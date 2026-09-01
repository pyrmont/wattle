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

const regalloc = @import("subsystems").regalloc;
const compiler = @import("subsystems").compiler_primitives;
const constants = @import("constants");
const expect = @import("expect.zig").expect;

/// The last of the eight temporaries, chosen because it is the one whose
/// register number the allocator computes rather than assigns: 0xf3 is
/// `JANETC_REGTEMP_3` counted down from the top of the 0xff range.
const temp_3 = constants.JANETC_REGTEMP_3;

fn check(allocator: *compiler.JanetcRegisterAllocator, register: i32) bool {
    return regalloc.regallocCheck(allocator, register);
}

fn theEmptyAllocator() void {
    var allocator: compiler.JanetcRegisterAllocator = undefined;
    regalloc.regallocInit(&allocator);
    defer regalloc.regallocDeinit(&allocator);

    expect(allocator.count == 0);
    expect(allocator.capacity == 0);

    // Handed out in order, and a freed one is handed out again before any
    // higher number is.
    expect(regalloc.regalloc1(&allocator) == 0);
    expect(regalloc.regalloc1(&allocator) == 1);
    regalloc.regallocFree(&allocator, 0);
    expect(regalloc.regalloc1(&allocator) == 0);

    // `touch` marks a register used without allocating around it, which is how
    // the compiler reserves a slot it has already decided on.
    regalloc.regallocTouch(&allocator, 100);
    expect(check(&allocator, 100));
    expect(!check(&allocator, 101));
}

fn aCloneOwnsItsOwnBits() void {
    var allocator: compiler.JanetcRegisterAllocator = undefined;
    var clone: compiler.JanetcRegisterAllocator = undefined;
    regalloc.regallocInit(&allocator);
    defer regalloc.regallocDeinit(&allocator);

    regalloc.regallocTouch(&allocator, 100);

    regalloc.regallocClone(&clone, &allocator);
    defer regalloc.regallocDeinit(&clone);

    expect(clone.count == allocator.count);
    expect(clone.capacity == allocator.capacity);
    expect(clone.max == allocator.max);
    // The temporaries are *not* carried across: a clone starts with none held,
    // because the scope that held them is the one being left behind.
    expect(clone.regtemps == 0);

    regalloc.regallocTouch(&clone, 101);
    expect(check(&clone, 101));
    expect(!check(&allocator, 101));
}

fn theTemporariesSitAboveTheOrdinaryRegisters() void {
    var allocator: compiler.JanetcRegisterAllocator = undefined;
    regalloc.regallocInit(&allocator);
    defer regalloc.regallocDeinit(&allocator);

    // 240 ordinary registers first, so that the temporary cannot come from the
    // ordinary pool by accident.
    for (0..240) |i| {
        expect(regalloc.regalloc1(&allocator) == @as(i32, @intCast(i)));
    }

    expect(regalloc.regallocTemp(&allocator, temp_3) == 0xf3);
    expect(allocator.max == 0xf3);

    regalloc.regallocFreetemp(&allocator, 0xf3, temp_3);
    expect(allocator.regtemps == 0);
}

pub fn run() void {
    theEmptyAllocator();
    aCloneOwnsItsOwnBits();
    theTemporariesSitAboveTheOrdinaryRegisters();
}
