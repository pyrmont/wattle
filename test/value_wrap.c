/* Behavioral contract for the value representation: everything `wrap.c`
 * defines. Run against whichever implementation the build selected
 * (`-Dvalue-wrap=c` or the Zig default).
 *
 * This is the one file in Phase 8 whose *content* changes shape per target.
 * `JANET_NANBOX_64`, `JANET_NANBOX_32` and the tagged fallback are three
 * different implementations behind one set of signatures, so the tests below
 * come in two kinds and both are needed.
 *
 *  - The layout-independent ones, which are the bulk. A wrapper's type tag, a
 *    round trip through the matching unwrapper, the fact that two wrappers over
 *    the same pointer produce values that are not equal, truthiness, and the
 *    `janet_checktype`/`janet_checktypes` agreement matrix. These say the
 *    representation is *a* working one.
 *
 *  - The layout-dependent ones, guarded by the same `#ifdef` chain `janet.h`
 *    uses, which assert absolute bit patterns computed from the header's own
 *    constants. These say it is *the* one. Without them a port that shifted
 *    every tag by one would pass everything above.
 *
 * A third channel is available here and nowhere else in the phase. `wrap.c`
 * exists to provide a function form of what `janet.h` provides as a macro, so
 * for every entry point that has both, the two spellings must agree. C's rule
 * that a parenthesised name is not macro-expanded is what lets one file call
 * both -- and it is exactly the spelling `wrap.c` uses to define them.
 *
 * That channel is weaker than it looks and the weakness is worth stating: under
 * either NaN-boxed layout the macro bottoms out in `janet_nanbox_from_bits` and
 * friends, which this increment also ports, so the comparison is between two
 * paths through the same implementation rather than against the header. It
 * catches a wrapper wired to the wrong helper and nothing more. The absolute
 * bit patterns are what catch the helper itself.
 *
 * `janet_wrap_integer` is referenced only under a NaN-boxed layout. That is not
 * tidiness: `wrap.c` defines it only there, so a tagged build has no such
 * symbol and referencing it would fail to link. `FOUND.md` records it, and the
 * `#if` below is what pins the port to the same asymmetry.
 *
 * The file includes `state.h` for `janet_vm.next_collection`, which
 * `janet_memalloc_empty` charges, and `util.h`, which is where that function
 * and `janet_memempty` are declared.
 */

#include <assert.h>
#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "features.h"
#include <janet.h>
#include "state.h"
#include "util.h"

static JanetTable *test_env;

/* ------------------------------------------------------------------ helpers */

/* Two values are the same value when their payload word and their type agree.
 * `memcmp` would be wrong under the tagged layout, whose `Janet` is twelve
 * bytes of content in a sixteen-byte structure: neither implementation writes
 * the padding, and neither is required to. */
static int same_value(Janet a, Janet b) {
    return janet_u64(a) == janet_u64(b) && janet_type(a) == janet_type(b);
}

/* A cfunction to wrap. Its address is the only function pointer in the file,
 * and under a pointer-shifted NaN-box it has to satisfy the same alignment
 * every registered cfunction does. */
static Janet a_cfunction(int32_t argc, Janet *argv) {
    (void) argc;
    (void) argv;
    return janet_wrap_nil();
}

/* Sixteen-byte-aligned storage, so the addresses handed to the pointer
 * wrappers are legal under every value of JANET_NANBOX_64_POINTER_SHIFT, which
 * ranges up to 4. A shift discards low bits that the wrapper never restores,
 * so an under-aligned pointer would not round trip on aarch64 Linux and would
 * on macOS -- a difference in the test rather than in the code. */
typedef union {
    double alignment[2];
    char bytes[64];
} aligned_block;

static aligned_block block_a;
static aligned_block block_b;

/* -------------------------------------------------- type tags and round trips */

/* Every wrapper stamps its own type, and `janet_type` reads it back. This is
 * the whole of the representation's job stated once. The pointers are not
 * dereferenced by anything here: a wrapper stores an address and a tag, and
 * whether the address points at a real object is the collector's problem. */
static void test_each_wrapper_stamps_its_type(void) {
    void *p = &block_a;
    assert(janet_type(janet_wrap_nil()) == JANET_NIL);
    assert(janet_type(janet_wrap_true()) == JANET_BOOLEAN);
    assert(janet_type(janet_wrap_false()) == JANET_BOOLEAN);
    assert(janet_type(janet_wrap_boolean(1)) == JANET_BOOLEAN);
    assert(janet_type(janet_wrap_number(1.5)) == JANET_NUMBER);
    assert(janet_type(janet_wrap_string((JanetString) p)) == JANET_STRING);
    assert(janet_type(janet_wrap_symbol((JanetSymbol) p)) == JANET_SYMBOL);
    assert(janet_type(janet_wrap_keyword((JanetKeyword) p)) == JANET_KEYWORD);
    assert(janet_type(janet_wrap_array((JanetArray *) p)) == JANET_ARRAY);
    assert(janet_type(janet_wrap_tuple((JanetTuple) p)) == JANET_TUPLE);
    assert(janet_type(janet_wrap_struct((JanetStruct) p)) == JANET_STRUCT);
    assert(janet_type(janet_wrap_fiber((JanetFiber *) p)) == JANET_FIBER);
    assert(janet_type(janet_wrap_buffer((JanetBuffer *) p)) == JANET_BUFFER);
    assert(janet_type(janet_wrap_function((JanetFunction *) p)) == JANET_FUNCTION);
    assert(janet_type(janet_wrap_cfunction(a_cfunction)) == JANET_CFUNCTION);
    assert(janet_type(janet_wrap_table((JanetTable *) p)) == JANET_TABLE);
    assert(janet_type(janet_wrap_abstract(p)) == JANET_ABSTRACT);
    assert(janet_type(janet_wrap_pointer(p)) == JANET_POINTER);
}

