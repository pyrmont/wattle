//! Fiber stack frames, funcframes, and function environments: the machinery a
//! call goes through on its way onto and off a fiber's value stack.
//!
//! It reaches the VM state by name and reads and writes `Fiber`,
//! `vm/state.zig`'s `StackFrame` and `functions.FuncEnv` directly -- all three
//! are `pub`, so nothing private is being exposed to get here.
//!
//! **Allocation failure is not a raise.** Running out of memory is fatal by
//! policy, so `fatal.outOfMemory` is called directly.
//!
//! ## The kernels raise by returning
//!
//! The four pushes raise by returning `raise.Error` and their callers `try`
//! them; one abi survives beside them, for a caller that cannot.
//!
//! The struct packing and the varargs fill are here too, so that `funcframe`
//! and `funcframeTail` are whole instead of being a kernel in two halves with
//! a packing step between them. Neither
//! *raises* -- an arity mismatch is reported as 1, which is what the loop
//! branches on -- but both can raise *through*, because `structs.put` hashes
//! the caller's keys and an abstract type's `hash` callback is a function
//! pointer the runtime does not own.

const std = @import("std");
const raise = @import("../../api/raise.zig");
const pp_format = @import("../pp/format.zig");
const corefn = @import("../corefn.zig");
const args_core = @import("../args.zig");
const config = @import("config");
const structs = @import("structs.zig");
const tables = @import("tables.zig");
const tuples = @import("tuples.zig");
const utils = @import("../utils.zig");
const wrap = @import("helpers/wrap.zig");
const fatal = @import("../fatal.zig");
const gc_alloc = @import("../gc.zig");
const functions = @import("functions.zig");
const repr = @import("repr");
const constants = @import("constants");
const value = @import("../value.zig");
const vm_state = @import("../vm/state.zig");
const abi = @import("abi");
const signal = @import("../signal.zig");
const ev_stream = @import("../ev/stream.zig");
const ev_loop = @import("../ev.zig");

/// A stack frame's size in `Value` slots, named locally so the arithmetic below
/// reads as arithmetic. The two helpers under it are the only places that do
/// it.
const frame_size: i32 = constants.JANET_FRAME_SIZE;

/// A fiber's status, stored in six bits of its flag word, which `statusOf`
/// below reads and whose width the `comptime` block beside `statusOf`
/// asserts.
///
/// **Declared in `abi.zig` because a module author reads one.** `module.pcall`
/// hands back a fiber and `module.fiberStatus` answers this over it, so both
/// compilations have to agree on the numbering; every operation over a fiber
/// is here, which is the split `KV`, `Method` and `ByteView` already have.
/// It is a vocabulary rather than a layout, which is why `abi.zig` gaining it
/// leaves `DESIGN.md` section 15's invariant intact.
pub const FiberStatus = abi.FiberStatus;

/// The GC header's per-type field, as a fiber reads it. `canceled`,
/// `suspended` and `root` are the event loop's three bits, and the same six
/// bits carry the signal `signal.signalInject` arms the fiber to raise --
/// which is why arming one clears all three. `abi.GCFlags` records why that
/// aliasing is kept.
pub const EvFlags = packed struct(u6) {
    canceled: bool = false,
    suspended: bool = false,
    root: bool = false,
    _rest: u3 = 0,
};

pub inline fn evFlags(fiber: *const Fiber) EvFlags {
    return @bitCast(fiber.gc.flags.own);
}

inline fn dataAt(fiber: *Fiber, index: i32) [*]repr.Value {
    return fiber.data.? + @as(usize, @bitCast(@as(isize, index)));
}

/// A frame lives in the four `Janet` slots immediately below the frame's
/// stack base.
pub inline fn stackFrame(values: [*]repr.Value) *vm_state.StackFrame {
    return @ptrCast(@alignCast(values - frame_size));
}

inline fn fiberFrame(fiber: *Fiber) *vm_state.StackFrame {
    return stackFrame(dataAt(fiber, fiber.frame));
}

/// **A negative count is contract.** `2 * nextstacktop` can produce one on a
/// very large stack, and widening it makes an enormous size the allocation
/// refuses. The result is a fatal out-of-memory either way, so it is left as
/// it is rather than changed into a different diagnostic.
pub inline fn stackBytes(n: i32) usize {
    return @bitCast(@as(isize, n) *% @as(isize, @sizeOf(repr.Value)));
}

/// Move every fiber's stack on every frame push, so that a pointer kept across
/// one is a use-after-free the allocator can see. `-Dfiber-stack-shuffle=true`
/// turns it on; it is off by default because it reallocates on every call.
const debug_build = config.debug;

