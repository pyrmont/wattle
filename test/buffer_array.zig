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
//! `vm.gc.next_collection` for the payloads they allocate, and they do it
//! inconsistently — the buffer charges before its `janet_realloc` and the
//! array after, `janet_array_n` charges nothing at all. None of that is a
//! defect, but all of it is observable, so it is pinned here.
//!
//! ## What the refusals cost, before and after
//!
//! The C original reached a refusal through an `EXPECT_PANIC` macro: open a
//! scope, arm `janet_contract_arm`, call the abi, read
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
const types = @import("types");
const repr = @import("repr");
const constants = @import("constants");
const harness = @import("harness.zig");
const arrays = @import("subsystems").value.arrays;
const buffers = @import("subsystems").value.buffers;
const tables = @import("subsystems").value.tables;
const gc_alloc = @import("subsystems").gc_alloc;
const strings = @import("subsystems").value.strings;
const utils = @import("subsystems").utils;
const gc_mark = @import("subsystems").gc_mark;
const core_env = @import("subsystems").env;
const wrap = @import("subsystems").value.wrap;
const vm_lifecycle = @import("subsystems").lifecycle;

const heap = harness.heap;

// --------------------------------------------------------------- helpers

/// Does this C library's `realloc(p, 0)` return a block, or NULL? The answer
/// decides whether the zero-growth case in `janet_array_ensure` returns or
/// exits, and it is a property of the allocator rather than of Janet.
fn reallocZeroReturnsABlock() bool {
    const p = utils.malloc(16);
    std.debug.assert(p != null);
    const q = utils.realloc(p, 0);
    if (q == null) return false;
    utils.free(q);
    return true;
}

// ---------------------------------------------------------------- buffer

/// A collectable buffer starts empty, lands on the strong heap list, and is
/// given a floor of four bytes of capacity however little was asked for. The
/// floor is the buffer's alone; `janet_array` has no equivalent.
fn bufferStartsWithACapacityFloor() void {
    const b = buffers.new(0);
    std.debug.assert(b.*.count == 0);
    std.debug.assert(b.*.capacity == 4);
    std.debug.assert(b.*.data != null);
    std.debug.assert(heap.memoryType(b) == types.MemoryType.buffer);
    std.debug.assert(heap.onList(harness.vm().gc.blocks, b));

    const big = buffers.new(100);
    std.debug.assert(big.*.capacity == 100);
    std.debug.assert(big.*.count == 0);

    // Exactly at the floor, and one below it.
    std.debug.assert(buffers.new(4).*.capacity == 4);
    std.debug.assert(buffers.new(3).*.capacity == 4);
    std.debug.assert(buffers.new(-1).*.capacity == 4);
}

/// A buffer the caller owns is marked disabled and is not linked into a heap
/// list, so the collector never reaches it and never frees it.
fn callerOwnedBufferIsDisabled() !void {
    var b: types.JanetBuffer = undefined;
    @memset(std.mem.asBytes(&b), 0xAA);
    const returned = buffers.init(&b, 32);
    std.debug.assert(returned == &b);
    std.debug.assert(b.count == 0);
    std.debug.assert(b.capacity == 32);
    std.debug.assert(b.data != null);
    std.debug.assert(b.gc.flags == constants.JANET_MEM_DISABLED);
    std.debug.assert(b.gc.data.next == null);
    std.debug.assert(!heap.onList(harness.vm().gc.blocks, &b));

    // It still behaves as a buffer, and deinit releases the payload.
    try buffers.pushCString(&b, "hello");
    std.debug.assert(b.count == 5);
    std.debug.assert(std.mem.eql(u8, b.slice()[0..5], "hello"));
    buffers.deinit(&b);
    std.debug.assert(b.data == null);
}

/// The foreign memory a pointer buffer wraps. At file scope because the buffer
/// outlives the case that makes it, exactly as the C original's `static` did.
var foreign = [8]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };

/// A pointer buffer wraps memory the runtime did not allocate. The block is
/// collectable but the payload is not: the NO_REALLOC flag makes every growth
/// path refuse and makes deinit leave the foreign pointer alone.
fn pointerBufferNeverReallocates() !void {
    const b = try buffers.pointerUnsafe(&foreign, 8, 3);
    std.debug.assert(b.data == @as([*]u8, &foreign));
    std.debug.assert(b.capacity == 8);
    std.debug.assert(b.count == 3);
    std.debug.assert(b.gc.flags & constants.JANET_BUFFER_FLAG_NO_REALLOC != 0);
    std.debug.assert(heap.memoryType(b) == types.MemoryType.buffer);
    std.debug.assert(heap.onList(harness.vm().gc.blocks, b));

    // Growing within the existing capacity is fine -- `bufferEnsure` returns
    // before it consults the flag.
    try buffers.ensure(b, 8, 1);
    std.debug.assert(b.data == @as([*]u8, &foreign));

    // Growing past it is refused, and so is the guard called directly.
    const refusal = "buffer cannot reallocate foreign memory";
    std.debug.assert(harness.raised(
        buffers.ensure,
        .{ b, @as(i32, 9), @as(i32, 1) },
    ).?.says(refusal));
    std.debug.assert(harness.raised(
        buffers.extra,
        .{ b, @as(i32, 100) },
    ).?.says(refusal));
    std.debug.assert(harness.raised(buffers.canRealloc, .{b}).?.says(refusal));
    std.debug.assert(b.data == @as([*]u8, &foreign));
    std.debug.assert(b.capacity == 8);

    // Deinit leaves the foreign memory intact rather than freeing it.
    buffers.deinit(b);
    std.debug.assert(b.data == @as([*]u8, &foreign));
    std.debug.assert(foreign[0] == 1 and foreign[7] == 8);

    // Its arguments are validated before the block is allocated.
    std.debug.assert(harness.raised(
        buffers.pointerUnsafe,
        .{ @as(?*anyopaque, &foreign), @as(i32, 8), @as(i32, -1) },
    ).?.says("count < 0"));
    std.debug.assert(harness.raised(
        buffers.pointerUnsafe,
        .{ @as(?*anyopaque, &foreign), @as(i32, 2), @as(i32, 3) },
    ).?.says("capacity < count"));
}

/// The growth factor multiplies the requested capacity, and the request is
/// ignored outright when the buffer is already large enough.
fn bufferEnsureAppliesTheGrowthFactor() !void {
    const b = buffers.new(10);
    const before = b.*.data;

    // Already big enough: no reallocation, no change, no pressure.
    const charge = harness.vm().gc.next_collection;
    try buffers.ensure(b, 10, 2);
    try buffers.ensure(b, 4, 8);
    std.debug.assert(b.*.capacity == 10);
    std.debug.assert(b.*.data == before);
    std.debug.assert(harness.vm().gc.next_collection == charge);

    // Past it: the new capacity is the request times the growth.
    try buffers.ensure(b, 11, 3);
    std.debug.assert(b.*.capacity == 33);

    try buffers.ensure(b, 100, 1);
    std.debug.assert(b.*.capacity == 100);

    // The count is never touched by a capacity change.
    try buffers.pushCString(b, "abc");
    try buffers.ensure(b, 500, 2);
    std.debug.assert(b.*.capacity == 1000);
    std.debug.assert(b.*.count == 3);
    std.debug.assert(std.mem.eql(u8, b.*.slice()[0..3], "abc"));
}

/// Growing the count zero-fills the bytes it newly covers; shrinking keeps the
/// capacity and the bytes above the new count. A negative count does nothing.
fn bufferSetcountZeroFills() !void {
    const b = buffers.new(4);
    try buffers.pushCString(b, "xy");
    std.debug.assert(b.*.count == 2);

    try buffers.setcount(b, 6);
    std.debug.assert(b.*.count == 6);
    std.debug.assert(b.*.capacity >= 6);
    std.debug.assert(std.mem.eql(u8, b.*.slice()[0..6], "xy\x00\x00\x00\x00"));

    // Shrinking leaves the capacity alone.
    const capacity = b.*.capacity;
    try buffers.setcount(b, 1);
    std.debug.assert(b.*.count == 1);
    std.debug.assert(b.*.capacity == capacity);

    // And growing again re-zeroes, rather than exposing the old bytes. The
    // scribble is deliberately outside the live range, so it is written
    // through the allocation rather than through `slice()`.
    b.*.reserved()[3] = 0xFF;
    try buffers.setcount(b, 4);
    std.debug.assert(b.*.count == 4);
    std.debug.assert(b.*.slice()[3] == 0);

    // A negative count is a no-op, not a truncation to zero.
    try buffers.setcount(b, -1);
    std.debug.assert(b.*.count == 4);
}

