//! Try scopes and the decision half of raising a signal: the six VM fields a
//! protected call saves and restores, what `janet_signalv` does before it
//! jumps, and the signal a scheduler injects into a fiber it is about to
//! resume.
//!
//! This is Phase 7's third Zig object in the runtime core, and the boundary it
//! draws is the same one Part 7 drew, applied to control flow instead of to
//! frames: **nothing here may raise, and nothing here jumps.**
//!
//! Three consequences, each of which decided a split rather than followed from
//! one:
//!
//!  - **The `longjmp` stays in C.** `janet_signalv` is the only jump that
//!    targets `janet_vm.signal_buf`, and Zig owns everything it does except the
//!    jump itself: the null test on the return register, the coercion
//!    predicate, the `EVENT` bump of the root fiber's `sched_id`, the store
//!    into the return register, and `JANET_FIBER_DID_RAISE`. `src/core/capi.c`
//!    keeps the three lines that jump. That is not a limitation of Zig — Zig
//!    can call `_longjmp` — but a jump out of a Zig frame is the thing this
//!    phase exists to remove, and it is what Phase 10 deletes outright. Porting
//!    it would be work with a known expiry; porting the decision is not,
//!    because a tagged signal-and-payload result still has to make every one of
//!    these choices.
//!
//!    *Phase 10 Part 2 made that concrete.* `janet_zig_signal_record` at the
//!    foot of this file is the whole decision, and the jump in `capi.c` is now
//!    `janet_zig_signal_deliver` — three lines that read
//!    `janet_vm.pending_signal` and go. A Zig caller returns
//!    `error.JanetSignal` instead. Both deliveries share this file's decision,
//!    which is what stops them drifting while both are live.
//!
//!  - **The coercion message stayed in C, and no longer does.** `janet_formatc`
//!    renders a Janet value by running an abstract type's `tostring` callback,
//!    which can panic, so through Phase 9 `janet_signal_plan` reported that a
//!    message was needed and stopped, and C built it. Part 2 brought it here
//!    with `janet_zig_signal_record`: the constraint was the old rule that no
//!    Zig frame may be jumped through, and jump transparency replaced that in
//!    Phase 8. The order is the C original's exactly, including the case that
//!    matters: a panic raised *by* the formatting happens after the `sched_id`
//!    bump and before the return register is written, in both implementations.
//!    `JANET_SIGNAL_PLAN_COERCE` stays in the interface because `-Dsignal-core=c`
//!    still answers with it.
//!
//!  - **`janet_try_init` does not `setjmp`.** It cannot: Zig has no `setjmp`,
//!    and the buffer has to be filled in the frame that will be jumped to. The
//!    `janet_try` macro in `janet.h` still expands to `janet_try_init(state)`
//!    followed by `_setjmp((state)->buf)` in the caller's own frame, and the
//!    function below is only the field shuffling that precedes it. For the same
//!    reason `janet_continue_no_check` in `src/core/vm.c` stays in C in its
//!    entirety: it *is* the frame that holds the `jmp_buf`, so it cannot move
//!    until the public perimeter goes in Phase 10.
//!
//! `janet_check_can_resume` also stays in C, for a different reason: its three
//! failure paths build their diagnostics as Janet strings. That is the
//! report-rather-than-format layer Phase 7's third constraint describes, and it
//! is still unbuilt.

const std = @import("std");
const raise = @import("raise");
const pp_format = @import("pp/format.zig");
const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");
const stdio = @import("stdio.zig");
const wrap = @import("value/helpers/wrap.zig");
const fatal = @import("fatal.zig");
const utils = @import("utils.zig");

/// `JANET_VM_HAS_EV` in `src/zig/state_abi.h`. The `sched_id` bump below is
/// inside `#ifdef JANET_EV` in the C original; the field itself is
/// unconditional in `JanetFiber`, so only the behaviour is guarded.
const has_ev = constants.JANET_VM_HAS_EV != 0;

/// `janet_vm`, whose layout is `types.JanetVM`'s and whose address
/// `cabi.vm()` takes.
inline fn vm() *types.JanetVM {
    return c.vm();
}

/// `JanetSignal` translates as `c_uint` while the signal constants translate as
/// `c_int`, so every comparison would otherwise need a cast at the use site.
const sig_ok: types.JanetSignal = @intCast(constants.JANET_SIGNAL_OK);
const sig_error: types.JanetSignal = @intCast(constants.JANET_SIGNAL_ERROR);
const sig_event: types.JanetSignal = @intCast(constants.JANET_SIGNAL_EVENT);

