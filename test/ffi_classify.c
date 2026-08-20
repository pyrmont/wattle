/* Behavioral contract for the FFI's calling conventions, run against whichever
 * implementation the build selected (`-Dffi-classify=c` or the Zig default).
 *
 * All three conventions are asserted here on every target. In `ffi.c` each is
 * compiled only on the architecture that uses it, so on any one machine two of
 * the three were never built, let alone exercised; nothing about classification
 * or argument placement is architecture-specific except the rules being
 * encoded, so all three run everywhere now. `ffi.c` keeps the `#ifdef`s that
 * decide which convention a build is allowed to *call* — being able to describe
 * a Windows signature is not the same as being able to make a Windows call.
 *
 * The AAPCS64 rules differ on Apple platforms, where stack arguments are packed
 * at their natural alignment rather than rounded up to a word. That difference
 * arrives as a parameter rather than a conditional, so both variants are
 * checked here regardless of which one the host would use.
 *
 * Types reach the conventions as a flat pre-order array of nodes rather than as
 * a JanetFFIType, so this file builds them directly and needs no Janet heap:
 * every case below is a literal description of a type, which also means a case
 * can describe something `ffi.c` would never build.
 */

#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <janet.h>

/* Declared rather than included from src/core/ffi.c, so the contract depends
 * only on the internal ABI it exercises. Compile-time assertions in that file
 * pin the ordinals below to the enumerations they mirror. */
enum {
    PRIM_VOID = 0,
    PRIM_BOOL = 1,
    PRIM_PTR = 2,
    PRIM_STRING = 3,
    PRIM_FLOAT = 4,
    PRIM_DOUBLE = 5,
    PRIM_INT8 = 6,
    PRIM_UINT8 = 7,
    PRIM_INT16 = 8,
    PRIM_UINT16 = 9,
    PRIM_INT32 = 10,
    PRIM_UINT32 = 11,
    PRIM_INT64 = 12,
    PRIM_UINT64 = 13,
    PRIM_STRUCT = 14
};

enum {
    SYSV64_INTEGER = 0,
    SYSV64_SSE = 1,
    SYSV64_SSEUP = 2,
    SYSV64_PAIR_INTINT = 3,
    SYSV64_PAIR_INTSSE = 4,
    SYSV64_PAIR_SSEINT = 5,
    SYSV64_PAIR_SSESSE = 6,
    SYSV64_NO_CLASS = 7,
    SYSV64_MEMORY = 8,
    WIN64_REGISTER = 9,
    WIN64_STACK = 10,
    WIN64_REGISTER_REF = 11,
    WIN64_STACK_REF = 12,
    AAPCS64_GENERAL = 13,
    AAPCS64_SSE = 14,
    AAPCS64_GENERAL_REF = 15,
    AAPCS64_STACK = 16,
    AAPCS64_STACK_REF = 17,
    AAPCS64_NONE = 18
};

enum {
    ALLOC_OK = 0,
    ALLOC_UNSUPPORTED_SPEC = 1,
    ALLOC_RETURN_TOO_BIG = 2
};

typedef struct {
    uint64_t size;
    uint32_t struct_size;
    uint32_t prim;
    uint32_t field_count;
    uint32_t is_aligned;
    uint32_t offset;
    int32_t array_count;
} JanetFFITypeNode;

typedef struct {
    uint64_t size;
    uint32_t prim;
    uint32_t spec;
    uint32_t alignment;
    uint32_t offset;
    uint32_t offset2;
} JanetFFIArgSlot;

typedef struct {
    uint32_t stack_count;
    uint32_t variant;
    uint32_t error_kind;
    int32_t error_arg;
} JanetFFIAllocResult;

uint32_t janet_ffi_sysv64_classify(const JanetFFITypeNode *nodes, uint32_t count);
uint32_t janet_ffi_aapcs64_classify(const JanetFFITypeNode *nodes, uint32_t count);
void janet_ffi_win64_alloc(JanetFFIAllocResult *result, JanetFFIArgSlot *ret,
                           JanetFFIArgSlot *args, uint32_t arg_count);
void janet_ffi_sysv64_alloc(JanetFFIAllocResult *result, JanetFFIArgSlot *ret,
                            JanetFFIArgSlot *args, uint32_t arg_count);
void janet_ffi_aapcs64_alloc(JanetFFIAllocResult *result, JanetFFIArgSlot *ret,
                             JanetFFIArgSlot *args, uint32_t arg_count,
                             int apple_abi, uint64_t max_ret_size);

/* The width of the AAPCS64 trampoline's return buffer, which `ffi.c` passes as
 * the size of a real structure. */
#define AAPCS64_MAX_RET 128

/* -- Building types ------------------------------------------------------ */

static JanetFFITypeNode leaf(uint32_t prim, uint64_t size, uint32_t offset) {
    JanetFFITypeNode node;
    node.size = size;
    node.struct_size = 0;
    node.prim = prim;
    node.field_count = 0;
    node.is_aligned = 1;
    node.offset = offset;
    node.array_count = -1;
    return node;
}

static JanetFFITypeNode struct_node(uint32_t size, uint32_t field_count, uint32_t offset) {
    JanetFFITypeNode node;
    node.size = size;
    node.struct_size = size;
    node.prim = PRIM_STRUCT;
    node.field_count = field_count;
    node.is_aligned = 1;
    node.offset = offset;
    node.array_count = -1;
    return node;
}

static JanetFFIArgSlot slot(uint32_t prim, uint64_t size, uint32_t alignment, uint32_t spec) {
    JanetFFIArgSlot s;
    s.size = size;
    s.prim = prim;
    s.spec = spec;
    s.alignment = alignment;
    s.offset = 0;
    s.offset2 = 0;
    return s;
}

/* -- SysV classification ------------------------------------------------- */

