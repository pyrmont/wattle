//! Behavioral contract for platform classification and CPU discovery: the
//! strings behind `os/which`, `os/arch` and `os/compiler`, and the count
//! behind `os/cpu-count`.
//!
//! ## Where the expectations come from
//!
//! `os_platform.zig` derives its results from `builtin`, so asserting them
//! against `builtin` again would prove nothing. A preprocessor's view is not
//! the second opinion either: a macro derived from a compiler's own predefines
//! is unreliable through `@cImport`, since Aro predefines `__unix__` for
//! `x86_64-windows-gnu`, so a header's *translation* can say POSIX where its
//! *compilation* says Windows. The standing rule is to test the platform with
//! `builtin.os.tag`.
//!
//! Two oracles are used instead.
//!
//! `uname` describes the machine the binary is executing on rather than any
//! compiler's belief about the target, so it catches the failure that matters,
//! a build that thinks it is Linux while running on macOS, and it stays
//! correct under Rosetta, where an `x86_64-macos` binary genuinely is an
//! x86_64 process. It is consulted only for the cases it can speak to and the
//! rest are skipped rather than faked.
//!
//! The kernel and the Janet surface are cross-checked against each other,
//! which needs no oracle at all: whatever `os.osName` returns, `os/which` must
//! give the keyword form of it, and `os/which` given that keyword must be
//! true.
//!
//! ## `os/which` has three behaviours under one name
//!
//! With no argument it gives the platform keyword; with a keyword it reports
//! whether that is the platform; with `nil` it gives the platform keyword
//! again rather than testing `nil`. The third is the one a reader would not
//! guess and the one a port drops.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");
const builtin = @import("builtin");

// ==========================================================================
// Project imports
// ==========================================================================

const args_core = @import("subsystems").args;
const config = @import("config");
const expect = @import("expect.zig").expect;
const harness = @import("harness.zig");
const os = @import("subsystems").os;
const repr = @import("repr");
const value = @import("subsystems").value;
const vm_lifecycle = @import("subsystems").lifecycle;
const wrap = @import("subsystems").value.wrap;

// ==========================================================================
// Cases
// ==========================================================================

fn cstr(pointer: [*:0]const u8) []const u8 {
    return std.mem.span(pointer);
}

/// What the running kernel calls itself, or null where `uname` is not
/// available or not informative.
fn unameSysname(buffer: *std.c.utsname) ?[]const u8 {
    if (builtin.os.tag == .windows) return null;
    if (std.c.uname(buffer) != 0) return null;
    return std.mem.sliceTo(&buffer.sysname, 0);
}

fn unameMachine(buffer: *std.c.utsname) ?[]const u8 {
    if (builtin.os.tag == .windows) return null;
    if (std.c.uname(buffer) != 0) return null;
    return std.mem.sliceTo(&buffer.machine, 0);
}

/// `uname` names an OS differently from Janet, and only the mappings this
/// project actually runs are written down. An unrecognised sysname skips the
/// assertion rather than failing it: the point is to catch a build that is
/// wrong about the machine under it, not to enumerate every Unix.
fn osNameForSysname(sysname: []const u8) ?[]const u8 {
    const table = [_]struct { []const u8, []const u8 }{
        .{ "Darwin", "macos" },
        .{ "Linux", "linux" },
        .{ "FreeBSD", "freebsd" },
        .{ "NetBSD", "netbsd" },
        .{ "OpenBSD", "openbsd" },
        .{ "DragonFly", "dragonfly" },
        .{ "GNU", "hurd" },
    };
    for (table) |row| {
        if (std.mem.eql(u8, sysname, row[0])) return row[1];
    }
    return null;
}

fn archForMachine(machine: []const u8) ?[]const u8 {
    const table = [_]struct { []const u8, []const u8 }{
        .{ "arm64", "aarch64" },
        .{ "aarch64", "aarch64" },
        .{ "x86_64", "x64" },
        .{ "amd64", "x64" },
        .{ "i386", "x86" },
        .{ "i686", "x86" },
        .{ "riscv64", "riscv64" },
        .{ "s390x", "s390x" },
    };
    for (table) |row| {
        if (std.mem.eql(u8, machine, row[0])) return row[1];
    }
    return null;
}

