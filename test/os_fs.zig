//! Behavioral contract for the basic filesystem kernels: `getcwd`, `mkdir`,
//! `rmdir`, `chdir`, `remove` and `rename`, and the `os/` functions over them.
//!
//! Two things here are not reachable from Janet. The kernels return a status
//! and set `errno`, where the Janet functions give a boolean or raise, so
//! the distinction between "the directory already existed" and "the call
//! failed" exists only below the Janet surface. And `os/mkdir` gives *false*
//! for an existing directory rather than raising, which is a return value a
//! suite would have to be written to look for.
//!
//! ## The fixture is a real directory, and it is cleaned twice
//!
//! Once before the run and once after. Before, because a previous run that
//! aborted mid-way leaves the tree behind and every assertion after that fails
//! for the wrong reason, so one suite's leftover file cannot make fifty-seven
//! mutants look caught. After, because `res/testing/matrix.janet` runs
//! entries concurrently in the repository working directory.
//!
//! The names have a random-looking suffix for the same reason: two matrix
//! entries share a working directory, and a fixture named `test-dir` would
//! have them deleting each other's.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const c = @import("cabi");
const expect = @import("expect.zig").expect;
const fs = @import("subsystems").fs;
const harness = @import("harness.zig");
const repr = @import("repr");
const value = @import("subsystems").value;
const vm_lifecycle = @import("subsystems").lifecycle;
const wrap = @import("subsystems").value.wrap;

// ==========================================================================
// Constants
// ==========================================================================

const direct_dest = "wattle-os-fs-direct-83c2/dest";
const direct_dir = "wattle-os-fs-direct-83c2";
const direct_source = "wattle-os-fs-direct-83c2/source";
const path_max = 4096;
const public_dest = "wattle-os-fs-public-91af/dest";
const public_dir = "wattle-os-fs-public-91af";
const public_source = "wattle-os-fs-public-91af/source";

// ==========================================================================
// Cases
// ==========================================================================

/// The working directory as a NUL-terminated slice. Sentinel-terminated
/// rather than plain, because every kernel below takes a C string and a plain
/// slice would need re-terminating at each call.
fn cwd(buffer: *[path_max]u8) [:0]const u8 {
    expect(fs.hostGetcwd(buffer, path_max) == 0);
    return std.mem.span(@as([*:0]const u8, @ptrCast(buffer)));
}

/// A file with fixed contents, written through libc so that nothing under test
/// builds the fixture for the things under test.
fn makeFile(path: [*:0]const u8) void {
    const file = c.fopen(path, "wb");
    expect(file != null);
    expect(c.fputs("filesystem-contract", file) >= 0);
    expect(c.fclose(file) == 0);
}

/// Best-effort: every one of these may legitimately fail because the path is
/// already absent, which is the state this is trying to reach.
fn cleanPaths() void {
    _ = fs.hostRemove(direct_source);
    _ = fs.hostRemove(direct_dest);
    _ = fs.hostRmdir(direct_dir);
    _ = fs.hostRemove(public_source);
    _ = fs.hostRemove(public_dest);
    _ = fs.hostRmdir(public_dir);
}

fn theKernels(original: [:0]const u8) void {
    expect(fs.hostMkdir(direct_dir) == 0);

    // The second `mkdir` fails and says why. This is the distinction the Janet
    // surface flattens into `false`.
    //
    // `errno` is a macro over a per-thread location, so it does not survive
    // translation as a variable; `std._errno` is the accessor Zig provides
    // for the same location.
    std.c._errno().* = 0;
    expect(fs.hostMkdir(direct_dir) == -1);
    expect(std.c._errno().* == @intFromEnum(std.c.E.EXIST));

    // `chdir` moves, `getcwd` reports where.
    var inside: [path_max]u8 = undefined;
    expect(fs.hostChdir(direct_dir) == 0);
    expect(!std.mem.eql(u8, cwd(&inside), original));
    makeFile("source");

    var back: [path_max]u8 = undefined;
    expect(fs.hostChdir(original.ptr) == 0);
    expect(std.mem.eql(u8, cwd(&back), original));

    expect(fs.hostRename(direct_source, direct_dest) == 0);
    // Renamed rather than copied: the old name is gone.
    expect(fs.hostRemove(direct_source) == -1);
    expect(fs.hostRemove(direct_dest) == 0);
    expect(fs.hostRmdir(direct_dir) == 0);
}

fn theCoreFunctions(original: [:0]const u8) !void {
    const getcwd = harness.core("os/cwd");
    const mkdir = harness.core("os/mkdir");
    const rmdir = harness.core("os/rmdir");
    const cd = harness.core("os/cd");
    const rename = harness.core("os/rename");
    const remove = harness.core("os/rm");
    var args: [2]repr.Value = undefined;

    const here = try getcwd(&.{});
    expect(harness.isType(here, repr.Tag.string));
    expect(harness.stringIs(wrap.toString(here), original.ptr));

    args[0] = value.fromBytes(public_dir, .string);
    // True the first time, false the second, and not a raise.
    expect(wrap.toBoolean(try mkdir(args[0..1])));
    expect(!wrap.toBoolean(try mkdir(args[0..1])));

    expect(harness.isType(try cd(args[0..1]), repr.Tag.nil));
    makeFile("source");

    args[0] = value.fromBytes(original, .string);
    expect(harness.isType(try cd(args[0..1]), repr.Tag.nil));

    args[0] = value.fromBytes(public_source, .string);
    args[1] = value.fromBytes(public_dest, .string);
    expect(harness.isType(try rename(args[0..2]), repr.Tag.nil));

    args[0] = args[1];
    expect(harness.isType(try remove(args[0..1]), repr.Tag.nil));
    args[0] = value.fromBytes(public_dir, .string);
    expect(harness.isType(try rmdir(args[0..1]), repr.Tag.nil));
}

/// What the Janet surface refuses. Each is a
/// call the kernel below would have failed at; the point is that the failure
/// arrives as a raise rather than as a silent false.
fn theRefusals() void {
    const cd = harness.core("os/cd");
    const rmdir = harness.core("os/rmdir");
    const remove = harness.core("os/rm");
    var args: [1]repr.Value = undefined;

    args[0] = value.fromBytes("wattle-os-fs-absent-0000", .string);
    expect(harness.raised(cd, .{args[0..1]}) != null);
    expect(harness.raised(rmdir, .{args[0..1]}) != null);
    expect(harness.raised(remove, .{args[0..1]}) != null);

    // A number is not a path, and the refusal comes from the argument layer.
    args[0] = harness.wrapInteger(7);
    expect(harness.raised(cd, .{args[0..1]}) != null);
}

// ==========================================================================
// Entry
// ==========================================================================

pub fn run() void {
    var buffer: [path_max]u8 = undefined;
    const original = cwd(&buffer);

    cleanPaths();
    theKernels(original);

    harness.init();
    theCoreFunctions(original) catch @panic("os_fs: a core function raised");
    theRefusals();
    vm_lifecycle.deinit();

    // Back where we started, whatever the assertions above did.
    expect(fs.hostChdir(original.ptr) == 0);
    cleanPaths();
}
