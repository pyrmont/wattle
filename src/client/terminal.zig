//! The terminal the line editor runs on: raw mode, the size, and the reads
//! and writes, for POSIX and for the Windows console.
//!
//! `prompt.zig` is the only importer. The editor reads standard input and
//! draws on standard error, where the plain reader writes its prompt, so
//! standard output can be redirected while the editor is in use.
//!
//! ## Raw mode
//!
//! - On POSIX, raw mode clears `ICANON`, `ECHO`, `ISIG` and `IEXTEN`, so each
//!   key arrives as it is pressed and Ctrl-C and Ctrl-Z arrive as bytes. It
//!   clears `ICRNL`, so Enter and Ctrl-J are different bytes, and `OPOST`, so
//!   the editor's `\r\n` is written as it stands. The change waits for output
//!   to drain and keeps pending input, so keys typed before the prompt are
//!   read rather than discarded.
//!
//! - On Windows, raw mode sets `ENABLE_VIRTUAL_TERMINAL_INPUT` on the input
//!   handle and `ENABLE_VIRTUAL_TERMINAL_PROCESSING` on the output handle, and
//!   sets both code pages to UTF-8. The console then sends and interprets the
//!   same escape sequences as a POSIX terminal. Where the console refuses a
//!   mode, `enter` reports it and the editor is not used.
//!
//! - The modes in effect before `enter` are restored by `leave`, and by an
//!   `atexit` handler if the process exits while a line is open.
//!
//! - `enter` turns on bracketed paste, so the terminal marks where pasted
//!   text begins and ends, and `leave` turns it off. Both are written to
//!   standard error, so the mode is on exactly while raw mode is.
//!
//! A size change is read at the next frame, since `columns` and `rows` are
//! asked before each one. Nothing redraws on the signal itself.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");
const builtin = @import("builtin");

// ==========================================================================
// Project imports
// ==========================================================================

const c = @import("cabi");

// ==========================================================================
// Constants
// ==========================================================================

/// Whether this target is Windows, which has the console arm.
const windows = builtin.os.tag == .windows;

/// The descriptors the POSIX arm reads and draws on.
const input_fd: c_int = 0;
const output_fd: c_int = 2;

/// The Windows standard handle numbers and console mode bits `enter` sets.
const std_input_handle: u32 = @bitCast(@as(i32, -10));
const std_error_handle: u32 = @bitCast(@as(i32, -12));
const enable_processed_output: u32 = 0x0001;
const enable_virtual_terminal_processing: u32 = 0x0004;
const disable_newline_auto_return: u32 = 0x0008;
const enable_virtual_terminal_input: u32 = 0x0200;
const utf8_code_page: u32 = 65001;

/// The modes `enter` replaced, or null while the terminal is not in raw
/// mode.
var saved: ?Saved = null;

/// Whether the `atexit` handler has been registered.
var registered = false;

// ==========================================================================
// Types
// ==========================================================================

/// The modes in effect before raw mode, which `leave` restores.
///
/// On POSIX `termios` is the input descriptor's settings. On Windows the four
/// fields are the two console modes and the two code pages.
const Saved = if (windows) struct {
    input_mode: u32,
    output_mode: u32,
    input_code_page: u32,
    output_code_page: u32,
} else struct {
    termios: std.c.termios,
};

// ==========================================================================
// Public functions
// ==========================================================================

/// Returns the terminal's width in columns, or 0 when it cannot be read.
///
/// A width of 0 is what some terminals report, and the session takes it as
/// 80.
pub fn columns() usize {
    if (windows) {
        var info: c.ConsoleScreenBufferInfo = undefined;
        if (c.GetConsoleScreenBufferInfo(c.GetStdHandle(std_error_handle), &info) == 0) return 0;
        const width = @as(i32, info.srWindow[2]) - @as(i32, info.srWindow[0]) + 1;
        return if (width > 0) @intCast(width) else 0;
    }
    var size: std.c.winsize = undefined;
    if (std.c.ioctl(output_fd, std.c.T.IOCGWINSZ, &size) == -1) return 0;
    return size.col;
}

/// Returns the terminal's height in rows, or 0 when it cannot be read.
///
/// The session takes 0 as no limit on the rows a frame draws.
pub fn rows() usize {
    if (windows) {
        var info: c.ConsoleScreenBufferInfo = undefined;
        if (c.GetConsoleScreenBufferInfo(c.GetStdHandle(std_error_handle), &info) == 0) return 0;
        const height = @as(i32, info.srWindow[3]) - @as(i32, info.srWindow[1]) + 1;
        return if (height > 0) @intCast(height) else 0;
    }
    var size: std.c.winsize = undefined;
    if (std.c.ioctl(output_fd, std.c.T.IOCGWINSZ, &size) == -1) return 0;
    return size.row;
}

