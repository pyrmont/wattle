//! The layout of the line editor's buffer on the terminal: which row and
//! column each byte is drawn at, and which byte a row and column name.
//!
//! The editor and `res/tools/layout.zig` import this file. A _position_ is a
//! row, counted from the prompt's row, and an absolute terminal column. Column
//! 0 is the terminal's left edge, so row 0 begins after the prompt and a row
//! opened by a newline begins after the continuation marker. The _marker_ is
//! what the editor draws at the start of a row that a newline opens.
//!
//! ## Two kinds of row break
//!
//! A newline is a byte in the buffer, and the row it opens begins after the
//! marker. A _wrap_ is a break the terminal imposes when a rune does not fit
//! on the row. It occupies no byte, and the row it opens begins in column 0.
//!
//! - A newline ends the row it is on. Its position is the last on that row
//!   and the byte after it is the first on the next, so the end of a line is
//!   before its newline.
//!
//! - A wrap is applied before the rune's position is recorded. The rune that
//!   wrapped is drawn on the new row, and the cursor on that rune is on the new
//!   row too.
//!
//! - A rune never wraps at column 0. A rune wider than the terminal occupies a
//!   row of its own, and the walk always advances.
//!
//! - Widths come from `rune.width` and never from byte counts.
//!
//! ## One walk for both queries
//!
//! `position` and `offset` are the same traversal, `walk`, with a different
//! target. Two separate traversals could place a byte differently, and the
//! cursor would then be drawn away from the text. `rows` is the same walk with
//! no target.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const picture = @import("picture.zig");
const rune = @import("rune.zig");

// ==========================================================================
// Types
// ==========================================================================

/// The terminal and prompt dimensions a buffer is laid out against.
///
/// Every function in this file takes a `Geometry`. `columns` is the
/// terminal's width, `prompt` the width of the prompt on row 0, and `marker`
/// the width of the marker on each row a newline opens. The two widths are
/// independent.
pub const Geometry = struct {
    columns: usize,
    prompt: usize,
    marker: usize,
};

/// A row and an absolute terminal column.
///
/// `position` returns a `Position` and `offset` takes one.
pub const Position = struct {
    row: usize,
    column: usize,
};

/// The result of one `walk`.
///
/// `position` is where the requested offset is drawn, `offset` is the byte the
/// requested position names, and `rows` is the number of rows the buffer
/// occupies.
const Walk = struct {
    position: Position,
    offset: usize,
    rows: usize,
};

// ==========================================================================
// Public functions
// ==========================================================================

/// Returns the offset of the byte drawn at `target` in `buffer`.
///
/// A column before the start of the target row names the row's first byte. A
/// column past the end of the row names its last position: the newline that
/// ends it, or the last rune before a wrap. A row past the last names the end
/// of the buffer. The result is at most `buffer.len`.
pub fn offset(geometry: Geometry, buffer: []const u8, target: Position) usize {
    return walk(geometry, buffer, null, target).offset;
}

/// Returns where the byte at `at` in `buffer` is drawn.
///
/// `at` of `buffer.len` is the position after the last byte, where the cursor
/// is after typing. An `at` inside a rune names the next rune, and an `at`
/// past the end names the end.
pub fn position(geometry: Geometry, buffer: []const u8, at: usize) Position {
    return walk(geometry, buffer, @min(at, buffer.len), null).position;
}

/// Returns the number of rows `buffer` occupies, including the prompt's row.
///
/// The result is at least 1. A row that the renderer adds after a rune fills
/// the rightmost column is not a row of the layout and is not counted.
pub fn rows(geometry: Geometry, buffer: []const u8) usize {
    return walk(geometry, buffer, null, null).rows;
}

/// Checks whether a rune `w` columns wide, offered at `column`, is drawn on the
/// next row.
///
/// `columns` is the terminal's width. The result is false at column 0 for
/// every width. The renderer calls this function wherever it decides that a
/// row ends, so that it and the layout end rows at the same rune.
pub fn wraps(column: usize, w: usize, columns: usize) bool {
    return column != 0 and column + w > columns;
}

