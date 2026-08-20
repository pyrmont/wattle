/* Behavioral contract for the FFI's type system, marshalling, calling
 * machinery and cfunction surface, run against whichever implementation the
 * build selected (`-Dffi-core=c` or the Zig default).
 *
 * ## What the Janet suites cannot reach
 *
 * `test/suite-ffi.janet` exercises the type system and `port/probe-16/abi/`
 * drives real calls against real C. Six things have no Janet spelling:
 *
 *  - **The primitive size and alignment table.** `janet_ffi_type_info` is
 *    built from the host's `sizeof` and an `alignof` macro; the port restates
 *    it with `@sizeOf` and `@alignOf`. A restatement is a place two answers
 *    can drift apart, and only C can ask the host the same question directly.
 *    Every entry is checked against the real type below, which is the same
 *    argument `test/ffi_layout.c` makes for the struct layout machine.
 *  - **The abstract types' callback sets.** `core/ffi-struct` and
 *    `core/ffi-signature` are `JANET_ATEND_GCMARK`, so a mark callback and
 *    eleven null slots; `core/ffi-native` is `JANET_ATEND_NAME` and has
 *    twelve; `ffi/jitfn` has three of them filled and `gcmark` null. From
 *    Janet only the *name* is visible, through `(type x)`. That the `get`,
 *    `put`, `call` and `next` slots are null is what makes these values
 *    opaque, and it is invisible from the language.
 *  - **`janet_ffi_trampoline` with no userdata.** Every callback ends here,
 *    and its first act is to check for a null `userdata` and complain. A
 *    Janet program reaches this function only through a C library calling
 *    back, which always passes the pointer it was given, so the null arm is
 *    unreachable from the language and reachable in one line from here.
 *  - **The outgoing half of the frame.** Part 16 added `arg_stack_count` to
 *    `JanetFFIAllocResult` because a Zig caller declares the outgoing stack
 *    words as function parameters and must not count the by-reference
 *    payloads that follow them. Nothing in Janet can observe the split; the
 *    allocators are exported and can be asked directly.
 *  - **The rung ceiling.** Past 1024 words of outgoing arguments there is no
 *    function type to call through, and `ffi/signature` reports it. Only
 *    SysV64 can reach it, so the assertion is on the allocator rather than on
 *    a call this host could make.
 *  - **The failure messages.** A raise is asserted here by its *message*,
 *    which Part 11 recorded as the difference between a test and a tautology.
 *
 * ## The two faces
 *
 * Phase 10's acceptance list requires the C face and the Zig face of a
 * converted symbol to be tested separately. As in Parts 14 and 15, this
 * increment converts no raise-capable *exported* symbol: every raise is inside
 * a cfunction, and a cfunction is a C face already. So the check is met by
 * calling the registered cfunction pointer directly, which is what `call_core`
 * does, and there is no second face to drift from it. `janet_ffi_trampoline`
 * is the one exported non-cfunction and it does not raise on its own account.
 */

#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "features.h"
#include <janet.h>

#include "support.h"
#include "state.h"

#ifdef JANET_FFI

static int panics_fired = 0;

#define EXPECT_PANIC_MSG(expr, text) do { \
    JanetTryState _state; \
    int _raised = 0; \
    JanetSignal _sig = JANET_SIGNAL_OK; \
    janet_try_init(&_state); \
    janet_contract_arm(); \
    (void)(expr); \
    _raised = janet_contract_raised(); \
    if (_raised) _sig = janet_contract_signal(); \
    janet_restore(&_state); \
    assert(_raised && "expected a panic, got a return"); \
    assert(_sig == JANET_SIGNAL_ERROR); \
    assert(janet_checktype(_state.payload, JANET_STRING)); \
    assert(janet_string_length(janet_unwrap_string(_state.payload)) == (int32_t) strlen(text)); \
    assert(!memcmp(janet_unwrap_string(_state.payload), (text), strlen(text))); \
    panics_fired++; \
} while (0)

