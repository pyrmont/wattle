/* Behavioral contract for the marshalling protocol, run against whichever
 * implementation the build selected (`-Dmarsh=c` or the Zig default).
 *
 * The reason this file exists rather than leaning on `test/suite-marsh.janet`:
 * the suite reaches `marshal` and `unmarshal`, and those two cfunctions use a
 * strict subset of the subsystem. Everything below is either unreachable from
 * Janet or unobservable there.
 *
 *  - `JANET_MARSHAL_UNSAFE` has no Janet spelling. `cfun_marshal` never sets
 *    it and `cfun_unmarshal` passes a hard zero, so pointers, cfunctions,
 *    pointer-backed buffers and threaded abstracts -- five of the twenty-nine
 *    lead bytes -- are reachable only from C.
 *  - The twenty-function marshal context API is called from an abstract type's
 *    `marshal` and `unmarshal` callbacks and from nowhere else. The core types
 *    that have such callbacks exercise four of the twenty between them.
 *  - `janet_env_lookup_into`'s `prefix` and `recurse` parameters are both
 *    fixed by `janet_env_lookup`, which is what `env-lookup` calls.
 *  - `janet_unmarshal`'s `next` out-parameter is dropped by `cfun_unmarshal`.
 *
 * The wire format is the other reason. A marshalled stream is a file format,
 * so its bytes are the contract rather than an implementation detail, and the
 * assertions below are written against literal bytes for that reason.
 */

#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "features.h"
#include <janet.h>

#include "support.h"
#include "util.h"

static JanetTable *test_env;

static int panics_fired = 0;
#define EXPECTED_PANICS 30

#define EXPECT_PANIC(expr, message) do { \
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
    if (janet_cstrcmp(janet_unwrap_string(_state.payload), (message))) { \
        printf("expected: %s\n     got: %s\n", (message), \
               (const char *) janet_unwrap_string(_state.payload)); \
        assert(0 && "message mismatch"); \
    } \
    panics_fired++; \
} while (0)

/* Three messages end in `%p`, which renders an address. Only their prefix is
 * a contract. */
#define EXPECT_PANIC_PREFIX(expr, prefix) do { \
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
    { \
        JanetString _s = janet_unwrap_string(_state.payload); \
        size_t _n = strlen(prefix); \
        if ((size_t) janet_string_length(_s) < _n || memcmp(_s, (prefix), _n)) { \
            printf("expected prefix: %s\n            got: %s\n", (prefix), (const char *) _s); \
            assert(0 && "message prefix mismatch"); \
        } \
    } \
    panics_fired++; \
} while (0)

static void check_bytes(JanetBuffer *b, const char *expected, int32_t len) {
    if (b->count != len || memcmp(b->data, expected, (size_t) len)) {
        printf("expected %d bytes:", len);
        for (int32_t i = 0; i < len; i++) printf(" %02x", (unsigned char) expected[i]);
        printf("\n     got %d bytes:", b->count);
        for (int32_t i = 0; i < b->count; i++) printf(" %02x", b->data[i]);
        printf("\n");
        assert(0 && "wire format mismatch");
    }
}

#define CHECK_WIRE(buf, literal) check_bytes((buf), (literal), (int32_t)(sizeof(literal) - 1))

static JanetBuffer *marshalled(Janet x, JanetTable *rreg, int flags) {
    JanetBuffer *b = janet_buffer(16);
    janet_marshal(b, x, rreg, flags);
    return b;
}

static Janet unmarshalled(JanetBuffer *b, int flags) {
    return janet_unmarshal(b->data, (size_t) b->count, flags, NULL, NULL);
}

/* ------------------------------------------------- the probe abstract type
 *
 * One abstract type whose callbacks drive every entry point of the context
 * API, so that a round trip through it is a round trip through all twenty.
 * The pointer fields are written only in unsafe mode, which is also what makes
 * this type a witness for `janet_marshal_flags`. */

typedef struct {
    int32_t i32;
    int64_t i64;
    size_t sz;
    uint8_t byte;
    uint8_t bytes[4];
    Janet value;
    void *ptr;
} Probe;

static const JanetAbstractType probe_type;

static void probe_marshal(void *p, JanetMarshalContext *ctx) {
    Probe *probe = (Probe *)p;
    janet_marshal_abstract(ctx, p);
    janet_marshal_int(ctx, probe->i32);
    janet_marshal_int64(ctx, probe->i64);
    janet_marshal_size(ctx, probe->sz);
    janet_marshal_byte(ctx, probe->byte);
    janet_marshal_bytes(ctx, probe->bytes, sizeof(probe->bytes));
    janet_marshal_janet(ctx, probe->value);
    janet_marshal_byte(ctx, (uint8_t)(janet_marshal_flags(ctx) & JANET_MARSHAL_UNSAFE ? 1 : 0));
    if (janet_marshal_flags(ctx) & JANET_MARSHAL_UNSAFE) {
        janet_marshal_ptr(ctx, probe->ptr);
    }
}

/* A read that raises reports and returns; it no longer leaves this function by
 * itself, so every read is followed by a test. `test_a_truncated_stream_is_
 * refused_at_every_length` cuts the stream at every offset, so each of these
 * really is reached -- without them the reads walk off the end of the source
 * and the assertion below fires on a byte that was never written. The report
 * is left standing deliberately: the thunk that called this turns it back into
 * a raise. */
#define BAIL_IF_RAISING(value) do { if (janet_contract_raising()) return (value); } while (0)

