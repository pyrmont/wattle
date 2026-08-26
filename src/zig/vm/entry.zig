//! The entry points: everything that stands above `run_vm` and decides whether,
//! and in what state, the loop is entered at all. `janet_step`, `janet_call`,
//! `janet_pcall`, `janet_continue`, `janet_continue_signal` and
//! `janet_check_can_resume`. This is Part 4 of Phase 9.
//!
//! `janet_continue_no_check` is not here and does not move in this phase.
//! Phase 7's fourth rule keeps it in C because it holds the `jmp_buf` that
//! every fiber resume re-establishes, and it is what makes this seam run in
//! both directions: `janet_continue` below calls down into a C function that
//! calls back up into `janet_run_vm`, which may itself be Zig.
//!
//! ## Why this is a separate object rather than part of vm_run.zig
//!
//! Part 3's rule is that a subsystem the interpreter touches *on every
//! instruction* is imported rather than linked. None of these is on that path.
//! `janet_call` runs once per C-to-Janet call, against a `janet_fiber_pushn`,
//! a `janet_fiber_funcframe` and the whole of `run_vm`; `janet_step` runs once
//! per debugger step. So the value operations here are ordinary calls to the C
//! symbols, which has the side benefit that `-Dvalue-wrap` is honoured by the
//! linker without this file needing an `extern` shim of its own.
//!
//! ## Raising, and why the file is jump-transparent
//!
//! Four of the six only ever *return* signals. The two that raise are
//! `janet_step`, for a fiber whose status forbids stepping, and `janet_call`,
//! which raises on three arity mismatches, two entry conditions, and any signal
//! the loop hands back — that last one being the coercion `janet_signal_plan`
//! is written to match.
//!
//! Raises also pass *through* `janet_call`. Under the default a panic anywhere
//! below `janet_run_vm` is a `longjmp` to the `setjmp` in
//! `janet_continue_no_check`, so this frame is abandoned along with the C
//! loop's. Nothing here is lost by that: `janet_gclock`'s handle and the
//! `stackn` bump are both restored by `janet_restore` on the way out, which is
//! why the C original does not release them on that path either, and the
//! `dirty_stack` frame belongs to a fiber the jump has already unwound.
//!
//! `build.zig` enforces the other half by rejecting `defer` and `errdefer` in a
//! file carrying the marker at the top.
//!
//! ## One thing stays in C
//!
//! `janet_call`'s trace line. `vm_do_trace` is a macro over `janet_eprintf`,
//! which is itself a variadic macro over `janet_dynprintf` and does not survive
//! translation; `src/core/vm.c` exposes it as `janet_vm_trace_argv`, defined
//! under either selector so that the two archives hold the same symbols. Part 3
//! did the same for the loop's own trace, and needed a different signature
//! there because the argv it traces is a window on a fiber stack `janet_eprintf`
//! can move.
//!
//! That the stack can move under a trace is not hypothetical: `janet_dynprintf`
//! calls a `:err` handler through the interpreter, and `FOUND.md` records what
//! that does to `run_vm`'s frame pointer. `janet_call` is not exposed to it,
//! because the argv it traces belongs to its caller rather than to the fiber.

const config = @import("config");
const options = @import("options");
const raise = @import("raise");
const pp_format = @import("../pp/format.zig");
const gc_alloc = @import("../gc.zig");
const tuples = @import("../value/tuples.zig");
const signal_core = @import("../signal.zig");
const kind = @import("../value/helpers/kind.zig");
const wrap = @import("../value/helpers/wrap.zig");
const fibers = @import("../value/fibers.zig");
const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");
const utils = @import("../utils.zig");
const ev = @import("../ev.zig");

/// The fiber's pushes, which raise by returning since Part 17a. Resolved to
/// `fiber_core_extern.zig` under `-Dfiber-core=c` until Phase 11 Part 26, where
/// the C body jumped and the declared error was never returned.
/// The loop itself. `continueNoCheck` below is the one caller that opens a
/// protected scope around it, and it reaches it by import: until the hinge
/// this was `c.janet_run_vm`, an abi that turned the error back into a
/// `longjmp`. `vm_run.zig` imports this file in turn, for `JOP_RESUME`.
const vm_run = @import("../vm.zig");
const value = @import("../value.zig");

/// `JANET_VM_HAS_EV` in `src/zig/state_abi.h`. Two regions below are inside
/// `#ifdef JANET_EV` in the C original: the `sched_id` bump on a coerced
/// `JANET_SIGNAL_EVENT`, and the wording of the root-fiber refusal, which names
/// `ev/cancel` and `ev/go` only when those exist.
const has_ev = constants.JANET_VM_HAS_EV != 0;

