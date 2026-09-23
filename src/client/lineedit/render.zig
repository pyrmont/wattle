//! The bytes that draw the line editor's prompt and buffer on the terminal.
//!
//! `session.zig` calls `draw` once for the keys of each read that change the
//! line, and `erase` before output that goes above the line. Both write to a
//! `std.Io.Writer` and never to the terminal, so a frame can be compared byte
//! for byte without one. A _frame_ is the bytes one `draw` writes.
//!
//! ## Rows and the window
//!
//! A _display row_ is a layout row, or the row a frame adds below a full last
//! row for the cursor at the end of the buffer. The _window_ is the display
//! rows a frame draws: all of them when the terminal's height is not limited
//! or they fit in it, and otherwise as many as the height, chosen as below.
//! The _climb_ is the number of rows the terminal's cursor is below the
//! window's first row after a frame, which is how far the next frame or
//! erase moves up before it begins.
//!
//! - The window keeps its first row from the last frame where the cursor's
//!   row is still inside it, and otherwise moves by the fewest rows that put
//!   the cursor's row at its top or its bottom. Rows above the window have
//!   scrolled off the screen, and a cursor movement cannot reach them, so the
//!   cursor's row is always drawn.
//!
//! - A frame with no height limit draws every row from the prompt's. The frame
//!   at submission is one, so the submitted line is left whole on the screen
//!   and in the scrollback, and the rows above the window are drawn again.
//!
//! ## How a frame is drawn
//!
//! - A frame begins with `\r`, a move up by the climb and `\x1b[J`, so it
//!   starts at the window's first row with that row and every row below it
//!   cleared. Clearing first means nothing is cleared from a full row's last
//!   cell, where the terminal has not yet wrapped and a clear would erase
//!   the rune in that cell.
//!
//! - Every row break is written by the frame, as `\r\n`, at the rune where
//!   `layout.wraps` reports one and at each newline. The terminal's own wrap
//!   is never relied on, so a wide rune or a caret pair that does not fit is
//!   moved whole, as `layout.zig` places it.
//!
//! - The prompt is written when its row is in the window. A row after the
//!   window is not written, and no break is written after the window's last
//!   row.
//!
//! - The _marker_ is spaces as wide as the prompt's columns, written at the
//!   start of each row a newline opens, including the window's first row. A
//!   row a wrap opens has no marker, so the two kinds of break can be told
//!   apart, and a line's text under the marker begins in the column where the
//!   first line's text begins.
//!
//! - The cursor is then moved from where drawing stopped to its position, by
//!   rows up and columns right from the row's start. No movement is written
//!   when the cursor is at the end of the buffer and drawing stopped there.
//!
//! A C0 control character and DEL are drawn in caret notation, a C1 control
//! character is not drawn, and a byte that begins no valid UTF-8 sequence is
//! drawn as U+FFFD, so each rune occupies the width `rune.width` reports.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const layout = @import("layout.zig");
const rune = @import("rune.zig");

// ==========================================================================
// Types
// ==========================================================================

/// What one frame draws.
///
/// `draw` takes a `Frame`. `prompt` is written as it stands on the first
/// row, `buffer` is the text being edited, `cursor` is a byte offset into
/// `buffer`, and `columns` is the terminal's width. `height` is the most
/// rows the frame draws, 0 for no limit, and `top` is the first display row
/// of the last frame's window.
pub const Frame = struct {
    prompt: []const u8,
    buffer: []const u8,
    cursor: usize,
    columns: usize,
    height: usize = 0,
    top: usize = 0,
};

/// Where a frame left the terminal.
///
/// `draw` returns a `Drawn`. `climb` is the climb after the frame and `top`
/// is the first display row of its window, which the next frame takes as
/// `Frame.top`.
pub const Drawn = struct {
    climb: usize,
    top: usize,
};

// ==========================================================================
// Public functions
// ==========================================================================

