//! Behavioral contract for rendering one Janet value as text: `pp.toStringB`,
//! `pp.descriptionB`, their two non-buffer wrappers, and the escape table
//! underneath all four.
//!
//! ## Why this exists rather than leaning on the Janet suites
//!
//! From Janet, both entry points are only ever reached through
//! `string/format` and friends, which hand them a buffer that is either empty
//! or is not the value being printed. Both are documented to **append**, both
//! special-case a buffer printed into itself, and neither property is
//! observable through a cfunction that returns a fresh string.
//!
//! The escape width is the other subject. `pp.zig`'s `escapeString` answers how
//! many columns it wrote and the pretty printer's alignment is computed from it, so
//! a width consistently two too small would show up only as slightly wrong
//! wrapping in output no test compares.
//!
//! ## No abi, and no adapter
//!
//! **`escapeString` has no abi**, and this file is why. One existed with
//! exactly one caller left: a C contract, which needed the width and could not
//! take a `raise.Raising(i32)`. Inside the compilation the width is just a
//! return value and the error is just an error, so the abi, its
//! `raise.reported` wrapper and its `@export` all went with the `.c` file.
//!
//! The abstract type below is the other one. A C contract has to build a
//! `abstract_type.AbstractType` and pass it through an adapter pool,
//! because the runtime dispatches raising Zig callbacks and C cannot define
//! one. Here it is an ordinary `AbstractType` literal with no callbacks at
//! all.

const std = @import("std");
const repr = @import("repr");
const harness = @import("harness.zig");
const subsystems = @import("subsystems");
const value = @import("subsystems").value;
const gc_alloc = @import("subsystems").gc_alloc;
const buffers = @import("subsystems").value.buffers;
const core_env = @import("subsystems").env;
const wrap = @import("subsystems").value.wrap;
const vm_lifecycle = @import("subsystems").lifecycle;
const abstracts = @import("subsystems").value.abstracts;
const abstract_type = @import("subsystems").abstract_type;
const pp_describe = @import("subsystems").pp_describe;
const strings = @import("subsystems").value.strings;
const tables = @import("subsystems").value.tables;
const expect = @import("expect.zig").expect;

/// The subject, by import. `toStringB` and `descriptionB` raise — rendering a
/// value runs an abstract type's `tostring` callback — so a caller outside the
/// compilation would have to read the report instead of the error.
const describe = subsystems.pp_describe;

var test_env: *tables.Table = undefined;

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

// --------------------------------------------------------------- appending

/// Both functions append. Every caller in the tree relies on it — `%v` in the
/// middle of a format string is the common case — and a version that reset the
/// buffer first would pass every Janet suite that formats a whole string at
/// once.
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
    // **The length is read before the '@' is pushed**, so what is escaped is
    // what the buffer held rather than what it holds after the marker. Pushing
    // first makes the marker part of its own escaped content, which is
    // `a\nb@"a\\nb@"` -- the trailing `@` inside the quotes.
    checkBuffer(d, "a\nb@\"a\\nb\"");
}

// ---------------------------------------------------------------- escaping

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

// ----------------------------------------------------------------- numbers

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

// -------------------------------------------------------- the two wrappers

/// `pp.toString` answers with the contents of a byte type and with a
/// rendering of everything else; `pp.description` renders in every case.
/// The three byte types take a path through neither renderer at all, which is
/// why a change there is invisible to a test that only checks the text.
/// Neither wrapper can raise for any value below, which is why they are called
/// directly here.
fn theTwoWrappersDifferWhereTheyShould() void {
    const s = value.fromBytes("a\"b", .string);
    const k = value.fromBytes("kw", .keyword);
    const n = harness.wrapInteger(12);

    checkString(pp_describe.toString(s), "a\"b");
    checkString(pp_describe.description(s), "\"a\\\"b\"");
    checkString(pp_describe.toString(k), "kw");
    checkString(pp_describe.description(k), ":kw");
    checkString(pp_describe.toString(n), "12");
    checkString(pp_describe.description(n), "12");

    // A buffer answers with a copy of its contents rather than with itself.
    const b: *buffers.Buffer = buffers.new(4);
    _ = buffers.pushCstringAbi(b, "raw");
    checkString(pp_describe.toString(wrap.fromBuffer(b)), "raw");
    checkString(pp_describe.description(wrap.fromBuffer(b)), "@\"raw\"");

    // A symbol is returned as it stands, without a copy: the identity is the
    // point, since symbols are interned.
    const sym = value.fromBytes("sym", .symbol);
    expect(pp_describe.toString(sym) == wrap.toSymbol(sym));
}

// ------------------------------------------------------------ the callables

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
}

/// A pointer description truncates the type name at 32 bytes, which keeps the
/// whole thing inside the fixed reservation made before writing it. Nothing in
/// Janet has a name that long, so the bound is never approached in practice
/// and would never be noticed if it were wrong.
///
/// A C contract has to route the type through an adapter pool, because the
/// runtime dispatches raising Zig callbacks; this one declares none at all.
///
/// **It is a container declaration and must stay one.** An abstract stores
/// its type by address and outlives the frame that made it, so a
/// function-local would leave `gc/sweep.zig`'s `clearMemory` dereferencing a
/// dead pointer at teardown -- a bus error inside `deinitBlock`, nowhere near
/// here. It was a local while it was a struct literal, which Zig materialises
/// statically; making it a call is what surfaced the crash.
const long_name = abstract_type.define(anyopaque, .{
    .name = "abstract/with-an-extremely-long-type-name-here",
});

fn thePointerDescriptionTruncatesItsTitle() !void {
    const p = abstracts.newBytes(&long_name, 8);
    const b: *buffers.Buffer = buffers.new(64);

    try describe.descriptionB(b, wrap.fromAbstract(p));
    expect(b.slice()[0] == '<');
    expect(b.slice()[@intCast(b.count - 1)] == '>');
    // '<' + exactly 32 title bytes + " 0x". The name is 45 bytes long, so the
    // cut lands mid-word and that is the point.
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
    std.debug.print("pp describe contract ok\n", .{});
}
