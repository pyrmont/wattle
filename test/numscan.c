/* Behavioral contract for Janet's number scanner, run against whichever
 * implementation the build selected (`-Dnumber-scan=c` or the Zig default). */

#include <assert.h>
#include <math.h>
#include <stdint.h>
#include <string.h>
#include <janet.h>
#include "util.h"

static int scan(const char *text, double *out) {
    return janet_scan_number((const uint8_t *) text, (int32_t) strlen(text), out);
}

static int scan_base(const char *text, int32_t base, double *out) {
    return janet_scan_number_base((const uint8_t *) text, (int32_t) strlen(text), base, out);
}

/* Numbers must match exactly, so compare representations rather than values.
 * This also distinguishes -0.0 from 0.0 and rejects unexpected NaNs. */
static int same_double(double a, double b) {
    return memcmp(&a, &b, sizeof(double)) == 0;
}

static int scans_to(const char *text, double expected) {
    double value = 12345.0;
    if (scan(text, &value)) return 0;
    return same_double(value, expected);
}

static int rejects(const char *text) {
    double value = 12345.0;
    return scan(text, &value) == 1;
}

static void test_integers(void) {
    assert(scans_to("0", 0.0));
    assert(scans_to("-0", -0.0));
    assert(scans_to("+0", 0.0));
    assert(scans_to("1", 1.0));
    assert(scans_to("-1", -1.0));
    assert(scans_to("+42", 42.0));
    assert(scans_to("000123", 123.0));
    /* Janet breaks ties away from zero rather than to even, so 2^53 + 1 rounds
     * up where a round-to-even strtod rounds down. */
    assert(scans_to("9007199254740993", 9007199254740994.0));
    assert(scans_to("9007199254740995", 9007199254740996.0));
    assert(scans_to("1_000_000", 1000000.0));
    assert(scans_to("1_", 1.0));
}

static void test_fractions(void) {
    assert(scans_to("1.5", 1.5));
    assert(scans_to("-1.5", -1.5));
    assert(scans_to(".5", 0.5));
    assert(scans_to("0.5", 0.5));
    assert(scans_to("5.", 5.0));
    assert(scans_to("0.0", 0.0));
    assert(scans_to("-0.0", -0.0));
    assert(scans_to("0.000", 0.0));
    assert(scans_to("0.1", 0.1));
    assert(scans_to("0.2", 0.2));
    assert(scans_to("0.3", 0.3));
    assert(scans_to("1.7976931348623157", 1.7976931348623157));
    assert(scans_to("3.141592653589793", 3.141592653589793));
    assert(scans_to("2.2250738585072014", 2.2250738585072014));
}

static void test_exponents(void) {
    assert(scans_to("1e2", 100.0));
    assert(scans_to("1E2", 100.0));
    assert(scans_to("1e+2", 100.0));
    assert(scans_to("1e-2", 0.01));
    assert(scans_to("1e0", 1.0));
    assert(scans_to("1e00002", 100.0));
    assert(scans_to("1.5e3", 1500.0));
    assert(scans_to("1e308", 1e308));
    assert(scans_to("1e-308", 1e-308));
    assert(scans_to("5e-324", 5e-324)); /* smallest denormal */
    assert(scans_to("1e309", INFINITY));
    assert(scans_to("-1e309", -INFINITY));
    assert(scans_to("1e-400", 0.0));
    assert(scans_to("-1e-400", -0.0));
    /* The exponent accumulator saturates rather than wrapping. */
    assert(scans_to("1e99999", INFINITY));
    assert(scans_to("1e-99999", 0.0));
    /* Zero short-circuits before any exponent is applied. */
    assert(scans_to("0e99999", 0.0));
    assert(scans_to("-0e99999", -0.0));
}

