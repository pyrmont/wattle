/* Behavioral contract for the immutable head-allocated sequences: strings,
 * symbols and the symbol cache, and tuples. Run against whichever
 * implementation the build selected (`-Dstring-symbol=c` or the Zig default).
 *
 * All three of these types are a header and a payload in one `janet_gcalloc`,
 * and the value Janet passes around is the address of the payload. So the
 * first thing this file does is pin the arithmetic that recovers the header,
 * from C, where `offsetof` is available -- the Zig port cannot use `offsetof`
 * at all, because translate-c drops a flexible array member, and it uses
 * `sizeof` on the strength of the equality asserted below.
 *
 * The observable surface splits three ways.
 *
 * The fields are directly checkable: a string's length and hash, a tuple's
 * length, hash and source-map position, and the memory type in the GC header
 * that decides which of `janet_deinit_block`'s cases will eventually free it.
 *
 * The symbol cache is checkable through `janet_vm.cache_count` and
 * `janet_vm.cache_deleted`, and through pointer identity: interning means two
 * calls with the same name return the same address, and that is a stronger
 * statement than equality. It is also the property that makes symbol comparison
 * a pointer comparison everywhere else in the runtime, so it is the one worth
 * asserting hardest.
 *
 * Hashing is checkable only for consistency, not for value. `janet_string_calchash`
 * is a different subsystem (`-Dutilities`) and changes under `-Dprf`, so
 * nothing here asserts a particular hash. What it does assert is that the hash
 * a constructor stores is the one that function returns, and that equal
 * contents hash equally -- which is what the dictionaries in Part 6c will rely
 * on.
 *
 * Two things are deliberately not covered. `janet_string_begin` and
 * `janet_tuple_begin` leave the hash uninitialised, and there is no way to
 * assert an indeterminate value; the tests read it only after the matching
 * `end`. And `janet_symcache_findmem` ends the process when the table is full,
 * which `FOUND.md` records as reachable only at a capacity of two -- a state
 * that needs `cache_count` to reach zero and so cannot be arranged while a core
 * environment is loaded.
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
#include "util.h"
#include "symcache.h"

/* ------------------------------------------------------------------ helpers */

static int memtype(void *p) {
    return janet_gc_header(p)->flags & JANET_MEM_TYPEBITS;
}

static int on_list(void *list, void *block) {
    JanetGCObject *current = (JanetGCObject *) list;
    while (NULL != current) {
        if ((void *) current == block) return 1;
        current = current->data.next;
    }
    return 0;
}

/* Is `sym` in the cache, and at what address? Walks the table rather than
 * calling the finder, so that a test can distinguish "interned" from "would be
 * found by the same lookup the implementation uses". */
static int in_cache(const uint8_t *sym) {
    for (uint32_t i = 0; i < janet_vm.cache_capacity; i++) {
        if (janet_vm.cache[i] == sym) return 1;
    }
    return 0;
}

/* --------------------------------------------------------------- the heads */

/* The port recovers a head by subtracting `sizeof`, because translate-c drops
 * the flexible array member and `offsetof` is not available to it. That is only
 * correct while the two agree, and this is where they are made to. */
static void test_head_layout(void) {
    assert(sizeof(JanetStringHead) == offsetof(JanetStringHead, data));
    assert(sizeof(JanetTupleHead) == offsetof(JanetTupleHead, data));

    /* And the arithmetic itself, in both directions. */
    const uint8_t *s = janet_cstring("abc");
    assert((const char *) janet_string_head(s) + sizeof(JanetStringHead) == (const char *) s);

    const Janet *t = janet_tuple_n(NULL, 0);
    assert((const char *) janet_tuple_head(t) + sizeof(JanetTupleHead) == (const char *) t);
}

/* ------------------------------------------------------------------ string */

/* A string built in two steps: the length is set by `begin`, the terminator is
 * written by `begin`, and the hash is written by `end` and nowhere else. */
