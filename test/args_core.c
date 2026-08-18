/* Behavioral contract for the argument extraction layer, run against whichever
 * implementation the build selected (`-Dargs-core=c` or the Zig default).
 *
 * What is under test is a set of decisions and a set of messages, and the two
 * are checked separately because the port separates them. The kernels decide
 * and fill in a JanetArgFault; janet_arg_raise renders it. So every case below
 * drives an exported janet_get* or janet_opt* through a try scope and compares
 * the payload byte for byte, which is the only way to show that a fault code
 * plus a slot really does reconstruct the message the C original raised.
 *
 * The suites reach almost none of this. A Janet program that calls a cfunction
 * with the wrong argument sees one of these messages and stops, so the common
 * shapes are covered incidentally and the rest - every width of integer, both
 * range foldings, the flag ceiling, the three cbytes shapes - are not reached
 * at all. They are enumerated here.
 *
 * Two behaviors are pinned rather than asserted as correct. janet_checkfloat
 * tests against FLT_MIN, so janet_getfloat rejects zero and every negative
 * number; and janet_getflags silently ignores a permitted set longer than 64
 * characters. Both are in FOUND.md, both are reproduced by the port, and both
 * are pinned so that a later fix has to be deliberate.
 */

#include <assert.h>
#include <float.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "features.h"
#include <janet.h>
#include "state.h"
#include "util.h"

/* Every panic this file expects is counted, because a case that silently
 * stopped panicking would otherwise look exactly like one that passed. */
static int panics_fired = 0;

/* Fixed rather than a floor: a case that stopped raising would otherwise be a
 * silent subtraction. Verified against -Dargs-core=c before Zig was trusted.
 * A build without integer types raises four more, because janet_getinteger64
 * and janet_getuinteger64 have a fault path of their own there and delegate to
 * an abstract type's here. */
#ifdef JANET_INT_TYPES
#define EXPECTED_PANICS 70
#else
#define EXPECTED_PANICS 74
#endif

#define EXPECT_PANIC(expr, message) do { \
    JanetTryState _state; \
    volatile int _returned = 0; \
    JanetSignal _sig = janet_try(&_state); \
    if (!_sig) { \
        (void)(expr); \
        _returned = 1; \
    } \
    janet_restore(&_state); \
    assert(!_returned && "expected a panic, got a return"); \
    assert(_sig == JANET_SIGNAL_ERROR); \
    assert(janet_checktype(_state.payload, JANET_STRING)); \
    if (janet_cstrcmp(janet_unwrap_string(_state.payload), (message))) { \
        printf("expected: %s\n     got: %s\n", (message), \
               (const char *) janet_unwrap_string(_state.payload)); \
        assert(0 && "message mismatch"); \
    } \
    panics_fired++; \
} while (0)

/* An abstract value renders with its address, so those two messages are
 * compared by prefix. Everything else is compared whole. */
#define EXPECT_PANIC_PREFIX(expr, prefix) do { \
    JanetTryState _state; \
    volatile int _returned = 0; \
    JanetSignal _sig = janet_try(&_state); \
    if (!_sig) { \
        (void)(expr); \
        _returned = 1; \
    } \
    janet_restore(&_state); \
    assert(!_returned && "expected a panic, got a return"); \
    assert(_sig == JANET_SIGNAL_ERROR); \
    assert(janet_checktype(_state.payload, JANET_STRING)); \
    { \
        const uint8_t *_m = janet_unwrap_string(_state.payload); \
        if (strncmp((const char *) _m, (prefix), strlen(prefix))) { \
            printf("expected prefix: %s\n            got: %s\n", (prefix), (const char *) _m); \
            assert(0 && "message prefix mismatch"); \
        } \
    } \
    panics_fired++; \
} while (0)

/* ------------------------------------------------------------------ arity */

static void test_arity(void) {
    janet_fixarity(2, 2);
    janet_arity(2, 1, 3);
    janet_arity(2, -1, -1);
    janet_arity(0, -1, 0);
    janet_arity(99, 1, -1);

    EXPECT_PANIC(janet_fixarity(1, 2), "arity mismatch, expected 2, got 1");
    EXPECT_PANIC(janet_fixarity(3, 2), "arity mismatch, expected 2, got 3");
    EXPECT_PANIC(janet_arity(0, 1, 3), "arity mismatch, expected at least 1, got 0");
    EXPECT_PANIC(janet_arity(4, 1, 3), "arity mismatch, expected at most 3, got 4");
    /* A negative bound is unbounded, so only the other side can fault. */
    EXPECT_PANIC(janet_arity(4, -1, 3), "arity mismatch, expected at most 3, got 4");
    EXPECT_PANIC(janet_arity(0, 1, -1), "arity mismatch, expected at least 1, got 0");
}

