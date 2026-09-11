//! Behavioral contract for rendering one Janet value as text: `pp.toStringB`,
//! `pp.descriptionB`, their two non-buffer wrappers, and the escape table
//! underneath all four.
//!
//! ## Why this exists rather than leaning on the Janet suites
//!
//! From Janet, both entry points are only ever reached through
//! `string/format` and friends, which hand them a buffer that is either empty
//! or is not the value being printed. Both append rather than replace, both
//! special-case a buffer printed into itself, and neither property is
//! observable through a cfunction that returns a fresh string.
//!
//! The escape width is the other subject. `pp.zig`'s `escapeString` reports
//! how many columns it wrote and the pretty printer's alignment is computed
//! from that, so a width consistently two too small would show up only as
//! slightly wrong wrapping in output no test compares.
//!
//! `escapeString` has no abi beside it, because inside the compilation the
//! width is a return value and the refusal is an error. The abstract type
//! below is an ordinary `AbstractType` for the same reason: its callbacks are
//! Zig functions and this file writes them.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abstract_type = @import("subsystems").abstract_type;
const abstracts = @import("subsystems").value.abstracts;
const buffers = @import("subsystems").value.buffers;
const core_env = @import("subsystems").env;

/// The subject, by import. `toStringB` and `descriptionB` raise, rendering a
/// value running an abstract type's `tostring` callback, so a caller outside
/// the compilation would have to read the report instead of the error.
const describe = subsystems.pp_describe;
const expect = @import("expect.zig").expect;
const functions = @import("subsystems").value.functions;
const gc_alloc = @import("subsystems").gc_alloc;
const harness = @import("harness.zig");
const repr = @import("repr");
const strings = @import("subsystems").value.strings;
const subsystems = @import("subsystems");
const tables = @import("subsystems").value.tables;
const value = @import("subsystems").value;
const vm_lifecycle = @import("subsystems").lifecycle;
const wrap = @import("subsystems").value.wrap;

// ==========================================================================
// Constants
// ==========================================================================

/// A pointer description truncates the type name at 32 bytes, which keeps the
/// whole thing inside the fixed reservation made before writing it. Nothing in
/// Janet has a name that long, so the bound is never approached in practice
/// and would never be noticed if it were wrong.
///
/// It is a container declaration and has to stay one. An abstract stores its
/// type by address and outlives the frame that made it, so a function-local
/// would leave `gc/sweep.zig`'s `clearMemory` dereferencing a dead pointer at
/// teardown, which surfaces as a fault inside `deinitBlock` and nowhere near
/// here.
const long_name = abstract_type.define(anyopaque, .{
    .name = "abstract/with-an-extremely-long-type-name-here",
});

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

fn checkString(s: strings.String, expected: [*:0]const u8) void {
    if (!harness.stringIs(s, expected)) {
        std.debug.print("expected: {s}\n     got: {s}\n", .{ expected, s });
        @panic("string mismatch");
    }
}

fn eval(source: [*:0]const u8) repr.Value {
    var out: repr.Value = wrap.fromNil();
    expect(core_env.dostring(test_env, source, "pp-describe-test", &out) == 0);
    return out;
}

/// Both functions append. Every caller in the tree relies on it, `%v` in the
/// middle of a format string being the common case, and a version that reset
/// the buffer first would pass every Janet suite that formats a whole string
/// at once.
fn bothAppendRatherThanReplace() !void {
    const b: *buffers.Buffer = buffers.new(16);

    _ = buffers.pushCstringAbi(b, "head:");
    try describe.toStringB(b, harness.wrapInteger(7));
    buffers.pushU8(b, '|') catch @panic("pp_describe: buffer push raised");
    try describe.descriptionB(b, value.fromBytes("x", .string));
    checkBuffer(b, "head:7|\"x\"");

    // And again, so that a second append after a first is covered too.
    try describe.toStringB(b, wrap.fromBoolean(true));
    checkBuffer(b, "head:7|\"x\"true");
}

