//! Janet's reader: a state machine that takes one byte at a time and queues
//! whole values, plus the abstract type that exposes it to Janet as
//! `parser/*`.
//!
//! **Two kinds of failure, and the difference is the point.** A *parse* error
//! is data -- it goes into `parser->error`, `parser/status` answers `:error`,
//! and the caller decides what to do. Feeding bytes to a parser that has
//! already finished, or that is still holding an unread error, is a *panic*,
//! because there is no value to answer with. Phase 10 Part 7 moved the second
//! kind here; before it, `janet_parser_consume` was a C function that checked
//! and panicked before calling this engine, because a Zig frame could not
//! raise.
//!
//! The two panics say different things and reaching the second takes care: a
//! delimiter error sets the dead flag as well as the message, so it reports
//! "parser is dead". "parser has unchecked error" needs an error that
//! `delimError` did not raise, and needs it left unread, because
//! `parser/error` clears it.

const abi = @import("abi");
const corefn = @import("corefn");
const raise = @import("raise");
const pp_format = @import("pp_format.zig");
const c = abi.c;
const containers = @import("containers.zig");
const arglayer = @import("arglayer.zig");
const abstract_type = @import("abstract_type.zig");

/// `janet_wrap_integer` written out: it is a macro under nanboxing and a
/// symbol `wrap.c` never defines there.
inline fn wrapInteger(value: i32) c.Janet {
    return c.janet_wrap_number(@floatFromInt(value));
}

const parser_dead: c_int = 0x1;
const parser_generated_error: c_int = 0x2;
const container: c_int = 0x100;
const reader_macro: c_int = 0x8000;
const buffer: c_int = 0x200;
const parens: c_int = 0x400;
const square_brackets: c_int = 0x800;
const curly_brackets: c_int = 0x1000;
const string: c_int = 0x2000;
const long_string: c_int = 0x4000;
const at_symbol: c_int = 0x10000;
const comment: c_int = 0x20000;
const token: c_int = 0x40000;
const in_string: c_int = 0x100000;
const end_candidate: c_int = 0x200000;

extern fn janet_is_symbol_char(character: u8) callconv(.c) c_int;
extern fn janet_valid_utf8(bytes: [*c]const u8, length: i32) callconv(.c) c_int;

export fn janet_zig_parser_consume(parser: *c.JanetParser, character: u8) callconv(.c) void {
    if (character == '\r') {
        parser.line += 1;
        parser.column = 0;
    } else if (character == '\n') {
        parser.column = 0;
        if (parser.lookback != '\r') parser.line += 1;
    } else {
        parser.column += 1;
    }

    var consumed: c_int = 0;
    while (consumed == 0 and parser.@"error" == null) {
        const state = &parser.states[parser.statecount - 1];
        consumed = state.consumer.?(parser, state, character);
    }
    parser.lookback = character;
}

fn parserEof(parser: *c.JanetParser) raise.Raising(void) {
    const previous_column = parser.column;
    const previous_line = parser.line;
    janet_zig_parser_consume(parser, '\n');
    if (parser.statecount > 1) try delimError(parser, parser.statecount - 1, 0, "unexpected end of source");
    parser.line = previous_line;
    parser.column = previous_column;
    parser.flag |= parser_dead;
}

export fn janet_zig_parser_eof(parser: *c.JanetParser) callconv(.c) void {
    raise.reported(parserEof(parser));
}

export fn janet_zig_parser_push_buf(parser: *c.JanetParser, value: u8) callconv(.c) void {
    growAndPush(u8, &parser.buf, &parser.bufcount, &parser.bufcap, value);
}

export fn janet_zig_parser_push_arg(parser: *c.JanetParser, value: c.Janet) callconv(.c) void {
    growAndPush(c.Janet, &parser.args, &parser.argcount, &parser.argcap, value);
}

export fn janet_zig_parser_push_state(
    parser: *c.JanetParser,
    consumer: c.Consumer,
    flags: c_int,
) callconv(.c) void {
    growAndPush(c.JanetParseState, &parser.states, &parser.statecount, &parser.statecap, .{
        .counter = 0,
        .argn = 0,
        .flags = flags,
        .line = parser.line,
        .column = parser.column,
        .consumer = consumer,
    });
}

export fn janet_zig_parser_pop_state(parser: *c.JanetParser, original_value: c.Janet) callconv(.c) void {
    var value = original_value;
    while (true) {
        parser.statecount -= 1;
        const top = parser.states[parser.statecount];
        const new_top = &parser.states[parser.statecount - 1];
        value = setSource(value, top.line, top.column);
        if (new_top.flags & container != 0) {
            new_top.argn += 1;
            if (parser.statecount == 1) {
                parser.pending += 1;
                value = wrapRoot(value, top.line, top.column);
            }
            janet_zig_parser_push_arg(parser, value);
            return;
        }
        if (new_top.flags & reader_macro != 0) {
            value = wrapReader(
                value,
                new_top.flags & 0xff,
                new_top.line,
                new_top.column,
            );
        } else {
            return;
        }
    }
}

export fn janet_zig_parser_close_tuple(
    parser: *c.JanetParser,
    state: *c.JanetParseState,
    flag: i32,
) callconv(.c) c.Janet {
    const tuple = c.janet_tuple_begin(state.argn);
    c.janet_tuple_head(tuple).*.gc.flags |= @intCast(flag);
    var index = state.argn;
    while (index > 0) {
        index -= 1;
        parser.argcount -= 1;
        tuple[@intCast(index)] = parser.args[parser.argcount];
    }
    return c.janet_wrap_tuple(c.janet_tuple_end(tuple));
}

