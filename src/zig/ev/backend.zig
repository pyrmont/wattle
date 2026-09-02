//! The four polling backends: the Windows completion port, `epoll`, `kqueue`,
//! and `poll`. Part of the event loop; `ev.zig` has the reasoning for why the
//! four files are one module.
//!
//! Each backend is a `struct` namespace and `selected` picks one. Zig analyses
//! a container's declarations only when something references them, so exactly
//! one backend is compiled per target and the other three cost nothing.
//!
//! **The selection and the VM's layout must agree.** `Vm` carries a different
//! block per backend, so a build that compiled one arm and laid out another
//! would read every field at the wrong offset. The `comptime` block below
//! Windows arm, which is the one the translation used to get wrong, and the
//! comptime check below asserts the two agree.
//!
//! **No host structure is translated.** `struct kevent`, `struct epoll_event`,
//! `struct itimerspec` and `struct pollfd` come from `std`, which declares
//! each per target, and `std` is where a structure with a per-target layout
//! should come from. The calls themselves are one-line `extern fn`s.

const std = @import("std");
const builtin = @import("builtin");
const raise = @import("../raise.zig");
const pp_format = @import("../pp/format.zig");
const ev = @import("../ev.zig");
const ev_core = @import("../ev.zig");
const stream_mod = @import("stream.zig");

const constants = @import("constants");
const vm_state = @import("../vm/state.zig");
const ev_callback = @import("../callback_type.zig");
const config = @import("config");
const utils = @import("../utils.zig");
const c = @import("cabi");
const fibers = @import("../value/fibers.zig");
const host = @import("host");
const windows = ev.windows;

pub const Backend = enum { iocp, epoll, kqueue, poll };

pub const selected: Backend = if (windows)
    .iocp
else if (config.ev_epoll)
    .epoll
else if (config.ev_kqueue)
    .kqueue
else
    .poll;

comptime {
    // The backend follows the platform and two `-D` switches, and `Vm` is laid
    // out differently per backend. If the two ever disagreed, every field this
    // file names would be at the wrong offset. Assert the agreement rather
    // than hope for it.
    if (windows != (builtin.os.tag == .windows)) {
        @compileError("ev_backend: the translation and the build disagree about Windows");
    }
    if (!windows and config.ev_epoll and config.ev_kqueue) {
        @compileError("ev_backend: the translation selects two POSIX backends");
    }
}

/// The event loop's per-mechanism state. Four arms, chosen the way
/// `build.zig` chooses the backend, and each holds exactly what its own
/// arm below reads. `vm/state.zig`'s `Vm` carries one.
///
/// `new_thread_attr` and `selfpipe` are in three of the four rather than in
/// `VmEv`: they are what a POSIX backend needs to start a thread and to wake
/// itself, and Windows does neither that way.
pub const VmBackend = if (builtin.os.tag == .windows)
    struct {
        iocp: ?[*]?*anyopaque = null,
        connect_ex: ?*anyopaque = null,
        connect_ex_loaded: bool = false,
    }
else if (config.ev_epoll)
    struct {
        new_thread_attr: host.pthread_attr_t = std.mem.zeroes(host.pthread_attr_t),
        selfpipe: [2]host.Handle = std.mem.zeroes([2]host.Handle),
        epoll: c_int = 0,
        timerfd: c_int = 0,
        timer_enabled: bool = false,
    }
else if (config.ev_kqueue)
    struct {
        new_thread_attr: host.pthread_attr_t = std.mem.zeroes(host.pthread_attr_t),
        selfpipe: [2]host.Handle = std.mem.zeroes([2]host.Handle),
        kq: c_int = 0,
        timer_enabled: bool = false,
    }
else
    struct {
        new_thread_attr: host.pthread_attr_t = std.mem.zeroes(host.pthread_attr_t),
        selfpipe: [2]host.Handle = std.mem.zeroes([2]host.Handle),
        streams: ?[*]*stream_mod.Stream = null,
        stream_count: usize = 0,
        stream_capacity: usize = 0,
        fds: ?[*]std.c.pollfd = null,
    };

