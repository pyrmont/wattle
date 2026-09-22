//! The REPL's line editor, connected to the runtime: `getline` on a
//! terminal, and the output a program writes while a line is open.
//!
//! `interop.zig`'s `lineGetter` calls `read`, and uses the plain reader when
//! the result is null. `read` returns null in a build with `lineedit` false,
//! and when `terminal.enter` reports that standard input or standard error is
//! not a terminal that raw mode can be set on.
//!
//! ## Where the bytes come from
//!
//! The session in `lineedit/session.zig` takes bytes and returns bytes, and
//! this file is what reads and writes them. There are two _feeds_, and a
//! build compiles one of them.
//!
//! - With the event loop, on POSIX, standard input is a stream registered
//!   with the loop, level-triggered, and `read` suspends the calling fiber on
//!   it. Other fibers run between keys. Each readiness event is one read,
//!   which cannot block because the descriptor is readable. A fiber resumed
//!   by something else while it waits, such as by `ev/cancel`, ends the
//!   operation, and the operation's deinit event abandons the line.
//!
//! - Without the event loop, and on Windows with or without it, `read` reads
//!   with a blocking read until the line ends. A console handle cannot be
//!   waited on through a completion port, so on Windows the loop does not run
//!   while a line is open: another fiber's timer or output waits for the
//!   line to end, and nothing can cancel the wait.
//!
//! ## Output while a line is open
//!
//! `read` passes `io.divert` a function that gives each write to standard
//! output or standard error to the session, which writes it above the line.
//! The diversion is removed when the line ends. Standard output is diverted
//! only when it is a terminal, so a redirected standard output is written as
//! it is without the editor. The same diversion is installed by every feed,
//! although only the event loop's lets another fiber write.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");
const builtin = @import("builtin");

// ==========================================================================
// Project imports
// ==========================================================================

const buffers = subsystems.value.buffers;
const c = @import("cabi");
const config = @import("config");
const constants = @import("constants");
const ev = subsystems.ev;
const ev_stream = subsystems.ev_stream;
const gc_alloc = subsystems.gc_alloc;
const io = subsystems.io;
const lineedit = @import("lineedit");
const raise = subsystems.raise;
const repr = @import("repr");
const subsystems = @import("subsystems");
const terminal = @import("terminal.zig");
const value = subsystems.value;
const wrap = subsystems.value.wrap;

// ==========================================================================
// Constants
// ==========================================================================

/// The most bytes one read takes from the terminal.
const read_size = 256;

/// Whether this build waits on the loop for input, through the stream feed.
/// Windows reads with the blocking feed whether or not the loop is compiled.
const stream_feed = config.ev and builtin.os.tag != .windows;

/// The session every line is edited in, created at the first `read`.
var session: ?lineedit.session.Session = null;

/// The buffer `read` fills while it waits on the loop, rooted for as long as
/// it waits.
var pending_buffer: ?*buffers.Buffer = null;

/// Standard input as a stream, created at the first `read` that waits on the
/// loop and rooted for the life of the process.
var input_stream: ?*ev_stream.Stream = null;

/// Whether standard output is a terminal, read when a line is opened.
var output_is_terminal = false;

// ==========================================================================
// Public functions
// ==========================================================================

/// Reads a line on the terminal into `buffer`, after drawing `prompt`, and
/// returns what `getline` returns.
///
/// `buffer` is empty and takes the line and a newline. The result is
/// `buffer`, which is empty at end of input, or the keyword `:cancel` after
/// Ctrl-C. The result is null when the editor is not used, and the caller
/// then reads without it. With the event loop, the calling fiber is
/// suspended until the line ends.
///
/// This function raises when another line is open, and when an allocation
/// fails.
pub fn read(prompt: []const u8, buffer: *buffers.Buffer) raise.Error!?repr.Value {
    if (!config.lineedit) return null;
    const s = sessionPtr();
    if (s.open) return raise.panic("getline is already reading a line");
    if (!terminal.enter()) return null;
    output_is_terminal = c.isatty(1) != 0;
    io.divert(&divertedWrite);
    const opened = s.begin(prompt, size()) catch {
        abandon();
        return raise.panic("out of memory");
    };
    flush();
    if (opened) |end| return try finish(end, buffer);
    if (stream_feed) return awaitStream(buffer);
    return try readBlocking(buffer);
}

// ==========================================================================
// Private functions
// ==========================================================================

/// Ends an open line with no value to return, as when the fiber waiting on it
/// has been cancelled.
///
/// The line is drawn as cancelled, the terminal restored, and the root on
/// the buffer dropped.
fn abandon() void {
    const s = sessionPtr();
    if (s.open) s.close(.cancel) catch {};
    flush();
    restore();
    release();
}

/// Applies the bytes one read returned, and returns how the line ended, or
/// null while it is open.
///
/// Empty `bytes` is end of input. This function raises when an allocation
/// fails.
fn apply(bytes: []const u8) raise.Error!?lineedit.session.End {
    const s = sessionPtr();
    const end: ?lineedit.session.End = if (bytes.len == 0) blk: {
        s.close(.eof) catch return raise.panic("out of memory");
        break :blk .eof;
    } else s.feed(bytes, size()) catch return raise.panic("out of memory");
    flush();
    return end;
}

