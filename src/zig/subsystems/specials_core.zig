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

const abi = @import("abi");
const c = abi.c;
const raise = @import("raise");
const pp_format = @import("pp_format.zig");
const containers = @import("containers.zig");
const compiler_primitives = @import("compiler_primitives.zig");
const special = @import("special.zig");

extern fn janet_def_addflags(definition: *c.JanetFuncDef) callconv(.c) void;
/// `janet_wrap_keyword`, and `janet_wrap_integer` written out.
///
/// Both were one-line C functions in `specials.c` until Phase 10 Part 7,
/// because this subsystem translated only `compile.h` and `emit.h`. Sharing
/// `abi.zig` removes the detour; `wrapInteger` stays spelled out because
/// `janet_wrap_integer` is a macro under nanboxing and a symbol `wrap.c`
/// never defines there.
inline fn wrapKeyword(value: [*c]const u8) c.Janet {
    return c.janet_wrap_keyword(value);
}

inline fn wrapInteger(value: i32) c.Janet {
    return c.janet_wrap_number(@floatFromInt(value));
}

const vector_header_size = 2 * @sizeOf(i32);

fn janet_zig_special_quote(
    options: c.JanetFopts,
    argument_count: i32,
    arguments: [*c]const c.Janet,
) raise.Raising(c.JanetSlot) {
    if (argument_count != 1) {
        c.janetc_cerror(options.compiler, "expected 1 argument to quote");
        return nilSlot();
    }
    return c.janetc_cslot(arguments[0]);
}

fn janet_zig_special_splice(
    options: c.JanetFopts,
    argument_count: i32,
    arguments: [*c]const c.Janet,
) raise.Raising(c.JanetSlot) {
    if (options.flags & c.JANET_FOPTS_ACCEPT_SPLICE == 0) {
        c.janetc_cerror(options.compiler, "splice can only be used in function parameters and data constructors, it has no effect here");
        return nilSlot();
    }
    if (argument_count != 1) {
        c.janetc_cerror(options.compiler, "expected 1 argument to splice");
        return nilSlot();
    }
    var result = try compiler_primitives.janetc_valueImpl(options, arguments[0]);
    result.flags |= c.JANET_SLOT_SPLICED;
    return result;
}

fn janet_zig_special_unquote(
    options: c.JanetFopts,
    _: i32,
    _: [*c]const c.Janet,
) raise.Raising(c.JanetSlot) {
    c.janetc_cerror(options.compiler, "cannot use unquote here");
    return nilSlot();
}

fn janet_zig_special_do(
    options: c.JanetFopts,
    argument_count: i32,
    arguments: [*c]const c.Janet,
) raise.Raising(c.JanetSlot) {
    const compiler: *c.JanetCompiler = options.compiler;
    var scope: c.JanetScope = undefined;
    c.janetc_scope(&scope, compiler, 0, "do");
    const result = try compileSequence(options, argument_count, arguments);
    try compiler_primitives.janetc_popscope_keepslotImpl(compiler, result);
    return result;
}

fn janet_zig_special_upscope(
    options: c.JanetFopts,
    argument_count: i32,
    arguments: [*c]const c.Janet,
) raise.Raising(c.JanetSlot) {
    return compileSequence(options, argument_count, arguments);
}

fn janet_zig_special_break(
    options: c.JanetFopts,
    argument_count: i32,
    arguments: [*c]const c.Janet,
) raise.Raising(c.JanetSlot) {
    const compiler: *c.JanetCompiler = options.compiler;
    if (argument_count > 1) {
        c.janetc_cerror(compiler, "expected at most 1 argument");
        return nilSlot();
    }

    var scope = compiler.scope;
    while (scope != null) : (scope = scope.*.parent) {
        if (scope.*.flags & (c.JANET_SCOPE_FUNCTION | c.JANET_SCOPE_WHILE) != 0) break;
    }
    if (scope == null) {
        c.janetc_cerror(compiler, "break must occur in while loop or closure");
        return nilSlot();
    }

    var suboptions = c.janetc_fopts_default(compiler);
    if (scope.*.flags & c.JANET_SCOPE_FUNCTION != 0) {
        if (scope.*.flags & c.JANET_SCOPE_WHILE == 0 and argument_count != 0) {
            suboptions.flags |= c.JANET_FOPTS_TAIL;
            _ = try compiler_primitives.janetc_valueImpl(suboptions, arguments[0]);
        } else {
            if (argument_count != 0) {
                suboptions.flags |= c.JANET_FOPTS_DROP;
                _ = try compiler_primitives.janetc_valueImpl(suboptions, arguments[0]);
            }
            _ = c.janetc_emit(compiler, c.JOP_RETURN_NIL);
        }
    } else {
        if (argument_count != 0) {
            suboptions.flags |= c.JANET_FOPTS_DROP;
            _ = try compiler_primitives.janetc_valueImpl(suboptions, arguments[0]);
        }
        _ = c.janetc_emit(compiler, 0x80 | c.JOP_JUMP);
    }
    return nilSlot();
}

