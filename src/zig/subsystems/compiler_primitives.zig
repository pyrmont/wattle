const std = @import("std");
const abi = @import("abi");
const corefn = @import("corefn");
const c = abi.c;
const specials = @import("special.zig");
const lifecycle = @import("lifecycle.zig");
const containers = @import("containers.zig");
const raise = @import("raise");
const pp_format = @import("pp_format.zig");
const arglayer = @import("arglayer.zig");

const vector_header_size = 2 * @sizeOf(i32);

/// `janet_wrap_nil`, and `janet_wrap_integer` written out.
///
/// Both were one-line C functions in `compile.c` until Phase 10 Part 7,
/// because this subsystem translated only `compile.h` and `emit.h`. Sharing
/// `abi.zig` removes the detour; `wrapInteger` stays spelled out because
/// `janet_wrap_integer` is a macro under nanboxing and a symbol `wrap.c`
/// never defines there.
inline fn wrapNil() c.Janet {
    return c.janet_wrap_nil();
}

inline fn wrapInteger(value: i32) c.Janet {
    return c.janet_wrap_number(@floatFromInt(value));
}

// ==========================================================================
// Lints
//
// A lint is a note the compiler files against a program it is willing to
// compile anyway: a shadowed binding, a deprecated name, unreachable code.
// They go into `c->lints` when the caller asked for them and are dropped
// otherwise.
//
// **The C original is variadic, and this one is not.** Phase 10 Part 4
// established that a variadic entry point is the one shape that cannot be
// ported at all, because Zig 0.16 cannot name a `va_list` on `aarch64-linux`.
// That rule survives, but Part 7 finds its edge: it binds where the variadic
// *signature* is the contract -- `janet_panicf` and `janet_dynprintf` are
// public API and an embedder's call has to keep compiling. `janetc_lintf` is
// declared in `compile.h`, is called from nowhere but the compiler front end,
// and after this increment every one of those callers is Zig. So it does not
// have to stay variadic; it just has to stop being called by C, and then the
// argument list can be an ordinary Zig tuple that the compiler counts and
// type-checks.
//
// Zig can *call* a C variadic perfectly well -- only defining one and
// consuming a `va_list` are out of reach -- so the message itself still goes
// through `janet_formatc`, and `%q`, `%v` and `%.4q` mean exactly what they
// did.
// ==========================================================================

const LintLevel = enum(c_uint) {
    relaxed = c.JANET_C_LINT_RELAXED,
    normal = c.JANET_C_LINT_NORMAL,
    strict = c.JANET_C_LINT_STRICT,

    fn keyword(self: LintLevel) [*c]const u8 {
        return switch (self) {
            .relaxed => "relaxed",
            .normal => "normal",
            .strict => "strict",
        };
    }
};

/// File a lint, formatting the message only if anyone is listening.
///
/// The `lints == null` test comes first for the reason it does in C:
/// `janet_formatc` allocates, an allocation can collect, and a build that
/// asked for no lints should pay for none of that.
fn lintf(
    compiler: *c.JanetCompiler,
    level: LintLevel,
    comptime format: [:0]const u8,
    args: anytype,
) raise.Raising(void) {
    if (compiler.lints == null) return;
    try record(compiler, level, try pp_format.formatc(format, args));
}

/// The same, for a lint with nothing to interpolate and for a caller in
/// another subsystem object.
///
/// `specials_core.zig` is the only one, and it is why `compile.h` keeps a lint
/// declaration at all: a subsystem seam is the C ABI, so it cannot reach
/// `lintf` above however simple the call is. The C string is interned *after*
/// the test, so a build collecting no lints still allocates nothing -- which
/// is the behaviour `janetc_lintf` had and the reason its test came first.
pub fn janetc_lintImpl(
    compiler: *c.JanetCompiler,
    level: c_uint,
    message: [*c]const u8,
) raise.Raising(void) {
    if (compiler.lints == null) return;
    try record(compiler, @enumFromInt(level), c.janet_cstring(message));
}

export fn janetc_lint(
    compiler: *c.JanetCompiler,
    level: c_uint,
    message: [*c]const u8,
) callconv(.c) void {
    raise.reported(janetc_lintImpl(compiler, level, message));
}

