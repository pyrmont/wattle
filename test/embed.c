#include <janet.h>

int main(void) {
    JanetTable *env;
    Janet result;

    if (janet_init()) return 1;
    env = janet_core_env(NULL);
    if (janet_dostring(env, "(+ 20 22)", "embed-test", &result)) {
        janet_deinit();
        return 2;
    }
    if (!janet_checkint(result) || janet_unwrap_integer(result) != 42) {
        janet_deinit();
        return 3;
    }
    janet_deinit();
    return 0;
}
