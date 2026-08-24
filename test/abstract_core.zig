//! Behavioral contract for abstract value construction and the threaded
//! abstract refcount: `janet_abstract_begin`, `janet_abstract_end`,
//! `janet_abstract`, their threaded counterparts, and
//! `janet_abstract_incref`, `janet_abstract_decref` and
//! `janet_abstract_decref_maybe_free`.
//!
//! These nine functions are almost all bookkeeping, and bookkeeping is what
//! has to be checked, because the return values agree between a correct
//! implementation and several wrong ones. Four channels carry it:
//!
//!  - `janet_abstract_head` recovers the header, so `size`, `type` and the raw
//!    `gc.flags` word are readable directly. The flags word is where the
//!    difference between `janet_gc_settype`'s or and a plain store shows up,
//!    and nothing else observes it.
//!  - `janet_vm.blocks` and `janet_vm.block_count` say whether the collector
//!    was given the block. A plain abstract must be on the list; a threaded
//!    one must be on neither list.
//!  - `janet_vm.next_collection` says what the block was charged, and the two
//!    allocators charge it by different arithmetic to the same total.
//!  - `janet_vm.threaded_abstracts` is the visit record a threaded abstract is
//!    registered in at birth, and the type's `gc` callback counts its own
//!    calls on the way out.
//!
//! The two-step protocol gets a case of its own because it is the only reason
//! `janet_abstract_begin` exists separately: a collection between the two
//! calls must free the block without traversing or finalizing it, and an
//! abstract type whose `gcmark` and `gc` count their calls is what proves it.
//!
//! ## What the adapter pool stopped being needed for
//!
//! The C original reached every one of these types through `CONTRACT_AT`,
//! which is `test/support.zig`'s `janet_contract_abstract_type` — a pool of
//! pre-built tables that exists because a `JanetAbstractType`'s callbacks have
//! been Zig-ABI since Phase 10's hinge and C can define none of them.
//!
//! This file needs `gc`, `gcmark` and `gcperthread`, and the hinge typed all
//! three **non**-raising for a reason `abstract_type.zig` sets out: a raise
//! from a finalizer runs mid-sweep on an object that is already unreachable,
//! so it has nowhere to go for anybody. They are ordinary `callconv(.c)`
//! functions, and the table below is the runtime's own `AbstractType` with no
//! adapter between.
//!
//! ## Two things this file no longer says, and where they went
//!
//! The C original opened with
//! `assert(sizeof(JanetAbstractHead) == offsetof(JanetAbstractHead, data))`
//! and later checked the recovery arithmetic as
//! `(char *) a == (char *) head + sizeof(JanetAbstractHead)`. Neither can be
//! translated: `@cImport` drops a flexible array member, so `@offsetOf` does
//! not compile and `c.janet_abstract_head` recovers the header with `@sizeOf`
//! — which makes both comparisons `@sizeOf` against itself.
//!
//! Both replacements already exist, from Phase 11 Part 8. `test/abi.c` carries
//! the static assertion unchanged, because that is a claim about `janet.h` and
//! `abi.c` is C; `test/gc_mark.zig`'s `theHeadOffsets` derives the offset from
//! the allocator and compares it against `@sizeOf`, which is the runtime claim.
//! Nothing is dropped here, and nothing is restated.
//!
//! Nothing exercises a raising callback. SPIKE-8 settled that an abstract
//! callback may not raise; `SPIKE-8.md` records what the C runtime did when
//! one did anyway.

const std = @import("std");
const abi = @import("abi");
const c = abi.c;
const options = @import("options");
const harness = @import("harness.zig");
const abstract_type = @import("subsystems").abstract_type;
const AbstractType = abstract_type.AbstractType;

const heap = harness.heap;

/// The threaded half of this subsystem exists only with the event loop.
/// `options` names **subsystems** rather than features — Part 3's lesson 7 —
/// so `ev_core` is the field that carries `hasEv(options)`.
const has_ev = options.ev_core;

// --------------------------------------------------------------- helpers