/* Fill the allocator's free list with blocks of `size` whose bytes are all
 * 0xFF, and report whether they come back that way.
 *
 * Every assertion that a constructor wrote a terminator is vacuous on a block
 * that arrived zeroed, and whether one does is a property of the C library
 * rather than of Janet: macOS zeroes small allocations and leaves large ones
 * alone, glibc leaves both. So the terminator test probes first and asserts
 * only where the answer makes the assertion mean something. */
static int dirty_free_list(size_t size) {
    void *junk[8];
    for (int i = 0; i < 8; i++) {
        junk[i] = janet_malloc(size);
        assert(NULL != junk[i]);
        memset(junk[i], 0xFF, size);
    }
    for (int i = 0; i < 8; i++) janet_free(junk[i]);

    unsigned char *check = janet_malloc(size);
    assert(NULL != check);
    int dirty = (check[size - 1] != 0);
    memset(check, 0xFF, size);
    janet_free(check);
    return dirty;
}

/* Both constructors write a zero one byte past the length, so that a Janet
 * string can be handed to a C function that expects one. Asserted on a block
 * large enough that this allocator does not zero it -- see above. */
static void test_constructors_write_the_terminator(void) {
    const int32_t n = 8192;
    if (!dirty_free_list(sizeof(JanetStringHead) + (size_t) n + 1)) return;

    uint8_t *begun = janet_string_begin(n);
    assert(begun[n] == 0);

    uint8_t *source = janet_malloc((size_t) n);
    assert(NULL != source);
    memset(source, 'x', (size_t) n);
    (void) dirty_free_list(sizeof(JanetStringHead) + (size_t) n + 1);
    const uint8_t *copied = janet_string(source, n);
    assert(copied[n] == 0);
    assert(0 == memcmp(copied, source, (size_t) n));
    janet_free(source);
}

static void test_string_begin_and_end(void) {
    uint8_t *s = janet_string_begin(5);
    assert(janet_string_length(s) == 5);
    assert(s[5] == 0);
    assert(memtype(janet_string_head(s)) == JANET_MEMORY_STRING);
    assert(on_list(janet_vm.blocks, janet_string_head(s)));

    memcpy(s, "hello", 5);
    const uint8_t *done = janet_string_end(s);
    assert(done == s);
    assert(janet_string_length(done) == 5);
    assert(janet_string_hash(done) == janet_string_calchash((const uint8_t *) "hello", 5));

    /* A zero-length string is legal, terminated, and has the empty hash. */
    uint8_t *e = janet_string_begin(0);
    assert(janet_string_length(e) == 0);
    assert(e[0] == 0);
    assert(janet_string_hash(janet_string_end(e)) == janet_string_calchash((const uint8_t *) "", 0));
}

/* The one-step constructor copies and hashes immediately. */
static void test_string_copies_and_hashes(void) {
    const uint8_t *s = janet_string((const uint8_t *) "world", 5);
    assert(janet_string_length(s) == 5);
    assert(0 == memcmp(s, "world", 5));
    assert(s[5] == 0);
    assert(janet_string_hash(s) == janet_string_calchash((const uint8_t *) "world", 5));

    /* The source is copied, so a caller's buffer may change afterwards. */
    uint8_t src[3] = {'a', 'b', 'c'};
    const uint8_t *copy = janet_string(src, 3);
    src[0] = 'z';
    assert(0 == memcmp(copy, "abc", 3));

    /* An interior zero is content, not a terminator: the length comes from the
     * head and the bytes past the zero are part of the string. */
    const uint8_t *nul = janet_string((const uint8_t *) "a\0b", 3);
    assert(janet_string_length(nul) == 3);
    assert(0 == memcmp(nul, "a\0b", 3));
    assert(nul[3] == 0);

    /* `janet_cstring` takes its length from the bytes instead. */
    const uint8_t *cs = janet_cstring("a\0b");
    assert(janet_string_length(cs) == 1);
    assert(cs[0] == 'a' && cs[1] == 0);
}

/* Ordering is three-valued and by prefix. The normalisation matters: `memcmp`
 * may return any value of the right sign, and callers compare against 1 and -1. */
