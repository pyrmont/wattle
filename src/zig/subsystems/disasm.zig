const abi = @import("abi");
const c = abi.c;

pub const Field = enum(c_int) {
    arity,
    min_arity,
    max_arity,
    bytecode,
    source,
    vararg,
    structarg,
    namedargs,
    name,
    slotcount,
    symbolmap,
    constants,
    sourcemap,
    environments,
    defs,
    all,
};

comptime {
    @export(&disassembleFieldExport, .{ .name = "janet_zig_disasm_field", .visibility = .hidden });
}

// The nine wraps this file builds its table from. They were nine one-line C
// functions in `asm.c`, and they were there because `-Ddisasm` once had a C arm
// that had to share the runtime's own macros. Every `janet_wrap_*` except
// `janet_wrap_integer` is an ordinary exported function as well as a macro, so
// only that one needs writing out; see the note in `asm_decode.zig`.
inline fn janet_c_disasm_wrap_nil() c.Janet {
    return c.janet_wrap_nil();
}
inline fn janet_c_disasm_wrap_integer(value: i32) c.Janet {
    return c.janet_wrap_number(@floatFromInt(value));
}
inline fn janet_c_disasm_wrap_boolean(value: c_int) c.Janet {
    return c.janet_wrap_boolean(value);
}
inline fn janet_c_disasm_wrap_string(value: c.JanetString) c.Janet {
    return c.janet_wrap_string(value);
}
inline fn janet_c_disasm_wrap_symbol(value: c.JanetSymbol) c.Janet {
    return c.janet_wrap_symbol(value);
}
inline fn janet_c_disasm_wrap_array(value: [*c]c.JanetArray) c.Janet {
    return c.janet_wrap_array(value);
}
inline fn janet_c_disasm_wrap_tuple(value: c.JanetTuple) c.Janet {
    return c.janet_wrap_tuple(value);
}
inline fn janet_c_disasm_wrap_struct(value: c.JanetStruct) c.Janet {
    return c.janet_wrap_struct(value);
}
inline fn janet_c_disasm_keyword(value: [*:0]const u8) c.Janet {
    return c.janet_wrap_keyword(c.janet_csymbol(value));
}

/// `janet_disasm`, the public entry. `asm.c` spelled it as a call into this
/// file with the `all` field; there is nothing else to it.
fn janetDisasm(definition: *c.JanetFuncDef) callconv(.c) c.Janet {
    return disassembleFieldExport(definition, @intFromEnum(Field.all));
}

comptime {
    @export(&janetDisasm, .{ .name = "janet_disasm" });
}

fn disassembleFieldExport(definition: *c.JanetFuncDef, field_value: c_int) callconv(.c) c.Janet {
    const gc_lock = c.janet_gclock();
    defer c.janet_gcunlock(gc_lock);
    return disassembleField(definition, @enumFromInt(field_value));
}

pub fn disassembleField(definition: *c.JanetFuncDef, field: Field) c.Janet {
    return switch (field) {
        .arity => wrapInteger(definition.arity),
        .min_arity => wrapInteger(definition.min_arity),
        .max_arity => wrapInteger(definition.max_arity),
        .bytecode => disassembleBytecode(definition),
        .source => if (definition.source == null) wrapNil() else janet_c_disasm_wrap_string(definition.source),
        .vararg => wrapBoolean(definition.flags & c.JANET_FUNCDEF_FLAG_VARARG != 0),
        .structarg => wrapBoolean(definition.flags & c.JANET_FUNCDEF_FLAG_STRUCTARG != 0),
        .namedargs => if (definition.flags & c.JANET_FUNCDEF_FLAG_NAMEDARGS != 0)
            wrapInteger(definition.named_args_count)
        else
            wrapNil(),
        .name => if (definition.name == null) wrapNil() else janet_c_disasm_wrap_string(definition.name),
        .slotcount => wrapInteger(definition.slotcount),
        .symbolmap => disassembleSymbolMap(definition),
        .constants => disassembleConstants(definition),
        .sourcemap => disassembleSourceMap(definition),
        .environments => disassembleEnvironments(definition),
        .defs => disassembleDefinitions(definition),
        .all => disassembleAll(definition),
    };
}

fn disassembleSymbolMap(definition: *c.JanetFuncDef) c.Janet {
    if (definition.symbolmap == null) return wrapNil();
    const result = c.janet_array(definition.symbolmap_length);
    const upvalue = janet_c_disasm_keyword("upvalue");
    var index: i32 = 0;
    while (index < definition.symbolmap_length) : (index += 1) {
        const mapping = definition.symbolmap[@intCast(index)];
        const tuple = c.janet_tuple_begin(4);
        tuple[0] = if (mapping.birth_pc == std_max_u32)
            upvalue
        else
            wrapUnsigned(mapping.birth_pc);
        tuple[1] = wrapUnsigned(mapping.death_pc);
        tuple[2] = wrapUnsigned(mapping.slot_index);
        tuple[3] = janet_c_disasm_wrap_symbol(mapping.symbol);
        result[0].data[@intCast(index)] = janet_c_disasm_wrap_tuple(c.janet_tuple_end(tuple));
    }
    result[0].count = definition.symbolmap_length;
    return janet_c_disasm_wrap_array(result);
}