static void test_sysv64_classifies_scalars(void) {
    struct {
        uint32_t prim;
        uint64_t size;
        uint32_t expected;
    } cases[] = {
        {PRIM_BOOL, 1, SYSV64_INTEGER},
        {PRIM_PTR, 8, SYSV64_INTEGER},
        {PRIM_STRING, 8, SYSV64_INTEGER},
        {PRIM_INT8, 1, SYSV64_INTEGER},
        {PRIM_UINT8, 1, SYSV64_INTEGER},
        {PRIM_INT16, 2, SYSV64_INTEGER},
        {PRIM_UINT16, 2, SYSV64_INTEGER},
        {PRIM_INT32, 4, SYSV64_INTEGER},
        {PRIM_UINT32, 4, SYSV64_INTEGER},
        {PRIM_INT64, 8, SYSV64_INTEGER},
        {PRIM_UINT64, 8, SYSV64_INTEGER},
        {PRIM_FLOAT, 4, SYSV64_SSE},
        {PRIM_DOUBLE, 8, SYSV64_SSE},
        {PRIM_VOID, 0, SYSV64_NO_CLASS},
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        JanetFFITypeNode node = leaf(cases[i].prim, cases[i].size, 0);
        assert(janet_ffi_sysv64_classify(&node, 1) == cases[i].expected);
    }
}

static void test_sysv64_sends_wide_structs_to_memory(void) {
    JanetFFITypeNode nodes[4];
    nodes[0] = struct_node(24, 3, 0);
    nodes[1] = leaf(PRIM_INT64, 8, 0);
    nodes[2] = leaf(PRIM_INT64, 8, 8);
    nodes[3] = leaf(PRIM_INT64, 8, 16);
    assert(janet_ffi_sysv64_classify(nodes, 4) == SYSV64_MEMORY);

    /* Exactly sixteen bytes still fits in the register pair. */
    JanetFFITypeNode fits[3];
    fits[0] = struct_node(16, 2, 0);
    fits[1] = leaf(PRIM_INT64, 8, 0);
    fits[2] = leaf(PRIM_INT64, 8, 8);
    assert(janet_ffi_sysv64_classify(fits, 3) == SYSV64_PAIR_INTINT);
}

static void test_sysv64_sends_misaligned_structs_to_memory(void) {
    JanetFFITypeNode nodes[3];
    nodes[0] = struct_node(9, 2, 0);
    nodes[0].is_aligned = 0;
    nodes[1] = leaf(PRIM_UINT8, 1, 0);
    nodes[2] = leaf(PRIM_UINT64, 8, 1);
    assert(janet_ffi_sysv64_classify(nodes, 3) == SYSV64_MEMORY);
}

static void test_sysv64_names_the_pair_of_a_wide_struct(void) {
    struct {
        uint32_t first;
        uint32_t second;
        uint32_t expected;
    } cases[] = {
        {PRIM_INT64, PRIM_INT64, SYSV64_PAIR_INTINT},
        {PRIM_INT64, PRIM_DOUBLE, SYSV64_PAIR_INTSSE},
        {PRIM_DOUBLE, PRIM_INT64, SYSV64_PAIR_SSEINT},
        {PRIM_DOUBLE, PRIM_DOUBLE, SYSV64_PAIR_SSESSE},
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        JanetFFITypeNode nodes[3];
        nodes[0] = struct_node(16, 2, 0);
        nodes[1] = leaf(cases[i].first, 8, 0);
        nodes[2] = leaf(cases[i].second, 8, 8);
        assert(janet_ffi_sysv64_classify(nodes, 3) == cases[i].expected);
    }
}

static void test_sysv64_merges_a_narrow_struct(void) {
    /* Two floats share one eightbyte and stay in the vector registers. */
    JanetFFITypeNode floats[3];
    floats[0] = struct_node(8, 2, 0);
    floats[1] = leaf(PRIM_FLOAT, 4, 0);
    floats[2] = leaf(PRIM_FLOAT, 4, 4);
    assert(janet_ffi_sysv64_classify(floats, 3) == SYSV64_SSE);

    /* An integer anywhere in the eightbyte makes the whole of it integer. */
    JanetFFITypeNode mixed[3];
    mixed[0] = struct_node(8, 2, 0);
    mixed[1] = leaf(PRIM_INT32, 4, 0);
    mixed[2] = leaf(PRIM_FLOAT, 4, 4);
    assert(janet_ffi_sysv64_classify(mixed, 3) == SYSV64_INTEGER);

    /* An empty struct reaches no class at all. */
    JanetFFITypeNode empty = struct_node(0, 0, 0);
    assert(janet_ffi_sysv64_classify(&empty, 1) == SYSV64_NO_CLASS);
}

static void test_sysv64_uses_the_offset_to_pick_the_eightbyte(void) {
    /* { float; float; int32; int32 }: the integers sit entirely in the second
     * eightbyte, so the low half is SSE and the high half integer. */
    JanetFFITypeNode nodes[5];
    nodes[0] = struct_node(16, 4, 0);
    nodes[1] = leaf(PRIM_FLOAT, 4, 0);
    nodes[2] = leaf(PRIM_FLOAT, 4, 4);
    nodes[3] = leaf(PRIM_INT32, 4, 8);
    nodes[4] = leaf(PRIM_INT32, 4, 12);
    assert(janet_ffi_sysv64_classify(nodes, 5) == SYSV64_PAIR_SSEINT);

    /* Moving one integer down into the first eightbyte moves the class with
     * it. */
    JanetFFITypeNode swapped[5];
    swapped[0] = struct_node(16, 4, 0);
    swapped[1] = leaf(PRIM_INT32, 4, 0);
    swapped[2] = leaf(PRIM_FLOAT, 4, 4);
    swapped[3] = leaf(PRIM_FLOAT, 4, 8);
    swapped[4] = leaf(PRIM_FLOAT, 4, 12);
    assert(janet_ffi_sysv64_classify(swapped, 5) == SYSV64_PAIR_INTSSE);
}

