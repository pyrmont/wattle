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
//! for the wrong reason; `AGENTS.md` has the same lesson from the mutation
//! sweep, where one suite's leftover file made fifty-seven mutants look
//! caught. After, because `matrix.py` runs entries concurrently in the
//! repository working directory.
//!
//! The names carry a random-looking suffix for the same reason: two matrix
//! entries share a working directory, and a fixture named `test-dir` would
//! have them deleting each other's.

const std = @import("std");
const abi = @import("abi");
const c = abi.c;
const harness = @import("harness.zig");

/// The kernels, by symbol; `janet.h` does not declare them.
extern fn janet_os_getcwd(buffer: [*]u8, size: i32) callconv(.c) i32;
extern fn janet_os_mkdir(path: [*:0]const u8) callconv(.c) i32;
extern fn janet_os_rmdir(path: [*:0]const u8) callconv(.c) i32;
extern fn janet_os_chdir(path: [*:0]const u8) callconv(.c) i32;
extern fn janet_os_remove(path: [*:0]const u8) callconv(.c) i32;
extern fn janet_os_rename(old: [*:0]const u8, new: [*:0]const u8) callconv(.c) i32;

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
    std.debug.assert(janet_os_getcwd(buffer, path_max) == 0);
    return std.mem.span(@as([*:0]const u8, @ptrCast(buffer)));
}

/// A file with known contents, written through libc so that nothing under test
/// is used to build the fixture for the things under test.
fn makeFile(path: [*:0]const u8) void {
    const file = c.fopen(path, "wb");
    std.debug.assert(file != null);
    std.debug.assert(c.fputs("filesystem-contract", file) >= 0);
    std.debug.assert(c.fclose(file) == 0);
}

/// Best-effort: every one of these may legitimately fail because the path is
/// already absent, which is the state this is trying to reach.
fn cleanPaths() void {
    _ = janet_os_remove(direct_source);
    _ = janet_os_remove(direct_dest);
    _ = janet_os_rmdir(direct_dir);
    _ = janet_os_remove(public_source);
    _ = janet_os_remove(public_dest);
    _ = janet_os_rmdir(public_dir);
}

fn theKernels(original: [:0]const u8) void {
    std.debug.assert(janet_os_mkdir(direct_dir) == 0);

    // The second `mkdir` fails and says why. This is the distinction the Janet
    // surface flattens into `false`.
    //
    // `errno` is a macro over a per-thread location, so it does not survive
    // translation as a variable; `std.c._errno` is the accessor Zig provides
    // for the same location.
    std.c._errno().* = 0;
    std.debug.assert(janet_os_mkdir(direct_dir) == -1);
    std.debug.assert(std.c._errno().* == @intFromEnum(std.c.E.EXIST));

    // `chdir` moves, `getcwd` reports where.
    var inside: [path_max]u8 = undefined;
    std.debug.assert(janet_os_chdir(direct_dir) == 0);
    std.debug.assert(!std.mem.eql(u8, cwd(&inside), original));
    makeFile("source");

    var back: [path_max]u8 = undefined;
    std.debug.assert(janet_os_chdir(original.ptr) == 0);
    std.debug.assert(std.mem.eql(u8, cwd(&back), original));

    std.debug.assert(janet_os_rename(direct_source, direct_dest) == 0);
    // Renamed rather than copied: the old name is gone.
    std.debug.assert(janet_os_remove(direct_source) == -1);
    std.debug.assert(janet_os_remove(direct_dest) == 0);
    std.debug.assert(janet_os_rmdir(direct_dir) == 0);
}

fn theCoreFunctions(original: [:0]const u8) !void {
    const getcwd = harness.core("os/cwd");
    const mkdir = harness.core("os/mkdir");
    const rmdir = harness.core("os/rmdir");
    const cd = harness.core("os/cd");
    const rename = harness.core("os/rename");
    const remove = harness.core("os/rm");
    var args: [2]c.Janet = undefined;

    const here = try getcwd(0, null);
    std.debug.assert(harness.isType(here, c.JANET_STRING));
    std.debug.assert(harness.stringIs(c.janet_unwrap_string(here), original.ptr));

    args[0] = c.janet_cstringv(public_dir);
    // True the first time, false the second -- not a raise.
    std.debug.assert(c.janet_unwrap_boolean(try mkdir(1, &args)) != 0);
    std.debug.assert(c.janet_unwrap_boolean(try mkdir(1, &args)) == 0);

    std.debug.assert(harness.isType(try cd(1, &args), c.JANET_NIL));
    makeFile("source");

    args[0] = c.janet_cstringv(original.ptr);
    std.debug.assert(harness.isType(try cd(1, &args), c.JANET_NIL));

    args[0] = c.janet_cstringv(public_source);
    args[1] = c.janet_cstringv(public_dest);
    std.debug.assert(harness.isType(try rename(2, &args), c.JANET_NIL));

    args[0] = args[1];
    std.debug.assert(harness.isType(try remove(1, &args), c.JANET_NIL));
    args[0] = c.janet_cstringv(public_dir);
    std.debug.assert(harness.isType(try rmdir(1, &args), c.JANET_NIL));
}

/// What the Janet surface refuses, which the C contract did not ask. Each is a
/// call the kernel below would have failed at; the point is that the failure
/// arrives as a raise rather than as a silent false.
fn theRefusals() void {
    const cd = harness.core("os/cd");
    const rmdir = harness.core("os/rmdir");
    const remove = harness.core("os/rm");
    var args: [1]c.Janet = undefined;

    args[0] = c.janet_cstringv("janet-zig-os-fs-absent-0000");
    std.debug.assert(harness.raised(cd, .{ @as(i32, 1), &args }) != null);
    std.debug.assert(harness.raised(rmdir, .{ @as(i32, 1), &args }) != null);
    std.debug.assert(harness.raised(remove, .{ @as(i32, 1), &args }) != null);

    // A number is not a path, and the refusal comes from the argument layer.
    args[0] = harness.wrapInteger(7);
    std.debug.assert(harness.raised(cd, .{ @as(i32, 1), &args }) != null);
}

pub fn run() void {
    var buffer: [path_max]u8 = undefined;
    const original = cwd(&buffer);

    cleanPaths();
    theKernels(original);

    _ = c.janet_init();
    theCoreFunctions(original) catch @panic("os_fs: a core function raised");
    theRefusals();
    c.janet_deinit();

    // Back where we started, whatever the assertions above did.
    std.debug.assert(janet_os_chdir(original.ptr) == 0);
    cleanPaths();
}
