/* Behavioral contract for `janet_next` and the indexed and keyed accessors.
 * Run against whichever implementation the build selected
 * (`-Dvalue-access=c` or the Zig default).
 *
 * Nine functions, and the reason they are one contract is that they disagree
 * with each other on purpose. `janet_in`, `janet_get` and `janet_getindex`
 * answer the same question about the same value and differ only in what a
 * failure is -- a panic, a nil, or a panic for one kind of failure and a nil
 * for another. Testing any one of them in isolation would pin a policy without
 * pinning the differences between the three policies, and the differences are
 * the part a port gets wrong. So the sections below run the same failing input
 * through all three and assert each answer against the others.
 *
 * Three properties get more attention than their size suggests.
 *
 * **The panic messages are the ABI test.** This is the first Zig subsystem to
 * call `janet_panicf` through the C variadic ABI, and `%v` puts a `Janet` --
 * an eight-byte union under nanboxing, a sixteen-byte struct under
 * `-Dnanbox=false` -- through `...`. `%T` puts a type-flag mask through as an
 * `int`, `%u` puts a `size_t` through as a `uint64_t`, and `%d` puts an
 * `int32_t` through. Every one of those is a place where an ABI mismatch would
 * produce a plausible-looking wrong message rather than a crash, so every
 * message here is compared byte for byte rather than merely being expected to
 * appear.
 *
 * **The two length bounds are not the same bound.** `janet_length` rejects an
 * abstract length above `INT32_MAX` and `janet_lengthv` rejects one at or
 * above `JANET_INTMAX_INT64`, so there is a wide band in which one panics and
 * the other succeeds. An implementation that used one bound for both would
 * pass every test that did not look in that band.
 *
 * **`janet_next` on a fiber has two error policies and they are chosen by an
 * argument.** `janet_next_impl`'s `is_interpreter` flag decides whether a
 * signal from the resumed fiber is re-raised as that signal or converted to a
 * panic, and it decides whether `janet_vm.fiber->child` is cleared first. No
 * in-tree caller passes zero -- the VM always passes one -- so the whole
 * `janet_next` entry point is reachable only from C, and it is tested here
 * through a cfunction registered for the purpose.
 *
 * What is deliberately not covered: three undefined-behaviour edges.
 * `(next "abc" 2147483647)` and `janet_putindex` at
 * `INT32_MAX` are signed overflow, and `janet_next` on a fiber from outside a
 * running fiber is a null dereference. All three are in `FOUND.md`, and the
 * first two abort the C selector under its sanitizer while the Zig selector
 * carries the wrap out, so no assertion here can hold for both. The probe is
 * where that asymmetry is recorded.
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
#include "util.h"

/* ------------------------------------------------------------------ helpers */

/* Every panic this file expects is counted, because a case that silently
 * stopped panicking would otherwise look exactly like one that passed. Fixed
 * rather than a floor, and verified against -Dvalue-access=c first. */
static int panics_fired = 0;
#define EXPECTED_PANICS 49

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

/* An abstract value renders with its address, so those messages are compared
 * by prefix. Everything else is compared whole. */
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
        const uint8_t *_m = janet_unwrap_string(_state.payload); \
        if (strncmp((const char *) _m, (prefix), strlen(prefix))) { \
            printf("expected prefix: %s\n            got: %s\n", (prefix), (const char *) _m); \
            assert(0 && "message prefix mismatch"); \
        } \
    } \
    panics_fired++; \
} while (0)

#define EXPECT_NO_PANIC(expr) do { \
    JanetTryState _state; \
    int _raised = 0; \
    JanetSignal _sig = JANET_SIGNAL_OK; \
    janet_try_init(&_state); \
    janet_contract_arm(); \
    (void)(expr); \
    _raised = janet_contract_raised(); \
    if (_raised) _sig = janet_contract_signal(); \
    janet_restore(&_state); \
    assert(!_raised && "expected a return, got a panic"); \
} while (0)

static Janet kw(const char *name) {
    return janet_ckeywordv(name);
}

static Janet intv(int32_t i) {
    return janet_wrap_integer(i);
}

static int is_nil(Janet x) {
    return janet_checktype(x, JANET_NIL);
}

/* ------------------------------------------------------- abstract fixtures */

/* Three integer slots, addressed by integer keys, with every callback the
 * accessors reach. `next` walks 0, 1, 2 and stops. */
typedef struct {
    int32_t slot[3];
} slots;

static int slots_get(void *p, Janet key, Janet *out) {
    slots *s = (slots *) p;
    if (!janet_checkint(key)) return 0;
    int32_t i = janet_unwrap_integer(key);
    if (i < 0 || i > 2) return 0;
    *out = janet_wrap_integer(s->slot[i]);
    return 1;
}

static void slots_put(void *p, Janet key, Janet value) {
    slots *s = (slots *) p;
    if (!janet_checkint(key)) janet_panic("slots: bad key");
    int32_t i = janet_unwrap_integer(key);
    if (i < 0 || i > 2) janet_panic("slots: key out of range");
    s->slot[i] = janet_unwrap_integer(value);
}

static Janet slots_next(void *p, Janet key) {
    (void) p;
    if (janet_checktype(key, JANET_NIL)) return janet_wrap_integer(0);
    int32_t i = janet_unwrap_integer(key) + 1;
    return i < 3 ? janet_wrap_integer(i) : janet_wrap_nil();
}

static size_t slots_length(void *p, size_t len) {
    (void) p;
    (void) len;
    return 3;
}

static const JanetAbstractType slots_type = {
    .name = "value-access/slots",
    .get = slots_get,
    .put = slots_put,
    .next = slots_next,
    .length = slots_length
};

/* No callbacks at all: the type every "no getter", "no setter" and "no next"
 * arm is written for. */
static const JanetAbstractType bare_type = {
    .name = "value-access/bare"
};

/* Two lengths chosen to straddle the two different bounds. */
static size_t big_length(void *p, size_t len) {
    (void) p;
    (void) len;
    return (size_t) 2147483648u;          /* INT32_MAX + 1 */
}

static size_t huge_length(void *p, size_t len) {
    (void) p;
    (void) len;
    return (size_t) 9007199254740992ull;  /* JANET_INTMAX_INT64 */
}

static const JanetAbstractType big_type = {
    .name = "value-access/big",
    .length = big_length
};

static const JanetAbstractType huge_type = {
    .name = "value-access/huge",
    .length = huge_length
};

/* A type with no `length` callback but a `:length` method, which is the other
 * half of `janet_length`'s abstract arm. The method is found through
 * `janet_get` -- one of the functions under test -- so this arm re-enters the
 * file it is testing. */
static Janet method_seven(int32_t argc, Janet *argv) {
    (void) argc;
    (void) argv;
    return janet_wrap_integer(7);
}

static Janet method_keyword(int32_t argc, Janet *argv) {
    (void) argc;
    (void) argv;
    return janet_ckeywordv("not-a-number");
}