/* Every pointer wrapper hands back the pointer it was given, for two different
 * addresses -- static storage and a heap block, which differ in their high
 * bits on every target that nanboxes. */
static void test_pointer_round_trips(void) {
    void *ps[3];
    size_t i;
    ps[0] = &block_a;
    ps[1] = &block_b;
    ps[2] = janet_malloc(64);
    assert(ps[2] != NULL);
    for (i = 0; i < 3; i++) {
        void *p = ps[i];
        assert(janet_unwrap_string(janet_wrap_string((JanetString) p)) == (JanetString) p);
        assert(janet_unwrap_symbol(janet_wrap_symbol((JanetSymbol) p)) == (JanetSymbol) p);
        assert(janet_unwrap_keyword(janet_wrap_keyword((JanetKeyword) p)) == (JanetKeyword) p);
        assert(janet_unwrap_array(janet_wrap_array((JanetArray *) p)) == (JanetArray *) p);
        assert(janet_unwrap_tuple(janet_wrap_tuple((JanetTuple) p)) == (JanetTuple) p);
        assert(janet_unwrap_struct(janet_wrap_struct((JanetStruct) p)) == (JanetStruct) p);
        assert(janet_unwrap_fiber(janet_wrap_fiber((JanetFiber *) p)) == (JanetFiber *) p);
        assert(janet_unwrap_buffer(janet_wrap_buffer((JanetBuffer *) p)) == (JanetBuffer *) p);
        assert(janet_unwrap_function(janet_wrap_function((JanetFunction *) p)) == (JanetFunction *) p);
        assert(janet_unwrap_table(janet_wrap_table((JanetTable *) p)) == (JanetTable *) p);
        assert(janet_unwrap_abstract(janet_wrap_abstract(p)) == p);
        assert(janet_unwrap_pointer(janet_wrap_pointer(p)) == p);
    }
    assert(janet_unwrap_cfunction(janet_wrap_cfunction(a_cfunction)) == a_cfunction);
    janet_free(ps[2]);
}

/* A NULL payload is a legal value for every pointer type -- `janet_wrap_fiber`
 * is called with one every time a fiber has no child. It must not be confused
 * with nil, and it must come back NULL. */
static void test_null_payloads_round_trip(void) {
    assert(janet_unwrap_fiber(janet_wrap_fiber(NULL)) == NULL);
    assert(janet_unwrap_pointer(janet_wrap_pointer(NULL)) == NULL);
    assert(janet_unwrap_abstract(janet_wrap_abstract(NULL)) == NULL);
    assert(janet_type(janet_wrap_fiber(NULL)) == JANET_FIBER);
    assert(!janet_checktype(janet_wrap_pointer(NULL), JANET_NIL));
    assert(janet_truthy(janet_wrap_pointer(NULL)));
    /* `janet_truthy` is a macro under all three layouts, so every assertion
     * above tests `janet.h` rather than the library. The function form is what
     * `wrap.c` exists to provide, and it needs the same two false values. */
    assert(!(janet_truthy)(janet_wrap_nil()));
    assert(!(janet_truthy)(janet_wrap_false()));
    assert(!(janet_truthy)(janet_wrap_boolean(0)));
    assert((janet_truthy)(janet_wrap_true()));
    assert((janet_truthy)(janet_wrap_boolean(1)));
    assert((janet_truthy)(janet_wrap_number(0.0)));
    assert((janet_truthy)(janet_wrap_pointer(NULL)));
}

/* The same address under two tags is two different values. This is what a
 * representation that dropped or shared a tag would fail, and it is the reason
 * a keyword and a string spelled alike are not `=` even though they hash
 * alike. */
static void test_the_tag_is_part_of_the_value(void) {
    void *p = &block_a;
    Janet as_array = janet_wrap_array((JanetArray *) p);
    Janet as_table = janet_wrap_table((JanetTable *) p);
    Janet as_pointer = janet_wrap_pointer(p);
    assert(!same_value(as_array, as_table));
    assert(!same_value(as_array, as_pointer));
    assert(!same_value(as_table, as_pointer));
    assert(!same_value(janet_wrap_string((JanetString) p), janet_wrap_symbol((JanetSymbol) p)));
    assert(!same_value(janet_wrap_symbol((JanetSymbol) p), janet_wrap_keyword((JanetKeyword) p)));
    assert(!same_value(janet_wrap_true(), janet_wrap_false()));
    assert(!same_value(janet_wrap_nil(), janet_wrap_false()));
}

