//! Janet's reader: a state machine that takes one byte at a time and queues
//! whole values, plus the abstract type that gives Janet `parser/*`.
//!
//! Two kinds of failure are decided here, by this engine rather than by a
//! caller ahead of it. A parse error is data: it goes into the parser's
//! `error` field, `parser/status` reports `:error`, and the caller decides
//! what to do. Feeding bytes to a parser that has already finished, or to a
//! parser still sitting on an unread error, is a panic, because there is no
//! value to report with.
//!
//! The two panics say different things and reaching the second takes care: a
//! delimiter error sets the dead flag as well as the message, so it reports
//! "parser is dead". "parser has unchecked error" needs an error that
//! `delimError` did not raise, and needs it left unread, because
//! `parser/error` clears it.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abstract_type = @import("../api/abstract_type.zig");
const abstracts = @import("value/abstracts.zig");
const args_core = @import("args.zig");
const arrays = @import("value/arrays.zig");
const buffers = @import("value/buffers.zig");
const config = @import("config");
const corefn = @import("corefn.zig");
const fatal = @import("fatal.zig");
const gc_mark = @import("gc/mark.zig");
const maps = @import("value/maps.zig");
const method_type = @import("method_type.zig");
const lexicon = @import("lexicon");
const numscan = @import("scan.zig");
const pp_describe = @import("pp.zig");
const pp_format = @import("pp/format.zig");
const raise = @import("../api/raise.zig");
const repr = @import("repr");
const strings = @import("value/strings.zig");
const symbols = @import("value/symbols.zig");
const tables = @import("value/tables.zig");
const tuples = @import("value/tuples.zig");
const utils = @import("utils.zig");
const value = @import("value.zig");
const vectors = @import("value/vectors.zig");
const wrap = @import("value/helpers/wrap.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// The methods reached through `(p :consume)` and its siblings.
///
/// Lexicographic order, which is not a lookup requirement: `findMethod` scans
/// linearly. It is the iteration order, because `nextmethod` walks the same
/// table, so `(keys p)` and `next` report the methods in the order they are
/// written here.
const methods = [_]method_type.Method{
    .{ .name = "byte", .nfun = nfunParserByte },
    .{ .name = "clone", .nfun = nfunParserClone },
    .{ .name = "consume", .nfun = nfunParserConsume },
    .{ .name = "eof", .nfun = nfunParserEof },
    .{ .name = "error", .nfun = nfunParserError },
    .{ .name = "flush", .nfun = nfunParserFlush },
    .{ .name = "has-more", .nfun = nfunParserHasMore },
    .{ .name = "insert", .nfun = nfunParserInsert },
    .{ .name = "produce", .nfun = nfunParserProduce },
    .{ .name = "state", .nfun = nfunParserState },
    .{ .name = "status", .nfun = nfunParserStatus },
    .{ .name = "where", .nfun = nfunParserWhere },
    .{ .name = null, .nfun = null },
};

/// The abstract type `parser/new` allocates, and what `getParser` checks an
/// argument against.
pub const parserType = abstract_type.define(Parser, .{
    .name = "core/parser",
    .gc = parserGC,
    .gcmark = parserMark,
    .get = parserGet,
    .next = parserNext,
});

/// The two keys `(parser/state p key)` accepts, and the order a call with no
/// key reports them in.
const state_getters = [_]StateGetter{
    .{ .name = "frames", .get = parserStateFrames },
    .{ .name = "delimiters", .get = parserStateDelimiters },
};

// ==========================================================================
// Types
// ==========================================================================

/// A parse state's consumer: given a character, whether it consumed it.
///
/// Not optional and not `callconv(.c)`. Every state is pushed with a consumer,
/// since `parserPushState` takes it as a parameter, so nothing has to unwrap
/// it, and nothing outside this tree implements a consumer.
///
/// It raises. Three consumers finish a string or close a delimiter, either of
/// which can raise, and a `callconv(.c)` slot has no room for the error union
/// that reports it. The error set is spelled out rather than imported, so that
/// this declaration needs nothing above `repr` in the module graph.
pub const Consumer = *const fn (p: *Parser, state: *ParseState, c: u8) error{Signal}!bool;

/// One frame of the state stack: the consumer reading this form, where the
/// form opened, and two counters whose meaning is the consumer's. A container
/// counts its elements in `argn`, a long string counts its opening backticks
/// there, and an escape accumulates the digits it has read.
pub const ParseState = struct {
    counter: i32 = 0,
    argn: i32 = 0,
    flags: ParseStateFlags = .{},
    line: usize = 0,
    column: usize = 0,
    /// Every state is pushed with one; there is no default because there is no
    /// such thing as a state with no consumer.
    consumer: Consumer,
};

/// One parser state's flags.
///
/// The low byte is not a flag word: when `reader_macro` is set it is the
/// macro's character, which `parserPopState` reads back to rebuild the form,
/// so it is a field of its own rather than eight bools.
pub const ParseStateFlags = packed struct(c_int) {
    /// The reader-macro character, when `reader_macro` is set.
    macro_char: u8 = 0,
    container: bool = false,
    buffer: bool = false,
    parens: bool = false,
    square_brackets: bool = false,
    curly_brackets: bool = false,
    string: bool = false,
    long_string: bool = false,
    reader_macro: bool = false,
    at_symbol: bool = false,
    comment: bool = false,
    token: bool = false,
    /// A `[ ]` container that closes to a vector, which is Wattle's. Janet's
    /// `[ ]` closes to a bracketed tuple and leaves this clear.
    vector: bool = false,
    /// Wattle's `#`, waiting for the character that says what it opens.
    dispatch: bool = false,
    /// A `#{ }` container, which closes to a set. The curly brackets alone
    /// would close to a map.
    set: bool = false,
    in_string: bool = false,
    end_candidate: bool = false,
    _reserved24: u8 = 0,
};

/// A parser: the queue of finished values, the stack of states, the scratch
/// buffer the token or string in progress accumulates in, and where in the
/// source the reader has got to.
pub const Parser = struct {
    args: std.ArrayListUnmanaged(repr.Value) = .empty,
    @"error": ?[*:0]const u8 = null,
    states: std.ArrayListUnmanaged(ParseState) = .empty,
    buf: std.ArrayListUnmanaged(u8) = .empty,
    line: usize = 0,
    column: usize = 0,
    pending: usize = 0,
    lookback: c_int = 0,
    /// Dead once a consume raised, and `generated_error` while an error the
    /// parser produced itself is still unread. `parserStatus` reads the two
    /// as one question: either sets `:dead`.
    dead: bool = false,
    generated_error: bool = false,
};

/// What `parser/status` reports, and the whole of what a parser can be in.
/// A Janet program sees the keyword rather than the number, and the keyword is
/// what the suites pin; the numbers are C's and are kept.
pub const ParserStatus = enum(u32) {
    root = 0,
    @"error" = 1,
    pending = 2,
    dead = 3,
};

/// One `(parser/state p key)` key, and the function behind it.
const StateGetter = struct {
    name: [:0]const u8,
    get: *const fn (*Parser) raise.Error!repr.Value,
};

// ==========================================================================
// Public functions
// ==========================================================================

/// `parserConsume` behind `checkDead`, which is what every caller from Janet
/// reaches.
pub fn consumeChecked(parser: *Parser, character: u8) raise.Error!void {
    try checkDead(parser);
    try parserConsume(parser, character);
}

/// `parserEof` behind `checkDead`.
pub fn eofChecked(parser: *Parser) raise.Error!void {
    try checkDead(parser);
    try parserEof(parser);
}

/// Registers the `parser/*` nfunctions.
pub fn libParse(env: *tables.Table) void {
    const entries = comptime [_]corefn.Entry{
        corefn.reg("parser/new", &nfunParserNew, @src(), "(parser/new)", "Creates and returns a new parser object. Parsers are state machines " ++
            "that can receive bytes and generate a stream of values."),
        corefn.reg("parser/clone", &nfunParserClone, @src(), "(parser/clone p)", "Creates a deep clone of a parser that is identical to the input parser. " ++
            "This cloned parser can be used to continue parsing from a good checkpoint " ++
            "if parsing later fails. Returns a new parser."),
        corefn.reg("parser/has-more", &nfunParserHasMore, @src(), "(parser/has-more parser)", "Checks whether the parser has more values in the value queue."),
        corefn.reg("parser/produce", &nfunParserProduce, @src(), "(parser/produce parser [wrap])", "Dequeues the next value in the parse queue. Will return nil if " ++
            "no parsed values are in the queue, otherwise will dequeue the " ++
            "next value. If wrap is truthy, will return a 1-element tuple that " ++
            "wraps the result. This tuple can be used for source-mapping " ++
            "purposes."),
        corefn.reg("parser/consume", &nfunParserConsume, @src(), "(parser/consume parser bytes [index])", "Inputs bytes into the parser and parses them. Will not throw errors " ++
            "if there is a parse error. Starts at the byte index given by index. Returns " ++
            "the number of bytes read."),
        corefn.reg("parser/byte", &nfunParserByte, @src(), "(parser/byte parser b)", "Inputs a single byte b into the parser byte stream. Returns the parser."),
        corefn.reg("parser/error", &nfunParserError, @src(), "(parser/error parser)", "If the parser is in the error state, returns the message associated with " ++
            "that error. Otherwise, returns nil. Also flushes the parser state and parser " ++
            "queue, so be sure to handle everything in the queue before calling " ++
            "^parser/error."),
        corefn.reg("parser/status", &nfunParserStatus, @src(), "(parser/status parser)", "Gets the current status of the parser state machine. The status will " ++
            "be one of:\n\n" ++
            "* :pending - a value is being parsed.\n\n" ++
            "* :error - a parsing error was encountered.\n\n" ++
            "* :root - the parser can either read more values or safely terminate."),
        corefn.reg("parser/flush", &nfunParserFlush, @src(), "(parser/flush parser)", "Clears the parser state and parse queue. Can be used to reset the parser " ++
            "if an error was encountered. Does not reset the line and column counter, so " ++
            "to begin parsing in a new context, create a new parser."),
        corefn.reg("parser/state", &nfunParserState, @src(), "(parser/state parser [key])", "Returns a representation of the internal state of the parser. If a key is passed, " ++
            "only that information about the state is returned. Allowed keys are:\n\n" ++
            "* :delimiters - Each byte in the string represents a nested data structure. For example, " ++
            "if the parser state is '([\"', then the parser is in the middle of parsing a " ++
            "string inside of square brackets inside parentheses. Can be used to augment a REPL prompt.\n\n" ++
            "* :frames - Each table in the array represents a 'frame' in the parser state. Frames " ++
            "contain information about the start of the expression being parsed as well as the " ++
            "type of that expression and some type-specific information."),
        corefn.reg("parser/where", &nfunParserWhere, @src(), "(parser/where parser [line [col]])", "Returns the current line number and column of the parser's internal state. If line is " ++
            "provided, the current line number of the parser is first set to that value. If column is " ++
            "also provided, the current column number of the parser is also first set to that value."),
        corefn.reg("parser/eof", &nfunParserEof, @src(), "(parser/eof parser)", "Indicates to the parser that the end of file was reached. This puts the parser in the :dead state."),
        corefn.reg("parser/insert", &nfunParserInsert, @src(), "(parser/insert parser value)", "Inserts a value into the parser. This means that the parser state can be manipulated " ++
            "in between chunks of bytes. This would allow a user to add extra elements to arrays " ++
            "and tuples, for example. Returns the parser."),
    };
    corefn.install(env, entries);
}

/// Copies `source` into `destination`: queue, stack, buffer and position
/// alike.
pub fn parserClone(source: *const Parser, destination: *Parser) void {
    destination.* = .{
        .args = .empty,
        .@"error" = source.@"error",
        .states = .empty,
        .buf = .empty,
        .line = source.line,
        .column = source.column,
        .pending = source.pending,
        .lookback = source.lookback,
        .dead = source.dead,
        .generated_error = source.generated_error,
    };
    // Count-many, not capacity-many: each of the three allocations is sized to
    // the count it then copies, so a clone has none of the source's spare
    // room. `Precise` is what says so.
    destination.buf.ensureTotalCapacityPrecise(utils.heap, source.buf.items.len) catch fatal.outOfMemory();
    destination.buf.appendSliceAssumeCapacity(source.buf.items);
    destination.args.ensureTotalCapacityPrecise(utils.heap, source.args.items.len) catch fatal.outOfMemory();
    destination.args.appendSliceAssumeCapacity(source.args.items);
    destination.states.ensureTotalCapacityPrecise(utils.heap, source.states.items.len) catch fatal.outOfMemory();
    destination.states.appendSliceAssumeCapacity(source.states.items);
}

/// Takes `state.argn` values off the queue into an array.
pub fn parserCloseArray(
    parser: *Parser,
    state: *ParseState,
) repr.Value {
    const array = arrays.new(@intCast(state.argn));
    var index = state.argn;
    while (index > 0) {
        index -= 1;
        array.reserved()[@intCast(index)] = parser.args.pop().?;
    }
    array.count = @intCast(state.argn);
    return wrap.fromArray(array);
}

/// The refusal a map or set literal earns, or null where every element may be
/// stored.
///
/// Neither holds a nil or a NaN, so `{nil 1}` and `#{nil}` are refused where
/// they are written rather than read as a collection that cannot be iterated.
/// A table takes both and drops the pair, which is why a table does not ask.
/// `stride` is 2 for a map, whose keys are every other value on the queue, and
/// 1 for a set, whose elements are all of them.
fn unstorableElementIn(parser: *Parser, state: *ParseState, stride: usize) ?[*:0]const u8 {
    const start = parser.args.items.len - @as(usize, @intCast(state.argn));
    var index = start;
    while (index < parser.args.items.len) : (index += stride) {
        const key = parser.args.items[index];
        if (maps.storableKey(key)) continue;
        return if (repr.checkType(key, repr.Tag.nil))
            "cannot use nil as a key"
        else
            "cannot use nan as a key";
    }
    return null;
}

/// Takes `state.argn` values off the queue into a vector, which is what
/// Wattle's `[ ]` closes to.
pub fn parserCloseVector(
    parser: *Parser,
    state: *ParseState,
) repr.Value {
    const count: usize = @intCast(state.argn);
    const start = parser.args.items.len - count;
    const built = vectors.fromSlice(parser.args.items[start..]);
    parser.args.shrinkRetainingCapacity(start);
    return wrap.fromVector(built);
}

/// Takes `state.argn` values off the queue into a set, which is what `#{ }`
/// closes to.
pub fn parserCloseSet(
    parser: *Parser,
    state: *ParseState,
) repr.Value {
    const start = parser.args.items.len - @as(usize, @intCast(state.argn));
    const built = maps.build(.set, parser.args.items[start..]);
    parser.args.shrinkRetainingCapacity(start);
    return wrap.fromAbstract(built);
}

/// Takes `state.argn` values off the queue as alternating keys and values,
/// into a map.
pub fn parserCloseMap(
    parser: *Parser,
    state: *ParseState,
) repr.Value {
    const start = parser.args.items.len - @as(usize, @intCast(state.argn));
    const built = maps.build(.map, parser.args.items[start..]);
    parser.args.shrinkRetainingCapacity(start);
    return wrap.fromMap(built);
}

/// `parserCloseMap` into a table.
pub fn parserCloseTable(
    parser: *Parser,
    state: *ParseState,
) repr.Value {
    const table = tables.new(@intCast(@divTrunc(state.argn, 2)));
    const start = parser.args.items.len - @as(usize, @intCast(state.argn));
    var index = start;
    while (index < parser.args.items.len) : (index += 2) {
        tables.put(table, parser.args.items[index], parser.args.items[index + 1]);
    }
    parser.args.shrinkRetainingCapacity(start);
    return wrap.fromTable(table);
}

/// Takes `state.argn` values off the queue into a tuple.
pub fn parserCloseTuple(
    parser: *Parser,
    state: *ParseState,
) repr.Value {
    const tuple = tuples.begin(@intCast(state.argn));
    var index = state.argn;
    while (index > 0) {
        index -= 1;
        tuple[@intCast(index)] = parser.args.pop().?;
    }
    return wrap.fromTuple(tuples.end(tuple));
}

/// Feeds one byte to the parser, running the top consumer until the byte is
/// consumed or an error stops it.
///
/// Line and column are advanced here, with a `\r\n` counted as one break. The
/// dead and unread-error checks are `consumeChecked`'s rather than this
/// function's.
pub fn parserConsume(parser: *Parser, character: u8) raise.Error!void {
    if (character == '\r') {
        parser.line += 1;
        parser.column = 0;
    } else if (character == '\n') {
        parser.column = 0;
        if (parser.lookback != '\r') parser.line += 1;
    } else {
        parser.column += 1;
    }

    var consumed = false;
    while (!consumed and parser.@"error" == null) {
        const state = &parser.states.items[parser.states.items.len - 1];
        consumed = try state.consumer(parser, state, character);
    }
    parser.lookback = character;
}

/// Frees the three lists, leaving them empty rather than `undefined`.
pub fn parserDeinit(parser: *Parser) void {
    parser.args.deinit(utils.heap);
    parser.buf.deinit(utils.heap);
    parser.states.deinit(utils.heap);
    // `ArrayListUnmanaged.deinit` ends `self.* = undefined`; see
    // `gc.rootsDeinit`. A parser left in that state would read a freed pointer
    // at its next use, through a capacity that still looks live.
    parser.args = .empty;
    parser.buf = .empty;
    parser.states = .empty;
}

/// Takes the error message, clearing it and flushing the parser, or nothing
/// where there is no unread error.
pub fn parserError(parser: *Parser) ?[*:0]const u8 {
    if (parserStatus(parser) != .@"error") return null;
    const message = parser.@"error";
    parser.@"error" = null;
    parser.generated_error = false;
    parserFlush(parser);
    return message;
}

/// Clears the queue, the scratch buffer and every state above the root. The
/// line and column are left where they were.
pub fn parserFlush(parser: *Parser) void {
    parser.args.clearRetainingCapacity();
    parser.states.shrinkRetainingCapacity(1);
    parser.buf.clearRetainingCapacity();
    parser.pending = 0;
}

/// Whether a finished value is waiting in the queue.
pub fn parserHasMore(parser: *Parser) bool {
    return parser.pending != 0;
}

/// Starts a parser at line 1, column 0, with the root state on the stack.
pub fn parserInit(parser: *Parser) void {
    parser.* = .{
        .args = .empty,
        .@"error" = null,
        .states = .empty,
        .buf = .empty,
        .line = 1,
        .column = 0,
        .pending = 0,
        .lookback = -1,
    };
    // `Precise` because a fresh parser has just the root state, and the second
    // slot is room for one push before the first grow.
    parser.states.ensureTotalCapacityPrecise(utils.heap, 2) catch fatal.outOfMemory();
    parser.states.appendAssumeCapacity(.{
        .counter = 0,
        .argn = 0,
        .flags = .{ .container = true },
        .line = parser.line,
        .column = parser.column,
        .consumer = wattleRoot,
    });
}

/// Finishes the top state with `original_value`, recording the source map and
/// handing the value to whatever is underneath.
///
/// A container takes it as an element. A reader macro wraps it and the loop
/// runs again, so `~',x` unwinds in a single call. At the root the value is
/// wrapped in a one-element tuple, which is what `parserProduce` unwraps and
/// what `parserProduceWrapped` returns as it stands.
pub fn parserPopState(parser: *Parser, original_value: repr.Value) void {
    var val = original_value;
    while (true) {
        const top = parser.states.pop().?;
        const new_top = &parser.states.items[parser.states.items.len - 1];
        val = setSource(val, top.line, top.column);
        if (new_top.flags.container) {
            new_top.argn += 1;
            if (parser.states.items.len == 1) {
                parser.pending += 1;
                val = wrapRoot(val, top.line, top.column);
            }
            parserPushArg(parser, val);
            return;
        }
        if (new_top.flags.reader_macro) {
            val = wrapReader(
                val,
                new_top.flags.macro_char,
                new_top.line,
                new_top.column,
            );
        } else {
            return;
        }
    }
}

/// Dequeues the next value, or nil where the queue is empty.
pub fn parserProduce(parser: *Parser) repr.Value {
    if (parser.pending == 0) return wrap.fromNil();
    const result = wrap.toTuple(parser.args.items[0])[0];
    shiftArguments(parser);
    return result;
}

/// Dequeues the next value in the one-element tuple it is queued in, which is
/// where its source map is recorded.
pub fn parserProduceWrapped(parser: *Parser) repr.Value {
    if (parser.pending == 0) return wrap.fromNil();
    const result = parser.args.items[0];
    shiftArguments(parser);
    return result;
}

/// Appends a finished value to the queue.
pub fn parserPushArg(parser: *Parser, val: repr.Value) void {
    parser.args.append(utils.heap, val) catch fatal.outOfMemory();
}

/// Appends one byte to the scratch buffer the token or string in progress
/// accumulates in.
pub fn parserPushBuf(parser: *Parser, val: u8) void {
    parser.buf.append(utils.heap, val) catch fatal.outOfMemory();
}

/// Pushes a state onto the stack, recording where the form opened.
pub fn parserPushState(
    parser: *Parser,
    consumer: Consumer,
    flags: ParseStateFlags,
) void {
    parser.states.append(utils.heap, .{
        .counter = 0,
        .argn = 0,
        .flags = flags,
        .line = parser.line,
        .column = parser.column,
        .consumer = consumer,
    }) catch fatal.outOfMemory();
}

/// Wattle's consumer between forms.
///
/// The shape Janet's root consumer had, with Wattle's characters: `;` comments where
/// `#` did, `#` dispatches, `` ` `` quasiquotes where it opened a long string,
/// `~` unquotes where it quasiquoted, `|` splices where it made a short
/// function, `!` opens a mutable container where `@` did, and `,` is
/// whitespace. `@` and `^` are refused rather than read as a symbol.
pub fn wattleRoot(
    parser: *Parser,
    state: *ParseState,
    character: u8,
) raise.Error!bool {
    // A prefix and its form are one unit, and the newline is what ends the
    // line rather than what ends the buffer, so a chunk boundary may still
    // fall between them. Without this a line ending in `'` leaves the parser
    // pending and silent, and `parser/state`'s `:delimiters` does not report a
    // pending prefix, so the next form read is taken as its argument.
    if (state.flags.reader_macro and (character == '\n' or character == '\r')) {
        try adjacencyError(parser, state);
        return true;
    }
    switch (character) {
        '\'', '`', '~', '|' => {
            parserPushState(parser, wattleRoot, .{ .reader_macro = true, .macro_char = character });
            return true;
        },
        '"' => {
            parserPushState(parser, wattleQuoteRun, .{ .string = true });
            return true;
        },
        ';' => {
            parserPushState(parser, wattleComment, .{ .comment = true });
            return true;
        },
        '#' => {
            parserPushState(parser, wattleDispatch, .{ .dispatch = true });
            return true;
        },
        '!' => {
            parserPushState(parser, wattleBang, .{ .at_symbol = true });
            return true;
        },
        // Held free for a reader meaning not yet chosen. Inside a symbol each
        // is an ordinary character, which `parserTokenchar` decides; only a
        // form beginning with one reaches here.
        '@' => {
            parser.@"error" = "@ is reserved";
            return true;
        },
        '^' => {
            parser.@"error" = "^ is reserved";
            return true;
        },
        ')', ']', '}' => return closeDelimiter(parser, state, character),
        '(' => {
            parserPushState(parser, wattleRoot, .{ .container = true, .parens = true });
            return true;
        },
        '[' => {
            parserPushState(parser, wattleRoot, .{ .container = true, .square_brackets = true, .vector = true });
            return true;
        },
        '{' => {
            parserPushState(parser, wattleRoot, .{ .container = true, .curly_brackets = true });
            return true;
        },
        else => {
            if (lexicon.isWhitespace(character)) return true;
            if (!lexicon.isSymbolChar(character)) {
                parser.@"error" = "unexpected character";
                return true;
            }
            parserPushState(parser, parserTokenchar, .{ .token = true });
            return false;
        },
    }
}

/// The comment consumer, which hands the newline or carriage return that ends
/// the comment back rather than consuming it.
///
/// A comment ends where `parserConsume` counts a new line, at a newline or a
/// carriage return, so a form after a lone carriage return is read. A comment
/// does not excuse the byte that ends it: `'; note` leaves a quote pending,
/// and the byte has to reach the quote's state for `wattleRoot` to refuse it.
/// At the root the re-fed byte is whitespace.
fn wattleComment(
    parser: *Parser,
    _: *ParseState,
    character: u8,
) raise.Error!bool {
    if (character != '\n' and character != '\r') {
        parserPushBuf(parser, character);
        return true;
    }
    _ = parser.states.pop();
    parser.buf.clearRetainingCapacity();
    return false;
}

/// Moves the top `depth` states' recorded position back to where the form
/// they belong to actually opened.
fn openedAt(parser: *Parser, depth: usize, line: usize, column: usize) void {
    const top = parser.states.items.len;
    for (top - depth..top) |index| {
        parser.states.items[index].line = line;
        parser.states.items[index].column = column;
    }
}

/// The refusal a prefix earns when its form does not begin on the same line,
/// naming the prefix and where it was written.
fn adjacencyError(parser: *Parser, state: *ParseState) raise.Error!void {
    const text = buffers.new(40);
    try buffers.pushCString(text, "expected a form on the same line as ");
    try buffers.pushU8(text, state.flags.macro_char);
    _ = try pp_format.formatb(text, ", opened at line %d, column %d", .{
        @as(i32, @intCast(state.line)),
        @as(i32, @intCast(state.column)),
    });
    parser.@"error" = @ptrCast(strings.new(text.slice()));
    parser.generated_error = true;
}

/// The consumer after a `!`: a mutable container or a buffer where the next
/// character opens one, and the first character of a symbol otherwise.
///
/// The consumer just after a `!`. Wattle has one
/// string opener and classifies it by the length of its run, so `!"` and
/// `!"""` are one state here where Janet's `@"` and `` @` `` are two.
fn wattleBang(
    parser: *Parser,
    _: *ParseState,
    character: u8,
) raise.Error!bool {
    _ = parser.states.pop();
    switch (character) {
        '{' => parserPushState(parser, wattleRoot, .{ .container = true, .curly_brackets = true, .at_symbol = true }),
        '"' => parserPushState(parser, wattleQuoteRun, .{ .buffer = true, .string = true }),
        '[' => parserPushState(parser, wattleRoot, .{ .container = true, .square_brackets = true, .at_symbol = true }),
        '(' => parserPushState(parser, wattleRoot, .{ .container = true, .parens = true, .at_symbol = true }),
        else => {
            parserPushState(parser, parserTokenchar, .{ .token = true });
            parserPushBuf(parser, '!');
            return false;
        },
    }
    return true;
}

/// The consumer after a `#`.
///
/// `#(` is a short function, `#{` a set, and `#!` at the first byte of a
/// source is the shebang. A word tag is refused by name rather than by
/// silence, because someone arriving from Clojure will write one: tagged
/// forms are designed and not built, and `notes/LANGUAGE.md` records why the
/// case for building them has gone. Anything else is not a dispatch character
/// at all.
fn wattleDispatch(
    parser: *Parser,
    state: *ParseState,
    character: u8,
) raise.Error!bool {
    // Line 1, column 1 is the first byte of the source: `parserInit`
    // starts at column 0 and `parserConsume` counts before it dispatches. A
    // chunk boundary cannot fall before byte zero, so this holds however the
    // source is fed.
    if (character == '!' and state.line == 1 and state.column == 1) {
        _ = parser.states.pop();
        parserPushState(parser, wattleComment, .{ .comment = true });
        return true;
    }
    // A dispatch form opens at its `#`, not at the delimiter after it, so an
    // error inside `#{1 2)` names column 1. `parserPushState` records where
    // the parser is now, which is the delimiter, so the two are moved back.
    const opened_line = state.line;
    const opened_column = state.column;
    _ = parser.states.pop();
    switch (character) {
        '(' => {
            parserPushState(parser, wattleRoot, .{ .reader_macro = true, .macro_char = '#' });
            parserPushState(parser, wattleRoot, .{ .container = true, .parens = true });
            openedAt(parser, 2, opened_line, opened_column);
            return true;
        },
        '{' => {
            parserPushState(parser, wattleRoot, .{ .container = true, .curly_brackets = true, .set = true });
            openedAt(parser, 1, opened_line, opened_column);
            return true;
        },
        else => {
            if (lexicon.isSymbolChar(character)) {
                parser.@"error" = "word tags are not implemented";
                return true;
            }
            parser.@"error" = "unknown dispatch";
            return true;
        },
    }
}

/// The consumer at a run of `"`, which is scanned whole before it is
/// classified.
///
/// One quote opens an ordinary string, two are the empty string, and three or
/// more open a raw string closed by a run of the same length. The run is
/// counted in `state.argn`, and
/// the character that ends the run is handed back to whichever consumer the
/// count chose.
fn wattleQuoteRun(
    parser: *Parser,
    state: *ParseState,
    character: u8,
) raise.Error!bool {
    if (character == '"') {
        state.argn += 1;
        return true;
    }
    // `argn` counts the quotes after the one that pushed this state.
    switch (state.argn) {
        0 => {
            state.consumer = wattleStringchar;
            return false;
        },
        1 => {
            state.argn = 0;
            _ = try finishString(parser, state);
            return false;
        },
        else => {
            // `string` and `long_string` are exclusive, as they are in Janet:
            // `delimError` tests `string` first, so a state carrying both
            // would name a raw string as an ordinary one. `buffer` stays.
            state.flags.string = false;
            state.flags.long_string = true;
            state.flags.in_string = true;
            state.argn += 1;
            state.consumer = wattleLongstring;
            return false;
        },
    }
}

/// The consumer inside a `"` string, which refuses a bare newline.
///
/// An ordinary string is one line: `"""` is how a string spans lines, so
/// nothing is left for the quiet behaviour to serve.
fn wattleStringchar(
    parser: *Parser,
    state: *ParseState,
    character: u8,
) raise.Error!bool {
    if (character == '\\') {
        state.consumer = parserEscape1;
    } else if (character == '"') {
        return try finishString(parser, state);
    } else if (character == '\n' or character == '\r') {
        parser.@"error" = "newline in string";
        return true;
    } else {
        parserPushBuf(parser, character);
    }
    return true;
}

/// `longstringImpl` closed by a run of `"`.
fn wattleLongstring(
    parser: *Parser,
    state: *ParseState,
    character: u8,
) raise.Error!bool {
    return longstringImpl('"', parser, state, character);
}

/// What state the parser is in.
///
/// An unread error reports `:error` whatever else is true. After that, a
/// parser that has ended, or whose error was generated here and has been read,
/// reports `:dead`; an unclosed form reports `:pending`; anything else is
/// `:root`.
pub fn parserStatus(parser: *Parser) ParserStatus {
    if (parser.@"error" != null) return .@"error";
    if (parser.dead or parser.generated_error) return .dead;
    if (parser.states.items.len > 1) return .pending;
    return .root;
}

/// The consumer of a bare token: symbol characters accumulate and anything
/// else ends it.
///
/// The finished text is a keyword where it begins with `:`, a number where it
/// scans as one, `nil`, `true` or `false` where it is that word, and a symbol
/// otherwise. A symbol may not begin with a digit, and a token with a byte
/// above 127 in it has to be valid UTF-8.
pub fn parserTokenchar(
    parser: *Parser,
    state: *ParseState,
    character: u8,
) raise.Error!bool {
    if (lexicon.isSymbolChar(character)) {
        parserPushBuf(parser, character);
        if (character > 127) state.argn = 1;
        return true;
    }

    const length: i32 = @intCast(parser.buf.items.len);
    const starts_with_digit = parser.buf.items[0] >= '0' and parser.buf.items[0] <= '9';
    const starts_with_number = starts_with_digit or
        parser.buf.items[0] == '-' or parser.buf.items[0] == '+' or parser.buf.items[0] == '.';
    var val: repr.Value = undefined;
    var parsed_number = false;

    if (parser.buf.items[0] == ':') {
        if (state.argn != 0 and !lexicon.validUtf8(parser.buf.items[1..@intCast(length)])) {
            parser.@"error" = "invalid utf-8 in keyword";
            return false;
        }
        val = wrap.fromKeyword(symbols.keyword(parser.buf.items[1..@intCast(length)]));
    } else {
        if (starts_with_number) {
            if (config.int_types) {
                if (numscan.scanNumeric(parser.buf.items[0..@intCast(length)])) |scanned| {
                    val = scanned;
                    parsed_number = true;
                }
            } else {
                if (numscan.scanNumber(parser.buf.items[0..@intCast(length)])) |number| {
                    val = wrap.fromNumber(number);
                    parsed_number = true;
                }
            }
        }

        if (!parsed_number) {
            if (tokenEquals(parser.buf.items, "nil")) {
                val = wrap.fromNil();
            } else if (tokenEquals(parser.buf.items, "false")) {
                val = wrap.fromFalse();
            } else if (tokenEquals(parser.buf.items, "true")) {
                val = wrap.fromTrue();
            } else {
                if (starts_with_digit) {
                    parser.@"error" = "symbol literal cannot start with a digit";
                    return false;
                }
                if (state.argn != 0 and !lexicon.validUtf8(parser.buf.items[0..@intCast(length)])) {
                    parser.@"error" = "invalid utf-8 in symbol";
                    return false;
                }
                val = wrap.fromSymbol(symbols.new(parser.buf.items[0..@intCast(length)]));
            }
        }
    }

    parser.buf.clearRetainingCapacity();
    parserPopState(parser, val);
    return false;
}

// ==========================================================================
// Private functions
// ==========================================================================

/// `(parser/byte parser b)`. The low eight bits of `b` are the byte fed.
fn nfunParserByte(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 2);
    const parser = try getParser(argv, 0);
    const val = try args_core.getInteger(argv, 1);
    try consumeChecked(parser, @intCast(0xFF & val));
    return argv[0];
}

