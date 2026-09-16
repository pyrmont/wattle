//! The `os/` process surface: launching, waiting on, signalling and piping to
//! a child.
//!
//! `spawn.zig`, `signals.zig` and `pipe.zig` beside it would each need a name,
//! and none earns one. A piece splits out when it has a name Janet already
//! publishes, a type, a cfunction family or a module, or when it exists
//! because the platform differs. This file registers twelve cfunctions and not
//! one of those three names is among them: there is no `os/spawn` family
//! (there is `os/spawn`, `os/execute` and `os/shell`, which share no name),
//! `os/sigaction` is a single cfunction, and so is `os/pipe`. A leaf called
//! `signals` would claim something the tree cannot point at.
//!
//! `Proc` is the one thing here Janet publishes as a type, and it stays in the
//! bucket because splitting it out would invert the file: the type's four
//! methods are a fraction of what creates and drives it, so the leaf would be
//! the core and the bucket the periphery. That is the same ruling as
//! `os/fs/paths.zig`, which also does not exist. The cost is a large file, and
//! the compensation is that its name claims exactly what is in it. A name that
//! claims nothing cannot claim wrongly.
//!
//! `shell` appears twice and the two are not duplicates: the host call, and
//! the cfunction that checks arguments and calls it. The cfunction is
//! `cfunShell`, which is this file's own convention beside `cfunExecute`,
//! `cfunSpawn`, `cfunSigaction` and `cfunPipe`.
//!
//! The kernels at the foot are reached by import rather than by symbol, and
//! the host calls below them are the ones whose signatures name `h.pid_t`,
//! which this file aliases, so they stay with the alias rather than moving to
//! `cabi.zig`.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");
const builtin = @import("builtin");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const abstract_type = @import("../../api/abstract_type.zig");
const abstracts = @import("../value/abstracts.zig");
const args_core = @import("../args.zig");
const buffers = @import("../value/buffers.zig");
const c = @import("cabi");
const config = @import("config");
const constants = @import("constants");
const corefn = @import("../corefn.zig");
const ev_loop = @import("../ev.zig");
const ev_stream = @import("../ev/stream.zig");
const fibers = @import("../value/fibers.zig");
const functions = @import("../value/functions.zig");
const gc_alloc = @import("../gc.zig");
const gc_mark = @import("../gc/mark.zig");
const host = @import("host");
const io = @import("../io.zig");
const method_type = @import("../method_type.zig");
const oa = @import("abi.zig");
const pp_format = @import("../pp/format.zig");
const raise = @import("../../api/raise.zig");
const repr = @import("repr");
const stdio = @import("../stdio.zig");
const strings = @import("../value/strings.zig");
const tables = @import("../value/tables.zig");
const tuples = @import("../value/tuples.zig");
const utils = @import("../utils.zig");
const value = @import("../value.zig");
const vm_lifecycle = @import("../vm/lifecycle.zig");
const vm_state = @import("../vm/state.zig");
const wrap = @import("../value/helpers/wrap.zig");

/// `os/abi.zig`'s translation, which is where `pid_t`, the spawn file actions
/// and the signal types come from.
const h = oa.h;

// ==========================================================================
// Constants
// ==========================================================================

/// The three `io.File` flags this file reads, which is all it needs of that
/// type's flag word.
const file_closed: i32 = 32;
const file_read: i32 = 2;
const file_write: i32 = 1;

/// The handle value that is no handle, which a redirection slot starts at.
const handle_none: host.Handle = if (windows) null else -1;

/// Whether this build has the event loop, which decides whether a child's
/// stdio is a stream or a file, and whether the wait is threaded.
pub const has_ev = config.ev;

/// Whether this build registers the spawn family at all.
pub const no_spawn = !config.spawn;

/// The `Proc` flag word: what has been closed or waited on, which of the three
/// stdio handles this process owns, and the two flags `os/spawn` takes as
/// options.
const proc_allow_zombie: c_int = 128;
const proc_closed: c_int = 1;
const proc_error_nonzero: c_int = 8;
const proc_owns_stderr: c_int = 64;
const proc_owns_stdin: c_int = 16;
const proc_owns_stdout: c_int = 32;
const proc_waited: c_int = 2;
const proc_waiting: c_int = 4;

/// The methods reached through `(:wait p)` and its siblings.
///
/// Three real methods and three dud entries. The duds are what `nextmethod`
/// walks, so `(keys p)` reports `:in`, `:out` and `:err` as well; the table's
/// order is observable for the same reason, and it is preserved.
const proc_methods = [_]method_type.Method{
    .{ .name = "wait", .cfun = &cfunProcWait },
    .{ .name = "kill", .cfun = &cfunProcKill },
    .{ .name = "close", .cfun = &cfunProcClose },
    .{ .name = "in", .cfun = null },
    .{ .name = "out", .cfun = null },
    .{ .name = "err", .cfun = null },
    .{ .name = null, .cfun = null },
};

/// The abstract type `os/spawn` returns.
const proc_type = abstract_type.define(Proc, .{
    .name = "core/process",
    .gc = &procGc,
    .gcmark = &procMark,
    .get = &procGet,
    .next = &procNext,
});

/// The signal keywords `os/proc-kill` and `os/sigaction` accept, in the order
/// the C table listed them.
///
/// Only the names live here. Which of them a platform actually defines, and
/// what number goes with each, are host facts, so a position maps to a signal
/// and the ones a platform's headers left out are reported as undefined,
/// exactly as the `#ifdef`-gated table did by omitting them.
///
/// Each name is its signal's own, lower-cased with the `SIG` dropped, which is
/// the rule every one of them follows: `vtalrm` for `SIGVTALRM`, and no alias
/// for the `vtlarm` this list once had.
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
    "vtalrm",
    "xcpu",
    "xfsz",
};

/// The header names, reached by position through `signalIndex` so that the two
/// halves cannot disagree about the order, and the number each position has on
/// this platform, or -1 where the headers define none.
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

/// Whether `posix_spawn_file_actions_addchdir` exists. `os/abi.h` enumerates
/// the systems, because the extension follows no standard and the enumeration
/// belongs beside the other predefine tests.
const spawn_chdir = oa.spawn_chdir;

/// The three `ev_stream.Stream` flags this file reads.
const stream_closed: u32 = 0x1;
const stream_readable: u32 = 0x200;
const stream_writable: u32 = 0x400;

/// What `wait` reports, and the whole of that vocabulary. The cfunctions turn
/// the first three into the number a Janet program sees and raise on the
/// fourth; `test/os_process.zig` names all four rather than restating the
/// numbers.
pub const wait_exited: i32 = 0;
pub const wait_signaled: i32 = 2;
pub const wait_stopped: i32 = 1;
pub const wait_unknown: i32 = 3;

/// Whether this target takes the `CreateProcess` arm rather than the
/// `posix_spawn` one.
const windows = builtin.os.tag == .windows;

// ==========================================================================
// Aliased types
// ==========================================================================

/// A double-NUL-terminated byte block on Windows, a NULL-terminated vector of
/// `key=value` strings on POSIX. Both are `gc.smalloc`'d and freed by
/// `cleanupEnv`.
const EnvBlock = if (windows) ?[*]u8 else ?[*:null]?[*:0]u8;

/// The stdio a `Proc` has is an `ev_stream.Stream` under the event loop and an
/// `io.File` without it. Both are abstracts, so the field is a pointer either
/// way and the mark callback needs no test.
const Stdio = if (has_ev) ev_stream.Stream else io.File;

// ==========================================================================
// Types
// ==========================================================================

/// Accumulates the escaped form of one argument, measuring where it has
/// nowhere to write and filling where it does.
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

/// Which of the three ways a child is started: wait for it, keep it, or
/// replace this process with it.
const ExecuteMode = enum { execute, spawn, exec };

