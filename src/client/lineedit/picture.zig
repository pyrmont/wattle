//! A text picture of the screen that `layout.zig` describes, for the layout's
//! tests and for `res/tools/layout.zig`.
//!
//! The editor does not import this file. `draw` places each rune at the row
//! and column that `layout.position` reports for its offset, and at no other
//! place, so a picture shows the position query and nothing derived
//! separately.
//!
//! ## The format
//!
//! The first line is `rows N`, with the row count from `layout.rows`. Each row
//! follows as `|` and the row's cells and `|`, one cell per terminal column.
//!
//! - A cell with no rune is a space, so trailing space is visible and every
//!   row is the terminal's width.
//!
//! - A wide rune fills its first cell, and the cell it covers is written as
//!   nothing, so the row is as wide on the screen as the terminal.
//!
//! - A zero-width rune is appended to the cell before its column. A C0
//!   control character or DEL is drawn as `rune.caret` returns it, across two
//!   cells, and a C1 control character is not drawn. A newline is not drawn,
//!   because the break is the picture's own line break.
//!
//! - A byte that does not begin a valid UTF-8 sequence is drawn as U+FFFD.
//!
//! - A rune at a column past the terminal's width is not drawn. Only a rune
//!   wider than the terminal is placed there.

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

/// One column of one row of the picture.
///
/// `bytes` is the UTF-8 drawn in the cell, and grows with each zero-width rune
/// appended to it. `covered` is set on the second column of a wide rune.
const Cell = struct {
    bytes: std.ArrayList(u8) = .empty,
    covered: bool = false,
};

// ==========================================================================
// Public functions
// ==========================================================================

/// Writes the picture of `buffer` laid out against `geometry` to `out`.
///
/// `allocator` holds the grid of cells and their bytes for the duration of the
/// call. This function returns the allocator's error, or the writer's.
pub fn draw(allocator: std.mem.Allocator, geometry: layout.Geometry, buffer: []const u8, out: *std.Io.Writer) !void {
    const rows = layout.rows(geometry, buffer);
    const grid = try allocator.alloc(Cell, rows * geometry.columns);
    @memset(grid, .{});
    defer {
        for (grid) |*cell| cell.bytes.deinit(allocator);
        allocator.free(grid);
    }

    var i: usize = 0;
    while (i < buffer.len) {
        const r = rune.decode(buffer[i..]);
        defer i += r.len;
        if (buffer[i] == '\n') continue;
        const p = layout.position(geometry, buffer, i);
        const w = rune.width(r);
        const shown = rune.caret(r);
        const text: []const u8 = if (r.codepoint == null) "\u{fffd}" else if (shown) |*s| s else buffer[i..][0..r.len];
        if (w == 0) {
            if (control(r) or p.column == 0 or p.column > geometry.columns) continue;
            try grid[p.row * geometry.columns + p.column - 1].bytes.appendSlice(allocator, text);
            continue;
        }
        if (p.column >= geometry.columns) continue;
        const row = grid[p.row * geometry.columns ..][0..geometry.columns];
        try row[p.column].bytes.appendSlice(allocator, text);
        var c = p.column + 1;
        while (c < p.column + w and c < geometry.columns) : (c += 1) row[c].covered = true;
    }

    try out.print("rows {d}\n", .{rows});
    for (0..rows) |r| {
        try out.writeByte('|');
        for (grid[r * geometry.columns ..][0..geometry.columns]) |cell| {
            if (cell.bytes.items.len > 0) {
                try out.writeAll(cell.bytes.items);
            } else if (!cell.covered) {
                try out.writeByte(' ');
            }
        }
        try out.writeAll("|\n");
    }
}

// ==========================================================================
// Private functions
// ==========================================================================

/// Checks whether `r` is a C1 control character, the controls of width 0.
fn control(r: rune.Rune) bool {
    const c = r.codepoint orelse return false;
    return c >= 0x80 and c <= 0x9f;
}

// ==========================================================================
// Tests
// ==========================================================================

test "draw: every zero-width rune after a base is drawn in its cell" {
    // Eight combining marks after one base, more than a fixed-size cell of
    // sixteen bytes would take.
    const marks = "\u{301}" ** 8;
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try draw(std.testing.allocator, .{ .columns = 4, .prompt = 0, .marker = 0 }, "e" ++ marks ++ "x", &out.writer);
    try std.testing.expectEqualStrings("rows 1\n|e" ++ marks ++ "x  |\n", out.written());
}
