//! Stress contract for the two collector behaviours no per-increment contract
//! covers: allocation from inside a GC callback, and the cross-thread
//! facilities.
//!
//! This file is not a subsystem contract. Root categories are covered by
//! `test/gc_alloc.zig`, deep and cyclic graphs by `test/gc_mark.zig`, weak
//! references by `test/gc_sweep.zig`, and repeated init/deinit by the cycle
//! test those files end with. These two are the remainder, and they are here
//! rather than split across three files because both are properties of the
//! collector as a whole rather than of any one function in it.
//!
//! ## What a GC callback may allocate
//!
//! A `gcmark` callback may not keep anything it allocates. The block is
//! prepended to `vm.gc.blocks` with its mark bit clear, and the mark phase
//! reaches objects from the root set rather than by walking that list, so the
//! sweep in the same collection frees it. The object is created and destroyed
//! inside one collection and the caller never sees it live. That is a rule
//! rather than a defect: making it survive would mean marking during the mark
//! phase or deferring the sweep, either of which changes what a collection is.
//!
//! A finalizer may. What it allocates is collected on the next cycle, wherever
//! in the heap list the block being finalized sat. The sweep re-derives the
//! predecessor of the block it is unlinking after the callback rather than
//! trusting the head it saved before it, which is what makes the head case
//! behave like the mid-list one. Both are asserted below, the position
//! dependence being what the two cases exist to rule out.
//!
//! ## The cross-thread half
//!
//! Threaded abstracts are the cross-thread facility. What is asserted is the
//! refcount's atomicity under contention, that each thread's heap is its own,
//! and that the last reference finalizes exactly once no matter which thread
//! drops it.
//!
//! It needs threads and `vm.ev.threaded_abstracts`, so `has_threads` guards
//! it.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");
const builtin = @import("builtin");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const abstract_type = @import("subsystems").abstract_type;
const abstracts = @import("subsystems").value.abstracts;
const arrays = @import("subsystems").value.arrays;
const expect = @import("expect.zig").expect;
const gc_alloc = @import("subsystems").gc_alloc;
const gc_mark = @import("subsystems").gc_mark;
const harness = @import("harness.zig");
const options = @import("options");
const tables = @import("subsystems").value.tables;
const vm_lifecycle = @import("subsystems").lifecycle;
const wrap = @import("subsystems").value.wrap;

// ==========================================================================
// Constants
// ==========================================================================

var allocations_left: i32 = 0;
const at_child = abstract_type.define(anyopaque, .{ .name = "gc-stress/child", .gc = childGc });

const at_finalizing_parent = abstract_type.define(anyopaque, .{
    .name = "gc-stress/finalizing-parent",
    .gc = allocatingGc,
});

const at_marking_parent = abstract_type.define(anyopaque, .{
    .name = "gc-stress/marking-parent",
    .gc = parentGc,
    .gcmark = allocatingGcmark,
});

const at_shared = abstract_type.define(anyopaque, .{ .name = "gc-stress/shared", .gc = threadedGc });
var child_block_count: usize = 0;
var child_finalized: i32 = 0;
var child_saw_main_blocks: usize = 0;

/// `options.ev` is `Config.ev`, which is already `ev and !single_threaded`.
/// Windows is cross-compiled and never executed here, so its path is left out
/// rather than written blind, on the same condition and for the same reason as
/// `test/fiber_core.zig`.
const has_threads = options.ev and builtin.os.tag != .windows;
var parent_finalized: i32 = 0;
var shared_abstract: ?*anyopaque = null;
const stress_rounds = 2000;
const stress_threads = 4;
var threaded_finalized: i32 = 0;

// ==========================================================================
// Cases
// ==========================================================================

fn headerOf(pointer: ?*anyopaque) *abi.GCObject {
    return @ptrCast(@alignCast(pointer.?));
}

/// The length of the main heap list, walked rather than counted.
/// `block_count` is the collector's own tally and the two are supposed to
/// agree; where they do not, a block is on the tally and on no list, which is
/// the leak this file pins. The bound stops a corrupt list from hanging the
/// test.
fn walkBlocks() usize {
    var count: usize = 0;
    var current = harness.vm().gc.blocks;
    while (current != null and count < 1_000_000) {
        count += 1;
        current = @ptrCast(headerOf(current).data.next);
    }
    return count;
}

/// Blocks counted but not reachable from the list. Zero in a healthy runtime.
fn orphanedBlocks() isize {
    return @as(isize, @intCast(harness.vm().gc.block_count)) - @as(isize, @intCast(walkBlocks()));
}

