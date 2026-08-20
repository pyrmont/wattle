/* Behavioral contract for the callee side of the interpreter: method
 * invocation, the operator fallbacks, method resolution, the non-function call
 * path, and the three collection fill loops. Run against whichever
 * implementation the build selected (`-Dvm-calls=c` or the Zig default).
 *
 * Eleven functions, and they are one contract because they are one decision
 * made in stages. `run_vm` hands a callee to `janet_call_nonfn` or a name to
 * `janet_resolve_method`; both end in `janet_method_invoke`, which decides what
 * calling that value even means. Testing any of them alone would pin a stage
 * without pinning the handover.
 *
 * Four properties get more attention than their size suggests.
 *
 * **The whole battery runs inside a real fiber.** `janet_method_invoke` reaches
 * `janet_call` for a function callee, which requires a current fiber and a
 * frame to push onto. Rather than installing one by hand, `main` registers a
 * cfunction and calls it from Janet source, so every assertion below runs where
 * `run_vm` would have made the same call.
 *
 * **The seven panic messages are the ABI test.** The Zig implementation calls
 * `janet_panicf` through the C variadic ABI with a `Janet` in a `%v`, a
 * `const char *` in a `%s` and an `int32_t` in a `%d`. A mismatch there
 * produces a plausible wrong message rather than a crash, so every message is
 * compared byte for byte. The values chosen for those messages are numbers,
 * keywords and strings, because `%v` renders a table or a tuple with its
 * address and an address cannot be compared.
 *
 * **Argument order is asserted, not assumed.** `janet_binop_call`'s
 * right-hand fallback swaps its operands -- a `:r+` method receives its own
 * receiver first -- and `janet_method_invoke`'s default arm reverses the
 * lookup, indexing the argument by the callee rather than the other way round.
 * Both are invisible to a test that only checks that something came back.
 *
 * **Two tests exist to be jumped through.** An abstract type whose `tostring`
 * panics, and another whose `hash` panics, drive `janet_fill_string` and
 * `janet_fill_table` into raising from inside the loop. Under the Zig selector
 * that signal crosses a Zig frame, which is what SPIKE-8 permits and what the
 * `//! jump-transparent` marker asserts; these two are the only tests here that
 * would notice if it stopped being true.
 */

#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "features.h"
#include <janet.h>

#include "support.h"
#include "fiber.h"
#include "state.h"

/* ------------------------------------------------------------------ helpers */

/* Every panic this file expects is counted, because a case that silently
 * stopped panicking would otherwise look exactly like one that passed. Fixed
 * rather than a floor, and verified against -Dvm-calls=c first.
 *
 * It was 13 until the hinge, when the raising `hash` callback went; see
 * test_a_raise_from_inside_a_fill_loop. */
static int panics_fired = 0;
#define EXPECTED_PANICS 12

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

static JanetTable *test_env = NULL;

static Janet kw(const char *name) {
    return janet_ckeywordv(name);
}

static Janet intv(int32_t i) {
    return janet_wrap_integer(i);
}

static int is_nil(Janet x) {
    return janet_checktype(x, JANET_NIL);
}

/* Roots whatever it produces and never unroots it. The values these tests
 * hold live across calls that intern keywords and compile source, either of
 * which can collect, and a Janet value in a C local is not a root. The process
 * is short enough that never releasing them costs nothing. */
static Janet eval(const char *source) {
    Janet out = janet_wrap_nil();
    int status = janet_dostring(test_env, source, "vm-calls-test", &out);
    assert(status == 0);
    janet_gcroot(out);
    return out;
}

/* A fiber with a run of arguments pushed onto it, in the state `run_vm` leaves
 * before JOP_CALL: `stackstart` marks where the arguments begin and `stacktop`
 * where they end. */
static JanetFiber *fiber_with_args(int32_t argc, const Janet *argv) {
    JanetFiber *fiber = janet_fiber(janet_unwrap_function(eval("(fn [] nil)")), 32, 0, NULL);
    int32_t i;
    assert(fiber != NULL);
    janet_gcroot(janet_wrap_fiber(fiber));
    fiber->stackstart = fiber->stacktop;
    for (i = 0; i < argc; i++) janet_fiber_push(fiber, argv[i]);
    return fiber;
}

/* ------------------------------------------------------- cfunction fixtures */

static Janet cfun_sum(int32_t argc, Janet *argv) {
    double total = 0;
    int32_t i;
    for (i = 0; i < argc; i++) total += janet_getnumber(argv, i);
    return janet_wrap_number(total);
}

