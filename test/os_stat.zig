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
//! member. Nothing in Janet can see an index, `os/stat` taking keywords, so
//! the list below is the only place that ordering is written down twice.
//!
//! ## Two permission projections, and only one of them round-trips everywhere
//!
//! `os_stat.hostPermToUnix` and `os_stat.hostPermFromUnix` convert between the
//! host's mode bits and Janet's portable nine. On Unix they are the identity
//! and every one of the 512 values round-trips, which is asserted
//! exhaustively. On Windows the CRT collapses user, group and other into three
//! bits, so only the reduced value survives a round trip, and the contract is
//! weaker there because the platform is, and saying which is the point.
//!
//! ## One preserved quirk
//!
//! `os_stat.fieldLookup` keeps `utils.cstrcmp`'s rule, which stops at a NUL
//! shared by the key and the name. So a key whose own bytes end in NUL
//! still matches: `lookup("dev\0", 4)` is 0 rather than -1. That is deliberate
//! and is asserted below so a port cannot tidy it away.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");
const builtin = @import("builtin");

// ==========================================================================
// Project imports
// ==========================================================================

const config = @import("config");
const core_env = @import("subsystems").env;
const expect = @import("expect.zig").expect;
const fs = @import("subsystems").fs;
const harness = @import("harness.zig");

/// The field registry, by import.
const os_stat = @import("subsystems").stat;
const repr = @import("repr");
const tables = @import("subsystems").value.tables;
const value = @import("subsystems").value;
const vm_lifecycle = @import("subsystems").lifecycle;

// ==========================================================================
// Constants
// ==========================================================================

var environment: *tables.Table = undefined;

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

// ==========================================================================
// Cases
// ==========================================================================

fn modeNameIs(mode: u32, expected: []const u8) bool {
    return std.mem.eql(u8, std.mem.span(os_stat.hostModeName(mode)), expected);
}

fn eval(source: [*:0]const u8) void {
    var result: repr.Value = undefined;
    expect(core_env.dostring(environment, source, "os-stat-contract", &result) == 0);
}

fn cleanPaths() void {
    _ = fs.hostRemove(work_link);
    _ = fs.hostRemove(work_file);
    _ = fs.hostRmdir(work_dir);
}

/// Janet tests the three type bits individually rather than masking with
/// `S_IFMT` first, so a mode with no type bits at all is "other"
/// rather than a misclassification.
///
/// Unix only, and the guard is a `comptime` condition so the branch is not
/// analysed on a Windows cross-compile, `std.c.S` having no members there.
/// There is no CRT arm beside it, because this tree's platform
/// scope makes Windows a build target rather than a tested one, so the arm is
/// dropped rather than written and never run.
fn theModeNames() void {
    if (builtin.os.tag == .windows) return;
    const S = std.c.S;

    expect(modeNameIs(S.IFREG | 0o644, "file"));
    expect(modeNameIs(S.IFDIR | 0o755, "directory"));
    expect(modeNameIs(S.IFCHR | 0o666, "character"));
    expect(modeNameIs(0, "other"));
    expect(modeNameIs(0o777, "other"));

    // Plan 9 has none of these four.
    if (!(builtin.os.tag == .plan9)) {
        expect(modeNameIs(S.IFIFO | 0o644, "fifo"));
        expect(modeNameIs(S.IFBLK | 0o644, "block"));
        expect(modeNameIs(S.IFSOCK | 0o644, "socket"));
        expect(modeNameIs(S.IFLNK | 0o777, "link"));
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
    expect(os_stat.hostDecodePermissions(S.IFREG | 0o754) == 0o754);
    expect(os_stat.hostDecodePermissions(S.IFDIR | 0o7777) == 0o777);
    expect(os_stat.hostDecodePermissions(0) == 0);

    // On Unix the two projections are the identity, and all 512 round-trip.
    var mode: i32 = 0;
    while (mode <= 0o777) : (mode += 1) {
        expect(os_stat.hostPermToUnix(@intCast(mode)) == mode);
        expect(os_stat.hostPermFromUnix(mode) == @as(u32, @intCast(mode)));
        expect(os_stat.hostPermToUnix(os_stat.hostPermFromUnix(mode)) == mode);
    }
}

fn theFieldRegistry() void {
    const count = os_stat.fieldCount();
    expect(count == expected_fields.len);

    for (expected_fields, 0..) |expected, index| {
        const name = os_stat.fieldName(@intCast(index)).?;
        const actual = std.mem.span(name);
        expect(std.mem.eql(u8, actual, expected));
        // The inverse agrees, which is what makes the index an identifier.
        expect(os_stat.fieldLookup(actual.ptr, @intCast(actual.len)) == index);
    }

    // Out of range reports absence rather than reading past the table.
    expect(os_stat.fieldName(-1) == null);
    expect(os_stat.fieldName(count) == null);

    // Whole names only: no prefix, no extension, no empty key, and no case
    // folding. The negative length C also had to refuse is not a value this
    // signature admits: `len` is a byte count and is a `usize`.
    expect(os_stat.fieldLookup("de", 2) == -1);
    expect(os_stat.fieldLookup("device", 6) == -1);
    expect(os_stat.fieldLookup("", 0) == -1);
    expect(os_stat.fieldLookup("Dev", 3) == -1);
    expect(os_stat.fieldLookup("int-permission", 14) == -1);

    // The preserved `utils.cstrcmp` quirk; see the header comment.
    expect(os_stat.fieldLookup("dev\x00", 4) == 0);
}

/// Written in Janet because every assertion here is about a *keyword-keyed
/// table*, which Janet states in a line and Zig states in five unwraps.
fn theCoreFunctions() void {
    eval(
        \\(os/mkdir "janet-zig-os-stat-4d71")
        \\(spit "janet-zig-os-stat-4d71/file" "0123456789")
        \\(os/chmod "janet-zig-os-stat-4d71/file" 8r640)
    );

    // A whole-table result has every registry field in it, under the
    // registry's own names, which is the Janet-visible half of
    // `theFieldRegistry`.
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

    // A supplied table is filled and returned: the same table, with its
    // existing entry intact, so the length is sixteen.
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

/// An unknown field keyword raises rather than giving nil, and a prefix of a
/// real one is still unknown. These are reached
/// inside a Janet string; here they are values.
fn theRefusals() void {
    const stat = harness.core("os/stat");
    var args: [2]repr.Value = undefined;

    args[0] = value.fromBytes(work_file, .string);
    args[1] = value.fromBytes("nope", .keyword);
    expect(harness.raised(stat, .{args[0..2]}) != null);

    // `:de` is a prefix of `:dev`, and the lookup matches whole names.
    args[1] = value.fromBytes("de", .keyword);
    expect(harness.raised(stat, .{args[0..2]}) != null);
}

// ==========================================================================
// Entry
// ==========================================================================

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
