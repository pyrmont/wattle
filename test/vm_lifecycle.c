/* Behavioral contract for the runtime's lifecycle and for the stack-frame
 * decoding behind `debug/stack`. Run against whichever implementations the
 * build selected (`-Dvm-lifecycle=c`, `-Ddebug-frames=c`, or the Zig defaults).
 *
 * Two subjects, because Phase 9's fifth increment has two.
 *
 * **`janet_init`, `janet_deinit`, and the sandbox.** These are the first and
 * last functions an embedder calls, and every other test binary in this tree
 * depends on them working without ever looking at them: a suite that reaches
 * `main` has already proved `janet_init` does *something*. What it has not
 * proved is which fields of `janet_vm` are set, which are deliberately left
 * alone, and what `janet_deinit` puts back — and those are the difference
 * between a host that can cycle the runtime and one that cannot. Every field
 * `janet_init` assigns is asserted here, in the state it leaves, and so is the
 * subset `janet_deinit` clears. A second full cycle runs afterwards, because a
 * teardown that leaks a pointer looks identical to one that does not until
 * something reuses it.
 *
 * The sandbox is four lines and one of them is a panic. It is also one-way by
 * construction — `janet_sandbox` asserts against `JANET_SANDBOX_SANDBOX`
 * before widening the flags — and the one-way property is the whole security
 * claim, so it is pinned directly rather than through a standard-library
 * function that happens to check a flag.
 *
 * **`janet_debug_frame`.** Formerly `doframe`. `debug/stack` is the only caller,
 * and what it returns is a table whose keys are the runtime's answer to "where
 * am I". The Janet suites call it and check almost nothing about it.
 *
 * One assertion here cannot run under `-Ddebug-frames=c`, and it is the reason
 * this increment exists: the C original reads the cfunction registry entry
 * without checking it for null, so decoding a cframe whose function was never
 * passed through `janet_cfuns` dereferences null. `FOUND.md` records it; the
 * port does not reproduce it, because it consumes `janet_trace_frame`, which
 * has the check. `build.zig` gives this file `JANET_ZIG_DEBUG_FRAMES` so the
 * case can be pinned where it is defined and skipped where it is not. Every
 * other assertion in the file runs under both selectors.
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

static int panics_fired = 0;
/* One of these is the sandbox refusing `asm`, which a build without
 * JANET_ASSEMBLER cannot ask for. */
#ifdef JANET_ASSEMBLER
#define EXPECTED_PANICS 4
#else
#define EXPECTED_PANICS 3
#endif

static JanetTable *test_env = NULL;

