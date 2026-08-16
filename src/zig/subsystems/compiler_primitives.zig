const c = @cImport({
    @cInclude("compile.h");
    @cInclude("emit.h");
    @cInclude("runtime.h");
    @cInclude("vector.h");
});

const vector_header_size = 2 * @sizeOf(i32);

comptime {
    @export(&farSlot, .{ .name = "janet_zig_farslot", .visibility = .hidden });
}

extern fn janet_c_compiler_wrap_nil() callconv(.c) c.Janet;
extern fn janet_c_compiler_unused_binding(compiler: *c.JanetCompiler, symbol: [*c]const u8) callconv(.c) void;
extern fn janet_c_compiler_assert(condition: c_int, message: [*:0]const u8) callconv(.c) void;
extern fn janet_c_compiler_shadow_lint(compiler: *c.JanetCompiler, symbol: [*c]const u8, shadowing: c.Shadowing) callconv(.c) void;
extern fn janet_c_compiler_resolve_global(compiler: *c.JanetCompiler, symbol: [*c]const u8, result: *c.JanetSlot) callconv(.c) void;
extern fn janet_c_compiler_dead_code(compiler: *c.JanetCompiler, value: c.Janet) callconv(.c) void;
extern fn janet_c_compiler_is_redef(environment: [*c]c.JanetTable) callconv(.c) c_int;
extern fn janet_c_compiler_run_macro(compiler: *c.JanetCompiler, value: c.Janet, macro_value: c.Janet, result: *c.Janet) callconv(.c) c_int;
extern fn janet_c_compiler_call_diagnostic(compiler: *c.JanetCompiler, kind: c_int, function: c.Janet, argument: c.Janet, expected: i32, got: i32) callconv(.c) void;

export fn janetc_fopts_default(compiler: *c.JanetCompiler) callconv(.c) c.JanetFopts {
    return .{
        .compiler = compiler,
        .hint = janetc_cslot(janet_c_compiler_wrap_nil()),
        .flags = 0,
    };
}

export fn janetc_error(compiler: *c.JanetCompiler, message: [*c]const u8) callconv(.c) void {
    if (compiler.result.status == c.JANET_COMPILE_ERROR) return;
    compiler.result.status = c.JANET_COMPILE_ERROR;
    compiler.result.@"error" = message;
}

export fn janetc_cerror(compiler: *c.JanetCompiler, message: [*c]const u8) callconv(.c) void {
    janetc_error(compiler, c.janet_cstring(message));
}

export fn janetc_freeslot(compiler: *c.JanetCompiler, slot: c.JanetSlot) callconv(.c) void {
    if (slot.flags & (c.JANET_SLOT_CONSTANT | c.JANET_SLOT_REF | c.JANET_SLOT_NAMED) != 0) return;
    if (slot.envindex >= 0) return;
    c.janetc_regalloc_free(&compiler.scope.*.ra, slot.index);
}

export fn janetc_shadowcheck(compiler: *c.JanetCompiler, symbol: [*c]const u8) callconv(.c) c.Shadowing {
    var scope = compiler.scope;
    const is_global = scope.*.flags & c.JANET_SCOPE_TOP != 0;
    while (scope != null) : (scope = scope.*.parent) {
        var index = vectorCount(c.SymPair, scope.*.syms);
        while (index > 0) {
            index -= 1;
            if (scope.*.syms[@intCast(index)].sym == symbol) {
                return if (is_global) c.JANETC_SHADOW_GLOBAL_HIDES_GLOBAL else c.JANETC_SHADOW_LOCAL_HIDES_LOCAL;
            }
        }
    }
    const binding = c.janet_resolve_ext(compiler.env, symbol);
    if (binding.type == c.JANET_BINDING_MACRO or binding.type == c.JANET_BINDING_DYNAMIC_MACRO)
        return c.JANETC_SHADOW_MACRO;
    if (binding.type == c.JANET_BINDING_NONE) return c.JANETC_SHADOW_NONE;
    return if (is_global) c.JANETC_SHADOW_GLOBAL_HIDES_GLOBAL else c.JANETC_SHADOW_LOCAL_HIDES_GLOBAL;
}

export fn janetc_nameslot(
    compiler: *c.JanetCompiler,
    symbol: [*c]const u8,
    slot: c.JanetSlot,
    flags: u32,
) callconv(.c) void {
    if (flags & c.JANET_DEFFLAG_NO_SHADOWCHECK == 0 and symbol[0] != '_') {
        janet_c_compiler_shadow_lint(compiler, symbol, janetc_shadowcheck(compiler, symbol));
    }
    const instruction_count = vectorCount(u32, compiler.buffer);
    var named_slot = slot;
    named_slot.flags |= c.JANET_SLOT_NAMED;
    pushVector(c.SymPair, &compiler.scope.*.syms, .{
        .slot = named_slot,
        .sym = symbol,
        .sym2 = symbol,
        .keep = 0,
        .referenced = if (flags & c.JANET_DEFFLAG_NO_UNUSED != 0 or symbol[0] == '_') 1 else 0,
        .birth_pc = @intCast(if (instruction_count != 0) instruction_count - 1 else 0),
        .death_pc = std_max_u32,
    });
}

