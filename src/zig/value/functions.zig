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
//! uses it -- so the guard `fiber.c` now carries is a second, separate region
//! rather than an extension of the first.
//!
//! The two selectors are independent. `-Dvalue-alloc=c -Dfiber-core=zig` and
//! its mirror both build and both pass, because everything crossing between
//! them is a public entry point: this file calls `janet_fiber_setcapacity` and
//! `janet_fiber_funcframe` by name and does not care which selector answered.
//!
//! ## The file is jump-transparent, and one call is why
//!
//! `janet_fiber_reset` calls `janet_fiber_funcframe`, which packs a variadic
//! tail when the callee takes one, which for a `JANET_FUNCDEF_FLAG_STRUCTARG`
//! function means `janet_struct_put`, which hashes the caller's arguments and
//! so may run an abstract type's `hash` callback. That callback can panic --
//! SPIKE-8 forbids it and records what happens anyway -- and a panic is a
//! `longjmp` that goes straight through the Zig frame below.
//! There is no `defer` in this file and `build.zig` checks that there is not.
//!
//! Nothing is stranded when that jump happens, and the reason is worth stating
//! rather than assuming. The fiber `janet_fiber` has just allocated is on
//! `vm.gc.blocks` from the moment `janet_gcalloc` returns, so the collector
//! owns it whether or not this function ever returns; its `data` array is
//! reachable from the block and is freed with it. The half-built frame the
//! signal leaves behind is exactly what C leaves behind, because C runs the
//! same statements in the same order.
//!
//! ## Two allocations per fiber, and only one of them is collectable
//!
//! `fiber_alloc` makes a `JANET_MEMORY_FIBER` block through `janet_gcalloc`
//! and then a plain `janet_malloc` array for the value stack, and charges the
//! second against `vm.gc.next_collection` by hand -- `janet_gcalloc` bills
//! only what it allocated itself. That is the same split
//! `janet_fiber_setcapacity` maintains in `fiber_core.zig`, and the two have to
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
//! ## Arithmetic reproduced rather than repaired
//!
//! `janet_fiber_reset` computes `fiber->stacktop + argc` and then
//! `2 * newstacktop` in `int32_t`. Both overflow for large enough arguments and
//! signed overflow is undefined in C, so a build with different optimisation
//! settings can already disagree with itself there. Wrapping operators are used
//! below to give one defined answer, the two's-complement one every compiler in
//! practice produces, rather than to trap: a trap would be a new behaviour at a
//! point where the C original has none, and `janet_fiber_setcapacity` --
//! whichever selector provides it -- already turns the resulting negative
//! capacity into a fatal out-of-memory, which is where a caller passing an
//! `argc` near `INT32_MAX` ends up today. `FOUND.md` records the C side.
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
const types = @import("types");
const repr = @import("repr");
const constants = @import("constants");
const vm_state = @import("../vm/lifecycle.zig");
const compiler_primitives = @import("../compiler.zig");

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
    /// `max_arity` starting at `INT32_MAX` rather than 0 is the one value here that
    /// is not simply "empty": an unfinished funcdef accepts any number of arguments
    /// until the assembler or the compiler narrows it.
    pub fn new() callconv(.c) *types.JanetFuncDef {
        const def: *types.JanetFuncDef = @ptrCast(@alignCast(gc_alloc.gcalloc(
            types.MemoryType.funcdef,
            @sizeOf(types.JanetFuncDef),
        )));
        def.environments = null;
        def.constants = null;
        def.bytecode = null;
        def.closure_bitset = null;
        def.flags = 0;
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
/// `sizeof(JanetFunction)` is the size of a function with no environments:
/// `envs` is a flexible array member, so `types.function_envs` is where the
/// environments begin, and a thunk has none: the block is exactly that long.
/// `test/value_alloc.zig` checks the figure against `@sizeOf` -- the other
/// spelling.
pub fn thunk(def: *types.JanetFuncDef) *types.JanetFunction {
    const func: *types.JanetFunction = @ptrCast(@alignCast(gc_alloc.gcalloc(
        types.MemoryType.function,
        types.function_envs,
    )));
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
pub fn thunkDelay(x: repr.Value) *types.JanetFunction {
    const bytecode = [_]u32{
        @intCast(constants.JOP_LOAD_CONSTANT),
        @intCast(constants.JOP_RETURN),
    };
    const def = defs.new();
    def.arity = 0;
    def.min_arity = 0;
    def.max_arity = std.math.maxInt(i32);
    def.flags = @intCast(constants.JANET_FUNCDEF_FLAG_VARARG);
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
// That follows batch 2's line rather than batch 1's. A leaf may duplicate a
// private *predicate*; it may not duplicate a definition anything else can
// observe, and a pointer offset can disagree. The merge proved the rule twice
// over on the way in: `fiber_core.zig` and `value_alloc.zig` each carried a
// private `stackBytes` and a private `setStatus`, and in both pairs the two
// copies had drifted apart -- one `stackBytes` traps where the other wraps a
// negative length into an enormous `size_t`, which is the behaviour
// `janet_fiber_setcapacity` depends on. Neither call site could see the
// difference; that is exactly how the C original left it, in two files.

/// `src/core/util.h`, declared here rather than translated, as `fibers.zig`,
/// `core_env.zig` and `peg.zig` each declare it: `util.h` pulls in `dlfcn.h`
/// on any target it does not recognise as Windows. `utils.zig` defines this
/// without `pub`, so the declaration is the cheaper of the two repairs.
extern fn safe_memcpy(dest: ?*anyopaque, src: ?*const anyopaque, len: usize) callconv(.c) void;

/// Copy a closure environment off the fiber's stack so it can outlive the
/// frame that produced it. The values the function's `closure_bitset` does not
/// claim are dropped, which is what keeps a closure from rooting every local of
/// its defining frame.
pub fn envDetach(maybe_env: ?*types.JanetFuncEnv) void {
    // Check for closure environment
    const env = maybe_env orelse return;
    _ = envValid(env);
    const len = env.*.length;
    const bytes = fibers.stackBytes(len);
    const memory = utils.malloc(bytes);
    // The budget is bumped before the null check, and through a `uint32_t`
    // truncation, in the C original. Both are reproduced.
    vm_state.current().gc.next_collection +%= @as(u32, @truncate(bytes));
    if (memory == null) fatal.outOfMemory();
    const vmem: [*]repr.Value = @ptrCast(@alignCast(memory));
    const values = env.*.as.fiber.?.data.? + @as(usize, @bitCast(@as(isize, env.*.offset)));
    safe_memcpy(vmem, values, bytes);
    const bitset = fibers.stackFrame(values).func.?.def.?.closure_bitset;
    if (bitset != null) {
        // Clear unneeded references in closure environment
        var i: i32 = 0;
        while (i < len) : (i += 32) {
            var mask = ~bitset.?[@intCast(i >> 5)];
            const maxj = if (i + 32 > len) len else i + 32;
            var j = i;
            while (j < maxj) : (j += 1) {
                if (mask & 1 != 0) vmem[@intCast(j)] = wrap.fromNil();
                mask >>= 1;
            }
        }
    }
    env.*.offset = 0;
    env.*.as.values = vmem;
}

pub fn envValid(env: *types.JanetFuncEnv) c_int {
    if (env.*.offset >= 0) return 1;
    const real_offset = -%env.*.offset;
    const fiber = env.*.as.fiber.?;
    var i = fiber.*.frame;
    while (i > 0) {
        const frame = fibers.stackFrame(fiber.*.data.? + @as(usize, @bitCast(@as(isize, i))));
        if (real_offset == i and
            frame.env == env and
            frame.func != null and
            frame.func.?.def.?.slotcount == env.*.length)
        {
            env.*.offset = real_offset;
            return 1;
        }
        i = frame.prevframe;
    }
    // Invalid, set to empty off-stack variant.
    env.*.offset = 0;
    env.*.length = 0;
    env.*.as.values = null;
    return 0;
}

/// Validate a potentially untrusted func env. An unmarshalled environment
/// records its stack offset negated; it is trustworthy only if a live frame of
/// the fiber it names still matches it exactly.
///
/// Detach an environment from its fiber once that fiber can no longer mutate
/// the slots the environment points at.
pub fn envMaybeDetach(env: *types.JanetFuncEnv) void {
    // Check for detachable closure envs
    _ = envValid(env);
    if (env.offset > 0) {
        if (fibers.finished(env.as.fiber.?)) envDetach(env);
    }
}
