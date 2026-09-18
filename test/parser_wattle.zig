//! Behavioral contract for Wattle's parser.
//!
//! Wattle's parser is the second dialect in `runtime/parser.zig` and no
//! source in the tree loads through it yet: `parser/new` takes no dialect and
//! `module/paths` has no Wattle entry, so a contract feeding it bytes is the
//! only driver it has until the converter lands. That is why the assertions
//! here are about values rather than about programs.
//!
//! ## The two parsers are each other's oracle, where they overlap
//!
//! For every construct the languages share -- tokens, numbers, keywords,
//! escapes, the raw string's reindentation -- Wattle's parser over converted
//! source must give what Janet's gives over the original. `theSharedAtoms`
//! drives both parsers over the same bytes and compares, so a defect in the
//! scanner shows here rather than waiting for the converter to be blamed for
//! it.
//!
//! What that pair cannot reach is the part with no Janet spelling: `,` as
//! whitespace, `"""`, `;` comments, `#` dispatch, `!` containers, `[ ]`
//! closing to a vector, and `@` and `^` refused. Those are asserted directly.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const expect = @import("expect.zig").expect;
const harness = @import("harness.zig");
const access = @import("subsystems").value.access;
const maps = @import("subsystems").value.maps;
const order = @import("subsystems").value.order;
const parser_core = @import("subsystems").parser;
const repr = @import("repr");
const symbols = @import("subsystems").value.symbols;
const vm_lifecycle = @import("subsystems").lifecycle;
const wrap = @import("subsystems").value.wrap;

// ==========================================================================
// Cases
// ==========================================================================

fn consume(parser: *parser_core.Parser, source: []const u8) !void {
    for (source) |character| try parser_core.consumeChecked(parser, character);
}

/// The one value `source` parses to under `dialect`, with the parser closed.
fn only(dialect: parser_core.Dialect, source: []const u8) !repr.Value {
    var parser: parser_core.Parser = undefined;
    parser_core.parserInitDialect(&parser, dialect);
    defer parser_core.parserDeinit(&parser);
    try consume(&parser, source);
    try parser_core.eofChecked(&parser);
    expect(parser_core.parserHasMore(&parser));
    return parser_core.parserProduce(&parser);
}

fn wattle(source: []const u8) !repr.Value {
    return only(.wattle, source);
}

/// The message `source` earns under Wattle, or null where it parses.
fn refusal(source: []const u8) ?[]const u8 {
    var parser: parser_core.Parser = undefined;
    parser_core.parserInitDialect(&parser, .wattle);
    defer parser_core.parserDeinit(&parser);
    for (source) |character| {
        parser_core.consumeChecked(&parser, character) catch return "raised";
        if (parser_core.parserStatus(&parser) == parser_core.ParserStatus.@"error") {
            const message = parser_core.parserError(&parser) orelse return null;
            return std.mem.span(@as([*:0]const u8, @ptrCast(message)));
        }
    }
    return null;
}

fn refusalIs(source: []const u8, expected: []const u8) bool {
    const message = refusal(source) orelse return false;
    return std.mem.eql(u8, message, expected);
}

/// Every token both languages spell the same way parses to the same value.
///
/// This is the oracle pair: the subject is Wattle's parser and the expected
/// value comes from Janet's over the same bytes, not from a literal written
/// here, so neither is the other's implementation.
fn theSharedAtoms() !void {
    const shared = [_][]const u8{
        "1",      "-2",        "3.5",   "1e3",     "0x10",
        "nil",    "true",      "false", ":a",      ":a/b",
        "foo",    "foo/bar",   "+",     "a@b",     "a^b",
        "\"ab\"", "\"a\\nb\"", "(1 2)", "(a (b))",
    };
    for (shared) |source| {
        const mine = try wattle(source);
        const theirs = try only(.janet, source);
        expect(order.equals(mine, theirs));
    }
}

