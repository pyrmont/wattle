//! Bytecode as text: one instruction decoded, and a whole `functions.FuncDef`
//! disassembled.
//!
//! A decoder -- an encoded word to the tuple `(op arg ...)`, the reverse of the
//! assembler's table -- and the `FuncDef` walk that calls it once per
//! instruction. One is the other's inner loop, and neither has a name Janet
//! publishes or exists because a platform differs, so they are one file.

const repr = @import("repr");
const constants = @import("constants");

const asm_encode = @import("../bytecode.zig");
const gc_alloc = @import("../gc.zig");
const arrays = @import("../value/arrays.zig");
const symbols = @import("../value/symbols.zig");
const tables = @import("../value/tables.zig");
const tuples = @import("../value/tuples.zig");
const wrap = @import("../value/helpers/wrap.zig");
const verify = @import("verify.zig");
const strings = @import("../value/strings.zig");
const structs = @import("../value/structs.zig");
const functions = @import("../value/functions.zig");

// ---------------------------------------------------------------------------
// One instruction, decoded.
// ---------------------------------------------------------------------------

/// The instruction name for an encoded word, or `null` for an opcode this
/// build does not know.
///
/// A walk over the assembler's own table rather than a second copy of it: that
/// table is what the assembler matches names against, and one table means a
/// name that assembles is a name that disassembles.
fn asmOpcodeName(instruction: u32) ?[*:0]const u8 {
    const opcode = constants.Opcode.fromWord(instruction & 0x7F);
    for (asm_encode.opcodes) |def| {
        if (def.opcode == opcode) return def.name;
    }
    return null;
}

inline fn asmWrapSymbol(val: [*:0]const u8) repr.Value {
    return wrap.fromSymbol(symbols.csymbol(val));
}

inline fn asmWrapTuple(val: tuples.Tuple) repr.Value {
    return wrap.fromTuple(val);
}

/// `janet_tuple_flag(value) |= JANET_TUPLE_FLAG_BRACKETCTOR`, which is what
/// makes a disassembled instruction print as `[...]` rather than `(...)`.
inline fn asmMarkBracketed(val: tuples.Tuple) void {
    tuples.setBracketed(tuples.head(val));
}

pub fn asmDecodeInstruction(instruction: u32) repr.Value {
    const name_bytes = asmOpcodeName(instruction) orelse {
        return wrap.fromInteger(@bitCast(instruction));
    };

    const gc_lock = gc_alloc.gclock();
    defer gc_alloc.gcunlock(gc_lock);

    const name = asmWrapSymbol(name_bytes);
    const opcode = instruction & 0x7f;
    const instruction_type = verify.instructions[opcode];
    const result = switch (instruction_type) {
        constants.InstructionType.zero => makeTuple(&.{name}),
        constants.InstructionType.s => makeTuple(&.{ name, integer(argument(instruction, 1, 0xffffff)) }),
        constants.InstructionType.l => makeTuple(&.{ name, integer(signedShift(instruction, 8)) }),
        constants.InstructionType.ss, constants.InstructionType.st, constants.InstructionType.sc, constants.InstructionType.su, constants.InstructionType.sd => makeTuple(&.{
            name,
            integer(argument(instruction, 1, 0xff)),
            integer(argument(instruction, 2, 0xffff)),
        }),
        constants.InstructionType.si, constants.InstructionType.sl => makeTuple(&.{
            name,
            integer(argument(instruction, 1, 0xff)),
            integer(signedShift(instruction, 16)),
        }),
        constants.InstructionType.sss, constants.InstructionType.ses, constants.InstructionType.ssu => makeTuple(&.{
            name,
            integer(argument(instruction, 1, 0xff)),
            integer(argument(instruction, 2, 0xff)),
            integer(argument(instruction, 3, 0xff)),
        }),
        constants.InstructionType.ssi => makeTuple(&.{
            name,
            integer(argument(instruction, 1, 0xff)),
            integer(argument(instruction, 2, 0xff)),
            integer(signedShift(instruction, 24)),
        }),
    };

    if (instruction & 0x80 != 0) {
        asmMarkBracketed(result);
    }
    return asmWrapTuple(result);
}

fn makeTuple(values: []const repr.Value) tuples.Tuple {
    const tuple = tuples.begin(@intCast(values.len));
    for (values, 0..) |val, index| tuple[index] = val;
    return tuples.end(tuple);
}

fn integer(val: i32) repr.Value {
    return wrap.fromInteger(val);
}

fn argument(instruction: u32, byte: u5, mask: u32) i32 {
    return @intCast((instruction >> (byte * 8)) & mask);
}

fn signedShift(instruction: u32, shift: u5) i32 {
    const signed: i32 = @bitCast(instruction);
    return signed >> shift;
}

// ---------------------------------------------------------------------------
// A whole `functions.FuncDef`, disassembled.
// ---------------------------------------------------------------------------

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

// The eight wraps this file builds its table from, named locally so the table
// below reads as a table.
inline fn disasmWrapNil() repr.Value {
    return wrap.fromNil();
}
inline fn disasmWrapBoolean(val: c_int) repr.Value {
    return wrap.fromBoolean(val != 0);
}
inline fn disasmWrapString(val: strings.String) repr.Value {
    return wrap.fromString(val);
}
inline fn disasmWrapSymbol(val: strings.Symbol) repr.Value {
    return wrap.fromSymbol(val);
}
inline fn disasmWrapArray(val: *arrays.Array) repr.Value {
    return wrap.fromArray(val);
}
inline fn disasmWrapTuple(val: tuples.Tuple) repr.Value {
    return wrap.fromTuple(val);
}
inline fn disasmWrapStruct(val: structs.Struct) repr.Value {
    return wrap.fromStruct(val);
}
inline fn disasmKeyword(val: [*:0]const u8) repr.Value {
    return wrap.fromKeyword(symbols.csymbol(val));
}

