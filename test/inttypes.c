/* Behavioral contract for the numeric kernels behind int/s64 and int/u64, run
 * against whichever implementation the build selected (`-Dint-types-core=c` or
 * the Zig default). */

#include <assert.h>
#include <math.h>
#include <stdint.h>
#include <string.h>
#include <janet.h>

static JanetFunction *compare_fn;

/* Compare through a compiled function rather than a literal expression, so a
 * double argument never becomes a compile-time constant. janetc_loadconst
 * casts a NaN constant to int32_t without excluding NaN first -- see
 * FOUND.md -- and these vectors must not depend on that unresolved defect. */
static double compare_values(Janet a, Janet b) {
    Janet argv[2];
    Janet out;
    argv[0] = a;
    argv[1] = b;
    assert(janet_pcall(compare_fn, 2, argv, &out, NULL) == JANET_SIGNAL_OK);
    assert(janet_checktype(out, JANET_NUMBER));
    return janet_unwrap_number(out);
}

static double compare_s64_double(int64_t x, double y) {
    return compare_values(janet_wrap_s64(x), janet_wrap_number(y));
}

static double compare_u64_double(uint64_t x, double y) {
    return compare_values(janet_wrap_u64(x), janet_wrap_number(y));
}

static void test_hash(void) {
    int64_t a = 0;
    int64_t b = 1;
    int64_t c = INT64_MIN;
    uint64_t u = 1;

    /* The hash folds the two halves together, so it is stable and independent
     * of which of the two types holds the bits. */
    assert(janet_s64_type.hash(&a, sizeof(a)) == 0);
    assert(janet_s64_type.hash(&b, sizeof(b)) == janet_u64_type.hash(&u, sizeof(u)));
    assert(janet_s64_type.hash(&c, sizeof(c)) == INT32_MIN);
    assert(janet_s64_type.hash(&b, sizeof(b)) != janet_s64_type.hash(&a, sizeof(a)));

    /* Values differing only in the high word still separate. */
    {
        int64_t high = ((int64_t) 1) << 32;
        assert(janet_s64_type.hash(&high, sizeof(high)) == 1);
    }
}

static void test_abstract_compare(void) {
    int64_t s_small = -5;
    int64_t s_big = 5;
    int64_t s_min = INT64_MIN;
    int64_t s_max = INT64_MAX;
    uint64_t u_small = 5;
    uint64_t u_big = UINT64_MAX;

    assert(janet_s64_type.compare(&s_small, &s_big) == -1);
    assert(janet_s64_type.compare(&s_big, &s_small) == 1);
    assert(janet_s64_type.compare(&s_big, &s_big) == 0);
    assert(janet_s64_type.compare(&s_min, &s_max) == -1);
    assert(janet_s64_type.compare(&s_max, &s_min) == 1);

    /* The unsigned comparison must not borrow the signed ordering. */
    assert(janet_u64_type.compare(&u_small, &u_big) == -1);
    assert(janet_u64_type.compare(&u_big, &u_small) == 1);
    assert(janet_u64_type.compare(&u_big, &u_big) == 0);
    {
        uint64_t high_bit = ((uint64_t) 1) << 63;
        uint64_t one = 1;
        assert(janet_u64_type.compare(&high_bit, &one) == 1);
    }
}

static void test_compare_s64_double(void) {
    /* Inside the double's contiguous integer range the comparison is exact. */
    assert(compare_s64_double(0, 0.0) == 0);
    assert(compare_s64_double(5, 5.0) == 0);
    assert(compare_s64_double(5, 5.5) == -1);
    assert(compare_s64_double(6, 5.5) == 1);
    assert(compare_s64_double(-5, -5.0) == 0);
    assert(compare_s64_double(-6, -5.5) == -1);
    assert(compare_s64_double(-5, -5.5) == 1);

    /* NaN compares equal to everything, which is how the C original reports
     * "no ordering" through an int return. */
    assert(compare_s64_double(0, NAN) == 0);
    assert(compare_s64_double(INT64_MAX, NAN) == 0);

    /* Infinities sit outside every integer. */
    assert(compare_s64_double(INT64_MAX, INFINITY) == -1);
    assert(compare_s64_double(INT64_MIN, -INFINITY) == 1);

    /* Beyond 2^53 the integer can no longer be widened without rounding, so
     * the double is narrowed instead. */
    assert(compare_s64_double(INT64_MAX, 1e300) == -1);
    assert(compare_s64_double(INT64_MIN, -1e300) == 1);
    assert(compare_s64_double(INT64_MAX, 9.3e18) == -1);
    assert(compare_s64_double(INT64_MIN, -9.3e18) == 1);

    /* 2^53 itself is the edge of the exact range. */
    assert(compare_s64_double(9007199254740992LL, 9007199254740992.0) == 0);
    assert(compare_s64_double(9007199254740993LL, 9007199254740992.0) == 1);
    assert(compare_s64_double(-9007199254740993LL, -9007199254740992.0) == -1);
}