#define EXPECT_PANIC_PREFIX(expr, text) do { \
    JanetTryState _state; \
    int _raised = 0; \
    JanetSignal _sig = JANET_SIGNAL_OK; \
    janet_try_init(&_state); \
    janet_contract_arm(); \
    (void)(expr); \
    _raised = janet_contract_raised(); \
    if (_raised) _sig = janet_contract_signal(); \
    janet_restore(&_state); \
    assert(_raised && "expected a panic, got a return"); \
    assert(_sig == JANET_SIGNAL_ERROR); \
    assert(janet_checktype(_state.payload, JANET_STRING)); \
    assert((size_t) janet_string_length(janet_unwrap_string(_state.payload)) >= strlen(text)); \
    assert(!memcmp(janet_unwrap_string(_state.payload), (text), strlen(text))); \
    panics_fired++; \
} while (0)

/* Call a core cfunction by name. This is the pointer `janet_lib_ffi`
 * registered, so it is the same face a Janet call would reach. */
static Janet call_core(const char *name, int32_t argc, Janet *argv) {
    Janet fun = janet_resolve_core(name);
    assert(janet_checktype(fun, JANET_CFUNCTION));
    return janet_contract_call_cfunction(janet_unwrap_cfunction(fun), argc, argv);
}

static Janet eval(const char *source) {
    Janet out = janet_wrap_nil();
    JanetTable *env = janet_core_env(NULL);
    int status = janet_dostring(env, source, "ffi_core", &out);
    assert(status == 0);
    return out;
}

/* ------------------------------------------------------------ registration */

/* Every name `janet_lib_ffi` registers. A binding that stops being registered
 * is what this catches, and Part 6 recorded that a registration table is the
 * one place a cfunction can go missing without a link error. */
static const char *const ffi_bindings[] = {
    "ffi/native", "ffi/lookup", "ffi/close", "ffi/signature", "ffi/call",
    "ffi/struct", "ffi/write", "ffi/read", "ffi/size", "ffi/align",
    "ffi/trampoline", "ffi/jitfn", "ffi/malloc", "ffi/free",
    "ffi/pointer-buffer", "ffi/pointer-cfunction", "ffi/calling-conventions",
};

static void test_registration(void) {
    size_t count = sizeof(ffi_bindings) / sizeof(ffi_bindings[0]);
    assert(count == 17);
    for (size_t i = 0; i < count; i++) {
        Janet fun = janet_resolve_core(ffi_bindings[i]);
        assert(janet_checktype(fun, JANET_CFUNCTION));
    }
}

/* ------------------------------------------------- the host's own numbers */

/* `ALIGNOF` as `ffi.c` spells it: `alignof` is not in c99. */
#define ALIGNOF(type) offsetof(struct { char c; type member; }, member)

struct prim_case {
    const char *name;
    size_t size;
    size_t alignment;
};

/* Every machine type, against the real C type it names. The port restates this
 * table with `@sizeOf` and `@alignOf`, and this is where the two are pinned
 * together on whatever host is building. */
