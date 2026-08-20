/* Behavioral contract for the FFI type system's portable kernels, run against
 * whichever implementation the build selected (`-Dffi-layout=c` or the Zig
 * default).
 *
 * The name tables are pinned name by name, including every alias, because a
 * table is exactly the kind of thing a port drops one entry from. The layout
 * machine is checked two ways: against fixed vectors, and against the offsets
 * the host C compiler itself assigns to equivalent structures. The second is
 * the stronger check — it says the machine reproduces the platform's ABI
 * rather than merely reproducing whatever the previous implementation did.
 *
 * All four calling-convention names are asserted here even though a build
 * enables at most one of them. Deciding which are enabled stays in `ffi.c`;
 * decoding a name does not depend on the target, and asserting that on every
 * target is the coverage the arch-gated C original could never have.
 */

#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <janet.h>

/* Declared rather than included from src/core/ffi.c, so the contract depends
 * only on the internal ABI it exercises. A compile-time assertion in that file
 * pins the ordinals below to the enumerations they mirror. */
typedef struct {
    uint32_t size;
    uint32_t alignment;
    uint32_t is_aligned;
} JanetFFILayout;

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
    CC_NONE = 0,
    CC_SYSV_64 = 1,
    CC_WIN_64 = 2,
    CC_AAPCS64 = 3
};

int32_t janet_ffi_decode_prim(const uint8_t *name, int32_t len);
int32_t janet_ffi_decode_cc(const uint8_t *name, int32_t len);
size_t janet_ffi_type_extent(size_t base_size, int32_t array_count);
void janet_ffi_layout_init(JanetFFILayout *layout);
size_t janet_ffi_layout_place(JanetFFILayout *layout, size_t el_size, size_t el_align, int packed_field);
void janet_ffi_layout_finish(JanetFFILayout *layout);

static int32_t prim(const char *name) {
    return janet_ffi_decode_prim((const uint8_t *) name, (int32_t) strlen(name));
}

static int32_t cc(const char *name) {
    return janet_ffi_decode_cc((const uint8_t *) name, (int32_t) strlen(name));
}

/* ------------------------------------------------------------ name tables */

static void test_primary_machine_types(void) {
    assert(prim("void") == PRIM_VOID);
    assert(prim("bool") == PRIM_BOOL);
    assert(prim("ptr") == PRIM_PTR);
    assert(prim("pointer") == PRIM_PTR);
    assert(prim("string") == PRIM_STRING);
    assert(prim("float") == PRIM_FLOAT);
    assert(prim("double") == PRIM_DOUBLE);
    assert(prim("int8") == PRIM_INT8);
    assert(prim("uint8") == PRIM_UINT8);
    assert(prim("int16") == PRIM_INT16);
    assert(prim("uint16") == PRIM_UINT16);
    assert(prim("int32") == PRIM_INT32);
    assert(prim("uint32") == PRIM_UINT32);
    assert(prim("int64") == PRIM_INT64);
    assert(prim("uint64") == PRIM_UINT64);
}

static void test_machine_type_aliases(void) {
    assert(prim("r32") == PRIM_FLOAT);
    assert(prim("r64") == PRIM_DOUBLE);
    assert(prim("s8") == PRIM_INT8);
    assert(prim("u8") == PRIM_UINT8);
    assert(prim("s16") == PRIM_INT16);
    assert(prim("u16") == PRIM_UINT16);
    assert(prim("s32") == PRIM_INT32);
    assert(prim("u32") == PRIM_UINT32);
    assert(prim("s64") == PRIM_INT64);
    assert(prim("u64") == PRIM_UINT64);
    assert(prim("char") == PRIM_INT8);
    assert(prim("short") == PRIM_INT16);
    assert(prim("int") == PRIM_INT32);
    assert(prim("long") == PRIM_INT64);
    assert(prim("byte") == PRIM_UINT8);
    assert(prim("uchar") == PRIM_UINT8);
    assert(prim("ushort") == PRIM_UINT16);
    assert(prim("uint") == PRIM_UINT32);
    assert(prim("ulong") == PRIM_UINT64);
}

/* The only two names whose meaning depends on the word size. */
static void test_word_sized_machine_types(void) {
#ifdef JANET_64
    assert(prim("size") == PRIM_UINT64);
    assert(prim("ssize") == PRIM_INT64);
#else
    assert(prim("size") == PRIM_UINT32);
    assert(prim("ssize") == PRIM_INT32);
#endif
}