/* ------------------------------------------------------------- type faults */

static void test_type_faults(void) {
    Janet argv[4];
    argv[0] = janet_wrap_nil();
    argv[1] = janet_wrap_integer(7);
    argv[2] = janet_cstringv("hello");
    argv[3] = janet_wrap_true();

    /* The slot number in the message is the slot that was asked for, not the
     * position of the value in some other list. */
    EXPECT_PANIC(janet_getnumber(argv, 0), "bad slot #0, expected number, got nil");
    EXPECT_PANIC(janet_getstring(argv, 1), "bad slot #1, expected string, got 7");
    EXPECT_PANIC(janet_getarray(argv, 2), "bad slot #2, expected array, got \"hello\"");
    EXPECT_PANIC(janet_gettable(argv, 3), "bad slot #3, expected table, got true");
    EXPECT_PANIC(janet_getbuffer(argv, 0), "bad slot #0, expected buffer, got nil");
    EXPECT_PANIC(janet_getfiber(argv, 0), "bad slot #0, expected fiber, got nil");
    EXPECT_PANIC(janet_getfunction(argv, 0), "bad slot #0, expected function, got nil");
    EXPECT_PANIC(janet_getcfunction(argv, 0), "bad slot #0, expected cfunction, got nil");
    EXPECT_PANIC(janet_getkeyword(argv, 0), "bad slot #0, expected keyword, got nil");
    EXPECT_PANIC(janet_getsymbol(argv, 0), "bad slot #0, expected symbol, got nil");
    EXPECT_PANIC(janet_gettuple(argv, 0), "bad slot #0, expected tuple, got nil");
    EXPECT_PANIC(janet_getstruct(argv, 0), "bad slot #0, expected struct, got nil");
    EXPECT_PANIC(janet_getboolean(argv, 0), "bad slot #0, expected boolean, got nil");
    EXPECT_PANIC(janet_getpointer(argv, 0), "bad slot #0, expected pointer, got nil");

    /* The three view getters report a set of types rather than one. */
    EXPECT_PANIC(janet_getindexed(argv, 0), "bad slot #0, expected array or tuple, got nil");
    EXPECT_PANIC(janet_getbytes(argv, 0), "bad slot #0, expected string, symbol, keyword or buffer, got nil");
    EXPECT_PANIC(janet_getdictionary(argv, 0), "bad slot #0, expected table or struct, got nil");

    /* And the success paths, which have to agree with the C original about
     * where the data and the length come from. */
    assert(janet_getnumber(argv, 1) == 7.0);
    assert(!janet_cstrcmp(janet_getstring(argv, 2), "hello"));
    assert(janet_getboolean(argv, 3) == 1);
}

/* --------------------------------------------------------- numeric getters */

static void test_numeric_faults(void) {
    Janet argv[3];
    argv[0] = janet_wrap_nil();
    argv[1] = janet_wrap_number(1.5);
    argv[2] = janet_wrap_number(-1.0);

    /* Every one of the eleven expectation codes, in the words janet_arg_raise
     * spells them. A code that mapped to the wrong noun would show here and
     * nowhere else. */
    EXPECT_PANIC(janet_getinteger(argv, 0), "bad slot #0, expected 32 bit signed integer, got nil");
    EXPECT_PANIC(janet_getinteger(argv, 1), "bad slot #1, expected 32 bit signed integer, got 1.5");
    EXPECT_PANIC(janet_getuinteger(argv, 2), "bad slot #2, expected 32 bit unsigned integer, got -1");
    EXPECT_PANIC(janet_getinteger16(argv, 1), "bad slot #1, expected 16 bit signed integer, got 1.5");
    EXPECT_PANIC(janet_getuinteger16(argv, 2), "bad slot #2, expected 16 bit unsigned integer, got -1");
    EXPECT_PANIC(janet_getinteger8(argv, 1), "bad slot #1, expected 8 bit signed integer, got 1.5");
    EXPECT_PANIC(janet_getuinteger8(argv, 2), "bad slot #2, expected 8 bit unsigned integer, got -1");
    EXPECT_PANIC(janet_getnat(argv, 2), "bad slot #2, expected non-negative 32 bit signed integer, got -1");
    EXPECT_PANIC(janet_getfloat(argv, 0), "bad slot #0, expected float number, got nil");
#ifndef JANET_INT_TYPES
    EXPECT_PANIC(janet_getinteger64(argv, 1), "bad slot #1, expected 64 bit signed integer, got 1.5");
    EXPECT_PANIC(janet_getuinteger64(argv, 2), "bad slot #2, expected 64 bit unsigned integer, got -1");
#endif
}