static void *probe_unmarshal(JanetMarshalContext *ctx) {
    Probe *probe = janet_unmarshal_abstract(ctx, sizeof(Probe));
    BAIL_IF_RAISING(NULL);
    probe->i32 = janet_unmarshal_int(ctx);
    BAIL_IF_RAISING(probe);
    probe->i64 = janet_unmarshal_int64(ctx);
    BAIL_IF_RAISING(probe);
    probe->sz = janet_unmarshal_size(ctx);
    BAIL_IF_RAISING(probe);
    janet_unmarshal_ensure(ctx, 1);
    BAIL_IF_RAISING(probe);
    probe->byte = janet_unmarshal_byte(ctx);
    BAIL_IF_RAISING(probe);
    janet_unmarshal_bytes(ctx, probe->bytes, sizeof(probe->bytes));
    BAIL_IF_RAISING(probe);
    probe->value = janet_unmarshal_janet(ctx);
    BAIL_IF_RAISING(probe);
    probe->ptr = NULL;
    int unsafe = janet_unmarshal_byte(ctx);
    BAIL_IF_RAISING(probe);
    if (unsafe) {
        assert(janet_unmarshal_flags(ctx) & JANET_MARSHAL_UNSAFE);
        probe->ptr = janet_unmarshal_ptr(ctx);
    }
    return probe;
}

static const JanetAbstractType probe_type = {
    "test/marsh-probe",
    NULL, NULL, NULL, NULL,
    probe_marshal,
    probe_unmarshal,
    JANET_ATEND_UNMARSHAL
};

/* A type that always reaches for a pointer, so that the safe-mode refusal has
 * something to refuse. */
static void refuser_marshal(void *p, JanetMarshalContext *ctx) {
    janet_marshal_abstract(ctx, p);
    janet_marshal_ptr(ctx, p);
}

static void *refuser_unmarshal(JanetMarshalContext *ctx) {
    void *p = janet_unmarshal_abstract(ctx, sizeof(int));
    BAIL_IF_RAISING(p);
    (void) janet_unmarshal_ptr(ctx);
    return p;
}

static const JanetAbstractType refuser_type = {
    "test/marsh-refuser",
    NULL, NULL, NULL, NULL,
    refuser_marshal,
    refuser_unmarshal,
    JANET_ATEND_UNMARSHAL
};

/* A type that writes more bytes than a Janet buffer can index. */
static void toobig_marshal(void *p, JanetMarshalContext *ctx) {
    janet_marshal_abstract(ctx, p);
    janet_marshal_bytes(ctx, (const uint8_t *) p, (size_t) INT32_MAX + 1);
}

static const JanetAbstractType toobig_type = {
    "test/marsh-toobig",
    NULL, NULL, NULL, NULL,
    toobig_marshal,
    NULL,
    JANET_ATEND_UNMARSHAL
};

/* A type whose callbacks break the two halves of the abstract protocol: one
 * registers itself twice, the other never registers at all. */
static void protocol_marshal(void *p, JanetMarshalContext *ctx) {
    janet_marshal_abstract(ctx, p);
    janet_marshal_byte(ctx, *(uint8_t *)p);
}

static void *twice_unmarshal(JanetMarshalContext *ctx) {
    void *p = janet_unmarshal_abstract(ctx, 1);
    janet_unmarshal_abstract_reuse(ctx, p);
    return p;
}

static const JanetAbstractType twice_type = {
    "test/marsh-twice",
    NULL, NULL, NULL, NULL,
    protocol_marshal,
    twice_unmarshal,
    JANET_ATEND_UNMARSHAL
};

static void *never_unmarshal(JanetMarshalContext *ctx) {
    (void) janet_unmarshal_byte(ctx);
    return janet_abstract(CONTRACT_AT(probe_type), sizeof(Probe));
}

static const JanetAbstractType never_type = {
    "test/marsh-never",
    NULL, NULL, NULL, NULL,
    protocol_marshal,
    never_unmarshal,
    JANET_ATEND_UNMARSHAL
};

static void *threaded_unmarshal(JanetMarshalContext *ctx) {
    return janet_unmarshal_abstract_threaded(ctx, 1);
}

static const JanetAbstractType threaded_type = {
    "test/marsh-threaded",
    NULL, NULL, NULL, NULL,
    protocol_marshal,
    threaded_unmarshal,
    JANET_ATEND_UNMARSHAL
};

/* A type with no callbacks at all, which is what makes a value unmarshallable
 * rather than merely unregistered. */
static const JanetAbstractType inert_type = {
    "test/marsh-inert",
    NULL, NULL, NULL, NULL, NULL, NULL,
    JANET_ATEND_UNMARSHAL
};

/* -------------------------------------------------------- the integer codec */

/* `pushint` picks one of three encodings by range, and `readint` picks by lead
 * byte. Neither boundary is observable from Janet, where a marshalled integer
 * is just an integer coming back. */