fn janet_zig_special_if(
    options: c.JanetFopts,
    argument_count: i32,
    arguments: [*c]const c.Janet,
) raise.Raising(c.JanetSlot) {
    const compiler: *c.JanetCompiler = options.compiler;
    if (argument_count < 2 or argument_count > 3) {
        c.janetc_cerror(compiler, "expected 2 or 3 arguments to if");
        return nilSlot();
    }

    var true_body = arguments[1];
    var false_body = if (argument_count > 2) arguments[2] else c.janet_wrap_nil();
    const condition_options = c.janetc_fopts_default(compiler);
    var body_options = options;
    body_options.flags &= ~@as(u32, c.JANET_FOPTS_ACCEPT_SPLICE);
    const tail = options.flags & c.JANET_FOPTS_TAIL != 0;
    const drop = options.flags & c.JANET_FOPTS_DROP != 0;
    var target = if (drop or tail) nilSlot() else c.janetc_gettarget(options);

    var condition_scope: c.JanetScope = undefined;
    c.janetc_scope(&condition_scope, compiler, 0, "if");
    var condition_form = arguments[0];
    var jump_opcode: u8 = c.JOP_JUMP_IF_NOT;
    if (checkNilForm(condition_form, &condition_form, c.JANET_FUN_EQ)) {
        jump_opcode = c.JOP_JUMP_IF_NOT_NIL;
    } else if (checkNilForm(condition_form, &condition_form, c.JANET_FUN_NEQ)) {
        jump_opcode = c.JOP_JUMP_IF_NIL;
    }
    const condition = try compiler_primitives.janetc_valueImpl(condition_options, condition_form);

    if (condition.flags & c.JANET_SLOT_CONSTANT != 0) {
        const swap_condition =
            (jump_opcode == c.JOP_JUMP_IF_NOT and c.janet_truthy(condition.constant) == 0) or
            (jump_opcode == c.JOP_JUMP_IF_NIL and c.janet_checktype(condition.constant, c.JANET_NIL) != 0) or
            (jump_opcode == c.JOP_JUMP_IF_NOT_NIL and c.janet_checktype(condition.constant, c.JANET_NIL) == 0);
        if (swap_condition) {
            const temporary = false_body;
            false_body = true_body;
            true_body = temporary;
        }
        var body_scope: c.JanetScope = undefined;
        c.janetc_scope(&body_scope, compiler, 0, "if-true");
        const right = try compiler_primitives.janetc_valueImpl(body_options, true_body);
        if (!drop and !tail) c.janetc_copy(compiler, target, right);
        try compiler_primitives.janetc_popscopeImpl(compiler);
        if (c.janet_checktype(false_body, c.JANET_NIL) == 0) {
            try compiler_primitives.janetc_throwawayImpl(body_options, false_body);
        }
        try compiler_primitives.janetc_popscopeImpl(compiler);
        return target;
    }

    const right_jump = c.janetc_emit_si(compiler, jump_opcode, condition, 0, 0);
    var body_scope: c.JanetScope = undefined;
    c.janetc_scope(&body_scope, compiler, 0, "if-true");
    const left = try compiler_primitives.janetc_valueImpl(body_options, true_body);
    if (!drop and !tail) c.janetc_copy(compiler, target, left);
    try compiler_primitives.janetc_popscopeImpl(compiler);

    const done_jump = vectorCount(u32, compiler.buffer);
    if (!tail and !(drop and c.janet_checktype(false_body, c.JANET_NIL) != 0)) {
        _ = c.janetc_emit(compiler, c.JOP_JUMP);
    }
    const right_label = vectorCount(u32, compiler.buffer);
    c.janetc_scope(&body_scope, compiler, 0, "if-false");
    const right = try compiler_primitives.janetc_valueImpl(body_options, false_body);
    if (!drop and !tail) c.janetc_copy(compiler, target, right);
    try compiler_primitives.janetc_popscopeImpl(compiler);
    try compiler_primitives.janetc_popscopeImpl(compiler);

    const done_label = vectorCount(u32, compiler.buffer);
    if (right_jump < done_label) {
        checkJump16(compiler, right_jump, right_label);
        compiler.buffer[@intCast(right_jump)] |= @as(u32, @intCast(right_label - right_jump)) << 16;
        if (!tail and done_jump < done_label) {
            checkJump24(compiler, done_jump, done_label);
            compiler.buffer[@intCast(done_jump)] |= @as(u32, @intCast(done_label - done_jump)) << 8;
        }
    }

    if (tail) target.flags |= c.JANET_SLOT_RETURNED;
    return target;
}

fn janet_zig_special_quasiquote(
    options: c.JanetFopts,
    argument_count: i32,
    arguments: [*c]const c.Janet,
) raise.Raising(c.JanetSlot) {
    if (argument_count != 1) {
        c.janetc_cerror(options.compiler, "expected 1 argument to quasiquote");
        return nilSlot();
    }
    return quasiquote(options, arguments[0], c.JANET_RECURSION_GUARD, 0);
}

fn janet_zig_special_while(
    options: c.JanetFopts,
    argument_count: i32,
    arguments: [*c]const c.Janet,
) raise.Raising(c.JanetSlot) {
    const compiler: *c.JanetCompiler = options.compiler;
    if (argument_count < 1) {
        c.janetc_cerror(compiler, "expected at least 1 argument to while");
        return nilSlot();
    }

    const while_label = vectorCount(u32, compiler.buffer);
    var suboptions = c.janetc_fopts_default(compiler);
    var scope: c.JanetScope = undefined;
    c.janetc_scope(&scope, compiler, c.JANET_SCOPE_WHILE, "while");

    var condition_form = arguments[0];
    var is_nil_form = false;
    var is_not_nil_form = false;
    var true_jump: u8 = c.JOP_JUMP_IF;
    var false_jump: u8 = c.JOP_JUMP_IF_NOT;
    if (checkNilForm(condition_form, &condition_form, c.JANET_FUN_EQ)) {
        is_nil_form = true;
        true_jump = c.JOP_JUMP_IF_NIL;
        false_jump = c.JOP_JUMP_IF_NOT_NIL;
    }
    if (checkNilForm(condition_form, &condition_form, c.JANET_FUN_NEQ)) {
        is_not_nil_form = true;
        true_jump = c.JOP_JUMP_IF_NOT_NIL;
        false_jump = c.JOP_JUMP_IF_NIL;
    }

    var condition = try compiler_primitives.janetc_valueImpl(suboptions, condition_form);
    var infinite = false;
    if (condition.flags & c.JANET_SLOT_CONSTANT != 0) {
        const never_executes = if (is_nil_form)
            c.janet_checktype(condition.constant, c.JANET_NIL) == 0
        else if (is_not_nil_form)
            c.janet_checktype(condition.constant, c.JANET_NIL) != 0
        else
            c.janet_truthy(condition.constant) == 0;
        if (never_executes) {
            try compiler_primitives.janetc_popscopeImpl(compiler);
            return nilSlot();
        }
        infinite = true;
    }

    const condition_label = if (infinite)
        0
    else
        c.janetc_emit_si(compiler, false_jump, condition, 0, 0);
    var index: i32 = 1;
    while (index < argument_count) : (index += 1) {
        suboptions.flags = c.JANET_FOPTS_DROP;
        c.janetc_freeslot(compiler, try compiler_primitives.janetc_valueImpl(suboptions, arguments[@intCast(index)]));
    }

    if (scope.flags & c.JANET_SCOPE_CLOSURE != 0) {
        suboptions = c.janetc_fopts_default(compiler);
        scope.flags |= c.JANET_SCOPE_UNUSED;
        try compiler_primitives.janetc_popscopeImpl(compiler);
        if (compiler.buffer != null) setVectorCount(u32, compiler.buffer, while_label);
        if (compiler.mapbuffer != null) setVectorCount(c.JanetSourceMapping, compiler.mapbuffer, while_label);

        c.janetc_scope(&scope, compiler, c.JANET_SCOPE_FUNCTION, "while-iife");
        condition = try compiler_primitives.janetc_valueImpl(suboptions, condition_form);
        if (condition.flags & c.JANET_SLOT_CONSTANT == 0) {
            _ = c.janetc_emit_si(compiler, true_jump, condition, 2, 0);
            _ = c.janetc_emit(compiler, c.JOP_RETURN_NIL);
        }
        index = 1;
        while (index < argument_count) : (index += 1) {
            suboptions.flags = c.JANET_FOPTS_DROP;
            c.janetc_freeslot(compiler, try compiler_primitives.janetc_valueImpl(suboptions, arguments[@intCast(index)]));
        }

        const self_register = c.janetc_regalloc_temp(&scope.ra, c.JANETC_REGTEMP_0);
        emitInstruction(compiler, @as(u32, c.JOP_LOAD_SELF) | (@as(u32, @intCast(self_register)) << 8));
        emitInstruction(compiler, @as(u32, c.JOP_TAILCALL) | (@as(u32, @intCast(self_register)) << 8));
        c.janetc_regalloc_freetemp(&compiler.scope.*.ra, self_register, c.JANETC_REGTEMP_0);

        const definition = try compiler_primitives.janetc_pop_funcdefImpl(compiler);
        definition.*.name = c.janet_cstring("while");
        janet_def_addflags(definition);
        const definition_index = addFunctionDefinition(compiler, definition);
        const closure_register = c.janetc_regalloc_temp(&compiler.scope.*.ra, c.JANETC_REGTEMP_0);
        emitInstruction(
            compiler,
            @as(u32, c.JOP_CLOSURE) |
                (@as(u32, @intCast(closure_register)) << 8) |
                (@as(u32, @intCast(definition_index)) << 16),
        );
        emitInstruction(
            compiler,
            @as(u32, c.JOP_CALL) |
                (@as(u32, @intCast(closure_register)) << 8) |
                (@as(u32, @intCast(closure_register)) << 16),
        );
        c.janetc_regalloc_freetemp(&compiler.scope.*.ra, closure_register, c.JANETC_REGTEMP_0);
        compiler.scope.*.flags |= c.JANET_SCOPE_CLOSURE;
        return nilSlot();
    }

    const top_jump = vectorCount(u32, compiler.buffer);
    _ = c.janetc_emit(compiler, c.JOP_JUMP);
    const done_label = vectorCount(u32, compiler.buffer);
    if (!infinite) {
        checkJump16(compiler, condition_label, done_label);
        compiler.buffer[@intCast(condition_label)] |= @as(u32, @intCast(done_label - condition_label)) << 16;
    }
    checkJump24(compiler, top_jump, while_label);
    compiler.buffer[@intCast(top_jump)] |= @as(u32, @bitCast(while_label - top_jump)) << 8;

    index = while_label;
    while (index < done_label) : (index += 1) {
        if (compiler.buffer[@intCast(index)] == 0x80 | c.JOP_JUMP) {
            checkJump24(compiler, index, done_label);
            compiler.buffer[@intCast(index)] = @as(u32, c.JOP_JUMP) |
                (@as(u32, @intCast(done_label - index)) << 8);
        }
    }
    try compiler_primitives.janetc_popscopeImpl(compiler);
    return nilSlot();
}

