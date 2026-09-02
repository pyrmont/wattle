//! The entry points: everything that stands above `run_vm` and decides whether,
//! and in what state, the loop is entered at all. `janet_step`, `janet_call`,
//! `janet_pcall`, `janet_continue`, `janet_continue_signal` and
//! `janet_check_can_resume`.
//!
//! ## Why this is separate from the loop
//!
//! A subsystem the interpreter touches *on every instruction* is imported
//! rather than called through a symbol. None of these is on that path.
//! `janet_call` runs once per C-to-Janet call, against a `janet_fiber_pushn`,
//! a `janet_fiber_funcframe` and the whole of the loop; `janet_step` runs once
//! per debugger step.
//!
//! ## Raising
//!
//! Four of the six only ever *return* signals. The two that raise are
//! `janet_step`, for a fiber whose status forbids stepping, and `janet_call`,
//! which raises on three arity mismatches, two entry conditions, and any signal
//! the loop hands back -- that last one being the coercion `signalPlan` is
//! written to match.
//!
//! ## One trace line
//!
//! `janet_call`'s trace goes through `janet_eprintf`, a variadic. Zig can call
//! a C variadic but cannot define one, and `dynprintf` calls a `:err` handler
//! through the interpreter, which can grow the fiber's stack. `call` is not
//! exposed to that, because the argv it traces belongs to its caller rather
//! than to the fiber; the interpreter's own trace reloads its frame pointer
//! after the trace for exactly this reason.

const config = @import("config");
const raise = @import("../raise.zig");
const pp_format = @import("../pp/format.zig");
const gc_alloc = @import("../gc.zig");
const tuples = @import("../value/tuples.zig");
const signal_core = @import("../signal.zig");
const wrap = @import("../value/helpers/wrap.zig");
const fibers = @import("../value/fibers.zig");
const repr = @import("repr");
const constants = @import("constants");
const vm_state = @import("../vm/state.zig");
const utils = @import("../utils.zig");
const ev = @import("../ev.zig");

/// The fiber's pushes, which raise by returning.
/// The loop itself. `continueNoCheck` below is the one caller that opens a
/// protected scope around it, and it reaches it by import. `vm.zig` imports
/// this file in turn, for `JOP_RESUME`.
const vm_run = @import("../vm.zig");
const value = @import("../value.zig");
const abi = @import("abi");
const functions = @import("../value/functions.zig");

/// `config.ev`. Two regions below are inside
/// `#ifdef JANET_EV` in the C original: the `sched_id` bump on a coerced
/// `JANET_SIGNAL_EVENT`, and the wording of the root-fiber refusal, which names
/// `ev/cancel` and `ev/go` only when those exist.
const has_ev = constants.JANET_VM_HAS_EV != 0;

/// A stack frame's size in `Value` slots.
const frame_size: i32 = constants.JANET_FRAME_SIZE;

/// A signed instruction field as a pointer offset. Zig's pointer arithmetic
/// takes an unsigned offset, so the two's complement is taken explicitly.
inline fn asOffset(n: i32) usize {
    return @bitCast(@as(isize, n));
}

/// `janet_fiber_frame(f)` from `fiber.h`.
inline fn fiberFrame(fiber: *fibers.Fiber) *vm_state.StackFrame {
    return @ptrCast(@alignCast(fiber.data.? + utils.asSize(fiber.frame) - frame_size));
}

/// `janet_fiber_set_status` from `fiber.h`: clear the status bits, then write
/// the new status into them. Also a macro, and also written out here.
inline fn setStatus(fiber: *fibers.Fiber, status: fibers.FiberStatus) void {
    fiber.flags.status = @intCast(@intFromEnum(status));
}

/// Signed interpretations of the instruction word's jump fields, as C's
/// arithmetic right shift of the word reinterpreted as `int32_t`.
inline fn fDS(pc: [*]const u32) i32 {
    return @as(i32, @bitCast(pc[0])) >> 8;
}
inline fn fES(pc: [*]const u32) i32 {
    return @as(i32, @bitCast(pc[0])) >> 16;
}

// ------------------------------------------------------------------ step

/// Execute a single instruction in the fiber. Does this by inspecting the
/// fiber, setting a breakpoint at the next instruction, executing, and
/// resetting breakpoints to how they were prior. Yes, it's a bit hacky.
///
/// The breakpoint bit is written into the bytecode itself and taken out again
/// afterwards, so a raise from inside `janet_continue` leaves it set. That is
/// the C behaviour and it is reproduced rather than repaired: `janet_continue`
/// returns signals rather than raising, and the only way out of it that skips
/// the restore is a panic from below the `setjmp` it installs, which cannot
/// reach here.
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
    const pc: [*]u32 = fiberFrame(fiber).pc.?;

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

