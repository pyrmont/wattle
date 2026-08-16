const c = @cImport({
    @cInclude("janet.h");
});

const ResolvedArgument = struct {
    value: i32,
    error_message: [*c]const u8 = null,
};

const EncodeResult = extern struct {
    instruction: u32,
    error_message: [*c]const u8,
    indexed_error: i32,
};

const BytecodeResult = extern struct {
    count: i32,
    error_message: [*c]const u8,
    indexed_error: i32,
    error_index: i32,
};

const HeaderResult = extern struct {
    error_message: [*c]const u8,
    indexed_error: i32,
};

extern fn janet_c_asm_argument_table(
    assembler: ?*anyopaque,
    argument_type: i32,
) callconv(.c) ?*c.JanetTable;
extern fn janet_c_asm_funcdef(assembler: ?*anyopaque) callconv(.c) *c.JanetFuncDef;
extern fn janet_c_asm_set_name(assembler: ?*anyopaque, name: c.Janet) callconv(.c) void;
extern fn janet_c_asm_bytecode_count(assembler: ?*anyopaque) callconv(.c) i32;
extern fn janet_c_asm_set_bytecode_count(assembler: ?*anyopaque, count: i32) callconv(.c) void;
extern fn janet_c_asm_add_environment(assembler: ?*anyopaque, name: c.Janet) callconv(.c) i32;
extern fn janet_c_asm_wrap_integer(value: i32) callconv(.c) c.Janet;
extern fn janet_c_asm_get_field(source: c.Janet, name: [*:0]const u8) callconv(.c) c.Janet;
extern fn janet_c_asm_parent_for_environment(
    assembler: ?*anyopaque,
    environment: u32,
) callconv(.c) ?*anyopaque;
extern fn janet_c_asm_argument_bounds_error(
    value: c.Janet,
    byte_count: i32,
    too_large: i32,
) callconv(.c) [*c]const u8;
extern fn janet_c_asm_unknown_instruction(value: c.Janet) callconv(.c) [*c]const u8;
extern fn janet_c_asm_resolution_error(value: c.Janet, kind: i32) callconv(.c) [*c]const u8;
extern fn janet_c_asm_invalid_error(status: i32) callconv(.c) [*c]const u8;
extern fn janet_def_addflags(definition: *c.JanetFuncDef) callconv(.c) void;

const OpcodeDefinition = struct {
    name: [*:0]const u8,
    opcode: u32,
};

const TypeAlias = struct {
    name: [*:0]const u8,
    mask: i32,
};

const type_aliases = [_]TypeAlias{
    .{ .name = "abstract", .mask = c.JANET_TFLAG_ABSTRACT },
    .{ .name = "array", .mask = c.JANET_TFLAG_ARRAY },
    .{ .name = "boolean", .mask = c.JANET_TFLAG_BOOLEAN },
    .{ .name = "buffer", .mask = c.JANET_TFLAG_BUFFER },
    .{ .name = "callable", .mask = c.JANET_TFLAG_CALLABLE },
    .{ .name = "cfunction", .mask = c.JANET_TFLAG_CFUNCTION },
    .{ .name = "dictionary", .mask = c.JANET_TFLAG_DICTIONARY },
    .{ .name = "fiber", .mask = c.JANET_TFLAG_FIBER },
    .{ .name = "function", .mask = c.JANET_TFLAG_FUNCTION },
    .{ .name = "indexed", .mask = c.JANET_TFLAG_INDEXED },
    .{ .name = "keyword", .mask = c.JANET_TFLAG_KEYWORD },
    .{ .name = "nil", .mask = c.JANET_TFLAG_NIL },
    .{ .name = "number", .mask = c.JANET_TFLAG_NUMBER },
    .{ .name = "pointer", .mask = c.JANET_TFLAG_POINTER },
    .{ .name = "string", .mask = c.JANET_TFLAG_STRING },
    .{ .name = "struct", .mask = c.JANET_TFLAG_STRUCT },
    .{ .name = "symbol", .mask = c.JANET_TFLAG_SYMBOL },
    .{ .name = "table", .mask = c.JANET_TFLAG_TABLE },
    .{ .name = "tuple", .mask = c.JANET_TFLAG_TUPLE },
};

