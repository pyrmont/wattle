#ifndef JANET_ZIG_RUNTIME_H
#define JANET_ZIG_RUNTIME_H

#include <janet.h>

JANET_NO_RETURN void janet_zig_out_of_memory(void);
JANET_NO_RETURN void janet_zig_fatal(const char *message);

#endif
