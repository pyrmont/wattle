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

#if defined(JANET_NANBOX_64) || defined(JANET_NANBOX_32)
ABI_ASSERT(sizeof(Janet) == sizeof(uint64_t), "NaN-boxed Janet must be 64 bits");
#else
ABI_ASSERT(sizeof(Janet) >= sizeof(uint64_t) + sizeof(JanetType), "Tagged Janet is unexpectedly small");
#endif

int main(void) {
    return 0;
}
