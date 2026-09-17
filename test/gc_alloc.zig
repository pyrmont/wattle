//! Behavioral contract for the collector's memory: block allocation and the
//! two heap lists, the root set, the GC suspend counter, and the scratch
//! allocator.
//!
//! Every operation under test is a mutation of the VM's collection fields, and
//! the fields are the observable result. There is no accessor for
//! `block_count` or the scratch table's length, and inventing one would test
//! the accessor, so this file reads the VM directly. The Zig driver can do
//! that because it *is* the runtime's compilation.
//!
//! Two things are deliberately not exercised. Nothing here lets a synthetic
//! block reach `gc/sweep.zig`'s `sweep`: each allocation case unlinks what it
//! made and restores the counters, so the contract stays independent of
//! marking and sweeping. And the fatal paths abort the process, so they are
//! described here rather than run: `gc.srealloc` and `gc.sfree` on a pointer
//! this allocator never handed out, and the checked adds in `gc.smalloc` and
//! `gc.gcallocWithPayload`.
//!
//! ## The header arithmetic has a real oracle here
//!
//! `ScratchBlock` ends in a flexible array, so the header is recovered with
//! `@sizeOf`, which is the same assumption `gc_mark.zig` and `gc_sweep.zig`
//! make about the four value heads. Here it is checked rather than assumed,
//! and by the allocator itself: `gc.smalloc` registers the header in the
//! scratch table and returns a pointer into it, so comparing that table entry
//! against `headerOf(p)` puts Zig's arithmetic against an address the runtime
//! recorded. `test/gc_mark.zig` sets out what had to be built to get the same
//! guarantee for the value heads.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const arrays = @import("subsystems").value.arrays;
const constants = @import("constants");
const expect = @import("expect.zig").expect;
const gc_alloc = @import("subsystems").gc_alloc;
const gc_mark = @import("subsystems").gc_mark;
const harness = @import("harness.zig");
const utils = @import("subsystems").utils;
const vm_lifecycle = @import("subsystems").lifecycle;
const vm_state = @import("subsystems").vm_state;
const wrap = @import("subsystems").value.wrap;

// ==========================================================================
// Constants
// ==========================================================================

var finalizer_args: [8]?*anyopaque = undefined;
var finalizer_calls: usize = 0;

// ==========================================================================
// Cases
// ==========================================================================

/// The scratch header sits exactly one header below the pointer the caller
/// gets. That relationship is the whole allocator: `gc.srealloc`, `gc.sfree`
/// and `gc.sfinalizer` all recover it by subtraction.
fn headerOf(memory: ?*anyopaque) *gc_alloc.ScratchBlock {
    return @ptrFromInt(@intFromPtr(memory) - @sizeOf(gc_alloc.ScratchBlock));
}

/// Where the runtime recorded `memory`'s header, or null if it did not.
fn scratchIndexOf(memory: ?*anyopaque) ?usize {
    const want = headerOf(memory);
    var index: usize = 0;
    while (index < harness.vm().scratch.items.len) : (index += 1) {
        if (harness.vm().scratch.items[index] == want) return index;
    }
    return null;
}

/// Both heap list heads are `?*GCObject`, so list identity is an ordinary
/// pointer comparison and the head's own fields are reachable without a cast.
fn asBlock(pointer: ?*abi.GCObject) *abi.GCObject {
    return pointer.?;
}

fn nextOf(block: *abi.GCObject) ?*abi.GCObject {
    return block.data.next;
}

/// Undo one allocation, restoring every field it moved. Only valid for the
/// block at the head of its list, which is where `gc.gcallocBytes` just put
/// it.
fn unlinkHead(weak: bool, size: usize) void {
    const head = asBlock(if (weak) harness.vm().gc.weak_blocks else harness.vm().gc.blocks);
    if (weak) {
        harness.vm().gc.weak_blocks = nextOf(head);
    } else {
        harness.vm().gc.blocks = nextOf(head);
    }
    harness.vm().gc.block_count -= 1;
    harness.vm().gc.next_collection -= size;
    utils.free(@ptrCast(head));
}