static void test_compare_u64_double(void) {
    assert(compare_u64_double(0, 0.0) == 0);
    assert(compare_u64_double(5, 5.0) == 0);
    assert(compare_u64_double(5, 5.5) == -1);
    assert(compare_u64_double(6, 5.5) == 1);

    /* Every unsigned value is above every negative double, including zero
     * against a small negative. */
    assert(compare_u64_double(0, -0.5) == 1);
    assert(compare_u64_double(0, -1e300) == 1);
    assert(compare_u64_double(UINT64_MAX, -1.0) == 1);

    assert(compare_u64_double(0, NAN) == 0);
    assert(compare_u64_double(UINT64_MAX, NAN) == 0);
    assert(compare_u64_double(UINT64_MAX, INFINITY) == -1);

    assert(compare_u64_double(UINT64_MAX, 1e300) == -1);
    assert(compare_u64_double(9007199254740992ULL, 9007199254740992.0) == 0);
    assert(compare_u64_double(9007199254740993ULL, 9007199254740992.0) == 1);
}

static void test_compare_across_types(void) {
    Janet s_neg = janet_wrap_s64(-1);
    Janet s_zero = janet_wrap_s64(0);
    Janet s_max = janet_wrap_s64(INT64_MAX);
    Janet u_zero = janet_wrap_u64(0);
    Janet u_small = janet_wrap_u64(1);
    Janet u_huge = janet_wrap_u64(((uint64_t) INT64_MAX) + 1);
    Janet u_max = janet_wrap_u64(UINT64_MAX);

    /* A negative signed value is below every unsigned value. */
    assert(compare_values(s_neg, u_zero) == -1);
    assert(compare_values(s_neg, u_max) == -1);
    assert(compare_values(u_zero, s_neg) == 1);
    assert(compare_values(u_max, s_neg) == 1);

    /* An unsigned value above INT64_MAX is above every signed value. */
    assert(compare_values(s_max, u_huge) == -1);
    assert(compare_values(u_huge, s_max) == 1);
    assert(compare_values(s_max, u_max) == -1);

    /* Inside the overlap the ordering is ordinary. */
    assert(compare_values(s_zero, u_zero) == 0);
    assert(compare_values(s_zero, u_small) == -1);
    assert(compare_values(u_small, s_zero) == 1);
    assert(compare_values(s_max, janet_wrap_u64((uint64_t) INT64_MAX)) == 0);
}

static void test_tostring(void) {
    JanetBuffer *buffer = janet_buffer(0);
    int64_t s;
    uint64_t u;

    s = 0;
    janet_s64_type.tostring(&s, buffer);
    assert(buffer->count == 1 && !memcmp(buffer->data, "0", 1));

    buffer->count = 0;
    s = INT64_MIN;
    janet_s64_type.tostring(&s, buffer);
    assert(buffer->count == 20);
    assert(!memcmp(buffer->data, "-9223372036854775808", 20));

    buffer->count = 0;
    s = INT64_MAX;
    janet_s64_type.tostring(&s, buffer);
    assert(buffer->count == 19);
    assert(!memcmp(buffer->data, "9223372036854775807", 19));

    /* The unsigned formatter must not print the high bit as a sign. */
    buffer->count = 0;
    u = UINT64_MAX;
    janet_u64_type.tostring(&u, buffer);
    assert(buffer->count == 20);
    assert(!memcmp(buffer->data, "18446744073709551615", 20));

    /* Formatting appends rather than replacing. */
    buffer->count = 0;
    janet_buffer_push_cstring(buffer, "n=");
    u = 42;
    janet_u64_type.tostring(&u, buffer);
    assert(buffer->count == 4 && !memcmp(buffer->data, "n=42", 4));
}