static void test_sysv64_descends_into_nested_structs(void) {
    /* { { double } ; int64 } — the nested struct classifies SSE on its own and
     * the outer pair is named from the two halves. */
    JanetFFITypeNode nodes[4];
    nodes[0] = struct_node(16, 2, 0);
    nodes[1] = struct_node(8, 1, 0);
    nodes[2] = leaf(PRIM_DOUBLE, 8, 0);
    nodes[3] = leaf(PRIM_INT64, 8, 8);
    assert(janet_ffi_sysv64_classify(nodes, 4) == SYSV64_PAIR_SSEINT);

    /* A nested struct that reached memory carries the whole enclosing type
     * there with it, when that type fits in a single eightbyte and so goes
     * through the merge rule. */
    JanetFFITypeNode packed[3];
    packed[0] = struct_node(8, 1, 0);
    packed[1] = struct_node(8, 1, 0);
    packed[1].is_aligned = 0;
    packed[2] = leaf(PRIM_UINT64, 8, 0);
    assert(janet_ffi_sysv64_classify(packed, 3) == SYSV64_MEMORY);
}

/* The two-eightbyte rules look only for integer classes, so a field that
 * reached memory is dropped instead of carrying the aggregate to memory the way
 * the merge rule just did. Recorded in FOUND.md; asserted here because it is
 * the behavior the port reproduces. */
static void test_sysv64_drops_a_memory_field_from_a_pair(void) {
    JanetFFITypeNode nodes[4];
    nodes[0] = struct_node(16, 2, 0);
    nodes[1] = struct_node(8, 1, 0);
    nodes[1].is_aligned = 0;
    nodes[2] = leaf(PRIM_UINT64, 8, 0);
    nodes[3] = leaf(PRIM_DOUBLE, 8, 8);
    assert(janet_ffi_sysv64_classify(nodes, 4) == SYSV64_PAIR_SSESSE);
}

/* A struct's fields must be walked in full even when a class is decided before
 * reaching them, or the node cursor lands on the wrong field. */
static void test_sysv64_skips_a_decided_subtree_correctly(void) {
    /* An outer struct wider than sixteen bytes is memory outright, and the walk
     * must still consume every node beneath it. */
    JanetFFITypeNode nodes[6];
    nodes[0] = struct_node(32, 2, 0);
    nodes[1] = struct_node(24, 3, 0);
    nodes[2] = leaf(PRIM_INT64, 8, 0);
    nodes[3] = leaf(PRIM_INT64, 8, 8);
    nodes[4] = leaf(PRIM_INT64, 8, 16);
    nodes[5] = leaf(PRIM_DOUBLE, 8, 24);
    assert(janet_ffi_sysv64_classify(nodes, 6) == SYSV64_MEMORY);

    /* { {float; float} ; int64 } : the second field of the outer struct is the
     * trailing integer, and reading one of the nested floats instead would name
     * the pair SSESSE rather than SSEINT. */
    JanetFFITypeNode nested[5];
    nested[0] = struct_node(16, 2, 0);
    nested[1] = struct_node(8, 2, 0);
    nested[2] = leaf(PRIM_FLOAT, 4, 0);
    nested[3] = leaf(PRIM_FLOAT, 4, 4);
    nested[4] = leaf(PRIM_INT64, 8, 8);
    assert(janet_ffi_sysv64_classify(nested, 5) == SYSV64_PAIR_SSEINT);
}

/* -- AAPCS64 classification ---------------------------------------------- */

static void test_aapcs64_classifies_scalars(void) {
    struct {
        uint32_t prim;
        uint64_t size;
        uint32_t expected;
    } cases[] = {
        {PRIM_BOOL, 1, AAPCS64_GENERAL},
        {PRIM_PTR, 8, AAPCS64_GENERAL},
        {PRIM_STRING, 8, AAPCS64_GENERAL},
        {PRIM_INT8, 1, AAPCS64_GENERAL},
        {PRIM_UINT64, 8, AAPCS64_GENERAL},
        {PRIM_FLOAT, 4, AAPCS64_SSE},
        {PRIM_DOUBLE, 8, AAPCS64_SSE},
        {PRIM_VOID, 0, AAPCS64_NONE},
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        JanetFFITypeNode node = leaf(cases[i].prim, cases[i].size, 0);
        assert(janet_ffi_aapcs64_classify(&node, 1) == cases[i].expected);
    }
}

static void test_aapcs64_recognises_homogeneous_float_aggregates(void) {
    /* Up to four members of one floating-point type travel in the vector
     * registers, however wide that makes the aggregate. */
    for (uint32_t count = 1; count <= 4; count++) {
        JanetFFITypeNode nodes[5];
        nodes[0] = struct_node(count * 8, count, 0);
        for (uint32_t i = 0; i < count; i++) {
            nodes[1 + i] = leaf(PRIM_DOUBLE, 8, i * 8);
        }
        assert(janet_ffi_aapcs64_classify(nodes, 1 + count) == AAPCS64_SSE);
    }

    /* A fifth member is one too many, and forty bytes then goes by reference. */
    JanetFFITypeNode five[6];
    five[0] = struct_node(40, 5, 0);
    for (uint32_t i = 0; i < 5; i++) {
        five[1 + i] = leaf(PRIM_DOUBLE, 8, i * 8);
    }
    assert(janet_ffi_aapcs64_classify(five, 6) == AAPCS64_GENERAL_REF);
}

static void test_aapcs64_rejects_inhomogeneous_aggregates(void) {
    /* Float and double are both floating point but not the same type. */
    JanetFFITypeNode mixed[3];
    mixed[0] = struct_node(16, 2, 0);
    mixed[1] = leaf(PRIM_FLOAT, 4, 0);
    mixed[2] = leaf(PRIM_DOUBLE, 8, 8);
    assert(janet_ffi_aapcs64_classify(mixed, 3) == AAPCS64_GENERAL);

    /* A leading integer takes it out of the floating-point case at the first
     * test. */
    JanetFFITypeNode leading[3];
    leading[0] = struct_node(16, 2, 0);
    leading[1] = leaf(PRIM_INT64, 8, 0);
    leading[2] = leaf(PRIM_DOUBLE, 8, 8);
    assert(janet_ffi_aapcs64_classify(leading, 3) == AAPCS64_GENERAL);
}

