/* Behavioral contract for abstract value construction and the threaded
 * abstract refcount: `janet_abstract_begin`, `janet_abstract_end`,
 * `janet_abstract`, their threaded counterparts, and
 * `janet_abstract_incref`, `janet_abstract_decref` and
 * `janet_abstract_decref_maybe_free`. Run against whichever implementation the
 * build selected (`-Dabstract-core=c` or the Zig default).
 *
 * These nine functions are almost all bookkeeping, and bookkeeping is what has
 * to be checked, because the return values agree between a correct
 * implementation and several wrong ones. Four channels carry it:
 *
 *  - `janet_abstract_head` recovers the header, so `size`, `type` and the raw
 *    `gc.flags` word are readable directly. The flags word is where the
 *    difference between `janet_gc_settype`'s or and a plain store shows up, and
 *    nothing else observes it.
 *  - `janet_vm.blocks` and `janet_vm.block_count` say whether the collector was
 *    given the block. A plain abstract must be on the list; a threaded one must
 *    be on neither list.
 *  - `janet_vm.next_collection` says what the block was charged, and the two
 *    allocators charge it by different arithmetic to the same total.
 *  - `janet_vm.threaded_abstracts` is the visit record a threaded abstract is
 *    registered in at birth, and the type's `gc` callback counts its own calls
 *    on the way out.
 *
 * The two-step protocol gets a test of its own because it is the only reason
 * `janet_abstract_begin` exists separately: a collection between the two calls
 * must free the block without traversing or finalizing it, and an abstract type
 * whose `gcmark` and `gc` count their calls is what proves it.
 *
 * Nothing here exercises a panicking callback. SPIKE-8 settled that an abstract
 * callback may not raise; `SPIKE-8.md` records what the C runtime does when one
 * does anyway.
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

/* Zig cannot ask for `offsetof(JanetAbstractHead, data)`: translate-c drops the
 * flexible array member, so the port recovers the header with
 * `@sizeOf(JanetAbstractHead)` instead. That is only correct while the two are
 * equal, and C is the only side that can check. */
static void test_head_offset(void) {
    assert(sizeof(JanetAbstractHead) == offsetof(JanetAbstractHead, data));
}

/* Whether a block is on one of the two heap lists. Only ever called for a block
 * known to be alive, so nothing freed is dereferenced. */
