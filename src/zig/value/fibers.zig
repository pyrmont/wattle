//! Fiber stack frames, funcframes, and function environments: the machinery a
//! call goes through on its way onto and off a fiber's value stack.
//!
//! This is the second Zig object in the runtime core and the first that does
//! real work. It reaches `janet_vm` by name, which Part 6 made possible, and it
//! reads and writes `JanetFiber`, `JanetStackFrame`, and `JanetFuncEnv`
//! directly — all three are public in `janet.h`, so nothing private is being
//! exposed to get here.
//!
//! Two boundaries are drawn deliberately and are the whole design of the
//! increment:
//!
//!  - **Nothing here may raise.** `janet_panic` is a `longjmp`, and a `longjmp`
//!    may not cross a Zig frame. The one recoverable failure in this code —
//!    a stack that has reached `INT32_MAX` — is reported as a nonzero return
//!    and raised by the thin C wrapper in `src/core/fiber.c`. Allocation
//!    failure is different: `JANET_OUT_OF_MEMORY` is fatal by policy, so
//!    `janet_zig_out_of_memory` is called directly, exactly as the vector port
//!    does.
//!  - **Zig reports where the varargs go; C builds the value.** Packing a
//!    variadic tail means `janet_tuple_n` or `janet_struct_put`, and
//!    `janet_struct_put` hashes the caller's keys, which runs an abstract
//!    type's `hash` callback, which can panic. So the funcframe kernels stop
//!    at the slot index and the count, and `src/core/fiber.c` constructs and
//!    stores the value. That is the scan/allocate/fill split Phase 5
//!    established, and it costs nothing: the packing was a call in the C
//!    original too.
//!
//! ## Both of those boundaries are gone, and this is where Part 17 begins
//!
//! **Phase 10 Part 17a took this file as its proof**, because it was the
//! clearest case in the tree of C that exists only to hold a raise. Four
//! `janet_panic("stack overflow")` calls sat in `src/core/fiber.c` wrapping
//! four kernels here, for one reason: a kernel that raised would have had to
//! do it by jumping, and it could not jump out of its own Zig frame.
//!
//! With every subsystem in one module that reason is spent. The kernels below
//! raise by returning `raise.Error`, their callers `try` them, and the abis
//! beside them — `janet_fiber_push` and its three siblings — are
//! `raise.panicking` wrappers that deliver the jump a C caller still expects.
//! Two abis, which is the rule Part 2 set: the C one is the one that
//! disappears, so it is the one that rots, and it stays tested until it goes.
//!
//! The second boundary goes with it. `make_struct_n` and the varargs fill are
//! here now rather than in `fiber.c`, so `janet_fiber_funcframe` and
//! `janet_fiber_funcframe_tail` are whole again instead of being a kernel in
//! two halves with a C packing step between them. Neither *raises* — an arity
//! mismatch is still reported as 1, which is what `run_vm` branches on — but
//! both can be jumped *through*, because `janet_struct_put` hashes the caller's
//! keys and an abstract type's `hash` callback is a C function pointer. That is
//! why the file now carries `//! jump-transparent`: the rule SPIKE-8 set is
//! that such a callback may not raise, and nothing enforces it.
//!
//! `janet_fiber` and `janet_fiber_reset` stay in C on purpose. They are fiber
//! *allocation* — `janet_gcalloc` plus the collector's byte budget — which is
//! Phase 8's subject, not this one.

const std = @import("std");
const raise = @import("raise");
const pp_format = @import("../pp/format.zig");
const corefn = @import("corefn");
const args_core = @import("../args.zig");
const config = @import("config");
const structs = @import("structs.zig");
const tables = @import("tables.zig");
const tuples = @import("tuples.zig");
const utils = @import("../utils.zig");
const kind = @import("helpers/kind.zig");
const wrap = @import("helpers/wrap.zig");
const fatal = @import("../fatal.zig");
const gc_alloc = @import("../gc.zig");
const functions = @import("functions.zig");
const types = @import("types");
const constants = @import("constants");
const value = @import("../value.zig");
const c = @import("cabi");

/// `src/core/util.h`, declared here rather than translated: that header pulls
/// in `dlfcn.h` on any target it does not recognise as Windows, which breaks
/// the Windows cross-compile of every Zig object at once. This is `memcpy` with
/// a zero length permitted to carry a null source, which several
/// `janet_fiber_pushn` callers rely on.
extern fn safe_memcpy(dest: ?*anyopaque, src: ?*const anyopaque, len: usize) void;

/// `janet.h`'s frame size, named locally so the arithmetic below reads like
/// the C it replaces. The function-like macros that go with it —
/// `janet_stack_frame` and `janet_fiber_frame` in `fiber.h` — translate-c does
/// not surface, so those are the two helpers below.
const frame_size: i32 = constants.JANET_FRAME_SIZE;

