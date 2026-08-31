//! Behavioral contract for `janet_verify`, the bytecode validator.
//!
//! Every one of its fifteen numbered refusals is a function the compiler will
//! never emit, so nothing written in Janet can reach any of them. They exist
//! for bytecode that arrives from somewhere else — `asm`, an unmarshalled
//! image, a corrupted file — and the numbers are the contract: a caller
//! distinguishes them, so a port that renumbered them would be wrong in a way
//! no suite could see.
//!
//! ## Two halves
//!
//! The first walks the fifteen refusals in order. The second is about the
//! *instruction table*, and it is the more interesting one.
//!
//! The table gives each opcode a shape — which of its operand bytes are slots,
//! which are indices into another table, which are immediates, which are
//! nothing. The C original was seventy-seven bare initialisers with the opcode
//! named only in a trailing comment, so **a row inserted in the middle shifted
//! every row after it and nothing said so**. The Zig table places each row by
//! name, which makes that particular accident impossible; the assertions below
//! are what would have caught it anyway, and they are kept because they check
//! the property rather than the spelling.
//!
//! Each case picks an opcode whose shape differs from its neighbour's in
//! exactly one field, and a word that is valid under one shape and invalid
//! under the other. The table is deliberately **not** restated entry by entry:
//! writing the seventy-seven values out a second time would prove only that
//! two lists were typed the same way.
//!
//! ## One inconsistency is reproduced rather than fixed
//!
//! The dispatch loop masks the breakpoint bit off with `0x7F` before looking
//! an opcode up, and the terminator check masks with `0xFF`. So a breakpoint
//! on the *last* instruction turns a valid function into refusal 9, and a
//! breakpoint anywhere else is invisible. That is the C original's behaviour
//! and `FOUND.md` has the entry; it is asserted here so a port cannot
//! quietly repair it.

const std = @import("std");
const types = @import("types");
const constants = @import("constants");
const harness = @import("harness.zig");
const verify = @import("subsystems").verify;

/// A minimal one-slot, one-argument function over `bytecode`.
fn baseDefinition(bytecode: []u32) types.JanetFuncDef {
    var definition: types.JanetFuncDef = std.mem.zeroes(types.JanetFuncDef);
    definition.bytecode = bytecode.ptr;
    definition.bytecode_length = 1;
    definition.slotcount = 1;
    definition.arity = 1;
    return definition;
}

/// The fifteen numbered refusals, in order. The numbers are the contract.
fn theRefusalsAreNumbered() void {
    var bytecode = [_]u32{ constants.JOP_RETURN_NIL, constants.JOP_RETURN_NIL };
    var definition = baseDefinition(&bytecode);

    std.debug.assert(verify.verify(&definition) == 0);

    definition.bytecode_length = 0;
    std.debug.assert(verify.verify(&definition) == 1); // no bytecode

    definition = baseDefinition(&bytecode);
    definition.arity = 2;
    std.debug.assert(verify.verify(&definition) == 2); // arity exceeds slots

    definition = baseDefinition(&bytecode);
    bytecode[0] = 0x7f;
    std.debug.assert(verify.verify(&definition) == 3); // no such opcode
    bytecode[0] = harness.op(constants.JOP_RETURN) | (@as(u32, 1) << 8);
    std.debug.assert(verify.verify(&definition) == 4); // slot out of range
    bytecode[0] = harness.op(constants.JOP_JUMP) | (@as(u32, 2) << 8);
    std.debug.assert(verify.verify(&definition) == 5); // jump out of range

    bytecode[0] = harness.op(constants.JOP_CLOSURE) | (@as(u32, 1) << 16);
    std.debug.assert(verify.verify(&definition) == 6); // no such child def
    bytecode[0] = harness.op(constants.JOP_LOAD_CONSTANT) | (@as(u32, 1) << 16);
    std.debug.assert(verify.verify(&definition) == 7); // no such constant
    bytecode[0] = harness.op(constants.JOP_LOAD_UPVALUE) | (@as(u32, 1) << 16);
    std.debug.assert(verify.verify(&definition) == 8); // no such environment
    bytecode[0] = constants.JOP_NOOP;
    std.debug.assert(verify.verify(&definition) == 9); // does not terminate

    theSymbolMapRefusals(&bytecode, &definition);
}

/// Refusals 10 to 14, which are all about one symbol-map row.
fn theSymbolMapRefusals(bytecode: []u32, definition: *types.JanetFuncDef) void {
    bytecode[0] = constants.JOP_RETURN_NIL;

    var name = [_:0]u8{'x'};
    var symbol: types.JanetSymbolMap = std.mem.zeroes(types.JanetSymbolMap);
    definition.symbolmap = @ptrCast(&symbol);
    definition.symbolmap_length = 1;

    // The upvalue sentinel is only legal on a definition that has upvalues.
    symbol.birth_pc = std.math.maxInt(u32);
    symbol.death_pc = 0;
    symbol.symbol = &name;
    std.debug.assert(verify.verify(definition) == 10);

    symbol.birth_pc = 0;
    symbol.slot_index = 1;
    std.debug.assert(verify.verify(definition) == 11); // slot out of range

    symbol.slot_index = 0;
    symbol.birth_pc = 1;
    std.debug.assert(verify.verify(definition) == 12); // birth past the end

    symbol.birth_pc = 0;
    symbol.death_pc = 2;
    std.debug.assert(verify.verify(definition) == 13); // death past the end

    symbol.death_pc = 1;
    symbol.symbol = null;
    std.debug.assert(verify.verify(definition) == 14); // no name
}

