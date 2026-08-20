/* Behavioral contract for hashing, equality and ordering over any Janet value.
 * Run against whichever implementation the build selected
 * (`-Dvalue-order=c` or the Zig default).
 *
 * These three functions are one contract rather than three, and the file is
 * organised that way. A hash table needs `janet_hash` and `janet_equals` to
 * agree; Part 6c's Robin Hood insert needs `janet_compare` to totally order
 * whatever `janet_hash` collides. So the last section runs a corpus of values
 * that covers every `JanetType` through all three at once and asserts the
 * relations between them, rather than checking each function in isolation and
 * hoping.
 *
 * Two properties get more attention than their size suggests.
 *
 * **The traversal is not recursion.** `janet_equals` and `janet_compare` walk
 * nested tuples and structs with an explicit stack in `janet_vm`, because a
 * literal nested a few thousand deep is a value a parser will hand you and a C
 * stack overflow is not a catchable error. A test that only compares shallow
 * values passes just as happily against a recursive implementation, so the
 * depth tests here use depths that would blow a native stack.
 *
 * **The stack is scratch, not state.** Both entry points reset it on the way
 * in and neither pops what it pushed, so a comparison that returns early
 * leaves nodes behind. That is only correct if the next comparison is
 * unaffected, which is asserted directly rather than assumed.
 *
 * What is deliberately not covered: `janet_next` and the indexed and keyed
 * accessors below it in `value.c`, which are still C and move in Part 7b.
 */

#include <assert.h>
#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "features.h"
#include <janet.h>

#include "support.h"
#include "state.h"
#include "gc.h"
#include "util.h"

/* ------------------------------------------------------------------ helpers */

static Janet kw(const char *name) {
    return janet_ckeywordv(name);
}

static Janet sym(const char *name) {
    return janet_csymbolv(name);
}

static Janet str(const char *s) {
    return janet_cstringv(s);
}

static Janet num(double d) {
    return janet_wrap_number(d);
}

static Janet intv(int32_t i) {
    return janet_wrap_integer(i);
}

/* A tuple from an array of values, paren-constructed unless `bracket`. */
static Janet mktuple(const Janet *items, int32_t n, int bracket) {
    Janet *t = janet_tuple_begin(n);
    for (int32_t i = 0; i < n; i++) t[i] = items[i];
    if (bracket) janet_tuple_flag(t) |= JANET_TUPLE_FLAG_BRACKETCTOR;
    return janet_wrap_tuple(janet_tuple_end(t));
}

/* A struct from alternating key/value pairs, with an optional prototype. */
static Janet mkstruct(const Janet *kvs, int32_t pairs, const JanetKV *proto) {
    JanetKV *st = janet_struct_begin(pairs);
    for (int32_t i = 0; i < pairs; i++) {
        janet_struct_put(st, kvs[2 * i], kvs[2 * i + 1]);
    }
    if (proto != NULL) janet_struct_proto(st) = proto;
    return janet_wrap_struct(janet_struct_end(st));
}

/* Depth of the traversal stack in nodes, as the two entry points see it. Zero
 * when nothing has ever been pushed, because the base slot is never used. */
static ptrdiff_t stack_depth(void) {
    if (janet_vm.traversal_base == NULL) return 0;
    return janet_vm.traversal - janet_vm.traversal_base;
}

/* ------------------------------------------------------- abstract fixtures */

/* Three abstract types, differing only in which callbacks they supply, so that
 * each branch of `janet_compare_abstract` and of the abstract arm of
 * `janet_hash` is reached by a type that reaches no other. */

typedef struct {
    int32_t key;
} Cell;

static int32_t cell_hash(void *p, size_t len) {
    (void) len;
    return ((Cell *)p)->key;
}

static int cell_compare(void *lhs, void *rhs) {
    int32_t a = ((Cell *)lhs)->key;
    int32_t b = ((Cell *)rhs)->key;
    if (a == b) return 0;
    return a < b ? -1 : 1;
}

/* Designated initializers throughout: `JanetAbstractType` has fifteen members
 * and `compare` sits between `tostring` and `hash`, so a positional table is a
 * silent way to install a comparator as a `next` callback. */

/* Supplies both callbacks. */
static const JanetAbstractType cell_type = {
    .name = "value-order/cell",
    .compare = cell_compare,
    .hash = cell_hash
};

/* Supplies neither, so it falls back to pointer identity for both. */
static const JanetAbstractType bare_type = {
    .name = "value-order/bare"
};

/* A second callback-less type, so that two abstracts of *different* types can
 * be ordered without either type's `compare` being consulted. */
static const JanetAbstractType other_type = {
    .name = "value-order/other"
};

static Janet mkcell(int32_t key) {
    Cell *cell = janet_abstract(CONTRACT_AT(cell_type), sizeof(Cell));
    cell->key = key;
    return janet_wrap_abstract(cell);
}

static Janet mkbare(const JanetAbstractType *at) {
    Cell *cell = janet_abstract(at, sizeof(Cell));
    cell->key = 0;
    return janet_wrap_abstract(cell);
}

/* ------------------------------------------------------------------ hashing */

/* The constants, which nothing else pins. `janet_hash` of nil is the identity
 * of an empty bucket in every dictionary in the runtime, and `false` hashing
 * to zero is what makes `false` the one key a zero-capacity table can be
 * looked up with -- see `FOUND.md`. */
static void test_hash_of_the_atoms(void) {
    assert(janet_hash(janet_wrap_nil()) == 0);
    assert(janet_hash(janet_wrap_false()) == 0);
    assert(janet_hash(janet_wrap_true()) == 1);
}

/* Hashing is a function: the same value hashes the same every time, and two
 * separately built values that are `=` hash alike. The second half is the
 * property every dictionary in the runtime is built on. */
static void test_hash_agrees_with_equality(void) {
    Janet items[3] = { intv(1), kw("a"), str("s") };
    Janet a = mktuple(items, 3, 0);
    Janet b = mktuple(items, 3, 0);
    assert(!janet_equals(a, b) || janet_hash(a) == janet_hash(b));
    assert(janet_equals(a, b));
    assert(janet_hash(a) == janet_hash(a));
    assert(janet_hash(a) == janet_hash(b));

    Janet kvs[4] = { kw("x"), intv(1), kw("y"), intv(2) };
    Janet rev[4] = { kw("y"), intv(2), kw("x"), intv(1) };
    Janet s1 = mkstruct(kvs, 2, NULL);
    Janet s2 = mkstruct(rev, 2, NULL);
    assert(janet_equals(s1, s2));
    assert(janet_hash(s1) == janet_hash(s2));
}

/* All three string-like types hash their bytes and nothing else, so a keyword,
 * a symbol and a string spelled alike collide while comparing unequal. This is
 * not an accident to be tidied up: it is exactly the collision that makes the
 * `janet_compare` tiebreak in `janet_struct_put_ext` load-bearing, and
 * `test/struct_table.c` has the other half of the story. */
