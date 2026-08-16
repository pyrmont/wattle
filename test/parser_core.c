#include <assert.h>
#include <string.h>
#include <janet.h>

void janet_parser_clone(const JanetParser *src, JanetParser *dest);

static void consume(JanetParser *parser, const char *source) {
    while (*source) janet_parser_consume(parser, (uint8_t) *source++);
}

int main(void) {
    JanetParser parser;
    JanetParser clone;
    Janet value;
    const Janet *wrapped;
    const char *message;

    janet_init();

    janet_parser_init(&parser);
    assert(janet_parser_status(&parser) == JANET_PARSE_ROOT);
    assert(parser.line == 1 && parser.column == 0);
    assert(parser.statecount == 1 && parser.statecap == 2);
    assert(parser.states[0].argn == 0);
    assert(!janet_parser_has_more(&parser));

    consume(&parser, "1 2");
    janet_parser_eof(&parser);
    assert(janet_parser_status(&parser) == JANET_PARSE_DEAD);
    assert(janet_parser_has_more(&parser));
    assert(parser.pending == 2);

    janet_parser_clone(&parser, &clone);
    assert(clone.pending == parser.pending);
    assert(clone.args != parser.args);
    assert(clone.states != parser.states);

    value = janet_parser_produce(&parser);
    assert(janet_unwrap_number(value) == 1);
    value = janet_parser_produce(&parser);
    assert(janet_unwrap_number(value) == 2);
    assert(!janet_parser_has_more(&parser));

    value = janet_parser_produce_wrapped(&clone);
    assert(janet_checktype(value, JANET_TUPLE));
    wrapped = janet_unwrap_tuple(value);
    assert(janet_tuple_length(wrapped) == 1);
    assert(janet_unwrap_number(wrapped[0]) == 1);
    assert(janet_tuple_sm_line(wrapped) == 1);
    value = janet_parser_produce(&clone);
    assert(janet_unwrap_number(value) == 2);
    assert(!janet_parser_has_more(&clone));

    janet_parser_deinit(&clone);
    janet_parser_deinit(&parser);

    janet_parser_init(&parser);
    consume(&parser, "\"a\\n\\x42\\u03bb\\U01f600\" ");
    value = janet_parser_produce(&parser);
    assert(janet_checktype(value, JANET_STRING));
    {
        static const uint8_t expected[] = {'a', '\n', 'B', 0xCE, 0xBB, 0xF0, 0x9F, 0x98, 0x80};
        const uint8_t *string = janet_unwrap_string(value);
        assert(janet_string_length(string) == (int32_t) sizeof(expected));
        assert(!memcmp(string, expected, sizeof(expected)));
    }
    janet_parser_deinit(&parser);

    janet_parser_init(&parser);
    consume(&parser, "`hello` ");
    value = janet_parser_produce(&parser);
    assert(janet_checktype(value, JANET_STRING));
    assert(!strcmp((const char *) janet_unwrap_string(value), "hello"));
    janet_parser_deinit(&parser);

    janet_parser_init(&parser);
    consume(&parser, "@\"abc\" ");
    value = janet_parser_produce(&parser);
    assert(janet_checktype(value, JANET_BUFFER));
    assert(janet_unwrap_buffer(value)->count == 3);
    assert(!memcmp(janet_unwrap_buffer(value)->data, "abc", 3));
    janet_parser_deinit(&parser);

    janet_parser_init(&parser);
    consume(&parser, "\"\\q");
    assert(janet_parser_status(&parser) == JANET_PARSE_ERROR);
    assert(!strcmp(janet_parser_error(&parser), "invalid string escape sequence"));
    janet_parser_deinit(&parser);

    janet_parser_init(&parser);
    consume(&parser, "\"abc");
    assert(parser.bufcount == 3);
    janet_parser_clone(&parser, &clone);
    assert(clone.bufcount == 3);
    assert(clone.buf != parser.buf);
    assert(!memcmp(clone.buf, parser.buf, 3));
    consume(&parser, "\"");
    consume(&clone, "d\"");
    assert(!strcmp((const char *) janet_unwrap_string(janet_parser_produce(&parser)), "abc"));
    assert(!strcmp((const char *) janet_unwrap_string(janet_parser_produce(&clone)), "abcd"));
    janet_parser_deinit(&clone);
    janet_parser_deinit(&parser);

    janet_parser_init(&parser);
    consume(&parser, "((((1)))) ");
    assert(parser.statecap > 2);
    value = janet_parser_produce(&parser);
    for (int i = 0; i < 4; i++) {
        assert(janet_checktype(value, JANET_TUPLE));
        value = janet_unwrap_tuple(value)[0];
    }
    assert(janet_unwrap_number(value) == 1);
    janet_parser_deinit(&parser);

    janet_parser_init(&parser);
    consume(&parser, "'x ");
    value = janet_parser_produce(&parser);
    assert(janet_checktype(value, JANET_TUPLE));
    wrapped = janet_unwrap_tuple(value);
    assert(janet_tuple_length(wrapped) == 2);
    assert(janet_checktype(wrapped[0], JANET_SYMBOL));
    assert(!strcmp((const char *) janet_unwrap_symbol(wrapped[0]), "quote"));
    assert(!strcmp((const char *) janet_unwrap_symbol(wrapped[1]), "x"));
    assert(janet_tuple_sm_line(wrapped) == 1);
    janet_parser_deinit(&parser);

    janet_parser_init(&parser);
    consume(&parser, "(");
    assert(janet_parser_status(&parser) == JANET_PARSE_PENDING);
    janet_parser_flush(&parser);
    assert(janet_parser_status(&parser) == JANET_PARSE_ROOT);
    janet_parser_deinit(&parser);

    janet_parser_init(&parser);
    consume(&parser, ")");
    assert(janet_parser_status(&parser) == JANET_PARSE_ERROR);
    message = janet_parser_error(&parser);
    assert(message != NULL);
    assert(strstr(message, "unexpected closing delimiter") != NULL);
    assert(janet_parser_status(&parser) == JANET_PARSE_ROOT);
    assert(janet_parser_error(&parser) == NULL);
    janet_parser_deinit(&parser);

    janet_parser_init(&parser);
    consume(&parser, ":key nil false true symbol ");
    value = janet_parser_produce(&parser);
    assert(janet_checktype(value, JANET_KEYWORD));
    assert(!strcmp((const char *) janet_unwrap_keyword(value), "key"));
    assert(janet_checktype(janet_parser_produce(&parser), JANET_NIL));
    value = janet_parser_produce(&parser);
    assert(janet_checktype(value, JANET_BOOLEAN));
    assert(!janet_unwrap_boolean(value));
    value = janet_parser_produce(&parser);
    assert(janet_checktype(value, JANET_BOOLEAN));
    assert(janet_unwrap_boolean(value));
    value = janet_parser_produce(&parser);
    assert(janet_checktype(value, JANET_SYMBOL));
    assert(!strcmp((const char *) janet_unwrap_symbol(value), "symbol"));
    janet_parser_deinit(&parser);

    janet_parser_init(&parser);
    consume(&parser, "12abc ");
    assert(janet_parser_status(&parser) == JANET_PARSE_ERROR);
    assert(!strcmp(janet_parser_error(&parser), "symbol literal cannot start with a digit"));
    janet_parser_deinit(&parser);

    janet_parser_init(&parser);
    janet_parser_consume(&parser, 0xC2);
    janet_parser_consume(&parser, ' ');
    assert(janet_parser_status(&parser) == JANET_PARSE_ERROR);
    assert(!strcmp(janet_parser_error(&parser), "invalid utf-8 in symbol"));
    janet_parser_deinit(&parser);

    janet_parser_init(&parser);
    janet_parser_consume(&parser, ':');
    janet_parser_consume(&parser, 0xC2);
    janet_parser_consume(&parser, ' ');
    assert(janet_parser_status(&parser) == JANET_PARSE_ERROR);
    assert(!strcmp(janet_parser_error(&parser), "invalid utf-8 in keyword"));
    janet_parser_deinit(&parser);

    janet_deinit();
    return 0;
}
