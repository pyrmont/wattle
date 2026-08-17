//! Allocation-free conversion between Janet's textual permissions and the
//! portable low nine bits of a Unix file mode.
//!
//! C retains Janet argument validation, value allocation, and host `mode_t`
//! conversion because those paths can panic or differ by platform.

const std = @import("std");

const permission_bits = [9]i32{
    0o400, 0o200, 0o100,
    0o040, 0o020, 0o010,
    0o004, 0o002, 0o001,
};
const permission_chars = "rwxrwxrwx";

export fn janet_os_parse_permissions(permissions: [*c]const u8) callconv(.c) i32 {
    var mode: i32 = 0;
    for (permission_bits, permission_chars, 0..) |bit, expected, index| {
        if (permissions[index] == expected) mode |= bit;
    }
    return mode;
}

export fn janet_os_format_permissions(mode: i32, out: [*c]u8) callconv(.c) void {
    for (permission_bits, permission_chars, 0..) |bit, enabled, index| {
        out[index] = if (mode & bit != 0) enabled else '-';
    }
}

test "permission tables remain paired" {
    try std.testing.expectEqual(permission_bits.len, permission_chars.len);
}