const opcodes = [_]OpcodeDefinition{
    .{ .name = "add", .opcode = c.JOP_ADD },
    .{ .name = "addim", .opcode = c.JOP_ADD_IMMEDIATE },
    .{ .name = "band", .opcode = c.JOP_BAND },
    .{ .name = "bnot", .opcode = c.JOP_BNOT },
    .{ .name = "bor", .opcode = c.JOP_BOR },
    .{ .name = "bxor", .opcode = c.JOP_BXOR },
    .{ .name = "call", .opcode = c.JOP_CALL },
    .{ .name = "clo", .opcode = c.JOP_CLOSURE },
    .{ .name = "cmp", .opcode = c.JOP_COMPARE },
    .{ .name = "cncl", .opcode = c.JOP_CANCEL },
    .{ .name = "div", .opcode = c.JOP_DIVIDE },
    .{ .name = "divf", .opcode = c.JOP_DIVIDE_FLOOR },
    .{ .name = "divim", .opcode = c.JOP_DIVIDE_IMMEDIATE },
    .{ .name = "eq", .opcode = c.JOP_EQUALS },
    .{ .name = "eqim", .opcode = c.JOP_EQUALS_IMMEDIATE },
    .{ .name = "err", .opcode = c.JOP_ERROR },
    .{ .name = "get", .opcode = c.JOP_GET },
    .{ .name = "geti", .opcode = c.JOP_GET_INDEX },
    .{ .name = "gt", .opcode = c.JOP_GREATER_THAN },
    .{ .name = "gte", .opcode = c.JOP_GREATER_THAN_EQUAL },
    .{ .name = "gtim", .opcode = c.JOP_GREATER_THAN_IMMEDIATE },
    .{ .name = "in", .opcode = c.JOP_IN },
    .{ .name = "jmp", .opcode = c.JOP_JUMP },
    .{ .name = "jmpif", .opcode = c.JOP_JUMP_IF },
    .{ .name = "jmpni", .opcode = c.JOP_JUMP_IF_NIL },
    .{ .name = "jmpnn", .opcode = c.JOP_JUMP_IF_NOT_NIL },
    .{ .name = "jmpno", .opcode = c.JOP_JUMP_IF_NOT },
    .{ .name = "ldc", .opcode = c.JOP_LOAD_CONSTANT },
    .{ .name = "ldf", .opcode = c.JOP_LOAD_FALSE },
    .{ .name = "ldi", .opcode = c.JOP_LOAD_INTEGER },
    .{ .name = "ldn", .opcode = c.JOP_LOAD_NIL },
    .{ .name = "lds", .opcode = c.JOP_LOAD_SELF },
    .{ .name = "ldt", .opcode = c.JOP_LOAD_TRUE },
    .{ .name = "ldu", .opcode = c.JOP_LOAD_UPVALUE },
    .{ .name = "len", .opcode = c.JOP_LENGTH },
    .{ .name = "lt", .opcode = c.JOP_LESS_THAN },
    .{ .name = "lte", .opcode = c.JOP_LESS_THAN_EQUAL },
    .{ .name = "ltim", .opcode = c.JOP_LESS_THAN_IMMEDIATE },
    .{ .name = "mkarr", .opcode = c.JOP_MAKE_ARRAY },
    .{ .name = "mkbtp", .opcode = c.JOP_MAKE_BRACKET_TUPLE },
    .{ .name = "mkbuf", .opcode = c.JOP_MAKE_BUFFER },
    .{ .name = "mkstr", .opcode = c.JOP_MAKE_STRING },
    .{ .name = "mkstu", .opcode = c.JOP_MAKE_STRUCT },
    .{ .name = "mktab", .opcode = c.JOP_MAKE_TABLE },
    .{ .name = "mktup", .opcode = c.JOP_MAKE_TUPLE },
    .{ .name = "mod", .opcode = c.JOP_MODULO },
    .{ .name = "movf", .opcode = c.JOP_MOVE_FAR },
    .{ .name = "movn", .opcode = c.JOP_MOVE_NEAR },
    .{ .name = "mul", .opcode = c.JOP_MULTIPLY },
    .{ .name = "mulim", .opcode = c.JOP_MULTIPLY_IMMEDIATE },
    .{ .name = "neq", .opcode = c.JOP_NOT_EQUALS },
    .{ .name = "neqim", .opcode = c.JOP_NOT_EQUALS_IMMEDIATE },
    .{ .name = "next", .opcode = c.JOP_NEXT },
    .{ .name = "noop", .opcode = c.JOP_NOOP },
    .{ .name = "prop", .opcode = c.JOP_PROPAGATE },
    .{ .name = "push", .opcode = c.JOP_PUSH },
    .{ .name = "push2", .opcode = c.JOP_PUSH_2 },
    .{ .name = "push3", .opcode = c.JOP_PUSH_3 },
    .{ .name = "pusha", .opcode = c.JOP_PUSH_ARRAY },
    .{ .name = "put", .opcode = c.JOP_PUT },
    .{ .name = "puti", .opcode = c.JOP_PUT_INDEX },
    .{ .name = "rem", .opcode = c.JOP_REMAINDER },
    .{ .name = "res", .opcode = c.JOP_RESUME },
    .{ .name = "ret", .opcode = c.JOP_RETURN },
    .{ .name = "retn", .opcode = c.JOP_RETURN_NIL },
    .{ .name = "setu", .opcode = c.JOP_SET_UPVALUE },
    .{ .name = "sig", .opcode = c.JOP_SIGNAL },
    .{ .name = "sl", .opcode = c.JOP_SHIFT_LEFT },
    .{ .name = "slim", .opcode = c.JOP_SHIFT_LEFT_IMMEDIATE },
    .{ .name = "sr", .opcode = c.JOP_SHIFT_RIGHT },
    .{ .name = "srim", .opcode = c.JOP_SHIFT_RIGHT_IMMEDIATE },
    .{ .name = "sru", .opcode = c.JOP_SHIFT_RIGHT_UNSIGNED },
    .{ .name = "sruim", .opcode = c.JOP_SHIFT_RIGHT_UNSIGNED_IMMEDIATE },
    .{ .name = "sub", .opcode = c.JOP_SUBTRACT },
    .{ .name = "subim", .opcode = c.JOP_SUBTRACT_IMMEDIATE },
    .{ .name = "tcall", .opcode = c.JOP_TAILCALL },
    .{ .name = "tchck", .opcode = c.JOP_TYPECHECK },
};