static Janet eval(const char *source) {
    Janet out = janet_wrap_nil();
    int status = janet_dostring(test_env, source, "vm-lifecycle-test", &out);
    if (status) {
        printf("unexpected error from: %s\n", source);
        printf("                  got: %s\n", (const char *) janet_to_string(out));
        assert(0 && "expected the source to evaluate");
    }
    janet_gcroot(out);
    return out;
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

/* The same refusal reached through the standard library rather than through the
 * assert directly. Wrapped in a fiber rather than handed to janet_dostring,
 * because janet_dostring prints a stack trace on the way out and catches the
 * error itself. */
#ifdef JANET_ASSEMBLER
static void expect_sandbox_refusal(const char *source) {
    char wrapped[512];
    Janet fiberv;
    Janet out = janet_wrap_nil();
    JanetSignal sig;
    int written = snprintf(wrapped, sizeof wrapped, "(fiber/new (fn [] %s) :ye)", source);
    assert(written > 0 && (size_t) written < sizeof wrapped);
    fiberv = eval(wrapped);
    sig = janet_continue(janet_unwrap_fiber(fiberv), janet_wrap_nil(), &out);
    assert(sig == JANET_SIGNAL_ERROR);
    assert(janet_checktype(out, JANET_STRING));
    if (janet_cstrcmp(janet_unwrap_string(out), "operation forbidden by sandbox")) {
        printf("got: %s\n", (const char *) janet_unwrap_string(out));
        assert(0 && "message mismatch");
    }
    panics_fired++;
}
#endif

/* A key of the table janet_debug_frame builds. */
static Janet frame_get(Janet frame, const char *key) {
    assert(janet_checktype(frame, JANET_TABLE));
    return janet_table_get(janet_unwrap_table(frame), janet_ckeywordv(key));
}

static void expect_string(Janet frame, const char *key, const char *expected) {
    Janet v = frame_get(frame, key);
    if (!janet_checktype(v, JANET_STRING) ||
            janet_cstrcmp(janet_unwrap_string(v), expected)) {
        printf("key %s: expected %s, got %s\n", key, expected,
               (const char *) janet_to_string(v));
        assert(0 && "frame key mismatch");
    }
}

static void expect_integer(Janet frame, const char *key, int32_t expected) {
    Janet v = frame_get(frame, key);
    if (!janet_checktype(v, JANET_NUMBER) || janet_unwrap_integer(v) != expected) {
        printf("key %s: expected %d, got %s\n", key, (int) expected,
               (const char *) janet_to_string(v));
        assert(0 && "frame key mismatch");
    }
}

static void expect_absent(Janet frame, const char *key) {
    Janet v = frame_get(frame, key);
    if (!janet_checktype(v, JANET_NIL)) {
        printf("key %s: expected nil, got %s\n", key,
               (const char *) janet_to_string(v));
        assert(0 && "frame key should be absent");
    }
}

/* --------------------------------------------------------------- init state */

/* janet_init assigns rather than assumes, and a host that reuses a thread — or
 * that calls it after a previous runtime was torn down by something other than
 * janet_deinit — depends on that. Every field janet_init sets is scribbled on
 * first, so the assertions below are about what init wrote rather than about
 * what a freshly zeroed janet_vm already held. */
static Janet scribble_roots[4];
static char scribble_bytes[64];

static void scribble_over_the_vm(void) {
    janet_vm.blocks = scribble_bytes;
    janet_vm.weak_blocks = scribble_bytes;
    janet_vm.next_collection = 4242;
    janet_vm.gc_interval = 99;
    janet_vm.block_count = 77;
    janet_vm.gc_mark_phase = 1;
    janet_vm.roots = scribble_roots;
    janet_vm.root_count = 3;
    janet_vm.root_capacity = 4;
    janet_vm.user = scribble_bytes;
    janet_vm.scratch_mem = (JanetScratch **) scribble_bytes;
    janet_vm.scratch_len = 5;
    janet_vm.scratch_cap = 6;
    janet_vm.sandbox_flags = JANET_SANDBOX_ASM;
    janet_vm.registry = (JanetCFunRegistry *) scribble_bytes;
    janet_vm.registry_cap = 7;
    janet_vm.registry_count = 8;
    janet_vm.registry_dirty = 1;
    janet_vm.abstract_registry = NULL;
    janet_vm.traversal = (JanetTraversalNode *) scribble_bytes;
    janet_vm.traversal_base = (JanetTraversalNode *) scribble_bytes;
    janet_vm.traversal_top = (JanetTraversalNode *) scribble_bytes;
    janet_vm.core_env = (JanetTable *) scribble_bytes;
    janet_vm.auto_suspend = 1;
    janet_vm.top_dyns = (JanetTable *) scribble_bytes;
    janet_vm.fiber = (JanetFiber *) scribble_bytes;
    janet_vm.root_fiber = (JanetFiber *) scribble_bytes;
    janet_vm.stackn = 9;
}


/* Field by field, in the state janet_init leaves. Three of these are not
 * literally what janet_init assigned: `blocks` and `next_collection` have moved
 * because the abstract registry is allocated during init, and `root_count` is
 * one because that registry is rooted. Asserting those rather than the assigned
 * values is the point — they are what the next line of an embedder's code
 * sees. */
static void test_the_state_janet_init_leaves(void) {
    scribble_over_the_vm();
    assert(janet_init() == 0);

    /* The three that would otherwise be invisible: they are zero in a freshly
     * zeroed janet_vm, so only the scribble above can tell an assignment from
     * an assumption. */
    assert(janet_vm.next_collection < 4242);
    assert(janet_vm.weak_blocks == NULL);
    assert(janet_vm.block_count == 1);

    /* Collector. */
    assert(janet_vm.gc_interval == 0x400000);
    assert(janet_vm.gc_mark_phase == 0);
    assert(janet_vm.weak_blocks == NULL);
    assert(janet_vm.blocks != NULL && "the abstract registry is allocated during init");
    assert(janet_vm.block_count == 1);

    /* Roots: empty except for the abstract registry. */
    assert(janet_vm.roots != NULL);
    assert(janet_vm.root_count == 1);
    assert(janet_vm.abstract_registry != NULL);
    assert(janet_equals(janet_vm.roots[0], janet_wrap_table(janet_vm.abstract_registry)));

    /* Scratch memory. */
    assert(janet_vm.user == NULL);
    assert(janet_vm.scratch_mem == NULL);
    assert(janet_vm.scratch_len == 0);
    assert(janet_vm.scratch_cap == 0);

    /* Sandbox. */
    assert(janet_vm.sandbox_flags == 0);

    /* Cfunction registry: empty, and not yet sorted. */
    assert(janet_vm.registry == NULL);
    assert(janet_vm.registry_cap == 0);
    assert(janet_vm.registry_count == 0);
    assert(janet_vm.registry_dirty == 0);

    /* Traversal, used by marshalling. */
    assert(janet_vm.traversal == NULL);
    assert(janet_vm.traversal_base == NULL);
    assert(janet_vm.traversal_top == NULL);

    /* Environments and fibers. */
    assert(janet_vm.core_env == NULL && "the core env is built lazily");
    assert(janet_vm.top_dyns == NULL);
    assert(janet_vm.fiber == NULL);
    assert(janet_vm.root_fiber == NULL);
    assert(janet_vm.stackn == 0);
    assert(janet_vm.auto_suspend == 0);

    /* The symbol cache belongs to janet_symcache_init, which janet_init calls
     * after the collector's fields and before the first allocation. */
    assert(janet_vm.cache != NULL);
    assert(janet_vm.cache_count == 0);
    assert(janet_vm.cache_deleted == 0);
    assert(janet_vm.cache_capacity > 0);

    janet_deinit();
}

/* What janet_deinit puts back, and what it deliberately does not touch. */
static void test_what_janet_deinit_clears(void) {
    int dummy = 0;
    assert(janet_init() == 0);
    (void) janet_core_env(NULL);
    janet_vm.user = &dummy;

    /* Preconditions, so that the assertions below are about the teardown. */
    assert(janet_vm.core_env != NULL);
    assert(janet_vm.registry != NULL);
    assert(janet_vm.roots != NULL);
    assert(janet_vm.cache_count > 0);

    janet_deinit();

    assert(janet_vm.roots == NULL);
    assert(janet_vm.root_count == 0);
    assert(janet_vm.root_capacity == 0);
    assert(janet_vm.abstract_registry == NULL);
    assert(janet_vm.core_env == NULL);
    assert(janet_vm.top_dyns == NULL);
    assert(janet_vm.user == NULL && "an embedder's pointer is dropped, not freed");
    assert(janet_vm.fiber == NULL);
    assert(janet_vm.root_fiber == NULL);
    assert(janet_vm.registry == NULL);
    assert(janet_vm.cache == NULL);
    assert(janet_vm.cache_count == 0);

    /* janet_clear_memory ran: it is the one line of janet_deinit whose effect
     * is a heap rather than a field, and this is the only field it leaves
     * behind to say so. It does not reset block_count, which is why that is not
     * asserted here. */
    assert(janet_vm.blocks == NULL);
}

/* A teardown that leaks looks exactly like one that does not until something
 * reuses the runtime. Two full cycles, each doing real work. */
static void test_a_second_cycle(void) {
    int i;
    for (i = 0; i < 2; i++) {
        Janet out = janet_wrap_nil();
        assert(janet_init() == 0);
        test_env = janet_core_env(NULL);
        assert(janet_dostring(test_env, "(+ 1 2)", "cycle", &out) == 0);
        assert(janet_unwrap_integer(out) == 3);
        janet_deinit();
    }
    test_env = NULL;
}

/* ------------------------------------------------------------------ sandbox */

/* The sandbox accumulates and never narrows, and janet_sandbox_assert is the
 * only thing that reads it. Run in its own cycle, because nothing can undo it. */
static void test_the_sandbox_is_one_way(void) {
    assert(janet_init() == 0);
    test_env = janet_core_env(NULL);

    /* Nothing forbidden yet. */
    janet_sandbox_assert(JANET_SANDBOX_ALL & ~(uint32_t) 0);
    assert(janet_vm.sandbox_flags == 0);

    janet_sandbox(JANET_SANDBOX_ASM);
    assert(janet_vm.sandbox_flags == JANET_SANDBOX_ASM);
    EXPECT_PANIC(janet_sandbox_assert(JANET_SANDBOX_ASM),
                 "operation forbidden by sandbox");

    /* A flag that was not set is still allowed, and the assert takes a mask
     * rather than a single flag. */
    janet_sandbox_assert(JANET_SANDBOX_HRTIME);
    EXPECT_PANIC(janet_sandbox_assert(JANET_SANDBOX_ASM | JANET_SANDBOX_HRTIME),
                 "operation forbidden by sandbox");

    /* Flags accumulate rather than replace. */
    janet_sandbox(JANET_SANDBOX_HRTIME);
    assert(janet_vm.sandbox_flags == (JANET_SANDBOX_ASM | JANET_SANDBOX_HRTIME));

    /* Reached through the standard library, which is how it is used. `asm` is
     * absent from a build without JANET_ASSEMBLER, and an absent binding is a
     * compile error rather than the sandbox refusal being asserted. */
#ifdef JANET_ASSEMBLER
    expect_sandbox_refusal("(asm '{:arity 0 :bytecode [(ret 0)]})");
#endif

    /* And the lock: once the sandbox itself is forbidden, nothing more can be
     * added, including nothing. */
    janet_sandbox(JANET_SANDBOX_SANDBOX);
    EXPECT_PANIC(janet_sandbox(0), "operation forbidden by sandbox");
    assert(janet_vm.sandbox_flags ==
           (JANET_SANDBOX_ASM | JANET_SANDBOX_HRTIME | JANET_SANDBOX_SANDBOX));

    janet_deinit();
    test_env = NULL;
}

/* ------------------------------------------------------------- stack frames */

/* The Janet-function case, with everything a funcdef can contribute: a name, a
 * source, a source map, a program counter, the register file, and the symbol
 * map that turns registers back into names. */
static void test_a_janet_frame(void) {
    /* Written with its geometry fixed, because a source map that swapped line
     * for column would pass any assertion that only checked both were numbers.
     * `(debug/stack` opens at line 3, column 11.
     *
     *     1  (defn probe [a b]
     *     2    (let [scoped (* a 10)] (+ scoped b))
     *     3    (def total (+ a b))
     *     4    (def st (debug/stack (fiber/current)))
     *     5    (if (= total 7) st st))
     *
     * `total` is read after the call on purpose and `scoped` goes out of scope
     * before it: a binding whose last use is before the frame stops is dead
     * there, the symbol map says so, and `scoped`'s register still holds
     * something by then, which is what makes its absence an assertion rather
     * than an accident. The contract is about what is live at the program
     * counter, not about what the source mentions. */
    Janet frames = eval(
                       "(defn probe [a b]\n"
                       "  (let [scoped (* a 10)] (+ scoped b))\n"
                       "  (def total (+ a b))\n"
                       "  (def st (debug/stack (fiber/current)))\n"
                       "  (if (= total 7) st st))\n"
                       "(probe 3 4)\n");
    Janet frame;
    Janet slots, locals;
    JanetTable *bindings;
    assert(janet_checktype(frames, JANET_ARRAY));
    /* [0] is the debug/stack cframe itself; [1] is `probe`. */
    assert(janet_unwrap_array(frames)->count >= 2);
    frame = janet_unwrap_array(frames)->data[1];

    expect_string(frame, "name", "probe");
    expect_string(frame, "source", "vm-lifecycle-test");
    assert(janet_checktype(frame_get(frame, "function"), JANET_FUNCTION));
    assert(janet_checktype(frame_get(frame, "pc"), JANET_NUMBER));
    expect_absent(frame, "c");

    /* The source map, not the program counter, supplies the location for a
     * funcdef that has one. */
    expect_integer(frame, "source-line", 4);
    expect_integer(frame, "source-column", 11);

    /* The register file is copied whole, its length is the funcdef's, and its
     * contents are the frame's — the first two registers hold the arguments. */
    slots = frame_get(frame, "slots");
    assert(janet_checktype(slots, JANET_ARRAY));
    assert(janet_unwrap_array(slots)->count ==
           janet_unwrap_function(frame_get(frame, "function"))->def->slotcount);
    assert(janet_unwrap_array(slots)->count >= 2);
    assert(janet_unwrap_integer(janet_unwrap_array(slots)->data[0]) == 3);
    assert(janet_unwrap_integer(janet_unwrap_array(slots)->data[1]) == 4);

    /* Local bindings, by name, live at the point the frame stopped. */
    locals = frame_get(frame, "locals");
    assert(janet_checktype(locals, JANET_TABLE));
    bindings = janet_unwrap_table(locals);
    assert(janet_unwrap_integer(janet_table_get(bindings, janet_csymbolv("a"))) == 3);
    assert(janet_unwrap_integer(janet_table_get(bindings, janet_csymbolv("b"))) == 4);
    assert(janet_unwrap_integer(janet_table_get(bindings, janet_csymbolv("total"))) == 7);

    /* And a binding that is not live there is absent. Two of them, for two
     * different reasons: `st` is written by the call this frame is stopped at
     * and has not happened yet, and `scoped` left its scope two lines above
     * while its register still holds a value. Only the second can tell a
     * missing death bound from a working one — a table with a nil value is a
     * table without the key, so a binding reported live but holding nil looks
     * exactly like one correctly left out. */
    assert(janet_checktype(janet_table_get(bindings, janet_csymbolv("st")), JANET_NIL));
    assert(janet_checktype(janet_table_get(bindings, janet_csymbolv("scoped")), JANET_NIL));
}

/* An anonymous function reports no name and still reports everything else,
 * which is the classification `janet_trace_frame` calls NAME_ANONYMOUS and
 * which this consumer renders as the absence of a key. */
static void test_an_anonymous_janet_frame(void) {
    Janet frames = eval("((fn [] (debug/stack (fiber/current))))");
    Janet frame = janet_unwrap_array(frames)->data[1];
    expect_absent(frame, "name");
    assert(janet_checktype(frame_get(frame, "function"), JANET_FUNCTION));
    expect_string(frame, "source", "vm-lifecycle-test");
}

/* A closure reads a captured binding out of its environment rather than out of
 * its own registers: the symbol map encodes the environment index in
 * `death_pc` and marks it with a birth of UINT32_MAX. Nothing else in the tree
 * reaches that branch. */
static void test_a_captured_binding(void) {
    /* `(f)` is deliberately not in tail position. A tail call replaces the
     * caller's frame, `outer` would be gone, and the environment would have
     * been detached — which is the other branch of the same test, reading the
     * captured value off the stack rather than out of it. Keeping `outer` alive
     * is what makes this the on-stack case. */
    Janet frames = eval(
                       "(do (defn outer [captured]"
                       "      (def f (fn [] (+ captured 0) (debug/stack (fiber/current))))"
                       "      (def r (f))"
                       "      (if (= captured 11) r r))"
                       "    (outer 11))");
    Janet frame = janet_unwrap_array(frames)->data[1];
    Janet locals = frame_get(frame, "locals");
    assert(janet_checktype(locals, JANET_TABLE));
    expect_absent(frame, "name");
    assert(janet_unwrap_integer(janet_table_get(janet_unwrap_table(locals),
                                janet_csymbolv("captured"))) == 11);
}

/* The same closure entered by a tail call: `outer`'s frame is replaced, its
 * environment is detached, and the captured value is read from the environment
 * rather than from the stack it used to live on. */
static void test_a_captured_binding_off_the_stack(void) {
    Janet frames = eval(
                       "(do (defn outer2 [captured]"
                       "      (def f (fn [] (+ captured 0) (debug/stack (fiber/current))))"
                       "      (f))"
                       "    (outer2 12))");
    Janet frame = janet_unwrap_array(frames)->data[1];
    Janet locals = frame_get(frame, "locals");
    assert(janet_checktype(locals, JANET_TABLE));
    assert(janet_unwrap_integer(janet_table_get(janet_unwrap_table(locals),
                                janet_csymbolv("captured"))) == 12);
}

/* The registered-cfunction case. `debug/stack` is itself the top frame, so it
 * describes its own registration: a prefixed name, the source file it was
 * declared in, the line, and a column of one — which is not a column anybody
 * measured, but a constant this consumer supplies because the registry has no
 * column to give. */
static void test_a_registered_cfunction_frame(void) {
    Janet frames = eval("(debug/stack (fiber/current))");
    Janet frame = janet_unwrap_array(frames)->data[0];
    Janet name;

    assert(janet_equals(frame_get(frame, "c"), janet_wrap_true()));
    expect_absent(frame, "function");
    expect_absent(frame, "slots");
    expect_absent(frame, "pc");

    name = frame_get(frame, "name");
    assert(janet_checktype(name, JANET_STRING));
    assert(!janet_cstrcmp(janet_unwrap_string(name), "debug/stack") &&
           "a registered cfunction reports prefix/name");

    assert(janet_checktype(frame_get(frame, "source"), JANET_STRING));
    assert(janet_checktype(frame_get(frame, "source-line"), JANET_NUMBER));
    expect_integer(frame, "source-column", 1);
}

/* A tail call is reported, and it is the one key that comes from the frame's
 * own flags rather than from anything it points at. */
static void test_a_tail_call_frame(void) {
    Janet frames = eval(
                       "(do (defn inner [] (debug/stack (fiber/current)))"
                       "    (defn outer [] (inner))"
                       "    (outer))");
    /* `inner` was entered by a tail call from `outer`, so `outer`'s frame is
     * gone and `inner`'s carries the flag. */
    Janet frame = janet_unwrap_array(frames)->data[1];
    expect_string(frame, "name", "inner");
    assert(janet_equals(frame_get(frame, "tail"), janet_wrap_true()));
}

/* A cfunction registered with a prefix, which the core's own are not: every
 * core registration puts the qualified name in `name` and leaves `name_prefix`
 * null, so `debug/stack` above cannot tell a dropped prefix from a kept one.
 * This one is registered through janet_cfuns with a prefix, and with neither a
 * source file nor a source line, so it also pins the two keys a registry entry
 * without them must not produce.
 *
 * It reports its own frame, which is the only way to see a cframe that is not
 * `debug/stack` itself. */
static Janet cfun_selfframe(int32_t argc, Janet *argv) {
    janet_fixarity(argc, 0);
    (void) argv;
    return janet_debug_frame(janet_fiber_frame(janet_vm.fiber));
}

static const JanetReg cfuns[] = {
    {"selfframe", cfun_selfframe, "(selfframe)\n\nIts own stack frame."},
    {NULL, NULL, NULL}
};

static void test_a_prefixed_cfunction_frame(void) {
    Janet frame = eval("(selfframe)");
    assert(janet_equals(frame_get(frame, "c"), janet_wrap_true()));
    expect_string(frame, "name", "vmlife/selfframe");
    expect_absent(frame, "source");
    expect_absent(frame, "source-line");
    expect_absent(frame, "source-column");
    expect_absent(frame, "function");
}

/* A frame that has a function and no program counter reports the function and
 * nothing that depends on where it stopped. Nothing in the runtime builds one —
 * janet_fiber_funcframe always sets `pc` — so it is constructed here, which is
 * also the only way to reach the guard that skips the second half of the
 * decoding. */
static void test_a_frame_with_no_program_counter(void) {
    Janet fnv = eval("(do (defn named [] nil) named)");
    JanetFiber *fiber = janet_fiber(janet_unwrap_function(fnv), 64, 0, NULL);
    JanetStackFrame *fr;
    Janet frame;
    assert(fiber != NULL);
    janet_gcroot(janet_wrap_fiber(fiber));
    fr = janet_fiber_frame(fiber);
    assert(fr->func != NULL && fr->pc != NULL);
    fr->pc = NULL;

    frame = janet_debug_frame(fr);
    expect_string(frame, "name", "named");
    assert(janet_checktype(frame_get(frame, "function"), JANET_FUNCTION));
    expect_absent(frame, "pc");
    expect_absent(frame, "slots");
    expect_absent(frame, "locals");
    expect_absent(frame, "source");
    expect_absent(frame, "source-line");
}

/* A cfunction that was never passed through janet_cfuns has no registry entry.
 * The C original reads the entry anyway; the port asks janet_trace_frame, which
 * checks. See the header. */
static Janet unregistered_cfunction(int32_t argc, Janet *argv) {
    (void) argc;
    (void) argv;
    return janet_wrap_nil();
}

static void test_an_unregistered_cfunction_frame(void) {
#ifdef JANET_ZIG_DEBUG_FRAMES
    Janet fnv = eval("(fn [] nil)");
    JanetFiber *fiber = janet_fiber(janet_unwrap_function(fnv), 64, 0, NULL);
    Janet frame;
    assert(fiber != NULL);
    janet_gcroot(janet_wrap_fiber(fiber));
    janet_fiber_cframe(fiber, unregistered_cfunction);

    frame = janet_debug_frame(janet_fiber_frame(fiber));
    assert(janet_equals(frame_get(frame, "c"), janet_wrap_true()));
    expect_absent(frame, "name");
    expect_absent(frame, "source");
    expect_absent(frame, "source-line");
    expect_absent(frame, "function");
#else
    (void) unregistered_cfunction;
#endif
}

/* ------------------------------------------------------------------- entry */

int main(void) {
    /* Three cycles of their own, before anything shared exists. */
    test_the_state_janet_init_leaves();
    test_what_janet_deinit_clears();
    test_a_second_cycle();

    janet_init();
    test_env = janet_core_env(NULL);
    janet_cfuns(test_env, "vmlife", cfuns);

    test_a_janet_frame();
    test_an_anonymous_janet_frame();
    test_a_captured_binding();
    test_a_captured_binding_off_the_stack();
    test_a_registered_cfunction_frame();
    test_a_prefixed_cfunction_frame();
    test_a_tail_call_frame();
    test_a_frame_with_no_program_counter();
    test_an_unregistered_cfunction_frame();

    janet_deinit();
    test_env = NULL;

    /* Last, because it cannot be undone. */
    test_the_sandbox_is_one_way();

    if (panics_fired != EXPECTED_PANICS) {
        printf("expected %d panics, counted %d\n", EXPECTED_PANICS, panics_fired);
        assert(0 && "panic count mismatch");
    }

    printf("vm lifecycle contract ok (%d panics)\n", panics_fired);
    return 0;
}
