//! `os/stat` and `os/lstat`, the field registry they share, and what a
//! permission is.
//!
//! Out of the bucket because `os/stat` is a name Janet publishes and the
//! fifteen field keywords are its interface.
//!
//! **The permission helpers live here rather than in `os/fs.zig`, and that is
//! what keeps the subtree acyclic.** `getUnixMode`, `getMode`, `optMode` and
//! `makePermstring` are shared three ways -- by `os/chmod` and `os/umask` in
//! the bucket, by `os/perm-string` and `os/perm-int` beside them, and by
//! `os/open`'s mode argument. In the bucket they would have made both leaves
//! import it while it imports them for `entries()`. Here the graph is
//! `fs -> {stat, open}` and `open -> stat`, with no cycle. They belong here on
//! the merits too: this file's registry is what fixes a permission's Janet
//! representation.
//!
//! Six seam entries converted, all six symbols still exported.

const std = @import("std");
const builtin = @import("builtin");
const repr = @import("repr");
const raise = @import("../../raise.zig");
const wrap = @import("../../value/helpers/wrap.zig");
const tables = @import("../../value/tables.zig");
const args_core = @import("../../args.zig");
const oa = @import("../abi.zig");
const h = oa.h;
const pp_format = @import("../../pp/format.zig");
const vm_lifecycle = @import("../../vm/lifecycle.zig");
const host_stat = @import("host_stat.zig");
const value = @import("../../value.zig");
const strings = @import("../../value/strings.zig");

/// Reading a `struct stat` is `host_stat.zig`'s, for the reason its header
/// gives: musl's translates to `opaque {}`, so the answer is `statx` on Linux,
/// whose structure Zig defines itself, and the translation on macOS and mingw,
/// which carry `struct stat` completely.
const statRead = host_stat.statRead;

// ==========================================================================
// Permissions
// ==========================================================================

/// The field identifiers `-Dos-stat`'s registry fixes, by position. The
/// registry itself is that subsystem's and is reached by name; these are the
/// indices into it, and `test/os_stat.zig` already pins the order both sides
/// agree on.
pub const Field = enum(i32) {
    dev,
    inode,
    mode,
    int_permissions,
    permissions,
    uid,
    gid,
    nlink,
    rdev,
    size,
    blocks,
    blocksize,
    accessed,
    modified,
    changed,
};

pub const field_count = @typeInfo(Field).@"enum".fields.len;

/// `os_make_permstring`.
pub fn makePermstring(permissions: i32) repr.Value {
    var bytes: [9]u8 = undefined;
    hostFormatPermissions(permissions, &bytes);
    return value.fromBytes(&bytes, .string);
}

/// `os_get_unix_mode`: an integer in `[0, 8r777]` or a nine-byte `rwx` string.
///
/// Shared by five cfunctions across three `-Dos-*` subjects. See the head of
/// this file for why that is an ordinary Zig call rather than a seam.
pub fn getUnixMode(argv: []const repr.Value, n: usize) raise.Raising(i32) {
    if (args_core.checkint(argv[n])) {
        const x = wrap.toInteger(argv[n]);
        if (x < 0 or x > 0o777) {
            return pp_format.panicf(
                "bad slot #%d, expected integer in range [0, 8r777], got %v",
                .{ @as(i64, @intCast(n)), argv[n] },
            );
        }
        return x;
    }
    const bytes = try args_core.getBytes(argv, n);
    if (bytes.len != 9) {
        return pp_format.panicf(
            "bad slot #%d: expected byte sequence of length 9, got %v",
            .{ @as(i64, @intCast(n)), argv[n] },
        );
    }
    return hostParsePermissions(args_core.viewBytes(bytes).ptr);
}

/// `os_getmode`: the same value, converted to what the host's `chmod` takes.
///
/// `jmode_t` is `mode_t` on POSIX and `unsigned short` on Windows; both are
/// scalars, so nothing here depends on a host layout.
pub const jmode_t = if (windows) c_ushort else h.mode_t;

pub fn getMode(argv: []const repr.Value, n: usize) raise.Raising(jmode_t) {
    return @intCast(hostPermFromUnix(try getUnixMode(argv, n)));
}

/// `os_optmode`.
pub fn optMode(argv: []const repr.Value, n: usize, dflt: i32) raise.Raising(jmode_t) {
    if (argv.len > n) return getMode(argv, n);
    return @intCast(hostPermFromUnix(dflt));
}

