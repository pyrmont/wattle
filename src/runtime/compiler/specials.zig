//! The thirteen special forms: `quote`, `do`, `if`, `fn`, `def`, `var`, `set`,
//! `while`, `break`, `upscope`, `splice`, `quasiquote` and `unquote`.
//!
//! `lookupSpecial` is the only public name. `compiler.zig`'s value compiler
//! consults it before treating a tuple's head as a call, and everything else
//! here is reached through the `specials` table it searches.
//!
//! A compile error and a raise are two channels, and this file uses both. A
//! malformed form is recorded on the compiler by `cerror` and compilation
//! keeps going, so that the first error is the one the user sees. A raise,
//! from a macro, from the allocator or from a value operation, returns
//! `raise.Error`, and every one of these forms passes it on.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const args_core = @import("../args.zig");
const arrays = @import("../value/arrays.zig");
const compiler_primitives = @import("../compiler.zig");
const config = @import("config");
const constants = @import("constants");
const emit_core = @import("emit.zig");
const functions = @import("../value/functions.zig");
const maps = @import("../value/maps.zig");
const pp_format = @import("../pp/format.zig");
const raise = @import("../../api/raise.zig");
const registry = @import("../registry.zig");
const repr = @import("repr");
const scratch_vector = @import("../scratch_vector.zig");
const special = @import("../special_type.zig");
const strings = @import("../value/strings.zig");
const tables = @import("../value/tables.zig");
const tuples = @import("../value/tuples.zig");
const vectors = @import("../value/vectors.zig");
const utils = @import("../utils.zig");
const value = @import("../value.zig");
const wrap = @import("../value/helpers/wrap.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// `compiler.scope`, with the invariant that it is open named once in
/// `compiler.zig`.
const currentScope = compiler_primitives.currentScope;

/// The thirteen special forms, in lexicographic order so that `lookup` can
/// bisect them.
const specials = [_]special.Special{
    .{ .name = "break", .compile = specialBreak },
    .{ .name = "def", .compile = specialDef },
    .{ .name = "do", .compile = specialDo },
    .{ .name = "fn", .compile = specialFn },
    .{ .name = "if", .compile = specialIf },
    .{ .name = "quasiquote", .compile = specialQuasiquote },
    .{ .name = "quote", .compile = specialQuote },
    .{ .name = "set", .compile = specialSet },
    .{ .name = "splice", .compile = specialSplice },
    .{ .name = "unquote", .compile = specialUnquote },
    .{ .name = "upscope", .compile = specialUpscope },
    .{ .name = "var", .compile = specialVar },
    .{ .name = "while", .compile = specialWhile },
};

/// The jump ranges the two `checkJump*` helpers test against.
const std_max_i32 = 0x7fffffff;
const std_max_i16 = 0x7fff;
const std_min_i16 = -0x8000;

// ==========================================================================
// Types
// ==========================================================================

/// Whether a binding is a `var` or a `def`, which is the only thing
/// `compileBinding` and the leaf binders differ on.
const BindingKind = enum { variable, definition };

/// One destructuring step: the pattern on the left and the slot it is being
/// matched against.
const SlotHeadPair = struct {
    lhs: repr.Value,
    rhs: compiler_primitives.Slot,
};

// ==========================================================================
// Public functions
// ==========================================================================

/// Returns the thirteen special forms, in lexicographic order.
///
/// `client/prompt.zig` adds their names to the candidates for a completion.
pub fn allSpecials() []const special.Special {
    return &specials;
}

/// The special form `name` names, or null. `compiler.zig` consults this before
/// treating a tuple's head as a call.
pub fn lookupSpecial(name: [*:0]const u8) ?*const special.Special {
    return lookup(name);
}

// ==========================================================================
// Private functions
// ==========================================================================

/// Appends `definition` to the enclosing function scope's nested definitions
/// and returns its index there.
fn addFunctionDefinition(compiler: *compiler_primitives.Compiler, definition: *functions.FuncDef) i32 {
    var scope = compiler.scope;
    while (scope) |current| {
        if (current.flags.function) break;
        scope = current.parent;
    }
    // The same invariant `emit.internConstant` names: `compileLintImpl` pushes
    // the root scope with `.function = true` before any form is compiled, so
    // the walk above stops on a function scope rather than running out.
    const function_scope = scope orelse unreachable;
    scratch_vector.push(&function_scope.defs, definition);
    return @intCast(function_scope.defs.items.len - 1);
}

/// Binds one `def` name, recording its metadata in the environment where the
/// scope is the top one.
fn bindDefinitionLeaf(
    compiler: *compiler_primitives.Compiler,
    symbol: [*:0]const u8,
    slot: compiler_primitives.Slot,
    attributes: ?*tables.Table,
) raise.Error!bool {
    var entry: ?*tables.Table = null;
    var redef = false;
    if (currentScope(compiler).flags.top) {
        // A top-scope binding is always one `compileBinding` made, and
        // `compileBinding` has already returned on the single path where
        // `handleAttributes` gives back null. The one caller that passes null,
        // `specialFn` destructuring its named parameters, is inside the
        // function scope it just pushed, so it never reaches this branch.
        const table = tables.clone(attributes orelse unreachable);
        entry = table;
        tables.put(table, value.fromBytes("source-map", .keyword), wrap.fromTuple(makeSourceMap(compiler)));
        redef = compiler.is_redef;
        if (redef) tables.put(table, value.fromBytes("redef", .keyword), wrap.fromTrue());
        if (redef) {
            const binding = registry.resolveExt(compiler.env.?, symbol);
            const reference = if (binding.type == .dynamic_def or
                binding.type == .dynamic_macro)
                wrap.toArray(binding.value)
            else
                newReferenceArray();
            tables.put(table, value.fromBytes("ref", .keyword), wrap.fromArray(try reference));
            _ = emit_core.emitSsu(
                compiler,
                constants.Opcode.put_index,
                compiler_primitives.cslot(wrap.fromArray(try reference)),
                slot,
                0,
                0,
            );
        } else {
            _ = emit_core.emitSss(
                compiler,
                constants.Opcode.put,
                compiler_primitives.cslot(wrap.fromTable(table)),
                compiler_primitives.cslot(value.fromBytes("value", .keyword)),
                slot,
                0,
            );
        }
    }
    var definition_flags: u32 = 0;
    const attribute_table = metadata(attributes);
    if (attribute_table) |table| {
        if (repr.truthy(tableGetKeyword(table, "unused"))) {
            definition_flags |= constants.defflag_no_unused;
        }
    }
    if (redef) {
        definition_flags |= constants.defflag_no_shadowcheck;
    } else if (attribute_table) |table| {
        if (repr.truthy(tableGetKeyword(table, "shadow"))) {
            definition_flags |= constants.defflag_no_shadowcheck;
        }
    }
    const result = try nameLocal(compiler, symbol, .{}, slot, definition_flags);
    if (entry) |e| {
        tables.put(compiler.env.?, wrap.fromSymbol(symbol), wrap.fromTable(e));
    }
    return result;
}

/// Binds one destructured name, by binding kind.
fn bindLeaf(
    compiler: *compiler_primitives.Compiler,
    symbol: [*:0]const u8,
    slot: compiler_primitives.Slot,
    binding_kind: BindingKind,
    attributes: ?*tables.Table,
) raise.Error!bool {
    return switch (binding_kind) {
        .variable => try bindVariableLeaf(compiler, symbol, slot, attributes),
        .definition => bindDefinitionLeaf(compiler, symbol, slot, attributes),
    };
}

/// Binds one `var` name, recording its metadata in the environment where the
/// scope is the top one.
fn bindVariableLeaf(
    compiler: *compiler_primitives.Compiler,
    symbol: [*:0]const u8,
    slot: compiler_primitives.Slot,
    attributes: ?*tables.Table,
) raise.Error!bool {
    if (currentScope(compiler).flags.top) {
        // A top-scope binding is always one `compileBinding` made, and
        // `compileBinding` has already returned on the single path where
        // `handleAttributes` gives back null. The one caller that passes null,
        // `specialFn` destructuring its named parameters, is inside the
        // function scope it just pushed, so it never reaches this branch.
        const entry = tables.clone(attributes orelse unreachable);
        var reference: *arrays.Array = undefined;
        if (compiler.is_redef) {
            const old_binding = registry.resolveExt(compiler.env.?, symbol);
            if (old_binding.type == .@"var") {
                reference = wrap.toArray(old_binding.value);
            } else {
                reference = try newReferenceArray();
            }
        } else {
            reference = try newReferenceArray();
        }
        tables.put(entry, value.fromBytes("ref", .keyword), wrap.fromArray(reference));
        tables.put(entry, value.fromBytes("source-map", .keyword), wrap.fromTuple(makeSourceMap(compiler)));
        tables.put(compiler.env.?, wrap.fromSymbol(symbol), wrap.fromTable(entry));
        _ = emit_core.emitSsu(
            compiler,
            constants.Opcode.put_index,
            compiler_primitives.cslot(wrap.fromArray(reference)),
            slot,
            0,
            0,
        );
        return true;
    }
    var definition_flags: u32 = 0;
    if (metadata(attributes)) |table| {
        if (repr.truthy(tableGetKeyword(table, "unused"))) {
            definition_flags |= constants.defflag_no_unused;
        }
        if (repr.truthy(tableGetKeyword(table, "shadow"))) {
            definition_flags |= constants.defflag_no_shadowcheck;
        }
    }
    return nameLocal(compiler, symbol, .{ .mutable = true }, slot, definition_flags);
}

/// Walks a destructuring pattern and collects the pattern-and-slot pairs its
/// leaves need, so that the binder sees them in one list.
fn buildDestructureHeads(
    pairs: *scratch_vector.Vector(SlotHeadPair),
    options: compiler_primitives.FormOptions,
    lhs: repr.Value,
    rhs: repr.Value,
) raise.Error!void {
    const compiler: *compiler_primitives.Compiler = options.compiler;
    const lhs_indexed = repr.TagSet.indexed.has(repr.typeOf(lhs));
    const rhs_indexed = repr.checkType(rhs, repr.Tag.array) or
        repr.checkType(rhs, repr.Tag.vector);
    const has_drop = options.flags.drop;
    var suboptions = compiler_primitives.foptsDefault(compiler);
    suboptions.flags = options.flags;
    suboptions.flags.tail = false;
    suboptions.flags.drop = false;

    if (has_drop and lhs_indexed and rhs_indexed) {
        // Gathered rather than read a run at a time: both sides are indexed
        // by position against each other, and a vector's elements are not one
        // block. `free` is deferred because the walk below raises.
        var lhs_gathered = (try args_core.gather(lhs)).?;
        defer lhs_gathered.free();
        var rhs_gathered = (try args_core.gather(rhs)).?;
        defer rhs_gathered.free();
        const lhs_items = lhs_gathered.items;
        const rhs_items = rhs_gathered.items;
        var found_amp = false;
        var found_splice = false;
        for (rhs_items) |item| {
            if (!repr.checkType(item, repr.Tag.tuple)) continue;
            const tuple = wrap.toTuple(item);
            if (tuples.head(tuple).length != 0 and symbolEquals(tuple[0], "splice")) {
                found_splice = true;
                break;
            }
        }
        for (lhs_items) |item| {
            if (symbolEquals(item, "&")) {
                found_amp = true;
                break;
            }
        }
        if (!found_amp and !found_splice) {
            for (0..lhs_items.len) |index| {
                const sub_rhs = if (index < rhs_items.len) rhs_items[index] else wrap.fromNil();
                try buildDestructureHeads(pairs, suboptions, lhs_items[index], sub_rhs);
            }
            return;
        }
    }

    suboptions.hint = options.hint;
    scratch_vector.push(pairs, .{ .lhs = lhs, .rhs = try compiler_primitives.valueImpl(suboptions, rhs) });
}

/// Records an error where a 16-bit jump would not reach.
fn checkJump16(compiler: *compiler_primitives.Compiler, from: i32, to: i32) void {
    const distance = to - from;
    if (distance > std_max_i16 or distance < std_min_i16) {
        compiler_primitives.cerror(compiler, "bad 16-bit jump, too large");
    }
}

/// Records an error where a 24-bit jump would not reach.
fn checkJump24(compiler: *compiler_primitives.Compiler, from: i32, to: i32) void {
    const distance = to - from;
    if (distance > 0xffffff or distance < -0x1000000) {
        compiler_primitives.cerror(compiler, "bad 24-bit jump, too large");
    }
}

/// Lints a `:macro` tag on a binding in an inner scope, where it has no
/// effect.
fn checkMetadataLint(compiler: *compiler_primitives.Compiler, attributes: ?*tables.Table) raise.Error!void {
    if (currentScope(compiler).flags.top) return;
    const table = metadata(attributes) orelse return;
    if (repr.truthy(tableGetKeyword(table, "macro"))) {
        try compiler_primitives.lint(compiler, .normal, "macro tag is ignored in inner scopes");
    }
}

/// The other operand of a two-argument comparison against nil, where the form
/// is one. `(= x nil)` and `(not= nil x)` each give back `x`.
fn checkNilForm(val: repr.Value, function_tag: u32) ?repr.Value {
    if (!repr.checkType(val, repr.Tag.tuple)) return null;
    const tuple = wrap.toTuple(val);
    if (tuples.head(tuple).length != 3) return null;
    if (!repr.checkType(tuple[0], repr.Tag.function)) return null;
    const function = wrap.toFunction(tuple[0]);
    if (function.def.?.flags.tag != function_tag) return null;
    if (repr.checkType(tuple[1], repr.Tag.nil)) return tuple[2];
    if (repr.checkType(tuple[2], repr.Tag.nil)) return tuple[1];
    return null;
}

/// `functionError` with the two parameter vectors released first.
fn cleanupFunctionError(
    compiler: *compiler_primitives.Compiler,
    destructured_parameters: *scratch_vector.Vector(compiler_primitives.Slot),
    named_parameters: *scratch_vector.Vector(compiler_primitives.Slot),
    message: [*:0]const u8,
) raise.Error!compiler_primitives.Slot {
    scratch_vector.free(destructured_parameters);
    scratch_vector.free(named_parameters);
    return functionError(compiler, message);
}

/// The body `def` and `var` share: the attributes, the value, and the
/// destructuring of the name against it.
fn compileBinding(
    original_options: compiler_primitives.FormOptions,
    arguments: []const repr.Value,
    binding_kind: BindingKind,
) raise.Error!compiler_primitives.Slot {
    const compiler: *compiler_primitives.Compiler = original_options.compiler;
    const attributes = try handleAttributes(
        compiler,
        if (binding_kind == .variable) "var" else "def",
        arguments,
    );
    if (compiler.result.status == .@"error") return nilSlot();
    try checkMetadataLint(compiler, attributes);

    var options = original_options;
    if (binding_kind == .definition) options.flags.hint = false;
    var pairs: scratch_vector.Vector(SlotHeadPair) = .empty;
    try buildDestructureHeads(&pairs, options, arguments[0], arguments[arguments.len - 1]);
    if (compiler.result.status == .@"error") {
        scratch_vector.free(&pairs);
        return nilSlot();
    }

    if (pairs.items.len == 0) unreachable;
    var result = nilSlot();
    for (pairs.items) |pair| {
        _ = try destructure(compiler, pair.lhs, pair.rhs, binding_kind, attributes);
        result = pair.rhs;
    }
    scratch_vector.free(&pairs);
    return result;
}

/// Emits the loop that binds a `&` rest parameter, gathering every argument
/// from `start` onwards into an array.
fn compileRestDestructure(compiler: *compiler_primitives.Compiler, rhs: compiler_primitives.Slot, target: compiler_primitives.Slot, start: i32) void {
    const argument_index = compiler_primitives.farslot(compiler) orelse nilSlot();
    const argument = compiler_primitives.farslot(compiler) orelse nilSlot();
    const length = compiler_primitives.farslot(compiler) orelse nilSlot();
    _ = emit_core.emitSi(compiler, constants.Opcode.load_integer, argument_index, @truncate(start), 0);
    _ = emit_core.emitSs(compiler, constants.Opcode.length, length, rhs, 0);
    const loop_start = emit_core.emitSss(compiler, constants.Opcode.less_than, argument, argument_index, length, 0);
    const condition_jump = emit_core.emitSi(compiler, constants.Opcode.jump_if_not, argument, 0, 0);
    _ = emit_core.emitSss(compiler, constants.Opcode.get, argument, rhs, argument_index, 0);
    _ = emit_core.emitSlot(compiler, constants.Opcode.push, argument, 0);
    _ = emit_core.emitSsi(compiler, constants.Opcode.add_immediate, argument_index, argument_index, 1, 0);
    const loop_jump = compiler.here();
    _ = emit_core.emit(compiler, constants.Opcode.jump.number());
    const exit_label = compiler.here();
    checkJump16(compiler, condition_jump, exit_label);
    checkJump24(compiler, loop_start, loop_jump);
    compiler.buffer.items[@intCast(condition_jump)] |= @as(u32, @intCast(exit_label - condition_jump)) << 16;
    compiler.buffer.items[@intCast(loop_jump)] |= @as(u32, @bitCast(loop_start - loop_jump)) << 8;
    compiler_primitives.freeslot(compiler, argument_index);
    compiler_primitives.freeslot(compiler, argument);
    compiler_primitives.freeslot(compiler, length);
    // `& rest` binds a vector: what it collects is data, and the vector is
    // Wattle's immutable sequence where a tuple is the call form.
    _ = emit_core.emitSlot(compiler, constants.Opcode.make_vector, target, 1);
}

/// Compiles a run of forms, dropping every result but the last.
fn compileSequence(
    options: compiler_primitives.FormOptions,
    arguments: []const repr.Value,
) raise.Error!compiler_primitives.Slot {
    const compiler: *compiler_primitives.Compiler = options.compiler;
    var result = nilSlot();
    var suboptions = compiler_primitives.foptsDefault(compiler);
    for (arguments, 0..) |argument, index| {
        if (index != arguments.len - 1) {
            suboptions.flags = .{ .drop = true };
        } else {
            suboptions = options;
            suboptions.flags.accept_splice = false;
        }
        result = try compiler_primitives.valueImpl(suboptions, argument);
        if (index != arguments.len - 1) compiler_primitives.freeslot(compiler, result);
    }
    return result;
}

/// Binds a destructuring pattern against `rhs`, recursing through tuples and
/// arrays and binding a symbol as a leaf.
fn destructure(
    compiler: *compiler_primitives.Compiler,
    lhs: repr.Value,
    rhs: compiler_primitives.Slot,
    binding_kind: BindingKind,
    attributes: ?*tables.Table,
) raise.Error!bool {
    switch (repr.typeOf(lhs)) {
        repr.Tag.symbol => if (!wrap.isKeyword(lhs)) {
            return try bindLeaf(compiler, wrap.toSymbol(lhs), rhs, binding_kind, attributes);
        } else {
            compiler_primitives.recordError(compiler, try pp_format.formatc("unexpected type in destructuring, got %v", .{lhs}));
            return true;
        },
        repr.Tag.tuple, repr.Tag.array, repr.Tag.vector => {
            // Gathered rather than read a run at a time: the pattern is walked
            // by position and a vector's elements are not one block. `free` is
            // deferred because every arm below can raise or return early.
            var gathered = (try args_core.gather(lhs)).?;
            defer gathered.free();
            const values = gathered.items;
            // `index` is a position in `values`; the casts left below are the
            // points where it becomes a bytecode operand or a Janet integer.
            for (0..values.len) |index| {
                const next_rhs = compiler_primitives.farslot(compiler) orelse nilSlot();
                const subvalue = values[index];
                if (symbolEquals(subvalue, "&")) {
                    if (index + 1 >= values.len) {
                        compiler_primitives.cerror(compiler, "expected symbol following '& in destructuring pattern");
                        return true;
                    }
                    if (index + 2 < values.len) {
                        // The rest of the pattern, rendered as the vector a
                        // pattern is written as.
                        const extra = wrap.fromVector(vectors.fromSlice(values[index + 1 ..]));
                        compiler_primitives.recordError(
                            compiler,
                            try pp_format.formatc("expected a single symbol follow '& in destructuring pattern, found %q", .{extra}),
                        );
                        return true;
                    }
                    if (!wrap.isSymbol(values[index + 1])) {
                        compiler_primitives.recordError(
                            compiler,
                            try pp_format.formatc("expected symbol following '& in destructuring pattern, found %q", .{values[index + 1]}),
                        );
                        return true;
                    }
                    compileRestDestructure(compiler, rhs, next_rhs, @intCast(index));
                    _ = try bindLeaf(
                        compiler,
                        wrap.toSymbol(values[index + 1]),
                        next_rhs,
                        binding_kind,
                        attributes,
                    );
                    compiler_primitives.freeslot(compiler, next_rhs);
                    break;
                }

                if (index < 0x100) {
                    _ = emit_core.emitSsu(compiler, constants.Opcode.get_index, next_rhs, rhs, @intCast(index), 1);
                } else {
                    const key = compiler_primitives.cslot(wrap.fromInteger(@intCast(index)));
                    _ = emit_core.emitSss(compiler, constants.Opcode.in, next_rhs, rhs, key, 1);
                }
                if (try destructure(compiler, subvalue, next_rhs, binding_kind, attributes)) {
                    compiler_primitives.freeslot(compiler, next_rhs);
                }
            }
            return true;
        },
        repr.Tag.table, repr.Tag.map => {
            // Read through the pair reader, so that a map's leaves and a
            // table's slots are one walk. The pattern is a value in the tree
            // and cannot change under the loop.
            var pairs = (try args_core.keyvals(lhs)).?;
            while (try pairs.next()) |pair| {
                const next_rhs = compiler_primitives.farslot(compiler) orelse nilSlot();
                const key = try compiler_primitives.valueImpl(compiler_primitives.foptsDefault(compiler), pair.key);
                _ = emit_core.emitSss(compiler, constants.Opcode.in, next_rhs, rhs, key, 1);
                if (try destructure(compiler, pair.value, next_rhs, binding_kind, attributes)) {
                    compiler_primitives.freeslot(compiler, next_rhs);
                }
            }
            return true;
        },
        else => {
            compiler_primitives.recordError(compiler, try pp_format.formatc("unexpected type in destructuring, got %v", .{lhs}));
            return true;
        },
    }
}

/// Appends one instruction word to the compiler's buffer.
fn emitInstruction(compiler: *compiler_primitives.Compiler, instruction: u32) void {
    _ = emit_core.emit(compiler, @bitCast(instruction));
}

/// Records `message`, closes the function scope, and gives back a nil slot.
fn functionError(compiler: *compiler_primitives.Compiler, message: [*:0]const u8) raise.Error!compiler_primitives.Slot {
    compiler_primitives.cerror(compiler, message);
    try compiler_primitives.popscope(compiler);
    return nilSlot();
}

/// Reads a binding's metadata out of the form's leading keywords and strings,
/// as a table.
fn handleAttributes(
    compiler: *compiler_primitives.Compiler,
    binding_kind: [*:0]const u8,
    arguments: []const repr.Value,
) raise.Error!?*tables.Table {
    if (arguments.len < 2) {
        compiler_primitives.recordError(compiler, try pp_format.formatc("expected at least 2 arguments to %s", .{binding_kind}));
        return null;
    }
    const table = tables.new(2);
    const binding_name: [*:0]const u8 = if (wrap.isSymbol(arguments[0]))
        @ptrCast(wrap.toSymbol(arguments[0]))
    else
        "<multiple bindings>";
    for (arguments[1 .. arguments.len - 1]) |attribute| {
        switch (repr.typeOf(attribute)) {
            repr.Tag.tuple => compiler_primitives.cerror(compiler, "unexpected form - did you intend to use defn?"),
            repr.Tag.string => tables.put(table, value.fromBytes("doc", .keyword), attribute),
            repr.Tag.map => tables.mergeMap(table, wrap.toMap(attribute)),
            else => if (wrap.isKeyword(attribute))
                tables.put(table, attribute, wrap.fromTrue())
            else
                compiler_primitives.recordError(
                    compiler,
                    try pp_format.formatc("cannot add metadata %v to binding %s", .{ attribute, binding_name }),
                ),
        }
    }
    return table;
}

/// The special form `name` names, or null.
///
/// The table is in lexicographic order and this is a binary search over it.
fn lookup(name: [*:0]const u8) ?*const special.Special {
    var lower: usize = 0;
    var upper: usize = specials.len;
    while (lower < upper) {
        const middle = lower + (upper - lower) / 2;
        const comparison = utils.cstrcmp(name, specials[middle].name);
        if (comparison == 0) return &specials[middle];
        if (comparison < 0) {
            upper = middle;
        } else {
            lower = middle + 1;
        }
    }
    return null;
}

/// The current source position, as the `(source line column)` tuple a binding
/// records.
fn makeSourceMap(compiler: *compiler_primitives.Compiler) tuples.Tuple {
    const tuple = tuples.begin(3);
    tuple[0] = if (compiler.source) |source| wrap.fromString(source) else wrap.fromNil();
    tuple[1] = wrap.fromInteger(compiler.current_mapping.line);
    tuple[2] = wrap.fromInteger(compiler.current_mapping.column);
    return tuples.end(tuple);
}

/// The metadata a binding has, where it has any.
///
/// `handleAttributes` gives back a table for every `def` and `var` it accepts,
/// empty where the form had no metadata, and `specialFn`'s parameter
/// destructuring passes none at all. Every reader below asks the same two
/// questions of it in the same order; this asks them once.
fn metadata(attributes: ?*tables.Table) ?*tables.Table {
    const table = attributes orelse return null;
    return if (table.count == 0) null else table;
}

/// Gives a slot a name in the current scope, aliasing the slot it was given
/// where nothing would observe the difference.
fn nameLocal(
    compiler: *compiler_primitives.Compiler,
    symbol: [*:0]const u8,
    binding_flags: compiler_primitives.SlotFlags,
    original_slot: compiler_primitives.Slot,
    original_definition_flags: u32,
) raise.Error!bool {
    var slot = original_slot;
    var definition_flags = original_definition_flags;
    var unnamed_register = !slot.flags.named and slot.index > 0 and slot.envindex >= 0;
    const can_alias = !binding_flags.mutable and
        !slot.flags.mutable and
        slot.flags.named and
        slot.index >= 0 and slot.envindex == -1;
    if (can_alias) {
        slot.flags.mutable = false;
        unnamed_register = true;
    } else if (!unnamed_register) {
        const local_slot = compiler_primitives.farslot(compiler) orelse nilSlot();
        emit_core.copy(compiler, local_slot, slot);
        slot = local_slot;
    }
    // The only bit `nameLocal`'s two callers set is `mutable`, and it is a
    // union with the bit the slot already has rather than a replacement.
    slot.flags.mutable = slot.flags.mutable or binding_flags.mutable;
    if (currentScope(compiler).flags.top) definition_flags |= constants.defflag_no_unused;
    try compiler_primitives.nameslot(compiler, symbol, slot, definition_flags);
    return !unnamed_register;
}

/// A fresh one-element array of nil, which is the box a `var` binding at the
/// top scope is stored in.
fn newReferenceArray() raise.Error!*arrays.Array {
    const reference = arrays.new(1);
    try arrays.push(reference, wrap.fromNil());
    return reference;
}

/// A nil constant slot.
fn nilSlot() compiler_primitives.Slot {
    return compiler_primitives.cslot(wrap.fromNil());
}

/// Appends one slot to a slot vector.
fn pushSlot(slots: *scratch_vector.Vector(compiler_primitives.Slot), val: compiler_primitives.Slot) void {
    scratch_vector.push(slots, val);
}

/// Compiles a quasiquoted value, unquoting at level zero and recursing into
/// every aggregate.
///
/// `depth` is the recursion guard and `original_level` the quasiquote nesting,
/// which an inner `quasiquote` raises and an `unquote` lowers.
fn quasiquote(options: compiler_primitives.FormOptions, val: repr.Value, depth: i32, original_level: i32) raise.Error!compiler_primitives.Slot {
    if (depth == 0) {
        compiler_primitives.cerror(options.compiler, "quasiquote too deeply nested");
        return nilSlot();
    }
    var slots: scratch_vector.Vector(compiler_primitives.Slot) = .empty;
    var suboptions = options;
    suboptions.flags.hint = false;
    var level = original_level;

    switch (repr.typeOf(val)) {
        repr.Tag.tuple => {
            const tuple = wrap.toTuple(val);
            const length = tuples.head(tuple).length;
            if (length > 1 and wrap.isSymbol(tuple[0])) {
                const head = wrap.toSymbol(tuple[0]);
                if (utils.cstrcmp(head, "unquote") == 0) {
                    if (level == 0) {
                        var unquote_options = compiler_primitives.foptsDefault(options.compiler);
                        unquote_options.flags.accept_splice = true;
                        return try compiler_primitives.valueImpl(unquote_options, tuple[1]);
                    }
                    level -= 1;
                } else if (utils.cstrcmp(head, "quasiquote") == 0) {
                    level += 1;
                }
            }
            for (0..@as(usize, @intCast(length))) |index| {
                pushSlot(&slots, try quasiquote(suboptions, tuple[index], depth - 1, level));
            }
            return quoteSlots(options, slots, constants.Opcode.make_tuple);
        },
        repr.Tag.array => {
            const array = wrap.toArray(val);
            for (0..array.count) |index| {
                pushSlot(&slots, try quasiquote(suboptions, array.slice()[index], depth - 1, level));
            }
            return quoteSlots(options, slots, constants.Opcode.make_array);
        },
        repr.Tag.vector => {
            // Gathered rather than read a run at a time: quasiquoting an
            // element compiles a form, and a vector's elements are not one
            // block.
            var elements = (try args_core.gather(val)).?;
            defer elements.free();
            for (elements.items) |element| {
                pushSlot(&slots, try quasiquote(suboptions, element, depth - 1, level));
            }
            return quoteSlots(options, slots, constants.Opcode.make_vector);
        },
        repr.Tag.table, repr.Tag.map => {
            // Read through the pair reader, so that a map's leaves and a
            // table's slots are one walk. Quasiquoting a key or a value
            // compiles a form, which cannot change the dictionary being read:
            // it is a value in the tree.
            var pairs = (try args_core.keyvals(val)).?;
            while (try pairs.next()) |current| {
                var key = try quasiquote(suboptions, current.key, depth - 1, level);
                var pair_value = try quasiquote(suboptions, current.value, depth - 1, level);
                key.flags.spliced = false;
                pair_value.flags.spliced = false;
                pushSlot(&slots, key);
                pushSlot(&slots, pair_value);
            }
            return quoteSlots(
                options,
                slots,
                if (repr.checkType(val, repr.Tag.table)) constants.Opcode.make_table else constants.Opcode.make_map,
            );
        },
        repr.Tag.abstract => {
            // A set rebuilds, as a vector and a map do, so an unquote inside
            // one is compiled rather than kept as a literal `(unquote x)`.
            // Every other abstract is its own constant.
            const tree = maps.toTree(val, .set) orelse return compiler_primitives.cslot(val);
            // Read in the set's own order, not sorted. The dictionary arm
            // above reads a map in its storage order for the same reason:
            // these are the quasiquote arms, and an unquote inside a quoted
            // collection has the same unstable evaluation order a literal's
            // forms would have without `toslotskv`'s sort. Sorting here is a
            // separate question from `makeSet`'s and belongs with the map arm
            // rather than ahead of it.
            var element = wrap.fromNil();
            for (0..tree.count) |_| {
                element = maps.nextElement(tree, element);
                pushSlot(&slots, try quasiquote(suboptions, element, depth - 1, level));
            }
            return compiler_primitives.callConstant(options, slots, maps.hash_set_nfunction);
        },
        else => return compiler_primitives.cslot(val),
    }
}

/// Emits the constructor for a quoted aggregate over the slots already
/// gathered.
fn quoteSlots(options: compiler_primitives.FormOptions, slots: scratch_vector.Vector(compiler_primitives.Slot), opcode: constants.Opcode) compiler_primitives.Slot {
    const target = compiler_primitives.gettarget(options);
    _ = compiler_primitives.pushslots(options.compiler, slots.items);
    compiler_primitives.freeslots(options.compiler, slots);
    _ = emit_core.emitSlot(options.compiler, opcode, target, 1);
    return target;
}

/// `break`: leaves the innermost `while`, with an optional value.
fn specialBreak(
    options: compiler_primitives.FormOptions,
    arguments: []const repr.Value,
) raise.Error!compiler_primitives.Slot {
    const compiler: *compiler_primitives.Compiler = options.compiler;
    if (arguments.len > 1) {
        compiler_primitives.cerror(compiler, "expected at most 1 argument");
        return nilSlot();
    }

    var scope = compiler.scope;
    while (scope) |current| : (scope = current.parent) {
        if (current.flags.function or current.flags.while_body) break;
    }
    const target_scope = scope orelse {
        compiler_primitives.cerror(compiler, "break must occur in while loop or closure");
        return nilSlot();
    };

    var suboptions = compiler_primitives.foptsDefault(compiler);
    if (target_scope.flags.function) {
        if (!target_scope.flags.while_body and arguments.len != 0) {
            suboptions.flags.tail = true;
            _ = try compiler_primitives.valueImpl(suboptions, arguments[0]);
        } else {
            if (arguments.len != 0) {
                suboptions.flags.drop = true;
                _ = try compiler_primitives.valueImpl(suboptions, arguments[0]);
            }
            _ = emit_core.emit(compiler, constants.Opcode.return_nil.number());
        }
    } else {
        if (arguments.len != 0) {
            suboptions.flags.drop = true;
            _ = try compiler_primitives.valueImpl(suboptions, arguments[0]);
        }
        _ = emit_core.emit(compiler, 0x80 | constants.Opcode.jump.number());
    }
    return nilSlot();
}

/// `def`: an immutable binding.
fn specialDef(
    options: compiler_primitives.FormOptions,
    arguments: []const repr.Value,
) raise.Error!compiler_primitives.Slot {
    return try compileBinding(options, arguments, .definition);
}

/// `do`: a run of forms in a scope of their own, giving back the last.
fn specialDo(
    options: compiler_primitives.FormOptions,
    arguments: []const repr.Value,
) raise.Error!compiler_primitives.Slot {
    const compiler: *compiler_primitives.Compiler = options.compiler;
    var scope: compiler_primitives.Scope = undefined;
    compiler_primitives.pushScope(&scope, compiler, .{}, "do");
    const result = try compileSequence(options, arguments);
    try compiler_primitives.popscopeKeepslot(compiler, result);
    return result;
}

/// `fn`: a function literal, with its parameters destructured into the new
/// scope.
fn specialFn(
    options: compiler_primitives.FormOptions,
    arguments: []const repr.Value,
) raise.Error!compiler_primitives.Slot {
    const compiler: *compiler_primitives.Compiler = options.compiler;
    currentScope(compiler).flags.closure = true;
    var function_scope: compiler_primitives.Scope = undefined;
    compiler_primitives.pushScope(&function_scope, compiler, .{ .function = true }, "function");

    if (arguments.len == 0) {
        return functionError(compiler, "expected at least 1 argument to function literal");
    }

    var parameter_index: i32 = 0;
    const head = arguments[0];
    const self_reference = wrap.isSymbol(head);
    const has_name = self_reference or wrap.isKeyword(head);
    if (has_name) parameter_index = 1;
    if (parameter_index >= arguments.len or
        !repr.TagSet.of(&.{ .tuple, .vector }).has(repr.typeOf(arguments[@intCast(parameter_index)])))
    {
        return functionError(compiler, "expected function parameters");
    }

    // Gathered rather than read a run at a time: the list is walked twice and
    // indexed against the arity, and a vector's elements are not one block.
    // `free` is deferred because every refusal below returns early.
    var gathered = (try args_core.gather(arguments[@intCast(parameter_index)])).?;
    defer gathered.free();
    const parameters = gathered.items;
    // The arity arithmetic below subtracts one and two from this and compares
    // the result with an index, which is a signed question: `parameter_count`
    // is the list's length narrowed once, here, rather than a `usize` that
    // would wrap under those subtractions.
    const parameter_count: i32 = @intCast(parameters.len);
    var destructured_parameters: scratch_vector.Vector(compiler_primitives.Slot) = .empty;
    var named_parameters: scratch_vector.Vector(compiler_primitives.Slot) = .empty;
    var named_table: ?*tables.Table = null;
    var named_slot: compiler_primitives.Slot = undefined;
    var arity = parameter_count;
    var minimum_arity: i32 = 0;
    var vararg = false;
    var maparg = false;
    var allow_extra = false;
    var seen_amp = false;
    var seen_optional = false;

    for (parameters, 0..) |parameter, index| {
        // `named_table` is the `&named` flag: it is created when the marker is
        // seen and nothing clears it, so every later parameter is a named one.
        if (named_table) |named| {
            arity -= 1;
            if (!wrap.isSymbol(parameter)) {
                scratch_vector.free(&destructured_parameters);
                scratch_vector.free(&named_parameters);
                return functionError(compiler, "only named arguments can follow &named");
            }
            tables.put(
                named,
                value.fromBytes(std.mem.span(wrap.toSymbol(parameter)), .keyword),
                parameter,
            );
            pushSlot(&named_parameters, compiler_primitives.farslot(compiler) orelse nilSlot());
            continue;
        }

        if (!wrap.isSymbol(parameter)) {
            pushSlot(&destructured_parameters, compiler_primitives.farslot(compiler) orelse nilSlot());
            continue;
        }

        const symbol = wrap.toSymbol(parameter);
        if (symbol[0] != '&') {
            try compiler_primitives.nameslot(compiler, symbol, compiler_primitives.farslot(compiler) orelse nilSlot(), 0);
            continue;
        }

        if (utils.cstrcmp(symbol, "&") == 0) {
            if (seen_amp) {
                return cleanupFunctionError(compiler, &destructured_parameters, &named_parameters, "& in unexpected location");
            } else if (index == parameter_count - 1) {
                allow_extra = true;
                arity -= 1;
            } else if (index == parameter_count - 2) {
                vararg = true;
                arity -= 2;
            } else {
                return cleanupFunctionError(compiler, &destructured_parameters, &named_parameters, "& in unexpected location");
            }
            seen_amp = true;
        } else if (utils.cstrcmp(symbol, "&opt") == 0) {
            if (seen_optional) {
                return cleanupFunctionError(compiler, &destructured_parameters, &named_parameters, "only one &opt allowed");
            } else if (index == parameter_count - 1) {
                return cleanupFunctionError(compiler, &destructured_parameters, &named_parameters, "&opt cannot be last item in parameter list");
            }
            minimum_arity = @intCast(index);
            arity -= 1;
            seen_optional = true;
        } else if (utils.cstrcmp(symbol, "&keys") == 0) {
            if (seen_amp or index != parameter_count - 2) {
                return cleanupFunctionError(compiler, &destructured_parameters, &named_parameters, "&keys in unexpected location");
            }
            vararg = true;
            maparg = true;
            arity -= 2;
            seen_amp = true;
        } else if (utils.cstrcmp(symbol, "&named") == 0) {
            if (seen_amp) {
                return cleanupFunctionError(compiler, &destructured_parameters, &named_parameters, "&named in unexpected location");
            }
            vararg = true;
            maparg = true;
            arity -= 1;
            seen_amp = true;
            named_table = tables.new(10);
            named_slot = compiler_primitives.farslot(compiler) orelse nilSlot();
        } else {
            try compiler_primitives.nameslot(compiler, symbol, compiler_primitives.farslot(compiler) orelse nilSlot(), 0);
        }
    }

    if (named_table) |named| {
        _ = try destructure(
            compiler,
            wrap.fromTable(named),
            named_slot,
            .definition,
            null,
        );
        compiler_primitives.freeslot(compiler, named_slot);
        scratch_vector.free(&named_parameters);
    }

    var destructured_index: usize = 0;
    for (parameters) |parameter| {
        if (wrap.isSymbol(parameter)) continue;
        if (destructured_index >= destructured_parameters.items.len) unreachable;
        const parameter_slot = destructured_parameters.items[destructured_index];
        destructured_index += 1;
        _ = try destructure(compiler, parameter, parameter_slot, .definition, null);
        compiler_primitives.freeslot(compiler, parameter_slot);
    }
    scratch_vector.free(&destructured_parameters);

    const maximum_arity: i32 = if (vararg or allow_extra) std_max_i32 else arity;
    if (!seen_optional) minimum_arity = arity;

    if (self_reference) {
        const symbol = wrap.toSymbol(head);
        var found = false;
        for (currentScope(compiler).syms.items) |pair| {
            if (pair.sym == symbol) found = true;
        }
        if (!found) {
            var slot = compiler_primitives.farslot(compiler) orelse nilSlot();
            slot.flags = .{ .named = true, .types = .one(.function) };
            _ = emit_core.emitSlot(compiler, constants.Opcode.load_self, slot, 1);
            try compiler_primitives.nameslot(
                compiler,
                symbol,
                slot,
                constants.defflag_no_unused | constants.defflag_no_shadowcheck,
            );
        }
    }

    var suboptions = compiler_primitives.foptsDefault(compiler);
    if (parameter_index + 1 == arguments.len) {
        _ = emit_core.emit(compiler, constants.Opcode.return_nil.number());
    } else {
        for (arguments[@intCast(parameter_index + 1)..], @as(usize, @intCast(parameter_index + 1))..) |argument, argument_index| {
            suboptions.flags = if (argument_index == arguments.len - 1) .{ .tail = true } else .{ .drop = true };
            _ = try compiler_primitives.valueImpl(suboptions, argument);
            if (compiler.result.status == .@"error") {
                try compiler_primitives.popscope(compiler);
                return nilSlot();
            }
        }
    }

    const definition = try compiler_primitives.popFuncdef(compiler);
    definition.arity = arity;
    definition.min_arity = minimum_arity;
    definition.max_arity = maximum_arity;
    if (named_table) |named| definition.named_args_count = @intCast(named.count);
    if (vararg) definition.flags.vararg = true;
    if (maparg) definition.flags.maparg = true;
    if (named_table != null) definition.flags.namedargs = true;
    if (has_name) definition.name = wrap.toSymbol(head);
    compiler_primitives.defAddflags(definition);
    const definition_index = addFunctionDefinition(compiler, definition);
    const vararg_slot: i32 = if (vararg) 1 else 0;
    if (arity + vararg_slot > definition.slotcount) definition.slotcount = arity + vararg_slot;

    const result = compiler_primitives.gettarget(options);
    _ = emit_core.emitSu(compiler, constants.Opcode.closure, result, @intCast(definition_index), 1);
    return result;
}

/// `if`: the two-armed conditional, with the false arm optional.
fn specialIf(
    options: compiler_primitives.FormOptions,
    arguments: []const repr.Value,
) raise.Error!compiler_primitives.Slot {
    const compiler: *compiler_primitives.Compiler = options.compiler;
    if (arguments.len < 2 or arguments.len > 3) {
        compiler_primitives.cerror(compiler, "expected 2 or 3 arguments to if");
        return nilSlot();
    }

    var true_body = arguments[1];
    var false_body = if (arguments.len > 2) arguments[2] else wrap.fromNil();
    const condition_options = compiler_primitives.foptsDefault(compiler);
    var body_options = options;
    body_options.flags.accept_splice = false;
    const tail = options.flags.tail;
    const drop = options.flags.drop;
    var target = if (drop or tail) nilSlot() else compiler_primitives.gettarget(options);

    var condition_scope: compiler_primitives.Scope = undefined;
    compiler_primitives.pushScope(&condition_scope, compiler, .{}, "if");
    var condition_form = arguments[0];
    var jump_opcode: constants.Opcode = .jump_if_not;
    if (checkNilForm(condition_form, constants.fun_eq)) |operand| {
        condition_form = operand;
        jump_opcode = constants.Opcode.jump_if_not_nil;
    } else if (checkNilForm(condition_form, constants.fun_neq)) |operand| {
        condition_form = operand;
        jump_opcode = constants.Opcode.jump_if_nil;
    }
    const condition = try compiler_primitives.valueImpl(condition_options, condition_form);

    if (condition.flags.constant) {
        const swap_condition =
            (jump_opcode == constants.Opcode.jump_if_not and !repr.truthy(condition.constant)) or
            (jump_opcode == constants.Opcode.jump_if_nil and repr.checkType(condition.constant, repr.Tag.nil)) or
            (jump_opcode == constants.Opcode.jump_if_not_nil and !repr.checkType(condition.constant, repr.Tag.nil));
        if (swap_condition) {
            const temporary = false_body;
            false_body = true_body;
            true_body = temporary;
        }
        var body_scope: compiler_primitives.Scope = undefined;
        compiler_primitives.pushScope(&body_scope, compiler, .{}, "if-true");
        const right = try compiler_primitives.valueImpl(body_options, true_body);
        if (!drop and !tail) emit_core.copy(compiler, target, right);
        try compiler_primitives.popscope(compiler);
        if (!repr.checkType(false_body, repr.Tag.nil)) {
            try compiler_primitives.throwaway(body_options, false_body);
        }
        try compiler_primitives.popscope(compiler);
        return target;
    }

    const right_jump = emit_core.emitSi(compiler, jump_opcode, condition, 0, 0);
    var body_scope: compiler_primitives.Scope = undefined;
    compiler_primitives.pushScope(&body_scope, compiler, .{}, "if-true");
    const left = try compiler_primitives.valueImpl(body_options, true_body);
    if (!drop and !tail) emit_core.copy(compiler, target, left);
    try compiler_primitives.popscope(compiler);

    const done_jump = compiler.here();
    if (!tail and !(drop and repr.checkType(false_body, repr.Tag.nil))) {
        _ = emit_core.emit(compiler, constants.Opcode.jump.number());
    }
    const right_label = compiler.here();
    compiler_primitives.pushScope(&body_scope, compiler, .{}, "if-false");
    const right = try compiler_primitives.valueImpl(body_options, false_body);
    if (!drop and !tail) emit_core.copy(compiler, target, right);
    try compiler_primitives.popscope(compiler);
    try compiler_primitives.popscope(compiler);

    const done_label = compiler.here();
    if (right_jump < done_label) {
        checkJump16(compiler, right_jump, right_label);
        compiler.buffer.items[@intCast(right_jump)] |= @as(u32, @intCast(right_label - right_jump)) << 16;
        if (!tail and done_jump < done_label) {
            checkJump24(compiler, done_jump, done_label);
            compiler.buffer.items[@intCast(done_jump)] |= @as(u32, @intCast(done_label - done_jump)) << 8;
        }
    }

    if (tail) target.flags.returned = true;
    return target;
}

/// `quasiquote`: a quoted value with `unquote` holes compiled into it.
fn specialQuasiquote(
    options: compiler_primitives.FormOptions,
    arguments: []const repr.Value,
) raise.Error!compiler_primitives.Slot {
    if (arguments.len != 1) {
        compiler_primitives.cerror(options.compiler, "expected 1 argument to quasiquote");
        return nilSlot();
    }
    return quasiquote(options, arguments[0], config.recursion_guard, 0);
}

/// `quote`: its one argument as a constant, uncompiled.
fn specialQuote(
    options: compiler_primitives.FormOptions,
    arguments: []const repr.Value,
) raise.Error!compiler_primitives.Slot {
    if (arguments.len != 1) {
        compiler_primitives.cerror(options.compiler, "expected 1 argument to quote");
        return nilSlot();
    }
    return compiler_primitives.cslot(arguments[0]);
}

/// `set`: writes a value into an existing binding.
fn specialSet(
    options: compiler_primitives.FormOptions,
    arguments: []const repr.Value,
) raise.Error!compiler_primitives.Slot {
    const compiler: *compiler_primitives.Compiler = options.compiler;
    if (arguments.len != 2) {
        compiler_primitives.cerror(compiler, "expected 2 arguments to set");
        return nilSlot();
    }
    const suboptions = compiler_primitives.foptsDefault(compiler);

    if (wrap.isSymbol(arguments[0])) {
        const destination = try compiler_primitives.resolve(compiler, wrap.toSymbol(arguments[0]));
        if (!destination.flags.mutable) {
            compiler_primitives.cerror(compiler, "cannot set constant");
            return nilSlot();
        }
        var value_options = suboptions;
        value_options.flags = .{ .hint = true };
        value_options.hint = destination;
        const result = try compiler_primitives.valueImpl(value_options, arguments[1]);
        emit_core.copy(compiler, destination, result);
        return result;
    }

    if (repr.checkType(arguments[0], repr.Tag.tuple)) {
        const tuple = wrap.toTuple(arguments[0]);
        if (tuples.head(tuple).length != 2) {
            compiler_primitives.cerror(compiler, "expected 2 element tuple for l-value to set");
            return nilSlot();
        }
        const data_structure = try compiler_primitives.valueImpl(suboptions, tuple[0]);
        const key = try compiler_primitives.valueImpl(suboptions, tuple[1]);
        var value_options = options;
        value_options.flags.tail = false;
        value_options.flags.drop = false;
        const result = try compiler_primitives.valueImpl(value_options, arguments[1]);
        _ = emit_core.emitSss(compiler, constants.Opcode.put, data_structure, key, result, 0);
        return result;
    }

    compiler_primitives.cerror(compiler, "expected symbol or tuple for l-value to set");
    return nilSlot();
}

/// `splice`: accepted only in function parameters and data constructors, and
/// an error anywhere else.
fn specialSplice(
    options: compiler_primitives.FormOptions,
    arguments: []const repr.Value,
) raise.Error!compiler_primitives.Slot {
    if (!options.flags.accept_splice) {
        compiler_primitives.cerror(options.compiler, "splice can only be used in function parameters and data constructors, it has no effect here");
        return nilSlot();
    }
    if (arguments.len != 1) {
        compiler_primitives.cerror(options.compiler, "expected 1 argument to splice");
        return nilSlot();
    }
    var result = try compiler_primitives.valueImpl(options, arguments[0]);
    result.flags.spliced = true;
    return result;
}

/// `unquote`: an error outside a `quasiquote`, which is the only place it is
/// reached from.
fn specialUnquote(
    options: compiler_primitives.FormOptions,
    _: []const repr.Value,
) raise.Error!compiler_primitives.Slot {
    compiler_primitives.cerror(options.compiler, "cannot use unquote here");
    return nilSlot();
}

/// `upscope`: a run of forms in the enclosing scope rather than a new one.
fn specialUpscope(
    options: compiler_primitives.FormOptions,
    arguments: []const repr.Value,
) raise.Error!compiler_primitives.Slot {
    return compileSequence(options, arguments);
}

/// `var`: a mutable binding.
fn specialVar(
    options: compiler_primitives.FormOptions,
    arguments: []const repr.Value,
) raise.Error!compiler_primitives.Slot {
    return try compileBinding(options, arguments, .variable);
}

/// `while`: the loop, with its `break` jumps patched once the exit position
/// has been reached.
fn specialWhile(
    options: compiler_primitives.FormOptions,
    arguments: []const repr.Value,
) raise.Error!compiler_primitives.Slot {
    const compiler: *compiler_primitives.Compiler = options.compiler;
    if (arguments.len < 1) {
        compiler_primitives.cerror(compiler, "expected at least 1 argument to while");
        return nilSlot();
    }

    const while_label = compiler.here();
    var suboptions = compiler_primitives.foptsDefault(compiler);
    var scope: compiler_primitives.Scope = undefined;
    compiler_primitives.pushScope(&scope, compiler, .{ .while_body = true }, "while");

    var condition_form = arguments[0];
    var is_nil_form = false;
    var is_not_nil_form = false;
    var true_jump: constants.Opcode = .jump_if;
    var false_jump: constants.Opcode = .jump_if_not;
    if (checkNilForm(condition_form, constants.fun_eq)) |operand| {
        condition_form = operand;
        is_nil_form = true;
        true_jump = constants.Opcode.jump_if_nil;
        false_jump = constants.Opcode.jump_if_not_nil;
    }
    if (checkNilForm(condition_form, constants.fun_neq)) |operand| {
        condition_form = operand;
        is_not_nil_form = true;
        true_jump = constants.Opcode.jump_if_not_nil;
        false_jump = constants.Opcode.jump_if_nil;
    }

    var condition = try compiler_primitives.valueImpl(suboptions, condition_form);
    var infinite = false;
    if (condition.flags.constant) {
        const never_executes = if (is_nil_form)
            !repr.checkType(condition.constant, repr.Tag.nil)
        else if (is_not_nil_form)
            repr.checkType(condition.constant, repr.Tag.nil)
        else
            !repr.truthy(condition.constant);
        if (never_executes) {
            try compiler_primitives.popscope(compiler);
            return nilSlot();
        }
        infinite = true;
    }

    const condition_label = if (infinite)
        0
    else
        emit_core.emitSi(compiler, false_jump, condition, 0, 0);
    for (arguments[1..]) |argument| {
        suboptions.flags = .{ .drop = true };
        compiler_primitives.freeslot(compiler, try compiler_primitives.valueImpl(suboptions, argument));
    }

    if (scope.flags.closure) {
        suboptions = compiler_primitives.foptsDefault(compiler);
        scope.flags.unused = true;
        try compiler_primitives.popscope(compiler);
        compiler.buffer.shrinkRetainingCapacity(@intCast(while_label));
        compiler.mapbuffer.shrinkRetainingCapacity(@intCast(while_label));

        compiler_primitives.pushScope(&scope, compiler, .{ .function = true }, "while-iife");
        condition = try compiler_primitives.valueImpl(suboptions, condition_form);
        if (!condition.flags.constant) {
            _ = emit_core.emitSi(compiler, true_jump, condition, 2, 0);
            _ = emit_core.emit(compiler, constants.Opcode.return_nil.number());
        }
        for (arguments[1..]) |argument| {
            suboptions.flags = .{ .drop = true };
            compiler_primitives.freeslot(compiler, try compiler_primitives.valueImpl(suboptions, argument));
        }

        const self_register = scope.ra.allocateTemp(constants.RegisterTemp.t0);
        emitInstruction(compiler, @as(u32, constants.Opcode.load_self.number()) | (@as(u32, @intCast(self_register)) << 8));
        emitInstruction(compiler, @as(u32, constants.Opcode.tailcall.number()) | (@as(u32, @intCast(self_register)) << 8));
        currentScope(compiler).ra.freeTemp(self_register, constants.RegisterTemp.t0);

        const definition = try compiler_primitives.popFuncdef(compiler);
        definition.name = strings.cstring("while");
        compiler_primitives.defAddflags(definition);
        const definition_index = addFunctionDefinition(compiler, definition);
        const closure_register = currentScope(compiler).ra.allocateTemp(constants.RegisterTemp.t0);
        emitInstruction(
            compiler,
            @as(u32, constants.Opcode.closure.number()) |
                (@as(u32, @intCast(closure_register)) << 8) |
                (@as(u32, @intCast(definition_index)) << 16),
        );
        emitInstruction(
            compiler,
            @as(u32, constants.Opcode.call.number()) |
                (@as(u32, @intCast(closure_register)) << 8) |
                (@as(u32, @intCast(closure_register)) << 16),
        );
        currentScope(compiler).ra.freeTemp(closure_register, constants.RegisterTemp.t0);
        currentScope(compiler).flags.closure = true;
        return nilSlot();
    }

    const top_jump = compiler.here();
    _ = emit_core.emit(compiler, constants.Opcode.jump.number());
    const done_label = compiler.here();
    if (!infinite) {
        checkJump16(compiler, condition_label, done_label);
        compiler.buffer.items[@intCast(condition_label)] |= @as(u32, @intCast(done_label - condition_label)) << 16;
    }
    checkJump24(compiler, top_jump, while_label);
    compiler.buffer.items[@intCast(top_jump)] |= @as(u32, @bitCast(while_label - top_jump)) << 8;

    // Every `break` the body emitted is an unpatched jump waiting for the
    // loop's exit; `while_label + offset` is the position each one sits at.
    const region = compiler.buffer.items[@intCast(while_label)..@intCast(done_label)];
    for (region, 0..) |*instruction, offset| {
        if (instruction.* == 0x80 | constants.Opcode.jump.number()) {
            const here = while_label + @as(i32, @intCast(offset));
            checkJump24(compiler, here, done_label);
            instruction.* = @as(u32, constants.Opcode.jump.number()) |
                (@as(u32, @intCast(done_label - here)) << 8);
        }
    }
    try compiler_primitives.popscope(compiler);
    return nilSlot();
}

/// Whether `val` is the symbol `string` names.
fn symbolEquals(val: repr.Value, string: [*:0]const u8) bool {
    return wrap.isSymbol(val) and
        utils.cstrcmp(wrap.toSymbol(val), string) == 0;
}

/// The value `keyword` names in `table`.
fn tableGetKeyword(table: *tables.Table, keyword: [*:0]const u8) repr.Value {
    return tables.get(table, value.fromBytes(std.mem.span(keyword), .keyword));
}
