//! Abstracts: a value whose payload and lifetime belong to its `AbstractType`.
//!
//! Constructing one, and the refcount that decides when a threaded one dies.
//! An abstract is a value in none of Janet's three views, so it is a leaf in
//! `value/` like `fibers.zig` and `functions.zig` rather than a member of a
//! group.
//!
//! **The four atomics are not abstract operations.**
//! `abstracts.atomicInc` is `janet_atomic_inc`, a refcount primitive that
//! lives here because the threaded refcount is its only caller in the tree.
//!
//! The three plain constructors `janet_abstract_begin`, `janet_abstract_end`
//! and `janet_abstract`, their threaded counterparts, and
//! `janet_abstract_incref`, `janet_abstract_decref` and
//! `janet_abstract_decref_maybe_free`. Nine exported symbols, all of them
//! public API.
//!
//! ## Why the lock primitives are not here
//!
//! `janet_os_mutex_*` and `janet_os_rwlock_*` sit between the threaded
//! constructors and the refcount primitives in Janet's own file, so a reader
//! following that file's order expects them here. They are `ev/locks.zig`'s:
//! each is a thin cast onto a host structure -- `pthread_mutex_t`,
//! `pthread_rwlock_t`, `CRITICAL_SECTION`, `SRWLOCK` -- whose layout the
//! platform owns and whose size the runtime publishes through
//! `janet_os_mutex_size`. That is the event loop's business rather than the
//! collector's, and keeping it there is what stops this file depending on the
//! host threading headers.
//!
//! ## Two allocators, one head
//!
//! A plain abstract and a threaded abstract share `AbstractHead` and
//! share nothing else. The plain one comes from `janet_gcalloc`, which
//! prepends it to `vm.gc.blocks` and hands its lifetime to the collector.
//! The threaded one comes from `janet_malloc` directly, is on neither heap
//! list, and lives until its refcount reaches zero -- so this file has to do
//! by hand the three things `janet_gcalloc` would have done for it: write the
//! type tag into `flags`, clear `data.next` (`gc.zig` never does, because the
//! list link overwrites it immediately; here the union holds a refcount and the
//! whole word is cleared so a sanitizer sees no uninitialised read), and charge
//! the block against `vm.gc.next_collection`.
//!
//! That accounting is *not* the same charge `janet_gcalloc` makes, and the
//! difference is preserved. `janet_gcalloc` adds the size it was asked for,
//! which already includes the head, because `janet_abstract_begin` asks for
//! `sizeof(AbstractHead) + size`. The threaded path adds
//! `size + sizeof(AbstractHead)` explicitly for the same reason and to
//! the same total. Both wrap on overflow, which is defined for the unsigned
//! field and only ever delays a collection.
//!
//! ## Why construction is two steps
//!
//! `janet_abstract_begin` allocates with `JANET_MEMORY_NONE` and
//! `janet_abstract_end` writes `JANET_MEMORY_ABSTRACT` over it. The block is on
//! `vm.gc.blocks` and visible to the collector from the first call, with its
//! payload still uninitialised, and the tag is what makes that safe --
//! `janet_deinit_block` has no case for `JANET_MEMORY_NONE`, so a collection in
//! the window frees the block without calling a finalizer on it and without
//! reading a field of it. An abstract type whose `gc` releases a pointer it has
//! not been given yet is the failure this prevents.
//!
//! It is the *sweep* the tag protects, not the traversal, and the distinction
//! is worth keeping straight because the file reads as though it were the other
//! way round. The mark phase dispatches on the type of the `Janet` it is handed,
//! never on the block's memory tag, so an embedder that wraps and roots the
//! block before filling it in gets `gcmark` called on an uninitialised payload.
//! Nothing here prevents that and nothing should: the contract is that the
//! caller roots the value after `janet_abstract_end`. `test/abstract_core.zig`
//! pins both halves, so a port that "fixed" the second by tagging early would
//! be caught.
//!
//! `janet_gc_settype` is `|=`, not an assignment, which matters only on the
//! threaded path: `janet_abstract_begin_threaded` has already written
//! `JANET_MEMORY_THREADED_ABSTRACT` into `flags`, so
//! `janet_abstract_end_threaded` sets bits that are already set. Reproduced as
//! an or, not simplified into a store -- the two differ for any block whose
//! flags carry `JANET_MEM_REACHABLE`, and a threaded abstract's do not go
//! through the mark phase but `janet_abstract_end` on a plain one may run after
//! a collection has marked it.
//!
//! ## The block that is briefly owned by nobody
//!
//! Two calls here reach code this runtime does not own.
//! `janet_abstract_decref_maybe_free` runs the type's `gc` finalizer, and
//! `janet_abstract_begin_threaded` calls `janet_table_put`, which hashes an
//! abstract key and so may run the type's own `hash` callback. Neither may
//! raise.
//!
//! One frame here does hold a raw block across such a call.
//! `janet_abstract_begin_threaded` has a `janet_malloc`ed header in hand when
//! it calls `janet_table_put`; a raise out of that call leaks the header,
//! because nothing has recorded it yet -- not a heap list, not the visit
//! table, not the caller. It is reachable only through a third-party `hash`
//! callback, which is not allowed to raise -- so the leak is stated here as
//! the cost of breaking that rule rather than as a path the runtime has.
//!
//! The finalizer is the other way round: by the time it runs, the refcount is
//! already zero and no other thread can reach the block, so a signal out of it
//! leaks a block that was about to be freed and nothing else.