static const struct prim_case prim_cases[] = {
    { "void", 0, 0 },
    { "bool", sizeof(char), ALIGNOF(char) },
    { "ptr", sizeof(void *), ALIGNOF(void *) },
    { "pointer", sizeof(void *), ALIGNOF(void *) },
    { "string", sizeof(char *), ALIGNOF(char *) },
    { "float", sizeof(float), ALIGNOF(float) },
    { "double", sizeof(double), ALIGNOF(double) },
    { "int8", sizeof(int8_t), ALIGNOF(int8_t) },
    { "uint8", sizeof(uint8_t), ALIGNOF(uint8_t) },
    { "int16", sizeof(int16_t), ALIGNOF(int16_t) },
    { "uint16", sizeof(uint16_t), ALIGNOF(uint16_t) },
    { "int32", sizeof(int32_t), ALIGNOF(int32_t) },
    { "uint32", sizeof(uint32_t), ALIGNOF(uint32_t) },
    { "int64", sizeof(int64_t), ALIGNOF(int64_t) },
    { "uint64", sizeof(uint64_t), ALIGNOF(uint64_t) },
    /* The aliases, which resolve to the same entries. */
    { "r32", sizeof(float), ALIGNOF(float) },
    { "r64", sizeof(double), ALIGNOF(double) },
    { "s8", sizeof(int8_t), ALIGNOF(int8_t) },
    { "u8", sizeof(uint8_t), ALIGNOF(uint8_t) },
    { "s16", sizeof(int16_t), ALIGNOF(int16_t) },
    { "u16", sizeof(uint16_t), ALIGNOF(uint16_t) },
    { "s32", sizeof(int32_t), ALIGNOF(int32_t) },
    { "u32", sizeof(uint32_t), ALIGNOF(uint32_t) },
    { "s64", sizeof(int64_t), ALIGNOF(int64_t) },
    { "u64", sizeof(uint64_t), ALIGNOF(uint64_t) },
    { "char", sizeof(int8_t), ALIGNOF(int8_t) },
    { "short", sizeof(int16_t), ALIGNOF(int16_t) },
    { "int", sizeof(int32_t), ALIGNOF(int32_t) },
    { "long", sizeof(int64_t), ALIGNOF(int64_t) },
    { "byte", sizeof(uint8_t), ALIGNOF(uint8_t) },
    { "uchar", sizeof(uint8_t), ALIGNOF(uint8_t) },
    { "ushort", sizeof(uint16_t), ALIGNOF(uint16_t) },
    { "uint", sizeof(uint32_t), ALIGNOF(uint32_t) },
    { "ulong", sizeof(uint64_t), ALIGNOF(uint64_t) },
    { "size", sizeof(size_t), ALIGNOF(size_t) },
    { "ssize", sizeof(size_t), ALIGNOF(size_t) },
};

static void test_prim_table(void) {
    size_t count = sizeof(prim_cases) / sizeof(prim_cases[0]);
    assert(count == 36);
    for (size_t i = 0; i < count; i++) {
        Janet arg = janet_ckeywordv(prim_cases[i].name);
        Janet size = call_core("ffi/size", 1, &arg);
        Janet alignment = call_core("ffi/align", 1, &arg);
        assert(janet_unwrap_number(size) == (double) prim_cases[i].size);
        assert(janet_unwrap_number(alignment) == (double) prim_cases[i].alignment);
    }
}

/* ------------------------------------------------------- the abstract types */

/* The callback set of the abstract behind `expr`, checked slot by slot. Only
 * `name` is visible from Janet, and only through `(type x)`. */
static void expect_shape(const char *expr, const char *name,
                         int has_gc, int has_gcmark, int has_bytes, int has_length) {
    Janet value = eval(expr);
    assert(janet_checktype(value, JANET_ABSTRACT));
    const JanetAbstractType *at = janet_abstract_type(janet_unwrap_abstract(value));
    assert(!strcmp(at->name, name));
    assert((at->gc != NULL) == has_gc);
    assert((at->gcmark != NULL) == has_gcmark);
    assert((at->bytes != NULL) == has_bytes);
    assert((at->length != NULL) == has_length);
    /* Everything else is null in all four of these types, which is what makes
     * them opaque: no indexing, no method call, no comparison, no hashing. */
    assert(at->get == NULL);
    assert(at->put == NULL);
    assert(at->marshal == NULL);
    assert(at->unmarshal == NULL);
    assert(at->tostring == NULL);
    assert(at->compare == NULL);
    assert(at->hash == NULL);
    assert(at->next == NULL);
    assert(at->call == NULL);
}