fn disassembleBytecode(definition: *c.JanetFuncDef) c.Janet {
    const result = c.janet_array(definition.bytecode_length);
    var index: i32 = 0;
    while (index < definition.bytecode_length) : (index += 1) {
        result[0].data[@intCast(index)] = c.janet_asm_decode_instruction(definition.bytecode[@intCast(index)]);
    }
    result[0].count = definition.bytecode_length;
    return janet_c_disasm_wrap_array(result);
}

fn disassembleConstants(definition: *c.JanetFuncDef) c.Janet {
    const result = c.janet_array(definition.constants_length);
    var index: i32 = 0;
    while (index < definition.constants_length) : (index += 1) {
        result[0].data[@intCast(index)] = definition.constants[@intCast(index)];
    }
    result[0].count = definition.constants_length;
    return janet_c_disasm_wrap_array(result);
}

fn disassembleSourceMap(definition: *c.JanetFuncDef) c.Janet {
    if (definition.sourcemap == null) return wrapNil();
    const result = c.janet_array(definition.bytecode_length);
    var index: i32 = 0;
    while (index < definition.bytecode_length) : (index += 1) {
        const mapping = definition.sourcemap[@intCast(index)];
        const tuple = c.janet_tuple_begin(2);
        tuple[0] = wrapInteger(mapping.line);
        tuple[1] = wrapInteger(mapping.column);
        result[0].data[@intCast(index)] = janet_c_disasm_wrap_tuple(c.janet_tuple_end(tuple));
    }
    result[0].count = definition.bytecode_length;
    return janet_c_disasm_wrap_array(result);
}

fn disassembleEnvironments(definition: *c.JanetFuncDef) c.Janet {
    const result = c.janet_array(definition.environments_length);
    var index: i32 = 0;
    while (index < definition.environments_length) : (index += 1) {
        result[0].data[@intCast(index)] = wrapInteger(definition.environments[@intCast(index)]);
    }
    result[0].count = definition.environments_length;
    return janet_c_disasm_wrap_array(result);
}

fn disassembleDefinitions(definition: *c.JanetFuncDef) c.Janet {
    const result = c.janet_array(definition.defs_length);
    var index: i32 = 0;
    while (index < definition.defs_length) : (index += 1) {
        result[0].data[@intCast(index)] = disassembleAll(definition.defs[@intCast(index)]);
    }
    result[0].count = definition.defs_length;
    return janet_c_disasm_wrap_array(result);
}

fn disassembleAll(definition: *c.JanetFuncDef) c.Janet {
    const result = c.janet_table(10);
    put(result, "arity", disassembleField(definition, .arity));
    put(result, "min-arity", disassembleField(definition, .min_arity));
    put(result, "max-arity", disassembleField(definition, .max_arity));
    put(result, "bytecode", disassembleField(definition, .bytecode));
    put(result, "source", disassembleField(definition, .source));
    put(result, "vararg", disassembleField(definition, .vararg));
    put(result, "structarg", disassembleField(definition, .structarg));
    put(result, "namedargs", disassembleField(definition, .namedargs));
    put(result, "name", disassembleField(definition, .name));
    put(result, "slotcount", disassembleField(definition, .slotcount));
    put(result, "symbolmap", disassembleField(definition, .symbolmap));
    put(result, "constants", disassembleField(definition, .constants));
    put(result, "sourcemap", disassembleField(definition, .sourcemap));
    put(result, "environments", disassembleField(definition, .environments));
    put(result, "defs", disassembleField(definition, .defs));
    return janet_c_disasm_wrap_struct(c.janet_table_to_struct(result));
}

fn put(table: [*c]c.JanetTable, key: [*:0]const u8, value: c.Janet) void {
    c.janet_table_put(table, janet_c_disasm_keyword(key), value);
}

fn wrapNil() c.Janet {
    return janet_c_disasm_wrap_nil();
}

fn wrapInteger(value: i32) c.Janet {
    return janet_c_disasm_wrap_integer(value);
}

fn wrapUnsigned(value: u32) c.Janet {
    return wrapInteger(@bitCast(value));
}

fn wrapBoolean(value: bool) c.Janet {
    return janet_c_disasm_wrap_boolean(@intFromBool(value));
}

const std_max_u32 = ~@as(u32, 0);
