//! The event loop: the scheduler, and the primitives a subsystem suspends on.
//!
//! One name, `ev`, for what Janet publishes as one module. `ev/` beside it
//! holds the four pieces that have names of their own: the stream, the
//! channel, the backend, and the locks.
const std = @import("std");
const builtin = @import("builtin");
const corefn = @import("corefn.zig");
const raise = @import("../api/raise.zig");
const stdio = @import("stdio.zig");
const pp_format = @import("pp/format.zig");
const registry = @import("registry.zig");
const ev_callback = @import("callback_type.zig");
const tables = @import("value/tables.zig");
const gc_alloc = @import("gc.zig");
const arrays = @import("value/arrays.zig");
const buffers = @import("value/buffers.zig");
const tuples = @import("value/tuples.zig");
const utils = @import("utils.zig");
const abstracts = @import("value/abstracts.zig");
const gc_mark = @import("gc/mark.zig");
const vm_entry = @import("vm/entry.zig");
const vm_state = @import("vm/state.zig");
const vm_lifecycle = @import("vm/lifecycle.zig");
const math = @import("math.zig");
const signal_core = @import("signal.zig");
const wrap = @import("value/helpers/wrap.zig");
const fibers = @import("value/fibers.zig");
const trace_frames = @import("debug.zig");
const args_core = @import("args.zig");
const marsh = @import("marsh.zig");
const abstract_type = @import("../api/abstract_type.zig");
const ev_core = @import("ev.zig");
const os_locks = @import("ev/locks.zig");

/// The four leaves beside this file, re-exported for callers that reach the
/// loop rather than the piece. They are `pub` where the plain imports above
/// are not, so a mechanical edit that treats this block as an import list
/// breaks every dotted reference to them.
pub const backend = @import("ev/backend.zig");
pub const channel = @import("ev/channel.zig");
pub const stream = @import("ev/stream.zig");
pub const streamFlags = stream.streamFlags;
pub const streamClose = stream.streamClose;
pub const makeStream = stream.makeStream;
pub const makeStreamExt = stream.makeStreamExt;
pub const evInit = backend.evInit;
pub const edgeTriggeredStream = backend.edgeTriggeredStream;
pub const levelTriggeredStream = backend.levelTriggeredStream;
pub const getChannel = channel.getChannel;
pub const channelGive = channel.channelGive;

const repr = @import("repr");
const constants = @import("constants");
const value = @import("value.zig");
const os_surface = @import("os.zig");
const c = @import("cabi");
const strings = @import("value/strings.zig");
const abi = @import("abi");
const ev_stream = @import("ev/stream.zig");
const host = @import("host");

pub const ThreadedSubroutine = ?*const fn (arguments: GenericMessage) callconv(.c) GenericMessage;

pub const ThreadedCallback = ?*const fn (return_value: GenericMessage) callconv(.c) void;

pub const Timestamp = i64;

/// A ring buffer of `T`, and the runtime's only queue: the scheduler's spawn
/// list and a channel's items and two pending lists.
///
/// **It is generic over `T` rather than type-erased**, which is what keeps the
/// element type and the buffer it goes into from being told apart by an
/// argument: `chan.items` holds `repr.Value` while its neighbours hold
/// `Pending`. The wrap walk that four operations and two of
/// `ev/channel.zig`'s traversals would each write out is `segments` below.
///
/// The indices stay `i32`. `max_queue_capacity` and Janet's marshalled
/// channel format are both written in terms of them, and widening them would
/// change what a channel round-trips.
pub fn Queue(comptime T: type) type {
    return struct {
        capacity: i32 = 0,
        head: i32 = 0,
        tail: i32 = 0,
        data: ?[*]T = null,

        const Self = @This();

        pub fn init(q: *Self) void {
            q.* = .{};
        }

        pub fn deinit(q: *Self) void {
            utils.free(@ptrCast(q.data));
        }

        /// Items between `head` and `tail`, wrapping through the end of the
        /// buffer.
        ///
        /// The arithmetic wraps explicitly. Every term stays well inside `i32`
        /// -- capacity never exceeds `max_queue_capacity` -- but a corrupted
        /// queue must not trap here, so this commits to wrapping.
        pub fn count(q: *const Self) i32 {
            return if (q.head > q.tail)
                q.tail +% q.capacity -% q.head
            else
                q.tail -% q.head;
        }

        /// The live items, as the one or two contiguous runs the ring holds
        /// them in. Empty runs for an unallocated queue, which is what the
        /// `data orelse return` at the head of each open-coded walk did.
        pub fn segments(q: *Self) [2][]T {
            const items = q.data orelse return .{ &.{}, &.{} };
            const head: usize = @intCast(q.head);
            const tail: usize = @intCast(q.tail);
            if (head <= tail) return .{ items[head..tail], &.{} };
            return .{ items[head..@intCast(q.capacity)], items[0..tail] };
        }

        /// Grow the queue if another item would fill it, returning 1 if it
        /// cannot grow.
        ///
        /// One slot is always left empty so that a full queue is
        /// distinguishable from an empty one, which is why the test is
        /// `count + 1 >= capacity`.
        fn maybeResize(q: *Self) c_int {
            const n = q.count();
            if (n +% 1 < q.capacity) return 0;
            if (n +% 1 >= max_queue_capacity) return 1;

            var newcap: i32 = (n +% 2) *% 2;
            if (newcap > max_queue_capacity) newcap = max_queue_capacity;

            q.data = @ptrCast(@alignCast(utils.rawRealloc(
                @ptrCast(q.data),
                @sizeOf(T) * @as(usize, @intCast(newcap)),
            )));

            if (q.head > q.tail) {
                // The live items are in two segments. Growing the buffer moves
                // the second segment to sit against the new end, keeping it
                // contiguous with the first across the wrap.
                const newhead = q.head +% (newcap -% q.capacity);
                const seg1: usize = @intCast(q.capacity -% q.head);
                if (seg1 > 0) {
                    const items = q.data.?;
                    const source = items[@intCast(q.head)..][0..seg1];
                    const destination = items[@intCast(newhead)..][0..seg1];
                    // The regions overlap whenever the buffer less than
                    // doubled.
                    @memmove(destination, source);
                }
                q.head = newhead;
            }

            q.capacity = newcap;
            return 0;
        }

        pub fn push(q: *Self, item: T) c_int {
            if (q.maybeResize() != 0) return 1;
            q.data.?[@intCast(q.tail)] = item;
            q.tail = if (q.tail +% 1 < q.capacity) q.tail +% 1 else 0;
            return 0;
        }

        pub fn pushHead(q: *Self, item: T) c_int {
            if (q.maybeResize() != 0) return 1;
            var newhead = q.head -% 1;
            if (newhead < 0) newhead +%= q.capacity;
            q.data.?[@intCast(newhead)] = item;
            q.head = newhead;
            return 0;
        }

        pub fn pop(q: *Self, out: *T) c_int {
            if (q.head == q.tail) return 1;
            out.* = q.data.?[@intCast(q.head)];
            q.head = if (q.head +% 1 < q.capacity) q.head +% 1 else 0;
            return 0;
        }
    };
}

/// `state.h` gives the waiter thread two `HANDLE`s on Windows and one
/// `pthread_t` elsewhere, so this is 48 bytes there and 40 here.
pub const Timeout = if (builtin.os.tag == .windows) struct {
    when: Timestamp = 0,
    fiber: ?*fibers.Fiber = null,
    curr_fiber: ?*fibers.Fiber = null,
    sched_id: u32 = 0,
    is_error: bool = false,
    has_worker: bool = false,
    worker: ?*anyopaque = null,
    worker_event: ?*anyopaque = null,
} else struct {
    when: Timestamp = 0,
    fiber: ?*fibers.Fiber = null,
    curr_fiber: ?*fibers.Fiber = null,
    sched_id: u32 = 0,
    is_error: bool = false,
    has_worker: bool = false,
    worker: host.pthread_t = std.mem.zeroes(host.pthread_t),
};

pub const windows = builtin.os.tag == .windows;
pub const android = builtin.abi.isAndroid();
pub const has_net = constants.JANET_VM_HAS_NET != 0;
pub const has_interrupt = constants.JANET_VM_HAS_INTERRUPT != 0;

// -------------------------------------------------------------------------
// The loop and its cfunctions.
// -------------------------------------------------------------------------

/// Abort, naming this file's own position. Not overridable: an embedder's own
/// exit hook is a preprocessor facility with nothing behind it here.
pub fn exitWith(comptime where: std.builtin.SourceLocation, comptime message: []const u8) noreturn {
    const line = std.fmt.comptimePrint(
        "janet abort at {s}:{d}: {s}\n",
        .{ where.file, where.line, message },
    );
    _ = c.fwrite(line.ptr, 1, line.len, stdio.err());
    c.abort();
}