/// `[ ]` closes to a vector where Janet's closes to a bracketed tuple, and
/// `{ }` closes to a map in both.
fn theCollections() !void {
    const vector = try wattle("[1 2 3]");
    expect(repr.checkType(vector, repr.Tag.vector));
    expect(harness.integerIs(try access.getIndex(vector, 1), 2));

    const empty = try wattle("[]");
    expect(repr.checkType(empty, repr.Tag.vector));

    const map = try wattle("{:a 1}");
    expect(repr.checkType(map, repr.Tag.map));

    const tuple = try wattle("(1 2)");
    expect(repr.checkType(tuple, repr.Tag.tuple));

    // A vector nests in a tuple and a tuple in a vector, and neither becomes
    // the other.
    const nested = try wattle("([1] 2)");
    expect(repr.checkType(nested, repr.Tag.tuple));
    expect(repr.checkType(try access.getIndex(nested, 0), repr.Tag.vector));
}

/// `!` opens what `@` opens in Janet, and is an ordinary character anywhere
/// else in a symbol.
fn theMutableContainers() !void {
    expect(repr.checkType(try wattle("![1 2]"), repr.Tag.array));
    expect(repr.checkType(try wattle("!(1 2)"), repr.Tag.array));
    expect(repr.checkType(try wattle("!{:a 1}"), repr.Tag.table));
    expect(repr.checkType(try wattle("!\"ab\""), repr.Tag.buffer));

    // `assoc!` is a symbol, and so is a bare `!`.
    expect(harness.symbolIs(try wattle("assoc!"), "assoc!"));
    expect(harness.symbolIs(try wattle("!"), "!"));
    expect(harness.symbolIs(try wattle("!foo"), "!foo"));
}

/// A run of `"` is classified by its length.
fn theStrings() !void {
    expect(harness.stringIs(wrap.toString(try wattle("\"ab\"")), "ab"));
    expect(harness.stringIs(wrap.toString(try wattle("\"\"")), ""));
    expect(harness.stringIs(wrap.toString(try wattle("\"\"\"ab\"\"\"")), "ab"));

    // A raw string processes no escape and takes a newline.
    expect(harness.stringIs(wrap.toString(try wattle("\"\"\"a\\nb\"\"\"")), "a\\nb"));

    // An ordinary string may not span lines, where Janet drops the newline.
    expect(refusalIs("\"a\nb\"", "newline in string"));

    // A run shorter than the opening one is text inside a raw string.
    expect(harness.stringIs(wrap.toString(try wattle("\"\"\"a\"b\"\"\"")), "a\"b"));
}

/// A quoted collection is the collection, not a call: this is the property
/// the whole design turns on, and the reason `[ ]` is a vector in the tree.
fn theQuotedCollections() !void {
    const quoted = try wattle("'[a b]");
    expect(repr.checkType(quoted, repr.Tag.tuple));
    expect(harness.symbolIs(try access.getIndex(quoted, 0), "quote"));
    const inner = try access.getIndex(quoted, 1);
    expect(repr.checkType(inner, repr.Tag.vector));
    expect(harness.symbolIs(try access.getIndex(inner, 0), "a"));

    // A vector nests in a map and a map in a vector.
    const map = try wattle("{:a [1 2]}");
    expect(repr.checkType(map, repr.Tag.map));
    expect(repr.checkType(try access.get(map, wrap.fromKeyword(symbols.keyword("a"))), repr.Tag.vector));

    const holding = try wattle("[{:a 1}]");
    expect(repr.checkType(try access.getIndex(holding, 0), repr.Tag.map));
}

/// A raw string keeps Janet's post-processing: the indentation of the opening
/// delimiter comes off every line that carries it, and a leading and trailing
/// newline go.
fn theRawStringReindent() !void {
    expect(harness.stringIs(wrap.toString(try wattle("  \"\"\"\n  a\n  b\n  \"\"\"")), "a\nb"));
    // `!` before a run of three gives a buffer, as it does before one.
    expect(repr.checkType(try wattle("!\"\"\"ab\"\"\""), repr.Tag.buffer));
}

