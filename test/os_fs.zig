//! Behavioral contract for the basic filesystem kernels: `getcwd`, `mkdir`,
//! `rmdir`, `chdir`, `remove` and `rename`, and the `os/` functions over them.
//!
//! Two things here are not reachable from Janet. The kernels answer a status
//! and set `errno`, where the Janet functions answer a boolean or raise — so
//! the distinction between "the directory already existed" and "the call
//! failed" exists only below the Janet surface. And `os/mkdir` answers *false*
//! for an existing directory rather than raising, which is a return value a
//! suite would have to know to look for.
//!
//! ## The fixture is a real directory, and it is cleaned twice
//!
//! Once before the run and once after. Before, because a previous run that
//! aborted mid-way leaves the tree behind and every assertion after that fails
//! for the wrong reason -- one suite's leftover file once made fifty-seven
//! mutants look caught. After, because `tools/testing/matrix.janet` runs
//! entries concurrently in the repository working directory.
//!
//! The names carry a random-looking suffix for the same reason: two matrix
//! entries share a working directory, and a fixture named `test-dir` would
//! have them deleting each other's.

const std = @import("std");
const repr = @import("repr");
const c = @import("cabi");
const harness = @import("harness.zig");
const value = @import("subsystems").value;
const wrap = @import("subsystems").value.wrap;
const vm_lifecycle = @import("subsystems").lifecycle;
const fs = @import("subsystems").fs;
const expect = @import("expect.zig").expect;

const direct_dir = "janet-zig-os-fs-direct-83c2";
const direct_source = "janet-zig-os-fs-direct-83c2/source";
const direct_dest = "janet-zig-os-fs-direct-83c2/dest";
const public_dir = "janet-zig-os-fs-public-91af";
const public_source = "janet-zig-os-fs-public-91af/source";
const public_dest = "janet-zig-os-fs-public-91af/dest";

const path_max = 4096;

/// The working directory as a NUL-terminated slice. Sentinel-terminated
/// rather than plain, because every kernel below takes a C string and a plain
/// slice would need re-terminating at each call.
fn cwd(buffer: *[path_max]u8) [:0]const u8 {
    expect(fs.hostGetcwd(buffer, path_max) == 0);
    return std.mem.span(@as([*:0]const u8, @ptrCast(buffer)));
}

/// A file with known contents, written through libc so that nothing under test
/// is used to build the fixture for the things under test.
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
    // True the first time, false the second -- not a raise.
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

/// What the Janet surface refuses, which the C contract did not ask. Each is a
/// call the kernel below would have failed at; the point is that the failure
/// arrives as a raise rather than as a silent false.
fn theRefusals() void {
    const cd = harness.core("os/cd");
    const rmdir = harness.core("os/rmdir");
    const remove = harness.core("os/rm");
    var args: [1]repr.Value = undefined;

    args[0] = value.fromBytes("janet-zig-os-fs-absent-0000", .string);
    expect(harness.raised(cd, .{args[0..1]}) != null);
    expect(harness.raised(rmdir, .{args[0..1]}) != null);
    expect(harness.raised(remove, .{args[0..1]}) != null);

    // A number is not a path, and the refusal comes from the argument layer.
    args[0] = harness.wrapInteger(7);
    expect(harness.raised(cd, .{args[0..1]}) != null);
}

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