/// `janet_vm`, whose layout is `types.JanetVM`'s and whose address
/// `cabi.vm()` takes.
/// Whether it is thread-local is the C header's decision; Zig inherits it.
inline fn vm() *types.JanetVM {
    return c.vm();
}

inline fn dataAt(fiber: *types.JanetFiber, index: i32) [*]types.Janet {
    return fiber.data.? + @as(usize, @bitCast(@as(isize, index)));
}

/// `janet_stack_frame` from `fiber.h`: a frame lives in the four `Janet` slots
/// immediately below the frame's stack base.
pub inline fn stackFrame(values: [*]types.Janet) *types.JanetStackFrame {
    return @ptrCast(@alignCast(values - frame_size));
}

inline fn fiberFrame(fiber: *types.JanetFiber) *types.JanetStackFrame {
    return stackFrame(dataAt(fiber, fiber.frame));
}

/// C computes `sizeof(Janet) * n` with `n` an `int32_t`, so a negative `n` —
/// which `2 * nextstacktop` can produce on a very large stack — becomes an
/// enormous `size_t` and the allocation fails. Reproduced rather than
/// corrected: the result is a fatal out-of-memory either way, and changing it
/// would change which diagnostic a caller sees.
pub inline fn janetBytes(n: i32) usize {
    return @bitCast(@as(isize, n) *% @as(isize, @sizeOf(types.Janet)));
}

/// Only compiled when `janetconf.h` defines JANET_DEBUG, which no build option
/// does; it is edited in by hand to shake out use-after-free by moving the
/// stack on every frame push.
const debug_build = config.debug;

fn refreshMemory(fiber: *types.JanetFiber) void {
    const n = fiber.capacity;
    if (n != 0) {
        const new_data = utils.malloc(janetBytes(n)) orelse fatal.outOfMemory();
        const dest: [*]types.Janet = @ptrCast(@alignCast(new_data));
        @memcpy(dest[0..@intCast(n)], fiber.data[0..@intCast(n)]);
        utils.free(fiber.data);
        fiber.data = dest;
    }
}

/// The shape shared by every frame push: grow if the frame will not fit, and
/// otherwise shuffle the allocation in a debug build.
inline fn reserve(fiber: *types.JanetFiber, nextstacktop: i32) void {
    if (fiber.capacity < nextstacktop) {
        setcapacity(fiber, 2 *% nextstacktop);
    } else if (debug_build) {
        refreshMemory(fiber);
    }
}

inline fn fillNil(fiber: *types.JanetFiber, from: i32, to: i32) void {
    var i = from;
    while (i < to) : (i += 1) {
        dataAt(fiber, i)[0] = wrap.fromNil();
    }
}

// -------------------------------------------------------------- allocation
//
// Phase 8 Part 9 put these four in `value_alloc.zig` rather than here, on the
// boundary that phase drew everywhere: who owns the memory, not who uses it.
// `fiber.c` carried two `#ifndef` regions because of it. The namespace batch
// merged them back, because "alloc" was the only word that covered a fiber
// and a funcdef at once and it covered them by saying nothing --
// `port/NAMESPACES.md` has the argument.

/// `JANET_VM_HAS_EV` in `src/zig/state_abi.h`. `JanetFiber` carries five extra
/// fields when the event loop is compiled in, and `resetState` clears all of
/// them. The condition is comptime, so the fields are named only in a build
/// where they exist.
const has_ev = constants.JANET_VM_HAS_EV != 0;

/// Return a fiber to its newborn state: no frames, no child, no environment,
/// the default signal mask, and status `JANET_STATUS_NEW`. Called on a block
/// `alloc` has just produced and on one `reset` is recycling, which is why it
/// clears rather than assumes.
///
/// `capacity` and `data` are deliberately untouched: a recycled fiber keeps the
/// stack it already paid for, and that is the whole point of reusing one.
///
/// C called this `fiber_reset` and the public entry point below
/// `janet_fiber_reset`; stripping the prefix collapses both onto `reset`, so
/// the one that takes only a fiber says what it resets instead.
fn resetState(fiber: *types.JanetFiber) void {
    fiber.maxstack = config.stack_max;
    fiber.frame = 0;
    fiber.stackstart = frame_size;
    fiber.stacktop = frame_size;
    fiber.child = null;
    fiber.flags = constants.JANET_FIBER_MASK_YIELD |
        constants.JANET_FIBER_RESUME_NO_USEVAL |
        constants.JANET_FIBER_RESUME_NO_SKIP;
    fiber.env = null;
    fiber.last_value = wrap.fromNil();
    if (has_ev) {
        fiber.sched_id = 0;
        fiber.ev_callback = null;
        fiber.ev_state = null;
        fiber.ev_stream = null;
        fiber.supervisor_channel = null;
    }
    setStatus(fiber, constants.JANET_STATUS_NEW);
}

