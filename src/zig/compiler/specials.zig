//! The thirteen special forms: `quote`, `do`, `if`, `fn`, `def`, `var`, `set`,
//! `while`, `break`, `upscope`, `splice`, `quasiquote` and `unquote`.
//!
//! `janetc_special` at the foot of this file is what `janetc_value` consults
//! before treating a tuple's head as a call. It was one line of `specials.c`
//! forwarding here until Phase 10 Part 7, which is when this file took the
//! name outright.
//!
//! Nothing here raises. Like `emit_core.zig`, the compiler front end reports
//! by flag through `janetc_error`.

const std = @import("std");
const config = @import("config");
const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");
const raise = @import("raise");
const pp_format = @import("../pp/format.zig");
const compiler_primitives = @import("../compiler.zig");
const special = @import("../special_type.zig");
const tables = @import("../value/tables.zig");
const gc_alloc = @import("../gc.zig");
const strings = @import("../value/strings.zig");
const tuples = @import("../value/tuples.zig");
const utils = @import("../utils.zig");
const vector_mod = @import("../stretchy.zig");
const regalloc = @import("regalloc.zig");
const emit_core = @import("emit.zig");
const registry = @import("../registry.zig");
const kind = @import("../value/helpers/kind.zig");
const wrap = @import("../value/helpers/wrap.zig");
const args_core = @import("../args.zig");
const arrays = @import("../value/arrays.zig");
const value = @import("../value.zig");

extern fn janet_def_addflags(definition: *types.JanetFuncDef) callconv(.c) void;
/// `janet_wrap_keyword`, and `janet_wrap_integer` written out.
///
/// Both were one-line C functions in `specials.c` until Phase 10 Part 7,
/// because this subsystem translated only `compile.h` and `emit.h`. One shared
/// set of types removes the detour; `wrapInteger` stays spelled out because
/// `janet_wrap_integer` is a macro under nanboxing and a symbol `wrap.c`
/// never defines there.
inline fn wrapKeyword(val: [*:0]const u8) types.Janet {
    return wrap.fromKeyword(val);
}

inline fn wrapInteger(val: i32) types.Janet {
    return wrap.fromNumber(@floatFromInt(val));
}

const vector_header_size = 2 * @sizeOf(i32);

fn janet_zig_special_quote(
    options: types.JanetFopts,
    argument_count: i32,
    arguments: [*]const types.Janet,
) raise.Raising(types.JanetSlot) {
    if (argument_count != 1) {
        compiler_primitives.cerror(options.compiler, "expected 1 argument to quote");
        return nilSlot();
    }
    return compiler_primitives.cslot(arguments[0]);
}

fn janet_zig_special_splice(
    options: types.JanetFopts,
    argument_count: i32,
    arguments: [*]const types.Janet,
) raise.Raising(types.JanetSlot) {
    if (options.flags & constants.JANET_FOPTS_ACCEPT_SPLICE == 0) {
        compiler_primitives.cerror(options.compiler, "splice can only be used in function parameters and data constructors, it has no effect here");
        return nilSlot();
    }
    if (argument_count != 1) {
        compiler_primitives.cerror(options.compiler, "expected 1 argument to splice");
        return nilSlot();
    }
    var result = try compiler_primitives.janetc_valueImpl(options, arguments[0]);
    result.flags |= constants.JANET_SLOT_SPLICED;
    return result;
}

fn janet_zig_special_unquote(
    options: types.JanetFopts,
    _: i32,
    _: [*]const types.Janet,
) raise.Raising(types.JanetSlot) {
    compiler_primitives.cerror(options.compiler, "cannot use unquote here");
    return nilSlot();
}

fn janet_zig_special_do(
    options: types.JanetFopts,
    argument_count: i32,
    arguments: [*]const types.Janet,
) raise.Raising(types.JanetSlot) {
    const compiler: *types.JanetCompiler = options.compiler;
    var scope: types.JanetScope = undefined;
    compiler_primitives.pushScope(&scope, compiler, 0, "do");
    const result = try compileSequence(options, argument_count, arguments);
    try compiler_primitives.janetc_popscope_keepslotImpl(compiler, result);
    return result;
}

fn janet_zig_special_upscope(
    options: types.JanetFopts,
    argument_count: i32,
    arguments: [*]const types.Janet,
) raise.Raising(types.JanetSlot) {
    return compileSequence(options, argument_count, arguments);
}

fn janet_zig_special_break(
    options: types.JanetFopts,
    argument_count: i32,
    arguments: [*]const types.Janet,
) raise.Raising(types.JanetSlot) {
    const compiler: *types.JanetCompiler = options.compiler;
    if (argument_count > 1) {
        compiler_primitives.cerror(compiler, "expected at most 1 argument");
        return nilSlot();
    }

    var scope = compiler.scope;
    while (scope) |current| : (scope = current.parent) {
        if (current.flags & (constants.JANET_SCOPE_FUNCTION | constants.JANET_SCOPE_WHILE) != 0) break;
    }
    if (scope == null) {
        compiler_primitives.cerror(compiler, "break must occur in while loop or closure");
        return nilSlot();
    }

    var suboptions = compiler_primitives.foptsDefault(compiler);
    if (scope.?.flags & constants.JANET_SCOPE_FUNCTION != 0) {
        if (scope.?.flags & constants.JANET_SCOPE_WHILE == 0 and argument_count != 0) {
            suboptions.flags |= constants.JANET_FOPTS_TAIL;
            _ = try compiler_primitives.janetc_valueImpl(suboptions, arguments[0]);
        } else {
            if (argument_count != 0) {
                suboptions.flags |= constants.JANET_FOPTS_DROP;
                _ = try compiler_primitives.janetc_valueImpl(suboptions, arguments[0]);
            }
            _ = emit_core.emit(compiler, constants.JOP_RETURN_NIL);
        }
    } else {
        if (argument_count != 0) {
            suboptions.flags |= constants.JANET_FOPTS_DROP;
            _ = try compiler_primitives.janetc_valueImpl(suboptions, arguments[0]);
        }
        _ = emit_core.emit(compiler, 0x80 | constants.JOP_JUMP);
    }
    return nilSlot();
}

