//! Behavioral contract for the two growable containers: `buffers.Buffer` and
//! `arrays.Array`.
//!
//! These are the easiest containers in the runtime to observe, because almost
//! everything they do is visible in three `int32_t` fields and a pointer. So
//! this file asserts the fields directly rather than through the standard
//! library: `count`, `capacity`, and what `data` contains after each
//! operation. The capacity policy is the interesting part, both types
//! overshooting by a caller-supplied growth factor, and `array/ensure`
//! exposes the resulting capacity to Janet code, so it is fixed rather than
//! free to change.
//!
//! GC pressure is the second channel. Both halves charge
//! `vm.gc.next_collection` for the payloads they allocate, and they do it
//! inconsistently: the buffer charges before its reallocation and the array
//! after, and `arrays.newFrom` charges nothing at all. None of that is a
//! defect and all of it is observable, so it is pinned here.
//!
//! A refusal is a value in this file. `harness.raised` returns the `Raise` or
//! null and the assertion is one line at the site, so a refusal that stops
//! happening fails where it was expected.
//!
//! ## What this file cannot cover
//!
//! `arrays.ensure` is an internal entry point that takes its growth factor on
//! trust, and a factor of zero or less makes the arithmetic produce a capacity
//! that is zero or negative. The negative case ends the process, because every
//! negative capacity converts to a `usize` near the top of the range and the
//! allocation always fails, and a test cannot survive that. The zero case
//! depends on the C library: `realloc(p, 0)` gives back a minimal block on
//! macOS and NULL on glibc, and the second of those ends the process the same
//! way. So the zero case is asserted only after probing the allocator for
//! which it does, and the negative case is not asserted at all. `array/ensure`
//! rejects both before they get here, which `suite-corelib.janet` pins.
//!
//! The overflow refusals are asserted on both sides of their boundaries by
//! `theCeilings` and `theReservedCeilings`, on containers built by hand with a
//! count near `INT32_MAX` that no allocation backs. Each operation there
//! refuses before it reads an element or writes the one element past the
//! count, so a ceiling costs a reservation of address space and not the
//! elements.

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
const args = @import("subsystems").args;
const arrays = @import("subsystems").value.arrays;
const buffers = @import("subsystems").value.buffers;
const constants = @import("constants");
const core_env = @import("subsystems").env;
const expect = @import("expect.zig").expect;
const gc_alloc = @import("subsystems").gc_alloc;
const gc_mark = @import("subsystems").gc_mark;
const harness = @import("harness.zig");
const heap = harness.heap;

const raise = @import("subsystems").raise;
const registry = @import("subsystems").registry;
const repr = @import("repr");
const strings = @import("subsystems").value.strings;
const tables = @import("subsystems").value.tables;
const utils = @import("subsystems").utils;
const vm_lifecycle = @import("subsystems").lifecycle;
const wrap = @import("subsystems").value.wrap;

// ==========================================================================
// Constants
// ==========================================================================

/// The foreign memory a pointer buffer wraps. At file scope because the
/// buffer outlives the case that makes it.
var foreign = [8]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };

// ==========================================================================
// Cases
// ==========================================================================

/// The empty case of the three collection views, which is the case a raw
/// `data.?[0..count]` cannot express: `buffers.init(b, 0)` and `arrays.new(0)`
/// both leave `data` null, and slicing null traps even for a zero-length
/// range.
///
/// Each of the three is checked at zero and then again
/// after one element, so a view that reported empty for everything would fail
/// too.
fn theEmptyViews() !void {
    // A collection that has never been grown: `data` is null and `count` is
    // zero, which is what `std.mem.zeroes` and `tables.init(t, 0)` both leave
    // behind. This is the case `data.?[0..count]` traps on.
    var empty_buffer: buffers.Buffer = .{};
    expect(empty_buffer.data == null);
    expect(empty_buffer.slice().len == 0);
    expect(empty_buffer.reserved().len == 0);
    expect(empty_buffer.spare().len == 0);

    var empty_array: arrays.Array = .{};
    expect(empty_array.data == null);
    expect(empty_array.slice().len == 0);
    expect(empty_array.reserved().len == 0);

    var empty_table: tables.Table = .{};
    expect(empty_table.data == null);
    expect(empty_table.slots().len == 0);

    // And the non-empty case beside it, so that a view which always reported
    // the empty slice would fail here rather than pass both halves.
    const b = buffers.new(0);
    try buffers.pushU8(b, 'q');
    expect(b.slice().len == 1);
    expect(b.slice()[0] == 'q');
    expect(b.reserved().len == @as(usize, @intCast(b.capacity)));
    expect(b.spare().len == @as(usize, @intCast(b.capacity - 1)));

    const a = arrays.new(0);
    expect(a.slice().len == 0);
    try arrays.push(a, harness.wrapInteger(7));
    expect(a.slice().len == 1);
    expect(harness.integerIs(a.slice()[0], 7));

    // A table's view is its *slot* array, so it is `capacity` long rather
    // than `count` long, which is the reason it is not called `slice`.
    var table: tables.Table = .{};
    _ = tables.initRaw(&table, 4);
    tables.put(&table, harness.wrapInteger(1), harness.wrapInteger(2));
    expect(table.count == 1);
    expect(table.slots().len == @as(usize, @intCast(table.capacity)));
    expect(table.slots().len > table.count);
    tables.deinit(&table);
}

