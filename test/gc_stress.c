/* Stress contract for the two collector behaviours Phase 8's exit gate names
 * and no per-increment contract covers: allocation from inside a GC callback,
 * and the cross-thread facilities.
 *
 * This file is not a subsystem contract and has no selector of its own. The
 * other five stress bullets are covered where they belong -- root categories by
 * test/gc_alloc.c, deep and cyclic graphs by test/gc_mark.c, weak references by
 * test/gc_sweep.c, repeated init/deinit by the cycle test every Phase 8 contract
 * ends with, and mixed C/Zig calls by the fact that every contract is a C binary
 * calling Zig across a collection. These two are the remainder, and they are
 * here rather than split across three files because both are properties of the
 * collector as a whole rather than of any one function in it.
 *
 * ## Two of the assertions below pin defects
 *
 * A GC callback may not keep anything it allocates, and the two halves of that
 * sentence fail differently:
 *
 *  - Allocated from `gcmark`, during the mark phase: the block is prepended to
 *    `janet_vm.blocks` with its mark bit clear, and the sweep that follows in
 *    the same `janet_collect` frees it. The object is created and destroyed
 *    inside one collection and the caller never sees it live.
 *
 *  - Allocated from a finalizer, during the sweep: the outcome depends on where
 *    in the heap list the block being finalized sits. Mid-list it is fine and
 *    the new block is collected on the next cycle. At the *head* it is orphaned
 *    permanently -- `janet_sweep` restores the list head from a pointer it
 *    saved before the callback ran, which discards the prepend. The block is
 *    then reachable from nothing, is never finalized, is not freed by
 *    `janet_deinit`, and `janet_vm.block_count` counts it forever.
 *
 * Both are the C implementation's behaviour, byte for byte under either
 * selector, and both are in `FOUND.md`. They are pinned rather than merely
 * described because a leak is deterministic and observable -- unlike undefined
 * behaviour, which this phase's rules say not to pin.
 *
 * **This binary leaks on purpose and is excluded from the leak-checker gate.**
 * `PLAN.md` names which contracts `leaks --atExit` covers, and this is the one
 * it must not.
 *
 * ## The cross-thread half
 *
 * Threaded abstracts are the cross-thread facility Phase 8 owns; channels and
 * the event loop are Phase 9's and the standard library's. What is asserted is
 * the refcount's atomicity under contention, that each thread's heap is its own,
 * and that the last reference finalizes exactly once no matter which thread
 * drops it. It needs threads, so it is guarded the way test/fiber_core.c guards
 * its pthread half, and it needs `janet_vm.threaded_abstracts`, so it is also
 * behind JANET_EV.
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
#include "gc.h"

/* The cross-thread half needs real threads to say anything. A single-threaded
 * build has one process-wide VM by construction; the Windows path is
 * cross-compiled and never executed, so it is left out rather than written
 * blind. Same condition, and same reason, as test/fiber_core.c. */
#if !defined(JANET_SINGLE_THREADED) && !defined(JANET_WINDOWS) && defined(JANET_EV)
#define JANET_GC_STRESS_THREADS
#include <pthread.h>
#endif

/* ------------------------------------------------------------------ helpers */

/* The length of the main heap list, walked rather than counted. `block_count`
 * is the collector's own tally and the two are supposed to agree; where they do
 * not, a block is on the tally and on no list, which is the leak this file
 * pins. The bound stops a corrupt list from hanging the test. */
static size_t walk_blocks(void) {
    size_t n = 0;
    JanetGCObject *current = janet_vm.blocks;
    while (NULL != current && n < 1000000) {
        n++;
        current = current->data.next;
    }
    return n;
}

/* Blocks counted but not reachable from the list. Zero in a healthy runtime. */
static long orphaned_blocks(void) {
    return (long) janet_vm.block_count - (long) walk_blocks();
}

/* ------------------------------------------------- allocation from callbacks */

static int child_finalized;
static int parent_finalized;
static int allocations_left;

static int child_gc(void *data, size_t len) {
    (void) data;
    (void) len;
    child_finalized++;
    return 0;
}

static const JanetAbstractType at_child = {
    "gc-stress/child",
    child_gc, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL, NULL
};

/* A `gcmark` that allocates. Bounded by `allocations_left` so that marking
 * terminates: without the bound each new block would be marked in turn and the
 * callback would allocate forever. */
static int allocating_gcmark(void *data, size_t len) {
    (void) data;
    (void) len;
    if (allocations_left > 0) {
        allocations_left--;
        (void) janet_abstract(CONTRACT_AT(at_child), 8);
    }
    return 0;
}

static int parent_gc(void *data, size_t len) {
    (void) data;
    (void) len;
    parent_finalized++;
    return 0;
}

static const JanetAbstractType at_marking_parent = {
    "gc-stress/marking-parent",
    parent_gc, allocating_gcmark, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL, NULL
};