/// A variadic `(dyn :err)` write, spelled out here because Zig cannot define a
/// C variadic on every target this builds for. `env.zig` and `debug.zig` carry
/// the same lines for the same reason.
///
/// The one caller is `goThreadSubr`, which runs at the top of a new thread on
/// the *failure* path, with no scope above it and its two neighbours already
/// spelled `raise.total`. `pp/format.dynprintf` can raise -- `(dyn :err)` may
/// be a Janet function -- and a raise there has nowhere to go, so it aborts at
/// the site rather than leaving a report for whatever opens the next scope.
inline fn eprintf(comptime format: [:0]const u8, args: anytype) void {
    raise.total(pp_format.dynprintf("err", stdio.err(), format, args), "a thread subroutine's stderr report");
}

/// Abort with the caller's `@src()` unless `cond`.
pub inline fn assert(comptime where: std.builtin.SourceLocation, cond: bool, comptime message: []const u8) void {
    if (!cond) exitWith(where, message);
}

/// Report where the allocation failed and end the process. The caller's
/// `@src()` is what names the site.
pub fn outOfMemory(comptime where: std.builtin.SourceLocation) noreturn {
    const line = std.fmt.comptimePrint(
        "{s}:{d} - janet out of memory\n",
        .{ where.file, where.line },
    );
    _ = c.fwrite(line.ptr, 1, line.len, stdio.err());
    c.exit(1);
}

// ==========================================================================
// The timeout min heap
// ==========================================================================

/// The clock the timeout heap is ordered by: one arithmetic over `os.zig`'s
/// `gettime`, shared by every backend, with the Windows arm reading a tick
/// count instead of a clock.
pub fn tsNow() Timestamp {
    if (windows) return @intCast(c.GetTickCount64());
    const now = os_surface.gettime(1);
    assert(@src(), now != null, "failed to get time");
    // The assert above aborts on null, so nothing reaches the unwrap with one.
    const parts = now orelse unreachable;
    return ev_core.tsFromParts(parts.sec, parts.nsec);
}

/// Look at the next timeout without removing it, or null when there is none.
pub fn peekTimeout() ?Timeout {
    const sched = &vm_state.current().ev;
    if (sched.tq.items.len == 0) return null;
    return sched.tq.items[0];
}

/// Remove one timeout from the min heap and restore the heap property.
pub fn popTimeout(start: usize) void {
    var index = start;
    const sched = &vm_state.current().ev;
    if (sched.tq.items.len <= index) return;
    _ = sched.tq.swapRemove(index);
    while (true) {
        const heap = sched.tq.items;
        const smallest = ev_core.heapSiftDown(heap, index);
        if (smallest < 0) return;
        const target: usize = @intCast(smallest);
        const temp = heap[index];
        heap[index] = heap[target];
        heap[target] = temp;
        index = target;
    }
}

/// Add a timeout to the min heap, growing it if it is full.
pub fn addTimeout(to: Timeout) void {
    const sched = &vm_state.current().ev;
    const oldcount = sched.tq.items.len;
    sched.tq.append(utils.heap, to) catch outOfMemory(@src());
    var index = oldcount;
    while (true) {
        const heap = sched.tq.items;
        const parent = ev_core.heapSiftUp(heap, index);
        if (parent < 0) break;
        const target: usize = @intCast(parent);
        const tmp = heap[index];
        heap[index] = heap[target];
        heap[target] = tmp;
        index = target;
    }
}

// ==========================================================================
// Scheduling
// ==========================================================================

/// One entry of the scheduler's spawn list: the fiber to resume, the value to
/// resume it with, and the signal that resumption carries.
pub const Task = struct {
    fiber: *fibers.Fiber,
    value: repr.Value,
    sig: abi.Signal,
    /// If the fiber has been rescheduled this loop, don't run first scheduling.
    expected_sched_id: u32,
};

const fiber_flag_canceled: i32 = @intCast(constants.JANET_FIBER_EV_FLAG_CANCELED);
const fiber_flag_suspended: i32 = @intCast(constants.JANET_FIBER_EV_FLAG_SUSPENDED);
const fiber_flag_root: i32 = @intCast(constants.JANET_FIBER_FLAG_ROOT);

fn scheduleGeneral(fiber: *fibers.Fiber, val: repr.Value, sig: abi.Signal, soon: bool) void {
    const sched = &vm_state.current().ev;
    if (fibers.evFlags(fiber).canceled) return;
    if (!fibers.evFlags(fiber).root) {
        const task_element = wrap.fromFiber(fiber);
        tables.put(&sched.active_tasks, task_element, wrap.fromTrue());
    }
    fiber.sched_id +%= 1;
    const t: Task = .{
        .fiber = fiber,
        .value = val,
        .sig = sig,
        .expected_sched_id = fiber.sched_id,
    };
    fiber.gc.flags.own |= @as(u6, @bitCast(fibers.EvFlags{ .root = true }));
    if (sig == .@"error") fiber.gc.flags.own |= @as(u6, @bitCast(fibers.EvFlags{ .canceled = true }));
    const pushed = if (soon)
        sched.spawn.pushHead(t)
    else
        sched.spawn.push(t);
    assert(@src(), pushed == 0, "schedule queue overflow");
}

pub fn scheduleSignal(fiber: *fibers.Fiber, val: repr.Value, sig: abi.Signal) void {
    scheduleGeneral(fiber, val, sig, false);
}

pub fn scheduleSoon(fiber: *fibers.Fiber, val: repr.Value, sig: abi.Signal) void {
    scheduleGeneral(fiber, val, sig, true);
}

pub fn cancel(fiber: *fibers.Fiber, val: repr.Value) raise.Raising(void) {
    if (!fibers.evFlags(fiber).root) {
        return raise.panic("cannot cancel non-task fiber");
    }
    scheduleGeneral(fiber, val, .@"error", false);
}

pub fn schedule(fiber: *fibers.Fiber, val: repr.Value) void {
    scheduleGeneral(fiber, val, .ok, false);
}

/// Mark every fiber and value the scheduler is holding on to.
pub fn evMark() void {
    const sched = &vm_state.current().ev;
    for (sched.spawn.segments()) |run| {
        for (run) |*task| markTask(task);
    }

    for (sched.tq.items) |timeout| {
        gc_mark.mark(wrap.fromFiber(timeout.fiber.?));
        if (timeout.curr_fiber) |curr| {
            gc_mark.mark(wrap.fromFiber(curr));
        }
    }
}

inline fn markTask(t: *const Task) void {
    gc_mark.mark(wrap.fromFiber(t.fiber));
    gc_mark.mark(t.value);
}

// ==========================================================================
// Async listeners on a stream
// ==========================================================================

/// Stop sending events to a fiber's callback and release what it held.
pub fn asyncEnd(fiber: *fibers.Fiber) void {
    if (fiber.ev_callback) |cb| {
        if (fiber.ev_stream.?.read_fiber == fiber) fiber.ev_stream.?.read_fiber = null;
        if (fiber.ev_stream.?.write_fiber == fiber) fiber.ev_stream.?.write_fiber = null;
        ev_callback.dispatchTotal(ev_callback.of(cb), fiber, constants.AsyncEvent.deinit);
        _ = gc_alloc.gcunroot(wrap.fromAbstract(fiber.ev_stream));
        fiber.ev_callback = null;
        if (!fiber.flags.evInFlight()) {
            if (fiber.ev_state) |state| {
                utils.free(state);
                fiber.ev_state = null;
            }
            evDecRefcount();
        }
    }
}

/// Mark a fiber as waiting on a completion that has not been delivered yet.
/// A no-op away from Windows, where there is no in-flight state to track.
pub fn asyncInFlight(fiber: *fibers.Fiber) void {
    if (windows) fiber.flags.setEvInFlight(true);
}

pub fn asyncStartFiber(
    fiber: ?*fibers.Fiber,
    s: *ev_stream.Stream,
    mode: constants.AsyncMode,
    callback: ev_callback.EVCallback,
    state: ?*anyopaque,
) raise.Raising(void) {
    assert(@src(), fiber.?.ev_callback == null, "double async on fiber");
    if (mode.read) s.read_fiber = fiber;
    if (mode.write) s.write_fiber = fiber;
    fiber.?.ev_callback = ev_callback.stored(callback);
    fiber.?.ev_stream = s;
    evIncRefcount();
    gc_alloc.gcroot(wrap.fromAbstract(s));
    fiber.?.ev_state = state;
    try callback(fiber.?, constants.AsyncEvent.init);
}

pub fn asyncStart(
    s: *ev_stream.Stream,
    mode: constants.AsyncMode,
    callback: ev_callback.EVCallback,
    state: ?*anyopaque,
) raise.Error {
    asyncStartFiber(vm_state.current().root_fiber, s, mode, callback, state) catch |err| return err;
    return awaitEvent();
}

pub fn fiberDidResume(fiber: *fibers.Fiber) void {
    asyncEnd(fiber);
}

