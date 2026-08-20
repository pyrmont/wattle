//! jump-transparent
//!
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

const abi = @import("abi");
const c = abi.c;

/// `JANET_VM_HAS_EV` in `src/zig/state_abi.h`. Two regions below are inside
/// `#ifdef JANET_EV` in the C original: the `sched_id` bump on a coerced
/// `JANET_SIGNAL_EVENT`, and the wording of the root-fiber refusal, which names
/// `ev/cancel` and `ev/go` only when those exist.
const has_ev = c.JANET_VM_HAS_EV != 0;

/// `janet.h`'s frame size. `janet_stack_frame` and `janet_fiber_frame` are
/// function-like macros over it and do not survive translation.
const frame_size: i32 = c.JANET_FRAME_SIZE;

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
inline fn fiberFrame(fiber: [*c]c.JanetFiber) *c.JanetStackFrame {
    return @ptrCast(@alignCast(fiber.*.data + asSize(fiber.*.frame) - frame_size));
}

/// `janet_fiber_set_status` from `fiber.h`: clear the status bits, then write
/// the new status into them. Also a macro, and also written out here.
inline fn setStatus(fiber: [*c]c.JanetFiber, status: c.JanetFiberStatus) void {
    fiber.*.flags &= ~@as(i32, c.JANET_FIBER_STATUS_MASK);
    fiber.*.flags |= @as(i32, @intCast(status)) << c.JANET_FIBER_STATUS_OFFSET;
}