static void test_aapcs64_passes_wide_aggregates_by_reference(void) {
    JanetFFITypeNode narrow[3];
    narrow[0] = struct_node(16, 2, 0);
    narrow[1] = leaf(PRIM_INT64, 8, 0);
    narrow[2] = leaf(PRIM_INT64, 8, 8);
    assert(janet_ffi_aapcs64_classify(narrow, 3) == AAPCS64_GENERAL);

    JanetFFITypeNode wide[4];
    wide[0] = struct_node(24, 3, 0);
    wide[1] = leaf(PRIM_INT64, 8, 0);
    wide[2] = leaf(PRIM_INT64, 8, 8);
    wide[3] = leaf(PRIM_INT64, 8, 16);
    assert(janet_ffi_aapcs64_classify(wide, 4) == AAPCS64_GENERAL_REF);
}

/* An array of a struct measures wider than the struct itself, and it is the
 * array's width that decides whether it goes by reference. */
static void test_aapcs64_uses_the_whole_extent_of_an_array(void) {
    JanetFFITypeNode nodes[3];
    nodes[0] = struct_node(16, 2, 0);
    nodes[0].size = 48; /* three copies of a sixteen-byte struct */
    nodes[0].array_count = 3;
    nodes[1] = leaf(PRIM_INT64, 8, 0);
    nodes[2] = leaf(PRIM_INT64, 8, 8);
    assert(janet_ffi_aapcs64_classify(nodes, 3) == AAPCS64_GENERAL_REF);
}

/* `ffi.c` reads the first field of a struct with no fields; the port declines
 * to. A zero-field struct is reachable: a type of `[:pack]` names a member that
 * is not there. See FOUND.md. */
static void test_aapcs64_handles_an_empty_struct(void) {
    JanetFFITypeNode empty = struct_node(0, 0, 0);
    assert(janet_ffi_aapcs64_classify(&empty, 1) == AAPCS64_GENERAL);
}

/* -- Windows x64 allocation ---------------------------------------------- */

static void test_win64_fills_four_registers_then_the_stack(void) {
    JanetFFIArgSlot ret = slot(PRIM_INT64, 8, 8, 0);
    JanetFFIArgSlot args[6];
    for (int i = 0; i < 6; i++) args[i] = slot(PRIM_INT64, 8, 8, 0);
    JanetFFIAllocResult result;
    janet_ffi_win64_alloc(&result, &ret, args, 6);

    assert(result.error_kind == ALLOC_OK);
    for (uint32_t i = 0; i < 4; i++) {
        assert(args[i].spec == WIN64_REGISTER);
        assert(args[i].offset == i);
    }
    assert(args[4].spec == WIN64_STACK);
    assert(args[4].offset == 0);
    assert(args[5].spec == WIN64_STACK);
    assert(args[5].offset == 1);
    assert(result.stack_count == 2);
}

static void test_win64_marks_floating_registers_in_the_variant(void) {
    /* Each of the first four arguments owns one bit, counted from the top. */
    for (uint32_t position = 0; position < 4; position++) {
        JanetFFIArgSlot ret = slot(PRIM_VOID, 0, 1, 0);
        JanetFFIArgSlot args[4];
        for (int i = 0; i < 4; i++) args[i] = slot(PRIM_INT64, 8, 8, 0);
        args[position] = slot(PRIM_DOUBLE, 8, 8, 0);
        JanetFFIAllocResult result;
        janet_ffi_win64_alloc(&result, &ret, args, 4);
        assert(result.variant == (1u << (3 - position)));
    }

    /* A floating-point return adds its own bit above those four. */
    JanetFFIArgSlot ret = slot(PRIM_DOUBLE, 8, 8, 0);
    JanetFFIArgSlot args[1];
    args[0] = slot(PRIM_FLOAT, 4, 4, 0);
    JanetFFIAllocResult result;
    janet_ffi_win64_alloc(&result, &ret, args, 1);
    assert(result.variant == 16 + 8);
}

static void test_win64_passes_odd_sizes_by_reference(void) {
    /* Anything that is not one, two, four, or eight bytes wide goes through the
     * reference area rather than a register. */
    JanetFFIArgSlot ret = slot(PRIM_VOID, 0, 1, 0);
    JanetFFIArgSlot args[2];
    args[0] = slot(PRIM_STRUCT, 12, 4, 0);
    args[1] = slot(PRIM_INT64, 8, 8, 0);
    JanetFFIAllocResult result;
    janet_ffi_win64_alloc(&result, &ret, args, 2);

    assert(args[0].spec == WIN64_REGISTER_REF);
    assert(args[0].offset == 0);
    assert(args[1].spec == WIN64_REGISTER);
    assert(args[1].offset == 1);
    /* One sixteen-byte reference slot, so two eight-byte stack words. */
    assert(result.stack_count == 2);
    /* The reference offset is measured down from the top of the stack area. */
    assert(args[0].offset2 == 0);
}

static void test_win64_reserves_a_register_for_a_wide_return(void) {
    JanetFFIArgSlot ret = slot(PRIM_STRUCT, 24, 8, 0);
    JanetFFIArgSlot args[4];
    for (int i = 0; i < 4; i++) args[i] = slot(PRIM_INT64, 8, 8, 0);
    JanetFFIAllocResult result;
    janet_ffi_win64_alloc(&result, &ret, args, 4);

    assert(ret.spec == WIN64_REGISTER_REF);
    /* The first register holds the return pointer, so only three arguments fit
     * and the fourth spills. */
    assert(args[0].offset == 1);
    assert(args[2].spec == WIN64_REGISTER);
    assert(args[3].spec == WIN64_STACK);
}

static void test_win64_rounds_the_stack_to_an_even_number_of_words(void) {
    JanetFFIArgSlot ret = slot(PRIM_VOID, 0, 1, 0);
    JanetFFIArgSlot args[5];
    for (int i = 0; i < 5; i++) args[i] = slot(PRIM_INT64, 8, 8, 0);
    JanetFFIAllocResult result;
    janet_ffi_win64_alloc(&result, &ret, args, 5);
    /* One argument on the stack, rounded up to a pair. */
    assert(result.stack_count == 2);
}

/* -- SysV allocation ------------------------------------------------------ */

