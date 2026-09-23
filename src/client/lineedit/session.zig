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
//! ## Completion and hints
//!
//! `begin` takes a `Source` for a line that reads source, or null. With its
//! `symbol` and `gather` functions, Tab completes the token before the
//! cursor, as `complete.zig` describes, and draws the candidates beneath the
//! line while a completion is in progress. Any key other than Tab ends the
//! completion with the buffer as it stands, and is then applied. Without
//! them, or inside a bracketed paste, Tab inserts a tab.
//!
//! A `gather` that fails is taken as giving no candidates, and what it added
//! is freed, so the line stays open.
//!
//! With its `symbol` and `hint` functions, a frame draws the hint for the
//! token that ends at the cursor, when nothing follows the cursor on its
//! line. The frame at the end of a line draws neither the candidates nor the
//! hint.
//!
//! ## Highlighting
//!
//! With its `symbol`, `number` and `special` functions, each frame draws the
//! buffer in the classes `highlight.classify` gives it, the frame at the end
//! of a line included, so the line keeps its colours on the screen.
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

const complete = @import("complete.zig");
const editor_mod = @import("editor.zig");
const highlight = @import("highlight.zig");
const history_mod = @import("history.zig");
const keys = @import("keys.zig");
const layout = @import("layout.zig");
const render = @import("render.zig");

// ==========================================================================
// Aliased types
// ==========================================================================

/// Returns the hint for `token`, or null for none.
///
/// `Source` has a `Hint`. The result is valid until the next call into the
/// runtime, and a frame draws it at once.
pub const Hint = *const fn (token: []const u8) ?[]const u8;

// ==========================================================================
// Types
// ==========================================================================

/// How a line ended: `editor.zig`'s outcomes without the two that leave a
/// line open.
///
/// `Session.begin` and `Session.feed` return an `End`, and `Session.close`
/// takes one.
pub const End = enum { submit, eof, cancel };