fn typeOf(block: *abi.GCObject) gc_alloc.MemoryType {
    return gc_alloc.memoryTypeOf(block);
}

fn recordFinalizer(memory: ?*anyopaque) callconv(.c) void {
    if (finalizer_calls < finalizer_args.len) finalizer_args[finalizer_calls] = memory;
    finalizer_calls += 1;
}

/// The only thing `gc.gcpressure` does is move the threshold. It must not
/// collect, and it must not touch the block count, the bytes it is told about
/// having been allocated outside the collector's accounting.
fn theGcPressure() void {
    const before = harness.vm().gc.next_collection;
    const blocks = harness.vm().gc.block_count;

    gc_alloc.gcpressure(0);
    expect(harness.vm().gc.next_collection == before);

    gc_alloc.gcpressure(4096);
    expect(harness.vm().gc.next_collection == before + 4096);
    expect(harness.vm().gc.block_count == blocks);

    harness.vm().gc.next_collection = before;
}

fn isReachable(block: *abi.GCObject) bool {
    return harness.gcBits(block.flags) & constants.JANET_MEM_REACHABLE != 0;
}

/// A new block goes on the front of the normal heap with its type in the low
/// byte of `flags` and nothing else, and is counted. It is emphatically
/// not marked: the caller has not filled it in yet, and a collection that
/// treated it as reachable would trace uninitialised memory.
fn aNewBlockGoesOnTheNormalHeap() void {
    const size = 128;
    const previous = harness.vm().gc.blocks;
    const count = harness.vm().gc.block_count;
    const next = harness.vm().gc.next_collection;
    const weak = harness.vm().gc.weak_blocks;

    const block = gc_alloc.gcallocBytes(gc_alloc.MemoryType.array, size);
    expect(harness.vm().gc.blocks == block);
    expect(nextOf(block) == previous);
    expect(typeOf(block) == gc_alloc.MemoryType.array);
    // The whole word, not only the type byte: a fresh block has no flags set.
    expect(harness.gcBits(block.flags) == @intFromEnum(gc_alloc.MemoryType.array));
    expect(!isReachable(block));
    expect(harness.vm().gc.block_count == count + 1);
    expect(harness.vm().gc.next_collection == next + size);
    expect(harness.vm().gc.weak_blocks == weak);

    unlinkHead(false, size);
    expect(harness.vm().gc.blocks == previous);
    expect(harness.vm().gc.block_count == count);
    expect(harness.vm().gc.next_collection == next);
}

/// The four weak types are the ones at or above `MemoryType.table_weakk`,
/// and the boundary is exactly that: the split is a numeric comparison against
/// the first weak constant, not a table of types.
fn theWeakTypesGoOnTheWeakHeap() void {
    const weak_types = [_]gc_alloc.MemoryType{
        gc_alloc.MemoryType.table_weakk,
        gc_alloc.MemoryType.table_weakv,
        gc_alloc.MemoryType.table_weakkv,
        gc_alloc.MemoryType.array_weak,
    };

    for (weak_types) |memory_type| {
        const size = 96;
        const strong = harness.vm().gc.blocks;
        const previous = harness.vm().gc.weak_blocks;
        const count = harness.vm().gc.block_count;

        const block = gc_alloc.gcallocBytes(memory_type, size);
        expect(harness.vm().gc.weak_blocks == block);
        expect(nextOf(block) == previous);
        expect(typeOf(block) == memory_type);
        expect(harness.vm().gc.blocks == strong);
        expect(harness.vm().gc.block_count == count + 1);

        unlinkHead(true, size);
        expect(harness.vm().gc.weak_blocks == previous);
        expect(harness.vm().gc.block_count == count);
    }
}