export fn janetc_resolve(compiler: *c.JanetCompiler, symbol: [*c]const u8) callconv(.c) c.JanetSlot {
    var scope = compiler.scope;
    var found_pair: ?*c.SymPair = null;
    var found_local = true;
    var unused = false;

    search: while (scope != null) : (scope = scope.*.parent) {
        if (scope.*.flags & c.JANET_SCOPE_UNUSED != 0) unused = true;
        var index = vectorCount(c.SymPair, scope.*.syms);
        while (index > 0) {
            index -= 1;
            const pair = &scope.*.syms[@intCast(index)];
            if (pair.sym == symbol) {
                found_pair = pair;
                break :search;
            }
        }
        if (scope.*.flags & c.JANET_SCOPE_FUNCTION != 0) found_local = false;
    }

    const pair = found_pair orelse {
        var result: c.JanetSlot = undefined;
        janet_c_compiler_resolve_global(compiler, symbol, &result);
        return result;
    };
    var result = pair.slot;
    pair.referenced = 1;
    if (result.flags & (c.JANET_SLOT_CONSTANT | c.JANET_SLOT_REF) != 0) return result;
    if (unused or found_local) {
        result.envindex = -1;
        return result;
    }

    const original_scope = scope;
    pair.keep = 1;
    while (scope != null and scope.*.flags & c.JANET_SCOPE_FUNCTION == 0) scope = scope.*.parent;
    janet_c_compiler_assert(@intFromBool(scope != null), "invalid scopes");
    scope.*.flags |= c.JANET_SCOPE_ENV;
    c.janetc_regalloc_touch(&scope.*.ua, result.index);
    scope = scope.*.child;

    var environment_index: i32 = -1;
    while (scope != null) : (scope = scope.*.child) {
        if (scope.*.flags & c.JANET_SCOPE_FUNCTION == 0) continue;
        const environment_count = vectorCount(c.JanetEnvRef, scope.*.envs);
        var index: i32 = 0;
        var found = false;
        while (index < environment_count) : (index += 1) {
            if (scope.*.envs[@intCast(index)].envindex == environment_index) {
                found = true;
                environment_index = index;
                break;
            }
        }
        if (!found) {
            pushVector(c.JanetEnvRef, &scope.*.envs, .{
                .envindex = environment_index,
                .scope = original_scope,
            });
            environment_index = environment_count;
        }
    }
    result.envindex = environment_index;
    return result;
}

export fn janetc_cslot(value: c.Janet) callconv(.c) c.JanetSlot {
    const value_type: u5 = @intCast(c.janet_type(value));
    return .{
        .constant = value,
        .index = -1,
        .envindex = -1,
        .flags = (@as(u32, 1) << value_type) | c.JANET_SLOT_CONSTANT,
    };
}

fn farSlot(compiler: *c.JanetCompiler, result: *c.JanetSlot) callconv(.c) c_int {
    const register = c.janetc_regalloc_1(&compiler.scope.*.ra);
    if (register > 0xffff) return 0;
    result.* = .{
        .constant = janet_c_compiler_wrap_nil(),
        .index = register,
        .envindex = -1,
        .flags = c.JANET_SLOTTYPE_ANY,
    };
    return 1;
}

export fn janet_def_addflags(definition: *c.JanetFuncDef) callconv(.c) void {
    const controlled_flags = c.JANET_FUNCDEF_FLAG_HASNAME |
        c.JANET_FUNCDEF_FLAG_HASSOURCE |
        c.JANET_FUNCDEF_FLAG_HASDEFS |
        c.JANET_FUNCDEF_FLAG_HASENVS |
        c.JANET_FUNCDEF_FLAG_HASSOURCEMAP |
        c.JANET_FUNCDEF_FLAG_HASCLOBITSET |
        c.JANET_FUNCDEF_FLAG_NAMEDARGS;
    var present_flags: i32 = 0;
    if (definition.name != null) present_flags |= c.JANET_FUNCDEF_FLAG_HASNAME;
    if (definition.source != null) present_flags |= c.JANET_FUNCDEF_FLAG_HASSOURCE;
    if (definition.defs != null) present_flags |= c.JANET_FUNCDEF_FLAG_HASDEFS;
    if (definition.environments != null) present_flags |= c.JANET_FUNCDEF_FLAG_HASENVS;
    if (definition.sourcemap != null) present_flags |= c.JANET_FUNCDEF_FLAG_HASSOURCEMAP;
    if (definition.closure_bitset != null) present_flags |= c.JANET_FUNCDEF_FLAG_HASCLOBITSET;
    if (definition.named_args_count != 0) present_flags |= c.JANET_FUNCDEF_FLAG_NAMEDARGS;
    definition.flags = (definition.flags & ~controlled_flags) | present_flags;
}

export fn janetc_scope(
    result: *c.JanetScope,
    compiler: *c.JanetCompiler,
    flags: c_int,
    name: [*c]const u8,
) callconv(.c) void {
    var scope: c.JanetScope = undefined;
    scope.name = name;
    scope.parent = compiler.scope;
    scope.child = null;
    scope.consts = null;
    scope.syms = null;
    scope.defs = null;
    scope.envs = null;
    scope.bytecode_start = vectorCount(u32, compiler.buffer);
    scope.flags = flags;
    c.janetc_regalloc_init(&scope.ua);
    if (flags & c.JANET_SCOPE_FUNCTION == 0 and compiler.scope != null) {
        c.janetc_regalloc_clone(&scope.ra, &compiler.scope.*.ra);
    } else {
        c.janetc_regalloc_init(&scope.ra);
    }
    if (compiler.scope != null) compiler.scope.*.child = result;
    compiler.scope = result;
    result.* = scope;
}