export fn janet_zig_asm_parse_header(
    assembler: ?*anyopaque,
    source: c.Janet,
) callconv(.c) HeaderResult {
    if (c.janet_checktype(source, c.JANET_STRUCT) == 0 and
        c.janet_checktype(source, c.JANET_TABLE) == 0)
    {
        return headerFailure("expected struct or table for assembly source");
    }
    const definition = janet_c_asm_funcdef(assembler);
    var value = janet_c_asm_get_field(source, "name");
    janet_c_asm_set_name(assembler, value);
    if (c.janet_checktype(value, c.JANET_NIL) == 0) definition.*.name = c.janet_to_string(value);

    value = janet_c_asm_get_field(source, "arity");
    definition.*.arity = if (c.janet_checkint(value) != 0) integerValue(value) else 0;
    if (definition.*.arity < 0) return headerFailure("arity must be non-negative");

    value = janet_c_asm_get_field(source, "max-arity");
    definition.*.max_arity = if (c.janet_checkint(value) != 0) integerValue(value) else definition.*.arity;
    if (definition.*.max_arity < definition.*.arity) {
        return headerFailure("max-arity must be greater than or equal to arity");
    }

    value = janet_c_asm_get_field(source, "min-arity");
    definition.*.min_arity = if (c.janet_checkint(value) != 0) integerValue(value) else definition.*.arity;
    if (definition.*.min_arity > definition.*.arity) {
        return headerFailure("min-arity must be less than or equal to arity");
    }

    value = janet_c_asm_get_field(source, "vararg");
    if (c.janet_truthy(value) != 0) definition.*.flags |= c.JANET_FUNCDEF_FLAG_VARARG;
    definition.*.slotcount = definition.*.arity + @intFromBool(definition.*.flags & c.JANET_FUNCDEF_FLAG_VARARG != 0);

    value = janet_c_asm_get_field(source, "structarg");
    if (c.janet_truthy(value) != 0) definition.*.flags |= c.JANET_FUNCDEF_FLAG_STRUCTARG;

    value = janet_c_asm_get_field(source, "namedargs");
    if (c.janet_checkint(value) != 0) {
        definition.*.flags |= c.JANET_FUNCDEF_FLAG_NAMEDARGS;
        definition.*.named_args_count = integerValue(value);
    }

    value = janet_c_asm_get_field(source, "source");
    if (c.janet_checktype(value, c.JANET_STRING) != 0) definition.*.source = c.janet_unwrap_string(value);
    return .{ .error_message = null, .indexed_error = 0 };
}

export fn janet_zig_asm_parse_slots(
    assembler: ?*anyopaque,
    source: c.Janet,
) callconv(.c) HeaderResult {
    const slots_value = janet_c_asm_get_field(source, "slots");
    var items: [*c]const c.Janet = null;
    var length: i32 = 0;
    if (c.janet_indexed_view(slots_value, &items, &length) == 0) return headerSuccess();
    const slots = janet_c_asm_argument_table(assembler, c.JANET_OAT_SLOT).?;
    var index: i32 = 0;
    while (index < length) : (index += 1) {
        const value = items[@intCast(index)];
        if (c.janet_checktype(value, c.JANET_TUPLE) != 0) {
            const aliases = c.janet_unwrap_tuple(value);
            var alias_index: i32 = 0;
            while (alias_index < c.janet_tuple_length(aliases)) : (alias_index += 1) {
                const alias = aliases[@intCast(alias_index)];
                if (c.janet_checktype(alias, c.JANET_SYMBOL) == 0) {
                    return headerFailure("slot names must be symbols");
                }
                c.janet_table_put(slots, alias, janet_c_asm_wrap_integer(index));
            }
        } else if (c.janet_checktype(value, c.JANET_SYMBOL) != 0) {
            c.janet_table_put(slots, value, janet_c_asm_wrap_integer(index));
        } else {
            return headerFailure("slot names must be symbols or tuple of symbols");
        }
    }
    return headerSuccess();
}

