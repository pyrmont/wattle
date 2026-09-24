//! The assembler: `(asm ...)` from a Janet data structure to a
//! `functions.FuncDef`.
//!
//! `assembleValue` is the entry point and reports an `AssembleResult` rather
//! than raising. `libAsm` installs `asm` and `disasm`.
//!
//! Two halves under one name. A driver does the argument checking, the error
//! paths and the `FuncDef` it hands back. An encoder has the opcode table and
//! the per-field scan and fill passes over it: each `scan*` counts what a
//! source declares so the driver can allocate, and each `fill*` writes it in.
//! `getFieldByName` is the encoder's lookup; `getField` is the driver's
//! private helper and is a different thing.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const args_core = @import("args.zig");
const vectors = @import("value/vectors.zig");
const fatal = @import("fatal.zig");
const gc_alloc = @import("gc.zig");
const compiler_primitives = @import("compiler.zig");
const constants = @import("constants");
const corefn = @import("corefn.zig");
const disasm = @import("bytecode/disasm.zig");
const functions = @import("value/functions.zig");
const maps = @import("value/maps.zig");
const order = @import("value/helpers/order.zig");
const pp_describe = @import("pp.zig");
const pp_format = @import("pp/format.zig");
const raise = @import("../api/raise.zig");
const repr = @import("repr");
const strings = @import("value/strings.zig");
const tables = @import("value/tables.zig");
const utils = @import("utils.zig");
const value = @import("value.zig");
const verify = @import("bytecode/verify.zig");
const vm_lifecycle = @import("vm/lifecycle.zig");
const wrap = @import("value/helpers/wrap.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// The keyword-to-field table `disasm`'s optional second argument selects on.
/// One entry per `disasm.Field`, in the comparison order the chain relies on.
const disasm_fields = [_]struct { name: [*:0]const u8, field: disasm.Field }{
    .{ .name = "arity", .field = .arity },
    .{ .name = "min-arity", .field = .min_arity },
    .{ .name = "max-arity", .field = .max_arity },
    .{ .name = "bytecode", .field = .bytecode },
    .{ .name = "source", .field = .source },
    .{ .name = "name", .field = .name },
    .{ .name = "vararg", .field = .vararg },
    .{ .name = "maparg", .field = .maparg },
    .{ .name = "namedargs", .field = .namedargs },
    .{ .name = "slotcount", .field = .slotcount },
    .{ .name = "symbolmap", .field = .symbolmap },
    .{ .name = "constants", .field = .constants },
    .{ .name = "sourcemap", .field = .sourcemap },
    .{ .name = "environments", .field = .environments },
    .{ .name = "defs", .field = .defs },
};

/// The bounds an operand is checked against before it is packed. The two
/// floats are the range a Janet number may occupy and still be an `i32`.
const maximum_i32_float: f64 = 2147483647.0;
const maximum_u32: u32 = 0xffffffff;
const minimum_i32_float: f64 = -2147483648.0;

/// The opcode table, sorted by name so that `findOpcode` can bisect it. It is
/// also what `bytecode/disasm.zig` walks to turn an opcode back into a name.
pub const opcodes = [_]OpcodeDefinition{
    .{ .name = "add", .opcode = constants.Opcode.add },
    .{ .name = "addim", .opcode = constants.Opcode.add_immediate },
    .{ .name = "band", .opcode = constants.Opcode.band },
    .{ .name = "bnot", .opcode = constants.Opcode.bnot },
    .{ .name = "bor", .opcode = constants.Opcode.bor },
    .{ .name = "bxor", .opcode = constants.Opcode.bxor },
    .{ .name = "call", .opcode = constants.Opcode.call },
    .{ .name = "clo", .opcode = constants.Opcode.closure },
    .{ .name = "cmp", .opcode = constants.Opcode.compare },
    .{ .name = "cncl", .opcode = constants.Opcode.cancel },
    .{ .name = "div", .opcode = constants.Opcode.divide },
    .{ .name = "divf", .opcode = constants.Opcode.divide_floor },
    .{ .name = "divim", .opcode = constants.Opcode.divide_immediate },
    .{ .name = "eq", .opcode = constants.Opcode.equals },
    .{ .name = "eqim", .opcode = constants.Opcode.equals_immediate },
    .{ .name = "err", .opcode = constants.Opcode.@"error" },
    .{ .name = "get", .opcode = constants.Opcode.get },
    .{ .name = "geti", .opcode = constants.Opcode.get_index },
    .{ .name = "gt", .opcode = constants.Opcode.greater_than },
    .{ .name = "gte", .opcode = constants.Opcode.greater_than_equal },
    .{ .name = "gtim", .opcode = constants.Opcode.greater_than_immediate },
    .{ .name = "in", .opcode = constants.Opcode.in },
    .{ .name = "jmp", .opcode = constants.Opcode.jump },
    .{ .name = "jmpif", .opcode = constants.Opcode.jump_if },
    .{ .name = "jmpna", .opcode = constants.Opcode.jump_if_not_arity },
    .{ .name = "jmpni", .opcode = constants.Opcode.jump_if_nil },
    .{ .name = "jmpnn", .opcode = constants.Opcode.jump_if_not_nil },
    .{ .name = "jmpno", .opcode = constants.Opcode.jump_if_not },
    .{ .name = "ldc", .opcode = constants.Opcode.load_constant },
    .{ .name = "ldf", .opcode = constants.Opcode.load_false },
    .{ .name = "ldi", .opcode = constants.Opcode.load_integer },
    .{ .name = "ldn", .opcode = constants.Opcode.load_nil },
    .{ .name = "lds", .opcode = constants.Opcode.load_self },
    .{ .name = "ldt", .opcode = constants.Opcode.load_true },
    .{ .name = "ldu", .opcode = constants.Opcode.load_upvalue },
    .{ .name = "len", .opcode = constants.Opcode.length },
    .{ .name = "lt", .opcode = constants.Opcode.less_than },
    .{ .name = "lte", .opcode = constants.Opcode.less_than_equal },
    .{ .name = "ltim", .opcode = constants.Opcode.less_than_immediate },
    .{ .name = "mkarr", .opcode = constants.Opcode.make_array },
    .{ .name = "mkbuf", .opcode = constants.Opcode.make_buffer },
    .{ .name = "mkmap", .opcode = constants.Opcode.make_map },
    .{ .name = "mkstr", .opcode = constants.Opcode.make_string },
    .{ .name = "mktab", .opcode = constants.Opcode.make_table },
    .{ .name = "mktup", .opcode = constants.Opcode.make_tuple },
    .{ .name = "mkvec", .opcode = constants.Opcode.make_vector },
    .{ .name = "mod", .opcode = constants.Opcode.modulo },
    .{ .name = "movf", .opcode = constants.Opcode.move_far },
    .{ .name = "movn", .opcode = constants.Opcode.move_near },
    .{ .name = "mul", .opcode = constants.Opcode.multiply },
    .{ .name = "mulim", .opcode = constants.Opcode.multiply_immediate },
    .{ .name = "neq", .opcode = constants.Opcode.not_equals },
    .{ .name = "neqim", .opcode = constants.Opcode.not_equals_immediate },
    .{ .name = "next", .opcode = constants.Opcode.next },
    .{ .name = "noop", .opcode = constants.Opcode.noop },
    .{ .name = "prop", .opcode = constants.Opcode.propagate },
    .{ .name = "push", .opcode = constants.Opcode.push },
    .{ .name = "push2", .opcode = constants.Opcode.push_2 },
    .{ .name = "push3", .opcode = constants.Opcode.push_3 },
    .{ .name = "pusha", .opcode = constants.Opcode.push_array },
    .{ .name = "put", .opcode = constants.Opcode.put },
    .{ .name = "puti", .opcode = constants.Opcode.put_index },
    .{ .name = "rem", .opcode = constants.Opcode.remainder },
    .{ .name = "res", .opcode = constants.Opcode.@"resume" },
    .{ .name = "ret", .opcode = constants.Opcode.@"return" },
    .{ .name = "retn", .opcode = constants.Opcode.return_nil },
    .{ .name = "setu", .opcode = constants.Opcode.set_upvalue },
    .{ .name = "sig", .opcode = constants.Opcode.signal },
    .{ .name = "sl", .opcode = constants.Opcode.shift_left },
    .{ .name = "slim", .opcode = constants.Opcode.shift_left_immediate },
    .{ .name = "sr", .opcode = constants.Opcode.shift_right },
    .{ .name = "srim", .opcode = constants.Opcode.shift_right_immediate },
    .{ .name = "sru", .opcode = constants.Opcode.shift_right_unsigned },
    .{ .name = "sruim", .opcode = constants.Opcode.shift_right_unsigned_immediate },
    .{ .name = "sub", .opcode = constants.Opcode.subtract },
    .{ .name = "subim", .opcode = constants.Opcode.subtract_immediate },
    .{ .name = "tcall", .opcode = constants.Opcode.tailcall },
    .{ .name = "tchck", .opcode = constants.Opcode.typecheck },
};

/// The type-alias table an operand of kind `type` resolves in, sorted by name
/// so that `findTypeMask` can bisect it.
const type_aliases = [_]TypeAlias{
    .{ .name = "abstract", .mask = repr.TagSet.one(.abstract) },
    .{ .name = "array", .mask = repr.TagSet.one(.array) },
    .{ .name = "boolean", .mask = repr.TagSet.one(.boolean) },
    .{ .name = "buffer", .mask = repr.TagSet.one(.buffer) },
    .{ .name = "callable", .mask = repr.TagSet.callable },
    .{ .name = "dictionary", .mask = repr.TagSet.dictionary },
    .{ .name = "fiber", .mask = repr.TagSet.one(.fiber) },
    .{ .name = "function", .mask = repr.TagSet.one(.function) },
    .{ .name = "indexed", .mask = repr.TagSet.indexed },
    .{ .name = "keyword", .mask = repr.TagSet.one(.symbol) },
    .{ .name = "map", .mask = repr.TagSet.one(.map) },
    .{ .name = "nfunction", .mask = repr.TagSet.one(.nfunction) },
    .{ .name = "nil", .mask = repr.TagSet.one(.nil) },
    .{ .name = "number", .mask = repr.TagSet.one(.number) },
    .{ .name = "pointer", .mask = repr.TagSet.one(.pointer) },
    .{ .name = "string", .mask = repr.TagSet.one(.string) },
    .{ .name = "symbol", .mask = repr.TagSet.one(.symbol) },
    .{ .name = "table", .mask = repr.TagSet.one(.table) },
    .{ .name = "tuple", .mask = repr.TagSet.one(.tuple) },
    .{ .name = "vector", .mask = repr.TagSet.one(.vector) },
};

// ==========================================================================
// Types
// ==========================================================================

/// The assembler's own failure, and not a Janet signal. One member, because
/// the message travels in the assembler rather than in the error.
///
/// A failing site picks the channel it needs: `Assembler.fail` for a fault
/// that names the instruction it happened at, `Assembler.failv` for one whose
/// message is already complete.
const AsmError = error{Assembly};

/// What an assembly produced: a definition, or a message and an error status.
pub const AssembleResult = extern struct {
    funcdef: ?*functions.FuncDef = null,
    @"error": ?strings.String = null,
    status: AssembleStatus = .ok,
};

/// Whether an assembly produced a definition or a message. Two members, and
/// nothing outside this runtime supplies one.
pub const AssembleStatus = enum(u32) {
    ok = 0,
    @"error" = 1,
};

/// One assembly's state: the funcdef being built, the parent it resolves
/// enclosing names against, the pending failure, and the four tables the
/// operand kinds resolve their names in. The encoder is in this file and
/// reaches it directly.
/// The elements of an indexed value as one block, copying a vector's runs.
///
/// Every reader below wants one slice. An array's and a tuple's elements are
/// already one; a vector's are leaves of a trie, so they are gathered into
/// scratch and the caller frees. Assembly source written in Wattle spells a
/// list and an instruction `[ ]`, and `disasm` builds both as vectors.
const AsmItems = struct {
    items: []const repr.Value,
    owned: bool,

    fn free(self: AsmItems) void {
        if (self.owned) gc_alloc.scratch_heap.free(@constCast(self.items));
    }
};

fn asmItems(x: repr.Value) ?AsmItems {
    if (args_core.items(x)) |elements| return .{ .items = elements, .owned = false };
    if (!repr.checkType(x, repr.Tag.vector)) return null;
    const v = wrap.toVector(x);
    const block = gc_alloc.scratch_heap.alloc(repr.Value, v.count) catch
        fatal.outOfMemory();
    var index: usize = 0;
    while (index < v.count) {
        const run = vectors.chunk(v, index);
        @memcpy(block[index..][0..run.len], run.items.?[0..run.len]);
        index += run.len;
    }
    return .{ .items = block, .owned = true };
}

const Assembler = struct {
    parent: ?*Assembler,
    def: *functions.FuncDef,
    errmessage: ?[*:0]const u8,
    errindex: i32,

    environments_capacity: i32,
    defs_capacity: i32,
    bytecode_count: i32,

    name: repr.Value,
    labels: tables.Table,
    slots: tables.Table,
    envs: tables.Table,
    defs: tables.Table,

    /// Sets up an assembler over `def`, with `parent` as the scope enclosing
    /// names resolve in.
    fn init(self: *Assembler, parent: ?*Assembler, def: *functions.FuncDef) void {
        self.* = .{
            .parent = parent,
            .def = def,
            .errmessage = null,
            .errindex = 0,
            .environments_capacity = 0,
            .defs_capacity = 0,
            .bytecode_count = 0,
            .name = wrap.fromNil(),
            .labels = undefined,
            .slots = undefined,
            .envs = undefined,
            .defs = undefined,
        };
        // `tables.init` returns the table it initialised, and none of these
        // four call sites needs the result.
        _ = tables.init(&self.labels, 0);
        _ = tables.init(&self.slots, 0);
        _ = tables.init(&self.envs, 0);
        _ = tables.init(&self.defs, 0);
    }

    /// Releases the four tables. The parents are left alone: each is released
    /// by its own frame.
    fn deinit(self: *Assembler) void {
        tables.deinit(&self.slots);
        tables.deinit(&self.labels);
        tables.deinit(&self.envs);
        tables.deinit(&self.defs);
    }

    /// Records `message` as the failure and returns `error.Assembly`.
    ///
    /// The index suffix is appended exactly when `errindex` is non-negative,
    /// which is how a bytecode fault names its instruction and a header fault
    /// does not.
    fn fail(self: *Assembler, message: ?[*:0]const u8) AsmError {
        self.errmessage = if (self.errindex < 0)
            pp_format.formatcReported("%s", .{message})
        else
            pp_format.formatcReported("%s, instruction %d", .{ message, self.errindex });
        return error.Assembly;
    }

    /// Records `message` as the failure and returns `error.Assembly`, with the
    /// message taken unaltered, index or no index.
    fn failv(self: *Assembler, message: ?[*:0]const u8) AsmError {
        self.errmessage = message;
        return error.Assembly;
    }
};

/// One row of `opcodes`: an instruction name and the opcode it assembles to.
const OpcodeDefinition = struct {
    name: [*:0]const u8,
    opcode: constants.Opcode,
};

/// One row of `type_aliases`: a type name and the tag set it stands for.
const TypeAlias = struct {
    name: [*:0]const u8,
    mask: repr.TagSet,
};

// ==========================================================================
// Public functions
// ==========================================================================

/// The message for an operand that will not fit its field.
pub fn argumentBoundsError(x: repr.Value, nbytes: i32, too_large: i32) [*:0]const u8 {
    // Through a sentinel pointer rather than a slice, because `%s` renders a
    // NUL-terminated run of bytes and a slice is not one.
    const plural: [*]const u8 = if (nbytes > 1) "s" else "";
    // Two calls rather than one: the format string is `comptime`, so a
    // runtime `if` cannot choose between two of them.
    return if (too_large != 0)
        pp_format.formatcReported("instruction argument %v is too large, must be %d byte%s", .{ x, nbytes, plural })
    else
        pp_format.formatcReported("instruction argument %v is too small, must be %d byte%s", .{ x, nbytes, plural });
}

/// The table an operand kind resolves its names in, or null for a kind that
/// resolves in none.
pub fn argumentTable(a: *Assembler, argument_type: constants.OperandKind) ?*tables.Table {
    return switch (argument_type) {
        .slot => &a.slots,
        .environment => &a.envs,
        .label => &a.labels,
        .funcdef => &a.defs,
        else => null,
    };
}

/// Encodes one instruction tuple into its bytecode word.
///
/// `a` is the context the operands resolve against; the message of a failure
/// lands in it too, except that an environment slot resolves against an
/// ancestor, so `packArgument` is told the two separately.
pub fn asmEncode(
    a: *Assembler,
    arguments: []const repr.Value,
) AsmError!u32 {
    if (arguments.len < 1) return 0;
    if (!wrap.isSymbol(arguments[0])) {
        return a.fail("expected symbol in assembly instruction");
    }
    const opcode = findOpcode(wrap.toSymbol(arguments[0])) orelse
        return a.failv(unknownInstruction(arguments[0]));
    const instruction_type = verify.instructions[opcode.number()];
    var instruction: u32 = opcode.number();
    switch (instruction_type) {
        constants.InstructionType.zero => {
            if (!hasLength(arguments, 1)) return a.fail("expected 0 arguments: (op)");
        },
        constants.InstructionType.s => {
            if (!hasLength(arguments, 2)) return a.fail("expected 1 argument: (op, slot)");
            instruction |= try packArgument(a, a, constants.OperandKind.slot, 1, 2, false, arguments[1]);
        },
        constants.InstructionType.l => {
            if (!hasLength(arguments, 2)) return a.fail("expected 1 argument: (op, label)");
            instruction |= try packArgument(a, a, constants.OperandKind.label, 1, 3, true, arguments[1]);
        },
        constants.InstructionType.ss => {
            if (!hasLength(arguments, 3)) return a.fail("expected 2 arguments: (op, slot, slot)");
            const first = try packArgument(a, a, constants.OperandKind.slot, 1, 1, false, arguments[1]);
            const second = try packArgument(a, a, constants.OperandKind.slot, 2, 2, false, arguments[2]);
            instruction |= first | second;
        },
        constants.InstructionType.sl => {
            if (!hasLength(arguments, 3)) return a.fail("expected 2 arguments: (op, slot, label)");
            const slot = try packArgument(a, a, constants.OperandKind.slot, 1, 1, false, arguments[1]);
            const label = try packArgument(a, a, constants.OperandKind.label, 2, 2, true, arguments[2]);
            instruction |= slot | label;
        },
        constants.InstructionType.il => {
            if (!hasLength(arguments, 3)) return a.fail("expected 2 arguments: (op, integer, label)");
            const count = try packArgument(a, a, constants.OperandKind.integer, 1, 1, false, arguments[1]);
            const label = try packArgument(a, a, constants.OperandKind.label, 2, 2, true, arguments[2]);
            instruction |= count | label;
        },
        constants.InstructionType.st => {
            if (!hasLength(arguments, 3)) return a.fail("expected 2 arguments: (op, slot, type)");
            const slot = try packArgument(a, a, constants.OperandKind.slot, 1, 1, false, arguments[1]);
            const value_type = try packArgument(a, a, constants.OperandKind.type, 2, 2, false, arguments[2]);
            instruction |= slot | value_type;
        },
        constants.InstructionType.si, constants.InstructionType.su => {
            if (!hasLength(arguments, 3)) return a.fail("expected 2 arguments: (op, slot, integer)");
            const slot = try packArgument(a, a, constants.OperandKind.slot, 1, 1, false, arguments[1]);
            const immediate = try packArgument(
                a,
                a,
                constants.OperandKind.integer,
                2,
                2,
                instruction_type == constants.InstructionType.si,
                arguments[2],
            );
            instruction |= slot | immediate;
        },
        constants.InstructionType.sd => {
            if (!hasLength(arguments, 3)) return a.fail("expected 2 arguments: (op, slot, funcdef)");
            const slot = try packArgument(a, a, constants.OperandKind.slot, 1, 1, false, arguments[1]);
            const definition = try packArgument(a, a, constants.OperandKind.funcdef, 2, 2, false, arguments[2]);
            instruction |= slot | definition;
        },
        constants.InstructionType.sss => {
            if (!hasLength(arguments, 4)) return a.fail("expected 3 arguments: (op, slot, slot, slot)");
            const first = try packArgument(a, a, constants.OperandKind.slot, 1, 1, false, arguments[1]);
            const second = try packArgument(a, a, constants.OperandKind.slot, 2, 1, false, arguments[2]);
            const third = try packArgument(a, a, constants.OperandKind.slot, 3, 1, false, arguments[3]);
            instruction |= first | second | third;
        },
        constants.InstructionType.ssi, constants.InstructionType.ssu => {
            if (!hasLength(arguments, 4)) return a.fail("expected 3 arguments: (op, slot, slot, integer)");
            const first = try packArgument(a, a, constants.OperandKind.slot, 1, 1, false, arguments[1]);
            const second = try packArgument(a, a, constants.OperandKind.slot, 2, 1, false, arguments[2]);
            const immediate = try packArgument(
                a,
                a,
                constants.OperandKind.integer,
                3,
                1,
                instruction_type == constants.InstructionType.ssi,
                arguments[3],
            );
            instruction |= first | second | immediate;
        },
        constants.InstructionType.ses => {
            if (!hasLength(arguments, 4)) return a.fail("expected 3 arguments: (op, slot, environment, envslot)");
            const slot = try packArgument(a, a, constants.OperandKind.slot, 1, 1, false, arguments[1]);
            const environment = try packArgument(a, a, constants.OperandKind.environment, 0, 1, false, arguments[2]);
            const parent = parentForEnvironment(a, environment) orelse
                return a.fail("invalid environment index");
            const environment_slot = try packArgument(a, parent, constants.OperandKind.slot, 3, 1, false, arguments[3]);
            instruction |= slot | (environment << 16) | environment_slot;
        },
        constants.InstructionType.sc => {
            if (!hasLength(arguments, 3)) return a.fail("expected 2 arguments: (op, slot, constant)");
            const slot = try packArgument(a, a, constants.OperandKind.slot, 1, 1, false, arguments[1]);
            const constant = try packArgument(a, a, constants.OperandKind.constant, 2, 2, false, arguments[2]);
            instruction |= slot | constant;
        },
    }
    return instruction;
}

/// Writes the source map the source declares into the funcdef.
pub fn asmFillSourcemap(
    a: *Assembler,
    source: repr.Value,
) AsmError!void {
    const sourcemap = getFieldByName(source, "sourcemap");
    var gathered_sourcemap = asmItems(sourcemap) orelse unreachable;
    defer gathered_sourcemap.free();
    const items = gathered_sourcemap.items;
    const definition = a.def;
    for (items, 0..) |entry, index| {
        var got = asmItems(entry) orelse return a.fail("expected tuple or vector");
        defer got.free();
        const tuple = got.items;
        if (!args_core.checkint(tuple[0])) return a.fail("expected integer");
        if (!args_core.checkint(tuple[1])) return a.fail("expected integer");
        definition.sourcemap.?[index] = .{
            .line = integerValue(tuple[0]),
            .column = integerValue(tuple[1]),
        };
    }
}

/// Writes the symbol map the source declares into the funcdef.
///
/// It cannot raise: a failure is `error.Assembly` with the message already in
/// the assembler, which is the assembler's own channel. `error.Signal`
/// cannot travel through that error set, so a raise-capable return here
/// would only cost the caller a `catch` it could do nothing with.
pub fn asmFillSymbolmap(
    a: *Assembler,
    source: repr.Value,
) AsmError!void {
    const symbolmap = getFieldByName(source, "symbolmap");
    var gathered_symbolmap = asmItems(symbolmap) orelse unreachable;
    defer gathered_symbolmap.free();
    const items = gathered_symbolmap.items;
    const definition = a.def;
    for (items, 0..) |entry, index| {
        var got = asmItems(entry) orelse return a.fail("expected tuple or vector");
        defer got.free();
        const tuple = got.items;
        const birth_pc: u32 = if (wrap.isKeyword(tuple[0]) and
            utils.cstrcmp(wrap.toKeyword(tuple[0]), "upvalue") == 0)
            maximum_u32
        else if (args_core.checkint(tuple[0]))
            @bitCast(integerValue(tuple[0]))
        else
            return a.fail("expected integer");
        if (!args_core.checkint(tuple[1])) return a.fail("expected integer");
        if (!args_core.checkint(tuple[2])) return a.fail("expected integer");
        if (!wrap.isSymbol(tuple[3])) return a.fail("expected symbol");
        definition.symbolmap.?[index] = .{
            .birth_pc = birth_pc,
            .death_pc = @bitCast(integerValue(tuple[1])),
            .slot_index = @bitCast(integerValue(tuple[2])),
            .symbol = wrap.toSymbol(tuple[3]),
        };
    }
}

/// The entry point. It reports a result rather than raising, so nothing
/// underneath it needs an abi and a caller sees no error union.
pub fn assembleValue(source: repr.Value, flags: c_int) AssembleResult {
    return asm1(null, source, flags);
}

// ==========================================================================
// asm and disasm, the nfunction surface
// ==========================================================================
//
// The two nfunctions the assembler publishes.
//
// `disasm`'s fifteen-way keyword dispatch is the densest use of
// `utils.cstrcmp` in the tree. It is kept as a linear chain of comparisons
// rather than turned into a `std.StaticStringMap`, because the order decides
// which of two keys that share a prefix wins and because `utils.cstrcmp`
// compares against the *string head's* length rather than scanning for a NUL.

/// The `index`th nested definition of `source`, under either the `:closures`
/// or the `:defs` key.
pub fn defAt(source: repr.Value, index: usize) repr.Value {
    var definitions = getFieldByName(source, "closures");
    if (repr.checkType(definitions, repr.Tag.nil)) {
        definitions = getFieldByName(source, "defs");
    }
    var gathered_definitions = asmItems(definitions) orelse unreachable;
    defer gathered_definitions.free();
    const items = gathered_definitions.items;
    return items[index];
}

/// Encodes every instruction of `source` into the funcdef's bytecode.
///
/// The count the caller needs afterwards is `bytecode_count`, which this
/// leaves standing; what it reports is only whether the fill completed.
pub fn fillBytecode(
    a: *Assembler,
    source: repr.Value,
) AsmError!void {
    var gathered_source = asmItems(source) orelse unreachable;
    defer gathered_source.free();
    const items = gathered_source.items;
    const definition = a.def;
    a.bytecode_count = 0;
    // As in `scanBytecode`: a position in `items`, cast only where it is
    // handed to the signed `errindex`.
    for (0..items.len) |index| {
        const instruction = items[index];
        if (wrap.isKeyword(instruction)) continue;
        var got = asmItems(instruction) orelse
            return a.fail("expected assembly instruction");
        defer got.free();
        // Set before the encode rather than after it: an indexed failure
        // downstream formats its own message, and `fail` reads `errindex` to
        // name the instruction it belongs to.
        a.errindex = @intCast(index);
        const encoded = try asmEncode(a, got.items);
        const count = a.bytecode_count;
        definition.bytecode.?[@intCast(count)] = encoded;
        a.bytecode_count = count + 1;
    }
}

/// Copies the constants the source declares into the funcdef.
pub fn fillConstants(
    a: *Assembler,
    source: repr.Value,
) void {
    const consts = getFieldByName(source, "constants");
    var gathered_consts = asmItems(consts) orelse unreachable;
    defer gathered_consts.free();
    const items = gathered_consts.items;
    const definition = a.def;
    for (items, 0..) |item, index| {
        definition.constants.?[index] = item;
    }
}

/// Copies the environment indices the source declares into the funcdef.
pub fn fillEnvironments(
    a: *Assembler,
    source: repr.Value,
) AsmError!void {
    const environments = getFieldByName(source, "environments");
    var gathered_environments = asmItems(environments) orelse unreachable;
    defer gathered_environments.free();
    const items = gathered_environments.items;
    const definition = a.def;
    for (items, 0..) |val, index| {
        if (!args_core.checkint(val)) return a.fail("expected integer");
        definition.environments.?[index] = integerValue(val);
    }
}

/// Verifies the finished definition and computes its flags.
///
/// `failv` rather than `fail`: the verifier's verdict is reported as written,
/// with no instruction index appended to it.
pub fn finalize(a: *Assembler) AsmError!void {
    const definition = a.def;
    const verify_status = verify.verify(definition);
    if (verify_status != .ok) return a.failv(invalidError(verify_status));
    compiler_primitives.defAddflags(definition);
}

/// The value of `source`'s field `name`, as a keyword lookup.
pub fn getFieldByName(source: repr.Value, name: [*:0]const u8) repr.Value {
    return getField(source, value.fromBytes(std.mem.span(name), .keyword));
}

/// The message for a definition the verifier rejected.
///
/// The number is what a Janet program sees, so the verdict becomes one here
/// and only here.
pub fn invalidError(status: verify.Verdict) [*:0]const u8 {
    return pp_format.formatcReported("invalid assembly (%d)", .{status.number()});
}

/// Installs `asm` and `disasm` into `env`.
pub fn libAsm(env: *tables.Table) raise.Error!void {
    const entries = comptime [_]corefn.Entry{
        corefn.reg("asm", &nfunAsm, @src(), "(asm assembly)", "Returns a new function that is the compiled result of the assembly.\n" ++
            "The syntax for the assembly is Janet's, documented at janet-lang.org, and should correspond\n" ++
            "to the return value of disasm. Will throw an\n" ++
            "error on invalid assembly."),
        corefn.reg("disasm", &nfunDisasm, @src(), "(disasm func &opt field)", "Returns assembly that could be used to compile the given function. " ++
            "func must be a function, not an nfunction. Will throw on error on a badly " ++
            "typed argument. If given a field name, will only return that part of the function assembly. " ++
            "Possible fields are:\n\n" ++
            "* :arity - number of required and optional arguments.\n" ++
            "* :min-arity - minimum number of arguments function can be called with.\n" ++
            "* :max-arity - maximum number of arguments function can be called with.\n" ++
            "* :vararg - true if function can take a variable number of arguments.\n" ++
            "* :maparg - true if function can take a variable number of arguments using the &keys option.\n" ++
            "* :namedargs - if function can take a variable number of arguments using the &named option, this will be the number of named arguments.\n" ++
            "* :bytecode - array of parsed bytecode instructions. Each instruction is a tuple.\n" ++
            "* :source - name of source file that this function was compiled from.\n" ++
            "* :name - name of function.\n" ++
            "* :slotcount - how many virtual registers, or slots, this function uses. Corresponds to stack space used by function.\n" ++
            "* :symbolmap - all symbols and their slots.\n" ++
            "* :constants - an array of constants referenced by this function.\n" ++
            "* :sourcemap - a mapping of each bytecode instruction to a line and column in the source file.\n" ++
            "* :environments - an internal mapping of which enclosing functions are referenced for bindings.\n" ++
            "* :defs - other function definitions that this function may instantiate.\n"),
    };
    corefn.install(env, entries);
}

/// Walks `environment + 1` links up the parent chain.
///
/// The `+ 1` is load-bearing: environment 0 means the immediate parent, not
/// the assembler itself.
pub fn parentForEnvironment(context: *Assembler, environment: u32) ?*Assembler {
    var a: ?*Assembler = context;
    var remaining = environment + 1;
    while (remaining > 0) : (remaining -= 1) {
        a = (a orelse return null).parent;
        if (a == null) return null;
    }
    return a;
}

/// Reads the funcdef's header fields out of `source`: its name, its three
/// arities, the vararg and map-argument flags, the named-argument count and
/// the source name.
pub fn parseHeader(
    a: *Assembler,
    source: repr.Value,
) AsmError!void {
    if (!repr.checkTypes(source, repr.TagSet.dictionary)) {
        return a.fail("expected dictionary for assembly source");
    }
    const definition = a.def;
    var val = getFieldByName(source, "name");
    a.name = val;
    if (!repr.checkType(val, repr.Tag.nil)) definition.name = pp_describe.toString(val);

    val = getFieldByName(source, "arity");
    definition.arity = if (args_core.checkint(val)) integerValue(val) else 0;
    if (definition.arity < 0) return a.fail("arity must be non-negative");

    val = getFieldByName(source, "max-arity");
    definition.max_arity = if (args_core.checkint(val)) integerValue(val) else definition.arity;
    if (definition.max_arity < definition.arity) {
        return a.fail("max-arity must be greater than or equal to arity");
    }

    val = getFieldByName(source, "min-arity");
    definition.min_arity = if (args_core.checkint(val)) integerValue(val) else definition.arity;
    if (definition.min_arity > definition.arity) {
        return a.fail("min-arity must be less than or equal to arity");
    }

    val = getFieldByName(source, "vararg");
    if (repr.truthy(val)) definition.flags.vararg = true;
    definition.slotcount = definition.arity + @intFromBool(definition.flags.vararg);

    val = getFieldByName(source, "maparg");
    if (repr.truthy(val)) definition.flags.maparg = true;

    val = getFieldByName(source, "namedargs");
    if (args_core.checkint(val)) {
        definition.flags.namedargs = true;
        definition.named_args_count = integerValue(val);
    }

    val = getFieldByName(source, "source");
    if (repr.checkType(val, repr.Tag.string)) definition.source = wrap.toString(val);
}

/// Binds the slot names the source declares in the assembler's slot table.
pub fn parseSlots(
    a: *Assembler,
    source: repr.Value,
) AsmError!void {
    const slots_value = getFieldByName(source, "slots");
    var gathered_slots = asmItems(slots_value) orelse return;
    defer gathered_slots.free();
    const items = gathered_slots.items;
    const slots = argumentTable(a, constants.OperandKind.slot).?;
    // `index` is a position in `items`; the cast is at the seam where it
    // becomes a Janet integer in the slot table.
    for (0..items.len) |index| {
        const val = items[index];
        if (asmItems(val)) |aliases| {
            defer aliases.free();
            for (aliases.items) |alias| {
                if (!wrap.isSymbol(alias)) {
                    return a.fail("slot names must be symbols");
                }
                tables.put(slots, alias, wrap.fromInteger(@intCast(index)));
            }
        } else if (wrap.isSymbol(val)) {
            tables.put(slots, val, wrap.fromInteger(@intCast(index)));
        } else {
            return a.fail("slot names must be symbols or tuple of symbols");
        }
    }
}

/// Binds a nested definition's name to `index` in the assembler's def table,
/// where it has one.
pub fn registerDef(
    a: *Assembler,
    source: repr.Value,
    index: i32,
) void {
    const name = getFieldByName(source, "name");
    if (!repr.checkType(name, repr.Tag.nil)) {
        const definitions = argumentTable(a, constants.OperandKind.funcdef).?;
        tables.put(definitions, name, wrap.fromInteger(index));
    }
}

/// The message for an operand that resolved to nothing, by failure code.
pub fn resolutionError(val: repr.Value, failure: i32) [*:0]const u8 {
    return switch (failure) {
        1 => pp_format.formatcReported("unknown type %v", .{val}),
        2 => pp_format.formatcReported("unknown name %v", .{val}),
        3 => pp_format.formatcReported("unknown environment %v", .{val}),
        else => pp_format.formatcReported("error parsing instruction argument %v", .{val}),
    };
}

/// Counts the instructions in `source` and binds every label it declares.
///
/// The instruction index is written into the assembler before the message is
/// formatted, because `fail` appends it: a fault here names the source element
/// it found, and `errindex` is the only channel that gets it there.
pub fn scanBytecode(
    a: *Assembler,
    source: repr.Value,
) AsmError!i32 {
    var gathered_source = asmItems(source) orelse {
        a.errindex = 0;
        return a.fail("bytecode expected");
    };
    defer gathered_source.free();
    const items = gathered_source.items;
    const labels = argumentTable(a, constants.OperandKind.label).?;
    var bytecode_length: i32 = 0;
    // `index` is a position in `items`; `errindex` stays signed because -1 is
    // its "no instruction" sentinel, so the cast sits at that assignment.
    for (0..items.len) |index| {
        const instruction = items[index];
        if (wrap.isKeyword(instruction)) {
            tables.put(labels, instruction, wrap.fromInteger(bytecode_length));
        } else if (repr.checkType(instruction, repr.Tag.tuple) or
            repr.checkType(instruction, repr.Tag.vector))
        {
            bytecode_length += 1;
        } else {
            a.errindex = @intCast(index);
            return a.fail("expected assembly instruction");
        }
    }
    return bytecode_length;
}

/// How many constants the source declares.
pub fn scanConstants(
    _: *Assembler,
    source: repr.Value,
) i32 {
    const consts = getFieldByName(source, "constants");
    var gathered_consts = asmItems(consts) orelse return 0;
    defer gathered_consts.free();
    const items = gathered_consts.items;
    return @intCast(items.len);
}

/// How many nested definitions `source` declares, under either the
/// `:closures` or the `:defs` key.
pub fn scanDefs(source: repr.Value) usize {
    var definitions = getFieldByName(source, "closures");
    if (repr.checkType(definitions, repr.Tag.nil)) {
        definitions = getFieldByName(source, "defs");
    }
    var gathered_definitions = asmItems(definitions) orelse return 0;
    defer gathered_definitions.free();
    const items = gathered_definitions.items;
    return items.len;
}

/// How many environments the source declares, or -1 where it declares no
/// `:environments` at all.
///
/// That is not the same as an empty list, so this reports a code rather than
/// a length.
pub fn scanEnvironments(
    _: *Assembler,
    source: repr.Value,
) i32 {
    const environments = getFieldByName(source, "environments");
    var gathered_environments = asmItems(environments) orelse return -1;
    defer gathered_environments.free();
    const items = gathered_environments.items;
    return @intCast(items.len);
}

/// How many source-map entries the source declares, refusing a map whose
/// length does not match the bytecode's.
pub fn scanSourcemap(
    a: *Assembler,
    source: repr.Value,
) AsmError!i32 {
    const sourcemap = getFieldByName(source, "sourcemap");
    var gathered_sourcemap = asmItems(sourcemap) orelse return 0;
    defer gathered_sourcemap.free();
    const items = gathered_sourcemap.items;
    if (items.len != a.def.bytecode_length) {
        return a.fail("sourcemap must have the same length as the bytecode");
    }
    return @intCast(items.len);
}

/// How many symbol-map entries the source declares.
pub fn scanSymbolmap(
    _: *Assembler,
    source: repr.Value,
) i32 {
    const symbolmap = getFieldByName(source, "symbolmap");
    var gathered_symbolmap = asmItems(symbolmap) orelse return 0;
    defer gathered_symbolmap.free();
    const items = gathered_symbolmap.items;
    return @intCast(items.len);
}

/// The message for an instruction name the table does not have.
pub fn unknownInstruction(val: repr.Value) [*:0]const u8 {
    return pp_format.formatcReported("unknown instruction %v", .{val});
}

// ==========================================================================
// Private functions
// ==========================================================================

/// Resolves a closure environment by name, walking the parent chain and
/// memoising into `envs` on the way back down.
fn addEnv(a: *Assembler, envname: repr.Value) i32 {
    if (order.equals(a.name, envname)) return -1;
    const check = tables.get(&a.envs, envname);
    if (repr.checkType(check, repr.Tag.number)) {
        return @intFromFloat(wrap.toNumber(check));
    }
    const parent = a.parent orelse return -2;
    const res = addEnv(parent, envname);
    if (res < -1) return res;

    const def = a.def;
    const envindex = def.environments_length;
    tables.put(&a.envs, envname, wrap.fromNumber(@floatFromInt(envindex)));
    if (envindex >= @as(usize, @intCast(a.environments_capacity))) {
        // At least one. A bare doubling is zero for the first environment,
        // which would be a resize to nothing followed by a write into it.
        const newcap = @max(2 * envindex, envindex + 1);
        def.environments = utils.resizeMany(i32, def.environments, @intCast(newcap));
        a.environments_capacity = @intCast(newcap);
    }
    // Written before the length is declared, so the accessor is one short
    // here and the write goes through the allocation. Every *reader* of an
    // established run below uses `environmentIndices()`.
    def.environments.?[envindex] = res;
    def.environments_length = envindex + 1;
    return @intCast(envindex);
}

/// `count` elements of `T` from the runtime's allocator.
fn allocate(comptime T: type, count: i32) [*]T {
    return utils.allocMany(T, @intCast(count));
}

/// Owns one assembler, and is the frame an assembly's failure returns to.
fn asm1(parent: ?*Assembler, source: repr.Value, flags: c_int) AssembleResult {
    var a: Assembler = undefined;
    a.init(parent, functions.defs.new());
    defer a.deinit();

    assemble(&a, source, flags) catch {
        return .{
            .funcdef = null,
            .@"error" = a.errmessage,
            .status = .@"error",
        };
    };
    return .{
        .funcdef = a.def,
        .@"error" = null,
        .status = .ok,
    };
}

/// One nested assembly, for a `:defs` entry. A failure is re-reported on the
/// parent, which is how it reaches the outermost `assembleValue`.
fn asmNested(parent: *Assembler, source: repr.Value, flags: c_int) AsmError!*functions.FuncDef {
    const result = asm1(parent, source, flags);
    if (result.status != .ok) return parent.failv(result.@"error");
    return result.funcdef.?;
}

/// The body of one assembly.
///
/// Every step either succeeds or returns `error.Assembly` with the message
/// already in the assembler; the caller releases the tables.
fn assemble(a: *Assembler, source: repr.Value, flags: c_int) AsmError!void {
    const def = a.def;

    try parseHeader(a, source);

    {
        try parseSlots(a, source);
        const scanned = scanConstants(a, source);
        def.constants_length = @intCast(scanned);
        if (scanned > 0) {
            def.constants = allocate(repr.Value, scanned);
            fillConstants(a, source);
        } else {
            def.constants = null;
        }
    }

    // Sub funcdefs. The recursion is what the parent chain exists for, and the
    // child's result is checked here rather than passed on unread.
    {
        const definitions = scanDefs(source);
        for (0..definitions) |i| {
            const subsource = defAt(source, i);
            const subdef = try asmNested(a, subsource, flags);
            registerDef(a, subsource, @intCast(def.defs_length));
            const newlen = def.defs_length + 1;
            if (a.defs_capacity < newlen) {
                def.defs = utils.resizeMany(*functions.FuncDef, def.defs, @intCast(newlen));
                a.defs_capacity = @intCast(newlen);
            }
            def.defs.?[def.defs_length] = subdef;
            def.defs_length = @intCast(newlen);
        }
    }

    {
        const x = getField(source, value.fromBytes("bytecode", .keyword));
        const count = try scanBytecode(a, x);
        def.bytecode_length = @intCast(count);
        def.bytecode = allocate(u32, count);
        try fillBytecode(a, x);
    }

    // Everything from here reports without an instruction index.
    a.errindex = -1;

    {
        const count = try scanSourcemap(a, source);
        if (count > 0) {
            def.sourcemap = allocate(functions.SourceMapping, count);
            try asmFillSourcemap(a, source);
        }
    }

    def.symbolmap = null;
    def.symbolmap_length = 0;
    {
        const count = scanSymbolmap(a, source);
        if (count > 0) {
            def.symbolmap_length = @intCast(count);
            def.symbolmap = allocate(functions.SymbolMap, count);
            try asmFillSymbolmap(a, source);
        }
    }
    if (def.symbolmap_length != 0) def.flags.hassymbolmap = true;

    {
        const count = scanEnvironments(a, source);
        if (count >= 0) {
            def.environments_length = @intCast(count);
            if (count > 0) {
                def.environments = utils.resizeMany(i32, def.environments, @intCast(count));
            }
            try fillEnvironments(a, source);
        }
    }

    try finalize(a);
}

/// `asm`: a thunk over the assembled definition.
fn nfunAsm(argv: []repr.Value) raise.Error!repr.Value {
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"asm"}));
    try args_core.fixarity(argv, 1);
    const res = assembleValue(argv[0], 0);
    if (res.status != .ok) {
        const message = res.@"error" orelse strings.cstring("invalid assembly");
        return raise.panicv(wrap.fromString(message));
    }
    return wrap.fromFunction(functions.thunk(res.funcdef.?));
}

