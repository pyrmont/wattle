//! `os/stat` and `os/lstat`, the field registry they share, and what a
//! permission is.
//!
//! Out of the bucket because `os/stat` is a name Janet publishes and the
//! fifteen field keywords are its interface.
//!
//! The permission helpers live here rather than in `os/fs.zig`, and that is
//! what keeps the subtree acyclic. `getUnixMode`, `getMode`, `optMode` and
//! `makePermstring` are shared three ways: by `os/chmod` and `os/umask` in the
//! bucket, by `os/perm-string` and `os/perm-int` beside them, and by
//! `os/open`'s mode argument. In the bucket they would have made both leaves
//! import it while it imports them for `entries()`. Here the graph is
//! `fs -> {stat, open}` and `open -> stat`, with no cycle. They belong here on
//! the merits too: this file's registry is what fixes a permission's Janet
//! representation.
//!
//! The six entry points here are reached by import; none is a symbol.
//!
//! An nfunction that decides to raise is raising, and one that makes no such
//! decision is a plain `raise.NFunction`. Every nfunction in this file
//! decides, because every one of them reports a host failure.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");
const builtin = @import("builtin");

// ==========================================================================
// Project imports
// ==========================================================================

const args_core = @import("../../args.zig");
const host_stat = @import("host_stat.zig");
const oa = @import("../abi.zig");
const pp_format = @import("../../pp/format.zig");
const raise = @import("../../../api/raise.zig");
const repr = @import("repr");
const strings = @import("../../value/strings.zig");
const tables = @import("../../value/tables.zig");
const value = @import("../../value.zig");
const vm_lifecycle = @import("../../vm/lifecycle.zig");
const wrap = @import("../../value/helpers/wrap.zig");

/// `os/abi.zig`'s translation, which is where `mode_t` below comes from.
const h = oa.h;

/// Reading a `struct stat` is `host_stat.zig`'s, for the reason its header
/// gives: musl's translates to `opaque {}`, so the route is `statx` on Linux,
/// whose structure Zig defines itself, and the translation on macOS and mingw,
/// which have `struct stat` complete.
const statRead = host_stat.statRead;

// ==========================================================================
// Constants
// ==========================================================================

/// How many fields `os/stat` reports.
pub const field_count = @typeInfo(Field).@"enum".fields.len;

/// The `os/stat` field registry, in the order the C implementation inserts
/// them into the result table. The index of a name is the field identifier the
/// getters switch on, so the two orders stay aligned; `test/os_stat.zig` pins
/// every name and index.
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

/// The nine permission bits and the nine characters that spell them, in the
/// order an `rwx` string reads.
const permission_bits = [9]i32{
    0o400, 0o200, 0o100,
    0o040, 0o020, 0o010,
    0o004, 0o002, 0o001,
};

const permission_chars = "rwxrwxrwx";

/// Portable POSIX file type bits. Linux, macOS and the BSDs agree on these.
const s_ifblk: u32 = 0o060000;
const s_ifchr: u32 = 0o020000;
const s_ifdir: u32 = 0o040000;
const s_ififo: u32 = 0o010000;
const s_iflnk: u32 = 0o120000;
const s_ifmt: u32 = 0o170000;
const s_ifreg: u32 = 0o100000;
const s_ifsock: u32 = 0o140000;

/// The Windows CRT's mode bits, which are three type bits and three
/// permission bits and no mask.
const w_iexec: u32 = 0o000100;
const w_ifchr: u32 = 0o020000;
const w_ifdir: u32 = 0o040000;
const w_ifreg: u32 = 0o100000;
const w_iread: u32 = 0o000400;
const w_iwrite: u32 = 0o000200;

/// Whether this target takes the CRT's mode bits rather than POSIX's.
const windows = builtin.os.tag == .windows;

// ==========================================================================
// Aliased types
// ==========================================================================

/// What the host's `chmod` takes.
///
/// `jmode_t` is `mode_t` on POSIX and `unsigned short` on Windows; both are
/// scalars, so nothing here depends on a host layout.
pub const jmode_t = if (windows) c_ushort else h.mode_t;

// ==========================================================================
// Types
// ==========================================================================

/// The field identifiers, by position: an index into the numbers array
/// `host_stat.zig` fills, and into `field_names` below, which is the keyword
/// for each. `test/os_stat.zig` pins the order both sides agree on.
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

// ==========================================================================
// Public functions
// ==========================================================================

/// `(os/lstat path [tab-or-key])`.
pub fn nfunLstat(argv: []repr.Value) raise.Error!repr.Value {
    return statOrLstat(true, argv);
}

/// `(os/stat path [tab-or-key])`.
pub fn nfunStat(argv: []repr.Value) raise.Error!repr.Value {
    return statOrLstat(false, argv);
}

/// How many fields the registry has, which `statOrLstat` walks rather than
/// `field_count`, so that the two cannot silently disagree.
pub fn fieldCount() i32 {
    return @intCast(field_names.len);
}