/* A finalizer that allocates while the sweep is walking the block list. */
static int allocating_gc(void *data, size_t len) {
    (void) data;
    (void) len;
    parent_finalized++;
    if (allocations_left > 0) {
        allocations_left--;
        (void) janet_abstract(CONTRACT_AT(at_child), 8);
    }
    return 0;
}

static const JanetAbstractType at_finalizing_parent = {
    "gc-stress/finalizing-parent",
    allocating_gc, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL, NULL
};

/* An object allocated from `gcmark` is freed by the collection that ran the
 * callback. The mark phase has already passed the head of the list by the time
 * the block is prepended, so nothing marks it, and the sweep in the same
 * `janet_collect` frees it and runs its finalizer.
 *
 * The finalizer count is what makes this observable without touching the freed
 * block: a third-party `gcmark` that allocated something and stored it would be
 * left holding a dangling pointer, and there is no safe way to read that. */
static void test_allocation_from_gcmark_dies_in_the_same_collection(void) {
    Janet parent;
    long orphans_before = orphaned_blocks();

    child_finalized = 0;
    parent_finalized = 0;
    allocations_left = 1;

    parent = janet_wrap_abstract(janet_abstract(CONTRACT_AT(at_marking_parent), 8));
    janet_gcroot(parent);

    janet_collect();
    assert(allocations_left == 0);          /* the callback ran */
    assert(child_finalized == 1);           /* and what it made is already gone */
    assert(parent_finalized == 0);          /* the parent itself is rooted */
    assert(orphaned_blocks() == orphans_before);

    janet_gcunroot(parent);
    janet_collect();
    assert(parent_finalized == 1);
    assert(child_finalized == 1);           /* nothing further to finalize */
}

/* A finalizer that allocates while its own block is *not* at the head of the
 * list behaves correctly. The prepend lands ahead of the sweep's walk position,
 * so the new block survives this collection untouched and is collected on the
 * next one, having never been marked.
 *
 * The keeper is allocated after the dying block and rooted, so it is the head
 * and is retained -- which is what puts the dying block mid-list with a
 * non-null predecessor. */
static void test_finalizer_allocation_survives_when_mid_list(void) {
    Janet keeper;
    long orphans_before = orphaned_blocks();

    child_finalized = 0;
    parent_finalized = 0;
    allocations_left = 1;

    (void) janet_abstract(CONTRACT_AT(at_finalizing_parent), 8);   /* unrooted: dies */
    keeper = janet_wrap_abstract(janet_abstract(CONTRACT_AT(at_child), 8));
    janet_gcroot(keeper);

    janet_collect();
    assert(parent_finalized == 1);
    assert(allocations_left == 0);
    assert(child_finalized == 0);                      /* survived this cycle */
    assert(orphaned_blocks() == orphans_before);       /* and is on the list */

    janet_collect();
    assert(child_finalized == 1);                      /* collected on the next */
    assert(orphaned_blocks() == orphans_before);

    janet_gcunroot(keeper);
    janet_collect();
    assert(child_finalized == 2);                      /* the keeper, in turn */
    assert(orphaned_blocks() == orphans_before);
}

/* The defect. When the block being finalized *is* the head of the heap list,
 * `janet_sweep` restores the head from the pointer it saved before running the
 * callback, and the block the callback allocated is discarded with it.
 *
 * What is asserted is every consequence: the block is counted and not on the
 * list, its finalizer never runs however many collections follow, and the gap
 * never closes. `FOUND.md` has the analysis. Nothing here dereferences the
 * orphan -- it is unreachable by construction, which is the whole problem. */
static void test_finalizer_allocation_is_orphaned_at_the_head(void) {
    long orphans_before = orphaned_blocks();

    child_finalized = 0;
    parent_finalized = 0;
    allocations_left = 1;

    /* Allocated last and left unrooted, so it is both the list head and dead. */
    (void) janet_abstract(CONTRACT_AT(at_finalizing_parent), 8);

    janet_collect();
    assert(parent_finalized == 1);
    assert(allocations_left == 0);                     /* the callback allocated */
    assert(child_finalized == 0);                      /* and it was never freed */
    assert(orphaned_blocks() == orphans_before + 1);   /* counted, not listed */

    /* No number of collections reclaims it, because nothing can reach it. */
    janet_collect();
    janet_collect();
    assert(child_finalized == 0);
    assert(orphaned_blocks() == orphans_before + 1);
}

/* ---------------------------------------------------------- cross-thread */

#ifdef JANET_GC_STRESS_THREADS

#define STRESS_THREADS 4
#define STRESS_ROUNDS 2000

static int threaded_finalized;
static void *shared_abstract;

static int threaded_gc(void *data, size_t len) {
    (void) data;
    (void) len;
    threaded_finalized++;
    return 0;
}

static const JanetAbstractType at_shared = {
    "gc-stress/shared",
    threaded_gc, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL, NULL
};

/* Each worker runs its own runtime, which is what a real second thread does.
 * The reference it takes is balanced before it exits, so the count returns to
 * exactly what the main thread left. */