/* ----------------------------------------------------------------- numbers */

/* Doubles survive the representation exactly, including the ones that are
 * awkward to store beside a tag: both zeroes, both infinities, the smallest
 * subnormal, and the largest finite. Under either NaN-boxed layout the
 * exponent field these share with the tag is what makes the test worth
 * writing. */
static void test_numbers_round_trip(void) {
    double xs[9];
    size_t i;
    xs[0] = 0.0;
    xs[1] = -0.0;
    xs[2] = 1.0;
    xs[3] = -1.0;
    xs[4] = 0.5;
    xs[5] = 1.0 / 0.0;
    xs[6] = -1.0 / 0.0;
    xs[7] = 5e-324;
    xs[8] = 1.7976931348623157e308;
    for (i = 0; i < 9; i++) {
        Janet v = janet_wrap_number(xs[i]);
        assert(janet_type(v) == JANET_NUMBER);
        assert(janet_checktype(v, JANET_NUMBER));
        assert(janet_unwrap_number(v) == xs[i] || (xs[i] != xs[i]));
    }
    /* Negative zero is preserved as a bit pattern, not merely as a value:
     * `janet_hash` normalizes it away and the representation must not. */
    assert(janet_unwrap_number(janet_wrap_number(-0.0)) == 0.0);
    assert(1.0 / janet_unwrap_number(janet_wrap_number(-0.0)) < 0.0);
}

/* A NaN is a number, not a tagged value. Under a NaN-boxed layout this is the
 * one case where the tag space and the payload space collide, and `janet_type`
 * has to answer JANET_NUMBER for a quiet NaN whose bits look like a tag. */
static void test_nan_is_a_number(void) {
    double nan_value = 0.0 / 0.0;
    Janet v = janet_wrap_number(nan_value);
    assert(janet_type(v) == JANET_NUMBER);
    assert(janet_checktype(v, JANET_NUMBER));
    assert(!janet_checktype(v, JANET_NIL));
    assert(janet_unwrap_number(v) != janet_unwrap_number(v));
    assert(janet_truthy(v));
    /* And through the functions, which is a different code path and the one a
     * language binding calls. Under a NaN-boxed layout the type nibble of a
     * canonical NaN reads as JANET_NUMBER, so the second arm of
     * `janet_nanbox_isnumber` is what answers here and the first is what
     * answers for every other double. Asserting only the macro leaves that arm
     * untested in the library -- which a mutation sweep found. */
    assert((janet_type)(v) == JANET_NUMBER);
    assert((janet_checktype)(v, JANET_NUMBER));
    assert(!(janet_checktype)(v, JANET_NIL));
    assert((janet_truthy)(v));
    assert((janet_checktypes)(v, JANET_TFLAG_NUMBER) != 0);
}

/* `janet_wrap_number_safe` is the entry point unmarshalling uses for a double
 * that came off the wire, and its job is to make sure a crafted payload cannot
 * be read back as a tagged value. Under both NaN-boxed layouts it replaces any
 * NaN with the canonical quiet one; under the tagged layout it does not,
 * because there is no tag space in the double to protect. That asymmetry is in
 * the C original. */
static void test_wrap_number_safe(void) {
    double finite[3];
    size_t i;
    finite[0] = 0.0;
    finite[1] = -3.25;
    finite[2] = 1.0 / 0.0;
    for (i = 0; i < 3; i++) {
        assert(same_value(janet_wrap_number_safe(finite[i]), janet_wrap_number(finite[i])));
    }
    assert(janet_type(janet_wrap_number_safe(0.0 / 0.0)) == JANET_NUMBER);
#if defined(JANET_NANBOX_64) || defined(JANET_NANBOX_32)
    {
        /* A signalling NaN with a payload in the low bits, which is what a
         * hostile marshalled double looks like. */
        union {
            uint64_t u;
            double d;
        } hostile;
        hostile.u = 0x7FF0000000000123ull;
        assert(hostile.d != hostile.d);
        assert(same_value(janet_wrap_number_safe(hostile.d), janet_wrap_number_safe(0.0 / 0.0)));
    }
#endif
}

/* `janet_unwrap_integer` is `(int32_t)` applied to the double, so it truncates
 * toward zero. Only in-range inputs are checked: the C original's cast is
 * undefined outside the destination range and the two behavioral targets
 * already disagree about it, so nothing here can be asserted for both
 * selectors. `FOUND.md` records what the port does instead. */
