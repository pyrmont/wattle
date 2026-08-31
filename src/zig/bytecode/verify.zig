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

const types = @import("types");
const constants = @import("constants");

pub fn verify(definition: *types.JanetFuncDef) c_int {
    const varargs: i32 = @intFromBool(definition.flags & constants.JANET_FUNCDEF_FLAG_VARARG != 0);
    const maximum_argument_slot = definition.arity + varargs;
    const slot_count = definition.slotcount;
    const bytecode_length = definition.bytecode_length;

    if (bytecode_length == 0) return 1;
    if (maximum_argument_slot > slot_count) return 2;

    for (definition.instructions()[0..@intCast(bytecode_length)], 0..) |instruction, index| {
        const opcode = instruction & 0x7f;
        if (opcode >= constants.JOP_INSTRUCTION_COUNT) return 3;
        const instruction_type = instructions[opcode];
        switch (instruction_type) {
            constants.JINT_0 => {},
            constants.JINT_S => if (@as(i32, @intCast(instruction >> 8)) >= slot_count) return 4,
            constants.JINT_SI, constants.JINT_SU, constants.JINT_ST => if (slotA(instruction) >= slot_count) return 4,
            constants.JINT_L => {
                const destination = @as(i32, @intCast(index)) + signedField(instruction, 8);
                if (destination < 0 or destination >= bytecode_length) return 5;
            },
            constants.JINT_SS => if (slotA(instruction) >= slot_count or @as(i32, @intCast(instruction >> 16)) >= slot_count) return 4,
            constants.JINT_SSI, constants.JINT_SSU => if (slotA(instruction) >= slot_count or slotB(instruction) >= slot_count) return 4,
            constants.JINT_SL => {
                if (slotA(instruction) >= slot_count) return 4;
                const destination = @as(i32, @intCast(index)) + signedField(instruction, 16);
                if (destination < 0 or destination >= bytecode_length) return 5;
            },
            constants.JINT_SSS => if (slotA(instruction) >= slot_count or slotB(instruction) >= slot_count or slotC(instruction) >= slot_count) return 4,
            constants.JINT_SD => {
                if (slotA(instruction) >= slot_count) return 4;
                if (@as(i32, @intCast(instruction >> 16)) >= definition.defs_length) return 6;
            },
            constants.JINT_SC => {
                if (slotA(instruction) >= slot_count) return 4;
                if (@as(i32, @intCast(instruction >> 16)) >= definition.constants_length) return 7;
            },
            constants.JINT_SES => {
                if (slotA(instruction) >= slot_count) return 4;
                if (slotB(instruction) >= definition.environments_length) return 8;
            },
            else => unreachable,
        }
    }

    switch (definition.instructions()[@intCast(bytecode_length - 1)] & 0xff) {
        constants.JOP_RETURN, constants.JOP_RETURN_NIL, constants.JOP_JUMP, constants.JOP_ERROR, constants.JOP_TAILCALL => {},
        else => return 9,
    }

    var symbol_index = definition.symbolmap_length;
    while (symbol_index > 0) {
        symbol_index -= 1;
        const symbol = definition.symbols()[@intCast(symbol_index)];
        if (symbol.birth_pc == std.math.maxInt(u32)) {
            if (symbol.death_pc >= definition.environments_length) return 10;
        } else {
            if (symbol.slot_index >= slot_count) return 11;
            if (symbol.birth_pc >= bytecode_length) return 12;
            if (symbol.death_pc != std.math.maxInt(u32) and symbol.death_pc > bytecode_length) return 13;
        }
        if (symbol.symbol == null) return 14;
    }
    return 0;
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
// `bytecode.c`'s only remaining definition, and it comes here rather than to
// one of the two `asm_*` subsystems that also read it, because `-Dverify` is
// the one selector whose C original is `bytecode.c` -- the assembler's are
// `asm.c`'s. So this guard is that file's guard, and moving the table under
// it empties the file rather than splitting it.
//
// The C original is seventy-seven bare initialisers with the opcode named in
// a trailing comment, so an opcode inserted in the middle of `JanetOpCode`
// silently shifts every row after it and a comment that no compiler reads is
// what says otherwise. Here each row names its opcode, and the loop below
// places it by that name and refuses to compile if any opcode is missed or
// written twice. The check costs nothing at run time: `janet_instructions` is
// built at comptime and lands in read-only data exactly as the C array does.
// ==========================================================================

const Row = struct { op: c_int, type: c_uint };

const rows = [_]Row{
    .{ .op = constants.JOP_NOOP, .type = constants.JINT_0 },
    .{ .op = constants.JOP_ERROR, .type = constants.JINT_S },
    .{ .op = constants.JOP_TYPECHECK, .type = constants.JINT_ST },
    .{ .op = constants.JOP_RETURN, .type = constants.JINT_S },
    .{ .op = constants.JOP_RETURN_NIL, .type = constants.JINT_0 },
    .{ .op = constants.JOP_ADD_IMMEDIATE, .type = constants.JINT_SSI },
    .{ .op = constants.JOP_ADD, .type = constants.JINT_SSS },
    .{ .op = constants.JOP_SUBTRACT_IMMEDIATE, .type = constants.JINT_SSI },
    .{ .op = constants.JOP_SUBTRACT, .type = constants.JINT_SSS },
    .{ .op = constants.JOP_MULTIPLY_IMMEDIATE, .type = constants.JINT_SSI },
    .{ .op = constants.JOP_MULTIPLY, .type = constants.JINT_SSS },
    .{ .op = constants.JOP_DIVIDE_IMMEDIATE, .type = constants.JINT_SSI },
    .{ .op = constants.JOP_DIVIDE, .type = constants.JINT_SSS },
    .{ .op = constants.JOP_DIVIDE_FLOOR, .type = constants.JINT_SSS },
    .{ .op = constants.JOP_MODULO, .type = constants.JINT_SSS },
    .{ .op = constants.JOP_REMAINDER, .type = constants.JINT_SSS },
    .{ .op = constants.JOP_BAND, .type = constants.JINT_SSS },
    .{ .op = constants.JOP_BOR, .type = constants.JINT_SSS },
    .{ .op = constants.JOP_BXOR, .type = constants.JINT_SSS },
    .{ .op = constants.JOP_BNOT, .type = constants.JINT_SS },
    .{ .op = constants.JOP_SHIFT_LEFT, .type = constants.JINT_SSS },
    .{ .op = constants.JOP_SHIFT_LEFT_IMMEDIATE, .type = constants.JINT_SSI },
    .{ .op = constants.JOP_SHIFT_RIGHT, .type = constants.JINT_SSS },
    .{ .op = constants.JOP_SHIFT_RIGHT_IMMEDIATE, .type = constants.JINT_SSI },
    .{ .op = constants.JOP_SHIFT_RIGHT_UNSIGNED, .type = constants.JINT_SSS },
    .{ .op = constants.JOP_SHIFT_RIGHT_UNSIGNED_IMMEDIATE, .type = constants.JINT_SSU },
    .{ .op = constants.JOP_MOVE_FAR, .type = constants.JINT_SS },
    .{ .op = constants.JOP_MOVE_NEAR, .type = constants.JINT_SS },
    .{ .op = constants.JOP_JUMP, .type = constants.JINT_L },
    .{ .op = constants.JOP_JUMP_IF, .type = constants.JINT_SL },
    .{ .op = constants.JOP_JUMP_IF_NOT, .type = constants.JINT_SL },
    .{ .op = constants.JOP_JUMP_IF_NIL, .type = constants.JINT_SL },
    .{ .op = constants.JOP_JUMP_IF_NOT_NIL, .type = constants.JINT_SL },
    .{ .op = constants.JOP_GREATER_THAN, .type = constants.JINT_SSS },
    .{ .op = constants.JOP_GREATER_THAN_IMMEDIATE, .type = constants.JINT_SSI },
    .{ .op = constants.JOP_LESS_THAN, .type = constants.JINT_SSS },
    .{ .op = constants.JOP_LESS_THAN_IMMEDIATE, .type = constants.JINT_SSI },
    .{ .op = constants.JOP_EQUALS, .type = constants.JINT_SSS },
    .{ .op = constants.JOP_EQUALS_IMMEDIATE, .type = constants.JINT_SSI },
    .{ .op = constants.JOP_COMPARE, .type = constants.JINT_SSS },
    .{ .op = constants.JOP_LOAD_NIL, .type = constants.JINT_S },
    .{ .op = constants.JOP_LOAD_TRUE, .type = constants.JINT_S },
    .{ .op = constants.JOP_LOAD_FALSE, .type = constants.JINT_S },
    .{ .op = constants.JOP_LOAD_INTEGER, .type = constants.JINT_SI },
    .{ .op = constants.JOP_LOAD_CONSTANT, .type = constants.JINT_SC },
    .{ .op = constants.JOP_LOAD_UPVALUE, .type = constants.JINT_SES },
    .{ .op = constants.JOP_LOAD_SELF, .type = constants.JINT_S },
    .{ .op = constants.JOP_SET_UPVALUE, .type = constants.JINT_SES },
    .{ .op = constants.JOP_CLOSURE, .type = constants.JINT_SD },
    .{ .op = constants.JOP_PUSH, .type = constants.JINT_S },
    .{ .op = constants.JOP_PUSH_2, .type = constants.JINT_SS },
    .{ .op = constants.JOP_PUSH_3, .type = constants.JINT_SSS },
    .{ .op = constants.JOP_PUSH_ARRAY, .type = constants.JINT_S },
    .{ .op = constants.JOP_CALL, .type = constants.JINT_SS },
    .{ .op = constants.JOP_TAILCALL, .type = constants.JINT_S },
    .{ .op = constants.JOP_RESUME, .type = constants.JINT_SSS },
    .{ .op = constants.JOP_SIGNAL, .type = constants.JINT_SSU },
    .{ .op = constants.JOP_PROPAGATE, .type = constants.JINT_SSS },
    .{ .op = constants.JOP_IN, .type = constants.JINT_SSS },
    .{ .op = constants.JOP_GET, .type = constants.JINT_SSS },
    .{ .op = constants.JOP_PUT, .type = constants.JINT_SSS },
    .{ .op = constants.JOP_GET_INDEX, .type = constants.JINT_SSU },
    .{ .op = constants.JOP_PUT_INDEX, .type = constants.JINT_SSU },
    .{ .op = constants.JOP_LENGTH, .type = constants.JINT_SS },
    .{ .op = constants.JOP_MAKE_ARRAY, .type = constants.JINT_S },
    .{ .op = constants.JOP_MAKE_BUFFER, .type = constants.JINT_S },
    .{ .op = constants.JOP_MAKE_STRING, .type = constants.JINT_S },
    .{ .op = constants.JOP_MAKE_STRUCT, .type = constants.JINT_S },
    .{ .op = constants.JOP_MAKE_TABLE, .type = constants.JINT_S },
    .{ .op = constants.JOP_MAKE_TUPLE, .type = constants.JINT_S },
    .{ .op = constants.JOP_MAKE_BRACKET_TUPLE, .type = constants.JINT_S },
    .{ .op = constants.JOP_GREATER_THAN_EQUAL, .type = constants.JINT_SSS },
    .{ .op = constants.JOP_LESS_THAN_EQUAL, .type = constants.JINT_SSS },
    .{ .op = constants.JOP_NEXT, .type = constants.JINT_SSS },
    .{ .op = constants.JOP_NOT_EQUALS, .type = constants.JINT_SSS },
    .{ .op = constants.JOP_NOT_EQUALS_IMMEDIATE, .type = constants.JINT_SSI },
    .{ .op = constants.JOP_CANCEL, .type = constants.JINT_SSS },
};

/// `extern const enum JanetInstructionType janet_instructions[]` in `janet.h`:
/// the operand shape of every opcode, read by `janet_verify` above, by both
/// assembler directions, and by `janet_disasm`.
pub const instructions: [constants.JOP_INSTRUCTION_COUNT]c_uint = build: {
    var table: [constants.JOP_INSTRUCTION_COUNT]c_uint = undefined;
    var filled = [_]bool{false} ** constants.JOP_INSTRUCTION_COUNT;
    for (rows) |row| {
        if (filled[@intCast(row.op)]) {
            @compileError("janet_instructions: opcode listed twice");
        }
        filled[@intCast(row.op)] = true;
        table[@intCast(row.op)] = row.type;
    }
    for (filled, 0..) |present, opcode| {
        if (!present) {
            @compileError("janet_instructions: no row for opcode " ++
                std.fmt.comptimePrint("{d}", .{opcode}));
        }
    }
    break :build table;
};