/// `disasm`: a whole disassembly, or the one field an optional keyword names.
///
/// The keyword dispatch is a linear chain of comparisons rather than a
/// `std.StaticStringMap`, because the order decides which of two keys sharing
/// a prefix wins and because `utils.cstrcmp` compares against the string
/// head's length rather than scanning for a NUL.
fn nfunDisasm(argv: []repr.Value) raise.Error!repr.Value {
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"asm"}));
    try args_core.arity(argv, 1, 2);
    const f = try args_core.getFunction(argv, 0);
    if (argv.len != 2) return disasm.disassembleField(f.def.?, .all);

    const kw = try args_core.getKeyword(argv, 1);
    for (disasm_fields) |entry| {
        if (utils.cstrcmp(kw, entry.name) == 0) {
            return disasm.disassembleField(f.def.?, entry.field);
        }
    }
    return pp_format.panicf("unknown disasm key %v", .{argv[1]});
}

/// The opcode `name` assembles to, by bisection over `opcodes`.
fn findOpcode(name: [*:0]const u8) ?constants.Opcode {
    var lower: usize = 0;
    var upper: usize = opcodes.len;
    while (lower < upper) {
        const middle = lower + (upper - lower) / 2;
        const comparison = utils.cstrcmp(name, opcodes[middle].name);
        if (comparison == 0) return opcodes[middle].opcode;
        if (comparison < 0) {
            upper = middle;
        } else {
            lower = middle + 1;
        }
    }
    return null;
}

