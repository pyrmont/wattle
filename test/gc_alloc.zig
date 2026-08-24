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
const abi = @import("abi");
const c = abi.c;
const harness = @import("harness.zig");

/// The scratch header sits exactly one header below the pointer the caller
/// holds. That relationship is the whole allocator: `janet_srealloc`,
/// `janet_sfree` and `janet_sfinalizer` all recover it by subtraction.
fn headerOf(memory: ?*anyopaque) *c.JanetScratch {
    return @ptrFromInt(@intFromPtr(memory) - @sizeOf(c.JanetScratch));
}

/// Where the runtime recorded `memory`'s header, or null if it did not.
fn scratchIndexOf(memory: ?*anyopaque) ?usize {
    const want = headerOf(memory);
    var index: usize = 0;
    while (index < c.janet_vm.scratch_len) : (index += 1) {
        if (c.janet_vm.scratch_mem[index] == want) return index;
    }
    return null;
}

/// `state.h` types both heap list heads as `void *`, so list identity is
/// compared as an opaque pointer and cast only where a field is wanted.
fn asBlock(pointer: ?*anyopaque) *c.JanetGCObject {
    return @ptrCast(@alignCast(pointer.?));
}

fn nextOf(block: *c.JanetGCObject) ?*anyopaque {
    return @ptrCast(block.data.next);
}

/// Undo one allocation, restoring every field it moved. Only valid for the
/// block at the head of its list, which is where `janet_gcalloc` just put it.
fn unlinkHead(weak: bool, size: usize) void {
    const head = asBlock(if (weak) c.janet_vm.weak_blocks else c.janet_vm.blocks);
    if (weak) {
        c.janet_vm.weak_blocks = nextOf(head);
    } else {
        c.janet_vm.blocks = nextOf(head);
    }
    c.janet_vm.block_count -= 1;
    c.janet_vm.next_collection -= size;
    c.janet_free(head);
}

fn typeOf(block: *c.JanetGCObject) i32 {
    return block.flags & c.JANET_MEM_TYPEBITS;
}

fn isReachable(block: *c.JanetGCObject) bool {
    return block.flags & c.JANET_MEM_REACHABLE != 0;
}

/// The only thing `janet_gcpressure` does is move the threshold. It must not
/// collect, and it must not touch the block count — the bytes it is told about
/// were allocated outside the collector's accounting.
fn theGcPressure() void {
    const before = c.janet_vm.next_collection;
    const blocks = c.janet_vm.block_count;

    c.janet_gcpressure(0);
    std.debug.assert(c.janet_vm.next_collection == before);

    c.janet_gcpressure(4096);
    std.debug.assert(c.janet_vm.next_collection == before + 4096);
    std.debug.assert(c.janet_vm.block_count == blocks);

    c.janet_vm.next_collection = before;
}

/// A new block goes on the front of the normal heap, carries its type in the
/// low byte of `flags` and nothing else, and is counted. It is emphatically
/// not marked: the caller has not filled it in yet, and a collection that
/// treated it as reachable would trace uninitialised memory.
fn aNewBlockGoesOnTheNormalHeap() void {
    const size = 128;
    const previous = c.janet_vm.blocks;
    const count = c.janet_vm.block_count;
    const next = c.janet_vm.next_collection;
    const weak = c.janet_vm.weak_blocks;

    const block: *c.JanetGCObject = @ptrCast(@alignCast(c.janet_gcalloc(c.JANET_MEMORY_ARRAY, size).?));
    std.debug.assert(c.janet_vm.blocks == @as(?*anyopaque, block));
    std.debug.assert(nextOf(block) == previous);
    std.debug.assert(typeOf(block) == c.JANET_MEMORY_ARRAY);
    std.debug.assert(block.flags == c.JANET_MEMORY_ARRAY);
    std.debug.assert(!isReachable(block));
    std.debug.assert(c.janet_vm.block_count == count + 1);
    std.debug.assert(c.janet_vm.next_collection == next + size);
    std.debug.assert(c.janet_vm.weak_blocks == weak);

    unlinkHead(false, size);
    std.debug.assert(c.janet_vm.blocks == previous);
    std.debug.assert(c.janet_vm.block_count == count);
    std.debug.assert(c.janet_vm.next_collection == next);
}