export fn janet_zig_asm_scan_constants(
    _: ?*anyopaque,
    source: c.Janet,
) callconv(.c) BytecodeResult {
    const constants = janet_c_asm_get_field(source, "constants");
    var items: [*c]const c.Janet = null;
    var length: i32 = 0;
    if (c.janet_indexed_view(constants, &items, &length) == 0) return bytecodeSuccess(0);
    return bytecodeSuccess(length);
}

export fn janet_zig_asm_fill_constants(
    assembler: ?*anyopaque,
    source: c.Janet,
) callconv(.c) void {
    const constants = janet_c_asm_get_field(source, "constants");
    var items: [*c]const c.Janet = null;
    var length: i32 = 0;
    if (c.janet_indexed_view(constants, &items, &length) == 0) unreachable;
    const definition = janet_c_asm_funcdef(assembler);
    var index: i32 = 0;
    while (index < length) : (index += 1) {
        definition.*.constants[@intCast(index)] = items[@intCast(index)];
    }
}

export fn janet_zig_asm_scan_sourcemap(
    assembler: ?*anyopaque,
    source: c.Janet,
) callconv(.c) BytecodeResult {
    const sourcemap = janet_c_asm_get_field(source, "sourcemap");
    var items: [*c]const c.Janet = null;
    var length: i32 = 0;
    if (c.janet_indexed_view(sourcemap, &items, &length) == 0) return bytecodeSuccess(0);
    if (length != janet_c_asm_funcdef(assembler).*.bytecode_length) {
        return bytecodeFailure("sourcemap must have the same length as the bytecode", true, -1);
    }
    return bytecodeSuccess(length);
}

export fn janet_zig_asm_fill_sourcemap(
    assembler: ?*anyopaque,
    source: c.Janet,
) callconv(.c) HeaderResult {
    const sourcemap = janet_c_asm_get_field(source, "sourcemap");
    var items: [*c]const c.Janet = null;
    var length: i32 = 0;
    if (c.janet_indexed_view(sourcemap, &items, &length) == 0) unreachable;
    const definition = janet_c_asm_funcdef(assembler);
    var index: i32 = 0;
    while (index < length) : (index += 1) {
        const entry = items[@intCast(index)];
        if (c.janet_checktype(entry, c.JANET_TUPLE) == 0) return headerFailure("expected tuple");
        const tuple = c.janet_unwrap_tuple(entry);
        if (c.janet_checkint(tuple[0]) == 0) return headerFailure("expected integer");
        if (c.janet_checkint(tuple[1]) == 0) return headerFailure("expected integer");
        definition.*.sourcemap[@intCast(index)] = .{
            .line = integerValue(tuple[0]),
            .column = integerValue(tuple[1]),
        };
    }
    return headerSuccess();
}

export fn janet_zig_asm_scan_symbolmap(
    _: ?*anyopaque,
    source: c.Janet,
) callconv(.c) BytecodeResult {
    const symbolmap = janet_c_asm_get_field(source, "symbolmap");
    var items: [*c]const c.Janet = null;
    var length: i32 = 0;
    if (c.janet_indexed_view(symbolmap, &items, &length) == 0) return bytecodeSuccess(0);
    return bytecodeSuccess(length);
}

export fn janet_zig_asm_fill_symbolmap(
    assembler: ?*anyopaque,
    source: c.Janet,
) callconv(.c) HeaderResult {
    const symbolmap = janet_c_asm_get_field(source, "symbolmap");
    var items: [*c]const c.Janet = null;
    var length: i32 = 0;
    if (c.janet_indexed_view(symbolmap, &items, &length) == 0) unreachable;
    const definition = janet_c_asm_funcdef(assembler);
    var index: i32 = 0;
    while (index < length) : (index += 1) {
        const entry = items[@intCast(index)];
        if (c.janet_checktype(entry, c.JANET_TUPLE) == 0) return headerFailure("expected tuple");
        const tuple = c.janet_unwrap_tuple(entry);
        const birth_pc: u32 = if (c.janet_checktype(tuple[0], c.JANET_KEYWORD) != 0 and
            c.janet_cstrcmp(c.janet_unwrap_keyword(tuple[0]), "upvalue") == 0)
            maximum_u32
        else if (c.janet_checkint(tuple[0]) != 0)
            @bitCast(integerValue(tuple[0]))
        else
            return headerFailure("expected integer");
        if (c.janet_checkint(tuple[1]) == 0) return headerFailure("expected integer");
        if (c.janet_checkint(tuple[2]) == 0) return headerFailure("expected integer");
        if (c.janet_checktype(tuple[3], c.JANET_SYMBOL) == 0) return headerFailure("expected symbol");
        definition.*.symbolmap[@intCast(index)] = .{
            .birth_pc = birth_pc,
            .death_pc = @bitCast(integerValue(tuple[1])),
            .slot_index = @bitCast(integerValue(tuple[2])),
            .symbol = c.janet_unwrap_symbol(tuple[3]),
        };
    }
    return headerSuccess();
}

