/* Behavioral contract for the collector's memory: block allocation and the two
 * heap lists, the root set, the GC suspend counter, and the scratch allocator.
 * Run against whichever implementation the build selected (`-Dgc-alloc=c` or
 * the Zig default).
 *
 * Like the VM state contract, this one includes the internal headers. It has
 * to: every operation under test is a mutation of `janet_vm`'s garbage
 * collection fields, and the fields are the observable result. There is no
 * public accessor for `block_count` or `scratch_len`, and inventing one would
 * test the accessor.
 *
 * Two things are deliberately *not* exercised. Nothing here lets a synthetic
 * block reach `janet_sweep`: `test_gcalloc_*` unlinks what it allocated and
 * restores the counters, so the contract stays independent of the two
 * increments that still own marking and sweeping. And the two fatal paths --
 * `janet_srealloc` and `janet_sfree` on a pointer this allocator never handed
 * out -- abort the process, so they are described here rather than run.
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

static JanetScratch *header_of(void *mem) {
    return ((JanetScratch *) mem) - 1;
}

static int scratch_index_of(void *mem) {
    JanetScratch *s = header_of(mem);
    for (size_t i = 0; i < janet_vm.scratch_len; i++) {
        if (janet_vm.scratch_mem[i] == s) return (int) i;
    }
    return -1;
}

/* --------------------------------------------------------------- gcpressure */

/* The only thing janet_gcpressure does is move the threshold. It must not
 * collect, and it must not touch the block count -- the bytes it is told about
 * were allocated outside the collector's accounting. */
static void test_gcpressure(void) {
    size_t before = janet_vm.next_collection;
    size_t blocks = janet_vm.block_count;

    janet_gcpressure(0);
    assert(janet_vm.next_collection == before);

    janet_gcpressure(4096);
    assert(janet_vm.next_collection == before + 4096);
    assert(janet_vm.block_count == blocks);

    janet_vm.next_collection = before;
}

/* ------------------------------------------------------------------ gcalloc */

/* Undo one allocation, restoring every field it moved. Only valid for the
 * block at the head of its list, which is where janet_gcalloc just put it. */
static void unlink_head(int weak, size_t size) {
    JanetGCObject *head = weak ? janet_vm.weak_blocks : janet_vm.blocks;
    if (weak) {
        janet_vm.weak_blocks = head->data.next;
    } else {
        janet_vm.blocks = head->data.next;
    }
    janet_vm.block_count--;
    janet_vm.next_collection -= size;
    janet_free(head);
}

/* A new block goes on the front of the normal heap, carries its type in the
 * low byte of `flags` and nothing else, and is counted. It is emphatically not
 * marked: the caller has not filled it in yet, and a collection that treated it
 * as reachable would trace uninitialised memory. */
static void test_gcalloc_normal_heap(void) {
    size_t size = 128;
    void *previous = janet_vm.blocks;
    size_t count = janet_vm.block_count;
    size_t next = janet_vm.next_collection;
    void *weak = janet_vm.weak_blocks;

    JanetGCObject *mem = janet_gcalloc(JANET_MEMORY_ARRAY, size);
    assert(mem != NULL);
    assert(janet_vm.blocks == mem);
    assert(mem->data.next == previous);
    assert(janet_gc_type(mem) == JANET_MEMORY_ARRAY);
    assert(mem->flags == JANET_MEMORY_ARRAY);
    assert(!janet_gc_reachable(mem));
    assert(janet_vm.block_count == count + 1);
    assert(janet_vm.next_collection == next + size);
    assert(janet_vm.weak_blocks == weak);

    unlink_head(0, size);
    assert(janet_vm.blocks == previous);
    assert(janet_vm.block_count == count);
    assert(janet_vm.next_collection == next);
}

/* The four weak types are the ones at or above JANET_MEMORY_TABLE_WEAKK, and
 * the boundary is exactly that: the split is a numeric comparison against the
 * first weak constant, not a table of types. */
