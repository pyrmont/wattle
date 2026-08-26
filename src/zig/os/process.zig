//! The `os/` process surface: launching, waiting on, signalling and piping to
//! a child.
//!
//! `os_procs.zig` and `os_process.zig` until Phase 12 increment 6f -- the
//! cfunctions and the portable rules with the scalar host calls beneath them.
//! The two were already Zig to Zig, reached through an ordinary `@import` at
//! twenty-eight call sites rather than through the C-ABI seam, so the merge
//! only drops a qualifier.
//!
//! ## Why this is one file and not four
//!
//! `port/TREE.md` designed `os/process.zig` with `spawn.zig`, `signals.zig` and
//! `pipe.zig` beside it, and none of the three earns a name. The heuristic
//! splits a piece out when it has a name **Janet already publishes** -- a type,
//! a cfun family, a module -- or when it exists because the platform differs.
//! This file registers twelve cfunctions and not one of those three names is
//! among them: there is no `os/spawn` family (there is `os/spawn`, `os/execute`
//! and `os/shell`, which share no name), `os/sigaction` is a single cfunction,
//! and so is `os/pipe`. A leaf called `signals` would claim something the tree
//! cannot point at.
//!
//! `JanetProc` is the one thing here Janet does publish as a type, and it was
//! the one candidate with a real case. It stays in the bucket because splitting
//! it out inverts the file: the type's four methods are 316 lines against the
//! 1,500 that create and drive it, so the leaf would be the core and the bucket
//! the periphery.
//!
//! **This is the same ruling as `os/fs/paths.zig`, which also does not exist.**
//! The cost is a large file -- second only to `ev.zig` -- and the compensation
//! is that its name claims exactly what it holds. A name that claims nothing
//! cannot claim wrongly.
//!
//! `shell` was declared in both halves and they are not duplicates: the host
//! call, and the cfunction that checks arguments and calls it. The cfunction is
//! `shellCfn` now, which is this file's own convention -- `executeCfn`,
//! `spawnCfn`, `sigactionCfn`, `pipeCfn`. The three `wait_*` constants *were*
//! duplicates and there is one copy.

const std = @import("std");
const builtin = @import("builtin");
const oa = @import("abi.zig");
const corefn = @import("corefn");
const raise = @import("raise");
const pp_format = @import("../pp/format.zig");
const os_files = @import("../os/fs.zig");
const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");
const stdio = @import("../stdio.zig");
const ev_loop = @import("../ev.zig");
const vm_lifecycle = @import("../vm/lifecycle.zig");
const ev_stream = @import("../ev/stream.zig");
const abstract_type = @import("../abstract_type.zig");
const method_type = @import("../method_type.zig");
const tables = @import("../value/tables.zig");
const gc_alloc = @import("../gc.zig");
const tuples = @import("../value/tuples.zig");
const utils = @import("../utils.zig");
const gc_mark = @import("../gc/mark.zig");
const vm_state = @import("../vm/lifecycle.zig");
const kind = @import("../value/helpers/kind.zig");
const wrap = @import("../value/helpers/wrap.zig");
const args_core = @import("../args.zig");
const buffers = @import("../value/buffers.zig");
const abstracts = @import("../value/abstracts.zig");
const fibers = @import("../value/fibers.zig");
const config = @import("config");
const value = @import("../value.zig");
const io = @import("../io.zig");
// ---------------------------------------------------------------------------
// The cfunctions -- what `os_procs.zig` was.
// ---------------------------------------------------------------------------

const h = oa.h;

const windows = builtin.os.tag == .windows;

pub const has_ev = config.ev;
pub const no_spawn = !config.spawn;

/// `JANET_SPAWN_CHDIR`: whether `posix_spawn_file_actions_addchdir` exists.
/// `os/abi.h` enumerates the systems, because the extension follows no
/// standard and C is where that enumeration already lived.
const spawn_chdir = oa.spawn_chdir;

// ==========================================================================
// `-Dos-process`'s kernels, and the rest of the C ABI this file stands on
// ==========================================================================

/// `-Dos-process`'s kernels, by import.
///
/// Each of these was declared here as an `extern fn` under a `janet_os_*`
/// name and `@export`ed from `zig`, which is the shape `os.c`
/// needed when they were the first Zig inside it. This file is the only
/// caller any of them has ever had, and both ends have been Zig since Phase
/// 10 Part 18 -- so the symbols were fourteen exports that existed to let one
/// Zig file call another. Phase 11 Part 20 replaced them with the import,
/// which is rule 44 applied a second time.
/// `src/core/util.h`, declared here rather than in `cabi.zig`.
extern fn janet_strerror(e: c_int) callconv(.c) [*:0]const u8;

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
inline fn wrapInteger(x: i32) types.Janet {
    return wrap.fromNumber(@floatFromInt(x));
}

inline fn errno() c_int {
    return std.c._errno().*;
}

/// `JANET_OS_WAIT_*` in `src/core/os.c`. The classification crosses the
/// boundary; the policy that turns it into the number Janet reports is here,
/// because the fourth outcome raises.
/// `janet_flag_at`, which is a function-like macro and does not survive
/// translation.
inline fn flagAt(flags: u64, index: u6) bool {
    return flags & (@as(u64, 1) << index) != 0;
}

// ==========================================================================
// The signal number table
// ==========================================================================