/// A collectable buffer starts empty, lands on the strong heap list, and is
/// given a floor of four bytes of capacity however little was asked for. The
/// floor is the buffer's alone; `arrays.new` has no equivalent.
fn bufferStartsWithACapacityFloor() void {
    const b = buffers.new(0);
    expect(b.count == 0);
    expect(b.capacity == 4);
    expect(b.data != null);
    expect(heap.memoryType(b) == gc_alloc.MemoryType.buffer);
    expect(heap.onList(harness.vm().gc.blocks, b));

    const big = buffers.new(100);
    expect(big.capacity == 100);
    expect(big.count == 0);

    // Exactly at the floor, and one below it. A request of zero is what C's
    // negative one became: `initImpl` floors both at four.
    expect(buffers.new(4).capacity == 4);
    expect(buffers.new(3).capacity == 4);
    expect(buffers.new(0).capacity == 4);
}

/// A buffer the caller owns is marked disabled and is not linked into a heap
/// list, so the collector never reaches it and never frees it.
fn callerOwnedBufferIsDisabled() !void {
    var b: buffers.Buffer = undefined;
    @memset(std.mem.asBytes(&b), 0xAA);
    const returned = buffers.init(&b, 32);
    expect(returned == &b);
    expect(b.count == 0);
    expect(b.capacity == 32);
    expect(b.data != null);
    expect(harness.gcBits(b.gc.flags) == constants.JANET_MEM_DISABLED);
    expect(b.gc.data.next == null);
    expect(!heap.onList(harness.vm().gc.blocks, &b));

    // It still behaves as a buffer, and deinit releases the payload.
    try buffers.pushCString(&b, "hello");
    expect(b.count == 5);
    expect(std.mem.eql(u8, b.slice()[0..5], "hello"));
    buffers.deinit(&b);
    expect(b.data == null);
}

/// A pointer buffer wraps memory the runtime did not allocate. The block is
/// collectable but the payload is not: the NO_REALLOC flag makes every growth
/// path refuse and makes deinit leave the foreign pointer alone.
fn pointerBufferNeverReallocates() !void {
    const b = try buffers.pointerUnsafe(&foreign, 8, 3);
    expect(b.data == @as([*]u8, &foreign));
    expect(b.capacity == 8);
    expect(b.count == 3);
    expect(harness.gcBits(b.gc.flags) & constants.JANET_BUFFER_FLAG_NO_REALLOC != 0);
    expect(heap.memoryType(b) == gc_alloc.MemoryType.buffer);
    expect(heap.onList(harness.vm().gc.blocks, b));

    // Growing within the existing capacity is fine, and `buffers.ensure`
    // returns before it consults the flag.
    try buffers.ensure(b, 8, 1);
    expect(b.data == @as([*]u8, &foreign));

    // Growing past it is refused, and so is the guard called directly.
    const refusal = "buffer cannot reallocate foreign memory";
    expect(harness.raised(
        buffers.ensure,
        .{ b, @as(i32, 9), @as(i32, 1) },
    ).?.says(refusal));
    expect(harness.raised(
        buffers.extra,
        .{ b, @as(i32, 100) },
    ).?.says(refusal));
    expect(harness.raised(buffers.canRealloc, .{b}).?.says(refusal));
    expect(b.data == @as([*]u8, &foreign));
    expect(b.capacity == 8);

    // Deinit leaves the foreign memory intact rather than freeing it.
    buffers.deinit(b);
    expect(b.data == @as([*]u8, &foreign));
    expect(foreign[0] == 1 and foreign[7] == 8);

    // Its arguments are validated before the block is allocated. The count is
    // a `usize`, so the negative C also refused is not a value a caller can
    // form; `ffi/pointer-buffer` and the unmarshaller both read theirs through
    // a getter that refuses one first.
    expect(harness.raised(
        buffers.pointerUnsafe,
        .{ @as(?*anyopaque, &foreign), @as(usize, 2), @as(usize, 3) },
    ).?.says("capacity < count"));

    // A capacity equal to the count is a full buffer and not a refusal.
    const full = try buffers.pointerUnsafe(&foreign, 8, 8);
    expect(full.count == 8);
    expect(full.capacity == 8);
}

