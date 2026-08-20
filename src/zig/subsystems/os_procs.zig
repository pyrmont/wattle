//! The process half of `os.c`'s cfunction surface, and the first of the two
//! areas Phase 10's decision 4 unparks: the `core/process` abstract type and
//! its four callbacks, the eleven `os/` cfunctions that make or manage a
//! subprocess, the signal-number table, the `posix_spawn` and `CreateProcess`
//! sequences, `os/sigaction`, and `os/pipe`. This is Part 12.
//!
//! ## What the decision changed
//!
//! `PLAN.md` recorded process control as permanently C because it drives
//! `posix_spawn_file_actions_t`, `struct sigaction`, `sigset_t`, `STARTUPINFO`
//! and `PROCESS_INFORMATION`, and a host structure's layout is the platform
//! header's. Decision 4 keeps that for the structures and drops it for the
//! language: every one of them is still libc's, declared in `os_abi.h` and
//! reached through the shared translation, and each lives on one Zig frame for
//! the length of one call. None crosses a boundary, which is the property that
//! matters rather than the translation succeeding.
//!
//! `-Dos-process` is untouched and still owns what it owned: the scalar host
//! calls, the wait-status classification, the Windows command-line escaping
//! and the environment entry rules. This file calls them across the C ABI
//! exactly as `os.c` did, so `-Dos-process=c` still swaps them under a Zig
//! `os/spawn`.
//!
//! ## The signal table stops being split
//!
//! `-Dos-process` holds the signal *names* and reports a position; `os.c` held
//! a `#ifdef`-gated array mapping a position to a number, with `-1` for a
//! signal the platform does not define. That split existed because a name is
//! portable and a host constant is not. The constants are now reachable --
//! `<signal.h>` is in `os_abi.h` -- so the mapping is `@hasDecl` per signal
//! instead of `#ifdef` per signal, and it is *compiled* on every target rather
//! than only on the host. The `-1` sentinel and its consequence are preserved
//! exactly: `:poll` still reports `undefined signal :poll` on macOS and
//! resolves on Linux.
//!
//! ## `JANET_THREADS` is defined by nothing in this tree
//!
//! `FOUND.md` already records that, and this file is where it has the most
//! visible effect: `janet_lock_environ` and `janet_unlock_environ` are empty
//! functions in every build there is, and `os/sigaction`'s mask manipulation
//! goes through `sigprocmask` rather than `pthread_sigmask`. The pthread and
//! `CRITICAL_SECTION` arms are recorded here and not written, on Part 8's
//! `JANET_MARSHAL_DEBUG` rule: Zig does not analyse a comptime-false branch,
//! so carrying them would produce something even less checked than the C.
//!
//! ## The marker
//!
//! Every raise this file makes is an error return, and it still carries the
//! marker: `janet_arity`, `janet_getabstract`, `janet_getcstring`,
//! `janet_sandbox_assert` and `janet_getdictionary` are all C faces that raise
//! by jumping. Two places show it. `os_execute_impl` allocates its child
//! `argv` and its environment block with `janet_smalloc` and frees them on
//! every exit path by hand -- a raise between the two jumps past the free in C
//! and jumps past it here. And `os/shell` under the event loop leaks its
//! command copy, which is the defect `FOUND.md` records rather than a new one.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi");
const oa = @import("os_abi");
const corefn = @import("corefn");
const raise = @import("raise");
const pp_format = @import("pp_format.zig");
const os_files = @import("os_files.zig");
const c = abi.c;
const stdio = @import("stdio.zig");
const evloop = @import("evloop.zig");
const lifecycle = @import("lifecycle.zig");
const containers = @import("containers.zig");
const arglayer = @import("arglayer.zig");
const ev_stream = @import("ev_stream.zig");
const abstract_type = @import("abstract_type.zig");
const h = oa.h;

const windows = builtin.os.tag == .windows;

pub const has_ev = @hasDecl(c, "JANET_EV");
pub const no_spawn = @hasDecl(c, "JANET_NO_SPAWN");

/// `JANET_SPAWN_CHDIR`: whether `posix_spawn_file_actions_addchdir` exists.
/// `os_abi.h` enumerates the systems, because the extension follows no
/// standard and C is where that enumeration already lived.
const spawn_chdir = oa.spawn_chdir;

// ==========================================================================
// `-Dos-process`'s kernels, and the rest of the C ABI this file stands on
// ==========================================================================

extern fn janet_os_exec_escape_arg(arg: [*:0]const u8, dest: ?[*]u8, cap: i32) callconv(.c) i32;
extern fn janet_os_env_key_ok(key: [*]const u8, len: i32) callconv(.c) i32;
extern fn janet_os_env_entry_fill(
    key: [*]const u8,
    klen: i32,
    value: [*]const u8,
    vlen: i32,
    out: [*]u8,
) callconv(.c) void;
extern fn janet_os_getpid() callconv(.c) i64;
extern fn janet_os_system(command: ?[*:0]const u8) callconv(.c) i32;
extern fn janet_os_wait(pid: i64, value: *i32) callconv(.c) i32;
extern fn janet_os_reap(pid: i64) callconv(.c) void;
extern fn janet_os_kill(pid: i64, sig: i32) callconv(.c) i32;
extern fn janet_os_pipe(fds: *[2]c_int) callconv(.c) i32;
extern fn janet_os_close_fd(fd: c_int) callconv(.c) i32;
extern fn janet_os_fork() callconv(.c) i64;
extern fn janet_os_exec(
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    search_path: i32,
) callconv(.c) i32;
extern fn janet_os_chroot(path: [*:0]const u8) callconv(.c) i32;
extern fn janet_os_signal_index(key: [*]const u8, len: i32) callconv(.c) i32;

/// `src/core/util.h`, which `abi.zig` deliberately does not translate.
extern fn janet_strerror(e: c_int) callconv(.c) [*c]const u8;
extern fn janet_make_pipe(handles: *[2]c.JanetHandle, mode: c_int) callconv(.c) c_int;

extern fn janet_smalloc(size: usize) callconv(.c) ?*anyopaque;
extern fn janet_sfree(ptr: ?*anyopaque) callconv(.c) void;
extern fn janet_malloc(size: usize) callconv(.c) ?*anyopaque;
extern fn janet_free(ptr: ?*anyopaque) callconv(.c) void;

/// `janet_wrap_integer`, written out rather than called. `janet.h` declares the
/// function beside its macro and `wrap.c` defines it only for the two nanbox
/// layouts, so a tagged build has no such symbol and a Zig caller -- which
/// cannot use the macro -- does not link. `marsh.zig`, `pp_pretty.zig` and
/// `value_access.zig` write it out for the same reason, and `FOUND.md` has the
/// defect. This is the fourth subsystem to meet it.
inline fn wrapInteger(x: i32) c.Janet {
    return c.janet_wrap_number(@floatFromInt(x));
}

inline fn errno() c_int {
    return std.c._errno().*;
}

/// `JANET_OS_WAIT_*` in `src/core/os.c`. The classification crosses the
/// boundary; the policy that turns it into the number Janet reports is here,
/// because the fourth outcome raises.
const wait_exited: i32 = 0;
const wait_stopped: i32 = 1;
const wait_signaled: i32 = 2;

/// `janet_flag_at`, which is a function-like macro and does not survive
/// translation.
inline fn flagAt(flags: u64, index: u6) bool {
    return flags & (@as(u64, 1) << index) != 0;
}

// ==========================================================================
// The signal number table
// ==========================================================================

/// The names are `-Dos-process`'s and are reached by position through
/// `janet_os_signal_index`, so that a build selecting the C kernel still
/// agrees about the order. This is the other half: what number each position
/// carries on *this* platform, or -1 where the headers define none.
///
/// The misspelling `vtlarm` is `signal_names`' and is recorded in `FOUND.md`;
/// it is not repeated here, because this table is indexed rather than named.
const signal_number_names = [_][:0]const u8{
    "SIGKILL", "SIGINT",    "SIGABRT", "SIGFPE",  "SIGILL",  "SIGSEGV",
    "SIGTERM", "SIGALRM",   "SIGHUP",  "SIGPIPE", "SIGQUIT", "SIGUSR1",
    "SIGUSR2", "SIGCHLD",   "SIGCONT", "SIGSTOP", "SIGTSTP", "SIGTTIN",
    "SIGTTOU", "SIGBUS",    "SIGPOLL", "SIGPROF", "SIGSYS",  "SIGTRAP",
    "SIGURG",  "SIGVTALRM", "SIGXCPU", "SIGXFSZ",
};

const signal_numbers: [signal_number_names.len]i32 = blk: {
    var table: [signal_number_names.len]i32 = undefined;
    for (signal_number_names, 0..) |name, i| {
        table[i] = if (@hasDecl(h, name)) @field(h, name) else -1;
    }
    break :blk table;
};