static void test_string_likes_share_one_hash(void) {
    assert(janet_hash(kw("tie")) == janet_hash(str("tie")));
    assert(janet_hash(sym("tie")) == janet_hash(str("tie")));
    assert(!janet_equals(kw("tie"), str("tie")));
    assert(!janet_equals(sym("tie"), str("tie")));
    assert(!janet_equals(kw("tie"), sym("tie")));
}

/* Negative zero is normalized before the number is mixed, so that `0.0` and
 * `-0.0` -- which are `=` -- do not land in different buckets. The `+= 0.0`
 * that does it is one statement and deleting it breaks nothing else. */
static void test_hash_normalizes_negative_zero(void) {
    assert(janet_equals(num(0.0), num(-0.0)));
    assert(janet_hash(num(0.0)) == janet_hash(num(-0.0)));
    /* And the mixing is not a no-op: neighbouring doubles must not share a
     * hash, or the assertion above would hold for a `return 0`. */
    assert(janet_hash(num(0.0)) != janet_hash(num(1.0)));
    assert(janet_hash(num(1.0)) != janet_hash(num(2.0)));
    assert(janet_hash(num(1.0)) != janet_hash(num(1.0000000000000002)));
}

/* The exact numbers, which nothing else pins and which are not free to change.
 * A struct's bucket array is part of the language contract -- `{1 2 3 4}` and
 * `{3 4 1 2}` are the same value because they lay out identically -- and the
 * layout is a function of `janet_hash`. So the hash of a double is observable
 * through every struct with a numeric key, and it does not vary with the
 * target or with `-Dprf`: the double's bits are fixed, `murmur64` is fixed,
 * and the result is the *high* word of the mix. Taking the low word instead
 * would be just as good a hash and a different language. */
static void test_exact_number_hashes(void) {
    assert(janet_hash(num(1.0)) == -1365709855);
    assert(janet_hash(num(2.0)) == 1700046601);
    assert(janet_hash(num(-1.0)) == -1784919109);
    assert(janet_hash(num(1.5)) == -2007118713);
    assert(janet_hash(num(1e300)) == -701392662);
    /* Zero is the fixed point of the mixer -- every step of `murmur64` maps
     * zero to zero -- so `0` hashes to the same 0 that `nil` and `false` do.
     * Not a defect, but it is the reason `janet_hash` of a number cannot be
     * assumed nonzero. */
    assert(janet_hash(num(0.0)) == 0);
}

/* An integer and the double that equals it are the same Janet number, so they
 * must hash alike -- there is no separate integer hash to get wrong. */
static void test_hash_of_integers_and_doubles_agree(void) {
    assert(janet_equals(intv(7), num(7.0)));
    assert(janet_hash(intv(7)) == janet_hash(num(7.0)));
}

/* A bracket-constructed tuple hashes to one more than the paren-constructed
 * tuple with the same contents, and compares unequal to it. The flag is the
 * only case in the language where something other than contents participates
 * in a hash. */
static void test_bracket_tuples_hash_and_compare_apart(void) {
    Janet items[2] = { intv(1), intv(2) };
    Janet paren = mktuple(items, 2, 0);
    Janet bracket = mktuple(items, 2, 1);
    assert(!janet_equals(paren, bracket));
    assert((uint32_t) janet_hash(bracket) == (uint32_t) janet_hash(paren) + 1u);
    /* And the difference is a *hash* difference, not a length or content one:
     * the stored head hashes are identical. */
    assert(janet_tuple_hash(janet_unwrap_tuple(paren)) ==
           janet_tuple_hash(janet_unwrap_tuple(bracket)));
}

/* The stored hash is returned rather than recomputed, for every type that has
 * one. Asserted by mutating the head after construction: a recomputing
 * implementation would ignore the change. */
static void test_hash_reads_the_stored_head(void) {
    Janet items[1] = { intv(1) };
    Janet t = mktuple(items, 1, 0);
    const Janet *tup = janet_unwrap_tuple(t);
    janet_tuple_head(tup)->hash = 0x5eed;
    assert(janet_hash(t) == 0x5eed);

    Janet kvs[2] = { kw("k"), intv(1) };
    Janet s = mkstruct(kvs, 1, NULL);
    const JanetKV *st = janet_unwrap_struct(s);
    janet_struct_head(st)->hash = 0x5eee;
    assert(janet_hash(s) == 0x5eee);

    Janet v = str("abc");
    janet_string_head(janet_unwrap_string(v))->hash = 0x5eef;
    assert(janet_hash(v) == 0x5eef);
}

/* An abstract type's `hash` callback is used when it has one, is passed the
 * abstract's own size, and is not consulted when it does not. */
static void test_abstract_hash_callback(void) {
    assert(janet_hash(mkcell(1234)) == 1234);
    assert(janet_hash(mkcell(-1)) == -1);

    /* Without a callback the pointer is hashed, so the same instance is stable
     * and two instances are (overwhelmingly) not equal. Two draws rather than
     * one, because a constant-returning implementation passes with one. */
    Janet b1 = mkbare(CONTRACT_AT(bare_type));
    Janet b2 = mkbare(CONTRACT_AT(bare_type));
    assert(janet_hash(b1) == janet_hash(b1));
    assert(janet_hash(b1) != janet_hash(b2));
}

/* `murmur64`, restated. Not shared with the implementation on purpose: the
 * point of the test below is that the mixer and the word it takes are what
 * they are, and a test that called the same function could not say so. */
static uint64_t murmur64_ref(uint64_t h) {
    h ^= h >> 33;
    h *= 0xff51afd7ed558ccdULL;
    h ^= h >> 33;
    h *= 0xc4ceb9fe1a85ec53ULL;
    h ^= h >> 33;
    return h;
}

/* The pointer hash is the *high* word of the mix of the payload word, which
 * nothing else can pin: a pointer is not a constant, so this is the only way
 * to say which half of the mix is taken. Taking the low word would be just as
 * good a hash and a different language, for the same reason the exact number
 * hashes above matter -- a struct keyed by anything that lands here lays out
 * accordingly. `janet_u64` is the same macro `janet_hash` uses and spells a
 * different field per value representation. */
static void test_pointer_hash_is_the_high_word(void) {
    if (sizeof(double) != sizeof(void *)) return;
    JanetTable *t = janet_table(4);
    Janet v = janet_wrap_table(t);
    uint64_t mixed = murmur64_ref(janet_u64(v));
    assert(janet_hash(v) == (int32_t)(uint32_t)(mixed >> 32));

    JanetArray *a = janet_array(4);
    Janet w = janet_wrap_array(a);
    assert(janet_hash(w) == (int32_t)(uint32_t)(murmur64_ref(janet_u64(w)) >> 32));
}

/* The pointer fallback is a fallback for every remaining type, not just for
 * abstracts, and it is stable per value. */