/// `(parser/clone p)`.
fn nfunParserClone(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const source = try getParser(argv, 0);
    const destination: *Parser = abstracts.newFor(Parser, &parserType);
    parserClone(source, destination);
    return wrap.fromAbstract(destination);
}

/// `(parser/consume parser bytes [index])`, returning how many bytes were
/// read. A byte that puts the parser in the error or dead state stops the
/// loop and is counted.
fn nfunParserConsume(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 2, 3);
    const parser = try getParser(argv, 0);
    var view = try args_core.getBytes(argv, 1);
    if (argv.len == 3) {
        const offset = try args_core.getInteger(argv, 2);
        // The `@intCast` is only reached when `offset` is non-negative:
        // `or` short-circuits, and the arm before it is the sign check.
        if (offset < 0 or @as(usize, @intCast(offset)) > view.len) {
            return pp_format.panicf("invalid offset %d out of range [0,%d]", .{ offset, @as(i64, @intCast(view.len)) });
        }
        view.len -= @intCast(offset);
        view.bytes.? += @intCast(offset);
    }
    var index: usize = 0;
    while (index < view.len) : (index += 1) {
        try consumeChecked(parser, view.bytes.?[index]);
        switch (parserStatus(parser)) {
            .root, .pending => {},
            // A dead or errored parser stops the loop, and the count reported
            // includes the byte that stopped it.
            else => return wrap.fromInteger(@intCast(index + 1)),
        }
    }
    return wrap.fromInteger(@intCast(index));
}