fn refreshMemory(fiber: *Fiber) void {
    const n = fiber.capacity;
    if (n != 0) {
        const dest = utils.allocMany(repr.Value, @intCast(n));
        @memcpy(dest[0..@intCast(n)], fiber.data.?[0..@intCast(n)]);
        utils.free(fiber.data);
        fiber.data = dest;
    }
}

/// The shape shared by every frame push: grow if the frame will not fit, and
/// otherwise shuffle the allocation in a debug build.
inline fn reserve(fiber: *Fiber, nextstacktop: i32) void {
    if (fiber.capacity < nextstacktop) {
        setcapacity(fiber, 2 *% nextstacktop);
    } else if (debug_build) {
        refreshMemory(fiber);
    }
}

inline fn fillNil(fiber: *Fiber, from: i32, to: i32) void {
    var i = from;
    while (i < to) : (i += 1) {
        dataAt(fiber, i)[0] = wrap.fromNil();
    }
}

// -------------------------------------------------------------- allocation
//
// These four live here rather than in an allocation file of their own: the
// only word that covers a fiber and a funcdef at once is "alloc", and it
// covers them by saying nothing.

/// `config.ev`. `Fiber` carries five extra fields when the event loop is
/// compiled in, and `resetState` clears all of them. The condition is
/// comptime, so the fields are named only in a build where they exist.
const has_ev = constants.JANET_VM_HAS_EV != 0;

/// Return a fiber to its newborn state: no frames, no child, no environment,
/// the default signal mask, and status `.new`. Called on a block
/// `alloc` has just produced and on one `reset` is recycling, which is why it
/// clears rather than assumes.
///
/// `capacity` and `data` are deliberately untouched: a recycled fiber keeps the
/// stack it already paid for, and that is the whole point of reusing one.
///
/// It resets the *state* rather than the fiber: `reset` below is the entry
/// point that takes only a fiber, and this is the half of it that does not
/// touch the stack.
fn resetState(fiber: *Fiber) void {
    fiber.maxstack = config.stack_max;
    fiber.frame = 0;
    fiber.stackstart = frame_size;
    fiber.stacktop = frame_size;
    fiber.child = null;
    fiber.flags = .{
        .traps = .of(&.{.yield}),
        .resume_no_useval = true,
        .resume_no_skip = true,
    };
    fiber.env = null;
    fiber.last_value = wrap.fromNil();
    if (has_ev) {
        fiber.sched_id = 0;
        fiber.ev_callback = null;
        fiber.ev_state = null;
        fiber.ev_stream = null;
        fiber.supervisor_channel = null;
    }
    setStatus(fiber, FiberStatus.new);
}

/// Allocate a fiber and its value stack. The block is collectable and on
/// `vm.gc.blocks` before this returns; the stack is a plain allocation the
/// collector knows about only through `gc/sweep.zig`'s `deinitBlock`, which is
/// why the byte charge is made here by hand.
///
/// **The charge and `setcapacity`'s have to agree.** A fiber is charged once
/// for its initial capacity and once per resize, never twice and never zero
/// times. `test/value_alloc.zig` checks this charge against the same arithmetic
/// `test/fiber_core.zig` checks `setcapacity`'s against, and that pairing is
/// what says the two stay in step.
///
/// **The 32-slot floor is applied before the capacity is written**, so a caller
/// asking for zero gets a fiber whose `capacity` reads 32 and whose charge is
/// 32 slots. A negative request lands on the same floor rather than wrapping
/// into an enormous allocation, which is what makes the `@intCast` below safe.
///
/// The fiber is returned with `capacity` and `data` set and *nothing else*
/// initialised. Both callers run `resetState` over it immediately, and a
/// collection cannot intervene: no allocation happens between the two.
fn alloc(requested: i32) *Fiber {
    const fiber = gc_alloc.gcalloc(Fiber, .fiber);
    const capacity: i32 = if (requested < 32) 32 else requested;
    fiber.capacity = capacity;
    vm_state.current().gc.next_collection +%= stackBytes(capacity);
    fiber.data = utils.allocMany(repr.Value, @intCast(capacity));
    return fiber;
}

