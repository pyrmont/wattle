//! Behavioral contract for the two growable containers: `JanetBuffer` and
//! `JanetArray`.
//!
//! These are the easiest containers in the runtime to observe, because almost
//! everything they do is visible in three `int32_t` fields and a pointer. So
//! this file asserts the fields directly rather than through the standard
//! library: `count`, `capacity`, and what `data` holds after each operation.
//! The capacity policy is the interesting part — both types overshoot by a
//! caller-supplied growth factor, and the exact resulting capacity is a
//! contract, not an implementation detail, because `array/ensure` exposes it
//! to Janet code.
//!
//! GC pressure is the second channel. Both halves charge
//! `janet_vm.next_collection` for the payloads they allocate, and they do it
//! inconsistently — the buffer charges before its `janet_realloc` and the
//! array after, `janet_array_n` charges nothing at all. None of that is a
//! defect, but all of it is observable, so it is pinned here.
//!
//! ## What the refusals cost, before and after
//!
//! The C original reached a refusal through an `EXPECT_PANIC` macro: open a
//! scope, arm `janet_contract_arm`, call the C-ABI face, read
//! `janet_contract_raised`, read `janet_contract_signal`, restore, and compare
//! the payload string — twenty lines of macro for six call sites, plus a
//! `panics_fired` tally at the foot to prove all six had run.
//!
//! Here a refusal is a value. `harness.raised` returns the `Raise` or null,
//! the assertion is one line at the site, and the tally is gone because a
//! refusal that did not happen fails where it was expected rather than in a
//! count at the end.
//!
//! ## What this file cannot cover, unchanged from the C original
//!
//! `FOUND.md` records that `array/ensure` passes an unchecked growth factor to
//! `janet_array_ensure`, and that a factor of zero or less makes the
//! arithmetic produce a capacity that is zero or negative. The negative case
//! ends the process through `JANET_OUT_OF_MEMORY` — every negative capacity
//! converts to a `usize` near the top of the range, so the allocation always
//! fails — and a test cannot survive it. The zero case depends on the C
//! library: `realloc(p, 0)` returns a minimal block on macOS and NULL on
//! glibc, and the second answer also reaches `JANET_OUT_OF_MEMORY`. So the
//! zero case is asserted only after probing the allocator for which answer it
//! gives, and the negative case is left to `FOUND.md`'s reproducer.
//!
//! Two overflow refusals are also uncovered. `bufferExtra`'s is asserted below
//! because it is reachable with a large `n` and an empty buffer, but
//! `arrayPush`'s requires an array of `INT32_MAX` elements to already exist,
//! which is not something a test can arrange.

const std = @import("std");
const abi = @import("abi");
const c = abi.c;
const harness = @import("harness.zig");
const buffer_array = @import("subsystems").buffer_array;

const heap = harness.heap;

// --------------------------------------------------------------- helpers

/// Does this C library's `realloc(p, 0)` return a block, or NULL? The answer
/// decides whether the zero-growth case in `janet_array_ensure` returns or
/// exits, and it is a property of the allocator rather than of Janet.
fn reallocZeroReturnsABlock() bool {
    const p = c.janet_malloc(16);
    std.debug.assert(p != null);
    const q = c.janet_realloc(p, 0);
    if (q == null) return false;
    c.janet_free(q);
    return true;
}

// ---------------------------------------------------------------- buffer

/// A collectable buffer starts empty, lands on the strong heap list, and is
/// given a floor of four bytes of capacity however little was asked for. The
/// floor is the buffer's alone; `janet_array` has no equivalent.
fn bufferStartsWithACapacityFloor() void {
    const b = c.janet_buffer(0);
    std.debug.assert(b.*.count == 0);
    std.debug.assert(b.*.capacity == 4);
    std.debug.assert(b.*.data != null);
    std.debug.assert(heap.memoryType(b) == c.JANET_MEMORY_BUFFER);
    std.debug.assert(heap.onList(c.janet_vm.blocks, b));

    const big = c.janet_buffer(100);
    std.debug.assert(big.*.capacity == 100);
    std.debug.assert(big.*.count == 0);

    // Exactly at the floor, and one below it.
    std.debug.assert(c.janet_buffer(4).*.capacity == 4);
    std.debug.assert(c.janet_buffer(3).*.capacity == 4);
    std.debug.assert(c.janet_buffer(-1).*.capacity == 4);
}

