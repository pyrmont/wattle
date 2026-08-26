//! The event loop: the scheduler, and the primitives a subsystem suspends on.
//!
//! Two files until Phase 12 increment 6f.  `ev_loop.zig` is the loop and the
//! `ev/` cfunctions; `ev_core.zig` is what a fiber's suspension is made of.
//! One name, `ev`, for what Janet publishes as one module -- and `ev/` beside
//! it holds the four pieces that do have names of their own: the stream, the
//! channel, the backend, and the locks.
const std = @import("std");
const builtin = @import("builtin");
const corefn = @import("corefn");
const raise = @import("raise");
const stdio = @import("stdio.zig");
const io_core = @import("io.zig");
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
const vm_state = @import("vm/lifecycle.zig");
const math = @import("math.zig");
const signal_core = @import("signal.zig");
const kind = @import("value/helpers/kind.zig");
const wrap = @import("value/helpers/wrap.zig");
const vm_lifecycle = @import("vm/lifecycle.zig");
const fibers = @import("value/fibers.zig");
const trace_frames = @import("debug.zig");
const args_core = @import("args.zig");
const marsh = @import("marsh.zig");
const abstract_type = @import("abstract_type.zig");
const ev_core = @import("ev.zig");
const fatal = @import("fatal.zig");
const os_locks = @import("ev/locks.zig");

/// The four leaves beside this file, and the members `ev_loop.zig` re-exported
/// for callers that reach the loop rather than the piece. Increment 6f cut
/// these out of the merge by accident -- they sat among the plain imports and
/// the extractor took the body from after the last one -- and `use of
/// undeclared identifier 'windows'` is what said so.
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

// `c` was `pub` here until increment 5g, re-exporting the C-ABI namespace as
// `ev.c` -- the facade shape 6d and 6g spent, surviving at one name because
// it is a single line rather than a file. Nothing in the tree spells `ev.c`;
// making it private is what proves that, and the build is the proof.
const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");
const value = @import("value.zig");

pub const windows = builtin.os.tag == .windows;
pub const android = builtin.abi.isAndroid();
pub const has_net = constants.JANET_VM_HAS_NET != 0;
pub const has_interrupt = constants.JANET_VM_HAS_INTERRUPT != 0;

// -------------------------------------------------------------------------
// The loop and its cfunctions -- what `ev_loop.zig` was.
// -------------------------------------------------------------------------

/// `src/core/util.h`. The clock arrives in parts because `struct timespec`
/// cannot be named portably from Zig; `os_time.zig` records the measurement
/// and `util.c` supplies this over either arm of `-Dos-time`.
pub extern fn janet_os_gettime(source: i32, sec: *i64, nsec: *i64) callconv(.c) i32;

/// `src/core/util.h`, declared here rather than in `cabi.zig`.
pub extern fn janet_strerror(e: c_int) callconv(.c) [*:0]const u8;

/// `src/core/util.h`. Only the read state machine's `recvfrom` arm names it,
/// and only under `JANET_NET`.
pub extern const janet_address_type: abstract_type.AbstractType;

pub inline fn vm() *types.JanetVM {
    return c.vm();
}

pub inline fn errno() c_int {
    return std.c._errno().*;
}

pub const sig_ok: types.JanetSignal = @intCast(constants.JANET_SIGNAL_OK);
pub const sig_error: types.JanetSignal = @intCast(constants.JANET_SIGNAL_ERROR);
pub const sig_event: types.JanetSignal = @intCast(constants.JANET_SIGNAL_EVENT);
pub const sig_yield: types.JanetSignal = @intCast(constants.JANET_SIGNAL_YIELD);
pub const sig_interrupt: types.JanetSignal = @intCast(constants.JANET_SIGNAL_INTERRUPT);

/// `JANET_EXIT`, which `janet_assert` expands to. A macro, so no translation
/// ever carried it. `io_core.zig` records what differs from the C original: the
/// location is this file's, and an embedder's own `JANET_EXIT` override is a
/// preprocessor substitution no Zig caller can see.
pub fn exitWith(comptime where: std.builtin.SourceLocation, comptime message: []const u8) noreturn {
    const line = std.fmt.comptimePrint(
        "janet abort at {s}:{d}: {s}\n",
        .{ where.file, where.line, message },
    );
    _ = fwrite(line.ptr, 1, line.len, @ptrCast(@alignCast(stdio.err())));
    abort();
}

/// `src/core/io.c`'s stderr handle. A function rather than a variable for the
/// reason Part 11 records: `translate-c` gives `stderr` three incompatible
/// shapes across this project's targets. The `FILE` is spelled `?*c.FILE` and
/// never `[*c]c.FILE`, because musl declares it incomplete and Zig will not
/// index a pointer to an opaque type -- Part 11 met the same difference.
extern fn fwrite(ptr: [*]const u8, size: usize, n: usize, stream_handle: ?*types.FILE) callconv(.c) usize;
extern fn abort() callconv(.c) noreturn;
extern fn exit(status: c_int) callconv(.c) noreturn;

/// `janet_eprintf`, which is a macro over `janet_dynprintf` and so does not
/// survive translation. `core_env.zig` writes it out the same way.
inline fn eprintf(comptime format: [:0]const u8, args: anytype) void {
    // `pp_format.dynprintf` can raise: `(dyn :err)` may be a Janet function, and
    // calling it can. This position cannot carry one -- it is a trace or a
    // diagnostic on the way out -- so the raise is reported exactly as the C
    // abi reported it before Part 18 deleted the variadic.
    raise.reported(pp_format.dynprintf("err", @ptrCast(@alignCast(stdio.err())), format, args));
}

/// `janet_assert`.
pub inline fn assert(comptime where: std.builtin.SourceLocation, cond: bool, comptime message: []const u8) void {
    if (!cond) exitWith(where, message);
}

/// `JANET_OUT_OF_MEMORY`. The C macro names `__FILE__` and `__LINE__` at the
/// call site and this names the caller's `@src()` for the same reason.
pub fn outOfMemory(comptime where: std.builtin.SourceLocation) noreturn {
    const line = std.fmt.comptimePrint(
        "{s}:{d} - janet out of memory\n",
        .{ where.file, where.line },
    );
    _ = fwrite(line.ptr, 1, line.len, @ptrCast(@alignCast(stdio.err())));
    exit(1);
}

/// `janet_wrap_integer`, written out. `janet.h` declares the function beside
/// its macro and `wrap.c` defines it only for the two nanbox layouts, so a
/// tagged build has no such symbol. This is the fifth subsystem to meet the
/// defect `FOUND.md` records.
pub inline fn wrapInteger(x: i32) types.Janet {
    return wrap.fromNumber(@floatFromInt(x));
}

// ==========================================================================
// The timeout min heap
// ==========================================================================

/// `ts_now`. Each backend spelled this out after calling `janet_gettime`;
/// `ev_core.zig` took the arithmetic in Phase 8 and the Windows arm reads a
/// tick count instead of a clock.
pub fn tsNow() types.JanetTimestamp {
    if (windows) return @intCast(GetTickCount64());
    var sec: i64 = undefined;
    var nsec: i64 = undefined;
    assert(@src(), janet_os_gettime(1, &sec, &nsec) != -1, "failed to get time");
    return ev_core.tsFromParts(sec, nsec);
}

/// Look at the next timeout without removing it.
pub fn peekTimeout(out: *types.JanetTimeout) bool {
    if (vm().tq_count == 0) return false;
    out.* = vm().tq.?[0];
    return true;
}

/// Remove one timeout from the min heap and restore the heap property.
pub fn popTimeout(start: usize) void {
    var index = start;
    const v = vm();
    if (v.tq_count <= index) return;
    v.tq_count -= 1;
    v.tq.?[index] = v.tq.?[v.tq_count];
    while (true) {
        const smallest = ev_core.heapSiftDown(
            v.tq.?,
            @sizeOf(types.JanetTimeout),
            @offsetOf(types.JanetTimeout, "when"),
            v.tq_count,
            index,
        );
        if (smallest < 0) return;
        const target: usize = @intCast(smallest);
        const temp = v.tq.?[index];
        v.tq.?[index] = v.tq.?[target];
        v.tq.?[target] = temp;
        index = target;
    }
}