// ==========================================================================
// Init, deinit, and the reference count that keeps the loop alive
// ==========================================================================

pub fn evIncRefcount() void {
    _ = abstracts.atomicInc(&vm_state.current().ev.listener_count);
}

pub fn evDecRefcount() void {
    _ = abstracts.atomicDec(&vm_state.current().ev.listener_count);
}

pub fn evInitCommon() void {
    const sched = &vm_state.current().ev;
    sched.spawn.init();
    sched.tq = .empty;
    _ = tables.initRaw(&sched.threaded_abstracts, 0);
    _ = tables.initRaw(&sched.active_tasks, 0);
    _ = tables.initRaw(&sched.signal_handlers, 0);
    math.rngSeed(&sched.ev_rng, 0);
    if (!windows) {
        _ = c.pthread_attr_init(&sched.backend.new_thread_attr);
        _ = c.pthread_attr_setdetachstate(&sched.backend.new_thread_attr, PTHREAD_CREATE_DETACHED);
    }
}

pub fn evDeinitCommon() void {
    const sched = &vm_state.current().ev;
    while (peekTimeout()) |to| {
        handleTimeoutWorker(to, true);
        popTimeout(0);
    }
    sched.spawn.deinit();
    sched.tq.deinit(utils.heap);
    sched.tq = .empty;
    tables.deinit(&sched.threaded_abstracts);
    tables.deinit(&sched.active_tasks);
    tables.deinit(&sched.signal_handlers);
    if (!windows) _ = c.pthread_attr_destroy(&sched.backend.new_thread_attr);
}

// ==========================================================================
// Yielding to the loop, and the timeouts a fiber can set on itself
// ==========================================================================

/// Yield to the event loop: a raise carrying the `.event` signal, returned
/// rather than jumped.
pub fn awaitEvent() raise.Error {
    return raise.signal(.event, wrap.fromNil());
}

fn addFiberTimeout(sec: f64, is_error: bool) void {
    const fiber = vm_state.current().root_fiber.?;
    addTimeout(.{
        .when = ev_core.tsDelta(tsNow(), sec),
        .fiber = fiber,
        .curr_fiber = null,
        .sched_id = fiber.sched_id,
        .is_error = is_error,
        .has_worker = false,
        .worker = std.mem.zeroes(@FieldType(Timeout, "worker")),
    });
}

pub fn addtimeout(sec: f64) void {
    addFiberTimeout(sec, true);
}

pub fn addtimeoutNil(sec: f64) void {
    addFiberTimeout(sec, false);
}

pub fn sleepAwait(sec: f64) raise.Error {
    const fiber = vm_state.current().root_fiber.?;
    addTimeout(.{
        .when = ev_core.tsDelta(tsNow(), sec),
        .fiber = fiber,
        .curr_fiber = null,
        .sched_id = fiber.sched_id,
        .is_error = false,
        .has_worker = false,
        .worker = std.mem.zeroes(@FieldType(Timeout, "worker")),
    });
    return awaitEvent();
}

// ==========================================================================
// The deadline worker thread
// ==========================================================================

/// What the deadline worker thread is started with, and what it reads back.
const ThreadedTimeout = struct {
    sec: f64,
    vm_ptr: *vm_state.Vm,
    fiber: *fibers.Fiber,
    cancel_event: if (windows) ?*anyopaque else void = if (windows) null else {},
};

fn timeoutCallback(msg: GenericMessage) callconv(.c) void {
    _ = msg;
    vm_state.interpreterInterruptHandled(vm_state.current());
}

/// Join, and optionally interrupt, the thread a `(ev/deadline ... true)` set
/// running. `has_worker` is false for every other kind of timeout.
fn handleTimeoutWorker(to: Timeout, cancel_it: bool) void {
    if (!to.has_worker) return;
    if (windows) {
        if (cancel_it and to.worker_event != null) _ = c.SetEvent(to.worker_event);
        _ = c.WaitForSingleObject(to.worker, INFINITE);
        _ = c.CloseHandle(to.worker);
        if (to.worker_event != null) _ = c.CloseHandle(to.worker_event);
    } else {
        if (cancel_it) {
            if (android) {
                assert(@src(), c.pthread_kill(to.worker, SIGUSR1) == 0, "pthread_kill");
            } else {
                assert(@src(), c.pthread_cancel(to.worker) == 0, "pthread_cancel");
            }
        }
        var res: ?*anyopaque = null;
        assert(@src(), c.pthread_join(to.worker, &res) == 0, "pthread_join");
    }
}

/// The Android arm's `SIGUSR1` handler: `c.pthread_cancel` is not available
/// there, so the worker is asked to exit instead.
fn timeoutStop(sig_num: c_int) void {
    if (sig_num == SIGUSR1) c.pthread_exit(null);
}

/// The Android arm installs a `SIGUSR1` handler here before sleeping, because
/// `c.pthread_cancel` does not exist there and `timeoutStop` is what stands in
/// for it. That installation is *recorded rather than written*: it needs a
/// `struct sigaction`, which is a host layout, and `android` is comptime-false
/// for every target this project builds -- so writing it would produce
/// something even less checked than what it replaced. `os/abi.zig` makes the
/// same call for the threads configuration.
fn timeoutBodyPosix(ptr: ?*anyopaque) callconv(.c) ?*anyopaque {
    const tto: *ThreadedTimeout = @ptrCast(@alignCast(ptr));
    const copy = tto.*;
    utils.free(ptr);
    var ts: std.c.timespec = .{
        .sec = @intFromFloat(copy.sec),
        .nsec = if (copy.sec <= @as(f64, std.math.maxInt(u32)))
            @intFromFloat((copy.sec - @as(f64, @floatFromInt(@as(u32, @intFromFloat(copy.sec))))) * 1000000000)
        else
            0,
    };
    _ = std.c.nanosleep(&ts, &ts);
    vm_state.interpreterInterrupt(copy.vm_ptr);
    const msg = std.mem.zeroes(GenericMessage);
    evPostEvent(copy.vm_ptr, timeoutCallback, msg);
    return null;
}

fn timeoutBodyWindows(ptr: ?*anyopaque) callconv(.winapi) u32 {
    const tto: *ThreadedTimeout = @ptrCast(@alignCast(ptr));
    const copy = tto.*;
    utils.free(ptr);
    const wait_begin = tsNow();
    const duration: u32 = @intFromFloat(@round(copy.sec * 1000));
    var res: u32 = WAIT_TIMEOUT;
    var wait_end = tsNow();
    var i: u32 = 1;
    while (res == WAIT_TIMEOUT and (wait_end - wait_begin) < duration) : (i += 1) {
        res = c.WaitForSingleObject(copy.cancel_event, duration + i);
        wait_end = tsNow();
    }
    if (res == WAIT_TIMEOUT) {
        vm_state.interpreterInterrupt(copy.vm_ptr);
        const msg = std.mem.zeroes(GenericMessage);
        evPostEvent(copy.vm_ptr, timeoutCallback, msg);
    }
    return 0;
}

// ==========================================================================
// The main loop
// ==========================================================================

pub fn loopDone() bool {
    const sched = &vm_state.current().ev;
    const busy = (sched.spawn.head != sched.spawn.tail) or
        (sched.tq.items.len != 0) or
        (abstracts.atomicLoad(&sched.listener_count) != 0);
    return !busy;
}