/// A `core/process`: the flag word, the host's handles for the child, its
/// return code, and the three stdio abstracts this process kept.
const Proc = struct {
    flags: c_int,
    handles: if (windows) struct { p: host.Handle, t: host.Handle } else struct { pid: h.pid_t },
    return_code: c_int,
    in: ?*Stdio,
    out: ?*Stdio,
    err: ?*Stdio,

    inline fn pid(self: *const Proc) i64 {
        return @intCast(self.handles.pid);
    }
};

/// Where the child's three descriptors come from, and which of them this
/// process still owns after the spawn.
const Redirection = struct {
    orig_in: ?*anyopaque = null,
    orig_out: ?*anyopaque = null,
    orig_err: ?*anyopaque = null,
    new_in: host.Handle = handle_none,
    new_out: host.Handle = handle_none,
    new_err: host.Handle = handle_none,
    pipe_in: host.Handle = handle_none,
    pipe_out: host.Handle = handle_none,
    pipe_err: host.Handle = handle_none,
    stderr_is_stdout: bool = false,
    errflag: c_int = 0,
    owner_flags: c_int = 0,
};

/// The handler Janet installs. It runs in signal context, so it may touch
/// nothing but `ev.evPostEvent`; everything else happens on the main thread in
/// `signalCallback`.
const Trampolines = struct {
    fn plain(sig: c_int) callconv(.c) void {
        var msg: ev_loop.GenericMessage = std.mem.zeroes(ev_loop.GenericMessage);
        msg.tag = sig;
        ev_loop.evPostEvent(vm_state.current(), &signalCallback, msg);
    }

    fn interrupting(sig: c_int) callconv(.c) void {
        var msg: ev_loop.GenericMessage = std.mem.zeroes(ev_loop.GenericMessage);
        msg.tag = sig;
        msg.argi = 1;
        vm_state.interpreterInterrupt(vm_state.current());
        ev_loop.evPostEvent(vm_state.current(), &signalCallback, msg);
    }
};

/// The threaded wait, and the callback that runs on the main thread when it
/// finishes. Referenced only under the event loop, which is what keeps them
/// out of a `-Dev=false` build: Zig does not analyse an unreferenced function.
const Waiter = struct {
    fn subroutine(args: ev_loop.GenericMessage) callconv(.c) ev_loop.GenericMessage {
        var out = args;
        const proc: *Proc = @ptrCast(@alignCast(args.argp.?));
        if (windows) {
            _ = c.WaitForSingleObject(proc.handles.p, 0xFFFF_FFFF);
            var exitcode: u32 = 0;
            _ = c.GetExitCodeProcess(proc.handles.p, &exitcode);
            out.tag = @bitCast(exitcode);
        } else {
            // This runs off the main thread, where a raise has nowhere to go,
            // so `procGetStatus`'s fourth outcome ends the process from the
            // worker. That is what a program sees, and `raise.total` is what
            // says the report has nowhere further to go.
            out.tag = raise.total(procGetStatus(proc), "os/proc-wait's worker thread");
        }
        return out;
    }

    fn callback(args: ev_loop.GenericMessage) raise.Error!void {
        const proc: *Proc = @ptrCast(@alignCast(args.argp orelse return));
        const status = args.tag;
        proc.return_code = status;
        proc.flags |= proc_waited;
        proc.flags &= ~proc_waiting;
        _ = gc_alloc.gcunroot(wrap.fromAbstract(proc));
        _ = gc_alloc.gcunroot(wrap.fromFiber(args.fiber.?));
        const sched_id: u32 = @bitCast(args.argi);
        if (fibers.canResume(args.fiber.?) and args.fiber.?.sched_id == sched_id) {
            if (status != 0 and proc.flags & proc_error_nonzero != 0) {
                const s = try pp_format.formatc("command failed with non-zero exit code %d", .{status});
                try ev_loop.cancel(args.fiber.?, wrap.fromString(s));
            } else {
                ev_loop.schedule(args.fiber.?, wrap.fromInteger(status));
            }
        }
    }

    // An `ev.ThreadedCallback`, run by the event loop on the thread that
    // receives the event. Nothing above it can take an error.
    fn callbackAbi(args: ev_loop.GenericMessage) callconv(.c) void {
        raise.total(callback(args), "os/proc's completion callback");
    }
};

// ==========================================================================
// Public functions
// ==========================================================================

/// `chroot`.
pub fn changeRoot(path: [*:0]const u8) i32 {
    return c.retryIntr(c.chroot, .{path});
}

/// `close` on a descriptor.
pub fn closeDescriptor(fd: c_int) i32 {
    return c.close(fd);
}

