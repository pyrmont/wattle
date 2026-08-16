#include <stdlib.h>
#include "runtime.h"

JANET_NO_RETURN void janet_zig_out_of_memory(void) {
    JANET_OUT_OF_MEMORY;
    abort();
}
