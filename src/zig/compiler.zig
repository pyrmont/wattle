const std = @import("std");
const config = @import("config");
const corefn = @import("corefn");
const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");
const specials = @import("special_type.zig");
const vm_lifecycle = @import("vm/lifecycle.zig");
const arrays = @import("value/arrays.zig");
const raise = @import("raise");
const pp_format = @import("pp/format.zig");
const structs = @import("value/structs.zig");
const tables = @import("value/tables.zig");
const gc_alloc = @import("gc.zig");
const strings = @import("value/strings.zig");
const tuples = @import("value/tuples.zig");
const utils = @import("utils.zig");
const order = @import("value/helpers/order.zig");
const fibers = @import("value/fibers.zig");
const functions = @import("value/functions.zig");
const vector_mod = @import("stretchy.zig");
const optimize = @import("compiler/optimize.zig");
const regalloc = @import("compiler/regalloc.zig");
const emit_core = @import("compiler/emit.zig");
const registry = @import("registry.zig");
const kind = @import("value/helpers/kind.zig");
const wrap = @import("value/helpers/wrap.zig");
const args_core = @import("args.zig");
const value = @import("value.zig");
const fatal = @import("fatal.zig");
const specials_core = @import("compiler/specials.zig");
const vm_entry = @import("vm/entry.zig");

const vector_header_size = 2 * @sizeOf(i32);

/// `janet_wrap_nil`, and `janet_wrap_integer` written out.
///
/// Both were one-line C functions in `compile.c` until Phase 10 Part 7,
/// because this subsystem translated only `compile.h` and `emit.h`. One shared
/// set of types removes the detour; `wrapInteger` stays spelled out because
/// `janet_wrap_integer` is a macro under nanboxing and a symbol `wrap.c`
/// never defines there.
inline fn wrapNil() types.Janet {
    return wrap.fromNil();
}

