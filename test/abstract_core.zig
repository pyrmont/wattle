//! Behavioral contract for abstract value construction and the threaded
//! abstract refcount: `abstracts.beginBytes`, `abstracts.end`,
//! `abstracts.newBytes`, their threaded counterparts, and `abstracts.incref`,
//! `abstracts.decref` and `abstracts.decrefMaybeFree`.
//!
//! These nine functions are almost all bookkeeping, and bookkeeping is what
//! has to be checked, because the return values agree between a correct
//! implementation and several wrong ones. Four channels reach it:
//!
//!  - `abi.abstractHead` recovers the header, so `size`, `type` and the raw
//!    `gc.flags` word are readable directly. The flags word is where the
//!    difference between `abstracts.end`'s `|=` and a plain store shows up,
//!    and nothing else observes it.
//!  - `vm.gc.blocks` and `vm.gc.block_count` say whether the collector
//!    was given the block. A plain abstract must be on the list; a threaded
//!    one must be on neither list.
//!  - `vm.gc.next_collection` says what the block was charged, and the two
//!    allocators charge it by different arithmetic to the same total.
//!  - `vm.ev.threaded_abstracts` is the visit record a threaded abstract is
//!    registered in at birth, and the type's `gc` callback counts its own
//!    calls on the way out.
//!
//! The two-step protocol gets a case of its own because it is the only reason
//! `beginBytes` exists separately from `newBytes`: a collection between the two
//! calls must free the block without traversing or finalizing it, and an
//! abstract type whose `gcmark` and `gc` count their calls is what proves it.
//!
//! ## The probe types
//!
//! `abstract_type.define` takes Zig callbacks, so the four probe types below
//! are ordinary declarations over the runtime's own `AbstractType`. This file
//! needs `gc`, `gcmark` and `gcperthread`, all three typed non-raising for a
//! reason `abstract_type.zig` sets out: a raise from a finalizer runs
//! mid-sweep on an object that is already unreachable, so it has nowhere to
//! go.
//!
//! ## The head offset is measured rather than asserted
//!
//! What would say the header is exactly its own size is that the size equals
//! the offset of `data`. A head with a flexible array member loses it in
//! translation, so `@offsetOf` does not compile against one and the header is
//! recovered with `@sizeOf`, which makes the comparison `@sizeOf` against
//! itself. `test/gc_mark.zig`'s `theHeadOffsets` derives the offset from the
//! allocator and compares it against `@sizeOf`, which is the claim worth
//! making.
//!
//! Nothing exercises a raising callback: an abstract callback may not raise.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const abstract_type = @import("subsystems").abstract_type;
const abstracts = @import("subsystems").value.abstracts;
const constants = @import("constants");
const expect = @import("expect.zig").expect;
const gc_alloc = @import("subsystems").gc_alloc;
const gc_mark = @import("subsystems").gc_mark;
const harness = @import("harness.zig");
const heap = harness.heap;
const options = @import("options");
const repr = @import("repr");
const tables = @import("subsystems").value.tables;
const utils = @import("subsystems").utils;
const value = @import("subsystems").value;
const vm_lifecycle = @import("subsystems").lifecycle;
const wrap = @import("subsystems").value.wrap;

// ==========================================================================
// Constants
// ==========================================================================

/// The same type with no callbacks at all. Freeing one of these must not reach
/// for a null function pointer.
const at_bare = abstract_type.define(anyopaque, .{ .name = "abstract-core-test/bare" });

const at_counted = abstract_type.define(anyopaque, .{
    .name = "abstract-core-test/counted",
    .gc = probeGc,
    .gcmark = probeGcmark,
    .gcperthread = probePerthread,
});

const at_threaded = abstract_type.define(anyopaque, .{
    .name = "abstract-core-test/threaded",
    .gc = probeThreadedGc,
    .gcmark = probeGcmark,
});

const at_threaded_bare = abstract_type.define(anyopaque, .{ .name = "abstract-core-test/threaded-bare" });
var gc_calls: i32 = 0;

/// The threaded half of this subsystem exists only with the event loop.
/// `options` names subsystems rather than features, so `ev` is the field
/// `Config.ev` is recorded in.
const has_ev = options.ev;