/// `#{ }` closes to a set, whose elements are its own rather than pairs.
fn theSetLiterals() !void {
    // The expected set is built rather than parsed: `only` parses and does not
    // evaluate, so a Janet-parsed `(hash-set 1 2 3)` is a tuple.
    var three = [_]repr.Value{ wrap.fromInteger(1), wrap.fromInteger(2), wrap.fromInteger(3) };
    const expected = wrap.fromAbstract(maps.build(.set, &three));
    expect(order.equals(try wattle("#{1 2 3}"), expected));
    expect(order.equals(try wattle("#{}"), wrap.fromAbstract(maps.build(.set, &.{}))));

    // Order does not distinguish one, and a repeat is one element.
    expect(order.equals(try wattle("#{1 2}"), try wattle("#{2 1}")));
    expect(order.equals(try wattle("#{1 1 2}"), try wattle("#{1 2}")));

    // A set nests, and is not a map.
    expect(repr.checkType(try access.getIndex(try wattle("[#{1}]"), 0), repr.Tag.abstract));
    expect(!order.equals(try wattle("#{1}"), try wattle("{1 1}")));

    // Every element is checked, not every other one as a map's keys are.
    expect(refusalIs("#{nil}", "cannot use nil as a key"));
    expect(refusalIs("#{1 nil}", "cannot use nil as a key"));

    // An odd count is fine, where a map literal refuses one.
    expect(order.equals(try wattle("#{1 2 3}"), expected));

    // Two identical forms are one element, because the set is built where it
    // is written: `#{(f) (f)}` holds one tuple, so `(f)` is called once, where
    // `[(f) (f)]` calls it twice. A map literal's repeated key behaves the
    // same way, keeping the last.
    const forms = try wattle("#{(f) (f)}");
    expect(maps.toTree(forms, .set).?.count == 1);

    // An unclosed one names `#{` rather than `{`.
    expect(refusalIs("#{1 2)", "mismatched delimiter ), #{ opened at line 1, column 1"));
}

/// `;` comments to end of line, and `,` is whitespace.
fn theWhitespaceAndComments() !void {
    expect(harness.integerIs(try wattle("; a comment\n7"), 7));
    expect(harness.integerIs(try wattle("7 ; trailing\n"), 7));

    const vector = try wattle("[1, 2, 3]");
    expect(repr.checkType(vector, repr.Tag.vector));
    expect(harness.integerIs(try access.getIndex(vector, 2), 3));

    // A comma inside a symbol is not possible, so it separates two of them.
    const pair = try wattle("(a,b)");
    expect(repr.checkType(pair, repr.Tag.tuple));
    expect(harness.symbolIs(try access.getIndex(pair, 0), "a"));
    expect(harness.symbolIs(try access.getIndex(pair, 1), "b"));
}

/// The prefixes, and what each expands to.
fn theReaderMacros() !void {
    const quoted = try wattle("'x");
    expect(repr.checkType(quoted, repr.Tag.tuple));
    expect(harness.symbolIs(try access.getIndex(quoted, 0), "quote"));

    const quasi = try wattle("`x");
    expect(harness.symbolIs(try access.getIndex(quasi, 0), "quasiquote"));

    const unquoted = try wattle("~x");
    expect(harness.symbolIs(try access.getIndex(unquoted, 0), "unquote"));

    const spliced = try wattle("|x");
    expect(harness.symbolIs(try access.getIndex(spliced, 0), "splice"));

    const short = try wattle("#(+ $ 1)");
    expect(harness.symbolIs(try access.getIndex(short, 0), "short-fn"));
    expect(repr.checkType(try access.getIndex(short, 1), repr.Tag.tuple));
}

/// `#!` is the shebang at the first byte of a source and dispatch anywhere
/// else.
fn theShebang() !void {
    expect(harness.integerIs(try wattle("#!/usr/bin/env wattle\n7"), 7));
    // The same two bytes further in are a tag, which is not implemented.
    expect(refusalIs("7\n#!/usr/bin/env wattle\n", "tagged literals are not implemented"));
}

/// `parser/state`'s two reports name Wattle's forms, not Janet's.
fn theParserState() !void {
    var parser: parser_core.Parser = undefined;
    parser_core.parserInitDialect(&parser, .wattle);
    defer parser_core.parserDeinit(&parser);

    // A pending raw string reports the run that opened it in quotes, where a
    // Janet parser would report backticks.
    try consume(&parser, "\"\"\"abc");
    const delimiters = try parser_core.parserStateDelimiters(&parser);
    expect(harness.stringIs(wrap.toString(delimiters), "\"\"\""));
}

