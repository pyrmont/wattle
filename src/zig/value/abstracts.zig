//! Abstracts: a value whose payload and lifetime belong to its `JanetAbstractType`.
//!
//! Constructing one, and the refcount that decides when a threaded one dies.
//! Phase 12's namespace batch 3 renamed `abstract_core.zig` to this and
//! `janet_abstract(t, n)` to `abstracts.new(t, n)`; `port/NAMESPACES.md` has
//! the scheme. An abstract is a value in none of `janet.h`'s three views, so
//! it is a leaf in `value/` like `fibers.zig` and `functions.zig` rather than
//! a member of a group.
//!
//! **The four atomics keep their names and are not abstract operations.**
//! `abstracts.atomicInc` is `janet_atomic_inc`, a refcount primitive that
//! lives here because `abstract.c` did and because the threaded refcount is
//! its only caller in the tree. Stripping `abstract` off a name that never
//! carried it would have produced `abstracts.inc`, which says the wrong
//! thing; a fifteenth file in `value/` for four one-line functions would
//! contradict the layout `NAMESPACES.md` settled, on the same reasoning that
//! left `asSize` duplicated in batch 1.
//!
//! This is Part 8 of Phase 8 and it takes the whole of
//! `src/core/abstract.c` except the mutex and rwlock shims: the three plain
//! constructors `janet_abstract_begin`, `janet_abstract_end` and
//! `janet_abstract`, their threaded counterparts, and
//! `janet_abstract_incref`, `janet_abstract_decref` and
//! `janet_abstract_decref_maybe_free`. Nine exported symbols, and no seam --
//! every one of them is public API in `janet.h` and the file has no `static`
//! at all.
//!
//! ## What stays in C, and why the guard has three regions
//!
//! `janet_os_mutex_*` and `janet_os_rwlock_*` stay in C by the same rule as
//! `struct tm` and `jstat_t`: each one is a thin cast onto a host structure --
//! `pthread_mutex_t`, `pthread_rwlock_t`, `CRITICAL_SECTION`, `SRWLOCK` --
//! whose layout the platform owns and whose size Janet publishes through
//! `janet_os_mutex_size`. Porting them would move the cast without moving the
//! structure, and would make Zig's translation of `<pthread.h>` a build
//! dependency of the runtime core for no gain.
//!
//! Those twelve functions sit physically between the threaded constructors and
//! the refcount primitives, so `abstract.c` carries three
//! `JANET_ZIG_ABSTRACT_CORE` regions rather than one. Nothing was moved to
//! make them contiguous, for the reason Part 7a gives: a reordered C file is a
//! permanent diff against upstream that buys only tidiness.
//!
//! ## Two allocators, one head
//!
//! A plain abstract and a threaded abstract share `JanetAbstractHead` and
//! share nothing else. The plain one comes from `janet_gcalloc`, which
//! prepends it to `janet_vm.blocks` and hands its lifetime to the collector.
//! The threaded one comes from `janet_malloc` directly, is on neither heap
//! list, and lives until its refcount reaches zero -- so this file has to do
//! by hand the three things `janet_gcalloc` would have done for it: write the
//! type tag into `flags`, clear `data.next` (`gc_alloc.zig` never does, because
//! the list link overwrites it immediately; here the union holds a refcount and
//! the C original clears the whole word for the sanitizers), and charge the
//! block against `janet_vm.next_collection`.
//!
//! That accounting is *not* the same charge `janet_gcalloc` makes, and the
//! difference is preserved. `janet_gcalloc` adds the size it was asked for,
//! which already includes the head, because `janet_abstract_begin` asks for
//! `sizeof(JanetAbstractHead) + size`. The threaded path adds
//! `size + sizeof(JanetAbstractHead)` explicitly for the same reason and to
//! the same total. Both wrap on overflow, which is defined for the unsigned
//! field and only ever delays a collection.
//!
//! ## Why construction is two steps
//!
//! `janet_abstract_begin` allocates with `JANET_MEMORY_NONE` and
//! `janet_abstract_end` writes `JANET_MEMORY_ABSTRACT` over it. The block is on
//! `janet_vm.blocks` and visible to the collector from the first call, with its
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
//! ## SPIKE-8, and the block that is briefly owned by nobody
//!
//! Two calls here reach code this runtime does not own.
//! `janet_abstract_decref_maybe_free` runs the type's `gc` finalizer, and
//! `janet_abstract_begin_threaded` calls `janet_table_put`, which hashes an
//! abstract key and so may run the type's own `hash` callback. Under SPIKE-8
//! both are called directly, in the shape of the C original, and a signal
//! raised by either jumps straight through the Zig frame that invoked it. There
//! is no `defer` in this file and `build.zig` checks that there is not.
//!
//! One frame here does hold a raw block across such a call, and it is the
//! exception to Part 6a's observation that every panic happens before the
//! allocation it guards. `janet_abstract_begin_threaded` has a `janet_malloc`ed
//! header in hand when it calls `janet_table_put`; a signal out of that call
//! leaks the header, because nothing has recorded it yet -- not a heap list,
//! not the visit table, not the caller. The C original leaks it identically,
//! and the port does not diverge. It is reachable only by the third-party
//! `hash` callback SPIKE-8 forbids, so it is stated here rather than in
//! `FOUND.md`.
//!
//! The finalizer is the other way round: by the time it runs, the refcount is
//! already zero and no other thread can reach the block, so a signal out of it
//! leaks a block that was about to be freed and nothing else.