var mark_calls: i32 = 0;
var perthread_calls: i32 = 0;
var threaded_gc_calls: i32 = 0;
var threaded_gc_data: ?*anyopaque = null;
var threaded_gc_len: usize = 0;

// ==========================================================================
// Cases
// ==========================================================================

/// Reach a quiet heap, so that a later collection's effects are attributable
/// to what this case made rather than to what an earlier one left behind.
fn settle() void {
    gc_mark.collect();
    gc_mark.collect();
}

fn probeGcmark(_: *anyopaque, _: usize) void {
    mark_calls += 1;
}

fn probeGc(_: *anyopaque, _: usize) void {
    gc_calls += 1;
}

fn probePerthread(_: *anyopaque, _: usize) void {
    perthread_calls += 1;
}

/// The finalizer records what it was handed. `abstracts.decrefMaybeFree`
/// calls it with the head's payload pointer and its `size`, and both arguments
/// are easy to get wrong in a way no return value reveals: the header is one
/// word from the payload, and `size` is the only place the payload's length is
/// recorded once the caller has let go of it.
fn probeThreadedGc(data: *anyopaque, length: usize) void {
    threaded_gc_data = data;
    threaded_gc_len = length;
    threaded_gc_calls += 1;
}

fn counted() *const abi.AbstractType {
    return &at_counted;
}

fn bare() *const abi.AbstractType {
    return &at_bare;
}

fn threaded() *const abi.AbstractType {
    return &at_threaded;
}

fn threadedBare() *const abi.AbstractType {
    return &at_threaded_bare;
}

fn headOf(abstract: ?*anyopaque) *abi.AbstractHead {
    return utils.abstractHead(abstract);
}

/// Drop this interpreter's reference the way the sweep does: take the entry
/// out of the visit record first, then decrement. The order matters, because
/// freeing the block while `vm.ev.threaded_abstracts` is still keyed on it
/// leaves the next collection reading a freed header. Every threaded case here
/// ends this way rather than by calling `abstracts.decrefMaybeFree` alone.
fn drop(a: ?*anyopaque) i32 {
    _ = tables.remove(&harness.vm().ev.threaded_abstracts, wrap.fromAbstract(a));
    return abstracts.decrefMaybeFree(a);
}

/// Whether the visit record has an entry for this abstract. `tables.get`
/// returns nil for an absent key and the stored boolean for a present one, and
/// the sweep tells the two apart, so this does as well.
fn tracked(a: ?*anyopaque) bool {
    const entry = tables.get(&harness.vm().ev.threaded_abstracts, wrap.fromAbstract(a));
    return !harness.isType(entry, repr.Tag.nil);
}

/// `abstracts.beginBytes` writes the two header fields and nothing else, and
/// hands the block to the collector tagged `MemoryType.none`. The tag is the
/// whole point: the payload is uninitialised at this moment and the block is
/// already reachable from `vm.gc.blocks`.
fn beginPublishesAnUntypedBlock() void {
    settle();
    const before_count = harness.vm().gc.block_count;
    const before_charge = harness.vm().gc.next_collection;

    const a = abstracts.beginBytes(counted(), 40);
    const head = headOf(a);

    expect(head.size == 40);
    expect(head.type == counted());
    expect(heap.memoryType(head) == gc_alloc.MemoryType.none);
    expect(harness.gcBits(head.gc.flags) & constants.JANET_MEM_REACHABLE == 0);

    expect(harness.vm().gc.block_count == before_count + 1);
    expect(heap.onList(harness.vm().gc.blocks, head));
    expect(!heap.onList(harness.vm().gc.weak_blocks, head));
    expect(harness.vm().gc.next_collection ==
        before_charge + @sizeOf(abi.AbstractHead) + 40);

    // `long long data[]` is the most general alignment the header can ask for,
    // so the payload is aligned for anything an embedder puts in it.
    expect(@intFromPtr(a) % @sizeOf(c_longlong) == 0);

    _ = abstracts.end(a);
}

