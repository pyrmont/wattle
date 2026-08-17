//! File-mode parsing and the stream host operations behind Janet's `file/`
//! namespace.
//!
//! Two portable kernels and a set of result-returning calls on `FILE *`. C
//! retains the abstract type and its `JanetFile` payload, argument extraction,
//! Janet value construction, buffer growth, `errno` formatting, the sandbox
//! assertions this subsystem describes but does not perform, and every panic
//! path.
//!
//! `FILE` is opaque by definition, so a stream pointer crosses the boundary as
//! a handle rather than as a structure. That is what separates this subsystem
//! from `jstat_t`, `struct timespec`, and `struct _finddata_t`, whose layouts
//! the port deliberately left in C: nothing here depends on a host layout.
//!
//! The marshalling path stays in C. It reaches into a `JanetMarshalContext`,
//! and its `dup`/`fdopen` pair has a Plan 9 spelling that Zig has no target
//! for; only the mode-string reconstruction it needs moves here.

const std = @import("std");
const builtin = @import("builtin");

const windows = builtin.os.tag == .windows;

/// Mirrors the `JANET_FILE_*` flags in `src/include/janet.h`.
const file_write: i32 = 1;
const file_read: i32 = 2;
const file_append: i32 = 4;
const file_update: i32 = 8;
const file_binary: i32 = 64;
const file_nonil: i32 = 512;

/// Mirrors the `JANET_SANDBOX_FS*` flags in `src/include/janet.h`. This
/// subsystem reports which of them a mode string implies; C performs the
/// assertion, because a forbidden operation panics.
const sandbox_fs_write: u32 = 32;
const sandbox_fs_read: u32 = 64;
const sandbox_fs_temp: u32 = 1024;
const sandbox_fs: u32 = sandbox_fs_write | sandbox_fs_read | sandbox_fs_temp;

/// Mirrors the `JANET_IO_MODE_*` codes in `src/core/io.c`.
const mode_ok: i32 = 0;
const mode_bad_length: i32 = 1;
const mode_bad_first: i32 = 2;
const mode_bad_later: i32 = 3;
const mode_repeated: i32 = 4;

/// `SEEK_SET`, `SEEK_CUR`, and `SEEK_END` are 0, 1, and 2 on every platform
/// Janet builds for, but they are host constants, so the boundary carries the
/// position of the keyword in `whence_names` instead and the mapping happens
/// here.
const seek_set: c_int = 0;
const seek_cur: c_int = 1;
const seek_end: c_int = 2;

/// `_IONBF` is 2 in the POSIX C libraries and 4 in the Microsoft one.
const iofbf: c_int = 0;
const ionbf: c_int = if (windows) 4 else 2;

/// The single fd flag POSIX defines.
const fd_cloexec: c_int = 1;

const FILE = opaque {};

extern fn fopen(path: [*:0]const u8, mode: [*:0]const u8) callconv(.c) ?*FILE;
extern fn tmpfile() callconv(.c) ?*FILE;
extern fn fclose(file: *FILE) callconv(.c) c_int;
extern fn fflush(file: *FILE) callconv(.c) c_int;
extern fn fread(dest: [*]u8, size: usize, count: usize, file: *FILE) callconv(.c) usize;
extern fn fwrite(src: [*]const u8, size: usize, count: usize, file: *FILE) callconv(.c) usize;
extern fn fgetc(file: *FILE) callconv(.c) c_int;
extern fn fputc(ch: c_int, file: *FILE) callconv(.c) c_int;
extern fn ferror(file: *FILE) callconv(.c) c_int;
extern fn setvbuf(file: *FILE, buffer: ?[*]u8, mode: c_int, size: usize) callconv(.c) c_int;
extern fn fileno(file: *FILE) callconv(.c) c_int;

extern fn fseek(file: *FILE, offset: c_long, whence: c_int) callconv(.c) c_int;
extern fn ftell(file: *FILE) callconv(.c) c_long;

