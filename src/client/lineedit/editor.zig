//! The line editor's buffer and cursor, and what each key does to them.
//!
//! `session.zig` owns an `Editor` and applies each key `keys.zig` decodes.
//! The _cursor_ is a byte offset into the buffer, and it is always at the
//! start of a rune or at the end of the buffer.
//!
//! ## Runes and movement
//!
//! A movement or a deletion acts on a whole rune, as `rune.decode` delimits
//! it. A byte that begins no valid UTF-8 sequence is a rune of its own, so a
//! buffer with invalid bytes in it is still edited one column at a time. A
//! combining mark is a rune of its own and is stepped over separately from
//! its base.
//!
//! ## Lines and rows
//!
//! A _line_ is the text between two newlines, or between a newline and an
//! end of the buffer. Home, End, Ctrl-U and Ctrl-K act on the cursor's line,
//! and none of them removes or crosses a newline. Up and Down move by layout
//! row, which a wrap opens as well as a newline, so `vertical` takes the
//! layout's geometry and `apply` does not move for them. Up on the first
//! row and Down on the last return `beyond`, which the session takes to the
//! history.
//!
//! A run of Up and Down keeps the _goal column_, the cursor's column when the
//! run began, so a move through a shorter row and back returns to it. Every
//! other key ends the run.
//!
//! ## Enter
//!
//! Enter submits the buffer, unless the editor has a `Finished` function and
//! that function says the buffer is not finished, when Enter opens a line.
//! Ctrl-J always opens a line. _Opening a line_ inserts a newline at the
//! cursor and then the spaces and tabs that begin the cursor's line, as far as
//! the cursor. Inside a bracketed paste it inserts the newline alone, because
//! pasted text carries its own indentation.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const keys = @import("keys.zig");
const layout = @import("layout.zig");
const rune = @import("rune.zig");

// ==========================================================================
// Types
// ==========================================================================

/// What applying a key did.
///
/// `Editor.apply` and `Editor.vertical` return an `Outcome`. `unchanged`,
/// `edited` and `beyond` leave the line open, and `edited` says the buffer or
/// the cursor changed. `beyond` is Up on the first row or Down on the last,
/// which change nothing in the buffer. `submit`,
/// `eof` and `cancel` end the line: `submit` with the buffer as it stands,
/// `eof` at Ctrl-D on an empty buffer, and `cancel` at Ctrl-C.
pub const Outcome = enum { unchanged, edited, beyond, submit, eof, cancel };

/// Returns whether `text` is ready to be submitted.
///
/// `Editor.finished` holds one. `text` is the whole buffer. The editor calls
/// the function at Enter, and opens a line when the result is false.
pub const Finished = *const fn (text: []const u8) bool;

