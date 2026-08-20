//! `ev.c`: the event loop, the scheduler, the timeout heap, the three POSIX
//! backends and the Windows completion port, channels, streams, the read and
//! write state machines, and the thirty `ev/` cfunctions. This is Phase 10
//! Part 13.
//!
//! ## Four files, one object, and why they are not four modules
//!
//! `-Dpp` and `-Dos-surface` fold several sources into one object by making
//! each a module and importing one from another. That shape needs a directed
//! acyclic graph and this subsystem does not have one: the backend steps a
//! stream's callbacks, a stream's callbacks schedule a fiber, the scheduler
//! polls the backend, and a channel wakes a fiber that a stream is waiting on.
//! `ev.c` is one translation unit for that reason. So this object is **one
//! module rooted here**, and `ev_stream.zig`, `ev_channel.zig` and
//! `ev_backend.zig` are ordinary file imports inside it, which Zig allows to
//! be cyclic where module imports may not.
//!
//! ## The second `setjmp`, and what finally let it go
//!
//! Part 13 left nine lines in `ev.c` and a rule that explains them: **a
//! protected scope can stop being a `setjmp` only when every raise that can
//! reach it is already a Zig error.** The scope is the one `ev/thread`'s child
//! runs under, and `janet_go_thread_subr` reaches `janet_unmarshal` four times
//! inside it. `janet_unmarshal` was another subsystem behind another selector,
//! Part 4's rule made that seam the C ABI, and a raise across it was a jump --
//! so deleting the scope would have removed the catcher rather than the jump.
//!
//! What changed is not this file. Part 17a folded the subsystems into one
//! module, after which those four calls are ordinary Zig imports whose raise
//! is an error; the hinge then converted the last fixed function-pointer types
//! that stood between them and here. `goThreadProtect` below is what is left
//! of the shim, and the comment on it says what the `setjmp` was actually
//! doing -- which was travel, not catching.
//!
//! ## The backends
//!
//! Four of them, selected at comptime in `ev_backend.zig`, and only one is
//! analysed per target. The selection follows the translation's own answer
//! (`JANET_EV_EPOLL`, `JANET_EV_KQUEUE`) rather than a fresh derivation,
//! because that is what fixed `JanetVM`'s translated layout: reading the arm
//! `state.h` took and then compiling a different one is the fault Part 12
//! found in `janet.h`'s platform chain, arriving from the other side.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi");
const corefn = @import("corefn");
const raise = @import("raise");
const stdio = @import("stdio.zig");
const io_core = @import("io_core.zig");
const pp_format = @import("pp_format.zig");
const registration = @import("registration.zig");
const ev_callback = @import("ev_callback.zig");

pub const backend = @import("ev_backend.zig");
pub const channel = @import("ev_channel.zig");
pub const stream = @import("ev_stream.zig");

// The two entry points `subsystems/evloop.zig` presents that live in this
// selector's other files. Re-exported here because a façade names one module
// and `-Dev-loop` is one selector over four.
pub const streamFlags = stream.streamFlags;
pub const streamClose = stream.streamClose;
pub const evInit = backend.evInit;
pub const edgeTriggeredStream = backend.edgeTriggeredStream;
pub const levelTriggeredStream = backend.levelTriggeredStream;
pub const getChannel = channel.getChannel;
pub const channelGive = channel.channelGive;

pub const c = abi.c;
const trace_frames = @import("trace_frames.zig");
const lifecycle = @import("lifecycle.zig");
const containers = @import("containers.zig");
const arglayer = @import("arglayer.zig");
const marsh = @import("marsh.zig");
const abstract_type = @import("abstract_type.zig");

pub const windows = builtin.os.tag == .windows;

/// `JANET_ANDROID`. `janet.h` derives it from `__ANDROID__`, which is a
/// compiler predefine -- the class Part 12 found unreliable through
/// `@cImport` -- so the platform is read from `builtin` and the janetconf
/// macro is not consulted.
pub const android = builtin.abi.isAndroid();

/// `JANET_NET`, restated with a value in `state_abi.h` because translate-c
/// surfaces a macro's value and this one has none.
pub const has_net = c.JANET_VM_HAS_NET != 0;

/// `JANET_NO_INTERPRETER_INTERRUPT`, restated the same way.
pub const has_interrupt = c.JANET_VM_HAS_INTERRUPT != 0;

// ==========================================================================
// The C ABI this subsystem reaches through
// ==========================================================================

/// The portable kernels, behind `-Dev-core`. They keep their C ABI here
/// exactly as they had it in `ev.c`: this increment moves the callers and
/// leaves that seam where Phase 8 drew it, so `-Dev-core=c` still swaps the
/// queue and the heap ordering under a Zig scheduler.
pub extern fn janet_ev_q_init(q: *c.JanetQueue) callconv(.c) void;
pub extern fn janet_ev_q_deinit(q: *c.JanetQueue) callconv(.c) void;
pub extern fn janet_ev_q_count(q: *const c.JanetQueue) callconv(.c) i32;
pub extern fn janet_ev_q_push(q: *c.JanetQueue, item: *const anyopaque, itemsize: usize) callconv(.c) c_int;
pub extern fn janet_ev_q_push_head(q: *c.JanetQueue, item: *const anyopaque, itemsize: usize) callconv(.c) c_int;
pub extern fn janet_ev_q_pop(q: *c.JanetQueue, out: *anyopaque, itemsize: usize) callconv(.c) c_int;
pub extern fn janet_ev_heap_sift_down(base: *const anyopaque, stride: usize, when_offset: usize, count: usize, index: usize) callconv(.c) isize;
pub extern fn janet_ev_heap_sift_up(base: *const anyopaque, stride: usize, when_offset: usize, index: usize) callconv(.c) isize;
pub extern fn janet_ev_ts_delta(ts: c.JanetTimestamp, delta: f64) callconv(.c) c.JanetTimestamp;
pub extern fn janet_ev_ts_from_parts(sec: i64, nsec: i64) callconv(.c) c.JanetTimestamp;
pub extern fn janet_ev_ts_to_parts(ts: c.JanetTimestamp, sec: *i64, nsec: *i64) callconv(.c) void;
pub extern fn janet_ev_kqueue_interval(ts: c.JanetTimestamp) callconv(.c) c.JanetTimestamp;

/// `src/core/util.h`. The clock arrives in parts because `struct timespec`
/// cannot be named portably from Zig; `os_time.zig` records the measurement
/// and `util.c` supplies this over either arm of `-Dos-time`.
pub extern fn janet_os_gettime(source: i32, sec: *i64, nsec: *i64) callconv(.c) i32;

/// `src/core/util.h`, which `abi.zig` deliberately does not translate.
pub extern fn janet_strerror(e: c_int) callconv(.c) [*c]const u8;

/// `src/core/util.h`. Only the read state machine's `recvfrom` arm names it,
/// and only under `JANET_NET`.
pub extern const janet_address_type: abstract_type.AbstractType;

pub inline fn vm() *c.JanetVM {
    return &c.janet_vm;
}