/// `janet.h`'s frame size. `janet_stack_frame` and `janet_fiber_frame` are
/// function-like macros over it and do not survive translation.
const frame_size: i32 = constants.JANET_FRAME_SIZE;

/// A sign-preserving widening, matching C's `int32_t` to `size_t` conversion in
/// `fiber->data + fiber->frame`.
inline fn asSize(n: i32) usize {
    return @bitCast(@as(isize, n));
}

/// `pc += DS` in C, where `DS` is a signed instruction field. Zig's pointer
/// arithmetic takes an unsigned offset, so the two's complement is taken
/// explicitly and the wrap is the same one C performs.
inline fn asOffset(n: i32) usize {
    return @bitCast(@as(isize, n));
}

/// `janet_fiber_frame(f)` from `fiber.h`.
inline fn fiberFrame(fiber: *types.JanetFiber) *types.JanetStackFrame {
    return @ptrCast(@alignCast(fiber.*.data.? + asSize(fiber.*.frame) - frame_size));
}

/// `janet_fiber_set_status` from `fiber.h`: clear the status bits, then write
/// the new status into them. Also a macro, and also written out here.
inline fn setStatus(fiber: *types.JanetFiber, status: types.JanetFiberStatus) void {
    fiber.*.flags &= ~@as(i32, constants.JANET_FIBER_STATUS_MASK);
    fiber.*.flags |= @as(i32, @intCast(status)) << constants.JANET_FIBER_STATUS_OFFSET;
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
pub fn stepImpl(fiber: *types.JanetFiber, in: types.Janet, out: *types.Janet) raise.Error!types.JanetSignal {
    // No finished or currently alive fibers.
    const status = fibers.status(fiber);
    if (status == constants.JANET_STATUS_ALIVE or
        status == constants.JANET_STATUS_DEAD or
        status == constants.JANET_STATUS_ERROR)
    {
        return pp_format.panicf("cannot step fiber with status :%s", .{utils.statusNames[@intCast(status)]});
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

    switch (pc[0] & 0x7F) {
        // These we just ignore for now. Supporting them means we could step
        // into and out of functions (including JOP_CALL).
        constants.JOP_RETURN_NIL, constants.JOP_RETURN, constants.JOP_ERROR, constants.JOP_TAILCALL => {},
        constants.JOP_JUMP => nexta = pc + asOffset(fDS(pc)),
        constants.JOP_JUMP_IF, constants.JOP_JUMP_IF_NOT => {
            nexta = pc + 1;
            nextb = pc + asOffset(fES(pc));
        },
        else => nexta = pc + 1,
    }
    if (nexta != null) {
        olda = nexta.?[0];
        nexta.?[0] |= 0x80;
    }
    if (nextb != null) {
        oldb = nextb.?[0];
        nextb.?[0] |= 0x80;
    }

    // Go.
    const signal = continueFiber(fiber, in, out);

    // Restore.
    if (nexta != null) nexta.?[0] = olda;
    if (nextb != null) nextb.?[0] = oldb;

    return signal;
}

// ------------------------------------------------------------------ call

/// The placeholder a dirty stack's guard frame carries. It is never called; the
/// frame exists so that the arguments already pushed above `stackstart` are not
/// overwritten by the call being set up. Its address is not observable — the
/// frame stores it in `pc` with `func` left null, and an unregistered
/// `JanetCFunction` renders as `<cfunction>` in a stack trace either way.
fn voidCFunction(argv: []types.Janet) raise.Raising(types.Janet) {
    _ = @as(i32, @intCast(argv.len));

    return raise.panic("placeholder");
}

/// Call a Janet function from C, on the current fiber, and raise rather than
/// report if anything goes wrong.
///
/// `janet_vm.fiber` is re-read at every use rather than held in a local, which
/// is what the C original does through the macro. The last two uses are after
/// `janet_run_vm` has returned, and the loop can re-enter fibers underneath it.
pub fn callImpl(fun: *types.JanetFunction, argv: []const types.Janet) raise.Error!types.Janet {
    // Check entry conditions.
    if (c.vm().fiber == null) {
        return raise.panic("janet_call failed because there is no current fiber");
    }
    if (c.vm().stackn >= config.recursion_guard) {
        return raise.panic("C stack recursed too deeply");
    }

    // Dirty stack.
    const dirty_stack: i32 = c.vm().fiber.?.stacktop - c.vm().fiber.?.stackstart;
    if (dirty_stack != 0) {
        fibers.cframe(c.vm().fiber.?, raise.stored(&voidCFunction));
    }

    // Tracing.
    if ((fun.*.gc.flags & constants.JANET_FUNCFLAG_TRACE) != 0) {
        c.vm().stackn += 1;
        vm_run.traceArgv(fun, argv);
        c.vm().stackn -= 1;
    }

    // Push frame.
    try fibers.pushn(c.vm().fiber.?, argv.ptr, @as(i32, @intCast(argv.len)));
    if (fibers.funcframe(c.vm().fiber.?, fun) != 0) {
        const min = fun.*.def.?.min_arity;
        const max = fun.*.def.?.max_arity;
        const funv = wrap.fromFunction(fun);
        if (min == max and min != @as(i32, @intCast(argv.len))) {
            return pp_format.panicf("arity mismatch in %v, expected %d, got %d", .{ funv, min, @as(i32, @intCast(argv.len)) });
        }
        if (min >= 0 and @as(i32, @intCast(argv.len)) < min) {
            return pp_format.panicf("arity mismatch in %v, expected at least %d, got %d", .{ funv, min, @as(i32, @intCast(argv.len)) });
        }
        return pp_format.panicf("arity mismatch in %v, expected at most %d, got %d", .{ funv, max, @as(i32, @intCast(argv.len)) });
    }
    fiberFrame(c.vm().fiber.?).flags |= constants.JANET_STACKFRAME_ENTRANCE;

    // Set up.
    const oldn = c.vm().stackn;
    c.vm().stackn += 1;
    const handle = gc_alloc.gclock();

    // Run vm.
    c.vm().fiber.?.flags |= constants.JANET_FIBER_RESUME_NO_USEVAL | constants.JANET_FIBER_RESUME_NO_SKIP;
    const old_coerce_error = c.vm().coerce_error;
    c.vm().coerce_error = 1;
    const signal = try vm_run.runVm(c.vm().fiber.?, wrap.fromNil());
    c.vm().coerce_error = old_coerce_error;

    // Teardown.
    c.vm().stackn = oldn;
    gc_alloc.gcunlock(handle);
    if (dirty_stack != 0) {
        fibers.popframe(c.vm().fiber.?);
        c.vm().fiber.?.stacktop += dirty_stack;
    }

    if (signal != constants.JANET_SIGNAL_OK) {
        // Should match logic in janet_signalv.
        if (has_ev) {
            if (c.vm().root_fiber != null and signal == constants.JANET_SIGNAL_EVENT) {
                c.vm().root_fiber.?.sched_id +%= 1;
            }
        }
        if (signal != constants.JANET_SIGNAL_ERROR) {
            c.vm().return_reg.?.* = wrap.fromString(try pp_format.formatc("%v coerced from %s to error", .{ c.vm().return_reg.?.*, utils.signalNames[@intCast(signal)] }));
        }
        return raise.panicv(c.vm().return_reg.?.*);
    }

    return c.vm().return_reg.?.*;
}

// -------------------------------------------------------------- resuming

/// Whether `fiber` may be resumed, and the message if not.
///
/// Reports rather than raises, in all three refusals. The first also marks the
/// fiber errored, which the other two do not: a fiber refused for recursion
/// depth has had nothing done to it, while one refused for its status already
/// carries the status that refused it.
/// `janet_check_can_resume` was the abi of this, exported with hidden
/// visibility because `state.h` declared it rather than `janet.h`. Phase 11
/// Part 12 retired it: `test/vm_entry.c` and `test/vm_run.c` were its last C
/// callers, and `vm_run.zig`'s `JOP_RESUME` and `JOP_CANCEL` arms were reaching
/// it through the symbol table from inside the same compilation. It reports
/// rather than raises, so this is rule 17's harmless half — a round trip
/// removed rather than a flattened raise.
pub fn checkCanResume(fiber: *types.JanetFiber, out: *types.Janet, is_cancel: c_int) callconv(.c) types.JanetSignal {
    // Check conditions.
    const old_status = fibers.status(fiber);
    if (c.vm().stackn >= config.recursion_guard) {
        setStatus(fiber, constants.JANET_STATUS_ERROR);
        out.* = value.fromBytes("C stack recursed too deeply", .string);
        return constants.JANET_SIGNAL_ERROR;
    }
    // If a "task" fiber is trying to be used as a normal fiber, detect that.
    // See bug #920. Fibers must be marked as root fibers manually, or by the ev
    // scheduler.
    if (c.vm().fiber != null and (fiber.*.gc.flags & constants.JANET_FIBER_FLAG_ROOT) != 0) {
        out.* = value.fromBytes(if (has_ev)
            (if (is_cancel != 0)
                "cannot cancel root fiber, use ev/cancel"
            else
                "cannot resume root fiber, use ev/go")
        else
            (if (is_cancel != 0)
                "cannot cancel root fiber"
            else
                "cannot resume root fiber"), .string);
        return constants.JANET_SIGNAL_ERROR;
    }
    if (old_status == constants.JANET_STATUS_ALIVE or
        old_status == constants.JANET_STATUS_DEAD or
        (old_status >= constants.JANET_STATUS_USER0 and old_status <= constants.JANET_STATUS_USER4) or
        old_status == constants.JANET_STATUS_ERROR)
    {
        const str = pp_format.formatcReported("cannot resume fiber with status :%s", .{utils.statusNames[@intCast(old_status)]});
        out.* = wrap.fromString(str);
        return constants.JANET_SIGNAL_ERROR;
    }
    return constants.JANET_SIGNAL_OK;
}

/// Resume `fiber`, with the protected scope every resume re-establishes.
///
/// **This is the hinge, and until Phase 10's last increment it was the third
/// and final `setjmp`.** It stayed in `src/core/vm.c` from Phase 7 to here for
/// one reason: it held the `jmp_buf`, a Zig function cannot hold one, and
/// every raise anywhere below it — in C or in Zig — was a `longjmp` that
/// landed exactly here. Phase 7's fourth rule was written around that fact.
///
/// What replaced it is `janet_try_init` with nothing after it. The scope was
/// never the jump: `janet_try_init` is what points `janet_vm.return_reg` at
/// `tstate.payload`, and therefore what makes `janet_signal_plan` answer
/// `RAISE` instead of `TOP_LEVEL`. The `setjmp` only carried the raise from
/// where it happened up to here, and a returned error carries it instead —
/// through frames that have already run their `defer`s, which the jump never
/// did.
///
/// So the whole of the mechanism is `runVm(fiber, in) catch pending_signal`.
/// The signal a raise carries is in `janet_vm.pending_signal`, which is where
/// `longjmp`'s second argument used to put it and where `janet_zig_signal_record`
/// has written it since Part 2; the payload is in `tstate.payload`, which is
/// where `return_reg` pointed. Both readings are unchanged. Only the travel is
/// gone.
///
/// It is not exported and no longer appears in `state.h`. Nothing in C calls
/// it: `janet_continue` and `janet_continue_signal` are just above,
/// `JOP_RESUME` reaches it by import from `vm_run.zig`, and the C bodies that
/// used to do both are behind selectors that have no `c` arm left.
pub fn continueNoCheck(fiber: *types.JanetFiber, in_init: types.Janet, out: *types.Janet) types.JanetSignal {
    var in = in_init;
    const old_status = fibers.status(fiber);

    if (has_ev) ev.fiberDidResume(fiber);

    // Clear last value.
    fiber.*.last_value = wrap.fromNil();

    // Continue child fiber if it exists.
    if (fiber.*.child != null) {
        if (c.vm().root_fiber == null) c.vm().root_fiber = fiber;
        const child = fiber.*.child.?;
        const instr = fiberFrame(fiber).pc.?[0];
        c.vm().stackn += 1;
        const sig = continueFiber(child, in, &in);
        c.vm().stackn -= 1;
        if (c.vm().root_fiber == fiber) c.vm().root_fiber = null;
        if (sig != constants.JANET_SIGNAL_OK and (child.*.flags & (@as(i32, 1) << @intCast(sig))) == 0) {
            out.* = in;
            setStatus(fiber, @intCast(sig));
            fiber.*.last_value = child.*.last_value;
            return sig;
        }
        // Check if we need any special handling for certain opcodes.
        if (instr & 0x7F == constants.JOP_NEXT) {
            in = if (sig == constants.JANET_SIGNAL_OK or
                sig == constants.JANET_SIGNAL_ERROR or
                sig == constants.JANET_SIGNAL_USER0 or
                sig == constants.JANET_SIGNAL_USER1 or
                sig == constants.JANET_SIGNAL_USER2 or
                sig == constants.JANET_SIGNAL_USER3 or
                sig == constants.JANET_SIGNAL_USER4)
                wrap.fromNil()
            else
                // `janet_wrap_integer(0)`, written out. It is the one declared
                // `janet_wrap_*` with no definition under `-Dnanbox=false`, so
                // calling it links only under a NaN-boxed layout;
                // `value_access.zig`'s `wrapInteger` has the whole account and
                // `FOUND.md` has the defect.
                wrap.fromNumber(0);
        }
        fiber.*.child = null;
    }

    // Handle new fibers being resumed with a non-nil value.
    if (old_status == constants.JANET_STATUS_NEW and kind.checkType(in, constants.JANET_NIL) == 0) {
        const stack = fiber.*.data.? + asSize(fiber.*.frame);
        if (fiberFrame(fiber).func) |func| {
            if (func.def.?.arity > 0) {
                stack[0] = in;
            } else if (func.def.?.flags & constants.JANET_FUNCDEF_FLAG_VARARG != 0) {
                stack[0] = wrap.fromTuple(tuples.newFrom(@ptrCast(&in), 1));
            }
        }
    }

    // If this is a nested continue (root_fiber already set), root the fiber so
    // it survives GC. `janet_collect` only marks `root_fiber`, so without this
    // a nested fiber -- one from a `janet_pcall` in a C function, say -- would
    // be invisible to the collector and could be freed while actively running.
    const fiber_rooted = c.vm().root_fiber != null;
    if (fiber_rooted) gc_alloc.gcroot(wrap.fromFiber(fiber));

    // Save global state, and run.
    var tstate: types.JanetTryState = undefined;
    signal_core.tryInit(&tstate);
    if (c.vm().root_fiber == null) c.vm().root_fiber = fiber;
    c.vm().fiber = fiber;
    setStatus(fiber, constants.JANET_STATUS_ALIVE);
    const sig = vm_run.runVm(fiber, in) catch c.vm().pending_signal;

    // Restore.
    if (c.vm().root_fiber == fiber) c.vm().root_fiber = null;
    setStatus(fiber, @intCast(sig));
    signal_core.restore(&tstate);
    if (fiber_rooted) _ = gc_alloc.gcunroot(wrap.fromFiber(fiber));
    fiber.*.last_value = tstate.payload;
    out.* = tstate.payload;

    return sig;
}

/// Enter the main vm loop.
pub fn continueFiber(fiber: *types.JanetFiber, in: types.Janet, out: *types.Janet) types.JanetSignal {
    // Check conditions.
    const tmp_signal = checkCanResume(fiber, out, 0);
    if (tmp_signal != 0) return tmp_signal;
    return continueNoCheck(fiber, in, out);
}

/// Enter the main vm loop but immediately raise a signal.
pub fn continueSignal(fiber: *types.JanetFiber, in: types.Janet, out: *types.Janet, sig: types.JanetSignal) types.JanetSignal {
    const tmp_signal = checkCanResume(fiber, out, @intFromBool(sig != constants.JANET_SIGNAL_OK));
    if (tmp_signal != 0) return tmp_signal;
    if (sig != constants.JANET_SIGNAL_OK) {
        signal_core.signalInject(fiber, sig);
    }
    return continueNoCheck(fiber, in, out);
}

/// Call a function on a fresh or recycled fiber, and report rather than raise.
pub fn pcall(
    fun: *types.JanetFunction,
    argc: i32,
    argv: ?[*]const types.Janet,
    out: *types.Janet,
    f: ?*?*types.JanetFiber,
) callconv(.c) types.JanetSignal {
    var fiber: ?*types.JanetFiber = undefined;
    if (if (f) |slot| slot.* else null) |existing| {
        fiber = fibers.reset(existing, fun, argc, argv);
    } else {
        fiber = fibers.new(fun, 64, argc, argv);
    }
    if (f) |slot| slot.* = fiber;
    if (fiber == null) {
        out.* = value.fromBytes("arity mismatch", .string);
        return constants.JANET_SIGNAL_ERROR;
    }
    return continueFiber(fiber.?, wrap.fromNil(), out);
}

/// The abis of the two entry points that raise. Both are `JANET_API`,
/// so the exported names are the abis and the implementations above are
/// reached only from Zig.
///
/// Nothing else here needs one: `janet_continue`, `janet_continue_signal` and
/// `janet_pcall` report a signal rather than raising, which is what makes them
/// the boundary a caller can already handle.
///
/// Neither of these two has an in-tree caller any more — `test/vm_entry.zig`
/// reaches `stepImpl` and `callImpl` by import, and every other Zig caller
/// always did. They stay because they are `janet.h`'s public surface, which is
/// the same finding Part 10 recorded for nine `value.c` exports and Part 11 for
/// `janet_signalv` and `janet_panics`.
pub const janetStepAbi = raise.panicking(stepImpl).abi;
pub const janetCallAbi = raise.panickingArgv(callImpl).abi;