/// Allocate a fiber and its value stack. The block is collectable and on
/// `janet_vm.blocks` before this returns; the stack is a plain allocation the
/// collector knows about only through `janet_deinit_block`, which is why the
/// byte charge is made here by hand.
///
/// The fiber is returned with `capacity` and `data` set and *nothing else*
/// initialised, exactly as in C. Both callers run `resetState` over it
/// immediately. A collection cannot intervene: no allocation happens between
/// the two, because `janet_malloc` does not collect.
fn alloc(requested: i32) *types.JanetFiber {
    const fiber: *types.JanetFiber = @ptrCast(@alignCast(gc_alloc.gcalloc(
        constants.JANET_MEMORY_FIBER,
        @sizeOf(types.JanetFiber),
    )));
    const capacity: i32 = if (requested < 32) 32 else requested;
    fiber.capacity = capacity;
    const data = utils.malloc(janetBytes(capacity)) orelse fatal.outOfMemory();
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
pub fn reset(
    fiber: *types.JanetFiber,
    callee: *types.JanetFunction,
    argc: i32,
    argv: ?[*]const types.Janet,
) callconv(.c) ?*types.JanetFiber {
    resetState(fiber);
    if (argc != 0) {
        const newstacktop = fiber.stacktop +% argc;
        if (newstacktop >= fiber.capacity) {
            setcapacity(fiber, 2 *% newstacktop);
        }
        const dest = fiber.data.? + @as(usize, @intCast(fiber.stacktop));
        if (argv) |items| {
            @memcpy(
                @as([*]u8, @ptrCast(dest))[0..janetBytes(argc)],
                @as([*]const u8, @ptrCast(items))[0..janetBytes(argc)],
            );
        } else {
            // If argv not given, fill with nil
            var i: i32 = 0;
            while (i < argc) : (i += 1) dest[@intCast(i)] = wrap.fromNil();
        }
        fiber.stacktop = newstacktop;
    }
    // Don't panic on failure since we use this to implement janet_pcall
    if (funcframe(fiber, callee) != 0) return null;
    fiberFrame(fiber).flags |= constants.JANET_STACKFRAME_ENTRANCE;
    if (has_ev) fiber.supervisor_channel = null;
    return fiber;
}

/// Create a new fiber with `argc` values on the stack.
pub fn new(
    callee: *types.JanetFunction,
    capacity: i32,
    argc: i32,
    argv: ?[*]const types.Janet,
) callconv(.c) ?*types.JanetFiber {
    return reset(alloc(capacity), callee, argc, argv);
}

// ------------------------------------------------------------------ growth

pub fn setcapacity(fiber: *types.JanetFiber, n: i32) void {
    const old_size = fiber.capacity;
    const diff = n -% old_size;
    const new_data = utils.realloc(fiber.data, janetBytes(n)) orelse
        fatal.outOfMemory();
    fiber.data = @ptrCast(@alignCast(new_data));
    fiber.capacity = n;
    // Unsigned wraparound is how the C original shrinks the budget: `diff` is
    // negative and the product is added to a `size_t`.
    vm().next_collection +%= janetBytes(diff);
}

fn grow(fiber: *types.JanetFiber, needed: i32) void {
    const cap: i32 = if (needed > @divTrunc(std.math.maxInt(i32), 2))
        std.math.maxInt(i32)
    else
        2 *% needed;
    setcapacity(fiber, cap);
}

// ------------------------------------------------------------------ pushes

// Each of these raises "stack overflow" by returning it. Until Part 17a they
// returned nonzero and a wrapper in `src/core/fiber.c` did the panicking, for
// the reason the header gives: a kernel in its own object could not raise
// without jumping out of a Zig frame.
//
// The three fixed-arity pushes take their values rather than pointers to them.
// The pointers were the C ABI's shape -- `janet_zig_fiber_push` took a
// `const Janet *` so that `fiber.c`'s wrapper could hand it the address of its
// own by-value parameter -- and with the wrapper gone the indirection has no
// caller it serves: `run_vm` passes a slot of the fiber stack, which is a value
// it already holds. `pushn` keeps its pointer, because a run of values is what
// it takes.

pub fn push(fiber: *types.JanetFiber, x: types.Janet) raise.Error!void {
    if (fiber.stacktop == std.math.maxInt(i32)) return raise.panic("stack overflow");
    if (fiber.stacktop >= fiber.capacity) grow(fiber, fiber.stacktop);
    dataAt(fiber, fiber.stacktop)[0] = x;
    fiber.stacktop += 1;
}

pub fn push2(fiber: *types.JanetFiber, x: types.Janet, y: types.Janet) raise.Error!void {
    if (fiber.stacktop >= std.math.maxInt(i32) - 1) return raise.panic("stack overflow");
    const newtop = fiber.stacktop + 2;
    if (newtop > fiber.capacity) grow(fiber, newtop);
    const slots = dataAt(fiber, fiber.stacktop);
    slots[0] = x;
    slots[1] = y;
    fiber.stacktop = newtop;
}

pub fn push3(fiber: *types.JanetFiber, x: types.Janet, y: types.Janet, z: types.Janet) raise.Error!void {
    if (fiber.stacktop >= std.math.maxInt(i32) - 2) return raise.panic("stack overflow");
    const newtop = fiber.stacktop + 3;
    if (newtop > fiber.capacity) grow(fiber, newtop);
    const slots = dataAt(fiber, fiber.stacktop);
    slots[0] = x;
    slots[1] = y;
    slots[2] = z;
    fiber.stacktop = newtop;
}

pub fn pushn(
    fiber: *types.JanetFiber,
    arr: ?[*]const types.Janet,
    n: i32,
) raise.Error!void {
    if (fiber.stacktop > std.math.maxInt(i32) -% n) return raise.panic("stack overflow");
    const newtop = fiber.stacktop +% n;
    if (newtop > fiber.capacity) grow(fiber, newtop);
    // safe_memcpy rather than @memcpy: `arr` is null when `n` is zero at
    // several call sites, and a null source is what that helper exists for.
    safe_memcpy(dataAt(fiber, fiber.stacktop), arr, janetBytes(n));
    fiber.stacktop = newtop;
}

// --------------------------------------------------------------- varargs

/// Create a struct with n values. If n is odd, the last value is ignored.
///
/// `src/core/fiber.c`'s `make_struct_n` until Phase 10 Part 17a. It is here
/// now because `janet_fiber_funcframe` is, and it is the reason this file
/// carries the jump-transparent marker: `janet_struct_put` hashes the caller's
/// keys, so an abstract type's `hash` callback runs underneath it, and that
/// callback is a C function pointer which may jump whatever language surrounds
/// it. SPIKE-8's rule says it may not raise; nothing enforces it. This frame
/// holds nothing, so a jump through it costs nothing.
fn makeStructN(args: ?[*]const types.Janet, n: i32) types.Janet {
    const st = structs.begin(n & ~@as(i32, 1));
    var i: i32 = 0;
    while (i < n) : (i += 2) {
        structs.put(st, args.?[@intCast(i)], args.?[@intCast(i + 1)]);
    }
    return wrap.fromStruct(structs.end(st));
}

/// Build the variadic tail the frame setup located and store it in its slot.
///
/// A count of zero is an empty tail rather than an empty range, which is why
/// the source pointer is null there -- that is the distinction the C original
/// drew with its `tuplehead >= oldtop` branch.
fn fillVarargs(fiber: *types.JanetFiber, func: *types.JanetFunction, slot: i32, count: i32) void {
    const structarg = (func.def.?.flags & constants.JANET_FUNCDEF_FLAG_STRUCTARG) != 0;
    const values: ?[*]const types.Janet = if (count != 0) dataAt(fiber, slot) else null;
    dataAt(fiber, slot)[0] = if (structarg)
        makeStructN(values, count)
    else
        wrap.fromTuple(tuples.newFrom(values, count));
}

// The abi of the pushes, and by Phase 11 Part 11 there is one of it.
//
// There were four, written out rather than generated by `raise.panicking`,
// which builds an abi for a function that returns a payload and has nothing to
// wrap where the return is `void`. Each turned the kernel's `raise.Error` into
// the report a C caller consumes.
//
// All four are gone. `run_vm` and `janet_call` reach `push2`, `push3` and
// `pushn` by import, `fiber.h` is an internal header rather than `janet.h`, and
// `test/fiber_core.c` was the last caller of those three — so they went with it
// when the contract migrated. Phase 11 Part 12 took the fourth on the same
// argument: `janet_fiber_push`'s last two callers were `test/vm_calls.c` and
// `test/vm_entry.c`, and the migrated contracts use `push`.

// ------------------------------------------------------------------- frames

/// Push a call frame for `func`. Returns 1 without touching the fiber if the
/// argument count is outside the function's arity, and otherwise reports
/// through `slot_out` where a variadic tail has to be packed: -1 for none, or
/// the slot index with `count_out` values to gather from it. C does the
/// packing, because building a tuple or a struct can raise.
pub fn funcframe(fiber: *types.JanetFiber, func: *types.JanetFunction) c_int {
    var slot: i32 = undefined;
    var count: i32 = undefined;
    if (funcframeBegin(fiber, func, &slot, &count) != 0) return 1;
    if (slot >= 0) fillVarargs(fiber, func, slot, count);
    return 0;
}

/// Everything up to the point where a variadic tail's value is needed:
/// `slot_out` reports where to pack one, or -1 for none, and `count_out` how
/// many values to gather. Returns 1 without touching the fiber if the argument
/// count is outside the function's arity.
///
/// Split from the fill above rather than folded into it because the tail-call
/// path needs the two halves in a different order -- the tail's value has to
/// exist before the arguments are moved down over the outgoing frame.
fn funcframeBegin(
    fiber: *types.JanetFiber,
    func: *types.JanetFunction,
    slot_out: *i32,
    count_out: *i32,
) c_int {
    const def = func.def.?;
    const oldtop = fiber.stacktop;
    const oldframe = fiber.frame;
    const nextframe = fiber.stackstart;
    const nextstacktop = nextframe +% def.*.slotcount +% frame_size;
    const next_arity = fiber.stacktop -% fiber.stackstart;

    slot_out.* = -1;
    count_out.* = 0;

    // Check strict arity before messing with state
    if (next_arity < def.*.min_arity) return 1;
    if (next_arity > def.*.max_arity) return 1;

    reserve(fiber, nextstacktop);

    // Nil unset stack arguments (Needed for gc correctness)
    fillNil(fiber, fiber.stacktop, nextstacktop);

    // Set up the next frame
    fiber.frame = nextframe;
    fiber.stacktop = nextstacktop;
    fiber.stackstart = nextstacktop;
    const newframe = fiberFrame(fiber);
    newframe.prevframe = oldframe;
    newframe.pc = def.*.bytecode;
    newframe.func = func;
    newframe.env = null;
    newframe.flags = 0;

    // Check varargs
    if (def.*.flags & constants.JANET_FUNCDEF_FLAG_VARARG != 0) {
        const tuplehead = fiber.frame +% def.*.arity;
        slot_out.* = tuplehead;
        count_out.* = if (tuplehead >= oldtop) 0 else oldtop -% tuplehead;
    }

    return 0;
}

/// The first half of a tail call. Everything up to the point where the
/// variadic tail's value is needed: arity, capacity, detaching the outgoing
/// frame's environment, and the gap fill an empty tail requires. `stacksize` is
/// how many slots the finishing half has to move down.
pub fn funcframeTail(fiber: *types.JanetFiber, func: *types.JanetFunction) c_int {
    var slot: i32 = undefined;
    var count: i32 = undefined;
    var stacksize: i32 = 0;
    if (funcframeTailBegin(fiber, func, &slot, &count, &stacksize) != 0) return 1;
    if (slot >= 0) fillVarargs(fiber, func, slot, count);
    funcframeTailFinish(fiber, func, stacksize);
    return 0;
}

fn funcframeTailBegin(
    fiber: *types.JanetFiber,
    func: *types.JanetFunction,
    slot_out: *i32,
    count_out: *i32,
    stacksize_out: *i32,
) c_int {
    const def = func.def.?;
    const nextstacktop = fiber.frame +% def.*.slotcount +% frame_size;
    const next_arity = fiber.stacktop -% fiber.stackstart;

    slot_out.* = -1;
    count_out.* = 0;

    // Check strict arity before messing with state
    if (next_arity < def.*.min_arity) return 1;
    if (next_arity > def.*.max_arity) return 1;

    reserve(fiber, nextstacktop);

    // Detach old function
    const frame = fiberFrame(fiber);
    if (frame.func != null) functions.envDetach(frame.env);
    frame.env = null;

    // Check varargs
    if (def.*.flags & constants.JANET_FUNCDEF_FLAG_VARARG != 0) {
        const tuplehead = fiber.stackstart +% def.*.arity;
        if (tuplehead >= fiber.stacktop) {
            if (tuplehead >= fiber.capacity) {
                setcapacity(fiber, 2 *% (tuplehead +% 1));
            }
            fillNil(fiber, fiber.stacktop, tuplehead);
            count_out.* = 0;
        } else {
            count_out.* = fiber.stacktop -% tuplehead;
        }
        slot_out.* = tuplehead;
        stacksize_out.* = tuplehead -% fiber.stackstart +% 1;
    } else {
        stacksize_out.* = fiber.stacktop -% fiber.stackstart;
    }

    return 0;
}

/// The second half: move the arguments down over the outgoing frame's slots,
/// nil the rest, and repoint the frame at `func`. Runs after C has stored the
/// variadic tail, because the move copies that slot too.
fn funcframeTailFinish(
    fiber: *types.JanetFiber,
    func: *types.JanetFunction,
    stacksize: i32,
) void {
    const def = func.def.?;
    const nextframetop = fiber.frame +% def.*.slotcount;
    const nextstacktop = nextframetop +% frame_size;

    if (stacksize != 0) {
        const count: usize = @intCast(stacksize);
        const dest = dataAt(fiber, fiber.frame)[0..count];
        const src = dataAt(fiber, fiber.stackstart)[0..count];
        @memmove(dest, src);
    }

    // Nil unset locals (Needed for functional correctness)
    fillNil(fiber, fiber.frame +% stacksize, nextframetop);

    // Set stack stuff
    fiber.stacktop = nextstacktop;
    fiber.stackstart = nextstacktop;

    // Set frame stuff
    const frame = fiberFrame(fiber);
    frame.func = func;
    frame.pc = def.*.bytecode;
    frame.flags |= constants.JANET_STACKFRAME_TAILCALL;
}

pub fn cframe(fiber: *types.JanetFiber, cfun: types.JanetCFunction) void {
    const oldframe = fiber.frame;
    const nextframe = fiber.stackstart;
    const nextstacktop = fiber.stacktop +% frame_size;

    reserve(fiber, nextstacktop);

    // Set the next frame
    fiber.frame = nextframe;
    fiber.stacktop = nextstacktop;
    fiber.stackstart = nextstacktop;
    const newframe = fiberFrame(fiber);

    // Set up the new frame
    newframe.prevframe = oldframe;
    // C stores the cfunction in the frame's `pc` slot; a frame with a null
    // `func` is what marks it as a C frame. Function and data pointers are
    // distinct kinds in Zig, so the reinterpretation goes through the address.
    newframe.pc = @ptrFromInt(@intFromPtr(cfun));
    newframe.func = null;
    newframe.env = null;
    newframe.flags = 0;
}

pub fn popframe(fiber: *types.JanetFiber) void {
    const frame = fiberFrame(fiber);
    if (fiber.frame == 0) return;

    // Clean up the frame (detach environments)
    if (frame.func != null) functions.envDetach(frame.env);

    // Shrink stack
    fiber.stacktop = fiber.frame;
    fiber.stackstart = fiber.frame;
    fiber.frame = frame.prevframe;
}

// -------------------------------------------------------------- inspection

/// The seven statuses that mean a fiber has run to a stop.
///
/// The C original had this list twice, once in `janet_env_maybe_detach` and
/// once in `janet_fiber_can_resume`, and the port inherited both copies into
/// one file. The split separates those two callers, so it is a fiber
/// predicate here and `functions.envMaybeDetach` asks it rather than carrying
/// the list a third time.
pub fn finished(f: *types.JanetFiber) bool {
    return switch (statusOf(f)) {
        constants.JANET_STATUS_DEAD,
        constants.JANET_STATUS_ERROR,
        constants.JANET_STATUS_USER0,
        constants.JANET_STATUS_USER1,
        constants.JANET_STATUS_USER2,
        constants.JANET_STATUS_USER3,
        constants.JANET_STATUS_USER4,
        => true,
        else => false,
    };
}

inline fn statusOf(f: *types.JanetFiber) types.JanetFiberStatus {
    return @intCast((f.*.flags & constants.JANET_FIBER_STATUS_MASK) >> constants.JANET_FIBER_STATUS_OFFSET);
}

pub fn status(f: *types.JanetFiber) types.JanetFiberStatus {
    return statusOf(f);
}

pub fn canResume(fiber: *types.JanetFiber) c_int {
    return @intFromBool(!finished(fiber));
}

pub fn current() ?*types.JanetFiber {
    return vm().fiber;
}

pub fn root() ?*types.JanetFiber {
    return vm().root_fiber;
}

// ==========================================================================
// fiber/*, the cfunction surface
// ==========================================================================
//
// Phase 10 Part 17g. Ten builtins, and the last cfunctions in `fiber.c`.
//
// They are here rather than in a file of their own because they are this
// subsystem's own surface: nine of the ten are two lines over a field of
// `JanetFiber` that the kernels above already own, and the tenth --
// `fiber/new` -- is the flag parser, which is the only real code in the set.
//
// The type they are declared with is the subject of this part. A builtin
// returns `raise.Error!c.Janet` now rather than recording its raise in
// `janet_vm.raising` and returning an unspecified value, so a caller that
// forgets to `try` is a compile error again.

fn cfunFiberGetenv(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 1);
    const fiber = try args_core.getFiber(argv, 0);
    return if (fiber.*.env) |env|
        wrap.fromTable(env)
    else
        wrap.fromNil();
}