/* Returns its arguments as a tuple, so a caller can assert their order. */
static Janet cfun_args(int32_t argc, Janet *argv) {
    return janet_wrap_tuple(janet_tuple_n(argv, argc));
}

static Janet cfun_contract(int32_t argc, Janet *argv);

static JanetReg cfuns[] = {
    {"vmcalls/sum", cfun_sum, NULL},
    {"vmcalls/args", cfun_args, NULL},
    {"vmcalls/contract", cfun_contract, NULL},
    {NULL, NULL, NULL}
};

/* -------------------------------------------------------- abstract fixtures */

/* Callable: its `call` callback answers with its own argument count, so a test
 * can tell it apart from the indexed fallback. */
static Janet callable_call(void *p, int32_t argc, Janet *argv) {
    (void) p;
    (void) argv;
    return janet_wrap_integer(argc);
}

static const JanetAbstractType callable_type = {
    .name = "vm-calls/callable",
    .call = callable_call,
};

/* Indexable: no `call`, so janet_method_invoke falls out of the abstract arm
 * into the arity check and janet_in. */
static int indexable_get(void *p, Janet key, Janet *out) {
    (void) p;
    if (!janet_checkint(key)) return 0;
    *out = janet_wrap_integer(janet_unwrap_integer(key) * 10);
    return 1;
}

static const JanetAbstractType indexable_type = {
    .name = "vm-calls/indexable",
    .get = indexable_get,
};

/* Raises from `tostring`, which janet_fill_string reaches through
 * janet_to_string_b. */
static void loud_tostring(void *p, JanetBuffer *buffer) {
    (void) p;
    (void) buffer;
    janet_panic("tostring raised");
}

static const JanetAbstractType loud_string_type = {
    .name = "vm-calls/loud-string",
    .tostring = loud_tostring,
};

static Janet callable_value;
static Janet indexable_value;
static Janet loud_string_value;

static void make_abstracts(void) {
    callable_value = janet_wrap_abstract(janet_abstract(CONTRACT_AT(callable_type), 1));
    indexable_value = janet_wrap_abstract(janet_abstract(CONTRACT_AT(indexable_type), 1));
    loud_string_value = janet_wrap_abstract(janet_abstract(CONTRACT_AT(loud_string_type), 1));
    janet_gcroot(callable_value);
    janet_gcroot(indexable_value);
    janet_gcroot(loud_string_value);
}

/* ------------------------------------------------------ janet_method_invoke */

static void test_invoke_a_cfunction(void) {
    Janet argv[3] = { intv(1), intv(2), intv(4) };
    Janet callee = eval("vmcalls/sum");
    assert(janet_checktype(callee, JANET_CFUNCTION));
    assert(janet_unwrap_number(janet_method_invoke(callee, 3, argv)) == 7);
    /* Arity is the callee's business, not this layer's: zero arguments reach
     * the cfunction rather than the arity check below. */
    assert(janet_unwrap_number(janet_method_invoke(callee, 0, NULL)) == 0);
}

static void test_invoke_a_function(void) {
    Janet argv[2] = { intv(3), intv(4) };
    Janet callee = eval("(fn [a b] (* a b))");
    assert(janet_checktype(callee, JANET_FUNCTION));
    assert(janet_unwrap_number(janet_method_invoke(callee, 2, argv)) == 12);
}

static void test_invoke_an_abstract_with_a_call_callback(void) {
    Janet argv[3] = { intv(1), intv(1), intv(1) };
    /* The callback answers with argc, so this also shows that the arity check
     * below is not reached: three arguments would have failed it. */
    assert(janet_unwrap_number(janet_method_invoke(callable_value, 3, argv)) == 3);
    assert(janet_unwrap_number(janet_method_invoke(callable_value, 0, NULL)) == 0);
    /* One argument is the case that tells the two paths apart by value rather
     * than by arity: the indexed fallback would answer with janet_in on an
     * abstract that has no `get`, and the callback answers 1. */
    assert(janet_unwrap_number(janet_method_invoke(callable_value, 1, argv)) == 1);
}