fn childGc(_: *anyopaque, _: usize) void {
    child_finalized += 1;
}

/// A `gcmark` that allocates. Bounded by `allocations_left` so that marking
/// terminates: without the bound each new block would be marked in turn and
/// the callback would allocate forever.
fn allocatingGcmark(_: *anyopaque, _: usize) void {
    if (allocations_left > 0) {
        allocations_left -= 1;
        _ = abstracts.newBytes(&at_child, 8);
    }
}

fn parentGc(_: *anyopaque, _: usize) void {
    parent_finalized += 1;
}

/// A finalizer that allocates while the sweep is walking the block list.
fn allocatingGc(_: *anyopaque, _: usize) void {
    parent_finalized += 1;
    if (allocations_left > 0) {
        allocations_left -= 1;
        _ = abstracts.newBytes(&at_child, 8);
    }
}

fn threadedGc(_: *anyopaque, _: usize) void {
    threaded_finalized += 1;
}

/// An object allocated from `gcmark` is freed by the collection that ran the
/// callback. The mark phase has already passed the head of the list by the
/// time the block is prepended, so nothing marks it, and the sweep in the same
/// `collect` frees it and runs its finalizer.
///
/// The finalizer count is what makes this observable without touching the
/// freed block: a third-party `gcmark` that allocated something and stored it
/// would be left with a dangling pointer, and there is no safe way to read
/// that.
fn allocationFromGcmarkDiesInTheSameCollection() void {
    const orphans_before = orphanedBlocks();

    child_finalized = 0;
    parent_finalized = 0;
    allocations_left = 1;

    const parent = wrap.fromAbstract(abstracts.newBytes(&at_marking_parent, 8));
    gc_alloc.gcroot(parent);

    gc_mark.collect();
    expect(allocations_left == 0); // the callback ran
    expect(child_finalized == 1); // and what it made is already gone
    expect(parent_finalized == 0); // the parent itself is rooted
    expect(orphanedBlocks() == orphans_before);

    _ = gc_alloc.gcunroot(parent);
    gc_mark.collect();
    expect(parent_finalized == 1);
    expect(child_finalized == 1); // nothing further to finalize
}

/// A finalizer that allocates while its own block is *not* at the head of the
/// list behaves correctly. The prepend lands ahead of the sweep's walk
/// position, so the new block survives this collection untouched and is
/// collected on the next one, having never been marked.
///
/// The keeper is allocated after the dying block and rooted, so it is the head
/// and is retained, which is what puts the dying block mid-list with a
/// non-null predecessor.
fn finalizerAllocationSurvivesWhenMidList() void {
    const orphans_before = orphanedBlocks();

    child_finalized = 0;
    parent_finalized = 0;
    allocations_left = 1;

    _ = abstracts.newBytes(&at_finalizing_parent, 8); // unrooted: dies
    const keeper = wrap.fromAbstract(abstracts.newBytes(&at_child, 8));
    gc_alloc.gcroot(keeper);

    gc_mark.collect();
    expect(parent_finalized == 1);
    expect(allocations_left == 0);
    expect(child_finalized == 0); // survived this cycle
    expect(orphanedBlocks() == orphans_before); // and is on the list

    gc_mark.collect();
    expect(child_finalized == 1); // collected on the next
    expect(orphanedBlocks() == orphans_before);

    _ = gc_alloc.gcunroot(keeper);
    gc_mark.collect();
    expect(child_finalized == 2); // the keeper, in turn
    expect(orphanedBlocks() == orphans_before);
}

/// The case the position dependence turned on: the block being finalized *is*
/// the head of the heap list, so the finalizer's own allocation is prepended
/// in front of it and the head the sweep saved before the callback is stale.
///
/// What is asserted is that it behaves like the mid-list case: the new block
/// is on the list, is collected on the next cycle, and the gap between
/// `block_count` and the walked list never opens.
fn finalizerAllocationSurvivesAtTheHead() void {
    const orphans_before = orphanedBlocks();

    child_finalized = 0;
    parent_finalized = 0;
    allocations_left = 1;

    // Allocated last and left unrooted, so it is both the list head and dead.
    _ = abstracts.newBytes(&at_finalizing_parent, 8);

    gc_mark.collect();
    expect(parent_finalized == 1);
    expect(allocations_left == 0); // the callback allocated
    expect(child_finalized == 0); // and it survived this collection
    expect(orphanedBlocks() == orphans_before); // on the list, and counted once

    gc_mark.collect();
    expect(child_finalized == 1); // collected on the next
    expect(orphanedBlocks() == orphans_before);
}