fn janet_zig_special_if(
    options: types.JanetFopts,
    argument_count: i32,
    arguments: [*]const types.Janet,
) raise.Raising(types.JanetSlot) {
    const compiler: *types.JanetCompiler = options.compiler;
    if (argument_count < 2 or argument_count > 3) {
        compiler_primitives.cerror(compiler, "expected 2 or 3 arguments to if");
        return nilSlot();
    }

    var true_body = arguments[1];
    var false_body = if (argument_count > 2) arguments[2] else wrap.fromNil();
    const condition_options = compiler_primitives.foptsDefault(compiler);
    var body_options = options;
    body_options.flags &= ~@as(u32, constants.JANET_FOPTS_ACCEPT_SPLICE);
    const tail = options.flags & constants.JANET_FOPTS_TAIL != 0;
    const drop = options.flags & constants.JANET_FOPTS_DROP != 0;
    var target = if (drop or tail) nilSlot() else compiler_primitives.gettarget(options);

    var condition_scope: types.JanetScope = undefined;
    compiler_primitives.pushScope(&condition_scope, compiler, 0, "if");
    var condition_form = arguments[0];
    var jump_opcode: u8 = constants.JOP_JUMP_IF_NOT;
    if (checkNilForm(condition_form, &condition_form, constants.JANET_FUN_EQ)) {
        jump_opcode = constants.JOP_JUMP_IF_NOT_NIL;
    } else if (checkNilForm(condition_form, &condition_form, constants.JANET_FUN_NEQ)) {
        jump_opcode = constants.JOP_JUMP_IF_NIL;
    }
    const condition = try compiler_primitives.janetc_valueImpl(condition_options, condition_form);

    if (condition.flags & constants.JANET_SLOT_CONSTANT != 0) {
        const swap_condition =
            (jump_opcode == constants.JOP_JUMP_IF_NOT and kind.truthy(condition.constant) == 0) or
            (jump_opcode == constants.JOP_JUMP_IF_NIL and kind.checkType(condition.constant, constants.JANET_NIL) != 0) or
            (jump_opcode == constants.JOP_JUMP_IF_NOT_NIL and kind.checkType(condition.constant, constants.JANET_NIL) == 0);
        if (swap_condition) {
            const temporary = false_body;
            false_body = true_body;
            true_body = temporary;
        }
        var body_scope: types.JanetScope = undefined;
        compiler_primitives.pushScope(&body_scope, compiler, 0, "if-true");
        const right = try compiler_primitives.janetc_valueImpl(body_options, true_body);
        if (!drop and !tail) emit_core.copy(compiler, target, right);
        try compiler_primitives.janetc_popscopeImpl(compiler);
        if (kind.checkType(false_body, constants.JANET_NIL) == 0) {
            try compiler_primitives.janetc_throwawayImpl(body_options, false_body);
        }
        try compiler_primitives.janetc_popscopeImpl(compiler);
        return target;
    }

    const right_jump = emit_core.emitSi(compiler, jump_opcode, condition, 0, 0);
    var body_scope: types.JanetScope = undefined;
    compiler_primitives.pushScope(&body_scope, compiler, 0, "if-true");
    const left = try compiler_primitives.janetc_valueImpl(body_options, true_body);
    if (!drop and !tail) emit_core.copy(compiler, target, left);
    try compiler_primitives.janetc_popscopeImpl(compiler);

    const done_jump = vectorCount(u32, compiler.buffer);
    if (!tail and !(drop and kind.checkType(false_body, constants.JANET_NIL) != 0)) {
        _ = emit_core.emit(compiler, constants.JOP_JUMP);
    }
    const right_label = vectorCount(u32, compiler.buffer);
    compiler_primitives.pushScope(&body_scope, compiler, 0, "if-false");
    const right = try compiler_primitives.janetc_valueImpl(body_options, false_body);
    if (!drop and !tail) emit_core.copy(compiler, target, right);
    try compiler_primitives.janetc_popscopeImpl(compiler);
    try compiler_primitives.janetc_popscopeImpl(compiler);

    const done_label = vectorCount(u32, compiler.buffer);
    if (right_jump < done_label) {
        checkJump16(compiler, right_jump, right_label);
        compiler.buffer.?[@intCast(right_jump)] |= @as(u32, @intCast(right_label - right_jump)) << 16;
        if (!tail and done_jump < done_label) {
            checkJump24(compiler, done_jump, done_label);
            compiler.buffer.?[@intCast(done_jump)] |= @as(u32, @intCast(done_label - done_jump)) << 8;
        }
    }

    if (tail) target.flags |= constants.JANET_SLOT_RETURNED;
    return target;
}

fn janet_zig_special_quasiquote(
    options: types.JanetFopts,
    argument_count: i32,
    arguments: [*]const types.Janet,
) raise.Raising(types.JanetSlot) {
    if (argument_count != 1) {
        compiler_primitives.cerror(options.compiler, "expected 1 argument to quasiquote");
        return nilSlot();
    }
    return quasiquote(options, arguments[0], config.recursion_guard, 0);
}

