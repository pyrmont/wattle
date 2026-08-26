//! Behavioral contract for `janet_bytecode_remove_noops`, the compaction pass
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
const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");

/// `JOP_JUMP`'s offset is a signed 24-bit field in the top three bytes, so a
/// backward jump is written as a wrapped `u32`.
fn jump(offset: i32) u32 {
    // `JOP_JUMP` translates as a `c_int`, and the offset is the top three
    // bytes of a `u32`, so both halves are widened before they are joined.
    const opcode: u32 = constants.JOP_JUMP;
    return opcode | (@as(u32, @bitCast(offset)) << 8);
}

fn theThreeTablesMoveTogether() void {
    const count = 6;
    const bytecode: [*]u32 = @ptrCast(@alignCast(utils.malloc(count * @sizeOf(u32)).?));
    const source_map: [*]types.JanetSourceMapping =
        @ptrCast(@alignCast(utils.malloc(count * @sizeOf(types.JanetSourceMapping)).?));
    var symbols: [2]types.JanetSymbolMap = @splat(std.mem.zeroes(types.JanetSymbolMap));

    bytecode[0] = constants.JOP_NOOP;
    bytecode[1] = constants.JOP_LOAD_NIL;
    bytecode[2] = constants.JOP_JUMP_IF | (@as(u32, 2) << 8) | (@as(u32, 3) << 16);
    bytecode[3] = constants.JOP_NOOP;
    bytecode[4] = jump(-3);
    bytecode[5] = constants.JOP_RETURN_NIL;

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

    var definition: types.JanetFuncDef = std.mem.zeroes(types.JanetFuncDef);
    definition.bytecode = bytecode;
    definition.bytecode_length = count;
    definition.sourcemap = source_map;
    definition.symbolmap = &symbols;
    definition.symbolmap_length = symbols.len;

    remove_noops.bytecodeRemoveNoops(&definition);

    std.debug.assert(definition.bytecode_length == 4);
    std.debug.assert(definition.bytecode.?[0] == constants.JOP_LOAD_NIL);
    std.debug.assert(definition.bytecode.?[1] ==
        (constants.JOP_JUMP_IF | (@as(u32, 2) << 8) | (@as(u32, 2) << 16)));
    std.debug.assert(definition.bytecode.?[2] == jump(-2));
    std.debug.assert(definition.bytecode.?[3] == constants.JOP_RETURN_NIL);

    // Lines 10 and 13 belonged to the two noops and go with them.
    std.debug.assert(definition.sourcemap.?[0].line == 11);
    std.debug.assert(definition.sourcemap.?[1].line == 12);
    std.debug.assert(definition.sourcemap.?[2].line == 14);
    std.debug.assert(definition.sourcemap.?[3].line == 15);

    std.debug.assert(symbols[0].birth_pc == 0);
    std.debug.assert(symbols[0].death_pc == 3);
    std.debug.assert(symbols[1].birth_pc == std.math.maxInt(u32));
    std.debug.assert(symbols[1].death_pc == 0);

    utils.free(@ptrCast(definition.bytecode));
    utils.free(@ptrCast(source_map));
}

/// A function with nothing to remove, and with no source map or symbol map at
/// all. The pass must not walk a null table, and must not reallocate to the
/// same length it already has.
fn aFunctionWithNoNoopsIsUntouched() void {
    const bytecode: [*]u32 = @ptrCast(@alignCast(utils.malloc(@sizeOf(u32)).?));
    bytecode[0] = constants.JOP_RETURN_NIL;

    var definition: types.JanetFuncDef = std.mem.zeroes(types.JanetFuncDef);
    definition.bytecode = bytecode;
    definition.bytecode_length = 1;

    remove_noops.bytecodeRemoveNoops(&definition);

    std.debug.assert(definition.bytecode_length == 1);
    std.debug.assert(definition.bytecode.?[0] == constants.JOP_RETURN_NIL);

    utils.free(@ptrCast(definition.bytecode));
}

/// The runtime is initialised here and by nine sibling contracts it is not,
/// which is the distinction Phase 11 Part 27 had to make the hard way.
///
/// `janet_bytecode_remove_noops` opens with `janet_smalloc` for its pc map, so
/// this subject reaches VM state even though it looks like pure bytecode
/// arithmetic. Without an initialised runtime that call lands on whatever the
/// previous contract's `janet_deinit` left behind, and it left a freed pointer:
/// `FOUND.md` has the bisection, and the no-argument driver run aborted under
/// glibc for eleven parts because of these two missing lines.
pub fn run() void {
    harness.init();
    theThreeTablesMoveTogether();
    aFunctionWithNoNoopsIsUntouched();
    vm_lifecycle.deinit();
}