/// Create a new fiber with `args` on the stack by reusing `fiber`.
///
/// Answers `error.Arity` when the callee's arity rejects the argument count,
/// which is why the failure is a return value rather than a panic:
/// `vm/entry.zig`'s `pcall` turns it into a `Resumed` of its own. Everything
/// before the funcframe has already been written by then, so the rejected
/// fiber is reset but frameless.
///
/// `args` is a slice, so "no arguments" is an empty slice rather than a null
/// with a count. `fiber/new`, seeding a one-argument fiber, passes the nil it
/// means.
pub fn reset(
    fiber: *Fiber,
    callee: *functions.Function,
    args: []const repr.Value,
) ArityError!*Fiber {
    resetState(fiber);
    if (args.len != 0) {
        // The sum and the doubling are both bounded, which is what `grow`
        // beside this does for the other route into `setcapacity`. Unbounded
        // they wrap negative, and `setcapacity` turns a negative count into an
        // enormous byte request and a fatal out-of-memory -- the right refusal
        // reached through two wraps.
        const requested = std.math.add(i32, fiber.stacktop, @intCast(args.len)) catch
            fatal.outOfMemory();
        if (requested >= fiber.capacity) grow(fiber, requested);
        const newstacktop = requested;
        const dest = fiber.data.? + @as(usize, @intCast(fiber.stacktop));
        @memcpy(dest[0..args.len], args);
        fiber.stacktop = newstacktop;
    }
    // The rejection travels as an error rather than as a null: `pcall` is the
    // caller that has to tell "no fiber" from "this fiber refused the
    // arguments", and only one of the two is a thing a Janet program did.
    try funcframe(fiber, callee);
    fiberFrame(fiber).flags.entrance = true;
    if (has_ev) fiber.supervisor_channel = null;
    return fiber;
}

/// Create a new fiber with `args` on the stack.
pub fn new(
    callee: *functions.Function,
    capacity: i32,
    args: []const repr.Value,
) ArityError!*Fiber {
    return reset(alloc(capacity), callee, args);
}

// ------------------------------------------------------------------ growth

pub fn setcapacity(fiber: *Fiber, n: i32) void {
    const old_size = fiber.capacity;
    const diff = n -% old_size;
    const new_data = utils.realloc(fiber.data, stackBytes(n)) orelse
        fatal.outOfMemory();
    fiber.data = @ptrCast(@alignCast(new_data));
    fiber.capacity = n;
    // The budget shrinks by wraparound: `diff` is negative and the product is
    // added to a `usize`, which is the arithmetic the charge is defined by.
    vm_state.current().gc.next_collection +%= stackBytes(diff);
}

fn grow(fiber: *Fiber, needed: i32) void {
    const cap: i32 = if (needed > @divTrunc(std.math.maxInt(i32), 2))
        std.math.maxInt(i32)
    else
        2 *% needed;
    setcapacity(fiber, cap);
}

// ------------------------------------------------------------------ pushes

// Each of these raises "stack overflow" by returning it, so a caller `try`s
// it rather than testing a status.
//
// The three fixed-arity pushes take their values rather than pointers to them:
// `vm.zig`'s `runVm` passes a slot of the fiber stack, which is a value it
// already holds, and no caller has an address it would rather hand over.
// `pushn` keeps its pointer, because a run of values is what it takes.

pub fn push(fiber: *Fiber, x: repr.Value) raise.Error!void {
    if (fiber.stacktop == std.math.maxInt(i32)) return raise.panic("stack overflow");
    if (fiber.stacktop >= fiber.capacity) grow(fiber, fiber.stacktop);
    dataAt(fiber, fiber.stacktop)[0] = x;
    fiber.stacktop += 1;
}

pub fn push2(fiber: *Fiber, x: repr.Value, y: repr.Value) raise.Error!void {
    if (fiber.stacktop >= std.math.maxInt(i32) - 1) return raise.panic("stack overflow");
    const newtop = fiber.stacktop + 2;
    if (newtop > fiber.capacity) grow(fiber, newtop);
    const slots = dataAt(fiber, fiber.stacktop);
    slots[0] = x;
    slots[1] = y;
    fiber.stacktop = newtop;
}

pub fn push3(fiber: *Fiber, x: repr.Value, y: repr.Value, z: repr.Value) raise.Error!void {
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
    fiber: *Fiber,
    arr: []const repr.Value,
) raise.Error!void {
    const n: i32 = @intCast(arr.len);
    if (fiber.stacktop > std.math.maxInt(i32) -% n) return raise.panic("stack overflow");
    const newtop = fiber.stacktop +% n;
    var src = arr;
    if (newtop > fiber.capacity) {
        // **The source may be a slice of this same stack, and growing frees
        // it.** `grow` reaches `setcapacity`, which reallocates, so a caller
        // pushing a run that lives on this fiber -- a native module forwarding
        // its own `argv` through `vm/entry.zig`'s `callValue` is the short way
        // to get one -- would have the copy below read the block that was just
        // released. The offset is what carries the slice across the move.
        //
        // It is inside the growth branch and not above it because that is
        // where the hazard is: a push that fits reallocates nothing, and its
        // path is untouched. The branch it does sit in already copies the
        // whole stack, so two pointer comparisons are not a cost that shows.
        const offset = stackOffset(fiber, src);
        grow(fiber, newtop);
        if (offset) |at| src = (fiber.data.? + at)[0..src.len];
    }
    // Guarded rather than unconditional: `src` is an empty slice over a null
    // pointer at several call sites, and copying zero bytes from a null source
    // is undefined even where every implementation makes it a no-op.
    if (src.len != 0) @memcpy(dataAt(fiber, fiber.stacktop)[0..src.len], src);
    fiber.stacktop = newtop;
}

