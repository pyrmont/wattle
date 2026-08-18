/* Behavioral contract for the collector's sweep: dropping dead weak
 * references, unlinking and freeing unreachable blocks, running finalizers,
 * and tearing the heap down at `janet_deinit`. Run against whichever
 * implementation the build selected (`-Dgc-sweep=c` or the Zig default).
 *
 * The sweep is driven through `janet_collect` rather than by calling
 * `janet_sweep` directly, and that is not a convenience. `janet_sweep` frees
 * every block the mark phase did not reach, so calling it against a hand-made
 * mark set would free the core environment along with everything else. Driving
 * it through a collection means liveness is expressed the way the runtime
 * expresses it -- a value is alive because it is rooted -- and the mark phase
 * is an input to this contract rather than part of it.
 *
 * Freeing is mostly invisible: a freed block cannot be read, and a `janet_free`
 * that does not happen leaves nothing to observe from inside the process. So
 * three channels stand in for it. `janet_vm.block_count` counts blocks and is
 * decremented exactly once per block freed. An abstract type's `gc` and
 * `gcperthread` callbacks fire on the way out and can count themselves.
 * And `janet_vm.cache_count` falls when a symbol block leaves the symbol
 * cache, which is the only external obligation any immutable block has.
 *
 * What that leaves uncovered is honest to state: the `janet_free` calls inside
 * `janet_deinit_block` for an array's, a table's, a fiber's or a funcdef's
 * payload are leaks when omitted and double frees when duplicated, and neither
 * is observable here. A leak checker sees the first; the second is what the
 * repeated init/deinit cycle at the end of this file would catch.
 *
 * Nothing here exercises a panicking finalizer. SPIKE-8 settled that an
 * abstract callback may not raise, and `SPIKE-8.md` records what the C runtime
 * does when one does anyway -- which for a finalizer is to poison the heap
 * permanently, an entry in `FOUND.md`.
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
#include "gc.h"

/* ------------------------------------------------------------------ helpers */

static int reachable(void *p) {
    return (janet_gc_header(p)->flags & JANET_MEM_REACHABLE) != 0;
}

/* Whether a block is still on one of the two heap lists. Only ever called for
 * a block that is known to have survived, so nothing freed is dereferenced. */
static int on_list(void *list, void *block) {
    JanetGCObject *current = (JanetGCObject *) list;
    while (NULL != current) {
        if ((void *) current == block) return 1;
        current = current->data.next;
    }
    return 0;
}

/* Start from a heap with nothing collectable left over from an earlier case,
 * so that a block count taken here means what the next case assumes. */
static void settle(void) {
    janet_collect();
}

/* ------------------------------------------------------------ probe types */

static int gc_calls;
static void *gc_data;
static size_t gc_size;

static int probe_gc(void *data, size_t len) {
    gc_calls++;
    gc_data = data;
    gc_size = len;
    return 0;
}

static char order_log[8];
static int order_len;

static void log_order(char ch) {
    if (order_len < (int) sizeof(order_log)) order_log[order_len++] = ch;
}

static int probe_gc_ordered(void *data, size_t len) {
    (void) data;
    (void) len;
    log_order('G');
    return 0;
}

static int probe_perthread_ordered(void *data, size_t len) {
    (void) data;
    (void) len;
    log_order('P');
    return 0;
}

static const JanetAbstractType at_final = {
    "gc-sweep-test/final",
    probe_gc, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL
};

static const JanetAbstractType at_ordered = {
    "gc-sweep-test/ordered",
    probe_gc_ordered, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, probe_perthread_ordered
};

static const JanetAbstractType at_plain = {
    "gc-sweep-test/plain",
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL
};

/* ------------------------------------------------------------ head layout */

/* Zig cannot ask for `offsetof(JanetStringHead, data)`: translate-c drops
 * flexible array members, so `gc_sweep.zig` crosses every header with `@sizeOf`
 * instead -- in both directions, since the sweep recovers a symbol's bytes and
 * an abstract's payload from the block as well as recovering heads from
 * values. The two spellings agree only where the flexible array needs no
 * padding after the last declared field. That is a property of the C layout, so
 * it is checked here, in C, where both spellings exist -- and it is checked
 * against `c` as well, where it is merely true rather than load-bearing. */
