/* Behavioral contract for the key/value containers: structs and tables,
 * including the three weak table variants. Run against whichever
 * implementation the build selected (`-Dstruct-table=c` or the Zig default).
 *
 * The two share the `JanetKV` bucket layout and nothing else about how they
 * use it, so the file is organised around the two probing disciplines rather
 * than around the two files.
 *
 * A struct's layout is observable and is part of the language contract. Robin
 * Hood insertion exists so that the bucket array depends on the *set* of pairs
 * and not on the order they arrived in, because `janet_struct_end` hashes the
 * array -- `{1 2 3 4}` and `{3 4 1 2}` must be byte-for-byte identical or they
 * would not be `=`. So the struct tests compare whole bucket arrays position
 * by position rather than asserting properties of one of them -- see
 * `same_layout`, which explains why that is not a `memcmp`.
 *
 * A table's layout is *not* observable and depends on deletion history as well
 * as insertion order. What is checkable there is the policy: the exact
 * capacity after each growth, the tombstone a removal leaves, the fact that a
 * tombstone does not truncate a probe run through it, and the fact that
 * tombstones are reclaimed only by a rehash. Those are asserted as exact
 * numbers, because a policy asserted as an inequality passes for almost any
 * implementation.
 *
 * Two things are deliberately not covered here.
 *
 * Weak tables are checked only for the memory type their constructor stamps
 * and for the heap list that type puts them on. What the collector then does
 * with them belongs to `test/gc_sweep.c`, which already has it.
 *
 * `janet_table_proto_flatten` walks a prototype chain to its end rather than
 * to `JANET_MAX_PROTO_DEPTH`, so a cyclic chain does not terminate. `FOUND.md`
 * records it. No assertion can pin a hang.
 */

#include <assert.h>
#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "features.h"
#include <janet.h>
#include "state.h"
#include "gc.h"
#include "util.h"

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

/* The bucket a key would like to occupy. Spelled out rather than reusing
 * `janet_maphash`, so that a change to that macro shows up as a test failure
 * rather than being tracked silently. */
static int32_t ideal_index(int32_t cap, Janet key) {
    return (int32_t)((uint32_t) janet_hash(key) & (uint32_t)(cap - 1));
}

/* Fill `out` with `want` distinct integer keys that all want the same bucket
 * in an array of `cap` buckets, and return that bucket's index.
 *
 * Searched rather than hard-coded on purpose. Janet's integer hash is a
 * different subsystem and changes outright under `-Dprf`, so a fixed pair of
 * colliding keys would silently stop colliding and every test built on it
 * would keep passing while testing nothing. */
static int32_t find_colliding(int32_t cap, int32_t want, Janet *out) {
    for (int32_t target = 0; target < cap; target++) {
        int32_t found = 0;
        for (int32_t i = 0; i < 200000 && found < want; i++) {
            Janet k = janet_wrap_integer(i);
            if (ideal_index(cap, k) == target) out[found++] = k;
        }
        if (found == want) return target;
    }
    assert(0 && "no set of colliding integer keys was found");
    return -1;
}

/* Fill `out` with `want` distinct integer keys whose ideal buckets are
 * pairwise *different*, which is the opposite need and has the same reason:
 * so that a test about accumulating tombstones is not quietly turned into a
 * test about reusing one. */
static void find_distinct_indices(int32_t cap, int32_t want, Janet *out) {
    int32_t used[64];
    int32_t found = 0;
    assert(want <= cap && cap <= 64);
    for (int32_t i = 0; i < 200000 && found < want; i++) {
        Janet k = janet_wrap_integer(i);
        int32_t idx = ideal_index(cap, k);
        int dup = 0;
        for (int32_t j = 0; j < found; j++) {
            if (used[j] == idx) dup = 1;
        }
        if (!dup) {
            used[found] = idx;
            out[found] = k;
            found++;
        }
    }
    assert(found == want);
}

/* Do two bucket arrays hold the same thing in the same place?
 *
 * Deliberately not `memcmp`. Under `-Dnanbox=false` a `Janet` is a struct with
 * an eight-byte union and a four-byte type tag, so it carries four bytes of
 * tail padding that nothing ever writes -- two identical values compare equal
 * and differ byte for byte. A byte-wise comparison there fails on garbage from
 * the allocator rather than on layout, and passes or fails at random. The
 * layout claim is about which value sits in which bucket, so it is asserted
 * that way. */
static int same_layout(const JanetKV *a, const JanetKV *b, int32_t cap) {
    for (int32_t i = 0; i < cap; i++) {
        if (janet_type(a[i].key) != janet_type(b[i].key)) return 0;
        if (janet_type(a[i].value) != janet_type(b[i].value)) return 0;
        if (!janet_equals(a[i].key, b[i].key)) return 0;
        if (!janet_equals(a[i].value, b[i].value)) return 0;
    }
    return 1;
}

static Janet kw(const char *name) {
    return janet_ckeywordv(name);
}

/* --------------------------------------------------------------- the head */

/* The Zig port recovers a struct's head with `sizeof` because translate-c
 * drops the flexible array member and `offsetof` is unavailable to it. That
 * substitution is only sound if the two agree, and C is the only side that can
 * say so. `test/gc_mark.c` and `test/gc_sweep.c` assert this for the free and
 * mark paths; it is repeated here beside the constructor that depends on it. */
static void test_head_layout(void) {
    assert(sizeof(JanetStructHead) == offsetof(JanetStructHead, data));
}

/* ------------------------------------------------------- struct: allocation */

/* The capacity policy. `janet_tablen` is a *strict* next power of two, so
 * twice the pair count is rounded up past itself: a two-pair struct gets eight
 * buckets, not four. Asserted as exact numbers because the load factor is what
 * bounds Robin Hood displacement, and an off-by-one-doubling would still pass
 * every functional test in this file. */
