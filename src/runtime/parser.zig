//! Janet's reader: a state machine that takes one byte at a time and queues
//! whole values, plus the abstract type that exposes it to Janet as
//! `parser/*`.
//!
//! **Two kinds of failure, and the difference is the point.** A *parse* error
//! is data -- it goes into `parser->error`, `parser/status` answers `:error`,
//! and the caller decides what to do. Feeding bytes to a parser that has
//! already finished, or that is still holding an unread error, is a *panic*,
//! because there is no value to answer with. **Both kinds are decided here**,
//! by this engine rather than by a caller ahead of it.
//!
//! The two panics say different things and reaching the second takes care: a
//! delimiter error sets the dead flag as well as the message, so it reports
//! "parser is dead". "parser has unchecked error" needs an error that
//! `delimError` did not raise, and needs it left unread, because
//! `parser/error` clears it.

const std = @import("std");
const config = @import("config");
const corefn = @import("corefn.zig");
const raise = @import("../api/raise.zig");
const pp_format = @import("pp/format.zig");
const repr = @import("repr");
const constants = @import("constants");
const abstract_type = @import("../api/abstract_type.zig");
const method_type = @import("method_type.zig");
const structs = @import("value/structs.zig");
const tables = @import("value/tables.zig");
const strings = @import("value/strings.zig");
const symbols = @import("value/symbols.zig");
const tuples = @import("value/tuples.zig");
const utils = @import("utils.zig");
const fatal = @import("fatal.zig");
const gc_mark = @import("gc/mark.zig");
const numscan = @import("scan.zig");
const wrap = @import("value/helpers/wrap.zig");
const args_core = @import("args.zig");
const arrays = @import("value/arrays.zig");
const buffers = @import("value/buffers.zig");
const value = @import("value.zig");
const abstracts = @import("value/abstracts.zig");
const pp_describe = @import("pp.zig");

/// A parse state's consumer: given a character, whether it consumed it.
///
/// **Not optional and not `callconv(.c)`.** Every state is pushed with one --
/// `parserPushState` takes it as a parameter -- so nothing has to unwrap it,
/// and nothing outside this tree implements one.
///
/// **And it raises.** Three consumers finish a string or close a delimiter,
/// which can, and a `callconv(.c)` slot could not hold the error union that
/// carries it. The error set is spelled out rather than imported, so that this
/// declaration needs nothing above `repr` in the module graph.
pub const Consumer = *const fn (p: *Parser, state: *ParseState, c: u8) error{JanetSignal}!bool;

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

/// One parser state's flags.
///
/// **The low byte is not a flag word**: when `reader_macro` is set it holds the
/// macro's character, which `parser.zig` reads back to rebuild the form. That
/// is why it is a field of its own rather than eight bools.
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
    _reserved19: u1 = 0,
    in_string: bool = false,
    end_candidate: bool = false,
    _reserved22: u10 = 0,
};

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

/// What `parser/status` answers, and the whole of what a parser can be in.
/// A Janet program sees the keyword rather than the number, and the keyword is
/// what the suites pin; the numbers are C's and are kept.
pub const ParserStatus = enum(u32) {
    root = 0,
    @"error" = 1,
    pending = 2,
    dead = 3,
};