static void test_string_compare_is_three_valued(void) {
    const uint8_t *a = janet_cstring("abc");
    const uint8_t *b = janet_cstring("abd");
    const uint8_t *pre = janet_cstring("ab");
    const uint8_t *same = janet_cstring("abc");

    assert(janet_string_compare(a, b) == -1);
    assert(janet_string_compare(b, a) == 1);
    assert(janet_string_compare(a, same) == 0);
    assert(janet_string_compare(a, a) == 0);

    /* A prefix is less than what extends it, whichever side it is on. */
    assert(janet_string_compare(pre, a) == -1);
    assert(janet_string_compare(a, pre) == 1);

    /* A large byte difference still normalises to exactly one. */
    const uint8_t low[1] = {0x01};
    const uint8_t high[1] = {0xFF};
    const uint8_t *l = janet_string(low, 1);
    const uint8_t *h = janet_string(high, 1);
    assert(janet_string_compare(l, h) == -1);
    assert(janet_string_compare(h, l) == 1);

    /* The empty string is least, and equal to itself. */
    const uint8_t *empty = janet_cstring("");
    assert(janet_string_compare(empty, a) == -1);
    assert(janet_string_compare(empty, empty) == 0);
}

/* Equality rejects on the hash or the length before it touches the bytes, and
 * short-circuits on identity. Both are what make the symbol cache cheap. */
static void test_string_equality(void) {
    const uint8_t *a = janet_cstring("abc");
    const uint8_t *b = janet_cstring("abc");
    const uint8_t *c = janet_cstring("abd");

    assert(janet_string_equal(a, b));
    assert(janet_string_equal(a, a));
    assert(!janet_string_equal(a, c));

    /* Same bytes, right hash and length: equal. */
    assert(janet_string_equalconst(a, (const uint8_t *) "abc", 3,
                                   janet_string_calchash((const uint8_t *) "abc", 3)));

    /* A wrong hash rejects even when the bytes are identical -- the hash is
     * trusted, not recomputed, which is the whole point of this entry point. */
    assert(!janet_string_equalconst(a, (const uint8_t *) "abc", 3,
                                    janet_string_calchash((const uint8_t *) "zzz", 3)));

    /* The length and byte checks are harder to reach honestly, because the hash
     * mixes the length in and so rejects almost every mismatched argument
     * before either runs. They are reachable through the public API, though,
     * which is what these two do: pass the hash `lhs` actually has, and vary
     * only the thing being tested. Without this, the length comparison and the
     * `memcmp` are both dead code that no test distinguishes. */
    assert(!janet_string_equalconst(a, (const uint8_t *) "abc", 2, janet_string_hash(a)));
    assert(!janet_string_equalconst(a, (const uint8_t *) "abd", 3, janet_string_hash(a)));

    /* And the same arguments with nothing varied still match, so the two above
     * are rejections rather than an entry point that rejects everything. */
    assert(janet_string_equalconst(a, (const uint8_t *) "abc", 3, janet_string_hash(a)));

    /* Interior zeros are compared, not stopped at. */
    const uint8_t *n1 = janet_string((const uint8_t *) "a\0b", 3);
    const uint8_t *n2 = janet_string((const uint8_t *) "a\0c", 3);
    assert(!janet_string_equal(n1, n2));
}

/* ------------------------------------------------------------------ symbol */

/* Interning is pointer identity, which is stronger than equality and is what
 * the rest of the runtime relies on. */