/// `(parser/eof parser)`.
fn nfunParserEof(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    try eofChecked(try getParser(argv, 0));
    return argv[0];
}

/// `(parser/error parser)`. Reading the message clears it and flushes the
/// parser.
fn nfunParserError(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const parser = try getParser(argv, 0);
    const message = parserError(parser) orelse return wrap.fromNil();
    // Interned from its bytes whatever built it. `parserError` above has
    // already cleared `generated_error`, so by here a generated message is no
    // longer distinguishable, and interning it costs a hash and a cache
    // probe.
    return value.fromBytes(std.mem.span(message), .string);
}

/// `(parser/flush parser)`.
fn nfunParserFlush(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    parserFlush(try getParser(argv, 0));
    return argv[0];
}

/// `(parser/has-more parser)`.
fn nfunParserHasMore(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    return wrap.fromBoolean(parserHasMore(try getParser(argv, 0)));
}

/// `(parser/insert parser value)`. A value inserted into a container is
/// queued as an element of it; inserted into a string or a long string, the
/// value's printed form is appended to the text being read.
fn nfunParserInsert(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 2);
    const parser = try getParser(argv, 0);
    var state = &parser.states.items[parser.states.items.len - 1];
    // A token in progress is terminated first, and the space that terminates
    // it is un-counted so the column still points at the inserted value.
    if (state.flags.token) {
        try consumeChecked(parser, ' ');
        parser.column -= 1;
        state = &parser.states.items[parser.states.items.len - 1];
    }
    if (state.flags.comment) state = @ptrCast(@as([*]ParseState, @ptrCast(state)) - 1);
    if (state.flags.container) {
        state.argn += 1;
        if (parser.states.items.len == 1) {
            parser.pending += 1;
            parserPushArg(parser, wrap.fromTuple(tuples.newFrom(argv[1..2])));
        } else {
            parserPushArg(parser, argv[1]);
        }
    } else if (state.flags.string or state.flags.long_string) {
        const text = pp_describe.toString(argv[1]);
        const length: usize = strings.head(text).length;
        parser.buf.ensureUnusedCapacity(utils.heap, length) catch fatal.outOfMemory();
        parser.buf.appendSliceAssumeCapacity(text[0..length]);
    } else {
        return raise.panic("cannot insert value into parser");
    }
    return argv[0];
}