export fn janet_zig_parser_close_array(
    parser: *c.JanetParser,
    state: *c.JanetParseState,
) callconv(.c) c.Janet {
    const array = c.janet_array(state.argn);
    var index = state.argn;
    while (index > 0) {
        index -= 1;
        parser.argcount -= 1;
        array.*.data[@intCast(index)] = parser.args[parser.argcount];
    }
    array.*.count = state.argn;
    return c.janet_wrap_array(array);
}

export fn janet_zig_parser_close_struct(
    parser: *c.JanetParser,
    state: *c.JanetParseState,
) callconv(.c) c.Janet {
    const structure = c.janet_struct_begin(@divTrunc(state.argn, 2));
    var index = parser.argcount - @as(usize, @intCast(state.argn));
    while (index < parser.argcount) : (index += 2) {
        c.janet_struct_put(structure, parser.args[index], parser.args[index + 1]);
    }
    parser.argcount -= @intCast(state.argn);
    return c.janet_wrap_struct(c.janet_struct_end(structure));
}

export fn janet_zig_parser_close_table(
    parser: *c.JanetParser,
    state: *c.JanetParseState,
) callconv(.c) c.Janet {
    const table = c.janet_table(@divTrunc(state.argn, 2));
    var index = parser.argcount - @as(usize, @intCast(state.argn));
    while (index < parser.argcount) : (index += 2) {
        c.janet_table_put(table, parser.args[index], parser.args[index + 1]);
    }
    parser.argcount -= @intCast(state.argn);
    return c.janet_wrap_table(table);
}

fn janet_zig_parser_stringcharImpl(
    parser: *c.JanetParser,
    state: *c.JanetParseState,
    character: u8,
) raise.Raising(c_int) {
    if (character == '\\') {
        state.consumer = @ptrCast(&janetZigParserEscape1);
    } else if (character == '"') {
        return try finishString(parser, state);
    } else if (character != '\n' and character != '\r') {
        janet_zig_parser_push_buf(parser, character);
    }
    return 1;
}

export fn janet_zig_parser_stringchar(
    parser: *c.JanetParser,
    state: *c.JanetParseState,
    character: u8,
) callconv(.c) c_int {
    return raise.reported(janet_zig_parser_stringcharImpl(parser, state, character));
}

fn janetZigParserEscape1(
    parser: *c.JanetParser,
    state: *c.JanetParseState,
    character: u8,
) callconv(.c) c_int {
    const escaped = checkEscape(character);
    if (escaped < 0) {
        parser.@"error" = "invalid string escape sequence";
    } else if (character == 'x') {
        state.counter = 2;
        state.argn = 0;
        state.consumer = @ptrCast(&janetZigParserEscapeHex);
    } else if (character == 'u' or character == 'U') {
        state.counter = if (character == 'u') 4 else 6;
        state.argn = 0;
        state.consumer = @ptrCast(&janetZigParserEscapeUnicode);
    } else {
        janet_zig_parser_push_buf(parser, @intCast(escaped));
        state.consumer = @ptrCast(&janet_zig_parser_stringchar);
    }
    return 1;
}

fn janetZigParserEscapeHex(
    parser: *c.JanetParser,
    state: *c.JanetParseState,
    character: u8,
) callconv(.c) c_int {
    const digit = hexDigit(character);
    if (digit < 0) {
        parser.@"error" = "invalid hex digit in hex escape";
        return 1;
    }
    state.argn = (state.argn << 4) + digit;
    state.counter -= 1;
    if (state.counter == 0) {
        janet_zig_parser_push_buf(parser, @intCast(state.argn & 0xff));
        state.argn = 0;
        state.consumer = @ptrCast(&janet_zig_parser_stringchar);
    }
    return 1;
}

fn janetZigParserEscapeUnicode(
    parser: *c.JanetParser,
    state: *c.JanetParseState,
    character: u8,
) callconv(.c) c_int {
    const digit = hexDigit(character);
    if (digit < 0) {
        parser.@"error" = "invalid hex digit in unicode escape";
        return 1;
    }
    state.argn = (state.argn << 4) + digit;
    state.counter -= 1;
    if (state.counter == 0) {
        if (state.argn > 0x10ffff) {
            parser.@"error" = "invalid unicode codepoint";
            return 1;
        }
        writeCodepoint(parser, state.argn);
        state.argn = 0;
        state.consumer = @ptrCast(&janet_zig_parser_stringchar);
    }
    return 1;
}

fn janet_zig_parser_longstringImpl(
    parser: *c.JanetParser,
    state: *c.JanetParseState,
    character: u8,
) raise.Raising(c_int) {
    if (state.flags & in_string != 0) {
        if (character == '`') {
            state.flags |= end_candidate;
            state.flags &= ~@as(c_int, in_string);
            state.counter = 1;
        } else {
            janet_zig_parser_push_buf(parser, character);
        }
        return 1;
    }
    if (state.flags & end_candidate != 0) {
        if (state.counter == state.argn) {
            _ = try finishString(parser, state);
            return 0;
        }
        if (character == '`' and state.counter < state.argn) {
            state.counter += 1;
            return 1;
        }
        var index: i32 = 0;
        while (index < state.counter) : (index += 1) janet_zig_parser_push_buf(parser, '`');
        janet_zig_parser_push_buf(parser, character);
        state.counter = 0;
        state.flags &= ~@as(c_int, end_candidate);
        state.flags |= in_string;
        return 1;
    }

    state.argn += 1;
    if (character != '`') {
        state.flags |= in_string;
        janet_zig_parser_push_buf(parser, character);
    }
    return 1;
}

export fn janet_zig_parser_longstring(
    parser: *c.JanetParser,
    state: *c.JanetParseState,
    character: u8,
) callconv(.c) c_int {
    return raise.reported(janet_zig_parser_longstringImpl(parser, state, character));
}

