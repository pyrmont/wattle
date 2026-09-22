//! One line being edited on the terminal: the decoder, the editor, the
//! frames drawn for them, and the output written above the line meanwhile.
//!
//! `src/client/prompt.zig` owns a `Session`. It passes the bytes it reads to
//! `feed` and the bytes a program writes to `above`, and writes what `take`
//! returns to the terminal after each call. The session never reads or writes
//! the terminal itself, so it runs the same whether the bytes come from the
//! event loop or from a blocking read, and a test drives it with neither.
//!
//! ## Output above the line
//!
//! While a line is open, output a program writes to the terminal goes
//! through `above`. Each complete line of it is written above the line being
//! edited: the frame is erased, the output is written, and the frame is drawn
//! again beneath it.
//!
//! - Output after its last newline is held. It is written when a later write
//!   completes it, or when the line ends, after the line's own row break.
//!   Writing a partial line above the frame would leave the next frame drawn
//!   on the same row.
//!
//! - Each newline in the output is written as `\r\n`, because raw mode stops
//!   the terminal from adding the carriage return.
//!
//! ## Typeahead
//!
//! Bytes that arrive after the key that ends a line are kept, and `begin`
//! applies them to the next line before it waits for more.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const editor_mod = @import("editor.zig");
const keys = @import("keys.zig");
const render = @import("render.zig");

// ==========================================================================
// Types
// ==========================================================================

/// How a line ended: `editor.zig`'s outcomes without the two that leave a
/// line open.
///
/// `Session.begin` and `Session.feed` return an `End`, and `Session.close`
/// takes one.
pub const End = enum { submit, eof, cancel };

/// The terminal's size, in columns and rows.
///
/// `Session.begin`, `Session.feed` and `Session.above` take a `Size`. A
/// `columns` of 0, which some terminals report, is taken as 80, and a `rows`
/// of 0 is taken as no limit on the rows a frame draws.
pub const Size = struct {
    columns: usize,
    rows: usize = 0,
};

