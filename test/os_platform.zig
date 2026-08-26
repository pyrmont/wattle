//! Behavioral contract for platform classification and CPU discovery: the
//! strings behind `os/which`, `os/arch` and `os/compiler`, and the count
//! behind `os/cpu-count`.
//!
//! ## The oracle changed in the migration, and that is worth reading before
//! ## trusting this file
//!
//! The C contract computed its expectations from **the C preprocessor's view
//! of the target** — a seventy-line chain of `#if defined(JANET_APPLE)` and
//! its kin — and compared that with what `os_platform.zig` derives from Zig's
//! `builtin`. Two independent descriptions of the same fact, which is exactly
//! what a contract wants.
//!
//! That oracle is not available here, and not merely inconvenient:
//! `AGENTS.md`'s standing rule is **"test the platform with `builtin.os.tag`;
//! read only what the build wrote into `janetconf.h` with `@hasDecl`"**,
//! because a `JANET_*` macro derived from the compiler's own predefines is
//! unreliable through `@cImport` — Aro predefines `__unix__` for
//! `x86_64-windows-gnu`, so the *translation* of `janet.h` says `JANET_POSIX`
//! where the *compilation* of it says `JANET_WINDOWS`. A Zig contract that
//! read those macros would be checking a description known to be wrong.
//!
//! So a naive translation of this file would assert `builtin` against
//! `builtin` and prove nothing. Two things are done instead.
//!
//! **`uname` is the replacement oracle**, and on the platforms this project
//! actually runs it is a better one. It describes the machine the binary is
//! executing on rather than either compiler's belief about the target, so it
//! catches the failure that matters — a build that thinks it is Linux while
//! running on macOS — and it stays correct under Rosetta, where an
//! `x86_64-macos` binary genuinely is an x86_64 process. It is consulted only
//! for the cases it can speak to and the rest are skipped rather than faked.
//!
//! **The kernel and the Janet surface are cross-checked against each other**,
//! which the C contract also did and which needs no oracle at all: whatever
//! `janet_os_name` answers, `os/which` must answer the keyword form of it, and
//! `os/which` given that keyword must answer true.
//!
//! ## `os/which` has three behaviours under one name
//!
//! With no argument it answers the platform keyword; with a keyword it answers
//! whether that is the platform; with `nil` it answers the platform keyword
//! again rather than testing `nil`. The third is the one a reader would not
//! guess and the one a port drops.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");
const harness = @import("harness.zig");
const config = @import("config");
const value = @import("subsystems").value;
const wrap = @import("subsystems").value.wrap;
const args_core = @import("subsystems").args;
const vm_lifecycle = @import("subsystems").lifecycle;

/// The kernels, by symbol; `janet.h` does not declare them.
extern fn janet_os_name() callconv(.c) [*:0]const u8;
extern fn janet_os_arch() callconv(.c) [*:0]const u8;
extern fn janet_os_compiler() callconv(.c) [*:0]const u8;
extern fn janet_os_cpu_count() callconv(.c) i32;

fn cstr(pointer: [*:0]const u8) []const u8 {
    return std.mem.span(pointer);
}

