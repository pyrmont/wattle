//! Prints the line editor's layout of a buffer as a picture, and the answers
//! to position and offset queries.
//!
//! `zig build` builds this file as `<prefix>/test/wattle-layout`, which is not
//! installed for use. It imports the `lineedit` module, the code the editor
//! runs, and needs no terminal and no runtime.
//!
//! Usage: `wattle-layout -w COLS [-p PROMPT] [-m MARKER] [-o OFFSET]...
//! [-a ROW,COL]... < buffer`.
//!
//! `-w` is the terminal's width, `-p` the prompt's width, which defaults to 0,
//! and `-m` the marker's width, which defaults to the prompt's. The buffer is
//! standard input without its last byte if that byte is a newline, so that a
//! shell's trailing newline is not part of it. The output is `picture.draw`'s
//! picture, then `pos OFFSET ROW COL` for each `-o` and `off ROW COL OFFSET`
//! for each `-a`, in the order given.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const lineedit = @import("lineedit");

// ==========================================================================
// Constants
// ==========================================================================

/// The usage line printed when the arguments cannot be read.
const usage = "usage: wattle-layout -w COLS [-p PROMPT] [-m MARKER] [-o OFFSET]... [-a ROW,COL]...\n";

// ==========================================================================
// Public functions
// ==========================================================================

/// Reads the arguments and the buffer, and writes the picture and the
/// answers to standard output.
///
/// The result is 2 when the arguments cannot be read, and 0 otherwise.
pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();

    var columns: ?usize = null;
    var prompt: usize = 0;
    var marker: ?usize = null;
    var offsets: std.ArrayList(usize) = .empty;
    var targets: std.ArrayList(lineedit.layout.Position) = .empty;

    var args = try init.minimal.args.iterateAllocator(arena);
    defer args.deinit();
    _ = args.skip();
    while (args.next()) |flag| {
        const value = args.next() orelse return fail();
        if (std.mem.eql(u8, flag, "-w")) {
            columns = std.fmt.parseInt(usize, value, 10) catch return fail();
        } else if (std.mem.eql(u8, flag, "-p")) {
            prompt = std.fmt.parseInt(usize, value, 10) catch return fail();
        } else if (std.mem.eql(u8, flag, "-m")) {
            marker = std.fmt.parseInt(usize, value, 10) catch return fail();
        } else if (std.mem.eql(u8, flag, "-o")) {
            try offsets.append(arena, std.fmt.parseInt(usize, value, 10) catch return fail());
        } else if (std.mem.eql(u8, flag, "-a")) {
            var it = std.mem.splitScalar(u8, value, ',');
            const row = std.fmt.parseInt(usize, it.next() orelse return fail(), 10) catch return fail();
            const column = std.fmt.parseInt(usize, it.next() orelse return fail(), 10) catch return fail();
            if (it.next() != null) return fail();
            try targets.append(arena, .{ .row = row, .column = column });
        } else {
            return fail();
        }
    }
    const geometry: lineedit.layout.Geometry = .{
        .columns = columns orelse return fail(),
        .prompt = prompt,
        .marker = marker orelse prompt,
    };

    var input_buffer: [4096]u8 = undefined;
    var input = std.Io.File.stdin().reader(init.io, &input_buffer);
    var buffer = try input.interface.allocRemaining(arena, .unlimited);
    if (buffer.len > 0 and buffer[buffer.len - 1] == '\n') buffer = buffer[0 .. buffer.len - 1];

    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &output_buffer);
    const out = &output.interface;
    try lineedit.picture.draw(arena, geometry, buffer, out);
    for (offsets.items) |at| {
        const p = lineedit.layout.position(geometry, buffer, at);
        try out.print("pos {d} {d} {d}\n", .{ at, p.row, p.column });
    }
    for (targets.items) |t| {
        try out.print("off {d} {d} {d}\n", .{ t.row, t.column, lineedit.layout.offset(geometry, buffer, t) });
    }
    try out.flush();
    return 0;
}

// ==========================================================================
// Private functions
// ==========================================================================

/// Prints the usage line to standard error and returns the status for it.
fn fail() u8 {
    std.debug.print(usage, .{});
    return 2;
}