/// Reach a quiet heap, so that a later collection's effects are attributable
/// to what this case made rather than to what an earlier one left behind.
fn settle() void {
    c.janet_collect();
    c.janet_collect();
}

var mark_calls: i32 = 0;
var gc_calls: i32 = 0;
var perthread_calls: i32 = 0;

fn probeGcmark(_: ?*anyopaque, _: usize) callconv(.c) c_int {
    mark_calls += 1;
    return 0;
}

fn probeGc(_: ?*anyopaque, _: usize) callconv(.c) c_int {
    gc_calls += 1;
    return 0;
}

fn probePerthread(_: ?*anyopaque, _: usize) callconv(.c) c_int {
    perthread_calls += 1;
    return 0;
}

const at_counted: AbstractType = .{
    .name = "abstract-core-test/counted",
    .gc = probeGc,
    .gcmark = probeGcmark,
    .gcperthread = probePerthread,
};

/// The same type with no callbacks at all. Freeing one of these must not reach
/// for a null function pointer.
const at_bare: AbstractType = .{ .name = "abstract-core-test/bare" };

fn counted() [*c]const c.JanetAbstractType {
    return abstract_type.stored(&at_counted);
}

fn bare() [*c]const c.JanetAbstractType {
    return abstract_type.stored(&at_bare);
}

fn headOf(abstract: ?*anyopaque) *c.JanetAbstractHead {
    return c.janet_abstract_head(abstract);
}

// -------------------------------------------------- plain construction

/// `janet_abstract_begin` writes the two header fields and nothing else, and
/// hands the block to the collector tagged `JANET_MEMORY_NONE`. The tag is the
/// whole point: the payload is uninitialised at this moment and the block is
/// already reachable from `janet_vm.blocks`.
fn beginPublishesAnUntypedBlock() void {
    settle();
    const before_count = c.janet_vm.block_count;
    const before_charge = c.janet_vm.next_collection;

    const a = c.janet_abstract_begin(counted(), 40);
    const head = headOf(a);

    std.debug.assert(head.size == 40);
    std.debug.assert(head.type == counted());
    std.debug.assert(heap.memoryType(head) == c.JANET_MEMORY_NONE);
    std.debug.assert(head.gc.flags & c.JANET_MEM_REACHABLE == 0);

    std.debug.assert(c.janet_vm.block_count == before_count + 1);
    std.debug.assert(heap.onList(c.janet_vm.blocks, head));
    std.debug.assert(!heap.onList(c.janet_vm.weak_blocks, head));
    std.debug.assert(c.janet_vm.next_collection ==
        before_charge + @sizeOf(c.JanetAbstractHead) + 40);

    // `long long data[]` is the most general alignment the header can ask for,
    // so the payload is aligned for anything an embedder puts in it.
    std.debug.assert(@intFromPtr(a) % @sizeOf(c_longlong) == 0);

    _ = c.janet_abstract_end(a);
}

/// `janet_abstract_end` writes the type tag and returns the same pointer.
fn endTypesTheBlock() void {
    const a = c.janet_abstract_begin(counted(), 8);
    const head = headOf(a);
    std.debug.assert(heap.memoryType(head) == c.JANET_MEMORY_NONE);

    const b = c.janet_abstract_end(a);
    std.debug.assert(b == a);
    std.debug.assert(heap.memoryType(head) == c.JANET_MEMORY_ABSTRACT);
    std.debug.assert(head.size == 8);
    std.debug.assert(head.type == counted());
}

/// `janet_gc_settype` is an or, not a store, and this is the only place the
/// difference is visible: a block marked reachable by a collection that ran
/// between `begin` and `end` must still be marked afterwards. A store would
/// clear `JANET_MEM_REACHABLE` and the sweep would then free a block the
/// caller is about to use.
fn endPreservesTheOtherFlagBits() void {
    const a = c.janet_abstract_begin(counted(), 8);
    const head = headOf(a);

    head.gc.flags |= c.JANET_MEM_REACHABLE;
    head.gc.flags |= c.JANET_MEM_DISABLED;

    _ = c.janet_abstract_end(a);
    std.debug.assert(heap.memoryType(head) == c.JANET_MEMORY_ABSTRACT);
    std.debug.assert(head.gc.flags & c.JANET_MEM_REACHABLE != 0);
    std.debug.assert(head.gc.flags & c.JANET_MEM_DISABLED != 0);

    // Leave nothing marked or disabled behind for the next case.
    head.gc.flags &= ~@as(i32, c.JANET_MEM_REACHABLE | c.JANET_MEM_DISABLED);
}