/// Finds a field by keyword, returning its index or -1.
///
/// The comparison is `utils.cstrcmp`'s walk written as an equality test: the
/// key's own length bounds it, and a NUL in the name ends it.
pub fn fieldLookup(key: [*]const u8, len: usize) i32 {
    for (field_names, 0..) |name, index| {
        if (cstrequal(key, len, name)) return @intCast(index);
    }
    return -1;
}

/// The name at `index`, or nothing where the index is outside the registry.
pub fn fieldName(index: i32) ?[*:0]const u8 {
    if (index < 0 or index >= field_names.len) return null;
    return field_names[@intCast(index)].ptr;
}

/// A permission argument as what the host's `chmod` takes.
pub fn getMode(argv: []const repr.Value, n: usize) raise.Error!jmode_t {
    return @intCast(hostPermFromUnix(try getUnixMode(argv, n)));
}

/// A permission argument: an integer in `[0, 8r777]` or a nine-byte `rwx`
/// string.
///
/// Reached by five nfunctions: `os/perm-int` and `os/perm-string` call this
/// directly, `os/chmod` and `os/umask` through `getMode`, and `os/open`
/// through `optMode`. The head of this file says why that is an ordinary Zig
/// call rather than a seam.
pub fn getUnixMode(argv: []const repr.Value, n: usize) raise.Error!i32 {
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

/// Reduces a host mode word to the permission bits Janet reports.
pub fn hostDecodePermissions(mode: u32) i32 {
    if (windows) return @intCast(mode & (w_iexec | w_iwrite | w_iread));
    return @intCast(mode & 0o777);
}

/// Writes a nine-bit permission value as the nine `rwx` bytes.
pub fn hostFormatPermissions(mode: i32, out: [*]u8) void {
    for (permission_bits, permission_chars, 0..) |bit, enabled, index| {
        out[index] = if (mode & bit != 0) enabled else '-';
    }
}

/// Classifies a host mode word the way `os/stat`'s `:mode` field reports it.
///
/// The Windows CRT has no `S_IS*` macros, and Janet tests its three type bits
/// individually rather than masking first; that difference is preserved. Plan
/// 9 also omits the fifo, block, socket, link and character cases, but it has
/// no Zig target and therefore always takes the C implementation.
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

/// Reads nine `rwx` bytes as a permission value.
pub fn hostParsePermissions(permissions: [*]const u8) i32 {
    var mode: i32 = 0;
    for (permission_bits, permission_chars, 0..) |bit, expected, index| {
        if (permissions[index] == expected) mode |= bit;
    }
    return mode;
}

/// Converts Janet's portable nine-bit value back into host permission bits.
///
/// The masks are octal, which is what `hostPermToUnix` above tests with and
/// what every permission constant in this subsystem is written in. Decimal
/// `111`, `222` and `444` are `0o157`, `0o336` and `0o674`, which overlap the
/// wrong fields: decimal 222 shares the group-read bit with `8r444`, so
/// `(os/chmod p 8r444)` would leave a Windows file writable, because `_chmod`
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

/// Converts host permission bits into Janet's portable nine-bit value.
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

/// A mode as the nine-byte `rwx` string `os/perm-string` gives back.
pub fn makePermstring(permissions: i32) repr.Value {
    var bytes: [9]u8 = undefined;
    hostFormatPermissions(permissions, &bytes);
    return value.fromBytes(&bytes, .string);
}

/// `getMode` with a default for an absent argument.
pub fn optMode(argv: []const repr.Value, n: usize, dflt: i32) raise.Error!jmode_t {
    if (argv.len > n) return getMode(argv, n);
    return @intCast(hostPermFromUnix(dflt));
}

/// Builds the Janet value for one field out of what `host_stat.zig`'s
/// `statRead` copied out. Every one of the fifteen is constructed here, and
/// `statRead` does nothing but the read.
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

/// The body of `os/stat` and `os/lstat`, which differ only in whether a
/// symlink is followed. A keyword second argument asks for one field, a table
/// is filled with all fifteen, and a path that cannot be stat'ed is nil.
pub fn statOrLstat(do_lstat: bool, argv: []repr.Value) raise.Error!repr.Value {
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"fs_read"}));
    try args_core.arity(argv, 1, 2);
    const path = try args_core.getCString(argv, 0);
    var tab: ?*tables.Table = null;
    var key: ?strings.Keyword = null;
    if (argv.len == 2) {
        if (wrap.isKeyword(argv[1])) {
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
    // The count walked is `field_names`'s rather than `field_count`, so that
    // the two cannot silently disagree.
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
// Private functions
// ==========================================================================

/// Whether the `len` bytes at `key` are `other`, with a NUL in `other` ending
/// the comparison.
fn cstrequal(key: [*]const u8, len: usize, other: [:0]const u8) bool {
    var index: usize = 0;
    while (index < len) : (index += 1) {
        const k = other.ptr[index];
        if (key[index] != k) return false;
        if (k == 0) break;
    }
    return other.ptr[index] == 0;
}

// ==========================================================================
// Tests
// ==========================================================================

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

test "permission tables remain paired" {
    try std.testing.expectEqual(permission_bits.len, permission_chars.len);
}
