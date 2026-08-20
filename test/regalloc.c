#include <assert.h>
#include "regalloc.h"

void regalloc_contract(void) {
    JanetcRegisterAllocator allocator;
    JanetcRegisterAllocator clone;
    int32_t registers[240];
    int32_t i;

    janetc_regalloc_init(&allocator);
    assert(allocator.count == 0);
    assert(allocator.capacity == 0);
    assert(janetc_regalloc_1(&allocator) == 0);
    assert(janetc_regalloc_1(&allocator) == 1);
    janetc_regalloc_free(&allocator, 0);
    assert(janetc_regalloc_1(&allocator) == 0);

    janetc_regalloc_touch(&allocator, 100);
    assert(janetc_regalloc_check(&allocator, 100));
    assert(!janetc_regalloc_check(&allocator, 101));

    janetc_regalloc_clone(&clone, &allocator);
    assert(clone.count == allocator.count);
    assert(clone.capacity == allocator.capacity);
    assert(clone.max == allocator.max);
    assert(clone.regtemps == 0);
    janetc_regalloc_touch(&clone, 101);
    assert(janetc_regalloc_check(&clone, 101));
    assert(!janetc_regalloc_check(&allocator, 101));
    janetc_regalloc_deinit(&clone);
    janetc_regalloc_deinit(&allocator);

    janetc_regalloc_init(&allocator);
    for (i = 0; i < 240; i++) {
        registers[i] = janetc_regalloc_1(&allocator);
        assert(registers[i] == i);
    }
    assert(janetc_regalloc_temp(&allocator, JANETC_REGTEMP_3) == 0xf3);
    assert(allocator.max == 0xf3);
    janetc_regalloc_freetemp(&allocator, 0xf3, JANETC_REGTEMP_3);
    assert(allocator.regtemps == 0);
    janetc_regalloc_deinit(&allocator);
}