/// The four weak types are the ones at or above `JANET_MEMORY_TABLE_WEAKK`,
/// and the boundary is exactly that: the split is a numeric comparison against
/// the first weak constant, not a table of types.
fn theWeakTypesGoOnTheWeakHeap() void {
    const weak_types = [_]c_uint{
        c.JANET_MEMORY_TABLE_WEAKK,
        c.JANET_MEMORY_TABLE_WEAKV,
        c.JANET_MEMORY_TABLE_WEAKKV,
        c.JANET_MEMORY_ARRAY_WEAK,
    };

    for (weak_types) |memory_type| {
        const size = 96;
        const strong = c.janet_vm.blocks;
        const previous = c.janet_vm.weak_blocks;
        const count = c.janet_vm.block_count;

        const block: *c.JanetGCObject = @ptrCast(@alignCast(c.janet_gcalloc(memory_type, size).?));
        std.debug.assert(c.janet_vm.weak_blocks == @as(?*anyopaque, block));
        std.debug.assert(nextOf(block) == previous);
        std.debug.assert(typeOf(block) == @as(i32, @intCast(memory_type)));
        std.debug.assert(c.janet_vm.blocks == strong);
        std.debug.assert(c.janet_vm.block_count == count + 1);

        unlinkHead(true, size);
        std.debug.assert(c.janet_vm.weak_blocks == previous);
        std.debug.assert(c.janet_vm.block_count == count);
    }
}

/// Every type below the boundary goes on the normal heap. Worth stating for
/// `JANET_MEMORY_NONE` in particular, which is zero and therefore the value a
/// caller reaches by mistake.
fn theStrongTypesGoOnTheNormalHeap() void {
    const strong_types = [_]c_uint{
        c.JANET_MEMORY_NONE,
        c.JANET_MEMORY_STRING,
        c.JANET_MEMORY_TABLE,
        c.JANET_MEMORY_FUNCDEF,
        c.JANET_MEMORY_THREADED_ABSTRACT,
    };

    for (strong_types) |memory_type| {
        const weak = c.janet_vm.weak_blocks;
        const block: *c.JanetGCObject = @ptrCast(@alignCast(c.janet_gcalloc(memory_type, 64).?));
        std.debug.assert(c.janet_vm.blocks == @as(?*anyopaque, block));
        std.debug.assert(c.janet_vm.weak_blocks == weak);
        std.debug.assert(typeOf(block) == @as(i32, @intCast(memory_type)));
        unlinkHead(false, 64);
    }
}

/// Successive allocations chain: the list is singly linked through the
/// header's `next`, newest first.
fn allocationsChainNewestFirst() void {
    const previous = c.janet_vm.blocks;
    const first: *c.JanetGCObject = @ptrCast(@alignCast(c.janet_gcalloc(c.JANET_MEMORY_NONE, 32).?));
    const second: *c.JanetGCObject = @ptrCast(@alignCast(c.janet_gcalloc(c.JANET_MEMORY_NONE, 32).?));
    const third: *c.JanetGCObject = @ptrCast(@alignCast(c.janet_gcalloc(c.JANET_MEMORY_NONE, 32).?));

    std.debug.assert(c.janet_vm.blocks == @as(?*anyopaque, third));
    std.debug.assert(nextOf(third) == @as(?*anyopaque, second));
    std.debug.assert(nextOf(second) == @as(?*anyopaque, first));
    std.debug.assert(nextOf(first) == previous);

    unlinkHead(false, 32);
    unlinkHead(false, 32);
    unlinkHead(false, 32);
    std.debug.assert(c.janet_vm.blocks == previous);
}