/// `janet_abstract` is the two calls in one, and must charge and tag exactly
/// as they do separately.
fn abstractIsBeginThenEnd() void {
    settle();
    const before_count = c.janet_vm.block_count;
    const before_charge = c.janet_vm.next_collection;

    const a = c.janet_abstract(counted(), 24);
    const head = headOf(a);

    std.debug.assert(heap.memoryType(head) == c.JANET_MEMORY_ABSTRACT);
    std.debug.assert(head.size == 24);
    std.debug.assert(head.type == counted());
    std.debug.assert(c.janet_vm.block_count == before_count + 1);
    std.debug.assert(heap.onList(c.janet_vm.blocks, head));
    std.debug.assert(c.janet_vm.next_collection ==
        before_charge + @sizeOf(c.JanetAbstractHead) + 24);
}

/// A zero-length abstract is a header and nothing else, and is legal.
fn zeroLengthAbstract() void {
    const a = c.janet_abstract(bare(), 0);
    const head = headOf(a);
    std.debug.assert(head.size == 0);
    std.debug.assert(heap.memoryType(head) == c.JANET_MEMORY_ABSTRACT);
}

/// The payload is untouched by construction, so an embedder that writes it
/// before `janet_abstract_end` finds it intact afterwards.
fn payloadSurvivesEnd() void {
    const a = c.janet_abstract_begin(bare(), 16);
    const payload: [*]u8 = @ptrCast(a.?);
    @memset(payload[0..16], 0x5a);
    _ = c.janet_abstract_end(a);
    for (payload[0..16]) |byte| std.debug.assert(byte == 0x5a);
}

// ------------------------------------------------- the two-step window

/// The reason `begin` and `end` are separate. A block tagged
/// `JANET_MEMORY_NONE` is on the heap list and visible to the collector with
/// an uninitialised payload, and what makes that safe is the sweep rather than
/// the mark phase: `janet_deinit_block` has no case for that tag, so the block
/// is freed without its finalizer running and without anything reading a field
/// of the payload. An abstract type whose `gc` frees a pointer it has not been
/// given yet is the crash this prevents.
fn collectionBetweenBeginAndEnd() void {
    settle();
    mark_calls = 0;
    gc_calls = 0;
    perthread_calls = 0;

    const counted_before = c.janet_vm.block_count;
    _ = c.janet_abstract_begin(counted(), 32);
    std.debug.assert(c.janet_vm.block_count == counted_before + 1);

    // Nothing refers to it, so the collection frees it -- untyped, so neither
    // finalizer runs and the payload is never read.
    c.janet_collect();
    std.debug.assert(c.janet_vm.block_count == counted_before);
    std.debug.assert(mark_calls == 0);
    std.debug.assert(gc_calls == 0);
    std.debug.assert(perthread_calls == 0);
}

/// What the tag does *not* do is keep the traversal away. The mark phase
/// dispatches on the type of the `Janet` it is given, not on the block's
/// memory tag, so an embedder that wraps and roots the block before filling it
/// in gets `gcmark` called on an uninitialised payload. That is the C
/// behaviour and the port reproduces it; the caller's obligation is to root
/// the value after `janet_abstract_end`, not before. Pinned here so that a
/// port which "fixed" it by tagging early would be caught.
fn theWindowDoesNotStopTheTraversal() void {
    settle();
    mark_calls = 0;
    gc_calls = 0;
    perthread_calls = 0;

    const a = c.janet_abstract_begin(counted(), 32);
    const value = c.janet_wrap_abstract(a);
    c.janet_gcroot(value);

    const counted_before = c.janet_vm.block_count;
    c.janet_collect();

    std.debug.assert(c.janet_vm.block_count == counted_before);
    std.debug.assert(mark_calls == 1);
    std.debug.assert(gc_calls == 0);
    std.debug.assert(heap.memoryType(headOf(a)) == c.JANET_MEMORY_NONE);

    _ = c.janet_gcunroot(value);
    c.janet_collect();

    // Freed, and still never finalized: the sweep is where the tag decides.
    std.debug.assert(c.janet_vm.block_count == counted_before - 1);
    std.debug.assert(gc_calls == 0);
    std.debug.assert(perthread_calls == 0);
}

