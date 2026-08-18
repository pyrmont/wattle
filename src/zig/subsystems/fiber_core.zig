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
//! `janet_fiber` and `janet_fiber_reset` stay in C on purpose. They are fiber
//! *allocation* — `janet_gcalloc` plus the collector's byte budget — which is
//! Phase 8's subject, not this one.

const std = @import("std");
const abi = @import("abi");
const c = abi.c;

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
const frame_size: i32 = c.JANET_FRAME_SIZE;

/// `janet_vm` as `src/core/state.h` declares it, resolved through `abi.zig`.
/// Whether it is thread-local is the C header's decision; Zig inherits it.
inline fn vm() *c.JanetVM {
    return &c.janet_vm;
}

inline fn dataAt(fiber: *c.JanetFiber, index: i32) [*c]c.Janet {
    return fiber.data + @as(usize, @bitCast(@as(isize, index)));
}

/// `janet_stack_frame` from `fiber.h`: a frame lives in the four `Janet` slots
/// immediately below the frame's stack base.
inline fn stackFrame(values: [*c]c.Janet) *c.JanetStackFrame {
    return @ptrCast(@alignCast(values - frame_size));
}

inline fn fiberFrame(fiber: *c.JanetFiber) *c.JanetStackFrame {
    return stackFrame(dataAt(fiber, fiber.frame));
}

/// C computes `sizeof(Janet) * n` with `n` an `int32_t`, so a negative `n` —
/// which `2 * nextstacktop` can produce on a very large stack — becomes an
/// enormous `size_t` and the allocation fails. Reproduced rather than
/// corrected: the result is a fatal out-of-memory either way, and changing it
/// would change which diagnostic a caller sees.
inline fn janetBytes(n: i32) usize {
    return @bitCast(@as(isize, n) *% @as(isize, @sizeOf(c.Janet)));
}

/// Only compiled when `janetconf.h` defines JANET_DEBUG, which no build option
/// does; it is edited in by hand to shake out use-after-free by moving the
/// stack on every frame push.
const debug_build = @hasDecl(c, "JANET_DEBUG");

fn refreshMemory(fiber: *c.JanetFiber) void {
    const n = fiber.capacity;
    if (n != 0) {
        const new_data = c.janet_malloc(janetBytes(n)) orelse c.janet_zig_out_of_memory();
        const dest: [*c]c.Janet = @ptrCast(@alignCast(new_data));
        @memcpy(dest[0..@intCast(n)], fiber.data[0..@intCast(n)]);
        c.janet_free(fiber.data);
        fiber.data = dest;
    }
}

/// The shape shared by every frame push: grow if the frame will not fit, and
/// otherwise shuffle the allocation in a debug build.
inline fn reserve(fiber: *c.JanetFiber, nextstacktop: i32) void {
    if (fiber.capacity < nextstacktop) {
        janet_fiber_setcapacity(fiber, 2 *% nextstacktop);
    } else if (debug_build) {
        refreshMemory(fiber);
    }
}

inline fn fillNil(fiber: *c.JanetFiber, from: i32, to: i32) void {
    var i = from;
    while (i < to) : (i += 1) {
        dataAt(fiber, i)[0] = c.janet_wrap_nil();
    }
}

// ------------------------------------------------------------------ growth

export fn janet_fiber_setcapacity(fiber: *c.JanetFiber, n: i32) callconv(.c) void {
    const old_size = fiber.capacity;
    const diff = n -% old_size;
    const new_data = c.janet_realloc(fiber.data, janetBytes(n)) orelse
        c.janet_zig_out_of_memory();
    fiber.data = @ptrCast(@alignCast(new_data));
    fiber.capacity = n;
    // Unsigned wraparound is how the C original shrinks the budget: `diff` is
    // negative and the product is added to a `size_t`.
    vm().next_collection +%= janetBytes(diff);
}

fn fiberGrow(fiber: *c.JanetFiber, needed: i32) void {
    const cap: i32 = if (needed > @divTrunc(std.math.maxInt(i32), 2))
        std.math.maxInt(i32)
    else
        2 *% needed;
    janet_fiber_setcapacity(fiber, cap);
}

// ------------------------------------------------------------------ pushes

// Each of these returns nonzero for "stack overflow" rather than raising it.
// The C wrapper turns that into the panic the caller expects.