static void test_struct_begin_capacity(void) {
    assert(janet_struct_capacity(janet_struct_begin(0)) == 1);
    assert(janet_struct_capacity(janet_struct_begin(1)) == 4);
    assert(janet_struct_capacity(janet_struct_begin(2)) == 8);
    assert(janet_struct_capacity(janet_struct_begin(3)) == 8);
    assert(janet_struct_capacity(janet_struct_begin(4)) == 16);
}

static void test_struct_begin_initialises_the_head(void) {
    JanetKV *st = janet_struct_begin(3);
    assert(janet_struct_length(st) == 3);
    assert(janet_struct_capacity(st) == 8);
    /* The hash field is a running count of filled slots until `end` runs. */
    assert(janet_struct_hash(st) == 0);
    assert(janet_struct_proto(st) == NULL);
    for (int32_t i = 0; i < janet_struct_capacity(st); i++) {
        assert(janet_checktype(st[i].key, JANET_NIL));
        assert(janet_checktype(st[i].value, JANET_NIL));
    }
    assert(memtype(janet_struct_head(st)) == JANET_MEMORY_STRUCT);
    assert(on_list(janet_vm.blocks, janet_struct_head(st)));
    assert(!on_list(janet_vm.weak_blocks, janet_struct_head(st)));
}

/* ------------------------------------------------------- struct: insertion */

/* The whole reason Robin Hood insertion is here. Two structs built from the
 * same pairs in different orders must have identical bucket arrays, because
 * `janet_struct_end` hashes the array and `janet_equals` compares the hash
 * first. Compared over the entire array rather than pair by pair, so that a
 * difference in *position* fails as loudly as a difference in contents. */
static void test_struct_layout_is_order_independent(void) {
    Janet keys[6];
    for (int i = 0; i < 6; i++) keys[i] = janet_wrap_integer(i * 37 + 11);

    JanetKV *a = janet_struct_begin(6);
    for (int i = 0; i < 6; i++) janet_struct_put(a, keys[i], janet_wrap_integer(i));
    JanetKV *b = janet_struct_begin(6);
    for (int i = 5; i >= 0; i--) janet_struct_put(b, keys[i], janet_wrap_integer(i));
    /* And a third order that is neither forwards nor backwards. */
    JanetKV *c = janet_struct_begin(6);
    const int order[6] = {3, 0, 5, 1, 4, 2};
    for (int i = 0; i < 6; i++) janet_struct_put(c, keys[order[i]], janet_wrap_integer(order[i]));

    int32_t cap = janet_struct_capacity(a);
    assert(janet_struct_capacity(b) == cap);
    assert(janet_struct_capacity(c) == cap);

    JanetStruct sa = janet_struct_end(a);
    JanetStruct sb = janet_struct_end(b);
    JanetStruct sc = janet_struct_end(c);

    assert(same_layout(sa, sb, cap));
    assert(same_layout(sa, sc, cap));
    assert(janet_struct_hash(sa) == janet_struct_hash(sb));
    assert(janet_struct_hash(sa) == janet_struct_hash(sc));
    assert(janet_equals(janet_wrap_struct(sa), janet_wrap_struct(sb)));
}

/* Order-independence alone does not pin the *direction* of the displacement
 * rule: inverting the comparison consistently still yields a layout that is a
 * function of the pair set. What pins the direction is a run of keys that all
 * want the same bucket, where every displacement comparison ties and the full
 * hash decides. The pair with the larger hash keeps the earlier slot. */
static void test_struct_collision_run_is_ordered_by_hash(void) {
    JanetKV *st = janet_struct_begin(3);
    int32_t cap = janet_struct_capacity(st);
    Janet keys[3];
    int32_t idx = find_colliding(cap, 3, keys);

    for (int i = 0; i < 3; i++) janet_struct_put(st, keys[i], janet_wrap_integer(i));
    JanetStruct s = janet_struct_end(st);

    int32_t prev = 0;
    for (int32_t n = 0; n < 3; n++) {
        const JanetKV *kv = s + ((idx + n) % cap);
        assert(!janet_checktype(kv->key, JANET_NIL));
        int32_t h = janet_hash(kv->key);
        if (n > 0) assert(h < prev);
        prev = h;
    }

    /* Inserted backwards, the run comes out byte for byte the same. */
    JanetKV *st2 = janet_struct_begin(3);
    for (int i = 2; i >= 0; i--) janet_struct_put(st2, keys[i], janet_wrap_integer(i));
    JanetStruct s2 = janet_struct_end(st2);
    assert(same_layout(s, s2, cap));
}

/* The last tiebreak, and the only one that reaches outside this file.
 *
 * `janet_hash` reads only the bytes for all three string-like types, so a
 * keyword and a string spelled the same have the same hash. They want the same
 * bucket, they tie on displacement and they tie on hash, so `janet_compare` is
 * the only thing left -- and the only thing stopping the second from being
 * taken for a duplicate of the first, which would silently drop it. */
static void test_struct_hash_tie_falls_through_to_compare(void) {
    Janet as_keyword = janet_ckeywordv("tie");
    Janet as_string = janet_cstringv("tie");
    assert(janet_hash(as_keyword) == janet_hash(as_string));
    assert(!janet_equals(as_keyword, as_string));
    /* JANET_STRING sorts before JANET_KEYWORD, so the order is by type. */
    assert(janet_compare(as_string, as_keyword) == -1);

    JanetKV *st = janet_struct_begin(2);
    janet_struct_put(st, as_keyword, janet_wrap_integer(1));
    janet_struct_put(st, as_string, janet_wrap_integer(2));
    /* Both landed: neither was mistaken for the other. */
    assert(janet_struct_hash(st) == 2);
    JanetStruct s = janet_struct_end(st);
    assert(janet_struct_length(s) == 2);
    assert(janet_equals(janet_struct_rawget(s, as_keyword), janet_wrap_integer(1)));
    assert(janet_equals(janet_struct_rawget(s, as_string), janet_wrap_integer(2)));

    JanetKV *st2 = janet_struct_begin(2);
    janet_struct_put(st2, as_string, janet_wrap_integer(2));
    janet_struct_put(st2, as_keyword, janet_wrap_integer(1));
    JanetStruct s2 = janet_struct_end(st2);
    assert(same_layout(s, s2, janet_struct_capacity(s)));
}

