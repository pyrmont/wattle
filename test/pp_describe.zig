//! Behavioral contract for rendering one Janet value as text:
//! `janet_to_string_b`, `janet_description_b`, their two non-buffer wrappers,
//! and the escape table underneath all four.
//!
//! ## Why this exists rather than leaning on the Janet suites
//!
//! From Janet, both entry points are only ever reached through
//! `string/format` and friends, which hand them a buffer that is either empty
//! or is not the value being printed. Both are documented to **append**, both
//! special-case a buffer printed into itself, and neither property is
//! observable through a cfunction that returns a fresh string.
//!
//! The escape width is the other subject. `escapeStringImpl` answers how many
//! columns it wrote and the pretty printer's alignment is computed from it, so
//! a width consistently two too small would show up only as slightly wrong
//! wrapping in output no test compares.
//!
//! ## What the migration retired
//!
//! **The C face `janet_zig_pp_escape_string` is gone**, and this file is why.
//! It existed for `pp.c` under the other selector, outlived it, and had
//! exactly one caller left: `test/pp_describe.c`, which needed the width and
//! could not take a `raise.Raising(i32)`. Inside the compilation the width is
//! just a return value and the error is just an error, so the face, its
//! `raise.reported` wrapper and its `@export` all went with the `.c` file.
//! That is Phase 11's "delete the reporting faces with them" landing for the
//! first time on a real face rather than on a contract.
//!
//! The abstract type below is the other one. The C contract had to build a
//! `JanetAbstractType` and pass it through `test/support.zig`'s adapter pool,
//! because the runtime dispatches raising Zig callbacks and C cannot define
//! one. Here it is an ordinary `AbstractType` literal with no callbacks at
//! all.

const std = @import("std");
const abi = @import("abi");
const c = abi.c;
const harness = @import("harness.zig");
const subsystems = @import("subsystems");

/// The subject, by import. `toStringB` and `descriptionB` raise — rendering a
/// value runs an abstract type's `tostring` callback — so a caller outside the
/// compilation would have to read the report instead of the error.
const describe = subsystems.pp_describe;
const AbstractType = subsystems.abstract_type.AbstractType;

var test_env: [*c]c.JanetTable = undefined;

fn checkBuffer(b: *c.JanetBuffer, expected: []const u8) void {
    const count: usize = @intCast(b.count);
    if (count != expected.len or !std.mem.eql(u8, b.data[0..count], expected)) {
        std.debug.print("expected: {s}\n     got: {s}\n", .{ expected, b.data[0..count] });
        @panic("buffer mismatch");
    }
}

fn checkString(s: c.JanetString, expected: [*:0]const u8) void {
    if (!harness.stringIs(s, expected)) {
        std.debug.print("expected: {s}\n     got: {s}\n", .{ expected, s });
        @panic("string mismatch");
    }
}

fn eval(source: [*:0]const u8) c.Janet {
    var out: c.Janet = c.janet_wrap_nil();
    std.debug.assert(c.janet_dostring(test_env, source, "pp-describe-test", &out) == 0);
    return out;
}

// --------------------------------------------------------------- appending

/// Both functions append. Every caller in the tree relies on it — `%v` in the
/// middle of a format string is the common case — and a version that reset the
/// buffer first would pass every Janet suite that formats a whole string at
/// once.
fn bothAppendRatherThanReplace() !void {
    const b: *c.JanetBuffer = c.janet_buffer(16);

    _ = c.janet_buffer_push_cstring(b, "head:");
    try describe.toStringB(b, harness.wrapInteger(7));
    _ = c.janet_buffer_push_u8(b, '|');
    try describe.descriptionB(b, c.janet_cstringv("x"));
    checkBuffer(b, "head:7|\"x\"");

    // And again, so that a second append after a first is covered too.
    try describe.toStringB(b, c.janet_wrap_boolean(1));
    checkBuffer(b, "head:7|\"x\"true");
}

