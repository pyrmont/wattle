/* Behavioral contract for the two growable containers: `JanetBuffer` and
 * `JanetArray`. Run against whichever implementation the build selected
 * (`-Dbuffer-array=c` or the Zig default).
 *
 * These are the easiest containers in the runtime to observe, because almost
 * everything they do is visible in three `int32_t` fields and a pointer. So
 * this file asserts the fields directly rather than through the standard
 * library: `count`, `capacity`, and what `data` holds after each operation.
 * The capacity policy is the interesting part -- both types overshoot by a
 * caller-supplied growth factor, and the exact resulting capacity is a
 * contract, not an implementation detail, because `array/ensure` exposes it to
 * Janet code.
 *
 * GC pressure is the second channel. Both files charge `janet_vm.next_collection`
 * for the payloads they allocate, and they do it inconsistently -- the buffer
 * charges before its `janet_realloc` and the array after, `janet_array_n`
 * charges nothing at all. None of that is a defect, but all of it is
 * observable, so it is pinned here to stop the two selectors drifting apart on
 * an accounting term that nothing else would catch.
 *
 * What this file cannot cover is worth stating plainly.
 *
 * `FOUND.md` records that `array/ensure` passes an unchecked growth factor to
 * `janet_array_ensure`, and that a factor of zero or less makes the arithmetic
 * produce a capacity that is zero or negative. The negative case ends the
 * process through `JANET_OUT_OF_MEMORY` -- every negative capacity converts to
 * a `size_t` near the top of the range, so the allocation always fails -- and a
 * test cannot survive it. The zero case depends on the C library: `realloc(p, 0)`
 * returns a minimal block on macOS and NULL on glibc, and the second answer
 * also reaches `JANET_OUT_OF_MEMORY`. So the zero case is asserted only after
 * probing the allocator for which answer it gives, and the negative case is
 * left to `FOUND.md`'s reproducer.
 *
 * The zero case does cover the wrapping conversions in `buffer_array.zig`,
 * where the allocator allows it to be run: the GC accounting term below is a
 * negative `int32_t` widened to a `size_t`, and replacing the bit-preserving
 * conversion with a checked one makes the Zig trap there instead of proceeding
 * as C does. Where `realloc(p, 0)` returns NULL that coverage is lost with the
 * rest of the case, and the negative-growth path is never covered on any
 * platform, because it dies inside the allocator on the next line.
 *
 * Two overflow panics are also uncovered. `janet_buffer_extra`'s is asserted
 * below because it is reachable with a large `n` and an empty buffer, but
 * `janet_array_push`'s requires an array of `INT32_MAX` elements to already
 * exist, which is not something a test can arrange.
 */

#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "features.h"
#include <janet.h>

#include "support.h"
#include "state.h"
#include "gc.h"
#include "util.h"

/* ------------------------------------------------------------------ helpers */

static int panics_fired = 0;

#define EXPECT_PANIC(expr, message) do { \
    JanetTryState _state; \
    int _raised = 0; \
    JanetSignal _sig = JANET_SIGNAL_OK; \
    janet_try_init(&_state); \
    janet_contract_arm(); \
    (void)(expr); \
    _raised = janet_contract_raised(); \
    if (_raised) _sig = janet_contract_signal(); \
    janet_restore(&_state); \
    assert(_raised && "expected a panic, got a return"); \
    assert(_sig == JANET_SIGNAL_ERROR); \
    assert(janet_checktype(_state.payload, JANET_STRING)); \
    if (janet_cstrcmp(janet_unwrap_string(_state.payload), (message))) { \
        printf("expected: %s\n     got: %s\n", (message), \
               (const char *) janet_unwrap_string(_state.payload)); \
        assert(0 && "message mismatch"); \
    } \
    panics_fired++; \
} while (0)

static int memtype(void *p) {
    return janet_gc_header(p)->flags & JANET_MEM_TYPEBITS;
}

/* Whether a block is on one of the two heap lists. */
static int on_list(void *list, void *block) {
    JanetGCObject *current = (JanetGCObject *) list;
    while (NULL != current) {
        if ((void *) current == block) return 1;
        current = current->data.next;
    }
    return 0;
}

/* Does this C library's `realloc(p, 0)` return a block, or NULL? The answer
 * decides whether the zero-growth case in `janet_array_ensure` returns or
 * exits, and it is a property of the allocator rather than of Janet. */
