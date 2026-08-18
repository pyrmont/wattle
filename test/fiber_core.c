/* Behavioral contract for the fiber stack-frame machinery, run against
 * whichever implementation the build selected (`-Dfiber-core=c` or the Zig
 * default).
 *
 * Almost everything here is exercised constantly by the Janet suites — every
 * function call in the language goes through janet_fiber_funcframe — so what
 * this file is for is the edges the suites reach only by accident: the arity
 * boundaries, an empty variadic tail against a non-empty one, a tail call that
 * has to move its arguments down over the frame it is replacing, and the
 * environment validator, whose whole job is to reject input the suites never
 * produce.
 *
 * The file includes `fiber.h` and `state.h`. It has to: the frame macros and
 * the collector's byte budget are what the machinery manipulates, and a test
 * that declared its own copies would be testing the copies.
 */

#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "features.h"
#include <janet.h>
#include "fiber.h"
#include "state.h"

/* The per-thread half of the contract needs threads and pthreads to say it
 * with, exactly as test/vm_state.c does. A single-threaded build has one
 * process-wide VM by construction; the Windows path is cross-compiled and
 * never executed, so it is left out rather than written blind. */
#if !defined(JANET_SINGLE_THREADED) && !defined(JANET_WINDOWS)
#define JANET_FIBER_CORE_THREADS
#include <pthread.h>
#endif

static JanetTable *test_env;

/* ------------------------------------------------------- without a runtime */

/* janet_fiber_setcapacity is reachable without janet_init: it resizes a plain
 * allocation and charges the collector's byte budget, and touches nothing
 * else. Testing it here keeps the arithmetic visible instead of buried under a
 * live heap whose budget is moving for other reasons. */
static void test_setcapacity_charges_the_budget(void) {
    JanetFiber fiber;
    size_t before;

    memset(&fiber, 0, sizeof(fiber));
    janet_vm.next_collection = 0;

    janet_fiber_setcapacity(&fiber, 40);
    assert(fiber.capacity == 40);
    assert(fiber.data != NULL);
    assert(janet_vm.next_collection == 40 * sizeof(Janet));

    /* Growing charges the difference, not the new total. */
    janet_fiber_setcapacity(&fiber, 100);
    assert(fiber.capacity == 100);
    assert(janet_vm.next_collection == 100 * sizeof(Janet));

    /* Shrinking gives the difference back. The C original writes this as
     * `next_collection += sizeof(Janet) * diff` with a negative `diff`, so the
     * refund is an unsigned wraparound rather than a subtraction; the result is
     * the same and the spelling is what a port could get wrong. */
    before = janet_vm.next_collection;
    janet_fiber_setcapacity(&fiber, 60);
    assert(fiber.capacity == 60);
    assert(janet_vm.next_collection == before - 40 * sizeof(Janet));

    janet_free(fiber.data);
    janet_vm.next_collection = 0;
}

#ifdef JANET_FIBER_CORE_THREADS

static size_t child_charge;
static size_t child_saw_main;

static void *charge_child_budget(void *arg) {
    JanetFiber fiber;
    (void) arg;
    memset(&fiber, 0, sizeof(fiber));
    child_saw_main = janet_vm.next_collection;
    janet_fiber_setcapacity(&fiber, 16);
    child_charge = janet_vm.next_collection;
    janet_free(fiber.data);
    return NULL;
}

/* The budget belongs to the calling thread's VM. This is the one property the
 * port could plausibly get wrong while still linking and passing everything
 * else: reaching a process-wide `janet_vm` instead of a thread-local one is
 * invisible until two threads run at once. */
static void test_budget_is_per_thread(void) {
    pthread_t thread;
    size_t main_before;

    janet_vm.next_collection = 4096;
    main_before = janet_vm.next_collection;
    assert(0 == pthread_create(&thread, NULL, charge_child_budget, NULL));
    assert(0 == pthread_join(thread, NULL));

    assert(child_saw_main == 0);
    assert(child_charge == 16 * sizeof(Janet));
    assert(janet_vm.next_collection == main_before);
    janet_vm.next_collection = 0;
}