export fn janet_zig_asm_scan_environments(
    _: ?*anyopaque,
    source: c.Janet,
) callconv(.c) BytecodeResult {
    const environments = janet_c_asm_get_field(source, "environments");
    var items: [*c]const c.Janet = null;
    var length: i32 = 0;
    if (c.janet_indexed_view(environments, &items, &length) == 0) {
        return bytecodeSuccess(-1);
    }
    return bytecodeSuccess(length);
}

export fn janet_zig_asm_fill_environments(
    assembler: ?*anyopaque,
    source: c.Janet,
) callconv(.c) HeaderResult {
    const environments = janet_c_asm_get_field(source, "environments");
    var items: [*c]const c.Janet = null;
    var length: i32 = 0;
    if (c.janet_indexed_view(environments, &items, &length) == 0) unreachable;
    const definition = janet_c_asm_funcdef(assembler);
    var index: i32 = 0;
    while (index < length) : (index += 1) {
        const value = items[@intCast(index)];
        if (c.janet_checkint(value) == 0) return headerFailure("expected integer");
        definition.*.environments[@intCast(index)] = integerValue(value);
    }
    return headerSuccess();
}

export fn janet_zig_asm_finalize(assembler: ?*anyopaque) callconv(.c) HeaderResult {
    const definition = janet_c_asm_funcdef(assembler);
    const verify_status = c.janet_verify(definition);
    if (verify_status != 0) {
        return .{
            .error_message = janet_c_asm_invalid_error(verify_status),
            .indexed_error = 0,
        };
    }
    janet_def_addflags(definition);
    return headerSuccess();
}

export fn janet_zig_asm_scan_defs(source: c.Janet) callconv(.c) BytecodeResult {
    var definitions = janet_c_asm_get_field(source, "closures");
    if (c.janet_checktype(definitions, c.JANET_NIL) != 0) {
        definitions = janet_c_asm_get_field(source, "defs");
    }
    var items: [*c]const c.Janet = null;
    var length: i32 = 0;
    if (c.janet_indexed_view(definitions, &items, &length) == 0) {
        return bytecodeSuccess(0);
    }
    return bytecodeSuccess(length);
}

export fn janet_zig_asm_def_at(source: c.Janet, index: i32) callconv(.c) c.Janet {
    var definitions = janet_c_asm_get_field(source, "closures");
    if (c.janet_checktype(definitions, c.JANET_NIL) != 0) {
        definitions = janet_c_asm_get_field(source, "defs");
    }
    var items: [*c]const c.Janet = null;
    var length: i32 = 0;
    if (c.janet_indexed_view(definitions, &items, &length) == 0) unreachable;
    return items[@intCast(index)];
}

export fn janet_zig_asm_register_def(
    assembler: ?*anyopaque,
    source: c.Janet,
    index: i32,
) callconv(.c) void {
    const name = janet_c_asm_get_field(source, "name");
    if (c.janet_checktype(name, c.JANET_NIL) == 0) {
        const definitions = janet_c_asm_argument_table(assembler, c.JANET_OAT_FUNCDEF).?;
        c.janet_table_put(definitions, name, janet_c_asm_wrap_integer(index));
    }
}

export fn janet_zig_asm_scan_bytecode(
    assembler: ?*anyopaque,
    source: c.Janet,
) callconv(.c) BytecodeResult {
    var items: [*c]const c.Janet = null;
    var length: i32 = 0;
    if (c.janet_indexed_view(source, &items, &length) == 0) {
        return bytecodeFailure("bytecode expected", true, 0);
    }
    const labels = janet_c_asm_argument_table(assembler, c.JANET_OAT_LABEL).?;
    var bytecode_length: i32 = 0;
    var index: i32 = 0;
    while (index < length) : (index += 1) {
        const instruction = items[@intCast(index)];
        if (c.janet_checktype(instruction, c.JANET_KEYWORD) != 0) {
            c.janet_table_put(labels, instruction, janet_c_asm_wrap_integer(bytecode_length));
        } else if (c.janet_checktype(instruction, c.JANET_TUPLE) != 0) {
            bytecode_length += 1;
        } else {
            return bytecodeFailure("expected assembly instruction", true, index);
        }
    }
    return bytecodeSuccess(bytecode_length);
}