static void test_pointer_hash_is_stable(void) {
    JanetTable *t = janet_table(4);
    JanetArray *a = janet_array(4);
    JanetBuffer *b = janet_buffer(4);
    assert(janet_hash(janet_wrap_table(t)) == janet_hash(janet_wrap_table(t)));
    assert(janet_hash(janet_wrap_array(a)) == janet_hash(janet_wrap_array(a)));
    assert(janet_hash(janet_wrap_buffer(b)) == janet_hash(janet_wrap_buffer(b)));
    assert(janet_hash(janet_wrap_table(t)) != janet_hash(janet_wrap_array(a)));
}

/* ----------------------------------------------------------------- equality */

static void test_equality_of_atoms(void) {
    assert(janet_equals(janet_wrap_nil(), janet_wrap_nil()));
    assert(janet_equals(janet_wrap_true(), janet_wrap_true()));
    assert(janet_equals(janet_wrap_false(), janet_wrap_false()));
    assert(!janet_equals(janet_wrap_true(), janet_wrap_false()));
    /* Different types are never equal, whatever their payloads look like. */
    assert(!janet_equals(janet_wrap_nil(), janet_wrap_false()));
    assert(!janet_equals(intv(0), janet_wrap_false()));
    assert(!janet_equals(kw("a"), str("a")));
}

static void test_equality_of_numbers(void) {
    assert(janet_equals(num(1.5), num(1.5)));
    assert(janet_equals(num(0.0), num(-0.0)));
    assert(!janet_equals(num(1.5), num(2.5)));
    /* NaN is not equal to itself, which is the one place equality is not
     * reflexive and the reason a NaN cannot be a table key. */
    assert(!janet_equals(num(NAN), num(NAN)));
    assert(janet_equals(num(INFINITY), num(INFINITY)));
    assert(!janet_equals(num(INFINITY), num(-INFINITY)));
}

/* Strings compare by content and are not interned, so two distinct allocations
 * with the same bytes are equal. Symbols and keywords *are* interned, so the
 * same spelling is the same pointer -- the assertion is that both routes end
 * at the same answer. */
static void test_equality_of_string_likes(void) {
    Janet s1 = str("hello");
    Janet s2 = str("hello");
    assert(janet_unwrap_string(s1) != janet_unwrap_string(s2));
    assert(janet_equals(s1, s2));
    assert(!janet_equals(s1, str("hellp")));
    assert(!janet_equals(s1, str("hell")));

    assert(janet_unwrap_symbol(sym("q")) == janet_unwrap_symbol(sym("q")));
    assert(janet_equals(sym("q"), sym("q")));
    assert(!janet_equals(sym("q"), sym("r")));
    assert(janet_equals(kw("q"), kw("q")));
    assert(!janet_equals(kw("q"), kw("r")));
}

/* Mutable containers are equal only to themselves. */
static void test_equality_of_mutable_containers(void) {
    JanetTable *t1 = janet_table(4);
    JanetTable *t2 = janet_table(4);
    janet_table_put(t1, kw("a"), intv(1));
    janet_table_put(t2, kw("a"), intv(1));
    assert(janet_equals(janet_wrap_table(t1), janet_wrap_table(t1)));
    assert(!janet_equals(janet_wrap_table(t1), janet_wrap_table(t2)));

    JanetArray *a1 = janet_array(4);
    JanetArray *a2 = janet_array(4);
    janet_array_push(a1, intv(1));
    janet_array_push(a2, intv(1));
    assert(janet_equals(janet_wrap_array(a1), janet_wrap_array(a1)));
    assert(!janet_equals(janet_wrap_array(a1), janet_wrap_array(a2)));
}

/* Tuple equality traverses, and each of the four cheap rejections in front of
 * the traversal is reached by a case that reaches no other. */
static void test_equality_of_tuples(void) {
    Janet items[3] = { intv(1), kw("k"), str("s") };
    Janet other[3] = { intv(1), kw("k"), str("t") };
    Janet a = mktuple(items, 3, 0);
    Janet b = mktuple(items, 3, 0);
    assert(janet_unwrap_tuple(a) != janet_unwrap_tuple(b));
    assert(janet_equals(a, b));
    assert(!janet_equals(a, mktuple(other, 3, 0)));
    /* Shorter, so the length rejection fires. */
    assert(!janet_equals(a, mktuple(items, 2, 0)));
    /* Same contents, different constructor, so the flag rejection fires. */
    assert(!janet_equals(a, mktuple(items, 3, 1)));
    /* Identity short-circuits before any of them. */
    assert(janet_equals(a, a));
}

/* A value is equal to itself even when it contains something that is not equal
 * to itself. `janet_equals` short-circuits on pointer identity for a tuple
 * before it looks at any element, so a tuple holding a NaN is `=` to itself
 * and not `=` to a separately built tuple with the same bits.
 *
 * Pinned because it is the only observable consequence of that short-circuit
 * -- for every other value the two routes agree -- and because dropping it
 * would silently make `(= x x)` false for a value a program is holding. */
static void test_a_tuple_holding_nan_equals_itself(void) {
    Janet items[1] = { num(NAN) };
    Janet a = mktuple(items, 1, 0);
    janet_gcroot(a);
    Janet b = mktuple(items, 1, 0);
    janet_gcroot(b);

    assert(janet_equals(a, a));
    /* Same length, same stored hash -- the NaN bits are the same bits -- so
     * this one reaches the traversal, and the traversal finds a NaN. */
    assert(janet_tuple_hash(janet_unwrap_tuple(a)) == janet_tuple_hash(janet_unwrap_tuple(b)));
    assert(!janet_equals(a, b));

    janet_gcunroot(a);
    janet_gcunroot(b);
}

/* Struct equality is layout equality, which Part 6c's Robin Hood insert exists
 * to make order-independent, plus a prototype check that is *presence* only --
 * two structs whose prototypes differ are still compared through the
 * traversal, not rejected up front. */
static void test_equality_of_structs(void) {
    Janet kvs[4] = { kw("x"), intv(1), kw("y"), intv(2) };
    Janet rev[4] = { kw("y"), intv(2), kw("x"), intv(1) };
    Janet diff[4] = { kw("x"), intv(1), kw("y"), intv(3) };
    assert(janet_equals(mkstruct(kvs, 2, NULL), mkstruct(rev, 2, NULL)));
    assert(!janet_equals(mkstruct(kvs, 2, NULL), mkstruct(diff, 2, NULL)));
    assert(!janet_equals(mkstruct(kvs, 2, NULL), mkstruct(kvs, 1, NULL)));

    Janet pk[2] = { kw("p"), intv(9) };
    const JanetKV *proto = janet_unwrap_struct(mkstruct(pk, 1, NULL));
    Janet with = mkstruct(kvs, 2, proto);
    Janet without = mkstruct(kvs, 2, NULL);
    /* One has a prototype and the other does not: rejected before traversing. */
    assert(!janet_equals(with, without));
    assert(!janet_equals(without, with));
    /* Both have one, and it is the same one. */
    assert(janet_equals(with, mkstruct(rev, 2, proto)));
    /* Both have one and they differ, which only the traversal can tell. */
    Janet qk[2] = { kw("q"), intv(9) };
    const JanetKV *other_proto = janet_unwrap_struct(mkstruct(qk, 1, NULL));
    assert(!janet_equals(with, mkstruct(kvs, 2, other_proto)));
}

