//! Behavioral contract for the collector's memory: block allocation and the
//! two heap lists, the root set, the GC suspend counter, and the scratch
//! allocator.
//!
//! Every operation under test is a mutation of `janet_vm`'s collection fields,
//! and the fields are the observable result. There is no public accessor for
//! `block_count` or `scratch_len`, and inventing one would test the accessor —
//! so this file reads `janet_vm` directly, which the Zig driver can do because
//! it *is* the runtime's compilation.
//!
//! Two things are deliberately not exercised. Nothing here lets a synthetic
//! block reach `janet_sweep`: each allocation case unlinks what it made and
//! restores the counters, so the contract stays independent of marking and
//! sweeping. And the two fatal paths — `janet_srealloc` and `janet_sfree` on a
//! pointer this allocator never handed out — abort the process, so they are
//! described here rather than run.
//!
//! ## The header arithmetic has a real oracle here
//!
//! `JanetScratch` ends in a flexible array, so `@cImport` drops the member and
//! Zig recovers the header with `@sizeOf` — the same assumption `gc_mark.zig`
//! and `gc_sweep.zig` make about the four value heads. In this file the
//! assumption is *checked* rather than assumed, and by the allocator itself:
//! `janet_smalloc` registers the header in `scratch_mem` and returns a pointer
//! into it, so `scratch_mem[base] == headerOf(p)` compares Zig's arithmetic
//! against an address the runtime recorded. `test/gc_mark.zig` explains what
//! had to be built to get the same guarantee for the value heads.

const std = @import("std");
const types = @import("types");
const constants = @import("constants");
const harness = @import("harness.zig");
const gc_alloc = @import("subsystems").gc_alloc;
const utils = @import("subsystems").utils;
const gc_mark = @import("subsystems").gc_mark;
const wrap = @import("subsystems").value.wrap;
const vm_lifecycle = @import("subsystems").lifecycle;
const arrays = @import("subsystems").value.arrays;

/// The scratch header sits exactly one header below the pointer the caller
/// holds. That relationship is the whole allocator: `janet_srealloc`,
/// `janet_sfree` and `janet_sfinalizer` all recover it by subtraction.
fn headerOf(memory: ?*anyopaque) *types.JanetScratch {
    return @ptrFromInt(@intFromPtr(memory) - @sizeOf(types.JanetScratch));
}

/// Where the runtime recorded `memory`'s header, or null if it did not.
fn scratchIndexOf(memory: ?*anyopaque) ?usize {
    const want = headerOf(memory);
    var index: usize = 0;
    while (index < harness.vm().scratch.count) : (index += 1) {
        if (harness.vm().scratch.at(index).* == want) return index;
    }
    return null;
}

/// `state.h` types both heap list heads as `void *`, so list identity is
/// compared as an opaque pointer and cast only where a field is wanted.
fn asBlock(pointer: ?*anyopaque) *types.JanetGCObject {
    return @ptrCast(@alignCast(pointer.?));
}

fn nextOf(block: *types.JanetGCObject) ?*anyopaque {
    return @ptrCast(block.data.next);
}

/// Undo one allocation, restoring every field it moved. Only valid for the
/// block at the head of its list, which is where `janet_gcalloc` just put it.
fn unlinkHead(weak: bool, size: usize) void {
    const head = asBlock(if (weak) harness.vm().gc.weak_blocks else harness.vm().gc.blocks);
    if (weak) {
        harness.vm().gc.weak_blocks = nextOf(head);
    } else {
        harness.vm().gc.blocks = nextOf(head);
    }
    harness.vm().gc.block_count -= 1;
    harness.vm().gc.next_collection -= size;
    utils.free(head);
}

fn typeOf(block: *types.JanetGCObject) types.MemoryType {
    return block.memoryType();
}

fn isReachable(block: *types.JanetGCObject) bool {
    return block.flags & constants.JANET_MEM_REACHABLE != 0;
}

