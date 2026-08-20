#include <assert.h>
#include <stdint.h>
#include <string.h>
#include <janet.h>
#include "compile.h"

void remove_noops_contract(void) {
    JanetFuncDef definition;
    JanetSourceMapping *source_map;
    JanetSymbolMap symbols[2];
    uint32_t *bytecode = janet_malloc(6 * sizeof(uint32_t));

    memset(&definition, 0, sizeof(definition));
    bytecode[0] = JOP_NOOP;
    bytecode[1] = JOP_LOAD_NIL;
    bytecode[2] = JOP_JUMP_IF | (UINT32_C(2) << 8) | (UINT32_C(3) << 16);
    bytecode[3] = JOP_NOOP;
    bytecode[4] = JOP_JUMP | ((uint32_t) -3 << 8);
    bytecode[5] = JOP_RETURN_NIL;
    source_map = janet_malloc(6 * sizeof(JanetSourceMapping));
    for (int32_t i = 0; i < 6; i++) {
        source_map[i].line = i + 10;
        source_map[i].column = i + 20;
    }
    memset(symbols, 0, sizeof(symbols));
    symbols[0].birth_pc = 1;
    symbols[0].death_pc = 5;
    symbols[1].birth_pc = UINT32_MAX;
    symbols[1].death_pc = 0;

    definition.bytecode = bytecode;
    definition.bytecode_length = 6;
    definition.sourcemap = source_map;
    definition.symbolmap = symbols;
    definition.symbolmap_length = 2;
    janet_bytecode_remove_noops(&definition);

    assert(definition.bytecode_length == 4);
    assert(definition.bytecode[0] == JOP_LOAD_NIL);
    assert(definition.bytecode[1] == (JOP_JUMP_IF | (UINT32_C(2) << 8) | (UINT32_C(2) << 16)));
    assert(definition.bytecode[2] == (JOP_JUMP | ((uint32_t) -2 << 8)));
    assert(definition.bytecode[3] == JOP_RETURN_NIL);
    assert(definition.sourcemap[0].line == 11);
    assert(definition.sourcemap[1].line == 12);
    assert(definition.sourcemap[2].line == 14);
    assert(definition.sourcemap[3].line == 15);
    assert(symbols[0].birth_pc == 0);
    assert(symbols[0].death_pc == 3);
    assert(symbols[1].birth_pc == UINT32_MAX);
    assert(symbols[1].death_pc == 0);

    janet_free(definition.bytecode);
    janet_free(source_map);

    bytecode = janet_malloc(sizeof(uint32_t));
    bytecode[0] = JOP_RETURN_NIL;
    memset(&definition, 0, sizeof(definition));
    definition.bytecode = bytecode;
    definition.bytecode_length = 1;
    janet_bytecode_remove_noops(&definition);
    assert(definition.bytecode_length == 1);
    assert(definition.bytecode[0] == JOP_RETURN_NIL);
    janet_free(definition.bytecode);
}