/// A buffer the caller owns is marked disabled and is not linked into a heap
/// list, so the collector never reaches it and never frees it.
fn callerOwnedBufferIsDisabled() !void {
    var b: c.JanetBuffer = undefined;
    @memset(std.mem.asBytes(&b), 0xAA);
    const returned = c.janet_buffer_init(&b, 32);
    std.debug.assert(returned == &b);
    std.debug.assert(b.count == 0);
    std.debug.assert(b.capacity == 32);
    std.debug.assert(b.data != null);
    std.debug.assert(b.gc.flags == c.JANET_MEM_DISABLED);
    std.debug.assert(b.gc.data.next == null);
    std.debug.assert(!heap.onList(c.janet_vm.blocks, &b));

    // It still behaves as a buffer, and deinit releases the payload.
    try buffer_array.bufferPushCString(&b, "hello");
    std.debug.assert(b.count == 5);
    std.debug.assert(std.mem.eql(u8, b.data[0..5], "hello"));
    c.janet_buffer_deinit(&b);
    std.debug.assert(b.data == null);
}

/// The foreign memory a pointer buffer wraps. At file scope because the buffer
/// outlives the case that makes it, exactly as the C original's `static` did.
var foreign = [8]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };

/// A pointer buffer wraps memory the runtime did not allocate. The block is
/// collectable but the payload is not: the NO_REALLOC flag makes every growth
/// path refuse and makes deinit leave the foreign pointer alone.
fn pointerBufferNeverReallocates() !void {
    const b = try buffer_array.pointerBufferUnsafe(&foreign, 8, 3);
    std.debug.assert(b.data == @as([*c]u8, &foreign));
    std.debug.assert(b.capacity == 8);
    std.debug.assert(b.count == 3);
    std.debug.assert(b.gc.flags & c.JANET_BUFFER_FLAG_NO_REALLOC != 0);
    std.debug.assert(heap.memoryType(b) == c.JANET_MEMORY_BUFFER);
    std.debug.assert(heap.onList(c.janet_vm.blocks, b));

    // Growing within the existing capacity is fine -- `bufferEnsure` returns
    // before it consults the flag.
    try buffer_array.bufferEnsure(b, 8, 1);
    std.debug.assert(b.data == @as([*c]u8, &foreign));

    // Growing past it is refused, and so is the guard called directly.
    const refusal = "buffer cannot reallocate foreign memory";
    std.debug.assert(harness.raised(
        buffer_array.bufferEnsure,
        .{ b, @as(i32, 9), @as(i32, 1) },
    ).?.says(refusal));
    std.debug.assert(harness.raised(
        buffer_array.bufferExtra,
        .{ b, @as(i32, 100) },
    ).?.says(refusal));
    std.debug.assert(harness.raised(buffer_array.canRealloc, .{b}).?.says(refusal));
    std.debug.assert(b.data == @as([*c]u8, &foreign));
    std.debug.assert(b.capacity == 8);

    // Deinit leaves the foreign memory intact rather than freeing it.
    c.janet_buffer_deinit(b);
    std.debug.assert(b.data == @as([*c]u8, &foreign));
    std.debug.assert(foreign[0] == 1 and foreign[7] == 8);

    // Its arguments are validated before the block is allocated.
    std.debug.assert(harness.raised(
        buffer_array.pointerBufferUnsafe,
        .{ @as(?*anyopaque, &foreign), @as(i32, 8), @as(i32, -1) },
    ).?.says("count < 0"));
    std.debug.assert(harness.raised(
        buffer_array.pointerBufferUnsafe,
        .{ @as(?*anyopaque, &foreign), @as(i32, 2), @as(i32, 3) },
    ).?.says("capacity < count"));
}

