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
//!    into the return register, and `JANET_FIBER_DID_LONGJUMP`. `src/core/capi.c`
//!    keeps the three lines that jump. That is not a limitation of Zig — Zig
//!    can call `_longjmp` — but a jump out of a Zig frame is the thing this
//!    phase exists to remove, and it is what Phase 10 deletes outright. Porting
//!    it would be work with a known expiry; porting the decision is not,
//!    because a tagged signal-and-payload result still has to make every one of
//!    these choices.
//!
//!  - **The coercion message stays in C.** `janet_formatc("%v coerced from %s
//!    to error", ...)` renders a Janet value, which runs an abstract type's
//!    `tostring` callback, which can panic. So `janet_signal_plan` reports that
//!    a message is needed and stops. C builds it and hands it back to
//!    `janet_signal_commit`. The order is the C original's exactly, including
//!    the case that matters: a panic raised *by* the formatting happens after
//!    the `sched_id` bump and before the return register is written, in both
//!    implementations.
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
const abi = @import("abi");
const c = abi.c;

/// `JANET_VM_HAS_EV` in `src/zig/state_abi.h`. The `sched_id` bump below is
/// inside `#ifdef JANET_EV` in the C original; the field itself is
/// unconditional in `JanetFiber`, so only the behaviour is guarded.
const has_ev = c.JANET_VM_HAS_EV != 0;

/// `janet_vm` as `src/core/state.h` declares it, resolved through `abi.zig`.
inline fn vm() *c.JanetVM {
    return &c.janet_vm;
}

/// `JanetSignal` translates as `c_uint` while the signal constants translate as
/// `c_int`, so every comparison would otherwise need a cast at the use site.
const sig_ok: c.JanetSignal = @intCast(c.JANET_SIGNAL_OK);
const sig_error: c.JanetSignal = @intCast(c.JANET_SIGNAL_ERROR);
const sig_event: c.JanetSignal = @intCast(c.JANET_SIGNAL_EVENT);

const did_longjmp: i32 = @intCast(c.JANET_FIBER_DID_LONGJUMP);
const status_mask: i32 = @intCast(c.JANET_FIBER_STATUS_MASK);
const status_offset: u5 = @intCast(c.JANET_FIBER_STATUS_OFFSET);
const resume_signal: i32 = @intCast(c.JANET_FIBER_RESUME_SIGNAL);

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
/// Note what this is *not*: the per-call scope `src/core/vm.c` uses under
/// `-Dcall-trampoline=true` saves two of these six deliberately, for reasons
/// recorded beside it. This is the wide scope, and it is the one the public
/// `janet_try` macro opens.
export fn janet_try_init(state: *c.JanetTryState) callconv(.c) void {
    const v = vm();
    state.stackn = @intCast(v.stackn);
    v.stackn += 1;
    state.gc_handle = v.gc_suspend;
    state.vm_fiber = v.fiber;
    state.vm_jmp_buf = v.signal_buf;
    state.vm_return_reg = v.return_reg;
    state.coerce_error = v.coerce_error;
    v.return_reg = &state.payload;
    v.signal_buf = &state.buf;
    v.coerce_error = 0;
}

/// Close a try scope, whether it caught anything or not. Restoring `gc_suspend`
/// is the asymmetric one: `janet_try_init` only records it, so a callee that
/// locked the collector and then raised has its lock released here rather than
/// where it was taken.
export fn janet_restore(state: *c.JanetTryState) callconv(.c) void {
    const v = vm();
    v.stackn = @intCast(state.stackn);
    v.gc_suspend = state.gc_handle;
    v.fiber = state.vm_fiber;
    v.signal_buf = state.vm_jmp_buf;
    v.return_reg = state.vm_return_reg;
    v.coerce_error = state.coerce_error;
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
export fn janet_signal_plan(sig: c.JanetSignal, out_sig: *c.JanetSignal) callconv(.c) c.JanetSignalPlan {
    const v = vm();
    out_sig.* = sig;
    if (v.return_reg == null) return @intCast(c.JANET_SIGNAL_PLAN_TOP_LEVEL);
    if (v.coerce_error != 0 and sig != sig_ok) {
        if (has_ev) {
            if (v.root_fiber != null and sig == sig_event) {
                v.root_fiber.*.sched_id +%= 1;
            }
        }
        out_sig.* = sig_error;
        if (sig != sig_error) return @intCast(c.JANET_SIGNAL_PLAN_COERCE);
    }
    return @intCast(c.JANET_SIGNAL_PLAN_RAISE);
}

/// Publish the payload and mark the fiber, immediately before the caller jumps.
/// Split from `janet_signal_plan` so that the coercion message — which only C
/// may build — lands in the return register rather than beside it.
///
/// The flag is what a resume reads to pop a C frame and to turn a raise at a
/// tail call into an implicit return, so setting it is not bookkeeping: a raise
/// that skipped it would resume differently.
export fn janet_signal_commit(message: *const c.Janet) callconv(.c) void {
    const v = vm();
    v.return_reg.* = message.*;
    if (v.fiber != null) v.fiber.*.flags |= did_longjmp;
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
export fn janet_signal_inject(fiber: *c.JanetFiber, sig: c.JanetSignal) callconv(.c) void {
    var child: *c.JanetFiber = fiber;
    while (child.child != null) child = child.child;
    // Through u64 so that a caller-supplied signal wide enough to shift bits
    // out cannot trap in a safe build. C wraps here; this wraps identically.
    const shifted: u32 = @truncate(@as(u64, sig) << status_offset);
    child.gc.flags &= ~status_mask;
    child.gc.flags |= @bitCast(shifted);
    child.flags |= resume_signal;
}