/// The tag set `name` stands for, by bisection over `type_aliases`.
fn findTypeMask(name: [*:0]const u8) ?repr.TagSet {
    var lower: usize = 0;
    var upper: usize = type_aliases.len;
    while (lower < upper) {
        const middle = lower + (upper - lower) / 2;
        const comparison = utils.cstrcmp(name, type_aliases[middle].name);
        if (comparison == 0) return type_aliases[middle].mask;
        if (comparison < 0) {
            upper = middle;
        } else {
            lower = middle + 1;
        }
    }
    return null;
}

/// A lookup that gives back nil for anything it cannot read as a dictionary,
/// which is what lets `asm1` ask for a field of a source it has not yet
/// validated.
///
/// The two dictionaries are read by tag rather than through `access.get`,
/// which raises: the assembler reports with `Assembler.fail` and has no raise
/// to propagate. Neither `tables.get` nor `maps.lookup` can raise.
fn getField(ds: repr.Value, key: repr.Value) repr.Value {
    return switch (repr.typeOf(ds)) {
        repr.Tag.table => tables.get(wrap.toTable(ds), key),
        repr.Tag.map => maps.lookup(wrap.toMap(ds), key),
        else => wrap.fromNil(),
    };
}

// The table an operand kind resolves in, and the walk up the parent chain.

