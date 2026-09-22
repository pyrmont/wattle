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
//! ## Enter
//!
//! Enter and Ctrl-J both submit the buffer. The editor does not read the
//! parser's status, so neither key inserts a newline.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const keys = @import("keys.zig");
const rune = @import("rune.zig");

// ==========================================================================
// Types
// ==========================================================================

/// What applying a key did.
///
/// `Editor.apply` returns an `Outcome`. `unchanged` and `edited` leave the
/// line open, and `edited` says the buffer or the cursor changed. `submit`,
/// `eof` and `cancel` end the line: `submit` with the buffer as it stands,
/// `eof` at Ctrl-D on an empty buffer, and `cancel` at Ctrl-C.
pub const Outcome = enum { unchanged, edited, submit, eof, cancel };

/// The buffer being edited and the cursor in it.
///
/// `init` returns an `Editor` and `deinit` releases it. `buffer` is the
/// bytes typed so far and `cursor` is a byte offset into them.
pub const Editor = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8) = .empty,
    cursor: usize = 0,

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
    /// The buffer's memory is kept for the next line.
    pub fn clear(editor: *Editor) void {
        editor.buffer.clearRetainingCapacity();
        editor.cursor = 0;
    }

    /// Applies `key` to the buffer and the cursor, and returns what it did.
    ///
    /// This function returns `error.OutOfMemory` when an insertion cannot
    /// grow the buffer, and the buffer is then unchanged.
    pub fn apply(editor: *Editor, key: keys.Key) error{OutOfMemory}!Outcome {
        const text = editor.buffer.items;
        switch (key) {
            .insert => |r| {
                try editor.buffer.insertSlice(editor.allocator, editor.cursor, r.slice());
                editor.cursor += r.len;
                return .edited;
            },
            .left => return editor.moveTo(previous(text, editor.cursor)),
            .right => return editor.moveTo(next(text, editor.cursor)),
            .home => return editor.moveTo(0),
            .end => return editor.moveTo(text.len),
            .backspace => {
                if (editor.cursor == 0) return .unchanged;
                const start = previous(text, editor.cursor);
                editor.remove(start, editor.cursor);
                editor.cursor = start;
                return .edited;
            },
            .delete => return editor.deleteForward(),
            .kill_end => {
                if (editor.cursor == text.len) return .unchanged;
                editor.remove(editor.cursor, text.len);
                return .edited;
            },
            .kill_start => {
                if (editor.cursor == 0) return .unchanged;
                editor.remove(0, editor.cursor);
                editor.cursor = 0;
                return .edited;
            },
            .enter, .newline => return .submit,
            .eof => {
                if (text.len == 0) return .eof;
                return editor.deleteForward();
            },
            .interrupt => return .cancel,
            .ignored => return .unchanged,
        }
    }

    /// Deletes the rune at the cursor.
    fn deleteForward(editor: *Editor) Outcome {
        const text = editor.buffer.items;
        if (editor.cursor == text.len) return .unchanged;
        editor.remove(editor.cursor, next(text, editor.cursor));
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

test "apply: Enter and Ctrl-J submit, Ctrl-C cancels" {
    try std.testing.expectEqual(Outcome.submit, try lastOutcome("abc\r"));
    try std.testing.expectEqual(Outcome.submit, try lastOutcome("abc\n"));
    try std.testing.expectEqual(Outcome.cancel, try lastOutcome("abc\x03"));
}
