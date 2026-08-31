//! Try scopes and the decision half of raising a signal: the six VM fields a
//! protected call saves and restores, what a raise decides before it is
//! delivered, and the signal a scheduler injects into a fiber it is about to
//! resume.
//!
//! **Nothing here raises, and nothing here jumps.** Both halves are load
//! bearing.
//!
//!  - **Deciding and delivering are separate.** `signalRecord` at the foot of
//!    this file is the whole decision -- the null test on the return register,
//!    the coercion predicate, the `EVENT` bump of the root fiber's `sched_id`,
//!    the store into the return register, and `JANET_FIBER_DID_RAISE`. What a
//!    caller does next is the caller's: a Zig caller returns
//!    `error.JanetSignal`, and `janet_zig_signal_deliver` is three lines that
//!    read `pending_signal` and go. Both read what this file decided, which is
//!    what stops them drifting.
//!
//!  - **The coercion message is built here.** Rendering a Janet value runs an
//!    abstract type's `tostring` callback, which can raise, so this was once
//!    split: the plan reported that a message was needed and stopped, and
//!    something else built it. The order is Janet's exactly, including the case
//!    that matters -- a raise *by* the formatting happens after the `sched_id`
//!    bump and before the return register is written.
//!
//!  - **A try scope is not a `setjmp`.** There is no `setjmp` anywhere in this
//!    runtime. `tryInit` points the return register at the scope's payload,
//!    which is what decides a raise has somewhere to go; the travel is an
//!    ordinary Zig `return`.

const std = @import("std");
const raise = @import("raise");
const pp_format = @import("pp/format.zig");
const types = @import("types");
const repr = @import("repr");
const constants = @import("constants");
const c = @import("cabi");
const vm_state = @import("vm/lifecycle.zig");
const stdio = @import("stdio.zig");
const wrap = @import("value/helpers/wrap.zig");
const fatal = @import("fatal.zig");
const utils = @import("utils.zig");

/// `config.ev`. The `sched_id` bump below is
/// inside `#ifdef JANET_EV` in the C original; the field itself is
/// unconditional in `JanetFiber`, so only the behaviour is guarded.
const has_ev = constants.JANET_VM_HAS_EV != 0;

// Three `sig_*` locals stood here, and five in `ev.zig`, because a translated
// `JanetSignal` was `c_uint` while the signal constants were `c_int` -- eight
// `@intCast`s so that a comparison did not need one at every use site.
// `types.Signal` is one type with one width and the casts have nothing left to
// convert.

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
    const v = vm_state.current();
    // A report outstanding when a scope opens was left by whatever ran before
    // it. These two assertions came out of three days spent hunting a raise
    // that was reported and never consumed: the symptom always arrived far
    // from the cause, as a blank value or a jump with no scope. Bracketing the
    // leak to one scope found it in a single run. They cost a branch on a path
    // the runtime rarely takes, and they go with the flag.
    if (v.c_raised != 0) fatal.fatal("a raise was reported to a C caller and never consumed");
    state.stackn = @intCast(v.stackn);
    v.stackn += 1;
    state.gc_handle = v.gc.suspend_count;
    state.vm_fiber = v.fiber;
    state.vm_return_reg = v.return_reg;
    state.coerce_error = @intFromBool(v.coerce_error);
    v.return_reg = &state.payload;
    v.coerce_error = false;
}

/// Close a try scope, whether it caught anything or not. Restoring `gc_suspend`
/// is the asymmetric one: `janet_try_init` only records it, so a callee that
/// locked the collector and then raised has its lock released here rather than
/// where it was taken.
pub fn restore(state: *types.JanetTryState) void {
    const v = vm_state.current();
    // ...and one outstanding when a scope closes was made inside it. See the
    // note in `janet_try_init`.
    if (v.c_raised != 0) fatal.fatal("a raise was reported to a C caller and never consumed");
    v.stackn = @intCast(state.stackn);
    v.gc.suspend_count = state.gc_handle;
    v.fiber = state.vm_fiber;
    v.return_reg = state.vm_return_reg;
    v.coerce_error = state.coerce_error != 0;
}

// ------------------------------------------- a raise handed to a C caller

/// Record that a raise reached an abi, which returned rather than jumping.
/// `src/zig/raise.zig` has the argument.
pub fn zigCRaiseRecord() void {
    vm_state.current().c_raised = 1;
}

/// Whether a raise reached an abi since the last time this was asked.
/// Clears, because a raise is consumed exactly once.
pub fn zigCRaiseTake() c_int {
    const v = vm_state.current();
    if (v.c_raised == 0) return 0;
    v.c_raised = 0;
    return 1;
}

/// Discard any record of one, for a caller about to open a window it wants to
/// measure. `janet_try_init` does not do this: a scope and a report are
/// different things, and the ev loop opens scopes without caring.
pub fn zigCRaiseClear() void {
    vm_state.current().c_raised = 0;
}

// ---------------------------------------------------------------- raising