static void test_symbol_interns(void) {
    uint32_t before = janet_vm.cache_count;

    const uint8_t *s1 = janet_csymbol("interned-test-symbol");
    assert(janet_vm.cache_count == before + 1);
    assert(memtype(janet_string_head(s1)) == JANET_MEMORY_SYMBOL);
    assert(on_list(janet_vm.blocks, janet_string_head(s1)));
    assert(in_cache(s1));

    /* The same name returns the same address and allocates nothing. */
    const uint8_t *s2 = janet_csymbol("interned-test-symbol");
    assert(s2 == s1);
    assert(janet_vm.cache_count == before + 1);

    /* A different name is a different address. */
    const uint8_t *s3 = janet_csymbol("interned-test-symbol-2");
    assert(s3 != s1);
    assert(janet_vm.cache_count == before + 2);

    /* Interning is by length as well as by bytes, so an interior zero
     * distinguishes two symbols a C string could not tell apart. */
    const uint8_t *z1 = janet_symbol((const uint8_t *) "zz\0a", 4);
    const uint8_t *z2 = janet_symbol((const uint8_t *) "zz\0b", 4);
    assert(z1 != z2);
    assert(janet_symbol((const uint8_t *) "zz\0a", 4) == z1);

    /* A symbol and a string with the same bytes are different objects with
     * different memory types, and still compare equal as byte strings. */
    const uint8_t *str = janet_cstring("interned-test-symbol");
    assert(str != s1);
    assert(memtype(janet_string_head(str)) == JANET_MEMORY_STRING);
    assert(janet_string_equal(str, s1));
}

/* Removing a symbol leaves a tombstone: the count falls, the deleted count
 * rises, and the name is available again -- at a new address. */
static void test_symbol_deinit_leaves_a_tombstone(void) {
    uint32_t count = janet_vm.cache_count;
    uint32_t deleted = janet_vm.cache_deleted;

    const uint8_t *s = janet_csymbol("tombstone-test-symbol");
    assert(janet_vm.cache_count == count + 1);
    assert(in_cache(s));

    janet_symbol_deinit(s);
    assert(janet_vm.cache_count == count);
    assert(janet_vm.cache_deleted == deleted + 1);
    assert(!in_cache(s));

    /* The name interns again, to a different block. */
    const uint8_t *again = janet_csymbol("tombstone-test-symbol");
    assert(again != s);
    assert(janet_vm.cache_count == count + 1);
    assert(in_cache(again));

    /* Removing something that was never there changes nothing. */
    count = janet_vm.cache_count;
    deleted = janet_vm.cache_deleted;
    const uint8_t *loose = janet_string((const uint8_t *) "never-interned", 14);
    janet_symbol_deinit(loose);
    assert(janet_vm.cache_count == count);
    assert(janet_vm.cache_deleted == deleted);
}

/* Where in the table is `sym`, and where would a name ideally go? Together
 * these make the probe sequence observable, which is the only way to see what
 * a lookup does to the table on its way past a tombstone. */
static int32_t cache_index_of(const uint8_t *sym) {
    for (uint32_t i = 0; i < janet_vm.cache_capacity; i++) {
        if (janet_vm.cache[i] == sym) return (int32_t) i;
    }
    return -1;
}

static uint32_t ideal_index(const char *name) {
    int32_t len = (int32_t) strlen(name);
    int32_t hash = janet_string_calchash((const uint8_t *) name, len);
    return (uint32_t) hash & (janet_vm.cache_capacity - 1);
}

/* A successful lookup is not a pure read: if the key was found *after* a
 * tombstone, it is moved back into the tombstone's slot and its old slot
 * becomes one. That keeps probe sequences short as symbols come and go, and
 * without it a table that has churned degrades toward a full scan per lookup.
 *
 * It needs two names that collide, so this searches for a pair rather than
 * assuming one. Nothing here may cross the load factor, or a rehash would
 * relocate everything and hide what is being tested. */