/// The twelve registrations, which `os.zig` installs after the filesystem
/// family.
pub fn entries() []const corefn.Entry {
    const list = comptime blk: {
        var acc: []const corefn.Entry = &.{};
        acc = acc ++ [_]corefn.Entry{
            corefn.reg("os/execute", &cfunExecute, @src(), "(os/execute args &opt flags env)", "Execute a program on the system and return the exit code. `args` is an array/tuple " ++
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
            corefn.reg("os/spawn", &cfunSpawn, @src(), "(os/spawn args &opt flags env)", "Execute a program on the system and return a core/process value representing the " ++
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
            corefn.reg("os/shell", &cfunShell, @src(), "(os/shell str)", "Pass a command string str directly to the system shell."),
            corefn.reg("os/posix-fork", &cfunPosixFork, @src(), "(os/posix-fork)", "Make a `fork` system call and create a new process. Return nil if in the new process, otherwise a core/process object (as returned by os/spawn). " ++
                "Not supported on all systems (POSIX and Plan 9 only)."),
            corefn.reg("os/posix-exec", &cfunPosixExec, @src(), "(os/posix-exec args &opt flags env)", "Use the execvpe or execve system calls to replace the current process with an interface similar to os/execute. " ++
                "However, instead of creating a subprocess, the current process is replaced. Is not supported on Windows, and " ++
                "does not allow redirection of stdio."),
            corefn.reg("os/posix-chroot", &cfunPosixChroot, @src(), "(os/posix-chroot dirname)", "Call `chroot` to change the root directory to `dirname`. " ++
                "Not supported on all systems (POSIX only)."),
            // Process management is not sandboxed: a build that cannot create
            // processes can still be handed one by an embedder's cfunction.
            corefn.reg("os/proc-wait", &cfunProcWait, @src(), "(os/proc-wait proc)", "Suspend the current fiber until the subprocess `proc` completes. Once `proc` " ++
                "completes, return the exit code of `proc`. If called more than once on the same " ++
                "core/process value, will raise an error. When creating subprocesses using " ++
                "`os/spawn`, this function should be called on the returned value to avoid zombie " ++
                "processes."),
            corefn.reg("os/proc-kill", &cfunProcKill, @src(), "(os/proc-kill proc &opt wait signal)", "Kill the subprocess `proc` by sending SIGKILL to it on POSIX systems, or by closing " ++
                "the process handle on Windows. If `proc` has already completed, raise an error. If " ++
                "`wait` is truthy, will wait for `proc` to complete and return the exit code (this " ++
                "will raise an error if `proc` is being waited for). Otherwise, return `proc`. If " ++
                "`signal` is provided, send it instead of SIGKILL. Signal keywords are named after " ++
                "their C counterparts but in lowercase with the leading SIG stripped. `signal` is " ++
                "ignored on Windows."),
            corefn.reg("os/proc-close", &cfunProcClose, @src(), "(os/proc-close proc)", "Close pipes created for subprocess `proc` by `os/spawn` if they have not been " ++
                "closed. Then, if `proc` is not being waited for, wait. If this function waits, when " ++
                "`proc` completes, return the exit code of `proc`. Otherwise, return nil."),
            corefn.reg("os/getpid", &cfunProcGetpid, @src(), "(os/getpid)", "Get the process ID of the current process."),
        };
        if (has_ev) acc = acc ++ [_]corefn.Entry{
            corefn.reg("os/sigaction", &cfunSigaction, @src(), "(os/sigaction which &opt handler interrupt-interpreter)", "Add a signal handler for a given action. Use nil for the `handler` argument to remove a signal handler. " ++
                "All signal handlers are the same as supported by `os/proc-kill`."),
        };
        break :blk acc[0..acc.len].*;
    };
    return &list;
}

/// Writes one environment entry as `key=value` followed by a terminator. The
/// caller sizes the destination as `klen + vlen + 2`.
pub fn envEntryFill(
    key: [*]const u8,
    klen: usize,
    val: [*]const u8,
    vlen: usize,
    dest: [*]u8,
) void {
    const k = klen;
    const v = vlen;
    @memcpy(dest[0..k], key[0..k]);
    dest[k] = '=';
    @memcpy(dest[k + 1 ..][0..v], val[0..v]);
    dest[k + 1 + v] = 0;
}

/// Whether an environment key may be passed to a child.
///
/// A key containing `=` would be read back as a shorter name with a longer
/// value, and one containing NUL would end the entry early, so both are
/// dropped rather than built into an entry that means something else.
pub fn envKeyOk(key: [*]const u8, len: usize) i32 {
    for (0..len) |index| {
        if (key[index] == 0 or key[index] == '=') return 0;
    }
    return 1;
}

/// Escapes one argument for a Windows command line, writing at most `cap`
/// bytes and returning the length the whole escaped form needs.
///
/// A process started by `CreateProcess` receives a single command line and
/// splits it itself; the rule reproduced here is the one `CommandLineToArgvW`
/// applies, and it is what makes the caller quote and double the backslashes
/// that precede a quotation mark. That rule belongs to the Windows runtime
/// rather than to the host running the build, so this is compiled and tested
/// everywhere even though only the Windows spawn calls it.
///
/// It gives back -1 where the escaped form would not fit in a Janet string,
/// which the C implementation reached only by overflowing its own length
/// arithmetic; the command line limit already enforced makes it unreachable in
/// practice.
pub fn escapeArgument(arg: [*:0]const u8, dest: ?[*]u8, cap: i32) i32 {
    var out: Escaped = .{ .dest = dest, .cap = if (cap > 0) @intCast(cap) else 0 };

    // Quoting is needed only for an argument with a byte in it that the
    // splitter would otherwise treat as a separator or as a quotation mark.
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

/// `os/pipe`, which is registered with `os/open` after the process family
/// rather than with it, and only under the event loop. The order of the `os/`
/// table is preserved because `nextmethod` walks it, which makes it
/// observable; `os/fs.zig`'s `evEntries` states the same rule at its own half.
pub fn evEntries() []const corefn.Entry {
    if (!has_ev) return &.{};
    const list = comptime [_]corefn.Entry{
        corefn.reg("os/pipe", &cfunPipe, @src(), "(os/pipe &opt flags)", "Create a readable stream and a writable stream that are connected. Returns a two-element " ++
            "tuple where the first element is a readable stream and the second element is the writable " ++
            "stream. `flags` is a keyword set of flags to disable non-blocking settings on the ends of the pipe. " ++
            "This may be desired if passing the pipe to a subprocess with `os/spawn`.\n\n" ++
            "* :W - sets the writable end of the pipe to a blocking stream.\n" ++
            "* :R - sets the readable end of the pipe to a blocking stream.\n\n" ++
            "By default, both ends of the pipe are non-blocking for use with the `ev` module."),
    };
    return &list;
}

/// Replaces the current process. Returns only on failure, with `errno` set.
pub fn exec(
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    search_path: i32,
) i32 {
    return if (search_path != 0)
        c.retryIntr(c.execvp, .{ path, argv })
    else
        c.retryIntr(c.execv, .{ path, argv });
}

/// `fork`.
pub fn forkProcess() i64 {
    return c.retryIntr(c.fork, .{});
}

/// `pipe` with both ends closed on exec, which is `ev_stream.makePipe`'s mode
/// 3. A child is given its end by `dup2`, which clears the flag on the
/// descriptor it makes. Windows keeps `c.pipe`; `makePipes` does not call this
/// there.
pub fn makePipe(fds: *[2]c_int) i32 {
    if (windows) return c.pipe(fds);
    return ev_stream.makePipe(fds, 3);
}

/// `getpid`.
pub fn processId() i64 {
    if (windows) return c._getpid();
    return c.getpid();
}

/// Collects a process the collector is discarding. Unlike `wait` this does not
/// retry and does not report the status, because the C implementation it
/// replaces did neither.
pub fn reap(pid: i64) void {
    var status: c_int = 0;
    _ = c.waitpid(@intCast(pid), &status, 0);
}

/// `kill`.
pub fn sendSignal(pid: i64, sig: i32) i32 {
    return c.kill(@intCast(pid), sig);
}

/// `system`, which runs a command line through the host's shell.
pub fn shell(command: ?[*:0]const u8) i32 {
    return c.system(command);
}

/// Finds a signal by keyword, returning its position in `signal_names` or -1.
///
/// `cstrequal` below is `utils.cstrcmp`'s walk written as an equality test:
/// the key's own length bounds the loop, a NUL in the name ends it, and a name
/// longer than the key does not match.
pub fn signalIndex(key: [*]const u8, len: usize) i32 {
    for (signal_names, 0..) |name, index| {
        if (cstrequal(key, len, name)) return @intCast(index);
    }
    return -1;
}

/// Waits for a process and classifies how it ended.
///
/// Reports the outcome and the number that goes with it, an exit code, a stop
/// signal, or a terminating signal, leaving the caller to add the offset it
/// applies to the two signal cases and to panic on the fourth outcome.
///
/// A failed `c.waitpid` is not reported. The C implementation ignored its
/// result and decoded the untouched status word, which classifies as a zero
/// exit; that is preserved here.
pub fn wait(pid: i64, val: *i32) i32 {
    var status: c_int = 0;
    _ = c.retryIntr(c.waitpid, .{ @as(h.pid_t, @intCast(pid)), &status, @as(c_int, 0) });

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

// ==========================================================================
// Private functions
// ==========================================================================

/// Builds the environment block a child is given.
///
/// The two blocks are built separately rather than unified: the POSIX block
/// drops a key containing `=` or NUL and the Windows block does not, so
/// `envKeyOk` is called only where the C original called it.
fn buildEnv(argv: []repr.Value) raise.Error!EnvBlock {
    if (argv.len <= 2) return null;
    const dict = try args_core.getDictionary(argv, 2);
    if (windows) {
        const temp = buffers.new(10);
        for (0..dict.cap) |i| {
            const kv = &dict.kvs.?[i];
            if (!repr.checkType(kv.key, repr.Tag.string)) continue;
            if (!repr.checkType(kv.value, repr.Tag.string)) continue;
            const keys = wrap.toString(kv.key);
            const vals = wrap.toString(kv.value);
            const klen = strings.head(keys).length;
            const vlen = strings.head(vals).length;
            try buffers.extra(temp, @intCast(klen + vlen + 2));
            envEntryFill(keys, klen, vals, vlen, temp.data.? + temp.count);
            temp.count += klen + vlen + 2;
        }
        // A Windows environment block is double-NUL terminated.
        if (temp.count == 0) try buffers.pushU8(temp, 0);
        try buffers.pushU8(temp, 0);
        const ret: [*]u8 = @ptrCast(gc_alloc.smalloc(@intCast(temp.count)));
        @memcpy(ret[0..@intCast(temp.count)], temp.slice());
        return ret;
    } else {
        const slots: usize = @intCast(dict.len + 1);
        const envp: [*]?[*:0]u8 = @ptrCast(@alignCast(gc_alloc.smalloc(@sizeOf(?*u8) * slots)));
        var j: usize = 0;
        for (0..dict.cap) |i| {
            const kv = &dict.kvs.?[i];
            if (!repr.checkType(kv.key, repr.Tag.string)) continue;
            if (!repr.checkType(kv.value, repr.Tag.string)) continue;
            const keys = wrap.toString(kv.key);
            const vals = wrap.toString(kv.value);
            const klen = strings.head(keys).length;
            const vlen = strings.head(vals).length;
            // The key must contain no NUL and no `=`.
            if (envKeyOk(keys, klen) == 0) continue;
            const item: [*]u8 = @ptrCast(gc_alloc.smalloc(@as(usize, @intCast(klen)) + @as(usize, @intCast(vlen)) + 2));
            envEntryFill(keys, klen, vals, vlen, item);
            envp[j] = @ptrCast(item);
            j += 1;
        }
        envp[j] = null;
        return @ptrCast(envp);
    }
}

/// `(os/execute args &opt flags env)`.
fn cfunExecute(argv: []repr.Value) raise.Error!repr.Value {
    return execute(argv, .execute);
}

/// `(os/pipe &opt flags)`.
fn cfunPipe(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 0, 1);
    var fds: [2]host.Handle = undefined;
    var flags: c_int = 0;
    if (argv.len > 0 and !repr.checkType(argv[0], repr.Tag.nil)) {
        flags = @intCast(try args_core.getFlags(argv, 0, "WR"));
    }
    if (ev_stream.makePipe(&fds, flags) != 0) return raise.panicv(ev_stream.evLasterr());
    const reader = try ev_stream.makeStream(fds[0], if (flags & 2 != 0) 0 else stream_readable, null);
    const writer = try ev_stream.makeStream(fds[1], if (flags & 1 != 0) 0 else stream_writable, null);
    var tup = [2]repr.Value{ wrap.fromAbstract(reader), wrap.fromAbstract(writer) };
    return wrap.fromTuple(tuples.newFrom(&tup));
}

/// `(os/posix-chroot path)`.
fn cfunPosixChroot(argv: []repr.Value) raise.Error!repr.Value {
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"chroot"}));
    try args_core.fixarity(argv, 1);
    if (windows) return raise.panic("not supported on Windows or Plan 9");
    const root = try args_core.getCString(argv, 0);
    if (changeRoot(root) == -1) {
        return raise.panic(@ptrCast(utils.strerrorSafe(c.errno())));
    }
    return wrap.fromNil();
}