/// Each worker runs its own runtime, which is what a real second thread does.
/// The reference it takes is balanced before it exits, so the count returns to
/// exactly what the main thread left.
fn hammerRefcount() void {
    harness.init();
    for (0..stress_rounds) |_| {
        _ = abstracts.incref(shared_abstract);
        _ = abstracts.decref(shared_abstract);
    }
    vm_lifecycle.deinit();
}

/// The refcount is the whole cross-thread contract for a threaded abstract,
/// and it is the one thing here that a non-atomic implementation would still
/// pass every single-threaded test with. Four threads take and drop a
/// reference two thousand times each; a lost update shows up as a count that
/// is not one.
fn theRefcountIsAtomicAcrossThreads() !void {
    shared_abstract = abstracts.threaded(&at_shared, 16);

    var threads: [stress_threads]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, hammerRefcount, .{});
    for (threads) |thread| thread.join();

    // Back to the single reference this thread made it with.
    expect(abstracts.incref(shared_abstract) == 2);
    expect(abstracts.decref(shared_abstract) == 1);
}

fn allocateInChild() void {
    child_saw_main_blocks = harness.vm().gc.block_count;
    harness.init();
    for (0..64) |_| _ = arrays.new(8);
    child_block_count = harness.vm().gc.block_count;
    gc_mark.collect();
    vm_lifecycle.deinit();
}

/// Each thread's heap belongs to that thread. A port that reached a
/// process-wide VM rather than the thread-local one would still pass
/// every other test in the tree: the damage is invisible until two runtimes
/// exist at once, and then it is heap corruption rather than a wrong count.
fn eachThreadHasItsOwnHeap() !void {
    const main_blocks_before = harness.vm().gc.block_count;
    const main_walk_before = walkBlocks();

    const thread = try std.Thread.spawn(.{}, allocateInChild, .{});
    thread.join();

    // Before its own `vm_lifecycle.init`, the child's VM is zeroed rather
    // than shared.
    expect(child_saw_main_blocks == 0);
    expect(child_block_count >= 64);
    // And nothing it did touched this thread's heap.
    expect(harness.vm().gc.block_count == main_blocks_before);
    expect(walkBlocks() == main_walk_before);
}

/// The finalizer runs on whichever thread drops the last reference, exactly
/// once. This one drops it on the main thread; the point is the count, not the
/// thread identity, which no part of the runtime promises.
fn theLastReferenceFinalizesOnce() !void {
    const abstract = abstracts.threaded(&at_shared, 16);

    threaded_finalized = 0;
    shared_abstract = abstract;

    const thread = try std.Thread.spawn(.{}, hammerRefcount, .{});
    thread.join();
    expect(threaded_finalized == 0);

    // This thread still has the reference it was made with. Dropping it is
    // what frees the block and runs the finalizer.
    _ = tables.remove(&harness.vm().ev.threaded_abstracts, wrap.fromAbstract(abstract));
    expect(abstracts.decrefMaybeFree(abstract) == 0);
    expect(threaded_finalized == 1);
}

/// Every collector contract ends by cycling the runtime, and this one has more
/// reason than most: the callbacks above run during collection, and a state
/// they corrupted would show up as a heap that stops being walkable.
fn repeatedCycles() void {
    for (0..32) |_| {
        const orphans_before = orphanedBlocks();

        child_finalized = 0;
        parent_finalized = 0;
        allocations_left = 1;

        const parent = wrap.fromAbstract(
            abstracts.newBytes(&at_marking_parent, 8),
        );
        gc_alloc.gcroot(parent);
        gc_mark.collect();
        expect(child_finalized == 1);
        _ = gc_alloc.gcunroot(parent);
        gc_mark.collect();
        expect(parent_finalized == 1);
        expect(orphanedBlocks() == orphans_before);
    }
}

// ==========================================================================
// Entry
// ==========================================================================

fn body() !void {
    expect(orphanedBlocks() == 0);

    allocationFromGcmarkDiesInTheSameCollection();
    finalizerAllocationSurvivesWhenMidList();
    finalizerAllocationSurvivesAtTheHead();

    if (has_threads) {
        try theRefcountIsAtomicAcrossThreads();
        try eachThreadHasItsOwnHeap();
        try theLastReferenceFinalizesOnce();
    }

    repeatedCycles();
}

pub fn run() void {
    harness.init();
    gc_alloc.gcroot(wrap.fromTable(harness.coreEnv()));

    body() catch @panic("gc_stress: a thread could not be started");

    vm_lifecycle.deinit();
}