/* Every pair that lands moves the running count in the hash field. */
static void test_struct_put_counts_in_the_hash_field(void) {
    JanetKV *st = janet_struct_begin(3);
    janet_struct_put(st, kw("a"), janet_wrap_integer(1));
    assert(janet_struct_hash(st) == 1);
    janet_struct_put(st, kw("b"), janet_wrap_integer(2));
    assert(janet_struct_hash(st) == 2);
    /* A duplicate replaces rather than adds, so the count stands still. */
    janet_struct_put(st, kw("a"), janet_wrap_integer(9));
    assert(janet_struct_hash(st) == 2);
}

static void test_struct_put_rejects_unstorable_pairs(void) {
    JanetKV *st = janet_struct_begin(4);
    janet_struct_put(st, janet_wrap_nil(), janet_wrap_integer(1));
    assert(janet_struct_hash(st) == 0);
    janet_struct_put(st, kw("k"), janet_wrap_nil());
    assert(janet_struct_hash(st) == 0);
    janet_struct_put(st, janet_wrap_number_safe(nan("")), janet_wrap_integer(1));
    assert(janet_struct_hash(st) == 0);
    /* And one that is storable, so the three above are shown to be the reason
     * the count stayed at zero rather than the puts not working at all. */
    janet_struct_put(st, kw("k"), janet_wrap_integer(1));
    assert(janet_struct_hash(st) == 1);
}

/* Past the declared length, a put is silently dropped. */
static void test_struct_put_drops_the_surplus(void) {
    JanetKV *st = janet_struct_begin(1);
    janet_struct_put(st, kw("a"), janet_wrap_integer(1));
    janet_struct_put(st, kw("b"), janet_wrap_integer(2));
    assert(janet_struct_hash(st) == 1);
    JanetStruct s = janet_struct_end(st);
    assert(janet_struct_length(s) == 1);
    assert(janet_equals(janet_struct_rawget(s, kw("a")), janet_wrap_integer(1)));
    assert(janet_checktype(janet_struct_rawget(s, kw("b")), JANET_NIL));
}

/* `replace` is what separates `janet_struct_put` from the flattening path:
 * `struct/proto-flatten` walks child first and must not let a prototype's
 * binding overwrite the child's. */
static void test_struct_put_ext_honours_replace(void) {
    JanetKV *keep = janet_struct_begin(2);
    janet_struct_put_ext(keep, kw("a"), janet_wrap_integer(1), 0);
    janet_struct_put_ext(keep, kw("a"), janet_wrap_integer(2), 0);
    assert(janet_equals(janet_struct_rawget(janet_struct_end(keep), kw("a")),
                        janet_wrap_integer(1)));

    JanetKV *over = janet_struct_begin(2);
    janet_struct_put_ext(over, kw("a"), janet_wrap_integer(1), 1);
    janet_struct_put_ext(over, kw("a"), janet_wrap_integer(2), 1);
    assert(janet_equals(janet_struct_rawget(janet_struct_end(over), kw("a")),
                        janet_wrap_integer(2)));
}

/* ------------------------------------------------------------ struct: end */

/* When fewer pairs land than were declared, the array is the wrong size for
 * its contents and the whole struct is rebuilt at the size that fit. */
static void test_struct_end_rebuilds_on_a_short_count(void) {
    JanetKV *proto = janet_struct_begin(1);
    janet_struct_put(proto, kw("p"), janet_wrap_integer(7));
    JanetStruct sproto = janet_struct_end(proto);

    JanetKV *st = janet_struct_begin(3);
    janet_struct_put(st, kw("a"), janet_wrap_integer(1));
    janet_struct_put(st, kw("a"), janet_wrap_integer(2));
    janet_struct_put(st, kw("b"), janet_wrap_integer(3));
    janet_struct_proto(st) = sproto;
    assert(janet_struct_capacity(st) == 8);

    JanetStruct s = janet_struct_end(st);
    assert(s != (JanetStruct) st);
    assert(janet_struct_length(s) == 2);
    assert(janet_struct_capacity(s) == 8);
    assert(janet_equals(janet_struct_rawget(s, kw("a")), janet_wrap_integer(2)));
    assert(janet_equals(janet_struct_rawget(s, kw("b")), janet_wrap_integer(3)));
    /* The prototype is not a bucket, so it is carried across by hand. */
    assert(janet_struct_proto(s) == sproto);
}

static void test_struct_end_keeps_the_array_when_the_count_is_exact(void) {
    JanetKV *st = janet_struct_begin(2);
    janet_struct_put(st, kw("a"), janet_wrap_integer(1));
    janet_struct_put(st, kw("b"), janet_wrap_integer(2));
    JanetStruct s = janet_struct_end(st);
    assert(s == (JanetStruct) st);
}

/* The prototype contributes to the hash by a multiply, so it costs one read
 * rather than a walk -- and two structs with the same pairs and different
 * prototypes are distinguishable. */
static void test_struct_end_folds_the_prototype_into_the_hash(void) {
    JanetKV *p = janet_struct_begin(1);
    janet_struct_put(p, kw("p"), janet_wrap_integer(1));
    JanetStruct sp = janet_struct_end(p);

    JanetKV *bare = janet_struct_begin(1);
    janet_struct_put(bare, kw("a"), janet_wrap_integer(1));
    JanetStruct sbare = janet_struct_end(bare);

    JanetKV *with = janet_struct_begin(1);
    janet_struct_put(with, kw("a"), janet_wrap_integer(1));
    janet_struct_proto(with) = sp;
    JanetStruct swith = janet_struct_end(with);

    assert(same_layout(sbare, swith, janet_struct_capacity(sbare)));
    assert(janet_struct_hash(sbare) != janet_struct_hash(swith));

    int32_t expected = (int32_t)((uint32_t) janet_kv_calchash(swith, janet_struct_capacity(swith)) +
                                 2654435761u * (uint32_t) janet_struct_hash(sp));
    assert(janet_struct_hash(swith) == expected);
}