/* Three checks in `janet_equals` sit behind the stored-hash comparison and are
 * unreachable while the hashes disagree -- which, for values that differ, they
 * essentially always do. They are not dead code: a 32-bit hash collides, and
 * when it does these are what stop the traversal from reading a bucket array
 * off the end of itself or from reporting two different values equal.
 *
 * A collision cannot be constructed to order, so it is forged: the head hash
 * of one value is overwritten after construction, which is exactly the state a
 * collision produces. Nothing else in the file does this, and these values are
 * used for nothing afterwards. */
static void test_the_checks_behind_the_hash(void) {
    /* Tuple length. Two identical two-element tuples, one of which claims to
     * be one element long. Without the length check the traversal compares
     * element zero, finds it equal, runs out of the shorter side, and -- with
     * `index2` clear, which is what `janet_equals` pushes -- reports that
     * there is nothing more to compare. The answer would be "equal". */
    Janet pair[2] = { intv(1), intv(2) };
    Janet t1 = mktuple(pair, 2, 0);
    janet_gcroot(t1);
    Janet t2 = mktuple(pair, 2, 0);
    janet_gcroot(t2);
    assert(janet_equals(t1, t2));
    janet_tuple_head(janet_unwrap_tuple(t2))->length = 1;
    assert(janet_tuple_hash(janet_unwrap_tuple(t1)) == janet_tuple_hash(janet_unwrap_tuple(t2)));
    assert(!janet_equals(t1, t2));
    janet_gcunroot(t1);
    janet_gcunroot(t2);

    /* Struct length. Same shape, and it matters more here: a struct's
     * capacity is a function of its length, and `traversal_next` bounds the
     * bucket walk by the *left* side's capacity while indexing both. Two
     * structs of different length therefore have different capacities, and
     * comparing them bucket for bucket would read past the end of the shorter
     * one. The length check is what makes that unreachable. */
    Janet kvs[2] = { kw("a"), intv(1) };
    Janet s1 = mkstruct(kvs, 1, NULL);
    janet_gcroot(s1);
    Janet s2 = mkstruct(kvs, 1, NULL);
    janet_gcroot(s2);
    assert(janet_equals(s1, s2));
    janet_struct_head(janet_unwrap_struct(s2))->length = 2;
    assert(janet_struct_hash(janet_unwrap_struct(s1)) == janet_struct_hash(janet_unwrap_struct(s2)));
    assert(!janet_equals(s1, s2));
    janet_gcunroot(s1);
    janet_gcunroot(s2);

    /* Struct prototype presence. `janet_struct_end` folds the prototype
     * pointer into the hash, so in practice the hash rejects this pair before
     * the presence check is consulted; forcing the hashes together is the only
     * way to reach it. Without it the traversal walks the buckets, finds them
     * identical, reaches the prototype hop, and the hop's `return 3` ends
     * `janet_equals`'s loop the same way a completed traversal would -- so the
     * answer would be "equal". */
    Janet pk[2] = { kw("p"), intv(1) };
    Janet proto = mkstruct(pk, 1, NULL);
    janet_gcroot(proto);
    Janet with = mkstruct(kvs, 1, janet_unwrap_struct(proto));
    janet_gcroot(with);
    Janet without = mkstruct(kvs, 1, NULL);
    janet_gcroot(without);
    assert(janet_struct_hash(janet_unwrap_struct(with)) !=
           janet_struct_hash(janet_unwrap_struct(without)));
    janet_struct_head(janet_unwrap_struct(without))->hash =
        janet_struct_hash(janet_unwrap_struct(with));
    assert(janet_struct_length(janet_unwrap_struct(with)) ==
           janet_struct_length(janet_unwrap_struct(without)));
    assert(!janet_equals(with, without));
    assert(!janet_equals(without, with));
    janet_gcunroot(proto);
    janet_gcunroot(with);
    janet_gcunroot(without);
}

/* `janet_compare` orders two structs by capacity, then by stored hash, and
 * only then by contents. Each of the first two is isolated by forcing the
 * later criteria to disagree with it: an implementation that dropped either
 * would still order most structs plausibly and would no longer be reproducing
 * this one. */
static void test_the_struct_ordering_criteria_are_in_order(void) {
    Janet one[2] = { kw("a"), intv(1) };
    Janet two[4] = { kw("a"), intv(1), kw("b"), intv(2) };
    Janet small = mkstruct(one, 1, NULL);
    janet_gcroot(small);
    Janet large = mkstruct(two, 2, NULL);
    janet_gcroot(large);
    assert(janet_struct_capacity(janet_unwrap_struct(small)) <
           janet_struct_capacity(janet_unwrap_struct(large)));

    /* Capacity beats hash: the larger struct is given the smaller hash. */
    janet_struct_head(janet_unwrap_struct(small))->hash = 100;
    janet_struct_head(janet_unwrap_struct(large))->hash = 1;
    assert(janet_compare(small, large) == -1);
    assert(janet_compare(large, small) == 1);
    janet_gcunroot(small);
    janet_gcunroot(large);

    /* Hash beats contents: two structs of equal capacity whose hashes are
     * forced to the opposite order from their values. */
    Janet lo[2] = { kw("a"), intv(1) };
    Janet hi[2] = { kw("a"), intv(2) };
    Janet a = mkstruct(lo, 1, NULL);
    janet_gcroot(a);
    Janet b = mkstruct(hi, 1, NULL);
    janet_gcroot(b);
    assert(janet_struct_capacity(janet_unwrap_struct(a)) ==
           janet_struct_capacity(janet_unwrap_struct(b)));
    janet_struct_head(janet_unwrap_struct(a))->hash = 9;
    janet_struct_head(janet_unwrap_struct(b))->hash = 3;
    assert(janet_compare(a, b) == 1);
    assert(janet_compare(b, a) == -1);
    janet_gcunroot(a);
    janet_gcunroot(b);

    /* And below both of them, the traversal, which is the only thing that
     * looks at a struct's contents. Reaching it needs everything above it to
     * tie: same capacity, same key, and the hash forced to agree. Then the
     * *values* decide, which is the only case in the file where a struct's
     * value slot is compared at all -- every other pair of structs is settled
     * by the stored hash long before. */
    Janet c1 = mkstruct(lo, 1, NULL);
    janet_gcroot(c1);
    Janet c2 = mkstruct(hi, 1, NULL);
    janet_gcroot(c2);
    janet_struct_head(janet_unwrap_struct(c2))->hash =
        janet_struct_hash(janet_unwrap_struct(c1));
    assert(janet_equals(janet_struct_get(janet_unwrap_struct(c1), kw("a")), intv(1)));
    assert(janet_equals(janet_struct_get(janet_unwrap_struct(c2), kw("a")), intv(2)));
    assert(janet_compare(c1, c2) == -1);
    assert(janet_compare(c2, c1) == 1);
    /* `janet_equals` reaches it on the same terms and for the same reason. */
    assert(!janet_equals(c1, c2));
    janet_gcunroot(c1);
    janet_gcunroot(c2);
}