static void test_lookup_reclaims_a_tombstone(void) {
    char first[32], second[32];
    int found = 0;
    for (int i = 0; i < 20000 && !found; i++) {
        snprintf(first, sizeof(first), "collide-a-%d", i);
        uint32_t target = ideal_index(first);
        for (int j = 0; j < 400; j++) {
            snprintf(second, sizeof(second), "collide-b-%d-%d", i, j);
            if (ideal_index(second) == target) {
                found = 1;
                break;
            }
        }
    }
    assert(found && "no colliding pair of names");

    uint32_t capacity = janet_vm.cache_capacity;
    const uint8_t *a = janet_csymbol(first);
    const uint8_t *b = janet_csymbol(second);
    janet_gcroot(janet_wrap_symbol(a));
    janet_gcroot(janet_wrap_symbol(b));
    assert(janet_vm.cache_capacity == capacity);

    int32_t pos_a = cache_index_of(a);
    int32_t pos_b = cache_index_of(b);
    assert(pos_a >= 0 && pos_b >= 0 && pos_a != pos_b);
    assert((uint32_t) pos_a == ideal_index(first));

    /* Delete the first, leaving a tombstone directly in the second's path. */
    janet_symbol_deinit(a);
    assert(cache_index_of(a) == -1);
    assert(janet_vm.cache[pos_a] != NULL);

    /* Looking the second one up moves it into that slot. Its address does not
     * change -- interning is still identity -- only its position does. */
    assert(janet_csymbol(second) == b);
    assert(cache_index_of(b) == pos_a);
    assert(janet_vm.cache[pos_b] != NULL);
    assert(janet_vm.cache[pos_b] != b);
    assert(janet_vm.cache_capacity == capacity);

    janet_gcunroot(janet_wrap_symbol(a));
    janet_gcunroot(janet_wrap_symbol(b));
}

/* Growing past the load factor rehashes: the capacity rises, every tombstone
 * is dropped, and every live symbol is still found at its original address. */
static void test_cache_resizes_and_keeps_identity(void) {
    char name[32];
    const uint8_t *kept[400];

    /* Keep them alive across the resize by rooting them. */
    for (int i = 0; i < 400; i++) {
        snprintf(name, sizeof(name), "resize-probe-%d", i);
        kept[i] = janet_csymbol(name);
        janet_gcroot(janet_wrap_symbol(kept[i]));
    }

    /* Delete half, which raises the tombstone count without lowering capacity. */
    for (int i = 0; i < 400; i += 2) janet_symbol_deinit(kept[i]);
    assert(janet_vm.cache_deleted >= 200);

    /* Force enough puts to cross the load factor and rehash. */
    uint32_t capacity_before = janet_vm.cache_capacity;
    for (int i = 0; i < 1200; i++) {
        snprintf(name, sizeof(name), "resize-filler-%d", i);
        const uint8_t *f = janet_csymbol(name);
        janet_gcroot(janet_wrap_symbol(f));
    }
    assert(janet_vm.cache_capacity > capacity_before);

    /* Every survivor is still interned, at the address it always had. */
    for (int i = 1; i < 400; i += 2) {
        snprintf(name, sizeof(name), "resize-probe-%d", i);
        assert(janet_csymbol(name) == kept[i]);
        assert(in_cache(kept[i]));
    }

    /* Every deleted one interns fresh rather than coming back. */
    for (int i = 0; i < 400; i += 2) {
        snprintf(name, sizeof(name), "resize-probe-%d", i);
        assert(janet_csymbol(name) != kept[i]);
    }

    for (int i = 0; i < 400; i++) janet_gcunroot(janet_wrap_symbol(kept[i]));
}

/* Tombstones count toward the load factor, and that is what keeps a table that
 * churns from degrading. A symbol created and immediately deleted leaves
 * `cache_count` where it was and `cache_deleted` one higher, so a long run of
 * them adds no entries at all and still has to force a rehash. If only live
 * entries were counted the tombstones would accumulate without bound until no
 * empty slot remained and the finder gave up. */
static void test_tombstones_force_a_rehash(void) {
    uint32_t high_water = 0;
    int rehashed = 0;

    for (int i = 0; i < 200000; i++) {
        char name[40];
        snprintf(name, sizeof(name), "churn-symbol-%d", i);
        const uint8_t *s = janet_csymbol(name);

        if (janet_vm.cache_deleted > high_water) high_water = janet_vm.cache_deleted;
        /* The invariant a live count alone would not maintain. */
        assert(janet_vm.cache_deleted < janet_vm.cache_capacity);

        if (janet_vm.cache_deleted == 0 && high_water > 8) {
            rehashed = 1;
            janet_symbol_deinit(s);
            break;
        }
        janet_symbol_deinit(s);
    }
    assert(rehashed && "tombstones never forced a rehash");
}

