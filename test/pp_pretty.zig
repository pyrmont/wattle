//! Behavioral contract for the pretty printer and the WDN writer.
//!
//! ## Why this exists rather than leaning on the Janet suites
//!
//! From Janet these are reached only through `string/format` and
//! `buffer/format`, which always supply a buffer and always take the page
//! width from the format string. Three of the printer's parameters are
//! therefore never varied from Janet at all, the null buffer, the start length
//! and the lookback barrier, and the last two exist precisely so that printing
//! *into text that is already there* behaves differently from printing into an
//! empty buffer.
//!
//! `pretty.wdn` raises and this file `try`s it, so there is no abi to test
//! beside it. A refusal is a value here, and `Raise.says` checks the message
//! at the site that expected it.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const buffers = @import("subsystems").value.buffers;
const config = @import("config");
const constants = @import("constants");
const core_env = @import("subsystems").env;
const expect = @import("expect.zig").expect;
const format = subsystems.pp_format;
const gc_alloc = @import("subsystems").gc_alloc;
const harness = @import("harness.zig");
const pretty = subsystems.pp_pretty;
const repr = @import("repr");
const subsystems = @import("subsystems");
const tables = @import("subsystems").value.tables;
const vm_lifecycle = @import("subsystems").lifecycle;
const wrap = @import("subsystems").value.wrap;

// ==========================================================================
// Constants
// ==========================================================================

const guard = config.recursion_guard;
var test_env: *tables.Table = undefined;

// ==========================================================================
// Cases
// ==========================================================================

fn checkBuffer(b: *buffers.Buffer, expected: []const u8) void {
    const count: usize = @intCast(b.count);
    if (count != expected.len or !std.mem.eql(u8, b.slice()[0..count], expected)) {
        std.debug.print("expected: {s}\n     got: {s}\n", .{ expected, b.slice()[0..count] });
        @panic("buffer mismatch");
    }
}

fn contains(b: *buffers.Buffer, needle: []const u8) bool {
    const count: usize = @intCast(b.count);
    return std.mem.indexOf(u8, b.slice()[0..count], needle) != null;
}

fn endsWith(b: *buffers.Buffer, tail: []const u8) bool {
    const count: usize = @intCast(b.count);
    return std.mem.endsWith(u8, b.slice()[0..count], tail);
}

fn newlines(b: *buffers.Buffer) usize {
    const count: usize = @intCast(b.count);
    return std.mem.count(u8, b.slice()[0..count], "\n");
}

fn eval(source: [*:0]const u8) repr.Value {
    var out: repr.Value = wrap.fromNil();
    expect(core_env.dostring(test_env, source, "pp-pretty-test", &out) == 0);
    gc_alloc.gcroot(out);
    return out;
}

fn buffer(capacity: usize) *buffers.Buffer {
    return buffers.new(capacity);
}

/// Print with an explicit width and flag set.
///
/// There is no entry point that takes them directly: `pretty.prettyBuffer`
/// fixes the width at 80. This goes through the formatter instead, which is
/// how every real caller reaches those parameters anyway, and it means the
/// start length and the lookback barrier are set the way a `%p` in the middle
/// of a format string sets them rather than the way a test would.
///
/// Eight conversion characters cover the eight flag combinations, and the
/// width field is two digits, which bounds the width at 99.
fn prettyWidth(b: *buffers.Buffer, width: u32, flags: c_int, x: repr.Value) !void {
    const conv = [8]u8{ 'p', 'P', 'q', 'Q', 'm', 'M', 'n', 'N' };
    const index: usize =
        @as(usize, if (flags & constants.pretty_color != 0) 1 else 0) |
        @as(usize, if (flags & constants.pretty_oneline != 0) 2 else 0) |
        @as(usize, if (flags & constants.pretty_notrunc != 0) 4 else 0);

    expect(width >= 1 and width <= 99);
    var spec: [8]u8 = undefined;
    const written = std.fmt.bufPrint(&spec, "%{d}{c}", .{ width, conv[index] }) catch unreachable;
    spec[written.len] = 0;

    var argv = [1]repr.Value{x};
    try format.bufferFormat(b, &spec, 0, argv[0..1]);
}

