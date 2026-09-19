//! Behavioral contract for the incremental parser.
//!
//! The parser is a byte-at-a-time state machine, and this file drives it
//! directly: the state stack growing, a clone diverging from its original, an
//! error being *read* and thereby cleared, a partial string sitting in `buf`.
//! It is also where the syntax itself is pinned -- what each delimiter closes
//! to, what each prefix expands to, and what the parser refuses.
//!
//! ## One parser, one contract
//!
//! There is one parser and no dialect to name, so `parserInit` is the only
//! way to start one and this file carries both halves: the machinery cases
//! and the syntax cases.
//!
//! ## The oracle is the printer, not a second parser
//!
//! The two parsers were each other's oracle while both existed. What replaces
//! that pair is `theRoundTrip`: `%w` writes a value as source, and that source
//! has to parse back to the value it was given. The printer's tables are not
//! the parser's, so the two sides are still independently derived, which is
//! what a contract owes. It is also the property the swap made load-bearing --
//! `bundle` writes its manifest with `%m` and reads it back with `parse`.
//!
//! What no round trip can reach is what has no printed form: the refusals,
//! the adjacency rule, the delimiter messages and the shebang. Those are
//! asserted directly, against what `notes/LANGUAGE.md` says they do.
//!
//! ## The checked pair is called rather than the abis
//!
//! `parser.consumeChecked` and `parser.eofChecked` panic on a parser that has
//! already finished or has an unread error in it. Reached by import each
//! refusal is a value, so both messages are one line here. The abis beside
//! them are what a fuzz target drives.
//!
//! ## The error field is read once
//!
//! `parser.parserError` clears what it returns and flushes the parser, which
//! is why the "unexpected closing delimiter" case asserts `:root`
//! immediately afterwards. A second read gives null. That is deliberate and
//! the reason `consumeChecked` has a second refusal: a parser whose error has
//! *not* been read cannot be fed.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const access = @import("subsystems").value.access;
const config = @import("config");
const expect = @import("expect.zig").expect;
const harness = @import("harness.zig");
const maps = @import("subsystems").value.maps;
const order = @import("subsystems").value.order;
const parser_core = @import("subsystems").parser;
const pretty = @import("subsystems").pp_pretty;
const repr = @import("repr");
const symbols = @import("subsystems").value.symbols;
const strings = @import("subsystems").value.strings;
const tuples = @import("subsystems").value.tuples;
const vm_lifecycle = @import("subsystems").lifecycle;
const wrap = @import("subsystems").value.wrap;

const guard = config.recursion_guard;

// ==========================================================================
// Cases
// ==========================================================================

/// Feed a whole string, one byte at a time, the way the public entry point is
/// documented to be used.
fn consume(parser: *parser_core.Parser, source: []const u8) !void {
    for (source) |character| try parser_core.consumeChecked(parser, character);
}

fn statusOf(parser: *parser_core.Parser) parser_core.ParserStatus {
    return parser_core.parserStatus(parser);
}

fn hasMore(parser: *parser_core.Parser) bool {
    return parser_core.parserHasMore(parser);
}

fn errorOf(parser: *parser_core.Parser) ?[*:0]const u8 {
    const message = parser_core.parserError(parser);
    return if (message == null) null else @ptrCast(message);
}

fn errorIs(parser: *parser_core.Parser, expected: []const u8) bool {
    const message = errorOf(parser) orelse return false;
    return std.mem.eql(u8, std.mem.span(message), expected);
}

/// A parser that has just been initialised, and the two numbers that describe
/// its stack. The capacity is 2 rather than 1 because the root state is pushed
/// into a freshly grown allocation.
fn theFreshParser() !void {
    var parser: parser_core.Parser = undefined;
    parser_core.parserInit(&parser);
    defer parser_core.parserDeinit(&parser);

    expect(statusOf(&parser) == parser_core.ParserStatus.root);
    expect(parser.line == 1 and parser.column == 0);
    expect(parser.states.items.len == 1 and parser.states.capacity == 2);
    expect(parser.states.items[0].argn == 0);
    expect(!hasMore(&parser));
}

