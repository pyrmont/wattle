//! Behavioral contract for `janet_disasm`: a `JanetFuncDef` rendered as the
//! struct `disasm` answers.
//!
//! Every field of a function definition has to appear, under the right key and
//! in the right form, and a Janet program cannot check that: to see a field it
//! must first produce a function that *has* one, and several of these fields
//! only arise from bytecode the compiler emits in particular circumstances.
//! Building the `JanetFuncDef` by hand is what lets one fixture carry all of
//! them at once — a vararg, structarg, named-args function with constants, a
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
//! program counter — two different shapes under one key, which is exactly the
//! kind of thing a port drops.

const std = @import("std");
const abi = @import("abi");
const c = abi.c;
const harness = @import("harness.zig");

fn theWholeDefinitionRoundTrips() void {
    var child: c.JanetFuncDef = std.mem.zeroes(c.JanetFuncDef);
    child.arity = 1;
    child.min_arity = 1;
    child.max_arity = 1;
    child.slotcount = 2;

    var definitions = [_][*c]c.JanetFuncDef{&child};
    var bytecode = [_]u32{
        c.JOP_NOOP,
        harness.op(c.JOP_LOAD_INTEGER) | (@as(u32, 2) << 8) | (@as(u32, 0xFFF9) << 16),
    };
    var constants = [_]c.Janet{
        c.janet_wrap_true(),
        c.janet_cstringv("constant"),
    };
    var sourcemap = [_]c.JanetSourceMapping{
        .{ .line = 3, .column = 5 },
        .{ .line = 8, .column = 13 },
    };
    var environments = [_]i32{ 4, 1 };

    var symbolmap: [2]c.JanetSymbolMap = @splat(std.mem.zeroes(c.JanetSymbolMap));
    symbolmap[0].birth_pc = 0;
    symbolmap[0].death_pc = 2;
    symbolmap[0].slot_index = 3;
    symbolmap[0].symbol = c.janet_symbol("local", 5);
    // The upvalue sentinel; see the header comment.
    symbolmap[1].birth_pc = std.math.maxInt(u32);
    symbolmap[1].death_pc = 1;
    symbolmap[1].slot_index = 0;
    symbolmap[1].symbol = c.janet_symbol("captured", 8);

    var definition: c.JanetFuncDef = std.mem.zeroes(c.JanetFuncDef);
    definition.arity = 2;
    definition.min_arity = 1;
    definition.max_arity = 4;
    definition.slotcount = 9;
    definition.flags = c.JANET_FUNCDEF_FLAG_VARARG |
        c.JANET_FUNCDEF_FLAG_STRUCTARG |
        c.JANET_FUNCDEF_FLAG_NAMEDARGS;
    definition.named_args_count = 3;
    definition.bytecode = &bytecode;
    definition.bytecode_length = bytecode.len;
    definition.constants = &constants;
    definition.constants_length = constants.len;
    definition.sourcemap = &sourcemap;
    definition.source = c.janet_cstring("source.janet");
    definition.name = c.janet_cstring("sample");
    definition.environments = &environments;
    definition.environments_length = environments.len;
    definition.symbolmap = &symbolmap;
    definition.symbolmap_length = symbolmap.len;
    definition.defs = &definitions;
    definition.defs_length = definitions.len;

    const value = c.janet_disasm(&definition);
    std.debug.assert(harness.isType(value, c.JANET_STRUCT));
    const result = c.janet_unwrap_struct(value);

    theScalarFields(result);
    theBytecode(result);
    theConstants(result, &constants);
    theSourceMap(result);
    theEnvironments(result);
    theSymbolMap(result);
    theChildDefinition(result);
}

fn theScalarFields(result: c.JanetStruct) void {
    std.debug.assert(harness.integerIs(harness.field(result, "arity"), 2));
    std.debug.assert(harness.integerIs(harness.field(result, "min-arity"), 1));
    std.debug.assert(harness.integerIs(harness.field(result, "max-arity"), 4));
    std.debug.assert(harness.integerIs(harness.field(result, "slotcount"), 9));
    // The three flags come back as booleans and a count rather than as bits.
    std.debug.assert(c.janet_unwrap_boolean(harness.field(result, "vararg")) != 0);
    std.debug.assert(c.janet_unwrap_boolean(harness.field(result, "structarg")) != 0);
    std.debug.assert(harness.integerIs(harness.field(result, "namedargs"), 3));
    std.debug.assert(harness.stringValueIs(harness.field(result, "source"), "source.janet"));
    std.debug.assert(harness.stringValueIs(harness.field(result, "name"), "sample"));
}

fn theBytecode(result: c.JanetStruct) void {
    const array = c.janet_unwrap_array(harness.field(result, "bytecode"));
    std.debug.assert(array.*.count == 2);

    const noop = c.janet_unwrap_tuple(array.*.data[0]);
    std.debug.assert(c.janet_tuple_length(noop) == 1);
    std.debug.assert(harness.symbolIs(noop[0], "noop"));

    // Decoded rather than copied: -7 was `0xFFF9` in the word.
    const ldi = c.janet_unwrap_tuple(array.*.data[1]);
    std.debug.assert(harness.integerIs(ldi[1], 2));
    std.debug.assert(harness.integerIs(ldi[2], -7));
}

fn theConstants(result: c.JanetStruct, expected: []const c.Janet) void {
    const array = c.janet_unwrap_array(harness.field(result, "constants"));
    std.debug.assert(array.*.count == 2);
    std.debug.assert(harness.equals(array.*.data[0], expected[0]));
    std.debug.assert(harness.equals(array.*.data[1], expected[1]));
}

fn theSourceMap(result: c.JanetStruct) void {
    const array = c.janet_unwrap_array(harness.field(result, "sourcemap"));
    std.debug.assert(array.*.count == 2);
    const second = c.janet_unwrap_tuple(array.*.data[1]);
    std.debug.assert(harness.integerIs(second[0], 8));
    std.debug.assert(harness.integerIs(second[1], 13));
}

fn theEnvironments(result: c.JanetStruct) void {
    const array = c.janet_unwrap_array(harness.field(result, "environments"));
    std.debug.assert(array.*.count == 2);
    std.debug.assert(harness.integerIs(array.*.data[0], 4));
    std.debug.assert(harness.integerIs(array.*.data[1], 1));
}

fn theSymbolMap(result: c.JanetStruct) void {
    const array = c.janet_unwrap_array(harness.field(result, "symbolmap"));
    std.debug.assert(array.*.count == 2);

    // An ordinary local: birth, death, slot, name.
    const local = c.janet_unwrap_tuple(array.*.data[0]);
    std.debug.assert(harness.integerIs(local[0], 0));
    std.debug.assert(harness.integerIs(local[1], 2));
    std.debug.assert(harness.integerIs(local[2], 3));
    std.debug.assert(harness.symbolIs(local[3], "local"));

    // The sentinel row, rendered as a keyword in the first position.
    const upvalue = c.janet_unwrap_tuple(array.*.data[1]);
    std.debug.assert(harness.keywordIs(upvalue[0], "upvalue"));
}

fn theChildDefinition(result: c.JanetStruct) void {
    const array = c.janet_unwrap_array(harness.field(result, "defs"));
    std.debug.assert(array.*.count == 1);
    // Disassembled recursively, so the child's own fields are present.
    const nested = c.janet_unwrap_struct(array.*.data[0]);
    std.debug.assert(harness.integerIs(harness.field(nested, "arity"), 1));
}

pub fn run() void {
    _ = c.janet_init();
    theWholeDefinitionRoundTrips();
    c.janet_deinit();
}
