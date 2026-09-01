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
//! ## Two things about how the subjects are reached
//!
//! **The heap is driven through `Timeout` itself.** The kernels used to
//! take a base pointer, a stride and the offset of the `when` field, and a
//! local `Entry` with a different layout was what proved they needed none of
//! `Timeout`'s definition. They take `[]const Timeout` now -- there
//! is one heap in the runtime and one element type in it -- so the stand-in
//! would assert nothing that the real element does not. The heap is still
//! built here, from `when` values alone: `zeroes` fills the `pthread_t` on
//! POSIX and the two `HANDLE`s on Windows, and nothing in the ordering reads
//! them.
//!
//! **One assertion could not survive, and the type is why.**
//! `janet_ev_q_pop(&q, NULL, sizeof(int32_t))` is what a C contract writes to
//! check that an empty queue reports before it writes. `pop` takes a `*T`, so
//! there is no null to pass. What is kept is the half that still has a
//! subject: a pop from an empty queue leaves the caller's variable as it was
//! -- said here because the next reader will look for the other.
//!
//! **The queue is a `Queue(T)` rather than a byte ring.** The element type is
//! the compiler's business, so the `@sizeOf` that used to accompany every call
//! is gone, and the two element types below -- `i32` and a 40-byte `Big` --
//! are what stands in for the runtime's `Task`, `Pending` and `Value`.

const std = @import("std");

const subsystems = @import("subsystems");
const ev_core = subsystems.ev;

const expect = @import("expect.zig").expect;

// ==========================================================================
// The generic queue
// ==========================================================================

fn theEmptyQueue() void {
    var q: ev_core.Queue(i32) = undefined;
    q.init();
    defer q.deinit();

    expect(q.data == null);
    expect(q.capacity == 0);
    expect(q.count() == 0);

    // Popping an empty queue reports failure and leaves the output alone.
    var out: i32 = 12345;
    expect(q.pop(&out) == 1);
    expect(out == 12345);
}

fn theQueueIsFirstInFirstOut() void {
    var q: ev_core.Queue(i32) = undefined;
    q.init();
    defer q.deinit();

    var i: i32 = 0;
    while (i < 100) : (i += 1) {
        expect(q.push(i) == 0);
        expect(q.count() == i + 1);
    }
    i = 0;
    while (i < 100) : (i += 1) {
        var out: i32 = -1;
        expect(q.pop(&out) == 0);
        expect(out == i);
    }
    expect(q.count() == 0);
}

fn theHeadPushReversesTheOrder() void {
    var q: ev_core.Queue(i32) = undefined;
    q.init();
    defer q.deinit();

    var i: i32 = 0;
    while (i < 50) : (i += 1) {
        expect(q.pushHead(i) == 0);
    }
    expect(q.count() == 50);
    i = 49;
    while (i >= 0) : (i -= 1) {
        var out: i32 = -1;
        expect(q.pop(&out) == 0);
        expect(out == i);
    }
}

/// Interleaving pushes and pops walks head and tail around the buffer, so the
/// resize path runs with head > tail and has to move the wrapped segment.
fn theQueueWrapsAndResizes() void {
    var q: ev_core.Queue(i32) = undefined;
    q.init();
    defer q.deinit();

    var next_in: i32 = 0;
    var next_out: i32 = 0;

    var round: u32 = 0;
    while (round < 200) : (round += 1) {
        for (0..3) |_| {
            expect(q.push(next_in) == 0);
            next_in += 1;
        }
        for (0..2) |_| {
            var out: i32 = -1;
            expect(q.pop(&out) == 0);
            expect(out == next_out);
            next_out += 1;
        }
        expect(q.count() == next_in - next_out);
    }

    // Everything still queued comes out in order, unshuffled by any resize.
    while (next_out < next_in) {
        var out: i32 = -1;
        expect(q.pop(&out) == 0);
        expect(out == next_out);
        next_out += 1;
    }
    expect(q.count() == 0);
}