/// A clone owns its own `args` and `states`, so producing from one does not
/// consume the other's pending values.
fn aCloneOwnsItsOwnQueue() !void {
    var parser: parser_core.Parser = undefined;
    var clone: parser_core.Parser = undefined;
    parser_core.parserInit(&parser);

    try consume(&parser, "1 2");
    try parser_core.eofChecked(&parser);
    expect(statusOf(&parser) == parser_core.ParserStatus.dead);
    expect(hasMore(&parser));
    expect(parser.pending == 2);

    parser_core.parserClone(&parser, &clone);
    expect(clone.pending == parser.pending);
    expect(clone.args.items.ptr != parser.args.items.ptr);
    expect(clone.states.items.ptr != parser.states.items.ptr);

    expect(harness.integerIs(parser_core.parserProduce(&parser), 1));
    expect(harness.integerIs(parser_core.parserProduce(&parser), 2));
    expect(!hasMore(&parser));

    // The clone still has both, and `parserProduceWrapped` gives back the
    // one-element tuple the parser stores rather than the value inside it,
    // which is where the source mapping lives.
    const wrapped = parser_core.parserProduceWrapped(&clone);
    expect(harness.isType(wrapped, repr.Tag.tuple));
    const tuple = wrap.toTuple(wrapped);
    expect(tuples.head(tuple).length == 1);
    expect(harness.integerIs(tuple[0], 1));
    expect(tuples.head(tuple).sm_line == 1);
    expect(harness.integerIs(parser_core.parserProduce(&clone), 2));
    expect(!hasMore(&clone));

    parser_core.parserDeinit(&clone);
    parser_core.parserDeinit(&parser);
}

/// The four string escapes that are not one byte each: a named escape, a hex
/// pair, and the two Unicode forms, which are encoded as UTF-8.
fn theStringEscapes() !void {
    var parser: parser_core.Parser = undefined;
    parser_core.parserInit(&parser);
    defer parser_core.parserDeinit(&parser);

    try consume(&parser, "\"a\\n\\x42\\u03bb\\U01f600\" ");
    const val = parser_core.parserProduce(&parser);
    expect(harness.isType(val, repr.Tag.string));

    const expected = [_]u8{ 'a', '\n', 'B', 0xCE, 0xBB, 0xF0, 0x9F, 0x98, 0x80 };
    const string = wrap.toString(val);
    expect(strings.head(string).length == expected.len);
    expect(std.mem.eql(u8, string[0..expected.len], &expected));
}

/// The other two literal forms that bring their own delimiters: a raw string
/// opened by a run of three quotes, and a buffer opened by `!`.
fn theOtherLiterals() !void {
    var parser: parser_core.Parser = undefined;

    parser_core.parserInit(&parser);
    try consume(&parser, "\"\"\"hello\"\"\" ");
    expect(harness.stringValueIs(parser_core.parserProduce(&parser), "hello"));
    parser_core.parserDeinit(&parser);

    parser_core.parserInit(&parser);
    try consume(&parser, "!\"abc\" ");
    const val = parser_core.parserProduce(&parser);
    expect(harness.isType(val, repr.Tag.buffer));
    const buffer = wrap.toBuffer(val);
    expect(buffer.count == 3);
    expect(std.mem.eql(u8, buffer.slice()[0..3], "abc"));
    parser_core.parserDeinit(&parser);
}

/// A clone taken mid-token owns its own `buf`, so the two can be finished
/// differently.
fn aCloneOwnsItsOwnBuffer() !void {
    var parser: parser_core.Parser = undefined;
    var clone: parser_core.Parser = undefined;

    parser_core.parserInit(&parser);
    try consume(&parser, "\"abc");
    expect(parser.buf.items.len == 3);

    parser_core.parserClone(&parser, &clone);
    expect(clone.buf.items.len == 3);
    expect(clone.buf.items.ptr != parser.buf.items.ptr);
    expect(std.mem.eql(u8, clone.buf.items, parser.buf.items));

    try consume(&parser, "\"");
    try consume(&clone, "d\"");
    expect(harness.stringValueIs(parser_core.parserProduce(&parser), "abc"));
    expect(harness.stringValueIs(parser_core.parserProduce(&clone), "abcd"));

    parser_core.parserDeinit(&clone);
    parser_core.parserDeinit(&parser);
}

/// The state stack grows past its initial two entries, and nesting unwinds in
/// the order it was built.
fn theStateStackGrows() !void {
    var parser: parser_core.Parser = undefined;
    parser_core.parserInit(&parser);
    defer parser_core.parserDeinit(&parser);

    try consume(&parser, "((((1)))) ");
    expect(parser.states.capacity > 2);

    var val = parser_core.parserProduce(&parser);
    for (0..4) |_| {
        expect(harness.isType(val, repr.Tag.tuple));
        val = wrap.toTuple(val)[0];
    }
    expect(harness.integerIs(val, 1));
}

