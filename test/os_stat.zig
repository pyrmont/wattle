//! Behavioral contract for the file-metadata kernels behind `os/stat` and
//! `os/lstat`: mode classification, the two permission projections, and the
//! field registry.
//!
//! ## The registry's order is an identifier, not a presentation choice
//!
//! `os_stat.fieldName(i)` and `os_stat.fieldLookup(name)` are
//! inverses, and the index they agree on is what the getters switch on. So the
//! *order* of the fifteen names is load-bearing: inserting a field in the
//! middle renumbers everything after it, and every getter then reads the wrong
//! member. Nothing in Janet can see an index — `os/stat` answers keywords — so
//! the list below is the only place that ordering is written down twice.
//!
//! ## Two permission projections, and only one of them round-trips everywhere
//!
//! `janet_os_perm_to_unix` and `janet_os_perm_from_unix` convert between the
//! host's mode bits and Janet's portable nine. On Unix they are the identity
//! and every one of the 512 values round-trips, which is asserted
//! exhaustively. On Windows the CRT collapses user, group and other into three
//! bits, so only the reduced value survives a round trip — the contract is
//! weaker there because the platform is, and saying which is the point.
//!
//! ## One preserved quirk
//!
//! `os_stat.fieldLookup` replaced a `janet_cstrcmp`, which stops at a
//! NUL shared by the key and the name. So a key whose own bytes end in NUL
//! still matches: `lookup("dev\0", 4)` is 0 rather than -1. That is deliberate
//! and is asserted below so a port cannot tidy it away.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types");
const repr = @import("repr");
const c = @import("cabi");
const harness = @import("harness.zig");
const value = @import("subsystems").value;
const config = @import("config");
const core_env = @import("subsystems").env;
const vm_lifecycle = @import("subsystems").lifecycle;

/// The kernels, by symbol; `janet.h` does not declare them.
extern fn janet_os_mode_name(mode: u32) callconv(.c) [*:0]const u8;
extern fn janet_os_decode_permissions(mode: u32) callconv(.c) i32;
extern fn janet_os_perm_to_unix(mode: u32) callconv(.c) i32;
extern fn janet_os_perm_from_unix(permissions: i32) callconv(.c) u32;
/// The field registry, by import. The three symbols this file used to declare
/// existed because the subsystem was reaching its own kernels through the
/// linker and a C contract was the only other reader.
const os_stat = @import("subsystems").stat;

/// The registry, in order. See the header comment on why the order matters.
const expected_fields = [_][]const u8{
    "dev",
    "inode",
    "mode",
    "int-permissions",
    "permissions",
    "uid",
    "gid",
    "nlink",
    "rdev",
    "size",
    "blocks",
    "blocksize",
    "accessed",
    "modified",
    "changed",
};

const work_dir = "janet-zig-os-stat-4d71";
const work_file = "janet-zig-os-stat-4d71/file";
const work_link = "janet-zig-os-stat-4d71/link";

fn modeNameIs(mode: u32, expected: []const u8) bool {
    return std.mem.eql(u8, std.mem.span(janet_os_mode_name(mode)), expected);
}

/// Janet tests the three type bits individually rather than masking with
/// `S_IFMT` first, which is why a mode with no type bits at all is "other"
/// rather than a misclassification.
///
/// Unix only, and the guard is a `comptime`-known condition so the branch is
/// not analysed on a Windows cross-compile -- `std.c.S` has no members there.
/// The C original carried a `_S_IFREG` arm for the CRT; this tree's platform
/// scope makes Windows a build target rather than a tested one, so the arm is
/// dropped rather than written and never run.
fn theModeNames() void {
    if (builtin.os.tag == .windows) return;
    const S = std.c.S;

    std.debug.assert(modeNameIs(S.IFREG | 0o644, "file"));
    std.debug.assert(modeNameIs(S.IFDIR | 0o755, "directory"));
    std.debug.assert(modeNameIs(S.IFCHR | 0o666, "character"));
    std.debug.assert(modeNameIs(0, "other"));
    std.debug.assert(modeNameIs(0o777, "other"));

    // Plan 9 has none of these four.
    if (!(builtin.os.tag == .plan9)) {
        std.debug.assert(modeNameIs(S.IFIFO | 0o644, "fifo"));
        std.debug.assert(modeNameIs(S.IFBLK | 0o644, "block"));
        std.debug.assert(modeNameIs(S.IFSOCK | 0o644, "socket"));
        std.debug.assert(modeNameIs(S.IFLNK | 0o777, "link"));
    }
}