/// Writes a frame, and returns where it left the terminal.
///
/// `out` receives the bytes, `climb` is the climb the previous frame
/// returned, or 0 when the cursor is at the start of an empty row, and
/// `frame` is what to draw. This function returns the writer's error.
pub fn draw(out: *std.Io.Writer, climb: usize, frame: Frame) std.Io.Writer.Error!Drawn {
    const geometry = geometryOf(frame.prompt, frame.columns);
    const end = layout.position(geometry, frame.buffer, frame.buffer.len);
    const extra_row = end.column >= frame.columns;
    const display_rows = end.row + 1 + @intFromBool(extra_row);

    var target = layout.position(geometry, frame.buffer, frame.cursor);
    if (target.column >= frame.columns) {
        if (frame.cursor >= frame.buffer.len) {
            target = .{ .row = target.row + 1, .column = 0 };
        } else {
            target.column = frame.columns - 1;
        }
    }

    var first: usize = 0;
    var last = display_rows;
    if (frame.height > 0 and display_rows > frame.height) {
        first = @min(frame.top, display_rows - frame.height);
        if (target.row < first) first = target.row;
        if (target.row >= first + frame.height) first = target.row + 1 - frame.height;
        last = first + frame.height;
    }

    try top(out, climb);
    try out.writeAll("\x1b[J");
    if (first == 0) try out.writeAll(frame.prompt);

    var row: usize = 0;
    var column = geometry.prompt;
    var stopped = false;
    var i: usize = 0;
    while (i < frame.buffer.len) {
        const newline = frame.buffer[i] == '\n';
        const r = rune.decode(frame.buffer[i..]);
        const w: usize = if (newline) 0 else rune.width(r);
        if (newline or layout.wraps(column, w, frame.columns)) {
            if (row + 1 >= last) {
                stopped = true;
                break;
            }
            if (row >= first) try out.writeAll("\r\n");
            row += 1;
            column = if (newline) geometry.marker else 0;
            if (newline) {
                if (row >= first) try out.splatByteAll(' ', geometry.marker);
                i += 1;
                continue;
            }
        }
        if (row >= first) try drawRune(out, r, frame.buffer[i..][0..r.len]);
        column += w;
        i += r.len;
    }
    // A full last row leaves the terminal waiting to wrap. The display row
    // below makes the cursor's place definite.
    if (!stopped and extra_row and last == display_rows) {
        // Where that row is the whole window, the cursor is on it already.
        if (row >= first) try out.writeAll("\r\n");
        row += 1;
        column = 0;
    }

    if (stopped or target.row != row or target.column != column) {
        if (row > target.row) try out.print("\x1b[{d}A", .{row - target.row});
        try out.writeByte('\r');
        if (target.column > 0) try out.print("\x1b[{d}C", .{target.column});
    }
    return .{ .climb = target.row - first, .top = first };
}

/// Clears the rows a frame occupies, and leaves the cursor at the start of
/// the window's first row.
///
/// `out` receives the bytes and `climb` is the climb the last frame
/// returned. The climb after this function is 0. This function returns the
/// writer's error.
pub fn erase(out: *std.Io.Writer, climb: usize) std.Io.Writer.Error!void {
    try top(out, climb);
    try out.writeAll("\x1b[J");
}

/// Returns the layout a frame draws a buffer with, after `prompt` on a
/// terminal `columns` wide.
///
/// The marker is as wide as the prompt.
pub fn geometryOf(prompt: []const u8, columns: usize) layout.Geometry {
    const width = promptWidth(prompt);
    return .{ .columns = columns, .prompt = width, .marker = width };
}

/// Returns the number of columns `prompt` occupies on the terminal.
///
/// A frame writes the prompt as it stands, so an escape sequence in it
/// styles the prompt and occupies no column. Three forms are skipped: a CSI,
/// from `ESC [` to a final byte from `@` to `~`; an OSC, from `ESC ]` to BEL
/// or `ESC \`; and `ESC` with any intermediate bytes, from space to `/`, and
/// one final byte. Every other rune is measured by `rune.width`. An
/// unterminated sequence occupies no column to the end of `prompt`.
pub fn promptWidth(prompt: []const u8) usize {
    var total: usize = 0;
    var i: usize = 0;
    while (i < prompt.len) {
        if (prompt[i] == 0x1b) {
            i = pastEscape(prompt, i);
            continue;
        }
        const r = rune.decode(prompt[i..]);
        total += rune.width(r);
        i += r.len;
    }
    return total;
}