/// The buffer being edited and the cursor in it.
///
/// `init` returns an `Editor` and `deinit` releases it. `buffer` is the
/// bytes typed so far and `cursor` is a byte offset into them. `finished`
/// decides what Enter does, and Enter submits when it is null. `pasting` is
/// whether the keys are inside a bracketed paste, and `goal` is the goal
/// column of a run of vertical moves, null outside one.
pub const Editor = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    finished: ?Finished = null,
    pasting: bool = false,
    goal: ?usize = null,

    /// Returns an empty editor whose buffer `allocator` holds.
    pub fn init(allocator: std.mem.Allocator) Editor {
        return .{ .allocator = allocator };
    }

    /// Releases the buffer.
    pub fn deinit(editor: *Editor) void {
        editor.buffer.deinit(editor.allocator);
    }

    /// Empties the buffer and puts the cursor at its start.
    ///
    /// The buffer's memory is kept for the next line. `finished` and
    /// `pasting` are left as they are.
    pub fn clear(editor: *Editor) void {
        editor.buffer.clearRetainingCapacity();
        editor.cursor = 0;
        editor.goal = null;
    }

    /// Replaces the buffer with `text` and puts the cursor at its end.
    ///
    /// This function returns `error.OutOfMemory` when the buffer cannot grow,
    /// and the buffer is then unchanged.
    pub fn replace(editor: *Editor, text: []const u8) error{OutOfMemory}!void {
        try editor.buffer.ensureTotalCapacity(editor.allocator, text.len);
        editor.buffer.clearRetainingCapacity();
        editor.buffer.appendSliceAssumeCapacity(text);
        editor.cursor = text.len;
        editor.goal = null;
    }

    /// Replaces the bytes from `start` up to `end` with `text`, and puts the
    /// cursor after `text`.
    ///
    /// `start` and `end` are offsets into the buffer, with `start` at most
    /// `end`. This function returns `error.OutOfMemory` when the buffer
    /// cannot grow, and the buffer is then unchanged.
    pub fn splice(editor: *Editor, start: usize, end: usize, text: []const u8) error{OutOfMemory}!void {
        if (text.len > end - start) try editor.buffer.ensureUnusedCapacity(editor.allocator, text.len - (end - start));
        editor.buffer.replaceRangeAssumeCapacity(start, end - start, text);
        editor.cursor = start + text.len;
        editor.goal = null;
    }

    /// Applies `key` to the buffer and the cursor, and returns what it did.
    ///
    /// Up and Down change nothing here; `vertical` applies them. This
    /// function returns `error.OutOfMemory` when an insertion cannot grow the
    /// buffer, and the buffer is then unchanged.
    pub fn apply(editor: *Editor, key: keys.Key) error{OutOfMemory}!Outcome {
        const text = editor.buffer.items;
        editor.goal = null;
        switch (key) {
            .insert => |r| {
                try editor.buffer.insertSlice(editor.allocator, editor.cursor, r.slice());
                editor.cursor += r.len;
                return .edited;
            },
            .tab => {
                try editor.buffer.insert(editor.allocator, editor.cursor, '\t');
                editor.cursor += 1;
                return .edited;
            },
            .left => return editor.moveTo(previous(text, editor.cursor)),
            .right => return editor.moveTo(next(text, editor.cursor)),
            .up, .down => return .unchanged,
            .home => return editor.moveTo(lineStart(text, editor.cursor)),
            .end => return editor.moveTo(lineEnd(text, editor.cursor)),
            .backspace => {
                if (editor.cursor == 0) return .unchanged;
                const start = previous(text, editor.cursor);
                editor.remove(start, editor.cursor);
                editor.cursor = start;
                return .edited;
            },
            .delete => return editor.deleteForward(),
            .kill_end => {
                const end = lineEnd(text, editor.cursor);
                if (end == editor.cursor) return .unchanged;
                editor.remove(editor.cursor, end);
                return .edited;
            },
            .kill_start => {
                const start = lineStart(text, editor.cursor);
                if (start == editor.cursor) return .unchanged;
                editor.remove(start, editor.cursor);
                editor.cursor = start;
                return .edited;
            },
            .enter => {
                const finished = editor.finished orelse return .submit;
                if (finished(text)) return .submit;
                return editor.openLine();
            },
            .newline => return editor.openLine(),
            .eof => {
                if (text.len == 0) return .eof;
                return editor.deleteForward();
            },
            .interrupt => return .cancel,
            .paste_start, .paste_end => {
                editor.pasting = key == .paste_start;
                return .unchanged;
            },
            .ignored => return .unchanged,
        }
    }

    /// Moves the cursor to the layout row above, when `up`, or below, and
    /// returns what it did.
    ///
    /// `geometry` is the layout the buffer is drawn with. The cursor moves to
    /// the byte `layout.offset` names at the goal column on that row. On the
    /// first row a move up, and on the last row a move down, changes nothing
    /// and returns `beyond`.
    pub fn vertical(editor: *Editor, geometry: layout.Geometry, up: bool) Outcome {
        const text = editor.buffer.items;
        const from = layout.position(geometry, text, editor.cursor);
        const column = editor.goal orelse from.column;
        if (up and from.row == 0) return .beyond;
        if (!up and from.row + 1 >= layout.rows(geometry, text)) return .beyond;
        const row = if (up) from.row - 1 else from.row + 1;
        const outcome = editor.moveTo(layout.offset(geometry, text, .{ .row = row, .column = column }));
        editor.goal = column;
        return outcome;
    }

    /// Deletes the rune at the cursor.
    fn deleteForward(editor: *Editor) Outcome {
        const text = editor.buffer.items;
        if (editor.cursor == text.len) return .unchanged;
        editor.remove(editor.cursor, next(text, editor.cursor));
        return .edited;
    }

    /// Inserts a newline at the cursor and the indentation of the cursor's
    /// line before the cursor, or the newline alone inside a paste.
    fn openLine(editor: *Editor) error{OutOfMemory}!Outcome {
        const text = editor.buffer.items;
        const start = lineStart(text, editor.cursor);
        var end = start;
        if (!editor.pasting) {
            while (end < editor.cursor and (text[end] == ' ' or text[end] == '\t')) end += 1;
        }
        try editor.buffer.ensureUnusedCapacity(editor.allocator, 1 + end - start);
        const at = editor.cursor;
        editor.buffer.insertAssumeCapacity(at, '\n');
        // The indentation is before the cursor, so the insertions after it
        // leave it where it was.
        editor.buffer.insertSliceAssumeCapacity(at + 1, editor.buffer.items[start..end]);
        editor.cursor = at + 1 + end - start;
        return .edited;
    }

    /// Moves the cursor to `at`, and reports whether it moved.
    fn moveTo(editor: *Editor, at: usize) Outcome {
        if (at == editor.cursor) return .unchanged;
        editor.cursor = at;
        return .edited;
    }

    /// Removes the bytes from `start` up to `end`.
    fn remove(editor: *Editor, start: usize, end: usize) void {
        editor.buffer.replaceRangeAssumeCapacity(start, end - start, &.{});
    }
};