/// Append one finished lint, tagged with the level and the form's position.
///
/// A line or column of -1 means the source had no mapping there, and becomes
/// nil rather than -1 in the tuple.
fn record(compiler: *c.JanetCompiler, level: LintLevel, message: [*c]const u8) raise.Raising(void) {
    const payload = c.janet_tuple_begin(4);
    payload[0] = c.janet_ckeywordv(level.keyword());
    payload[1] = if (compiler.current_mapping.line == -1) wrapNil() else wrapInteger(compiler.current_mapping.line);
    payload[2] = if (compiler.current_mapping.column == -1) wrapNil() else wrapInteger(compiler.current_mapping.column);
    payload[3] = c.janet_wrap_string(message);
    try containers.arrayPush(compiler.lints, c.janet_wrap_tuple(c.janet_tuple_end(payload)));
}

export fn janetc_fopts_default(compiler: *c.JanetCompiler) callconv(.c) c.JanetFopts {
    return .{
        .compiler = compiler,
        .hint = janetc_cslot(wrapNil()),
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

pub fn janetc_nameslotImpl(
    compiler: *c.JanetCompiler,
    symbol: [*c]const u8,
    slot: c.JanetSlot,
    flags: u32,
) raise.Raising(void) {
    if (flags & c.JANET_DEFFLAG_NO_SHADOWCHECK == 0 and symbol[0] != '_') {
        try shadowLint(compiler, symbol, janetc_shadowcheck(compiler, symbol));
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

export fn janetc_nameslot(
    compiler: *c.JanetCompiler,
    symbol: [*c]const u8,
    slot: c.JanetSlot,
    flags: u32,
) callconv(.c) void {
    raise.reported(janetc_nameslotImpl(compiler, symbol, slot, flags));
}

pub fn janetc_resolveImpl(compiler: *c.JanetCompiler, symbol: [*c]const u8) raise.Raising(c.JanetSlot) {
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
        try resolveGlobal(compiler, symbol, &result);
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
    compilerAssert(@intFromBool(scope != null), "invalid scopes");
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

export fn janetc_resolve(compiler: *c.JanetCompiler, symbol: [*c]const u8) callconv(.c) c.JanetSlot {
    return raise.reported(janetc_resolveImpl(compiler, symbol));
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

/// A fresh far slot, or an error recorded on the compiler.
///
/// Until Phase 10 Part 7 the allocation was here and the error was in
/// `compile.c`, because an error union cannot cross a subsystem seam and this
/// one reported through a returned flag. With the callers in Zig there is no
/// seam left to report across. On failure the slot is returned uninitialised,
/// exactly as the C original left it: the compile has already failed, and
/// every caller is on its way out.
export fn janetc_farslot(compiler: *c.JanetCompiler) callconv(.c) c.JanetSlot {
    const register = c.janetc_regalloc_1(&compiler.scope.*.ra);
    if (register > 0xffff) {
        c.janetc_cerror(compiler, "ran out of internal registers");
        return undefined;
    }
    return .{
        .constant = wrapNil(),
        .index = register,
        .envindex = -1,
        .flags = c.JANET_SLOTTYPE_ANY,
    };
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

pub fn janetc_popscopeImpl(compiler: *c.JanetCompiler) raise.Raising(void) {
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
                try lintf(compiler, .strict, "binding %q is unused", .{c.janet_wrap_symbol(pair.sym)});
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

export fn janetc_popscope(compiler: *c.JanetCompiler) callconv(.c) void {
    raise.reported(janetc_popscopeImpl(compiler));
}

export fn janetc_popscope_keepslot(compiler: *c.JanetCompiler, return_slot: c.JanetSlot) callconv(.c) void {
    raise.reported(janetc_popscopeImpl(compiler));
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
        .constant = wrapNil(),
        .index = c.janetc_allocfar(options.compiler),
        .envindex = -1,
        .flags = 0,
    };
}

pub fn janetc_toslotsImpl(
    compiler: *c.JanetCompiler,
    values: [*c]const c.Janet,
    length: i32,
) raise.Raising([*c]c.JanetSlot) {
    var result: [*c]c.JanetSlot = null;
    var options = janetc_fopts_default(compiler);
    options.flags |= c.JANET_FOPTS_ACCEPT_SPLICE;
    var index: i32 = 0;
    while (index < length) : (index += 1) {
        pushVector(c.JanetSlot, &result, try janetc_valueImpl(options, values[@intCast(index)]));
    }
    return result;
}

export fn janetc_toslots(
    compiler: *c.JanetCompiler,
    values: [*c]const c.Janet,
    length: i32,
) callconv(.c) [*c]c.JanetSlot {
    return raise.reported(janetc_toslotsImpl(compiler, values, length));
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
    if (length != 0) _ = c.janet_sorted_keys(key_values, capacity, indices);
    var index: i32 = 0;
    while (index < length) : (index += 1) {
        const pair = key_values[@intCast(indices[@intCast(index)])];
        pushVector(c.JanetSlot, &result, raise.reported(janetc_valueImpl(options, pair.key)));
        pushVector(c.JanetSlot, &result, raise.reported(janetc_valueImpl(options, pair.value)));
    }
    // This was a `defer` until Phase 10 Part 7 gave the file its
    // `//! jump-transparent` marker, and the marker is what makes the
    // difference visible rather than what creates it: `janetc_value` above
    // reaches a lint, an error message and `%v`, and `%v` runs an abstract
    // type's `tostring`, which can still panic through C. A jump would have
    // skipped the `defer` then too. Nothing leaks either way -- scratch memory
    // is reclaimed by the next collection, which is the whole point of
    // allocating it here rather than with `janet_malloc` -- but there is one
    // exit and it may as well say so.
    if (heap_indices) |allocated| c.janet_sfree(allocated);
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

pub fn janetc_throwawayImpl(options: c.JanetFopts, value: c.Janet) raise.Raising(void) {
    const compiler: *c.JanetCompiler = options.compiler;
    const bytecode_start = vectorCount(u32, compiler.buffer);
    const source_map_start = vectorCount(c.JanetSourceMapping, compiler.mapbuffer);
    var unused_scope: c.JanetScope = undefined;
    janetc_scope(&unused_scope, compiler, c.JANET_SCOPE_UNUSED, "unused");
    _ = try janetc_valueImpl(options, value);
    try lintf(compiler, .strict, "dead code, consider removing %.4q", .{value});
    try janetc_popscopeImpl(compiler);
    if (compiler.buffer != null) {
        setVectorCount(u32, compiler.buffer, bytecode_start);
        if (compiler.mapbuffer != null) setVectorCount(c.JanetSourceMapping, compiler.mapbuffer, source_map_start);
    }
}

export fn janetc_throwaway(options: c.JanetFopts, value: c.Janet) callconv(.c) void {
    raise.reported(janetc_throwawayImpl(options, value));
}

pub fn janetc_valueImpl(options: c.JanetFopts, original_value: c.Janet) raise.Raising(c.JanetSlot) {
    const compiler: *c.JanetCompiler = options.compiler;
    const previous_mapping = compiler.current_mapping;
    compiler.recursion_guard -= 1;
    if (compiler.result.status == c.JANET_COMPILE_ERROR) return janetc_cslot(wrapNil());
    if (compiler.recursion_guard <= 0) {
        c.janetc_cerror(compiler, "recursed too deeply");
        return janetc_cslot(wrapNil());
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
        return janetc_cslot(wrapNil());
    }

    if (special) |special_form| {
        const tuple = c.janet_unwrap_tuple(value);
        result = try specials.of(special_form).compile.?(options, c.janet_tuple_length(tuple) - 1, tuple + 1);
    } else {
        switch (c.janet_type(value)) {
            c.JANET_TUPLE => {
                const tuple = c.janet_unwrap_tuple(value);
                const length = c.janet_tuple_length(tuple);
                if (length == 0) {
                    result = janetc_cslot(c.janet_wrap_tuple(c.janet_tuple_n(null, 0)));
                } else if (c.janet_tuple_flag(tuple) & c.JANET_TUPLE_FLAG_BRACKETCTOR != 0) {
                    result = try makeTuple(options, value);
                } else {
                    var suboptions = janetc_fopts_default(compiler);
                    const function = try janetc_valueImpl(suboptions, tuple[0]);
                    suboptions.flags = c.JANET_FUNCTION | c.JANET_CFUNCTION;
                    result = try compileCall(
                        options,
                        try janetc_toslotsImpl(compiler, tuple + 1, length - 1),
                        function,
                        tuple,
                    );
                    janetc_freeslot(compiler, function);
                }
                result.flags &= ~@as(u32, c.JANET_SLOT_SPLICED);
            },
            c.JANET_SYMBOL => result = try janetc_resolveImpl(compiler, c.janet_unwrap_symbol(value)),
            c.JANET_ARRAY => result = try makeArray(options, value),
            c.JANET_STRUCT => result = makeDictionary(options, value, c.JOP_MAKE_STRUCT),
            c.JANET_TABLE => result = makeDictionary(options, value, c.JOP_MAKE_TABLE),
            c.JANET_BUFFER => result = try makeBuffer(options, value),
            else => result = janetc_cslot(value),
        }
    }

    if (compiler.result.status == c.JANET_COMPILE_ERROR) return janetc_cslot(wrapNil());
    if (options.flags & c.JANET_FOPTS_TAIL != 0) result = janetc_return(compiler, result);
    if (options.flags & c.JANET_FOPTS_HINT != 0) {
        c.janetc_copy(compiler, options.hint, result);
        result = options.hint;
    }
    compiler.current_mapping = previous_mapping;
    compiler.recursion_guard += 1;
    return result;
}

export fn janetc_value(options: c.JanetFopts, original_value: c.Janet) callconv(.c) c.JanetSlot {
    return raise.reported(janetc_valueImpl(options, original_value));
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
    return runMacro(compiler, value, macro_value, result);
}

fn compileCall(
    options: c.JanetFopts,
    slots: [*c]c.JanetSlot,
    function: c.JanetSlot,
    form: [*c]const c.Janet,
) raise.Raising(c.JanetSlot) {
    const compiler: *c.JanetCompiler = options.compiler;
    var result: c.JanetSlot = undefined;
    if (!tryCallOptimizer(options, slots, function, &result)) {
        const minimum_arity = janetc_pushslots(compiler, slots);
        try validateCall(compiler, function, minimum_arity, form);
        if (options.flags & c.JANET_FOPTS_TAIL != 0 and compiler.scope.*.flags & c.JANET_SCOPE_TOP == 0) {
            _ = c.janetc_emit_s(compiler, @intCast(c.JOP_TAILCALL), function, 0);
            result = janetc_cslot(wrapNil());
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

// ==========================================================================
// Resolving a global, and the two escapes into user code
//
// `lookupMissing` and `runMacro` both suspend the compiler to run a Janet
// function in a fresh fiber: the first is the `:missing-symbol` handler, the
// second is a macro expansion. Both were in C until Phase 10 Part 7 for a
// reason that has expired -- `janet_continue` used to be reachable only from
// C -- and both keep the same shape they had, including the GC lock that
// holds the compiler's own structures alive across the call.
// ==========================================================================

/// `src/core/util.h`, which `abi.zig` deliberately does not translate.
extern fn janet_table_get_keyword(table: [*c]c.JanetTable, keyword: [*c]const u8) callconv(.c) c.Janet;
extern fn janet_binding_from_entry(entry: c.Janet) callconv(.c) c.JanetBinding;

/// `janet_assert` from `src/core/util.h`, a macro over `JANET_EXIT`. Not a
/// raise: a broken scope chain is a defect in this file rather than a program
/// error, and the C original prints and calls `abort`, which is what
/// `janet_zig_fatal` does. Same shape as `gc_sweep.zig`'s `assertFinalized`.
inline fn compilerAssert(condition: c_int, message: [*c]const u8) void {
    if (condition == 0) c.janet_zig_fatal(message);
}

/// Ask the environment's `:missing-symbol` handler for a binding.
///
/// Answers false having recorded a compile error, which is why the binding is
/// an out-parameter rather than an optional: a failure here is reported on the
/// compiler, not returned.
fn lookupMissing(
    compiler: *c.JanetCompiler,
    symbol: [*c]const u8,
    handler: [*c]c.JanetFunction,
    out: *c.JanetBinding,
) bool {
    const definition = handler.*.def;
    if (definition.*.min_arity > 1 or definition.*.max_arity < 1) {
        janetc_error(compiler, c.janet_cstring("missing symbol lookup handler must take 1 argument"));
        return false;
    }
    var args = [_]c.Janet{c.janet_wrap_symbol(symbol)};
    const fiber = c.janet_fiber(handler, 64, 1, &args);
    if (fiber == null) {
        janetc_error(compiler, c.janet_cstring("failed to call missing symbol lookup handler"));
        return false;
    }
    fiber.*.env = compiler.env;
    const lock = c.janet_gclock();
    var handler_out: c.Janet = undefined;
    const status = c.janet_continue(fiber, wrapNil(), &handler_out);
    c.janet_gcunlock(lock);
    if (status != c.JANET_SIGNAL_OK) {
        janetc_error(compiler, pp_format.formatcReported("(lookup) %V", .{handler_out}));
        return false;
    }
    out.* = janet_binding_from_entry(handler_out);
    return true;
}

/// Resolve a symbol that no lexical scope claimed.
fn resolveGlobal(compiler: *c.JanetCompiler, symbol: [*c]const u8, out: *c.JanetSlot) raise.Raising(void) {
    var binding = c.janet_resolve_ext(compiler.env, symbol);
    if (binding.type == c.JANET_BINDING_NONE) {
        const handler = janet_table_get_keyword(compiler.env, "missing-symbol");
        switch (c.janet_type(handler)) {
            c.JANET_NIL => {},
            c.JANET_FUNCTION => {
                if (!lookupMissing(compiler, symbol, c.janet_unwrap_function(handler), &binding)) {
                    out.* = janetc_cslot(wrapNil());
                    return;
                }
            },
            else => {
                janetc_error(compiler, pp_format.formatcReported("invalid lookup handler %V", .{handler}));
                out.* = janetc_cslot(wrapNil());
                return;
            },
        }
    }

    switch (binding.type) {
        c.JANET_BINDING_DEF, c.JANET_BINDING_MACRO => out.* = janetc_cslot(binding.value),
        c.JANET_BINDING_DYNAMIC_DEF, c.JANET_BINDING_DYNAMIC_MACRO => {
            out.* = janetc_cslot(binding.value);
            out.flags |= c.JANET_SLOT_REF | c.JANET_SLOT_NAMED | c.JANET_SLOTTYPE_ANY;
            out.flags &= ~@as(u32, c.JANET_SLOT_CONSTANT);
        },
        c.JANET_BINDING_VAR => {
            out.* = janetc_cslot(binding.value);
            out.flags |= c.JANET_SLOT_REF | c.JANET_SLOT_NAMED | c.JANET_SLOT_MUTABLE | c.JANET_SLOTTYPE_ANY;
            out.flags &= ~@as(u32, c.JANET_SLOT_CONSTANT);
        },
        // `JANET_BINDING_NONE` and anything unrecognised. The C original
        // spells this as `default:` falling into the `NONE` label.
        else => {
            janetc_error(compiler, pp_format.formatcReported("unknown symbol %q", .{c.janet_wrap_symbol(symbol)}));
            out.* = janetc_cslot(wrapNil());
            return;
        },
    }

    switch (binding.deprecation) {
        c.JANET_BINDING_DEP_NONE => {},
        c.JANET_BINDING_DEP_RELAXED => try lintf(compiler, .relaxed, "%q is deprecated", .{c.janet_wrap_symbol(symbol)}),
        c.JANET_BINDING_DEP_NORMAL => try lintf(compiler, .normal, "%q is deprecated", .{c.janet_wrap_symbol(symbol)}),
        c.JANET_BINDING_DEP_STRICT => try lintf(compiler, .strict, "%q is deprecated", .{c.janet_wrap_symbol(symbol)}),
        else => {},
    }
}

/// The four shadowing lints, by what is being shadowed.
fn shadowLint(compiler: *c.JanetCompiler, symbol: [*c]const u8, shadowing: c.Shadowing) raise.Raising(void) {
    const name = c.janet_wrap_symbol(symbol);
    switch (shadowing) {
        c.JANETC_SHADOW_MACRO => try lintf(compiler, .normal, "binding %q is shadowing a macro", .{name}),
        c.JANETC_SHADOW_LOCAL_HIDES_LOCAL => try lintf(compiler, .strict, "binding %q is shadowing a binding", .{name}),
        c.JANETC_SHADOW_LOCAL_HIDES_GLOBAL => try lintf(compiler, .strict, "binding %q is shadowing a top-level binding", .{name}),
        c.JANETC_SHADOW_GLOBAL_HIDES_GLOBAL => try lintf(compiler, .strict, "top-level binding %q is shadowing another top-level binding", .{name}),
        else => {},
    }
}

/// Expand one macro form, and report the expansion's failure as a compile
/// error.
///
/// The two `:macro-form` and `:macro-lints` bindings are put into the
/// environment for the macro to read and cleared afterwards -- unconditionally
/// in the C original, including the lints key that may never have been set,
/// which is reproduced here.
fn runMacro(
    compiler: *c.JanetCompiler,
    form_value: c.Janet,
    macro_value: c.Janet,
    out: *c.Janet,
) bool {
    const form = c.janet_unwrap_tuple(form_value);
    const macro = c.janet_unwrap_function(macro_value);
    const arity = c.janet_tuple_length(form) - 1;
    const fiber = c.janet_fiber(macro, 64, arity, form + 1);
    if (fiber == null) {
        const definition = macro.*.def;
        const minimum = definition.*.min_arity;
        const maximum = definition.*.max_arity;
        var message: [*c]const u8 = null;
        if (minimum >= 0 and arity < minimum)
            message = pp_format.formatcReported("macro arity mismatch, expected at least %d, got %d", .{ minimum, arity });
        if (maximum >= 0 and arity > maximum)
            message = pp_format.formatcReported("macro arity mismatch, expected at most %d, got %d", .{ maximum, arity });
        compiler.result.macrofiber = null;
        janetc_error(compiler, message);
        return false;
    }
    fiber.*.env = compiler.env;
    const lock = c.janet_gclock();
    const form_keyword = c.janet_ckeywordv("macro-form");
    c.janet_table_put(compiler.env, form_keyword, form_value);
    const lints_keyword = c.janet_ckeywordv("macro-lints");
    if (compiler.lints != null) {
        c.janet_table_put(compiler.env, lints_keyword, c.janet_wrap_array(compiler.lints));
    }
    var macro_out: c.Janet = undefined;
    const status = c.janet_continue(fiber, wrapNil(), &macro_out);
    c.janet_table_put(compiler.env, form_keyword, wrapNil());
    c.janet_table_put(compiler.env, lints_keyword, wrapNil());
    c.janet_gcunlock(lock);
    if (status != c.JANET_SIGNAL_OK) {
        compiler.result.macrofiber = fiber;
        janetc_error(compiler, pp_format.formatcReported("(macro) %V", .{macro_out}));
        return false;
    }
    out.* = macro_out;
    return true;
}

/// The three "wrong number of arguments" errors, which differ only in their
/// format string and in which bound they name.
///
/// `%s` selects the plural, which is why the count is passed twice.
fn arityError(
    compiler: *c.JanetCompiler,
    comptime format: [:0]const u8,
    function: c.Janet,
    expected: i32,
    got: i32,
) void {
    const plural: [*c]const u8 = if (expected == 1) "" else "s";
    janetc_error(compiler, pp_format.formatcReported(format, .{ function, expected, plural, got }));
}

fn validateCall(
    compiler: *c.JanetCompiler,
    function: c.JanetSlot,
    original_minimum_arity: i32,
    form: [*c]const c.Janet,
) raise.Raising(void) {
    if (function.flags & c.JANET_SLOT_CONSTANT == 0) return;
    var minimum_arity = original_minimum_arity;

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
                    arityError(compiler, "%v expects at most %d argument%s, got at least %d", function.constant, maximum, minimum_arity);
                }
                return;
            }
            if (maximum >= 0 and minimum_arity > maximum) {
                arityError(compiler, "%v expects at most %d argument%s, got %d", function.constant, maximum, minimum_arity);
            }
            if (minimum_arity < minimum) {
                arityError(compiler, "%v expects at least %d argument%s, got %d", function.constant, minimum, minimum_arity);
            }
            if (has_struct_argument and
                minimum_arity > definition.*.arity and
                (minimum_arity - definition.*.arity) & 1 != 0)
            {
                if (has_named_arguments) {
                    try lintf(compiler, .normal, "odd number of named arguments to `&named` function %v", .{function.constant});
                } else {
                    try lintf(compiler, .normal, "odd number of named arguments to `&keys` function %v", .{function.constant});
                }
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
                        try lintf(
                            compiler,
                            .normal,
                            "unused named argument %v to function %v",
                            .{ argument_key, function.constant },
                        );
                    }
                }
            }
        },
        c.JANET_CFUNCTION, c.JANET_ABSTRACT, c.JANET_NIL => {},
        c.JANET_KEYWORD => {
            if (minimum_arity == 0) {
                janetc_error(compiler, try pp_format.formatc("%v expects at least 1 argument, got 0", .{function.constant}));
            }
        },
        else => {
            if (minimum_arity > 1 or minimum_arity == 0) {
                janetc_error(compiler, try pp_format.formatc("%v expects 1 argument, got %d", .{ function.constant, minimum_arity }));
            }
            if (minimum_arity < -2) {
                janetc_error(compiler, try pp_format.formatc("%v expects 1 argument, got at least %d", .{ function.constant, -1 - minimum_arity }));
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

fn makeArray(options: c.JanetFopts, value: c.Janet) raise.Raising(c.JanetSlot) {
    const compiler: *c.JanetCompiler = options.compiler;
    const array = c.janet_unwrap_array(value);
    return makeValue(options, try janetc_toslotsImpl(compiler, array.*.data, array.*.count), c.JOP_MAKE_ARRAY);
}

fn makeTuple(options: c.JanetFopts, value: c.Janet) raise.Raising(c.JanetSlot) {
    const compiler: *c.JanetCompiler = options.compiler;
    const tuple = c.janet_unwrap_tuple(value);
    return makeValue(options, try janetc_toslotsImpl(compiler, tuple, c.janet_tuple_length(tuple)), c.JOP_MAKE_TUPLE);
}

fn makeDictionary(options: c.JanetFopts, value: c.Janet, operation: c_int) c.JanetSlot {
    const compiler: *c.JanetCompiler = options.compiler;
    return makeValue(options, janetc_toslotskv(compiler, value), operation);
}

fn makeBuffer(options: c.JanetFopts, value: c.Janet) raise.Raising(c.JanetSlot) {
    const compiler: *c.JanetCompiler = options.compiler;
    const buffer = c.janet_unwrap_buffer(value);
    const argument = c.janet_stringv(buffer.*.data, buffer.*.count);
    return makeValue(options, try janetc_toslotsImpl(compiler, &argument, 1), c.JOP_MAKE_BUFFER);
}

pub fn janetc_pop_funcdefImpl(compiler: *c.JanetCompiler) raise.Raising([*c]c.JanetFuncDef) {
    const scope = compiler.scope;
    const definition = c.janet_funcdef_alloc();
    definition.*.slotcount = scope.*.ra.max + 1;
    compilerAssert(@intFromBool(scope.*.flags & c.JANET_SCOPE_FUNCTION != 0), "expected function scope");

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
        try if (pair.referenced == 0 and pair.sym != null) lintf(compiler, .strict, "binding %q is unused", .{c.janet_wrap_symbol(pair.sym)});
        const death_pc: u32 = if (pair.death_pc == std_max_u32)
            @intCast(definition.*.bytecode_length)
        else
            pair.death_pc - @as(u32, @intCast(scope.*.bytecode_start));
        const birth_pc: u32 = if (@as(u32, @intCast(scope.*.bytecode_start)) > pair.birth_pc)
            0
        else
            pair.birth_pc - @as(u32, @intCast(scope.*.bytecode_start));
        compilerAssert(@intFromBool(birth_pc <= death_pc), "birth pc after death pc");
        compilerAssert(
            @intFromBool(birth_pc < @as(u32, @intCast(definition.*.bytecode_length))),
            "bad birth pc",
        );
        compilerAssert(
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

    try janetc_popscopeImpl(compiler);
    c.janet_bytecode_movopt(definition);
    c.janet_bytecode_remove_noops(definition);
    return definition;
}

export fn janetc_pop_funcdef(compiler: *c.JanetCompiler) callconv(.c) [*c]c.JanetFuncDef {
    return raise.reported(janetc_pop_funcdefImpl(compiler));
}

export fn janet_compile_lint(
    source: c.Janet,
    environment: [*c]c.JanetTable,
    where: c.JanetString,
    lints: [*c]c.JanetArray,
) callconv(.c) c.JanetCompileResult {
    return raise.reported(janet_compile_lintImpl(source, environment, where, lints));
}

pub fn janet_compile_lintImpl(
    source: c.Janet,
    environment: [*c]c.JanetTable,
    where: c.JanetString,
    lints: [*c]c.JanetArray,
) raise.Raising(c.JanetCompileResult) {
    var compiler: c.JanetCompiler = undefined;
    initCompiler(&compiler, environment, where, lints);

    var root_scope: c.JanetScope = undefined;
    janetc_scope(&root_scope, &compiler, c.JANET_SCOPE_FUNCTION | c.JANET_SCOPE_TOP, "root");
    const options = c.JanetFopts{
        .compiler = &compiler,
        .hint = janetc_cslot(wrapNil()),
        .flags = c.JANET_FOPTS_TAIL | c.JANET_SLOTTYPE_ANY,
    };
    _ = try janetc_valueImpl(options, source);

    if (compiler.result.status == c.JANET_COMPILE_OK) {
        const definition = try janetc_pop_funcdefImpl(&compiler);
        definition.*.name = c.janet_cstring("thunk");
        janet_def_addflags(definition);
        compiler.result.funcdef = definition;
    } else {
        compiler.result.error_mapping = compiler.current_mapping;
        try janetc_popscopeImpl(&compiler);
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
        .is_redef = @intFromBool(c.janet_truthy(janet_table_get_keyword(environment, "redef")) != 0),
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

// ==========================================================================
// The cfunction surface
// ==========================================================================

fn cfunCompile(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try lifecycle.sandboxAssert(c.JANET_SANDBOX_COMPILE);
    try arglayer.arity(argc, 1, 4);

    var env: [*c]c.JanetTable = if (argc > 1 and c.janet_checktype(argv[1], c.JANET_NIL) == 0)
        try arglayer.getTable(argv, 1)
    else
        c.janet_vm.fiber.*.env;
    if (env == null) {
        env = c.janet_table(0);
        c.janet_vm.fiber.*.env = env;
    }

    var source: [*c]const u8 = null;
    if (argc >= 3) {
        const x = argv[2];
        if (c.janet_checktype(x, c.JANET_STRING) != 0) {
            source = c.janet_unwrap_string(x);
        } else if (c.janet_checktype(x, c.JANET_KEYWORD) != 0) {
            source = c.janet_unwrap_keyword(x);
        } else if (c.janet_checktype(x, c.JANET_NIL) == 0) {
            return arglayer.panicType(x, 2, c.JANET_TFLAG_STRING | c.JANET_TFLAG_KEYWORD);
        }
    }

    const lints: [*c]c.JanetArray = if (argc >= 4 and c.janet_checktype(argv[3], c.JANET_NIL) == 0)
        try arglayer.getArray(argv, 3)
    else
        null;

    const result = c.janet_compile_lint(argv[0], env, source, lints);
    if (result.status == c.JANET_COMPILE_OK) {
        return c.janet_wrap_function(c.janet_thunk(result.funcdef));
    }

    // A failed compile is a value, not a raise: the caller asked to compile
    // something and gets back what went wrong and where.
    const table = c.janet_table(4);
    c.janet_table_put(table, c.janet_ckeywordv("error"), c.janet_wrap_string(result.@"error"));
    if (result.error_mapping.line > 0) {
        c.janet_table_put(table, c.janet_ckeywordv("line"), wrapInteger(result.error_mapping.line));
    }
    if (result.error_mapping.column > 0) {
        c.janet_table_put(table, c.janet_ckeywordv("column"), wrapInteger(result.error_mapping.column));
    }
    if (result.macrofiber != null) {
        c.janet_table_put(table, c.janet_ckeywordv("fiber"), c.janet_wrap_fiber(result.macrofiber));
    }
    return c.janet_wrap_table(table);
}

export fn janet_lib_compile(env: *c.JanetTable) callconv(.c) void {
    const entries = [_]corefn.Entry{
        corefn.reg("compile", &cfunCompile, @src(), "(compile ast &opt env source lints)", "Compiles an Abstract Syntax Tree (ast) into a function. " ++
            "Pair the compile function with parsing functionality to implement " ++
            "eval. Returns a new function and does not modify ast. Returns an error " ++
            "struct with keys :line, :column, and :error if compilation fails. " ++
            "If a `lints` array is given, linting messages will be appended to the array. " ++
            "Each message will be a tuple of the form `(level line col message)`."),
        corefn.end,
    };
    corefn.install(env, &entries);
}