static void test_head_offsets(void) {
    assert(sizeof(JanetStringHead) == offsetof(JanetStringHead, data));
    assert(sizeof(JanetTupleHead) == offsetof(JanetTupleHead, data));
    assert(sizeof(JanetStructHead) == offsetof(JanetStructHead, data));
    assert(sizeof(JanetAbstractHead) == offsetof(JanetAbstractHead, data));
}

/* --------------------------------------------------------- freeing blocks */

/* The block count is the sweep's arithmetic made visible: one decrement per
 * block freed, and no decrement for a block kept. */
static void test_sweep_frees_unreachable_blocks(void) {
    settle();
    size_t before = janet_vm.block_count;

    for (int i = 0; i < 16; i++) {
        (void) janet_buffer(8);
    }
    assert(janet_vm.block_count == before + 16);

    janet_collect();
    assert(janet_vm.block_count == before);
}

/* A survivor stays on its list, keeps its payload, and loses its mark. The
 * last part is what makes the next collection meaningful: `REACHABLE` is
 * cleared on the way past, so every mark phase starts from a clean heap. */
static void test_sweep_keeps_survivors_and_clears_the_mark(void) {
    settle();
    size_t before = janet_vm.block_count;

    JanetBuffer *b = janet_buffer(8);
    janet_buffer_push_cstring(b, "still here");
    Janet v = janet_wrap_buffer(b);
    janet_gcroot(v);

    janet_collect();
    assert(janet_vm.block_count == before + 1);
    assert(on_list(janet_vm.blocks, b));
    assert(!reachable(b));
    assert(b->count == 10);
    assert(0 == memcmp(b->data, "still here", 10));

    janet_gcunroot(v);
    janet_collect();
    assert(janet_vm.block_count == before);
}

/* `JANET_MEM_DISABLED` holds a block through a sweep that never reached it,
 * and unlike `JANET_MEM_REACHABLE` it is not cleared on the way past -- it
 * holds the block through every later sweep too, until whoever set it clears
 * it. `janet_buffer_init` sets it on a caller-owned buffer for exactly that
 * reason; here it is set by hand on a heap block, which is the general case
 * the flag is defined for. */
static void test_sweep_preserves_disabled(void) {
    settle();
    size_t before = janet_vm.block_count;

    JanetBuffer *b = janet_buffer(8);
    b->gc.flags |= JANET_MEM_DISABLED;

    janet_collect();
    assert(janet_vm.block_count == before + 1);
    assert(on_list(janet_vm.blocks, b));
    assert((b->gc.flags & JANET_MEM_DISABLED) != 0);
    assert(!reachable(b));

    janet_collect();
    assert(janet_vm.block_count == before + 1);

    b->gc.flags &= ~JANET_MEM_DISABLED;
    janet_collect();
    assert(janet_vm.block_count == before);
}

/* ----------------------------------------------------------- finalization */

/* A finalizer runs once, on the way out, with the pointer and size the runtime
 * handed the type -- not the block address, and not the header size. */
static void test_finalizer_runs_once_with_the_abstract(void) {
    settle();
    void *a = janet_abstract(&at_final, 24);
    gc_calls = 0;
    gc_data = NULL;
    gc_size = 0;

    janet_collect();
    assert(gc_calls == 1);
    assert(gc_data == a);
    assert(gc_size == 24);

    janet_collect();
    assert(gc_calls == 1);
}

/* A block that survives is not finalized. The pair matters more than either
 * half: it is the only place the contract says the callback is driven by
 * reachability rather than by the sweep visiting the block. */
static void test_survivor_is_not_finalized(void) {
    settle();
    void *a = janet_abstract(&at_final, 8);
    Janet v = janet_wrap_abstract(a);
    janet_gcroot(v);
    gc_calls = 0;

    janet_collect();
    assert(gc_calls == 0);

    janet_gcunroot(v);
    janet_collect();
    assert(gc_calls == 1);
}

/* Both finalizers run, and `gcperthread` runs first. The order is not
 * incidental: the per-thread callback releases what belongs to this
 * interpreter, and the type's `gc` releases what the value owns outright, so
 * reversing them would let `gc` free memory `gcperthread` still reads. */
static void test_perthread_finalizer_runs_before_gc(void) {
    settle();
    (void) janet_abstract(&at_ordered, 8);
    order_len = 0;

    janet_collect();
    assert(order_len == 2);
    assert(order_log[0] == 'P');
    assert(order_log[1] == 'G');
}