/// `get_signal_kw`. A keyword the name list does not hold and one this
/// platform's headers left out are both "undefined signal", which is what the
/// `#ifdef`-gated C table produced by omitting the entry.
fn getSignalKw(argv: [*c]const c.Janet, n: i32) raise.Raising(c_int) {
    const kw = try arglayer.getKeyword(argv, n);
    const index = janet_os_signal_index(kw, c.janet_string_length(kw));
    if (index >= 0 and signal_numbers[@intCast(index)] >= 0) {
        return signal_numbers[@intCast(index)];
    }
    return pp_format.panicf("undefined signal %v", .{argv[@intCast(n)]});
}

// ==========================================================================
// The `core/process` abstract type
// ==========================================================================

const proc_closed: c_int = 1;
const proc_waited: c_int = 2;
const proc_waiting: c_int = 4;
const proc_error_nonzero: c_int = 8;
const proc_owns_stdin: c_int = 16;
const proc_owns_stdout: c_int = 32;
const proc_owns_stderr: c_int = 64;
const proc_allow_zombie: c_int = 128;

/// The stdio a `JanetProc` holds is a `JanetStream` under the event loop and a
/// `JanetFile` without it. Both are abstracts, so the field is a pointer
/// either way and the mark callback does not have to know which.
const Stdio = if (has_ev) c.JanetStream else c.JanetFile;

const JanetProc = extern struct {
    flags: c_int,
    handles: if (windows) extern struct { p: c.JanetHandle, t: c.JanetHandle } else extern struct { pid: h.pid_t },
    return_code: c_int,
    in: ?*Stdio,
    out: ?*Stdio,
    err: ?*Stdio,

    inline fn pid(self: *const JanetProc) i64 {
        return @intCast(self.handles.pid);
    }
};

/// `proc_get_status`: POSIX shell semantics for a signalled or stopped child.
/// The 128 offset and the fourth-outcome raise are here rather than in
/// `-Dos-process` because a raise may not cross that seam.
fn procGetStatus(proc: *JanetProc) raise.Raising(c_int) {
    var value: i32 = 0;
    const outcome = janet_os_wait(proc.pid(), &value);
    if (outcome == wait_exited) return value;
    if (outcome == wait_stopped or outcome == wait_signaled) return value + 128;
    return pp_format.panicf("Undefined status code for process termination, %d.", .{value});
}

extern fn WaitForSingleObject(handle: c.JanetHandle, ms: u32) callconv(.c) u32;
extern fn GetExitCodeProcess(handle: c.JanetHandle, code: *u32) callconv(.c) c_int;
extern fn TerminateProcess(handle: c.JanetHandle, code: c_uint) callconv(.c) c_int;
extern fn CloseHandle(handle: c.JanetHandle) callconv(.c) c_int;
extern fn GetCurrentProcess() callconv(.c) c.JanetHandle;
extern fn DuplicateHandle(
    src_proc: c.JanetHandle,
    src: c.JanetHandle,
    dst_proc: c.JanetHandle,
    dst: *c.JanetHandle,
    access: u32,
    inherit: c_int,
    options: u32,
) callconv(.c) c_int;
extern fn SetHandleInformation(handle: c.JanetHandle, mask: u32, flags: u32) callconv(.c) c_int;
extern fn CreatePipe(
    read: *c.JanetHandle,
    write: *c.JanetHandle,
    attrs: *h.SECURITY_ATTRIBUTES,
    size: u32,
) callconv(.c) c_int;

/// The threaded wait, and the callback that runs on the main thread when it
/// finishes. Only referenced under the event loop, which is what keeps them
/// out of a `-Dev=false` build: Zig does not analyse an unreferenced function.
const Waiter = struct {
    fn subroutine(args: c.JanetEVGenericMessage) callconv(.c) c.JanetEVGenericMessage {
        var out = args;
        const proc: *JanetProc = @ptrCast(@alignCast(args.argp.?));
        if (windows) {
            _ = WaitForSingleObject(proc.handles.p, 0xFFFF_FFFF);
            var exitcode: u32 = 0;
            _ = GetExitCodeProcess(proc.handles.p, &exitcode);
            out.tag = @bitCast(exitcode);
        } else {
            // This runs off the main thread, where a raise has nowhere to go.
            // The C original calls `proc_get_status` here too, and its fourth
            // outcome panics from the worker exactly as this delivers from it;
            // reproduced rather than repaired.
            out.tag = raise.total(procGetStatus(proc), "os/proc-wait's worker thread");
        }
        return out;
    }

    fn callbackImpl(args: c.JanetEVGenericMessage) raise.Raising(void) {
        const proc: *JanetProc = @ptrCast(@alignCast(args.argp orelse return));
        const status = args.tag;
        proc.return_code = status;
        proc.flags |= proc_waited;
        proc.flags &= ~proc_waiting;
        _ = c.janet_gcunroot(c.janet_wrap_abstract(proc));
        _ = c.janet_gcunroot(c.janet_wrap_fiber(args.fiber));
        const sched_id: u32 = @bitCast(args.argi);
        if (c.janet_fiber_can_resume(args.fiber) != 0 and args.fiber.*.sched_id == sched_id) {
            if (status != 0 and proc.flags & proc_error_nonzero != 0) {
                const s = try pp_format.formatc("command failed with non-zero exit code %d", .{status});
                try evloop.cancel(args.fiber, c.janet_wrap_string(s));
            } else {
                c.janet_schedule(args.fiber, wrapInteger(status));
            }
        }
    }

    // A `JanetCallback`, run by the event loop on the thread that receives
    // the event. Nothing above it can take an error.
    fn callback(args: c.JanetEVGenericMessage) callconv(.c) void {
        raise.total(callbackImpl(args), "os/proc's completion callback");
    }
};

fn procGc(p: ?*anyopaque, s: usize) callconv(.c) c_int {
    _ = s;
    const proc: *JanetProc = @ptrCast(@alignCast(p.?));
    if (windows) {
        if (proc.flags & proc_closed == 0) {
            if (proc.flags & proc_allow_zombie == 0) _ = TerminateProcess(proc.handles.p, 1);
            _ = CloseHandle(proc.handles.p);
            _ = CloseHandle(proc.handles.t);
        }
    } else {
        if (proc.flags & (proc_waited | proc_allow_zombie) == 0) {
            // Kill and wait, so that the child does not become a zombie.
            _ = janet_os_kill(proc.pid(), h.SIGKILL);
            if (proc.flags & proc_waiting == 0) janet_os_reap(proc.pid());
        }
    }
    return 0;
}

fn procMark(p: ?*anyopaque, s: usize) callconv(.c) c_int {
    _ = s;
    const proc: *JanetProc = @ptrCast(@alignCast(p.?));
    if (proc.in) |x| c.janet_mark(c.janet_wrap_abstract(x));
    if (proc.out) |x| c.janet_mark(c.janet_wrap_abstract(x));
    if (proc.err) |x| c.janet_mark(c.janet_wrap_abstract(x));
    return 0;
}

/// `os_proc_wait_impl`. Under the event loop it never returns -- `janet_await`
/// is `JANET_NO_RETURN` -- and without it the wait happens inline and the exit
/// code is the result. The C original spells that with two different return
/// types behind one `#ifdef`; this returns an optional instead, and the two
/// callers read it the same way.
fn procWaitImpl(proc: *JanetProc) raise.Raising(c.Janet) {
    if (proc.flags & (proc_waited | proc_waiting) != 0) {
        return raise.panic("cannot wait twice on a process");
    }
    if (has_ev) {
        // The threaded call resumes the current fiber when the child exits,
        // and `janet_await` does not return; the exit code reaches Janet
        // through the callback rather than through this frame.
        proc.flags |= proc_waiting;
        var targs: c.JanetEVGenericMessage = std.mem.zeroes(c.JanetEVGenericMessage);
        targs.argp = proc;
        targs.fiber = c.janet_root_fiber();
        targs.argi = @bitCast(targs.fiber.*.sched_id);
        c.janet_gcroot(c.janet_wrap_abstract(proc));
        c.janet_gcroot(c.janet_wrap_fiber(targs.fiber));
        try evloop.threadedCall(&Waiter.subroutine, targs, &Waiter.callback);
        try raise.crossing(c.janet_await());
        unreachable;
    } else {
        proc.flags |= proc_waited;
        var status: c_int = 0;
        if (windows) {
            _ = WaitForSingleObject(proc.handles.p, 0xFFFF_FFFF);
            var exitcode: u32 = 0;
            _ = GetExitCodeProcess(proc.handles.p, &exitcode);
            status = @bitCast(exitcode);
            if (proc.flags & proc_closed == 0) {
                proc.flags |= proc_closed;
                _ = CloseHandle(proc.handles.p);
                _ = CloseHandle(proc.handles.t);
            }
        } else {
            status = try procGetStatus(proc);
        }
        proc.return_code = status;
        return wrapInteger(proc.return_code);
    }
}