static void test_sysv64_fills_the_integer_registers(void) {
    JanetFFIArgSlot ret = slot(PRIM_VOID, 0, 1, SYSV64_NO_CLASS);
    JanetFFIArgSlot args[8];
    for (int i = 0; i < 8; i++) args[i] = slot(PRIM_INT64, 8, 8, SYSV64_INTEGER);
    JanetFFIAllocResult result;
    janet_ffi_sysv64_alloc(&result, &ret, args, 8);

    assert(result.error_kind == ALLOC_OK);
    for (uint32_t i = 0; i < 6; i++) {
        assert(args[i].spec == SYSV64_INTEGER);
        assert(args[i].offset == i);
    }
    assert(args[6].spec == SYSV64_MEMORY);
    assert(args[6].offset == 0);
    assert(args[7].spec == SYSV64_MEMORY);
    assert(args[7].offset == 1);
    assert(result.stack_count == 2);
}

static void test_sysv64_counts_the_vector_registers_separately(void) {
    JanetFFIArgSlot ret = slot(PRIM_VOID, 0, 1, SYSV64_NO_CLASS);
    JanetFFIArgSlot args[10];
    for (int i = 0; i < 10; i++) args[i] = slot(PRIM_DOUBLE, 8, 8, SYSV64_SSE);
    JanetFFIAllocResult result;
    janet_ffi_sysv64_alloc(&result, &ret, args, 10);

    for (uint32_t i = 0; i < 8; i++) {
        assert(args[i].spec == SYSV64_SSE);
        assert(args[i].offset == i);
    }
    assert(args[8].spec == SYSV64_MEMORY);
    assert(args[9].spec == SYSV64_MEMORY);
}

static void test_sysv64_reserves_a_register_for_a_memory_return(void) {
    JanetFFIArgSlot ret = slot(PRIM_STRUCT, 32, 8, SYSV64_MEMORY);
    JanetFFIArgSlot args[6];
    for (int i = 0; i < 6; i++) args[i] = slot(PRIM_INT64, 8, 8, SYSV64_INTEGER);
    JanetFFIAllocResult result;
    janet_ffi_sysv64_alloc(&result, &ret, args, 6);

    /* The hidden return pointer takes the first register. */
    assert(args[0].offset == 1);
    assert(args[4].offset == 5);
    assert(args[5].spec == SYSV64_MEMORY);
    assert(result.stack_count == 1);
}

static void test_sysv64_places_register_pairs(void) {
    JanetFFIArgSlot ret = slot(PRIM_VOID, 0, 1, SYSV64_NO_CLASS);
    JanetFFIArgSlot args[4];
    args[0] = slot(PRIM_STRUCT, 16, 8, SYSV64_PAIR_INTINT);
    args[1] = slot(PRIM_STRUCT, 16, 8, SYSV64_PAIR_INTSSE);
    args[2] = slot(PRIM_STRUCT, 16, 8, SYSV64_PAIR_SSEINT);
    args[3] = slot(PRIM_STRUCT, 16, 8, SYSV64_PAIR_SSESSE);
    JanetFFIAllocResult result;
    janet_ffi_sysv64_alloc(&result, &ret, args, 4);

    /* Two integer registers. */
    assert(args[0].offset == 0 && args[0].offset2 == 1);
    /* One integer then one vector. */
    assert(args[1].offset == 2 && args[1].offset2 == 0);
    /* A vector first, then an integer — the offsets swap roles. */
    assert(args[2].offset == 1 && args[2].offset2 == 3);
    /* Two vector registers. */
    assert(args[3].offset == 2 && args[3].offset2 == 3);
    assert(result.stack_count == 0);
}

/* An integer pair needs two free registers, and the check is strict: five used
 * of six is not enough. */
static void test_sysv64_spills_a_pair_that_cannot_fit(void) {
    JanetFFIArgSlot ret = slot(PRIM_VOID, 0, 1, SYSV64_NO_CLASS);
    JanetFFIArgSlot args[6];
    for (int i = 0; i < 5; i++) args[i] = slot(PRIM_INT64, 8, 8, SYSV64_INTEGER);
    args[5] = slot(PRIM_STRUCT, 16, 8, SYSV64_PAIR_INTINT);
    JanetFFIAllocResult result;
    janet_ffi_sysv64_alloc(&result, &ret, args, 6);

    assert(args[5].spec == SYSV64_MEMORY);
    assert(args[5].offset == 0);
    assert(result.stack_count == 2);
}

static void test_sysv64_names_the_return_variant(void) {
    struct {
        uint32_t ret_spec;
        uint32_t expected;
    } cases[] = {
        {SYSV64_INTEGER, 0},
        {SYSV64_SSE, 1},
        {SYSV64_PAIR_INTSSE, 2},
        {SYSV64_PAIR_SSEINT, 3},
        {SYSV64_PAIR_INTINT, 0},
        {SYSV64_MEMORY, 0},
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        JanetFFIArgSlot ret = slot(PRIM_STRUCT, 16, 8, cases[i].ret_spec);
        JanetFFIArgSlot args[1];
        args[0] = slot(PRIM_INT64, 8, 8, SYSV64_INTEGER);
        JanetFFIAllocResult result;
        janet_ffi_sysv64_alloc(&result, &ret, args, 1);
        assert(result.variant == cases[i].expected);
    }
}

static void test_sysv64_reports_a_spec_it_cannot_place(void) {
    JanetFFIArgSlot ret = slot(PRIM_VOID, 0, 1, SYSV64_NO_CLASS);
    JanetFFIArgSlot args[2];
    args[0] = slot(PRIM_INT64, 8, 8, SYSV64_INTEGER);
    args[1] = slot(PRIM_VOID, 0, 1, SYSV64_NO_CLASS);
    JanetFFIAllocResult result;
    janet_ffi_sysv64_alloc(&result, &ret, args, 2);

    assert(result.error_kind == ALLOC_UNSUPPORTED_SPEC);
    assert(result.error_arg == 1);
}

/* -- AAPCS64 allocation --------------------------------------------------- */

