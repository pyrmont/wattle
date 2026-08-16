#include <assert.h>
#include <stdint.h>
#include <janet.h>
#include "vector.h"

int main(void) {
    int32_t *vector = NULL;
    int32_t i;

    janet_init();
    assert(janet_v_count(vector) == 0);

    for (i = 0; i < 1024; i++) {
        janet_v_push(vector, i * 3);
    }

    assert(janet_v_count(vector) == 1024);
    for (i = 0; i < 1024; i++) {
        assert(vector[i] == i * 3);
    }

    {
        int32_t *flat = janet_v_flatten(vector);
        assert(flat != NULL);
        for (i = 0; i < 1024; i++) {
            assert(flat[i] == vector[i]);
        }
        janet_free(flat);
    }

    janet_v_free(vector);
    janet_deinit();
    return 0;
}
