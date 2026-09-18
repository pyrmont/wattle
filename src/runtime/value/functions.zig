//! A closure, the funcdef that is its bytecode, and the captured environments
//! that make the two different things.
//!
//! `defs.new` allocates an empty funcdef, `thunk` wraps one in a closure with
//! no captured environments, and `thunkDelay` builds both for a function that
//! returns a constant. The assembler, the compiler and the unmarshaller fill
//! in everything else.
//!
//! A `FuncEnv` is a closure's captured environment, and `envDetach`,
//! `envValid` and `envMaybeDetach` are its lifecycle. `marsh.zig`'s
//! environment lookups read like they belong beside them and do not: those
//! take a module environment table, which is a different thing under the same
//! word.
//!
//! ## What this file asks of `value/fibers.zig`
//!
//! Validating an environment means walking the frames of the fiber it names,
//! so this file reaches `fibers.stackFrame`, `fibers.stackBytes` and
//! `fibers.finished` rather than keeping a second copy of the frame geometry.
//! It goes the other way too: `envDetach` is what `fibers.popframe` and
//! `fibers.funcframeTailBegin` run over a frame's environment as they drop it,
//! so the two files import each other, which Zig permits.
//!
//! A leaf may duplicate a private predicate; it may not duplicate a definition
//! anything else can observe, so `stackBytes` is `fibers`' alone.
//! Its wrapping on a negative length is behaviour `fibers.setcapacity` depends
//! on, and a second copy that trapped instead would be invisible at both
//! sites.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const compiler_primitives = @import("../compiler.zig");
const constants = @import("constants");
const fatal = @import("../fatal.zig");
const fibers = @import("fibers.zig");
const gc_alloc = @import("../gc.zig");
const repr = @import("repr");
const strings = @import("strings.zig");
const utils = @import("../utils.zig");
const vm_state = @import("../vm/state.zig");
const wrap = @import("helpers/wrap.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// The offset of a `Function`'s environment array within its block.
///
/// A `Function` has its captured environments in the same allocation, so
/// `envsOf(f)[i]` is the arithmetic a head's payload takes. The value Janet
/// passes around is the address of the struct rather than of the payload, so
/// nothing subtracts and no negative offset appears anywhere.
///
/// `@offsetOf` and not `@sizeOf`: where the two can diverge, the offset is
/// right and the size is wrong. `test/gc_mark.zig`'s `theHeadOffsets` checks
/// the offset the allocator actually used.
pub const function_envs = @offsetOf(Function, "_envs");

/// Bit 0 of the GC header's per-type field: the function is traced. `vm.zig`
/// and `vm/entry.zig` consult it before printing a trace line.
const own_traced: u6 = 1;

// ==========================================================================
// Types
// ==========================================================================

/// A function definition: the bytecode, the constant pool, and everything the
/// debugger and the marshaller read alongside them.
///
/// The seven accessors below each pair a pointer with the length that goes
/// with it, which is not derivable from the field names: `sourcemap` is as
/// long as the bytecode, and `closure_bitset` is a bit per slot rounded up to
/// a word. Each returns an empty slice where its run is absent.
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

    /// The constant pool. `constants.Opcode.load_constant` indexes it.
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

    /// The nested function definitions this definition closes over.
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

    /// One source position per instruction. Its length is `bytecode_length`,
    /// which is the pairing this accessor exists to state: there is no
    /// `sourcemap_length` field to read instead. The pointer is null with a
    /// non-zero bytecode length under `-Dsourcemaps=false`, so the pointer is
    /// tested and not only the count.
    pub inline fn sourceMappings(self: anytype) utils.View(@TypeOf(self), SourceMapping) {
        if (self.bytecode_length == 0) return &.{};
        const map = self.sourcemap orelse return &.{};
        return map[0..self.bytecode_length];
    }

    /// One bit per slot, rounded up to a word, saying which slots a closure
    /// captures. Null when the function captures nothing, which is the
    /// ordinary case and is why this returns empty rather than unwrapping.
    pub inline fn closureBits(self: anytype) utils.View(@TypeOf(self), u32) {
        const bits = self.closure_bitset orelse return &.{};
        if (self.slotcount <= 0) return &.{};
        return bits[0..@intCast((self.slotcount + 31) >> 5)];
    }
};