static void test_the_three_integer_encodings(void) {
    CHECK_WIRE(marshalled(janet_wrap_integer(0), NULL, 0), "\x00");
    CHECK_WIRE(marshalled(janet_wrap_integer(127), NULL, 0), "\x7f");
    CHECK_WIRE(marshalled(janet_wrap_integer(128), NULL, 0), "\x80\x80");
    CHECK_WIRE(marshalled(janet_wrap_integer(8191), NULL, 0), "\x9f\xff");
    CHECK_WIRE(marshalled(janet_wrap_integer(8192), NULL, 0), "\xcd\x00\x00\x20\x00");
    CHECK_WIRE(marshalled(janet_wrap_integer(-1), NULL, 0), "\xbf\xff");
    CHECK_WIRE(marshalled(janet_wrap_integer(-8192), NULL, 0), "\xa0\x00");
    CHECK_WIRE(marshalled(janet_wrap_integer(-8193), NULL, 0), "\xcd\xff\xff\xdf\xff");
    CHECK_WIRE(marshalled(janet_wrap_integer(INT32_MIN), NULL, 0), "\xcd\x80\x00\x00\x00");
    CHECK_WIRE(marshalled(janet_wrap_integer(INT32_MAX), NULL, 0), "\xcd\x7f\xff\xff\xff");

    /* And back. The two-byte form sign extends its eighteen most significant
     * bits, which is the half of `readint` a positive value never reaches. */
    static const struct {
        const char *bytes;
        int32_t len;
        int32_t value;
    } cases[] = {
        { "\x00", 1, 0 },
        { "\x7f", 1, 127 },
        { "\x80\x80", 2, 128 },
        { "\x9f\xff", 2, 8191 },
        { "\xa0\x00", 2, -8192 },
        { "\xbf\xff", 2, -1 },
        { "\xcd\x80\x00\x00\x00", 5, INT32_MIN },
        { "\xcd\x7f\xff\xff\xff", 5, INT32_MAX },
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        Janet out = janet_unmarshal((const uint8_t *) cases[i].bytes,
                                    (size_t) cases[i].len, 0, NULL, NULL);
        assert(janet_checktype(out, JANET_NUMBER));
        assert(janet_unwrap_integer(out) == cases[i].value);
    }
}

/* A double that is not an exact int32 takes the eight-byte path and is
 * recorded as a reference; an integral one never is. */
static void test_reals_and_integral_doubles_differ(void) {
    JanetBuffer *b = marshalled(janet_wrap_number(0.5), NULL, 0);
    assert(b->count == 9);
    assert(b->data[0] == 200 /* LB_REAL */);
    assert(janet_unwrap_number(unmarshalled(b, 0)) == 0.5);

    CHECK_WIRE(marshalled(janet_wrap_number(3.0), NULL, 0), "\x03");

    /* 2^31 is integral and outside int32, so it is a real. */
    b = marshalled(janet_wrap_number(2147483648.0), NULL, 0);
    assert(b->count == 9 && b->data[0] == 200);
    assert(janet_unwrap_number(unmarshalled(b, 0)) == 2147483648.0);
}

/* ------------------------------------------------------- the 64-bit codec */

/* `push64` is length-prefixed above 0xF0 and bare below it, and only the
 * context API reaches it. */
static void test_the_size_encoding_boundaries(void) {
    static const uint64_t values[] = {
        0, 1, 0xEF, 0xF0, 0xF1, 0xFF, 0x100, 0xFFFFFFFFu,
        0x0102030405060708ull, 0xFFFFFFFFFFFFFFFFull
    };
    for (size_t i = 0; i < sizeof(values) / sizeof(values[0]); i++) {
        Probe *probe = janet_abstract(CONTRACT_AT(probe_type), sizeof(Probe));
        memset(probe, 0, sizeof(Probe));
        probe->i64 = (int64_t) values[i];
        probe->sz = (size_t) values[i];
        probe->value = janet_wrap_nil();
        JanetBuffer *b = marshalled(janet_wrap_abstract(probe), NULL, 0);
        Probe *back = janet_unwrap_abstract(unmarshalled(b, 0));
        assert((uint64_t) back->i64 == values[i]);
        assert((uint64_t) back->sz == values[i]);
    }

    /* The prefix byte counts the bytes that follow, little endian. */
    Probe *probe = janet_abstract(CONTRACT_AT(probe_type), sizeof(Probe));
    memset(probe, 0, sizeof(Probe));
    probe->i64 = 0x0102;
    probe->value = janet_wrap_nil();
    JanetBuffer *b = marshalled(janet_wrap_abstract(probe), NULL, 0);
    /* ...LB_ABSTRACT, name, i32=0, then the int64. */
    const uint8_t *at = b->data + b->count - (1 + 2)  /* i64 */
                        - 1                            /* sz, zero */
                        - 1                            /* byte */
                        - 4                            /* bytes */
                        - 1                            /* value: nil */
                        - 1;                           /* the unsafe marker */
    assert(at[0] == 0xF2 && at[1] == 0x02 && at[2] == 0x01);

    /* Nine bytes of length is not a 64-bit integer. */
    EXPECT_PANIC(janet_unmarshal((const uint8_t *) "\xf9\0\0\0\0\0\0\0\0\0", 10, 0, NULL, NULL),
                 "unknown byte f9 at index 0");
}

/* ------------------------------------------------------- the context API */

static Probe *make_probe(void) {
    Probe *probe = janet_abstract(CONTRACT_AT(probe_type), sizeof(Probe));
    probe->i32 = -12345;
    probe->i64 = -0x0102030405060708ll;
    probe->sz = 0x1234;
    probe->byte = 0xAB;
    memcpy(probe->bytes, "wxyz", 4);
    probe->value = janet_cstringv("payload");
    probe->ptr = (void *) CONTRACT_AT(probe_type);
    return probe;
}