/* The boundaries of each width, taken from both sides, because an off-by-one
 * in a range test is invisible to every other test here. */
static void test_numeric_boundaries(void) {
    Janet argv[1];

#define ACCEPTS(getter, value, expected) do { \
    argv[0] = janet_wrap_number((double)(value)); \
    assert(getter(argv, 0) == (expected)); \
} while (0)

#define REJECTS(getter, value) do { \
    argv[0] = janet_wrap_number((double)(value)); \
    JanetTryState _s; \
    volatile int _r = 0; \
    JanetSignal _g = janet_try(&_s); \
    if (!_g) { (void) getter(argv, 0); _r = 1; } \
    janet_restore(&_s); \
    assert(!_r && "expected a range rejection"); \
    panics_fired++; \
} while (0)

    ACCEPTS(janet_getinteger, INT32_MAX, INT32_MAX);
    ACCEPTS(janet_getinteger, INT32_MIN, INT32_MIN);
    REJECTS(janet_getinteger, (double) INT32_MAX + 1.0);
    REJECTS(janet_getinteger, (double) INT32_MIN - 1.0);

    ACCEPTS(janet_getuinteger, UINT32_MAX, UINT32_MAX);
    ACCEPTS(janet_getuinteger, 0, 0);
    REJECTS(janet_getuinteger, (double) UINT32_MAX + 1.0);
    REJECTS(janet_getuinteger, -1.0);

    ACCEPTS(janet_getinteger16, INT16_MAX, INT16_MAX);
    ACCEPTS(janet_getinteger16, INT16_MIN, INT16_MIN);
    REJECTS(janet_getinteger16, INT16_MAX + 1);
    REJECTS(janet_getinteger16, INT16_MIN - 1);

    ACCEPTS(janet_getuinteger16, UINT16_MAX, UINT16_MAX);
    REJECTS(janet_getuinteger16, UINT16_MAX + 1);

    ACCEPTS(janet_getinteger8, INT8_MAX, INT8_MAX);
    ACCEPTS(janet_getinteger8, INT8_MIN, INT8_MIN);
    REJECTS(janet_getinteger8, INT8_MAX + 1);
    REJECTS(janet_getinteger8, INT8_MIN - 1);

    ACCEPTS(janet_getuinteger8, UINT8_MAX, UINT8_MAX);
    REJECTS(janet_getuinteger8, UINT8_MAX + 1);

    ACCEPTS(janet_getnat, 0, 0);
    ACCEPTS(janet_getnat, INT32_MAX, INT32_MAX);
    REJECTS(janet_getnat, -1);

    /* Only the defined half of janet_checksize's domain is exercised. The C
     * original casts to size_t before testing the round trip, which is
     * undefined for a negative, infinite or enormous double and aborts a
     * sanitizer build outright - reachable from Janet source as
     * (gcsetinterval -1). It is in FOUND.md, and per this phase's rules
     * undefined behavior gets no contract, because the result would belong to
     * the development target rather than to the language. */
    ACCEPTS(janet_getsize, 0, 0);
    ACCEPTS(janet_getsize, 1, 1);
    REJECTS(janet_getsize, 1.5);

#ifndef JANET_INT_TYPES
    ACCEPTS(janet_getinteger64, 9007199254740992.0, 9007199254740992LL);
    ACCEPTS(janet_getinteger64, -9007199254740992.0, -9007199254740992LL);
    /* The ceiling is 2^53, not INT64_MAX: past it a double cannot name
     * consecutive integers, so the round trip would accept a value that is not
     * the one that was written. */
    REJECTS(janet_getinteger64, 9007199254740994.0);
    ACCEPTS(janet_getuinteger64, 9007199254740992.0, 9007199254740992ULL);
    REJECTS(janet_getuinteger64, -1.0);
#endif

    /* A fractional value is rejected at every width, which is the round trip
     * rather than the range test doing the work. */
    REJECTS(janet_getinteger, 0.5);
    REJECTS(janet_getuinteger, 0.5);
    REJECTS(janet_getinteger16, 0.5);
    REJECTS(janet_getinteger8, 0.5);
    REJECTS(janet_getnat, 0.5);

#undef ACCEPTS
#undef REJECTS
}

/* janet_checkfloat tests `>= FLT_MIN`, and FLT_MIN is the smallest positive
 * normal float rather than the most negative finite one. So janet_getfloat
 * rejects zero, every negative value, and every subnormal, and accepts only
 * positive normals that survive a round trip through float. This is a defect
 * in the C implementation, recorded in FOUND.md, and it is pinned rather than
 * asserted as correct: the port reproduces it, and a later fix has to be a
 * deliberate change to this test. */