/// The growth factor multiplies the requested capacity, and the request is
/// ignored outright when the buffer is already large enough.
fn bufferEnsureAppliesTheGrowthFactor() !void {
    const b = c.janet_buffer(10);
    const before = b.*.data;

    // Already big enough: no reallocation, no change, no pressure.
    const charge = c.janet_vm.next_collection;
    try buffer_array.bufferEnsure(b, 10, 2);
    try buffer_array.bufferEnsure(b, 4, 8);
    std.debug.assert(b.*.capacity == 10);
    std.debug.assert(b.*.data == before);
    std.debug.assert(c.janet_vm.next_collection == charge);

    // Past it: the new capacity is the request times the growth.
    try buffer_array.bufferEnsure(b, 11, 3);
    std.debug.assert(b.*.capacity == 33);

    try buffer_array.bufferEnsure(b, 100, 1);
    std.debug.assert(b.*.capacity == 100);

    // The count is never touched by a capacity change.
    try buffer_array.bufferPushCString(b, "abc");
    try buffer_array.bufferEnsure(b, 500, 2);
    std.debug.assert(b.*.capacity == 1000);
    std.debug.assert(b.*.count == 3);
    std.debug.assert(std.mem.eql(u8, b.*.data[0..3], "abc"));
}

/// Growing the count zero-fills the bytes it newly covers; shrinking keeps the
/// capacity and the bytes above the new count. A negative count does nothing.
fn bufferSetcountZeroFills() !void {
    const b = c.janet_buffer(4);
    try buffer_array.bufferPushCString(b, "xy");
    std.debug.assert(b.*.count == 2);

    try buffer_array.bufferSetcount(b, 6);
    std.debug.assert(b.*.count == 6);
    std.debug.assert(b.*.capacity >= 6);
    std.debug.assert(std.mem.eql(u8, b.*.data[0..6], "xy\x00\x00\x00\x00"));

    // Shrinking leaves the capacity alone.
    const capacity = b.*.capacity;
    try buffer_array.bufferSetcount(b, 1);
    std.debug.assert(b.*.count == 1);
    std.debug.assert(b.*.capacity == capacity);

    // And growing again re-zeroes, rather than exposing the old bytes.
    b.*.data[3] = 0xFF;
    try buffer_array.bufferSetcount(b, 4);
    std.debug.assert(b.*.count == 4);
    std.debug.assert(b.*.data[3] == 0);

    // A negative count is a no-op, not a truncation to zero.
    try buffer_array.bufferSetcount(b, -1);
    std.debug.assert(b.*.count == 4);
}

/// `bufferExtra` reserves room without moving the count, and doubles rather
/// than using the growth factor.
fn bufferExtraDoubles() !void {
    const b = c.janet_buffer(4);
    try buffer_array.bufferPushCString(b, "ab");

    // Room already there: nothing happens.
    const capacity = b.*.capacity;
    try buffer_array.bufferExtra(b, 2);
    std.debug.assert(b.*.capacity == capacity);
    std.debug.assert(b.*.count == 2);

    // Room not there: capacity becomes twice what was needed.
    try buffer_array.bufferExtra(b, 9);
    std.debug.assert(b.*.capacity == 22);
    std.debug.assert(b.*.count == 2);
    std.debug.assert(std.mem.eql(u8, b.*.data[0..2], "ab"));

    // The overflow guard runs before any allocation.
    std.debug.assert(harness.raised(
        buffer_array.bufferExtra,
        .{ b, @as(i32, std.math.maxInt(i32)) },
    ).?.says("buffer overflow"));
    std.debug.assert(b.*.capacity == 22);
    std.debug.assert(b.*.count == 2);
}