/// `(parser/new)`.
fn nfunParserNew(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 0);
    const parser: *Parser = abstracts.newFor(Parser, &parserType);
    parserInit(parser);
    return wrap.fromAbstract(parser);
}

/// `(parser/produce parser [wrap])`.
fn nfunParserProduce(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, 2);
    const parser = try getParser(argv, 0);
    if (argv.len == 2 and repr.truthy(argv[1])) {
        return parserProduceWrapped(parser);
    }
    return parserProduce(parser);
}

/// `(parser/state parser [key])`, with the key looked up in
/// `state_getters` and every getter run when there is none.
fn nfunParserState(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, 2);
    const parser = try getParser(argv, 0);
    if (argv.len == 2) {
        const key = try args_core.getKeyword(argv, 1);
        for (state_getters) |getter| {
            if (utils.cstrcmp(key, getter.name) == 0) return getter.get(parser);
        }
        return pp_format.panicf("unexpected keyword %v", .{wrap.fromKeyword(key)});
    }
    const table = tables.new(0);
    for (state_getters) |getter| {
        tables.put(table, value.fromBytes(getter.name, .keyword), try getter.get(parser));
    }
    return wrap.fromTable(table);
}

/// `(parser/status parser)`, as the keyword rather than the number.
fn nfunParserStatus(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const name: [*:0]const u8 = switch (parserStatus(try getParser(argv, 0))) {
        .pending => "pending",
        .@"error" => "error",
        .root => "root",
        .dead => "dead",
    };
    return value.fromBytes(std.mem.span(name), .keyword);
}