/// Rooting appends. The root set is a multiset: n roots need n unroots.
fn theRootSetIsAMultiset() void {
    const base = c.janet_vm.root_count;
    const array = c.janet_array(0);
    const value = c.janet_wrap_array(array);

    c.janet_gcroot(value);
    std.debug.assert(c.janet_vm.root_count == base + 1);
    std.debug.assert(c.janet_unwrap_array(c.janet_vm.roots[base]) == array);

    c.janet_gcroot(value);
    std.debug.assert(c.janet_vm.root_count == base + 2);
    std.debug.assert(c.janet_unwrap_array(c.janet_vm.roots[base + 1]) == array);

    std.debug.assert(c.janet_gcunroot(value) == 1);
    std.debug.assert(c.janet_vm.root_count == base + 1);
    std.debug.assert(c.janet_gcunroot(value) == 1);
    std.debug.assert(c.janet_vm.root_count == base);
    std.debug.assert(c.janet_gcunroot(value) == 0);
    std.debug.assert(c.janet_vm.root_count == base);
}

/// Roots are matched by pointer identity, not by value equality. Two arrays
/// with the same contents are different roots.
fn rootsAreMatchedByPointer() void {
    const base = c.janet_vm.root_count;
    const a = c.janet_wrap_array(c.janet_array(0));
    const b = c.janet_wrap_array(c.janet_array(0));

    c.janet_gcroot(a);
    std.debug.assert(c.janet_gcunroot(b) == 0);
    std.debug.assert(c.janet_vm.root_count == base + 1);
    std.debug.assert(c.janet_gcunroot(a) == 1);
    std.debug.assert(c.janet_vm.root_count == base);
}

/// The three types the collector never traces compare equal to any value of
/// their own type. Rooting one number and unrooting a different one succeeds,
/// which is harmless — the slot held nothing worth keeping either way — but it
/// is observable, so it is pinned here.
fn immediatesMatchAnyValueOfTheirType() void {
    const base = c.janet_vm.root_count;

    c.janet_gcroot(c.janet_wrap_number(1.0));
    std.debug.assert(c.janet_gcunroot(c.janet_wrap_number(9999.0)) == 1);
    std.debug.assert(c.janet_vm.root_count == base);

    c.janet_gcroot(c.janet_wrap_true());
    std.debug.assert(c.janet_gcunroot(c.janet_wrap_false()) == 1);
    std.debug.assert(c.janet_vm.root_count == base);

    c.janet_gcroot(c.janet_wrap_nil());
    std.debug.assert(c.janet_gcunroot(c.janet_wrap_nil()) == 1);
    std.debug.assert(c.janet_vm.root_count == base);

    // Different types never match, immediate or not.
    c.janet_gcroot(c.janet_wrap_number(1.0));
    std.debug.assert(c.janet_gcunroot(c.janet_wrap_true()) == 0);
    std.debug.assert(c.janet_gcunroot(c.janet_wrap_nil()) == 0);
    std.debug.assert(c.janet_gcunroot(c.janet_wrap_number(0.0)) == 1);
    std.debug.assert(c.janet_vm.root_count == base);
}

/// Unrooting fills the vacated slot from the top of the set, so the order of
/// the remaining roots is not the order they were added in.
fn unrootingSwapsFromTheTop() void {
    const base = c.janet_vm.root_count;
    const a = c.janet_array(0);
    const b = c.janet_array(0);
    const d = c.janet_array(0);

    c.janet_gcroot(c.janet_wrap_array(a));
    c.janet_gcroot(c.janet_wrap_array(b));
    c.janet_gcroot(c.janet_wrap_array(d));

    std.debug.assert(c.janet_gcunroot(c.janet_wrap_array(a)) == 1);
    std.debug.assert(c.janet_vm.root_count == base + 2);
    std.debug.assert(c.janet_unwrap_array(c.janet_vm.roots[base]) == d);
    std.debug.assert(c.janet_unwrap_array(c.janet_vm.roots[base + 1]) == b);

    std.debug.assert(c.janet_gcunroot(c.janet_wrap_array(b)) == 1);
    std.debug.assert(c.janet_gcunroot(c.janet_wrap_array(d)) == 1);
    std.debug.assert(c.janet_vm.root_count == base);
}