/// The growth factor multiplies the requested capacity, and the request is
/// ignored outright when the buffer is already large enough.
fn bufferEnsureAppliesTheGrowthFactor() !void {
    const b = buffers.new(10);
    const before = b.data;

    // Already big enough: no reallocation, no change, no pressure.
    const charge = harness.vm().gc.next_collection;
    try buffers.ensure(b, 10, 2);
    try buffers.ensure(b, 4, 8);
    expect(b.capacity == 10);
    expect(b.data == before);
    expect(harness.vm().gc.next_collection == charge);

    // Past it: the new capacity is the request times the growth.
    try buffers.ensure(b, 11, 3);
    expect(b.capacity == 33);

    try buffers.ensure(b, 100, 1);
    expect(b.capacity == 100);

    // The count is never touched by a capacity change.
    try buffers.pushCString(b, "abc");
    try buffers.ensure(b, 500, 2);
    expect(b.capacity == 1000);
    expect(b.count == 3);
    expect(std.mem.eql(u8, b.slice()[0..3], "abc"));
}

/// Growing the count zero-fills the bytes it newly covers; shrinking keeps the
/// capacity and the bytes above the new count.
///
/// There is no negative-count case: `setcount` takes a `usize`, and the one
/// Janet path that could produce a negative is `os/cryptorand`, which rejects
/// it before it gets here. `test/suite-os.janet` pins that refusal.
fn bufferSetcountZeroFills() !void {
    const b = buffers.new(4);
    try buffers.pushCString(b, "xy");
    expect(b.count == 2);

    try buffers.setcount(b, 6);
    expect(b.count == 6);
    expect(b.capacity >= 6);
    expect(std.mem.eql(u8, b.slice()[0..6], "xy\x00\x00\x00\x00"));

    // Shrinking leaves the capacity alone.
    const capacity = b.capacity;
    try buffers.setcount(b, 1);
    expect(b.count == 1);
    expect(b.capacity == capacity);

    // And growing again re-zeroes, rather than exposing the old bytes. The
    // scribble is deliberately outside the live range, so it is written
    // through the allocation rather than through `slice()`.
    b.reserved()[3] = 0xFF;
    try buffers.setcount(b, 4);
    expect(b.count == 4);
    expect(b.slice()[3] == 0);
}

/// `buffers.extra` reserves room without moving the count, and doubles rather
/// than using the growth factor.
fn bufferExtraDoubles() !void {
    const b = buffers.new(4);
    try buffers.pushCString(b, "ab");

    // Room already there: nothing happens.
    const capacity = b.capacity;
    try buffers.extra(b, 2);
    expect(b.capacity == capacity);
    expect(b.count == 2);

    // Room not there: capacity becomes twice what was needed.
    try buffers.extra(b, 9);
    expect(b.capacity == 22);
    expect(b.count == 2);
    expect(std.mem.eql(u8, b.slice()[0..2], "ab"));

    // The overflow guard runs before any allocation.
    expect(harness.raised(
        buffers.extra,
        .{ b, @as(i32, std.math.maxInt(i32)) },
    ).?.says("buffer overflow"));
    expect(b.capacity == 22);
    expect(b.count == 2);
}

/// The push primitives, including the byte order of the multi-byte ones. They
/// shift rather than copy, so the layout is little-endian on every host.
fn bufferPushesLittleEndian() !void {
    const b = buffers.new(4);

    try buffers.pushU8(b, 0xAB);
    expect(b.count == 1 and b.slice()[0] == 0xAB);

    try buffers.setcount(b, 0);
    try buffers.pushU16(b, 0x1234);
    expect(b.count == 2);
    expect(b.slice()[0] == 0x34 and b.slice()[1] == 0x12);

    try buffers.setcount(b, 0);
    try buffers.pushU32(b, 0x12345678);
    expect(b.count == 4);
    expect(b.slice()[0] == 0x78 and b.slice()[1] == 0x56);
    expect(b.slice()[2] == 0x34 and b.slice()[3] == 0x12);

    try buffers.setcount(b, 0);
    const wide: u64 = 0x0123456789ABCDEF;
    try buffers.pushU64(b, wide);
    expect(b.count == 8);
    for (0..8) |i| {
        const byte: u8 = @truncate(wide >> @intCast(8 * i));
        expect(b.slice()[i] == byte);
    }

    // Bytes, C strings, and Janet strings. A zero-length push is a no-op that
    // does not even reserve, so capacity is what distinguishes them.
    try buffers.setcount(b, 0);
    const capacity = b.capacity;
    try buffers.pushBytes(b, "ignored"[0..0]);
    expect(b.count == 0 and b.capacity == capacity);

    try buffers.pushBytes(b, "one");
    try buffers.pushCString(b, "two");
    try buffers.pushString(b, strings.cstring("three"));
    expect(b.count == 11);
    expect(std.mem.eql(u8, b.slice()[0..11], "onetwothree"));

    // A Janet string may contain an interior zero, and the length comes from
    // its head rather than from the bytes.
    try buffers.setcount(b, 0);
    try buffers.pushString(b, strings.new("a\x00b"));
    expect(b.count == 3);
    expect(std.mem.eql(u8, b.slice()[0..3], "a\x00b"));
}