export fn janet_zig_fiber_push(fiber: *c.JanetFiber, x: *const c.Janet) callconv(.c) c_int {
    if (fiber.stacktop == std.math.maxInt(i32)) return 1;
    if (fiber.stacktop >= fiber.capacity) fiberGrow(fiber, fiber.stacktop);
    dataAt(fiber, fiber.stacktop)[0] = x.*;
    fiber.stacktop += 1;
    return 0;
}

export fn janet_zig_fiber_push2(
    fiber: *c.JanetFiber,
    x: *const c.Janet,
    y: *const c.Janet,
) callconv(.c) c_int {
    if (fiber.stacktop >= std.math.maxInt(i32) - 1) return 1;
    const newtop = fiber.stacktop + 2;
    if (newtop > fiber.capacity) fiberGrow(fiber, newtop);
    const slots = dataAt(fiber, fiber.stacktop);
    slots[0] = x.*;
    slots[1] = y.*;
    fiber.stacktop = newtop;
    return 0;
}

export fn janet_zig_fiber_push3(
    fiber: *c.JanetFiber,
    x: *const c.Janet,
    y: *const c.Janet,
    z: *const c.Janet,
) callconv(.c) c_int {
    if (fiber.stacktop >= std.math.maxInt(i32) - 2) return 1;
    const newtop = fiber.stacktop + 3;
    if (newtop > fiber.capacity) fiberGrow(fiber, newtop);
    const slots = dataAt(fiber, fiber.stacktop);
    slots[0] = x.*;
    slots[1] = y.*;
    slots[2] = z.*;
    fiber.stacktop = newtop;
    return 0;
}

export fn janet_zig_fiber_pushn(
    fiber: *c.JanetFiber,
    arr: [*c]const c.Janet,
    n: i32,
) callconv(.c) c_int {
    if (fiber.stacktop > std.math.maxInt(i32) -% n) return 1;
    const newtop = fiber.stacktop +% n;
    if (newtop > fiber.capacity) fiberGrow(fiber, newtop);
    // safe_memcpy rather than @memcpy: `arr` is null when `n` is zero at
    // several call sites, and a null source is what that helper exists for.
    safe_memcpy(dataAt(fiber, fiber.stacktop), arr, janetBytes(n));
    fiber.stacktop = newtop;
    return 0;
}

// ------------------------------------------------------------------- frames