const did_raise: i32 = @intCast(constants.JANET_FIBER_DID_RAISE);
const status_mask: i32 = @intCast(constants.JANET_FIBER_STATUS_MASK);
const status_offset: u5 = @intCast(constants.JANET_FIBER_STATUS_OFFSET);
const resume_signal: i32 = @intCast(constants.JANET_FIBER_RESUME_SIGNAL);

// ------------------------------------------------------------- try scopes

/// Open a try scope over the whole VM: six fields saved into the caller's
/// `JanetTryState`, and three redirected at it.
///
/// `stackn` is read before it is incremented, which is what the C original's
/// `state->stackn = janet_vm.stackn++` says and the one line here where the
/// order is load-bearing — `janet_restore` writes the saved value straight
/// back, so an off-by-one would leak a level of `JANET_RECURSION_GUARD` per
/// scope.
///
/// This is the wide scope, and since the hinge it is the only one: the
/// per-call scope `src/core/vm.c` kept under `-Dcall-trampoline=true` saved
/// two of these six deliberately, and went with the last `setjmp`. It is also
/// no longer opened by a `janet_try` macro, which was this call followed by a
/// `setjmp`; a caller opens a scope by calling it.
pub fn tryInit(state: *types.JanetTryState) void {
    const v = vm();
    // A report outstanding when a scope opens was left by whatever ran before
    // it. Phase 10 Part 17h added this pair of assertions after three days of
    // hunting a raise that was reported and never consumed: the symptom always
    // arrived far from the cause, as a blank value or a jump with no scope.
    // Bracketing the leak to one scope found it in a single run. They cost a
    // branch on a path the runtime rarely takes, and they go with the flag.
    if (v.c_raised != 0) fatal.fatal("a raise was reported to a C caller and never consumed");
    state.stackn = @intCast(v.stackn);
    v.stackn += 1;
    state.gc_handle = v.gc_suspend;
    state.vm_fiber = v.fiber;
    state.vm_return_reg = v.return_reg;
    state.coerce_error = v.coerce_error;
    v.return_reg = &state.payload;
    v.coerce_error = 0;
}

/// Close a try scope, whether it caught anything or not. Restoring `gc_suspend`
/// is the asymmetric one: `janet_try_init` only records it, so a callee that
/// locked the collector and then raised has its lock released here rather than
/// where it was taken.
pub fn restore(state: *types.JanetTryState) void {
    const v = vm();
    // ...and one outstanding when a scope closes was made inside it. See the
    // note in `janet_try_init`.
    if (v.c_raised != 0) fatal.fatal("a raise was reported to a C caller and never consumed");
    v.stackn = @intCast(state.stackn);
    v.gc_suspend = state.gc_handle;
    v.fiber = state.vm_fiber;
    v.return_reg = state.vm_return_reg;
    v.coerce_error = state.coerce_error;
}

// ------------------------------------------- a raise handed to a C caller

/// Record that a raise reached an abi, which returned rather than
/// jumping. Phase 10 Part 17h; `src/zig/raise.zig` has the argument.
pub fn zigCRaiseRecord() void {
    vm().c_raised = 1;
}

/// Whether a raise reached an abi since the last time this was asked.
/// Clears, because a raise is consumed exactly once.
pub fn zigCRaiseTake() c_int {
    const v = vm();
    if (v.c_raised == 0) return 0;
    v.c_raised = 0;
    return 1;
}

/// Discard any record of one, for a caller about to open a window it wants to
/// measure. `janet_try_init` does not do this: a scope and a report are
/// different things, and the ev loop opens scopes without caring.
pub fn zigCRaiseClear() void {
    vm().c_raised = 0;
}

// ---------------------------------------------------------------- raising