export fn janet_zig_parser_tokenchar(
    parser: *c.JanetParser,
    state: *c.JanetParseState,
    character: u8,
) callconv(.c) c_int {
    if (janet_is_symbol_char(character) != 0) {
        janet_zig_parser_push_buf(parser, character);
        if (character > 127) state.argn = 1;
        return 1;
    }

    const length: i32 = @intCast(parser.bufcount);
    const starts_with_digit = parser.buf[0] >= '0' and parser.buf[0] <= '9';
    const starts_with_number = starts_with_digit or
        parser.buf[0] == '-' or parser.buf[0] == '+' or parser.buf[0] == '.';
    var value: c.Janet = undefined;
    var parsed_number = false;

    if (parser.buf[0] == ':') {
        if (state.argn != 0 and janet_valid_utf8(parser.buf + 1, length - 1) == 0) {
            parser.@"error" = "invalid utf-8 in keyword";
            return 0;
        }
        value = c.janet_wrap_keyword(c.janet_symbol(parser.buf + 1, length - 1));
    } else {
        if (starts_with_number) {
            if (@hasDecl(c, "janet_scan_numeric")) {
                parsed_number = c.janet_scan_numeric(parser.buf, length, &value) == 0;
            } else {
                var number: f64 = undefined;
                if (c.janet_scan_number(parser.buf, length, &number) == 0) {
                    value = c.janet_wrap_number(number);
                    parsed_number = true;
                }
            }
        }

        if (!parsed_number) {
            if (tokenEquals(parser.buf, parser.bufcount, "nil")) {
                value = c.janet_wrap_nil();
            } else if (tokenEquals(parser.buf, parser.bufcount, "false")) {
                value = c.janet_wrap_false();
            } else if (tokenEquals(parser.buf, parser.bufcount, "true")) {
                value = c.janet_wrap_true();
            } else {
                if (starts_with_digit) {
                    parser.@"error" = "symbol literal cannot start with a digit";
                    return 0;
                }
                if (state.argn != 0 and janet_valid_utf8(parser.buf, length) == 0) {
                    parser.@"error" = "invalid utf-8 in symbol";
                    return 0;
                }
                value = c.janet_wrap_symbol(c.janet_symbol(parser.buf, length));
            }
        }
    }

    parser.bufcount = 0;
    janet_zig_parser_pop_state(parser, value);
    return 0;
}

export fn janet_zig_parser_comment(
    parser: *c.JanetParser,
    _: *c.JanetParseState,
    character: u8,
) callconv(.c) c_int {
    if (character == '\n') {
        parser.statecount -= 1;
        parser.bufcount = 0;
    } else {
        janet_zig_parser_push_buf(parser, character);
    }
    return 1;
}

export fn janet_zig_parser_atsign(
    parser: *c.JanetParser,
    _: *c.JanetParseState,
    character: u8,
) callconv(.c) c_int {
    parser.statecount -= 1;
    switch (character) {
        '{' => janet_zig_parser_push_state(parser, @ptrCast(&janet_zig_parser_root), container | curly_brackets | at_symbol),
        '"' => janet_zig_parser_push_state(parser, @ptrCast(&janet_zig_parser_stringchar), buffer | string),
        '`' => janet_zig_parser_push_state(parser, @ptrCast(&janet_zig_parser_longstring), buffer | long_string),
        '[' => janet_zig_parser_push_state(parser, @ptrCast(&janet_zig_parser_root), container | square_brackets | at_symbol),
        '(' => janet_zig_parser_push_state(parser, @ptrCast(&janet_zig_parser_root), container | parens | at_symbol),
        else => {
            janet_zig_parser_push_state(parser, @ptrCast(&janet_zig_parser_tokenchar), token);
            janet_zig_parser_push_buf(parser, '@');
            return 0;
        },
    }
    return 1;
}

export fn janet_zig_parser_root(
    parser: *c.JanetParser,
    state: *c.JanetParseState,
    character: u8,
) callconv(.c) c_int {
    switch (character) {
        '\'', ',', ';', '~', '|' => {
            janet_zig_parser_push_state(parser, @ptrCast(&janet_zig_parser_root), reader_macro | character);
            return 1;
        },
        '"' => {
            janet_zig_parser_push_state(parser, @ptrCast(&janet_zig_parser_stringchar), string);
            return 1;
        },
        '#' => {
            janet_zig_parser_push_state(parser, @ptrCast(&janet_zig_parser_comment), comment);
            return 1;
        },
        '@' => {
            janet_zig_parser_push_state(parser, @ptrCast(&janet_zig_parser_atsign), at_symbol);
            return 1;
        },
        '`' => {
            janet_zig_parser_push_state(parser, @ptrCast(&janet_zig_parser_longstring), long_string);
            return 1;
        },
        ')', ']', '}' => return raise.reported(closeDelimiter(parser, state, character)),
        '(' => {
            janet_zig_parser_push_state(parser, @ptrCast(&janet_zig_parser_root), container | parens);
            return 1;
        },
        '[' => {
            janet_zig_parser_push_state(parser, @ptrCast(&janet_zig_parser_root), container | square_brackets);
            return 1;
        },
        '{' => {
            janet_zig_parser_push_state(parser, @ptrCast(&janet_zig_parser_root), container | curly_brackets);
            return 1;
        },
        else => {
            if (isWhitespace(character)) return 1;
            if (janet_is_symbol_char(character) == 0) {
                parser.@"error" = "unexpected character";
                return 1;
            }
            janet_zig_parser_push_state(parser, @ptrCast(&janet_zig_parser_tokenchar), token);
            return 0;
        },
    }
}