/// A head push on a queue that is about to wrap takes the newhead < 0 branch.
fn theHeadPushWraps() void {
    var q: ev_core.Queue(i32) = undefined;
    q.init();
    defer q.deinit();

    const seed: i32 = 0;
    expect(q.push(seed) == 0);
    expect(q.head == 0);

    const value: i32 = 99;
    expect(q.pushHead(value) == 0);
    expect(q.head > 0);
    expect(q.count() == 2);

    var out: i32 = -1;
    expect(q.pop(&out) == 0);
    expect(out == 99);
    expect(q.pop(&out) == 0);
    expect(out == 0);
}

/// Items larger than a machine word: the element type is what sizes the
/// buffer, and this is the queue whose stride is not a machine word.
fn theQueueCarriesLargeItems() void {
    const Big = extern struct {
        a: i64,
        b: i64,
        tag: [24]u8,
    };

    var q: ev_core.Queue(Big) = undefined;
    q.init();
    defer q.deinit();

    var i: i64 = 0;
    while (i < 40) : (i += 1) {
        var item = std.mem.zeroes(Big);
        item.a = i;
        item.b = -i;
        _ = std.fmt.bufPrintZ(&item.tag, "item-{d}", .{i}) catch unreachable;
        expect(q.push(item) == 0);
    }
    i = 0;
    while (i < 40) : (i += 1) {
        var out = std.mem.zeroes(Big);
        expect(q.pop(&out) == 0);
        expect(out.a == i);
        expect(out.b == -i);
        var expected: [24]u8 = undefined;
        const text = std.fmt.bufPrintZ(&expected, "item-{d}", .{i}) catch unreachable;
        expect(std.mem.eql(u8, text, std.mem.sliceTo(&out.tag, 0)));
    }
}

/// One slot is always left empty, so a resize happens one item before the
/// buffer is actually full.
fn theQueueKeepsASpareSlot() void {
    var q: ev_core.Queue(i32) = undefined;
    q.init();
    defer q.deinit();

    var i: i32 = 0;
    while (i < 64) : (i += 1) {
        expect(q.push(i) == 0);
        expect(q.count() < q.capacity);
    }
}

// ==========================================================================
// The timeout min heap
// ==========================================================================

const Entry = ev_core.Timeout;

/// The heap element carries more than the ordering reads, and `sched_id` is
/// the one other scalar in it, so it stands in for the marker the sort check
/// needs to tell two equal `when` values apart.
fn entry(when: i64, marker: u32) Entry {
    var e = std.mem.zeroes(Entry);
    e.when = when;
    e.sched_id = marker;
    return e;
}

fn swapEntries(heap: []Entry, a: usize, b: usize) void {
    const tmp = heap[a];
    heap[a] = heap[b];
    heap[b] = tmp;
}

