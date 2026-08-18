/* Behavioral contract for the allocation of the three remaining collectable
 * kinds: `janet_fiber` and `janet_fiber_reset` from `fiber.c`, and
 * `janet_funcdef_alloc` and `janet_thunk` from `bytecode.c`. Run against
 * whichever implementation the build selected (`-Dvalue-alloc=c` or the Zig
 * default).
 *
 * These five functions -- two exported entry points plus the two file-local
 * helpers underneath them -- are almost entirely field initialisation, and
 * field initialisation is what a port silently gets wrong: a missed store
 * leaves whatever `janet_malloc` returned, which is usually the corpse of a
 * previous block and so is usually plausible. So the tests below read every
 * field they can and prefer dirtying a field before the call to asserting a
 * value that a fresh allocation might have had anyway.
 *
 * Four channels carry it:
 *
 *  - The block header. `janet_gc_type` says which of the three memory types was
 *    written, and `janet_vm.blocks` says the collector was handed the block.
 *  - `janet_vm.next_collection`, which each of these functions charges. A fiber
 *    is charged twice, once by `janet_gcalloc` for the block and once by hand
 *    for the value stack, and the second charge is the one only this test sees.
 *  - The fiber's own fields after a *failed* `janet_fiber_reset`. This is the
 *    only way to observe the newborn state: a successful call runs
 *    `janet_fiber_funcframe` over it, which overwrites `frame`, `stackstart`
 *    and `stacktop` before returning.
 *  - `janet_collect`, run with the new object rooted and again with it
 *    unrooted, which is what says the block was initialised well enough for the
 *    mark phase to walk it and the sweep to free it.
 *
 * The file includes `fiber.h`, `state.h` and `gc.h`, for the frame constants,
 * the VM state, and the block header respectively.
 */

#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "features.h"
#include <janet.h>
#include "fiber.h"
#include "state.h"
#include "gc.h"

/* The one behaviour here that is fatal by design needs a child process to
 * observe, exactly as test/fiber_core.c needs threads for its per-thread half.
 * The Windows path is cross-compiled and never executed, so it is left out
 * rather than written blind. */
#ifndef JANET_WINDOWS
#define JANET_VALUE_ALLOC_FORK
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

static JanetTable *test_env;

/* ------------------------------------------------------------------ helpers */

/* Zig cannot ask for `offsetof(JanetFunction, envs)`: translate-c drops the
 * flexible array member, so `janet_thunk` sizes the block with
 * `@sizeOf(JanetFunction)` instead. That is only correct while the two are
 * equal, and C is the only side that can check. The same assertion for
 * `JanetAbstractHead` lives in test/abstract_core.c; this is the second and
 * last flexible array member the port has to size around. */
static void test_function_size(void) {
    assert(sizeof(JanetFunction) == offsetof(JanetFunction, envs));
}

/* Whether a block is on one of the two heap lists. Only ever called for a block
 * known to be alive, so nothing freed is dereferenced. */
static int on_blocks(void *block) {
    JanetGCObject *current = janet_vm.blocks;
    while (NULL != current) {
        if ((void *) current == block) return 1;
        current = current->data.next;
    }
    return 0;
}

/* Reach a quiet heap, so that a later collection's effects are attributable to
 * what this test made rather than to what an earlier one left behind. */
static void settle(void) {
    janet_collect();
    janet_collect();
}

static JanetFunction *compile_function(const char *source) {
    Janet out = janet_wrap_nil();
    int status = janet_dostring(test_env, source, "value-alloc-test", &out);
    assert(status == 0);
    assert(janet_checktype(out, JANET_FUNCTION));
    janet_gcroot(out);
    return janet_unwrap_function(out);
}

static int32_t status_of(JanetFiber *fiber) {
    return (fiber->flags & JANET_FIBER_STATUS_MASK) >> JANET_FIBER_STATUS_OFFSET;
}

/* The newborn state, as fiber_reset leaves it. Read after a rejected
 * janet_fiber_reset, where nothing has run over it. */