/// The only thing `janet_gcpressure` does is move the threshold. It must not
/// collect, and it must not touch the block count — the bytes it is told about
/// were allocated outside the collector's accounting.
fn theGcPressure() void {
    const before = harness.vm().gc.next_collection;
    const blocks = harness.vm().gc.block_count;

    gc_alloc.gcpressure(0);
    std.debug.assert(harness.vm().gc.next_collection == before);

    gc_alloc.gcpressure(4096);
    std.debug.assert(harness.vm().gc.next_collection == before + 4096);
    std.debug.assert(harness.vm().gc.block_count == blocks);

    harness.vm().gc.next_collection = before;
}

/// A new block goes on the front of the normal heap, carries its type in the
/// low byte of `flags` and nothing else, and is counted. It is emphatically
/// not marked: the caller has not filled it in yet, and a collection that
/// treated it as reachable would trace uninitialised memory.
fn aNewBlockGoesOnTheNormalHeap() void {
    const size = 128;
    const previous = harness.vm().gc.blocks;
    const count = harness.vm().gc.block_count;
    const next = harness.vm().gc.next_collection;
    const weak = harness.vm().gc.weak_blocks;

    const block: *types.JanetGCObject = @ptrCast(@alignCast(gc_alloc.gcalloc(types.MemoryType.array, size).?));
    std.debug.assert(harness.vm().gc.blocks == @as(?*anyopaque, block));
    std.debug.assert(nextOf(block) == previous);
    std.debug.assert(typeOf(block) == types.MemoryType.array);
    // The whole word, not only the type byte: a fresh block carries no flags.
    std.debug.assert(block.flags == @intFromEnum(types.MemoryType.array));
    std.debug.assert(!isReachable(block));
    std.debug.assert(harness.vm().gc.block_count == count + 1);
    std.debug.assert(harness.vm().gc.next_collection == next + size);
    std.debug.assert(harness.vm().gc.weak_blocks == weak);

    unlinkHead(false, size);
    std.debug.assert(harness.vm().gc.blocks == previous);
    std.debug.assert(harness.vm().gc.block_count == count);
    std.debug.assert(harness.vm().gc.next_collection == next);
}

/// The four weak types are the ones at or above `JANET_MEMORY_TABLE_WEAKK`,
/// and the boundary is exactly that: the split is a numeric comparison against
/// the first weak constant, not a table of types.
fn theWeakTypesGoOnTheWeakHeap() void {
    const weak_types = [_]types.MemoryType{
        types.MemoryType.table_weakk,
        types.MemoryType.table_weakv,
        types.MemoryType.table_weakkv,
        types.MemoryType.array_weak,
    };

    for (weak_types) |memory_type| {
        const size = 96;
        const strong = harness.vm().gc.blocks;
        const previous = harness.vm().gc.weak_blocks;
        const count = harness.vm().gc.block_count;

        const block: *types.JanetGCObject = @ptrCast(@alignCast(gc_alloc.gcalloc(memory_type, size).?));
        std.debug.assert(harness.vm().gc.weak_blocks == @as(?*anyopaque, block));
        std.debug.assert(nextOf(block) == previous);
        std.debug.assert(typeOf(block) == memory_type);
        std.debug.assert(harness.vm().gc.blocks == strong);
        std.debug.assert(harness.vm().gc.block_count == count + 1);

        unlinkHead(true, size);
        std.debug.assert(harness.vm().gc.weak_blocks == previous);
        std.debug.assert(harness.vm().gc.block_count == count);
    }
}

