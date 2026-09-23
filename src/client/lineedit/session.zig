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
//!
//! ## History
//!
//! `begin` takes the `history.History` a line browses, or null for a line
//! with none. Up on the first row and Down on the last load the older and the
//! newer entry, with the cursor at its end. Without a history they change
//! nothing. The session does not record a submitted line; its owner does.
//!
//! ## Bracketed paste
//!
//! A paste can submit several lines, and its bytes can be split across reads
//! at any point, so the editor's paste flag lasts from the start marker to the
//! end marker whatever lines begin and end between them. A line that ends by
//! Ctrl-C or Ctrl-D clears it, so a paste whose end marker never arrives is
//! ended by the user rather than affecting every line after it.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const editor_mod = @import("editor.zig");
const history_mod = @import("history.zig");
const keys = @import("keys.zig");
const layout = @import("layout.zig");
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
/// line. `history` is the history the open line browses, or null. `climb` is
/// `render.zig`'s climb and `top` the first row of its window, `size` is the
/// size the last frame was drawn at, and `open` is whether a line is being
/// edited.
pub const Session = struct {
    allocator: std.mem.Allocator,
    decoder: keys.Decoder = .{},
    editor: editor_mod.Editor,
    prompt: std.ArrayList(u8) = .empty,
    output: std.Io.Writer.Allocating,
    held: std.ArrayList(u8) = .empty,
    typeahead: std.ArrayList(u8) = .empty,
    history: ?*history_mod.History = null,
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
    /// `size` is the terminal's size, and `finished` decides what Enter does
    /// on this line, as `editor.Editor.finished` does. `history` is what Up
    /// and Down browse beyond the buffer's first and last rows, or null for
    /// nothing, and is reset here and when the line ends. The result is how the
    /// line ended when the typeahead ended it, and null when the line is
    /// open. This function returns `error.OutOfMemory` when an allocation
    /// fails, with no line open.
    pub fn begin(session: *Session, prompt: []const u8, size: Size, finished: ?editor_mod.Finished, history: ?*history_mod.History) error{OutOfMemory}!?End {
        session.editor.clear();
        session.editor.finished = finished;
        session.history = history;
        if (history) |h| h.reset();
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
            const outcome = switch (key) {
                .up => try session.vertical(true),
                .down => try session.vertical(false),
                else => try session.editor.apply(key),
            };
            const end: End = switch (outcome) {
                .unchanged, .beyond => continue,
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

    /// Returns the layout the open line is drawn with.
    fn geometry(session: *const Session) layout.Geometry {
        return render.geometryOf(session.prompt.items, session.size.columns);
    }

    /// Applies Up, when `up`, or Down, and loads the older or the newer entry
    /// of the history when the move is beyond the buffer.
    fn vertical(session: *Session, up: bool) error{OutOfMemory}!editor_mod.Outcome {
        const outcome = session.editor.vertical(session.geometry(), up);
        if (outcome != .beyond) return outcome;
        const history = session.history orelse return .unchanged;
        const text = try history.step(session.editor.buffer.items, up) orelse return .unchanged;
        try session.editor.replace(text);
        return .edited;
    }

    /// Draws the last frame with the cursor at the end and every row, breaks
    /// the row, and writes the held output.
    fn finish(session: *Session, end: End) error{OutOfMemory}!void {
        if (session.history) |h| h.reset();
        if (end != .submit) session.editor.pasting = false;
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
    try std.testing.expectEqual(null, try session.begin("repl:1:> ", w80, null, null));
    try std.testing.expectEqualStrings("\r\x1b[Jrepl:1:> ", session.take());
    try std.testing.expectEqualStrings("", session.take());
}

test "feed: one frame for a whole read, and the last frame at submission" {
    var session = Session.init(std.testing.allocator);
    defer session.deinit();
    _ = try session.begin("repl:1:> ", w80, null, null);
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
    _ = try session.begin("> ", w80, null, null);
    try std.testing.expectEqual(End.submit, (try session.feed("a\rb", w80)).?);
    try std.testing.expectEqualStrings("a", session.line());
    try std.testing.expectEqual(null, try session.begin("> ", w80, null, null));
    try std.testing.expectEqualStrings("b", session.line());
    _ = session.take();
    try std.testing.expectEqual(End.submit, (try session.feed("\r", w80)).?);
    try std.testing.expectEqual(null, try session.begin("> ", w80, null, null));
    try std.testing.expectEqualStrings("", session.line());
}

test "feed: Ctrl-D on an empty line ends it, and Ctrl-C cancels" {
    var session = Session.init(std.testing.allocator);
    defer session.deinit();
    _ = try session.begin("> ", w80, null, null);
    try std.testing.expectEqual(End.eof, (try session.feed("\x04", w80)).?);
    _ = try session.begin("> ", w80, null, null);
    _ = session.take();
    try std.testing.expectEqual(End.cancel, (try session.feed("ab\x03", w80)).?);
    try std.testing.expectEqualStrings("\r\x1b[J> ab^C\r\n", session.take());
}

test "above: a complete line is written above the frame and the frame redrawn" {
    var session = Session.init(std.testing.allocator);
    defer session.deinit();
    _ = try session.begin("> ", w80, null, null);
    _ = try session.feed("(+ 40", w80);
    _ = session.take();
    try session.above("tick\n", w80);
    try std.testing.expectEqualStrings("\r\x1b[Jtick\r\n\r\x1b[J> (+ 40", session.take());
}

test "above: output after its last newline is held until the line ends" {
    var session = Session.init(std.testing.allocator);
    defer session.deinit();
    _ = try session.begin("> ", w80, null, null);
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
    _ = try session.begin("> ", w8, null, null);
    _ = try session.feed("abcdefgh", w8);
    _ = session.take();
    try session.above("t\n", w8);
    try std.testing.expectEqualStrings("\r\x1b[1A\x1b[Jt\r\n\r\x1b[J> abcdef\r\ngh", session.take());
}

test "feed: a line taller than the terminal is drawn in a window that follows the cursor" {
    var session = Session.init(std.testing.allocator);
    defer session.deinit();
    const small: Size = .{ .columns = 8, .rows = 2 };
    _ = try session.begin("> ", small, null, null);
    _ = session.take();
    _ = try session.feed("abcdefghijklmnopqrstuv", small);
    try std.testing.expectEqualStrings("\r\x1b[Jopqrstuv\r\n", session.take());
    _ = try session.feed("\x1b[H", small);
    try std.testing.expectEqualStrings("\r\x1b[1A\x1b[J> abcdef\r\nghijklmn\x1b[1A\r\x1b[2C", session.take());
    // The frame at submission draws every row, from the window's first row.
    try std.testing.expectEqual(End.submit, (try session.feed("\r", small)).?);
    try std.testing.expectEqualStrings("\r\x1b[J> abcdef\r\nghijklmn\r\nopqrstuv\r\n\r\n", session.take());
}

/// The `Finished` the REPL's parser would give for the tests: the buffer is
/// finished when it has as many `)` as `(`.
fn balanced(text: []const u8) bool {
    return std.mem.count(u8, text, "(") == std.mem.count(u8, text, ")");
}

test "feed: Enter on an unfinished form opens a row under the marker" {
    var session = Session.init(std.testing.allocator);
    defer session.deinit();
    _ = try session.begin("repl:1:> ", w80, &balanced, null);
    _ = session.take();
    try std.testing.expectEqual(null, try session.feed("(+ 1\r", w80));
    try std.testing.expectEqualStrings("\r\x1b[Jrepl:1:> (+ 1\r\n         ", session.take());
    try std.testing.expectEqual(End.submit, (try session.feed("2)\r", w80)).?);
    try std.testing.expectEqualStrings("\r\x1b[1A\x1b[Jrepl:1:> (+ 1\r\n         2)\r\n", session.take());
    try std.testing.expectEqualStrings("(+ 1\n2)", session.line());
}

test "feed: Up moves to the row above, and Enter there submits the whole form" {
    var session = Session.init(std.testing.allocator);
    defer session.deinit();
    _ = try session.begin("> ", w80, &balanced, null);
    _ = try session.feed("(+ 1\r2)\x1b[A", w80);
    // Column 4 on the row above is the space after `+`.
    try std.testing.expectEqual(@as(usize, 2), session.editor.cursor);
    try std.testing.expectEqual(End.submit, (try session.feed("\x05 10\r", w80)).?);
    try std.testing.expectEqualStrings("(+ 1 10\n2)", session.line());
}

test "feed: a paste flag lasts until the end marker, and Ctrl-C or Ctrl-D ends it" {
    var session = Session.init(std.testing.allocator);
    defer session.deinit();
    _ = try session.begin("> ", w80, &balanced, null);
    try std.testing.expectEqual(End.submit, (try session.feed("\x1b[200~(a)\r", w80)).?);
    // No typeahead, and the paste has not ended.
    _ = try session.begin("> ", w80, &balanced, null);
    try std.testing.expect(session.editor.pasting);
    try std.testing.expectEqual(End.cancel, (try session.feed("\x03", w80)).?);
    try std.testing.expect(!session.editor.pasting);
    _ = try session.begin("> ", w80, &balanced, null);
    _ = try session.feed("\x1b[200~", w80);
    try std.testing.expectEqual(End.eof, (try session.feed("\x04", w80)).?);
    try std.testing.expect(!session.editor.pasting);
}

/// A paste of a finished form and an indented form of three rows, then
/// Enter. The second form's indentation is all in the paste.
const pasted = "\x1b[200~(a)\r(do\r  (b)\r  (c))\x1b[201~\r";

/// Feeds each of `chunks` in turn to a fresh session, opening a line whenever
/// one ends, and writes the lines submitted to `lines`, one per line.
fn submitted(chunks: []const []const u8, lines: *std.Io.Writer.Allocating) !void {
    var session = Session.init(std.testing.allocator);
    defer session.deinit();
    var ended = try session.begin("> ", w80, &balanced, null);
    for (chunks) |chunk| {
        ended = try session.feed(chunk, w80);
        while (ended) |_| {
            try lines.writer.print("{s}\n", .{session.line()});
            ended = try session.begin("> ", w80, &balanced, null);
        }
    }
}

test "feed: a paste gives the same lines however its bytes are split" {
    var whole: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer whole.deinit();
    try submitted(&.{pasted}, &whole);
    try std.testing.expectEqualStrings("(a)\n(do\n  (b)\n  (c))\n", whole.written());
    var at: usize = 1;
    while (at < pasted.len) : (at += 1) {
        var split: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer split.deinit();
        try submitted(&.{ pasted[0..at], pasted[at..] }, &split);
        try std.testing.expectEqualStrings(whole.written(), split.written());
    }
    var bytes: [pasted.len][]const u8 = undefined;
    for (&bytes, 0..) |*chunk, i| chunk.* = pasted[i..][0..1];
    var bytewise: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytewise.deinit();
    try submitted(&bytes, &bytewise);
    try std.testing.expectEqualStrings(whole.written(), bytewise.written());
}

/// Returns a history of `(a)` and the form `(b\n c)`, oldest first. The
/// caller releases it.
fn twoEntries() !history_mod.History {
    var history = history_mod.History.init(std.testing.allocator);
    errdefer history.deinit();
    _ = try history.add("(a)");
    _ = try history.add("(b\n c)");
    return history;
}

test "feed: Up on the first row recalls the newer entry first, with the cursor at its end" {
    var history = try twoEntries();
    defer history.deinit();
    var session = Session.init(std.testing.allocator);
    defer session.deinit();
    _ = try session.begin("> ", w80, &balanced, &history);
    _ = session.take();
    _ = try session.feed("\x1b[A", w80);
    try std.testing.expectEqualStrings("(b\n c)", session.line());
    try std.testing.expectEqual(6, session.editor.cursor);
    try std.testing.expectEqualStrings("\r\x1b[J> (b\r\n   c)", session.take());
}

test "feed: Up inside a recalled entry of several rows moves by row" {
    var history = try twoEntries();
    defer history.deinit();
    var session = Session.init(std.testing.allocator);
    defer session.deinit();
    _ = try session.begin("> ", w80, &balanced, &history);
    _ = try session.feed("\x1b[A\x1b[A", w80);
    try std.testing.expectEqualStrings("(b\n c)", session.line());
    try std.testing.expectEqual(2, session.editor.cursor);
    _ = try session.feed("\x1b[A", w80);
    try std.testing.expectEqualStrings("(a)", session.line());
}

test "feed: Down past the newest entry brings back the line being typed" {
    var history = try twoEntries();
    defer history.deinit();
    var session = Session.init(std.testing.allocator);
    defer session.deinit();
    _ = try session.begin("> ", w80, &balanced, &history);
    _ = try session.feed("xyz\x1b[A\x1b[B", w80);
    try std.testing.expectEqualStrings("xyz", session.line());
    try std.testing.expectEqual(3, session.editor.cursor);
    // Down on the line being typed goes no further.
    try std.testing.expectEqual(null, try session.feed("\x1b[B", w80));
    try std.testing.expectEqualStrings("xyz", session.line());
}

test "feed: an edit to a recalled entry is gone after the line ends" {
    var history = try twoEntries();
    defer history.deinit();
    var session = Session.init(std.testing.allocator);
    defer session.deinit();
    _ = try session.begin("> ", w80, &balanced, &history);
    _ = try session.feed("\x1b[A\x1b[A\x1b[A!\x1b[B", w80);
    try std.testing.expectEqualStrings("(b\n c)", session.line());
    // Down put the cursor on the entry's last row.
    _ = try session.feed("\x1b[A\x1b[A", w80);
    try std.testing.expectEqualStrings("(a)!", session.line());
    try std.testing.expectEqual(End.cancel, (try session.feed("\x03", w80)).?);
    _ = try session.begin("> ", w80, &balanced, &history);
    _ = try session.feed("\x1b[A\x1b[A\x1b[A", w80);
    try std.testing.expectEqualStrings("(a)", session.line());
    try std.testing.expectEqualStrings("(a)", history.entries.items[0]);
}

test "feed: without a history Up on the first row changes nothing" {
    var session = Session.init(std.testing.allocator);
    defer session.deinit();
    _ = try session.begin("> ", w80, &balanced, null);
    _ = try session.feed("ab", w80);
    _ = session.take();
    try std.testing.expectEqual(null, try session.feed("\x1b[A", w80));
    try std.testing.expectEqualStrings("ab", session.line());
    try std.testing.expectEqualStrings("", session.take());
}
