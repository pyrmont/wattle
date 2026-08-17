//! The portable rules and the scalar host calls behind Janet's process
//! functions.
//!
//! Three kernels — the signal keyword lookup, the Windows command-line
//! argument escaping, and the environment entry rule and layout — together
//! with the process calls behind `os/execute`, `os/spawn`, `os/proc-wait`,
//! `os/proc-kill`, `os/getpid`, `os/posix-fork`, `os/posix-exec`,
//! `os/posix-chroot`, and `os/shell`. C retains sandbox and argument checks,
//! Janet value construction, `errno` formatting, and every panic path.
//!
//! Every host structure this area touches stays in C. `posix_spawn` works
//! through a `posix_spawn_file_actions_t`, `os/sigaction` through a `struct
//! sigaction` and a `sigset_t`, and the Windows spawn through
//! `STARTUPINFO`, `PROCESS_INFORMATION`, and `SECURITY_ATTRIBUTES`; all fall
//! under the rule that kept `jstat_t` and `struct timespec` behind. What
//! crosses here is a pid, a signal number, a descriptor, and bytes.
//!
//! A wait status is the one host encoding this subsystem decodes. It is a
//! scalar, not a structure, and `std.c.W` transcribes the same platform
//! definitions the `WIF*` macros expand to, so it is read here rather than in
//! C. The classification crosses the boundary; the policy that turns it into
//! the number Janet reports stays in C, because the fourth outcome panics.

const std = @import("std");
const builtin = @import("builtin");

const windows = builtin.os.tag == .windows;

const pid_t = if (windows) c_int else std.c.pid_t;

/// Mirrors the `JANET_OS_WAIT_*` codes in `src/core/os.c`.
const wait_exited: i32 = 0;
const wait_stopped: i32 = 1;
const wait_signaled: i32 = 2;
const wait_unknown: i32 = 3;

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

comptime {
    @export(&escapeArgument, .{ .name = "janet_os_exec_escape_arg" });
    @export(&envKeyOk, .{ .name = "janet_os_env_key_ok" });
    @export(&envEntryFill, .{ .name = "janet_os_env_entry_fill" });
    @export(&processId, .{ .name = "janet_os_getpid" });
    @export(&shell, .{ .name = "janet_os_system" });
    if (!windows) {
        @export(&signalIndex, .{ .name = "janet_os_signal_index" });
        @export(&wait, .{ .name = "janet_os_wait" });
        @export(&reap, .{ .name = "janet_os_reap" });
        @export(&sendSignal, .{ .name = "janet_os_kill" });
        @export(&makePipe, .{ .name = "janet_os_pipe" });
        @export(&closeDescriptor, .{ .name = "janet_os_close_fd" });
        @export(&forkProcess, .{ .name = "janet_os_fork" });
        @export(&exec, .{ .name = "janet_os_exec" });
        @export(&changeRoot, .{ .name = "janet_os_chroot" });
    }
}

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
fn signalIndex(key: [*]const u8, len: i32) callconv(.c) i32 {
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

    fn byte(self: *Escaped, value: u8) void {
        if (self.dest) |d| {
            if (self.len < self.cap) d[self.len] = value;
        }
        self.len +|= 1;
    }

    fn repeat(self: *Escaped, value: u8, count: usize) void {
        var remaining = count;
        while (remaining > 0) : (remaining -= 1) self.byte(value);
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
fn escapeArgument(arg: [*:0]const u8, dest: ?[*]u8, cap: i32) callconv(.c) i32 {
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
fn envKeyOk(key: [*]const u8, len: i32) callconv(.c) i32 {
    if (len < 0) return 0;
    var index: usize = 0;
    while (index < @as(usize, @intCast(len))) : (index += 1) {
        if (key[index] == 0 or key[index] == '=') return 0;
    }
    return 1;
}

/// Write one environment entry as `key=value` followed by a terminator. The
/// caller sizes the destination as `klen + vlen + 2`.
fn envEntryFill(
    key: [*]const u8,
    klen: i32,
    value: [*]const u8,
    vlen: i32,
    dest: [*]u8,
) callconv(.c) void {
    const k: usize = if (klen > 0) @intCast(klen) else 0;
    const v: usize = if (vlen > 0) @intCast(vlen) else 0;
    @memcpy(dest[0..k], key[0..k]);
    dest[k] = '=';
    @memcpy(dest[k + 1 ..][0..v], value[0..v]);
    dest[k + 1 + v] = 0;
}

fn processId() callconv(.c) i64 {
    if (windows) return _getpid();
    return getpid();
}

fn shell(command: ?[*:0]const u8) callconv(.c) i32 {
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
fn wait(pid: i64, value: *i32) callconv(.c) i32 {
    var status: c_int = 0;
    while (true) {
        const result = waitpid(@intCast(pid), &status, 0);
        if (result != -1) break;
        if (std.c._errno().* != @intFromEnum(std.c.E.INTR)) break;
    }

    const bits: u32 = @bitCast(status);
    if (std.c.W.IFEXITED(bits)) {
        value.* = @intCast(std.c.W.EXITSTATUS(bits));
        return wait_exited;
    }
    if (std.c.W.IFSTOPPED(bits)) {
        value.* = @intCast(@intFromEnum(std.c.W.STOPSIG(bits)));
        return wait_stopped;
    }
    if (std.c.W.IFSIGNALED(bits)) {
        value.* = @intCast(@intFromEnum(std.c.W.TERMSIG(bits)));
        return wait_signaled;
    }
    value.* = status;
    return wait_unknown;
}

/// Collect a process the collector is discarding. Unlike `wait` this does not
/// retry and does not report the status, because the C implementation it
/// replaces did neither.
fn reap(pid: i64) callconv(.c) void {
    var status: c_int = 0;
    _ = waitpid(@intCast(pid), &status, 0);
}

fn sendSignal(pid: i64, sig: i32) callconv(.c) i32 {
    return kill(@intCast(pid), sig);
}

fn makePipe(fds: *[2]c_int) callconv(.c) i32 {
    return pipe(fds);
}

fn closeDescriptor(fd: c_int) callconv(.c) i32 {
    return close(fd);
}

fn forkProcess() callconv(.c) i64 {
    while (true) {
        const result = fork();
        if (result != -1) return result;
        if (std.c._errno().* != @intFromEnum(std.c.E.INTR)) return result;
    }
}

/// Replace the current process. Returns only on failure, with `errno` set.
fn exec(
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    search_path: i32,
) callconv(.c) i32 {
    while (true) {
        const status = if (search_path != 0) execvp(path, argv) else execv(path, argv);
        if (status != -1) return status;
        if (std.c._errno().* != @intFromEnum(std.c.E.INTR)) return status;
    }
}

fn changeRoot(path: [*:0]const u8) callconv(.c) i32 {
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