// ==========================================================================
// The process cfunctions
// ==========================================================================

fn procWait(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    const proc: *JanetProc = @ptrCast(@alignCast((try arglayer.getAbstract(argv, 0, abstract_type.stored(&proc_type))).?));
    return procWaitImpl(proc);
}

fn procKill(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 1, 3);
    const proc: *JanetProc = @ptrCast(@alignCast((try arglayer.getAbstract(argv, 0, abstract_type.stored(&proc_type))).?));
    if (proc.flags & proc_waited != 0) {
        return raise.panic("cannot kill process that has already finished");
    }
    if (windows) {
        if (proc.flags & proc_closed != 0) {
            return raise.panic("cannot close process handle that is already closed");
        }
        proc.flags |= proc_closed;
        _ = TerminateProcess(proc.handles.p, 1);
        _ = CloseHandle(proc.handles.p);
        _ = CloseHandle(proc.handles.t);
    } else {
        var signal: c_int = -1;
        if (argc == 3) signal = try getSignalKw(argv, 2);
        const status = janet_os_kill(proc.pid(), if (signal == -1) h.SIGKILL else signal);
        if (status != 0) return raise.panic(@ptrCast(janet_strerror(errno())));
    }
    // Having killed it, wait on it -- but only if asked.
    if (argc > 1 and c.janet_truthy(argv[1]) != 0) return procWaitImpl(proc);
    return argv[0];
}

extern fn janet_stream_close(stream: *c.JanetStream) callconv(.c) void;
extern fn janet_file_close(file: *c.JanetFile) callconv(.c) c_int;

inline fn closeStdio(x: *Stdio) raise.Raising(void) {
    if (has_ev) try ev_stream.streamClose(x) else _ = janet_file_close(x);
}

fn procClose(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    const proc: *JanetProc = @ptrCast(@alignCast((try arglayer.getAbstract(argv, 0, abstract_type.stored(&proc_type))).?));
    if (proc.flags & proc_owns_stdin != 0) try closeStdio(proc.in.?);
    if (proc.flags & proc_owns_stdout != 0) try closeStdio(proc.out.?);
    if (proc.flags & proc_owns_stderr != 0) try closeStdio(proc.err.?);
    proc.flags &= ~(proc_owns_stdin | proc_owns_stdout | proc_owns_stderr);
    if (proc.flags & (proc_waited | proc_waiting) != 0) return c.janet_wrap_nil();
    return procWaitImpl(proc);
}

fn procGetpid(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    _ = argv;
    try lifecycle.sandboxAssert(c.JANET_SANDBOX_SUBPROCESS);
    try arglayer.fixarity(argc, 0);
    return c.janet_wrap_number(@floatFromInt(janet_os_getpid()));
}

// ==========================================================================
// The abstract type's own table
//
// `proc_methods` carries three real methods and three dud entries. The duds
// are what `janet_nextmethod` walks, so `(keys p)` reports `:in`, `:out` and
// `:err` as well; Part 7 found that the table's *order* is observable for the
// same reason, and it is preserved here.
// ==========================================================================

const proc_methods = [_]corefn.Method{
    .{ .name = "wait", .cfun = &procWait },
    .{ .name = "kill", .cfun = &procKill },
    .{ .name = "close", .cfun = &procClose },
    .{ .name = "in", .cfun = null },
    .{ .name = "out", .cfun = null },
    .{ .name = "err", .cfun = null },
    .{ .name = null, .cfun = null },
};

fn procGet(p: ?*anyopaque, key: c.Janet, out: [*c]c.Janet) raise.Raising(c_int) {
    const proc: *JanetProc = @ptrCast(@alignCast(p.?));
    if (c.janet_keyeq(key, "in") != 0) {
        out.* = if (proc.in) |x| c.janet_wrap_abstract(x) else c.janet_wrap_nil();
        return 1;
    }
    if (c.janet_keyeq(key, "out") != 0) {
        out.* = if (proc.out) |x| c.janet_wrap_abstract(x) else c.janet_wrap_nil();
        return 1;
    }
    if (c.janet_keyeq(key, "err") != 0) {
        out.* = if (proc.err) |x| c.janet_wrap_abstract(x) else c.janet_wrap_nil();
        return 1;
    }
    if (!windows) {
        if (c.janet_keyeq(key, "pid") != 0) {
            out.* = c.janet_wrap_number(@floatFromInt(proc.handles.pid));
            return 1;
        }
    }
    if (proc.return_code != -1 and c.janet_keyeq(key, "return-code") != 0) {
        out.* = wrapInteger(proc.return_code);
        return 1;
    }
    if (c.janet_checktype(key, c.JANET_KEYWORD) == 0) return 0;
    return c.janet_getmethod(c.janet_unwrap_keyword(key), @ptrCast(&proc_methods), out);
}

fn procNext(p: ?*anyopaque, key: c.Janet) raise.Raising(c.Janet) {
    _ = p;
    return c.janet_nextmethod(@ptrCast(&proc_methods), key);
}

const proc_type: abstract_type.AbstractType = .{
    .name = "core/process",
    .gc = &procGc,
    .gcmark = &procMark,
    .get = &procGet,
    .put = null,
    .marshal = null,
    .unmarshal = null,
    .tostring = null,
    .compare = null,
    .hash = null,
    .next = &procNext,
    .call = null,
    .length = null,
    .bytes = null,
    .gcperthread = null,
};

// ==========================================================================
// Pipes and stdio redirection
// ==========================================================================

const handle_none: c.JanetHandle = if (windows) null else -1;

inline fn isHandle(x: c.JanetHandle) bool {
    return if (windows) x != null else x != -1;
}

fn closeHandle(handle: c.JanetHandle) void {
    if (windows) _ = CloseHandle(handle) else _ = janet_os_close_fd(handle);
}

/// `make_pipes`. The caller keeps `handle.*`; the returned end is the one the
/// child gets and is closed after the spawn. An error anywhere sets the flag
/// and answers "no handle", exactly as the C `goto error` did -- and, exactly
/// as there, the handles opened before the failure are not closed here.
fn makePipes(handle: *c.JanetHandle, reverse: bool, errflag: *c_int) c.JanetHandle {
    var handles: [2]c.JanetHandle = undefined;
    if (has_ev) {
        // Non-blocking pipes.
        if (janet_make_pipe(&handles, if (reverse) 2 else 1) != 0) {
            errflag.* = 1;
            return handle_none;
        }
        if (reverse) std.mem.swap(c.JanetHandle, &handles[0], &handles[1]);
        if (windows) {
            if (SetHandleInformation(handles[0], h.HANDLE_FLAG_INHERIT, 0) == 0) {
                errflag.* = 1;
                return handle_none;
            }
        }
    } else if (windows) {
        var sa_attr: h.SECURITY_ATTRIBUTES = std.mem.zeroes(h.SECURITY_ATTRIBUTES);
        sa_attr.nLength = @sizeOf(h.SECURITY_ATTRIBUTES);
        sa_attr.bInheritHandle = 1;
        if (CreatePipe(&handles[0], &handles[1], &sa_attr, 0) == 0) {
            errflag.* = 1;
            return handle_none;
        }
        if (reverse) std.mem.swap(c.JanetHandle, &handles[0], &handles[1]);
        // Do not inherit the side of the pipe this process owns.
        if (SetHandleInformation(handles[0], h.HANDLE_FLAG_INHERIT, 0) == 0) {
            errflag.* = 1;
            return handle_none;
        }
    } else {
        if (janet_os_pipe(&handles) != 0) {
            errflag.* = 1;
            return handle_none;
        }
        if (reverse) std.mem.swap(c.JanetHandle, &handles[0], &handles[1]);
    }
    handle.* = handles[1];
    return handles[0];
}

extern fn janet_stream(handle: c.JanetHandle, flags: u32, methods: ?*const c.JanetMethod) callconv(.c) *c.JanetStream;
extern fn janet_makejfile(f: ?*anyopaque, flags: i32) callconv(.c) *c.JanetFile;
extern fn _get_osfhandle(fd: c_int) callconv(.c) isize;
extern fn _open_osfhandle(handle: isize, flags: c_int) callconv(.c) c_int;
extern fn _fileno(f: ?*anyopaque) callconv(.c) c_int;
extern fn fileno(f: ?*anyopaque) callconv(.c) c_int;
extern fn fdopen(fd: c_int, mode: [*:0]const u8) callconv(.c) ?*anyopaque;
extern fn _fdopen(fd: c_int, mode: [*:0]const u8) callconv(.c) ?*anyopaque;
extern fn _close(fd: c_int) callconv(.c) c_int;
extern fn dup(fd: c_int) callconv(.c) c_int;

const stream_closed: u32 = 0x1;
const stream_readable: u32 = 0x200;
const stream_writable: u32 = 0x400;
const file_write: i32 = 1;
const file_read: i32 = 2;
const file_closed: i32 = 32;

