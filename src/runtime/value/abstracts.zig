//! Abstracts: a value whose payload and lifetime belong to its `AbstractType`.
//! Constructing one, and the refcount that decides when a threaded one dies.
//! An abstract is a value in none of Janet's three views, so it is a leaf in
//! `value/` like `fibers.zig` and `functions.zig` rather than a group member.
//!
//! The four atomics at the foot of the file are refcount primitives rather than
//! abstract operations; they live here because the threaded refcount is their
//! only caller. The lock primitives are `ev/locks.zig`'s, even though Janet's
//! own file puts them between the threaded constructors and the refcount: each
//! is a thin cast onto a host structure whose layout the platform owns, which
//! is what keeps this file off the host threading headers.
//!
//! **Two allocators, one head.** A plain abstract and a threaded abstract share
//! `AbstractHead` and share nothing else. The plain one is collectable and its
//! lifetime is the collector's; the threaded one is a plain heap block on
//! neither list, living until its refcount reaches zero, so `beginThreaded` does
//! by hand the three things the collectable allocator would have done -- write
//! the type tag, clear the whole `data` union so a sanitizer sees no
//! uninitialised read, and charge the block against `vm.gc.next_collection`.
//! Both charges wrap on overflow, which only ever delays a collection.
//!
//! **Nothing here may raise, and one frame would leak if something did.**
//! `decrefMaybeFree` runs the type's `gc` finalizer and `beginThreaded` puts an
//! abstract key into a table, which may run the type's `hash`; `DESIGN.md`
//! section 12 is why neither may raise. `beginThreaded` holds a raw header
//! across that put, and nothing else has recorded it, so a raise from a `hash`
//! callback leaks it. That is the cost of breaking the rule, not a path the
//! runtime has. The finalizer is the other way round: the refcount is already
//! zero and no other thread can reach the block.

const tables = @import("tables.zig");
const gc_alloc = @import("../gc.zig");
const utils = @import("../utils.zig");
const wrap = @import("helpers/wrap.zig");
const constants = @import("constants");
const vm_state = @import("../vm/state.zig");
const abi = @import("abi");

/// `config.ev`. Six of the nine functions here reach
/// `vm.ev.threaded_abstracts`, a field that exists only in that configuration,
/// so this gates compilation rather than merely behaviour.
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

/// Allocate an abstract whose payload is not yet initialised.
///
/// **Construction is two steps, and the tag is what makes the window safe.**
/// The block is on the collector's heap list when this returns, tagged `.none`,
/// and `gc/sweep.zig`'s `deinitBlock` has no case for `.none` -- so a collection
/// before `end` frees the block without calling a finalizer on it and without
/// reading a field of it. An abstract type whose `gc` releases a pointer it has
/// not been given yet is the failure that prevents.
///
/// It is the *sweep* the tag protects and not the traversal. The mark phase
/// dispatches on the type of the `Value` it is handed, never on the block's
/// memory tag, so a caller that wraps and roots the block before filling it in
/// gets `gcmark` called on an uninitialised payload. Nothing here prevents
/// that: the contract is that the caller roots the value after `end`.
/// `test/abstract_core.zig` pins both halves, so tagging early to "fix" the
/// second would be caught.
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
///
/// The write is an `|=` rather than a store, and the two differ for any block
/// whose flags already carry the reachable bit: a plain abstract's `end` may
/// run after a collection has marked it.
pub fn end(x: ?*anyopaque) ?*anyopaque {
    gcSetType(abi.abstractHead(x), gc_alloc.MemoryType.abstract);
    return x;
}

/// `beginBytes` and `end` in one call, for a payload the caller fills in
/// afterwards or not at all.
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

// The threaded half of the file exists only with the event loop. Zig analyses
// a function only when something references it, so the bodies below are never
// compiled in a build without `vm.ev.threaded_abstracts` to reach.
comptime {
    if (has_ev) {}
}

/// Allocate a threaded abstract. It is on neither heap list; what keeps it
/// alive is its refcount, and what lets the collector see it at all is the
/// entry this makes in `v.ev.threaded_abstracts`, the per-collection visit
/// record `gc/mark.zig` writes into and `gc/sweep.zig` reads.
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
    // Clear the union before storing the refcount into it: the address
    // sanitizers read the whole word, so a partially written one is an
    // uninitialised read.
    header.gc.data.next = null;
    header.gc.data.refcount = 1;
    header.size = size;
    header.type = atype;
    const abstract = data(header);
    tables.put(&v.ev.threaded_abstracts, wrap.fromAbstract(abstract), wrap.fromFalse());
    return abstract;
}

/// The threaded counterpart of `end`. `beginThreaded` has already written this
/// tag, so this sets bits that are already set.
pub fn endThreaded(x: ?*anyopaque) ?*anyopaque {
    gcSetType(abi.abstractHead(x), gc_alloc.MemoryType.threaded_abstract);
    return x;
}

/// `beginThreaded` and `endThreaded` in one call, over the current VM.
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

/// Take a reference. Relaxed: an increment publishes nothing that another
/// thread has to observe in order.
pub fn incref(abst: ?*anyopaque) i32 {
    return @truncate(atomicInc(refcount(abst)));
}

/// Drop a reference without acting on the result. The caller decides what a
/// zero means; `decrefMaybeFree` is the version that acts.
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

// The primitives under the threaded abstract refcount above, which is why
// they live here. Two other counters use them as well: the event loop's
// `listener_count` and the VM's `auto_suspend`.
//
// Janet picks between four spellings by preprocessor: `_MSC_VER` interlocked
// intrinsics, `stdatomic.h`, Plan 9's `aincl`, and GCC's `__atomic_*`
// builtins. Zig has one spelling that compiles to the right instruction on
// every target, so the four collapse to one implementation rather than to a
// `switch` over the same four cases.
//
// `@atomicRmw` answers with the value *before* the operation where Janet's
// `__atomic_add_fetch` answers with the value after, so each of the first two
// adds the delta back. **The orderings are the contract**, not a local choice:
// relaxed to increment, acquire-release to decrement -- which is what makes
// the decrement that reaches zero see every write the other owners made.

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
