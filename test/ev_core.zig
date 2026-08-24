//! Behavioral contract for the event loop's portable kernels: the generic
//! queue behind every channel and the scheduler, the timeout min-heap's
//! ordering decisions, and the timestamp arithmetic the POSIX backends share.
//!
//! ## Why this file exists rather than the suite covering it
//!
//! The Janet-level behaviour these kernels produce — channel ordering across a
//! resize, deadlines firing in time order — is covered by `test/suite-ev.janet`
//! rather than here, and deliberately so.
//!
//! `ev/give`, `ev/take` and `ev/sleep` all end in `janet_await`, which suspends
//! the calling fiber whether or not the operation could be satisfied
//! immediately. `janet_dostring` runs a source string one top-level form at a
//! time and only drains the event loop once the whole string has been read, so
//! a form that follows a suspending one runs while the earlier form is still
//! parked. An assertion written that way observes an intermediate state: a
//! channel drained by a suspended loop still reports its items, and a print
//! placed after the loop emits before the loop's own output. That is the
//! embedding API behaving as designed, not a defect, but it makes any assertion
//! of this shape meaningless. `harness.inFiber` is the answer where the subject
//! is a cfunction; here the subject is arithmetic, and pinning it with fixed
//! vectors is both cheaper and stricter.
//!
//! ## What the migration changed
//!
//! **The kernels are reached by import.** `test/ev_core.c` hand-declared
//! thirteen `janet_ev_*` symbols and a fourth copy of `JanetQueue`, because
//! none of them is in a header. They were exported for an `ev.c` that Phase 10
//! Part 18 deleted, and the only callers left were `ev_loop.zig`,
//! `ev_channel.zig` and `ev_backend.zig` — three Zig files reaching a fourth
//! through the symbol table. Phase 11 Part 21 converted the callers, and the
//! thirteen symbols went with the seam.
//!
//! **The heap is still driven through a foreign element type.** That is the
//! one thing the C contract did that a naive translation would have thrown
//! away. `heapSiftDown` and `heapSiftUp` take a base pointer, a stride and the
//! offset of the `when` field *precisely* so that they never need
//! `JanetTimeout`, which carries a `pthread_t` on POSIX and two `HANDLE`s on
//! Windows. Exercising them against a local `Entry` is what proves the claim;
//! passing `c.JanetTimeout` here would assert nothing about it.
//!
//! **One assertion could not survive, and the type is why.**
//! `janet_ev_q_pop(&q, NULL, sizeof(int32_t))` is what the C contract wrote to
//! check that an empty queue reports before it writes. `qPop` takes
//! `*anyopaque`, so there is no null to pass. What is kept is the half that
//! still has a subject: a pop from an empty queue leaves the caller's variable
//! as it was. Rule 30 — say which half survived, because the next reader will
//! look for the other.

const std = @import("std");
const abi = @import("abi");
const c = abi.c;

const subsystems = @import("subsystems");
const ev_core = subsystems.ev_core;

const assert = std.debug.assert;

// ==========================================================================
// The generic queue
// ==========================================================================

fn theEmptyQueue() void {
    var q: c.JanetQueue = undefined;
    ev_core.qInit(&q);
    defer ev_core.qDeinit(&q);

    assert(q.data == null);
    assert(q.capacity == 0);
    assert(ev_core.qCount(&q) == 0);

    // Popping an empty queue reports failure and leaves the output alone.
    var out: i32 = 12345;
    assert(ev_core.qPop(&q, &out, @sizeOf(i32)) == 1);
    assert(out == 12345);
}

fn theQueueIsFirstInFirstOut() void {
    var q: c.JanetQueue = undefined;
    ev_core.qInit(&q);
    defer ev_core.qDeinit(&q);

    var i: i32 = 0;
    while (i < 100) : (i += 1) {
        assert(ev_core.qPush(&q, &i, @sizeOf(i32)) == 0);
        assert(ev_core.qCount(&q) == i + 1);
    }
    i = 0;
    while (i < 100) : (i += 1) {
        var out: i32 = -1;
        assert(ev_core.qPop(&q, &out, @sizeOf(i32)) == 0);
        assert(out == i);
    }
    assert(ev_core.qCount(&q) == 0);
}

