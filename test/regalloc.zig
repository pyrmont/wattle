//! Behavioral contract for the compiler's register allocator.
//!
//! Nothing in Janet names a register. The allocator is reached only from
//! `compile.c`'s descendants, and the states worth asserting — a freed
//! register being handed out again, a clone diverging from its original, the
//! temporary registers at the top of the file — arise from bytecode shapes
//! rather than from source shapes, so the suites cannot aim at them.
//!
//! The bitset grows in words and `capacity` counts bits, which is why `init`
//! answers zero for both counters rather than a preallocated span, and why
//! touching register 100 on a clone must not touch it on the original: the
//! clone owns its own allocation from the moment it is made.

const std = @import("std");
const abi = @import("abi");
const c = abi.c;

/// The last of the eight temporaries, chosen because it is the one whose
/// register number the allocator computes rather than assigns: 0xf3 is
/// `JANETC_REGTEMP_3` counted down from the top of the 0xff range.
const temp_3 = c.JANETC_REGTEMP_3;

fn check(allocator: *c.JanetcRegisterAllocator, register: i32) bool {
    return c.janetc_regalloc_check(allocator, register) != 0;
}

fn theEmptyAllocator() void {
    var allocator: c.JanetcRegisterAllocator = undefined;
    c.janetc_regalloc_init(&allocator);
    defer c.janetc_regalloc_deinit(&allocator);

    std.debug.assert(allocator.count == 0);
    std.debug.assert(allocator.capacity == 0);

    // Handed out in order, and a freed one is handed out again before any
    // higher number is.
    std.debug.assert(c.janetc_regalloc_1(&allocator) == 0);
    std.debug.assert(c.janetc_regalloc_1(&allocator) == 1);
    c.janetc_regalloc_free(&allocator, 0);
    std.debug.assert(c.janetc_regalloc_1(&allocator) == 0);

    // `touch` marks a register used without allocating around it, which is how
    // the compiler reserves a slot it has already decided on.
    c.janetc_regalloc_touch(&allocator, 100);
    std.debug.assert(check(&allocator, 100));
    std.debug.assert(!check(&allocator, 101));
}

fn aCloneOwnsItsOwnBits() void {
    var allocator: c.JanetcRegisterAllocator = undefined;
    var clone: c.JanetcRegisterAllocator = undefined;
    c.janetc_regalloc_init(&allocator);
    defer c.janetc_regalloc_deinit(&allocator);

    c.janetc_regalloc_touch(&allocator, 100);

    c.janetc_regalloc_clone(&clone, &allocator);
    defer c.janetc_regalloc_deinit(&clone);

    std.debug.assert(clone.count == allocator.count);
    std.debug.assert(clone.capacity == allocator.capacity);
    std.debug.assert(clone.max == allocator.max);
    // The temporaries are *not* carried across: a clone starts with none held,
    // because the scope that held them is the one being left behind.
    std.debug.assert(clone.regtemps == 0);

    c.janetc_regalloc_touch(&clone, 101);
    std.debug.assert(check(&clone, 101));
    std.debug.assert(!check(&allocator, 101));
}

fn theTemporariesSitAboveTheOrdinaryRegisters() void {
    var allocator: c.JanetcRegisterAllocator = undefined;
    c.janetc_regalloc_init(&allocator);
    defer c.janetc_regalloc_deinit(&allocator);

    // 240 ordinary registers first, so that the temporary cannot come from the
    // ordinary pool by accident.
    for (0..240) |i| {
        std.debug.assert(c.janetc_regalloc_1(&allocator) == @as(i32, @intCast(i)));
    }

    std.debug.assert(c.janetc_regalloc_temp(&allocator, temp_3) == 0xf3);
    std.debug.assert(allocator.max == 0xf3);

    c.janetc_regalloc_freetemp(&allocator, 0xf3, temp_3);
    std.debug.assert(allocator.regtemps == 0);
}

pub fn run() void {
    theEmptyAllocator();
    aCloneOwnsItsOwnBits();
    theTemporariesSitAboveTheOrdinaryRegisters();
}
