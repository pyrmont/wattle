//! jump-transparent
//!
//! The last three collectable kinds a caller cannot otherwise construct
//! through Zig: a fiber, a funcdef, and the thunk that wraps one. This is
//! Part 9 of Phase 8 and it takes `fiber_alloc`, `janet_fiber` and
//! `janet_fiber_reset` from `src/core/fiber.c` together with
//! `janet_funcdef_alloc` and `janet_thunk` from `src/core/bytecode.c` -- four
//! exported symbols and two file-local helpers, and with them the last
//! `janet_gcalloc` call sites outside `vm.c` and `marsh.c`.
//!
//! Two files, one increment, because they are one gap rather than two. After
//! Parts 6 and 8 every other collectable kind can be built from Zig; fiber,
//! function and funcdef were what remained, and splitting them would have
//! produced two contracts that each tested half of the same sentence.
//!
//! ## Why this is not part of `fiber_core.zig`
//!
//! `fiber_alloc` and its two callers sit physically *above* the
//! `JANET_ZIG_FIBER_CORE` region in `fiber.c`, and Phase 7 left them there on
//! purpose: the code below that `#ifndef` is the frame machinery, and the code
//! above it is allocation, which is this phase's subject. The boundary is the
//! same one the phase has drawn everywhere else -- who owns the memory, not who
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
//! `janet_vm.blocks` from the moment `janet_gcalloc` returns, so the collector
//! owns it whether or not this function ever returns; its `data` array is
//! reachable from the block and is freed with it. The half-built frame the
//! signal leaves behind is exactly what C leaves behind, because C runs the
//! same statements in the same order.
//!
//! ## Two allocations per fiber, and only one of them is collectable
//!
//! `fiber_alloc` makes a `JANET_MEMORY_FIBER` block through `janet_gcalloc`
//! and then a plain `janet_malloc` array for the value stack, and charges the
//! second against `janet_vm.next_collection` by hand -- `janet_gcalloc` bills
//! only what it allocated itself. That is the same split
//! `janet_fiber_setcapacity` maintains in `fiber_core.zig`, and the two have to
//! agree: a fiber allocated here and grown there must have been charged once
//! for its initial capacity and once per resize, never twice and never zero
//! times. `test/value_alloc.c` checks the initial charge against the same
//! arithmetic `test/fiber_core.c` checks the resize against.
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
const abi = @import("abi");
const c = abi.c;

/// `janet_vm` as `src/core/state.h` declares it, resolved through `abi.zig`.
inline fn vm() *c.JanetVM {
    return &c.janet_vm;
}

/// `JANET_VM_HAS_EV` in `src/zig/state_abi.h`. `JanetFiber` carries five extra
/// fields when the event loop is compiled in, and `fiber_reset` clears all of
/// them. The condition is comptime, so the fields are named only in a build
/// where they exist.
const has_ev = c.JANET_VM_HAS_EV != 0;

/// `janet.h`'s frame size, named locally so the arithmetic below reads like
/// the C it replaces.
const frame_size: i32 = c.JANET_FRAME_SIZE;

/// `janet_stack_frame` and `janet_fiber_frame` from `fiber.h`, which are
/// function-like macros and so do not survive translation. A frame lives in the
/// four `Janet` slots immediately below the frame's stack base.
inline fn fiberFrame(fiber: *c.JanetFiber) *c.JanetStackFrame {
    const base = fiber.data + @as(usize, @bitCast(@as(isize, fiber.frame)));
    return @ptrCast(@alignCast(base - frame_size));
}

/// `janet_fiber_set_status` from `fiber.h`: clear the status bits, then write
/// the new status into them. Also a macro, and also written out here.
inline fn setStatus(fiber: *c.JanetFiber, status: c.JanetFiberStatus) void {
    fiber.flags &= ~@as(i32, c.JANET_FIBER_STATUS_MASK);
    fiber.flags |= @as(i32, @intCast(status)) << c.JANET_FIBER_STATUS_OFFSET;
}

/// `sizeof(Janet) * n` as C computes it: `n` is an `int32_t` widened to
/// `size_t`, so the product wraps rather than traps on a 32-bit target. Every
/// caller here has already floored `n` at 32, so the widening is of a positive
/// value.
inline fn janetBytes(n: i32) usize {
    return @as(usize, @intCast(n)) *% @sizeOf(c.Janet);
}

// ------------------------------------------------------------------- fibers

/// Return a fiber to its newborn state: no frames, no child, no environment,
/// the default signal mask, and status `JANET_STATUS_NEW`. Called on a block
/// `fiber_alloc` has just produced and on one `janet_fiber_reset` is recycling,
/// which is why it clears rather than assumes.
///
/// `capacity` and `data` are deliberately untouched: a recycled fiber keeps the
/// stack it already paid for, and that is the whole point of reusing one.
fn fiberReset(fiber: *c.JanetFiber) void {
    fiber.maxstack = c.JANET_STACK_MAX;
    fiber.frame = 0;
    fiber.stackstart = frame_size;
    fiber.stacktop = frame_size;
    fiber.child = null;
    fiber.flags = c.JANET_FIBER_MASK_YIELD |
        c.JANET_FIBER_RESUME_NO_USEVAL |
        c.JANET_FIBER_RESUME_NO_SKIP;
    fiber.env = null;
    fiber.last_value = c.janet_wrap_nil();
    if (has_ev) {
        fiber.sched_id = 0;
        fiber.ev_callback = null;
        fiber.ev_state = null;
        fiber.ev_stream = null;
        fiber.supervisor_channel = null;
    }
    setStatus(fiber, c.JANET_STATUS_NEW);
}