/// Both printers allocate their own buffer when given none. No caller in the
/// tree passes null, every one being a format string with a buffer already in
/// hand, so this branch runs nowhere but here.
fn aNullBufferIsAllocated() !void {
    const b = try pretty.prettyBuffer(null, guard, 80, .{}, eval("[1 2 3]"), 0, 0);
    checkBuffer(b, "[1 2 3]");

    const j = try pretty.wdn(null, guard, eval("[1 2 3]"), 0, 0);
    checkBuffer(j, "[1 2 3]");
}

/// The barrier is what stops the reflow from rewriting text the caller had
/// already put in the buffer. Without it a `%p` in the middle of a format
/// string could delete newlines belonging to the text before it, which is a
/// corruption rather than a formatting difference.
fn theBarrierProtectsEarlierText() !void {
    const b = buffer(64);
    const preamble = "one\n  two\n  three)";
    const val = eval("![![1 2] ![3 4]]");

    _ = buffers.pushCstringAbi(b, preamble);
    try prettyWidth(b, 12, 0, val);

    // Byte for byte, the preamble is untouched, including its newlines and
    // the ')' that would otherwise make the backtracker start here.
    const count: usize = @intCast(b.count);
    expect(count > preamble.len);
    expect(std.mem.eql(u8, b.slice()[0..preamble.len], preamble));

    // And what followed it did wrap, so the case is not vacuous.
    expect(std.mem.indexOfScalar(u8, b.slice()[preamble.len..count], '\n') != null);
}

/// A narrow page wraps and a wide one does not, from the same value. The pair
/// is what makes the width parameter's effect observable at all, and the wide
/// case is the only one in this file where the reflow actually fires: a
/// printer that never backtracked would still pass every other assertion here.
///
/// The value is flat rather than nested on purpose. A nested one does not
/// reflow at its outer level whatever the width, because `leaf_align` is left
/// at the inner level's indentation and the walk stops at the first newline
/// indented less than that.
fn theWidthDecidesTheWrapping() !void {
    const val = eval("![1 2 3 4 5]");
    const narrow = buffer(64);
    const wide = buffer(64);

    try prettyWidth(narrow, 12, 0, val);
    try prettyWidth(wide, 16, 0, val);

    checkBuffer(narrow, "![1\n  2\n  3\n  4\n  5]");
    checkBuffer(wide, "![1 2 3 4 5]");
}

fn oneLineNeverWraps() !void {
    const b = buffer(64);
    try prettyWidth(b, 4, constants.pretty_oneline, eval("![![1 2] ![3 4]]"));
    checkBuffer(b, "![![1 2] ![3 4]]");
}

/// Nesting is the case the reflow does *not* reach, asserted so that a change
/// to the `leaf_align` test shows up as a failure rather than as quietly nicer
/// output.
fn nestingBlocksTheReflow() !void {
    const b = buffer(64);
    try prettyWidth(b, 99, 0, eval("![![1 2] ![3 4]]"));
    checkBuffer(b, "![![1 2]\n  ![3 4]]");
}

/// Colour escapes occupy no columns, and the backtracker steps over them
/// rather than charging the page for them. The same value at the same width
/// must therefore wrap the same way with and without colour, which is the one
/// observable consequence of two comparisons nothing else covers.
fn colourCostsNoColumns() !void {
    const val = eval("![1 2 3 4 5]");
    const plain = buffer(64);
    const colored = buffer(64);

    try prettyWidth(plain, 16, 0, val);
    try prettyWidth(colored, 16, constants.pretty_color, val);

    expect(colored.count > plain.count);
    expect(newlines(plain) == 0);
    expect(newlines(colored) == 0);

    // And one column narrower, where both must wrap the same way.
    const narrow_plain = buffer(64);
    const narrow_colored = buffer(64);
    try prettyWidth(narrow_plain, 12, 0, val);
    try prettyWidth(narrow_colored, 12, constants.pretty_color, val);
    expect(newlines(narrow_plain) == 4);
    expect(newlines(narrow_colored) == 4);
}