// ------------------------------------------------------- the uname oracle

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
fn janetNameForSysname(sysname: []const u8) ?[]const u8 {
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

fn janetArchForMachine(machine: []const u8) ?[]const u8 {
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

/// The classification against the running machine. Skipped wherever `uname`
/// cannot speak, and skipped entirely when the build overrode the name.
fn theClassificationAgreesWithTheMachine() void {
    var buffer: std.c.utsname = undefined;

    // `janetconf.h` may pin either name, in which case the kernel is answering
    // the build's choice rather than describing the machine and there is
    // nothing here to check. `@hasDecl` is how `AGENTS.md` says to ask.
    if (config.os_name == null) {
        if (unameSysname(&buffer)) |sysname| {
            if (janetNameForSysname(sysname)) |expected| {
                std.debug.assert(std.mem.eql(u8, cstr(janet_os_name()), expected));
            }
        }
    }

    if (config.arch_name == null) {
        if (unameMachine(&buffer)) |machine| {
            if (janetArchForMachine(machine)) |expected| {
                std.debug.assert(std.mem.eql(u8, cstr(janet_os_arch()), expected));
            }
        }
    }

    // Nothing outside the build can say which compiler built it, so this is
    // the one classification with no independent oracle. What is left is that
    // it answers one of the names the subsystem can produce -- which would
    // catch an uninitialised or truncated string, and nothing subtler.
    const compiler = cstr(janet_os_compiler());
    std.debug.assert(std.mem.eql(u8, compiler, "clang") or
        std.mem.eql(u8, compiler, "msvc") or
        std.mem.eql(u8, compiler, "gcc") or
        std.mem.eql(u8, compiler, "kencc") or
        std.mem.eql(u8, compiler, "unknown"));
}

/// Every classification is a non-empty string. Trivial, and it is the
/// assertion that fails if a table gained an entry with no name.
fn theClassificationsAreNamed() void {
    std.debug.assert(cstr(janet_os_name()).len > 0);
    std.debug.assert(cstr(janet_os_arch()).len > 0);
    std.debug.assert(cstr(janet_os_compiler()).len > 0);
}

// ------------------------------------------------------ the Janet surface

/// The Janet-visible functions answer the keyword form of the kernels'
/// strings. This needs no oracle: it is the two descriptions inside the
/// runtime agreeing with one another.
fn theSurfaceAgreesWithTheKernels() !void {
    const which = harness.core("os/which");
    const arch = harness.core("os/arch");
    const compiler = harness.core("os/compiler");

    std.debug.assert(harness.keywordIs(try which(&.{}), janet_os_name()));
    std.debug.assert(harness.keywordIs(try arch(&.{}), janet_os_arch()));
    std.debug.assert(harness.keywordIs(try compiler(&.{}), janet_os_compiler()));
}

/// `os/which`'s three behaviours; see the header comment.
fn theThreeReadingsOfWhich() !void {
    const which = harness.core("os/which");
    var argument: [1]types.Janet = undefined;

    argument[0] = value.fromBytes(std.mem.span(janet_os_name()), .keyword);
    std.debug.assert(wrap.toBoolean(try which(argument[0..1])) != 0);

    argument[0] = value.fromBytes("not-a-platform", .keyword);
    std.debug.assert(wrap.toBoolean(try which(argument[0..1])) == 0);

    // `nil` is not a platform to test against; it is the same as no argument.
    argument[0] = wrap.fromNil();
    std.debug.assert(harness.keywordIs(try which(argument[0..1]), janet_os_name()));
}

/// `os/cpu-count` answers the kernel's number, or the caller's fallback when
/// the kernel has none. The fallback is the branch a suite cannot reach, since
/// it only arises on a platform where the count is unavailable.
fn theCpuCount() !void {
    // Absent from a reduced-OS build, where `os.c` never registered it. Asked
    // of the environment rather than read out of `options`, because what is
    // missing is a registration and no `Selection` field names it.
    const cpuCount = harness.coreOptional("os/cpu-count") orelse return;
    const direct = janet_os_cpu_count();
    var fallback = [1]types.Janet{value.fromBytes("fallback", .keyword)};

    const answered = try cpuCount(fallback[0..1]);
    if (direct < 0) {
        std.debug.assert(harness.equals(answered, fallback[0]));
        // With no fallback to give, the answer is nil rather than an error.
        std.debug.assert(harness.isType(try cpuCount(&.{}), constants.JANET_NIL));
    } else {
        std.debug.assert(args_core.checkint(answered) != 0);
        std.debug.assert(wrap.toInteger(answered) == direct);
        // The fallback is not consulted when there is a real answer.
        std.debug.assert(wrap.toInteger(try cpuCount(&.{})) == direct);
    }
}

pub fn run() void {
    theClassificationsAreNamed();
    theClassificationAgreesWithTheMachine();

    harness.init();
    theSurfaceAgreesWithTheKernels() catch @panic("os_platform: a core function raised");
    theThreeReadingsOfWhich() catch @panic("os_platform: os/which raised");
    theCpuCount() catch @panic("os_platform: os/cpu-count raised");
    vm_lifecycle.deinit();
}