/// Janet redirects `fseek` and `ftell` to the 64-bit Microsoft variants, so the
/// port calls what the C implementation calls rather than the narrow ones.
extern fn _fseeki64(file: *FILE, offset: i64, whence: c_int) callconv(.c) c_int;
extern fn _ftelli64(file: *FILE) callconv(.c) i64;

comptime {
    @export(&scanMode, .{ .name = "janet_io_scan_mode" });
    @export(&seekWhence, .{ .name = "janet_io_seek_whence" });
    @export(&modeFromFlags, .{ .name = "janet_io_mode_from_flags" });
    @export(&open, .{ .name = "janet_io_open" });
    @export(&temp, .{ .name = "janet_io_temp" });
    @export(&close, .{ .name = "janet_io_close" });
    @export(&flush, .{ .name = "janet_io_flush" });
    @export(&read, .{ .name = "janet_io_read" });
    @export(&write, .{ .name = "janet_io_write" });
    @export(&getChar, .{ .name = "janet_io_getc" });
    @export(&putChar, .{ .name = "janet_io_putc" });
    @export(&err, .{ .name = "janet_io_error" });
    @export(&setBufferSize, .{ .name = "janet_io_setvbuf" });
    @export(&seek, .{ .name = "janet_io_seek" });
    @export(&tell, .{ .name = "janet_io_tell" });
    if (!windows) {
        @export(&setCloexec, .{ .name = "janet_io_set_cloexec" });
    }
}

/// Classify an `file/open` mode string.
///
/// Reports the flag word, the sandbox permissions the accepted prefix implies,
/// and where the scan stopped. C asserts the permissions and raises the errors,
/// so ordering matters: the permissions accumulate only over the bytes the C
/// loop would have reached before stopping, which is what lets C assert them
/// before reporting a later bad byte and reproduce the original interleaving.
///
/// A repeated flag yields a flag word of -1, which is what the C implementation
/// returned and what its caller then used as a flag word. That is recorded in
/// `FOUND.md` as a defect and reproduced rather than fixed.
fn scanMode(
    mode: [*]const u8,
    len: i32,
    flags_out: *i32,
    sandbox_out: *u32,
    index_out: *i32,
) callconv(.c) i32 {
    flags_out.* = 0;
    sandbox_out.* = 0;
    index_out.* = 0;
    if (len < 1 or len > 10) return mode_bad_length;

    var flags: i32 = 0;
    switch (mode[0]) {
        'w' => {
            flags |= file_write;
            sandbox_out.* |= sandbox_fs_write;
        },
        'a' => {
            flags |= file_append;
            sandbox_out.* |= sandbox_fs;
        },
        'r' => {
            flags |= file_read;
            sandbox_out.* |= sandbox_fs_read;
        },
        else => return mode_bad_first,
    }

    var index: i32 = 1;
    while (index < len) : (index += 1) {
        index_out.* = index;
        switch (mode[@intCast(index)]) {
            '+' => {
                if (flags & file_update != 0) return repeated(flags_out);
                sandbox_out.* |= sandbox_fs_write;
                flags |= file_update;
            },
            'b' => {
                if (flags & file_binary != 0) return repeated(flags_out);
                flags |= file_binary;
            },
            'n' => {
                if (flags & file_nonil != 0) return repeated(flags_out);
                flags |= file_nonil;
            },
            else => return mode_bad_later,
        }
    }

    flags_out.* = flags;
    return mode_ok;
}

fn repeated(flags_out: *i32) i32 {
    flags_out.* = -1;
    return mode_repeated;
}

const whence_names = [_][:0]const u8{ "cur", "set", "end" };