static void test_unknown_machine_types(void) {
    assert(prim("nonesuch") == -1);
    assert(prim("") == -1);
    assert(prim("struct") == -1);       /* written as a tuple, never as a name */
    assert(prim("VOID") == -1);         /* the table is case sensitive */

    /* A prefix of a name and a name with something appended are both unknown:
     * the comparison is on the whole length, not on a leading run. */
    assert(janet_ffi_decode_prim((const uint8_t *) "void", 3) == -1);
    assert(janet_ffi_decode_prim((const uint8_t *) "voidx", 5) == -1);

    /* A keyword may contain a zero byte, so the length is what delimits the
     * name rather than a terminator. */
    assert(janet_ffi_decode_prim((const uint8_t *) "vo\0d", 4) == -1);
    assert(janet_ffi_decode_prim((const uint8_t *) "void\0x", 6) == -1);
}

static void test_calling_conventions(void) {
    /* Every convention decodes on every target, including the three that this
     * build cannot call through. */
    assert(cc("none") == CC_NONE);
    assert(cc("sysv64") == CC_SYSV_64);
    assert(cc("win64") == CC_WIN_64);
    assert(cc("aapcs64") == CC_AAPCS64);

    /* `default` resolves to whichever convention the build enables, which is a
     * property of the target; `ffi.c` maps it before reaching the table. */
    assert(cc("default") == -1);

    assert(cc("nonesuch") == -1);
    assert(cc("") == -1);
    assert(janet_ffi_decode_cc((const uint8_t *) "win64", 4) == -1);
}

/* ----------------------------------------------------------- type extents */

static void test_type_extent(void) {
    /* A negative count means the type is not an array at all. */
    assert(janet_ffi_type_extent(8, -1) == 8);
    assert(janet_ffi_type_extent(0, -1) == 0);
    assert(janet_ffi_type_extent(3, -7) == 3);

    /* `@[type]` with no count decodes to a count of zero, which is a real zero
     * rather than a missing one. */
    assert(janet_ffi_type_extent(8, 0) == 0);

    assert(janet_ffi_type_extent(1, 17) == 17);
    assert(janet_ffi_type_extent(4, 3) == 12);
    assert(janet_ffi_type_extent(8, 1024) == 8192);
}

/* ------------------------------------------------------- layout machinery */

static void test_layout_of_nothing(void) {
    JanetFFILayout layout;
    janet_ffi_layout_init(&layout);
    assert(layout.size == 0);
    assert(layout.alignment == 1);
    assert(layout.is_aligned == 1);
    janet_ffi_layout_finish(&layout);
    assert(layout.size == 0);
    assert(layout.alignment == 1);
    assert(layout.is_aligned == 1);
}

static void test_layout_pads_between_fields(void) {
    JanetFFILayout layout;
    janet_ffi_layout_init(&layout);
    assert(janet_ffi_layout_place(&layout, 1, 1, 0) == 0);
    /* Seven bytes of padding ahead of the eight-byte field. */
    assert(janet_ffi_layout_place(&layout, 8, 8, 0) == 8);
    assert(janet_ffi_layout_place(&layout, 2, 2, 0) == 16);
    janet_ffi_layout_finish(&layout);
    /* 18 bytes rounded up to the struct's own eight-byte alignment. */
    assert(layout.size == 24);
    assert(layout.alignment == 8);
    assert(layout.is_aligned == 1);
}

static void test_layout_takes_the_strictest_alignment(void) {
    JanetFFILayout layout;
    janet_ffi_layout_init(&layout);
    assert(janet_ffi_layout_place(&layout, 2, 2, 0) == 0);
    assert(janet_ffi_layout_place(&layout, 4, 4, 0) == 4);
    assert(janet_ffi_layout_place(&layout, 1, 1, 0) == 8);
    janet_ffi_layout_finish(&layout);
    assert(layout.size == 12);
    assert(layout.alignment == 4);
}

static void test_layout_of_a_single_field(void) {
    JanetFFILayout layout;
    janet_ffi_layout_init(&layout);
    assert(janet_ffi_layout_place(&layout, 4, 4, 0) == 0);
    janet_ffi_layout_finish(&layout);
    assert(layout.size == 4);
    assert(layout.alignment == 4);
}

/* An array member contributes its whole extent but only its element's
 * alignment, which is what `janet_ffi_type_extent` and `type_align` produce
 * together. */
static void test_layout_of_an_array_member(void) {
    JanetFFILayout layout;
    janet_ffi_layout_init(&layout);
    assert(janet_ffi_layout_place(&layout, 1, 1, 0) == 0);
    assert(janet_ffi_layout_place(&layout, janet_ffi_type_extent(4, 3), 4, 0) == 4);
    janet_ffi_layout_finish(&layout);
    assert(layout.size == 16);
    assert(layout.alignment == 4);
}

