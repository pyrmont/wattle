/* Behavioral contract for the try scope, the signal decision, and the signal
 * injection, run against whichever implementation the build selected
 * (`-Dsignal-core=c` or the Zig default).
 *
 * The reason this file exists rather than leaning on the Janet suites: the
 * suites exercise these paths constantly but observe almost none of them. Every
 * `try` in Janet opens a scope and every `error` raises through the plan, yet
 * what a program can see afterwards is the payload alone. Whether `stackn` came
 * back to the value it started from, whether `coerce_error` was cleared inside
 * the scope and restored outside it, which of fourteen signals coerce and which
 * do not, and whether the injected signal reached the innermost fiber of a
 * chain, are all invisible from Janet and all load-bearing.
 *
 * The file includes `state.h` and `fiber.h`. It has to: the six VM fields a
 * scope saves and the two fiber flag words it writes are the subject.
 */

#include <assert.h>
#include <setjmp.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "features.h"
#include <janet.h>
#include "fiber.h"
#include "state.h"

static JanetTable *test_env;

/* Signals run from OK to USER9; INTERRUPT and EVENT are aliases of USER8 and
 * USER9 rather than values of their own, so counting the enum would overcount. */
#define SIGNAL_COUNT (JANET_SIGNAL_USER9 + 1)

static JanetFunction *compile_function(const char *source) {
    Janet out = janet_wrap_nil();
    int status = janet_dostring(test_env, source, "signal-core-test", &out);
    assert(status == 0);
    assert(janet_checktype(out, JANET_FUNCTION));
    janet_gcroot(out);
    return janet_unwrap_function(out);
}

static JanetFiber *rooted_fiber(JanetFunction *func) {
    JanetFiber *fiber = janet_fiber(func, 32, 0, NULL);
    assert(fiber != NULL);
    janet_gcroot(janet_wrap_fiber(fiber));
    return fiber;
}

/* ------------------------------------------------------------- try scopes */

/* A scope saves six fields, redirects three, and hands all six back. The two
 * halves are tested together because a save that is never restored is not a
 * scope, and each field is checked for the value it should hold rather than for
 * having merely changed. */
static void test_try_scope_saves_redirects_and_restores(void) {
    JanetTryState state;
    int old_stackn = janet_vm.stackn;
    int old_gc_suspend = janet_vm.gc_suspend;
    JanetFiber *old_fiber = janet_vm.fiber;
    jmp_buf *old_signal_buf = janet_vm.signal_buf;
    Janet *old_return_reg = janet_vm.return_reg;
    int old_coerce_error = janet_vm.coerce_error;

    /* Set so that clearing it inside the scope is visible. */
    janet_vm.coerce_error = 1;

    janet_try_init(&state);

    assert(state.stackn == old_stackn);
    assert(state.gc_handle == old_gc_suspend);
    assert(state.vm_fiber == old_fiber);
    assert(state.vm_jmp_buf == old_signal_buf);
    assert(state.vm_return_reg == old_return_reg);
    assert(state.coerce_error == 1);

    /* The recursion counter advances by exactly one. The C original writes this
     * as a post-increment, so the state holds the old value and the VM the new;
     * getting it backwards would leak one JANET_RECURSION_GUARD level per
     * scope, which nothing else here would notice. */
    assert(janet_vm.stackn == old_stackn + 1);

    assert(janet_vm.return_reg == &state.payload);
    assert(janet_vm.signal_buf == &state.buf);
    assert(janet_vm.coerce_error == 0);

    /* Whatever the scope's body did to the saved fields is undone rather than
     * merged. gc_suspend is the one that matters in practice: a callee that
     * locked the collector and then raised has its lock released here. */
    janet_vm.gc_suspend = old_gc_suspend + 7;
    janet_vm.stackn += 3;
    janet_vm.coerce_error = 1;

    janet_restore(&state);

    assert(janet_vm.stackn == old_stackn);
    assert(janet_vm.gc_suspend == old_gc_suspend);
    assert(janet_vm.fiber == old_fiber);
    assert(janet_vm.signal_buf == old_signal_buf);
    assert(janet_vm.return_reg == old_return_reg);
    assert(janet_vm.coerce_error == 1);

    janet_vm.coerce_error = old_coerce_error;
}

/* Scopes nest, and the inner one's saved fields are the outer one's live
 * fields. This is the property a fiber resumed from a different native frame
 * depends on: each resume opens a fresh scope over whatever the last one left. */
