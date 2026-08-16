#include <janet.h>

extern int janet_zig_native_identity(int32_t argc, Janet *argv, Janet *out);

static Janet native_identity(int32_t argc, Janet *argv) {
    Janet result;
    janet_fixarity(argc, 1);
    if (!janet_zig_native_identity(argc, argv, &result)) {
        janet_panic("Zig native identity failed");
    }
    return result;
}

JANET_MODULE_ENTRY(JanetTable *env) {
    janet_def(env, "identity", janet_wrap_cfunction(native_identity),
              "Round-trip a Janet value through a dynamically loaded Zig module.");
}