/// `'x` is rewritten to `(quote x)` by the parser rather than by a macro, and
/// the tuple it builds is where the source mapping lives.
fn theQuoteShorthand() !void {
    var parser: parser_core.Parser = undefined;
    parser_core.parserInit(&parser);
    defer parser_core.parserDeinit(&parser);

    try consume(&parser, "'x ");
    const val = parser_core.parserProduce(&parser);
    expect(harness.isType(val, repr.Tag.tuple));
    const tuple = wrap.toTuple(val);
    expect(tuples.head(tuple).length == 2);
    expect(harness.symbolIs(tuple[0], "quote"));
    expect(harness.symbolIs(tuple[1], "x"));
    expect(tuples.head(tuple).sm_line == 1);
}

/// `flush` abandons whatever is half-parsed and returns the machine to root.
fn theFlush() !void {
    var parser: parser_core.Parser = undefined;
    parser_core.parserInit(&parser);
    defer parser_core.parserDeinit(&parser);

    try consume(&parser, "(");
    expect(statusOf(&parser) == parser_core.ParserStatus.pending);
    parser_core.parserFlush(&parser);
    expect(statusOf(&parser) == parser_core.ParserStatus.root);
}

/// The five parse errors, and the one property that makes reading one an
/// action rather than an inspection.
fn theParseErrors() !void {
    var parser: parser_core.Parser = undefined;

    parser_core.parserInit(&parser);
    try consume(&parser, "\"\\q");
    expect(statusOf(&parser) == parser_core.ParserStatus.@"error");
    expect(errorIs(&parser, "invalid string escape sequence"));
    parser_core.parserDeinit(&parser);

    // Reading the error clears it and flushes the parser, so the status goes
    // back to root and a second read gives nothing. The message names where
    // the unclosed form opened, so it is matched by prefix rather than whole.
    parser_core.parserInit(&parser);
    try consume(&parser, ")");
    expect(statusOf(&parser) == parser_core.ParserStatus.@"error");
    const message = errorOf(&parser) orelse unreachable;
    expect(std.mem.indexOf(u8, std.mem.span(message), "unexpected closing delimiter") != null);
    expect(statusOf(&parser) == parser_core.ParserStatus.root);
    expect(errorOf(&parser) == null);
    parser_core.parserDeinit(&parser);

    parser_core.parserInit(&parser);
    try consume(&parser, "12abc ");
    expect(statusOf(&parser) == parser_core.ParserStatus.@"error");
    expect(errorIs(&parser, "symbol literal cannot start with a digit"));
    parser_core.parserDeinit(&parser);

    // A lone continuation byte is invalid UTF-8, and the message names which
    // of the two token kinds was being read.
    parser_core.parserInit(&parser);
    try parser_core.consumeChecked(&parser, 0xC2);
    try parser_core.consumeChecked(&parser, ' ');
    expect(statusOf(&parser) == parser_core.ParserStatus.@"error");
    expect(errorIs(&parser, "invalid utf-8 in symbol"));
    parser_core.parserDeinit(&parser);

    parser_core.parserInit(&parser);
    try parser_core.consumeChecked(&parser, ':');
    try parser_core.consumeChecked(&parser, 0xC2);
    try parser_core.consumeChecked(&parser, ' ');
    expect(statusOf(&parser) == parser_core.ParserStatus.@"error");
    expect(errorIs(&parser, "invalid utf-8 in keyword"));
    parser_core.parserDeinit(&parser);
}

/// The five atoms the root state recognises without a delimiter.
fn theAtoms() !void {
    var parser: parser_core.Parser = undefined;
    parser_core.parserInit(&parser);
    defer parser_core.parserDeinit(&parser);

    try consume(&parser, ":key nil false true symbol ");
    expect(harness.keywordIs(parser_core.parserProduce(&parser), "key"));
    expect(harness.isType(parser_core.parserProduce(&parser), repr.Tag.nil));

    const false_value = parser_core.parserProduce(&parser);
    expect(harness.isType(false_value, repr.Tag.boolean));
    expect(!wrap.toBoolean(false_value));

    const true_value = parser_core.parserProduce(&parser);
    expect(harness.isType(true_value, repr.Tag.boolean));
    expect(wrap.toBoolean(true_value));

    expect(harness.symbolIs(parser_core.parserProduce(&parser), "symbol"));
}