/// Puts the terminal in raw mode, and returns whether it is.
///
/// The result is false when standard input or standard error is not a
/// terminal, when `TERM` is `dumb`, and when the terminal refuses the mode,
/// and the terminal is then unchanged. Calling this function while in raw
/// mode returns true and changes nothing.
pub fn enter() bool {
    if (saved != null) return true;
    if (!registered) {
        registered = true;
        _ = c.atexit(restoreAtExit);
    }
    const entered = if (windows) enterWindows() else enterPosix();
    if (entered) write("\x1b[?2004h");
    return entered;
}

/// Restores the modes `enter` replaced.
///
/// Calling this function when not in raw mode changes nothing.
pub fn leave() void {
    const previous = saved orelse return;
    saved = null;
    write("\x1b[?2004l");
    if (windows) {
        const input = c.GetStdHandle(std_input_handle);
        const output = c.GetStdHandle(std_error_handle);
        _ = c.SetConsoleMode(input, previous.input_mode);
        _ = c.SetConsoleMode(output, previous.output_mode);
        _ = c.SetConsoleCP(previous.input_code_page);
        _ = c.SetConsoleOutputCP(previous.output_code_page);
    } else {
        _ = std.c.tcsetattr(input_fd, .DRAIN, &previous.termios);
    }
}

/// Reads the bytes available from standard input into `bytes`, and returns
/// how many were read.
///
/// The read blocks until at least one byte is available. The result is 0 at
/// end of input and on an error. On POSIX `error.WouldBlock` is returned when
/// the descriptor has no bytes and is non-blocking. An interrupted read is
/// retried.
pub fn read(bytes: []u8) error{WouldBlock}!usize {
    if (windows) {
        var count: u32 = 0;
        const limit: u32 = @intCast(@min(bytes.len, std.math.maxInt(u32)));
        if (c.ReadFile(c.GetStdHandle(std_input_handle), bytes.ptr, limit, &count, null) == 0) return 0;
        return count;
    }
    while (true) {
        const count = c.read(input_fd, bytes.ptr, bytes.len);
        if (count >= 0) return @intCast(count);
        const errno = c.errno();
        if (errno == @intFromEnum(std.c.E.INTR)) continue;
        if (errno == @intFromEnum(std.c.E.AGAIN)) return error.WouldBlock;
        return 0;
    }
}

/// Writes all of `bytes` to standard error, the terminal the editor draws
/// on.
///
/// A write that fails is abandoned, and what was not written is lost. An
/// interrupted write is retried.
pub fn write(bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        if (windows) {
            var count: u32 = 0;
            const limit: u32 = @intCast(@min(rest.len, std.math.maxInt(u32)));
            if (c.WriteFile(c.GetStdHandle(std_error_handle), rest.ptr, limit, &count, null) == 0) return;
            rest = rest[count..];
            continue;
        }
        const count = c.write(output_fd, rest.ptr, rest.len);
        if (count < 0) {
            if (c.errno() == @intFromEnum(std.c.E.INTR)) continue;
            return;
        }
        rest = rest[@intCast(count)..];
    }
}

// ==========================================================================
// Private functions
// ==========================================================================

/// The POSIX arm of `enter`.
fn enterPosix() bool {
    if (c.isatty(input_fd) == 0 or c.isatty(output_fd) == 0) return false;
    if (c.getenv("TERM")) |term| {
        if (std.mem.eql(u8, std.mem.span(term), "dumb")) return false;
    }
    var original: std.c.termios = undefined;
    if (std.c.tcgetattr(input_fd, &original) != 0) return false;
    var raw = original;
    raw.iflag.BRKINT = false;
    raw.iflag.ICRNL = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.IXON = false;
    raw.oflag.OPOST = false;
    raw.cflag.CSIZE = .CS8;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.IEXTEN = false;
    raw.lflag.ISIG = false;
    raw.cc[@intFromEnum(std.c.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.c.V.TIME)] = 0;
    if (std.c.tcsetattr(input_fd, .DRAIN, &raw) != 0) return false;
    saved = .{ .termios = original };
    return true;
}

/// The Windows arm of `enter`.
fn enterWindows() bool {
    const input = c.GetStdHandle(std_input_handle);
    const output = c.GetStdHandle(std_error_handle);
    var input_mode: u32 = 0;
    var output_mode: u32 = 0;
    if (c.GetConsoleMode(input, &input_mode) == 0) return false;
    if (c.GetConsoleMode(output, &output_mode) == 0) return false;
    if (c.SetConsoleMode(input, enable_virtual_terminal_input) == 0) return false;
    const drawing = output_mode | enable_processed_output | enable_virtual_terminal_processing | disable_newline_auto_return;
    if (c.SetConsoleMode(output, drawing) == 0) {
        _ = c.SetConsoleMode(input, input_mode);
        return false;
    }
    saved = .{
        .input_mode = input_mode,
        .output_mode = output_mode,
        .input_code_page = c.GetConsoleCP(),
        .output_code_page = c.GetConsoleOutputCP(),
    };
    _ = c.SetConsoleCP(utf8_code_page);
    _ = c.SetConsoleOutputCP(utf8_code_page);
    return true;
}

/// Restores the terminal when the process exits while a line is open.
fn restoreAtExit() callconv(.c) void {
    leave();
}