/// The four backends wear one interface, and several of its entry points
/// declare an error that only some of them return: `init` raises on `iocp` and
/// on `epoll`, `edgeTriggered`, `levelTriggered` and `unregister` only on
/// `epoll`, `register` on `iocp` and `epoll`, and `kqueue` and `poll` raise
/// from none of them.
///
/// A function that cannot raise should not pretend it can, and this is the
/// exception that rule has to make. The dispatch below picks a backend at
/// comptime and calls it by name; if the signatures differed per backend, the
/// *call site* would need a `try` on some targets and not on others, which is
/// not something one source line can be. A cross-compile is what found it,
/// after the host had been green for an hour.
const impl = switch (selected) {
    .iocp => Iocp,
    .epoll => Epoll,
    .kqueue => Kqueue,
    .poll => Poll,
};

// ==========================================================================
// The seam the rest of the object uses
// ==========================================================================

pub inline fn registerStream(s: *stream_mod.Stream) raise.Raising(void) {
    try impl.register(s);
}

pub inline fn unregisterStream(s: *stream_mod.Stream) raise.Raising(void) {
    try impl.unregister(s);
}

pub inline fn loop1(has_timeout: bool, timeout: ev.Timestamp) raise.Raising(void) {
    try impl.loop1(has_timeout, timeout);
}

pub fn evInit() raise.Raising(void) {
    ev.evInitCommon();
    try impl.init();
}

pub fn evDeinit() void {
    ev.evDeinitCommon();
    impl.deinit();
}

pub fn edgeTriggeredStream(s: *stream_mod.Stream) raise.Raising(void) {
    try impl.edgeTriggered(s);
}

pub fn levelTriggeredStream(s: *stream_mod.Stream) raise.Raising(void) {
    try impl.levelTriggered(s);
}

// ==========================================================================
// The self pipe
// ==========================================================================

/// On Windows the completion port carries custom events itself, so there is no
/// self pipe at all; every other backend needs a descriptor it can wake by
/// writing to.
const SelfPipe = struct {
    fn setup() void {
        if (stream_mod.makePipe(&vm_state.current().ev.backend.selfpipe, 1) != 0) {
            ev.exitWith(@src(), "failed to initialize self pipe in event loop");
        }
    }

    /// Drain the pipe, running each posted callback. One short read ends it.
    ///
    /// **The reference is given back whether or not there is a callback**, and
    /// that is what balances `postEvent`, which takes one unconditionally so
    /// the loop cannot decide it is done while an event is in flight. An event
    /// posted with no callback is what `loop1Interrupt` sends -- it exists to
    /// wake a loop blocked in the backend and do nothing else -- so putting
    /// the decrement inside the null test leaves that loop never finishing.
    /// The completion-port handler below already decrements outside it.
    fn handle() void {
        var response: ev.SelfPipeEvent = undefined;
        while (true) {
            const status = c.retryIntr(c.read, .{ vm_state.current().ev.backend.selfpipe[0], @as([*]u8, @ptrCast(&response)), @sizeOf(ev.SelfPipeEvent) });
            if (status <= 0) return;
            if (response.cb) |cb| cb(response.msg);
            ev.evDecRefcount();
        }
    }

    fn cleanup() void {
        const b = &vm_state.current().ev.backend;
        _ = c.close(b.selfpipe[0]);
        _ = c.close(b.selfpipe[1]);
    }
};

