//! Functions: a closure, the funcdef that is its bytecode, and the captured
//! environments that make the two different things.
//!
//! Two halves of two files. The name is not `alloc`: that word covered fiber
//! allocation *and* the funcdef machinery by saying nothing about either.
//!
//! **A near-miss worth keeping.** `janet_env_lookup` and
//! `janet_env_lookup_into` in `marsh.zig` look like they belong here and do
//! not. Their signature is `JanetTable *janet_env_lookup(JanetTable *env)` --
//! the *module environment table*, not a closure environment. Same word,
//! different thing.
//!
//! `janet_funcdef_alloc`, `janet_thunk` and `janet_thunk_delay` from the
//! bytecode side; `janet_env_valid` and `janet_env_maybe_detach` from the
//! fiber side. They are one leaf because they are one gap: the last
//! collectable kinds a caller cannot otherwise construct.
//!
//! ## Why the fiber's frame machinery is not here
//!
//! This file is allocation: who owns the memory. `value/fibers.zig` is the
//! frame machinery: what a call does to a stack. The boundary is the same one
//! uses it -- so the guard `fibers.zig` carries is a second, separate region
//! rather than an extension of the first.
//!
//! ## One call here can raise, and nothing is stranded when it does
//!
//! `fibers.reset` calls `fibers.funcframe`, which packs a variadic tail when
//! the callee takes one, which for a struct-argument function means
//! `structs.put`, which hashes the caller's arguments and so may run an
//! abstract type's `hash` callback. That callback is out of contract if it
//! raises, and records what happens anyway.
//!
//! Nothing is stranded when it does, and the reason is worth stating rather
//! than assuming. The fiber is on `vm.gc.blocks` from the moment `gcalloc`
//! returns, so the collector owns it whether or not this function ever returns;
//! its `data` array is reachable from the block and is freed with it.
//!
//! ## Two allocations per fiber, and only one of them is collectable
//!
//! A fiber is a collectable block through `gcalloc` and then a plain heap array
//! for the value stack, and the second is charged against
//! `vm.gc.next_collection` by hand -- `gcalloc` bills only what it allocated
//! itself. `fibers.setcapacity` maintains the same split, and the two have to
//! agree: a fiber allocated here and grown there must have been charged once
//! for its initial capacity and once per resize, never twice and never zero
//! times. `test/value_alloc.zig` checks the initial charge against the same
//! arithmetic `test/fiber_core.zig` checks the resize against.
//!
//! The 32-slot floor is applied *after* the capacity is used for nothing and
//! *before* it is written to the fiber, so a caller asking for 0 gets a fiber
//! whose `capacity` field reads 32 and whose budget charge is 32 slots. A
//! negative request lands on the same floor rather than wrapping into an
//! enormous allocation, which is the only reason the cast to `usize` below is
//! safe.
//!
//! ## The argument block is bounded
//!
//! `fibers.reset` sizes room for the caller's arguments with a checked add and
//! `fibers.grow`'s clamp, so an `argc` near `INT32_MAX` is refused by a bound
//! rather than by two wraps and a request for more bytes than there are
//! addresses. The refusal is the same fatal out-of-memory either way.
//!
//! ## `janet_thunk` asserts after it stores
//!
//! The C original writes `func->def = def` and *then* checks that the def needs
//! no upvalues. The order is preserved. It is observable only in a debugger
//! attached to the abort, since `janet_assert` is fatal and the block is never
//! seen by anything else, but the rule this phase has followed is that a port
//! reproduces the order of writes unless there is a reason to do otherwise, and
//! "it cannot matter" is not one.

const std = @import("std");
const gc_alloc = @import("../gc.zig");
const utils = @import("../utils.zig");
const fibers = @import("fibers.zig");
const wrap = @import("helpers/wrap.zig");
const fatal = @import("../fatal.zig");
const repr = @import("repr");
const abi = @import("abi");
const constants = @import("constants");
const vm_state = @import("../vm/state.zig");
const compiler_primitives = @import("../compiler.zig");
const strings = @import("strings.zig");