export fn janet_zig_asm_fill_bytecode(
    assembler: ?*anyopaque,
    source: c.Janet,
) callconv(.c) BytecodeResult {
    var items: [*c]const c.Janet = null;
    var length: i32 = 0;
    if (c.janet_indexed_view(source, &items, &length) == 0) unreachable;
    const definition = janet_c_asm_funcdef(assembler);
    janet_c_asm_set_bytecode_count(assembler, 0);
    var index: i32 = 0;
    while (index < length) : (index += 1) {
        const instruction = items[@intCast(index)];
        if (c.janet_checktype(instruction, c.JANET_KEYWORD) != 0) continue;
        const tuple = c.janet_unwrap_tuple(instruction);
        const encoded = if (c.janet_tuple_length(tuple) == 0) success(0) else janet_zig_asm_encode(assembler, tuple);
        if (encoded.error_message != null) {
            return .{
                .count = janet_c_asm_bytecode_count(assembler),
                .error_message = encoded.error_message,
                .indexed_error = encoded.indexed_error,
                .error_index = index,
            };
        }
        const count = janet_c_asm_bytecode_count(assembler);
        definition.*.bytecode[@intCast(count)] = encoded.instruction;
        janet_c_asm_set_bytecode_count(assembler, count + 1);
    }
    return bytecodeSuccess(janet_c_asm_bytecode_count(assembler));
}

export fn janet_zig_asm_encode(
    assembler: ?*anyopaque,
    arguments: [*c]const c.Janet,
) callconv(.c) EncodeResult {
    if (!hasLengthAtLeast(arguments, 1)) return success(0);
    if (c.janet_checktype(arguments[0], c.JANET_SYMBOL) == 0) {
        return indexedFailure("expected symbol in assembly instruction");
    }
    const opcode = findOpcode(c.janet_unwrap_symbol(arguments[0])) orelse
        return exactFailure(janet_c_asm_unknown_instruction(arguments[0]));
    const instruction_type = c.janet_instructions[opcode];
    var instruction = opcode;
    switch (instruction_type) {
        c.JINT_0 => {
            if (!hasLength(arguments, 1)) return indexedFailure("expected 0 arguments: (op)");
        },
        c.JINT_S => {
            if (!hasLength(arguments, 2)) return indexedFailure("expected 1 argument: (op, slot)");
            const argument = packArgument(assembler, c.JANET_OAT_SLOT, 1, 2, false, arguments[1]);
            if (argument.error_message != null) return argument;
            instruction |= argument.instruction;
        },
        c.JINT_L => {
            if (!hasLength(arguments, 2)) return indexedFailure("expected 1 argument: (op, label)");
            const argument = packArgument(assembler, c.JANET_OAT_LABEL, 1, 3, true, arguments[1]);
            if (argument.error_message != null) return argument;
            instruction |= argument.instruction;
        },
        c.JINT_SS => {
            if (!hasLength(arguments, 3)) return indexedFailure("expected 2 arguments: (op, slot, slot)");
            const first = packArgument(assembler, c.JANET_OAT_SLOT, 1, 1, false, arguments[1]);
            if (first.error_message != null) return first;
            const second = packArgument(assembler, c.JANET_OAT_SLOT, 2, 2, false, arguments[2]);
            if (second.error_message != null) return second;
            instruction |= first.instruction | second.instruction;
        },
        c.JINT_SL => {
            if (!hasLength(arguments, 3)) return indexedFailure("expected 2 arguments: (op, slot, label)");
            const slot = packArgument(assembler, c.JANET_OAT_SLOT, 1, 1, false, arguments[1]);
            if (slot.error_message != null) return slot;
            const label = packArgument(assembler, c.JANET_OAT_LABEL, 2, 2, true, arguments[2]);
            if (label.error_message != null) return label;
            instruction |= slot.instruction | label.instruction;
        },
        c.JINT_ST => {
            if (!hasLength(arguments, 3)) return indexedFailure("expected 2 arguments: (op, slot, type)");
            const slot = packArgument(assembler, c.JANET_OAT_SLOT, 1, 1, false, arguments[1]);
            if (slot.error_message != null) return slot;
            const value_type = packArgument(assembler, c.JANET_OAT_TYPE, 2, 2, false, arguments[2]);
            if (value_type.error_message != null) return value_type;
            instruction |= slot.instruction | value_type.instruction;
        },
        c.JINT_SI, c.JINT_SU => {
            if (!hasLength(arguments, 3)) return indexedFailure("expected 2 arguments: (op, slot, integer)");
            const slot = packArgument(assembler, c.JANET_OAT_SLOT, 1, 1, false, arguments[1]);
            if (slot.error_message != null) return slot;
            const immediate = packArgument(
                assembler,
                c.JANET_OAT_INTEGER,
                2,
                2,
                instruction_type == c.JINT_SI,
                arguments[2],
            );
            if (immediate.error_message != null) return immediate;
            instruction |= slot.instruction | immediate.instruction;
        },
        c.JINT_SD => {
            if (!hasLength(arguments, 3)) return indexedFailure("expected 2 arguments: (op, slot, funcdef)");
            const slot = packArgument(assembler, c.JANET_OAT_SLOT, 1, 1, false, arguments[1]);
            if (slot.error_message != null) return slot;
            const definition = packArgument(assembler, c.JANET_OAT_FUNCDEF, 2, 2, false, arguments[2]);
            if (definition.error_message != null) return definition;
            instruction |= slot.instruction | definition.instruction;
        },
        c.JINT_SSS => {
            if (!hasLength(arguments, 4)) return indexedFailure("expected 3 arguments: (op, slot, slot, slot)");
            const first = packArgument(assembler, c.JANET_OAT_SLOT, 1, 1, false, arguments[1]);
            if (first.error_message != null) return first;
            const second = packArgument(assembler, c.JANET_OAT_SLOT, 2, 1, false, arguments[2]);
            if (second.error_message != null) return second;
            const third = packArgument(assembler, c.JANET_OAT_SLOT, 3, 1, false, arguments[3]);
            if (third.error_message != null) return third;
            instruction |= first.instruction | second.instruction | third.instruction;
        },
        c.JINT_SSI, c.JINT_SSU => {
            if (!hasLength(arguments, 4)) return indexedFailure("expected 3 arguments: (op, slot, slot, integer)");
            const first = packArgument(assembler, c.JANET_OAT_SLOT, 1, 1, false, arguments[1]);
            if (first.error_message != null) return first;
            const second = packArgument(assembler, c.JANET_OAT_SLOT, 2, 1, false, arguments[2]);
            if (second.error_message != null) return second;
            const immediate = packArgument(
                assembler,
                c.JANET_OAT_INTEGER,
                3,
                1,
                instruction_type == c.JINT_SSI,
                arguments[3],
            );
            if (immediate.error_message != null) return immediate;
            instruction |= first.instruction | second.instruction | immediate.instruction;
        },
        c.JINT_SES => {
            if (!hasLength(arguments, 4)) return indexedFailure("expected 3 arguments: (op, slot, environment, envslot)");
            const slot = packArgument(assembler, c.JANET_OAT_SLOT, 1, 1, false, arguments[1]);
            if (slot.error_message != null) return slot;
            const environment = packArgument(assembler, c.JANET_OAT_ENVIRONMENT, 0, 1, false, arguments[2]);
            if (environment.error_message != null) return environment;
            const parent = janet_c_asm_parent_for_environment(assembler, environment.instruction) orelse
                return indexedFailure("invalid environment index");
            const environment_slot = packArgument(parent, c.JANET_OAT_SLOT, 3, 1, false, arguments[3]);
            if (environment_slot.error_message != null) return environment_slot;
            instruction |= slot.instruction | (environment.instruction << 16) | environment_slot.instruction;
        },
        c.JINT_SC => {
            if (!hasLength(arguments, 3)) return indexedFailure("expected 2 arguments: (op, slot, constant)");
            const slot = packArgument(assembler, c.JANET_OAT_SLOT, 1, 1, false, arguments[1]);
            if (slot.error_message != null) return slot;
            const constant = packArgument(assembler, c.JANET_OAT_CONSTANT, 2, 2, false, arguments[2]);
            if (constant.error_message != null) return constant;
            instruction |= slot.instruction | constant.instruction;
        },
        else => return indexedFailure("unknown instruction layout"),
    }
    return success(instruction);
}