const tables = @import("tables.zig");
const gc_alloc = @import("../gc.zig");
const utils = @import("../utils.zig");
const wrap = @import("helpers/wrap.zig");
const constants = @import("constants");
const vm_state = @import("../vm/state.zig");
const abi = @import("abi");

/// `config.ev`. Six of the nine functions here
/// are inside `#ifdef JANET_EV` in the C original, and they reach
/// `vm.ev.threaded_abstracts`, a field that only exists in that
/// configuration, so this has to gate compilation rather than merely
/// behaviour.
const has_ev = constants.JANET_VM_HAS_EV != 0;

/// The payload Janet passes an abstract around as: the address just past the
/// head, with no type of its own -- the `AbstractType` is what says what is
/// there.
pub const Abstract = ?*anyopaque;

/// The payload of a block the allocator has just returned, the inverse of
/// `abi.abstractHead`. It takes a `*const` head and hands back a mutable
/// payload: the allocator's caller has to write through it, and a const head
/// is what a comparison or a hash holds.
pub inline fn data(hd: *const abi.AbstractHead) *anyopaque {
    return @ptrFromInt(@intFromPtr(hd) +% abi.abstract_payload);
}

/// Set the memory type in the header's flag word. An or, not a store; see the
/// note at the head of the file. The field is the type's own byte now, so the
/// or is over that byte rather than over the whole word.
inline fn gcSetType(head: *abi.AbstractHead, mtype: gc_alloc.MemoryType) void {
    head.gc.flags.type |= @intFromEnum(mtype);
}

// ------------------------------------------------------- plain abstracts

/// Allocate an abstract whose payload is not yet initialised. The block is on
/// the collector's heap list when this returns, tagged `JANET_MEMORY_NONE` so
/// that a collection before `janet_abstract_end` frees it without traversing
/// or finalizing it.
///
/// The size is a run-time byte count here because several payloads are sized
/// by their contents rather than by a type: a compiled PEG, a socket address,
/// an unmarshalled abstract. Where the caller does know the type, `newFor`
/// below says so and answers a `*T`.
pub fn beginBytes(atype: *const abi.AbstractType, size: usize) *anyopaque {
    const header = gc_alloc.gcallocWithPayload(abi.AbstractHead, .none, size);
    header.size = size;
    header.type = atype;
    return data(header);
}

/// Publish an abstract the caller has finished initialising, by writing the
/// type tag the collector dispatches on.
pub fn end(x: ?*anyopaque) ?*anyopaque {
    gcSetType(abi.abstractHead(x), gc_alloc.MemoryType.abstract);
    return x;
}

/// `janet_abstract_begin` and `janet_abstract_end` in one call, for a payload
/// the caller fills in afterwards or not at all.
pub fn newBytes(atype: *const abi.AbstractType, size: usize) *anyopaque {
    return @ptrCast(end(beginBytes(atype, size)).?);
}

/// The same, for a payload that is exactly a `T`. A caller of `newBytes` writes
/// `@sizeOf(T)` on the way in and `@ptrCast(@alignCast(...))` on the way out,
/// and the two halves can disagree without anything noticing.
pub inline fn newFor(comptime T: type, atype: *const abi.AbstractType) *T {
    return @ptrCast(@alignCast(newBytes(atype, @sizeOf(T))));
}

// ---------------------------------------------------- threaded abstracts

// The threaded half of the file exists only with the event loop, exactly as
// `#ifdef JANET_EV` makes it in the C original. Zig analyses a function only
// when something references it, so the bodies below are never compiled in a
// build without `vm.ev.threaded_abstracts` to reach.
comptime {
    if (has_ev) {}
}