fn janet_zig_special_set(
    options: c.JanetFopts,
    argument_count: i32,
    arguments: [*c]const c.Janet,
) raise.Raising(c.JanetSlot) {
    const compiler: *c.JanetCompiler = options.compiler;
    if (argument_count != 2) {
        c.janetc_cerror(compiler, "expected 2 arguments to set");
        return nilSlot();
    }
    const suboptions = c.janetc_fopts_default(compiler);

    if (c.janet_checktype(arguments[0], c.JANET_SYMBOL) != 0) {
        const destination = try compiler_primitives.janetc_resolveImpl(compiler, c.janet_unwrap_symbol(arguments[0]));
        if (destination.flags & c.JANET_SLOT_MUTABLE == 0) {
            c.janetc_cerror(compiler, "cannot set constant");
            return nilSlot();
        }
        var value_options = suboptions;
        value_options.flags = c.JANET_FOPTS_HINT;
        value_options.hint = destination;
        const result = try compiler_primitives.janetc_valueImpl(value_options, arguments[1]);
        c.janetc_copy(compiler, destination, result);
        return result;
    }

    if (c.janet_checktype(arguments[0], c.JANET_TUPLE) != 0) {
        const tuple = c.janet_unwrap_tuple(arguments[0]);
        if (c.janet_tuple_length(tuple) != 2) {
            c.janetc_cerror(compiler, "expected 2 element tuple for l-value to set");
            return nilSlot();
        }
        const data_structure = try compiler_primitives.janetc_valueImpl(suboptions, tuple[0]);
        const key = try compiler_primitives.janetc_valueImpl(suboptions, tuple[1]);
        var value_options = options;
        value_options.flags &= ~@as(u32, c.JANET_FOPTS_TAIL | c.JANET_FOPTS_DROP);
        const result = try compiler_primitives.janetc_valueImpl(value_options, arguments[1]);
        _ = c.janetc_emit_sss(compiler, c.JOP_PUT, data_structure, key, result, 0);
        return result;
    }

    c.janetc_cerror(compiler, "expected symbol or tuple for l-value to set");
    return nilSlot();
}

fn janet_zig_special_var(
    options: c.JanetFopts,
    argument_count: i32,
    arguments: [*c]const c.Janet,
) raise.Raising(c.JanetSlot) {
    return try compileBinding(options, argument_count, arguments, .variable);
}

fn janet_zig_special_def(
    options: c.JanetFopts,
    argument_count: i32,
    arguments: [*c]const c.Janet,
) raise.Raising(c.JanetSlot) {
    return try compileBinding(options, argument_count, arguments, .definition);
}

