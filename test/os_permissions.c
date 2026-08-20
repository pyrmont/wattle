/* Behavioral contract for OS permission parsing and formatting, run against
 * whichever implementation the build selected (`-Dos-permissions=c` or the
 * Zig default). */

#include <assert.h>
#include <stdint.h>
#include <string.h>
#include <janet.h>

int32_t janet_os_parse_permissions(const uint8_t *permissions);
void janet_os_format_permissions(int32_t permissions, uint8_t *out);

static void expect_format(int32_t mode, const char *expected) {
    uint8_t actual[9];
    memset(actual, 0xA5, sizeof(actual));
    janet_os_format_permissions(mode, actual);
    assert(!memcmp(actual, expected, sizeof(actual)));
}

static void test_kernels(void) {
    uint8_t formatted[9];
    assert(janet_os_parse_permissions((const uint8_t *)"---------") == 0000);
    assert(janet_os_parse_permissions((const uint8_t *)"rwxrwxrwx") == 0777);
    assert(janet_os_parse_permissions((const uint8_t *)"rw-r--r--") == 0644);
    assert(janet_os_parse_permissions((const uint8_t *)"r-x--x--x") == 0511);

    /* The established parser is position-sensitive and permissive: any byte
     * other than the expected letter clears that position. */
    assert(janet_os_parse_permissions((const uint8_t *)"xxxxxxxxx") == 0111);
    assert(janet_os_parse_permissions((const uint8_t *)"rwxgarbage") == 0700);

    expect_format(0000, "---------");
    expect_format(0777, "rwxrwxrwx");
    expect_format(0644, "rw-r--r--");
    expect_format(0511, "r-x--x--x");
    /* Bits outside the portable permission field are ignored. */
    expect_format(0100644, "rw-r--r--");

    /* Every portable mode round-trips exactly. */
    for (int32_t mode = 0; mode <= 0777; mode++) {
        janet_os_format_permissions(mode, formatted);
        assert(janet_os_parse_permissions(formatted) == mode);
    }
}

static void test_core_functions(void) {
    JanetTable *env = janet_core_env(NULL);
    Janet result;

    assert(janet_dostring(env,
                          "(and (= 8r640 (os/perm-int \"rw-r-----\")) "
                          "     (= \"rw-r-----\" (os/perm-string 8r640)) "
                          "     (= \"rwxrwxrwx\" (os/perm-string \"rwxrwxrwx\")))",
                          "test", &result) == 0);
    assert(janet_truthy(result));

    /* Preserve permissive parsing through the public functions too. */
    assert(janet_dostring(env,
                          "(= 8r111 (os/perm-int \"xxxxxxxxx\"))",
                          "test", &result) == 0);
    assert(janet_truthy(result));

    /* Validation remains in C, before either kernel is entered. Run expected
     * failures under protected calls so they stay off stderr. */
    assert(janet_dostring(env,
                          "(fn [] (os/perm-int \"rwx\"))",
                          "test", &result) == 0);
    {
        Janet out;
        assert(janet_pcall(janet_unwrap_function(result), 0, NULL, &out, NULL) == JANET_SIGNAL_ERROR);
    }
    assert(janet_dostring(env,
                          "(fn [] (os/perm-string 8r1000))",
                          "test", &result) == 0);
    {
        Janet out;
        assert(janet_pcall(janet_unwrap_function(result), 0, NULL, &out, NULL) == JANET_SIGNAL_ERROR);
    }
}

void os_permissions_contract(void) {
    janet_init();
    test_kernels();
    test_core_functions();
    janet_deinit();
}