const std = @import("std");
const raise = @import("raise");
const abstract_type = @import("../abstract_type.zig");
const tables = @import("tables.zig");
const gc_alloc = @import("../gc.zig");
const utils = @import("../utils.zig");
const wrap = @import("helpers/wrap.zig");
const fatal = @import("../fatal.zig");
const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");

/// `janet_vm`, whose layout is `types.JanetVM`'s and whose address
/// `cabi.vm()` takes.
inline fn vm() *types.JanetVM {
    return c.vm();
}

/// `JANET_VM_HAS_EV` in `src/zig/state_abi.h`. Six of the nine functions here
/// are inside `#ifdef JANET_EV` in the C original, and they reach
/// `janet_vm.threaded_abstracts`, a field that only exists in that
/// configuration, so this has to gate compilation rather than merely
/// behaviour.
const has_ev = constants.JANET_VM_HAS_EV != 0;

/// `janet_gc_settype` from `src/core/gc.h`. An or, not a store; see the note at
/// the head of the file.
inline fn gcSetType(head: *types.JanetAbstractHead, mtype: types.JanetMemoryType) void {
    head.gc.flags |= @as(i32, @intCast(0xFF & mtype));
}

// ------------------------------------------------------- plain abstracts

/// Allocate an abstract whose payload is not yet initialised. The block is on
/// the collector's heap list when this returns, tagged `JANET_MEMORY_NONE` so
/// that a collection before `janet_abstract_end` frees it without traversing
/// or finalizing it.
pub fn begin(atype: *const types.JanetAbstractType, size: usize) ?*anyopaque {
    const header: *types.JanetAbstractHead = @ptrCast(@alignCast(gc_alloc.gcalloc(
        constants.JANET_MEMORY_NONE,
        types.abstract_payload +% size,
    )));
    header.size = size;
    header.type = atype;
    return types.abstractData(header);
}

/// Publish an abstract the caller has finished initialising, by writing the
/// type tag the collector dispatches on.
pub fn end(x: ?*anyopaque) ?*anyopaque {
    gcSetType(types.abstractHead(x), constants.JANET_MEMORY_ABSTRACT);
    return x;
}

/// `janet_abstract_begin` and `janet_abstract_end` in one call, for a payload
/// the caller fills in afterwards or not at all.
pub fn new(atype: *const types.JanetAbstractType, size: usize) ?*anyopaque {
    return end(begin(atype, size));
}

// ---------------------------------------------------- threaded abstracts

// The threaded half of the file exists only with the event loop, exactly as
// `#ifdef JANET_EV` makes it in the C original. Zig analyses a function only
// when something references it, so the bodies below are never compiled in a
// build without `janet_vm.threaded_abstracts` to reach.
comptime {
    if (has_ev) {}
}