// ------------------------------------------------------------------ funcdefs
//
// A funcdef is the bytecode; a function is the bytecode plus its captured
// second a sub-namespace rather than a prefix: `functions.defs.new()` is
// `janet_funcdef_alloc`, where a bare `functions.new()` would name the wrong
// type.
// type.

pub const defs = struct {
    /// Allocate an empty funcdef. Every field is written, including the ones a
    /// zeroing allocator would have covered, because `janet_gcalloc` does not zero
    /// and the collector traverses a funcdef's pointer fields as soon as it is
    /// reachable.
    ///
    /// `max_arity` starts at `INT32_MAX` rather than 0, which is the one value
    /// here that is not simply "empty": an unfinished funcdef accepts any
    /// number of arguments until the assembler or the compiler narrows it.
    pub fn new() *FuncDef {
        const def = gc_alloc.gcalloc(FuncDef, .funcdef);
        def.environments = null;
        def.constants = null;
        def.bytecode = null;
        def.closure_bitset = null;
        def.flags = .{};
        def.slotcount = 0;
        def.symbolmap = null;
        def.arity = 0;
        def.min_arity = 0;
        def.max_arity = std.math.maxInt(i32);
        def.source = null;
        def.sourcemap = null;
        def.name = null;
        def.defs = null;
        def.defs_length = 0;
        def.constants_length = 0;
        def.bytecode_length = 0;
        def.environments_length = 0;
        def.symbolmap_length = 0;
        def.named_args_count = 0;
        return def;
    }
};

// ------------------------------------------------------------------ functions

/// Create a simple closure from a funcdef.
///
/// A thunk has no environments, so its block is exactly the header.
/// `test/value_alloc.zig` checks the figure against `@sizeOf`, the other
/// spelling.
pub fn thunk(def: *FuncDef) *Function {
    const func = gc_alloc.gcallocWithPayload(Function, .function, 0);
    func.def = def;
    if (def.environments_length != 0)
        fatal.fatal("tried to create thunk that needs upvalues");
    return func;
}

/// A function that, called, returns `x`. Trivial in Janet, a pain in C, and
/// here because both allocations it is assembled from are already in this file.
///
/// The two `janet_malloc`s are the C original's and are deliberately not
/// `janet_gcalloc`: a funcdef owns its bytecode and constants outright, and
/// the collector frees them through `janet_free` when the funcdef dies.
pub fn thunkDelay(x: repr.Value) *Function {
    const bytecode = [_]u32{
        constants.Opcode.load_constant.number(),
        constants.Opcode.@"return".number(),
    };
    const def = defs.new();
    def.arity = 0;
    def.min_arity = 0;
    def.max_arity = std.math.maxInt(i32);
    def.flags = .{ .vararg = true };
    def.slotcount = 1;
    def.bytecode = @ptrCast(@alignCast(utils.malloc(@sizeOf(@TypeOf(bytecode))) orelse
        fatal.outOfMemory()));
    def.bytecode_length = @intCast(bytecode.len);
    def.constants = @ptrCast(@alignCast(utils.malloc(@sizeOf(repr.Value)) orelse
        fatal.outOfMemory()));
    def.constants_length = 1;
    def.name = null;
    def.constantValues()[0] = x;
    @memcpy(def.instructions()[0..bytecode.len], &bytecode);
    compiler_primitives.defAddflags(def);
    return thunk(def);
}

// --------------------------------------------------- function environments
//
// A `JanetFuncEnv` is a *closure's* captured environment, which is why these
// three are here rather than with the fiber machinery they read. What that
// costs is worth stating, because it is the argument against a fourth leaf:
// validating an environment means walking the frames of the fiber it names, so
// this file asks `fibers` for the frame geometry -- `fibers.stackFrame`,
// `fibers.stackBytes`, `fibers.finished` -- rather than keeping a second copy
// of it. It goes the other way too: `envDetach` is what `fibers.popframe` and
// `fibers.funcframeTail` run over a frame's environment as they drop it, so
// the two files import each other. That is the second circular pair in
// `value/` after `tables`/`structs`, and Zig is as unbothered by it
// as it was there.
//
// **A leaf may duplicate a private predicate; it may not duplicate a definition
// anything else can observe.** Two copies of `stackBytes` had drifted apart
// once -- one trapped where the other wrapped a negative length into an
// enormous size, which is the behaviour `fibers.setcapacity` depends on -- and
// neither call site could see the difference.

