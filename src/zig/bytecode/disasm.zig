//! Bytecode as text: one instruction decoded, and a whole `JanetFuncDef`
//! disassembled.
//!
//! Two files once, split along the C originals rather than along the subject:
//! a decoder -- an encoded word to the tuple `(op arg ...)`, the reverse of the
//! assembler's table -- and the `JanetFuncDef` walk that calls it once per
//! instruction. One is the other's inner loop, and neither has a name Janet
//! publishes or exists because a platform differs, so they are one file.
//!
//! While they were two objects, `disassembleBytecode` reached the decoder
//! through the C ABI, because that is the only thing that joins two
//! compilations. The call is direct now and the symbol is still exported.
//!
//! The two sets of `janet_c_*_wrap_*` helpers are deliberately **not**
//! collapsed. They look like duplicates and three of them are not --
//! `janet_c_asm_wrap_symbol` takes a `[*:0]const u8` where
//! `janet_c_disasm_wrap_symbol` takes a `c.JanetSymbol` -- and folding
//! near-identical private helpers is a content change, which is not what a
//! move batch is for.

const types = @import("types");
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

// ---------------------------------------------------------------------------
// One instruction, decoded -- what `asm_decode.zig` was.
// ---------------------------------------------------------------------------

/// The instruction name for an encoded word, or `null` for an opcode this
/// build does not know.
///
/// `asm.c` kept a second copy of the whole opcode table for this one reverse
/// lookup. `asm_encode.zig` has the table -- it is what the assembler matches
/// names against -- so the lookup is a walk over that and the duplicate is
/// gone.
fn asmOpcodeName(instruction: u32) ?[*:0]const u8 {
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
inline fn asmWrapInteger(val: i32) repr.Value {
    return wrap.fromNumber(@floatFromInt(val));
}

inline fn asmWrapSymbol(val: [*:0]const u8) repr.Value {
    return wrap.fromSymbol(symbols.csymbol(val));
}

inline fn asmWrapTuple(val: types.JanetTuple) repr.Value {
    return wrap.fromTuple(val);
}

/// `janet_tuple_flag(value) |= JANET_TUPLE_FLAG_BRACKETCTOR`, which is what
/// makes a disassembled instruction print as `[...]` rather than `(...)`.
///
/// The C name says "breakpoint" and the flag it sets does not; the name is
/// reproduced rather than corrected, because it is the symbol `asm.c`
/// exported and renaming it here would hide the discrepancy rather than
/// record it. `FOUND.md` has the entry.
///
inline fn asmSetBreakpoint(val: types.JanetTuple) void {
    types.tupleHead(val).gc.flags |= constants.JANET_TUPLE_FLAG_BRACKETCTOR;
}

pub fn asmDecodeInstruction(instruction: u32) repr.Value {
    const name_bytes = asmOpcodeName(instruction) orelse {
        return asmWrapInteger(@bitCast(instruction));
    };

    const gc_lock = gc_alloc.gclock();
    defer gc_alloc.gcunlock(gc_lock);

    const name = asmWrapSymbol(name_bytes);
    const opcode = instruction & 0x7f;
    const instruction_type = verify.instructions[opcode];
    const result = switch (instruction_type) {
        constants.JINT_0 => makeTuple(&.{name}),
        constants.JINT_S => makeTuple(&.{ name, integer(argument(instruction, 1, 0xffffff)) }),
        constants.JINT_L => makeTuple(&.{ name, integer(signedShift(instruction, 8)) }),
        constants.JINT_SS, constants.JINT_ST, constants.JINT_SC, constants.JINT_SU, constants.JINT_SD => makeTuple(&.{
            name,
            integer(argument(instruction, 1, 0xff)),
            integer(argument(instruction, 2, 0xffff)),
        }),
        constants.JINT_SI, constants.JINT_SL => makeTuple(&.{
            name,
            integer(argument(instruction, 1, 0xff)),
            integer(signedShift(instruction, 16)),
        }),
        constants.JINT_SSS, constants.JINT_SES, constants.JINT_SSU => makeTuple(&.{
            name,
            integer(argument(instruction, 1, 0xff)),
            integer(argument(instruction, 2, 0xff)),
            integer(argument(instruction, 3, 0xff)),
        }),
        constants.JINT_SSI => makeTuple(&.{
            name,
            integer(argument(instruction, 1, 0xff)),
            integer(argument(instruction, 2, 0xff)),
            integer(signedShift(instruction, 24)),
        }),
        else => return wrap.fromNil(),
    };

    if (instruction & 0x80 != 0) {
        asmSetBreakpoint(result);
    }
    return asmWrapTuple(result);
}

fn makeTuple(values: []const repr.Value) types.JanetTuple {
    const tuple = tuples.begin(@intCast(values.len));
    for (values, 0..) |val, index| tuple[index] = val;
    return tuples.end(tuple);
}

fn integer(val: i32) repr.Value {
    return asmWrapInteger(val);
}

fn argument(instruction: u32, byte: u5, mask: u32) i32 {
    return @intCast((instruction >> (byte * 8)) & mask);
}

fn signedShift(instruction: u32, shift: u5) i32 {
    const signed: i32 = @bitCast(instruction);
    return signed >> shift;
}

// ---------------------------------------------------------------------------
// A whole `JanetFuncDef`, disassembled -- what `disasm.zig` was.
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

// The nine wraps this file builds its table from. They were nine one-line C
// functions in `asm.c`, and they were there because `-Ddisasm` once had a C arm
// that had to share the runtime's own macros. Every `janet_wrap_*` except
// `janet_wrap_integer` is an ordinary exported function as well as a macro, so
// only that one needs writing out; see the note in `asm_decode.zig`.
inline fn disasmWrapNil() repr.Value {
    return wrap.fromNil();
}
inline fn disasmWrapInteger(val: i32) repr.Value {
    return wrap.fromNumber(@floatFromInt(val));
}
inline fn disasmWrapBoolean(val: c_int) repr.Value {
    return wrap.fromBoolean(val != 0);
}
inline fn disasmWrapString(val: types.JanetString) repr.Value {
    return wrap.fromString(val);
}
inline fn disasmWrapSymbol(val: types.JanetSymbol) repr.Value {
    return wrap.fromSymbol(val);
}
inline fn disasmWrapArray(val: *types.JanetArray) repr.Value {
    return wrap.fromArray(val);
}
inline fn disasmWrapTuple(val: types.JanetTuple) repr.Value {
    return wrap.fromTuple(val);
}
inline fn disasmWrapStruct(val: types.JanetStruct) repr.Value {
    return wrap.fromStruct(val);
}
inline fn disasmKeyword(val: [*:0]const u8) repr.Value {
    return wrap.fromKeyword(symbols.csymbol(val));
}

/// `janet_disasm`, the public entry. `asm.c` spelled it as a call into this
/// file with the `all` field; there is nothing else to it.
pub fn disasm(definition: *types.JanetFuncDef) repr.Value {
    return disassembleFieldExport(definition, @intFromEnum(Field.all));
}

pub fn disassembleFieldExport(definition: *types.JanetFuncDef, field_value: c_int) repr.Value {
    const gc_lock = gc_alloc.gclock();
    defer gc_alloc.gcunlock(gc_lock);
    return disassembleField(definition, @enumFromInt(field_value));
}

pub fn disassembleField(definition: *types.JanetFuncDef, field: Field) repr.Value {
    return switch (field) {
        .arity => wrapInteger(definition.arity),
        .min_arity => wrapInteger(definition.min_arity),
        .max_arity => wrapInteger(definition.max_arity),
        .bytecode => disassembleBytecode(definition),
        .source => if (definition.source) |source| disasmWrapString(source) else wrapNil(),
        .vararg => wrapBoolean(definition.flags & constants.JANET_FUNCDEF_FLAG_VARARG != 0),
        .structarg => wrapBoolean(definition.flags & constants.JANET_FUNCDEF_FLAG_STRUCTARG != 0),
        .namedargs => if (definition.flags & constants.JANET_FUNCDEF_FLAG_NAMEDARGS != 0)
            wrapInteger(definition.named_args_count)
        else
            wrapNil(),
        .name => if (definition.name) |name| disasmWrapString(name) else wrapNil(),
        .slotcount => wrapInteger(definition.slotcount),
        .symbolmap => disassembleSymbolMap(definition),
        .constants => disassembleConstants(definition),
        .sourcemap => disassembleSourceMap(definition),
        .environments => disassembleEnvironments(definition),
        .defs => disassembleDefinitions(definition),
        .all => disassembleAll(definition),
    };
}

fn disassembleSymbolMap(definition: *types.JanetFuncDef) repr.Value {
    if (definition.symbolmap == null) return wrapNil();
    const result = arrays.new(definition.symbolmap_length);
    const upvalue = disasmKeyword("upvalue");
    var index: i32 = 0;
    while (index < definition.symbolmap_length) : (index += 1) {
        const mapping = definition.symbols()[@intCast(index)];
        const tuple = tuples.begin(4);
        tuple[0] = if (mapping.birth_pc == std_max_u32)
            upvalue
        else
            wrapUnsigned(mapping.birth_pc);
        tuple[1] = wrapUnsigned(mapping.death_pc);
        tuple[2] = wrapUnsigned(mapping.slot_index);
        tuple[3] = disasmWrapSymbol(mapping.symbol.?);
        result.reserved()[@intCast(index)] = disasmWrapTuple(tuples.end(tuple));
    }
    result.count = definition.symbolmap_length;
    return disasmWrapArray(result);
}

fn disassembleBytecode(definition: *types.JanetFuncDef) repr.Value {
    const result = arrays.new(definition.bytecode_length);
    var index: i32 = 0;
    while (index < definition.bytecode_length) : (index += 1) {
        result.reserved()[@intCast(index)] = asmDecodeInstruction(definition.instructions()[@intCast(index)]);
    }
    result.count = definition.bytecode_length;
    return disasmWrapArray(result);
}

fn disassembleConstants(definition: *types.JanetFuncDef) repr.Value {
    const result = arrays.new(definition.constants_length);
    var index: i32 = 0;
    while (index < definition.constants_length) : (index += 1) {
        result.reserved()[@intCast(index)] = definition.constantValues()[@intCast(index)];
    }
    result.count = definition.constants_length;
    return disasmWrapArray(result);
}

fn disassembleSourceMap(definition: *types.JanetFuncDef) repr.Value {
    if (definition.sourcemap == null) return wrapNil();
    const result = arrays.new(definition.bytecode_length);
    var index: i32 = 0;
    while (index < definition.bytecode_length) : (index += 1) {
        const mapping = definition.sourceMappings()[@intCast(index)];
        const tuple = tuples.begin(2);
        tuple[0] = wrapInteger(mapping.line);
        tuple[1] = wrapInteger(mapping.column);
        result.reserved()[@intCast(index)] = disasmWrapTuple(tuples.end(tuple));
    }
    result.count = definition.bytecode_length;
    return disasmWrapArray(result);
}

fn disassembleEnvironments(definition: *types.JanetFuncDef) repr.Value {
    const result = arrays.new(definition.environments_length);
    var index: i32 = 0;
    while (index < definition.environments_length) : (index += 1) {
        result.reserved()[@intCast(index)] = wrapInteger(definition.environmentIndices()[@intCast(index)]);
    }
    result.count = definition.environments_length;
    return disasmWrapArray(result);
}

fn disassembleDefinitions(definition: *types.JanetFuncDef) repr.Value {
    const result = arrays.new(definition.defs_length);
    var index: i32 = 0;
    while (index < definition.defs_length) : (index += 1) {
        result.reserved()[@intCast(index)] = disassembleAll(definition.subdefs()[@intCast(index)]);
    }
    result.count = definition.defs_length;
    return disasmWrapArray(result);
}

fn disassembleAll(definition: *types.JanetFuncDef) repr.Value {
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

fn put(table: *types.JanetTable, key: [*:0]const u8, val: repr.Value) void {
    tables.put(table, disasmKeyword(key), val);
}

fn wrapNil() repr.Value {
    return disasmWrapNil();
}

fn wrapInteger(val: i32) repr.Value {
    return disasmWrapInteger(val);
}

fn wrapUnsigned(val: u32) repr.Value {
    return wrapInteger(@bitCast(val));
}

fn wrapBoolean(val: bool) repr.Value {
    return disasmWrapBoolean(@intFromBool(val));
}

const std_max_u32 = ~@as(u32, 0);