/// `(os/posix-exec args &opt flags env)`.
fn cfunPosixExec(argv: []repr.Value) raise.Error!repr.Value {
    if (windows) return raise.panic("not supported on Windows");
    return execute(argv, .exec);
}

/// `(os/posix-fork)`.
fn cfunPosixFork(argv: []repr.Value) raise.Error!repr.Value {
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"subprocess"}));
    try args_core.fixarity(argv, 0);
    if (windows) return raise.panic("not supported on Windows");
    const result = forkProcess();
    if (result == -1) return raise.panic(@ptrCast(utils.strerrorSafe(c.errno())));
    if (result != 0) {
        const proc: *Proc = abstracts.newFor(Proc, &proc_type);
        proc.* = std.mem.zeroes(Proc);
        proc.handles.pid = @intCast(result);
        proc.flags = proc_allow_zombie;
        return wrap.fromAbstract(proc);
    }
    return wrap.fromNil();
}

/// `(:close p)`.
fn cfunProcClose(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const proc: *Proc = try args_core.getAbstract(Proc, argv, 0, &proc_type);
    if (proc.flags & proc_owns_stdin != 0) try closeStdio(proc.in.?);
    if (proc.flags & proc_owns_stdout != 0) try closeStdio(proc.out.?);
    if (proc.flags & proc_owns_stderr != 0) try closeStdio(proc.err.?);
    proc.flags &= ~(proc_owns_stdin | proc_owns_stdout | proc_owns_stderr);
    if (proc.flags & (proc_waited | proc_waiting) != 0) return wrap.fromNil();
    return procWait(proc);
}

/// `(os/proc-getpid p)`.
fn cfunProcGetpid(argv: []repr.Value) raise.Error!repr.Value {
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"subprocess"}));
    try args_core.fixarity(argv, 0);
    return wrap.fromNumber(@floatFromInt(processId()));
}

/// `(os/proc-kill p &opt wait signal)`.
fn cfunProcKill(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, 3);
    const proc: *Proc = try args_core.getAbstract(Proc, argv, 0, &proc_type);
    if (proc.flags & proc_waited != 0) {
        return raise.panic("cannot kill process that has already finished");
    }
    if (windows) {
        if (proc.flags & proc_closed != 0) {
            return raise.panic("cannot close process handle that is already closed");
        }
        proc.flags |= proc_closed;
        _ = c.TerminateProcess(proc.handles.p, 1);
        _ = c.CloseHandle(proc.handles.p);
        _ = c.CloseHandle(proc.handles.t);
    } else {
        var signal: c_int = -1;
        if (argv.len == 3) signal = try getSignalKw(argv, 2);
        const status = sendSignal(proc.pid(), if (signal == -1) h.SIGKILL else signal);
        if (status != 0) return raise.panic(@ptrCast(utils.strerrorSafe(c.errno())));
    }
    // Having killed it, wait on it, but only if asked.
    if (argv.len > 1 and repr.truthy(argv[1])) return procWait(proc);
    return argv[0];
}

/// `(os/proc-wait p)`.
fn cfunProcWait(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const proc: *Proc = try args_core.getAbstract(Proc, argv, 0, &proc_type);
    return procWait(proc);
}

/// `(os/shell &opt cmd)`.
fn cfunShell(argv: []repr.Value) raise.Error!repr.Value {
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"subprocess"}));
    try args_core.arity(argv, 0, 1);
    const cmd: ?[*:0]const u8 = if (argv.len != 0) try args_core.getCString(argv, 0) else null;
    if (has_ev) {
        var cmd_copy: ?*anyopaque = null;
        if (cmd) |src| {
            const cmdlen = std.mem.len(src);
            const dest: [*]u8 = @ptrCast(utils.malloc(cmdlen + 1).?);
            @memcpy(dest[0..cmdlen], src[0..cmdlen]);
            dest[cmdlen] = 0;
            cmd_copy = dest;
        }
        return ev_loop.threadedAwait(&shellSubroutine, 0, @as(i32, @intCast(argv.len)), cmd_copy);
    } else {
        const stat = shell(cmd);
        return if (argv.len != 0) wrap.fromInteger(stat) else wrap.fromBoolean(stat != 0);
    }
}

/// `(os/sigaction signal &opt handler)`.
fn cfunSigaction(argv: []repr.Value) raise.Error!repr.Value {
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"signal"}));
    try args_core.arity(argv, 1, 3);
    if (windows) return raise.panic("unsupported on this platform");

    const sig = try getSignalKw(argv, 0);
    const handler: ?*functions.Function =
        if (argv.len > 1 and !repr.checkType(argv[1], repr.Tag.nil))
            try args_core.getFunction(argv, 1)
        else
            null;
    const can_interrupt = try args_core.optBoolean(argv, 2, false);
    const oldhandler = tables.get(&vm_state.current().ev.signal_handlers, wrap.fromInteger(sig));
    if (!repr.checkType(oldhandler, repr.Tag.nil)) _ = gc_alloc.gcunroot(oldhandler);
    if (handler) |f| {
        // A handler is entered with no arguments, so one that cannot accept
        // zero can never run: no fiber can be built for it. Refusing at
        // registration names the mistake at the line that made it, where the
        // caller can still act on it.
        if (f.def.?.min_arity > 0) {
            return pp_format.panicf(
                "signal handler must accept zero arguments, got one of arity %d",
                .{f.def.?.min_arity},
            );
        }
        const handlerv = wrap.fromFunction(f);
        gc_alloc.gcroot(handlerv);
        tables.put(&vm_state.current().ev.signal_handlers, wrap.fromInteger(sig), handlerv);
    } else {
        tables.put(&vm_state.current().ev.signal_handlers, wrap.fromInteger(sig), wrap.fromNil());
    }

    // Emptied before it is added to, which is what leaves just this signal in
    // the mask. `sigaddset` adds to an existing set, so without the
    // `sigemptyset` the mask the handler runs under would be whatever was on
    // the stack. The unblock set below already writes the same pair in the
    // right order.
    var mask: h.sigset_t = undefined;
    _ = oa.sigemptyset(&mask);
    _ = oa.sigaddset(&mask, sig);
    var action: h.struct_sigaction = std.mem.zeroes(h.struct_sigaction);
    action.sa_flags |= h.SA_RESTART;
    if (can_interrupt) {
        if (constants.JANET_VM_HAS_INTERRUPT == 0) return raise.panic("interpreter interrupt not enabled");
        setHandler(&action, &Trampolines.interrupting);
    } else {
        setHandler(&action, &Trampolines.plain);
    }
    action.sa_mask = mask;
    _ = c.retryIntr(oa.sigaction, .{ sig, &action, null });
    var set: h.sigset_t = undefined;
    _ = oa.sigemptyset(&set);
    _ = oa.sigaddset(&set, sig);
    _ = oa.sigprocmask(h.SIG_UNBLOCK, &set, null);
    return wrap.fromNil();
}