/// Copy a closure environment off the fiber's stack so it can outlive the
/// frame that produced it. The values the function's `closure_bitset` does not
/// claim are dropped, which is what keeps a closure from rooting every local of
/// its defining frame.
pub fn envDetach(maybe_env: ?*FuncEnv) void {
    // Check for closure environment
    const env = maybe_env orelse return;
    // An environment the validator rejects has already been made the empty
    // off-stack variant -- which is what detaching produces -- and `as.values`
    // is the null it wrote over `as.fiber`. There is nothing left to copy and
    // nothing left to copy it from.
    if (!envValid(env)) return;
    const len = env.length;
    const bytes = fibers.stackBytes(len);
    const memory = utils.malloc(bytes);
    // The budget is bumped before the null check, and through a `uint32_t`
    // truncation, in the C original. Both are reproduced.
    vm_state.current().gc.next_collection +%= @as(u32, @truncate(bytes));
    if (memory == null) fatal.outOfMemory();
    const vmem: [*]repr.Value = @ptrCast(@alignCast(memory));
    const values = env.as.fiber.?.data.? + @as(usize, @bitCast(@as(isize, env.offset)));
    @memcpy(vmem[0..@intCast(len)], values[0..@intCast(len)]);
    const bitset = fibers.stackFrame(values).func.?.def.?.closure_bitset;
    if (bitset) |bits| {
        // Clear unneeded references in closure environment
        var i: i32 = 0;
        while (i < len) : (i += 32) {
            var mask = ~bits[@intCast(i >> 5)];
            const maxj = if (i + 32 > len) len else i + 32;
            var j = i;
            while (j < maxj) : (j += 1) {
                if (mask & 1 != 0) vmem[@intCast(j)] = wrap.fromNil();
                mask >>= 1;
            }
        }
    }
    env.offset = 0;
    env.as.values = vmem;
}

pub fn envValid(env: *FuncEnv) bool {
    if (env.offset >= 0) return true;
    const real_offset = -%env.offset;
    const fiber = env.as.fiber.?;
    var i = fiber.frame;
    while (i > 0) {
        const frame = fibers.stackFrame(fiber.data.? + @as(usize, @bitCast(@as(isize, i))));
        if (real_offset == i and frame.env == env) {
            if (frame.func) |func| {
                if (func.def.?.slotcount == env.length) {
                    env.offset = real_offset;
                    return true;
                }
            }
        }
        i = frame.prevframe;
    }
    // Invalid, set to empty off-stack variant.
    env.offset = 0;
    env.length = 0;
    env.as.values = null;
    return false;
}

/// Validate a potentially untrusted func env. An unmarshalled environment
/// records its stack offset negated; it is trustworthy only if a live frame of
/// the fiber it names still matches it exactly.
///
/// Detach an environment from its fiber once that fiber can no longer mutate
/// the slots the environment points at.
pub fn envMaybeDetach(env: *FuncEnv) void {
    // Check for detachable closure envs
    _ = envValid(env);
    if (env.offset > 0) {
        if (fibers.finished(env.as.fiber.?)) envDetach(env);
    }
}

/// `func->envs`, as an array the caller indexes. Both shapes the tree wants
/// come off it: `envsOf(f)[i]` is the environment and `&envsOf(f)[i]` is the
/// slot a marshaller writes through.
pub inline fn envsOf(func: *Function) [*]?*FuncEnv {
    return @ptrFromInt(@intFromPtr(func) +% function_envs);
}

