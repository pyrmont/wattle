/* Behavioral contract for Janet's random number generator and math kernels,
 * run against whichever implementation the build selected (`-Dmath-core=c` or
 * the Zig default).
 *
 * The generator's state is marshalled, so every vector below is an exact
 * sequence rather than a statistical property. */

#include <assert.h>
#include <math.h>
#include <stdint.h>
#include <string.h>
#include <janet.h>

static int same_double(double a, double b) {
    return memcmp(&a, &b, sizeof(double)) == 0;
}

static void expect_sequence(JanetRNG *rng, const uint32_t *expected, int count) {
    for (int i = 0; i < count; i++) assert(janet_rng_u32(rng) == expected[i]);
}

static void test_seed(void) {
    JanetRNG rng;

    /* Seeding runs 16 warmup draws, so the post-seed state is not the literal
     * seed constants. */
    janet_rng_seed(&rng, 0);
    assert(rng.a == 0x0c1a42aau);
    assert(rng.b == 0xeae5edceu);
    assert(rng.c == 0x4f5fd051u);
    assert(rng.d == 0xbf7df883u);
    assert(rng.counter == 0x00587c50u);

    static const uint32_t from_zero[] = {
        0x7cb7e804u, 0x5cc33daau, 0xe9aa2ab6u, 0x6ce3abcbu,
        0x0f68de54u, 0x3ce19a65u, 0x8faa2224u, 0xe4c19f5bu
    };
    expect_sequence(&rng, from_zero, 8);

    janet_rng_seed(&rng, 0xDEADBEEFu);
    assert(rng.a == 0xbbf082e8u);
    assert(rng.b == 0xa4ecbbdcu);
    assert(rng.c == 0xceeb0ecfu);
    assert(rng.d == 0xd9874a93u);
    static const uint32_t from_deadbeef[] = {
        0x35310846u, 0x7e749c7fu, 0x09e1b927u, 0x2255b762u
    };
    expect_sequence(&rng, from_deadbeef, 4);

    /* Reseeding is a full reset: the counter does not carry over. */
    janet_rng_seed(&rng, 0);
    assert(rng.counter == 0x00587c50u);
    expect_sequence(&rng, from_zero, 8);
}

static void test_longseed(void) {
    JanetRNG rng;
    JanetRNG empty;

    janet_rng_longseed(&rng, (const uint8_t *) "janet", 5);
    assert(rng.a == 0x3c6c72fbu);
    assert(rng.b == 0xfadea204u);
    assert(rng.c == 0xd01b463fu);
    assert(rng.d == 0xbaf55482u);
    assert(rng.counter == 0x00587c50u);
    static const uint32_t from_janet[] = {
        0x46d163c2u, 0x0dc3a987u, 0x9843ec91u, 0xc05d8081u
    };
    expect_sequence(&rng, from_janet, 4);

    /* Input longer than 16 bytes folds by XOR into the 16-byte state. */
    janet_rng_longseed(&rng, (const uint8_t *) "abcdefghijklmnopqrst", 20);
    assert(rng.a == 0x4cf87e6fu);
    assert(rng.b == 0x9fca16c7u);
    assert(rng.c == 0xe2ce039bu);
    assert(rng.d == 0x603634b8u);

    /* An empty seed leaves the state all zeros, so `a` is forced to 1. */
    janet_rng_longseed(&empty, (const uint8_t *) "", 0);
    assert(empty.a == 0x9c5f0f15u);
    assert(empty.b == 0x094111e2u);
    assert(empty.c == 0xcd5101c1u);
    assert(empty.d == 0x0c55143au);

    /* Bytes that cancel under the fold reach the same forced state. */
    static const uint8_t cancels[20] = {
        1, 2, 3, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4
    };
    janet_rng_longseed(&rng, cancels, 20);
    assert(rng.a == empty.a && rng.b == empty.b);
    assert(rng.c == empty.c && rng.d == empty.d);

    /* A negative length reads nothing. */
    janet_rng_longseed(&rng, (const uint8_t *) "janet", -1);
    assert(rng.a == empty.a && rng.b == empty.b);
    assert(rng.c == empty.c && rng.d == empty.d);
}

