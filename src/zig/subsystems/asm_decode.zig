const abi = @import("abi");
const c = abi.c;

const asm_encode = @import("asm_encode.zig");

/// The instruction name for an encoded word, or `null` for an opcode this
/// build does not know.
///
/// `asm.c` kept a second copy of the whole opcode table for this one reverse
/// lookup. `asm_encode.zig` has the table -- it is what the assembler matches
/// names against -- so the lookup is a walk over that and the duplicate is
/// gone.
fn janet_c_asm_opcode_name(instruction: u32) ?[*:0]const u8 {
    const opcode = instruction & 0x7F;
    for (asm_encode.opcodes) |def| {
        if (def.opcode == opcode) return def.name;
    }
    return null;
}

/// `janet_wrap_integer`, written out. `janet.h` declares it beside its macro
/// and `wrap.c` defines it only for the two nanbox layouts, so a Zig caller
/// that reaches the declaration does not link against `-Dnanbox=false`. Four
/// other files carry the same three lines and the same note.
inline fn janet_c_asm_wrap_integer(value: i32) c.Janet {
    return c.janet_wrap_number(@floatFromInt(value));
}

inline fn janet_c_asm_wrap_symbol(value: [*:0]const u8) c.Janet {
    return c.janet_wrap_symbol(c.janet_csymbol(value));
}

inline fn janet_c_asm_wrap_tuple(value: c.JanetTuple) c.Janet {
    return c.janet_wrap_tuple(value);
}

/// `janet_tuple_flag(value) |= JANET_TUPLE_FLAG_BRACKETCTOR`, which is what
/// makes a disassembled instruction print as `[...]` rather than `(...)`.
///
/// The C name says "breakpoint" and the flag it sets does not; the name is
/// reproduced rather than corrected, because it is the symbol `asm.c`
/// exported and renaming it here would hide the discrepancy rather than
/// record it. `FOUND.md` has the entry.
///
/// The head is found with `@sizeOf`, which is what `gc_mark.zig` and
/// `gc_sweep.zig` already do. The C macro spells it `offsetof(.., data)` and
/// the two are not the same question -- `data` is a flexible array member, so
/// `sizeof` could in principle round up past the offset -- but translate-c
/// drops a flexible array member entirely, so `@offsetOf` is not available and
/// `@sizeOf` is the tree's one spelling for this.
inline fn janet_c_asm_set_breakpoint(value: c.JanetTuple) void {
    const head: *c.JanetTupleHead =
        @ptrFromInt(@intFromPtr(value) -% @sizeOf(c.JanetTupleHead));
    head.gc.flags |= c.JANET_TUPLE_FLAG_BRACKETCTOR;
}

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
