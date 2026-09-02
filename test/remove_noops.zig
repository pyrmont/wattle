//! Behavioral contract for `optimize.bytecodeRemoveNoops`, the compaction pass
//! that deletes `JOP_NOOP` and repairs everything that pointed past one.
//!
//! Three tables index the bytecode by program counter, and all three have to
//! move together: the jump offsets inside the instructions, the source map
//! that gives each instruction a line and column, and the symbol map that
//! gives each local a live range. Nothing in Janet can see any of them
//! directly — a program with a stale jump offset does not misbehave subtly, it
//! executes the wrong instruction — so this is asserted on hand-assembled
//! bytecode rather than through the compiler that produces it.
//!
//! ## The shape of the fixture
//!
//! Six instructions, with a `JOP_NOOP` at 0 and another at 3, so that the
//! compaction moves everything after each of them and both a forward and a
//! backward jump have to be adjusted:
//!
//!     pc  instruction                       after compaction
//!     0   JOP_NOOP                          (deleted)
//!     1   JOP_LOAD_NIL                      0
//!     2   JOP_JUMP_IF slot 2, offset +3     1, offset +2
//!     3   JOP_NOOP                          (deleted)
//!     4   JOP_JUMP offset -3                2, offset -2
//!     5   JOP_RETURN_NIL                    3
//!
//! Each jump crosses exactly one deleted instruction, so each offset shrinks
//! by one — which is the smallest fixture that can tell "adjusted" from
//! "left alone" and from "adjusted twice".
//!
//! ## The two symbol-map entries are not the same case twice
//!
//! The first is an ordinary live range and moves with the code. The second is
//! the sentinel the compiler writes for a symbol that never becomes live:
//! `birth_pc` at `UINT32_MAX` and `death_pc` at 0, an inverted range that must
//! be left exactly as it is. A pass that mapped every program counter through
//! the same table would map `UINT32_MAX` to the end of the function and give
//! the symbol a range it never had.

const std = @import("std");
const utils = @import("subsystems").utils;
const remove_noops = @import("subsystems").optimize;
const harness = @import("harness.zig");
const vm_lifecycle = @import("subsystems").lifecycle;
const constants = @import("constants");
const functions = @import("subsystems").value.functions;
const expect = @import("expect.zig").expect;

/// `JOP_JUMP`'s offset is a signed 24-bit field in the top three bytes, so a
/// backward jump is written as a wrapped `u32`.
fn jump(offset: i32) u32 {
    // The opcode is a `u8` and the offset the top three bytes of a `u32`, so
    // both halves are widened before they are joined.
    const opcode: u32 = harness.op(constants.Opcode.jump);
    return opcode | (@as(u32, @bitCast(offset)) << 8);
}

fn theThreeTablesMoveTogether() void {
    const count = 6;
    const bytecode: [*]u32 = @ptrCast(@alignCast(utils.malloc(count * @sizeOf(u32)).?));
    const source_map: [*]functions.SourceMapping =
        @ptrCast(@alignCast(utils.malloc(count * @sizeOf(functions.SourceMapping)).?));
    var symbols: [2]functions.SymbolMap = @splat(std.mem.zeroes(functions.SymbolMap));

    bytecode[0] = harness.op(constants.Opcode.noop);
    bytecode[1] = harness.op(constants.Opcode.load_nil);
    bytecode[2] = harness.op(constants.Opcode.jump_if) | (@as(u32, 2) << 8) | (@as(u32, 3) << 16);
    bytecode[3] = harness.op(constants.Opcode.noop);
    bytecode[4] = jump(-3);
    bytecode[5] = harness.op(constants.Opcode.return_nil);

    // Distinct line and column per instruction, so that a mapping that moved
    // the wrong entry is visible rather than coincidentally right.
    for (0..count) |i| {
        source_map[i].line = @intCast(i + 10);
        source_map[i].column = @intCast(i + 20);
    }

    symbols[0].birth_pc = 1;
    symbols[0].death_pc = 5;
    symbols[1].birth_pc = std.math.maxInt(u32);
    symbols[1].death_pc = 0;

    var definition: functions.FuncDef = std.mem.zeroes(functions.FuncDef);
    definition.bytecode = bytecode;
    definition.bytecode_length = count;
    definition.sourcemap = source_map;
    definition.symbolmap = &symbols;
    definition.symbolmap_length = symbols.len;

    remove_noops.bytecodeRemoveNoops(&definition);

    expect(definition.bytecode_length == 4);
    expect(constants.Opcode.fromWord(definition.instructions()[0]) == constants.Opcode.load_nil);
    expect(definition.instructions()[1] ==
        (harness.op(constants.Opcode.jump_if) | (@as(u32, 2) << 8) | (@as(u32, 2) << 16)));
    expect(definition.instructions()[2] == jump(-2));
    expect(constants.Opcode.fromWord(definition.instructions()[3]) == constants.Opcode.return_nil);

    // Lines 10 and 13 belonged to the two noops and go with them.
    expect(definition.sourceMappings()[0].line == 11);
    expect(definition.sourceMappings()[1].line == 12);
    expect(definition.sourceMappings()[2].line == 14);
    expect(definition.sourceMappings()[3].line == 15);

    expect(symbols[0].birth_pc == 0);
    expect(symbols[0].death_pc == 3);
    expect(symbols[1].birth_pc == std.math.maxInt(u32));
    expect(symbols[1].death_pc == 0);

    utils.free(@ptrCast(definition.bytecode));
    utils.free(@ptrCast(source_map));
}

/// A function with nothing to remove, and with no source map or symbol map at
/// all. The pass must not walk a null table, and must not reallocate to the
/// same length it already has.
fn aFunctionWithNoNoopsIsUntouched() void {
    const bytecode: [*]u32 = @ptrCast(@alignCast(utils.malloc(@sizeOf(u32)).?));
    bytecode[0] = harness.op(constants.Opcode.return_nil);

    var definition: functions.FuncDef = std.mem.zeroes(functions.FuncDef);
    definition.bytecode = bytecode;
    definition.bytecode_length = 1;

    remove_noops.bytecodeRemoveNoops(&definition);

    expect(definition.bytecode_length == 1);
    expect(constants.Opcode.fromWord(definition.instructions()[0]) == constants.Opcode.return_nil);

    utils.free(@ptrCast(definition.bytecode));
}

/// The runtime is initialised here and by nine sibling contracts it is not,
/// which is a distinction this file had to make the hard way.
///
/// `optimize.bytecodeRemoveNoops` opens with `gc.smalloc` for its pc map, so
/// this subject reaches VM state even though it looks like pure bytecode
/// arithmetic. Without an initialised runtime that call lands on whatever the
/// previous contract's teardown left behind, which is how the no-argument
/// driver run aborted under glibc for eleven parts: two missing lines here.
pub fn run() void {
    harness.init();
    theThreeTablesMoveTogether();
    aFunctionWithNoNoopsIsUntouched();
    vm_lifecycle.deinit();
}
