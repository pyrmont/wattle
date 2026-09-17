//! The compiler: a Janet value to a `functions.FuncDef`, and the scope, slot
//! and lint machinery it is built on.
//!
//! `compile` is the entry point and reports a `CompileResult` rather than
//! raising. `valueImpl` compiles one form and is what `compiler/specials.zig`
//! recurses through; `compileLintImpl` is the whole pass, from a fresh
//! `Compiler` to a verified definition.
//!
//! A `Slot` is where a compiled value lives, `Scope` is one lexical level, and
//! `pushScope`, `popscope` and `popscopeKeepslot` move between them. `resolve`
//! turns a symbol into a slot, `nameslot` binds one, and `gettarget`,
//! `farslot`, `cslot` and `freeslot` are the register bookkeeping around them.
//!
//! A compile error and a raise are two channels. `cerror` and `recordError`
//! record a message on the compiler and keep going, so the first error is the
//! one the user sees; a raise, from a macro, from the allocator or from a
//! value operation, returns `raise.Error` and travels. `lint` and `lintf` are
//! the third channel, for a message that is not an error at all.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const args_core = @import("args.zig");
const arrays = @import("value/arrays.zig");
const config = @import("config");
const constants = @import("constants");
const corefn = @import("corefn.zig");
const emit_core = @import("compiler/emit.zig");
const fatal = @import("fatal.zig");
const fibers = @import("value/fibers.zig");
const functions = @import("value/functions.zig");
const gc_alloc = @import("gc.zig");
const optimize = @import("compiler/optimize.zig");
const order = @import("value/helpers/order.zig");
const pp_format = @import("pp/format.zig");
const raise = @import("../api/raise.zig");
const regalloc = @import("compiler/regalloc.zig");
const registry = @import("registry.zig");
const repr = @import("repr");
const scratch_vector = @import("scratch_vector.zig");
const specials = @import("special_type.zig");
const specials_core = @import("compiler/specials.zig");
const strings = @import("value/strings.zig");
const structs = @import("value/structs.zig");
const tables = @import("value/tables.zig");
const tuples = @import("value/tuples.zig");
const utils = @import("utils.zig");
const value = @import("value.zig");
const vm_entry = @import("vm/entry.zig");
const vm_lifecycle = @import("vm/lifecycle.zig");
const vm_state = @import("vm/state.zig");
const wrap = @import("value/helpers/wrap.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// The largest `u32`, which a symbol map entry uses as its "no position"
/// marker.
const std_max_u32 = ~@as(u32, 0);

// ==========================================================================
// The cfunction surface
// ==========================================================================

// ==========================================================================
// Types
// ==========================================================================

/// What a compilation produced: a definition, or a message with the position
/// it was found at and the macro fiber it came from.
pub const CompileResult = struct {
    funcdef: ?*functions.FuncDef = null,
    @"error": ?strings.String = null,
    macrofiber: ?*fibers.Fiber = null,
    error_mapping: functions.SourceMapping = .{},
    status: CompileStatus = .ok,
};

/// Whether a compilation produced a definition or a message. Two members, and
/// nothing outside this runtime supplies one; `compile` gives back the keyword
/// a Janet program sees.
pub const CompileStatus = enum(u32) {
    ok = 0,
    @"error" = 1,
};

/// One compilation: the scope chain, the bytecode being emitted, the source
/// map beside it, the lints, and the result.
pub const Compiler = struct {
    scope: ?*Scope = null,
    buffer: std.ArrayListUnmanaged(u32) = .empty,
    mapbuffer: std.ArrayListUnmanaged(functions.SourceMapping) = .empty,
    env: ?*tables.Table = null,
    source: ?[*:0]const u8 = null,
    result: CompileResult = .{},
    current_mapping: functions.SourceMapping = .{},
    recursion_guard: c_int = 0,
    lints: ?*arrays.Array = null,
    is_redef: bool = false,

    /// The index the next instruction will occupy, as the signed label the
    /// jump arithmetic uses.
    ///
    /// Every jump in the emitted bytecode is a difference between two of
    /// these, and `emit.zig`'s `emitSl` computes `label - (here - 1)`, which
    /// is negative for a backward jump and reads one below zero on an empty
    /// buffer. The length is unsigned and the label is not; this is the one
    /// place that says so.
    pub fn here(self: *const Compiler) i32 {
        return @intCast(self.buffer.items.len);
    }
};

/// One captured environment a scope refers to, by index into the enclosing
/// function's.
pub const EnvRef = struct {
    envindex: i32 = 0,
    scope: ?*Scope = null,
};

/// What one step of macro expansion found.
///
/// Three outcomes, one of them with a payload, which is what makes it a union
/// rather than a flag beside two out-parameters.
const Expansion = union(enum) {
    /// A macro ran; this is its expansion, and the loop goes round again.
    expanded: repr.Value,
    /// The head names a special form. Expansion stops and the caller compiles
    /// it.
    special: *const specials.Special,
    /// Not a macro form, or the macro failed and recorded a compile error.
    done,
};

/// What a form's caller asks of it: drop the result, take a tail position,
/// accept a splice, or take the hint slot as the target.
pub const FormFlags = packed struct(u32) {
    /// The types the caller will accept. Written and not read; see
    /// `SlotFlags.types`.
    types: repr.TagSet = .{},
    tail: bool = false,
    hint: bool = false,
    drop: bool = false,
    accept_splice: bool = false,
    _reserved: u12 = 0,
};

/// One form's compilation context: the compiler, the target hint and the
/// flags.
pub const FormOptions = struct {
    compiler: *Compiler,
    hint: Slot = .{},
    flags: FormFlags = .{},
};

/// How one core function compiles to bytecode instead of a call.
///
/// Neither slot is `callconv(.c)`: the table is built in
/// `compiler/optimize.zig` and read here, and nothing outside this tree fills
/// one in. `optimize` is not optional either, because an entry with no
/// `optimize` would be an optimizer that does not optimize.
pub const FunctionOptimizer = struct {
    /// Whether this call has a shape the optimizer handles. Absent means "any".
    can_optimize: ?*const fn (opts: FormOptions, args: []const Slot) bool = null,
    optimize: *const fn (opts: FormOptions, args: []const Slot) Slot,
};

/// How loudly a lint is filed. `(compile ...)` takes the level a caller asks
/// for and drops anything quieter.
pub const LintLevel = enum(c_uint) {
    relaxed = constants.JANET_C_LINT_RELAXED,
    normal = constants.JANET_C_LINT_NORMAL,
    strict = constants.JANET_C_LINT_STRICT,

    /// This level as the keyword a lint tuple records.
    fn keyword(self: LintLevel) [*:0]const u8 {
        return switch (self) {
            .relaxed => "relaxed",
            .normal => "normal",
            .strict => "strict",
        };
    }
};

/// A compiler scope: one lexical level, with its registers, its named slots,
/// its constants and its nested definitions.
///
/// It is not `extern`: its four vectors are `std.ArrayListUnmanaged`, which
/// has a slice in it, and a slice has no C representation. Nothing needs one,
/// because every use of this type is a local `var` or a pointer.
///
/// The vectors belong to the scratch allocator; `scratch_vector.zig` says why,
/// and is where they are pushed and freed.
pub const Scope = struct {
    name: [*]const u8,
    parent: ?*Scope = null,
    child: ?*Scope = null,
    consts: std.ArrayListUnmanaged(repr.Value) = .empty,
    syms: std.ArrayListUnmanaged(SymPair) = .empty,
    defs: std.ArrayListUnmanaged(*functions.FuncDef) = .empty,
    ra: regalloc.RegisterAllocator = .{},
    ua: regalloc.RegisterAllocator = .{},
    envs: std.ArrayListUnmanaged(EnvRef) = .empty,
    bytecode_start: i32 = 0,
    flags: ScopeFlags = .{},
};

/// A scope's own flags: whether it is a function scope, the top scope, a loop
/// body, or closed over.
pub const ScopeFlags = packed struct(c_uint) {
    function: bool = false,
    env: bool = false,
    top: bool = false,
    unused: bool = false,
    closure: bool = false,
    /// A `while` body, which is what forbids a closure capturing its scope.
    while_body: bool = false,
    _reserved: u26 = 0,
};

/// What a new binding hides, if anything.
///
/// `shadowcheck` decides it and `shadowLint` is the only reader. The numbers
/// are internal to the compiler and nothing serializes them.
pub const Shadowing = enum(c_uint) {
    none = 0,
    macro = 1,
    global_hides_global = 2,
    local_hides_global = 3,
    local_hides_local = 4,
};

/// Where a compiled value lives: a register, a constant, or a slot of a
/// captured environment.
pub const Slot = struct {
    constant: repr.Value = std.mem.zeroes(repr.Value),
    index: i32 = 0,
    envindex: i32 = 0,
    flags: SlotFlags = .{},
};

/// A compiled slot's flags: a type mask in the low sixteen bits and nine
/// independent bits above it.
///
/// The type mask is a `repr.TagSet`, so `cslot` builds one with `TagSet.one`
/// and any type is `TagSet.all`. A raw tag written where a mask is meant has
/// no spelling against this layout.
pub const SlotFlags = packed struct(u32) {
    /// Which Janet types this slot may take. Written in six places and read in
    /// none: an inference channel that is built and not consumed. It is
    /// kept because it is what the field *is*, and `sequal` masks it out.
    types: repr.TagSet = .{},
    constant: bool = false,
    named: bool = false,
    mutable: bool = false,
    ref: bool = false,
    returned: bool = false,
    dep_note: bool = false,
    dep_warn: bool = false,
    dep_error: bool = false,
    spliced: bool = false,
    _reserved: u7 = 0,

    /// Everything but the type mask, which is what `emit.sequal` compares.
    pub inline fn withoutTypes(self: SlotFlags) SlotFlags {
        var out = self;
        out.types = .{};
        return out;
    }
};

/// One named slot in a scope: the slot, the name, and the range of
/// instructions it is live over.
pub const SymPair = struct {
    slot: Slot = .{},
    sym: ?[*:0]const u8 = null,
    sym2: ?[*:0]const u8 = null,
    keep: bool = false,
    referenced: bool = false,
    birth_pc: u32 = 0,
    death_pc: u32 = 0,
};

// ==========================================================================
// Public functions
// ==========================================================================

/// Records `message` as a compile error and keeps compiling.
pub fn cerror(compiler: *Compiler, message: [*:0]const u8) void {
    recordError(compiler, strings.cstring(message));
}

/// Compiles `source` into a `CompileResult`, at the lint level a caller asks
/// for.
pub fn compile(
    source: repr.Value,
    environment: *tables.Table,
    where: ?strings.String,
) raise.Error!CompileResult {
    return compileLintImpl(source, environment, where, null);
}

/// The whole compile pass: a fresh compiler, the root scope, the form, the
/// return, and the verified definition.
pub fn compileLintImpl(
    source: repr.Value,
    environment: *tables.Table,
    where: ?strings.String,
    lints: ?*arrays.Array,
) raise.Error!CompileResult {
    var compiler: Compiler = undefined;
    initCompiler(&compiler, environment, where, lints);

    var root_scope: Scope = undefined;
    pushScope(&root_scope, &compiler, .{ .function = true, .top = true }, "root");
    const options = FormOptions{
        .compiler = &compiler,
        .hint = cslot(wrapNil()),
        .flags = .{ .tail = true, .types = .all },
    };
    _ = try valueImpl(options, source);

    if (compiler.result.status == .ok) {
        const definition = try popFuncdef(&compiler);
        definition.name = strings.cstring("thunk");
        defAddflags(definition);
        compiler.result.funcdef = definition;
    } else {
        compiler.result.error_mapping = compiler.current_mapping;
        try popscope(&compiler);
    }
    deinitCompiler(&compiler);
    return compiler.result;
}

/// Emits the return of `slot_value` and marks the slot returned.
pub fn compileReturn(compiler: *Compiler, slot_value: Slot) Slot {
    var result = slot_value;
    if (!result.flags.returned) {
        if (result.flags.constant and repr.checkType(result.constant, repr.Tag.nil)) {
            emit_core.emit(compiler, constants.Opcode.return_nil.number());
        } else {
            _ = emit_core.emitSlot(compiler, .@"return", result, 0);
        }
        result.flags.returned = true;
    }
    return result;
}

/// `val` as a constant slot, with its type mask set from the value's own tag.
pub fn cslot(val: repr.Value) Slot {
    const value_type = repr.typeOf(val);
    return .{
        .constant = val,
        .index = -1,
        .envindex = -1,
        .flags = .{ .types = .one(value_type), .constant = true },
    };
}

/// The scope the compiler is in, which is never null once `compileLintImpl`
/// has pushed the root one.
pub inline fn currentScope(compiler: *Compiler) *Scope {
    return compiler.scope orelse unreachable;
}

/// Computes a definition's flag bits from the optional parts it has.
pub fn defAddflags(definition: *functions.FuncDef) void {
    // The seven "has" bits say which optional parts the definition has, so
    // each is a read of the field it describes rather than a flag anyone sets
    // by hand. Everything else the definition already had survives.
    var flags = definition.flags.withoutControlled();
    flags.hasname = definition.name != null;
    flags.hassource = definition.source != null;
    flags.hasdefs = definition.defs != null;
    flags.hasenvs = definition.environments != null;
    flags.hassourcemap = definition.sourcemap != null;
    flags.hasclobitset = definition.closure_bitset != null;
    flags.namedargs = definition.named_args_count != 0;
    definition.flags = flags;
}

/// A fresh far register as a slot, or null where the allocator refused.
pub fn farslot(compiler: *Compiler) ?Slot {
    const register = currentScope(compiler).ra.allocate();
    if (register > 0xffff) {
        cerror(compiler, "ran out of internal registers");
        return null;
    }
    return .{
        .constant = wrapNil(),
        .index = @intCast(register),
        .envindex = -1,
        .flags = .{ .types = .all },
    };
}

/// The default form options: no hint, no flags.
pub fn foptsDefault(compiler: *Compiler) FormOptions {
    return .{
        .compiler = compiler,
        .hint = cslot(wrapNil()),
        .flags = .{},
    };
}

/// Releases the register `slot` occupies, where it occupies one.
pub fn freeslot(compiler: *Compiler, slot: Slot) void {
    if (slot.flags.constant or slot.flags.ref or slot.flags.named) return;
    if (slot.envindex >= 0) return;
    currentScope(compiler).ra.free(@intCast(slot.index));
}

/// Releases every register a slot vector occupies, and the vector itself.
pub fn freeslots(compiler: *Compiler, slots: scratch_vector.Vector(Slot)) void {
    for (slots.items) |slot| freeslot(compiler, slot);
    var owned = slots;
    scratch_vector.free(&owned);
}

/// The slot a form should write its result into: the caller's hint where it
/// gave one, and a fresh register otherwise.
pub fn gettarget(options: FormOptions) Slot {
    if (options.flags.hint and
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
        .flags = .{},
    };
}

/// Installs `compile` into `env`.
pub fn libCompile(env: *tables.Table) void {
    const entries = comptime [_]corefn.Entry{
        corefn.reg("compile", &cfunCompile, @src(), "(compile ast &opt env source lints)", "Compiles an Abstract Syntax Tree (ast) into a function. " ++
            "Pair the compile function with parsing functionality to implement " ++
            "eval. Returns a new function and does not modify ast. Returns an error " ++
            "struct with keys :line, :column, and :error if compilation fails. " ++
            "If a `lints` array is given, linting messages will be appended to the array. " ++
            "Each message will be a tuple of the form `(level line col message)`."),
    };
    corefn.install(env, entries);
}

/// Files a lint with nothing to interpolate.
///
/// The string is interned after the level test, so a build collecting no lints
/// allocates nothing.
pub fn lint(
    compiler: *Compiler,
    level: LintLevel,
    message: [*:0]const u8,
) raise.Error!void {
    if (compiler.lints == null) return;
    try record(compiler, level, strings.cstring(message));
}

/// Binds `symbol` to `slot` in the current scope, lints what it shadows, and
/// gives back the slot the name now refers to.
pub fn nameslot(
    compiler: *Compiler,
    symbol: [*:0]const u8,
    slot: Slot,
    flags: u32,
) raise.Error!void {
    if (flags & constants.JANET_DEFFLAG_NO_SHADOWCHECK == 0 and symbol[0] != '_') {
        try shadowLint(compiler, symbol, shadowcheck(compiler, symbol));
    }
    const instruction_count = compiler.buffer.items.len;
    var named_slot = slot;
    named_slot.flags.named = true;
    scratch_vector.push(&currentScope(compiler).syms, .{
        .slot = named_slot,
        .sym = symbol,
        .sym2 = symbol,
        .keep = false,
        .referenced = flags & constants.JANET_DEFFLAG_NO_UNUSED != 0 or symbol[0] == '_',
        .birth_pc = @intCast(if (instruction_count != 0) instruction_count - 1 else 0),
        .death_pc = std_max_u32,
    });
}

/// Finishes the definition the current function scope built, and pops it.
pub fn popFuncdef(compiler: *Compiler) raise.Error!*functions.FuncDef {
    const scope = currentScope(compiler);
    const definition = functions.defs.new();
    definition.slotcount = @intCast(scope.ra.max + 1);
    compilerAssert(scope.flags.function, "expected function scope");

    definition.environments_length = scope.envs.items.len;
    definition.environments = mallocArray(i32, definition.environments_length);
    for (scope.envs.items, definition.environmentIndices()) |ref, *out| out.* = ref.envindex;

    definition.constants_length = scope.consts.items.len;
    definition.constants = scratch_vector.flatten(repr.Value, scope.consts);
    definition.defs_length = scope.defs.items.len;
    definition.defs = scratch_vector.flatten(*functions.FuncDef, scope.defs);

    definition.bytecode_length = @intCast(compiler.here() - scope.bytecode_start);
    if (definition.bytecode_length != 0) {
        definition.bytecode = mallocArray(u32, definition.bytecode_length);
        @memcpy(definition.instructions(), compiler.buffer.items[@intCast(scope.bytecode_start)..][0..definition.bytecode_length]);
        compiler.buffer.shrinkRetainingCapacity(@intCast(scope.bytecode_start));

        if (compiler.mapbuffer.items.len != 0 and compiler.source != null) {
            definition.sourcemap = mallocArray(functions.SourceMapping, definition.bytecode_length);
            @memcpy(definition.sourceMappings(), compiler.mapbuffer.items[@intCast(scope.bytecode_start)..][0..definition.bytecode_length]);
            compiler.mapbuffer.shrinkRetainingCapacity(@intCast(scope.bytecode_start));
        }
    }

    definition.source = compiler.source;
    definition.arity = 0;
    definition.min_arity = 0;
    definition.flags = .{};
    if (scope.flags.env) definition.flags.needsenv = true;

    const used_chunks = scope.ua.chunks.items;
    if (used_chunks.len != 0) {
        const slot_chunks = @divTrunc(definition.slotcount + 31, 32);
        const chunk_count = @min(@as(usize, @intCast(slot_chunks)), used_chunks.len);
        const chunks = utils.allocManyZeroed(u32, @intCast(slot_chunks));
        @memcpy(chunks[0..chunk_count], used_chunks[0..chunk_count]);
        if (used_chunks.len > 7 and slot_chunks > 7) chunks[7] &= 0xffff;
        definition.closure_bitset = chunks;
    }

    var locals: scratch_vector.Vector(functions.SymbolMap) = .empty;
    var top = currentScope(compiler);
    while (top.parent) |parent| top = parent;
    var ancestor: ?*Scope = top;
    while (ancestor) |current| : (ancestor = current.child) {
        for (scope.envs.items, 0..) |reference, environment_index| {
            if (reference.scope != ancestor) continue;
            for (current.syms.items) |pair| {
                if (pair.sym2 != null) scratch_vector.push(&locals, .{
                    .birth_pc = std_max_u32,
                    .death_pc = @intCast(environment_index),
                    .slot_index = @intCast(pair.slot.index),
                    .symbol = pair.sym2,
                });
            }
        }
    }

    for (scope.syms.items) |pair| {
        if (pair.sym2 == null) continue;
        if (!pair.referenced) if (pair.sym) |symbol| {
            try lintf(compiler, .strict, "binding %q is unused", .{wrap.fromSymbol(symbol)});
        };
        const death_pc: u32 = if (pair.death_pc == std_max_u32)
            @intCast(definition.bytecode_length)
        else
            pair.death_pc - @as(u32, @intCast(scope.bytecode_start));
        const birth_pc: u32 = if (@as(u32, @intCast(scope.bytecode_start)) > pair.birth_pc)
            0
        else
            pair.birth_pc - @as(u32, @intCast(scope.bytecode_start));
        compilerAssert(birth_pc <= death_pc, "birth pc after death pc");
        compilerAssert(birth_pc < definition.bytecode_length, "bad birth pc");
        compilerAssert(death_pc <= definition.bytecode_length, "bad death pc");
        scratch_vector.push(&locals, .{
            .birth_pc = birth_pc,
            .death_pc = death_pc,
            .slot_index = @intCast(pair.slot.index),
            .symbol = pair.sym2,
        });
    }
    definition.symbolmap_length = locals.items.len;
    definition.symbolmap = scratch_vector.flatten(functions.SymbolMap, locals);
    if (definition.symbolmap_length != 0) definition.flags.hassymbolmap = true;

    try popscope(compiler);
    optimize.bytecodeMovopt(definition);
    optimize.bytecodeRemoveNoops(definition);
    return definition;
}

/// Pops the current scope, releasing its registers and vectors.
pub fn popscope(compiler: *Compiler) raise.Error!void {
    const old_scope = currentScope(compiler);
    const new_scope = old_scope.parent;
    if (!old_scope.flags.function and !old_scope.flags.unused) if (new_scope) |parent| {
        if (old_scope.flags.closure) {
            parent.flags.closure = true;
        }
        if (parent.ra.max < old_scope.ra.max) {
            parent.ra.max = old_scope.ra.max;
        }

        for (old_scope.syms.items) |original| {
            var pair = original;
            if (!pair.referenced) if (pair.sym) |symbol| {
                try lintf(compiler, .strict, "binding %q is unused", .{wrap.fromSymbol(symbol)});
            };
            pair.sym = null;
            if (pair.death_pc == std_max_u32) {
                pair.death_pc = @intCast(compiler.buffer.items.len);
            }
            if (pair.keep) {
                pair.sym2 = null;
                parent.ra.touch(@intCast(pair.slot.index));
            }
            scratch_vector.push(&parent.syms, pair);
        }
    };

    scratch_vector.free(&old_scope.consts);
    scratch_vector.free(&old_scope.syms);
    scratch_vector.free(&old_scope.envs);
    scratch_vector.free(&old_scope.defs);
    old_scope.ra.deinit();
    old_scope.ua.deinit();
    if (new_scope) |parent| parent.child = null;
    compiler.scope = new_scope;
}

/// The same as `popscope`, but keeping one slot alive in the parent scope.
pub fn popscopeKeepslot(
    compiler: *Compiler,
    return_slot: Slot,
) raise.Error!void {
    try popscope(compiler);
    if (return_slot.envindex < 0 and return_slot.index >= 0) if (compiler.scope) |current| {
        current.ra.touch(@intCast(return_slot.index));
    };
}

/// Pushes a new scope onto the chain, with `name` for a stack trace.
pub fn pushScope(
    result: *Scope,
    compiler: *Compiler,
    flags: ScopeFlags,
    name: [*]const u8,
) void {
    var scope: Scope = undefined;
    scope.name = name;
    scope.parent = compiler.scope;
    scope.child = null;
    scope.consts = .empty;
    scope.syms = .empty;
    scope.defs = .empty;
    scope.envs = .empty;
    scope.bytecode_start = compiler.here();
    scope.flags = flags;
    scope.ua = .{};
    const inherited: ?*Scope = if (flags.function) null else compiler.scope;
    if (inherited) |current| {
        scope.ra = current.ra.clone();
    } else {
        scope.ra = .{};
    }
    if (compiler.scope) |current| current.child = result;
    compiler.scope = result;
    result.* = scope;
}

/// Emits the pushes that put `slots` on the argument stack, and gives back how
/// many were pushed.
pub fn pushslots(compiler: *Compiler, slots: []const Slot) i32 {
    const count: i32 = @intCast(slots.len);
    var index: i32 = 0;
    var minimum_arity: i32 = 0;
    var has_splice = false;
    while (index < count) {
        if (slots[@intCast(index)].flags.spliced) {
            _ = emit_core.emitSlot(compiler, .push_array, slots[@intCast(index)], 0);
            index += 1;
            has_splice = true;
        } else if (index + 1 == count) {
            _ = emit_core.emitSlot(compiler, .push, slots[@intCast(index)], 0);
            index += 1;
            minimum_arity += 1;
        } else if (slots[@intCast(index + 1)].flags.spliced) {
            _ = emit_core.emitSlot(compiler, .push, slots[@intCast(index)], 0);
            _ = emit_core.emitSlot(compiler, .push_array, slots[@intCast(index + 1)], 0);
            index += 2;
            minimum_arity += 1;
            has_splice = true;
        } else if (index + 2 == count) {
            _ = emit_core.emitSs(compiler, .push_2, slots[@intCast(index)], slots[@intCast(index + 1)], 0);
            index += 2;
            minimum_arity += 2;
        } else if (slots[@intCast(index + 2)].flags.spliced) {
            _ = emit_core.emitSs(compiler, .push_2, slots[@intCast(index)], slots[@intCast(index + 1)], 0);
            _ = emit_core.emitSlot(compiler, .push_array, slots[@intCast(index + 2)], 0);
            index += 3;
            minimum_arity += 2;
            has_splice = true;
        } else {
            _ = emit_core.emitSss(
                compiler,
                .push_3,
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

/// Records `message` as a compile error, keeping the first one filed.
pub fn recordError(compiler: *Compiler, message: ?[*:0]const u8) void {
    if (compiler.result.status == .@"error") return;
    compiler.result.status = .@"error";
    compiler.result.@"error" = message;
}

/// Resolves `symbol` to a slot: a local, a captured environment slot, or a
/// global binding.
pub fn resolve(compiler: *Compiler, symbol: [*:0]const u8) raise.Error!Slot {
    var scope = compiler.scope;
    var found_pair: ?*SymPair = null;
    var found_local = true;
    var unused = false;

    search: while (scope) |current| : (scope = current.parent) {
        if (current.flags.unused) unused = true;
        var index = current.syms.items.len;
        while (index > 0) {
            index -= 1;
            const pair = &current.syms.items[index];
            if (pair.sym == symbol) {
                found_pair = pair;
                break :search;
            }
        }
        if (current.flags.function) found_local = false;
    }

    const pair = found_pair orelse return resolveGlobal(compiler, symbol);
    var result = pair.slot;
    pair.referenced = true;
    if (result.flags.constant or result.flags.ref) return result;
    if (unused or found_local) {
        result.envindex = -1;
        return result;
    }

    const original_scope = scope;
    pair.keep = true;
    while (scope) |current| {
        if (current.flags.function) break;
        scope = current.parent;
    }
    const function_scope = scope orelse fatal.fatal("invalid scopes");
    function_scope.flags.env = true;
    function_scope.ua.touch(@intCast(result.index));
    scope = function_scope.child;

    var environment_index: i32 = -1;
    while (scope) |current| : (scope = current.child) {
        if (!current.flags.function) continue;
        const environment_count = current.envs.items.len;
        var found = false;
        for (current.envs.items, 0..) |ref, index| {
            if (ref.envindex == environment_index) {
                found = true;
                environment_index = @intCast(index);
                break;
            }
        }
        if (!found) {
            scratch_vector.push(&current.envs, .{
                .envindex = environment_index,
                .scope = original_scope,
            });
            environment_index = @intCast(environment_count);
        }
    }
    result.envindex = environment_index;
    return result;
}

/// What binding `symbol` would shadow in the current scope, if any.
pub fn shadowcheck(compiler: *Compiler, symbol: [*:0]const u8) Shadowing {
    var scope = compiler.scope;
    const is_global = currentScope(compiler).flags.top;
    while (scope) |current| : (scope = current.parent) {
        var index = current.syms.items.len;
        while (index > 0) {
            index -= 1;
            if (current.syms.items[index].sym == symbol) {
                return if (is_global) .global_hides_global else .local_hides_local;
            }
        }
    }
    const binding = registry.resolveExt(compiler.env.?, symbol);
    if (binding.type == .macro or binding.type == .dynamic_macro)
        return .macro;
    if (binding.type == .none) return .none;
    return if (is_global) .global_hides_global else .local_hides_global;
}

/// Compiles `val` for its effect and releases whatever slot it produced.
pub fn throwaway(options: FormOptions, val: repr.Value) raise.Error!void {
    const compiler: *Compiler = options.compiler;
    const bytecode_start = compiler.buffer.items.len;
    const source_map_start = compiler.mapbuffer.items.len;
    var unused_scope: Scope = undefined;
    pushScope(&unused_scope, compiler, .{ .unused = true }, "unused");
    _ = try valueImpl(options, val);
    try lintf(compiler, .strict, "dead code, consider removing %.4q", .{val});
    try popscope(compiler);
    compiler.buffer.shrinkRetainingCapacity(bytecode_start);
    compiler.mapbuffer.shrinkRetainingCapacity(source_map_start);
}

/// Compiles every element of an indexed value into a slot vector.
pub fn toslots(
    compiler: *Compiler,
    values: ?[*]const repr.Value,
    length: usize,
) raise.Error!scratch_vector.Vector(Slot) {
    var result: scratch_vector.Vector(Slot) = .empty;
    var options = foptsDefault(compiler);
    options.flags.accept_splice = true;
    for (0..length) |index| {
        scratch_vector.push(&result, try valueImpl(options, values.?[index]));
    }
    return result;
}

/// Compiles every key and value of a dictionary into one slot vector,
/// alternating.
pub fn toslotskv(compiler: *Compiler, dictionary: repr.Value) raise.Error!scratch_vector.Vector(Slot) {
    var result: scratch_vector.Vector(Slot) = .empty;
    var options = foptsDefault(compiler);
    options.flags.accept_splice = true;
    const view = args_core.dictionaryView(dictionary).?;

    var stack_indices: [32]i32 = undefined;
    var heap_indices: ?[*]i32 = null;
    const indices: [*]i32 = if (view.len < stack_indices.len)
        &stack_indices
    else blk: {
        const allocated: [*]i32 = @ptrCast(@alignCast(gc_alloc.smalloc(@sizeOf(i32) * @as(usize, @intCast(view.len)))));
        heap_indices = allocated;
        break :blk allocated;
    };
    if (view.len != 0) _ = utils.sortedKeys(view.kvs.?, @intCast(view.cap), indices);
    for (0..view.len) |index| {
        const pair = view.kvs.?[@intCast(indices[index])];
        scratch_vector.push(&result, try valueImpl(options, pair.key));
        scratch_vector.push(&result, try valueImpl(options, pair.value));
    }
    // One exit rather than a `defer`, and it may as well say so. Nothing leaks
    // either way: scratch memory is reclaimed by the next collection, and that
    // reclamation is what the scratch allocator is used here for.
    if (heap_indices) |allocated| gc_alloc.sfree(allocated);
    return result;
}

/// Compiles one form into a slot, which is what every special form and every
/// call recurses through.
pub fn valueImpl(options: FormOptions, original_value: repr.Value) raise.Error!Slot {
    const compiler: *Compiler = options.compiler;
    const previous_mapping = compiler.current_mapping;
    compiler.recursion_guard -= 1;
    if (compiler.result.status == .@"error") return cslot(wrapNil());
    if (compiler.recursion_guard <= 0) {
        cerror(compiler, "recursed too deeply");
        return cslot(wrapNil());
    }

    var val = original_value;
    var result: Slot = undefined;
    var special: ?*const specials.Special = null;
    var expansions: i32 = config.max_macro_expand;
    while (expansions != 0 and compiler.result.status != .@"error") {
        switch (try expandMacroOnce(compiler, val)) {
            .expanded => |expanded| {
                val = expanded;
                expansions -= 1;
            },
            .special => |found| {
                special = found;
                break;
            },
            .done => break,
        }
    }
    if (expansions == 0) {
        cerror(compiler, "recursed too deeply in macro expansion");
        return cslot(wrapNil());
    }

    if (special) |special_form| {
        const tuple = wrap.toTuple(val);
        result = try special_form.compile.?(options, tuple[1..tuples.head(tuple).length]);
    } else {
        switch (repr.typeOf(val)) {
            repr.Tag.tuple => {
                const tuple = wrap.toTuple(val);
                const length = tuples.head(tuple).length;
                if (length == 0) {
                    result = cslot(wrap.fromTuple(tuples.newFrom(&.{})));
                } else if (tuples.isBracketed(tuples.head(tuple))) {
                    result = try makeTuple(options, val);
                } else {
                    var suboptions = foptsDefault(compiler);
                    const function = try valueImpl(suboptions, tuple[0]);
                    suboptions.flags = .{ .types = .of(&.{ .function, .cfunction }) };
                    result = try compileCall(
                        options,
                        try toslots(compiler, tuple + 1, @intCast(length - 1)),
                        function,
                        tuple,
                    );
                    freeslot(compiler, function);
                }
                result.flags.spliced = false;
            },
            // A keyword is a constant, and a symbol names a binding.
            repr.Tag.symbol => result = if (wrap.isKeyword(val)) cslot(val) else try resolve(compiler, wrap.toSymbol(val)),
            repr.Tag.array => result = try makeArray(options, val),
            repr.Tag.@"struct" => result = try makeDictionary(options, val, constants.Opcode.make_struct),
            repr.Tag.table => result = try makeDictionary(options, val, constants.Opcode.make_table),
            repr.Tag.buffer => result = try makeBuffer(options, val),
            else => result = cslot(val),
        }
    }

    if (compiler.result.status == .@"error") return cslot(wrapNil());
    if (options.flags.tail) result = compileReturn(compiler, result);
    if (options.flags.hint) {
        emit_core.copy(compiler, options.hint, result);
        result = options.hint;
    }
    compiler.current_mapping = previous_mapping;
    compiler.recursion_guard += 1;
    return result;
}

// ==========================================================================
// Private functions
// ==========================================================================

/// The three wrong-number-of-arguments errors, which differ only in their
/// format string and in which bound they name.
///
/// `%s` selects the plural, so the count is passed twice.
fn arityError(
    compiler: *Compiler,
    comptime format: [:0]const u8,
    function: repr.Value,
    expected: i32,
    got: i32,
) raise.Error!void {
    const plural: [*]const u8 = if (expected == 1) "" else "s";
    recordError(compiler, try pp_format.formatc(format, .{ function, expected, plural, got }));
}

/// `compile`: the cfunction, which turns the result into the struct a Janet
/// program reads.
fn cfunCompile(argv: []repr.Value) raise.Error!repr.Value {
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"compile"}));
    try args_core.arity(argv, 1, 4);

    // The fiber's environment is created on demand: `.env` is null on a fiber
    // nobody has given one to. Unwrapping it here trapped instead, and the
    // `if (env == null)` that followed, which allocated one and stored it back
    // on the fiber, could never fire, because both branches above it give back
    // a non-null table.
    const env: *tables.Table = if (argv.len > 1 and !repr.checkType(argv[1], repr.Tag.nil))
        try args_core.getTable(argv, 1)
    else fiber_env: {
        const fiber = vm_state.current().fiber.?;
        break :fiber_env fiber.env orelse {
            const fresh = tables.new(0);
            fiber.env = fresh;
            break :fiber_env fresh;
        };
    };

    var source: ?[*:0]const u8 = null;
    if (argv.len >= 3) {
        const x = argv[2];
        if (repr.checkType(x, repr.Tag.string)) {
            source = wrap.toString(x);
        } else if (wrap.isKeyword(x)) {
            source = wrap.toKeyword(x);
        } else if (!repr.checkType(x, repr.Tag.nil)) {
            return pp_format.panicf("bad slot #2, expected string or keyword, got %v", .{x});
        }
    }

    const lints: ?*arrays.Array = if (argv.len >= 4 and !repr.checkType(argv[3], repr.Tag.nil))
        try args_core.getArray(argv, 3)
    else
        null;

    const result = try compileLintImpl(argv[0], env, source, lints);
    if (result.status == .ok) {
        return wrap.fromFunction(functions.thunk(result.funcdef.?));
    }

    // A failed compile is a value, not a raise: the caller asked to compile
    // something and gets back what went wrong and where.
    const table = tables.new(4);
    tables.put(table, value.fromBytes("error", .keyword), wrap.fromString(result.@"error".?));
    if (result.error_mapping.line > 0) {
        tables.put(table, value.fromBytes("line", .keyword), wrap.fromInteger(result.error_mapping.line));
    }
    if (result.error_mapping.column > 0) {
        tables.put(table, value.fromBytes("column", .keyword), wrap.fromInteger(result.error_mapping.column));
    }
    if (result.macrofiber) |fiber| {
        tables.put(table, value.fromBytes("fiber", .keyword), wrap.fromFiber(fiber));
    }
    return wrap.fromTable(table);
}

/// Compiles a call form, taking the builtin optimizer where the callee has
/// one.
fn compileCall(
    options: FormOptions,
    slots: scratch_vector.Vector(Slot),
    function: Slot,
    form: [*]const repr.Value,
) raise.Error!Slot {
    const compiler: *Compiler = options.compiler;
    var result: Slot = undefined;
    if (!tryCallOptimizer(options, slots.items, function, &result)) {
        const minimum_arity = pushslots(compiler, slots.items);
        try validateCall(compiler, function, minimum_arity, form);
        if (options.flags.tail and !currentScope(compiler).flags.top) {
            _ = emit_core.emitSlot(compiler, .tailcall, function, 0);
            result = cslot(wrapNil());
            result.flags = .{ .returned = true };
        } else {
            result = gettarget(options);
            _ = emit_core.emitSs(compiler, .call, result, function, 1);
        }
    }
    freeslots(compiler, slots);
    return result;
}

/// Aborts unless `condition`.
///
/// Not a raise: a broken scope chain is a defect in this file rather than a
/// program error. Same shape as `peg.zig`'s `pegAssert`.
inline fn compilerAssert(condition: bool, message: [*:0]const u8) void {
    if (!condition) fatal.fatal(message);
}

/// Releases the compiler's own vectors. The scopes are the caller's.
fn deinitCompiler(compiler: *Compiler) void {
    scratch_vector.free(&compiler.buffer);
    scratch_vector.free(&compiler.mapbuffer);
    compiler.env = null;
}

/// Expands one macro form, or reports that the head is a special form or
/// neither.
fn expandMacroOnce(compiler: *Compiler, val: repr.Value) raise.Error!Expansion {
    if (!repr.checkType(val, repr.Tag.tuple)) return .done;
    const form = wrap.toTuple(val);
    const length = tuples.head(form).length;
    if (length == 0) return .done;

    const head = utils.tupleHead(form);
    if (head.sm_line >= 0) {
        compiler.current_mapping.line = head.sm_line;
        compiler.current_mapping.column = head.sm_column;
    }
    if (tuples.isBracketed(head)) return .done;
    if (!wrap.isSymbol(form[0])) return .done;

    const name = wrap.toSymbol(form[0]);
    if (specials_core.lookupSpecial(name)) |special| return .{ .special = special };

    const binding = registry.resolve(compiler.env.?, name);
    if ((binding.type != .macro and binding.type != .dynamic_macro) or
        !repr.checkType(binding.value, repr.Tag.function))
    {
        return .done;
    }
    return .{ .expanded = try runMacro(compiler, val, binding.value) orelse return .done };
}

/// Sets up a compiler over `env`, with the root scope not yet pushed.
fn initCompiler(
    compiler: *Compiler,
    environment: *tables.Table,
    where: ?strings.String,
    lints: ?*arrays.Array,
) void {
    compiler.* = .{
        .scope = null,
        .buffer = .empty,
        .mapbuffer = .empty,
        .env = environment,
        .source = where,
        .result = .{
            .funcdef = null,
            .@"error" = null,
            .macrofiber = null,
            .error_mapping = .{ .line = -1, .column = -1 },
            .status = .ok,
        },
        .current_mapping = .{ .line = -1, .column = -1 },
        .recursion_guard = config.recursion_guard,
        .lints = lints,
        .is_redef = repr.truthy(tables.getKeyword(environment, "redef")),
    };
}

/// Files a lint, formatting the message only where anyone is listening.
///
/// The null test on `lints` comes first because `pp_format.formatc`
/// allocates, an allocation can collect, and a build that asked for no lints
/// should pay for none of that.
fn lintf(
    compiler: *Compiler,
    level: LintLevel,
    comptime format: [:0]const u8,
    args: anytype,
) raise.Error!void {
    if (compiler.lints == null) return;
    try record(compiler, level, try pp_format.formatc(format, args));
}

/// Asks the environment's `:missing-symbol` handler for a binding.
///
/// It gives back nothing having recorded a compile error: a failure here is
/// recorded on the compiler rather than returned, and the absent binding is
/// what the caller acts on. The error union is a different channel: rendering
/// the handler's own failure runs the formatter, which can raise, and
/// `resolveGlobal` passes that on.
fn lookupMissing(
    compiler: *Compiler,
    symbol: [*:0]const u8,
    handler: *functions.Function,
) raise.Error!?registry.Binding {
    const definition = handler.def.?;
    if (definition.min_arity > 1 or definition.max_arity < 1) {
        recordError(compiler, strings.cstring("missing symbol lookup handler must take 1 argument"));
        return null;
    }
    var args = [_]repr.Value{wrap.fromSymbol(symbol)};
    const fiber = fibers.new(handler, 64, &args) catch {
        recordError(compiler, strings.cstring("failed to call missing symbol lookup handler"));
        return null;
    };
    fiber.env = compiler.env;
    const lock = gc_alloc.gclock(vm_state.current());
    const resumed = vm_entry.continueFiber(fiber, wrapNil());
    gc_alloc.gcunlock(vm_state.current(), lock);
    if (resumed.signal != abi.Signal.ok) {
        recordError(compiler, try pp_format.formatc("(lookup) %V", .{resumed.value}));
        return null;
    }
    return registry.bindingFromEntry(resumed.value);
}

/// Emits the array constructor over the slots already gathered.
fn makeArray(options: FormOptions, val: repr.Value) raise.Error!Slot {
    const compiler: *Compiler = options.compiler;
    const array = wrap.toArray(val);
    return makeValue(options, try toslots(compiler, array.data, @intCast(array.count)), constants.Opcode.make_array);
}

/// Emits the buffer constructor over the slots already gathered.
fn makeBuffer(options: FormOptions, val: repr.Value) raise.Error!Slot {
    const compiler: *Compiler = options.compiler;
    const buffer = wrap.toBuffer(val);
    const argument = value.fromBytes(buffer.slice(), .string);
    return makeValue(options, try toslots(compiler, @ptrCast(&argument), 1), constants.Opcode.make_buffer);
}

/// Emits the table or struct constructor over the slots already gathered.
fn makeDictionary(options: FormOptions, val: repr.Value, operation: constants.Opcode) raise.Error!Slot {
    const compiler: *Compiler = options.compiler;
    return makeValue(options, try toslotskv(compiler, val), operation);
}

/// Emits the tuple constructor over the slots already gathered.
fn makeTuple(options: FormOptions, val: repr.Value) raise.Error!Slot {
    const compiler: *Compiler = options.compiler;
    const tuple = wrap.toTuple(val);
    return makeValue(options, try toslots(compiler, tuple, tuples.head(tuple).length), constants.Opcode.make_tuple);
}

/// Emits the constructor for one aggregate literal, by opcode.
fn makeValue(options: FormOptions, slots: scratch_vector.Vector(Slot), operation: constants.Opcode) Slot {
    const compiler: *Compiler = options.compiler;
    const count = slots.items.len;
    var can_inline = true;
    for (slots.items) |slot| {
        if (!slot.flags.constant or slot.flags.spliced) {
            can_inline = false;
            break;
        }
    }

    if (can_inline and operation == constants.Opcode.make_struct) {
        const structure = structs.begin(@intCast(count / 2));
        var index: usize = 0;
        while (index < count) : (index += 2) {
            structs.put(structure, slots.items[index].constant, slots.items[index + 1].constant);
        }
        const result = cslot(wrap.fromStruct(structs.end(structure)));
        freeslots(compiler, slots);
        return result;
    }
    if (can_inline and operation == constants.Opcode.make_tuple) {
        const tuple = tuples.begin(@intCast(count));
        for (0..count) |index| tuple[index] = slots.items[index].constant;
        const result = cslot(wrap.fromTuple(tuples.end(tuple)));
        freeslots(compiler, slots);
        return result;
    }

    _ = pushslots(compiler, slots.items);
    freeslots(compiler, slots);
    const result = gettarget(options);
    _ = emit_core.emitSlot(compiler, operation, result, 1);
    return result;
}

/// `count` elements of `T` from the runtime's allocator.
fn mallocArray(comptime Element: type, count: usize) ?[*]Element {
    const size = @sizeOf(Element) * count;
    const memory = utils.malloc(size);
    if (memory == null and size != 0) fatal.outOfMemory();
    return @ptrCast(@alignCast(memory));
}

/// Appends one finished lint, tagged with the level and the form's position.
///
/// A line or column of -1 means the source had no mapping there, and becomes
/// nil rather than -1 in the tuple.
fn record(compiler: *Compiler, level: LintLevel, message: [*:0]const u8) raise.Error!void {
    const payload = tuples.begin(4);
    payload[0] = value.fromBytes(std.mem.span(level.keyword()), .keyword);
    payload[1] = if (compiler.current_mapping.line == -1) wrapNil() else wrap.fromInteger(compiler.current_mapping.line);
    payload[2] = if (compiler.current_mapping.column == -1) wrapNil() else wrap.fromInteger(compiler.current_mapping.column);
    payload[3] = wrap.fromString(message);
    try arrays.push(compiler.lints.?, wrap.fromTuple(tuples.end(payload)));
}

/// Resolves `symbol` against the environment, asking the `:missing-symbol`
/// handler where the environment has none.
fn resolveGlobal(compiler: *Compiler, symbol: [*:0]const u8) raise.Error!Slot {
    var binding = registry.resolveExt(compiler.env.?, symbol);
    if (binding.type == .none) {
        const handler = tables.getKeyword(compiler.env.?, "missing-symbol");
        switch (repr.typeOf(handler)) {
            repr.Tag.nil => {},
            repr.Tag.function => {
                binding = try lookupMissing(compiler, symbol, wrap.toFunction(handler)) orelse
                    return cslot(wrapNil());
            },
            else => {
                recordError(compiler, try pp_format.formatc("invalid lookup handler %V", .{handler}));
                return cslot(wrapNil());
            },
        }
    }

    var result = cslot(binding.value);
    switch (binding.type) {
        .def, .macro => {},
        .dynamic_def, .dynamic_macro => {
            result.flags.ref = true;
            result.flags.named = true;
            result.flags.types = .all;
            result.flags.constant = false;
        },
        .@"var" => {
            result.flags.ref = true;
            result.flags.named = true;
            result.flags.mutable = true;
            result.flags.types = .all;
            result.flags.constant = false;
        },
        // `.none` and anything unrecognised, which take the same arm.
        else => {
            recordError(compiler, try pp_format.formatc("unknown symbol %q", .{wrap.fromSymbol(symbol)}));
            return cslot(wrapNil());
        },
    }

    switch (binding.deprecation) {
        .none => {},
        .relaxed => try lintf(compiler, .relaxed, "%q is deprecated", .{wrap.fromSymbol(symbol)}),
        .normal => try lintf(compiler, .normal, "%q is deprecated", .{wrap.fromSymbol(symbol)}),
        .strict => try lintf(compiler, .strict, "%q is deprecated", .{wrap.fromSymbol(symbol)}),
    }
    return result;
}

/// Runs one macro and reports its failure as a compile error.
///
/// The `:macro-form` and `:macro-lints` bindings are put into the environment
/// for the macro to read and cleared afterwards, unconditionally, including
/// the lints key that may never have been set.
fn runMacro(
    compiler: *Compiler,
    form_value: repr.Value,
    macro_value: repr.Value,
) raise.Error!?repr.Value {
    const form = wrap.toTuple(form_value);
    const macro = wrap.toFunction(macro_value);
    const arity = tuples.head(form).length - 1;
    const fiber = fibers.new(macro, 64, (form + 1)[0..@intCast(arity)]) catch {
        const definition = macro.def.?;
        const minimum = definition.min_arity;
        const maximum = definition.max_arity;
        var message: ?[*:0]const u8 = null;
        if (minimum >= 0 and arity < minimum)
            message = try pp_format.formatc("macro arity mismatch, expected at least %d, got %d", .{ minimum, arity });
        if (maximum >= 0 and arity > maximum)
            message = try pp_format.formatc("macro arity mismatch, expected at most %d, got %d", .{ maximum, arity });
        compiler.result.macrofiber = null;
        recordError(compiler, message);
        return null;
    };
    fiber.env = compiler.env;
    const lock = gc_alloc.gclock(vm_state.current());
    const form_keyword = value.fromBytes("macro-form", .keyword);
    tables.put(compiler.env.?, form_keyword, form_value);
    const lints_keyword = value.fromBytes("macro-lints", .keyword);
    if (compiler.lints) |lints| {
        tables.put(compiler.env.?, lints_keyword, wrap.fromArray(lints));
    }
    const resumed = vm_entry.continueFiber(fiber, wrapNil());
    tables.put(compiler.env.?, form_keyword, wrapNil());
    tables.put(compiler.env.?, lints_keyword, wrapNil());
    gc_alloc.gcunlock(vm_state.current(), lock);
    if (resumed.signal != abi.Signal.ok) {
        compiler.result.macrofiber = fiber;
        recordError(compiler, try pp_format.formatc("(macro) %V", .{resumed.value}));
        return null;
    }
    return resumed.value;
}

/// The four shadowing lints, by what is being shadowed.
fn shadowLint(compiler: *Compiler, symbol: [*:0]const u8, shadowing: Shadowing) raise.Error!void {
    const name = wrap.fromSymbol(symbol);
    switch (shadowing) {
        .macro => try lintf(compiler, .normal, "binding %q is shadowing a macro", .{name}),
        .local_hides_local => try lintf(compiler, .strict, "binding %q is shadowing a binding", .{name}),
        .local_hides_global => try lintf(compiler, .strict, "binding %q is shadowing a top-level binding", .{name}),
        .global_hides_global => try lintf(compiler, .strict, "top-level binding %q is shadowing another top-level binding", .{name}),
        .none => {},
    }
}

/// Compiles a call through the builtin optimizer, or reports that it did not
/// apply.
fn tryCallOptimizer(
    options: FormOptions,
    slots: []const Slot,
    function: Slot,
    result: *Slot,
) bool {
    if (!function.flags.constant) return false;
    for (slots) |slot| {
        if (slot.flags.spliced) return false;
    }
    if (!repr.checkType(function.constant, repr.Tag.function)) return false;
    const function_value = wrap.toFunction(function.constant);
    const optimizer = optimize.funopt(function_value.def.?.flags) orelse return false;
    if (optimizer.can_optimize) |can_optimize| {
        if (!can_optimize(options, slots)) return false;
    }
    result.* = optimizer.optimize(options, slots);
    return true;
}

// ==========================================================================
// Resolving a global, and the two escapes into user code
//
// `lookupMissing` and `runMacro` both suspend the compiler to run a Janet
// function in a fresh fiber: the first is the `:missing-symbol` handler, the
// second is a macro expansion. Both keep the shape Janet gives them,
// including the GC lock that keeps the compiler's own structures alive across
// the call.
// ==========================================================================

/// Checks a call's arity against the callee's, recording an error where it
/// does not fit.
fn validateCall(
    compiler: *Compiler,
    function: Slot,
    original_minimum_arity: i32,
    form: [*]const repr.Value,
) raise.Error!void {
    if (!function.flags.constant) return;
    var minimum_arity = original_minimum_arity;

    switch (repr.typeOf(function.constant)) {
        repr.Tag.function => {
            const function_value = wrap.toFunction(function.constant);
            const definition = function_value.def.?;
            const minimum = definition.min_arity;
            const maximum = definition.max_arity;
            const has_struct_argument = definition.flags.structarg;
            const has_named_arguments = definition.flags.namedargs;

            if (minimum_arity < 0) {
                minimum_arity = -1 - minimum_arity;
                if (maximum >= 0 and minimum_arity > maximum) {
                    try arityError(compiler, "%v expects at most %d argument%s, got at least %d", function.constant, maximum, minimum_arity);
                }
                return;
            }
            if (maximum >= 0 and minimum_arity > maximum) {
                try arityError(compiler, "%v expects at most %d argument%s, got %d", function.constant, maximum, minimum_arity);
            }
            if (minimum_arity < minimum) {
                try arityError(compiler, "%v expects at least %d argument%s, got %d", function.constant, minimum, minimum_arity);
            }
            if (has_struct_argument and
                minimum_arity > definition.arity and
                (minimum_arity - definition.arity) & 1 != 0)
            {
                if (has_named_arguments) {
                    try lintf(compiler, .normal, "odd number of named arguments to `&named` function %v", .{function.constant});
                } else {
                    try lintf(compiler, .normal, "odd number of named arguments to `&keys` function %v", .{function.constant});
                }
            }
            if (has_named_arguments and definition.named_args_count > 0) {
                var argument_index = definition.arity + 1;
                const form_length = tuples.head(form).length;
                while (argument_index < form_length) : (argument_index += 2) {
                    const argument_key = form[@intCast(argument_index)];
                    var found = false;
                    if (wrap.isKeyword(argument_key)) {
                        var named_index: i32 = 0;
                        while (named_index < definition.named_args_count and
                            named_index < definition.constants_length) : (named_index += 1)
                        {
                            if (order.equals(argument_key, definition.constantValues()[@intCast(named_index)])) {
                                found = true;
                                break;
                            }
                        }
                    } else if (repr.checkType(argument_key, repr.Tag.tuple)) {
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
        repr.Tag.cfunction, repr.Tag.abstract, repr.Tag.nil => {},
        // A keyword is called as a method on its first argument, and anything
        // else callable is a lookup of one key.
        else => if (wrap.isKeyword(function.constant)) {
            if (minimum_arity == 0) {
                recordError(compiler, try pp_format.formatc("%v expects at least 1 argument, got 0", .{function.constant}));
            }
        } else {
            if (minimum_arity > 1 or minimum_arity == 0) {
                recordError(compiler, try pp_format.formatc("%v expects 1 argument, got %d", .{ function.constant, minimum_arity }));
            }
            if (minimum_arity < -2) {
                recordError(compiler, try pp_format.formatc("%v expects 1 argument, got at least %d", .{ function.constant, -1 - minimum_arity }));
            }
        },
    }
}

/// A nil, named so the error paths read as one thing.
inline fn wrapNil() repr.Value {
    return wrap.fromNil();
}

// ==========================================================================
// Lints
//
// A lint is a note the compiler files against a program it is willing to
// compile anyway: a shadowed binding, a deprecated name, unreachable code.
// They go into `c->lints` when the caller asked for them and are dropped
// otherwise.
//
// It is not variadic. A variadic definition is out of reach anyway: Zig 0.16
// cannot name a `va_list` on `aarch64-linux`. Nothing outside the compiler
// front end calls this, so its argument list is an ordinary Zig tuple that the
// compiler counts and type-checks.
//
// The message itself goes through `pp_format.formatc`, so `%q`, `%v` and
// `%.4q` mean what they mean everywhere else in the tree.
// ==========================================================================