/// `janet_gcunrootall` does not remove every rooting, despite what its comment
/// in the C original said. It fills the vacated slot from the top and then
/// advances, so the value it just moved down is never examined: n rootings
/// become floor(n / 2). `FOUND.md` carries the defect; this pins the behaviour
/// the port has to produce.
fn unrootAllHalves() void {
    for ([_]usize{ 1, 2, 3, 4, 5, 8 }) |n| {
        const base = c.janet_vm.root_count;
        const value = c.janet_wrap_array(c.janet_array(0));

        for (0..n) |_| c.janet_gcroot(value);
        std.debug.assert(c.janet_vm.root_count == base + n);

        std.debug.assert(c.janet_gcunrootall(value) == 1);
        std.debug.assert(c.janet_vm.root_count == base + n / 2);

        // What survives really is still rooted, and can be removed one at a
        // time.
        for (0..n / 2) |_| std.debug.assert(c.janet_gcunroot(value) == 1);
        std.debug.assert(c.janet_vm.root_count == base);
        std.debug.assert(c.janet_gcunrootall(value) == 0);
    }
}

/// An absent value reports absence and changes nothing.
fn unrootAllOfAnAbsentValue() void {
    const base = c.janet_vm.root_count;
    const a = c.janet_wrap_array(c.janet_array(0));
    const b = c.janet_wrap_array(c.janet_array(0));

    c.janet_gcroot(a);
    std.debug.assert(c.janet_gcunrootall(b) == 0);
    std.debug.assert(c.janet_vm.root_count == base + 1);
    std.debug.assert(c.janet_gcunroot(a) == 1);
    std.debug.assert(c.janet_vm.root_count == base);
}

/// Growth is by doubling the required count, and the roots survive it.
fn theRootSetGrows() void {
    const base = c.janet_vm.root_count;
    const value = c.janet_wrap_array(c.janet_array(0));
    var added: usize = 0;

    while (c.janet_vm.root_count < c.janet_vm.root_capacity) {
        c.janet_gcroot(value);
        added += 1;
    }
    const at_capacity = c.janet_vm.root_capacity;

    c.janet_gcroot(value);
    added += 1;
    std.debug.assert(c.janet_vm.root_capacity == 2 * (at_capacity + 1));
    std.debug.assert(c.janet_vm.root_count == base + added);
    for (0..added) |index| {
        std.debug.assert(c.janet_unwrap_array(c.janet_vm.roots[base + index]) ==
            c.janet_unwrap_array(value));
    }

    for (0..added) |_| std.debug.assert(c.janet_gcunroot(value) == 1);
    std.debug.assert(c.janet_vm.root_count == base);
}

/// The handle is the depth to restore, not a token to match. Unlocking with an
/// outer handle discards every lock taken since, which is what makes it safe
/// for a cleanup path to hold one handle across nested regions.
fn theSuspendCounterNests() void {
    const base = c.janet_vm.gc_suspend;

    const outer = c.janet_gclock();
    std.debug.assert(outer == base);
    std.debug.assert(c.janet_vm.gc_suspend == base + 1);

    const inner = c.janet_gclock();
    std.debug.assert(inner == base + 1);
    std.debug.assert(c.janet_vm.gc_suspend == base + 2);

    c.janet_gcunlock(inner);
    std.debug.assert(c.janet_vm.gc_suspend == base + 1);
    c.janet_gcunlock(outer);
    std.debug.assert(c.janet_vm.gc_suspend == base);

    const held = c.janet_gclock();
    _ = c.janet_gclock();
    _ = c.janet_gclock();
    std.debug.assert(c.janet_vm.gc_suspend == base + 3);
    c.janet_gcunlock(held);
    std.debug.assert(c.janet_vm.gc_suspend == base);
}

