/* Behavioral contract for environment scanning and host operations, run
 * against whichever implementation the build selected (`-Dos-environ=c` or
 * the Zig default). */

#include <assert.h>
#include <stdint.h>
#include <string.h>
#include <janet.h>

int32_t janet_os_environ_count(char *const *env);
int32_t janet_os_environ_separator(const char *entry);
const char *janet_os_getenv(const char *name);
int32_t janet_os_setenv(const char *name, const char *value);

static const char test_name[] = "JANET_ZIG_OS_ENVIRON_CONTRACT_6F6B4D";

static void test_scanning(void) {
    char first[] = "A=1";
    char second[] = "EMPTY=";
    char windows_drive[] = "=C:=C:\\work";
    char *entries[] = {first, second, windows_drive, NULL};

    assert(janet_os_environ_count(entries) == 3);
    assert(janet_os_environ_count(entries + 3) == 0);
    assert(janet_os_environ_separator(first) == 1);
    assert(janet_os_environ_separator(second) == 5);
    assert(janet_os_environ_separator(windows_drive) == 0);
    assert(janet_os_environ_separator("missing") == -1);
    assert(janet_os_environ_separator("") == -1);
}

static void test_host_operations(void) {
    const char *value;

    assert(janet_os_setenv(test_name, NULL) == 0);
    assert(janet_os_getenv(test_name) == NULL);

    assert(janet_os_setenv(test_name, "") == 0);
    value = janet_os_getenv(test_name);
    assert(value != NULL && !strcmp(value, ""));

    assert(janet_os_setenv(test_name, "first=second") == 0);
    assert(!strcmp(janet_os_getenv(test_name), "first=second"));
    assert(janet_os_setenv(test_name, "replacement") == 0);
    assert(!strcmp(janet_os_getenv(test_name), "replacement"));

    assert(janet_os_setenv(test_name, NULL) == 0);
    assert(janet_os_getenv(test_name) == NULL);
}

static void test_core_functions(void) {
    JanetCFunction setenv_fn = janet_unwrap_cfunction(janet_resolve_core("os/setenv"));
    JanetCFunction getenv_fn = janet_unwrap_cfunction(janet_resolve_core("os/getenv"));
    Janet args[2];
    Janet result;

    args[0] = janet_cstringv(test_name);
    args[1] = janet_cstringv("public-value");
    assert(janet_checktype(setenv_fn(2, args), JANET_NIL));
    result = getenv_fn(1, args);
    assert(janet_checktype(result, JANET_STRING));
    assert(!janet_cstrcmp(janet_unwrap_string(result), "public-value"));

#ifndef JANET_PLAN9
    {
        JanetCFunction environ_fn = janet_unwrap_cfunction(janet_resolve_core("os/environ"));
        JanetTable *snapshot = janet_unwrap_table(environ_fn(0, NULL));
        Janet captured = janet_table_get(snapshot, args[0]);
        assert(janet_checktype(captured, JANET_STRING));
        assert(!janet_cstrcmp(janet_unwrap_string(captured), "public-value"));
    }
#endif

    args[1] = janet_ckeywordv("fallback");
    args[0] = janet_cstringv("JANET_ZIG_OS_ENVIRON_MISSING_7A21C9");
    assert(janet_equals(getenv_fn(2, args), args[1]));

    args[0] = janet_cstringv(test_name);
    assert(janet_checktype(setenv_fn(1, args), JANET_NIL));
    assert(janet_checktype(getenv_fn(1, args), JANET_NIL));
}

int main(void) {
    janet_init();
    test_scanning();
    test_host_operations();
    test_core_functions();
    janet_deinit();
    return 0;
}
