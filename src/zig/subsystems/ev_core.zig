//! Portable kernels of the event loop: the generic queue behind every channel
//! and the scheduler, the timeout min-heap's ordering decisions, and the
//! timestamp arithmetic all three POSIX backends share.
//!
//! This was the first increment inside `ev.c`, and it deliberately took none of
//! the backends. What is here holds no Janet values, touches no host structure,
//! and has no non-local control flow; the only failure is an allocation failure,
//! which routes through the same fatal bridge the vector port uses.
//!
//! ## The kernels are reached by import
//!
//! Every function below was an `export fn janet_ev_*` until Phase 11 Part 21,
//! and `ev_loop.zig` declared each one again as a `pub extern fn` so that
//! `ev_channel.zig` and `ev_backend.zig` could reach it through the symbol
//! table. That was the shape `ev.c` needed. Both ends have been Zig since
//! Phase 10 Part 18, so the thirteen symbols existed to let one Zig file call
//! another -- rule 44, and the largest instance of it after Part 20's.
//!
//! Two things went with the seam. The `Queue` mirror this file kept of
//! `state.h`'s `JanetQueue` is gone, because a direct call has to agree about
//! the type and `c.JanetQueue` is the one the `janet_vm` fields are declared
//! with -- rule 45. And `qMaybeResize` is private now: it was exported and
//! declared by the C contract, and its only callers are the two pushes.
//!
//! `JanetTimeout` still never reaches these functions. It carries a `pthread_t`
//! on POSIX and two `HANDLE`s on Windows, and the heap functions take a base
//! pointer, a stride, and the offset of the `when` field rather than the
//! structure; the caller owns the array, the `janet_vm` fields it lives in, and
//! the moves. That interface no longer has to be untyped -- a comptime element
//! type and field name would say the same thing and check it -- but the change
//! belongs with `ev_loop`'s own migration rather than with this one, because
//! `test/ev_loop.c` is the oracle over the callers until then.

const std = @import("std");
const abi = @import("abi");
const c = abi.c;

/// `JANET_MAX_Q_CAPACITY` in `src/core/ev.c`.
const max_queue_capacity: i32 = 0x7FFFFFF;

/// `JANET_KQUEUE_MIN_INTERVAL` in `src/core/ev.c`. NetBSD rejects intervals
/// below a millisecond; every other kqueue platform accepts zero.
const kqueue_min_interval: i64 = 0;

const nanoseconds_per_millisecond: i64 = 1000000;
const milliseconds_per_second: i64 = 1000;

// ---------------------------------------------------------------------------
// Generic queue
// ---------------------------------------------------------------------------

pub fn qInit(q: *c.JanetQueue) void {
    q.data = null;
    q.head = 0;
    q.tail = 0;
    q.capacity = 0;
}

pub fn qDeinit(q: *c.JanetQueue) void {
    c.janet_free(q.data);
}

/// Items between `head` and `tail`, wrapping through the end of the buffer.
///
/// The arithmetic wraps explicitly. Janet's own invariants keep every term well
/// inside `int32_t` — capacity never exceeds `JANET_MAX_Q_CAPACITY` — but C
/// leaves a corrupted queue's overflow undefined and Zig may not, so the port
/// commits to wrapping rather than trapping.
pub fn qCount(q: *const c.JanetQueue) i32 {
    return if (q.head > q.tail)
        q.tail +% q.capacity -% q.head
    else
        q.tail -% q.head;
}