/// One turn of the loop: expired timers, then runnable fibers, then a poll.
///
/// Returns the fiber an interrupt stopped, or null. **The three stages and
/// their order are contract**, including that the poll is skipped when the
/// timer scan drained the heap.
pub fn loop1() raise.Raising(?*fibers.Fiber) {
    const v = vm_state.current();
    const sched = &v.ev;

    // Schedule expired timers.
    const now = tsNow();
    while (peekTimeout()) |to| {
        if (to.when > now) break;
        popTimeout(0);
        if (to.curr_fiber) |curr| {
            if (fibers.canResume(curr)) {
                // The fiber is a task, so this cannot raise.
                try cancel(to.fiber.?, value.fromBytes("deadline expired", .string));
            }
        } else if (to.fiber.?.sched_id == to.sched_id) {
            // A timeout on a call rather than on a whole fiber.
            if (to.is_error) {
                try cancel(to.fiber.?, value.fromBytes("timeout", .string));
            } else {
                schedule(to.fiber.?, wrap.fromNil());
            }
        }
        handleTimeoutWorker(to, false);
    }

    // Run scheduled fibers unless interrupts need to be handled.
    while (sched.spawn.head != sched.spawn.tail) {
        if (abstracts.atomicLoadRelaxed(&v.auto_suspend) != 0) break;
        var task: Task = .{
            .fiber = undefined,
            .value = wrap.fromNil(),
            .sig = .ok,
            .expected_sched_id = 0,
        };
        _ = sched.spawn.pop(&task);
        if (fibers.evFlags(task.fiber).suspended) evDecRefcount();
        task.fiber.gc.flags.own &= ~@as(u6, @bitCast(fibers.EvFlags{ .canceled = true, .suspended = true }));
        if (task.expected_sched_id != task.fiber.sched_id) continue;
        const resumed = vm_entry.continueSignal(task.fiber, task.value, task.sig);
        const sig = resumed.signal;
        const res = resumed.value;
        if (!fibers.canResume(task.fiber)) {
            _ = tables.remove(&sched.active_tasks, wrap.fromFiber(task.fiber));
        }
        const sv = task.fiber.supervisor_channel;
        const is_suspended = sig == abi.Signal.event or sig == .yield or sig == abi.Signal.interrupt;
        if (is_suspended) {
            task.fiber.gc.flags.own |= @as(u6, @bitCast(fibers.EvFlags{ .suspended = true }));
            evIncRefcount();
        }
        if (sv == null) {
            if (!is_suspended) try trace_frames.stacktraceExt(task.fiber, res, "");
        } else if (sig == .ok or task.fiber.flags.traps.has(sig)) {
            const chan = channel.unwrap(sv);
            const event = channel.makeSupervisorEvent(
                utils.signalNames[@intFromEnum(sig)],
                task.fiber,
                chan.is_threaded,
            );
            // Mode 2 does not block and the only raise it can make is on a
            // closed channel, which is what a program sees.
            _ = try channel.push(chan, event, .detached);
        } else if (!is_suspended) {
            try trace_frames.stacktraceExt(task.fiber, res, "");
        }
        if (sig == abi.Signal.interrupt) return task.fiber;
    }

    // Poll for events.
    if (sched.tq.items.len != 0 or abstracts.atomicLoad(&sched.listener_count) != 0) {
        var next: Timeout = std.mem.zeroes(Timeout);
        var has_timeout = false;
        // Drop timeouts that are no longer needed.
        while (true) {
            next = peekTimeout() orelse {
                has_timeout = false;
                break;
            };
            has_timeout = true;
            if (next.curr_fiber) |curr| {
                if (!fibers.canResume(curr)) {
                    popTimeout(0);
                    _ = tables.remove(&sched.active_tasks, wrap.fromFiber(curr));
                    handleTimeoutWorker(next, true);
                    continue;
                }
            } else if (next.fiber.?.sched_id != next.sched_id) {
                popTimeout(0);
                handleTimeoutWorker(next, true);
                continue;
            }
            break;
        }
        if (sched.tq.items.len != 0 or abstracts.atomicLoad(&sched.listener_count) != 0) {
            try backend.loop1(has_timeout, next.when);
        }
    }

    return null;
}

pub fn loop() raise.Raising(void) {
    while (!loopDone()) {
        if (try loop1()) |interrupted| schedule(interrupted, wrap.fromNil());
    }
}

// ==========================================================================
// Posting an event from another thread, and threaded calls
// ==========================================================================

/// What a thread writes down the self-pipe to wake the loop, and the head of
/// `ThreadInit` below.
pub const SelfPipeEvent = extern struct {
    msg: GenericMessage,
    cb: ThreadedCallback,
};

/// What a threaded subroutine is started with. Its first two fields are
/// `SelfPipeEvent`'s, deliberately: the thread reuses this allocation as the
/// reply it writes back down the pipe, so the reply is read out of the head of
/// a block that was a `ThreadInit`.
const ThreadInit = extern struct {
    msg: GenericMessage,
    cb: ThreadedCallback,
    subr: ThreadedSubroutine,
    write_pipe: host.Handle,
};

comptime {
    // **This is why both are `extern`**, and it is the whole reason: a prefix
    // pun between two types is a layout claim, and `layouts.txt` records the
    // pair as fixed with nothing but `repr` evidence to show for it. Stated
    // here, the claim is checked on every build and on every target instead.
    std.debug.assert(@offsetOf(ThreadInit, "msg") == @offsetOf(SelfPipeEvent, "msg"));
    std.debug.assert(@offsetOf(ThreadInit, "cb") == @offsetOf(SelfPipeEvent, "cb"));
    std.debug.assert(@sizeOf(ThreadInit) >= @sizeOf(SelfPipeEvent));
}

pub fn evPostEvent(
    target: ?*vm_state.Vm,
    cb: Callback,
    msg: GenericMessage,
) void {
    // The one scheduler operation that is not the current thread's: a thread
    // posting to another interpreter's loop names that interpreter's `VmEv`,
    // which is what "pass the narrower state" means where the state is not
    // ambient at all.
    const sched = &(target orelse vm_state.current()).ev;
    _ = abstracts.atomicInc(&sched.listener_count);
    if (windows) {
        const iocp: ?*anyopaque = @ptrCast(sched.backend.iocp);
        const event: *SelfPipeEvent = @ptrCast(@alignCast(utils.malloc(@sizeOf(SelfPipeEvent)) orelse
            outOfMemory(@src())));
        event.msg = msg;
        event.cb = cb;
        assert(@src(), c.PostQueuedCompletionStatus(
            iocp,
            @sizeOf(SelfPipeEvent),
            0,
            @ptrCast(event),
        ) != 0, "failed to post completion event");
    } else {
        var event = std.mem.zeroes(SelfPipeEvent);
        event.msg = msg;
        event.cb = cb;
        const fd = sched.backend.selfpipe[1];
        // Handle a bit of back pressure before giving up.
        var tries: i32 = 20;
        while (tries > 0) {
            const status = c.retryIntr(c.write, .{ fd, @as([*]const u8, @ptrCast(&event)), @sizeOf(SelfPipeEvent) });
            if (status > 0) break;
            _ = c.sleep(0);
            tries -= 1;
        }
        assert(@src(), tries > 0, "failed to write event to self-pipe");
    }
}

fn threadBodyPosix(ptr: ?*anyopaque) callconv(.c) ?*anyopaque {
    const init: *ThreadInit = @ptrCast(@alignCast(ptr));
    const msg = init.msg;
    const subr = init.subr;
    const cb = init.cb;
    const fd = init.write_pipe;
    utils.free(ptr);
    var response = std.mem.zeroes(SelfPipeEvent);
    response.msg = subr.?(msg);
    response.cb = cb;
    // Handle a bit of back pressure before giving up.
    var tries: i32 = 4;
    while (tries > 0) {
        const status = c.retryIntr(c.write, .{ fd, @as([*]const u8, @ptrCast(&response)), @sizeOf(SelfPipeEvent) });
        if (status > 0) break;
        _ = c.sleep(1);
        tries -= 1;
    }
    return null;
}

fn threadBodyWindows(ptr: ?*anyopaque) callconv(.winapi) u32 {
    const init: *ThreadInit = @ptrCast(@alignCast(ptr));
    const msg = init.msg;
    const subr = init.subr;
    const cb = init.cb;
    const iocp = init.write_pipe;
    // Reuse the memory from thread init for returning data.
    init.msg = subr.?(msg);
    init.cb = cb;
    assert(@src(), c.PostQueuedCompletionStatus(
        iocp,
        @sizeOf(SelfPipeEvent),
        0,
        @ptrCast(init),
    ) != 0, "failed to post completion event");
    return 0;
}

pub fn threadedCall(
    fp: ThreadedSubroutine,
    arguments: GenericMessage,
    cb: ThreadedCallback,
) raise.Raising(void) {
    const sched = &vm_state.current().ev;
    const init: *ThreadInit = @ptrCast(@alignCast(utils.malloc(@sizeOf(ThreadInit)) orelse
        outOfMemory(@src())));
    init.msg = arguments;
    init.subr = fp;
    init.cb = cb;

    if (windows) {
        init.write_pipe = iocpHandle();
        const thread_handle = c.CreateThread(null, 0, threadBodyWindows, init, 0, null);
        if (thread_handle == null) {
            utils.free(init);
            return raise.panic("failed to create thread");
        }
        _ = c.CloseHandle(thread_handle); // detach from thread
    } else {
        init.write_pipe = sched.backend.selfpipe[1];
        var waiter_thread: host.pthread_t = undefined;
        const err = c.pthread_create(&waiter_thread, &sched.backend.new_thread_attr, threadBodyPosix, init);
        if (err != 0) {
            utils.free(init);
            return pp_format.panicf("%s", .{utils.strerrorSafe(err)});
        }
    }

    // Increment ev refcount so we don't quit while waiting for a subprocess.
    evIncRefcount();
}