static void test_the_context_api_round_trips(void) {
    Probe *probe = make_probe();
    JanetBuffer *b = marshalled(janet_wrap_abstract(probe), NULL, 0);
    Janet out = unmarshalled(b, 0);
    assert(janet_checktype(out, JANET_ABSTRACT));
    assert(janet_abstract_type(janet_unwrap_abstract(out)) == CONTRACT_AT(probe_type));
    Probe *back = janet_unwrap_abstract(out);
    assert(back != probe);
    assert(back->i32 == probe->i32);
    assert(back->i64 == probe->i64);
    assert(back->sz == probe->sz);
    assert(back->byte == probe->byte);
    assert(memcmp(back->bytes, "wxyz", 4) == 0);
    assert(janet_equals(back->value, probe->value));
    /* Safe mode: the pointer was not written, so it does not come back. */
    assert(back->ptr == NULL);

    /* Unsafe mode carries it. */
    b = marshalled(janet_wrap_abstract(probe), NULL, JANET_MARSHAL_UNSAFE);
    back = janet_unwrap_abstract(unmarshalled(b, JANET_MARSHAL_UNSAFE));
    assert(back->ptr == (void *) CONTRACT_AT(probe_type));

    /* The stream opens with LB_ABSTRACT and the type's name as a symbol. */
    assert(b->data[0] == 217 /* LB_ABSTRACT */);
    assert(b->data[1] == 207 /* LB_SYMBOL */);
    assert(b->data[2] == (uint8_t) strlen(probe_type.name));
    assert(memcmp(b->data + 3, probe_type.name, strlen(probe_type.name)) == 0);
}

/* The abstract is entered into the reference table before its fields are read,
 * so a value that contains itself resolves rather than recursing. */
static void test_an_abstract_can_contain_itself(void) {
    Probe *probe = make_probe();
    Janet self = janet_wrap_abstract(probe);
    JanetArray *holder = janet_array(1);
    janet_array_push(holder, self);
    probe->value = janet_wrap_array(holder);

    JanetBuffer *b = marshalled(self, NULL, 0);
    Probe *back = janet_unwrap_abstract(unmarshalled(b, 0));
    assert(janet_checktype(back->value, JANET_ARRAY));
    JanetArray *back_holder = janet_unwrap_array(back->value);
    assert(back_holder->count == 1);
    assert(janet_unwrap_abstract(back_holder->data[0]) == back);
}

static void test_the_abstract_protocol_is_enforced(void) {
    uint8_t *twice = janet_abstract(CONTRACT_AT(twice_type), 1);
    *twice = 7;
    JanetBuffer *b = marshalled(janet_wrap_abstract(twice), NULL, 0);
    EXPECT_PANIC(unmarshalled(b, 0), "janet_unmarshal_abstract called more than once");

    uint8_t *never = janet_abstract(CONTRACT_AT(never_type), 1);
    *never = 7;
    b = marshalled(janet_wrap_abstract(never), NULL, 0);
    EXPECT_PANIC(unmarshalled(b, 0), "janet_unmarshal_abstract not called");

    uint8_t *threaded = janet_abstract(CONTRACT_AT(threaded_type), 1);
    *threaded = 7;
    b = marshalled(janet_wrap_abstract(threaded), NULL, 0);
    /* `JANET_THREADS` is defined by no build in this tree, so this arm is the
     * only one that has ever been compiled. See `FOUND.md`. */
    EXPECT_PANIC(unmarshalled(b, 0), "threaded abstracts not supported");

    int *inert = janet_abstract(CONTRACT_AT(inert_type), sizeof(int));
    *inert = 7;
    EXPECT_PANIC_PREFIX(marshalled(janet_wrap_abstract(inert), NULL, 0),
                        "cannot marshal <test/marsh-inert 0x");
}

static void test_the_unsafe_gate_on_the_context_api(void) {
    void *refuser = janet_abstract(CONTRACT_AT(refuser_type), sizeof(int));
    EXPECT_PANIC(marshalled(janet_wrap_abstract(refuser), NULL, 0),
                 "can only marshal pointers in unsafe mode");

    JanetBuffer *b = marshalled(janet_wrap_abstract(refuser), NULL, JANET_MARSHAL_UNSAFE);
    EXPECT_PANIC(unmarshalled(b, 0), "can only unmarshal pointers in unsafe mode");
    /* And succeeds when the flag is given. */
    assert(janet_checktype(unmarshalled(b, JANET_MARSHAL_UNSAFE), JANET_ABSTRACT));

    /* A length that cannot be a buffer index is refused before anything is
     * read from it. */
    void *toobig = janet_abstract(CONTRACT_AT(toobig_type), sizeof(int));
    EXPECT_PANIC(marshalled(janet_wrap_abstract(toobig), NULL, 0),
                 "size_t too large to fit in buffer");
}

/* ---------------------------------------------------- the unsafe payloads */

static Janet a_cfunction(int32_t argc, Janet *argv) {
    (void) argc;
    (void) argv;
    return janet_wrap_integer(1729);
}

static void test_pointers_and_cfunctions_need_the_unsafe_flag(void) {
    Janet ptr = janet_wrap_pointer((void *) CONTRACT_AT(probe_type));
    Janet cfun = janet_wrap_cfunction(a_cfunction);

    EXPECT_PANIC_PREFIX(marshalled(ptr, NULL, 0),
                        "no registry value and cannot marshal <pointer 0x");
    EXPECT_PANIC_PREFIX(marshalled(cfun, NULL, 0),
                        "no registry value and cannot marshal <cfunction 0x");

    JanetBuffer *b = marshalled(ptr, NULL, JANET_MARSHAL_UNSAFE);
    assert(b->data[0] == 222 /* LB_UNSAFE_POINTER */);
    assert(b->count == 1 + (int32_t) sizeof(void *));
    assert(janet_unwrap_pointer(unmarshalled(b, JANET_MARSHAL_UNSAFE)) == (void *) CONTRACT_AT(probe_type));
    EXPECT_PANIC(unmarshalled(b, 0),
                 "unsafe flag not given, will not unmarshal raw pointer at index 1");

    b = marshalled(cfun, NULL, JANET_MARSHAL_UNSAFE);
    assert(b->data[0] == 221 /* LB_UNSAFE_CFUNCTION */);
    Janet back = unmarshalled(b, JANET_MARSHAL_UNSAFE);
    assert(janet_unwrap_cfunction(back) == a_cfunction);
    EXPECT_PANIC(unmarshalled(b, 0),
                 "unsafe flag not given, will not unmarshal function pointer at index 1");
}