/// Whether an instruction tuple has exactly `expected` elements.
fn hasLength(arguments: []const repr.Value, expected: i32) bool {
    return arguments.len == expected;
}

/// Whether an instruction tuple has at least `minimum` elements.
/// A checked Janet number as an `i32`.
fn integerValue(val: repr.Value) i32 {
    return @intFromFloat(wrap.toNumber(val));
}

/// Resolves one operand and shifts it into its field.
///
/// `a` is where a failure's message lands and `context` is the assembler the
/// operand resolves against. They are the same assembler everywhere but the
/// environment slot of a symbolic environment-slot operand, which resolves in
/// an ancestor while the message still belongs to the assembly being encoded.
fn packArgument(
    a: *Assembler,
    context: *Assembler,
    argument_type: constants.OperandKind,
    byte_index: u5,
    byte_count: i32,
    signed: bool,
    val: repr.Value,
) AsmError!u32 {
    const resolved = try resolveArgument(a, context, argument_type, val);
    const bit_count: u5 = @intCast(byte_count * 8);
    const maximum: i32 = (@as(i32, 1) << (bit_count - @intFromBool(signed))) - 1;
    const minimum: i32 = if (signed) -maximum - 1 else 0;
    if (resolved < minimum) {
        return a.failv(argumentBoundsError(val, byte_count, 0));
    }
    if (resolved > maximum) {
        return a.failv(argumentBoundsError(val, byte_count, 1));
    }
    const bits: u32 = @bitCast(resolved);
    return bits << (byte_index * 8);
}