fn packArgument(
    assembler: ?*anyopaque,
    argument_type: i32,
    byte_index: u5,
    byte_count: i32,
    signed: bool,
    value: c.Janet,
) EncodeResult {
    const resolved = resolveArgument(assembler, argument_type, value);
    if (resolved.error_message != null) return exactFailure(resolved.error_message);
    const bit_count: u5 = @intCast(byte_count * 8);
    const maximum: i32 = (@as(i32, 1) << (bit_count - @intFromBool(signed))) - 1;
    const minimum: i32 = if (signed) -maximum - 1 else 0;
    if (resolved.value < minimum) {
        return exactFailure(janet_c_asm_argument_bounds_error(value, byte_count, 0));
    }
    if (resolved.value > maximum) {
        return exactFailure(janet_c_asm_argument_bounds_error(value, byte_count, 1));
    }
    const bits: u32 = @bitCast(resolved.value);
    return success(bits << (byte_index * 8));
}

fn resolveArgument(assembler: ?*anyopaque, argument_type: i32, value: c.Janet) ResolvedArgument {
    const table = janet_c_asm_argument_table(assembler, argument_type);
    var result: i32 = -1;
    switch (c.janet_type(value)) {
        c.JANET_NUMBER => {
            const number = c.janet_unwrap_number(value);
            if (number < minimum_i32_float or number > maximum_i32_float or @trunc(number) != number) {
                return resolutionFailure(value, 0);
            }
            result = @intFromFloat(number);
        },
        c.JANET_TUPLE => {
            if (argument_type != c.JANET_OAT_TYPE) return resolutionFailure(value, 0);
            const tuple = c.janet_unwrap_tuple(value);
            result = 0;
            var index: i32 = 0;
            while (index < c.janet_tuple_length(tuple)) : (index += 1) {
                const part = resolveArgument(assembler, c.JANET_OAT_SIMPLETYPE, tuple[@intCast(index)]);
                if (part.error_message != null) return part;
                result |= part.value;
            }
        },
        c.JANET_KEYWORD => {
            if (table != null and argument_type == c.JANET_OAT_LABEL) {
                const found = c.janet_table_get(table.?, value);
                if (c.janet_checktype(found, c.JANET_NUMBER) == 0) return resolutionFailure(value, 0);
                result = @intFromFloat(c.janet_unwrap_number(found));
                result -= janet_c_asm_bytecode_count(assembler);
            } else if (argument_type == c.JANET_OAT_TYPE or argument_type == c.JANET_OAT_SIMPLETYPE) {
                result = findTypeMask(c.janet_unwrap_keyword(value)) orelse return resolutionFailure(value, 1);
            } else {
                return resolutionFailure(value, 0);
            }
        },
        c.JANET_SYMBOL => {
            const argument_table = table orelse return resolutionFailure(value, 0);
            const found = c.janet_table_get(argument_table, value);
            if (c.janet_checktype(found, c.JANET_NUMBER) == 0) return resolutionFailure(value, 2);
            result = @intFromFloat(c.janet_unwrap_number(found));
            if (argument_type == c.JANET_OAT_ENVIRONMENT and result == -1) {
                result = janet_c_asm_add_environment(assembler, value);
                if (result < -1) return resolutionFailure(value, 3);
            }
        },
        else => return resolutionFailure(value, 0),
    }
    if (argument_type == c.JANET_OAT_SLOT) {
        const definition = janet_c_asm_funcdef(assembler);
        if (result >= definition.*.slotcount) definition.*.slotcount = result + 1;
    }
    return .{ .value = result };
}