static void test_try_scopes_nest(void) {
    JanetTryState outer, inner;
    int base = janet_vm.stackn;
    int old_coerce_error = janet_vm.coerce_error;

    janet_try_init(&outer);
    assert(janet_vm.stackn == base + 1);

    janet_try_init(&inner);
    assert(janet_vm.stackn == base + 2);
    assert(inner.vm_jmp_buf == &outer.buf);
    assert(inner.vm_return_reg == &outer.payload);

    janet_restore(&inner);
    assert(janet_vm.stackn == base + 1);
    assert(janet_vm.signal_buf == &outer.buf);
    assert(janet_vm.return_reg == &outer.payload);

    janet_restore(&outer);
    assert(janet_vm.stackn == base);
    janet_vm.coerce_error = old_coerce_error;
}

/* The scope and the raise, end to end through the public macro: janet_try
 * fills the buffer in this frame, janet_panic decides and jumps, and the
 * payload arrives in the scope's own slot. Neither half is much use without
 * the other, and this is the only test here that involves an actual longjmp. */
static void test_try_catches_a_panic(void) {
    JanetTryState state;
    int base = janet_vm.stackn;
    JanetSignal sig = janet_try(&state);
    if (!sig) {
        janet_panic("caught me");
    }
    janet_restore(&state);
    assert(sig == JANET_SIGNAL_ERROR);
    assert(janet_checktype(state.payload, JANET_STRING));
    assert(!janet_cstrcmp(janet_unwrap_string(state.payload), "caught me"));
    assert(janet_vm.stackn == base);
}

/* ------------------------------------------------------------ the decision */

/* No return register means no jump target, so nothing is decided and nothing is
 * coerced: the caller reports at top level with the message it was given. */
static void test_plan_without_a_return_register(void) {
    Janet *old_return_reg = janet_vm.return_reg;
    int old_coerce_error = janet_vm.coerce_error;
    JanetSignal out = JANET_SIGNAL_OK;

    janet_vm.return_reg = NULL;
    /* Set so that a plan which consulted it before the null test would show. */
    janet_vm.coerce_error = 1;

    assert(janet_signal_plan(JANET_SIGNAL_YIELD, &out) == JANET_SIGNAL_PLAN_TOP_LEVEL);
    assert(out == JANET_SIGNAL_YIELD);

    janet_vm.return_reg = old_return_reg;
    janet_vm.coerce_error = old_coerce_error;
}

/* Outside a coercing scope every signal passes through unchanged. All fourteen
 * are checked rather than a representative few, because the coercion branch
 * below distinguishes three groups among them and the pass-through branch must
 * distinguish none. */
static void test_plan_without_coercion(void) {
    Janet reg = janet_wrap_nil();
    Janet *old_return_reg = janet_vm.return_reg;
    int old_coerce_error = janet_vm.coerce_error;
    int s;

    janet_vm.return_reg = &reg;
    janet_vm.coerce_error = 0;

    for (s = 0; s < SIGNAL_COUNT; s++) {
        JanetSignal out = JANET_SIGNAL_OK;
        assert(janet_signal_plan((JanetSignal) s, &out) == JANET_SIGNAL_PLAN_RAISE);
        assert(out == (JanetSignal) s);
    }

    janet_vm.return_reg = old_return_reg;
    janet_vm.coerce_error = old_coerce_error;
}

/* Inside a coercing scope the fourteen signals fall into three groups, and the
 * plan reports a different answer for each. OK is not an error and is left
 * alone; ERROR is already one and needs no message; everything else becomes an
 * error and needs the message the caller formats. */
static void test_plan_coerces(void) {
    Janet reg = janet_wrap_nil();
    Janet *old_return_reg = janet_vm.return_reg;
    int old_coerce_error = janet_vm.coerce_error;
    JanetSignal out;
    int s;

    janet_vm.return_reg = &reg;
    janet_vm.coerce_error = 1;

    out = JANET_SIGNAL_YIELD;
    assert(janet_signal_plan(JANET_SIGNAL_OK, &out) == JANET_SIGNAL_PLAN_RAISE);
    assert(out == JANET_SIGNAL_OK);

    out = JANET_SIGNAL_YIELD;
    assert(janet_signal_plan(JANET_SIGNAL_ERROR, &out) == JANET_SIGNAL_PLAN_RAISE);
    assert(out == JANET_SIGNAL_ERROR);

    for (s = JANET_SIGNAL_DEBUG; s < SIGNAL_COUNT; s++) {
        out = JANET_SIGNAL_OK;
        assert(janet_signal_plan((JanetSignal) s, &out) == JANET_SIGNAL_PLAN_COERCE);
        assert(out == JANET_SIGNAL_ERROR);
    }

    janet_vm.return_reg = old_return_reg;
    janet_vm.coerce_error = old_coerce_error;
}

