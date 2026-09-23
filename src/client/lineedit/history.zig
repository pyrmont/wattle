//! The lines submitted at the REPL, the browsing of them while a line is
//! open, and the format they are stored in.
//!
//! `src/client/prompt.zig` owns a `History`, reads and appends the file, and
//! gives the history to `session.Session.begin` for a line that reads
//! source. This file does no I/O.
//!
//! ## Entries
//!
//! An _entry_ is one submitted buffer, whatever rows it occupies. `add`
//! records a buffer unless it is empty or equal to the newest entry, and at
//! `limit` entries it drops the oldest first.
//!
//! ## Browsing
//!
//! While a line is open, `step` moves between the entries and the line being
//! typed, which is after the newest entry. The buffer that `step` leaves is
//! kept, so the line being typed comes back when `step` returns to it, and an
//! edit to a recalled entry lasts while the line is open. `reset` discards
//! the kept buffers, so an edit to a recalled entry never changes the entry.
//!
//! ## The file format
//!
//! One entry is one line of the file. A backslash is written as `\\`, a
//! newline as `\n` and a carriage return as `\r`, and every other byte is
//! written as it is. On reading, an escape other than those three is kept
//! with its backslash, and a carriage return that ends a line is removed, so
//! a file with CRLF line ends reads the same.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Constants
// ==========================================================================

/// The most entries a `History` keeps by default.
pub const default_limit = 1000;

// ==========================================================================
// Types
// ==========================================================================

/// The entries, oldest first, and the browsing of them for the open line.
///
/// `init` returns a `History` and `deinit` releases it. `limit` is the most
/// entries kept. `at` is the entry the open line shows, where `entries.len`
/// is the line being typed, and `kept` is the buffer left at each position
/// `step` has moved from since the last `reset`.
pub const History = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList([]u8) = .empty,
    limit: usize = default_limit,
    at: usize = 0,
    kept: std.AutoHashMapUnmanaged(usize, []u8) = .empty,

    /// Returns an empty history whose entries `allocator` holds.
    pub fn init(allocator: std.mem.Allocator) History {
        return .{ .allocator = allocator };
    }

    /// Releases every entry and every kept buffer.
    pub fn deinit(history: *History) void {
        history.forget();
        history.kept.deinit(history.allocator);
        for (history.entries.items) |entry| history.allocator.free(entry);
        history.entries.deinit(history.allocator);
    }

    /// Records `text` as the newest entry, and returns whether it was
    /// recorded.
    ///
    /// `text` is not recorded when it is empty or equal to the newest entry.
    /// At `limit` entries the oldest is dropped. `reset` is called first.
    /// This function returns `error.OutOfMemory` when the entry cannot be
    /// copied, and the history is then unchanged apart from the reset.
    pub fn add(history: *History, text: []const u8) error{OutOfMemory}!bool {
        history.reset();
        _ = try history.push(text) orelse return false;
        history.at = history.entries.items.len;
        return true;
    }

    /// Ends the browsing: discards the kept buffers and puts `at` at the line
    /// being typed.
    pub fn reset(history: *History) void {
        history.forget();
        history.at = history.entries.items.len;
    }

    /// Moves to the older entry, when `older`, or the newer, and returns the
    /// text to show there.
    ///
    /// `current` is the buffer at the position being left, and is kept for a
    /// return to that position. The result is the buffer kept at the new
    /// position, or the entry there, and is valid until the next call on
    /// `history`. The result is null, and nothing is kept, at the oldest entry
    /// for `older` and at the line being typed otherwise. This function
    /// returns `error.OutOfMemory` when `current` cannot be copied, and the
    /// position is then unchanged.
    pub fn step(history: *History, current: []const u8, older: bool) error{OutOfMemory}!?[]const u8 {
        const count = history.entries.items.len;
        if (older and history.at == 0) return null;
        if (!older and history.at >= count) return null;
        const copy = try history.allocator.dupe(u8, current);
        errdefer history.allocator.free(copy);
        const slot = try history.kept.getOrPut(history.allocator, history.at);
        if (slot.found_existing) history.allocator.free(slot.value_ptr.*);
        slot.value_ptr.* = copy;
        history.at = if (older) history.at - 1 else history.at + 1;
        if (history.kept.get(history.at)) |kept| return kept;
        if (history.at == count) return "";
        return history.entries.items[history.at];
    }

    /// Reads the entries of a history file's `contents`, as `add` records
    /// them, and returns whether the limit dropped an entry.
    ///
    /// A caller that gets true can write the file again with `write` to
    /// shorten it. This function returns `error.OutOfMemory` when an entry
    /// cannot be copied, with the entries read before it recorded.
    pub fn load(history: *History, contents: []const u8) error{OutOfMemory}!bool {
        history.reset();
        defer history.at = history.entries.items.len;
        var scratch: std.ArrayList(u8) = .empty;
        defer scratch.deinit(history.allocator);
        var dropped = false;
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |raw| {
            const line = if (std.mem.endsWith(u8, raw, "\r")) raw[0 .. raw.len - 1] else raw;
            scratch.clearRetainingCapacity();
            try scratch.appendSlice(history.allocator, line);
            const entry = unescape(scratch.items);
            if (try history.push(entry)) |drop| dropped = dropped or drop;
        }
        return dropped;
    }

    /// Writes every entry to `out` in the file format, one to a line.
    ///
    /// This function returns `error.WriteFailed` when `out` fails.
    pub fn write(history: *const History, out: *std.Io.Writer) std.Io.Writer.Error!void {
        for (history.entries.items) |entry| {
            try escape(out, entry);
            try out.writeByte('\n');
        }
    }

    /// Appends a copy of `text` as the newest entry, dropping the oldest at
    /// the limit, and returns whether an entry was dropped.
    ///
    /// The result is null when `text` is empty or equal to the newest entry,
    /// which are not recorded, and when `limit` is 0.
    fn push(history: *History, text: []const u8) error{OutOfMemory}!?bool {
        if (text.len == 0) return null;
        const items = history.entries.items;
        if (items.len > 0 and std.mem.eql(u8, items[items.len - 1], text)) return null;
        if (history.limit == 0) return null;
        const copy = try history.allocator.dupe(u8, text);
        errdefer history.allocator.free(copy);
        try history.entries.ensureUnusedCapacity(history.allocator, 1);
        const drop = items.len >= history.limit;
        if (drop) history.allocator.free(history.entries.orderedRemove(0));
        history.entries.appendAssumeCapacity(copy);
        return drop;
    }

    /// Frees the kept buffers and empties the map of them.
    fn forget(history: *History) void {
        var kept = history.kept.valueIterator();
        while (kept.next()) |buffer| history.allocator.free(buffer.*);
        history.kept.clearRetainingCapacity();
    }
};