/// Waits on the loop for the line, with standard input as a stream.
///
/// The fiber is resumed with the value `finish` returns. This function
/// raises what making the stream raises.
fn awaitStream(buffer: *buffers.Buffer) raise.Error!?repr.Value {
    const stream = try inputStream();
    hold(buffer);
    return ev.asyncStart(stream, constants.AsyncMode.reading, onStreamEvent, null);
}

/// Gives a write to standard output or standard error to the open line.
///
/// This is the `io.Diversion` `read` installs. The result is null for a write
/// to standard output when that is not a terminal, and for any write when no
/// line is open, and the stream then takes the bytes.
fn divertedWrite(stream: io.Standard, bytes: []const u8) ?bool {
    if (stream == .out and !output_is_terminal) return null;
    const s = sessionPtr();
    if (!s.open) return null;
    s.above(bytes, size()) catch return false;
    flush();
    return true;
}

/// Finishes a line that has ended as `end`, and returns what `getline`
/// returns.
///
/// The session's last bytes are written before the terminal leaves raw mode,
/// so they are written as the session produced them. This function raises
/// when `buffer` cannot take the line.
fn finish(end: lineedit.session.End, buffer: *buffers.Buffer) raise.Error!repr.Value {
    flush();
    restore();
    release();
    switch (end) {
        .submit => {
            try buffers.pushBytes(buffer, sessionPtr().line());
            try buffers.pushU8(buffer, '\n');
            return wrap.fromBuffer(buffer);
        },
        .eof => return wrap.fromBuffer(buffer),
        .cancel => return value.fromBytes("cancel", .keyword),
    }
}

/// Writes the bytes the session has produced to the terminal.
fn flush() void {
    terminal.write(sessionPtr().take());
}

/// Roots `buffer` for as long as `read` waits on the loop.
fn hold(buffer: *buffers.Buffer) void {
    gc_alloc.gcroot(wrap.fromBuffer(buffer));
    pending_buffer = buffer;
}

/// Returns standard input as a stream, creating it at the first call.
///
/// The stream is level-triggered, so a readiness event that is not drained
/// is delivered again, and it never closes the descriptor. This function
/// raises when the loop refuses the descriptor.
fn inputStream() raise.Error!*ev_stream.Stream {
    if (input_stream) |stream| return stream;
    const flags: u32 = @intCast(constants.stream_readable | constants.stream_not_closeable);
    const stream = try ev.makeStream(0, flags, null);
    gc_alloc.gcroot(wrap.fromAbstract(stream));
    try ev.levelTriggeredStream(stream);
    input_stream = stream;
    return stream;
}

/// Receives the loop's events for the stream `awaitStream` waits on.
///
/// This is the operation's callback. A read event reads once and applies the
/// bytes, and the line's end resumes the fiber and ends the operation. A
/// hang-up, an error or a close ends the line as end of input. The deinit
/// event with a line still open is the fiber being cancelled, and the line is
/// abandoned. This function raises what `finish` raises.
fn onStreamEvent(op: *ev_stream.Operation, event: ev.AsyncEvent) raise.Error!void {
    switch (event) {
        .read, .hup => {
            var bytes: [read_size]u8 = undefined;
            const count = terminal.read(&bytes) catch return;
            const end = try apply(bytes[0..count]) orelse return;
            try resumeStream(op, end);
        },
        .err, .close => try resumeStream(op, (try apply(&.{})).?),
        .deinit => if (sessionPtr().open) abandon(),
        else => {},
    }
}

/// Reads with blocking reads until the line ends, for a build without the
/// loop.
///
/// This function raises what `finish` raises.
fn readBlocking(buffer: *buffers.Buffer) raise.Error!repr.Value {
    while (true) {
        var bytes: [read_size]u8 = undefined;
        const count = terminal.read(&bytes) catch continue;
        const end = try apply(bytes[0..count]) orelse continue;
        return finish(end, buffer);
    }
}

/// Drops the root on the buffer `hold` rooted.
fn release() void {
    const buffer = pending_buffer orelse return;
    pending_buffer = null;
    _ = gc_alloc.gcunroot(wrap.fromBuffer(buffer));
}

/// Takes the terminal out of raw mode and removes the diversion.
fn restore() void {
    terminal.leave();
    io.divert(null);
}

/// Resumes the fiber waiting on `op` with the line that ended as `end`, and
/// ends the operation.
///
/// This function raises what `finish` raises.
fn resumeStream(op: *ev_stream.Operation, end: lineedit.session.End) raise.Error!void {
    const buffer = pending_buffer.?;
    const result = try finish(end, buffer);
    ev.schedule(op.fiber, result);
    ev.asyncEnd(op);
}

/// Returns the session, creating it at the first call.
fn sessionPtr() *lineedit.session.Session {
    if (session == null) session = .init(std.heap.c_allocator);
    return &session.?;
}

/// Returns the terminal's size as the session takes it.
fn size() lineedit.session.Size {
    return .{ .columns = terminal.columns(), .rows = terminal.rows() };
}