static void test_integer_conversions(void) {
    assert(janet_unwrap_integer(janet_wrap_number(0.0)) == 0);
    assert(janet_unwrap_integer(janet_wrap_number(1.9)) == 1);
    assert(janet_unwrap_integer(janet_wrap_number(-1.9)) == -1);
    assert(janet_unwrap_integer(janet_wrap_number(2147483647.0)) == INT32_MAX);
    assert(janet_unwrap_integer(janet_wrap_number(-2147483648.0)) == INT32_MIN);
#if defined(JANET_NANBOX_64) || defined(JANET_NANBOX_32)
    /* Not referenced under the tagged layout, where the symbol does not
     * exist. See the header and `FOUND.md`. */
    assert(same_value((janet_wrap_integer)(7), janet_wrap_number(7.0)));
    assert(same_value((janet_wrap_integer)(INT32_MIN), janet_wrap_number(-2147483648.0)));
    assert(janet_unwrap_integer((janet_wrap_integer)(-5)) == -5);
#endif
    assert(janet_unwrap_integer(janet_wrap_integer(-5)) == -5);
    assert(janet_unwrap_integer(janet_wrap_integer(INT32_MAX)) == INT32_MAX);
}

/* ------------------------------------------------------ booleans and truth */

/* `janet_wrap_boolean` normalizes: any non-zero argument makes the same value
 * as `janet_wrap_true`, and `janet_unwrap_boolean` answers 0 or 1 rather than
 * whatever went in. */
static void test_booleans_normalize(void) {
    assert(same_value(janet_wrap_boolean(1), janet_wrap_true()));
    assert(same_value(janet_wrap_boolean(2), janet_wrap_true()));
    assert(same_value(janet_wrap_boolean(-1), janet_wrap_true()));
    assert(same_value(janet_wrap_boolean(0), janet_wrap_false()));
    assert(janet_unwrap_boolean(janet_wrap_true()) == 1);
    assert(janet_unwrap_boolean(janet_wrap_false()) == 0);
    assert(janet_unwrap_boolean(janet_wrap_boolean(37)) == 1);
}

/* Exactly two values are false, and everything else is true -- including zero,
 * the empty string and an empty array, which is the difference between Janet's
 * truthiness and C's. */
static void test_truthiness(void) {
    assert(!janet_truthy(janet_wrap_nil()));
    assert(!janet_truthy(janet_wrap_false()));
    assert(!janet_truthy(janet_wrap_boolean(0)));
    assert(janet_truthy(janet_wrap_true()));
    assert(janet_truthy(janet_wrap_boolean(1)));
    assert(janet_truthy(janet_wrap_number(0.0)));
    assert(janet_truthy(janet_wrap_number(0.0 / 0.0)));
    assert(janet_truthy(janet_wrap_string(janet_cstring(""))));
    assert(janet_truthy(janet_wrap_array(janet_array(0))));
    assert(janet_truthy(janet_wrap_pointer(NULL)));
}

/* ------------------------------------------------- checktype and checktypes */

/* One value of each type, in tag order, so the matrix below can be written as
 * a loop rather than as a hundred and sixty-nine assertions. */
static void build_one_of_each(Janet *out) {
    out[JANET_NUMBER] = janet_wrap_number(2.5);
    out[JANET_NIL] = janet_wrap_nil();
    out[JANET_BOOLEAN] = janet_wrap_true();
    out[JANET_FIBER] = janet_wrap_fiber((JanetFiber *) &block_a);
    out[JANET_STRING] = janet_wrap_string(janet_cstring("s"));
    out[JANET_SYMBOL] = janet_wrap_symbol(janet_csymbol("s"));
    out[JANET_KEYWORD] = janet_wrap_keyword(janet_ckeyword("s"));
    out[JANET_ARRAY] = janet_wrap_array(janet_array(0));
    out[JANET_TUPLE] = janet_wrap_tuple(janet_tuple_n(NULL, 0));
    out[JANET_TABLE] = janet_wrap_table(janet_table(0));
    out[JANET_STRUCT] = janet_wrap_struct(janet_struct_end(janet_struct_begin(0)));
    out[JANET_BUFFER] = janet_wrap_buffer(janet_buffer(0));
    out[JANET_FUNCTION] = janet_wrap_function((JanetFunction *) &block_a);
    out[JANET_CFUNCTION] = janet_wrap_cfunction(a_cfunction);
    out[JANET_ABSTRACT] = janet_wrap_abstract(&block_b);
    out[JANET_POINTER] = janet_wrap_pointer(&block_b);
}

/* `janet_checktype` agrees with `janet_type` for every value against every
 * type, and it is the full matrix rather than the diagonal: under a NaN-boxed
 * layout the number case is tested differently from the rest, so a wrong
 * answer is as likely to be a false positive as a false negative. */
static void test_checktype_matrix(void) {
    Janet values[JANET_COUNT_TYPES];
    int i, j;
    build_one_of_each(values);
    for (i = 0; i < JANET_COUNT_TYPES; i++) {
        for (j = 0; j < JANET_COUNT_TYPES; j++) {
            int expected = (i == j);
            assert(!janet_checktype(values[i], (JanetType) j) == !expected);
        }
        assert(janet_type(values[i]) == (JanetType) i);
    }
}