/// Unix only, for the same reason as `theModeNames`. Windows collapses user,
/// group and other into three CRT bits, so only the reduced value round-trips
/// there and the exhaustive sweep below would be wrong rather than merely
/// unavailable.
fn thePermissionBits() void {
    if (builtin.os.tag == .windows) return;
    const S = std.c.S;

    // Type bits and the setuid/setgid/sticky field are dropped.
    std.debug.assert(janet_os_decode_permissions(S.IFREG | 0o754) == 0o754);
    std.debug.assert(janet_os_decode_permissions(S.IFDIR | 0o7777) == 0o777);
    std.debug.assert(janet_os_decode_permissions(0) == 0);

    // On Unix the two projections are the identity, and all 512 round-trip.
    var mode: i32 = 0;
    while (mode <= 0o777) : (mode += 1) {
        std.debug.assert(janet_os_perm_to_unix(@intCast(mode)) == mode);
        std.debug.assert(janet_os_perm_from_unix(mode) == @as(u32, @intCast(mode)));
        std.debug.assert(janet_os_perm_to_unix(janet_os_perm_from_unix(mode)) == mode);
    }
}

fn theFieldRegistry() void {
    const count = os_stat.fieldCount();
    std.debug.assert(count == expected_fields.len);

    for (expected_fields, 0..) |expected, index| {
        const name = os_stat.fieldName(@intCast(index)).?;
        const actual = std.mem.span(name);
        std.debug.assert(std.mem.eql(u8, actual, expected));
        // The inverse agrees, which is what makes the index an identifier.
        std.debug.assert(os_stat.fieldLookup(actual.ptr, @intCast(actual.len)) == index);
    }

    // Out of range reports absence rather than reading past the table.
    std.debug.assert(os_stat.fieldName(-1) == null);
    std.debug.assert(os_stat.fieldName(count) == null);

    // Whole names only: no prefix, no extension, no empty key, no negative
    // length, and no case folding.
    std.debug.assert(os_stat.fieldLookup("de", 2) == -1);
    std.debug.assert(os_stat.fieldLookup("device", 6) == -1);
    std.debug.assert(os_stat.fieldLookup("", 0) == -1);
    std.debug.assert(os_stat.fieldLookup("dev", -1) == -1);
    std.debug.assert(os_stat.fieldLookup("Dev", 3) == -1);
    std.debug.assert(os_stat.fieldLookup("int-permission", 14) == -1);

    // The preserved `janet_cstrcmp` quirk; see the header comment.
    std.debug.assert(os_stat.fieldLookup("dev\x00", 4) == 0);
}

// -------------------------------------------------------- the Janet surface

var environment: *types.JanetTable = undefined;

fn eval(source: [*:0]const u8) void {
    var result: repr.Value = undefined;
    std.debug.assert(core_env.dostring(environment, source, "os-stat-contract", &result) == 0);
}

