//! Behavioral contract for `bytecode/disasm.zig`'s `disasm`: a
//! `functions.FuncDef` rendered as a struct.
//!
//! Every field of a function definition has to appear, under the right key and
//! in the right form, and a Janet program cannot check that: to see a field it
//! must first produce a function that *has* one, and several of these fields
//! only arise from bytecode the compiler emits in particular circumstances.
//! Building the `functions.FuncDef` by hand is what lets one fixture have all
//! of them at once: a vararg, structarg, named-args function with constants, a
//! source map, an environment list, a symbol map and a child definition.
//!
//! ## The two fields that are not what they look like
//!
//! `environments` is a list of *indices into the enclosing function's*
//! environments, not a list of environments, so `{4, 1}` must come back as the
//! numbers 4 and 1 rather than as anything resolved.
//!
//! And a symbol-map row whose `birth_pc` is `UINT32_MAX` is the compiler's
//! sentinel for an upvalue rather than a local. `disasm` renders that row with
//! the keyword `:upvalue` in the first position where an ordinary row has a
//! program counter, so two different shapes appear under one key.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const constants = @import("constants");
const disasm = @import("subsystems").disasm;
const expect = @import("expect.zig").expect;
const functions = @import("subsystems").value.functions;
const harness = @import("harness.zig");
const repr = @import("repr");
const strings = @import("subsystems").value.strings;
const structs = @import("subsystems").value.structs;
const symbols = @import("subsystems").value.symbols;
const tuples = @import("subsystems").value.tuples;
const value = @import("subsystems").value;
const vm_lifecycle = @import("subsystems").lifecycle;
const wrap = @import("subsystems").value.wrap;

// ==========================================================================
// Cases
// ==========================================================================

fn theScalarFields(result: structs.Struct) void {
    expect(harness.integerIs(harness.field(result, "arity"), 2));
    expect(harness.integerIs(harness.field(result, "min-arity"), 1));
    expect(harness.integerIs(harness.field(result, "max-arity"), 4));
    expect(harness.integerIs(harness.field(result, "slotcount"), 9));
    // The three flags come back as booleans and a count rather than as bits.
    expect(wrap.toBoolean(harness.field(result, "vararg")));
    expect(wrap.toBoolean(harness.field(result, "structarg")));
    expect(harness.integerIs(harness.field(result, "namedargs"), 3));
    expect(harness.stringValueIs(harness.field(result, "source"), "source.janet"));
    expect(harness.stringValueIs(harness.field(result, "name"), "sample"));
}

fn theBytecode(result: structs.Struct) void {
    const array = wrap.toArray(harness.field(result, "bytecode"));
    expect(array.count == 2);

    const noop = wrap.toTuple(array.slice()[0]);
    expect(tuples.head(noop).length == 1);
    expect(harness.symbolIs(noop[0], "noop"));

    // Decoded rather than copied: -7 was `0xFFF9` in the word.
    const ldi = wrap.toTuple(array.slice()[1]);
    expect(harness.integerIs(ldi[1], 2));
    expect(harness.integerIs(ldi[2], -7));
}

fn theConstants(result: structs.Struct, expected: []const repr.Value) void {
    const array = wrap.toArray(harness.field(result, "constants"));
    expect(array.count == 2);
    expect(harness.equals(array.slice()[0], expected[0]));
    expect(harness.equals(array.slice()[1], expected[1]));
}

fn theSourceMap(result: structs.Struct) void {
    const array = wrap.toArray(harness.field(result, "sourcemap"));
    expect(array.count == 2);
    const second = wrap.toTuple(array.slice()[1]);
    expect(harness.integerIs(second[0], 8));
    expect(harness.integerIs(second[1], 13));
}

fn theEnvironments(result: structs.Struct) void {
    const array = wrap.toArray(harness.field(result, "environments"));
    expect(array.count == 2);
    expect(harness.integerIs(array.slice()[0], 4));
    expect(harness.integerIs(array.slice()[1], 1));
}