/// `:native` is the byte order the host stores an integer in, which is `:le`
/// on one host and `:be` on another, so the expected bytes are the host's own
/// representation of the word.
fn nativeOrderIsTheHosts() !void {
    const word: u16 = 0x0102;
    const b = buffers.new(4);
    var argv = [_]repr.Value{
        wrap.fromBuffer(b),
        wrap.fromKeyword(strings.cstring("native")),
        harness.wrapInteger(word),
    };
    _ = try harness.callCore("buffer/push-uint16", &argv);
    expect(b.count == 2);
    expect(std.mem.eql(u8, b.slice(), std.mem.asBytes(&word)));
}

/// Every payload the buffer allocates is charged to the collector.
fn bufferChargesGcPressure() !void {
    var charge = harness.vm().gc.next_collection;
    const b = buffers.new(64);
    // `gc.gcalloc` charges the block, and the payload is charged on top.
    expect(harness.vm().gc.next_collection == charge + @sizeOf(buffers.Buffer) + 64);

    charge = harness.vm().gc.next_collection;
    try buffers.ensure(b, 100, 2);
    expect(b.capacity == 200);
    expect(harness.vm().gc.next_collection == charge + (200 - 64));

    charge = harness.vm().gc.next_collection;
    try buffers.setcount(b, 300);
    expect(b.capacity == 300);
    expect(harness.vm().gc.next_collection == charge + (300 - 200));

    // The floor is charged, not the request.
    charge = harness.vm().gc.next_collection;
    _ = buffers.new(1);
    expect(harness.vm().gc.next_collection == charge + @sizeOf(buffers.Buffer) + 4);
}

/// An array has no capacity floor, and a capacity of zero means no payload at
/// all rather than an empty one.
fn arrayHasNoCapacityFloor() !void {
    const a = arrays.new(0);
    expect(a.count == 0);
    expect(a.capacity == 0);
    expect(a.data == null);
    expect(heap.memoryType(a) == gc_alloc.MemoryType.array);
    expect(heap.onList(harness.vm().gc.blocks, a));

    const b = arrays.new(3);
    expect(b.capacity == 3);
    expect(b.count == 0);
    expect(b.data != null);

    // And it grows from nothing without special-casing the null payload.
    try arrays.push(a, harness.wrapInteger(7));
    expect(a.count == 1);
    expect(a.capacity == 2);
    expect(harness.equals(a.slice()[0], harness.wrapInteger(7)));
}

/// A weak array differs only in its memory type, which puts it on the other
/// heap list and hands it to the weak half of the sweep.
fn weakArrayIsANormalArrayElsewhere() !void {
    const a = arrays.weak(4);
    expect(heap.memoryType(a) == gc_alloc.MemoryType.array_weak);
    expect(heap.onList(harness.vm().gc.weak_blocks, a));
    expect(!heap.onList(harness.vm().gc.blocks, a));
    expect(a.capacity == 4);
    expect(a.count == 0);

    try arrays.push(a, harness.wrapInteger(1));
    expect(a.count == 1);
    expect(a.capacity == 4);

    // The strong twin is on the other list, and nothing else differs.
    const s = arrays.new(4);
    expect(heap.onList(harness.vm().gc.blocks, s));
    expect(!heap.onList(harness.vm().gc.weak_blocks, s));
    expect(s.capacity == a.capacity);
}