/// Deliver one event to whichever fiber is waiting on `s`, for the two
/// backends that report a bare readiness mask.
fn stepMasked(s: *stream_mod.Stream, readable: bool, writable: bool, has_err: bool, has_hup: bool, comptime else_chain: bool) raise.Raising(void) {
    const rf = s.read_fiber;
    const wf = s.write_fiber;
    if (rf) |f| {
        if (f.ev_callback != null and readable) {
            try ev_callback.of(f.ev_callback)(f, constants.AsyncEvent.read);
        } else if (else_chain and f.ev_callback != null and has_hup) {
            try ev_callback.of(f.ev_callback)(f, constants.AsyncEvent.hup);
        } else if (else_chain and f.ev_callback != null and has_err) {
            try ev_callback.of(f.ev_callback)(f, constants.AsyncEvent.err);
        }
        if (!else_chain) {
            if (f.ev_callback != null and has_err) try ev_callback.of(f.ev_callback)(f, constants.AsyncEvent.err);
            if (f.ev_callback != null and has_hup) try ev_callback.of(f.ev_callback)(f, constants.AsyncEvent.hup);
        }
    }
    if (wf) |f| {
        if (f.ev_callback != null and writable) {
            try ev_callback.of(f.ev_callback)(f, constants.AsyncEvent.write);
        } else if (else_chain and f.ev_callback != null and has_hup) {
            try ev_callback.of(f.ev_callback)(f, constants.AsyncEvent.hup);
        } else if (else_chain and f.ev_callback != null and has_err) {
            try ev_callback.of(f.ev_callback)(f, constants.AsyncEvent.err);
        }
        if (!else_chain) {
            if (f.ev_callback != null and has_err) try ev_callback.of(f.ev_callback)(f, constants.AsyncEvent.err);
            if (f.ev_callback != null and has_hup) try ev_callback.of(f.ev_callback)(f, constants.AsyncEvent.hup);
        }
    }
    try stream_mod.checkToClose(s);
}

// ==========================================================================
// Windows: an IO completion port
// ==========================================================================

const Iocp = struct {
    fn init() raise.Raising(void) {
        const b = &vm_state.current().ev.backend;
        b.iocp = @ptrCast(@alignCast(c.CreateIoCompletionPort(
            @ptrFromInt(std.math.maxInt(usize)),
            null,
            0,
            0,
        )));
        if (b.iocp == null) return raise.panic("could not create io completion port");
    }

    fn deinit() void {
        _ = c.CloseHandle(ev.iocpHandle());
    }

    fn register(s: *stream_mod.Stream) raise.Raising(void) {
        if (c.CreateIoCompletionPort(s.handle, ev.iocpHandle(), @intFromPtr(s), 0) == null) {
            const listenable: u32 = @intCast(constants.JANET_STREAM_READABLE | constants.JANET_STREAM_WRITABLE | constants.JANET_STREAM_ACCEPTABLE);
            if (s.flags & listenable != 0) {
                return pp_format.panicf("failed to listen for events: %V", .{stream_mod.evLasterr()});
            }
            s.flags |= @intCast(constants.JANET_STREAM_UNREGISTERED);
        }
    }

    /// The completion port has no per-stream registration to undo.
    fn unregister(s: *stream_mod.Stream) raise.Raising(void) {
        _ = s;
    }

    fn edgeTriggered(s: *stream_mod.Stream) raise.Raising(void) {
        _ = s;
    }

    fn levelTriggered(s: *stream_mod.Stream) raise.Raising(void) {
        _ = s;
    }

    fn loop1(has_timeout: bool, to: ev.Timestamp) raise.Raising(void) {
        var completion_key: usize = 0;
        var num_bytes_transferred: u32 = 0;
        var overlapped: ?*c.OVERLAPPED = null;

        // Calculate how long to wait before timeout.
        var waittime: u32 = ev.INFINITE;
        if (has_timeout) {
            const now = ev.tsNow();
            waittime = if (now > to) 0 else @intCast(to - now);
        }
        const result = c.GetQueuedCompletionStatus(
            ev.iocpHandle(),
            &num_bytes_transferred,
            &completion_key,
            &overlapped,
            waittime,
        );

        if (result == 0 and overlapped == null) return;
        if (completion_key == 0) {
            // Custom event.
            const response: *ev.SelfPipeEvent = @ptrCast(@alignCast(overlapped));
            if (response.cb) |cb| cb(response.msg);
            ev.evDecRefcount();
            utils.free(response);
            return;
        }
        // Normal event.
        const jo: *stream_mod.Overlapped = @ptrCast(@alignCast(overlapped));
        const s: *stream_mod.Stream = @ptrFromInt(completion_key);
        const fiber: ?*fibers.Fiber = blk: {
            if (s.read_fiber) |f| {
                if (f.ev_state == @as(?*anyopaque, jo)) break :blk f;
            }
            if (s.write_fiber) |f| {
                if (f.ev_state == @as(?*anyopaque, jo)) break :blk f;
            }
            break :blk null;
        };
        if (fiber) |waiting| {
            waiting.flags.setEvInFlight(false);
            jo.bytes_transfered = num_bytes_transferred;
            try ev_callback.of(waiting.ev_callback)(waiting, if (result != 0)
                constants.AsyncEvent.complete
            else
                constants.AsyncEvent.failed);
        } else {
            utils.free(jo);
            ev.evDecRefcount();
        }
        try stream_mod.checkToClose(s);
    }
};

