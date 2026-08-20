//! The four polling backends: the Windows completion port, `epoll`, `kqueue`,
//! and `poll`. Part of the `-Dev-loop` object; `ev_loop.zig` has the reasoning
//! for why the four files are one module.
//!
//! Each backend is a `struct` namespace and `selected` picks one. Zig analyses
//! a container's declarations only when something references them, so exactly
//! one backend is compiled per target and the other three cost nothing -- the
//! same arrangement `ev.c` gets from `#elif`, without the property Part 7
//! warned about, that a file which compiles is not a file that runs.
//!
//! **The selection follows the translation, not a fresh derivation.** `state.h`
//! lays `JanetVM` out differently per backend, and which arm it took is
//! already decided by the time Zig sees the structure; reading
//! `JANET_EV_EPOLL` and `JANET_EV_KQUEUE` out of the translation is what keeps
//! the fields this file names and the backend it compiles in agreement. Part
//! 12's rule -- test the platform with `builtin.os.tag` -- applies to the
//! Windows arm, which is the one the translation used to get wrong, and the
//! comptime check below asserts the two agree.
//!
//! **No host structure is translated.** `struct kevent`, `struct epoll_event`,
//! `struct itimerspec` and `struct pollfd` come from `std`, which declares
//! each per target; `os_files.zig` records why `struct timespec` cannot come
//! from translate-c on musl, and every structure here would inherit that. The
//! calls themselves are one-line `extern fn`s.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi");
const raise = @import("raise");
const pp_format = @import("pp_format.zig");
const ev = @import("ev_loop.zig");
const stream_mod = @import("ev_stream.zig");

const c = abi.c;
const ev_callback = @import("ev_callback.zig");
const windows = ev.windows;

pub const Backend = enum { iocp, epoll, kqueue, poll };

pub const selected: Backend = if (windows)
    .iocp
else if (@hasDecl(c, "JANET_EV_EPOLL"))
    .epoll
else if (@hasDecl(c, "JANET_EV_KQUEUE"))
    .kqueue
else
    .poll;

comptime {
    // `janet.h` picks the backend from the platform and two `JANET_EV_NO_*`
    // switches. If the translation and the compilation ever disagreed about
    // the platform -- the fault Part 12 found in `janet.h`'s Unix chain --
    // `JanetVM`'s translated layout would be the wrong arm's, and every field
    // this file names would be at the wrong offset. Assert the agreement
    // rather than hope for it.
    if (windows != @hasDecl(c, "JANET_WINDOWS")) {
        @compileError("ev_backend: the translation and the build disagree about Windows");
    }
    if (!windows and @hasDecl(c, "JANET_EV_EPOLL") and @hasDecl(c, "JANET_EV_KQUEUE")) {
        @compileError("ev_backend: the translation selects two POSIX backends");
    }
}

/// The four backends wear one interface, and several of its entry points
/// declare an error that only some of them return: `init` raises on `iocp` and
/// on `epoll`, `edgeTriggered`, `levelTriggered` and `unregister` only on
/// `epoll`, `register` on `iocp` and `epoll`, and `kqueue` and `poll` raise
/// from none of them.
///
/// Phase 10's fourth rule says a function that cannot raise should not pretend
/// it can, and this is the exception the rule has to make. The dispatch below
/// picks a backend at comptime and calls it by name; if the signatures differed
/// per backend, the *call site* would need a `try` on some targets and not on
/// others, which is not something one source line can be. Part 17d found this
/// the way it finds everything of the kind -- from a cross-compile, after the
/// host had been green for an hour.
const impl = switch (selected) {
    .iocp => Iocp,
    .epoll => Epoll,
    .kqueue => Kqueue,
    .poll => Poll,
};

// ==========================================================================
// The seam the rest of the object uses
// ==========================================================================

pub inline fn registerStream(s: *c.JanetStream) raise.Raising(void) {
    try impl.register(s);
}

pub inline fn unregisterStream(s: *c.JanetStream) raise.Raising(void) {
    try impl.unregister(s);
}

pub inline fn loop1Impl(has_timeout: bool, timeout: c.JanetTimestamp) raise.Raising(void) {
    try impl.loop1(has_timeout, timeout);
}

