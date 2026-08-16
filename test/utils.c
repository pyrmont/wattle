#include <assert.h>
#include <limits.h>
#include <stdint.h>
#include "util.h"

int main(void) {
    static const uint8_t a[] = {'a'};
    static const uint8_t hello[] = {'h', 'e', 'l', 'l', 'o'};
    static const uint8_t embedded_nul[] = {'J', 'a', 'n', 'e', 't', 0, 'Z'};

    assert(janet_hash_mix(0, 0) == UINT32_C(0x53a3c667));
    assert(janet_hash_mix(1, 2) == UINT32_C(0x53a3d6f6));
    assert(janet_hash_mix(UINT32_MAX, UINT32_MAX) == UINT32_C(0x9c5c4a29));

#ifndef JANET_PRF
    assert(janet_string_calchash(NULL, 0) == 5381);
    assert(janet_string_calchash(a, sizeof(a)) == INT32_C(2136581281));
    assert(janet_string_calchash(hello, sizeof(hello)) == INT32_C(1719582043));
    assert(janet_string_calchash(embedded_nul, sizeof(embedded_nul)) == INT32_C(-1777808027));
#else
    {
        uint8_t key[JANET_HASH_KEY_SIZE] = {0, 1, 2, 3, 4, 5, 6, 7};
        janet_init_hash_key(key);
        assert(janet_string_calchash(a, sizeof(a)) == INT32_C(1520149057));
        assert(janet_string_calchash(hello, sizeof(hello)) == INT32_C(1601058579));
        assert(janet_string_calchash(embedded_nul, sizeof(embedded_nul)) == -INT32_C(1601329231));
    }
#endif

    assert(janet_tablen(-1) == 0);
    assert(janet_tablen(0) == 1);
    assert(janet_tablen(1) == 2);
    assert(janet_tablen(2) == 4);
    assert(janet_tablen(3) == 4);
    assert(janet_tablen(1024) == 2048);
    assert(janet_tablen(INT32_MAX) == INT32_MAX);
    return 0;
}