static int realloc_zero_returns_a_block(void) {
    void *p = janet_malloc(16);
    assert(NULL != p);
    void *q = janet_realloc(p, 0);
    if (NULL == q) return 0;
    janet_free(q);
    return 1;
}

/* ------------------------------------------------------------------ buffer */

/* A collectable buffer starts empty, lands on the strong heap list, and is
 * given a floor of four bytes of capacity however little was asked for. The
 * floor is the buffer's alone; `janet_array` has no equivalent. */
static void test_buffer_starts_with_a_capacity_floor(void) {
    JanetBuffer *b = janet_buffer(0);
    assert(b->count == 0);
    assert(b->capacity == 4);
    assert(b->data != NULL);
    assert(memtype(b) == JANET_MEMORY_BUFFER);
    assert(on_list(janet_vm.blocks, b));

    JanetBuffer *big = janet_buffer(100);
    assert(big->capacity == 100);
    assert(big->count == 0);

    /* Exactly at the floor, and one below it. */
    assert(janet_buffer(4)->capacity == 4);
    assert(janet_buffer(3)->capacity == 4);
    assert(janet_buffer(-1)->capacity == 4);
}

/* A buffer the caller owns is marked disabled and is not linked into a heap
 * list, so the collector never reaches it and never frees it. */
static void test_caller_owned_buffer_is_disabled(void) {
    JanetBuffer b;
    memset(&b, 0xAA, sizeof(b));
    JanetBuffer *ret = janet_buffer_init(&b, 32);
    assert(ret == &b);
    assert(b.count == 0);
    assert(b.capacity == 32);
    assert(b.data != NULL);
    assert(b.gc.flags == JANET_MEM_DISABLED);
    assert(b.gc.data.next == NULL);
    assert(!on_list(janet_vm.blocks, &b));

    /* It still behaves as a buffer, and deinit releases the payload. */
    janet_buffer_push_cstring(&b, "hello");
    assert(b.count == 5);
    assert(0 == memcmp(b.data, "hello", 5));
    janet_buffer_deinit(&b);
    assert(b.data == NULL);
}

/* A pointer buffer wraps memory the runtime did not allocate. The block is
 * collectable but the payload is not: the NO_REALLOC flag makes every growth
 * path refuse and makes deinit leave the foreign pointer alone. */
static void test_pointer_buffer_never_reallocates(void) {
    static uint8_t foreign[8] = {1, 2, 3, 4, 5, 6, 7, 8};

    JanetBuffer *b = janet_pointer_buffer_unsafe(foreign, 8, 3);
    assert(b->data == foreign);
    assert(b->capacity == 8);
    assert(b->count == 3);
    assert(b->gc.flags & JANET_BUFFER_FLAG_NO_REALLOC);
    assert(memtype(b) == JANET_MEMORY_BUFFER);
    assert(on_list(janet_vm.blocks, b));

    /* Growing within the existing capacity is fine -- `janet_buffer_ensure`
     * returns before it consults the flag. */
    janet_buffer_ensure(b, 8, 1);
    assert(b->data == foreign);

    /* Growing past it is refused, and so is the guard called directly. This
     * is the increment's one seam: `janet_buffer_can_realloc` was static in
     * `buffer.c` and is now shared, because `cfun_buffer_trim` still calls it
     * from the half of the file that stays in C. */
    EXPECT_PANIC(janet_buffer_ensure(b, 9, 1), "buffer cannot reallocate foreign memory");
    EXPECT_PANIC(janet_buffer_extra(b, 100), "buffer cannot reallocate foreign memory");
    EXPECT_PANIC(janet_buffer_can_realloc(b), "buffer cannot reallocate foreign memory");
    assert(b->data == foreign);
    assert(b->capacity == 8);

    /* Deinit leaves the foreign memory intact rather than freeing it. */
    janet_buffer_deinit(b);
    assert(b->data == foreign);
    assert(foreign[0] == 1 && foreign[7] == 8);

    /* Its arguments are validated before the block is allocated. */
    EXPECT_PANIC(janet_pointer_buffer_unsafe(foreign, 8, -1), "count < 0");
    EXPECT_PANIC(janet_pointer_buffer_unsafe(foreign, 2, 3), "capacity < count");
}