static void test_gcalloc_weak_heap(void) {
    enum JanetMemoryType weak_types[] = {
        JANET_MEMORY_TABLE_WEAKK,
        JANET_MEMORY_TABLE_WEAKV,
        JANET_MEMORY_TABLE_WEAKKV,
        JANET_MEMORY_ARRAY_WEAK
    };

    for (size_t i = 0; i < sizeof(weak_types) / sizeof(weak_types[0]); i++) {
        size_t size = 96;
        void *strong = janet_vm.blocks;
        void *previous = janet_vm.weak_blocks;
        size_t count = janet_vm.block_count;

        JanetGCObject *mem = janet_gcalloc(weak_types[i], size);
        assert(janet_vm.weak_blocks == mem);
        assert(mem->data.next == previous);
        assert(janet_gc_type(mem) == (int) weak_types[i]);
        assert(janet_vm.blocks == strong);
        assert(janet_vm.block_count == count + 1);

        unlink_head(1, size);
        assert(janet_vm.weak_blocks == previous);
        assert(janet_vm.block_count == count);
    }
}

/* Every type below the boundary goes on the normal heap. Worth stating for
 * JANET_MEMORY_NONE in particular, which is zero and therefore the value a
 * caller reaches by mistake. */
static void test_gcalloc_strong_types(void) {
    enum JanetMemoryType strong_types[] = {
        JANET_MEMORY_NONE,
        JANET_MEMORY_STRING,
        JANET_MEMORY_TABLE,
        JANET_MEMORY_FUNCDEF,
        JANET_MEMORY_THREADED_ABSTRACT
    };

    for (size_t i = 0; i < sizeof(strong_types) / sizeof(strong_types[0]); i++) {
        void *weak = janet_vm.weak_blocks;
        JanetGCObject *mem = janet_gcalloc(strong_types[i], 64);
        assert(janet_vm.blocks == mem);
        assert(janet_vm.weak_blocks == weak);
        assert(janet_gc_type(mem) == (int) strong_types[i]);
        unlink_head(0, 64);
    }
}

/* Successive allocations chain: the list is singly linked through the header's
 * `next`, newest first. */
static void test_gcalloc_chains(void) {
    void *previous = janet_vm.blocks;
    JanetGCObject *first = janet_gcalloc(JANET_MEMORY_NONE, 32);
    JanetGCObject *second = janet_gcalloc(JANET_MEMORY_NONE, 32);
    JanetGCObject *third = janet_gcalloc(JANET_MEMORY_NONE, 32);

    assert(janet_vm.blocks == third);
    assert(third->data.next == second);
    assert(second->data.next == first);
    assert(first->data.next == previous);

    unlink_head(0, 32);
    unlink_head(0, 32);
    unlink_head(0, 32);
    assert(janet_vm.blocks == previous);
}

/* --------------------------------------------------------------- root set */

/* Rooting appends. The root set is a multiset: n roots need n unroots. */
static void test_root_counting(void) {
    size_t base = janet_vm.root_count;
    JanetArray *a = janet_array(0);
    Janet v = janet_wrap_array(a);

    janet_gcroot(v);
    assert(janet_vm.root_count == base + 1);
    assert(janet_unwrap_array(janet_vm.roots[base]) == a);

    janet_gcroot(v);
    assert(janet_vm.root_count == base + 2);
    assert(janet_unwrap_array(janet_vm.roots[base + 1]) == a);

    assert(janet_gcunroot(v) == 1);
    assert(janet_vm.root_count == base + 1);
    assert(janet_gcunroot(v) == 1);
    assert(janet_vm.root_count == base);
    assert(janet_gcunroot(v) == 0);
    assert(janet_vm.root_count == base);
}

/* Roots are matched by pointer identity, not by value equality. Two arrays
 * with the same contents are different roots. */
static void test_root_identity_by_pointer(void) {
    size_t base = janet_vm.root_count;
    Janet a = janet_wrap_array(janet_array(0));
    Janet b = janet_wrap_array(janet_array(0));

    janet_gcroot(a);
    assert(janet_gcunroot(b) == 0);
    assert(janet_vm.root_count == base + 1);
    assert(janet_gcunroot(a) == 1);
    assert(janet_vm.root_count == base);
}

/* The three types the collector never traces compare equal to any value of
 * their own type. Rooting one number and unrooting a different one succeeds,
 * which is harmless -- the slot held nothing worth keeping either way -- but it
 * is observable, so it is pinned here. */
