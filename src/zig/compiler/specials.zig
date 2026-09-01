//! The thirteen special forms: `quote`, `do`, `if`, `fn`, `def`, `var`, `set`,
//! `while`, `break`, `upscope`, `splice`, `quasiquote` and `unquote`.
//!
//! `janetc_special` at the foot of this file is what `janetc_value` consults
//! before treating a tuple's head as a call.
//!
//! **A compile error and a raise are two channels, and this file uses both.**
//! A malformed form is recorded on the compiler by `cerror` and compilation
//! keeps going, so that the first error is the one the user sees; a raise --
//! from a macro, from the allocator, from a value operation -- returns
//! `raise.Error` and every one of these forms carries it.

const std = @import("std");
const config = @import("config");
const repr = @import("repr");
const constants = @import("constants");
const raise = @import("../raise.zig");
const pp_format = @import("../pp/format.zig");
const compiler_primitives = @import("../compiler.zig");
const special = @import("../special_type.zig");
const tables = @import("../value/tables.zig");
const strings = @import("../value/strings.zig");
const tuples = @import("../value/tuples.zig");
const utils = @import("../utils.zig");
const stretchy = @import("../stretchy.zig");
const regalloc = @import("regalloc.zig");
const emit_core = @import("emit.zig");
const registry = @import("../registry.zig");
const wrap = @import("../value/helpers/wrap.zig");
const args_core = @import("../args.zig");
const arrays = @import("../value/arrays.zig");
const value = @import("../value.zig");
const functions = @import("../value/functions.zig");

/// A keyword from a NUL-terminated literal, named so the special forms below
/// read as one thing.
inline fn wrapKeyword(val: [*:0]const u8) repr.Value {
    return wrap.fromKeyword(val);
}

fn specialQuote(
    options: compiler_primitives.JanetFopts,
    arguments: []const repr.Value,
) raise.Raising(compiler_primitives.JanetSlot) {
    if (arguments.len != 1) {
        compiler_primitives.cerror(options.compiler, "expected 1 argument to quote");
        return nilSlot();
    }
    return compiler_primitives.cslot(arguments[0]);
}