/* ---------------------------------------------------------- struct: lookup */

static void test_struct_find_returns_an_empty_bucket_for_an_absent_key(void) {
    JanetKV *st = janet_struct_begin(2);
    janet_struct_put(st, kw("a"), janet_wrap_integer(1));
    JanetStruct s = janet_struct_end(st);

    const JanetKV *hit = janet_struct_find(s, kw("a"));
    assert(hit != NULL);
    assert(janet_equals(hit->value, janet_wrap_integer(1)));

    const JanetKV *miss = janet_struct_find(s, kw("zz"));
    assert(miss != NULL);
    assert(janet_checktype(miss->key, JANET_NIL));
    assert(janet_checktype(janet_struct_rawget(s, kw("zz")), JANET_NIL));
}

/* Build a chain `depth` deep and return the deepest struct. Entry `i` holds
 * the key `i` and its prototype is entry `i - 1`. */
static JanetStruct struct_chain(int depth) {
    JanetStruct proto = NULL;
    for (int i = 0; i < depth; i++) {
        JanetKV *st = janet_struct_begin(1);
        janet_struct_put(st, janet_wrap_integer(i), janet_wrap_integer(i));
        janet_struct_proto(st) = proto;
        proto = janet_struct_end(st);
    }
    return proto;
}

/* The chain walk is bounded, and the bound is enumerated rather than sampled:
 * the last reachable depth and the first unreachable one are both asserted. */
static void test_struct_get_bounds_the_prototype_chain(void) {
    JanetStruct deep = struct_chain(JANET_MAX_PROTO_DEPTH + 5);
    /* The head holds the highest key; the walk descends toward key 0. */
    int32_t top = JANET_MAX_PROTO_DEPTH + 4;
    assert(janet_equals(janet_struct_get(deep, janet_wrap_integer(top)),
                        janet_wrap_integer(top)));
    int32_t last = top - (JANET_MAX_PROTO_DEPTH - 1);
    assert(janet_equals(janet_struct_get(deep, janet_wrap_integer(last)),
                        janet_wrap_integer(last)));
    assert(janet_checktype(janet_struct_get(deep, janet_wrap_integer(last - 1)),
                           JANET_NIL));
    /* rawget never leaves the head at all. */
    assert(janet_checktype(janet_struct_rawget(deep, janet_wrap_integer(top - 1)),
                           JANET_NIL));
}

static void test_struct_get_ex_reports_the_owner(void) {
    JanetKV *p = janet_struct_begin(1);
    janet_struct_put(p, kw("a"), janet_wrap_integer(1));
    JanetStruct sp = janet_struct_end(p);

    JanetKV *ch = janet_struct_begin(1);
    janet_struct_put(ch, kw("b"), janet_wrap_integer(2));
    janet_struct_proto(ch) = sp;
    JanetStruct sch = janet_struct_end(ch);

    JanetStruct which = NULL;
    assert(janet_equals(janet_struct_get_ex(sch, kw("b"), &which), janet_wrap_integer(2)));
    assert(which == sch);
    which = NULL;
    assert(janet_equals(janet_struct_get_ex(sch, kw("a"), &which), janet_wrap_integer(1)));
    assert(which == sp);
}

/* ------------------------------------------------------ struct: conversion */

/* The new table is sized from the struct's *capacity*, not its pair count,
 * which is why a two-pair struct becomes a sixteen-bucket table. */
static void test_struct_to_table(void) {
    JanetKV *p = janet_struct_begin(1);
    janet_struct_put(p, kw("p"), janet_wrap_integer(9));
    JanetStruct sp = janet_struct_end(p);

    JanetKV *st = janet_struct_begin(2);
    janet_struct_put(st, kw("a"), janet_wrap_integer(1));
    janet_struct_put(st, kw("b"), janet_wrap_integer(2));
    janet_struct_proto(st) = sp;
    JanetStruct s = janet_struct_end(st);

    JanetTable *t = janet_struct_to_table(s);
    assert(t->count == 2);
    assert(t->capacity == janet_tablen(janet_struct_capacity(s)));
    assert(t->capacity == 16);
    assert(janet_equals(janet_table_rawget(t, kw("a")), janet_wrap_integer(1)));
    assert(janet_equals(janet_table_rawget(t, kw("b")), janet_wrap_integer(2)));
    /* The prototype is not carried; `struct/to-table` rebuilds it itself. */
    assert(t->proto == NULL);
    assert(janet_checktype(janet_table_get(t, kw("p")), JANET_NIL));
}

/* ------------------------------------------------------- table: allocation */

/* `janet_tablen` rounds strictly up, so a requested capacity of zero still
 * gets one bucket -- there is no such thing as an empty bucket array reached
 * from a non-negative request.
 *
 * A *negative* request produces one, and the resulting table cannot be looked
 * up in at all: `janet_maphash` masks the hash with `capacity - 1`, which for a
 * zero capacity is every bit set, so `janet_dict_find` treats the whole hash as
 * a bucket number and both of its loops are bounded by it rather than by the
 * capacity. Only a hash of exactly zero survives. `FOUND.md` records it, with
 * the reproducer. Nothing below touches such a table
 * beyond its fields, because the behaviour is undefined and a contract cannot
 * pin it. */
static void test_table_capacity_rounding(void) {
    assert(janet_table(0)->capacity == 1);
    assert(janet_table(1)->capacity == 2);
    assert(janet_table(4)->capacity == 8);

    JanetTable *empty = janet_table(-1);
    assert(empty->capacity == 0);
    assert(empty->data == NULL);
    assert(empty->count == 0);
    assert(empty->deleted == 0);
}