/// `abstracts.end` writes the type tag and returns the same pointer.
fn endTypesTheBlock() void {
    const a = abstracts.beginBytes(counted(), 8);
    const head = headOf(a);
    expect(heap.memoryType(head) == gc_alloc.MemoryType.none);

    const b = abstracts.end(a);
    expect(b == a);
    expect(heap.memoryType(head) == gc_alloc.MemoryType.abstract);
    expect(head.size == 8);
    expect(head.type == counted());
}

/// `end` leaves the other flag bits alone. A block marked reachable by a
/// collection that ran between `begin` and `end` must still be marked
/// afterwards, or the sweep frees a block the caller is about to use.
///
/// The assertion reads the whole 32-bit word through `harness.gcBits`, and
/// that is the only form of it worth writing. `abstracts.gcSetType` writes
/// `head.gc.flags.type`, a `u8` field of a `packed struct(u32)` whose
/// `reachable` and `disabled` are separate fields, so its `|=` and a plain
/// store are indistinguishable here and neither could disturb them. What the
/// word-level read still catches is an implementation that went back to one
/// flag word for all of it.
fn endPreservesTheOtherFlagBits() void {
    const a = abstracts.beginBytes(counted(), 8);
    const head = headOf(a);

    harness.gcSetBits(&head.gc.flags, constants.JANET_MEM_REACHABLE);
    harness.gcSetBits(&head.gc.flags, constants.JANET_MEM_DISABLED);

    _ = abstracts.end(a);
    expect(heap.memoryType(head) == gc_alloc.MemoryType.abstract);
    expect(harness.gcBits(head.gc.flags) & constants.JANET_MEM_REACHABLE != 0);
    expect(harness.gcBits(head.gc.flags) & constants.JANET_MEM_DISABLED != 0);

    // Leave nothing marked or disabled behind for the next case.
    head.gc.flags = @bitCast(harness.gcBits(head.gc.flags) &
        ~@as(u32, constants.JANET_MEM_REACHABLE | constants.JANET_MEM_DISABLED));
}

/// `janet_abstract` is the two calls in one, and must charge and tag exactly
/// as they do separately.
fn abstractIsBeginThenEnd() void {
    settle();
    const before_count = harness.vm().gc.block_count;
    const before_charge = harness.vm().gc.next_collection;

    const a = abstracts.newBytes(counted(), 24);
    const head = headOf(a);

    expect(heap.memoryType(head) == gc_alloc.MemoryType.abstract);
    expect(head.size == 24);
    expect(head.type == counted());
    expect(harness.vm().gc.block_count == before_count + 1);
    expect(heap.onList(harness.vm().gc.blocks, head));
    expect(harness.vm().gc.next_collection ==
        before_charge + @sizeOf(abi.AbstractHead) + 24);
}

/// A zero-length abstract is a header and nothing else, and is legal.
fn zeroLengthAbstract() void {
    const a = abstracts.newBytes(bare(), 0);
    const head = headOf(a);
    expect(head.size == 0);
    expect(heap.memoryType(head) == gc_alloc.MemoryType.abstract);
}

/// The payload is untouched by construction, so an embedder that writes it
/// before `abstracts.end` finds it intact afterwards.
fn payloadSurvivesEnd() void {
    const a = abstracts.beginBytes(bare(), 16);
    const payload: [*]u8 = @ptrCast(a);
    @memset(payload[0..16], 0x5a);
    _ = abstracts.end(a);
    for (payload[0..16]) |byte| expect(byte == 0x5a);
}

/// The reason `begin` and `end` are separate. A block tagged
/// `MemoryType.none` is on the heap list and visible to the collector with
/// an uninitialised payload, and what makes that safe is the sweep rather than
/// the mark phase: `gc/sweep.zig`'s `deinitBlock` lists that tag in the arm
/// that does nothing, so the block is freed without its finalizer running and
/// without anything reading a field of the payload. An abstract type whose
/// `gc` frees a pointer it has not been given yet is the crash this prevents.
fn collectionBetweenBeginAndEnd() void {
    settle();
    mark_calls = 0;
    gc_calls = 0;
    perthread_calls = 0;

    const counted_before = harness.vm().gc.block_count;
    _ = abstracts.beginBytes(counted(), 32);
    expect(harness.vm().gc.block_count == counted_before + 1);

    // Nothing refers to it, so the collection frees it. It is untyped, so
    // neither finalizer runs and the payload is never read.
    gc_mark.collect();
    expect(harness.vm().gc.block_count == counted_before);
    expect(mark_calls == 0);
    expect(gc_calls == 0);
    expect(perthread_calls == 0);
}