/// Every type below the boundary goes on the normal heap. Worth stating for
/// `MemoryType.none` in particular, which is zero and therefore the value a
/// caller reaches by mistake, and for the collection node types, which are
/// numbered after `threaded_abstract` and immediately below the boundary.
fn theStrongTypesGoOnTheNormalHeap() void {
    const strong_types = [_]gc_alloc.MemoryType{
        gc_alloc.MemoryType.none,
        gc_alloc.MemoryType.string,
        gc_alloc.MemoryType.table,
        gc_alloc.MemoryType.funcdef,
        gc_alloc.MemoryType.threaded_abstract,
        gc_alloc.MemoryType.vector_inner,
        gc_alloc.MemoryType.vector_leaf,
        gc_alloc.MemoryType.map_node,
        gc_alloc.MemoryType.set_node,
    };

    for (strong_types) |memory_type| {
        const weak = harness.vm().gc.weak_blocks;
        const block = gc_alloc.gcallocBytes(memory_type, 64);
        expect(harness.vm().gc.blocks == block);
        expect(harness.vm().gc.weak_blocks == weak);
        expect(typeOf(block) == memory_type);
        unlinkHead(false, 64);
    }
}

/// Successive allocations chain: the list is singly linked through the
/// header's `next`, newest first.
fn allocationsChainNewestFirst() void {
    const previous = harness.vm().gc.blocks;
    const first = gc_alloc.gcallocBytes(gc_alloc.MemoryType.none, 32);
    const second = gc_alloc.gcallocBytes(gc_alloc.MemoryType.none, 32);
    const third = gc_alloc.gcallocBytes(gc_alloc.MemoryType.none, 32);

    expect(harness.vm().gc.blocks == third);
    expect(nextOf(third) == second);
    expect(nextOf(second) == first);
    expect(nextOf(first) == previous);

    unlinkHead(false, 32);
    unlinkHead(false, 32);
    unlinkHead(false, 32);
    expect(harness.vm().gc.blocks == previous);
}

/// Rooting appends. The root set is a multiset: n roots need n unroots.
fn theRootSetIsAMultiset() void {
    const base = harness.vm().roots.items.len;
    const array = arrays.new(0);
    const val = wrap.fromArray(array);

    gc_alloc.gcroot(val);
    expect(harness.vm().roots.items.len == base + 1);
    expect(wrap.toArray(harness.vm().roots.items[base]) == array);

    gc_alloc.gcroot(val);
    expect(harness.vm().roots.items.len == base + 2);
    expect(wrap.toArray(harness.vm().roots.items[base + 1]) == array);

    expect(gc_alloc.gcunroot(val));
    expect(harness.vm().roots.items.len == base + 1);
    expect(gc_alloc.gcunroot(val));
    expect(harness.vm().roots.items.len == base);
    expect(!gc_alloc.gcunroot(val));
    expect(harness.vm().roots.items.len == base);
}

/// Roots are matched by pointer identity, not by value equality. Two arrays
/// with the same contents are different roots.
fn rootsAreMatchedByPointer() void {
    const base = harness.vm().roots.items.len;
    const a = wrap.fromArray(arrays.new(0));
    const b = wrap.fromArray(arrays.new(0));

    gc_alloc.gcroot(a);
    expect(!gc_alloc.gcunroot(b));
    expect(harness.vm().roots.items.len == base + 1);
    expect(gc_alloc.gcunroot(a));
    expect(harness.vm().roots.items.len == base);
}

/// The three types the collector never traces compare equal to any value of
/// their own type. Rooting one number and unrooting a different one succeeds,
/// which is harmless, the slot having nothing worth keeping either way, but
/// it is observable, so it is pinned here.
fn immediatesMatchAnyValueOfTheirType() void {
    const base = harness.vm().roots.items.len;

    gc_alloc.gcroot(wrap.fromNumber(1.0));
    expect(gc_alloc.gcunroot(wrap.fromNumber(9999.0)));
    expect(harness.vm().roots.items.len == base);

    gc_alloc.gcroot(wrap.fromTrue());
    expect(gc_alloc.gcunroot(wrap.fromFalse()));
    expect(harness.vm().roots.items.len == base);

    gc_alloc.gcroot(wrap.fromNil());
    expect(gc_alloc.gcunroot(wrap.fromNil()));
    expect(harness.vm().roots.items.len == base);

    // Different types never match, immediate or not.
    gc_alloc.gcroot(wrap.fromNumber(1.0));
    expect(!gc_alloc.gcunroot(wrap.fromTrue()));
    expect(!gc_alloc.gcunroot(wrap.fromNil()));
    expect(gc_alloc.gcunroot(wrap.fromNumber(0.0)));
    expect(harness.vm().roots.items.len == base);
}