pub fn evInit() raise.Raising(void) {
    ev.janet_ev_init_common();
    try impl.init();
}

export fn janet_ev_init() callconv(.c) void {
    raise.reported(evInit());
}

export fn janet_ev_deinit() callconv(.c) void {
    ev.janet_ev_deinit_common();
    impl.deinit();
}

pub fn edgeTriggeredStream(s: *c.JanetStream) raise.Raising(void) {
    try impl.edgeTriggered(s);
}

export fn janet_stream_edge_triggered(s: *c.JanetStream) callconv(.c) void {
    raise.reported(edgeTriggeredStream(s));
}

pub fn levelTriggeredStream(s: *c.JanetStream) raise.Raising(void) {
    try impl.levelTriggered(s);
}

export fn janet_stream_level_triggered(s: *c.JanetStream) callconv(.c) void {
    raise.reported(levelTriggeredStream(s));
}

/// `janet_loop1_impl`. Not part of the public API, and exported anyway so that
/// `test/ev_loop.c` can drive one turn of the poll without a fiber -- the two
/// faces rule, applied to the one entry point whose C face nothing else calls.
export fn janet_loop1_impl(has_timeout: c_int, timeout: c.JanetTimestamp) callconv(.c) void {
    raise.reported(loop1Impl(has_timeout != 0, timeout));
}

// ==========================================================================
// The self pipe
// ==========================================================================

/// On Windows the completion port carries custom events itself, so there is no
/// self pipe at all; every other backend needs a descriptor it can wake by
/// writing to.
const SelfPipe = struct {
    fn setup() void {
        if (janet_make_pipe(&c.janet_vm.selfpipe, 1) != 0) {
            ev.exitWith(@src(), "failed to initialize self pipe in event loop");
        }
    }

    /// Drain the pipe, running each posted callback. One short read ends it.
    fn handle() void {
        var response: ev.SelfPipeEvent = undefined;
        while (true) {
            var status: isize = undefined;
            while (true) {
                status = ev.read(c.janet_vm.selfpipe[0], @ptrCast(&response), @sizeOf(ev.SelfPipeEvent));
                if (!(status == -1 and ev.errno() == ev.EINTR)) break;
            }
            if (status <= 0) return;
            if (response.cb) |cb| {
                cb(response.msg);
                ev.janet_ev_dec_refcount();
            }
        }
    }

    fn cleanup() void {
        _ = ev.close(c.janet_vm.selfpipe[0]);
        _ = ev.close(c.janet_vm.selfpipe[1]);
    }
};

extern fn janet_make_pipe(handles: *[2]c.JanetHandle, mode: c_int) callconv(.c) c_int;

/// Deliver one event to whichever fiber is waiting on `s`, for the two
/// backends that report a bare readiness mask.
fn stepMasked(s: *c.JanetStream, readable: bool, writable: bool, has_err: bool, has_hup: bool, comptime else_chain: bool) raise.Raising(void) {
    const rf = s.read_fiber;
    const wf = s.write_fiber;
    if (rf != null) {
        if (rf.*.ev_callback != null and readable) {
            try ev_callback.of(rf.*.ev_callback)(rf, c.JANET_ASYNC_EVENT_READ);
        } else if (else_chain and rf.*.ev_callback != null and has_hup) {
            try ev_callback.of(rf.*.ev_callback)(rf, c.JANET_ASYNC_EVENT_HUP);
        } else if (else_chain and rf.*.ev_callback != null and has_err) {
            try ev_callback.of(rf.*.ev_callback)(rf, c.JANET_ASYNC_EVENT_ERR);
        }
        if (!else_chain) {
            if (rf.*.ev_callback != null and has_err) try ev_callback.of(rf.*.ev_callback)(rf, c.JANET_ASYNC_EVENT_ERR);
            if (rf.*.ev_callback != null and has_hup) try ev_callback.of(rf.*.ev_callback)(rf, c.JANET_ASYNC_EVENT_HUP);
        }
    }
    if (wf != null) {
        if (wf.*.ev_callback != null and writable) {
            try ev_callback.of(wf.*.ev_callback)(wf, c.JANET_ASYNC_EVENT_WRITE);
        } else if (else_chain and wf.*.ev_callback != null and has_hup) {
            try ev_callback.of(wf.*.ev_callback)(wf, c.JANET_ASYNC_EVENT_HUP);
        } else if (else_chain and wf.*.ev_callback != null and has_err) {
            try ev_callback.of(wf.*.ev_callback)(wf, c.JANET_ASYNC_EVENT_ERR);
        }
        if (!else_chain) {
            if (wf.*.ev_callback != null and has_err) try ev_callback.of(wf.*.ev_callback)(wf, c.JANET_ASYNC_EVENT_ERR);
            if (wf.*.ev_callback != null and has_hup) try ev_callback.of(wf.*.ev_callback)(wf, c.JANET_ASYNC_EVENT_HUP);
        }
    }
    try stream_mod.checkToClose(s);
}