/// Once `janet_abstract_end` has run, the same block is traversed and
/// finalized like any other abstract. Without this, an implementation that
/// never tags the block at all passes every case above.
fn aFinishedAbstractIsTraversedAndFinalized() void {
    settle();
    mark_calls = 0;
    gc_calls = 0;
    perthread_calls = 0;

    const a = c.janet_abstract(counted(), 32);
    const value = c.janet_wrap_abstract(a);
    c.janet_gcroot(value);

    c.janet_collect();
    std.debug.assert(mark_calls == 1);
    std.debug.assert(gc_calls == 0);

    _ = c.janet_gcunroot(value);
    c.janet_collect();
    std.debug.assert(gc_calls == 1);
    std.debug.assert(perthread_calls == 1);
}

// ------------------------------------------------ threaded construction

var threaded_gc_calls: i32 = 0;
var threaded_gc_data: ?*anyopaque = null;
var threaded_gc_len: usize = 0;

/// The finalizer records what it was handed. `janet_abstract_decref_maybe_free`
/// calls it as `head->type->gc(head->data, head->size)`, and both arguments
/// are easy to get wrong in a way no return value reveals: the header is one
/// word from the payload, and `size` is the only place the payload's length is
/// recorded once the caller has let go of it.
fn probeThreadedGc(data: ?*anyopaque, length: usize) callconv(.c) c_int {
    threaded_gc_data = data;
    threaded_gc_len = length;
    threaded_gc_calls += 1;
    return 0;
}

const at_threaded: AbstractType = .{
    .name = "abstract-core-test/threaded",
    .gc = probeThreadedGc,
    .gcmark = probeGcmark,
};

const at_threaded_bare: AbstractType = .{ .name = "abstract-core-test/threaded-bare" };

fn threaded() [*c]const c.JanetAbstractType {
    return abstract_type.stored(&at_threaded);
}

fn threadedBare() [*c]const c.JanetAbstractType {
    return abstract_type.stored(&at_threaded_bare);
}

/// Drop the reference this interpreter holds, the way the sweep does: take the
/// entry out of the visit record first, then decrement. That order is not a
/// tidiness -- freeing the block while `janet_vm.threaded_abstracts` still
/// keys on it leaves the next collection reading a freed header, which is why
/// every threaded case here ends this way rather than by calling
/// `janet_abstract_decref_maybe_free` alone.
fn drop(a: ?*anyopaque) i32 {
    _ = c.janet_table_remove(&c.janet_vm.threaded_abstracts, c.janet_wrap_abstract(a));
    return c.janet_abstract_decref_maybe_free(a);
}

/// Whether the visit record holds this abstract. `janet_table_get` returns nil
/// for an absent key and the stored boolean for a present one, and the sweep
/// distinguishes the two, so this does as well.
fn tracked(a: ?*anyopaque) bool {
    const entry = c.janet_table_get(&c.janet_vm.threaded_abstracts, c.janet_wrap_abstract(a));
    return !harness.isType(entry, c.JANET_NIL);
}