/* `janet_checktypes` is the type as a bit in a mask, and it returns the masked
 * bit rather than a normalized boolean -- which is why every caller in the
 * tree tests it against zero. */
static void test_checktypes(void) {
    Janet values[JANET_COUNT_TYPES];
    int i;
    build_one_of_each(values);
    for (i = 0; i < JANET_COUNT_TYPES; i++) {
        int32_t bit = (int32_t) 1 << i;
        assert(janet_checktypes(values[i], bit) == bit);
        assert(janet_checktypes(values[i], ~bit) == 0);
        assert(janet_checktypes(values[i], -1) == bit);
        assert(janet_checktypes(values[i], 0) == 0);
    }
    assert(janet_checktypes(values[JANET_STRING], JANET_TFLAG_BYTES) != 0);
    assert(janet_checktypes(values[JANET_SYMBOL], JANET_TFLAG_BYTES) != 0);
    assert(janet_checktypes(values[JANET_KEYWORD], JANET_TFLAG_BYTES) != 0);
    assert(janet_checktypes(values[JANET_BUFFER], JANET_TFLAG_BYTES) != 0);
    assert(janet_checktypes(values[JANET_ARRAY], JANET_TFLAG_BYTES) == 0);
}

/* ------------------------------------------ the macro and the function agree */

/* `wrap.c`'s reason to exist. Every entry point here is a macro in `janet.h`
 * under at least one layout and a function in the library under all of them,
 * and a language binding that cannot expand macros calls the function. The
 * parenthesised spelling is what suppresses the macro, and it is the spelling
 * `wrap.c` uses to define these in the first place.
 *
 * Under the tagged layout most of the wrappers have no macro at all, so half
 * of the assertions below compare a function with itself. They are kept
 * because the set that has a macro differs per layout and enumerating that
 * difference here would be a fourth copy of the `#ifdef` chain. */
/* Every predicate `janet.h` provides in both spellings, checked against each
 * other for one value. Factored out because the set of values that matters is
 * larger than one per type -- see the call sites below. */
static void agree_on(Janet v) {
    int j;
    assert((janet_type)(v) == janet_type(v));
    assert(!(janet_truthy)(v) == !janet_truthy(v));
    for (j = 0; j < JANET_COUNT_TYPES; j++) {
        assert(!(janet_checktype)(v, (JanetType) j) == !janet_checktype(v, (JanetType) j));
        assert((janet_checktypes)(v, (int32_t) 1 << j) == janet_checktypes(v, (int32_t) 1 << j));
    }
    assert((janet_checktypes)(v, -1) == janet_checktypes(v, -1));
    assert((janet_checktypes)(v, 0) == janet_checktypes(v, 0));
}