static int good_method_get(void *p, Janet key, Janet *out) {
    (void) p;
    if (!janet_keyeq(key, "length")) return 0;
    *out = janet_wrap_cfunction(janet_contract_cfunction(method_seven));
    return 1;
}

static int bad_method_get(void *p, Janet key, Janet *out) {
    (void) p;
    if (!janet_keyeq(key, "length")) return 0;
    *out = janet_wrap_cfunction(janet_contract_cfunction(method_keyword));
    return 1;
}

static const JanetAbstractType good_method_type = {
    .name = "value-access/good-method",
    .get = good_method_get
};

static const JanetAbstractType bad_method_type = {
    .name = "value-access/bad-method",
    .get = bad_method_get
};

static Janet slots_value;
static Janet bare_value;
static Janet big_value;
static Janet huge_value;
static Janet good_method_value;
static Janet bad_method_value;

static void make_abstracts(void) {
    slots *s = janet_abstract(CONTRACT_AT(slots_type), sizeof(slots));
    s->slot[0] = 10;
    s->slot[1] = 11;
    s->slot[2] = 12;
    slots_value = janet_wrap_abstract(s);
    bare_value = janet_wrap_abstract(janet_abstract(CONTRACT_AT(bare_type), 8));
    big_value = janet_wrap_abstract(janet_abstract(CONTRACT_AT(big_type), 8));
    huge_value = janet_wrap_abstract(janet_abstract(CONTRACT_AT(huge_type), 8));
    good_method_value = janet_wrap_abstract(janet_abstract(CONTRACT_AT(good_method_type), 8));
    bad_method_value = janet_wrap_abstract(janet_abstract(CONTRACT_AT(bad_method_type), 8));
    janet_gcroot(slots_value);
    janet_gcroot(bare_value);
    janet_gcroot(big_value);
    janet_gcroot(huge_value);
    janet_gcroot(good_method_value);
    janet_gcroot(bad_method_value);
}

/* ------------------------------------------------------------ next: tables */

/* The property that matters is completeness, not the order: starting from nil
 * and following `next` has to visit every key exactly once and then stop. A
 * bucket walk that skipped an occupied slot, or that restarted, would still
 * return plausible keys. */
static void test_next_visits_every_table_key_once(void) {
    JanetTable *t = janet_table(0);
    const int n = 64;
    for (int i = 0; i < n; i++) {
        janet_table_put(t, intv(i), intv(i * 100));
    }
    int seen[64];
    memset(seen, 0, sizeof seen);
    int count = 0;
    Janet k = janet_next(janet_wrap_table(t), janet_wrap_nil());
    while (!is_nil(k)) {
        assert(janet_checkint(k));
        int32_t i = janet_unwrap_integer(k);
        assert(i >= 0 && i < n);
        assert(!seen[i] && "a key was visited twice");
        seen[i] = 1;
        count++;
        assert(count <= n);
        k = janet_next(janet_wrap_table(t), k);
    }
    assert(count == n);
}

/* Removing a key leaves a tombstone -- a bucket whose key is nil and whose
 * value is not -- and the walk has to step over it like any other empty
 * bucket rather than stopping at it. */
static void test_next_steps_over_tombstones(void) {
    JanetTable *t = janet_table(0);
    for (int i = 0; i < 16; i++) janet_table_put(t, intv(i), intv(i));
    for (int i = 0; i < 16; i += 2) janet_table_remove(t, intv(i));
    int count = 0;
    Janet k = janet_next(janet_wrap_table(t), janet_wrap_nil());
    while (!is_nil(k)) {
        assert(janet_unwrap_integer(k) % 2 == 1);
        count++;
        assert(count <= 8);
        k = janet_next(janet_wrap_table(t), k);
    }
    assert(count == 8);
}

static void test_next_visits_every_struct_key_once(void) {
    JanetKV *st = janet_struct_begin(20);
    for (int i = 0; i < 20; i++) janet_struct_put(st, intv(i), intv(i));
    Janet s = janet_wrap_struct(janet_struct_end(st));
    int seen[20];
    memset(seen, 0, sizeof seen);
    int count = 0;
    Janet k = janet_next(s, janet_wrap_nil());
    while (!is_nil(k)) {
        int32_t i = janet_unwrap_integer(k);
        assert(i >= 0 && i < 20);
        assert(!seen[i]);
        seen[i] = 1;
        count++;
        assert(count <= 20);
        k = janet_next(s, k);
    }
    assert(count == 20);
}

/* Iteration reads the bucket array and nothing else, so a prototype's keys are
 * not visited even though `janet_in` finds them. The two disagree, and that is
 * established behaviour rather than an accident: `(each k s ...)` over a
 * struct with a prototype sees only the struct's own keys. */
static void test_next_does_not_follow_a_struct_prototype(void) {
    JanetKV *pst = janet_struct_begin(1);
    janet_struct_put(pst, kw("inherited"), intv(1));
    JanetStruct proto = janet_struct_end(pst);

    JanetKV *st = janet_struct_begin(1);
    janet_struct_put(st, kw("own"), intv(2));
    janet_struct_proto(st) = proto;
    Janet s = janet_wrap_struct(janet_struct_end(st));

    Janet k = janet_next(s, janet_wrap_nil());
    assert(janet_equals(k, kw("own")));
    assert(is_nil(janet_next(s, k)));

    /* ...but the key is reachable through every accessor. */
    assert(janet_equals(janet_in(s, kw("inherited")), intv(1)));
    assert(janet_equals(janet_get(s, kw("inherited")), intv(1)));
}

/* A table's prototype behaves the same way, and for the same reason. */
static void test_next_does_not_follow_a_table_prototype(void) {
    JanetTable *proto = janet_table(0);
    janet_table_put(proto, kw("inherited"), intv(1));
    JanetTable *t = janet_table(0);
    janet_table_put(t, kw("own"), intv(2));
    t->proto = proto;

    Janet k = janet_next(janet_wrap_table(t), janet_wrap_nil());
    assert(janet_equals(k, kw("own")));
    assert(is_nil(janet_next(janet_wrap_table(t), k)));
    assert(janet_equals(janet_in(janet_wrap_table(t), kw("inherited")), intv(1)));
}

/* An empty dictionary answers nil to the first step rather than walking off
 * the end of a zero-length bucket array. */
static void test_next_over_empty_dictionaries(void) {
    assert(is_nil(janet_next(janet_wrap_table(janet_table(0)), janet_wrap_nil())));
    Janet empty = janet_wrap_struct(janet_struct_end(janet_struct_begin(0)));
    assert(is_nil(janet_next(empty, janet_wrap_nil())));
}

/* -------------------------------------------------------- next: sequences */