/// Every type below the boundary goes on the normal heap. Worth stating for
/// `JANET_MEMORY_NONE` in particular, which is zero and therefore the value a
/// caller reaches by mistake.
fn theStrongTypesGoOnTheNormalHeap() void {
    const strong_types = [_]types.MemoryType{
        types.MemoryType.none,
        types.MemoryType.string,
        types.MemoryType.table,
        types.MemoryType.funcdef,
        types.MemoryType.threaded_abstract,
    };

    for (strong_types) |memory_type| {
        const weak = harness.vm().gc.weak_blocks;
        const block: *types.JanetGCObject = @ptrCast(@alignCast(gc_alloc.gcalloc(memory_type, 64).?));
        std.debug.assert(harness.vm().gc.blocks == @as(?*anyopaque, block));
        std.debug.assert(harness.vm().gc.weak_blocks == weak);
        std.debug.assert(typeOf(block) == memory_type);
        unlinkHead(false, 64);
    }
}

/// Successive allocations chain: the list is singly linked through the
/// header's `next`, newest first.
fn allocationsChainNewestFirst() void {
    const previous = harness.vm().gc.blocks;
    const first: *types.JanetGCObject = @ptrCast(@alignCast(gc_alloc.gcalloc(types.MemoryType.none, 32).?));
    const second: *types.JanetGCObject = @ptrCast(@alignCast(gc_alloc.gcalloc(types.MemoryType.none, 32).?));
    const third: *types.JanetGCObject = @ptrCast(@alignCast(gc_alloc.gcalloc(types.MemoryType.none, 32).?));

    std.debug.assert(harness.vm().gc.blocks == @as(?*anyopaque, third));
    std.debug.assert(nextOf(third) == @as(?*anyopaque, second));
    std.debug.assert(nextOf(second) == @as(?*anyopaque, first));
    std.debug.assert(nextOf(first) == previous);

    unlinkHead(false, 32);
    unlinkHead(false, 32);
    unlinkHead(false, 32);
    std.debug.assert(harness.vm().gc.blocks == previous);
}

/// Rooting appends. The root set is a multiset: n roots need n unroots.
fn theRootSetIsAMultiset() void {
    const base = harness.vm().roots.count;
    const array = arrays.new(0);
    const val = wrap.fromArray(array);

    gc_alloc.gcroot(val);
    std.debug.assert(harness.vm().roots.count == base + 1);
    std.debug.assert(wrap.toArray(harness.vm().roots.at(base).*) == array);

    gc_alloc.gcroot(val);
    std.debug.assert(harness.vm().roots.count == base + 2);
    std.debug.assert(wrap.toArray(harness.vm().roots.at(base + 1).*) == array);

    std.debug.assert(gc_alloc.gcunroot(val) == 1);
    std.debug.assert(harness.vm().roots.count == base + 1);
    std.debug.assert(gc_alloc.gcunroot(val) == 1);
    std.debug.assert(harness.vm().roots.count == base);
    std.debug.assert(gc_alloc.gcunroot(val) == 0);
    std.debug.assert(harness.vm().roots.count == base);
}

/// Roots are matched by pointer identity, not by value equality. Two arrays
/// with the same contents are different roots.
fn rootsAreMatchedByPointer() void {
    const base = harness.vm().roots.count;
    const a = wrap.fromArray(arrays.new(0));
    const b = wrap.fromArray(arrays.new(0));

    gc_alloc.gcroot(a);
    std.debug.assert(gc_alloc.gcunroot(b) == 0);
    std.debug.assert(harness.vm().roots.count == base + 1);
    std.debug.assert(gc_alloc.gcunroot(a) == 1);
    std.debug.assert(harness.vm().roots.count == base);
}