static void assert_newborn(JanetFiber *fiber, int32_t expect_stacktop) {
    assert(fiber->maxstack == JANET_STACK_MAX);
    assert(fiber->frame == 0);
    assert(fiber->stackstart == JANET_FRAME_SIZE);
    assert(fiber->stacktop == expect_stacktop);
    assert(fiber->child == NULL);
    assert(fiber->env == NULL);
    assert(janet_checktype(fiber->last_value, JANET_NIL));
    assert((fiber->flags & ~JANET_FIBER_STATUS_MASK) ==
           (JANET_FIBER_MASK_YIELD | JANET_FIBER_RESUME_NO_USEVAL | JANET_FIBER_RESUME_NO_SKIP));
    assert(status_of(fiber) == JANET_STATUS_NEW);
#ifdef JANET_EV
    assert(fiber->sched_id == 0);
    assert(fiber->ev_callback == NULL);
    assert(fiber->ev_state == NULL);
    assert(fiber->ev_stream == NULL);
    assert(fiber->supervisor_channel == NULL);
#endif
}

/* Write a distinguishable value into every field fiber_reset is supposed to
 * clear, so that the assertions above are about stores rather than about what
 * the allocator happened to hand back. */
static void dirty(JanetFiber *fiber, JanetFiber *child, JanetTable *env) {
    fiber->maxstack = 7;
    fiber->frame = 11;
    fiber->stackstart = 13;
    fiber->stacktop = 17;
    fiber->child = child;
    fiber->env = env;
    fiber->last_value = janet_wrap_integer(23);
    fiber->flags = JANET_FIBER_MASK_ERROR | JANET_FIBER_DID_LONGJUMP |
                   (JANET_STATUS_ALIVE << JANET_FIBER_STATUS_OFFSET);
#ifdef JANET_EV
    fiber->sched_id = 29;
    fiber->ev_callback = (JanetEVCallback) 0;
    fiber->ev_state = (void *) fiber;
    fiber->ev_stream = (JanetStream *) NULL;
    fiber->supervisor_channel = (void *) fiber;
#endif
}

/* ------------------------------------------------------------ fiber blocks */

/* A fiber is a collectable block the collector is given immediately, tagged
 * JANET_MEMORY_FIBER, plus a plain allocation for the value stack that hangs
 * off it. */
static void test_fiber_is_a_collectable_block(JanetFunction *nullary) {
    JanetFiber *fiber = janet_fiber(nullary, 32, 0, NULL);
    assert(fiber != NULL);
    janet_gcroot(janet_wrap_fiber(fiber));

    assert(janet_gc_type(fiber) == JANET_MEMORY_FIBER);
    assert(!janet_gc_reachable(fiber));
    assert(on_blocks(fiber));
    assert(fiber->data != NULL);

    janet_gcunroot(janet_wrap_fiber(fiber));
}

/* The 32-slot floor. A caller asking for less gets 32; a caller asking for more
 * gets what it asked for, as long as the first frame fits inside it. */
static void test_capacity_floor(JanetFunction *nullary) {
    JanetFiber *small = janet_fiber(nullary, 0, 0, NULL);
    JanetFiber *tiny = janet_fiber(nullary, 31, 0, NULL);
    JanetFiber *negative = janet_fiber(nullary, -4096, 0, NULL);
    JanetFiber *large = janet_fiber(nullary, 4096, 0, NULL);

    assert(small->capacity == 32);
    assert(tiny->capacity == 32);
    assert(negative->capacity == 32);
    assert(large->capacity == 4096);

    /* Exactly 32 is not below the floor, so it is left alone rather than
     * doubled. Only a wrong comparison would tell these two apart. */
    assert(janet_fiber(nullary, 32, 0, NULL)->capacity == 32);
}

/* A fiber costs the collector two charges: the block, billed by janet_gcalloc,
 * and the value stack, billed here. Nothing else in the call allocates, so long
 * as the callee takes no arguments and its frame fits in the capacity asked
 * for. */