/// A threaded abstract is `janet_malloc`ed, not `janet_gcalloc`ed. It is on
/// neither heap list and the block count does not move -- what records it is
/// the visit table, and what keeps it alive is the refcount that starts at one.
fn beginThreadedRegistersWithoutTheHeap() void {
    settle();
    const before_count = c.janet_vm.block_count;
    const before_charge = c.janet_vm.next_collection;
    const before_tracked = c.janet_vm.threaded_abstracts.count;
    const before_capacity = c.janet_vm.threaded_abstracts.capacity;

    const a = c.janet_abstract_begin_threaded(threadedBare(), 48);
    const head = headOf(a);

    std.debug.assert(head.size == 48);
    std.debug.assert(head.type == threadedBare());
    std.debug.assert(heap.memoryType(head) == c.JANET_MEMORY_THREADED_ABSTRACT);
    std.debug.assert(head.gc.data.refcount == 1);

    std.debug.assert(c.janet_vm.block_count == before_count);
    std.debug.assert(!heap.onList(c.janet_vm.blocks, head));
    std.debug.assert(!heap.onList(c.janet_vm.weak_blocks, head));

    // The threaded path adds `size + sizeof(head)` by hand where
    // `janet_gcalloc` adds the size it was asked for. Same total -- plus
    // whatever the visit table charged if this entry made it rehash, since
    // `janet_memalloc_empty` bills its new bucket array to the same counter.
    var table_charge: usize = 0;
    if (c.janet_vm.threaded_abstracts.capacity != before_capacity) {
        table_charge = @as(usize, @intCast(c.janet_vm.threaded_abstracts.capacity)) * @sizeOf(c.JanetKV);
    }
    std.debug.assert(c.janet_vm.next_collection ==
        before_charge + @sizeOf(c.JanetAbstractHead) + 48 + table_charge);

    std.debug.assert(c.janet_vm.threaded_abstracts.count == before_tracked + 1);
    std.debug.assert(tracked(a));

    // Registered false: the visit record starts unvisited, and a mark phase is
    // what sets it.
    const entry = c.janet_table_get(&c.janet_vm.threaded_abstracts, c.janet_wrap_abstract(a));
    std.debug.assert(harness.isType(entry, c.JANET_BOOLEAN));
    std.debug.assert(c.janet_unwrap_boolean(entry) == 0);

    std.debug.assert(@intFromPtr(a) % @sizeOf(c_longlong) == 0);

    _ = c.janet_abstract_end_threaded(a);
    std.debug.assert(drop(a) == 0);
}

/// `janet_abstract_end_threaded` sets a tag `begin` has already set, so the
/// only observable requirement is that it changes nothing and returns its
/// argument. An implementation that stored `JANET_MEMORY_ABSTRACT` instead
/// would put a malloced block on the collector's abstract path, which is a
/// double free.
fn endThreadedChangesNothing() void {
    const a = c.janet_abstract_begin_threaded(threadedBare(), 8);
    const head = headOf(a);
    const flags_before = head.gc.flags;

    const b = c.janet_abstract_end_threaded(a);
    std.debug.assert(b == a);
    std.debug.assert(head.gc.flags == flags_before);
    std.debug.assert(heap.memoryType(head) == c.JANET_MEMORY_THREADED_ABSTRACT);
    std.debug.assert(head.gc.data.refcount == 1);

    std.debug.assert(drop(a) == 0);
}

fn abstractThreadedIsBeginThenEnd() void {
    settle();
    const before_tracked = c.janet_vm.threaded_abstracts.count;
    const before_count = c.janet_vm.block_count;

    const a = c.janet_abstract_threaded(threadedBare(), 16);
    const head = headOf(a);

    std.debug.assert(heap.memoryType(head) == c.JANET_MEMORY_THREADED_ABSTRACT);
    std.debug.assert(head.size == 16);
    std.debug.assert(head.gc.data.refcount == 1);
    std.debug.assert(c.janet_vm.block_count == before_count);
    std.debug.assert(c.janet_vm.threaded_abstracts.count == before_tracked + 1);
    std.debug.assert(tracked(a));

    std.debug.assert(drop(a) == 0);
}

// ---------------------------------------------------------- the refcount

