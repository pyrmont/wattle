/* Behavioral contract for the interpreter's entry points: the six functions
 * that stand above `run_vm` and decide whether, and in what state, the loop is
 * entered at all. Run against whichever implementation the build selected
 * (`-Dvm-entry=c` or the Zig default), and under either raise mechanism
 * (`-Dcall-trampoline`).
 *
 * These are the runtime's front door, and almost nothing in the Janet suites
 * looks at them directly: a suite that calls a function exercises `janet_call`
 * only in the sense that a passenger exercises an airframe. What this file
 * pins is the part the suites cannot see.
 *
 * **Reporting versus raising, per function.** Four of the six only ever return
 * a `JanetSignal`; `janet_step` and `janet_call` raise. Getting that backwards
 * for even one condition turns a recoverable error into an abort, and every
 * refusal below is asserted to arrive by the mechanism it is supposed to.
 *
 * **The messages.** Nine of them, and under the Zig selector each one crosses
 * the C variadic ABI: a `%v` holding a `Janet`, a `%d` holding an `int32_t`, a
 * `%s` holding a `const char *`. Compared byte for byte. The three arity
 * messages matter most, because they are the only place a C caller learns why
 * its call was rejected, and the three cases -- exact, minimum, maximum -- are
 * chosen by a two-branch cascade that reads plausibly when wrong.
 *
 * **The state each one leaves behind.** `janet_check_can_resume` marks the
 * fiber errored for one of its three refusals and not for the other two.
 * `janet_pcall` writes its out-parameter before it decides whether it failed.
 * `janet_call` restores `stackn`, the gc lock, and a dirty stack on the way
 * out. `janet_step` writes breakpoints into the shared bytecode and takes them
 * out again, so a function stepped once must still run normally afterwards.
 * None of that is visible in a return value and all of it is asserted.
 *
 * **The coercion.** `janet_call` sets `coerce_error`, so a signal the loop
 * hands back rather than raises -- a yield, in practice -- is turned into an
 * error with a message built here rather than in `janet_signalv`. It is the one
 * message in the runtime that names a signal, and reaching it needs a Janet
 * function called through `janet_call` rather than through `JOP_CALL`, which is
 * what the operator fallback below arranges.
 *
 * The three functions the arity messages name are given names on purpose: `%v`
 * renders an unnamed function with its address, and the point of these three
 * cases is the message, not the pointer.
 *
 * Two things are deliberately not pinned. The trace line's argument list holds
 * `%p` renderings of whatever was passed, which for a function or a table is an
 * address, so only the fixed prefix is compared. And `janet_step`'s refusal for
 * a fiber with status `:alive` is unreachable: stepping requires a fiber that
 * is not running, and there is no way to hand `janet_step` the current one
 * without going through a C frame that has already stopped being able to.
 */

#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "features.h"
#include <janet.h>
#include "fiber.h"
#include "state.h"

/* ------------------------------------------------------------------ helpers */

/* Every panic this file expects is counted, because a case that silently
 * stopped raising would otherwise look exactly like one that passed. Fixed
 * rather than a floor, and verified against -Dvm-entry=c first. */
static int panics_fired = 0;
#define EXPECTED_PANICS 7

/* Reported errors are counted separately from raised ones, which is the
 * distinction this file exists to hold: the same refusal delivered by the wrong
 * mechanism would still carry the right message. */
static int reports_fired = 0;
#define EXPECTED_REPORTS 10

static JanetTable *test_env = NULL;

/* Roots whatever it produces and never unroots it, for the reason
 * test/vm_calls.c gives: a Janet value in a C local is not a root, and these
 * live across calls that compile source and intern keywords. */
static Janet eval(const char *source) {
    Janet out = janet_wrap_nil();
    int status = janet_dostring(test_env, source, "vm-entry-test", &out);
    if (status) {
        printf("unexpected error from: %s\n", source);
        printf("                  got: %s\n", (const char *) janet_to_string(out));
        assert(0 && "expected the source to evaluate");
    }
    janet_gcroot(out);
    return out;
}

static JanetFunction *evalfn(const char *source) {
    Janet v = eval(source);
    assert(janet_checktype(v, JANET_FUNCTION));
    return janet_unwrap_function(v);
}

/* A fiber over `source`, rooted. Built with janet_fiber rather than fiber/new
 * so the default flags are the ones janet_pcall would have used. */