static void test_fiber_charges_block_and_stack(JanetFunction *nullary) {
    size_t before, after;
    JanetFiber *fiber;

    settle();
    before = janet_vm.next_collection;
    fiber = janet_fiber(nullary, 1024, 0, NULL);
    after = janet_vm.next_collection;

    assert(fiber->capacity == 1024);
    assert(after - before == sizeof(JanetFiber) + 1024 * sizeof(Janet));

    /* And the floor is charged, not the request: 32 slots for a request of 1. */
    before = janet_vm.next_collection;
    fiber = janet_fiber(nullary, 1, 0, NULL);
    after = janet_vm.next_collection;
    assert(after - before == sizeof(JanetFiber) + 32 * sizeof(Janet));
}

/* -------------------------------------------------------------- fiber_reset */

/* A rejected arity is reported by returning NULL, and leaves the fiber in the
 * newborn state rather than half-built -- callers use the return value to
 * implement janet_pcall, not to recover a partial frame. This is also the only
 * vantage point from which fiber_reset's own stores are visible. */
static void test_rejected_reset_leaves_a_newborn(JanetFunction *binary, JanetFunction *nullary) {
    JanetFiber *fiber = janet_fiber(nullary, 64, 0, NULL);
    JanetFiber *child = janet_fiber(nullary, 32, 0, NULL);
    JanetTable *env = janet_table(0);
    Janet root = janet_wrap_fiber(fiber);

    janet_gcroot(root);
    janet_gcroot(janet_wrap_fiber(child));
    janet_gcroot(janet_wrap_table(env));

    dirty(fiber, child, env);
    assert(janet_fiber_reset(fiber, binary, 0, NULL) == NULL);
    assert_newborn(fiber, JANET_FRAME_SIZE);

    janet_gcunroot(janet_wrap_table(env));
    janet_gcunroot(janet_wrap_fiber(child));
    janet_gcunroot(root);
}

/* Recycling keeps the stack the fiber already paid for. This is the whole
 * reason janet_fiber_reset exists as a separate entry point, and a port that
 * cleared capacity or data would still pass everything else here. */
static void test_reset_keeps_the_stack(JanetFunction *binary, JanetFunction *nullary) {
    JanetFiber *fiber = janet_fiber(nullary, 4096, 0, NULL);
    Janet *data = fiber->data;
    size_t before;

    janet_gcroot(janet_wrap_fiber(fiber));
    settle();
    before = janet_vm.next_collection;

    assert(janet_fiber_reset(fiber, binary, 0, NULL) == NULL);
    assert(fiber->capacity == 4096);
    assert(fiber->data == data);
    assert(janet_vm.next_collection == before);

    janet_gcunroot(janet_wrap_fiber(fiber));
}

/* Arguments are copied into the slots above the frame base, and a NULL argv is
 * a request for that many nils rather than a request for nothing. Read through
 * a rejected callee so the frame machinery has not moved anything. */
static void test_arguments_land_above_the_frame(JanetFunction *binary, JanetFunction *nullary) {
    JanetFiber *fiber = janet_fiber(nullary, 64, 0, NULL);
    Janet args[3];
    int32_t i;

    janet_gcroot(janet_wrap_fiber(fiber));

    args[0] = janet_wrap_integer(101);
    args[1] = janet_wrap_integer(102);
    args[2] = janet_wrap_integer(103);

    /* Three arguments to a function of two: rejected, but only after the
     * arguments have been placed. */
    assert(janet_fiber_reset(fiber, binary, 3, args) == NULL);
    assert(fiber->stacktop == JANET_FRAME_SIZE + 3);
    assert(fiber->stackstart == JANET_FRAME_SIZE);
    for (i = 0; i < 3; i++) {
        assert(janet_unwrap_integer(fiber->data[JANET_FRAME_SIZE + i]) == 101 + i);
    }

    /* No argv means nil, and means it for every slot. */
    for (i = 0; i < 3; i++) fiber->data[JANET_FRAME_SIZE + i] = janet_wrap_integer(-1);
    assert(janet_fiber_reset(fiber, binary, 3, NULL) == NULL);
    assert(fiber->stacktop == JANET_FRAME_SIZE + 3);
    for (i = 0; i < 3; i++) {
        assert(janet_checktype(fiber->data[JANET_FRAME_SIZE + i], JANET_NIL));
    }

    /* Zero arguments touch neither the stack pointer nor the slots. */
    fiber->data[JANET_FRAME_SIZE] = janet_wrap_integer(-7);
    assert(janet_fiber_reset(fiber, binary, 0, NULL) == NULL);
    assert(fiber->stacktop == JANET_FRAME_SIZE);
    assert(janet_unwrap_integer(fiber->data[JANET_FRAME_SIZE]) == -7);

    janet_gcunroot(janet_wrap_fiber(fiber));
}

