#include <assert.h>
#include <stdint.h>
#include <string.h>
#include <janet.h>

static JanetFuncDef base_definition(uint32_t *bytecode, int32_t length) {
    JanetFuncDef definition;
    memset(&definition, 0, sizeof(definition));
    definition.bytecode = bytecode;
    definition.bytecode_length = length;
    definition.slotcount = 1;
    definition.arity = 1;
    return definition;
}

int main(void) {
    uint32_t bytecode[2] = {JOP_RETURN_NIL, JOP_RETURN_NIL};
    JanetFuncDef definition = base_definition(bytecode, 1);
    JanetSymbolMap symbol;
    uint8_t symbol_name[] = "x";

    assert(janet_verify(&definition) == 0);
    definition.bytecode_length = 0;
    assert(janet_verify(&definition) == 1);

    definition = base_definition(bytecode, 1);
    definition.arity = 2;
    assert(janet_verify(&definition) == 2);

    definition = base_definition(bytecode, 1);
    bytecode[0] = 0x7f;
    assert(janet_verify(&definition) == 3);
    bytecode[0] = JOP_RETURN | (UINT32_C(1) << 8);
    assert(janet_verify(&definition) == 4);
    bytecode[0] = JOP_JUMP | (UINT32_C(2) << 8);
    assert(janet_verify(&definition) == 5);

    bytecode[0] = JOP_CLOSURE | (UINT32_C(0) << 8) | (UINT32_C(1) << 16);
    assert(janet_verify(&definition) == 6);
    bytecode[0] = JOP_LOAD_CONSTANT | (UINT32_C(0) << 8) | (UINT32_C(1) << 16);
    assert(janet_verify(&definition) == 7);
    bytecode[0] = JOP_LOAD_UPVALUE | (UINT32_C(0) << 8) | (UINT32_C(1) << 16);
    assert(janet_verify(&definition) == 8);
    bytecode[0] = JOP_NOOP;
    assert(janet_verify(&definition) == 9);

    bytecode[0] = JOP_RETURN_NIL;
    memset(&symbol, 0, sizeof(symbol));
    definition.symbolmap = &symbol;
    definition.symbolmap_length = 1;
    symbol.birth_pc = UINT32_MAX;
    symbol.death_pc = 0;
    symbol.symbol = symbol_name;
    assert(janet_verify(&definition) == 10);
    symbol.birth_pc = 0;
    symbol.slot_index = 1;
    assert(janet_verify(&definition) == 11);
    symbol.slot_index = 0;
    symbol.birth_pc = 1;
    assert(janet_verify(&definition) == 12);
    symbol.birth_pc = 0;
    symbol.death_pc = 2;
    assert(janet_verify(&definition) == 13);
    symbol.death_pc = 1;
    symbol.symbol = NULL;
    assert(janet_verify(&definition) == 14);
    return 0;
}
