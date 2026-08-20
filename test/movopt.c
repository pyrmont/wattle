#include <assert.h>
#include <stdint.h>
#include <string.h>
#include <janet.h>
#include "compile.h"

static JanetFuncDef definition_for(uint32_t *bytecode, int32_t length, int32_t slots) {
    JanetFuncDef definition;
    memset(&definition, 0, sizeof(definition));
    definition.bytecode = bytecode;
    definition.bytecode_length = length;
    definition.slotcount = slots;
    return definition;
}

void movopt_contract(void) {
    uint32_t dead_load[] = {JOP_LOAD_NIL, JOP_RETURN_NIL};
    uint32_t cascading[] = {
        JOP_LOAD_NIL,
        JOP_MOVE_NEAR | (UINT32_C(1) << 8),
        JOP_RETURN_NIL
    };
    uint32_t live_load[] = {JOP_LOAD_NIL, JOP_RETURN};
    uint32_t captured_load[] = {JOP_LOAD_NIL, JOP_RETURN_NIL};
    uint32_t side_effect[] = {JOP_MAKE_BUFFER, JOP_RETURN_NIL};
    uint32_t closure_bits[] = {1};
    JanetFuncDef definition;

    definition = definition_for(dead_load, 2, 1);
    janet_bytecode_movopt(&definition);
    assert(dead_load[0] == JOP_NOOP);

    definition = definition_for(cascading, 3, 2);
    janet_bytecode_movopt(&definition);
    assert(cascading[0] == JOP_NOOP);
    assert(cascading[1] == JOP_NOOP);

    definition = definition_for(live_load, 2, 1);
    janet_bytecode_movopt(&definition);
    assert(live_load[0] == JOP_LOAD_NIL);

    definition = definition_for(captured_load, 2, 1);
    definition.closure_bitset = closure_bits;
    janet_bytecode_movopt(&definition);
    assert(captured_load[0] == JOP_LOAD_NIL);

    definition = definition_for(side_effect, 2, 1);
    janet_bytecode_movopt(&definition);
    assert(side_effect[0] == JOP_MAKE_BUFFER);
}
