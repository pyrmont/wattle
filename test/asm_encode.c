#include <assert.h>
#include <stdint.h>
#include <string.h>
#include <janet.h>

static Janet assembly_source(JanetTable *environment, const char *source) {
    Janet result;
    assert(janet_dostring(environment, source, "asm-encode-test", &result) == 0);
    return result;
}

static JanetAssembleResult assemble(JanetTable *environment, const char *source) {
    return janet_asm(assembly_source(environment, source), 0);
}

void asm_encode_contract(void) {
    JanetTable *environment;
    JanetAssembleResult result;

    janet_init();
    environment = janet_core_env(NULL);

    result = assemble(environment,
                      "'{:arity 0 "
                      "  :constants [\"constant\"] "
                      "  :slots [(first first-alias) second] "
                      "  :bytecode [(ldi first -12) "
                      "             (addim second first-alias -3) "
                      "             (tchck first [:nil :number]) "
                      "             (ldc second 0) "
                      "             (jmp :done) "
                      "             :done "
                      "             (retn)]}");
    assert(result.status == JANET_ASSEMBLE_OK);
    assert(result.error == NULL);
    assert(result.funcdef->bytecode_length == 6);
    assert(result.funcdef->bytecode[0] ==
           (JOP_LOAD_INTEGER | (UINT32_C(0) << 8) | (UINT32_C(0xFFF4) << 16)));
    assert(result.funcdef->bytecode[1] ==
           (JOP_ADD_IMMEDIATE | (UINT32_C(1) << 8) |
            (UINT32_C(0) << 16) | (UINT32_C(0xFD) << 24)));
    assert(result.funcdef->bytecode[2] ==
           (JOP_TYPECHECK | ((uint32_t) (JANET_TFLAG_NIL | JANET_TFLAG_NUMBER) << 16)));
    assert(result.funcdef->bytecode[3] ==
           (JOP_LOAD_CONSTANT | (UINT32_C(1) << 8)));
    assert(result.funcdef->bytecode[4] ==
           (JOP_JUMP | (UINT32_C(1) << 8)));
    assert(result.funcdef->bytecode[5] == JOP_RETURN_NIL);
    assert(result.funcdef->slotcount == 2);
    assert(result.funcdef->constants_length == 1);
    assert(janet_checktype(result.funcdef->constants[0], JANET_STRING));
    assert(!janet_cstrcmp(janet_unwrap_string(result.funcdef->constants[0]), "constant"));

    result = assemble(environment,
                      "'{:closures [{:name child :bytecode [(retn)]}] "
                      "  :bytecode [(clo 0 child) (retn)]}");
    assert(result.status == JANET_ASSEMBLE_OK);
    assert(result.funcdef->defs_length == 1);
    assert(!janet_cstrcmp(result.funcdef->defs[0]->name, "child"));
    assert(result.funcdef->bytecode[0] == JOP_CLOSURE);

    result = assemble(environment,
                      "'{:defs [{:name legacy-child :bytecode [(retn)]}] "
                      "  :bytecode [(clo 0 legacy-child) (retn)]}");
    assert(result.status == JANET_ASSEMBLE_OK);
    assert(result.funcdef->defs_length == 1);
    assert(!janet_cstrcmp(result.funcdef->defs[0]->name, "legacy-child"));

    result = assemble(environment,
                      "'{:name metadata-fn :arity 2 :min-arity 1 :max-arity 3 "
                      "  :vararg true :structarg true :namedargs 2 "
                      "  :source \"metadata-source\" :bytecode [(retn)]}");
    assert(result.status == JANET_ASSEMBLE_OK);
    assert(result.funcdef->arity == 2);
    assert(result.funcdef->min_arity == 1);
    assert(result.funcdef->max_arity == 3);
    assert(result.funcdef->slotcount == 3);
    assert(result.funcdef->named_args_count == 2);
    assert(result.funcdef->flags & JANET_FUNCDEF_FLAG_VARARG);
    assert(result.funcdef->flags & JANET_FUNCDEF_FLAG_STRUCTARG);
    assert(result.funcdef->flags & JANET_FUNCDEF_FLAG_NAMEDARGS);
    assert(!janet_cstrcmp(result.funcdef->name, "metadata-fn"));
    assert(!janet_cstrcmp(result.funcdef->source, "metadata-source"));

    result = assemble(environment,
                      "'{:bytecode [(retn)] :sourcemap [[12 34]]}");
    assert(result.status == JANET_ASSEMBLE_OK);
    assert(result.funcdef->sourcemap[0].line == 12);
    assert(result.funcdef->sourcemap[0].column == 34);

    result = assemble(environment,
                      "'{:bytecode [(retn)] :sourcemap []}");
    assert(result.status == JANET_ASSEMBLE_ERROR);
    assert(!strcmp((const char *) result.error,
                   "sourcemap must have the same length as the bytecode"));

    result = assemble(environment,
                      "'{:bytecode [(retn)] :sourcemap [:bad]}");
    assert(result.status == JANET_ASSEMBLE_ERROR);
    assert(!strcmp((const char *) result.error, "expected tuple"));

    result = assemble(environment,
                      "'{:arity 1 :bytecode [(noop) (retn)] "
                      "  :symbolmap [[0 1 0 local]]}");
    assert(result.status == JANET_ASSEMBLE_OK);
    assert(result.funcdef->symbolmap_length == 1);
    assert(result.funcdef->flags & JANET_FUNCDEF_FLAG_HASSYMBOLMAP);
    assert(result.funcdef->symbolmap[0].birth_pc == 0);
    assert(!janet_cstrcmp(result.funcdef->symbolmap[0].symbol, "local"));

    result = assemble(environment,
                      "'{:arity 1 :bytecode [(retn)] :symbolmap [[0 1 0 :bad]]}");
    assert(result.status == JANET_ASSEMBLE_ERROR);
    assert(!strcmp((const char *) result.error, "expected symbol"));

    result = assemble(environment,
                      "'{:bytecode [(retn)] :environments []}");
    assert(result.status == JANET_ASSEMBLE_OK);
    assert(result.funcdef->environments_length == 0);

    result = assemble(environment,
                      "'{:bytecode [(retn)] :environments [:bad]}");
    assert(result.status == JANET_ASSEMBLE_ERROR);
    assert(!strcmp((const char *) result.error, "expected integer"));

    result = assemble(environment, "'{:arity -1 :bytecode [(retn)]}");
    assert(result.status == JANET_ASSEMBLE_ERROR);
    assert(!strcmp((const char *) result.error,
                   "arity must be non-negative, instruction 0"));

    result = assemble(environment, "'{:slots [0] :bytecode [(retn)]}");
    assert(result.status == JANET_ASSEMBLE_ERROR);
    assert(!strcmp((const char *) result.error,
                   "slot names must be symbols or tuple of symbols, instruction 0"));

    result = assemble(environment, "'{:slots [(good 0)] :bytecode [(retn)]}");
    assert(result.status == JANET_ASSEMBLE_ERROR);
    assert(!strcmp((const char *) result.error,
                   "slot names must be symbols, instruction 0"));

    result = assemble(environment, "'{:bytecode [(retn 1)]}");
    assert(result.status == JANET_ASSEMBLE_ERROR);
    assert(!strcmp((const char *) result.error,
                   "expected 0 arguments: (op), instruction 0"));

    result = assemble(environment, "'{:bytecode [(ldi 0 40000)]}");
    assert(result.status == JANET_ASSEMBLE_ERROR);
    assert(!strcmp((const char *) result.error,
                   "instruction argument 40000 is too large, must be 2 bytes"));

    result = assemble(environment, "'{:bytecode [(sruim 0 0 -1)]}");
    assert(result.status == JANET_ASSEMBLE_ERROR);
    assert(!strcmp((const char *) result.error,
                   "instruction argument -1 is too small, must be 1 byte"));

    result = assemble(environment, "'{:bytecode [(ldi 0 1.5)]}");
    assert(result.status == JANET_ASSEMBLE_ERROR);
    assert(!strcmp((const char *) result.error,
                   "error parsing instruction argument 1.5"));

    result = assemble(environment, "'{:bytecode [(ldi missing 1)]}");
    assert(result.status == JANET_ASSEMBLE_ERROR);
    assert(!strcmp((const char *) result.error, "unknown name missing"));

    result = assemble(environment, "'{:bytecode [(tchck 0 :not-a-type)]}");
    assert(result.status == JANET_ASSEMBLE_ERROR);
    assert(!strcmp((const char *) result.error, "unknown type :not-a-type"));

    result = assemble(environment, "'{:bytecode [(not-an-opcode)]}");
    assert(result.status == JANET_ASSEMBLE_ERROR);
    assert(!strcmp((const char *) result.error, "unknown instruction not-an-opcode"));

    result = assemble(environment, "'{:bytecode [(1)]}");
    assert(result.status == JANET_ASSEMBLE_ERROR);
    assert(!strcmp((const char *) result.error,
                   "expected symbol in assembly instruction, instruction 0"));

    result = assemble(environment, "'{:bytecode [123]}");
    assert(result.status == JANET_ASSEMBLE_ERROR);
    assert(!strcmp((const char *) result.error,
                   "expected assembly instruction, instruction 0"));

    result = assemble(environment, "'{}");
    assert(result.status == JANET_ASSEMBLE_ERROR);
    assert(!strcmp((const char *) result.error, "bytecode expected, instruction 0"));

    result = assemble(environment, "'not-an-assembly");
    assert(result.status == JANET_ASSEMBLE_ERROR);
    assert(!strcmp((const char *) result.error,
                   "expected struct or table for assembly source, instruction 0"));

    janet_deinit();
}