pub inline fn errno() c_int {
    return std.c._errno().*;
}

pub const sig_ok: c.JanetSignal = @intCast(c.JANET_SIGNAL_OK);
pub const sig_error: c.JanetSignal = @intCast(c.JANET_SIGNAL_ERROR);
pub const sig_event: c.JanetSignal = @intCast(c.JANET_SIGNAL_EVENT);
pub const sig_yield: c.JanetSignal = @intCast(c.JANET_SIGNAL_YIELD);
pub const sig_interrupt: c.JanetSignal = @intCast(c.JANET_SIGNAL_INTERRUPT);

/// `JANET_EXIT`, which `janet_assert` expands to and which `abi.zig` does not
/// translate. `io_core.zig` records what differs from the C original: the
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
extern fn fwrite(ptr: [*]const u8, size: usize, n: usize, stream_handle: ?*c.FILE) callconv(.c) usize;
extern fn abort() callconv(.c) noreturn;
extern fn exit(status: c_int) callconv(.c) noreturn;

/// `janet_eprintf`, which is a macro over `janet_dynprintf` and so does not
/// survive translation. `core_env.zig` writes it out the same way.
inline fn eprintf(comptime format: [:0]const u8, args: anytype) void {
    // `pp_format.dynprintf` can raise: `(dyn :err)` may be a Janet function, and
    // calling it can. This position cannot carry one -- it is a trace or a
    // diagnostic on the way out -- so the raise is reported exactly as the C
    // face reported it before Part 18 deleted the variadic.
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
pub inline fn wrapInteger(x: i32) c.Janet {
    return c.janet_wrap_number(@floatFromInt(x));
}

// ==========================================================================
// The timeout min heap
// ==========================================================================

/// `ts_now`. Each backend spelled this out after calling `janet_gettime`;
/// `ev_core.zig` took the arithmetic in Phase 8 and the Windows arm reads a
/// tick count instead of a clock.
pub fn tsNow() c.JanetTimestamp {
    if (windows) return @intCast(GetTickCount64());
    var sec: i64 = undefined;
    var nsec: i64 = undefined;
    assert(@src(), janet_os_gettime(1, &sec, &nsec) != -1, "failed to get time");
    return janet_ev_ts_from_parts(sec, nsec);
}

/// Look at the next timeout without removing it.
pub fn peekTimeout(out: *c.JanetTimeout) bool {
    if (vm().tq_count == 0) return false;
    out.* = vm().tq[0];
    return true;
}

/// Remove one timeout from the min heap and restore the heap property.
pub fn popTimeout(start: usize) void {
    var index = start;
    const v = vm();
    if (v.tq_count <= index) return;
    v.tq_count -= 1;
    v.tq[index] = v.tq[v.tq_count];
    while (true) {
        const smallest = janet_ev_heap_sift_down(
            v.tq,
            @sizeOf(c.JanetTimeout),
            @offsetOf(c.JanetTimeout, "when"),
            v.tq_count,
            index,
        );
        if (smallest < 0) return;
        const target: usize = @intCast(smallest);
        const temp = v.tq[index];
        v.tq[index] = v.tq[target];
        v.tq[target] = temp;
        index = target;
    }
}

/// Add a timeout to the min heap, growing it if it is full.
pub fn addTimeout(to: c.JanetTimeout) void {
    const v = vm();
    const oldcount = v.tq_count;
    const newcount = oldcount + 1;
    if (newcount > v.tq_capacity) {
        const newcap = 2 * newcount;
        const tq: [*c]c.JanetTimeout = @ptrCast(@alignCast(c.janet_realloc(
            v.tq,
            newcap * @sizeOf(c.JanetTimeout),
        )));
        if (tq == null) outOfMemory(@src());
        v.tq = tq;
        v.tq_capacity = newcap;
    }
    v.tq_count = newcount;
    v.tq[oldcount] = to;
    var index = oldcount;
    while (true) {
        const parent = janet_ev_heap_sift_up(
            v.tq,
            @sizeOf(c.JanetTimeout),
            @offsetOf(c.JanetTimeout, "when"),
            index,
        );
        if (parent < 0) break;
        const target: usize = @intCast(parent);
        const tmp = v.tq[index];
        v.tq[index] = v.tq[target];
        v.tq[target] = tmp;
        index = target;
    }
}

// ==========================================================================
// Scheduling
// ==========================================================================

/// Mirrors the anonymous `JanetTask` in `ev.c`.
pub const Task = extern struct {
    fiber: [*c]c.JanetFiber,
    value: c.Janet,
    sig: c.JanetSignal,
    /// If the fiber has been rescheduled this loop, don't run first scheduling.
    expected_sched_id: u32,
};

const fiber_flag_canceled: i32 = @intCast(c.JANET_FIBER_EV_FLAG_CANCELED);
const fiber_flag_suspended: i32 = @intCast(c.JANET_FIBER_EV_FLAG_SUSPENDED);
const fiber_flag_root: i32 = @intCast(c.JANET_FIBER_FLAG_ROOT);
const fiber_flag_in_flight: i32 = @intCast(c.JANET_FIBER_EV_FLAG_IN_FLIGHT);

fn scheduleGeneral(fiber: [*c]c.JanetFiber, value: c.Janet, sig: c.JanetSignal, soon: bool) void {
    if (fiber.*.gc.flags & fiber_flag_canceled != 0) return;
    if (fiber.*.gc.flags & fiber_flag_root == 0) {
        const task_element = c.janet_wrap_fiber(fiber);
        c.janet_table_put(&vm().active_tasks, task_element, c.janet_wrap_true());
    }
    fiber.*.sched_id +%= 1;
    const t: Task = .{
        .fiber = fiber,
        .value = value,
        .sig = sig,
        .expected_sched_id = fiber.*.sched_id,
    };
    fiber.*.gc.flags |= fiber_flag_root;
    if (sig == sig_error) fiber.*.gc.flags |= fiber_flag_canceled;
    const pushed = if (soon)
        janet_ev_q_push_head(&vm().spawn, &t, @sizeOf(Task))
    else
        janet_ev_q_push(&vm().spawn, &t, @sizeOf(Task));
    assert(@src(), pushed == 0, "schedule queue overflow");
}

pub export fn janet_schedule_signal(fiber: [*c]c.JanetFiber, value: c.Janet, sig: c.JanetSignal) callconv(.c) void {
    scheduleGeneral(fiber, value, sig, false);
}

pub export fn janet_schedule_soon(fiber: [*c]c.JanetFiber, value: c.Janet, sig: c.JanetSignal) callconv(.c) void {
    scheduleGeneral(fiber, value, sig, true);
}

pub fn cancel(fiber: [*c]c.JanetFiber, value: c.Janet) raise.Raising(void) {
    if (fiber.*.gc.flags & fiber_flag_root == 0) {
        return raise.panic("cannot cancel non-task fiber");
    }
    scheduleGeneral(fiber, value, sig_error, false);
}

export fn janet_cancel(fiber: [*c]c.JanetFiber, value: c.Janet) callconv(.c) void {
    raise.reported(cancel(fiber, value));
}

pub export fn janet_schedule(fiber: [*c]c.JanetFiber, value: c.Janet) callconv(.c) void {
    scheduleGeneral(fiber, value, sig_ok, false);
}

/// Mark every fiber and value the scheduler is holding on to.
export fn janet_ev_mark() callconv(.c) void {
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
        c.janet_mark(c.janet_wrap_fiber(v.tq[i].fiber));
        if (v.tq[i].curr_fiber != null) {
            c.janet_mark(c.janet_wrap_fiber(v.tq[i].curr_fiber));
        }
    }
}