/// `bufferExtra` reserves room without moving the count, and doubles rather
/// than using the growth factor.
fn bufferExtraDoubles() !void {
    const b = buffers.new(4);
    try buffers.pushCString(b, "ab");

    // Room already there: nothing happens.
    const capacity = b.*.capacity;
    try buffers.extra(b, 2);
    std.debug.assert(b.*.capacity == capacity);
    std.debug.assert(b.*.count == 2);

    // Room not there: capacity becomes twice what was needed.
    try buffers.extra(b, 9);
    std.debug.assert(b.*.capacity == 22);
    std.debug.assert(b.*.count == 2);
    std.debug.assert(std.mem.eql(u8, b.*.slice()[0..2], "ab"));

    // The overflow guard runs before any allocation.
    std.debug.assert(harness.raised(
        buffers.extra,
        .{ b, @as(i32, std.math.maxInt(i32)) },
    ).?.says("buffer overflow"));
    std.debug.assert(b.*.capacity == 22);
    std.debug.assert(b.*.count == 2);
}

/// The push primitives, including the byte order of the multi-byte ones. They
/// shift rather than copy, so the layout is little-endian on every host.
fn bufferPushesLittleEndian() !void {
    const b = buffers.new(4);

    try buffers.pushU8(b, 0xAB);
    std.debug.assert(b.*.count == 1 and b.*.slice()[0] == 0xAB);

    try buffers.setcount(b, 0);
    try buffers.pushU16(b, 0x1234);
    std.debug.assert(b.*.count == 2);
    std.debug.assert(b.*.slice()[0] == 0x34 and b.*.slice()[1] == 0x12);

    try buffers.setcount(b, 0);
    try buffers.pushU32(b, 0x12345678);
    std.debug.assert(b.*.count == 4);
    std.debug.assert(b.*.slice()[0] == 0x78 and b.*.slice()[1] == 0x56);
    std.debug.assert(b.*.slice()[2] == 0x34 and b.*.slice()[3] == 0x12);

    try buffers.setcount(b, 0);
    const wide: u64 = 0x0123456789ABCDEF;
    try buffers.pushU64(b, wide);
    std.debug.assert(b.*.count == 8);
    for (0..8) |i| {
        const byte: u8 = @truncate(wide >> @intCast(8 * i));
        std.debug.assert(b.*.slice()[i] == byte);
    }

    // Bytes, C strings, and Janet strings. A zero-length push is a no-op that
    // does not even reserve, which is why it can be checked by capacity.
    try buffers.setcount(b, 0);
    const capacity = b.*.capacity;
    try buffers.pushBytes(b, "ignored"[0..0]);
    std.debug.assert(b.*.count == 0 and b.*.capacity == capacity);

    try buffers.pushBytes(b, "one");
    try buffers.pushCString(b, "two");
    try buffers.pushString(b, strings.cstring("three"));
    std.debug.assert(b.*.count == 11);
    std.debug.assert(std.mem.eql(u8, b.*.slice()[0..11], "onetwothree"));

    // A Janet string may hold an interior zero, and the length comes from its
    // head rather than from the bytes.
    try buffers.setcount(b, 0);
    try buffers.pushString(b, strings.new("a\x00b"));
    std.debug.assert(b.*.count == 3);
    std.debug.assert(std.mem.eql(u8, b.*.slice()[0..3], "a\x00b"));
}

/// Every payload the buffer allocates is charged to the collector.
fn bufferChargesGcPressure() !void {
    var charge = harness.vm().gc.next_collection;
    const b = buffers.new(64);
    // `janet_gcalloc` charges the block, and the payload is charged on top.
    std.debug.assert(harness.vm().gc.next_collection == charge + @sizeOf(types.JanetBuffer) + 64);

    charge = harness.vm().gc.next_collection;
    try buffers.ensure(b, 100, 2);
    std.debug.assert(b.*.capacity == 200);
    std.debug.assert(harness.vm().gc.next_collection == charge + (200 - 64));

    charge = harness.vm().gc.next_collection;
    try buffers.setcount(b, 300);
    std.debug.assert(b.*.capacity == 300);
    std.debug.assert(harness.vm().gc.next_collection == charge + (300 - 200));

    // The floor is charged, not the request.
    charge = harness.vm().gc.next_collection;
    _ = buffers.new(1);
    std.debug.assert(harness.vm().gc.next_collection == charge + @sizeOf(types.JanetBuffer) + 4);
}

// ----------------------------------------------------------------- array