/// A funcdef's flags: a sixteen-bit tag naming the core function this
/// definition is, and eleven independent bits above it.
///
/// The whole word is marshalled, `marsh.zig`'s `marshalOneDef` writing it with
/// `pushInt` and `unmarshalOneDef` reading it back, so the layout is the
/// format. Those two are also the only places it becomes an `i32`, and each
/// asserts the width at comptime beside the conversion.
///
/// `tag` is not a bitfield: it is a `JANET_FUN_*` number, and
/// `compiler/optimize.zig`'s `funopt` indexes its optimizer table with
/// `tag - 1`.
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
    maparg: bool = false,
    hasclobitset: bool = false,
    namedargs: bool = false,
    _reserved: u5 = 0,

    /// The seven bits `compiler.zig`'s `defAddflags` owns, cleared. The tag,
    /// `vararg`, `needsenv`, `hassymbolmap` and `maparg` are set elsewhere
    /// and survive.
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

/// A closure's captured environment: either a window onto a live fiber's
/// stack or an array of its own.
///
/// `offset` says which. Negative is an unmarshalled window `envValid` has yet
/// to check, positive is a window onto a live frame, and zero is a detached
/// array. `as` is read according to that.
pub const FuncEnv = struct {
    gc: abi.GCObject = .{},
    as: FuncEnvRef = std.mem.zeroes(FuncEnvRef),
    length: i32 = 0,
    offset: i32 = 0,
};

/// `FuncEnv.as`: an environment is either still on a fiber's stack or has been
/// closed over into its own array.
pub const FuncEnvRef = extern union {
    fiber: ?*fibers.Fiber,
    values: ?[*]repr.Value,
};

/// A closure: a funcdef and the environments captured with it.
///
/// `extern` because `function_envs` is `@offsetOf(_envs)` and
/// `gcallocWithPayload` sizes the block from `@sizeOf(Function)`, so the
/// flexible array has to stay at the end. `test/gc_mark.zig`'s
/// `theHeadOffsets` is the instrument, and it checks this layout by reading
/// what lives at the computed slot rather than by differencing two addresses.
pub const Function = extern struct {
    gc: abi.GCObject = .{},
    def: ?*FuncDef = null,
    _envs: [0]?*FuncEnv = std.mem.zeroes([0]?*FuncEnv),
};

/// One instruction's source position. `FuncDef.sourceMappings` is an array of
/// these, as long as the bytecode.
pub const SourceMapping = struct {
    line: i32 = 0,
    column: i32 = 0,
};

/// One named slot and the range of instructions it is live over.
/// `FuncDef.symbols` is an array of these.
pub const SymbolMap = struct {
    birth_pc: u32 = 0,
    death_pc: u32 = 0,
    slot_index: u32 = 0,
    symbol: ?[*:0]const u8 = null,
};

