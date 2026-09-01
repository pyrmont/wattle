//! Behavioral contract for the incremental parser.
//!
//! Janet's parser is a byte-at-a-time state machine with a public C entry
//! point, and the suites reach it only through `parse` and the REPL — which
//! feed it whole strings and read whole values. What they cannot see is the
//! machine between bytes: the state stack growing, a clone diverging from its
//! original, an error being *read* and thereby cleared, a partial string
//! sitting in `buf`. Those are the states this file drives directly.
//!
//! ## Two refusals a C contract cannot reach
//!
//!
//! `janet_parser_consume` and `janet_parser_eof` are abis over
//! `consumeChecked` and `eofChecked`, which panic on a parser that has already
//! finished or is holding an unread error. From C those are a jump with
//! nowhere to go — the C contract simply never fed a dead parser, so the two
//! messages had no test. Here each is one line, because `consumeChecked` is an
//! ordinary import and its refusal is a value.
//!
//! This is why the contract calls the *checked* pair rather than the abis. The
//! abis are still what a fuzz target drives, so nothing here is dead; what the
//! contract gains is being able to see both halves.
//!
//! ## The error field is read once
//!
//! `janet_parser_error` clears what it returns and flushes the parser, which
//! is why the "unexpected closing delimiter" case asserts `JANET_PARSE_ROOT`
//! immediately afterwards. A second read answers null. That is deliberate C
//! behaviour and the reason `consumeChecked` has a second refusal: a parser
//! whose error has *not* been read cannot be fed.

const std = @import("std");
const repr = @import("repr");
const constants = @import("constants");
const harness = @import("harness.zig");
const parser_core = @import("subsystems").parser;
const wrap = @import("subsystems").value.wrap;
const vm_lifecycle = @import("subsystems").lifecycle;
const strings = @import("subsystems").value.strings;
const tuples = @import("subsystems").value.tuples;
const expect = @import("expect.zig").expect;

/// Feed a whole string, one byte at a time, the way the public entry point is
/// documented to be used.
fn consume(parser: *parser_core.JanetParser, source: []const u8) !void {
    for (source) |character| try parser_core.consumeChecked(parser, character);
}

fn statusOf(parser: *parser_core.JanetParser) parser_core.JanetParserStatus {
    return parser_core.parserStatus(parser);
}

fn hasMore(parser: *parser_core.JanetParser) bool {
    return parser_core.parserHasMore(parser);
}

fn errorOf(parser: *parser_core.JanetParser) ?[*:0]const u8 {
    const message = parser_core.parserError(parser);
    return if (message == null) null else @ptrCast(message);
}

fn errorIs(parser: *parser_core.JanetParser, expected: []const u8) bool {
    const message = errorOf(parser) orelse return false;
    return std.mem.eql(u8, std.mem.span(message), expected);
}

/// A parser that has just been initialised, and the two counters that describe
/// its stack. `statecap` is 2 rather than 1 because the root state is pushed
/// into a freshly grown allocation.
fn theFreshParser() !void {
    var parser: parser_core.JanetParser = undefined;
    parser_core.parserInit(&parser);
    defer parser_core.parserDeinit(&parser);

    expect(statusOf(&parser) == constants.JANET_PARSE_ROOT);
    expect(parser.line == 1 and parser.column == 0);
    expect(parser.statecount == 1 and parser.statecap == 2);
    expect(parser.states.?[0].argn == 0);
    expect(!hasMore(&parser));
}