static int on_list(void *list, void *block) {
    JanetGCObject *current = (JanetGCObject *) list;
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

static int mark_calls;
static int gc_calls;
static int perthread_calls;

static int probe_gcmark(void *data, size_t len) {
    (void) data;
    (void) len;
    mark_calls++;
    return 0;
}

static int probe_gc(void *data, size_t len) {
    (void) data;
    (void) len;
    gc_calls++;
    return 0;
}

static int probe_perthread(void *data, size_t len) {
    (void) data;
    (void) len;
    perthread_calls++;
    return 0;
}

static const JanetAbstractType at_counted = {
    "abstract-core-test/counted",
    probe_gc, probe_gcmark, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, probe_perthread
};

/* The same type with no callbacks at all. Freeing one of these must not reach
 * for a null function pointer. */
static const JanetAbstractType at_bare = {
    "abstract-core-test/bare",
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL
};

/* ------------------------------------------------------- plain construction */

/* `janet_abstract_begin` writes the two header fields and nothing else, and
 * hands the block to the collector tagged `JANET_MEMORY_NONE`. The tag is the
 * whole point: the payload is uninitialised at this moment and the block is
 * already reachable from `janet_vm.blocks`. */
static void test_begin_publishes_an_untyped_block(void) {
    settle();
    size_t before_count = janet_vm.block_count;
    size_t before_charge = janet_vm.next_collection;

    void *a = janet_abstract_begin(&at_counted, 40);
    JanetAbstractHead *head = janet_abstract_head(a);

    assert(head->size == 40);
    assert(head->type == &at_counted);
    assert(janet_gc_type(head) == JANET_MEMORY_NONE);
    assert(0 == (head->gc.flags & JANET_MEM_REACHABLE));

    assert(janet_vm.block_count == before_count + 1);
    assert(on_list(janet_vm.blocks, head));
    assert(!on_list(janet_vm.weak_blocks, head));
    assert(janet_vm.next_collection ==
           before_charge + sizeof(JanetAbstractHead) + 40);

    /* The pointer handed out is the payload, and the head is exactly one
     * header behind it. */
    assert((char *) a == (char *) head + sizeof(JanetAbstractHead));
    assert(janet_abstract_size(a) == 40);
    assert(janet_abstract_type(a) == &at_counted);

    /* `long long data[]` is the most general alignment the header can ask for,
     * so the payload is aligned for anything an embedder puts in it. */
    assert(0 == ((uintptr_t) a % sizeof(long long)));

    janet_abstract_end(a);
}

/* `janet_abstract_end` writes the type tag and returns the same pointer. */
static void test_end_types_the_block(void) {
    void *a = janet_abstract_begin(&at_counted, 8);
    JanetAbstractHead *head = janet_abstract_head(a);
    assert(janet_gc_type(head) == JANET_MEMORY_NONE);

    void *b = janet_abstract_end(a);
    assert(b == a);
    assert(janet_gc_type(head) == JANET_MEMORY_ABSTRACT);
    assert(head->size == 8);
    assert(head->type == &at_counted);
}

/* `janet_gc_settype` is an or, not a store, and this is the only place the
 * difference is visible: a block marked reachable by a collection that ran
 * between `begin` and `end` must still be marked afterwards. A store would
 * clear `JANET_MEM_REACHABLE` and the sweep would then free a block the caller
 * is about to use. */
static void test_end_preserves_the_other_flag_bits(void) {
    void *a = janet_abstract_begin(&at_counted, 8);
    JanetAbstractHead *head = janet_abstract_head(a);

    janet_gc_mark(head);
    head->gc.flags |= JANET_MEM_DISABLED;
    assert(0 != (head->gc.flags & JANET_MEM_REACHABLE));

    janet_abstract_end(a);
    assert(janet_gc_type(head) == JANET_MEMORY_ABSTRACT);
    assert(0 != (head->gc.flags & JANET_MEM_REACHABLE));
    assert(0 != (head->gc.flags & JANET_MEM_DISABLED));

    /* Leave nothing marked or disabled behind for the next test. */
    head->gc.flags &= ~(JANET_MEM_REACHABLE | JANET_MEM_DISABLED);
}

/* `janet_abstract` is the two calls in one, and must charge and tag exactly as
 * they do separately. */
static void test_abstract_is_begin_then_end(void) {
    settle();
    size_t before_count = janet_vm.block_count;
    size_t before_charge = janet_vm.next_collection;

    void *a = janet_abstract(&at_counted, 24);
    JanetAbstractHead *head = janet_abstract_head(a);

    assert(janet_gc_type(head) == JANET_MEMORY_ABSTRACT);
    assert(head->size == 24);
    assert(head->type == &at_counted);
    assert(janet_vm.block_count == before_count + 1);
    assert(on_list(janet_vm.blocks, head));
    assert(janet_vm.next_collection ==
           before_charge + sizeof(JanetAbstractHead) + 24);
}

/* A zero-length abstract is a header and nothing else, and is legal. */
static void test_zero_length_abstract(void) {
    void *a = janet_abstract(&at_bare, 0);
    JanetAbstractHead *head = janet_abstract_head(a);
    assert(head->size == 0);
    assert(janet_gc_type(head) == JANET_MEMORY_ABSTRACT);
}

/* The payload is untouched by construction, so an embedder that writes it
 * before `janet_abstract_end` finds it intact afterwards. */
static void test_payload_survives_end(void) {
    void *a = janet_abstract_begin(&at_bare, 16);
    memset(a, 0x5a, 16);
    janet_abstract_end(a);
    for (int i = 0; i < 16; i++) assert(((unsigned char *) a)[i] == 0x5a);
}

/* ------------------------------------------------------ the two-step window */

/* The reason `begin` and `end` are separate. A block tagged
 * `JANET_MEMORY_NONE` is on the heap list and visible to the collector with an
 * uninitialised payload, and what makes that safe is the sweep rather than the
 * mark phase: `janet_deinit_block` has no case for that tag, so the block is
 * freed without its finalizer running and without anything reading a field of
 * the payload. An abstract type whose `gc` frees a pointer it has not been
 * given yet is the crash this prevents. */
static void test_collection_between_begin_and_end(void) {
    settle();
    mark_calls = 0;
    gc_calls = 0;
    perthread_calls = 0;

    size_t counted = janet_vm.block_count;
    void *a = janet_abstract_begin(&at_counted, 32);
    assert(janet_vm.block_count == counted + 1);
    (void) a;

    /* Nothing refers to it, so the collection frees it -- untyped, so neither
     * finalizer runs and the payload is never read. */
    janet_collect();
    assert(janet_vm.block_count == counted);
    assert(mark_calls == 0);
    assert(gc_calls == 0);
    assert(perthread_calls == 0);
}

/* What the tag does *not* do is keep the traversal away. The mark phase
 * dispatches on the type of the `Janet` it is given, not on the block's memory
 * tag, so an embedder that wraps and roots the block before filling it in gets
 * `gcmark` called on an uninitialised payload. That is the C behaviour and the
 * port reproduces it; the caller's obligation is to root the value after
 * `janet_abstract_end`, not before. Pinned here so that a port which "fixed"
 * it by tagging early would be caught. */
static void test_the_window_does_not_stop_the_traversal(void) {
    settle();
    mark_calls = 0;
    gc_calls = 0;
    perthread_calls = 0;

    void *a = janet_abstract_begin(&at_counted, 32);
    Janet v = janet_wrap_abstract(a);
    janet_gcroot(v);

    size_t counted = janet_vm.block_count;
    janet_collect();

    assert(janet_vm.block_count == counted);
    assert(mark_calls == 1);
    assert(gc_calls == 0);
    assert(janet_gc_type(janet_abstract_head(a)) == JANET_MEMORY_NONE);

    janet_gcunroot(v);
    janet_collect();

    /* Freed, and still never finalized: the sweep is where the tag decides. */
    assert(janet_vm.block_count == counted - 1);
    assert(gc_calls == 0);
    assert(perthread_calls == 0);
}

/* Once `janet_abstract_end` has run, the same block is traversed and finalized
 * like any other abstract. Without this, an implementation that never tags the
 * block at all passes every test above. */
static void test_a_finished_abstract_is_traversed_and_finalized(void) {
    settle();
    mark_calls = 0;
    gc_calls = 0;
    perthread_calls = 0;

    void *a = janet_abstract(&at_counted, 32);
    Janet v = janet_wrap_abstract(a);
    janet_gcroot(v);

    janet_collect();
    assert(mark_calls == 1);
    assert(gc_calls == 0);

    janet_gcunroot(v);
    janet_collect();
    assert(gc_calls == 1);
    assert(perthread_calls == 1);
}

/* ---------------------------------------------------- threaded construction */

#ifdef JANET_EV

static int threaded_gc_calls;
static void *threaded_gc_data;
static size_t threaded_gc_len;

/* The finalizer records what it was handed. `janet_abstract_decref_maybe_free`
 * calls it as `head->type->gc(head->data, head->size)`, and both arguments are
 * easy to get wrong in a way no return value reveals: the header is one word
 * from the payload, and `size` is the only place the payload's length is
 * recorded once the caller has let go of it. */
static int probe_threaded_gc(void *data, size_t len) {
    threaded_gc_data = data;
    threaded_gc_len = len;
    threaded_gc_calls++;
    return 0;
}

static const JanetAbstractType at_threaded = {
    "abstract-core-test/threaded",
    probe_threaded_gc, probe_gcmark, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL
};

static const JanetAbstractType at_threaded_bare = {
    "abstract-core-test/threaded-bare",
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL
};

/* Drop the reference this interpreter holds, the way the sweep does: take the
 * entry out of the visit record first, then decrement. That order is not a
 * tidiness -- freeing the block while `janet_vm.threaded_abstracts` still keys
 * on it leaves the next collection reading a freed header, which is why every
 * threaded test here ends this way rather than by calling
 * `janet_abstract_decref_maybe_free` alone. */
static int32_t drop(void *a) {
    janet_table_remove(&janet_vm.threaded_abstracts, janet_wrap_abstract(a));
    return janet_abstract_decref_maybe_free(a);
}

/* Whether the visit record holds this abstract. `janet_table_get` returns nil
 * for an absent key and the stored boolean for a present one, and the sweep
 * distinguishes the two, so the test does as well. */
static int tracked(void *a) {
    return !janet_checktype(janet_table_get(&janet_vm.threaded_abstracts,
                                            janet_wrap_abstract(a)), JANET_NIL);
}

/* A threaded abstract is `janet_malloc`ed, not `janet_gcalloc`ed. It is on
 * neither heap list and the block count does not move -- what records it is the
 * visit table, and what keeps it alive is the refcount that starts at one. */
static void test_begin_threaded_registers_without_the_heap(void) {
    settle();
    size_t before_count = janet_vm.block_count;
    size_t before_charge = janet_vm.next_collection;
    int32_t before_tracked = janet_vm.threaded_abstracts.count;
    int32_t before_capacity = janet_vm.threaded_abstracts.capacity;

    void *a = janet_abstract_begin_threaded(&at_threaded_bare, 48);
    JanetAbstractHead *head = janet_abstract_head(a);

    assert(head->size == 48);
    assert(head->type == &at_threaded_bare);
    assert(janet_gc_type(head) == JANET_MEMORY_THREADED_ABSTRACT);
    assert(head->gc.data.refcount == 1);

    assert(janet_vm.block_count == before_count);
    assert(!on_list(janet_vm.blocks, head));
    assert(!on_list(janet_vm.weak_blocks, head));

    /* The threaded path adds `size + sizeof(head)` by hand where
     * `janet_gcalloc` adds the size it was asked for. Same total -- plus
     * whatever the visit table charged if this entry made it rehash, since
     * `janet_memalloc_empty` bills its new bucket array to the same counter. */
    size_t table_charge = 0;
    if (janet_vm.threaded_abstracts.capacity != before_capacity)
        table_charge = (size_t) janet_vm.threaded_abstracts.capacity * sizeof(JanetKV);
    assert(janet_vm.next_collection ==
           before_charge + sizeof(JanetAbstractHead) + 48 + table_charge);

    assert(janet_vm.threaded_abstracts.count == before_tracked + 1);
    assert(tracked(a));

    /* Registered false: the visit record starts unvisited, and a mark phase is
     * what sets it. */
    assert(janet_checktype(janet_table_get(&janet_vm.threaded_abstracts,
                                           janet_wrap_abstract(a)), JANET_BOOLEAN));
    assert(!janet_unwrap_boolean(janet_table_get(&janet_vm.threaded_abstracts,
                                                 janet_wrap_abstract(a))));

    assert(0 == ((uintptr_t) a % sizeof(long long)));

    janet_abstract_end_threaded(a);
    assert(drop(a) == 0);
}

/* `janet_abstract_end_threaded` sets a tag `begin` has already set, so the only
 * observable requirement is that it changes nothing and returns its argument.
 * An implementation that stored `JANET_MEMORY_ABSTRACT` instead would put a
 * malloced block on the collector's abstract path, which is a double free. */
static void test_end_threaded_changes_nothing(void) {
    void *a = janet_abstract_begin_threaded(&at_threaded_bare, 8);
    JanetAbstractHead *head = janet_abstract_head(a);
    int32_t flags_before = head->gc.flags;

    void *b = janet_abstract_end_threaded(a);
    assert(b == a);
    assert(head->gc.flags == flags_before);
    assert(janet_gc_type(head) == JANET_MEMORY_THREADED_ABSTRACT);
    assert(head->gc.data.refcount == 1);

    assert(drop(a) == 0);
}

static void test_abstract_threaded_is_begin_then_end(void) {
    settle();
    int32_t before_tracked = janet_vm.threaded_abstracts.count;
    size_t before_count = janet_vm.block_count;

    void *a = janet_abstract_threaded(&at_threaded_bare, 16);
    JanetAbstractHead *head = janet_abstract_head(a);

    assert(janet_gc_type(head) == JANET_MEMORY_THREADED_ABSTRACT);
    assert(head->size == 16);
    assert(head->gc.data.refcount == 1);
    assert(janet_vm.block_count == before_count);
    assert(janet_vm.threaded_abstracts.count == before_tracked + 1);
    assert(tracked(a));

    assert(drop(a) == 0);
}

/* ---------------------------------------------------------------- refcount */

/* Both primitives return the value *after* their own change, not before, and
 * both write it through to the header. */
static void test_incref_and_decref_return_the_new_count(void) {
    void *a = janet_abstract_threaded(&at_threaded_bare, 8);
    JanetAbstractHead *head = janet_abstract_head(a);

    assert(janet_abstract_incref(a) == 2);
    assert(head->gc.data.refcount == 2);
    assert(janet_abstract_incref(a) == 3);
    assert(head->gc.data.refcount == 3);
    assert(janet_abstract_decref(a) == 2);
    assert(head->gc.data.refcount == 2);
    assert(janet_abstract_decref(a) == 1);
    assert(head->gc.data.refcount == 1);

    assert(drop(a) == 0);
}

/* `janet_abstract_decref` does not act on a zero. It is the primitive the
 * caller uses when it intends to decide for itself, and the block survives it
 * -- which is readable, because nothing has freed the header. */
static void test_decref_to_zero_does_not_free(void) {
    threaded_gc_calls = 0;
    void *a = janet_abstract_threaded(&at_threaded, 8);
    JanetAbstractHead *head = janet_abstract_head(a);
    janet_table_remove(&janet_vm.threaded_abstracts, janet_wrap_abstract(a));

    assert(janet_abstract_decref(a) == 0);
    assert(head->gc.data.refcount == 0);
    assert(threaded_gc_calls == 0);
    assert(head->type == &at_threaded);

    /* Drop it properly. The count is zero, so this takes it to -1 and does not
     * free either -- the free is on the transition, and the caller that used
     * the plain primitive owns the block from here. */
    assert(janet_abstract_decref_maybe_free(a) == -1);
    assert(threaded_gc_calls == 0);
    janet_free(head);
}

/* The last reference frees the block and runs the type's `gc` exactly once.
 * `gcperthread` is not called: that callback belongs to the collector's sweep,
 * which is where an interpreter drops *its* reference, and this path is the
 * value's actual death. */
static void test_decref_maybe_free_finalizes_once(void) {
    threaded_gc_calls = 0;
    threaded_gc_data = NULL;
    threaded_gc_len = 0;
    perthread_calls = 0;
    void *a = janet_abstract_threaded(&at_threaded, 24);
    memset(a, 0x7e, 24);

    assert(janet_abstract_incref(a) == 2);
    assert(janet_abstract_decref_maybe_free(a) == 1);
    assert(threaded_gc_calls == 0);

    assert(drop(a) == 0);
    assert(threaded_gc_calls == 1);
    assert(perthread_calls == 0);

    /* The finalizer sees the payload and its recorded length, not the header
     * and not a zero. Both are read out of the header at the moment of the
     * call, which is the last moment either is readable. */
    assert(threaded_gc_data == a);
    assert(threaded_gc_len == 24);
}

/* A type with no `gc` callback is freed without one being looked up. */
static void test_decref_maybe_free_without_a_finalizer(void) {
    void *a = janet_abstract_threaded(&at_threaded_bare, 8);
    assert(drop(a) == 0);
}

/* The refcount shares a union with the heap-list link every collectable block
 * uses, and a threaded abstract is on no list, so the two never contend. This
 * pins the layout the port depends on: writing the refcount must not put a
 * plausible pointer in `next`, and the sweep must not find the block by
 * walking. */
static void test_refcount_and_list_link_share_one_word(void) {
    void *a = janet_abstract_threaded(&at_threaded_bare, 8);
    JanetAbstractHead *head = janet_abstract_head(a);

    assert((void *) &head->gc.data.refcount == (void *) &head->gc.data.next);
    janet_abstract_incref(a);
    assert(!on_list(janet_vm.blocks, head));
    assert(!on_list(janet_vm.weak_blocks, head));

    assert(janet_abstract_decref_maybe_free(a) == 1);
    assert(drop(a) == 0);
}

/* The visit record is keyed by the abstract, so two of them are two entries,
 * and the collector can tell them apart. Hashing the key runs the type's `hash`
 * callback when it has one; this type has none, so the pointer hash is what
 * distinguishes them. */
static void test_two_threaded_abstracts_are_two_entries(void) {
    settle();
    int32_t before = janet_vm.threaded_abstracts.count;
    void *a = janet_abstract_threaded(&at_threaded_bare, 8);
    void *b = janet_abstract_threaded(&at_threaded_bare, 8);

    assert(a != b);
    assert(janet_vm.threaded_abstracts.count == before + 2);
    assert(tracked(a));
    assert(tracked(b));

    assert(drop(a) == 0);
    assert(drop(b) == 0);
}

#endif /* JANET_EV */

/* ---------------------------------------------------------------- teardown */

/* Construction has to survive a runtime that is torn down and rebuilt: the
 * charge against `next_collection` and the heap list are both per-VM state. */
static void test_repeated_cycles(void) {
    for (int i = 0; i < 3; i++) {
        void *a = janet_abstract(&at_counted, 16);
        Janet v = janet_wrap_abstract(a);
        janet_gcroot(v);
        JanetTable *t = janet_table(4);
        janet_table_put(t, janet_ckeywordv("abstract"), v);
        janet_collect();
#ifdef JANET_EV
        void *th = janet_abstract_threaded(&at_threaded_bare, 16);
        assert(drop(th) == 0);
#endif
        janet_gcunroot(v);
        janet_deinit();
        janet_init();
    }
}

int main(void) {
    janet_init();

    test_head_offset();

    test_begin_publishes_an_untyped_block();
    test_end_types_the_block();
    test_end_preserves_the_other_flag_bits();
    test_abstract_is_begin_then_end();
    test_zero_length_abstract();
    test_payload_survives_end();

    test_collection_between_begin_and_end();
    test_the_window_does_not_stop_the_traversal();
    test_a_finished_abstract_is_traversed_and_finalized();

#ifdef JANET_EV
    test_begin_threaded_registers_without_the_heap();
    test_end_threaded_changes_nothing();
    test_abstract_threaded_is_begin_then_end();
    test_incref_and_decref_return_the_new_count();
    test_decref_to_zero_does_not_free();
    test_decref_maybe_free_finalizes_once();
    test_decref_maybe_free_without_a_finalizer();
    test_refcount_and_list_link_share_one_word();
    test_two_threaded_abstracts_are_two_entries();
#endif

    test_repeated_cycles();

    janet_deinit();
    printf("abstract core contract ok\n");
    return 0;
}