/// One line being edited, and what outlives it: the typeahead and the
/// allocations.
///
/// `init` returns a `Session` and `deinit` releases it. `editor` has the
/// buffer and the cursor, `prompt` a copy of the prompt, `output` the bytes
/// for the terminal that `take` has not returned, `held` the output after its
/// last newline, and `typeahead` the bytes after the key that ended the last
/// line. `climb` is `render.zig`'s climb and `top` the first row of its
/// window, `size` is the size the last frame was drawn at, and `open` is
/// whether a line is being edited.
pub const Session = struct {
    allocator: std.mem.Allocator,
    decoder: keys.Decoder = .{},
    editor: editor_mod.Editor,
    prompt: std.ArrayList(u8) = .empty,
    output: std.Io.Writer.Allocating,
    held: std.ArrayList(u8) = .empty,
    typeahead: std.ArrayList(u8) = .empty,
    climb: usize = 0,
    top: usize = 0,
    size: Size = .{ .columns = 80 },
    open: bool = false,

    /// Returns a session with no line open, whose allocations `allocator`
    /// holds.
    pub fn init(allocator: std.mem.Allocator) Session {
        return .{
            .allocator = allocator,
            .editor = .init(allocator),
            .output = .init(allocator),
        };
    }

    /// Releases every allocation.
    pub fn deinit(session: *Session) void {
        session.editor.deinit();
        session.prompt.deinit(session.allocator);
        session.output.deinit();
        session.held.deinit(session.allocator);
        session.typeahead.deinit(session.allocator);
    }

    /// Opens a line with `prompt`, draws its first frame, and applies the
    /// typeahead.
    ///
    /// `size` is the terminal's size. The result is how the line ended when
    /// the typeahead ended it, and null when the line is open. This function
    /// returns `error.OutOfMemory` when an allocation fails, with no line
    /// open.
    pub fn begin(session: *Session, prompt: []const u8, size: Size) error{OutOfMemory}!?End {
        session.editor.clear();
        session.decoder = .{};
        session.climb = 0;
        session.top = 0;
        session.prompt.clearRetainingCapacity();
        try session.prompt.appendSlice(session.allocator, prompt);
        session.open = true;
        errdefer session.open = false;
        session.size = usable(size);
        try session.redraw(true);
        if (session.typeahead.items.len == 0) return null;
        const pending = try session.typeahead.toOwnedSlice(session.allocator);
        defer session.allocator.free(pending);
        return session.feed(pending, size);
    }

    /// Applies `bytes` to the open line, and returns how the line ended, or
    /// null while it is open.
    ///
    /// `size` is the terminal's size. A frame is drawn once for all of
    /// `bytes`, and not once for each key. The bytes after a key that ends
    /// the line are kept for the next `begin`. This function returns
    /// `error.OutOfMemory` when an allocation fails.
    pub fn feed(session: *Session, bytes: []const u8, size: Size) error{OutOfMemory}!?End {
        std.debug.assert(session.open);
        session.size = usable(size);
        var changed = false;
        for (bytes, 0..) |byte, i| {
            const key = session.decoder.feed(byte) orelse continue;
            const end: End = switch (try session.editor.apply(key)) {
                .unchanged => continue,
                .edited => {
                    changed = true;
                    continue;
                },
                .submit => .submit,
                .eof => .eof,
                .cancel => .cancel,
            };
            try session.typeahead.appendSlice(session.allocator, bytes[i + 1 ..]);
            try session.finish(end);
            return end;
        }
        if (changed) try session.redraw(true);
        return null;
    }

    /// Ends the open line as `end` without a key, as when the input has
    /// closed.
    ///
    /// This function returns `error.OutOfMemory` when an allocation fails.
    pub fn close(session: *Session, end: End) error{OutOfMemory}!void {
        std.debug.assert(session.open);
        try session.finish(end);
    }

    /// Writes `bytes` a program wrote to the terminal above the open line.
    ///
    /// `size` is the terminal's size. This function returns
    /// `error.OutOfMemory` when an allocation fails.
    pub fn above(session: *Session, bytes: []const u8, size: Size) error{OutOfMemory}!void {
        std.debug.assert(session.open);
        session.size = usable(size);
        try session.held.appendSlice(session.allocator, bytes);
        const last = std.mem.lastIndexOfScalar(u8, session.held.items, '\n') orelse return;
        render.erase(&session.output.writer, session.climb) catch return error.OutOfMemory;
        session.climb = 0;
        try session.writeOutput(session.held.items[0 .. last + 1]);
        session.held.replaceRangeAssumeCapacity(0, last + 1, &.{});
        try session.redraw(true);
    }

    /// Returns the line's text after it ended by submission.
    ///
    /// The result is valid until the next `begin`, and does not include a
    /// newline.
    pub fn line(session: *const Session) []const u8 {
        return session.editor.buffer.items;
    }

    /// Returns the bytes for the terminal since the last call, and forgets
    /// them.
    ///
    /// The result is valid until the next call on `session`.
    pub fn take(session: *Session) []const u8 {
        const bytes = session.output.written();
        session.output.writer.end = 0;
        return bytes;
    }

    /// Draws the last frame with the cursor at the end and every row, breaks
    /// the row, and writes the held output.
    fn finish(session: *Session, end: End) error{OutOfMemory}!void {
        session.editor.cursor = session.editor.buffer.items.len;
        try session.redraw(false);
        const out = &session.output.writer;
        (if (end == .cancel) out.writeAll("^C\r\n") else out.writeAll("\r\n")) catch return error.OutOfMemory;
        session.climb = 0;
        if (session.held.items.len > 0) {
            try session.writeOutput(session.held.items);
            session.held.clearRetainingCapacity();
        }
        session.open = false;
    }

    /// Draws a frame of the open line, within the terminal's height when
    /// `bounded` and with every row otherwise.
    fn redraw(session: *Session, bounded: bool) error{OutOfMemory}!void {
        const drawn = render.draw(&session.output.writer, session.climb, .{
            .prompt = session.prompt.items,
            .buffer = session.editor.buffer.items,
            .cursor = session.editor.cursor,
            .columns = session.size.columns,
            .height = if (bounded) session.size.rows else 0,
            .top = session.top,
        }) catch return error.OutOfMemory;
        session.climb = drawn.climb;
        session.top = drawn.top;
    }

    /// Writes program output with each bare newline as `\r\n`.
    fn writeOutput(session: *Session, bytes: []const u8) error{OutOfMemory}!void {
        const out = &session.output.writer;
        for (bytes, 0..) |byte, i| {
            if (byte == '\n' and (i == 0 or bytes[i - 1] != '\r')) out.writeByte('\r') catch return error.OutOfMemory;
            out.writeByte(byte) catch return error.OutOfMemory;
        }
    }
};

// ==========================================================================
// Private functions
// ==========================================================================

/// Returns `size` with a `columns` of 0 taken as 80.
fn usable(size: Size) Size {
    return .{ .columns = if (size.columns == 0) 80 else size.columns, .rows = size.rows };
}

// ==========================================================================
// Tests
// ==========================================================================

const w80: Size = .{ .columns = 80 };
const w8: Size = .{ .columns = 8 };

test "begin: draws the prompt" {
    var session = Session.init(std.testing.allocator);
    defer session.deinit();
    try std.testing.expectEqual(null, try session.begin("repl:1:> ", w80));
    try std.testing.expectEqualStrings("\r\x1b[Jrepl:1:> ", session.take());
    try std.testing.expectEqualStrings("", session.take());
}