/// Decide what raising `sig` means here, and perform every part of it that is
/// not formatting or jumping. `out_sig` receives the signal to jump with, which
/// differs from `sig` exactly when the scope coerces.
///
/// The `sched_id` bump happens here rather than in the caller because it must
/// precede the coercion message: building that message can itself panic, and a
/// re-entrant raise must find the counter already advanced. `janet_call` in
/// `src/core/vm.c` open-codes the same three decisions on its own return path
/// and has to stay in step; its comment already says so.
pub fn signalPlan(sig: types.JanetSignal, out_sig: *types.JanetSignal) types.JanetSignalPlan {
    const v = vm();
    out_sig.* = sig;
    if (v.return_reg == null) return @intCast(constants.JANET_SIGNAL_PLAN_TOP_LEVEL);
    if (v.coerce_error != 0 and sig != sig_ok) {
        if (has_ev) {
            if (v.root_fiber) |root| {
                if (sig == sig_event) root.sched_id +%= 1;
            }
        }
        out_sig.* = sig_error;
        if (sig != sig_error) return @intCast(constants.JANET_SIGNAL_PLAN_COERCE);
    }
    return @intCast(constants.JANET_SIGNAL_PLAN_RAISE);
}

/// Publish the payload and mark the fiber, which is the last thing a raise does
/// before it becomes the caller's problem. Split from `janet_signal_plan` so
/// that the coercion message lands in the return register rather than beside
/// it — that split was drawn when only C could build the message, and it earns
/// its keep now for a different reason: the plan's `sched_id` bump has to
/// precede the formatting, and the store has to follow it.
///
/// The flag is what a resume reads to pop a C frame and to turn a raise at a
/// tail call into an implicit return, so setting it is not bookkeeping: a raise
/// that skipped it would resume differently.
///
/// **Not exported.** It was `janet_signal_commit`, declared in `state.h`, and
/// Phase 11 Part 11 found that its only caller outside this file was
/// `test/signal_core.c`. `state.h` is an internal header, so the abi went
/// with the contract and `test/signal_core.zig` reaches this by import.
pub fn signalCommit(message: *const types.Janet) void {
    const v = vm();
    v.return_reg.?.* = message.*;
    if (v.fiber) |fiber| fiber.flags |= did_raise;
}

/// Arm the innermost live fiber of a chain to raise `sig` the moment it
/// resumes, for `janet_continue_signal`.
///
/// The signal travels in `gc.flags`, not in `flags`, and that is deliberate
/// rather than a slip: `run_vm` reads it back out of `gc.flags` and clears it
/// there (`src/core/vm.c:1026-1029`), so the two halves agree, and the fiber's
/// real status in `flags` is left untouched meanwhile.
///
/// It is worth knowing what that costs, because a port must not quietly
/// "improve" it. `JANET_FIBER_STATUS_MASK` covers bits 16 through 21 of
/// `gc.flags`, and `JANET_FIBER_EV_FLAG_CANCELED`, `..._SUSPENDED` and
/// `JANET_FIBER_FLAG_ROOT` are bits 16, 17 and 18 of the same word. Clearing
/// the mask therefore clears all three. Nothing observable depends on it today
/// — `janet_schedule_general` re-sets `FLAG_ROOT` on every schedule, and the
/// fiber is running between the clear and the next schedule, so no other code
/// can look — but the aliasing is real and is recorded rather than tidied.
pub fn signalInject(fiber: *types.JanetFiber, sig: types.JanetSignal) void {
    var child: *types.JanetFiber = fiber;
    while (child.child) |next| child = next;
    // Through u64 so that a caller-supplied signal wide enough to shift bits
    // out cannot trap in a safe build. C wraps here; this wraps identically.
    const shifted: u32 = @truncate(@as(u64, sig) << status_offset);
    child.gc.flags &= ~status_mask;
    child.gc.flags |= @bitCast(shifted);
    child.flags |= resume_signal;
}

// ------------------------------------------ the decision half of a raise