/// Allocate a threaded abstract. It is on neither heap list; what keeps it
/// alive is its refcount, and what lets the collector see it at all is the
/// entry this makes in `janet_vm.threaded_abstracts`, the per-collection visit
/// record `gc_mark.zig` writes into and `gc_sweep.zig` reads.
pub fn beginThreaded(atype: *const types.JanetAbstractType, size: usize) ?*anyopaque {
    const header: *types.JanetAbstractHead = @ptrCast(@alignCast(utils.malloc(
        types.abstract_payload +% size,
    ) orelse fatal.outOfMemory()));

    vm().next_collection +%= size +% types.abstract_payload;
    header.gc.flags = @as(i32, @intCast(constants.JANET_MEMORY_THREADED_ABSTRACT));
    // Clear the union before storing the refcount into it, exactly as the C
    // original does and for the reason its comment gives: the address
    // sanitizers read the whole word.
    header.gc.data.next = null;
    header.gc.data.refcount = 1;
    header.size = size;
    header.type = atype;
    const abstract = types.abstractData(header);
    tables.put(&vm().threaded_abstracts, wrap.fromAbstract(abstract), wrap.fromFalse());
    return abstract;
}

/// The threaded counterpart of `janet_abstract_end`. `janet_abstract_begin_threaded`
/// has already written this tag, so this sets bits that are already set.
pub fn endThreaded(x: ?*anyopaque) ?*anyopaque {
    gcSetType(types.abstractHead(x), constants.JANET_MEMORY_THREADED_ABSTRACT);
    return x;
}

/// `janet_abstract_begin_threaded` and `janet_abstract_end_threaded` in one call.
pub fn threaded(atype: *const types.JanetAbstractType, size: usize) ?*anyopaque {
    return endThreaded(beginThreaded(atype, size));
}

// --------------------------------------------------------------- refcount

/// The refcount field, which shares the union with the heap-list link a
/// collectable block uses. A threaded abstract is on no heap list, so the two
/// never contend.
inline fn refcount(abst: ?*anyopaque) *volatile types.JanetAtomicInt {
    return &types.abstractHead(abst).gc.data.refcount;
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
        const head = types.abstractHead(abst);
        if (abstract_type.of(head.type).gc) |finalizer| {
            // `janet_assert(!head->type->gc(...), "finalizer failed")`. A
            // finalizer that reports failure is not an error to be raised: the
            // C original prints and calls `abort`.
            if (finalizer(types.abstractData(head), head.size) != 0)
                fatal.fatal("finalizer failed");
        }
        utils.free(head);
    }
    return result;
}

// ----------------------------------------------------------- atomic counts

// The primitives under the threaded abstract refcount above, moved out of
// `capi.c` in Phase 10 Part 5. Two other counters in the runtime use them --
// the event loop's `listener_count` and the VM's `auto_suspend` -- but this is
// where the refcount they were written for lives.
//
// The C original picks between four spellings by preprocessor: `_MSC_VER`
// interlocked intrinsics, `stdatomic.h`, Plan 9's `aincl`, and GCC's
// `__atomic_*` builtins. Zig has one spelling that compiles to the right
// instruction on every target, so the four collapse to one implementation
// rather than to a Zig `switch` over the same four cases.
//
// `@atomicRmw` answers with the value *before* the operation and
// `__atomic_add_fetch` with the value after, so each of the first two adds the
// delta back. The orderings are the C original's, not a fresh choice: relaxed
// to increment, acquire-release to decrement -- which is what makes the
// decrement that reaches zero see every write the other owners made.

pub fn atomicInc(x: *volatile types.JanetAtomicInt) types.JanetAtomicInt {
    return @atomicRmw(types.JanetAtomicInt, x, .Add, 1, .monotonic) +% 1;
}

pub fn atomicDec(x: *volatile types.JanetAtomicInt) types.JanetAtomicInt {
    return @atomicRmw(types.JanetAtomicInt, x, .Add, -1, .acq_rel) -% 1;
}

pub fn atomicLoad(x: *volatile types.JanetAtomicInt) types.JanetAtomicInt {
    return @atomicLoad(types.JanetAtomicInt, x, .acquire);
}

pub fn atomicLoadRelaxed(x: *volatile types.JanetAtomicInt) types.JanetAtomicInt {
    return @atomicLoad(types.JanetAtomicInt, x, .monotonic);
}