#endif

/* ---------------------------------------------------------------- helpers */

static JanetFunction *compile_function(const char *source) {
    Janet out = janet_wrap_nil();
    int status = janet_dostring(test_env, source, "fiber-core-test", &out);
    assert(status == 0);
    assert(janet_checktype(out, JANET_FUNCTION));
    janet_gcroot(out);
    return janet_unwrap_function(out);
}

static JanetFiber *rooted_fiber(JanetFunction *func, int32_t argc, const Janet *argv) {
    JanetFiber *fiber = janet_fiber(func, 32, argc, argv);
    assert(fiber != NULL);
    janet_gcroot(janet_wrap_fiber(fiber));
    return fiber;
}

static void assert_nil_from(JanetFiber *fiber, int32_t first, int32_t last) {
    int32_t i;
    for (i = first; i < last; i++) {
        assert(janet_checktype(fiber->data[i], JANET_NIL));
    }
}

/* ------------------------------------------------------------- funcframes */

/* A fresh fiber's first frame: base at JANET_FRAME_SIZE, arguments at the
 * frame's slot 0, every remaining slot nil because the collector walks them. */
static void test_funcframe_layout(JanetFunction *add) {
    Janet args[2];
    JanetFiber *fiber;
    JanetStackFrame *frame;

    args[0] = janet_wrap_integer(11);
    args[1] = janet_wrap_integer(22);
    fiber = rooted_fiber(add, 2, args);
    frame = janet_fiber_frame(fiber);

    assert(fiber->frame == JANET_FRAME_SIZE);
    assert(fiber->stackstart == fiber->stacktop);
    assert(fiber->stacktop == JANET_FRAME_SIZE + add->def->slotcount + JANET_FRAME_SIZE);
    assert(fiber->capacity >= fiber->stacktop);

    assert(frame->func == add);
    assert(frame->pc == add->def->bytecode);
    assert(frame->env == NULL);
    assert(frame->prevframe == 0);
    /* janet_fiber_reset adds ENTRANCE after the frame is pushed, so the frame
     * itself must have been left with no other flags set. */
    assert(frame->flags == JANET_STACKFRAME_ENTRANCE);

    assert(janet_unwrap_integer(fiber->data[fiber->frame]) == 11);
    assert(janet_unwrap_integer(fiber->data[fiber->frame + 1]) == 22);
    assert_nil_from(fiber, fiber->frame + 2, fiber->frame + add->def->slotcount);
}

/* A rejected arity must leave the fiber exactly as it was, because callers use
 * the return value to implement janet_pcall rather than to recover from a
 * partially built frame. */
static void test_funcframe_arity_rejection(JanetFunction *add) {
    Janet args[3];
    JanetFiber *fiber;
    int32_t frame, stackstart, stacktop;

    args[0] = janet_wrap_integer(1);
    args[1] = janet_wrap_integer(2);
    args[2] = janet_wrap_integer(3);

    assert(janet_fiber(add, 32, 1, args) == NULL);
    assert(janet_fiber(add, 32, 3, args) == NULL);

    fiber = rooted_fiber(add, 2, args);
    frame = fiber->frame;
    stackstart = fiber->stackstart;
    stacktop = fiber->stacktop;

    janet_fiber_push(fiber, janet_wrap_integer(5));
    assert(janet_fiber_funcframe(fiber, add) == 1);
    assert(fiber->frame == frame);
    assert(fiber->stackstart == stackstart);
    assert(fiber->stacktop == stacktop + 1);
}

/* A variadic tail is a tuple, and an empty one is the empty tuple rather than
 * a missing slot — the slot is a live local of the callee either way. */
