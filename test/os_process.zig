//! Behavioral contract for the process-control kernels and the host calls
//! behind Janet's process functions.
//!
//! ## What only the kernels can be asked
//!
//! Three of the four sections below have no spelling in Janet at all.
//! Command-line escaping has no caller outside Windows, the signal lookup
//! reports a *position* that `os/proc-kill` turns into a number and then into
//! a panic, and the wait classification is collapsed into a single integer
//! before Janet sees it. The public section then pins what a caller does see,
//! including the misspelled signal keyword `FOUND.md` records.
//!
//! ## How the subjects are reached
//!
//! **Nothing here reaches a symbol.** Fourteen `janet_os_*` kernels were
//! hand-declared once, because none of them is in a header; they were exported
//! for a C caller that no longer exists, and the subsystem was declaring the
//! same fourteen back as `extern fn` to call its own kernels.
//!
//! **The four wait codes are named rather than restated.** A third copy of a
//! number two files already agree on is a place they can drift;
//! `os_process.wait_exited` and its three siblings are the subject's own, so a
//! renumbering fails to compile here instead of passing against a stale
//! literal.
//!
//! ## Some of this is asserted twice, deliberately
//!
//! `os/process.zig` carries `test` blocks over the escaping, the signal lookup
//! and the environment rule, and `zig build test` runs them. They are not the
//! same instrument: a mutation sweep scores *contracts*, so a mutation in
//! `escapeArgument` is caught by this file and not by that one. The unit tests
//! are kept where they are and this file does not shrink to avoid them.

const std = @import("std");
const builtin = @import("builtin");
const harness = @import("harness.zig");

const subsystems = @import("subsystems");
const vm_lifecycle = @import("subsystems").lifecycle;
const os_process = subsystems.process;

const expect = @import("expect.zig").expect;

const windows = builtin.os.tag == .windows;

/// The host calls a contract needs and a subsystem does not: a child that
/// exits without flushing, a child that stops until it is signalled, and the
/// two ends of a pipe.
const posix = struct {
    extern fn write(fd: c_int, buffer: [*]const u8, count: usize) callconv(.c) isize;
    extern fn read(fd: c_int, buffer: [*]u8, count: usize) callconv(.c) isize;
    extern fn raise(sig: c_int) callconv(.c) c_int;

    /// `std.c.SIG` is an enum on some targets and a plain integer on others,
    /// so a signal number is narrowed once here rather than at each site.
    fn signal(number: anytype) c_int {
        return switch (@typeInfo(@TypeOf(number))) {
            .@"enum" => @intCast(@intFromEnum(number)),
            else => @intCast(number),
        };
    }
    extern fn pause() callconv(.c) c_int;
    extern fn _exit(status: c_int) callconv(.c) noreturn;
};

// ==========================================================================
// Command-line escaping
// ==========================================================================

/// Escaping is measured with nowhere to write, then filled into exactly the
/// space it asked for. Both passes must agree, and neither may touch a byte
/// past the reported length -- which is why the destination is poisoned first
/// and the byte after the result is checked.
fn expectEscape(argument: [*:0]const u8, expected: []const u8) void {
    var buffer: [64]u8 = undefined;
    const needed = os_process.escapeArgument(argument, null, 0);
    expect(needed == @as(i32, @intCast(expected.len)));
    expect(needed < @as(i32, @intCast(buffer.len)));

    @memset(&buffer, '#');
    expect(os_process.escapeArgument(argument, &buffer, needed) == needed);
    expect(std.mem.eql(u8, buffer[0..@intCast(needed)], expected));
    expect(buffer[@intCast(needed)] == '#');
}

fn theExecEscaping() void {
    // An argument the splitter would keep whole is passed through.
    expectEscape("simple", "simple");
    expectEscape("", "");
    expectEscape("a\\b\\c", "a\\b\\c");
    expectEscape("trailing\\\\", "trailing\\\\");

    // Each byte the splitter treats as a separator forces quoting.
    expectEscape("two words", "\"two words\"");
    expectEscape("tab\there", "\"tab\there\"");
    expectEscape("line\nbreak", "\"line\nbreak\"");
    expectEscape("vertical\x0btab", "\"vertical\x0btab\"");

    // A quotation mark is escaped, and so is every backslash before it.
    expectEscape("a\"b", "\"a\\\"b\"");
    expectEscape("\"", "\"\\\"\"");
    expectEscape("a\\\\\"b", "\"a\\\\\\\\\\\"b\"");

    // Backslashes elsewhere in a quoted argument stand for themselves.
    expectEscape("a\\\\b c", "\"a\\\\b c\"");

    // A run at the end meets the closing mark, so it doubles as well.
    expectEscape("end \\\\", "\"end \\\\\\\\\"");

    // Writing is refused when the caller offers less room than it asked for,
    // but the length is still reported.
    var small: [4]u8 = undefined;
    @memset(&small, '#');
    expect(os_process.escapeArgument("two words", &small, 0) == 11);
    expect(small[0] == '#');
}