// ==========================================================================
// Metadata
// ==========================================================================

/// Build the Janet value for one field out of what `janet_zig_os_stat_read`
/// copied out. Every one of the fifteen is constructed here; C keeps only the
/// read.
pub fn statField(field: Field, mode: u32, numbers: *const [field_count]f64) repr.Value {
    return switch (field) {
        .mode => value.fromBytes(std.mem.span(hostModeName(mode)), .keyword),
        .int_permissions => wrap.fromInteger(
            hostPermToUnix(@bitCast(hostDecodePermissions(mode))),
        ),
        .permissions => makePermstring(
            hostPermToUnix(@bitCast(hostDecodePermissions(mode))),
        ),
        else => wrap.fromNumber(numbers[@intCast(@intFromEnum(field))]),
    };
}

pub fn statOrLstat(do_lstat: bool, argv: []repr.Value) raise.Raising(repr.Value) {
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"fs_read"}));
    try args_core.arity(argv, 1, 2);
    const path = try args_core.getCString(argv, 0);
    var tab: ?*tables.Table = null;
    var key: ?strings.Keyword = null;
    if (argv.len == 2) {
        if (repr.checkType(argv[1], repr.Tag.keyword)) {
            key = try args_core.getKeyword(argv, 1);
        } else {
            tab = try args_core.getTable(argv, 1);
        }
    } else {
        tab = tables.new(0);
    }

    var mode: u32 = 0;
    var numbers: [field_count]f64 = @splat(0);
    if (statRead(@ptrCast(path), do_lstat, &mode, &numbers) == -1) {
        return wrap.fromNil();
    }

    if (key) |k| {
        const field = fieldLookup(k, strings.head(k).length);
        if (field < 0) return pp_format.panicf("unexpected keyword %v", .{wrap.fromKeyword(k)});
        return statField(@enumFromInt(field), mode, &numbers);
    }
    // The registry's count is `-Dos-stat`'s, and this walks it rather than
    // `field_count` so that the two cannot silently disagree.
    const count: usize = @intCast(fieldCount());
    for (0..count) |field| {
        tables.put(
            tab.?,
            value.fromBytes(std.mem.span(fieldName(@intCast(field)).?), .keyword),
            statField(@enumFromInt(field), mode, &numbers),
        );
    }
    return wrap.fromTable(tab.?);
}

// ==========================================================================
// The abis
//
// A cfunction that decides to raise is raising, and one that makes no such
// decision is a plain `raise.CFunction`. Every cfunction in this file decides,
// because every one of them reports a host failure.
// ==========================================================================

pub fn cfunStat(argv: []repr.Value) raise.Raising(repr.Value) {
    return statOrLstat(false, argv);
}

pub fn cfunLstat(argv: []repr.Value) raise.Raising(repr.Value) {
    return statOrLstat(true, argv);
}

const windows = builtin.os.tag == .windows;

/// Portable POSIX file type bits. Linux, macOS, and the BSDs agree on these.
const s_ifmt: u32 = 0o170000;
const s_ififo: u32 = 0o010000;
const s_ifchr: u32 = 0o020000;
const s_ifdir: u32 = 0o040000;
const s_ifblk: u32 = 0o060000;
const s_ifreg: u32 = 0o100000;
const s_iflnk: u32 = 0o120000;
const s_ifsock: u32 = 0o140000;

/// Windows CRT mode bits, as `<sys/stat.h>` defines them for MSVC and MinGW.
const w_ifreg: u32 = 0o100000;
const w_ifdir: u32 = 0o040000;
const w_ifchr: u32 = 0o020000;
const w_iexec: u32 = 0o000100;
const w_iwrite: u32 = 0o000200;
const w_iread: u32 = 0o000400;

/// Classify a host mode word the way `os/stat`'s `:mode` field reports it.
///
/// The Windows CRT has no `S_IS*` macros, and Janet tests its three type bits
/// individually rather than masking first; that difference is preserved.
/// Plan 9 also omits the fifo, block, socket, link, and character cases, but it
/// has no Zig target and therefore always uses the C implementation.
pub fn hostModeName(mode: u32) [*:0]const u8 {
    if (windows) {
        if (mode & w_ifreg != 0) return "file";
        if (mode & w_ifdir != 0) return "directory";
        if (mode & w_ifchr != 0) return "character";
        return "other";
    }
    return switch (mode & s_ifmt) {
        s_ifreg => "file",
        s_ifdir => "directory",
        s_ififo => "fifo",
        s_ifblk => "block",
        s_ifsock => "socket",
        s_iflnk => "link",
        s_ifchr => "character",
        else => "other",
    };
}