/// Where `arr` starts within this fiber's stack, or null if it is elsewhere.
///
/// An empty slice answers null: it carries no pointer worth re-deriving, and
/// `pushn` copies nothing from it.
fn stackOffset(fiber: *const Fiber, arr: []const repr.Value) ?usize {
    const data = fiber.data orelse return null;
    if (arr.len == 0) return null;
    const base = @intFromPtr(data);
    const start = @intFromPtr(arr.ptr);
    if (start < base or start >= base + stackBytes(fiber.capacity)) return null;
    return (start - base) / @sizeOf(repr.Value);
}

// --------------------------------------------------------------- varargs

/// Create a struct with n values. If n is odd, the last value is ignored.
///
/// It is here because `funcframe` is, and it is why nothing in this file holds
/// anything across a call: `structs.put` hashes the caller's keys, so an
/// abstract type's `hash` callback runs underneath it,
/// and that callback is a function pointer the runtime does not own. It may
/// not raise; nothing enforces it. This frame holds nothing.
fn makeStructN(args: []const repr.Value) repr.Value {
    const st = structs.begin(args.len & ~@as(usize, 1));
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 2) {
        structs.put(st, args[i], args[i + 1]);
    }
    return wrap.fromStruct(structs.end(st));
}

/// Build the variadic tail the frame setup located and store it in its slot.
///
/// A count of zero is an empty tail rather than an empty range, which is why
/// the source pointer is null there.
fn fillVarargs(fiber: *Fiber, func: *functions.Function, slot: i32, count: i32) void {
    const structarg = func.def.?.flags.structarg;
    // The empty tail is an empty *slice* rather than a null pointer with a
    // zero count. `values.?[0..count]` here traps on the first varargs call
    // with no arguments -- `DESIGN.md` section 9's "a `.?` is a claim about
    // length", demonstrated.
    const values: []const repr.Value = if (count != 0)
        dataAt(fiber, slot)[0..@intCast(count)]
    else
        &.{};
    dataAt(fiber, slot)[0] = if (structarg)
        makeStructN(values)
    else
        wrap.fromTuple(tuples.newFrom(values));
}

// The one abi of the pushes. It is written out rather than generated by
// `raise.panicking`, which builds an abi for a function that returns a payload
// and has nothing to wrap where the return is `void`.

// ------------------------------------------------------------------- frames

/// A variadic tail waiting to be packed: the slot to pack it into, and how
/// many values to gather from there.
///
/// It travels out of the two `Begin` halves rather than being used inside them
/// because the tail-call path needs the packing to happen at a different point
/// in the sequence -- see `funcframeTailBegin`.
const Varargs = struct { slot: i32, count: i32 };

/// What pushing half a frame decided: the frame is pushed and a variadic tail
/// may still want packing, or the arity refused the arguments and the fiber was
/// not touched.
///
/// A union rather than a status beside two out-parameters with sentinels:
/// three states, two of which would otherwise be one state at two sentinel
/// values.
const FrameBegin = union(enum) {
    pushed: ?Varargs,
    arity_mismatch,
};

/// Refusal from a frame push: the argument count was outside the callee's
/// arity. Not a raise -- every caller decides for itself what to say, and two
/// of them say nothing.
pub const ArityError = error{Arity};

/// Push a call frame for `func`, packing its variadic tail if it has one.
///
/// `error.Arity` without touching the fiber if the argument count is outside
/// the function's arity.
pub fn funcframe(fiber: *Fiber, func: *functions.Function) ArityError!void {
    switch (funcframeBegin(fiber, func)) {
        .arity_mismatch => return error.Arity,
        .pushed => |tail| if (tail) |t| fillVarargs(fiber, func, t.slot, t.count),
    }
}