export fn janetc_popscope(compiler: *c.JanetCompiler) callconv(.c) void {
    const old_scope = compiler.scope;
    const new_scope = old_scope.*.parent;
    if (old_scope.*.flags & (c.JANET_SCOPE_FUNCTION | c.JANET_SCOPE_UNUSED) == 0 and new_scope != null) {
        if (old_scope.*.flags & c.JANET_SCOPE_CLOSURE != 0) {
            new_scope.*.flags |= c.JANET_SCOPE_CLOSURE;
        }
        if (new_scope.*.ra.max < old_scope.*.ra.max) {
            new_scope.*.ra.max = old_scope.*.ra.max;
        }

        const symbol_count = vectorCount(c.SymPair, old_scope.*.syms);
        var index: i32 = 0;
        while (index < symbol_count) : (index += 1) {
            var pair = old_scope.*.syms[@intCast(index)];
            if (pair.referenced == 0 and pair.sym != null) {
                janet_c_compiler_unused_binding(compiler, pair.sym);
            }
            pair.sym = null;
            if (pair.death_pc == std_max_u32) {
                pair.death_pc = @intCast(vectorCount(u32, compiler.buffer));
            }
            if (pair.keep != 0) {
                pair.sym2 = null;
                c.janetc_regalloc_touch(&new_scope.*.ra, pair.slot.index);
            }
            pushVector(c.SymPair, &new_scope.*.syms, pair);
        }
    }

    freeVector(c.Janet, old_scope.*.consts);
    freeVector(c.SymPair, old_scope.*.syms);
    freeVector(c.JanetEnvRef, old_scope.*.envs);
    freeVector([*c]c.JanetFuncDef, old_scope.*.defs);
    c.janetc_regalloc_deinit(&old_scope.*.ra);
    c.janetc_regalloc_deinit(&old_scope.*.ua);
    if (new_scope != null) new_scope.*.child = null;
    compiler.scope = new_scope;
}

export fn janetc_popscope_keepslot(compiler: *c.JanetCompiler, return_slot: c.JanetSlot) callconv(.c) void {
    janetc_popscope(compiler);
    if (compiler.scope != null and return_slot.envindex < 0 and return_slot.index >= 0) {
        c.janetc_regalloc_touch(&compiler.scope.*.ra, return_slot.index);
    }
}

export fn janetc_return(compiler: *c.JanetCompiler, slot_value: c.JanetSlot) callconv(.c) c.JanetSlot {
    var result = slot_value;
    if (result.flags & c.JANET_SLOT_RETURNED == 0) {
        if (result.flags & c.JANET_SLOT_CONSTANT != 0 and c.janet_checktype(result.constant, c.JANET_NIL) != 0) {
            c.janetc_emit(compiler, @intCast(c.JOP_RETURN_NIL));
        } else {
            _ = c.janetc_emit_s(compiler, @intCast(c.JOP_RETURN), result, 0);
        }
        result.flags |= c.JANET_SLOT_RETURNED;
    }
    return result;
}

export fn janetc_gettarget(options: c.JanetFopts) callconv(.c) c.JanetSlot {
    if (options.flags & c.JANET_FOPTS_HINT != 0 and
        options.hint.envindex < 0 and
        options.hint.index >= 0 and
        options.hint.index <= 0xff)
    {
        return options.hint;
    }
    return .{
        .constant = janet_c_compiler_wrap_nil(),
        .index = c.janetc_allocfar(options.compiler),
        .envindex = -1,
        .flags = 0,
    };
}

export fn janetc_toslots(
    compiler: *c.JanetCompiler,
    values: [*c]const c.Janet,
    length: i32,
) callconv(.c) [*c]c.JanetSlot {
    var result: [*c]c.JanetSlot = null;
    var options = janetc_fopts_default(compiler);
    options.flags |= c.JANET_FOPTS_ACCEPT_SPLICE;
    var index: i32 = 0;
    while (index < length) : (index += 1) {
        pushVector(c.JanetSlot, &result, c.janetc_value(options, values[@intCast(index)]));
    }
    return result;
}

export fn janetc_toslotskv(compiler: *c.JanetCompiler, dictionary: c.Janet) callconv(.c) [*c]c.JanetSlot {
    var result: [*c]c.JanetSlot = null;
    var options = janetc_fopts_default(compiler);
    options.flags |= c.JANET_FOPTS_ACCEPT_SPLICE;
    var key_values: [*c]const c.JanetKV = null;
    var length: i32 = 0;
    var capacity: i32 = 0;
    _ = c.janet_dictionary_view(dictionary, &key_values, &length, &capacity);

    var stack_indices: [32]i32 = undefined;
    var heap_indices: ?[*]i32 = null;
    const indices: [*]i32 = if (length < stack_indices.len)
        &stack_indices
    else blk: {
        const memory = c.janet_smalloc(@sizeOf(i32) * @as(usize, @intCast(length))) orelse
            c.janet_zig_out_of_memory();
        const allocated: [*]i32 = @ptrCast(@alignCast(memory));
        heap_indices = allocated;
        break :blk allocated;
    };
    defer if (heap_indices) |allocated| c.janet_sfree(allocated);

    if (length != 0) _ = c.janet_sorted_keys(key_values, capacity, indices);
    var index: i32 = 0;
    while (index < length) : (index += 1) {
        const pair = key_values[@intCast(indices[@intCast(index)])];
        pushVector(c.JanetSlot, &result, c.janetc_value(options, pair.key));
        pushVector(c.JanetSlot, &result, c.janetc_value(options, pair.value));
    }
    return result;
}

