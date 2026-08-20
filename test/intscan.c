#include <assert.h>
#include <stdint.h>
#include <string.h>
#include <janet.h>

static int scan_i64(const char *text, int64_t *out) {
    return janet_scan_int64((const uint8_t *) text, (int32_t) strlen(text), out);
}

static int scan_u64(const char *text, uint64_t *out) {
    return janet_scan_uint64((const uint8_t *) text, (int32_t) strlen(text), out);
}

void intscan_contract(void) {
    int64_t signed_value = 123;
    uint64_t unsigned_value = 123;

    assert(scan_i64("0", &signed_value) && signed_value == 0);
    assert(scan_i64("-0", &signed_value) && signed_value == 0);
    assert(scan_i64("+42", &signed_value) && signed_value == 42);
    assert(scan_i64("-9223372036854775808", &signed_value) && signed_value == INT64_MIN);
    assert(scan_i64("9223372036854775807", &signed_value) && signed_value == INT64_MAX);
    assert(scan_i64("16r7fff_ffff_ffff_ffff", &signed_value) && signed_value == INT64_MAX);
    assert(!scan_i64("9223372036854775808", &signed_value));
    assert(!scan_i64("-9223372036854775809", &signed_value));

    assert(scan_u64("18446744073709551615", &unsigned_value) && unsigned_value == UINT64_MAX);
    assert(scan_u64("0xffff_ffff_ffff_ffff", &unsigned_value) && unsigned_value == UINT64_MAX);
    assert(scan_u64("2r101010", &unsigned_value) && unsigned_value == 42);
    assert(scan_u64("36rZ", &unsigned_value) && unsigned_value == 35);
    assert(scan_u64("1_000_000", &unsigned_value) && unsigned_value == UINT64_C(1000000));
    assert(!scan_u64("18446744073709551616", &unsigned_value));
    assert(!scan_u64("-1", &unsigned_value));
    assert(!scan_u64("_1", &unsigned_value));
    assert(!scan_u64("0x", &unsigned_value));
    assert(!scan_u64("37r1", &unsigned_value));
    assert(!scan_u64("12z", &unsigned_value));
}