fn janet_zig_special_while(
    options: types.JanetFopts,
    argument_count: i32,
    arguments: [*]const types.Janet,
) raise.Raising(types.JanetSlot) {
    const compiler: *types.JanetCompiler = options.compiler;
    if (argument_count < 1) {
        compiler_primitives.cerror(compiler, "expected at least 1 argument to while");
        return nilSlot();
    }

    const while_label = vectorCount(u32, compiler.buffer);
    var suboptions = compiler_primitives.foptsDefault(compiler);
    var scope: types.JanetScope = undefined;
    compiler_primitives.pushScope(&scope, compiler, constants.JANET_SCOPE_WHILE, "while");

    var condition_form = arguments[0];
    var is_nil_form = false;
    var is_not_nil_form = false;
    var true_jump: u8 = constants.JOP_JUMP_IF;
    var false_jump: u8 = constants.JOP_JUMP_IF_NOT;
    if (checkNilForm(condition_form, &condition_form, constants.JANET_FUN_EQ)) {
        is_nil_form = true;
        true_jump = constants.JOP_JUMP_IF_NIL;
        false_jump = constants.JOP_JUMP_IF_NOT_NIL;
    }
    if (checkNilForm(condition_form, &condition_form, constants.JANET_FUN_NEQ)) {
        is_not_nil_form = true;
        true_jump = constants.JOP_JUMP_IF_NOT_NIL;
        false_jump = constants.JOP_JUMP_IF_NIL;
    }

    var condition = try compiler_primitives.janetc_valueImpl(suboptions, condition_form);
    var infinite = false;
    if (condition.flags & constants.JANET_SLOT_CONSTANT != 0) {
        const never_executes = if (is_nil_form)
            kind.checkType(condition.constant, constants.JANET_NIL) == 0
        else if (is_not_nil_form)
            kind.checkType(condition.constant, constants.JANET_NIL) != 0
        else
            kind.truthy(condition.constant) == 0;
        if (never_executes) {
            try compiler_primitives.janetc_popscopeImpl(compiler);
            return nilSlot();
        }
        infinite = true;
    }

    const condition_label = if (infinite)
        0
    else
        emit_core.emitSi(compiler, false_jump, condition, 0, 0);
    var index: i32 = 1;
    while (index < argument_count) : (index += 1) {
        suboptions.flags = constants.JANET_FOPTS_DROP;
        compiler_primitives.freeslot(compiler, try compiler_primitives.janetc_valueImpl(suboptions, arguments[@intCast(index)]));
    }

    if (scope.flags & constants.JANET_SCOPE_CLOSURE != 0) {
        suboptions = compiler_primitives.foptsDefault(compiler);
        scope.flags |= constants.JANET_SCOPE_UNUSED;
        try compiler_primitives.janetc_popscopeImpl(compiler);
        if (compiler.buffer != null) setVectorCount(u32, compiler.buffer.?, while_label);
        if (compiler.mapbuffer != null) setVectorCount(types.JanetSourceMapping, compiler.mapbuffer.?, while_label);

        compiler_primitives.pushScope(&scope, compiler, constants.JANET_SCOPE_FUNCTION, "while-iife");
        condition = try compiler_primitives.janetc_valueImpl(suboptions, condition_form);
        if (condition.flags & constants.JANET_SLOT_CONSTANT == 0) {
            _ = emit_core.emitSi(compiler, true_jump, condition, 2, 0);
            _ = emit_core.emit(compiler, constants.JOP_RETURN_NIL);
        }
        index = 1;
        while (index < argument_count) : (index += 1) {
            suboptions.flags = constants.JANET_FOPTS_DROP;
            compiler_primitives.freeslot(compiler, try compiler_primitives.janetc_valueImpl(suboptions, arguments[@intCast(index)]));
        }

        const self_register = regalloc.regallocTemp(&scope.ra, constants.JANETC_REGTEMP_0);
        emitInstruction(compiler, @as(u32, constants.JOP_LOAD_SELF) | (@as(u32, @intCast(self_register)) << 8));
        emitInstruction(compiler, @as(u32, constants.JOP_TAILCALL) | (@as(u32, @intCast(self_register)) << 8));
        regalloc.regallocFreetemp(&compiler.scope.?.ra, self_register, constants.JANETC_REGTEMP_0);

        const definition = try compiler_primitives.janetc_pop_funcdefImpl(compiler);
        definition.*.name = strings.cstring("while");
        janet_def_addflags(definition);
        const definition_index = addFunctionDefinition(compiler, definition);
        const closure_register = regalloc.regallocTemp(&compiler.scope.?.ra, constants.JANETC_REGTEMP_0);
        emitInstruction(
            compiler,
            @as(u32, constants.JOP_CLOSURE) |
                (@as(u32, @intCast(closure_register)) << 8) |
                (@as(u32, @intCast(definition_index)) << 16),
        );
        emitInstruction(
            compiler,
            @as(u32, constants.JOP_CALL) |
                (@as(u32, @intCast(closure_register)) << 8) |
                (@as(u32, @intCast(closure_register)) << 16),
        );
        regalloc.regallocFreetemp(&compiler.scope.?.ra, closure_register, constants.JANETC_REGTEMP_0);
        compiler.scope.?.flags |= constants.JANET_SCOPE_CLOSURE;
        return nilSlot();
    }

    const top_jump = vectorCount(u32, compiler.buffer);
    _ = emit_core.emit(compiler, constants.JOP_JUMP);
    const done_label = vectorCount(u32, compiler.buffer);
    if (!infinite) {
        checkJump16(compiler, condition_label, done_label);
        compiler.buffer.?[@intCast(condition_label)] |= @as(u32, @intCast(done_label - condition_label)) << 16;
    }
    checkJump24(compiler, top_jump, while_label);
    compiler.buffer.?[@intCast(top_jump)] |= @as(u32, @bitCast(while_label - top_jump)) << 8;

    index = while_label;
    while (index < done_label) : (index += 1) {
        if (compiler.buffer.?[@intCast(index)] == 0x80 | constants.JOP_JUMP) {
            checkJump24(compiler, index, done_label);
            compiler.buffer.?[@intCast(index)] = @as(u32, constants.JOP_JUMP) |
                (@as(u32, @intCast(done_label - index)) << 8);
        }
    }
    try compiler_primitives.janetc_popscopeImpl(compiler);
    return nilSlot();
}

fn janet_zig_special_set(
    options: types.JanetFopts,
    argument_count: i32,
    arguments: [*]const types.Janet,
) raise.Raising(types.JanetSlot) {
    const compiler: *types.JanetCompiler = options.compiler;
    if (argument_count != 2) {
        compiler_primitives.cerror(compiler, "expected 2 arguments to set");
        return nilSlot();
    }
    const suboptions = compiler_primitives.foptsDefault(compiler);

    if (kind.checkType(arguments[0], constants.JANET_SYMBOL) != 0) {
        const destination = try compiler_primitives.janetc_resolveImpl(compiler, wrap.toSymbol(arguments[0]));
        if (destination.flags & constants.JANET_SLOT_MUTABLE == 0) {
            compiler_primitives.cerror(compiler, "cannot set constant");
            return nilSlot();
        }
        var value_options = suboptions;
        value_options.flags = constants.JANET_FOPTS_HINT;
        value_options.hint = destination;
        const result = try compiler_primitives.janetc_valueImpl(value_options, arguments[1]);
        emit_core.copy(compiler, destination, result);
        return result;
    }

    if (kind.checkType(arguments[0], constants.JANET_TUPLE) != 0) {
        const tuple = wrap.toTuple(arguments[0]);
        if (types.tupleHead(tuple).length != 2) {
            compiler_primitives.cerror(compiler, "expected 2 element tuple for l-value to set");
            return nilSlot();
        }
        const data_structure = try compiler_primitives.janetc_valueImpl(suboptions, tuple[0]);
        const key = try compiler_primitives.janetc_valueImpl(suboptions, tuple[1]);
        var value_options = options;
        value_options.flags &= ~@as(u32, constants.JANET_FOPTS_TAIL | constants.JANET_FOPTS_DROP);
        const result = try compiler_primitives.janetc_valueImpl(value_options, arguments[1]);
        _ = emit_core.emitSss(compiler, constants.JOP_PUT, data_structure, key, result, 0);
        return result;
    }

    compiler_primitives.cerror(compiler, "expected symbol or tuple for l-value to set");
    return nilSlot();
}

fn janet_zig_special_var(
    options: types.JanetFopts,
    argument_count: i32,
    arguments: [*]const types.Janet,
) raise.Raising(types.JanetSlot) {
    return try compileBinding(options, argument_count, arguments, .variable);
}

fn janet_zig_special_def(
    options: types.JanetFopts,
    argument_count: i32,
    arguments: [*]const types.Janet,
) raise.Raising(types.JanetSlot) {
    return try compileBinding(options, argument_count, arguments, .definition);
}

