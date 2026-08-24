//! Behavioral contract for the incremental parser.
//!
//! Janet's parser is a byte-at-a-time state machine with a public C entry
//! point, and the suites reach it only through `parse` and the REPL — which
//! feed it whole strings and read whole values. What they cannot see is the
//! machine between bytes: the state stack growing, a clone diverging from its
//! original, an error being *read* and thereby cleared, a partial string
//! sitting in `buf`. Those are the states this file drives directly.
//!
//! ## What the migration adds
//!
//! Two refusals the C contract could not reach at all.
//!
//! `janet_parser_consume` and `janet_parser_eof` are faces over
//! `consumeChecked` and `eofChecked`, which panic on a parser that has already
//! finished or is holding an unread error. From C those are a jump with
//! nowhere to go — the C contract simply never fed a dead parser, so the two
//! messages had no test. Here each is one line, because `consumeChecked` is an
//! ordinary import and its refusal is a value.
//!
//! This is why the contract calls the *checked* pair rather than the exported
//! faces. `janet_parser_consume` is still the public entry point and still has
//! callers — `janet.h` documents it and the fuzzers use it — so nothing dies
//! here; what changes is that the contract can now see both halves of it.
//!
//! ## The error field is read once
//!
//! `janet_parser_error` clears what it returns and flushes the parser, which
//! is why the "unexpected closing delimiter" case asserts `JANET_PARSE_ROOT`
//! immediately afterwards. A second read answers null. That is deliberate C
//! behaviour and the reason `consumeChecked` has a second refusal: a parser
//! whose error has *not* been read cannot be fed.

const std = @import("std");
const abi = @import("abi");
const c = abi.c;
const harness = @import("harness.zig");
const parser_core = @import("subsystems").parser_core;

/// `parser_core.zig` declares this `export fn`, so it has a symbol but no
/// namespace entry, and `janet.h` does not carry it either — `parser/clone`
/// is the only thing that reaches it and it does so from inside the
/// subsystem. The C contract hand-declared it for the same reason.
extern fn janet_parser_clone(source: *const c.JanetParser, destination: *c.JanetParser) void;

/// Feed a whole string, one byte at a time, the way the public entry point is
/// documented to be used.
fn consume(parser: *c.JanetParser, source: []const u8) !void {
    for (source) |character| try parser_core.consumeChecked(parser, character);
}

fn statusOf(parser: *c.JanetParser) c.JanetParserStatus {
    return c.janet_parser_status(parser);
}

fn hasMore(parser: *c.JanetParser) bool {
    return c.janet_parser_has_more(parser) != 0;
}

fn errorOf(parser: *c.JanetParser) ?[*:0]const u8 {
    const message = c.janet_parser_error(parser);
    return if (message == null) null else @ptrCast(message);
}

fn errorIs(parser: *c.JanetParser, expected: []const u8) bool {
    const message = errorOf(parser) orelse return false;
    return std.mem.eql(u8, std.mem.span(message), expected);
}

/// A parser that has just been initialised, and the two counters that describe
/// its stack. `statecap` is 2 rather than 1 because the root state is pushed
/// into a freshly grown allocation.
fn theFreshParser() !void {
    var parser: c.JanetParser = undefined;
    c.janet_parser_init(&parser);
    defer c.janet_parser_deinit(&parser);

    std.debug.assert(statusOf(&parser) == c.JANET_PARSE_ROOT);
    std.debug.assert(parser.line == 1 and parser.column == 0);
    std.debug.assert(parser.statecount == 1 and parser.statecap == 2);
    std.debug.assert(parser.states[0].argn == 0);
    std.debug.assert(!hasMore(&parser));
}

/// A clone owns its own `args` and `states`, so producing from one does not
/// consume the other's pending values.
fn aCloneOwnsItsOwnQueue() !void {
    var parser: c.JanetParser = undefined;
    var clone: c.JanetParser = undefined;
    c.janet_parser_init(&parser);

    try consume(&parser, "1 2");
    try parser_core.eofChecked(&parser);
    std.debug.assert(statusOf(&parser) == c.JANET_PARSE_DEAD);
    std.debug.assert(hasMore(&parser));
    std.debug.assert(parser.pending == 2);

    janet_parser_clone(&parser, &clone);
    std.debug.assert(clone.pending == parser.pending);
    std.debug.assert(clone.args != parser.args);
    std.debug.assert(clone.states != parser.states);

    std.debug.assert(harness.integerIs(c.janet_parser_produce(&parser), 1));
    std.debug.assert(harness.integerIs(c.janet_parser_produce(&parser), 2));
    std.debug.assert(!hasMore(&parser));

    // The clone still has both, and `produce_wrapped` answers the one-element
    // tuple the parser stores rather than the value inside it — which is where
    // the source mapping lives.
    const wrapped = c.janet_parser_produce_wrapped(&clone);
    std.debug.assert(harness.isType(wrapped, c.JANET_TUPLE));
    const tuple = c.janet_unwrap_tuple(wrapped);
    std.debug.assert(c.janet_tuple_length(tuple) == 1);
    std.debug.assert(harness.integerIs(tuple[0], 1));
    std.debug.assert(c.janet_tuple_sm_line(tuple) == 1);
    std.debug.assert(harness.integerIs(c.janet_parser_produce(&clone), 2));
    std.debug.assert(!hasMore(&clone));

    c.janet_parser_deinit(&clone);
    c.janet_parser_deinit(&parser);
}