// ==========================================================================
// Private functions
// ==========================================================================

/// Walks `buffer` once, and records where `at` is drawn and which offset
/// `target` names.
///
/// A null `at` or `target` is not looked for. `position`, `offset` and `rows`
/// are the callers, and each reads one field of the result.
fn walk(geometry: Geometry, buffer: []const u8, at: ?usize, target: ?Position) Walk {
    var result: Walk = .{
        .position = .{ .row = 0, .column = geometry.prompt },
        .offset = buffer.len,
        .rows = 1,
    };
    var placed = false;
    var found = false;
    var row: usize = 0;
    var column = geometry.prompt;
    var i: usize = 0;
    var previous: usize = 0;
    while (true) {
        const newline = i < buffer.len and buffer[i] == '\n';
        var len: usize = 1;
        var w: usize = 0;
        // The wrap is applied before the position is recorded below, so a
        // rune that wraps is placed on the new row.
        if (i < buffer.len and !newline) {
            const r = rune.decode(buffer[i..]);
            len = r.len;
            w = rune.width(r);
            if (wraps(column, w, geometry.columns)) {
                row += 1;
                column = 0;
            }
        }
        if (at) |a| {
            if (!placed and i >= a) {
                result.position = .{ .row = row, .column = column };
                placed = true;
            }
        }
        if (target) |t| {
            if (!found and row > t.row) {
                // The target row ended before the target column, so the
                // offset is the last one on that row.
                result.offset = previous;
                found = true;
            } else if (!found and row == t.row and column >= t.column) {
                result.offset = i;
                found = true;
            }
        }
        previous = i;
        if (i >= buffer.len) break;
        if (newline) {
            row += 1;
            column = geometry.marker;
        } else {
            column += w;
        }
        i += len;
    }
    result.rows = row + 1;
    return result;
}

// ==========================================================================
// Tests
// ==========================================================================

/// Draws `buffer` against `geometry` with `picture.draw`, then appends a `pos`
/// line for each of `at` and an `off` line for each of `targets`.
///
/// The format is `res/tools/layout.zig`'s. `picture.draw` places each rune by
/// `position` alone, and each expected picture in the cases below is written
/// by hand.
fn drawn(geometry: Geometry, buffer: []const u8, at: []const usize, targets: []const Position) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try picture.draw(std.testing.allocator, geometry, buffer, &out.writer);
    for (at) |a| {
        const p = position(geometry, buffer, a);
        try out.writer.print("pos {d} {d} {d}\n", .{ a, p.row, p.column });
    }
    for (targets) |t| {
        try out.writer.print("off {d} {d} {d}\n", .{ t.row, t.column, offset(geometry, buffer, t) });
    }
    return out.toOwnedSlice();
}

fn expectDrawn(expected: []const u8, geometry: Geometry, buffer: []const u8, at: []const usize, targets: []const Position) !void {
    const got = try drawn(geometry, buffer, at, targets);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(expected, got);
}

const g30: Geometry = .{ .columns = 30, .prompt = 9, .marker = 9 };
const g20: Geometry = .{ .columns = 20, .prompt = 9, .marker = 9 };

test "position: a single line sits after the prompt" {
    try expectDrawn(
        \\rows 1
        \\|         (+ 1 2)              |
        \\
    , g30, "(+ 1 2)", &.{}, &.{});
}

test "rows: an empty buffer occupies a row" {
    try expectDrawn(
        \\rows 1
        \\|                              |
        \\pos 0 0 9
        \\
    , g30, "", &.{0}, &.{});
}

test "position: a newline opens a row after the marker" {
    try expectDrawn(
        \\rows 2
        \\|         (defn f [x]          |
        \\|           (+ x 1))           |
        \\
    , g30, "(defn f [x]\n  (+ x 1))", &.{}, &.{});
}