static JanetFiber *fiber_over(const char *source) {
    JanetFiber *fiber = janet_fiber(evalfn(source), 64, 0, NULL);
    assert(fiber != NULL);
    janet_gcroot(janet_wrap_fiber(fiber));
    return fiber;
}

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

/* A refusal that arrives as a value. `sig` and `out` are the caller's, already
 * filled in; this only checks that the pair says what it should. */
static void expect_report(JanetSignal sig, Janet out, const char *message) {
    assert(sig == JANET_SIGNAL_ERROR);
    if (!janet_checktype(out, JANET_STRING)) {
        printf("expected a string payload for: %s\n", message);
        assert(0 && "payload type mismatch");
    }
    if (janet_cstrcmp(janet_unwrap_string(out), message)) {
        printf("expected: %s\n     got: %s\n", message,
               (const char *) janet_unwrap_string(out));
        assert(0 && "message mismatch");
    }
    reports_fired++;
}

/* ------------------------------------------------------------------ pcall */

/* janet_pcall reports. Nothing it does raises, including the arity failure,
 * which is the whole reason janet_fiber_reset returns NULL instead of panicking
 * the way janet_fiber_funcframe's other caller does. */
static void test_pcall_reports_rather_than_raises(void) {
    Janet out = janet_wrap_nil();
    Janet args[2];
    JanetSignal sig;

    sig = janet_pcall(evalfn("(fn [] (+ 1 2))"), 0, NULL, &out, NULL);
    assert(sig == JANET_SIGNAL_OK);
    assert(janet_unwrap_integer(out) == 3);

    args[0] = janet_wrap_integer(4);
    args[1] = janet_wrap_integer(5);
    sig = janet_pcall(evalfn("(fn [a b] (* a b))"), 2, args, &out, NULL);
    assert(sig == JANET_SIGNAL_OK);
    assert(janet_unwrap_integer(out) == 20);

    sig = janet_pcall(evalfn("(fn [] (error \"boom\"))"), 0, NULL, &out, NULL);
    expect_report(sig, out, "boom");

    /* The fiber janet_pcall builds masks yield, so a yield comes back as a
     * signal rather than propagating past it. */
    sig = janet_pcall(evalfn("(fn [] (yield 7) 8)"), 0, NULL, &out, NULL);
    assert(sig == JANET_SIGNAL_YIELD);
    assert(janet_unwrap_integer(out) == 7);
}

/* The out-parameter is written before the NULL check, so a caller that reuses a
 * fiber across calls sees it cleared by the failure rather than left pointing
 * at the previous one. */
static void test_pcall_with_a_reused_fiber(void) {
    Janet out = janet_wrap_nil();
    JanetFiber *f = NULL;
    JanetFiber *first;
    JanetSignal sig;

    sig = janet_pcall(evalfn("(fn [] 1)"), 0, NULL, &out, &f);
    assert(sig == JANET_SIGNAL_OK);
    assert(f != NULL);
    first = f;
    janet_gcroot(janet_wrap_fiber(f));

    sig = janet_pcall(evalfn("(fn [] 2)"), 0, NULL, &out, &f);
    assert(sig == JANET_SIGNAL_OK);
    assert(f == first && "a supplied fiber is reset, not replaced");
    assert(janet_unwrap_integer(out) == 2);

    /* Too few arguments for a fixed arity: the frame cannot be built, and the
     * report is a bare "arity mismatch" with no detail, unlike janet_call's. */
    sig = janet_pcall(evalfn("(fn [a b] a)"), 0, NULL, &out, &f);
    expect_report(sig, out, "arity mismatch");
    assert(f == NULL && "the out-parameter is written before the NULL check");
}

/* --------------------------------------------------------- can-resume gate */

static void test_resuming_a_fiber_that_cannot_be(void) {
    Janet out = janet_wrap_nil();
    JanetFiber *fiber = fiber_over("(fn [] 1)");
    JanetSignal sig;

    sig = janet_continue(fiber, janet_wrap_nil(), &out);
    assert(sig == JANET_SIGNAL_OK);
    assert(janet_fiber_status(fiber) == JANET_STATUS_DEAD);

    sig = janet_continue(fiber, janet_wrap_nil(), &out);
    expect_report(sig, out, "cannot resume fiber with status :dead");

    /* An unmasked user signal leaves the fiber in the matching status, which is
     * inside the band the gate refuses. */
    fiber = fiber_over("(fn [] (signal 0 :stopped))");
    sig = janet_continue(fiber, janet_wrap_nil(), &out);
    assert(sig == JANET_SIGNAL_USER0);
    assert(janet_fiber_status(fiber) == JANET_STATUS_USER0);
    sig = janet_continue(fiber, janet_wrap_nil(), &out);
    expect_report(sig, out, "cannot resume fiber with status :user0");
}