/// **The fifth flexible array, which is not a head.** `JanetFunction` carries
/// its captured environments in the same allocation, so `func.envs[i]` is the
/// same arithmetic as a head's -- but the value Janet passes around is the
/// address of the *struct*, not of the payload, so nothing subtracts and no
/// negative offset appears anywhere. `DESIGN.md` §3's rule: point at the
/// payload only when the payload has to be raw, and an environment array does
/// not.
///
/// `@offsetOf` and not `@sizeOf`: four private copies wrote
/// `@sizeOf(JanetFunction)` for this offset and said `@offsetOf` was
/// unavailable, which a Zig-owned declaration with an ordinary `_envs` field
/// is not. `test/gc_mark.zig`'s `theHeadOffsets` checks the offset the
/// allocator actually used.
pub const function_envs = @offsetOf(Function, "_envs");

/// `extern` for the same reason: `function_envs` is `@offsetOf(_envs)` and
/// `gcallocWithPayload` sizes the block from `@sizeOf(Function)`, so the
/// flexible array has to stay at the end. `test/gc_mark.zig`'s
/// `theHeadOffsets` is the instrument, and it checks this one by reading what
/// lives at the computed slot rather than by differencing two addresses.
pub const Function = extern struct {
    gc: abi.GCObject = .{},
    def: ?*FuncDef = null,
    _envs: [0]?*FuncEnv = std.mem.zeroes([0]?*FuncEnv),
};

/// Bit 0 of the GC header's per-type field: `trace` was called on this
/// function, and the interpreter prints a line on entry and on return.
const own_traced: u6 = 1;

pub inline fn isTraced(function: *const Function) bool {
    return function.gc.flags.own & own_traced != 0;
}

pub inline fn setTraced(function: *Function, to: bool) void {
    if (to) {
        function.gc.flags.own |= own_traced;
    } else {
        function.gc.flags.own &= ~own_traced;
    }
}

pub const FuncDef = struct {
    gc: abi.GCObject = .{},
    environments: ?[*]i32 = null,
    constants: ?[*]repr.Value = null,
    defs: ?[*]*FuncDef = null,
    bytecode: ?[*]u32 = null,
    closure_bitset: ?[*]u32 = null,
    sourcemap: ?[*]SourceMapping = null,
    source: ?strings.String = null,
    name: ?strings.String = null,
    symbolmap: ?[*]SymbolMap = null,
    flags: FuncDefFlags = .{},
    slotcount: i32 = 0,
    arity: i32 = 0,
    min_arity: i32 = 0,
    max_arity: i32 = 0,
    constants_length: usize = 0,
    bytecode_length: usize = 0,
    environments_length: usize = 0,
    defs_length: usize = 0,
    symbolmap_length: usize = 0,
    named_args_count: i32 = 0,

    // The seven runs, each a pointer with a length somewhere else in the
    // structure. The pairing is what the accessor states, and it is not
    // derivable from the field names -- `sourcemap` is as long as the
    // *bytecode*, and `closure_bitset` is a bit per slot rounded up to a word.
    // The layout is fixed by `abi,field,repr` and does not move; what these
    // replace is 110 raw indexings.

    /// The constant pool. `JOP_LOAD_CONSTANT` indexes it.
    pub inline fn constantValues(self: anytype) utils.View(@TypeOf(self), repr.Value) {
        if (self.constants_length == 0) return &.{};
        return self.constants.?[0..self.constants_length];
    }

    /// The bytecode.
    pub inline fn instructions(self: anytype) utils.View(@TypeOf(self), u32) {
        if (self.bytecode_length == 0) return &.{};
        return self.bytecode.?[0..self.bytecode_length];
    }

    /// The captured environments, by index into the enclosing function's.
    pub inline fn environmentIndices(self: anytype) utils.View(@TypeOf(self), i32) {
        if (self.environments_length == 0) return &.{};
        return self.environments.?[0..self.environments_length];
    }

    /// The nested function definitions this one closes over.
    pub inline fn subdefs(self: anytype) utils.View(@TypeOf(self), *FuncDef) {
        if (self.defs_length == 0) return &.{};
        return self.defs.?[0..self.defs_length];
    }

    /// The debug symbol map: one entry per named slot, with the range of
    /// instructions it is live over.
    pub inline fn symbols(self: anytype) utils.View(@TypeOf(self), SymbolMap) {
        if (self.symbolmap_length == 0) return &.{};
        return self.symbolmap.?[0..self.symbolmap_length];
    }

    /// One source position per instruction. **Its length is
    /// `bytecode_length`**, which is the pairing this accessor exists to say:
    /// there is no `sourcemap_length` field and every caller was deriving it.
    /// Null with a non-zero bytecode length under `-Dsourcemaps=false`, which
    /// is why the pointer is tested and not only the count.
    pub inline fn sourceMappings(self: anytype) utils.View(@TypeOf(self), SourceMapping) {
        if (self.bytecode_length == 0) return &.{};
        const map = self.sourcemap orelse return &.{};
        return map[0..self.bytecode_length];
    }

    /// One bit per slot, rounded up to a word, saying which slots a closure
    /// captures. Absent -- null -- when the function captures nothing, which
    /// is the ordinary case and is why this answers empty rather than
    /// unwrapping.
    pub inline fn closureBits(self: anytype) utils.View(@TypeOf(self), u32) {
        const bits = self.closure_bitset orelse return &.{};
        if (self.slotcount <= 0) return &.{};
        return bits[0..@intCast((self.slotcount + 31) >> 5)];
    }
};