static void test_abstract_types(void) {
    expect_shape("(ffi/struct :int32 :double)", "core/ffi-struct", 0, 1, 0, 0);
    expect_shape("(ffi/signature :none :void :int32)", "core/ffi-signature", 0, 1, 0, 0);
#ifdef JANET_DYNAMIC_MODULES
    expect_shape("(ffi/native)", "core/ffi-native", 0, 0, 0, 0);
#endif
}

/* ------------------------------------------------------------ the trampoline */

void janet_ffi_trampoline(void *ctx, void *userdata);

/* The null-userdata arm, which no Janet program can produce: a C library
 * always passes back the pointer it was handed. It complains and returns
 * rather than raising, so reaching it at all is the assertion. */
static void test_trampoline_without_userdata(void) {
    janet_ffi_trampoline(NULL, NULL);
}

/* ------------------------------------------- the outgoing half of the frame */

typedef struct {
    uint64_t size;
    uint32_t prim;
    uint32_t spec;
    uint32_t alignment;
    uint32_t offset;
    uint32_t offset2;
} ArgSlot;

typedef struct {
    uint32_t stack_count;
    uint32_t variant;
    uint32_t error_kind;
    int32_t error_arg;
    uint32_t arg_stack_count;
} AllocResult;

void janet_ffi_win64_alloc(AllocResult *result, ArgSlot *ret, ArgSlot *args, uint32_t arg_count);
void janet_ffi_sysv64_alloc(AllocResult *result, ArgSlot *ret, ArgSlot *args, uint32_t arg_count);
void janet_ffi_aapcs64_alloc(AllocResult *result, ArgSlot *ret, ArgSlot *args,
                             uint32_t arg_count, int apple_abi, uint64_t max_ret_size);

enum {
    PRIM_INT64 = 12,
    PRIM_STRUCT = 14,
    SYSV64_INTEGER = 0,
    SYSV64_MEMORY = 8,
    WIN64_REGISTER = 9,
    AAPCS64_GENERAL = 13,
};

static ArgSlot slot(uint32_t prim, uint32_t spec, uint64_t size, uint32_t alignment) {
    ArgSlot s;
    memset(&s, 0, sizeof s);
    s.prim = prim;
    s.spec = spec;
    s.size = size;
    s.alignment = alignment;
    return s;
}

/* A by-reference payload is part of the frame and is *not* an outgoing
 * argument, and only the split tells a caller how many parameters to declare.
 * Win64 and AAPCS64 both have a payload area; SysV64 has none, and its two
 * counts are therefore equal. */
static void test_outgoing_split(void) {
    ArgSlot args[16];
    ArgSlot ret;
    AllocResult result;

    /* Ten integers on Win64: four in registers, six on the stack, no payloads.
     * The two counts agree because nothing was passed by reference. */
    ret = slot(PRIM_INT64, WIN64_REGISTER, 8, 8);
    for (int i = 0; i < 10; i++) args[i] = slot(PRIM_INT64, WIN64_REGISTER, 8, 8);
    janet_ffi_win64_alloc(&result, &ret, args, 10);
    assert(result.error_kind == 0);
    assert(result.arg_stack_count == 6);
    assert(result.stack_count == 6);

    /* The same with three oversized aggregates, which Win64 passes by
     * reference: each takes one outgoing word and a payload behind it, so the
     * frame grows and the outgoing count does not. */
    ret = slot(PRIM_INT64, WIN64_REGISTER, 8, 8);
    for (int i = 0; i < 10; i++) args[i] = slot(PRIM_INT64, WIN64_REGISTER, 8, 8);
    for (int i = 10; i < 13; i++) args[i] = slot(PRIM_STRUCT, WIN64_REGISTER, 64, 8);
    janet_ffi_win64_alloc(&result, &ret, args, 13);
    assert(result.error_kind == 0);
    assert(result.arg_stack_count == 9);
    assert(result.stack_count > result.arg_stack_count);

    /* SysV64 has no payload area at all: an aggregate that does not fit in
     * registers goes onto the stack whole. */
    ret = slot(PRIM_INT64, SYSV64_INTEGER, 8, 8);
    for (int i = 0; i < 8; i++) args[i] = slot(PRIM_INT64, SYSV64_INTEGER, 8, 8);
    args[8] = slot(PRIM_STRUCT, SYSV64_MEMORY, 64, 8);
    janet_ffi_sysv64_alloc(&result, &ret, args, 9);
    assert(result.error_kind == 0);
    assert(result.stack_count == result.arg_stack_count);
    assert(result.arg_stack_count == 2 + 8);

    /* AAPCS64 counts its frame in bytes and its outgoing half in words. */
    ret = slot(PRIM_INT64, AAPCS64_GENERAL, 8, 8);
    for (int i = 0; i < 12; i++) args[i] = slot(PRIM_INT64, AAPCS64_GENERAL, 8, 8);
    janet_ffi_aapcs64_alloc(&result, &ret, args, 12, 0, 128);
    assert(result.error_kind == 0);
    assert(result.arg_stack_count == 4);
    assert(result.stack_count == 32);
}

