const c = @cImport({
    @cInclude("janet.h");
});

extern fn janet_c_asm_opcode_name(instruction: u32) callconv(.c) ?[*:0]const u8;
extern fn janet_c_asm_wrap_integer(value: i32) callconv(.c) c.Janet;
extern fn janet_c_asm_wrap_symbol(value: [*:0]const u8) callconv(.c) c.Janet;
extern fn janet_c_asm_wrap_tuple(value: c.JanetTuple) callconv(.c) c.Janet;
extern fn janet_c_asm_set_breakpoint(value: c.JanetTuple) callconv(.c) void;

export fn janet_asm_decode_instruction(instruction: u32) callconv(.c) c.Janet {
    const name_bytes = janet_c_asm_opcode_name(instruction) orelse {
        return janet_c_asm_wrap_integer(@bitCast(instruction));
    };

    const gc_lock = c.janet_gclock();
    defer c.janet_gcunlock(gc_lock);

    const name = janet_c_asm_wrap_symbol(name_bytes);
    const opcode = instruction & 0x7f;
    const instruction_type = c.janet_instructions[opcode];
    const result = switch (instruction_type) {
        c.JINT_0 => makeTuple(&.{name}),
        c.JINT_S => makeTuple(&.{ name, integer(argument(instruction, 1, 0xffffff)) }),
        c.JINT_L => makeTuple(&.{ name, integer(signedShift(instruction, 8)) }),
        c.JINT_SS, c.JINT_ST, c.JINT_SC, c.JINT_SU, c.JINT_SD => makeTuple(&.{
            name,
            integer(argument(instruction, 1, 0xff)),
            integer(argument(instruction, 2, 0xffff)),
        }),
        c.JINT_SI, c.JINT_SL => makeTuple(&.{
            name,
            integer(argument(instruction, 1, 0xff)),
            integer(signedShift(instruction, 16)),
        }),
        c.JINT_SSS, c.JINT_SES, c.JINT_SSU => makeTuple(&.{
            name,
            integer(argument(instruction, 1, 0xff)),
            integer(argument(instruction, 2, 0xff)),
            integer(argument(instruction, 3, 0xff)),
        }),
        c.JINT_SSI => makeTuple(&.{
            name,
            integer(argument(instruction, 1, 0xff)),
            integer(argument(instruction, 2, 0xff)),
            integer(signedShift(instruction, 24)),
        }),
        else => return c.janet_wrap_nil(),
    };

    if (instruction & 0x80 != 0) {
        janet_c_asm_set_breakpoint(result);
    }
    return janet_c_asm_wrap_tuple(result);
}

fn makeTuple(values: []const c.Janet) c.JanetTuple {
    const tuple = c.janet_tuple_begin(@intCast(values.len));
    for (values, 0..) |value, index| tuple[index] = value;
    return c.janet_tuple_end(tuple);
}

fn integer(value: i32) c.Janet {
    return janet_c_asm_wrap_integer(value);
}

fn argument(instruction: u32, byte: u5, mask: u32) i32 {
    return @intCast((instruction >> (byte * 8)) & mask);
}

fn signedShift(instruction: u32, shift: u5) i32 {
    const signed: i32 = @bitCast(instruction);
    return signed >> shift;
}