static void test_getfloat_rejects_zero_and_negatives(void) {
    Janet argv[1];

    argv[0] = janet_wrap_number(1.5);
    assert(janet_getfloat(argv, 0) == 1.5f);

    argv[0] = janet_wrap_number(0.0);
    EXPECT_PANIC(janet_getfloat(argv, 0), "bad slot #0, expected float number, got 0");
    argv[0] = janet_wrap_number(-1.5);
    EXPECT_PANIC(janet_getfloat(argv, 0), "bad slot #0, expected float number, got -1.5");

    assert(!janet_checkfloat(janet_wrap_number(0.0)));
    assert(!janet_checkfloat(janet_wrap_number(-1.0)));
    assert(!janet_checkfloat(janet_wrap_number((double) FLT_MIN / 2.0)));
    assert(janet_checkfloat(janet_wrap_number((double) FLT_MIN)));
    assert(janet_checkfloat(janet_wrap_number((double) FLT_MAX)));
    assert(!janet_checkfloat(janet_wrap_number((double) FLT_MAX * 2.0)));
    /* A double with more precision than a float holds fails the round trip. */
    assert(!janet_checkfloat(janet_wrap_number(1.0000000000000002)));
}

/* ----------------------------------------------------------------- ranges */

static void test_ranges(void) {
    Janet argv[4];
    argv[0] = janet_wrap_integer(0);
    argv[1] = janet_wrap_integer(3);
    argv[2] = janet_wrap_integer(-1);
    argv[3] = janet_wrap_nil();

    /* A half range folds a negative index against length + 1 and accepts
     * length itself, because it names a boundary between elements. */
    assert(janet_gethalfrange(argv, 0, 10, "start") == 0);
    assert(janet_gethalfrange(argv, 1, 10, "start") == 3);
    assert(janet_gethalfrange(argv, 2, 10, "end") == 10);
    argv[0] = janet_wrap_integer(10);
    assert(janet_gethalfrange(argv, 0, 10, "end") == 10);
    argv[0] = janet_wrap_integer(-11);
    assert(janet_gethalfrange(argv, 0, 10, "start") == 0);

    argv[0] = janet_wrap_integer(11);
    EXPECT_PANIC(janet_gethalfrange(argv, 0, 10, "start"),
                 "start index 11 out of range [-11,10]");
    argv[0] = janet_wrap_integer(-12);
    EXPECT_PANIC(janet_gethalfrange(argv, 0, 10, "end"),
                 "end index -12 out of range [-11,10]");

    /* An argument index folds against length and its interval is half open,
     * yet it still accepts length itself - the one asymmetry between the two. */
    argv[0] = janet_wrap_integer(0);
    assert(janet_getargindex(argv, 0, 10, "at") == 0);
    argv[0] = janet_wrap_integer(-1);
    assert(janet_getargindex(argv, 0, 10, "at") == 9);
    argv[0] = janet_wrap_integer(-10);
    assert(janet_getargindex(argv, 0, 10, "at") == 0);

    argv[0] = janet_wrap_integer(11);
    EXPECT_PANIC(janet_getargindex(argv, 0, 10, "at"),
                 "at index 11 out of range [-10,10)");
    argv[0] = janet_wrap_integer(-11);
    EXPECT_PANIC(janet_getargindex(argv, 0, 10, "at"),
                 "at index -11 out of range [-10,10)");

    /* A non-integer faults as an integer before any folding happens, so the
     * message names the type rather than the range. */
    argv[0] = janet_cstringv("x");
    EXPECT_PANIC(janet_gethalfrange(argv, 0, 10, "start"),
                 "bad slot #0, expected 32 bit signed integer, got \"x\"");

    /* The start and end forms supply a default when the slot is absent or nil,
     * and the defaults are the two ends of the sequence. */
    argv[0] = janet_wrap_integer(4);
    assert(janet_getstartrange(argv, 1, 3, 10) == 0);
    assert(janet_getendrange(argv, 1, 3, 10) == 10);
    argv[3] = janet_wrap_nil();
    assert(janet_getstartrange(argv, 4, 3, 10) == 0);
    assert(janet_getendrange(argv, 4, 3, 10) == 10);
    assert(janet_getstartrange(argv, 4, 0, 10) == 4);
}