static void test_root_identity_of_immediates(void) {
    size_t base = janet_vm.root_count;

    janet_gcroot(janet_wrap_number(1.0));
    assert(janet_gcunroot(janet_wrap_number(9999.0)) == 1);
    assert(janet_vm.root_count == base);

    janet_gcroot(janet_wrap_true());
    assert(janet_gcunroot(janet_wrap_false()) == 1);
    assert(janet_vm.root_count == base);

    janet_gcroot(janet_wrap_nil());
    assert(janet_gcunroot(janet_wrap_nil()) == 1);
    assert(janet_vm.root_count == base);

    /* Different types never match, immediate or not. */
    janet_gcroot(janet_wrap_number(1.0));
    assert(janet_gcunroot(janet_wrap_true()) == 0);
    assert(janet_gcunroot(janet_wrap_nil()) == 0);
    assert(janet_gcunroot(janet_wrap_number(0.0)) == 1);
    assert(janet_vm.root_count == base);
}

/* Unrooting fills the vacated slot from the top of the set, so the order of
 * the remaining roots is not the order they were added in. */
static void test_root_removal_swaps_from_top(void) {
    size_t base = janet_vm.root_count;
    JanetArray *a = janet_array(0);
    JanetArray *b = janet_array(0);
    JanetArray *cc = janet_array(0);

    janet_gcroot(janet_wrap_array(a));
    janet_gcroot(janet_wrap_array(b));
    janet_gcroot(janet_wrap_array(cc));

    assert(janet_gcunroot(janet_wrap_array(a)) == 1);
    assert(janet_vm.root_count == base + 2);
    assert(janet_unwrap_array(janet_vm.roots[base]) == cc);
    assert(janet_unwrap_array(janet_vm.roots[base + 1]) == b);

    assert(janet_gcunroot(janet_wrap_array(b)) == 1);
    assert(janet_gcunroot(janet_wrap_array(cc)) == 1);
    assert(janet_vm.root_count == base);
}

/* janet_gcunrootall does not remove every rooting, despite what its comment in
 * gc.c says. It fills the vacated slot from the top and then advances, so the
 * value it just moved down is never examined: n rootings become floor(n / 2).
 * FOUND.md carries the defect; this pins the behaviour both implementations
 * have to produce. */
static void test_root_unrootall_halves(void) {
    size_t counts[] = {1, 2, 3, 4, 5, 8};

    for (size_t k = 0; k < sizeof(counts) / sizeof(counts[0]); k++) {
        size_t n = counts[k];
        size_t base = janet_vm.root_count;
        Janet v = janet_wrap_array(janet_array(0));

        for (size_t i = 0; i < n; i++) janet_gcroot(v);
        assert(janet_vm.root_count == base + n);

        assert(janet_gcunrootall(v) == 1);
        assert(janet_vm.root_count == base + n / 2);

        /* What survives really is still rooted, and can be removed one at a
         * time. */
        for (size_t i = 0; i < n / 2; i++) assert(janet_gcunroot(v) == 1);
        assert(janet_vm.root_count == base);
        assert(janet_gcunrootall(v) == 0);
    }
}

/* An absent value reports absence and changes nothing. */
static void test_root_unrootall_absent(void) {
    size_t base = janet_vm.root_count;
    Janet a = janet_wrap_array(janet_array(0));
    Janet b = janet_wrap_array(janet_array(0));

    janet_gcroot(a);
    assert(janet_gcunrootall(b) == 0);
    assert(janet_vm.root_count == base + 1);
    assert(janet_gcunroot(a) == 1);
    assert(janet_vm.root_count == base);
}

/* Growth is by doubling the required count, and the roots survive it. */
static void test_root_capacity_growth(void) {
    size_t base = janet_vm.root_count;
    Janet v = janet_wrap_array(janet_array(0));
    size_t added = 0;

    while (janet_vm.root_count < janet_vm.root_capacity) {
        janet_gcroot(v);
        added++;
    }
    size_t at_capacity = janet_vm.root_capacity;

    janet_gcroot(v);
    added++;
    assert(janet_vm.root_capacity == 2 * (at_capacity + 1));
    assert(janet_vm.root_count == base + added);
    for (size_t i = 0; i < added; i++) {
        assert(janet_unwrap_array(janet_vm.roots[base + i]) == janet_unwrap_array(v));
    }

    for (size_t i = 0; i < added; i++) assert(janet_gcunroot(v) == 1);
    assert(janet_vm.root_count == base);
}

/* ------------------------------------------------------------- suspension */

/* The handle is the depth to restore, not a token to match. Unlocking with an
 * outer handle discards every lock taken since, which is what makes it safe for
 * a cleanup path to hold one handle across nested regions. */