/// Both primitives return the value *after* their own change, not before, and
/// both write it through to the header.
fn increfAndDecrefReturnTheNewCount() void {
    const a = c.janet_abstract_threaded(threadedBare(), 8);
    const head = headOf(a);

    std.debug.assert(c.janet_abstract_incref(a) == 2);
    std.debug.assert(head.gc.data.refcount == 2);
    std.debug.assert(c.janet_abstract_incref(a) == 3);
    std.debug.assert(head.gc.data.refcount == 3);
    std.debug.assert(c.janet_abstract_decref(a) == 2);
    std.debug.assert(head.gc.data.refcount == 2);
    std.debug.assert(c.janet_abstract_decref(a) == 1);
    std.debug.assert(head.gc.data.refcount == 1);

    std.debug.assert(drop(a) == 0);
}

/// `janet_abstract_decref` does not act on a zero. It is the primitive the
/// caller uses when it intends to decide for itself, and the block survives it
/// -- which is readable, because nothing has freed the header.
fn decrefToZeroDoesNotFree() void {
    threaded_gc_calls = 0;
    const a = c.janet_abstract_threaded(threaded(), 8);
    const head = headOf(a);
    _ = c.janet_table_remove(&c.janet_vm.threaded_abstracts, c.janet_wrap_abstract(a));

    std.debug.assert(c.janet_abstract_decref(a) == 0);
    std.debug.assert(head.gc.data.refcount == 0);
    std.debug.assert(threaded_gc_calls == 0);
    std.debug.assert(head.type == threaded());

    // Drop it properly. The count is zero, so this takes it to -1 and does not
    // free either -- the free is on the transition, and the caller that used
    // the plain primitive owns the block from here.
    std.debug.assert(c.janet_abstract_decref_maybe_free(a) == -1);
    std.debug.assert(threaded_gc_calls == 0);
    c.janet_free(head);
}

/// The last reference frees the block and runs the type's `gc` exactly once.
/// `gcperthread` is not called: that callback belongs to the collector's
/// sweep, which is where an interpreter drops *its* reference, and this path
/// is the value's actual death.
fn decrefMaybeFreeFinalizesOnce() void {
    threaded_gc_calls = 0;
    threaded_gc_data = null;
    threaded_gc_len = 0;
    perthread_calls = 0;
    const a = c.janet_abstract_threaded(threaded(), 24);
    const payload: [*]u8 = @ptrCast(a.?);
    @memset(payload[0..24], 0x7e);

    std.debug.assert(c.janet_abstract_incref(a) == 2);
    std.debug.assert(c.janet_abstract_decref_maybe_free(a) == 1);
    std.debug.assert(threaded_gc_calls == 0);

    std.debug.assert(drop(a) == 0);
    std.debug.assert(threaded_gc_calls == 1);
    std.debug.assert(perthread_calls == 0);

    // The finalizer sees the payload and its recorded length, not the header
    // and not a zero. Both are read out of the header at the moment of the
    // call, which is the last moment either is readable.
    std.debug.assert(threaded_gc_data == a);
    std.debug.assert(threaded_gc_len == 24);
}

/// A type with no `gc` callback is freed without one being looked up.
fn decrefMaybeFreeWithoutAFinalizer() void {
    const a = c.janet_abstract_threaded(threadedBare(), 8);
    std.debug.assert(drop(a) == 0);
}

/// The refcount shares a union with the heap-list link every collectable block
/// uses, and a threaded abstract is on no list, so the two never contend. This
/// pins the layout the port depends on: writing the refcount must not put a
/// plausible pointer in `next`, and the sweep must not find the block by
/// walking.
fn refcountAndListLinkShareOneWord() void {
    const a = c.janet_abstract_threaded(threadedBare(), 8);
    const head = headOf(a);

    std.debug.assert(@intFromPtr(&head.gc.data.refcount) == @intFromPtr(&head.gc.data.next));
    _ = c.janet_abstract_incref(a);
    std.debug.assert(!heap.onList(c.janet_vm.blocks, head));
    std.debug.assert(!heap.onList(c.janet_vm.weak_blocks, head));

    std.debug.assert(c.janet_abstract_decref_maybe_free(a) == 1);
    std.debug.assert(drop(a) == 0);
}

