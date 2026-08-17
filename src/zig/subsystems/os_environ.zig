//! Non-panicking environment scanning and host operations.
//!
//! C retains Janet validation and allocation and holds its environment mutex
//! across these calls, including while copying the pointer returned by getenv.

const builtin = @import("builtin");

extern fn getenv(name: [*:0]const u8) callconv(.c) ?[*:0]const u8;
extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) callconv(.c) c_int;
extern fn unsetenv(name: [*:0]const u8) callconv(.c) c_int;
extern fn _putenv_s(name: [*:0]const u8, value: [*:0]const u8) callconv(.c) c_int;

export fn janet_os_environ_count(environ: [*c]const ?[*:0]u8) callconv(.c) i32 {
    var count: i32 = 0;
    while (environ[@intCast(count)] != null) count += 1;
    return count;
}

export fn janet_os_environ_separator(entry: [*:0]const u8) callconv(.c) i32 {
    var index: i32 = 0;
    while (entry[@intCast(index)] != 0) : (index += 1) {
        if (entry[@intCast(index)] == '=') return index;
    }
    return -1;
}

export fn janet_os_getenv(name: [*:0]const u8) callconv(.c) ?[*:0]const u8 {
    return getenv(name);
}

export fn janet_os_setenv(name: [*:0]const u8, value: ?[*:0]const u8) callconv(.c) i32 {
    if (builtin.os.tag == .windows) {
        return _putenv_s(name, value orelse "");
    }
    return if (value) |bytes| setenv(name, bytes, 1) else unsetenv(name);
}