/// The three types the collector never traces compare equal to any value of
/// their own type. Rooting one number and unrooting a different one succeeds,
/// which is harmless — the slot held nothing worth keeping either way — but it
/// is observable, so it is pinned here.
fn immediatesMatchAnyValueOfTheirType() void {
    const base = harness.vm().roots.count;

    gc_alloc.gcroot(wrap.fromNumber(1.0));
    std.debug.assert(gc_alloc.gcunroot(wrap.fromNumber(9999.0)) == 1);
    std.debug.assert(harness.vm().roots.count == base);

    gc_alloc.gcroot(wrap.fromTrue());
    std.debug.assert(gc_alloc.gcunroot(wrap.fromFalse()) == 1);
    std.debug.assert(harness.vm().roots.count == base);

    gc_alloc.gcroot(wrap.fromNil());
    std.debug.assert(gc_alloc.gcunroot(wrap.fromNil()) == 1);
    std.debug.assert(harness.vm().roots.count == base);

    // Different types never match, immediate or not.
    gc_alloc.gcroot(wrap.fromNumber(1.0));
    std.debug.assert(gc_alloc.gcunroot(wrap.fromTrue()) == 0);
    std.debug.assert(gc_alloc.gcunroot(wrap.fromNil()) == 0);
    std.debug.assert(gc_alloc.gcunroot(wrap.fromNumber(0.0)) == 1);
    std.debug.assert(harness.vm().roots.count == base);
}

/// Unrooting fills the vacated slot from the top of the set, so the order of
/// the remaining roots is not the order they were added in.
fn unrootingSwapsFromTheTop() void {
    const base = harness.vm().roots.count;
    const a = arrays.new(0);
    const b = arrays.new(0);
    const d = arrays.new(0);

    gc_alloc.gcroot(wrap.fromArray(a));
    gc_alloc.gcroot(wrap.fromArray(b));
    gc_alloc.gcroot(wrap.fromArray(d));

    std.debug.assert(gc_alloc.gcunroot(wrap.fromArray(a)) == 1);
    std.debug.assert(harness.vm().roots.count == base + 2);
    std.debug.assert(wrap.toArray(harness.vm().roots.at(base).*) == d);
    std.debug.assert(wrap.toArray(harness.vm().roots.at(base + 1).*) == b);

    std.debug.assert(gc_alloc.gcunroot(wrap.fromArray(b)) == 1);
    std.debug.assert(gc_alloc.gcunroot(wrap.fromArray(d)) == 1);
    std.debug.assert(harness.vm().roots.count == base);
}

/// `janet_gcunrootall` does not remove every rooting, despite what Janet's
/// comment says. It fills the vacated slot from the top and then advances, so
/// the value it just moved down is never examined: n rootings become
/// floor(n / 2). `FOUND.md` carries the defect; this pins the behaviour.
fn unrootAllHalves() void {
    for ([_]usize{ 1, 2, 3, 4, 5, 8 }) |n| {
        const base = harness.vm().roots.count;
        const val = wrap.fromArray(arrays.new(0));

        for (0..n) |_| gc_alloc.gcroot(val);
        std.debug.assert(harness.vm().roots.count == base + n);

        std.debug.assert(gc_alloc.gcunrootall(val) == 1);
        std.debug.assert(harness.vm().roots.count == base + n / 2);

        // What survives really is still rooted, and can be removed one at a
        // time.
        for (0..n / 2) |_| std.debug.assert(gc_alloc.gcunroot(val) == 1);
        std.debug.assert(harness.vm().roots.count == base);
        std.debug.assert(gc_alloc.gcunrootall(val) == 0);
    }
}

/// An absent value reports absence and changes nothing.
fn unrootAllOfAnAbsentValue() void {
    const base = harness.vm().roots.count;
    const a = wrap.fromArray(arrays.new(0));
    const b = wrap.fromArray(arrays.new(0));

    gc_alloc.gcroot(a);
    std.debug.assert(gc_alloc.gcunrootall(b) == 0);
    std.debug.assert(harness.vm().roots.count == base + 1);
    std.debug.assert(gc_alloc.gcunroot(a) == 1);
    std.debug.assert(harness.vm().roots.count == base);
}

