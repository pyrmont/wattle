#ifndef JANET_ZIG_INTEROP_H
#define JANET_ZIG_INTEROP_H

#include <janet.h>

typedef struct {
    uint8_t *bytes;
    int32_t length;
} JanetZigLine;

/* Implemented in Zig. These functions return normally across the C ABI. */
int janet_zig_readline(const char *prompt, JanetZigLine *line);
int janet_zig_dispatch(int32_t operation, int32_t argc, const Janet *argv, Janet *out);

/* Implemented by the C safety bridge. */
Janet janet_zig_line_getter(int32_t argc, Janet *argv);
int janet_zig_cli_run(int32_t argc, const char **argv);
JanetSignal janet_zig_interop_register(JanetTable *env, Janet *error);
JanetSignal janet_zig_make_rooted(Janet *out);
void janet_zig_wrap_integer(int32_t value, Janet *out);
JanetFunction *janet_zig_unwrap_function(const Janet *value);

#endif