/// Signed interpretations of the instruction word's jump fields, as C's
/// arithmetic right shift of the word reinterpreted as `int32_t`.
inline fn fDS(pc: [*c]const u32) i32 {
    return @as(i32, @bitCast(pc[0])) >> 8;
}
inline fn fES(pc: [*c]const u32) i32 {
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
export fn janet_step(fiber: [*c]c.JanetFiber, in: c.Janet, out: [*c]c.Janet) callconv(.c) c.JanetSignal {
    // No finished or currently alive fibers.
    const status = c.janet_fiber_status(fiber);
    if (status == c.JANET_STATUS_ALIVE or
        status == c.JANET_STATUS_DEAD or
        status == c.JANET_STATUS_ERROR)
    {
        c.janet_panicf("cannot step fiber with status :%s", c.janet_status_names[@intCast(status)]);
        unreachable;
    }

    // Get PC for setting breakpoints.
    const pc: [*c]u32 = fiberFrame(fiber).pc;

    // Check current opcode (sans debug flag). This tells us where the next or
    // next two candidate instructions will be. Usually it's the next
    // instruction in memory, but for branching instructions it is also the
    // target of the branch.
    var nexta: [*c]u32 = null;
    var nextb: [*c]u32 = null;
    var olda: u32 = 0;
    var oldb: u32 = 0;

    switch (pc[0] & 0x7F) {
        // These we just ignore for now. Supporting them means we could step
        // into and out of functions (including JOP_CALL).
        c.JOP_RETURN_NIL, c.JOP_RETURN, c.JOP_ERROR, c.JOP_TAILCALL => {},
        c.JOP_JUMP => nexta = pc + asOffset(fDS(pc)),
        c.JOP_JUMP_IF, c.JOP_JUMP_IF_NOT => {
            nexta = pc + 1;
            nextb = pc + asOffset(fES(pc));
        },
        else => nexta = pc + 1,
    }
    if (nexta != null) {
        olda = nexta[0];
        nexta[0] |= 0x80;
    }
    if (nextb != null) {
        oldb = nextb[0];
        nextb[0] |= 0x80;
    }

    // Go.
    const signal = c.janet_continue(fiber, in, out);

    // Restore.
    if (nexta != null) nexta[0] = olda;
    if (nextb != null) nextb[0] = oldb;

    return signal;
}

// ------------------------------------------------------------------ call

/// The placeholder a dirty stack's guard frame carries. It is never called; the
/// frame exists so that the arguments already pushed above `stackstart` are not
/// overwritten by the call being set up. Its address is not observable — the
/// frame stores it in `pc` with `func` left null, and an unregistered
/// `JanetCFunction` renders as `<cfunction>` in a stack trace either way.
fn voidCFunction(argc: i32, argv: [*c]c.Janet) callconv(.c) c.Janet {
    _ = argc;
    _ = argv;
    c.janet_panics(c.janet_cstring("placeholder"));
    unreachable;
}

/// Call a Janet function from C, on the current fiber, and raise rather than
/// report if anything goes wrong.
///
/// `janet_vm.fiber` is re-read at every use rather than held in a local, which
/// is what the C original does through the macro. The last two uses are after
/// `janet_run_vm` has returned, and the loop can re-enter fibers underneath it.
export fn janet_call(fun: [*c]c.JanetFunction, argc: i32, argv: [*c]const c.Janet) callconv(.c) c.Janet {
    // Check entry conditions.
    if (c.janet_vm.fiber == null) {
        c.janet_panics(c.janet_cstring("janet_call failed because there is no current fiber"));
        unreachable;
    }
    if (c.janet_vm.stackn >= c.JANET_RECURSION_GUARD) {
        c.janet_panics(c.janet_cstring("C stack recursed too deeply"));
        unreachable;
    }

    // Dirty stack.
    const dirty_stack: i32 = c.janet_vm.fiber.*.stacktop - c.janet_vm.fiber.*.stackstart;
    if (dirty_stack != 0) {
        c.janet_fiber_cframe(c.janet_vm.fiber, &voidCFunction);
    }

    // Tracing.
    if ((fun.*.gc.flags & c.JANET_FUNCFLAG_TRACE) != 0) {
        c.janet_vm.stackn += 1;
        c.janet_vm_trace_argv(fun, argc, argv);
        c.janet_vm.stackn -= 1;
    }

    // Push frame.
    c.janet_fiber_pushn(c.janet_vm.fiber, argv, argc);
    if (c.janet_fiber_funcframe(c.janet_vm.fiber, fun) != 0) {
        const min = fun.*.def.*.min_arity;
        const max = fun.*.def.*.max_arity;
        const funv = c.janet_wrap_function(fun);
        if (min == max and min != argc) {
            c.janet_panicf("arity mismatch in %v, expected %d, got %d", funv, min, argc);
            unreachable;
        }
        if (min >= 0 and argc < min) {
            c.janet_panicf("arity mismatch in %v, expected at least %d, got %d", funv, min, argc);
            unreachable;
        }
        c.janet_panicf("arity mismatch in %v, expected at most %d, got %d", funv, max, argc);
        unreachable;
    }
    fiberFrame(c.janet_vm.fiber).flags |= c.JANET_STACKFRAME_ENTRANCE;

    // Set up.
    const oldn = c.janet_vm.stackn;
    c.janet_vm.stackn += 1;
    const handle = c.janet_gclock();

    // Run vm.
    c.janet_vm.fiber.*.flags |= c.JANET_FIBER_RESUME_NO_USEVAL | c.JANET_FIBER_RESUME_NO_SKIP;
    const old_coerce_error = c.janet_vm.coerce_error;
    c.janet_vm.coerce_error = 1;
    const signal = c.janet_run_vm(c.janet_vm.fiber, c.janet_wrap_nil());
    c.janet_vm.coerce_error = old_coerce_error;

    // Teardown.
    c.janet_vm.stackn = oldn;
    c.janet_gcunlock(handle);
    if (dirty_stack != 0) {
        c.janet_fiber_popframe(c.janet_vm.fiber);
        c.janet_vm.fiber.*.stacktop += dirty_stack;
    }

    if (signal != c.JANET_SIGNAL_OK) {
        // Should match logic in janet_signalv.
        if (has_ev) {
            if (c.janet_vm.root_fiber != null and signal == c.JANET_SIGNAL_EVENT) {
                c.janet_vm.root_fiber.*.sched_id +%= 1;
            }
        }
        if (signal != c.JANET_SIGNAL_ERROR) {
            c.janet_vm.return_reg.* = c.janet_wrap_string(c.janet_formatc(
                "%v coerced from %s to error",
                c.janet_vm.return_reg.*,
                c.janet_signal_names[@intCast(signal)],
            ));
        }
        c.janet_panicv(c.janet_vm.return_reg.*);
        unreachable;
    }

    return c.janet_vm.return_reg.*;
}

// -------------------------------------------------------------- resuming

/// Whether `fiber` may be resumed, and the message if not.
///
/// Reports rather than raises, in all three refusals. The first also marks the
/// fiber errored, which the other two do not: a fiber refused for recursion
/// depth has had nothing done to it, while one refused for its status already
/// carries the status that refused it.
/// Exported with hidden visibility, which is what the C build's
/// `-fvisibility=hidden` already gives it: it is declared in `state.h` rather
/// than in `janet.h`, so a plain `export` would widen the shared library's
/// symbol set relative to the other selector.
fn checkCanResume(fiber: [*c]c.JanetFiber, out: [*c]c.Janet, is_cancel: c_int) callconv(.c) c.JanetSignal {
    // Check conditions.
    const old_status = c.janet_fiber_status(fiber);
    if (c.janet_vm.stackn >= c.JANET_RECURSION_GUARD) {
        setStatus(fiber, c.JANET_STATUS_ERROR);
        out.* = c.janet_cstringv("C stack recursed too deeply");
        return c.JANET_SIGNAL_ERROR;
    }
    // If a "task" fiber is trying to be used as a normal fiber, detect that.
    // See bug #920. Fibers must be marked as root fibers manually, or by the ev
    // scheduler.
    if (c.janet_vm.fiber != null and (fiber.*.gc.flags & c.JANET_FIBER_FLAG_ROOT) != 0) {
        out.* = c.janet_cstringv(if (has_ev)
            (if (is_cancel != 0)
                "cannot cancel root fiber, use ev/cancel"
            else
                "cannot resume root fiber, use ev/go")
        else
            (if (is_cancel != 0)
                "cannot cancel root fiber"
            else
                "cannot resume root fiber"));
        return c.JANET_SIGNAL_ERROR;
    }
    if (old_status == c.JANET_STATUS_ALIVE or
        old_status == c.JANET_STATUS_DEAD or
        (old_status >= c.JANET_STATUS_USER0 and old_status <= c.JANET_STATUS_USER4) or
        old_status == c.JANET_STATUS_ERROR)
    {
        const str = c.janet_formatc(
            "cannot resume fiber with status :%s",
            c.janet_status_names[@intCast(old_status)],
        );
        out.* = c.janet_wrap_string(str);
        return c.JANET_SIGNAL_ERROR;
    }
    return c.JANET_SIGNAL_OK;
}

/// Enter the main vm loop.
export fn janet_continue(fiber: [*c]c.JanetFiber, in: c.Janet, out: [*c]c.Janet) callconv(.c) c.JanetSignal {
    // Check conditions.
    const tmp_signal = checkCanResume(fiber, out, 0);
    if (tmp_signal != 0) return tmp_signal;
    return c.janet_continue_no_check(fiber, in, out);
}

/// Enter the main vm loop but immediately raise a signal.
export fn janet_continue_signal(fiber: [*c]c.JanetFiber, in: c.Janet, out: [*c]c.Janet, sig: c.JanetSignal) callconv(.c) c.JanetSignal {
    const tmp_signal = checkCanResume(fiber, out, @intFromBool(sig != c.JANET_SIGNAL_OK));
    if (tmp_signal != 0) return tmp_signal;
    if (sig != c.JANET_SIGNAL_OK) {
        c.janet_signal_inject(fiber, sig);
    }
    return c.janet_continue_no_check(fiber, in, out);
}

/// Call a function on a fresh or recycled fiber, and report rather than raise.
export fn janet_pcall(
    fun: [*c]c.JanetFunction,
    argc: i32,
    argv: [*c]const c.Janet,
    out: [*c]c.Janet,
    f: [*c][*c]c.JanetFiber,
) callconv(.c) c.JanetSignal {
    var fiber: [*c]c.JanetFiber = undefined;
    if (f != null and f.* != null) {
        fiber = c.janet_fiber_reset(f.*, fun, argc, argv);
    } else {
        fiber = c.janet_fiber(fun, 64, argc, argv);
    }
    if (f != null) f.* = fiber;
    if (fiber == null) {
        out.* = c.janet_cstringv("arity mismatch");
        return c.JANET_SIGNAL_ERROR;
    }
    return janet_continue(fiber, c.janet_wrap_nil(), out);
}

comptime {
    @export(&checkCanResume, .{ .name = "janet_check_can_resume", .visibility = .hidden });
}