/* ------------------------------------------------------ the weak vocabulary */

/* `LB_THREADED_ABSTRACT` and `LB_POINTER_BUFFER` are inside `#ifdef JANET_EV`
 * in the lead-byte enum and the seven weak-container bytes that follow them
 * are not, so the weak bytes renumber with the build. That is a defect, it is
 * upstream's, and this pins it in whichever configuration is being built --
 * see `FOUND.md`. */
#ifdef JANET_EV
#define LB_WEAK_BASE 226
#else
#define LB_WEAK_BASE 224
#endif

static void test_the_weak_lead_bytes_move_with_the_event_loop(void) {
    JanetTable *weakk = janet_table_weakk(1);
    JanetTable *weakv = janet_table_weakv(1);
    JanetTable *weakkv = janet_table_weakkv(1);
    JanetArray *weak_array = janet_array_weak(0);

    assert(marshalled(janet_wrap_table(weakk), NULL, 0)->data[0] == LB_WEAK_BASE + 0);
    assert(marshalled(janet_wrap_table(weakv), NULL, 0)->data[0] == LB_WEAK_BASE + 1);
    assert(marshalled(janet_wrap_table(weakkv), NULL, 0)->data[0] == LB_WEAK_BASE + 2);
    assert(marshalled(janet_wrap_array(weak_array), NULL, 0)->data[0] == LB_WEAK_BASE + 6);

    weakk->proto = janet_table(0);
    weakv->proto = janet_table(0);
    weakkv->proto = janet_table(0);
    assert(marshalled(janet_wrap_table(weakk), NULL, 0)->data[0] == LB_WEAK_BASE + 3);
    assert(marshalled(janet_wrap_table(weakv), NULL, 0)->data[0] == LB_WEAK_BASE + 4);
    assert(marshalled(janet_wrap_table(weakkv), NULL, 0)->data[0] == LB_WEAK_BASE + 5);

    /* And each comes back as the same flavour of weak container. */
    JanetBuffer *b = marshalled(janet_wrap_array(weak_array), NULL, 0);
    Janet back = unmarshalled(b, 0);
    assert(janet_checktype(back, JANET_ARRAY));
    b = marshalled(janet_wrap_table(weakkv), NULL, 0);
    back = unmarshalled(b, 0);
    assert(janet_checktype(back, JANET_TABLE));
    assert(janet_unwrap_table(back)->proto != NULL);
}

/* --------------------------------------------------------- the reference table */

/* A tuple and a struct are marked seen *after* their contents are written and
 * everything else before, which decides whether a self-reference is expressible
 * at all. */
static void test_when_a_value_becomes_a_reference(void) {
    JanetArray *a = janet_array(1);
    janet_array_push(a, janet_wrap_array(a));
    JanetBuffer *b = marshalled(janet_wrap_array(a), NULL, 0);
    /* LB_ARRAY, count 1, then LB_REFERENCE 0. */
    CHECK_WIRE(b, "\xd1\x01\xda\x00");
    Janet back = unmarshalled(b, 0);
    JanetArray *back_a = janet_unwrap_array(back);
    assert(back_a->count == 1 && janet_unwrap_array(back_a->data[0]) == back_a);

    /* The same array twice is one reference and one back-reference. */
    JanetArray *outer = janet_array(2);
    JanetArray *inner = janet_array(0);
    janet_array_push(outer, janet_wrap_array(inner));
    janet_array_push(outer, janet_wrap_array(inner));
    b = marshalled(janet_wrap_array(outer), NULL, 0);
    CHECK_WIRE(b, "\xd1\x02\xd1\x00\xda\x01");
    back_a = janet_unwrap_array(unmarshalled(b, 0));
    assert(janet_unwrap_array(back_a->data[0]) == janet_unwrap_array(back_a->data[1]));

    /* With cycles switched off nothing is recorded, so the same array is
     * written twice and the copies come back distinct. */
    b = marshalled(janet_wrap_array(outer), NULL, JANET_MARSHAL_NO_CYCLES);
    CHECK_WIRE(b, "\xd1\x02\xd1\x00\xd1\x00");
    back_a = janet_unwrap_array(unmarshalled(b, 0));
    assert(janet_unwrap_array(back_a->data[0]) != janet_unwrap_array(back_a->data[1]));

    /* And a cyclic value has nothing to stop it but the recursion guard. */
    EXPECT_PANIC(marshalled(janet_wrap_array(a), NULL, JANET_MARSHAL_NO_CYCLES),
                 "stack overflow");
}