// ==========================================================================
// Windows: an IO completion port
// ==========================================================================

const Iocp = struct {
    extern "kernel32" fn CreateIoCompletionPort(file: ?*anyopaque, port: ?*anyopaque, key: usize, threads: u32) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetQueuedCompletionStatus(port: ?*anyopaque, bytes: *u32, key: *usize, overlapped: *?*stream_mod.OVERLAPPED, ms: u32) callconv(.winapi) c_int;

    fn init() raise.Raising(void) {
        c.janet_vm.iocp = @ptrCast(@alignCast(CreateIoCompletionPort(
            @ptrFromInt(std.math.maxInt(usize)),
            null,
            0,
            0,
        )));
        if (c.janet_vm.iocp == null) return raise.panic("could not create io completion port");
    }

    fn deinit() void {
        _ = ev.CloseHandle(ev.iocpHandle());
    }

    fn register(s: *c.JanetStream) raise.Raising(void) {
        if (CreateIoCompletionPort(s.handle, ev.iocpHandle(), @intFromPtr(s), 0) == null) {
            const listenable: u32 = @intCast(c.JANET_STREAM_READABLE | c.JANET_STREAM_WRITABLE | c.JANET_STREAM_ACCEPTABLE);
            if (s.flags & listenable != 0) {
                return pp_format.panicf("failed to listen for events: %V", .{stream_mod.janet_ev_lasterr()});
            }
            s.flags |= @intCast(c.JANET_STREAM_UNREGISTERED);
        }
    }

    /// The completion port has no per-stream registration to undo.
    fn unregister(s: *c.JanetStream) raise.Raising(void) {
        _ = s;
    }

    fn edgeTriggered(s: *c.JanetStream) raise.Raising(void) {
        _ = s;
    }

    fn levelTriggered(s: *c.JanetStream) raise.Raising(void) {
        _ = s;
    }

    fn loop1(has_timeout: bool, to: c.JanetTimestamp) raise.Raising(void) {
        var completion_key: usize = 0;
        var num_bytes_transferred: u32 = 0;
        var overlapped: ?*stream_mod.OVERLAPPED = null;

        // Calculate how long to wait before timeout.
        var waittime: u32 = ev.INFINITE;
        if (has_timeout) {
            const now = ev.tsNow();
            waittime = if (now > to) 0 else @intCast(to - now);
        }
        const result = GetQueuedCompletionStatus(
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
            ev.janet_ev_dec_refcount();
            c.janet_free(response);
            return;
        }
        // Normal event.
        const jo: *stream_mod.Overlapped = @ptrCast(@alignCast(overlapped));
        const s: *c.JanetStream = @ptrFromInt(completion_key);
        var fiber: [*c]c.JanetFiber = null;
        if (s.read_fiber != null and s.read_fiber.*.ev_state == @as(?*anyopaque, jo)) {
            fiber = s.read_fiber;
        } else if (s.write_fiber != null and s.write_fiber.*.ev_state == @as(?*anyopaque, jo)) {
            fiber = s.write_fiber;
        }
        if (fiber != null) {
            fiber.*.flags &= ~@as(i32, @intCast(c.JANET_FIBER_EV_FLAG_IN_FLIGHT));
            jo.bytes_transfered = num_bytes_transferred;
            try ev_callback.of(fiber.*.ev_callback)(fiber, if (result != 0)
                c.JANET_ASYNC_EVENT_COMPLETE
            else
                c.JANET_ASYNC_EVENT_FAILED);
        } else {
            c.janet_free(jo);
            ev.janet_ev_dec_refcount();
        }
        try stream_mod.checkToClose(s);
    }
};