/// The default reply handler for a threaded call.
///
/// `ThreadedCallback` is `callconv(.c)`, so this cannot return an
/// error, and it runs off the self-pipe with no scope above it. `cancel`
/// raises only when the fiber it is handed is not cancellable, which the
/// `canResume` above has already established -- so a raise here means the
/// scheduler's view of the fiber and this one disagree, and the runtime is
/// already inconsistent. It aborts at the site.
pub fn evDefaultThreadedCallback(return_value: GenericMessage) callconv(.c) void {
    const fiber = return_value.fiber orelse {
        freeThreadedPayload(return_value);
        return;
    };
    if (fibers.canResume(fiber)) {
        switch (return_value.tag) {
            constants.JANET_EV_TCTAG_INTEGER => schedule(fiber, wrap.fromInteger(return_value.argi)),
            constants.JANET_EV_TCTAG_STRING, constants.JANET_EV_TCTAG_STRINGF => schedule(
                fiber,
                value.fromBytes(std.mem.span(payloadText(return_value)), .string),
            ),
            constants.JANET_EV_TCTAG_KEYWORD => schedule(
                fiber,
                value.fromBytes(std.mem.span(payloadText(return_value)), .keyword),
            ),
            constants.JANET_EV_TCTAG_ERR_STRING, constants.JANET_EV_TCTAG_ERR_STRINGF => raise.total(cancel(
                fiber,
                value.fromBytes(std.mem.span(payloadText(return_value)), .string),
            ), "a threaded call's error reply"),
            constants.JANET_EV_TCTAG_ERR_KEYWORD => raise.total(cancel(
                fiber,
                value.fromBytes(std.mem.span(payloadText(return_value)), .keyword),
            ), "a threaded call's error reply"),
            constants.JANET_EV_TCTAG_BOOLEAN => schedule(
                fiber,
                wrap.fromBoolean(return_value.argi != 0),
            ),
            // JANET_EV_TCTAG_NIL, and every tag the C switch sends to
            // `default`, which is the same arm.
            else => schedule(fiber, wrap.fromNil()),
        }
    }
    freeThreadedPayload(return_value);
    _ = gc_alloc.gcunroot(wrap.fromFiber(fiber));
}

inline fn payloadText(return_value: GenericMessage) [*:0]const u8 {
    return @ptrCast(return_value.argp);
}

/// Release the reply payload, **for the two tags that own one and no others**.
///
/// `*_STRINGF` is the "string, freed" tag: the subroutine allocated the bytes
/// and the callback releases them. Every other tag either carries no payload
/// or points at something that is not the callback's -- the plain error-string
/// tag points at
/// a string literal, and a tag that carries no payload at all can still be
/// carrying the *request* pointer the subroutine has already released.
///
/// Freeing for every tag is what makes `(os/shell "cmd")` abort the process
/// and `ev/thread`'s start failure free `"failed to start thread"`.
inline fn freeThreadedPayload(return_value: GenericMessage) void {
    switch (return_value.tag) {
        constants.JANET_EV_TCTAG_STRINGF,
        constants.JANET_EV_TCTAG_ERR_STRINGF,
        => utils.free(return_value.argp),
        else => {},
    }
}

pub fn threadedAwait(fp: ThreadedSubroutine, tag: c_int, argi: c_int, argp: ?*anyopaque) raise.Error {
    var arguments = std.mem.zeroes(GenericMessage);
    arguments.tag = tag;
    arguments.argi = argi;
    arguments.argp = argp;
    arguments.fiber = fibers.root();
    gc_alloc.gcroot(wrap.fromFiber(arguments.fiber.?));
    threadedCall(fp, arguments, evDefaultThreadedCallback) catch |err| return err;
    return awaitEvent();
}

// ==========================================================================
// The host calls this file makes directly
// ==========================================================================
//
// Declared here rather than translated, on the tree's standing rule: each
// takes primitive parameters or a type `host.zig` already supplies, so no host
// layout is at stake and no further translation is needed. `pthread_t` and
// `pthread_attr_t` are `host.zig`'s, which takes them from libc because `Vm`
// and `Timeout` embed both.

/// `PTHREAD_CREATE_DETACHED` is 2 on both glibc and musl and 2 on Darwin.
const PTHREAD_CREATE_DETACHED: c_int = 2;
const SIGUSR1: c_int = 30;
pub const EAGAIN: c_int = @intFromEnum(std.c.E.AGAIN);
/// `EWOULDBLOCK` and `EAGAIN` are the same number on every platform in this
/// project's reach, and Darwin's `std.E` does not name the first at all.
pub const EWOULDBLOCK: c_int = if (@hasField(std.c.E, "WOULDBLOCK"))
    @intFromEnum(@field(std.c.E, "WOULDBLOCK"))
else
    EAGAIN;
pub const EPIPE: c_int = @intFromEnum(std.c.E.PIPE);
pub const EPERM: c_int = @intFromEnum(std.c.E.PERM);

pub const INFINITE: u32 = 0xFFFFFFFF;
const WAIT_TIMEOUT: u32 = 0x102;

/// The backend's `iocp` field is `?[*]?*anyopaque`, a pointer *to* the handle,
/// where every Windows call wants the handle itself.
pub inline fn iocpHandle() ?*anyopaque {
    return @ptrCast(vm_state.current().ev.backend.iocp);
}

const CREATE_SUSPENDED: u32 = 0x4;

// ==========================================================================
// `ev/thread`'s child interpreter
// ==========================================================================

/// The supervisor bit. Above the four flag letters `ev/thread`
/// accepts, so that it can be added to the same word.
const thread_supervisor_flag: u32 = 0x100;

/// What the protected body needs from `goThreadSubr`, and what it reports
/// back. It is a structure because `args` is an in-out parameter and the other
/// three are read together.
const GoThreadContext = struct {
    args: GenericMessage,
    flags: u32,
    next: [*]const u8,
    end: [*]const u8,
};

/// The protected scope `ev/thread`'s child interpreter runs under.
///
/// `signal.tryInit` opens the scope -- it is what points `return_reg` at
/// `tstate.payload`, and therefore what `signal.plan` reads to answer `.raise`
/// rather than `.top_level` -- and `signal.restore` closes it. The body is
/// called directly and a returned error carries the raise back here.
///
/// A report left by an abi inside the body is consumed at its own call site by
/// `raise.crossing`; one that is not is what the assertion in `signal.restore`
/// exists to name.
fn goThreadProtect(ctx: *GoThreadContext, payload: *repr.Value) abi.Signal {
    var tstate: vm_state.TryState = undefined;
    signal_core.tryInit(&tstate);
    var signal: abi.Signal = .ok;
    goThreadBody(ctx) catch {
        signal = vm_state.current().pending_signal;
    };
    signal_core.restore(&tstate);
    if (signal != .ok) payload.* = tstate.payload;
    return signal;
}

/// The body `goThreadProtect` runs between `signal_core.tryInit` and
/// `signal_core.restore`.
fn goThreadBody(ctx: *GoThreadContext) raise.Raising(void) {
    const v = vm_state.current();
    const flags = ctx.flags;

    // Set abstract registry.
    if (flags & 0x2 == 0) {
        const aregv = try marsh.unmarshal(
            ctx.next[0 .. @intFromPtr(ctx.end) - @intFromPtr(ctx.next)],
            constants.JANET_MARSHAL_UNSAFE,
            null,
            @ptrCast(&ctx.next),
        );
        assert(@src(), repr.checkType(aregv, repr.Tag.table), "expected table for abstract registry");
        v.abstract_registry = wrap.toTable(aregv);
        gc_alloc.gcroot(wrap.fromTable(v.abstract_registry.?));
    }

    // Get supervisor.
    if (flags & thread_supervisor_flag != 0) {
        const sup = try marsh.unmarshal(
            ctx.next[0 .. @intFromPtr(ctx.end) - @intFromPtr(ctx.next)],
            constants.JANET_MARSHAL_UNSAFE,
            null,
            @ptrCast(&ctx.next),
        );
        // The VM's `user` field is where the failure arm reads the supervisor
        // from, and that arm still runs after a raise, so it is set here
        // rather than left to the path that raised.
        v.user = wrap.toPointer(sup);
    }

    // Set cfunction registry.
    if (flags & 0x4 == 0) {
        var count1: u32 = undefined;
        @memcpy(std.mem.asBytes(&count1), ctx.next[0..@sizeOf(u32)]);
        const count: usize = count1;
        const remaining = @intFromPtr(ctx.end) - @intFromPtr(ctx.next) - @sizeOf(u32);
        // Use division to avoid overflowing size_t.
        assert(@src(), count <= remaining / @sizeOf(registry.Row), "thread message invalid");
        v.registry.rows = std.ArrayListUnmanaged(registry.Row)
            .initCapacity(utils.heap, count) catch outOfMemory(@src());
        v.registry.rows.items.len = count;
        v.registry.dirty = true;
        ctx.next += @sizeOf(u32);
        @memcpy(
            std.mem.sliceAsBytes(v.registry.rows.items),
            ctx.next[0 .. count * @sizeOf(registry.Row)],
        );
        ctx.next += count * @sizeOf(registry.Row);
    }

    const fiberv = try marsh.unmarshal(
        ctx.next[0 .. @intFromPtr(ctx.end) - @intFromPtr(ctx.next)],
        constants.JANET_MARSHAL_UNSAFE,
        null,
        @ptrCast(&ctx.next),
    );
    const val = try marsh.unmarshal(
        ctx.next[0 .. @intFromPtr(ctx.end) - @intFromPtr(ctx.next)],
        constants.JANET_MARSHAL_UNSAFE,
        null,
        @ptrCast(&ctx.next),
    );

    var fiber: *fibers.Fiber = undefined;
    if (!repr.checkType(fiberv, repr.Tag.fiber)) {
        assert(@src(), repr.checkType(fiberv, repr.Tag.function), "expected function or fiber");
        const func = wrap.toFunction(fiberv);
        // An assert rather than a panic: an ordinary panic here misbehaves
        // under Wine and mingw.
        assert(
            @src(),
            func.def.?.min_arity >= 0 and func.def.?.min_arity <= 1,
            "thread function must accept 0 or 1 arguments",
        );
        var seed = val;
        // The arity was checked just above, so the slice is exactly the length
        // the callee accepts and the refusal cannot happen.
        fiber = fibers.new(func, 64, @as([*]const repr.Value, @ptrCast(&seed))[0..@intCast(func.def.?.min_arity)]) catch
            exitWith(@src(), "bad fiber in thread setup");
        fiber.flags.traps = signal_core.SignalSet.fromBits(fiber.flags.traps.bits() |
            signal_core.SignalSet.of(&.{ .@"error", .user0, .user1, .user2, .user3, .user4 }).bits());
    } else {
        fiber = wrap.toFiber(fiberv);
    }
    if (flags & 0x8 != 0) {
        if (fiber.env == null) fiber.env = tables.new(0);
        // The line above installs a table when there is none, so there is one.
        tables.put(fiber.env orelse unreachable, value.fromBytes("task-id", .keyword), val);
    }
    fiber.supervisor_channel = v.user;
    schedule(fiber, val);
    // The raise is returned rather than flattened: this function is
    // `raise.Raising`, and a report nobody here consumes is exactly what
    // `tools/check/swallowed.janet` finds.
    try loop();
    ctx.args.tag = constants.JANET_EV_TCTAG_NIL;
}