static void test_funcframe_varargs(JanetFunction *rest) {
    Janet args[3];
    JanetFiber *fiber;
    Janet tail;
    const Janet *tuple;

    args[0] = janet_wrap_integer(1);
    args[1] = janet_wrap_integer(2);
    args[2] = janet_wrap_integer(3);

    fiber = rooted_fiber(rest, 3, args);
    tail = fiber->data[fiber->frame + rest->def->arity];
    assert(janet_checktype(tail, JANET_TUPLE));
    tuple = janet_unwrap_tuple(tail);
    assert(janet_tuple_length(tuple) == 2);
    assert(janet_unwrap_integer(tuple[0]) == 2);
    assert(janet_unwrap_integer(tuple[1]) == 3);

    fiber = rooted_fiber(rest, 1, args);
    tail = fiber->data[fiber->frame + rest->def->arity];
    assert(janet_checktype(tail, JANET_TUPLE));
    assert(janet_tuple_length(janet_unwrap_tuple(tail)) == 0);
}

/* `&keys` sets JANET_FUNCDEF_FLAG_STRUCTARG, and the tail is built with
 * janet_struct_put instead of janet_tuple_n. Only even-length tails are
 * asserted here: an odd one reads a slot past the arguments, which is a defect
 * in `make_struct_n` recorded in FOUND.md and shared by both selectors, so
 * pinning it would pin an out-of-range read rather than a behavior. */
static void test_funcframe_structargs(JanetFunction *keyed) {
    Janet args[5];
    JanetFiber *fiber;
    Janet tail;

    args[0] = janet_wrap_integer(1);
    args[1] = janet_ckeywordv("a");
    args[2] = janet_wrap_integer(7);
    args[3] = janet_ckeywordv("b");
    args[4] = janet_wrap_integer(8);

    fiber = rooted_fiber(keyed, 5, args);
    tail = fiber->data[fiber->frame + keyed->def->arity];
    assert(janet_checktype(tail, JANET_STRUCT));
    assert(janet_struct_length(janet_unwrap_struct(tail)) == 2);
    assert(janet_unwrap_integer(janet_get(tail, janet_ckeywordv("a"))) == 7);
    assert(janet_unwrap_integer(janet_get(tail, janet_ckeywordv("b"))) == 8);

    fiber = rooted_fiber(keyed, 1, args);
    tail = fiber->data[fiber->frame + keyed->def->arity];
    assert(janet_checktype(tail, JANET_STRUCT));
    assert(janet_struct_length(janet_unwrap_struct(tail)) == 0);
}

/* ------------------------------------------------------------- tail calls */

/* A tail call reuses the current frame: the arguments move down over the
 * outgoing function's slots, the rest are nil'd, and the frame is repointed
 * without its base moving. */
static void test_funcframe_tail(JanetFunction *add, JanetFunction *other) {
    Janet args[2];
    JanetFiber *fiber;
    JanetStackFrame *frame;
    int32_t base;

    args[0] = janet_wrap_integer(1);
    args[1] = janet_wrap_integer(2);
    fiber = rooted_fiber(add, 2, args);
    base = fiber->frame;

    janet_fiber_push2(fiber, janet_wrap_integer(30), janet_wrap_integer(40));
    assert(janet_fiber_funcframe_tail(fiber, other) == 0);

    frame = janet_fiber_frame(fiber);
    assert(fiber->frame == base);
    assert(frame->func == other);
    assert(frame->pc == other->def->bytecode);
    assert(frame->env == NULL);
    assert(frame->flags & JANET_STACKFRAME_TAILCALL);
    /* The entrance flag belongs to the frame, not to the function in it, and a
     * tail call must not clear it. */
    assert(frame->flags & JANET_STACKFRAME_ENTRANCE);

    assert(janet_unwrap_integer(fiber->data[base]) == 30);
    assert(janet_unwrap_integer(fiber->data[base + 1]) == 40);
    assert_nil_from(fiber, base + 2, base + other->def->slotcount);
    assert(fiber->stacktop == base + other->def->slotcount + JANET_FRAME_SIZE);
    assert(fiber->stackstart == fiber->stacktop);
}