/// Unrooting fills the vacated slot from the top of the set, so the order of
/// the remaining roots is not the order they were added in.
fn unrootingSwapsFromTheTop() void {
    const base = harness.vm().roots.items.len;
    const a = arrays.new(0);
    const b = arrays.new(0);
    const d = arrays.new(0);

    gc_alloc.gcroot(wrap.fromArray(a));
    gc_alloc.gcroot(wrap.fromArray(b));
    gc_alloc.gcroot(wrap.fromArray(d));

    expect(gc_alloc.gcunroot(wrap.fromArray(a)));
    expect(harness.vm().roots.items.len == base + 2);
    expect(wrap.toArray(harness.vm().roots.items[base]) == d);
    expect(wrap.toArray(harness.vm().roots.items[base + 1]) == b);

    expect(gc_alloc.gcunroot(wrap.fromArray(b)));
    expect(gc_alloc.gcunroot(wrap.fromArray(d)));
    expect(harness.vm().roots.items.len == base);
}

/// `gcunrootall` sets a value's effective reference count to zero, whatever it
/// was. The removal fills the vacated slot from the top, so the count is what
/// says whether the element moved down was examined too: an implementation
/// that advanced past it would leave floor(n / 2) behind and still report
/// success.
fn unrootAllRemovesEveryRooting() void {
    for ([_]usize{ 1, 2, 3, 4, 5, 8 }) |n| {
        const base = harness.vm().roots.items.len;
        const val = wrap.fromArray(arrays.new(0));

        for (0..n) |_| gc_alloc.gcroot(val);
        expect(harness.vm().roots.items.len == base + n);

        expect(gc_alloc.gcunrootall(val));
        expect(harness.vm().roots.items.len == base);
        expect(!gc_alloc.gcunroot(val));
        expect(!gc_alloc.gcunrootall(val));
    }
}

/// And it removes only that value's rootings. A run of the same value between
/// two others is the shape a swap-remove can get wrong in the other direction.
fn unrootAllLeavesOtherRootingsAlone() void {
    const base = harness.vm().roots.items.len;
    const keep_a = wrap.fromArray(arrays.new(0));
    const target = wrap.fromArray(arrays.new(0));
    const keep_b = wrap.fromArray(arrays.new(0));

    gc_alloc.gcroot(keep_a);
    for (0..3) |_| gc_alloc.gcroot(target);
    gc_alloc.gcroot(keep_b);
    gc_alloc.gcroot(keep_a);

    expect(gc_alloc.gcunrootall(target));
    expect(harness.vm().roots.items.len == base + 3);
    expect(gc_alloc.gcunroot(keep_a));
    expect(gc_alloc.gcunroot(keep_a));
    expect(gc_alloc.gcunroot(keep_b));
    expect(harness.vm().roots.items.len == base);
}

/// An absent value reports absence and changes nothing.
fn unrootAllOfAnAbsentValue() void {
    const base = harness.vm().roots.items.len;
    const a = wrap.fromArray(arrays.new(0));
    const b = wrap.fromArray(arrays.new(0));

    gc_alloc.gcroot(a);
    expect(!gc_alloc.gcunrootall(b));
    expect(harness.vm().roots.items.len == base + 1);
    expect(gc_alloc.gcunroot(a));
    expect(harness.vm().roots.items.len == base);
}