/// Every row names a shape the validator knows. This does not check *which*
/// shape each opcode has -- the cases below do that -- only that no row is
/// blank or out of range, which is what a truncated or misaligned table looks
/// like.
fn everyRowIsAShape() void {
    var op: i32 = 0;
    while (op < constants.JOP_INSTRUCTION_COUNT) : (op += 1) {
        const shape = verify.instructions[@intCast(op)];
        std.debug.assert(shape >= constants.JINT_0 and shape <= constants.JINT_SC);
    }
}

/// Each pair below is two opcodes whose rows differ in one field, and a word
/// that is valid under one and refused by the other.
fn theShapesDisagreeWhereTheyShould() void {
    var bytecode = [_]u32{ constants.JOP_RETURN_NIL, constants.JOP_RETURN_NIL };
    var definition = baseDefinition(&bytecode);
    definition.arity = 0;
    definition.slotcount = 2;
    definition.bytecode_length = 2;

    // JINT_0 reads no operands at all, so a word whose upper bytes would be
    // bad slots under any other shape still verifies. A row shifted onto
    // `JOP_NOOP` breaks exactly this.
    bytecode[0] = harness.op(constants.JOP_NOOP) | (@as(u32, 200) << 8) | (@as(u32, 200) << 16) | (@as(u32, 200) << 24);
    std.debug.assert(verify.verify(&definition) == 0);

    // JINT_SSS checks all three slots, including the third. JINT_SS passes it.
    bytecode[0] = harness.op(constants.JOP_ADD) | (@as(u32, 1) << 16) | (@as(u32, 9) << 24);
    std.debug.assert(verify.verify(&definition) == 4);

    // JINT_SSI's third byte is an immediate rather than a slot, so the same
    // word is fine.
    bytecode[0] = harness.op(constants.JOP_ADD_IMMEDIATE) | (@as(u32, 1) << 16) | (@as(u32, 9) << 24);
    std.debug.assert(verify.verify(&definition) == 0);

    // JINT_SL checks the slot first and the displacement second, so the two
    // refusals are distinguishable.
    bytecode[0] = harness.op(constants.JOP_JUMP_IF) | (@as(u32, 9) << 8);
    std.debug.assert(verify.verify(&definition) == 4);
    bytecode[0] = harness.op(constants.JOP_JUMP_IF) | (@as(u32, 500) << 16);
    std.debug.assert(verify.verify(&definition) == 5);
    bytecode[0] = harness.op(constants.JOP_JUMP_IF) | (@as(u32, 1) << 16);
    std.debug.assert(verify.verify(&definition) == 0);

    // JINT_SES reads an environment index where JINT_SSS would read a slot,
    // so the refusal is 8 rather than 4.
    bytecode[0] = harness.op(constants.JOP_SET_UPVALUE) | (@as(u32, 1) << 16);
    std.debug.assert(verify.verify(&definition) == 8);

    // JINT_ST's second field is a type mask, not a slot or an index, so a
    // value far outside any slot range is still valid.
    bytecode[0] = harness.op(constants.JOP_TYPECHECK) | (@as(u32, 0xFFFF) << 16);
    std.debug.assert(verify.verify(&definition) == 0);
}

/// The `0x7F` / `0xFF` inconsistency; see the header comment.
fn aBreakpointOnTheLastInstructionIsRefused() void {
    var bytecode = [_]u32{ constants.JOP_RETURN_NIL, constants.JOP_RETURN_NIL };
    var definition = baseDefinition(&bytecode);
    definition.arity = 0;
    definition.slotcount = 2;
    definition.bytecode_length = 2;

    // Anywhere but last: invisible.
    bytecode[0] = harness.op(constants.JOP_LOAD_INTEGER) | @as(u32, 0x80);
    bytecode[1] = constants.JOP_RETURN_NIL;
    std.debug.assert(verify.verify(&definition) == 0);

    // On the terminator: refusal 9, because that check masks with 0xFF.
    bytecode[1] = harness.op(constants.JOP_RETURN_NIL) | @as(u32, 0x80);
    std.debug.assert(verify.verify(&definition) == 9);
}

/// Five opcodes end a function and nothing else does.
fn theFiveTerminators() void {
    var bytecode = [_]u32{ constants.JOP_RETURN_NIL, constants.JOP_RETURN_NIL };
    var definition = baseDefinition(&bytecode);
    definition.arity = 0;
    definition.slotcount = 2;

    for ([_]u32{
        constants.JOP_RETURN,
        constants.JOP_RETURN_NIL,
        constants.JOP_JUMP,
        constants.JOP_ERROR,
        constants.JOP_TAILCALL,
    }) |ender| {
        bytecode[0] = ender;
        std.debug.assert(verify.verify(&definition) == 0);
    }

    bytecode[0] = constants.JOP_LOAD_NIL;
    std.debug.assert(verify.verify(&definition) == 9);
}

pub fn run() void {
    theRefusalsAreNumbered();
    everyRowIsAShape();
    theShapesDisagreeWhereTheyShould();
    aBreakpointOnTheLastInstructionIsRefused();
    theFiveTerminators();
}