/* An abstract with no callbacks at all is freed without incident. The `gc.c`
 * original tests each slot before calling it, and a type may fill neither. */
static void test_abstract_without_finalizers(void) {
    settle();
    size_t before = janet_vm.block_count;
    (void) janet_abstract(&at_plain, 8);
    assert(janet_vm.block_count == before + 1);
    janet_collect();
    assert(janet_vm.block_count == before);
}

/* A symbol is the one immutable block with an obligation outside its own
 * allocation: it has to leave the symbol cache, or the cache keeps a pointer
 * into freed memory and the next symbol with those bytes is handed it. The
 * cache counters are the observation -- `janet_symbol_deinit` decrements the
 * live count and increments the deleted count, in place. */
static void test_symbol_leaves_the_cache(void) {
    settle();
    uint32_t count = janet_vm.cache_count;
    uint32_t deleted = janet_vm.cache_deleted;

    (void) janet_csymbolv("gc-sweep-test-unique-symbol");
    assert(janet_vm.cache_count == count + 1);

    janet_collect();
    assert(janet_vm.cache_count == count);
    assert(janet_vm.cache_deleted == deleted + 1);
}

/* ------------------------------------------------------------- weak heap */

/* A weak array keeps its shape and loses its dead elements. The count does not
 * change and the live entries do not move: a dead slot becomes nil in place,
 * which is what lets an index into a weak array stay meaningful across a
 * collection. Immediates have no header to consult and are always live. */
static void test_weak_array_drops_dead_elements(void) {
    settle();
    JanetArray *w = janet_array_weak(4);
    janet_gcroot(janet_wrap_array(w));

    JanetBuffer *live = janet_buffer(8);
    janet_gcroot(janet_wrap_buffer(live));
    JanetBuffer *dead = janet_buffer(8);

    janet_array_push(w, janet_wrap_buffer(live));
    janet_array_push(w, janet_wrap_buffer(dead));
    janet_array_push(w, janet_wrap_integer(42));

    janet_collect();

    assert(w->count == 3);
    assert(janet_unwrap_buffer(w->data[0]) == live);
    assert(janet_checktype(w->data[1], JANET_NIL));
    assert(janet_unwrap_integer(w->data[2]) == 42);

    janet_gcunroot(janet_wrap_buffer(live));
    janet_gcunroot(janet_wrap_array(w));
}

/* Which half of an entry is checked is what makes a table weak, and it mirrors
 * the mark phase exactly: whichever half the walk did not mark is the half that
 * may have died. A weak-keyed table therefore keeps an entry whose value is
 * otherwise unreferenced -- the walk marked that value -- and drops one whose
 * key is. A dropped entry becomes the (nil, false) tombstone `janet_table_put`
 * writes, so the count falls and the deleted count rises. */
static void test_weak_table_variants(void) {
    settle();

    JanetTable *weakk = janet_table_weakk(4);
    JanetTable *weakv = janet_table_weakv(4);
    JanetTable *weakkv = janet_table_weakkv(4);
    JanetTable *strong = janet_table(4);
    janet_gcroot(janet_wrap_table(weakk));
    janet_gcroot(janet_wrap_table(weakv));
    janet_gcroot(janet_wrap_table(weakkv));
    janet_gcroot(janet_wrap_table(strong));

    JanetBuffer *live = janet_buffer(8);
    janet_gcroot(janet_wrap_buffer(live));
    Janet livev = janet_wrap_buffer(live);

    /* One entry per table with a doomed key, one with a doomed value. */
    janet_table_put(weakk, janet_wrap_buffer(janet_buffer(8)), livev);
    janet_table_put(weakk, livev, janet_wrap_buffer(janet_buffer(8)));
    janet_table_put(weakv, janet_wrap_buffer(janet_buffer(8)), livev);
    janet_table_put(weakv, livev, janet_wrap_buffer(janet_buffer(8)));
    janet_table_put(weakkv, janet_wrap_buffer(janet_buffer(8)), livev);
    janet_table_put(weakkv, livev, janet_wrap_buffer(janet_buffer(8)));
    janet_table_put(strong, janet_wrap_buffer(janet_buffer(8)), livev);
    janet_table_put(strong, livev, janet_wrap_buffer(janet_buffer(8)));

    assert(weakk->count == 2 && weakv->count == 2 && weakkv->count == 2);
    int32_t deleted = weakk->deleted;

    janet_collect();

    /* Weak keys: the doomed-key entry goes, the doomed-value one stays
     * because a weak-keyed table's values are marked. */
    assert(weakk->count == 1);
    assert(weakk->deleted == deleted + 1);
    assert(!janet_checktype(janet_table_get(weakk, livev), JANET_NIL));

    /* Weak values: the mirror image. */
    assert(weakv->count == 1);
    assert(janet_checktype(janet_table_get(weakv, livev), JANET_NIL));

    /* Weak in both halves: neither entry survives. */
    assert(weakkv->count == 0);

    /* A strong table marks both halves, so nothing in it can die. */
    assert(strong->count == 2);
    assert(!janet_checktype(janet_table_get(strong, livev), JANET_NIL));

    janet_gcunroot(janet_wrap_buffer(live));
    janet_gcunroot(janet_wrap_table(weakk));
    janet_gcunroot(janet_wrap_table(weakv));
    janet_gcunroot(janet_wrap_table(weakkv));
    janet_gcunroot(janet_wrap_table(strong));
}