/// `arrays.newFrom` copies its elements and sets count and capacity to the
/// same value, so the result is exactly full.
fn arrayNIsExactlyFull() void {
    var elements = [3]repr.Value{
        harness.wrapInteger(10),
        wrap.fromKeyword(strings.cstring("k")),
        wrap.fromNil(),
    };

    const a = arrays.newFrom(&elements);
    expect(a.count == 3);
    expect(a.capacity == 3);
    expect(harness.equals(a.slice()[0], elements[0]));
    expect(harness.equals(a.slice()[1], elements[1]));
    expect(harness.isType(a.slice()[2], repr.Tag.nil));

    // The source is copied, not aliased.
    elements[0] = harness.wrapInteger(99);
    expect(harness.equals(a.slice()[0], harness.wrapInteger(10)));

    // Zero elements is legal and allocates nothing to copy into.
    const empty = arrays.newFrom(elements[0..0]);
    expect(empty.count == 0);
    expect(empty.capacity == 0);
}

/// The array's growth factor behaves as the buffer's does. This is the policy
/// `array/ensure` exposes to Janet, so the exact capacities are a contract.
fn arrayEnsureAppliesTheGrowthFactor() !void {
    const a = arrays.new(10);
    const before = a.data;

    const charge = harness.vm().gc.next_collection;
    arrays.ensure(a, 10, 2);
    arrays.ensure(a, 4, 8);
    expect(a.capacity == 10);
    expect(a.data == before);
    expect(harness.vm().gc.next_collection == charge);

    arrays.ensure(a, 11, 3);
    expect(a.capacity == 33);

    arrays.ensure(a, 100, 1);
    expect(a.capacity == 100);

    // Contents and count survive a reallocation.
    try arrays.push(a, harness.wrapInteger(5));
    arrays.ensure(a, 500, 2);
    expect(a.capacity == 1000);
    expect(a.count == 1);
    expect(harness.equals(a.slice()[0], harness.wrapInteger(5)));
}

/// Growing the count fills with nil, not with zero bytes; a negative count is
/// a no-op. Pushing doubles, and popping and peeking on an empty array give
/// nil rather than failing.
fn arraySetcountPushPopPeek() !void {
    const a = arrays.new(0);

    expect(harness.isType(arrays.pop(a), repr.Tag.nil));
    expect(harness.isType(arrays.peek(a), repr.Tag.nil));
    expect(a.count == 0);

    arrays.setcount(a, 3);
    expect(a.count == 3);
    for (0..3) |i| expect(harness.isType(a.slice()[i], repr.Tag.nil));

    a.slice()[2] = harness.wrapInteger(2);
    arrays.setcount(a, 1);
    expect(a.count == 1);
    arrays.setcount(a, 3);
    // Re-extending fills with nil again rather than exposing the old value.
    expect(harness.isType(a.slice()[2], repr.Tag.nil));

    // The negative-count case is gone with the `i32` parameter. `setcount`
    // takes a `usize`, nothing registers an `array/setcount` binding, and
    // `capi.zig` does not publish it, so there is no caller left that could
    // reach it with a negative, and the range check is the type.

    arrays.setcount(a, 0);
    try arrays.push(a, harness.wrapInteger(1));
    try arrays.push(a, harness.wrapInteger(2));
    expect(a.count == 2);
    expect(harness.equals(arrays.peek(a), harness.wrapInteger(2)));
    expect(a.count == 2);
    expect(harness.equals(arrays.pop(a), harness.wrapInteger(2)));
    expect(a.count == 1);
    expect(harness.equals(arrays.pop(a), harness.wrapInteger(1)));
    expect(a.count == 0);
    expect(harness.isType(arrays.pop(a), repr.Tag.nil));
}

/// The array's GC accounting, including the two asymmetries with the buffer:
/// `arrays.newFrom` charges nothing, and `arrays.ensure` charges after its
/// allocation rather than before.
fn arrayChargesGcPressure() void {
    var charge = harness.vm().gc.next_collection;
    const a = arrays.new(64);
    expect(harness.vm().gc.next_collection ==
        charge + @sizeOf(arrays.Array) + 64 * @sizeOf(repr.Value));

    charge = harness.vm().gc.next_collection;
    arrays.ensure(a, 100, 2);
    expect(a.capacity == 200);
    expect(harness.vm().gc.next_collection == charge + (200 - 64) * @sizeOf(repr.Value));

    // A capacity of zero allocates no payload, so only the block is charged.
    charge = harness.vm().gc.next_collection;
    _ = arrays.new(0);
    expect(harness.vm().gc.next_collection == charge + @sizeOf(arrays.Array));

    // `arrays.newFrom` allocates a payload and charges nothing for it.
    var elements = [_]repr.Value{wrap.fromNil()} ** 4;
    charge = harness.vm().gc.next_collection;
    const n = arrays.newFrom(&elements);
    expect(n.capacity == 4);
    expect(n.data != null);
    expect(harness.vm().gc.next_collection == charge + @sizeOf(arrays.Array));
}