/// A buffer printed into itself. `toStringB` reserves the extra length before
/// pushing and `descriptionB` reserves five times it, because in both cases
/// the source of the bytes is the storage the push may reallocate. Dropping
/// either reservation is a use-after-free that a sanitizer build would catch
/// and an ordinary one would not.
fn aBufferPrintedIntoItself() !void {
    const b: *c.JanetBuffer = c.janet_buffer(1);
    _ = c.janet_buffer_push_cstring(b, "ab");
    try describe.toStringB(b, c.janet_wrap_buffer(b));
    checkBuffer(b, "abab");

    const d: *c.JanetBuffer = c.janet_buffer(1);
    _ = c.janet_buffer_push_cstring(d, "a\nb");
    try describe.descriptionB(d, c.janet_wrap_buffer(d));
    // The '@' is pushed before the length is read, so it is escaped as part of
    // the contents. That is a defect and it is pinned rather than corrected:
    // `FOUND.md` has it, and the pretty printer avoids it by escaping
    // `bufstartlen` bytes instead of `count`.
    checkBuffer(d, "a\nb@\"a\\nb@\"");
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
    const b: *c.JanetBuffer = c.janet_buffer(64);
    const width = try describe.escapeStringImpl(b, &raw, raw.len);

    checkBuffer(b, "\"\\\"\\n\\r\\0\\f\\v\\a\\b\\e\\\\\\t" ++
        "\\x1F \x7E\\x7F\\xFFz\"");

    // The width is the column count, which is the byte count here because
    // nothing written is multi-byte: two quotes, eleven two-byte escapes,
    // three four-byte escapes, and three bytes that escape to themselves.
    std.debug.assert(width == b.count);
    std.debug.assert(width == 2 + 11 * 2 + 3 * 4 + 3);
}

/// A description escapes; a stringification does not. This is the whole
/// difference between the two entry points for the byte types, and the pair is
/// asserted together so a change to one cannot look like a change to both.
fn descriptionEscapesWhereToStringDoesNot() !void {
    const s = c.janet_cstringv("a\"b");
    const b: *c.JanetBuffer = c.janet_buffer(16);

    try describe.toStringB(b, s);
    checkBuffer(b, "a\"b");

    b.count = 0;
    try describe.descriptionB(b, s);
    checkBuffer(b, "\"a\\\"b\"");

    // A keyword keeps its colon in a description and loses it in a string.
    b.count = 0;
    try describe.descriptionB(b, c.janet_ckeywordv("kw"));
    checkBuffer(b, ":kw");
    b.count = 0;
    try describe.toStringB(b, c.janet_ckeywordv("kw"));
    checkBuffer(b, "kw");
}

// ----------------------------------------------------------------- numbers

/// Three properties of the number path, none of which the suites pin.
fn theNumbers() !void {
    const b: *c.JanetBuffer = c.janet_buffer(32);

    // Negative zero prints without its sign.
    try describe.toStringB(b, c.janet_wrap_number(-0.0));
    checkBuffer(b, "0");

    // An integral value inside the exactly-representable range prints with no
    // fraction and no exponent.
    b.count = 0;
    try describe.toStringB(b, c.janet_wrap_number(9007199254740992.0));
    checkBuffer(b, "9007199254740992");

    // One past it: the integral shortcut must not take it, because `%.0f`
    // would print all of its digits as if they were significant.
    b.count = 0;
    try describe.toStringB(b, c.janet_wrap_number(9007199254740994.0));
    checkBuffer(b, "9.00719925474099e+15");

    b.count = 0;
    try describe.toStringB(b, c.janet_wrap_number(1.5));
    checkBuffer(b, "1.5");
}

// -------------------------------------------------------- the two wrappers