/* The leading underscore comes from `janet_symcache_init` and nothing else
 * ever writes it, so it is the one part of the counter's initial state that
 * survives to be observed. This test has to run before the one below, which
 * resets the counter itself and would make the same assertion vacuous. */
static void test_generated_names_come_from_the_initial_counter(void) {
    const uint8_t *g = janet_symbol_gen();
    janet_gcroot(janet_wrap_symbol(g));
    assert(g[0] == '_');
    assert(janet_string_length(g) == (int32_t) sizeof(janet_vm.gensym_counter) - 1);
    for (int32_t i = 1; i < janet_string_length(g); i++) {
        assert((g[i] >= '0' && g[i] <= '9') ||
               (g[i] >= 'a' && g[i] <= 'z') ||
               (g[i] >= 'A' && g[i] <= 'Z'));
    }
    janet_gcunroot(janet_wrap_symbol(g));
}

/* A generated symbol is interned like any other, and the counter advances only
 * when a name is already taken -- so the sequence is exactly the odometer. */
static void test_gensym_advances_the_odometer(void) {
    /* Start from the state `janet_symcache_init` leaves, so the sequence is
     * predictable however many gensyms ran before this. Collecting first drops
     * the ones earlier tests made, which would otherwise still be cached and
     * would make the counter skip past them. */
    janet_collect();
    memset(&janet_vm.gensym_counter, '0', sizeof(janet_vm.gensym_counter));
    janet_vm.gensym_counter[0] = '_';

    const int32_t len = (int32_t) sizeof(janet_vm.gensym_counter) - 1;
    const uint8_t *seen[40];
    for (int i = 0; i < 40; i++) {
        seen[i] = janet_symbol_gen();
        janet_gcroot(janet_wrap_symbol(seen[i]));
        assert(janet_string_length(seen[i]) == len);
        assert(seen[i][0] == '_');
        assert(memtype(janet_string_head(seen[i])) == JANET_MEMORY_SYMBOL);
        assert(in_cache(seen[i]));
    }

    /* All distinct, and each is the one the cache holds for its own name. */
    for (int i = 0; i < 40; i++) {
        for (int j = i + 1; j < 40; j++) assert(seen[i] != seen[j]);
        assert(janet_symbol(seen[i], len) == seen[i]);
    }

    /* The last character walks '0'..'9', then 'a'..'z', then 'A'..'Z' -- the
     * two carries at '9' and at 'z' are the whole of what `inc_gensym` does
     * beyond incrementing a byte. Only the final position moves over forty
     * names, so the rest stay where the reset above put them.
     *
     * The starting point is read from the first name rather than assumed to be
     * '0', because a name the cache already holds is skipped rather than
     * reused, and a symbol surviving from the boot process would shift the
     * whole run by one. */
    static const char alphabet[] = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
    const char *start = strchr(alphabet, (char) seen[0][len - 1]);
    assert(NULL != start);
    assert(start + 40 <= alphabet + sizeof(alphabet) - 1);
    for (int i = 0; i < 40; i++) {
        assert(seen[i][len - 1] == (uint8_t) start[i]);
        for (int p = 1; p < len - 1; p++) assert(seen[i][p] == '0');
    }

    for (int i = 0; i < 40; i++) janet_gcunroot(janet_wrap_symbol(seen[i]));
}

/* The third carry, which the forty-name run above cannot reach: exhausting a
 * position wraps it to '0' and advances the one to its left. Reaching it by
 * counting would take sixty-three names, so the odometer is set to its last
 * value at the lowest position and stepped once. */
static void test_gensym_carries_between_positions(void) {
    janet_collect();
    const int32_t len = (int32_t) sizeof(janet_vm.gensym_counter) - 1;
    memset(&janet_vm.gensym_counter, '0', sizeof(janet_vm.gensym_counter));
    janet_vm.gensym_counter[0] = '_';
    janet_vm.gensym_counter[len - 1] = 'Z';

    const uint8_t *last = janet_symbol_gen();
    janet_gcroot(janet_wrap_symbol(last));
    assert(last[len - 1] == 'Z');
    for (int32_t i = 1; i < len - 1; i++) assert(last[i] == '0');

    const uint8_t *carried = janet_symbol_gen();
    janet_gcroot(janet_wrap_symbol(carried));
    assert(carried != last);
    assert(carried[len - 1] == '0');
    assert(carried[len - 2] == '1');
    for (int32_t i = 1; i < len - 2; i++) assert(carried[i] == '0');

    janet_gcunroot(janet_wrap_symbol(last));
    janet_gcunroot(janet_wrap_symbol(carried));
}

