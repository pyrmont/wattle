const abi = @import("abi");
const c = abi.c;

export fn janet_bytecode_movopt(definition: *c.JanetFuncDef) callconv(.c) void {
    var repeat = true;
    while (repeat) {
        var registers: c.JanetcRegisterAllocator = undefined;
        c.janetc_regalloc_init(&registers);
        defer c.janetc_regalloc_deinit(&registers);

        if (definition.closure_bitset != null) {
            var slot: i32 = 0;
            while (slot < definition.slotcount) : (slot += 1) {
                const index: usize = @intCast(slot >> 5);
                const bit: u5 = @intCast(slot & 31);
                if (definition.closure_bitset[index] & (@as(u32, 1) << bit) != 0) {
                    c.janetc_regalloc_touch(&registers, slot);
                }
            }
        }

        for (definition.bytecode[0..@intCast(definition.bytecode_length)]) |instruction| {
            markReads(&registers, instruction);
        }

        repeat = false;
        for (definition.bytecode[0..@intCast(definition.bytecode_length)]) |*instruction| {
            const candidate: ?i32 = switch (opcode(instruction.*)) {
                c.JOP_LOAD_NIL,
                c.JOP_LOAD_TRUE,
                c.JOP_LOAD_FALSE,
                c.JOP_LOAD_SELF,
                c.JOP_MAKE_ARRAY,
                c.JOP_MAKE_TUPLE,
                c.JOP_MAKE_BRACKET_TUPLE,
                => fieldD(instruction.*),

                c.JOP_MOVE_FAR => fieldE(instruction.*),

                c.JOP_MOVE_NEAR,
                c.JOP_GET_INDEX,
                c.JOP_LOAD_INTEGER,
                c.JOP_LOAD_CONSTANT,
                c.JOP_LOAD_UPVALUE,
                c.JOP_CLOSURE,
                => fieldA(instruction.*),

                else => null,
            };
            if (candidate) |written_slot| {
                if (c.janetc_regalloc_check(&registers, written_slot) == 0) {
                    instruction.* = c.JOP_NOOP;
                    repeat = true;
                }
            }
        }
    }
}

fn markReads(registers: *c.JanetcRegisterAllocator, instruction: u32) void {
    switch (opcode(instruction)) {
        c.JOP_JUMP,
        c.JOP_NOOP,
        c.JOP_RETURN_NIL,
        c.JOP_LOAD_INTEGER,
        c.JOP_LOAD_CONSTANT,
        c.JOP_LOAD_UPVALUE,
        c.JOP_CLOSURE,
        c.JOP_LOAD_NIL,
        c.JOP_LOAD_TRUE,
        c.JOP_LOAD_FALSE,
        c.JOP_LOAD_SELF,
        => {},

        c.JOP_MAKE_ARRAY,
        c.JOP_MAKE_BUFFER,
        c.JOP_MAKE_STRING,
        c.JOP_MAKE_STRUCT,
        c.JOP_MAKE_TABLE,
        c.JOP_MAKE_TUPLE,
        c.JOP_MAKE_BRACKET_TUPLE,
        c.JOP_RETURN,
        c.JOP_PUSH,
        c.JOP_PUSH_ARRAY,
        c.JOP_TAILCALL,
        => touch(registers, fieldD(instruction)),

        c.JOP_ERROR,
        c.JOP_TYPECHECK,
        c.JOP_JUMP_IF,
        c.JOP_JUMP_IF_NOT,
        c.JOP_JUMP_IF_NIL,
        c.JOP_JUMP_IF_NOT_NIL,
        c.JOP_SET_UPVALUE,
        c.JOP_MOVE_FAR,
        => touch(registers, fieldA(instruction)),

        c.JOP_SIGNAL,
        c.JOP_ADD_IMMEDIATE,
        c.JOP_SUBTRACT_IMMEDIATE,
        c.JOP_MULTIPLY_IMMEDIATE,
        c.JOP_DIVIDE_IMMEDIATE,
        c.JOP_SHIFT_LEFT_IMMEDIATE,
        c.JOP_SHIFT_RIGHT_IMMEDIATE,
        c.JOP_SHIFT_RIGHT_UNSIGNED_IMMEDIATE,
        c.JOP_GREATER_THAN_IMMEDIATE,
        c.JOP_LESS_THAN_IMMEDIATE,
        c.JOP_EQUALS_IMMEDIATE,
        c.JOP_NOT_EQUALS_IMMEDIATE,
        c.JOP_GET_INDEX,
        => touch(registers, fieldB(instruction)),

        c.JOP_MOVE_NEAR,
        c.JOP_LENGTH,
        c.JOP_BNOT,
        c.JOP_CALL,
        => touch(registers, fieldE(instruction)),

        c.JOP_PUT_INDEX => {
            touch(registers, fieldA(instruction));
            touch(registers, fieldB(instruction));
        },

        c.JOP_PUSH_2 => {
            touch(registers, fieldA(instruction));
            touch(registers, fieldE(instruction));
        },

        c.JOP_PROPAGATE,
        c.JOP_BAND,
        c.JOP_BOR,
        c.JOP_BXOR,
        c.JOP_ADD,
        c.JOP_SUBTRACT,
        c.JOP_MULTIPLY,
        c.JOP_DIVIDE,
        c.JOP_DIVIDE_FLOOR,
        c.JOP_MODULO,
        c.JOP_REMAINDER,
        c.JOP_SHIFT_LEFT,
        c.JOP_SHIFT_RIGHT,
        c.JOP_SHIFT_RIGHT_UNSIGNED,
        c.JOP_GREATER_THAN,
        c.JOP_LESS_THAN,
        c.JOP_EQUALS,
        c.JOP_COMPARE,
        c.JOP_IN,
        c.JOP_GET,
        c.JOP_GREATER_THAN_EQUAL,
        c.JOP_LESS_THAN_EQUAL,
        c.JOP_NOT_EQUALS,
        c.JOP_CANCEL,
        c.JOP_RESUME,
        c.JOP_NEXT,
        => {
            touch(registers, fieldB(instruction));
            touch(registers, fieldC(instruction));
        },

        c.JOP_PUT, c.JOP_PUSH_3 => {
            touch(registers, fieldA(instruction));
            touch(registers, fieldB(instruction));
            touch(registers, fieldC(instruction));
        },

        else => c.janet_zig_fatal("unhandled instruction"),
    }
}

fn touch(registers: *c.JanetcRegisterAllocator, slot: i32) void {
    c.janetc_regalloc_touch(registers, slot);
}

fn opcode(instruction: u32) u32 {
    return instruction & 0x7f;
}

fn fieldA(instruction: u32) i32 {
    return @intCast((instruction >> 8) & 0xff);
}

fn fieldB(instruction: u32) i32 {
    return @intCast((instruction >> 16) & 0xff);
}

fn fieldC(instruction: u32) i32 {
    return @intCast(instruction >> 24);
}

fn fieldD(instruction: u32) i32 {
    return @intCast(instruction >> 8);
}

fn fieldE(instruction: u32) i32 {
    return @intCast(instruction >> 16);
}