/* The argument block grows the stack when it would exactly fill it, not only
 * when it would overrun it. The two differ by one comparison and by a factor of
 * two in the resulting capacity: a stack that is grown here reaches 2 *
 * newstacktop, and one that is not stays at its old size, because the frame
 * that follows is small enough to fit either way.
 *
 * The frame that follows is 2 * JANET_FRAME_SIZE + slotcount regardless of how
 * many arguments were pushed -- funcframe measures from stackstart, which the
 * argument block does not move -- so the assertion below is independent of the
 * vararg function's arity. */
static void test_argument_block_grows_on_equality(JanetFunction *variadic) {
    JanetFiber *fiber;
    Janet args[28];
    int32_t argc = 32 - JANET_FRAME_SIZE;
    int32_t i;

    for (i = 0; i < argc; i++) args[i] = janet_wrap_integer(i);
    assert(2 * JANET_FRAME_SIZE + variadic->def->slotcount < 64);

    fiber = janet_fiber(variadic, 32, argc, args);
    assert(fiber != NULL);
    janet_gcroot(janet_wrap_fiber(fiber));

    /* JANET_FRAME_SIZE + argc == 32 == the capacity asked for, so the stack was
     * doubled to 64 before the arguments were written. */
    assert(fiber->capacity == 64);

    janet_gcunroot(janet_wrap_fiber(fiber));
}

/* A fiber built by janet_fiber is left with its first frame pushed and marked
 * as an entrance frame, and -- under the event loop -- with no supervisor. */
static void test_fiber_is_ready_to_run(JanetFunction *binary) {
    Janet args[2];
    JanetFiber *fiber;
    JanetStackFrame *frame;

    args[0] = janet_wrap_integer(3);
    args[1] = janet_wrap_integer(4);
    fiber = janet_fiber(binary, 32, 2, args);
    assert(fiber != NULL);
    janet_gcroot(janet_wrap_fiber(fiber));

    frame = janet_fiber_frame(fiber);
    assert(fiber->frame == JANET_FRAME_SIZE);
    assert(frame->func == binary);
    assert(frame->flags == JANET_STACKFRAME_ENTRANCE);
    assert(status_of(fiber) == JANET_STATUS_NEW);
#ifdef JANET_EV
    assert(fiber->supervisor_channel == NULL);
#endif

    janet_gcunroot(janet_wrap_fiber(fiber));
}

/* A fiber allocated here has to survive the collector: marked while rooted,
 * and freed with its value stack when it is not. Nothing else in this file
 * runs the sweep over a block these functions produced. */
static void test_a_fiber_survives_a_collection(JanetFunction *nullary) {
    JanetFiber *fiber = janet_fiber(nullary, 128, 0, NULL);
    Janet root = janet_wrap_fiber(fiber);
    size_t blocks_before;

    janet_gcroot(root);
    janet_collect();
    assert(janet_gc_type(fiber) == JANET_MEMORY_FIBER);
    assert(fiber->capacity == 128);
    assert(on_blocks(fiber));

    janet_gcunroot(root);
    settle();
    blocks_before = janet_vm.block_count;
    janet_collect();
    assert(janet_vm.block_count == blocks_before);
}