// ==========================================================================
// Linux: epoll, with a timerfd for the deadline
// ==========================================================================

const Epoll = struct {
    const linux = std.os.linux;

    const EPOLL_CTL_ADD: c_int = linux.EPOLL.CTL_ADD;
    const EPOLL_CTL_DEL: c_int = linux.EPOLL.CTL_DEL;
    const EPOLL_CTL_MOD: c_int = linux.EPOLL.CTL_MOD;
    const EPOLLIN: u32 = linux.EPOLL.IN;
    const EPOLLOUT: u32 = linux.EPOLL.OUT;
    const EPOLLERR: u32 = linux.EPOLL.ERR;
    const EPOLLHUP: u32 = linux.EPOLL.HUP;
    const EPOLLET: u32 = linux.EPOLL.ET;
    const EPOLL_CLOEXEC: c_int = @intCast(linux.EPOLL.CLOEXEC);
    /// `TFD_CLOEXEC` and `TFD_NONBLOCK` are `O_CLOEXEC` and `O_NONBLOCK`, and
    /// `TFD_TIMER_ABSTIME` is 1 on every architecture Linux supports.
    const TFD_CLOEXEC: c_int = EPOLL_CLOEXEC;
    const TFD_NONBLOCK: c_int = @intCast(@as(u32, @bitCast(linux.TFD{ .NONBLOCK = true })));
    const TFD_TIMER_ABSTIME: c_int = 1;
    const CLOCK_MONOTONIC: c_int = @intFromEnum(linux.CLOCK.MONOTONIC);

    const max_events = 64;

    fn init() raise.Raising(void) {
        SelfPipe.setup();
        const b = &vm_state.current().ev.backend;
        b.epoll = c.epoll_create1(EPOLL_CLOEXEC);
        b.timerfd = c.timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
        b.timer_enabled = false;
        if (b.epoll != -1 and b.timerfd != -1) {
            var event: c.EpollEvent = .{ .events = EPOLLIN | EPOLLET, .data = .{ .ptr = @intFromPtr(&b.timerfd) } };
            if (c.epoll_ctl(b.epoll, EPOLL_CTL_ADD, b.timerfd, &event) != -1) {
                event = .{ .events = EPOLLIN | EPOLLET, .data = .{ .ptr = @intFromPtr(&b.selfpipe) } };
                if (c.epoll_ctl(b.epoll, EPOLL_CTL_ADD, b.selfpipe[0], &event) != -1) return;
            }
        }
        ev.exitWith(@src(), "failed to initialize event loop");
    }

    fn deinit() void {
        const b = &vm_state.current().ev.backend;
        _ = c.close(b.epoll);
        _ = c.close(b.timerfd);
        SelfPipe.cleanup();
        b.epoll = 0;
    }

    fn registerImpl(s: *stream_mod.Stream, mod: bool, edge_trigger: bool) raise.Raising(void) {
        var event: c.EpollEvent = .{
            .events = if (edge_trigger) EPOLLET else 0,
            .data = .{ .ptr = @intFromPtr(s) },
        };
        const readable: u32 = @intCast(constants.JANET_STREAM_READABLE | constants.JANET_STREAM_ACCEPTABLE);
        if (s.flags & readable != 0) event.events |= EPOLLIN;
        if (s.flags & @as(u32, @intCast(constants.JANET_STREAM_WRITABLE)) != 0) event.events |= EPOLLOUT;
        const status = c.retryIntr(c.epoll_ctl, .{
            vm_state.current().ev.backend.epoll,
            if (mod) EPOLL_CTL_MOD else EPOLL_CTL_ADD,
            s.handle,
            &event,
        });
        if (status == -1) {
            if (c.errno() == ev.EPERM) {
                // Couldn't add to the event loop, so assume it completes
                // synchronously.
                s.flags |= @intCast(constants.JANET_STREAM_UNREGISTERED);
            } else {
                return raise.panicv(stream_mod.evLasterr());
            }
        }
    }

    fn register(s: *stream_mod.Stream) raise.Raising(void) {
        try registerImpl(s, false, true);
    }

    fn edgeTriggered(s: *stream_mod.Stream) raise.Raising(void) {
        try registerImpl(s, true, true);
    }

    fn levelTriggered(s: *stream_mod.Stream) raise.Raising(void) {
        try registerImpl(s, true, false);
    }

    /// **`ENOENT` is not an error here.** epoll keys a registration by
    /// descriptor, so a stream whose descriptor was duplicated -- which is
    /// what an unsafe marshal does -- was never added under the number it is
    /// now being removed by. Deregistering something that is not registered is
    /// the state this is trying to reach, and kqueue answers it silently.
    /// Anything else is still raised.
    fn unregister(s: *stream_mod.Stream) raise.Raising(void) {
        if (s.flags & @as(u32, @intCast(constants.JANET_STREAM_NODUPS)) != 0) return;
        const status = c.retryIntr(c.epoll_ctl, .{ vm_state.current().ev.backend.epoll, EPOLL_CTL_DEL, s.handle, null });
        if (status == -1 and c.errno() != @intFromEnum(std.c.E.NOENT)) return raise.panicv(stream_mod.evLasterr());
        s.flags |= @intCast(constants.JANET_STREAM_UNREGISTERED);
    }

    fn loop1(has_timeout: bool, timeout: ev.Timestamp) raise.Raising(void) {
        const b = &vm_state.current().ev.backend;
        if (b.timer_enabled or has_timeout) {
            var its = std.mem.zeroes(c.ITimerSpec);
            if (has_timeout) {
                its.it_value.sec = @intCast(@divTrunc(timeout, 1000));
                its.it_value.nsec = @intCast(@rem(timeout, 1000) * 1000000);
            }
            _ = c.timerfd_settime(b.timerfd, TFD_TIMER_ABSTIME, &its, null);
        }
        b.timer_enabled = has_timeout;

        var events: [max_events]c.EpollEvent = undefined;
        const ready = c.retryIntr(c.epoll_wait, .{ b.epoll, &events, max_events, -1 });
        if (ready == -1) ev.exitWith(@src(), "failed to poll events");

        for (events[0..@as(usize, @intCast(ready))]) |event| {
            const p = event.data.ptr;
            if (p == @intFromPtr(&b.timerfd)) {
                // Timer expired, ignore.
            } else if (p == @intFromPtr(&b.selfpipe)) {
                SelfPipe.handle();
            } else {
                const s: *stream_mod.Stream = @ptrFromInt(p);
                const mask = event.events;
                try stepMasked(
                    s,
                    mask & EPOLLIN != 0,
                    mask & EPOLLOUT != 0,
                    mask & EPOLLERR != 0,
                    mask & EPOLLHUP != 0,
                    false,
                );
            }
        }
    }
};