/* The recursion refusal is the only one of the three that marks the fiber, and
 * the mark is what stops a caller from retrying the same fiber forever. */
static void test_the_recursion_guard_marks_the_fiber(void) {
    Janet out = janet_wrap_nil();
    JanetFiber *fiber = fiber_over("(fn [] 1)");
    int saved = janet_vm.stackn;
    JanetSignal sig;

    assert(janet_fiber_status(fiber) == JANET_STATUS_NEW);
    janet_vm.stackn = JANET_RECURSION_GUARD;
    sig = janet_continue(fiber, janet_wrap_nil(), &out);
    janet_vm.stackn = saved;

    expect_report(sig, out, "C stack recursed too deeply");
    assert(janet_fiber_status(fiber) == JANET_STATUS_ERROR);
}

/* janet_continue_signal injects the signal into the fiber before resuming it,
 * so the fiber wakes where it yielded and raises there rather than receiving a
 * value. Nothing else in the tree reaches janet_signal_inject from outside the
 * loop. */
static void test_cancelling_a_suspended_fiber(void) {
    Janet out = janet_wrap_nil();
    JanetFiber *fiber = fiber_over("(fn [] (yield 1) :finished)");
    JanetSignal sig = janet_continue(fiber, janet_wrap_nil(), &out);
    assert(sig == JANET_SIGNAL_YIELD);
    assert(janet_unwrap_integer(out) == 1);

    sig = janet_continue_signal(fiber, janet_cstringv("stop"), &out, JANET_SIGNAL_ERROR);
    expect_report(sig, out, "stop");
    assert(janet_fiber_status(fiber) == JANET_STATUS_ERROR);

    /* JANET_SIGNAL_OK injects nothing and resumes normally, which is the branch
     * that keeps janet_continue_signal from being janet_continue with an extra
     * argument. */
    fiber = fiber_over("(fn [] (yield 1) :finished)");
    assert(janet_continue(fiber, janet_wrap_nil(), &out) == JANET_SIGNAL_YIELD);
    sig = janet_continue_signal(fiber, janet_wrap_nil(), &out, JANET_SIGNAL_OK);
    assert(sig == JANET_SIGNAL_OK);
    assert(!janet_cstrcmp(janet_unwrap_keyword(out), "finished"));
}

/* ------------------------------------------------------------------- step */

/* Stepping walks the bytecode by writing a breakpoint bit into it and taking it
 * out again. The bit lives in the funcdef, which every fiber over that function
 * shares, so a step that failed to restore one would leave a permanent
 * breakpoint behind -- which is what the second half of each case checks. */
#define MAX_STOPS 256

/* Steps until the fiber finishes, recording the bytecode offset it stopped at
 * each time. The offsets are the subject: a step count says only that stepping
 * happened, while the offsets say which instructions it visited. */
static int step_to_completion(JanetFiber *fiber, Janet *out, int32_t *stops) {
    JanetFuncDef *def = janet_stack_frame(fiber->data + fiber->frame)->func->def;
    int nstops = 0;
    JanetSignal sig;
    do {
        sig = janet_step(fiber, janet_wrap_nil(), out);
        if (sig == JANET_SIGNAL_DEBUG) {
            assert(nstops < MAX_STOPS);
            stops[nstops++] = (int32_t)(janet_stack_frame(fiber->data + fiber->frame)->pc
                                        - def->bytecode);
        }
        assert(nstops < MAX_STOPS && "stepping did not terminate");
    } while (sig == JANET_SIGNAL_DEBUG);
    assert(sig == JANET_SIGNAL_OK);
    return nstops;
}

static int stopped_at(const int32_t *stops, int count, int32_t offset) {
    int i;
    for (i = 0; i < count; i++) if (stops[i] == offset) return 1;
    return 0;
}