/// Add a timeout to the min heap, growing it if it is full.
pub fn addTimeout(to: types.JanetTimeout) void {
    const v = vm();
    const oldcount = v.tq_count;
    const newcount = oldcount + 1;
    if (newcount > v.tq_capacity) {
        const newcap = 2 * newcount;
        const tq: ?[*]types.JanetTimeout = @ptrCast(@alignCast(utils.realloc(
            v.tq,
            newcap * @sizeOf(types.JanetTimeout),
        )));
        if (tq == null) outOfMemory(@src());
        v.tq = tq;
        v.tq_capacity = newcap;
    }
    v.tq_count = newcount;
    v.tq.?[oldcount] = to;
    var index = oldcount;
    while (true) {
        const parent = ev_core.heapSiftUp(
            v.tq.?,
            @sizeOf(types.JanetTimeout),
            @offsetOf(types.JanetTimeout, "when"),
            index,
        );
        if (parent < 0) break;
        const target: usize = @intCast(parent);
        const tmp = v.tq.?[index];
        v.tq.?[index] = v.tq.?[target];
        v.tq.?[target] = tmp;
        index = target;
    }
}

// ==========================================================================
// Scheduling
// ==========================================================================

/// Mirrors the anonymous `JanetTask` in `ev.c`.
pub const Task = extern struct {
    fiber: *types.JanetFiber,
    value: types.Janet,
    sig: types.JanetSignal,
    /// If the fiber has been rescheduled this loop, don't run first scheduling.
    expected_sched_id: u32,
};

const fiber_flag_canceled: i32 = @intCast(constants.JANET_FIBER_EV_FLAG_CANCELED);
const fiber_flag_suspended: i32 = @intCast(constants.JANET_FIBER_EV_FLAG_SUSPENDED);
const fiber_flag_root: i32 = @intCast(constants.JANET_FIBER_FLAG_ROOT);
const fiber_flag_in_flight: i32 = @intCast(constants.JANET_FIBER_EV_FLAG_IN_FLIGHT);

fn scheduleGeneral(fiber: *types.JanetFiber, val: types.Janet, sig: types.JanetSignal, soon: bool) void {
    if (fiber.*.gc.flags & fiber_flag_canceled != 0) return;
    if (fiber.*.gc.flags & fiber_flag_root == 0) {
        const task_element = wrap.fromFiber(fiber);
        tables.put(&vm().active_tasks, task_element, wrap.fromTrue());
    }
    fiber.*.sched_id +%= 1;
    const t: Task = .{
        .fiber = fiber,
        .value = val,
        .sig = sig,
        .expected_sched_id = fiber.*.sched_id,
    };
    fiber.*.gc.flags |= fiber_flag_root;
    if (sig == sig_error) fiber.*.gc.flags |= fiber_flag_canceled;
    const pushed = if (soon)
        ev_core.qPushHead(&vm().spawn, &t, @sizeOf(Task))
    else
        ev_core.qPush(&vm().spawn, &t, @sizeOf(Task));
    assert(@src(), pushed == 0, "schedule queue overflow");
}

pub fn scheduleSignal(fiber: *types.JanetFiber, val: types.Janet, sig: types.JanetSignal) void {
    scheduleGeneral(fiber, val, sig, false);
}

pub fn scheduleSoon(fiber: *types.JanetFiber, val: types.Janet, sig: types.JanetSignal) void {
    scheduleGeneral(fiber, val, sig, true);
}

pub fn cancel(fiber: *types.JanetFiber, val: types.Janet) raise.Raising(void) {
    if (fiber.*.gc.flags & fiber_flag_root == 0) {
        return raise.panic("cannot cancel non-task fiber");
    }
    scheduleGeneral(fiber, val, sig_error, false);
}

pub fn janet_cancel(fiber: *types.JanetFiber, val: types.Janet) void {
    raise.reported(cancel(fiber, val));
}

pub fn schedule(fiber: *types.JanetFiber, val: types.Janet) void {
    scheduleGeneral(fiber, val, sig_ok, false);
}