/// The insertion loop from `addTimeout`, spelled out against the kernel.
fn heapPush(heap: []Entry, count: *usize, when: i64, marker: u32) void {
    var index = count.*;
    heap[index] = entry(when, marker);
    count.* += 1;
    while (true) {
        const parent = ev_core.heapSiftUp(heap[0..count.*], index);
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
        const smallest = ev_core.heapSiftDown(heap[0..count.*], index);
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
    expect(ev_core.heapSiftDown(&heap, 0) == -1);
    expect(ev_core.heapSiftUp(&heap, 0) == -1);
    expect(ev_core.heapSiftUp(&heap, 1) == -1);
    expect(ev_core.heapSiftUp(&heap, 2) == -1);
}

fn theHeapSelectsChildren() void {
    var heap = std.mem.zeroes([3]Entry);

    // Left child smallest.
    heap[0].when = 30;
    heap[1].when = 10;
    heap[2].when = 20;
    expect(ev_core.heapSiftDown(&heap, 0) == 1);

    // Right child smallest.
    heap[1].when = 20;
    heap[2].when = 10;
    expect(ev_core.heapSiftDown(&heap, 0) == 2);

    // A tie between the children keeps the left one, which is what the C
    // implementation's strict comparisons produce.
    heap[1].when = 10;
    heap[2].when = 10;
    expect(ev_core.heapSiftDown(&heap, 0) == 1);

    // A child equal to the parent does not move: the parent wins ties too.
    heap[0].when = 10;
    expect(ev_core.heapSiftDown(&heap, 0) == -1);
}

/// Children outside the live count are invisible, which is what makes the
/// shrink in `popTimeout` safe.
fn theHeapRespectsTheCount() void {
    var heap = std.mem.zeroes([3]Entry);
    heap[0].when = 30;
    heap[1].when = 10;
    heap[2].when = 20;

    expect(ev_core.heapSiftDown(heap[0..1], 0) == -1);
    expect(ev_core.heapSiftDown(heap[0..2], 0) == 1);
    expect(ev_core.heapSiftDown(heap[0..3], 0) == 1);
}

fn theHeapSiftsUpToItsParent() void {
    var heap = std.mem.zeroes([4]Entry);
    heap[0].when = 10;
    heap[1].when = 50;
    heap[2].when = 60;
    heap[3].when = 20;

    // Index 3's parent is index 1, and 20 < 50, so it rises.
    expect(ev_core.heapSiftUp(&heap, 3) == 1);
    // Index 1's parent is the root, and 50 > 10, so it stays.
    expect(ev_core.heapSiftUp(&heap, 1) == -1);
    // An equal parent also stays: sifting up compares with <=.
    heap[3].when = 50;
    expect(ev_core.heapSiftUp(&heap, 3) == -1);
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
    expect(count == input.len);

    var previous: i64 = std.math.minInt(i64);
    for (0..input.len) |_| {
        const got = heapPop(&heap, &count);
        expect(got.when >= previous);
        previous = got.when;
    }
    expect(count == 0);
}

// ==========================================================================
// The timestamp arithmetic
// ==========================================================================

fn theDelta() void {
    expect(ev_core.tsDelta(1000, 0.0) == 1000);
    expect(ev_core.tsDelta(1000, 1.0) == 2000);
    expect(ev_core.tsDelta(1000, 0.5) == 1500);
    expect(ev_core.tsDelta(1000, -0.5) == 500);

    // Milliseconds are rounded, not truncated.
    expect(ev_core.tsDelta(0, 0.0004) == 0);
    expect(ev_core.tsDelta(0, 0.0006) == 1);
    expect(ev_core.tsDelta(0, 0.0015) == 2);

    // A negative infinity is "already due"; a positive one is "never".
    expect(ev_core.tsDelta(1234, -std.math.inf(f64)) == 1234);
    expect(ev_core.tsDelta(1234, std.math.inf(f64)) == std.math.maxInt(i64));
}

fn theParts() void {
    expect(ev_core.tsFromParts(0, 0) == 0);
    expect(ev_core.tsFromParts(1, 0) == 1000);
    expect(ev_core.tsFromParts(0, 1000000) == 1);
    // Sub-millisecond nanoseconds are dropped rather than rounded.
    expect(ev_core.tsFromParts(0, 999999) == 0);
    expect(ev_core.tsFromParts(2, 500000000) == 2500);

    var sec: i64 = -1;
    var nsec: i64 = -1;
    ev_core.tsToParts(0, &sec, &nsec);
    expect(sec == 0 and nsec == 0);

    ev_core.tsToParts(1500, &sec, &nsec);
    expect(sec == 1 and nsec == 500000000);

    ev_core.tsToParts(1000, &sec, &nsec);
    expect(sec == 1 and nsec == 0);

    ev_core.tsToParts(7, &sec, &nsec);
    expect(sec == 0 and nsec == 7000000);

    // A round trip through both directions is exact on millisecond values.
    var ts: i64 = 1;
    while (ts < 100000) : (ts += 337) {
        ev_core.tsToParts(ts, &sec, &nsec);
        expect(ev_core.tsFromParts(sec, nsec) == ts);
    }
}

fn theKqueueInterval() void {
    expect(ev_core.kqueueInterval(0) == 0);
    expect(ev_core.kqueueInterval(5) == 5);
    expect(ev_core.kqueueInterval(std.math.maxInt(i64)) == std.math.maxInt(i64));
    // A deadline already in the past clamps to the minimum.
    expect(ev_core.kqueueInterval(-1) == 0);
    expect(ev_core.kqueueInterval(std.math.minInt(i64)) == 0);
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