pub fn parserConsume(parser: *Parser, character: u8) raise.Raising(void) {
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

fn parserEof(parser: *Parser) raise.Raising(void) {
    const previous_column = parser.column;
    const previous_line = parser.line;
    try parserConsume(parser, '\n');
    if (parser.states.items.len > 1) try delimError(parser, parser.states.items.len - 1, 0, "unexpected end of source");
    parser.line = previous_line;
    parser.column = previous_column;
    parser.dead = true;
}

pub fn parserPushBuf(parser: *Parser, val: u8) void {
    parser.buf.append(utils.heap, val) catch fatal.outOfMemory();
}

pub fn parserPushArg(parser: *Parser, val: repr.Value) void {
    parser.args.append(utils.heap, val) catch fatal.outOfMemory();
}

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

pub fn parserCloseTuple(
    parser: *Parser,
    state: *ParseState,
    flag: i32,
) repr.Value {
    const tuple = tuples.begin(@intCast(state.argn));
    if (flag != 0) tuples.setBracketed(utils.tupleHead(tuple));
    var index = state.argn;
    while (index > 0) {
        index -= 1;
        tuple[@intCast(index)] = parser.args.pop().?;
    }
    return wrap.fromTuple(tuples.end(tuple));
}

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

pub fn parserCloseStruct(
    parser: *Parser,
    state: *ParseState,
) repr.Value {
    const structure = structs.begin(@intCast(@divTrunc(state.argn, 2)));
    const start = parser.args.items.len - @as(usize, @intCast(state.argn));
    var index = start;
    while (index < parser.args.items.len) : (index += 2) {
        structs.put(structure, parser.args.items[index], parser.args.items[index + 1]);
    }
    parser.args.shrinkRetainingCapacity(start);
    return wrap.fromStruct(structs.end(structure));
}

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

fn parserStringchar(
    parser: *Parser,
    state: *ParseState,
    character: u8,
) raise.Raising(bool) {
    if (character == '\\') {
        state.consumer = parserEscape1;
    } else if (character == '"') {
        return try finishString(parser, state);
    } else if (character != '\n' and character != '\r') {
        parserPushBuf(parser, character);
    }
    return true;
}

fn parserEscape1(
    parser: *Parser,
    state: *ParseState,
    character: u8,
) raise.Raising(bool) {
    const escaped = checkEscape(character);
    if (escaped < 0) {
        parser.@"error" = "invalid string escape sequence";
    } else if (character == 'x') {
        state.counter = 2;
        state.argn = 0;
        state.consumer = parserEscapeHex;
    } else if (character == 'u' or character == 'U') {
        state.counter = if (character == 'u') 4 else 6;
        state.argn = 0;
        state.consumer = parserEscapeUnicode;
    } else {
        parserPushBuf(parser, @intCast(escaped));
        state.consumer = parserStringchar;
    }
    return true;
}

fn parserEscapeHex(
    parser: *Parser,
    state: *ParseState,
    character: u8,
) raise.Raising(bool) {
    const digit = hexDigit(character);
    if (digit < 0) {
        parser.@"error" = "invalid hex digit in hex escape";
        return true;
    }
    state.argn = (state.argn << 4) + digit;
    state.counter -= 1;
    if (state.counter == 0) {
        parserPushBuf(parser, @intCast(state.argn & 0xff));
        state.argn = 0;
        state.consumer = parserStringchar;
    }
    return true;
}

fn parserEscapeUnicode(
    parser: *Parser,
    state: *ParseState,
    character: u8,
) raise.Raising(bool) {
    const digit = hexDigit(character);
    if (digit < 0) {
        parser.@"error" = "invalid hex digit in unicode escape";
        return true;
    }
    state.argn = (state.argn << 4) + digit;
    state.counter -= 1;
    if (state.counter == 0) {
        if (state.argn > 0x10ffff) {
            parser.@"error" = "invalid unicode codepoint";
            return true;
        }
        writeCodepoint(parser, state.argn);
        state.argn = 0;
        state.consumer = parserStringchar;
    }
    return true;
}

fn parserLongstring(
    parser: *Parser,
    state: *ParseState,
    character: u8,
) raise.Raising(bool) {
    if (state.flags.in_string) {
        if (character == '`') {
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
        if (character == '`' and state.counter < state.argn) {
            state.counter += 1;
            return true;
        }
        const ticks: usize = @intCast(state.counter);
        for (0..ticks) |_| parserPushBuf(parser, '`');
        parserPushBuf(parser, character);
        state.counter = 0;
        state.flags.end_candidate = false;
        state.flags.in_string = true;
        return true;
    }

    state.argn += 1;
    if (character != '`') {
        state.flags.in_string = true;
        parserPushBuf(parser, character);
    }
    return true;
}

pub fn parserTokenchar(
    parser: *Parser,
    state: *ParseState,
    character: u8,
) raise.Raising(bool) {
    if (numscan.isSymbolChar(character)) {
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
        if (state.argn != 0 and !numscan.validUtf8(parser.buf.items[1..@intCast(length)])) {
            parser.@"error" = "invalid utf-8 in keyword";
            return false;
        }
        val = wrap.fromKeyword(symbols.new(parser.buf.items[1..@intCast(length)]));
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
                if (state.argn != 0 and !numscan.validUtf8(parser.buf.items[0..@intCast(length)])) {
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

pub fn parserComment(
    parser: *Parser,
    _: *ParseState,
    character: u8,
) raise.Raising(bool) {
    if (character == '\n') {
        _ = parser.states.pop();
        parser.buf.clearRetainingCapacity();
    } else {
        parserPushBuf(parser, character);
    }
    return true;
}

pub fn parserAtsign(
    parser: *Parser,
    _: *ParseState,
    character: u8,
) raise.Raising(bool) {
    _ = parser.states.pop();
    switch (character) {
        '{' => parserPushState(parser, parserRoot, .{ .container = true, .curly_brackets = true, .at_symbol = true }),
        '"' => parserPushState(parser, parserStringchar, .{ .buffer = true, .string = true }),
        '`' => parserPushState(parser, parserLongstring, .{ .buffer = true, .long_string = true }),
        '[' => parserPushState(parser, parserRoot, .{ .container = true, .square_brackets = true, .at_symbol = true }),
        '(' => parserPushState(parser, parserRoot, .{ .container = true, .parens = true, .at_symbol = true }),
        else => {
            parserPushState(parser, parserTokenchar, .{ .token = true });
            parserPushBuf(parser, '@');
            return false;
        },
    }
    return true;
}

pub fn parserRoot(
    parser: *Parser,
    state: *ParseState,
    character: u8,
) raise.Raising(bool) {
    switch (character) {
        '\'', ',', ';', '~', '|' => {
            parserPushState(parser, parserRoot, .{ .reader_macro = true, .macro_char = character });
            return true;
        },
        '"' => {
            parserPushState(parser, parserStringchar, .{ .string = true });
            return true;
        },
        '#' => {
            parserPushState(parser, parserComment, .{ .comment = true });
            return true;
        },
        '@' => {
            parserPushState(parser, parserAtsign, .{ .at_symbol = true });
            return true;
        },
        '`' => {
            parserPushState(parser, parserLongstring, .{ .long_string = true });
            return true;
        },
        ')', ']', '}' => return closeDelimiter(parser, state, character),
        '(' => {
            parserPushState(parser, parserRoot, .{ .container = true, .parens = true });
            return true;
        },
        '[' => {
            parserPushState(parser, parserRoot, .{ .container = true, .square_brackets = true });
            return true;
        },
        '{' => {
            parserPushState(parser, parserRoot, .{ .container = true, .curly_brackets = true });
            return true;
        },
        else => {
            if (isWhitespace(character)) return true;
            if (!numscan.isSymbolChar(character)) {
                parser.@"error" = "unexpected character";
                return true;
            }
            parserPushState(parser, parserTokenchar, .{ .token = true });
            return false;
        },
    }
}

fn closeDelimiter(parser: *Parser, state: *ParseState, character: u8) raise.Raising(bool) {
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
        else
            parserCloseTuple(
                parser,
                state,
                if (character == ']') constants.JANET_TUPLE_FLAG_BRACKETCTOR else 0,
            );
    } else if (character == '}' and state.flags.curly_brackets) {
        if (state.argn & 1 != 0) {
            parser.@"error" = "struct and table literals expect even number of arguments";
            return true;
        }
        val = if (state.flags.at_symbol)
            parserCloseTable(parser, state)
        else
            parserCloseStruct(parser, state);
    } else {
        try delimError(parser, parser.states.items.len - 1, character, "mismatched delimiter ");
        return true;
    }
    parserPopState(parser, val);
    return true;
}

fn isWhitespace(character: u8) bool {
    return switch (character) {
        ' ', '\t', '\n', '\r', 0, 11, 12 => true,
        else => false,
    };
}

fn tokenEquals(bytes: []const u8, comptime expected: []const u8) bool {
    return std.mem.eql(u8, bytes, expected);
}

fn finishString(parser: *Parser, state: *ParseState) raise.Raising(bool) {
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

fn setSource(original_value: repr.Value, line: usize, column: usize) repr.Value {
    const val = original_value;
    if (repr.checkType(val, repr.Tag.tuple)) {
        const head = utils.tupleHead(wrap.toTuple(val));
        head.sm_line = @intCast(line);
        head.sm_column = @intCast(column);
    }
    return val;
}

fn wrapRoot(original_value: repr.Value, line: usize, column: usize) repr.Value {
    var val = original_value;
    const tuple = tuples.newFrom(@as(*const [1]repr.Value, &val));
    const head = utils.tupleHead(tuple);
    head.sm_line = @intCast(line);
    head.sm_column = @intCast(column);
    return wrap.fromTuple(tuple);
}

fn wrapReader(original_value: repr.Value, character: c_int, line: usize, column: usize) repr.Value {
    const tuple = tuples.begin(2);
    const name: [*:0]const u8 = switch (character) {
        '\'' => "quote",
        ',' => "unquote",
        ';' => "splice",
        '|' => "short-fn",
        '~' => "quasiquote",
        else => "<unknown>",
    };
    tuple[0] = wrap.fromSymbol(symbols.csymbol(name));
    tuple[1] = original_value;
    const head = utils.tupleHead(tuple);
    head.sm_line = @intCast(line);
    head.sm_column = @intCast(column);
    return wrap.fromTuple(tuples.end(tuple));
}

fn hexDigit(character: u8) i32 {
    if (character >= '0' and character <= '9') return character - '0';
    if (character >= 'A' and character <= 'F') return 10 + character - 'A';
    if (character >= 'a' and character <= 'f') return 10 + character - 'a';
    return -1;
}

fn checkEscape(character: u8) i32 {
    return switch (character) {
        'x', 'u', 'U' => 1,
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        '0', 'z' => 0,
        'f' => 12,
        'v' => 11,
        'a' => 7,
        'b' => 8,
        '\'' => '\'',
        '?' => '?',
        'e' => 27,
        '"' => '"',
        '\\' => '\\',
        else => -1,
    };
}

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

pub fn parserStatus(parser: *Parser) ParserStatus {
    if (parser.@"error" != null) return .@"error";
    if (parser.dead or parser.generated_error) return .dead;
    if (parser.states.items.len > 1) return .pending;
    return .root;
}

pub fn parserFlush(parser: *Parser) void {
    parser.args.clearRetainingCapacity();
    parser.states.shrinkRetainingCapacity(1);
    parser.buf.clearRetainingCapacity();
    parser.pending = 0;
}

pub fn parserError(parser: *Parser) ?[*:0]const u8 {
    if (parserStatus(parser) != .@"error") return null;
    const message = parser.@"error";
    parser.@"error" = null;
    parser.generated_error = false;
    parserFlush(parser);
    return message;
}

pub fn parserProduce(parser: *Parser) repr.Value {
    if (parser.pending == 0) return wrap.fromNil();
    const result = wrap.toTuple(parser.args.items[0])[0];
    shiftArguments(parser);
    return result;
}

pub fn parserProduceWrapped(parser: *Parser) repr.Value {
    if (parser.pending == 0) return wrap.fromNil();
    const result = parser.args.items[0];
    shiftArguments(parser);
    return result;
}

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
    // `Precise` because the root state is the only one a fresh parser holds,
    // and the second slot is room for one push before the first grow.
    parser.states.ensureTotalCapacityPrecise(utils.heap, 2) catch fatal.outOfMemory();
    parser.states.appendAssumeCapacity(.{
        .counter = 0,
        .argn = 0,
        .flags = .{ .container = true },
        .line = parser.line,
        .column = parser.column,
        .consumer = parserRoot,
    });
}

pub fn parserDeinit(parser: *Parser) void {
    parser.args.deinit(utils.heap);
    parser.buf.deinit(utils.heap);
    parser.states.deinit(utils.heap);
    // `ArrayListUnmanaged.deinit` ends `self.* = undefined`; see
    // `gc.rootsDeinit`. A parser left in that state is one whose next use
    // reads a freed pointer through a capacity that still looks live.
    parser.args = .empty;
    parser.buf = .empty;
    parser.states = .empty;
}

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
    // Count-many, not capacity-many: each of the three allocations is sized
    // to the *count* it then copies, so a clone never carries the source's
    // spare room. `Precise` is what says so.
    destination.buf.ensureTotalCapacityPrecise(utils.heap, source.buf.items.len) catch fatal.outOfMemory();
    destination.buf.appendSliceAssumeCapacity(source.buf.items);
    destination.args.ensureTotalCapacityPrecise(utils.heap, source.args.items.len) catch fatal.outOfMemory();
    destination.args.appendSliceAssumeCapacity(source.args.items);
    destination.states.ensureTotalCapacityPrecise(utils.heap, source.states.items.len) catch fatal.outOfMemory();
    destination.states.appendSliceAssumeCapacity(source.states.items);
}

pub fn parserHasMore(parser: *Parser) bool {
    return parser.pending != 0;
}

fn shiftArguments(parser: *Parser) void {
    for (1..parser.args.items.len) |index| parser.args.items[index - 1] = parser.args.items[index];
    parser.pending -= 1;
    _ = parser.args.pop();
    parser.states.items[0].argn -= 1;
}

// ==========================================================================
// Errors, and the parser's raise perimeter
//
// The parser reports two different ways and the difference matters. A *parse*
// error is data: it goes into `parser->error`, `parser/status` answers
// `:error`, and the caller decides what to do. A *use* error -- feeding bytes
// to a parser that has already finished -- is a raise, because there is no
// sensible value to answer with.
// ==========================================================================

/// Build the "unexpected closing delimiter" / "mismatched delimiter" /
/// "unexpected end of source" message, naming where the unclosed form opened.
///
/// The result is a Janet string stored in the parser's `error` field, which is
/// why `generated_error` is set: the field usually points at a literal, and
/// the flag is what tells `parsermark` to trace it and `parser/error` to
/// return it as a string rather than re-intern it.
fn delimError(
    parser: *Parser,
    stack_index: usize,
    character: u8,
    message: ?[*:0]const u8,
) raise.Raising(void) {
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
        } else if (state.flags.curly_brackets) {
            try buffers.pushU8(text, '{');
        } else if (state.flags.string) {
            try buffers.pushU8(text, '"');
        } else if (state.flags.long_string) {
            const ticks: usize = @intCast(state.argn);
            for (0..ticks) |_| try buffers.pushU8(text, '`');
        }
        _ = try pp_format.formatb(text, " opened at line %d, column %d", .{ @as(i32, @intCast(state.line)), @as(i32, @intCast(state.column)) });
    }
    parser.@"error" = @ptrCast(strings.new(text.slice()));
    parser.generated_error = true;
}

/// A parser that has hit EOF or is holding an unread error cannot be fed.
fn checkDead(parser: *Parser) raise.Raising(void) {
    if (parser.dead or parser.generated_error) return raise.panic("parser is dead, cannot consume");
    if (parser.@"error" != null) return raise.panic("parser has unchecked error, cannot consume");
}

pub fn consumeChecked(parser: *Parser, character: u8) raise.Raising(void) {
    try checkDead(parser);
    try parserConsume(parser, character);
}

pub fn eofChecked(parser: *Parser) raise.Raising(void) {
    try checkDead(parser);
    try parserEof(parser);
}

// ==========================================================================
// The parser as an abstract type
// ==========================================================================

fn parserMark(parser: *Parser, _: usize) void {
    for (parser.args.items) |arg| gc_mark.mark(arg);
    // Only a generated message is a Janet string; a literal must not be traced.
    if (parser.generated_error) {
        gc_mark.mark(wrap.fromString(@ptrCast(parser.@"error")));
    }
}

fn parserGC(parser: *Parser, _: usize) void {
    parserDeinit(parser);
}

fn parserGet(_: *Parser, key: repr.Value) raise.Raising(?repr.Value) {
    return args_core.findMethod(key, @ptrCast(&methods));
}

fn parserNext(_: *Parser, key: repr.Value) raise.Raising(repr.Value) {
    return args_core.nextmethod(@ptrCast(&methods), key);
}

pub const parserType = abstract_type.define(Parser, .{
    .name = "core/parser",
    .gc = parserGC,
    .gcmark = parserMark,
    .get = parserGet,
    .next = parserNext,
});

fn getParser(argv: []repr.Value, n: usize) raise.Raising(*Parser) {
    return try args_core.getAbstract(Parser, argv, n, &parserType);
}

// ==========================================================================
// The cfunction surface
// ==========================================================================

fn cfunParserNew(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 0);
    const parser: *Parser = abstracts.newFor(Parser, &parserType);
    parserInit(parser);
    return wrap.fromAbstract(parser);
}