static void test_macro_and_function_agree(void) {
    Janet values[JANET_COUNT_TYPES];
    void *p = &block_a;
    int i;
    build_one_of_each(values);

    assert(same_value((janet_wrap_nil)(), janet_wrap_nil()));
    assert(same_value((janet_wrap_true)(), janet_wrap_true()));
    assert(same_value((janet_wrap_false)(), janet_wrap_false()));
    assert(same_value((janet_wrap_boolean)(3), janet_wrap_boolean(3)));
    assert(same_value((janet_wrap_number)(2.5), janet_wrap_number(2.5)));
    assert(same_value((janet_wrap_string)((JanetString) p), janet_wrap_string((JanetString) p)));
    assert(same_value((janet_wrap_symbol)((JanetSymbol) p), janet_wrap_symbol((JanetSymbol) p)));
    assert(same_value((janet_wrap_keyword)((JanetKeyword) p), janet_wrap_keyword((JanetKeyword) p)));
    assert(same_value((janet_wrap_array)((JanetArray *) p), janet_wrap_array((JanetArray *) p)));
    assert(same_value((janet_wrap_tuple)((JanetTuple) p), janet_wrap_tuple((JanetTuple) p)));
    assert(same_value((janet_wrap_struct)((JanetStruct) p), janet_wrap_struct((JanetStruct) p)));
    assert(same_value((janet_wrap_fiber)((JanetFiber *) p), janet_wrap_fiber((JanetFiber *) p)));
    assert(same_value((janet_wrap_buffer)((JanetBuffer *) p), janet_wrap_buffer((JanetBuffer *) p)));
    assert(same_value((janet_wrap_function)((JanetFunction *) p), janet_wrap_function((JanetFunction *) p)));
    assert(same_value((janet_wrap_cfunction)(a_cfunction), janet_wrap_cfunction(a_cfunction)));
    assert(same_value((janet_wrap_table)((JanetTable *) p), janet_wrap_table((JanetTable *) p)));
    assert(same_value((janet_wrap_abstract)(p), janet_wrap_abstract(p)));
    assert(same_value((janet_wrap_pointer)(p), janet_wrap_pointer(p)));

    for (i = 0; i < JANET_COUNT_TYPES; i++) {
        agree_on(values[i]);
    }

    /* One value per type is not enough, and a mutation sweep is what said so.
     * `build_one_of_each` samples `2.5` for JANET_NUMBER and `true` for
     * JANET_BOOLEAN, and both of those take the *ordinary* arm of every
     * predicate. The interesting arms belong to the values below: a NaN, whose
     * type nibble under a NaN-boxed layout reads as JANET_NUMBER and so is
     * recognized by the second half of `janet_nanbox_isnumber` rather than the
     * first; and `false`, which is the only value whose truthiness depends on
     * the payload rather than on the tag. Without these, two of the port's arms
     * were reachable through `janet.h`'s macros and through nothing else. */
    {
        Janet awkward[9];
        size_t k;
        awkward[0] = janet_wrap_number(0.0 / 0.0);
        awkward[1] = janet_wrap_number(1.0 / 0.0);
        awkward[2] = janet_wrap_number(-1.0 / 0.0);
        awkward[3] = janet_wrap_number(0.0);
        awkward[4] = janet_wrap_number(-0.0);
        awkward[5] = janet_wrap_false();
        awkward[6] = janet_wrap_boolean(0);
        awkward[7] = janet_wrap_boolean(3);
        awkward[8] = janet_wrap_pointer(NULL);
        for (k = 0; k < 9; k++) {
            agree_on(awkward[k]);
        }
    }

    assert((janet_unwrap_boolean)(values[JANET_BOOLEAN]) == janet_unwrap_boolean(values[JANET_BOOLEAN]));
    assert((janet_unwrap_number)(values[JANET_NUMBER]) == janet_unwrap_number(values[JANET_NUMBER]));
    assert((janet_unwrap_integer)(janet_wrap_number(-9.5)) == janet_unwrap_integer(janet_wrap_number(-9.5)));
    assert((janet_unwrap_string)(values[JANET_STRING]) == janet_unwrap_string(values[JANET_STRING]));
    assert((janet_unwrap_symbol)(values[JANET_SYMBOL]) == janet_unwrap_symbol(values[JANET_SYMBOL]));
    assert((janet_unwrap_keyword)(values[JANET_KEYWORD]) == janet_unwrap_keyword(values[JANET_KEYWORD]));
    assert((janet_unwrap_array)(values[JANET_ARRAY]) == janet_unwrap_array(values[JANET_ARRAY]));
    assert((janet_unwrap_tuple)(values[JANET_TUPLE]) == janet_unwrap_tuple(values[JANET_TUPLE]));
    assert((janet_unwrap_struct)(values[JANET_STRUCT]) == janet_unwrap_struct(values[JANET_STRUCT]));
    assert((janet_unwrap_fiber)(values[JANET_FIBER]) == janet_unwrap_fiber(values[JANET_FIBER]));
    assert((janet_unwrap_buffer)(values[JANET_BUFFER]) == janet_unwrap_buffer(values[JANET_BUFFER]));
    assert((janet_unwrap_function)(values[JANET_FUNCTION]) == janet_unwrap_function(values[JANET_FUNCTION]));
    assert((janet_unwrap_cfunction)(values[JANET_CFUNCTION]) == janet_unwrap_cfunction(values[JANET_CFUNCTION]));
    assert((janet_unwrap_table)(values[JANET_TABLE]) == janet_unwrap_table(values[JANET_TABLE]));
    assert((janet_unwrap_abstract)(values[JANET_ABSTRACT]) == janet_unwrap_abstract(values[JANET_ABSTRACT]));
    assert((janet_unwrap_pointer)(values[JANET_POINTER]) == janet_unwrap_pointer(values[JANET_POINTER]));
}

/* ------------------------------------------------------ the exact bit layout */

/* The assertions that say this is *the* representation rather than a working
 * one. Each is computed from `janet.h`'s own constants and none of them goes
 * through an implementation of the thing under test. */
#ifdef JANET_NANBOX_64