/// Whether this C library's `realloc(p, 0)` gives back a block or NULL. Which
/// decides whether the zero-growth case in `arrays.ensure` returns or exits,
/// and it is a property of the allocator rather than of Janet.
fn reallocZeroReturnsABlock() bool {
    const p = utils.malloc(16);
    expect(p != null);
    const q = utils.realloc(p, 0);
    if (q == null) return false;
    utils.free(q);
    return true;
}

/// A growth factor of zero releases the payload while leaving `count` alone.
///
/// The internal function still does this and the boundary does not let a
/// Janet program reach it. `array/ensure` rejects a growth below one, as it
/// already rejected a count below one, because `Array.count` is `usize` and a
/// negative capacity has nowhere to go. `arrays.ensure` itself takes the
/// factor on trust, every in-tree caller passing 1 or 2, so this asserts
/// what the internal entry point does, and `suite-corelib.janet` asserts the
/// refusal on the other side of the wall.
/// See the note at the head of this file about why the allocator is probed
/// first.
fn zeroGrowthReleasesThePayload() !void {
    if (!reallocZeroReturnsABlock()) return;

    const a = arrays.new(0);
    for (0..5) |i| try arrays.push(a, harness.wrapInteger(@intCast(i)));
    expect(a.count == 5);
    expect(a.capacity == 6);

    const charge = harness.vm().gc.next_collection;
    arrays.ensure(a, 100, 0);

    // The capacity is gone and the count is not, so every element the array
    // claims to have is now a read of freed memory. Nothing below reads one.
    expect(a.capacity == 0);
    expect(a.count == 5);

    // And the accounting term went negative into a `usize`. C spelled this
    // `(size_t)(int32_t)(0 - 6) * sizeof(Janet)`, which is a sign extension
    // followed by a wrapping multiply; `@bitCast` and `*%` are the same two
    // steps named rather than implied.
    const negative: usize = @bitCast(@as(isize, -6));
    expect(harness.vm().gc.next_collection == charge +% negative *% @sizeOf(repr.Value));

    // Make the array safe for the collector again before returning: the mark
    // phase walks `count` elements, and they are not there any more.
    a.count = 0;
}

/// The ceilings that need no memory: `buffers.extra` takes a total of exactly
/// `maxInt(i32)` and refuses one more.
///
/// The buffer is built by hand and already claims that capacity, so neither
/// call allocates. It is on the stack and on no heap list, and nothing here
/// runs the collector.
fn theCeilings() !void {
    const ceiling: usize = std.math.maxInt(i32);
    var full: buffers.Buffer = .{ .count = 1, .capacity = ceiling, .data = &foreign };
    try buffers.extra(&full, ceiling - 1);
    expect(full.capacity == ceiling);
    expect(full.count == 1);
    expect(harness.raised(buffers.extra, .{ &full, ceiling }).?.says("buffer overflow"));

    if (comptime builtin.os.tag != .windows and @sizeOf(usize) >= 8) {
        try theReservedCeilings();
    }
}