/// A clone owns its own `args` and `states`, so producing from one does not
/// consume the other's pending values.
fn aCloneOwnsItsOwnQueue() !void {
    var parser: parser_core.JanetParser = undefined;
    var clone: parser_core.JanetParser = undefined;
    parser_core.parserInit(&parser);

    try consume(&parser, "1 2");
    try parser_core.eofChecked(&parser);
    expect(statusOf(&parser) == constants.JANET_PARSE_DEAD);
    expect(hasMore(&parser));
    expect(parser.pending == 2);

    parser_core.parserClone(&parser, &clone);
    expect(clone.pending == parser.pending);
    expect(clone.args != parser.args);
    expect(clone.states != parser.states);

    expect(harness.integerIs(parser_core.parserProduce(&parser), 1));
    expect(harness.integerIs(parser_core.parserProduce(&parser), 2));
    expect(!hasMore(&parser));

    // The clone still has both, and `produce_wrapped` answers the one-element
    // tuple the parser stores rather than the value inside it — which is where
    // the source mapping lives.
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
    var parser: parser_core.JanetParser = undefined;
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

/// The other two literal forms that carry their own delimiters.
fn theOtherLiterals() !void {
    var parser: parser_core.JanetParser = undefined;

    parser_core.parserInit(&parser);
    try consume(&parser, "`hello` ");
    expect(harness.stringValueIs(parser_core.parserProduce(&parser), "hello"));
    parser_core.parserDeinit(&parser);

    parser_core.parserInit(&parser);
    try consume(&parser, "@\"abc\" ");
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
    var parser: parser_core.JanetParser = undefined;
    var clone: parser_core.JanetParser = undefined;

    parser_core.parserInit(&parser);
    try consume(&parser, "\"abc");
    expect(parser.bufcount == 3);

    parser_core.parserClone(&parser, &clone);
    expect(clone.bufcount == 3);
    expect(clone.buf != parser.buf);
    expect(std.mem.eql(u8, clone.buf.?[0..3], parser.buf.?[0..3]));

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
    var parser: parser_core.JanetParser = undefined;
    parser_core.parserInit(&parser);
    defer parser_core.parserDeinit(&parser);

    try consume(&parser, "((((1)))) ");
    expect(parser.statecap > 2);

    var val = parser_core.parserProduce(&parser);
    for (0..4) |_| {
        expect(harness.isType(val, repr.Tag.tuple));
        val = wrap.toTuple(val)[0];
    }
    expect(harness.integerIs(val, 1));
}

/// `'x` is rewritten to `(quote x)` by the parser rather than by a macro, and
/// the tuple it builds carries the source mapping.
fn theQuoteShorthand() !void {
    var parser: parser_core.JanetParser = undefined;
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
    var parser: parser_core.JanetParser = undefined;
    parser_core.parserInit(&parser);
    defer parser_core.parserDeinit(&parser);

    try consume(&parser, "(");
    expect(statusOf(&parser) == constants.JANET_PARSE_PENDING);
    parser_core.parserFlush(&parser);
    expect(statusOf(&parser) == constants.JANET_PARSE_ROOT);
}

/// The five parse errors, and the one property that makes reading one an
/// action rather than an inspection.
fn theParseErrors() !void {
    var parser: parser_core.JanetParser = undefined;

    parser_core.parserInit(&parser);
    try consume(&parser, "\"\\q");
    expect(statusOf(&parser) == constants.JANET_PARSE_ERROR);
    expect(errorIs(&parser, "invalid string escape sequence"));
    parser_core.parserDeinit(&parser);

    // Reading the error clears it and flushes the parser, so the status goes
    // back to root and a second read answers nothing. The message names where
    // the unclosed form opened, so it is matched by prefix rather than whole.
    parser_core.parserInit(&parser);
    try consume(&parser, ")");
    expect(statusOf(&parser) == constants.JANET_PARSE_ERROR);
    const message = errorOf(&parser) orelse unreachable;
    expect(std.mem.indexOf(u8, std.mem.span(message), "unexpected closing delimiter") != null);
    expect(statusOf(&parser) == constants.JANET_PARSE_ROOT);
    expect(errorOf(&parser) == null);
    parser_core.parserDeinit(&parser);

    parser_core.parserInit(&parser);
    try consume(&parser, "12abc ");
    expect(statusOf(&parser) == constants.JANET_PARSE_ERROR);
    expect(errorIs(&parser, "symbol literal cannot start with a digit"));
    parser_core.parserDeinit(&parser);

    // A lone continuation byte is invalid UTF-8, and the message names which
    // of the two token kinds was being read.
    parser_core.parserInit(&parser);
    try parser_core.consumeChecked(&parser, 0xC2);
    try parser_core.consumeChecked(&parser, ' ');
    expect(statusOf(&parser) == constants.JANET_PARSE_ERROR);
    expect(errorIs(&parser, "invalid utf-8 in symbol"));
    parser_core.parserDeinit(&parser);

    parser_core.parserInit(&parser);
    try parser_core.consumeChecked(&parser, ':');
    try parser_core.consumeChecked(&parser, 0xC2);
    try parser_core.consumeChecked(&parser, ' ');
    expect(statusOf(&parser) == constants.JANET_PARSE_ERROR);
    expect(errorIs(&parser, "invalid utf-8 in keyword"));
    parser_core.parserDeinit(&parser);
}

/// The five atoms the root state recognises without a delimiter.
fn theAtoms() !void {
    var parser: parser_core.JanetParser = undefined;
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

/// The two refusals `janet_parser_consume` carries, neither of which the C
/// contract could reach.
///
/// The distinction they draw is the parser's whole error policy: a *parse*
/// error is data, and goes into `parser->error` for the caller to read; a
/// *use* error — feeding a machine that has already finished, or one whose
/// error nobody has looked at — is a panic, because there is no value to
/// answer with. Both halves are asserted here because a port could easily
/// keep one and lose the other.
fn aFinishedParserRefusesMore() !void {
    var parser: parser_core.JanetParser = undefined;

    parser_core.parserInit(&parser);
    try consume(&parser, "1");
    try parser_core.eofChecked(&parser);
    expect(statusOf(&parser) == constants.JANET_PARSE_DEAD);

    const fed = harness.raised(parser_core.consumeChecked, .{ &parser, ' ' }).?;
    expect(fed.says("parser is dead, cannot consume"));

    // `eof` refuses for the same reason, which matters because it is the one a
    // REPL reaches by pressing return twice.
    const twice = harness.raised(parser_core.eofChecked, .{&parser}).?;
    expect(twice.says("parser is dead, cannot consume"));
    parser_core.parserDeinit(&parser);

    parser_core.parserInit(&parser);
    try consume(&parser, "\"\\q");
    expect(statusOf(&parser) == constants.JANET_PARSE_ERROR);

    const unread = harness.raised(parser_core.consumeChecked, .{ &parser, ' ' }).?;
    expect(unread.says("parser has unchecked error, cannot consume"));

    // Reading the error is what makes the parser usable again.
    expect(errorIs(&parser, "invalid string escape sequence"));
    try consume(&parser, "7 ");
    expect(harness.integerIs(parser_core.parserProduce(&parser), 7));
    parser_core.parserDeinit(&parser);
}

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
}

pub fn run() void {
    harness.init();
    body() catch @panic("parser_core: a kernel raised unexpectedly");
    vm_lifecycle.deinit();
}