/* The weak heap is swept for blocks as well as for references. A weak
 * container nothing refers to is freed like any other block -- it is on a
 * separate list, not exempt from collection. */
static void test_weak_containers_are_collected(void) {
    settle();
    size_t before = janet_vm.block_count;

    (void) janet_array_weak(4);
    (void) janet_table_weakk(4);
    (void) janet_table_weakv(4);
    (void) janet_table_weakkv(4);
    assert(janet_vm.block_count == before + 4);

    janet_collect();
    assert(janet_vm.block_count == before);
}

/* A weak reference to a block that is itself dying is dropped, not read after
 * it is freed. That is the whole reason the weak heap is walked twice: the
 * first pass consults the mark of every value a surviving weak container holds,
 * and the second frees. Reversing them would make this case a use-after-free
 * rather than a wrong answer, so what is asserted here is only that the
 * survivor is intact and empty; a sanitizer is what sees the difference. */
static void test_weak_entry_and_its_target_die_together(void) {
    settle();
    size_t before = janet_vm.block_count;

    JanetTable *w = janet_table_weakv(4);
    janet_gcroot(janet_wrap_table(w));
    janet_table_put(w, janet_ckeywordv("doomed"), janet_wrap_buffer(janet_buffer(8)));
    assert(w->count == 1);

    janet_collect();

    assert(w->count == 0);
    assert(on_list(janet_vm.weak_blocks, w));

    /* The table and its key survive this collection; the buffer does not. The
     * key is alive because a weak-valued table marks its keys -- the entry was
     * dropped by the sweep, after the walk had already reached the keyword
     * through it. The next collection is where the keyword goes, which is the
     * one collection of lag a weak table costs. */
    assert(janet_vm.block_count == before + 2);
    janet_collect();
    assert(janet_vm.block_count == before + 1);

    janet_gcunroot(janet_wrap_table(w));
}

/* -------------------------------------------------- threaded abstracts */

#ifdef JANET_EV

static int threaded_gc_calls;
static int threaded_perthread_calls;

static int probe_threaded_gc(void *data, size_t len) {
    (void) data;
    (void) len;
    threaded_gc_calls++;
    return 0;
}

static int probe_threaded_perthread(void *data, size_t len) {
    (void) data;
    (void) len;
    threaded_perthread_calls++;
    return 0;
}

static const JanetAbstractType at_threaded = {
    "gc-sweep-test/threaded",
    probe_threaded_gc, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, probe_threaded_perthread
};

/* A threaded abstract is not on either heap list, so the sweep decides its
 * fate through `janet_vm.threaded_abstracts` instead. The table is a visit
 * record: the mark phase writes true for every threaded abstract it reaches,
 * and the sweep reads the entry and resets it to false for next time. An entry
 * still false is one this interpreter no longer refers to, so this
 * interpreter's reference goes -- and because the last reference anywhere is
 * what frees the value, the type's `gc` runs exactly once across every
 * interpreter that ever held it. */