/* The growth factor multiplies the requested capacity, and the request is
 * ignored outright when the buffer is already large enough. */
static void test_buffer_ensure_applies_the_growth_factor(void) {
    JanetBuffer *b = janet_buffer(10);
    uint8_t *before = b->data;

    /* Already big enough: no reallocation, no change, no pressure. */
    size_t nc = janet_vm.next_collection;
    janet_buffer_ensure(b, 10, 2);
    janet_buffer_ensure(b, 4, 8);
    assert(b->capacity == 10);
    assert(b->data == before);
    assert(janet_vm.next_collection == nc);

    /* Past it: the new capacity is the request times the growth. */
    janet_buffer_ensure(b, 11, 3);
    assert(b->capacity == 33);

    janet_buffer_ensure(b, 100, 1);
    assert(b->capacity == 100);

    /* The count is never touched by a capacity change. */
    janet_buffer_push_cstring(b, "abc");
    janet_buffer_ensure(b, 500, 2);
    assert(b->capacity == 1000);
    assert(b->count == 3);
    assert(0 == memcmp(b->data, "abc", 3));
}

/* Growing the count zero-fills the bytes it newly covers; shrinking keeps the
 * capacity and the bytes above the new count. A negative count does nothing. */
static void test_buffer_setcount_zero_fills(void) {
    JanetBuffer *b = janet_buffer(4);
    janet_buffer_push_cstring(b, "xy");
    assert(b->count == 2);

    janet_buffer_setcount(b, 6);
    assert(b->count == 6);
    assert(b->capacity >= 6);
    assert(0 == memcmp(b->data, "xy\0\0\0\0", 6));

    /* Shrinking leaves the capacity alone. */
    int32_t cap = b->capacity;
    janet_buffer_setcount(b, 1);
    assert(b->count == 1);
    assert(b->capacity == cap);

    /* And growing again re-zeroes, rather than exposing the old bytes. */
    b->data[3] = 0xFF;
    janet_buffer_setcount(b, 4);
    assert(b->count == 4);
    assert(b->data[3] == 0);

    /* A negative count is a no-op, not a truncation to zero. */
    janet_buffer_setcount(b, -1);
    assert(b->count == 4);
}

/* `janet_buffer_extra` reserves room without moving the count, and doubles
 * rather than using the growth factor. */
static void test_buffer_extra_doubles(void) {
    JanetBuffer *b = janet_buffer(4);
    janet_buffer_push_cstring(b, "ab");

    /* Room already there: nothing happens. */
    int32_t cap = b->capacity;
    janet_buffer_extra(b, 2);
    assert(b->capacity == cap);
    assert(b->count == 2);

    /* Room not there: capacity becomes twice what was needed. */
    janet_buffer_extra(b, 9);
    assert(b->capacity == 22);
    assert(b->count == 2);
    assert(0 == memcmp(b->data, "ab", 2));

    /* The overflow guard runs before any allocation. */
    EXPECT_PANIC(janet_buffer_extra(b, INT32_MAX), "buffer overflow");
    assert(b->capacity == 22);
    assert(b->count == 2);
}

/* The push primitives, including the byte order of the multi-byte ones. They
 * shift rather than copy, so the layout is little-endian on every host. */
static void test_buffer_pushes_little_endian(void) {
    JanetBuffer *b = janet_buffer(4);

    janet_buffer_push_u8(b, 0xAB);
    assert(b->count == 1 && b->data[0] == 0xAB);

    janet_buffer_setcount(b, 0);
    janet_buffer_push_u16(b, 0x1234);
    assert(b->count == 2);
    assert(b->data[0] == 0x34 && b->data[1] == 0x12);

    janet_buffer_setcount(b, 0);
    janet_buffer_push_u32(b, 0x12345678u);
    assert(b->count == 4);
    assert(b->data[0] == 0x78 && b->data[1] == 0x56);
    assert(b->data[2] == 0x34 && b->data[3] == 0x12);

    janet_buffer_setcount(b, 0);
    janet_buffer_push_u64(b, 0x0123456789ABCDEFull);
    assert(b->count == 8);
    for (int i = 0; i < 8; i++) {
        assert(b->data[i] == (uint8_t)(0x0123456789ABCDEFull >> (8 * i)));
    }

    /* Bytes, C strings, and Janet strings. A zero-length push is a no-op that
     * does not even reserve, which is why it can be checked by capacity. */
    janet_buffer_setcount(b, 0);
    int32_t cap = b->capacity;
    janet_buffer_push_bytes(b, (const uint8_t *) "ignored", 0);
    assert(b->count == 0 && b->capacity == cap);

    janet_buffer_push_bytes(b, (const uint8_t *) "one", 3);
    janet_buffer_push_cstring(b, "two");
    janet_buffer_push_string(b, janet_cstring("three"));
    assert(b->count == 11);
    assert(0 == memcmp(b->data, "onetwothree", 11));

    /* A Janet string may hold an interior zero, and the length comes from its
     * head rather than from the bytes. */
    janet_buffer_setcount(b, 0);
    janet_buffer_push_string(b, janet_string((const uint8_t *) "a\0b", 3));
    assert(b->count == 3);
    assert(0 == memcmp(b->data, "a\0b", 3));
}

