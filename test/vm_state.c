/* Behavioral contract for the thread-local VM state, run against whichever
 * implementation the build selected (`-Dvm-state=c` or the Zig default).
 *
 * Unlike the other subsystem contracts this one includes `state.h`. It has to:
 * the thing under test is the storage of `janet_vm` itself, and the whole
 * point of the increment is that C's `janet_vm` and the owner's are one
 * object. Declaring a stand-in structure here would test the stand-in.
 *
 * Nothing below calls janet_init(), with one exception. These are operations
 * over the state as a whole — its address, its size, and whole-structure
 * copies — and none of them reads a field the runtime has to have filled in.
 * Keeping the VM uninitialised is deliberate: it lets the destructive cases
 * write whatever they like.
 *
 * The exception is the dynamic bindings, which arrived with Phase 10 Part 5
 * and are the first thing here that reads a field rather than the structure.
 * They run last, inside their own janet_init/janet_deinit, so that the
 * destructive cases above still get an uninitialised VM to scribble on.
 */

#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "features.h"
#include <janet.h>
#include "state.h"

/* The per-thread half of the contract needs threads and pthreads to say it
 * with. A single-threaded build has one process-wide VM by construction and
 * has nothing to check here; the Windows path is cross-compiled and never
 * executed, so it is left out rather than written blind. */
#if !defined(JANET_SINGLE_THREADED) && !defined(JANET_WINDOWS)
#define JANET_VM_STATE_THREADS
#include <pthread.h>
#endif

/* ------------------------------------------------------------------ layout */

/* The owner's view of JanetVM has to be the compiler's, byte for byte. Every
 * whole-VM copy uses the owner's length, so a disagreement would truncate or
 * overrun one, and neither would show up as a compile error. */
static void test_layout_agrees(void) {
    assert(janet_vm_state_size() == sizeof(JanetVM));
    assert(janet_vm_state_align() == offsetof(JanetVMAlignProbe, vm));
    assert(sizeof(JanetVM) % janet_vm_state_align() == 0);
}

/* ------------------------------------------------------------------ address */

/* janet_local_vm() must name the same object as `janet_vm`, which is the
 * property that lets the Zig implementation define the storage while every
 * core C file keeps writing `janet_vm.field`. */
static void test_local_vm_is_janet_vm(void) {
    assert(janet_local_vm() == &janet_vm);
    assert(janet_local_vm() == janet_local_vm());

    janet_vm.stackn = 1234;
    assert(janet_local_vm()->stackn == 1234);
    janet_local_vm()->stackn = 4321;
    assert(janet_vm.stackn == 4321);
    janet_vm.stackn = 0;
}

/* --------------------------------------------------------------- allocation */

static void test_alloc_and_free(void) {
    JanetVM *a = janet_vm_alloc();
    JanetVM *b = janet_vm_alloc();
    assert(a != NULL);
    assert(b != NULL);
    assert(a != b);
    /* A detached VM is a destination for janet_vm_save and nothing else, so
     * the only thing to check about a fresh one is that it can hold a save. */
    janet_vm_save(a);
    janet_vm_save(b);
    janet_vm_free(a);
    janet_vm_free(b);
    janet_vm_free(NULL);
}

/* ------------------------------------------------------------ save and load */

/* Two snapshots taken around a change must differ in the changed field and
 * restore independently. `stackn` is used as the witness because it is a
 * scalar the VM owns outright — a field reached through one of the VM's
 * pointers would be shared by every snapshot rather than copied. */
static void test_save_load_round_trip(void) {
    JanetVM *first = janet_vm_alloc();
    JanetVM *second = janet_vm_alloc();

    janet_vm.stackn = 11;
    janet_vm.coerce_error = 1;
    janet_vm_save(first);

    janet_vm.stackn = 22;
    janet_vm.coerce_error = 0;
    janet_vm_save(second);

    janet_vm.stackn = 33;
    janet_vm.coerce_error = 1;

    janet_vm_load(first);
    assert(janet_vm.stackn == 11);
    assert(janet_vm.coerce_error == 1);

    janet_vm_load(second);
    assert(janet_vm.stackn == 22);
    assert(janet_vm.coerce_error == 0);

    /* A load is a plain copy: loading the same snapshot twice is idempotent,
     * and the snapshot is not consumed. */
    janet_vm_load(second);
    assert(janet_vm.stackn == 22);

    janet_vm_free(first);
    janet_vm_free(second);
    janet_vm.stackn = 0;
    janet_vm.coerce_error = 0;
}

