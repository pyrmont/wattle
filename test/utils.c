#include <assert.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>

#include "features.h"
#include <janet.h>

#include "support.h"
#include "util.h"

/* The four out-of-line head accessors, which janet.h declares beside macros of
 * the same name. Every call below is parenthesised so the macro does not eat
 * it, and every one is checked against the macro: an embedder that reaches
 * Janet through the shared library gets the function, everything inside the
 * runtime gets the macro, and the port has to keep them the same pointer.
 *
 * They are the reason the Zig implementations compute the offset with
 * `@sizeOf` rather than `@offsetOf`: `data` is a flexible array member, which
 * translate-c drops, so Zig cannot take its offset. The two agree only because
 * `data` is maximally aligned within each head, and that is what these
 * assertions check from the side where the member is visible. */
static const JanetAbstractType head_probe_at = {
    "utils/head-probe", NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL, NULL
};

static void test_heads(void) {
    JanetString s = janet_cstring("hello");
    Janet items[2];
    JanetTuple tup;
    JanetKV *kvs;
    JanetStruct st;
    void *abst;

    assert((janet_string_head)(s) == janet_string_head(s));
    assert((janet_string_head)(s)->length == 5);
    assert((const uint8_t *)((janet_string_head)(s)->data) == s);

    items[0] = janet_wrap_integer(1);
    items[1] = janet_wrap_integer(2);
    tup = janet_tuple_n(items, 2);
    assert((janet_tuple_head)(tup) == janet_tuple_head(tup));
    assert((janet_tuple_head)(tup)->length == 2);
    assert((const Janet *)((janet_tuple_head)(tup)->data) == tup);

    kvs = janet_struct_begin(1);
    janet_struct_put(kvs, janet_ckeywordv("k"), janet_wrap_integer(3));
    st = janet_struct_end(kvs);
    assert((janet_struct_head)(st) == janet_struct_head(st));
    assert((janet_struct_head)(st)->length == 1);
    assert((const JanetKV *)((janet_struct_head)(st)->data) == st);

    abst = janet_abstract(CONTRACT_AT(head_probe_at), 8);
    assert((janet_abstract_head)(abst) == janet_abstract_head(abst));
    assert((janet_abstract_head)(abst)->size == 8);
    assert((void *)((janet_abstract_head)(abst)->data) == abst);
}

/* Phase 10 Part 17f. What only a C caller can reach.
 *
 * The dictionary probe, the two string comparisons and the key sort are on the
 * path of every table lookup and every printed table, so
 * `port/probe-17/util-remainder.janet` covers them from Janet and this covers
 * what it cannot see: the probe's own return value, which distinguishes a
 * tombstone from an empty bucket, and the comparisons' behaviour around an
 * embedded NUL. */

static void test_cstrcmp(void) {
    /* A Janet string knows its length; the C string ends at a NUL. So the
     * comparison stops at whichever comes first, and equality needs both to
     * end together. */
    assert(janet_cstrcmp(janet_cstring("abc"), "abc") == 0);
    assert(janet_cstrcmp(janet_cstring(""), "") == 0);
    assert(janet_cstrcmp(janet_cstring("abc"), "abd") == -1);
    assert(janet_cstrcmp(janet_cstring("abd"), "abc") == 1);

    /* A prefix on either side. The shorter Janet string runs out first and the
     * result is decided after the loop; the shorter C string is found by the
     * NUL test inside it. */
    assert(janet_cstrcmp(janet_cstring("ab"), "abc") == -1);
    assert(janet_cstrcmp(janet_cstring("abc"), "ab") == 1);

    /* A Janet string may contain a NUL, and then it compares *greater* than
     * the C string that stops there -- the loop breaks with k == '\0' and
     * c == '\0' equal, and the answer is decided by what follows in the C
     * string, which is nothing. */
    {
        JanetString embedded = janet_string((const uint8_t *)"a\0b", 3);
        assert(janet_string_length(embedded) == 3);
        assert(janet_cstrcmp(embedded, "a") == 0);
        assert(janet_cstrcmp(embedded, "a\0b") == 0);
    }
}

/* `janet_strbinsearch` wants an array of structs whose first member is a
 * `char *`, sorted by it. Two shapes, to prove the item size is respected
 * rather than assumed. */
typedef struct {
    const char *name;
    int value;
} SearchSmall;

typedef struct {
    const char *name;
    double a;
    double b;
    double c;
} SearchBig;