/* Every payload the buffer allocates is charged to the collector. */
static void test_buffer_charges_gc_pressure(void) {
    size_t nc = janet_vm.next_collection;
    JanetBuffer *b = janet_buffer(64);
    /* `janet_gcalloc` charges the block, and the payload is charged on top. */
    assert(janet_vm.next_collection == nc + sizeof(JanetBuffer) + 64);

    nc = janet_vm.next_collection;
    janet_buffer_ensure(b, 100, 2);
    assert(b->capacity == 200);
    assert(janet_vm.next_collection == nc + (200 - 64));

    nc = janet_vm.next_collection;
    janet_buffer_setcount(b, 300);
    assert(b->capacity == 300);
    assert(janet_vm.next_collection == nc + (300 - 200));

    /* The floor is charged, not the request. */
    nc = janet_vm.next_collection;
    (void) janet_buffer(1);
    assert(janet_vm.next_collection == nc + sizeof(JanetBuffer) + 4);
}

/* ------------------------------------------------------------------- array */

/* An array has no capacity floor, and a capacity of zero means no payload at
 * all rather than an empty one. */
static void test_array_has_no_capacity_floor(void) {
    JanetArray *a = janet_array(0);
    assert(a->count == 0);
    assert(a->capacity == 0);
    assert(a->data == NULL);
    assert(memtype(a) == JANET_MEMORY_ARRAY);
    assert(on_list(janet_vm.blocks, a));

    JanetArray *b = janet_array(3);
    assert(b->capacity == 3);
    assert(b->count == 0);
    assert(b->data != NULL);

    /* And it grows from nothing without special-casing the null payload. */
    janet_array_push(a, janet_wrap_integer(7));
    assert(a->count == 1);
    assert(a->capacity == 2);
    assert(janet_equals(a->data[0], janet_wrap_integer(7)));
}

/* A weak array differs only in its memory type, which puts it on the other
 * heap list and hands it to the weak half of the sweep. */
static void test_weak_array_is_a_normal_array_elsewhere(void) {
    JanetArray *a = janet_array_weak(4);
    assert(memtype(a) == JANET_MEMORY_ARRAY_WEAK);
    assert(on_list(janet_vm.weak_blocks, a));
    assert(!on_list(janet_vm.blocks, a));
    assert(a->capacity == 4);
    assert(a->count == 0);

    janet_array_push(a, janet_wrap_integer(1));
    assert(a->count == 1);
    assert(a->capacity == 4);

    /* The strong twin is on the other list, and nothing else differs. */
    JanetArray *s = janet_array(4);
    assert(on_list(janet_vm.blocks, s));
    assert(!on_list(janet_vm.weak_blocks, s));
    assert(s->capacity == a->capacity);
}

/* `janet_array_n` copies its elements and sets count and capacity to the same
 * value, so the result is exactly full. */
static void test_array_n_is_exactly_full(void) {
    Janet elements[3];
    elements[0] = janet_wrap_integer(10);
    elements[1] = janet_wrap_keyword(janet_cstring("k"));
    elements[2] = janet_wrap_nil();

    JanetArray *a = janet_array_n(elements, 3);
    assert(a->count == 3);
    assert(a->capacity == 3);
    assert(janet_equals(a->data[0], elements[0]));
    assert(janet_equals(a->data[1], elements[1]));
    assert(janet_checktype(a->data[2], JANET_NIL));

    /* The source is copied, not aliased. */
    elements[0] = janet_wrap_integer(99);
    assert(janet_equals(a->data[0], janet_wrap_integer(10)));

    /* Zero elements is legal and allocates nothing to copy into. */
    JanetArray *empty = janet_array_n(elements, 0);
    assert(empty->count == 0);
    assert(empty->capacity == 0);
}