/// Find a seek origin by keyword, returning its position or -1.
///
/// The comparison reproduces `janet_cstrcmp`, which the C implementation used
/// here, including its treatment of a key whose own bytes end in NUL.
fn seekWhence(key: [*]const u8, len: i32) callconv(.c) i32 {
    if (len < 0) return -1;
    for (whence_names, 0..) |name, index| {
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

/// Rebuild the `fopen` mode a flag word came from, for reattaching a marshalled
/// descriptor. Writes at most three bytes plus a terminator into `out` and
/// returns the length.
///
/// This is not the inverse of `scanMode`: it drops the binary, update, and
/// no-nil flags, and it collapses append and write, because the C
/// implementation only needed a mode `fdopen` would accept.
fn modeFromFlags(flags: i32, out: *[4]u8) callconv(.c) i32 {
    out.* = .{ 0, 0, 0, 0 };
    var len: usize = 0;
    if (flags & file_read != 0) {
        out[len] = 'r';
        len += 1;
    }
    if (flags & file_append != 0) {
        out[len] = 'a';
        len += 1;
    } else if (flags & file_write != 0) {
        out[len] = 'w';
        len += 1;
    }
    return @intCast(len);
}

fn open(path: [*:0]const u8, mode: [*:0]const u8) callconv(.c) ?*anyopaque {
    return @ptrCast(fopen(path, mode));
}

fn temp() callconv(.c) ?*anyopaque {
    return @ptrCast(tmpfile());
}

fn close(handle: *anyopaque) callconv(.c) i32 {
    return fclose(stream(handle));
}

fn flush(handle: *anyopaque) callconv(.c) i32 {
    return fflush(stream(handle));
}

/// Read up to `count` bytes, reporting how many arrived. A short read is not by
/// itself a failure, which is why C consults `janet_io_error` afterwards.
fn read(handle: *anyopaque, dest: [*]u8, count: usize) callconv(.c) usize {
    return fread(dest, 1, count, stream(handle));
}

/// Write `count` bytes as a single item, so the result is 1 on success and 0 on
/// failure. C compares against 1, as it did with `fwrite` directly.
fn write(handle: *anyopaque, src: [*]const u8, count: usize) callconv(.c) i32 {
    return @intCast(fwrite(src, count, 1, stream(handle)));
}

/// Read one byte, or return `EOF`.
fn getChar(handle: *anyopaque) callconv(.c) i32 {
    return fgetc(stream(handle));
}

fn putChar(handle: *anyopaque, ch: i32) callconv(.c) i32 {
    return fputc(ch, stream(handle));
}

fn err(handle: *anyopaque) callconv(.c) i32 {
    return ferror(stream(handle));
}

/// Select full buffering of `size` bytes, or no buffering when `size` is zero.
fn setBufferSize(handle: *anyopaque, size: usize) callconv(.c) i32 {
    return setvbuf(stream(handle), null, if (size != 0) iofbf else ionbf, size);
}

/// Move the file position, with `whence` given as a position in
/// `whence_names`. An unrecognized origin cannot reach here: C rejects it while
/// it still holds the keyword to name in the panic.
fn seek(handle: *anyopaque, offset: i64, whence: i32) callconv(.c) i32 {
    const origin: c_int = switch (whence) {
        0 => seek_cur,
        1 => seek_set,
        else => seek_end,
    };
    if (windows) return _fseeki64(stream(handle), offset, origin);
    // A 32-bit `long` narrows the offset here exactly as the C
    // implementation's implicit conversion did.
    return fseek(stream(handle), @truncate(offset), origin);
}

fn tell(handle: *anyopaque) callconv(.c) i64 {
    if (windows) return _ftelli64(stream(handle));
    return ftell(stream(handle));
}

/// Close the stream's descriptor across an exec. `fopen` has no standard flag
/// for this, which is why the C implementation set it separately.
fn setCloexec(handle: *anyopaque) callconv(.c) i32 {
    return std.c.fcntl(fileno(stream(handle)), std.c.F.SETFD, fd_cloexec);
}

fn stream(handle: *anyopaque) *FILE {
    return @ptrCast(handle);
}

fn scan(mode: []const u8) struct { status: i32, flags: i32, sandbox: u32, index: i32 } {
    var flags: i32 = 0;
    var sandbox: u32 = 0;
    var index: i32 = 0;
    const status = scanMode(mode.ptr, @intCast(mode.len), &flags, &sandbox, &index);
    return .{ .status = status, .flags = flags, .sandbox = sandbox, .index = index };
}

test "mode scanning accepts the documented flags" {
    const r = scan("r");
    try std.testing.expectEqual(mode_ok, r.status);
    try std.testing.expectEqual(file_read, r.flags);
    try std.testing.expectEqual(sandbox_fs_read, r.sandbox);

    const wbn = scan("wbn");
    try std.testing.expectEqual(mode_ok, wbn.status);
    try std.testing.expectEqual(file_write | file_binary | file_nonil, wbn.flags);
    try std.testing.expectEqual(sandbox_fs_write, wbn.sandbox);

    const ap = scan("a+");
    try std.testing.expectEqual(mode_ok, ap.status);
    try std.testing.expectEqual(file_append | file_update, ap.flags);
    try std.testing.expectEqual(sandbox_fs | sandbox_fs_write, ap.sandbox);
}

test "mode scanning reports where it stopped" {
    try std.testing.expectEqual(mode_bad_length, scan("").status);
    try std.testing.expectEqual(mode_bad_length, scan("rbbbbbbbbbb").status);
    try std.testing.expectEqual(mode_bad_first, scan("q").status);
    try std.testing.expectEqual(@as(i32, 0), scan("q").index);

    const later = scan("r+q");
    try std.testing.expectEqual(mode_bad_later, later.status);
    try std.testing.expectEqual(@as(i32, 2), later.index);
    try std.testing.expectEqual(sandbox_fs_read | sandbox_fs_write, later.sandbox);
}

test "a repeated flag yields the flag word the C implementation returned" {
    for ([_][]const u8{ "r++", "rbb", "rnn" }) |mode| {
        const result = scan(mode);
        try std.testing.expectEqual(mode_repeated, result.status);
        try std.testing.expectEqual(@as(i32, -1), result.flags);
    }
    // The prefix before the repeat still reports its permissions, because the
    // C loop asserted them before reaching the repeated byte.
    try std.testing.expectEqual(sandbox_fs_read | sandbox_fs_write, scan("r++").sandbox);
    try std.testing.expectEqual(sandbox_fs_read, scan("rbb").sandbox);
}

test "seek origins match whole keywords only" {
    try std.testing.expectEqual(@as(i32, 0), seekWhence("cur", 3));
    try std.testing.expectEqual(@as(i32, 1), seekWhence("set", 3));
    try std.testing.expectEqual(@as(i32, 2), seekWhence("end", 3));
    try std.testing.expectEqual(@as(i32, -1), seekWhence("cu", 2));
    try std.testing.expectEqual(@as(i32, -1), seekWhence("current", 7));
    try std.testing.expectEqual(@as(i32, -1), seekWhence("", 0));
}

test "mode reconstruction collapses append over write" {
    var out: [4]u8 = undefined;
    try std.testing.expectEqual(@as(i32, 2), modeFromFlags(file_read | file_write, &out));
    try std.testing.expectEqualStrings("rw", out[0..2]);
    try std.testing.expectEqual(@as(u8, 0), out[2]);

    try std.testing.expectEqual(@as(i32, 2), modeFromFlags(file_read | file_write | file_append, &out));
    try std.testing.expectEqualStrings("ra", out[0..2]);

    try std.testing.expectEqual(@as(i32, 1), modeFromFlags(file_append | file_binary, &out));
    try std.testing.expectEqualStrings("a", out[0..1]);

    try std.testing.expectEqual(@as(i32, 0), modeFromFlags(file_binary, &out));
    try std.testing.expectEqual(@as(u8, 0), out[0]);
}