/// The visit record is keyed by the abstract, so two of them are two entries,
/// and the collector can tell them apart. Hashing the key runs the type's
/// `hash` callback when it has one; this type has none, so the pointer hash is
/// what distinguishes them.
fn twoThreadedAbstractsAreTwoEntries() void {
    settle();
    const before = c.janet_vm.threaded_abstracts.count;
    const a = c.janet_abstract_threaded(threadedBare(), 8);
    const b = c.janet_abstract_threaded(threadedBare(), 8);

    std.debug.assert(a != b);
    std.debug.assert(c.janet_vm.threaded_abstracts.count == before + 2);
    std.debug.assert(tracked(a));
    std.debug.assert(tracked(b));

    std.debug.assert(drop(a) == 0);
    std.debug.assert(drop(b) == 0);
}

// ------------------------------------------------------------- teardown

/// Construction has to survive a runtime that is torn down and rebuilt: the
/// charge against `next_collection` and the heap list are both per-VM state.
fn repeatedCycles() void {
    for (0..3) |_| {
        const a = c.janet_abstract(counted(), 16);
        const value = c.janet_wrap_abstract(a);
        c.janet_gcroot(value);
        const t = c.janet_table(4);
        c.janet_table_put(t, c.janet_ckeywordv("abstract"), value);
        c.janet_collect();
        if (has_ev) {
            const th = c.janet_abstract_threaded(threadedBare(), 16);
            std.debug.assert(drop(th) == 0);
        }
        _ = c.janet_gcunroot(value);
        c.janet_deinit();
        _ = c.janet_init();
    }
}

// -------------------------------------------------------------- atomics

/// The four primitives under the refcount above. The C original picked between
/// MSVC intrinsics, `stdatomic.h`, Plan 9's `aincl` and GCC's `__atomic`
/// builtins by preprocessor; the Zig implementation is one `@atomicRmw` per
/// operation, which is why the return convention is worth pinning.
/// `@atomicRmw` answers with the value before the operation and
/// `__atomic_add_fetch` with the value after, so an implementation that forgot
/// to add the delta back would be off by one on every call and still pass
/// every refcount case above -- the counts would be consistently shifted, and
/// only the comparison against zero would notice.
fn atomicsReturnTheNewValue() void {
    var x: c.JanetAtomicInt = 0;

    std.debug.assert(c.janet_atomic_inc(&x) == 1);
    std.debug.assert(c.janet_atomic_inc(&x) == 2);
    std.debug.assert(c.janet_atomic_load(&x) == 2);
    std.debug.assert(c.janet_atomic_load_relaxed(&x) == 2);

    std.debug.assert(c.janet_atomic_dec(&x) == 1);
    std.debug.assert(c.janet_atomic_dec(&x) == 0);
    std.debug.assert(c.janet_atomic_load(&x) == 0);

    // Signed, and nothing stops it going below zero. `janet_abstract_decref`
    // relies on reaching exactly 0, not on saturating there.
    std.debug.assert(c.janet_atomic_dec(&x) == -1);
    std.debug.assert(c.janet_atomic_load_relaxed(&x) == -1);

    x = 41;
    std.debug.assert(c.janet_atomic_inc(&x) == 42);
}

pub fn run() void {
    _ = c.janet_init();

    beginPublishesAnUntypedBlock();
    endTypesTheBlock();
    endPreservesTheOtherFlagBits();
    abstractIsBeginThenEnd();
    zeroLengthAbstract();
    payloadSurvivesEnd();

    collectionBetweenBeginAndEnd();
    theWindowDoesNotStopTheTraversal();
    aFinishedAbstractIsTraversedAndFinalized();

    if (has_ev) {
        beginThreadedRegistersWithoutTheHeap();
        endThreadedChangesNothing();
        abstractThreadedIsBeginThenEnd();
        increfAndDecrefReturnTheNewCount();
        decrefToZeroDoesNotFree();
        decrefMaybeFreeFinalizesOnce();
        decrefMaybeFreeWithoutAFinalizer();
        refcountAndListLinkShareOneWord();
        twoThreadedAbstractsAreTwoEntries();
    }

    atomicsReturnTheNewValue();

    repeatedCycles();

    c.janet_deinit();
}