/// An array has no capacity floor, and a capacity of zero means no payload at
/// all rather than an empty one.
fn arrayHasNoCapacityFloor() !void {
    const a = arrays.new(0);
    std.debug.assert(a.*.count == 0);
    std.debug.assert(a.*.capacity == 0);
    std.debug.assert(a.*.data == null);
    std.debug.assert(heap.memoryType(a) == types.MemoryType.array);
    std.debug.assert(heap.onList(harness.vm().gc.blocks, a));

    const b = arrays.new(3);
    std.debug.assert(b.*.capacity == 3);
    std.debug.assert(b.*.count == 0);
    std.debug.assert(b.*.data != null);

    // And it grows from nothing without special-casing the null payload.
    try arrays.push(a, harness.wrapInteger(7));
    std.debug.assert(a.*.count == 1);
    std.debug.assert(a.*.capacity == 2);
    std.debug.assert(harness.equals(a.*.slice()[0], harness.wrapInteger(7)));
}

/// A weak array differs only in its memory type, which puts it on the other
/// heap list and hands it to the weak half of the sweep.
fn weakArrayIsANormalArrayElsewhere() !void {
    const a = arrays.weak(4);
    std.debug.assert(heap.memoryType(a) == types.MemoryType.array_weak);
    std.debug.assert(heap.onList(harness.vm().gc.weak_blocks, a));
    std.debug.assert(!heap.onList(harness.vm().gc.blocks, a));
    std.debug.assert(a.*.capacity == 4);
    std.debug.assert(a.*.count == 0);

    try arrays.push(a, harness.wrapInteger(1));
    std.debug.assert(a.*.count == 1);
    std.debug.assert(a.*.capacity == 4);

    // The strong twin is on the other list, and nothing else differs.
    const s = arrays.new(4);
    std.debug.assert(heap.onList(harness.vm().gc.blocks, s));
    std.debug.assert(!heap.onList(harness.vm().gc.weak_blocks, s));
    std.debug.assert(s.*.capacity == a.*.capacity);
}

/// `janet_array_n` copies its elements and sets count and capacity to the same
/// value, so the result is exactly full.
fn arrayNIsExactlyFull() void {
    var elements = [3]repr.Value{
        harness.wrapInteger(10),
        wrap.fromKeyword(strings.cstring("k")),
        wrap.fromNil(),
    };

    const a = arrays.newFrom(&elements);
    std.debug.assert(a.*.count == 3);
    std.debug.assert(a.*.capacity == 3);
    std.debug.assert(harness.equals(a.*.slice()[0], elements[0]));
    std.debug.assert(harness.equals(a.*.slice()[1], elements[1]));
    std.debug.assert(harness.isType(a.*.slice()[2], repr.Tag.nil));

    // The source is copied, not aliased.
    elements[0] = harness.wrapInteger(99);
    std.debug.assert(harness.equals(a.*.slice()[0], harness.wrapInteger(10)));

    // Zero elements is legal and allocates nothing to copy into.
    const empty = arrays.newFrom(elements[0..0]);
    std.debug.assert(empty.*.count == 0);
    std.debug.assert(empty.*.capacity == 0);
}

/// The array's growth factor behaves as the buffer's does. This is the policy
/// `array/ensure` exposes to Janet, so the exact capacities are a contract.
fn arrayEnsureAppliesTheGrowthFactor() !void {
    const a = arrays.new(10);
    const before = a.*.data;

    const charge = harness.vm().gc.next_collection;
    arrays.ensure(a, 10, 2);
    arrays.ensure(a, 4, 8);
    std.debug.assert(a.*.capacity == 10);
    std.debug.assert(a.*.data == before);
    std.debug.assert(harness.vm().gc.next_collection == charge);

    arrays.ensure(a, 11, 3);
    std.debug.assert(a.*.capacity == 33);

    arrays.ensure(a, 100, 1);
    std.debug.assert(a.*.capacity == 100);

    // Contents and count survive a reallocation.
    try arrays.push(a, harness.wrapInteger(5));
    arrays.ensure(a, 500, 2);
    std.debug.assert(a.*.capacity == 1000);
    std.debug.assert(a.*.count == 1);
    std.debug.assert(harness.equals(a.*.slice()[0], harness.wrapInteger(5)));
}