/// Push a call frame for `func`. Returns 1 without touching the fiber if the
/// argument count is outside the function's arity, and otherwise reports
/// through `slot_out` where a variadic tail has to be packed: -1 for none, or
/// the slot index with `count_out` values to gather from it. C does the
/// packing, because building a tuple or a struct can raise.
export fn janet_zig_fiber_funcframe(
    fiber: *c.JanetFiber,
    func: *c.JanetFunction,
    slot_out: *i32,
    count_out: *i32,
) callconv(.c) c_int {
    const def = func.def;
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
    if (def.*.flags & c.JANET_FUNCDEF_FLAG_VARARG != 0) {
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
export fn janet_zig_fiber_funcframe_tail_begin(
    fiber: *c.JanetFiber,
    func: *c.JanetFunction,
    slot_out: *i32,
    count_out: *i32,
    stacksize_out: *i32,
) callconv(.c) c_int {
    const def = func.def;
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
    if (frame.func != null) envDetach(frame.env);
    frame.env = null;

    // Check varargs
    if (def.*.flags & c.JANET_FUNCDEF_FLAG_VARARG != 0) {
        const tuplehead = fiber.stackstart +% def.*.arity;
        if (tuplehead >= fiber.stacktop) {
            if (tuplehead >= fiber.capacity) {
                janet_fiber_setcapacity(fiber, 2 *% (tuplehead +% 1));
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
export fn janet_zig_fiber_funcframe_tail_finish(
    fiber: *c.JanetFiber,
    func: *c.JanetFunction,
    stacksize: i32,
) callconv(.c) void {
    const def = func.def;
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
    frame.flags |= c.JANET_STACKFRAME_TAILCALL;
}

export fn janet_fiber_cframe(fiber: *c.JanetFiber, cfun: c.JanetCFunction) callconv(.c) void {
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

export fn janet_fiber_popframe(fiber: *c.JanetFiber) callconv(.c) void {
    const frame = fiberFrame(fiber);
    if (fiber.frame == 0) return;

    // Clean up the frame (detach environments)
    if (frame.func != null) envDetach(frame.env);

    // Shrink stack
    fiber.stacktop = fiber.frame;
    fiber.stackstart = fiber.frame;
    fiber.frame = frame.prevframe;
}

// ------------------------------------------------- function environments

/// Copy a closure environment off the fiber's stack so it can outlive the
/// frame that produced it. The values the function's `closure_bitset` does not
/// claim are dropped, which is what keeps a closure from rooting every local of
/// its defining frame.
fn envDetach(maybe_env: [*c]c.JanetFuncEnv) void {
    // Check for closure environment
    if (maybe_env == null) return;
    const env = maybe_env;
    _ = envValid(env);
    const len = env.*.length;
    const bytes = janetBytes(len);
    const memory = c.janet_malloc(bytes);
    // The budget is bumped before the null check, and through a `uint32_t`
    // truncation, in the C original. Both are reproduced.
    vm().next_collection +%= @as(u32, @truncate(bytes));
    if (memory == null) c.janet_zig_out_of_memory();
    const vmem: [*c]c.Janet = @ptrCast(@alignCast(memory));
    const values = env.*.as.fiber.*.data + @as(usize, @bitCast(@as(isize, env.*.offset)));
    safe_memcpy(vmem, values, bytes);
    const bitset = stackFrame(values).func.*.def.*.closure_bitset;
    if (bitset != null) {
        // Clear unneeded references in closure environment
        var i: i32 = 0;
        while (i < len) : (i += 32) {
            var mask = ~bitset[@intCast(i >> 5)];
            const maxj = if (i + 32 > len) len else i + 32;
            var j = i;
            while (j < maxj) : (j += 1) {
                if (mask & 1 != 0) vmem[@intCast(j)] = c.janet_wrap_nil();
                mask >>= 1;
            }
        }
    }
    env.*.offset = 0;
    env.*.as.values = vmem;
}

fn envValid(env: [*c]c.JanetFuncEnv) c_int {
    if (env.*.offset >= 0) return 1;
    const real_offset = -%env.*.offset;
    const fiber = env.*.as.fiber;
    var i = fiber.*.frame;
    while (i > 0) {
        const frame = stackFrame(fiber.*.data + @as(usize, @bitCast(@as(isize, i))));
        if (real_offset == i and
            frame.env == env and
            frame.func != null and
            frame.func.*.def.*.slotcount == env.*.length)
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
export fn janet_env_valid(env: *c.JanetFuncEnv) callconv(.c) c_int {
    return envValid(env);
}

/// Detach an environment from its fiber once that fiber can no longer mutate
/// the slots the environment points at.
export fn janet_env_maybe_detach(env: *c.JanetFuncEnv) callconv(.c) void {
    // Check for detachable closure envs
    _ = envValid(env);
    if (env.offset > 0) {
        if (isFinished(statusOf(env.as.fiber))) envDetach(env);
    }
}

// -------------------------------------------------------------- inspection

/// The seven statuses that mean a fiber has run to a stop. Shared by
/// `janet_env_maybe_detach` and `janet_fiber_can_resume`, which is how the C
/// original had it too — as two copies of the same list.
inline fn isFinished(status: c.JanetFiberStatus) bool {
    return switch (status) {
        c.JANET_STATUS_DEAD,
        c.JANET_STATUS_ERROR,
        c.JANET_STATUS_USER0,
        c.JANET_STATUS_USER1,
        c.JANET_STATUS_USER2,
        c.JANET_STATUS_USER3,
        c.JANET_STATUS_USER4,
        => true,
        else => false,
    };
}

inline fn statusOf(f: [*c]c.JanetFiber) c.JanetFiberStatus {
    return @intCast((f.*.flags & c.JANET_FIBER_STATUS_MASK) >> c.JANET_FIBER_STATUS_OFFSET);
}

export fn janet_fiber_status(f: *c.JanetFiber) callconv(.c) c.JanetFiberStatus {
    return statusOf(f);
}

export fn janet_fiber_can_resume(fiber: *c.JanetFiber) callconv(.c) c_int {
    return @intFromBool(!isFinished(statusOf(fiber)));
}

export fn janet_current_fiber() callconv(.c) [*c]c.JanetFiber {
    return vm().fiber;
}

export fn janet_root_fiber() callconv(.c) [*c]c.JanetFiber {
    return vm().root_fiber;
}