/// Every classification is a non-empty string. Trivial, and it is the
/// assertion that fails if a table gained an entry with no name.
fn theClassificationsAreNamed() void {
    expect(cstr(os.osName()).len > 0);
    expect(cstr(os.osArch()).len > 0);
    expect(cstr(os.osCompiler()).len > 0);
}

/// The classification against the running machine. Skipped wherever `uname`
/// cannot speak, and skipped entirely when the build overrode the name.
fn theClassificationAgreesWithTheMachine() void {
    var buffer: std.c.utsname = undefined;

    // `-Dos-name` may pin the name, in which case the kernel is reporting the
    // build's choice rather than describing the machine and there is nothing
    // here to check.
    if (config.os_name == null) {
        if (unameSysname(&buffer)) |sysname| {
            if (osNameForSysname(sysname)) |expected| {
                expect(std.mem.eql(u8, cstr(os.osName()), expected));
            }
        }
    }

    if (config.arch_name == null) {
        if (unameMachine(&buffer)) |machine| {
            if (archForMachine(machine)) |expected| {
                expect(std.mem.eql(u8, cstr(os.osArch()), expected));
            }
        }
    }

    // Every build is compiled by Zig, whatever the target.
    expect(std.mem.eql(u8, cstr(os.osCompiler()), "zig"));
}

/// The Janet-visible functions give the keyword form of the kernels'
/// strings. This needs no oracle: it is the two descriptions inside the
/// runtime agreeing with one another.
fn theSurfaceAgreesWithTheKernels() !void {
    const which = harness.core("os/which");
    const arch = harness.core("os/arch");
    const compiler = harness.core("os/compiler");

    expect(harness.keywordIs(try which(&.{}), os.osName()));
    expect(harness.keywordIs(try arch(&.{}), os.osArch()));
    expect(harness.keywordIs(try compiler(&.{}), os.osCompiler()));
}

/// `os/which`'s three behaviours; see the header comment.
fn theThreeReadingsOfWhich() !void {
    const which = harness.core("os/which");
    var argument: [1]repr.Value = undefined;

    argument[0] = value.fromBytes(std.mem.span(os.osName()), .keyword);
    expect(wrap.toBoolean(try which(argument[0..1])));

    argument[0] = value.fromBytes("not-a-platform", .keyword);
    expect(!wrap.toBoolean(try which(argument[0..1])));

    // `nil` is not a platform to test against; it is the same as no argument.
    argument[0] = wrap.fromNil();
    expect(harness.keywordIs(try which(argument[0..1]), os.osName()));
}

/// `os/cpu-count` gives the kernel's number, or the caller's fallback when
/// the kernel has none. The fallback is the branch a suite cannot reach, since
/// it only arises on a platform where the count is unavailable.
fn theCpuCount() !void {
    // Absent from a reduced-OS build, where `os.c` never registered it. Asked
    // of the environment rather than read out of `options`, because what is
    // missing is a registration and no `Selection` field names it.
    const cpuCount = harness.coreOptional("os/cpu-count") orelse return;
    const direct = os.osCpuCount();
    var fallback = [1]repr.Value{value.fromBytes("fallback", .keyword)};

    const answered = try cpuCount(fallback[0..1]);
    if (direct < 0) {
        expect(harness.equals(answered, fallback[0]));
        // With no fallback to give, the result is nil rather than an error.
        expect(harness.isType(try cpuCount(&.{}), repr.Tag.nil));
    } else {
        expect(args_core.checkint(answered));
        expect(wrap.toInteger(answered) == direct);
        // The fallback is not consulted when there is a real count.
        expect(wrap.toInteger(try cpuCount(&.{})) == direct);
    }
}

// ==========================================================================
// Entry
// ==========================================================================

pub fn run() void {
    theClassificationsAreNamed();
    theClassificationAgreesWithTheMachine();

    harness.init();
    theSurfaceAgreesWithTheKernels() catch @panic("os_platform: a core function raised");
    theThreeReadingsOfWhich() catch @panic("os_platform: os/which raised");
    theCpuCount() catch @panic("os_platform: os/cpu-count raised");
    vm_lifecycle.deinit();
}
