//! The bytecode verifier, and the instruction table it reads.
//!
//! `janet_verify` is the gate every funcdef passes before it can be run: the
//! assembler's output, and anything `unmarshal` produces. It answers a numbered
//! reason rather than a message, so `test/verify.zig` is written against
//! numbers.
//!
//! What each check *is* depends on the opcode's operand shape, and that comes
//! from `janet_instructions` at the foot of this file. It is here rather than
//! with the assembler because `-Dverify` selects this file and nothing else.

const std = @import("std");

const constants = @import("constants");
const functions = @import("../value/functions.zig");

/// What `verify` found, and the number `"invalid assembly (%d)"` prints.
///
/// **The numbers are user-visible**, so each is written out and none may move:
/// a Janet program that assembles bad bytecode sees the figure in the message,
/// and `test/verify.zig` asserts one per case. The type is what makes the
/// fifteen returns readable at the site -- `return .no_such_constant` rather
/// than `return 7` -- and what makes a sixteenth check have to name itself.
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

    pub inline fn number(self: Verdict) u8 {
        return @intFromEnum(self);
    }
};

pub fn verify(definition: *functions.FuncDef) Verdict {
    const varargs: i32 = @intFromBool(definition.flags.vararg);
    const maximum_argument_slot = definition.arity + varargs;
    const slot_count = definition.slotcount;
    const bytecode_length = definition.bytecode_length;

    if (bytecode_length == 0) return .no_bytecode;
    if (maximum_argument_slot > slot_count) return .arity_exceeds_slots;

    for (definition.instructions()[0..@intCast(bytecode_length)], 0..) |instruction, index| {
        const opcode = instruction & 0x7f;
        if (opcode >= constants.Opcode.count) return .unknown_opcode;
        const instruction_type = instructions[opcode];
        switch (instruction_type) {
            constants.JINT_0 => {},
            constants.JINT_S => if (@as(i32, @intCast(instruction >> 8)) >= slot_count) return .slot_out_of_range,
            constants.JINT_SI, constants.JINT_SU, constants.JINT_ST => if (slotA(instruction) >= slot_count) return .slot_out_of_range,
            constants.JINT_L => {
                const destination = @as(i32, @intCast(index)) + signedField(instruction, 8);
                if (destination < 0 or destination >= bytecode_length) return .jump_out_of_range;
            },
            constants.JINT_SS => if (slotA(instruction) >= slot_count or @as(i32, @intCast(instruction >> 16)) >= slot_count) return .slot_out_of_range,
            constants.JINT_SSI, constants.JINT_SSU => if (slotA(instruction) >= slot_count or slotB(instruction) >= slot_count) return .slot_out_of_range,
            constants.JINT_SL => {
                if (slotA(instruction) >= slot_count) return .slot_out_of_range;
                const destination = @as(i32, @intCast(index)) + signedField(instruction, 16);
                if (destination < 0 or destination >= bytecode_length) return .jump_out_of_range;
            },
            constants.JINT_SSS => if (slotA(instruction) >= slot_count or slotB(instruction) >= slot_count or slotC(instruction) >= slot_count) return .slot_out_of_range,
            constants.JINT_SD => {
                if (slotA(instruction) >= slot_count) return .slot_out_of_range;
                if (@as(i32, @intCast(instruction >> 16)) >= definition.defs_length) return .no_such_subdef;
            },
            constants.JINT_SC => {
                if (slotA(instruction) >= slot_count) return .slot_out_of_range;
                if (@as(i32, @intCast(instruction >> 16)) >= definition.constants_length) return .no_such_constant;
            },
            constants.JINT_SES => {
                if (slotA(instruction) >= slot_count) return .slot_out_of_range;
                if (slotB(instruction) >= definition.environments_length) return .no_such_environment;
            },
            else => unreachable,
        }
    }

    switch (constants.Opcode.fromWord(definition.instructions()[@intCast(bytecode_length - 1)])) {
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

fn slotA(instruction: u32) i32 {
    return @intCast((instruction >> 8) & 0xff);
}

fn slotB(instruction: u32) i32 {
    return @intCast((instruction >> 16) & 0xff);
}

fn slotC(instruction: u32) i32 {
    return @intCast(instruction >> 24);
}

fn signedField(instruction: u32, comptime shift: u5) i32 {
    return @as(i32, @bitCast(instruction)) >> shift;
}

// ==========================================================================
// The instruction table
//
// It lives here rather than with the assembler or the disassembler that also
// read it, because the verifier is the one thing that cannot work without it.
//
// **Each row names its opcode.** A table of bare initialisers with the opcode
// in a trailing comment shifts silently when an opcode is inserted in the
// middle, and a comment no compiler reads is what says otherwise. The loop below
// places it by that name and refuses to compile if any opcode is missed or
// written twice. The check costs nothing at run time: `janet_instructions` is
// built at comptime and lands in read-only data exactly as the C array does.
// ==========================================================================

const Row = struct { op: constants.Opcode, type: c_uint };

const rows = [_]Row{
    .{ .op = constants.Opcode.noop, .type = constants.JINT_0 },
    .{ .op = constants.Opcode.@"error", .type = constants.JINT_S },
    .{ .op = constants.Opcode.typecheck, .type = constants.JINT_ST },
    .{ .op = constants.Opcode.@"return", .type = constants.JINT_S },
    .{ .op = constants.Opcode.return_nil, .type = constants.JINT_0 },
    .{ .op = constants.Opcode.add_immediate, .type = constants.JINT_SSI },
    .{ .op = constants.Opcode.add, .type = constants.JINT_SSS },
    .{ .op = constants.Opcode.subtract_immediate, .type = constants.JINT_SSI },
    .{ .op = constants.Opcode.subtract, .type = constants.JINT_SSS },
    .{ .op = constants.Opcode.multiply_immediate, .type = constants.JINT_SSI },
    .{ .op = constants.Opcode.multiply, .type = constants.JINT_SSS },
    .{ .op = constants.Opcode.divide_immediate, .type = constants.JINT_SSI },
    .{ .op = constants.Opcode.divide, .type = constants.JINT_SSS },
    .{ .op = constants.Opcode.divide_floor, .type = constants.JINT_SSS },
    .{ .op = constants.Opcode.modulo, .type = constants.JINT_SSS },
    .{ .op = constants.Opcode.remainder, .type = constants.JINT_SSS },
    .{ .op = constants.Opcode.band, .type = constants.JINT_SSS },
    .{ .op = constants.Opcode.bor, .type = constants.JINT_SSS },
    .{ .op = constants.Opcode.bxor, .type = constants.JINT_SSS },
    .{ .op = constants.Opcode.bnot, .type = constants.JINT_SS },
    .{ .op = constants.Opcode.shift_left, .type = constants.JINT_SSS },
    .{ .op = constants.Opcode.shift_left_immediate, .type = constants.JINT_SSI },
    .{ .op = constants.Opcode.shift_right, .type = constants.JINT_SSS },
    .{ .op = constants.Opcode.shift_right_immediate, .type = constants.JINT_SSI },
    .{ .op = constants.Opcode.shift_right_unsigned, .type = constants.JINT_SSS },
    .{ .op = constants.Opcode.shift_right_unsigned_immediate, .type = constants.JINT_SSU },
    .{ .op = constants.Opcode.move_far, .type = constants.JINT_SS },
    .{ .op = constants.Opcode.move_near, .type = constants.JINT_SS },
    .{ .op = constants.Opcode.jump, .type = constants.JINT_L },
    .{ .op = constants.Opcode.jump_if, .type = constants.JINT_SL },
    .{ .op = constants.Opcode.jump_if_not, .type = constants.JINT_SL },
    .{ .op = constants.Opcode.jump_if_nil, .type = constants.JINT_SL },
    .{ .op = constants.Opcode.jump_if_not_nil, .type = constants.JINT_SL },
    .{ .op = constants.Opcode.greater_than, .type = constants.JINT_SSS },
    .{ .op = constants.Opcode.greater_than_immediate, .type = constants.JINT_SSI },
    .{ .op = constants.Opcode.less_than, .type = constants.JINT_SSS },
    .{ .op = constants.Opcode.less_than_immediate, .type = constants.JINT_SSI },
    .{ .op = constants.Opcode.equals, .type = constants.JINT_SSS },
    .{ .op = constants.Opcode.equals_immediate, .type = constants.JINT_SSI },
    .{ .op = constants.Opcode.compare, .type = constants.JINT_SSS },
    .{ .op = constants.Opcode.load_nil, .type = constants.JINT_S },
    .{ .op = constants.Opcode.load_true, .type = constants.JINT_S },
    .{ .op = constants.Opcode.load_false, .type = constants.JINT_S },
    .{ .op = constants.Opcode.load_integer, .type = constants.JINT_SI },
    .{ .op = constants.Opcode.load_constant, .type = constants.JINT_SC },
    .{ .op = constants.Opcode.load_upvalue, .type = constants.JINT_SES },
    .{ .op = constants.Opcode.load_self, .type = constants.JINT_S },
    .{ .op = constants.Opcode.set_upvalue, .type = constants.JINT_SES },
    .{ .op = constants.Opcode.closure, .type = constants.JINT_SD },
    .{ .op = constants.Opcode.push, .type = constants.JINT_S },
    .{ .op = constants.Opcode.push_2, .type = constants.JINT_SS },
    .{ .op = constants.Opcode.push_3, .type = constants.JINT_SSS },
    .{ .op = constants.Opcode.push_array, .type = constants.JINT_S },
    .{ .op = constants.Opcode.call, .type = constants.JINT_SS },
    .{ .op = constants.Opcode.tailcall, .type = constants.JINT_S },
    .{ .op = constants.Opcode.@"resume", .type = constants.JINT_SSS },
    .{ .op = constants.Opcode.signal, .type = constants.JINT_SSU },
    .{ .op = constants.Opcode.propagate, .type = constants.JINT_SSS },
    .{ .op = constants.Opcode.in, .type = constants.JINT_SSS },
    .{ .op = constants.Opcode.get, .type = constants.JINT_SSS },
    .{ .op = constants.Opcode.put, .type = constants.JINT_SSS },
    .{ .op = constants.Opcode.get_index, .type = constants.JINT_SSU },
    .{ .op = constants.Opcode.put_index, .type = constants.JINT_SSU },
    .{ .op = constants.Opcode.length, .type = constants.JINT_SS },
    .{ .op = constants.Opcode.make_array, .type = constants.JINT_S },
    .{ .op = constants.Opcode.make_buffer, .type = constants.JINT_S },
    .{ .op = constants.Opcode.make_string, .type = constants.JINT_S },
    .{ .op = constants.Opcode.make_struct, .type = constants.JINT_S },
    .{ .op = constants.Opcode.make_table, .type = constants.JINT_S },
    .{ .op = constants.Opcode.make_tuple, .type = constants.JINT_S },
    .{ .op = constants.Opcode.make_bracket_tuple, .type = constants.JINT_S },
    .{ .op = constants.Opcode.greater_than_equal, .type = constants.JINT_SSS },
    .{ .op = constants.Opcode.less_than_equal, .type = constants.JINT_SSS },
    .{ .op = constants.Opcode.next, .type = constants.JINT_SSS },
    .{ .op = constants.Opcode.not_equals, .type = constants.JINT_SSS },
    .{ .op = constants.Opcode.not_equals_immediate, .type = constants.JINT_SSI },
    .{ .op = constants.Opcode.cancel, .type = constants.JINT_SSS },
};

/// The operand shape of every opcode, read by `verify` above, by both assembler
/// directions, and by the disassembler.
pub const instructions: [constants.Opcode.count]c_uint = build: {
    var table: [constants.Opcode.count]c_uint = undefined;
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
            @compileError("janet_instructions: no row for opcode " ++
                std.fmt.comptimePrint("{d}", .{opcode}));
        }
    }
    break :build table;
};
