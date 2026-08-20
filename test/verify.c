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

void verify_contract(void) {
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

    /* ---- The instruction table, which Phase 10 Part 7 moved here from
     * `bytecode.c` ----
     *
     * The cases above reach six opcodes and so pin six rows. These check the
     * property the whole table has to have: that each row describes the
     * operands its own opcode actually takes. The C original was seventy-seven
     * bare initialisers with the opcode named only in a trailing comment, so a
     * row inserted in the middle shifted every row after it and nothing said
     * so; the Zig table names the opcode in each row and places it by name.
     * These assertions are what would notice if the naming were wrong anyway.
     *
     * The table is deliberately not restated entry by entry. Writing the
     * seventy-seven values out a second time proves only that two lists were
     * typed the same way.
     */
    {
        int32_t op;
        for (op = 0; op < JOP_INSTRUCTION_COUNT; op++) {
            enum JanetInstructionType t = janet_instructions[op];
            assert(t >= JINT_0 && t <= JINT_SC);
        }
    }

    definition = base_definition(bytecode, 1);
    definition.arity = 0;
    definition.slotcount = 2;

    /* JINT_0 reads no operands, so a word whose upper bytes would be bad slots
     * under any other shape still verifies. A row shifted onto JOP_NOOP breaks
     * exactly this. */
    bytecode[0] = JOP_NOOP | (UINT32_C(200) << 8) | (UINT32_C(200) << 16) | (UINT32_C(200) << 24);
    definition.bytecode_length = 2;
    bytecode[1] = JOP_RETURN_NIL;
    assert(janet_verify(&definition) == 0);

    /* JINT_SSS checks all three slots, including the third. JINT_SS would pass
     * this. */
    bytecode[0] = JOP_ADD | (UINT32_C(0) << 8) | (UINT32_C(1) << 16) | (UINT32_C(9) << 24);
    assert(janet_verify(&definition) == 4);

    /* JINT_SSI's third byte is an immediate rather than a slot, so the same
     * word is fine for an opcode carrying that shape. */
    bytecode[0] = JOP_ADD_IMMEDIATE | (UINT32_C(0) << 8) | (UINT32_C(1) << 16) | (UINT32_C(9) << 24);
    assert(janet_verify(&definition) == 0);

    /* JINT_SL checks the slot first and the displacement second. */
    bytecode[0] = JOP_JUMP_IF | (UINT32_C(9) << 8);
    assert(janet_verify(&definition) == 4);
    bytecode[0] = JOP_JUMP_IF | (UINT32_C(0) << 8) | (UINT32_C(500) << 16);
    assert(janet_verify(&definition) == 5);
    bytecode[0] = JOP_JUMP_IF | (UINT32_C(0) << 8) | (UINT32_C(1) << 16);
    assert(janet_verify(&definition) == 0);

    /* JINT_SES reads an environment index where JINT_SSS would read a slot. */
    bytecode[0] = JOP_SET_UPVALUE | (UINT32_C(0) << 8) | (UINT32_C(1) << 16);
    assert(janet_verify(&definition) == 8);

    /* JINT_ST's second field is a type mask, not a slot or an index. */
    bytecode[0] = JOP_TYPECHECK | (UINT32_C(0) << 8) | (UINT32_C(0xFFFF) << 16);
    assert(janet_verify(&definition) == 0);

    /* A breakpoint is bit 7 of the word. The dispatch loop masks it off with
     * 0x7F before looking the opcode up, so a breakpoint anywhere but the last
     * instruction is invisible here. */
    bytecode[0] = JOP_LOAD_INTEGER | 0x80;
    bytecode[1] = JOP_RETURN_NIL;
    assert(janet_verify(&definition) == 0);

    /* The terminator check does not: it masks with 0xFF, so a breakpoint on
     * the final instruction turns a valid function into error 9. That
     * inconsistency is the C original's and is reproduced rather than fixed;
     * FOUND.md records it. */
    bytecode[1] = JOP_RETURN_NIL | 0x80;
    assert(janet_verify(&definition) == 9);
    bytecode[1] = JOP_RETURN_NIL;

    /* All five terminators end a function; nothing else does. */
    {
        static const uint8_t enders[] = {
            JOP_RETURN, JOP_RETURN_NIL, JOP_JUMP, JOP_ERROR, JOP_TAILCALL
        };
        size_t i;
        definition.bytecode_length = 1;
        for (i = 0; i < sizeof(enders) / sizeof(enders[0]); i++) {
            bytecode[0] = enders[i];
            assert(janet_verify(&definition) == 0);
        }
        bytecode[0] = JOP_LOAD_NIL;
        assert(janet_verify(&definition) == 9);
    }

}