/// A cycle marker names the id of the value it points back at, and the id is
/// written by the printer's own integer formatter rather than by `snprintf`.
/// A two-digit id is what makes that formatter's digit loop run more than
/// once; every cycle in the Janet suites is `<cycle 0>`.
fn aTwoDigitCycleId() !void {
    const outer = eval(
        \\(def as (seq [i :range [0 13]] ![]))
        \\(loop [i :range [0 12]] (array/push (as i) (as (+ i 1))))
        \\(array/push (last as) (last as))
        \\(as 0)
    );
    const b = buffer(64);
    try prettyWidth(b, 99, constants.pretty_oneline, outer);
    checkBuffer(b, "![![![![![![![![![![![![![<cycle 12>]]]]]]]]]]]]]");
}

/// A value seen twice without a cycle is printed twice, not marked. The `seen`
/// table is emptied on the way back out of every subtree, and a version that
/// left entries behind would turn a repeated sibling into a cycle marker.
fn aRepeatThatIsNotACycle() !void {
    const pair = eval("(def inner ![1 2]) ![inner inner]");
    const b = buffer(64);
    try prettyWidth(b, 99, constants.pretty_oneline, pair);
    checkBuffer(b, "![![1 2] ![1 2]]");
}

/// An indexed value longer than the limit prints three from each end with an
/// elision between; one exactly at the limit prints whole. The boundary is
/// where an off-by-one lives, and the suites use neither length.
fn theArrayTruncationBoundary() !void {
    const at_limit = buffer(1024);
    const over = buffer(1024);

    try prettyWidth(at_limit, 99, constants.pretty_oneline, eval("(seq [i :range [0 160]] i)"));
    try prettyWidth(over, 99, constants.pretty_oneline, eval("(seq [i :range [0 161]] i)"));

    // 160 elements, whole: no elision anywhere, and the last element is the
    // last one rather than the last one printed before an elision.
    expect(!contains(at_limit, "..."));
    expect(endsWith(at_limit, " 157 158 159]"));

    // 161 elements: three, an elision, three.
    checkBuffer(over, "![0 1 2 ... 158 159 160]");
}

/// The same boundary for a dictionary, where the limit is 30 rather than 160
/// and the elision goes at the end rather than in the middle.
fn theDictionaryTruncationBoundary() !void {
    const at_limit = buffer(1024);
    const over = buffer(1024);

    try prettyWidth(at_limit, 99, constants.pretty_oneline, eval("(tabseq [i :range [0 30]] i i)"));
    try prettyWidth(over, 99, constants.pretty_oneline, eval("(tabseq [i :range [0 31]] i i)"));

    expect(!contains(at_limit, "..."));
    expect(endsWith(over, " ...}"));

    // Truncation is off under NOTRUNC, for both shapes.
    const whole = buffer(4096);
    try prettyWidth(
        whole,
        99,
        constants.pretty_oneline | constants.pretty_notrunc,
        eval("(tabseq [i :range [0 31]] i i)"),
    );
    expect(!contains(whole, "..."));
}

/// Keys are sorted, so a table prints the same way twice however it was built.
/// Above the key-sort limit the sort is abandoned and storage order is used
/// instead, which is still deterministic for one table, so what the boundary
/// changes is whether *two* tables with the same contents print alike.
fn keysAreSortedBelowTheLimit() !void {
    const forward = buffer(1024);
    const backward = buffer(1024);
    const flags = constants.pretty_oneline | constants.pretty_notrunc;

    try prettyWidth(forward, 99, flags, eval("(tabseq [i :range [0 40]] i i)"));
    try prettyWidth(backward, 99, flags, eval(
        "(let [t !{}] (var i 39) (while (>= i 0) (put t i i) (-- i)) t)",
    ));

    expect(forward.count == backward.count);
    const count: usize = @intCast(forward.count);
    expect(std.mem.eql(u8, forward.slice()[0..count], backward.slice()[0..count]));
    // Sorted, so the first entry is the smallest key.
    expect(std.mem.eql(u8, forward.slice()[0..6], "!{0 0 "));
}