static void test_getslice(void) {
    Janet argv[3];
    argv[0] = janet_wrap_array(janet_array(0));
    janet_array_push(janet_unwrap_array(argv[0]), janet_wrap_integer(1));
    janet_array_push(janet_unwrap_array(argv[0]), janet_wrap_integer(2));
    janet_array_push(janet_unwrap_array(argv[0]), janet_wrap_integer(3));

    JanetRange r = janet_getslice(1, argv);
    assert(r.start == 0 && r.end == 3);

    argv[1] = janet_wrap_integer(1);
    r = janet_getslice(2, argv);
    assert(r.start == 1 && r.end == 3);

    argv[2] = janet_wrap_integer(2);
    r = janet_getslice(3, argv);
    assert(r.start == 1 && r.end == 2);

    /* An end before the start collapses to an empty range rather than
     * faulting, which is the one piece of arithmetic janet_getslice does
     * itself. */
    argv[1] = janet_wrap_integer(3);
    argv[2] = janet_wrap_integer(1);
    r = janet_getslice(3, argv);
    assert(r.start == 3 && r.end == 3);

    EXPECT_PANIC(janet_getslice(0, argv), "arity mismatch, expected at least 1, got 0");
    EXPECT_PANIC(janet_getslice(4, argv), "arity mismatch, expected at most 3, got 4");
}

/* ------------------------------------------------------------------ flags */

static void test_flags(void) {
    Janet argv[2];
    argv[0] = janet_ckeywordv("acb");
    argv[1] = janet_ckeywordv("z");

    /* Each character contributes the bit at its position in the permitted set,
     * and the order of the keyword does not matter. */
    assert(janet_getflags(argv, 0, "abc") == 0x7);
    argv[0] = janet_ckeywordv("");
    assert(janet_getflags(argv, 0, "abc") == 0);
    argv[0] = janet_ckeywordv("c");
    assert(janet_getflags(argv, 0, "abc") == 0x4);
    /* A repeated character sets the same bit twice, which is not an error. */
    argv[0] = janet_ckeywordv("aa");
    assert(janet_getflags(argv, 0, "abc") == 0x1);

    EXPECT_PANIC(janet_getflags(argv, 1, "abc"),
                 "unexpected flag z, expected one of \"abc\"");

    /* Not a keyword at all faults before any scanning. */
    argv[0] = janet_cstringv("a");
    EXPECT_PANIC(janet_getflags(argv, 0, "abc"), "bad slot #0, expected keyword, got \"a\"");

    /* A permitted set longer than 64 characters has its tail silently ignored,
     * so a character that appears only past the ceiling is reported as
     * unexpected rather than accepted. Pinned, not endorsed: FOUND.md. */
    {
        char wide[80];
        int i;
        for (i = 0; i < 70; i++) wide[i] = (char)('0' + (i % 10));
        wide[64] = 'Z';
        wide[70] = 0;
        argv[0] = janet_ckeywordv("Z");
        EXPECT_PANIC(janet_getflags(argv, 0, wide), "unexpected flag Z, expected one of \"0123456789012345678901234567890123456789012345678901234567890123Z56789\"");
    }
}

/* ------------------------------------------------------------- byte access */

static void test_bytes_and_cstrings(void) {
    Janet argv[4];
    argv[0] = janet_cstringv("hi");
    argv[1] = janet_wrap_buffer(janet_buffer(8));
    janet_buffer_push_cstring(janet_unwrap_buffer(argv[1]), "buf");
    argv[2] = janet_ckeywordv("kw");
    argv[3] = janet_wrap_nil();

    JanetByteView v = janet_getbytes(argv, 0);
    assert(v.len == 2 && !memcmp(v.bytes, "hi", 2));
    v = janet_getbytes(argv, 1);
    assert(v.len == 3 && !memcmp(v.bytes, "buf", 3));
    v = janet_getbytes(argv, 2);
    assert(v.len == 2 && !memcmp(v.bytes, "kw", 2));

    assert(!strcmp(janet_getcstring(argv, 0), "hi"));
    assert(!strcmp(janet_getcbytes(argv, 1), "buf"));
    /* The terminating shape leaves the buffer's visible count alone: the zero
     * is written past the end and the count is put back. */
    assert(janet_unwrap_buffer(argv[1])->count == 3);

    EXPECT_PANIC(janet_getcstring(argv, 1), "bad slot #1, expected string, got @\"buf\"");
    EXPECT_PANIC(janet_getcstring(argv, 3), "bad slot #3, expected string, got nil");
    EXPECT_PANIC(janet_getcbytes(argv, 3),
                 "bad slot #3, expected string, symbol, keyword or buffer, got nil");

    /* An embedded zero is rejected for every shape that can carry one. */
    {
        JanetBuffer *b = janet_buffer(8);
        janet_buffer_push_u8(b, 'a');
        janet_buffer_push_u8(b, 0);
        janet_buffer_push_u8(b, 'b');
        argv[0] = janet_wrap_buffer(b);
        EXPECT_PANIC(janet_getcbytes(argv, 0), "bytes contain embedded 0s");
    }
    {
        const uint8_t raw[3] = { 'a', 0, 'b' };
        argv[0] = janet_wrap_string(janet_string(raw, 3));
        EXPECT_PANIC(janet_getcstring(argv, 0), "bytes contain embedded 0s");
    }
}

