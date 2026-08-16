#include <assert.h>
#include <stdint.h>
#include <string.h>
#include <janet.h>

static const Janet *decoded_tuple(uint32_t instruction, int32_t length, const char *name) {
    Janet decoded = janet_asm_decode_instruction(instruction);
    const Janet *tuple;
    assert(janet_checktype(decoded, JANET_TUPLE));
    tuple = janet_unwrap_tuple(decoded);
    assert(janet_tuple_length(tuple) == length);
    assert(janet_checktype(tuple[0], JANET_SYMBOL));
    assert(!janet_cstrcmp(janet_unwrap_symbol(tuple[0]), name));
    return tuple;
}

static void assert_integer(Janet value, int32_t expected) {
    assert(janet_checktype(value, JANET_NUMBER));
    assert(janet_unwrap_integer(value) == expected);
}

int main(void) {
    const Janet *tuple;
    Janet unknown;

    janet_init();

    unknown = janet_asm_decode_instruction(UINT32_C(0x1234567F));
    assert(janet_checktype(unknown, JANET_NUMBER));
    assert((uint32_t) janet_unwrap_integer(unknown) == UINT32_C(0x1234567F));

    tuple = decoded_tuple(JOP_NOOP, 1, "noop");
    assert(!(janet_tuple_flag(tuple) & JANET_TUPLE_FLAG_BRACKETCTOR));

    tuple = decoded_tuple(JOP_ERROR | (UINT32_C(0x123456) << 8), 2, "err");
    assert_integer(tuple[1], 0x123456);

    tuple = decoded_tuple(JOP_JUMP | (UINT32_C(0xFFFFFE) << 8), 2, "jmp");
    assert_integer(tuple[1], -2);

    tuple = decoded_tuple(JOP_MOVE_NEAR | (UINT32_C(7) << 8) | (UINT32_C(300) << 16), 3, "movn");
    assert_integer(tuple[1], 7);
    assert_integer(tuple[2], 300);

    tuple = decoded_tuple(JOP_LOAD_INTEGER | (UINT32_C(5) << 8) | (UINT32_C(0xFFF4) << 16), 3, "ldi");
    assert_integer(tuple[1], 5);
    assert_integer(tuple[2], -12);

    tuple = decoded_tuple(JOP_ADD | (UINT32_C(3) << 8) | (UINT32_C(7) << 16) | (UINT32_C(9) << 24), 4, "add");
    assert_integer(tuple[1], 3);
    assert_integer(tuple[2], 7);
    assert_integer(tuple[3], 9);

    tuple = decoded_tuple(JOP_ADD_IMMEDIATE | (UINT32_C(3) << 8) | (UINT32_C(7) << 16) | (UINT32_C(0xFD) << 24), 4, "addim");
    assert_integer(tuple[1], 3);
    assert_integer(tuple[2], 7);
    assert_integer(tuple[3], -3);

    tuple = decoded_tuple(JOP_SHIFT_RIGHT_UNSIGNED_IMMEDIATE |
                              (UINT32_C(3) << 8) |
                              (UINT32_C(7) << 16) |
                              (UINT32_C(0xFD) << 24),
                          4,
                          "sruim");
    assert_integer(tuple[1], 3);
    assert_integer(tuple[2], 7);
    assert_integer(tuple[3], 253);

    tuple = decoded_tuple(JOP_NOOP | UINT32_C(0x80), 1, "noop");
    assert(janet_tuple_flag(tuple) & JANET_TUPLE_FLAG_BRACKETCTOR);

    janet_deinit();
    return 0;
}