inline fn markTask(t: *const Task) void {
    c.janet_mark(c.janet_wrap_fiber(t.fiber));
    c.janet_mark(t.value);
}

// ==========================================================================
// Async listeners on a stream
// ==========================================================================

/// Stop sending events to a fiber's callback and release what it held.
pub export fn janet_async_end(fiber: [*c]c.JanetFiber) callconv(.c) void {
    if (fiber.*.ev_callback) |cb| {
        if (fiber.*.ev_stream.*.read_fiber == fiber) fiber.*.ev_stream.*.read_fiber = null;
        if (fiber.*.ev_stream.*.write_fiber == fiber) fiber.*.ev_stream.*.write_fiber = null;
        ev_callback.dispatchTotal(ev_callback.of(cb), fiber, c.JANET_ASYNC_EVENT_DEINIT);
        _ = c.janet_gcunroot(c.janet_wrap_abstract(fiber.*.ev_stream));
        fiber.*.ev_callback = null;
        if (fiber.*.flags & fiber_flag_in_flight == 0) {
            if (fiber.*.ev_state) |state| {
                c.janet_free(state);
                fiber.*.ev_state = null;
            }
            janet_ev_dec_refcount();
        }
    }
}

/// Mark a fiber as waiting on a completion the port has not delivered yet.
/// A no-op away from Windows, where there is no in-flight state to track.
export fn janet_async_in_flight(fiber: [*c]c.JanetFiber) callconv(.c) void {
    if (windows) fiber.*.flags |= fiber_flag_in_flight;
}

pub fn asyncStartFiber(
    fiber: [*c]c.JanetFiber,
    s: *c.JanetStream,
    mode: c.JanetAsyncMode,
    callback: ev_callback.EVCallback,
    state: ?*anyopaque,
) raise.Raising(void) {
    assert(@src(), fiber.*.ev_callback == null, "double async on fiber");
    if (mode & c.JANET_ASYNC_LISTEN_READ != 0) s.read_fiber = fiber;
    if (mode & c.JANET_ASYNC_LISTEN_WRITE != 0) s.write_fiber = fiber;
    fiber.*.ev_callback = ev_callback.stored(callback);
    fiber.*.ev_stream = s;
    janet_ev_inc_refcount();
    c.janet_gcroot(c.janet_wrap_abstract(s));
    fiber.*.ev_state = state;
    try callback(fiber, c.JANET_ASYNC_EVENT_INIT);
}

export fn janet_async_start_fiber(
    fiber: [*c]c.JanetFiber,
    s: *c.JanetStream,
    mode: c.JanetAsyncMode,
    callback: c.JanetEVCallback,
    state: ?*anyopaque,
) callconv(.c) void {
    raise.reported(asyncStartFiber(fiber, s, mode, ev_callback.of(callback), state));
}

pub fn asyncStart(
    s: *c.JanetStream,
    mode: c.JanetAsyncMode,
    callback: ev_callback.EVCallback,
    state: ?*anyopaque,
) raise.Error {
    asyncStartFiber(vm().root_fiber, s, mode, callback, state) catch |err| return err;
    return awaitEvent();
}

export fn janet_async_start(
    s: *c.JanetStream,
    mode: c.JanetAsyncMode,
    callback: c.JanetEVCallback,
    state: ?*anyopaque,
) callconv(.c) void {
    raise.report(asyncStart(s, mode, ev_callback.of(callback), state));
}

export fn janet_fiber_did_resume(fiber: [*c]c.JanetFiber) callconv(.c) void {
    janet_async_end(fiber);
}

// ==========================================================================
// Init, deinit, and the reference count that keeps the loop alive
// ==========================================================================

pub export fn janet_ev_inc_refcount() callconv(.c) void {
    _ = c.janet_atomic_inc(&vm().listener_count);
}

pub export fn janet_ev_dec_refcount() callconv(.c) void {
    _ = c.janet_atomic_dec(&vm().listener_count);
}

pub export fn janet_ev_init_common() callconv(.c) void {
    const v = vm();
    janet_ev_q_init(&v.spawn);
    v.tq = null;
    v.tq_count = 0;
    v.tq_capacity = 0;
    _ = c.janet_table_init_raw(&v.threaded_abstracts, 0);
    _ = c.janet_table_init_raw(&v.active_tasks, 0);
    _ = c.janet_table_init_raw(&v.signal_handlers, 0);
    c.janet_rng_seed(&v.ev_rng, 0);
    if (!windows) {
        _ = pthread_attr_init(&v.new_thread_attr);
        _ = pthread_attr_setdetachstate(&v.new_thread_attr, PTHREAD_CREATE_DETACHED);
    }
}

pub export fn janet_ev_deinit_common() callconv(.c) void {
    const v = vm();
    var to: c.JanetTimeout = undefined;
    while (peekTimeout(&to)) {
        handleTimeoutWorker(to, true);
        popTimeout(0);
    }
    janet_ev_q_deinit(&v.spawn);
    c.janet_free(v.tq);
    c.janet_table_deinit(&v.threaded_abstracts);
    c.janet_table_deinit(&v.active_tasks);
    c.janet_table_deinit(&v.signal_handlers);
    if (!windows) _ = pthread_attr_destroy(&v.new_thread_attr);
}

// ==========================================================================
// Yielding to the loop, and the timeouts a fiber can set on itself
// ==========================================================================

/// `janet_await`. The Zig face: yielding to the event loop is a raise with the
/// `EVENT` signal, and always has been -- what changes here is that it returns
/// instead of jumping.
pub fn awaitEvent() raise.Error {
    return raise.signal(sig_event, c.janet_wrap_nil());
}

export fn janet_await() callconv(.c) void {
    raise.report(awaitEvent());
}

fn addFiberTimeout(sec: f64, is_error: bool) void {
    const fiber = vm().root_fiber;
    addTimeout(.{
        .when = janet_ev_ts_delta(tsNow(), sec),
        .fiber = fiber,
        .curr_fiber = null,
        .sched_id = fiber.*.sched_id,
        .is_error = @intFromBool(is_error),
        .has_worker = 0,
        .worker = std.mem.zeroes(@FieldType(c.JanetTimeout, "worker")),
    });
}

pub export fn janet_addtimeout(sec: f64) callconv(.c) void {
    addFiberTimeout(sec, true);
}

pub export fn janet_addtimeout_nil(sec: f64) callconv(.c) void {
    addFiberTimeout(sec, false);
}

