#include <stdlib.h>
#include "interop.h"

enum {
    JANET_ZIG_IDENTITY,
    JANET_ZIG_LENGTH,
    JANET_ZIG_CALL,
    JANET_ZIG_ROOTED,
    JANET_ZIG_FAIL
};

static Janet dispatch_or_panic(int32_t operation, int32_t argc, Janet *argv) {
    Janet result;
    if (!janet_zig_dispatch(operation, argc, argv, &result)) {
        janet_panicv(result);
    }
    return result;
}

static Janet zig_identity(int32_t argc, Janet *argv) {
    janet_fixarity(argc, 1);
    return dispatch_or_panic(JANET_ZIG_IDENTITY, argc, argv);
}

static Janet zig_length(int32_t argc, Janet *argv) {
    janet_fixarity(argc, 1);
    if (!janet_checktypes(argv[0], JANET_TFLAG_LENGTHABLE)) {
        janet_panic_type(argv[0], 0, JANET_TFLAG_LENGTHABLE);
    }
    return dispatch_or_panic(JANET_ZIG_LENGTH, argc, argv);
}

static Janet zig_call(int32_t argc, Janet *argv) {
    janet_fixarity(argc, 2);
    if (!janet_checktype(argv[0], JANET_FUNCTION)) {
        janet_panic_type(argv[0], 0, JANET_TFLAG_FUNCTION);
    }
    return dispatch_or_panic(JANET_ZIG_CALL, argc, argv);
}

static Janet zig_rooted(int32_t argc, Janet *argv) {
    janet_fixarity(argc, 0);
    return dispatch_or_panic(JANET_ZIG_ROOTED, argc, argv);
}

static Janet zig_fail(int32_t argc, Janet *argv) {
    janet_fixarity(argc, 1);
    return dispatch_or_panic(JANET_ZIG_FAIL, argc, argv);
}

Janet janet_zig_line_getter(int32_t argc, Janet *argv) {
    janet_arity(argc, 0, 3);
    const char *prompt = argc >= 1 ? (const char *)janet_getstring(argv, 0) : "";
    JanetBuffer *buffer = argc >= 2 ? janet_getbuffer(argv, 1) : janet_buffer(10);
    JanetZigLine line = {NULL, 0};

    buffer->count = 0;
    if (janet_zig_readline(prompt, &line) && line.length > 0) {
        janet_buffer_push_bytes(buffer, line.bytes, line.length);
    }
    free(line.bytes);
    return janet_wrap_buffer(buffer);
}

int janet_zig_cli_run(int32_t argc, const char **argv) {
    Janet error;
    Janet main_function;
    int status = 1;

    if (janet_init()) return 1;

    JanetTable *replacements = janet_table(0);
    janet_table_put(replacements, janet_csymbolv("getline"),
                    janet_wrap_cfunction(janet_zig_line_getter));
    JanetTable *env = janet_core_env(replacements);
    if (janet_zig_interop_register(env, &error) != JANET_SIGNAL_OK) goto cleanup;

    JanetArray *args = janet_array(argc);
    for (int32_t i = 1; i < argc; i++) {
        janet_array_push(args, janet_cstringv(argv[i]));
    }
    janet_table_put(env, janet_ckeywordv("executable"), janet_cstringv(argv[0]));

    if (janet_resolve(env, janet_csymbol("cli-main"), &main_function) == JANET_BINDING_NONE) {
        goto cleanup;
    }

    Janet main_args[1] = {janet_wrap_array(args)};
    JanetFiber *fiber = janet_fiber(janet_unwrap_function(main_function), 64, 1, main_args);
    janet_gcroot(janet_wrap_fiber(fiber));
    fiber->env = env;
    status = janet_loop_fiber(fiber);

cleanup:
    janet_deinit();
    return status;
}

JanetSignal janet_zig_interop_register(JanetTable *env, Janet *error) {
    JanetTryState state;
    JanetSignal signal = janet_try(&state);
    if (signal == JANET_SIGNAL_OK) {
        janet_def(env, "zig/identity", janet_wrap_cfunction(zig_identity),
                  "Round-trip one Janet value through Zig.");
        janet_def(env, "zig/length", janet_wrap_cfunction(zig_length),
                  "Read the length of a Janet collection in Zig.");
        janet_def(env, "zig/call", janet_wrap_cfunction(zig_call),
                  "Call a Janet closure from Zig through janet_pcall.");
        janet_def(env, "zig/rooted", janet_wrap_cfunction(zig_rooted),
                  "Create and root a Janet value across a forced collection.");
        janet_def(env, "zig/fail", janet_wrap_cfunction(zig_fail),
                  "Raise a controlled Janet error after returning from Zig.");
    }
    if (signal != JANET_SIGNAL_OK && error != NULL) *error = state.payload;
    janet_restore(&state);
    return signal;
}

JanetSignal janet_zig_make_rooted(Janet *out) {
    JanetTryState state;
    volatile int rooted = 0;
    volatile Janet value = janet_wrap_nil();
    JanetSignal signal = janet_try(&state);
    if (signal == JANET_SIGNAL_OK) {
        JanetArray *array = janet_array(1);
        value = janet_wrap_array(array);
        janet_gcroot(value);
        rooted = 1;
        janet_array_push(array, janet_cstringv("alive"));
        janet_collect();
        *out = value;
    } else {
        *out = state.payload;
    }
    if (rooted) janet_gcunroot(value);
    janet_restore(&state);
    return signal;
}

void janet_zig_wrap_integer(int32_t value, Janet *out) {
    *out = janet_wrap_integer(value);
}

JanetFunction *janet_zig_unwrap_function(const Janet *value) {
    return janet_unwrap_function(*value);
}