/// Everything up to the point where a variadic tail's value is needed.
///
/// Split from the fill above rather than folded into it because the tail-call
/// path needs the two halves in a different order -- the tail's value has to
/// exist before the arguments are moved down over the outgoing frame.
fn funcframeBegin(fiber: *Fiber, func: *functions.Function) FrameBegin {
    const def = func.def.?;
    const oldtop = fiber.stacktop;
    const oldframe = fiber.frame;
    const nextframe = fiber.stackstart;
    const nextstacktop = nextframe +% def.slotcount +% frame_size;
    const next_arity = fiber.stacktop -% fiber.stackstart;

    // Check strict arity before messing with state
    if (next_arity < def.min_arity) return .arity_mismatch;
    if (next_arity > def.max_arity) return .arity_mismatch;

    reserve(fiber, nextstacktop);

    // Nil unset stack arguments (Needed for gc correctness)
    fillNil(fiber, fiber.stacktop, nextstacktop);

    // Set up the next frame
    fiber.frame = nextframe;
    fiber.stacktop = nextstacktop;
    fiber.stackstart = nextstacktop;
    const newframe = fiberFrame(fiber);
    newframe.prevframe = oldframe;
    newframe.pc = def.bytecode;
    newframe.func = func;
    newframe.env = null;
    newframe.flags = .{};

    // Check varargs
    if (!def.flags.vararg) return .{ .pushed = null };
    const tuplehead = fiber.frame +% def.arity;
    return .{ .pushed = .{
        .slot = tuplehead,
        .count = if (tuplehead >= oldtop) 0 else oldtop -% tuplehead,
    } };
}

/// The first half of a tail call. Everything up to the point where the
/// variadic tail's value is needed: arity, capacity, detaching the outgoing
/// frame's environment, and the gap fill an empty tail requires. `stacksize` is
/// how many slots the finishing half has to move down.
pub fn funcframeTail(fiber: *Fiber, func: *functions.Function) ArityError!void {
    const begun = switch (funcframeTailBegin(fiber, func)) {
        .arity_mismatch => return error.Arity,
        .pushed => |begun| begun,
    };
    if (begun.tail) |t| fillVarargs(fiber, func, t.slot, t.count);
    funcframeTailFinish(fiber, func, begun.stacksize);
}

/// The tail-call half's answer: the variadic tail to pack, if any, and how
/// many slots the finishing half has to move down.
const TailBegin = union(enum) {
    pushed: struct { tail: ?Varargs, stacksize: i32 },
    arity_mismatch,
};

fn funcframeTailBegin(fiber: *Fiber, func: *functions.Function) TailBegin {
    const def = func.def.?;
    const nextstacktop = fiber.frame +% def.slotcount +% frame_size;
    const next_arity = fiber.stacktop -% fiber.stackstart;

    // Check strict arity before messing with state
    if (next_arity < def.min_arity) return .arity_mismatch;
    if (next_arity > def.max_arity) return .arity_mismatch;

    reserve(fiber, nextstacktop);

    // Detach old function
    const frame = fiberFrame(fiber);
    if (frame.func != null) functions.envDetach(frame.env);
    frame.env = null;

    // Check varargs
    if (!def.flags.vararg) return .{ .pushed = .{
        .tail = null,
        .stacksize = fiber.stacktop -% fiber.stackstart,
    } };

    const tuplehead = fiber.stackstart +% def.arity;
    var count: i32 = undefined;
    if (tuplehead >= fiber.stacktop) {
        if (tuplehead >= fiber.capacity) {
            setcapacity(fiber, 2 *% (tuplehead +% 1));
        }
        fillNil(fiber, fiber.stacktop, tuplehead);
        count = 0;
    } else {
        count = fiber.stacktop -% tuplehead;
    }
    return .{ .pushed = .{
        .tail = .{ .slot = tuplehead, .count = count },
        .stacksize = tuplehead -% fiber.stackstart +% 1,
    } };
}

/// The second half: move the arguments down over the outgoing frame's slots,
/// nil the rest, and repoint the frame at `func`. Runs after the caller has
/// stored the variadic tail, because the move copies that slot too.
fn funcframeTailFinish(
    fiber: *Fiber,
    func: *functions.Function,
    stacksize: i32,
) void {
    const def = func.def.?;
    const nextframetop = fiber.frame +% def.slotcount;
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
    frame.pc = def.bytecode;
    frame.flags.tailcall = true;
}

pub fn cframe(fiber: *Fiber, cfun: abi.CFunction) void {
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
    // The cfunction goes in the frame's `pc` slot, and a frame with a null
    // `func` is what marks it a C frame. Function and data pointers are
    // distinct kinds in Zig, so the reinterpretation goes through the address.
    newframe.pc = @ptrFromInt(@intFromPtr(cfun));
    newframe.func = null;
    newframe.env = null;
    newframe.flags = .{};
}