static void test_next_over_each_sequence_type(void) {
    Janet seqs[6];
    seqs[0] = janet_cstringv("abc");
    seqs[1] = janet_csymbolv("abc");
    seqs[2] = kw("abc");
    JanetBuffer *b = janet_buffer(4);
    janet_buffer_push_cstring(b, "abc");
    seqs[3] = janet_wrap_buffer(b);
    JanetArray *a = janet_array(4);
    for (int i = 0; i < 3; i++) janet_array_push(a, intv(i));
    seqs[4] = janet_wrap_array(a);
    Janet *t = janet_tuple_begin(3);
    for (int i = 0; i < 3; i++) t[i] = intv(i);
    seqs[5] = janet_wrap_tuple(janet_tuple_end(t));

    for (int i = 0; i < 6; i++) {
        Janet k = janet_next(seqs[i], janet_wrap_nil());
        assert(janet_equals(k, intv(0)));
        k = janet_next(seqs[i], k);
        assert(janet_equals(k, intv(1)));
        k = janet_next(seqs[i], k);
        assert(janet_equals(k, intv(2)));
        assert(is_nil(janet_next(seqs[i], k)));
    }
}

/* A key that is not an integer is not an error here: iteration simply stops.
 * That is the opposite of what `janet_in` does with the same key on the same
 * value, which is what makes it worth pinning. */
static void test_next_stops_rather_than_panicking_on_a_bad_key(void) {
    Janet s = janet_cstringv("abc");
    assert(is_nil(janet_next(s, kw("x"))));
    assert(is_nil(janet_next(s, janet_wrap_number(1.5))));
    assert(is_nil(janet_next(s, janet_wrap_true())));
    EXPECT_PANIC(janet_in(s, kw("x")),
                 "expected integer key for string in range [0, 3), got :x");
}

/* A negative key advances to a still-negative index, which the range test
 * rejects. Both halves of that test are load-bearing: `i < len` alone would
 * accept it. */
static void test_next_from_a_negative_key(void) {
    Janet s = janet_cstringv("abc");
    assert(is_nil(janet_next(s, intv(-5))));
    /* -1 advances to 0, which is in range. */
    assert(janet_equals(janet_next(s, intv(-1)), intv(0)));
}

static void test_next_past_the_end(void) {
    Janet s = janet_cstringv("abc");
    assert(is_nil(janet_next(s, intv(2))));
    assert(is_nil(janet_next(s, intv(99))));
    assert(is_nil(janet_next(janet_cstringv(""), janet_wrap_nil())));
}

/* ------------------------------------------------------- next: the rest */

static void test_next_on_an_abstract(void) {
    Janet k = janet_next(slots_value, janet_wrap_nil());
    assert(janet_equals(k, intv(0)));
    k = janet_next(slots_value, k);
    assert(janet_equals(k, intv(1)));
    k = janet_next(slots_value, k);
    assert(janet_equals(k, intv(2)));
    assert(is_nil(janet_next(slots_value, k)));

    /* No `next` callback is not an error, it is an empty iteration. */
    assert(is_nil(janet_next(bare_value, janet_wrap_nil())));
}

static void test_next_on_a_non_iterable_panics(void) {
    EXPECT_PANIC(janet_next(intv(5), janet_wrap_nil()),
                 "expected iterable type, got 5");
    EXPECT_PANIC(janet_next(janet_wrap_nil(), janet_wrap_nil()),
                 "expected iterable type, got nil");
    EXPECT_PANIC(janet_next(janet_wrap_true(), janet_wrap_nil()),
                 "expected iterable type, got true");
    EXPECT_PANIC_PREFIX(janet_next(janet_wrap_cfunction(janet_contract_cfunction(method_seven)), janet_wrap_nil()),
                        "expected iterable type, got <cfunction ");
}

/* ---------------------------------------------------------- next: fibers */

/* `janet_next` writes `janet_vm.fiber->child` before resuming, so every fiber
 * case has to run with a fiber on the VM. These cfunctions are how: they are
 * called from Janet source, so `janet_vm.fiber` is the fiber running that
 * source. `FOUND.md` has what happens without one. */

static Janet cfun_next(int32_t argc, Janet *argv) {
    janet_fixarity(argc, 2);
    return janet_next(argv[0], argv[1]);
}

/* Resume through `janet_next` and report whether the caller's `child` slot was
 * put back to null afterwards. A slot left set keeps the child fiber reachable
 * and misreports the fiber chain, and nothing else observes it. */
static Janet cfun_next_child_cleared(int32_t argc, Janet *argv) {
    janet_fixarity(argc, 2);
    JanetFiber *self = janet_vm.fiber;
    (void) janet_next(argv[0], argv[1]);
    return janet_wrap_boolean(self->child == NULL);
}

/* The same, for the path that leaves through `janet_panicv`. The C clears the
 * slot before panicking there and deliberately does not on the interpreter's
 * path, which is the one asymmetry in the function. */
static Janet cfun_next_child_cleared_on_panic(int32_t argc, Janet *argv) {
    janet_fixarity(argc, 2);
    JanetFiber *self = janet_vm.fiber;
    JanetTryState state;
    janet_try_init(&state);
    janet_contract_arm();
    (void) janet_next(argv[0], argv[1]);
    int raised = janet_contract_raised();
    janet_restore(&state);
    if (!raised) return janet_wrap_nil();   /* did not panic; the caller asserts */
    return janet_wrap_boolean(self->child == NULL);
}

static JanetReg cfuns[] = {
    {"va/next", cfun_next, NULL},
    {"va/next-child-cleared", cfun_next_child_cleared, NULL},
    {"va/next-child-cleared-on-panic", cfun_next_child_cleared_on_panic, NULL},
    {NULL, NULL, NULL}
};

static Janet run(const char *src) {
    Janet out;
    int status = janet_dostring(janet_core_env(NULL), src, "value_access", &out);
    if (status) {
        printf("janet source failed: %s\n", src);
        assert(0 && "janet source failed");
    }
    return out;
}

/* Iterating a fiber runs it, and the key it yields is always the integer zero
 * -- a fiber has no index. The value comes back through `janet_in`, which is
 * the whole reason the accessors have a `JANET_FIBER` arm at all. */
static void test_next_resumes_a_fiber(void) {
    Janet r = run("(def f (fiber/new (fn [] (yield :a) (yield :b) :done)))"
                  "[(next f nil) (in f 0)"
                  " (next f 0)   (in f 0)"
                  " (next f 0)   (fiber/status f)"
                  " (next f 0)]");
    const Janet *v = janet_unwrap_tuple(r);
    assert(janet_equals(v[0], intv(0)));
    assert(janet_equals(v[1], kw("a")));
    assert(janet_equals(v[2], intv(0)));
    assert(janet_equals(v[3], kw("b")));
    /* The resume that finishes the fiber discards the return value and stops. */
    assert(is_nil(v[4]));
    assert(janet_equals(v[5], kw("dead")));
    /* A dead fiber answers nil without being resumed. */
    assert(is_nil(v[6]));
}

/* `janet_next` -- the entry point with `is_interpreter` clear -- has no
 * in-tree caller, so this is the only exercise it gets. It agrees with the
 * interpreter's path everywhere except on a signal. */
