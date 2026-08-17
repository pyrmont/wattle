/* Behavioral contract for platform classification and CPU discovery, run
 * against whichever implementation the build selected (`-Dos-platform=c` or
 * the Zig default). */

#include <assert.h>
#include <stdint.h>
#include <string.h>
#include <janet.h>

const char *janet_os_name(void);
const char *janet_os_arch(void);
const char *janet_os_compiler(void);
#ifndef JANET_REDUCED_OS
int32_t janet_os_cpu_count(void);
#endif

#define JANET_TEST_STRINGIFY1(x) #x
#define JANET_TEST_STRINGIFY(x) JANET_TEST_STRINGIFY1(x)

static const char *expected_os(void) {
#if defined(JANET_OS_NAME)
    return JANET_TEST_STRINGIFY(JANET_OS_NAME);
#elif defined(JANET_MINGW)
    return "mingw";
#elif defined(JANET_CYGWIN)
    return "cygwin";
#elif defined(JANET_WINDOWS)
    return "windows";
#elif defined(JANET_APPLE)
    return "macos";
#elif defined(__EMSCRIPTEN__)
    return "web";
#elif defined(JANET_LINUX)
    return "linux";
#elif defined(JANET_GNU_HURD)
    return "hurd";
#elif defined(__FreeBSD__)
    return "freebsd";
#elif defined(__NetBSD__)
    return "netbsd";
#elif defined(__OpenBSD__)
    return "openbsd";
#elif defined(__DragonFly__)
    return "dragonfly";
#elif defined(JANET_BSD)
    return "bsd";
#elif defined(JANET_ILLUMOS)
    return "illumos";
#else
    return "posix";
#endif
}

static const char *expected_arch(void) {
#if defined(JANET_ARCH_NAME)
    return JANET_TEST_STRINGIFY(JANET_ARCH_NAME);
#elif defined(__EMSCRIPTEN__)
    return "wasm";
#elif defined(__x86_64__) || defined(_M_X64)
    return "x64";
#elif defined(__i386) || defined(_M_IX86)
    return "x86";
#elif defined(_M_ARM64) || defined(__aarch64__)
    return "aarch64";
#elif defined(_M_ARM) || defined(__arm__)
    return "arm";
#elif defined(__riscv) && (__riscv_xlen == 64)
    return "riscv64";
#elif defined(__riscv) && (__riscv_xlen == 32)
    return "riscv32";
#elif defined(__sparc__)
    return "sparc";
#elif defined(__ppc__)
    return "ppc";
#elif defined(__ppc64__) || defined(_ARCH_PPC64) || defined(_M_PPC)
    return "ppc64";
#elif defined(__s390x__)
    return "s390x";
#elif defined(__s390__)
    return "s390";
#else
    return "unknown";
#endif
}

static const char *expected_compiler(void) {
#if defined(_MSC_VER)
    return "msvc";
#elif defined(__clang__)
    return "clang";
#elif defined(__GNUC__)
    return "gcc";
#elif defined(JANET_PLAN9)
    return "kencc";
#else
    return "unknown";
#endif
}

static void expect_keyword(Janet value, const char *expected) {
    assert(janet_checktype(value, JANET_KEYWORD));
    assert(!janet_cstrcmp(janet_unwrap_keyword(value), expected));
}

static void test_classification(void) {
#ifndef JANET_OS_NAME
    assert(!strcmp(janet_os_name(), expected_os()));
#endif
#ifndef JANET_ARCH_NAME
    assert(!strcmp(janet_os_arch(), expected_arch()));
#endif
    assert(!strcmp(janet_os_compiler(), expected_compiler()));
}

static void test_core_functions(void) {
    JanetCFunction which = janet_unwrap_cfunction(janet_resolve_core("os/which"));
    JanetCFunction arch = janet_unwrap_cfunction(janet_resolve_core("os/arch"));
    JanetCFunction compiler = janet_unwrap_cfunction(janet_resolve_core("os/compiler"));
    Janet test;

    expect_keyword(which(0, NULL), expected_os());
    expect_keyword(arch(0, NULL), expected_arch());
    expect_keyword(compiler(0, NULL), expected_compiler());

    test = janet_ckeywordv(expected_os());
    assert(janet_unwrap_boolean(which(1, &test)));
    test = janet_ckeywordv("not-a-platform");
    assert(!janet_unwrap_boolean(which(1, &test)));
    test = janet_wrap_nil();
    expect_keyword(which(1, &test), expected_os());
}

#ifndef JANET_REDUCED_OS
static void test_cpu_count(void) {
    JanetCFunction cpu_count = janet_unwrap_cfunction(janet_resolve_core("os/cpu-count"));
    int32_t direct = janet_os_cpu_count();
    Janet fallback = janet_ckeywordv("fallback");
    Janet actual = cpu_count(1, &fallback);

    if (direct < 0) {
        assert(janet_equals(actual, fallback));
        assert(janet_checktype(cpu_count(0, NULL), JANET_NIL));
    } else {
        assert(janet_checkint(actual));
        assert(janet_unwrap_integer(actual) == direct);
        assert(janet_unwrap_integer(cpu_count(0, NULL)) == direct);
    }
}
#endif

int main(void) {
    test_classification();
    janet_init();
    test_core_functions();
#ifndef JANET_REDUCED_OS
    test_cpu_count();
#endif
    janet_deinit();
    return 0;
}