/// The root set grows when it fills, and the roots survive the growth.
///
/// Not the growth rule. The rule is `ArrayListUnmanaged`'s and decides only
/// *when* a reallocation happens, which nothing a program can run observes.
/// What a caller can see is that rooting past the capacity keeps every root at
/// its index and that unrooting them all restores the count, and that is what
/// is asserted.
fn theRootSetGrows() void {
    const base = harness.vm().roots.items.len;
    const val = wrap.fromArray(arrays.new(0));
    var added: usize = 0;

    while (harness.vm().roots.items.len < harness.vm().roots.capacity) {
        gc_alloc.gcroot(val);
        added += 1;
    }
    const at_capacity = harness.vm().roots.capacity;

    gc_alloc.gcroot(val);
    added += 1;
    expect(harness.vm().roots.capacity > at_capacity);
    expect(harness.vm().roots.items.len == base + added);
    for (0..added) |index| {
        expect(wrap.toArray(harness.vm().roots.items[base + index]) ==
            wrap.toArray(val));
    }

    for (0..added) |_| expect(gc_alloc.gcunroot(val));
    expect(harness.vm().roots.items.len == base);
}

/// The handle is the depth to restore, not a token to match. Unlocking with an
/// outer handle discards every lock taken since, which is what makes one
/// handle safe to keep across nested regions on a cleanup path.
fn theSuspendCounterNests() void {
    const base = harness.vm().gc.suspend_count;

    const outer = gc_alloc.gclock(vm_state.current());
    expect(outer == base);
    expect(harness.vm().gc.suspend_count == base + 1);

    const inner = gc_alloc.gclock(vm_state.current());
    expect(inner == base + 1);
    expect(harness.vm().gc.suspend_count == base + 2);

    gc_alloc.gcunlock(vm_state.current(), inner);
    expect(harness.vm().gc.suspend_count == base + 1);
    gc_alloc.gcunlock(vm_state.current(), outer);
    expect(harness.vm().gc.suspend_count == base);

    const held = gc_alloc.gclock(vm_state.current());
    _ = gc_alloc.gclock(vm_state.current());
    _ = gc_alloc.gclock(vm_state.current());
    expect(harness.vm().gc.suspend_count == base + 3);
    gc_alloc.gcunlock(vm_state.current(), held);
    expect(harness.vm().gc.suspend_count == base);
}

/// A suspended collector does not collect. This is the one property the
/// counter exists for, and it is checked through `gc/mark.zig`'s `collect`
/// rather than by reading the field back.
fn aSuspendedCollectorDoesNotCollect() void {
    const handle = gc_alloc.gclock(vm_state.current());
    harness.vm().gc.next_collection = 12345;
    gc_mark.collect();
    expect(harness.vm().gc.next_collection == 12345);
    gc_alloc.gcunlock(vm_state.current(), handle);
    gc_mark.collect();
    expect(harness.vm().gc.next_collection == 0);
}

/// A scratch block is registered in the table, and the pointer handed back sits
/// exactly one header above it.
///
/// The second assertion is the one that matters beyond this file: it compares
/// `headerOf`'s `@sizeOf` arithmetic against the address the *runtime*
/// recorded, so the flexible-array assumption is checked rather than assumed.
fn smallocRegistersItsBlock() void {
    const base = harness.vm().scratch.items.len;

    const p: [*]u8 = @ptrCast(gc_alloc.smalloc(40));
    expect(harness.vm().scratch.items.len == base + 1);
    expect(harness.vm().scratch.items[base] == headerOf(p));
    expect(headerOf(p).finalize == null);
    expect(@intFromPtr(p) % @alignOf(c_longlong) == 0);

    @memset(p[0..40], 'x');
    gc_alloc.sfree(p);
    expect(harness.vm().scratch.items.len == base);
}