/// The names are `zig`'s and are reached by position through
/// `signalIndex`, so that the two halves cannot disagree about the
/// order. This is the other half: what number each position carries on *this*
/// platform, or -1 where the headers define none.
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
fn getSignalKw(argv: []const types.Janet, n: i32) raise.Raising(c_int) {
    const kw = try args_core.getKeyword(argv, n);
    const index = signalIndex(kw, types.stringHead(kw).length);
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
const Stdio = if (has_ev) types.JanetStream else types.JanetFile;

const JanetProc = extern struct {
    flags: c_int,
    handles: if (windows) extern struct { p: types.JanetHandle, t: types.JanetHandle } else extern struct { pid: h.pid_t },
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
    var val: i32 = 0;
    const outcome = wait(proc.pid(), &val);
    if (outcome == wait_exited) return val;
    if (outcome == wait_stopped or outcome == wait_signaled) return val + 128;
    return pp_format.panicf("Undefined status code for process termination, %d.", .{val});
}

extern fn WaitForSingleObject(handle: types.JanetHandle, ms: u32) callconv(.c) u32;
extern fn GetExitCodeProcess(handle: types.JanetHandle, code: *u32) callconv(.c) c_int;
extern fn TerminateProcess(handle: types.JanetHandle, code: c_uint) callconv(.c) c_int;
extern fn CloseHandle(handle: types.JanetHandle) callconv(.c) c_int;
extern fn GetCurrentProcess() callconv(.c) types.JanetHandle;
extern fn DuplicateHandle(
    src_proc: types.JanetHandle,
    src: types.JanetHandle,
    dst_proc: types.JanetHandle,
    dst: *types.JanetHandle,
    access: u32,
    inherit: c_int,
    options: u32,
) callconv(.c) c_int;
extern fn SetHandleInformation(handle: types.JanetHandle, mask: u32, flags: u32) callconv(.c) c_int;
extern fn CreatePipe(
    read: *types.JanetHandle,
    write: *types.JanetHandle,
    attrs: *h.SECURITY_ATTRIBUTES,
    size: u32,
) callconv(.c) c_int;

/// The threaded wait, and the callback that runs on the main thread when it
/// finishes. Only referenced under the event loop, which is what keeps them
/// out of a `-Dev=false` build: Zig does not analyse an unreferenced function.
const Waiter = struct {
    fn subroutine(args: types.JanetEVGenericMessage) callconv(.c) types.JanetEVGenericMessage {
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

    fn callbackImpl(args: types.JanetEVGenericMessage) raise.Raising(void) {
        const proc: *JanetProc = @ptrCast(@alignCast(args.argp orelse return));
        const status = args.tag;
        proc.return_code = status;
        proc.flags |= proc_waited;
        proc.flags &= ~proc_waiting;
        _ = gc_alloc.gcunroot(wrap.fromAbstract(proc));
        _ = gc_alloc.gcunroot(wrap.fromFiber(args.fiber.?));
        const sched_id: u32 = @bitCast(args.argi);
        if (fibers.canResume(args.fiber.?) != 0 and args.fiber.?.sched_id == sched_id) {
            if (status != 0 and proc.flags & proc_error_nonzero != 0) {
                const s = try pp_format.formatc("command failed with non-zero exit code %d", .{status});
                try ev_loop.cancel(args.fiber.?, wrap.fromString(s));
            } else {
                ev_loop.schedule(args.fiber.?, wrapInteger(status));
            }
        }
    }

    // A `JanetCallback`, run by the event loop on the thread that receives
    // the event. Nothing above it can take an error.
    fn callback(args: types.JanetEVGenericMessage) callconv(.c) void {
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
            _ = sendSignal(proc.pid(), h.SIGKILL);
            if (proc.flags & proc_waiting == 0) reap(proc.pid());
        }
    }
    return 0;
}

fn procMark(p: ?*anyopaque, s: usize) callconv(.c) c_int {
    _ = s;
    const proc: *JanetProc = @ptrCast(@alignCast(p.?));
    if (proc.in) |x| gc_mark.mark(wrap.fromAbstract(x));
    if (proc.out) |x| gc_mark.mark(wrap.fromAbstract(x));
    if (proc.err) |x| gc_mark.mark(wrap.fromAbstract(x));
    return 0;
}

/// `os_proc_wait_impl`. Under the event loop it never returns -- `janet_await`
/// is `JANET_NO_RETURN` -- and without it the wait happens inline and the exit
/// code is the result. The C original spells that with two different return
/// types behind one `#ifdef`; this returns an optional instead, and the two
/// callers read it the same way.
fn procWaitImpl(proc: *JanetProc) raise.Raising(types.Janet) {
    if (proc.flags & (proc_waited | proc_waiting) != 0) {
        return raise.panic("cannot wait twice on a process");
    }
    if (has_ev) {
        // The threaded call resumes the current fiber when the child exits,
        // and `janet_await` does not return; the exit code reaches Janet
        // through the callback rather than through this frame.
        proc.flags |= proc_waiting;
        var targs: types.JanetEVGenericMessage = std.mem.zeroes(types.JanetEVGenericMessage);
        targs.argp = proc;
        targs.fiber = fibers.root();
        targs.argi = @bitCast(targs.fiber.?.sched_id);
        gc_alloc.gcroot(wrap.fromAbstract(proc));
        gc_alloc.gcroot(wrap.fromFiber(targs.fiber.?));
        try ev_loop.threadedCall(&Waiter.subroutine, targs, &Waiter.callback);
        return ev_loop.awaitEvent();
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

fn procWait(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 1);
    const proc: *JanetProc = @ptrCast(@alignCast((try args_core.getAbstract(argv, 0, abstract_type.stored(&proc_type))).?));
    return procWaitImpl(proc);
}

fn procKill(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.arity(argv, 1, 3);
    const proc: *JanetProc = @ptrCast(@alignCast((try args_core.getAbstract(argv, 0, abstract_type.stored(&proc_type))).?));
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
        if (@as(i32, @intCast(argv.len)) == 3) signal = try getSignalKw(argv, 2);
        const status = sendSignal(proc.pid(), if (signal == -1) h.SIGKILL else signal);
        if (status != 0) return raise.panic(@ptrCast(janet_strerror(errno())));
    }
    // Having killed it, wait on it -- but only if asked.
    if (@as(i32, @intCast(argv.len)) > 1 and kind.truthy(argv[1]) != 0) return procWaitImpl(proc);
    return argv[0];
}

extern fn janet_stream_close(stream: *types.JanetStream) callconv(.c) void;
extern fn janet_file_close(file: *types.JanetFile) callconv(.c) c_int;

inline fn closeStdio(x: *Stdio) raise.Raising(void) {
    if (has_ev) try ev_stream.streamClose(x) else _ = janet_file_close(x);
}

fn procClose(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 1);
    const proc: *JanetProc = @ptrCast(@alignCast((try args_core.getAbstract(argv, 0, abstract_type.stored(&proc_type))).?));
    if (proc.flags & proc_owns_stdin != 0) try closeStdio(proc.in.?);
    if (proc.flags & proc_owns_stdout != 0) try closeStdio(proc.out.?);
    if (proc.flags & proc_owns_stderr != 0) try closeStdio(proc.err.?);
    proc.flags &= ~(proc_owns_stdin | proc_owns_stdout | proc_owns_stderr);
    if (proc.flags & (proc_waited | proc_waiting) != 0) return wrap.fromNil();
    return procWaitImpl(proc);
}