/// `(parser/where parser [line [col]])`, setting the position first where
/// either is given.
fn nfunParserWhere(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, 3);
    const parser = try getParser(argv, 0);
    if (argv.len > 1) {
        const line = try args_core.getInteger(argv, 1);
        if (line < 1) return pp_format.panicf("invalid line number %d", .{line});
        parser.line = @intCast(line);
    }
    if (argv.len > 2) {
        const column = try args_core.getInteger(argv, 2);
        if (column < 0) return pp_format.panicf("invalid column number %d", .{column});
        parser.column = @intCast(column);
    }
    const pair = [2]repr.Value{
        wrap.fromInteger(@intCast(parser.line)),
        wrap.fromInteger(@intCast(parser.column)),
    };
    return wrap.fromVector(vectors.fromSlice(&pair));
}

/// A parser that has hit EOF, or that is sitting on an unread error, cannot be
/// fed.
fn checkDead(parser: *Parser) raise.Error!void {
    if (parser.dead or parser.generated_error) return raise.panic("parser is dead, cannot consume");
    if (parser.@"error" != null) return raise.panic("parser has unchecked error, cannot consume");
}

/// Closes the top container on a `)`, `]` or `}`, or reports the delimiter as
/// unexpected or mismatched.
fn closeDelimiter(parser: *Parser, state: *ParseState, character: u8) raise.Error!bool {
    if (parser.states.items.len == 1) {
        try delimError(parser, 0, character, "unexpected closing delimiter ");
        return true;
    }

    var val: repr.Value = undefined;
    if ((character == ')' and state.flags.parens) or
        (character == ']' and state.flags.square_brackets))
    {
        val = if (state.flags.at_symbol)
            parserCloseArray(parser, state)
        else if (state.flags.vector)
            parserCloseVector(parser, state)
        else
            parserCloseTuple(parser, state);
    } else if (character == '}' and state.flags.set) {
        // A set's elements are its own, not pairs, so the even-count rule does
        // not apply; the storable rule does, and for every element rather than
        // every other one.
        if (unstorableElementIn(parser, state, 1)) |message| {
            parser.@"error" = message;
            return true;
        }
        val = parserCloseSet(parser, state);
    } else if (character == '}' and state.flags.curly_brackets) {
        if (state.argn & 1 != 0) {
            parser.@"error" = "map and table literals expect even number of arguments";
            return true;
        }
        if (!state.flags.at_symbol) {
            if (unstorableElementIn(parser, state, 2)) |message| {
                parser.@"error" = message;
                return true;
            }
        }
        val = if (state.flags.at_symbol)
            parserCloseTable(parser, state)
        else
            parserCloseMap(parser, state);
    } else {
        try delimError(parser, parser.states.items.len - 1, character, "mismatched delimiter ");
        return true;
    }
    parserPopState(parser, val);
    return true;
}