/// The subroutine a new `ev/thread` runs on its own operating system thread:
/// a whole interpreter, from `vm/lifecycle.zig`'s `init` to its `deinit`.
fn goThreadSubr(args_in: GenericMessage) callconv(.c) GenericMessage {
    var args = args_in;
    const buffer: *buffers.Buffer = @ptrCast(@alignCast(args.argp));
    const flags: u32 = @bitCast(args.tag);
    args.tag = 0;
    args.argp = null;
    // A thread subroutine's type is the event loop's, and this runs at the
    // very top of a new thread: there is no scope above it and no caller that
    // could act on a failure to initialise a VM.
    _ = raise.total(vm_lifecycle.init(), "a thread subroutine's VM init");
    vm_state.current().sandbox_flags = @bitCast(args.argi);

    var ctx: GoThreadContext = .{
        .args = args,
        .flags = flags,
        .next = buffer.data.?,
        .end = buffer.data.? + @as(usize, @intCast(buffer.count)),
    };
    var payload: repr.Value = wrap.fromNil();
    const signal = goThreadProtect(&ctx, &payload);
    args = ctx.args;

    if (signal != .ok) {
        const supervisor = vm_state.current().user;
        if (supervisor != null) {
            // Got a supervisor, write the error there.
            const pair = [2]repr.Value{ value.fromBytes("error", .keyword), payload };
            // Reporting the thread's own start failure to its supervisor.
            // A raise here has nowhere left to go -- this *is* the error path.
            _ = raise.total(channel.push(
                channel.unwrap(supervisor),
                wrap.fromTuple(tuples.newFrom(&pair)),
                .detached,
            ), "a thread subroutine's supervisor report");
        } else if (flags & 0x1 != 0) {
            // No wait, just print to stderr.
            eprintf("thread start failure: %v\n", .{payload});
        } else {
            // Make the ev/thread call from the parent thread error.
            if (repr.checkType(payload, repr.Tag.string)) {
                args.tag = constants.JANET_EV_TCTAG_ERR_STRINGF;
                const msg = wrap.toString(payload);
                const len: usize = strings.head(msg).length;
                args.argp = utils.malloc(len + 1);
                @memcpy(@as([*]u8, @ptrCast(args.argp))[0 .. len + 1], msg[0 .. len + 1]);
            } else {
                args.tag = constants.JANET_EV_TCTAG_ERR_STRING;
                args.argp = @ptrCast(@constCast("failed to start thread"));
            }
        }
    }

    buffers.deinit(buffer);
    utils.free(buffer);
    vm_lifecycle.deinit();
    return args;
}

// ==========================================================================
// The scheduler's cfunctions
// ==========================================================================

fn cfunGo(argv: []repr.Value) raise.Raising(repr.Value) {
    try args_core.arity(argv, 1, 3);
    const val = if (argv.len >= 2) argv[1] else wrap.fromNil();
    const supervisor = try args_core.optAbstract(
        argv,
        2,
        &channel.channelType,
        vm_state.current().root_fiber.?.supervisor_channel,
    );
    var fiber: ?*fibers.Fiber = undefined;
    if (repr.checkType(argv[0], repr.Tag.function)) {
        // Create a fiber for the user.
        const func = wrap.toFunction(argv[0]);
        if (func.def.?.min_arity > 1) {
            return pp_format.panicf("task function must accept 0 or 1 arguments", .{});
        }
        var seed = val;
        // As above: the slice is `min_arity` long by construction.
        fiber = fibers.new(func, 64, @as([*]const repr.Value, @ptrCast(&seed))[0..@intCast(func.def.?.min_arity)]) catch unreachable;
        fiber.?.flags.traps = signal_core.SignalSet.fromBits(fiber.?.flags.traps.bits() |
            signal_core.SignalSet.of(&.{ .@"error", .user0, .user1, .user2, .user3, .user4 }).bits());
        if (vm_state.current().fiber.?.env == null) vm_state.current().fiber.?.env = tables.new(0);
        const env = tables.new(0);
        fiber.?.env = env;
        env.proto = vm_state.current().fiber.?.env;
    } else {
        fiber = try args_core.getFiber(argv, 0);
        if (fibers.status(fiber.?) != fibers.FiberStatus.new) {
            return raise.panic("can only schedule new fibers where (= (fiber/status f) :new)");
        }
    }
    fiber.?.supervisor_channel = supervisor;
    schedule(fiber.?, val);
    return wrap.fromFiber(fiber.?);
}

fn cfunThread(argv: []repr.Value) raise.Raising(repr.Value) {
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"threads"}));
    try args_core.arity(argv, 1, 4);
    const val = if (argv.len >= 2) argv[1] else wrap.fromNil();
    if (repr.checkType(argv[0], repr.Tag.function)) {
        const func = try args_core.getFunction(argv, 0);
        if (func.def.?.arity < 0 or func.def.?.min_arity > 1) {
            return raise.panic("function must take 0 or 1 arguments");
        }
    } else {
        _ = try args_core.getFiber(argv, 0); // arg check for fiber
    }
    var flags: u64 = 0;
    if (argv.len >= 3) flags = try args_core.getFlags(argv, 2, "nact");
    const supervisor = try args_core.optAbstract(
        argv,
        3,
        &channel.channelType,
        vm_state.current().root_fiber.?.supervisor_channel,
    );
    if (supervisor != null) flags |= thread_supervisor_flag;

    // Marshal arguments for the new thread.
    const buffer: *buffers.Buffer = @ptrCast(@alignCast(utils.malloc(@sizeOf(buffers.Buffer)) orelse
        outOfMemory(@src())));
    _ = buffers.init(buffer, 0);
    if (flags & 0x2 == 0) {
        try marsh.marshal(buffer, wrap.fromTable(vm_state.current().abstract_registry.?), null, constants.JANET_MARSHAL_UNSAFE);
    }
    if (flags & thread_supervisor_flag != 0) {
        try marsh.marshal(buffer, wrap.fromAbstract(supervisor), null, constants.JANET_MARSHAL_UNSAFE);
    }
    if (flags & 0x4 == 0) {
        assert(@src(), vm_state.current().registry.rows.items.len <= std.math.maxInt(i32), "assert failed size check");
        const temp: u32 = @intCast(vm_state.current().registry.rows.items.len);
        _ = try buffers.pushBytes(buffer, std.mem.asBytes(&temp));
        _ = try buffers.pushBytes(
            buffer,
            std.mem.sliceAsBytes(vm_state.current().registry.rows.items),
        );
    }
    try marsh.marshal(buffer, argv[0], null, constants.JANET_MARSHAL_UNSAFE);
    try marsh.marshal(buffer, val, null, constants.JANET_MARSHAL_UNSAFE);

    if (flags & 0x1 != 0) {
        // Return immediately.
        var arguments = std.mem.zeroes(GenericMessage);
        arguments.tag = @bitCast(@as(u32, @truncate(flags)));
        arguments.argi = @bitCast(vm_state.current().sandbox_flags);
        arguments.argp = buffer;
        arguments.fiber = null;
        try threadedCall(goThreadSubr, arguments, evDefaultThreadedCallback);
        return wrap.fromNil();
    }
    return threadedAwait(
        goThreadSubr,
        @bitCast(@as(u32, @truncate(flags))),
        @bitCast(vm_state.current().sandbox_flags),
        buffer,
    );
}