/// `janet_to_string` answers with the contents of a byte type and with a
/// rendering of everything else; `janet_description` renders in every case.
/// The three byte types take a path through neither renderer at all, which is
/// why a change there is invisible to a test that only checks the text.
/// The two wrappers are reached by *symbol* rather than by import, and
/// deliberately: `janet_to_string` and `janet_description` are what `janet.h`
/// declares and what an embedder calls, so the exported face is the subject
/// here rather than an obstacle to it. Neither can raise for any value below.
fn theTwoWrappersDifferWhereTheyShould() void {
    const s = c.janet_cstringv("a\"b");
    const k = c.janet_ckeywordv("kw");
    const n = harness.wrapInteger(12);

    checkString(c.janet_to_string(s), "a\"b");
    checkString(c.janet_description(s), "\"a\\\"b\"");
    checkString(c.janet_to_string(k), "kw");
    checkString(c.janet_description(k), ":kw");
    checkString(c.janet_to_string(n), "12");
    checkString(c.janet_description(n), "12");

    // A buffer answers with a copy of its contents rather than with itself.
    const b: *c.JanetBuffer = c.janet_buffer(4);
    _ = c.janet_buffer_push_cstring(b, "raw");
    checkString(c.janet_to_string(c.janet_wrap_buffer(b)), "raw");
    checkString(c.janet_description(c.janet_wrap_buffer(b)), "@\"raw\"");

    // A symbol is returned as it stands, without a copy: the identity is the
    // point, since symbols are interned.
    const sym = c.janet_csymbolv("sym");
    std.debug.assert(c.janet_to_string(sym) == c.janet_unwrap_symbol(sym));
}

// ------------------------------------------------------------ the callables

/// A registered cfunction prints its registry name, with the prefix when it
/// has one. An unregistered one falls through to the pointer description,
/// which is the same fall-through an anonymous function takes.
fn theCfunctionsAndFunctions() !void {
    const b: *c.JanetBuffer = c.janet_buffer(64);

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
    std.debug.assert(b.count > 11);
    std.debug.assert(std.mem.eql(u8, b.data[0..12], "<function 0x"));
    std.debug.assert(b.data[@intCast(b.count - 1)] == '>');
}

/// A pointer description truncates the type name at 32 bytes, which keeps the
/// whole thing inside the fixed reservation made before writing it. Nothing in
/// Janet has a name that long, so the bound is never approached in practice
/// and would never be noticed if it were wrong.
///
/// The abstract type is an ordinary literal here. The C contract had to route
/// one through `test/support.zig`'s adapter pool, because the runtime
/// dispatches raising Zig callbacks; this one declares none at all.
fn thePointerDescriptionTruncatesItsTitle() !void {
    const long_name = AbstractType{
        .name = "abstract/with-an-extremely-long-type-name-here",
    };
    const p = c.janet_abstract(@ptrCast(&long_name), 8);
    const b: *c.JanetBuffer = c.janet_buffer(64);

    try describe.descriptionB(b, c.janet_wrap_abstract(p));
    std.debug.assert(b.data[0] == '<');
    std.debug.assert(b.data[@intCast(b.count - 1)] == '>');
    // '<' + exactly 32 title bytes + " 0x". The name is 45 bytes long, so the
    // cut lands mid-word and that is the point.
    std.debug.assert(std.mem.eql(u8, b.data[1..36], "abstract/with-an-extremely-long- 0x"));
}

/// An abstract type with a `tostring` callback is wrapped in angle brackets
/// and its own name by a description, and is *not* wrapped by a
/// stringification. The two spellings are easy to swap and the suites print
/// only one of them.
fn anAbstractWithATostring() !void {
    const value = eval("(int/s64 -5)");
    const b: *c.JanetBuffer = c.janet_buffer(32);

    try describe.toStringB(b, value);
    checkBuffer(b, "-5");

    b.count = 0;
    try describe.descriptionB(b, value);
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
    _ = c.janet_init();
    test_env = c.janet_core_env(null);
    _ = c.janet_gcroot(c.janet_wrap_table(test_env));

    body() catch @panic("pp_describe: a renderer raised unexpectedly");

    c.janet_deinit();
    std.debug.print("pp describe contract ok\n", .{});
}