static void test_stepping_straight_line_code(void) {
    /* Four instructions, no jumps: two loads, an add and a return. */
    const char *source = "(fn [] (let [a 1 b 2] (+ a b)))";
    Janet out = janet_wrap_nil();
    JanetFiber *fiber = fiber_over(source);
    JanetFunction *fun = janet_stack_frame(fiber->data + fiber->frame)->func;
    int32_t stops[MAX_STOPS];
    int nstops = step_to_completion(fiber, &out, stops);
    int32_t i;

    /* Every instruction after the first is stopped at, in order. The first is
     * executed by the step that installs the breakpoint on the second, and the
     * last is a return, which is one of the four opcodes janet_step declines to
     * set a breakpoint past. */
    assert(nstops == fun->def->bytecode_length - 1);
    for (i = 0; i < nstops; i++) {
        assert(stops[i] == i + 1 && "stepping visits every instruction in order");
    }
    assert(janet_unwrap_integer(out) == 3);

    /* The same funcdef, run without stepping: every breakpoint was taken out. */
    assert(janet_pcall(fun, 0, NULL, &out, NULL) == JANET_SIGNAL_OK);
    assert(janet_unwrap_integer(out) == 3);
}

/* A branch has two candidate successors, and both get a breakpoint. That is the
 * only place `nextb` is ever set, and it is the difference between stepping a
 * program and stepping the parts of it that fall through.
 *
 * Asserted structurally rather than by counting steps. The step count does
 * separate the two -- nineteen with the second breakpoint, fifteen without --
 * but it pins the compiler's instruction selection for one expression rather
 * than the property being tested. What is tested instead is that both
 * successors of the conditional jump are among the offsets stepping stopped at.
 */
static void test_stepping_across_branches(void) {
    const char *source = "(fn [] (var i 0) (while (< i 3) (++ i)) (if (= i 3) :yes :no))";
    Janet out = janet_wrap_nil();
    JanetFiber *fiber = fiber_over(source);
    JanetFunction *fun = janet_stack_frame(fiber->data + fiber->frame)->func;
    JanetFuncDef *def = fun->def;
    int32_t stops[MAX_STOPS];
    int nstops = step_to_completion(fiber, &out, stops);
    int32_t i, cond = -1, fallthrough, target;

    assert(janet_checktype(out, JANET_KEYWORD));
    assert(!janet_cstrcmp(janet_unwrap_keyword(out), "yes"));

    /* Every Janet instruction is one word, so the bytecode can be scanned
     * directly for the first conditional jump. */
    for (i = 0; i < def->bytecode_length; i++) {
        uint32_t op = def->bytecode[i] & 0x7F;
        if (op == JOP_JUMP_IF || op == JOP_JUMP_IF_NOT) {
            cond = i;
            break;
        }
    }
    assert(cond >= 0 && "the loop condition compiles to a conditional jump");
    fallthrough = cond + 1;
    target = cond + (((int32_t) def->bytecode[cond]) >> 16);
    assert(stopped_at(stops, nstops, fallthrough) && "stepped into the fallthrough");
    assert(stopped_at(stops, nstops, target) && "stepped into the branch target");

    /* The same funcdef, run without stepping: every breakpoint was taken out. */
    assert(janet_pcall(fun, 0, NULL, &out, NULL) == JANET_SIGNAL_OK);
    assert(!janet_cstrcmp(janet_unwrap_keyword(out), "yes"));
}

/* Stepping raises, where resuming reports, and it refuses a different set of
 * statuses: a fiber suspended on a user signal can be stepped, while a dead one
 * cannot. */
static void test_stepping_a_fiber_that_cannot_be(void) {
    Janet out = janet_wrap_nil();
    JanetFiber *dead = fiber_over("(fn [] 1)");
    JanetFiber *errored = fiber_over("(fn [] (error \"boom\"))");

    assert(janet_continue(dead, janet_wrap_nil(), &out) == JANET_SIGNAL_OK);
    EXPECT_PANIC(janet_step(dead, janet_wrap_nil(), &out),
                 "cannot step fiber with status :dead");

    assert(janet_continue(errored, janet_wrap_nil(), &out) == JANET_SIGNAL_ERROR);
    EXPECT_PANIC(janet_step(errored, janet_wrap_nil(), &out),
                 "cannot step fiber with status :error");
}

/* ----------------------------------------------------------- entry checks */

/* Both entry conditions raise, and both are reachable only from outside a
 * running fiber or with the recursion counter already at its limit. */