fn specialSplice(
    options: compiler_primitives.JanetFopts,
    arguments: []const repr.Value,
) raise.Raising(compiler_primitives.JanetSlot) {
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

fn specialUnquote(
    options: compiler_primitives.JanetFopts,
    _: []const repr.Value,
) raise.Raising(compiler_primitives.JanetSlot) {
    compiler_primitives.cerror(options.compiler, "cannot use unquote here");
    return nilSlot();
}

fn specialDo(
    options: compiler_primitives.JanetFopts,
    arguments: []const repr.Value,
) raise.Raising(compiler_primitives.JanetSlot) {
    const compiler: *compiler_primitives.JanetCompiler = options.compiler;
    var scope: compiler_primitives.JanetScope = undefined;
    compiler_primitives.pushScope(&scope, compiler, .{}, "do");
    const result = try compileSequence(options, arguments);
    try compiler_primitives.popscopeKeepslot(compiler, result);
    return result;
}

fn specialUpscope(
    options: compiler_primitives.JanetFopts,
    arguments: []const repr.Value,
) raise.Raising(compiler_primitives.JanetSlot) {
    return compileSequence(options, arguments);
}

fn specialBreak(
    options: compiler_primitives.JanetFopts,
    arguments: []const repr.Value,
) raise.Raising(compiler_primitives.JanetSlot) {
    const compiler: *compiler_primitives.JanetCompiler = options.compiler;
    if (arguments.len > 1) {
        compiler_primitives.cerror(compiler, "expected at most 1 argument");
        return nilSlot();
    }

    var scope = compiler.scope;
    while (scope) |current| : (scope = current.parent) {
        if (current.flags.function or current.flags.while_body) break;
    }
    if (scope == null) {
        compiler_primitives.cerror(compiler, "break must occur in while loop or closure");
        return nilSlot();
    }

    var suboptions = compiler_primitives.foptsDefault(compiler);
    if (scope.?.flags.function) {
        if (!scope.?.flags.while_body and arguments.len != 0) {
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

fn specialIf(
    options: compiler_primitives.JanetFopts,
    arguments: []const repr.Value,
) raise.Raising(compiler_primitives.JanetSlot) {
    const compiler: *compiler_primitives.JanetCompiler = options.compiler;
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

    var condition_scope: compiler_primitives.JanetScope = undefined;
    compiler_primitives.pushScope(&condition_scope, compiler, .{}, "if");
    var condition_form = arguments[0];
    var jump_opcode: constants.Opcode = .jump_if_not;
    if (checkNilForm(condition_form, constants.JANET_FUN_EQ)) |operand| {
        condition_form = operand;
        jump_opcode = constants.Opcode.jump_if_not_nil;
    } else if (checkNilForm(condition_form, constants.JANET_FUN_NEQ)) |operand| {
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
        var body_scope: compiler_primitives.JanetScope = undefined;
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
    var body_scope: compiler_primitives.JanetScope = undefined;
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

fn specialQuasiquote(
    options: compiler_primitives.JanetFopts,
    arguments: []const repr.Value,
) raise.Raising(compiler_primitives.JanetSlot) {
    if (arguments.len != 1) {
        compiler_primitives.cerror(options.compiler, "expected 1 argument to quasiquote");
        return nilSlot();
    }
    return quasiquote(options, arguments[0], config.recursion_guard, 0);
}

fn specialWhile(
    options: compiler_primitives.JanetFopts,
    arguments: []const repr.Value,
) raise.Raising(compiler_primitives.JanetSlot) {
    const compiler: *compiler_primitives.JanetCompiler = options.compiler;
    if (arguments.len < 1) {
        compiler_primitives.cerror(compiler, "expected at least 1 argument to while");
        return nilSlot();
    }

    const while_label = compiler.here();
    var suboptions = compiler_primitives.foptsDefault(compiler);
    var scope: compiler_primitives.JanetScope = undefined;
    compiler_primitives.pushScope(&scope, compiler, .{ .while_body = true }, "while");

    var condition_form = arguments[0];
    var is_nil_form = false;
    var is_not_nil_form = false;
    var true_jump: constants.Opcode = .jump_if;
    var false_jump: constants.Opcode = .jump_if_not;
    if (checkNilForm(condition_form, constants.JANET_FUN_EQ)) |operand| {
        condition_form = operand;
        is_nil_form = true;
        true_jump = constants.Opcode.jump_if_nil;
        false_jump = constants.Opcode.jump_if_not_nil;
    }
    if (checkNilForm(condition_form, constants.JANET_FUN_NEQ)) |operand| {
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
    var index: i32 = 1;
    while (index < @as(i32, @intCast(arguments.len))) : (index += 1) {
        suboptions.flags = .{ .drop = true };
        compiler_primitives.freeslot(compiler, try compiler_primitives.valueImpl(suboptions, arguments[@intCast(index)]));
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
        index = 1;
        while (index < @as(i32, @intCast(arguments.len))) : (index += 1) {
            suboptions.flags = .{ .drop = true };
            compiler_primitives.freeslot(compiler, try compiler_primitives.valueImpl(suboptions, arguments[@intCast(index)]));
        }

        const self_register = regalloc.regallocTemp(&scope.ra, constants.JANETC_REGTEMP_0);
        emitInstruction(compiler, @as(u32, constants.Opcode.load_self.number()) | (@as(u32, @intCast(self_register)) << 8));
        emitInstruction(compiler, @as(u32, constants.Opcode.tailcall.number()) | (@as(u32, @intCast(self_register)) << 8));
        regalloc.regallocFreetemp(&compiler.scope.?.ra, self_register, constants.JANETC_REGTEMP_0);

        const definition = try compiler_primitives.popFuncdef(compiler);
        definition.name = strings.cstring("while");
        compiler_primitives.defAddflags(definition);
        const definition_index = addFunctionDefinition(compiler, definition);
        const closure_register = regalloc.regallocTemp(&compiler.scope.?.ra, constants.JANETC_REGTEMP_0);
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
        regalloc.regallocFreetemp(&compiler.scope.?.ra, closure_register, constants.JANETC_REGTEMP_0);
        compiler.scope.?.flags.closure = true;
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

    index = while_label;
    while (index < done_label) : (index += 1) {
        if (compiler.buffer.items[@intCast(index)] == 0x80 | constants.Opcode.jump.number()) {
            checkJump24(compiler, index, done_label);
            compiler.buffer.items[@intCast(index)] = @as(u32, constants.Opcode.jump.number()) |
                (@as(u32, @intCast(done_label - index)) << 8);
        }
    }
    try compiler_primitives.popscope(compiler);
    return nilSlot();
}

fn specialSet(
    options: compiler_primitives.JanetFopts,
    arguments: []const repr.Value,
) raise.Raising(compiler_primitives.JanetSlot) {
    const compiler: *compiler_primitives.JanetCompiler = options.compiler;
    if (arguments.len != 2) {
        compiler_primitives.cerror(compiler, "expected 2 arguments to set");
        return nilSlot();
    }
    const suboptions = compiler_primitives.foptsDefault(compiler);

    if (repr.checkType(arguments[0], repr.Tag.symbol)) {
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

fn specialVar(
    options: compiler_primitives.JanetFopts,
    arguments: []const repr.Value,
) raise.Raising(compiler_primitives.JanetSlot) {
    return try compileBinding(options, arguments, .variable);
}

fn specialDef(
    options: compiler_primitives.JanetFopts,
    arguments: []const repr.Value,
) raise.Raising(compiler_primitives.JanetSlot) {
    return try compileBinding(options, arguments, .definition);
}

fn specialFn(
    options: compiler_primitives.JanetFopts,
    arguments: []const repr.Value,
) raise.Raising(compiler_primitives.JanetSlot) {
    const compiler: *compiler_primitives.JanetCompiler = options.compiler;
    compiler.scope.?.flags.closure = true;
    var function_scope: compiler_primitives.JanetScope = undefined;
    compiler_primitives.pushScope(&function_scope, compiler, .{ .function = true }, "function");

    if (arguments.len == 0) {
        return functionError(compiler, "expected at least 1 argument to function literal");
    }

    var parameter_index: i32 = 0;
    const head = arguments[0];
    const self_reference = repr.checkType(head, repr.Tag.symbol);
    const has_name = self_reference or repr.checkType(head, repr.Tag.keyword);
    if (has_name) parameter_index = 1;
    if (parameter_index >= @as(i32, @intCast(arguments.len)) or
        !repr.checkType(arguments[@intCast(parameter_index)], repr.Tag.tuple))
    {
        return functionError(compiler, "expected function parameters");
    }

    const parameters = wrap.toTuple(arguments[@intCast(parameter_index)]);
    const parameter_count = tuples.head(parameters).length;
    var destructured_parameters: stretchy.Vector(compiler_primitives.JanetSlot) = .empty;
    var named_parameters: stretchy.Vector(compiler_primitives.JanetSlot) = .empty;
    var named_table: ?*tables.Table = null;
    var named_slot: compiler_primitives.JanetSlot = undefined;
    var arity = parameter_count;
    var minimum_arity: i32 = 0;
    var vararg = false;
    var structarg = false;
    var allow_extra = false;
    var seen_amp = false;
    var seen_optional = false;
    var named_arguments = false;

    var index: usize = 0;
    while (index < parameter_count) : (index += 1) {
        const parameter = parameters[index];
        if (named_arguments) {
            arity -= 1;
            if (!repr.checkType(parameter, repr.Tag.symbol)) {
                stretchy.free(&destructured_parameters);
                stretchy.free(&named_parameters);
                return functionError(compiler, "only named arguments can follow &named");
            }
            tables.put(
                named_table.?,
                wrapKeyword(wrap.toSymbol(parameter)),
                parameter,
            );
            pushSlot(&named_parameters, compiler_primitives.farslot(compiler) orelse nilSlot());
            continue;
        }

        if (!repr.checkType(parameter, repr.Tag.symbol)) {
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
            structarg = true;
            arity -= 2;
            seen_amp = true;
        } else if (utils.cstrcmp(symbol, "&named") == 0) {
            if (seen_amp) {
                return cleanupFunctionError(compiler, &destructured_parameters, &named_parameters, "&named in unexpected location");
            }
            vararg = true;
            structarg = true;
            arity -= 1;
            seen_amp = true;
            named_arguments = true;
            named_table = tables.new(10);
            named_slot = compiler_primitives.farslot(compiler) orelse nilSlot();
        } else {
            try compiler_primitives.nameslot(compiler, symbol, compiler_primitives.farslot(compiler) orelse nilSlot(), 0);
        }
    }

    if (named_arguments) {
        _ = try destructure(
            compiler,
            wrap.fromTable(named_table.?),
            named_slot,
            .definition,
            null,
        );
        compiler_primitives.freeslot(compiler, named_slot);
        stretchy.free(&named_parameters);
    }

    var destructured_index: usize = 0;
    index = 0;
    while (index < parameter_count) : (index += 1) {
        const parameter = parameters[@intCast(index)];
        if (repr.checkType(parameter, repr.Tag.symbol)) continue;
        if (destructured_index >= destructured_parameters.items.len) unreachable;
        const parameter_slot = destructured_parameters.items[destructured_index];
        destructured_index += 1;
        _ = try destructure(compiler, parameter, parameter_slot, .definition, null);
        compiler_primitives.freeslot(compiler, parameter_slot);
    }
    stretchy.free(&destructured_parameters);

    const maximum_arity: i32 = if (vararg or allow_extra) std_max_i32 else arity;
    if (!seen_optional) minimum_arity = arity;

    if (self_reference) {
        const symbol = wrap.toSymbol(head);
        var found = false;
        index = 0;
        for (compiler.scope.?.syms.items) |pair| {
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
                constants.JANET_DEFFLAG_NO_UNUSED | constants.JANET_DEFFLAG_NO_SHADOWCHECK,
            );
        }
    }

    var suboptions = compiler_primitives.foptsDefault(compiler);
    if (parameter_index + 1 == @as(i32, @intCast(arguments.len))) {
        _ = emit_core.emit(compiler, constants.Opcode.return_nil.number());
    } else {
        var argument_index = parameter_index + 1;
        while (argument_index < @as(i32, @intCast(arguments.len))) : (argument_index += 1) {
            suboptions.flags = if (argument_index == @as(i32, @intCast(arguments.len)) - 1) .{ .tail = true } else .{ .drop = true };
            _ = try compiler_primitives.valueImpl(suboptions, arguments[@intCast(argument_index)]);
            if (compiler.result.status == constants.JANET_COMPILE_ERROR) {
                try compiler_primitives.popscope(compiler);
                return nilSlot();
            }
        }
    }

    const definition = try compiler_primitives.popFuncdef(compiler);
    definition.arity = arity;
    definition.min_arity = minimum_arity;
    definition.max_arity = maximum_arity;
    if (named_table != null) definition.named_args_count = @intCast(named_table.?.count);
    if (vararg) definition.flags.vararg = true;
    if (structarg) definition.flags.structarg = true;
    if (named_arguments) definition.flags.namedargs = true;
    if (has_name) definition.name = wrap.toSymbol(head);
    compiler_primitives.defAddflags(definition);
    const definition_index = addFunctionDefinition(compiler, definition);
    const vararg_slot: i32 = if (vararg) 1 else 0;
    if (arity + vararg_slot > definition.slotcount) definition.slotcount = arity + vararg_slot;

    const result = compiler_primitives.gettarget(options);
    _ = emit_core.emitSu(compiler, constants.Opcode.closure, result, @intCast(definition_index), 1);
    return result;
}

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

/// `janetc_special`: the special form named, or null.
///
/// The table above is in lexicographic order and this is a binary search over
/// it, exactly as Janet's is.
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

pub fn lookupSpecial(name: [*:0]const u8) ?*const special.Special {
    return lookup(name);
}

fn functionError(compiler: *compiler_primitives.JanetCompiler, message: [*:0]const u8) raise.Raising(compiler_primitives.JanetSlot) {
    compiler_primitives.cerror(compiler, message);
    try compiler_primitives.popscope(compiler);
    return nilSlot();
}

fn cleanupFunctionError(
    compiler: *compiler_primitives.JanetCompiler,
    destructured_parameters: *stretchy.Vector(compiler_primitives.JanetSlot),
    named_parameters: *stretchy.Vector(compiler_primitives.JanetSlot),
    message: [*:0]const u8,
) raise.Raising(compiler_primitives.JanetSlot) {
    stretchy.free(destructured_parameters);
    stretchy.free(named_parameters);
    return functionError(compiler, message);
}

const BindingKind = enum { variable, definition };

const SlotHeadPair = struct {
    lhs: repr.Value,
    rhs: compiler_primitives.JanetSlot,
};

fn compileBinding(
    original_options: compiler_primitives.JanetFopts,
    arguments: []const repr.Value,
    binding_kind: BindingKind,
) raise.Raising(compiler_primitives.JanetSlot) {
    const compiler: *compiler_primitives.JanetCompiler = original_options.compiler;
    const attributes = try handleAttributes(
        compiler,
        if (binding_kind == .variable) "var" else "def",
        arguments,
    );
    if (compiler.result.status == constants.JANET_COMPILE_ERROR) return nilSlot();
    try checkMetadataLint(compiler, attributes);

    var options = original_options;
    if (binding_kind == .definition) options.flags.hint = false;
    var pairs: stretchy.Vector(SlotHeadPair) = .empty;
    try buildDestructureHeads(&pairs, options, arguments[0], arguments[@intCast(@as(i32, @intCast(arguments.len)) - 1)]);
    if (compiler.result.status == constants.JANET_COMPILE_ERROR) {
        stretchy.free(&pairs);
        return nilSlot();
    }

    if (pairs.items.len == 0) unreachable;
    var result = nilSlot();
    for (pairs.items) |pair| {
        _ = try destructure(compiler, pair.lhs, pair.rhs, binding_kind, attributes);
        result = pair.rhs;
    }
    stretchy.free(&pairs);
    return result;
}

fn handleAttributes(
    compiler: *compiler_primitives.JanetCompiler,
    binding_kind: [*:0]const u8,
    arguments: []const repr.Value,
) raise.Raising(?*tables.Table) {
    if (arguments.len < 2) {
        compiler_primitives.recordError(compiler, try pp_format.formatc("expected at least 2 arguments to %s", .{binding_kind}));
        return null;
    }
    const table = tables.new(2);
    const binding_name: [*:0]const u8 = if (repr.typeOf(arguments[0]) == repr.Tag.symbol)
        @ptrCast(wrap.toSymbol(arguments[0]))
    else
        "<multiple bindings>";
    var index: i32 = 1;
    while (index < @as(i32, @intCast(arguments.len)) - 1) : (index += 1) {
        const attribute = arguments[@intCast(index)];
        switch (repr.typeOf(attribute)) {
            repr.Tag.tuple => compiler_primitives.cerror(compiler, "unexpected form - did you intend to use defn?"),
            repr.Tag.keyword => tables.put(table, attribute, wrap.fromTrue()),
            repr.Tag.string => tables.put(table, value.fromBytes("doc", .keyword), attribute),
            repr.Tag.@"struct" => tables.mergeStruct(table, wrap.toStruct(attribute)),
            else => compiler_primitives.recordError(
                compiler,
                try pp_format.formatc("cannot add metadata %v to binding %s", .{ attribute, binding_name }),
            ),
        }
    }
    return table;
}

fn checkMetadataLint(compiler: *compiler_primitives.JanetCompiler, attributes: ?*tables.Table) raise.Raising(void) {
    if (compiler.scope.?.flags.top or attributes == null or attributes.?.count == 0) return;
    if (repr.truthy(tableGetKeyword(attributes.?, "macro"))) {
        try compiler_primitives.lint(compiler, .normal, "macro tag is ignored in inner scopes");
    }
}

fn buildDestructureHeads(
    pairs: *stretchy.Vector(SlotHeadPair),
    options: compiler_primitives.JanetFopts,
    lhs: repr.Value,
    rhs: repr.Value,
) raise.Raising(void) {
    const compiler: *compiler_primitives.JanetCompiler = options.compiler;
    const lhs_indexed = repr.checkType(lhs, repr.Tag.tuple) or
        repr.checkType(lhs, repr.Tag.array);
    const rhs_indexed = repr.checkType(rhs, repr.Tag.array) or
        (repr.checkType(rhs, repr.Tag.tuple) and
            utils.tupleHead(wrap.toTuple(rhs)).gc.flags & constants.JANET_TUPLE_FLAG_BRACKETCTOR != 0);
    const has_drop = options.flags.drop;
    var suboptions = compiler_primitives.foptsDefault(compiler);
    suboptions.flags = options.flags;
    suboptions.flags.tail = false;
    suboptions.flags.drop = false;

    if (has_drop and lhs_indexed and rhs_indexed) {
        const lhs_items = args_core.indexedView(lhs).?;
        const rhs_items = args_core.indexedView(rhs).?;
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
    stretchy.push(pairs, .{ .lhs = lhs, .rhs = try compiler_primitives.valueImpl(suboptions, rhs) });
}

fn destructure(
    compiler: *compiler_primitives.JanetCompiler,
    lhs: repr.Value,
    rhs: compiler_primitives.JanetSlot,
    binding_kind: BindingKind,
    attributes: ?*tables.Table,
) raise.Raising(bool) {
    switch (repr.typeOf(lhs)) {
        repr.Tag.symbol => return try bindLeaf(compiler, wrap.toSymbol(lhs), rhs, binding_kind, attributes),
        repr.Tag.tuple, repr.Tag.array => {
            const values = args_core.indexedView(lhs).?;
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
                        const extra_count = values.len - index - 1;
                        const extra = tuples.begin(@intCast(extra_count));
                        utils.tupleHead(extra).gc.flags |= constants.JANET_TUPLE_FLAG_BRACKETCTOR;
                        for (0..extra_count) |extra_index| {
                            extra[extra_index] = values[index + 1 + extra_index];
                        }
                        compiler_primitives.recordError(
                            compiler,
                            try pp_format.formatc("expected a single symbol follow '& in destructuring pattern, found %q", .{wrap.fromTuple(tuples.end(extra))}),
                        );
                        return true;
                    }
                    if (!repr.checkType(values[index + 1], repr.Tag.symbol)) {
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
        repr.Tag.table, repr.Tag.@"struct" => {
            const view = args_core.dictionaryView(lhs).?;
            for (0..view.cap) |index| {
                const pair = view.kvs.?[index];
                if (repr.checkType(pair.key, repr.Tag.nil)) continue;
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

fn compileRestDestructure(compiler: *compiler_primitives.JanetCompiler, rhs: compiler_primitives.JanetSlot, target: compiler_primitives.JanetSlot, start: i32) void {
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
    _ = emit_core.emitSlot(compiler, constants.Opcode.make_tuple, target, 1);
}

fn bindLeaf(
    compiler: *compiler_primitives.JanetCompiler,
    symbol: [*:0]const u8,
    slot: compiler_primitives.JanetSlot,
    binding_kind: BindingKind,
    attributes: ?*tables.Table,
) raise.Raising(bool) {
    return switch (binding_kind) {
        .variable => try bindVariableLeaf(compiler, symbol, slot, attributes),
        .definition => bindDefinitionLeaf(compiler, symbol, slot, attributes),
    };
}

fn nameLocal(
    compiler: *compiler_primitives.JanetCompiler,
    symbol: [*:0]const u8,
    binding_flags: compiler_primitives.SlotFlags,
    original_slot: compiler_primitives.JanetSlot,
    original_definition_flags: u32,
) raise.Raising(bool) {
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
    // union with what the slot already carries rather than a replacement.
    slot.flags.mutable = slot.flags.mutable or binding_flags.mutable;
    if (compiler.scope.?.flags.top) definition_flags |= constants.JANET_DEFFLAG_NO_UNUSED;
    try compiler_primitives.nameslot(compiler, symbol, slot, definition_flags);
    return !unnamed_register;
}

fn bindVariableLeaf(
    compiler: *compiler_primitives.JanetCompiler,
    symbol: [*:0]const u8,
    slot: compiler_primitives.JanetSlot,
    attributes: ?*tables.Table,
) raise.Raising(bool) {
    if (compiler.scope.?.flags.top) {
        const entry = tables.clone(attributes.?);
        var reference: *arrays.Array = undefined;
        if (compiler.is_redef) {
            const old_binding = registry.resolveExt(compiler.env.?, symbol);
            if (old_binding.type == constants.JANET_BINDING_VAR) {
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
    if (attributes != null and attributes.?.count != 0) {
        if (repr.truthy(tableGetKeyword(attributes.?, "unused"))) {
            definition_flags |= constants.JANET_DEFFLAG_NO_UNUSED;
        }
        if (repr.truthy(tableGetKeyword(attributes.?, "shadow"))) {
            definition_flags |= constants.JANET_DEFFLAG_NO_SHADOWCHECK;
        }
    }
    return nameLocal(compiler, symbol, .{ .mutable = true }, slot, definition_flags);
}

fn bindDefinitionLeaf(
    compiler: *compiler_primitives.JanetCompiler,
    symbol: [*:0]const u8,
    slot: compiler_primitives.JanetSlot,
    attributes: ?*tables.Table,
) raise.Raising(bool) {
    var entry: ?*tables.Table = null;
    var redef = false;
    if (compiler.scope.?.flags.top) {
        entry = tables.clone(attributes.?);
        tables.put(entry.?, value.fromBytes("source-map", .keyword), wrap.fromTuple(makeSourceMap(compiler)));
        redef = compiler.is_redef;
        if (redef) tables.put(entry.?, value.fromBytes("redef", .keyword), wrap.fromTrue());
        if (redef) {
            const binding = registry.resolveExt(compiler.env.?, symbol);
            const reference = if (binding.type == constants.JANET_BINDING_DYNAMIC_DEF or
                binding.type == constants.JANET_BINDING_DYNAMIC_MACRO)
                wrap.toArray(binding.value)
            else
                newReferenceArray();
            tables.put(entry.?, value.fromBytes("ref", .keyword), wrap.fromArray(try reference));
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
                compiler_primitives.cslot(wrap.fromTable(entry.?)),
                compiler_primitives.cslot(value.fromBytes("value", .keyword)),
                slot,
                0,
            );
        }
    }
    var definition_flags: u32 = 0;
    if (attributes != null and attributes.?.count != 0 and
        repr.truthy(tableGetKeyword(attributes.?, "unused")))
    {
        definition_flags |= constants.JANET_DEFFLAG_NO_UNUSED;
    }
    if (redef or (attributes != null and attributes.?.count != 0 and
        repr.truthy(tableGetKeyword(attributes.?, "shadow"))))
    {
        definition_flags |= constants.JANET_DEFFLAG_NO_SHADOWCHECK;
    }
    const result = try nameLocal(compiler, symbol, .{}, slot, definition_flags);
    if (entry) |e| {
        tables.put(compiler.env.?, wrap.fromSymbol(symbol), wrap.fromTable(e));
    }
    return result;
}

fn makeSourceMap(compiler: *compiler_primitives.JanetCompiler) tuples.Tuple {
    const tuple = tuples.begin(3);
    tuple[0] = if (compiler.source) |source| wrap.fromString(source) else wrap.fromNil();
    tuple[1] = wrap.fromInteger(compiler.current_mapping.line);
    tuple[2] = wrap.fromInteger(compiler.current_mapping.column);
    return tuples.end(tuple);
}

fn newReferenceArray() raise.Raising(*arrays.Array) {
    const reference = arrays.new(1);
    try arrays.push(reference, wrap.fromNil());
    return reference;
}

fn symbolEquals(val: repr.Value, string: [*:0]const u8) bool {
    return repr.checkType(val, repr.Tag.symbol) and
        utils.cstrcmp(wrap.toSymbol(val), string) == 0;
}

fn tableGetKeyword(table: *tables.Table, keyword: [*:0]const u8) repr.Value {
    return tables.get(table, value.fromBytes(std.mem.span(keyword), .keyword));
}

fn quasiquote(options: compiler_primitives.JanetFopts, val: repr.Value, depth: i32, original_level: i32) raise.Raising(compiler_primitives.JanetSlot) {
    if (depth == 0) {
        compiler_primitives.cerror(options.compiler, "quasiquote too deeply nested");
        return nilSlot();
    }
    var slots: stretchy.Vector(compiler_primitives.JanetSlot) = .empty;
    var suboptions = options;
    suboptions.flags.hint = false;
    var level = original_level;

    switch (repr.typeOf(val)) {
        repr.Tag.tuple => {
            const tuple = wrap.toTuple(val);
            const length = tuples.head(tuple).length;
            if (length > 1 and repr.checkType(tuple[0], repr.Tag.symbol)) {
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
            const opcode = if (utils.tupleHead(tuple).gc.flags & constants.JANET_TUPLE_FLAG_BRACKETCTOR != 0)
                constants.Opcode.make_bracket_tuple
            else
                constants.Opcode.make_tuple;
            return quoteSlots(options, slots, opcode);
        },
        repr.Tag.array => {
            const array = wrap.toArray(val);
            for (0..array.count) |index| {
                pushSlot(&slots, try quasiquote(suboptions, array.slice()[index], depth - 1, level));
            }
            return quoteSlots(options, slots, constants.Opcode.make_array);
        },
        repr.Tag.table, repr.Tag.@"struct" => {
            const view = args_core.dictionaryView(val).?;
            var pair = if (view.kvs) |kvs| value.dictionaryNext(kvs[0..@intCast(view.cap)], null) else null;
            while (pair != null) : (pair = value.dictionaryNext(view.kvs.?[0..@intCast(view.cap)], pair)) {
                var key = try quasiquote(suboptions, pair.?.key, depth - 1, level);
                var pair_value = try quasiquote(suboptions, pair.?.value, depth - 1, level);
                key.flags.spliced = false;
                pair_value.flags.spliced = false;
                pushSlot(&slots, key);
                pushSlot(&slots, pair_value);
            }
            return quoteSlots(
                options,
                slots,
                if (repr.checkType(val, repr.Tag.table)) constants.Opcode.make_table else constants.Opcode.make_struct,
            );
        },
        else => return compiler_primitives.cslot(val),
    }
}

fn quoteSlots(options: compiler_primitives.JanetFopts, slots: stretchy.Vector(compiler_primitives.JanetSlot), opcode: constants.Opcode) compiler_primitives.JanetSlot {
    const target = compiler_primitives.gettarget(options);
    _ = compiler_primitives.pushslots(options.compiler, slots.items);
    compiler_primitives.freeslots(options.compiler, slots);
    _ = emit_core.emitSlot(options.compiler, opcode, target, 1);
    return target;
}

fn compileSequence(
    options: compiler_primitives.JanetFopts,
    arguments: []const repr.Value,
) raise.Raising(compiler_primitives.JanetSlot) {
    const compiler: *compiler_primitives.JanetCompiler = options.compiler;
    var result = nilSlot();
    var suboptions = compiler_primitives.foptsDefault(compiler);
    var index: i32 = 0;
    while (index < @as(i32, @intCast(arguments.len))) : (index += 1) {
        if (index != @as(i32, @intCast(arguments.len)) - 1) {
            suboptions.flags = .{ .drop = true };
        } else {
            suboptions = options;
            suboptions.flags.accept_splice = false;
        }
        result = try compiler_primitives.valueImpl(suboptions, arguments[@intCast(index)]);
        if (index != @as(i32, @intCast(arguments.len)) - 1) compiler_primitives.freeslot(compiler, result);
    }
    return result;
}

fn nilSlot() compiler_primitives.JanetSlot {
    return compiler_primitives.cslot(wrap.fromNil());
}

fn emitInstruction(compiler: *compiler_primitives.JanetCompiler, instruction: u32) void {
    _ = emit_core.emit(compiler, @bitCast(instruction));
}

/// The other operand of a two-argument comparison against nil, when the form
/// is one -- `(= x nil)` and `(not= nil x)` each answer `x`.
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

fn checkJump16(compiler: *compiler_primitives.JanetCompiler, from: i32, to: i32) void {
    const distance = to - from;
    if (distance > std_max_i16 or distance < std_min_i16) {
        compiler_primitives.cerror(compiler, "bad 16-bit jump, too large");
    }
}

fn checkJump24(compiler: *compiler_primitives.JanetCompiler, from: i32, to: i32) void {
    const distance = to - from;
    if (distance > 0xffffff or distance < -0x1000000) {
        compiler_primitives.cerror(compiler, "bad 24-bit jump, too large");
    }
}

fn pushSlot(slots: *stretchy.Vector(compiler_primitives.JanetSlot), val: compiler_primitives.JanetSlot) void {
    stretchy.push(slots, val);
}

fn addFunctionDefinition(compiler: *compiler_primitives.JanetCompiler, definition: *functions.FuncDef) i32 {
    var scope = compiler.scope;
    while (scope) |current| {
        if (current.flags.function) break;
        scope = current.parent;
    }
    const function_scope = scope orelse unreachable;
    stretchy.push(&function_scope.defs, definition);
    return @intCast(function_scope.defs.items.len - 1);
}

const std_max_i16 = 0x7fff;
const std_min_i16 = -0x8000;
const std_max_i32 = 0x7fffffff;