/// The four string escapes that are not one byte each: a named escape, a hex
/// pair, and the two Unicode forms, which are encoded as UTF-8.
fn theStringEscapes() !void {
    var parser: c.JanetParser = undefined;
    c.janet_parser_init(&parser);
    defer c.janet_parser_deinit(&parser);

    try consume(&parser, "\"a\\n\\x42\\u03bb\\U01f600\" ");
    const value = c.janet_parser_produce(&parser);
    std.debug.assert(harness.isType(value, c.JANET_STRING));

    const expected = [_]u8{ 'a', '\n', 'B', 0xCE, 0xBB, 0xF0, 0x9F, 0x98, 0x80 };
    const string = c.janet_unwrap_string(value);
    std.debug.assert(c.janet_string_length(string) == expected.len);
    std.debug.assert(std.mem.eql(u8, string[0..expected.len], &expected));
}

/// The other two literal forms that carry their own delimiters.
fn theOtherLiterals() !void {
    var parser: c.JanetParser = undefined;

    c.janet_parser_init(&parser);
    try consume(&parser, "`hello` ");
    std.debug.assert(harness.stringValueIs(c.janet_parser_produce(&parser), "hello"));
    c.janet_parser_deinit(&parser);

    c.janet_parser_init(&parser);
    try consume(&parser, "@\"abc\" ");
    const value = c.janet_parser_produce(&parser);
    std.debug.assert(harness.isType(value, c.JANET_BUFFER));
    const buffer = c.janet_unwrap_buffer(value);
    std.debug.assert(buffer.*.count == 3);
    std.debug.assert(std.mem.eql(u8, buffer.*.data[0..3], "abc"));
    c.janet_parser_deinit(&parser);
}

/// A clone taken mid-token owns its own `buf`, so the two can be finished
/// differently.
fn aCloneOwnsItsOwnBuffer() !void {
    var parser: c.JanetParser = undefined;
    var clone: c.JanetParser = undefined;

    c.janet_parser_init(&parser);
    try consume(&parser, "\"abc");
    std.debug.assert(parser.bufcount == 3);

    janet_parser_clone(&parser, &clone);
    std.debug.assert(clone.bufcount == 3);
    std.debug.assert(clone.buf != parser.buf);
    std.debug.assert(std.mem.eql(u8, clone.buf[0..3], parser.buf[0..3]));

    try consume(&parser, "\"");
    try consume(&clone, "d\"");
    std.debug.assert(harness.stringValueIs(c.janet_parser_produce(&parser), "abc"));
    std.debug.assert(harness.stringValueIs(c.janet_parser_produce(&clone), "abcd"));

    c.janet_parser_deinit(&clone);
    c.janet_parser_deinit(&parser);
}

/// The state stack grows past its initial two entries, and nesting unwinds in
/// the order it was built.
fn theStateStackGrows() !void {
    var parser: c.JanetParser = undefined;
    c.janet_parser_init(&parser);
    defer c.janet_parser_deinit(&parser);

    try consume(&parser, "((((1)))) ");
    std.debug.assert(parser.statecap > 2);

    var value = c.janet_parser_produce(&parser);
    for (0..4) |_| {
        std.debug.assert(harness.isType(value, c.JANET_TUPLE));
        value = c.janet_unwrap_tuple(value)[0];
    }
    std.debug.assert(harness.integerIs(value, 1));
}

/// `'x` is rewritten to `(quote x)` by the parser rather than by a macro, and
/// the tuple it builds carries the source mapping.
fn theQuoteShorthand() !void {
    var parser: c.JanetParser = undefined;
    c.janet_parser_init(&parser);
    defer c.janet_parser_deinit(&parser);

    try consume(&parser, "'x ");
    const value = c.janet_parser_produce(&parser);
    std.debug.assert(harness.isType(value, c.JANET_TUPLE));
    const tuple = c.janet_unwrap_tuple(value);
    std.debug.assert(c.janet_tuple_length(tuple) == 2);
    std.debug.assert(harness.symbolIs(tuple[0], "quote"));
    std.debug.assert(harness.symbolIs(tuple[1], "x"));
    std.debug.assert(c.janet_tuple_sm_line(tuple) == 1);
}

/// `flush` abandons whatever is half-parsed and returns the machine to root.
fn theFlush() !void {
    var parser: c.JanetParser = undefined;
    c.janet_parser_init(&parser);
    defer c.janet_parser_deinit(&parser);

    try consume(&parser, "(");
    std.debug.assert(statusOf(&parser) == c.JANET_PARSE_PENDING);
    c.janet_parser_flush(&parser);
    std.debug.assert(statusOf(&parser) == c.JANET_PARSE_ROOT);
}