export fn janetc_pushslots(compiler: *c.JanetCompiler, slots: [*c]c.JanetSlot) callconv(.c) i32 {
    const count = vectorCount(c.JanetSlot, slots);
    var index: i32 = 0;
    var minimum_arity: i32 = 0;
    var has_splice = false;
    while (index < count) {
        if (slots[@intCast(index)].flags & c.JANET_SLOT_SPLICED != 0) {
            _ = c.janetc_emit_s(compiler, @intCast(c.JOP_PUSH_ARRAY), slots[@intCast(index)], 0);
            index += 1;
            has_splice = true;
        } else if (index + 1 == count) {
            _ = c.janetc_emit_s(compiler, @intCast(c.JOP_PUSH), slots[@intCast(index)], 0);
            index += 1;
            minimum_arity += 1;
        } else if (slots[@intCast(index + 1)].flags & c.JANET_SLOT_SPLICED != 0) {
            _ = c.janetc_emit_s(compiler, @intCast(c.JOP_PUSH), slots[@intCast(index)], 0);
            _ = c.janetc_emit_s(compiler, @intCast(c.JOP_PUSH_ARRAY), slots[@intCast(index + 1)], 0);
            index += 2;
            minimum_arity += 1;
            has_splice = true;
        } else if (index + 2 == count) {
            _ = c.janetc_emit_ss(compiler, @intCast(c.JOP_PUSH_2), slots[@intCast(index)], slots[@intCast(index + 1)], 0);
            index += 2;
            minimum_arity += 2;
        } else if (slots[@intCast(index + 2)].flags & c.JANET_SLOT_SPLICED != 0) {
            _ = c.janetc_emit_ss(compiler, @intCast(c.JOP_PUSH_2), slots[@intCast(index)], slots[@intCast(index + 1)], 0);
            _ = c.janetc_emit_s(compiler, @intCast(c.JOP_PUSH_ARRAY), slots[@intCast(index + 2)], 0);
            index += 3;
            minimum_arity += 2;
            has_splice = true;
        } else {
            _ = c.janetc_emit_sss(
                compiler,
                @intCast(c.JOP_PUSH_3),
                slots[@intCast(index)],
                slots[@intCast(index + 1)],
                slots[@intCast(index + 2)],
                0,
            );
            index += 3;
            minimum_arity += 3;
        }
    }
    return if (has_splice) -1 - minimum_arity else minimum_arity;
}

export fn janetc_freeslots(compiler: *c.JanetCompiler, slots: [*c]c.JanetSlot) callconv(.c) void {
    const count = vectorCount(c.JanetSlot, slots);
    var index: i32 = 0;
    while (index < count) : (index += 1) janetc_freeslot(compiler, slots[@intCast(index)]);
    freeVector(c.JanetSlot, slots);
}

export fn janetc_throwaway(options: c.JanetFopts, value: c.Janet) callconv(.c) void {
    const compiler: *c.JanetCompiler = options.compiler;
    const bytecode_start = vectorCount(u32, compiler.buffer);
    const source_map_start = vectorCount(c.JanetSourceMapping, compiler.mapbuffer);
    var unused_scope: c.JanetScope = undefined;
    janetc_scope(&unused_scope, compiler, c.JANET_SCOPE_UNUSED, "unused");
    _ = c.janetc_value(options, value);
    janet_c_compiler_dead_code(compiler, value);
    janetc_popscope(compiler);
    if (compiler.buffer != null) {
        setVectorCount(u32, compiler.buffer, bytecode_start);
        if (compiler.mapbuffer != null) setVectorCount(c.JanetSourceMapping, compiler.mapbuffer, source_map_start);
    }
}

export fn janetc_value(options: c.JanetFopts, original_value: c.Janet) callconv(.c) c.JanetSlot {
    const compiler: *c.JanetCompiler = options.compiler;
    const previous_mapping = compiler.current_mapping;
    compiler.recursion_guard -= 1;
    if (compiler.result.status == c.JANET_COMPILE_ERROR) return janetc_cslot(janet_c_compiler_wrap_nil());
    if (compiler.recursion_guard <= 0) {
        c.janetc_cerror(compiler, "recursed too deeply");
        return janetc_cslot(janet_c_compiler_wrap_nil());
    }

    var value = original_value;
    var result: c.JanetSlot = undefined;
    var special: ?*const c.JanetSpecial = null;
    var expansions: i32 = c.JANET_MAX_MACRO_EXPAND;
    while (expansions != 0 and
        compiler.result.status != c.JANET_COMPILE_ERROR and
        expandMacroOnce(compiler, value, &value, &special))
    {
        expansions -= 1;
    }
    if (expansions == 0) {
        c.janetc_cerror(compiler, "recursed too deeply in macro expansion");
        return janetc_cslot(janet_c_compiler_wrap_nil());
    }

    if (special) |special_form| {
        const tuple = c.janet_unwrap_tuple(value);
        result = special_form.*.compile.?(options, c.janet_tuple_length(tuple) - 1, tuple + 1);
    } else {
        switch (c.janet_type(value)) {
            c.JANET_TUPLE => {
                const tuple = c.janet_unwrap_tuple(value);
                const length = c.janet_tuple_length(tuple);
                if (length == 0) {
                    result = janetc_cslot(c.janet_wrap_tuple(c.janet_tuple_n(null, 0)));
                } else if (c.janet_tuple_flag(tuple) & c.JANET_TUPLE_FLAG_BRACKETCTOR != 0) {
                    result = makeTuple(options, value);
                } else {
                    var suboptions = janetc_fopts_default(compiler);
                    const function = janetc_value(suboptions, tuple[0]);
                    suboptions.flags = c.JANET_FUNCTION | c.JANET_CFUNCTION;
                    result = compileCall(
                        options,
                        janetc_toslots(compiler, tuple + 1, length - 1),
                        function,
                        tuple,
                    );
                    janetc_freeslot(compiler, function);
                }
                result.flags &= ~@as(u32, c.JANET_SLOT_SPLICED);
            },
            c.JANET_SYMBOL => result = janetc_resolve(compiler, c.janet_unwrap_symbol(value)),
            c.JANET_ARRAY => result = makeArray(options, value),
            c.JANET_STRUCT => result = makeDictionary(options, value, c.JOP_MAKE_STRUCT),
            c.JANET_TABLE => result = makeDictionary(options, value, c.JOP_MAKE_TABLE),
            c.JANET_BUFFER => result = makeBuffer(options, value),
            else => result = janetc_cslot(value),
        }
    }

    if (compiler.result.status == c.JANET_COMPILE_ERROR) return janetc_cslot(janet_c_compiler_wrap_nil());
    if (options.flags & c.JANET_FOPTS_TAIL != 0) result = janetc_return(compiler, result);
    if (options.flags & c.JANET_FOPTS_HINT != 0) {
        c.janetc_copy(compiler, options.hint, result);
        result = options.hint;
    }
    compiler.current_mapping = previous_mapping;
    compiler.recursion_guard += 1;
    return result;
}