static void test_double(void) {
    JanetRNG rng;

    janet_rng_seed(&rng, 7);
    assert(same_double(janet_rng_double(&rng), 0.012130103775150669));
    assert(same_double(janet_rng_double(&rng), 0.95069094881030836));
    assert(same_double(janet_rng_double(&rng), 0.39906010130019998));

    /* Every draw stays in [0, 1) and consumes exactly two 32-bit words. */
    janet_rng_seed(&rng, 11);
    for (int i = 0; i < 2000; i++) {
        double x = janet_rng_double(&rng);
        assert(x >= 0.0 && x < 1.0);
    }
    {
        JanetRNG paired;
        JanetRNG stepped;
        janet_rng_seed(&paired, 11);
        janet_rng_seed(&stepped, 11);
        (void) janet_rng_double(&paired);
        (void) janet_rng_u32(&stepped);
        (void) janet_rng_u32(&stepped);
        assert(paired.a == stepped.a && paired.b == stepped.b);
        assert(paired.c == stepped.c && paired.d == stepped.d);
        assert(paired.counter == stepped.counter);
    }
}

static void test_default_rng(void) {
    JanetRNG *shared = janet_default_rng();
    assert(shared != NULL);

    /* math/seedrandom and math/random run on this generator. */
    janet_rng_seed(shared, 0);
    assert(janet_rng_u32(shared) == 0x7cb7e804u);
    assert(janet_default_rng() == shared);
}

/* Call math/gcd and math/lcm directly rather than through compiled source.
 * A NaN argument written as a literal would be folded into a constant slot,
 * and janetc_loadconst casts such a constant to int32_t without excluding NaN
 * first -- see FOUND.md. Calling the C function avoids the compiler entirely,
 * so these vectors do not depend on that unresolved defect. */
static double call2(JanetCFunction fn, double a, double b) {
    Janet argv[2];
    argv[0] = janet_wrap_number(a);
    argv[1] = janet_wrap_number(b);
    return janet_unwrap_number(fn(2, argv));
}

static void test_gcd_lcm(void) {
    Janet gcd_binding = janet_resolve_core("math/gcd");
    Janet lcm_binding = janet_resolve_core("math/lcm");
    JanetCFunction gcd;
    JanetCFunction lcm;

    assert(janet_checktype(gcd_binding, JANET_CFUNCTION));
    assert(janet_checktype(lcm_binding, JANET_CFUNCTION));
    gcd = janet_unwrap_cfunction(gcd_binding);
    lcm = janet_unwrap_cfunction(lcm_binding);

    assert(same_double(call2(gcd, 12, 18), 6.0));
    assert(same_double(call2(gcd, 0, 5), 5.0));
    assert(same_double(call2(gcd, 5, 0), 5.0));
    assert(same_double(call2(gcd, 0, 0), 0.0));
    assert(same_double(call2(gcd, 7, 13), 1.0));
    assert(same_double(call2(gcd, 2.5, 1.25), 1.25));
    /* fmod keeps the sign of the dividend, so negative inputs propagate. */
    assert(same_double(call2(gcd, -12, 18), 6.0));
    assert(same_double(call2(gcd, 12, -18), -6.0));
    assert(same_double(call2(gcd, -12, -18), -6.0));

    assert(same_double(call2(lcm, 12, 18), 36.0));
    assert(same_double(call2(lcm, 0, 5), 0.0));
    assert(same_double(call2(lcm, -12, 18), -36.0));
    assert(same_double(call2(lcm, 12, -18), 36.0));
    assert(same_double(call2(lcm, 7, 13), 91.0));
    assert(same_double(call2(lcm, 2.5, 1.25), 2.5));

    /* Any infinite operand makes the gcd positive infinity, whatever its
     * sign, and makes the lcm NaN. */
    assert(same_double(call2(gcd, INFINITY, 4), INFINITY));
    assert(same_double(call2(gcd, 4, INFINITY), INFINITY));
    assert(same_double(call2(gcd, -INFINITY, 4), INFINITY));
    assert(same_double(call2(gcd, 4, -INFINITY), INFINITY));
    assert(isnan(call2(lcm, INFINITY, 4)));
    assert(isnan(call2(lcm, 4, INFINITY)));

    /* NaN in, NaN out. */
    assert(isnan(call2(gcd, NAN, 4)));
    assert(isnan(call2(gcd, 4, NAN)));
    assert(isnan(call2(gcd, NAN, NAN)));
    assert(isnan(call2(lcm, NAN, 4)));
    assert(isnan(call2(lcm, 0, 0)));
}

