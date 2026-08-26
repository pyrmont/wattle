//! `os/stat` and `os/lstat`, the field registry they share, and what a
//! permission is.
//!
//! Split out of `os_files.zig` at Phase 12 increment 6f, together with
//! `os_stat.zig` and `os_permissions.zig` -- the host wrappers it reached
//! across the C-ABI seam. `port/TREE.md`'s heuristic keeps this one out of the
//! bucket because `os/stat` is a name Janet publishes and the fifteen field
//! keywords are its interface.
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
const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");
const raise = @import("raise");
const wrap = @import("../../value/helpers/wrap.zig");
const tables = @import("../../value/tables.zig");
const kind = @import("../../value/helpers/kind.zig");
const args_core = @import("../../args.zig");
const oa = @import("../abi.zig");
const h = oa.h;
const pp_format = @import("../../pp/format.zig");
const vm_lifecycle = @import("../../vm/lifecycle.zig");
const host_stat = @import("host_stat.zig");
const value = @import("../../value.zig");

/// `-Dos-stat`'s field registry, by import. These were `export fn`s reached
/// back through the linker, which is the shape `os.c` needed; Phase 11 Part 20
/// spent the three symbols along with `test/os_surface.c`, their last reader
/// outside this file.
/// `host_stat.zig` since Phase 10 Part 18. The measurement at the head of this
/// file still holds -- musl's `struct stat` is `opaque {}` after translation --
/// and what changed is the answer: `statx` on Linux, whose structure Zig
/// defines itself, and `@cImport` on macOS and mingw, which translate `struct
/// stat` completely.
const janet_zig_os_stat_read = host_stat.statReadAbiCompat;

// ==========================================================================
// Permissions
// ==========================================================================

/// The field identifiers `-Dos-stat`'s registry fixes, by position. The
/// registry itself is that subsystem's and is reached by name; these are the
/// indices into it, and `test/os_stat.c` already pins the order both sides
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
pub fn makePermstring(permissions: i32) types.Janet {
    var bytes: [9]u8 = undefined;
    hostFormatPermissions(permissions, &bytes);
    return value.fromBytes(&bytes, .string);
}

/// `os_get_unix_mode`: an integer in `[0, 8r777]` or a nine-byte `rwx` string.
///
/// Shared by five cfunctions across three `-Dos-*` subjects. See the head of
/// this file for why that is an ordinary Zig call rather than a seam.
pub fn getUnixMode(argv: []const types.Janet, n: i32) raise.Raising(i32) {
    if (args_core.checkint(argv[@intCast(n)]) != 0) {
        const x = wrap.toInteger(argv[@intCast(n)]);
        if (x < 0 or x > 0o777) {
            return pp_format.panicf(
                "bad slot #%d, expected integer in range [0, 8r777], got %v",
                .{ n, argv[@intCast(n)] },
            );
        }
        return x;
    }
    const bytes = try args_core.getBytes(argv, n);
    if (bytes.len != 9) {
        return pp_format.panicf(
            "bad slot #%d: expected byte sequence of length 9, got %v",
            .{ n, argv[@intCast(n)] },
        );
    }
    return hostParsePermissions(args_core.viewBytes(bytes).ptr);
}

/// `os_getmode`: the same value, converted to what the host's `chmod` takes.
///
/// `jmode_t` is `mode_t` on POSIX and `unsigned short` on Windows; both are
/// scalars, so nothing here depends on a host layout.
pub const jmode_t = if (windows) c_ushort else h.mode_t;

pub fn getMode(argv: []const types.Janet, n: i32) raise.Raising(jmode_t) {
    return @intCast(hostPermFromUnix(try getUnixMode(argv, n)));
}

/// `os_optmode`.
pub fn optMode(argv: []const types.Janet, n: i32, dflt: i32) raise.Raising(jmode_t) {
    if (@as(i32, @intCast(argv.len)) > n) return getMode(argv, n);
    return @intCast(hostPermFromUnix(dflt));
}

// ==========================================================================
// Metadata
// ==========================================================================