fn theHeadPushReversesTheOrder() void {
    var q: c.JanetQueue = undefined;
    ev_core.qInit(&q);
    defer ev_core.qDeinit(&q);

    var i: i32 = 0;
    while (i < 50) : (i += 1) {
        assert(ev_core.qPushHead(&q, &i, @sizeOf(i32)) == 0);
    }
    assert(ev_core.qCount(&q) == 50);
    i = 49;
    while (i >= 0) : (i -= 1) {
        var out: i32 = -1;
        assert(ev_core.qPop(&q, &out, @sizeOf(i32)) == 0);
        assert(out == i);
    }
}

/// Interleaving pushes and pops walks head and tail around the buffer, so the
/// resize path runs with head > tail and has to move the wrapped segment.
fn theQueueWrapsAndResizes() void {
    var q: c.JanetQueue = undefined;
    ev_core.qInit(&q);
    defer ev_core.qDeinit(&q);

    var next_in: i32 = 0;
    var next_out: i32 = 0;

    var round: u32 = 0;
    while (round < 200) : (round += 1) {
        for (0..3) |_| {
            assert(ev_core.qPush(&q, &next_in, @sizeOf(i32)) == 0);
            next_in += 1;
        }
        for (0..2) |_| {
            var out: i32 = -1;
            assert(ev_core.qPop(&q, &out, @sizeOf(i32)) == 0);
            assert(out == next_out);
            next_out += 1;
        }
        assert(ev_core.qCount(&q) == next_in - next_out);
    }

    // Everything still queued comes out in order, unshuffled by any resize.
    while (next_out < next_in) {
        var out: i32 = -1;
        assert(ev_core.qPop(&q, &out, @sizeOf(i32)) == 0);
        assert(out == next_out);
        next_out += 1;
    }
    assert(ev_core.qCount(&q) == 0);
}

/// A head push on a queue that is about to wrap takes the newhead < 0 branch.
fn theHeadPushWraps() void {
    var q: c.JanetQueue = undefined;
    ev_core.qInit(&q);
    defer ev_core.qDeinit(&q);

    var seed: i32 = 0;
    assert(ev_core.qPush(&q, &seed, @sizeOf(i32)) == 0);
    assert(q.head == 0);

    var value: i32 = 99;
    assert(ev_core.qPushHead(&q, &value, @sizeOf(i32)) == 0);
    assert(q.head > 0);
    assert(ev_core.qCount(&q) == 2);

    var out: i32 = -1;
    assert(ev_core.qPop(&q, &out, @sizeOf(i32)) == 0);
    assert(out == 99);
    assert(ev_core.qPop(&q, &out, @sizeOf(i32)) == 0);
    assert(out == 0);
}

/// Items larger than a machine word exercise the itemsize arithmetic.
fn theQueueCarriesLargeItems() void {
    const Big = extern struct {
        a: i64,
        b: i64,
        tag: [24]u8,
    };

    var q: c.JanetQueue = undefined;
    ev_core.qInit(&q);
    defer ev_core.qDeinit(&q);

    var i: i64 = 0;
    while (i < 40) : (i += 1) {
        var item = std.mem.zeroes(Big);
        item.a = i;
        item.b = -i;
        _ = std.fmt.bufPrintZ(&item.tag, "item-{d}", .{i}) catch unreachable;
        assert(ev_core.qPush(&q, &item, @sizeOf(Big)) == 0);
    }
    i = 0;
    while (i < 40) : (i += 1) {
        var out = std.mem.zeroes(Big);
        assert(ev_core.qPop(&q, &out, @sizeOf(Big)) == 0);
        assert(out.a == i);
        assert(out.b == -i);
        var expected: [24]u8 = undefined;
        const text = std.fmt.bufPrintZ(&expected, "item-{d}", .{i}) catch unreachable;
        assert(std.mem.eql(u8, text, std.mem.sliceTo(&out.tag, 0)));
    }
}

/// One slot is always left empty, so a resize happens one item before the
/// buffer is actually full.
fn theQueueKeepsASpareSlot() void {
    var q: c.JanetQueue = undefined;
    ev_core.qInit(&q);
    defer ev_core.qDeinit(&q);

    var i: i32 = 0;
    while (i < 64) : (i += 1) {
        assert(ev_core.qPush(&q, &i, @sizeOf(i32)) == 0);
        assert(ev_core.qCount(&q) < q.capacity);
    }
}

// ==========================================================================
// The timeout min heap
// ==========================================================================