/// The two refusals `parser.consumeChecked` can make.
///
/// The distinction they draw is the parser's whole error policy: a *parse*
/// error is data and goes into the parser's own error field for the caller to
/// read, while a *use* error is a panic, there being no value to give back.
/// Feeding a machine that has already finished is one, and feeding one whose
/// error nobody has looked at is the other. Both are asserted here because a
/// port could keep one and lose the other.
fn aFinishedParserRefusesMore() !void {
    var parser: parser_core.Parser = undefined;

    parser_core.parserInit(&parser);
    try consume(&parser, "1");
    try parser_core.eofChecked(&parser);
    expect(statusOf(&parser) == parser_core.ParserStatus.dead);

    const fed = harness.raised(parser_core.consumeChecked, .{ &parser, ' ' }).?;
    expect(fed.says("parser is dead, cannot consume"));

    // `eof` refuses for the same reason, which matters because it is the one a
    // REPL reaches by pressing return twice.
    const twice = harness.raised(parser_core.eofChecked, .{&parser}).?;
    expect(twice.says("parser is dead, cannot consume"));
    parser_core.parserDeinit(&parser);

    parser_core.parserInit(&parser);
    try consume(&parser, "\"\\q");
    expect(statusOf(&parser) == parser_core.ParserStatus.@"error");

    const unread = harness.raised(parser_core.consumeChecked, .{ &parser, ' ' }).?;
    expect(unread.says("parser has unchecked error, cannot consume"));

    // Reading the error is what makes the parser usable again.
    expect(errorIs(&parser, "invalid string escape sequence"));
    try consume(&parser, "7 ");
    expect(harness.integerIs(parser_core.parserProduce(&parser), 7));
    parser_core.parserDeinit(&parser);
}

/// The one value `source` parses to, with the parser closed.
fn only(source: []const u8) !repr.Value {
    var parser: parser_core.Parser = undefined;
    parser_core.parserInit(&parser);
    defer parser_core.parserDeinit(&parser);
    try consume(&parser, source);
    try parser_core.eofChecked(&parser);
    expect(parser_core.parserHasMore(&parser));
    return parser_core.parserProduce(&parser);
}