/* Abstract equality is `compare == 0`, because the abstract type interface has
 * no equality callback at all: a third-party type supplies an ordering and
 * equality is defined as its zero. So two distinct instances that compare
 * equal *are* equal, which is a real observable difference from pointer
 * identity and the only way to see the callback being used. */
static void test_equality_of_abstracts(void) {
    Janet a = mkcell(5);
    Janet b = mkcell(5);
    Janet c = mkcell(6);
    assert(janet_unwrap_abstract(a) != janet_unwrap_abstract(b));
    assert(janet_equals(a, b));
    assert(!janet_equals(a, c));

    /* Without a callback, only identity. */
    Janet p = mkbare(CONTRACT_AT(bare_type));
    Janet q = mkbare(CONTRACT_AT(bare_type));
    assert(janet_equals(p, p));
    assert(!janet_equals(p, q));

    /* Different abstract types are never equal even with equal payloads. */
    Janet r = mkbare(CONTRACT_AT(other_type));
    assert(!janet_equals(p, r));
}

/* ----------------------------------------------------------------- ordering */

/* Across types the order is the `JanetType` enumeration, which makes it
 * arbitrary and stable -- both of which the sort in the standard library
 * depends on. */
static void test_order_across_types(void) {
    /* In enumeration order, which is *not* the order a reader would guess:
     * `JANET_NUMBER` is zero and `JANET_NIL` follows it. */
    Janet ordered[6] = {
        num(0.0), janet_wrap_nil(), janet_wrap_false(),
        str("s"), sym("s"), kw("s")
    };
    assert(JANET_NUMBER < JANET_NIL);
    assert(JANET_NIL < JANET_BOOLEAN);
    assert(JANET_BOOLEAN < JANET_STRING);
    for (int i = 0; i < 6; i++) {
        for (int j = 0; j < 6; j++) {
            int expect = (i == j) ? 0 : (i < j ? -1 : 1);
            if (i != j) assert(janet_compare(ordered[i], ordered[j]) == expect);
        }
    }
}

static void test_order_of_numbers(void) {
    assert(janet_compare(num(1.0), num(2.0)) == -1);
    assert(janet_compare(num(2.0), num(1.0)) == 1);
    assert(janet_compare(num(1.0), num(1.0)) == 0);
    assert(janet_compare(num(-0.0), num(0.0)) == 0);
    assert(janet_compare(num(-INFINITY), num(INFINITY)) == -1);
    /* NaN is not orderable and the C says so in a comment: both directions
     * return 1, so `janet_compare` is not antisymmetric on NaN. Pinned
     * because it is the behaviour, not because it is desirable. */
    assert(janet_compare(num(NAN), num(1.0)) == 1);
    assert(janet_compare(num(1.0), num(NAN)) == 1);
    assert(janet_compare(num(NAN), num(NAN)) == 1);
}

static void test_order_of_booleans(void) {
    assert(janet_compare(janet_wrap_false(), janet_wrap_true()) == -1);
    assert(janet_compare(janet_wrap_true(), janet_wrap_false()) == 1);
    assert(janet_compare(janet_wrap_true(), janet_wrap_true()) == 0);
}

/* Strings order lexicographically by byte, with a shorter prefix first, and
 * the same routine orders symbols and keywords. */
static void test_order_of_string_likes(void) {
    assert(janet_compare(str("a"), str("b")) < 0);
    assert(janet_compare(str("b"), str("a")) > 0);
    assert(janet_compare(str("ab"), str("abc")) < 0);
    assert(janet_compare(str("abc"), str("ab")) > 0);
    assert(janet_compare(str("abc"), str("abc")) == 0);
    assert(janet_compare(sym("a"), sym("b")) < 0);
    assert(janet_compare(kw("a"), kw("b")) < 0);
}

/* Tuples order element-wise, and a prefix sorts before its extension -- which
 * the traversal decides, not a length check up front. The bracket flag is
 * checked before any element and outranks all of them. */
static void test_order_of_tuples(void) {
    Janet a[2] = { intv(1), intv(2) };
    Janet b[3] = { intv(1), intv(2), intv(3) };
    Janet cc[2] = { intv(1), intv(3) };
    Janet big[2] = { intv(9), intv(0) };
    assert(janet_compare(mktuple(a, 2, 0), mktuple(b, 3, 0)) == -1);
    assert(janet_compare(mktuple(b, 3, 0), mktuple(a, 2, 0)) == 1);
    assert(janet_compare(mktuple(a, 2, 0), mktuple(cc, 2, 0)) == -1);
    assert(janet_compare(mktuple(a, 2, 0), mktuple(a, 2, 0)) == 0);
    /* Element-wise beats length: a longer tuple whose first element is larger
     * still sorts after. And a shorter one whose first element is larger sorts
     * after too, which is the same claim from the other side. */
    assert(janet_compare(mktuple(big, 2, 0), mktuple(b, 3, 0)) == 1);

    /* The bracket flag outranks the contents in both directions. */
    assert(janet_compare(mktuple(a, 2, 1), mktuple(b, 3, 0)) == 1);
    assert(janet_compare(mktuple(b, 3, 0), mktuple(a, 2, 1)) == -1);
}

/* Structs order by capacity, then by hash, and only then element-wise. The
 * first two are asserted with pairs that isolate them, because an
 * implementation that dropped either would still order most structs
 * "correctly" and would silently stop being a total order. */
static void test_order_of_structs(void) {
    Janet one[2] = { kw("a"), intv(1) };
    Janet two[4] = { kw("a"), intv(1), kw("b"), intv(2) };
    Janet s1 = mkstruct(one, 1, NULL);
    Janet s2 = mkstruct(two, 2, NULL);
    assert(janet_struct_capacity(janet_unwrap_struct(s1)) <
           janet_struct_capacity(janet_unwrap_struct(s2)));
    assert(janet_compare(s1, s2) == -1);
    assert(janet_compare(s2, s1) == 1);
    assert(janet_compare(s1, s1) == 0);
    assert(janet_compare(s1, mkstruct(one, 1, NULL)) == 0);

    /* Same capacity, different contents: the hash decides, and whichever way
     * it decides it must be antisymmetric and it must agree with equality. */
    Janet alt[2] = { kw("z"), intv(1) };
    Janet s3 = mkstruct(alt, 1, NULL);
    assert(janet_struct_capacity(janet_unwrap_struct(s1)) ==
           janet_struct_capacity(janet_unwrap_struct(s3)));
    assert(!janet_equals(s1, s3));
    int fwd = janet_compare(s1, s3);
    int rev = janet_compare(s3, s1);
    assert(fwd != 0 && fwd == -rev);
}