fn procGetpid(argv: []types.Janet) raise.Raising(types.Janet) {
    try vm_lifecycle.sandboxAssert(constants.JANET_SANDBOX_SUBPROCESS);
    try args_core.fixarity(argv, 0);
    return wrap.fromNumber(@floatFromInt(processId()));
}

// ==========================================================================
// The abstract type's own table
//
// `proc_methods` carries three real methods and three dud entries. The duds
// are what `janet_nextmethod` walks, so `(keys p)` reports `:in`, `:out` and
// `:err` as well; Part 7 found that the table's *order* is observable for the
// same reason, and it is preserved here.
// ==========================================================================

const proc_methods = [_]method_type.Method{
    .{ .name = "wait", .cfun = &procWait },
    .{ .name = "kill", .cfun = &procKill },
    .{ .name = "close", .cfun = &procClose },
    .{ .name = "in", .cfun = null },
    .{ .name = "out", .cfun = null },
    .{ .name = "err", .cfun = null },
    .{ .name = null, .cfun = null },
};

fn procGet(p: ?*anyopaque, key: types.Janet, out: *types.Janet) raise.Raising(c_int) {
    const proc: *JanetProc = @ptrCast(@alignCast(p.?));
    if (args_core.keyeq(key, "in") != 0) {
        out.* = if (proc.in) |x| wrap.fromAbstract(x) else wrap.fromNil();
        return 1;
    }
    if (args_core.keyeq(key, "out") != 0) {
        out.* = if (proc.out) |x| wrap.fromAbstract(x) else wrap.fromNil();
        return 1;
    }
    if (args_core.keyeq(key, "err") != 0) {
        out.* = if (proc.err) |x| wrap.fromAbstract(x) else wrap.fromNil();
        return 1;
    }
    if (!windows) {
        if (args_core.keyeq(key, "pid") != 0) {
            out.* = wrap.fromNumber(@floatFromInt(proc.handles.pid));
            return 1;
        }
    }
    if (proc.return_code != -1 and args_core.keyeq(key, "return-code") != 0) {
        out.* = wrapInteger(proc.return_code);
        return 1;
    }
    if (kind.checkType(key, constants.JANET_KEYWORD) == 0) return 0;
    return args_core.getmethod(wrap.toKeyword(key), @ptrCast(&proc_methods), out);
}