/// Builds the message for an unexpected closing delimiter, a mismatched
/// delimiter, or an unclosed form at end of source, naming where the form
/// opened.
///
/// The result is a Janet string stored in the parser's `error` field, and
/// `generated_error` is what says so: the field usually points at a literal,
/// and the flag is what tells `parserMark` to trace the string.
fn delimError(
    parser: *Parser,
    stack_index: usize,
    character: u8,
    message: ?[*:0]const u8,
) raise.Error!void {
    const state = &parser.states.items[stack_index];
    const text = buffers.new(40);
    if (message) |m| try buffers.pushCString(text, m);
    if (character != 0) try buffers.pushU8(text, character);
    if (stack_index > 0) {
        try buffers.pushCString(text, ", ");
        if (state.flags.parens) {
            try buffers.pushU8(text, '(');
        } else if (state.flags.square_brackets) {
            try buffers.pushU8(text, '[');
        } else if (state.flags.set) {
            try buffers.pushCString(text, "#{");
        } else if (state.flags.curly_brackets) {
            try buffers.pushU8(text, '{');
        } else if (state.flags.string) {
            try buffers.pushU8(text, '"');
        } else if (state.flags.long_string) {
            // The run that opened it, in the delimiter that opened it.
            const ticks: usize = @intCast(state.argn);
            for (0..ticks) |_| try buffers.pushU8(text, '"');
        }
        _ = try pp_format.formatb(text, " opened at line %d, column %d", .{ @as(i32, @intCast(state.line)), @as(i32, @intCast(state.column)) });
    }
    parser.@"error" = @ptrCast(strings.new(text.slice()));
    parser.generated_error = true;
}