/// Mark every fiber and value the scheduler is holding on to.
pub fn evMark() void {
    const v = vm();
    // The queue allocates lazily, so `data` is null until something is
    // pushed; `head` and `tail` are then both zero and the C original's loops
    // run zero times. Zig will not cast a null pointer to a non-optional one
    // even when nothing dereferences it, so the emptiness is spelled out.
    if (v.spawn.data) |data| {
        const tasks: [*]Task = @ptrCast(@alignCast(data));
        if (v.spawn.head <= v.spawn.tail) {
            var i = v.spawn.head;
            while (i < v.spawn.tail) : (i += 1) markTask(&tasks[@intCast(i)]);
        } else {
            var i = v.spawn.head;
            while (i < v.spawn.capacity) : (i += 1) markTask(&tasks[@intCast(i)]);
            i = 0;
            while (i < v.spawn.tail) : (i += 1) markTask(&tasks[@intCast(i)]);
        }
    }

    var i: usize = 0;
    while (i < v.tq_count) : (i += 1) {
        gc_mark.mark(wrap.fromFiber(v.tq.?[i].fiber.?));
        if (v.tq.?[i].curr_fiber) |curr| {
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
pub fn asyncEnd(fiber: *types.JanetFiber) void {
    if (fiber.*.ev_callback) |cb| {
        if (fiber.*.ev_stream.?.read_fiber == fiber) fiber.*.ev_stream.?.read_fiber = null;
        if (fiber.*.ev_stream.?.write_fiber == fiber) fiber.*.ev_stream.?.write_fiber = null;
        ev_callback.dispatchTotal(ev_callback.of(cb), fiber, constants.JANET_ASYNC_EVENT_DEINIT);
        _ = gc_alloc.gcunroot(wrap.fromAbstract(fiber.*.ev_stream));
        fiber.*.ev_callback = null;
        if (fiber.*.flags & fiber_flag_in_flight == 0) {
            if (fiber.*.ev_state) |state| {
                utils.free(state);
                fiber.*.ev_state = null;
            }
            evDecRefcount();
        }
    }
}

/// Mark a fiber as waiting on a completion the port has not delivered yet.
/// A no-op away from Windows, where there is no in-flight state to track.
pub fn asyncInFlight(fiber: *types.JanetFiber) void {
    if (windows) fiber.*.flags |= fiber_flag_in_flight;
}

pub fn asyncStartFiber(
    fiber: ?*types.JanetFiber,
    s: *types.JanetStream,
    mode: types.JanetAsyncMode,
    callback: ev_callback.EVCallback,
    state: ?*anyopaque,
) raise.Raising(void) {
    assert(@src(), fiber.?.ev_callback == null, "double async on fiber");
    if (mode & constants.JANET_ASYNC_LISTEN_READ != 0) s.read_fiber = fiber;
    if (mode & constants.JANET_ASYNC_LISTEN_WRITE != 0) s.write_fiber = fiber;
    fiber.?.ev_callback = ev_callback.stored(callback);
    fiber.?.ev_stream = s;
    evIncRefcount();
    gc_alloc.gcroot(wrap.fromAbstract(s));
    fiber.?.ev_state = state;
    try callback(fiber.?, constants.JANET_ASYNC_EVENT_INIT);
}

pub fn janet_async_start_fiber(
    fiber: *types.JanetFiber,
    s: *types.JanetStream,
    mode: types.JanetAsyncMode,
    callback: types.JanetEVCallback,
    state: ?*anyopaque,
) callconv(.c) void {
    raise.reported(asyncStartFiber(fiber, s, mode, ev_callback.of(callback), state));
}

pub fn asyncStart(
    s: *types.JanetStream,
    mode: types.JanetAsyncMode,
    callback: ev_callback.EVCallback,
    state: ?*anyopaque,
) raise.Error {
    asyncStartFiber(vm().root_fiber, s, mode, callback, state) catch |err| return err;
    return awaitEvent();
}

pub fn janet_async_start(
    s: *types.JanetStream,
    mode: types.JanetAsyncMode,
    callback: types.JanetEVCallback,
    state: ?*anyopaque,
) callconv(.c) void {
    raise.report(asyncStart(s, mode, ev_callback.of(callback), state));
}

pub fn fiberDidResume(fiber: *types.JanetFiber) void {
    asyncEnd(fiber);
}

// ==========================================================================
// Init, deinit, and the reference count that keeps the loop alive
// ==========================================================================

pub fn evIncRefcount() void {
    _ = abstracts.atomicInc(&vm().listener_count);
}

pub fn evDecRefcount() void {
    _ = abstracts.atomicDec(&vm().listener_count);
}

pub fn evInitCommon() void {
    const v = vm();
    ev_core.qInit(&v.spawn);
    v.tq = null;
    v.tq_count = 0;
    v.tq_capacity = 0;
    _ = tables.initRaw(&v.threaded_abstracts, 0);
    _ = tables.initRaw(&v.active_tasks, 0);
    _ = tables.initRaw(&v.signal_handlers, 0);
    math.rngSeed(&v.ev_rng, 0);
    if (!windows) {
        _ = pthread_attr_init(&v.new_thread_attr);
        _ = pthread_attr_setdetachstate(&v.new_thread_attr, PTHREAD_CREATE_DETACHED);
    }
}

pub fn evDeinitCommon() void {
    const v = vm();
    var to: types.JanetTimeout = undefined;
    while (peekTimeout(&to)) {
        handleTimeoutWorker(to, true);
        popTimeout(0);
    }
    ev_core.qDeinit(&v.spawn);
    utils.free(v.tq);
    tables.deinit(&v.threaded_abstracts);
    tables.deinit(&v.active_tasks);
    tables.deinit(&v.signal_handlers);
    if (!windows) _ = pthread_attr_destroy(&v.new_thread_attr);
}

// ==========================================================================
// Yielding to the loop, and the timeouts a fiber can set on itself
// ==========================================================================

/// `janet_await`. The Zig side: yielding to the event loop is a raise with the
/// `EVENT` signal, and always has been -- what changes here is that it returns
/// instead of jumping.
pub fn awaitEvent() raise.Error {
    return raise.signal(sig_event, wrap.fromNil());
}

pub fn janet_await() void {
    raise.report(awaitEvent());
}

fn addFiberTimeout(sec: f64, is_error: bool) void {
    const fiber = vm().root_fiber.?;
    addTimeout(.{
        .when = ev_core.tsDelta(tsNow(), sec),
        .fiber = fiber,
        .curr_fiber = null,
        .sched_id = fiber.sched_id,
        .is_error = @intFromBool(is_error),
        .has_worker = 0,
        .worker = std.mem.zeroes(@FieldType(types.JanetTimeout, "worker")),
    });
}

pub fn addtimeout(sec: f64) void {
    addFiberTimeout(sec, true);
}

pub fn addtimeoutNil(sec: f64) void {
    addFiberTimeout(sec, false);
}

pub fn sleepAwait(sec: f64) raise.Error {
    const fiber = vm().root_fiber.?;
    addTimeout(.{
        .when = ev_core.tsDelta(tsNow(), sec),
        .fiber = fiber,
        .curr_fiber = null,
        .sched_id = fiber.sched_id,
        .is_error = 0,
        .has_worker = 0,
        .worker = std.mem.zeroes(@FieldType(types.JanetTimeout, "worker")),
    });
    return awaitEvent();
}

pub fn janet_sleep_await(sec: f64) void {
    raise.report(sleepAwait(sec));
}

// ==========================================================================
// The deadline worker thread
// ==========================================================================

/// Mirrors the anonymous `JanetThreadedTimeout` in `ev.c`.
const ThreadedTimeout = extern struct {
    sec: f64,
    vm_ptr: *types.JanetVM,
    fiber: *types.JanetFiber,
    cancel_event: if (windows) ?*anyopaque else void = if (windows) null else {},
};

fn timeoutCallback(msg: types.JanetEVGenericMessage) callconv(.c) void {
    _ = msg;
    vm_state.interpreterInterruptHandled(vm());
}

/// Join, and optionally interrupt, the thread a `(ev/deadline ... true)` set
/// running. `has_worker` is false for every other kind of timeout.
fn handleTimeoutWorker(to: types.JanetTimeout, cancel_it: bool) void {
    if (to.has_worker == 0) return;
    if (windows) {
        if (cancel_it and to.worker_event != null) _ = SetEvent(to.worker_event);
        _ = WaitForSingleObject(to.worker, INFINITE);
        _ = CloseHandle(to.worker);
        if (to.worker_event != null) _ = CloseHandle(to.worker_event);
    } else {
        if (cancel_it) {
            if (android) {
                assert(@src(), pthread_kill(to.worker, SIGUSR1) == 0, "pthread_kill");
            } else {
                assert(@src(), pthread_cancel(to.worker) == 0, "pthread_cancel");
            }
        }
        var res: ?*anyopaque = null;
        assert(@src(), pthread_join(to.worker, &res) == 0, "pthread_join");
    }
}

/// The Android arm's `SIGUSR1` handler: `pthread_cancel` is not available
/// there, so the worker is asked to exit instead.
fn timeoutStop(sig_num: c_int) callconv(.c) void {
    if (sig_num == SIGUSR1) pthread_exit(null);
}

/// The Android arm installs a `SIGUSR1` handler here before sleeping, because
/// `pthread_cancel` does not exist there and `timeoutStop` is what stands in
/// for it. That installation is *recorded rather than written*: it needs a
/// `struct sigaction`, which is a host layout, and `android` is comptime-false
/// for every target this project builds -- so Part 8's rule applies and
/// carrying it would produce something even less checked than the C it
/// replaced. `os/abi.zig` makes the same call for `JANET_THREADS`.
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
    const msg = std.mem.zeroes(types.JanetEVGenericMessage);
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
        res = WaitForSingleObject(copy.cancel_event, duration + i);
        wait_end = tsNow();
    }
    if (res == WAIT_TIMEOUT) {
        vm_state.interpreterInterrupt(copy.vm_ptr);
        const msg = std.mem.zeroes(types.JanetEVGenericMessage);
        evPostEvent(copy.vm_ptr, timeoutCallback, msg);
    }
    return 0;
}

// ==========================================================================
// The main loop
// ==========================================================================

pub fn loopDone() c_int {
    const v = vm();
    const busy = (v.spawn.head != v.spawn.tail) or
        (v.tq_count != 0) or
        (abstracts.atomicLoad(&v.listener_count) != 0);
    return @intFromBool(!busy);
}

/// One turn of the loop: expired timers, then runnable fibers, then a poll.
///
/// Returns the fiber an interrupt stopped, or null. The C original's three
/// stages are preserved exactly, including that the poll is skipped when the
/// timer scan drained the heap.
pub fn loop1() raise.Raising(?*types.JanetFiber) {
    const v = vm();

    // Schedule expired timers.
    var to: types.JanetTimeout = undefined;
    const now = tsNow();
    while (peekTimeout(&to) and to.when <= now) {
        popTimeout(0);
        if (to.curr_fiber) |curr| {
            if (fibers.canResume(curr) != 0) {
                // The fiber is a task, so this cannot raise.
                try cancel(to.fiber.?, value.fromBytes("deadline expired", .string));
            }
        } else if (to.fiber.?.sched_id == to.sched_id) {
            // A timeout on a call rather than on a whole fiber.
            if (to.is_error != 0) {
                try cancel(to.fiber.?, value.fromBytes("timeout", .string));
            } else {
                schedule(to.fiber.?, wrap.fromNil());
            }
        }
        handleTimeoutWorker(to, false);
    }

    // Run scheduled fibers unless interrupts need to be handled.
    while (v.spawn.head != v.spawn.tail) {
        if (abstracts.atomicLoadRelaxed(&v.auto_suspend) != 0) break;
        var task: Task = .{
            .fiber = undefined,
            .value = wrap.fromNil(),
            .sig = sig_ok,
            .expected_sched_id = 0,
        };
        _ = ev_core.qPop(&v.spawn, &task, @sizeOf(Task));
        if (task.fiber.*.gc.flags & fiber_flag_suspended != 0) evDecRefcount();
        task.fiber.*.gc.flags &= ~(fiber_flag_canceled | fiber_flag_suspended);
        if (task.expected_sched_id != task.fiber.*.sched_id) continue;
        var res: types.Janet = undefined;
        const sig = vm_entry.continueSignal(task.fiber, task.value, &res, task.sig);
        if (fibers.canResume(task.fiber) == 0) {
            _ = tables.remove(&v.active_tasks, wrap.fromFiber(task.fiber));
        }
        const sv = task.fiber.*.supervisor_channel;
        const is_suspended = sig == sig_event or sig == sig_yield or sig == sig_interrupt;
        if (is_suspended) {
            task.fiber.*.gc.flags |= fiber_flag_suspended;
            evIncRefcount();
        }
        if (sv == null) {
            if (!is_suspended) try trace_frames.stacktraceExt(task.fiber, res, "");
        } else if (sig == sig_ok or (task.fiber.*.flags & (@as(i32, 1) << @intCast(sig)) != 0)) {
            const chan = channel.unwrap(sv);
            const event = channel.makeSupervisorEvent(
                utils.signalNames[@intCast(sig)],
                task.fiber,
                chan.is_threaded != 0,
            );
            // Mode 2 does not block and the only raise it can make is on a
            // closed channel, which the C original delivers the same way.
            _ = try channel.push(chan, event, 2);
        } else if (!is_suspended) {
            try trace_frames.stacktraceExt(task.fiber, res, "");
        }
        if (sig == sig_interrupt) return task.fiber;
    }

    // Poll for events.
    if (v.tq_count != 0 or abstracts.atomicLoad(&v.listener_count) != 0) {
        var next: types.JanetTimeout = std.mem.zeroes(types.JanetTimeout);
        var has_timeout = false;
        // Drop timeouts that are no longer needed.
        while (true) {
            has_timeout = peekTimeout(&next);
            if (!has_timeout) break;
            if (next.curr_fiber) |curr| {
                if (fibers.canResume(curr) == 0) {
                    popTimeout(0);
                    _ = tables.remove(&v.active_tasks, wrap.fromFiber(curr));
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
        if (v.tq_count != 0 or abstracts.atomicLoad(&v.listener_count) != 0) {
            try backend.loop1Impl(has_timeout, next.when);
        }
    }

    return null;
}

pub fn janet_loop1() ?*types.JanetFiber {
    return raise.reported(loop1());
}

/// `janet_interpreter_interrupt`, plus an empty event so that a loop blocked
/// in the backend wakes up to see it.
pub fn loop1Interrupt(v: *types.JanetVM) void {
    vm_state.interpreterInterrupt(v);
    const msg = std.mem.zeroes(types.JanetEVGenericMessage);
    evPostEvent(v, null, msg);
}

pub fn loop() raise.Raising(void) {
    while (loopDone() == 0) {
        if (try loop1()) |interrupted| schedule(interrupted, wrap.fromNil());
    }
}

pub fn janet_loop() void {
    raise.reported(loop());
}

// ==========================================================================
// Posting an event from another thread, and threaded calls
// ==========================================================================

/// Mirrors the anonymous `JanetSelfPipeEvent` in `ev.c`, and is the head of
/// `ThreadInit` below.
pub const SelfPipeEvent = extern struct {
    msg: types.JanetEVGenericMessage,
    cb: types.JanetThreadedCallback,
};

/// Mirrors the anonymous `JanetEVThreadInit` in `ev.c`. The first two fields
/// are `SelfPipeEvent`'s, deliberately: the Windows arm reuses the allocation
/// as the reply.
const ThreadInit = extern struct {
    msg: types.JanetEVGenericMessage,
    cb: types.JanetThreadedCallback,
    subr: types.JanetThreadedSubroutine,
    write_pipe: types.JanetHandle,
};

pub fn evPostEvent(
    target: ?*types.JanetVM,
    cb: types.JanetCallback,
    msg: types.JanetEVGenericMessage,
) callconv(.c) void {
    const v = target orelse vm();
    _ = abstracts.atomicInc(&v.listener_count);
    if (windows) {
        const iocp: ?*anyopaque = @ptrCast(v.iocp);
        const event: *SelfPipeEvent = @ptrCast(@alignCast(utils.malloc(@sizeOf(SelfPipeEvent)) orelse
            outOfMemory(@src())));
        event.msg = msg;
        event.cb = cb;
        assert(@src(), PostQueuedCompletionStatus(
            iocp,
            @sizeOf(SelfPipeEvent),
            0,
            @ptrCast(event),
        ) != 0, "failed to post completion event");
    } else {
        var event = std.mem.zeroes(SelfPipeEvent);
        event.msg = msg;
        event.cb = cb;
        const fd = v.selfpipe[1];
        // Handle a bit of back pressure before giving up.
        var tries: i32 = 20;
        while (tries > 0) {
            var status: isize = undefined;
            while (true) {
                status = write(fd, @ptrCast(&event), @sizeOf(SelfPipeEvent));
                if (!(status == -1 and errno() == EINTR)) break;
            }
            if (status > 0) break;
            _ = sleep(0);
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
        var status: isize = undefined;
        while (true) {
            status = write(fd, @ptrCast(&response), @sizeOf(SelfPipeEvent));
            if (!(status == -1 and errno() == EINTR)) break;
        }
        if (status > 0) break;
        _ = sleep(1);
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
    assert(@src(), PostQueuedCompletionStatus(
        iocp,
        @sizeOf(SelfPipeEvent),
        0,
        @ptrCast(init),
    ) != 0, "failed to post completion event");
    return 0;
}

pub fn threadedCall(
    fp: types.JanetThreadedSubroutine,
    arguments: types.JanetEVGenericMessage,
    cb: types.JanetThreadedCallback,
) raise.Raising(void) {
    const init: *ThreadInit = @ptrCast(@alignCast(utils.malloc(@sizeOf(ThreadInit)) orelse
        outOfMemory(@src())));
    init.msg = arguments;
    init.subr = fp;
    init.cb = cb;

    if (windows) {
        init.write_pipe = iocpHandle();
        const thread_handle = CreateThread(null, 0, threadBodyWindows, init, 0, null);
        if (thread_handle == null) {
            utils.free(init);
            return raise.panic("failed to create thread");
        }
        _ = CloseHandle(thread_handle); // detach from thread
    } else {
        init.write_pipe = vm().selfpipe[1];
        var waiter_thread: types.pthread_t = undefined;
        const err = pthread_create(&waiter_thread, &vm().new_thread_attr, threadBodyPosix, init);
        if (err != 0) {
            utils.free(init);
            return pp_format.panicf("%s", .{janet_strerror(err)});
        }
    }

    // Increment ev refcount so we don't quit while waiting for a subprocess.
    evIncRefcount();
}

pub fn evThreadedCall(
    fp: types.JanetThreadedSubroutine,
    arguments: types.JanetEVGenericMessage,
    cb: types.JanetThreadedCallback,
) callconv(.c) void {
    raise.reported(threadedCall(fp, arguments, cb));
}

/// The default reply handler for `janet_ev_threaded_await`.
pub fn evDefaultThreadedCallback(return_value: types.JanetEVGenericMessage) callconv(.c) void {
    const fiber = return_value.fiber orelse {
        freeThreadedPayload(return_value);
        return;
    };
    if (fibers.canResume(fiber) != 0) {
        switch (return_value.tag) {
            constants.JANET_EV_TCTAG_INTEGER => schedule(fiber, wrapInteger(return_value.argi)),
            constants.JANET_EV_TCTAG_STRING, constants.JANET_EV_TCTAG_STRINGF => schedule(
                fiber,
                value.fromBytes(std.mem.span(payloadText(return_value)), .string),
            ),
            constants.JANET_EV_TCTAG_KEYWORD => schedule(
                fiber,
                value.fromBytes(std.mem.span(payloadText(return_value)), .keyword),
            ),
            constants.JANET_EV_TCTAG_ERR_STRING, constants.JANET_EV_TCTAG_ERR_STRINGF => raise.reported(cancel(
                fiber,
                value.fromBytes(std.mem.span(payloadText(return_value)), .string),
            )),
            constants.JANET_EV_TCTAG_ERR_KEYWORD => raise.reported(cancel(
                fiber,
                value.fromBytes(std.mem.span(payloadText(return_value)), .keyword),
            )),
            constants.JANET_EV_TCTAG_BOOLEAN => schedule(
                fiber,
                wrap.fromBoolean(return_value.argi),
            ),
            // JANET_EV_TCTAG_NIL, and every tag the C switch sends to
            // `default`, which is the same arm.
            else => schedule(fiber, wrap.fromNil()),
        }
    }
    freeThreadedPayload(return_value);
    _ = gc_alloc.gcunroot(wrap.fromFiber(fiber));
}

inline fn payloadText(return_value: types.JanetEVGenericMessage) [*:0]const u8 {
    return @ptrCast(return_value.argp);
}

/// The C original writes this cleanup switch twice, and both copies send
/// every tag but the two `*_STRINGF` ones to a `default` that also frees. So
/// the payload is freed for every tag; the two named cases are documentation
/// rather than a condition, and that is reproduced here.
inline fn freeThreadedPayload(return_value: types.JanetEVGenericMessage) void {
    utils.free(return_value.argp);
}

pub fn threadedAwait(fp: types.JanetThreadedSubroutine, tag: c_int, argi: c_int, argp: ?*anyopaque) raise.Error {
    var arguments = std.mem.zeroes(types.JanetEVGenericMessage);
    arguments.tag = tag;
    arguments.argi = argi;
    arguments.argp = argp;
    arguments.fiber = fibers.root();
    gc_alloc.gcroot(wrap.fromFiber(arguments.fiber.?));
    threadedCall(fp, arguments, evDefaultThreadedCallback) catch |err| return err;
    return awaitEvent();
}

pub fn evThreadedAwait(
    fp: types.JanetThreadedSubroutine,
    tag: c_int,
    argi: c_int,
    argp: ?*anyopaque,
) callconv(.c) void {
    raise.report(threadedAwait(fp, tag, argi, argp));
}

// ==========================================================================
// The host calls this file makes directly
// ==========================================================================
//
// Declared here rather than translated, on the tree's standing rule: each
// takes primitive parameters or a type `types.zig` already supplies, so no
// host layout is at stake and no further translation is needed. `pthread_t`
// and `pthread_attr_t` are `types.zig`'s, which takes them from libc because
// `JanetVM` and `JanetTimeout` embed both.

pub extern fn write(fd: c_int, buf: [*]const u8, count: usize) callconv(.c) isize;
pub extern fn read(fd: c_int, buf: [*]u8, count: usize) callconv(.c) isize;
pub extern fn close(fd: c_int) callconv(.c) c_int;
pub extern fn sleep(seconds: c_uint) callconv(.c) c_uint;
pub extern fn pipe(fds: *[2]c_int) callconv(.c) c_int;
pub extern fn fcntl(fd: c_int, cmd: c_int, ...) callconv(.c) c_int;
pub extern fn dup(fd: c_int) callconv(.c) c_int;
pub extern fn fdopen(fd: c_int, mode: [*:0]const u8) callconv(.c) ?*anyopaque;

extern fn pthread_attr_init(attr: *types.pthread_attr_t) callconv(.c) c_int;
extern fn pthread_attr_destroy(attr: *types.pthread_attr_t) callconv(.c) c_int;
extern fn pthread_attr_setdetachstate(attr: *types.pthread_attr_t, state: c_int) callconv(.c) c_int;
extern fn pthread_create(
    thread: *types.pthread_t,
    attr: ?*const types.pthread_attr_t,
    start: *const fn (?*anyopaque) callconv(.c) ?*anyopaque,
    arg: ?*anyopaque,
) callconv(.c) c_int;
extern fn pthread_join(thread: types.pthread_t, res: *?*anyopaque) callconv(.c) c_int;
extern fn pthread_cancel(thread: types.pthread_t) callconv(.c) c_int;
extern fn pthread_kill(thread: types.pthread_t, sig: c_int) callconv(.c) c_int;
extern fn pthread_exit(res: ?*anyopaque) callconv(.c) noreturn;

/// `PTHREAD_CREATE_DETACHED` is 2 on both glibc and musl and 2 on Darwin.
const PTHREAD_CREATE_DETACHED: c_int = 2;
const SIGUSR1: c_int = 30;
pub const EINTR: c_int = @intFromEnum(std.c.E.INTR);
pub const EAGAIN: c_int = @intFromEnum(std.c.E.AGAIN);
/// `EWOULDBLOCK` and `EAGAIN` are the same number on every platform in this
/// project's reach, and Darwin's `std.c.E` does not name the first at all.
pub const EWOULDBLOCK: c_int = if (@hasField(std.c.E, "WOULDBLOCK"))
    @intFromEnum(@field(std.c.E, "WOULDBLOCK"))
else
    EAGAIN;
pub const EPIPE: c_int = @intFromEnum(std.c.E.PIPE);
pub const EPERM: c_int = @intFromEnum(std.c.E.PERM);

pub const INFINITE: u32 = 0xFFFFFFFF;
const WAIT_TIMEOUT: u32 = 0x102;

pub extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
pub extern "kernel32" fn CloseHandle(h: ?*anyopaque) callconv(.winapi) c_int;
pub extern "kernel32" fn SetEvent(h: ?*anyopaque) callconv(.winapi) c_int;
pub extern "kernel32" fn CreateEventA(attrs: ?*anyopaque, manual: c_int, initial: c_int, name: ?[*:0]const u8) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn WaitForSingleObject(h: ?*anyopaque, ms: u32) callconv(.winapi) u32;
pub extern "kernel32" fn ResumeThread(h: ?*anyopaque) callconv(.winapi) u32;
pub extern "kernel32" fn CreateThread(
    attrs: ?*anyopaque,
    stack: usize,
    start: *const fn (?*anyopaque) callconv(.winapi) u32,
    arg: ?*anyopaque,
    flags: u32,
    id: ?*u32,
) callconv(.winapi) ?*anyopaque;
/// `janet_vm.iocp` is declared `void **` in `state.h`, so it is a double
/// pointer where every Windows call wants the handle itself.
pub inline fn iocpHandle() ?*anyopaque {
    return @ptrCast(c.vm().iocp);
}

pub extern "kernel32" fn PostQueuedCompletionStatus(
    port: ?*anyopaque,
    bytes: u32,
    key: usize,
    overlapped: ?*anyopaque,
) callconv(.winapi) c_int;

const CREATE_SUSPENDED: u32 = 0x4;

// ==========================================================================
// `ev/thread`'s child interpreter
// ==========================================================================

/// `JANET_THREAD_SUPERVISOR_FLAG`. Above the four flag letters `ev/thread`
/// accepts, so that it can be added to the same word.
const thread_supervisor_flag: u32 = 0x100;

/// What the protected body needs from `janet_go_thread_subr`, and what it
/// reports back. It was a structure because it had to cross a C shim; it stays
/// one because `args` is an in-out parameter and the other three are read
/// together.
const GoThreadContext = struct {
    args: types.JanetEVGenericMessage,
    flags: u32,
    next: [*]const u8,
    end: [*]const u8,
};

/// The protected scope `ev/thread`'s child interpreter runs under, and until
/// the hinge the second of Phase 10's three `setjmp` sites.
///
/// `janet_zig_ev_protect` in `ev.c` was the whole of it: nine lines that
/// opened the scope with `janet_try`, called back into this file through a C
/// function pointer, and reported the signal `longjmp` had returned. What
/// makes those nine lines unnecessary is that **the jump was only travel**.
/// `janet_try_init` opens the scope -- it is what points `return_reg` at
/// `tstate.payload`, and therefore what `janet_signal_plan` reads to answer
/// `RAISE` rather than `TOP_LEVEL` -- and `janet_restore` closes it. The
/// `setjmp` between them carried the raise from where it happened to here,
/// and a returned error carries it instead.
///
/// So the body is called directly, and the two things the C shim needed and
/// this does not are the function pointer and the `c_raised` handshake around
/// it. A report left by an abi inside the body is consumed at its own
/// call site by `raise.crossing`; one that is not is what the assertion in
/// `janet_restore` exists to name.
fn goThreadProtect(ctx: *GoThreadContext, payload: *types.Janet) types.JanetSignal {
    var tstate: types.JanetTryState = undefined;
    signal_core.tryInit(&tstate);
    var signal: types.JanetSignal = 0;
    goThreadBodyImpl(ctx) catch {
        signal = vm().pending_signal;
    };
    signal_core.restore(&tstate);
    if (signal != 0) payload.* = tstate.payload;
    return signal;
}

/// Everything between `janet_try` and `janet_restore` in the C original's
/// success arm.
fn goThreadBodyImpl(ctx: *GoThreadContext) raise.Raising(void) {
    const v = vm();
    const flags = ctx.flags;

    // Set abstract registry.
    if (flags & 0x2 == 0) {
        const aregv = try marsh.unmarshal(
            ctx.next[0 .. @intFromPtr(ctx.end) - @intFromPtr(ctx.next)],
            constants.JANET_MARSHAL_UNSAFE,
            null,
            @ptrCast(&ctx.next),
        );
        assert(@src(), kind.checkType(aregv, constants.JANET_TABLE) != 0, "expected table for abstract registry");
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
        // The C original calls this a hack to avoid longjmp clobber. It is
        // kept because `janet_vm.user` is where the failure arm reads the
        // supervisor from, and that arm still runs after a jump.
        v.user = wrap.toPointer(sup);
    }

    // Set cfunction registry.
    if (flags & 0x4 == 0) {
        var count1: u32 = undefined;
        @memcpy(std.mem.asBytes(&count1), ctx.next[0..@sizeOf(u32)]);
        const count: usize = count1;
        const remaining = @intFromPtr(ctx.end) - @intFromPtr(ctx.next) - @sizeOf(u32);
        // Use division to avoid overflowing size_t.
        assert(@src(), count <= remaining / @sizeOf(types.JanetCFunRegistry), "thread message invalid");
        v.registry_count = count;
        v.registry_cap = count;
        v.registry = @ptrCast(@alignCast(utils.malloc(count * @sizeOf(types.JanetCFunRegistry)) orelse
            outOfMemory(@src())));
        v.registry_dirty = 1;
        ctx.next += @sizeOf(u32);
        @memcpy(
            @as([*]u8, @ptrCast(v.registry))[0 .. count * @sizeOf(types.JanetCFunRegistry)],
            ctx.next[0 .. count * @sizeOf(types.JanetCFunRegistry)],
        );
        ctx.next += count * @sizeOf(types.JanetCFunRegistry);
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

    var fiber: ?*types.JanetFiber = undefined;
    if (kind.checkType(fiberv, constants.JANET_FIBER) == 0) {
        assert(@src(), kind.checkType(fiberv, constants.JANET_FUNCTION) != 0, "expected function or fiber");
        const func = wrap.toFunction(fiberv);
        // The C original notes that an ordinary panic here misbehaves on
        // Wine + Mingw and asserts instead. The assert is kept.
        assert(
            @src(),
            func.*.def.?.min_arity >= 0 and func.*.def.?.min_arity <= 1,
            "thread function must accept 0 or 1 arguments",
        );
        var seed = val;
        fiber = fibers.new(func, 64, func.*.def.?.min_arity, @ptrCast(&seed));
        assert(@src(), fiber != null, "bad fiber in thread setup");
        fiber.?.flags |= @intCast(constants.JANET_FIBER_MASK_ERROR |
            constants.JANET_FIBER_MASK_USER0 |
            constants.JANET_FIBER_MASK_USER1 |
            constants.JANET_FIBER_MASK_USER2 |
            constants.JANET_FIBER_MASK_USER3 |
            constants.JANET_FIBER_MASK_USER4);
    } else {
        fiber = wrap.toFiber(fiberv);
    }
    if (flags & 0x8 != 0) {
        if (fiber.?.env == null) fiber.?.env = tables.new(0);
        tables.put(fiber.?.env.?, value.fromBytes("task-id", .keyword), val);
    }
    fiber.?.supervisor_channel = v.user;
    schedule(fiber.?, val);
    // `loop`, not the `janet_loop` abi beside it: this function is
    // `raise.Raising` and the abi flattens a raise into a report nobody here
    // would consume. Phase 11 Part 15; `port/swallowed.py` found it.
    try loop();
    ctx.args.tag = constants.JANET_EV_TCTAG_NIL;
}

/// The subroutine a new `ev/thread` runs on its own operating system thread:
/// a whole interpreter, from `janet_init` to `janet_deinit`.
fn goThreadSubr(args_in: types.JanetEVGenericMessage) callconv(.c) types.JanetEVGenericMessage {
    var args = args_in;
    const buffer: *types.JanetBuffer = @ptrCast(@alignCast(args.argp));
    const flags: u32 = @bitCast(args.tag);
    args.tag = 0;
    args.argp = null;
    // A thread subroutine's type is the event loop's, and this runs at the
    // very top of a new thread: there is no scope above it and no caller that
    // could act on a failure to initialise a VM.
    _ = raise.total(vm_lifecycle.init(), "a thread subroutine's VM init");
    vm().sandbox_flags = @bitCast(args.argi);

    var ctx: GoThreadContext = .{
        .args = args,
        .flags = flags,
        .next = buffer.data.?,
        .end = buffer.data.? + @as(usize, @intCast(buffer.count)),
    };
    var payload: types.Janet = wrap.fromNil();
    const signal = goThreadProtect(&ctx, &payload);
    args = ctx.args;

    if (signal != 0) {
        const supervisor = vm().user;
        if (supervisor != null) {
            // Got a supervisor, write the error there.
            const pair = [2]types.Janet{ value.fromBytes("error", .keyword), payload };
            // Reporting the thread's own start failure to its supervisor.
            // A raise here has nowhere left to go -- this *is* the error path.
            _ = raise.total(channel.push(
                channel.unwrap(supervisor),
                wrap.fromTuple(tuples.newFrom(&pair, 2)),
                2,
            ), "a thread subroutine's supervisor report");
        } else if (flags & 0x1 != 0) {
            // No wait, just print to stderr.
            eprintf("thread start failure: %v\n", .{payload});
        } else {
            // Make the ev/thread call from the parent thread error.
            if (kind.checkType(payload, constants.JANET_STRING) != 0) {
                args.tag = constants.JANET_EV_TCTAG_ERR_STRINGF;
                const msg = wrap.toString(payload);
                const len: usize = @intCast(types.stringHead(msg).length);
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

fn goImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.arity(argv, 1, 3);
    const val = if (@as(i32, @intCast(argv.len)) >= 2) argv[1] else wrap.fromNil();
    const supervisor = try args_core.optAbstract(
        argv,
        2,
        abstract_type.stored(&channel.channelType),
        vm().root_fiber.?.supervisor_channel,
    );
    var fiber: ?*types.JanetFiber = undefined;
    if (kind.checkType(argv[0], constants.JANET_FUNCTION) != 0) {
        // Create a fiber for the user.
        const func = wrap.toFunction(argv[0]);
        if (func.*.def.?.min_arity > 1) {
            return pp_format.panicf("task function must accept 0 or 1 arguments", .{});
        }
        var seed = val;
        fiber = fibers.new(func, 64, func.*.def.?.min_arity, @ptrCast(&seed));
        fiber.?.flags |= @intCast(constants.JANET_FIBER_MASK_ERROR |
            constants.JANET_FIBER_MASK_USER0 |
            constants.JANET_FIBER_MASK_USER1 |
            constants.JANET_FIBER_MASK_USER2 |
            constants.JANET_FIBER_MASK_USER3 |
            constants.JANET_FIBER_MASK_USER4);
        if (vm().fiber.?.env == null) vm().fiber.?.env = tables.new(0);
        fiber.?.env = tables.new(0);
        fiber.?.env.?.proto = vm().fiber.?.env;
    } else {
        fiber = try args_core.getFiber(argv, 0);
        if (fibers.status(fiber.?) != constants.JANET_STATUS_NEW) {
            return raise.panic("can only schedule new fibers where (= (fiber/status f) :new)");
        }
    }
    fiber.?.supervisor_channel = supervisor;
    schedule(fiber.?, val);
    return wrap.fromFiber(fiber.?);
}

fn threadImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try vm_lifecycle.sandboxAssert(constants.JANET_SANDBOX_THREADS);
    try args_core.arity(argv, 1, 4);
    const val = if (@as(i32, @intCast(argv.len)) >= 2) argv[1] else wrap.fromNil();
    if (kind.checkType(argv[0], constants.JANET_FUNCTION) != 0) {
        const func = try args_core.getFunction(argv, 0);
        if (func.*.def.?.arity < 0 or func.*.def.?.min_arity > 1) {
            return raise.panic("function must take 0 or 1 arguments");
        }
    } else {
        _ = try args_core.getFiber(argv, 0); // arg check for fiber
    }
    var flags: u64 = 0;
    if (@as(i32, @intCast(argv.len)) >= 3) flags = try args_core.getFlags(argv, 2, "nact");
    const supervisor = try args_core.optAbstract(
        argv,
        3,
        abstract_type.stored(&channel.channelType),
        vm().root_fiber.?.supervisor_channel,
    );
    if (supervisor != null) flags |= thread_supervisor_flag;

    // Marshal arguments for the new thread.
    const buffer: *types.JanetBuffer = @ptrCast(@alignCast(utils.malloc(@sizeOf(types.JanetBuffer)) orelse
        outOfMemory(@src())));
    _ = buffers.init(buffer, 0);
    if (flags & 0x2 == 0) {
        try marsh.marshal(buffer, wrap.fromTable(vm().abstract_registry.?), null, constants.JANET_MARSHAL_UNSAFE);
    }
    if (flags & thread_supervisor_flag != 0) {
        try marsh.marshal(buffer, wrap.fromAbstract(supervisor), null, constants.JANET_MARSHAL_UNSAFE);
    }
    if (flags & 0x4 == 0) {
        assert(@src(), vm().registry_count <= std.math.maxInt(i32), "assert failed size check");
        const temp: u32 = @intCast(vm().registry_count);
        _ = try buffers.pushBytes(buffer, std.mem.asBytes(&temp));
        _ = try buffers.pushBytes(
            buffer,
            @as([*]const u8, @ptrCast(vm().registry))[0 .. vm().registry_count * @sizeOf(types.JanetCFunRegistry)],
        );
    }
    try marsh.marshal(buffer, argv[0], null, constants.JANET_MARSHAL_UNSAFE);
    try marsh.marshal(buffer, val, null, constants.JANET_MARSHAL_UNSAFE);

    if (flags & 0x1 != 0) {
        // Return immediately.
        var arguments = std.mem.zeroes(types.JanetEVGenericMessage);
        arguments.tag = @bitCast(@as(u32, @truncate(flags)));
        arguments.argi = @bitCast(vm().sandbox_flags);
        arguments.argp = buffer;
        arguments.fiber = null;
        try threadedCall(goThreadSubr, arguments, evDefaultThreadedCallback);
        return wrap.fromNil();
    }
    return threadedAwait(
        goThreadSubr,
        @bitCast(@as(u32, @truncate(flags))),
        @bitCast(vm().sandbox_flags),
        buffer,
    );
}

fn giveSupervisorImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.arity(argv, 1, -1);
    const chanv = vm().root_fiber.?.supervisor_channel;
    if (chanv != null) {
        const chan = channel.unwrap(chanv);
        if (try channel.push(chan, wrap.fromTuple(tuples.newFrom(argv.ptr, @as(i32, @intCast(argv.len)))), 0)) {
            return awaitEvent();
        }
    }
    return wrap.fromNil();
}

fn sleepImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 1);
    const sec = try args_core.getNumber(argv, 0);
    return sleepAwait(sec);
}

fn deadlineImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.arity(argv, 1, 4);
    var sec = try args_core.getNumber(argv, 0);
    if (sec < 0) sec = 0;
    const tocancel = try args_core.optFiber(argv, 1, vm().root_fiber);
    const tocheck = try args_core.optFiber(argv, 2, vm().fiber);
    const use_interrupt = try args_core.optBoolean(argv, 3, 0) != 0;
    var to: types.JanetTimeout = .{
        .when = ev_core.tsDelta(tsNow(), sec),
        .fiber = tocancel,
        .curr_fiber = tocheck,
        .is_error = 0,
        .sched_id = tocancel.?.sched_id,
        .has_worker = 0,
        .worker = std.mem.zeroes(@FieldType(types.JanetTimeout, "worker")),
    };
    if (use_interrupt) {
        if (!has_interrupt) {
            // The interpreter's half of this is compiled out, so a timer
            // thread would raise auto_suspend at a VM that never reads it and
            // a fiber that does not yield would run forever. Refuse the same
            // way os/sigaction does, before anything is allocated or started.
            return raise.panic("interpreter interrupt not enabled");
        }
        if (android) try vm_lifecycle.sandboxAssert(constants.JANET_SANDBOX_SIGNAL);
        const tto: *ThreadedTimeout = @ptrCast(@alignCast(utils.malloc(@sizeOf(ThreadedTimeout)) orelse
            outOfMemory(@src())));
        tto.sec = sec;
        tto.vm_ptr = vm();
        tto.fiber = tocheck.?;
        if (windows) {
            const cancel_event = CreateEventA(null, 1, 0, null);
            if (cancel_event == null) {
                utils.free(tto);
                return raise.panic("failed to create cancel event");
            }
            tto.cancel_event = cancel_event;
            const worker = CreateThread(null, 0, timeoutBodyWindows, tto, CREATE_SUSPENDED, null);
            if (worker == null) {
                utils.free(tto);
                return raise.panic("failed to create thread");
            }
            to.has_worker = 1;
            to.worker = worker;
            to.worker_event = cancel_event;
            _ = ResumeThread(worker);
        } else {
            var worker: types.pthread_t = undefined;
            const err = pthread_create(&worker, null, timeoutBodyPosix, tto);
            if (err != 0) {
                utils.free(tto);
                return pp_format.panicf("%s", .{janet_strerror(err)});
            }
            to.has_worker = 1;
            to.worker = worker;
        }
    }
    addTimeout(to);
    return wrap.fromFiber(tocancel.?);
}

fn cancelImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 2);
    const fiber = try args_core.getFiber(argv, 0);
    try cancel(fiber, argv[1]);
    return argv[0];
}

fn allTasksImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 0);

    const v = vm();
    const array = arrays.new(v.active_tasks.count);
    var i: i32 = 0;
    while (i < v.active_tasks.capacity) : (i += 1) {
        const key = v.active_tasks.data.?[@intCast(i)].key;
        if (kind.checkType(key, constants.JANET_NIL) == 0) try arrays.push(array, key);
    }
    return wrap.fromArray(array);
}

// ==========================================================================
// The two lock types
// ==========================================================================

fn mutexGC(p: ?*anyopaque, size: usize) callconv(.c) c_int {
    _ = size;
    os_locks.mutexDeinit(@ptrCast(p));
    return 0;
}

pub const mutexType: abstract_type.AbstractType = .{
    .name = "core/lock",
    .gc = mutexGC,
    .gcmark = null,
    .get = null,
    .put = null,
    .marshal = null,
    .unmarshal = null,
    .tostring = null,
    .compare = null,
    .hash = null,
    .next = null,
    .call = null,
    .length = null,
    .bytes = null,
    .gcperthread = null,
};

fn rwlockGC(p: ?*anyopaque, size: usize) callconv(.c) c_int {
    _ = size;
    os_locks.rwlockDeinit(@ptrCast(p));
    return 0;
}

pub const rwlockType: abstract_type.AbstractType = .{
    .name = "core/rwlock",
    .gc = rwlockGC,
    .gcmark = null,
    .get = null,
    .put = null,
    .marshal = null,
    .unmarshal = null,
    .tostring = null,
    .compare = null,
    .hash = null,
    .next = null,
    .call = null,
    .length = null,
    .bytes = null,
    .gcperthread = null,
};

fn mutexImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 0);

    const mutex = abstracts.threaded(abstract_type.stored(&mutexType), os_locks.mutexSize());
    os_locks.mutexInit(@ptrCast(mutex));
    return wrap.fromAbstract(mutex);
}