static void test_an_abstract_without_call_falls_through_to_indexing(void) {
    Janet argv[2] = { intv(4), intv(5) };
    assert(janet_unwrap_number(janet_method_invoke(indexable_value, 1, argv)) == 40);
    /* Having fallen through, it is subject to the arity check the six indexed
     * types share. The message renders an abstract with its address, so this
     * is the one arity panic not compared whole. */
    {
        JanetTryState state;
        janet_try_init(&state);
        janet_contract_arm();
        (void) janet_method_invoke(indexable_value, 2, argv);
        int raised = janet_contract_raised();
        JanetSignal sig = janet_contract_signal();
        janet_restore(&state);
        assert(raised && "expected a panic");
        assert(sig == JANET_SIGNAL_ERROR);
        assert(janet_checktype(state.payload, JANET_STRING));
        {
            const char *m = (const char *) janet_unwrap_string(state.payload);
            const char *tail = " called with 2 arguments, possibly expected 1";
            size_t len = strlen(m);
            size_t taillen = strlen(tail);
            assert(len > taillen && 0 == strcmp(m + len - taillen, tail));
            assert(0 == strncmp(m, "<vm-calls/indexable ", 20));
        }
        panics_fired++;
    }
}

static void test_invoke_each_indexed_type(void) {
    Janet key[1];
    key[0] = kw("a");
    assert(janet_unwrap_number(janet_method_invoke(eval("@{:a 1}"), 1, key)) == 1);
    assert(janet_unwrap_number(janet_method_invoke(eval("{:a 2}"), 1, key)) == 2);
    key[0] = intv(1);
    assert(janet_unwrap_number(janet_method_invoke(eval("@[7 8]"), 1, key)) == 8);
    assert(janet_unwrap_number(janet_method_invoke(eval("[9 10]"), 1, key)) == 10);
    assert(janet_unwrap_number(janet_method_invoke(eval("\"ab\""), 1, key)) == 'b');
    assert(janet_unwrap_number(janet_method_invoke(eval("@\"cd\""), 1, key)) == 'd');
}

static void test_the_indexed_arity_check(void) {
    Janet argv[2] = { intv(0), intv(0) };
    EXPECT_PANIC(janet_method_invoke(eval("\"ab\""), 2, argv),
                 "\"ab\" called with 2 arguments, possibly expected 1");
    EXPECT_PANIC(janet_method_invoke(eval("\"ab\""), 0, NULL),
                 "\"ab\" called with 0 arguments, possibly expected 1");
}

static void test_the_default_arm_reverses_the_lookup(void) {
    Janet argv[1];
    argv[0] = eval("{:a 11}");
    /* A keyword callee indexes its argument, not the other way round: this is
     * what makes (:a struct) work. */
    assert(janet_unwrap_number(janet_method_invoke(kw("a"), 1, argv)) == 11);
    /* Any other unlisted type takes the same arm. A number is not a key of
     * that struct, so the answer is nil rather than a panic. */
    assert(is_nil(janet_method_invoke(intv(5), 1, argv)));
    EXPECT_PANIC(janet_method_invoke(kw("a"), 3, argv),
                 ":a called with 3 arguments, possibly expected 1");
}

/* ------------------------------------------------------ janet_method_lookup */

static void test_method_lookup(void) {
    Janet found = janet_method_lookup(eval("@{:m vmcalls/sum}"), "m");
    assert(janet_checktype(found, JANET_CFUNCTION));
    assert(is_nil(janet_method_lookup(eval("@{:m 1}"), "other")));
    /* A value with no keys at all answers nil rather than raising, which is
     * what lets the operator fallbacks try the other operand. */
    assert(is_nil(janet_method_lookup(intv(5), "m")));
}

/* -------------------------------------------------------------- janet_mcall */

static void test_mcall(void) {
    Janet argv[3];
    argv[0] = eval("@{:sum (fn [self a b] (+ a b))}");
    argv[1] = intv(2);
    argv[2] = intv(3);
    /* The receiver is passed to the method as its first argument, which is why
     * the method takes three parameters for a two-argument call. */
    assert(janet_unwrap_number(janet_mcall("sum", 3, argv)) == 5);
    argv[0] = intv(7);
    EXPECT_PANIC(janet_mcall("nope", 1, argv), "could not find method :nope for 7");
    EXPECT_PANIC(janet_mcall("len", 0, NULL), "method :len expected at least 1 argument");
}

/* --------------------------------------------------------- operator methods */

static void test_unary_call(void) {
    Janet receiver = eval("@{:- (fn [self] 42)}");
    assert(janet_unwrap_number(janet_unary_call("-", receiver)) == 42);
    EXPECT_PANIC(janet_unary_call("-", intv(5)), "could not find method :- for 5");
}