/// The five parse errors, and the one property that makes reading one an
/// action rather than an inspection.
fn theParseErrors() !void {
    var parser: c.JanetParser = undefined;

    c.janet_parser_init(&parser);
    try consume(&parser, "\"\\q");
    std.debug.assert(statusOf(&parser) == c.JANET_PARSE_ERROR);
    std.debug.assert(errorIs(&parser, "invalid string escape sequence"));
    c.janet_parser_deinit(&parser);

    // Reading the error clears it and flushes the parser, so the status goes
    // back to root and a second read answers nothing. The message names where
    // the unclosed form opened, so it is matched by prefix rather than whole.
    c.janet_parser_init(&parser);
    try consume(&parser, ")");
    std.debug.assert(statusOf(&parser) == c.JANET_PARSE_ERROR);
    const message = errorOf(&parser) orelse unreachable;
    std.debug.assert(std.mem.indexOf(u8, std.mem.span(message), "unexpected closing delimiter") != null);
    std.debug.assert(statusOf(&parser) == c.JANET_PARSE_ROOT);
    std.debug.assert(errorOf(&parser) == null);
    c.janet_parser_deinit(&parser);

    c.janet_parser_init(&parser);
    try consume(&parser, "12abc ");
    std.debug.assert(statusOf(&parser) == c.JANET_PARSE_ERROR);
    std.debug.assert(errorIs(&parser, "symbol literal cannot start with a digit"));
    c.janet_parser_deinit(&parser);

    // A lone continuation byte is invalid UTF-8, and the message names which
    // of the two token kinds was being read.
    c.janet_parser_init(&parser);
    try parser_core.consumeChecked(&parser, 0xC2);
    try parser_core.consumeChecked(&parser, ' ');
    std.debug.assert(statusOf(&parser) == c.JANET_PARSE_ERROR);
    std.debug.assert(errorIs(&parser, "invalid utf-8 in symbol"));
    c.janet_parser_deinit(&parser);

    c.janet_parser_init(&parser);
    try parser_core.consumeChecked(&parser, ':');
    try parser_core.consumeChecked(&parser, 0xC2);
    try parser_core.consumeChecked(&parser, ' ');
    std.debug.assert(statusOf(&parser) == c.JANET_PARSE_ERROR);
    std.debug.assert(errorIs(&parser, "invalid utf-8 in keyword"));
    c.janet_parser_deinit(&parser);
}

/// The five atoms the root state recognises without a delimiter.
fn theAtoms() !void {
    var parser: c.JanetParser = undefined;
    c.janet_parser_init(&parser);
    defer c.janet_parser_deinit(&parser);

    try consume(&parser, ":key nil false true symbol ");
    std.debug.assert(harness.keywordIs(c.janet_parser_produce(&parser), "key"));
    std.debug.assert(harness.isType(c.janet_parser_produce(&parser), c.JANET_NIL));

    const false_value = c.janet_parser_produce(&parser);
    std.debug.assert(harness.isType(false_value, c.JANET_BOOLEAN));
    std.debug.assert(c.janet_unwrap_boolean(false_value) == 0);

    const true_value = c.janet_parser_produce(&parser);
    std.debug.assert(harness.isType(true_value, c.JANET_BOOLEAN));
    std.debug.assert(c.janet_unwrap_boolean(true_value) != 0);

    std.debug.assert(harness.symbolIs(c.janet_parser_produce(&parser), "symbol"));
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
    var parser: c.JanetParser = undefined;

    c.janet_parser_init(&parser);
    try consume(&parser, "1");
    try parser_core.eofChecked(&parser);
    std.debug.assert(statusOf(&parser) == c.JANET_PARSE_DEAD);

    const fed = harness.raised(parser_core.consumeChecked, .{ &parser, ' ' }).?;
    std.debug.assert(fed.says("parser is dead, cannot consume"));

    // `eof` refuses for the same reason, which matters because it is the one a
    // REPL reaches by pressing return twice.
    const twice = harness.raised(parser_core.eofChecked, .{&parser}).?;
    std.debug.assert(twice.says("parser is dead, cannot consume"));
    c.janet_parser_deinit(&parser);

    c.janet_parser_init(&parser);
    try consume(&parser, "\"\\q");
    std.debug.assert(statusOf(&parser) == c.JANET_PARSE_ERROR);

    const unread = harness.raised(parser_core.consumeChecked, .{ &parser, ' ' }).?;
    std.debug.assert(unread.says("parser has unchecked error, cannot consume"));

    // Reading the error is what makes the parser usable again.
    std.debug.assert(errorIs(&parser, "invalid string escape sequence"));
    try consume(&parser, "7 ");
    std.debug.assert(harness.integerIs(c.janet_parser_produce(&parser), 7));
    c.janet_parser_deinit(&parser);
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
    _ = c.janet_init();
    body() catch @panic("parser_core: a kernel raised unexpectedly");
    c.janet_deinit();
}