fn resolutionFailure(value: c.Janet, kind: i32) ResolvedArgument {
    return .{ .value = -1, .error_message = janet_c_asm_resolution_error(value, kind) };
}

fn hasLength(arguments: [*c]const c.Janet, expected: i32) bool {
    return c.janet_tuple_length(arguments) == expected;
}

fn hasLengthAtLeast(arguments: [*c]const c.Janet, minimum: i32) bool {
    return c.janet_tuple_length(arguments) >= minimum;
}

fn findOpcode(name: [*c]const u8) ?u32 {
    var lower: usize = 0;
    var upper: usize = opcodes.len;
    while (lower < upper) {
        const middle = lower + (upper - lower) / 2;
        const comparison = c.janet_cstrcmp(name, opcodes[middle].name);
        if (comparison == 0) return opcodes[middle].opcode;
        if (comparison < 0) {
            upper = middle;
        } else {
            lower = middle + 1;
        }
    }
    return null;
}

fn findTypeMask(name: [*c]const u8) ?i32 {
    var lower: usize = 0;
    var upper: usize = type_aliases.len;
    while (lower < upper) {
        const middle = lower + (upper - lower) / 2;
        const comparison = c.janet_cstrcmp(name, type_aliases[middle].name);
        if (comparison == 0) return type_aliases[middle].mask;
        if (comparison < 0) {
            upper = middle;
        } else {
            lower = middle + 1;
        }
    }
    return null;
}

fn success(instruction: u32) EncodeResult {
    return .{ .instruction = instruction, .error_message = null, .indexed_error = 0 };
}

fn indexedFailure(message: [*:0]const u8) EncodeResult {
    return .{ .instruction = 0, .error_message = message, .indexed_error = 1 };
}

fn exactFailure(message: [*c]const u8) EncodeResult {
    return .{ .instruction = 0, .error_message = message, .indexed_error = 0 };
}

fn bytecodeSuccess(count: i32) BytecodeResult {
    return .{ .count = count, .error_message = null, .indexed_error = 0, .error_index = -1 };
}

fn bytecodeFailure(message: [*:0]const u8, indexed: bool, index: i32) BytecodeResult {
    return .{
        .count = 0,
        .error_message = message,
        .indexed_error = @intFromBool(indexed),
        .error_index = index,
    };
}

fn headerFailure(message: [*:0]const u8) HeaderResult {
    return .{ .error_message = message, .indexed_error = 1 };
}

fn headerSuccess() HeaderResult {
    return .{ .error_message = null, .indexed_error = 0 };
}

fn integerValue(value: c.Janet) i32 {
    return @intFromFloat(c.janet_unwrap_number(value));
}

const minimum_i32_float: f64 = -2147483648.0;
const maximum_i32_float: f64 = 2147483647.0;
const maximum_u32: u32 = 0xffffffff;