/// `(os/spawn args &opt flags env)`.
fn cfunSpawn(argv: []repr.Value) raise.Error!repr.Value {
    return execute(argv, .spawn);
}

/// Frees what `buildEnv` allocated, and the child's argument vector with it.
fn cleanupEnv(envp: EnvBlock, child_argv: ?*const anyopaque) void {
    if (windows) {
        if (envp) |p| gc_alloc.sfree(p);
    } else {
        gc_alloc.sfree(@constCast(child_argv));
        if (envp) |p| {
            var i: usize = 0;
            while (p[i]) |item| : (i += 1) gc_alloc.sfree(item);
            gc_alloc.sfree(@ptrCast(p));
        }
    }
}

/// Closes a host handle.
fn closeHandle(handle: host.Handle) void {
    if (windows) _ = c.CloseHandle(handle) else _ = closeDescriptor(handle);
}

/// Closes the three stdio abstracts a `Proc` owns.
inline fn closeStdio(x: *Stdio) raise.Error!void {
    if (has_ev) try ev_stream.streamClose(x) else _ = io.fileClose(x);
}

/// Whether the `len` bytes at `key` are `other`, with a NUL in `other` ending
/// the comparison.
fn cstrequal(key: [*]const u8, len: usize, other: [:0]const u8) bool {
    var index: usize = 0;
    while (index < len) : (index += 1) {
        const k = other.ptr[index];
        if (key[index] != k) return false;
        if (k == 0) break;
    }
    return other.ptr[index] == 0;
}

/// One command line string in the form `CommandLineToArgvW` parses.
///
/// The escaping rule itself is `escapeArgument`'s and is compiled and tested
/// on every platform; this is the measure-then-fill wrapper, which exists
/// because growing the buffer can raise and the escaping may not.
fn execEscape(args: []const repr.Value) raise.Error!*buffers.Buffer {
    const b = buffers.new(0);
    for (0..args.len) |i| {
        const arg = try args_core.getCString(args, i);
        if (i != 0) try buffers.pushU8(b, ' ');
        const needed = escapeArgument(arg, null, 0);
        if (needed < 0) return raise.panic("command line string too long (max 8191 characters)");
        // The checked conversion: `escapeArgument` gives back a signed length
        // and negative is its overflow report, which the line above consumed.
        try buffers.extra(b, @intCast(needed));
        _ = escapeArgument(arg, b.data.? + b.count, needed);
        b.count += @intCast(needed);
    }
    try buffers.pushU8(b, 0);
    return b;
}