fn cfunParserConsume(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
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

fn cfunParserEof(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    try eofChecked(try getParser(argv, 0));
    return argv[0];
}

fn cfunParserInsert(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
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

fn cfunParserHasMore(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    return wrap.fromBoolean(parserHasMore(try getParser(argv, 0)));
}

fn cfunParserByte(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 2);
    const parser = try getParser(argv, 0);
    const val = try args_core.getInteger(argv, 1);
    try consumeChecked(parser, @intCast(0xFF & val));
    return argv[0];
}

fn cfunParserStatus(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    const name: [*:0]const u8 = switch (parserStatus(try getParser(argv, 0))) {
        .pending => "pending",
        .@"error" => "error",
        .root => "root",
        .dead => "dead",
    };
    return value.fromBytes(std.mem.span(name), .keyword);
}

fn cfunParserError(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    const parser = try getParser(argv, 0);
    const message = parserError(parser) orelse return wrap.fromNil();
    // Interned from its bytes whatever built it. `parserError` above has
    // already cleared `generated_error`, so by here there is no longer a
    // generated message to distinguish -- and interning one costs a hash and a
    // cache probe rather than an answer.
    return value.fromBytes(std.mem.span(message), .string);
}

fn cfunParserProduce(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.arity(argv, 1, 2);
    const parser = try getParser(argv, 0);
    if (argv.len == 2 and repr.truthy(argv[1])) {
        return parserProduceWrapped(parser);
    }
    return parserProduce(parser);
}

fn cfunParserFlush(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    parserFlush(try getParser(argv, 0));
    return argv[0];
}

fn cfunParserWhere(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
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
    const tuple = tuples.begin(2);
    tuple[0] = wrap.fromInteger(@intCast(parser.line));
    tuple[1] = wrap.fromInteger(@intCast(parser.column));
    return wrap.fromTuple(tuples.end(tuple));
}

/// One frame of `(parser/state p :frames)`: what is being parsed, where it
/// started, and what has been read into it so far.
fn wrapParseState(
    state: *allowzero const ParseState,
    args: ?[*]repr.Value,
    buf: ?[*]u8,
    bufcount: u32,
) raise.Raising(repr.Value) {
    const table = tables.new(0);
    var add_buffer = false;

    if (state.flags.container) {
        const container_args = arrays.new(@intCast(state.argn));
        const argn: usize = @intCast(state.argn);
        for (0..argn) |index| try arrays.push(container_args, args.?[index]);
        tables.put(table, value.fromBytes("args", .keyword), wrap.fromArray(container_args));
    }

    const type_name: [*:0]const u8 = if (state.flags.parens or state.flags.square_brackets)
        (if (state.flags.at_symbol) "array" else "tuple")
    else if (state.flags.curly_brackets)
        (if (state.flags.at_symbol) "table" else "struct")
    else if (state.flags.string or state.flags.long_string) blk: {
        add_buffer = true;
        break :blk if (state.flags.buffer) "buffer" else "string";
    } else if (state.flags.comment) blk: {
        add_buffer = true;
        break :blk "comment";
    } else if (state.flags.token) blk: {
        add_buffer = true;
        break :blk "token";
    } else if (state.flags.at_symbol)
        "at"
    else if (state.flags.reader_macro) switch (state.flags.macro_char) {
        '\'' => "quote",
        ',' => "unquote",
        ';' => "splice",
        '~' => "quasiquote",
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

/// `(parser/state p :delimiters)`: one byte per open form, outermost first.
///
/// The characters are pushed onto the parser's own buffer and the count is put
/// back afterwards, so this reads as a mutation and is not one. That is
/// Janet's trick and it is kept: the buffer is the one scratch area the
/// parser already owns and is already sized for.
/// Declares an error it never returns, which is normally wrong. The reason it
/// is right here is the table below: two getters of different shapes need one
/// signature to sit in one array, and `parserStateFrames` genuinely raises.
/// The alternative is a tagged union over two function types, which is more
/// machinery than the fact deserves.
/// two function types, which is more machinery than the fact deserves.
fn parserStateDelimiters(parser: *Parser) raise.Raising(repr.Value) {
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
            const ticks: usize = @intCast(state.argn);
            for (0..ticks) |_| parserPushBuf(parser, '`');
        }
    }
    const text = strings.new(parser.buf.items[old_count..]);
    parser.buf.shrinkRetainingCapacity(old_count);
    return wrap.fromString(text);
}

/// `(parser/state p :frames)`, innermost frame last.
///
/// The walk runs backwards because a container frame's arguments sit at the
/// end of one shared array and their extent is only known by subtracting each
/// frame's count in turn.
fn parserStateFrames(parser: *Parser) raise.Raising(repr.Value) {
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

const StateGetter = struct {
    name: [:0]const u8,
    get: *const fn (*Parser) raise.Raising(repr.Value),
};

const state_getters = [_]StateGetter{
    .{ .name = "frames", .get = parserStateFrames },
    .{ .name = "delimiters", .get = parserStateDelimiters },
};

fn cfunParserState(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
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

fn cfunParserClone(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    const source = try getParser(argv, 0);
    const destination: *Parser = abstracts.newFor(Parser, &parserType);
    parserClone(source, destination);
    return wrap.fromAbstract(destination);
}

/// Lexicographic order, which is not a lookup requirement: `janet_getmethod`
/// scans linearly. It is the *iteration* order, because `janet_nextmethod`
/// walks the same table, so `(keys p)` and `next` report the methods in the
/// order they are written here.
const methods = [_]method_type.Method{
    .{ .name = "byte", .cfun = cfunParserByte },
    .{ .name = "clone", .cfun = cfunParserClone },
    .{ .name = "consume", .cfun = cfunParserConsume },
    .{ .name = "eof", .cfun = cfunParserEof },
    .{ .name = "error", .cfun = cfunParserError },
    .{ .name = "flush", .cfun = cfunParserFlush },
    .{ .name = "has-more", .cfun = cfunParserHasMore },
    .{ .name = "insert", .cfun = cfunParserInsert },
    .{ .name = "produce", .cfun = cfunParserProduce },
    .{ .name = "state", .cfun = cfunParserState },
    .{ .name = "status", .cfun = cfunParserStatus },
    .{ .name = "where", .cfun = cfunParserWhere },
    .{ .name = null, .cfun = null },
};

pub fn libParse(env: *tables.Table) void {
    const entries = comptime [_]corefn.Entry{
        corefn.reg("parser/new", &cfunParserNew, @src(), "(parser/new)", "Creates and returns a new parser object. Parsers are state machines " ++
            "that can receive bytes and generate a stream of values."),
        corefn.reg("parser/clone", &cfunParserClone, @src(), "(parser/clone p)", "Creates a deep clone of a parser that is identical to the input parser. " ++
            "This cloned parser can be used to continue parsing from a good checkpoint " ++
            "if parsing later fails. Returns a new parser."),
        corefn.reg("parser/has-more", &cfunParserHasMore, @src(), "(parser/has-more parser)", "Check if the parser has more values in the value queue."),
        corefn.reg("parser/produce", &cfunParserProduce, @src(), "(parser/produce parser &opt wrap)", "Dequeue the next value in the parse queue. Will return nil if " ++
            "no parsed values are in the queue, otherwise will dequeue the " ++
            "next value. If `wrap` is truthy, will return a 1-element tuple that " ++
            "wraps the result. This tuple can be used for source-mapping " ++
            "purposes."),
        corefn.reg("parser/consume", &cfunParserConsume, @src(), "(parser/consume parser bytes &opt index)", "Input bytes into the parser and parse them. Will not throw errors " ++
            "if there is a parse error. Starts at the byte index given by `index`. Returns " ++
            "the number of bytes read."),
        corefn.reg("parser/byte", &cfunParserByte, @src(), "(parser/byte parser b)", "Input a single byte `b` into the parser byte stream. Returns the parser."),
        corefn.reg("parser/error", &cfunParserError, @src(), "(parser/error parser)", "If the parser is in the error state, returns the message associated with " ++
            "that error. Otherwise, returns nil. Also flushes the parser state and parser " ++
            "queue, so be sure to handle everything in the queue before calling " ++
            "`parser/error`."),
        corefn.reg("parser/status", &cfunParserStatus, @src(), "(parser/status parser)", "Gets the current status of the parser state machine. The status will " ++
            "be one of:\n\n" ++
            "* :pending - a value is being parsed.\n\n" ++
            "* :error - a parsing error was encountered.\n\n" ++
            "* :root - the parser can either read more values or safely terminate."),
        corefn.reg("parser/flush", &cfunParserFlush, @src(), "(parser/flush parser)", "Clears the parser state and parse queue. Can be used to reset the parser " ++
            "if an error was encountered. Does not reset the line and column counter, so " ++
            "to begin parsing in a new context, create a new parser."),
        corefn.reg("parser/state", &cfunParserState, @src(), "(parser/state parser &opt key)", "Returns a representation of the internal state of the parser. If a key is passed, " ++
            "only that information about the state is returned. Allowed keys are:\n\n" ++
            "* :delimiters - Each byte in the string represents a nested data structure. For example, " ++
            "if the parser state is '([\"', then the parser is in the middle of parsing a " ++
            "string inside of square brackets inside parentheses. Can be used to augment a REPL prompt.\n\n" ++
            "* :frames - Each table in the array represents a 'frame' in the parser state. Frames " ++
            "contain information about the start of the expression being parsed as well as the " ++
            "type of that expression and some type-specific information."),
        corefn.reg("parser/where", &cfunParserWhere, @src(), "(parser/where parser &opt line col)", "Returns the current line number and column of the parser's internal state. If line is " ++
            "provided, the current line number of the parser is first set to that value. If column is " ++
            "also provided, the current column number of the parser is also first set to that value."),
        corefn.reg("parser/eof", &cfunParserEof, @src(), "(parser/eof parser)", "Indicate to the parser that the end of file was reached. This puts the parser in the :dead state."),
        corefn.reg("parser/insert", &cfunParserInsert, @src(), "(parser/insert parser value)", "Insert a value into the parser. This means that the parser state can be manipulated " ++
            "in between chunks of bytes. This would allow a user to add extra elements to arrays " ++
            "and tuples, for example. Returns the parser."),
    };
    corefn.install(env, entries);
}