/// `janet_getjstream`: the OS handle behind a `core/stream` or a `core/file`,
/// and the abstract it came from.
fn getJStream(argv: [*c]c.Janet, n: i32, orig: *?*anyopaque) raise.Raising(c.JanetHandle) {
    if (has_ev) {
        if (c.janet_checkabstract(argv[@intCast(n)], &c.janet_stream_type)) |p| {
            const stream: *c.JanetStream = @ptrCast(@alignCast(p));
            if (stream.flags & stream_closed != 0) return raise.panic("stream is closed");
            orig.* = stream;
            return stream.handle;
        }
    }
    if (c.janet_checkabstract(argv[@intCast(n)], &c.janet_file_type)) |p| {
        const f: *c.JanetFile = @ptrCast(@alignCast(p));
        if (f.flags & file_closed != 0) return raise.panic("file is closed");
        orig.* = f;
        if (windows) return @ptrFromInt(@as(usize, @bitCast(_get_osfhandle(_fileno(f.file)))));
        return fileno(f.file);
    }
    return pp_format.panicf("expected file|stream, got %v", .{argv[@intCast(n)]});
}

/// `get_stdio_for_handle`. Answers null where the host refused to give this
/// process its own copy of the handle, which the caller reports as "failed to
/// construct proc".
fn getStdioForHandle(handle: c.JanetHandle, orig: ?*anyopaque, iswrite: bool) ?*Stdio {
    if (has_ev) {
        const p = orig orelse
            return janet_stream(handle, if (iswrite) stream_writable else stream_readable, null);
        if (c.janet_abstract_type(p) == &c.janet_file_type) {
            const jf: *c.JanetFile = @ptrCast(@alignCast(p));
            var flags: u32 = 0;
            if (jf.flags & file_write != 0) flags |= stream_writable;
            if (jf.flags & file_read != 0) flags |= stream_readable;
            // A file becoming a stream gets its own duplicate of the handle,
            // so that closing one does not close the other.
            if (windows) {
                const prochandle = GetCurrentProcess();
                var new_handle: c.JanetHandle = undefined;
                if (DuplicateHandle(prochandle, handle, prochandle, &new_handle, 0, 0, 0x2) == 0) {
                    return null;
                }
                return janet_stream(new_handle, flags, null);
            }
            const new_handle = dup(handle);
            if (new_handle < 0) return null;
            return janet_stream(new_handle, flags, null);
        }
        return @ptrCast(@alignCast(p));
    } else {
        if (orig) |p| return @ptrCast(@alignCast(p));
        if (windows) {
            const fd = _open_osfhandle(@bitCast(@intFromPtr(handle)), if (iswrite) h._O_WRONLY else h._O_RDONLY);
            if (fd == -1) return null;
            const f = _fdopen(fd, if (iswrite) "w" else "r") orelse {
                _ = _close(fd);
                return null;
            };
            return janet_makejfile(f, if (iswrite) file_write else file_read);
        }
        const f = fdopen(handle, if (iswrite) "w" else "r") orelse return null;
        return janet_makejfile(f, if (iswrite) file_write else file_read);
    }
}

// ==========================================================================
// The environment block, and the Windows command line
// ==========================================================================

/// `EnvBlock`: a double-NUL-terminated byte block on Windows, a NULL-terminated
/// vector of `key=value` strings on POSIX. Both are `janet_smalloc`'d and
/// freed by `cleanupEnv`.
const EnvBlock = if (windows) ?[*]u8 else ?[*:null]?[*:0]u8;

/// `os_execute_env`. The two blocks are built separately rather than unified,
/// which is `-Dos-process`'s note repeated here: the POSIX block drops a key
/// holding `=` or NUL and the Windows block does not, so `janet_os_env_key_ok`
/// is called only where C called it.
fn buildEnv(argc: i32, argv: [*c]c.Janet) raise.Raising(EnvBlock) {
    if (argc <= 2) return null;
    const dict = try arglayer.getDictionary(argv, 2);
    if (windows) {
        const temp = c.janet_buffer(10);
        var i: i32 = 0;
        while (i < dict.cap) : (i += 1) {
            const kv = &dict.kvs[@intCast(i)];
            if (c.janet_checktype(kv.key, c.JANET_STRING) == 0) continue;
            if (c.janet_checktype(kv.value, c.JANET_STRING) == 0) continue;
            const keys = c.janet_unwrap_string(kv.key);
            const vals = c.janet_unwrap_string(kv.value);
            const klen = c.janet_string_length(keys);
            const vlen = c.janet_string_length(vals);
            try containers.bufferExtra(temp, klen + vlen + 2);
            janet_os_env_entry_fill(keys, klen, vals, vlen, temp.*.data + @as(usize, @intCast(temp.*.count)));
            temp.*.count += klen + vlen + 2;
        }
        // A Windows environment block is double-NUL terminated.
        if (temp.*.count == 0) try containers.bufferPushU8(temp, 0);
        try containers.bufferPushU8(temp, 0);
        const ret: [*]u8 = @ptrCast(janet_smalloc(@intCast(temp.*.count)).?);
        @memcpy(ret[0..@intCast(temp.*.count)], temp.*.data[0..@intCast(temp.*.count)]);
        return ret;
    } else {
        const slots: usize = @intCast(dict.len + 1);
        const envp: [*]?[*:0]u8 = @ptrCast(@alignCast(janet_smalloc(@sizeOf(?*u8) * slots).?));
        var j: usize = 0;
        var i: i32 = 0;
        while (i < dict.cap) : (i += 1) {
            const kv = &dict.kvs[@intCast(i)];
            if (c.janet_checktype(kv.key, c.JANET_STRING) == 0) continue;
            if (c.janet_checktype(kv.value, c.JANET_STRING) == 0) continue;
            const keys = c.janet_unwrap_string(kv.key);
            const vals = c.janet_unwrap_string(kv.value);
            const klen = c.janet_string_length(keys);
            const vlen = c.janet_string_length(vals);
            // The key must hold no NUL and no `=`.
            if (janet_os_env_key_ok(keys, klen) == 0) continue;
            const item: [*]u8 = @ptrCast(janet_smalloc(@as(usize, @intCast(klen)) + @as(usize, @intCast(vlen)) + 2).?);
            janet_os_env_entry_fill(keys, klen, vals, vlen, item);
            envp[j] = @ptrCast(item);
            j += 1;
        }
        envp[j] = null;
        return @ptrCast(envp);
    }
}

/// `os_execute_cleanup`.
fn cleanupEnv(envp: EnvBlock, child_argv: ?*const anyopaque) void {
    if (windows) {
        if (envp) |p| janet_sfree(p);
    } else {
        janet_sfree(@constCast(child_argv));
        if (envp) |p| {
            var i: usize = 0;
            while (p[i]) |item| : (i += 1) janet_sfree(item);
            janet_sfree(@ptrCast(p));
        }
    }
}

/// `os_exec_escape`: one command line string in the form `CommandLineToArgvW`
/// parses. The escaping rule itself is `-Dos-process`'s and is compiled and
/// tested on every platform; this is the measure-then-fill wrapper, which
/// exists because growing the buffer can raise and the escaping may not.
fn execEscape(args: c.JanetView) raise.Raising(*c.JanetBuffer) {
    const b = c.janet_buffer(0);
    var i: i32 = 0;
    while (i < args.len) : (i += 1) {
        const arg = try arglayer.getCString(args.items, i);
        if (i != 0) try containers.bufferPushU8(b, ' ');
        const needed = janet_os_exec_escape_arg(@ptrCast(arg), null, 0);
        if (needed < 0) return raise.panic("command line string too long (max 8191 characters)");
        try containers.bufferExtra(b, needed);
        _ = janet_os_exec_escape_arg(@ptrCast(arg), b.*.data + @as(usize, @intCast(b.*.count)), needed);
        b.*.count += needed;
    }
    try containers.bufferPushU8(b, 0);
    return b;
}

// ==========================================================================
// `os/execute`, `os/spawn` and `os/posix-exec`
// ==========================================================================

const ExecuteMode = enum { execute, spawn, exec };