fn theSymbolMap(result: structs.Struct) void {
    const array = wrap.toArray(harness.field(result, "symbolmap"));
    expect(array.count == 2);

    // An ordinary local: birth, death, slot, name.
    const local = wrap.toTuple(array.slice()[0]);
    expect(harness.integerIs(local[0], 0));
    expect(harness.integerIs(local[1], 2));
    expect(harness.integerIs(local[2], 3));
    expect(harness.symbolIs(local[3], "local"));

    // The sentinel row, rendered as a keyword in the first position.
    const upvalue = wrap.toTuple(array.slice()[1]);
    expect(harness.keywordIs(upvalue[0], "upvalue"));
}

fn theChildDefinition(result: structs.Struct) void {
    const array = wrap.toArray(harness.field(result, "defs"));
    expect(array.count == 1);
    // Disassembled recursively, so the child's own fields are present.
    const nested = wrap.toStruct(array.slice()[0]);
    expect(harness.integerIs(harness.field(nested, "arity"), 1));
}

fn theWholeDefinitionRoundTrips() void {
    var child: functions.FuncDef = std.mem.zeroes(functions.FuncDef);
    child.arity = 1;
    child.min_arity = 1;
    child.max_arity = 1;
    child.slotcount = 2;

    var definitions = [_]*functions.FuncDef{&child};
    var bytecode = [_]u32{
        harness.op(constants.Opcode.noop),
        harness.op(constants.Opcode.load_integer) | (@as(u32, 2) << 8) | (@as(u32, 0xFFF9) << 16),
    };
    var consts = [_]repr.Value{
        wrap.fromTrue(),
        value.fromBytes("constant", .string),
    };
    var sourcemap = [_]functions.SourceMapping{
        .{ .line = 3, .column = 5 },
        .{ .line = 8, .column = 13 },
    };
    var environments = [_]i32{ 4, 1 };

    var symbolmap: [2]functions.SymbolMap = @splat(std.mem.zeroes(functions.SymbolMap));
    symbolmap[0].birth_pc = 0;
    symbolmap[0].death_pc = 2;
    symbolmap[0].slot_index = 3;
    symbolmap[0].symbol = symbols.new("local");
    // The upvalue sentinel; see the header comment.
    symbolmap[1].birth_pc = std.math.maxInt(u32);
    symbolmap[1].death_pc = 1;
    symbolmap[1].slot_index = 0;
    symbolmap[1].symbol = symbols.new("captured");

    var definition: functions.FuncDef = std.mem.zeroes(functions.FuncDef);
    definition.arity = 2;
    definition.min_arity = 1;
    definition.max_arity = 4;
    definition.slotcount = 9;
    definition.flags = .{ .vararg = true, .structarg = true, .namedargs = true };
    definition.named_args_count = 3;
    definition.bytecode = &bytecode;
    definition.bytecode_length = bytecode.len;
    definition.constants = &consts;
    definition.constants_length = consts.len;
    definition.sourcemap = &sourcemap;
    definition.source = strings.cstring("source.janet");
    definition.name = strings.cstring("sample");
    definition.environments = &environments;
    definition.environments_length = environments.len;
    definition.symbolmap = &symbolmap;
    definition.symbolmap_length = symbolmap.len;
    definition.defs = &definitions;
    definition.defs_length = definitions.len;

    const val = disasm.disasm(&definition);
    expect(harness.isType(val, repr.Tag.@"struct"));
    const result = wrap.toStruct(val);

    theScalarFields(result);
    theBytecode(result);
    theConstants(result, &consts);
    theSourceMap(result);
    theEnvironments(result);
    theSymbolMap(result);
    theChildDefinition(result);
}

// ==========================================================================
// Entry
// ==========================================================================

pub fn run() void {
    harness.init();
    theWholeDefinitionRoundTrips();
    vm_lifecycle.deinit();
}
