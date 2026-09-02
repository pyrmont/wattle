//! Behavioral contract for `bytecode/verify.zig`'s `verify`, the bytecode
//! validator.
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
//! ## The breakpoint bit is not part of an opcode
//!
//! Bit 7 of an instruction word is the breakpoint flag, and every lookup in
//! the verifier masks it off. A breakpoint is set on bytecode that already
//! verified, so wherever it is set it must leave the verdict alone -- on the
//! last instruction as much as on any other.

const std = @import("std");
const constants = @import("constants");
const harness = @import("harness.zig");
const verify = @import("subsystems").verify;
const functions = @import("subsystems").value.functions;
const expect = @import("expect.zig").expect;

/// A minimal one-slot, one-argument function over `bytecode`.
fn baseDefinition(bytecode: []u32) functions.FuncDef {
    var definition: functions.FuncDef = std.mem.zeroes(functions.FuncDef);
    definition.bytecode = bytecode.ptr;
    definition.bytecode_length = 1;
    definition.slotcount = 1;
    definition.arity = 1;
    return definition;
}

/// The fifteen numbered refusals, in order. The numbers are the contract.
fn theRefusalsAreNumbered() void {
    var bytecode = [_]u32{ harness.op(constants.Opcode.return_nil), harness.op(constants.Opcode.return_nil) };
    var definition = baseDefinition(&bytecode);

    expect(verify.verify(&definition).number() == 0);

    definition.bytecode_length = 0;
    expect(verify.verify(&definition).number() == 1); // no bytecode

    definition = baseDefinition(&bytecode);
    definition.arity = 2;
    expect(verify.verify(&definition).number() == 2); // arity exceeds slots

    definition = baseDefinition(&bytecode);
    bytecode[0] = 0x7f;
    expect(verify.verify(&definition).number() == 3); // no such opcode
    bytecode[0] = harness.op(constants.Opcode.@"return") | (@as(u32, 1) << 8);
    expect(verify.verify(&definition).number() == 4); // slot out of range
    bytecode[0] = harness.op(constants.Opcode.jump) | (@as(u32, 2) << 8);
    expect(verify.verify(&definition).number() == 5); // jump out of range

    bytecode[0] = harness.op(constants.Opcode.closure) | (@as(u32, 1) << 16);
    expect(verify.verify(&definition).number() == 6); // no such child def
    bytecode[0] = harness.op(constants.Opcode.load_constant) | (@as(u32, 1) << 16);
    expect(verify.verify(&definition).number() == 7); // no such constant
    bytecode[0] = harness.op(constants.Opcode.load_upvalue) | (@as(u32, 1) << 16);
    expect(verify.verify(&definition).number() == 8); // no such environment
    bytecode[0] = harness.op(constants.Opcode.noop);
    expect(verify.verify(&definition).number() == 9); // does not terminate

    theSymbolMapRefusals(&bytecode, &definition);
}

/// Refusals 10 to 14, which are all about one symbol-map row.
fn theSymbolMapRefusals(bytecode: []u32, definition: *functions.FuncDef) void {
    bytecode[0] = harness.op(constants.Opcode.return_nil);

    var name = [_:0]u8{'x'};
    var symbol: functions.SymbolMap = std.mem.zeroes(functions.SymbolMap);
    definition.symbolmap = @ptrCast(&symbol);
    definition.symbolmap_length = 1;

    // The upvalue sentinel is only legal on a definition that has upvalues.
    symbol.birth_pc = std.math.maxInt(u32);
    symbol.death_pc = 0;
    symbol.symbol = &name;
    expect(verify.verify(definition).number() == 10);

    symbol.birth_pc = 0;
    symbol.slot_index = 1;
    expect(verify.verify(definition).number() == 11); // slot out of range

    symbol.slot_index = 0;
    symbol.birth_pc = 1;
    expect(verify.verify(definition).number() == 12); // birth past the end

    symbol.birth_pc = 0;
    symbol.death_pc = 2;
    expect(verify.verify(definition).number() == 13); // death past the end

    symbol.death_pc = 1;
    symbol.symbol = null;
    expect(verify.verify(definition).number() == 14); // no name
}

/// Every row names a shape the validator knows. This does not check *which*
/// shape each opcode has -- the cases below do that -- only that no row is
/// blank or out of range, which is what a truncated or misaligned table looks
/// like. Asserted on the stored number rather than on the enum, so that the
/// table is still checked against the fourteen values C had rather than
/// against whatever `InstructionType` happens to declare.
fn everyRowIsAShape() void {
    var op: i32 = 0;
    while (op < constants.Opcode.count) : (op += 1) {
        const shape = @intFromEnum(verify.instructions[@intCast(op)]);
        expect(shape <= 13);
    }
}