#ifdef JANET_EV

/* An EVENT signal coerced to an error invalidates the root fiber's scheduling
 * id, so that a callback which completes later cannot resume a fiber that has
 * already moved on. The bump belongs to the plan rather than to its caller
 * because it has to happen before the coercion message is built: building that
 * message can panic, and the re-entrant raise must find the counter already
 * advanced.
 *
 * Three conditions gate it and each is checked separately, since any one of
 * them dropped would leave the common path working. */
static void test_plan_bumps_the_root_fiber(JanetFunction *nothing) {
    Janet reg = janet_wrap_nil();
    Janet *old_return_reg = janet_vm.return_reg;
    int old_coerce_error = janet_vm.coerce_error;
    JanetFiber *old_root_fiber = janet_vm.root_fiber;
    JanetFiber *fiber = rooted_fiber(nothing);
    JanetSignal out;
    uint32_t base;

    janet_vm.return_reg = &reg;
    janet_vm.coerce_error = 1;
    janet_vm.root_fiber = fiber;
    base = fiber->sched_id;

    assert(janet_signal_plan(JANET_SIGNAL_EVENT, &out) == JANET_SIGNAL_PLAN_COERCE);
    assert(fiber->sched_id == base + 1);

    /* Only EVENT. */
    assert(janet_signal_plan(JANET_SIGNAL_YIELD, &out) == JANET_SIGNAL_PLAN_COERCE);
    assert(fiber->sched_id == base + 1);

    /* Only while coercing. */
    janet_vm.coerce_error = 0;
    assert(janet_signal_plan(JANET_SIGNAL_EVENT, &out) == JANET_SIGNAL_PLAN_RAISE);
    assert(fiber->sched_id == base + 1);

    /* Only with a root fiber - and without one it must not dereference null. */
    janet_vm.coerce_error = 1;
    janet_vm.root_fiber = NULL;
    assert(janet_signal_plan(JANET_SIGNAL_EVENT, &out) == JANET_SIGNAL_PLAN_COERCE);
    assert(fiber->sched_id == base + 1);

    janet_vm.root_fiber = old_root_fiber;
    janet_vm.return_reg = old_return_reg;
    janet_vm.coerce_error = old_coerce_error;
    janet_gcunroot(janet_wrap_fiber(fiber));
}

#endif /* JANET_EV */

/* The commit publishes the payload and marks the fiber. The flag is not
 * bookkeeping: a resume reads it to pop a C frame and to turn a raise at a tail
 * call into an implicit return, so a raise that skipped it would resume
 * differently from one that set it. */
static void test_commit_publishes_and_marks(JanetFunction *nothing) {
    Janet reg = janet_wrap_nil();
    Janet message = janet_cstringv("payload");
    Janet *old_return_reg = janet_vm.return_reg;
    JanetFiber *old_fiber = janet_vm.fiber;
    JanetFiber *fiber = rooted_fiber(nothing);

    janet_gcroot(message);
    fiber->flags &= ~JANET_FIBER_DID_LONGJUMP;
    janet_vm.return_reg = &reg;
    janet_vm.fiber = fiber;

    janet_signal_commit(&message);
    assert(janet_equals(reg, message));
    assert(fiber->flags & JANET_FIBER_DID_LONGJUMP);

    /* With no current fiber the register is still written and nothing is
     * dereferenced. janet_signalv reaches this whenever a panic is raised
     * outside any fiber at all. */
    reg = janet_wrap_nil();
    janet_vm.fiber = NULL;
    janet_signal_commit(&message);
    assert(janet_equals(reg, message));

    janet_vm.fiber = old_fiber;
    janet_vm.return_reg = old_return_reg;
    janet_gcunroot(message);
    janet_gcunroot(janet_wrap_fiber(fiber));
}

/* ------------------------------------------------------------- injection */

/* An injected signal goes to the innermost fiber of the chain, not to the one
 * named, and it travels in gc.flags while the resume flag travels in flags.
 * That split is deliberate - run_vm reads the signal back out of gc.flags and
 * clears it there - and a port that "tidied" it into one word would compile,
 * pass the suites, and deliver every injected signal as status NEW. */