fn expandMacroOnce(
    compiler: *c.JanetCompiler,
    value: c.Janet,
    result: *c.Janet,
    special: *?*const c.JanetSpecial,
) bool {
    if (c.janet_checktype(value, c.JANET_TUPLE) == 0) return false;
    const form = c.janet_unwrap_tuple(value);
    const length = c.janet_tuple_length(form);
    if (length == 0) return false;

    const head = c.janet_tuple_head(form);
    if (head.*.sm_line >= 0) {
        compiler.current_mapping.line = head.*.sm_line;
        compiler.current_mapping.column = head.*.sm_column;
    }
    if (head.*.gc.flags & c.JANET_TUPLE_FLAG_BRACKETCTOR != 0) return false;
    if (c.janet_checktype(form[0], c.JANET_SYMBOL) == 0) return false;

    const name = c.janet_unwrap_symbol(form[0]);
    special.* = c.janetc_special(name);
    if (special.* != null) return false;

    var macro_value: c.Janet = undefined;
    const binding_type = c.janet_resolve(compiler.env, name, &macro_value);
    if ((binding_type != c.JANET_BINDING_MACRO and binding_type != c.JANET_BINDING_DYNAMIC_MACRO) or
        c.janet_checktype(macro_value, c.JANET_FUNCTION) == 0)
    {
        return false;
    }
    return janet_c_compiler_run_macro(compiler, value, macro_value, result) != 0;
}

fn compileCall(
    options: c.JanetFopts,
    slots: [*c]c.JanetSlot,
    function: c.JanetSlot,
    form: [*c]const c.Janet,
) c.JanetSlot {
    const compiler: *c.JanetCompiler = options.compiler;
    var result: c.JanetSlot = undefined;
    if (!tryCallOptimizer(options, slots, function, &result)) {
        const minimum_arity = janetc_pushslots(compiler, slots);
        validateCall(compiler, function, minimum_arity, form);
        if (options.flags & c.JANET_FOPTS_TAIL != 0 and compiler.scope.*.flags & c.JANET_SCOPE_TOP == 0) {
            _ = c.janetc_emit_s(compiler, @intCast(c.JOP_TAILCALL), function, 0);
            result = janetc_cslot(janet_c_compiler_wrap_nil());
            result.flags = c.JANET_SLOT_RETURNED;
        } else {
            result = janetc_gettarget(options);
            _ = c.janetc_emit_ss(compiler, @intCast(c.JOP_CALL), result, function, 1);
        }
    }
    janetc_freeslots(compiler, slots);
    return result;
}

fn tryCallOptimizer(
    options: c.JanetFopts,
    slots: [*c]c.JanetSlot,
    function: c.JanetSlot,
    result: *c.JanetSlot,
) bool {
    if (function.flags & c.JANET_SLOT_CONSTANT == 0) return false;
    const slot_count = vectorCount(c.JanetSlot, slots);
    var index: i32 = 0;
    while (index < slot_count) : (index += 1) {
        if (slots[@intCast(index)].flags & c.JANET_SLOT_SPLICED != 0) return false;
    }
    if (c.janet_checktype(function.constant, c.JANET_FUNCTION) == 0) return false;
    const function_value = c.janet_unwrap_function(function.constant);
    const optimizer = c.janetc_funopt(@bitCast(function_value.*.def.*.flags)) orelse return false;
    if (optimizer.*.can_optimize) |can_optimize| {
        if (can_optimize(options, slots) == 0) return false;
    }
    result.* = optimizer.*.optimize.?(options, slots);
    return true;
}