// ==========================================================================
// Private functions
// ==========================================================================

/// Writes one rune as a frame draws it.
///
/// `bytes` are the rune's bytes in the buffer.
fn drawRune(out: *std.Io.Writer, r: rune.Rune, bytes: []const u8) std.Io.Writer.Error!void {
    if (r.codepoint == null) return out.writeAll("\u{fffd}");
    if (rune.caret(r)) |pair| return out.writeAll(&pair);
    // A C1 control has width 0 and a terminal may act on it, so it is not
    // written.
    if (r.codepoint.? >= 0x80 and r.codepoint.? <= 0x9f) return;
    try out.writeAll(bytes);
}

/// Returns the offset after the escape sequence that begins at `at` in
/// `text`, as `promptWidth` delimits it.
fn pastEscape(text: []const u8, at: usize) usize {
    var i = at + 1;
    if (i >= text.len) return i;
    switch (text[i]) {
        '[' => {
            i += 1;
            while (i < text.len) : (i += 1) {
                if (text[i] >= 0x40 and text[i] <= 0x7e) return i + 1;
            }
            return i;
        },
        ']' => {
            i += 1;
            while (i < text.len) : (i += 1) {
                if (text[i] == 0x07) return i + 1;
                if (text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '\\') return i + 2;
            }
            return i;
        },
        else => {
            while (i < text.len and text[i] >= 0x20 and text[i] <= 0x2f) i += 1;
            return @min(i + 1, text.len);
        },
    }
}

/// Moves the cursor to the start of the window's first row.
fn top(out: *std.Io.Writer, climb: usize) std.Io.Writer.Error!void {
    try out.writeByte('\r');
    if (climb > 0) try out.print("\x1b[{d}A", .{climb});
}

// ==========================================================================
// Tests
// ==========================================================================

/// Draws `frame` after a frame that left the climb at `climb`, and checks
/// the bytes, the climb and the window's first row returned.
fn expectFrame(expected: []const u8, expected_drawn: Drawn, climb: usize, frame: Frame) !void {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const got = try draw(&out.writer, climb, frame);
    try std.testing.expectEqualStrings(expected, out.written());
    try std.testing.expectEqual(expected_drawn, got);
}

test "draw: the cursor at the end writes no movement" {
    try expectFrame("\r\x1b[Jrepl:1:> (+ 1 2)", .{ .climb = 0, .top = 0 }, 0, .{
        .prompt = "repl:1:> ",
        .buffer = "(+ 1 2)",
        .cursor = 7,
        .columns = 80,
    });
}

test "draw: an empty buffer is the prompt alone" {
    try expectFrame("\r\x1b[Jrepl:2:> ", .{ .climb = 0, .top = 0 }, 0, .{ .prompt = "repl:2:> ", .buffer = "", .cursor = 0, .columns = 80 });
}

test "draw: the cursor inside the buffer is placed from the row's start" {
    try expectFrame("\r\x1b[J> abc\r\x1b[3C", .{ .climb = 0, .top = 0 }, 0, .{ .prompt = "> ", .buffer = "abc", .cursor = 1, .columns = 80 });
    try expectFrame("\r\x1b[J> abc\r\x1b[2C", .{ .climb = 0, .top = 0 }, 0, .{ .prompt = "> ", .buffer = "abc", .cursor = 0, .columns = 80 });
}

test "draw: a wrap is written as a row break, and the climb counts it" {
    // Eight columns: the prompt and six runes fill row 0, and the seventh
    // rune opens row 1 in column 0.
    try expectFrame("\r\x1b[J> abcdef\r\ngh", .{ .climb = 1, .top = 0 }, 0, .{ .prompt = "> ", .buffer = "abcdefgh", .cursor = 8, .columns = 8 });
}

test "draw: a frame starts by climbing the previous climb" {
    try expectFrame("\r\x1b[1A\x1b[J> abcdef\r\ngh\x1b[1A\r\x1b[2C", .{ .climb = 0, .top = 0 }, 1, .{
        .prompt = "> ",
        .buffer = "abcdefgh",
        .cursor = 0,
        .columns = 8,
    });
}