static void test_janet_next_entry_point_on_a_fiber(void) {
    janet_contract_adapt_regs(cfuns);
    janet_cfuns(janet_core_env(NULL), NULL, cfuns);
    Janet r = run("(def f (fiber/new (fn [] (yield :a) :done)))"
                  "[(va/next f nil) (in f 0) (va/next f 0) (va/next f 0)]");
    const Janet *v = janet_unwrap_tuple(r);
    assert(janet_equals(v[0], intv(0)));
    assert(janet_equals(v[1], kw("a")));
    assert(is_nil(v[2]));
    assert(is_nil(v[3]));
}

/* Every status that cannot be resumed answers nil without touching the fiber.
 * `:new` and `:pending` are the two that can, and the list below is the
 * complement of those two. */
static void test_next_on_an_unresumable_fiber(void) {
    /* One form, because `(fiber/current)` has to be read and used inside the
     * same fiber -- `janet_dostring` runs each top-level form in its own. */
    Janet r = run("(do"
                  " (def dead (fiber/new (fn [] 1))) (resume dead)"
                  " (def errd (fiber/new (fn [] (error :x)) :e)) (resume errd)"
                  " (def alive (fiber/current))"
                  " (def user (fiber/new (fn [] (signal 3 :s)) :3)) (resume user)"
                  " [(fiber/status dead)  (next dead nil)"
                  "  (fiber/status errd)  (next errd nil)"
                  "  (fiber/status alive) (next alive nil)"
                  "  (fiber/status user)  (next user nil)])");
    const Janet *v = janet_unwrap_tuple(r);
    assert(janet_equals(v[0], kw("dead")));
    assert(is_nil(v[1]));
    assert(janet_equals(v[2], kw("error")));
    assert(is_nil(v[3]));
    assert(janet_equals(v[4], kw("alive")));
    assert(is_nil(v[5]));
    assert(janet_equals(v[6], kw("user3")));
    assert(is_nil(v[7]));
}

/* The `is_interpreter` asymmetry, which is the only thing the two entry points
 * disagree about. A signal the resumed fiber raises and does not trap reaches
 * the caller as that same signal through `janet_next_impl(..., 1)`, and as a
 * plain error through `janet_next_impl(..., 0)`. The payload survives either
 * way, so the status is the only thing that distinguishes them. */
static void test_the_interpreter_flag_chooses_the_error_policy(void) {
    Janet r = run("(def mk (fn [] (fiber/new (fn [] (signal 5 :sig)))))"
                  "(def viaint (fiber/new (fn [] (next (mk) nil)) :5))"
                  "(def viacapi (fiber/new (fn [] (va/next (mk) nil)) :5e))"
                  "[(resume viaint)  (fiber/status viaint)"
                  " (resume viacapi) (fiber/status viacapi)]");
    const Janet *v = janet_unwrap_tuple(r);
    assert(janet_equals(v[0], kw("sig")));
    assert(janet_equals(v[1], kw("user5")));
    assert(janet_equals(v[2], kw("sig")));
    assert(janet_equals(v[3], kw("error")));
}

static void test_the_child_slot_is_cleared(void) {
    Janet r = run("(def ok (fiber/new (fn [] (yield :a) :done)))"
                  "(def bad (fiber/new (fn [] (error :boom))))"
                  "[(va/next-child-cleared ok nil)"
                  " (va/next-child-cleared-on-panic bad nil)]");
    const Janet *v = janet_unwrap_tuple(r);
    assert(janet_truthy(v[0]) && "child not cleared after a successful resume");
    assert(janet_checktype(v[1], JANET_BOOLEAN) && "the failing resume did not panic");
    assert(janet_truthy(v[1]) && "child not cleared before janet_panicv");
}

/* Resuming through `next` links the child into the caller's fiber chain
 * before it runs, and that link is what `debug/lineage` walks -- and, through
 * the same chain, what puts the resumed fiber's frames into a stack trace. The
 * link is only observable while the child is running, so the child observes it
 * itself. */
static void test_the_resumed_fiber_joins_the_lineage(void) {
    Janet r = run("(do"
                  " (def log @[])"
                  " (var outer nil)"
                  " (def child (fiber/new (fn []"
                  "   (array/push log (length (debug/lineage outer)))"
                  "   (yield 1))))"
                  " (set outer (fiber/new (fn [] (next child nil))))"
                  " (resume outer)"
                  " log)");
    JanetArray *log = janet_unwrap_array(r);
    assert(log->count == 1);
    assert(janet_unwrap_integer(log->data[0]) == 2 &&
           "the resumed fiber was not linked into the caller's chain");
}

/* ------------------------------------------------------------- janet_in */

static void test_in_reads_every_container(void) {
    JanetArray *a = janet_array(2);
    janet_array_push(a, kw("x"));
    janet_array_push(a, kw("y"));
    assert(janet_equals(janet_in(janet_wrap_array(a), intv(1)), kw("y")));

    Janet *t = janet_tuple_begin(2);
    t[0] = kw("x");
    t[1] = kw("y");
    Janet tup = janet_wrap_tuple(janet_tuple_end(t));
    assert(janet_equals(janet_in(tup, intv(0)), kw("x")));

    JanetBuffer *b = janet_buffer(4);
    janet_buffer_push_cstring(b, "AB");
    assert(janet_equals(janet_in(janet_wrap_buffer(b), intv(1)), intv('B')));

    assert(janet_equals(janet_in(janet_cstringv("AB"), intv(0)), intv('A')));
    assert(janet_equals(janet_in(janet_csymbolv("AB"), intv(1)), intv('B')));
    assert(janet_equals(janet_in(kw("AB"), intv(0)), intv('A')));

    JanetTable *tab = janet_table(0);
    janet_table_put(tab, kw("k"), intv(3));
    assert(janet_equals(janet_in(janet_wrap_table(tab), kw("k")), intv(3)));

    JanetKV *st = janet_struct_begin(1);
    janet_struct_put(st, kw("k"), intv(4));
    assert(janet_equals(janet_in(janet_wrap_struct(janet_struct_end(st)), kw("k")), intv(4)));

    assert(janet_equals(janet_in(slots_value, intv(2)), intv(12)));
}

/* A key that is merely absent from a dictionary is nil, not an error. The
 * panic in `janet_in` is about keys that are wrong for the container, and a
 * dictionary accepts every key. */
static void test_in_on_a_missing_dictionary_key_is_nil(void) {
    JanetTable *tab = janet_table(0);
    assert(is_nil(janet_in(janet_wrap_table(tab), kw("nope"))));
    Janet st = janet_wrap_struct(janet_struct_end(janet_struct_begin(0)));
    assert(is_nil(janet_in(st, kw("nope"))));
    /* Including keys no sequence would accept. */
    assert(is_nil(janet_in(janet_wrap_table(tab), janet_wrap_number(1.5))));
}

