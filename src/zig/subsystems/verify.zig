//! The bytecode verifier, and the instruction table it reads.
//!
//! `janet_verify` is the gate every funcdef passes before it can be run: the
//! assembler's output, and anything `unmarshal` produces. It answers a numbered
//! reason rather than a message, which is why `test/verify.c` is written
//! against numbers.
//!
//! What each check *is* depends on the opcode's operand shape, and that comes
//! from `janet_instructions` at the foot of this file -- `bytecode.c`'s last
//! definition, which Phase 10 Part 7 moved here. It is here rather than with
//! either `asm_*` subsystem because `-Dverify` is the one selector whose C
//! original is `bytecode.c`; the assembler's are `asm.c`'s.

const std = @import("std");

const abi = @import("abi");
const c = abi.c;

export fn janet_verify(definition: *c.JanetFuncDef) callconv(.c) c_int {
    const varargs: i32 = @intFromBool(definition.flags & c.JANET_FUNCDEF_FLAG_VARARG != 0);
    const maximum_argument_slot = definition.arity + varargs;
    const slot_count = definition.slotcount;
    const bytecode_length = definition.bytecode_length;

    if (bytecode_length == 0) return 1;
    if (maximum_argument_slot > slot_count) return 2;

    for (definition.bytecode[0..@intCast(bytecode_length)], 0..) |instruction, index| {
        const opcode = instruction & 0x7f;
        if (opcode >= c.JOP_INSTRUCTION_COUNT) return 3;
        const instruction_type = c.janet_instructions[opcode];
        switch (instruction_type) {
            c.JINT_0 => {},
            c.JINT_S => if (@as(i32, @intCast(instruction >> 8)) >= slot_count) return 4,
            c.JINT_SI, c.JINT_SU, c.JINT_ST => if (slotA(instruction) >= slot_count) return 4,
            c.JINT_L => {
                const destination = @as(i32, @intCast(index)) + signedField(instruction, 8);
                if (destination < 0 or destination >= bytecode_length) return 5;
            },
            c.JINT_SS => if (slotA(instruction) >= slot_count or @as(i32, @intCast(instruction >> 16)) >= slot_count) return 4,
            c.JINT_SSI, c.JINT_SSU => if (slotA(instruction) >= slot_count or slotB(instruction) >= slot_count) return 4,
            c.JINT_SL => {
                if (slotA(instruction) >= slot_count) return 4;
                const destination = @as(i32, @intCast(index)) + signedField(instruction, 16);
                if (destination < 0 or destination >= bytecode_length) return 5;
            },
            c.JINT_SSS => if (slotA(instruction) >= slot_count or slotB(instruction) >= slot_count or slotC(instruction) >= slot_count) return 4,
            c.JINT_SD => {
                if (slotA(instruction) >= slot_count) return 4;
                if (@as(i32, @intCast(instruction >> 16)) >= definition.defs_length) return 6;
            },
            c.JINT_SC => {
                if (slotA(instruction) >= slot_count) return 4;
                if (@as(i32, @intCast(instruction >> 16)) >= definition.constants_length) return 7;
            },
            c.JINT_SES => {
                if (slotA(instruction) >= slot_count) return 4;
                if (slotB(instruction) >= definition.environments_length) return 8;
            },
            else => unreachable,
        }
    }

    switch (definition.bytecode[@intCast(bytecode_length - 1)] & 0xff) {
        c.JOP_RETURN, c.JOP_RETURN_NIL, c.JOP_JUMP, c.JOP_ERROR, c.JOP_TAILCALL => {},
        else => return 9,
    }

    var symbol_index = definition.symbolmap_length;
    while (symbol_index > 0) {
        symbol_index -= 1;
        const symbol = definition.symbolmap[@intCast(symbol_index)];
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
    .{ .op = c.JOP_NOOP, .type = c.JINT_0 },
    .{ .op = c.JOP_ERROR, .type = c.JINT_S },
    .{ .op = c.JOP_TYPECHECK, .type = c.JINT_ST },
    .{ .op = c.JOP_RETURN, .type = c.JINT_S },
    .{ .op = c.JOP_RETURN_NIL, .type = c.JINT_0 },
    .{ .op = c.JOP_ADD_IMMEDIATE, .type = c.JINT_SSI },
    .{ .op = c.JOP_ADD, .type = c.JINT_SSS },
    .{ .op = c.JOP_SUBTRACT_IMMEDIATE, .type = c.JINT_SSI },
    .{ .op = c.JOP_SUBTRACT, .type = c.JINT_SSS },
    .{ .op = c.JOP_MULTIPLY_IMMEDIATE, .type = c.JINT_SSI },
    .{ .op = c.JOP_MULTIPLY, .type = c.JINT_SSS },
    .{ .op = c.JOP_DIVIDE_IMMEDIATE, .type = c.JINT_SSI },
    .{ .op = c.JOP_DIVIDE, .type = c.JINT_SSS },
    .{ .op = c.JOP_DIVIDE_FLOOR, .type = c.JINT_SSS },
    .{ .op = c.JOP_MODULO, .type = c.JINT_SSS },
    .{ .op = c.JOP_REMAINDER, .type = c.JINT_SSS },
    .{ .op = c.JOP_BAND, .type = c.JINT_SSS },
    .{ .op = c.JOP_BOR, .type = c.JINT_SSS },
    .{ .op = c.JOP_BXOR, .type = c.JINT_SSS },
    .{ .op = c.JOP_BNOT, .type = c.JINT_SS },
    .{ .op = c.JOP_SHIFT_LEFT, .type = c.JINT_SSS },
    .{ .op = c.JOP_SHIFT_LEFT_IMMEDIATE, .type = c.JINT_SSI },
    .{ .op = c.JOP_SHIFT_RIGHT, .type = c.JINT_SSS },
    .{ .op = c.JOP_SHIFT_RIGHT_IMMEDIATE, .type = c.JINT_SSI },
    .{ .op = c.JOP_SHIFT_RIGHT_UNSIGNED, .type = c.JINT_SSS },
    .{ .op = c.JOP_SHIFT_RIGHT_UNSIGNED_IMMEDIATE, .type = c.JINT_SSU },
    .{ .op = c.JOP_MOVE_FAR, .type = c.JINT_SS },
    .{ .op = c.JOP_MOVE_NEAR, .type = c.JINT_SS },
    .{ .op = c.JOP_JUMP, .type = c.JINT_L },
    .{ .op = c.JOP_JUMP_IF, .type = c.JINT_SL },
    .{ .op = c.JOP_JUMP_IF_NOT, .type = c.JINT_SL },
    .{ .op = c.JOP_JUMP_IF_NIL, .type = c.JINT_SL },
    .{ .op = c.JOP_JUMP_IF_NOT_NIL, .type = c.JINT_SL },
    .{ .op = c.JOP_GREATER_THAN, .type = c.JINT_SSS },
    .{ .op = c.JOP_GREATER_THAN_IMMEDIATE, .type = c.JINT_SSI },
    .{ .op = c.JOP_LESS_THAN, .type = c.JINT_SSS },
    .{ .op = c.JOP_LESS_THAN_IMMEDIATE, .type = c.JINT_SSI },
    .{ .op = c.JOP_EQUALS, .type = c.JINT_SSS },
    .{ .op = c.JOP_EQUALS_IMMEDIATE, .type = c.JINT_SSI },
    .{ .op = c.JOP_COMPARE, .type = c.JINT_SSS },
    .{ .op = c.JOP_LOAD_NIL, .type = c.JINT_S },
    .{ .op = c.JOP_LOAD_TRUE, .type = c.JINT_S },
    .{ .op = c.JOP_LOAD_FALSE, .type = c.JINT_S },
    .{ .op = c.JOP_LOAD_INTEGER, .type = c.JINT_SI },
    .{ .op = c.JOP_LOAD_CONSTANT, .type = c.JINT_SC },
    .{ .op = c.JOP_LOAD_UPVALUE, .type = c.JINT_SES },
    .{ .op = c.JOP_LOAD_SELF, .type = c.JINT_S },
    .{ .op = c.JOP_SET_UPVALUE, .type = c.JINT_SES },
    .{ .op = c.JOP_CLOSURE, .type = c.JINT_SD },
    .{ .op = c.JOP_PUSH, .type = c.JINT_S },
    .{ .op = c.JOP_PUSH_2, .type = c.JINT_SS },
    .{ .op = c.JOP_PUSH_3, .type = c.JINT_SSS },
    .{ .op = c.JOP_PUSH_ARRAY, .type = c.JINT_S },
    .{ .op = c.JOP_CALL, .type = c.JINT_SS },
    .{ .op = c.JOP_TAILCALL, .type = c.JINT_S },
    .{ .op = c.JOP_RESUME, .type = c.JINT_SSS },
    .{ .op = c.JOP_SIGNAL, .type = c.JINT_SSU },
    .{ .op = c.JOP_PROPAGATE, .type = c.JINT_SSS },
    .{ .op = c.JOP_IN, .type = c.JINT_SSS },
    .{ .op = c.JOP_GET, .type = c.JINT_SSS },
    .{ .op = c.JOP_PUT, .type = c.JINT_SSS },
    .{ .op = c.JOP_GET_INDEX, .type = c.JINT_SSU },
    .{ .op = c.JOP_PUT_INDEX, .type = c.JINT_SSU },
    .{ .op = c.JOP_LENGTH, .type = c.JINT_SS },
    .{ .op = c.JOP_MAKE_ARRAY, .type = c.JINT_S },
    .{ .op = c.JOP_MAKE_BUFFER, .type = c.JINT_S },
    .{ .op = c.JOP_MAKE_STRING, .type = c.JINT_S },
    .{ .op = c.JOP_MAKE_STRUCT, .type = c.JINT_S },
    .{ .op = c.JOP_MAKE_TABLE, .type = c.JINT_S },
    .{ .op = c.JOP_MAKE_TUPLE, .type = c.JINT_S },
    .{ .op = c.JOP_MAKE_BRACKET_TUPLE, .type = c.JINT_S },
    .{ .op = c.JOP_GREATER_THAN_EQUAL, .type = c.JINT_SSS },
    .{ .op = c.JOP_LESS_THAN_EQUAL, .type = c.JINT_SSS },
    .{ .op = c.JOP_NEXT, .type = c.JINT_SSS },
    .{ .op = c.JOP_NOT_EQUALS, .type = c.JINT_SSS },
    .{ .op = c.JOP_NOT_EQUALS_IMMEDIATE, .type = c.JINT_SSI },
    .{ .op = c.JOP_CANCEL, .type = c.JINT_SSS },
};

/// `extern const enum JanetInstructionType janet_instructions[]` in `janet.h`:
/// the operand shape of every opcode, read by `janet_verify` above, by both
/// assembler directions, and by `janet_disasm`.
export const janet_instructions: [c.JOP_INSTRUCTION_COUNT]c_uint = build: {
    var table: [c.JOP_INSTRUCTION_COUNT]c_uint = undefined;
    var filled = [_]bool{false} ** c.JOP_INSTRUCTION_COUNT;
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
