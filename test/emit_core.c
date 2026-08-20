#include <assert.h>
#include <stdint.h>
#include <string.h>
#include <janet.h>
#include "compile.h"
#include "emit.h"
#include "vector.h"

static JanetSlot slot(int32_t index, int32_t envindex, uint32_t flags, Janet constant) {
    JanetSlot value;
    value.index = index;
    value.envindex = envindex;
    value.flags = flags;
    value.constant = constant;
    return value;
}

static void clear_error(JanetCompiler *compiler) {
    compiler->result.status = JANET_COMPILE_OK;
    compiler->result.error = NULL;
}

static void clear_emission(JanetCompiler *compiler) {
    janet_v_empty(compiler->buffer);
    janet_v_empty(compiler->mapbuffer);
}

void emit_core_contract(void) {
    JanetCompiler compiler;
    JanetScope scope;
    Janet reference;
    int32_t near_register;
    int32_t i;

    janet_init();
    memset(&compiler, 0, sizeof(compiler));
    memset(&scope, 0, sizeof(scope));
    compiler.scope = &scope;
    scope.flags = JANET_SCOPE_FUNCTION;
    janetc_regalloc_init(&scope.ra);
    reference = janet_cstringv("reference-cell");

    assert(janetc_allocfar(&compiler) == 0);
    near_register = janetc_allocnear(&compiler, JANETC_REGTEMP_2);
    assert(near_register == 1);
    janetc_regalloc_freetemp(&scope.ra, near_register, JANETC_REGTEMP_2);

    assert(janetc_sequal(
        slot(3, -1, 1, janet_wrap_integer(10)),
        slot(3, -1, 2, janet_wrap_integer(20))));
    assert(!janetc_sequal(
        slot(3, -1, JANET_SLOT_MUTABLE, janet_wrap_nil()),
        slot(3, -1, 0, janet_wrap_nil())));
    assert(!janetc_sequal(
        slot(3, -1, 0, janet_wrap_nil()),
        slot(4, -1, 0, janet_wrap_nil())));
    assert(!janetc_sequal(
        slot(3, -1, 0, janet_wrap_nil()),
        slot(3, 0, 0, janet_wrap_nil())));
    assert(janetc_sequal(
        slot(-1, 0, JANET_SLOT_CONSTANT, janet_wrap_integer(10)),
        slot(-1, 0, JANET_SLOT_CONSTANT, janet_wrap_integer(10))));
    assert(!janetc_sequal(
        slot(-1, 0, JANET_SLOT_CONSTANT, janet_wrap_integer(10)),
        slot(-1, 0, JANET_SLOT_CONSTANT, janet_wrap_integer(20))));
    assert(janetc_sequal(
        slot(5, -1, JANET_SLOT_REF, janet_wrap_integer(10)),
        slot(5, -1, JANET_SLOT_REF, janet_wrap_integer(10))));
    assert(!janetc_sequal(
        slot(5, -1, JANET_SLOT_REF, janet_wrap_integer(10)),
        slot(5, -1, JANET_SLOT_REF, janet_wrap_integer(20))));

    for (i = 0; i < 100; i++) {
        compiler.current_mapping.line = i + 1;
        compiler.current_mapping.column = i * 2;
        janetc_emit(&compiler, UINT32_C(0x1000) + (uint32_t) i);
    }

    assert(janet_v_count(compiler.buffer) == 100);
    assert(janet_v_count(compiler.mapbuffer) == 100);
    for (i = 0; i < 100; i++) {
        assert(compiler.buffer[i] == UINT32_C(0x1000) + (uint32_t) i);
        assert(compiler.mapbuffer[i].line == i + 1);
        assert(compiler.mapbuffer[i].column == i * 2);
    }

    clear_emission(&compiler);
    janetc_copy(
        &compiler,
        slot(3, -1, 0, janet_wrap_nil()),
        slot(7, -1, 0, janet_wrap_nil()));
    assert(janet_v_count(compiler.buffer) == 1);
    assert(compiler.buffer[0] == (JOP_MOVE_NEAR | (UINT32_C(3) << 8) | (UINT32_C(7) << 16)));

    clear_emission(&compiler);
    janetc_copy(
        &compiler,
        slot(4, -1, 0, janet_wrap_nil()),
        slot(-1, 0, JANET_SLOT_CONSTANT, janet_wrap_number(-12)));
    assert(compiler.buffer[0] ==
           (JOP_LOAD_INTEGER | (UINT32_C(4) << 8) | (UINT32_C(0xFFF4) << 16)));

    clear_emission(&compiler);
    janetc_copy(
        &compiler,
        slot(5, -1, 0, janet_wrap_nil()),
        slot(-1, 0, JANET_SLOT_CONSTANT, janet_wrap_number(1.5)));
    janetc_copy(
        &compiler,
        slot(6, -1, 0, janet_wrap_nil()),
        slot(-1, 0, JANET_SLOT_CONSTANT, janet_wrap_number(1.5)));
    assert(janet_v_count(scope.consts) == 1);
    assert(compiler.buffer[0] == (JOP_LOAD_CONSTANT | (UINT32_C(5) << 8)));
    assert(compiler.buffer[1] == (JOP_LOAD_CONSTANT | (UINT32_C(6) << 8)));

    clear_emission(&compiler);
    janetc_copy(
        &compiler,
        slot(4, -1, 0, janet_wrap_nil()),
        slot(2, 1, 0, janet_wrap_nil()));
    assert(compiler.buffer[0] ==
           (JOP_LOAD_UPVALUE | (UINT32_C(4) << 8) | (UINT32_C(1) << 16) | (UINT32_C(2) << 24)));

    clear_emission(&compiler);
    janetc_copy(
        &compiler,
        slot(300, -1, 0, janet_wrap_nil()),
        slot(4, -1, 0, janet_wrap_nil()));
    assert(compiler.buffer[0] == (JOP_MOVE_FAR | (UINT32_C(4) << 8) | (UINT32_C(300) << 16)));

    clear_emission(&compiler);
    janetc_copy(
        &compiler,
        slot(2, 1, 0, janet_wrap_nil()),
        slot(300, -1, 0, janet_wrap_nil()));
    assert(janet_v_count(compiler.buffer) == 2);
    assert(compiler.buffer[0] == (JOP_MOVE_NEAR | (UINT32_C(1) << 8) | (UINT32_C(300) << 16)));
    assert(compiler.buffer[1] ==
           (JOP_SET_UPVALUE | (UINT32_C(1) << 8) | (UINT32_C(1) << 16) | (UINT32_C(2) << 24)));

    clear_emission(&compiler);
    janetc_copy(
        &compiler,
        slot(4, -1, 0, janet_wrap_nil()),
        slot(-1, 0, JANET_SLOT_REF, reference));
    assert(janet_v_count(compiler.buffer) == 2);
    assert(compiler.buffer[0] == (JOP_LOAD_CONSTANT | (UINT32_C(4) << 8) | (UINT32_C(1) << 16)));
    assert(compiler.buffer[1] == (JOP_GET_INDEX | (UINT32_C(4) << 8) | (UINT32_C(4) << 16)));

    clear_emission(&compiler);
    janetc_copy(
        &compiler,
        slot(-1, 0, JANET_SLOT_REF, reference),
        slot(4, -1, 0, janet_wrap_nil()));
    assert(janet_v_count(compiler.buffer) == 2);
    assert(compiler.buffer[0] == (JOP_LOAD_CONSTANT | (UINT32_C(1) << 8) | (UINT32_C(1) << 16)));
    assert(compiler.buffer[1] == (JOP_PUT_INDEX | (UINT32_C(1) << 8) | (UINT32_C(4) << 16)));

    clear_emission(&compiler);
    assert(janetc_emit_s(&compiler, JOP_RETURN, slot(3, -1, 0, janet_wrap_nil()), 0) == 0);
    assert(compiler.buffer[0] == (JOP_RETURN | (UINT32_C(3) << 8)));
    assert(janetc_emit_sl(&compiler, JOP_JUMP_IF, slot(3, -1, 0, janet_wrap_nil()), -2) == 1);
    assert(compiler.buffer[1] ==
           (JOP_JUMP_IF | (UINT32_C(3) << 8) | (UINT32_C(0xFFFE) << 16)));
    assert(janetc_emit_st(&compiler, JOP_PUSH_ARRAY, slot(3, -1, 0, janet_wrap_nil()), 0x1234) == 2);
    assert(compiler.buffer[2] ==
           (JOP_PUSH_ARRAY | (UINT32_C(3) << 8) | (UINT32_C(0x1234) << 16)));
    assert(janetc_emit_si(&compiler, JOP_ADD_IMMEDIATE, slot(3, -1, 0, janet_wrap_nil()), -12, 0) == 3);
    assert(compiler.buffer[3] ==
           (JOP_ADD_IMMEDIATE | (UINT32_C(3) << 8) | (UINT32_C(0xFFF4) << 16)));
    assert(janetc_emit_su(&compiler, JOP_GET_INDEX, slot(3, -1, 0, janet_wrap_nil()), 0xABCD, 0) == 4);
    assert(compiler.buffer[4] ==
           (JOP_GET_INDEX | (UINT32_C(3) << 8) | (UINT32_C(0xABCD) << 16)));
    assert(janetc_emit_ss(
               &compiler,
               JOP_MOVE_FAR,
               slot(3, -1, 0, janet_wrap_nil()),
               slot(300, -1, 0, janet_wrap_nil()),
               0) == 5);
    assert(compiler.buffer[5] ==
           (JOP_MOVE_FAR | (UINT32_C(3) << 8) | (UINT32_C(300) << 16)));
    assert(janetc_emit_ssi(
               &compiler,
               JOP_ADD_IMMEDIATE,
               slot(3, -1, 0, janet_wrap_nil()),
               slot(7, -1, 0, janet_wrap_nil()),
               -3,
               0) == 6);
    assert(compiler.buffer[6] ==
           (JOP_ADD_IMMEDIATE | (UINT32_C(3) << 8) | (UINT32_C(7) << 16) | (UINT32_C(0xFD) << 24)));
    assert(janetc_emit_ssu(
               &compiler,
               JOP_GET,
               slot(3, -1, 0, janet_wrap_nil()),
               slot(7, -1, 0, janet_wrap_nil()),
               250,
               0) == 7);
    assert(compiler.buffer[7] ==
           (JOP_GET | (UINT32_C(3) << 8) | (UINT32_C(7) << 16) | (UINT32_C(250) << 24)));
    assert(janetc_emit_sss(
               &compiler,
               JOP_ADD,
               slot(3, -1, 0, janet_wrap_nil()),
               slot(7, -1, 0, janet_wrap_nil()),
               slot(9, -1, 0, janet_wrap_nil()),
               0) == 8);
    assert(compiler.buffer[8] ==
           (JOP_ADD | (UINT32_C(3) << 8) | (UINT32_C(7) << 16) | (UINT32_C(9) << 24)));

    clear_emission(&compiler);
    assert(janetc_emit_si(
               &compiler,
               JOP_ADD_IMMEDIATE,
               slot(300, -1, 0, janet_wrap_nil()),
               7,
               1) == 1);
    assert(janet_v_count(compiler.buffer) == 3);
    assert(compiler.buffer[0] == (JOP_MOVE_NEAR | (UINT32_C(1) << 8) | (UINT32_C(300) << 16)));
    assert(compiler.buffer[1] ==
           (JOP_ADD_IMMEDIATE | (UINT32_C(1) << 8) | (UINT32_C(7) << 16)));
    assert(compiler.buffer[2] == (JOP_MOVE_FAR | (UINT32_C(1) << 8) | (UINT32_C(300) << 16)));

    clear_emission(&compiler);
    assert(janetc_emit_s(
               &compiler,
               JOP_RETURN,
               slot(-1, 0, JANET_SLOT_CONSTANT, janet_wrap_number(1.5)),
               0) == 1);
    assert(janet_v_count(compiler.buffer) == 2);
    assert(compiler.buffer[0] == (JOP_LOAD_CONSTANT | (UINT32_C(1) << 8)));
    assert(compiler.buffer[1] == (JOP_RETURN | (UINT32_C(1) << 8)));

    assert(janet_v_count(compiler.buffer) == janet_v_count(compiler.mapbuffer));


    /* ---- The four emit failures, which Phase 10 Part 7 moved into Zig ----
     *
     * Each was a `janetc_cerror` call in `emit.c` reached from a status code
     * the Zig kernel returned across the C ABI; with the callers in Zig there
     * is no status code and the message is raised where the failure is
     * detected. None of these is reachable from Janet source without a program
     * too large to put in a suite, which is why they are here.
     *
     * They are recorded rather than raised -- `janetc_error` keeps the first
     * error and returns -- so each case clears the status before the next.
     */

    /* Writing to a constant slot. */
    clear_error(&compiler);
    janetc_copy(&compiler,
                slot(-1, -1, JANET_SLOT_CONSTANT, janet_wrap_integer(7)),
                slot(0, -1, 0, janet_wrap_nil()));
    assert(compiler.result.status == JANET_COMPILE_ERROR);
    assert(!strcmp((const char *) compiler.result.error, "cannot write to constant"));

    /* A jump whose displacement does not fit in the signed sixteen bits the
     * instruction carries, in both directions. The instruction is emitted
     * anyway, exactly as the C original did: the compile has already failed
     * and the bytecode is never run. */
    clear_error(&compiler);
    clear_emission(&compiler);
    janetc_emit(&compiler, JOP_NOOP);
    janetc_emit_sl(&compiler, JOP_JUMP_IF, slot(0, -1, 0, janet_wrap_nil()), 0x7FFFF);
    assert(compiler.result.status == JANET_COMPILE_ERROR);
    assert(!strcmp((const char *) compiler.result.error, "jump is too far"));
    assert(janet_v_count(compiler.buffer) == 2);

    clear_error(&compiler);
    clear_emission(&compiler);
    janetc_emit(&compiler, JOP_NOOP);
    janetc_emit_sl(&compiler, JOP_JUMP_IF, slot(0, -1, 0, janet_wrap_nil()), -0x7FFFF);
    assert(compiler.result.status == JANET_COMPILE_ERROR);
    assert(!strcmp((const char *) compiler.result.error, "jump is too far"));

    /* A displacement that only just fits reports nothing, and is measured from
     * the instruction *after* the jump. */
    clear_error(&compiler);
    clear_emission(&compiler);
    janetc_emit(&compiler, JOP_NOOP);
    janetc_emit_sl(&compiler, JOP_JUMP_IF, slot(0, -1, 0, janet_wrap_nil()), INT16_MAX);
    assert(compiler.result.status == JANET_COMPILE_OK);

    /* Far registers past the sixteen bits an instruction has for one.
     * `janetc_regalloc_1` hands out the whole 32-bit range and takes the
     * lowest free bit, so the ceiling is the emitter's to enforce and reaching
     * it means marking everything below it as taken. */
    {
        JanetScope full;
        int32_t chunk;
        memset(&full, 0, sizeof(full));
        full.flags = JANET_SCOPE_FUNCTION;
        janetc_regalloc_init(&full.ra);
        janetc_regalloc_touch(&full.ra, 0xFFFF);
        for (chunk = 0; chunk < full.ra.count; chunk++) {
            full.ra.chunks[chunk] = UINT32_C(0xFFFFFFFF);
        }
        compiler.scope = &full;

        clear_error(&compiler);
        assert(janetc_allocfar(&compiler) > 0xFFFF);
        assert(compiler.result.status == JANET_COMPILE_ERROR);
        assert(!strcmp((const char *) compiler.result.error, "ran out of internal registers"));

        /* The same ceiling through `janetc_farslot`, which lives in
         * `compiler_primitives` and reports the same message. */
        clear_error(&compiler);
        janetc_farslot(&compiler);
        assert(compiler.result.status == JANET_COMPILE_ERROR);
        assert(!strcmp((const char *) compiler.result.error, "ran out of internal registers"));

        janetc_regalloc_deinit(&full.ra);
        compiler.scope = &scope;
    }

    /* "too many constants" is reported when the function's constant pool is
     * full, which is 0xFFFF entries. Filling it honestly is quadratic -- the
     * pool is searched linearly on every insert -- so the vector is grown once
     * and its count set directly, with every entry a distinct value so that
     * the search finds no match and tries to append. */
    {
        JanetScope full;
        int32_t i;
        memset(&full, 0, sizeof(full));
        full.flags = JANET_SCOPE_FUNCTION;
        janetc_regalloc_init(&full.ra);
        for (i = 0; i < 8; i++) {
            janet_v_push(full.consts, janet_wrap_number(1000.0 + i));
        }
        full.consts = janet_v_grow(full.consts, 0xFFFF, sizeof(Janet));
        for (i = 0; i < 0xFFFF; i++) {
            full.consts[i] = janet_wrap_number(1000.0 + i);
        }
        janet_v__cnt(full.consts) = 0xFFFF;
        compiler.scope = &full;

        clear_error(&compiler);
        clear_emission(&compiler);
        janetc_emit_s(&compiler, JOP_RETURN,
                      slot(-1, 0, JANET_SLOT_CONSTANT, janet_wrap_number(2.5)), 0);
        assert(compiler.result.status == JANET_COMPILE_ERROR);
        assert(!strcmp((const char *) compiler.result.error, "too many constants"));

        janet_v_free(full.consts);
        compiler.scope = &scope;
        janetc_regalloc_deinit(&full.ra);
    }

    janet_v_free(compiler.buffer);
    janet_v_free(compiler.mapbuffer);
    janet_v_free(scope.consts);
    janetc_regalloc_deinit(&scope.ra);
    janet_deinit();
}