/* The third cbytes shape: a buffer that cannot be realloced and is exactly
 * full, where pushing a terminator would panic. It is copied with the scratch
 * allocator instead, which the suites never reach because a no-realloc buffer
 * only comes from janet_buffer_init_custom paths. */
static void test_cbytes_copies_a_full_no_realloc_buffer(void) {
    JanetBuffer *b = janet_buffer(0);
    uint8_t backing[3];
    Janet argv[1];

    janet_buffer_deinit(b);
    janet_buffer_init(b, 0);
    janet_free(b->data);
    b->data = backing;
    b->count = 3;
    b->capacity = 3;
    b->gc.flags |= JANET_BUFFER_FLAG_NO_REALLOC;
    memcpy(backing, "abc", 3);

    argv[0] = janet_wrap_buffer(b);
    const char *s = janet_getcbytes(argv, 0);
    assert(!strcmp(s, "abc"));
    /* The copy is a separate allocation, not the buffer's own storage. */
    assert((const uint8_t *) s != backing);
    assert(b->count == 3);
    assert(!memcmp(backing, "abc", 3));

    /* Put it back into a shape janet_buffer_deinit can free. */
    b->data = NULL;
    b->count = 0;
    b->capacity = 0;
    b->gc.flags &= ~(int32_t) JANET_BUFFER_FLAG_NO_REALLOC;
}

/* ---------------------------------------------------------------- abstract */

static const JanetAbstractType probe_at = {
    "args-core/probe", NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL
};

static JanetByteView probe_bytes(void *p, size_t len) {
    JanetByteView view;
    (void) len;
    view.bytes = (const uint8_t *) p;
    view.len = 3;
    return view;
}

static const JanetAbstractType probe_bytes_at = {
    "args-core/bytes-probe", NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, probe_bytes, NULL
};

static const JanetAbstractType other_at = {
    "args-core/other", NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL
};

static void test_abstract(void) {
    Janet argv[3];
    void *p = janet_abstract(&probe_at, 4);
    void *q = janet_abstract(&probe_bytes_at, 4);
    memcpy(q, "xyz", 3);
    argv[0] = janet_wrap_abstract(p);
    argv[1] = janet_wrap_abstract(q);
    argv[2] = janet_wrap_nil();

    assert(janet_getabstract(argv, 0, &probe_at) == p);
    assert(janet_checkabstract(argv[0], &probe_at) == p);
    /* checkabstract reports the mismatch by returning NULL rather than by
     * raising: it is the same decision with the other half discarded. */
    assert(janet_checkabstract(argv[0], &other_at) == NULL);
    assert(janet_checkabstract(argv[2], &probe_at) == NULL);

    EXPECT_PANIC_PREFIX(janet_getabstract(argv, 0, &other_at),
                        "bad slot #0, expected args-core/other, got <args-core/probe 0x");
    EXPECT_PANIC(janet_getabstract(argv, 2, &probe_at),
                 "bad slot #2, expected args-core/probe, got nil");

    /* An abstract with a `bytes` callback is byte-viewable, and the callback
     * runs on the C side of the seam. One without is not, and faults as an
     * ordinary type mismatch. */
    JanetByteView v = janet_getbytes(argv, 1);
    assert(v.len == 3 && !memcmp(v.bytes, "xyz", 3));
    assert(janet_bytes_view(argv[1], &v.bytes, &v.len));
    assert(v.len == 3);
    EXPECT_PANIC_PREFIX(janet_getbytes(argv, 0),
                        "bad slot #0, expected string, symbol, keyword or buffer, got <args-core/probe 0x");

    assert(janet_optabstract(argv, 3, 0, &probe_at, NULL) == p);
    assert(janet_optabstract(argv, 3, 2, &probe_at, p) == p);
    assert(janet_optabstract(argv, 1, 2, &probe_at, p) == p);
}

/* -------------------------------------------------------------- defaulting */

