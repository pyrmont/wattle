//! Completion at Tab: the token before the cursor, the candidates for it, and
//! the cycle through them.
//!
//! `session.zig` gathers the candidates with the `Gather` function it is
//! given, and owns a `Cycle` while a completion is in progress. This file
//! does not edit the buffer; the session does.
//!
//! ## The token
//!
//! The _token_ is the run of symbol bytes that ends at an offset, where a
//! `Symbol` function reports which bytes are symbol bytes. `tokenEnd` finds
//! where the run the cursor is in ends, so Tab inside a token completes the
//! whole of it.
//!
//! ## The cycle
//!
//! With more than one candidate, each call to `Cycle.advance` returns the
//! next candidate, and the call after the last returns the token as it was
//! typed, with no candidate selected. The call after that returns the first
//! again. `Cycle.retreat` goes through the same cycle in reverse, so from the
//! token as typed it returns the last candidate.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Aliased types
// ==========================================================================

/// Adds to `candidates` each name that begins with `token`.
///
/// `session.Source` has a `Gather`. The candidates may be added in any
/// order and more than once. This function returns `error.OutOfMemory` when
/// `candidates` cannot grow.
pub const Gather = *const fn (token: []const u8, candidates: *Candidates) error{OutOfMemory}!void;

/// Returns whether `byte` may be part of a token.
///
/// `session.Source` has a `Symbol`, and `tokenStart` and `tokenEnd` take
/// one.
pub const Symbol = *const fn (byte: u8) bool;

// ==========================================================================
// Types
// ==========================================================================

/// The names a `Gather` function adds.
///
/// `init` returns a `Candidates` and `deinit` releases it. `add` copies a
/// name in and `settle` sorts the names and removes duplicates. `names` are
/// the copies.
pub const Candidates = struct {
    allocator: std.mem.Allocator,
    names: std.ArrayList([]u8) = .empty,

    /// Returns an empty `Candidates` whose copies `allocator` holds.
    pub fn init(allocator: std.mem.Allocator) Candidates {
        return .{ .allocator = allocator };
    }

    /// Releases every copy.
    pub fn deinit(candidates: *Candidates) void {
        for (candidates.names.items) |name| candidates.allocator.free(name);
        candidates.names.deinit(candidates.allocator);
    }

    /// Adds a copy of `name`.
    ///
    /// This function returns `error.OutOfMemory` when the copy or the list
    /// cannot be allocated, and nothing is then added.
    pub fn add(candidates: *Candidates, name: []const u8) error{OutOfMemory}!void {
        try candidates.names.ensureUnusedCapacity(candidates.allocator, 1);
        candidates.names.appendAssumeCapacity(try candidates.allocator.dupe(u8, name));
    }

    /// Sorts the names by their bytes and removes duplicates.
    pub fn settle(candidates: *Candidates) void {
        const names = candidates.names.items;
        std.mem.sort([]u8, names, {}, lessThan);
        var kept: usize = 0;
        for (names) |name| {
            if (kept > 0 and std.mem.eql(u8, names[kept - 1], name)) {
                candidates.allocator.free(name);
                continue;
            }
            names[kept] = name;
            kept += 1;
        }
        candidates.names.shrinkRetainingCapacity(kept);
    }
};

/// A completion in progress: the candidates, the token as it was typed, and
/// where the buffer has the text that replaced it.
///
/// `init` returns a `Cycle` and `deinit` releases it. `start` is the offset
/// of the token in the buffer and `length` is the length of the text there
/// now. `selected` is the index of the candidate in the buffer, or null when
/// the buffer has the token as typed.
pub const Cycle = struct {
    candidates: Candidates,
    typed: []u8,
    start: usize,
    length: usize,
    selected: ?usize = null,

    /// Returns a cycle through `candidates` for `token`, at offset `start`,
    /// with no candidate selected.
    ///
    /// The cycle owns `candidates` from this call. This function returns
    /// `error.OutOfMemory` when the copy of `token` cannot be allocated, and
    /// the caller then still owns `candidates`.
    pub fn init(candidates: Candidates, token: []const u8, start: usize) error{OutOfMemory}!Cycle {
        return .{
            .candidates = candidates,
            .typed = try candidates.allocator.dupe(u8, token),
            .start = start,
            .length = token.len,
        };
    }

    /// Releases the candidates and the copy of the token.
    pub fn deinit(cycle: *Cycle) void {
        cycle.candidates.allocator.free(cycle.typed);
        cycle.candidates.deinit();
    }

    /// Selects the next candidate, and returns the text the buffer is to
    /// have in place of the token.
    ///
    /// After the last candidate the result is the token as typed and nothing
    /// is selected. The result is valid while the cycle is.
    pub fn advance(cycle: *Cycle) []const u8 {
        const names = cycle.candidates.names.items;
        const next: ?usize = if (cycle.selected) |i| (if (i + 1 < names.len) i + 1 else null) else 0;
        cycle.selected = next;
        return if (next) |i| names[i] else cycle.typed;
    }

    /// Selects the previous candidate, and returns the text the buffer is to
    /// have in place of the token.
    ///
    /// Before the first candidate the result is the token as typed and
    /// nothing is selected, and before that the result is the last
    /// candidate. The result is valid while the cycle is.
    pub fn retreat(cycle: *Cycle) []const u8 {
        const names = cycle.candidates.names.items;
        const previous: ?usize = if (cycle.selected) |i| (if (i > 0) i - 1 else null) else names.len - 1;
        cycle.selected = previous;
        return if (previous) |i| names[i] else cycle.typed;
    }
};