/// The functions a line that reads source is edited with.
///
/// `Session.begin` takes a `Source`. `finished` sets what Enter does, as
/// `editor.Editor.finished` does. `symbol` reports which bytes a token has,
/// `gather` adds the candidates for a token, and `hint` returns a token's
/// hint. `number` and `special` report which tokens are numbers and special
/// forms, and `bound` which symbols are bound. Tab completes only with
/// `symbol` and `gather`, a frame draws a hint only with `symbol` and `hint`,
/// and a frame is highlighted only with `symbol`, `number` and `special`.
pub const Source = struct {
    finished: ?editor_mod.Finished = null,
    symbol: ?complete.Symbol = null,
    gather: ?complete.Gather = null,
    hint: ?Hint = null,
    number: ?highlight.Number = null,
    special: ?highlight.Special = null,
    bound: ?highlight.Bound = null,
};

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
/// line. `source` is the open line's `Source`, or null, and `cycle` is the
/// completion in progress, or null. `history` is the history the open line
/// browses, or null. `classes` is the class of each byte of the buffer in
/// the last highlighted frame. `climb` is
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
    source: ?Source = null,
    cycle: ?complete.Cycle = null,
    history: ?*history_mod.History = null,
    classes: std.ArrayList(highlight.Class) = .empty,
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
        _ = session.endCycle();
        session.editor.deinit();
        session.prompt.deinit(session.allocator);
        session.output.deinit();
        session.held.deinit(session.allocator);
        session.typeahead.deinit(session.allocator);
        session.classes.deinit(session.allocator);
    }

    /// Opens a line with `prompt`, draws its first frame, and applies the
    /// typeahead.
    ///
    /// `size` is the terminal's size, and `source` is the functions a line
    /// that reads source is edited with, or null for none. `history` is what Up
    /// and Down browse beyond the buffer's first and last rows, or null for
    /// nothing, and is reset here and when the line ends. The result is how the
    /// line ended when the typeahead ended it, and null when the line is
    /// open. This function returns `error.OutOfMemory` when an allocation
    /// fails, with no line open.
    pub fn begin(session: *Session, prompt: []const u8, size: Size, source: ?Source, history: ?*history_mod.History) error{OutOfMemory}!?End {
        session.editor.clear();
        _ = session.endCycle();
        session.source = source;
        session.editor.finished = if (source) |s| s.finished else null;
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
            if (key != .tab and session.endCycle()) changed = true;
            const outcome = switch (key) {
                .tab => try session.tab(),
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

    /// Returns the class of each byte of the buffer, or an empty slice for a
    /// line that is not highlighted.
    ///
    /// The result is valid until the next call. This function returns
    /// `error.OutOfMemory` when the classes cannot be allocated.
    fn classify(session: *Session) error{OutOfMemory}![]const highlight.Class {
        const source = session.source orelse return &.{};
        const lexicon: highlight.Lexicon = .{
            .symbol = source.symbol orelse return &.{},
            .number = source.number orelse return &.{},
            .special = source.special orelse return &.{},
            .bound = source.bound,
        };
        const text = session.editor.buffer.items;
        try session.classes.resize(session.allocator, text.len);
        highlight.classify(text, session.classes.items, lexicon);
        return session.classes.items;
    }

    /// Ends the completion in progress, and reports whether there was one.
    fn endCycle(session: *Session) bool {
        var cycle = session.cycle orelse return false;
        cycle.deinit();
        session.cycle = null;
        return true;
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

    /// Returns the hint for the token that ends at the cursor, or an empty
    /// slice where there is none or text follows the cursor on its line.
    fn hintText(session: *const Session) []const u8 {
        const source = session.source orelse return "";
        const symbol = source.symbol orelse return "";
        const hint = source.hint orelse return "";
        const text = session.editor.buffer.items;
        const cursor = session.editor.cursor;
        if (cursor < text.len and text[cursor] != '\n') return "";
        const start = complete.tokenStart(text, cursor, symbol);
        if (start == cursor) return "";
        return hint(text[start..cursor]) orelse "";
    }

    /// Applies Tab: completes the token before the cursor, or inserts a tab
    /// on a line that does not complete and inside a bracketed paste.
    fn tab(session: *Session) error{OutOfMemory}!editor_mod.Outcome {
        const editor = &session.editor;
        if (session.cycle) |*cycle| {
            const text = cycle.advance();
            try editor.splice(cycle.start, cycle.start + cycle.length, text);
            cycle.length = text.len;
            return .edited;
        }
        const source = session.source orelse return editor.apply(.tab);
        const symbol = source.symbol orelse return editor.apply(.tab);
        const gather = source.gather orelse return editor.apply(.tab);
        if (editor.pasting) return editor.apply(.tab);
        const text = editor.buffer.items;
        const end = complete.tokenEnd(text, editor.cursor, symbol);
        const start = complete.tokenStart(text, end, symbol);
        const moved: editor_mod.Outcome = if (end == editor.cursor) .unchanged else .edited;
        editor.cursor = end;
        editor.goal = null;
        if (start == end) return moved;
        var candidates = complete.Candidates.init(session.allocator);
        // A gatherer that fails gives no candidates, so the line stays open.
        gather(text[start..end], &candidates) catch {
            candidates.deinit();
            return moved;
        };
        candidates.settle();
        switch (candidates.names.items.len) {
            0 => {
                candidates.deinit();
                return moved;
            },
            1 => {
                defer candidates.deinit();
                try editor.splice(start, end, candidates.names.items[0]);
                return .edited;
            },
            else => {
                // From here the cycle frees the candidates.
                var cycle = complete.Cycle.init(candidates, text[start..end], start) catch |err| {
                    candidates.deinit();
                    return err;
                };
                errdefer cycle.deinit();
                const first = cycle.advance();
                try editor.splice(start, end, first);
                cycle.length = first.len;
                session.cycle = cycle;
                return .edited;
            },
        }
    }

    /// Draws the last frame with the cursor at the end and every row, breaks
    /// the row, and writes the held output.
    fn finish(session: *Session, end: End) error{OutOfMemory}!void {
        _ = session.endCycle();
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
    ///
    /// The frame draws the candidates of the completion in progress, and a
    /// bounded frame draws the hint. The frame at the end of a line is
    /// unbounded, and no completion is in progress when it is drawn.
    fn redraw(session: *Session, bounded: bool) error{OutOfMemory}!void {
        const classes = try session.classify();
        var listing: ?render.Listing = null;
        if (session.cycle) |cycle| listing = .{ .names = cycle.candidates.names.items, .selected = cycle.selected };
        const drawn = render.draw(&session.output.writer, session.climb, .{
            .prompt = session.prompt.items,
            .buffer = session.editor.buffer.items,
            .cursor = session.editor.cursor,
            .columns = session.size.columns,
            .height = if (bounded) session.size.rows else 0,
            .top = session.top,
            .listing = listing,
            .hint = if (bounded) session.hintText() else "",
            .classes = classes,
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
    _ = try session.begin("repl:1:> ", w80, .{ .finished = &balanced }, null);
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
    _ = try session.begin("> ", w80, .{ .finished = &balanced }, null);
    _ = try session.feed("(+ 1\r2)\x1b[A", w80);
    // Column 4 on the row above is the space after `+`.
    try std.testing.expectEqual(@as(usize, 2), session.editor.cursor);
    try std.testing.expectEqual(End.submit, (try session.feed("\x05 10\r", w80)).?);
    try std.testing.expectEqualStrings("(+ 1 10\n2)", session.line());
}

test "feed: a paste flag lasts until the end marker, and Ctrl-C or Ctrl-D ends it" {
    var session = Session.init(std.testing.allocator);
    defer session.deinit();
    _ = try session.begin("> ", w80, .{ .finished = &balanced }, null);
    try std.testing.expectEqual(End.submit, (try session.feed("\x1b[200~(a)\r", w80)).?);
    // No typeahead, and the paste has not ended.
    _ = try session.begin("> ", w80, .{ .finished = &balanced }, null);
    try std.testing.expect(session.editor.pasting);
    try std.testing.expectEqual(End.cancel, (try session.feed("\x03", w80)).?);
    try std.testing.expect(!session.editor.pasting);
    _ = try session.begin("> ", w80, .{ .finished = &balanced }, null);
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
    var ended = try session.begin("> ", w80, .{ .finished = &balanced }, null);
    for (chunks) |chunk| {
        ended = try session.feed(chunk, w80);
        while (ended) |_| {
            try lines.writer.print("{s}\n", .{session.line()});
            ended = try session.begin("> ", w80, .{ .finished = &balanced }, null);
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
    _ = try session.begin("> ", w80, .{ .finished = &balanced }, &history);
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
    _ = try session.begin("> ", w80, .{ .finished = &balanced }, &history);
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
    _ = try session.begin("> ", w80, .{ .finished = &balanced }, &history);
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
    _ = try session.begin("> ", w80, .{ .finished = &balanced }, &history);
    _ = try session.feed("\x1b[A\x1b[A\x1b[A!\x1b[B", w80);
    try std.testing.expectEqualStrings("(b\n c)", session.line());
    // Down put the cursor on the entry's last row.
    _ = try session.feed("\x1b[A\x1b[A", w80);
    try std.testing.expectEqualStrings("(a)!", session.line());
    try std.testing.expectEqual(End.cancel, (try session.feed("\x03", w80)).?);
    _ = try session.begin("> ", w80, .{ .finished = &balanced }, &history);
    _ = try session.feed("\x1b[A\x1b[A\x1b[A", w80);
    try std.testing.expectEqualStrings("(a)", session.line());
    try std.testing.expectEqualStrings("(a)", history.entries.items[0]);
}

test "feed: without a history Up on the first row changes nothing" {
    var session = Session.init(std.testing.allocator);
    defer session.deinit();
    _ = try session.begin("> ", w80, .{ .finished = &balanced }, null);
    _ = try session.feed("ab", w80);
    _ = session.take();
    try std.testing.expectEqual(null, try session.feed("\x1b[A", w80));
    try std.testing.expectEqualStrings("ab", session.line());
    try std.testing.expectEqualStrings("", session.take());
}

/// Whether `byte` is a letter, a digit, `-` or `/`.
fn testSymbol(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '/';
}

/// Adds the names of `test_names` that begin with `token`, the first twice.
fn testGather(token: []const u8, candidates: *complete.Candidates) error{OutOfMemory}!void {
    for (test_names) |name| {
        if (std.mem.startsWith(u8, name, token)) try candidates.add(name);
    }
    if (std.mem.startsWith(u8, test_names[0], token)) try candidates.add(test_names[0]);
}

/// Returns a hint for `map` and nothing for any other token.
fn testHint(token: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, token, "map")) return "(map f ind)\n\nMap a function.";
    return null;
}

/// The names `testGather` completes from, not in order. The three that begin
/// `zz` and `yy` are longer than a buffer holds after a few keys, so
/// replacing a token with one of them allocates.
const test_names = [_][]const u8{ "mapcat", "map", "max", "string/find", "zz" ++ "z" ** 300, "yya" ++ "y" ** 300, "yyb" ++ "y" ** 300 };

/// A source that completes from `test_names` and hints `map`.
const completing: Source = .{ .symbol = &testSymbol, .gather = &testGather, .hint = &testHint };

/// Opens a line with `completing`, feeds it `bytes`, and checks the buffer.
fn expectCompleted(bytes: []const u8, buffer: []const u8) !void {
    var session = Session.init(std.testing.allocator);
    defer session.deinit();
    _ = try session.begin("> ", w80, completing, null);
    _ = try session.feed(bytes, w80);
    try std.testing.expectEqualStrings(buffer, session.line());
    try std.testing.expectEqual(buffer.len, session.editor.cursor);
}

test "feed: Tab with one candidate replaces the token" {
    try expectCompleted("(stri\t", "(string/find");
}

test "feed: Tab with three candidates cycles through each and back to the token" {
    try expectCompleted("ma\t", "map");
    try expectCompleted("ma\t\t", "mapcat");
    try expectCompleted("ma\t\t\t", "max");
    try expectCompleted("ma\t\t\t\t", "ma");
    try expectCompleted("ma\t\t\t\t\t", "map");
}

test "feed: a key other than Tab keeps the candidate and is applied" {
    try expectCompleted("ma\t\t ", "mapcat ");
    try expectCompleted("ma\t\tx", "mapcatx");
}

test "feed: Tab inside a token completes the whole token" {
    try expectCompleted("stri\x1b[D\x1b[D\t", "string/find");
}

test "feed: Tab with an empty token or no candidate changes nothing" {
    try expectCompleted("( \t", "( ");
    try expectCompleted("qq\t", "qq");
}

test "feed: Tab inside a paste, and on a line that does not complete, inserts a tab" {
    try expectCompleted("\x1b[200~ma\t\x1b[201~", "ma\t");
    var session = Session.init(std.testing.allocator);
    defer session.deinit();
    _ = try session.begin("> ", w80, null, null);
    _ = try session.feed("ma\t", w80);
    try std.testing.expectEqualStrings("ma\t", session.line());
}

test "feed: the candidates are listed while the completion is in progress" {
    var session = Session.init(std.testing.allocator);
    defer session.deinit();
    _ = try session.begin("> ", w80, completing, null);
    _ = session.take();
    _ = try session.feed("ma\t", w80);
    try std.testing.expectEqualStrings("\r\x1b[J> map\r\n\x1b[7mmap\x1b[0m     mapcat  max\x1b[1A\r\x1b[5C\x1b[3C\x1b[90m(map f ind) Map a function.\x1b[0m\r\x1b[5C", session.take());
    _ = try session.feed(" ", w80);
    try std.testing.expectEqualStrings("\r\x1b[J> map ", session.take());
}

test "feed: the frame at submission draws no candidates and no hint" {
    var session = Session.init(std.testing.allocator);
    defer session.deinit();
    _ = try session.begin("> ", w80, completing, null);
    _ = try session.feed("ma\t", w80);
    _ = session.take();
    try std.testing.expectEqual(End.submit, (try session.feed("\r", w80)).?);
    try std.testing.expectEqualStrings("\r\x1b[J> map\r\n", session.take());
}

test "feed: no hint is drawn with text after the cursor on its line" {
    var session = Session.init(std.testing.allocator);
    defer session.deinit();
    _ = try session.begin("> ", w80, completing, null);
    _ = try session.feed("map x\x1b[D\x1b[D", w80);
    try std.testing.expectEqual(null, std.mem.indexOf(u8, session.take(), "\x1b[90m"));
    _ = try session.feed("\x1b[F", w80);
    try std.testing.expectEqual(null, std.mem.indexOf(u8, session.take(), "\x1b[90m"));
    _ = try session.feed("\x7f\x7f", w80);
    try std.testing.expect(std.mem.indexOf(u8, session.take(), "\x1b[90m") != null);
}

/// Opens a line with `completing` on `allocator` and feeds it `bytes`.
fn completeWith(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var session = Session.init(allocator);
    defer session.deinit();
    _ = try session.begin("> ", w80, completing, null);
    _ = try session.feed(bytes, w80);
}

test "feed: a completion that fails to allocate frees each allocation once" {
    for ([_][]const u8{ "zz\t", "yy\t", "yy\t\t\t\t" }) |bytes| {
        var fail_index: usize = 0;
        while (true) : (fail_index += 1) {
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
            completeWith(failing.allocator(), bytes) catch |err| try std.testing.expectEqual(error.OutOfMemory, err);
            if (!failing.has_induced_failure) break;
        }
    }
}

/// Adds a candidate and then fails, as a gatherer that cannot allocate does.
fn failingGather(token: []const u8, candidates: *complete.Candidates) error{OutOfMemory}!void {
    _ = token;
    try candidates.add("mapcat");
    return error.OutOfMemory;
}

test "feed: a gatherer that fails gives no candidates and the line stays open" {
    var session = Session.init(std.testing.allocator);
    defer session.deinit();
    _ = try session.begin("> ", w80, .{ .symbol = &testSymbol, .gather = &failingGather }, null);
    try std.testing.expectEqual(null, try session.feed("ma\t", w80));
    try std.testing.expectEqualStrings("ma", session.line());
    try std.testing.expectEqual(null, session.cycle);
    try std.testing.expectEqual(End.submit, (try session.feed("\r", w80)).?);
}

/// The `highlight.Number` of the tests: a run of digits.
fn testNumber(token: []const u8) bool {
    for (token) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

/// The `highlight.Special` of the tests: `def` alone.
fn testSpecial(token: []const u8) bool {
    return std.mem.eql(u8, token, "def");
}

test "feed: a line with the classifier's functions is highlighted, the last frame too" {
    var session = Session.init(std.testing.allocator);
    defer session.deinit();
    const source: Source = .{ .symbol = &testSymbol, .number = &testNumber, .special = &testSpecial };
    _ = try session.begin("> ", w80, source, null);
    _ = session.take();
    _ = try session.feed("(def 1)", w80);
    try std.testing.expectEqualStrings("\r\x1b[J> (\x1b[0;93mdef\x1b[0m \x1b[0;32m1\x1b[0m)", session.take());
    try std.testing.expectEqual(End.submit, (try session.feed("\r", w80)).?);
    try std.testing.expectEqualStrings("\r\x1b[J> (\x1b[0;93mdef\x1b[0m \x1b[0;32m1\x1b[0m)\r\n", session.take());
}

test "feed: a line without the classifier's functions is not highlighted" {
    var session = Session.init(std.testing.allocator);
    defer session.deinit();
    _ = try session.begin("> ", w80, .{ .symbol = &testSymbol, .special = &testSpecial }, null);
    _ = session.take();
    _ = try session.feed("(def 1)", w80);
    try std.testing.expectEqualStrings("\r\x1b[J> (def 1)", session.take());
}