test "position: a newline ends the row it is on" {
    try expectDrawn(
        \\rows 2
        \\|         (defn f [x]          |
        \\|           (+ x 1))           |
        \\pos 11 0 20
        \\pos 12 1 9
        \\
    , g30, "(defn f [x]\n  (+ x 1))", &.{ 11, 12 }, &.{});
}

test "position: a blank line is a row of its own" {
    try expectDrawn(
        \\rows 3
        \\|         a                    |
        \\|                              |
        \\|         b                    |
        \\
    , g30, "a\n\nb", &.{}, &.{});
}

test "position: a leading newline leaves the prompt's row empty" {
    try expectDrawn(
        \\rows 2
        \\|                              |
        \\|         x                    |
        \\pos 0 0 9
        \\pos 1 1 9
        \\
    , g30, "\nx", &.{ 0, 1 }, &.{});
}

test "position: a wrap resumes in column 0" {
    try expectDrawn(
        \\rows 2
        \\|         (+ 1111 222|
        \\|2 3333)             |
        \\pos 11 1 0
        \\
    , g20, "(+ 1111 2222 3333)", &.{11}, &.{});
}

test "rows: a wrap after a newline counts its own row" {
    try expectDrawn(
        \\rows 3
        \\|         (do        |
        \\|           (+ 1111 2|
        \\|222 3333))          |
        \\
    , g20, "(do\n  (+ 1111 2222 3333))", &.{}, &.{});
}

test "position: a wide rune that does not fit moves to the next row whole" {
    try expectDrawn(
        \\rows 2
        \\|         度度 |
        \\|度            |
        \\pos 6 1 0
        \\
    , .{ .columns = 14, .prompt = 9, .marker = 9 }, "度度度", &.{6}, &.{});
}

test "position: a wide rune offered the last two columns takes them" {
    // A byte count would measure 度 as three columns and wrap it a row early.
    try expectDrawn(
        \\rows 3
        \\|                    |
        \\|         abcdefghi度|
        \\|度                  |
        \\
    , g20, "\nabcdefghi度度", &.{}, &.{});
}

test "position: a rune wider than the terminal still advances" {
    try expectDrawn(
        \\rows 2
        \\|度|
        \\|度|
        \\
    , .{ .columns = 1, .prompt = 0, .marker = 0 }, "度度", &.{}, &.{});
}

test "position: a marker narrower than the prompt" {
    try expectDrawn(
        \\rows 2
        \\|         a                    |
        \\|  b                           |
        \\
    , .{ .columns = 30, .prompt = 9, .marker = 2 }, "a\nb", &.{}, &.{});
}

test "offset: a column past the end of a row names its end" {
    try expectDrawn(
        \\rows 2
        \\|         (defn f [x]          |
        \\|           (+ x 1))           |
        \\off 0 99 11
        \\off 1 99 22
        \\
    , g30, "(defn f [x]\n  (+ x 1))", &.{}, &.{ .{ .row = 0, .column = 99 }, .{ .row = 1, .column = 99 } });
}

test "offset: a column past the end of a wrapped row names its last rune" {
    try expectDrawn(
        \\rows 2
        \\|         (+ 1111 222|
        \\|2 3333)             |
        \\off 0 99 10
        \\
    , g20, "(+ 1111 2222 3333)", &.{}, &.{.{ .row = 0, .column = 99 }});
}

test "offset: a row past the last names the end of the buffer" {
    try expectDrawn(
        \\rows 2
        \\|         a                    |
        \\|         b                    |
        \\off 9 0 3
        \\
    , g30, "a\nb", &.{}, &.{.{ .row = 9, .column = 0 }});
}

test "offset: a column inside the prompt or the marker names the row's first byte" {
    try expectDrawn(
        \\rows 2
        \\|         a                    |
        \\|         b                    |
        \\off 0 0 0
        \\off 1 0 2
        \\
    , g30, "a\nb", &.{}, &.{ .{ .row = 0, .column = 0 }, .{ .row = 1, .column = 0 } });
}