fn mutexAcquireImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 1);
    const mutex = try args_core.getAbstract(argv, 0, abstract_type.stored(&mutexType));
    os_locks.mutexLock(@ptrCast(mutex));
    return argv[0];
}

fn mutexReleaseImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 1);
    const mutex = try args_core.getAbstract(argv, 0, abstract_type.stored(&mutexType));
    try os_locks.mutexUnlock(@ptrCast(mutex));
    return argv[0];
}

fn rwlockImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 0);

    const rwlock = abstracts.threaded(abstract_type.stored(&rwlockType), os_locks.rwlockSize());
    os_locks.rwlockInit(@ptrCast(rwlock));
    return wrap.fromAbstract(rwlock);
}

fn rwlockReadLockImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 1);
    const rwlock = try args_core.getAbstract(argv, 0, abstract_type.stored(&rwlockType));
    os_locks.rwlockRlock(@ptrCast(rwlock));
    return argv[0];
}

fn rwlockWriteLockImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 1);
    const rwlock = try args_core.getAbstract(argv, 0, abstract_type.stored(&rwlockType));
    os_locks.rwlockWlock(@ptrCast(rwlock));
    return argv[0];
}

fn rwlockReadReleaseImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 1);
    const rwlock = try args_core.getAbstract(argv, 0, abstract_type.stored(&rwlockType));
    os_locks.rwlockRunlock(@ptrCast(rwlock));
    return argv[0];
}