inline fn wrapInteger(val: i32) types.Janet {
    return wrap.fromNumber(@floatFromInt(val));
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
    relaxed = constants.JANET_C_LINT_RELAXED,
    normal = constants.JANET_C_LINT_NORMAL,
    strict = constants.JANET_C_LINT_STRICT,

    fn keyword(self: LintLevel) [*:0]const u8 {
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
    compiler: *types.JanetCompiler,
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
    compiler: *types.JanetCompiler,
    level: c_uint,
    message: [*:0]const u8,
) raise.Raising(void) {
    if (compiler.lints == null) return;
    try record(compiler, @enumFromInt(level), strings.cstring(message));
}

/// Append one finished lint, tagged with the level and the form's position.
///
/// A line or column of -1 means the source had no mapping there, and becomes
/// nil rather than -1 in the tuple.
fn record(compiler: *types.JanetCompiler, level: LintLevel, message: [*:0]const u8) raise.Raising(void) {
    const payload = tuples.begin(4);
    payload[0] = value.fromBytes(std.mem.span(level.keyword()), .keyword);
    payload[1] = if (compiler.current_mapping.line == -1) wrapNil() else wrapInteger(compiler.current_mapping.line);
    payload[2] = if (compiler.current_mapping.column == -1) wrapNil() else wrapInteger(compiler.current_mapping.column);
    payload[3] = wrap.fromString(message);
    try arrays.push(compiler.lints.?, wrap.fromTuple(tuples.end(payload)));
}

pub fn foptsDefault(compiler: *types.JanetCompiler) types.JanetFopts {
    return .{
        .compiler = compiler,
        .hint = cslot(wrapNil()),
        .flags = 0,
    };
}

pub fn recordError(compiler: *types.JanetCompiler, message: ?[*:0]const u8) void {
    if (compiler.result.status == constants.JANET_COMPILE_ERROR) return;
    compiler.result.status = constants.JANET_COMPILE_ERROR;
    compiler.result.@"error" = message;
}

pub fn cerror(compiler: *types.JanetCompiler, message: [*:0]const u8) void {
    recordError(compiler, strings.cstring(message));
}

pub fn freeslot(compiler: *types.JanetCompiler, slot: types.JanetSlot) void {
    if (slot.flags & (constants.JANET_SLOT_CONSTANT | constants.JANET_SLOT_REF | constants.JANET_SLOT_NAMED) != 0) return;
    if (slot.envindex >= 0) return;
    regalloc.regallocFree(&compiler.scope.?.ra, slot.index);
}

pub fn shadowcheck(compiler: *types.JanetCompiler, symbol: [*:0]const u8) types.Shadowing {
    var scope = compiler.scope;
    const is_global = compiler.scope.?.flags & constants.JANET_SCOPE_TOP != 0;
    while (scope) |current| : (scope = current.parent) {
        var index = vectorCount(types.SymPair, current.syms);
        while (index > 0) {
            index -= 1;
            if (current.syms.?[@intCast(index)].sym == symbol) {
                return if (is_global) constants.JANETC_SHADOW_GLOBAL_HIDES_GLOBAL else constants.JANETC_SHADOW_LOCAL_HIDES_LOCAL;
            }
        }
    }
    const binding = registry.resolveExt(compiler.env.?, symbol);
    if (binding.type == constants.JANET_BINDING_MACRO or binding.type == constants.JANET_BINDING_DYNAMIC_MACRO)
        return constants.JANETC_SHADOW_MACRO;
    if (binding.type == constants.JANET_BINDING_NONE) return constants.JANETC_SHADOW_NONE;
    return if (is_global) constants.JANETC_SHADOW_GLOBAL_HIDES_GLOBAL else constants.JANETC_SHADOW_LOCAL_HIDES_GLOBAL;
}

pub fn janetc_nameslotImpl(
    compiler: *types.JanetCompiler,
    symbol: [*:0]const u8,
    slot: types.JanetSlot,
    flags: u32,
) raise.Raising(void) {
    if (flags & constants.JANET_DEFFLAG_NO_SHADOWCHECK == 0 and symbol[0] != '_') {
        try shadowLint(compiler, symbol, shadowcheck(compiler, symbol));
    }
    const instruction_count = vectorCount(u32, compiler.buffer);
    var named_slot = slot;
    named_slot.flags |= constants.JANET_SLOT_NAMED;
    pushVector(types.SymPair, &compiler.scope.?.syms, .{
        .slot = named_slot,
        .sym = symbol,
        .sym2 = symbol,
        .keep = 0,
        .referenced = if (flags & constants.JANET_DEFFLAG_NO_UNUSED != 0 or symbol[0] == '_') 1 else 0,
        .birth_pc = @intCast(if (instruction_count != 0) instruction_count - 1 else 0),
        .death_pc = std_max_u32,
    });
}

pub fn janetc_resolveImpl(compiler: *types.JanetCompiler, symbol: [*:0]const u8) raise.Raising(types.JanetSlot) {
    var scope = compiler.scope;
    var found_pair: ?*types.SymPair = null;
    var found_local = true;
    var unused = false;

    search: while (scope) |current| : (scope = current.parent) {
        if (current.flags & constants.JANET_SCOPE_UNUSED != 0) unused = true;
        var index = vectorCount(types.SymPair, current.syms);
        while (index > 0) {
            index -= 1;
            const pair = &current.syms.?[@intCast(index)];
            if (pair.sym == symbol) {
                found_pair = pair;
                break :search;
            }
        }
        if (current.flags & constants.JANET_SCOPE_FUNCTION != 0) found_local = false;
    }

    const pair = found_pair orelse {
        var result: types.JanetSlot = undefined;
        try resolveGlobal(compiler, symbol, &result);
        return result;
    };
    var result = pair.slot;
    pair.referenced = 1;
    if (result.flags & (constants.JANET_SLOT_CONSTANT | constants.JANET_SLOT_REF) != 0) return result;
    if (unused or found_local) {
        result.envindex = -1;
        return result;
    }

    const original_scope = scope;
    pair.keep = 1;
    while (scope) |current| {
        if (current.flags & constants.JANET_SCOPE_FUNCTION != 0) break;
        scope = current.parent;
    }
    compilerAssert(@intFromBool(scope != null), "invalid scopes");
    scope.?.flags |= constants.JANET_SCOPE_ENV;
    regalloc.regallocTouch(&scope.?.ua, result.index);
    scope = scope.?.child;

    var environment_index: i32 = -1;
    while (scope) |current| : (scope = current.child) {
        if (current.flags & constants.JANET_SCOPE_FUNCTION == 0) continue;
        const environment_count = vectorCount(types.JanetEnvRef, current.envs);
        var index: i32 = 0;
        var found = false;
        while (index < environment_count) : (index += 1) {
            if (current.envs.?[@intCast(index)].envindex == environment_index) {
                found = true;
                environment_index = index;
                break;
            }
        }
        if (!found) {
            pushVector(types.JanetEnvRef, &current.envs, .{
                .envindex = environment_index,
                .scope = original_scope,
            });
            environment_index = environment_count;
        }
    }
    result.envindex = environment_index;
    return result;
}

pub fn cslot(val: types.Janet) types.JanetSlot {
    const value_type: u5 = @intCast(kind.typeOf(val));
    return .{
        .constant = val,
        .index = -1,
        .envindex = -1,
        .flags = (@as(u32, 1) << value_type) | constants.JANET_SLOT_CONSTANT,
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
pub fn farslot(compiler: *types.JanetCompiler) types.JanetSlot {
    const register = regalloc.regalloc1(&compiler.scope.?.ra);
    if (register > 0xffff) {
        cerror(compiler, "ran out of internal registers");
        return undefined;
    }
    return .{
        .constant = wrapNil(),
        .index = register,
        .envindex = -1,
        .flags = constants.JANET_SLOTTYPE_ANY,
    };
}

pub fn defAddflags(definition: *types.JanetFuncDef) void {
    const controlled_flags = constants.JANET_FUNCDEF_FLAG_HASNAME |
        constants.JANET_FUNCDEF_FLAG_HASSOURCE |
        constants.JANET_FUNCDEF_FLAG_HASDEFS |
        constants.JANET_FUNCDEF_FLAG_HASENVS |
        constants.JANET_FUNCDEF_FLAG_HASSOURCEMAP |
        constants.JANET_FUNCDEF_FLAG_HASCLOBITSET |
        constants.JANET_FUNCDEF_FLAG_NAMEDARGS;
    var present_flags: i32 = 0;
    if (definition.name != null) present_flags |= constants.JANET_FUNCDEF_FLAG_HASNAME;
    if (definition.source != null) present_flags |= constants.JANET_FUNCDEF_FLAG_HASSOURCE;
    if (definition.defs != null) present_flags |= constants.JANET_FUNCDEF_FLAG_HASDEFS;
    if (definition.environments != null) present_flags |= constants.JANET_FUNCDEF_FLAG_HASENVS;
    if (definition.sourcemap != null) present_flags |= constants.JANET_FUNCDEF_FLAG_HASSOURCEMAP;
    if (definition.closure_bitset != null) present_flags |= constants.JANET_FUNCDEF_FLAG_HASCLOBITSET;
    if (definition.named_args_count != 0) present_flags |= constants.JANET_FUNCDEF_FLAG_NAMEDARGS;
    definition.flags = (definition.flags & ~controlled_flags) | present_flags;
}

pub fn pushScope(
    result: *types.JanetScope,
    compiler: *types.JanetCompiler,
    flags: c_int,
    name: [*]const u8,
) callconv(.c) void {
    var scope: types.JanetScope = undefined;
    scope.name = name;
    scope.parent = compiler.scope;
    scope.child = null;
    scope.consts = null;
    scope.syms = null;
    scope.defs = null;
    scope.envs = null;
    scope.bytecode_start = vectorCount(u32, compiler.buffer);
    scope.flags = flags;
    regalloc.regallocInit(&scope.ua);
    if (flags & constants.JANET_SCOPE_FUNCTION == 0 and compiler.scope != null) {
        regalloc.regallocClone(&scope.ra, &compiler.scope.?.ra);
    } else {
        regalloc.regallocInit(&scope.ra);
    }
    if (compiler.scope) |current| current.child = result;
    compiler.scope = result;
    result.* = scope;
}

pub fn janetc_popscopeImpl(compiler: *types.JanetCompiler) raise.Raising(void) {
    const old_scope = compiler.scope.?;
    const new_scope = old_scope.*.parent;
    if (old_scope.*.flags & (constants.JANET_SCOPE_FUNCTION | constants.JANET_SCOPE_UNUSED) == 0 and new_scope != null) {
        if (old_scope.*.flags & constants.JANET_SCOPE_CLOSURE != 0) {
            new_scope.?.flags |= constants.JANET_SCOPE_CLOSURE;
        }
        if (new_scope.?.ra.max < old_scope.*.ra.max) {
            new_scope.?.ra.max = old_scope.*.ra.max;
        }

        const symbol_count = vectorCount(types.SymPair, old_scope.*.syms);
        var index: i32 = 0;
        while (index < symbol_count) : (index += 1) {
            var pair = old_scope.*.syms.?[@intCast(index)];
            if (pair.referenced == 0 and pair.sym != null) {
                try lintf(compiler, .strict, "binding %q is unused", .{wrap.fromSymbol(pair.sym.?)});
            }
            pair.sym = null;
            if (pair.death_pc == std_max_u32) {
                pair.death_pc = @intCast(vectorCount(u32, compiler.buffer));
            }
            if (pair.keep != 0) {
                pair.sym2 = null;
                regalloc.regallocTouch(&new_scope.?.ra, pair.slot.index);
            }
            pushVector(types.SymPair, &new_scope.?.syms, pair);
        }
    }

    freeVector(types.Janet, old_scope.*.consts);
    freeVector(types.SymPair, old_scope.*.syms);
    freeVector(types.JanetEnvRef, old_scope.*.envs);
    freeVector(*types.JanetFuncDef, old_scope.*.defs);
    regalloc.regallocDeinit(&old_scope.*.ra);
    regalloc.regallocDeinit(&old_scope.*.ua);
    if (new_scope) |parent| parent.child = null;
    compiler.scope = new_scope;
}

/// Pop a scope and reserve the register its result lives in.
///
/// This was an `export fn` that swallowed the pop's raise into a report, and
/// Phase 11 Part 7 found it by deleting `janetc_popscope` beside it: the one
/// caller is `specials_core.zig`'s `do`, which is itself raising, so the
/// report had nobody to consume it and would have surfaced at the next scope
/// boundary's assertion arbitrarily far from the cause. That is
/// `raise.crossing`'s documented family, of which it says each is "an
/// ordinary import away from not needing this at all". This is the import.
pub fn janetc_popscope_keepslotImpl(
    compiler: *types.JanetCompiler,
    return_slot: types.JanetSlot,
) raise.Raising(void) {
    try janetc_popscopeImpl(compiler);
    if (compiler.scope != null and return_slot.envindex < 0 and return_slot.index >= 0) {
        regalloc.regallocTouch(&compiler.scope.?.ra, return_slot.index);
    }
}

pub fn compileReturn(compiler: *types.JanetCompiler, slot_value: types.JanetSlot) types.JanetSlot {
    var result = slot_value;
    if (result.flags & constants.JANET_SLOT_RETURNED == 0) {
        if (result.flags & constants.JANET_SLOT_CONSTANT != 0 and kind.checkType(result.constant, constants.JANET_NIL) != 0) {
            emit_core.emit(compiler, @intCast(constants.JOP_RETURN_NIL));
        } else {
            _ = emit_core.emitSlot(compiler, @intCast(constants.JOP_RETURN), result, 0);
        }
        result.flags |= constants.JANET_SLOT_RETURNED;
    }
    return result;
}

pub fn gettarget(options: types.JanetFopts) types.JanetSlot {
    if (options.flags & constants.JANET_FOPTS_HINT != 0 and
        options.hint.envindex < 0 and
        options.hint.index >= 0 and
        options.hint.index <= 0xff)
    {
        return options.hint;
    }
    return .{
        .constant = wrapNil(),
        .index = emit_core.allocfar(options.compiler),
        .envindex = -1,
        .flags = 0,
    };
}

pub fn janetc_toslotsImpl(
    compiler: *types.JanetCompiler,
    values: ?[*]const types.Janet,
    length: i32,
) raise.Raising(?[*]types.JanetSlot) {
    var result: ?[*]types.JanetSlot = null;
    var options = foptsDefault(compiler);
    options.flags |= constants.JANET_FOPTS_ACCEPT_SPLICE;
    var index: i32 = 0;
    while (index < length) : (index += 1) {
        pushVector(types.JanetSlot, &result, try janetc_valueImpl(options, values.?[@intCast(index)]));
    }
    return result;
}

/// A dictionary's keys and values, interleaved, in sorted key order.
///
/// The two `janetc_value` calls below raise, and until Part 7 this was an
/// `export fn` that reported them — with its only caller, `makeDictionary`,
/// inside `janetc_valueImpl`'s raising chain. Same family as
/// `janetc_popscope_keepslotImpl` above and found the same way.
pub fn janetc_toslotskvImpl(compiler: *types.JanetCompiler, dictionary: types.Janet) raise.Raising(?[*]types.JanetSlot) {
    var result: ?[*]types.JanetSlot = null;
    var options = foptsDefault(compiler);
    options.flags |= constants.JANET_FOPTS_ACCEPT_SPLICE;
    var key_values: ?[*]const types.JanetKV = null;
    var length: i32 = 0;
    var capacity: i32 = 0;
    _ = args_core.dictionaryView(dictionary, &key_values, &length, &capacity);

    var stack_indices: [32]i32 = undefined;
    var heap_indices: ?[*]i32 = null;
    const indices: [*]i32 = if (length < stack_indices.len)
        &stack_indices
    else blk: {
        const memory = gc_alloc.smalloc(@sizeOf(i32) * @as(usize, @intCast(length))) orelse
            fatal.outOfMemory();
        const allocated: [*]i32 = @ptrCast(@alignCast(memory));
        heap_indices = allocated;
        break :blk allocated;
    };
    if (length != 0) _ = utils.sortedKeys(key_values.?, capacity, indices);
    var index: i32 = 0;
    while (index < length) : (index += 1) {
        const pair = key_values.?[@intCast(indices[@intCast(index)])];
        pushVector(types.JanetSlot, &result, try janetc_valueImpl(options, pair.key));
        pushVector(types.JanetSlot, &result, try janetc_valueImpl(options, pair.value));
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
    if (heap_indices) |allocated| gc_alloc.sfree(allocated);
    return result;
}

pub fn pushslots(compiler: *types.JanetCompiler, slots: ?[*]types.JanetSlot) i32 {
    const count = vectorCount(types.JanetSlot, slots);
    var index: i32 = 0;
    var minimum_arity: i32 = 0;
    var has_splice = false;
    while (index < count) {
        if (slots.?[@intCast(index)].flags & constants.JANET_SLOT_SPLICED != 0) {
            _ = emit_core.emitSlot(compiler, @intCast(constants.JOP_PUSH_ARRAY), slots.?[@intCast(index)], 0);
            index += 1;
            has_splice = true;
        } else if (index + 1 == count) {
            _ = emit_core.emitSlot(compiler, @intCast(constants.JOP_PUSH), slots.?[@intCast(index)], 0);
            index += 1;
            minimum_arity += 1;
        } else if (slots.?[@intCast(index + 1)].flags & constants.JANET_SLOT_SPLICED != 0) {
            _ = emit_core.emitSlot(compiler, @intCast(constants.JOP_PUSH), slots.?[@intCast(index)], 0);
            _ = emit_core.emitSlot(compiler, @intCast(constants.JOP_PUSH_ARRAY), slots.?[@intCast(index + 1)], 0);
            index += 2;
            minimum_arity += 1;
            has_splice = true;
        } else if (index + 2 == count) {
            _ = emit_core.emitSs(compiler, @intCast(constants.JOP_PUSH_2), slots.?[@intCast(index)], slots.?[@intCast(index + 1)], 0);
            index += 2;
            minimum_arity += 2;
        } else if (slots.?[@intCast(index + 2)].flags & constants.JANET_SLOT_SPLICED != 0) {
            _ = emit_core.emitSs(compiler, @intCast(constants.JOP_PUSH_2), slots.?[@intCast(index)], slots.?[@intCast(index + 1)], 0);
            _ = emit_core.emitSlot(compiler, @intCast(constants.JOP_PUSH_ARRAY), slots.?[@intCast(index + 2)], 0);
            index += 3;
            minimum_arity += 2;
            has_splice = true;
        } else {
            _ = emit_core.emitSss(
                compiler,
                @intCast(constants.JOP_PUSH_3),
                slots.?[@intCast(index)],
                slots.?[@intCast(index + 1)],
                slots.?[@intCast(index + 2)],
                0,
            );
            index += 3;
            minimum_arity += 3;
        }
    }
    return if (has_splice) -1 - minimum_arity else minimum_arity;
}

pub fn freeslots(compiler: *types.JanetCompiler, slots: ?[*]types.JanetSlot) void {
    const count = vectorCount(types.JanetSlot, slots);
    var index: i32 = 0;
    while (index < count) : (index += 1) freeslot(compiler, slots.?[@intCast(index)]);
    freeVector(types.JanetSlot, slots);
}

pub fn janetc_throwawayImpl(options: types.JanetFopts, val: types.Janet) raise.Raising(void) {
    const compiler: *types.JanetCompiler = options.compiler;
    const bytecode_start = vectorCount(u32, compiler.buffer);
    const source_map_start = vectorCount(types.JanetSourceMapping, compiler.mapbuffer);
    var unused_scope: types.JanetScope = undefined;
    pushScope(&unused_scope, compiler, constants.JANET_SCOPE_UNUSED, "unused");
    _ = try janetc_valueImpl(options, val);
    try lintf(compiler, .strict, "dead code, consider removing %.4q", .{val});
    try janetc_popscopeImpl(compiler);
    if (compiler.buffer != null) {
        setVectorCount(u32, compiler.buffer.?, bytecode_start);
        if (compiler.mapbuffer != null) setVectorCount(types.JanetSourceMapping, compiler.mapbuffer.?, source_map_start);
    }
}

pub fn janetc_valueImpl(options: types.JanetFopts, original_value: types.Janet) raise.Raising(types.JanetSlot) {
    const compiler: *types.JanetCompiler = options.compiler;
    const previous_mapping = compiler.current_mapping;
    compiler.recursion_guard -= 1;
    if (compiler.result.status == constants.JANET_COMPILE_ERROR) return cslot(wrapNil());
    if (compiler.recursion_guard <= 0) {
        cerror(compiler, "recursed too deeply");
        return cslot(wrapNil());
    }

    var val = original_value;
    var result: types.JanetSlot = undefined;
    var special: ?*const types.JanetSpecial = null;
    var expansions: i32 = config.max_macro_expand;
    while (expansions != 0 and
        compiler.result.status != constants.JANET_COMPILE_ERROR and
        expandMacroOnce(compiler, val, &val, &special))
    {
        expansions -= 1;
    }
    if (expansions == 0) {
        cerror(compiler, "recursed too deeply in macro expansion");
        return cslot(wrapNil());
    }

    if (special) |special_form| {
        const tuple = wrap.toTuple(val);
        result = try specials.of(special_form).compile.?(options, types.tupleHead(tuple).length - 1, tuple + 1);
    } else {
        switch (kind.typeOf(val)) {
            constants.JANET_TUPLE => {
                const tuple = wrap.toTuple(val);
                const length = types.tupleHead(tuple).length;
                if (length == 0) {
                    result = cslot(wrap.fromTuple(tuples.newFrom(null, 0)));
                } else if (types.tupleHead(tuple).gc.flags & constants.JANET_TUPLE_FLAG_BRACKETCTOR != 0) {
                    result = try makeTuple(options, val);
                } else {
                    var suboptions = foptsDefault(compiler);
                    const function = try janetc_valueImpl(suboptions, tuple[0]);
                    suboptions.flags = constants.JANET_FUNCTION | constants.JANET_CFUNCTION;
                    result = try compileCall(
                        options,
                        try janetc_toslotsImpl(compiler, tuple + 1, length - 1),
                        function,
                        tuple,
                    );
                    freeslot(compiler, function);
                }
                result.flags &= ~@as(u32, constants.JANET_SLOT_SPLICED);
            },
            constants.JANET_SYMBOL => result = try janetc_resolveImpl(compiler, wrap.toSymbol(val)),
            constants.JANET_ARRAY => result = try makeArray(options, val),
            constants.JANET_STRUCT => result = try makeDictionary(options, val, constants.JOP_MAKE_STRUCT),
            constants.JANET_TABLE => result = try makeDictionary(options, val, constants.JOP_MAKE_TABLE),
            constants.JANET_BUFFER => result = try makeBuffer(options, val),
            else => result = cslot(val),
        }
    }

    if (compiler.result.status == constants.JANET_COMPILE_ERROR) return cslot(wrapNil());
    if (options.flags & constants.JANET_FOPTS_TAIL != 0) result = compileReturn(compiler, result);
    if (options.flags & constants.JANET_FOPTS_HINT != 0) {
        emit_core.copy(compiler, options.hint, result);
        result = options.hint;
    }
    compiler.current_mapping = previous_mapping;
    compiler.recursion_guard += 1;
    return result;
}

fn expandMacroOnce(
    compiler: *types.JanetCompiler,
    val: types.Janet,
    result: *types.Janet,
    special: *?*const types.JanetSpecial,
) bool {
    if (kind.checkType(val, constants.JANET_TUPLE) == 0) return false;
    const form = wrap.toTuple(val);
    const length = types.tupleHead(form).length;
    if (length == 0) return false;

    const head = utils.tupleHead(form);
    if (head.*.sm_line >= 0) {
        compiler.current_mapping.line = head.*.sm_line;
        compiler.current_mapping.column = head.*.sm_column;
    }
    if (head.*.gc.flags & constants.JANET_TUPLE_FLAG_BRACKETCTOR != 0) return false;
    if (kind.checkType(form[0], constants.JANET_SYMBOL) == 0) return false;

    const name = wrap.toSymbol(form[0]);
    special.* = specials_core.lookupSpecial(name);
    if (special.* != null) return false;

    var macro_value: types.Janet = undefined;
    const binding_type = registry.resolve(compiler.env.?, name, &macro_value);
    if ((binding_type != constants.JANET_BINDING_MACRO and binding_type != constants.JANET_BINDING_DYNAMIC_MACRO) or
        kind.checkType(macro_value, constants.JANET_FUNCTION) == 0)
    {
        return false;
    }
    return runMacro(compiler, val, macro_value, result);
}

fn compileCall(
    options: types.JanetFopts,
    slots: ?[*]types.JanetSlot,
    function: types.JanetSlot,
    form: [*]const types.Janet,
) raise.Raising(types.JanetSlot) {
    const compiler: *types.JanetCompiler = options.compiler;
    var result: types.JanetSlot = undefined;
    if (!tryCallOptimizer(options, slots, function, &result)) {
        const minimum_arity = pushslots(compiler, slots);
        try validateCall(compiler, function, minimum_arity, form);
        if (options.flags & constants.JANET_FOPTS_TAIL != 0 and compiler.scope.?.flags & constants.JANET_SCOPE_TOP == 0) {
            _ = emit_core.emitSlot(compiler, @intCast(constants.JOP_TAILCALL), function, 0);
            result = cslot(wrapNil());
            result.flags = constants.JANET_SLOT_RETURNED;
        } else {
            result = gettarget(options);
            _ = emit_core.emitSs(compiler, @intCast(constants.JOP_CALL), result, function, 1);
        }
    }
    freeslots(compiler, slots);
    return result;
}

fn tryCallOptimizer(
    options: types.JanetFopts,
    slots: ?[*]types.JanetSlot,
    function: types.JanetSlot,
    result: *types.JanetSlot,
) bool {
    if (function.flags & constants.JANET_SLOT_CONSTANT == 0) return false;
    const slot_count = vectorCount(types.JanetSlot, slots);
    var index: i32 = 0;
    while (index < slot_count) : (index += 1) {
        if (slots.?[@intCast(index)].flags & constants.JANET_SLOT_SPLICED != 0) return false;
    }
    if (kind.checkType(function.constant, constants.JANET_FUNCTION) == 0) return false;
    const function_value = wrap.toFunction(function.constant);
    const optimizer = optimize.funopt(@bitCast(function_value.*.def.?.flags)) orelse return false;
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

/// `src/core/util.h`, declared here rather than in `cabi.zig`.
extern fn janet_table_get_keyword(table: *types.JanetTable, keyword: [*]const u8) callconv(.c) types.Janet;
extern fn janet_binding_from_entry(entry: types.Janet) callconv(.c) types.JanetBinding;

/// `janet_assert` from `src/core/util.h`, a macro over `JANET_EXIT`. Not a
/// raise: a broken scope chain is a defect in this file rather than a program
/// error, and the C original prints and calls `abort`, which is what
/// `janet_zig_fatal` does. Same shape as `gc_sweep.zig`'s `assertFinalized`.
inline fn compilerAssert(condition: c_int, message: [*:0]const u8) void {
    if (condition == 0) fatal.fatal(message);
}

/// Ask the environment's `:missing-symbol` handler for a binding.
///
/// Answers false having recorded a compile error, which is why the binding is
/// an out-parameter rather than an optional: a failure here is reported on the
/// compiler, not returned.
fn lookupMissing(
    compiler: *types.JanetCompiler,
    symbol: [*:0]const u8,
    handler: *types.JanetFunction,
    out: *types.JanetBinding,
) bool {
    const definition = handler.*.def.?;
    if (definition.*.min_arity > 1 or definition.*.max_arity < 1) {
        recordError(compiler, strings.cstring("missing symbol lookup handler must take 1 argument"));
        return false;
    }
    var args = [_]types.Janet{wrap.fromSymbol(symbol)};
    const fiber = fibers.new(handler, 64, 1, &args) orelse {
        recordError(compiler, strings.cstring("failed to call missing symbol lookup handler"));
        return false;
    };
    fiber.*.env = compiler.env;
    const lock = gc_alloc.gclock();
    var handler_out: types.Janet = undefined;
    const status = vm_entry.continueFiber(fiber, wrapNil(), &handler_out);
    gc_alloc.gcunlock(lock);
    if (status != constants.JANET_SIGNAL_OK) {
        recordError(compiler, pp_format.formatcReported("(lookup) %V", .{handler_out}));
        return false;
    }
    out.* = janet_binding_from_entry(handler_out);
    return true;
}

/// Resolve a symbol that no lexical scope claimed.
fn resolveGlobal(compiler: *types.JanetCompiler, symbol: [*:0]const u8, out: *types.JanetSlot) raise.Raising(void) {
    var binding = registry.resolveExt(compiler.env.?, symbol);
    if (binding.type == constants.JANET_BINDING_NONE) {
        const handler = janet_table_get_keyword(compiler.env.?, "missing-symbol");
        switch (kind.typeOf(handler)) {
            constants.JANET_NIL => {},
            constants.JANET_FUNCTION => {
                if (!lookupMissing(compiler, symbol, wrap.toFunction(handler), &binding)) {
                    out.* = cslot(wrapNil());
                    return;
                }
            },
            else => {
                recordError(compiler, pp_format.formatcReported("invalid lookup handler %V", .{handler}));
                out.* = cslot(wrapNil());
                return;
            },
        }
    }

    switch (binding.type) {
        constants.JANET_BINDING_DEF, constants.JANET_BINDING_MACRO => out.* = cslot(binding.value),
        constants.JANET_BINDING_DYNAMIC_DEF, constants.JANET_BINDING_DYNAMIC_MACRO => {
            out.* = cslot(binding.value);
            out.flags |= constants.JANET_SLOT_REF | constants.JANET_SLOT_NAMED | constants.JANET_SLOTTYPE_ANY;
            out.flags &= ~@as(u32, constants.JANET_SLOT_CONSTANT);
        },
        constants.JANET_BINDING_VAR => {
            out.* = cslot(binding.value);
            out.flags |= constants.JANET_SLOT_REF | constants.JANET_SLOT_NAMED | constants.JANET_SLOT_MUTABLE | constants.JANET_SLOTTYPE_ANY;
            out.flags &= ~@as(u32, constants.JANET_SLOT_CONSTANT);
        },
        // `JANET_BINDING_NONE` and anything unrecognised. The C original
        // spells this as `default:` falling into the `NONE` label.
        else => {
            recordError(compiler, pp_format.formatcReported("unknown symbol %q", .{wrap.fromSymbol(symbol)}));
            out.* = cslot(wrapNil());
            return;
        },
    }

    switch (binding.deprecation) {
        constants.JANET_BINDING_DEP_NONE => {},
        constants.JANET_BINDING_DEP_RELAXED => try lintf(compiler, .relaxed, "%q is deprecated", .{wrap.fromSymbol(symbol)}),
        constants.JANET_BINDING_DEP_NORMAL => try lintf(compiler, .normal, "%q is deprecated", .{wrap.fromSymbol(symbol)}),
        constants.JANET_BINDING_DEP_STRICT => try lintf(compiler, .strict, "%q is deprecated", .{wrap.fromSymbol(symbol)}),
        else => {},
    }
}

/// The four shadowing lints, by what is being shadowed.
fn shadowLint(compiler: *types.JanetCompiler, symbol: [*:0]const u8, shadowing: types.Shadowing) raise.Raising(void) {
    const name = wrap.fromSymbol(symbol);
    switch (shadowing) {
        constants.JANETC_SHADOW_MACRO => try lintf(compiler, .normal, "binding %q is shadowing a macro", .{name}),
        constants.JANETC_SHADOW_LOCAL_HIDES_LOCAL => try lintf(compiler, .strict, "binding %q is shadowing a binding", .{name}),
        constants.JANETC_SHADOW_LOCAL_HIDES_GLOBAL => try lintf(compiler, .strict, "binding %q is shadowing a top-level binding", .{name}),
        constants.JANETC_SHADOW_GLOBAL_HIDES_GLOBAL => try lintf(compiler, .strict, "top-level binding %q is shadowing another top-level binding", .{name}),
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
    compiler: *types.JanetCompiler,
    form_value: types.Janet,
    macro_value: types.Janet,
    out: *types.Janet,
) bool {
    const form = wrap.toTuple(form_value);
    const macro = wrap.toFunction(macro_value);
    const arity = types.tupleHead(form).length - 1;
    const fiber = fibers.new(macro, 64, arity, form + 1) orelse {
        const definition = macro.*.def.?;
        const minimum = definition.*.min_arity;
        const maximum = definition.*.max_arity;
        var message: ?[*:0]const u8 = null;
        if (minimum >= 0 and arity < minimum)
            message = pp_format.formatcReported("macro arity mismatch, expected at least %d, got %d", .{ minimum, arity });
        if (maximum >= 0 and arity > maximum)
            message = pp_format.formatcReported("macro arity mismatch, expected at most %d, got %d", .{ maximum, arity });
        compiler.result.macrofiber = null;
        recordError(compiler, message);
        return false;
    };
    fiber.*.env = compiler.env;
    const lock = gc_alloc.gclock();
    const form_keyword = value.fromBytes("macro-form", .keyword);
    tables.put(compiler.env.?, form_keyword, form_value);
    const lints_keyword = value.fromBytes("macro-lints", .keyword);
    if (compiler.lints != null) {
        tables.put(compiler.env.?, lints_keyword, wrap.fromArray(compiler.lints.?));
    }
    var macro_out: types.Janet = undefined;
    const status = vm_entry.continueFiber(fiber, wrapNil(), &macro_out);
    tables.put(compiler.env.?, form_keyword, wrapNil());
    tables.put(compiler.env.?, lints_keyword, wrapNil());
    gc_alloc.gcunlock(lock);
    if (status != constants.JANET_SIGNAL_OK) {
        compiler.result.macrofiber = fiber;
        recordError(compiler, pp_format.formatcReported("(macro) %V", .{macro_out}));
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
    compiler: *types.JanetCompiler,
    comptime format: [:0]const u8,
    function: types.Janet,
    expected: i32,
    got: i32,
) void {
    const plural: [*]const u8 = if (expected == 1) "" else "s";
    recordError(compiler, pp_format.formatcReported(format, .{ function, expected, plural, got }));
}

fn validateCall(
    compiler: *types.JanetCompiler,
    function: types.JanetSlot,
    original_minimum_arity: i32,
    form: [*]const types.Janet,
) raise.Raising(void) {
    if (function.flags & constants.JANET_SLOT_CONSTANT == 0) return;
    var minimum_arity = original_minimum_arity;

    switch (kind.typeOf(function.constant)) {
        constants.JANET_FUNCTION => {
            const function_value = wrap.toFunction(function.constant);
            const definition = function_value.*.def.?;
            const minimum = definition.*.min_arity;
            const maximum = definition.*.max_arity;
            const flags: u32 = @bitCast(definition.*.flags);
            const has_struct_argument = flags & constants.JANET_FUNCDEF_FLAG_STRUCTARG != 0;
            const has_named_arguments = flags & constants.JANET_FUNCDEF_FLAG_NAMEDARGS != 0;

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
                const form_length = types.tupleHead(form).length;
                while (argument_index < form_length) : (argument_index += 2) {
                    const argument_key = form[@intCast(argument_index)];
                    var found = false;
                    if (kind.checkType(argument_key, constants.JANET_KEYWORD) != 0) {
                        var named_index: i32 = 0;
                        while (named_index < definition.*.named_args_count and
                            named_index < definition.*.constants_length) : (named_index += 1)
                        {
                            if (order.equals(argument_key, definition.*.constants.?[@intCast(named_index)]) != 0) {
                                found = true;
                                break;
                            }
                        }
                    } else if (kind.checkType(argument_key, constants.JANET_TUPLE) != 0) {
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
        constants.JANET_CFUNCTION, constants.JANET_ABSTRACT, constants.JANET_NIL => {},
        constants.JANET_KEYWORD => {
            if (minimum_arity == 0) {
                recordError(compiler, try pp_format.formatc("%v expects at least 1 argument, got 0", .{function.constant}));
            }
        },
        else => {
            if (minimum_arity > 1 or minimum_arity == 0) {
                recordError(compiler, try pp_format.formatc("%v expects 1 argument, got %d", .{ function.constant, minimum_arity }));
            }
            if (minimum_arity < -2) {
                recordError(compiler, try pp_format.formatc("%v expects 1 argument, got at least %d", .{ function.constant, -1 - minimum_arity }));
            }
        },
    }
}

fn makeValue(options: types.JanetFopts, slots: ?[*]types.JanetSlot, operation: c_int) types.JanetSlot {
    const compiler: *types.JanetCompiler = options.compiler;
    const count = vectorCount(types.JanetSlot, slots);
    var can_inline = true;
    var index: i32 = 0;
    while (index < count) : (index += 1) {
        if (slots.?[@intCast(index)].flags & constants.JANET_SLOT_CONSTANT == 0 or
            slots.?[@intCast(index)].flags & constants.JANET_SLOT_SPLICED != 0)
        {
            can_inline = false;
            break;
        }
    }

    if (can_inline and operation == constants.JOP_MAKE_STRUCT) {
        const structure = structs.begin(@divTrunc(count, 2));
        index = 0;
        while (index < count) : (index += 2) {
            structs.put(structure, slots.?[@intCast(index)].constant, slots.?[@intCast(index + 1)].constant);
        }
        const result = cslot(wrap.fromStruct(structs.end(structure)));
        freeslots(compiler, slots);
        return result;
    }
    if (can_inline and operation == constants.JOP_MAKE_TUPLE) {
        const tuple = tuples.begin(count);
        index = 0;
        while (index < count) : (index += 1) tuple[@intCast(index)] = slots.?[@intCast(index)].constant;
        const result = cslot(wrap.fromTuple(tuples.end(tuple)));
        freeslots(compiler, slots);
        return result;
    }

    _ = pushslots(compiler, slots);
    freeslots(compiler, slots);
    const result = gettarget(options);
    _ = emit_core.emitSlot(compiler, @intCast(operation), result, 1);
    return result;
}

fn makeArray(options: types.JanetFopts, val: types.Janet) raise.Raising(types.JanetSlot) {
    const compiler: *types.JanetCompiler = options.compiler;
    const array = wrap.toArray(val);
    return makeValue(options, try janetc_toslotsImpl(compiler, array.*.data, array.*.count), constants.JOP_MAKE_ARRAY);
}

fn makeTuple(options: types.JanetFopts, val: types.Janet) raise.Raising(types.JanetSlot) {
    const compiler: *types.JanetCompiler = options.compiler;
    const tuple = wrap.toTuple(val);
    return makeValue(options, try janetc_toslotsImpl(compiler, tuple, types.tupleHead(tuple).length), constants.JOP_MAKE_TUPLE);
}

fn makeDictionary(options: types.JanetFopts, val: types.Janet, operation: c_int) raise.Raising(types.JanetSlot) {
    const compiler: *types.JanetCompiler = options.compiler;
    return makeValue(options, try janetc_toslotskvImpl(compiler, val), operation);
}

fn makeBuffer(options: types.JanetFopts, val: types.Janet) raise.Raising(types.JanetSlot) {
    const compiler: *types.JanetCompiler = options.compiler;
    const buffer = wrap.toBuffer(val);
    const argument = value.fromBytes(buffer.*.data.?[0..@intCast(buffer.*.count)], .string);
    return makeValue(options, try janetc_toslotsImpl(compiler, @ptrCast(&argument), 1), constants.JOP_MAKE_BUFFER);
}

pub fn janetc_pop_funcdefImpl(compiler: *types.JanetCompiler) raise.Raising(*types.JanetFuncDef) {
    const scope = compiler.scope.?;
    const definition = functions.defs.new();
    definition.*.slotcount = scope.*.ra.max + 1;
    compilerAssert(@intFromBool(scope.*.flags & constants.JANET_SCOPE_FUNCTION != 0), "expected function scope");

    definition.*.environments_length = vectorCount(types.JanetEnvRef, scope.*.envs);
    definition.*.environments = mallocArray(i32, definition.*.environments_length);
    var index: i32 = 0;
    while (index < definition.*.environments_length) : (index += 1) {
        definition.*.environments.?[@intCast(index)] = scope.*.envs.?[@intCast(index)].envindex;
    }

    definition.*.constants_length = vectorCount(types.Janet, scope.*.consts);
    definition.*.constants = flattenVector(types.Janet, scope.*.consts);
    definition.*.defs_length = vectorCount(*types.JanetFuncDef, scope.*.defs);
    definition.*.defs = flattenVector(*types.JanetFuncDef, scope.*.defs);

    definition.*.bytecode_length = vectorCount(u32, compiler.buffer) - scope.*.bytecode_start;
    if (definition.*.bytecode_length != 0) {
        definition.*.bytecode = mallocArray(u32, definition.*.bytecode_length);
        const bytecode_length: usize = @intCast(definition.*.bytecode_length);
        @memcpy(definition.*.bytecode.?[0..bytecode_length], compiler.buffer.?[@intCast(scope.*.bytecode_start)..][0..bytecode_length]);
        setVectorCount(u32, compiler.buffer.?, scope.*.bytecode_start);

        if (compiler.mapbuffer != null and compiler.source != null) {
            definition.*.sourcemap = mallocArray(types.JanetSourceMapping, definition.*.bytecode_length);
            @memcpy(definition.*.sourcemap.?[0..bytecode_length], compiler.mapbuffer.?[@intCast(scope.*.bytecode_start)..][0..bytecode_length]);
            setVectorCount(types.JanetSourceMapping, compiler.mapbuffer.?, scope.*.bytecode_start);
        }
    }

    definition.*.source = compiler.source;
    definition.*.arity = 0;
    definition.*.min_arity = 0;
    definition.*.flags = 0;
    if (scope.*.flags & constants.JANET_SCOPE_ENV != 0) definition.*.flags |= constants.JANET_FUNCDEF_FLAG_NEEDSENV;

    if (scope.*.ua.count != 0) {
        const slot_chunks = @divTrunc(definition.*.slotcount + 31, 32);
        const chunk_count = @min(slot_chunks, scope.*.ua.count);
        const memory = utils.calloc(@intCast(slot_chunks), @sizeOf(u32)) orelse fatal.outOfMemory();
        const chunks: [*]u32 = @ptrCast(@alignCast(memory));
        @memcpy(chunks[0..@intCast(chunk_count)], scope.*.ua.chunks.?[0..@intCast(chunk_count)]);
        if (scope.*.ua.count > 7 and slot_chunks > 7) chunks[7] &= 0xffff;
        definition.*.closure_bitset = chunks;
    }

    var locals: ?[*]types.JanetSymbolMap = null;
    var top = compiler.scope.?;
    while (top.parent) |parent| top = parent;
    var ancestor: ?*types.JanetScope = top;
    while (ancestor) |current| : (ancestor = current.child) {
        const environment_count = vectorCount(types.JanetEnvRef, scope.*.envs);
        var environment_index: i32 = 0;
        while (environment_index < environment_count) : (environment_index += 1) {
            const reference = scope.*.envs.?[@intCast(environment_index)];
            if (reference.scope != ancestor) continue;
            const symbol_count = vectorCount(types.SymPair, current.syms);
            var symbol_index: i32 = 0;
            while (symbol_index < symbol_count) : (symbol_index += 1) {
                const pair = current.syms.?[@intCast(symbol_index)];
                if (pair.sym2 != null) pushVector(types.JanetSymbolMap, &locals, .{
                    .birth_pc = std_max_u32,
                    .death_pc = @intCast(environment_index),
                    .slot_index = @intCast(pair.slot.index),
                    .symbol = pair.sym2,
                });
            }
        }
    }

    const symbol_count = vectorCount(types.SymPair, scope.*.syms);
    index = 0;
    while (index < symbol_count) : (index += 1) {
        const pair = scope.*.syms.?[@intCast(index)];
        if (pair.sym2 == null) continue;
        try if (pair.referenced == 0 and pair.sym != null) lintf(compiler, .strict, "binding %q is unused", .{wrap.fromSymbol(pair.sym.?)});
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
        pushVector(types.JanetSymbolMap, &locals, .{
            .birth_pc = birth_pc,
            .death_pc = death_pc,
            .slot_index = @intCast(pair.slot.index),
            .symbol = pair.sym2,
        });
    }
    definition.*.symbolmap_length = vectorCount(types.JanetSymbolMap, locals);
    definition.*.symbolmap = flattenVector(types.JanetSymbolMap, locals);
    if (definition.*.symbolmap_length != 0) definition.*.flags |= constants.JANET_FUNCDEF_FLAG_HASSYMBOLMAP;

    try janetc_popscopeImpl(compiler);
    optimize.bytecodeMovopt(definition);
    optimize.bytecodeRemoveNoops(definition);
    return definition;
}

pub fn compileLint(
    source: types.Janet,
    environment: *types.JanetTable,
    where: ?types.JanetString,
    lints: ?*types.JanetArray,
) callconv(.c) types.JanetCompileResult {
    return raise.reported(janet_compile_lintImpl(source, environment, where, lints));
}

pub fn janet_compile_lintImpl(
    source: types.Janet,
    environment: *types.JanetTable,
    where: ?types.JanetString,
    lints: ?*types.JanetArray,
) raise.Raising(types.JanetCompileResult) {
    var compiler: types.JanetCompiler = undefined;
    initCompiler(&compiler, environment, where, lints);

    var root_scope: types.JanetScope = undefined;
    pushScope(&root_scope, &compiler, constants.JANET_SCOPE_FUNCTION | constants.JANET_SCOPE_TOP, "root");
    const options = types.JanetFopts{
        .compiler = &compiler,
        .hint = cslot(wrapNil()),
        .flags = constants.JANET_FOPTS_TAIL | constants.JANET_SLOTTYPE_ANY,
    };
    _ = try janetc_valueImpl(options, source);

    if (compiler.result.status == constants.JANET_COMPILE_OK) {
        const definition = try janetc_pop_funcdefImpl(&compiler);
        definition.*.name = strings.cstring("thunk");
        defAddflags(definition);
        compiler.result.funcdef = definition;
    } else {
        compiler.result.error_mapping = compiler.current_mapping;
        try janetc_popscopeImpl(&compiler);
    }
    deinitCompiler(&compiler);
    return compiler.result;
}

pub fn compile(
    source: types.Janet,
    environment: *types.JanetTable,
    where: ?types.JanetString,
) callconv(.c) types.JanetCompileResult {
    return compileLint(source, environment, where, null);
}

fn initCompiler(
    compiler: *types.JanetCompiler,
    environment: *types.JanetTable,
    where: ?types.JanetString,
    lints: ?*types.JanetArray,
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
            .status = constants.JANET_COMPILE_OK,
        },
        .current_mapping = .{ .line = -1, .column = -1 },
        .recursion_guard = config.recursion_guard,
        .lints = lints,
        .is_redef = @intFromBool(kind.truthy(janet_table_get_keyword(environment, "redef")) != 0),
    };
}

fn deinitCompiler(compiler: *types.JanetCompiler) void {
    freeVector(u32, compiler.buffer);
    freeVector(types.JanetSourceMapping, compiler.mapbuffer);
    compiler.env = null;
}

fn pushVector(comptime Element: type, vector_pointer: *?[*]Element, val: Element) void {
    var vector = vector_pointer.*;
    const count = vectorCount(Element, vector);
    if (vector == null or count + 1 >= vectorCapacity(Element, vector.?)) {
        const grown = vector_mod.vGrow(if (vector) |v| @ptrCast(v) else null, 1, @sizeOf(Element));
        vector = @ptrCast(@alignCast(grown));
        vector_pointer.* = vector;
    }
    vector.?[@intCast(count)] = val;
    vectorHeader(Element, vector.?)[1] = count + 1;
}

fn freeVector(comptime Element: type, vector: ?[*]Element) void {
    if (vector) |v| gc_alloc.sfree(vectorHeader(Element, v));
}

fn flattenVector(comptime Element: type, vector: ?[*]Element) ?[*]Element {
    const opaque_vector: ?*anyopaque = if (vector) |v| @ptrCast(v) else null;
    const memory = vector_mod.vFlattenmem(opaque_vector, @sizeOf(Element));
    return @ptrCast(@alignCast(memory));
}

fn mallocArray(comptime Element: type, count: i32) ?[*]Element {
    const size = @sizeOf(Element) * @as(usize, @intCast(count));
    const memory = utils.malloc(size);
    if (memory == null and size != 0) fatal.outOfMemory();
    return @ptrCast(@alignCast(memory));
}

fn setVectorCount(comptime Element: type, vector: [*]Element, count: i32) void {
    vectorHeader(Element, vector)[1] = count;
}

fn vectorCount(comptime Element: type, vector: ?[*]Element) i32 {
    return if (vector) |v| vectorHeader(Element, v)[1] else 0;
}

fn vectorCapacity(comptime Element: type, vector: [*]Element) i32 {
    return vectorHeader(Element, vector)[0];
}

fn vectorHeader(comptime Element: type, vector: [*]Element) [*]i32 {
    return @ptrFromInt(@intFromPtr(vector) - vector_header_size);
}

const std_max_u32 = ~@as(u32, 0);

// ==========================================================================
// The cfunction surface
// ==========================================================================

fn cfunCompile(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    try vm_lifecycle.sandboxAssert(constants.JANET_SANDBOX_COMPILE);
    try args_core.arity(argv, 1, 4);

    var env: ?*types.JanetTable = if (@as(i32, @intCast(argv.len)) > 1 and kind.checkType(argv[1], constants.JANET_NIL) == 0)
        try args_core.getTable(argv, 1)
    else
        c.vm().fiber.?.env.?;
    if (env == null) {
        env = tables.new(0);
        c.vm().fiber.?.env = env;
    }

    var source: ?[*:0]const u8 = null;
    if (@as(i32, @intCast(argv.len)) >= 3) {
        const x = argv[2];
        if (kind.checkType(x, constants.JANET_STRING) != 0) {
            source = wrap.toString(x);
        } else if (kind.checkType(x, constants.JANET_KEYWORD) != 0) {
            source = wrap.toKeyword(x);
        } else if (kind.checkType(x, constants.JANET_NIL) == 0) {
            return args_core.panicType(x, 2, constants.JANET_TFLAG_STRING | constants.JANET_TFLAG_KEYWORD);
        }
    }

    const lints: ?*types.JanetArray = if (@as(i32, @intCast(argv.len)) >= 4 and kind.checkType(argv[3], constants.JANET_NIL) == 0)
        try args_core.getArray(argv, 3)
    else
        null;

    const result = try janet_compile_lintImpl(argv[0], env.?, source, lints);
    if (result.status == constants.JANET_COMPILE_OK) {
        return wrap.fromFunction(functions.thunk(result.funcdef.?));
    }

    // A failed compile is a value, not a raise: the caller asked to compile
    // something and gets back what went wrong and where.
    const table = tables.new(4);
    tables.put(table, value.fromBytes("error", .keyword), wrap.fromString(result.@"error".?));
    if (result.error_mapping.line > 0) {
        tables.put(table, value.fromBytes("line", .keyword), wrapInteger(result.error_mapping.line));
    }
    if (result.error_mapping.column > 0) {
        tables.put(table, value.fromBytes("column", .keyword), wrapInteger(result.error_mapping.column));
    }
    if (result.macrofiber != null) {
        tables.put(table, value.fromBytes("fiber", .keyword), wrap.fromFiber(result.macrofiber.?));
    }
    return wrap.fromTable(table);
}

pub fn libCompile(env: *types.JanetTable) void {
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