/// Build the Janet value for one field out of what `janet_zig_os_stat_read`
/// copied out. Every one of the fifteen is constructed here; C keeps only the
/// read.
pub fn statField(field: Field, mode: u32, numbers: *const [field_count]f64) types.Janet {
    return switch (field) {
        .mode => value.fromBytes(std.mem.span(hostModeName(mode)), .keyword),
        .int_permissions => wrapInteger(
            hostPermToUnix(@bitCast(hostDecodePermissions(mode))),
        ),
        .permissions => makePermstring(
            hostPermToUnix(@bitCast(hostDecodePermissions(mode))),
        ),
        else => wrap.fromNumber(numbers[@intCast(@intFromEnum(field))]),
    };
}

pub fn statOrLstat(do_lstat: bool, argv: []types.Janet) raise.Raising(types.Janet) {
    try vm_lifecycle.sandboxAssert(constants.JANET_SANDBOX_FS_READ);
    try args_core.arity(argv, 1, 2);
    const path = try args_core.getCString(argv, 0);
    var tab: ?*types.JanetTable = null;
    var key: ?types.JanetKeyword = null;
    if (@as(i32, @intCast(argv.len)) == 2) {
        if (kind.checkType(argv[1], constants.JANET_KEYWORD) != 0) {
            key = try args_core.getKeyword(argv, 1);
        } else {
            tab = try args_core.getTable(argv, 1);
        }
    } else {
        tab = tables.new(0);
    }

    var mode: u32 = 0;
    var numbers: [field_count]f64 = @splat(0);
    if (janet_zig_os_stat_read(@ptrCast(path), @intFromBool(do_lstat), &mode, &numbers) == -1) {
        return wrap.fromNil();
    }

    if (key) |k| {
        const field = fieldLookup(k, types.stringHead(k).length);
        if (field < 0) return pp_format.panicf("unexpected keyword %v", .{wrap.fromKeyword(k)});
        return statField(@enumFromInt(field), mode, &numbers);
    }
    // The registry's count is `-Dos-stat`'s, and this walks it rather than
    // `field_count` so that the two cannot silently disagree.
    const count = fieldCount();
    var field: i32 = 0;
    while (field < count) : (field += 1) {
        tables.put(
            tab.?,
            value.fromBytes(std.mem.span(fieldName(field).?), .keyword),
            statField(@enumFromInt(field), mode, &numbers),
        );
    }
    return wrap.fromTable(tab.?);
}

// ==========================================================================
// The abis
//
// Part 10's finding applied rather than restated: a cfunction that decides to
// raise is an `Impl` behind a two-line abi, and one that makes no such
// decision stays a plain `JanetCFunction`. Every cfunction in this file
// decides, because every one of them reports a host failure.
// ==========================================================================

pub fn statImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    return statOrLstat(false, argv);
}

pub fn lstatImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    return statOrLstat(true, argv);
}

const windows = builtin.os.tag == .windows;

/// `src/core/util.h`, declared here rather than in `cabi.zig`.
extern fn janet_strerror(e: c_int) callconv(.c) [*:0]const u8;

/// `janet_wrap_integer`, written out rather than called. `janet.h` declares the
/// function beside its macro and `wrap.c` defines it only for the two nanbox
/// layouts, so a tagged build has no such symbol and a Zig caller -- which
/// cannot use the macro -- does not link. `marsh.zig`, `pp_pretty.zig` and
/// `value_access.zig` write it out for the same reason, and `FOUND.md` has the
/// defect. This is the fourth subsystem to meet it.
inline fn wrapInteger(x: i32) types.Janet {
    return wrap.fromNumber(@floatFromInt(x));
}

inline fn errno() c_int {
    return std.c._errno().*;
}

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
/// The Windows tests are decimal 111, 222, and 444 rather than octal. That is
/// a defect in the C implementation, recorded in `FOUND.md`; it is reproduced
/// here so the two implementations stay observationally identical until the
/// behavior is decided.
pub fn hostPermFromUnix(permissions: i32) u32 {
    if (windows) {
        var mode: u32 = 0;
        if (permissions & 111 != 0) mode |= w_iexec;
        if (permissions & 222 != 0) mode |= w_iwrite;
        if (permissions & 444 != 0) mode |= w_iread;
        return mode;
    }
    return @bitCast(permissions);
}

/// The `os/stat` field registry, in the order the C implementation inserts
/// them into the result table. The index of a name is the field identifier the
/// C getters switch on, so the two orders must stay aligned; `test/os_stat.c`
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
pub fn fieldLookup(key: [*]const u8, len: i32) i32 {
    if (len < 0) return -1;
    for (field_names, 0..) |name, index| {
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
