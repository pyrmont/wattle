//! The bytecode verifier, and the instruction table it reads.
//!
//! `verify` is the gate every funcdef passes before it can be run: the
//! assembler's output, and anything the unmarshaller produces. It reports a
//! numbered `Verdict` rather than a message, so `test/verify.zig` is written
//! against numbers.
//!
//! What each check is depends on the opcode's operand shape, and that comes
//! from `instructions` at the foot of this file. The table is here rather than
//! with the assembler because `bytecode.zig` and `bytecode/disasm.zig` are
//! both gated on `-Dassembler` and this file is not, so a build without the
//! assembler still needs it.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const constants = @import("constants");
const functions = @import("../value/functions.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// The operand shape of every opcode, read by `verify`, by both assembler
/// directions, and by the disassembler.
///
/// Built from `rows` at comptime, so it lands in read-only data. The loop
/// places each row by the opcode it names and refuses to compile if any opcode
/// is missed or written twice.
pub const instructions: [constants.Opcode.count]constants.InstructionType = build: {
    var table: [constants.Opcode.count]constants.InstructionType = undefined;
    var filled = [_]bool{false} ** constants.Opcode.count;
    for (rows) |row| {
        if (filled[row.op.number()]) {
            @compileError("instructions: opcode listed twice");
        }
        filled[row.op.number()] = true;
        table[row.op.number()] = row.type;
    }
    for (filled, 0..) |present, opcode| {
        if (!present) {
            @compileError("instructions: no row for opcode " ++
                std.fmt.comptimePrint("{d}", .{opcode}));
        }
    }
    break :build table;
};

/// One row of `instructions`: an opcode and its operand shape.
///
/// Each row names its opcode. A table of bare initialisers with the opcode in
/// a trailing comment shifts silently when an opcode is inserted in the
/// middle, and a comment no compiler reads is what says otherwise.
const rows = [_]Row{
    .{ .op = constants.Opcode.noop, .type = constants.InstructionType.zero },
    .{ .op = constants.Opcode.@"error", .type = constants.InstructionType.s },
    .{ .op = constants.Opcode.typecheck, .type = constants.InstructionType.st },
    .{ .op = constants.Opcode.@"return", .type = constants.InstructionType.s },
    .{ .op = constants.Opcode.return_nil, .type = constants.InstructionType.zero },
    .{ .op = constants.Opcode.add_immediate, .type = constants.InstructionType.ssi },
    .{ .op = constants.Opcode.add, .type = constants.InstructionType.sss },
    .{ .op = constants.Opcode.subtract_immediate, .type = constants.InstructionType.ssi },
    .{ .op = constants.Opcode.subtract, .type = constants.InstructionType.sss },
    .{ .op = constants.Opcode.multiply_immediate, .type = constants.InstructionType.ssi },
    .{ .op = constants.Opcode.multiply, .type = constants.InstructionType.sss },
    .{ .op = constants.Opcode.divide_immediate, .type = constants.InstructionType.ssi },
    .{ .op = constants.Opcode.divide, .type = constants.InstructionType.sss },
    .{ .op = constants.Opcode.divide_floor, .type = constants.InstructionType.sss },
    .{ .op = constants.Opcode.modulo, .type = constants.InstructionType.sss },
    .{ .op = constants.Opcode.remainder, .type = constants.InstructionType.sss },
    .{ .op = constants.Opcode.band, .type = constants.InstructionType.sss },
    .{ .op = constants.Opcode.bor, .type = constants.InstructionType.sss },
    .{ .op = constants.Opcode.bxor, .type = constants.InstructionType.sss },
    .{ .op = constants.Opcode.bnot, .type = constants.InstructionType.ss },
    .{ .op = constants.Opcode.shift_left, .type = constants.InstructionType.sss },
    .{ .op = constants.Opcode.shift_left_immediate, .type = constants.InstructionType.ssi },
    .{ .op = constants.Opcode.shift_right, .type = constants.InstructionType.sss },
    .{ .op = constants.Opcode.shift_right_immediate, .type = constants.InstructionType.ssi },
    .{ .op = constants.Opcode.shift_right_unsigned, .type = constants.InstructionType.sss },
    .{ .op = constants.Opcode.shift_right_unsigned_immediate, .type = constants.InstructionType.ssu },
    .{ .op = constants.Opcode.move_far, .type = constants.InstructionType.ss },
    .{ .op = constants.Opcode.move_near, .type = constants.InstructionType.ss },
    .{ .op = constants.Opcode.jump, .type = constants.InstructionType.l },
    .{ .op = constants.Opcode.jump_if, .type = constants.InstructionType.sl },
    .{ .op = constants.Opcode.jump_if_not, .type = constants.InstructionType.sl },
    .{ .op = constants.Opcode.jump_if_nil, .type = constants.InstructionType.sl },
    .{ .op = constants.Opcode.jump_if_not_nil, .type = constants.InstructionType.sl },
    .{ .op = constants.Opcode.greater_than, .type = constants.InstructionType.sss },
    .{ .op = constants.Opcode.greater_than_immediate, .type = constants.InstructionType.ssi },
    .{ .op = constants.Opcode.less_than, .type = constants.InstructionType.sss },
    .{ .op = constants.Opcode.less_than_immediate, .type = constants.InstructionType.ssi },
    .{ .op = constants.Opcode.equals, .type = constants.InstructionType.sss },
    .{ .op = constants.Opcode.equals_immediate, .type = constants.InstructionType.ssi },
    .{ .op = constants.Opcode.compare, .type = constants.InstructionType.sss },
    .{ .op = constants.Opcode.load_nil, .type = constants.InstructionType.s },
    .{ .op = constants.Opcode.load_true, .type = constants.InstructionType.s },
    .{ .op = constants.Opcode.load_false, .type = constants.InstructionType.s },
    .{ .op = constants.Opcode.load_integer, .type = constants.InstructionType.si },
    .{ .op = constants.Opcode.load_constant, .type = constants.InstructionType.sc },
    .{ .op = constants.Opcode.load_upvalue, .type = constants.InstructionType.ses },
    .{ .op = constants.Opcode.load_self, .type = constants.InstructionType.s },
    .{ .op = constants.Opcode.set_upvalue, .type = constants.InstructionType.ses },
    .{ .op = constants.Opcode.closure, .type = constants.InstructionType.sd },
    .{ .op = constants.Opcode.push, .type = constants.InstructionType.s },
    .{ .op = constants.Opcode.push_2, .type = constants.InstructionType.ss },
    .{ .op = constants.Opcode.push_3, .type = constants.InstructionType.sss },
    .{ .op = constants.Opcode.push_array, .type = constants.InstructionType.s },
    .{ .op = constants.Opcode.call, .type = constants.InstructionType.ss },
    .{ .op = constants.Opcode.tailcall, .type = constants.InstructionType.s },
    .{ .op = constants.Opcode.@"resume", .type = constants.InstructionType.sss },
    .{ .op = constants.Opcode.signal, .type = constants.InstructionType.ssu },
    .{ .op = constants.Opcode.propagate, .type = constants.InstructionType.sss },
    .{ .op = constants.Opcode.in, .type = constants.InstructionType.sss },
    .{ .op = constants.Opcode.get, .type = constants.InstructionType.sss },
    .{ .op = constants.Opcode.put, .type = constants.InstructionType.sss },
    .{ .op = constants.Opcode.get_index, .type = constants.InstructionType.ssu },
    .{ .op = constants.Opcode.put_index, .type = constants.InstructionType.ssu },
    .{ .op = constants.Opcode.length, .type = constants.InstructionType.ss },
    .{ .op = constants.Opcode.make_array, .type = constants.InstructionType.s },
    .{ .op = constants.Opcode.make_buffer, .type = constants.InstructionType.s },
    .{ .op = constants.Opcode.make_string, .type = constants.InstructionType.s },
    .{ .op = constants.Opcode.make_map, .type = constants.InstructionType.s },
    .{ .op = constants.Opcode.make_table, .type = constants.InstructionType.s },
    .{ .op = constants.Opcode.make_tuple, .type = constants.InstructionType.s },
    .{ .op = constants.Opcode.make_vector, .type = constants.InstructionType.s },
    .{ .op = constants.Opcode.greater_than_equal, .type = constants.InstructionType.sss },
    .{ .op = constants.Opcode.less_than_equal, .type = constants.InstructionType.sss },
    .{ .op = constants.Opcode.next, .type = constants.InstructionType.sss },
    .{ .op = constants.Opcode.not_equals, .type = constants.InstructionType.sss },
    .{ .op = constants.Opcode.not_equals_immediate, .type = constants.InstructionType.ssi },
    .{ .op = constants.Opcode.cancel, .type = constants.InstructionType.sss },
    .{ .op = constants.Opcode.jump_if_not_arity, .type = constants.InstructionType.il },
};

// ==========================================================================
// Types
// ==========================================================================

/// A row of `rows`: an opcode and the operand shape its instruction word has.
const Row = struct { op: constants.Opcode, type: constants.InstructionType };

/// What `verify` found, and the number `"invalid assembly (%d)"` prints.
///
/// The numbers are user-visible, so each is written out and none may move: a
/// Janet program that assembles bad bytecode sees the figure in the message,
/// and `test/verify.zig` asserts one per case. The type is what makes the
/// fifteen returns readable at the site, `return .no_such_constant` rather
/// than `return 7`, and what makes a sixteenth check have to name itself.
pub const Verdict = enum(u8) {
    ok = 0,
    no_bytecode = 1,
    arity_exceeds_slots = 2,
    unknown_opcode = 3,
    slot_out_of_range = 4,
    jump_out_of_range = 5,
    no_such_subdef = 6,
    no_such_constant = 7,
    no_such_environment = 8,
    does_not_terminate = 9,
    symbol_environment_out_of_range = 10,
    symbol_slot_out_of_range = 11,
    symbol_birth_out_of_range = 12,
    symbol_death_out_of_range = 13,
    symbol_has_no_name = 14,

    /// This verdict's number, which is what the message renders.
    pub inline fn number(self: Verdict) u8 {
        return @intFromEnum(self);
    }
};

// ==========================================================================
// Public functions
// ==========================================================================

/// Checks that `definition`'s bytecode is safe to run, and reports what is
/// wrong where it is not.
///
/// Every slot reference is checked against the slot count, every jump against
/// the bytecode length, every constant, subdefinition and environment index
/// against its own array, and the last instruction against the set that may
/// end a function. The symbol map is checked last.
pub fn verify(definition: *functions.FuncDef) Verdict {
    const varargs: i32 = @intFromBool(definition.flags.vararg);
    const maximum_argument_slot = definition.arity + varargs;
    const slot_count = definition.slotcount;
    const bytecode_length = definition.bytecode_length;

    if (bytecode_length == 0) return .no_bytecode;
    if (maximum_argument_slot > slot_count) return .arity_exceeds_slots;

    for (definition.instructions(), 0..) |instruction, index| {
        const opcode = instruction & 0x7f;
        if (opcode >= constants.Opcode.count) return .unknown_opcode;
        const instruction_type = instructions[opcode];
        switch (instruction_type) {
            constants.InstructionType.zero => {},
            constants.InstructionType.s => if (@as(i32, @intCast(instruction >> 8)) >= slot_count) return .slot_out_of_range,
            constants.InstructionType.si, constants.InstructionType.su, constants.InstructionType.st => if (slotA(instruction) >= slot_count) return .slot_out_of_range,
            constants.InstructionType.l => {
                const destination = @as(i32, @intCast(index)) + signedField(instruction, 8);
                if (destination < 0 or destination >= bytecode_length) return .jump_out_of_range;
            },
            constants.InstructionType.ss => if (slotA(instruction) >= slot_count or @as(i32, @intCast(instruction >> 16)) >= slot_count) return .slot_out_of_range,
            constants.InstructionType.ssi, constants.InstructionType.ssu => if (slotA(instruction) >= slot_count or slotB(instruction) >= slot_count) return .slot_out_of_range,
            constants.InstructionType.sl => {
                if (slotA(instruction) >= slot_count) return .slot_out_of_range;
                const destination = @as(i32, @intCast(index)) + signedField(instruction, 16);
                if (destination < 0 or destination >= bytecode_length) return .jump_out_of_range;
            },
            constants.InstructionType.il => {
                const destination = @as(i32, @intCast(index)) + signedField(instruction, 16);
                if (destination < 0 or destination >= bytecode_length) return .jump_out_of_range;
            },
            constants.InstructionType.sss => if (slotA(instruction) >= slot_count or slotB(instruction) >= slot_count or slotC(instruction) >= slot_count) return .slot_out_of_range,
            constants.InstructionType.sd => {
                if (slotA(instruction) >= slot_count) return .slot_out_of_range;
                if (@as(i32, @intCast(instruction >> 16)) >= definition.defs_length) return .no_such_subdef;
            },
            constants.InstructionType.sc => {
                if (slotA(instruction) >= slot_count) return .slot_out_of_range;
                if (@as(i32, @intCast(instruction >> 16)) >= definition.constants_length) return .no_such_constant;
            },
            constants.InstructionType.ses => {
                if (slotA(instruction) >= slot_count) return .slot_out_of_range;
                if (slotB(instruction) >= definition.environments_length) return .no_such_environment;
            },
        }
    }

    // `& 0x7F` for the same reason the operand loop above masks: bit 7 of an
    // instruction word is the breakpoint flag, not part of the opcode. A
    // breakpoint is set on a function that already verified, so it may not
    // decide whether that function verifies.
    const last = definition.instructions()[@intCast(bytecode_length - 1)];
    switch (constants.Opcode.fromWord(last & 0x7F)) {
        .@"return", .return_nil, .jump, .@"error", .tailcall => {},
        else => return .does_not_terminate,
    }

    var symbol_index = definition.symbolmap_length;
    while (symbol_index > 0) {
        symbol_index -= 1;
        const symbol = definition.symbols()[@intCast(symbol_index)];
        if (symbol.birth_pc == std.math.maxInt(u32)) {
            if (symbol.death_pc >= definition.environments_length) return .symbol_environment_out_of_range;
        } else {
            if (symbol.slot_index >= slot_count) return .symbol_slot_out_of_range;
            if (symbol.birth_pc >= bytecode_length) return .symbol_birth_out_of_range;
            if (symbol.death_pc != std.math.maxInt(u32) and symbol.death_pc > bytecode_length) return .symbol_death_out_of_range;
        }
        if (symbol.symbol == null) return .symbol_has_no_name;
    }
    return .ok;
}

// ==========================================================================
// Private functions
// ==========================================================================

/// A signed instruction field, as an arithmetic right shift of the word
/// reinterpreted as a signed 32-bit integer.
fn signedField(instruction: u32, comptime shift: u5) i32 {
    return @as(i32, @bitCast(instruction)) >> shift;
}

/// The instruction word's first slot field.
fn slotA(instruction: u32) i32 {
    return @intCast((instruction >> 8) & 0xff);
}

/// The instruction word's second slot field.
fn slotB(instruction: u32) i32 {
    return @intCast((instruction >> 16) & 0xff);
}

/// The instruction word's third slot field.
fn slotC(instruction: u32) i32 {
    return @intCast(instruction >> 24);
}