static void test_packed_fields_leave_no_padding(void) {
    JanetFFILayout layout;
    janet_ffi_layout_init(&layout);
    assert(janet_ffi_layout_place(&layout, 1, 1, 1) == 0);
    assert(janet_ffi_layout_place(&layout, 8, 8, 1) == 1);
    assert(janet_ffi_layout_place(&layout, 2, 2, 1) == 9);
    janet_ffi_layout_finish(&layout);
    /* Nothing was padded and nothing raised the struct's alignment, so the
     * total is the plain sum. */
    assert(layout.size == 11);
    assert(layout.alignment == 1);
    /* Two of the three landed off their natural boundary. */
    assert(layout.is_aligned == 0);
}

static void test_packed_fields_can_still_be_aligned(void) {
    JanetFFILayout layout;
    janet_ffi_layout_init(&layout);
    assert(janet_ffi_layout_place(&layout, 4, 4, 1) == 0);
    assert(janet_ffi_layout_place(&layout, 4, 4, 1) == 4);
    janet_ffi_layout_finish(&layout);
    assert(layout.size == 8);
    /* A packed field contributes nothing to the struct's alignment even when
     * it happens to sit on its own boundary. */
    assert(layout.alignment == 1);
    assert(layout.is_aligned == 1);
}

/* `:pack` packs one member and `:pack-all` packs the rest, so a layout can mix
 * the two kinds of placement. */
static void test_layout_mixes_packed_and_aligned_fields(void) {
    JanetFFILayout layout;
    janet_ffi_layout_init(&layout);
    assert(janet_ffi_layout_place(&layout, 1, 1, 0) == 0);
    assert(janet_ffi_layout_place(&layout, 4, 4, 1) == 1);
    assert(janet_ffi_layout_place(&layout, 8, 8, 0) == 8);
    janet_ffi_layout_finish(&layout);
    assert(layout.size == 16);
    assert(layout.alignment == 8);
    assert(layout.is_aligned == 0);
}

/* The rounding at the end is what makes an array of the struct place every
 * element on the alignment its fields demand. */
static void test_layout_rounds_the_total_up(void) {
    JanetFFILayout layout;
    janet_ffi_layout_init(&layout);
    assert(janet_ffi_layout_place(&layout, 8, 8, 0) == 0);
    assert(janet_ffi_layout_place(&layout, 1, 1, 0) == 8);
    assert(layout.size == 9);
    janet_ffi_layout_finish(&layout);
    assert(layout.size == 16);
    assert(layout.size % layout.alignment == 0);
}

/* --------------------------------------------- agreement with the host ABI */

struct host_char_double {
    char a;
    double b;
};

struct host_mixed {
    char a;
    int32_t b;
    char c;
    double d;
    int16_t e;
};

struct host_nested {
    int16_t a;
    struct host_char_double b;
    char c;
};

/* Lay out the equivalent of a C structure and compare every offset and the
 * total against what the host compiler assigned. This is what says the machine
 * reproduces the platform ABI rather than only its own past output. */
static void test_layout_matches_the_host_compiler(void) {
    JanetFFILayout layout;

    janet_ffi_layout_init(&layout);
    assert(janet_ffi_layout_place(&layout, sizeof(char), sizeof(char), 0)
           == offsetof(struct host_char_double, a));
    assert(janet_ffi_layout_place(&layout, sizeof(double), sizeof(double), 0)
           == offsetof(struct host_char_double, b));
    janet_ffi_layout_finish(&layout);
    assert(layout.size == sizeof(struct host_char_double));
    assert(layout.alignment == sizeof(double));

    janet_ffi_layout_init(&layout);
    assert(janet_ffi_layout_place(&layout, sizeof(char), sizeof(char), 0)
           == offsetof(struct host_mixed, a));
    assert(janet_ffi_layout_place(&layout, sizeof(int32_t), sizeof(int32_t), 0)
           == offsetof(struct host_mixed, b));
    assert(janet_ffi_layout_place(&layout, sizeof(char), sizeof(char), 0)
           == offsetof(struct host_mixed, c));
    assert(janet_ffi_layout_place(&layout, sizeof(double), sizeof(double), 0)
           == offsetof(struct host_mixed, d));
    assert(janet_ffi_layout_place(&layout, sizeof(int16_t), sizeof(int16_t), 0)
           == offsetof(struct host_mixed, e));
    janet_ffi_layout_finish(&layout);
    assert(layout.size == sizeof(struct host_mixed));

    /* A nested structure enters as its own size and alignment, which is how
     * `type_size` and `type_align` present one. */
    janet_ffi_layout_init(&layout);
    assert(janet_ffi_layout_place(&layout, sizeof(int16_t), sizeof(int16_t), 0)
           == offsetof(struct host_nested, a));
    assert(janet_ffi_layout_place(&layout, sizeof(struct host_char_double),
                                  sizeof(double), 0)
           == offsetof(struct host_nested, b));
    assert(janet_ffi_layout_place(&layout, sizeof(char), sizeof(char), 0)
           == offsetof(struct host_nested, c));
    janet_ffi_layout_finish(&layout);
    assert(layout.size == sizeof(struct host_nested));
}

