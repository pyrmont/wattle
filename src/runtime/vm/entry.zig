//! The entry points: everything that stands above `vm.zig`'s `runVm` and
//! decides whether, and in what state, the loop is entered at all.
//!
//! `call` and `callValue` enter the loop from a host frame, `pcall` runs a
//! function on a fresh or recycled fiber, `continueFiber` and
//! `continueSignal` resume an existing one, `step` runs a single instruction
//! for the debugger, and `checkCanResume` is the refusal all of the resumes
//! share. `continueNoCheck` is the protected scope every resume opens.
//!
//! ## Why this is separate from the loop
//!
//! A subsystem the interpreter touches on every instruction is imported rather
//! than reached through an entry point. None of these is on that path. `call`
//! runs once per host-to-Janet call, against a `fibers.pushn`, a
//! `fibers.funcframe` and the whole of the loop; `step` runs once per debugger
//! step.
//!
//! ## Raising
//!
//! Three raise and five return a `Resumed`. The three are `step`, for a fiber
//! whose status forbids stepping; `call`, which raises on three arity
//! mismatches, two entry conditions, and any signal the loop hands back, that
//! last being the coercion `signal.signalPlan` is written to match; and
//! `callValue`, which reaches `call` for the function case and `runVm`'s
//! method dispatch otherwise.
//!
//! ## One trace line
//!
//! `call`'s trace goes through a variadic `(dyn :err)` write. Zig can call a C
//! variadic but cannot define one, and `dynprintf` calls a `:err` handler
//! through the interpreter, which can grow the fiber's stack. `call` is not
//! exposed to that, because the argv it traces belongs to its caller rather
//! than to the fiber; the interpreter's own trace reloads its frame pointer
//! after the trace for the same reason.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const config = @import("config");
const constants = @import("constants");
const ev = @import("../ev.zig");
const fibers = @import("../value/fibers.zig");
const functions = @import("../value/functions.zig");
const gc_alloc = @import("../gc.zig");
const pp_format = @import("../pp/format.zig");
const raise = @import("../../api/raise.zig");
const repr = @import("repr");
const signal_core = @import("../signal.zig");
const tuples = @import("../value/tuples.zig");
const utils = @import("../utils.zig");
const value = @import("../value.zig");
const vm_run = @import("../vm.zig");
const vm_state = @import("state.zig");
const wrap = @import("../value/helpers/wrap.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// A stack frame's size in `Value` slots.
const frame_size: i32 = constants.JANET_FRAME_SIZE;

/// Whether this build has the event loop. Two regions below are the loop's:
/// the `sched_id` bump on a coerced `Signal.event`, and the wording of the
/// root-fiber refusal, which names `ev/cancel` and `ev/go` only where those
/// exist.
const has_ev = constants.JANET_VM_HAS_EV != 0;

// ==========================================================================
// Types
// ==========================================================================

/// What a resume returns: the signal it ended on and the value that goes with
/// it.
///
/// The two are always produced together, so this is one type rather than a
/// signal beside an `out: *repr.Value`. Every path through the resume family
/// sets both: a refusal sets the message, an ordinary return sets the returned
/// value, and a raise sets the payload.
pub const Resumed = struct {
    signal: abi.Signal,
    value: repr.Value,

    /// A refusal with a fixed message. The three in `checkCanResume` and
    /// `pcall`'s arity rejection are all this shape.
    fn fail(message: []const u8) Resumed {
        return .{ .signal = abi.Signal.@"error", .value = value.fromBytes(message, .string) };
    }
};

// ==========================================================================
// Public functions
// ==========================================================================

/// Calls a Janet function from a host frame, on the current fiber, raising
/// rather than reporting if anything goes wrong.
///
/// `fun` is the callee and `argv` the arguments, which are copied onto the
/// fiber's stack.
///
/// The VM is captured once and its `fiber` field is read again at every use.
/// Those are two decisions, and they point opposite ways.
///
/// The VM's address is fixed for the life of the thread, so `vm_state.pinned()`
/// takes it once at the top. On Darwin every thread-local access is a
/// `_tlv_get_addr` call, and holding the pointer is what keeps this function
/// from paying one per use; `pinned()`'s own comment has the mechanism.
///
/// The `fiber` field is not fixed. The last two uses are after `vm.zig`'s
/// `runVm` has returned, and the loop can re-enter fibers underneath it, so
/// each use reads the field again through `vm_state.fiberOf` rather than
/// binding it once. The entry check below is what earns that accessor's
/// invariant here: it refuses a null fiber, and nothing between it and the
/// return can put the field back to null, `signal.restore` writing back the
/// fiber it saved on the way in.
pub fn call(fun: *functions.Function, argv: []const repr.Value) raise.Error!repr.Value {
    const v = vm_state.pinned();

    // Check entry conditions.
    if (v.fiber == null) {
        return raise.panic("janet_call failed because there is no current fiber");
    }
    if (v.stackn >= config.recursion_guard) {
        return raise.panic("C stack recursed too deeply");
    }

    // Dirty stack.
    const dirty_stack: i32 = vm_state.fiberOf(v).stacktop - vm_state.fiberOf(v).stackstart;
    if (dirty_stack != 0) {
        fibers.cframe(vm_state.fiberOf(v), raise.stored(&voidCFunction));
    }

    // Tracing.
    if (functions.isTraced(fun)) {
        v.stackn += 1;
        try vm_run.traceArgv(fun, argv);
        v.stackn -= 1;
    }

    // Push frame.
    try fibers.pushn(vm_state.fiberOf(v), argv);
    fibers.funcframe(vm_state.fiberOf(v), fun) catch return arityMismatch(fun, argv.len);
    fiberFrame(vm_state.fiberOf(v)).flags.entrance = true;

    // Set up.
    const oldn = v.stackn;
    v.stackn += 1;
    const handle = gc_alloc.gclock();

    // Run vm.
    vm_state.fiberOf(v).flags.resume_no_useval = true;
    vm_state.fiberOf(v).flags.resume_no_skip = true;
    const old_coerce_error = v.coerce_error;
    v.coerce_error = true;
    const signal = try vm_run.runVm(vm_state.fiberOf(v), wrap.fromNil());
    v.coerce_error = old_coerce_error;

    // Teardown.
    v.stackn = oldn;
    gc_alloc.gcunlock(handle);
    if (dirty_stack != 0) {
        fibers.popframe(vm_state.fiberOf(v));
        vm_state.fiberOf(v).stacktop += dirty_stack;
    }

    if (signal != abi.Signal.ok) {
        // Should match the logic in `signal.signalRecord`.
        if (has_ev) {
            if (v.root_fiber) |root| {
                if (signal == abi.Signal.event) root.sched_id +%= 1;
            }
        }
        if (signal != abi.Signal.@"error") {
            v.return_reg.?.* = wrap.fromString(try pp_format.formatc("%v coerced from %s to error", .{ v.return_reg.?.*, utils.signalNames[@intFromEnum(signal)] }));
        }
        return raise.panicv(v.return_reg.?.*);
    }

    return v.return_reg.?.*;
}

/// Calls any value `(f ...)` calls, from a host frame, raising as `call` does.
///
/// `callee` is the value and `argv` the arguments. `call` is narrower: it
/// takes a `*functions.Function`, which is the callee the interpreter's own
/// host-to-Janet path has already resolved. Janet's call is wider, `vm.zig`'s
/// `.call` and `.tailcall` arms dispatching a function and a cfunction
/// themselves and handing everything else to `callNonfn`, which is
/// `methodInvoke`: an abstract with a `call` slot, and the six indexable
/// types, which index their one argument rather than call it. This is that
/// whole vocabulary reached from a host frame, so that a module author's
/// `call` is Janet's call. `capi.zig` is its only caller.
///
/// The arguments are copied onto the current fiber's stack, under a `cframe`
/// of their own, which is the technique `vm.zig`'s own arms use and not a
/// third one. Three things make it necessary, and each is a property of the
/// callee or of the collector rather than of this function:
///
/// - a cfunction may write to its `argv`, `ev/channel.zig`'s `fisherYatesArgs`
///   shuffling it in place to make `ev/rselect` fair, so a `[]const` slice
///   cannot be handed through;
/// - `gc/mark.zig`'s `markFiber` traces `[stackstart, stacktop)` and each
///   frame's locals, and nothing above the top frame, so a callee that
///   re-enters the interpreter and reaches a safe point would not otherwise
///   see these values at all;
/// - the frame is what keeps them there. `cframe` puts its struct above the
///   arguments and leaves them as the frame's locals, so a nested `call`
///   underneath pushes above them instead of over them.
///
/// The function arm returns before any of that, because `call` does all three
/// for itself: it pushes with `fibers.pushn` and covers a dirty stack with a
/// guard frame of its own.
///
/// `argv` may be the caller's own, which is the ordinary case and is a slice
/// of this same stack. `fibers.pushn` handles that where the hazard is, in the
/// branch that grows and therefore reallocates; nothing is needed here.
pub fn callValue(callee: repr.Value, argv: []const repr.Value) raise.Error!repr.Value {
    if (vm_state.current().fiber == null) {
        return raise.panic("janet_call failed because there is no current fiber");
    }
    const fiber = vm_state.currentFiber();
    // The stack is clean here, and this is where that is checked rather than
    // assumed. Every route to this function runs under a frame that left it
    // so: `vm.zig`'s `.call` arm installs a `cframe` before invoking a
    // cfunction, and `callNonfn` resets `stacktop` to `stackstart` before
    // reaching `methodInvoke`. A dirty entry would put `cframe`'s `nextframe`
    // below the arguments pushed below, so the frame would name the wrong
    // values, and `call`'s guard frame reserves, which relocates the stack in
    // a `-Dfiber-stack-shuffle` build and would strand an aliasing `argv`.
    // Neither is reachable, and an assertion is what says so in every debug
    // build the matrix runs rather than in a sentence.
    std.debug.assert(fiber.stacktop == fiber.stackstart);
    if (repr.checkType(callee, repr.Tag.function)) {
        return call(wrap.toFunction(callee), argv);
    }
    try fibers.pushn(fiber, argv);
    // The real cfunction where there is one, so a trace through a module's
    // `call` names what a trace through `(f ...)` names; the placeholder
    // otherwise, exactly as `call`'s guard frame uses it.
    fibers.cframe(fiber, if (repr.checkType(callee, repr.Tag.cfunction))
        wrap.toCfunction(callee)
    else
        raise.stored(&voidCFunction));
    // Read after `cframe`, which reserves and may therefore move the stack.
    const pushed = (fiber.data.? + utils.asSize(fiber.frame))[0..argv.len];
    const answer = try vm_run.methodInvoke(callee, pushed);
    // `popframe` restores all three indices, so nothing else is saved here. A
    // raise leaves the frame standing, which is what `vm.zig`'s own cfunction
    // arm leaves too.
    fibers.popframe(fiber);
    return answer;
}

/// Whether `fiber` may be resumed, and the message if not.
///
/// `is_cancel` selects the wording of the root-fiber refusal. Null means the
/// fiber may be resumed: a refusal is the case that has a value to give back,
/// so the optional says which of the two happened without a caller comparing
/// against `.ok`.
///
/// All three refusals return a signal rather than raising. The first also
/// marks the fiber errored, which the other two do not: a fiber refused for
/// recursion depth has had nothing done to it, while one refused for its
/// status already has the status that refused it.
pub fn checkCanResume(fiber: *fibers.Fiber, is_cancel: bool) ?Resumed {
    // Check conditions.
    const old_status = fibers.status(fiber);
    if (vm_state.current().stackn >= config.recursion_guard) {
        setStatus(fiber, fibers.FiberStatus.@"error");
        return .fail("C stack recursed too deeply");
    }
    // If a "task" fiber is trying to be used as a normal fiber, detect that.
    // See bug #920. Fibers must be marked as root fibers manually, or by the ev
    // scheduler.
    if (vm_state.current().fiber != null and fibers.evFlags(fiber).root) {
        return .fail(if (has_ev)
            (if (is_cancel)
                "cannot cancel root fiber, use ev/cancel"
            else
                "cannot resume root fiber, use ev/go")
        else
            (if (is_cancel)
                "cannot cancel root fiber"
            else
                "cannot resume root fiber"));
    }
    // Listed rather than `else`: a status added later must state whether it
    // can be resumed, and defaulting to "yes" is the dangerous half.
    if (switch (old_status) {
        .alive, .dead, .@"error", .user0, .user1, .user2, .user3, .user4 => true,
        .debug, .pending, .user5, .user6, .user7, .user8, .user9, .new => false,
    }) {
        // The refusal message is built before any scope is opened. `tryInit`
        // is `continueNoCheck`'s and this returns before reaching it, so a
        // raise from the formatter has nothing above it to land in. It aborts
        // at the site rather than leaving a report for whatever opens the next
        // scope. Only `%s` of a static name is rendered, so nothing
        // user-supplied runs here.
        const str = raise.total(
            pp_format.formatc("cannot resume fiber with status :%s", .{utils.statusNames[@intFromEnum(old_status)]}),
            "a fiber-resume refusal's message",
        );
        return .{ .signal = abi.Signal.@"error", .value = wrap.fromString(str) };
    }
    return null;
}

/// Enters the main VM loop, refusing a fiber `checkCanResume` rejects.
pub fn continueFiber(fiber: *fibers.Fiber, in: repr.Value) Resumed {
    // Check conditions.
    if (checkCanResume(fiber, false)) |refusal| return refusal;
    return continueNoCheck(fiber, in);
}

/// Resumes `fiber`, with the protected scope every resume re-establishes.
///
/// `signal.tryInit` is what points the VM's `return_reg` at `tstate.payload`,
/// and so what makes `signalPlan` decide `.raise` instead of `.top_level`. The
/// raise itself travels back as a returned error, through frames that have run
/// their `defer`s.
///
/// So the whole of the mechanism is `runVm(fiber, in) catch pending_signal`.
/// The signal a raise ends on is in the VM's `pending_signal`, where
/// `signalRecord` writes it; the payload is in `tstate.payload`, where
/// `return_reg` pointed.
///
/// `continueFiber` and `continueSignal` are the two callers that check first,
/// `JOP_RESUME` reaches it by import from `vm.zig`, and `test/gc_pcall.zig` is
/// the contract on its rooting.
pub fn continueNoCheck(fiber: *fibers.Fiber, in_init: repr.Value) Resumed {
    var in = in_init;
    const old_status = fibers.status(fiber);

    if (has_ev) ev.fiberDidResume(fiber);

    // Clear last value.
    fiber.last_value = wrap.fromNil();

    // Continue child fiber if it exists.
    if (fiber.child) |child| {
        if (vm_state.current().root_fiber == null) vm_state.current().root_fiber = fiber;
        const instr = fiberFrame(fiber).pc.bytecode.?[0];
        vm_state.current().stackn += 1;
        const resumed = continueFiber(child, in);
        const sig = resumed.signal;
        in = resumed.value;
        vm_state.current().stackn -= 1;
        if (vm_state.current().root_fiber == fiber) vm_state.current().root_fiber = null;
        if (sig != abi.Signal.ok and !child.flags.traps.has(sig)) {
            // The two vocabularies share their first fourteen values, which is
            // what `signal.zig`'s comptime block asserts and what this line
            // depends on.
            setStatus(fiber, @enumFromInt(@intFromEnum(sig)));
            fiber.last_value = child.last_value;
            return .{ .signal = sig, .value = in };
        }
        // Check if we need any special handling for certain opcodes.
        if (constants.Opcode.fromWord(instr & 0x7F) == .next) {
            in = if (sig == abi.Signal.ok or
                sig == abi.Signal.@"error" or
                sig == abi.Signal.user0 or
                sig == abi.Signal.user1 or
                sig == abi.Signal.user2 or
                sig == abi.Signal.user3 or
                sig == abi.Signal.user4)
                wrap.fromNil()
            else
                wrap.fromInteger(0);
        }
        fiber.child = null;
    }

    // Handle new fibers being resumed with a non-nil value.
    if (old_status == fibers.FiberStatus.new and !repr.checkType(in, repr.Tag.nil)) {
        const stack = fiber.data.? + utils.asSize(fiber.frame);
        if (fiberFrame(fiber).func) |func| {
            if (func.def.?.arity > 0) {
                stack[0] = in;
            } else if (func.def.?.flags.vararg) {
                stack[0] = wrap.fromTuple(tuples.newFrom(@as(*const [1]repr.Value, &in)));
            }
        }
    }

    // If this is a nested continue (root_fiber already set), root the fiber so
    // it survives GC. `gc/mark.zig`'s `collect` marks only `root_fiber`, so
    // without this a nested fiber, one from a `pcall` inside a cfunction for
    // instance, would be invisible to the collector and could be freed while
    // actively running.
    const fiber_rooted = vm_state.current().root_fiber != null;
    if (fiber_rooted) gc_alloc.gcroot(wrap.fromFiber(fiber));

    // Save global state, and run.
    var tstate: vm_state.TryState = undefined;
    signal_core.tryInit(&tstate);
    if (vm_state.current().root_fiber == null) vm_state.current().root_fiber = fiber;
    vm_state.current().fiber = fiber;
    setStatus(fiber, fibers.FiberStatus.alive);
    const sig = vm_run.runVm(fiber, in) catch vm_state.current().pending_signal;

    // Restore.
    if (vm_state.current().root_fiber == fiber) vm_state.current().root_fiber = null;
    setStatus(fiber, @enumFromInt(@intFromEnum(sig)));
    signal_core.restore(&tstate);
    if (fiber_rooted) _ = gc_alloc.gcunroot(wrap.fromFiber(fiber));
    fiber.last_value = tstate.payload;

    return .{ .signal = sig, .value = tstate.payload };
}

/// Enters the main VM loop and immediately delivers `sig` into the fiber.
pub fn continueSignal(fiber: *fibers.Fiber, in: repr.Value, sig: abi.Signal) Resumed {
    if (checkCanResume(fiber, sig != abi.Signal.ok)) |refusal| return refusal;
    if (sig != abi.Signal.ok) {
        signal_core.signalInject(fiber, sig);
    }
    return continueNoCheck(fiber, in);
}

/// Calls a function on a fresh or recycled fiber, and reports rather than
/// raises.
///
/// `fun` is the callee, `args` the arguments, and `f` an optional slot: a
/// fiber already in it is recycled through `fibers.reset`, and the fiber
/// actually used is written back.
pub fn pcall(
    fun: *functions.Function,
    args: []const repr.Value,
    f: ?*?*fibers.Fiber,
) Resumed {
    const made = if (if (f) |slot| slot.* else null) |existing|
        fibers.reset(existing, fun, args)
    else
        fibers.new(fun, 64, args);
    const live = made catch {
        // The slot is cleared rather than left alone. A rejection stores null
        // over whatever the caller had, including the recycled fiber a
        // rejected `reset` left frameless. `test/vm_entry.zig` pins it.
        if (f) |slot| slot.* = null;
        return .fail("arity mismatch");
    };
    if (f) |slot| slot.* = live;
    return continueFiber(live, wrap.fromNil());
}

/// Executes a single instruction in `fiber`.
///
/// `in` is the value the resume passes in and `out` is where the value it
/// ends with is written. It works by inspecting the fiber, setting a
/// breakpoint at each instruction that could come next, resuming, and putting
/// the bytecode back.
///
/// The breakpoint bit is written into the bytecode itself and taken out again
/// afterwards, so a raise from inside the resume would leave it set. Nothing
/// reaches that: the resume returns a signal rather than raising, so the
/// restore always runs.
pub fn step(fiber: *fibers.Fiber, in: repr.Value, out: *repr.Value) raise.Error!abi.Signal {
    // No finished or currently alive fibers.
    const status = fibers.status(fiber);
    if (status == fibers.FiberStatus.alive or
        status == fibers.FiberStatus.dead or
        status == fibers.FiberStatus.@"error")
    {
        return pp_format.panicf("cannot step fiber with status :%s", .{utils.statusNames[@intFromEnum(status)]});
    }

    // Get PC for setting breakpoints.
    const pc: [*]u32 = fiberFrame(fiber).pc.bytecode.?;

    // Check current opcode (sans debug flag). This tells us where the next or
    // next two candidate instructions will be. Usually it's the next
    // instruction in memory, but for branching instructions it is also the
    // target of the branch.
    var nexta: ?[*]u32 = null;
    var nextb: ?[*]u32 = null;
    var olda: u32 = 0;
    var oldb: u32 = 0;

    switch (constants.Opcode.fromWord(pc[0] & 0x7F)) {
        // These we just ignore for now. Supporting them means we could step
        // into and out of functions (including a call).
        .return_nil, .@"return", .@"error", .tailcall => {},
        .jump => nexta = pc + asOffset(fDS(pc)),
        .jump_if, .jump_if_not => {
            nexta = pc + 1;
            nextb = pc + asOffset(fES(pc));
        },
        else => nexta = pc + 1,
    }
    if (nexta) |word| {
        olda = word[0];
        word[0] |= 0x80;
    }
    if (nextb) |word| {
        oldb = word[0];
        word[0] |= 0x80;
    }

    // Go.
    const resumed = continueFiber(fiber, in);
    out.* = resumed.value;
    const signal = resumed.signal;

    // Restore.
    if (nexta) |word| word[0] = olda;
    if (nextb) |word| word[0] = oldb;

    return signal;
}

// ==========================================================================
// Private functions
// ==========================================================================

/// The raise for a `funcframe` that refused `argc` arguments, naming which of
/// the three arity bounds was missed.
///
/// `fun` is the callee and `argc` the count it was offered. The caller has
/// already had `fibers.funcframe` refuse, so this only decides the wording.
///
/// It is `noinline` because it is `call`'s only cold region and the largest:
/// three `panicf` calls with distinct comptime formats instantiate three
/// renderings, and inlined they sit in the frame of a function whose hot path
/// is a host-to-Janet call.
noinline fn arityMismatch(fun: *functions.Function, argc: usize) raise.Error {
    const min = fun.def.?.min_arity;
    const max = fun.def.?.max_arity;
    const funv = wrap.fromFunction(fun);
    // `%d` renders through an `i64`; the arities are the funcdef's own `i32`
    // and the count is the slice's.
    const got: i64 = @intCast(argc);
    if (min == max and min != argc) {
        return pp_format.panicf("arity mismatch in %v, expected %d, got %d", .{ funv, min, got });
    }
    if (min >= 0 and argc < min) {
        return pp_format.panicf("arity mismatch in %v, expected at least %d, got %d", .{ funv, min, got });
    }
    return pp_format.panicf("arity mismatch in %v, expected at most %d, got %d", .{ funv, max, got });
}

/// A signed instruction field as a pointer offset. Zig's pointer arithmetic
/// takes an unsigned offset, so the two's complement is taken explicitly.
inline fn asOffset(n: i32) usize {
    return @bitCast(@as(isize, n));
}

/// Signed interpretations of the instruction word's jump fields, as an
/// arithmetic right shift of the word reinterpreted as a signed 32-bit
/// integer.
inline fn fDS(pc: [*]const u32) i32 {
    return @as(i32, @bitCast(pc[0])) >> 8;
}
inline fn fES(pc: [*]const u32) i32 {
    return @as(i32, @bitCast(pc[0])) >> 16;
}

/// The frame `fiber` is currently in.
inline fn fiberFrame(fiber: *fibers.Fiber) *vm_state.StackFrame {
    return @ptrCast(@alignCast(fiber.data.? + utils.asSize(fiber.frame) - frame_size));
}

/// Clears the status bits, then writes the new status into them.
inline fn setStatus(fiber: *fibers.Fiber, status: fibers.FiberStatus) void {
    fiber.flags.status = @intCast(@intFromEnum(status));
}

/// The placeholder a dirty stack's guard frame stores.
///
/// It is never called. The frame exists so that the arguments already pushed
/// above `stackstart` are not overwritten by the call being set up. Its
/// address is not observable: the frame stores it in `pc` with `func` left
/// null, and an unregistered `CFunction` renders as `<cfunction>` in a stack
/// trace either way.
fn voidCFunction(argv: []repr.Value) raise.Error!repr.Value {
    _ = argv;

    return raise.panic("placeholder");
}