/// Each pair below is two opcodes whose rows differ in one field, and a word
/// that is valid under one and refused by the other.
fn theShapesDisagreeWhereTheyShould() void {
    var bytecode = [_]u32{ harness.op(constants.Opcode.return_nil), harness.op(constants.Opcode.return_nil) };
    var definition = baseDefinition(&bytecode);
    definition.arity = 0;
    definition.slotcount = 2;
    definition.bytecode_length = 2;

    // JINT_0 reads no operands at all, so a word whose upper bytes would be
    // bad slots under any other shape still verifies. A row shifted onto
    // `JOP_NOOP` breaks exactly this.
    bytecode[0] = harness.op(constants.Opcode.noop) | (@as(u32, 200) << 8) | (@as(u32, 200) << 16) | (@as(u32, 200) << 24);
    expect(verify.verify(&definition).number() == 0);

    // JINT_SSS checks all three slots, including the third. JINT_SS passes it.
    bytecode[0] = harness.op(constants.Opcode.add) | (@as(u32, 1) << 16) | (@as(u32, 9) << 24);
    expect(verify.verify(&definition).number() == 4);

    // JINT_SSI's third byte is an immediate rather than a slot, so the same
    // word is fine.
    bytecode[0] = harness.op(constants.Opcode.add_immediate) | (@as(u32, 1) << 16) | (@as(u32, 9) << 24);
    expect(verify.verify(&definition).number() == 0);

    // JINT_SL checks the slot first and the displacement second, so the two
    // refusals are distinguishable.
    bytecode[0] = harness.op(constants.Opcode.jump_if) | (@as(u32, 9) << 8);
    expect(verify.verify(&definition).number() == 4);
    bytecode[0] = harness.op(constants.Opcode.jump_if) | (@as(u32, 500) << 16);
    expect(verify.verify(&definition).number() == 5);
    bytecode[0] = harness.op(constants.Opcode.jump_if) | (@as(u32, 1) << 16);
    expect(verify.verify(&definition).number() == 0);

    // JINT_SES reads an environment index where JINT_SSS would read a slot,
    // so the refusal is 8 rather than 4.
    bytecode[0] = harness.op(constants.Opcode.set_upvalue) | (@as(u32, 1) << 16);
    expect(verify.verify(&definition).number() == 8);

    // JINT_ST's second field is a type mask, not a slot or an index, so a
    // value far outside any slot range is still valid.
    bytecode[0] = harness.op(constants.Opcode.typecheck) | (@as(u32, 0xFFFF) << 16);
    expect(verify.verify(&definition).number() == 0);
}

/// A breakpoint is invisible to the verifier wherever it is set; see the
/// header comment.
fn aBreakpointDoesNotChangeTheVerdict() void {
    var bytecode = [_]u32{ harness.op(constants.Opcode.return_nil), harness.op(constants.Opcode.return_nil) };
    var definition = baseDefinition(&bytecode);
    definition.arity = 0;
    definition.slotcount = 2;
    definition.bytecode_length = 2;

    // Anywhere but last.
    bytecode[0] = harness.op(constants.Opcode.load_integer) | @as(u32, 0x80);
    bytecode[1] = harness.op(constants.Opcode.return_nil);
    expect(verify.verify(&definition).number() == 0);

    // On the terminator, which is the case the mask decides.
    bytecode[1] = harness.op(constants.Opcode.return_nil) | @as(u32, 0x80);
    expect(verify.verify(&definition).number() == 0);

    // On both.
    bytecode[0] = harness.op(constants.Opcode.load_integer) | @as(u32, 0x80);
    expect(verify.verify(&definition).number() == 0);

    // And the check the mask must not disarm: a last instruction that is
    // genuinely not a terminator is still refusal 9, breakpoint or not.
    bytecode[1] = harness.op(constants.Opcode.load_integer) | @as(u32, 0x80);
    expect(verify.verify(&definition).number() == 9);
    bytecode[1] = harness.op(constants.Opcode.load_integer);
    expect(verify.verify(&definition).number() == 9);
}

/// Five opcodes end a function and nothing else does.
fn theFiveTerminators() void {
    var bytecode = [_]u32{ harness.op(constants.Opcode.return_nil), harness.op(constants.Opcode.return_nil) };
    var definition = baseDefinition(&bytecode);
    definition.arity = 0;
    definition.slotcount = 2;

    for ([_]constants.Opcode{
        constants.Opcode.@"return",
        constants.Opcode.return_nil,
        constants.Opcode.jump,
        constants.Opcode.@"error",
        constants.Opcode.tailcall,
    }) |ender| {
        bytecode[0] = harness.op(ender);
        expect(verify.verify(&definition).number() == 0);
    }

    bytecode[0] = harness.op(constants.Opcode.load_nil);
    expect(verify.verify(&definition).number() == 9);
}

pub fn run() void {
    theRefusalsAreNumbered();
    everyRowIsAShape();
    theShapesDisagreeWhereTheyShould();
    aBreakpointDoesNotChangeTheVerdict();
    theFiveTerminators();
}