pub fn popframe(fiber: *Fiber) void {
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
/// `functions.envMaybeDetach` is its one caller, and asks it rather than
/// carrying the list itself. `vm/entry.zig`'s `checkCanResume` keeps a list of
/// its own, because it refuses `.alive` as well and this predicate does not.
pub fn finished(f: *Fiber) bool {
    return switch (statusOf(f)) {
        .dead, .@"error", .user0, .user1, .user2, .user3, .user4 => true,
        // Listed rather than `else`, so a status added later has to be
        // *decided* here instead of defaulting to "still running".
        .debug, .pending, .user5, .user6, .user7, .user8, .user9, .new, .alive => false,
    };
}

/// The six bits `constants.JANET_FIBER_STATUS_MASK` covers, read as the vocabulary they
/// hold. The field is wider than the vocabulary -- six bits for sixteen
/// values -- and the assertion below is what says so; every writer is in this
/// tree and `marsh.zig` validates the one value that arrives from outside it.
inline fn statusOf(f: *Fiber) FiberStatus {
    return @enumFromInt(f.flags.status);
}

comptime {
    // The stored width, which is the fiber flag word's and not the enum's.
    const stored = std.math.maxInt(@FieldType(FiberFlags, "status"));
    for (@typeInfo(FiberStatus).@"enum".fields) |f| {
        std.debug.assert(f.value <= stored);
    }
}

pub fn status(f: *Fiber) FiberStatus {
    return statusOf(f);
}

/// The status of the fiber a `Value` names, refusing anything that is not one.
///
/// **The module boundary's form**, in the shape `arrays.pushChecked` set:
/// `DESIGN.md` section 15 keeps `*Fiber` off the author surface, so a module
/// names a fiber the only way it can and the tag test is on this side. The
/// refusal names the type and the value and no argument slot, because there is
/// none -- the fiber came back from `pcall` rather than out of `argv`.
pub fn statusChecked(v: repr.Value) raise.Raising(FiberStatus) {
    if (!repr.checkType(v, repr.Tag.fiber)) {
        return pp_format.panicf("expected %T, got %v", .{ repr.TagSet.one(repr.Tag.fiber), v });
    }
    return statusOf(wrap.toFiber(v));
}

pub fn canResume(fiber: *Fiber) bool {
    return !finished(fiber);
}

pub fn current() ?*Fiber {
    return vm_state.current().fiber;
}

pub fn root() ?*Fiber {
    return vm_state.current().root_fiber;
}

// ==========================================================================
// fiber/*, the cfunction surface
// ==========================================================================
//
// Ten builtins: nine of them two lines over a field of `Fiber` that the
// kernels above already own, and the tenth -- `fiber/new` -- the flag parser,
// which is the only real code in the set. They are here rather than in a file
// of their own because they are this subsystem's own surface.
//
// A builtin returns `raise.Error!repr.Value` rather than recording its raise in
// a VM field and returning an unspecified value, so a caller that forgets to
// `try` is a compile error again.

fn cfunFiberGetenv(argv: []repr.Value) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    const fiber = try args_core.getFiber(argv, 0);
    return if (fiber.env) |env|
        wrap.fromTable(env)
    else
        wrap.fromNil();
}

fn cfunFiberSetenv(argv: []repr.Value) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 2);
    const fiber = try args_core.getFiber(argv, 0);
    if (repr.checkType(argv[1], repr.Tag.nil)) {
        fiber.env = null;
    } else {
        fiber.env = try args_core.getTable(argv, 1);
    }
    return argv[0];
}

/// Write a fiber's status into its flag word.
inline fn setStatus(fiber: *Fiber, to: FiberStatus) void {
    fiber.flags.status = @intCast(@intFromEnum(to));
}

/// The `n`th user signal, for the digits `0`-`9` in a fiber's flag string.
inline fn userSignal(n: u8) abi.Signal {
    return @enumFromInt(@intFromEnum(abi.Signal.user0) + @as(c_uint, n));
}

/// Union `more` into a fiber's trap set. The flag string names overlapping
/// groups, so every one of these is an addition rather than an assignment.
inline fn addTraps(fiber: *Fiber, more: u14) void {
    fiber.flags.traps = signal.SignalSet.fromBits(fiber.flags.traps.bits() | more);
}