static void test_aapcs64_fills_both_register_banks(void) {
    JanetFFIArgSlot ret = slot(PRIM_VOID, 0, 1, AAPCS64_NONE);
    JanetFFIArgSlot args[4];
    args[0] = slot(PRIM_INT64, 8, 8, AAPCS64_GENERAL);
    args[1] = slot(PRIM_DOUBLE, 8, 8, AAPCS64_SSE);
    args[2] = slot(PRIM_INT64, 8, 8, AAPCS64_GENERAL);
    args[3] = slot(PRIM_DOUBLE, 8, 8, AAPCS64_SSE);
    JanetFFIAllocResult result;
    janet_ffi_aapcs64_alloc(&result, &ret, args, 4, 0, AAPCS64_MAX_RET);

    assert(result.error_kind == ALLOC_OK);
    assert(args[0].offset == 0);
    assert(args[1].offset == 0);
    assert(args[2].offset == 1);
    assert(args[3].offset == 1);
    assert(result.stack_count == 0);
}

/* A general aggregate occupies as many registers as it is words wide, and it
 * must fit entirely or go to the stack. */
static void test_aapcs64_takes_several_registers_for_an_aggregate(void) {
    JanetFFIArgSlot ret = slot(PRIM_VOID, 0, 1, AAPCS64_NONE);
    JanetFFIArgSlot args[3];
    args[0] = slot(PRIM_STRUCT, 16, 8, AAPCS64_GENERAL);
    args[1] = slot(PRIM_STRUCT, 16, 8, AAPCS64_GENERAL);
    args[2] = slot(PRIM_STRUCT, 16, 8, AAPCS64_GENERAL);
    JanetFFIAllocResult result;
    janet_ffi_aapcs64_alloc(&result, &ret, args, 3, 0, AAPCS64_MAX_RET);

    assert(args[0].offset == 0);
    assert(args[1].offset == 2);
    assert(args[2].offset == 4);
    assert(result.stack_count == 0);
}

static void test_aapcs64_packs_the_stack_by_platform(void) {
    /* Nine one-byte arguments: eight take the general registers and the ninth
     * goes to the stack. Both variants round the total to sixteen, so the
     * difference shows in where a second stack argument lands. */
    for (int apple = 0; apple <= 1; apple++) {
        JanetFFIArgSlot ret = slot(PRIM_VOID, 0, 1, AAPCS64_NONE);
        JanetFFIArgSlot args[10];
        for (int i = 0; i < 10; i++) args[i] = slot(PRIM_UINT8, 1, 1, AAPCS64_GENERAL);
        JanetFFIAllocResult result;
        janet_ffi_aapcs64_alloc(&result, &ret, args, 10, apple, AAPCS64_MAX_RET);

        assert(args[8].spec == AAPCS64_STACK);
        assert(args[8].offset == 0);
        assert(args[9].spec == AAPCS64_STACK);
        /* Apple packs the second byte next to the first; the generic standard
         * gives each a whole word. */
        assert(args[9].offset == (apple ? 1u : 8u));
        assert(result.stack_count == 16);
    }
}

static void test_aapcs64_aligns_stack_aggregates_to_a_word(void) {
    /* A struct on the stack is aligned as a word under both variants, even when
     * its own alignment is finer. */
    for (int apple = 0; apple <= 1; apple++) {
        JanetFFIArgSlot ret = slot(PRIM_VOID, 0, 1, AAPCS64_NONE);
        JanetFFIArgSlot args[10];
        for (int i = 0; i < 8; i++) args[i] = slot(PRIM_UINT8, 1, 1, AAPCS64_GENERAL);
        args[8] = slot(PRIM_UINT8, 1, 1, AAPCS64_GENERAL);
        args[9] = slot(PRIM_STRUCT, 3, 1, AAPCS64_GENERAL);
        JanetFFIAllocResult result;
        janet_ffi_aapcs64_alloc(&result, &ret, args, 10, apple, AAPCS64_MAX_RET);

        assert(args[9].spec == AAPCS64_STACK);
        assert(args[9].offset == 8);
    }
}

static void test_aapcs64_places_the_reference_area_after_the_stack(void) {
    JanetFFIArgSlot ret = slot(PRIM_VOID, 0, 1, AAPCS64_NONE);
    JanetFFIArgSlot args[2];
    args[0] = slot(PRIM_STRUCT, 24, 8, AAPCS64_GENERAL_REF);
    args[1] = slot(PRIM_STRUCT, 32, 8, AAPCS64_GENERAL_REF);
    JanetFFIAllocResult result;
    janet_ffi_aapcs64_alloc(&result, &ret, args, 2, 0, AAPCS64_MAX_RET);

    /* Both pointers fit in registers, so nothing sits in the stack area and the
     * reference area starts at zero. */
    assert(args[0].spec == AAPCS64_GENERAL_REF);
    assert(args[0].offset == 0);
    assert(args[0].offset2 == 0);
    assert(args[1].offset == 1);
    /* The first copy is twenty-four bytes, rounded up to the next word. */
    assert(args[1].offset2 == 24);
    /* Twenty-four plus thirty-two, rounded up to sixteen. */
    assert(result.stack_count == 64);
}

static void test_aapcs64_spills_a_reference_pointer(void) {
    JanetFFIArgSlot ret = slot(PRIM_VOID, 0, 1, AAPCS64_NONE);
    JanetFFIArgSlot args[9];
    for (int i = 0; i < 8; i++) args[i] = slot(PRIM_INT64, 8, 8, AAPCS64_GENERAL);
    args[8] = slot(PRIM_STRUCT, 24, 8, AAPCS64_GENERAL_REF);
    JanetFFIAllocResult result;
    janet_ffi_aapcs64_alloc(&result, &ret, args, 9, 0, AAPCS64_MAX_RET);

    assert(args[8].spec == AAPCS64_STACK_REF);
    assert(args[8].offset == 0);
    /* The pointer occupies one stack word, rounded to sixteen, and the copy
     * follows it. */
    assert(args[8].offset2 == 16);
    assert(result.stack_count == 16 + 32);
}