/// What the tag does *not* do is keep the traversal away. The mark phase
/// dispatches on the type of the value it is given, not on the block's memory
/// tag, so an embedder that wraps and roots the block before filling it in
/// gets `gcmark` called on an uninitialised payload. That is deliberate, and
/// the caller's obligation is to root the value after `abstracts.end` rather
/// than before. Pinned here so that a runtime which tagged the block early to
/// avoid it would be caught.
fn theWindowDoesNotStopTheTraversal() void {
    settle();
    mark_calls = 0;
    gc_calls = 0;
    perthread_calls = 0;

    const a = abstracts.beginBytes(counted(), 32);
    const val = wrap.fromAbstract(a);
    gc_alloc.gcroot(val);

    const counted_before = harness.vm().gc.block_count;
    gc_mark.collect();

    expect(harness.vm().gc.block_count == counted_before);
    expect(mark_calls == 1);
    expect(gc_calls == 0);
    expect(heap.memoryType(headOf(a)) == gc_alloc.MemoryType.none);

    _ = gc_alloc.gcunroot(val);
    gc_mark.collect();

    // Freed, and still never finalized: the sweep is where the tag decides.
    expect(harness.vm().gc.block_count == counted_before - 1);
    expect(gc_calls == 0);
    expect(perthread_calls == 0);
}

/// Once `abstracts.end` has run, the same block is traversed and
/// finalized like any other abstract. Without this, an implementation that
/// never tags the block at all passes every case above.
fn aFinishedAbstractIsTraversedAndFinalized() void {
    settle();
    mark_calls = 0;
    gc_calls = 0;
    perthread_calls = 0;

    const a = abstracts.newBytes(counted(), 32);
    const val = wrap.fromAbstract(a);
    gc_alloc.gcroot(val);

    gc_mark.collect();
    expect(mark_calls == 1);
    expect(gc_calls == 0);

    _ = gc_alloc.gcunroot(val);
    gc_mark.collect();
    expect(gc_calls == 1);
    expect(perthread_calls == 1);
}

/// A threaded abstract comes from the plain heap allocator rather than from
/// `gc.gcallocWithPayload`. It is on neither heap list and the block count does
/// not move: the visit table is what records it, and the refcount that starts
/// at one is what keeps it alive.
fn beginThreadedRegistersWithoutTheHeap() void {
    settle();
    const before_count = harness.vm().gc.block_count;
    const before_charge = harness.vm().gc.next_collection;
    const before_tracked = harness.vm().ev.threaded_abstracts.count;
    const before_capacity = harness.vm().ev.threaded_abstracts.capacity;

    const a = abstracts.beginThreaded(harness.vm(), threadedBare(), 48);
    const head = headOf(a);

    expect(head.size == 48);
    expect(head.type == threadedBare());
    expect(heap.memoryType(head) == gc_alloc.MemoryType.threaded_abstract);
    expect(head.gc.data.refcount == 1);

    expect(harness.vm().gc.block_count == before_count);
    expect(!heap.onList(harness.vm().gc.blocks, head));
    expect(!heap.onList(harness.vm().gc.weak_blocks, head));

    // The threaded path adds `size + @sizeOf(head)` by hand where
    // `gc.gcallocBytes` adds the size it was asked for. Same total, plus
    // whatever the visit table charged if this entry made it rehash, since
    // `value.memallocEmpty` bills its new bucket array to the same counter.
    var table_charge: usize = 0;
    if (harness.vm().ev.threaded_abstracts.capacity != before_capacity) {
        table_charge = @as(usize, @intCast(harness.vm().ev.threaded_abstracts.capacity)) * @sizeOf(tables.KV);
    }
    expect(harness.vm().gc.next_collection ==
        before_charge + @sizeOf(abi.AbstractHead) + 48 + table_charge);

    expect(harness.vm().ev.threaded_abstracts.count == before_tracked + 1);
    expect(tracked(a));

    // Registered false: the visit record starts unvisited, and a mark phase is
    // what sets it.
    const entry = tables.get(&harness.vm().ev.threaded_abstracts, wrap.fromAbstract(a));
    expect(harness.isType(entry, repr.Tag.boolean));
    expect(!wrap.toBoolean(entry));

    expect(@intFromPtr(a) % @sizeOf(c_longlong) == 0);

    _ = abstracts.endThreaded(a);
    expect(drop(a) == 0);
}