test "draw: a full last row adds a display row for the cursor" {
    try expectFrame("\r\x1b[J> abcdef\r\n", .{ .climb = 1, .top = 0 }, 0, .{ .prompt = "> ", .buffer = "abcdef", .cursor = 6, .columns = 8 });
}

test "draw: a cursor on a full row's last rune is not moved to the display row" {
    try expectFrame("\r\x1b[J> abcdef\r\n\x1b[1A\r\x1b[7C", .{ .climb = 0, .top = 0 }, 0, .{
        .prompt = "> ",
        .buffer = "abcdef",
        .cursor = 5,
        .columns = 8,
    });
}

test "draw: a wide rune that does not fit moves whole" {
    // Seven columns in all, so the wide rune offered column 6 is drawn on
    // row 1.
    try expectFrame("\r\x1b[J> abcd\r\n度", .{ .climb = 1, .top = 0 }, 0, .{ .prompt = "> ", .buffer = "abcd度", .cursor = 7, .columns = 7 });
}

test "draw: a tab is drawn in caret notation at the width the layout measures" {
    try expectFrame("\r\x1b[J> a^Ib\r\x1b[5C", .{ .climb = 0, .top = 0 }, 0, .{ .prompt = "> ", .buffer = "a\tb", .cursor = 2, .columns = 80 });
    const geometry: layout.Geometry = .{ .columns = 80, .prompt = 2, .marker = 0 };
    try std.testing.expectEqual(layout.Position{ .row = 0, .column = 5 }, layout.position(geometry, "a\tb", 2));
}

test "draw: an invalid byte is drawn as U+FFFD" {
    try expectFrame("\r\x1b[J> a\u{fffd}b", .{ .climb = 0, .top = 0 }, 0, .{ .prompt = "> ", .buffer = "a\x80b", .cursor = 3, .columns = 80 });
}

test "draw: the end of each frame is where the layout puts the end of the buffer" {
    const buffers = [_][]const u8{ "", "abc", "abcdefgh", "abcdef", "度度度度", "a\tb\tc\td", "e\u{301}xyz", "\x80\x80\x80\x80\x80" };
    for (buffers) |buffer| {
        for ([_]usize{ 1, 2, 3, 5, 8, 13 }) |columns| {
            var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer out.deinit();
            const drawn = try draw(&out.writer, 0, .{ .prompt = "> ", .buffer = buffer, .cursor = buffer.len, .columns = columns });
            const end = layout.position(.{ .columns = columns, .prompt = 2, .marker = 2 }, buffer, buffer.len);
            const expected = if (end.column >= columns) end.row + 1 else end.row;
            try std.testing.expectEqual(expected, drawn.climb);
            // No movement is written when the cursor is at the end: the only
            // sequence is the clear at the start.
            try std.testing.expectEqual(null, std.mem.indexOfPos(u8, out.written(), 4, "\x1b["));
        }
    }
}

test "draw: a coloured prompt is measured by its visible width" {
    try expectFrame("\r\x1b[J\x1b[31m> \x1b[0mabc\r\x1b[4C", .{ .climb = 0, .top = 0 }, 0, .{
        .prompt = "\x1b[31m> \x1b[0m",
        .buffer = "abc",
        .cursor = 2,
        .columns = 80,
    });
}

test "draw: a coloured prompt wraps at the visible width" {
    try expectFrame("\r\x1b[J\x1b[1m> \x1b[22mabcdef\r\ngh", .{ .climb = 1, .top = 0 }, 0, .{
        .prompt = "\x1b[1m> \x1b[22m",
        .buffer = "abcdefgh",
        .cursor = 8,
        .columns = 8,
    });
}

/// A buffer that fills three rows of eight columns after a two-column
/// prompt, so a fourth display row holds the cursor at its end.
const tall = "abcdefghijklmnopqrstuv";