static void test_aapcs64_names_the_return_variant(void) {
    struct {
        uint32_t ret_spec;
        uint64_t ret_size;
        uint32_t expected;
    } cases[] = {
        {AAPCS64_GENERAL, 8, 0},
        {AAPCS64_SSE, 8, 1},
        {AAPCS64_GENERAL_REF, 24, 2},
        {AAPCS64_NONE, 0, 0},
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        JanetFFIArgSlot ret = slot(PRIM_STRUCT, cases[i].ret_size, 8, cases[i].ret_spec);
        JanetFFIArgSlot args[1];
        args[0] = slot(PRIM_INT64, 8, 8, AAPCS64_GENERAL);
        JanetFFIAllocResult result;
        janet_ffi_aapcs64_alloc(&result, &ret, args, 1, 0, AAPCS64_MAX_RET);
        assert(result.error_kind == ALLOC_OK);
        assert(result.variant == cases[i].expected);
    }
}

static void test_aapcs64_reports_an_oversized_return(void) {
    JanetFFIArgSlot ret = slot(PRIM_STRUCT, AAPCS64_MAX_RET + 1, 8, AAPCS64_GENERAL_REF);
    JanetFFIArgSlot args[1];
    args[0] = slot(PRIM_INT64, 8, 8, AAPCS64_GENERAL);
    JanetFFIAllocResult result;
    janet_ffi_aapcs64_alloc(&result, &ret, args, 1, 0, AAPCS64_MAX_RET);

    assert(result.error_kind == ALLOC_RETURN_TOO_BIG);
    assert(result.error_arg == -1);

    /* Exactly the buffer's width is still allowed. */
    JanetFFIArgSlot exact = slot(PRIM_STRUCT, AAPCS64_MAX_RET, 8, AAPCS64_GENERAL_REF);
    janet_ffi_aapcs64_alloc(&result, &exact, args, 1, 0, AAPCS64_MAX_RET);
    assert(result.error_kind == ALLOC_OK);
}

static void test_aapcs64_reports_a_spec_it_cannot_place(void) {
    JanetFFIArgSlot ret = slot(PRIM_VOID, 0, 1, AAPCS64_NONE);
    JanetFFIArgSlot args[2];
    args[0] = slot(PRIM_INT64, 8, 8, AAPCS64_GENERAL);
    args[1] = slot(PRIM_VOID, 0, 1, AAPCS64_NONE);
    JanetFFIAllocResult result;
    janet_ffi_aapcs64_alloc(&result, &ret, args, 2, 0, AAPCS64_MAX_RET);

    assert(result.error_kind == ALLOC_UNSUPPORTED_SPEC);
    assert(result.error_arg == 1);
}

/* -- Invariants ----------------------------------------------------------- */

/* Whatever the mix of arguments, a convention must never hand two of them the
 * same register, and every register it names must be one that exists. */
static void test_no_convention_reuses_a_register(void) {
    const uint32_t sysv_specs[] = {
        SYSV64_INTEGER, SYSV64_SSE, SYSV64_PAIR_INTINT,
        SYSV64_PAIR_INTSSE, SYSV64_PAIR_SSEINT, SYSV64_PAIR_SSESSE
    };
    const size_t spec_count = sizeof(sysv_specs) / sizeof(sysv_specs[0]);

    /* Walk a wide range of argument sequences by treating the case number as a
     * base-six numeral over the specs above. */
    for (uint32_t seed = 0; seed < 4096; seed++) {
        JanetFFIArgSlot ret = slot(PRIM_VOID, 0, 1, SYSV64_NO_CLASS);
        JanetFFIArgSlot args[5];
        uint32_t n = seed;
        for (int i = 0; i < 5; i++) {
            uint32_t spec = sysv_specs[n % spec_count];
            n /= (uint32_t) spec_count;
            args[i] = slot(PRIM_STRUCT, 16, 8, spec);
        }
        JanetFFIAllocResult result;
        janet_ffi_sysv64_alloc(&result, &ret, args, 5);
        assert(result.error_kind == ALLOC_OK);

        int int_used[6] = {0};
        int fp_used[8] = {0};
        uint32_t stack_words = 0;
        for (int i = 0; i < 5; i++) {
            switch (args[i].spec) {
                case SYSV64_INTEGER:
                    assert(args[i].offset < 6);
                    assert(!int_used[args[i].offset]);
                    int_used[args[i].offset] = 1;
                    break;
                case SYSV64_SSE:
                    assert(args[i].offset < 8);
                    assert(!fp_used[args[i].offset]);
                    fp_used[args[i].offset] = 1;
                    break;
                case SYSV64_PAIR_INTINT:
                    assert(args[i].offset < 6 && args[i].offset2 < 6);
                    assert(!int_used[args[i].offset] && !int_used[args[i].offset2]);
                    int_used[args[i].offset] = 1;
                    int_used[args[i].offset2] = 1;
                    break;
                case SYSV64_PAIR_INTSSE:
                    assert(args[i].offset < 6 && args[i].offset2 < 8);
                    assert(!int_used[args[i].offset] && !fp_used[args[i].offset2]);
                    int_used[args[i].offset] = 1;
                    fp_used[args[i].offset2] = 1;
                    break;
                case SYSV64_PAIR_SSEINT:
                    assert(args[i].offset < 8 && args[i].offset2 < 6);
                    assert(!fp_used[args[i].offset] && !int_used[args[i].offset2]);
                    fp_used[args[i].offset] = 1;
                    int_used[args[i].offset2] = 1;
                    break;
                case SYSV64_PAIR_SSESSE:
                    assert(args[i].offset < 8 && args[i].offset2 < 8);
                    assert(!fp_used[args[i].offset] && !fp_used[args[i].offset2]);
                    fp_used[args[i].offset] = 1;
                    fp_used[args[i].offset2] = 1;
                    break;
                case SYSV64_MEMORY:
                    /* Two words per sixteen-byte argument, laid down in order. */
                    assert(args[i].offset == stack_words);
                    stack_words += 2;
                    break;
                default:
                    assert(0 && "unexpected placement");
            }
        }
        assert(result.stack_count == stack_words);
    }
}