static void test_a_reference_index_is_bounds_checked(void) {
    EXPECT_PANIC(janet_unmarshal((const uint8_t *) "\xda\x00", 2, 0, NULL, NULL),
                 "invalid reference 0");
    /* Neither of the other two reference bytes is a lead byte: a funcenv
     * reference is only read where a funcenv is expected, and a funcdef
     * reference where a funcdef is. */
    EXPECT_PANIC(janet_unmarshal((const uint8_t *) "\xdb\x00", 2, 0, NULL, NULL),
                 "unknown byte db at index 0");
    EXPECT_PANIC(janet_unmarshal((const uint8_t *) "\xdc\x00", 2, 0, NULL, NULL),
                 "unknown byte dc at index 0");
    /* A function with no environments, whose funcdef is a reference into an
     * empty table. */
    EXPECT_PANIC(janet_unmarshal((const uint8_t *) "\xd7\x00\xdc\x00", 4, 0, NULL, NULL),
                 "invalid funcdef reference 0");
}

/* ------------------------------------------------- functions and closures */

static int32_t only_index_of(JanetBuffer *b, uint8_t lead) {
    int32_t found = -1;
    for (int32_t i = 0; i < b->count; i++) {
        if (b->data[i] != lead) continue;
        assert(found < 0 && "expected exactly one occurrence of this lead byte");
        found = i;
    }
    assert(found >= 0 && "expected this lead byte to appear");
    return found;
}

static int32_t call_thunk(Janet f) {
    Janet result = janet_wrap_nil();
    JanetFiber *fiber = NULL;
    JanetSignal sig = janet_pcall(janet_unwrap_function(f), 0, NULL, &result, &fiber);
    assert(sig == JANET_SIGNAL_OK);
    return janet_unwrap_integer(result);
}

/* The funcenv and funcdef tables are the two reference tables that have no
 * Janet-visible effect: sharing is preserved rather than observed, so what
 * pins them is the wire format and the failure of a corrupted index. */
static void test_function_streams_and_their_back_references(void) {
    Janet out;

    /* Two closures over one variable share a funcenv, so the second is written
     * as a back reference. */
    assert(!janet_dostring(test_env, "(do (var x 41) [(fn [] x) (fn [] (+ x 1))])",
                           "marsh-test", &out));
    JanetBuffer *b = marshalled(out, NULL, 0);
    janet_gcroot(janet_wrap_buffer(b));
    int32_t at = only_index_of(b, 219 /* LB_FUNCENV_REF */);
    Janet closures = unmarshalled(b, 0);
    janet_gcroot(closures);
    const Janet *back = janet_unwrap_tuple(closures);
    assert(call_thunk(back[0]) == 41);
    assert(call_thunk(back[1]) == 42);
    janet_gcunroot(closures);
    b->data[at + 1] = 0x7f;
    EXPECT_PANIC(unmarshalled(b, 0), "invalid funcenv reference 127");

    /* Two instances of one `fn` share a funcdef, and only the second is a back
     * reference -- the closed-over values are still written twice. */
    assert(!janet_dostring(test_env, "(tuple ;(map (fn [x] (fn [] x)) [7 8]))", "marsh-test", &out));
    janet_gcunroot(janet_wrap_buffer(b));
    b = marshalled(out, NULL, 0);
    janet_gcroot(janet_wrap_buffer(b));
    at = only_index_of(b, 220 /* LB_FUNCDEF_REF */);
    Janet instances = unmarshalled(b, 0);
    janet_gcroot(instances);
    const Janet *pair = janet_unwrap_tuple(instances);
    assert(call_thunk(pair[0]) == 7);
    assert(call_thunk(pair[1]) == 8);
    janet_gcunroot(instances);
    b->data[at + 1] = 0x7f;
    EXPECT_PANIC(unmarshalled(b, 0), "invalid funcdef reference 127");
    janet_gcunroot(janet_wrap_buffer(b));

    /* A function carries at most 255 environments on the wire. */
    EXPECT_PANIC(janet_unmarshal((const uint8_t *) "\xd7\xcd\x00\x00\x01\x00", 6, 0, NULL, NULL),
                 "invalid function - too many environments (256)");

    /* A funcdef is verified before it is handed back. This one declares no
     * flags, no slots, no constants and no bytecode, which is the smallest
     * well-formed header a stream can carry and still not be a function. */
    EXPECT_PANIC(janet_unmarshal((const uint8_t *) "\xd7\x00\x00\x00\x00\x00\x00\x00\x00",
                                 9, 0, NULL, NULL),
                 "funcdef has invalid bytecode");
}

/* ------------------------------------------------------------- the registry */

static void test_the_reverse_registry_short_circuits(void) {
    JanetTable *rreg = janet_table(1);
    JanetArray *a = janet_array(0);
    janet_table_put(rreg, janet_wrap_array(a), janet_csymbolv("an-array"));

    JanetBuffer *b = marshalled(janet_wrap_array(a), rreg, 0);
    /* LB_REGISTRY, length, name. */
    CHECK_WIRE(b, "\xd8\x08" "an-array");

    /* Without a forward table the name resolves to nil. */
    assert(janet_checktype(unmarshalled(b, 0), JANET_NIL));

    JanetTable *reg = janet_table(1);
    janet_table_put(reg, janet_csymbolv("an-array"), janet_wrap_array(a));
    Janet back = janet_unmarshal(b->data, (size_t) b->count, 0, reg, NULL);
    assert(janet_unwrap_array(back) == a);

    /* A registry hit is still recorded as a reference, so a second occurrence
     * is a back-reference rather than a second name. */
    JanetArray *outer = janet_array(2);
    janet_array_push(outer, janet_wrap_array(a));
    janet_array_push(outer, janet_wrap_array(a));
    b = marshalled(janet_wrap_array(outer), rreg, 0);
    CHECK_WIRE(b, "\xd1\x02\xd8\x08" "an-array" "\xda\x01");
}

/* ------------------------------------------------------- the environment API */