/* One message, four ways to earn it, and it names the container's type and
 * the exclusive upper bound. Every sequence type is checked because the type
 * name comes out of `janet_type_names` and a wrong index there would still
 * produce a well-formed message. */
static void test_in_panics_on_a_bad_key(void) {
    JanetArray *a = janet_array(1);
    janet_array_push(a, intv(0));
    Janet arr = janet_wrap_array(a);
    EXPECT_PANIC(janet_in(arr, kw("x")),
                 "expected integer key for array in range [0, 1), got :x");
    EXPECT_PANIC(janet_in(arr, intv(1)),
                 "expected integer key for array in range [0, 1), got 1");
    EXPECT_PANIC(janet_in(arr, intv(-1)),
                 "expected integer key for array in range [0, 1), got -1");
    EXPECT_PANIC(janet_in(arr, janet_wrap_number(0.5)),
                 "expected integer key for array in range [0, 1), got 0.5");

    Janet *t = janet_tuple_begin(1);
    t[0] = intv(0);
    EXPECT_PANIC(janet_in(janet_wrap_tuple(janet_tuple_end(t)), intv(3)),
                 "expected integer key for tuple in range [0, 1), got 3");
    EXPECT_PANIC(janet_in(janet_wrap_buffer(janet_buffer(4)), intv(0)),
                 "expected integer key for buffer in range [0, 0), got 0");
    EXPECT_PANIC(janet_in(janet_cstringv("abc"), intv(9)),
                 "expected integer key for string in range [0, 3), got 9");
    EXPECT_PANIC(janet_in(janet_csymbolv("abc"), intv(9)),
                 "expected integer key for symbol in range [0, 3), got 9");
    EXPECT_PANIC(janet_in(kw("abc"), intv(9)),
                 "expected integer key for keyword in range [0, 3), got 9");
}

/* The `%T` message, which renders a type-flag mask rather than a value. Two
 * different masks appear in this file and they have to stay different. */
static void test_in_on_a_non_lengthable_panics(void) {
    const char *msg = "expected string, symbol, keyword, array, tuple, "
                      "table, struct or buffer, got ";
    EXPECT_PANIC(janet_in(intv(5), intv(0)), "expected string, symbol, keyword, "
                 "array, tuple, table, struct or buffer, got 5");
    EXPECT_PANIC(janet_in(janet_wrap_nil(), intv(0)), "expected string, symbol, keyword, "
                 "array, tuple, table, struct or buffer, got nil");
    EXPECT_PANIC(janet_in(janet_wrap_true(), intv(0)), "expected string, symbol, keyword, "
                 "array, tuple, table, struct or buffer, got true");
    EXPECT_PANIC_PREFIX(janet_in(janet_wrap_cfunction(janet_contract_cfunction(method_seven)), intv(0)), msg);
}

/* An abstract type is the one place where a key that is simply absent is an
 * error, because its `get` reports presence separately from the value. */
static void test_in_on_an_abstract(void) {
    assert(janet_equals(janet_in(slots_value, intv(0)), intv(10)));
    EXPECT_PANIC_PREFIX(janet_in(slots_value, intv(7)), "key 7 not found in <value-access/slots ");
    EXPECT_PANIC_PREFIX(janet_in(slots_value, kw("nope")), "key :nope not found in <value-access/slots ");
    EXPECT_PANIC_PREFIX(janet_in(bare_value, intv(0)), "no getter for <value-access/bare ");
}

static void test_in_on_a_fiber(void) {
    Janet r = run("(def f (fiber/new (fn [] (yield :a) :done)))"
                  "(next f nil)"
                  "[(in f 0) (get f 0) (get f 1) (protect (in f 1))]");
    const Janet *v = janet_unwrap_tuple(r);
    assert(janet_equals(v[0], kw("a")));
    assert(janet_equals(v[1], kw("a")));
    assert(is_nil(v[2]));
    /* `protect` returns [false message] for a caught error. */
    const Janet *p = janet_unwrap_tuple(v[3]);
    assert(!janet_truthy(p[0]));
    assert(janet_equals(p[1], janet_cstringv("expected key 0, got 1")));
}

/* ------------------------------------------------------------ janet_get */

/* Everything `janet_in` panics about, `janet_get` answers nil to -- including
 * the container type itself, which is why `janet_get` accepts a number as a
 * data structure and `janet_in` does not. */
static void test_get_answers_nil_where_in_panics(void) {
    JanetArray *a = janet_array(1);
    janet_array_push(a, intv(0));
    Janet arr = janet_wrap_array(a);
    assert(is_nil(janet_get(arr, kw("x"))));
    assert(is_nil(janet_get(arr, intv(1))));
    assert(is_nil(janet_get(arr, intv(-1))));
    assert(is_nil(janet_get(arr, janet_wrap_number(0.5))));
    assert(is_nil(janet_get(janet_cstringv("abc"), intv(9))));
    /* The string arm has its own negative-index test, separate from the one
     * the array, tuple and buffer arm shares, and both have to be there: an
     * index below zero is not "past the end" and the length test alone lets
     * it through. */
    assert(is_nil(janet_get(janet_cstringv("abc"), intv(-1))));
    assert(is_nil(janet_get(janet_csymbolv("abc"), intv(-1))));
    assert(is_nil(janet_get(kw("abc"), intv(-1))));
    assert(is_nil(janet_get(janet_wrap_tuple(janet_tuple_end(janet_tuple_begin(0))), intv(-1))));
    assert(is_nil(janet_get(janet_wrap_buffer(janet_buffer(4)), intv(0))));
    assert(is_nil(janet_get(intv(5), intv(0))));
    assert(is_nil(janet_get(janet_wrap_nil(), intv(0))));
    assert(is_nil(janet_get(janet_wrap_true(), kw("x"))));
    assert(is_nil(janet_get(bare_value, intv(0))));
    assert(is_nil(janet_get(slots_value, intv(7))));
    assert(is_nil(janet_get(janet_wrap_cfunction(janet_contract_cfunction(method_seven)), intv(0))));
}

/* ...and where both succeed they agree. */
static void test_get_agrees_with_in_where_both_succeed(void) {
    JanetArray *a = janet_array(2);
    janet_array_push(a, kw("x"));
    janet_array_push(a, kw("y"));
    Janet *t = janet_tuple_begin(1);
    t[0] = kw("t");
    JanetBuffer *b = janet_buffer(4);
    janet_buffer_push_cstring(b, "AB");
    JanetTable *tab = janet_table(0);
    janet_table_put(tab, kw("k"), intv(3));
    JanetKV *st = janet_struct_begin(1);
    janet_struct_put(st, kw("k"), intv(4));

    Janet pairs[7][2] = {
        { janet_wrap_array(a), intv(1) },
        { janet_wrap_tuple(janet_tuple_end(t)), intv(0) },
        { janet_wrap_buffer(b), intv(1) },
        { janet_cstringv("AB"), intv(0) },
        { janet_wrap_table(tab), kw("k") },
        { janet_wrap_struct(janet_struct_end(st)), kw("k") },
        { slots_value, intv(2) }
    };
    for (int i = 0; i < 7; i++) {
        assert(janet_equals(janet_in(pairs[i][0], pairs[i][1]),
                            janet_get(pairs[i][0], pairs[i][1])));
    }
}