/// Growth is by doubling the required count, and the roots survive it.
fn theRootSetGrows() void {
    const base = harness.vm().roots.count;
    const val = wrap.fromArray(arrays.new(0));
    var added: usize = 0;

    while (harness.vm().roots.count < harness.vm().roots.capacity) {
        gc_alloc.gcroot(val);
        added += 1;
    }
    const at_capacity = harness.vm().roots.capacity;

    gc_alloc.gcroot(val);
    added += 1;
    std.debug.assert(harness.vm().roots.capacity == 2 * (at_capacity + 1));
    std.debug.assert(harness.vm().roots.count == base + added);
    for (0..added) |index| {
        std.debug.assert(wrap.toArray(harness.vm().roots.at(base + index).*) ==
            wrap.toArray(val));
    }

    for (0..added) |_| std.debug.assert(gc_alloc.gcunroot(val) == 1);
    std.debug.assert(harness.vm().roots.count == base);
}

/// The handle is the depth to restore, not a token to match. Unlocking with an
/// outer handle discards every lock taken since, which is what makes it safe
/// for a cleanup path to hold one handle across nested regions.
fn theSuspendCounterNests() void {
    const base = harness.vm().gc.suspend_count;

    const outer = gc_alloc.gclock();
    std.debug.assert(outer == base);
    std.debug.assert(harness.vm().gc.suspend_count == base + 1);

    const inner = gc_alloc.gclock();
    std.debug.assert(inner == base + 1);
    std.debug.assert(harness.vm().gc.suspend_count == base + 2);

    gc_alloc.gcunlock(inner);
    std.debug.assert(harness.vm().gc.suspend_count == base + 1);
    gc_alloc.gcunlock(outer);
    std.debug.assert(harness.vm().gc.suspend_count == base);

    const held = gc_alloc.gclock();
    _ = gc_alloc.gclock();
    _ = gc_alloc.gclock();
    std.debug.assert(harness.vm().gc.suspend_count == base + 3);
    gc_alloc.gcunlock(held);
    std.debug.assert(harness.vm().gc.suspend_count == base);
}

/// A suspended collector does not collect. This is the one property the
/// counter exists for, and it is checked through `janet_collect` rather than by
/// reading the field back.
fn aSuspendedCollectorDoesNotCollect() void {
    const handle = gc_alloc.gclock();
    harness.vm().gc.next_collection = 12345;
    gc_mark.collect();
    std.debug.assert(harness.vm().gc.next_collection == 12345);
    gc_alloc.gcunlock(handle);
    gc_mark.collect();
    std.debug.assert(harness.vm().gc.next_collection == 0);
}

var finalizer_calls: usize = 0;
var finalizer_args: [8]?*anyopaque = undefined;

fn recordFinalizer(memory: ?*anyopaque) callconv(.c) void {
    if (finalizer_calls < finalizer_args.len) finalizer_args[finalizer_calls] = memory;
    finalizer_calls += 1;
}

/// A scratch block is registered in the table, and the pointer handed back sits
/// exactly one header above it.
///
/// The second assertion is the one that matters beyond this file: it compares
/// `headerOf`'s `@sizeOf` arithmetic against the address the *runtime*
/// recorded, so the flexible-array assumption is checked rather than assumed.
fn smallocRegistersItsBlock() void {
    const base = harness.vm().scratch.count;

    const p: [*]u8 = @ptrCast(gc_alloc.smalloc(40).?);
    std.debug.assert(harness.vm().scratch.count == base + 1);
    std.debug.assert(harness.vm().scratch.at(base).* == headerOf(p));
    std.debug.assert(headerOf(p).finalize == null);
    std.debug.assert(@intFromPtr(p) % @alignOf(c_longlong) == 0);

    @memset(p[0..40], 'x');
    gc_alloc.sfree(p);
    std.debug.assert(harness.vm().scratch.count == base);
}