fn janet_zig_special_fn(
    options: types.JanetFopts,
    argument_count: i32,
    arguments: [*]const types.Janet,
) raise.Raising(types.JanetSlot) {
    const compiler: *types.JanetCompiler = options.compiler;
    compiler.scope.?.flags |= constants.JANET_SCOPE_CLOSURE;
    var function_scope: types.JanetScope = undefined;
    compiler_primitives.pushScope(&function_scope, compiler, constants.JANET_SCOPE_FUNCTION, "function");

    if (argument_count == 0) {
        return functionError(compiler, "expected at least 1 argument to function literal");
    }

    var parameter_index: i32 = 0;
    const head = arguments[0];
    const self_reference = kind.checkType(head, constants.JANET_SYMBOL) != 0;
    const has_name = self_reference or kind.checkType(head, constants.JANET_KEYWORD) != 0;
    if (has_name) parameter_index = 1;
    if (parameter_index >= argument_count or
        kind.checkType(arguments[@intCast(parameter_index)], constants.JANET_TUPLE) == 0)
    {
        return functionError(compiler, "expected function parameters");
    }

    const parameters = wrap.toTuple(arguments[@intCast(parameter_index)]);
    const parameter_count = types.tupleHead(parameters).length;
    var destructured_parameters: ?[*]types.JanetSlot = null;
    var named_parameters: ?[*]types.JanetSlot = null;
    var named_table: ?*types.JanetTable = null;
    var named_slot: types.JanetSlot = undefined;
    var arity = parameter_count;
    var minimum_arity: i32 = 0;
    var vararg = false;
    var structarg = false;
    var allow_extra = false;
    var seen_amp = false;
    var seen_optional = false;
    var named_arguments = false;

    var index: i32 = 0;
    while (index < parameter_count) : (index += 1) {
        const parameter = parameters[@intCast(index)];
        if (named_arguments) {
            arity -= 1;
            if (kind.checkType(parameter, constants.JANET_SYMBOL) == 0) {
                freeVector(types.JanetSlot, destructured_parameters);
                freeVector(types.JanetSlot, named_parameters);
                return functionError(compiler, "only named arguments can follow &named");
            }
            tables.put(
                named_table.?,
                wrapKeyword(wrap.toSymbol(parameter)),
                parameter,
            );
            pushSlot(&named_parameters, compiler_primitives.farslot(compiler));
            continue;
        }

        if (kind.checkType(parameter, constants.JANET_SYMBOL) == 0) {
            pushSlot(&destructured_parameters, compiler_primitives.farslot(compiler));
            continue;
        }

        const symbol = wrap.toSymbol(parameter);
        if (symbol[0] != '&') {
            try compiler_primitives.janetc_nameslotImpl(compiler, symbol, compiler_primitives.farslot(compiler), 0);
            continue;
        }

        if (utils.cstrcmp(symbol, "&") == 0) {
            if (seen_amp) {
                return cleanupFunctionError(compiler, destructured_parameters.?, named_parameters.?, "& in unexpected location");
            } else if (index == parameter_count - 1) {
                allow_extra = true;
                arity -= 1;
            } else if (index == parameter_count - 2) {
                vararg = true;
                arity -= 2;
            } else {
                return cleanupFunctionError(compiler, destructured_parameters.?, named_parameters.?, "& in unexpected location");
            }
            seen_amp = true;
        } else if (utils.cstrcmp(symbol, "&opt") == 0) {
            if (seen_optional) {
                return cleanupFunctionError(compiler, destructured_parameters.?, named_parameters.?, "only one &opt allowed");
            } else if (index == parameter_count - 1) {
                return cleanupFunctionError(compiler, destructured_parameters.?, named_parameters.?, "&opt cannot be last item in parameter list");
            }
            minimum_arity = index;
            arity -= 1;
            seen_optional = true;
        } else if (utils.cstrcmp(symbol, "&keys") == 0) {
            if (seen_amp or index != parameter_count - 2) {
                return cleanupFunctionError(compiler, destructured_parameters.?, named_parameters.?, "&keys in unexpected location");
            }
            vararg = true;
            structarg = true;
            arity -= 2;
            seen_amp = true;
        } else if (utils.cstrcmp(symbol, "&named") == 0) {
            if (seen_amp) {
                return cleanupFunctionError(compiler, destructured_parameters.?, named_parameters.?, "&named in unexpected location");
            }
            vararg = true;
            structarg = true;
            arity -= 1;
            seen_amp = true;
            named_arguments = true;
            named_table = tables.new(10);
            named_slot = compiler_primitives.farslot(compiler);
        } else {
            try compiler_primitives.janetc_nameslotImpl(compiler, symbol, compiler_primitives.farslot(compiler), 0);
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
        freeVector(types.JanetSlot, named_parameters);
        named_parameters = null;
    }

    var destructured_index: i32 = 0;
    index = 0;
    while (index < parameter_count) : (index += 1) {
        const parameter = parameters[@intCast(index)];
        if (kind.checkType(parameter, constants.JANET_SYMBOL) != 0) continue;
        if (destructured_index >= vectorCount(types.JanetSlot, destructured_parameters)) unreachable;
        const parameter_slot = destructured_parameters.?[@intCast(destructured_index)];
        destructured_index += 1;
        _ = try destructure(compiler, parameter, parameter_slot, .definition, null);
        compiler_primitives.freeslot(compiler, parameter_slot);
    }
    freeVector(types.JanetSlot, destructured_parameters);
    destructured_parameters = null;

    const maximum_arity: i32 = if (vararg or allow_extra) std_max_i32 else arity;
    if (!seen_optional) minimum_arity = arity;

    if (self_reference) {
        const symbol = wrap.toSymbol(head);
        var found = false;
        index = 0;
        while (index < vectorCount(types.SymPair, compiler.scope.?.syms)) : (index += 1) {
            if (compiler.scope.?.syms.?[@intCast(index)].sym == symbol) found = true;
        }
        if (!found) {
            var slot = compiler_primitives.farslot(compiler);
            slot.flags = @as(u32, constants.JANET_SLOT_NAMED) | @as(u32, constants.JANET_FUNCTION);
            _ = emit_core.emitSlot(compiler, constants.JOP_LOAD_SELF, slot, 1);
            try compiler_primitives.janetc_nameslotImpl(
                compiler,
                symbol,
                slot,
                constants.JANET_DEFFLAG_NO_UNUSED | constants.JANET_DEFFLAG_NO_SHADOWCHECK,
            );
        }
    }

    var suboptions = compiler_primitives.foptsDefault(compiler);
    if (parameter_index + 1 == argument_count) {
        _ = emit_core.emit(compiler, constants.JOP_RETURN_NIL);
    } else {
        var argument_index = parameter_index + 1;
        while (argument_index < argument_count) : (argument_index += 1) {
            suboptions.flags = if (argument_index == argument_count - 1) constants.JANET_FOPTS_TAIL else constants.JANET_FOPTS_DROP;
            _ = try compiler_primitives.janetc_valueImpl(suboptions, arguments[@intCast(argument_index)]);
            if (compiler.result.status == constants.JANET_COMPILE_ERROR) {
                try compiler_primitives.janetc_popscopeImpl(compiler);
                return nilSlot();
            }
        }
    }

    const definition = try compiler_primitives.janetc_pop_funcdefImpl(compiler);
    definition.*.arity = arity;
    definition.*.min_arity = minimum_arity;
    definition.*.max_arity = maximum_arity;
    if (named_table != null) definition.*.named_args_count = named_table.?.*.count;
    if (vararg) definition.*.flags |= constants.JANET_FUNCDEF_FLAG_VARARG;
    if (structarg) definition.*.flags |= constants.JANET_FUNCDEF_FLAG_STRUCTARG;
    if (named_arguments) definition.*.flags |= constants.JANET_FUNCDEF_FLAG_NAMEDARGS;
    if (has_name) definition.*.name = wrap.toSymbol(head);
    janet_def_addflags(definition);
    const definition_index = addFunctionDefinition(compiler, definition);
    const vararg_slot: i32 = if (vararg) 1 else 0;
    if (arity + vararg_slot > definition.*.slotcount) definition.*.slotcount = arity + vararg_slot;

    const result = compiler_primitives.gettarget(options);
    _ = emit_core.emitSu(compiler, constants.JOP_CLOSURE, result, @intCast(definition_index), 1);
    return result;
}

const specials = [_]special.Special{
    .{ .name = "break", .compile = janet_zig_special_break },
    .{ .name = "def", .compile = janet_zig_special_def },
    .{ .name = "do", .compile = janet_zig_special_do },
    .{ .name = "fn", .compile = janet_zig_special_fn },
    .{ .name = "if", .compile = janet_zig_special_if },
    .{ .name = "quasiquote", .compile = janet_zig_special_quasiquote },
    .{ .name = "quote", .compile = janet_zig_special_quote },
    .{ .name = "set", .compile = janet_zig_special_set },
    .{ .name = "splice", .compile = janet_zig_special_splice },
    .{ .name = "unquote", .compile = janet_zig_special_unquote },
    .{ .name = "upscope", .compile = janet_zig_special_upscope },
    .{ .name = "var", .compile = janet_zig_special_var },
    .{ .name = "while", .compile = janet_zig_special_while },
};

/// `janetc_special`: the special form named, or null.
///
/// The table above is in lexicographic order and this is a binary search over
/// it, exactly as the C original was. Until Phase 10 Part 7 the export was
/// called `janet_zig_special_lookup` and `specials.c` held a one-line
/// `janetc_special` that forwarded to it; there was never a reason for the
/// indirection beyond the increment that introduced it not yet owning the
/// name.
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

pub fn lookupSpecial(name: [*:0]const u8) ?*const types.JanetSpecial {
    return if (lookup(name)) |s| special.stored(s) else null;
}

fn functionError(compiler: *types.JanetCompiler, message: [*:0]const u8) raise.Raising(types.JanetSlot) {
    compiler_primitives.cerror(compiler, message);
    try compiler_primitives.janetc_popscopeImpl(compiler);
    return nilSlot();
}

fn cleanupFunctionError(
    compiler: *types.JanetCompiler,
    destructured_parameters: [*]types.JanetSlot,
    named_parameters: [*]types.JanetSlot,
    message: [*:0]const u8,
) raise.Raising(types.JanetSlot) {
    freeVector(types.JanetSlot, destructured_parameters);
    freeVector(types.JanetSlot, named_parameters);
    return functionError(compiler, message);
}

const BindingKind = enum { variable, definition };

const SlotHeadPair = extern struct {
    lhs: types.Janet,
    rhs: types.JanetSlot,
};

fn compileBinding(
    original_options: types.JanetFopts,
    argument_count: i32,
    arguments: [*]const types.Janet,
    binding_kind: BindingKind,
) raise.Raising(types.JanetSlot) {
    const compiler: *types.JanetCompiler = original_options.compiler;
    const attributes = handleAttributes(
        compiler,
        if (binding_kind == .variable) "var" else "def",
        argument_count,
        arguments,
    );
    if (compiler.result.status == constants.JANET_COMPILE_ERROR) return nilSlot();
    try checkMetadataLint(compiler, attributes);

    var options = original_options;
    if (binding_kind == .definition) options.flags &= ~@as(u32, constants.JANET_FOPTS_HINT);
    var pairs: ?[*]SlotHeadPair = null;
    try buildDestructureHeads(&pairs, options, arguments[0], arguments[@intCast(argument_count - 1)]);
    if (compiler.result.status == constants.JANET_COMPILE_ERROR) {
        freeVector(SlotHeadPair, pairs);
        return nilSlot();
    }

    const count = vectorCount(SlotHeadPair, pairs);
    if (count == 0) unreachable;
    var result = nilSlot();
    var index: i32 = 0;
    while (index < count) : (index += 1) {
        const pair = pairs.?[@intCast(index)];
        _ = try destructure(compiler, pair.lhs, pair.rhs, binding_kind, attributes);
        result = pair.rhs;
    }
    freeVector(SlotHeadPair, pairs);
    return result;
}

fn handleAttributes(
    compiler: *types.JanetCompiler,
    binding_kind: [*:0]const u8,
    argument_count: i32,
    arguments: [*]const types.Janet,
) ?*types.JanetTable {
    if (argument_count < 2) {
        compiler_primitives.recordError(compiler, pp_format.formatcReported("expected at least 2 arguments to %s", .{binding_kind}));
        return null;
    }
    const table = tables.new(2);
    const binding_name: [*:0]const u8 = if (kind.typeOf(arguments[0]) == constants.JANET_SYMBOL)
        @ptrCast(wrap.toSymbol(arguments[0]))
    else
        "<multiple bindings>";
    var index: i32 = 1;
    while (index < argument_count - 1) : (index += 1) {
        const attribute = arguments[@intCast(index)];
        switch (kind.typeOf(attribute)) {
            constants.JANET_TUPLE => compiler_primitives.cerror(compiler, "unexpected form - did you intend to use defn?"),
            constants.JANET_KEYWORD => tables.put(table, attribute, wrap.fromTrue()),
            constants.JANET_STRING => tables.put(table, value.fromBytes("doc", .keyword), attribute),
            constants.JANET_STRUCT => tables.mergeStruct(table, wrap.toStruct(attribute)),
            else => compiler_primitives.recordError(
                compiler,
                pp_format.formatcReported("cannot add metadata %v to binding %s", .{ attribute, binding_name }),
            ),
        }
    }
    return table;
}

fn checkMetadataLint(compiler: *types.JanetCompiler, attributes: ?*types.JanetTable) raise.Raising(void) {
    if (compiler.scope.?.flags & constants.JANET_SCOPE_TOP != 0 or attributes == null or attributes.?.*.count == 0) return;
    if (kind.truthy(tableGetKeyword(attributes.?, "macro")) != 0) {
        try compiler_primitives.janetc_lintImpl(compiler, constants.JANET_C_LINT_NORMAL, "macro tag is ignored in inner scopes");
    }
}

fn buildDestructureHeads(
    pairs: *?[*]SlotHeadPair,
    options: types.JanetFopts,
    lhs: types.Janet,
    rhs: types.Janet,
) raise.Raising(void) {
    const compiler: *types.JanetCompiler = options.compiler;
    const lhs_indexed = kind.checkType(lhs, constants.JANET_TUPLE) != 0 or
        kind.checkType(lhs, constants.JANET_ARRAY) != 0;
    const rhs_indexed = kind.checkType(rhs, constants.JANET_ARRAY) != 0 or
        (kind.checkType(rhs, constants.JANET_TUPLE) != 0 and
            utils.tupleHead(wrap.toTuple(rhs)).*.gc.flags & constants.JANET_TUPLE_FLAG_BRACKETCTOR != 0);
    const has_drop = options.flags & constants.JANET_FOPTS_DROP != 0;
    var suboptions = compiler_primitives.foptsDefault(compiler);
    suboptions.flags = options.flags & ~@as(u32, constants.JANET_FOPTS_TAIL | constants.JANET_FOPTS_DROP);

    if (has_drop and lhs_indexed and rhs_indexed) {
        var lhs_items: ?[*]const types.Janet = null;
        var lhs_length: i32 = 0;
        var rhs_items: ?[*]const types.Janet = null;
        var rhs_length: i32 = 0;
        _ = args_core.indexedView(lhs, &lhs_items, &lhs_length);
        _ = args_core.indexedView(rhs, &rhs_items, &rhs_length);
        var found_amp = false;
        var found_splice = false;
        var index: i32 = 0;
        while (index < rhs_length) : (index += 1) {
            const item = rhs_items.?[@intCast(index)];
            if (kind.checkType(item, constants.JANET_TUPLE) == 0) continue;
            const tuple = wrap.toTuple(item);
            if (types.tupleHead(tuple).length != 0 and symbolEquals(tuple[0], "splice")) {
                found_splice = true;
                break;
            }
        }
        index = 0;
        while (index < lhs_length) : (index += 1) {
            if (symbolEquals(lhs_items.?[@intCast(index)], "&")) {
                found_amp = true;
                break;
            }
        }
        if (!found_amp and !found_splice) {
            index = 0;
            while (index < lhs_length) : (index += 1) {
                const sub_rhs = if (index < rhs_length) rhs_items.?[@intCast(index)] else wrap.fromNil();
                try buildDestructureHeads(pairs, suboptions, lhs_items.?[@intCast(index)], sub_rhs);
            }
            return;
        }
    }

    suboptions.hint = options.hint;
    pushVector(SlotHeadPair, pairs, .{ .lhs = lhs, .rhs = try compiler_primitives.janetc_valueImpl(suboptions, rhs) });
}

fn destructure(
    compiler: *types.JanetCompiler,
    lhs: types.Janet,
    rhs: types.JanetSlot,
    binding_kind: BindingKind,
    attributes: ?*types.JanetTable,
) raise.Raising(bool) {
    switch (kind.typeOf(lhs)) {
        constants.JANET_SYMBOL => return try bindLeaf(compiler, wrap.toSymbol(lhs), rhs, binding_kind, attributes),
        constants.JANET_TUPLE, constants.JANET_ARRAY => {
            var values: ?[*]const types.Janet = null;
            var length: i32 = 0;
            _ = args_core.indexedView(lhs, &values, &length);
            var index: i32 = 0;
            while (index < length) : (index += 1) {
                const next_rhs = compiler_primitives.farslot(compiler);
                const subvalue = values.?[@intCast(index)];
                if (symbolEquals(subvalue, "&")) {
                    if (index + 1 >= length) {
                        compiler_primitives.cerror(compiler, "expected symbol following '& in destructuring pattern");
                        return true;
                    }
                    if (index + 2 < length) {
                        const extra_count = length - index - 1;
                        const extra = tuples.begin(extra_count);
                        utils.tupleHead(extra).*.gc.flags |= constants.JANET_TUPLE_FLAG_BRACKETCTOR;
                        var extra_index: i32 = 0;
                        while (extra_index < extra_count) : (extra_index += 1) {
                            extra[@intCast(extra_index)] = values.?[@intCast(index + 1 + extra_index)];
                        }
                        compiler_primitives.recordError(
                            compiler,
                            try pp_format.formatc("expected a single symbol follow '& in destructuring pattern, found %q", .{wrap.fromTuple(tuples.end(extra))}),
                        );
                        return true;
                    }
                    if (kind.checkType(values.?[@intCast(index + 1)], constants.JANET_SYMBOL) == 0) {
                        compiler_primitives.recordError(
                            compiler,
                            try pp_format.formatc("expected symbol following '& in destructuring pattern, found %q", .{values.?[@intCast(index + 1)]}),
                        );
                        return true;
                    }
                    compileRestDestructure(compiler, rhs, next_rhs, index);
                    _ = try bindLeaf(
                        compiler,
                        wrap.toSymbol(values.?[@intCast(index + 1)]),
                        next_rhs,
                        binding_kind,
                        attributes,
                    );
                    compiler_primitives.freeslot(compiler, next_rhs);
                    break;
                }

                if (index < 0x100) {
                    _ = emit_core.emitSsu(compiler, constants.JOP_GET_INDEX, next_rhs, rhs, @intCast(index), 1);
                } else {
                    const key = compiler_primitives.cslot(wrapInteger(index));
                    _ = emit_core.emitSss(compiler, constants.JOP_IN, next_rhs, rhs, key, 1);
                }
                if (try destructure(compiler, subvalue, next_rhs, binding_kind, attributes)) {
                    compiler_primitives.freeslot(compiler, next_rhs);
                }
            }
            return true;
        },
        constants.JANET_TABLE, constants.JANET_STRUCT => {
            var key_values: ?[*]const types.JanetKV = null;
            var length: i32 = 0;
            var capacity: i32 = 0;
            _ = args_core.dictionaryView(lhs, &key_values, &length, &capacity);
            var index: i32 = 0;
            while (index < capacity) : (index += 1) {
                const pair = key_values.?[@intCast(index)];
                if (kind.checkType(pair.key, constants.JANET_NIL) != 0) continue;
                const next_rhs = compiler_primitives.farslot(compiler);
                const key = try compiler_primitives.janetc_valueImpl(compiler_primitives.foptsDefault(compiler), pair.key);
                _ = emit_core.emitSss(compiler, constants.JOP_IN, next_rhs, rhs, key, 1);
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

fn compileRestDestructure(compiler: *types.JanetCompiler, rhs: types.JanetSlot, target: types.JanetSlot, start: i32) void {
    const argument_index = compiler_primitives.farslot(compiler);
    const argument = compiler_primitives.farslot(compiler);
    const length = compiler_primitives.farslot(compiler);
    _ = emit_core.emitSi(compiler, constants.JOP_LOAD_INTEGER, argument_index, @truncate(start), 0);
    _ = emit_core.emitSs(compiler, constants.JOP_LENGTH, length, rhs, 0);
    const loop_start = emit_core.emitSss(compiler, constants.JOP_LESS_THAN, argument, argument_index, length, 0);
    const condition_jump = emit_core.emitSi(compiler, constants.JOP_JUMP_IF_NOT, argument, 0, 0);
    _ = emit_core.emitSss(compiler, constants.JOP_GET, argument, rhs, argument_index, 0);
    _ = emit_core.emitSlot(compiler, constants.JOP_PUSH, argument, 0);
    _ = emit_core.emitSsi(compiler, constants.JOP_ADD_IMMEDIATE, argument_index, argument_index, 1, 0);
    const loop_jump = vectorCount(u32, compiler.buffer);
    _ = emit_core.emit(compiler, constants.JOP_JUMP);
    const exit_label = vectorCount(u32, compiler.buffer);
    checkJump16(compiler, condition_jump, exit_label);
    checkJump24(compiler, loop_start, loop_jump);
    compiler.buffer.?[@intCast(condition_jump)] |= @as(u32, @intCast(exit_label - condition_jump)) << 16;
    compiler.buffer.?[@intCast(loop_jump)] |= @as(u32, @bitCast(loop_start - loop_jump)) << 8;
    compiler_primitives.freeslot(compiler, argument_index);
    compiler_primitives.freeslot(compiler, argument);
    compiler_primitives.freeslot(compiler, length);
    _ = emit_core.emitSlot(compiler, constants.JOP_MAKE_TUPLE, target, 1);
}

fn bindLeaf(
    compiler: *types.JanetCompiler,
    symbol: [*:0]const u8,
    slot: types.JanetSlot,
    binding_kind: BindingKind,
    attributes: ?*types.JanetTable,
) raise.Raising(bool) {
    return switch (binding_kind) {
        .variable => try bindVariableLeaf(compiler, symbol, slot, attributes),
        .definition => bindDefinitionLeaf(compiler, symbol, slot, attributes),
    };
}

fn nameLocal(
    compiler: *types.JanetCompiler,
    symbol: [*:0]const u8,
    binding_flags: u32,
    original_slot: types.JanetSlot,
    original_definition_flags: u32,
) raise.Raising(bool) {
    var slot = original_slot;
    var definition_flags = original_definition_flags;
    var unnamed_register = slot.flags & constants.JANET_SLOT_NAMED == 0 and slot.index > 0 and slot.envindex >= 0;
    const can_alias = binding_flags & constants.JANET_SLOT_MUTABLE == 0 and
        slot.flags & constants.JANET_SLOT_MUTABLE == 0 and
        slot.flags & constants.JANET_SLOT_NAMED != 0 and
        slot.index >= 0 and slot.envindex == -1;
    if (can_alias) {
        slot.flags &= ~@as(u32, constants.JANET_SLOT_MUTABLE);
        unnamed_register = true;
    } else if (!unnamed_register) {
        const local_slot = compiler_primitives.farslot(compiler);
        emit_core.copy(compiler, local_slot, slot);
        slot = local_slot;
    }
    slot.flags |= binding_flags;
    if (compiler.scope.?.flags & constants.JANET_SCOPE_TOP != 0) definition_flags |= constants.JANET_DEFFLAG_NO_UNUSED;
    try compiler_primitives.janetc_nameslotImpl(compiler, symbol, slot, definition_flags);
    return !unnamed_register;
}

fn bindVariableLeaf(
    compiler: *types.JanetCompiler,
    symbol: [*:0]const u8,
    slot: types.JanetSlot,
    attributes: ?*types.JanetTable,
) raise.Raising(bool) {
    if (compiler.scope.?.flags & constants.JANET_SCOPE_TOP != 0) {
        const entry = tables.clone(attributes.?);
        var reference: *types.JanetArray = undefined;
        if (compiler.is_redef != 0) {
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
            constants.JOP_PUT_INDEX,
            compiler_primitives.cslot(wrap.fromArray(reference)),
            slot,
            0,
            0,
        );
        return true;
    }
    var definition_flags: u32 = 0;
    if (attributes != null and attributes.?.*.count != 0) {
        if (kind.truthy(tableGetKeyword(attributes.?, "unused")) != 0) {
            definition_flags |= constants.JANET_DEFFLAG_NO_UNUSED;
        }
        if (kind.truthy(tableGetKeyword(attributes.?, "shadow")) != 0) {
            definition_flags |= constants.JANET_DEFFLAG_NO_SHADOWCHECK;
        }
    }
    return nameLocal(compiler, symbol, constants.JANET_SLOT_MUTABLE, slot, definition_flags);
}

fn bindDefinitionLeaf(
    compiler: *types.JanetCompiler,
    symbol: [*:0]const u8,
    slot: types.JanetSlot,
    attributes: ?*types.JanetTable,
) raise.Raising(bool) {
    var entry: ?*types.JanetTable = null;
    var redef = false;
    if (compiler.scope.?.flags & constants.JANET_SCOPE_TOP != 0) {
        entry = tables.clone(attributes.?);
        tables.put(entry.?, value.fromBytes("source-map", .keyword), wrap.fromTuple(makeSourceMap(compiler)));
        redef = compiler.is_redef != 0;
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
                constants.JOP_PUT_INDEX,
                compiler_primitives.cslot(wrap.fromArray(try reference)),
                slot,
                0,
                0,
            );
        } else {
            _ = emit_core.emitSss(
                compiler,
                constants.JOP_PUT,
                compiler_primitives.cslot(wrap.fromTable(entry.?)),
                compiler_primitives.cslot(value.fromBytes("value", .keyword)),
                slot,
                0,
            );
        }
    }
    var definition_flags: u32 = 0;
    if (attributes != null and attributes.?.*.count != 0 and
        kind.truthy(tableGetKeyword(attributes.?, "unused")) != 0)
    {
        definition_flags |= constants.JANET_DEFFLAG_NO_UNUSED;
    }
    if (redef or (attributes != null and attributes.?.*.count != 0 and
        kind.truthy(tableGetKeyword(attributes.?, "shadow")) != 0))
    {
        definition_flags |= constants.JANET_DEFFLAG_NO_SHADOWCHECK;
    }
    const result = try nameLocal(compiler, symbol, 0, slot, definition_flags);
    if (entry) |e| {
        tables.put(compiler.env.?, wrap.fromSymbol(symbol), wrap.fromTable(e));
    }
    return result;
}

fn makeSourceMap(compiler: *types.JanetCompiler) types.JanetTuple {
    const tuple = tuples.begin(3);
    tuple[0] = if (compiler.source) |source| wrap.fromString(source) else wrap.fromNil();
    tuple[1] = wrapInteger(compiler.current_mapping.line);
    tuple[2] = wrapInteger(compiler.current_mapping.column);
    return tuples.end(tuple);
}

fn newReferenceArray() raise.Raising(*types.JanetArray) {
    const reference = arrays.new(1);
    try arrays.push(reference, wrap.fromNil());
    return reference;
}

fn symbolEquals(val: types.Janet, string: [*:0]const u8) bool {
    return kind.checkType(val, constants.JANET_SYMBOL) != 0 and
        utils.cstrcmp(wrap.toSymbol(val), string) == 0;
}

fn tableGetKeyword(table: *types.JanetTable, keyword: [*:0]const u8) types.Janet {
    return tables.get(table, value.fromBytes(std.mem.span(keyword), .keyword));
}

fn quasiquote(options: types.JanetFopts, val: types.Janet, depth: i32, original_level: i32) raise.Raising(types.JanetSlot) {
    if (depth == 0) {
        compiler_primitives.cerror(options.compiler, "quasiquote too deeply nested");
        return nilSlot();
    }
    var slots: ?[*]types.JanetSlot = null;
    var suboptions = options;
    suboptions.flags &= ~@as(u32, constants.JANET_FOPTS_HINT);
    var level = original_level;

    switch (kind.typeOf(val)) {
        constants.JANET_TUPLE => {
            const tuple = wrap.toTuple(val);
            const length = types.tupleHead(tuple).length;
            if (length > 1 and kind.checkType(tuple[0], constants.JANET_SYMBOL) != 0) {
                const head = wrap.toSymbol(tuple[0]);
                if (utils.cstrcmp(head, "unquote") == 0) {
                    if (level == 0) {
                        var unquote_options = compiler_primitives.foptsDefault(options.compiler);
                        unquote_options.flags |= constants.JANET_FOPTS_ACCEPT_SPLICE;
                        return try compiler_primitives.janetc_valueImpl(unquote_options, tuple[1]);
                    }
                    level -= 1;
                } else if (utils.cstrcmp(head, "quasiquote") == 0) {
                    level += 1;
                }
            }
            var index: i32 = 0;
            while (index < length) : (index += 1) {
                pushSlot(&slots, try quasiquote(suboptions, tuple[@intCast(index)], depth - 1, level));
            }
            const opcode = if (utils.tupleHead(tuple).*.gc.flags & constants.JANET_TUPLE_FLAG_BRACKETCTOR != 0)
                constants.JOP_MAKE_BRACKET_TUPLE
            else
                constants.JOP_MAKE_TUPLE;
            return quoteSlots(options, slots, opcode);
        },
        constants.JANET_ARRAY => {
            const array = wrap.toArray(val);
            var index: i32 = 0;
            while (index < array.*.count) : (index += 1) {
                pushSlot(&slots, try quasiquote(suboptions, array.*.data.?[@intCast(index)], depth - 1, level));
            }
            return quoteSlots(options, slots, constants.JOP_MAKE_ARRAY);
        },
        constants.JANET_TABLE, constants.JANET_STRUCT => {
            var key_values: ?[*]const types.JanetKV = null;
            var length: i32 = 0;
            var capacity: i32 = 0;
            _ = args_core.dictionaryView(val, &key_values, &length, &capacity);
            var pair = if (key_values) |kvs| value.dictionaryNext(kvs, capacity, null) else null;
            while (pair != null) : (pair = value.dictionaryNext(key_values.?, capacity, pair)) {
                var key = try quasiquote(suboptions, pair.?.key, depth - 1, level);
                var pair_value = try quasiquote(suboptions, pair.?.value, depth - 1, level);
                key.flags &= ~@as(u32, constants.JANET_SLOT_SPLICED);
                pair_value.flags &= ~@as(u32, constants.JANET_SLOT_SPLICED);
                pushSlot(&slots, key);
                pushSlot(&slots, pair_value);
            }
            return quoteSlots(
                options,
                slots,
                if (kind.checkType(val, constants.JANET_TABLE) != 0) constants.JOP_MAKE_TABLE else constants.JOP_MAKE_STRUCT,
            );
        },
        else => return compiler_primitives.cslot(val),
    }
}

fn quoteSlots(options: types.JanetFopts, slots: ?[*]types.JanetSlot, opcode: c_int) types.JanetSlot {
    const target = compiler_primitives.gettarget(options);
    _ = compiler_primitives.pushslots(options.compiler, slots);
    compiler_primitives.freeslots(options.compiler, slots);
    _ = emit_core.emitSlot(options.compiler, @intCast(opcode), target, 1);
    return target;
}

fn compileSequence(
    options: types.JanetFopts,
    argument_count: i32,
    arguments: [*]const types.Janet,
) raise.Raising(types.JanetSlot) {
    const compiler: *types.JanetCompiler = options.compiler;
    var result = nilSlot();
    var suboptions = compiler_primitives.foptsDefault(compiler);
    var index: i32 = 0;
    while (index < argument_count) : (index += 1) {
        if (index != argument_count - 1) {
            suboptions.flags = constants.JANET_FOPTS_DROP;
        } else {
            suboptions = options;
            suboptions.flags &= ~@as(u32, constants.JANET_FOPTS_ACCEPT_SPLICE);
        }
        result = try compiler_primitives.janetc_valueImpl(suboptions, arguments[@intCast(index)]);
        if (index != argument_count - 1) compiler_primitives.freeslot(compiler, result);
    }
    return result;
}

fn nilSlot() types.JanetSlot {
    return compiler_primitives.cslot(wrap.fromNil());
}

fn emitInstruction(compiler: *types.JanetCompiler, instruction: u32) void {
    _ = emit_core.emit(compiler, @bitCast(instruction));
}

fn checkNilForm(val: types.Janet, capture: *types.Janet, function_tag: u32) bool {
    if (kind.checkType(val, constants.JANET_TUPLE) == 0) return false;
    const tuple = wrap.toTuple(val);
    if (types.tupleHead(tuple).length != 3) return false;
    if (kind.checkType(tuple[0], constants.JANET_FUNCTION) == 0) return false;
    const function = wrap.toFunction(tuple[0]);
    const flags: u32 = @bitCast(function.*.def.?.flags);
    if (flags & constants.JANET_FUNCDEF_FLAG_TAG != function_tag) return false;
    if (kind.checkType(tuple[1], constants.JANET_NIL) != 0) {
        capture.* = tuple[2];
        return true;
    }
    if (kind.checkType(tuple[2], constants.JANET_NIL) != 0) {
        capture.* = tuple[1];
        return true;
    }
    return false;
}

fn checkJump16(compiler: *types.JanetCompiler, from: i32, to: i32) void {
    const distance = to - from;
    if (distance > std_max_i16 or distance < std_min_i16) {
        compiler_primitives.cerror(compiler, "bad 16-bit jump, too large");
    }
}

fn checkJump24(compiler: *types.JanetCompiler, from: i32, to: i32) void {
    const distance = to - from;
    if (distance > 0xffffff or distance < -0x1000000) {
        compiler_primitives.cerror(compiler, "bad 24-bit jump, too large");
    }
}

fn vectorCount(comptime Element: type, vector: ?[*]Element) i32 {
    const v = vector orelse return 0;
    const header: [*]i32 = @ptrFromInt(@intFromPtr(v) - vector_header_size);
    return header[1];
}

fn vectorCapacity(comptime Element: type, vector: [*]Element) i32 {
    const header: [*]i32 = @ptrFromInt(@intFromPtr(vector) - vector_header_size);
    return header[0];
}

fn pushSlot(slots: *?[*]types.JanetSlot, val: types.JanetSlot) void {
    pushVector(types.JanetSlot, slots, val);
}

fn pushVector(comptime Element: type, items: *?[*]Element, val: Element) void {
    var vector = items.*;
    const count = vectorCount(Element, vector);
    if (vector == null or count + 1 >= vectorCapacity(Element, vector.?)) {
        const opaque_vector: ?*anyopaque = if (vector) |v| @ptrCast(v) else null;
        vector = @ptrCast(@alignCast(vector_mod.vGrow(opaque_vector, 1, @sizeOf(Element))));
        items.* = vector;
    }
    vector.?[@intCast(count)] = val;
    const header: [*]i32 = @ptrFromInt(@intFromPtr(vector.?) - vector_header_size);
    header[1] = count + 1;
}

fn freeVector(comptime Element: type, vector: ?[*]Element) void {
    const v = vector orelse return;
    const raw: *anyopaque = @ptrFromInt(@intFromPtr(v) - vector_header_size);
    gc_alloc.sfree(raw);
}

fn setVectorCount(comptime Element: type, vector: [*]Element, count: i32) void {
    const header: [*]i32 = @ptrFromInt(@intFromPtr(vector) - vector_header_size);
    header[1] = count;
}

fn addFunctionDefinition(compiler: *types.JanetCompiler, definition: *types.JanetFuncDef) i32 {
    var scope = compiler.scope;
    while (scope) |current| {
        if (current.flags & constants.JANET_SCOPE_FUNCTION != 0) break;
        scope = current.parent;
    }
    const function_scope = scope orelse unreachable;
    pushVector(*types.JanetFuncDef, &function_scope.*.defs, definition);
    return vectorCount(*types.JanetFuncDef, function_scope.*.defs) - 1;
}

const std_max_i16 = 0x7fff;
const std_min_i16 = -0x8000;
const std_max_i32 = 0x7fffffff;
