//! Directory enumeration, hard and symbolic links, timestamp updates, and
//! canonical path resolution.
//!
//! These are the filesystem host operations that `-Dos-fs` deliberately left
//! behind: each one either iterates, borrows host memory, or allocates. C
//! retains sandbox and argument checks, Janet value construction, `errno`
//! formatting, the buffer that receives a link target, releasing the path
//! `janet_os_realpath` allocates, and every panic path.
//!
//! The link kernels and the directory iterator exist only where the C
//! implementation used them. On Windows `os/link`, `os/symlink`, and
//! `os/readlink` panic before reaching the host, and `os/dir` enumerates with
//! `_findfirst`, whose `struct _finddata_t` layout depends on the CRT's
//! `time_t` configuration; that loop stays in C for the same reason `jstat_t`
//! and `struct timespec` did.

const std = @import("std");
const builtin = @import("builtin");

const windows = builtin.os.tag == .windows;

/// `struct utimbuf` is two `time_t` values, which is the one host structure
/// this subsystem builds rather than receiving. It is never shared across the
/// boundary: C passes the two times as doubles and the structure lives only for
/// the duration of the call.
const TimeT = if (windows) i64 else std.c.time_t;
const utimbuf = extern struct {
    actime: TimeT,
    modtime: TimeT,
};

extern fn link(oldpath: [*:0]const u8, newpath: [*:0]const u8) callconv(.c) c_int;
extern fn utime(path: [*:0]const u8, times: ?*const utimbuf) callconv(.c) c_int;
extern fn realpath(path: [*:0]const u8, resolved: ?[*]u8) callconv(.c) ?[*:0]u8;

/// The MinGW CRT resolves `utime` to the 64-bit variant, which is what Janet's
/// C implementation calls.
extern fn _utime64(path: [*:0]const u8, times: ?*const utimbuf) callconv(.c) c_int;
extern fn _fullpath(resolved: ?[*]u8, path: [*:0]const u8, size: c_int) callconv(.c) ?[*:0]u8;

const MAX_PATH = 260;

comptime {
    if (!windows) {
        @export(&dirOpen, .{ .name = "janet_os_dir_open" });
        @export(&dirNext, .{ .name = "janet_os_dir_next" });
        @export(&dirClose, .{ .name = "janet_os_dir_close" });
        @export(&hardLink, .{ .name = "janet_os_link" });
        @export(&symbolicLink, .{ .name = "janet_os_symlink" });
        @export(&readLink, .{ .name = "janet_os_readlink" });
    }
    @export(&touch, .{ .name = "janet_os_touch" });
    @export(&canonicalPath, .{ .name = "janet_os_realpath" });
}

/// Open a directory stream, reporting failure through `errno` as `opendir`
/// does.
fn dirOpen(path: [*:0]const u8) callconv(.c) ?*anyopaque {
    return @ptrCast(std.c.opendir(path));
}

/// Report the next entry that is neither "." nor "..", borrowing the name from
/// the directory stream.
///
/// Returns 1 with a name, 0 at the end of the stream, or -1 with `errno` set.
/// The C loop this replaces cleared `errno` before each read, because a null
/// result means either the end of the stream or a failure.
fn dirNext(handle: *anyopaque, name_out: *[*:0]const u8) callconv(.c) i32 {
    const dir: *std.c.DIR = @ptrCast(handle);
    while (true) {
        std.c._errno().* = 0;
        const entry = std.c.readdir(dir) orelse {
            return if (std.c._errno().* != 0) -1 else 0;
        };
        const name: [*:0]const u8 = @ptrCast(&entry.name);
        if (isDotEntry(name)) continue;
        name_out.* = name;
        return 1;
    }
}

fn dirClose(handle: *anyopaque) callconv(.c) void {
    _ = std.c.closedir(@ptrCast(handle));
}

fn isDotEntry(name: [*:0]const u8) bool {
    if (name[0] != '.') return false;
    if (name[1] == 0) return true;
    return name[1] == '.' and name[2] == 0;
}

fn hardLink(oldpath: [*:0]const u8, newpath: [*:0]const u8) callconv(.c) i32 {
    return link(oldpath, newpath);
}

fn symbolicLink(oldpath: [*:0]const u8, newpath: [*:0]const u8) callconv(.c) i32 {
    return std.c.symlink(oldpath, newpath);
}

/// Read a link target into the caller's buffer, returning its length or -1.
/// The target is not terminated, and a target longer than the buffer is
/// truncated rather than reported, which is why C compares the length against
/// the buffer size.
fn readLink(path: [*:0]const u8, buffer: [*]u8, size: usize) callconv(.c) i64 {
    return @intCast(std.c.readlink(path, buffer, size));
}

/// Set a file's access and modification times, or set both to the current time
/// when `has_times` is zero.
///
/// C has already resolved the argument defaults; the times arrive as doubles
/// because that is what Janet holds. Converting a double that no `time_t` can
/// represent is undefined in C, so the port saturates instead, as the host wait
/// in `os_time.zig` does.
fn touch(path: [*:0]const u8, has_times: i32, actime: f64, modtime: f64) callconv(.c) i32 {
    if (has_times == 0) {
        return if (windows) _utime64(path, null) else utime(path, null);
    }
    const times: utimbuf = .{
        .actime = saturatingCast(TimeT, actime),
        .modtime = saturatingCast(TimeT, modtime),
    };
    return if (windows) _utime64(path, &times) else utime(path, &times);
}

/// Resolve a path to its canonical absolute form, following `.`, `..`, and
/// symbolic links. The result is allocated by the host and released by the
/// caller.
fn canonicalPath(path: [*:0]const u8) callconv(.c) ?[*:0]u8 {
    if (windows) return _fullpath(null, path, MAX_PATH);
    return realpath(path, null);
}

/// Convert toward zero, clamping instead of trapping. This reproduces the
/// AArch64 conversion the C implementation performs without a sanitizer: a NaN
/// becomes zero and an out-of-range value becomes the nearest bound. A NaN is
/// separated first because `@intFromFloat` is illegal for it and because the
/// ordinary comparisons below would otherwise send it to the low bound.
fn saturatingCast(comptime T: type, value: f64) T {
    if (std.math.isNan(value)) return 0;
    const low: f64 = @floatFromInt(@as(T, std.math.minInt(T)));
    const high: f64 = @floatFromInt(@as(T, std.math.maxInt(T)));
    if (!(value > low)) return std.math.minInt(T);
    if (value >= high) return std.math.maxInt(T);
    return @intFromFloat(value);
}

test "dot entries are recognized without matching longer names" {
    try std.testing.expect(isDotEntry("."));
    try std.testing.expect(isDotEntry(".."));
    try std.testing.expect(!isDotEntry("..."));
    try std.testing.expect(!isDotEntry(".hidden"));
    try std.testing.expect(!isDotEntry("first"));
    try std.testing.expect(!isDotEntry(""));
}

test "saturating conversion clamps rather than trapping" {
    try std.testing.expectEqual(@as(i64, 0), saturatingCast(i64, std.math.nan(f64)));
    try std.testing.expectEqual(@as(i64, 1000000000), saturatingCast(i64, 1000000000.75));
    try std.testing.expectEqual(@as(i64, -1), saturatingCast(i64, -1.5));
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), saturatingCast(i64, 1e300));
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), saturatingCast(i64, -1e300));
}