static void test_calling_without_a_fiber(void) {
    JanetFunction *fun = evalfn("(fn [] 1)");
    assert(janet_vm.fiber == NULL && "top level runs outside any fiber");
    EXPECT_PANIC(janet_call(fun, 0, NULL),
                 "janet_call failed because there is no current fiber");
}

/* ------------------------------------------------- inside a running fiber */

/* Five things need janet_vm.fiber to be set, and the only honest way to get
 * that is to be called by the interpreter. */
static Janet cfun_probe(int32_t argc, Janet *argv) {
    Janet out = janet_wrap_nil();
    JanetFiber *self;
    JanetFunction *fun;
    Janet args[2];
    int saved;
    JanetSignal sig;

    janet_fixarity(argc, 0);
    (void) argv;
    self = janet_vm.fiber;
    assert(self != NULL);

    /* The fiber running this cfunction is alive, and the gate refuses it. */
    sig = janet_continue(self, janet_wrap_nil(), &out);
    expect_report(sig, out, "cannot resume fiber with status :alive");

    /* A fiber marked as a task belongs to the scheduler, and the refusal names
     * the scheduler's own entry points when there is one. */
    {
        JanetFiber *rooted = fiber_over("(fn [] 1)");
        rooted->gc.flags |= JANET_FIBER_FLAG_ROOT;
#ifdef JANET_EV
        sig = janet_continue(rooted, janet_wrap_nil(), &out);
        expect_report(sig, out, "cannot resume root fiber, use ev/go");
        sig = janet_continue_signal(rooted, janet_wrap_nil(), &out, JANET_SIGNAL_ERROR);
        expect_report(sig, out, "cannot cancel root fiber, use ev/cancel");
#else
        sig = janet_continue(rooted, janet_wrap_nil(), &out);
        expect_report(sig, out, "cannot resume root fiber");
        sig = janet_continue_signal(rooted, janet_wrap_nil(), &out, JANET_SIGNAL_ERROR);
        expect_report(sig, out, "cannot cancel root fiber");
#endif
    }

    /* The three arity messages. The cascade that picks between them tests
     * `min == max` first, then a minimum, and falls through to a maximum, so
     * all three shapes have to be present for any of them to be trusted. */
    fun = evalfn("(do (defn exactly-two [a b] a) exactly-two)");
    args[0] = janet_wrap_integer(1);
    args[1] = janet_wrap_integer(2);
    EXPECT_PANIC(janet_call(fun, 1, args),
                 "arity mismatch in <function exactly-two>, expected 2, got 1");

    /* janet_call raises on its own entry condition too, and does it before
     * touching the fiber. */
    saved = janet_vm.stackn;
    janet_vm.stackn = JANET_RECURSION_GUARD;
    EXPECT_PANIC(janet_call(fun, 2, args), "C stack recursed too deeply");
    janet_vm.stackn = saved;

    /* A dirty stack: values pushed above stackstart that janet_call must not
     * overwrite. It pushes a guard frame to protect them and pops it again, so
     * both the pushed value and the two stack marks survive the call. */
    {
        int32_t top_before, start_before;
        Janet result;
        janet_fiber_push(self, janet_wrap_integer(99));
        start_before = self->stackstart;
        top_before = self->stacktop;
        args[0] = janet_wrap_integer(4);
        result = janet_call(evalfn("(fn [x] (* x 10))"), 1, args);
        assert(janet_unwrap_integer(result) == 40);
        assert(self->stackstart == start_before && "stackstart restored");
        assert(self->stacktop == top_before && "stacktop restored");
        assert(janet_unwrap_integer(self->data[top_before - 1]) == 99);
        self->stacktop = start_before;
    }

    /* The gc lock is balanced across a successful call. */
    {
        int before = janet_vm.gc_suspend;
        args[0] = janet_wrap_integer(3);
        (void) janet_call(evalfn("(fn [x] (+ x 1))"), 1, args);
        assert(janet_vm.gc_suspend == before && "the gc lock is released");
        assert(janet_vm.stackn == saved && "stackn is restored");
    }

    return janet_wrap_nil();
}