static Janet an_entry(const char *key, Janet value) {
    JanetTable *entry = janet_table(1);
    janet_table_put(entry, janet_ckeywordv(key), value);
    return janet_wrap_table(entry);
}

static void test_env_lookup_into_prefixes_and_recurses(void) {
    JanetTable *proto = janet_table(2);
    janet_table_put(proto, janet_csymbolv("inherited"), an_entry("value", janet_wrap_integer(1)));

    JanetTable *env = janet_table(4);
    env->proto = proto;
    janet_table_put(env, janet_csymbolv("plain"), an_entry("value", janet_wrap_integer(2)));
    janet_table_put(env, janet_csymbolv("by-ref"), an_entry("ref", janet_wrap_integer(3)));
    /* A struct entry is read the same way a table entry is. */
    JanetKV *st = janet_struct_begin(1);
    janet_struct_put(st, janet_ckeywordv("value"), janet_wrap_integer(4));
    janet_table_put(env, janet_csymbolv("from-struct"), janet_wrap_struct(janet_struct_end(st)));
    /* Anything else has no value at all, and a non-symbol key is skipped. */
    janet_table_put(env, janet_csymbolv("opaque"), janet_wrap_integer(99));
    janet_table_put(env, janet_ckeywordv("not-a-symbol"), an_entry("value", janet_wrap_integer(5)));

    JanetTable *flat = janet_table(0);
    janet_env_lookup_into(flat, env, NULL, 1);
    assert(janet_unwrap_integer(janet_table_get(flat, janet_csymbolv("plain"))) == 2);
    assert(janet_unwrap_integer(janet_table_get(flat, janet_csymbolv("by-ref"))) == 3);
    assert(janet_unwrap_integer(janet_table_get(flat, janet_csymbolv("from-struct"))) == 4);
    assert(janet_unwrap_integer(janet_table_get(flat, janet_csymbolv("inherited"))) == 1);
    assert(janet_checktype(janet_table_get(flat, janet_csymbolv("opaque")), JANET_NIL));
    assert(janet_checktype(janet_table_get(flat, janet_ckeywordv("not-a-symbol")), JANET_NIL));

    /* Without recursion the prototype is not walked. */
    JanetTable *shallow = janet_table(0);
    janet_env_lookup_into(shallow, env, NULL, 0);
    assert(janet_unwrap_integer(janet_table_get(shallow, janet_csymbolv("plain"))) == 2);
    assert(janet_checktype(janet_table_get(shallow, janet_csymbolv("inherited")), JANET_NIL));

    /* A prefix is prepended to the symbol, not to the entry. */
    JanetTable *prefixed = janet_table(0);
    janet_env_lookup_into(prefixed, env, "mod/", 1);
    assert(janet_unwrap_integer(janet_table_get(prefixed, janet_csymbolv("mod/plain"))) == 2);
    assert(janet_unwrap_integer(janet_table_get(prefixed, janet_csymbolv("mod/inherited"))) == 1);
    assert(janet_checktype(janet_table_get(prefixed, janet_csymbolv("plain")), JANET_NIL));

    /* An empty prefix is not the same code path as a null one, and gives the
     * same answer. */
    JanetTable *empty = janet_table(0);
    janet_env_lookup_into(empty, env, "", 1);
    assert(janet_unwrap_integer(janet_table_get(empty, janet_csymbolv("plain"))) == 2);

    /* `janet_env_lookup` is the recursive, unprefixed case with a fresh
     * table. */
    JanetTable *made = janet_env_lookup(env);
    assert(janet_unwrap_integer(janet_table_get(made, janet_csymbolv("inherited"))) == 1);
}

/* ------------------------------------------------------------ truncation */

/* Every read is bounds checked, and the check is what stops a corrupt stream
 * from reading past the buffer rather than merely producing a wrong value. */
static void test_a_truncated_stream_is_refused_at_every_length(void) {
    Probe *probe = make_probe();
    JanetArray *a = janet_array(2);
    janet_array_push(a, janet_wrap_abstract(probe));
    janet_array_push(a, janet_cstringv("tail"));
    JanetBuffer *whole = marshalled(janet_wrap_array(a), NULL, 0);

    for (int32_t len = 0; len < whole->count; len++) {
        JanetTryState state;
        janet_try_init(&state);
        janet_contract_arm();
        (void) janet_unmarshal(whole->data, (size_t) len, 0, NULL, NULL);
        int raised = janet_contract_raised();
        JanetSignal sig = janet_contract_signal();
        janet_restore(&state);
        if (!raised) {
            printf("prefix of %d bytes unmarshalled without error\n", len);
            assert(0 && "a truncated stream was accepted");
        }
        assert(sig == JANET_SIGNAL_ERROR);
    }
    /* The whole thing is fine. */
    assert(janet_checktype(unmarshalled(whole, 0), JANET_ARRAY));
}

static void test_the_diagnostics_name_a_byte_and_an_offset(void) {
    /* The byte is rendered by `%x`, which reads a 64-bit argument from a call
     * that passes a 32-bit one in the C original -- see `FOUND.md`. */
    EXPECT_PANIC(janet_unmarshal((const uint8_t *) "\xff", 1, 0, NULL, NULL),
                 "unknown byte ff at index 0");
    EXPECT_PANIC(janet_unmarshal((const uint8_t *) "\xd1\x01\xff", 3, 0, NULL, NULL),
                 "unknown byte ff at index 2");
    /* A lead byte in [192, 200) is not an integer encoding. */
    EXPECT_PANIC(janet_unmarshal((const uint8_t *) "\xd1\xc0", 2, 0, NULL, NULL),
                 "expected integer, got byte c0 at index 1");
    /* A count has to be a natural number. */
    EXPECT_PANIC(janet_unmarshal((const uint8_t *) "\xd1\xbf\xff", 3, 0, NULL, NULL),
                 "expected integer >= 0, got -1");
    EXPECT_PANIC(janet_unmarshal((const uint8_t *) "", 0, 0, NULL, NULL),
                 "unexpected end of source");
}