/* The array's growth factor behaves as the buffer's does. This is the policy
 * `array/ensure` exposes to Janet, so the exact capacities are a contract. */
static void test_array_ensure_applies_the_growth_factor(void) {
    JanetArray *a = janet_array(10);
    Janet *before = a->data;

    size_t nc = janet_vm.next_collection;
    janet_array_ensure(a, 10, 2);
    janet_array_ensure(a, 4, 8);
    assert(a->capacity == 10);
    assert(a->data == before);
    assert(janet_vm.next_collection == nc);

    janet_array_ensure(a, 11, 3);
    assert(a->capacity == 33);

    janet_array_ensure(a, 100, 1);
    assert(a->capacity == 100);

    /* Contents and count survive a reallocation. */
    janet_array_push(a, janet_wrap_integer(5));
    janet_array_ensure(a, 500, 2);
    assert(a->capacity == 1000);
    assert(a->count == 1);
    assert(janet_equals(a->data[0], janet_wrap_integer(5)));
}

/* Growing the count fills with nil, not with zero bytes; a negative count is
 * a no-op. Pushing doubles, and popping and peeking on an empty array give
 * nil rather than failing. */
static void test_array_setcount_push_pop_peek(void) {
    JanetArray *a = janet_array(0);

    assert(janet_checktype(janet_array_pop(a), JANET_NIL));
    assert(janet_checktype(janet_array_peek(a), JANET_NIL));
    assert(a->count == 0);

    janet_array_setcount(a, 3);
    assert(a->count == 3);
    for (int i = 0; i < 3; i++) assert(janet_checktype(a->data[i], JANET_NIL));

    a->data[2] = janet_wrap_integer(2);
    janet_array_setcount(a, 1);
    assert(a->count == 1);
    janet_array_setcount(a, 3);
    /* Re-extending fills with nil again rather than exposing the old value. */
    assert(janet_checktype(a->data[2], JANET_NIL));

    janet_array_setcount(a, -5);
    assert(a->count == 3);

    janet_array_setcount(a, 0);
    janet_array_push(a, janet_wrap_integer(1));
    janet_array_push(a, janet_wrap_integer(2));
    assert(a->count == 2);
    assert(janet_equals(janet_array_peek(a), janet_wrap_integer(2)));
    assert(a->count == 2);
    assert(janet_equals(janet_array_pop(a), janet_wrap_integer(2)));
    assert(a->count == 1);
    assert(janet_equals(janet_array_pop(a), janet_wrap_integer(1)));
    assert(a->count == 0);
    assert(janet_checktype(janet_array_pop(a), JANET_NIL));
}

/* The array's GC accounting, including the two asymmetries with the buffer:
 * `janet_array_n` charges nothing, and `janet_array_ensure` charges after its
 * allocation rather than before. */
static void test_array_charges_gc_pressure(void) {
    size_t nc = janet_vm.next_collection;
    JanetArray *a = janet_array(64);
    assert(janet_vm.next_collection == nc + sizeof(JanetArray) + 64 * sizeof(Janet));

    nc = janet_vm.next_collection;
    janet_array_ensure(a, 100, 2);
    assert(a->capacity == 200);
    assert(janet_vm.next_collection == nc + (200 - 64) * sizeof(Janet));

    /* A capacity of zero allocates no payload, so only the block is charged. */
    nc = janet_vm.next_collection;
    (void) janet_array(0);
    assert(janet_vm.next_collection == nc + sizeof(JanetArray));

    /* `janet_array_n` allocates a payload and charges nothing for it. */
    Janet elements[4] = {0};
    nc = janet_vm.next_collection;
    JanetArray *n = janet_array_n(elements, 4);
    assert(n->capacity == 4);
    assert(n->data != NULL);
    assert(janet_vm.next_collection == nc + sizeof(JanetArray));
}

/* `FOUND.md`: `array/ensure` hands an unchecked growth factor through, and a
 * factor of zero releases the payload while leaving `count` alone. Asserted
 * deliberately, so that whichever selector is fixed first fails here. See the
 * note at the head of this file about why the allocator is probed first. */