extern fn posix_spawn_file_actions_init(actions: *h.posix_spawn_file_actions_t) callconv(.c) c_int;
extern fn posix_spawn_file_actions_destroy(actions: *h.posix_spawn_file_actions_t) callconv(.c) c_int;
extern fn posix_spawn_file_actions_adddup2(actions: *h.posix_spawn_file_actions_t, fd: c_int, newfd: c_int) callconv(.c) c_int;
extern fn posix_spawn_file_actions_addclose(actions: *h.posix_spawn_file_actions_t, fd: c_int) callconv(.c) c_int;
extern fn posix_spawn_file_actions_addchdir(actions: *h.posix_spawn_file_actions_t, path: [*:0]const u8) callconv(.c) c_int;
extern fn posix_spawn_file_actions_addchdir_np(actions: *h.posix_spawn_file_actions_t, path: [*:0]const u8) callconv(.c) c_int;
extern fn posix_spawn(
    pid: *h.pid_t,
    path: [*:0]const u8,
    actions: ?*const h.posix_spawn_file_actions_t,
    attrp: ?*const anyopaque,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*c][*c]u8,
) callconv(.c) c_int;
extern fn posix_spawnp(
    pid: *h.pid_t,
    file: [*:0]const u8,
    actions: ?*const h.posix_spawn_file_actions_t,
    attrp: ?*const anyopaque,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*c][*c]u8,
) callconv(.c) c_int;

extern fn CreateProcessA(
    application: ?[*:0]const u8,
    command_line: ?[*]u8,
    proc_attrs: ?*h.SECURITY_ATTRIBUTES,
    thread_attrs: ?*h.SECURITY_ATTRIBUTES,
    inherit: c_int,
    flags: u32,
    environment: ?*anyopaque,
    current_directory: ?[*:0]const u8,
    startup: *h.STARTUPINFOA,
    info: *h.PROCESS_INFORMATION,
) callconv(.c) c_int;
extern fn GetLastError() callconv(.c) u32;
extern fn FormatMessageA(
    flags: u32,
    source: ?*const anyopaque,
    message_id: u32,
    language_id: u32,
    buffer: [*]u8,
    size: u32,
    args: ?*anyopaque,
) callconv(.c) u32;

/// Where the child's three descriptors come from, and which of them this
/// process still owns after the spawn.
const Redirection = struct {
    orig_in: ?*anyopaque = null,
    orig_out: ?*anyopaque = null,
    orig_err: ?*anyopaque = null,
    new_in: c.JanetHandle = handle_none,
    new_out: c.JanetHandle = handle_none,
    new_err: c.JanetHandle = handle_none,
    pipe_in: c.JanetHandle = handle_none,
    pipe_out: c.JanetHandle = handle_none,
    pipe_err: c.JanetHandle = handle_none,
    stderr_is_stdout: bool = false,
    errflag: c_int = 0,
    owner_flags: c_int = 0,
};

fn executeImpl(argc: i32, argv: [*c]c.Janet, mode: ExecuteMode) raise.Raising(c.Janet) {
    try lifecycle.sandboxAssert(c.JANET_SANDBOX_SUBPROCESS);
    try arglayer.arity(argc, 1, 3);

    const is_spawn = mode == .spawn;
    var flags: u64 = 0;
    if (argc > 1) flags = try arglayer.getFlags(argv, 1, "epxd");

    const use_environ = !flagAt(flags, 0);
    const envp = try buildEnv(argc, argv);

    const exargs = try arglayer.getIndexed(argv, 0);
    if (exargs.len < 1) return raise.panic("expected at least 1 command line argument");

    var r: Redirection = .{};
    r.owner_flags = if (is_spawn and flags & 0x8 != 0) proc_allow_zombie else 0;

    if (argc > 2 and mode != .exec) {
        const tab = try arglayer.getDictionary(argv, 2);
        const maybe_stdin = c.janet_dictionary_get(tab.kvs, tab.cap, c.janet_ckeywordv("in"));
        const maybe_stdout = c.janet_dictionary_get(tab.kvs, tab.cap, c.janet_ckeywordv("out"));
        const maybe_stderr = c.janet_dictionary_get(tab.kvs, tab.cap, c.janet_ckeywordv("err"));
        var slot = maybe_stdin;
        if (is_spawn and c.janet_keyeq(maybe_stdin, "pipe") != 0) {
            r.new_in = makePipes(&r.pipe_in, true, &r.errflag);
            r.owner_flags |= proc_owns_stdin;
        } else if (c.janet_checktype(maybe_stdin, c.JANET_NIL) == 0) {
            r.new_in = try getJStream(&slot, 0, &r.orig_in);
        }
        slot = maybe_stdout;
        if (is_spawn and c.janet_keyeq(maybe_stdout, "pipe") != 0) {
            r.new_out = makePipes(&r.pipe_out, false, &r.errflag);
            r.owner_flags |= proc_owns_stdout;
        } else if (c.janet_checktype(maybe_stdout, c.JANET_NIL) == 0) {
            r.new_out = try getJStream(&slot, 0, &r.orig_out);
        }
        slot = maybe_stderr;
        if (is_spawn and c.janet_keyeq(maybe_stderr, "pipe") != 0) {
            r.new_err = makePipes(&r.pipe_err, false, &r.errflag);
            r.owner_flags |= proc_owns_stderr;
        } else if (c.janet_keyeq(maybe_stderr, "out") != 0) {
            r.stderr_is_stdout = true;
        } else if (c.janet_checktype(maybe_stderr, c.JANET_NIL) == 0) {
            r.new_err = try getJStream(&slot, 0, &r.orig_err);
        }
    }

    // The working directory, for `os/execute` and `os/spawn` alike.
    var chdir_path: ?[*:0]const u8 = null;
    if (argc > 2) {
        const tab = try arglayer.getDictionary(argv, 2);
        const workdir = c.janet_dictionary_get(tab.kvs, tab.cap, c.janet_ckeywordv("cd"));
        if (c.janet_checktype(workdir, c.JANET_STRING) != 0) {
            chdir_path = @ptrCast(c.janet_unwrap_string(workdir));
            if (!spawn_chdir) {
                return pp_format.panicf(":cd argument not supported on this system - %s", .{chdir_path.?});
            }
        } else if (c.janet_checktype(workdir, c.JANET_NIL) == 0) {
            // The misspelling in this message is the C original's.
            return pp_format.panicf("expected string for :cd argumnet, got %v", .{workdir});
        }
    }

    if (r.errflag != 0) {
        if (isHandle(r.pipe_in)) closeHandle(r.pipe_in);
        if (isHandle(r.pipe_out)) closeHandle(r.pipe_out);
        if (isHandle(r.pipe_err)) closeHandle(r.pipe_err);
        return raise.panic("failed to create pipes");
    }

    const proc = if (windows)
        try spawnWindows(argv, exargs, &r, flags, envp, use_environ, chdir_path)
    else
        try spawnPosix(argv, exargs, &r, flags, envp, use_environ, chdir_path, mode);

    proc.flags = r.owner_flags;
    if (flagAt(flags, 2)) proc.flags |= proc_error_nonzero;
    if (is_spawn) {
        // Only `os/spawn` hands the caller the three ends it kept.
        if (isHandle(r.new_in)) {
            proc.in = getStdioForHandle(r.new_in, r.orig_in, true) orelse
                return raise.panic("failed to construct proc");
        }
        if (isHandle(r.new_out)) {
            proc.out = getStdioForHandle(r.new_out, r.orig_out, false) orelse
                return raise.panic("failed to construct proc");
        }
        if (isHandle(r.new_err)) {
            proc.err = getStdioForHandle(r.new_err, r.orig_err, false) orelse
                return raise.panic("failed to construct proc");
        }
        return c.janet_wrap_abstract(proc);
    }
    return procWaitImpl(proc);
}

fn newProc() *JanetProc {
    const proc: *JanetProc = @ptrCast(@alignCast(c.janet_abstract(abstract_type.stored(&proc_type), @sizeOf(JanetProc))));
    proc.return_code = -1;
    proc.in = null;
    proc.out = null;
    proc.err = null;
    proc.flags = 0;
    return proc;
}