static void test_gclock_nesting(void) {
    int base = janet_vm.gc_suspend;

    int h1 = janet_gclock();
    assert(h1 == base);
    assert(janet_vm.gc_suspend == base + 1);

    int h2 = janet_gclock();
    assert(h2 == base + 1);
    assert(janet_vm.gc_suspend == base + 2);

    janet_gcunlock(h2);
    assert(janet_vm.gc_suspend == base + 1);
    janet_gcunlock(h1);
    assert(janet_vm.gc_suspend == base);

    h1 = janet_gclock();
    (void) janet_gclock();
    (void) janet_gclock();
    assert(janet_vm.gc_suspend == base + 3);
    janet_gcunlock(h1);
    assert(janet_vm.gc_suspend == base);
}

/* A suspended collector does not collect. This is the one property the counter
 * exists for, and it is checked through janet_collect rather than by reading
 * the field back. */
static void test_gclock_suspends_collection(void) {
    int handle = janet_gclock();
    janet_vm.next_collection = 12345;
    janet_collect();
    assert(janet_vm.next_collection == 12345);
    janet_gcunlock(handle);
    janet_collect();
    assert(janet_vm.next_collection == 0);
}

/* --------------------------------------------------------------- scratch */

static int finalizer_calls;
static void *finalizer_args[8];

static void record_finalizer(void *mem) {
    if (finalizer_calls < 8) finalizer_args[finalizer_calls] = mem;
    finalizer_calls++;
}

/* A scratch block is registered in the table, and the pointer handed back sits
 * exactly one header above it. That relationship is the whole allocator:
 * janet_srealloc, janet_sfree and janet_sfinalizer all recover the header by
 * subtracting from the pointer the caller holds. */
static void test_smalloc_registers(void) {
    size_t base = janet_vm.scratch_len;

    char *p = janet_smalloc(40);
    assert(p != NULL);
    assert(janet_vm.scratch_len == base + 1);
    assert(janet_vm.scratch_mem[base] == header_of(p));
    assert(header_of(p)->finalize == NULL);
    assert(((uintptr_t) p) % sizeof(long long) == 0);

    memset(p, 'x', 40);
    janet_sfree(p);
    assert(janet_vm.scratch_len == base);
}

/* janet_scalloc zeroes, and rejects a product that would wrap. The zero-length
 * cases still produce a registered block. */
static void test_scalloc(void) {
    size_t base = janet_vm.scratch_len;

    unsigned char *p = janet_scalloc(9, 7);
    assert(janet_vm.scratch_len == base + 1);
    for (size_t i = 0; i < 63; i++) assert(p[i] == 0);

    void *empty = janet_scalloc(0, 16);
    assert(empty != NULL);
    assert(janet_vm.scratch_len == base + 2);

    void *empty2 = janet_scalloc(16, 0);
    assert(empty2 != NULL);
    assert(janet_vm.scratch_len == base + 3);

    janet_sfree(empty2);
    janet_sfree(empty);
    janet_sfree(p);
    assert(janet_vm.scratch_len == base);
}

/* janet_srealloc keeps the block in the same table slot, preserves the bytes
 * that fit, and carries the finalizer across -- the header moves with the
 * allocation. A null pointer means allocate. */
static void test_srealloc(void) {
    size_t base = janet_vm.scratch_len;

    void *fresh = janet_srealloc(NULL, 24);
    assert(fresh != NULL);
    assert(janet_vm.scratch_len == base + 1);
    assert(scratch_index_of(fresh) == (int) base);
    janet_sfree(fresh);

    char *p = janet_smalloc(16);
    memcpy(p, "0123456789abcde", 16);
    janet_sfinalizer(p, record_finalizer);
    int slot = scratch_index_of(p);
    assert(slot >= 0);

    char *grown = janet_srealloc(p, 4096);
    assert(janet_vm.scratch_len == base + 1);
    assert(scratch_index_of(grown) == slot);
    assert(0 == memcmp(grown, "0123456789abcde", 16));
    assert(header_of(grown)->finalize == record_finalizer);

    char *shrunk = janet_srealloc(grown, 8);
    assert(janet_vm.scratch_len == base + 1);
    assert(scratch_index_of(shrunk) == slot);
    assert(0 == memcmp(shrunk, "01234567", 8));

    finalizer_calls = 0;
    janet_sfree(shrunk);
    assert(finalizer_calls == 1);
    assert(finalizer_args[0] == shrunk);
    assert(janet_vm.scratch_len == base);
}

/* Freeing fills the vacated table slot from the top, the same way the root set
 * does, and a null pointer is a no-op. */