// ==========================================================================
// Public functions
// ==========================================================================

/// Writes `text` to `out` in the file format, without a line end.
///
/// This function returns `error.WriteFailed` when `out` fails.
pub fn escape(out: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    for (text) |byte| switch (byte) {
        '\\' => try out.writeAll("\\\\"),
        '\n' => try out.writeAll("\\n"),
        '\r' => try out.writeAll("\\r"),
        else => try out.writeByte(byte),
    };
}

/// Restores the three escapes of the file format in `line`, in place, and
/// returns the part of `line` that holds the result.
///
/// An escape other than the three, and a backslash that ends `line`, are
/// kept as they are. The result is never longer than `line`.
pub fn unescape(line: []u8) []u8 {
    var from: usize = 0;
    var to: usize = 0;
    while (from < line.len) : (to += 1) {
        const byte = line[from];
        from += 1;
        if (byte == '\\' and from < line.len) {
            const restored: ?u8 = switch (line[from]) {
                '\\' => '\\',
                'n' => '\n',
                'r' => '\r',
                else => null,
            };
            if (restored) |r| {
                line[to] = r;
                from += 1;
                continue;
            }
        }
        line[to] = byte;
    }
    return line[0..to];
}

// ==========================================================================
// Tests
// ==========================================================================

/// Returns `text` in the file format, in memory the caller frees.
fn escaped(text: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer out.deinit();
    try escape(&out.writer, text);
    return out.toOwnedSlice();
}