// ==========================================================================
// The environment entry rule
// ==========================================================================

fn theEnvEntries() void {
    // A key holding a separator or a terminator would be read back as a
    // different name, so it is refused.
    expect(os_process.envKeyOk("PATH", 4) == 1);
    expect(os_process.envKeyOk("", 0) == 1);
    expect(os_process.envKeyOk("A=B", 3) == 0);
    expect(os_process.envKeyOk("A\x00B", 3) == 0);

    // Only the reported length is examined, so a separator past it is unseen.
    expect(os_process.envKeyOk("A=B", 1) == 1);

    var entry: [16]u8 = undefined;
    @memset(&entry, '#');
    os_process.envEntryFill("K", 1, "V", 1, &entry);
    expect(std.mem.eql(u8, entry[0..4], "K=V\x00"));
    expect(entry[4] == '#');

    os_process.envEntryFill("K", 1, "", 0, &entry);
    expect(std.mem.eql(u8, entry[0..3], "K=\x00"));

    // A value may hold anything the key may not.
    os_process.envEntryFill("K", 1, "a=b", 3, &entry);
    expect(std.mem.eql(u8, entry[0..6], "K=a=b\x00"));
}

// ==========================================================================
// The signal name table
// ==========================================================================

fn theSignalLookup() void {
    expect(os_process.signalIndex("kill", 4) == 0);
    expect(os_process.signalIndex("int", 3) == 1);
    expect(os_process.signalIndex("segv", 4) == 5);
    expect(os_process.signalIndex("xfsz", 4) == 27);

    // Only whole names match.
    expect(os_process.signalIndex("kil", 3) == -1);
    expect(os_process.signalIndex("killer", 6) == -1);
    expect(os_process.signalIndex("", 0) == -1);
    expect(os_process.signalIndex("nosuch", 6) == -1);

    // A key whose own bytes end in a terminator matches the shorter name,
    // which is what `janet_cstrcmp` did here.
    expect(os_process.signalIndex("int\x00x", 5) == 1);

    // The table misspells the name SIGVTALRM would give, so the documented
    // spelling is the one that fails. See `FOUND.md`.
    expect(os_process.signalIndex("vtlarm", 6) == 25);
    expect(os_process.signalIndex("vtalrm", 6) == -1);
}

// ==========================================================================
// The host calls
// ==========================================================================

fn theHostOperations() void {
    expect(os_process.processId() > 0);
    expect(os_process.shell("exit 0") == 0);
    expect(os_process.shell("exit 5") != 0);

    // A pipe carries bytes from its write end to its read end.
    var fds: [2]c_int = undefined;
    var byte: [1]u8 = .{0};
    expect(os_process.makePipe(&fds) == 0);
    expect(posix.write(fds[1], "x", 1) == 1);
    expect(posix.read(fds[0], &byte, 1) == 1);
    expect(byte[0] == 'x');
    expect(os_process.closeDescriptor(fds[0]) == 0);
    expect(os_process.closeDescriptor(fds[1]) == 0);

    // An ordinary exit is classified by its code.
    var value: i32 = -1;
    var pid = os_process.forkProcess();
    expect(pid >= 0);
    if (pid == 0) posix._exit(3);
    expect(os_process.wait(pid, &value) == os_process.wait_exited);
    expect(value == 3);

    // A process that ends on a signal is classified by that signal, without
    // the offset the caller adds.
    value = -1;
    pid = os_process.forkProcess();
    expect(pid >= 0);
    if (pid == 0) {
        _ = posix.raise(posix.signal(std.c.SIG.TERM));
        posix._exit(0);
    }
    expect(os_process.wait(pid, &value) == os_process.wait_signaled);
    expect(value == posix.signal(std.c.SIG.TERM));

    // The same holds for a signal sent from outside.
    value = -1;
    pid = os_process.forkProcess();
    expect(pid >= 0);
    if (pid == 0) {
        _ = posix.pause();
        posix._exit(0);
    }
    expect(os_process.sendSignal(pid, posix.signal(std.c.SIG.KILL)) == 0);
    expect(os_process.wait(pid, &value) == os_process.wait_signaled);
    expect(value == posix.signal(std.c.SIG.KILL));

    // Collecting a process reports nothing, and a later wait on it finds
    // nothing to report. The untouched status word then classifies as a zero
    // exit, which is what the C implementation did by ignoring `waitpid`'s
    // result.
    pid = os_process.forkProcess();
    expect(pid >= 0);
    if (pid == 0) posix._exit(9);
    os_process.reap(pid);
    value = -1;
    expect(os_process.wait(pid, &value) == os_process.wait_exited);
    expect(value == 0);

    // Replacing a process by absolute path, and by a name found on the path.
    value = -1;
    pid = os_process.forkProcess();
    expect(pid >= 0);
    if (pid == 0) {
        const args = [_:null]?[*:0]const u8{ "/bin/sh", "-c", "exit 5" };
        _ = os_process.exec("/bin/sh", &args, 0);
        posix._exit(70);
    }
    expect(os_process.wait(pid, &value) == os_process.wait_exited);
    expect(value == 5);

    value = -1;
    pid = os_process.forkProcess();
    expect(pid >= 0);
    if (pid == 0) {
        const args = [_:null]?[*:0]const u8{ "sh", "-c", "exit 6" };
        _ = os_process.exec("sh", &args, 1);
        posix._exit(70);
    }
    expect(os_process.wait(pid, &value) == os_process.wait_exited);
    expect(value == 6);

    // A failed replacement returns instead of ending the process.
    value = -1;
    pid = os_process.forkProcess();
    expect(pid >= 0);
    if (pid == 0) {
        const absent = "/janet-zig-os-process-absent-4f81";
        const args = [_:null]?[*:0]const u8{absent};
        posix._exit(if (os_process.exec(absent, &args, 0) == -1) 71 else 72);
    }
    expect(os_process.wait(pid, &value) == os_process.wait_exited);
    expect(value == 71);
}