/* A struct's prototype has to be a struct and a table's a table, and the
 * message names the type set rather than the type. */
static void test_a_prototype_is_type_checked(void) {
    EXPECT_PANIC(janet_unmarshal((const uint8_t *) "\xdf\x00\x00", 3, 0, NULL, NULL),
                 "expected type struct, got 0");
    EXPECT_PANIC(janet_unmarshal((const uint8_t *) "\xd4\x00\x00", 3, 0, NULL, NULL),
                 "expected type table, got 0");
}

/* ----------------------------------------------------------------- fibers */

/* A fiber is only ALIVE while it is running, so the refusal can only be
 * provoked from inside one. */
static void test_a_live_fiber_cannot_be_marshalled(void) {
    Janet out;
    assert(!janet_dostring(test_env, "(fn [] (marshal (fiber/current)))", "marsh-test", &out));
    janet_gcroot(out);
    Janet result = janet_wrap_nil();
    JanetFiber *fiber = NULL;
    JanetSignal sig = janet_pcall(janet_unwrap_function(out), 0, NULL, &result, &fiber);
    assert(sig == JANET_SIGNAL_ERROR);
    assert(janet_checktype(result, JANET_STRING));
    assert(!janet_cstrcmp(janet_unwrap_string(result), "cannot marshal alive fiber"));
    janet_gcunroot(out);

    /* A suspended one round-trips, and the reader checks the frame arithmetic
     * the writer produced. */
    assert(!janet_dostring(test_env, "(fiber/new (fn [] (yield 1) 2))", "marsh-test", &out));
    janet_gcroot(out);
    JanetBuffer *b = marshalled(out, NULL, 0);
    assert(b->data[0] == 204 /* LB_FIBER */);
    assert(janet_checktype(unmarshalled(b, 0), JANET_FIBER));
    janet_gcunroot(out);

    EXPECT_PANIC(janet_unmarshal((const uint8_t *) "\xcc\x00\x01\x00\x00\x00", 6, 0, NULL, NULL),
                 "fiber has incorrect stack setup");
    /* A status field of 16 is one past `JANET_STATUS_ALIVE` and still inside
     * the six-bit status mask, so it survives every other check. */
    EXPECT_PANIC(janet_unmarshal(
                     (const uint8_t *) "\xcc\xcd\x00\x10\x00\x00\x00\x04\x04\x04\xc9",
                     11, 0, NULL, NULL),
                 "invalid fiber status");
}

/* -------------------------------------------------- what `next` reports */

/* `cfun_unmarshal` drops the out-parameter, so this is the only caller that
 * can see where a value ended -- which is what makes a stream of concatenated
 * values readable at all. */
static void test_next_points_past_the_value(void) {
    JanetBuffer *b = janet_buffer(16);
    janet_marshal(b, janet_wrap_integer(1), NULL, 0);
    int32_t first = b->count;
    janet_marshal(b, janet_cstringv("second"), NULL, 0);

    const uint8_t *next = NULL;
    Janet one = janet_unmarshal(b->data, (size_t) b->count, 0, NULL, &next);
    assert(janet_unwrap_integer(one) == 1);
    assert(next == b->data + first);

    Janet two = janet_unmarshal(next, (size_t)(b->count - first), 0, NULL, &next);
    assert(janet_cstrcmp(janet_unwrap_string(two), "second") == 0);
    assert(next == b->data + b->count);
}

/* ------------------------------------------------------------------- main */

void marsh_contract(void) {
    janet_init();
    test_env = janet_core_env(NULL);
    janet_gcroot(janet_wrap_table(test_env));
    janet_register_abstract_type(CONTRACT_AT(probe_type));
    janet_register_abstract_type(CONTRACT_AT(refuser_type));
    janet_register_abstract_type(CONTRACT_AT(twice_type));
    janet_register_abstract_type(CONTRACT_AT(never_type));
    janet_register_abstract_type(CONTRACT_AT(threaded_type));
    janet_register_abstract_type(CONTRACT_AT(inert_type));
    janet_register_abstract_type(CONTRACT_AT(toobig_type));

    test_the_three_integer_encodings();
    test_reals_and_integral_doubles_differ();
    test_the_size_encoding_boundaries();
    test_the_context_api_round_trips();
    test_an_abstract_can_contain_itself();
    test_the_abstract_protocol_is_enforced();
    test_the_unsafe_gate_on_the_context_api();
    test_pointers_and_cfunctions_need_the_unsafe_flag();
    test_the_weak_lead_bytes_move_with_the_event_loop();
    test_when_a_value_becomes_a_reference();
    test_a_reference_index_is_bounds_checked();
    test_function_streams_and_their_back_references();
    test_the_reverse_registry_short_circuits();
    test_env_lookup_into_prefixes_and_recurses();
    test_a_truncated_stream_is_refused_at_every_length();
    test_the_diagnostics_name_a_byte_and_an_offset();
    test_a_prototype_is_type_checked();
    test_a_live_fiber_cannot_be_marshalled();
    test_next_points_past_the_value();

    assert(panics_fired == EXPECTED_PANICS);

    janet_deinit();
    printf("marsh contract ok\n");
}