/// Every level of a nested dictionary sorts its own keys, taking its slice of
/// one scratch allocation above the level below it. A map's pairs are gathered
/// into a block of their own first, one per level, and each is released as its
/// level returns.
fn nestedDictionariesShareTheKeySortScratch() !void {
    const b = buffer(4096);
    try prettyWidth(b, 99, constants.pretty_oneline, eval(
        "{:a {:x 1 :y 2 :z 3} :b {:x 4 :y 5 :z 6} :c {:x 7 :y 8 :z 9}}",
    ));
    checkBuffer(b, "{:a {:x 1 :y 2 :z 3} :b {:x 4 :y 5 :z 6} :c {:x 7 :y 8 :z 9}}");

    const t = buffer(4096);
    try prettyWidth(t, 99, constants.pretty_oneline, eval(
        "!{:a !{:x 1 :y 2 :z 3} :b !{:x 4 :y 5 :z 6} :c !{:x 7 :y 8 :z 9}}",
    ));
    checkBuffer(t, "!{:a !{:x 1 :y 2 :z 3} :b !{:x 4 :y 5 :z 6} :c !{:x 7 :y 8 :z 9}}");
}

fn theDepthLimit() !void {
    const b = buffer(64);
    var argv = [1]repr.Value{eval("[1 [2 [3 [4]]]]")};
    try format.bufferFormat(b, "%.2q", 0, argv[0..1]);
    checkBuffer(b, "[1 [...]]");
}

fn whatJdnRefuses() !void {
    // One key, because WDN walks a dictionary in storage order rather than
    // sorted order and two would pin the hash layout rather than the writer.
    const b = buffer(64);
    _ = try pretty.wdn(b, guard, eval("{:a [1 ![2 \"x\"] 1.5]}"), 0, 0);
    checkBuffer(b, "{:a [1 ![2 \"x\"] 1.5]}");

    for ([_][*:0]const u8{
        "print", // a cfunction has no WDN form
        "(keyword \"a b\")", // nor a keyword whose text would not lex
        "math/inf", // nor infinity
    }) |source| {
        const val = eval(source);
        const r = harness.raised(pretty.wdn, .{ buffer(16), guard, val, @as(i32, 0), @as(i32, 0) }).?;
        expect(r.signal == abi.Signal.@"error");
        expect(r.says("could not print to wdn format"));
    }
}

fn wdnTreatsSymbolsAndKeywordsDifferently() !void {
    const b = buffer(64);
    _ = try pretty.wdn(b, guard, eval("(keyword \"1abc\")"), 0, 0);
    checkBuffer(b, ":1abc");

    const symbol = eval("(symbol \"1abc\")");
    expect(harness.raised(
        pretty.wdn,
        .{ buffer(16), guard, symbol, @as(i32, 0), @as(i32, 0) },
    ) != null);
}

// ==========================================================================
// Entry
// ==========================================================================

fn body() !void {
    try aNullBufferIsAllocated();
    try theBarrierProtectsEarlierText();
    try theWidthDecidesTheWrapping();
    try oneLineNeverWraps();
    try nestingBlocksTheReflow();
    try colourCostsNoColumns();
    try aTwoDigitCycleId();
    try aRepeatThatIsNotACycle();
    try theArrayTruncationBoundary();
    try theDictionaryTruncationBoundary();
    try keysAreSortedBelowTheLimit();
    try nestedDictionariesShareTheKeySortScratch();
    try theDepthLimit();
    try whatJdnRefuses();
    try wdnTreatsSymbolsAndKeywordsDifferently();
}

pub fn run() void {
    harness.init();
    test_env = harness.coreEnv();
    gc_alloc.gcroot(wrap.fromTable(test_env));

    body() catch @panic("pp_pretty: a printer raised unexpectedly");

    vm_lifecycle.deinit();
}