/// The POSIX spawn, and the `exec` mode that never returns.
///
/// `child_argv` and the environment block are `janet_smalloc`'d and released
/// by `cleanupEnv` on the way out. A raise between the two -- from
/// `janet_getcstring` on a non-string element, say -- jumps past that release
/// in C and jumps past it here, which is the reproduction the marker at the
/// head of this file is about.
fn spawnPosix(
    argv: [*c]c.Janet,
    exargs: c.JanetView,
    r: *Redirection,
    flags: u64,
    envp: EnvBlock,
    use_environ: bool,
    chdir_path: ?[*:0]const u8,
    mode: ExecuteMode,
) raise.Raising(*JanetProc) {
    const slots: usize = @intCast(exargs.len + 1);
    const child_argv: [*]?[*:0]const u8 = @ptrCast(@alignCast(janet_smalloc(@sizeOf(?*u8) * slots).?));
    var i: i32 = 0;
    while (i < exargs.len) : (i += 1) {
        child_argv[@intCast(i)] = @ptrCast(try arglayer.getCString(exargs.items, i));
    }
    child_argv[@intCast(exargs.len)] = null;
    const cargv: [*:null]const ?[*:0]const u8 = @ptrCast(child_argv);

    if (use_environ) oa.lockEnviron();

    if (mode == .exec) {
        // Only a failure returns, and the message reads `errno` rather than
        // the result, so the result is deliberately discarded.
        if (!use_environ) oa.setEnviron(@ptrCast(envp));
        _ = janet_os_exec(cargv[0].?, cargv, if (flagAt(flags, 1)) 1 else 0);
        // `%s`, not the `%p` the C original writes. `%p` pulls a `Janet` and
        // `cargv[0]` is a `char *`: a mismatched `va_arg` type, which is
        // undefined, so Part 8's rule applies rather than Part 9's and this
        // gets it right instead of reproducing it. The C prints the pointer's
        // bits as a denormal double; `FOUND.md` has the entry and records this
        // as a deliberate divergence.
        return pp_format.panicf("%s: %s", .{
            cargv[0].?,
            janet_strerror(if (errno() != 0) errno() else h.ENOENT),
        });
    }

    if (no_spawn) return raise.panic("subprocess creation not supported in this build");

    var actions: h.posix_spawn_file_actions_t = undefined;
    _ = posix_spawn_file_actions_init(&actions);
    if (spawn_chdir) {
        if (chdir_path) |path| {
            if (oa.spawn_chdir_np) {
                _ = posix_spawn_file_actions_addchdir_np(&actions, path);
            } else {
                _ = posix_spawn_file_actions_addchdir(&actions, path);
            }
        }
    }
    if (isHandle(r.pipe_in)) {
        _ = posix_spawn_file_actions_adddup2(&actions, r.pipe_in, 0);
        _ = posix_spawn_file_actions_addclose(&actions, r.pipe_in);
    } else if (isHandle(r.new_in) and r.new_in != 0) {
        _ = posix_spawn_file_actions_adddup2(&actions, r.new_in, 0);
        if (r.new_in != r.new_out and r.new_in != r.new_err) {
            _ = posix_spawn_file_actions_addclose(&actions, r.new_in);
        }
    }
    if (isHandle(r.pipe_out)) {
        _ = posix_spawn_file_actions_adddup2(&actions, r.pipe_out, 1);
        _ = posix_spawn_file_actions_addclose(&actions, r.pipe_out);
    } else if (isHandle(r.new_out) and r.new_out != 1) {
        _ = posix_spawn_file_actions_adddup2(&actions, r.new_out, 1);
        if (r.new_out != r.new_err) {
            _ = posix_spawn_file_actions_addclose(&actions, r.new_out);
        }
    }
    if (isHandle(r.pipe_err)) {
        _ = posix_spawn_file_actions_adddup2(&actions, r.pipe_err, 2);
        _ = posix_spawn_file_actions_addclose(&actions, r.pipe_err);
    } else if (isHandle(r.new_err) and r.new_err != 2) {
        _ = posix_spawn_file_actions_adddup2(&actions, r.new_err, 2);
        _ = posix_spawn_file_actions_addclose(&actions, r.new_err);
    } else if (r.stderr_is_stdout) {
        _ = posix_spawn_file_actions_adddup2(&actions, 1, 2);
    }

    var pid: h.pid_t = undefined;
    const environment: [*c][*c]u8 = if (use_environ) oa.getEnviron() else @ptrCast(envp);
    const status = if (flagAt(flags, 1))
        posix_spawnp(&pid, child_argv[0].?, &actions, null, cargv, environment)
    else
        posix_spawn(&pid, child_argv[0].?, &actions, null, cargv, environment);

    _ = posix_spawn_file_actions_destroy(&actions);

    if (isHandle(r.pipe_in)) _ = janet_os_close_fd(r.pipe_in);
    if (isHandle(r.pipe_out)) _ = janet_os_close_fd(r.pipe_out);
    if (isHandle(r.pipe_err)) _ = janet_os_close_fd(r.pipe_err);

    if (use_environ) oa.unlockEnviron();

    cleanupEnv(envp, @ptrCast(child_argv));
    if (status != 0) {
        // macOS leaves `errno` unset here, which is what the fallback is for.
        return pp_format.panicf("%p: %s", .{
            argv[0],
            janet_strerror(if (errno() != 0) errno() else h.ENOENT),
        });
    }

    const proc = newProc();
    proc.handles.pid = pid;
    return proc;
}

/// The Windows spawn. Compiled only for a Windows target and never run by this
/// project's tests, which `PLAN.md` records as the platform scope: the
/// cross-compile is what checks it.
fn spawnWindows(
    argv: [*c]c.Janet,
    exargs: c.JanetView,
    r: *Redirection,
    flags: u64,
    envp: EnvBlock,
    use_environ: bool,
    chdir_path: ?[*:0]const u8,
) raise.Raising(*JanetProc) {
    _ = argv;
    var sa_attr: h.SECURITY_ATTRIBUTES = std.mem.zeroes(h.SECURITY_ATTRIBUTES);
    var process_info: h.PROCESS_INFORMATION = std.mem.zeroes(h.PROCESS_INFORMATION);
    var startup_info: h.STARTUPINFOA = std.mem.zeroes(h.STARTUPINFOA);
    startup_info.cb = @sizeOf(h.STARTUPINFOA);
    startup_info.dwFlags |= h.STARTF_USESTDHANDLES;
    sa_attr.nLength = @sizeOf(h.SECURITY_ATTRIBUTES);

    const buf = try execEscape(exargs);
    if (buf.count > 8191) {
        if (isHandle(r.pipe_in)) _ = CloseHandle(r.pipe_in);
        if (isHandle(r.pipe_out)) _ = CloseHandle(r.pipe_out);
        if (isHandle(r.pipe_err)) _ = CloseHandle(r.pipe_err);
        return raise.panic("command line string too long (max 8191 characters)");
    }
    const path: [*:0]const u8 = @ptrCast(c.janet_unwrap_string(exargs.items[0]));

    startup_info.hStdInput = if (isHandle(r.pipe_in))
        r.pipe_in
    else if (isHandle(r.new_in))
        r.new_in
    else
        @ptrFromInt(@as(usize, @bitCast(_get_osfhandle(_fileno(@ptrCast(@alignCast(stdio.in())))))));

    startup_info.hStdOutput = if (isHandle(r.pipe_out))
        r.pipe_out
    else if (isHandle(r.new_out))
        r.new_out
    else
        @ptrFromInt(@as(usize, @bitCast(_get_osfhandle(_fileno(@ptrCast(@alignCast(stdio.out())))))));

    startup_info.hStdError = if (isHandle(r.pipe_err))
        r.pipe_err
    else if (isHandle(r.new_err))
        r.new_err
    else if (r.stderr_is_stdout)
        startup_info.hStdOutput
    else
        @ptrFromInt(@as(usize, @bitCast(_get_osfhandle(_fileno(@ptrCast(@alignCast(stdio.err())))))));

    var cp_failed = false;
    var cp_error_code: u32 = 0;
    if (CreateProcessA(
        if (flagAt(flags, 1)) null else path,
        buf.data,
        &sa_attr,
        &sa_attr,
        1,
        0,
        if (use_environ) null else @ptrCast(envp),
        chdir_path,
        &startup_info,
        &process_info,
    ) == 0) {
        cp_failed = true;
        cp_error_code = GetLastError();
    }

    if (isHandle(r.pipe_in)) _ = CloseHandle(r.pipe_in);
    if (isHandle(r.pipe_out)) _ = CloseHandle(r.pipe_out);
    if (isHandle(r.pipe_err)) _ = CloseHandle(r.pipe_err);

    cleanupEnv(envp, null);

    if (cp_failed) {
        var msgbuf: [256]u8 = undefined;
        msgbuf[0] = 0;
        _ = FormatMessageA(
            h.FORMAT_MESSAGE_FROM_SYSTEM | h.FORMAT_MESSAGE_IGNORE_INSERTS,
            null,
            cp_error_code,
            h.MAKELANGID(h.LANG_NEUTRAL, h.SUBLANG_DEFAULT),
            &msgbuf,
            msgbuf.len,
            null,
        );
        if (msgbuf[0] == 0) {
            _ = std.fmt.bufPrintZ(&msgbuf, "{d}", .{cp_error_code}) catch unreachable;
        }
        // The system message ends in a newline; cut the line short at it.
        var i: usize = 0;
        while (msgbuf[i] != 0) : (i += 1) {
            if (msgbuf[i] == '\n' or msgbuf[i] == '\r') {
                msgbuf[i] = 0;
                break;
            }
        }
        // The same mismatch in the other direction: the C original hands a
        // `Janet` to `%s`, which pulls a `const char *`. Undefined, so the
        // port passes the buffer this had already built.
        return pp_format.panicf("failed to create process: %s", .{@as([*c]const u8, @ptrCast(&msgbuf))});
    }

    const proc = newProc();
    proc.handles.p = process_info.hProcess;
    proc.handles.t = process_info.hThread;
    return proc;
}