// ==========================================================================
// What a Janet caller sees
// ==========================================================================

fn theCoreFunctions() void {
    const env = harness.coreEnv();

    // An exit code reaches the caller unchanged, whether the program is named
    // by path or found on it.
    harness.inFiber(env,
        \\(assert (= 0 (os/execute ["/bin/sh" "-c" "exit 0"])))
        \\(assert (= 7 (os/execute ["/bin/sh" "-c" "exit 7"])))
        \\(assert (= 3 (os/execute ["sh" "-c" "exit 3"] :p)))
    );

    // The `:x` flag turns a non-zero code into an error -- but only where the
    // event loop is compiled in. The flag is read in the wait callback, which
    // does not exist otherwise, so a build without the event loop accepts the
    // flag and ignores it. That is recorded in `FOUND.md` and left unfixed, so
    // the contract pins each configuration as it stands.
    harness.inFiber(env,
        \\(assert (= 0 (os/execute ["/bin/sh" "-c" "exit 0"] :x)))
    );
    if (harness.has_ev) {
        harness.inFiber(env,
            \\(assert (not (first (protect (os/execute ["/bin/sh" "-c" "exit 1"] :x)))))
        );
    } else {
        harness.inFiber(env,
            \\(assert (= 1 (os/execute ["/bin/sh" "-c" "exit 1"] :x)))
        );
    }

    // A supplied environment reaches the child, and a key holding a separator
    // is dropped rather than passed as a different name.
    harness.inFiber(env,
        \\(assert (= 0 (os/execute ["/bin/sh" "-c" "[ \"$FOO\" = bar ]"] :e {"FOO" "bar"})))
        \\(assert (= 0 (os/execute ["/bin/sh" "-c" "[ -z \"$A\" ]"] :e {"A=B" "C" "FOO" "bar"})))
    );

    // A process ended by a signal reports that signal offset by 128.
    harness.inFiber(env,
        \\(def p (os/spawn ["/bin/sh" "-c" "sleep 10"]))
        \\(assert (= 143 (os/proc-kill p true :term)))
    );

    // Signal keywords are looked up whole, and the table's misspelling of
    // SIGVTALRM is the spelling that resolves. See `FOUND.md`.
    harness.inFiber(env,
        \\(def p (os/spawn ["/bin/sh" "-c" "sleep 10"]))
        \\(assert (not (first (protect (os/proc-kill p false :vtalrm)))))
        \\(assert (not (first (protect (os/proc-kill p false :kil)))))
        \\(os/proc-kill p false :vtlarm)
        \\(assert (>= (os/proc-wait p) 129))
    );

    // Waiting twice on the same process is an error.
    harness.inFiber(env,
        \\(def p (os/spawn ["/bin/sh" "-c" "exit 4"]))
        \\(assert (= 4 (os/proc-wait p)))
        \\(assert (not (first (protect (os/proc-wait p)))))
    );

    // The remaining process functions report the host directly.
    //
    // `os/shell` is called without a command, which is the only form that
    // survives: passing one aborts the process under the event loop, because
    // the subroutine frees the copied command and the default callback frees
    // it again. That is recorded in `FOUND.md` and left unfixed, so the
    // contract cannot exercise it.
    harness.inFiber(env,
        \\(assert (> (os/getpid) 0))
        \\(assert (boolean? (os/shell)))
    );
}

pub fn run() void {
    theExecEscaping();
    theEnvEntries();

    if (!windows) {
        theSignalLookup();
        theHostOperations();

        harness.init();
        theCoreFunctions();
        vm_lifecycle.deinit();
    }

    std.debug.print("os_process contract ok\n", .{});
}