/* A struct with a prototype sorts after one without, and two with different
 * prototypes are decided by comparing the prototypes. Both of these are the
 * prototype hop at the bottom of `traversal_next`, which is the only place the
 * traversal replaces a stack node instead of pushing one. */
static void test_order_of_struct_prototypes(void) {
    Janet kvs[2] = { kw("a"), intv(1) };
    Janet pk[2] = { kw("p"), intv(1) };
    Janet qk[2] = { kw("p"), intv(2) };
    const JanetKV *p = janet_unwrap_struct(mkstruct(pk, 1, NULL));
    const JanetKV *q = janet_unwrap_struct(mkstruct(qk, 1, NULL));
    Janet bare = mkstruct(kvs, 1, NULL);
    Janet with_p = mkstruct(kvs, 1, p);
    Janet with_q = mkstruct(kvs, 1, q);

    assert(janet_compare(with_p, bare) == 1);
    assert(janet_compare(bare, with_p) == -1);
    assert(janet_compare(with_p, mkstruct(kvs, 1, p)) == 0);

    int fwd = janet_compare(with_p, with_q);
    int rev = janet_compare(with_q, with_p);
    assert(fwd != 0 && fwd == -rev);
    assert(!janet_equals(with_p, with_q));
}

/* Mutable containers order by pointer, which is arbitrary but must be a
 * consistent total order within a run. */
static void test_order_of_mutable_containers(void) {
    JanetTable *t1 = janet_table(4);
    JanetTable *t2 = janet_table(4);
    Janet a = janet_wrap_table(t1);
    Janet b = janet_wrap_table(t2);
    assert(janet_compare(a, a) == 0);
    int fwd = janet_compare(a, b);
    assert(fwd != 0 && fwd == -janet_compare(b, a));
    assert(janet_compare(a, b) == fwd);
    /* And the direction, not merely its consistency: the larger address sorts
     * after. Asserted absolutely because "some stable order" is satisfied by
     * the reverse of this one, and the reverse is a different language. */
    assert(fwd == ((void *) t1 > (void *) t2 ? 1 : -1));
}

/* Abstracts: identity first, then the abstract *type* pointer when the types
 * differ -- which is what lets two unrelated abstract types be sorted into one
 * array without either knowing about the other -- and only then the type's own
 * `compare`. */
static void test_order_of_abstracts(void) {
    Janet a = mkcell(1);
    Janet b = mkcell(2);
    assert(janet_compare(a, b) == -1);
    assert(janet_compare(b, a) == 1);
    assert(janet_compare(a, a) == 0);
    assert(janet_compare(a, mkcell(1)) == 0);

    /* No callback: pointer order, consistent both ways and in that direction. */
    Janet p = mkbare(CONTRACT_AT(bare_type));
    Janet q = mkbare(CONTRACT_AT(bare_type));
    int fwd = janet_compare(p, q);
    assert(fwd != 0 && fwd == -janet_compare(q, p));
    assert(fwd == (janet_unwrap_abstract(p) > janet_unwrap_abstract(q) ? 1 : -1));

    /* Different types: decided by the type pointers, before either type's
     * callback could be consulted -- `cell_type` has one and it is not used. */
    Janet r = mkbare(CONTRACT_AT(other_type));
    int cross = janet_compare(p, r);
    assert(cross != 0 && cross == -janet_compare(r, p));
    int expect = (CONTRACT_AT(bare_type) > CONTRACT_AT(other_type)) ? 1 : -1;
    assert(cross == expect);

    assert(janet_compare(a, p) == ((CONTRACT_AT(cell_type) > CONTRACT_AT(bare_type)) ? 1 : -1));
}

/* --------------------------------------------------------------- traversal */

/* Build a tuple nested `depth` levels deep: (0 (1 (2 ... leaf))).
 *
 * Twenty thousand levels is megabytes of allocation and the collector will run
 * part way through, so the accumulator is rooted across every allocation that
 * could trigger one. A value held only in a C local is not reachable, and each
 * level here is kept alive solely by the level above it -- so losing the
 * accumulator for the length of one `janet_tuple_begin` would free the entire
 * chain built so far. The successor is rooted before its predecessor is
 * released, never the other way round.
 *
 * The result is left rooted and the caller unroots it. */
static Janet nest_tuples(int32_t depth, Janet leaf) {
    Janet acc = leaf;
    janet_gcroot(acc);
    for (int32_t i = 0; i < depth; i++) {
        Janet items[2] = { intv(i), acc };
        Janet next = mktuple(items, 2, 0);
        janet_gcroot(next);
        janet_gcunroot(acc);
        acc = next;
    }
    return acc;
}

/* Build a struct nested `depth` levels deep: {:k {:k {:k leaf}}}, rooted the
 * same way and on the same terms. */
static Janet nest_structs(int32_t depth, Janet leaf) {
    Janet acc = leaf;
    janet_gcroot(acc);
    for (int32_t i = 0; i < depth; i++) {
        Janet kvs[2] = { kw("k"), acc };
        Janet next = mkstruct(kvs, 1, NULL);
        janet_gcroot(next);
        janet_gcunroot(acc);
        acc = next;
    }
    return acc;
}

/* The traversal is an explicit stack, not recursion. Twenty thousand levels of
 * nesting is a value a parser will produce and a depth a recursive comparison
 * would not survive on any default thread stack.
 *
 * Both directions are asserted: equal all the way down, and differing only at
 * the very bottom, so that the walk is shown to reach the leaf rather than
 * stopping early and returning a hopeful answer. */
static void test_deep_tuples_do_not_recurse(void) {
    Janet a = nest_tuples(20000, intv(0));
    Janet b = nest_tuples(20000, intv(0));
    Janet c = nest_tuples(20000, intv(1));

    assert(janet_equals(a, b));
    assert(!janet_equals(a, c));
    assert(janet_compare(a, b) == 0);
    assert(janet_compare(a, c) == -1);
    assert(janet_compare(c, a) == 1);

    janet_gcunroot(a);
    janet_gcunroot(b);
    janet_gcunroot(c);
}

static void test_deep_structs_do_not_recurse(void) {
    Janet a = nest_structs(20000, intv(0));
    Janet b = nest_structs(20000, intv(0));
    Janet c = nest_structs(20000, intv(1));

    assert(janet_equals(a, b));
    assert(!janet_equals(a, c));
    assert(janet_compare(a, b) == 0);
    assert(janet_compare(a, c) == -1);

    janet_gcunroot(a);
    janet_gcunroot(b);
    janet_gcunroot(c);
}