/// `janet_scalloc` zeroes, and the zero-length cases still produce a
/// registered block.
fn scallocZeroes() void {
    const base = harness.vm().scratch.count;

    const p: [*]u8 = @ptrCast(gc_alloc.scalloc(9, 7).?);
    std.debug.assert(harness.vm().scratch.count == base + 1);
    for (p[0..63]) |byte| std.debug.assert(byte == 0);

    const empty = gc_alloc.scalloc(0, 16);
    std.debug.assert(empty != null);
    std.debug.assert(harness.vm().scratch.count == base + 2);

    const empty2 = gc_alloc.scalloc(16, 0);
    std.debug.assert(empty2 != null);
    std.debug.assert(harness.vm().scratch.count == base + 3);

    gc_alloc.sfree(empty2);
    gc_alloc.sfree(empty);
    gc_alloc.sfree(p);
    std.debug.assert(harness.vm().scratch.count == base);
}

/// `janet_srealloc` keeps the block in the same table slot, preserves the
/// bytes that fit, and carries the finalizer across — the header moves with
/// the allocation. A null pointer means allocate.
fn sreallocKeepsItsSlot() void {
    const base = harness.vm().scratch.count;

    const fresh = gc_alloc.srealloc(null, 24);
    std.debug.assert(fresh != null);
    std.debug.assert(harness.vm().scratch.count == base + 1);
    std.debug.assert(scratchIndexOf(fresh).? == base);
    gc_alloc.sfree(fresh);

    const p: [*]u8 = @ptrCast(gc_alloc.smalloc(16).?);
    @memcpy(p[0..16], "0123456789abcde\x00");
    gc_alloc.sfinalizer(p, recordFinalizer);
    const slot = scratchIndexOf(p).?;

    const grown: [*]u8 = @ptrCast(gc_alloc.srealloc(p, 4096).?);
    std.debug.assert(harness.vm().scratch.count == base + 1);
    std.debug.assert(scratchIndexOf(grown).? == slot);
    std.debug.assert(std.mem.eql(u8, grown[0..15], "0123456789abcde"));
    std.debug.assert(headerOf(grown).finalize == recordFinalizer);

    const shrunk: [*]u8 = @ptrCast(gc_alloc.srealloc(grown, 8).?);
    std.debug.assert(harness.vm().scratch.count == base + 1);
    std.debug.assert(scratchIndexOf(shrunk).? == slot);
    std.debug.assert(std.mem.eql(u8, shrunk[0..8], "01234567"));

    finalizer_calls = 0;
    gc_alloc.sfree(shrunk);
    std.debug.assert(finalizer_calls == 1);
    std.debug.assert(finalizer_args[0] == @as(?*anyopaque, @ptrCast(shrunk)));
    std.debug.assert(harness.vm().scratch.count == base);
}

/// Freeing fills the vacated table slot from the top, the same way the root
/// set does, and a null pointer is a no-op.
fn sfreeSwapsFromTheTop() void {
    const base = harness.vm().scratch.count;

    const a = gc_alloc.smalloc(8);
    const b = gc_alloc.smalloc(8);
    const d = gc_alloc.smalloc(8);
    std.debug.assert(harness.vm().scratch.count == base + 3);

    gc_alloc.sfree(null);
    std.debug.assert(harness.vm().scratch.count == base + 3);

    gc_alloc.sfree(a);
    std.debug.assert(harness.vm().scratch.count == base + 2);
    std.debug.assert(scratchIndexOf(d).? == base);
    std.debug.assert(scratchIndexOf(b).? == base + 1);

    gc_alloc.sfree(b);
    gc_alloc.sfree(d);
    std.debug.assert(harness.vm().scratch.count == base);
}

/// A finalizer runs once, with the caller's pointer rather than the header.
fn aScratchFinalizerRunsOnce() void {
    const base = harness.vm().scratch.count;

    var p = gc_alloc.smalloc(8);
    finalizer_calls = 0;
    gc_alloc.sfree(p);
    std.debug.assert(finalizer_calls == 0);

    p = gc_alloc.smalloc(8);
    gc_alloc.sfinalizer(p, recordFinalizer);
    finalizer_calls = 0;
    gc_alloc.sfree(p);
    std.debug.assert(finalizer_calls == 1);
    std.debug.assert(finalizer_args[0] == p);
    std.debug.assert(harness.vm().scratch.count == base);
}