static void test_binop_call_prefers_the_left_operand(void) {
    Janet lhs = eval("@{:+ vmcalls/args}");
    Janet result = janet_binop_call("+", "r+", lhs, intv(9));
    const Janet *tup = janet_unwrap_tuple(result);
    assert(janet_tuple_length(tup) == 2);
    assert(janet_equals(tup[0], lhs));
    assert(janet_unwrap_number(tup[1]) == 9);
}

static void test_binop_call_swaps_for_the_right_operand(void) {
    Janet rhs = eval("@{:r+ vmcalls/args}");
    Janet result = janet_binop_call("+", "r+", intv(9), rhs);
    const Janet *tup = janet_unwrap_tuple(result);
    /* The right-hand method receives itself first. Asserted rather than
     * assumed: a port that passed them in source order would still return a
     * plausible answer for a commutative operator. */
    assert(janet_tuple_length(tup) == 2);
    assert(janet_equals(tup[0], rhs));
    assert(janet_unwrap_number(tup[1]) == 9);
}

static void test_binop_call_with_neither_method(void) {
    EXPECT_PANIC(janet_binop_call("+", "r+", intv(1), intv(2)),
                 "could not find method :+ for 1 or :r+ for 2");
}

/* ----------------------------------------------------- janet_resolve_method */

static void test_resolve_method(void) {
    Janet args[2];
    JanetFiber *fiber;
    Janet callee;

    args[0] = eval("@{:m vmcalls/sum}");
    args[1] = intv(1);
    fiber = fiber_with_args(2, args);
    callee = janet_resolve_method(kw("m"), fiber);
    assert(janet_checktype(callee, JANET_CFUNCTION));
    /* Resolution reads the receiver and leaves the stack alone: the arguments
     * are still pushed when it returns, because JOP_CALL consumes them next. */
    assert(fiber->stacktop - fiber->stackstart == 2);
    janet_gcunroot(janet_wrap_fiber(fiber));

    args[0] = eval("\"abc\"");
    fiber = fiber_with_args(1, args);
    EXPECT_PANIC(janet_resolve_method(kw("m"), fiber),
                 "unknown method :m invoked on \"abc\"");
    janet_gcunroot(janet_wrap_fiber(fiber));

    /* Unreachable from Janet source -- the compiler rejects a zero-argument
     * method call -- so only an assembled function or this test gets here. */
    fiber = fiber_with_args(0, NULL);
    EXPECT_PANIC(janet_resolve_method(kw("m"), fiber),
                 "method call (:m) takes at least 1 argument, got 0");
    janet_gcunroot(janet_wrap_fiber(fiber));
}

/* --------------------------------------------------------- janet_call_nonfn */

static void test_call_nonfn(void) {
    Janet args[2];
    JanetFiber *fiber;
    Janet result;

    /* A table callee with one argument is an indexed lookup. */
    args[0] = kw("a");
    fiber = fiber_with_args(1, args);
    result = janet_call_nonfn(fiber, eval("@{:a 3}"));
    assert(janet_unwrap_number(result) == 3);
    /* The arguments are consumed: stacktop is back at stackstart, which is
     * what lets the callee push a frame of its own over them. */
    assert(fiber->stacktop == fiber->stackstart);
    janet_gcunroot(janet_wrap_fiber(fiber));

    /* A cfunction callee gets the pushed arguments in order. */
    args[0] = intv(5);
    args[1] = intv(6);
    fiber = fiber_with_args(2, args);
    result = janet_call_nonfn(fiber, eval("vmcalls/sum"));
    assert(janet_unwrap_number(result) == 11);
    janet_gcunroot(janet_wrap_fiber(fiber));

    /* Zero pushed arguments reach the arity check rather than reading a stack
     * slot that holds nothing. */
    fiber = fiber_with_args(0, NULL);
    EXPECT_PANIC(janet_call_nonfn(fiber, kw("a")),
                 ":a called with 0 arguments, possibly expected 1");
    janet_gcunroot(janet_wrap_fiber(fiber));
}

/* -------------------------------------------------------------- fill loops */

static void test_fill_table(void) {
    JanetTable *table = janet_table(4);
    Janet mem[4];
    mem[0] = kw("a");
    mem[1] = intv(1);
    mem[2] = kw("b");
    mem[3] = intv(2);
    janet_gcroot(janet_wrap_table(table));
    janet_fill_table(table, mem, 4);
    assert(table->count == 2);
    assert(janet_unwrap_number(janet_table_get(table, kw("a"))) == 1);
    assert(janet_unwrap_number(janet_table_get(table, kw("b"))) == 2);
    /* A zero count writes nothing and reads nothing. */
    janet_fill_table(table, NULL, 0);
    assert(table->count == 2);
    janet_gcunroot(janet_wrap_table(table));
}