// ------------------------------------------------------------------ call

/// The placeholder a dirty stack's guard frame carries. It is never called; the
/// frame exists so that the arguments already pushed above `stackstart` are not
/// overwritten by the call being set up. Its address is not observable — the
/// frame stores it in `pc` with `func` left null, and an unregistered
/// `CFunction` renders as `<cfunction>` in a stack trace either way.
fn voidCFunction(argv: []repr.Value) raise.Raising(repr.Value) {
    _ = argv;

    return raise.panic("placeholder");
}

/// Call a Janet function from C, on the current fiber, and raise rather than
/// report if anything goes wrong.
///
/// `vm.fiber` is re-read at every use rather than held in a local, which
/// is what the C original does through the macro. The last two uses are after
/// `janet_run_vm` has returned, and the loop can re-enter fibers underneath it.
/// `vm_state.currentFiber()` is that same re-read: the entry check below
/// refuses a null fiber, and nothing between there and the return can put the
/// field back to null -- `signal.restore` writes back the fiber it saved on
/// the way in.
pub fn call(fun: *functions.Function, argv: []const repr.Value) raise.Error!repr.Value {
    // Check entry conditions.
    if (vm_state.current().fiber == null) {
        return raise.panic("janet_call failed because there is no current fiber");
    }
    if (vm_state.current().stackn >= config.recursion_guard) {
        return raise.panic("C stack recursed too deeply");
    }

    // Dirty stack.
    const dirty_stack: i32 = vm_state.currentFiber().stacktop - vm_state.currentFiber().stackstart;
    if (dirty_stack != 0) {
        fibers.cframe(vm_state.currentFiber(), raise.stored(&voidCFunction));
    }

    // Tracing.
    if (functions.isTraced(fun)) {
        vm_state.current().stackn += 1;
        try vm_run.traceArgv(fun, argv);
        vm_state.current().stackn -= 1;
    }

    // Push frame.
    try fibers.pushn(vm_state.currentFiber(), argv);
    fibers.funcframe(vm_state.currentFiber(), fun) catch {
        const min = fun.def.?.min_arity;
        const max = fun.def.?.max_arity;
        const funv = wrap.fromFunction(fun);
        // `%d` renders through an `i64`; the arities are the funcdef's own
        // `i32` and the count is the slice's.
        const got: i64 = @intCast(argv.len);
        if (min == max and min != argv.len) {
            return pp_format.panicf("arity mismatch in %v, expected %d, got %d", .{ funv, min, got });
        }
        if (min >= 0 and argv.len < min) {
            return pp_format.panicf("arity mismatch in %v, expected at least %d, got %d", .{ funv, min, got });
        }
        return pp_format.panicf("arity mismatch in %v, expected at most %d, got %d", .{ funv, max, got });
    };
    fiberFrame(vm_state.currentFiber()).flags.entrance = true;

    // Set up.
    const oldn = vm_state.current().stackn;
    vm_state.current().stackn += 1;
    const handle = gc_alloc.gclock();

    // Run vm.
    vm_state.currentFiber().flags.resume_no_useval = true;
    vm_state.currentFiber().flags.resume_no_skip = true;
    const old_coerce_error = vm_state.current().coerce_error;
    vm_state.current().coerce_error = true;
    const signal = try vm_run.runVm(vm_state.currentFiber(), wrap.fromNil());
    vm_state.current().coerce_error = old_coerce_error;

    // Teardown.
    vm_state.current().stackn = oldn;
    gc_alloc.gcunlock(handle);
    if (dirty_stack != 0) {
        fibers.popframe(vm_state.currentFiber());
        vm_state.currentFiber().stacktop += dirty_stack;
    }

    if (signal != abi.Signal.ok) {
        // Should match logic in janet_signalv.
        if (has_ev) {
            if (vm_state.current().root_fiber) |root| {
                if (signal == abi.Signal.event) root.sched_id +%= 1;
            }
        }
        if (signal != abi.Signal.@"error") {
            vm_state.current().return_reg.?.* = wrap.fromString(try pp_format.formatc("%v coerced from %s to error", .{ vm_state.current().return_reg.?.*, utils.signalNames[@intFromEnum(signal)] }));
        }
        return raise.panicv(vm_state.current().return_reg.?.*);
    }

    return vm_state.current().return_reg.?.*;
}

// -------------------------------------------------------------- resuming

