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

/* Also Zig, since Phase 10 Part 17g: the five `zig/*` builtins and the line
 * getter are cfunctions, and a cfunction is no longer a C function. What C
 * keeps here is the try scope they are defined inside. */
Janet janet_zig_line_getter_value(void);
void janet_zig_interop_defs(JanetTable *env);

/* Implemented by the C safety bridge. */
int janet_zig_cli_run(int32_t argc, const char **argv);
JanetSignal janet_zig_interop_register(JanetTable *env, Janet *error);
JanetSignal janet_zig_make_rooted(Janet *out);
void janet_zig_wrap_integer(int32_t value, Janet *out);
JanetFunction *janet_zig_unwrap_function(const Janet *value);

#endif