fn closeDelimiter(parser: *c.JanetParser, state: *c.JanetParseState, character: u8) raise.Raising(c_int) {
    if (parser.statecount == 1) {
        try delimError(parser, 0, character, "unexpected closing delimiter ");
        return 1;
    }

    var value: c.Janet = undefined;
    if ((character == ')' and state.flags & parens != 0) or
        (character == ']' and state.flags & square_brackets != 0))
    {
        value = if (state.flags & at_symbol != 0)
            janet_zig_parser_close_array(parser, state)
        else
            janet_zig_parser_close_tuple(
                parser,
                state,
                if (character == ']') c.JANET_TUPLE_FLAG_BRACKETCTOR else 0,
            );
    } else if (character == '}' and state.flags & curly_brackets != 0) {
        if (state.argn & 1 != 0) {
            parser.@"error" = "struct and table literals expect even number of arguments";
            return 1;
        }
        value = if (state.flags & at_symbol != 0)
            janet_zig_parser_close_table(parser, state)
        else
            janet_zig_parser_close_struct(parser, state);
    } else {
        try delimError(parser, parser.statecount - 1, character, "mismatched delimiter ");
        return 1;
    }
    janet_zig_parser_pop_state(parser, value);
    return 1;
}

fn isWhitespace(character: u8) bool {
    return switch (character) {
        ' ', '\t', '\n', '\r', 0, 11, 12 => true,
        else => false,
    };
}

fn tokenEquals(bytes: [*c]const u8, length: usize, comptime expected: []const u8) bool {
    if (length != expected.len) return false;
    for (expected, 0..) |character, index| {
        if (bytes[index] != character) return false;
    }
    return true;
}

fn finishString(parser: *c.JanetParser, state: *c.JanetParseState) raise.Raising(c_int) {
    var start: usize = 0;
    var length = parser.bufcount;

    if (state.flags & long_string != 0) {
        const indent_column: i32 = @as(i32, @intCast(parser.states[parser.statecount - 1].column)) - 1;
        var read: usize = 0;
        var reindent = true;

        while (reindent and read < length) {
            const character = parser.buf[read];
            read += 1;
            if (character == '\n') {
                var column: i32 = 0;
                while (read < length and parser.buf[read] != '\n' and column < indent_column) : (column += 1) {
                    if (parser.buf[read] != ' ') {
                        reindent = false;
                        break;
                    }
                    read += 1;
                }
                if (read + 1 < length and parser.buf[read] == '\r' and parser.buf[read + 1] == '\n') {
                    reindent = true;
                }
            }
        }

        if (reindent) {
            var write: usize = 0;
            read = 0;
            while (read < length) {
                if (parser.buf[read] == '\n') {
                    parser.buf[write] = parser.buf[read];
                    write += 1;
                    read += 1;
                    var column: i32 = 0;
                    while (read < length and parser.buf[read] != '\n' and column < indent_column) : (column += 1) {
                        read += 1;
                    }
                    if (read + 1 < length and parser.buf[read] == '\r' and parser.buf[read + 1] == '\n') {
                        parser.buf[write] = parser.buf[read];
                        write += 1;
                        read += 1;
                    }
                } else {
                    parser.buf[write] = parser.buf[read];
                    write += 1;
                    read += 1;
                }
            }
            length = write;
        }

        if (length > 1 and parser.buf[0] == '\r' and parser.buf[1] == '\n') {
            start = 2;
            length -= 2;
        } else if (length > 0 and parser.buf[0] == '\n') {
            start = 1;
            length -= 1;
        }
        if (length > 1 and parser.buf[start + length - 2] == '\r' and parser.buf[start + length - 1] == '\n') {
            length -= 2;
        } else if (length > 0 and parser.buf[start + length - 1] == '\n') {
            length -= 1;
        }
    }

    const value = if (state.flags & buffer != 0) value: {
        const result = c.janet_buffer(@intCast(length));
        try containers.bufferPushBytes(result, parser.buf + start, @intCast(length));
        break :value c.janet_wrap_buffer(result);
    } else c.janet_wrap_string(c.janet_string(parser.buf + start, @intCast(length)));

    parser.bufcount = 0;
    janet_zig_parser_pop_state(parser, value);
    return 1;
}

fn setSource(original_value: c.Janet, line: usize, column: usize) c.Janet {
    const value = original_value;
    if (c.janet_checktype(value, c.JANET_TUPLE) != 0) {
        const head = c.janet_tuple_head(c.janet_unwrap_tuple(value));
        head.*.sm_line = @intCast(line);
        head.*.sm_column = @intCast(column);
    }
    return value;
}

fn wrapRoot(original_value: c.Janet, line: usize, column: usize) c.Janet {
    var value = original_value;
    const tuple = c.janet_tuple_n(&value, 1);
    const head = c.janet_tuple_head(tuple);
    head.*.sm_line = @intCast(line);
    head.*.sm_column = @intCast(column);
    return c.janet_wrap_tuple(tuple);
}