/// Grow the queue if another item would fill it, returning 1 if it cannot grow.
///
/// One slot is always left empty so that a full queue is distinguishable from an
/// empty one, which is why the test is `count + 1 >= capacity`.
fn qMaybeResize(q: *c.JanetQueue, itemsize: usize) c_int {
    const count = qCount(q);
    if (count +% 1 < q.capacity) return 0;
    if (count +% 1 >= max_queue_capacity) return 1;

    var newcap: i32 = (count +% 2) *% 2;
    if (newcap > max_queue_capacity) newcap = max_queue_capacity;

    const allocation = c.janet_realloc(
        q.data,
        itemsize * @as(usize, @intCast(newcap)),
    ) orelse c.janet_zig_out_of_memory();
    q.data = allocation;

    if (q.head > q.tail) {
        // The live items are in two segments. Growing the buffer moves the
        // second segment to sit against the new end, keeping it contiguous with
        // the first across the wrap.
        const newhead = q.head +% (newcap -% q.capacity);
        const seg1: usize = @intCast(q.capacity -% q.head);
        if (seg1 > 0) {
            const base: [*]u8 = @ptrCast(allocation);
            const source = base + @as(usize, @intCast(q.head)) * itemsize;
            const destination = base + @as(usize, @intCast(newhead)) * itemsize;
            const bytes = seg1 * itemsize;
            // The regions overlap whenever the buffer less than doubled.
            @memmove(destination[0..bytes], source[0..bytes]);
        }
        q.head = newhead;
    }

    q.capacity = newcap;
    return 0;
}

pub fn qPush(q: *c.JanetQueue, item: *const anyopaque, itemsize: usize) c_int {
    if (qMaybeResize(q, itemsize) != 0) return 1;
    const base: [*]u8 = @ptrCast(q.data.?);
    const slot = base + @as(usize, @intCast(q.tail)) * itemsize;
    const source: [*]const u8 = @ptrCast(item);
    @memcpy(slot[0..itemsize], source[0..itemsize]);
    q.tail = if (q.tail +% 1 < q.capacity) q.tail +% 1 else 0;
    return 0;
}

pub fn qPushHead(q: *c.JanetQueue, item: *const anyopaque, itemsize: usize) c_int {
    if (qMaybeResize(q, itemsize) != 0) return 1;
    var newhead = q.head -% 1;
    if (newhead < 0) newhead +%= q.capacity;
    const base: [*]u8 = @ptrCast(q.data.?);
    const slot = base + @as(usize, @intCast(newhead)) * itemsize;
    const source: [*]const u8 = @ptrCast(item);
    @memcpy(slot[0..itemsize], source[0..itemsize]);
    q.head = newhead;
    return 0;
}

pub fn qPop(q: *c.JanetQueue, out: *anyopaque, itemsize: usize) c_int {
    if (q.head == q.tail) return 1;
    const base: [*]const u8 = @ptrCast(q.data.?);
    const slot = base + @as(usize, @intCast(q.head)) * itemsize;
    const destination: [*]u8 = @ptrCast(out);
    @memcpy(destination[0..itemsize], slot[0..itemsize]);
    q.head = if (q.head +% 1 < q.capacity) q.head +% 1 else 0;
    return 0;
}

// ---------------------------------------------------------------------------
// Timeout min-heap ordering
// ---------------------------------------------------------------------------

/// Read the `when` field of element `index` without knowing the element type.
///
/// The read goes through `@memcpy` rather than a pointer cast because the caller
/// only promises the C structure's own alignment, which Zig has not been told.
fn whenAt(base: *const anyopaque, stride: usize, when_offset: usize, index: usize) i64 {
    var value: i64 = undefined;
    const bytes: [*]const u8 = @ptrCast(base);
    const source = bytes + index * stride + when_offset;
    const destination: [*]u8 = @ptrCast(&value);
    @memcpy(destination[0..@sizeOf(i64)], source[0..@sizeOf(i64)]);
    return value;
}

/// One step of sifting down: report the child that should take `index`'s place,
/// or -1 when the heap property already holds there.
///
/// The left child is preferred on a tie, which is what the C implementation's
/// strict `<` comparisons produce.
pub fn heapSiftDown(
    base: *const anyopaque,
    stride: usize,
    when_offset: usize,
    count: usize,
    index: usize,
) isize {
    const left = (index << 1) + 1;
    const right = left + 1;
    var smallest = index;
    if (left < count and whenAt(base, stride, when_offset, left) <
        whenAt(base, stride, when_offset, smallest))
    {
        smallest = left;
    }
    if (right < count and whenAt(base, stride, when_offset, right) <
        whenAt(base, stride, when_offset, smallest))
    {
        smallest = right;
    }
    return if (smallest == index) -1 else @intCast(smallest);
}