/// The whole disassembly: `disassembleField` with the `all` field, and there is
/// nothing else to it.
pub fn disasm(definition: *functions.FuncDef) repr.Value {
    return disassembleFieldExport(definition, @intFromEnum(Field.all));
}

pub fn disassembleFieldExport(definition: *functions.FuncDef, field_value: c_int) repr.Value {
    const gc_lock = gc_alloc.gclock();
    defer gc_alloc.gcunlock(gc_lock);
    return disassembleField(definition, @enumFromInt(field_value));
}

pub fn disassembleField(definition: *functions.FuncDef, field: Field) repr.Value {
    return switch (field) {
        .arity => wrap.fromInteger(definition.arity),
        .min_arity => wrap.fromInteger(definition.min_arity),
        .max_arity => wrap.fromInteger(definition.max_arity),
        .bytecode => disassembleBytecode(definition),
        .source => if (definition.source) |source| disasmWrapString(source) else wrapNil(),
        .vararg => wrapBoolean(definition.flags.vararg),
        .structarg => wrapBoolean(definition.flags.structarg),
        .namedargs => if (definition.flags.namedargs)
            wrap.fromInteger(definition.named_args_count)
        else
            wrapNil(),
        .name => if (definition.name) |name| disasmWrapString(name) else wrapNil(),
        .slotcount => wrap.fromInteger(definition.slotcount),
        .symbolmap => disassembleSymbolMap(definition),
        .constants => disassembleConstants(definition),
        .sourcemap => disassembleSourceMap(definition),
        .environments => disassembleEnvironments(definition),
        .defs => disassembleDefinitions(definition),
        .all => disassembleAll(definition),
    };
}

fn disassembleSymbolMap(definition: *functions.FuncDef) repr.Value {
    if (definition.symbolmap == null) return wrapNil();
    const result = arrays.new(definition.symbolmap_length);
    const upvalue = disasmKeyword("upvalue");
    for (definition.symbols(), 0..) |mapping, index| {
        const tuple = tuples.begin(4);
        tuple[0] = if (mapping.birth_pc == std_max_u32)
            upvalue
        else
            wrapUnsigned(mapping.birth_pc);
        tuple[1] = wrapUnsigned(mapping.death_pc);
        tuple[2] = wrapUnsigned(mapping.slot_index);
        tuple[3] = disasmWrapSymbol(mapping.symbol.?);
        result.reserved()[index] = disasmWrapTuple(tuples.end(tuple));
    }
    result.count = definition.symbolmap_length;
    return disasmWrapArray(result);
}

fn disassembleBytecode(definition: *functions.FuncDef) repr.Value {
    const result = arrays.new(definition.bytecode_length);
    for (definition.instructions(), 0..) |instruction, index| {
        result.reserved()[index] = asmDecodeInstruction(instruction);
    }
    result.count = definition.bytecode_length;
    return disasmWrapArray(result);
}

fn disassembleConstants(definition: *functions.FuncDef) repr.Value {
    const result = arrays.new(definition.constants_length);
    for (definition.constantValues(), 0..) |constant, index| {
        result.reserved()[index] = constant;
    }
    result.count = definition.constants_length;
    return disasmWrapArray(result);
}

fn disassembleSourceMap(definition: *functions.FuncDef) repr.Value {
    if (definition.sourcemap == null) return wrapNil();
    const result = arrays.new(definition.bytecode_length);
    for (definition.sourceMappings(), 0..) |mapping, index| {
        const tuple = tuples.begin(2);
        tuple[0] = wrap.fromInteger(mapping.line);
        tuple[1] = wrap.fromInteger(mapping.column);
        result.reserved()[index] = disasmWrapTuple(tuples.end(tuple));
    }
    result.count = definition.bytecode_length;
    return disasmWrapArray(result);
}

fn disassembleEnvironments(definition: *functions.FuncDef) repr.Value {
    const result = arrays.new(definition.environments_length);
    for (definition.environmentIndices(), 0..) |environment, index| {
        result.reserved()[index] = wrap.fromInteger(environment);
    }
    result.count = definition.environments_length;
    return disasmWrapArray(result);
}

fn disassembleDefinitions(definition: *functions.FuncDef) repr.Value {
    const result = arrays.new(definition.defs_length);
    for (definition.subdefs(), 0..) |subdef, index| {
        result.reserved()[index] = disassembleAll(subdef);
    }
    result.count = definition.defs_length;
    return disasmWrapArray(result);
}

fn disassembleAll(definition: *functions.FuncDef) repr.Value {
    const result = tables.new(10);
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
    return disasmWrapStruct(tables.toStruct(result));
}

fn put(table: *tables.Table, key: [*:0]const u8, val: repr.Value) void {
    tables.put(table, disasmKeyword(key), val);
}

fn wrapNil() repr.Value {
    return disasmWrapNil();
}

fn wrapUnsigned(val: u32) repr.Value {
    return wrap.fromInteger(@bitCast(val));
}

fn wrapBoolean(val: bool) repr.Value {
    return disasmWrapBoolean(@intFromBool(val));
}

const std_max_u32 = ~@as(u32, 0);