static void test_radix_prefixes(void) {
    assert(scans_to("0xff", 255.0));
    assert(scans_to("0xFF", 255.0));
    assert(scans_to("-0xff", -255.0));
    assert(scans_to("0xdeadbeef", 3735928559.0));
    assert(scans_to("2r1010", 10.0));
    assert(scans_to("8r777", 511.0));
    assert(scans_to("16rdeadbeef", 3735928559.0));
    assert(scans_to("36rZZ", 1295.0));
    assert(scans_to("36rz", 35.0));
    /* A radix of 0 or 1 in the prefix falls back to the default base 10. */
    assert(scans_to("0r55", 55.0));
    assert(scans_to("1r0", 0.0));
    /* 'e' is a digit outside base 10, so only '&' introduces an exponent. */
    assert(scans_to("16r1&2", 256.0));
    assert(scans_to("10r1&2", 100.0));
    /* The '&' exponent digits are read in the mantissa's radix too, so this is
     * 1 * 2^2 rather than 1 * 2^10. */
    assert(scans_to("2r1&10", 4.0));
    assert(scans_to("16r1e", 30.0));
    assert(rejects("2r102"));
    assert(rejects("37r1"));
    assert(rejects("1r2"));
}

static void test_hex_floats(void) {
    /* 'p' switches to a base-2 mantissa with a base-10 exponent, and rescales
     * the fractional digits already seen. */
    assert(scans_to("0x1p4", 16.0));
    assert(scans_to("0x1p-4", 0.0625));
    assert(scans_to("0x1.8p1", 3.0));
    assert(scans_to("0x1.8P1", 3.0));
    assert(scans_to("16r1.8p1", 3.0));
    assert(scans_to("-0x1.8p1", -3.0));
    assert(scans_to("0xffp0", 255.0));
    /* 'p' is an ordinary digit in bases above 25. */
    assert(scans_to("26r1p", 51.0));
}

static void test_explicit_base(void) {
    double value = 0.0;
    assert(scan_base("ff", 16, &value) == 0 && same_double(value, 255.0));
    assert(scan_base("1010", 2, &value) == 0 && same_double(value, 10.0));
    assert(scan_base("z", 36, &value) == 0 && same_double(value, 35.0));
    assert(scan_base("10", 10, &value) == 0 && same_double(value, 10.0));
    assert(scan_base("1e2", 10, &value) == 0 && same_double(value, 100.0));
    /* An explicit base suppresses prefix detection: 0x is not special, and
     * 'x' is not a digit in base 16. */
    assert(scan_base("0xff", 16, &value) == 1);
    assert(scan_base("2r10", 10, &value) == 1);
    /* Base 0 means "detect". */
    assert(scan_base("0xff", 0, &value) == 0 && same_double(value, 255.0));
}

static void test_rejections(void) {
    assert(rejects(""));
    assert(rejects("-"));
    assert(rejects("+"));
    assert(rejects("."));
    assert(rejects("-."));
    assert(rejects("e5"));
    assert(rejects("1.2.3"));
    assert(rejects("1e"));
    assert(rejects("1e+"));
    assert(rejects("1e5e5"));
    assert(rejects("1e1.5"));
    assert(rejects("_1"));
    assert(scans_to("1__0", 10.0)); /* repeated separators after a digit are fine */
    assert(rejects("0x"));
    assert(rejects("abc"));
    assert(rejects("1abc"));
    assert(rejects("nan"));
    assert(rejects("inf"));
    assert(rejects(" 1"));
    assert(rejects("1 "));
    assert(rejects("1\xff"));

    /* A negative length, a zero length, and an absurd length all fail. */
    double value = 0.0;
    assert(janet_scan_number((const uint8_t *) "1", 0, &value) == 1);
    assert(janet_scan_number((const uint8_t *) "1", -1, &value) == 1);
}

static void test_long_input(void) {
    /* 0xFFFF bytes is the documented cutoff. */
    static char digits[0x10002];
    double value = 0.0;

    memset(digits, '0', sizeof(digits));
    digits[0] = '1';

    assert(janet_scan_number((const uint8_t *) digits, 0xFFFF, &value) == 0);
    assert(isinf(value) && value > 0);
    assert(janet_scan_number((const uint8_t *) digits, 0x10000, &value) == 1);

    /* A long fractional tail drives the exponent very negative without
     * wrapping it. */
    digits[0] = '0';
    digits[1] = '.';
    digits[0xFFFE] = '1';
    assert(janet_scan_number((const uint8_t *) digits, 0xFFFF, &value) == 0);
    assert(same_double(value, 0.0));
}