/* The collector's one external obligation: a symbol that dies leaves the
 * cache. `janet_deinit_block` calls `janet_symbol_deinit` from this file, so
 * the round trip is now entirely inside Zig. */
static void test_collected_symbol_leaves_the_cache(void) {
    janet_collect();
    uint32_t before = janet_vm.cache_count;

    for (int i = 0; i < 50; i++) {
        char name[32];
        snprintf(name, sizeof(name), "doomed-symbol-%d", i);
        (void) janet_csymbol(name);
    }
    assert(janet_vm.cache_count == before + 50);

    janet_collect();
    assert(janet_vm.cache_count == before);

    /* A rooted one survives the same collection and keeps its address. */
    const uint8_t *kept = janet_csymbol("kept-symbol");
    janet_gcroot(janet_wrap_symbol(kept));
    janet_collect();
    assert(janet_csymbol("kept-symbol") == kept);
    assert(in_cache(kept));
    janet_gcunroot(janet_wrap_symbol(kept));
}

/* ------------------------------------------------------------------- tuple */

/* A tuple built in two steps. `begin` sets the length and marks the source-map
 * position absent with -1; `end` computes the hash over every slot. */
static void test_tuple_begin_and_end(void) {
    Janet *t = janet_tuple_begin(3);
    assert(janet_tuple_length(t) == 3);
    assert(janet_tuple_sm_line(t) == -1);
    assert(janet_tuple_sm_column(t) == -1);
    assert(memtype(janet_tuple_head(t)) == JANET_MEMORY_TUPLE);
    assert(on_list(janet_vm.blocks, janet_tuple_head(t)));

    t[0] = janet_wrap_integer(1);
    t[1] = janet_wrap_nil();
    t[2] = janet_wrap_keyword(janet_cstring("k"));
    const Janet *done = janet_tuple_end(t);
    assert(done == t);
    assert(janet_tuple_hash(done) == janet_array_calchash(t, 3));

    /* A zero-length tuple is legal and hashes as the empty sequence. */
    const Janet *empty = janet_tuple_end(janet_tuple_begin(0));
    assert(janet_tuple_length(empty) == 0);
    assert(janet_tuple_hash(empty) == janet_array_calchash(empty, 0));
}

/* The one-step constructor copies its elements and closes the tuple, so equal
 * contents give equal hashes -- which is what Part 6c's dictionaries need. */
static void test_tuple_n_copies_and_hashes(void) {
    Janet src[3];
    src[0] = janet_wrap_integer(10);
    src[1] = janet_wrap_true();
    src[2] = janet_wrap_string(janet_cstring("s"));

    const Janet *a = janet_tuple_n(src, 3);
    assert(janet_tuple_length(a) == 3);
    assert(janet_equals(a[0], src[0]));
    assert(janet_equals(a[1], src[1]));
    assert(janet_equals(a[2], src[2]));
    assert(janet_tuple_sm_line(a) == -1);

    /* Copied, not aliased. */
    src[0] = janet_wrap_integer(99);
    assert(janet_equals(a[0], janet_wrap_integer(10)));

    /* Equal contents, equal hash; different contents, different tuple. */
    Janet again[3];
    again[0] = janet_wrap_integer(10);
    again[1] = janet_wrap_true();
    again[2] = janet_wrap_string(janet_cstring("s"));
    const Janet *b = janet_tuple_n(again, 3);
    assert(b != a);
    assert(janet_tuple_hash(b) == janet_tuple_hash(a));
    assert(janet_equals(janet_wrap_tuple(a), janet_wrap_tuple(b)));

    again[0] = janet_wrap_integer(11);
    const Janet *diff = janet_tuple_n(again, 3);
    assert(!janet_equals(janet_wrap_tuple(a), janet_wrap_tuple(diff)));

    /* Zero elements needs no source at all. */
    const Janet *none = janet_tuple_n(NULL, 0);
    assert(janet_tuple_length(none) == 0);
}