static void test_table_constructor_marks_and_lists(void) {
    struct {
        JanetTable *(*make)(int32_t);
        int type;
        int weak;
    } cases[] = {
        {janet_table, JANET_MEMORY_TABLE, 0},
        {janet_table_weakk, JANET_MEMORY_TABLE_WEAKK, 1},
        {janet_table_weakv, JANET_MEMORY_TABLE_WEAKV, 1},
        {janet_table_weakkv, JANET_MEMORY_TABLE_WEAKKV, 1},
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        JanetTable *t = cases[i].make(4);
        assert(memtype(t) == cases[i].type);
        assert(t->capacity == 8);
        assert(t->count == 0);
        assert(t->deleted == 0);
        assert(t->proto == NULL);
        /* The memory type is what decides the heap list, and the two weak
         * variants of that decision are what the sweep depends on. */
        assert(on_list(janet_vm.weak_blocks, t) == cases[i].weak);
        assert(on_list(janet_vm.blocks, t) == !cases[i].weak);
        /* All four behave identically as dictionaries. */
        janet_table_put(t, kw("a"), janet_wrap_integer(1));
        assert(janet_equals(janet_table_rawget(t, kw("a")), janet_wrap_integer(1)));
    }
}

/* A scratch table is caller-owned memory whose buckets come from the scratch
 * allocator. The flag lives in the same word as the memory type, which is safe
 * only because such a table is never `janet_gcalloc`ed -- so the flag is
 * asserted as the whole word, not as a bit. */
static void test_table_init_uses_scratch_memory(void) {
    JanetTable local;
    memset(&local, 0xEE, sizeof(local));
    janet_table_init(&local, 4);
    assert(local.gc.flags == 0x10000);
    assert(local.capacity == 8);
    assert(local.count == 0);
    assert(local.deleted == 0);
    assert(local.proto == NULL);

    /* Grow it, so the rehash takes the scratch branch too. */
    for (int32_t i = 0; i < 40; i++) {
        janet_table_put(&local, janet_wrap_integer(i), janet_wrap_integer(i * 2));
    }
    assert(local.count == 40);
    assert(local.gc.flags == 0x10000);
    for (int32_t i = 0; i < 40; i++) {
        assert(janet_equals(janet_table_rawget(&local, janet_wrap_integer(i)),
                            janet_wrap_integer(i * 2)));
    }
    janet_table_deinit(&local);
}

static void test_table_init_raw_leaves_the_flag_clear(void) {
    JanetTable local;
    memset(&local, 0, sizeof(local));
    janet_table_init_raw(&local, 4);
    assert(local.gc.flags == 0);
    assert(local.capacity == 8);
    janet_table_put(&local, kw("a"), janet_wrap_integer(1));
    assert(janet_equals(janet_table_rawget(&local, kw("a")), janet_wrap_integer(1)));
    janet_table_deinit(&local);
}

/* --------------------------------------------------------- table: growth */

/* The growth policy, as exact capacities. A rehash happens when twice the live
 * pairs plus the tombstones plus one would exceed the capacity, and the new
 * capacity is `janet_tablen(2 * count + 2)`. */
static void test_table_growth_capacities(void) {
    JanetTable *t = janet_table(0);
    const int32_t expected[] = {4, 4, 8, 8, 16, 16, 16, 16, 32};
    for (int32_t i = 0; i < 9; i++) {
        janet_table_put(t, janet_wrap_integer(i), janet_wrap_integer(i));
        assert(t->count == i + 1);
        assert(t->capacity == expected[i]);
    }
    for (int32_t i = 0; i < 9; i++) {
        assert(janet_equals(janet_table_rawget(t, janet_wrap_integer(i)),
                            janet_wrap_integer(i)));
    }
}

/* --------------------------------------------------------- table: removal */

/* A removal leaves a nil key and a *false* value. The falseness is the
 * tombstone marker: `janet_dict_find` stops only where key and value are both
 * nil, so a run of probes passes through the hole instead of ending at it. */
static void test_remove_leaves_a_tombstone(void) {
    JanetTable *t = janet_table(4);
    janet_table_put(t, kw("a"), janet_wrap_integer(1));
    JanetKV *bucket = janet_table_find(t, kw("a"));
    assert(!janet_checktype(bucket->key, JANET_NIL));

    Janet gone = janet_table_remove(t, kw("a"));
    assert(janet_equals(gone, janet_wrap_integer(1)));
    assert(t->count == 0);
    assert(t->deleted == 1);
    assert(janet_checktype(bucket->key, JANET_NIL));
    assert(janet_checktype(bucket->value, JANET_BOOLEAN));
    assert(!janet_truthy(bucket->value));

    /* Removing an absent key changes nothing. */
    assert(janet_checktype(janet_table_remove(t, kw("zz")), JANET_NIL));
    assert(t->count == 0);
    assert(t->deleted == 1);
}

/* The property the tombstone exists for. Two keys that want the same bucket,
 * the first removed: the second must still be found through the hole. */
static void test_a_tombstone_does_not_truncate_a_probe_run(void) {
    JanetTable *t = janet_table(4);
    assert(t->capacity == 8);
    Janet keys[2];
    int32_t idx = find_colliding(t->capacity, 2, keys);
    assert(idx >= 0);

    janet_table_put(t, keys[0], janet_wrap_integer(10));
    janet_table_put(t, keys[1], janet_wrap_integer(20));
    assert(t->count == 2);
    assert(t->capacity == 8);
    /* The second key really did displace: it is not in its ideal bucket. */
    assert(janet_table_find(t, keys[1]) != t->data + idx);

    janet_table_remove(t, keys[0]);
    assert(janet_equals(janet_table_rawget(t, keys[1]), janet_wrap_integer(20)));
    assert(janet_checktype(janet_table_rawget(t, keys[0]), JANET_NIL));
}