/// A suspended collector does not collect. This is the one property the
/// counter exists for, and it is checked through `janet_collect` rather than by
/// reading the field back.
fn aSuspendedCollectorDoesNotCollect() void {
    const handle = c.janet_gclock();
    c.janet_vm.next_collection = 12345;
    c.janet_collect();
    std.debug.assert(c.janet_vm.next_collection == 12345);
    c.janet_gcunlock(handle);
    c.janet_collect();
    std.debug.assert(c.janet_vm.next_collection == 0);
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
    const base = c.janet_vm.scratch_len;

    const p: [*]u8 = @ptrCast(c.janet_smalloc(40).?);
    std.debug.assert(c.janet_vm.scratch_len == base + 1);
    std.debug.assert(c.janet_vm.scratch_mem[base] == headerOf(p));
    std.debug.assert(headerOf(p).finalize == null);
    std.debug.assert(@intFromPtr(p) % @alignOf(c_longlong) == 0);

    @memset(p[0..40], 'x');
    c.janet_sfree(p);
    std.debug.assert(c.janet_vm.scratch_len == base);
}

/// `janet_scalloc` zeroes, and the zero-length cases still produce a
/// registered block.
fn scallocZeroes() void {
    const base = c.janet_vm.scratch_len;

    const p: [*]u8 = @ptrCast(c.janet_scalloc(9, 7).?);
    std.debug.assert(c.janet_vm.scratch_len == base + 1);
    for (p[0..63]) |byte| std.debug.assert(byte == 0);

    const empty = c.janet_scalloc(0, 16);
    std.debug.assert(empty != null);
    std.debug.assert(c.janet_vm.scratch_len == base + 2);

    const empty2 = c.janet_scalloc(16, 0);
    std.debug.assert(empty2 != null);
    std.debug.assert(c.janet_vm.scratch_len == base + 3);

    c.janet_sfree(empty2);
    c.janet_sfree(empty);
    c.janet_sfree(p);
    std.debug.assert(c.janet_vm.scratch_len == base);
}

/// `janet_srealloc` keeps the block in the same table slot, preserves the
/// bytes that fit, and carries the finalizer across — the header moves with
/// the allocation. A null pointer means allocate.
fn sreallocKeepsItsSlot() void {
    const base = c.janet_vm.scratch_len;

    const fresh = c.janet_srealloc(null, 24);
    std.debug.assert(fresh != null);
    std.debug.assert(c.janet_vm.scratch_len == base + 1);
    std.debug.assert(scratchIndexOf(fresh).? == base);
    c.janet_sfree(fresh);

    const p: [*]u8 = @ptrCast(c.janet_smalloc(16).?);
    @memcpy(p[0..16], "0123456789abcde\x00");
    c.janet_sfinalizer(p, recordFinalizer);
    const slot = scratchIndexOf(p).?;

    const grown: [*]u8 = @ptrCast(c.janet_srealloc(p, 4096).?);
    std.debug.assert(c.janet_vm.scratch_len == base + 1);
    std.debug.assert(scratchIndexOf(grown).? == slot);
    std.debug.assert(std.mem.eql(u8, grown[0..15], "0123456789abcde"));
    std.debug.assert(headerOf(grown).finalize == recordFinalizer);

    const shrunk: [*]u8 = @ptrCast(c.janet_srealloc(grown, 8).?);
    std.debug.assert(c.janet_vm.scratch_len == base + 1);
    std.debug.assert(scratchIndexOf(shrunk).? == slot);
    std.debug.assert(std.mem.eql(u8, shrunk[0..8], "01234567"));

    finalizer_calls = 0;
    c.janet_sfree(shrunk);
    std.debug.assert(finalizer_calls == 1);
    std.debug.assert(finalizer_args[0] == @as(?*anyopaque, @ptrCast(shrunk)));
    std.debug.assert(c.janet_vm.scratch_len == base);
}