/// `gc.scalloc` zeroes, and the zero-length cases still produce a registered
/// block.
fn scallocZeroes() void {
    const base = harness.vm().scratch.items.len;

    const p: [*]u8 = @ptrCast(gc_alloc.scalloc(9, 7).?);
    expect(harness.vm().scratch.items.len == base + 1);
    for (p[0..63]) |byte| expect(byte == 0);

    const empty = gc_alloc.scalloc(0, 16);
    expect(empty != null);
    expect(harness.vm().scratch.items.len == base + 2);

    const empty2 = gc_alloc.scalloc(16, 0);
    expect(empty2 != null);
    expect(harness.vm().scratch.items.len == base + 3);

    gc_alloc.sfree(empty2);
    gc_alloc.sfree(empty);
    gc_alloc.sfree(p);
    expect(harness.vm().scratch.items.len == base);
}

/// `gc.srealloc` keeps the block in the same table slot, preserves the bytes
/// that fit, and takes the finalizer across with it, the header moving with
/// the allocation. A null pointer means allocate.
fn sreallocKeepsItsSlot() void {
    const base = harness.vm().scratch.items.len;

    const fresh = gc_alloc.srealloc(null, 24);
    expect(fresh != null);
    expect(harness.vm().scratch.items.len == base + 1);
    expect(scratchIndexOf(fresh).? == base);
    gc_alloc.sfree(fresh);

    const p: [*]u8 = @ptrCast(gc_alloc.smalloc(16));
    @memcpy(p[0..16], "0123456789abcde\x00");
    gc_alloc.sfinalizer(p, recordFinalizer);
    const slot = scratchIndexOf(p).?;

    const grown: [*]u8 = @ptrCast(gc_alloc.srealloc(p, 4096).?);
    expect(harness.vm().scratch.items.len == base + 1);
    expect(scratchIndexOf(grown).? == slot);
    expect(std.mem.eql(u8, grown[0..15], "0123456789abcde"));
    expect(headerOf(grown).finalize == recordFinalizer);

    const shrunk: [*]u8 = @ptrCast(gc_alloc.srealloc(grown, 8).?);
    expect(harness.vm().scratch.items.len == base + 1);
    expect(scratchIndexOf(shrunk).? == slot);
    expect(std.mem.eql(u8, shrunk[0..8], "01234567"));

    finalizer_calls = 0;
    gc_alloc.sfree(shrunk);
    expect(finalizer_calls == 1);
    expect(finalizer_args[0] == @as(?*anyopaque, @ptrCast(shrunk)));
    expect(harness.vm().scratch.items.len == base);
}

/// `scratch_heap` resizes in place to the block's own length or shorter, and
/// refuses to grow in place, because `srealloc` may move the block.
fn theScratchHeapResizesInPlaceOnlyDownward() void {
    const base = harness.vm().scratch.items.len;
    const block = gc_alloc.scratch_heap.alloc(u8, 32) catch unreachable;
    expect(harness.vm().scratch.items.len == base + 1);
    expect(gc_alloc.scratch_heap.resize(block, 32));
    expect(gc_alloc.scratch_heap.resize(block, 16));
    const shrunk: []u8 = block[0..16];
    expect(!gc_alloc.scratch_heap.resize(shrunk, 64));
    gc_alloc.scratch_heap.free(shrunk);
    expect(harness.vm().scratch.items.len == base);
}

/// Freeing fills the vacated table slot from the top, the same way the root
/// set does, and a null pointer is a no-op.
fn sfreeSwapsFromTheTop() void {
    const base = harness.vm().scratch.items.len;

    const a = gc_alloc.smalloc(8);
    const b = gc_alloc.smalloc(8);
    const d = gc_alloc.smalloc(8);
    expect(harness.vm().scratch.items.len == base + 3);

    gc_alloc.sfree(null);
    expect(harness.vm().scratch.items.len == base + 3);

    gc_alloc.sfree(a);
    expect(harness.vm().scratch.items.len == base + 2);
    expect(scratchIndexOf(d).? == base);
    expect(scratchIndexOf(b).? == base + 1);

    gc_alloc.sfree(b);
    gc_alloc.sfree(d);
    expect(harness.vm().scratch.items.len == base);
}