/* ------------------------------------------------------------- invariants */

/* Sweep every combination of a few sizes and alignments and check the rules
 * that must hold whatever the inputs were, rather than a stored expectation
 * for each one. */
static void test_layout_invariants_over_a_sweep(void) {
    static const size_t alignments[] = {1, 2, 4, 8, 16};
    static const size_t sizes[] = {1, 2, 3, 4, 7, 8, 12, 16, 31};

    for (size_t ai = 0; ai < sizeof(alignments) / sizeof(alignments[0]); ai++) {
        for (size_t si = 0; si < sizeof(sizes) / sizeof(sizes[0]); si++) {
            for (size_t bi = 0; bi < sizeof(alignments) / sizeof(alignments[0]); bi++) {
                for (size_t ti = 0; ti < sizeof(sizes) / sizeof(sizes[0]); ti++) {
                    JanetFFILayout layout;
                    janet_ffi_layout_init(&layout);

                    size_t first = janet_ffi_layout_place(&layout, sizes[si], alignments[ai], 0);
                    assert(first == 0);
                    assert(layout.size == sizes[si]);

                    size_t second = janet_ffi_layout_place(&layout, sizes[ti], alignments[bi], 0);
                    /* Each field starts on its own boundary, never before the
                     * end of the field ahead of it, and never further past it
                     * than that boundary requires. */
                    assert(second % alignments[bi] == 0);
                    assert(second >= sizes[si]);
                    assert(second - sizes[si] < alignments[bi]);
                    assert(layout.size == second + sizes[ti]);

                    uint32_t before_rounding = layout.size;
                    janet_ffi_layout_finish(&layout);

                    /* The struct takes the strictest alignment any field asked
                     * for, its total is a whole number of those, and rounding
                     * never loses a byte or adds a needless one. */
                    size_t expected_align = alignments[ai] > alignments[bi]
                                            ? alignments[ai] : alignments[bi];
                    assert(layout.alignment == expected_align);
                    assert(layout.size % layout.alignment == 0);
                    assert(layout.size >= before_rounding);
                    assert(layout.size - before_rounding < layout.alignment);
                    /* Nothing was packed, so the layout is a natural one. */
                    assert(layout.is_aligned == 1);
                }
            }
        }
    }
}

/* A packed sweep: no padding anywhere, no contribution to the alignment, and
 * the aligned flag reporting exactly whether every field happened to land on
 * its own boundary. */
static void test_packed_layout_invariants_over_a_sweep(void) {
    static const size_t alignments[] = {1, 2, 4, 8, 16};
    static const size_t sizes[] = {1, 3, 4, 5, 8, 13};

    for (size_t ai = 0; ai < sizeof(alignments) / sizeof(alignments[0]); ai++) {
        for (size_t si = 0; si < sizeof(sizes) / sizeof(sizes[0]); si++) {
            for (size_t bi = 0; bi < sizeof(alignments) / sizeof(alignments[0]); bi++) {
                for (size_t ti = 0; ti < sizeof(sizes) / sizeof(sizes[0]); ti++) {
                    JanetFFILayout layout;
                    janet_ffi_layout_init(&layout);

                    assert(janet_ffi_layout_place(&layout, sizes[si], alignments[ai], 1) == 0);
                    size_t second = janet_ffi_layout_place(&layout, sizes[ti], alignments[bi], 1);
                    assert(second == sizes[si]);

                    janet_ffi_layout_finish(&layout);
                    assert(layout.alignment == 1);
                    assert(layout.size == sizes[si] + sizes[ti]);

                    /* The first field sits at zero and so is always natural;
                     * the second is natural exactly when the first field's
                     * size is a multiple of its alignment. */
                    int both_natural = (0 == sizes[si] % alignments[bi]);
                    assert(layout.is_aligned == (uint32_t)(both_natural ? 1 : 0));
                }
            }
        }
    }
}

void ffi_layout_contract(void) {
    test_primary_machine_types();
    test_machine_type_aliases();
    test_word_sized_machine_types();
    test_unknown_machine_types();
    test_calling_conventions();

    test_type_extent();

    test_layout_of_nothing();
    test_layout_pads_between_fields();
    test_layout_takes_the_strictest_alignment();
    test_layout_of_a_single_field();
    test_layout_of_an_array_member();
    test_packed_fields_leave_no_padding();
    test_packed_fields_can_still_be_aligned();
    test_layout_mixes_packed_and_aligned_fields();
    test_layout_rounds_the_total_up();

    test_layout_matches_the_host_compiler();
    test_layout_invariants_over_a_sweep();
    test_packed_layout_invariants_over_a_sweep();

    printf("ffi_layout: all tests passed\n");
}