// ==========================================================================
// BSD and macOS: kqueue
// ==========================================================================

const Kqueue = struct {
    const Kevent = std.c.Kevent;
    const EVFILT_READ: i16 = std.c.EVFILT.READ;
    const EVFILT_WRITE: i16 = std.c.EVFILT.WRITE;

    const max_events = 512;

    /// `EV_SETx` in `ev.c`: NetBSD spells `.udata` as an `intptr_t` and every
    /// other kqueue platform as a `void *`, so the C original casts through
    /// `__typeof__`. `std.Kevent` declares it `usize` everywhere, which is
    /// the same width on both.
    fn set(slot: *Kevent, ident: host.Handle, filter: i16, flags: u16, udata: usize) void {
        slot.* = .{
            .ident = @intCast(ident),
            .filter = @intCast(filter),
            .flags = @intCast(flags),
            .fflags = 0,
            .data = 0,
            .udata = udata,
        };
    }

    /// Fill `kevs` with one change per direction the stream listens in, and
    /// report how many were written.
    fn changes(kevs: *[2]Kevent, s: *stream_mod.Stream, flags: u16) usize {
        var length: usize = 0;
        const readable: u32 = @intCast(constants.JANET_STREAM_READABLE | constants.JANET_STREAM_ACCEPTABLE);
        if (s.flags & readable != 0) {
            set(&kevs[length], s.handle, EVFILT_READ, flags, @intFromPtr(s));
            length += 1;
        }
        if (s.flags & @as(u32, @intCast(constants.JANET_STREAM_WRITABLE)) != 0) {
            set(&kevs[length], s.handle, EVFILT_WRITE, flags, @intFromPtr(s));
            length += 1;
        }
        return length;
    }

    fn apply(kevs: []const Kevent) c_int {
        const status = c.retryIntr(std.c.kevent, .{ vm_state.current().ev.backend.kq, kevs.ptr, @as(c_int, @intCast(kevs.len)), undefined, 0, null });
        return status;
    }

    fn registerImpl(s: *stream_mod.Stream, edge_trigger: bool) void {
        var kevs: [2]Kevent = undefined;
        const clear: u16 = if (edge_trigger) @intCast(std.c.EV.CLEAR) else 0;
        const length = changes(&kevs, s, @as(u16, @intCast(std.c.EV.ADD | std.c.EV.ENABLE)) | clear);
        if (apply(kevs[0..length]) == -1) s.flags |= @intCast(constants.JANET_STREAM_UNREGISTERED);
    }

    fn register(s: *stream_mod.Stream) raise.Raising(void) {
        registerImpl(s, true);
    }

    fn edgeTriggered(s: *stream_mod.Stream) raise.Raising(void) {
        registerImpl(s, true);
    }

    /// On macOS a registered event has to be deleted before it can be
    /// re-registered without `EV_CLEAR`, or the new registration keeps
    /// `EV_CLEAR` set. The C original records this as possibly a kernel bug
    /// and certainly a vague specification.
    fn levelTriggered(s: *stream_mod.Stream) raise.Raising(void) {
        var kevs: [2]Kevent = undefined;
        const length = changes(&kevs, s, @intCast(std.c.EV.DELETE));
        _ = apply(kevs[0..length]);
        registerImpl(s, false);
    }

    fn unregister(s: *stream_mod.Stream) raise.Raising(void) {
        if (s.flags & @as(u32, @intCast(constants.JANET_STREAM_NODUPS)) != 0) return;
        var kevs: [2]Kevent = undefined;
        const length = changes(&kevs, s, @intCast(std.c.EV.DELETE));
        // The status might be -1 on the BSDs for subprocesses.
        _ = apply(kevs[0..length]);
        s.flags |= @intCast(constants.JANET_STREAM_UNREGISTERED);
    }

    fn init() raise.Raising(void) {
        // The C original's TODO asking to replace the self pipe with
        // EVFILT_USER stands.
        SelfPipe.setup();
        const b = &vm_state.current().ev.backend;
        b.kq = std.c.kqueue();
        b.timer_enabled = false;
        if (b.kq != -1) {
            var event: Kevent = undefined;
            set(&event, b.selfpipe[0], EVFILT_READ, @intCast(std.c.EV.ADD | std.c.EV.ENABLE), @intFromPtr(&b.selfpipe));
            const status = c.retryIntr(std.c.kevent, .{ b.kq, @as([*]const Kevent, @ptrCast(&event)), 1, undefined, 0, null });
            if (status != -1) return;
        }
        ev.exitWith(@src(), "failed to initialize event loop");
    }

    fn deinit() void {
        const b = &vm_state.current().ev.backend;
        _ = c.close(b.kq);
        SelfPipe.cleanup();
        b.kq = 0;
    }

    fn loop1(has_timeout: bool, timeout: ev.Timestamp) raise.Raising(void) {
        // The interval is calculated per iteration. When it drops to zero or
        // below the timeout is zero; an infinite timeout would make other
        // fibers miss theirs. `ev_core.kqueueInterval` is what keeps it at
        // or above the minimum the platform accepts.
        const b = &vm_state.current().ev.backend;
        var ts: std.c.timespec = undefined;
        var events: [max_events]Kevent = undefined;
        var status: c_int = undefined;
        while (true) {
            if (b.timer_enabled or has_timeout) {
                var sec: i64 = undefined;
                var nsec: i64 = undefined;
                ev_core.tsToParts(ev_core.kqueueInterval(timeout - ev.tsNow()), &sec, &nsec);
                ts = .{ .sec = @intCast(sec), .nsec = @intCast(nsec) };
                status = std.c.kevent(b.kq, undefined, 0, &events, max_events, &ts);
            } else {
                status = std.c.kevent(b.kq, undefined, 0, &events, max_events, null);
            }
            if (!(status == -1 and c.errno() == c.eintr)) break;
        }
        if (status == -1) ev.exitWith(@src(), "failed to poll events");

        b.timer_enabled = has_timeout;

        for (events[0..@as(usize, @intCast(status))]) |event| {
            const p = event.udata;
            if (p == @intFromPtr(&b.selfpipe)) {
                SelfPipe.handle();
                continue;
            }
            const s: *stream_mod.Stream = @ptrFromInt(p);
            const filt = event.filter;
            const has_err = event.flags & @as(u16, @intCast(std.c.EV.ERROR)) != 0;
            const has_hup = event.flags & @as(u16, @intCast(std.c.EV.EOF)) != 0;
            // The C original walks j = 0 then j = 1, taking the *write* fiber
            // first. Reproduced, including that both directions see an ERR
            // and a HUP.
            for (0..2) |j| {
                const f = (if (j != 0) s.read_fiber else s.write_fiber) orelse continue;
                if (f.ev_callback != null and has_err) {
                    try ev_callback.of(f.ev_callback)(f, constants.AsyncEvent.err);
                }
                if (f.ev_callback != null and filt == EVFILT_READ and f == s.read_fiber) {
                    try ev_callback.of(f.ev_callback)(f, constants.AsyncEvent.read);
                }
                if (f.ev_callback != null and filt == EVFILT_WRITE and f == s.write_fiber) {
                    try ev_callback.of(f.ev_callback)(f, constants.AsyncEvent.write);
                }
                if (f.ev_callback != null and has_hup) {
                    try ev_callback.of(f.ev_callback)(f, constants.AsyncEvent.hup);
                }
            }
            try stream_mod.checkToClose(s);
        }
    }
};