fn cfunFiberSetenv(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 2);
    const fiber = try args_core.getFiber(argv, 0);
    if (kind.checkType(argv[1], constants.JANET_NIL) != 0) {
        fiber.*.env = null;
    } else {
        fiber.*.env = try args_core.getTable(argv, 1);
    }
    return argv[0];
}

/// `janet_fiber_set_status` from `src/core/fiber.h`, a macro that does not
/// survive translation.
inline fn setStatus(fiber: *types.JanetFiber, to: u32) void {
    fiber.flags &= ~@as(i32, constants.JANET_FIBER_STATUS_MASK);
    fiber.flags |= @as(i32, @bitCast(to << constants.JANET_FIBER_STATUS_OFFSET));
}

/// `JANET_FIBER_MASK_USERN(n)`, likewise: a function-like macro, written out.
inline fn maskUserN(n: u5) i32 {
    return @as(i32, 16) << n;
}

fn cfunFiberNew(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.arity(argv, 1, 3);
    const func = try args_core.getFunction(argv, 0);
    if (func.*.def.?.min_arity > 1) {
        return pp_format.panicf("fiber function must accept 0 or 1 arguments", .{});
    }
    const fiber = new(func, 64, func.*.def.?.min_arity, null) orelse
        fatal.fatal("bad fiber arity check");

    if (@as(i32, @intCast(argv.len)) == 3 and kind.checkType(argv[2], constants.JANET_NIL) == 0) {
        fiber.*.env = try args_core.getTable(argv, 2);
    }

    if (@as(i32, @intCast(argv.len)) >= 2) {
        const view = try args_core.getBytes(argv, 1);
        fiber.*.flags = constants.JANET_FIBER_RESUME_NO_USEVAL | constants.JANET_FIBER_RESUME_NO_SKIP;
        setStatus(fiber, constants.JANET_STATUS_NEW);
        var i: i32 = 0;
        while (i < view.len) : (i += 1) {
            const ch = view.bytes.?[@intCast(i)];
            if (ch >= '0' and ch <= '9') {
                fiber.*.flags |= maskUserN(@intCast(ch - '0'));
                continue;
            }
            switch (ch) {
                'a' => fiber.*.flags |= constants.JANET_FIBER_MASK_DEBUG |
                    constants.JANET_FIBER_MASK_ERROR |
                    constants.JANET_FIBER_MASK_USER |
                    constants.JANET_FIBER_MASK_YIELD,
                't' => fiber.*.flags |= constants.JANET_FIBER_MASK_ERROR |
                    constants.JANET_FIBER_MASK_USER0 |
                    constants.JANET_FIBER_MASK_USER1 |
                    constants.JANET_FIBER_MASK_USER2 |
                    constants.JANET_FIBER_MASK_USER3 |
                    constants.JANET_FIBER_MASK_USER4,
                'd' => fiber.*.flags |= constants.JANET_FIBER_MASK_DEBUG,
                'e' => fiber.*.flags |= constants.JANET_FIBER_MASK_ERROR,
                'u' => fiber.*.flags |= constants.JANET_FIBER_MASK_USER,
                'y' => fiber.*.flags |= constants.JANET_FIBER_MASK_YIELD,
                'w' => fiber.*.flags |= constants.JANET_FIBER_MASK_USER9,
                'r' => fiber.*.flags |= constants.JANET_FIBER_MASK_USER8,
                'i' => {
                    if (vm().fiber.?.env == null) vm().fiber.?.env = tables.new(0);
                    fiber.*.env = vm().fiber.?.env;
                },
                'p' => {
                    if (vm().fiber.?.env == null) vm().fiber.?.env = tables.new(0);
                    fiber.*.env = tables.new(0);
                    fiber.*.env.?.proto = vm().fiber.?.env;
                },
                // The C original's `default` raises and then `break`s, which
                // is dead code after a `janet_panicf`; the port drops the
                // break and nothing else.
                else => return pp_format.panicf(
                    "invalid flag %c, expected a, t, d, e, u, y, w, r, i, or p",
                    .{@as(c_int, ch)},
                ),
            }
        }
    }

    return wrap.fromFiber(fiber);
}

