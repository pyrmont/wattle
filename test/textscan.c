#include <assert.h>
#include <stdint.h>
#include "util.h"

static int valid(const uint8_t *bytes, int32_t length) {
    return janet_valid_utf8(bytes, length);
}

int main(void) {
    static const uint8_t ascii[] = "janet";
    static const uint8_t two_byte[] = {0xc2, 0xa2};
    static const uint8_t three_byte[] = {0xe3, 0x81, 0x98};
    static const uint8_t four_byte[] = {0xf0, 0x9f, 0x90, 0x89};
    static const uint8_t overlong_two[] = {0xc0, 0x80};
    static const uint8_t overlong_three[] = {0xe0, 0x80, 0x80};
    static const uint8_t overlong_four[] = {0xf0, 0x80, 0x80, 0x80};
    static const uint8_t truncated[] = {0xe3, 0x81};
    static const uint8_t bad_continuation[] = {0xe3, 0x41, 0x98};
    static const uint8_t five_byte[] = {0xf8, 0x88, 0x80, 0x80, 0x80};
    static const uint8_t permissive_high[] = {0xf7, 0xbf, 0xbf, 0xbf};

    assert(valid(ascii, 5));
    assert(valid(two_byte, sizeof(two_byte)));
    assert(valid(three_byte, sizeof(three_byte)));
    assert(valid(four_byte, sizeof(four_byte)));
    assert(valid(permissive_high, sizeof(permissive_high)));
    assert(!valid(overlong_two, sizeof(overlong_two)));
    assert(!valid(overlong_three, sizeof(overlong_three)));
    assert(!valid(overlong_four, sizeof(overlong_four)));
    assert(!valid(truncated, sizeof(truncated)));
    assert(!valid(bad_continuation, sizeof(bad_continuation)));
    assert(!valid(five_byte, sizeof(five_byte)));

    assert(janet_is_symbol_char('a'));
    assert(janet_is_symbol_char('Z'));
    assert(janet_is_symbol_char('0'));
    assert(janet_is_symbol_char('-'));
    assert(janet_is_symbol_char(0x80));
    assert(!janet_is_symbol_char(' '));
    assert(!janet_is_symbol_char(','));
    assert(!janet_is_symbol_char('('));
    assert(!janet_is_symbol_char(')'));
    return 0;
}