/// A stand-in for `JanetTimeout`, and the reason the kernels take a stride and
/// an offset at all. The padding and the trailing field make the `when` offset
/// something other than zero and the stride something other than the field
/// size, which is what those parameters exist to describe.
const Entry = extern struct {
    marker: i32,
    when: i64,
    payload: [12]u8,
};

const entry_stride = @sizeOf(Entry);
const entry_offset = @offsetOf(Entry, "when");

fn swapEntries(heap: []Entry, a: usize, b: usize) void {
    const tmp = heap[a];
    heap[a] = heap[b];
    heap[b] = tmp;
}

/// The insertion loop from `addTimeout`, spelled out against the kernel.
fn heapPush(heap: []Entry, count: *usize, when: i64, marker: i32) void {
    var index = count.*;
    heap[index] = std.mem.zeroes(Entry);
    heap[index].when = when;
    heap[index].marker = marker;
    count.* += 1;
    while (true) {
        const parent = ev_core.heapSiftUp(heap.ptr, entry_stride, entry_offset, index);
        if (parent < 0) break;
        swapEntries(heap, index, @intCast(parent));
        index = @intCast(parent);
    }
}

/// The removal loop from `popTimeout`, spelled out against the kernel.
fn heapPop(heap: []Entry, count: *usize) Entry {
    const top = heap[0];
    count.* -= 1;
    heap[0] = heap[count.*];
    var index: usize = 0;
    while (true) {
        const smallest = ev_core.heapSiftDown(
            heap.ptr,
            entry_stride,
            entry_offset,
            count.*,
            index,
        );
        if (smallest < 0) break;
        swapEntries(heap, index, @intCast(smallest));
        index = @intCast(smallest);
    }
    return top;
}

fn theOrderedHeapReportsNoSwap() void {
    var heap = std.mem.zeroes([3]Entry);
    heap[0].when = 10;
    heap[1].when = 20;
    heap[2].when = 30;

    // The root is already smallest, and neither child has a parent to rise
    // above.
    assert(ev_core.heapSiftDown(&heap, entry_stride, entry_offset, 3, 0) == -1);
    assert(ev_core.heapSiftUp(&heap, entry_stride, entry_offset, 0) == -1);
    assert(ev_core.heapSiftUp(&heap, entry_stride, entry_offset, 1) == -1);
    assert(ev_core.heapSiftUp(&heap, entry_stride, entry_offset, 2) == -1);
}

fn theHeapSelectsChildren() void {
    var heap = std.mem.zeroes([3]Entry);

    // Left child smallest.
    heap[0].when = 30;
    heap[1].when = 10;
    heap[2].when = 20;
    assert(ev_core.heapSiftDown(&heap, entry_stride, entry_offset, 3, 0) == 1);

    // Right child smallest.
    heap[1].when = 20;
    heap[2].when = 10;
    assert(ev_core.heapSiftDown(&heap, entry_stride, entry_offset, 3, 0) == 2);

    // A tie between the children keeps the left one, which is what the C
    // implementation's strict comparisons produce.
    heap[1].when = 10;
    heap[2].when = 10;
    assert(ev_core.heapSiftDown(&heap, entry_stride, entry_offset, 3, 0) == 1);

    // A child equal to the parent does not move: the parent wins ties too.
    heap[0].when = 10;
    assert(ev_core.heapSiftDown(&heap, entry_stride, entry_offset, 3, 0) == -1);
}

/// Children outside the live count are invisible, which is what makes the
/// shrink in `popTimeout` safe.
fn theHeapRespectsTheCount() void {
    var heap = std.mem.zeroes([3]Entry);
    heap[0].when = 30;
    heap[1].when = 10;
    heap[2].when = 20;

    assert(ev_core.heapSiftDown(&heap, entry_stride, entry_offset, 1, 0) == -1);
    assert(ev_core.heapSiftDown(&heap, entry_stride, entry_offset, 2, 0) == 1);
    assert(ev_core.heapSiftDown(&heap, entry_stride, entry_offset, 3, 0) == 1);
}