static void test_optionals(void) {
    Janet argv[3];
    argv[0] = janet_wrap_integer(5);
    argv[1] = janet_wrap_nil();
    argv[2] = janet_cstringv("s");

    /* Past the end and an explicit nil both mean the default; anything else is
     * delegated to the strict getter, faults included. */
    assert(janet_optinteger(argv, 3, 0, 99) == 5);
    assert(janet_optinteger(argv, 3, 1, 99) == 99);
    assert(janet_optinteger(argv, 3, 7, 99) == 99);
    assert(janet_optnat(argv, 3, 1, 4) == 4);
    assert(janet_optsize(argv, 3, 1, 8) == 8);
    assert(janet_optuinteger(argv, 3, 1, 8) == 8);
    assert(janet_optuinteger64(argv, 3, 1, 8) == 8);
    assert(janet_optinteger64(argv, 3, 1, 8) == 8);
    assert(janet_optnumber(argv, 3, 0, 0.0) == 5.0);
    assert(!janet_cstrcmp(janet_optstring(argv, 3, 2, NULL), "s"));
    assert(janet_optstring(argv, 3, 1, NULL) == NULL);
    assert(!strcmp(janet_optcstring(argv, 3, 2, "d"), "s"));
    assert(!strcmp(janet_optcstring(argv, 3, 1, "d"), "d"));
    assert(!strcmp(janet_optcbytes(argv, 3, 1, "d"), "d"));
    assert(janet_optboolean(argv, 3, 1, 1) == 1);
    assert(janet_optpointer(argv, 3, 1, NULL) == NULL);
    assert(janet_optcfunction(argv, 3, 1, NULL) == NULL);
    assert(janet_optfiber(argv, 3, 1, NULL) == NULL);
    assert(janet_optfunction(argv, 3, 1, NULL) == NULL);
    assert(janet_opttuple(argv, 3, 1, NULL) == NULL);
    assert(janet_optstruct(argv, 3, 1, NULL) == NULL);
    assert(janet_optkeyword(argv, 3, 1, NULL) == NULL);
    assert(janet_optsymbol(argv, 3, 1, NULL) == NULL);

    EXPECT_PANIC(janet_optinteger(argv, 3, 2, 99),
                 "bad slot #2, expected 32 bit signed integer, got \"s\"");

    /* The three length-defaulted getters build an empty collection instead of
     * taking one, so the default is a capacity rather than a value. */
    {
        JanetBuffer *b = janet_optbuffer(argv, 3, 1, 16);
        JanetTable *t = janet_opttable(argv, 3, 1, 4);
        JanetArray *a = janet_optarray(argv, 3, 1, 4);
        assert(b != NULL && b->count == 0 && b->capacity >= 16);
        assert(t != NULL && t->count == 0);
        assert(a != NULL && a->count == 0);
        argv[1] = janet_wrap_buffer(b);
        assert(janet_optbuffer(argv, 3, 1, 16) == b);
        argv[1] = janet_wrap_nil();
    }
}

/* ---------------------------------------------------------------- strlike */

static void test_strlike(void) {
    assert(janet_keyeq(janet_ckeywordv("a"), "a"));
    assert(!janet_keyeq(janet_ckeywordv("a"), "b"));
    /* The type has to match as well as the bytes, which is the whole reason
     * there are three of these rather than one. */
    assert(!janet_keyeq(janet_cstringv("a"), "a"));
    assert(!janet_keyeq(janet_csymbolv("a"), "a"));
    assert(janet_streq(janet_cstringv("a"), "a"));
    assert(!janet_streq(janet_ckeywordv("a"), "a"));
    assert(janet_symeq(janet_csymbolv("a"), "a"));
    assert(!janet_symeq(janet_cstringv("a"), "a"));
    assert(!janet_streq(janet_wrap_nil(), "a"));
    assert(janet_streq(janet_cstringv(""), ""));
}

/* ---------------------------------------------------------------- methods */

static Janet method_one(int32_t argc, Janet *argv) {
    (void) argc;
    (void) argv;
    return janet_wrap_integer(1);
}

static Janet method_two(int32_t argc, Janet *argv) {
    (void) argc;
    (void) argv;
    return janet_wrap_integer(2);
}

