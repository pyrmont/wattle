//! The contract between the line editor's classifier and the parser.
//!
//! `lineedit/highlight.zig` is a second description of the lexical syntax,
//! and `runtime/parser.zig` is the first. This contract compares the two. It
//! reads the tree's `.wattle` files from the working directory, which is the
//! repository's root when `build.zig` or a developer runs the driver.
//!
//! ## The rule
//!
//! Where the classifier classes a byte as an error, a fresh parser given the
//! buffer has reported an error by the end of the line with the first such
//! byte. The parser is given no newline after the buffer, so what the end of
//! the buffer cuts short, which the parser has not refused, cannot be classed
//! as an error. The rule is checked over every `.wattle` file in the tree, a
//! list of literals that are easy to misread, and random byte strings.
//!
//! The rule holds in one direction only: the parser also refuses a map with
//! an odd number of forms, and the classifier does not check the count. The
//! other direction is checked case by case, over one source for each lexical
//! refusal the classifier copies.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const expect = @import("expect.zig").expect;
const harness = @import("harness.zig");
const highlight = @import("lineedit").highlight;
const parser_core = @import("subsystems").parser;
const scan = @import("subsystems").scan;
const specials = @import("subsystems").specials_core;
const vm_lifecycle = @import("subsystems").lifecycle;

// ==========================================================================
// Constants
// ==========================================================================

/// The most bytes of a buffer a case classifies.
const buffer_limit = 1 << 22;

/// The fewest `.wattle` files the walk has to find, so a run from a directory
/// other than the repository's root fails rather than checking nothing.
const least_files = 50;

/// The number of random byte strings.
const random_count = 2000;

/// The longest random byte string.
const random_length = 24;

/// The bytes a random byte string is drawn from.
const random_alphabet = "()[]{}\"\\;#!'`~|@^,: \n\t\raxuUnF019.-+" ++ "\x01\xc3\xa9\xff";

/// The seed of the random byte strings.
const random_seed = 0x5741_5454;

// ==========================================================================
// Cases
// ==========================================================================

/// The special forms' names, as `prompt.zig` tests them.
fn special(token: []const u8) bool {
    for (specials.allSpecials()) |form| {
        if (std.mem.eql(u8, std.mem.span(form.name), token)) return true;
    }
    return false;
}

const lexicon: highlight.Lexicon = .{
    .symbol = &scan.isSymbolChar,
    .number = &scan.isNumber,
    .special = &special,
};

var classes: [buffer_limit]highlight.Class = undefined;

/// Returns the offset of the first byte of `text` the classifier classes as
/// an error, or null for none.
fn firstError(text: []const u8) ?usize {
    const found = classes[0..text.len];
    highlight.classify(text, found, lexicon);
    return std.mem.indexOfScalar(highlight.Class, found, .@"error");
}

/// Returns whether a fresh parser, given `text` up to `end`, has reported an
/// error, and given a newline after it as well when `newline`.
fn parserRefuses(text: []const u8, end: usize, newline: bool) !bool {
    var p: parser_core.Parser = undefined;
    parser_core.parserInit(&p);
    defer parser_core.parserDeinit(&p);
    for (text[0..end]) |byte| try parser_core.parserConsume(&p, byte);
    if (newline) try parser_core.parserConsume(&p, '\n');
    return p.@"error" != null;
}

/// Checks the rule for `text`, and returns whether any byte was classed as
/// an error.
///
/// The line with the first error ends at the first newline or carriage
/// return after it.
fn ruleHolds(text: []const u8) !bool {
    const first = firstError(text) orelse return false;
    var end = first;
    while (end < text.len and text[end] != '\n' and text[end] != '\r') end += 1;
    if (end < text.len) end += 1;
    if (!try parserRefuses(text, end, false)) {
        std.debug.print("highlight: an error at offset {d} the parser does not refuse: {f}\n", .{ first, std.ascii.hexEscape(text, .lower) });
        expect(false);
    }
    return true;
}