/// Freeing fills the vacated table slot from the top, the same way the root
/// set does, and a null pointer is a no-op.
fn sfreeSwapsFromTheTop() void {
    const base = c.janet_vm.scratch_len;

    const a = c.janet_smalloc(8);
    const b = c.janet_smalloc(8);
    const d = c.janet_smalloc(8);
    std.debug.assert(c.janet_vm.scratch_len == base + 3);

    c.janet_sfree(null);
    std.debug.assert(c.janet_vm.scratch_len == base + 3);

    c.janet_sfree(a);
    std.debug.assert(c.janet_vm.scratch_len == base + 2);
    std.debug.assert(scratchIndexOf(d).? == base);
    std.debug.assert(scratchIndexOf(b).? == base + 1);

    c.janet_sfree(b);
    c.janet_sfree(d);
    std.debug.assert(c.janet_vm.scratch_len == base);
}

/// A finalizer runs once, with the caller's pointer rather than the header.
fn aScratchFinalizerRunsOnce() void {
    const base = c.janet_vm.scratch_len;

    var p = c.janet_smalloc(8);
    finalizer_calls = 0;
    c.janet_sfree(p);
    std.debug.assert(finalizer_calls == 0);

    p = c.janet_smalloc(8);
    c.janet_sfinalizer(p, recordFinalizer);
    finalizer_calls = 0;
    c.janet_sfree(p);
    std.debug.assert(finalizer_calls == 1);
    std.debug.assert(finalizer_args[0] == p);
    std.debug.assert(c.janet_vm.scratch_len == base);
}

/// The table grows to twice what is needed plus two, and everything already in
/// it survives the move.
fn theScratchTableGrows() void {
    var held: [64]?*anyopaque = undefined;
    const base = c.janet_vm.scratch_len;
    var count: usize = 0;

    while (c.janet_vm.scratch_len < c.janet_vm.scratch_cap) {
        held[count] = c.janet_smalloc(8);
        @memset(@as([*]u8, @ptrCast(held[count].?))[0..8], @intCast(count));
        count += 1;
        std.debug.assert(count < held.len);
    }
    const at_capacity = c.janet_vm.scratch_cap;

    held[count] = c.janet_smalloc(8);
    @memset(@as([*]u8, @ptrCast(held[count].?))[0..8], @intCast(count));
    count += 1;
    std.debug.assert(c.janet_vm.scratch_cap == 2 * at_capacity + 2);
    std.debug.assert(c.janet_vm.scratch_len == base + count);

    for (0..count) |index| {
        std.debug.assert(scratchIndexOf(held[index]) != null);
        const bytes: [*]u8 = @ptrCast(held[index].?);
        for (bytes[0..8]) |byte| std.debug.assert(byte == @as(u8, @intCast(index)));
    }
    for (0..count) |index| c.janet_sfree(held[index]);
    std.debug.assert(c.janet_vm.scratch_len == base);
}

/// Releasing everything runs each finalizer and empties the table. This is what
/// `janet_collect` does at the end of a collection and `janet_clear_memory`
/// does at shutdown, which is why the scratch API needs no explicit free to be
/// correct.
fn freeAllScratchRunsEveryFinalizer() void {
    c.janet_collect();
    std.debug.assert(c.janet_vm.scratch_len == 0);

    const a = c.janet_smalloc(8);
    _ = c.janet_smalloc(8);
    const d = c.janet_smalloc(8);
    c.janet_sfinalizer(a, recordFinalizer);
    c.janet_sfinalizer(d, recordFinalizer);

    finalizer_calls = 0;
    c.janet_free_all_scratch();
    std.debug.assert(c.janet_vm.scratch_len == 0);
    std.debug.assert(finalizer_calls == 2);
    std.debug.assert(finalizer_args[0] == a);
    std.debug.assert(finalizer_args[1] == d);
}

/// And a collection does the same, on its way out.
fn aCollectionFreesScratch() void {
    const p = c.janet_smalloc(8);
    c.janet_sfinalizer(p, recordFinalizer);
    finalizer_calls = 0;
    c.janet_collect();
    std.debug.assert(finalizer_calls == 1);
    std.debug.assert(finalizer_args[0] == p);
    std.debug.assert(c.janet_vm.scratch_len == 0);
}

pub fn run() void {
    _ = c.janet_init();

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

    c.janet_deinit();
}