/* ------------------------------------------------------- janet_getindex */

/* The third policy: a negative index and a missing getter panic, and every
 * other failure is nil. The abstract arm is where it parts company with
 * `janet_in` -- a `get` that runs and reports absence is an error there and a
 * nil here. */
static void test_getindex_policies(void) {
    JanetArray *a = janet_array(1);
    janet_array_push(a, kw("x"));
    Janet arr = janet_wrap_array(a);
    assert(janet_equals(janet_getindex(arr, 0), kw("x")));
    assert(is_nil(janet_getindex(arr, 5)));
    EXPECT_PANIC(janet_getindex(arr, -1), "expected non-negative index");
    EXPECT_PANIC(janet_getindex(janet_wrap_nil(), -1), "expected non-negative index");

    assert(is_nil(janet_getindex(janet_cstringv("ab"), 9)));
    assert(janet_equals(janet_getindex(janet_cstringv("ab"), 1), intv('b')));
    assert(is_nil(janet_getindex(janet_wrap_buffer(janet_buffer(4)), 0)));

    Janet *t = janet_tuple_begin(1);
    t[0] = kw("t");
    Janet tup = janet_wrap_tuple(janet_tuple_end(t));
    assert(janet_equals(janet_getindex(tup, 0), kw("t")));
    assert(is_nil(janet_getindex(tup, 1)));

    /* Dictionaries are keyed by the integer, so an out-of-range index is a
     * missing key rather than an out-of-range one. */
    JanetTable *tab = janet_table(0);
    janet_table_put(tab, intv(7), kw("seven"));
    assert(janet_equals(janet_getindex(janet_wrap_table(tab), 7), kw("seven")));
    assert(is_nil(janet_getindex(janet_wrap_table(tab), 0)));

    JanetKV *st = janet_struct_begin(1);
    janet_struct_put(st, intv(7), kw("seven"));
    Janet s = janet_wrap_struct(janet_struct_end(st));
    assert(janet_equals(janet_getindex(s, 7), kw("seven")));
    assert(is_nil(janet_getindex(s, 0)));

    /* The disagreement with janet_in, stated directly. */
    assert(is_nil(janet_getindex(slots_value, 7)));
    EXPECT_PANIC_PREFIX(janet_in(slots_value, intv(7)), "key 7 not found in ");
    EXPECT_PANIC_PREFIX(janet_getindex(bare_value, 0), "no getter for <value-access/bare ");
    EXPECT_PANIC(janet_getindex(intv(5), 0), "expected string, symbol, keyword, "
                 "array, tuple, table, struct or buffer, got 5");
}

static void test_getindex_on_a_fiber(void) {
    Janet r = run("(def f (fiber/new (fn [] (yield :a) :done)))"
                  "(next f nil) f");
    assert(janet_equals(janet_getindex(r, 0), kw("a")));
    assert(is_nil(janet_getindex(r, 1)));
}

/* -------------------------------------------------------------- lengths */

static void test_length_of_every_container(void) {
    JanetArray *a = janet_array(3);
    for (int i = 0; i < 3; i++) janet_array_push(a, intv(i));
    JanetBuffer *b = janet_buffer(4);
    janet_buffer_push_cstring(b, "abcd");
    Janet *t = janet_tuple_begin(2);
    t[0] = t[1] = janet_wrap_nil();
    JanetTable *tab = janet_table(0);
    janet_table_put(tab, kw("a"), intv(1));
    janet_table_put(tab, kw("b"), intv(2));
    JanetKV *st = janet_struct_begin(1);
    janet_struct_put(st, kw("a"), intv(1));

    Janet vals[8];
    int32_t lens[8];
    vals[0] = janet_cstringv("abc");     lens[0] = 3;
    vals[1] = janet_csymbolv("abcd");    lens[1] = 4;
    vals[2] = kw("ab");                  lens[2] = 2;
    vals[3] = janet_wrap_array(a);       lens[3] = 3;
    vals[4] = janet_wrap_buffer(b);      lens[4] = 4;
    vals[5] = janet_wrap_tuple(janet_tuple_end(t)); lens[5] = 2;
    vals[6] = janet_wrap_table(tab);     lens[6] = 2;
    vals[7] = janet_wrap_struct(janet_struct_end(st)); lens[7] = 1;

    for (int i = 0; i < 8; i++) {
        assert(janet_length(vals[i]) == lens[i]);
        assert(janet_equals(janet_lengthv(vals[i]), intv(lens[i])));
    }

    /* A struct's length is its pair count, not its bucket count. */
    JanetKV *wide = janet_struct_begin(9);
    for (int i = 0; i < 9; i++) janet_struct_put(wide, intv(i), intv(i));
    Janet w = janet_wrap_struct(janet_struct_end(wide));
    assert(janet_length(w) == 9);
    assert(janet_struct_capacity(janet_unwrap_struct(w)) > 9);
}

/* A table's length is its live count, so removing a key shortens it even
 * though the tombstone stays in the bucket array. */
static void test_length_of_a_table_ignores_tombstones(void) {
    JanetTable *tab = janet_table(0);
    for (int i = 0; i < 8; i++) janet_table_put(tab, intv(i), intv(i));
    assert(janet_length(janet_wrap_table(tab)) == 8);
    janet_table_remove(tab, intv(0));
    assert(janet_length(janet_wrap_table(tab)) == 7);
    assert(tab->deleted == 1);
}

static void test_abstract_length_callback(void) {
    assert(janet_length(slots_value) == 3);
    assert(janet_equals(janet_lengthv(slots_value), janet_wrap_number(3.0)));
    /* `janet_lengthv` wraps a callback's length as a double rather than as an
     * integer, and the two are equal but not identically represented. */
    assert(janet_checktype(janet_lengthv(slots_value), JANET_NUMBER));
}

/* The band where the two functions disagree. `janet_length` stops at
 * `INT32_MAX` because it returns an `int32_t`; `janet_lengthv` stops at
 * `JANET_INTMAX_INT64` because it returns a double. A length between them
 * panics one and satisfies the other. */
static void test_the_two_length_bounds_are_different(void) {
    EXPECT_PANIC(janet_length(big_value), "invalid integer length 2147483648");
    Janet lv = janet_lengthv(big_value);
    assert(janet_checktype(lv, JANET_NUMBER));
    assert(janet_unwrap_number(lv) == 2147483648.0);

    EXPECT_PANIC(janet_length(huge_value), "invalid integer length 9007199254740992");
    EXPECT_PANIC(janet_lengthv(huge_value), "integer length 9007199254740992 too large");
}