/// Written in Janet because every assertion here is about a *keyword-keyed
/// table*, which Janet states in a line and Zig states in five unwraps.
fn theCoreFunctions() void {
    eval(
        \\(os/mkdir "janet-zig-os-stat-4d71")
        \\(spit "janet-zig-os-stat-4d71/file" "0123456789")
        \\(os/chmod "janet-zig-os-stat-4d71/file" 8r640)
    );

    // A whole-table result carries every registry field, under the registry's
    // own names -- which is the Janet-visible half of `theFieldRegistry`.
    eval(
        \\(def st (os/stat "janet-zig-os-stat-4d71/file"))
        \\(assert (table? st))
        \\(assert (= 15 (length st)))
        \\(each key [:dev :inode :mode :int-permissions :permissions :uid :gid
        \\           :nlink :rdev :size :blocks :blocksize :accessed :modified :changed]
        \\  (assert (not= nil (st key))))
    );

    eval(
        \\(def st (os/stat "janet-zig-os-stat-4d71/file"))
        \\(assert (= :file (st :mode)))
        \\(assert (= 10 (st :size)))
        \\(assert (= :directory (get (os/stat "janet-zig-os-stat-4d71") :mode)))
    );

    // Unix only: the CRT has three permission bits rather than nine.
    if (builtin.os.tag != .windows) eval(
        \\(def st (os/stat "janet-zig-os-stat-4d71/file"))
        \\(assert (= 8r640 (st :int-permissions)))
        \\(assert (= "rw-r-----" (st :permissions)))
    );

    // A keyword selects one field rather than building the table.
    eval(
        \\(assert (= :file (os/stat "janet-zig-os-stat-4d71/file" :mode)))
        \\(assert (= 10 (os/stat "janet-zig-os-stat-4d71/file" :size)))
        \\(assert (= :directory (os/stat "janet-zig-os-stat-4d71" :mode)))
    );

    // A supplied table is filled and returned -- the same table, with its
    // existing entry intact, which is why the length is sixteen.
    eval(
        \\(def tab @{:seed true})
        \\(assert (= tab (os/stat "janet-zig-os-stat-4d71/file" tab)))
        \\(assert (= 16 (length tab)))
        \\(assert (= :file (tab :mode)))
    );

    // A missing path is nil rather than an error, which distinguishes "no such
    // file" from "the call failed".
    eval("(assert (nil? (os/stat \"janet-zig-os-stat-4d71/missing\")))");

    if (config.symlinks) {
        // `os/lstat` reports the link, `os/stat` its target.
        eval(
            \\(os/symlink "file" "janet-zig-os-stat-4d71/link")
            \\(assert (= :link (os/lstat "janet-zig-os-stat-4d71/link" :mode)))
            \\(assert (= :file (os/stat "janet-zig-os-stat-4d71/link" :mode)))
            \\(assert (= 10 (os/stat "janet-zig-os-stat-4d71/link" :size)))
        );
    }
}

/// An unknown field keyword raises rather than answering nil, and a prefix of
/// a real one is still unknown. The C contract reached these through `protect`
/// inside a Janet string; here they are values.
fn theRefusals() void {
    const stat = harness.core("os/stat");
    var args: [2]repr.Value = undefined;

    args[0] = value.fromBytes(work_file, .string);
    args[1] = value.fromBytes("nope", .keyword);
    std.debug.assert(harness.raised(stat, .{args[0..2]}) != null);

    // `:de` is a prefix of `:dev`, and the lookup matches whole names.
    args[1] = value.fromBytes("de", .keyword);
    std.debug.assert(harness.raised(stat, .{args[0..2]}) != null);
}

/// Cleaned before as well as after: a previous run that aborted mid-way leaves
/// the fixture behind, and every assertion after that fails for the wrong
/// reason. `os_fs`'s kernels are used rather than libc's because they are
/// already exported and compiled under exactly the same condition this
/// contract is.
extern fn janet_os_remove(path: [*:0]const u8) callconv(.c) i32;
extern fn janet_os_rmdir(path: [*:0]const u8) callconv(.c) i32;

fn cleanPaths() void {
    _ = janet_os_remove(work_link);
    _ = janet_os_remove(work_file);
    _ = janet_os_rmdir(work_dir);
}

pub fn run() void {
    theModeNames();
    thePermissionBits();
    theFieldRegistry();

    cleanPaths();
    harness.init();
    environment = harness.coreEnv();
    theCoreFunctions();
    theRefusals();
    vm_lifecycle.deinit();
    cleanPaths();
}
