#include <stdlib.h>
#include <stdio.h>
#include "runtime.h"

JANET_NO_RETURN void janet_zig_out_of_memory(void) {
    JANET_OUT_OF_MEMORY;
    abort();
}

JANET_NO_RETURN void janet_zig_fatal(const char *message) {
    fprintf(stderr, "janet abort at %s:%d: %s\n", __FILE__, __LINE__, message);
    abort();
}