/// The table grows to twice what is needed plus two, and everything already in
/// it survives the move.
fn theScratchTableGrows() void {
    var held: [64]?*anyopaque = undefined;
    const base = harness.vm().scratch.count;
    var count: usize = 0;

    while (harness.vm().scratch.count < harness.vm().scratch.capacity) {
        held[count] = gc_alloc.smalloc(8);
        @memset(@as([*]u8, @ptrCast(held[count].?))[0..8], @intCast(count));
        count += 1;
        std.debug.assert(count < held.len);
    }
    const at_capacity = harness.vm().scratch.capacity;

    held[count] = gc_alloc.smalloc(8);
    @memset(@as([*]u8, @ptrCast(held[count].?))[0..8], @intCast(count));
    count += 1;
    std.debug.assert(harness.vm().scratch.capacity == 2 * at_capacity + 2);
    std.debug.assert(harness.vm().scratch.count == base + count);

    for (0..count) |index| {
        std.debug.assert(scratchIndexOf(held[index]) != null);
        const bytes: [*]u8 = @ptrCast(held[index].?);
        for (bytes[0..8]) |byte| std.debug.assert(byte == @as(u8, @intCast(index)));
    }
    for (0..count) |index| gc_alloc.sfree(held[index]);
    std.debug.assert(harness.vm().scratch.count == base);
}

/// Releasing everything runs each finalizer and empties the table. This is what
/// `janet_collect` does at the end of a collection and `janet_clear_memory`
/// does at shutdown, which is why the scratch API needs no explicit free to be
/// correct.
fn freeAllScratchRunsEveryFinalizer() void {
    gc_mark.collect();
    std.debug.assert(harness.vm().scratch.count == 0);

    const a = gc_alloc.smalloc(8);
    _ = gc_alloc.smalloc(8);
    const d = gc_alloc.smalloc(8);
    gc_alloc.sfinalizer(a, recordFinalizer);
    gc_alloc.sfinalizer(d, recordFinalizer);

    finalizer_calls = 0;
    gc_alloc.freeAllScratch(&harness.vm().scratch);
    std.debug.assert(harness.vm().scratch.count == 0);
    std.debug.assert(finalizer_calls == 2);
    std.debug.assert(finalizer_args[0] == a);
    std.debug.assert(finalizer_args[1] == d);
}

/// And a collection does the same, on its way out.
fn aCollectionFreesScratch() void {
    const p = gc_alloc.smalloc(8);
    gc_alloc.sfinalizer(p, recordFinalizer);
    finalizer_calls = 0;
    gc_mark.collect();
    std.debug.assert(finalizer_calls == 1);
    std.debug.assert(finalizer_args[0] == p);
    std.debug.assert(harness.vm().scratch.count == 0);
}

pub fn run() void {
    harness.init();

    theGcPressure();
    aNewBlockGoesOnTheNormalHeap();
    theWeakTypesGoOnTheWeakHeap();
    theStrongTypesGoOnTheNormalHeap();
    allocationsChainNewestFirst();

    theRootSetIsAMultiset();
    rootsAreMatchedByPointer();
    immediatesMatchAnyValueOfTheirType();
    unrootingSwapsFromTheTop();
    unrootAllHalves();
    unrootAllOfAnAbsentValue();
    theRootSetGrows();

    theSuspendCounterNests();
    aSuspendedCollectorDoesNotCollect();

    smallocRegistersItsBlock();
    scallocZeroes();
    sreallocKeepsItsSlot();
    sfreeSwapsFromTheTop();
    aScratchFinalizerRunsOnce();
    theScratchTableGrows();
    freeAllScratchRunsEveryFinalizer();
    aCollectionFreesScratch();

    vm_lifecycle.deinit();
}