fn cfunGiveSupervisor(argv: []repr.Value) raise.Raising(repr.Value) {
    try args_core.arity(argv, 1, -1);
    const chanv = vm_state.current().root_fiber.?.supervisor_channel;
    if (chanv != null) {
        const chan = channel.unwrap(chanv);
        if (try channel.push(chan, wrap.fromTuple(tuples.newFrom(argv)), .plain)) {
            return awaitEvent();
        }
    }
    return wrap.fromNil();
}

fn cfunSleep(argv: []repr.Value) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    const sec = try args_core.getNumber(argv, 0);
    return sleepAwait(sec);
}

fn cfunDeadline(argv: []repr.Value) raise.Raising(repr.Value) {
    try args_core.arity(argv, 1, 4);
    var sec = try args_core.getNumber(argv, 0);
    if (sec < 0) sec = 0;
    const tocancel = try args_core.optFiber(argv, 1, vm_state.current().root_fiber);
    const tocheck = try args_core.optFiber(argv, 2, vm_state.current().fiber);
    const use_interrupt = try args_core.optBoolean(argv, 3, false);
    var to: Timeout = .{
        .when = ev_core.tsDelta(tsNow(), sec),
        .fiber = tocancel,
        .curr_fiber = tocheck,
        .is_error = false,
        .sched_id = tocancel.?.sched_id,
        .has_worker = false,
        .worker = std.mem.zeroes(@FieldType(Timeout, "worker")),
    };
    if (use_interrupt) {
        if (!has_interrupt) {
            // The interpreter's half of this is compiled out, so a timer
            // thread would raise auto_suspend at a VM that never reads it and
            // a fiber that does not yield would run forever. Refuse the same
            // way os/sigaction does, before anything is allocated or started.
            return raise.panic("interpreter interrupt not enabled");
        }
        if (android) try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"signal"}));
        const tto: *ThreadedTimeout = @ptrCast(@alignCast(utils.malloc(@sizeOf(ThreadedTimeout)) orelse
            outOfMemory(@src())));
        tto.sec = sec;
        tto.vm_ptr = vm_state.current();
        tto.fiber = tocheck.?;
        if (windows) {
            const cancel_event = c.CreateEventA(null, 1, 0, null);
            if (cancel_event == null) {
                utils.free(tto);
                return raise.panic("failed to create cancel event");
            }
            tto.cancel_event = cancel_event;
            const worker = c.CreateThread(null, 0, timeoutBodyWindows, tto, CREATE_SUSPENDED, null);
            if (worker == null) {
                utils.free(tto);
                return raise.panic("failed to create thread");
            }
            to.has_worker = true;
            to.worker = worker;
            to.worker_event = cancel_event;
            _ = c.ResumeThread(worker);
        } else {
            var worker: host.pthread_t = undefined;
            const err = c.pthread_create(&worker, null, timeoutBodyPosix, tto);
            if (err != 0) {
                utils.free(tto);
                return pp_format.panicf("%s", .{utils.strerrorSafe(err)});
            }
            to.has_worker = true;
            to.worker = worker;
        }
    }
    addTimeout(to);
    return wrap.fromFiber(tocancel.?);
}

fn cfunCancel(argv: []repr.Value) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 2);
    const fiber = try args_core.getFiber(argv, 0);
    try cancel(fiber, argv[1]);
    return argv[0];
}

fn cfunAllTasks(argv: []repr.Value) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 0);

    const sched = &vm_state.current().ev;
    const array = arrays.new(@intCast(sched.active_tasks.count));
    for (0..sched.active_tasks.capacity) |i| {
        const key = sched.active_tasks.slots()[i].key;
        if (!repr.checkType(key, repr.Tag.nil)) try arrays.push(array, key);
    }
    return wrap.fromArray(array);
}

// ==========================================================================
// The two lock types
// ==========================================================================

fn mutexGC(mutex: *anyopaque, _: usize) void {
    os_locks.mutexDeinit(mutex);
}

pub const mutexType = abstract_type.define(anyopaque, .{
    .name = "core/lock",
    .gc = mutexGC,
});

fn rwlockGC(rwlock: *anyopaque, _: usize) void {
    os_locks.rwlockDeinit(rwlock);
}

pub const rwlockType = abstract_type.define(anyopaque, .{
    .name = "core/rwlock",
    .gc = rwlockGC,
});

fn cfunMutex(argv: []repr.Value) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 0);

    const mutex = abstracts.threaded(&mutexType, os_locks.mutexSize());
    os_locks.mutexInit(@ptrCast(mutex));
    return wrap.fromAbstract(mutex);
}

fn cfunMutexAcquire(argv: []repr.Value) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    const mutex = try args_core.getAbstract(anyopaque, argv, 0, &mutexType);
    os_locks.mutexLock(@ptrCast(mutex));
    return argv[0];
}

fn cfunMutexRelease(argv: []repr.Value) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    const mutex = try args_core.getAbstract(anyopaque, argv, 0, &mutexType);
    try os_locks.mutexUnlock(@ptrCast(mutex));
    return argv[0];
}

fn cfunRwlock(argv: []repr.Value) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 0);

    const rwlock = abstracts.threaded(&rwlockType, os_locks.rwlockSize());
    os_locks.rwlockInit(@ptrCast(rwlock));
    return wrap.fromAbstract(rwlock);
}

fn cfunRwlockReadLock(argv: []repr.Value) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    const rwlock = try args_core.getAbstract(anyopaque, argv, 0, &rwlockType);
    os_locks.rwlockRlock(@ptrCast(rwlock));
    return argv[0];
}

fn cfunRwlockWriteLock(argv: []repr.Value) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    const rwlock = try args_core.getAbstract(anyopaque, argv, 0, &rwlockType);
    os_locks.rwlockWlock(@ptrCast(rwlock));
    return argv[0];
}

fn cfunRwlockReadRelease(argv: []repr.Value) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    const rwlock = try args_core.getAbstract(anyopaque, argv, 0, &rwlockType);
    os_locks.rwlockRunlock(@ptrCast(rwlock));
    return argv[0];
}

fn cfunRwlockWriteRelease(argv: []repr.Value) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    const rwlock = try args_core.getAbstract(anyopaque, argv, 0, &rwlockType);
    os_locks.rwlockWunlock(@ptrCast(rwlock));
    return argv[0];
}

// ==========================================================================
// Registration
// ==========================================================================

// `channel.channelType` and `stream.streamType` are reached by import, and
// each use site names the module.
//
// **Not through a local alias.** `const stream_type = stream.streamType;`
// compiles and is wrong: an alias of a `const` is a *copy* of the value, so
// `&stream_type` is the address of this file's copy, and an abstract built
// through it is not the type `getAbstract` compares against.

fn selfEntries() []const corefn.Entry {
    const list = comptime blk: {
        var acc: []const corefn.Entry = &.{};
        acc = acc ++ [_]corefn.Entry{
            corefn.reg("ev/go", &cfunGo, @src(), "(ev/go fiber-or-fun &opt value supervisor)", "Put a fiber on the event loop to be resumed later. If a " ++
                "function is used, it is wrapped with `fiber/new` first. " ++
                "Returns a task fiber. Optionally pass a value to resume " ++
                "with, otherwise resumes with nil. An optional `core/channel` " ++
                "can be provided as a supervisor. When various events occur " ++
                "in the newly scheduled fiber, an event will be pushed to the " ++
                "supervisor. If not provided, the new fiber will inherit the " ++
                "current supervisor."),
            corefn.reg("ev/thread", &cfunThread, @src(), "(ev/thread main &opt value flags supervisor)", "Run `main` in a new operating system thread, optionally passing `value` " ++
                "to resume with. The parameter `main` can either be a fiber, or a function that accepts " ++
                "0 or 1 arguments. " ++
                "Unlike `ev/go`, this function will suspend the current fiber until the thread is complete. " ++
                "If you want to run the thread without waiting for a result, pass the `:n` flag to return nil immediately. " ++
                "Otherwise, returns nil. Available flags:\n\n" ++
                "* `:n` - return immediately\n" ++
                "* `:t` - set the task-id of the new thread to value. The task-id is passed in messages to the supervisor channel.\n" ++
                "* `:a` - don't copy abstract registry to new thread (performance optimization)\n" ++
                "* `:c` - don't copy cfunction registry to new thread (performance optimization)"),
            corefn.reg("ev/give-supervisor", &cfunGiveSupervisor, @src(), "(ev/give-supervisor tag & payload)", "Send a message to the current supervisor channel if there is one. The message will be a " ++
                "tuple of all of the arguments combined into a single message, where the first element is tag. " ++
                "By convention, tag should be a keyword indicating the type of message. Returns nil."),
            corefn.reg("ev/sleep", &cfunSleep, @src(), "(ev/sleep sec)", "Suspend the current fiber for sec seconds without blocking the event loop."),
            corefn.reg("ev/deadline", &cfunDeadline, @src(), "(ev/deadline sec &opt tocancel tocheck intr?)", "Schedules the event loop to try to cancel the `tocancel` task as with `ev/cancel`. " ++
                "After `sec` seconds, the event loop will attempt cancellation of `tocancel` if the " ++
                "`tocheck` fiber is resumable. `sec` is a number that can have a fractional part. " ++
                "`tocancel` defaults to `(fiber/root)`, but if specified, must be a task (root " ++
                "fiber). `tocheck` defaults to `(fiber/current)`, but if specified, must be a fiber. " ++
                "Returns `tocancel` immediately. If `interrupt?` is set to true, will create a " ++
                "background thread to try to interrupt the VM if the timeout expires."),
            corefn.reg("ev/cancel", &cfunCancel, @src(), "(ev/cancel fiber err)", "Cancel a suspended task fiber in the event loop. Differs from " ++
                "`cancel` in that it returns the canceled fiber immediately."),
        };
        break :blk acc;
    };
    return list;
}