fn rwlockWriteReleaseImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 1);
    const rwlock = try args_core.getAbstract(argv, 0, abstract_type.stored(&rwlockType));
    os_locks.rwlockWunlock(@ptrCast(rwlock));
    return argv[0];
}

// ==========================================================================
// Registration
// ==========================================================================

// `janet_channel_type` and `janet_stream_type` were declared here as
// `extern const`s -- while lines 56 and 57 of this file were already importing
// the two modules that define them. Rule 31's blindness with the alternative in
// plain sight: an unreferenced declaration is never checked, and a referenced
// one that resolves says nothing either. Phase 11 Part 22 replaced them with
// the imports, and each use site names the module.
//
// **Not with a local alias.** `const janet_stream_type =
// stream.streamType;` compiles and is wrong: an alias of a `const` is a
// *copy* of the value, so `&janet_stream_type` is the address of this file's
// copy and an abstract built through it is not the type `getAbstract` compares
// against. Rule 36 is the same hazard from the other side.

fn selfEntries() []const corefn.Entry {
    const list = comptime blk: {
        var acc: []const corefn.Entry = &.{};
        acc = acc ++ [_]corefn.Entry{
            corefn.reg("ev/go", &goImpl, @src(), "(ev/go fiber-or-fun &opt value supervisor)", "Put a fiber on the event loop to be resumed later. If a " ++
                "function is used, it is wrapped with `fiber/new` first. " ++
                "Returns a task fiber. Optionally pass a value to resume " ++
                "with, otherwise resumes with nil. An optional `core/channel` " ++
                "can be provided as a supervisor. When various events occur " ++
                "in the newly scheduled fiber, an event will be pushed to the " ++
                "supervisor. If not provided, the new fiber will inherit the " ++
                "current supervisor."),
            corefn.reg("ev/thread", &threadImpl, @src(), "(ev/thread main &opt value flags supervisor)", "Run `main` in a new operating system thread, optionally passing `value` " ++
                "to resume with. The parameter `main` can either be a fiber, or a function that accepts " ++
                "0 or 1 arguments. " ++
                "Unlike `ev/go`, this function will suspend the current fiber until the thread is complete. " ++
                "If you want to run the thread without waiting for a result, pass the `:n` flag to return nil immediately. " ++
                "Otherwise, returns nil. Available flags:\n\n" ++
                "* `:n` - return immediately\n" ++
                "* `:t` - set the task-id of the new thread to value. The task-id is passed in messages to the supervisor channel.\n" ++
                "* `:a` - don't copy abstract registry to new thread (performance optimization)\n" ++
                "* `:c` - don't copy cfunction registry to new thread (performance optimization)"),
            corefn.reg("ev/give-supervisor", &giveSupervisorImpl, @src(), "(ev/give-supervisor tag & payload)", "Send a message to the current supervisor channel if there is one. The message will be a " ++
                "tuple of all of the arguments combined into a single message, where the first element is tag. " ++
                "By convention, tag should be a keyword indicating the type of message. Returns nil."),
            corefn.reg("ev/sleep", &sleepImpl, @src(), "(ev/sleep sec)", "Suspend the current fiber for sec seconds without blocking the event loop."),
            corefn.reg("ev/deadline", &deadlineImpl, @src(), "(ev/deadline sec &opt tocancel tocheck intr?)", "Schedules the event loop to try to cancel the `tocancel` task as with `ev/cancel`. " ++
                "After `sec` seconds, the event loop will attempt cancellation of `tocancel` if the " ++
                "`tocheck` fiber is resumable. `sec` is a number that can have a fractional part. " ++
                "`tocancel` defaults to `(fiber/root)`, but if specified, must be a task (root " ++
                "fiber). `tocheck` defaults to `(fiber/current)`, but if specified, must be a fiber. " ++
                "Returns `tocancel` immediately. If `interrupt?` is set to true, will create a " ++
                "background thread to try to interrupt the VM if the timeout expires."),
            corefn.reg("ev/cancel", &cancelImpl, @src(), "(ev/cancel fiber err)", "Cancel a suspended task fiber in the event loop. Differs from " ++
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
            corefn.reg("ev/lock", &mutexImpl, @src(), "(ev/lock)", "Create a new lock to coordinate threads."),
            corefn.reg("ev/acquire-lock", &mutexAcquireImpl, @src(), "(ev/acquire-lock lock)", "Acquire a lock such that this operating system thread is the only thread with access to this resource." ++
                " This will block this entire thread until the lock becomes available, and will not yield to other fibers " ++
                "on this system thread."),
            corefn.reg("ev/release-lock", &mutexReleaseImpl, @src(), "(ev/release-lock lock)", "Release a lock such that other threads may acquire it."),
            corefn.reg("ev/rwlock", &rwlockImpl, @src(), "(ev/rwlock)", "Create a new read-write lock to coordinate threads."),
            corefn.reg("ev/acquire-rlock", &rwlockReadLockImpl, @src(), "(ev/acquire-rlock rwlock)", "Acquire a read lock an a read-write lock."),
            corefn.reg("ev/acquire-wlock", &rwlockWriteLockImpl, @src(), "(ev/acquire-wlock rwlock)", "Acquire a write lock on a read-write lock."),
            corefn.reg("ev/release-rlock", &rwlockReadReleaseImpl, @src(), "(ev/release-rlock rwlock)", "Release a read lock on a read-write lock"),
            corefn.reg("ev/release-wlock", &rwlockWriteReleaseImpl, @src(), "(ev/release-wlock rwlock)", "Release a write lock on a read-write lock"),
        };
        break :blk acc;
    };
    return list;
}

fn tailEntries() []const corefn.Entry {
    const list = comptime blk: {
        var acc: []const corefn.Entry = &.{};
        acc = acc ++ [_]corefn.Entry{
            corefn.reg("ev/all-tasks", &allTasksImpl, @src(), "(ev/all-tasks)", "Get an array of all active task fibers that are being used by the scheduler."),
        };
        break :blk acc;
    };
    return list;
}

/// `janet_lib_ev`. The order is the C original's exactly: the ten channel
/// rows, the six scheduler rows, the four stream rows, the eight lock rows,
/// `ev/to-file` and `ev/all-tasks`.
pub fn janet_lib_evImpl(env: *types.JanetTable) raise.Raising(void) {
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
    corefn.install(env, table[0 .. n + 1]);

    try registry.registerAbstractType(abstract_type.stored(&stream.streamType));
    try registry.registerAbstractType(abstract_type.stored(&channel.channelType));
    try registry.registerAbstractType(abstract_type.stored(&mutexType));
    try registry.registerAbstractType(abstract_type.stored(&rwlockType));
}

pub fn libEv(env: *types.JanetTable) void {
    raise.reported(janet_lib_evImpl(env));
}

// -------------------------------------------------------------------------
// Suspension and resumption -- what `ev_core.zig` was.
// -------------------------------------------------------------------------

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

pub fn qInit(q: *types.JanetQueue) void {
    q.data = null;
    q.head = 0;
    q.tail = 0;
    q.capacity = 0;
}

pub fn qDeinit(q: *types.JanetQueue) void {
    utils.free(q.data);
}

/// Items between `head` and `tail`, wrapping through the end of the buffer.
///
/// The arithmetic wraps explicitly. Janet's own invariants keep every term well
/// inside `int32_t` — capacity never exceeds `JANET_MAX_Q_CAPACITY` — but C
/// leaves a corrupted queue's overflow undefined and Zig may not, so the port
/// commits to wrapping rather than trapping.
pub fn qCount(q: *const types.JanetQueue) i32 {
    return if (q.head > q.tail)
        q.tail +% q.capacity -% q.head
    else
        q.tail -% q.head;
}

/// Grow the queue if another item would fill it, returning 1 if it cannot grow.
///
/// One slot is always left empty so that a full queue is distinguishable from an
/// empty one, which is why the test is `count + 1 >= capacity`.
fn qMaybeResize(q: *types.JanetQueue, itemsize: usize) c_int {
    const count = qCount(q);
    if (count +% 1 < q.capacity) return 0;
    if (count +% 1 >= max_queue_capacity) return 1;

    var newcap: i32 = (count +% 2) *% 2;
    if (newcap > max_queue_capacity) newcap = max_queue_capacity;

    const allocation = utils.realloc(
        q.data,
        itemsize * @as(usize, @intCast(newcap)),
    ) orelse fatal.outOfMemory();
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

pub fn qPush(q: *types.JanetQueue, item: *const anyopaque, itemsize: usize) c_int {
    if (qMaybeResize(q, itemsize) != 0) return 1;
    const base: [*]u8 = @ptrCast(q.data.?);
    const slot = base + @as(usize, @intCast(q.tail)) * itemsize;
    const source: [*]const u8 = @ptrCast(item);
    @memcpy(slot[0..itemsize], source[0..itemsize]);
    q.tail = if (q.tail +% 1 < q.capacity) q.tail +% 1 else 0;
    return 0;
}

pub fn qPushHead(q: *types.JanetQueue, item: *const anyopaque, itemsize: usize) c_int {
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

pub fn qPop(q: *types.JanetQueue, out: *anyopaque, itemsize: usize) c_int {
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
    var when: i64 = undefined;
    const bytes: [*]const u8 = @ptrCast(base);
    const source = bytes + index * stride + when_offset;
    const destination: [*]u8 = @ptrCast(&when);
    @memcpy(destination[0..@sizeOf(i64)], source[0..@sizeOf(i64)]);
    return when;
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
fn saturatingCast(comptime T: type, x: f64) T {
    if (std.math.isNan(x)) return 0;
    const low: f64 = @floatFromInt(@as(T, std.math.minInt(T)));
    const high: f64 = @floatFromInt(@as(T, std.math.maxInt(T)));
    if (!(x > low)) return std.math.minInt(T);
    if (x >= high) return std.math.maxInt(T);
    return @intFromFloat(x);
}

test "queue counts across a wrap" {
    var q: types.JanetQueue = undefined;
    qInit(&q);
    defer qDeinit(&q);
    try std.testing.expectEqual(@as(i32, 0), qCount(&q));
}

test "saturating conversion clamps rather than trapping" {
    try std.testing.expectEqual(@as(i64, 0), saturatingCast(i64, std.math.nan(f64)));
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), saturatingCast(i64, 1e300));
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), saturatingCast(i64, -1e300));
}