static void test_threaded_abstract_loses_its_reference(void) {
    settle();
    void *a = janet_abstract_threaded(&at_threaded, 8);
    Janet v = janet_wrap_abstract(a);
    janet_gcroot(v);
    threaded_gc_calls = 0;
    threaded_perthread_calls = 0;

    int32_t tracked = janet_vm.threaded_abstracts.count;
    janet_collect();
    assert(threaded_perthread_calls == 0);
    assert(threaded_gc_calls == 0);
    assert(janet_vm.threaded_abstracts.count == tracked);

    janet_gcunroot(v);
    janet_collect();
    assert(threaded_perthread_calls == 1);
    assert(threaded_gc_calls == 1);
    assert(janet_vm.threaded_abstracts.count == tracked - 1);

    /* The entry is a tombstone now, so a later sweep must not find it again. */
    janet_collect();
    assert(threaded_perthread_calls == 1);
    assert(threaded_gc_calls == 1);
}

#endif

/* -------------------------------------------------------------- teardown */

/* `janet_clear_memory` is not a collection. Nothing is marked, rooting buys a
 * block nothing, and every finalizer runs -- which is what makes `janet_deinit`
 * safe to call with live values outstanding.
 *
 * The last assertion pins a defect rather than a guarantee, and is written that
 * way on purpose. `janet_clear_memory` walks `janet_vm.blocks` and never
 * touches `janet_vm.weak_blocks`, so every weak table and weak array alive at
 * teardown leaks its block and its data array. The list head still pointing at
 * them after `janet_deinit` returns is that leak, visible from inside the
 * process. `FOUND.md` records it; the port reproduces it, so the assertion
 * holds for both selectors and will fail for whichever is fixed first. */
static void test_clear_memory_finalizes_everything(void) {
    void *a = janet_abstract(&at_final, 8);
    janet_gcroot(janet_wrap_abstract(a));
    (void) janet_abstract(&at_final, 8);
    gc_calls = 0;

    JanetTable *w = janet_table_weakv(4);
    janet_gcroot(janet_wrap_table(w));

    janet_deinit();

    assert(gc_calls == 2);
    assert(janet_vm.blocks == NULL);
    assert(janet_vm.weak_blocks != NULL);

    janet_init();
}

/* A second cycle over a heap that has held every block type. Nothing is
 * asserted beyond arriving here: this is the case that fails by crashing, and
 * it is the only coverage the port has for the `janet_free` calls inside
 * `janet_deinit_block` that a leak checker would otherwise have to find. */
static void test_repeated_cycles(void) {
    for (int i = 0; i < 3; i++) {
        JanetTable *t = janet_table(4);
        janet_gcroot(janet_wrap_table(t));
        janet_table_put(t, janet_ckeywordv("array"), janet_wrap_array(janet_array(4)));
        janet_table_put(t, janet_ckeywordv("buffer"), janet_wrap_buffer(janet_buffer(8)));
        janet_table_put(t, janet_ckeywordv("weak"), janet_wrap_array(janet_array_weak(4)));
        janet_table_put(t, janet_ckeywordv("abstract"), janet_wrap_abstract(janet_abstract(&at_plain, 8)));
        Janet f = janet_wrap_nil();
        janet_dostring(janet_core_env(NULL), "(fn [] 1)", "gc-sweep-test", &f);
        assert(janet_checktype(f, JANET_FUNCTION));
        janet_table_put(t, janet_ckeywordv("fiber"),
                        janet_wrap_fiber(janet_fiber(janet_unwrap_function(f), 8, 0, NULL)));
        janet_collect();
        janet_deinit();
        janet_init();
    }
}

int main(void) {
    janet_init();

    test_head_offsets();

    test_sweep_frees_unreachable_blocks();
    test_sweep_keeps_survivors_and_clears_the_mark();
    test_sweep_preserves_disabled();

    test_finalizer_runs_once_with_the_abstract();
    test_survivor_is_not_finalized();
    test_perthread_finalizer_runs_before_gc();
    test_abstract_without_finalizers();
    test_symbol_leaves_the_cache();

    test_weak_array_drops_dead_elements();
    test_weak_table_variants();
    test_weak_containers_are_collected();
    test_weak_entry_and_its_target_die_together();

#ifdef JANET_EV
    test_threaded_abstract_loses_its_reference();
#endif

    test_clear_memory_finalizes_everything();
    test_repeated_cycles();

    janet_deinit();
    printf("gc sweep contract ok\n");
    return 0;
}