fn cfunFiberNew(argv: []repr.Value) raise.Raising(repr.Value) {
    try args_core.arity(argv, 1, 3);
    const func = try args_core.getFunction(argv, 0);
    if (func.def.?.min_arity > 1) {
        return pp_format.panicf("fiber function must accept 0 or 1 arguments", .{});
    }
    // `min_arity` is zero or one, checked above, and the slice is what says
    // how many nils get pushed.
    const seed = [_]repr.Value{wrap.fromNil()};
    const fiber = new(func, 64, seed[0..@intCast(func.def.?.min_arity)]) catch
        fatal.fatal("bad fiber arity check");

    if (argv.len == 3 and !repr.checkType(argv[2], repr.Tag.nil)) {
        fiber.env = try args_core.getTable(argv, 2);
    }

    if (argv.len >= 2) {
        const view = try args_core.getBytes(argv, 1);
        fiber.flags = .{ .resume_no_useval = true, .resume_no_skip = true };
        setStatus(fiber, FiberStatus.new);
        for (0..view.len) |i| {
            const ch = view.bytes.?[i];
            if (ch >= '0' and ch <= '9') {
                fiber.flags.traps = fiber.flags.traps.with(userSignal(ch - '0'));
                continue;
            }
            switch (ch) {
                'a' => addTraps(fiber, signal.SignalSet.of(&.{ .debug, .@"error", .yield }).bits() |
                    signal.SignalSet.user.bits()),
                't' => addTraps(fiber, signal.SignalSet.of(&.{ .@"error", .user0, .user1, .user2, .user3, .user4 }).bits()),
                'd' => addTraps(fiber, signal.SignalSet.of(&.{.debug}).bits()),
                'e' => addTraps(fiber, signal.SignalSet.of(&.{.@"error"}).bits()),
                'u' => addTraps(fiber, signal.SignalSet.user.bits()),
                'y' => addTraps(fiber, signal.SignalSet.of(&.{.yield}).bits()),
                'w' => addTraps(fiber, signal.SignalSet.of(&.{.user9}).bits()),
                'r' => addTraps(fiber, signal.SignalSet.of(&.{.user8}).bits()),
                'i' => {
                    if (vm_state.current().fiber.?.env == null) vm_state.current().fiber.?.env = tables.new(0);
                    fiber.env = vm_state.current().fiber.?.env;
                },
                'p' => {
                    if (vm_state.current().fiber.?.env == null) vm_state.current().fiber.?.env = tables.new(0);
                    fiber.env = tables.new(0);
                    fiber.env.?.proto = vm_state.current().fiber.?.env;
                },
                // The raise is the whole arm: there is no fallthrough past a
                // `pp_format.panicf`.
                else => return pp_format.panicf(
                    "invalid flag %c, expected a, t, d, e, u, y, w, r, i, or p",
                    .{@as(c_int, ch)},
                ),
            }
        }
    }

    return wrap.fromFiber(fiber);
}

fn cfunFiberStatus(argv: []repr.Value) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    const fiber = try args_core.getFiber(argv, 0);
    return value.fromBytes(std.mem.span(utils.statusNames[@intFromEnum(statusOf(fiber))]), .keyword);
}

fn cfunFiberCurrent(argv: []repr.Value) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 0);
    return wrap.fromFiber(vm_state.current().fiber.?);
}

fn cfunFiberRoot(argv: []repr.Value) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 0);
    return wrap.fromFiber(vm_state.current().root_fiber.?);
}

fn cfunFiberMaxstack(argv: []repr.Value) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    const fiber = try args_core.getFiber(argv, 0);
    return wrap.fromNumber(@floatFromInt(fiber.maxstack));
}

fn cfunFiberSetmaxstack(argv: []repr.Value) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 2);
    const fiber = try args_core.getFiber(argv, 0);
    const maxs = try args_core.getInteger(argv, 1);
    if (maxs < 0) return raise.panic("expected positive integer");
    fiber.maxstack = maxs;
    return argv[0];
}

fn cfunFiberCanResume(argv: []repr.Value) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    const fiber = try args_core.getFiber(argv, 0);
    return wrap.fromBoolean(canResume(fiber));
}

fn cfunFiberLastValue(argv: []repr.Value) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    const fiber = try args_core.getFiber(argv, 0);
    return fiber.last_value;
}

pub fn lib(env: *tables.Table) raise.Raising(void) {
    const entries = comptime [_]corefn.Entry{
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
    };
    corefn.install(env, entries);
}

