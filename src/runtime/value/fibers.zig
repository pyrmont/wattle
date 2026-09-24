//! Fiber stack frames, funcframes, and function environments: the machinery a
//! call goes through on its way onto and off a fiber's value stack.
//!
//! `new` allocates a fiber and seeds it, `reset` does the same over a fiber
//! that already exists. `push`, `push2`, `push3`, `pushn` and `pushChunks` put
//! values on the stack; `funcframe`, `funcframeTail` and `cframe` push a call
//! frame over them and `popframe` takes one off. `status`, `finished` and
//! `canResume` read a fiber's state, and `current` and `root` name the two the
//! VM tracks.
//!
//! This file reaches the VM state by name and reads and writes `Fiber`,
//! `vm/state.zig`'s `StackFrame` and `functions.FuncEnv` directly. All three
//! are `pub`, so nothing private is being exposed to get here.
//!
//! Running out of memory is fatal by policy, so `fatal.outOfMemory` is called
//! directly rather than raised.
//!
//! ## The kernels raise by returning
//!
//! The five pushes raise by returning `raise.Error`, and their callers `try`
//! them. A frame push returns `error.Arity` for an invalid count or
//! `error.MapTail` for an invalid map tail. Each caller reports the refusal.
//!
//! The map packing and the varargs fill are here too, so that `funcframe`
//! and `funcframeTail` are whole instead of being a kernel in two halves with
//! a packing step between them. Neither raises, and neither can be raised
//! through: `maps.build` may run an abstract type's `hash` callback, and
//! `abi.zig` declares that callback `callconv(.c)`.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const args_core = @import("../args.zig");
const config = @import("config");
const constants = @import("constants");
const corefn = @import("../corefn.zig");
const ev_stream = @import("../ev/stream.zig");
const fatal = @import("../fatal.zig");
const functions = @import("functions.zig");
const gc_alloc = @import("../gc.zig");
const maps = @import("maps.zig");
const pp_format = @import("../pp/format.zig");
const raise = @import("../../api/raise.zig");
const repr = @import("repr");
const signal = @import("../signal.zig");
const tables = @import("tables.zig");
const vectors = @import("vectors.zig");
const utils = @import("../utils.zig");
const value = @import("../value.zig");
const vm_state = @import("../vm/state.zig");
const wrap = @import("helpers/wrap.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// Whether to move every fiber's stack on every frame push, so that a pointer
/// kept across one is a use-after-free the allocator can see.
/// `-Dfiber-stack-shuffle=true` turns it on; it is off by default because it
/// reallocates on every call.
const debug_build = config.debug;

/// A stack frame's size in `Value` slots, named locally so the arithmetic
/// below reads as arithmetic. `stackFrame` and `dataAt` are the only places
/// that do it.
const frame_size: i32 = constants.frame_size;

/// Whether this build has the event loop. `Fiber` has five extra fields where
/// it does, and `resetState` clears all five. The condition is comptime, so
/// the fields are named only in a build where they exist.
const has_ev = constants.vm_has_ev != 0;

// ==========================================================================
// Aliased types
// ==========================================================================

/// A fiber's status, stored in six bits of its flag word, which `statusOf`
/// reads and whose width the assertion block at the foot of the file checks.
///
/// It is declared in `abi.zig` because a module author reads one:
/// `module.pcall` gives back a fiber and `module.fiberStatus` reads this over
/// it, so both compilations have to agree on the numbering. Every operation
/// over a fiber is here, which is the split `Keyval`, `Method` and `ByteView`
/// already have. It is a vocabulary rather than a layout.
pub const FiberStatus = abi.FiberStatus;

// ==========================================================================
// Types
// ==========================================================================

/// Refusal from a frame push: an invalid argument count or map tail.
pub const ArityError = error{ Arity, MapTail };

pub const MapTailRefusal = union(enum) {
    missing_value: repr.Value,
    invalid_key: repr.Value,
};

/// The GC header's per-type field, as a fiber reads it.
///
/// `canceled`, `suspended` and `root` are the event loop's three bits, and the
/// same six bits are where `signal.signalInject` puts the signal it arms the
/// fiber to raise. Arming a signal clears all three. `abi.GCFlags` records
/// why that aliasing is kept.
pub const EvFlags = packed struct(u6) {
    canceled: bool = false,
    suspended: bool = false,
    root: bool = false,
    _rest: u3 = 0,
};

/// A fiber: its flag word, its stack geometry, its value stack, and the five
/// extra fields the event loop adds.
///
/// `extern` for the field order, not for an ABI. The collector writes a
/// block's memory type through a `*GCObject` at the start of the allocation
/// and the sweep frees the block at that same address, so `gc` has to be the
/// first field; `gc.zig`'s `assertHeaderFirst` is what says so. On a 32-bit
/// target Zig's automatic layout puts `last_value` first, because a `Value` is
/// eight-byte aligned there and the header is not, and the header lands at
/// offset 8. `extern` fixes the declaration order, and the assertion then
/// is true on every target rather than on the ones that happen to agree.
///
/// The last three fields matter only for a fiber the event loop has scheduled
/// as a root fiber. `ev_op` is the operation the fiber is waiting on, which
/// `ev/stream.zig` declares and a stream's own list owns.
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
    ev_op: ?*ev_stream.Operation = null,
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
/// It is marshalled, so the layout is the format, and two more bits live in it
/// on the wire only: `marsh.zig` sets bits 29 and 30 to say the fiber has a
/// child and an environment. They are in `_wire` here, always zero in memory,
/// and `marsh.zig` is where they are put in and taken out.
///
/// `status` is six bits for a sixteen-value vocabulary. It is a number here,
/// and `statusOf` reads it as a `FiberStatus`.
pub const FiberFlags = packed struct(u32) {
    /// The signals this fiber traps instead of propagating.
    traps: signal.SignalSet = .{},
    _reserved14: u2 = 0,
    /// The six status bits: `constants.fiber_status_mask`, at
    /// `constants.fiber_status_offset`.
    status: u6 = 0,
    resume_signal: bool = false,
    _reserved23: u1 = 0,
    breakpoint: bool = false,
    resume_no_useval: bool = false,
    resume_no_skip: bool = false,
    did_raise: bool = false,
    /// Bits 28-31. Bits 29 and 30 are `marsh.zig`'s wire-only overlay.
    _wire: u4 = 0,

    /// The four resume-state bits, as one mask.
    ///
    /// Derived from the fields rather than written as a literal, so it cannot
    /// drift from them, and applied as one `and` rather than four stores.
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

/// What pushing half a frame decided: the frame is pushed and a variadic tail
/// may still need packing, or a refusal left the fiber unchanged.
///
/// The two refusal tags leave the stack unchanged.
const FrameBegin = union(enum) {
    pushed: ?Varargs,
    arity_mismatch,
    map_tail_mismatch,
};

/// What `funcframeTailBegin` decided: the variadic tail to pack, if any, and
/// how many slots the finishing half has to move down.
const TailBegin = union(enum) {
    pushed: struct { tail: ?Varargs, stacksize: i32 },
    arity_mismatch,
    map_tail_mismatch,
};

/// A variadic tail waiting to be packed: the slot to pack it into, and how
/// many values to gather from there.
///
/// It travels out of the two `Begin` halves rather than being used inside them
/// because the tail-call path needs the packing to happen at a different point
/// in the sequence. See `funcframeTailBegin`.
const Varargs = struct { slot: i32, count: i32 };

// ==========================================================================
// Public functions
// ==========================================================================

/// Whether `fiber` can still be resumed, which is the negation of `finished`.
pub fn canResume(fiber: *Fiber) bool {
    return !finished(fiber);
}

/// Pushes a C frame for `nfun`.
pub fn cframe(fiber: *Fiber, nfun: abi.NFunction) void {
    const oldframe = fiber.frame;
    const nextframe = fiber.stackstart;
    const nextstacktop = fiber.stacktop +% frame_size;

    reserve(fiber, nextstacktop);

    fiber.frame = nextframe;
    fiber.stacktop = nextstacktop;
    fiber.stackstart = nextstacktop;
    const newframe = fiberFrame(fiber);

    newframe.prevframe = oldframe;
    // The nfunction goes in the frame's `pc` slot, and a frame with a null
    // `func` is what marks it a C frame.
    newframe.pc = .{ .nfunction = nfun };
    newframe.func = null;
    newframe.env = null;
    newframe.flags = .{};
}

/// The fiber the calling thread is running, or null.
pub fn current() ?*Fiber {
    return vm_state.current().fiber;
}

/// A fiber's event-loop bits, read out of the GC header's per-type field.
pub inline fn evFlags(fiber: *const Fiber) EvFlags {
    return @bitCast(fiber.gc.flags.own);
}

/// Whether `f` has run to a stop, which is true of seven of the sixteen
/// statuses.
///
/// `functions.envMaybeDetach` is its one caller, and asks it rather than
/// keeping the list itself. `vm/entry.zig`'s `checkCanResume` keeps a list of
/// its own, because it refuses `.alive` as well and this predicate does not.
pub fn finished(f: *Fiber) bool {
    return switch (statusOf(f)) {
        .dead, .@"error", .user0, .user1, .user2, .user3, .user4 => true,
        // Listed rather than `else`, so a status added later has to be
        // decided here instead of defaulting to "still running".
        .debug, .pending, .user5, .user6, .user7, .user8, .user9, .new, .alive => false,
    };
}

/// Pushes a call frame for `func`, packing its variadic tail where it has one.
///
/// Returns `error.Arity` or `error.MapTail` without changing the fiber.
pub fn funcframe(fiber: *Fiber, func: *functions.Function) ArityError!void {
    switch (funcframeBegin(fiber, func)) {
        .arity_mismatch => return error.Arity,
        .map_tail_mismatch => return error.MapTail,
        .pushed => |tail| if (tail) |t| fillVarargs(fiber, func, t.slot, t.count),
    }
}

/// Replaces the current frame with one for `func`, which is a tail call.
///
/// Split into three so that the tail's value exists before the arguments are
/// moved down over the outgoing frame: `funcframeTailBegin` does the arity
/// check, the capacity, the outgoing environment and the gap fill,
/// `fillVarargs` packs the tail, and `funcframeTailFinish` does the move.
///
/// Returns `error.Arity` or `error.MapTail` without changing the fiber.
pub fn funcframeTail(fiber: *Fiber, func: *functions.Function) ArityError!void {
    const begun = switch (funcframeTailBegin(fiber, func)) {
        .arity_mismatch => return error.Arity,
        .map_tail_mismatch => return error.MapTail,
        .pushed => |begun| begun,
    };
    if (begun.tail) |t| fillVarargs(fiber, func, t.slot, t.count);
    funcframeTailFinish(fiber, func, begun.stacksize);
}

/// Installs the `fiber/` nfunctions into `env`.
///
/// Ten bindings: nine of them two lines over a field of `Fiber` that the
/// kernels above already own, and `fiber/new`, the flag parser, which is the
/// only real code in the set. They are here rather than in a file of their own
/// because they are this subsystem's own surface.
///
/// Each returns `raise.Error!repr.Value` rather than recording its raise in a
/// VM field and returning an unspecified value, so a caller that forgets to
/// `try` is a compile error.
pub fn lib(env: *tables.Table) raise.Error!void {
    const entries = comptime [_]corefn.Entry{
        corefn.reg("fiber/new", &nfunFiberNew, @src(), "(fiber/new func &opt sigmask env)",
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
        corefn.reg("fiber/status", &nfunFiberStatus, @src(), "(fiber/status fib)",
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
        corefn.reg("fiber/root", &nfunFiberRoot, @src(), "(fiber/root)", "Returns the current root fiber. The root fiber is the oldest " ++
            "ancestor that does not have a parent. Note that a root fiber " ++
            "is also a task fiber."),
        corefn.reg("fiber/current", &nfunFiberCurrent, @src(), "(fiber/current)", "Returns the currently running fiber."),
        corefn.reg("fiber/maxstack", &nfunFiberMaxstack, @src(), "(fiber/maxstack fib)", "Gets the maximum stack size in Wattle values allowed for a fiber. While memory for " ++
            "the fiber's stack is not allocated up front, the fiber will not allocated more " ++
            "than this amount and will throw a stack-overflow error if more memory is needed. "),
        corefn.reg("fiber/setmaxstack", &nfunFiberSetmaxstack, @src(), "(fiber/setmaxstack fib maxstack)", "Sets the maximum stack size in Wattle values for a fiber. By default, the " ++
            "maximum stack size is usually 8192."),
        corefn.reg("fiber/getenv", &nfunFiberGetenv, @src(), "(fiber/getenv fiber)", "Gets the environment for a fiber. Returns nil if no such table is " ++
            "set yet."),
        corefn.reg("fiber/setenv", &nfunFiberSetenv, @src(), "(fiber/setenv fiber table)", "Sets the environment table for a fiber. Set to nil to remove the current " ++
            "environment."),
        corefn.reg("fiber/can-resume?", &nfunFiberCanResume, @src(), "(fiber/can-resume? fiber)", "Check if a fiber is finished and cannot be resumed."),
        corefn.reg("fiber/last-value", &nfunFiberLastValue, @src(), "(fiber/last-value fiber)", "Get the last value returned or signaled from the fiber."),
    };
    corefn.install(env, entries);
}

/// Allocates a fiber with `args` on its stack, ready to run `callee`.
///
/// `capacity` is the initial stack in slots, floored at 32.
pub fn new(
    callee: *functions.Function,
    capacity: i32,
    args: []const repr.Value,
) ArityError!*Fiber {
    return reset(alloc(capacity), callee, args);
}

/// Pops the innermost frame off `fiber`, detaching its environment.
pub fn popframe(fiber: *Fiber) void {
    const frame = fiberFrame(fiber);
    if (fiber.frame == 0) return;

    // Detach the frame's environments.
    if (frame.func != null) functions.envDetach(frame.env);

    // Shrink the stack.
    fiber.stacktop = fiber.frame;
    fiber.stackstart = fiber.frame;
    fiber.frame = frame.prevframe;
}

/// Pushes `x` onto `fiber`'s stack, growing it where there is no room.
///
/// The three fixed-arity pushes take their values rather than pointers to
/// them: `vm.zig`'s `runVm` passes a slot of the fiber stack, which is a value
/// it already has, and no caller has an address it would rather hand over.
/// `pushn` keeps its pointer, because a run of values is what it takes.
pub fn push(fiber: *Fiber, x: repr.Value) raise.Error!void {
    if (fiber.stacktop == std.math.maxInt(i32)) return raise.panic("stack overflow");
    if (fiber.stacktop >= fiber.capacity) grow(fiber, fiber.stacktop);
    dataAt(fiber, fiber.stacktop)[0] = x;
    fiber.stacktop += 1;
}

/// Pushes two values onto `fiber`'s stack. See `push`.
pub fn push2(fiber: *Fiber, x: repr.Value, y: repr.Value) raise.Error!void {
    if (fiber.stacktop >= std.math.maxInt(i32) - 1) return raise.panic("stack overflow");
    const newtop = fiber.stacktop + 2;
    if (newtop > fiber.capacity) grow(fiber, newtop);
    const slots = dataAt(fiber, fiber.stacktop);
    slots[0] = x;
    slots[1] = y;
    fiber.stacktop = newtop;
}

/// Pushes three values onto `fiber`'s stack. See `push`.
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

/// Pushes the elements of an indexed value onto `fiber`'s stack, one run at a
/// time. See `push`.
///
/// `it` is an iterator from `args_core.chunks` and is read to its end. This
/// function raises where `pushn` does, and where `args_core.Chunks.next` does.
///
/// The room for every element is reserved before the first run is taken,
/// because a run stays valid only until the next call that can allocate.
/// `stacktop` moves once, after the last run is copied: a raise part way
/// through leaves the slots already written above `stacktop`, where
/// `gc/mark.zig`'s `markFiber` does not look.
///
/// `pushn` re-derives its source after a growth because a caller may hand it a
/// slice of this stack. A run here comes from an array, a tuple, a vector's
/// node or an abstract's payload, and none of the four is this stack.
pub fn pushChunks(fiber: *Fiber, it: *args_core.Chunks) raise.Error!void {
    const n: i32 = @intCast(it.len);
    if (fiber.stacktop > std.math.maxInt(i32) -% n) return raise.panic("stack overflow");
    const newtop = fiber.stacktop +% n;
    if (newtop > fiber.capacity) grow(fiber, newtop);
    var at = fiber.stacktop;
    while (try it.next()) |run| {
        @memcpy(dataAt(fiber, at)[0..run.len], run);
        at +%= @intCast(run.len);
    }
    fiber.stacktop = newtop;
}

/// Pushes a run of values onto `fiber`'s stack. See `push`.
pub fn pushn(
    fiber: *Fiber,
    arr: []const repr.Value,
) raise.Error!void {
    const n: i32 = @intCast(arr.len);
    if (fiber.stacktop > std.math.maxInt(i32) -% n) return raise.panic("stack overflow");
    const newtop = fiber.stacktop +% n;
    var src = arr;
    if (newtop > fiber.capacity) {
        // The source may be a slice of this same stack, and growing frees it.
        // `grow` reaches `setcapacity`, which reallocates, so a caller pushing
        // a run that lives on this fiber would have the copy below read the
        // block that was just released. A native module forwarding its own
        // `argv` through `vm/entry.zig`'s `callValue` is the short way to
        // reach that. The offset is re-derived from the new block, so the
        // slice names the same elements after the move.
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

/// Recycles `fiber` as a new fiber with `args` on the stack, running `callee`.
///
/// Returns `error.Arity` where the callee's arity rejects the argument count.
/// The failure is a return value rather than a panic because `vm/entry.zig`'s
/// `pcall` turns it into a `Resumed` of its own. Everything
/// before the funcframe has already been written by then, so the rejected
/// fiber is reset but frameless.
///
/// `args` is a slice, so no arguments is an empty slice rather than a null
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
        // does for the other route into `setcapacity`. Unbounded they wrap
        // negative, and `setcapacity` turns a negative count into an enormous
        // byte request and a fatal out-of-memory, which is the right refusal
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

/// The fiber at the root of the calling thread's chain, or null.
pub fn root() ?*Fiber {
    return vm_state.current().root_fiber;
}

/// Reallocates `fiber`'s stack to `n` slots and adjusts the collector's
/// budget.
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

/// `n` stack slots as a byte count.
///
/// A negative count is allowed here. `2 * nextstacktop` can produce a negative
/// count on a very large stack, and widening it makes an enormous size the
/// allocation refuses.
/// The result is a fatal out-of-memory either way, so it is left as it is
/// rather than turned into a different diagnostic.
pub inline fn stackBytes(n: i32) usize {
    return @bitCast(@as(isize, n) *% @as(isize, @sizeOf(repr.Value)));
}

/// A frame lives in the four `Value` slots immediately below the frame's stack
/// base, and this is that frame.
pub inline fn stackFrame(values: [*]repr.Value) *vm_state.StackFrame {
    return @ptrCast(@alignCast(values - frame_size));
}

/// `f`'s status.
pub fn status(f: *Fiber) FiberStatus {
    return statusOf(f);
}

/// The status of the fiber a `Value` names, refusing anything that is not a
/// fiber.
///
/// This is the module boundary's form, in the shape `arrays.pushChecked` set:
/// `*Fiber` stays off the author surface, so a module names a fiber the only
/// way it can and the tag test is on this side. The refusal names the type and
/// the value and no argument slot, because there is no slot: the fiber came
/// back from `pcall` rather than out of `argv`.
pub fn statusChecked(v: repr.Value) raise.Error!FiberStatus {
    if (!repr.checkType(v, repr.Tag.fiber)) {
        return pp_format.panicf("expected %T, got %v", .{ repr.TagSet.one(repr.Tag.fiber), v });
    }
    return statusOf(wrap.toFiber(v));
}

// ==========================================================================
// Private functions
// ==========================================================================

/// Unions `more` into `fiber`'s trap set. The flag string names overlapping
/// groups, so each of these is an addition rather than an assignment.
inline fn addTraps(fiber: *Fiber, more: u14) void {
    fiber.flags.traps = signal.SignalSet.fromBits(fiber.flags.traps.bits() | more);
}

/// Allocates a fiber and its value stack.
///
/// The block is collectable and on `vm.gc.blocks` before this returns. The
/// stack is a plain allocation the collector reaches only through
/// `gc/sweep.zig`'s `deinitBlock`, so the byte charge is made here by hand.
///
/// This charge and `setcapacity`'s have to agree: a fiber is charged once for
/// its initial capacity and once per resize, never twice and never zero times.
/// `test/value_alloc.zig` checks this charge against the same arithmetic
/// `test/fiber_core.zig` checks `setcapacity`'s against, and that pairing is
/// what says the two stay in step.
///
/// The 32-slot floor is applied before the capacity is written, so a caller
/// asking for zero gets a fiber whose `capacity` reads 32 and whose charge is
/// 32 slots. A negative request lands on the same floor rather than wrapping
/// into an enormous allocation, which is what makes the `@intCast` safe.
///
/// The fiber comes back with `capacity` and `data` set and nothing else
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

/// `fiber/can-resume?`: whether a fiber can still be resumed.
fn nfunFiberCanResume(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const fiber = try args_core.getFiber(argv, 0);
    return wrap.fromBoolean(canResume(fiber));
}

/// `fiber/current`: the running fiber.
fn nfunFiberCurrent(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 0);
    return wrap.fromFiber(vm_state.current().fiber.?);
}

/// `fiber/getenv`: a fiber's environment table, or nil.
fn nfunFiberGetenv(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const fiber = try args_core.getFiber(argv, 0);
    return if (fiber.env) |env|
        wrap.fromTable(env)
    else
        wrap.fromNil();
}

/// `fiber/last-value`: the last value the fiber returned or signalled.
fn nfunFiberLastValue(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const fiber = try args_core.getFiber(argv, 0);
    return fiber.last_value;
}

/// `fiber/maxstack`: a fiber's stack ceiling in slots.
fn nfunFiberMaxstack(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const fiber = try args_core.getFiber(argv, 0);
    return wrap.fromNumber(@floatFromInt(fiber.maxstack));
}

/// `fiber/new`: a fiber over a function, with an optional signal mask and
/// environment.
///
/// The mask string is parsed here, a character at a time. `i` and `p` are
/// environment flags rather than signals, and a later one overrides an earlier
/// one, which is what the docstring means by mutually exclusive.
fn nfunFiberNew(argv: []repr.Value) raise.Error!repr.Value {
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

/// `fiber/root`: the root fiber of the current chain.
fn nfunFiberRoot(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 0);
    return wrap.fromFiber(vm_state.current().root_fiber.?);
}

/// `fiber/setenv`: a fiber's environment table replaced, or cleared by nil.
fn nfunFiberSetenv(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 2);
    const fiber = try args_core.getFiber(argv, 0);
    if (repr.checkType(argv[1], repr.Tag.nil)) {
        fiber.env = null;
    } else {
        fiber.env = try args_core.getTable(argv, 1);
    }
    return argv[0];
}

/// `fiber/setmaxstack`: a fiber's stack ceiling in slots, set.
fn nfunFiberSetmaxstack(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 2);
    const fiber = try args_core.getFiber(argv, 0);
    const maxs = try args_core.getInteger(argv, 1);
    if (maxs < 0) return raise.panic("expected positive integer");
    fiber.maxstack = maxs;
    return argv[0];
}

/// `fiber/status`: a fiber's status as a keyword.
fn nfunFiberStatus(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const fiber = try args_core.getFiber(argv, 0);
    return value.fromBytes(std.mem.span(utils.statusNames[@intFromEnum(statusOf(fiber))]), .keyword);
}

/// The slot at `index` in `fiber`'s stack.
inline fn dataAt(fiber: *Fiber, index: i32) [*]repr.Value {
    return fiber.data.? + @as(usize, @bitCast(@as(isize, index)));
}

/// The frame `fiber` is currently in.
inline fn fiberFrame(fiber: *Fiber) *vm_state.StackFrame {
    return stackFrame(dataAt(fiber, fiber.frame));
}

/// Fills `fiber`'s slots from `from` up to `to` with nil, which the collector
/// needs before it can walk them.
inline fn fillNil(fiber: *Fiber, from: i32, to: i32) void {
    var i = from;
    while (i < to) : (i += 1) {
        dataAt(fiber, i)[0] = wrap.fromNil();
    }
}

/// Builds the variadic tail the frame setup located and stores it in its slot.
///
/// A count of zero is an empty tail rather than an empty range, so the source
/// slice is empty there.
fn fillVarargs(fiber: *Fiber, func: *functions.Function, slot: i32, count: i32) void {
    const maparg = func.def.?.flags.maparg;
    // The empty tail is an empty slice rather than a null pointer with a zero
    // count. `values.?[0..count]` here traps on the first varargs call with no
    // arguments: a `.?` is a claim about length, demonstrated.
    const values: []repr.Value = if (count != 0)
        dataAt(fiber, slot)[0..@intCast(count)]
    else
        &.{};
    // `& rest` binds a vector, as the destructuring `& rest` does: what it
    // collects is data, and the vector is Wattle's immutable sequence.
    dataAt(fiber, slot)[0] = if (maparg)
        makeMapN(values)
    else
        wrap.fromVector(vectors.fromSlice(values));
}

/// Returns the first invalid map-tail argument, or null when the tail is valid.
pub fn mapTailRefusal(args: []const repr.Value) ?MapTailRefusal {
    const trailing_map = args.len % 2 == 1 and repr.checkType(args[args.len - 1], repr.Tag.map);
    const pairs = args[0 .. args.len - @intFromBool(trailing_map)];
    var i: usize = 0;
    while (i + 1 < pairs.len) : (i += 2) {
        if (!maps.storableKey(pairs[i])) return .{ .invalid_key = pairs[i] };
    }
    if (pairs.len % 2 != 0) return .{ .missing_value = pairs[pairs.len - 1] };
    return null;
}

/// Returns the refusal for a map tail in `fiber`'s pending call to `func`.
pub fn pendingMapTailRefusal(fiber: *Fiber, func: *functions.Function) ?MapTailRefusal {
    const start = fiber.stackstart + func.def.?.arity;
    if (start >= fiber.stacktop) return null;
    return mapTailRefusal(dataAt(fiber, start)[0..@intCast(fiber.stacktop - start)]);
}

/// Everything a frame push does up to the point where a variadic tail's value
/// is needed.
///
/// Split from `fillVarargs` rather than folded into it because the tail-call
/// path needs the two halves in a different order: the tail's value has to
/// exist before the arguments are moved down over the outgoing frame.
fn funcframeBegin(fiber: *Fiber, func: *functions.Function) FrameBegin {
    const def = func.def.?;
    const oldtop = fiber.stacktop;
    const oldframe = fiber.frame;
    const nextframe = fiber.stackstart;
    const nextstacktop = nextframe +% def.slotcount +% frame_size;
    const next_arity = fiber.stacktop -% fiber.stackstart;

    // Check strict arity before touching any state.
    if (next_arity < def.min_arity) return .arity_mismatch;
    if (next_arity > def.max_arity) return .arity_mismatch;
    if (def.flags.maparg and pendingMapTailRefusal(fiber, func) != null) return .map_tail_mismatch;

    reserve(fiber, nextstacktop);

    // Nil the unset stack arguments, which the collector needs.
    fillNil(fiber, fiber.stacktop, nextstacktop);

    // Set up the next frame
    fiber.frame = nextframe;
    fiber.stacktop = nextstacktop;
    fiber.stackstart = nextstacktop;
    const newframe = fiberFrame(fiber);
    newframe.prevframe = oldframe;
    newframe.pc = .{ .bytecode = def.bytecode };
    newframe.func = func;
    newframe.env = null;
    newframe.flags = .{ .argc = saturatedArgc(next_arity) };

    // Locate the variadic tail, where there is one.
    if (!def.flags.vararg) return .{ .pushed = null };
    const tuplehead = fiber.frame +% def.arity;
    return .{ .pushed = .{
        .slot = tuplehead,
        .count = if (tuplehead >= oldtop) 0 else oldtop -% tuplehead,
    } };
}

/// An argument count as `FrameFlags.argc` holds it.
inline fn saturatedArgc(argc: i32) u16 {
    return @intCast(@min(argc, std.math.maxInt(u16)));
}

/// The first half of a tail call: arity, capacity, detaching the outgoing
/// frame's environment, and the gap fill an empty tail requires.
///
/// The `stacksize` it reports is how many slots `funcframeTailFinish` has to
/// move down.
fn funcframeTailBegin(fiber: *Fiber, func: *functions.Function) TailBegin {
    const def = func.def.?;
    const nextstacktop = fiber.frame +% def.slotcount +% frame_size;
    const next_arity = fiber.stacktop -% fiber.stackstart;

    // Check strict arity before touching any state.
    if (next_arity < def.min_arity) return .arity_mismatch;
    if (next_arity > def.max_arity) return .arity_mismatch;
    if (def.flags.maparg and pendingMapTailRefusal(fiber, func) != null) return .map_tail_mismatch;

    reserve(fiber, nextstacktop);

    // Detach the outgoing function's environment.
    const frame = fiberFrame(fiber);
    if (frame.func != null) functions.envDetach(frame.env);
    frame.env = null;
    frame.flags.argc = saturatedArgc(next_arity);

    // Locate the variadic tail, where there is one.
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

/// The second half of a tail call: move the arguments down over the outgoing
/// frame's slots, nil the rest, and repoint the frame at `func`.
///
/// Runs after the caller has stored the variadic tail, because the move copies
/// that slot too.
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

    // Nil the unset locals, which the callee reads as nil.
    fillNil(fiber, fiber.frame +% stacksize, nextframetop);

    // Set the stack geometry.
    fiber.stacktop = nextstacktop;
    fiber.stackstart = nextstacktop;

    // Point the frame at the new function.
    const frame = fiberFrame(fiber);
    frame.func = func;
    frame.pc = .{ .bytecode = def.bytecode };
    frame.flags.tailcall = true;
}

/// Doubles `fiber`'s stack to fit `needed` slots, clamping at `maxInt(i32)`.
fn grow(fiber: *Fiber, needed: i32) void {
    const cap: i32 = if (needed > @divTrunc(std.math.maxInt(i32), 2))
        std.math.maxInt(i32)
    else
        2 *% needed;
    setcapacity(fiber, cap);
}

/// Builds a map from the pairs in `args` and an optional trailing map.
///
/// `mapTailRefusal` must have accepted `args` before this call.
/// It is here because `funcframe` is. `maps.build` hashes the caller's keys,
/// so an abstract type's `hash` callback runs underneath it; `abi.zig`
/// declares that callback `callconv(.c)`, so it has no way to raise, and this
/// frame keeps nothing across it either way.
///
fn makeMapN(args: []repr.Value) repr.Value {
    const trailing_map = args.len % 2 == 1;
    if (trailing_map and args.len == 1) return args[0];
    const pairs = args[0 .. args.len - @intFromBool(trailing_map)];
    var result = maps.build(.map, pairs);
    if (trailing_map) {
        const extra = maps.toTree(args[args.len - 1], .map).?;
        var key = wrap.fromNil();
        while (true) {
            key = maps.nextKey(extra, key);
            if (repr.checkType(key, repr.Tag.nil)) break;
            result = maps.put(result, .map, &.{ key, maps.lookup(extra, key) });
        }
    }
    return wrap.fromMap(result);
}

/// Copies `fiber`'s stack into a fresh allocation and frees the old block, so
/// that a stale pointer into it becomes a use-after-free the allocator can
/// see. Reached only where `debug_build` is true.
fn refreshMemory(fiber: *Fiber) void {
    const n = fiber.capacity;
    if (n != 0) {
        const dest = utils.allocMany(repr.Value, @intCast(n));
        @memcpy(dest[0..@intCast(n)], fiber.data.?[0..@intCast(n)]);
        utils.free(fiber.data);
        fiber.data = dest;
    }
}

/// The shape shared by every frame push: grow where the frame will not fit,
/// and otherwise shuffle the allocation in a debug build.
inline fn reserve(fiber: *Fiber, nextstacktop: i32) void {
    if (fiber.capacity < nextstacktop) {
        setcapacity(fiber, 2 *% nextstacktop);
    } else if (debug_build) {
        refreshMemory(fiber);
    }
}

/// Returns `fiber` to its newborn state: no frames, no child, no environment,
/// the default signal mask, and status `.new`.
///
/// Called on a block `alloc` has just produced and on a block `reset` is
/// recycling, so it clears rather than assumes.
///
/// `capacity` and `data` are deliberately untouched. A recycled fiber keeps
/// the stack it already paid for.
///
/// It resets the state rather than the fiber: `reset` is the entry point that
/// takes only a fiber, and this is the half of it that does not touch the
/// stack.
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
        fiber.ev_op = null;
        fiber.supervisor_channel = null;
    }
    setStatus(fiber, FiberStatus.new);
}

/// Writes a fiber's status into its flag word.
inline fn setStatus(fiber: *Fiber, to: FiberStatus) void {
    fiber.flags.status = @intCast(@intFromEnum(to));
}

/// Where `arr` starts within `fiber`'s stack, or null where it is elsewhere.
///
/// An empty slice gives null: it has no pointer worth re-deriving, and `pushn`
/// copies nothing from it.
fn stackOffset(fiber: *const Fiber, arr: []const repr.Value) ?usize {
    const data = fiber.data orelse return null;
    if (arr.len == 0) return null;
    const base = @intFromPtr(data);
    const start = @intFromPtr(arr.ptr);
    if (start < base or start >= base + stackBytes(fiber.capacity)) return null;
    return (start - base) / @sizeOf(repr.Value);
}

/// The six bits `constants.fiber_status_mask` covers, read as the
/// vocabulary they stand for.
///
/// The field is wider than the vocabulary, six bits for sixteen values, and
/// the assertion block at the foot of the file is what says so. Every writer
/// is in this tree, and `marsh.zig` validates the one value that arrives from
/// outside it.
inline fn statusOf(f: *Fiber) FiberStatus {
    return @enumFromInt(f.flags.status);
}

/// The `n`th user signal, for the digits `0` through `9` in a fiber's flag
/// string.
inline fn userSignal(n: u8) abi.Signal {
    return @enumFromInt(@intFromEnum(abi.Signal.user0) + @as(c_uint, n));
}

// ==========================================================================
// Tests
// ==========================================================================

// `FiberStatus` against the field it is stored in: every value has to fit in
// `FiberFlags.status`.
comptime {
    // The stored width, which is the fiber flag word's and not the enum's.
    const stored = std.math.maxInt(@FieldType(FiberFlags, "status"));
    for (@typeInfo(FiberStatus).@"enum".fields) |f| {
        std.debug.assert(f.value <= stored);
    }
}