/// The funcdef half of the file, as a sub-namespace rather than a prefix, so
/// that `functions.defs.new()` names the funcdef where a bare
/// `functions.new()` would name the wrong type.
pub const defs = struct {
    /// Allocates an empty funcdef.
    ///
    /// Every field is written, including the fields a zeroing allocator would
    /// have covered, because `gcalloc` does not zero and the collector
    /// traverses a funcdef's pointer fields as soon as it is reachable.
    ///
    /// `max_arity` starts at `maxInt(i32)` rather than 0, which is the one
    /// field here that is not simply empty: an unfinished funcdef accepts any
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

// ==========================================================================
// Public functions
// ==========================================================================

/// Copies a closure environment off the fiber's stack so it can outlive the
/// frame that produced it.
///
/// `maybe_env` is the environment. Null and an environment `envValid` rejects
/// are both no-ops. The values the function's `closure_bitset` does not claim
/// are dropped, which is what stops a closure from rooting every local of its
/// defining frame.
pub fn envDetach(maybe_env: ?*FuncEnv) void {
    const env = maybe_env orelse return;
    // An environment the validator rejects has already been made the empty
    // off-stack variant, which is what detaching produces, and `as.values` is
    // the null it wrote over `as.fiber`. There is nothing left to copy and
    // nothing left to copy it from.
    if (!envValid(env)) return;
    const len = env.length;
    const bytes = fibers.stackBytes(len);
    const memory = utils.malloc(bytes);
    // The budget is bumped before the null check and through a 32-bit
    // truncation. A charge for an allocation that then fails is harmless,
    // since the process ends on the next line, and the truncation is what a
    // program's collection interval is computed from.
    vm_state.current().gc.next_collection +%= @as(u32, @truncate(bytes));
    if (memory == null) fatal.outOfMemory();
    const vmem: [*]repr.Value = @ptrCast(@alignCast(memory));
    const values = env.as.fiber.?.data.? + @as(usize, @bitCast(@as(isize, env.offset)));
    @memcpy(vmem[0..@intCast(len)], values[0..@intCast(len)]);
    const bitset = fibers.stackFrame(values).func.?.def.?.closure_bitset;
    if (bitset) |bits| {
        // Drop the references the bitset does not claim.
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

/// Detaches `env` from its fiber once that fiber can no longer mutate the
/// slots the environment points at.
pub fn envMaybeDetach(env: *FuncEnv) void {
    _ = envValid(env);
    if (env.offset > 0) {
        if (fibers.finished(env.as.fiber.?)) envDetach(env);
    }
}

/// Validates a func env that may have come from outside, and returns whether
/// it is usable.
///
/// `env` is the environment. An unmarshalled environment records its stack
/// offset negated, and it is trustworthy only where a live frame of the fiber
/// it names still matches it exactly. An environment this rejects is left as
/// the empty off-stack variant, so a caller that ignores the result reads
/// nothing stale out of it.
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
    // Rejected: leave it as the empty off-stack variant.
    env.offset = 0;
    env.length = 0;
    env.as.values = null;
    return false;
}

/// A function's environments, as an array the caller indexes.
///
/// `func` is the function. Both shapes the tree uses come off the result:
/// `envsOf(f)[i]` is the environment and `&envsOf(f)[i]` is the slot a
/// marshaller writes through.
pub inline fn envsOf(func: *Function) [*]?*FuncEnv {
    return @ptrFromInt(@intFromPtr(func) +% function_envs);
}

/// Whether `function` is traced.
pub inline fn isTraced(function: *const Function) bool {
    return function.gc.flags.own & own_traced != 0;
}

/// Sets or clears `function`'s traced bit. `to` is the state to leave it in.
pub inline fn setTraced(function: *Function, to: bool) void {
    if (to) {
        function.gc.flags.own |= own_traced;
    } else {
        function.gc.flags.own &= ~own_traced;
    }
}

/// Creates a closure over `def` with no captured environments.
///
/// A thunk has no environments, so its block is exactly the header, and this
/// aborts on a `def` that needs upvalues rather than returning a block with no
/// room for them. `test/gc_mark.zig` derives the header offset from the
/// allocator, which is what makes that sizing checkable.
///
/// The store of `def` comes before the check, an order nothing can observe,
/// because the abort is fatal and the block reaches nothing else. It is kept
/// anyway: that it cannot matter is not a reason to reorder two writes.
pub fn thunk(def: *FuncDef) *Function {
    const func = gc_alloc.gcallocWithPayload(Function, .function, 0);
    func.def = def;
    if (def.environments_length != 0)
        fatal.fatal("tried to create thunk that needs upvalues");
    return func;
}

/// Builds a function that, called, returns `x`.
///
/// Both allocations it is assembled from are this file's, so it lives here
/// rather than with the compiler.
///
/// The bytecode and the constant pool are plain heap allocations rather than
/// collectable ones: a funcdef owns both outright, and the collector frees
/// them with the funcdef.
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