/// Growing the count fills with nil, not with zero bytes; a negative count is
/// a no-op. Pushing doubles, and popping and peeking on an empty array give
/// nil rather than failing.
fn arraySetcountPushPopPeek() !void {
    const a = arrays.new(0);

    std.debug.assert(harness.isType(arrays.pop(a), repr.Tag.nil));
    std.debug.assert(harness.isType(arrays.peek(a), repr.Tag.nil));
    std.debug.assert(a.*.count == 0);

    arrays.setcount(a, 3);
    std.debug.assert(a.*.count == 3);
    for (0..3) |i| std.debug.assert(harness.isType(a.*.slice()[i], repr.Tag.nil));

    a.*.slice()[2] = harness.wrapInteger(2);
    arrays.setcount(a, 1);
    std.debug.assert(a.*.count == 1);
    arrays.setcount(a, 3);
    // Re-extending fills with nil again rather than exposing the old value.
    std.debug.assert(harness.isType(a.*.slice()[2], repr.Tag.nil));

    arrays.setcount(a, -5);
    std.debug.assert(a.*.count == 3);

    arrays.setcount(a, 0);
    try arrays.push(a, harness.wrapInteger(1));
    try arrays.push(a, harness.wrapInteger(2));
    std.debug.assert(a.*.count == 2);
    std.debug.assert(harness.equals(arrays.peek(a), harness.wrapInteger(2)));
    std.debug.assert(a.*.count == 2);
    std.debug.assert(harness.equals(arrays.pop(a), harness.wrapInteger(2)));
    std.debug.assert(a.*.count == 1);
    std.debug.assert(harness.equals(arrays.pop(a), harness.wrapInteger(1)));
    std.debug.assert(a.*.count == 0);
    std.debug.assert(harness.isType(arrays.pop(a), repr.Tag.nil));
}

/// The array's GC accounting, including the two asymmetries with the buffer:
/// `janet_array_n` charges nothing, and `janet_array_ensure` charges after its
/// allocation rather than before.
fn arrayChargesGcPressure() void {
    var charge = harness.vm().gc.next_collection;
    const a = arrays.new(64);
    std.debug.assert(harness.vm().gc.next_collection ==
        charge + @sizeOf(types.JanetArray) + 64 * @sizeOf(repr.Value));

    charge = harness.vm().gc.next_collection;
    arrays.ensure(a, 100, 2);
    std.debug.assert(a.*.capacity == 200);
    std.debug.assert(harness.vm().gc.next_collection == charge + (200 - 64) * @sizeOf(repr.Value));

    // A capacity of zero allocates no payload, so only the block is charged.
    charge = harness.vm().gc.next_collection;
    _ = arrays.new(0);
    std.debug.assert(harness.vm().gc.next_collection == charge + @sizeOf(types.JanetArray));

    // `janet_array_n` allocates a payload and charges nothing for it.
    var elements = [_]repr.Value{wrap.fromNil()} ** 4;
    charge = harness.vm().gc.next_collection;
    const n = arrays.newFrom(&elements);
    std.debug.assert(n.*.capacity == 4);
    std.debug.assert(n.*.data != null);
    std.debug.assert(harness.vm().gc.next_collection == charge + @sizeOf(types.JanetArray));
}

/// `FOUND.md`: `array/ensure` hands an unchecked growth factor through, and a
/// factor of zero releases the payload while leaving `count` alone. Asserted
/// deliberately, so that whichever side is fixed first fails here. See the
/// note at the head of this file about why the allocator is probed first.
fn zeroGrowthReleasesThePayload() !void {
    if (!reallocZeroReturnsABlock()) return;

    const a = arrays.new(0);
    for (0..5) |i| try arrays.push(a, harness.wrapInteger(@intCast(i)));
    std.debug.assert(a.*.count == 5);
    std.debug.assert(a.*.capacity == 6);

    const charge = harness.vm().gc.next_collection;
    arrays.ensure(a, 100, 0);

    // The capacity is gone and the count is not, so every element the array
    // claims to hold is now a read of freed memory. Nothing below reads one.
    std.debug.assert(a.*.capacity == 0);
    std.debug.assert(a.*.count == 5);

    // And the accounting term went negative into a `usize`. C spelled this
    // `(size_t)(int32_t)(0 - 6) * sizeof(Janet)`, which is a sign extension
    // followed by a wrapping multiply; `@bitCast` and `*%` are the same two
    // steps named rather than implied.
    const negative: usize = @bitCast(@as(isize, -6));
    std.debug.assert(harness.vm().gc.next_collection == charge +% negative *% @sizeOf(repr.Value));

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
    gc_mark.collect();
    const before = harness.vm().gc.block_count;

    for (0..10) |_| {
        const b = buffers.new(1000);
        try buffers.setcount(b, 1000);
        const a = arrays.new(1000);
        arrays.setcount(a, 1000);
        _ = arrays.weak(1000);
    }
    std.debug.assert(harness.vm().gc.block_count == before + 30);

    gc_mark.collect();
    std.debug.assert(harness.vm().gc.block_count == before);

    // A rooted one survives the same collection, and is still usable -- which
    // is the assertion that its payload was not freed underneath it.
    const keep = buffers.new(16);
    try buffers.pushCString(keep, "kept");
    gc_alloc.gcroot(wrap.fromBuffer(keep));
    gc_mark.collect();
    std.debug.assert(keep.*.count == 4);
    std.debug.assert(std.mem.eql(u8, keep.*.slice()[0..4], "kept"));
    _ = gc_alloc.gcunroot(wrap.fromBuffer(keep));
}