/* The same property for AAPCS64, where an aggregate can claim a run of
 * registers rather than just one or two. */
static void test_aapcs64_never_reuses_a_register(void) {
    const uint32_t sizes[] = {1, 8, 16, 24};
    const uint32_t specs[] = {AAPCS64_GENERAL, AAPCS64_SSE, AAPCS64_GENERAL_REF};

    for (int apple = 0; apple <= 1; apple++) {
        for (uint32_t seed = 0; seed < 4096; seed++) {
            JanetFFIArgSlot ret = slot(PRIM_VOID, 0, 1, AAPCS64_NONE);
            JanetFFIArgSlot args[6];
            uint32_t n = seed;
            for (int i = 0; i < 6; i++) {
                uint32_t spec = specs[n % 3];
                n /= 3;
                uint32_t size = sizes[n % 4];
                n /= 4;
                args[i] = slot(PRIM_STRUCT, size, 8, spec);
            }
            JanetFFIAllocResult result;
            janet_ffi_aapcs64_alloc(&result, &ret, args, 6, apple, AAPCS64_MAX_RET);
            assert(result.error_kind == ALLOC_OK);

            int general_used[8] = {0};
            int fp_used[8] = {0};
            for (int i = 0; i < 6; i++) {
                uint32_t words = (uint32_t)((args[i].size + 7) / 8);
                if (words == 0) words = 1;
                switch (args[i].spec) {
                    case AAPCS64_GENERAL:
                        for (uint32_t w = 0; w < words; w++) {
                            assert(args[i].offset + w < 8);
                            assert(!general_used[args[i].offset + w]);
                            general_used[args[i].offset + w] = 1;
                        }
                        break;
                    case AAPCS64_SSE:
                        for (uint32_t w = 0; w < words; w++) {
                            assert(args[i].offset + w < 8);
                            assert(!fp_used[args[i].offset + w]);
                            fp_used[args[i].offset + w] = 1;
                        }
                        break;
                    case AAPCS64_GENERAL_REF:
                        assert(args[i].offset < 8);
                        assert(!general_used[args[i].offset]);
                        general_used[args[i].offset] = 1;
                        break;
                    case AAPCS64_STACK:
                    case AAPCS64_STACK_REF:
                        /* Everything on the stack lies inside the area the
                         * convention reserved for it. */
                        assert(args[i].offset < result.stack_count);
                        break;
                    default:
                        assert(0 && "unexpected placement");
                }
                if (args[i].spec == AAPCS64_GENERAL_REF || args[i].spec == AAPCS64_STACK_REF) {
                    assert(args[i].offset2 + args[i].size <= result.stack_count);
                }
            }
            assert(result.stack_count % 16 == 0);
        }
    }
}

/* Once the registers are gone every later argument must stay on the stack: a
 * convention may not skip a wide argument and give a narrow one the register it
 * could not use. */
static void test_aapcs64_does_not_backfill_registers(void) {
    JanetFFIArgSlot ret = slot(PRIM_VOID, 0, 1, AAPCS64_NONE);
    JanetFFIArgSlot args[3];
    args[0] = slot(PRIM_STRUCT, 56, 8, AAPCS64_GENERAL); /* seven words */
    args[1] = slot(PRIM_STRUCT, 16, 8, AAPCS64_GENERAL); /* two words: will not fit */
    args[2] = slot(PRIM_INT64, 8, 8, AAPCS64_GENERAL);   /* one word: would fit */
    JanetFFIAllocResult result;
    janet_ffi_aapcs64_alloc(&result, &ret, args, 3, 0, AAPCS64_MAX_RET);

    assert(args[0].offset == 0);
    assert(args[1].spec == AAPCS64_STACK);
    assert(args[2].spec == AAPCS64_STACK);
}

void ffi_classify_contract(void) {
    test_sysv64_classifies_scalars();
    test_sysv64_sends_wide_structs_to_memory();
    test_sysv64_sends_misaligned_structs_to_memory();
    test_sysv64_names_the_pair_of_a_wide_struct();
    test_sysv64_merges_a_narrow_struct();
    test_sysv64_uses_the_offset_to_pick_the_eightbyte();
    test_sysv64_descends_into_nested_structs();
    test_sysv64_drops_a_memory_field_from_a_pair();
    test_sysv64_skips_a_decided_subtree_correctly();

    test_aapcs64_classifies_scalars();
    test_aapcs64_recognises_homogeneous_float_aggregates();
    test_aapcs64_rejects_inhomogeneous_aggregates();
    test_aapcs64_passes_wide_aggregates_by_reference();
    test_aapcs64_uses_the_whole_extent_of_an_array();
    test_aapcs64_handles_an_empty_struct();

    test_win64_fills_four_registers_then_the_stack();
    test_win64_marks_floating_registers_in_the_variant();
    test_win64_passes_odd_sizes_by_reference();
    test_win64_reserves_a_register_for_a_wide_return();
    test_win64_rounds_the_stack_to_an_even_number_of_words();

    test_sysv64_fills_the_integer_registers();
    test_sysv64_counts_the_vector_registers_separately();
    test_sysv64_reserves_a_register_for_a_memory_return();
    test_sysv64_places_register_pairs();
    test_sysv64_spills_a_pair_that_cannot_fit();
    test_sysv64_names_the_return_variant();
    test_sysv64_reports_a_spec_it_cannot_place();

    test_aapcs64_fills_both_register_banks();
    test_aapcs64_takes_several_registers_for_an_aggregate();
    test_aapcs64_packs_the_stack_by_platform();
    test_aapcs64_aligns_stack_aggregates_to_a_word();
    test_aapcs64_places_the_reference_area_after_the_stack();
    test_aapcs64_spills_a_reference_pointer();
    test_aapcs64_names_the_return_variant();
    test_aapcs64_reports_an_oversized_return();
    test_aapcs64_reports_a_spec_it_cannot_place();

    test_no_convention_reuses_a_register();
    test_aapcs64_never_reuses_a_register();
    test_aapcs64_does_not_backfill_registers();

    printf("ffi_classify: all tests passed\n");
}