/// Decide and publish a raise, without delivering it.
///
/// Phase 10 Part 2 split `janet_signalv` into this and the jump, so that a Zig
/// caller returning `error.JanetSignal` and a C caller taking the `longjmp`
/// cannot drift apart: both go through here first, and both read the signal
/// this leaves in `janet_vm.pending_signal`. `src/zig/raise.zig` is the Zig
/// side and `janet_zig_signal_deliver` in `src/core/capi.c` is the C one.
///
/// The order is the C original's, and one part of it is load-bearing rather
/// than incidental: the `sched_id` bump inside `janet_signal_plan` happens
/// *before* the coercion message is built, so a panic raised by that formatting
/// finds the counter already advanced and the return register not yet written.
/// A port must not tidy that.
///
/// Two calls here can still panic through C, which is why the file's
/// prohibition on raising is now narrower than it was rather than gone.
/// `janet_formatc` renders `%v` by running an abstract type's `tostring`
/// callback. This function holds nothing, so the jump costs nothing, and Phase
/// 10 Part 4 takes `pp.c` and removes it.
///
/// Does not return when the plan is `TOP_LEVEL`: there is no scope to raise
/// into, so `janet_top_level_signal` ends the process or the thread.
pub fn zigSignalRecord(sig: types.JanetSignal, message: types.Janet) void {
    const v = vm();
    var out_sig: types.JanetSignal = sig;
    const plan = signalPlan(sig, &out_sig);
    if (plan == @as(types.JanetSignalPlan, @intCast(constants.JANET_SIGNAL_PLAN_TOP_LEVEL))) {
        const str = pp_format.formatcReported("janet top level signal - %v\n", .{message});
        topLevelSignal(@ptrCast(str));
    }
    var payload = message;
    if (plan == @as(types.JanetSignalPlan, @intCast(constants.JANET_SIGNAL_PLAN_COERCE))) {
        payload = wrap.fromString(pp_format.formatcReported("%v coerced from %s to error", .{ message, utils.signalNames[@intCast(sig)] }));
    }
    signalCommit(&payload);
    v.pending_signal = out_sig;
}

// ------------------------------------------------ the public raise perimeter

// Phase 10 Part 5. Each of these is the abi of an entry point in
// `raise.zig` and nothing else: record the raise, then deliver it as the jump
// a C caller is waiting for. A Zig caller skips the abi and calls
// `raise.signal`, `raise.panicv` or `raise.panic` directly, which returns
// `error.JanetSignal` instead — so the two are each other's differential for
// as long as any C caller remains.
//
// `raise.panicking` does not generate these. It builds an abi for a function
// that *returns* a payload on the way through, and there is no way through
// here: the C originals are `JANET_NO_RETURN`, and the Zig entry points return
// the bare error set rather than an error union, so there is nothing to catch.
//
// This is also why the file now carries the jump-transparent marker. It always
// could be jumped through — `janet_zig_signal_record` renders a coercion
// message with `%v`, which runs an abstract type's `tostring` callback — and
// four functions whose whole body is a jump make that impossible to overlook.

pub fn signalv(sig: types.JanetSignal, message: types.Janet) void {
    raise.report(raise.signal(sig, message));
}

pub fn panicv(message: types.Janet) void {
    raise.report(raise.panicv(message));
}

pub fn panic(message: [*:0]const u8) void {
    raise.report(raise.panic(message));
}

pub fn panics(message: [*:0]const u8) void {
    raise.report(raise.panicv(wrap.fromString(message)));
}

/// `janet_top_level_signal`. The end of a raise that has no scope to land in.
///
/// It was the last symbol `capi.c` defined. The C wrote to `stdout` rather
/// than to `stderr`, which looks like a mistake and is reproduced deliberately:
/// a Janet program can redirect one and not the other.
///
/// **Nothing pins the destination**, and nothing can from inside this process:
/// every path here ends it or ends the calling thread, so a contract that
/// reached this function would not come back to assert anything. This comment
/// claimed `test/signal_core.c` pinned it and that file never did; Phase 11
/// Part 11 migrated the contract, went looking for the case, and corrected the
/// claim rather than inheriting it.
///
/// `JANET_SANDBOX_EXIT` is what makes the two endings different. Without it the
/// process ends; with it only the calling thread does, because a sandboxed
/// child interpreter must not be able to take the host down.
///
/// **The return type said `void` and every path here ends the process or the
/// thread.** `cabi.zig` declared it `noreturn` -- correctly -- and nothing
/// compared the two: increment 5c's hand-written pair list sampled 87 of the
/// 159 declarations and this was not among them. Increment 5h generates that
/// list from `cabi.zig` itself, and the disagreement was its first build's
/// output. Rule 70, at a checked-in list rather than at a tool's data.
pub fn topLevelSignal(msg: [*]const u8) noreturn {
    _ = fputs(msg, @ptrCast(@alignCast(stdio.out())));
    if ((c.vm().sandbox_flags & constants.JANET_SANDBOX_EXIT) == 0) {
        c.exit(1);
    }
    pthread_exit(null);
}

extern fn fputs(s: [*]const u8, stream: ?*anyopaque) callconv(.c) c_int;
extern fn pthread_exit(val: ?*anyopaque) callconv(.c) noreturn;