/// The ceilings whose accepting side writes one element at the end of the
/// range, into address space reserved for it and otherwise untouched.
///
/// `buffers.extra` doubles a size of exactly half of `maxInt(i32)` to
/// `maxInt(i32) - 1`, which reallocates two gigabytes that nothing fills.
/// `buffer/blit` writes up to exactly `maxInt(i32)`. `array/push` refuses a
/// push that would reach a count of `maxInt(i32)`, `array/insert` takes one
/// that reaches it and refuses one more, and `arrays.push` refuses at the
/// count itself. A host that refuses a reservation skips the part that uses
/// it.
///
/// The doubling reallocates through the runtime's allocator, whose
/// out-of-memory path ends the process rather than raising, so it is probed
/// with a reservation of the same size first. A host with two gigabytes of
/// memory, such as a container VM, refuses the probe and skips it.
fn theReservedCeilings() !void {
    const ceiling: usize = std.math.maxInt(i32);
    const top: i32 = std.math.maxInt(i32);

    if (reserve(ceiling)) |probe| {
        release(probe, ceiling);
        var half: buffers.Buffer = undefined;
        _ = buffers.init(&half, 4);
        try buffers.extra(&half, ceiling / 2);
        expect(half.capacity == ceiling - 1);
        buffers.deinit(&half);
    }

    if (reserve(ceiling)) |memory| {
        defer release(memory, ceiling);
        var dest: buffers.Buffer = .{ .count = ceiling - 1, .capacity = ceiling, .data = memory };
        var argv = [_]repr.Value{
            wrap.fromBuffer(&dest),
            wrap.fromString(strings.cstring("xy")),
            harness.wrapInteger(top - 1),
        };
        expect(harness.coreRaised("buffer/blit", &argv).?.says("buffer blit out of range"));
        expect(dest.count == ceiling - 1);
        argv[1] = wrap.fromString(strings.cstring("x"));
        _ = try harness.callCore("buffer/blit", &argv);
        expect(dest.count == ceiling);
        expect(memory[ceiling - 1] == 'x');
    }

    const slots = ceiling * @sizeOf(repr.Value);
    if (reserve(slots)) |memory| {
        defer release(memory, slots);
        var a: arrays.Array = .{
            .count = ceiling - 2,
            .capacity = ceiling,
            .data = @ptrCast(@alignCast(memory)),
        };
        var push = [_]repr.Value{ wrap.fromArray(&a), harness.wrapInteger(7) };
        _ = try harness.callCore("array/push", &push);
        expect(a.count == ceiling - 1);
        expect(harness.integerIs(a.data.?[ceiling - 2], 7));
        expect(harness.coreRaised("array/push", &push).?.says("array overflow"));
        expect(a.count == ceiling - 1);

        var insert = [_]repr.Value{
            wrap.fromArray(&a),
            harness.wrapInteger(top - 1),
            harness.wrapInteger(8),
        };
        _ = try harness.callCore("array/insert", &insert);
        expect(a.count == ceiling);
        expect(harness.integerIs(a.data.?[ceiling - 1], 8));
        insert[1] = harness.wrapInteger(top);
        expect(harness.coreRaised("array/insert", &insert).?.says("array overflow"));
        expect(harness.raised(arrays.push, .{ &a, harness.wrapInteger(9) }).?.says("array overflow"));
        expect(a.count == ceiling);
    }
}

/// Address space for a container that claims a count near its ceiling, or
/// null where the host refuses to reserve it. `release` returns it.
fn reserve(bytes: usize) ?[*]u8 {
    const ptr = std.c.mmap(
        null,
        bytes,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    if (ptr == std.c.MAP_FAILED) return null;
    return @ptrCast(ptr);
}

fn release(memory: [*]u8, bytes: usize) void {
    _ = std.c.munmap(@ptrCast(@alignCast(memory)), bytes);
}

/// The collector frees a container's payload through `gc/sweep.zig`'s
/// `deinitBlock`, which calls `buffers.deinit` from this subsystem. Both
/// containers are freed the same way, so one collection covers the round trip
/// in both directions.
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
    expect(harness.vm().gc.block_count == before + 30);

    gc_mark.collect();
    expect(harness.vm().gc.block_count == before);

    // A rooted one survives the same collection and is still usable, which
    // is the assertion that its payload was not freed underneath it.
    const keep = buffers.new(16);
    try buffers.pushCString(keep, "kept");
    gc_alloc.gcroot(wrap.fromBuffer(keep));
    gc_mark.collect();
    expect(keep.count == 4);
    expect(std.mem.eql(u8, keep.slice()[0..4], "kept"));
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
    expect(core_env.dostring(env, source, "buffer-array-test", &out) == 0);
    expect(harness.isType(out, repr.Tag.tuple));
    const t = wrap.toTuple(out);
    expect(harness.integerIs(t[0], 3));
    expect(harness.stringValueIs(t[1], "abc"));
    expect(harness.integerIs(t[2], 2));
    expect(harness.integerIs(t[3], 2));
    expect(harness.integerIs(t[4], 1));
}

/// Numbers handed out in runs of three from one buffer the callback overwrites
/// on every call.
///
/// The buffer is what this fixture is for. A reader holding two runs of one
/// value at once reads the poison rather than the elements it asked for, so
/// `(array/concat @[] v v)` fails here and would pass against a type that
/// hands out its own storage. The elements are numbers, so nothing in the
/// buffer has to be marked.
const Runs = struct {
    count: usize,
    buffer: [3]repr.Value,

    /// What a slot holds where the run is shorter than the buffer, and what a
    /// stale run reads back as. No element takes this value.
    const poison = -1;
};

const runs_at = abstract_type.define(Runs, .{
    .name = "buffer-array/runs",
    .length = runsLength,
    .chunk = runsChunk,
    .contents = .elements,
});