static void *hammer_refcount(void *arg) {
    int i;
    (void) arg;
    janet_init();
    for (i = 0; i < STRESS_ROUNDS; i++) {
        janet_abstract_incref(shared_abstract);
        janet_abstract_decref(shared_abstract);
    }
    janet_deinit();
    return NULL;
}

/* The refcount is the whole cross-thread contract for a threaded abstract, and
 * it is the one thing here that a non-atomic implementation would still pass
 * every single-threaded test with. Four threads take and drop a reference two
 * thousand times each; a lost update shows up as a count that is not one. */
static void test_refcount_is_atomic_across_threads(void) {
    pthread_t threads[STRESS_THREADS];
    int i;

    shared_abstract = janet_abstract_threaded(CONTRACT_AT(at_shared), 16);
    assert(shared_abstract != NULL);

    for (i = 0; i < STRESS_THREADS; i++)
        assert(0 == pthread_create(&threads[i], NULL, hammer_refcount, NULL));
    for (i = 0; i < STRESS_THREADS; i++)
        assert(0 == pthread_join(threads[i], NULL));

    /* Back to the single reference this thread made it with. */
    assert(janet_abstract_incref(shared_abstract) == 2);
    assert(janet_abstract_decref(shared_abstract) == 1);
}

static size_t child_block_count;
static size_t child_saw_main_blocks;

static void *allocate_in_child(void *arg) {
    int i;
    (void) arg;
    child_saw_main_blocks = janet_vm.block_count;
    janet_init();
    for (i = 0; i < 64; i++)
        (void) janet_array(8);
    child_block_count = janet_vm.block_count;
    janet_collect();
    janet_deinit();
    return NULL;
}

/* Each thread's heap belongs to that thread. A port that reached a
 * process-wide `janet_vm` rather than the thread-local one would still pass
 * every other test in the tree: the damage is invisible until two runtimes
 * exist at once, and then it is heap corruption rather than a wrong answer. */
static void test_each_thread_has_its_own_heap(void) {
    pthread_t thread;
    size_t main_blocks_before = janet_vm.block_count;
    size_t main_walk_before = walk_blocks();

    assert(0 == pthread_create(&thread, NULL, allocate_in_child, NULL));
    assert(0 == pthread_join(thread, NULL));

    /* Before its own janet_init, the child's VM is zeroed rather than shared. */
    assert(child_saw_main_blocks == 0);
    assert(child_block_count >= 64);
    /* And nothing it did touched this thread's heap. */
    assert(janet_vm.block_count == main_blocks_before);
    assert(walk_blocks() == main_walk_before);
}

/* The finalizer runs on whichever thread drops the last reference, exactly
 * once. This one drops it on the main thread; the point is the count, not the
 * thread identity, which no part of the runtime promises. */
static void test_the_last_reference_finalizes_once(void) {
    void *abst = janet_abstract_threaded(CONTRACT_AT(at_shared), 16);
    pthread_t thread;

    threaded_finalized = 0;
    shared_abstract = abst;

    assert(0 == pthread_create(&thread, NULL, hammer_refcount, NULL));
    assert(0 == pthread_join(thread, NULL));
    assert(threaded_finalized == 0);

    /* This thread still holds the reference it was made with. Dropping it is
     * what frees the block and runs the finalizer. */
    janet_table_remove(&janet_vm.threaded_abstracts, janet_wrap_abstract(abst));
    assert(janet_abstract_decref_maybe_free(abst) == 0);
    assert(threaded_finalized == 1);
}

#endif /* JANET_GC_STRESS_THREADS */

/* ---------------------------------------------------------------- cycles */

/* Every Phase 8 contract ends by cycling the runtime, and this one has more
 * reason than most: the callbacks above run during collection, and a state they
 * corrupted would show up as a heap that stops being walkable. */
static void test_repeated_cycles(void) {
    int i;
    for (i = 0; i < 32; i++) {
        long orphans_before = orphaned_blocks();
        Janet parent;

        child_finalized = 0;
        parent_finalized = 0;
        allocations_left = 1;

        parent = janet_wrap_abstract(janet_abstract(CONTRACT_AT(at_marking_parent), 8));
        janet_gcroot(parent);
        janet_collect();
        assert(child_finalized == 1);
        janet_gcunroot(parent);
        janet_collect();
        assert(parent_finalized == 1);
        assert(orphaned_blocks() == orphans_before);
    }
}

void gc_stress_contract(void) {
    janet_init();
    janet_gcroot(janet_wrap_table(janet_core_env(NULL)));

    assert(orphaned_blocks() == 0);

    test_allocation_from_gcmark_dies_in_the_same_collection();
    test_finalizer_allocation_survives_when_mid_list();
    test_finalizer_allocation_is_orphaned_at_the_head();

#ifdef JANET_GC_STRESS_THREADS
    test_refcount_is_atomic_across_threads();
    test_each_thread_has_its_own_heap();
    test_the_last_reference_finalizes_once();
#endif

    test_repeated_cycles();

    janet_deinit();
    printf("gc stress contract ok\n");
}