/* --------------------------------------------------------------- funcdefs */

/* Every field janet_funcdef_alloc writes.
 *
 * A missing store here is only visible when the memory underneath it held
 * something else, and on the development target it never does: macOS zeroes a
 * block on free, so a recycled block reads exactly like a correctly emptied
 * one. Every field below whose right answer is zero is therefore beyond an
 * in-process contract on this platform, and the mutation sweep says so. Only
 * max_arity, which starts at INT32_MAX, is checkable here. */
static void assert_empty_funcdef(JanetFuncDef *def) {
    assert(def->environments == NULL);
    assert(def->constants == NULL);
    assert(def->bytecode == NULL);
    assert(def->closure_bitset == NULL);
    assert(def->sourcemap == NULL);
    assert(def->source == NULL);
    assert(def->name == NULL);
    assert(def->symbolmap == NULL);

    assert(def->flags == 0);
    assert(def->slotcount == 0);
    assert(def->arity == 0);
    assert(def->min_arity == 0);
    assert(def->max_arity == INT32_MAX);
    assert(def->constants_length == 0);
    assert(def->bytecode_length == 0);
    assert(def->environments_length == 0);
    assert(def->defs == NULL);
    assert(def->defs_length == 0);
    assert(def->symbolmap_length == 0);
    assert(def->named_args_count == 0);
}

/* An empty funcdef: every pointer null, every length zero, and max_arity at
 * INT32_MAX rather than at zero, because an unfinished funcdef accepts anything
 * until the assembler or the compiler narrows it. */
static void test_funcdef_alloc_is_empty(void) {
    JanetFuncDef *def = janet_funcdef_alloc();
    Janet root = janet_wrap_function(janet_thunk(def));

    janet_gcroot(root);

    assert(janet_gc_type(def) == JANET_MEMORY_FUNCDEF);
    assert(!janet_gc_reachable(def));
    assert(on_blocks(def));
    assert_empty_funcdef(def);

    janet_gcunroot(root);
}

/* Two funcdefs are two blocks. A port that cached or reused one would pass
 * every field assertion above. */
static void test_funcdefs_are_distinct(void) {
    JanetFuncDef *a = janet_funcdef_alloc();
    JanetFuncDef *b = janet_funcdef_alloc();
    assert(a != b);
    assert(on_blocks(a));
    assert(on_blocks(b));
}

/* The funcdef block is charged at its own size. */
static void test_funcdef_charges_its_block(void) {
    size_t before, after;
    settle();
    before = janet_vm.next_collection;
    (void) janet_funcdef_alloc();
    after = janet_vm.next_collection;
    assert(after - before == sizeof(JanetFuncDef));
}

/* An empty funcdef is initialised well enough for the mark phase to walk it
 * and the sweep to free it. This is what the field-by-field assertions are
 * actually protecting: the collector reads every one of those pointers. */
static void test_an_empty_funcdef_survives_a_collection(void) {
    JanetFuncDef *def = janet_funcdef_alloc();
    Janet root = janet_wrap_function(janet_thunk(def));
    size_t blocks_before;

    janet_gcroot(root);
    janet_collect();
    assert(janet_gc_type(def) == JANET_MEMORY_FUNCDEF);
    assert(def->max_arity == INT32_MAX);

    janet_gcunroot(root);
    settle();
    blocks_before = janet_vm.block_count;
    janet_collect();
    assert(janet_vm.block_count == blocks_before);
}

/* ----------------------------------------------------------------- thunks */

/* A thunk is a JANET_MEMORY_FUNCTION block wrapping one funcdef and no
 * environments, sized for exactly that. */
static void test_thunk_wraps_the_def(void) {
    JanetFuncDef *def = janet_funcdef_alloc();
    JanetFunction *func = janet_thunk(def);
    Janet root = janet_wrap_function(func);

    janet_gcroot(root);

    assert(janet_gc_type(func) == JANET_MEMORY_FUNCTION);
    assert(!janet_gc_reachable(func));
    assert(on_blocks(func));
    assert(func->def == def);

    janet_gcunroot(root);
}