/* Floored division and modulo, exercised through the `div` and `mod` methods.
 *
 * INT64_MIN with a divisor of -1 is deliberately absent. The `/` and `%`
 * methods reject it with a Janet error, but `div` and `mod` do not guard it and
 * reach an undefined division in C -- see FOUND.md. Pinning either outcome
 * would assert behavior that is not yet decided. */
static void test_divf_mod(void) {
    JanetTable *env = janet_core_env(NULL);
    Janet result;

    struct {
        const char *source;
        const char *expected;
    } cases[] = {
        /* Floored division rounds toward negative infinity, unlike `/`. */
        {"(div (int/s64 7) (int/s64 2))", "3"},
        {"(div (int/s64 -7) (int/s64 2))", "-4"},
        {"(div (int/s64 7) (int/s64 -2))", "-4"},
        {"(div (int/s64 -7) (int/s64 -2))", "3"},
        {"(div (int/s64 8) (int/s64 2))", "4"},
        {"(div (int/s64 -8) (int/s64 2))", "-4"},
        {"(div (int/s64 0) (int/s64 -3))", "0"},
        /* rdiv swaps the operands. */
        {"(:rdiv (int/s64 2) (int/s64 -7))", "-4"},
        /* Floored modulo takes the sign of the divisor, unlike `%`. */
        {"(mod (int/s64 7) (int/s64 2))", "1"},
        {"(mod (int/s64 -7) (int/s64 2))", "1"},
        {"(mod (int/s64 7) (int/s64 -2))", "-1"},
        {"(mod (int/s64 -7) (int/s64 -2))", "-1"},
        {"(mod (int/s64 -8) (int/s64 2))", "0"},
        {"(% (int/s64 -7) (int/s64 2))", "-1"},
        /* A zero divisor returns the dividend rather than raising. */
        {"(mod (int/s64 7) (int/s64 0))", "7"},
        {"(mod (int/s64 -7) (int/s64 0))", "-7"},
        {"(:rmod (int/s64 2) (int/s64 -7))", "1"},
        /* The extremes still divide when the result is representable. */
        {"(div (int/s64 \"-9223372036854775808\") (int/s64 2))", "-4611686018427387904"},
        {"(mod (int/s64 \"-9223372036854775808\") (int/s64 3))", "1"},
    };

    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        assert(janet_dostring(env, cases[i].source, "test", &result) == 0);
        assert(janet_is_int(result) == JANET_INT_S64);
        {
            JanetBuffer *buffer = janet_buffer(0);
            janet_s64_type.tostring(janet_unwrap_abstract(result), buffer);
            assert(buffer->count == (int32_t) strlen(cases[i].expected));
            assert(!memcmp(buffer->data, cases[i].expected, buffer->count));
        }
    }

    /* Dividing by zero raises, while the modulo above does not. Run it under a
     * protected call so the expected failure stays off stderr. */
    assert(janet_dostring(env, "(fn [] (div (int/s64 1) (int/s64 0)))", "test", &result) == 0);
    {
        Janet out;
        assert(janet_pcall(janet_unwrap_function(result), 0, NULL, &out, NULL) == JANET_SIGNAL_ERROR);
    }
}

int main(void) {
    JanetTable *env;
    Janet fn;

    janet_init();
    env = janet_core_env(NULL);
    assert(janet_dostring(env, "(fn [a b] (compare a b))", "test", &fn) == 0);
    compare_fn = janet_unwrap_function(fn);
    janet_gcroot(fn);

    test_hash();
    test_abstract_compare();
    test_compare_s64_double();
    test_compare_u64_double();
    test_compare_across_types();
    test_tostring();
    test_divf_mod();

    janet_gcunroot(fn);
    janet_deinit();
    return 0;
}