static void test_exact_layout(void) {
    void *p = &block_a;
    uint64_t nil_tag = ((uint64_t)((uint64_t) JANET_NIL | 0x1FFF0u)) << 47;
    uint64_t bool_tag = ((uint64_t)((uint64_t) JANET_BOOLEAN | 0x1FFF0u)) << 47;
    uint64_t array_tag = ((uint64_t)((uint64_t) JANET_ARRAY | 0x1FFF0u)) << 47;
    union {
        uint64_t u;
        double d;
    } as;

    /* The three immediate values are a tag with a one-bit payload. */
    assert(janet_u64(janet_wrap_nil()) == (nil_tag | 1));
    assert(janet_u64(janet_wrap_true()) == (bool_tag | 1));
    assert(janet_u64(janet_wrap_false()) == bool_tag);

    /* A double is stored unchanged. */
    as.d = 1.5;
    assert(janet_u64(janet_wrap_number(1.5)) == as.u);
    assert(janet_u64(janet_nanbox_from_double(1.5)) == as.u);
    assert(janet_u64(janet_nanbox_from_bits(as.u)) == as.u);

    /* A pointer is shifted right by the alignment shift and then tagged, and
     * the payload bits are the only ones it may occupy. */
    {
        uint64_t word = janet_u64(janet_wrap_array((JanetArray *) p));
        assert((word & JANET_NANBOX_TAGBITS) == array_tag);
        assert((word & JANET_NANBOX_PAYLOADBITS) ==
               (((uint64_t)(uintptr_t) p) >> JANET_NANBOX_64_POINTER_SHIFT));
        assert(janet_nanbox_to_pointer(janet_nanbox_from_pointer(p, array_tag)) == p);
        assert(janet_nanbox_to_pointer(janet_nanbox_from_cpointer((const void *) p, array_tag)) == p);
        assert(janet_u64(janet_nanbox_from_pointer(p, array_tag)) == word);
    }

    /* The canonical NaN is what `janet_wrap_number_safe` stores, and it is not
     * mistaken for a tagged value. */
    as.d = janet_unwrap_number(janet_wrap_number_safe(0.0 / 0.0));
    assert(janet_type(janet_wrap_number_safe(0.0 / 0.0)) == JANET_NUMBER);
    assert((as.u & JANET_NANBOX_PAYLOADBITS) == 0);
}

#elif defined(JANET_NANBOX_32)

static void test_exact_layout(void) {
    void *p = &block_a;
    union {
        uint64_t u;
        double d;
    } as;

    /* Every non-number tag is stored raw in the high word, below the offset
     * that biases a double's exponent out of the way. */
    assert(janet_wrap_nil().tagged.type == (uint32_t) JANET_NIL);
    assert(janet_wrap_nil().tagged.payload.integer == 0);
    assert(janet_wrap_true().tagged.type == (uint32_t) JANET_BOOLEAN);
    assert(janet_wrap_true().tagged.payload.integer == 1);
    assert(janet_wrap_false().tagged.payload.integer == 0);
    assert(janet_wrap_array((JanetArray *) p).tagged.type == (uint32_t) JANET_ARRAY);
    assert(janet_wrap_array((JanetArray *) p).tagged.payload.pointer == p);
    assert((uint32_t) JANET_POINTER < (uint32_t) JANET_DOUBLE_OFFSET);

    /* A double is biased by JANET_DOUBLE_OFFSET in its high word, which is
     * what keeps every number above every tag. */
    as.d = 1.5;
    assert(janet_u64(janet_wrap_number(1.5)) == as.u + ((uint64_t) JANET_DOUBLE_OFFSET << 32));
    assert(janet_unwrap_number(janet_wrap_number(1.5)) == 1.5);

    assert(janet_nanbox32_from_tagi((uint32_t) JANET_BOOLEAN, 1).tagged.payload.integer == 1);
    assert(janet_nanbox32_from_tagp((uint32_t) JANET_ARRAY, p).tagged.payload.pointer == p);
    assert(janet_nanbox32_from_tagp((uint32_t) JANET_ARRAY, p).tagged.type == (uint32_t) JANET_ARRAY);

    as.d = janet_unwrap_number(janet_wrap_number_safe(0.0 / 0.0));
    assert((as.u & 0x000FFFFFFFFFFFFFull) == 0x0008000000000000ull);
}

#else

static void test_exact_layout(void) {
    void *p = &block_a;
    union {
        uint64_t u;
        double d;
    } as;

    /* The tag is a field of its own, and the payload union is zeroed before
     * the narrower member is written -- which is what the `as.u64 = 0` in
     * `JANET_WRAP_DEFINE` is for and the only way to see it is through a
     * pointer narrower than the union. */
    assert(janet_wrap_nil().type == JANET_NIL);
    assert(janet_u64(janet_wrap_nil()) == 0);
    assert(janet_wrap_true().type == JANET_BOOLEAN);
    assert(janet_u64(janet_wrap_true()) == 1);
    assert(janet_u64(janet_wrap_false()) == 0);
    assert(janet_wrap_array((JanetArray *) p).type == JANET_ARRAY);
    assert(janet_u64(janet_wrap_array((JanetArray *) p)) == (uint64_t)(uintptr_t) p);
    assert(janet_u64(janet_wrap_pointer(NULL)) == 0);

    as.d = 1.5;
    assert(janet_u64(janet_wrap_number(1.5)) == as.u);

    /* The one layout that does not canonicalize a NaN, because it has no tag
     * space in the double to protect. `FOUND.md` has the asymmetry. */
    {
        union {
            uint64_t u;
            double d;
        } hostile;
        hostile.u = 0x7FF0000000000123ull;
        assert(janet_u64(janet_wrap_number_safe(hostile.d)) == hostile.u);
    }
}

#endif

/* ------------------------------------------------------ empty bucket arrays */

/* `janet_memalloc_empty` is the allocator every dictionary's bucket array
 * comes from. Three things are its contract: the block is `count` pairs long,
 * every pair is nil/nil, and the collection budget is charged for the bytes.
 * The charge is what only this test sees -- `janet_gcalloc` bills its own
 * blocks and this one is a plain `janet_malloc`. */