/// The push primitives, including the byte order of the multi-byte ones. They
/// shift rather than copy, so the layout is little-endian on every host.
fn bufferPushesLittleEndian() !void {
    const b = c.janet_buffer(4);

    try buffer_array.bufferPushU8(b, 0xAB);
    std.debug.assert(b.*.count == 1 and b.*.data[0] == 0xAB);

    try buffer_array.bufferSetcount(b, 0);
    try buffer_array.bufferPushU16(b, 0x1234);
    std.debug.assert(b.*.count == 2);
    std.debug.assert(b.*.data[0] == 0x34 and b.*.data[1] == 0x12);

    try buffer_array.bufferSetcount(b, 0);
    try buffer_array.bufferPushU32(b, 0x12345678);
    std.debug.assert(b.*.count == 4);
    std.debug.assert(b.*.data[0] == 0x78 and b.*.data[1] == 0x56);
    std.debug.assert(b.*.data[2] == 0x34 and b.*.data[3] == 0x12);

    try buffer_array.bufferSetcount(b, 0);
    const wide: u64 = 0x0123456789ABCDEF;
    try buffer_array.bufferPushU64(b, wide);
    std.debug.assert(b.*.count == 8);
    for (0..8) |i| {
        const byte: u8 = @truncate(wide >> @intCast(8 * i));
        std.debug.assert(b.*.data[i] == byte);
    }

    // Bytes, C strings, and Janet strings. A zero-length push is a no-op that
    // does not even reserve, which is why it can be checked by capacity.
    try buffer_array.bufferSetcount(b, 0);
    const capacity = b.*.capacity;
    try buffer_array.bufferPushBytes(b, "ignored", 0);
    std.debug.assert(b.*.count == 0 and b.*.capacity == capacity);

    try buffer_array.bufferPushBytes(b, "one", 3);
    try buffer_array.bufferPushCString(b, "two");
    try buffer_array.bufferPushString(b, c.janet_cstring("three"));
    std.debug.assert(b.*.count == 11);
    std.debug.assert(std.mem.eql(u8, b.*.data[0..11], "onetwothree"));

    // A Janet string may hold an interior zero, and the length comes from its
    // head rather than from the bytes.
    try buffer_array.bufferSetcount(b, 0);
    try buffer_array.bufferPushString(b, c.janet_string("a\x00b", 3));
    std.debug.assert(b.*.count == 3);
    std.debug.assert(std.mem.eql(u8, b.*.data[0..3], "a\x00b"));
}

/// Every payload the buffer allocates is charged to the collector.
fn bufferChargesGcPressure() !void {
    var charge = c.janet_vm.next_collection;
    const b = c.janet_buffer(64);
    // `janet_gcalloc` charges the block, and the payload is charged on top.
    std.debug.assert(c.janet_vm.next_collection == charge + @sizeOf(c.JanetBuffer) + 64);

    charge = c.janet_vm.next_collection;
    try buffer_array.bufferEnsure(b, 100, 2);
    std.debug.assert(b.*.capacity == 200);
    std.debug.assert(c.janet_vm.next_collection == charge + (200 - 64));

    charge = c.janet_vm.next_collection;
    try buffer_array.bufferSetcount(b, 300);
    std.debug.assert(b.*.capacity == 300);
    std.debug.assert(c.janet_vm.next_collection == charge + (300 - 200));

    // The floor is charged, not the request.
    charge = c.janet_vm.next_collection;
    _ = c.janet_buffer(1);
    std.debug.assert(c.janet_vm.next_collection == charge + @sizeOf(c.JanetBuffer) + 4);
}

// ----------------------------------------------------------------- array

/// An array has no capacity floor, and a capacity of zero means no payload at
/// all rather than an empty one.
fn arrayHasNoCapacityFloor() !void {
    const a = c.janet_array(0);
    std.debug.assert(a.*.count == 0);
    std.debug.assert(a.*.capacity == 0);
    std.debug.assert(a.*.data == null);
    std.debug.assert(heap.memoryType(a) == c.JANET_MEMORY_ARRAY);
    std.debug.assert(heap.onList(c.janet_vm.blocks, a));

    const b = c.janet_array(3);
    std.debug.assert(b.*.capacity == 3);
    std.debug.assert(b.*.count == 0);
    std.debug.assert(b.*.data != null);

    // And it grows from nothing without special-casing the null payload.
    try buffer_array.arrayPush(a, harness.wrapInteger(7));
    std.debug.assert(a.*.count == 1);
    std.debug.assert(a.*.capacity == 2);
    std.debug.assert(harness.equals(a.*.data[0], harness.wrapInteger(7)));
}