/// Allocate a threaded abstract. It is on neither heap list; what keeps it
/// alive is its refcount, and what lets the collector see it at all is the
/// entry this makes in `v.ev.threaded_abstracts`, the per-collection visit
/// record `gc_mark.zig` writes into and `gc_sweep.zig` reads.
///
/// **It takes the VM rather than fetching it**, because it writes two pieces
/// of state that belong to different owners -- the collector's byte budget and
/// the event loop's visit record -- and naming the one thing that has both is
/// the only parameter that does not hide half of that. `threaded` below is
/// where the current VM is looked up.
pub fn beginThreaded(v: *vm_state.Vm, atype: *const abi.AbstractType, size: usize) ?*anyopaque {
    const header: *abi.AbstractHead = @ptrCast(@alignCast(utils.rawAlloc(
        abi.abstract_payload +% size,
    )));

    v.gc.next_collection +%= size +% abi.abstract_payload;
    header.gc.flags = .{ .type = @intFromEnum(gc_alloc.MemoryType.threaded_abstract) };
    // Clear the union before storing the refcount into it, exactly as the C
    // original does and for the reason its comment gives: the address
    // sanitizers read the whole word.
    header.gc.data.next = null;
    header.gc.data.refcount = 1;
    header.size = size;
    header.type = atype;
    const abstract = data(header);
    tables.put(&v.ev.threaded_abstracts, wrap.fromAbstract(abstract), wrap.fromFalse());
    return abstract;
}

/// The threaded counterpart of `janet_abstract_end`. `janet_abstract_begin_threaded`
/// has already written this tag, so this sets bits that are already set.
pub fn endThreaded(x: ?*anyopaque) ?*anyopaque {
    gcSetType(abi.abstractHead(x), gc_alloc.MemoryType.threaded_abstract);
    return x;
}

/// `janet_abstract_begin_threaded` and `janet_abstract_end_threaded` in one call.
pub fn threaded(atype: *const abi.AbstractType, size: usize) ?*anyopaque {
    return endThreaded(beginThreaded(vm_state.current(), atype, size));
}

// --------------------------------------------------------------- refcount

/// The refcount field, which shares the union with the heap-list link a
/// collectable block uses. A threaded abstract is on no heap list, so the two
/// never contend.
inline fn refcount(abst: ?*anyopaque) *volatile abi.AtomicInt {
    return &abi.abstractHead(abst).gc.data.refcount;
}

/// Take a reference. Relaxed, like the C original: an increment publishes
/// nothing that another thread has to observe in order.
pub fn incref(abst: ?*anyopaque) i32 {
    return @truncate(atomicInc(refcount(abst)));
}

/// Drop a reference without acting on the result. The caller decides what a
/// zero means; `janet_abstract_decref_maybe_free` is the version that acts.
pub fn decref(abst: ?*anyopaque) i32 {
    return @truncate(atomicDec(refcount(abst)));
}

/// Drop a reference and free the block if it was the last one. The finalizer
/// runs on the thread that dropped the last reference, which is not
/// necessarily the thread that made the abstract.
pub fn decrefMaybeFree(abst: ?*anyopaque) i32 {
    const result = decref(abst);
    if (result == 0) {
        const head = abi.abstractHead(abst);
        // A finalizer cannot raise and does not report: it answers `void`,
        // because every implementation in the tree returns a literal zero and
        // no caller could act on anything else. `abstract_type.zig` has the
        // contract.
        if (head.type.gc) |finalizer| finalizer(data(head), head.size);
        utils.free(head);
    }
    return result;
}

// ----------------------------------------------------------- atomic counts

// The primitives under the threaded abstract refcount above. Two other
// counters in the runtime use them -- the event loop's `listener_count` and
// the VM's `auto_suspend` -- but this is where the refcount they were written
// for lives.
//
// Janet picks between four spellings by preprocessor: `_MSC_VER` interlocked
// intrinsics, `stdatomic.h`, Plan 9's `aincl`, and GCC's `__atomic_*`
// builtins. Zig has one spelling that compiles to the right instruction on
// every target, so the four collapse to one implementation rather than to a
// `switch` over the same four cases.
//
// `@atomicRmw` answers with the value *before* the operation and
// `__atomic_add_fetch` with the value after, so each of the first two adds the
// delta back. The orderings are the C original's, not a fresh choice: relaxed
// to increment, acquire-release to decrement -- which is what makes the
// decrement that reaches zero see every write the other owners made.

pub fn atomicInc(x: *volatile abi.AtomicInt) abi.AtomicInt {
    return @atomicRmw(abi.AtomicInt, x, .Add, 1, .monotonic) +% 1;
}

pub fn atomicDec(x: *volatile abi.AtomicInt) abi.AtomicInt {
    return @atomicRmw(abi.AtomicInt, x, .Add, -1, .acq_rel) -% 1;
}

pub fn atomicLoad(x: *volatile abi.AtomicInt) abi.AtomicInt {
    return @atomicLoad(abi.AtomicInt, x, .acquire);
}

pub fn atomicLoadRelaxed(x: *volatile abi.AtomicInt) abi.AtomicInt {
    return @atomicLoad(abi.AtomicInt, x, .monotonic);
}