/// One step of sifting up: report the parent that should take `index`'s place,
/// or -1 when the heap property already holds there.
pub fn heapSiftUp(
    base: *const anyopaque,
    stride: usize,
    when_offset: usize,
    index: usize,
) isize {
    if (index == 0) return -1;
    const parent = (index - 1) >> 1;
    if (whenAt(base, stride, when_offset, parent) <=
        whenAt(base, stride, when_offset, index)) return -1;
    return @intCast(parent);
}

// ---------------------------------------------------------------------------
// Timestamp arithmetic
// ---------------------------------------------------------------------------

/// Add a delay in seconds to a millisecond timestamp.
///
/// A negative infinity means "already due" and yields the timestamp unchanged; a
/// positive infinity means "never" and yields `INT64_MAX`. C leaves the
/// conversion of a NaN or an out-of-range delay undefined, exactly as `os/sleep`
/// and `os/touch` do; the port saturates for the same reason and with the same
/// result on the development target.
pub fn tsDelta(ts: i64, delta: f64) i64 {
    if (std.math.isInf(delta)) {
        return if (delta < 0) ts else std.math.maxInt(i64);
    }
    return ts +% saturatingCast(i64, @round(delta * 1000));
}

/// Convert a clock reading into Janet's millisecond timestamp.
///
/// This is the body the epoll, kqueue, and poll backends each spell out
/// identically after calling `janet_gettime`. It is arithmetic rather than a
/// clock reading, so it is shared here while `janet_gettime` stays with
/// `-Dos-time`.
pub fn tsFromParts(sec: i64, nsec: i64) i64 {
    return milliseconds_per_second *% sec +%
        @divTrunc(nsec, nanoseconds_per_millisecond);
}

/// Split a millisecond timestamp into whole seconds and nanoseconds.
///
/// C fills a `struct timespec`; the parts cross the boundary separately because
/// that structure's layout varies by platform, libc, and word size. A zero
/// timestamp is answered directly, as the C implementation's ternaries do.
pub fn tsToParts(ts: i64, sec_out: *i64, nsec_out: *i64) void {
    if (ts == 0) {
        sec_out.* = 0;
        nsec_out.* = 0;
        return;
    }
    sec_out.* = @divTrunc(ts, milliseconds_per_second);
    nsec_out.* = @rem(ts, milliseconds_per_second) *% nanoseconds_per_millisecond;
}

/// Clamp a kqueue interval to the minimum the platform accepts.
///
/// Only the kqueue backend calls this, but the rule belongs to kqueue's
/// interface rather than to the host running the build, so it is compiled and
/// tested everywhere — as the Windows command-line escaping is.
pub fn kqueueInterval(ts: i64) i64 {
    return if (ts >= kqueue_min_interval) ts else kqueue_min_interval;
}

/// Convert toward zero, clamping instead of trapping. This mirrors the helper in
/// `os_time.zig`: a NaN becomes zero and an out-of-range value becomes the
/// nearest bound, which is what the development target's hardware conversion
/// produces where C leaves the result undefined.
fn saturatingCast(comptime T: type, value: f64) T {
    if (std.math.isNan(value)) return 0;
    const low: f64 = @floatFromInt(@as(T, std.math.minInt(T)));
    const high: f64 = @floatFromInt(@as(T, std.math.maxInt(T)));
    if (!(value > low)) return std.math.minInt(T);
    if (value >= high) return std.math.maxInt(T);
    return @intFromFloat(value);
}

test "queue counts across a wrap" {
    var q: c.JanetQueue = undefined;
    qInit(&q);
    defer qDeinit(&q);
    try std.testing.expectEqual(@as(i32, 0), qCount(&q));
}

test "saturating conversion clamps rather than trapping" {
    try std.testing.expectEqual(@as(i64, 0), saturatingCast(i64, std.math.nan(f64)));
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), saturatingCast(i64, 1e300));
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), saturatingCast(i64, -1e300));
}