/* A rehash is the only thing that reclaims a tombstone.
 *
 * It is tempting to expect re-inserting the key that was just removed to fill
 * its own hole, and the `--t->deleted` branch in `janet_table_put` reads as
 * though it does. It does not. `janet_dict_find` returns the first *truly*
 * empty bucket it reaches and falls back on a remembered tombstone only if the
 * array has no empty bucket anywhere -- and the growth test keeps the array at
 * most half full counting tombstones, so an empty bucket always exists. The
 * re-inserted key therefore takes the slot *after* its own hole and the
 * tombstone stays. `FOUND.md` records the branch as unreachable. */
static void test_tombstones_are_reclaimed(void) {
    JanetTable *t = janet_table(4);
    janet_table_put(t, kw("a"), janet_wrap_integer(1));
    JanetKV *first = janet_table_find(t, kw("a"));
    janet_table_remove(t, kw("a"));
    assert(t->deleted == 1);
    janet_table_put(t, kw("a"), janet_wrap_integer(2));
    assert(t->count == 1);
    assert(t->deleted == 1);
    assert(janet_table_find(t, kw("a")) != first);
    assert(janet_checktype(first->key, JANET_NIL));
    assert(janet_checktype(first->value, JANET_BOOLEAN));
    assert(janet_equals(janet_table_rawget(t, kw("a")), janet_wrap_integer(2)));

    /* Otherwise a tombstone is reclaimed only by a rehash, and the rehash is
     * driven by the tombstone count alone -- a table with no live pairs at all
     * still grows. Keys at pairwise-distinct ideal buckets, so that each
     * removal leaves a tombstone instead of the next insert reusing the last
     * one. Capacity 8 trips at `count + deleted >= 4`. */
    JanetTable *c = janet_table(4);
    assert(c->capacity == 8);
    Janet keys[5];
    find_distinct_indices(c->capacity, 5, keys);
    for (int32_t i = 0; i < 4; i++) {
        janet_table_put(c, keys[i], janet_wrap_integer(i));
        janet_table_remove(c, keys[i]);
    }
    assert(c->count == 0);
    assert(c->deleted == 4);
    assert(c->capacity == 8);

    janet_table_put(c, keys[4], janet_wrap_integer(4));
    /* `janet_tablen(2 * 0 + 2)` is 4: the new array is sized from the live
     * count, so a table that was only ever churned shrinks. */
    assert(c->capacity == 4);
    assert(c->deleted == 0);
    assert(c->count == 1);
    assert(janet_equals(janet_table_rawget(c, keys[4]), janet_wrap_integer(4)));
}

/* --------------------------------------------------------- table: put rules */

static void test_table_put_rejects_unstorable_keys(void) {
    JanetTable *t = janet_table(4);
    janet_table_put(t, janet_wrap_nil(), janet_wrap_integer(1));
    assert(t->count == 0);
    janet_table_put(t, janet_wrap_number_safe(nan("")), janet_wrap_integer(1));
    assert(t->count == 0);
    janet_table_put(t, kw("k"), janet_wrap_integer(1));
    assert(t->count == 1);
}

/* A nil value is a removal, not a stored nil. This is what makes an absent key
 * and a nil-valued key indistinguishable. */
static void test_table_put_nil_removes(void) {
    JanetTable *t = janet_table(4);
    janet_table_put(t, kw("a"), janet_wrap_integer(1));
    assert(t->count == 1);
    janet_table_put(t, kw("a"), janet_wrap_nil());
    assert(t->count == 0);
    assert(t->deleted == 1);
    assert(janet_checktype(janet_table_rawget(t, kw("a")), JANET_NIL));

    /* And a nil value for an absent key is not a removal of anything. */
    janet_table_put(t, kw("zz"), janet_wrap_nil());
    assert(t->count == 0);
    assert(t->deleted == 1);
}

static void test_table_put_updates_in_place(void) {
    JanetTable *t = janet_table(4);
    janet_table_put(t, kw("a"), janet_wrap_integer(1));
    JanetKV *bucket = janet_table_find(t, kw("a"));
    int32_t cap = t->capacity;
    janet_table_put(t, kw("a"), janet_wrap_integer(2));
    assert(t->count == 1);
    assert(t->capacity == cap);
    assert(janet_table_find(t, kw("a")) == bucket);
    assert(janet_equals(bucket->value, janet_wrap_integer(2)));
}

/* ---------------------------------------------------------- table: lookup */

static void test_table_get_bounds_the_prototype_chain(void) {
    JanetTable *deep = NULL;
    for (int32_t i = 0; i < JANET_MAX_PROTO_DEPTH + 5; i++) {
        JanetTable *t = janet_table(1);
        janet_table_put(t, janet_wrap_integer(i), janet_wrap_integer(i));
        t->proto = deep;
        deep = t;
    }
    int32_t top = JANET_MAX_PROTO_DEPTH + 4;
    assert(janet_equals(janet_table_get(deep, janet_wrap_integer(top)),
                        janet_wrap_integer(top)));
    int32_t last = top - (JANET_MAX_PROTO_DEPTH - 1);
    assert(janet_equals(janet_table_get(deep, janet_wrap_integer(last)),
                        janet_wrap_integer(last)));
    assert(janet_checktype(janet_table_get(deep, janet_wrap_integer(last - 1)),
                           JANET_NIL));
    assert(janet_checktype(janet_table_rawget(deep, janet_wrap_integer(top - 1)),
                           JANET_NIL));
}

static void test_table_get_ex_reports_the_owner(void) {
    JanetTable *proto = janet_table(2);
    janet_table_put(proto, kw("a"), janet_wrap_integer(1));
    JanetTable *child = janet_table(2);
    janet_table_put(child, kw("b"), janet_wrap_integer(2));
    child->proto = proto;

    JanetTable *which = NULL;
    assert(janet_equals(janet_table_get_ex(child, kw("b"), &which), janet_wrap_integer(2)));
    assert(which == child);
    which = NULL;
    assert(janet_equals(janet_table_get_ex(child, kw("a"), &which), janet_wrap_integer(1)));
    assert(which == proto);
}