fn theHeapSiftsUpToItsParent() void {
    var heap = std.mem.zeroes([4]Entry);
    heap[0].when = 10;
    heap[1].when = 50;
    heap[2].when = 60;
    heap[3].when = 20;

    // Index 3's parent is index 1, and 20 < 50, so it rises.
    assert(ev_core.heapSiftUp(&heap, entry_stride, entry_offset, 3) == 1);
    // Index 1's parent is the root, and 50 > 10, so it stays.
    assert(ev_core.heapSiftUp(&heap, entry_stride, entry_offset, 1) == -1);
    // An equal parent also stays: sifting up compares with <=.
    heap[3].when = 50;
    assert(ev_core.heapSiftUp(&heap, entry_stride, entry_offset, 3) == -1);
}

/// Driving both kernels through a full heapsort checks the ordering end to end
/// rather than one decision at a time.
fn theHeapOrdersAFullSequence() void {
    const input = [_]i64{
        50, 10, 40, 10, 90, 0, -5, 70, 30, 30, 1, 1000000, -100, 20, 60,
    };
    var heap = std.mem.zeroes([input.len]Entry);
    var count: usize = 0;

    for (input, 0..) |when, i| heapPush(&heap, &count, when, @intCast(i));
    assert(count == input.len);

    var previous: i64 = std.math.minInt(i64);
    for (0..input.len) |_| {
        const got = heapPop(&heap, &count);
        assert(got.when >= previous);
        previous = got.when;
    }
    assert(count == 0);
}

// ==========================================================================
// The timestamp arithmetic
// ==========================================================================

fn theDelta() void {
    assert(ev_core.tsDelta(1000, 0.0) == 1000);
    assert(ev_core.tsDelta(1000, 1.0) == 2000);
    assert(ev_core.tsDelta(1000, 0.5) == 1500);
    assert(ev_core.tsDelta(1000, -0.5) == 500);

    // Milliseconds are rounded, not truncated.
    assert(ev_core.tsDelta(0, 0.0004) == 0);
    assert(ev_core.tsDelta(0, 0.0006) == 1);
    assert(ev_core.tsDelta(0, 0.0015) == 2);

    // A negative infinity is "already due"; a positive one is "never".
    assert(ev_core.tsDelta(1234, -std.math.inf(f64)) == 1234);
    assert(ev_core.tsDelta(1234, std.math.inf(f64)) == std.math.maxInt(i64));
}

fn theParts() void {
    assert(ev_core.tsFromParts(0, 0) == 0);
    assert(ev_core.tsFromParts(1, 0) == 1000);
    assert(ev_core.tsFromParts(0, 1000000) == 1);
    // Sub-millisecond nanoseconds are dropped rather than rounded.
    assert(ev_core.tsFromParts(0, 999999) == 0);
    assert(ev_core.tsFromParts(2, 500000000) == 2500);

    var sec: i64 = -1;
    var nsec: i64 = -1;
    ev_core.tsToParts(0, &sec, &nsec);
    assert(sec == 0 and nsec == 0);

    ev_core.tsToParts(1500, &sec, &nsec);
    assert(sec == 1 and nsec == 500000000);

    ev_core.tsToParts(1000, &sec, &nsec);
    assert(sec == 1 and nsec == 0);

    ev_core.tsToParts(7, &sec, &nsec);
    assert(sec == 0 and nsec == 7000000);

    // A round trip through both directions is exact on millisecond values.
    var ts: i64 = 1;
    while (ts < 100000) : (ts += 337) {
        ev_core.tsToParts(ts, &sec, &nsec);
        assert(ev_core.tsFromParts(sec, nsec) == ts);
    }
}

fn theKqueueInterval() void {
    assert(ev_core.kqueueInterval(0) == 0);
    assert(ev_core.kqueueInterval(5) == 5);
    assert(ev_core.kqueueInterval(std.math.maxInt(i64)) == std.math.maxInt(i64));
    // A deadline already in the past clamps to the minimum.
    assert(ev_core.kqueueInterval(-1) == 0);
    assert(ev_core.kqueueInterval(std.math.minInt(i64)) == 0);
}

pub fn run() void {
    theEmptyQueue();
    theQueueIsFirstInFirstOut();
    theHeadPushReversesTheOrder();
    theQueueWrapsAndResizes();
    theHeadPushWraps();
    theQueueCarriesLargeItems();
    theQueueKeepsASpareSlot();

    theOrderedHeapReportsNoSwap();
    theHeapSelectsChildren();
    theHeapRespectsTheCount();
    theHeapSiftsUpToItsParent();
    theHeapOrdersAFullSequence();

    theDelta();
    theParts();
    theKqueueInterval();

    std.debug.print("ev_core contract ok\n", .{});
}