static void test_fill_struct(void) {
    JanetKV *st = janet_struct_begin(2);
    Janet mem[4];
    const JanetKV *done;
    mem[0] = kw("a");
    mem[1] = intv(1);
    mem[2] = kw("b");
    mem[3] = intv(2);
    janet_fill_struct(st, mem, 4);
    done = janet_struct_end(st);
    assert(janet_struct_length(done) == 2);
    assert(janet_unwrap_number(janet_struct_get(done, kw("a"))) == 1);
    assert(janet_unwrap_number(janet_struct_get(done, kw("b"))) == 2);
}

static void test_fill_string(void) {
    JanetBuffer *buffer = janet_buffer(8);
    Janet mem[3];
    mem[0] = intv(1);
    mem[1] = kw("ab");
    mem[2] = eval("\"cd\"");
    janet_gcroot(janet_wrap_buffer(buffer));
    janet_fill_string(buffer, mem, 3);
    /* Each element is rendered as `string` would render it: a keyword loses
     * its colon and a string loses its quotes. */
    assert(buffer->count == 5);
    assert(0 == memcmp(buffer->data, "1abcd", 5));
    janet_fill_string(buffer, NULL, 0);
    assert(buffer->count == 5);
    janet_gcunroot(janet_wrap_buffer(buffer));
}

/* A raise from inside the fill loop, which is the one thing about these three
 * that a Janet-level test cannot reach: the callback that raises belongs to an
 * abstract type no in-tree module defines.
 *
 * There were two halves here until the hinge, and the second is gone rather
 * than fixed. It drove `janet_fill_table` through an abstract whose `hash`
 * called `janet_panic`, and it worked because `janet_panic` was a `longjmp`:
 * the jump left `janet_table_put` from inside a callback whose signature had
 * no way to say it had failed. The hinge typed `hash` non-raising -- see
 * `src/zig/subsystems/abstract_type.zig`, which gives the reason: `hash` is
 * reached from comparisons that must be total, so a raise there has no caller
 * that could act on it. With the jump gone the callback has no way out, so the
 * case is not a behaviour this runtime has any more. `tostring` is raising and
 * is what this keeps. */
static void test_a_raise_from_inside_a_fill_loop(void) {
    JanetBuffer *buffer = janet_buffer(8);
    Janet mem[2];

    janet_gcroot(janet_wrap_buffer(buffer));
    mem[0] = intv(1);
    mem[1] = loud_string_value;
    EXPECT_PANIC(janet_fill_string(buffer, mem, 2), "tostring raised");
    /* The element before the raising one was already written, and the buffer
     * survives the raise. */
    assert(buffer->count == 1);
    assert(buffer->data[0] == '1');
    janet_gcunroot(janet_wrap_buffer(buffer));
}

/* ------------------------------------------------------------------- entry */

static Janet cfun_contract(int32_t argc, Janet *argv) {
    (void) argv;
    janet_fixarity(argc, 0);

    test_invoke_a_cfunction();
    test_invoke_a_function();
    test_invoke_an_abstract_with_a_call_callback();
    test_an_abstract_without_call_falls_through_to_indexing();
    test_invoke_each_indexed_type();
    test_the_indexed_arity_check();
    test_the_default_arm_reverses_the_lookup();

    test_method_lookup();
    test_mcall();

    test_unary_call();
    test_binop_call_prefers_the_left_operand();
    test_binop_call_swaps_for_the_right_operand();
    test_binop_call_with_neither_method();

    test_resolve_method();
    test_call_nonfn();

    test_fill_table();
    test_fill_struct();
    test_fill_string();
    test_a_raise_from_inside_a_fill_loop();

    return janet_wrap_nil();
}

void vm_calls_contract(void) {
    janet_init();
    test_env = janet_core_env(NULL);
    janet_contract_adapt_regs(cfuns);
    janet_cfuns(test_env, NULL, cfuns);
    make_abstracts();

    /* From Janet source, so that everything above runs with a live fiber under
     * it: janet_method_invoke reaches janet_call, which has no meaning
     * without one. */
    eval("(vmcalls/contract)");

    if (panics_fired != EXPECTED_PANICS) {
        printf("expected %d panics, counted %d\n", EXPECTED_PANICS, panics_fired);
        assert(0 && "panic count mismatch");
    }

    janet_deinit();
    printf("vm calls contract ok (%d panics)\n", panics_fired);
}