// ==========================================================================
// Private functions
// ==========================================================================

/// Returns the offset of the start of the line `at` is on.
fn lineStart(text: []const u8, at: usize) usize {
    const newline = std.mem.lastIndexOfScalar(u8, text[0..at], '\n') orelse return 0;
    return newline + 1;
}

/// Returns the offset of the end of the line `at` is on: its newline, or the
/// end of `text`.
fn lineEnd(text: []const u8, at: usize) usize {
    return std.mem.indexOfScalarPos(u8, text, at, '\n') orelse text.len;
}

/// Returns the offset after the rune at `at`, or `text.len` at the end.
fn next(text: []const u8, at: usize) usize {
    if (at >= text.len) return text.len;
    return at + rune.decode(text[at..]).len;
}

/// Returns the offset of the rune before `at`, or 0 at the start.
///
/// The walk is forward from the start of `text`, because a byte that begins
/// no valid sequence cannot be told from a continuation byte by reading
/// backward.
fn previous(text: []const u8, at: usize) usize {
    var i: usize = 0;
    var last: usize = 0;
    while (i < at) {
        last = i;
        i += rune.decode(text[i..]).len;
    }
    return last;
}

// ==========================================================================
// Tests
// ==========================================================================

/// Applies every key `bytes` decodes to a fresh editor, and checks the buffer
/// and the cursor after them.
fn expectEdited(bytes: []const u8, buffer: []const u8, cursor: usize) !void {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    var decoder = keys.Decoder.init();
    for (bytes) |byte| {
        if (decoder.feed(byte)) |key| _ = try editor.apply(key);
    }
    try std.testing.expectEqualStrings(buffer, editor.buffer.items);
    try std.testing.expectEqual(cursor, editor.cursor);
}