/// A weak array differs only in its memory type, which puts it on the other
/// heap list and hands it to the weak half of the sweep.
fn weakArrayIsANormalArrayElsewhere() !void {
    const a = c.janet_array_weak(4);
    std.debug.assert(heap.memoryType(a) == c.JANET_MEMORY_ARRAY_WEAK);
    std.debug.assert(heap.onList(c.janet_vm.weak_blocks, a));
    std.debug.assert(!heap.onList(c.janet_vm.blocks, a));
    std.debug.assert(a.*.capacity == 4);
    std.debug.assert(a.*.count == 0);

    try buffer_array.arrayPush(a, harness.wrapInteger(1));
    std.debug.assert(a.*.count == 1);
    std.debug.assert(a.*.capacity == 4);

    // The strong twin is on the other list, and nothing else differs.
    const s = c.janet_array(4);
    std.debug.assert(heap.onList(c.janet_vm.blocks, s));
    std.debug.assert(!heap.onList(c.janet_vm.weak_blocks, s));
    std.debug.assert(s.*.capacity == a.*.capacity);
}

/// `janet_array_n` copies its elements and sets count and capacity to the same
/// value, so the result is exactly full.
fn arrayNIsExactlyFull() void {
    var elements = [3]c.Janet{
        harness.wrapInteger(10),
        c.janet_wrap_keyword(c.janet_cstring("k")),
        c.janet_wrap_nil(),
    };

    const a = c.janet_array_n(&elements, 3);
    std.debug.assert(a.*.count == 3);
    std.debug.assert(a.*.capacity == 3);
    std.debug.assert(harness.equals(a.*.data[0], elements[0]));
    std.debug.assert(harness.equals(a.*.data[1], elements[1]));
    std.debug.assert(harness.isType(a.*.data[2], c.JANET_NIL));

    // The source is copied, not aliased.
    elements[0] = harness.wrapInteger(99);
    std.debug.assert(harness.equals(a.*.data[0], harness.wrapInteger(10)));

    // Zero elements is legal and allocates nothing to copy into.
    const empty = c.janet_array_n(&elements, 0);
    std.debug.assert(empty.*.count == 0);
    std.debug.assert(empty.*.capacity == 0);
}

/// The array's growth factor behaves as the buffer's does. This is the policy
/// `array/ensure` exposes to Janet, so the exact capacities are a contract.
fn arrayEnsureAppliesTheGrowthFactor() !void {
    const a = c.janet_array(10);
    const before = a.*.data;

    const charge = c.janet_vm.next_collection;
    c.janet_array_ensure(a, 10, 2);
    c.janet_array_ensure(a, 4, 8);
    std.debug.assert(a.*.capacity == 10);
    std.debug.assert(a.*.data == before);
    std.debug.assert(c.janet_vm.next_collection == charge);

    c.janet_array_ensure(a, 11, 3);
    std.debug.assert(a.*.capacity == 33);

    c.janet_array_ensure(a, 100, 1);
    std.debug.assert(a.*.capacity == 100);

    // Contents and count survive a reallocation.
    try buffer_array.arrayPush(a, harness.wrapInteger(5));
    c.janet_array_ensure(a, 500, 2);
    std.debug.assert(a.*.capacity == 1000);
    std.debug.assert(a.*.count == 1);
    std.debug.assert(harness.equals(a.*.data[0], harness.wrapInteger(5)));
}