/// Element `i` is `i * 10`, and the runs are `[0..3)`, `[3..6)` and so on, the
/// last of them short where `count` is not a multiple of three.
fn runsChunk(self: *Runs, index: usize) abstract_type.Chunk {
    const start = index - index % 3;
    const end = @min(start + 3, self.count);
    for (&self.buffer) |*slot| slot.* = wrap.fromInteger(Runs.poison);
    for (self.buffer[0 .. end - start], start..) |*slot, i| {
        slot.* = wrap.fromInteger(@intCast(i * 10));
    }
    return .{ .items = self.buffer[0 .. end - start], .start = start };
}

fn runsLength(self: *Runs, _: usize) raise.Error!usize {
    return self.count;
}

fn cfunRuns(argv: []repr.Value) raise.Error!repr.Value {
    try args.fixarity(argv, 1);
    const count = try args.getInteger(argv, 0);
    const raw = abstracts.newBytes(&runs_at, @sizeOf(Runs));
    const runs: *Runs = @ptrCast(@alignCast(raw));
    runs.* = .{ .count = @intCast(count), .buffer = undefined };
    return wrap.fromAbstract(raw);
}

const cfuns = [_]abi.Reg{
    .{ .name = "bufarr/runs", .cfun = raise.stored(&cfunRuns), .documentation = null },
};

/// `array/concat` and `array/join` read an abstract type with a `chunk`
/// callback one run at a time, and an array or a tuple holding the same
/// elements is the oracle for every case.
///
/// `array/concat` appends an indexed part element by element and anything else
/// as a single element, and it read that distinction off the type tag, so an
/// indexed abstract used to go in whole. It goes in element by element now,
/// which is what the rule says and what `array/join` already did.
///
/// The aliasing case is here too. Concatenating an array onto itself makes it
/// both the source and the destination, and the reservation may move the run
/// the copy reads.
fn concatReadsAnIndexedAbstract() void {
    var out: repr.Value = undefined;
    const env = harness.coreEnv();
    registry.cfuns(env, null, &cfuns);
    const source =
        \\(def failures @[])
        \\(defn- check [label ok] (unless ok (array/push failures label)))
        \\(def v (bufarr/runs 10))
        \\(def oracle [0 10 20 30 40 50 60 70 80 90])
        \\(check "concat element by element"
        \\       (deep= (array/concat @[] v) (array/concat @[] oracle)))
        \\(check "concat twice from one value"
        \\       (deep= (array/concat @[] v v) (array/concat @[] oracle oracle)))
        \\(check "join twice from one value"
        \\       (deep= (array/join @[] v v) (array/join @[] oracle oracle)))
        \\(check "a part that is not indexed is one element"
        \\       (deep= (array/concat @[1] v 2 v) (array/concat @[1] oracle 2 oracle)))
        \\(check "an empty abstract appends nothing"
        \\       (deep= (array/concat @[:a] (bufarr/runs 0)) @[:a]))
        \\(check "a growth mid-copy keeps every element"
        \\       (= 1000 (length (array/concat @[] (bufarr/runs 1000)))))
        \\(check "an array concatenated onto itself"
        \\       (let [a @[1 2 3]] (array/concat a a) (deep= a @[1 2 3 1 2 3])))
        \\(check "join still refuses what is not indexed"
        \\       (= "expected indexed type for argument 1, got 5"
        \\          (let [[ok r] (protect (array/join @[] 5))] r)))
        \\failures
    ;
    expect(core_env.dostring(env, source, "buffer-array-test", &out) == 0);
    expect(harness.isType(out, repr.Tag.array));
    const failed = wrap.toArray(out);
    if (failed.count != 0) {
        for (failed.slice()) |label| {
            std.debug.print("concat check failed: {s}\n", .{wrap.toString(label)});
        }
        expect(false);
    }
}

// ==========================================================================
// Entry
// ==========================================================================

fn body() !void {
    try theEmptyViews();
    bufferStartsWithACapacityFloor();
    try callerOwnedBufferIsDisabled();
    try pointerBufferNeverReallocates();
    try bufferEnsureAppliesTheGrowthFactor();
    try bufferSetcountZeroFills();
    try bufferExtraDoubles();
    try bufferPushesLittleEndian();
    try nativeOrderIsTheHosts();
    try bufferChargesGcPressure();

    try arrayHasNoCapacityFloor();
    try weakArrayIsANormalArrayElsewhere();
    arrayNIsExactlyFull();
    try arrayEnsureAppliesTheGrowthFactor();
    try arraySetcountPushPopPeek();
    arrayChargesGcPressure();
    try zeroGrowthReleasesThePayload();
    try theCeilings();

    try theCollectorReclaimsBoth();
    fromJanet();
    concatReadsAnIndexedAbstract();
}

pub fn run() void {
    harness.init();
    body() catch @panic("buffer_array: a container operation raised unexpectedly");
    vm_lifecycle.deinit();
}