/* A long prototype chain is walked by the same stack, and the hop at the
 * bottom of `traversal_next` replaces the current node rather than pushing on
 * top of it -- so comparing a chain of N prototypes does not need N nodes.
 *
 * A successful comparison ends with the stack pointer back at the base, so the
 * depth afterwards says nothing. What does say something is the *capacity*,
 * which only ever grows and starts at a floor of 128: if the hop pushed, five
 * hundred levels would have forced two doublings. This is why the test runs
 * before the deep ones -- they grow the array past the floor and it is never
 * given back. */
static void test_prototype_hop_replaces_the_node(void) {
    Janet kvs[2] = { kw("a"), intv(1) };
    Janet a = janet_wrap_nil();
    Janet b = janet_wrap_nil();
    janet_gcroot(a);
    janet_gcroot(b);
    for (int32_t i = 0; i < 500; i++) {
        const JanetKV *pa = janet_checktype(a, JANET_NIL) ? NULL : janet_unwrap_struct(a);
        Janet next_a = mkstruct(kvs, 1, pa);
        janet_gcroot(next_a);
        janet_gcunroot(a);
        a = next_a;
        const JanetKV *pb = janet_checktype(b, JANET_NIL) ? NULL : janet_unwrap_struct(b);
        Janet next_b = mkstruct(kvs, 1, pb);
        janet_gcroot(next_b);
        janet_gcunroot(b);
        b = next_b;
    }
    const JanetKV *chain_a = janet_unwrap_struct(a);
    assert(janet_equals(a, b));
    assert(stack_depth() == 0);
    assert(janet_compare(a, b) == 0);
    assert(janet_vm.traversal_base != NULL);
    assert(janet_vm.traversal_top - janet_vm.traversal_base == 128);

    /* And the chains are genuinely five hundred deep, so the walk had that
     * many hops to make. */
    int32_t levels = 0;
    for (const JanetKV *p = chain_a; p != NULL; p = janet_struct_proto(p)) levels++;
    assert(levels == 500);

    janet_gcunroot(a);
    janet_gcunroot(b);
}

/* Neither entry point pops what it pushed: an early rejection deep inside a
 * traversal leaves nodes on the stack. That is only sound because the next
 * comparison resets the pointer on the way in, which is asserted by running a
 * comparison that must return 1 immediately after one that bailed out deep. */
static void test_the_stack_is_reset_not_unwound(void) {
    Janet deep_a = nest_tuples(200, intv(0));
    Janet deep_b = nest_tuples(200, intv(1));

    /* `janet_compare`, because it is the one that descends: see
     * `test_the_base_slot_is_dead`. Two hundred levels down it finds the leaf
     * and returns, leaving two hundred nodes behind it. */
    assert(janet_compare(deep_a, deep_b) == -1);
    ptrdiff_t left_behind = stack_depth();
    assert(left_behind == 200);

    /* The next comparison sees a stack with two hundred nodes still on it and
     * must not be affected by any of them. */
    assert(janet_equals(intv(1), intv(1)));
    assert(stack_depth() == 0);
    Janet deep_c = nest_tuples(200, intv(0));
    assert(janet_equals(deep_a, deep_c));
    assert(janet_compare(deep_a, deep_b) == -1);
    assert(janet_compare(deep_b, deep_a) == 1);
    assert(!janet_equals(deep_a, deep_b));

    janet_gcunroot(deep_a);
    janet_gcunroot(deep_b);
    janet_gcunroot(deep_c);
}

/* The stack grows by doubling from a floor of 128 nodes and never shrinks, so
 * a deep comparison after a shallow one reuses the array. Asserted on the
 * capacity in nodes, which is the growth policy and nothing else. */
static void test_stack_growth_policy(void) {
    assert(janet_equals(intv(1), intv(1)));
    if (janet_vm.traversal_base != NULL) {
        ptrdiff_t cap = janet_vm.traversal_top - janet_vm.traversal_base;
        assert(cap >= 128);
    }

    Janet a = nest_tuples(5000, intv(0));
    Janet b = nest_tuples(5000, intv(0));
    assert(janet_equals(a, b));

    ptrdiff_t grown = janet_vm.traversal_top - janet_vm.traversal_base;
    assert(grown >= 5000);
    /* Doubling, so never far past what was needed. */
    assert(grown < 4 * 5001);

    /* And the array is not given back: a shallow comparison afterwards leaves
     * the capacity where it was. */
    assert(janet_equals(intv(1), intv(1)));
    assert(janet_vm.traversal_top - janet_vm.traversal_base == grown);

    janet_gcunroot(a);
    janet_gcunroot(b);
}

/* The base slot is never used: the stack pointer is pre-incremented before a
 * node is stored, and the walk stops strictly above the base. So a comparison
 * that pushes exactly one node and stops inside it leaves the pointer one past
 * the base, and one that runs to the end leaves it *at* the base.
 *
 * Observed through `janet_compare` rather than `janet_equals`, and the reason
 * is worth stating because it governs the two tests below as well.
 * `janet_equals` compares the stored hashes of two tuples before it pushes
 * anything, so two tuples that differ almost never reach the traversal at all
 * -- the only inputs that get `janet_equals` into the stack are ones that are
 * *equal*, which then run to completion. `janet_compare` has no such exit,
 * since an ordering cannot stop at "different", so it always pushes. */
static void test_the_base_slot_is_dead(void) {
    Janet items[1] = { intv(0) };
    Janet other[1] = { intv(1) };
    Janet a = mktuple(items, 1, 0);
    Janet b = mktuple(items, 1, 0);
    Janet c = mktuple(other, 1, 0);

    assert(janet_equals(a, b));
    assert(stack_depth() == 0);
    assert(janet_compare(a, b) == 0);
    assert(stack_depth() == 0);

    /* Stops inside the tuple's node, which is therefore still on the stack. */
    assert(janet_compare(a, c) == -1);
    assert(stack_depth() == 1);

    /* And `janet_equals` settles the same pair on the stored hash, without
     * pushing at all -- which is the claim the comment above makes. */
    assert(janet_tuple_hash(janet_unwrap_tuple(a)) != janet_tuple_hash(janet_unwrap_tuple(c)));
    assert(!janet_equals(a, c));
    assert(stack_depth() == 0);
}

/* ------------------------------------------------------------ the contract */

/* The three functions against one corpus covering every `JanetType`, checking
 * the relations that hold *between* them rather than any one in isolation:
 *
 *   - `janet_compare` is a total order: reflexive, antisymmetric, and its sign
 *     agrees with `janet_equals` being zero.
 *   - `janet_equals` implies equal `janet_hash`.
 *
 * NaN is excluded, since it satisfies none of them and the C says so. */