fn validateCall(
    compiler: *c.JanetCompiler,
    function: c.JanetSlot,
    original_minimum_arity: i32,
    form: [*c]const c.Janet,
) void {
    if (function.flags & c.JANET_SLOT_CONSTANT == 0) return;
    var minimum_arity = original_minimum_arity;
    const nil = janet_c_compiler_wrap_nil();

    switch (c.janet_type(function.constant)) {
        c.JANET_FUNCTION => {
            const function_value = c.janet_unwrap_function(function.constant);
            const definition = function_value.*.def;
            const minimum = definition.*.min_arity;
            const maximum = definition.*.max_arity;
            const flags: u32 = @bitCast(definition.*.flags);
            const has_struct_argument = flags & c.JANET_FUNCDEF_FLAG_STRUCTARG != 0;
            const has_named_arguments = flags & c.JANET_FUNCDEF_FLAG_NAMEDARGS != 0;

            if (minimum_arity < 0) {
                minimum_arity = -1 - minimum_arity;
                if (maximum >= 0 and minimum_arity > maximum) {
                    janet_c_compiler_call_diagnostic(compiler, 1, function.constant, nil, maximum, minimum_arity);
                }
                return;
            }
            if (maximum >= 0 and minimum_arity > maximum) {
                janet_c_compiler_call_diagnostic(compiler, 0, function.constant, nil, maximum, minimum_arity);
            }
            if (minimum_arity < minimum) {
                janet_c_compiler_call_diagnostic(compiler, 2, function.constant, nil, minimum, minimum_arity);
            }
            if (has_struct_argument and
                minimum_arity > definition.*.arity and
                (minimum_arity - definition.*.arity) & 1 != 0)
            {
                janet_c_compiler_call_diagnostic(
                    compiler,
                    if (has_named_arguments) 4 else 3,
                    function.constant,
                    nil,
                    0,
                    0,
                );
            }
            if (has_named_arguments and definition.*.named_args_count > 0) {
                var argument_index = definition.*.arity + 1;
                const form_length = c.janet_tuple_length(form);
                while (argument_index < form_length) : (argument_index += 2) {
                    const argument_key = form[@intCast(argument_index)];
                    var found = false;
                    if (c.janet_checktype(argument_key, c.JANET_KEYWORD) != 0) {
                        var named_index: i32 = 0;
                        while (named_index < definition.*.named_args_count and
                            named_index < definition.*.constants_length) : (named_index += 1)
                        {
                            if (c.janet_equals(argument_key, definition.*.constants[@intCast(named_index)]) != 0) {
                                found = true;
                                break;
                            }
                        }
                    } else if (c.janet_checktype(argument_key, c.JANET_TUPLE) != 0) {
                        found = true;
                    }
                    if (!found) {
                        janet_c_compiler_call_diagnostic(
                            compiler,
                            5,
                            function.constant,
                            argument_key,
                            0,
                            0,
                        );
                    }
                }
            }
        },
        c.JANET_CFUNCTION, c.JANET_ABSTRACT, c.JANET_NIL => {},
        c.JANET_KEYWORD => {
            if (minimum_arity == 0) {
                janet_c_compiler_call_diagnostic(compiler, 6, function.constant, nil, 0, 0);
            }
        },
        else => {
            if (minimum_arity > 1 or minimum_arity == 0) {
                janet_c_compiler_call_diagnostic(compiler, 7, function.constant, nil, 0, minimum_arity);
            }
            if (minimum_arity < -2) {
                janet_c_compiler_call_diagnostic(compiler, 8, function.constant, nil, 0, -1 - minimum_arity);
            }
        },
    }
}

fn makeValue(options: c.JanetFopts, slots: [*c]c.JanetSlot, operation: c_int) c.JanetSlot {
    const compiler: *c.JanetCompiler = options.compiler;
    const count = vectorCount(c.JanetSlot, slots);
    var can_inline = true;
    var index: i32 = 0;
    while (index < count) : (index += 1) {
        if (slots[@intCast(index)].flags & c.JANET_SLOT_CONSTANT == 0 or
            slots[@intCast(index)].flags & c.JANET_SLOT_SPLICED != 0)
        {
            can_inline = false;
            break;
        }
    }

    if (can_inline and operation == c.JOP_MAKE_STRUCT) {
        const structure = c.janet_struct_begin(@divTrunc(count, 2));
        index = 0;
        while (index < count) : (index += 2) {
            c.janet_struct_put(structure, slots[@intCast(index)].constant, slots[@intCast(index + 1)].constant);
        }
        const result = janetc_cslot(c.janet_wrap_struct(c.janet_struct_end(structure)));
        janetc_freeslots(compiler, slots);
        return result;
    }
    if (can_inline and operation == c.JOP_MAKE_TUPLE) {
        const tuple = c.janet_tuple_begin(count);
        index = 0;
        while (index < count) : (index += 1) tuple[@intCast(index)] = slots[@intCast(index)].constant;
        const result = janetc_cslot(c.janet_wrap_tuple(c.janet_tuple_end(tuple)));
        janetc_freeslots(compiler, slots);
        return result;
    }

    _ = janetc_pushslots(compiler, slots);
    janetc_freeslots(compiler, slots);
    const result = janetc_gettarget(options);
    _ = c.janetc_emit_s(compiler, @intCast(operation), result, 1);
    return result;
}

fn makeArray(options: c.JanetFopts, value: c.Janet) c.JanetSlot {
    const compiler: *c.JanetCompiler = options.compiler;
    const array = c.janet_unwrap_array(value);
    return makeValue(options, janetc_toslots(compiler, array.*.data, array.*.count), c.JOP_MAKE_ARRAY);
}

fn makeTuple(options: c.JanetFopts, value: c.Janet) c.JanetSlot {
    const compiler: *c.JanetCompiler = options.compiler;
    const tuple = c.janet_unwrap_tuple(value);
    return makeValue(options, janetc_toslots(compiler, tuple, c.janet_tuple_length(tuple)), c.JOP_MAKE_TUPLE);
}

fn makeDictionary(options: c.JanetFopts, value: c.Janet, operation: c_int) c.JanetSlot {
    const compiler: *c.JanetCompiler = options.compiler;
    return makeValue(options, janetc_toslotskv(compiler, value), operation);
}

