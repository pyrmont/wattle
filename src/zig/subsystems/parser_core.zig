const c = @cImport({
    @cInclude("janet.h");
    @cInclude("runtime.h");
});

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

extern fn janet_c_parser_eof_error(parser: *c.JanetParser) callconv(.c) void;
extern fn janet_c_parser_delim_error(parser: *c.JanetParser, stack_index: usize, character: u8, message: [*c]const u8) callconv(.c) void;
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

export fn janet_zig_parser_eof(parser: *c.JanetParser) callconv(.c) void {
    const previous_column = parser.column;
    const previous_line = parser.line;
    janet_zig_parser_consume(parser, '\n');
    if (parser.statecount > 1) janet_c_parser_eof_error(parser);
    parser.line = previous_line;
    parser.column = previous_column;
    parser.flag |= parser_dead;
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

export fn janet_zig_parser_stringchar(
    parser: *c.JanetParser,
    state: *c.JanetParseState,
    character: u8,
) callconv(.c) c_int {
    if (character == '\\') {
        state.consumer = @ptrCast(&janetZigParserEscape1);
    } else if (character == '"') {
        return finishString(parser, state);
    } else if (character != '\n' and character != '\r') {
        janet_zig_parser_push_buf(parser, character);
    }
    return 1;
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

export fn janet_zig_parser_longstring(
    parser: *c.JanetParser,
    state: *c.JanetParseState,
    character: u8,
) callconv(.c) c_int {
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
            _ = finishString(parser, state);
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
        ')', ']', '}' => return closeDelimiter(parser, state, character),
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

fn closeDelimiter(parser: *c.JanetParser, state: *c.JanetParseState, character: u8) c_int {
    if (parser.statecount == 1) {
        janet_c_parser_delim_error(parser, 0, character, "unexpected closing delimiter ");
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
        janet_c_parser_delim_error(parser, parser.statecount - 1, character, "mismatched delimiter ");
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

fn finishString(parser: *c.JanetParser, state: *c.JanetParseState) c_int {
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
        c.janet_buffer_push_bytes(result, parser.buf + start, @intCast(length));
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