fn wrapReader(original_value: c.Janet, character: c_int, line: usize, column: usize) c.Janet {
    const tuple = c.janet_tuple_begin(2);
    const name: [*c]const u8 = switch (character) {
        '\'' => "quote",
        ',' => "unquote",
        ';' => "splice",
        '|' => "short-fn",
        '~' => "quasiquote",
        else => "<unknown>",
    };
    tuple[0] = c.janet_wrap_symbol(c.janet_csymbol(name));
    tuple[1] = original_value;
    const head = c.janet_tuple_head(tuple);
    head.*.sm_line = @intCast(line);
    head.*.sm_column = @intCast(column);
    return c.janet_wrap_tuple(c.janet_tuple_end(tuple));
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

fn writeCodepoint(parser: *c.JanetParser, codepoint: i32) void {
    if (codepoint <= 0x7f) {
        janet_zig_parser_push_buf(parser, @intCast(codepoint));
    } else if (codepoint <= 0x7ff) {
        janet_zig_parser_push_buf(parser, @intCast(((codepoint >> 6) & 0x1f) | 0xc0));
        janet_zig_parser_push_buf(parser, @intCast((codepoint & 0x3f) | 0x80));
    } else if (codepoint <= 0xffff) {
        janet_zig_parser_push_buf(parser, @intCast(((codepoint >> 12) & 0x0f) | 0xe0));
        janet_zig_parser_push_buf(parser, @intCast(((codepoint >> 6) & 0x3f) | 0x80));
        janet_zig_parser_push_buf(parser, @intCast((codepoint & 0x3f) | 0x80));
    } else {
        janet_zig_parser_push_buf(parser, @intCast(((codepoint >> 18) & 0x07) | 0xf0));
        janet_zig_parser_push_buf(parser, @intCast(((codepoint >> 12) & 0x3f) | 0x80));
        janet_zig_parser_push_buf(parser, @intCast(((codepoint >> 6) & 0x3f) | 0x80));
        janet_zig_parser_push_buf(parser, @intCast((codepoint & 0x3f) | 0x80));
    }
}

export fn janet_parser_status(parser: *c.JanetParser) callconv(.c) c.JanetParserStatus {
    if (parser.@"error" != null) return c.JANET_PARSE_ERROR;
    if (parser.flag != 0) return c.JANET_PARSE_DEAD;
    if (parser.statecount > 1) return c.JANET_PARSE_PENDING;
    return c.JANET_PARSE_ROOT;
}

export fn janet_parser_flush(parser: *c.JanetParser) callconv(.c) void {
    parser.argcount = 0;
    parser.statecount = 1;
    parser.bufcount = 0;
    parser.pending = 0;
}

export fn janet_parser_error(parser: *c.JanetParser) callconv(.c) [*c]const u8 {
    if (janet_parser_status(parser) != c.JANET_PARSE_ERROR) return null;
    const message = parser.@"error";
    parser.@"error" = null;
    parser.flag &= ~@as(c_int, parser_generated_error);
    janet_parser_flush(parser);
    return message;
}

export fn janet_parser_produce(parser: *c.JanetParser) callconv(.c) c.Janet {
    if (parser.pending == 0) return c.janet_wrap_nil();
    const result = c.janet_unwrap_tuple(parser.args[0])[0];
    shiftArguments(parser);
    return result;
}

export fn janet_parser_produce_wrapped(parser: *c.JanetParser) callconv(.c) c.Janet {
    if (parser.pending == 0) return c.janet_wrap_nil();
    const result = parser.args[0];
    shiftArguments(parser);
    return result;
}

export fn janet_parser_init(parser: *c.JanetParser) callconv(.c) void {
    parser.* = .{
        .args = null,
        .@"error" = null,
        .states = null,
        .buf = null,
        .argcount = 0,
        .argcap = 0,
        .statecount = 0,
        .statecap = 0,
        .bufcount = 0,
        .bufcap = 0,
        .line = 1,
        .column = 0,
        .pending = 0,
        .lookback = -1,
        .flag = 0,
    };
    const memory = c.janet_realloc(null, 2 * @sizeOf(c.JanetParseState)) orelse c.janet_zig_out_of_memory();
    parser.states = @ptrCast(@alignCast(memory));
    parser.statecap = 2;
    parser.statecount = 1;
    parser.states[0] = .{
        .counter = 0,
        .argn = 0,
        .flags = container,
        .line = parser.line,
        .column = parser.column,
        .consumer = @ptrCast(&janet_zig_parser_root),
    };
}

export fn janet_parser_deinit(parser: *c.JanetParser) callconv(.c) void {
    c.janet_free(parser.args);
    c.janet_free(parser.buf);
    c.janet_free(parser.states);
}

export fn janet_parser_clone(source: *const c.JanetParser, destination: *c.JanetParser) callconv(.c) void {
    destination.* = .{
        .args = null,
        .@"error" = source.@"error",
        .states = null,
        .buf = null,
        .argcount = source.argcount,
        .argcap = source.argcount,
        .statecount = source.statecount,
        .statecap = source.statecount,
        .bufcount = source.bufcount,
        .bufcap = source.bufcount,
        .line = source.line,
        .column = source.column,
        .pending = source.pending,
        .lookback = source.lookback,
        .flag = source.flag,
    };
    if (destination.bufcap != 0) {
        destination.buf = allocate(u8, destination.bufcap);
        @memcpy(destination.buf[0..destination.bufcap], source.buf[0..destination.bufcap]);
    }
    if (destination.argcap != 0) {
        destination.args = allocate(c.Janet, destination.argcap);
        @memcpy(destination.args[0..destination.argcap], source.args[0..destination.argcap]);
    }
    if (destination.statecap != 0) {
        destination.states = allocate(c.JanetParseState, destination.statecap);
        @memcpy(destination.states[0..destination.statecap], source.states[0..destination.statecap]);
    }
}

export fn janet_parser_has_more(parser: *c.JanetParser) callconv(.c) c_int {
    return @intFromBool(parser.pending != 0);
}

fn shiftArguments(parser: *c.JanetParser) void {
    var index: usize = 1;
    while (index < parser.argcount) : (index += 1) parser.args[index - 1] = parser.args[index];
    parser.pending -= 1;
    parser.argcount -= 1;
    parser.states[0].argn -= 1;
}

fn allocate(comptime Element: type, count: usize) [*c]Element {
    const memory = c.janet_malloc(@sizeOf(Element) * count) orelse c.janet_zig_out_of_memory();
    return @ptrCast(@alignCast(memory));
}

fn growAndPush(
    comptime Element: type,
    items: *[*c]Element,
    count: *usize,
    capacity: *usize,
    value: Element,
) void {
    const new_count = count.* + 1;
    if (new_count > capacity.*) {
        const new_capacity = 2 * new_count;
        const memory = c.janet_realloc(items.*, @sizeOf(Element) * new_capacity) orelse c.janet_zig_out_of_memory();
        items.* = @ptrCast(@alignCast(memory));
        capacity.* = new_capacity;
    }
    items.*[count.*] = value;
    count.* = new_count;
}

// ==========================================================================
// Errors, and the parser's raise perimeter
//
// The parser reports two different ways and the difference matters. A *parse*
// error is data: it goes into `parser->error`, `parser/status` answers
// `:error`, and the caller decides what to do. A *use* error -- feeding bytes
// to a parser that has already finished -- is a panic, because there is no
// sensible value to answer with.
//
// Until Phase 10 Part 7 both halves lived in C: `janet_parser_consume` was a
// C function that checked and panicked before calling the Zig engine, because
// a Zig frame could not raise. Phase 10's first decision retires that, and
// `raise.deliver` is what a `JANET_NO_RETURN` entry point uses.
// ==========================================================================

/// Build the "unexpected closing delimiter" / "mismatched delimiter" /
/// "unexpected end of source" message, naming where the unclosed form opened.
///
/// The result is a Janet string stored in `parser->error`, which is why
/// `JANET_PARSER_GENERATED_ERROR` is set: the field is a `const char *` that
/// usually points at a literal, and the flag is what tells `parsermark` to
/// trace it and `parser/error` to return it as a string rather than re-intern
/// it.
fn delimError(
    parser: *c.JanetParser,
    stack_index: usize,
    character: u8,
    message: [*c]const u8,
) raise.Raising(void) {
    const state = &parser.states[stack_index];
    const text = c.janet_buffer(40);
    if (message != null) try containers.bufferPushCString(text, message);
    if (character != 0) try containers.bufferPushU8(text, character);
    if (stack_index > 0) {
        try containers.bufferPushCString(text, ", ");
        if (state.flags & parens != 0) {
            try containers.bufferPushU8(text, '(');
        } else if (state.flags & square_brackets != 0) {
            try containers.bufferPushU8(text, '[');
        } else if (state.flags & curly_brackets != 0) {
            try containers.bufferPushU8(text, '{');
        } else if (state.flags & string != 0) {
            try containers.bufferPushU8(text, '"');
        } else if (state.flags & long_string != 0) {
            var index: i32 = 0;
            while (index < state.argn) : (index += 1) try containers.bufferPushU8(text, '`');
        }
        _ = try pp_format.formatb(text, " opened at line %d, column %d", .{ @as(i32, @intCast(state.line)), @as(i32, @intCast(state.column)) });
    }
    parser.@"error" = @ptrCast(c.janet_string(text.*.data, text.*.count));
    parser.flag |= parser_generated_error;
}

/// A parser that has hit EOF or is holding an unread error cannot be fed.
fn checkDead(parser: *c.JanetParser) raise.Raising(void) {
    if (parser.flag != 0) return raise.panic("parser is dead, cannot consume");
    if (parser.@"error" != null) return raise.panic("parser has unchecked error, cannot consume");
}

const consumeFace = raise.panicking(consumeChecked).face;
const eofFace = raise.panicking(eofChecked).face;

pub fn consumeChecked(parser: *c.JanetParser, character: u8) raise.Raising(void) {
    try checkDead(parser);
    janet_zig_parser_consume(parser, character);
}

pub fn eofChecked(parser: *c.JanetParser) raise.Raising(void) {
    try checkDead(parser);
    try parserEof(parser);
}

comptime {
    @export(&consumeFace, .{ .name = "janet_parser_consume" });
    @export(&eofFace, .{ .name = "janet_parser_eof" });
}

// ==========================================================================
// The parser as an abstract type
// ==========================================================================

fn parserMark(pointer: ?*anyopaque, size: usize) callconv(.c) c_int {
    _ = size;
    const parser: *c.JanetParser = @ptrCast(@alignCast(pointer));
    var index: usize = 0;
    while (index < parser.argcount) : (index += 1) c.janet_mark(parser.args[index]);
    // Only a generated message is a Janet string; a literal must not be traced.
    if (parser.flag & parser_generated_error != 0) {
        c.janet_mark(c.janet_wrap_string(@ptrCast(parser.@"error")));
    }
    return 0;
}

fn parserGC(pointer: ?*anyopaque, size: usize) callconv(.c) c_int {
    _ = size;
    janet_parser_deinit(@ptrCast(@alignCast(pointer)));
    return 0;
}

fn parserGet(pointer: ?*anyopaque, key: c.Janet, out: [*c]c.Janet) raise.Raising(c_int) {
    _ = pointer;
    if (c.janet_checktype(key, c.JANET_KEYWORD) == 0) return 0;
    return c.janet_getmethod(c.janet_unwrap_keyword(key), @ptrCast(&methods), out);
}

fn parserNext(pointer: ?*anyopaque, key: c.Janet) raise.Raising(c.Janet) {
    _ = pointer;
    return c.janet_nextmethod(@ptrCast(&methods), key);
}

export const janet_parser_type: abstract_type.AbstractType = .{
    .name = "core/parser",
    .gc = parserGC,
    .gcmark = parserMark,
    .get = parserGet,
    .put = null,
    .marshal = null,
    .unmarshal = null,
    .tostring = null,
    .compare = null,
    .hash = null,
    .next = parserNext,
    .call = null,
    .length = null,
    .bytes = null,
};

fn getParser(argv: [*c]c.Janet, n: i32) raise.Raising(*c.JanetParser) {
    return @ptrCast(@alignCast(try arglayer.getAbstract(argv, n, abstract_type.stored(&janet_parser_type))));
}

// ==========================================================================
// The cfunction surface
// ==========================================================================

fn cfunParserNew(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    _ = argv;
    try arglayer.fixarity(argc, 0);
    const parser: *c.JanetParser = @ptrCast(@alignCast(c.janet_abstract(abstract_type.stored(&janet_parser_type), @sizeOf(c.JanetParser))));
    janet_parser_init(parser);
    return c.janet_wrap_abstract(parser);
}

fn cfunParserConsume(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 2, 3);
    const parser = try getParser(argv, 0);
    var view = try arglayer.getBytes(argv, 1);
    if (argc == 3) {
        const offset = try arglayer.getInteger(argv, 2);
        if (offset < 0 or offset > view.len) {
            return pp_format.panicf("invalid offset %d out of range [0,%d]", .{ offset, view.len });
        }
        view.len -= offset;
        view.bytes += @intCast(offset);
    }
    var index: i32 = 0;
    while (index < view.len) : (index += 1) {
        try consumeChecked(parser, view.bytes[@intCast(index)]);
        switch (janet_parser_status(parser)) {
            c.JANET_PARSE_ROOT, c.JANET_PARSE_PENDING => {},
            // A dead or errored parser stops the loop, and the count reported
            // includes the byte that stopped it.
            else => return wrapInteger(index + 1),
        }
    }
    return wrapInteger(index);
}