/// Decide what raising `sig` means here, and perform every part of it that is
/// not formatting or jumping. `out_sig` receives the signal to jump with, which
/// differs from `sig` exactly when the scope coerces.
///
/// The `sched_id` bump happens here rather than in the caller because it must
/// precede the coercion message: building that message can itself panic, and a
/// re-entrant raise must find the counter already advanced. `janet_call` in
/// `vm/entry.zig` open-codes the same three decisions on its own return path
/// and has to stay in step; its comment already says so.
/// What `signalPlan` decides. It is this file's rather than `types.zig`'s
/// because nothing outside the raise protocol names it and no symbol carries
/// it: `tools/check/exports.txt` has no `janet_signal_plan`.
pub const Plan = enum(c_uint) {
    /// No protected scope above, so the raise ends the process.
    top_level = 0,
    /// Deliver the signal as it stands.
    raise = 1,
    /// Deliver it as an error instead, which is what `coerce_error` asks for.
    coerce = 2,
};

pub fn signalPlan(sig: types.Signal, out_sig: *types.Signal) Plan {
    const v = vm_state.current();
    out_sig.* = sig;
    if (v.return_reg == null) return .top_level;
    if (v.coerce_error and sig != .ok) {
        if (has_ev) {
            if (v.root_fiber) |root| {
                if (sig == types.Signal.event) root.sched_id +%= 1;
            }
        }
        out_sig.* = .@"error";
        if (sig != .@"error") return .coerce;
    }
    return .raise;
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
/// **Not exported.** It was `janet_signal_commit`, declared in an internal
/// header, and its only caller outside this file was a C contract.
/// `test/signal_core.zig` reaches this by import.
pub fn signalCommit(message: *const repr.Value) void {
    const v = vm_state.current();
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
pub fn signalInject(fiber: *types.JanetFiber, sig: types.Signal) void {
    var child: *types.JanetFiber = fiber;
    while (child.child) |next| child = next;
    // Through u64 so that a caller-supplied signal wide enough to shift bits
    // out cannot trap in a safe build. C wraps here; this wraps identically.
    // The signal goes into the *GC header's* copy of the status field, which
    // is `vm.zig`'s reason for reading it back with `@enumFromInt`.
    const shifted: u32 = @truncate(@as(u64, @intFromEnum(sig)) << status_offset);
    child.gc.flags &= ~status_mask;
    child.gc.flags |= @bitCast(shifted);
    child.flags |= resume_signal;
}

// ------------------------------------------ the decision half of a raise

/// Decide and publish a raise, without delivering it.
///
/// This is the decision half; the delivery is the caller's. A Zig caller
/// returns `error.JanetSignal`, and a C caller takes the jump
/// `janet_zig_signal_deliver` performs. Both go through here first, and both
/// read the signal this leaves in the VM's `pending_signal`, which is what
/// stops them drifting apart.
///
/// The order is Janet's, and one part of it is load-bearing rather than
/// incidental: the `sched_id` bump inside `signalPlan` happens *before* the
/// coercion message is built, so a panic raised by that formatting finds the
/// counter already advanced and the return register not yet written. Do not
/// tidy that.
///
/// Does not return when the plan is `TOP_LEVEL`: there is no scope to raise
/// into, so `janet_top_level_signal` ends the process or the thread.
pub fn zigSignalRecord(sig: types.Signal, message: repr.Value) void {
    const v = vm_state.current();
    var out_sig: types.Signal = sig;
    const plan = signalPlan(sig, &out_sig);
    if (plan == .top_level) {
        const str = pp_format.formatcReported("janet top level signal - %v\n", .{message});
        topLevelSignal(@ptrCast(str));
    }
    var payload = message;
    if (plan == .coerce) {
        payload = wrap.fromString(pp_format.formatcReported("%v coerced from %s to error", .{ message, utils.signalNames[@intFromEnum(sig)] }));
    }
    signalCommit(&payload);
    v.pending_signal = out_sig;
}

// ------------------------------------------------ the public raise perimeter

// Each of these is the abi of an entry point in `raise.zig` and nothing else:
// record the raise, then deliver it as the jump a C caller is waiting for. A
// Zig caller skips the abi and calls `raise.signal`, `raise.panicv` or
// `raise.panic` directly, which returns `error.JanetSignal` instead.
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

pub fn signalv(sig: types.Signal, message: repr.Value) void {
    raise.report(raise.signal(sig, message));
}

pub fn panicv(message: repr.Value) void {
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
/// It writes to `stdout` rather than to `stderr`, which looks like a mistake
/// and is reproduced deliberately: a Janet program can redirect one and not
/// the other.
///
/// **Nothing pins the destination**, and nothing can from inside this process:
/// every path here ends it or ends the calling thread, so a contract that
/// reached this function would not come back to assert anything. A comment
/// here once claimed a contract pinned it; no contract ever did.
///
/// `JANET_SANDBOX_EXIT` is what makes the two endings different. Without it the
/// process ends; with it only the calling thread does, because a sandboxed
/// child interpreter must not be able to take the host down.
///
/// **The return type is `noreturn`, and it once said `void`.** `cabi.zig`
/// declared it `noreturn` -- correctly -- and nothing compared the two while
/// `cabi_check.zig` held a hand-written list of pairs that sampled 87 of the
/// 159 declarations. The list is generated from `cabi.zig` itself now, and
/// this disagreement was its first build's output.
pub fn topLevelSignal(msg: [*]const u8) noreturn {
    _ = fputs(msg, @ptrCast(@alignCast(stdio.out())));
    if (!vm_state.current().sandbox_flags.intersects(types.Sandbox.of(&.{"exit"}))) {
        c.exit(1);
    }
    pthread_exit(null);
}

extern fn fputs(s: [*]const u8, stream: ?*anyopaque) callconv(.c) c_int;
extern fn pthread_exit(val: ?*anyopaque) callconv(.c) noreturn;