/* A save must copy the fields at the very end of the structure as well as the
 * ones at the front. The last member is configuration-dependent, so the check
 * walks a set of fields that spans the structure instead of naming one. */
static void test_save_spans_the_structure(void) {
    JanetVM *snapshot = janet_vm_alloc();

    janet_vm.user = (void *) (uintptr_t) 0x1111;
    janet_vm.registry_count = 0x2222;
    janet_vm.root_capacity = 0x3333;
    janet_vm.sandbox_flags = 0x4444;
    janet_vm.traversal_base = (JanetTraversalNode *) (uintptr_t) 0x5555;
#ifndef JANET_WINDOWS
    janet_vm.strerror_buf[0] = 'z';
    janet_vm.strerror_buf[sizeof(janet_vm.strerror_buf) - 1] = 'q';
#endif
#ifdef JANET_EV
    janet_vm.tq_capacity = 0x6666;
    janet_vm.spawn.capacity = 0x7777;
    janet_vm.active_tasks.capacity = 0x8888;
#ifdef JANET_WINDOWS
    janet_vm.connect_ex_loaded = 0x9999;
#elif defined(JANET_EV_EPOLL)
    janet_vm.timer_enabled = 0x9999;
#elif defined(JANET_EV_KQUEUE)
    janet_vm.timer_enabled = 0x9999;
#else
    janet_vm.stream_capacity = 0x9999;
#endif
#endif

    janet_vm_save(snapshot);
    memset(&janet_vm, 0, sizeof(JanetVM));
    janet_vm_load(snapshot);

    assert(janet_vm.user == (void *) (uintptr_t) 0x1111);
    assert(janet_vm.registry_count == 0x2222);
    assert(janet_vm.root_capacity == 0x3333);
    assert(janet_vm.sandbox_flags == 0x4444);
    assert(janet_vm.traversal_base == (JanetTraversalNode *) (uintptr_t) 0x5555);
#ifndef JANET_WINDOWS
    assert(janet_vm.strerror_buf[0] == 'z');
    assert(janet_vm.strerror_buf[sizeof(janet_vm.strerror_buf) - 1] == 'q');
#endif
#ifdef JANET_EV
    assert(janet_vm.tq_capacity == 0x6666);
    assert(janet_vm.spawn.capacity == 0x7777);
    assert(janet_vm.active_tasks.capacity == 0x8888);
#ifdef JANET_WINDOWS
    assert(janet_vm.connect_ex_loaded == 0x9999);
#elif defined(JANET_EV_EPOLL)
    assert(janet_vm.timer_enabled == 0x9999);
#elif defined(JANET_EV_KQUEUE)
    assert(janet_vm.timer_enabled == 0x9999);
#else
    assert(janet_vm.stream_capacity == 0x9999);
#endif
#endif

    janet_vm_free(snapshot);
    memset(&janet_vm, 0, sizeof(JanetVM));
}

/* A save must also copy no further than the end of the structure. This is the
 * check that would catch a Zig `@sizeOf` larger than the C `sizeof` even if
 * janet_vm_state_size() were somehow wrong about it. */
static void test_save_stays_inside_the_structure(void) {
    size_t guard = 64;
    unsigned char *buffer = malloc(sizeof(JanetVM) + guard);
    size_t i;
    assert(buffer != NULL);
    memset(buffer, 0xAB, sizeof(JanetVM) + guard);
    janet_vm_save((JanetVM *) buffer);
    for (i = 0; i < guard; i++) {
        assert(buffer[sizeof(JanetVM) + i] == 0xAB);
    }
    free(buffer);
}

/* ------------------------------------------------------------- interruption */

/* The interrupt counter is a signed counter, not a flag: nested interrupts are
 * balanced by the same number of handled calls. A null argument means the
 * calling thread's own VM, which is the form os/sigaction's handler uses. */
static void test_interrupt_counter(void) {
    JanetVM *self = janet_local_vm();
    JanetAtomicInt before = self->auto_suspend;

    janet_interpreter_interrupt(NULL);
    assert(self->auto_suspend == before + 1);
    janet_interpreter_interrupt(self);
    assert(self->auto_suspend == before + 2);
    janet_interpreter_interrupt_handled(NULL);
    assert(self->auto_suspend == before + 1);
    janet_interpreter_interrupt_handled(self);
    assert(self->auto_suspend == before);

    /* An explicit VM pointer must reach that VM and no other. */
    {
        JanetVM *other = janet_vm_alloc();
        janet_vm_save(other);
        other->auto_suspend = 0;
        janet_interpreter_interrupt(other);
        assert(other->auto_suspend == 1);
        assert(self->auto_suspend == before);
        janet_interpreter_interrupt_handled(other);
        assert(other->auto_suspend == 0);
        janet_vm_free(other);
    }
}