/// `abstracts.endThreaded` sets a tag `beginThreaded` has already set, so the
/// only observable requirement is that it changes nothing and returns its
/// argument. An implementation that stored `MemoryType.abstract` instead
/// would put a malloced block on the collector's abstract path, which is a
/// double free.
fn endThreadedChangesNothing() void {
    const a = abstracts.beginThreaded(harness.vm(), threadedBare(), 8);
    const head = headOf(a);
    const flags_before = head.gc.flags;

    const b = abstracts.endThreaded(a);
    expect(b == a);
    expect(head.gc.flags == flags_before);
    expect(heap.memoryType(head) == gc_alloc.MemoryType.threaded_abstract);
    expect(head.gc.data.refcount == 1);

    expect(drop(a) == 0);
}

fn abstractThreadedIsBeginThenEnd() void {
    settle();
    const before_tracked = harness.vm().ev.threaded_abstracts.count;
    const before_count = harness.vm().gc.block_count;

    const a = abstracts.threaded(threadedBare(), 16);
    const head = headOf(a);

    expect(heap.memoryType(head) == gc_alloc.MemoryType.threaded_abstract);
    expect(head.size == 16);
    expect(head.gc.data.refcount == 1);
    expect(harness.vm().gc.block_count == before_count);
    expect(harness.vm().ev.threaded_abstracts.count == before_tracked + 1);
    expect(tracked(a));

    expect(drop(a) == 0);
}

/// Both primitives return the value *after* their own change, not before, and
/// both write it through to the header.
fn increfAndDecrefReturnTheNewCount() void {
    const a = abstracts.threaded(threadedBare(), 8);
    const head = headOf(a);

    expect(abstracts.incref(a) == 2);
    expect(head.gc.data.refcount == 2);
    expect(abstracts.incref(a) == 3);
    expect(head.gc.data.refcount == 3);
    expect(abstracts.decref(a) == 2);
    expect(head.gc.data.refcount == 2);
    expect(abstracts.decref(a) == 1);
    expect(head.gc.data.refcount == 1);

    expect(drop(a) == 0);
}

/// `abstracts.decref` does not act on a zero. It is the primitive a caller
/// reaches for when it means to decide for itself, and the block survives it,
/// which is readable because nothing has freed the header.
fn decrefToZeroDoesNotFree() void {
    threaded_gc_calls = 0;
    const a = abstracts.threaded(threaded(), 8);
    const head = headOf(a);
    _ = tables.remove(&harness.vm().ev.threaded_abstracts, wrap.fromAbstract(a));

    expect(abstracts.decref(a) == 0);
    expect(head.gc.data.refcount == 0);
    expect(threaded_gc_calls == 0);
    expect(head.type == threaded());

    // Drop it properly. The count is zero, so this takes it to -1 and does
    // not free either: the free is on the transition, and the caller that used
    // the plain primitive owns the block from here.
    expect(abstracts.decrefMaybeFree(a) == -1);
    expect(threaded_gc_calls == 0);
    utils.free(head);
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
    const a = abstracts.threaded(threaded(), 24);
    const payload: [*]u8 = @ptrCast(a.?);
    @memset(payload[0..24], 0x7e);

    expect(abstracts.incref(a) == 2);
    expect(abstracts.decrefMaybeFree(a) == 1);
    expect(threaded_gc_calls == 0);

    expect(drop(a) == 0);
    expect(threaded_gc_calls == 1);
    expect(perthread_calls == 0);

    // The finalizer sees the payload and its recorded length, not the header
    // and not a zero. Both are read out of the header at the moment of the
    // call, which is the last moment either is readable.
    expect(threaded_gc_data == a);
    expect(threaded_gc_len == 24);
}