pub fn sleepAwait(sec: f64) raise.Error {
    const fiber = vm().root_fiber;
    addTimeout(.{
        .when = janet_ev_ts_delta(tsNow(), sec),
        .fiber = fiber,
        .curr_fiber = null,
        .sched_id = fiber.*.sched_id,
        .is_error = 0,
        .has_worker = 0,
        .worker = std.mem.zeroes(@FieldType(c.JanetTimeout, "worker")),
    });
    return awaitEvent();
}

export fn janet_sleep_await(sec: f64) callconv(.c) void {
    raise.report(sleepAwait(sec));
}

// ==========================================================================
// The deadline worker thread
// ==========================================================================

/// Mirrors the anonymous `JanetThreadedTimeout` in `ev.c`.
const ThreadedTimeout = extern struct {
    sec: f64,
    vm_ptr: *c.JanetVM,
    fiber: [*c]c.JanetFiber,
    cancel_event: if (windows) ?*anyopaque else void = if (windows) null else {},
};

fn timeoutCallback(msg: c.JanetEVGenericMessage) callconv(.c) void {
    _ = msg;
    c.janet_interpreter_interrupt_handled(vm());
}

/// Join, and optionally interrupt, the thread a `(ev/deadline ... true)` set
/// running. `has_worker` is false for every other kind of timeout.
fn handleTimeoutWorker(to: c.JanetTimeout, cancel_it: bool) void {
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
/// replaced. `os_abi.zig` makes the same call for `JANET_THREADS`.
fn timeoutBodyPosix(ptr: ?*anyopaque) callconv(.c) ?*anyopaque {
    const tto: *ThreadedTimeout = @ptrCast(@alignCast(ptr));
    const copy = tto.*;
    c.janet_free(ptr);
    var ts: std.c.timespec = .{
        .sec = @intFromFloat(copy.sec),
        .nsec = if (copy.sec <= @as(f64, std.math.maxInt(u32)))
            @intFromFloat((copy.sec - @as(f64, @floatFromInt(@as(u32, @intFromFloat(copy.sec))))) * 1000000000)
        else
            0,
    };
    _ = std.c.nanosleep(&ts, &ts);
    c.janet_interpreter_interrupt(copy.vm_ptr);
    const msg = std.mem.zeroes(c.JanetEVGenericMessage);
    janet_ev_post_event(copy.vm_ptr, timeoutCallback, msg);
    return null;
}

fn timeoutBodyWindows(ptr: ?*anyopaque) callconv(.winapi) u32 {
    const tto: *ThreadedTimeout = @ptrCast(@alignCast(ptr));
    const copy = tto.*;
    c.janet_free(ptr);
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
        c.janet_interpreter_interrupt(copy.vm_ptr);
        const msg = std.mem.zeroes(c.JanetEVGenericMessage);
        janet_ev_post_event(copy.vm_ptr, timeoutCallback, msg);
    }
    return 0;
}

// ==========================================================================
// The main loop
// ==========================================================================

export fn janet_loop_done() callconv(.c) c_int {
    const v = vm();
    const busy = (v.spawn.head != v.spawn.tail) or
        (v.tq_count != 0) or
        (c.janet_atomic_load(&v.listener_count) != 0);
    return @intFromBool(!busy);
}