/// A buffer printed into itself. `toStringB` reserves the extra length before
/// pushing and `descriptionB` reserves five times it, because in both cases
/// the source of the bytes is the storage the push may reallocate. Dropping
/// either reservation is a use-after-free that a sanitizer build would catch
/// and an ordinary one would not.
fn aBufferPrintedIntoItself() !void {
    const b: *buffers.Buffer = buffers.new(1);
    _ = buffers.pushCstringAbi(b, "ab");
    try describe.toStringB(b, wrap.fromBuffer(b));
    checkBuffer(b, "abab");

    const d: *buffers.Buffer = buffers.new(1);
    _ = buffers.pushCstringAbi(d, "a\nb");
    try describe.descriptionB(d, wrap.fromBuffer(d));
    // The length is read before the '@' is pushed, so what is escaped is the
    // buffer as it was rather than as it is after the marker. Pushing first
    // would make the marker part of its own escaped content, which is
    // `a\nb@"a\\nb@"`, with a trailing `@` inside the quotes.
    checkBuffer(d, "a\nb@\"a\\nb\"");
}

/// Every escape the table has, in one string, plus the two boundaries of the
/// printable range. A missing case does not corrupt anything; it emits a raw
/// control byte, which reads as valid output until something parses it back.
fn theWholeEscapeTable() !void {
    const raw = [_]u8{
        '"',  '\n', '\r', 0,  0x0C, 0x0B, 0x07, 0x08, 27,
        '\\', '\t', 31,   32, 126,  127,  255,  'z',
    };
    const b: *buffers.Buffer = buffers.new(64);
    const width = try describe.escapeString(b, &raw);

    checkBuffer(b, "\"\\\"\\n\\r\\0\\f\\v\\a\\b\\e\\\\\\t" ++
        "\\x1F \x7E\\x7F\\xFFz\"");

    // The width is the column count, which is the byte count here because
    // nothing written is multi-byte: two quotes, eleven two-byte escapes,
    // three four-byte escapes, and three bytes that escape to themselves.
    expect(width == b.count);
    expect(width == 2 + 11 * 2 + 3 * 4 + 3);
}

/// A description escapes; a stringification does not. This is the whole
/// difference between the two entry points for the byte types, and the pair is
/// asserted together so a change to one cannot look like a change to both.
fn descriptionEscapesWhereToStringDoesNot() !void {
    const s = value.fromBytes("a\"b", .string);
    const b: *buffers.Buffer = buffers.new(16);

    try describe.toStringB(b, s);
    checkBuffer(b, "a\"b");

    b.count = 0;
    try describe.descriptionB(b, s);
    checkBuffer(b, "\"a\\\"b\"");

    // A keyword keeps its colon in a description and loses it in a string.
    b.count = 0;
    try describe.descriptionB(b, value.fromBytes("kw", .keyword));
    checkBuffer(b, ":kw");
    b.count = 0;
    try describe.toStringB(b, value.fromBytes("kw", .keyword));
    checkBuffer(b, "kw");
}

/// Three properties of the number path, none of which the suites pin.
fn theNumbers() !void {
    const b: *buffers.Buffer = buffers.new(32);

    // Negative zero prints without its sign.
    try describe.toStringB(b, wrap.fromNumber(-0.0));
    checkBuffer(b, "0");

    // An integral value inside the exactly-representable range prints with no
    // fraction and no exponent.
    b.count = 0;
    try describe.toStringB(b, wrap.fromNumber(9007199254740992.0));
    checkBuffer(b, "9007199254740992");

    // One past it: the integral shortcut must not take it, because `%.0f`
    // would print all of its digits as if they were significant.
    b.count = 0;
    try describe.toStringB(b, wrap.fromNumber(9007199254740994.0));
    checkBuffer(b, "9.00719925474099e+15");

    b.count = 0;
    try describe.toStringB(b, wrap.fromNumber(1.5));
    checkBuffer(b, "1.5");
}