static void test_inject_reaches_the_innermost_fiber(JanetFunction *nothing) {
    JanetFiber *parent = rooted_fiber(nothing);
    JanetFiber *child = rooted_fiber(nothing);
    JanetFiber *grandchild = rooted_fiber(nothing);
    int32_t parent_flags, child_flags;

    parent->child = child;
    child->child = grandchild;

    /* Preload the carrier so that a plan which only ORs shows up. */
    grandchild->gc.flags |= JANET_FIBER_STATUS_MASK;
    parent_flags = parent->flags;
    child_flags = child->flags;

    janet_signal_inject(parent, JANET_SIGNAL_USER3);

    assert(grandchild->flags & JANET_FIBER_RESUME_SIGNAL);
    assert(((grandchild->gc.flags & JANET_FIBER_STATUS_MASK) >> JANET_FIBER_STATUS_OFFSET)
           == JANET_SIGNAL_USER3);

    /* The fiber's real status lives in flags and is untouched. */
    assert(janet_fiber_status(grandchild) == JANET_STATUS_NEW);

    /* Neither of the fibers above it is disturbed. */
    assert(parent->flags == parent_flags);
    assert(child->flags == child_flags);

    /* A chain of one is its own innermost fiber. */
    grandchild->gc.flags &= ~JANET_FIBER_STATUS_MASK;
    grandchild->flags &= ~JANET_FIBER_RESUME_SIGNAL;
    parent->child = NULL;
    child->child = NULL;
    janet_signal_inject(grandchild, JANET_SIGNAL_USER1);
    assert(grandchild->flags & JANET_FIBER_RESUME_SIGNAL);
    assert(((grandchild->gc.flags & JANET_FIBER_STATUS_MASK) >> JANET_FIBER_STATUS_OFFSET)
           == JANET_SIGNAL_USER1);

    grandchild->gc.flags &= ~JANET_FIBER_STATUS_MASK;
    grandchild->flags &= ~JANET_FIBER_RESUME_SIGNAL;
    janet_gcunroot(janet_wrap_fiber(grandchild));
    janet_gcunroot(janet_wrap_fiber(child));
    janet_gcunroot(janet_wrap_fiber(parent));
}

/* The injection and the resume that consumes it, end to end. This is what
 * ev/cancel is built on, and it is the only check here that the carrier the
 * injection writes is the one run_vm reads. */
static void test_continue_signal_delivers_an_error(JanetFunction *yielder) {
    JanetFiber *fiber = rooted_fiber(yielder);
    Janet out = janet_wrap_nil();
    JanetSignal sig;

    sig = janet_continue(fiber, janet_wrap_nil(), &out);
    assert(sig == JANET_SIGNAL_YIELD);

    sig = janet_continue_signal(fiber, janet_cstringv("cancelled"), &out, JANET_SIGNAL_ERROR);
    assert(sig == JANET_SIGNAL_ERROR);
    assert(janet_checktype(out, JANET_STRING));
    assert(!janet_cstrcmp(janet_unwrap_string(out), "cancelled"));

    janet_gcunroot(janet_wrap_fiber(fiber));
}

/* A signal of OK is not injected at all: janet_continue_signal resumes
 * normally, and the fiber sees the value rather than a raise. */
static void test_continue_signal_ok_is_an_ordinary_resume(JanetFunction *yielder) {
    JanetFiber *fiber = rooted_fiber(yielder);
    Janet out = janet_wrap_nil();
    JanetSignal sig;

    sig = janet_continue(fiber, janet_wrap_nil(), &out);
    assert(sig == JANET_SIGNAL_YIELD);

    sig = janet_continue_signal(fiber, janet_wrap_integer(7), &out, JANET_SIGNAL_OK);
    assert(sig == JANET_SIGNAL_OK);
    assert(janet_checktype(out, JANET_NUMBER));
    assert(janet_unwrap_integer(out) == 7);

    janet_gcunroot(janet_wrap_fiber(fiber));
}

/* ------------------------------------------------------------------- main */

int main(void) {
    JanetFunction *nothing;
    JanetFunction *yielder;

    janet_init();
    test_env = janet_core_env(NULL);
    janet_gcroot(janet_wrap_table(test_env));

    nothing = compile_function("(fn [] nil)");
    /* Yields once, then returns whatever it was resumed with. */
    yielder = compile_function("(fn [] (yield 1))");

    test_try_scope_saves_redirects_and_restores();
    test_try_scopes_nest();
    test_try_catches_a_panic();

    test_plan_without_a_return_register();
    test_plan_without_coercion();
    test_plan_coerces();
#ifdef JANET_EV
    test_plan_bumps_the_root_fiber(nothing);
#endif
    test_commit_publishes_and_marks(nothing);

    test_inject_reaches_the_innermost_fiber(nothing);
    test_continue_signal_delivers_an_error(yielder);
    test_continue_signal_ok_is_an_ordinary_resume(yielder);

    janet_deinit();
    printf("signal core contract ok\n");
    return 0;
}