/// A finalizer runs once, with the caller's pointer rather than the header.
fn aScratchFinalizerRunsOnce() void {
    const base = harness.vm().scratch.items.len;

    var p = gc_alloc.smalloc(8);
    finalizer_calls = 0;
    gc_alloc.sfree(p);
    expect(finalizer_calls == 0);

    p = gc_alloc.smalloc(8);
    gc_alloc.sfinalizer(p, recordFinalizer);
    finalizer_calls = 0;
    gc_alloc.sfree(p);
    expect(finalizer_calls == 1);
    expect(finalizer_args[0] == p);
    expect(harness.vm().scratch.items.len == base);
}

/// The table grows to twice what is needed plus two, and everything already in
/// it survives the move.
fn theScratchTableGrows() void {
    var held: [64]?*anyopaque = undefined;
    const base = harness.vm().scratch.items.len;
    var count: usize = 0;

    while (harness.vm().scratch.items.len < harness.vm().scratch.capacity) {
        held[count] = gc_alloc.smalloc(8);
        @memset(@as([*]u8, @ptrCast(held[count].?))[0..8], @intCast(count));
        count += 1;
        expect(count < held.len);
    }
    const at_capacity = harness.vm().scratch.capacity;

    held[count] = gc_alloc.smalloc(8);
    @memset(@as([*]u8, @ptrCast(held[count].?))[0..8], @intCast(count));
    count += 1;
    // Not the growth rule; see `theRootSetGrows`. What the table owes is that
    // every live block is still findable in it after the growth, which the
    // loop below checks.
    expect(harness.vm().scratch.capacity > at_capacity);
    expect(harness.vm().scratch.items.len == base + count);

    for (0..count) |index| {
        expect(scratchIndexOf(held[index]) != null);
        const bytes: [*]u8 = @ptrCast(held[index].?);
        for (bytes[0..8]) |byte| expect(byte == @as(u8, @intCast(index)));
    }
    for (0..count) |index| gc_alloc.sfree(held[index]);
    expect(harness.vm().scratch.items.len == base);
}

/// Releasing everything runs each finalizer and empties the table. It is what
/// `gc/mark.zig`'s `collect` does at the end of a collection and
/// `gc/sweep.zig`'s `clearMemory` does at shutdown, so a caller of the scratch
/// allocator needs no explicit free to be correct.
fn freeAllScratchRunsEveryFinalizer() void {
    gc_mark.collect();
    expect(harness.vm().scratch.items.len == 0);

    const a = gc_alloc.smalloc(8);
    _ = gc_alloc.smalloc(8);
    const d = gc_alloc.smalloc(8);
    gc_alloc.sfinalizer(a, recordFinalizer);
    gc_alloc.sfinalizer(d, recordFinalizer);

    finalizer_calls = 0;
    gc_alloc.freeAllScratch(&harness.vm().scratch);
    expect(harness.vm().scratch.items.len == 0);
    expect(finalizer_calls == 2);
    expect(finalizer_args[0] == a);
    expect(finalizer_args[1] == d);
}

/// And a collection does the same, on its way out.
fn aCollectionFreesScratch() void {
    const p = gc_alloc.smalloc(8);
    gc_alloc.sfinalizer(p, recordFinalizer);
    finalizer_calls = 0;
    gc_mark.collect();
    expect(finalizer_calls == 1);
    expect(finalizer_args[0] == p);
    expect(harness.vm().scratch.items.len == 0);
}

// ==========================================================================
// Entry
// ==========================================================================

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
    unrootAllRemovesEveryRooting();
    unrootAllLeavesOtherRootingsAlone();
    unrootAllOfAnAbsentValue();
    theRootSetGrows();

    theSuspendCounterNests();
    aSuspendedCollectorDoesNotCollect();

    smallocRegistersItsBlock();
    scallocZeroes();
    sreallocKeepsItsSlot();
    theScratchHeapResizesInPlaceOnlyDownward();
    sfreeSwapsFromTheTop();
    aScratchFinalizerRunsOnce();
    theScratchTableGrows();
    freeAllScratchRunsEveryFinalizer();
    aCollectionFreesScratch();

    vm_lifecycle.deinit();
}