fn makeBuffer(options: c.JanetFopts, value: c.Janet) c.JanetSlot {
    const compiler: *c.JanetCompiler = options.compiler;
    const buffer = c.janet_unwrap_buffer(value);
    const argument = c.janet_stringv(buffer.*.data, buffer.*.count);
    return makeValue(options, janetc_toslots(compiler, &argument, 1), c.JOP_MAKE_BUFFER);
}

export fn janetc_pop_funcdef(compiler: *c.JanetCompiler) callconv(.c) [*c]c.JanetFuncDef {
    const scope = compiler.scope;
    const definition = c.janet_funcdef_alloc();
    definition.*.slotcount = scope.*.ra.max + 1;
    janet_c_compiler_assert(@intFromBool(scope.*.flags & c.JANET_SCOPE_FUNCTION != 0), "expected function scope");

    definition.*.environments_length = vectorCount(c.JanetEnvRef, scope.*.envs);
    definition.*.environments = mallocArray(i32, definition.*.environments_length);
    var index: i32 = 0;
    while (index < definition.*.environments_length) : (index += 1) {
        definition.*.environments[@intCast(index)] = scope.*.envs[@intCast(index)].envindex;
    }

    definition.*.constants_length = vectorCount(c.Janet, scope.*.consts);
    definition.*.constants = flattenVector(c.Janet, scope.*.consts);
    definition.*.defs_length = vectorCount([*c]c.JanetFuncDef, scope.*.defs);
    definition.*.defs = flattenVector([*c]c.JanetFuncDef, scope.*.defs);

    definition.*.bytecode_length = vectorCount(u32, compiler.buffer) - scope.*.bytecode_start;
    if (definition.*.bytecode_length != 0) {
        definition.*.bytecode = mallocArray(u32, definition.*.bytecode_length);
        const bytecode_length: usize = @intCast(definition.*.bytecode_length);
        @memcpy(definition.*.bytecode[0..bytecode_length], compiler.buffer[@intCast(scope.*.bytecode_start)..][0..bytecode_length]);
        setVectorCount(u32, compiler.buffer, scope.*.bytecode_start);

        if (compiler.mapbuffer != null and compiler.source != null) {
            definition.*.sourcemap = mallocArray(c.JanetSourceMapping, definition.*.bytecode_length);
            @memcpy(definition.*.sourcemap[0..bytecode_length], compiler.mapbuffer[@intCast(scope.*.bytecode_start)..][0..bytecode_length]);
            setVectorCount(c.JanetSourceMapping, compiler.mapbuffer, scope.*.bytecode_start);
        }
    }

    definition.*.source = compiler.source;
    definition.*.arity = 0;
    definition.*.min_arity = 0;
    definition.*.flags = 0;
    if (scope.*.flags & c.JANET_SCOPE_ENV != 0) definition.*.flags |= c.JANET_FUNCDEF_FLAG_NEEDSENV;

    if (scope.*.ua.count != 0) {
        const slot_chunks = @divTrunc(definition.*.slotcount + 31, 32);
        const chunk_count = @min(slot_chunks, scope.*.ua.count);
        const memory = c.janet_calloc(@intCast(slot_chunks), @sizeOf(u32)) orelse c.janet_zig_out_of_memory();
        const chunks: [*]u32 = @ptrCast(@alignCast(memory));
        @memcpy(chunks[0..@intCast(chunk_count)], scope.*.ua.chunks[0..@intCast(chunk_count)]);
        if (scope.*.ua.count > 7 and slot_chunks > 7) chunks[7] &= 0xffff;
        definition.*.closure_bitset = chunks;
    }

    var locals: [*c]c.JanetSymbolMap = null;
    var top = compiler.scope;
    while (top.*.parent != null) top = top.*.parent;
    var ancestor = top;
    while (ancestor != null) : (ancestor = ancestor.*.child) {
        const environment_count = vectorCount(c.JanetEnvRef, scope.*.envs);
        var environment_index: i32 = 0;
        while (environment_index < environment_count) : (environment_index += 1) {
            const reference = scope.*.envs[@intCast(environment_index)];
            if (reference.scope != ancestor) continue;
            const symbol_count = vectorCount(c.SymPair, ancestor.*.syms);
            var symbol_index: i32 = 0;
            while (symbol_index < symbol_count) : (symbol_index += 1) {
                const pair = ancestor.*.syms[@intCast(symbol_index)];
                if (pair.sym2 != null) pushVector(c.JanetSymbolMap, &locals, .{
                    .birth_pc = std_max_u32,
                    .death_pc = @intCast(environment_index),
                    .slot_index = @intCast(pair.slot.index),
                    .symbol = pair.sym2,
                });
            }
        }
    }

    const symbol_count = vectorCount(c.SymPair, scope.*.syms);
    index = 0;
    while (index < symbol_count) : (index += 1) {
        const pair = scope.*.syms[@intCast(index)];
        if (pair.sym2 == null) continue;
        if (pair.referenced == 0 and pair.sym != null) janet_c_compiler_unused_binding(compiler, pair.sym);
        const death_pc: u32 = if (pair.death_pc == std_max_u32)
            @intCast(definition.*.bytecode_length)
        else
            pair.death_pc - @as(u32, @intCast(scope.*.bytecode_start));
        const birth_pc: u32 = if (@as(u32, @intCast(scope.*.bytecode_start)) > pair.birth_pc)
            0
        else
            pair.birth_pc - @as(u32, @intCast(scope.*.bytecode_start));
        janet_c_compiler_assert(@intFromBool(birth_pc <= death_pc), "birth pc after death pc");
        janet_c_compiler_assert(
            @intFromBool(birth_pc < @as(u32, @intCast(definition.*.bytecode_length))),
            "bad birth pc",
        );
        janet_c_compiler_assert(
            @intFromBool(death_pc <= @as(u32, @intCast(definition.*.bytecode_length))),
            "bad death pc",
        );
        pushVector(c.JanetSymbolMap, &locals, .{
            .birth_pc = birth_pc,
            .death_pc = death_pc,
            .slot_index = @intCast(pair.slot.index),
            .symbol = pair.sym2,
        });
    }
    definition.*.symbolmap_length = vectorCount(c.JanetSymbolMap, locals);
    definition.*.symbolmap = flattenVector(c.JanetSymbolMap, locals);
    if (definition.*.symbolmap_length != 0) definition.*.flags |= c.JANET_FUNCDEF_FLAG_HASSYMBOLMAP;

    janetc_popscope(compiler);
    c.janet_bytecode_movopt(definition);
    c.janet_bytecode_remove_noops(definition);
    return definition;
}