static void test_the_relations_hold_over_a_corpus(void) {
    /* Built under a lock and rooted before it is released: the corpus is a C
     * array, so every element after the first would be unreachable during the
     * allocation of the next one. */
    int lock = janet_gclock();
    JanetTable *root = janet_table(64);
    janet_gcroot(janet_wrap_table(root));

    Janet items[2] = { intv(1), kw("k") };
    Janet kvs[4] = { kw("x"), intv(1), kw("y"), intv(2) };
    Janet corpus[] = {
        janet_wrap_nil(),
        janet_wrap_false(),
        janet_wrap_true(),
        num(-1.5), num(0.0), num(-0.0), intv(0), intv(1), num(INFINITY),
        str("a"), str("b"), str(""),
        sym("a"), kw("a"),
        mktuple(items, 2, 0), mktuple(items, 2, 1), mktuple(items, 1, 0),
        mkstruct(kvs, 2, NULL), mkstruct(kvs, 1, NULL),
        janet_wrap_array(janet_array(1)),
        janet_wrap_table(janet_table(1)),
        janet_wrap_buffer(janet_buffer(1)),
        mkcell(42),
        mkbare(CONTRACT_AT(bare_type)),
        janet_wrap_pointer((void *) CONTRACT_AT(cell_type)),
        janet_wrap_cfunction(NULL),
    };
    const int n = (int)(sizeof(corpus) / sizeof(corpus[0]));
    for (int i = 0; i < n; i++) janet_table_put(root, intv(i), corpus[i]);
    janet_gcunlock(lock);

    for (int i = 0; i < n; i++) {
        assert(janet_compare(corpus[i], corpus[i]) == 0);
        assert(janet_equals(corpus[i], corpus[i]));
        for (int j = 0; j < n; j++) {
            int fwd = janet_compare(corpus[i], corpus[j]);
            int rev = janet_compare(corpus[j], corpus[i]);
            assert(fwd == -rev);
            int eq = janet_equals(corpus[i], corpus[j]);
            assert((fwd == 0) == (eq != 0));
            if (eq) assert(janet_hash(corpus[i]) == janet_hash(corpus[j]));
        }
    }

    /* Transitivity across the whole corpus, which is what "total order"
     * actually claims and what a sort will exercise. */
    for (int i = 0; i < n; i++) {
        for (int j = 0; j < n; j++) {
            for (int k = 0; k < n; k++) {
                if (janet_compare(corpus[i], corpus[j]) < 0 &&
                        janet_compare(corpus[j], corpus[k]) < 0) {
                    assert(janet_compare(corpus[i], corpus[k]) < 0);
                }
            }
        }
    }

    janet_gcunroot(janet_wrap_table(root));
}

/* ------------------------------------------------------- through the runtime */

/* The same properties once more, reached the way a Janet program reaches them,
 * so that the C entry points above are shown to be the ones the language is
 * actually built on. */
static void test_from_janet(void) {
    Janet out;
    const char *src =
        "[(= [1 2] [1 2]) "
        " (= [1 2] (tuple 1 2)) "
        " (= (hash :tie) (hash \"tie\")) "
        " (= :tie \"tie\") "
        " (compare [1 2] [1 2 3]) "
        " (compare 1 2) "
        " (compare \"a\" \"b\") "
        " (= (hash 0.0) (hash -0.0)) "
        " (deep= {:a [1 {:b 2}]} {:a [1 {:b 2}]}) "
        " (sorted [3 1 2 :a \"s\" nil true]) "
        " (= (do (var t nil) (for i 0 5000 (set t [i t])) t) "
        "    (do (var t nil) (for i 0 5000 (set t [i t])) t))]";
    assert(janet_dostring(janet_core_env(NULL), src, "value_order", &out) == 0);
    const Janet *r = janet_unwrap_tuple(out);
    assert(janet_truthy(r[0]));
    assert(janet_truthy(r[1]));
    assert(janet_truthy(r[2]));
    assert(!janet_truthy(r[3]));
    assert(janet_unwrap_integer(r[4]) == -1);
    assert(janet_unwrap_integer(r[5]) == -1);
    assert(janet_unwrap_integer(r[6]) == -1);
    assert(janet_truthy(r[7]));
    assert(janet_truthy(r[8]));
    /* `sorted` puts the types in `JanetType` order, which is the ordering
     * across types this file pins from the C side -- and that order starts
     * with numbers, because `JANET_NUMBER` is zero. */
    /* `sorted` returns an array, not a tuple. */
    const Janet *sortd = janet_unwrap_array(r[9])->data;
    assert(janet_unwrap_integer(sortd[0]) == 1);
    assert(janet_unwrap_integer(sortd[1]) == 2);
    assert(janet_unwrap_integer(sortd[2]) == 3);
    assert(janet_checktype(sortd[3], JANET_NIL));
    assert(janet_checktype(sortd[4], JANET_BOOLEAN));
    assert(janet_checktype(sortd[5], JANET_STRING));
    assert(janet_checktype(sortd[6], JANET_KEYWORD));
    assert(janet_truthy(r[10]));
}

void value_order_contract(void) {
    janet_init();

    test_hash_of_the_atoms();
    test_hash_agrees_with_equality();
    test_string_likes_share_one_hash();
    test_hash_normalizes_negative_zero();
    test_exact_number_hashes();
    test_hash_of_integers_and_doubles_agree();
    test_bracket_tuples_hash_and_compare_apart();
    test_hash_reads_the_stored_head();
    test_abstract_hash_callback();
    test_pointer_hash_is_the_high_word();
    test_pointer_hash_is_stable();

    test_equality_of_atoms();
    test_equality_of_numbers();
    test_equality_of_string_likes();
    test_equality_of_mutable_containers();
    test_equality_of_tuples();
    test_a_tuple_holding_nan_equals_itself();
    test_equality_of_structs();
    test_the_checks_behind_the_hash();
    test_the_struct_ordering_criteria_are_in_order();
    test_equality_of_abstracts();

    test_order_across_types();
    test_order_of_numbers();
    test_order_of_booleans();
    test_order_of_string_likes();
    test_order_of_tuples();
    test_order_of_structs();
    test_order_of_struct_prototypes();
    test_order_of_mutable_containers();
    test_order_of_abstracts();

    /* Order matters here and nowhere else in this file. The traversal array
     * only ever grows, so every test that asserts a capacity has to run before
     * the ones that grow it past the floor. */
    test_the_base_slot_is_dead();
    test_prototype_hop_replaces_the_node();
    test_stack_growth_policy();
    test_the_stack_is_reset_not_unwound();
    test_deep_tuples_do_not_recurse();
    test_deep_structs_do_not_recurse();

    test_the_relations_hold_over_a_corpus();

    test_from_janet();

    janet_deinit();
    printf("value order contract ok\n");
}