/// A type with no `gc` callback is freed without one being looked up.
fn decrefMaybeFreeWithoutAFinalizer() void {
    const a = abstracts.threaded(threadedBare(), 8);
    expect(drop(a) == 0);
}

/// The refcount shares a union with the heap-list link every collectable block
/// uses, and a threaded abstract is on no list, so the two never contend. This
/// pins the layout the runtime depends on: writing the refcount must not put a
/// plausible pointer in `next`, and the sweep must not find the block by
/// walking.
fn refcountAndListLinkShareOneWord() void {
    const a = abstracts.threaded(threadedBare(), 8);
    const head = headOf(a);

    expect(@intFromPtr(&head.gc.data.refcount) == @intFromPtr(&head.gc.data.next));
    _ = abstracts.incref(a);
    expect(!heap.onList(harness.vm().gc.blocks, head));
    expect(!heap.onList(harness.vm().gc.weak_blocks, head));

    expect(abstracts.decrefMaybeFree(a) == 1);
    expect(drop(a) == 0);
}

/// The visit record is keyed by the abstract, so two of them are two entries,
/// and the collector can tell them apart. Hashing the key runs the type's
/// `hash` callback when it has one; this type has none, so the pointer hash is
/// what distinguishes them.
fn twoThreadedAbstractsAreTwoEntries() void {
    settle();
    const before = harness.vm().ev.threaded_abstracts.count;
    const a = abstracts.threaded(threadedBare(), 8);
    const b = abstracts.threaded(threadedBare(), 8);

    expect(a != b);
    expect(harness.vm().ev.threaded_abstracts.count == before + 2);
    expect(tracked(a));
    expect(tracked(b));

    expect(drop(a) == 0);
    expect(drop(b) == 0);
}

/// The four primitives under the refcount above, and what they return.
///
/// Each is one `@atomicRmw`, which gives back the value *before* the
/// operation, and each of these four gives back the value after. An
/// implementation that forgot to add the delta back would be off by one on
/// every call and would still pass every refcount case above, the counts being
/// consistently shifted; only a comparison against zero would notice. That is
/// what makes the return convention worth pinning here.
fn atomicsReturnTheNewValue() void {
    var x: abi.AtomicInt = 0;

    expect(abstracts.atomicInc(&x) == 1);
    expect(abstracts.atomicInc(&x) == 2);
    expect(abstracts.atomicLoad(&x) == 2);
    expect(abstracts.atomicLoadRelaxed(&x) == 2);

    expect(abstracts.atomicDec(&x) == 1);
    expect(abstracts.atomicDec(&x) == 0);
    expect(abstracts.atomicLoad(&x) == 0);

    // Signed, and nothing stops it going below zero. `abstracts.decref`
    // relies on reaching exactly 0, not on saturating there.
    expect(abstracts.atomicDec(&x) == -1);
    expect(abstracts.atomicLoadRelaxed(&x) == -1);

    x = 41;
    expect(abstracts.atomicInc(&x) == 42);

    // The refcount is 32 bits on every target: janet.h declares
    // `JanetAtomicInt` as `int32_t`, or as a 32-bit `long` on Windows. So the
    // count wraps at 2^31.
    x = std.math.maxInt(i32);
    expect(abstracts.atomicInc(&x) == std.math.minInt(i32));
}

/// Construction has to survive a runtime that is torn down and rebuilt: the
/// charge against `next_collection` and the heap list are both per-VM state.
fn repeatedCycles() void {
    for (0..3) |_| {
        const a = abstracts.newBytes(counted(), 16);
        const val = wrap.fromAbstract(a);
        gc_alloc.gcroot(val);
        const t = tables.new(4);
        tables.put(t, value.fromBytes("abstract", .keyword), val);
        gc_mark.collect();
        if (has_ev) {
            const th = abstracts.threaded(threadedBare(), 16);
            expect(drop(th) == 0);
        }
        _ = gc_alloc.gcunroot(val);
        vm_lifecycle.deinit();
        harness.init();
    }
}

// ==========================================================================
// Entry
// ==========================================================================

pub fn run() void {
    harness.init();

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

    vm_lifecycle.deinit();
}
