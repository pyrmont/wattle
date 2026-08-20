#include <assert.h>
#include <stdint.h>
#include <string.h>
#include <janet.h>

static Janet get_field(JanetStruct structure, const char *name) {
    return janet_struct_get(structure, janet_ckeywordv(name));
}

static void assert_integer(Janet value, int32_t expected) {
    assert(janet_checktype(value, JANET_NUMBER));
    assert(janet_unwrap_integer(value) == expected);
}

static void assert_string(Janet value, const char *expected) {
    assert(janet_checktype(value, JANET_STRING));
    assert(!janet_cstrcmp(janet_unwrap_string(value), expected));
}

void disasm_contract(void) {
    JanetFuncDef definition;
    JanetFuncDef child;
    JanetFuncDef *definitions[] = {&child};
    uint32_t bytecode[] = {
        JOP_NOOP,
        JOP_LOAD_INTEGER | (UINT32_C(2) << 8) | (UINT32_C(0xFFF9) << 16)
    };
    Janet constants[2];
    JanetSourceMapping sourcemap[] = {{3, 5}, {8, 13}};
    int32_t environments[] = {4, 1};
    JanetSymbolMap symbolmap[2];
    Janet decoded;
    JanetStruct result;
    JanetArray *array;
    const Janet *tuple;

    janet_init();
    memset(&definition, 0, sizeof(definition));
    memset(&child, 0, sizeof(child));

    child.arity = 1;
    child.min_arity = 1;
    child.max_arity = 1;
    child.slotcount = 2;

    constants[0] = janet_wrap_true();
    constants[1] = janet_cstringv("constant");
    symbolmap[0].birth_pc = 0;
    symbolmap[0].death_pc = 2;
    symbolmap[0].slot_index = 3;
    symbolmap[0].symbol = janet_symbol((const uint8_t *) "local", 5);
    symbolmap[1].birth_pc = UINT32_MAX;
    symbolmap[1].death_pc = 1;
    symbolmap[1].slot_index = 0;
    symbolmap[1].symbol = janet_symbol((const uint8_t *) "captured", 8);

    definition.arity = 2;
    definition.min_arity = 1;
    definition.max_arity = 4;
    definition.slotcount = 9;
    definition.flags = JANET_FUNCDEF_FLAG_VARARG |
                       JANET_FUNCDEF_FLAG_STRUCTARG |
                       JANET_FUNCDEF_FLAG_NAMEDARGS;
    definition.named_args_count = 3;
    definition.bytecode = bytecode;
    definition.bytecode_length = 2;
    definition.constants = constants;
    definition.constants_length = 2;
    definition.sourcemap = sourcemap;
    definition.source = janet_cstring("source.janet");
    definition.name = janet_cstring("sample");
    definition.environments = environments;
    definition.environments_length = 2;
    definition.symbolmap = symbolmap;
    definition.symbolmap_length = 2;
    definition.defs = definitions;
    definition.defs_length = 1;

    decoded = janet_disasm(&definition);
    assert(janet_checktype(decoded, JANET_STRUCT));
    result = janet_unwrap_struct(decoded);

    assert_integer(get_field(result, "arity"), 2);
    assert_integer(get_field(result, "min-arity"), 1);
    assert_integer(get_field(result, "max-arity"), 4);
    assert_integer(get_field(result, "slotcount"), 9);
    assert(janet_unwrap_boolean(get_field(result, "vararg")));
    assert(janet_unwrap_boolean(get_field(result, "structarg")));
    assert_integer(get_field(result, "namedargs"), 3);
    assert_string(get_field(result, "source"), "source.janet");
    assert_string(get_field(result, "name"), "sample");

    array = janet_unwrap_array(get_field(result, "bytecode"));
    assert(array->count == 2);
    tuple = janet_unwrap_tuple(array->data[0]);
    assert(janet_tuple_length(tuple) == 1);
    assert(!janet_cstrcmp(janet_unwrap_symbol(tuple[0]), "noop"));
    tuple = janet_unwrap_tuple(array->data[1]);
    assert_integer(tuple[1], 2);
    assert_integer(tuple[2], -7);

    array = janet_unwrap_array(get_field(result, "constants"));
    assert(array->count == 2);
    assert(janet_equals(array->data[0], constants[0]));
    assert(janet_equals(array->data[1], constants[1]));

    array = janet_unwrap_array(get_field(result, "sourcemap"));
    assert(array->count == 2);
    tuple = janet_unwrap_tuple(array->data[1]);
    assert_integer(tuple[0], 8);
    assert_integer(tuple[1], 13);

    array = janet_unwrap_array(get_field(result, "environments"));
    assert(array->count == 2);
    assert_integer(array->data[0], 4);
    assert_integer(array->data[1], 1);

    array = janet_unwrap_array(get_field(result, "symbolmap"));
    assert(array->count == 2);
    tuple = janet_unwrap_tuple(array->data[0]);
    assert_integer(tuple[0], 0);
    assert_integer(tuple[1], 2);
    assert_integer(tuple[2], 3);
    assert(!janet_cstrcmp(janet_unwrap_symbol(tuple[3]), "local"));
    tuple = janet_unwrap_tuple(array->data[1]);
    assert(janet_checktype(tuple[0], JANET_KEYWORD));
    assert(!janet_cstrcmp(janet_unwrap_keyword(tuple[0]), "upvalue"));

    array = janet_unwrap_array(get_field(result, "defs"));
    assert(array->count == 1);
    assert_integer(get_field(janet_unwrap_struct(array->data[0]), "arity"), 1);

    janet_deinit();
}