test "escape: the three bytes are escaped and nothing else" {
    const cases = [_][2][]const u8{
        .{ "(print \"a\")", "(print \"a\")" },
        .{ "(+ 1\n2)", "(+ 1\\n2)" },
        .{ "a\\b", "a\\\\b" },
        .{ "a\rb", "a\\rb" },
        .{ "\"\\n\"", "\"\\\\n\"" },
        .{ "\t\x1b度", "\t\x1b度" },
    };
    for (cases) |case| {
        const out = try escaped(case[0]);
        defer std.testing.allocator.free(out);
        try std.testing.expectEqualStrings(case[1], out);
    }
}

test "unescape: every escaped text round-trips" {
    const corpus = [_][]const u8{
        "",               "(print \"a\")", "(+ 1\n2)", "\\",          "\\\\n",
        "a\\nb\n\\\r\\r", "\n\n",          "\r",       "end with \\",
    };
    for (corpus) |text| {
        const out = try escaped(text);
        defer std.testing.allocator.free(out);
        try std.testing.expect(std.mem.indexOfScalar(u8, out, '\n') == null);
        try std.testing.expectEqualStrings(text, unescape(out));
    }
}

test "unescape: an unknown escape and a final backslash are kept" {
    var line = "a\\tb\\".*;
    try std.testing.expectEqualStrings("a\\tb\\", unescape(&line));
}

test "add: empty text and the newest entry again are not recorded" {
    var history = History.init(std.testing.allocator);
    defer history.deinit();
    try std.testing.expect(!try history.add(""));
    try std.testing.expect(try history.add("a"));
    try std.testing.expect(!try history.add("a"));
    try std.testing.expect(try history.add("b"));
    try std.testing.expect(try history.add("a"));
    try std.testing.expectEqual(3, history.entries.items.len);
}

test "add: the oldest entry is dropped at the limit" {
    var history = History.init(std.testing.allocator);
    defer history.deinit();
    history.limit = 2;
    _ = try history.add("a");
    _ = try history.add("b");
    _ = try history.add("c");
    try std.testing.expectEqual(2, history.entries.items.len);
    try std.testing.expectEqualStrings("b", history.entries.items[0]);
    try std.testing.expectEqualStrings("c", history.entries.items[1]);
}

test "step: moves through the entries and back to the line being typed" {
    var history = History.init(std.testing.allocator);
    defer history.deinit();
    _ = try history.add("a");
    _ = try history.add("b");
    try std.testing.expectEqualStrings("b", (try history.step("typed", true)).?);
    try std.testing.expectEqualStrings("a", (try history.step("b", true)).?);
    try std.testing.expectEqual(null, try history.step("a", true));
    try std.testing.expectEqualStrings("b", (try history.step("a", false)).?);
    try std.testing.expectEqualStrings("typed", (try history.step("b", false)).?);
    try std.testing.expectEqual(null, try history.step("typed", false));
}

test "step: an edit to a recalled entry lasts until the reset" {
    var history = History.init(std.testing.allocator);
    defer history.deinit();
    _ = try history.add("a");
    _ = try history.add("b");
    _ = try history.step("", true);
    _ = try history.step("b edited", true);
    try std.testing.expectEqualStrings("b edited", (try history.step("a", false)).?);
    history.reset();
    try std.testing.expectEqualStrings("b", (try history.step("", true)).?);
    try std.testing.expectEqualStrings("b", history.entries.items[1]);
}

test "load: reads escaped entries and CRLF line ends" {
    var history = History.init(std.testing.allocator);
    defer history.deinit();
    try std.testing.expect(!try history.load("(+ 1\\n2)\r\n\n(print \"a\")\na\\\\n\n"));
    try std.testing.expectEqual(3, history.entries.items.len);
    try std.testing.expectEqualStrings("(+ 1\n2)", history.entries.items[0]);
    try std.testing.expectEqualStrings("(print \"a\")", history.entries.items[1]);
    try std.testing.expectEqualStrings("a\\n", history.entries.items[2]);
    try std.testing.expectEqual(3, history.at);
}

test "load: reports an entry the limit dropped, and write gives the rest" {
    var history = History.init(std.testing.allocator);
    defer history.deinit();
    history.limit = 2;
    try std.testing.expect(try history.load("a\nb\\nc\nd\n"));
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try history.write(&out.writer);
    try std.testing.expectEqualStrings("b\\nc\nd\n", out.written());
}