/* Looking a key up from raw bytes, without interning it first. Used by the
 * compiler against the core environment. */
static void test_table_get_keyword(void) {
    JanetTable *proto = janet_table(4);
    janet_table_put(proto, kw("deep"), janet_wrap_integer(2));
    JanetTable *t = janet_table(4);
    janet_table_put(t, kw("hello"), janet_wrap_integer(1));
    t->proto = proto;

    assert(janet_equals(janet_table_get_keyword(t, "hello"), janet_wrap_integer(1)));
    assert(janet_equals(janet_table_get_keyword(t, "deep"), janet_wrap_integer(2)));
    assert(janet_checktype(janet_table_get_keyword(t, "missing"), JANET_NIL));
    /* A prefix of a present key is not that key. */
    assert(janet_checktype(janet_table_get_keyword(t, "hell"), JANET_NIL));
}

/* --------------------------------------------------------- table: wholesale */

/* Clearing keeps the bucket array and the prototype, and drops both counts. */
static void test_table_clear(void) {
    JanetTable *proto = janet_table(2);
    JanetTable *t = janet_table(4);
    t->proto = proto;
    for (int32_t i = 0; i < 6; i++) janet_table_put(t, janet_wrap_integer(i), janet_wrap_integer(i));
    janet_table_remove(t, janet_wrap_integer(0));
    int32_t cap = t->capacity;
    JanetKV *data = t->data;
    assert(t->deleted == 1);

    janet_table_clear(t);
    assert(t->count == 0);
    assert(t->deleted == 0);
    assert(t->capacity == cap);
    assert(t->data == data);
    assert(t->proto == proto);
    for (int32_t i = 0; i < cap; i++) {
        assert(janet_checktype(data[i].key, JANET_NIL));
        assert(janet_checktype(data[i].value, JANET_NIL));
    }
}

/* A clone copies the bucket array verbatim, so it keeps the original's
 * tombstones and its `deleted` count rather than compacting them away. */
static void test_table_clone_copies_the_layout(void) {
    JanetTable *proto = janet_table(2);
    JanetTable *t = janet_table(4);
    t->proto = proto;
    for (int32_t i = 0; i < 4; i++) janet_table_put(t, janet_wrap_integer(i), janet_wrap_integer(i));
    janet_table_remove(t, janet_wrap_integer(1));
    assert(t->deleted == 1);

    JanetTable *cl = janet_table_clone(t);
    assert(cl != t);
    assert(cl->data != t->data);
    assert(cl->count == t->count);
    assert(cl->capacity == t->capacity);
    assert(cl->deleted == t->deleted);
    /* The prototype is shared, not cloned. */
    assert(cl->proto == proto);
    assert(memtype(cl) == JANET_MEMORY_TABLE);
    assert(same_layout(cl->data, t->data, t->capacity));

    /* And the two are independent afterwards. */
    janet_table_put(cl, kw("new"), janet_wrap_integer(9));
    assert(janet_checktype(janet_table_rawget(t, kw("new")), JANET_NIL));
}

/* Cloning a table with no bucket array. This is the `memcpy(dst, NULL, 0)`
 * that `FOUND.md` records against the C original, and it is the only thing
 * asserted here: the clone's fields, not its usability. A zero-capacity table
 * cannot be looked up in on either side -- see `test_table_capacity_rounding`
 * -- so a clone of one cannot be either. */
static void test_table_clone_of_an_empty_array(void) {
    JanetTable *empty = janet_table(-1);
    assert(empty->data == NULL);
    JanetTable *cl = janet_table_clone(empty);
    assert(cl != empty);
    assert(cl->count == 0);
    assert(cl->capacity == 0);
    assert(cl->deleted == 0);
    assert(memtype(cl) == JANET_MEMORY_TABLE);
}

/* Merging takes the source's own pairs only. Its prototype is not consulted,
 * which is what separates a merge from a flatten. */
static void test_table_merge(void) {
    JanetTable *proto = janet_table(2);
    janet_table_put(proto, kw("p"), janet_wrap_integer(9));
    JanetTable *src = janet_table(2);
    janet_table_put(src, kw("a"), janet_wrap_integer(1));
    src->proto = proto;

    JanetTable *dst = janet_table(2);
    janet_table_put(dst, kw("a"), janet_wrap_integer(0));
    janet_table_put(dst, kw("b"), janet_wrap_integer(2));
    janet_table_merge_table(dst, src);
    assert(janet_equals(janet_table_rawget(dst, kw("a")), janet_wrap_integer(1)));
    assert(janet_equals(janet_table_rawget(dst, kw("b")), janet_wrap_integer(2)));
    assert(janet_checktype(janet_table_rawget(dst, kw("p")), JANET_NIL));

    JanetKV *sp = janet_struct_begin(1);
    janet_struct_put(sp, kw("s"), janet_wrap_integer(5));
    JanetStruct sproto = janet_struct_end(sp);
    JanetKV *ss = janet_struct_begin(1);
    janet_struct_put(ss, kw("c"), janet_wrap_integer(3));
    janet_struct_proto(ss) = sproto;
    JanetStruct s = janet_struct_end(ss);

    janet_table_merge_struct(dst, s);
    assert(janet_equals(janet_table_rawget(dst, kw("c")), janet_wrap_integer(3)));
    assert(janet_checktype(janet_table_rawget(dst, kw("s")), JANET_NIL));
}