/// One turn of the loop: expired timers, then runnable fibers, then a poll.
///
/// Returns the fiber an interrupt stopped, or null. The C original's three
/// stages are preserved exactly, including that the poll is skipped when the
/// timer scan drained the heap.
pub fn loop1() raise.Raising([*c]c.JanetFiber) {
    const v = vm();

    // Schedule expired timers.
    var to: c.JanetTimeout = undefined;
    const now = tsNow();
    while (peekTimeout(&to) and to.when <= now) {
        popTimeout(0);
        if (to.curr_fiber != null) {
            if (c.janet_fiber_can_resume(to.curr_fiber) != 0) {
                // The fiber is a task, so this cannot raise.
                try cancel(to.fiber, c.janet_cstringv("deadline expired"));
            }
        } else if (to.fiber.*.sched_id == to.sched_id) {
            // A timeout on a call rather than on a whole fiber.
            if (to.is_error != 0) {
                try cancel(to.fiber, c.janet_cstringv("timeout"));
            } else {
                janet_schedule(to.fiber, c.janet_wrap_nil());
            }
        }
        handleTimeoutWorker(to, false);
    }

    // Run scheduled fibers unless interrupts need to be handled.
    while (v.spawn.head != v.spawn.tail) {
        if (c.janet_atomic_load_relaxed(&v.auto_suspend) != 0) break;
        var task: Task = .{
            .fiber = null,
            .value = c.janet_wrap_nil(),
            .sig = sig_ok,
            .expected_sched_id = 0,
        };
        _ = janet_ev_q_pop(&v.spawn, &task, @sizeOf(Task));
        if (task.fiber.*.gc.flags & fiber_flag_suspended != 0) janet_ev_dec_refcount();
        task.fiber.*.gc.flags &= ~(fiber_flag_canceled | fiber_flag_suspended);
        if (task.expected_sched_id != task.fiber.*.sched_id) continue;
        var res: c.Janet = undefined;
        const sig = c.janet_continue_signal(task.fiber, task.value, &res, task.sig);
        if (c.janet_fiber_can_resume(task.fiber) == 0) {
            _ = c.janet_table_remove(&v.active_tasks, c.janet_wrap_fiber(task.fiber));
        }
        const sv = task.fiber.*.supervisor_channel;
        const is_suspended = sig == sig_event or sig == sig_yield or sig == sig_interrupt;
        if (is_suspended) {
            task.fiber.*.gc.flags |= fiber_flag_suspended;
            janet_ev_inc_refcount();
        }
        if (sv == null) {
            if (!is_suspended) try trace_frames.stacktraceExt(task.fiber, res, "");
        } else if (sig == sig_ok or (task.fiber.*.flags & (@as(i32, 1) << @intCast(sig)) != 0)) {
            const chan = channel.unwrap(sv);
            const event = channel.makeSupervisorEvent(
                c.janet_signal_names[@intCast(sig)],
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
    if (v.tq_count != 0 or c.janet_atomic_load(&v.listener_count) != 0) {
        var next: c.JanetTimeout = std.mem.zeroes(c.JanetTimeout);
        var has_timeout = false;
        // Drop timeouts that are no longer needed.
        while (true) {
            has_timeout = peekTimeout(&next);
            if (!has_timeout) break;
            if (next.curr_fiber != null) {
                if (c.janet_fiber_can_resume(next.curr_fiber) == 0) {
                    popTimeout(0);
                    _ = c.janet_table_remove(&v.active_tasks, c.janet_wrap_fiber(next.curr_fiber));
                    handleTimeoutWorker(next, true);
                    continue;
                }
            } else if (next.fiber.*.sched_id != next.sched_id) {
                popTimeout(0);
                handleTimeoutWorker(next, true);
                continue;
            }
            break;
        }
        if (v.tq_count != 0 or c.janet_atomic_load(&v.listener_count) != 0) {
            try backend.loop1Impl(has_timeout, next.when);
        }
    }

    return null;
}

export fn janet_loop1() callconv(.c) [*c]c.JanetFiber {
    return raise.reported(loop1());
}

/// `janet_interpreter_interrupt`, plus an empty event so that a loop blocked
/// in the backend wakes up to see it.
export fn janet_loop1_interrupt(v: *c.JanetVM) callconv(.c) void {
    c.janet_interpreter_interrupt(v);
    const msg = std.mem.zeroes(c.JanetEVGenericMessage);
    janet_ev_post_event(v, null, msg);
}

pub fn loop() raise.Raising(void) {
    while (janet_loop_done() == 0) {
        const interrupted = try loop1();
        if (interrupted != null) janet_schedule(interrupted, c.janet_wrap_nil());
    }
}

export fn janet_loop() callconv(.c) void {
    raise.reported(loop());
}

// ==========================================================================
// Posting an event from another thread, and threaded calls
// ==========================================================================

/// Mirrors the anonymous `JanetSelfPipeEvent` in `ev.c`, and is the head of
/// `ThreadInit` below.
pub const SelfPipeEvent = extern struct {
    msg: c.JanetEVGenericMessage,
    cb: c.JanetThreadedCallback,
};

/// Mirrors the anonymous `JanetEVThreadInit` in `ev.c`. The first two fields
/// are `SelfPipeEvent`'s, deliberately: the Windows arm reuses the allocation
/// as the reply.
const ThreadInit = extern struct {
    msg: c.JanetEVGenericMessage,
    cb: c.JanetThreadedCallback,
    subr: c.JanetThreadedSubroutine,
    write_pipe: c.JanetHandle,
};

pub export fn janet_ev_post_event(
    target: ?*c.JanetVM,
    cb: c.JanetCallback,
    msg: c.JanetEVGenericMessage,
) callconv(.c) void {
    const v = target orelse vm();
    _ = c.janet_atomic_inc(&v.listener_count);
    if (windows) {
        const iocp: ?*anyopaque = @ptrCast(v.iocp);
        const event: *SelfPipeEvent = @ptrCast(@alignCast(c.janet_malloc(@sizeOf(SelfPipeEvent)) orelse
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
    c.janet_free(ptr);
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
    fp: c.JanetThreadedSubroutine,
    arguments: c.JanetEVGenericMessage,
    cb: c.JanetThreadedCallback,
) raise.Raising(void) {
    const init: *ThreadInit = @ptrCast(@alignCast(c.janet_malloc(@sizeOf(ThreadInit)) orelse
        outOfMemory(@src())));
    init.msg = arguments;
    init.subr = fp;
    init.cb = cb;

    if (windows) {
        init.write_pipe = iocpHandle();
        const thread_handle = CreateThread(null, 0, threadBodyWindows, init, 0, null);
        if (thread_handle == null) {
            c.janet_free(init);
            return raise.panic("failed to create thread");
        }
        _ = CloseHandle(thread_handle); // detach from thread
    } else {
        init.write_pipe = vm().selfpipe[1];
        var waiter_thread: c.pthread_t = undefined;
        const err = pthread_create(&waiter_thread, &vm().new_thread_attr, threadBodyPosix, init);
        if (err != 0) {
            c.janet_free(init);
            return pp_format.panicf("%s", .{janet_strerror(err)});
        }
    }

    // Increment ev refcount so we don't quit while waiting for a subprocess.
    janet_ev_inc_refcount();
}

export fn janet_ev_threaded_call(
    fp: c.JanetThreadedSubroutine,
    arguments: c.JanetEVGenericMessage,
    cb: c.JanetThreadedCallback,
) callconv(.c) void {
    raise.reported(threadedCall(fp, arguments, cb));
}

/// The default reply handler for `janet_ev_threaded_await`.
export fn janet_ev_default_threaded_callback(return_value: c.JanetEVGenericMessage) callconv(.c) void {
    if (return_value.fiber == null) {
        freeThreadedPayload(return_value);
        return;
    }
    if (c.janet_fiber_can_resume(return_value.fiber) != 0) {
        switch (return_value.tag) {
            c.JANET_EV_TCTAG_INTEGER => janet_schedule(return_value.fiber, wrapInteger(return_value.argi)),
            c.JANET_EV_TCTAG_STRING, c.JANET_EV_TCTAG_STRINGF => janet_schedule(
                return_value.fiber,
                c.janet_cstringv(payloadText(return_value)),
            ),
            c.JANET_EV_TCTAG_KEYWORD => janet_schedule(
                return_value.fiber,
                c.janet_ckeywordv(payloadText(return_value)),
            ),
            c.JANET_EV_TCTAG_ERR_STRING, c.JANET_EV_TCTAG_ERR_STRINGF => raise.reported(cancel(
                return_value.fiber,
                c.janet_cstringv(payloadText(return_value)),
            )),
            c.JANET_EV_TCTAG_ERR_KEYWORD => raise.reported(cancel(
                return_value.fiber,
                c.janet_ckeywordv(payloadText(return_value)),
            )),
            c.JANET_EV_TCTAG_BOOLEAN => janet_schedule(
                return_value.fiber,
                c.janet_wrap_boolean(return_value.argi),
            ),
            // JANET_EV_TCTAG_NIL, and every tag the C switch sends to
            // `default`, which is the same arm.
            else => janet_schedule(return_value.fiber, c.janet_wrap_nil()),
        }
    }
    freeThreadedPayload(return_value);
    _ = c.janet_gcunroot(c.janet_wrap_fiber(return_value.fiber));
}

inline fn payloadText(return_value: c.JanetEVGenericMessage) [*c]const u8 {
    return @ptrCast(return_value.argp);
}

/// The C original writes this cleanup switch twice, and both copies send
/// every tag but the two `*_STRINGF` ones to a `default` that also frees. So
/// the payload is freed for every tag; the two named cases are documentation
/// rather than a condition, and that is reproduced here.
inline fn freeThreadedPayload(return_value: c.JanetEVGenericMessage) void {
    c.janet_free(return_value.argp);
}

pub fn threadedAwait(fp: c.JanetThreadedSubroutine, tag: c_int, argi: c_int, argp: ?*anyopaque) raise.Error {
    var arguments = std.mem.zeroes(c.JanetEVGenericMessage);
    arguments.tag = tag;
    arguments.argi = argi;
    arguments.argp = argp;
    arguments.fiber = c.janet_root_fiber();
    c.janet_gcroot(c.janet_wrap_fiber(arguments.fiber));
    threadedCall(fp, arguments, janet_ev_default_threaded_callback) catch |err| return err;
    return awaitEvent();
}

export fn janet_ev_threaded_await(
    fp: c.JanetThreadedSubroutine,
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
// Declared rather than translated, on `abi.zig`'s rule: each takes primitive
// parameters or a type `abi.zig` already supplies, so no host layout is at
// stake and no second translation is needed. `c.pthread_t` and
// `c.pthread_attr_t` come from `state.h`, which includes `<pthread.h>` under
// `JANET_EV` and puts both in `JanetVM` and `JanetTimeout`.

pub extern fn write(fd: c_int, buf: [*]const u8, count: usize) callconv(.c) isize;
pub extern fn read(fd: c_int, buf: [*]u8, count: usize) callconv(.c) isize;
pub extern fn close(fd: c_int) callconv(.c) c_int;
pub extern fn sleep(seconds: c_uint) callconv(.c) c_uint;
pub extern fn pipe(fds: *[2]c_int) callconv(.c) c_int;
pub extern fn fcntl(fd: c_int, cmd: c_int, ...) callconv(.c) c_int;
pub extern fn dup(fd: c_int) callconv(.c) c_int;
pub extern fn fdopen(fd: c_int, mode: [*:0]const u8) callconv(.c) ?*anyopaque;

extern fn pthread_attr_init(attr: *c.pthread_attr_t) callconv(.c) c_int;
extern fn pthread_attr_destroy(attr: *c.pthread_attr_t) callconv(.c) c_int;
extern fn pthread_attr_setdetachstate(attr: *c.pthread_attr_t, state: c_int) callconv(.c) c_int;
extern fn pthread_create(
    thread: *c.pthread_t,
    attr: ?*const c.pthread_attr_t,
    start: *const fn (?*anyopaque) callconv(.c) ?*anyopaque,
    arg: ?*anyopaque,
) callconv(.c) c_int;
extern fn pthread_join(thread: c.pthread_t, res: *?*anyopaque) callconv(.c) c_int;
extern fn pthread_cancel(thread: c.pthread_t) callconv(.c) c_int;
extern fn pthread_kill(thread: c.pthread_t, sig: c_int) callconv(.c) c_int;
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
    return @ptrCast(c.janet_vm.iocp);
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
    args: c.JanetEVGenericMessage,
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
/// it. A report left by a C-ABI face inside the body is consumed at its own
/// call site by `raise.crossing`; one that is not is what the assertion in
/// `janet_restore` exists to name.
fn goThreadProtect(ctx: *GoThreadContext, payload: *c.Janet) c.JanetSignal {
    var tstate: c.JanetTryState = undefined;
    c.janet_try_init(&tstate);
    var signal: c.JanetSignal = 0;
    goThreadBodyImpl(ctx) catch {
        signal = vm().pending_signal;
    };
    c.janet_restore(&tstate);
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
            ctx.next,
            @intFromPtr(ctx.end) - @intFromPtr(ctx.next),
            c.JANET_MARSHAL_UNSAFE,
            null,
            @ptrCast(&ctx.next),
        );
        assert(@src(), c.janet_checktype(aregv, c.JANET_TABLE) != 0, "expected table for abstract registry");
        v.abstract_registry = c.janet_unwrap_table(aregv);
        c.janet_gcroot(c.janet_wrap_table(v.abstract_registry));
    }

    // Get supervisor.
    if (flags & thread_supervisor_flag != 0) {
        const sup = try marsh.unmarshal(
            ctx.next,
            @intFromPtr(ctx.end) - @intFromPtr(ctx.next),
            c.JANET_MARSHAL_UNSAFE,
            null,
            @ptrCast(&ctx.next),
        );
        // The C original calls this a hack to avoid longjmp clobber. It is
        // kept because `janet_vm.user` is where the failure arm reads the
        // supervisor from, and that arm still runs after a jump.
        v.user = c.janet_unwrap_pointer(sup);
    }

    // Set cfunction registry.
    if (flags & 0x4 == 0) {
        var count1: u32 = undefined;
        @memcpy(std.mem.asBytes(&count1), ctx.next[0..@sizeOf(u32)]);
        const count: usize = count1;
        const remaining = @intFromPtr(ctx.end) - @intFromPtr(ctx.next) - @sizeOf(u32);
        // Use division to avoid overflowing size_t.
        assert(@src(), count <= remaining / @sizeOf(c.JanetCFunRegistry), "thread message invalid");
        v.registry_count = count;
        v.registry_cap = count;
        v.registry = @ptrCast(@alignCast(c.janet_malloc(count * @sizeOf(c.JanetCFunRegistry)) orelse
            outOfMemory(@src())));
        v.registry_dirty = 1;
        ctx.next += @sizeOf(u32);
        @memcpy(
            @as([*]u8, @ptrCast(v.registry))[0 .. count * @sizeOf(c.JanetCFunRegistry)],
            ctx.next[0 .. count * @sizeOf(c.JanetCFunRegistry)],
        );
        ctx.next += count * @sizeOf(c.JanetCFunRegistry);
    }

    const fiberv = try marsh.unmarshal(
        ctx.next,
        @intFromPtr(ctx.end) - @intFromPtr(ctx.next),
        c.JANET_MARSHAL_UNSAFE,
        null,
        @ptrCast(&ctx.next),
    );
    const value = try marsh.unmarshal(
        ctx.next,
        @intFromPtr(ctx.end) - @intFromPtr(ctx.next),
        c.JANET_MARSHAL_UNSAFE,
        null,
        @ptrCast(&ctx.next),
    );

    var fiber: [*c]c.JanetFiber = undefined;
    if (c.janet_checktype(fiberv, c.JANET_FIBER) == 0) {
        assert(@src(), c.janet_checktype(fiberv, c.JANET_FUNCTION) != 0, "expected function or fiber");
        const func = c.janet_unwrap_function(fiberv);
        // The C original notes that an ordinary panic here misbehaves on
        // Wine + Mingw and asserts instead. The assert is kept.
        assert(
            @src(),
            func.*.def.*.min_arity >= 0 and func.*.def.*.min_arity <= 1,
            "thread function must accept 0 or 1 arguments",
        );
        var seed = value;
        fiber = c.janet_fiber(func, 64, func.*.def.*.min_arity, &seed);
        assert(@src(), fiber != null, "bad fiber in thread setup");
        fiber.*.flags |= @intCast(c.JANET_FIBER_MASK_ERROR |
            c.JANET_FIBER_MASK_USER0 |
            c.JANET_FIBER_MASK_USER1 |
            c.JANET_FIBER_MASK_USER2 |
            c.JANET_FIBER_MASK_USER3 |
            c.JANET_FIBER_MASK_USER4);
    } else {
        fiber = c.janet_unwrap_fiber(fiberv);
    }
    if (flags & 0x8 != 0) {
        if (fiber.*.env == null) fiber.*.env = c.janet_table(0);
        c.janet_table_put(fiber.*.env, c.janet_ckeywordv("task-id"), value);
    }
    fiber.*.supervisor_channel = v.user;
    janet_schedule(fiber, value);
    janet_loop();
    ctx.args.tag = c.JANET_EV_TCTAG_NIL;
}

/// The subroutine a new `ev/thread` runs on its own operating system thread:
/// a whole interpreter, from `janet_init` to `janet_deinit`.
fn goThreadSubr(args_in: c.JanetEVGenericMessage) callconv(.c) c.JanetEVGenericMessage {
    var args = args_in;
    const buffer: *c.JanetBuffer = @ptrCast(@alignCast(args.argp));
    const flags: u32 = @bitCast(args.tag);
    args.tag = 0;
    args.argp = null;
    // A thread subroutine's type is the event loop's, and this runs at the
    // very top of a new thread: there is no scope above it and no caller that
    // could act on a failure to initialise a VM.
    _ = raise.total(lifecycle.init(), "a thread subroutine's VM init");
    vm().sandbox_flags = @bitCast(args.argi);

    var ctx: GoThreadContext = .{
        .args = args,
        .flags = flags,
        .next = buffer.data,
        .end = buffer.data + @as(usize, @intCast(buffer.count)),
    };
    var payload: c.Janet = c.janet_wrap_nil();
    const signal = goThreadProtect(&ctx, &payload);
    args = ctx.args;

    if (signal != 0) {
        const supervisor = vm().user;
        if (supervisor != null) {
            // Got a supervisor, write the error there.
            const pair = [2]c.Janet{ c.janet_ckeywordv("error"), payload };
            // Reporting the thread's own start failure to its supervisor.
            // A raise here has nowhere left to go -- this *is* the error path.
            _ = raise.total(channel.push(
                channel.unwrap(supervisor),
                c.janet_wrap_tuple(c.janet_tuple_n(&pair, 2)),
                2,
            ), "a thread subroutine's supervisor report");
        } else if (flags & 0x1 != 0) {
            // No wait, just print to stderr.
            eprintf("thread start failure: %v\n", .{payload});
        } else {
            // Make the ev/thread call from the parent thread error.
            if (c.janet_checktype(payload, c.JANET_STRING) != 0) {
                args.tag = c.JANET_EV_TCTAG_ERR_STRINGF;
                const msg = c.janet_unwrap_string(payload);
                const len: usize = @intCast(c.janet_string_length(msg));
                args.argp = c.janet_malloc(len + 1);
                @memcpy(@as([*]u8, @ptrCast(args.argp))[0 .. len + 1], msg[0 .. len + 1]);
            } else {
                args.tag = c.JANET_EV_TCTAG_ERR_STRING;
                args.argp = @ptrCast(@constCast("failed to start thread"));
            }
        }
    }

    c.janet_buffer_deinit(buffer);
    c.janet_free(buffer);
    c.janet_deinit();
    return args;
}

// ==========================================================================
// The scheduler's cfunctions
// ==========================================================================

fn goImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 1, 3);
    const value = if (argc >= 2) argv[1] else c.janet_wrap_nil();
    const supervisor = try arglayer.optAbstract(
        argv,
        argc,
        2,
        abstract_type.stored(&janet_channel_type),
        vm().root_fiber.*.supervisor_channel,
    );
    var fiber: [*c]c.JanetFiber = undefined;
    if (c.janet_checktype(argv[0], c.JANET_FUNCTION) != 0) {
        // Create a fiber for the user.
        const func = c.janet_unwrap_function(argv[0]);
        if (func.*.def.*.min_arity > 1) {
            return pp_format.panicf("task function must accept 0 or 1 arguments", .{});
        }
        var seed = value;
        fiber = c.janet_fiber(func, 64, func.*.def.*.min_arity, &seed);
        fiber.*.flags |= @intCast(c.JANET_FIBER_MASK_ERROR |
            c.JANET_FIBER_MASK_USER0 |
            c.JANET_FIBER_MASK_USER1 |
            c.JANET_FIBER_MASK_USER2 |
            c.JANET_FIBER_MASK_USER3 |
            c.JANET_FIBER_MASK_USER4);
        if (vm().fiber.*.env == null) vm().fiber.*.env = c.janet_table(0);
        fiber.*.env = c.janet_table(0);
        fiber.*.env.*.proto = vm().fiber.*.env;
    } else {
        fiber = try arglayer.getFiber(argv, 0);
        if (c.janet_fiber_status(fiber) != c.JANET_STATUS_NEW) {
            return raise.panic("can only schedule new fibers where (= (fiber/status f) :new)");
        }
    }
    fiber.*.supervisor_channel = supervisor;
    janet_schedule(fiber, value);
    return c.janet_wrap_fiber(fiber);
}

fn threadImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try lifecycle.sandboxAssert(c.JANET_SANDBOX_THREADS);
    try arglayer.arity(argc, 1, 4);
    const value = if (argc >= 2) argv[1] else c.janet_wrap_nil();
    if (c.janet_checktype(argv[0], c.JANET_FUNCTION) != 0) {
        const func = try arglayer.getFunction(argv, 0);
        if (func.*.def.*.arity < 0 or func.*.def.*.min_arity > 1) {
            return raise.panic("function must take 0 or 1 arguments");
        }
    } else {
        _ = try arglayer.getFiber(argv, 0); // arg check for fiber
    }
    var flags: u64 = 0;
    if (argc >= 3) flags = try arglayer.getFlags(argv, 2, "nact");
    const supervisor = try arglayer.optAbstract(
        argv,
        argc,
        3,
        abstract_type.stored(&janet_channel_type),
        vm().root_fiber.*.supervisor_channel,
    );
    if (supervisor != null) flags |= thread_supervisor_flag;

    // Marshal arguments for the new thread.
    const buffer: *c.JanetBuffer = @ptrCast(@alignCast(c.janet_malloc(@sizeOf(c.JanetBuffer)) orelse
        outOfMemory(@src())));
    _ = c.janet_buffer_init(buffer, 0);
    if (flags & 0x2 == 0) {
        try marsh.marshal(buffer, c.janet_wrap_table(vm().abstract_registry), null, c.JANET_MARSHAL_UNSAFE);
    }
    if (flags & thread_supervisor_flag != 0) {
        try marsh.marshal(buffer, c.janet_wrap_abstract(supervisor), null, c.JANET_MARSHAL_UNSAFE);
    }
    if (flags & 0x4 == 0) {
        assert(@src(), vm().registry_count <= std.math.maxInt(i32), "assert failed size check");
        const temp: u32 = @intCast(vm().registry_count);
        _ = try containers.bufferPushBytes(buffer, @ptrCast(&temp), @sizeOf(u32));
        _ = try containers.bufferPushBytes(
            buffer,
            @ptrCast(vm().registry),
            @intCast(vm().registry_count * @sizeOf(c.JanetCFunRegistry)),
        );
    }
    try marsh.marshal(buffer, argv[0], null, c.JANET_MARSHAL_UNSAFE);
    try marsh.marshal(buffer, value, null, c.JANET_MARSHAL_UNSAFE);

    if (flags & 0x1 != 0) {
        // Return immediately.
        var arguments = std.mem.zeroes(c.JanetEVGenericMessage);
        arguments.tag = @bitCast(@as(u32, @truncate(flags)));
        arguments.argi = @bitCast(vm().sandbox_flags);
        arguments.argp = buffer;
        arguments.fiber = null;
        try threadedCall(goThreadSubr, arguments, janet_ev_default_threaded_callback);
        return c.janet_wrap_nil();
    }
    return threadedAwait(
        goThreadSubr,
        @bitCast(@as(u32, @truncate(flags))),
        @bitCast(vm().sandbox_flags),
        buffer,
    );
}

fn giveSupervisorImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 1, -1);
    const chanv = vm().root_fiber.*.supervisor_channel;
    if (chanv != null) {
        const chan = channel.unwrap(chanv);
        if (try channel.push(chan, c.janet_wrap_tuple(c.janet_tuple_n(argv, argc)), 0)) {
            return awaitEvent();
        }
    }
    return c.janet_wrap_nil();
}