static void test_funcframe_tail_arity_rejection(JanetFunction *add, JanetFunction *other) {
    Janet args[2];
    JanetFiber *fiber;
    int32_t frame, stackstart, stacktop;

    args[0] = janet_wrap_integer(1);
    args[1] = janet_wrap_integer(2);
    fiber = rooted_fiber(add, 2, args);
    janet_fiber_push(fiber, janet_wrap_integer(9));

    frame = fiber->frame;
    stackstart = fiber->stackstart;
    stacktop = fiber->stacktop;
    assert(janet_fiber_funcframe_tail(fiber, other) == 1);
    assert(fiber->frame == frame);
    assert(fiber->stackstart == stackstart);
    assert(fiber->stacktop == stacktop);
    assert(janet_fiber_frame(fiber)->func == add);
}

/* The variadic tail of a tail call is built before the arguments move, because
 * the move copies the tail's slot along with them. Getting that order wrong
 * moves an uninitialised slot and loses the tail. */
static void test_funcframe_tail_varargs(JanetFunction *add, JanetFunction *rest) {
    Janet args[2];
    JanetFiber *fiber;
    Janet tail;
    const Janet *tuple;
    int32_t base;

    args[0] = janet_wrap_integer(1);
    args[1] = janet_wrap_integer(2);
    fiber = rooted_fiber(add, 2, args);
    base = fiber->frame;

    janet_fiber_push3(fiber, janet_wrap_integer(7), janet_wrap_integer(8), janet_wrap_integer(9));
    assert(janet_fiber_funcframe_tail(fiber, rest) == 0);

    assert(janet_unwrap_integer(fiber->data[base]) == 7);
    tail = fiber->data[base + rest->def->arity];
    assert(janet_checktype(tail, JANET_TUPLE));
    tuple = janet_unwrap_tuple(tail);
    assert(janet_tuple_length(tuple) == 2);
    assert(janet_unwrap_integer(tuple[0]) == 8);
    assert(janet_unwrap_integer(tuple[1]) == 9);

    /* An empty tail in a tail call takes the other branch, which has to grow
     * the stack itself before it can nil the gap it leaves behind. */
    fiber = rooted_fiber(add, 2, args);
    base = fiber->frame;
    janet_fiber_push(fiber, janet_wrap_integer(5));
    assert(janet_fiber_funcframe_tail(fiber, rest) == 0);
    assert(janet_unwrap_integer(fiber->data[base]) == 5);
    tail = fiber->data[base + rest->def->arity];
    assert(janet_checktype(tail, JANET_TUPLE));
    assert(janet_tuple_length(janet_unwrap_tuple(tail)) == 0);
}

/* ------------------------------------------------------------- c frames */

static Janet a_cfunction(int32_t argc, Janet *argv) {
    (void) argc;
    (void) argv;
    return janet_wrap_nil();
}

/* A C frame carries the function in the slot a Janet frame uses for its
 * program counter, and is recognised by its null `func`. */
static void test_cframe_and_popframe(JanetFunction *add) {
    Janet args[2];
    JanetFiber *fiber;
    JanetStackFrame *frame;
    int32_t base, stacktop;

    args[0] = janet_wrap_integer(1);
    args[1] = janet_wrap_integer(2);
    fiber = rooted_fiber(add, 2, args);
    base = fiber->frame;
    stacktop = fiber->stacktop;

    janet_fiber_push2(fiber, janet_wrap_integer(3), janet_wrap_integer(4));
    janet_fiber_cframe(fiber, a_cfunction);
    frame = janet_fiber_frame(fiber);

    assert(fiber->frame == stacktop);
    assert(frame->func == NULL);
    assert(frame->pc == (uint32_t *) a_cfunction);
    assert(frame->env == NULL);
    assert(frame->flags == 0);
    assert(frame->prevframe == base);
    assert(fiber->stacktop == stacktop + 2 + JANET_FRAME_SIZE);
    assert(fiber->stackstart == fiber->stacktop);
    /* The arguments stay where they were pushed, below the new frame. */
    assert(janet_unwrap_integer(fiber->data[fiber->frame]) == 3);
    assert(janet_unwrap_integer(fiber->data[fiber->frame + 1]) == 4);

    janet_fiber_popframe(fiber);
    assert(fiber->frame == base);
    assert(fiber->stacktop == stacktop);
    assert(fiber->stackstart == stacktop);
    assert(janet_fiber_frame(fiber)->func == add);

    /* Popping the outermost frame is a no-op rather than an underflow. The
     * fiber stays rooted for the rest of the run, so it is put back into a
     * state the collector can walk. */
    janet_fiber_popframe(fiber);
    assert(fiber->frame == 0);
    stacktop = fiber->stacktop;
    janet_fiber_popframe(fiber);
    assert(fiber->frame == 0);
    assert(fiber->stacktop == stacktop);
    assert(fiber->stackstart == stacktop);
}