/// Applies every key `bytes` decodes, and returns the outcome of the last.
fn lastOutcome(bytes: []const u8) !Outcome {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    var decoder = keys.Decoder.init();
    var outcome: Outcome = .unchanged;
    for (bytes) |byte| {
        if (decoder.feed(byte)) |key| outcome = try editor.apply(key);
    }
    return outcome;
}

test "apply: printable ASCII is inserted at the cursor" {
    try expectEdited("(+ 1 2)", "(+ 1 2)", 7);
}

test "apply: a multi-byte rune moves the cursor by its length" {
    try expectEdited("é度😀", "é度😀", 9);
}

test "apply: a rune split across two feeds is inserted once" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    var decoder = keys.Decoder.init();
    const bytes = "a度b";
    for (bytes[0..2]) |byte| {
        if (decoder.feed(byte)) |key| _ = try editor.apply(key);
    }
    try std.testing.expectEqualStrings("a", editor.buffer.items);
    for (bytes[2..]) |byte| {
        if (decoder.feed(byte)) |key| _ = try editor.apply(key);
    }
    try std.testing.expectEqualStrings("a度b", editor.buffer.items);
    try std.testing.expectEqual(5, editor.cursor);
}

test "apply: Left, Right, Home and End as CSI" {
    try expectEdited("(+ 2\x1b[D1 ", "(+ 1 2", 5);
    try expectEdited("abc\x1b[H", "abc", 0);
    try expectEdited("abc\x1b[H\x1b[C", "abc", 1);
    try expectEdited("abc\x1b[H\x1b[F", "abc", 3);
}

test "apply: Left, Right, Home and End as SS3" {
    try expectEdited("abc\x1bOD\x1bOD", "abc", 1);
    try expectEdited("abc\x1bOH\x1bOC", "abc", 1);
    try expectEdited("abc\x1bOH\x1bOF", "abc", 3);
}

test "apply: Ctrl-A, Ctrl-E, Ctrl-B and Ctrl-F" {
    try expectEdited("abc\x01", "abc", 0);
    try expectEdited("abc\x01\x05", "abc", 3);
    try expectEdited("abc\x02\x02", "abc", 1);
    try expectEdited("abc\x01\x06", "abc", 1);
}

test "apply: movement stops at either end" {
    try expectEdited("a\x1b[D\x1b[D\x1b[D", "a", 0);
    try expectEdited("a\x1b[C\x1b[C", "a", 1);
}

test "apply: Left and Right step over a multi-byte rune whole" {
    try expectEdited("a度b\x1b[D\x1b[D", "a度b", 1);
    try expectEdited("a度b\x01\x1b[C\x1b[C", "a度b", 4);
}

test "apply: Backspace removes the multi-byte rune before the cursor" {
    try expectEdited("a度\x7f", "a", 1);
    try expectEdited("a度b\x1b[D\x08", "ab", 1);
    try expectEdited("\x7f", "", 0);
}

test "apply: Delete removes the multi-byte rune at the cursor" {
    try expectEdited("a度b\x01\x1b[C\x1b[3~", "ab", 1);
    try expectEdited("a\x1b[3~", "a", 1);
}

test "apply: Ctrl-D on a non-empty buffer deletes forward" {
    try expectEdited("a😀\x02\x04", "a", 1);
    try std.testing.expectEqual(Outcome.unchanged, try lastOutcome("a\x04"));
}

test "apply: Ctrl-D on an empty buffer is end of input" {
    try std.testing.expectEqual(Outcome.eof, try lastOutcome("\x04"));
}

test "apply: Ctrl-K and Ctrl-U kill to either end" {
    try expectEdited("abcd\x02\x02\x0b", "ab", 2);
    try expectEdited("abcd\x02\x02\x15", "cd", 0);
}

test "apply: an unrecognised CSI changes nothing" {
    try expectEdited("ab\x1b[99~c", "abc", 3);
    try std.testing.expectEqual(Outcome.unchanged, try lastOutcome("ab\x1b[99~"));
}

