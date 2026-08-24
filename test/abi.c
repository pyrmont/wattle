#include <stddef.h>
#include <stdint.h>
#include <janet.h>

#if defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L
#define ABI_ASSERT(condition, message) _Static_assert(condition, message)
#else
#define ABI_ASSERT_JOIN_(a, b) a##b
#define ABI_ASSERT_JOIN(a, b) ABI_ASSERT_JOIN_(a, b)
#define ABI_ASSERT(condition, message) \
    typedef char ABI_ASSERT_JOIN(abi_assert_, __LINE__)[(condition) ? 1 : -1]
#endif

ABI_ASSERT(JANET_NUMBER == 0, "JanetType numbering changed");
ABI_ASSERT(JANET_NIL == 1, "JanetType numbering changed");
ABI_ASSERT(JANET_POINTER == 15, "JanetType numbering changed");
ABI_ASSERT(JANET_COUNT_TYPES == 16, "JanetType count changed");
ABI_ASSERT(JANET_SIGNAL_OK == 0, "JanetSignal numbering changed");
ABI_ASSERT(JANET_SIGNAL_ERROR == 1, "JanetSignal numbering changed");
ABI_ASSERT(JANET_FRAME_SIZE == 4, "Janet stack-frame width changed");
ABI_ASSERT(sizeof(JanetKV) == 2 * sizeof(Janet), "JanetKV must contain two adjacent Janet values");
ABI_ASSERT(offsetof(JanetArray, count) == sizeof(JanetGCObject), "JanetArray prefix changed");
ABI_ASSERT(offsetof(JanetBuffer, count) == sizeof(JanetGCObject), "JanetBuffer prefix changed");
ABI_ASSERT(offsetof(JanetTable, count) == sizeof(JanetGCObject), "JanetTable prefix changed");

/* The five flexible-array headers, and the one assumption the Zig runtime
 * cannot check about itself.
 *
 * Every head in `janet.h` ends in a flexible array, and the C macros recover a
 * header by subtracting `offsetof(Head, data)`. `@cImport` **drops flexible
 * array members**, so `@offsetOf(JanetStringHead, "data")` does not compile
 * and every one of those subtractions is spelled `@sizeOf` in Zig instead.
 * The two agree only where the flexible array needs no padding after the last
 * declared field.
 *
 * `test/gc_mark.c` and `test/gc_sweep.c` carried these five lines until Phase
 * 11 Part 8 migrated both to Zig, at which point there was nowhere left in
 * either file to write `offsetof`. They live here now, which is where they
 * always belonged: this file is C's view of `janet.h`'s layout, and that is
 * exactly what the assumption is about.
 *
 * `test/gc_mark.zig` keeps a run-time check beside these, and it is a
 * *different* property -- that the runtime's own `@sizeOf` arithmetic agrees
 * with what the allocator did. Only these five compare the two spellings. If
 * this file is ever deleted rather than rewritten, they have to go somewhere
 * that is still C. */
ABI_ASSERT(sizeof(JanetStringHead) == offsetof(JanetStringHead, data), "JanetStringHead gained padding before its data");
ABI_ASSERT(sizeof(JanetTupleHead) == offsetof(JanetTupleHead, data), "JanetTupleHead gained padding before its data");
ABI_ASSERT(sizeof(JanetStructHead) == offsetof(JanetStructHead, data), "JanetStructHead gained padding before its data");
ABI_ASSERT(sizeof(JanetAbstractHead) == offsetof(JanetAbstractHead, data), "JanetAbstractHead gained padding before its data");
ABI_ASSERT(sizeof(JanetFunction) == offsetof(JanetFunction, envs), "JanetFunction gained padding before its environments");

#if defined(JANET_NANBOX_64) || defined(JANET_NANBOX_32)
ABI_ASSERT(sizeof(Janet) == sizeof(uint64_t), "NaN-boxed Janet must be 64 bits");
#else
ABI_ASSERT(sizeof(Janet) >= sizeof(uint64_t) + sizeof(JanetType), "Tagged Janet is unexpectedly small");
#endif

int main(void) {
    return 0;
}