/// The standard library reaches this code through the core environment, so the
/// two halves have to agree from Janet as well as from Zig. This also
/// exercises `cfun_buffer_trim`, which calls `canRealloc`.
fn fromJanet() void {
    var out: repr.Value = undefined;
    const env = harness.coreEnv();
    const source =
        \\(let [b (buffer/new 100)
        \\      a (array/new 10)]
        \\  (buffer/push b "abc")
        \\  (buffer/trim b)
        \\  (array/push a 1)
        \\  (array/push a 2)
        \\  [(length b) (string b) (length a) (array/pop a) (array/peek a)])
    ;
    std.debug.assert(core_env.dostring(env, source, "buffer-array-test", &out) == 0);
    std.debug.assert(harness.isType(out, repr.Tag.tuple));
    const t = wrap.toTuple(out);
    std.debug.assert(harness.integerIs(t[0], 3));
    std.debug.assert(harness.stringValueIs(t[1], "abc"));
    std.debug.assert(harness.integerIs(t[2], 2));
    std.debug.assert(harness.integerIs(t[3], 2));
    std.debug.assert(harness.integerIs(t[4], 1));
}

/// The empty case of the three collection views, which is the case a raw
/// `data.?[0..count]` cannot express: `janet_buffer_init(b, 0)` and
/// `janet_array_init(a, 0)` both leave `data` null, and slicing null traps
/// even for a zero-length range.
///
/// Each of the three is checked at zero and then again
/// after one element, so a view that always answered empty would fail too.
fn theEmptyViews() !void {
    // A collection that has never been grown: `data` is null and `count` is
    // zero, which is what `std.mem.zeroes` and `janet_table_init(t, 0)` both
    // leave behind. This is the case `data.?[0..count]` traps on.
    var empty_buffer: types.JanetBuffer = .{};
    std.debug.assert(empty_buffer.data == null);
    std.debug.assert(empty_buffer.slice().len == 0);
    std.debug.assert(empty_buffer.reserved().len == 0);
    std.debug.assert(empty_buffer.spare().len == 0);

    var empty_array: types.JanetArray = .{};
    std.debug.assert(empty_array.data == null);
    std.debug.assert(empty_array.slice().len == 0);
    std.debug.assert(empty_array.reserved().len == 0);

    var empty_table: types.JanetTable = .{};
    std.debug.assert(empty_table.data == null);
    std.debug.assert(empty_table.slots().len == 0);

    // And the non-empty case beside it, so that a view which always answered
    // the empty slice would fail here rather than pass both halves.
    const b = buffers.new(0);
    try buffers.pushU8(b, 'q');
    std.debug.assert(b.*.slice().len == 1);
    std.debug.assert(b.*.slice()[0] == 'q');
    std.debug.assert(b.*.reserved().len == @as(usize, @intCast(b.*.capacity)));
    std.debug.assert(b.*.spare().len == @as(usize, @intCast(b.*.capacity - 1)));

    const a = arrays.new(0);
    std.debug.assert(a.*.slice().len == 0);
    try arrays.push(a, harness.wrapInteger(7));
    std.debug.assert(a.*.slice().len == 1);
    std.debug.assert(harness.integerIs(a.*.slice()[0], 7));

    // A table's view is its *slot* array, so it is `capacity` long rather
    // than `count` long -- which is the reason it is not called `slice`.
    var table: types.JanetTable = .{};
    _ = tables.initRaw(&table, 4);
    tables.put(&table, harness.wrapInteger(1), harness.wrapInteger(2));
    std.debug.assert(table.count == 1);
    std.debug.assert(table.slots().len == @as(usize, @intCast(table.capacity)));
    std.debug.assert(table.slots().len > table.count);
    tables.deinit(&table);
}

fn body() !void {
    try theEmptyViews();
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
    harness.init();
    body() catch @panic("buffer_array: a container operation raised unexpectedly");
    vm_lifecycle.deinit();
}
