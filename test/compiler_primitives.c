#include <assert.h>
#include <stdint.h>
#include <string.h>
#include <janet.h>
#include "compile.h"
#include "util.h"
#include "vector.h"

int main(void) {
    JanetCompiler compiler;
    JanetScope scope;
    JanetFopts options;
    JanetSlot slot;
    JanetFuncDef definition;
    JanetFuncDef *nested = &definition;
    JanetFuncDef *finalized;
    JanetSourceMapping mapping = {0, 0};
    uint32_t closure_bits = 0;
    int32_t environment = 0;
    JanetScope child;
    JanetScope unused;
    SymPair pair;
    JanetSlot *slots = NULL;
    Janet values[2];
    JanetTable *dictionary;
    const uint8_t *captured_symbol;
    const uint8_t *global_symbol;
    JanetArray *constructed_array;
    JanetKV *constructed_struct;
    Janet *call_form;
    Janet folded_struct;

    janet_init();
    memset(&compiler, 0, sizeof(compiler));
    memset(&scope, 0, sizeof(scope));
    memset(&definition, 0, sizeof(definition));
    compiler.env = janet_table(0);
    compiler.scope = &scope;
    janetc_regalloc_init(&scope.ra);

    options = janetc_fopts_default(&compiler);
    assert(options.compiler == &compiler);
    assert(options.flags == 0);
    assert(options.hint.flags == ((UINT32_C(1) << JANET_NIL) | JANET_SLOT_CONSTANT));
    assert(janet_checktype(options.hint.constant, JANET_NIL));

    slot = janetc_cslot(janet_wrap_true());
    assert(slot.flags == ((UINT32_C(1) << JANET_BOOLEAN) | JANET_SLOT_CONSTANT));
    assert(slot.index == -1);
    assert(slot.envindex == -1);
    assert(janet_unwrap_boolean(slot.constant));

    slot = janetc_farslot(&compiler);
    assert(slot.index == 0);
    assert(slot.flags == JANET_SLOTTYPE_ANY);
    assert(slot.envindex == -1);
    assert(janet_checktype(slot.constant, JANET_NIL));
    janetc_freeslot(&compiler, slot);
    assert(janetc_farslot(&compiler).index == 0);

    slot = janetc_farslot(&compiler);
    slot.flags |= JANET_SLOT_NAMED;
    janetc_freeslot(&compiler, slot);
    assert(janetc_farslot(&compiler).index == 2);

    definition.flags = JANET_FUNCDEF_FLAG_VARARG |
                       JANET_FUNCDEF_FLAG_HASNAME |
                       JANET_FUNCDEF_FLAG_HASSOURCE |
                       JANET_FUNCDEF_FLAG_HASDEFS |
                       JANET_FUNCDEF_FLAG_HASENVS |
                       JANET_FUNCDEF_FLAG_HASSOURCEMAP |
                       JANET_FUNCDEF_FLAG_HASCLOBITSET |
                       JANET_FUNCDEF_FLAG_NAMEDARGS;
    janet_def_addflags(&definition);
    assert(definition.flags == JANET_FUNCDEF_FLAG_VARARG);

    definition.name = janet_cstring("name");
    definition.source = janet_cstring("source");
    definition.defs = &nested;
    definition.environments = &environment;
    definition.sourcemap = &mapping;
    definition.closure_bitset = &closure_bits;
    definition.named_args_count = 2;
    janet_def_addflags(&definition);
    assert(definition.flags & JANET_FUNCDEF_FLAG_VARARG);
    assert(definition.flags & JANET_FUNCDEF_FLAG_HASNAME);
    assert(definition.flags & JANET_FUNCDEF_FLAG_HASSOURCE);
    assert(definition.flags & JANET_FUNCDEF_FLAG_HASDEFS);
    assert(definition.flags & JANET_FUNCDEF_FLAG_HASENVS);
    assert(definition.flags & JANET_FUNCDEF_FLAG_HASSOURCEMAP);
    assert(definition.flags & JANET_FUNCDEF_FLAG_HASCLOBITSET);
    assert(definition.flags & JANET_FUNCDEF_FLAG_NAMEDARGS);

    janetc_regalloc_deinit(&scope.ra);
    compiler.scope = NULL;
    janetc_scope(&scope, &compiler, JANET_SCOPE_FUNCTION, "root");
    janetc_regalloc_touch(&scope.ra, 5);
    janet_v_push(compiler.buffer, JOP_NOOP);
    janetc_scope(&child, &compiler, JANET_SCOPE_CLOSURE, "child");
    assert(compiler.scope == &child);
    assert(scope.child == &child);
    assert(child.parent == &scope);
    assert(child.bytecode_start == 1);
    assert(janetc_regalloc_check(&child.ra, 5));

    memset(&pair, 0, sizeof(pair));
    pair.slot.index = 3;
    pair.slot.envindex = -1;
    pair.sym = janet_symbol((const uint8_t *) "local", 5);
    pair.sym2 = pair.sym;
    pair.referenced = 1;
    pair.keep = 1;
    pair.death_pc = UINT32_MAX;
    janet_v_push(child.syms, pair);
    janetc_regalloc_touch(&child.ra, 8);
    child.ra.max = 8;
    janet_v_push(compiler.buffer, JOP_NOOP);
    janetc_popscope(&compiler);
    assert(compiler.scope == &scope);
    assert(scope.child == NULL);
    assert(scope.flags & JANET_SCOPE_CLOSURE);
    assert(scope.ra.max >= 8);
    assert(janet_v_count(scope.syms) == 1);
    assert(scope.syms[0].sym == NULL);
    assert(scope.syms[0].sym2 == NULL);
    assert(scope.syms[0].death_pc == 2);
    assert(janetc_regalloc_check(&scope.ra, 3));

    janetc_scope(&unused, &compiler, JANET_SCOPE_UNUSED, "unused");
    slot.index = 10;
    slot.envindex = -1;
    slot.flags = 0;
    janetc_popscope_keepslot(&compiler, slot);
    assert(compiler.scope == &scope);
    assert(janetc_regalloc_check(&scope.ra, 10));

    janet_v_empty(compiler.buffer);
    slot = janetc_return(&compiler, janetc_cslot(janet_wrap_nil()));
    assert(slot.flags & JANET_SLOT_RETURNED);
    assert(janet_v_count(compiler.buffer) == 1);
    assert(compiler.buffer[0] == JOP_RETURN_NIL);
    slot = janetc_return(&compiler, slot);
    assert(janet_v_count(compiler.buffer) == 1);

    janet_v_empty(compiler.buffer);
    memset(&slot, 0, sizeof(slot));
    slot.index = 3;
    slot.envindex = -1;
    slot = janetc_return(&compiler, slot);
    assert(slot.flags & JANET_SLOT_RETURNED);
    assert(janet_v_count(compiler.buffer) == 1);
    assert(compiler.buffer[0] == (JOP_RETURN | (UINT32_C(3) << 8)));

    options = janetc_fopts_default(&compiler);
    options.flags = JANET_FOPTS_HINT;
    memset(&options.hint, 0, sizeof(options.hint));
    options.hint.index = 7;
    options.hint.envindex = -1;
    slot = janetc_gettarget(options);
    assert(slot.index == 7);
    options.hint.index = 300;
    slot = janetc_gettarget(options);
    assert(slot.index >= 0 && slot.index != 300);
    assert(slot.envindex == -1 && slot.flags == 0);
    assert(janet_checktype(slot.constant, JANET_NIL));

    values[0] = janet_wrap_integer(10);
    values[1] = janet_wrap_true();
    compiler.recursion_guard = 1024;
    slots = janetc_toslots(&compiler, values, 2);
    assert(janet_v_count(slots) == 2);
    assert(slots[0].flags & JANET_SLOT_CONSTANT);
    assert(janet_unwrap_integer(slots[0].constant) == 10);
    assert(slots[1].flags & JANET_SLOT_CONSTANT);
    assert(janet_unwrap_boolean(slots[1].constant));
    janetc_freeslots(&compiler, slots);

    dictionary = janet_table(2);
    janet_table_put(dictionary, janet_ckeywordv("b"), janet_wrap_integer(2));
    janet_table_put(dictionary, janet_ckeywordv("a"), janet_wrap_integer(1));
    compiler.recursion_guard = 1024;
    slots = janetc_toslotskv(&compiler, janet_wrap_table(dictionary));
    assert(janet_v_count(slots) == 4);
    assert(!strcmp((const char *) janet_unwrap_keyword(slots[0].constant), "a"));
    assert(janet_unwrap_integer(slots[1].constant) == 1);
    assert(!strcmp((const char *) janet_unwrap_keyword(slots[2].constant), "b"));
    assert(janet_unwrap_integer(slots[3].constant) == 2);
    janetc_freeslots(&compiler, slots);

    compiler.current_mapping.line = 12;
    compiler.current_mapping.column = 34;
    compiler.recursion_guard = 1024;
    options = janetc_fopts_default(&compiler);
    slot = janetc_value(options, janet_wrap_integer(55));
    assert(slot.flags & JANET_SLOT_CONSTANT);
    assert(janet_unwrap_integer(slot.constant) == 55);
    assert(compiler.recursion_guard == 1024);
    assert(compiler.current_mapping.line == 12);
    assert(compiler.current_mapping.column == 34);

    constructed_struct = janet_struct_begin(1);
    janet_struct_put(constructed_struct, janet_ckeywordv("key"), janet_wrap_integer(9));
    folded_struct = janet_wrap_struct(janet_struct_end(constructed_struct));
    slot = janetc_value(options, folded_struct);
    assert(slot.flags & JANET_SLOT_CONSTANT);
    assert(janet_checktype(slot.constant, JANET_STRUCT));
    assert(janet_v_count(compiler.buffer) == 1);

    constructed_array = janet_array(2);
    janet_array_push(constructed_array, janet_wrap_integer(4));
    janet_array_push(constructed_array, janet_wrap_integer(5));
    janet_v_empty(compiler.buffer);
    compiler.recursion_guard = 1024;
    slot = janetc_value(options, janet_wrap_array(constructed_array));
    assert(!(slot.flags & JANET_SLOT_CONSTANT));
    assert(janet_v_count(compiler.buffer) == 4);
    assert((compiler.buffer[2] & 0xFF) == JOP_PUSH_2);
    assert((compiler.buffer[3] & 0xFF) == JOP_MAKE_ARRAY);
    janetc_freeslot(&compiler, slot);

    call_form = janet_tuple_begin(2);
    call_form[0] = janet_ckeywordv("key");
    call_form[1] = folded_struct;
    folded_struct = janet_wrap_tuple(janet_tuple_end(call_form));
    janet_v_empty(compiler.buffer);
    compiler.recursion_guard = 1024;
    options = janetc_fopts_default(&compiler);
    slot = janetc_value(options, folded_struct);
    assert(!(slot.flags & JANET_SLOT_CONSTANT));
    assert((compiler.buffer[janet_v_count(compiler.buffer) - 1] & 0xFF) == JOP_CALL);
    janetc_freeslot(&compiler, slot);

    janet_v_empty(compiler.buffer);
    compiler.recursion_guard = 1024;
    options = janetc_fopts_default(&compiler);
    options.flags |= JANET_FOPTS_TAIL;
    slot = janetc_value(options, folded_struct);
    assert(slot.flags & JANET_SLOT_RETURNED);
    assert((compiler.buffer[janet_v_count(compiler.buffer) - 1] & 0xFF) == JOP_TAILCALL);

    call_form = janet_tuple_begin(1);
    call_form[0] = janet_ckeywordv("key");
    janet_v_empty(compiler.buffer);
    compiler.recursion_guard = 1024;
    options = janetc_fopts_default(&compiler);
    slot = janetc_value(options, janet_wrap_tuple(janet_tuple_end(call_form)));
    assert(slot.flags & JANET_SLOT_CONSTANT);
    assert(janet_checktype(slot.constant, JANET_NIL));
    assert(compiler.result.status == JANET_COMPILE_ERROR);
    assert(compiler.result.error != NULL);
    compiler.result.status = JANET_COMPILE_OK;
    compiler.result.error = NULL;
    compiler.recursion_guard = 1024;

    slots = NULL;
    memset(&slot, 0, sizeof(slot));
    slot.index = 1;
    slot.envindex = -1;
    janet_v_push(slots, slot);
    slot.index = 2;
    janet_v_push(slots, slot);
    slot.index = 3;
    janet_v_push(slots, slot);
    janet_v_empty(compiler.buffer);
    assert(janetc_pushslots(&compiler, slots) == 3);
    assert(janet_v_count(compiler.buffer) == 1);
    assert(compiler.buffer[0] == (JOP_PUSH_3 |
                                  (UINT32_C(1) << 8) |
                                  (UINT32_C(2) << 16) |
                                  (UINT32_C(3) << 24)));

    slots[1].flags |= JANET_SLOT_SPLICED;
    janet_v_empty(compiler.buffer);
    assert(janetc_pushslots(&compiler, slots) == -3);
    assert(janet_v_count(compiler.buffer) == 3);
    assert(compiler.buffer[0] == (JOP_PUSH | (UINT32_C(1) << 8)));
    assert(compiler.buffer[1] == (JOP_PUSH_ARRAY | (UINT32_C(2) << 8)));
    assert(compiler.buffer[2] == (JOP_PUSH | (UINT32_C(3) << 8)));
    janet_v_free(slots);

    janet_def(compiler.env, "global-def", janet_wrap_integer(42), NULL);
    global_symbol = janet_symbol((const uint8_t *) "global-def", 10);
    assert(janetc_shadowcheck(&compiler, global_symbol) == JANETC_SHADOW_LOCAL_HIDES_GLOBAL);
    slot = janetc_resolve(&compiler, global_symbol);
    assert(slot.flags & JANET_SLOT_CONSTANT);
    assert(janet_unwrap_integer(slot.constant) == 42);

    janet_var(compiler.env, "global-var", janet_wrap_integer(7), NULL);
    global_symbol = janet_symbol((const uint8_t *) "global-var", 10);
    slot = janetc_resolve(&compiler, global_symbol);
    assert(slot.flags & JANET_SLOT_REF);
    assert(slot.flags & JANET_SLOT_NAMED);
    assert(slot.flags & JANET_SLOT_MUTABLE);
    assert(!(slot.flags & JANET_SLOT_CONSTANT));

    captured_symbol = janet_symbol((const uint8_t *) "captured", 8);
    assert(janetc_shadowcheck(&compiler, captured_symbol) == JANETC_SHADOW_NONE);
    memset(&slot, 0, sizeof(slot));
    slot.index = 4;
    slot.envindex = -1;
    janetc_nameslot(&compiler, captured_symbol, slot, JANET_DEFFLAG_NO_SHADOWCHECK);
    assert(janet_v_count(scope.syms) == 2);
    assert(scope.syms[1].sym == captured_symbol);
    assert(scope.syms[1].sym2 == captured_symbol);
    assert(scope.syms[1].slot.flags & JANET_SLOT_NAMED);
    assert(scope.syms[1].birth_pc == 2);
    assert(scope.syms[1].death_pc == UINT32_MAX);
    assert(janetc_shadowcheck(&compiler, captured_symbol) == JANETC_SHADOW_LOCAL_HIDES_LOCAL);

    slot = janetc_resolve(&compiler, captured_symbol);
    assert(slot.index == 4 && slot.envindex == -1);
    assert(scope.syms[1].referenced);

    janetc_scope(&child, &compiler, JANET_SCOPE_FUNCTION, "capture");
    slot = janetc_resolve(&compiler, captured_symbol);
    assert(slot.index == 4 && slot.envindex == 0);
    assert(scope.flags & JANET_SCOPE_ENV);
    assert(scope.syms[1].keep);
    assert(janetc_regalloc_check(&scope.ua, 4));
    assert(janet_v_count(child.envs) == 1);
    assert(child.envs[0].envindex == -1);
    assert(child.envs[0].scope == &scope);
    janetc_popscope(&compiler);
    assert(compiler.scope == &scope);

    options = janetc_fopts_default(&compiler);
    compiler.recursion_guard = 1024;
    janetc_throwaway(options, janet_wrap_integer(99));
    assert(compiler.scope == &scope);
    assert(janet_v_count(compiler.buffer) == 3);

    finalized = janetc_pop_funcdef(&compiler);
    assert(compiler.scope == NULL);
    assert(finalized->slotcount == scope.ra.max + 1);
    assert(finalized->bytecode_length == 3);
    assert(finalized->bytecode[0] == (JOP_PUSH | (UINT32_C(1) << 8)));
    assert(finalized->bytecode[1] == (JOP_PUSH_ARRAY | (UINT32_C(2) << 8)));
    assert(finalized->bytecode[2] == (JOP_PUSH | (UINT32_C(3) << 8)));
    assert(finalized->constants_length > 0);
    assert(finalized->defs_length == 0);
    assert(finalized->environments_length == 0);
    assert(finalized->flags & JANET_FUNCDEF_FLAG_NEEDSENV);
    assert(finalized->flags & JANET_FUNCDEF_FLAG_HASSYMBOLMAP);
    assert(finalized->closure_bitset != NULL);
    assert(finalized->closure_bitset[0] & (UINT32_C(1) << 4));
    assert(finalized->symbolmap_length == 1);
    assert(finalized->symbolmap[0].birth_pc == 2);
    assert(finalized->symbolmap[0].death_pc == 3);
    assert(finalized->symbolmap[0].slot_index == 4);
    assert(finalized->symbolmap[0].symbol == captured_symbol);
    assert(janet_v_count(compiler.buffer) == 0);

    global_symbol = janet_symbol((const uint8_t *) "missing", 7);
    slot = janetc_resolve(&compiler, global_symbol);
    assert(slot.flags & JANET_SLOT_CONSTANT);
    assert(janet_checktype(slot.constant, JANET_NIL));
    assert(compiler.result.status == JANET_COMPILE_ERROR);
    assert(compiler.result.error != NULL);
    {
        JanetString first_error = compiler.result.error;
        janetc_cerror(&compiler, "replacement error");
        assert(compiler.result.error == first_error);
    }
    janet_v_free(compiler.buffer);

    janet_deinit();
    return 0;
}