fn cfunFiberStatus(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 1);
    const fiber = try args_core.getFiber(argv, 0);
    return value.fromBytes(std.mem.span(utils.statusNames[@intCast(statusOf(fiber))]), .keyword);
}

fn cfunFiberCurrent(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 0);
    return wrap.fromFiber(vm().fiber.?);
}

fn cfunFiberRoot(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 0);
    return wrap.fromFiber(vm().root_fiber.?);
}

fn cfunFiberMaxstack(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 1);
    const fiber = try args_core.getFiber(argv, 0);
    return wrap.fromNumber(@floatFromInt(fiber.*.maxstack));
}

fn cfunFiberSetmaxstack(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 2);
    const fiber = try args_core.getFiber(argv, 0);
    const maxs = try args_core.getInteger(argv, 1);
    if (maxs < 0) return raise.panic("expected positive integer");
    fiber.*.maxstack = maxs;
    return argv[0];
}

fn cfunFiberCanResume(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 1);
    const fiber = try args_core.getFiber(argv, 0);
    return wrap.fromBoolean(canResume(fiber));
}

fn cfunFiberLastValue(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 1);
    const fiber = try args_core.getFiber(argv, 0);
    return fiber.*.last_value;
}

pub fn lib(env: *types.JanetTable) void {
    raise.reported(libImpl(env));
}