/// Ends a string or buffer with what the scratch buffer has accumulated.
///
/// A long string is reindented first: the indentation up to the column the
/// string opened at is dropped from each line, along with a leading and a
/// trailing newline. A line indented less than that stops the reindentation
/// altogether, so a string whose lines do not line up is left as written.
fn finishString(parser: *Parser, state: *ParseState) raise.Error!bool {
    var start: usize = 0;
    var length = parser.buf.items.len;

    if (state.flags.long_string) {
        const indent_column: i32 = @as(i32, @intCast(parser.states.items[parser.states.items.len - 1].column)) - 1;
        var read: usize = 0;
        var reindent = true;

        while (reindent and read < length) {
            const character = parser.buf.items[read];
            read += 1;
            if (character == '\n') {
                var column: i32 = 0;
                while (read < length and parser.buf.items[read] != '\n' and column < indent_column) : (column += 1) {
                    if (parser.buf.items[read] != ' ') {
                        reindent = false;
                        break;
                    }
                    read += 1;
                }
                if (read + 1 < length and parser.buf.items[read] == '\r' and parser.buf.items[read + 1] == '\n') {
                    reindent = true;
                }
            }
        }

        if (reindent) {
            var write: usize = 0;
            read = 0;
            while (read < length) {
                if (parser.buf.items[read] == '\n') {
                    parser.buf.items[write] = parser.buf.items[read];
                    write += 1;
                    read += 1;
                    var column: i32 = 0;
                    while (read < length and parser.buf.items[read] != '\n' and column < indent_column) : (column += 1) {
                        read += 1;
                    }
                    if (read + 1 < length and parser.buf.items[read] == '\r' and parser.buf.items[read + 1] == '\n') {
                        parser.buf.items[write] = parser.buf.items[read];
                        write += 1;
                        read += 1;
                    }
                } else {
                    parser.buf.items[write] = parser.buf.items[read];
                    write += 1;
                    read += 1;
                }
            }
            length = write;
        }

        if (length > 1 and parser.buf.items[0] == '\r' and parser.buf.items[1] == '\n') {
            start = 2;
            length -= 2;
        } else if (length > 0 and parser.buf.items[0] == '\n') {
            start = 1;
            length -= 1;
        }
        if (length > 1 and parser.buf.items[start + length - 2] == '\r' and parser.buf.items[start + length - 1] == '\n') {
            length -= 2;
        } else if (length > 0 and parser.buf.items[start + length - 1] == '\n') {
            length -= 1;
        }
    }

    const val = if (state.flags.buffer) val: {
        const result = buffers.new(@intCast(length));
        try buffers.pushBytes(result, parser.buf.items[start..][0..@intCast(length)]);
        break :val wrap.fromBuffer(result);
    } else wrap.fromString(strings.new(parser.buf.items[start..][0..@intCast(length)]));

    parser.buf.clearRetainingCapacity();
    parserPopState(parser, val);
    return true;
}

/// The parser at `argv[n]`, or a raise where that argument is not a parser.
fn getParser(argv: []repr.Value, n: usize) raise.Error!*Parser {
    return try args_core.getAbstract(Parser, argv, n, &parserType);
}

/// Ends the source: a newline is fed, an unclosed form becomes a delimiter
/// error, and the parser is left dead. The line and column are put back, so
/// `parser/where` still reports where the source ended.
fn parserEof(parser: *Parser) raise.Error!void {
    const previous_column = parser.column;
    const previous_line = parser.line;
    try parserConsume(parser, '\n');
    if (parser.states.items.len > 1) try delimError(parser, parser.states.items.len - 1, 0, "unexpected end of source");
    parser.line = previous_line;
    parser.column = previous_column;
    parser.dead = true;
}

/// The consumer just after a backslash: a simple escape is written and reading
/// resumes, and an `x`, `u` or `U` switches to the consumer that reads its
/// digits.
fn parserEscape1(
    parser: *Parser,
    state: *ParseState,
    character: u8,
) raise.Error!bool {
    const escaped = lexicon.escape(character) orelse {
        parser.@"error" = "invalid string escape sequence";
        return true;
    };
    switch (escaped) {
        .digits => |count| {
            state.counter = count;
            state.argn = 0;
            state.consumer = if (character == 'x') parserEscapeHex else parserEscapeUnicode;
        },
        .byte => |byte| {
            parserPushBuf(parser, byte);
            state.consumer = wattleStringchar;
        },
    }
    return true;
}

/// Reads the two digits of a `\x` escape and writes the byte.
fn parserEscapeHex(
    parser: *Parser,
    state: *ParseState,
    character: u8,
) raise.Error!bool {
    const digit = lexicon.hexDigit(character) orelse {
        parser.@"error" = "invalid hex digit in hex escape";
        return true;
    };
    state.argn = (state.argn << 4) + digit;
    state.counter -= 1;
    if (state.counter == 0) {
        parserPushBuf(parser, @intCast(state.argn & 0xff));
        state.argn = 0;
        state.consumer = wattleStringchar;
    }
    return true;
}

/// Reads the four or six digits of a `\u` or `\U` escape and writes the
/// codepoint as UTF-8.
fn parserEscapeUnicode(
    parser: *Parser,
    state: *ParseState,
    character: u8,
) raise.Error!bool {
    const digit = lexicon.hexDigit(character) orelse {
        parser.@"error" = "invalid hex digit in unicode escape";
        return true;
    };
    state.argn = (state.argn << 4) + digit;
    state.counter -= 1;
    if (state.counter == 0) {
        if (state.argn > lexicon.max_codepoint) {
            parser.@"error" = "invalid unicode codepoint";
            return true;
        }
        writeCodepoint(parser, state.argn);
        state.argn = 0;
        state.consumer = wattleStringchar;
    }
    return true;
}

/// Frees the three lists when the abstract is collected.
fn parserGC(parser: *Parser, _: usize) void {
    parserDeinit(parser);
}

/// The method lookup behind `(p :consume)` and its siblings.
fn parserGet(_: *Parser, key: repr.Value) raise.Error!?repr.Value {
    return args_core.findMethod(key, @ptrCast(&methods));
}

/// The consumer inside a raw string, closed by a run of `delimiter` as long as
/// the run that opened it; a shorter run is text.
///
/// `state.argn` is that length and `state.counter` is how much of a candidate
/// closing run has been read. Janet opens one with a run of `` ` `` and Wattle
/// with a run of `"`, and the delimiter is the whole of the difference.
fn longstringImpl(
    comptime delimiter: u8,
    parser: *Parser,
    state: *ParseState,
    character: u8,
) raise.Error!bool {
    if (state.flags.in_string) {
        if (character == delimiter) {
            state.flags.end_candidate = true;
            state.flags.in_string = false;
            state.counter = 1;
        } else {
            parserPushBuf(parser, character);
        }
        return true;
    }
    if (state.flags.end_candidate) {
        if (state.counter == state.argn) {
            _ = try finishString(parser, state);
            return false;
        }
        if (character == delimiter and state.counter < state.argn) {
            state.counter += 1;
            return true;
        }
        const ticks: usize = @intCast(state.counter);
        for (0..ticks) |_| parserPushBuf(parser, delimiter);
        parserPushBuf(parser, character);
        state.counter = 0;
        state.flags.end_candidate = false;
        state.flags.in_string = true;
        return true;
    }

    state.argn += 1;
    if (character != delimiter) {
        state.flags.in_string = true;
        parserPushBuf(parser, character);
    }
    return true;
}

/// Traces the queued values, and the error message where the parser generated
/// it: a literal message is not a Janet string.
fn parserMark(parser: *Parser, _: usize) void {
    for (parser.args.items) |arg| gc_mark.mark(arg);
    // Only a generated message is a Janet string; a literal must not be traced.
    if (parser.generated_error) {
        gc_mark.mark(wrap.fromString(@ptrCast(parser.@"error")));
    }
}

/// The iteration order behind `next` and `(keys p)`.
fn parserNext(_: *Parser, key: repr.Value) raise.Error!repr.Value {
    return args_core.nextmethod(@ptrCast(&methods), key);
}