static void test_strbinsearch(void) {
    static const SearchSmall small[] = {
        {"alpha", 1}, {"beta", 2}, {"delta", 3}, {"gamma", 4}, {"omega", 5}
    };
    static const SearchBig big[] = {
        {"alpha", 0, 0, 0}, {"beta", 0, 0, 0}, {"gamma", 0, 0, 0}
    };
    const SearchSmall *hit;
    const SearchBig *bighit;

    hit = janet_strbinsearch(small, 5, sizeof(SearchSmall), janet_cstring("alpha"));
    assert(hit != NULL && hit->value == 1);
    hit = janet_strbinsearch(small, 5, sizeof(SearchSmall), janet_cstring("omega"));
    assert(hit != NULL && hit->value == 5);
    hit = janet_strbinsearch(small, 5, sizeof(SearchSmall), janet_cstring("delta"));
    assert(hit != NULL && hit->value == 3);
    assert(janet_strbinsearch(small, 5, sizeof(SearchSmall), janet_cstring("zeta")) == NULL);
    assert(janet_strbinsearch(small, 5, sizeof(SearchSmall), janet_cstring("aa")) == NULL);
    assert(janet_strbinsearch(small, 5, sizeof(SearchSmall), janet_cstring("")) == NULL);
    /* An empty table finds nothing rather than reading the first element. */
    assert(janet_strbinsearch(small, 0, sizeof(SearchSmall), janet_cstring("alpha")) == NULL);

    bighit = janet_strbinsearch(big, 3, sizeof(SearchBig), janet_cstring("gamma"));
    assert(bighit != NULL && bighit == &big[2]);
}

static void test_safe_memcpy(void) {
    char dest[4] = {'w', 'x', 'y', 'z'};
    /* The whole point: a zero length with null pointers must not be handed to
     * memcpy, which is undefined even then. */
    safe_memcpy(NULL, NULL, 0);
    safe_memcpy(dest, NULL, 0);
    assert(dest[0] == 'w');
    safe_memcpy(dest, "ab", 2);
    assert(dest[0] == 'a' && dest[1] == 'b' && dest[2] == 'y');
}

/* The probe's three answers: the key's own bucket, the first tombstone, and a
 * never-used bucket. Only a C caller sees which one it got. */
static void test_dict_probe(void) {
    JanetTable *t = janet_table(8);
    const JanetKV *kv;
    Janet present = janet_ckeywordv("present");
    Janet absent = janet_ckeywordv("absent");
    int32_t i;

    janet_table_put(t, present, janet_wrap_integer(1));

    kv = janet_dict_find(t->data, t->capacity, present);
    assert(kv != NULL);
    assert(janet_equals(kv->key, present));
    assert(janet_unwrap_integer(kv->value) == 1);

    /* An absent key lands on a bucket whose key is nil -- that is what makes
     * it a place to put one. */
    kv = janet_dict_find(t->data, t->capacity, absent);
    assert(kv != NULL);
    assert(janet_checktype(kv->key, JANET_NIL));

    /* Deleting leaves a tombstone: key nil, value not nil. The probe must
     * scan *past* it to find a key that hashed to the same bucket, which is
     * what this checks by filling the table and deleting from the middle. */
    for (i = 0; i < 16; i++) {
        janet_table_put(t, janet_wrap_integer(i), janet_wrap_integer(i * 10));
    }
    for (i = 0; i < 16; i += 2) {
        janet_table_put(t, janet_wrap_integer(i), janet_wrap_nil());
    }
    for (i = 1; i < 16; i += 2) {
        kv = janet_dict_find(t->data, t->capacity, janet_wrap_integer(i));
        assert(kv != NULL);
        assert(janet_equals(kv->key, janet_wrap_integer(i)));
        assert(janet_unwrap_integer(kv->value) == i * 10);
    }

    /* A struct takes the same probe, and `janet_dictionary_get` is the
     * wrapper that turns "found a nil key" into nil. */
    {
        JanetKV *st = janet_struct_begin(2);
        JanetStruct s;
        janet_struct_put(st, janet_ckeywordv("a"), janet_wrap_integer(1));
        janet_struct_put(st, janet_ckeywordv("b"), janet_wrap_integer(2));
        s = janet_struct_end(st);
        assert(janet_unwrap_integer(janet_dictionary_get(s, janet_struct_capacity(s),
                                                         janet_ckeywordv("a"))) == 1);
        assert(janet_checktype(janet_dictionary_get(s, janet_struct_capacity(s),
                                                    janet_ckeywordv("z")), JANET_NIL));
    }

    /* `janet_dict_find_keyword` matches by bytes without interning, so a
     * keyword, a symbol and a string with the same bytes all hit the same
     * bucket. */
    {
        JanetTable *kt = janet_table(4);
        janet_table_put(kt, janet_ckeywordv("kw"), janet_wrap_integer(9));
        kv = janet_dict_find_keyword(kt->data, kt->capacity, (const uint8_t *)"kw", 2);
        assert(kv != NULL);
        assert(janet_unwrap_integer(kv->value) == 9);
        kv = janet_dict_find_keyword(kt->data, kt->capacity, (const uint8_t *)"nope", 4);
        assert(kv != NULL);
        assert(janet_checktype(kv->key, JANET_NIL));
        /* A prefix of a stored key must miss: the length is compared before
         * the bytes. */
        kv = janet_dict_find_keyword(kt->data, kt->capacity, (const uint8_t *)"k", 1);
        assert(kv != NULL);
        assert(janet_checktype(kv->key, JANET_NIL));
    }
}