/// Growing the count fills with nil, not with zero bytes; a negative count is
/// a no-op. Pushing doubles, and popping and peeking on an empty array give
/// nil rather than failing.
fn arraySetcountPushPopPeek() !void {
    const a = c.janet_array(0);

    std.debug.assert(harness.isType(c.janet_array_pop(a), c.JANET_NIL));
    std.debug.assert(harness.isType(c.janet_array_peek(a), c.JANET_NIL));
    std.debug.assert(a.*.count == 0);

    c.janet_array_setcount(a, 3);
    std.debug.assert(a.*.count == 3);
    for (0..3) |i| std.debug.assert(harness.isType(a.*.data[i], c.JANET_NIL));

    a.*.data[2] = harness.wrapInteger(2);
    c.janet_array_setcount(a, 1);
    std.debug.assert(a.*.count == 1);
    c.janet_array_setcount(a, 3);
    // Re-extending fills with nil again rather than exposing the old value.
    std.debug.assert(harness.isType(a.*.data[2], c.JANET_NIL));

    c.janet_array_setcount(a, -5);
    std.debug.assert(a.*.count == 3);

    c.janet_array_setcount(a, 0);
    try buffer_array.arrayPush(a, harness.wrapInteger(1));
    try buffer_array.arrayPush(a, harness.wrapInteger(2));
    std.debug.assert(a.*.count == 2);
    std.debug.assert(harness.equals(c.janet_array_peek(a), harness.wrapInteger(2)));
    std.debug.assert(a.*.count == 2);
    std.debug.assert(harness.equals(c.janet_array_pop(a), harness.wrapInteger(2)));
    std.debug.assert(a.*.count == 1);
    std.debug.assert(harness.equals(c.janet_array_pop(a), harness.wrapInteger(1)));
    std.debug.assert(a.*.count == 0);
    std.debug.assert(harness.isType(c.janet_array_pop(a), c.JANET_NIL));
}

/// The array's GC accounting, including the two asymmetries with the buffer:
/// `janet_array_n` charges nothing, and `janet_array_ensure` charges after its
/// allocation rather than before.
fn arrayChargesGcPressure() void {
    var charge = c.janet_vm.next_collection;
    const a = c.janet_array(64);
    std.debug.assert(c.janet_vm.next_collection ==
        charge + @sizeOf(c.JanetArray) + 64 * @sizeOf(c.Janet));

    charge = c.janet_vm.next_collection;
    c.janet_array_ensure(a, 100, 2);
    std.debug.assert(a.*.capacity == 200);
    std.debug.assert(c.janet_vm.next_collection == charge + (200 - 64) * @sizeOf(c.Janet));

    // A capacity of zero allocates no payload, so only the block is charged.
    charge = c.janet_vm.next_collection;
    _ = c.janet_array(0);
    std.debug.assert(c.janet_vm.next_collection == charge + @sizeOf(c.JanetArray));

    // `janet_array_n` allocates a payload and charges nothing for it.
    var elements = [_]c.Janet{c.janet_wrap_nil()} ** 4;
    charge = c.janet_vm.next_collection;
    const n = c.janet_array_n(&elements, 4);
    std.debug.assert(n.*.capacity == 4);
    std.debug.assert(n.*.data != null);
    std.debug.assert(c.janet_vm.next_collection == charge + @sizeOf(c.JanetArray));
}

/// `FOUND.md`: `array/ensure` hands an unchecked growth factor through, and a
/// factor of zero releases the payload while leaving `count` alone. Asserted
/// deliberately, so that whichever side is fixed first fails here. See the
/// note at the head of this file about why the allocator is probed first.
fn zeroGrowthReleasesThePayload() !void {
    if (!reallocZeroReturnsABlock()) return;

    const a = c.janet_array(0);
    for (0..5) |i| try buffer_array.arrayPush(a, harness.wrapInteger(@intCast(i)));
    std.debug.assert(a.*.count == 5);
    std.debug.assert(a.*.capacity == 6);

    const charge = c.janet_vm.next_collection;
    c.janet_array_ensure(a, 100, 0);

    // The capacity is gone and the count is not, so every element the array
    // claims to hold is now a read of freed memory. Nothing below reads one.
    std.debug.assert(a.*.capacity == 0);
    std.debug.assert(a.*.count == 5);

    // And the accounting term went negative into a `usize`. C spelled this
    // `(size_t)(int32_t)(0 - 6) * sizeof(Janet)`, which is a sign extension
    // followed by a wrapping multiply; `@bitCast` and `*%` are the same two
    // steps named rather than implied.
    const negative: usize = @bitCast(@as(isize, -6));
    std.debug.assert(c.janet_vm.next_collection == charge +% negative *% @sizeOf(c.Janet));

    // Make the array safe for the collector again before returning: the mark
    // phase walks `count` elements, and they are not there any more.
    a.*.count = 0;
}