test "apply: a tab is inserted" {
    try expectEdited("a\tb", "a\tb", 3);
}

test "apply: an invalid byte is stepped over on its own" {
    try expectEdited("a\x80b\x1b[D\x1b[D", "a\x80b", 1);
}

test "apply: Enter submits without a Finished function, and Ctrl-C cancels" {
    try std.testing.expectEqual(Outcome.submit, try lastOutcome("abc\r"));
    try std.testing.expectEqual(Outcome.cancel, try lastOutcome("abc\x03"));
}

/// A `Finished` for the tests: the buffer is finished when it has as many
/// `)` as `(`.
fn balanced(text: []const u8) bool {
    return std.mem.count(u8, text, "(") == std.mem.count(u8, text, ")");
}

/// Applies every key `bytes` decodes to a fresh editor with `balanced` as its
/// `Finished`, applying Up and Down with `geometry`, and returns the editor
/// and the outcome of the last key. The caller releases the editor.
fn run(bytes: []const u8, geometry: layout.Geometry) !struct { Editor, Outcome } {
    var editor = Editor.init(std.testing.allocator);
    errdefer editor.deinit();
    editor.finished = &balanced;
    var decoder = keys.Decoder.init();
    var outcome: Outcome = .unchanged;
    for (bytes) |byte| {
        const key = decoder.feed(byte) orelse continue;
        outcome = switch (key) {
            .up => editor.vertical(geometry, true),
            .down => editor.vertical(geometry, false),
            else => try editor.apply(key),
        };
    }
    return .{ editor, outcome };
}

/// Checks the buffer, the cursor and the last outcome after `bytes`.
fn expectRun(bytes: []const u8, buffer: []const u8, cursor: usize, outcome: Outcome) !void {
    var result = try run(bytes, .{ .columns = 80, .prompt = 2, .marker = 2 });
    defer result[0].deinit();
    try std.testing.expectEqualStrings(buffer, result[0].buffer.items);
    try std.testing.expectEqual(cursor, result[0].cursor);
    try std.testing.expectEqual(outcome, result[1]);
}

test "apply: Enter opens a line when unfinished and submits when finished" {
    try expectRun("(+ 1\r", "(+ 1\n", 5, .edited);
    try expectRun("(+ 1\r2)\r", "(+ 1\n2)", 7, .submit);
}

test "apply: Enter opens a line at the cursor" {
    try expectRun("(ab\x1b[D\r", "(a\nb", 3, .edited);
}

test "apply: Ctrl-J opens a line with or without a Finished function" {
    try expectRun("(a)\n", "(a)\n", 4, .edited);
    try expectEdited("abc\n", "abc\n", 4);
}

test "apply: an opened line copies the indentation before the cursor" {
    // `(defn f [x]` has no indentation to copy.
    try expectRun("(defn f [x]\r", "(defn f [x]\n", 12, .edited);
    try expectRun("(do\r  (a)\r", "(do\n  (a)\n  ", 12, .edited);
    try expectRun("(do\r \t(a)\r", "(do\n \t(a)\n \t", 12, .edited);
    // A cursor inside the indentation copies only what is before it.
    try expectRun("(do\r    (a)\x01\x1b[C\x1b[C\r", "(do\n  \n    (a)", 9, .edited);
}

test "apply: an opened line inside a paste copies no indentation" {
    try expectRun("(do\r  (a)\x1b[200~\r", "(do\n  (a)\n", 10, .edited);
    // The paste's end restores the copying.
    try expectRun("(do\r  (a)\x1b[200~\x1b[201~\r", "(do\n  (a)\n  ", 12, .edited);
}

test "apply: the paste markers insert nothing" {
    try expectRun("\x1b[200~ab\x1b[201~", "ab", 2, .unchanged);
}