/// What a resume answers: the signal it ended on and the value that goes with
/// it.
///
/// **They are always produced together**, which is why this is one type rather
/// than a signal beside an `out: *repr.Value`. Every path through the resume
/// family sets both -- a refusal sets the message, an ordinary return sets the
/// returned value, a raise sets the payload -- and the out-parameter was C's
/// way of returning two things, not a decision anything here makes.
pub const Resumed = struct {
    signal: abi.Signal,
    value: repr.Value,

    /// A refusal carrying a fixed message. The three in `checkCanResume` and
    /// `pcall`'s arity rejection are all this shape.
    fn fail(message: []const u8) Resumed {
        return .{ .signal = abi.Signal.@"error", .value = value.fromBytes(message, .string) };
    }
};

/// Whether `fiber` may be resumed, and the message if not.
///
/// **Null means it may.** A refusal is the interesting answer and is the one
/// that carries a value, so the optional says which of the two happened
/// without a caller having to compare against `.ok`.
///
/// Answers a signal rather than raising, in all three refusals. The first also marks the
/// fiber errored, which the other two do not: a fiber refused for recursion
/// depth has had nothing done to it, while one refused for its status already
/// carries the status that refused it.
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
        // The refusal message is built before any scope is opened -- `tryInit`
        // is `continueNoCheck`'s and this returns before reaching it -- so a
        // raise from the formatter has nothing above it to land in. It aborts
        // at the site rather than leaving a report for whatever opens the next
        // scope. Only `%s` of a static name is rendered, so nothing user-supplied
        // runs here.
        const str = raise.total(
            pp_format.formatc("cannot resume fiber with status :%s", .{utils.statusNames[@intFromEnum(old_status)]}),
            "a fiber-resume refusal's message",
        );
        return .{ .signal = abi.Signal.@"error", .value = wrap.fromString(str) };
    }
    return null;
}

/// Resume `fiber`, with the protected scope every resume re-establishes.
///
/// `tryInit` is what points the VM's `return_reg` at `tstate.payload`, and
/// therefore what makes `signalPlan` answer `RAISE` instead of `TOP_LEVEL`.
/// The raise itself travels back as a returned error, through frames that have
/// run their `defer`s.
///
/// So the whole of the mechanism is `runVm(fiber, in) catch pending_signal`.
/// The signal a raise carries is in the VM's `pending_signal`, where
/// `signalRecord` writes it; the payload is in `tstate.payload`, where
/// `return_reg` pointed.
///
/// It is not exported and nothing outside this file calls it: `janet_continue`
/// and `janet_continue_signal` are just above, and `JOP_RESUME` reaches it by
/// import.
pub fn continueNoCheck(fiber: *fibers.Fiber, in_init: repr.Value) Resumed {
    var in = in_init;
    const old_status = fibers.status(fiber);

    if (has_ev) ev.fiberDidResume(fiber);

    // Clear last value.
    fiber.last_value = wrap.fromNil();

    // Continue child fiber if it exists.
    if (fiber.child) |child| {
        if (vm_state.current().root_fiber == null) vm_state.current().root_fiber = fiber;
        const instr = fiberFrame(fiber).pc.?[0];
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
    // it survives GC. `janet_collect` only marks `root_fiber`, so without this
    // a nested fiber -- one from a `janet_pcall` in a C function, say -- would
    // be invisible to the collector and could be freed while actively running.
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

/// Enter the main vm loop.
pub fn continueFiber(fiber: *fibers.Fiber, in: repr.Value) Resumed {
    // Check conditions.
    if (checkCanResume(fiber, false)) |refusal| return refusal;
    return continueNoCheck(fiber, in);
}

/// Enter the main vm loop but immediately raise a signal.
pub fn continueSignal(fiber: *fibers.Fiber, in: repr.Value, sig: abi.Signal) Resumed {
    if (checkCanResume(fiber, sig != abi.Signal.ok)) |refusal| return refusal;
    if (sig != abi.Signal.ok) {
        signal_core.signalInject(fiber, sig);
    }
    return continueNoCheck(fiber, in);
}

/// Call a function on a fresh or recycled fiber, and report rather than raise.
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
        // **The slot is cleared, not left alone.** C assigns the result before
        // testing it, so a rejection stores null over whatever the caller had
        // -- including the recycled fiber a rejected `reset` left frameless.
        // `test/vm_entry.zig` pins it.
        if (f) |slot| slot.* = null;
        return .fail("arity mismatch");
    };
    if (f) |slot| slot.* = live;
    return continueFiber(live, wrap.fromNil());
}