fn sleepImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    const sec = try arglayer.getNumber(argv, 0);
    return sleepAwait(sec);
}

fn deadlineImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 1, 4);
    var sec = try arglayer.getNumber(argv, 0);
    if (sec < 0) sec = 0;
    const tocancel = try arglayer.optFiber(argv, argc, 1, vm().root_fiber);
    const tocheck = try arglayer.optFiber(argv, argc, 2, vm().fiber);
    const use_interrupt = try arglayer.optBoolean(argv, argc, 3, 0) != 0;
    var to: c.JanetTimeout = .{
        .when = janet_ev_ts_delta(tsNow(), sec),
        .fiber = tocancel,
        .curr_fiber = tocheck,
        .is_error = 0,
        .sched_id = tocancel.*.sched_id,
        .has_worker = 0,
        .worker = std.mem.zeroes(@FieldType(c.JanetTimeout, "worker")),
    };
    if (use_interrupt) {
        if (!has_interrupt) {
            // The interpreter's half of this is compiled out, so a timer
            // thread would raise auto_suspend at a VM that never reads it and
            // a fiber that does not yield would run forever. Refuse the same
            // way os/sigaction does, before anything is allocated or started.
            return raise.panic("interpreter interrupt not enabled");
        }
        if (android) try lifecycle.sandboxAssert(c.JANET_SANDBOX_SIGNAL);
        const tto: *ThreadedTimeout = @ptrCast(@alignCast(c.janet_malloc(@sizeOf(ThreadedTimeout)) orelse
            outOfMemory(@src())));
        tto.sec = sec;
        tto.vm_ptr = vm();
        tto.fiber = tocheck;
        if (windows) {
            const cancel_event = CreateEventA(null, 1, 0, null);
            if (cancel_event == null) {
                c.janet_free(tto);
                return raise.panic("failed to create cancel event");
            }
            tto.cancel_event = cancel_event;
            const worker = CreateThread(null, 0, timeoutBodyWindows, tto, CREATE_SUSPENDED, null);
            if (worker == null) {
                c.janet_free(tto);
                return raise.panic("failed to create thread");
            }
            to.has_worker = 1;
            to.worker = worker;
            to.worker_event = cancel_event;
            _ = ResumeThread(worker);
        } else {
            var worker: c.pthread_t = undefined;
            const err = pthread_create(&worker, null, timeoutBodyPosix, tto);
            if (err != 0) {
                c.janet_free(tto);
                return pp_format.panicf("%s", .{janet_strerror(err)});
            }
            to.has_worker = 1;
            to.worker = worker;
        }
    }
    addTimeout(to);
    return c.janet_wrap_fiber(tocancel);
}