/// The message `source` earns, or null where it parses.
fn refusal(source: []const u8) ?[]const u8 {
    var parser: parser_core.Parser = undefined;
    parser_core.parserInit(&parser);
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

/// The oracle: what the printer writes, the parser reads back.
///
/// Janet's parser was this contract's oracle until step 7 removed it. `%w`
/// writes a value as source, so printing a parsed value and parsing the
/// result must give the value back. The printer's tables are not the
/// parser's, so the two sides are independently derived; and a defect in
/// either shows here, because only a matched pair of defects cancels.
fn theRoundTrip() !void {
    const sources = [_][]const u8{
        "1",      "-2",        "3.5",   "1e3",        "0x10",
        "nil",    "true",      "false", ":a",         ":a/b",
        "foo",    "foo/bar",   "+",     "a@b",        "a^b",
        "\"ab\"", "\"a\\nb\"", "(1 2)", "(a (b))",    "[1 2 3]",
        "[]",     "{:a 1}",    "{}",    "[{:a [1]}]",
    };
    for (sources) |source| {
        const parsed = try only(source);
        const printed = try pretty.source(null, guard, parsed, 0, 0);
        const reparsed = try only(printed.slice());
        expect(order.equals(parsed, reparsed));
    }
}

/// `[ ]` closes to a vector where Janet's closes to a bracketed tuple, and
/// `{ }` closes to a map in both.
fn theCollections() !void {
    const vector = try only("[1 2 3]");
    expect(repr.checkType(vector, repr.Tag.vector));
    expect(harness.integerIs(try access.getIndex(vector, 1), 2));

    const empty = try only("[]");
    expect(repr.checkType(empty, repr.Tag.vector));

    const map = try only("{:a 1}");
    expect(repr.checkType(map, repr.Tag.map));

    const tuple = try only("(1 2)");
    expect(repr.checkType(tuple, repr.Tag.tuple));

    // A vector nests in a tuple and a tuple in a vector, and neither becomes
    // the other.
    const nested = try only("([1] 2)");
    expect(repr.checkType(nested, repr.Tag.tuple));
    expect(repr.checkType(try access.getIndex(nested, 0), repr.Tag.vector));
}

/// `!` opens what `@` opens in Janet, and is an ordinary character anywhere
/// else in a symbol.
fn theMutableContainers() !void {
    expect(repr.checkType(try only("![1 2]"), repr.Tag.array));
    expect(repr.checkType(try only("!(1 2)"), repr.Tag.array));
    expect(repr.checkType(try only("!{:a 1}"), repr.Tag.table));
    expect(repr.checkType(try only("!\"ab\""), repr.Tag.buffer));

    // `assoc!` is a symbol, and so is a bare `!`.
    expect(harness.symbolIs(try only("assoc!"), "assoc!"));
    expect(harness.symbolIs(try only("!"), "!"));
    expect(harness.symbolIs(try only("!foo"), "!foo"));
}

/// A run of `"` is classified by its length.
fn theStrings() !void {
    expect(harness.stringIs(wrap.toString(try only("\"ab\"")), "ab"));
    expect(harness.stringIs(wrap.toString(try only("\"\"")), ""));
    expect(harness.stringIs(wrap.toString(try only("\"\"\"ab\"\"\"")), "ab"));

    // A raw string processes no escape and takes a newline.
    expect(harness.stringIs(wrap.toString(try only("\"\"\"a\\nb\"\"\"")), "a\\nb"));

    // An ordinary string may not span lines, where Janet dropped the newline.
    expect(refusalIs("\"a\nb\"", "newline in string"));

    // An escape does not hand the rest of the string to a different consumer.
    // The escape states returned to Janet's string consumer rather than
    // Wattle's, so until step 7 a newline was refused before an escape and
    // silently dropped after one: `"ab<newline>c"` was a parse error and
    // `"a\tb<newline>c"` was the four-byte string `a<tab>bc`.
    expect(refusalIs("\"a\\tb\nc\"", "newline in string"));
    expect(refusalIs("\"a\\x41b\nc\"", "newline in string"));
    expect(refusalIs("\"a\\u03bbb\nc\"", "newline in string"));

    // A run shorter than the opening one is text inside a raw string.
    expect(harness.stringIs(wrap.toString(try only("\"\"\"a\"b\"\"\"")), "a\"b"));
}

/// A quoted collection is the collection, not a call: this is the property
/// the whole design turns on, and the reason `[ ]` is a vector in the tree.
fn theQuotedCollections() !void {
    const quoted = try only("'[a b]");
    expect(repr.checkType(quoted, repr.Tag.tuple));
    expect(harness.symbolIs(try access.getIndex(quoted, 0), "quote"));
    const inner = try access.getIndex(quoted, 1);
    expect(repr.checkType(inner, repr.Tag.vector));
    expect(harness.symbolIs(try access.getIndex(inner, 0), "a"));

    // A vector nests in a map and a map in a vector.
    const map = try only("{:a [1 2]}");
    expect(repr.checkType(map, repr.Tag.map));
    expect(repr.checkType(try access.get(map, wrap.fromKeyword(symbols.keyword("a"))), repr.Tag.vector));

    const holding = try only("[{:a 1}]");
    expect(repr.checkType(try access.getIndex(holding, 0), repr.Tag.map));
}

/// A raw string keeps Janet's post-processing: the indentation of the opening
/// delimiter comes off every line that carries it, and a leading and trailing
/// newline go.
fn theRawStringReindent() !void {
    expect(harness.stringIs(wrap.toString(try only("  \"\"\"\n  a\n  b\n  \"\"\"")), "a\nb"));
    // `!` before a run of three gives a buffer, as it does before one.
    expect(repr.checkType(try only("!\"\"\"ab\"\"\""), repr.Tag.buffer));
}

/// `#{ }` closes to a set, whose elements are its own rather than pairs.
fn theSetLiterals() !void {
    // The expected set is built rather than parsed: `only` parses and does not
    // evaluate, so a Janet-parsed `(hash-set 1 2 3)` is a tuple.
    var three = [_]repr.Value{ wrap.fromInteger(1), wrap.fromInteger(2), wrap.fromInteger(3) };
    const expected = wrap.fromAbstract(maps.build(.set, &three));
    expect(order.equals(try only("#{1 2 3}"), expected));
    expect(order.equals(try only("#{}"), wrap.fromAbstract(maps.build(.set, &.{}))));

    // Order does not distinguish one, and a repeat is one element.
    expect(order.equals(try only("#{1 2}"), try only("#{2 1}")));
    expect(order.equals(try only("#{1 1 2}"), try only("#{1 2}")));

    // A set nests, and is not a map.
    expect(repr.checkType(try access.getIndex(try only("[#{1}]"), 0), repr.Tag.abstract));
    expect(!order.equals(try only("#{1}"), try only("{1 1}")));

    // Every element is checked, not every other one as a map's keys are.
    expect(refusalIs("#{nil}", "cannot use nil as a key"));
    expect(refusalIs("#{1 nil}", "cannot use nil as a key"));

    // An odd count is fine, where a map literal refuses one.
    expect(order.equals(try only("#{1 2 3}"), expected));

    // Two identical forms are one element, because the set is built where it
    // is written: `#{(f) (f)}` holds one tuple, so `(f)` is called once, where
    // `[(f) (f)]` calls it twice. A map literal's repeated key behaves the
    // same way, keeping the last.
    const forms = try only("#{(f) (f)}");
    expect(maps.toTree(forms, .set).?.count == 1);

    // An unclosed one names `#{` rather than `{`.
    expect(refusalIs("#{1 2)", "mismatched delimiter ), #{ opened at line 1, column 1"));
}

/// `;` comments to end of line, and `,` is whitespace.
fn theWhitespaceAndComments() !void {
    expect(harness.integerIs(try only("; a comment\n7"), 7));
    expect(harness.integerIs(try only("7 ; trailing\n"), 7));

    const vector = try only("[1, 2, 3]");
    expect(repr.checkType(vector, repr.Tag.vector));
    expect(harness.integerIs(try access.getIndex(vector, 2), 3));

    // A comma inside a symbol is not possible, so it separates two of them.
    const pair = try only("(a,b)");
    expect(repr.checkType(pair, repr.Tag.tuple));
    expect(harness.symbolIs(try access.getIndex(pair, 0), "a"));
    expect(harness.symbolIs(try access.getIndex(pair, 1), "b"));
}

/// The prefixes, and what each expands to.
fn theReaderMacros() !void {
    const quoted = try only("'x");
    expect(repr.checkType(quoted, repr.Tag.tuple));
    expect(harness.symbolIs(try access.getIndex(quoted, 0), "quote"));

    const quasi = try only("`x");
    expect(harness.symbolIs(try access.getIndex(quasi, 0), "quasiquote"));

    const unquoted = try only("~x");
    expect(harness.symbolIs(try access.getIndex(unquoted, 0), "unquote"));

    const spliced = try only("|x");
    expect(harness.symbolIs(try access.getIndex(spliced, 0), "splice"));

    const short = try only("#(+ $ 1)");
    expect(harness.symbolIs(try access.getIndex(short, 0), "short-fn"));
    expect(repr.checkType(try access.getIndex(short, 1), repr.Tag.tuple));
}

/// `#!` is the shebang at the first byte of a source and dispatch anywhere
/// else.
fn theShebang() !void {
    expect(harness.integerIs(try only("#!/usr/bin/env wattle\n7"), 7));
    // The same two bytes further in are a tag, which is not implemented.
    expect(refusalIs("7\n#!/usr/bin/env wattle\n", "word tags are not implemented"));
}

/// `parser/state`'s two reports name Wattle's forms, not Janet's.
fn theParserState() !void {
    var parser: parser_core.Parser = undefined;
    parser_core.parserInit(&parser);
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
    expect(harness.symbolIs(try access.getIndex(try only("'  x"), 1), "x"));
    expect(harness.integerIs(try only("; note\n7"), 7));

    // `!` is not a prefix: it resolves by lookahead and leaves nothing
    // pending, so a `!` at the end of a line is the symbol.
    expect(harness.symbolIs(try only("!\n"), "!"));
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
    parser_core.parserInit(&parser);
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
    expect(harness.symbolIs(try only("a@b"), "a@b"));
    expect(harness.symbolIs(try only("a^b"), "a^b"));

    expect(refusalIs("#tuple [1 2]", "word tags are not implemented"));
    expect(refusalIs("#,", "unknown dispatch"));

    // A map literal's keys are checked where they are written, as in Janet.
    expect(refusalIs("{nil 1}", "cannot use nil as a key"));
    expect(refusalIs("{:a}", "map and table literals expect even number of arguments"));
}

// ==========================================================================
// Entry
// ==========================================================================

fn body() !void {
    try theFreshParser();
    try aCloneOwnsItsOwnQueue();
    try theStringEscapes();
    try theOtherLiterals();
    try aCloneOwnsItsOwnBuffer();
    try theStateStackGrows();
    try theQuoteShorthand();
    try theFlush();
    try theParseErrors();
    try theAtoms();
    try aFinishedParserRefusesMore();

    try theRoundTrip();
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
    body() catch @panic("parser_core: a kernel raised unexpectedly");
    vm_lifecycle.deinit();
}
