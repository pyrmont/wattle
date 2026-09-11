//! Behavioral contract for the compiler's register allocator.
//!
//! Nothing in Janet names a register. The allocator is reached only from the
//! compiler, and the states worth asserting arise from bytecode shapes rather
//! than from source shapes, so the suites cannot aim at them: a freed register
//! handed out again, a clone diverging from its original, and the temporary
//! registers at the top of the file.
//!
//! The bitset grows in words while `capacity` counts bits, so a fresh
//! allocator reports zero for both counters rather than a preallocated span.
//! Touching register 100 on a clone must not touch it on the original, the
//! clone owning its own allocation from the moment it is made.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const constants = @import("constants");
const expect = @import("expect.zig").expect;
const regalloc = @import("subsystems").regalloc;

// ==========================================================================
// Constants
// ==========================================================================

/// The last of the eight temporaries, chosen because it is the one whose
/// register number the allocator computes rather than assigns: 0xf3 is
/// `JANETC_REGTEMP_3` counted down from the top of the 0xff range.
const temp_0 = constants.RegisterTemp.t0;
const temp_3 = constants.RegisterTemp.t3;

// ==========================================================================
// Cases
// ==========================================================================

fn check(allocator: *regalloc.RegisterAllocator, register: u32) bool {
    return allocator.isTaken(register);
}

fn theEmptyAllocator() void {
    var allocator: regalloc.RegisterAllocator = .{};
    defer allocator.deinit();

    expect(allocator.chunks.items.len == 0);
    expect(allocator.chunks.capacity == 0);

    // Handed out in order, and a freed one is handed out again before any
    // higher number is.
    expect(allocator.allocate() == 0);
    expect(allocator.allocate() == 1);
    allocator.free(0);
    expect(allocator.allocate() == 0);

    // `touch` marks a register used without allocating around it, which is how
    // the compiler reserves a slot it has already decided on.
    allocator.touch(100);
    expect(check(&allocator, 100));
    expect(!check(&allocator, 101));
}

fn aCloneOwnsItsOwnBits() void {
    var allocator: regalloc.RegisterAllocator = .{};
    defer allocator.deinit();

    allocator.touch(100);

    var clone = allocator.clone();
    defer clone.deinit();

    expect(clone.chunks.items.len == allocator.chunks.items.len);
    expect(std.mem.eql(u32, clone.chunks.items, allocator.chunks.items));
    expect(clone.max == allocator.max);
    // The temporaries are *not* copied across: a clone starts with none
    // reserved, the scope that reserved them being the one left behind.
    expect(clone.regtemps == 0);

    clone.touch(101);
    expect(check(&clone, 101));
    expect(!check(&allocator, 101));
}

fn theTemporariesSitAboveTheOrdinaryRegisters() void {
    var allocator: regalloc.RegisterAllocator = .{};
    defer allocator.deinit();

    // 240 ordinary registers first, so that the temporary cannot come from the
    // ordinary pool by accident.
    for (0..240) |i| {
        expect(allocator.allocate() == @as(u32, @intCast(i)));
    }

    expect(allocator.allocateTemp(temp_3) == 0xf3);
    expect(allocator.max == 0xf3);

    allocator.freeTemp(0xf3, temp_3);
    expect(allocator.regtemps == 0);

    // The reserved block is not in the bitmap, so releasing a temporary that
    // came from it releases nothing: 0xf0 is the first of those, and it stays
    // taken. A register handed back here would be handed out again as an
    // ordinary one and collide with the temporary still using it.
    expect(check(&allocator, 0xf0));
    expect(allocator.allocateTemp(temp_0) == 0xf0);
    allocator.freeTemp(0xf0, temp_0);
    expect(check(&allocator, 0xf0));
    expect(allocator.allocate() != 0xf0);
}

// ==========================================================================
// Entry
// ==========================================================================

pub fn run() void {
    theEmptyAllocator();
    aCloneOwnsItsOwnBits();
    theTemporariesSitAboveTheOrdinaryRegisters();
}