/* ------------------------------------------------------------------ threads */

#if defined(JANET_VM_STATE_THREADS)

static JanetVM *main_vm;
static JanetVM *child_vm;
static int child_saw_zero;
static int child_local_matches;

static void *child(void *arg) {
    unsigned char zero[sizeof(JanetVM)];
    (void) arg;
    memset(zero, 0, sizeof(zero));
    child_saw_zero = (0 == memcmp(zero, &janet_vm, sizeof(JanetVM)));
    child_vm = janet_local_vm();
    child_local_matches = (child_vm == &janet_vm);
    janet_vm.stackn = 99;
    return NULL;
}

/* Each thread gets its own VM, zero-initialised, and writing one leaves the
 * others alone. This is the property that makes the storage thread-local
 * rather than merely global, and it is the one thing a Zig `threadlocal var`
 * could plausibly get wrong while still linking. */
static void test_thread_local_storage(void) {
    pthread_t thread;
    main_vm = janet_local_vm();
    janet_vm.stackn = 7;
    assert(0 == pthread_create(&thread, NULL, child, NULL));
    assert(0 == pthread_join(thread, NULL));
    assert(child_local_matches);
    assert(child_saw_zero);
    assert(child_vm != main_vm);
    assert(janet_vm.stackn == 7);
    assert(janet_local_vm() == main_vm);
    janet_vm.stackn = 0;
}

#endif

/* ------------------------------------------------------ dynamic bindings */

/* janet_dyn and janet_setdyn choose between two tables, and which one is the
 * VM's business rather than the fiber's: a running fiber's own env when there
 * is one, janet_vm.top_dyns when there is not. Both tables are created lazily,
 * and the laziness is the part a port can quietly lose -- a reader that
 * allocated would turn every (dyn :missing) into a table.
 *
 * The Janet suites exercise this constantly through setdyn and dyn, but always
 * with a fiber running, so the no-fiber half below is reached by nothing else. */
static void test_dynamic_bindings(void) {
    JanetFiber *fiber;
    JanetFiber *saved = janet_vm.fiber;
    JanetTable *saved_dyns = janet_vm.top_dyns;

    janet_vm.fiber = NULL;
    janet_vm.top_dyns = NULL;

    /* A read finds nothing and creates nothing. */
    assert(janet_checktype(janet_dyn("nope"), JANET_NIL));
    assert(janet_vm.top_dyns == NULL);

    janet_setdyn("x", janet_wrap_integer(7));
    assert(janet_vm.top_dyns != NULL);
    assert(janet_equals(janet_dyn("x"), janet_wrap_integer(7)));
    assert(janet_checktype(janet_dyn("y"), JANET_NIL));

    /* With a fiber, the same names go to the fiber's env instead, and the VM's
     * table is neither read nor written. */
    fiber = janet_fiber(janet_thunk_delay(janet_wrap_nil()), 8, 0, NULL);
    assert(fiber != NULL);
    janet_gcroot(janet_wrap_fiber(fiber));
    assert(fiber->env == NULL);
    janet_vm.fiber = fiber;

    assert(janet_checktype(janet_dyn("x"), JANET_NIL));
    assert(fiber->env == NULL);

    janet_setdyn("x", janet_wrap_integer(9));
    assert(fiber->env != NULL);
    assert(janet_equals(janet_dyn("x"), janet_wrap_integer(9)));

    janet_vm.fiber = NULL;
    assert(janet_equals(janet_dyn("x"), janet_wrap_integer(7)));

    janet_gcunroot(janet_wrap_fiber(fiber));
    janet_vm.fiber = saved;
    janet_vm.top_dyns = saved_dyns;
}

void vm_state_contract(void) {
    test_layout_agrees();
    test_local_vm_is_janet_vm();
    test_alloc_and_free();
    test_save_load_round_trip();
    test_save_spans_the_structure();
    test_save_stays_inside_the_structure();
    test_interrupt_counter();
#if defined(JANET_VM_STATE_THREADS)
    test_thread_local_storage();
#endif

    /* Last, and the only case here that needs a live runtime. */
    janet_init();
    test_dynamic_bindings();
    janet_deinit();

    printf("vm state contract ok\n");
}