/// Every `.wattle` file under the working directory, outside the directories
/// that are not the tree's, is accepted by the parser, so no byte of any of
/// them is classed as an error.
fn theTreeHasNoError() !void {
    var threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const allocator = std.heap.c_allocator;
    var root = try std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
    defer root.close(io);
    var walker = try root.walkSelectively(allocator);
    defer walker.deinit();
    var files: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) {
            const skipped = entry.basename[0] == '.' or
                std.mem.eql(u8, entry.basename, "zig-out") or
                std.mem.eql(u8, entry.basename, "claret") or
                std.mem.eql(u8, entry.basename, "janet");
            if (!skipped) try walker.enter(io, entry);
            continue;
        }
        if (!std.mem.endsWith(u8, entry.basename, ".wattle")) continue;
        const text = try entry.dir.readFileAlloc(io, entry.basename, allocator, .limited(buffer_limit));
        defer allocator.free(text);
        if (firstError(text)) |at| {
            std.debug.print("highlight: {s} has an error at offset {d}\n", .{ entry.path, at });
            expect(false);
        }
        files += 1;
    }
    expect(files >= least_files);
}

/// Sources the parser accepts that a copy of its rules could misread.
const accepted = [_][]const u8{
    "assoc! foo@bar a^b",
    "!",
    "!\n",
    "(! x)",
    "\"\" \"a\"",
    "\"\"\"a\"\"\"",
    "\"\"\"\" a \"\"\" \"\"\"\"",
    "\"\"\"a\nb\"\"\"",
    "\"\\u00e9 \\U10FFFF \\x41 \\e \\0 \\z \\?\"",
    "-foo ... + - .5 -1.5 0x1F 1e5 1_000 16rFF",
    ": ::a :é",
    "#{1 2} #(+ $ 1)",
    "![1] !(1) !{:a 1} !\"buf\" !\"\"\"raw\"\"\"",
    "'x `(a ~b |c) ' x",
    ",a, nil true false é",
    "(a ; c\n b)",
    "\"a\\\\\"",
    "a\tb",
    "#!/usr/bin/env wattle\n(print 1)",
    "(def f (fn [x] (if x (do 1) (quote y))))",
};

/// No byte of a source the parser accepts is classed as an error.
fn theAcceptedLiteralsHaveNoError() !void {
    for (accepted) |text| {
        expect(!try parserRefuses(text, text.len, true));
        expect(firstError(text) == null);
    }
}

/// The rule holds for random byte strings, and at least a quarter of them
/// have a byte classed as an error, so the check is not met by classing
/// nothing.
fn theRuleHoldsForRandomBytes() !void {
    var prng: std.Random.DefaultPrng = .init(random_seed);
    const random = prng.random();
    var text: [random_length]u8 = undefined;
    var flagged: usize = 0;
    for (0..random_count) |_| {
        const len = random.intRangeAtMost(usize, 1, random_length);
        for (text[0..len]) |*byte| byte.* = random_alphabet[random.uintLessThan(usize, random_alphabet.len)];
        if (try ruleHolds(text[0..len])) flagged += 1;
    }
    expect(flagged * 4 >= random_count);
}

/// One source for each lexical refusal the classifier copies.
const refused = [_][]const u8{
    "@a",
    "^a",
    "a \\ b",
    "\x01",
    "#foo",
    "#[1]",
    "# ",
    "\"\\q\"",
    "\"\\x4G\"",
    "\"\\u12G4\"",
    "\"\\U110000\"",
    "\"ab\ncd\"",
    "1x ",
    "a\xff ",
    ":\xff ",
    ")",
    "(]",
    "[}",
    "#{1)",
    "'\n",
    "'; c\n",
    "'; comment\r\n",
    "'; a\rb\n",
    "(')",
};

/// The parser refuses each of `refused`, the classifier classes a byte of each
/// as an error, and the rule holds.
fn eachRefusalIsClassed() !void {
    for (refused) |text| {
        expect(try parserRefuses(text, text.len, true));
        expect(try ruleHolds(text));
    }
}

// ==========================================================================
// Entry
// ==========================================================================

fn body() !void {
    try theTreeHasNoError();
    try theAcceptedLiteralsHaveNoError();
    try theRuleHoldsForRandomBytes();
    try eachRefusalIsClassed();
}

pub fn run() void {
    harness.init();
    body() catch @panic("highlight: a case failed with an error");
    vm_lifecycle.deinit();
}