fn janet_zig_special_fn(
    options: c.JanetFopts,
    argument_count: i32,
    arguments: [*c]const c.Janet,
) raise.Raising(c.JanetSlot) {
    const compiler: *c.JanetCompiler = options.compiler;
    compiler.scope.*.flags |= c.JANET_SCOPE_CLOSURE;
    var function_scope: c.JanetScope = undefined;
    c.janetc_scope(&function_scope, compiler, c.JANET_SCOPE_FUNCTION, "function");

    if (argument_count == 0) {
        return functionError(compiler, "expected at least 1 argument to function literal");
    }

    var parameter_index: i32 = 0;
    const head = arguments[0];
    const self_reference = c.janet_checktype(head, c.JANET_SYMBOL) != 0;
    const has_name = self_reference or c.janet_checktype(head, c.JANET_KEYWORD) != 0;
    if (has_name) parameter_index = 1;
    if (parameter_index >= argument_count or
        c.janet_checktype(arguments[@intCast(parameter_index)], c.JANET_TUPLE) == 0)
    {
        return functionError(compiler, "expected function parameters");
    }

    const parameters = c.janet_unwrap_tuple(arguments[@intCast(parameter_index)]);
    const parameter_count = c.janet_tuple_length(parameters);
    var destructured_parameters: [*c]c.JanetSlot = null;
    var named_parameters: [*c]c.JanetSlot = null;
    var named_table: ?*c.JanetTable = null;
    var named_slot: c.JanetSlot = undefined;
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
            if (c.janet_checktype(parameter, c.JANET_SYMBOL) == 0) {
                freeVector(c.JanetSlot, destructured_parameters);
                freeVector(c.JanetSlot, named_parameters);
                return functionError(compiler, "only named arguments can follow &named");
            }
            c.janet_table_put(
                named_table.?,
                wrapKeyword(c.janet_unwrap_symbol(parameter)),
                parameter,
            );
            pushSlot(&named_parameters, c.janetc_farslot(compiler));
            continue;
        }

        if (c.janet_checktype(parameter, c.JANET_SYMBOL) == 0) {
            pushSlot(&destructured_parameters, c.janetc_farslot(compiler));
            continue;
        }

        const symbol = c.janet_unwrap_symbol(parameter);
        if (symbol[0] != '&') {
            try compiler_primitives.janetc_nameslotImpl(compiler, symbol, c.janetc_farslot(compiler), 0);
            continue;
        }

        if (c.janet_cstrcmp(symbol, "&") == 0) {
            if (seen_amp) {
                return cleanupFunctionError(compiler, destructured_parameters, named_parameters, "& in unexpected location");
            } else if (index == parameter_count - 1) {
                allow_extra = true;
                arity -= 1;
            } else if (index == parameter_count - 2) {
                vararg = true;
                arity -= 2;
            } else {
                return cleanupFunctionError(compiler, destructured_parameters, named_parameters, "& in unexpected location");
            }
            seen_amp = true;
        } else if (c.janet_cstrcmp(symbol, "&opt") == 0) {
            if (seen_optional) {
                return cleanupFunctionError(compiler, destructured_parameters, named_parameters, "only one &opt allowed");
            } else if (index == parameter_count - 1) {
                return cleanupFunctionError(compiler, destructured_parameters, named_parameters, "&opt cannot be last item in parameter list");
            }
            minimum_arity = index;
            arity -= 1;
            seen_optional = true;
        } else if (c.janet_cstrcmp(symbol, "&keys") == 0) {
            if (seen_amp or index != parameter_count - 2) {
                return cleanupFunctionError(compiler, destructured_parameters, named_parameters, "&keys in unexpected location");
            }
            vararg = true;
            structarg = true;
            arity -= 2;
            seen_amp = true;
        } else if (c.janet_cstrcmp(symbol, "&named") == 0) {
            if (seen_amp) {
                return cleanupFunctionError(compiler, destructured_parameters, named_parameters, "&named in unexpected location");
            }
            vararg = true;
            structarg = true;
            arity -= 1;
            seen_amp = true;
            named_arguments = true;
            named_table = c.janet_table(10);
            named_slot = c.janetc_farslot(compiler);
        } else {
            try compiler_primitives.janetc_nameslotImpl(compiler, symbol, c.janetc_farslot(compiler), 0);
        }
    }

    if (named_arguments) {
        _ = try destructure(
            compiler,
            c.janet_wrap_table(named_table.?),
            named_slot,
            .definition,
            null,
        );
        c.janetc_freeslot(compiler, named_slot);
        freeVector(c.JanetSlot, named_parameters);
        named_parameters = null;
    }

    var destructured_index: i32 = 0;
    index = 0;
    while (index < parameter_count) : (index += 1) {
        const parameter = parameters[@intCast(index)];
        if (c.janet_checktype(parameter, c.JANET_SYMBOL) != 0) continue;
        if (destructured_index >= vectorCount(c.JanetSlot, destructured_parameters)) unreachable;
        const parameter_slot = destructured_parameters[@intCast(destructured_index)];
        destructured_index += 1;
        _ = try destructure(compiler, parameter, parameter_slot, .definition, null);
        c.janetc_freeslot(compiler, parameter_slot);
    }
    freeVector(c.JanetSlot, destructured_parameters);
    destructured_parameters = null;

    const maximum_arity: i32 = if (vararg or allow_extra) std_max_i32 else arity;
    if (!seen_optional) minimum_arity = arity;

    if (self_reference) {
        const symbol = c.janet_unwrap_symbol(head);
        var found = false;
        index = 0;
        while (index < vectorCount(c.SymPair, compiler.scope.*.syms)) : (index += 1) {
            if (compiler.scope.*.syms[@intCast(index)].sym == symbol) found = true;
        }
        if (!found) {
            var slot = c.janetc_farslot(compiler);
            slot.flags = @as(u32, c.JANET_SLOT_NAMED) | @as(u32, c.JANET_FUNCTION);
            _ = c.janetc_emit_s(compiler, c.JOP_LOAD_SELF, slot, 1);
            try compiler_primitives.janetc_nameslotImpl(
                compiler,
                symbol,
                slot,
                c.JANET_DEFFLAG_NO_UNUSED | c.JANET_DEFFLAG_NO_SHADOWCHECK,
            );
        }
    }

    var suboptions = c.janetc_fopts_default(compiler);
    if (parameter_index + 1 == argument_count) {
        _ = c.janetc_emit(compiler, c.JOP_RETURN_NIL);
    } else {
        var argument_index = parameter_index + 1;
        while (argument_index < argument_count) : (argument_index += 1) {
            suboptions.flags = if (argument_index == argument_count - 1) c.JANET_FOPTS_TAIL else c.JANET_FOPTS_DROP;
            _ = try compiler_primitives.janetc_valueImpl(suboptions, arguments[@intCast(argument_index)]);
            if (compiler.result.status == c.JANET_COMPILE_ERROR) {
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
    if (vararg) definition.*.flags |= c.JANET_FUNCDEF_FLAG_VARARG;
    if (structarg) definition.*.flags |= c.JANET_FUNCDEF_FLAG_STRUCTARG;
    if (named_arguments) definition.*.flags |= c.JANET_FUNCDEF_FLAG_NAMEDARGS;
    if (has_name) definition.*.name = c.janet_unwrap_symbol(head);
    janet_def_addflags(definition);
    const definition_index = addFunctionDefinition(compiler, definition);
    const vararg_slot: i32 = if (vararg) 1 else 0;
    if (arity + vararg_slot > definition.*.slotcount) definition.*.slotcount = arity + vararg_slot;

    const result = c.janetc_gettarget(options);
    _ = c.janetc_emit_su(compiler, c.JOP_CLOSURE, result, @intCast(definition_index), 1);
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
fn lookup(name: [*c]const u8) ?*const special.Special {
    var lower: usize = 0;
    var upper: usize = specials.len;
    while (lower < upper) {
        const middle = lower + (upper - lower) / 2;
        const comparison = c.janet_cstrcmp(name, specials[middle].name);
        if (comparison == 0) return &specials[middle];
        if (comparison < 0) {
            upper = middle;
        } else {
            lower = middle + 1;
        }
    }
    return null;
}

export fn janetc_special(name: [*c]const u8) callconv(.c) ?*const c.JanetSpecial {
    return if (lookup(name)) |s| special.stored(s) else null;
}

fn functionError(compiler: *c.JanetCompiler, message: [*:0]const u8) raise.Raising(c.JanetSlot) {
    c.janetc_cerror(compiler, message);
    try compiler_primitives.janetc_popscopeImpl(compiler);
    return nilSlot();
}

fn cleanupFunctionError(
    compiler: *c.JanetCompiler,
    destructured_parameters: [*c]c.JanetSlot,
    named_parameters: [*c]c.JanetSlot,
    message: [*:0]const u8,
) raise.Raising(c.JanetSlot) {
    freeVector(c.JanetSlot, destructured_parameters);
    freeVector(c.JanetSlot, named_parameters);
    return functionError(compiler, message);
}

const BindingKind = enum { variable, definition };

const SlotHeadPair = extern struct {
    lhs: c.Janet,
    rhs: c.JanetSlot,
};

fn compileBinding(
    original_options: c.JanetFopts,
    argument_count: i32,
    arguments: [*c]const c.Janet,
    kind: BindingKind,
) raise.Raising(c.JanetSlot) {
    const compiler: *c.JanetCompiler = original_options.compiler;
    const attributes = handleAttributes(
        compiler,
        if (kind == .variable) "var" else "def",
        argument_count,
        arguments,
    );
    if (compiler.result.status == c.JANET_COMPILE_ERROR) return nilSlot();
    try checkMetadataLint(compiler, attributes);

    var options = original_options;
    if (kind == .definition) options.flags &= ~@as(u32, c.JANET_FOPTS_HINT);
    var pairs: [*c]SlotHeadPair = null;
    try buildDestructureHeads(&pairs, options, arguments[0], arguments[@intCast(argument_count - 1)]);
    if (compiler.result.status == c.JANET_COMPILE_ERROR) {
        freeVector(SlotHeadPair, pairs);
        return nilSlot();
    }

    const count = vectorCount(SlotHeadPair, pairs);
    if (count == 0) unreachable;
    var result = nilSlot();
    var index: i32 = 0;
    while (index < count) : (index += 1) {
        const pair = pairs[@intCast(index)];
        _ = try destructure(compiler, pair.lhs, pair.rhs, kind, attributes);
        result = pair.rhs;
    }
    freeVector(SlotHeadPair, pairs);
    return result;
}

fn handleAttributes(
    compiler: *c.JanetCompiler,
    kind: [*:0]const u8,
    argument_count: i32,
    arguments: [*c]const c.Janet,
) ?*c.JanetTable {
    if (argument_count < 2) {
        c.janetc_error(compiler, pp_format.formatcReported("expected at least 2 arguments to %s", .{kind}));
        return null;
    }
    const table = c.janet_table(2);
    const binding_name: [*:0]const u8 = if (c.janet_type(arguments[0]) == c.JANET_SYMBOL)
        @ptrCast(c.janet_unwrap_symbol(arguments[0]))
    else
        "<multiple bindings>";
    var index: i32 = 1;
    while (index < argument_count - 1) : (index += 1) {
        const attribute = arguments[@intCast(index)];
        switch (c.janet_type(attribute)) {
            c.JANET_TUPLE => c.janetc_cerror(compiler, "unexpected form - did you intend to use defn?"),
            c.JANET_KEYWORD => c.janet_table_put(table, attribute, c.janet_wrap_true()),
            c.JANET_STRING => c.janet_table_put(table, c.janet_ckeywordv("doc"), attribute),
            c.JANET_STRUCT => c.janet_table_merge_struct(table, c.janet_unwrap_struct(attribute)),
            else => c.janetc_error(
                compiler,
                pp_format.formatcReported("cannot add metadata %v to binding %s", .{ attribute, binding_name }),
            ),
        }
    }
    return table;
}

fn checkMetadataLint(compiler: *c.JanetCompiler, attributes: ?*c.JanetTable) raise.Raising(void) {
    if (compiler.scope.*.flags & c.JANET_SCOPE_TOP != 0 or attributes == null or attributes.?.*.count == 0) return;
    if (c.janet_truthy(tableGetKeyword(attributes.?, "macro")) != 0) {
        try compiler_primitives.janetc_lintImpl(compiler, c.JANET_C_LINT_NORMAL, "macro tag is ignored in inner scopes");
    }
}

fn buildDestructureHeads(
    pairs: *[*c]SlotHeadPair,
    options: c.JanetFopts,
    lhs: c.Janet,
    rhs: c.Janet,
) raise.Raising(void) {
    const compiler: *c.JanetCompiler = options.compiler;
    const lhs_indexed = c.janet_checktype(lhs, c.JANET_TUPLE) != 0 or
        c.janet_checktype(lhs, c.JANET_ARRAY) != 0;
    const rhs_indexed = c.janet_checktype(rhs, c.JANET_ARRAY) != 0 or
        (c.janet_checktype(rhs, c.JANET_TUPLE) != 0 and
            c.janet_tuple_head(c.janet_unwrap_tuple(rhs)).*.gc.flags & c.JANET_TUPLE_FLAG_BRACKETCTOR != 0);
    const has_drop = options.flags & c.JANET_FOPTS_DROP != 0;
    var suboptions = c.janetc_fopts_default(compiler);
    suboptions.flags = options.flags & ~@as(u32, c.JANET_FOPTS_TAIL | c.JANET_FOPTS_DROP);

    if (has_drop and lhs_indexed and rhs_indexed) {
        var lhs_items: [*c]const c.Janet = null;
        var lhs_length: i32 = 0;
        var rhs_items: [*c]const c.Janet = null;
        var rhs_length: i32 = 0;
        _ = c.janet_indexed_view(lhs, &lhs_items, &lhs_length);
        _ = c.janet_indexed_view(rhs, &rhs_items, &rhs_length);
        var found_amp = false;
        var found_splice = false;
        var index: i32 = 0;
        while (index < rhs_length) : (index += 1) {
            const item = rhs_items[@intCast(index)];
            if (c.janet_checktype(item, c.JANET_TUPLE) == 0) continue;
            const tuple = c.janet_unwrap_tuple(item);
            if (c.janet_tuple_length(tuple) != 0 and symbolEquals(tuple[0], "splice")) {
                found_splice = true;
                break;
            }
        }
        index = 0;
        while (index < lhs_length) : (index += 1) {
            if (symbolEquals(lhs_items[@intCast(index)], "&")) {
                found_amp = true;
                break;
            }
        }
        if (!found_amp and !found_splice) {
            index = 0;
            while (index < lhs_length) : (index += 1) {
                const sub_rhs = if (index < rhs_length) rhs_items[@intCast(index)] else c.janet_wrap_nil();
                try buildDestructureHeads(pairs, suboptions, lhs_items[@intCast(index)], sub_rhs);
            }
            return;
        }
    }

    suboptions.hint = options.hint;
    pushVector(SlotHeadPair, pairs, .{ .lhs = lhs, .rhs = try compiler_primitives.janetc_valueImpl(suboptions, rhs) });
}

fn destructure(
    compiler: *c.JanetCompiler,
    lhs: c.Janet,
    rhs: c.JanetSlot,
    kind: BindingKind,
    attributes: ?*c.JanetTable,
) raise.Raising(bool) {
    switch (c.janet_type(lhs)) {
        c.JANET_SYMBOL => return try bindLeaf(compiler, c.janet_unwrap_symbol(lhs), rhs, kind, attributes),
        c.JANET_TUPLE, c.JANET_ARRAY => {
            var values: [*c]const c.Janet = null;
            var length: i32 = 0;
            _ = c.janet_indexed_view(lhs, &values, &length);
            var index: i32 = 0;
            while (index < length) : (index += 1) {
                const next_rhs = c.janetc_farslot(compiler);
                const subvalue = values[@intCast(index)];
                if (symbolEquals(subvalue, "&")) {
                    if (index + 1 >= length) {
                        c.janetc_cerror(compiler, "expected symbol following '& in destructuring pattern");
                        return true;
                    }
                    if (index + 2 < length) {
                        const extra_count = length - index - 1;
                        const extra = c.janet_tuple_begin(extra_count);
                        c.janet_tuple_head(extra).*.gc.flags |= c.JANET_TUPLE_FLAG_BRACKETCTOR;
                        var extra_index: i32 = 0;
                        while (extra_index < extra_count) : (extra_index += 1) {
                            extra[@intCast(extra_index)] = values[@intCast(index + 1 + extra_index)];
                        }
                        c.janetc_error(
                            compiler,
                            try pp_format.formatc("expected a single symbol follow '& in destructuring pattern, found %q", .{c.janet_wrap_tuple(c.janet_tuple_end(extra))}),
                        );
                        return true;
                    }
                    if (c.janet_checktype(values[@intCast(index + 1)], c.JANET_SYMBOL) == 0) {
                        c.janetc_error(
                            compiler,
                            try pp_format.formatc("expected symbol following '& in destructuring pattern, found %q", .{values[@intCast(index + 1)]}),
                        );
                        return true;
                    }
                    compileRestDestructure(compiler, rhs, next_rhs, index);
                    _ = try bindLeaf(
                        compiler,
                        c.janet_unwrap_symbol(values[@intCast(index + 1)]),
                        next_rhs,
                        kind,
                        attributes,
                    );
                    c.janetc_freeslot(compiler, next_rhs);
                    break;
                }

                if (index < 0x100) {
                    _ = c.janetc_emit_ssu(compiler, c.JOP_GET_INDEX, next_rhs, rhs, @intCast(index), 1);
                } else {
                    const key = c.janetc_cslot(wrapInteger(index));
                    _ = c.janetc_emit_sss(compiler, c.JOP_IN, next_rhs, rhs, key, 1);
                }
                if (try destructure(compiler, subvalue, next_rhs, kind, attributes)) {
                    c.janetc_freeslot(compiler, next_rhs);
                }
            }
            return true;
        },
        c.JANET_TABLE, c.JANET_STRUCT => {
            var key_values: [*c]const c.JanetKV = null;
            var length: i32 = 0;
            var capacity: i32 = 0;
            _ = c.janet_dictionary_view(lhs, &key_values, &length, &capacity);
            var index: i32 = 0;
            while (index < capacity) : (index += 1) {
                const pair = key_values[@intCast(index)];
                if (c.janet_checktype(pair.key, c.JANET_NIL) != 0) continue;
                const next_rhs = c.janetc_farslot(compiler);
                const key = try compiler_primitives.janetc_valueImpl(c.janetc_fopts_default(compiler), pair.key);
                _ = c.janetc_emit_sss(compiler, c.JOP_IN, next_rhs, rhs, key, 1);
                if (try destructure(compiler, pair.value, next_rhs, kind, attributes)) {
                    c.janetc_freeslot(compiler, next_rhs);
                }
            }
            return true;
        },
        else => {
            c.janetc_error(compiler, try pp_format.formatc("unexpected type in destructuring, got %v", .{lhs}));
            return true;
        },
    }
}

fn compileRestDestructure(compiler: *c.JanetCompiler, rhs: c.JanetSlot, target: c.JanetSlot, start: i32) void {
    const argument_index = c.janetc_farslot(compiler);
    const argument = c.janetc_farslot(compiler);
    const length = c.janetc_farslot(compiler);
    _ = c.janetc_emit_si(compiler, c.JOP_LOAD_INTEGER, argument_index, @truncate(start), 0);
    _ = c.janetc_emit_ss(compiler, c.JOP_LENGTH, length, rhs, 0);
    const loop_start = c.janetc_emit_sss(compiler, c.JOP_LESS_THAN, argument, argument_index, length, 0);
    const condition_jump = c.janetc_emit_si(compiler, c.JOP_JUMP_IF_NOT, argument, 0, 0);
    _ = c.janetc_emit_sss(compiler, c.JOP_GET, argument, rhs, argument_index, 0);
    _ = c.janetc_emit_s(compiler, c.JOP_PUSH, argument, 0);
    _ = c.janetc_emit_ssi(compiler, c.JOP_ADD_IMMEDIATE, argument_index, argument_index, 1, 0);
    const loop_jump = vectorCount(u32, compiler.buffer);
    _ = c.janetc_emit(compiler, c.JOP_JUMP);
    const exit_label = vectorCount(u32, compiler.buffer);
    checkJump16(compiler, condition_jump, exit_label);
    checkJump24(compiler, loop_start, loop_jump);
    compiler.buffer[@intCast(condition_jump)] |= @as(u32, @intCast(exit_label - condition_jump)) << 16;
    compiler.buffer[@intCast(loop_jump)] |= @as(u32, @bitCast(loop_start - loop_jump)) << 8;
    c.janetc_freeslot(compiler, argument_index);
    c.janetc_freeslot(compiler, argument);
    c.janetc_freeslot(compiler, length);
    _ = c.janetc_emit_s(compiler, c.JOP_MAKE_TUPLE, target, 1);
}

fn bindLeaf(
    compiler: *c.JanetCompiler,
    symbol: [*c]const u8,
    slot: c.JanetSlot,
    kind: BindingKind,
    attributes: ?*c.JanetTable,
) raise.Raising(bool) {
    return switch (kind) {
        .variable => try bindVariableLeaf(compiler, symbol, slot, attributes),
        .definition => bindDefinitionLeaf(compiler, symbol, slot, attributes),
    };
}

fn nameLocal(
    compiler: *c.JanetCompiler,
    symbol: [*c]const u8,
    binding_flags: u32,
    original_slot: c.JanetSlot,
    original_definition_flags: u32,
) raise.Raising(bool) {
    var slot = original_slot;
    var definition_flags = original_definition_flags;
    var unnamed_register = slot.flags & c.JANET_SLOT_NAMED == 0 and slot.index > 0 and slot.envindex >= 0;
    const can_alias = binding_flags & c.JANET_SLOT_MUTABLE == 0 and
        slot.flags & c.JANET_SLOT_MUTABLE == 0 and
        slot.flags & c.JANET_SLOT_NAMED != 0 and
        slot.index >= 0 and slot.envindex == -1;
    if (can_alias) {
        slot.flags &= ~@as(u32, c.JANET_SLOT_MUTABLE);
        unnamed_register = true;
    } else if (!unnamed_register) {
        const local_slot = c.janetc_farslot(compiler);
        c.janetc_copy(compiler, local_slot, slot);
        slot = local_slot;
    }
    slot.flags |= binding_flags;
    if (compiler.scope.*.flags & c.JANET_SCOPE_TOP != 0) definition_flags |= c.JANET_DEFFLAG_NO_UNUSED;
    try compiler_primitives.janetc_nameslotImpl(compiler, symbol, slot, definition_flags);
    return !unnamed_register;
}

fn bindVariableLeaf(
    compiler: *c.JanetCompiler,
    symbol: [*c]const u8,
    slot: c.JanetSlot,
    attributes: ?*c.JanetTable,
) raise.Raising(bool) {
    if (compiler.scope.*.flags & c.JANET_SCOPE_TOP != 0) {
        const entry = c.janet_table_clone(attributes);
        var reference: *c.JanetArray = undefined;
        if (compiler.is_redef != 0) {
            const old_binding = c.janet_resolve_ext(compiler.env, symbol);
            if (old_binding.type == c.JANET_BINDING_VAR) {
                reference = c.janet_unwrap_array(old_binding.value);
            } else {
                reference = try newReferenceArray();
            }
        } else {
            reference = try newReferenceArray();
        }
        c.janet_table_put(entry, c.janet_ckeywordv("ref"), c.janet_wrap_array(reference));
        c.janet_table_put(entry, c.janet_ckeywordv("source-map"), c.janet_wrap_tuple(makeSourceMap(compiler)));
        c.janet_table_put(compiler.env, c.janet_wrap_symbol(symbol), c.janet_wrap_table(entry));
        _ = c.janetc_emit_ssu(
            compiler,
            c.JOP_PUT_INDEX,
            c.janetc_cslot(c.janet_wrap_array(reference)),
            slot,
            0,
            0,
        );
        return true;
    }
    var definition_flags: u32 = 0;
    if (attributes != null and attributes.?.*.count != 0) {
        if (c.janet_truthy(tableGetKeyword(attributes.?, "unused")) != 0) {
            definition_flags |= c.JANET_DEFFLAG_NO_UNUSED;
        }
        if (c.janet_truthy(tableGetKeyword(attributes.?, "shadow")) != 0) {
            definition_flags |= c.JANET_DEFFLAG_NO_SHADOWCHECK;
        }
    }
    return nameLocal(compiler, symbol, c.JANET_SLOT_MUTABLE, slot, definition_flags);
}

fn bindDefinitionLeaf(
    compiler: *c.JanetCompiler,
    symbol: [*c]const u8,
    slot: c.JanetSlot,
    attributes: ?*c.JanetTable,
) raise.Raising(bool) {
    var entry: ?*c.JanetTable = null;
    var redef = false;
    if (compiler.scope.*.flags & c.JANET_SCOPE_TOP != 0) {
        entry = c.janet_table_clone(attributes);
        c.janet_table_put(entry, c.janet_ckeywordv("source-map"), c.janet_wrap_tuple(makeSourceMap(compiler)));
        redef = compiler.is_redef != 0;
        if (redef) c.janet_table_put(entry, c.janet_ckeywordv("redef"), c.janet_wrap_true());
        if (redef) {
            const binding = c.janet_resolve_ext(compiler.env, symbol);
            const reference = if (binding.type == c.JANET_BINDING_DYNAMIC_DEF or
                binding.type == c.JANET_BINDING_DYNAMIC_MACRO)
                c.janet_unwrap_array(binding.value)
            else
                newReferenceArray();
            c.janet_table_put(entry, c.janet_ckeywordv("ref"), c.janet_wrap_array(try reference));
            _ = c.janetc_emit_ssu(
                compiler,
                c.JOP_PUT_INDEX,
                c.janetc_cslot(c.janet_wrap_array(try reference)),
                slot,
                0,
                0,
            );
        } else {
            _ = c.janetc_emit_sss(
                compiler,
                c.JOP_PUT,
                c.janetc_cslot(c.janet_wrap_table(entry)),
                c.janetc_cslot(c.janet_ckeywordv("value")),
                slot,
                0,
            );
        }
    }
    var definition_flags: u32 = 0;
    if (attributes != null and attributes.?.*.count != 0 and
        c.janet_truthy(tableGetKeyword(attributes.?, "unused")) != 0)
    {
        definition_flags |= c.JANET_DEFFLAG_NO_UNUSED;
    }
    if (redef or (attributes != null and attributes.?.*.count != 0 and
        c.janet_truthy(tableGetKeyword(attributes.?, "shadow")) != 0))
    {
        definition_flags |= c.JANET_DEFFLAG_NO_SHADOWCHECK;
    }
    const result = try nameLocal(compiler, symbol, 0, slot, definition_flags);
    if (entry != null) {
        c.janet_table_put(compiler.env, c.janet_wrap_symbol(symbol), c.janet_wrap_table(entry));
    }
    return result;
}

fn makeSourceMap(compiler: *c.JanetCompiler) c.JanetTuple {
    const tuple = c.janet_tuple_begin(3);
    tuple[0] = if (compiler.source != null) c.janet_wrap_string(compiler.source) else c.janet_wrap_nil();
    tuple[1] = wrapInteger(compiler.current_mapping.line);
    tuple[2] = wrapInteger(compiler.current_mapping.column);
    return c.janet_tuple_end(tuple);
}

fn newReferenceArray() raise.Raising(*c.JanetArray) {
    const reference = c.janet_array(1);
    try containers.arrayPush(reference, c.janet_wrap_nil());
    return reference;
}

fn symbolEquals(value: c.Janet, string: [*:0]const u8) bool {
    return c.janet_checktype(value, c.JANET_SYMBOL) != 0 and
        c.janet_cstrcmp(c.janet_unwrap_symbol(value), string) == 0;
}

fn tableGetKeyword(table: *c.JanetTable, keyword: [*:0]const u8) c.Janet {
    return c.janet_table_get(table, c.janet_ckeywordv(keyword));
}

fn quasiquote(options: c.JanetFopts, value: c.Janet, depth: i32, original_level: i32) raise.Raising(c.JanetSlot) {
    if (depth == 0) {
        c.janetc_cerror(options.compiler, "quasiquote too deeply nested");
        return nilSlot();
    }
    var slots: [*c]c.JanetSlot = null;
    var suboptions = options;
    suboptions.flags &= ~@as(u32, c.JANET_FOPTS_HINT);
    var level = original_level;

    switch (c.janet_type(value)) {
        c.JANET_TUPLE => {
            const tuple = c.janet_unwrap_tuple(value);
            const length = c.janet_tuple_length(tuple);
            if (length > 1 and c.janet_checktype(tuple[0], c.JANET_SYMBOL) != 0) {
                const head = c.janet_unwrap_symbol(tuple[0]);
                if (c.janet_cstrcmp(head, "unquote") == 0) {
                    if (level == 0) {
                        var unquote_options = c.janetc_fopts_default(options.compiler);
                        unquote_options.flags |= c.JANET_FOPTS_ACCEPT_SPLICE;
                        return try compiler_primitives.janetc_valueImpl(unquote_options, tuple[1]);
                    }
                    level -= 1;
                } else if (c.janet_cstrcmp(head, "quasiquote") == 0) {
                    level += 1;
                }
            }
            var index: i32 = 0;
            while (index < length) : (index += 1) {
                pushSlot(&slots, try quasiquote(suboptions, tuple[@intCast(index)], depth - 1, level));
            }
            const opcode = if (c.janet_tuple_head(tuple).*.gc.flags & c.JANET_TUPLE_FLAG_BRACKETCTOR != 0)
                c.JOP_MAKE_BRACKET_TUPLE
            else
                c.JOP_MAKE_TUPLE;
            return quoteSlots(options, slots, opcode);
        },
        c.JANET_ARRAY => {
            const array = c.janet_unwrap_array(value);
            var index: i32 = 0;
            while (index < array.*.count) : (index += 1) {
                pushSlot(&slots, try quasiquote(suboptions, array.*.data[@intCast(index)], depth - 1, level));
            }
            return quoteSlots(options, slots, c.JOP_MAKE_ARRAY);
        },
        c.JANET_TABLE, c.JANET_STRUCT => {
            var key_values: [*c]const c.JanetKV = null;
            var length: i32 = 0;
            var capacity: i32 = 0;
            _ = c.janet_dictionary_view(value, &key_values, &length, &capacity);
            var pair = c.janet_dictionary_next(key_values, capacity, null);
            while (pair != null) : (pair = c.janet_dictionary_next(key_values, capacity, pair)) {
                var key = try quasiquote(suboptions, pair.*.key, depth - 1, level);
                var pair_value = try quasiquote(suboptions, pair.*.value, depth - 1, level);
                key.flags &= ~@as(u32, c.JANET_SLOT_SPLICED);
                pair_value.flags &= ~@as(u32, c.JANET_SLOT_SPLICED);
                pushSlot(&slots, key);
                pushSlot(&slots, pair_value);
            }
            return quoteSlots(
                options,
                slots,
                if (c.janet_checktype(value, c.JANET_TABLE) != 0) c.JOP_MAKE_TABLE else c.JOP_MAKE_STRUCT,
            );
        },
        else => return c.janetc_cslot(value),
    }
}

fn quoteSlots(options: c.JanetFopts, slots: [*c]c.JanetSlot, opcode: c_int) c.JanetSlot {
    const target = c.janetc_gettarget(options);
    _ = c.janetc_pushslots(options.compiler, slots);
    c.janetc_freeslots(options.compiler, slots);
    _ = c.janetc_emit_s(options.compiler, @intCast(opcode), target, 1);
    return target;
}

fn compileSequence(
    options: c.JanetFopts,
    argument_count: i32,
    arguments: [*c]const c.Janet,
) raise.Raising(c.JanetSlot) {
    const compiler: *c.JanetCompiler = options.compiler;
    var result = nilSlot();
    var suboptions = c.janetc_fopts_default(compiler);
    var index: i32 = 0;
    while (index < argument_count) : (index += 1) {
        if (index != argument_count - 1) {
            suboptions.flags = c.JANET_FOPTS_DROP;
        } else {
            suboptions = options;
            suboptions.flags &= ~@as(u32, c.JANET_FOPTS_ACCEPT_SPLICE);
        }
        result = try compiler_primitives.janetc_valueImpl(suboptions, arguments[@intCast(index)]);
        if (index != argument_count - 1) c.janetc_freeslot(compiler, result);
    }
    return result;
}

fn nilSlot() c.JanetSlot {
    return c.janetc_cslot(c.janet_wrap_nil());
}

fn emitInstruction(compiler: *c.JanetCompiler, instruction: u32) void {
    _ = c.janetc_emit(compiler, @bitCast(instruction));
}

fn checkNilForm(value: c.Janet, capture: *c.Janet, function_tag: u32) bool {
    if (c.janet_checktype(value, c.JANET_TUPLE) == 0) return false;
    const tuple = c.janet_unwrap_tuple(value);
    if (c.janet_tuple_length(tuple) != 3) return false;
    if (c.janet_checktype(tuple[0], c.JANET_FUNCTION) == 0) return false;
    const function = c.janet_unwrap_function(tuple[0]);
    const flags: u32 = @bitCast(function.*.def.*.flags);
    if (flags & c.JANET_FUNCDEF_FLAG_TAG != function_tag) return false;
    if (c.janet_checktype(tuple[1], c.JANET_NIL) != 0) {
        capture.* = tuple[2];
        return true;
    }
    if (c.janet_checktype(tuple[2], c.JANET_NIL) != 0) {
        capture.* = tuple[1];
        return true;
    }
    return false;
}

fn checkJump16(compiler: *c.JanetCompiler, from: i32, to: i32) void {
    const distance = to - from;
    if (distance > std_max_i16 or distance < std_min_i16) {
        c.janetc_cerror(compiler, "bad 16-bit jump, too large");
    }
}

fn checkJump24(compiler: *c.JanetCompiler, from: i32, to: i32) void {
    const distance = to - from;
    if (distance > 0xffffff or distance < -0x1000000) {
        c.janetc_cerror(compiler, "bad 24-bit jump, too large");
    }
}

fn vectorCount(comptime Element: type, vector: [*c]Element) i32 {
    if (vector == null) return 0;
    const header: [*]i32 = @ptrFromInt(@intFromPtr(vector) - vector_header_size);
    return header[1];
}

fn vectorCapacity(comptime Element: type, vector: [*c]Element) i32 {
    const header: [*]i32 = @ptrFromInt(@intFromPtr(vector) - vector_header_size);
    return header[0];
}

fn pushSlot(slots: *[*c]c.JanetSlot, value: c.JanetSlot) void {
    pushVector(c.JanetSlot, slots, value);
}

fn pushVector(comptime Element: type, items: *[*c]Element, value: Element) void {
    var vector = items.*;
    const count = vectorCount(Element, vector);
    if (vector == null or count + 1 >= vectorCapacity(Element, vector)) {
        const opaque_vector: ?*anyopaque = if (vector == null) null else @ptrCast(vector);
        vector = @ptrCast(@alignCast(c.janet_v_grow(opaque_vector, 1, @sizeOf(Element))));
        items.* = vector;
    }
    vector[@intCast(count)] = value;
    const header: [*]i32 = @ptrFromInt(@intFromPtr(vector) - vector_header_size);
    header[1] = count + 1;
}

fn freeVector(comptime Element: type, vector: [*c]Element) void {
    if (vector == null) return;
    const raw: *anyopaque = @ptrFromInt(@intFromPtr(vector) - vector_header_size);
    c.janet_sfree(raw);
}

fn setVectorCount(comptime Element: type, vector: [*c]Element, count: i32) void {
    const header: [*]i32 = @ptrFromInt(@intFromPtr(vector) - vector_header_size);
    header[1] = count;
}

fn addFunctionDefinition(compiler: *c.JanetCompiler, definition: *c.JanetFuncDef) i32 {
    var scope = compiler.scope;
    while (scope != null and scope.*.flags & c.JANET_SCOPE_FUNCTION == 0) scope = scope.*.parent;
    const function_scope = scope orelse unreachable;
    pushVector([*c]c.JanetFuncDef, &function_scope.*.defs, definition);
    return vectorCount([*c]c.JanetFuncDef, function_scope.*.defs) - 1;
}

const std_max_i16 = 0x7fff;
const std_min_i16 = -0x8000;
const std_max_i32 = 0x7fffffff;