/* ---------------------------------------------------------------- pushes */

static void test_pushes(JanetFunction *add) {
    Janet args[2];
    Janet values[3];
    JanetFiber *fiber;
    int32_t start, old_capacity;

    args[0] = janet_wrap_integer(1);
    args[1] = janet_wrap_integer(2);
    fiber = rooted_fiber(add, 2, args);
    start = fiber->stacktop;

    janet_fiber_push(fiber, janet_wrap_integer(100));
    assert(fiber->stacktop == start + 1);
    janet_fiber_push2(fiber, janet_wrap_integer(101), janet_wrap_integer(102));
    assert(fiber->stacktop == start + 3);
    janet_fiber_push3(fiber, janet_wrap_integer(103), janet_wrap_integer(104), janet_wrap_integer(105));
    assert(fiber->stacktop == start + 6);
    values[0] = janet_wrap_integer(106);
    values[1] = janet_wrap_integer(107);
    values[2] = janet_wrap_integer(108);
    janet_fiber_pushn(fiber, values, 3);
    assert(fiber->stacktop == start + 9);
    for (int32_t i = 0; i < 9; i++) {
        assert(janet_unwrap_integer(fiber->data[start + i]) == 100 + i);
    }

    /* A zero-length push accepts a null array. That is what safe_memcpy is for
     * — memcpy with a null source is undefined however long it is told to
     * copy — and janet_fiber_pushn is called that way. */
    janet_fiber_pushn(fiber, NULL, 0);
    assert(fiber->stacktop == start + 9);

    /* Growth doubles what was needed, so a fiber that is exactly full doubles
     * its capacity on the next single push. */
    while (fiber->stacktop < fiber->capacity) {
        janet_fiber_push(fiber, janet_wrap_integer(0));
    }
    assert(fiber->stacktop == fiber->capacity);
    old_capacity = fiber->capacity;
    janet_fiber_push(fiber, janet_wrap_integer(1));
    assert(fiber->capacity == 2 * old_capacity);

    /* A multi-value push sizes the growth from the top it is about to reach,
     * not from the top it starts at. */
    while (fiber->stacktop < fiber->capacity - 1) {
        janet_fiber_push(fiber, janet_wrap_integer(0));
    }
    old_capacity = fiber->capacity;
    janet_fiber_push3(fiber, janet_wrap_integer(1), janet_wrap_integer(2), janet_wrap_integer(3));
    assert(fiber->capacity == 2 * (old_capacity + 2));
}

/* ---------------------------------------------------- function environments */

/* janet_env_valid exists for unmarshalled environments, which record their
 * stack offset negated and are trusted only if a live frame of the fiber they
 * name still matches them in offset, identity, and slot count. Each of those
 * three is checked separately, because a validator that ignored one would pass
 * every test built only from valid input. */