static void test_sfree(void) {
    size_t base = janet_vm.scratch_len;

    void *a = janet_smalloc(8);
    void *b = janet_smalloc(8);
    void *cc = janet_smalloc(8);
    assert(janet_vm.scratch_len == base + 3);

    janet_sfree(NULL);
    assert(janet_vm.scratch_len == base + 3);

    janet_sfree(a);
    assert(janet_vm.scratch_len == base + 2);
    assert(scratch_index_of(cc) == (int) base);
    assert(scratch_index_of(b) == (int) base + 1);

    janet_sfree(b);
    janet_sfree(cc);
    assert(janet_vm.scratch_len == base);
}

/* A finalizer runs once, with the caller's pointer rather than the header. */
static void test_sfinalizer(void) {
    size_t base = janet_vm.scratch_len;

    void *p = janet_smalloc(8);
    finalizer_calls = 0;
    janet_sfree(p);
    assert(finalizer_calls == 0);

    p = janet_smalloc(8);
    janet_sfinalizer(p, record_finalizer);
    finalizer_calls = 0;
    janet_sfree(p);
    assert(finalizer_calls == 1);
    assert(finalizer_args[0] == p);
    assert(janet_vm.scratch_len == base);
}

/* The table grows to twice what is needed plus two, and everything already in
 * it survives the move. */
static void test_scratch_capacity_growth(void) {
    void *held[64];
    size_t base = janet_vm.scratch_len;
    size_t held_count = 0;

    while (janet_vm.scratch_len < janet_vm.scratch_cap) {
        held[held_count] = janet_smalloc(8);
        memset(held[held_count], (int) held_count, 8);
        held_count++;
        assert(held_count < 64);
    }
    size_t at_capacity = janet_vm.scratch_cap;

    held[held_count] = janet_smalloc(8);
    memset(held[held_count], (int) held_count, 8);
    held_count++;
    assert(janet_vm.scratch_cap == 2 * at_capacity + 2);
    assert(janet_vm.scratch_len == base + held_count);

    for (size_t i = 0; i < held_count; i++) {
        unsigned char *bytes = held[i];
        assert(scratch_index_of(held[i]) >= 0);
        for (size_t j = 0; j < 8; j++) assert(bytes[j] == (unsigned char) i);
    }
    for (size_t i = 0; i < held_count; i++) janet_sfree(held[i]);
    assert(janet_vm.scratch_len == base);
}

/* Releasing everything runs each finalizer and empties the table. This is what
 * janet_collect does at the end of a collection and janet_clear_memory does at
 * shutdown, which is why the scratch API needs no explicit free to be correct. */
static void test_free_all_scratch(void) {
    janet_collect();
    assert(janet_vm.scratch_len == 0);

    void *a = janet_smalloc(8);
    void *b = janet_smalloc(8);
    void *cc = janet_smalloc(8);
    janet_sfinalizer(a, record_finalizer);
    janet_sfinalizer(cc, record_finalizer);

    finalizer_calls = 0;
    janet_free_all_scratch();
    assert(janet_vm.scratch_len == 0);
    assert(finalizer_calls == 2);
    assert(finalizer_args[0] == a);
    assert(finalizer_args[1] == cc);
    (void) b;
}

/* And a collection does the same, on its way out. */
static void test_collect_frees_scratch(void) {
    void *p = janet_smalloc(8);
    janet_sfinalizer(p, record_finalizer);
    finalizer_calls = 0;
    janet_collect();
    assert(finalizer_calls == 1);
    assert(finalizer_args[0] == p);
    assert(janet_vm.scratch_len == 0);
}

int main(void) {
    janet_init();

    test_gcpressure();
    test_gcalloc_normal_heap();
    test_gcalloc_weak_heap();
    test_gcalloc_strong_types();
    test_gcalloc_chains();

    test_root_counting();
    test_root_identity_by_pointer();
    test_root_identity_of_immediates();
    test_root_removal_swaps_from_top();
    test_root_unrootall_halves();
    test_root_unrootall_absent();
    test_root_capacity_growth();

    test_gclock_nesting();
    test_gclock_suspends_collection();

    test_smalloc_registers();
    test_scalloc();
    test_srealloc();
    test_sfree();
    test_sfinalizer();
    test_scratch_capacity_growth();
    test_free_all_scratch();
    test_collect_frees_scratch();

    janet_deinit();
    printf("gc alloc contract ok\n");
    return 0;
}