/* ------------------------------------------------------- across the seam */

/* The standard library reaches all of this through the public API, so the two
 * selectors have to agree from Janet as well as from C. */
static void test_from_janet(void) {
    Janet out;
    JanetTable *env = janet_core_env(NULL);
    const char *src =
        "(let [s (string \"ab\" \"cd\")\n"
        "      y (symbol \"sy\" \"mb\")\n"
        "      g1 (gensym)\n"
        "      g2 (gensym)\n"
        "      t (tuple 1 2 3)]\n"
        "  [s (length s) (= y (symbol \"symb\")) (not= g1 g2)\n"
        "   (= t [1 2 3]) (= (hash [1 2 3]) (hash t)) (tuple/slice t 1)])";
    assert(janet_dostring(env, src, "string-symbol-test", &out) == 0);
    const Janet *r = janet_unwrap_tuple(out);
    assert(0 == janet_cstrcmp(janet_unwrap_string(r[0]), "abcd"));
    assert(janet_unwrap_integer(r[1]) == 4);
    assert(janet_truthy(r[2]));
    assert(janet_truthy(r[3]));
    assert(janet_truthy(r[4]));
    assert(janet_truthy(r[5]));
    assert(janet_tuple_length(janet_unwrap_tuple(r[6])) == 2);
}

/* ------------------------------------------------------- the registration */

/* Every core cfunction is registered with the file and line it was declared
 * on, and that pair is what a stack trace prints for a frame that is not a
 * Janet function. Phase 10 Part 6 moved the registration of every surface in
 * this file to Zig, where the location comes from `@src()` at the table row
 * rather than from `__LINE__` at the definition; what has to hold either way
 * is that there *is* one.
 *
 * This is here rather than in a Janet suite because nothing in Janet reads the
 * registry directly -- the `:source-map` a binding carries comes from the
 * image, so a runtime that recorded nothing would still answer `(doc)`
 * correctly and only stack traces would go blank. A mutation sweep found that
 * hole. */
static void test_the_registry_records_a_location(void) {
    static const char *const names[] = {
        "tuple/join", "string/split", "buffer/blit", "array/concat",
        "table/clone", "struct/rawget", "math/log2", "int/to-number",
    };
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        Janet binding = janet_resolve_core(names[i]);
        /* A build without integer types has no int/ functions to look up. */
        if (janet_checktype(binding, JANET_NIL)) continue;
        assert(janet_checktype(binding, JANET_CFUNCTION));
        JanetCFunRegistry *entry = janet_registry_get(janet_unwrap_cfunction(binding));
        assert(entry != NULL);
        assert(entry->name != NULL);
        assert(!strcmp((const char *) entry->name, names[i]));
        assert(entry->source_file != NULL);
        assert(entry->source_line > 0);
    }
}

void string_symbol_contract(void) {
    janet_init();

    test_head_layout();

    test_string_begin_and_end();
    test_constructors_write_the_terminator();
    test_string_copies_and_hashes();
    test_string_compare_is_three_valued();
    test_string_equality();

    test_symbol_interns();
    test_symbol_deinit_leaves_a_tombstone();
    test_lookup_reclaims_a_tombstone();
    test_cache_resizes_and_keeps_identity();
    test_tombstones_force_a_rehash();
    test_generated_names_come_from_the_initial_counter();
    test_gensym_advances_the_odometer();
    test_gensym_carries_between_positions();
    test_collected_symbol_leaves_the_cache();

    test_tuple_begin_and_end();
    test_tuple_n_copies_and_hashes();

    test_from_janet();

    test_the_registry_records_a_location();

    janet_deinit();
    printf("string symbol contract ok\n");
}