static void test_env_valid(JanetFunction *add, JanetFunction *other) {
    Janet args[2];
    JanetFiber *fiber;
    JanetFuncEnv env;
    JanetFuncEnv decoy;

    args[0] = janet_wrap_integer(1);
    args[1] = janet_wrap_integer(2);
    fiber = rooted_fiber(add, 2, args);

    /* A non-negative offset is already on the stack and is accepted as is. */
    memset(&env, 0, sizeof(env));
    env.offset = 4;
    assert(janet_env_valid(&env) == 1);
    assert(env.offset == 4);

    /* The matching case restores the offset's sign. */
    env.offset = -(fiber->frame);
    env.length = add->def->slotcount;
    env.as.fiber = fiber;
    janet_fiber_frame(fiber)->env = &env;
    assert(janet_env_valid(&env) == 1);
    assert(env.offset == fiber->frame);

    /* Wrong offset: no frame lives there. */
    env.offset = -(fiber->frame + 1);
    assert(janet_env_valid(&env) == 0);
    assert(env.offset == 0);
    assert(env.length == 0);
    assert(env.as.values == NULL);

    /* Right offset, but the frame points at a different environment. */
    memset(&decoy, 0, sizeof(decoy));
    env.offset = -(fiber->frame);
    env.length = add->def->slotcount;
    env.as.fiber = fiber;
    janet_fiber_frame(fiber)->env = &decoy;
    assert(janet_env_valid(&env) == 0);
    assert(env.offset == 0);

    /* Right offset and identity, but a slot count the frame's function does
     * not have. */
    env.offset = -(fiber->frame);
    env.length = other->def->slotcount + 1;
    env.as.fiber = fiber;
    janet_fiber_frame(fiber)->env = &env;
    assert(janet_env_valid(&env) == 0);
    assert(env.offset == 0);

    janet_fiber_frame(fiber)->env = NULL;
}

/* An environment is detached when its fiber can no longer change the slots it
 * points at. Until then it must keep sharing them, which is what makes a
 * closure over a running fiber see that fiber's updates. */
static void test_env_maybe_detach(JanetFunction *add) {
    Janet args[2];
    JanetFiber *fiber;
    JanetFuncEnv env;

    args[0] = janet_wrap_integer(1);
    args[1] = janet_wrap_integer(2);
    fiber = rooted_fiber(add, 2, args);
    /* This half of the test wants the unfiltered copy, which is what a
     * function with no inner closure gets. */
    assert(add->def->closure_bitset == NULL);

    memset(&env, 0, sizeof(env));
    env.offset = fiber->frame;
    env.length = add->def->slotcount;
    env.as.fiber = fiber;

    janet_fiber_set_status(fiber, JANET_STATUS_PENDING);
    janet_env_maybe_detach(&env);
    assert(env.offset == fiber->frame);
    assert(env.as.fiber == fiber);

    janet_fiber_set_status(fiber, JANET_STATUS_DEAD);
    janet_env_maybe_detach(&env);
    assert(env.offset == 0);
    assert(env.length == add->def->slotcount);
    assert(env.as.values != NULL);
    assert(env.as.values != fiber->data + fiber->frame);
    assert(janet_unwrap_integer(env.as.values[0]) == 1);
    assert(janet_unwrap_integer(env.as.values[1]) == 2);

    /* The copy is independent: the fiber's slots may still be reused. */
    fiber->data[fiber->frame] = janet_wrap_integer(99);
    assert(janet_unwrap_integer(env.as.values[0]) == 1);

    janet_free(env.as.values);
}

/* A detached copy keeps only the slots an inner closure actually captured. The
 * rest are nil'd rather than copied, which is what stops a closure from
 * rooting every local of the frame it was made in. */
static void test_env_detach_honours_the_closure_bitset(JanetFunction *capturing) {
    Janet args[2];
    JanetFiber *fiber;
    JanetFuncEnv env;
    int32_t i;
    int32_t kept = 0;

    args[0] = janet_wrap_integer(41);
    args[1] = janet_wrap_integer(42);
    fiber = rooted_fiber(capturing, 2, args);
    assert(capturing->def->closure_bitset != NULL);

    memset(&env, 0, sizeof(env));
    env.offset = fiber->frame;
    env.length = capturing->def->slotcount;
    env.as.fiber = fiber;

    janet_fiber_set_status(fiber, JANET_STATUS_DEAD);
    janet_env_maybe_detach(&env);
    assert(env.offset == 0);
    assert(env.as.values != NULL);

    for (i = 0; i < env.length; i++) {
        int captured = (capturing->def->closure_bitset[i >> 5] >> (i & 31)) & 1;
        if (captured) {
            kept++;
            assert(janet_equals(env.as.values[i], fiber->data[fiber->frame + i]));
        } else {
            assert(janet_checktype(env.as.values[i], JANET_NIL));
        }
    }
    /* A bitset that kept nothing, or kept everything, would make the loop
     * above vacuous in one direction or the other. */
    assert(kept > 0);
    assert(kept < env.length);

    janet_free(env.as.values);
}