export fn janet_compile_lint(
    source: c.Janet,
    environment: [*c]c.JanetTable,
    where: c.JanetString,
    lints: [*c]c.JanetArray,
) callconv(.c) c.JanetCompileResult {
    var compiler: c.JanetCompiler = undefined;
    initCompiler(&compiler, environment, where, lints);

    var root_scope: c.JanetScope = undefined;
    janetc_scope(&root_scope, &compiler, c.JANET_SCOPE_FUNCTION | c.JANET_SCOPE_TOP, "root");
    const options = c.JanetFopts{
        .compiler = &compiler,
        .hint = janetc_cslot(janet_c_compiler_wrap_nil()),
        .flags = c.JANET_FOPTS_TAIL | c.JANET_SLOTTYPE_ANY,
    };
    _ = janetc_value(options, source);

    if (compiler.result.status == c.JANET_COMPILE_OK) {
        const definition = janetc_pop_funcdef(&compiler);
        definition.*.name = c.janet_cstring("thunk");
        janet_def_addflags(definition);
        compiler.result.funcdef = definition;
    } else {
        compiler.result.error_mapping = compiler.current_mapping;
        janetc_popscope(&compiler);
    }
    deinitCompiler(&compiler);
    return compiler.result;
}

export fn janet_compile(
    source: c.Janet,
    environment: [*c]c.JanetTable,
    where: c.JanetString,
) callconv(.c) c.JanetCompileResult {
    return janet_compile_lint(source, environment, where, null);
}

fn initCompiler(
    compiler: *c.JanetCompiler,
    environment: [*c]c.JanetTable,
    where: c.JanetString,
    lints: [*c]c.JanetArray,
) void {
    compiler.* = .{
        .scope = null,
        .buffer = null,
        .mapbuffer = null,
        .env = environment,
        .source = where,
        .result = .{
            .funcdef = null,
            .@"error" = null,
            .macrofiber = null,
            .error_mapping = .{ .line = -1, .column = -1 },
            .status = c.JANET_COMPILE_OK,
        },
        .current_mapping = .{ .line = -1, .column = -1 },
        .recursion_guard = c.JANET_RECURSION_GUARD,
        .lints = lints,
        .is_redef = janet_c_compiler_is_redef(environment),
    };
}

fn deinitCompiler(compiler: *c.JanetCompiler) void {
    freeVector(u32, compiler.buffer);
    freeVector(c.JanetSourceMapping, compiler.mapbuffer);
    compiler.env = null;
}

fn pushVector(comptime Element: type, vector_pointer: *[*c]Element, value: Element) void {
    var vector = vector_pointer.*;
    const count = vectorCount(Element, vector);
    if (vector == null or count + 1 >= vectorCapacity(Element, vector)) {
        vector = @ptrCast(@alignCast(c.janet_v_grow(vector, 1, @sizeOf(Element))));
        vector_pointer.* = vector;
    }
    vector[@intCast(count)] = value;
    vectorHeader(Element, vector)[1] = count + 1;
}

fn freeVector(comptime Element: type, vector: [*c]Element) void {
    if (vector != null) c.janet_sfree(vectorHeader(Element, vector));
}

fn flattenVector(comptime Element: type, vector: [*c]Element) [*c]Element {
    const opaque_vector: ?*anyopaque = if (vector == null) null else @ptrCast(vector);
    const memory = c.janet_v_flattenmem(opaque_vector, @sizeOf(Element));
    return @ptrCast(@alignCast(memory));
}

fn mallocArray(comptime Element: type, count: i32) [*c]Element {
    const size = @sizeOf(Element) * @as(usize, @intCast(count));
    const memory = c.janet_malloc(size);
    if (memory == null and size != 0) c.janet_zig_out_of_memory();
    return @ptrCast(@alignCast(memory));
}

fn setVectorCount(comptime Element: type, vector: [*c]Element, count: i32) void {
    vectorHeader(Element, vector)[1] = count;
}

fn vectorCount(comptime Element: type, vector: [*c]Element) i32 {
    return if (vector == null) 0 else vectorHeader(Element, vector)[1];
}

fn vectorCapacity(comptime Element: type, vector: [*c]Element) i32 {
    return vectorHeader(Element, vector)[0];
}

fn vectorHeader(comptime Element: type, vector: [*c]Element) [*]i32 {
    return @ptrFromInt(@intFromPtr(vector) - vector_header_size);
}

const std_max_u32 = ~@as(u32, 0);