static Janet cfun_arity_variants(int32_t argc, Janet *argv) {
    JanetFunction *fun;
    Janet args[3];
    janet_fixarity(argc, 0);
    (void) argv;

    args[0] = janet_wrap_integer(1);
    args[1] = janet_wrap_integer(2);
    args[2] = janet_wrap_integer(3);

    fun = evalfn("(do (defn at-least-two [a b & rest] a) at-least-two)");
    EXPECT_PANIC(janet_call(fun, 1, args),
                 "arity mismatch in <function at-least-two>, expected at least 2, got 1");

    fun = evalfn("(do (defn at-most-two [&opt a b] a) at-most-two)");
    EXPECT_PANIC(janet_call(fun, 3, args),
                 "arity mismatch in <function at-most-two>, expected at most 2, got 3");

    return janet_wrap_nil();
}

static const JanetReg cfuns[] = {
    {"vmentry/probe", cfun_probe, NULL},
    {"vmentry/arity", cfun_arity_variants, NULL},
    {NULL, NULL, NULL}
};

/* ------------------------------------------------------- the coercion path */

/* janet_call sets coerce_error, so a signal the loop returns rather than raises
 * becomes an error with a message naming the signal it came from. Reaching it
 * needs a Janet function entered through janet_call, which the binary operator
 * fallback arranges: `(+ t 1)` on a table looks up `:+` and invokes it as a
 * method, and janet_method_invoke calls janet_call for a Janet function. */
static void test_a_signal_the_loop_returns_is_coerced(void) {
    Janet out = janet_wrap_nil();
    JanetSignal sig = janet_pcall(
                          evalfn("(fn [] (def t @{:+ (fn [self other] (yield 5))}) (+ t 1))"),
                          0, NULL, &out, NULL);
    expect_report(sig, out, "5 coerced from yield to error");
}

/* ------------------------------------------------------------- the tracing */

/* The trace line goes through janet_eprintf, which writes to the `:err` dynamic
 * binding when it holds a buffer. Only the prefix is compared: the argument list
 * renders a table and a function with %p, and both carry addresses. */
static void test_a_traced_call(void) {
    Janet named = eval(
                      "(do (def buf @\"\")"
                      "    (defn adder [self other] 5)"
                      "    (trace adder)"
                      "    (def t @{:+ adder})"
                      "    (with-dyns [:err buf] (+ t 1))"
                      "    (string buf))");
    const char *text = (const char *) janet_unwrap_string(named);
    if (strncmp(text, "trace (adder ", 13)) {
        printf("expected a trace line for a named function, got: %s\n", text);
        assert(0 && "trace prefix mismatch");
    }
    assert(text[strlen(text) - 1] == '\n');
    assert(text[strlen(text) - 2] == ')');

    {
        Janet anon = eval(
                         "(do (def buf @\"\")"
                         "    (def t @{:+ (trace (fn [self other] 5))})"
                         "    (with-dyns [:err buf] (+ t 1))"
                         "    (string buf))");
        const char *anon_text = (const char *) janet_unwrap_string(anon);
        if (strncmp(anon_text, "trace (<function", 16)) {
            printf("expected a trace line for an unnamed function, got: %s\n", anon_text);
            assert(0 && "trace prefix mismatch");
        }
    }
}

/* ------------------------------------------------------------------- entry */

int main(void) {
    janet_init();
    test_env = janet_core_env(NULL);
    janet_cfuns(test_env, NULL, cfuns);

    test_pcall_reports_rather_than_raises();
    test_pcall_with_a_reused_fiber();

    test_resuming_a_fiber_that_cannot_be();
    test_the_recursion_guard_marks_the_fiber();
    test_cancelling_a_suspended_fiber();

    test_stepping_straight_line_code();
    test_stepping_across_branches();
    test_stepping_a_fiber_that_cannot_be();

    test_calling_without_a_fiber();

    /* Everything that needs a running fiber underneath it. */
    (void) eval("(vmentry/probe)");
    (void) eval("(vmentry/arity)");

    test_a_signal_the_loop_returns_is_coerced();
    test_a_traced_call();

    if (panics_fired != EXPECTED_PANICS) {
        printf("expected %d panics, counted %d\n", EXPECTED_PANICS, panics_fired);
        assert(0 && "panic count mismatch");
    }
    if (reports_fired != EXPECTED_REPORTS) {
        printf("expected %d reports, counted %d\n", EXPECTED_REPORTS, reports_fired);
        assert(0 && "report count mismatch");
    }

    janet_deinit();
    printf("vm entry contract ok (%d panics, %d reports)\n", panics_fired, reports_fired);
    return 0;
}