/* ------------------------------------------------------------ inspection */

static void test_status_and_resumability(JanetFunction *add) {
    Janet args[2];
    JanetFiber *fiber;
    int32_t status;

    args[0] = janet_wrap_integer(1);
    args[1] = janet_wrap_integer(2);
    fiber = rooted_fiber(add, 2, args);

    for (status = JANET_STATUS_DEAD; status <= JANET_STATUS_ALIVE; status++) {
        int finished = status == JANET_STATUS_DEAD ||
                       status == JANET_STATUS_ERROR ||
                       (status >= JANET_STATUS_USER0 && status <= JANET_STATUS_USER4);
        fiber->flags = JANET_FIBER_MASK_YIELD | JANET_FIBER_BREAKPOINT;
        janet_fiber_set_status(fiber, status);
        assert((int32_t) janet_fiber_status(fiber) == status);
        assert(janet_fiber_can_resume(fiber) == !finished);
        /* Setting a status must leave the other flag bits alone. */
        assert(fiber->flags & JANET_FIBER_MASK_YIELD);
        assert(fiber->flags & JANET_FIBER_BREAKPOINT);
    }
}

static void test_current_and_root_fiber(JanetFunction *add) {
    Janet args[2];
    JanetFiber *fiber;
    JanetFiber *saved_fiber = janet_vm.fiber;
    JanetFiber *saved_root = janet_vm.root_fiber;

    args[0] = janet_wrap_integer(1);
    args[1] = janet_wrap_integer(2);
    fiber = rooted_fiber(add, 2, args);

    assert(janet_current_fiber() == saved_fiber);
    assert(janet_root_fiber() == saved_root);

    janet_vm.fiber = fiber;
    janet_vm.root_fiber = NULL;
    assert(janet_current_fiber() == fiber);
    assert(janet_root_fiber() == NULL);

    janet_vm.fiber = saved_fiber;
    janet_vm.root_fiber = saved_root;
}

/* ------------------------------------------------------------------- main */

int main(void) {
    JanetFunction *add;
    JanetFunction *other;
    JanetFunction *rest;
    JanetFunction *keyed;
    JanetFunction *capturing;

    test_setcapacity_charges_the_budget();
#ifdef JANET_FIBER_CORE_THREADS
    test_budget_is_per_thread();
#endif

    janet_init();
    test_env = janet_core_env(NULL);
    janet_gcroot(janet_wrap_table(test_env));

    add = compile_function("(fn [a b] (+ a b))");
    other = compile_function("(fn [x y] (let [p (* x y) q (+ x y) r (- x y)] [p q r p q r]))");
    rest = compile_function("(fn [a & r] r)");
    keyed = compile_function("(fn [a &keys kw] kw)");
    capturing = compile_function("(fn [a b] (def unused (+ a b)) (fn [] a))");
    /* The tail-call tests need two functions of the same arity and different
     * slot counts, so that a wrong slot count shows up as a wrong stack top. */
    assert(other->def->slotcount != add->def->slotcount);

    test_funcframe_layout(add);
    test_funcframe_arity_rejection(add);
    test_funcframe_varargs(rest);
    test_funcframe_structargs(keyed);
    test_funcframe_tail(add, other);
    test_funcframe_tail_arity_rejection(add, other);
    test_funcframe_tail_varargs(add, rest);
    test_cframe_and_popframe(add);
    test_pushes(add);
    test_env_valid(add, other);
    test_env_maybe_detach(add);
    test_env_detach_honours_the_closure_bitset(capturing);
    test_status_and_resumability(add);
    test_current_and_root_fiber(add);

    janet_deinit();
    printf("fiber core contract ok\n");
    return 0;
}