static void test_memalloc_empty(void) {
    int32_t counts[3];
    size_t i;
    counts[0] = 1;
    counts[1] = 8;
    counts[2] = 257;
    for (i = 0; i < 3; i++) {
        int32_t n = counts[i];
        size_t before = janet_vm.next_collection;
        JanetKV *kvs = (JanetKV *) janet_memalloc_empty(n);
        int32_t j;
        /* Reaching this line is the null check: the failure path exits. */
        assert(kvs != NULL);
        assert(janet_vm.next_collection - before == (size_t) n * sizeof(JanetKV));
        for (j = 0; j < n; j++) {
            assert(janet_checktype(kvs[j].key, JANET_NIL));
            assert(janet_checktype(kvs[j].value, JANET_NIL));
        }
        janet_free(kvs);
    }
}

/* A zero-length request charges nothing and writes nothing. The pointer it
 * returns is whatever the platform's `malloc(0)` gives, which is a block on
 * macOS and on musl; if it were NULL the process would have exited inside the
 * call, so the assertion below is about the charge and not about the pointer. */
static void test_memalloc_empty_of_zero(void) {
    size_t before = janet_vm.next_collection;
    void *mem = janet_memalloc_empty(0);
    assert(janet_vm.next_collection == before);
    janet_free(mem);
}

/* `janet_memempty` clears a block the caller already owns. The block is
 * dirtied first with values of a type that is not nil under every layout, so a
 * fill that did nothing at all would be caught rather than passing on whatever
 * the allocator happened to leave. */
static void test_memempty_clears_a_dirty_block(void) {
    enum { n = 16 };
    JanetKV *kvs = (JanetKV *) janet_memalloc_empty(n);
    int32_t i;
    for (i = 0; i < n; i++) {
        kvs[i].key = janet_wrap_integer(i + 1);
        kvs[i].value = janet_wrap_boolean(1);
    }
    for (i = 0; i < n; i++) {
        assert(!janet_checktype(kvs[i].key, JANET_NIL));
        assert(!janet_checktype(kvs[i].value, JANET_NIL));
    }
    janet_memempty(kvs, n);
    for (i = 0; i < n; i++) {
        assert(janet_checktype(kvs[i].key, JANET_NIL));
        assert(janet_checktype(kvs[i].value, JANET_NIL));
        assert(same_value(kvs[i].key, janet_wrap_nil()));
        assert(same_value(kvs[i].value, janet_wrap_nil()));
    }
    /* A zero count leaves the block alone rather than clearing one pair. */
    kvs[0].key = janet_wrap_boolean(1);
    janet_memempty(kvs, 0);
    assert(janet_checktype(kvs[0].key, JANET_BOOLEAN));
    janet_free(kvs);
}

/* -------------------------------------------------------------- collection */

/* Values built by these wrappers are what the collector traverses, so the last
 * check is that a heap object reached only through a wrapped value survives a
 * collection while rooted and is freed once it is not. Repeated, because every
 * Phase 8 contract ends with a cycle. */
static void test_repeated_cycles(void) {
    int i;
    for (i = 0; i < 64; i++) {
        Janet array = janet_wrap_array(janet_array(4));
        Janet table = janet_wrap_table(janet_table(4));
        Janet buffer = janet_wrap_buffer(janet_buffer(4));
        Janet string = janet_wrap_string(janet_cstring("cycle"));
        janet_array_push(janet_unwrap_array(array), string);
        janet_table_put(janet_unwrap_table(table), janet_wrap_integer(i), buffer);
        janet_gcroot(array);
        janet_gcroot(table);
        janet_collect();
        assert(janet_type(array) == JANET_ARRAY);
        assert(janet_unwrap_array(array)->count == 1);
        assert(same_value(janet_unwrap_array(array)->data[0], string));
        assert(same_value(janet_table_get(janet_unwrap_table(table), janet_wrap_integer(i)), buffer));
        janet_gcunroot(table);
        janet_gcunroot(array);
        janet_collect();
    }
}

void value_wrap_contract(void) {
    janet_init();
    test_env = janet_core_env(NULL);
    janet_gcroot(janet_wrap_table(test_env));

    test_each_wrapper_stamps_its_type();
    test_pointer_round_trips();
    test_null_payloads_round_trip();
    test_the_tag_is_part_of_the_value();

    test_numbers_round_trip();
    test_nan_is_a_number();
    test_wrap_number_safe();
    test_integer_conversions();

    test_booleans_normalize();
    test_truthiness();

    test_checktype_matrix();
    test_checktypes();

    test_macro_and_function_agree();
    test_exact_layout();

    test_memalloc_empty();
    test_memalloc_empty_of_zero();
    test_memempty_clears_a_dirty_block();

    test_repeated_cycles();

    janet_deinit();
    printf("value wrap contract ok\n");
}