/// `pp.toString` gives back the contents of a byte type and a rendering of
/// everything else; `pp.description` renders in every case. The three byte
/// types take a path through neither renderer at all, so a change there is
/// invisible to a test that only checks the text. Neither wrapper can raise
/// for any value below, so both are called directly here.
fn theTwoWrappersDifferWhereTheyShould() void {
    const s = value.fromBytes("a\"b", .string);
    const k = value.fromBytes("kw", .keyword);
    const n = harness.wrapInteger(12);

    checkString(describe.toString(s), "a\"b");
    checkString(describe.description(s), "\"a\\\"b\"");
    checkString(describe.toString(k), "kw");
    checkString(describe.description(k), ":kw");
    checkString(describe.toString(n), "12");
    checkString(describe.description(n), "12");

    // A buffer gives back a copy of its contents rather than itself.
    const b: *buffers.Buffer = buffers.new(4);
    _ = buffers.pushCstringAbi(b, "raw");
    checkString(describe.toString(wrap.fromBuffer(b)), "raw");
    checkString(describe.description(wrap.fromBuffer(b)), "@\"raw\"");

    // A symbol is returned as it stands, without a copy: the identity is the
    // point, since symbols are interned.
    const sym = value.fromBytes("sym", .symbol);
    expect(describe.toString(sym) == wrap.toSymbol(sym));
}

/// A registered cfunction prints its registry name, with the prefix when it
/// has one. An unregistered one falls through to the pointer description,
/// which is the same fall-through an anonymous function takes.
fn theCfunctionsAndFunctions() !void {
    const b: *buffers.Buffer = buffers.new(64);

    try describe.descriptionB(b, eval("print"));
    checkBuffer(b, "<cfunction print>");

    b.count = 0;
    try describe.descriptionB(b, eval("string/format"));
    checkBuffer(b, "<cfunction string/format>");

    // A named function names itself; an anonymous one cannot and prints as a
    // pointer. Only the shape of the second is asserted, since the address is
    // not reproducible.
    b.count = 0;
    try describe.descriptionB(b, eval("(fn named [] nil)"));
    checkBuffer(b, "<function named>");

    b.count = 0;
    try describe.descriptionB(b, eval("(fn [] nil)"));
    expect(b.count > 11);
    expect(std.mem.eql(u8, b.slice()[0..12], "<function 0x"));
    expect(b.slice()[@intCast(b.count - 1)] == '>');

    // A function with no definition yet, which the unmarshaller holds while it
    // reads the definition, prints as incomplete. The allocation is not
    // zeroed, so the null is stored here as the unmarshaller stores it.
    b.count = 0;
    const incomplete = gc_alloc.gcallocWithPayload(functions.Function, .function, 0);
    incomplete.def = null;
    try describe.descriptionB(b, wrap.fromFunction(incomplete));
    checkBuffer(b, "<incomplete function>");
}

fn thePointerDescriptionTruncatesItsTitle() !void {
    const p = abstracts.newBytes(&long_name, 8);
    const b: *buffers.Buffer = buffers.new(64);

    try describe.descriptionB(b, wrap.fromAbstract(p));
    expect(b.slice()[0] == '<');
    expect(b.slice()[@intCast(b.count - 1)] == '>');
    // '<' + exactly 32 title bytes + " 0x". The name is 45 bytes long, so the
    // cut lands mid-word, which is what makes the truncation visible.
    expect(std.mem.eql(u8, b.slice()[1..36], "abstract/with-an-extremely-long- 0x"));
}

/// An abstract type with a `tostring` callback is wrapped in angle brackets
/// and its own name by a description, and is *not* wrapped by a
/// stringification. The two spellings are easy to swap and the suites print
/// only one of them.
fn anAbstractWithATostring() !void {
    const val = eval("(int/s64 -5)");
    const b: *buffers.Buffer = buffers.new(32);

    try describe.toStringB(b, val);
    checkBuffer(b, "-5");

    b.count = 0;
    try describe.descriptionB(b, val);
    checkBuffer(b, "<core/s64 -5>");
}

// ==========================================================================
// Entry
// ==========================================================================

fn body() !void {
    try bothAppendRatherThanReplace();
    try aBufferPrintedIntoItself();
    try theWholeEscapeTable();
    try descriptionEscapesWhereToStringDoesNot();
    try theNumbers();
    theTwoWrappersDifferWhereTheyShould();
    try theCfunctionsAndFunctions();
    try thePointerDescriptionTruncatesItsTitle();
    // `int/s64` exists only with the integer types compiled in.
    if (harness.coreOptional("int/s64") != null) try anAbstractWithATostring();
}

pub fn run() void {
    harness.init();
    test_env = harness.coreEnv();
    _ = gc_alloc.gcroot(wrap.fromTable(test_env));

    body() catch @panic("pp_describe: a renderer raised unexpectedly");

    vm_lifecycle.deinit();
}