pub fn libImpl(env: *types.JanetTable) raise.Raising(void) {
    const entries = [_]corefn.Entry{
        corefn.reg("fiber/new", &cfunFiberNew, @src(), "(fiber/new func &opt sigmask env)",
            \\Create a new fiber with function body func. Can optionally take a set of signals `sigmask` to capture from child fibers, and an environment table `env`. The mask is specified as a keyword where each character is used to indicate a signal to block. If the ev module is enabled, and this fiber is used as an argument to `ev/go`, these "blocked" signals will result in messages being sent to the supervisor channel. The default sigmask is :y. For example,
            \\
            \\    (fiber/new myfun :e123)
            \\
            \\blocks error signals and user signals 1, 2 and 3. The signals are as follows:
            \\
            \\* :a - block all signals
            \\* :d - block debug signals
            \\* :e - block error signals
            \\* :t - block termination signals: error + user[0-4]
            \\* :u - block user signals
            \\* :y - block yield signals
            \\* :w - block await signals (user9)
            \\* :r - block interrupt signals (user8)
            \\* :0-9 - block a specific user signal
            \\
            \\The sigmask argument also can take environment flags. If any mutually exclusive flags are present, the last flag takes precedence.
            \\
            \\* :i - inherit the environment from the current fiber
            \\* :p - the environment table's prototype is the current environment table
        ),
        corefn.reg("fiber/status", &cfunFiberStatus, @src(), "(fiber/status fib)",
            \\Get the status of a fiber. The status will be one of:
            \\
            \\* :dead - the fiber has finished
            \\* :error - the fiber has errored out
            \\* :debug - the fiber is suspended in debug mode
            \\* :pending - the fiber has been yielded
            \\* :user(0-7) - the fiber is suspended by a user signal
            \\* :interrupted - the fiber was interrupted
            \\* :suspended - the fiber is waiting to be resumed by the scheduler
            \\* :new - the fiber has just been created and not yet run
            \\* :alive - the fiber is currently running and cannot be resumed
        ),
        corefn.reg("fiber/root", &cfunFiberRoot, @src(), "(fiber/root)", "Returns the current root fiber. The root fiber is the oldest " ++
            "ancestor that does not have a parent. Note that a root fiber " ++
            "is also a task fiber."),
        corefn.reg("fiber/current", &cfunFiberCurrent, @src(), "(fiber/current)", "Returns the currently running fiber."),
        corefn.reg("fiber/maxstack", &cfunFiberMaxstack, @src(), "(fiber/maxstack fib)", "Gets the maximum stack size in janet values allowed for a fiber. While memory for " ++
            "the fiber's stack is not allocated up front, the fiber will not allocated more " ++
            "than this amount and will throw a stack-overflow error if more memory is needed. "),
        corefn.reg("fiber/setmaxstack", &cfunFiberSetmaxstack, @src(), "(fiber/setmaxstack fib maxstack)", "Sets the maximum stack size in janet values for a fiber. By default, the " ++
            "maximum stack size is usually 8192."),
        corefn.reg("fiber/getenv", &cfunFiberGetenv, @src(), "(fiber/getenv fiber)", "Gets the environment for a fiber. Returns nil if no such table is " ++
            "set yet."),
        corefn.reg("fiber/setenv", &cfunFiberSetenv, @src(), "(fiber/setenv fiber table)", "Sets the environment table for a fiber. Set to nil to remove the current " ++
            "environment."),
        corefn.reg("fiber/can-resume?", &cfunFiberCanResume, @src(), "(fiber/can-resume? fiber)", "Check if a fiber is finished and cannot be resumed."),
        corefn.reg("fiber/last-value", &cfunFiberLastValue, @src(), "(fiber/last-value fiber)", "Get the last value returned or signaled from the fiber."),
        corefn.end,
    };
    corefn.install(env, &entries);
}