/// Resolves one operand to the number its field takes, by operand kind.
fn resolveArgument(
    a: *Assembler,
    context: *Assembler,
    argument_type: constants.OperandKind,
    val: repr.Value,
) AsmError!i32 {
    const table = argumentTable(context, argument_type);
    var result: i32 = -1;
    switch (repr.typeOf(val)) {
        repr.Tag.number => {
            const number = wrap.toNumber(val);
            if (number < minimum_i32_float or number > maximum_i32_float or @trunc(number) != number) {
                return a.failv(resolutionError(val, 0));
            }
            result = @intFromFloat(number);
        },
        // A type set is written `[ ]` in Wattle and reaches here as a vector;
        // a tuple is what a set built at run time is.
        repr.Tag.tuple, repr.Tag.vector => {
            if (argument_type != constants.OperandKind.type) return a.failv(resolutionError(val, 0));
            var got = asmItems(val) orelse return a.failv(resolutionError(val, 0));
            defer got.free();
            result = 0;
            for (got.items) |element| {
                result |= try resolveArgument(a, context, constants.OperandKind.simple_type, element);
            }
        },
        // A keyword is a label or a type, and a symbol is a name in a table.
        repr.Tag.symbol => if (wrap.isKeyword(val)) {
            const label_table: ?*tables.Table = if (argument_type == constants.OperandKind.label) table else null;
            if (label_table) |labels| {
                const found = tables.get(labels, val);
                if (!repr.checkType(found, repr.Tag.number)) return a.failv(resolutionError(val, 0));
                result = @intFromFloat(wrap.toNumber(found));
                result -= context.bytecode_count;
            } else if (argument_type == constants.OperandKind.type or argument_type == constants.OperandKind.simple_type) {
                // The instruction operand is sixteen bits and so is the set;
                // `.bits()` is where the two meet, which is the one place the
                // assembler spells a type mask as a number.
                result = (findTypeMask(wrap.toKeyword(val)) orelse return a.failv(resolutionError(val, 1))).bits();
            } else {
                return a.failv(resolutionError(val, 0));
            }
        } else {
            const argument_table = table orelse return a.failv(resolutionError(val, 0));
            const found = tables.get(argument_table, val);
            if (repr.checkType(found, repr.Tag.number)) {
                result = @intFromFloat(wrap.toNumber(found));
            } else if (argument_type == constants.OperandKind.environment) {
                // An environment operand may name an enclosing function this
                // assembler has not captured yet, which is what `addEnv` is
                // for: it walks the parent chain and records the capture on
                // the way back down. Both of its negatives are failures here.
                // -2 is "no ancestor has that name" and -1 is "that is the
                // function being assembled", which is not an environment a
                // `ldu` can index.
                result = addEnv(context, val);
                if (result < 0) return a.failv(resolutionError(val, 3));
            } else {
                return a.failv(resolutionError(val, 2));
            }
        },
        else => return a.failv(resolutionError(val, 0)),
    }
    if (argument_type == constants.OperandKind.slot) {
        const definition = context.def;
        if (result >= definition.slotcount) definition.slotcount = result + 1;
    }
    return result;
}
