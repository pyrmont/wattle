//! Bytecode as text: one instruction decoded, and a whole `functions.FuncDef`
//! disassembled.
//!
//! `asmDecodeInstruction` turns one encoded word into the tuple
//! `(op arg ...)`, which is the reverse of the assembler's table.
//! `disassembleField` reads one field of a funcdef and `disasm` reads them
//! all. The first is the second's inner loop, and neither publishes a Janet
//! name of its own or exists because a platform differs, so they are one file.

// ==========================================================================
// Project imports
// ==========================================================================

const arrays = @import("../value/arrays.zig");
const asm_encode = @import("../bytecode.zig");
const constants = @import("constants");
const functions = @import("../value/functions.zig");
const gc_alloc = @import("../gc.zig");
const maps = @import("../value/maps.zig");
const repr = @import("repr");
const strings = @import("../value/strings.zig");
const symbols = @import("../value/symbols.zig");
const verify = @import("verify.zig");
const vm_state = @import("../vm/state.zig");
const vectors = @import("../value/vectors.zig");
const wrap = @import("../value/helpers/wrap.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// The `birth_pc` a symbol map entry uses to say that its slot is an upvalue
/// rather than a stack slot.
const std_max_u32 = ~@as(u32, 0);

// ==========================================================================
// Types
// ==========================================================================

/// Which part of a funcdef `disassembleField` reads, with `all` for the whole
/// struct. The numbering is what `disassembleFieldExport` takes across the
/// boundary.
pub const Field = enum(c_int) {
    arity,
    min_arity,
    max_arity,
    bytecode,
    source,
    vararg,
    maparg,
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

// ==========================================================================
// Public functions
// ==========================================================================

/// Decodes one instruction word into the tuple `(op arg ...)`.
///
/// An opcode this build has no name for decodes to the raw word as an integer
/// instead. A word with the breakpoint bit set decodes to a bracketed tuple,
/// which is what makes it print as `[...]`.
pub fn asmDecodeInstruction(instruction: u32) repr.Value {
    const name_bytes = asmOpcodeName(instruction) orelse {
        return wrap.fromInteger(@bitCast(instruction));
    };

    const gc_lock = gc_alloc.gclock(vm_state.current());
    defer gc_alloc.gcunlock(vm_state.current(), gc_lock);

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

    return asmWrapVector(result);
}

/// The whole disassembly, as a struct of every field.
pub fn disasm(definition: *functions.FuncDef) repr.Value {
    return disassembleFieldExport(definition, @intFromEnum(Field.all));
}

/// One field of `definition`, by `Field`.
pub fn disassembleField(definition: *functions.FuncDef, field: Field) repr.Value {
    return switch (field) {
        .arity => wrap.fromInteger(definition.arity),
        .min_arity => wrap.fromInteger(definition.min_arity),
        .max_arity => wrap.fromInteger(definition.max_arity),
        .bytecode => disassembleBytecode(definition),
        .source => if (definition.source) |source| disasmWrapString(source) else wrapNil(),
        .vararg => wrapBoolean(definition.flags.vararg),
        .maparg => wrapBoolean(definition.flags.maparg),
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

/// `disassembleField` by field number, under a collector lock.
///
/// The lock covers the whole walk because every arm allocates and none of the
/// intermediate values is rooted.
pub fn disassembleFieldExport(definition: *functions.FuncDef, field_value: c_int) repr.Value {
    const gc_lock = gc_alloc.gclock(vm_state.current());
    defer gc_alloc.gcunlock(vm_state.current(), gc_lock);
    return disassembleField(definition, @enumFromInt(field_value));
}

// ==========================================================================
// Private functions
// ==========================================================================

/// One byte-aligned field of an instruction word, masked to `mask`.
fn argument(instruction: u32, byte: u5, mask: u32) i32 {
    return @intCast((instruction >> (byte * 8)) & mask);
}

/// The instruction name for an encoded word, or null for an opcode the table
/// has no row for.
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

/// A decoded instruction's opcode name, as a symbol.
inline fn asmWrapSymbol(val: [*:0]const u8) repr.Value {
    return wrap.fromSymbol(symbols.csymbol(val));
}

/// A decoded instruction's vector, as a value.
inline fn asmWrapVector(val: *vectors.Vector) repr.Value {
    return wrap.fromVector(val);
}

/// The eight wraps the field walk is built from, named locally so that each
/// arm reads as one line.
inline fn disasmKeyword(val: [*:0]const u8) repr.Value {
    return wrap.fromKeyword(symbols.ckeyword(val));
}

inline fn disasmWrapArray(val: *arrays.Array) repr.Value {
    return wrap.fromArray(val);
}

inline fn disasmWrapBoolean(val: c_int) repr.Value {
    return wrap.fromBoolean(val != 0);
}

inline fn disasmWrapNil() repr.Value {
    return wrap.fromNil();
}

inline fn disasmWrapString(val: strings.String) repr.Value {
    return wrap.fromString(val);
}

inline fn disasmWrapSymbol(val: strings.Symbol) repr.Value {
    return wrap.fromSymbol(val);
}

inline fn disasmWrapVector(val: *vectors.Vector) repr.Value {
    return wrap.fromVector(val);
}

/// Every field of `definition`, as a map keyed by keyword. A subdefinition
/// is disassembled the same way, so this recurses through `defs`.
///
/// Built as the entries directly rather than into a table that is then frozen,
/// which is what it did while the result was a struct: the keys are fixed and
/// distinct, so there is nothing for a table's overwriting to do.
fn disassembleAll(definition: *functions.FuncDef) repr.Value {
    const fields = [_]repr.Value{
        disasmKeyword("arity"),        disassembleField(definition, .arity),
        disasmKeyword("min-arity"),    disassembleField(definition, .min_arity),
        disasmKeyword("max-arity"),    disassembleField(definition, .max_arity),
        disasmKeyword("bytecode"),     disassembleField(definition, .bytecode),
        disasmKeyword("source"),       disassembleField(definition, .source),
        disasmKeyword("vararg"),       disassembleField(definition, .vararg),
        disasmKeyword("maparg"),       disassembleField(definition, .maparg),
        disasmKeyword("namedargs"),    disassembleField(definition, .namedargs),
        disasmKeyword("name"),         disassembleField(definition, .name),
        disasmKeyword("slotcount"),    disassembleField(definition, .slotcount),
        disasmKeyword("symbolmap"),    disassembleField(definition, .symbolmap),
        disasmKeyword("constants"),    disassembleField(definition, .constants),
        disasmKeyword("sourcemap"),    disassembleField(definition, .sourcemap),
        disasmKeyword("environments"), disassembleField(definition, .environments),
        disasmKeyword("defs"),         disassembleField(definition, .defs),
    };
    return wrap.fromMap(maps.build(.map, &fields));
}

/// Every instruction of `definition`, decoded, as an array.
fn disassembleBytecode(definition: *functions.FuncDef) repr.Value {
    const result = arrays.new(definition.bytecode_length);
    for (definition.instructions(), 0..) |instruction, index| {
        result.reserved()[index] = asmDecodeInstruction(instruction);
    }
    result.count = definition.bytecode_length;
    return disasmWrapArray(result);
}

/// `definition`'s constant pool, as an array.
fn disassembleConstants(definition: *functions.FuncDef) repr.Value {
    const result = arrays.new(definition.constants_length);
    for (definition.constantValues(), 0..) |constant, index| {
        result.reserved()[index] = constant;
    }
    result.count = definition.constants_length;
    return disasmWrapArray(result);
}

/// `definition`'s nested definitions, each disassembled in full.
fn disassembleDefinitions(definition: *functions.FuncDef) repr.Value {
    const result = arrays.new(definition.defs_length);
    for (definition.subdefs(), 0..) |subdef, index| {
        result.reserved()[index] = disassembleAll(subdef);
    }
    result.count = definition.defs_length;
    return disasmWrapArray(result);
}

/// `definition`'s captured environment indices, as an array.
fn disassembleEnvironments(definition: *functions.FuncDef) repr.Value {
    const result = arrays.new(definition.environments_length);
    for (definition.environmentIndices(), 0..) |environment, index| {
        result.reserved()[index] = wrap.fromInteger(environment);
    }
    result.count = definition.environments_length;
    return disasmWrapArray(result);
}

/// `definition`'s source map, as an array of `[line column]` vectors, or nil
/// where it has none.
fn disassembleSourceMap(definition: *functions.FuncDef) repr.Value {
    if (definition.sourcemap == null) return wrapNil();
    const result = arrays.new(definition.bytecode_length);
    for (definition.sourceMappings(), 0..) |mapping, index| {
        const pair = [2]repr.Value{
            wrap.fromInteger(mapping.line),
            wrap.fromInteger(mapping.column),
        };
        result.reserved()[index] = disasmWrapVector(vectors.fromSlice(&pair));
    }
    result.count = definition.bytecode_length;
    return disasmWrapArray(result);
}

/// `definition`'s symbol map, as an array of
/// `[birth death slot symbol]` vectors, or nil where it has none. An upvalue
/// entry has the keyword `:upvalue` in place of its birth position.
fn disassembleSymbolMap(definition: *functions.FuncDef) repr.Value {
    if (definition.symbolmap == null) return wrapNil();
    const result = arrays.new(definition.symbolmap_length);
    const upvalue = disasmKeyword("upvalue");
    for (definition.symbols(), 0..) |mapping, index| {
        const quad = [4]repr.Value{
            if (mapping.birth_pc == std_max_u32) upvalue else wrapUnsigned(mapping.birth_pc),
            wrapUnsigned(mapping.death_pc),
            wrapUnsigned(mapping.slot_index),
            disasmWrapSymbol(mapping.symbol.?),
        };
        result.reserved()[index] = disasmWrapVector(vectors.fromSlice(&quad));
    }
    result.count = definition.symbolmap_length;
    return disasmWrapArray(result);
}

/// An `i32` as a value.
fn integer(val: i32) repr.Value {
    return wrap.fromInteger(val);
}

/// A vector of `values`.
///
/// A disassembled instruction is data and is spelled `[ ]`, which is what the
/// assembler reads one back from.
fn makeTuple(values: []const repr.Value) *vectors.Vector {
    return vectors.fromSlice(values);
}

/// A signed instruction field, as an arithmetic right shift of the word
/// reinterpreted as a signed 32-bit integer.
fn signedShift(instruction: u32, shift: u5) i32 {
    const signed: i32 = @bitCast(instruction);
    return signed >> shift;
}

/// A `bool` as a value.
fn wrapBoolean(val: bool) repr.Value {
    return disasmWrapBoolean(@intFromBool(val));
}

/// Nil, as a value.
fn wrapNil() repr.Value {
    return disasmWrapNil();
}

/// A `u32` as a value, reinterpreted rather than widened.
fn wrapUnsigned(val: u32) repr.Value {
    return wrap.fromInteger(@bitCast(val));
}