test "feed: one frame for a whole read, and the last frame at submission" {
    var session = Session.init(std.testing.allocator);
    defer session.deinit();
    _ = try session.begin("repl:1:> ", w80);
    _ = session.take();
    try std.testing.expectEqual(null, try session.feed("(+ 2\x1b[D1 ", w80));
    try std.testing.expectEqualStrings("\r\x1b[Jrepl:1:> (+ 1 2\r\x1b[14C", session.take());
    try std.testing.expectEqual(End.submit, (try session.feed("\x1b[H\x1b[Fx\x7f)\r", w80)).?);
    // The keys before Enter are drawn by the last frame and not by one of
    // their own.
    try std.testing.expectEqualStrings("\r\x1b[Jrepl:1:> (+ 1 2)\r\n", session.take());
    try std.testing.expectEqualStrings("(+ 1 2)", session.line());
}

test "feed: the bytes after the end of a line are applied to the next" {
    var session = Session.init(std.testing.allocator);
    defer session.deinit();
    _ = try session.begin("> ", w80);
    try std.testing.expectEqual(End.submit, (try session.feed("a\rb", w80)).?);
    try std.testing.expectEqualStrings("a", session.line());
    try std.testing.expectEqual(null, try session.begin("> ", w80));
    try std.testing.expectEqualStrings("b", session.line());
    _ = session.take();
    try std.testing.expectEqual(End.submit, (try session.feed("\r", w80)).?);
    try std.testing.expectEqual(null, try session.begin("> ", w80));
    try std.testing.expectEqualStrings("", session.line());
}

test "feed: Ctrl-D on an empty line ends it, and Ctrl-C cancels" {
    var session = Session.init(std.testing.allocator);
    defer session.deinit();
    _ = try session.begin("> ", w80);
    try std.testing.expectEqual(End.eof, (try session.feed("\x04", w80)).?);
    _ = try session.begin("> ", w80);
    _ = session.take();
    try std.testing.expectEqual(End.cancel, (try session.feed("ab\x03", w80)).?);
    try std.testing.expectEqualStrings("\r\x1b[J> ab^C\r\n", session.take());
}

test "above: a complete line is written above the frame and the frame redrawn" {
    var session = Session.init(std.testing.allocator);
    defer session.deinit();
    _ = try session.begin("> ", w80);
    _ = try session.feed("(+ 40", w80);
    _ = session.take();
    try session.above("tick\n", w80);
    try std.testing.expectEqualStrings("\r\x1b[Jtick\r\n\r\x1b[J> (+ 40", session.take());
}

test "above: output after its last newline is held until the line ends" {
    var session = Session.init(std.testing.allocator);
    defer session.deinit();
    _ = try session.begin("> ", w80);
    _ = session.take();
    try session.above("par", w80);
    try std.testing.expectEqualStrings("", session.take());
    try session.above("tial\nrest", w80);
    try std.testing.expectEqualStrings("\r\x1b[Jpartial\r\n\r\x1b[J> ", session.take());
    _ = try session.feed("x\r", w80);
    try std.testing.expectEqualStrings("\r\x1b[J> x\r\nrest", session.take());
}

test "above: a wrapped frame is climbed before it is erased" {
    var session = Session.init(std.testing.allocator);
    defer session.deinit();
    _ = try session.begin("> ", w8);
    _ = try session.feed("abcdefgh", w8);
    _ = session.take();
    try session.above("t\n", w8);
    try std.testing.expectEqualStrings("\r\x1b[1A\x1b[Jt\r\n\r\x1b[J> abcdef\r\ngh", session.take());
}

test "feed: a line taller than the terminal is drawn in a window that follows the cursor" {
    var session = Session.init(std.testing.allocator);
    defer session.deinit();
    const small: Size = .{ .columns = 8, .rows = 2 };
    _ = try session.begin("> ", small);
    _ = session.take();
    _ = try session.feed("abcdefghijklmnopqrstuv", small);
    try std.testing.expectEqualStrings("\r\x1b[Jopqrstuv\r\n", session.take());
    _ = try session.feed("\x1b[H", small);
    try std.testing.expectEqualStrings("\r\x1b[1A\x1b[J> abcdef\r\nghijklmn\x1b[1A\r\x1b[2C", session.take());
    // The frame at submission draws every row, from the window's first row.
    try std.testing.expectEqual(End.submit, (try session.feed("\r", small)).?);
    try std.testing.expectEqualStrings("\r\x1b[J> abcdef\r\nghijklmn\r\nopqrstuv\r\n\r\n", session.take());
}