fn cancelImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 2);
    const fiber = try arglayer.getFiber(argv, 0);
    try cancel(fiber, argv[1]);
    return argv[0];
}

fn allTasksImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 0);
    _ = argv;
    const v = vm();
    const array = c.janet_array(v.active_tasks.count);
    var i: i32 = 0;
    while (i < v.active_tasks.capacity) : (i += 1) {
        const key = v.active_tasks.data[@intCast(i)].key;
        if (c.janet_checktype(key, c.JANET_NIL) == 0) try containers.arrayPush(array, key);
    }
    return c.janet_wrap_array(array);
}

// ==========================================================================
// The two lock types
// ==========================================================================

fn mutexGC(p: ?*anyopaque, size: usize) callconv(.c) c_int {
    _ = size;
    c.janet_os_mutex_deinit(@ptrCast(p));
    return 0;
}

export const janet_mutex_type: abstract_type.AbstractType = .{
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
    c.janet_os_rwlock_deinit(@ptrCast(p));
    return 0;
}

export const janet_rwlock_type: abstract_type.AbstractType = .{
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

fn mutexImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 0);
    _ = argv;
    const mutex = c.janet_abstract_threaded(abstract_type.stored(&janet_mutex_type), c.janet_os_mutex_size());
    c.janet_os_mutex_init(@ptrCast(mutex));
    return c.janet_wrap_abstract(mutex);
}