pub const FuncEnv = struct {
    gc: abi.GCObject = .{},
    as: FuncEnvRef = std.mem.zeroes(FuncEnvRef),
    length: i32 = 0,
    offset: i32 = 0,
};

/// A funcdef's flags: a sixteen-bit *tag* naming the core function this
/// definition is, and ten independent bits above it.
///
/// **The whole word is marshalled** -- `marsh.zig` writes it with `pushInt`
/// and reads it back -- so the layout is the format. `marshalFlags` and
/// `unmarshalFlags` are the two places it becomes an `i32`, and each asserts
/// the width at comptime beside the conversion.
///
/// `tag` is not a bitfield: it holds a `JANET_FUN_*` number, and
/// `optimize.funopt` indexes its optimizer table with `tag - 1`.
pub const FuncDefFlags = packed struct(u32) {
    /// Which core function this is, or zero for an ordinary definition.
    tag: u16 = 0,
    vararg: bool = false,
    needsenv: bool = false,
    hassymbolmap: bool = false,
    hasname: bool = false,
    hassource: bool = false,
    hasdefs: bool = false,
    hasenvs: bool = false,
    hassourcemap: bool = false,
    structarg: bool = false,
    hasclobitset: bool = false,
    namedargs: bool = false,
    _reserved: u5 = 0,

    /// The seven bits `janetc_def_addflags` owns, cleared. Everything else --
    /// the tag, `vararg`, `needsenv`, `hassymbolmap`, `structarg` -- is set
    /// elsewhere and survives.
    pub inline fn withoutControlled(self: FuncDefFlags) FuncDefFlags {
        var out = self;
        out.hasname = false;
        out.hassource = false;
        out.hasdefs = false;
        out.hasenvs = false;
        out.hassourcemap = false;
        out.hasclobitset = false;
        out.namedargs = false;
        return out;
    }
};

pub const SourceMapping = struct {
    line: i32 = 0,
    column: i32 = 0,
};

pub const SymbolMap = struct {
    birth_pc: u32 = 0,
    death_pc: u32 = 0,
    slot_index: u32 = 0,
    symbol: ?[*:0]const u8 = null,
};

/// `JanetFuncEnv.as`: an environment is either still on a fiber's stack or
/// has been closed over into its own array.
pub const FuncEnvRef = extern union {
    fiber: ?*fibers.Fiber,
    values: ?[*]repr.Value,
};