/// A prefix and its form are one unit, and a newline between them is refused
/// where Janet leaves the parser pending and silent.
fn theAdjacencyRule() !void {
    expect(refusalIs("'\nx", "expected a form on the same line as ', opened at line 1, column 1"));
    expect(refusalIs("`\nx", "expected a form on the same line as `, opened at line 1, column 1"));
    expect(refusalIs("~\nx", "expected a form on the same line as ~, opened at line 1, column 1"));
    expect(refusalIs("|\nx", "expected a form on the same line as |, opened at line 1, column 1"));

    // A comment does not excuse the newline that ends it.
    expect(refusalIs("'; note\nx", "expected a form on the same line as ', opened at line 1, column 1"));

    // Whitespace within the line is fine, and so is a comment that the form
    // still follows on its own line.
    expect(harness.symbolIs(try access.getIndex(try wattle("'  x"), 1), "x"));
    expect(harness.integerIs(try wattle("; note\n7"), 7));

    // `!` is not a prefix: it resolves by lookahead and leaves nothing
    // pending, so a `!` at the end of a line is the symbol.
    expect(harness.symbolIs(try wattle("!\n"), "!"));
}

/// An unclosed form names what opened it, and a mismatch names both.
fn theDelimiterErrors() !void {
    expect(refusalIs("[1 2)", "mismatched delimiter ), [ opened at line 1, column 1"));
    expect(refusalIs("(1 2]", "mismatched delimiter ], ( opened at line 1, column 1"));
    expect(refusalIs("{:a 1]", "mismatched delimiter ], { opened at line 1, column 1"));
    expect(refusalIs(")", "unexpected closing delimiter )"));

    // An unterminated raw string names the run that opened it in the
    // delimiter that opened it, which is `"` here and a backtick in Janet.
    var parser: parser_core.Parser = undefined;
    parser_core.parserInitDialect(&parser, .wattle);
    defer parser_core.parserDeinit(&parser);
    try consume(&parser, "\"\"\"abc");
    parser_core.eofChecked(&parser) catch {};
    const message = parser_core.parserError(&parser) orelse unreachable;
    expect(std.mem.eql(
        u8,
        std.mem.span(@as([*:0]const u8, @ptrCast(message))),
        "unexpected end of source, \"\"\" opened at line 1, column 1",
    ));
}

/// What the parser refuses, by message rather than by silence.
fn theRefusals() !void {
    expect(refusalIs("@[1 2]", "@ is reserved"));
    expect(refusalIs("@{}", "@ is reserved"));
    expect(refusalIs("@foo", "@ is reserved"));
    expect(refusalIs("@", "@ is reserved"));
    expect(refusalIs("^foo", "^ is reserved"));

    // Inside a symbol each is ordinary, which the shared atoms also pin.
    expect(harness.symbolIs(try wattle("a@b"), "a@b"));
    expect(harness.symbolIs(try wattle("a^b"), "a^b"));

    expect(refusalIs("#tuple [1 2]", "tagged literals are not implemented"));
    expect(refusalIs("#,", "unknown dispatch"));

    // A map literal's keys are checked where they are written, as in Janet.
    expect(refusalIs("{nil 1}", "cannot use nil as a key"));
    expect(refusalIs("{:a}", "map and table literals expect even number of arguments"));
}

// ==========================================================================
// Entry
// ==========================================================================

fn body() !void {
    try theSharedAtoms();
    try theCollections();
    try theMutableContainers();
    try theStrings();
    try theQuotedCollections();
    try theRawStringReindent();
    try theSetLiterals();
    try theWhitespaceAndComments();
    try theReaderMacros();
    try theShebang();
    try theParserState();
    try theAdjacencyRule();
    try theDelimiterErrors();
    try theRefusals();
}

pub fn run() void {
    harness.init();
    body() catch @panic("parser_wattle: a kernel raised unexpectedly");
    vm_lifecycle.deinit();
}