static void test_rng_int(void) {
    JanetTable *env = janet_core_env(NULL);
    Janet result;

    /* A zero bound short-circuits before drawing. */
    assert(janet_dostring(env,
                          "(let [r (math/rng 5)] [(math/rng-int r 0) (math/rng-int r 0)])",
                          "test", &result) == 0);
    assert(janet_unwrap_number(janet_unwrap_tuple(result)[0]) == 0.0);
    assert(janet_unwrap_number(janet_unwrap_tuple(result)[1]) == 0.0);

    /* Without a bound the draw is a 31-bit word. */
    assert(janet_dostring(env,
                          "(let [r (math/rng 0)] (math/rng-int r))",
                          "test", &result) == 0);
    assert(janet_unwrap_number(result) == (double)(0x7cb7e804u >> 1));

    /* A bound of 1 always yields 0, and consumes exactly one word per call
     * because every draw falls inside the acceptance window. */
    assert(janet_dostring(env,
                          "(let [r (math/rng 0)] "
                          "  [(math/rng-int r 1) (math/rng-int r 1) (math/rng-int r)])",
                          "test", &result) == 0);
    assert(janet_unwrap_number(janet_unwrap_tuple(result)[0]) == 0.0);
    assert(janet_unwrap_number(janet_unwrap_tuple(result)[1]) == 0.0);
    assert(janet_unwrap_number(janet_unwrap_tuple(result)[2]) == (double)(0xe9aa2ab6u >> 1));

    /* Bounds are respected, and a fixed seed gives a fixed sequence. */
    assert(janet_dostring(env,
                          "(let [r (math/rng 42)] "
                          "  (all |(and (>= $ 0) (< $ 10)) (seq [_ :range [0 500]] (math/rng-int r 10))))",
                          "test", &result) == 0);
    assert(janet_truthy(result));

    assert(janet_dostring(env,
                          "(deep= (seq [_ :range [0 20]] (math/rng-int (math/rng 3) 1000)) "
                          "       (seq [_ :range [0 20]] (math/rng-int (math/rng 3) 1000)))",
                          "test", &result) == 0);
    assert(janet_truthy(result));
}

static void test_rng_buffer(void) {
    JanetTable *env = janet_core_env(NULL);
    Janet result;

    /* A length that is not a multiple of 4 takes the low bytes of a final
     * partial word. */
    assert(janet_dostring(env,
                          "(math/rng-buffer (math/rng 3) 11)", "test", &result) == 0);
    {
        static const uint8_t expected[11] = {
            0x20, 0xf8, 0x5a, 0x58, 0xcc, 0x1f, 0x5f, 0x10, 0x76, 0x3b, 0x1c
        };
        JanetBuffer *buffer = janet_unwrap_buffer(result);
        assert(buffer->count == 11);
        assert(!memcmp(buffer->data, expected, 11));
    }

    /* Zero bytes draws nothing and leaves the generator untouched. */
    assert(janet_dostring(env,
                          "(let [r (math/rng 3)] "
                          "  (math/rng-buffer r 0) "
                          "  (deep= (math/rng-buffer r 11) (math/rng-buffer (math/rng 3) 11)))",
                          "test", &result) == 0);
    assert(janet_truthy(result));

    /* An explicit buffer is appended to and returned. */
    assert(janet_dostring(env,
                          "(let [b (buffer \"xy\")] "
                          "  [(= b (math/rng-buffer (math/rng 3) 4 b)) (length b) (string/slice b 0 2)])",
                          "test", &result) == 0);
    assert(janet_truthy(janet_unwrap_tuple(result)[0]));
    assert(janet_unwrap_number(janet_unwrap_tuple(result)[1]) == 6.0);
    assert(!janet_string_compare(janet_unwrap_string(janet_unwrap_tuple(result)[2]),
                                 janet_cstring("xy")));

    /* Every length from 0 to 16 produces exactly that many bytes. */
    assert(janet_dostring(env,
                          "(all |(= $ (length (math/rng-buffer (math/rng 1) $))) (range 17))",
                          "test", &result) == 0);
    assert(janet_truthy(result));
}

static void test_marshal_roundtrip(void) {
    JanetTable *env = janet_core_env(NULL);
    Janet result;

    /* The generator's state survives marshalling exactly, which is why the
     * vectors above must be bit-exact. */
    assert(janet_dostring(env,
                          "(let [r (math/rng 12345)] "
                          "  (math/rng-int r) "
                          "  (let [c (unmarshal (marshal r))] "
                          "    (deep= (seq [_ :range [0 8]] (math/rng-int r)) "
                          "           (seq [_ :range [0 8]] (math/rng-int c)))))",
                          "test", &result) == 0);
    assert(janet_truthy(result));
}

int main(void) {
    janet_init();

    test_seed();
    test_longseed();
    test_double();
    test_default_rng();
    test_gcd_lcm();
    test_rng_int();
    test_rng_buffer();
    test_marshal_roundtrip();

    janet_deinit();
    return 0;
}