/* Without a `length` callback the length comes from a `:length` method, which
 * is looked up through `janet_get` -- so this arm re-enters the file under
 * test. `janet_length` checks the result and `janet_lengthv` does not, which
 * is the second place the two disagree. */
static void test_length_falls_back_to_a_method(void) {
    assert(janet_length(good_method_value) == 7);
    assert(janet_equals(janet_lengthv(good_method_value), intv(7)));

    EXPECT_PANIC(janet_length(bad_method_value), "invalid integer length :not-a-number");
    assert(janet_equals(janet_lengthv(bad_method_value), kw("not-a-number")));

    EXPECT_PANIC_PREFIX(janet_length(bare_value),
                        "could not find method :length for <value-access/bare ");
    EXPECT_PANIC_PREFIX(janet_lengthv(bare_value),
                        "could not find method :length for <value-access/bare ");
}

static void test_length_of_a_non_lengthable_panics(void) {
    EXPECT_PANIC(janet_length(intv(5)), "expected string, symbol, keyword, "
                 "array, tuple, table, struct or buffer, got 5");
    EXPECT_PANIC(janet_lengthv(intv(5)), "expected string, symbol, keyword, "
                 "array, tuple, table, struct or buffer, got 5");
    EXPECT_PANIC(janet_length(janet_wrap_nil()), "expected string, symbol, keyword, "
                 "array, tuple, table, struct or buffer, got nil");
    EXPECT_PANIC(janet_lengthv(janet_wrap_nil()), "expected string, symbol, keyword, "
                 "array, tuple, table, struct or buffer, got nil");
}

/* ------------------------------------------------------------- the setters */

/* Writing past the end grows the container, and the two growable types fill
 * the gap differently: an array with nil, a buffer with zero. */
static void test_put_grows_an_array_with_nils(void) {
    JanetArray *a = janet_array(0);
    janet_array_push(a, kw("first"));
    janet_put(janet_wrap_array(a), intv(4), kw("fifth"));
    assert(a->count == 5);
    assert(janet_equals(a->data[0], kw("first")));
    for (int i = 1; i < 4; i++) assert(is_nil(a->data[i]));
    assert(janet_equals(a->data[4], kw("fifth")));

    /* An in-range write does not shorten it. */
    janet_put(janet_wrap_array(a), intv(0), kw("again"));
    assert(a->count == 5);
    assert(janet_equals(a->data[0], kw("again")));
}

/* The growth test is `index >= count`, not `index > count`, so appending at
 * exactly the current count grows by one. An off-by-one there writes the value
 * into a slot the count does not cover, which is invisible rather than wrong. */
static void test_putindex_appends_at_the_count(void) {
    JanetArray *a = janet_array(8);
    janet_array_push(a, kw("a"));
    janet_putindex(janet_wrap_array(a), 1, kw("b"));
    assert(a->count == 2);
    assert(janet_equals(a->data[1], kw("b")));

    JanetBuffer *b = janet_buffer(8);
    janet_buffer_push_cstring(b, "A");
    janet_putindex(janet_wrap_buffer(b), 1, intv('B'));
    assert(b->count == 2);
    assert(b->data[1] == 'B');
}

static void test_putindex_grows_a_buffer_with_zeroes(void) {
    JanetBuffer *b = janet_buffer(0);
    janet_buffer_push_cstring(b, "A");
    janet_putindex(janet_wrap_buffer(b), 4, intv('E'));
    assert(b->count == 5);
    assert(b->data[0] == 'A');
    for (int i = 1; i < 4; i++) assert(b->data[i] == 0);
    assert(b->data[4] == 'E');

    janet_putindex(janet_wrap_buffer(b), 0, intv('Z'));
    assert(b->count == 5);
    assert(b->data[0] == 'Z');
}

/* A buffer stores bytes, and the value is masked to eight bits after being
 * checked for integer-ness rather than being range-checked. So a value out of
 * byte range is stored truncated and does not complain. */
static void test_a_buffer_truncates_to_a_byte(void) {
    JanetBuffer *b = janet_buffer(4);
    janet_buffer_push_cstring(b, "\0\0");
    janet_put(janet_wrap_buffer(b), intv(0), intv(300));
    assert(b->data[0] == 44);
    janet_putindex(janet_wrap_buffer(b), 1, intv(-1));
    assert(b->data[1] == 255);
    janet_put(janet_wrap_buffer(b), intv(0), intv(256));
    assert(b->data[0] == 0);
    /* Eight bits, not seven: a value whose low byte has the high bit set
     * survives through both entry points. */
    janet_put(janet_wrap_buffer(b), intv(0), intv(200));
    assert(b->data[0] == 200);
    janet_putindex(janet_wrap_buffer(b), 1, intv(200));
    assert(b->data[1] == 200);
}

/* `janet_put` checks the key before the value and `janet_putindex` has no key
 * to check, so the same two bad arguments produce different messages
 * depending on which function is asked. */
static void test_put_checks_the_key_before_the_value(void) {
    JanetBuffer *b = janet_buffer(4);
    janet_buffer_push_cstring(b, "AB");
    EXPECT_PANIC(janet_put(janet_wrap_buffer(b), kw("x"), kw("y")),
                 "expected integer key for buffer in range [0, 2147483646), got :x");
    EXPECT_PANIC(janet_put(janet_wrap_buffer(b), intv(0), kw("y")),
                 "can only put integers in buffers, got :y");
    EXPECT_PANIC(janet_putindex(janet_wrap_buffer(b), 0, kw("y")),
                 "can only put integers in buffers, got :y");
    /* The rejected write left the buffer alone. */
    assert(b->count == 2 && b->data[0] == 'A');
}

/* The value check comes before the growth, so a rejected write to a buffer
 * does not resize it -- which is not true of the key check on an array, where
 * there is nothing to reject after the bound. */
static void test_a_rejected_buffer_write_does_not_grow_it(void) {
    JanetBuffer *b = janet_buffer(0);
    EXPECT_PANIC(janet_putindex(janet_wrap_buffer(b), 100, kw("y")),
                 "can only put integers in buffers, got :y");
    assert(b->count == 0);
}

/* `janet_put` bounds its index at INT32_MAX - 1, which is the bound
 * `janet_putindex` does not have. `FOUND.md` has the other side. */
static void test_put_bounds_the_index(void) {
    JanetArray *a = janet_array(0);
    EXPECT_PANIC(janet_put(janet_wrap_array(a), intv(2147483647), intv(1)),
                 "expected integer key for array in range [0, 2147483646), got 2147483647");
    EXPECT_PANIC(janet_put(janet_wrap_array(a), intv(-1), intv(1)),
                 "expected integer key for array in range [0, 2147483646), got -1");
    assert(a->count == 0);
}