test "position: a combining mark is drawn with its base" {
    // The mark and the rune after it share a position, and the offset of that
    // position is the mark's.
    try expectDrawn("rows 1\n" ++
        "|         e\u{301}x                   |\n" ++
        "pos 1 0 10\n" ++
        "pos 3 0 10\n" ++
        "off 0 10 1\n", g30, "e\u{301}x", &.{ 1, 3 }, &.{.{ .row = 0, .column = 10 }});
}

test "position: an invalid byte is one column" {
    try expectDrawn(
        \\rows 1
        \\|         a�b                  |
        \\pos 2 0 11
        \\
    , g30, "a\x80b", &.{2}, &.{});
}

test "position: an offset inside a rune names the next rune" {
    try std.testing.expectEqual(Position{ .row = 0, .column = 11 }, position(g30, "度x", 1));
    try std.testing.expectEqual(Position{ .row = 0, .column = 11 }, position(g30, "度x", 3));
}

/// The buffers the round trip is checked over: newlines, wraps, wide runes,
/// combining marks, zero-width format characters and invalid bytes.
const corpus = [_][]const u8{
    "",
    "a",
    "\n",
    "\n\n",
    "(+ 1 2)",
    "(defn f [x]\n  (+ x 1)\n  (* x 2))",
    "(+ 1111 2222 3333 4444 5555 6666 7777 8888 9999)",
    "(do\n  (+ 1111 2222 3333))\n",
    "abcdefghi度度",
    "度度度度度度度度",
    "a度b度c度d度e度\n度a度b",
    "😀 (print \"héllo\") 😀😀",
    "e\u{301}x\u{301}\u{302}y",
    "\u{301}leading mark",
    "tab\there",
    "a\x80b\xe5\xbac\xff",
    "ends with a wide 度",
    "\n度\n\n度度\n",
    "Ａ\u{200b}Ｂ\u{200b}\u{200b}Ｃ",
};

/// Checks the round trip for every rune offset of `buffer`, and the end.
///
/// Positions must not decrease over increasing offsets. Offsets that share a
/// position must follow zero-width runes, and `offset` of that position must
/// be the first of them. The row count must be the end's row plus one.
fn expectRoundTrip(geometry: Geometry, buffer: []const u8) !void {
    const total = rows(geometry, buffer);
    var last: ?Position = null;
    var first_at: usize = 0;
    var previous_zero = false;
    var i: usize = 0;
    while (true) : (i += rune.decode(buffer[i..]).len) {
        const p = position(geometry, buffer, i);
        if (last) |l| {
            try std.testing.expect(p.row > l.row or (p.row == l.row and p.column >= l.column));
            if (p.row != l.row or p.column != l.column) {
                first_at = i;
            } else if (!previous_zero) {
                std.debug.print("columns {d} prompt {d} marker {d}: offset {d} shares {d},{d} with a rune of non-zero width\n", .{
                    geometry.columns, geometry.prompt, geometry.marker, i, p.row, p.column,
                });
                return error.RoundTrip;
            }
        }
        last = p;
        previous_zero = i < buffer.len and buffer[i] != '\n' and rune.width(rune.decode(buffer[i..])) == 0;
        const back = offset(geometry, buffer, p);
        if (back != first_at) {
            std.debug.print("columns {d} prompt {d} marker {d}: offset {d} drew at {d},{d} and resolved to {d}\n", .{
                geometry.columns, geometry.prompt, geometry.marker, i, p.row, p.column, back,
            });
            return error.RoundTrip;
        }
        if (i >= buffer.len) break;
    }
    try std.testing.expectEqual(total, last.?.row + 1);
}

test "position, offset: the round trip over the corpus at every geometry" {
    const widths = [_]usize{ 1, 2, 3, 5, 8, 13, 20, 80 };
    const pads = [_]usize{ 0, 2, 9 };
    for (corpus) |buffer| {
        for (widths) |columns| {
            for (pads) |prompt| {
                for (pads) |marker| {
                    try expectRoundTrip(.{ .columns = columns, .prompt = prompt, .marker = marker }, buffer);
                }
            }
        }
    }
}