/// Allocate a fiber and its value stack. The block is collectable and on
/// `janet_vm.blocks` before this returns; the stack is a plain allocation the
/// collector knows about only through `janet_deinit_block`, which is why the
/// byte charge is made here by hand.
///
/// The fiber is returned with `capacity` and `data` set and *nothing else*
/// initialised, exactly as in C. Both callers run `fiberReset` over it
/// immediately. A collection cannot intervene: no allocation happens between
/// the two, because `janet_malloc` does not collect.
fn fiberAlloc(requested: i32) *c.JanetFiber {
    const fiber: *c.JanetFiber = @ptrCast(@alignCast(c.janet_gcalloc(
        c.JANET_MEMORY_FIBER,
        @sizeOf(c.JanetFiber),
    )));
    const capacity: i32 = if (requested < 32) 32 else requested;
    fiber.capacity = capacity;
    const data = c.janet_malloc(janetBytes(capacity)) orelse c.janet_zig_out_of_memory();
    vm().next_collection +%= janetBytes(capacity);
    fiber.data = @ptrCast(@alignCast(data));
    return fiber;
}

/// Create a new fiber with `argc` values on the stack by reusing `fiber`.
///
/// Returns null when the callee's arity rejects the argument count, which is
/// how `janet_pcall` is implemented and is why the failure is a return value
/// rather than a panic. Everything before the funcframe has already been
/// written by then, so the rejected fiber is reset but frameless -- again, what
/// C leaves.
export fn janet_fiber_reset(
    fiber: *c.JanetFiber,
    callee: *c.JanetFunction,
    argc: i32,
    argv: [*c]const c.Janet,
) callconv(.c) ?*c.JanetFiber {
    fiberReset(fiber);
    if (argc != 0) {
        const newstacktop = fiber.stacktop +% argc;
        if (newstacktop >= fiber.capacity) {
            c.janet_fiber_setcapacity(fiber, 2 *% newstacktop);
        }
        const dest = fiber.data + @as(usize, @intCast(fiber.stacktop));
        if (argv != null) {
            @memcpy(
                @as([*]u8, @ptrCast(dest))[0..janetBytes(argc)],
                @as([*]const u8, @ptrCast(argv))[0..janetBytes(argc)],
            );
        } else {
            // If argv not given, fill with nil
            var i: i32 = 0;
            while (i < argc) : (i += 1) dest[@intCast(i)] = c.janet_wrap_nil();
        }
        fiber.stacktop = newstacktop;
    }
    // Don't panic on failure since we use this to implement janet_pcall
    if (c.janet_fiber_funcframe(fiber, callee) != 0) return null;
    fiberFrame(fiber).flags |= c.JANET_STACKFRAME_ENTRANCE;
    if (has_ev) fiber.supervisor_channel = null;
    return fiber;
}

/// Create a new fiber with `argc` values on the stack.
export fn janet_fiber(
    callee: *c.JanetFunction,
    capacity: i32,
    argc: i32,
    argv: [*c]const c.Janet,
) callconv(.c) ?*c.JanetFiber {
    return janet_fiber_reset(fiberAlloc(capacity), callee, argc, argv);
}

// ------------------------------------------------------- funcdefs and thunks

/// Allocate an empty funcdef. Every field is written, including the ones a
/// zeroing allocator would have covered, because `janet_gcalloc` does not zero
/// and the collector traverses a funcdef's pointer fields as soon as it is
/// reachable.
///
/// `max_arity` starting at `INT32_MAX` rather than 0 is the one value here that
/// is not simply "empty": an unfinished funcdef accepts any number of arguments
/// until the assembler or the compiler narrows it.
export fn janet_funcdef_alloc() callconv(.c) *c.JanetFuncDef {
    const def: *c.JanetFuncDef = @ptrCast(@alignCast(c.janet_gcalloc(
        c.JANET_MEMORY_FUNCDEF,
        @sizeOf(c.JanetFuncDef),
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

/// Create a simple closure from a funcdef.
///
/// `sizeof(JanetFunction)` is the size of a function with no environments:
/// `envs` is a flexible array member, which translate-c drops entirely, so
/// `@sizeOf` here is the same number C's `sizeof` produces. `test/value_alloc.c`
/// asserts that from the C side, where the flexible member is visible.
export fn janet_thunk(def: *c.JanetFuncDef) callconv(.c) *c.JanetFunction {
    const func: *c.JanetFunction = @ptrCast(@alignCast(c.janet_gcalloc(
        c.JANET_MEMORY_FUNCTION,
        @sizeOf(c.JanetFunction),
    )));
    func.def = def;
    if (def.environments_length != 0)
        c.janet_zig_fatal("tried to create thunk that needs upvalues");
    return func;
}