static void test_dictionary_next(void) {
    JanetTable *t = janet_table(8);
    const JanetKV *kv = NULL;
    int32_t seen = 0;

    /* An empty dictionary ends immediately. */
    assert(janet_dictionary_next(t->data, t->capacity, NULL) == NULL);

    janet_table_put(t, janet_ckeywordv("a"), janet_wrap_integer(1));
    janet_table_put(t, janet_ckeywordv("b"), janet_wrap_integer(2));
    janet_table_put(t, janet_ckeywordv("c"), janet_wrap_integer(3));

    while ((kv = janet_dictionary_next(t->data, t->capacity, kv))) {
        assert(!janet_checktype(kv->key, JANET_NIL));
        seen++;
    }
    assert(seen == 3);

    /* A deleted entry is skipped: its key is nil even though its value is
     * not. */
    janet_table_put(t, janet_ckeywordv("b"), janet_wrap_nil());
    kv = NULL;
    seen = 0;
    while ((kv = janet_dictionary_next(t->data, t->capacity, kv))) seen++;
    assert(seen == 2);
}

static void test_sorted_keys(void) {
    JanetTable *t = janet_table(8);
    int32_t buffer[32];
    int32_t n;
    int32_t i;

    /* An empty dictionary sorts to nothing and writes nothing. */
    n = janet_sorted_keys(t->data, t->capacity, buffer);
    assert(n == 0);

    for (i = 5; i >= 0; i--) janet_table_put(t, janet_wrap_integer(i), janet_wrap_integer(i));
    n = janet_sorted_keys(t->data, t->capacity, buffer);
    assert(n == 6);
    /* The answer is bucket *indices*, in key order. */
    for (i = 0; i < n; i++) {
        assert(janet_unwrap_integer(t->data[buffer[i]].key) == i);
    }

    /* Deleted entries are not counted. */
    janet_table_put(t, janet_wrap_integer(3), janet_wrap_nil());
    n = janet_sorted_keys(t->data, t->capacity, buffer);
    assert(n == 5);
    for (i = 1; i < n; i++) {
        assert(janet_compare(t->data[buffer[i - 1]].key, t->data[buffer[i]].key) < 0);
    }
}

static void test_collection_hashes(void) {
    Janet items[3];
    JanetKV *kvs;
    JanetStruct st;
    JanetTuple tup;

    items[0] = janet_wrap_integer(1);
    items[1] = janet_wrap_integer(2);
    items[2] = janet_wrap_integer(3);

    /* The seed is 33, so a zero-length run hashes to it. That is the one value
     * of the two collection hashes a caller can predict. */
    assert(janet_array_calchash(items, 0) == 33);
    assert(janet_kv_calchash(NULL, 0) == 33);

    /* A tuple's stored hash is what janet_array_calchash computed. */
    tup = janet_tuple_n(items, 3);
    assert(janet_tuple_hash(tup) == janet_array_calchash(tup, 3));

    kvs = janet_struct_begin(1);
    janet_struct_put(kvs, janet_ckeywordv("k"), janet_wrap_integer(1));
    st = janet_struct_end(kvs);
    assert(janet_struct_hash(st) == janet_kv_calchash(st, janet_struct_capacity(st)));
}

void utils_contract(void) {
    static const uint8_t a[] = {'a'};
    static const uint8_t hello[] = {'h', 'e', 'l', 'l', 'o'};
    static const uint8_t embedded_nul[] = {'J', 'a', 'n', 'e', 't', 0, 'Z'};

    assert(janet_hash_mix(0, 0) == UINT32_C(0x53a3c667));
    assert(janet_hash_mix(1, 2) == UINT32_C(0x53a3d6f6));
    assert(janet_hash_mix(UINT32_MAX, UINT32_MAX) == UINT32_C(0x9c5c4a29));

#ifndef JANET_PRF
    assert(janet_string_calchash(NULL, 0) == 5381);
    assert(janet_string_calchash(a, sizeof(a)) == INT32_C(2136581281));
    assert(janet_string_calchash(hello, sizeof(hello)) == INT32_C(1719582043));
    assert(janet_string_calchash(embedded_nul, sizeof(embedded_nul)) == INT32_C(-1777808027));
#else
    {
        uint8_t key[JANET_HASH_KEY_SIZE] = {0, 1, 2, 3, 4, 5, 6, 7};
        janet_init_hash_key(key);
        assert(janet_string_calchash(a, sizeof(a)) == INT32_C(1520149057));
        assert(janet_string_calchash(hello, sizeof(hello)) == INT32_C(1601058579));
        assert(janet_string_calchash(embedded_nul, sizeof(embedded_nul)) == -INT32_C(1601329231));
    }
#endif

    assert(janet_tablen(-1) == 0);
    assert(janet_tablen(0) == 1);
    assert(janet_tablen(1) == 2);
    assert(janet_tablen(2) == 4);
    assert(janet_tablen(3) == 4);
    assert(janet_tablen(1024) == 2048);
    assert(janet_tablen(INT32_MAX) == INT32_MAX);

    janet_init();
    test_heads();
    test_cstrcmp();
    test_strbinsearch();
    test_safe_memcpy();
    test_dict_probe();
    test_dictionary_next();
    test_sorted_keys();
    test_collection_hashes();
    janet_deinit();

    printf("utils contract ok\n");
}