/// The body of `os/execute`, `os/spawn` and `os/posix-exec`, which differ in
/// what they do with the child once it is started.
fn execute(argv: []repr.Value, mode: ExecuteMode) raise.Error!repr.Value {
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"subprocess"}));
    try args_core.arity(argv, 1, 3);

    const is_spawn = mode == .spawn;
    var flags: u64 = 0;
    if (argv.len > 1) flags = try args_core.getFlags(argv, 1, "epxd");

    const use_environ = !flagAt(flags, 0);
    const envp = try buildEnv(argv);

    // Gathered rather than read a run at a time: the arguments leave this
    // runtime as one array of C strings, which no iterator can hand over.
    var gathered = try args_core.gatherArg(argv, 0);
    const exargs = gathered.items;
    if (exargs.len < 1) return raise.panic("expected at least 1 command line argument");

    var r: Redirection = .{};
    r.owner_flags = if (is_spawn and flags & 0x8 != 0) proc_allow_zombie else 0;

    if (argv.len > 2 and mode != .exec) {
        const tab = try args_core.getDictionary(argv, 2);
        const maybe_stdin = value.dictionaryGet(tab.kvs.?[0..@intCast(tab.cap)], value.fromBytes("in", .keyword));
        const maybe_stdout = value.dictionaryGet(tab.kvs.?[0..@intCast(tab.cap)], value.fromBytes("out", .keyword));
        const maybe_stderr = value.dictionaryGet(tab.kvs.?[0..@intCast(tab.cap)], value.fromBytes("err", .keyword));
        var slot = maybe_stdin;
        if (is_spawn and args_core.keyeq(maybe_stdin, "pipe")) {
            if (makePipes(true)) |p| {
                r.new_in = p.keep;
                r.pipe_in = p.give;
            } else {
                r.errflag = 1;
            }
            r.owner_flags |= proc_owns_stdin;
        } else if (!repr.checkType(maybe_stdin, repr.Tag.nil)) {
            r.new_in = try getJStream((&slot)[0..1], 0, &r.orig_in);
        }
        slot = maybe_stdout;
        if (is_spawn and args_core.keyeq(maybe_stdout, "pipe")) {
            if (makePipes(false)) |p| {
                r.new_out = p.keep;
                r.pipe_out = p.give;
            } else {
                r.errflag = 1;
            }
            r.owner_flags |= proc_owns_stdout;
        } else if (!repr.checkType(maybe_stdout, repr.Tag.nil)) {
            r.new_out = try getJStream((&slot)[0..1], 0, &r.orig_out);
        }
        slot = maybe_stderr;
        if (is_spawn and args_core.keyeq(maybe_stderr, "pipe")) {
            if (makePipes(false)) |p| {
                r.new_err = p.keep;
                r.pipe_err = p.give;
            } else {
                r.errflag = 1;
            }
            r.owner_flags |= proc_owns_stderr;
        } else if (args_core.keyeq(maybe_stderr, "out")) {
            r.stderr_is_stdout = true;
        } else if (!repr.checkType(maybe_stderr, repr.Tag.nil)) {
            r.new_err = try getJStream((&slot)[0..1], 0, &r.orig_err);
        }
    }

    // The working directory, for `os/execute` and `os/spawn` alike.
    var chdir_path: ?[*:0]const u8 = null;
    if (argv.len > 2) {
        const tab = try args_core.getDictionary(argv, 2);
        const workdir = value.dictionaryGet(tab.kvs.?[0..@intCast(tab.cap)], value.fromBytes("cd", .keyword));
        if (repr.checkType(workdir, repr.Tag.string)) {
            chdir_path = @ptrCast(wrap.toString(workdir));
            if (!spawn_chdir) {
                return pp_format.panicf(":cd argument not supported on this system - %s", .{chdir_path.?});
            }
        } else if (!repr.checkType(workdir, repr.Tag.nil)) {
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
    // Released here rather than at each return below, `exargs` being read no
    // further. A raise above this leaves the block to the scratch sweep.
    gathered.free();

    proc.flags = r.owner_flags;
    if (flagAt(flags, 2)) proc.flags |= proc_error_nonzero;
    if (is_spawn) {
        // Only `os/spawn` hands the caller the three ends it kept.
        if (isHandle(r.new_in)) {
            proc.in = try getStdioForHandle(r.new_in, r.orig_in, true) orelse
                return raise.panic("failed to construct proc");
        }
        if (isHandle(r.new_out)) {
            proc.out = try getStdioForHandle(r.new_out, r.orig_out, false) orelse
                return raise.panic("failed to construct proc");
        }
        if (isHandle(r.new_err)) {
            proc.err = try getStdioForHandle(r.new_err, r.orig_err, false) orelse
                return raise.panic("failed to construct proc");
        }
        return wrap.fromAbstract(proc);
    }
    return procWait(proc);
}

/// Whether bit `index` of `flags` is set.
inline fn flagAt(flags: u64, index: u6) bool {
    return flags & (@as(u64, 1) << index) != 0;
}

/// The OS handle behind a `core/stream` or a `core/file`, and the abstract it
/// came from.
fn getJStream(argv: []repr.Value, n: usize, orig: *?*anyopaque) raise.Error!host.Handle {
    if (has_ev) {
        if (args_core.checkabstract(argv[n], &ev_stream.streamType)) |p| {
            const stream: *ev_stream.Stream = @ptrCast(@alignCast(p));
            if (stream.flags & stream_closed != 0) return raise.panic("stream is closed");
            orig.* = stream;
            return stream.handle;
        }
    }
    if (args_core.checkabstract(argv[n], &io.fileType)) |p| {
        const f: *io.File = @ptrCast(@alignCast(p));
        if (f.flags & file_closed != 0) return raise.panic("file is closed");
        orig.* = f;
        if (windows) return @ptrFromInt(@as(usize, @bitCast(c._get_osfhandle(c._fileno(f.file)))));
        return c.fileno(f.file);
    }
    return pp_format.panicf("expected file|stream, got %v", .{argv[n]});
}

/// The signal a keyword names. A keyword the name list does not have and one
/// this platform's headers left out are both "undefined signal", which is what
/// the `#ifdef`-gated C table produced by omitting the entry.
fn getSignalKw(argv: []const repr.Value, n: usize) raise.Error!c_int {
    const kw = try args_core.getKeyword(argv, n);
    const index = signalIndex(kw, strings.head(kw).length);
    if (index >= 0 and signal_numbers[@intCast(index)] >= 0) {
        return signal_numbers[@intCast(index)];
    }
    return pp_format.panicf("undefined signal %v", .{argv[n]});
}

/// The stdio abstract for one of the child's handles, or nothing where the
/// host refused to give this process its own copy of the handle, which the
/// caller reports as a failure to construct the process.
///
/// Raising, because registering a new stream with the event-loop backend can,
/// and the three callers are all inside `os/spawn`, which already has an error
/// channel.
fn getStdioForHandle(handle: host.Handle, orig: ?*anyopaque, iswrite: bool) raise.Error!?*Stdio {
    if (has_ev) {
        const p = orig orelse
            return try ev_stream.makeStream(handle, if (iswrite) stream_writable else stream_readable, null);
        if (abi.abstractHead(p).type == &io.fileType) {
            const jf: *io.File = @ptrCast(@alignCast(p));
            var flags: u32 = 0;
            if (jf.flags & file_write != 0) flags |= stream_writable;
            if (jf.flags & file_read != 0) flags |= stream_readable;
            // A file becoming a stream gets its own duplicate of the handle,
            // so that closing one does not close the other. The duplicate
            // stays with this process: the Windows one is not inheritable,
            // and the POSIX one is closed on exec, which `dup` does not copy
            // and `dup2` clears on the descriptor the child is given.
            if (windows) {
                const prochandle = c.GetCurrentProcess();
                var new_handle: host.Handle = undefined;
                if (c.DuplicateHandle(prochandle, handle, prochandle, &new_handle, 0, 0, 0x2) == 0) {
                    return null;
                }
                return try ev_stream.makeStream(new_handle, flags, null);
            }
            const new_handle = c.dup(handle);
            if (new_handle < 0) return null;
            _ = c.fcntl(new_handle, h.F_SETFD, h.FD_CLOEXEC);
            return try ev_stream.makeStream(new_handle, flags, null);
        }
        return @ptrCast(@alignCast(p));
    } else {
        if (orig) |p| return @ptrCast(@alignCast(p));
        if (windows) {
            const fd = c._open_osfhandle(@bitCast(@intFromPtr(handle)), if (iswrite) h._O_WRONLY else h._O_RDONLY);
            if (fd == -1) return null;
            const f = c._fdopen(fd, if (iswrite) "w" else "r") orelse {
                _ = c._close(fd);
                return null;
            };
            return io.makejfile(f, if (iswrite) file_write else file_read);
        }
        const f = c.fdopen(handle, if (iswrite) "w" else "r") orelse return null;
        return io.makejfile(f, if (iswrite) file_write else file_read);
    }
}

/// Whether a redirection slot has a handle in it.
inline fn isHandle(x: host.Handle) bool {
    return if (windows) x != null else x != -1;
}

/// Makes a pipe and reports both ends, or nothing where the host refused: the
/// caller keeps `keep`, and `give` is the end the child gets, closed after the
/// spawn. A failure anywhere gives back nothing, exactly as the C `goto error`
/// did, and, exactly as there, the handles opened before the failure are not
/// closed here.
fn makePipes(reverse: bool) ?struct { keep: host.Handle, give: host.Handle } {
    var handles: [2]host.Handle = undefined;
    if (has_ev) {
        // Non-blocking pipes.
        if (ev_stream.makePipe(&handles, if (reverse) 2 else 1) != 0) return null;
        if (reverse) std.mem.swap(host.Handle, &handles[0], &handles[1]);
        if (windows) {
            if (c.SetHandleInformation(handles[0], h.HANDLE_FLAG_INHERIT, 0) == 0) return null;
        }
    } else if (windows) {
        var sa_attr: h.SECURITY_ATTRIBUTES = std.mem.zeroes(h.SECURITY_ATTRIBUTES);
        sa_attr.nLength = @sizeOf(h.SECURITY_ATTRIBUTES);
        sa_attr.bInheritHandle = 1;
        if (oa.CreatePipe(&handles[0], &handles[1], &sa_attr, 0) == 0) return null;
        if (reverse) std.mem.swap(host.Handle, &handles[0], &handles[1]);
        // Do not inherit the side of the pipe this process owns.
        if (c.SetHandleInformation(handles[0], h.HANDLE_FLAG_INHERIT, 0) == 0) return null;
    } else {
        if (makePipe(&handles) != 0) return null;
        if (reverse) std.mem.swap(host.Handle, &handles[0], &handles[1]);
    }
    return .{ .keep = handles[0], .give = handles[1] };
}

/// Allocates a `Proc` and fills in the fields a spawn has settled.
fn newProc() *Proc {
    const proc: *Proc = abstracts.newFor(Proc, &proc_type);
    proc.return_code = -1;
    proc.in = null;
    proc.out = null;
    proc.err = null;
    proc.flags = 0;
    return proc;
}

/// Reaps the child and frees its stdio when the abstract is collected.
fn procGc(proc: *Proc, _: usize) void {
    if (windows) {
        if (proc.flags & proc_closed == 0) {
            if (proc.flags & proc_allow_zombie == 0) _ = c.TerminateProcess(proc.handles.p, 1);
            _ = c.CloseHandle(proc.handles.p);
            _ = c.CloseHandle(proc.handles.t);
        }
    } else {
        if (proc.flags & (proc_waited | proc_allow_zombie) == 0) {
            // Kill and wait, so that the child does not become a zombie.
            _ = sendSignal(proc.pid(), h.SIGKILL);
            if (proc.flags & proc_waiting == 0) reap(proc.pid());
        }
    }
}

/// The method lookup behind `(:wait p)` and its siblings, and the three dud
/// entries `(keys p)` reports.
fn procGet(proc: *Proc, key: repr.Value) raise.Error!?repr.Value {
    if (args_core.keyeq(key, "in"))
        return if (proc.in) |x| wrap.fromAbstract(x) else wrap.fromNil();
    if (args_core.keyeq(key, "out"))
        return if (proc.out) |x| wrap.fromAbstract(x) else wrap.fromNil();
    if (args_core.keyeq(key, "err"))
        return if (proc.err) |x| wrap.fromAbstract(x) else wrap.fromNil();
    if (!windows) {
        if (args_core.keyeq(key, "pid"))
            return wrap.fromNumber(@floatFromInt(proc.handles.pid));
    }
    if (proc.return_code != -1 and args_core.keyeq(key, "return-code"))
        return wrap.fromInteger(proc.return_code);
    return args_core.findMethod(key, @ptrCast(&proc_methods));
}

/// POSIX shell semantics for a signalled or stopped child. The 128 offset and
/// the fourth-outcome raise are here rather than beside `wait` because a raise
/// may not cross that seam.
fn procGetStatus(proc: *Proc) raise.Error!c_int {
    var val: i32 = 0;
    const outcome = wait(proc.pid(), &val);
    if (outcome == wait_exited) return val;
    if (outcome == wait_stopped or outcome == wait_signaled) return val + 128;
    return pp_format.panicf("Undefined status code for process termination, %d.", .{val});
}

/// Traces the three stdio abstracts.
fn procMark(proc: *Proc, _: usize) void {
    if (proc.in) |x| gc_mark.mark(wrap.fromAbstract(x));
    if (proc.out) |x| gc_mark.mark(wrap.fromAbstract(x));
    if (proc.err) |x| gc_mark.mark(wrap.fromAbstract(x));
}

/// The iteration order behind `next` and `(keys p)`.
fn procNext(_: *Proc, key: repr.Value) raise.Error!repr.Value {
    return args_core.nextmethod(@ptrCast(&proc_methods), key);
}

/// Waits for the child, and gives back its exit code.
///
/// Under the event loop nothing comes back, because `ev.awaitEvent` returns
/// the raise that suspends the fiber; without it the wait happens inline and
/// the exit code is the result. The C original spells that with two different
/// return types behind one `#ifdef`; this returns an optional instead, and the
/// two callers read it the same way.
fn procWait(proc: *Proc) raise.Error!repr.Value {
    if (proc.flags & (proc_waited | proc_waiting) != 0) {
        return raise.panic("cannot wait twice on a process");
    }
    if (has_ev) {
        // The threaded call resumes the current fiber when the child exits,
        // and `ev.awaitEvent` returns the raise that suspends it; the exit
        // code reaches Janet through the callback rather than through this
        // frame.
        proc.flags |= proc_waiting;
        var targs: ev_loop.GenericMessage = std.mem.zeroes(ev_loop.GenericMessage);
        targs.argp = proc;
        targs.fiber = fibers.root();
        targs.argi = @bitCast(targs.fiber.?.sched_id);
        gc_alloc.gcroot(wrap.fromAbstract(proc));
        gc_alloc.gcroot(wrap.fromFiber(targs.fiber.?));
        try ev_loop.threadedCall(&Waiter.subroutine, targs, &Waiter.callbackAbi);
        return ev_loop.awaitEvent();
    } else {
        proc.flags |= proc_waited;
        var status: c_int = 0;
        if (windows) {
            _ = c.WaitForSingleObject(proc.handles.p, 0xFFFF_FFFF);
            var exitcode: u32 = 0;
            _ = c.GetExitCodeProcess(proc.handles.p, &exitcode);
            status = @bitCast(exitcode);
            if (proc.flags & proc_closed == 0) {
                proc.flags |= proc_closed;
                _ = c.CloseHandle(proc.handles.p);
                _ = c.CloseHandle(proc.handles.t);
            }
        } else {
            status = try procGetStatus(proc);
        }
        proc.return_code = status;
        // The `:x` flag is honoured here too. Only the evented completion
        // callback reads it in the C original, so a build without the event
        // loop accepted the flag and did nothing with it, which leaves a
        // caller relying on it for error handling with nothing. The message is
        // the callback's, so the two configurations behave alike.
        if (status != 0 and proc.flags & proc_error_nonzero != 0) {
            return pp_format.panicf("command failed with non-zero exit code %d", .{status});
        }
        return wrap.fromInteger(proc.return_code);
    }
}

/// libc's `raise`, which cannot be spelled `extern fn raise` here because
/// `raise` is the name this file imports the error mechanism under.
const raiseSignal = @extern(*const fn (c_int) callconv(.c) c_int, .{ .name = "raise" });

/// Installs a handler into a `struct sigaction`, whichever of the three
/// spellings this platform's header uses.
///
/// POSIX says `sa_handler` may be a macro over a union member, and every libc
/// takes it up differently. The translation renders what the header says, so
/// the field path is:
///
/// | libc | path |
/// | --- | --- |
/// | macOS | `__sigaction_u.__sa_handler` |
/// | musl | `__sa_handler.sa_handler` |
/// | glibc | `__sigaction_handler.sa_handler` |
///
/// Only the host's spelling was needed to compile on the host, so the
/// cross-compiles are what found this. The lookup is written out rather than
/// guessed at by position, so that a fourth spelling fails to compile here
/// instead of writing into the wrong member.
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

/// The `os/shell` body, which runs on a worker thread.
///
/// The reply's payload pointer is cleared after the request's is freed. The
/// reply's tag is an integer or a boolean, which has no payload, so leaving
/// the freed request pointer in it would hand the callback something already
/// released, which is exactly what `goThreadSubr` clears for the same reason.
fn shellSubroutine(args: ev_loop.GenericMessage) callconv(.c) ev_loop.GenericMessage {
    var out = args;
    const stat = shell(@ptrCast(@alignCast(args.argp)));
    utils.free(args.argp);
    out.argp = null;
    out.tag = if (args.argi != 0) constants.JANET_EV_TCTAG_INTEGER else constants.JANET_EV_TCTAG_BOOLEAN;
    out.argi = stat;
    return out;
}

/// What runs on the main thread after a signal, where the trampoline posted an
/// event.
fn signalCallback(msg: ev_loop.GenericMessage) callconv(.c) void {
    const sig = msg.tag;
    if (msg.argi != 0) vm_state.interpreterInterruptHandled(null);
    const handlerv = tables.get(&vm_state.current().ev.signal_handlers, wrap.fromInteger(sig));
    if (!repr.checkType(handlerv, repr.Tag.function)) {
        // No handler is installed for it: unblock this signal and re-raise,
        // so that another thread or the default disposition can take it.
        var set: h.sigset_t = undefined;
        _ = oa.sigemptyset(&set);
        _ = oa.sigaddset(&set, sig);
        _ = oa.sigprocmask(h.SIG_BLOCK, &set, null);
        _ = raiseSignal(sig);
        return;
    }
    const handler = wrap.toFunction(handlerv);
    const fiber = fibers.new(handler, 64, &.{}) catch return;
    ev_loop.scheduleSoon(fiber, wrap.fromNil(), abi.Signal.ok);
}

/// The POSIX spawn, and the `exec` mode that never returns.
///
/// `child_argv` and the environment block are `gc.smalloc` scratch, released
/// by `cleanupEnv` on the way out. A raise between the two, from
/// `args.getCString` on a non-string element, say, returns past that release,
/// and the blocks are reclaimed wholesale when the protected scope above
/// unwinds, which is what makes the skipped `sfree` harmless.
fn spawnPosix(
    argv: []repr.Value,
    exargs: []const repr.Value,
    r: *Redirection,
    flags: u64,
    envp: EnvBlock,
    use_environ: bool,
    chdir_path: ?[*:0]const u8,
    mode: ExecuteMode,
) raise.Error!*Proc {
    const count: usize = exargs.len;
    const child_argv: [*]?[*:0]const u8 = @ptrCast(@alignCast(gc_alloc.smalloc(@sizeOf(?*u8) * (count + 1))));
    for (0..count) |i| {
        child_argv[i] = try args_core.getCString(exargs, i);
    }
    child_argv[count] = null;
    const cargv: [*:null]const ?[*:0]const u8 = @ptrCast(child_argv);

    if (use_environ) oa.lockEnviron();

    if (mode == .exec) {
        // Only a failure returns, and the message reads `errno` rather than
        // the result, so the result is deliberately discarded.
        if (!use_environ) oa.setEnviron(@ptrCast(envp));
        _ = exec(cargv[0].?, cargv, if (flagAt(flags, 1)) 1 else 0);
        // `%s`, not `%p`: `%p` takes a `Janet` and `cargv[0]` is a `char *`,
        // so a `%p` here renders the pointer's bits as a denormal double.
        return pp_format.panicf("%s: %s", .{
            cargv[0].?,
            utils.strerrorSafe(if (c.errno() != 0) c.errno() else h.ENOENT),
        });
    }

    if (no_spawn) return raise.panic("subprocess creation not supported in this build");

    var actions: h.posix_spawn_file_actions_t = undefined;
    _ = oa.posix_spawn_file_actions_init(&actions);
    if (spawn_chdir) {
        if (chdir_path) |path| {
            if (oa.spawn_chdir_np) {
                _ = oa.posix_spawn_file_actions_addchdir_np(&actions, path);
            } else {
                _ = oa.posix_spawn_file_actions_addchdir(&actions, path);
            }
        }
    }
    if (isHandle(r.pipe_in)) {
        _ = oa.posix_spawn_file_actions_adddup2(&actions, r.pipe_in, 0);
        _ = oa.posix_spawn_file_actions_addclose(&actions, r.pipe_in);
    } else if (isHandle(r.new_in) and r.new_in != 0) {
        _ = oa.posix_spawn_file_actions_adddup2(&actions, r.new_in, 0);
        if (r.new_in != r.new_out and r.new_in != r.new_err) {
            _ = oa.posix_spawn_file_actions_addclose(&actions, r.new_in);
        }
    }
    if (isHandle(r.pipe_out)) {
        _ = oa.posix_spawn_file_actions_adddup2(&actions, r.pipe_out, 1);
        _ = oa.posix_spawn_file_actions_addclose(&actions, r.pipe_out);
    } else if (isHandle(r.new_out) and r.new_out != 1) {
        _ = oa.posix_spawn_file_actions_adddup2(&actions, r.new_out, 1);
        if (r.new_out != r.new_err) {
            _ = oa.posix_spawn_file_actions_addclose(&actions, r.new_out);
        }
    }
    if (isHandle(r.pipe_err)) {
        _ = oa.posix_spawn_file_actions_adddup2(&actions, r.pipe_err, 2);
        _ = oa.posix_spawn_file_actions_addclose(&actions, r.pipe_err);
    } else if (isHandle(r.new_err) and r.new_err != 2) {
        _ = oa.posix_spawn_file_actions_adddup2(&actions, r.new_err, 2);
        _ = oa.posix_spawn_file_actions_addclose(&actions, r.new_err);
    } else if (r.stderr_is_stdout) {
        _ = oa.posix_spawn_file_actions_adddup2(&actions, 1, 2);
    }

    var pid: h.pid_t = undefined;
    const environment: ?[*]?[*:0]u8 = if (use_environ) oa.getEnviron() else @ptrCast(envp);
    const status = if (flagAt(flags, 1))
        oa.posix_spawnp(&pid, child_argv[0].?, &actions, null, cargv, environment)
    else
        oa.posix_spawn(&pid, child_argv[0].?, &actions, null, cargv, environment);

    _ = oa.posix_spawn_file_actions_destroy(&actions);

    if (isHandle(r.pipe_in)) _ = closeDescriptor(r.pipe_in);
    if (isHandle(r.pipe_out)) _ = closeDescriptor(r.pipe_out);
    if (isHandle(r.pipe_err)) _ = closeDescriptor(r.pipe_err);

    if (use_environ) oa.unlockEnviron();

    cleanupEnv(envp, @ptrCast(child_argv));
    if (status != 0) {
        // `posix_spawn` returns the error, the child's own where exec failed,
        // and does not set `errno`.
        return pp_format.panicf("%p: %s", .{ argv[0], utils.strerrorSafe(status) });
    }

    const proc = newProc();
    proc.handles.pid = pid;
    return proc;
}

/// The Windows spawn. Compiled only for a Windows target and never run:
/// Windows is compile-checked and untested here, and the cross-compile is what
/// checks it. `test/README.md` has the limitation.
fn spawnWindows(
    argv: []repr.Value,
    exargs: []const repr.Value,
    r: *Redirection,
    flags: u64,
    envp: EnvBlock,
    use_environ: bool,
    chdir_path: ?[*:0]const u8,
) raise.Error!*Proc {
    _ = argv;
    var sa_attr: h.SECURITY_ATTRIBUTES = std.mem.zeroes(h.SECURITY_ATTRIBUTES);
    var process_info: h.PROCESS_INFORMATION = std.mem.zeroes(h.PROCESS_INFORMATION);
    var startup_info: h.STARTUPINFOA = std.mem.zeroes(h.STARTUPINFOA);
    startup_info.cb = @sizeOf(h.STARTUPINFOA);
    startup_info.dwFlags |= h.STARTF_USESTDHANDLES;
    sa_attr.nLength = @sizeOf(h.SECURITY_ATTRIBUTES);

    const buf = try execEscape(exargs);
    if (buf.count > 8191) {
        if (isHandle(r.pipe_in)) _ = c.CloseHandle(r.pipe_in);
        if (isHandle(r.pipe_out)) _ = c.CloseHandle(r.pipe_out);
        if (isHandle(r.pipe_err)) _ = c.CloseHandle(r.pipe_err);
        return raise.panic("command line string too long (max 8191 characters)");
    }
    const path: [*:0]const u8 = @ptrCast(wrap.toString(exargs[0]));

    startup_info.hStdInput = if (isHandle(r.pipe_in))
        r.pipe_in
    else if (isHandle(r.new_in))
        r.new_in
    else
        @ptrFromInt(@as(usize, @bitCast(c._get_osfhandle(c._fileno(stdio.in())))));

    startup_info.hStdOutput = if (isHandle(r.pipe_out))
        r.pipe_out
    else if (isHandle(r.new_out))
        r.new_out
    else
        @ptrFromInt(@as(usize, @bitCast(c._get_osfhandle(c._fileno(stdio.out())))));

    startup_info.hStdError = if (isHandle(r.pipe_err))
        r.pipe_err
    else if (isHandle(r.new_err))
        r.new_err
    else if (r.stderr_is_stdout)
        startup_info.hStdOutput
    else
        @ptrFromInt(@as(usize, @bitCast(c._get_osfhandle(c._fileno(stdio.err())))));

    var cp_failed = false;
    var cp_error_code: u32 = 0;
    if (oa.CreateProcessA(
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
        cp_error_code = c.GetLastError();
    }

    if (isHandle(r.pipe_in)) _ = c.CloseHandle(r.pipe_in);
    if (isHandle(r.pipe_out)) _ = c.CloseHandle(r.pipe_out);
    if (isHandle(r.pipe_err)) _ = c.CloseHandle(r.pipe_err);

    cleanupEnv(envp, null);

    if (cp_failed) {
        var msgbuf: [256]u8 = undefined;
        msgbuf[0] = 0;
        _ = c.FormatMessageA(
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

// ==========================================================================
// Tests
// ==========================================================================

/// Escapes one argument into a fresh allocation, checking the measured length
/// against the filled one.
fn escape(arg: [:0]const u8) ![]u8 {
    const needed = escapeArgument(arg.ptr, null, 0);
    const buffer = try std.testing.allocator.alloc(u8, @intCast(needed));
    try std.testing.expectEqual(needed, escapeArgument(arg.ptr, buffer.ptr, needed));
    return buffer;
}

/// Escapes `arg` and compares it with `expected`.
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
    // The signal's own name with the `SIG` dropped, like every other row, and
    // no alias for the transposition the table once had.
    try std.testing.expectEqual(@as(i32, 25), signalIndex("vtalrm", 6));
    try std.testing.expectEqual(@as(i32, -1), signalIndex("vtlarm", 6));
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

    // A value may contain anything, including the separator.
    envEntryFill("K", 1, "a=b", 3, &buffer);
    try std.testing.expectEqualStrings("K=a=b", buffer[0..5]);
    try std.testing.expectEqual(@as(u8, 0), buffer[5]);
}