static void test_wide_mantissa(void) {
    /* Enough significant digits to force multi-digit BigNat arithmetic in both
     * the multiply and the premultiply-and-divide paths. */
    assert(scans_to(
               "123456789012345678901234567890123456789012345678901234567890",
               123456789012345678901234567890123456789012345678901234567890.0));
    assert(scans_to(
               "0.000000000000000000000000000000000000000000000000000000000001234567890123456789",
               1.234567890123456789e-60));
    assert(scans_to("1234567890123456789012345678901234567890e-40",
                    1234567890123456789012345678901234567890e-40));
    assert(scans_to("0.1e-300", 0.1e-300));
    assert(scans_to("1234567890123456789e289", 1234567890123456789e289));
}

#ifdef JANET_INT_TYPES
static void test_numeric_suffixes(void) {
    Janet value;

    assert(janet_scan_numeric((const uint8_t *) "12", 2, &value) == 0);
    assert(janet_checktype(value, JANET_NUMBER));
    assert(janet_unwrap_number(value) == 12.0);

    assert(janet_scan_numeric((const uint8_t *) "12:n", 4, &value) == 0);
    assert(janet_checktype(value, JANET_NUMBER));
    assert(janet_unwrap_number(value) == 12.0);

    assert(janet_scan_numeric((const uint8_t *) "-9223372036854775808:s", 22, &value) == 0);
    assert(janet_is_int(value) == JANET_INT_S64);
    assert(janet_unwrap_s64(value) == INT64_MIN);

    assert(janet_scan_numeric((const uint8_t *) "18446744073709551615:u", 22, &value) == 0);
    assert(janet_is_int(value) == JANET_INT_U64);
    assert(janet_unwrap_u64(value) == UINT64_MAX);

    /* Out of range for the requested width, an unknown suffix, and a bad
     * mantissa all report failure. */
    assert(janet_scan_numeric((const uint8_t *) "18446744073709551616:u", 22, &value) == 1);
    assert(janet_scan_numeric((const uint8_t *) "-1:u", 4, &value) == 1);
    assert(janet_scan_numeric((const uint8_t *) "1:q", 3, &value) == 1);
    assert(janet_scan_numeric((const uint8_t *) "x:n", 3, &value) == 1);
    /* A colon anywhere but the second-to-last byte is not a suffix. */
    assert(janet_scan_numeric((const uint8_t *) "1:", 2, &value) == 1);
    assert(janet_scan_numeric((const uint8_t *) ":s", 2, &value) == 1);
}
#endif

static void test_dtostr(void) {
    JanetBuffer *buffer = janet_buffer(0);

    janet_buffer_dtostr(buffer, 1.0);
    assert(buffer->count == 1 && buffer->data[0] == '1');

    buffer->count = 0;
    janet_buffer_dtostr(buffer, 0.1);
    assert(buffer->count == 19);
    assert(!memcmp(buffer->data, "0.10000000000000001", 19));

    buffer->count = 0;
    janet_buffer_dtostr(buffer, -0.0);
    assert(buffer->count == 2 && !memcmp(buffer->data, "-0", 2));

    /* Appending preserves the existing contents. */
    buffer->count = 0;
    janet_buffer_push_cstring(buffer, "x=");
    janet_buffer_dtostr(buffer, 2.5);
    assert(buffer->count == 5 && !memcmp(buffer->data, "x=2.5", 5));

    /* No comma survives regardless of locale. */
    buffer->count = 0;
    janet_buffer_dtostr(buffer, 1234.5678);
    for (int32_t i = 0; i < buffer->count; i++) assert(buffer->data[i] != ',');
}

void numscan_contract(void) {
    janet_init();

    test_integers();
    test_fractions();
    test_exponents();
    test_radix_prefixes();
    test_hex_floats();
    test_explicit_base();
    test_rejections();
    test_long_input();
    test_wide_mantissa();
#ifdef JANET_INT_TYPES
    test_numeric_suffixes();
#endif
    test_dtostr();

    janet_deinit();
}