test "draw: a window as high as the terminal ends at the cursor's row" {
    try expectFrame("\r\x1b[Jopqrstuv\r\n", .{ .climb = 1, .top = 2 }, 0, .{
        .prompt = "> ",
        .buffer = tall,
        .cursor = tall.len,
        .columns = 8,
        .height = 2,
    });
}

test "draw: moving above the window moves the window up to the cursor" {
    try expectFrame("\r\x1b[1A\x1b[J> abcdef\r\nghijklmn\x1b[1A\r\x1b[2C", .{ .climb = 0, .top = 0 }, 1, .{
        .prompt = "> ",
        .buffer = tall,
        .cursor = 0,
        .columns = 8,
        .height = 2,
        .top = 2,
    });
}

test "draw: a window keeps its first row while the cursor is inside it" {
    try expectFrame("\r\x1b[Jghijklmn\r\nopqrstuv\x1b[1A\r", .{ .climb = 0, .top = 1 }, 0, .{
        .prompt = "> ",
        .buffer = tall,
        .cursor = 6,
        .columns = 8,
        .height = 2,
        .top = 1,
    });
}

test "draw: a frame with no height limit draws every row" {
    try expectFrame("\r\x1b[1A\x1b[J> abcdef\r\nghijklmn\r\nopqrstuv\r\n", .{ .climb = 3, .top = 0 }, 1, .{
        .prompt = "> ",
        .buffer = tall,
        .cursor = tall.len,
        .columns = 8,
    });
}

test "draw: a window draws no more rows than the height and includes the cursor's row" {
    const buffers = [_][]const u8{ tall, "a\nb\nc\nd\ne\nf", "度度度度度度度度度度", "abcdefgh" ** 5 };
    for (buffers) |buffer| {
        for ([_]usize{ 1, 2, 3, 5 }) |height| {
            var previous: usize = 0;
            var cursor: usize = 0;
            while (cursor <= buffer.len) : (cursor += 1) {
                var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
                defer out.deinit();
                const drawn = try draw(&out.writer, 0, .{
                    .prompt = "> ",
                    .buffer = buffer,
                    .cursor = cursor,
                    .columns = 8,
                    .height = height,
                    .top = previous,
                });
                try std.testing.expect(std.mem.count(u8, out.written(), "\r\n") < height);
                try std.testing.expect(drawn.climb < height);
                previous = drawn.top;
            }
        }
    }
}

test "draw: a newline opens a row with the marker, and a wrap one without" {
    try expectFrame("\r\x1b[J> (a\r\n  bcdefg\r\nh", .{ .climb = 2, .top = 0 }, 0, .{
        .prompt = "> ",
        .buffer = "(a\nbcdefgh",
        .cursor = 10,
        .columns = 8,
    });
}

test "draw: the marker is as wide as a coloured prompt's columns" {
    try expectFrame("\r\x1b[J\x1b[31mrepl:1:> \x1b[0m(+ 1\r\n         2)", .{ .climb = 1, .top = 0 }, 0, .{
        .prompt = "\x1b[31mrepl:1:> \x1b[0m",
        .buffer = "(+ 1\n2)",
        .cursor = 7,
        .columns = 80,
    });
}

test "draw: a window whose first row a newline opened begins with the marker" {
    try expectFrame("\r\x1b[J  b\r\n  c", .{ .climb = 1, .top = 1 }, 0, .{
        .prompt = "> ",
        .buffer = "a\nb\nc",
        .cursor = 5,
        .columns = 8,
        .height = 2,
    });
}

test "promptWidth: each escape form occupies no column" {
    try std.testing.expectEqual(2, promptWidth("\x1b[1;31m> \x1b[0m"));
    try std.testing.expectEqual(2, promptWidth("\x1b]0;title\x07> "));
    try std.testing.expectEqual(2, promptWidth("\x1b]0;title\x1b\\> "));
    try std.testing.expectEqual(2, promptWidth("\x1b(B> "));
    try std.testing.expectEqual(0, promptWidth("\x1b[31"));
    try std.testing.expectEqual(4, promptWidth("度> "));
}

test "erase: climbs and clears" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try erase(&out.writer, 2);
    try std.testing.expectEqualStrings("\r\x1b[2A\x1b[J", out.written());
}