static void test_put_on_a_table_and_an_abstract(void) {
    JanetTable *tab = janet_table(0);
    janet_put(janet_wrap_table(tab), kw("k"), intv(1));
    assert(janet_equals(janet_in(janet_wrap_table(tab), kw("k")), intv(1)));
    janet_putindex(janet_wrap_table(tab), 3, intv(2));
    assert(janet_equals(janet_in(janet_wrap_table(tab), intv(3)), intv(2)));

    janet_put(slots_value, intv(0), intv(99));
    assert(janet_equals(janet_in(slots_value, intv(0)), intv(99)));
    janet_putindex(slots_value, 0, intv(10));
    assert(janet_equals(janet_in(slots_value, intv(0)), intv(10)));
}

/* The second `%T` mask, and it is a different one: writing to a tuple is not a
 * bad key but an impossible operation, so the message names three types rather
 * than eight. Note the trailing space in the abstract message, which is the C
 * original's and is preserved. */
static void test_put_on_a_non_writable_panics(void) {
    Janet *t = janet_tuple_begin(1);
    t[0] = intv(0);
    Janet tup = janet_wrap_tuple(janet_tuple_end(t));
    Janet st = janet_wrap_struct(janet_struct_end(janet_struct_begin(0)));

    EXPECT_PANIC_PREFIX(janet_put(tup, intv(0), intv(1)),
                        "expected array, table or buffer, got <tuple ");
    EXPECT_PANIC_PREFIX(janet_putindex(st, 0, intv(1)),
                        "expected array, table or buffer, got <struct ");
    EXPECT_PANIC(janet_put(janet_cstringv("ab"), intv(0), intv(1)),
                 "expected array, table or buffer, got \"ab\"");
    EXPECT_PANIC(janet_putindex(intv(5), 0, intv(1)),
                 "expected array, table or buffer, got 5");
    EXPECT_PANIC(janet_put(janet_wrap_nil(), intv(0), intv(1)),
                 "expected array, table or buffer, got nil");
    EXPECT_PANIC_PREFIX(janet_put(bare_value, intv(0), intv(1)),
                        "no setter for <value-access/bare ");
    EXPECT_PANIC_PREFIX(janet_putindex(bare_value, 0, intv(1)),
                        "no setter for <value-access/bare ");
}

/* ------------------------------------------------------- from Janet source */

static void test_from_janet(void) {
    Janet out = run(
        "[(do (var n 0) (each x @{:a 1 :b 2 :c 3} (+= n x)) n) "
        " (do (var n 0) (eachk k [:a :b :c] (+= n k)) n) "
        " (length \"abc\") "
        " (length @{:a 1}) "
        " (in [10 20 30] 1) "
        " (get [10 20 30] 9) "
        " (get \"abc\" :x) "
        " (protect (in [10 20 30] 9)) "
        " (do (def a @[1]) (put a 3 :x) a) "
        " (do (def b @\"A\") (put b 3 66) b) "
        " (keys @{:a 1 :b 2}) "
        " (values {:a 1}) "
        " (do (def s (table/setproto @{:own 1} @{:up 2})) [(in s :up) (keys s)])]");
    const Janet *v = janet_unwrap_tuple(out);
    assert(janet_unwrap_integer(v[0]) == 6);
    assert(janet_unwrap_integer(v[1]) == 3);
    assert(janet_unwrap_integer(v[2]) == 3);
    assert(janet_unwrap_integer(v[3]) == 1);
    assert(janet_unwrap_integer(v[4]) == 20);
    assert(is_nil(v[5]));
    assert(is_nil(v[6]));
    {
        const Janet *p = janet_unwrap_tuple(v[7]);
        assert(!janet_truthy(p[0]));
        assert(janet_equals(p[1], janet_cstringv(
                                "expected integer key for tuple in range [0, 3), got 9")));
    }
    {
        JanetArray *a = janet_unwrap_array(v[8]);
        assert(a->count == 4);
        assert(janet_unwrap_integer(a->data[0]) == 1);
        assert(is_nil(a->data[1]) && is_nil(a->data[2]));
        assert(janet_equals(a->data[3], kw("x")));
    }
    {
        JanetBuffer *b = janet_unwrap_buffer(v[9]);
        assert(b->count == 4);
        assert(b->data[0] == 'A' && b->data[1] == 0 && b->data[2] == 0 && b->data[3] == 66);
    }
    assert(janet_unwrap_array(v[10])->count == 2);
    assert(janet_unwrap_array(v[11])->count == 1);
    {
        const Janet *pair = janet_unwrap_tuple(v[12]);
        /* The prototype's key reads through `in` and does not appear in
         * `keys`, which walks with `next`. */
        assert(janet_unwrap_integer(pair[0]) == 2);
        assert(janet_unwrap_array(pair[1])->count == 1);
    }
}

/* ------------------------------------------------------------------- main */

void value_access_contract(void) {
    janet_init();
    make_abstracts();
    janet_contract_adapt_regs(cfuns);
    janet_cfuns(janet_core_env(NULL), NULL, cfuns);

    test_next_visits_every_table_key_once();
    test_next_steps_over_tombstones();
    test_next_visits_every_struct_key_once();
    test_next_does_not_follow_a_struct_prototype();
    test_next_does_not_follow_a_table_prototype();
    test_next_over_empty_dictionaries();

    test_next_over_each_sequence_type();
    test_next_stops_rather_than_panicking_on_a_bad_key();
    test_next_from_a_negative_key();
    test_next_past_the_end();

    test_next_on_an_abstract();
    test_next_on_a_non_iterable_panics();

    test_next_resumes_a_fiber();
    test_janet_next_entry_point_on_a_fiber();
    test_next_on_an_unresumable_fiber();
    test_the_interpreter_flag_chooses_the_error_policy();
    test_the_child_slot_is_cleared();
    test_the_resumed_fiber_joins_the_lineage();

    test_in_reads_every_container();
    test_in_on_a_missing_dictionary_key_is_nil();
    test_in_panics_on_a_bad_key();
    test_in_on_a_non_lengthable_panics();
    test_in_on_an_abstract();
    test_in_on_a_fiber();

    test_get_answers_nil_where_in_panics();
    test_get_agrees_with_in_where_both_succeed();

    test_getindex_policies();
    test_getindex_on_a_fiber();

    test_length_of_every_container();
    test_length_of_a_table_ignores_tombstones();
    test_abstract_length_callback();
    test_the_two_length_bounds_are_different();
    test_length_falls_back_to_a_method();
    test_length_of_a_non_lengthable_panics();

    test_put_grows_an_array_with_nils();
    test_putindex_appends_at_the_count();
    test_putindex_grows_a_buffer_with_zeroes();
    test_a_buffer_truncates_to_a_byte();
    test_put_checks_the_key_before_the_value();
    test_a_rejected_buffer_write_does_not_grow_it();
    test_put_bounds_the_index();
    test_put_on_a_table_and_an_abstract();
    test_put_on_a_non_writable_panics();

    test_from_janet();

    if (panics_fired != EXPECTED_PANICS) {
        printf("expected %d panics, counted %d\n", EXPECTED_PANICS, panics_fired);
        assert(0 && "panic count mismatch");
    }

    janet_deinit();
    printf("value access contract ok\n");
}