/// `src/core/io.c`'s three handles. `stdin`, `stdout` and `stderr` are macros
/// that translate-c renders three incompatible ways across this project's
/// targets, which is why `io.c` keeps a one-line function for each; Part 11
/// records the three spellings.

fn executeCfn(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    return executeImpl(argc, argv, .execute);
}

fn spawnCfn(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    return executeImpl(argc, argv, .spawn);
}

fn posixExec(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    if (windows) return raise.panic("not supported on Windows");
    return executeImpl(argc, argv, .exec);
}

fn posixFork(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    _ = argv;
    try lifecycle.sandboxAssert(c.JANET_SANDBOX_SUBPROCESS);
    try arglayer.fixarity(argc, 0);
    if (windows) return raise.panic("not supported on Windows");
    const result = janet_os_fork();
    if (result == -1) return raise.panic(@ptrCast(janet_strerror(errno())));
    if (result != 0) {
        const proc: *JanetProc = @ptrCast(@alignCast(c.janet_abstract(abstract_type.stored(&proc_type), @sizeOf(JanetProc))));
        proc.* = std.mem.zeroes(JanetProc);
        proc.handles.pid = @intCast(result);
        proc.flags = proc_allow_zombie;
        return c.janet_wrap_abstract(proc);
    }
    return c.janet_wrap_nil();
}

fn posixChroot(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try lifecycle.sandboxAssert(c.JANET_SANDBOX_CHROOT);
    try arglayer.fixarity(argc, 1);
    if (windows) return raise.panic("not supported on Windows or Plan 9");
    const root = try arglayer.getCString(argv, 0);
    if (janet_os_chroot(@ptrCast(root)) == -1) {
        return raise.panic(@ptrCast(janet_strerror(errno())));
    }
    return c.janet_wrap_nil();
}

/// `os_shell_subr`, which runs on a worker thread.
///
/// It frees the copied command and leaves `args.argp` pointing at the freed
/// block; the default threaded callback frees it a second time, which aborts.
/// That is the defect `FOUND.md` records, reproduced here rather than
/// repaired, and it is why `test/os_process.c` exercises only the
/// no-argument form.
fn shellSubroutine(args: c.JanetEVGenericMessage) callconv(.c) c.JanetEVGenericMessage {
    var out = args;
    const stat = janet_os_system(@ptrCast(@alignCast(args.argp)));
    janet_free(args.argp);
    out.tag = if (args.argi != 0) c.JANET_EV_TCTAG_INTEGER else c.JANET_EV_TCTAG_BOOLEAN;
    out.argi = stat;
    return out;
}

fn shell(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try lifecycle.sandboxAssert(c.JANET_SANDBOX_SUBPROCESS);
    try arglayer.arity(argc, 0, 1);
    const cmd: ?[*:0]const u8 = if (argc != 0) @ptrCast(try arglayer.getCString(argv, 0)) else null;
    if (has_ev) {
        var cmd_copy: ?*anyopaque = null;
        if (cmd) |src| {
            const cmdlen = std.mem.len(src);
            const dest: [*]u8 = @ptrCast(janet_malloc(cmdlen + 1).?);
            @memcpy(dest[0..cmdlen], src[0..cmdlen]);
            dest[cmdlen] = 0;
            cmd_copy = dest;
        }
        try raise.crossing(c.janet_ev_threaded_await(&shellSubroutine, 0, argc, cmd_copy));
        unreachable;
    } else {
        const stat = janet_os_system(cmd);
        return if (argc != 0) wrapInteger(stat) else c.janet_wrap_boolean(stat);
    }
}

// ==========================================================================
// `os/sigaction`
// ==========================================================================

extern fn sigaction(sig: c_int, act: *const h.struct_sigaction, old: ?*h.struct_sigaction) callconv(.c) c_int;
extern fn sigemptyset(set: *h.sigset_t) callconv(.c) c_int;
extern fn sigaddset(set: *h.sigset_t, sig: c_int) callconv(.c) c_int;
extern fn sigprocmask(how: c_int, set: *const h.sigset_t, old: ?*h.sigset_t) callconv(.c) c_int;
/// libc's `raise`, which cannot be spelled `extern fn raise` here because
/// `raise` is the name this file imports the error mechanism under.
const raiseSignal = @extern(*const fn (c_int) callconv(.c) c_int, .{ .name = "raise" });

/// The handler Janet installs. It runs in signal context, so it may touch
/// nothing but `janet_ev_post_event`; everything else happens on the main
/// thread in `signalCallback`.
const Trampolines = struct {
    fn plain(sig: c_int) callconv(.c) void {
        var msg: c.JanetEVGenericMessage = std.mem.zeroes(c.JanetEVGenericMessage);
        msg.tag = sig;
        c.janet_ev_post_event(&c.janet_vm, &signalCallback, msg);
    }

    fn interrupting(sig: c_int) callconv(.c) void {
        var msg: c.JanetEVGenericMessage = std.mem.zeroes(c.JanetEVGenericMessage);
        msg.tag = sig;
        msg.argi = 1;
        c.janet_interpreter_interrupt(&c.janet_vm);
        c.janet_ev_post_event(&c.janet_vm, &signalCallback, msg);
    }
};

fn signalCallback(msg: c.JanetEVGenericMessage) callconv(.c) void {
    const sig = msg.tag;
    if (msg.argi != 0) c.janet_interpreter_interrupt_handled(null);
    const handlerv = c.janet_table_get(&c.janet_vm.signal_handlers, wrapInteger(sig));
    if (c.janet_checktype(handlerv, c.JANET_FUNCTION) == 0) {
        // Nothing here wants it: unblock this signal and re-raise, so that
        // another thread or the default disposition can take it.
        var set: h.sigset_t = undefined;
        _ = sigemptyset(&set);
        _ = sigaddset(&set, sig);
        _ = sigprocmask(h.SIG_BLOCK, &set, null);
        _ = raiseSignal(sig);
        return;
    }
    const handler = c.janet_unwrap_function(handlerv);
    const fiber = c.janet_fiber(handler, 64, 0, null);
    c.janet_schedule_soon(fiber, c.janet_wrap_nil(), c.JANET_SIGNAL_OK);
}

fn sigactionCfn(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try lifecycle.sandboxAssert(c.JANET_SANDBOX_SIGNAL);
    try arglayer.arity(argc, 1, 3);
    if (windows) return raise.panic("unsupported on this platform");

    const sig = try getSignalKw(argv, 0);
    const handler = try arglayer.optFunction(argv, argc, 1, null);
    const can_interrupt = try arglayer.optBoolean(argv, argc, 2, 0) != 0;
    const oldhandler = c.janet_table_get(&c.janet_vm.signal_handlers, wrapInteger(sig));
    if (c.janet_checktype(oldhandler, c.JANET_NIL) == 0) _ = c.janet_gcunroot(oldhandler);
    if (handler) |f| {
        const handlerv = c.janet_wrap_function(f);
        c.janet_gcroot(handlerv);
        c.janet_table_put(&c.janet_vm.signal_handlers, wrapInteger(sig), handlerv);
    } else {
        c.janet_table_put(&c.janet_vm.signal_handlers, wrapInteger(sig), c.janet_wrap_nil());
    }

    // `mask` is used uninitialised by the C original: `sigaddset` adds to
    // whatever was on the stack, and only `sigemptyset` would have made it a
    // set holding just this signal. Reproduced -- it is a defined operation on
    // an indeterminate value rather than undefined behaviour, and the mask
    // only widens what is blocked during the handler.
    var mask: h.sigset_t = undefined;
    _ = sigaddset(&mask, sig);
    var action: h.struct_sigaction = std.mem.zeroes(h.struct_sigaction);
    action.sa_flags |= h.SA_RESTART;
    if (can_interrupt) {
        if (c.JANET_VM_HAS_INTERRUPT == 0) return raise.panic("interpreter interrupt not enabled");
        setHandler(&action, &Trampolines.interrupting);
    } else {
        setHandler(&action, &Trampolines.plain);
    }
    action.sa_mask = mask;
    var rc: c_int = undefined;
    while (true) {
        rc = sigaction(sig, &action, null);
        if (!(rc == -1 and errno() == h.EINTR)) break;
    }
    var set: h.sigset_t = undefined;
    _ = sigemptyset(&set);
    _ = sigaddset(&set, sig);
    _ = sigprocmask(h.SIG_UNBLOCK, &set, null);
    return c.janet_wrap_nil();
}