fn cfunParserEof(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    try eofChecked(try getParser(argv, 0));
    return argv[0];
}

fn cfunParserInsert(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 2);
    const parser = try getParser(argv, 0);
    var state = &parser.states[parser.statecount - 1];
    // A token in progress is terminated first, and the space that terminates
    // it is un-counted so the column still points at the inserted value.
    if (state.flags & token != 0) {
        try consumeChecked(parser, ' ');
        parser.column -= 1;
        state = &parser.states[parser.statecount - 1];
    }
    if (state.flags & comment != 0) state = @ptrCast(@as([*]c.JanetParseState, @ptrCast(state)) - 1);
    if (state.flags & container != 0) {
        state.argn += 1;
        if (parser.statecount == 1) {
            parser.pending += 1;
            janet_zig_parser_push_arg(parser, c.janet_wrap_tuple(c.janet_tuple_n(argv + 1, 1)));
        } else {
            janet_zig_parser_push_arg(parser, argv[1]);
        }
    } else if (state.flags & (string | long_string) != 0) {
        const text = c.janet_to_string(argv[1]);
        const length: usize = @intCast(c.janet_string_length(text));
        const new_count = parser.bufcount + length;
        if (parser.bufcap < new_count) {
            const new_capacity = 2 * new_count;
            const memory = c.janet_realloc(parser.buf, new_capacity) orelse c.janet_zig_out_of_memory();
            parser.buf = @ptrCast(@alignCast(memory));
            parser.bufcap = new_capacity;
        }
        if (length != 0) @memcpy(parser.buf[parser.bufcount..new_count], text[0..length]);
        parser.bufcount = new_count;
    } else {
        return raise.panic("cannot insert value into parser");
    }
    return argv[0];
}