// ------------------------------------------------------ across the seam

/// The collector frees a container's payload through `janet_deinit_block`,
/// which calls `janet_buffer_deinit` from this subsystem. Both containers are
/// freed the same way, so one collection covers the round trip in both
/// directions.
fn theCollectorReclaimsBoth() !void {
    c.janet_collect();
    const before = c.janet_vm.block_count;

    for (0..10) |_| {
        const b = c.janet_buffer(1000);
        try buffer_array.bufferSetcount(b, 1000);
        const a = c.janet_array(1000);
        c.janet_array_setcount(a, 1000);
        _ = c.janet_array_weak(1000);
    }
    std.debug.assert(c.janet_vm.block_count == before + 30);

    c.janet_collect();
    std.debug.assert(c.janet_vm.block_count == before);

    // A rooted one survives the same collection, and is still usable -- which
    // is the assertion that its payload was not freed underneath it.
    const keep = c.janet_buffer(16);
    try buffer_array.bufferPushCString(keep, "kept");
    c.janet_gcroot(c.janet_wrap_buffer(keep));
    c.janet_collect();
    std.debug.assert(keep.*.count == 4);
    std.debug.assert(std.mem.eql(u8, keep.*.data[0..4], "kept"));
    _ = c.janet_gcunroot(c.janet_wrap_buffer(keep));
}

/// The standard library reaches this code through the core environment, so the
/// two halves have to agree from Janet as well as from Zig. This also
/// exercises `cfun_buffer_trim`, which calls `canRealloc`.
fn fromJanet() void {
    var out: c.Janet = undefined;
    const env = c.janet_core_env(null);
    const source =
        \\(let [b (buffer/new 100)
        \\      a (array/new 10)]
        \\  (buffer/push b "abc")
        \\  (buffer/trim b)
        \\  (array/push a 1)
        \\  (array/push a 2)
        \\  [(length b) (string b) (length a) (array/pop a) (array/peek a)])
    ;
    std.debug.assert(c.janet_dostring(env, source, "buffer-array-test", &out) == 0);
    std.debug.assert(harness.isType(out, c.JANET_TUPLE));
    const t = c.janet_unwrap_tuple(out);
    std.debug.assert(harness.integerIs(t[0], 3));
    std.debug.assert(harness.stringValueIs(t[1], "abc"));
    std.debug.assert(harness.integerIs(t[2], 2));
    std.debug.assert(harness.integerIs(t[3], 2));
    std.debug.assert(harness.integerIs(t[4], 1));
}

fn body() !void {
    bufferStartsWithACapacityFloor();
    try callerOwnedBufferIsDisabled();
    try pointerBufferNeverReallocates();
    try bufferEnsureAppliesTheGrowthFactor();
    try bufferSetcountZeroFills();
    try bufferExtraDoubles();
    try bufferPushesLittleEndian();
    try bufferChargesGcPressure();

    try arrayHasNoCapacityFloor();
    try weakArrayIsANormalArrayElsewhere();
    arrayNIsExactlyFull();
    try arrayEnsureAppliesTheGrowthFactor();
    try arraySetcountPushPopPeek();
    arrayChargesGcPressure();
    try zeroGrowthReleasesThePayload();

    try theCollectorReclaimsBoth();
    fromJanet();
}

pub fn run() void {
    _ = c.janet_init();
    body() catch @panic("buffer_array: a container operation raised unexpectedly");
    c.janet_deinit();
}