/// Reduce a host mode word to the permission bits Janet reports.
pub fn hostDecodePermissions(mode: u32) i32 {
    if (windows) return @intCast(mode & (w_iexec | w_iwrite | w_iread));
    return @intCast(mode & 0o777);
}

/// Convert host permission bits into Janet's portable nine-bit value.
pub fn hostPermToUnix(mode: u32) i32 {
    if (windows) {
        var result: i32 = 0;
        if (mode & w_iexec != 0) result |= 0o111;
        if (mode & w_iwrite != 0) result |= 0o222;
        if (mode & w_iread != 0) result |= 0o444;
        return result;
    }
    return @intCast(mode);
}

/// Convert Janet's portable nine-bit value back into host permission bits.
///
/// **The masks are octal**, which is what `hostPermToUnix` above tests with
/// and what every permission constant in this subsystem is written in. Decimal
/// `111`, `222` and `444` are `0o157`, `0o336` and `0o674`, which overlap the
/// wrong fields: decimal 222 shares the group-read bit with `8r444`, so
/// `(os/chmod p 8r444)` leaves a Windows file writable, because `_chmod`
/// derives the read-only attribute from `_S_IWRITE`.
pub fn hostPermFromUnix(permissions: i32) u32 {
    if (windows) {
        var mode: u32 = 0;
        if (permissions & 0o111 != 0) mode |= w_iexec;
        if (permissions & 0o222 != 0) mode |= w_iwrite;
        if (permissions & 0o444 != 0) mode |= w_iread;
        return mode;
    }
    return @bitCast(permissions);
}

/// The `os/stat` field registry, in the order the C implementation inserts
/// them into the result table. The index of a name is the field identifier the
/// C getters switch on, so the two orders must stay aligned; `test/os_stat.zig`
/// pins every name and index.
const field_names = [_][:0]const u8{
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

pub fn fieldCount() i32 {
    return @intCast(field_names.len);
}

pub fn fieldName(index: i32) ?[*:0]const u8 {
    if (index < 0 or index >= field_names.len) return null;
    return field_names[@intCast(index)].ptr;
}

/// Find a field by keyword, returning its index or -1.
///
/// The comparison reproduces `janet_cstrcmp`, which the C implementation used
/// here, including its treatment of a key whose own bytes end in NUL.
pub fn fieldLookup(key: [*]const u8, len: usize) i32 {
    for (field_names, 0..) |name, index| {
        if (cstrequal(key, len, name)) return @intCast(index);
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

test "field names are unique and NUL terminated" {
    for (field_names, 0..) |name, index| {
        try std.testing.expect(name.len > 0);
        try std.testing.expectEqual(@as(u8, 0), name.ptr[name.len]);
        for (field_names[index + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, name, other));
        }
    }
}

test "lookup matches whole names only" {
    try std.testing.expectEqual(@as(i32, 0), fieldLookup("dev", 3));
    try std.testing.expectEqual(@as(i32, -1), fieldLookup("de", 2));
    try std.testing.expectEqual(@as(i32, -1), fieldLookup("device", 6));
}

const permission_bits = [9]i32{
    0o400, 0o200, 0o100,
    0o040, 0o020, 0o010,
    0o004, 0o002, 0o001,
};
const permission_chars = "rwxrwxrwx";

pub fn hostParsePermissions(permissions: [*]const u8) i32 {
    var mode: i32 = 0;
    for (permission_bits, permission_chars, 0..) |bit, expected, index| {
        if (permissions[index] == expected) mode |= bit;
    }
    return mode;
}

pub fn hostFormatPermissions(mode: i32, out: [*]u8) void {
    for (permission_bits, permission_chars, 0..) |bit, enabled, index| {
        out[index] = if (mode & bit != 0) enabled else '-';
    }
}

test "permission tables remain paired" {
    try std.testing.expectEqual(permission_bits.len, permission_chars.len);
}