/// **`extern` for the field order, not for an ABI.** The collector writes a
/// block's memory type through a `*GCObject` at the *start* of the
/// allocation and the sweep frees the block at that same address, so `gc` has
/// to be the first field -- `gc.zig`'s `assertHeaderFirst` is what says so. On
/// a 32-bit target Zig's automatic layout puts `last_value` first, because a
/// `Value` is eight-byte aligned there and the header is not, and the header
/// lands at offset 8. `extern` fixes the declaration order and the assertion
/// then holds on every target rather than on the ones that happen to agree.
/// The event loop adds the last five fields, and they matter only for a fiber
/// it has scheduled as a root fiber.
pub const Fiber = if (config.ev) extern struct {
    gc: abi.GCObject = .{},
    flags: FiberFlags = .{},
    frame: i32 = 0,
    stackstart: i32 = 0,
    stacktop: i32 = 0,
    capacity: i32 = 0,
    maxstack: i32 = 0,
    env: ?*tables.Table = null,
    data: ?[*]repr.Value = null,
    child: ?*Fiber = null,
    last_value: repr.Value = std.mem.zeroes(repr.Value),
    sched_id: u32 = 0,
    ev_callback: ev_loop.EVCallback = null,
    ev_stream: ?*ev_stream.Stream = null,
    ev_state: ?*anyopaque = null,
    supervisor_channel: ?*anyopaque = null,
} else extern struct {
    gc: abi.GCObject = .{},
    flags: FiberFlags = .{},
    frame: i32 = 0,
    stackstart: i32 = 0,
    stacktop: i32 = 0,
    capacity: i32 = 0,
    maxstack: i32 = 0,
    env: ?*tables.Table = null,
    data: ?[*]repr.Value = null,
    child: ?*Fiber = null,
    last_value: repr.Value = std.mem.zeroes(repr.Value),
};
/// A fiber's flag word.
///
/// **It is marshalled**, so the layout is the format, and two more bits live in
/// it on the wire only: `marsh.zig` sets bits 29 and 30 to say the fiber has a
/// child and an environment. They are in `_wire` here, always zero in memory,
/// and `marsh.zig` is where they are put in and taken out.
///
/// `status` is six bits for a sixteen-value vocabulary, which is why it is a
/// number here and `fibers.statusOf` is what reads it as `FiberStatus`.
pub const FiberFlags = packed struct(u32) {
    /// The signals this fiber traps instead of propagating.
    traps: signal.SignalSet = .{},
    _reserved14: u2 = 0,
    /// The six status bits: `constants.JANET_FIBER_STATUS_MASK`, at
    /// `constants.JANET_FIBER_STATUS_OFFSET`.
    status: u6 = 0,
    resume_signal: bool = false,
    _reserved23: u1 = 0,
    breakpoint: bool = false,
    resume_no_useval: bool = false,
    resume_no_skip: bool = false,
    did_raise: bool = false,
    /// Bits 28-31. Bits 29 and 30 are `marsh.zig`'s wire-only overlay.
    _wire: u4 = 0,

    /// The event loop's in-flight bit, which is bit 0 -- **the bit a signal
    /// set spends on `ok`**. `ok` is not a signal a fiber traps, so the event
    /// loop uses that bit for its own purpose and the two alias deliberately.
    /// These two accessors are the only correct readers of it; reading it as a
    /// trap would be a category error, and naming it here is what stops one.
    pub inline fn evInFlight(self: FiberFlags) bool {
        return self.traps.ok;
    }

    pub inline fn setEvInFlight(self: *FiberFlags, in_flight: bool) void {
        self.traps.ok = in_flight;
    }

    /// The four resume-state bits, as one mask.
    ///
    /// Derived from the fields rather than written as a literal, so it cannot
    /// drift from them, and applied as one `and` rather than four stores --
    /// which is what the interpreter's entry path measured the difference on.
    const resume_state: u32 = @bitCast(FiberFlags{
        .breakpoint = true,
        .resume_no_useval = true,
        .resume_no_skip = true,
        .did_raise = true,
    });

    /// The same four bits with `resume_signal` beside them, which is the
    /// single mask `runVm` clears on entry.
    const resume_state_and_signal: u32 = resume_state | @as(u32, @bitCast(FiberFlags{ .resume_signal = true }));

    /// The flag word with the four resume-state bits cleared.
    pub inline fn withoutResumeState(self: FiberFlags) FiberFlags {
        return @bitCast(@as(u32, @bitCast(self)) & ~resume_state);
    }

    /// The flag word with those four and `resume_signal` cleared.
    pub inline fn withoutResumeStateAndSignal(self: FiberFlags) FiberFlags {
        return @bitCast(@as(u32, @bitCast(self)) & ~resume_state_and_signal);
    }
};