static void test_thunk_charges_its_block(void) {
    JanetFuncDef *def = janet_funcdef_alloc();
    size_t before, after;

    settle();
    before = janet_vm.next_collection;
    (void) janet_thunk(def);
    after = janet_vm.next_collection;
    assert(after - before == sizeof(JanetFunction));
}

#ifdef JANET_VALUE_ALLOC_FORK

/* A thunk over a def that needs upvalues is refused, and refused fatally: the
 * block janet_thunk allocates is sized for no environments at all, so a caller
 * that got one back would read envs[0] off the end of a 24-byte allocation.
 * The check is an abort in both implementations -- janet_assert on the C side,
 * janet_zig_fatal on the Zig side -- and abort is what a child process can
 * report back. */
static void test_thunk_refuses_upvalues(void) {
    pid_t child = fork();
    int status = 0;

    assert(child >= 0);
    if (0 == child) {
        JanetFuncDef *def = janet_funcdef_alloc();
        def->environments_length = 1;
        /* The abort message is the point of the exercise, not of the log. */
        (void) freopen("/dev/null", "w", stderr);
        (void) janet_thunk(def);
        _exit(0);
    }

    assert(child == waitpid(child, &status, 0));
    assert(WIFSIGNALED(status));
    assert(WTERMSIG(status) == SIGABRT);
}

#endif

/* Two thunks over one def are two functions that agree about the def. */
static void test_thunks_are_distinct(void) {
    JanetFuncDef *def = janet_funcdef_alloc();
    JanetFunction *a = janet_thunk(def);
    JanetFunction *b = janet_thunk(def);
    assert(a != b);
    assert(a->def == def);
    assert(b->def == def);
}

/* --------------------------------------------------------------- pressure */

/* Repeated allocation of all three kinds, with collections in between, so that
 * a block whose header or fields were written wrongly is swept rather than
 * merely inspected. */
static void test_repeated_cycles(JanetFunction *nullary) {
    int i;
    for (i = 0; i < 64; i++) {
        Janet fiber = janet_wrap_fiber(janet_fiber(nullary, i, 0, NULL));
        Janet thunk = janet_wrap_function(janet_thunk(janet_funcdef_alloc()));
        janet_gcroot(fiber);
        janet_gcroot(thunk);
        janet_collect();
        (void) janet_funcdef_alloc();
        janet_gcunroot(thunk);
        janet_gcunroot(fiber);
        janet_collect();
    }
}

int main(void) {
    JanetFunction *nullary, *binary, *variadic;

    janet_init();
    test_env = janet_core_env(NULL);
    janet_gcroot(janet_wrap_table(test_env));

    test_function_size();

    nullary = compile_function("(fn [] 1)");
    binary = compile_function("(fn [a b] (+ a b))");
    variadic = compile_function("(fn [& args] (length args))");

    test_fiber_is_a_collectable_block(nullary);
    test_capacity_floor(nullary);
    test_fiber_charges_block_and_stack(nullary);

    test_rejected_reset_leaves_a_newborn(binary, nullary);
    test_reset_keeps_the_stack(binary, nullary);
    test_arguments_land_above_the_frame(binary, nullary);
    test_argument_block_grows_on_equality(variadic);
    test_fiber_is_ready_to_run(binary);
    test_a_fiber_survives_a_collection(nullary);

    test_funcdef_alloc_is_empty();
    test_funcdefs_are_distinct();
    test_funcdef_charges_its_block();
    test_an_empty_funcdef_survives_a_collection();

    test_thunk_wraps_the_def();
    test_thunk_charges_its_block();
    test_thunks_are_distinct();
#ifdef JANET_VALUE_ALLOC_FORK
    test_thunk_refuses_upvalues();
#endif

    test_repeated_cycles(nullary);

    janet_deinit();
    printf("value alloc contract ok\n");
    return 0;
}