static void test_methods(void) {
    static const JanetMethod methods[] = {
        {"one", method_one},
        {"two", method_two},
        {NULL, NULL}
    };
    Janet out = janet_wrap_nil();

    assert(janet_getmethod(janet_cstring("one"), methods, &out));
    assert(janet_unwrap_cfunction(out) == method_one);
    assert(janet_getmethod(janet_cstring("two"), methods, &out));
    assert(janet_unwrap_cfunction(out) == method_two);
    assert(!janet_getmethod(janet_cstring("three"), methods, &out));

    /* nextmethod is an iterator: nil starts at the head, and any other key
     * resumes after the entry it names. Running off the end yields nil, and so
     * does a key that is not in the table at all - it walks to the end looking
     * for it. */
    Janet k = janet_nextmethod(methods, janet_wrap_nil());
    assert(janet_keyeq(k, "one"));
    k = janet_nextmethod(methods, k);
    assert(janet_keyeq(k, "two"));
    k = janet_nextmethod(methods, k);
    assert(janet_checktype(k, JANET_NIL));
    assert(janet_checktype(janet_nextmethod(methods, janet_ckeywordv("nope")), JANET_NIL));
}

/* ------------------------------------------------------------- predicates */

/* The ten check functions are public API in their own right, and janet_getsize
 * is the only caller of janet_checksize that could otherwise show a
 * disagreement. The C original casts to size_t before testing, which is
 * undefined for a negative or enormous double; the port tests before casting.
 * Every input either language defines has to reach the same answer. */
static void test_check_predicates(void) {
    assert(janet_checkint(janet_wrap_integer(0)));
    assert(!janet_checkint(janet_wrap_nil()));
    assert(!janet_checkint(janet_cstringv("1")));
    assert(!janet_checkuint(janet_wrap_number(-0.0001)));
    assert(janet_checkuint(janet_wrap_number(0.0)));

    assert(!janet_checksize(janet_wrap_number(0.5)));
    assert(janet_checksize(janet_wrap_number(0.0)));
    assert(janet_checksize(janet_wrap_number(1.0)));
    assert(janet_checksize(janet_wrap_number(9007199254740992.0)));
    assert(!janet_checksize(janet_wrap_number(9007199254740994.0)));

    /* NaN and the infinities fail the first comparison at every width rather
     * than reaching a conversion. */
    {
        double n = 0.0 / 0.0;
        double inf = 1.0 / 0.0;
        assert(!janet_checkint(janet_wrap_number(n)));
        assert(!janet_checkuint(janet_wrap_number(n)));
        assert(!janet_checkfloat(janet_wrap_number(n)));
        assert(!janet_checkint(janet_wrap_number(inf)));
        assert(!janet_checkint(janet_wrap_number(-inf)));
        assert(!janet_checkfloat(janet_wrap_number(inf)));
        /* janet_checksize is absent here for the reason given above. */
    }
}

/* ---------------------------------------------------------------- the view
 * helpers, which are the substrate the getters are built on and move with
 * them. Their failure is a return value rather than a fault. */

static void test_views(void) {
    const Janet *items;
    const uint8_t *bytes;
    const JanetKV *kvs;
    int32_t len, cap;

    JanetArray *a = janet_array(0);
    janet_array_push(a, janet_wrap_integer(1));
    assert(janet_indexed_view(janet_wrap_array(a), &items, &len));
    assert(len == 1);
    assert(janet_indexed_view(janet_wrap_tuple(janet_tuple_n(items, 1)), &items, &len));
    assert(len == 1);
    assert(!janet_indexed_view(janet_wrap_nil(), &items, &len));

    assert(janet_bytes_view(janet_cstringv("ab"), &bytes, &len));
    assert(len == 2);
    assert(janet_bytes_view(janet_csymbolv("ab"), &bytes, &len));
    assert(len == 2);
    assert(!janet_bytes_view(janet_wrap_integer(1), &bytes, &len));

    JanetTable *t = janet_table(1);
    janet_table_put(t, janet_ckeywordv("k"), janet_wrap_integer(1));
    assert(janet_dictionary_view(janet_wrap_table(t), &kvs, &len, &cap));
    assert(len == 1 && cap == t->capacity);
    assert(!janet_dictionary_view(janet_wrap_nil(), &kvs, &len, &cap));
}

int main(void) {
    janet_init();

    test_arity();
    test_type_faults();
    test_numeric_faults();
    test_numeric_boundaries();
    test_getfloat_rejects_zero_and_negatives();
    test_ranges();
    test_getslice();
    test_flags();
    test_bytes_and_cstrings();
    test_cbytes_copies_a_full_no_realloc_buffer();
    test_abstract();
    test_optionals();
    test_strlike();
    test_methods();
    test_check_predicates();
    test_views();

    /* A count rather than a floor, so that a case which stops raising is a
     * failure rather than a silent subtraction. */
    if (panics_fired != EXPECTED_PANICS) {
        printf("expected %d panics, got %d\n", EXPECTED_PANICS, panics_fired);
        assert(0 && "panic count changed");
    }

    janet_deinit();
    printf("args core contract ok (%d panics)\n", panics_fired);
    return 0;
}