/* The struct is begun at the table's live count, so tombstones cost nothing. */
static void test_table_to_struct_ignores_tombstones(void) {
    JanetTable *t = janet_table(4);
    for (int32_t i = 0; i < 6; i++) janet_table_put(t, janet_wrap_integer(i), janet_wrap_integer(i));
    janet_table_remove(t, janet_wrap_integer(2));
    janet_table_remove(t, janet_wrap_integer(3));
    assert(t->count == 4);
    assert(t->deleted == 2);

    JanetStruct s = janet_table_to_struct(t);
    assert(janet_struct_length(s) == 4);
    assert(janet_struct_proto(s) == NULL);
    assert(janet_equals(janet_struct_rawget(s, janet_wrap_integer(0)), janet_wrap_integer(0)));
    assert(janet_checktype(janet_struct_rawget(s, janet_wrap_integer(2)), JANET_NIL));

    /* Round-tripping a struct through a table and back reproduces it exactly,
     * which is the order-independence property seen from the other side: the
     * table hands the pairs back in bucket order, not insertion order. */
    JanetStruct back = janet_table_to_struct(janet_struct_to_table(s));
    assert(janet_struct_capacity(back) == janet_struct_capacity(s));
    assert(same_layout(back, s, janet_struct_capacity(s)));
}

/* Flattening walks child first and never overwrites, so a binding nearer the
 * child wins -- the same precedence a chained lookup would have given. */
static void test_table_proto_flatten(void) {
    JanetTable *gp = janet_table(2);
    janet_table_put(gp, kw("a"), janet_wrap_integer(3));
    janet_table_put(gp, kw("c"), janet_wrap_integer(30));
    JanetTable *p = janet_table(2);
    janet_table_put(p, kw("a"), janet_wrap_integer(2));
    janet_table_put(p, kw("b"), janet_wrap_integer(20));
    p->proto = gp;
    JanetTable *ch = janet_table(2);
    janet_table_put(ch, kw("a"), janet_wrap_integer(1));
    ch->proto = p;

    JanetTable *flat = janet_table_proto_flatten(ch);
    assert(flat->proto == NULL);
    assert(flat->count == 3);
    assert(janet_equals(janet_table_rawget(flat, kw("a")), janet_wrap_integer(1)));
    assert(janet_equals(janet_table_rawget(flat, kw("b")), janet_wrap_integer(20)));
    assert(janet_equals(janet_table_rawget(flat, kw("c")), janet_wrap_integer(30)));

    /* A tombstone in a source table is not carried into the result. */
    janet_table_remove(ch, kw("a"));
    JanetTable *again = janet_table_proto_flatten(ch);
    assert(again->deleted == 0);
    assert(janet_equals(janet_table_rawget(again, kw("a")), janet_wrap_integer(2)));
}

/* ------------------------------------------------------- through the runtime */

/* The same properties once more, reached the way a Janet program reaches them,
 * so that the C entry points above are shown to be the ones the language is
 * actually built on. */
static void test_from_janet(void) {
    Janet out;
    const char *src =
        "[(= {1 2 3 4} {3 4 1 2}) "
        " (= (hash {1 2 3 4}) (hash {3 4 1 2})) "
        " (get (struct/with-proto {:p 1} :a 2) :p) "
        " (struct/rawget (struct/with-proto {:p 1} :a 2) :p) "
        " (do (def t @{:a 1}) (put t :a nil) (length t)) "
        " (do (def t @{:a 1}) (table/setproto t @{:b 2}) (get t :b)) "
        " (table/proto-flatten (table/setproto @{:a 1} @{:a 2 :b 3})) "
        " (length (table/to-struct (do (def t @{:a 1 :b 2}) (put t :a nil) t))) "
        " (do (def t @{:a 1}) (table/clear t) (length t))]";
    assert(janet_dostring(janet_core_env(NULL), src, "struct_table", &out) == 0);
    const Janet *r = janet_unwrap_tuple(out);
    assert(janet_truthy(r[0]));
    assert(janet_truthy(r[1]));
    assert(janet_unwrap_integer(r[2]) == 1);
    assert(janet_checktype(r[3], JANET_NIL));
    assert(janet_unwrap_integer(r[4]) == 0);
    assert(janet_unwrap_integer(r[5]) == 2);
    JanetTable *flat = janet_unwrap_table(r[6]);
    assert(janet_equals(janet_table_rawget(flat, kw("a")), janet_wrap_integer(1)));
    assert(janet_equals(janet_table_rawget(flat, kw("b")), janet_wrap_integer(3)));
    assert(janet_unwrap_integer(r[7]) == 1);
    assert(janet_unwrap_integer(r[8]) == 0);
}

int main(void) {
    janet_init();

    test_head_layout();

    test_struct_begin_capacity();
    test_struct_begin_initialises_the_head();
    test_struct_layout_is_order_independent();
    test_struct_collision_run_is_ordered_by_hash();
    test_struct_hash_tie_falls_through_to_compare();
    test_struct_put_counts_in_the_hash_field();
    test_struct_put_rejects_unstorable_pairs();
    test_struct_put_drops_the_surplus();
    test_struct_put_ext_honours_replace();
    test_struct_end_rebuilds_on_a_short_count();
    test_struct_end_keeps_the_array_when_the_count_is_exact();
    test_struct_end_folds_the_prototype_into_the_hash();
    test_struct_find_returns_an_empty_bucket_for_an_absent_key();
    test_struct_get_bounds_the_prototype_chain();
    test_struct_get_ex_reports_the_owner();
    test_struct_to_table();

    test_table_capacity_rounding();
    test_table_constructor_marks_and_lists();
    test_table_init_uses_scratch_memory();
    test_table_init_raw_leaves_the_flag_clear();
    test_table_growth_capacities();
    test_remove_leaves_a_tombstone();
    test_a_tombstone_does_not_truncate_a_probe_run();
    test_tombstones_are_reclaimed();
    test_table_put_rejects_unstorable_keys();
    test_table_put_nil_removes();
    test_table_put_updates_in_place();
    test_table_get_bounds_the_prototype_chain();
    test_table_get_ex_reports_the_owner();
    test_table_get_keyword();
    test_table_clear();
    test_table_clone_copies_the_layout();
    test_table_clone_of_an_empty_array();
    test_table_merge();
    test_table_to_struct_ignores_tombstones();
    test_table_proto_flatten();

    test_from_janet();

    janet_deinit();
    printf("struct table contract ok\n");
    return 0;
}
