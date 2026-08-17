//! File metadata kernels shared by `os/stat` and `os/lstat`.
//!
//! Zig owns the classification of a host mode word into Janet's file-kind
//! name, the conversion between the host's permission bits and Janet's
//! portable nine-bit value, and the stat field registry with its keyword
//! lookup.
//!
//! C retains the `jstat_t` declaration, the `stat`/`lstat` calls, and every
//! path that constructs a Janet value, so no panic can cross a Zig frame and
//! no host struct layout is duplicated here.

const std = @import("std");
const builtin = @import("builtin");

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
export fn janet_os_mode_name(mode: u32) callconv(.c) [*:0]const u8 {
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
export fn janet_os_decode_permissions(mode: u32) callconv(.c) i32 {
    if (windows) return @intCast(mode & (w_iexec | w_iwrite | w_iread));
    return @intCast(mode & 0o777);
}

/// Convert host permission bits into Janet's portable nine-bit value.
export fn janet_os_perm_to_unix(mode: u32) callconv(.c) i32 {
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
export fn janet_os_perm_from_unix(permissions: i32) callconv(.c) u32 {
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

export fn janet_os_stat_field_count() callconv(.c) i32 {
    return @intCast(field_names.len);
}

export fn janet_os_stat_field_name(index: i32) callconv(.c) ?[*:0]const u8 {
    if (index < 0 or index >= field_names.len) return null;
    return field_names[@intCast(index)].ptr;
}

/// Find a field by keyword, returning its index or -1.
///
/// The comparison reproduces `janet_cstrcmp`, which the C implementation used
/// here, including its treatment of a key whose own bytes end in NUL.
export fn janet_os_stat_field_lookup(key: [*]const u8, len: i32) callconv(.c) i32 {
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
    try std.testing.expectEqual(@as(i32, 0), janet_os_stat_field_lookup("dev", 3));
    try std.testing.expectEqual(@as(i32, -1), janet_os_stat_field_lookup("de", 2));
    try std.testing.expectEqual(@as(i32, -1), janet_os_stat_field_lookup("device", 6));
}