fn cfunParserHasMore(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    return c.janet_wrap_boolean(janet_parser_has_more(try getParser(argv, 0)));
}

fn cfunParserByte(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 2);
    const parser = try getParser(argv, 0);
    const value = try arglayer.getInteger(argv, 1);
    try consumeChecked(parser, @intCast(0xFF & value));
    return argv[0];
}

fn cfunParserStatus(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    const name: [*c]const u8 = switch (janet_parser_status(try getParser(argv, 0))) {
        c.JANET_PARSE_PENDING => "pending",
        c.JANET_PARSE_ERROR => "error",
        c.JANET_PARSE_ROOT => "root",
        c.JANET_PARSE_DEAD => "dead",
        else => null,
    };
    return c.janet_ckeywordv(name);
}

fn cfunParserError(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    const parser = try getParser(argv, 0);
    const message = janet_parser_error(parser);
    if (message == null) return c.janet_wrap_nil();
    // A generated message is already an interned Janet string; a literal has
    // to be interned now.
    return if (parser.flag & parser_generated_error != 0)
        c.janet_wrap_string(@ptrCast(message))
    else
        c.janet_cstringv(message);
}

fn cfunParserProduce(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 1, 2);
    const parser = try getParser(argv, 0);
    if (argc == 2 and c.janet_truthy(argv[1]) != 0) {
        return janet_parser_produce_wrapped(parser);
    }
    return janet_parser_produce(parser);
}

fn cfunParserFlush(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    janet_parser_flush(try getParser(argv, 0));
    return argv[0];
}

fn cfunParserWhere(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 1, 3);
    const parser = try getParser(argv, 0);
    if (argc > 1) {
        const line = try arglayer.getInteger(argv, 1);
        if (line < 1) return pp_format.panicf("invalid line number %d", .{line});
        parser.line = @intCast(line);
    }
    if (argc > 2) {
        const column = try arglayer.getInteger(argv, 2);
        if (column < 0) return pp_format.panicf("invalid column number %d", .{column});
        parser.column = @intCast(column);
    }
    const tuple = c.janet_tuple_begin(2);
    tuple[0] = wrapInteger(@intCast(parser.line));
    tuple[1] = wrapInteger(@intCast(parser.column));
    return c.janet_wrap_tuple(c.janet_tuple_end(tuple));
}

