//! Result-returning host operations behind Janet's basic filesystem functions.
//!
//! C retains sandbox and argument checks, Janet value construction, errno
//! formatting, and all panic paths.

const builtin = @import("builtin");

extern fn getcwd(buffer: [*]u8, size: usize) callconv(.c) ?[*]u8;
extern fn _getcwd(buffer: [*]u8, size: c_int) callconv(.c) ?[*]u8;
extern fn mkdir(path: [*:0]const u8, mode: c_uint) callconv(.c) c_int;
extern fn _mkdir(path: [*:0]const u8) callconv(.c) c_int;
extern fn rmdir(path: [*:0]const u8) callconv(.c) c_int;
extern fn _rmdir(path: [*:0]const u8) callconv(.c) c_int;
extern fn chdir(path: [*:0]const u8) callconv(.c) c_int;
extern fn _chdir(path: [*:0]const u8) callconv(.c) c_int;
extern fn remove(path: [*:0]const u8) callconv(.c) c_int;
extern fn rename(old_path: [*:0]const u8, new_path: [*:0]const u8) callconv(.c) c_int;

export fn janet_os_getcwd(buffer: [*]u8, size: i32) callconv(.c) i32 {
    const result = if (builtin.os.tag == .windows)
        _getcwd(buffer, size)
    else
        getcwd(buffer, @intCast(size));
    return if (result == null) -1 else 0;
}

export fn janet_os_mkdir(path: [*:0]const u8) callconv(.c) i32 {
    if (builtin.os.tag == .windows) return _mkdir(path);
    return mkdir(path, 0o775);
}

export fn janet_os_rmdir(path: [*:0]const u8) callconv(.c) i32 {
    return if (builtin.os.tag == .windows) _rmdir(path) else rmdir(path);
}

export fn janet_os_chdir(path: [*:0]const u8) callconv(.c) i32 {
    return if (builtin.os.tag == .windows) _chdir(path) else chdir(path);
}

export fn janet_os_remove(path: [*:0]const u8) callconv(.c) i32 {
    return remove(path);
}

export fn janet_os_rename(old_path: [*:0]const u8, new_path: [*:0]const u8) callconv(.c) i32 {
    return rename(old_path, new_path);
}