// ==========================================================================
// Everywhere else: poll
// ==========================================================================

const Poll = struct {
    const PollFd = std.c.pollfd;
    const POLLIN: i16 = @intCast(std.c.POLL.IN);
    const POLLOUT: i16 = @intCast(std.c.POLL.OUT);
    const POLLERR: i16 = @intCast(std.c.POLL.ERR);
    const POLLHUP: i16 = @intCast(std.c.POLL.HUP);

    inline fn fds() [*]PollFd {
        return @ptrCast(@alignCast(vm_state.current().ev.backend.fds));
    }

    /// The stream table, beside `fds` and for the same reason: both are
    /// allocated by `register` and read only where `stream_count` says there
    /// is something to read, so the unwrap is the claim `fds()` already makes.
    inline fn streams() [*]*stream_mod.Stream {
        return @ptrCast(@alignCast(vm_state.current().ev.backend.streams));
    }

    fn register(s: *stream_mod.Stream) raise.Raising(void) {
        const b = &vm_state.current().ev.backend;
        s.index = @intCast(b.stream_count);
        const new_count = b.stream_count + 1;
        if (new_count > b.stream_capacity) {
            const new_cap = new_count * 2;
            b.fds = @ptrCast(@alignCast(utils.realloc(b.fds, (1 + new_cap) * @sizeOf(PollFd))));
            b.streams = @ptrCast(@alignCast(utils.realloc(@ptrCast(b.streams), new_cap * @sizeOf(*stream_mod.Stream))));
            if (b.fds == null or b.streams == null) ev.outOfMemory(@src());
            b.stream_capacity = new_cap;
        }
        fds()[b.stream_count + 1] = .{ .fd = s.handle, .events = POLLIN | POLLOUT, .revents = 0 };
        streams()[b.stream_count] = s;
        b.stream_count = new_count;
    }

    fn unregister(s: *stream_mod.Stream) raise.Raising(void) {
        const b = &vm_state.current().ev.backend;
        const i = s.index;
        const j = b.stream_count - 1;
        const last = streams()[j];
        const lastfd = fds()[j + 1];
        fds()[i + 1] = lastfd;
        streams()[i] = last;
        last.index = s.index;
        b.stream_count -= 1;
        s.flags |= @intCast(constants.JANET_STREAM_UNREGISTERED);
    }

    fn edgeTriggered(s: *stream_mod.Stream) raise.Raising(void) {
        _ = s;
    }

    fn levelTriggered(s: *stream_mod.Stream) raise.Raising(void) {
        _ = s;
    }

    fn init() raise.Raising(void) {
        const b = &vm_state.current().ev.backend;
        b.fds = null;
        SelfPipe.setup();
        b.fds = @ptrCast(@alignCast(utils.malloc(@sizeOf(PollFd)) orelse ev.outOfMemory(@src())));
        fds()[0] = .{ .fd = b.selfpipe[0], .events = POLLIN, .revents = 0 };
        b.streams = null;
        b.stream_count = 0;
        b.stream_capacity = 0;
    }

    fn deinit() void {
        const b = &vm_state.current().ev.backend;
        SelfPipe.cleanup();
        utils.free(b.fds);
        utils.free(@ptrCast(b.streams));
        b.fds = null;
        b.streams = null;
    }

    fn loop1(has_timeout: bool, timeout: ev.Timestamp) raise.Raising(void) {
        const b = &vm_state.current().ev.backend;

        // Set event flags.
        for (0..b.stream_count) |i| {
            const s = streams()[i];
            const pfd = &fds()[i + 1];
            pfd.events = 0;
            pfd.revents = 0;
            if (s.read_fiber) |f| {
                if (f.ev_callback != null) pfd.events |= POLLIN;
            }
            if (s.write_fiber) |f| {
                if (f.ev_callback != null) pfd.events |= POLLOUT;
            }
            // Ignore a descriptor by making it negative, which is what `poll`
            // documents as "skip this entry".
            if (pfd.events == 0) pfd.fd = -pfd.fd;
        }

        var ready: c_int = undefined;
        while (true) {
            var to: c_int = -1;
            if (has_timeout) {
                const now = ev.tsNow();
                to = if (now > timeout) 0 else @intCast(timeout - now);
            }
            ready = std.c.poll(fds(), @intCast(b.stream_count + 1), to);
            if (!(ready == -1 and c.errno() == c.eintr)) break;
        }
        if (ready == -1) ev.exitWith(@src(), "failed to poll events");

        // Undo the negative hack.
        for (0..b.stream_count) |i| {
            const pfd = &fds()[i + 1];
            if (pfd.fd < 0) pfd.fd = -pfd.fd;
        }

        if (fds()[0].revents & POLLIN != 0) {
            fds()[0].revents = 0;
            SelfPipe.handle();
        }

        var i: usize = 0;
        while (i < b.stream_count) : (i += 1) {
            const pfd = &fds()[i + 1];
            const s = streams()[i];
            const mask = pfd.revents;
            if (mask == 0) continue;
            try stepMasked(
                s,
                mask & POLLIN != 0,
                mask & POLLOUT != 0,
                mask & POLLERR != 0,
                mask & POLLHUP != 0,
                true,
            );
        }
    }
};