fn procNext(p: ?*anyopaque, key: types.Janet) raise.Raising(types.Janet) {
    _ = p;
    return args_core.nextmethod(@ptrCast(&proc_methods), key);
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

const handle_none: types.JanetHandle = if (windows) null else -1;

inline fn isHandle(x: types.JanetHandle) bool {
    return if (windows) x != null else x != -1;
}

fn closeHandle(handle: types.JanetHandle) void {
    if (windows) _ = CloseHandle(handle) else _ = closeDescriptor(handle);
}

/// `make_pipes`. The caller keeps `handle.*`; the returned end is the one the
/// child gets and is closed after the spawn. An error anywhere sets the flag
/// and answers "no handle", exactly as the C `goto error` did -- and, exactly
/// as there, the handles opened before the failure are not closed here.
fn makePipes(handle: *types.JanetHandle, reverse: bool, errflag: *c_int) types.JanetHandle {
    var handles: [2]types.JanetHandle = undefined;
    if (has_ev) {
        // Non-blocking pipes.
        if (ev_stream.makePipe(&handles, if (reverse) 2 else 1) != 0) {
            errflag.* = 1;
            return handle_none;
        }
        if (reverse) std.mem.swap(types.JanetHandle, &handles[0], &handles[1]);
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
        if (reverse) std.mem.swap(types.JanetHandle, &handles[0], &handles[1]);
        // Do not inherit the side of the pipe this process owns.
        if (SetHandleInformation(handles[0], h.HANDLE_FLAG_INHERIT, 0) == 0) {
            errflag.* = 1;
            return handle_none;
        }
    } else {
        if (makePipe(&handles) != 0) {
            errflag.* = 1;
            return handle_none;
        }
        if (reverse) std.mem.swap(types.JanetHandle, &handles[0], &handles[1]);
    }
    handle.* = handles[1];
    return handles[0];
}

extern fn janet_stream(handle: types.JanetHandle, flags: u32, methods: ?*const types.JanetMethod) callconv(.c) *types.JanetStream;
extern fn janet_makejfile(f: ?*anyopaque, flags: i32) callconv(.c) *types.JanetFile;
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
fn getJStream(argv: []types.Janet, n: i32, orig: *?*anyopaque) raise.Raising(types.JanetHandle) {
    if (has_ev) {
        if (args_core.checkabstract(argv[@intCast(n)], abstract_type.stored(&ev_stream.streamType))) |p| {
            const stream: *types.JanetStream = @ptrCast(@alignCast(p));
            if (stream.flags & stream_closed != 0) return raise.panic("stream is closed");
            orig.* = stream;
            return stream.handle;
        }
    }
    if (args_core.checkabstract(argv[@intCast(n)], abstract_type.stored(&io.fileType))) |p| {
        const f: *types.JanetFile = @ptrCast(@alignCast(p));
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
fn getStdioForHandle(handle: types.JanetHandle, orig: ?*anyopaque, iswrite: bool) ?*Stdio {
    if (has_ev) {
        const p = orig orelse
            return janet_stream(handle, if (iswrite) stream_writable else stream_readable, null);
        if (types.abstractHead(p).type == abstract_type.stored(&io.fileType)) {
            const jf: *types.JanetFile = @ptrCast(@alignCast(p));
            var flags: u32 = 0;
            if (jf.flags & file_write != 0) flags |= stream_writable;
            if (jf.flags & file_read != 0) flags |= stream_readable;
            // A file becoming a stream gets its own duplicate of the handle,
            // so that closing one does not close the other.
            if (windows) {
                const prochandle = GetCurrentProcess();
                var new_handle: types.JanetHandle = undefined;
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
/// which is `zig`'s note repeated here: the POSIX block drops a key
/// holding `=` or NUL and the Windows block does not, so `envKeyOk`
/// is called only where the C original called it.
fn buildEnv(argv: []types.Janet) raise.Raising(EnvBlock) {
    if (@as(i32, @intCast(argv.len)) <= 2) return null;
    const dict = try args_core.getDictionary(argv, 2);
    if (windows) {
        const temp = buffers.new(10);
        var i: i32 = 0;
        while (i < dict.cap) : (i += 1) {
            const kv = &dict.kvs.?[@intCast(i)];
            if (kind.checkType(kv.key, constants.JANET_STRING) == 0) continue;
            if (kind.checkType(kv.value, constants.JANET_STRING) == 0) continue;
            const keys = wrap.toString(kv.key);
            const vals = wrap.toString(kv.value);
            const klen = types.stringHead(keys).length;
            const vlen = types.stringHead(vals).length;
            try buffers.extra(temp, klen + vlen + 2);
            envEntryFill(keys, klen, vals, vlen, temp.*.data.? + @as(usize, @intCast(temp.*.count)));
            temp.*.count += klen + vlen + 2;
        }
        // A Windows environment block is double-NUL terminated.
        if (temp.*.count == 0) try buffers.pushU8(temp, 0);
        try buffers.pushU8(temp, 0);
        const ret: [*]u8 = @ptrCast(janet_smalloc(@intCast(temp.*.count)).?);
        @memcpy(ret[0..@intCast(temp.*.count)], temp.*.data.?[0..@intCast(temp.*.count)]);
        return ret;
    } else {
        const slots: usize = @intCast(dict.len + 1);
        const envp: [*]?[*:0]u8 = @ptrCast(@alignCast(janet_smalloc(@sizeOf(?*u8) * slots).?));
        var j: usize = 0;
        var i: i32 = 0;
        while (i < dict.cap) : (i += 1) {
            const kv = &dict.kvs.?[@intCast(i)];
            if (kind.checkType(kv.key, constants.JANET_STRING) == 0) continue;
            if (kind.checkType(kv.value, constants.JANET_STRING) == 0) continue;
            const keys = wrap.toString(kv.key);
            const vals = wrap.toString(kv.value);
            const klen = types.stringHead(keys).length;
            const vlen = types.stringHead(vals).length;
            // The key must hold no NUL and no `=`.
            if (envKeyOk(keys, klen) == 0) continue;
            const item: [*]u8 = @ptrCast(janet_smalloc(@as(usize, @intCast(klen)) + @as(usize, @intCast(vlen)) + 2).?);
            envEntryFill(keys, klen, vals, vlen, item);
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
fn execEscape(args: types.JanetView) raise.Raising(*types.JanetBuffer) {
    const b = buffers.new(0);
    var i: i32 = 0;
    while (i < args.len) : (i += 1) {
        const arg = try args_core.getCString(args_core.viewItems(args), i);
        if (i != 0) try buffers.pushU8(b, ' ');
        const needed = escapeArgument(@ptrCast(arg), null, 0);
        if (needed < 0) return raise.panic("command line string too long (max 8191 characters)");
        try buffers.extra(b, needed);
        _ = escapeArgument(@ptrCast(arg), b.*.data.? + @as(usize, @intCast(b.*.count)), needed);
        b.*.count += needed;
    }
    try buffers.pushU8(b, 0);
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
    envp: ?[*]?[*:0]u8,
) callconv(.c) c_int;
extern fn posix_spawnp(
    pid: *h.pid_t,
    file: [*:0]const u8,
    actions: ?*const h.posix_spawn_file_actions_t,
    attrp: ?*const anyopaque,
    argv: [*:null]const ?[*:0]const u8,
    envp: ?[*]?[*:0]u8,
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
    new_in: types.JanetHandle = handle_none,
    new_out: types.JanetHandle = handle_none,
    new_err: types.JanetHandle = handle_none,
    pipe_in: types.JanetHandle = handle_none,
    pipe_out: types.JanetHandle = handle_none,
    pipe_err: types.JanetHandle = handle_none,
    stderr_is_stdout: bool = false,
    errflag: c_int = 0,
    owner_flags: c_int = 0,
};

fn executeImpl(argv: []types.Janet, mode: ExecuteMode) raise.Raising(types.Janet) {
    try vm_lifecycle.sandboxAssert(constants.JANET_SANDBOX_SUBPROCESS);
    try args_core.arity(argv, 1, 3);

    const is_spawn = mode == .spawn;
    var flags: u64 = 0;
    if (@as(i32, @intCast(argv.len)) > 1) flags = try args_core.getFlags(argv, 1, "epxd");

    const use_environ = !flagAt(flags, 0);
    const envp = try buildEnv(argv);

    const exargs = try args_core.getIndexed(argv, 0);
    if (exargs.len < 1) return raise.panic("expected at least 1 command line argument");

    var r: Redirection = .{};
    r.owner_flags = if (is_spawn and flags & 0x8 != 0) proc_allow_zombie else 0;

    if (@as(i32, @intCast(argv.len)) > 2 and mode != .exec) {
        const tab = try args_core.getDictionary(argv, 2);
        const maybe_stdin = value.dictionaryGet(tab.kvs.?, tab.cap, value.fromBytes("in", .keyword));
        const maybe_stdout = value.dictionaryGet(tab.kvs.?, tab.cap, value.fromBytes("out", .keyword));
        const maybe_stderr = value.dictionaryGet(tab.kvs.?, tab.cap, value.fromBytes("err", .keyword));
        var slot = maybe_stdin;
        if (is_spawn and args_core.keyeq(maybe_stdin, "pipe") != 0) {
            r.new_in = makePipes(&r.pipe_in, true, &r.errflag);
            r.owner_flags |= proc_owns_stdin;
        } else if (kind.checkType(maybe_stdin, constants.JANET_NIL) == 0) {
            r.new_in = try getJStream((&slot)[0..1], 0, &r.orig_in);
        }
        slot = maybe_stdout;
        if (is_spawn and args_core.keyeq(maybe_stdout, "pipe") != 0) {
            r.new_out = makePipes(&r.pipe_out, false, &r.errflag);
            r.owner_flags |= proc_owns_stdout;
        } else if (kind.checkType(maybe_stdout, constants.JANET_NIL) == 0) {
            r.new_out = try getJStream((&slot)[0..1], 0, &r.orig_out);
        }
        slot = maybe_stderr;
        if (is_spawn and args_core.keyeq(maybe_stderr, "pipe") != 0) {
            r.new_err = makePipes(&r.pipe_err, false, &r.errflag);
            r.owner_flags |= proc_owns_stderr;
        } else if (args_core.keyeq(maybe_stderr, "out") != 0) {
            r.stderr_is_stdout = true;
        } else if (kind.checkType(maybe_stderr, constants.JANET_NIL) == 0) {
            r.new_err = try getJStream((&slot)[0..1], 0, &r.orig_err);
        }
    }

    // The working directory, for `os/execute` and `os/spawn` alike.
    var chdir_path: ?[*:0]const u8 = null;
    if (@as(i32, @intCast(argv.len)) > 2) {
        const tab = try args_core.getDictionary(argv, 2);
        const workdir = value.dictionaryGet(tab.kvs.?, tab.cap, value.fromBytes("cd", .keyword));
        if (kind.checkType(workdir, constants.JANET_STRING) != 0) {
            chdir_path = @ptrCast(wrap.toString(workdir));
            if (!spawn_chdir) {
                return pp_format.panicf(":cd argument not supported on this system - %s", .{chdir_path.?});
            }
        } else if (kind.checkType(workdir, constants.JANET_NIL) == 0) {
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
        return wrap.fromAbstract(proc);
    }
    return procWaitImpl(proc);
}

fn newProc() *JanetProc {
    const proc: *JanetProc = @ptrCast(@alignCast(abstracts.new(abstract_type.stored(&proc_type), @sizeOf(JanetProc))));
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
    argv: []types.Janet,
    exargs: types.JanetView,
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
        child_argv[@intCast(i)] = @ptrCast(try args_core.getCString(args_core.viewItems(exargs), i));
    }
    child_argv[@intCast(exargs.len)] = null;
    const cargv: [*:null]const ?[*:0]const u8 = @ptrCast(child_argv);

    if (use_environ) oa.lockEnviron();

    if (mode == .exec) {
        // Only a failure returns, and the message reads `errno` rather than
        // the result, so the result is deliberately discarded.
        if (!use_environ) oa.setEnviron(@ptrCast(envp));
        _ = exec(cargv[0].?, cargv, if (flagAt(flags, 1)) 1 else 0);
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
    const environment: ?[*]?[*:0]u8 = if (use_environ) oa.getEnviron() else @ptrCast(envp);
    const status = if (flagAt(flags, 1))
        posix_spawnp(&pid, child_argv[0].?, &actions, null, cargv, environment)
    else
        posix_spawn(&pid, child_argv[0].?, &actions, null, cargv, environment);

    _ = posix_spawn_file_actions_destroy(&actions);

    if (isHandle(r.pipe_in)) _ = closeDescriptor(r.pipe_in);
    if (isHandle(r.pipe_out)) _ = closeDescriptor(r.pipe_out);
    if (isHandle(r.pipe_err)) _ = closeDescriptor(r.pipe_err);

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
    argv: []types.Janet,
    exargs: types.JanetView,
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
    const path: [*:0]const u8 = @ptrCast(wrap.toString(exargs.items.?[0]));

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
        return pp_format.panicf("failed to create process: %s", .{@as([*]const u8, @ptrCast(&msgbuf))});
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
fn executeCfn(argv: []types.Janet) raise.Raising(types.Janet) {
    return executeImpl(argv, .execute);
}

fn spawnCfn(argv: []types.Janet) raise.Raising(types.Janet) {
    return executeImpl(argv, .spawn);
}

fn posixExec(argv: []types.Janet) raise.Raising(types.Janet) {
    if (windows) return raise.panic("not supported on Windows");
    return executeImpl(argv, .exec);
}

fn posixFork(argv: []types.Janet) raise.Raising(types.Janet) {
    try vm_lifecycle.sandboxAssert(constants.JANET_SANDBOX_SUBPROCESS);
    try args_core.fixarity(argv, 0);
    if (windows) return raise.panic("not supported on Windows");
    const result = forkProcess();
    if (result == -1) return raise.panic(@ptrCast(janet_strerror(errno())));
    if (result != 0) {
        const proc: *JanetProc = @ptrCast(@alignCast(abstracts.new(abstract_type.stored(&proc_type), @sizeOf(JanetProc))));
        proc.* = std.mem.zeroes(JanetProc);
        proc.handles.pid = @intCast(result);
        proc.flags = proc_allow_zombie;
        return wrap.fromAbstract(proc);
    }
    return wrap.fromNil();
}

fn posixChroot(argv: []types.Janet) raise.Raising(types.Janet) {
    try vm_lifecycle.sandboxAssert(constants.JANET_SANDBOX_CHROOT);
    try args_core.fixarity(argv, 1);
    if (windows) return raise.panic("not supported on Windows or Plan 9");
    const root = try args_core.getCString(argv, 0);
    if (changeRoot(@ptrCast(root)) == -1) {
        return raise.panic(@ptrCast(janet_strerror(errno())));
    }
    return wrap.fromNil();
}

/// `os_shell_subr`, which runs on a worker thread.
///
/// It frees the copied command and leaves `args.argp` pointing at the freed
/// block; the default threaded callback frees it a second time, which aborts.
/// That is the defect `FOUND.md` records, reproduced here rather than
/// repaired, and it is why `test/zig` exercises only the
/// no-argument form.
fn shellSubroutine(args: types.JanetEVGenericMessage) callconv(.c) types.JanetEVGenericMessage {
    var out = args;
    const stat = shell(@ptrCast(@alignCast(args.argp)));
    janet_free(args.argp);
    out.tag = if (args.argi != 0) constants.JANET_EV_TCTAG_INTEGER else constants.JANET_EV_TCTAG_BOOLEAN;
    out.argi = stat;
    return out;
}

fn shellCfn(argv: []types.Janet) raise.Raising(types.Janet) {
    try vm_lifecycle.sandboxAssert(constants.JANET_SANDBOX_SUBPROCESS);
    try args_core.arity(argv, 0, 1);
    const cmd: ?[*:0]const u8 = if (@as(i32, @intCast(argv.len)) != 0) @ptrCast(try args_core.getCString(argv, 0)) else null;
    if (has_ev) {
        var cmd_copy: ?*anyopaque = null;
        if (cmd) |src| {
            const cmdlen = std.mem.len(src);
            const dest: [*]u8 = @ptrCast(janet_malloc(cmdlen + 1).?);
            @memcpy(dest[0..cmdlen], src[0..cmdlen]);
            dest[cmdlen] = 0;
            cmd_copy = dest;
        }
        try raise.crossing(ev_loop.evThreadedAwait(&shellSubroutine, 0, @as(i32, @intCast(argv.len)), cmd_copy));
        unreachable;
    } else {
        const stat = shell(cmd);
        return if (@as(i32, @intCast(argv.len)) != 0) wrapInteger(stat) else wrap.fromBoolean(stat);
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
        var msg: types.JanetEVGenericMessage = std.mem.zeroes(types.JanetEVGenericMessage);
        msg.tag = sig;
        ev_loop.evPostEvent(c.vm(), &signalCallback, msg);
    }

    fn interrupting(sig: c_int) callconv(.c) void {
        var msg: types.JanetEVGenericMessage = std.mem.zeroes(types.JanetEVGenericMessage);
        msg.tag = sig;
        msg.argi = 1;
        vm_state.interpreterInterrupt(c.vm());
        ev_loop.evPostEvent(c.vm(), &signalCallback, msg);
    }
};

fn signalCallback(msg: types.JanetEVGenericMessage) callconv(.c) void {
    const sig = msg.tag;
    if (msg.argi != 0) vm_state.interpreterInterruptHandled(null);
    const handlerv = tables.get(&c.vm().signal_handlers, wrapInteger(sig));
    if (kind.checkType(handlerv, constants.JANET_FUNCTION) == 0) {
        // Nothing here wants it: unblock this signal and re-raise, so that
        // another thread or the default disposition can take it.
        var set: h.sigset_t = undefined;
        _ = sigemptyset(&set);
        _ = sigaddset(&set, sig);
        _ = sigprocmask(h.SIG_BLOCK, &set, null);
        _ = raiseSignal(sig);
        return;
    }
    const handler = wrap.toFunction(handlerv);
    const fiber = fibers.new(handler, 64, 0, null) orelse return;
    ev_loop.scheduleSoon(fiber, wrap.fromNil(), constants.JANET_SIGNAL_OK);
}

fn sigactionCfn(argv: []types.Janet) raise.Raising(types.Janet) {
    try vm_lifecycle.sandboxAssert(constants.JANET_SANDBOX_SIGNAL);
    try args_core.arity(argv, 1, 3);
    if (windows) return raise.panic("unsupported on this platform");

    const sig = try getSignalKw(argv, 0);
    const handler: ?*types.JanetFunction =
        if (argv.len > 1 and kind.checkType(argv[1], constants.JANET_NIL) == 0)
            try args_core.getFunction(argv, 1)
        else
            null;
    const can_interrupt = try args_core.optBoolean(argv, 2, 0) != 0;
    const oldhandler = tables.get(&c.vm().signal_handlers, wrapInteger(sig));
    if (kind.checkType(oldhandler, constants.JANET_NIL) == 0) _ = gc_alloc.gcunroot(oldhandler);
    if (handler) |f| {
        // A handler is entered with no arguments, so one that cannot accept
        // zero can never run. `janet_fiber` answers null for it and the C
        // scheduled that null; refusing here names the mistake at the line
        // that made it. `port/FOUND.md` has the original behaviour.
        if (f.def.?.min_arity > 0) {
            return pp_format.panicf(
                "signal handler must accept zero arguments, got one of arity %d",
                .{f.def.?.min_arity},
            );
        }
        const handlerv = wrap.fromFunction(f);
        gc_alloc.gcroot(handlerv);
        tables.put(&c.vm().signal_handlers, wrapInteger(sig), handlerv);
    } else {
        tables.put(&c.vm().signal_handlers, wrapInteger(sig), wrap.fromNil());
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
        if (constants.JANET_VM_HAS_INTERRUPT == 0) return raise.panic("interpreter interrupt not enabled");
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
    return wrap.fromNil();
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

fn pipeCfn(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.arity(argv, 0, 1);
    var fds: [2]types.JanetHandle = undefined;
    var flags: c_int = 0;
    if (@as(i32, @intCast(argv.len)) > 0 and kind.checkType(argv[0], constants.JANET_NIL) == 0) {
        flags = @intCast(try args_core.getFlags(argv, 0, "WR"));
    }
    if (ev_stream.makePipe(&fds, flags) != 0) return raise.panicv(ev_stream.evLasterr());
    const reader = janet_stream(fds[0], if (flags & 2 != 0) 0 else stream_readable, null);
    const writer = janet_stream(fds[1], if (flags & 1 != 0) 0 else stream_writable, null);
    var tup = [2]types.Janet{ wrap.fromAbstract(reader), wrap.fromAbstract(writer) };
    return wrap.fromTuple(tuples.newFrom(&tup, 2));
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
            corefn.reg("os/shell", &shellCfn, @src(), "(os/shell str)", "Pass a command string str directly to the system shell."),
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

// ---------------------------------------------------------------------------
// The portable rules and the host calls -- what `os_process.zig` was.
// ---------------------------------------------------------------------------

const pid_t = if (windows) c_int else std.c.pid_t;

/// What `wait` reports. These were the `JANET_OS_WAIT_*` codes in
/// `src/core/os.c` and are now the whole of that vocabulary: `os_procs.zig`
/// restates the first three for the policy it applies to them, and
/// `test/os_process.zig` names all four rather than restating the numbers.
pub const wait_exited: i32 = 0;
pub const wait_stopped: i32 = 1;
pub const wait_signaled: i32 = 2;
pub const wait_unknown: i32 = 3;

extern fn getpid() callconv(.c) pid_t;
extern fn _getpid() callconv(.c) c_int;
extern fn system(command: ?[*:0]const u8) callconv(.c) c_int;

extern fn waitpid(pid: pid_t, status: *c_int, options: c_int) callconv(.c) pid_t;
extern fn kill(pid: pid_t, sig: c_int) callconv(.c) c_int;
extern fn fork() callconv(.c) pid_t;
extern fn chroot(path: [*:0]const u8) callconv(.c) c_int;
extern fn pipe(fds: *[2]c_int) callconv(.c) c_int;
extern fn close(fd: c_int) callconv(.c) c_int;
extern fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) callconv(.c) c_int;
extern fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) callconv(.c) c_int;

// The fourteen kernels below are reached by import rather than by symbol.
//
// Each was `@export`ed under a `janet_os_*` name and declared back as an
// `extern fn` by `os_procs.zig`, which is the only caller there has ever
// been. That shape is what `os.c` needed when these were the first Zig inside
// it; both ends have been Zig since Phase 10 Part 18 and nothing said so,
// because an `extern fn` declaration compiles forever and a symbol that
// resolves is silent. Phase 11 Part 16 named the class; Part 20 spent this
// instance of it.

/// The signal keywords `os/proc-kill` and `os/sigaction` accept, in the order
/// the C table listed them.
///
/// Only the names live here. Which of them a platform actually defines, and
/// what number each carries, are host facts, so C maps a position to a signal
/// and reports the ones its headers left out as undefined — exactly as the
/// `#ifdef`-gated table did by omitting them.
///
/// `vtlarm` is a misspelling of `vtalrm` that this list preserves; it is
/// recorded in `FOUND.md` as a defect and reproduced rather than corrected.
const signal_names = [_][:0]const u8{
    "kill",
    "int",
    "abrt",
    "fpe",
    "ill",
    "segv",
    "term",
    "alrm",
    "hup",
    "pipe",
    "quit",
    "usr1",
    "usr2",
    "chld",
    "cont",
    "stop",
    "tstp",
    "ttin",
    "ttou",
    "bus",
    "poll",
    "prof",
    "sys",
    "trap",
    "urg",
    "vtlarm",
    "xcpu",
    "xfsz",
};

/// Find a signal by keyword, returning its position in `signal_names` or -1.
///
/// The comparison reproduces `janet_cstrcmp`, which the C implementation used
/// here, including its treatment of a key whose own bytes end in NUL.
pub fn signalIndex(key: [*]const u8, len: i32) i32 {
    if (len < 0) return -1;
    for (signal_names, 0..) |name, index| {
        if (cstrequal(key, @intCast(len), name)) return @intCast(index);
    }
    return -1;
}

fn cstrequal(key: [*]const u8, len: usize, other: [:0]const u8) bool {
    var index: usize = 0;
    while (index < len) : (index += 1) {
        const k = other.ptr[index];
        if (key[index] != k) return false;
        if (k == 0) break;
    }
    return other.ptr[index] == 0;
}

/// Accumulates the escaped form of one argument, measuring when it has nowhere
/// to write and filling when it does.
const Escaped = struct {
    dest: ?[*]u8,
    cap: usize,
    len: usize = 0,

    fn byte(self: *Escaped, val: u8) void {
        if (self.dest) |d| {
            if (self.len < self.cap) d[self.len] = val;
        }
        self.len +|= 1;
    }

    fn repeat(self: *Escaped, val: u8, count: usize) void {
        var remaining = count;
        while (remaining > 0) : (remaining -= 1) self.byte(val);
    }
};

/// Escape one argument for a Windows command line, writing at most `cap` bytes
/// and returning the length the whole escaped form needs.
///
/// A process started by `CreateProcess` receives a single command line and
/// splits it itself; the rule reproduced here is the one `CommandLineToArgvW`
/// applies, which is why the caller must quote and double the backslashes that
/// precede a quotation mark. That rule belongs to the Windows runtime rather
/// than to the host running the build, so this is compiled and tested
/// everywhere even though only the Windows spawn calls it.
///
/// Returns -1 if the escaped form would not fit in a Janet string, which the C
/// implementation reached only by overflowing its own length arithmetic; the
/// command line limit C already enforces makes it unreachable in practice.
pub fn escapeArgument(arg: [*:0]const u8, dest: ?[*]u8, cap: i32) i32 {
    var out: Escaped = .{ .dest = dest, .cap = if (cap > 0) @intCast(cap) else 0 };

    // Quoting is needed only when the argument holds a byte the splitter would
    // otherwise treat as a separator or as a quotation mark.
    var scan: usize = 0;
    while (arg[scan] != 0) : (scan += 1) {
        switch (arg[scan]) {
            ' ', '\t', 0x0b, '\n', '"' => break,
            else => {},
        }
    }

    if (arg[scan] == 0) {
        var index: usize = 0;
        while (arg[index] != 0) : (index += 1) out.byte(arg[index]);
    } else {
        out.byte('"');
        var index: usize = 0;
        while (true) {
            var backslashes: usize = 0;
            while (arg[index] == '\\') : (index += 1) backslashes += 1;
            if (arg[index] == '"') {
                // A quotation mark ends a run of backslashes, so each of them
                // and the mark itself must be escaped.
                out.repeat('\\', 2 *| backslashes +| 1);
                out.byte('"');
            } else if (arg[index] != 0) {
                // Backslashes not followed by a quotation mark stand for
                // themselves.
                out.repeat('\\', backslashes);
                out.byte(arg[index]);
            } else {
                // The closing quotation mark that follows would otherwise
                // consume the final run.
                out.repeat('\\', 2 *| backslashes);
                break;
            }
            index += 1;
        }
        out.byte('"');
    }

    if (out.len > std.math.maxInt(i32)) return -1;
    return @intCast(out.len);
}

/// Report whether an environment key may be passed to a child.
///
/// A key containing `=` would be read back as a shorter name with a longer
/// value, and one containing NUL would end the entry early, so C drops both
/// rather than building an entry that means something else.
pub fn envKeyOk(key: [*]const u8, len: i32) i32 {
    if (len < 0) return 0;
    var index: usize = 0;
    while (index < @as(usize, @intCast(len))) : (index += 1) {
        if (key[index] == 0 or key[index] == '=') return 0;
    }
    return 1;
}

/// Write one environment entry as `key=value` followed by a terminator. The
/// caller sizes the destination as `klen + vlen + 2`.
pub fn envEntryFill(
    key: [*]const u8,
    klen: i32,
    val: [*]const u8,
    vlen: i32,
    dest: [*]u8,
) void {
    const k: usize = if (klen > 0) @intCast(klen) else 0;
    const v: usize = if (vlen > 0) @intCast(vlen) else 0;
    @memcpy(dest[0..k], key[0..k]);
    dest[k] = '=';
    @memcpy(dest[k + 1 ..][0..v], val[0..v]);
    dest[k + 1 + v] = 0;
}

pub fn processId() i64 {
    if (windows) return _getpid();
    return getpid();
}

pub fn shell(command: ?[*:0]const u8) i32 {
    return system(command);
}

/// Wait for a process and classify how it ended.
///
/// Reports the outcome and the number that goes with it — an exit code, a stop
/// signal, or a terminating signal — leaving C to add the offset it applies to
/// the two signal cases and to panic on the fourth outcome.
///
/// A failed `waitpid` is not reported. The C implementation ignored its result
/// and decoded the untouched status word, which classifies as a zero exit; that
/// is preserved here.
pub fn wait(pid: i64, val: *i32) i32 {
    var status: c_int = 0;
    while (true) {
        const result = waitpid(@intCast(pid), &status, 0);
        if (result != -1) break;
        if (std.c._errno().* != @intFromEnum(std.c.E.INTR)) break;
    }

    const bits: u32 = @bitCast(status);
    if (std.c.W.IFEXITED(bits)) {
        val.* = @intCast(std.c.W.EXITSTATUS(bits));
        return wait_exited;
    }
    if (std.c.W.IFSTOPPED(bits)) {
        val.* = @intCast(@intFromEnum(std.c.W.STOPSIG(bits)));
        return wait_stopped;
    }
    if (std.c.W.IFSIGNALED(bits)) {
        val.* = @intCast(@intFromEnum(std.c.W.TERMSIG(bits)));
        return wait_signaled;
    }
    val.* = status;
    return wait_unknown;
}

/// Collect a process the collector is discarding. Unlike `wait` this does not
/// retry and does not report the status, because the C implementation it
/// replaces did neither.
pub fn reap(pid: i64) void {
    var status: c_int = 0;
    _ = waitpid(@intCast(pid), &status, 0);
}

pub fn sendSignal(pid: i64, sig: i32) i32 {
    return kill(@intCast(pid), sig);
}

pub fn makePipe(fds: *[2]c_int) i32 {
    return pipe(fds);
}

pub fn closeDescriptor(fd: c_int) i32 {
    return close(fd);
}

pub fn forkProcess() i64 {
    while (true) {
        const result = fork();
        if (result != -1) return result;
        if (std.c._errno().* != @intFromEnum(std.c.E.INTR)) return result;
    }
}

/// Replace the current process. Returns only on failure, with `errno` set.
pub fn exec(
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    search_path: i32,
) i32 {
    while (true) {
        const status = if (search_path != 0) execvp(path, argv) else execv(path, argv);
        if (status != -1) return status;
        if (std.c._errno().* != @intFromEnum(std.c.E.INTR)) return status;
    }
}

pub fn changeRoot(path: [*:0]const u8) i32 {
    while (true) {
        const status = chroot(path);
        if (status != -1) return status;
        if (std.c._errno().* != @intFromEnum(std.c.E.INTR)) return status;
    }
}

fn escape(arg: [:0]const u8) ![]u8 {
    const needed = escapeArgument(arg.ptr, null, 0);
    const buffer = try std.testing.allocator.alloc(u8, @intCast(needed));
    try std.testing.expectEqual(needed, escapeArgument(arg.ptr, buffer.ptr, needed));
    return buffer;
}

fn expectEscape(arg: [:0]const u8, expected: []const u8) !void {
    const actual = try escape(arg);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "an argument without separators is passed through" {
    try expectEscape("simple", "simple");
    try expectEscape("", "");
    try expectEscape("a\\b\\c", "a\\b\\c");
    try expectEscape("trailing\\\\", "trailing\\\\");
}

test "an argument with a separator is quoted" {
    try expectEscape("two words", "\"two words\"");
    try expectEscape("tab\there", "\"tab\there\"");
    try expectEscape("line\nbreak", "\"line\nbreak\"");
    try expectEscape("vertical\x0btab", "\"vertical\x0btab\"");
}

test "backslashes double only where they precede a quotation mark" {
    // The quotation mark forces quoting, and the two backslashes before it are
    // doubled so the splitter sees them as literal.
    try expectEscape("a\\\\\"b", "\"a\\\\\\\\\\\"b\"");
    // The same backslashes elsewhere in a quoted argument stay as they are.
    try expectEscape("a\\\\b c", "\"a\\\\b c\"");
    // A run at the end meets the closing mark, so it doubles too.
    try expectEscape("end \\\\", "\"end \\\\\\\\\"");
    try expectEscape("\"", "\"\\\"\"");
}

test "signal keywords match whole names only" {
    try std.testing.expectEqual(@as(i32, 0), signalIndex("kill", 4));
    try std.testing.expectEqual(@as(i32, 1), signalIndex("int", 3));
    try std.testing.expectEqual(@as(i32, 27), signalIndex("xfsz", 4));
    try std.testing.expectEqual(@as(i32, -1), signalIndex("kil", 3));
    try std.testing.expectEqual(@as(i32, -1), signalIndex("killer", 6));
    try std.testing.expectEqual(@as(i32, -1), signalIndex("", 0));
    // The misspelling the C table carried is the name that resolves.
    try std.testing.expectEqual(@as(i32, 25), signalIndex("vtlarm", 6));
    try std.testing.expectEqual(@as(i32, -1), signalIndex("vtalrm", 6));
}

test "environment keys with a separator or a terminator are refused" {
    try std.testing.expectEqual(@as(i32, 1), envKeyOk("PATH", 4));
    try std.testing.expectEqual(@as(i32, 1), envKeyOk("", 0));
    try std.testing.expectEqual(@as(i32, 0), envKeyOk("A=B", 3));
    try std.testing.expectEqual(@as(i32, 0), envKeyOk("A\x00B", 3));
    // Only the reported length is examined, so a separator past it is unseen.
    try std.testing.expectEqual(@as(i32, 1), envKeyOk("A=B", 1));
}

test "an environment entry is key, separator, value, terminator" {
    var buffer: [16]u8 = undefined;
    envEntryFill("K", 1, "V", 1, &buffer);
    try std.testing.expectEqualStrings("K=V", buffer[0..3]);
    try std.testing.expectEqual(@as(u8, 0), buffer[3]);

    envEntryFill("K", 1, "", 0, &buffer);
    try std.testing.expectEqualStrings("K=", buffer[0..2]);
    try std.testing.expectEqual(@as(u8, 0), buffer[2]);

    // A value may hold anything, including the separator.
    envEntryFill("K", 1, "a=b", 3, &buffer);
    try std.testing.expectEqualStrings("K=a=b", buffer[0..5]);
    try std.testing.expectEqual(@as(u8, 0), buffer[5]);
}