/// One frame of `(parser/state p :frames)`: what is being parsed, where it
/// started, and what has been read into it so far.
fn wrapParseState(
    state: *allowzero const c.JanetParseState,
    args: [*c]c.Janet,
    buf: [*c]u8,
    bufcount: u32,
) raise.Raising(c.Janet) {
    const table = c.janet_table(0);
    var add_buffer = false;

    if (state.flags & container != 0) {
        const container_args = c.janet_array(state.argn);
        var index: i32 = 0;
        while (index < state.argn) : (index += 1) try containers.arrayPush(container_args, args[@intCast(index)]);
        c.janet_table_put(table, c.janet_ckeywordv("args"), c.janet_wrap_array(container_args));
    }

    const kind: [*c]const u8 = if (state.flags & (parens | square_brackets) != 0)
        (if (state.flags & at_symbol != 0) "array" else "tuple")
    else if (state.flags & curly_brackets != 0)
        (if (state.flags & at_symbol != 0) "table" else "struct")
    else if (state.flags & (string | long_string) != 0) blk: {
        add_buffer = true;
        break :blk if (state.flags & buffer != 0) "buffer" else "string";
    } else if (state.flags & comment != 0) blk: {
        add_buffer = true;
        break :blk "comment";
    } else if (state.flags & token != 0) blk: {
        add_buffer = true;
        break :blk "token";
    } else if (state.flags & at_symbol != 0)
        "at"
    else if (state.flags & reader_macro != 0) switch (state.flags & 0xFF) {
        '\'' => "quote",
        ',' => "unquote",
        ';' => "splice",
        '~' => "quasiquote",
        else => "<reader>",
    } else "root";

    c.janet_table_put(table, c.janet_ckeywordv("type"), c.janet_ckeywordv(kind));
    if (add_buffer) {
        c.janet_table_put(table, c.janet_ckeywordv("buffer"), c.janet_wrap_string(c.janet_string(buf, @intCast(bufcount))));
    }
    c.janet_table_put(table, c.janet_ckeywordv("line"), wrapInteger(@intCast(state.line)));
    c.janet_table_put(table, c.janet_ckeywordv("column"), wrapInteger(@intCast(state.column)));
    return c.janet_wrap_table(table);
}

/// `(parser/state p :delimiters)`: one byte per open form, outermost first.
///
/// The characters are pushed onto the parser's own buffer and the count is put
/// back afterwards, so this reads as a mutation and is not one. That is the C
/// original's trick and it is kept: the buffer is the one scratch area the
/// parser already owns and is already sized for.
/// Declares an error it never returns, which Phase 10's fourth rule would
/// normally forbid. The reason it is right here is the table below: two getters
/// of different shapes need one signature to sit in one array, and
/// `parserStateFrames` genuinely raises. The alternative is a tagged union over
/// two function types, which is more machinery than the fact deserves.
fn parserStateDelimiters(parser: *c.JanetParser) raise.Raising(c.Janet) {
    const old_count = parser.bufcount;
    var index: usize = 0;
    while (index < parser.statecount) : (index += 1) {
        const state = &parser.states[index];
        if (state.flags & parens != 0) {
            janet_zig_parser_push_buf(parser, '(');
        } else if (state.flags & square_brackets != 0) {
            janet_zig_parser_push_buf(parser, '[');
        } else if (state.flags & curly_brackets != 0) {
            janet_zig_parser_push_buf(parser, '{');
        } else if (state.flags & string != 0) {
            janet_zig_parser_push_buf(parser, '"');
        } else if (state.flags & long_string != 0) {
            var tick: i32 = 0;
            while (tick < state.argn) : (tick += 1) janet_zig_parser_push_buf(parser, '`');
        }
    }
    const text = c.janet_string(
        if (old_count != 0) parser.buf + old_count else parser.buf,
        @intCast(parser.bufcount - old_count),
    );
    parser.bufcount = old_count;
    return c.janet_wrap_string(text);
}

/// `(parser/state p :frames)`, innermost frame last.
///
/// The walk runs backwards because a container frame's arguments sit at the
/// end of one shared array and their extent is only known by subtracting each
/// frame's count in turn.
fn parserStateFrames(parser: *c.JanetParser) raise.Raising(c.Janet) {
    const count: i32 = @intCast(parser.statecount);
    const states = c.janet_array(count);
    states.*.count = count;
    // Avoid pointer arithmetic on NULL, which `args` is until something is
    // pushed.
    var args: [*c]c.Janet = if (parser.argcount != 0) parser.args + parser.argcount else parser.args;
    var index = count - 1;
    while (index >= 0) : (index -= 1) {
        const state = &parser.states[@intCast(index)];
        if (state.flags & container != 0 and state.argn != 0) args -= @as(usize, @intCast(state.argn));
        states.*.data[@intCast(index)] = try wrapParseState(state, args, parser.buf, @intCast(parser.bufcount));
    }
    return c.janet_wrap_array(states);
}

const StateGetter = struct {
    name: [:0]const u8,
    get: *const fn (*c.JanetParser) raise.Raising(c.Janet),
};

const state_getters = [_]StateGetter{
    .{ .name = "frames", .get = parserStateFrames },
    .{ .name = "delimiters", .get = parserStateDelimiters },
};

fn cfunParserState(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 1, 2);
    const parser = try getParser(argv, 0);
    if (argc == 2) {
        const key = try arglayer.getKeyword(argv, 1);
        for (state_getters) |getter| {
            if (c.janet_cstrcmp(key, getter.name) == 0) return getter.get(parser);
        }
        return pp_format.panicf("unexpected keyword %v", .{c.janet_wrap_keyword(key)});
    }
    const table = c.janet_table(0);
    for (state_getters) |getter| {
        c.janet_table_put(table, c.janet_ckeywordv(getter.name), try getter.get(parser));
    }
    return c.janet_wrap_table(table);
}

fn cfunParserClone(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    const source = try getParser(argv, 0);
    const destination: *c.JanetParser = @ptrCast(@alignCast(c.janet_abstract(abstract_type.stored(&janet_parser_type), @sizeOf(c.JanetParser))));
    janet_parser_clone(source, destination);
    return c.janet_wrap_abstract(destination);
}

/// Lexicographic order, which is not a lookup requirement: `janet_getmethod`
/// scans linearly. It is the *iteration* order, because `janet_nextmethod`
/// walks the same table, so `(keys p)` and `next` report the methods in the
/// order they are written here.
const methods = [_]corefn.Method{
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

export fn janet_lib_parse(env: *c.JanetTable) callconv(.c) void {
    const entries = [_]corefn.Entry{
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
        corefn.end,
    };
    corefn.install(env, &entries);
}