/// `(parser/state p :delimiters)`: one byte per open form, outermost first.
///
/// The characters are pushed onto the parser's own buffer and the count is put
/// back afterwards, so this reads like a mutation and leaves the buffer as it
/// found it. The buffer is the scratch area the parser already owns and is
/// already sized for.
///
/// It declares an error it never returns, so that it and `parserStateFrames`,
/// which does raise, share a signature and sit in one array. A tagged union
/// over two function types is more machinery than the fact deserves.
pub fn parserStateDelimiters(parser: *Parser) raise.Error!repr.Value {
    const old_count = parser.buf.items.len;
    for (0..parser.states.items.len) |index| {
        const state = &parser.states.items[index];
        if (state.flags.parens) {
            parserPushBuf(parser, '(');
        } else if (state.flags.square_brackets) {
            parserPushBuf(parser, '[');
        } else if (state.flags.curly_brackets) {
            parserPushBuf(parser, '{');
        } else if (state.flags.string) {
            parserPushBuf(parser, '"');
        } else if (state.flags.long_string) {
            // The delimiter that opened it, as `delimError` names it.
            const ticks: usize = @intCast(state.argn);
            for (0..ticks) |_| parserPushBuf(parser, '"');
        }
    }
    const text = strings.new(parser.buf.items[old_count..]);
    parser.buf.shrinkRetainingCapacity(old_count);
    return wrap.fromString(text);
}

/// `(parser/state p :frames)`, innermost frame last.
///
/// The walk runs backwards because a container frame's arguments sit at the
/// end of one shared array and their extent follows only from subtracting
/// each frame's count in turn.
fn parserStateFrames(parser: *Parser) raise.Error!repr.Value {
    const count: i32 = @intCast(parser.states.items.len);
    const states = arrays.new(@intCast(count));
    states.count = @intCast(count);
    // One past the last argument. An empty list's pointer is not null, so
    // there is no null case to step around.
    var args: ?[*]repr.Value = parser.args.items.ptr + parser.args.items.len;
    var index = count - 1;
    while (index >= 0) : (index -= 1) {
        const state = &parser.states.items[@intCast(index)];
        if (state.flags.container and state.argn != 0) args = args.? - @as(usize, @intCast(state.argn));
        states.reserved()[@intCast(index)] = try wrapParseState(state, args, parser.buf.items.ptr, @intCast(parser.buf.items.len));
    }
    return wrap.fromArray(states);
}

/// Records where a form began. A tuple is the only value with a source map, so
/// anything else is returned as it stands.
fn setSource(original_value: repr.Value, line: usize, column: usize) repr.Value {
    const val = original_value;
    if (repr.checkType(val, repr.Tag.tuple)) {
        const head = utils.tupleHead(wrap.toTuple(val));
        head.sm_line = @intCast(line);
        head.sm_column = @intCast(column);
    }
    return val;
}

/// Drops the queue's first value, moving the rest down.
fn shiftArguments(parser: *Parser) void {
    for (1..parser.args.items.len) |index| parser.args.items[index - 1] = parser.args.items[index];
    parser.pending -= 1;
    _ = parser.args.pop();
    parser.states.items[0].argn -= 1;
}

/// Whether the token in `bytes` is exactly `expected`.
fn tokenEquals(bytes: []const u8, comptime expected: []const u8) bool {
    return std.mem.eql(u8, bytes, expected);
}

/// One frame of `(parser/state p :frames)`: what is being parsed, where it
/// started, and what has been read into it so far.
fn wrapParseState(
    state: *allowzero const ParseState,
    args: ?[*]repr.Value,
    buf: ?[*]u8,
    bufcount: u32,
) raise.Error!repr.Value {
    const table = tables.new(0);
    var add_buffer = false;

    if (state.flags.container) {
        const container_args = arrays.new(@intCast(state.argn));
        const argn: usize = @intCast(state.argn);
        for (0..argn) |index| try arrays.push(container_args, args.?[index]);
        tables.put(table, value.fromBytes("args", .keyword), wrap.fromArray(container_args));
    }

    const type_name: [*:0]const u8 = if (state.flags.parens or state.flags.square_brackets)
        (if (state.flags.at_symbol) "array" else if (state.flags.vector) "vector" else "tuple")
    else if (state.flags.set)
        "set"
    else if (state.flags.curly_brackets)
        (if (state.flags.at_symbol) "table" else "map")
    else if (state.flags.string or state.flags.long_string) blk: {
        add_buffer = true;
        break :blk if (state.flags.buffer) "buffer" else "string";
    } else if (state.flags.comment) blk: {
        add_buffer = true;
        break :blk "comment";
    } else if (state.flags.token) blk: {
        add_buffer = true;
        break :blk "token";
    } else if (state.flags.dispatch)
        "dispatch"
    else if (state.flags.at_symbol)
        "bang"
    else if (state.flags.reader_macro) switch (state.flags.macro_char) {
        '\'' => "quote",
        '~' => "unquote",
        '|' => "splice",
        '#' => "short-fn",
        '`' => "quasiquote",
        else => "<reader>",
    } else "root";

    tables.put(table, value.fromBytes("type", .keyword), value.fromBytes(std.mem.span(type_name), .keyword));
    if (add_buffer) {
        tables.put(table, value.fromBytes("buffer", .keyword), wrap.fromString(strings.new(if (buf) |p| p[0..bufcount] else "")));
    }
    tables.put(table, value.fromBytes("line", .keyword), wrap.fromInteger(@intCast(state.line)));
    tables.put(table, value.fromBytes("column", .keyword), wrap.fromInteger(@intCast(state.column)));
    return wrap.fromTable(table);
}

/// Builds the two-element form a reader macro expands to, such as `(quote x)`
/// for `'x`.
fn wrapReader(original_value: repr.Value, character: c_int, line: usize, column: usize) repr.Value {
    const tuple = tuples.begin(2);
    const name: [*:0]const u8 = switch (character) {
        '\'' => "quote",
        '~' => "unquote",
        '|' => "splice",
        '#' => "short-fn",
        '`' => "quasiquote",
        else => "<unknown>",
    };
    tuple[0] = wrap.fromSymbol(symbols.csymbol(name));
    tuple[1] = original_value;
    const head = utils.tupleHead(tuple);
    head.sm_line = @intCast(line);
    head.sm_column = @intCast(column);
    return wrap.fromTuple(tuples.end(tuple));
}

/// Wraps a value finished at the root in a one-element tuple that records
/// where it began.
fn wrapRoot(original_value: repr.Value, line: usize, column: usize) repr.Value {
    var val = original_value;
    const tuple = tuples.newFrom(@as(*const [1]repr.Value, &val));
    const head = utils.tupleHead(tuple);
    head.sm_line = @intCast(line);
    head.sm_column = @intCast(column);
    return wrap.fromTuple(tuple);
}

/// Writes `codepoint` to the scratch buffer as UTF-8.
fn writeCodepoint(parser: *Parser, codepoint: i32) void {
    if (codepoint <= 0x7f) {
        parserPushBuf(parser, @intCast(codepoint));
    } else if (codepoint <= 0x7ff) {
        parserPushBuf(parser, @intCast(((codepoint >> 6) & 0x1f) | 0xc0));
        parserPushBuf(parser, @intCast((codepoint & 0x3f) | 0x80));
    } else if (codepoint <= 0xffff) {
        parserPushBuf(parser, @intCast(((codepoint >> 12) & 0x0f) | 0xe0));
        parserPushBuf(parser, @intCast(((codepoint >> 6) & 0x3f) | 0x80));
        parserPushBuf(parser, @intCast((codepoint & 0x3f) | 0x80));
    } else {
        parserPushBuf(parser, @intCast(((codepoint >> 18) & 0x07) | 0xf0));
        parserPushBuf(parser, @intCast(((codepoint >> 12) & 0x3f) | 0x80));
        parserPushBuf(parser, @intCast(((codepoint >> 6) & 0x3f) | 0x80));
        parserPushBuf(parser, @intCast((codepoint & 0x3f) | 0x80));
    }
}