// ==========================================================================
// Public functions
// ==========================================================================

/// Returns the offset after the run of symbol bytes at `at` in `text`.
///
/// `symbol` reports which bytes are symbol bytes. The result is `at` when
/// the byte at `at` is not one.
pub fn tokenEnd(text: []const u8, at: usize, symbol: Symbol) usize {
    var end = at;
    while (end < text.len and symbol(text[end])) end += 1;
    return end;
}

/// Returns the offset of the start of the run of symbol bytes that ends at
/// `at` in `text`.
///
/// `symbol` reports which bytes are symbol bytes. The result is `at` when
/// the byte before `at` is not one.
pub fn tokenStart(text: []const u8, at: usize, symbol: Symbol) usize {
    var start = at;
    while (start > 0 and symbol(text[start - 1])) start -= 1;
    return start;
}

// ==========================================================================
// Private functions
// ==========================================================================

/// Whether `a` sorts before `b` by their bytes.
fn lessThan(_: void, a: []u8, b: []u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

// ==========================================================================
// Tests
// ==========================================================================

/// Whether `byte` is a letter, a digit, `-` or `/`.
fn testSymbol(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '/';
}

test "settle: sorts and removes duplicates" {
    var candidates = Candidates.init(std.testing.allocator);
    defer candidates.deinit();
    for ([_][]const u8{ "map", "mapcat", "map", "make", "mapcat" }) |name| try candidates.add(name);
    candidates.settle();
    try std.testing.expectEqual(3, candidates.names.items.len);
    try std.testing.expectEqualStrings("make", candidates.names.items[0]);
    try std.testing.expectEqualStrings("map", candidates.names.items[1]);
    try std.testing.expectEqualStrings("mapcat", candidates.names.items[2]);
}

test "advance: each candidate in turn, then the token as typed, then the first" {
    var candidates = Candidates.init(std.testing.allocator);
    for ([_][]const u8{ "mab", "maa" }) |name| try candidates.add(name);
    candidates.settle();
    var cycle = try Cycle.init(candidates, "ma", 4);
    defer cycle.deinit();
    try std.testing.expectEqualStrings("maa", cycle.advance());
    try std.testing.expectEqual(0, cycle.selected.?);
    try std.testing.expectEqualStrings("mab", cycle.advance());
    try std.testing.expectEqualStrings("ma", cycle.advance());
    try std.testing.expectEqual(null, cycle.selected);
    try std.testing.expectEqualStrings("maa", cycle.advance());
}

test "retreat: the last candidate, each before it in turn, then the token as typed" {
    var candidates = Candidates.init(std.testing.allocator);
    for ([_][]const u8{ "mab", "maa" }) |name| try candidates.add(name);
    candidates.settle();
    var cycle = try Cycle.init(candidates, "ma", 4);
    defer cycle.deinit();
    try std.testing.expectEqualStrings("mab", cycle.retreat());
    try std.testing.expectEqual(1, cycle.selected.?);
    try std.testing.expectEqualStrings("maa", cycle.retreat());
    try std.testing.expectEqualStrings("ma", cycle.retreat());
    try std.testing.expectEqual(null, cycle.selected);
    try std.testing.expectEqualStrings("mab", cycle.retreat());
    try std.testing.expectEqualStrings("ma", cycle.advance());
}

test "tokenStart and tokenEnd: the run of symbol bytes around an offset" {
    const text = "(string/fi \"a\")";
    try std.testing.expectEqual(1, tokenStart(text, 5, testSymbol));
    try std.testing.expectEqual(10, tokenEnd(text, 5, testSymbol));
    try std.testing.expectEqual(11, tokenStart(text, 11, testSymbol));
    try std.testing.expectEqual(0, tokenStart(text, 0, testSymbol));
}