test "apply: Home and End act on the cursor's line" {
    try expectRun("(a\nbc\nd)\x1b[D\x1b[D\x1b[D\x01", "(a\nbc\nd)", 3, .edited);
    try expectRun("(a\nbc\nd)\x1b[D\x1b[D\x1b[D\x01\x05", "(a\nbc\nd)", 5, .edited);
    // At the line's start Home does not cross the newline.
    try expectRun("(a\nbc\x01\x01", "(a\nbc", 3, .unchanged);
}

test "apply: Ctrl-U and Ctrl-K act on the cursor's line" {
    try expectRun("(a\nbcd\nef\x1b[D\x1b[D\x1b[D\x1b[D\x1b[D\x0b", "(a\nb\nef", 4, .edited);
    try expectRun("(a\nbcd\nef\x1b[D\x1b[D\x1b[D\x1b[D\x1b[D\x15", "(a\ncd\nef", 3, .edited);
}

test "apply: Ctrl-U and Ctrl-K remove no newline at the line's edges" {
    try expectRun("(a\nb\x1b[D\x15", "(a\nb", 3, .unchanged);
    try expectRun("(a\nb\x1b[D\x1b[D\x0b", "(a\nb", 2, .unchanged);
}

test "vertical: Up and Down cross a newline" {
    // Row 0 is `> (abc`, row 1 is the marker and `de`.
    try expectRun("(abc\nde\x1b[A", "(abc\nde", 2, .edited);
    try expectRun("(abc\nde\x1b[A\x1b[B", "(abc\nde", 7, .edited);
}

test "vertical: Up and Down cross a wrap" {
    var result = try run("abcdefghij\x1b[A", .{ .columns = 8, .prompt = 2, .marker = 2 });
    defer result[0].deinit();
    // Row 1 is `ghij` from column 0, so the end at column 4 is below `c`.
    try std.testing.expectEqual(2, result[0].cursor);
    try std.testing.expectEqual(Outcome.edited, result[1]);
}

test "vertical: a run keeps its goal column through a shorter row" {
    // The cursor is after `(abcdef` at column 9. Row 1 ends at column 3, and
    // row 0 is back at column 9.
    try expectRun("(abcdef\nx\nyyyyyyy\x1b[A\x1b[A", "(abcdef\nx\nyyyyyyy", 7, .edited);
    try expectRun("(abcdef\nx\nyyyyyyy\x1b[A\x1b[A\x1b[B\x1b[B", "(abcdef\nx\nyyyyyyy", 17, .edited);
    // Any other key ends the run, and the next takes the column afresh:
    // Left puts the cursor at column 8, and two rows down is column 8 too.
    try expectRun("(abcdef\nx\nyyyyyyy\x1b[A\x1b[A\x1b[D\x1b[B\x1b[B", "(abcdef\nx\nyyyyyyy", 16, .edited);
}

test "vertical: a column inside the marker names the row's first byte" {
    // `(abc` puts the cursor at column 2 on row 0, which is inside a marker
    // six columns wide on row 1.
    var result = try run("(\nabcdef\x1b[A\x01\x1b[B", .{ .columns = 80, .prompt = 2, .marker = 6 });
    defer result[0].deinit();
    try std.testing.expectEqual(2, result[0].cursor);
}

test "vertical: Up on the first row and Down on the last are beyond the buffer" {
    try expectRun("(ab\x1b[A", "(ab", 3, .beyond);
    try expectRun("(a\nb\x1b[B", "(a\nb", 4, .beyond);
}

test "replace: the cursor goes to the end and the run of vertical moves ends" {
    var result = try run("(abc\nde\x1b[A", .{ .columns = 80, .prompt = 2, .marker = 2 });
    defer result[0].deinit();
    try result[0].replace("(x\ny)");
    try std.testing.expectEqualStrings("(x\ny)", result[0].buffer.items);
    try std.testing.expectEqual(5, result[0].cursor);
    try std.testing.expectEqual(null, result[0].goal);
}