fn lockEntries() []const corefn.Entry {
    const list = comptime blk: {
        var acc: []const corefn.Entry = &.{};
        acc = acc ++ [_]corefn.Entry{
            corefn.reg("ev/lock", &cfunMutex, @src(), "(ev/lock)", "Create a new lock to coordinate threads."),
            corefn.reg("ev/acquire-lock", &cfunMutexAcquire, @src(), "(ev/acquire-lock lock)", "Acquire a lock such that this operating system thread is the only thread with access to this resource." ++
                " This will block this entire thread until the lock becomes available, and will not yield to other fibers " ++
                "on this system thread."),
            corefn.reg("ev/release-lock", &cfunMutexRelease, @src(), "(ev/release-lock lock)", "Release a lock such that other threads may acquire it."),
            corefn.reg("ev/rwlock", &cfunRwlock, @src(), "(ev/rwlock)", "Create a new read-write lock to coordinate threads."),
            corefn.reg("ev/acquire-rlock", &cfunRwlockReadLock, @src(), "(ev/acquire-rlock rwlock)", "Acquire a read lock an a read-write lock."),
            corefn.reg("ev/acquire-wlock", &cfunRwlockWriteLock, @src(), "(ev/acquire-wlock rwlock)", "Acquire a write lock on a read-write lock."),
            corefn.reg("ev/release-rlock", &cfunRwlockReadRelease, @src(), "(ev/release-rlock rwlock)", "Release a read lock on a read-write lock"),
            corefn.reg("ev/release-wlock", &cfunRwlockWriteRelease, @src(), "(ev/release-wlock rwlock)", "Release a write lock on a read-write lock"),
        };
        break :blk acc;
    };
    return list;
}

fn tailEntries() []const corefn.Entry {
    const list = comptime blk: {
        var acc: []const corefn.Entry = &.{};
        acc = acc ++ [_]corefn.Entry{
            corefn.reg("ev/all-tasks", &cfunAllTasks, @src(), "(ev/all-tasks)", "Get an array of all active task fibers that are being used by the scheduler."),
        };
        break :blk acc;
    };
    return list;
}

/// Install the `ev/` bindings. The six groups go in upstream Janet's own
/// registration order: the ten channel rows, the six scheduler rows, the four
/// stream rows, the eight lock rows, `ev/to-file` and `ev/all-tasks`.
pub fn libEv(env: *tables.Table) raise.Raising(void) {
    var table: [64]corefn.Entry = undefined;
    var n: usize = 0;
    const push = struct {
        fn f(dest: []corefn.Entry, count: *usize, rows: []const corefn.Entry) void {
            @memcpy(dest[count.* .. count.* + rows.len], rows);
            count.* += rows.len;
        }
    }.f;

    push(&table, &n, channel.entries());
    push(&table, &n, selfEntries());
    push(&table, &n, stream.entries());
    push(&table, &n, lockEntries());
    push(&table, &n, stream.toFileEntries());
    push(&table, &n, tailEntries());
    table[n] = corefn.end;
    corefn.installTerminated(env, &table);

    try registry.registerAbstractType(&stream.streamType);
    try registry.registerAbstractType(&channel.channelType);
    try registry.registerAbstractType(&mutexType);
    try registry.registerAbstractType(&rwlockType);
}

// -------------------------------------------------------------------------
// Suspension and resumption.
// -------------------------------------------------------------------------

/// The most entries a generic queue may hold.
const max_queue_capacity: i32 = 0x7FFFFFF;

/// The shortest kqueue timer interval this build will ask for. NetBSD rejects
/// intervals below a millisecond; every other kqueue platform accepts zero.
const kqueue_min_interval: i64 = 0;

const nanoseconds_per_millisecond: i64 = 1000000;
const milliseconds_per_second: i64 = 1000;

// ---------------------------------------------------------------------------
// Generic queue
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Timeout min-heap ordering
// ---------------------------------------------------------------------------

// The two kernels below take the heap as a slice of `Timeout` and read `when`
// as a field. There is exactly one heap and one element type, and the slice
// carries its own length, so no base pointer, stride, field offset or live
// count has to be passed alongside it.

/// One step of sifting down: report the child that should take `index`'s place,
/// or -1 when the heap property already holds there.
///
/// The slice is the *live* part of the heap. A child past its end is invisible,
/// which is what makes `popTimeout`'s shrink safe.
///
/// The left child is preferred on a tie, which is what the C implementation's
/// strict `<` comparisons produce.
pub fn heapSiftDown(heap: []const Timeout, index: usize) isize {
    const left = (index << 1) + 1;
    const right = left + 1;
    var smallest = index;
    if (left < heap.len and heap[left].when < heap[smallest].when) {
        smallest = left;
    }
    if (right < heap.len and heap[right].when < heap[smallest].when) {
        smallest = right;
    }
    return if (smallest == index) -1 else @intCast(smallest);
}

/// One step of sifting up: report the parent that should take `index`'s place,
/// or -1 when the heap property already holds there.
pub fn heapSiftUp(heap: []const Timeout, index: usize) isize {
    if (index == 0) return -1;
    const parent = (index - 1) >> 1;
    if (heap[parent].when <= heap[index].when) return -1;
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
/// and `os/touch` do; this saturates for the same reason and with the same
/// result on the development target.
pub fn tsDelta(ts: i64, delta: f64) i64 {
    if (std.math.isInf(delta)) {
        return if (delta < 0) ts else std.math.maxInt(i64);
    }
    return ts +% saturatingCast(i64, @round(delta * 1000));
}

/// Convert a clock reading into Janet's millisecond timestamp.
///
/// The epoll, kqueue and poll backends each need this after reading the clock.
/// It is arithmetic rather than a clock reading, so it is shared here while
/// `os.zig`'s `gettime` stays behind `-Dos-time`.
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

/// Convert toward zero, clamping instead of trapping: a NaN becomes zero and an
/// out-of-range value becomes the nearest bound. `os.zig` carries the same
/// helper for the same reason.
fn saturatingCast(comptime T: type, x: f64) T {
    if (std.math.isNan(x)) return 0;
    const low: f64 = @floatFromInt(@as(T, std.math.minInt(T)));
    const high: f64 = @floatFromInt(@as(T, std.math.maxInt(T)));
    if (!(x > low)) return std.math.minInt(T);
    if (x >= high) return std.math.maxInt(T);
    return @intFromFloat(x);
}

test "queue counts across a wrap" {
    var q: Queue(i32) = undefined;
    q.init();
    defer q.deinit();
    try std.testing.expectEqual(@as(i32, 0), q.count());
}

test "saturating conversion clamps rather than trapping" {
    try std.testing.expectEqual(@as(i64, 0), saturatingCast(i64, std.math.nan(f64)));
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), saturatingCast(i64, 1e300));
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), saturatingCast(i64, -1e300));
}

pub const Callback = ?*const fn (return_value: GenericMessage) callconv(.c) void;

pub const GenericMessage = extern struct {
    tag: c_int = 0,
    argi: c_int = 0,
    argp: ?*anyopaque = null,
    argj: repr.Value = std.mem.zeroes(repr.Value),
    fiber: ?*fibers.Fiber = null,
};

pub const EVCallback = ?*const fn (fiber: *fibers.Fiber, event: AsyncEvent) callconv(.c) void;
pub const AsyncEvent = constants.AsyncEvent;