static void test_zero_growth_releases_the_payload(void) {
    if (!realloc_zero_returns_a_block()) return;

    JanetArray *a = janet_array(0);
    for (int i = 0; i < 5; i++) janet_array_push(a, janet_wrap_integer(i));
    assert(a->count == 5);
    assert(a->capacity == 6);

    size_t nc = janet_vm.next_collection;
    janet_array_ensure(a, 100, 0);

    /* The capacity is gone and the count is not, so every element the array
     * claims to hold is now a read of freed memory. Nothing below reads one. */
    assert(a->capacity == 0);
    assert(a->count == 5);

    /* And the accounting term went negative into a size_t. */
    assert(janet_vm.next_collection == nc + (size_t)(int32_t)(0 - 6) * sizeof(Janet));

    /* Make the array safe for the collector again before returning: the mark
     * phase walks `count` elements, and they are not there any more. */
    a->count = 0;
}

/* ------------------------------------------------------- across the seam */

/* The collector frees a container's payload through `janet_deinit_block`,
 * which Part 5 moved to Zig and which calls `janet_buffer_deinit` from this
 * increment. Both containers are freed the same way, so one collection covers
 * the round trip in both directions. */
static void test_the_collector_reclaims_both(void) {
    janet_collect();
    size_t before = janet_vm.block_count;

    for (int i = 0; i < 10; i++) {
        JanetBuffer *b = janet_buffer(1000);
        janet_buffer_setcount(b, 1000);
        JanetArray *a = janet_array(1000);
        janet_array_setcount(a, 1000);
        (void) janet_array_weak(1000);
    }
    assert(janet_vm.block_count == before + 30);

    janet_collect();
    assert(janet_vm.block_count == before);

    /* A rooted one survives the same collection, and is still usable -- which
     * is the assertion that its payload was not freed underneath it. */
    JanetBuffer *keep = janet_buffer(16);
    janet_buffer_push_cstring(keep, "kept");
    janet_gcroot(janet_wrap_buffer(keep));
    janet_collect();
    assert(keep->count == 4);
    assert(0 == memcmp(keep->data, "kept", 4));
    janet_gcunroot(janet_wrap_buffer(keep));
}

/* The standard library reaches this code through the public API, so the two
 * selectors have to agree from Janet as well as from C. This also exercises
 * `cfun_buffer_trim`, the one C caller of the seam. */
static void test_from_janet(void) {
    Janet out;
    JanetTable *env = janet_core_env(NULL);
    const char *src =
        "(let [b (buffer/new 100)\n"
        "      a (array/new 10)]\n"
        "  (buffer/push b \"abc\")\n"
        "  (buffer/trim b)\n"
        "  (array/push a 1)\n"
        "  (array/push a 2)\n"
        "  [(length b) (string b) (length a) (array/pop a) (array/peek a)])";
    assert(janet_dostring(env, src, "buffer-array-test", &out) == 0);
    assert(janet_checktype(out, JANET_TUPLE));
    const Janet *t = janet_unwrap_tuple(out);
    assert(janet_unwrap_integer(t[0]) == 3);
    assert(0 == janet_cstrcmp(janet_unwrap_string(t[1]), "abc"));
    assert(janet_unwrap_integer(t[2]) == 2);
    assert(janet_unwrap_integer(t[3]) == 2);
    assert(janet_unwrap_integer(t[4]) == 1);
}

void buffer_array_contract(void) {
    janet_init();

    test_buffer_starts_with_a_capacity_floor();
    test_caller_owned_buffer_is_disabled();
    test_pointer_buffer_never_reallocates();
    test_buffer_ensure_applies_the_growth_factor();
    test_buffer_setcount_zero_fills();
    test_buffer_extra_doubles();
    test_buffer_pushes_little_endian();
    test_buffer_charges_gc_pressure();

    test_array_has_no_capacity_floor();
    test_weak_array_is_a_normal_array_elsewhere();
    test_array_n_is_exactly_full();
    test_array_ensure_applies_the_growth_factor();
    test_array_setcount_push_pop_peek();
    test_array_charges_gc_pressure();
    test_zero_growth_releases_the_payload();

    test_the_collector_reclaims_both();
    test_from_janet();

    assert(panics_fired == 6);

    janet_deinit();
    printf("buffer array contract ok\n");
}