/* The ceiling is 1024 outgoing words, and SysV64 is the only convention that
 * can generate more: it passes a large aggregate by value on the stack where
 * the other two pass a pointer. */
static void test_ceiling_is_reachable_only_on_sysv(void) {
    ArgSlot args[2];
    ArgSlot ret;
    AllocResult result;

    ret = slot(PRIM_INT64, SYSV64_INTEGER, 8, 8);
    args[0] = slot(PRIM_STRUCT, SYSV64_MEMORY, 16000, 8);
    janet_ffi_sysv64_alloc(&result, &ret, args, 1);
    assert(result.error_kind == 0);
    assert(result.arg_stack_count == 2000);

    /* The same aggregate on AAPCS64 is one word, however large it gets. */
    ret = slot(PRIM_INT64, AAPCS64_GENERAL, 8, 8);
    args[0] = slot(PRIM_STRUCT, 15 /* AAPCS64_GENERAL_REF */, 16000, 8);
    janet_ffi_aapcs64_alloc(&result, &ret, args, 1, 0, 128);
    assert(result.error_kind == 0);
    assert(result.arg_stack_count == 0);
}

/* ------------------------------------------------------------- the raises */

static void test_raises(void) {
    Janet argv[4];

    EXPECT_PANIC_MSG(call_core("ffi/struct", 0, NULL),
                     "arity mismatch, expected at least 1, got 0");
    EXPECT_PANIC_MSG(call_core("ffi/size", 0, NULL),
                     "arity mismatch, expected 1, got 0");

    argv[0] = janet_ckeywordv("nonesuch");
    EXPECT_PANIC_MSG(call_core("ffi/size", 1, argv),
                     "unknown machine type nonesuch");

    argv[0] = janet_wrap_integer(7);
    EXPECT_PANIC_MSG(call_core("ffi/size", 1, argv),
                     "bad native type 7");

    argv[0] = eval("@[:int32 1 2]");
    EXPECT_PANIC_PREFIX(call_core("ffi/size", 1, argv),
                        "array type must be of form @[type count], got ");

    /* A struct of one void member: the void type has no alignment, which is
     * the `el_align <= 0` arm of the layout loop. */
    argv[0] = janet_ckeywordv("void");
    EXPECT_PANIC_MSG(call_core("ffi/struct", 1, argv),
                     "bad field type void");

    argv[0] = janet_ckeywordv("nonesuch");
    argv[1] = janet_ckeywordv("void");
    EXPECT_PANIC_MSG(call_core("ffi/signature", 2, argv),
                     "unknown calling convention nonesuch");

    /* `:none` describes but cannot call. */
    argv[0] = janet_ckeywordv("none");
    argv[1] = janet_ckeywordv("void");
    {
        Janet sig = call_core("ffi/signature", 2, argv);
        Janet call_argv[2];
        call_argv[0] = janet_wrap_pointer((void *) &test_raises);
        call_argv[1] = sig;
        EXPECT_PANIC_MSG(call_core("ffi/call", 2, call_argv),
                         "calling convention not supported");
    }

    /* A callable pointer is a pointer or a jitfn, and nothing else. */
    {
        Janet call_argv[2];
        call_argv[0] = janet_wrap_integer(7);
        call_argv[1] = eval("(ffi/signature :none :void)");
        EXPECT_PANIC_MSG(call_core("ffi/call", 2, call_argv),
                         "bad slot #0, expected ffi callable pointer type, got 7");
    }

    /* Reading past the end of a byte source. */
    argv[0] = janet_ckeywordv("int64");
    argv[1] = janet_cstringv("abc");
    EXPECT_PANIC_MSG(call_core("ffi/read", 2, argv),
                     "read out of range");

    /* Writing at an index beyond the buffer's own count. */
    argv[0] = janet_ckeywordv("int32");
    argv[1] = janet_wrap_integer(1);
    argv[2] = janet_wrap_buffer(janet_buffer(8));
    argv[3] = janet_wrap_integer(4);
    EXPECT_PANIC_MSG(call_core("ffi/write", 4, argv),
                     "index out of bounds");

    /* A struct written with the wrong number of fields, and an array with the
     * wrong length. Both are shape faults the marshaller reports. */
    argv[0] = eval("(ffi/struct :int32 :int32)");
    argv[1] = eval("[1 2 3]");
    EXPECT_PANIC_MSG(call_core("ffi/write", 2, argv),
                     "wrong number of fields in struct, expected 2, got 3");

    argv[0] = eval("@[:int32 3]");
    argv[1] = eval("[1 2]");
    EXPECT_PANIC_MSG(call_core("ffi/write", 2, argv),
                     "bad array length, expected 3, got 2");

    /* `:void` writes only nil. */
    argv[0] = janet_ckeywordv("void");
    argv[1] = janet_wrap_integer(1);
    EXPECT_PANIC_MSG(call_core("ffi/write", 2, argv),
                     "expected nil, got 1");

    /* A native object closed twice, and the running binary refusing to close.
     *
     * Without dynamic modules there is no native object to have: `util.h`
     * reduces `Clib` to an `int` and `load_clib` to a no-op that answers zero,
     * so `ffi/native` always raises and `error_clib` is a one-line function in
     * `util.c` rather than `dlerror`. That arm is the whole of this section in
     * such a build, and it is a real arm -- Part 16's matrix caught this
     * contract assuming the other one. */
#ifdef JANET_DYNAMIC_MODULES
    {
        Janet self = eval("(ffi/native)");
        janet_gcroot(self);
        EXPECT_PANIC_MSG(call_core("ffi/close", 1, &self), "cannot close self");
        {
            Janet lookup[2];
            lookup[0] = self;
            lookup[1] = janet_cstringv("a_symbol_that_does_not_exist");
            assert(janet_checktype(call_core("ffi/lookup", 2, lookup), JANET_NIL));
        }
        janet_gcunroot(self);
    }
#else
    EXPECT_PANIC_MSG(call_core("ffi/native", 0, NULL),
                     "dynamic modules not supported");
#endif
}

void ffi_core_contract(void) {
    janet_init();

    test_registration();
    test_prim_table();
    test_abstract_types();
    test_trampoline_without_userdata();
    test_outgoing_split();
    test_ceiling_is_reachable_only_on_sysv();
    test_raises();

    printf("ffi_core contract ok (%d raises)\n", panics_fired);
    janet_deinit();
}

#else /* JANET_FFI */

void ffi_core_contract(void) {
    printf("ffi_core contract skipped (no FFI in this build)\n");
}

#endif