/// Install a handler into a `struct sigaction`, whichever of the three
/// spellings this platform's header uses.
///
/// POSIX says `sa_handler` may be a macro over a union member, and every libc
/// takes it up differently. translate-c renders what the header says, so the
/// field path is:
///
/// | libc | path |
/// | --- | --- |
/// | macOS | `__sigaction_u.__sa_handler` |
/// | musl | `__sa_handler.sa_handler` |
/// | glibc | `__sigaction_handler.sa_handler` |
///
/// Only the host's spelling was needed to compile on the host, which is why
/// the cross-compiles are what found this -- the second portability fault
/// this increment owes to them, and the third increment running. The lookup
/// is written out rather than guessed at by position so that a fourth
/// spelling fails to compile here instead of writing into the wrong member.
inline fn setHandler(action: *h.struct_sigaction, f: *const fn (c_int) callconv(.c) void) void {
    const outer_names = .{ "sa_handler", "__sigaction_u", "__sa_handler", "__sigaction_handler" };
    const inner_names = .{ "__sa_handler", "sa_handler" };
    const outer = comptime blk: {
        for (outer_names) |name| {
            if (@hasField(h.struct_sigaction, name)) break :blk name;
        }
        @compileError("struct sigaction has no handler field this knows about");
    };
    const Outer = @FieldType(h.struct_sigaction, outer);
    if (@typeInfo(Outer) == .@"union") {
        const inner = comptime blk: {
            for (inner_names) |name| {
                if (@hasField(Outer, name)) break :blk name;
            }
            @compileError("struct sigaction's handler union has no member this knows about");
        };
        @field(@field(action, outer), inner) = @ptrCast(f);
    } else {
        @field(action, outer) = @ptrCast(f);
    }
}

// ==========================================================================
// `os/pipe`
// ==========================================================================

fn pipeCfn(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 0, 1);
    var fds: [2]c.JanetHandle = undefined;
    var flags: c_int = 0;
    if (argc > 0 and c.janet_checktype(argv[0], c.JANET_NIL) == 0) {
        flags = @intCast(try arglayer.getFlags(argv, 0, "WR"));
    }
    if (janet_make_pipe(&fds, flags) != 0) return raise.panicv(c.janet_ev_lasterr());
    const reader = janet_stream(fds[0], if (flags & 2 != 0) 0 else stream_readable, null);
    const writer = janet_stream(fds[1], if (flags & 1 != 0) 0 else stream_writable, null);
    var tup = [2]c.Janet{ c.janet_wrap_abstract(reader), c.janet_wrap_abstract(writer) };
    return c.janet_wrap_tuple(c.janet_tuple_n(&tup, 2));
}

// ==========================================================================
// Registration
// ==========================================================================

pub fn entries() []const corefn.Entry {
    const list = comptime blk: {
        var acc: []const corefn.Entry = &.{};
        acc = acc ++ [_]corefn.Entry{
            corefn.reg("os/execute", &executeCfn, @src(), "(os/execute args &opt flags env)", "Execute a program on the system and return the exit code. `args` is an array/tuple " ++
                "of strings. The first string is the name of the program and the remainder are " ++
                "arguments passed to the program. `flags` is a keyword made from the following " ++
                "characters that modifies how the program executes:\n" ++
                "* :e - enables passing an environment to the program. Without 'e', the " ++
                "current environment is inherited.\n" ++
                "* :p - allows searching the current PATH for the program to execute. " ++
                "Without this flag, the first element of `args` must be an absolute path.\n" ++
                "* :x - raises error if exit code is non-zero.\n" ++
                "* :d - prevents the garbage collector terminating the program (if still running) " ++
                "and calling the equivalent of `os/proc-wait` (allows zombie processes).\n" ++
                "`env` is a table/struct mapping environment variables to values. It can also " ++
                "contain the keys :in, :out, and :err, which allow redirecting stdio in the " ++
                "subprocess. :in, :out, and :err should be core/file or core/stream values. " ++
                "If core/stream values are used, the caller is responsible for ensuring pipes do not " ++
                "cause the program to block and deadlock."),
            corefn.reg("os/spawn", &spawnCfn, @src(), "(os/spawn args &opt flags env)", "Execute a program on the system and return a core/process value representing the " ++
                "spawned subprocess. Takes the same arguments as `os/execute` but does not wait for " ++
                "the subprocess to complete. Unlike `os/execute`, the value `:pipe` can be used for " ++
                ":in, :out and :err keys in `env`. If used, the returned core/process will have a " ++
                "writable stream in the :in field and readable streams in the :out and :err fields. " ++
                "On non-Windows systems, the subprocess PID will be in the :pid field. The caller is " ++
                "responsible for waiting on the process (e.g. by calling `os/proc-wait` on the " ++
                "returned core/process value) to avoid creating zombie process. After the subprocess " ++
                "completes, the exit value is in the :return-code field. If `flags` includes 'x', a " ++
                "non-zero exit code will cause a waiting fiber to raise an error. The use of " ++
                "`:pipe` may fail if there are too many active file descriptors. The caller is " ++
                "responsible for closing pipes created by `:pipe` (either individually or using " ++
                "`os/proc-close`). Similar to `os/execute`, the caller is responsible for ensuring " ++
                "pipes do not cause the program to block and deadlock. As a special case, the stream passed to `:err` " ++
                "can be the keyword `:out` to redirect stderr to stdout in the subprocess."),
            corefn.reg("os/shell", &shell, @src(), "(os/shell str)", "Pass a command string str directly to the system shell."),
            corefn.reg("os/posix-fork", &posixFork, @src(), "(os/posix-fork)", "Make a `fork` system call and create a new process. Return nil if in the new process, otherwise a core/process object (as returned by os/spawn). " ++
                "Not supported on all systems (POSIX and Plan 9 only)."),
            corefn.reg("os/posix-exec", &posixExec, @src(), "(os/posix-exec args &opt flags env)", "Use the execvpe or execve system calls to replace the current process with an interface similar to os/execute. " ++
                "However, instead of creating a subprocess, the current process is replaced. Is not supported on Windows, and " ++
                "does not allow redirection of stdio."),
            corefn.reg("os/posix-chroot", &posixChroot, @src(), "(os/posix-chroot dirname)", "Call `chroot` to change the root directory to `dirname`. " ++
                "Not supported on all systems (POSIX only)."),
            // Process management is not sandboxed: a build that cannot create
            // processes can still be handed one by an embedder's cfunction.
            corefn.reg("os/proc-wait", &procWait, @src(), "(os/proc-wait proc)", "Suspend the current fiber until the subprocess `proc` completes. Once `proc` " ++
                "completes, return the exit code of `proc`. If called more than once on the same " ++
                "core/process value, will raise an error. When creating subprocesses using " ++
                "`os/spawn`, this function should be called on the returned value to avoid zombie " ++
                "processes."),
            corefn.reg("os/proc-kill", &procKill, @src(), "(os/proc-kill proc &opt wait signal)", "Kill the subprocess `proc` by sending SIGKILL to it on POSIX systems, or by closing " ++
                "the process handle on Windows. If `proc` has already completed, raise an error. If " ++
                "`wait` is truthy, will wait for `proc` to complete and return the exit code (this " ++
                "will raise an error if `proc` is being waited for). Otherwise, return `proc`. If " ++
                "`signal` is provided, send it instead of SIGKILL. Signal keywords are named after " ++
                "their C counterparts but in lowercase with the leading SIG stripped. `signal` is " ++
                "ignored on Windows."),
            corefn.reg("os/proc-close", &procClose, @src(), "(os/proc-close proc)", "Close pipes created for subprocess `proc` by `os/spawn` if they have not been " ++
                "closed. Then, if `proc` is not being waited for, wait. If this function waits, when " ++
                "`proc` completes, return the exit code of `proc`. Otherwise, return nil."),
            corefn.reg("os/getpid", &procGetpid, @src(), "(os/getpid)", "Get the process ID of the current process."),
        };
        if (has_ev) acc = acc ++ [_]corefn.Entry{
            corefn.reg("os/sigaction", &sigactionCfn, @src(), "(os/sigaction which &opt handler interrupt-interpreter)", "Add a signal handler for a given action. Use nil for the `handler` argument to remove a signal handler. " ++
                "All signal handlers are the same as supported by `os/proc-kill`."),
        };
        break :blk acc[0..acc.len].*;
    };
    return &list;
}

/// `os/pipe` is registered with `os/open` after the process family rather than
/// with it, and only under the event loop. The order of `janet_lib_os`'s table
/// is preserved because it is observable.
pub fn evEntries() []const corefn.Entry {
    if (!has_ev) return &.{};
    const list = comptime [_]corefn.Entry{
        corefn.reg("os/pipe", &pipeCfn, @src(), "(os/pipe &opt flags)", "Create a readable stream and a writable stream that are connected. Returns a two-element " ++
            "tuple where the first element is a readable stream and the second element is the writable " ++
            "stream. `flags` is a keyword set of flags to disable non-blocking settings on the ends of the pipe. " ++
            "This may be desired if passing the pipe to a subprocess with `os/spawn`.\n\n" ++
            "* :W - sets the writable end of the pipe to a blocking stream.\n" ++
            "* :R - sets the readable end of the pipe to a blocking stream.\n\n" ++
            "By default, both ends of the pipe are non-blocking for use with the `ev` module."),
    };
    return &list;
}