fn mutexAcquireImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    const mutex = try arglayer.getAbstract(argv, 0, abstract_type.stored(&janet_mutex_type));
    c.janet_os_mutex_lock(@ptrCast(mutex));
    return argv[0];
}

fn mutexReleaseImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    const mutex = try arglayer.getAbstract(argv, 0, abstract_type.stored(&janet_mutex_type));
    c.janet_os_mutex_unlock(@ptrCast(mutex));
    return argv[0];
}

fn rwlockImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 0);
    _ = argv;
    const rwlock = c.janet_abstract_threaded(abstract_type.stored(&janet_rwlock_type), c.janet_os_rwlock_size());
    c.janet_os_rwlock_init(@ptrCast(rwlock));
    return c.janet_wrap_abstract(rwlock);
}

fn rwlockReadLockImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    const rwlock = try arglayer.getAbstract(argv, 0, abstract_type.stored(&janet_rwlock_type));
    c.janet_os_rwlock_rlock(@ptrCast(rwlock));
    return argv[0];
}

fn rwlockWriteLockImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    const rwlock = try arglayer.getAbstract(argv, 0, abstract_type.stored(&janet_rwlock_type));
    c.janet_os_rwlock_wlock(@ptrCast(rwlock));
    return argv[0];
}

fn rwlockReadReleaseImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    const rwlock = try arglayer.getAbstract(argv, 0, abstract_type.stored(&janet_rwlock_type));
    c.janet_os_rwlock_runlock(@ptrCast(rwlock));
    return argv[0];
}

fn rwlockWriteReleaseImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    const rwlock = try arglayer.getAbstract(argv, 0, abstract_type.stored(&janet_rwlock_type));
    c.janet_os_rwlock_wunlock(@ptrCast(rwlock));
    return argv[0];
}

// ==========================================================================
// Registration
// ==========================================================================

extern const janet_channel_type: abstract_type.AbstractType;
extern const janet_stream_type: abstract_type.AbstractType;

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
pub fn janet_lib_evImpl(env: *c.JanetTable) raise.Raising(void) {
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

    try registration.registerAbstractType(abstract_type.stored(&janet_stream_type));
    try registration.registerAbstractType(abstract_type.stored(&janet_channel_type));
    try registration.registerAbstractType(abstract_type.stored(&janet_mutex_type));
    try registration.registerAbstractType(abstract_type.stored(&janet_rwlock_type));
}

export fn janet_lib_ev(env: *c.JanetTable) callconv(.c) void {
    raise.reported(janet_lib_evImpl(env));
}