// ==========================================================================
// Linux: epoll, with a timerfd for the deadline
// ==========================================================================

const Epoll = struct {
    const linux = std.os.linux;
    const EpollEvent = linux.epoll_event;

    const ITimerSpec = extern struct {
        it_interval: std.c.timespec,
        it_value: std.c.timespec,
    };

    extern fn epoll_create1(flags: c_int) callconv(.c) c_int;
    extern fn epoll_ctl(epfd: c_int, op: c_int, fd: c_int, event: ?*EpollEvent) callconv(.c) c_int;
    extern fn epoll_wait(epfd: c_int, events: [*]EpollEvent, maxevents: c_int, timeout: c_int) callconv(.c) c_int;
    extern fn timerfd_create(clockid: c_int, flags: c_int) callconv(.c) c_int;
    extern fn timerfd_settime(fd: c_int, flags: c_int, new: *const ITimerSpec, old: ?*ITimerSpec) callconv(.c) c_int;

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
        const v = &c.janet_vm;
        v.epoll = epoll_create1(EPOLL_CLOEXEC);
        v.timerfd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
        v.timer_enabled = 0;
        if (v.epoll != -1 and v.timerfd != -1) {
            var event: EpollEvent = .{ .events = EPOLLIN | EPOLLET, .data = .{ .ptr = @intFromPtr(&v.timerfd) } };
            if (epoll_ctl(v.epoll, EPOLL_CTL_ADD, v.timerfd, &event) != -1) {
                event = .{ .events = EPOLLIN | EPOLLET, .data = .{ .ptr = @intFromPtr(&v.selfpipe) } };
                if (epoll_ctl(v.epoll, EPOLL_CTL_ADD, v.selfpipe[0], &event) != -1) return;
            }
        }
        ev.exitWith(@src(), "failed to initialize event loop");
    }

    fn deinit() void {
        const v = &c.janet_vm;
        _ = ev.close(v.epoll);
        _ = ev.close(v.timerfd);
        SelfPipe.cleanup();
        v.epoll = 0;
    }

    fn registerImpl(s: *c.JanetStream, mod: bool, edge_trigger: bool) raise.Raising(void) {
        var event: EpollEvent = .{
            .events = if (edge_trigger) EPOLLET else 0,
            .data = .{ .ptr = @intFromPtr(s) },
        };
        const readable: u32 = @intCast(c.JANET_STREAM_READABLE | c.JANET_STREAM_ACCEPTABLE);
        if (s.flags & readable != 0) event.events |= EPOLLIN;
        if (s.flags & @as(u32, @intCast(c.JANET_STREAM_WRITABLE)) != 0) event.events |= EPOLLOUT;
        var status: c_int = undefined;
        while (true) {
            status = epoll_ctl(
                c.janet_vm.epoll,
                if (mod) EPOLL_CTL_MOD else EPOLL_CTL_ADD,
                s.handle,
                &event,
            );
            if (!(status == -1 and ev.errno() == ev.EINTR)) break;
        }
        if (status == -1) {
            if (ev.errno() == ev.EPERM) {
                // Couldn't add to the event loop, so assume it completes
                // synchronously.
                s.flags |= @intCast(c.JANET_STREAM_UNREGISTERED);
            } else {
                return raise.panicv(stream_mod.janet_ev_lasterr());
            }
        }
    }

    fn register(s: *c.JanetStream) raise.Raising(void) {
        try registerImpl(s, false, true);
    }

    fn edgeTriggered(s: *c.JanetStream) raise.Raising(void) {
        try registerImpl(s, true, true);
    }

    fn levelTriggered(s: *c.JanetStream) raise.Raising(void) {
        try registerImpl(s, true, false);
    }

    fn unregister(s: *c.JanetStream) raise.Raising(void) {
        if (s.flags & @as(u32, @intCast(c.JANET_STREAM_NODUPS)) != 0) return;
        var status: c_int = undefined;
        while (true) {
            status = epoll_ctl(c.janet_vm.epoll, EPOLL_CTL_DEL, s.handle, null);
            if (!(status == -1 and ev.errno() == ev.EINTR)) break;
        }
        if (status == -1) return raise.panicv(stream_mod.janet_ev_lasterr());
        s.flags |= @intCast(c.JANET_STREAM_UNREGISTERED);
    }

    fn loop1(has_timeout: bool, timeout: c.JanetTimestamp) raise.Raising(void) {
        const v = &c.janet_vm;
        if (v.timer_enabled != 0 or has_timeout) {
            var its = std.mem.zeroes(ITimerSpec);
            if (has_timeout) {
                its.it_value.sec = @intCast(@divTrunc(timeout, 1000));
                its.it_value.nsec = @intCast(@rem(timeout, 1000) * 1000000);
            }
            _ = timerfd_settime(v.timerfd, TFD_TIMER_ABSTIME, &its, null);
        }
        v.timer_enabled = @intFromBool(has_timeout);

        var events: [max_events]EpollEvent = undefined;
        var ready: c_int = undefined;
        while (true) {
            ready = epoll_wait(v.epoll, &events, max_events, -1);
            if (!(ready == -1 and ev.errno() == ev.EINTR)) break;
        }
        if (ready == -1) ev.exitWith(@src(), "failed to poll events");

        var i: usize = 0;
        while (i < @as(usize, @intCast(ready))) : (i += 1) {
            const p = events[i].data.ptr;
            if (p == @intFromPtr(&v.timerfd)) {
                // Timer expired, ignore.
            } else if (p == @intFromPtr(&v.selfpipe)) {
                SelfPipe.handle();
            } else {
                const s: *c.JanetStream = @ptrFromInt(p);
                const mask = events[i].events;
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
    /// `__typeof__`. `std.c.Kevent` declares it `usize` everywhere, which is
    /// the same width on both.
    fn set(slot: *Kevent, ident: c.JanetHandle, filter: i16, flags: u16, udata: usize) void {
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
    fn changes(kevs: *[2]Kevent, s: *c.JanetStream, flags: u16) usize {
        var length: usize = 0;
        const readable: u32 = @intCast(c.JANET_STREAM_READABLE | c.JANET_STREAM_ACCEPTABLE);
        if (s.flags & readable != 0) {
            set(&kevs[length], s.handle, EVFILT_READ, flags, @intFromPtr(s));
            length += 1;
        }
        if (s.flags & @as(u32, @intCast(c.JANET_STREAM_WRITABLE)) != 0) {
            set(&kevs[length], s.handle, EVFILT_WRITE, flags, @intFromPtr(s));
            length += 1;
        }
        return length;
    }

    fn apply(kevs: []const Kevent) c_int {
        var status: c_int = undefined;
        while (true) {
            status = std.c.kevent(c.janet_vm.kq, kevs.ptr, @intCast(kevs.len), undefined, 0, null);
            if (!(status == -1 and ev.errno() == ev.EINTR)) break;
        }
        return status;
    }

    fn registerImpl(s: *c.JanetStream, edge_trigger: bool) void {
        var kevs: [2]Kevent = undefined;
        const clear: u16 = if (edge_trigger) @intCast(std.c.EV.CLEAR) else 0;
        const length = changes(&kevs, s, @as(u16, @intCast(std.c.EV.ADD | std.c.EV.ENABLE)) | clear);
        if (apply(kevs[0..length]) == -1) s.flags |= @intCast(c.JANET_STREAM_UNREGISTERED);
    }

    fn register(s: *c.JanetStream) raise.Raising(void) {
        registerImpl(s, true);
    }

    fn edgeTriggered(s: *c.JanetStream) raise.Raising(void) {
        registerImpl(s, true);
    }

    /// On macOS a registered event has to be deleted before it can be
    /// re-registered without `EV_CLEAR`, or the new registration keeps
    /// `EV_CLEAR` set. The C original records this as possibly a kernel bug
    /// and certainly a vague specification.
    fn levelTriggered(s: *c.JanetStream) raise.Raising(void) {
        var kevs: [2]Kevent = undefined;
        const length = changes(&kevs, s, @intCast(std.c.EV.DELETE));
        _ = apply(kevs[0..length]);
        registerImpl(s, false);
    }

    fn unregister(s: *c.JanetStream) raise.Raising(void) {
        if (s.flags & @as(u32, @intCast(c.JANET_STREAM_NODUPS)) != 0) return;
        var kevs: [2]Kevent = undefined;
        const length = changes(&kevs, s, @intCast(std.c.EV.DELETE));
        // The status might be -1 on the BSDs for subprocesses.
        _ = apply(kevs[0..length]);
        s.flags |= @intCast(c.JANET_STREAM_UNREGISTERED);
    }

    fn init() raise.Raising(void) {
        // The C original's TODO asking to replace the self pipe with
        // EVFILT_USER stands.
        SelfPipe.setup();
        const v = &c.janet_vm;
        v.kq = std.c.kqueue();
        v.timer_enabled = 0;
        if (v.kq != -1) {
            var event: Kevent = undefined;
            set(&event, v.selfpipe[0], EVFILT_READ, @intCast(std.c.EV.ADD | std.c.EV.ENABLE), @intFromPtr(&v.selfpipe));
            var status: c_int = undefined;
            // The C original's loop condition is `errno != EINTR`, which
            // retries on every error but that one. Reproduced.
            while (true) {
                status = std.c.kevent(v.kq, @ptrCast(&event), 1, undefined, 0, null);
                if (!(status == -1 and ev.errno() != ev.EINTR)) break;
            }
            if (status != -1) return;
        }
        ev.exitWith(@src(), "failed to initialize event loop");
    }

    fn deinit() void {
        const v = &c.janet_vm;
        _ = ev.close(v.kq);
        SelfPipe.cleanup();
        v.kq = 0;
    }

    fn loop1(has_timeout: bool, timeout: c.JanetTimestamp) raise.Raising(void) {
        // The interval is calculated per iteration. When it drops to zero or
        // below the timeout is zero; an infinite timeout would make other
        // fibers miss theirs. `janet_ev_kqueue_interval` is what keeps it at
        // or above the minimum the platform accepts.
        const v = &c.janet_vm;
        var ts: std.c.timespec = undefined;
        var events: [max_events]Kevent = undefined;
        var status: c_int = undefined;
        while (true) {
            if (v.timer_enabled != 0 or has_timeout) {
                var sec: i64 = undefined;
                var nsec: i64 = undefined;
                ev.janet_ev_ts_to_parts(ev.janet_ev_kqueue_interval(timeout - ev.tsNow()), &sec, &nsec);
                ts = .{ .sec = @intCast(sec), .nsec = @intCast(nsec) };
                status = std.c.kevent(v.kq, undefined, 0, &events, max_events, &ts);
            } else {
                status = std.c.kevent(v.kq, undefined, 0, &events, max_events, null);
            }
            if (!(status == -1 and ev.errno() == ev.EINTR)) break;
        }
        if (status == -1) ev.exitWith(@src(), "failed to poll events");

        v.timer_enabled = @intFromBool(has_timeout);

        var i: usize = 0;
        while (i < @as(usize, @intCast(status))) : (i += 1) {
            const p = events[i].udata;
            if (p == @intFromPtr(&v.selfpipe)) {
                SelfPipe.handle();
                continue;
            }
            const s: *c.JanetStream = @ptrFromInt(p);
            const filt = events[i].filter;
            const has_err = events[i].flags & @as(u16, @intCast(std.c.EV.ERROR)) != 0;
            const has_hup = events[i].flags & @as(u16, @intCast(std.c.EV.EOF)) != 0;
            // The C original walks j = 0 then j = 1, taking the *write* fiber
            // first. Reproduced, including that both directions see an ERR
            // and a HUP.
            var j: usize = 0;
            while (j < 2) : (j += 1) {
                const f = if (j != 0) s.read_fiber else s.write_fiber;
                if (f == null) continue;
                if (f.*.ev_callback != null and has_err) {
                    try ev_callback.of(f.*.ev_callback)(f, c.JANET_ASYNC_EVENT_ERR);
                }
                if (f.*.ev_callback != null and filt == EVFILT_READ and f == s.read_fiber) {
                    try ev_callback.of(f.*.ev_callback)(f, c.JANET_ASYNC_EVENT_READ);
                }
                if (f.*.ev_callback != null and filt == EVFILT_WRITE and f == s.write_fiber) {
                    try ev_callback.of(f.*.ev_callback)(f, c.JANET_ASYNC_EVENT_WRITE);
                }
                if (f.*.ev_callback != null and has_hup) {
                    try ev_callback.of(f.*.ev_callback)(f, c.JANET_ASYNC_EVENT_HUP);
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
        return @ptrCast(@alignCast(c.janet_vm.fds));
    }

    fn register(s: *c.JanetStream) raise.Raising(void) {
        const v = &c.janet_vm;
        s.index = @intCast(v.stream_count);
        const new_count = v.stream_count + 1;
        if (new_count > v.stream_capacity) {
            const new_cap = new_count * 2;
            v.fds = @ptrCast(@alignCast(c.janet_realloc(v.fds, (1 + new_cap) * @sizeOf(PollFd))));
            v.streams = @ptrCast(@alignCast(c.janet_realloc(@ptrCast(v.streams), new_cap * @sizeOf(*c.JanetStream))));
            if (v.fds == null or v.streams == null) ev.outOfMemory(@src());
            v.stream_capacity = new_cap;
        }
        fds()[v.stream_count + 1] = .{ .fd = s.handle, .events = POLLIN | POLLOUT, .revents = 0 };
        v.streams[v.stream_count] = s;
        v.stream_count = new_count;
    }

    fn unregister(s: *c.JanetStream) raise.Raising(void) {
        const v = &c.janet_vm;
        const i = s.index;
        const j = v.stream_count - 1;
        const last = v.streams[j];
        const lastfd = fds()[j + 1];
        fds()[i + 1] = lastfd;
        v.streams[i] = last;
        last.*.index = s.index;
        v.stream_count -= 1;
        s.flags |= @intCast(c.JANET_STREAM_UNREGISTERED);
    }

    fn edgeTriggered(s: *c.JanetStream) raise.Raising(void) {
        _ = s;
    }

    fn levelTriggered(s: *c.JanetStream) raise.Raising(void) {
        _ = s;
    }

    fn init() raise.Raising(void) {
        const v = &c.janet_vm;
        v.fds = null;
        SelfPipe.setup();
        v.fds = @ptrCast(@alignCast(c.janet_malloc(@sizeOf(PollFd)) orelse ev.outOfMemory(@src())));
        fds()[0] = .{ .fd = v.selfpipe[0], .events = POLLIN, .revents = 0 };
        v.streams = null;
        v.stream_count = 0;
        v.stream_capacity = 0;
    }

    fn deinit() void {
        const v = &c.janet_vm;
        SelfPipe.cleanup();
        c.janet_free(v.fds);
        c.janet_free(@ptrCast(v.streams));
        v.fds = null;
        v.streams = null;
    }

    fn loop1(has_timeout: bool, timeout: c.JanetTimestamp) raise.Raising(void) {
        const v = &c.janet_vm;

        // Set event flags.
        var i: usize = 0;
        while (i < v.stream_count) : (i += 1) {
            const s = v.streams[i];
            const pfd = &fds()[i + 1];
            pfd.events = 0;
            pfd.revents = 0;
            const rf = s.*.read_fiber;
            const wf = s.*.write_fiber;
            if (rf != null and rf.*.ev_callback != null) pfd.events |= POLLIN;
            if (wf != null and wf.*.ev_callback != null) pfd.events |= POLLOUT;
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
            ready = std.c.poll(fds(), @intCast(v.stream_count + 1), to);
            if (!(ready == -1 and ev.errno() == ev.EINTR)) break;
        }
        if (ready == -1) ev.exitWith(@src(), "failed to poll events");

        // Undo the negative hack.
        i = 0;
        while (i < v.stream_count) : (i += 1) {
            const pfd = &fds()[i + 1];
            if (pfd.fd < 0) pfd.fd = -pfd.fd;
        }

        if (fds()[0].revents & POLLIN != 0) {
            fds()[0].revents = 0;
            SelfPipe.handle();
        }

        i = 0;
        while (i < v.stream_count) : (i += 1) {
            const pfd = &fds()[i + 1];
            const s = v.streams[i];
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
