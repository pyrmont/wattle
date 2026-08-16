const std = @import("std");

const c = @cImport(@cInclude("janet.h"));

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
