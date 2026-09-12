//! Try scopes and the decision half of raising a signal: the six VM fields a
//! protected call saves and restores, what a raise decides before it is
//! delivered, and the signal a scheduler injects into a fiber it is about to
//! resume.
//!
//! Nothing here raises, and nothing here jumps. Both halves are load bearing.
//!
//! - Deciding and delivering are separate. `signalRecord` is the whole
//!   decision: the null test on the return register, the coercion predicate,
//!   the event bump of the root fiber's `sched_id`, the store into the return
//!   register, and the fiber's `did_raise` flag. What a caller does next is the
//!   caller's, and every caller in the tree returns `error.JanetSignal` and
//!   reads what this file left in `pending_signal`, which is what stops the
//!   decision and the delivery drifting apart.
//!
//! - The coercion message is built here. Rendering a Janet value runs an
//!   abstract type's `tostring` callback, which can raise, and the order that
//!   handles it is Janet's exactly: a raise by the formatting happens after the
//!   `sched_id` bump and before the return register is written.
//!
//! - A try scope is not a `setjmp`. There is no `setjmp` anywhere in this
//!   runtime. `tryInit` points the return register at the scope's payload,
//!   which is what decides a raise has somewhere to land, and the travel is an
//!   ordinary Zig `return`.

// ==========================================================================
// Standard library imports
// ==========================================================================

const builtin = @import("builtin");
const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const c = @import("cabi");
const constants = @import("constants");
const fatal = @import("fatal.zig");
const fibers = @import("value/fibers.zig");
const pp_format = @import("pp/format.zig");
const raise = @import("../api/raise.zig");
const repr = @import("repr");
const stdio = @import("stdio.zig");
const utils = @import("utils.zig");
const vm_lifecycle = @import("vm/lifecycle.zig");
const vm_state = @import("vm/state.zig");
const wrap = @import("value/helpers/wrap.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// Whether this build has the event loop. A fiber has `sched_id` in every
/// configuration; only the bump in `signalPlan` is the loop's, so this guards
/// the behaviour and not the field.
const has_ev = constants.JANET_VM_HAS_EV != 0;

// ==========================================================================
// Types
// ==========================================================================

/// The plan and the signal it decides, together.
///
/// `signalPlan` returns a `Decision`. The coercion that gives `.coerce` is
/// the same step that turns the signal into an error, so the two are never
/// produced apart.
pub const Decision = struct {
    plan: Plan,
    signal: abi.Signal,
};

/// What `signalPlan` decides.
///
/// It is this file's because nothing outside the raise protocol names a plan
/// and no symbol takes one: `tools/check/exports.txt` has no row for it.
pub const Plan = enum(c_uint) {
    /// No protected scope above, so the raise ends the process.
    top_level = 0,
    /// Deliver the signal as it stands.
    raise = 1,
    /// Deliver it as an error instead, which is what `coerce_error` asks for.
    coerce = 2,
};

/// A set of signals, one bit per `abi.Signal`.
///
/// A fiber's low fourteen flag bits are one such set: the signals it traps
/// rather than propagating to its caller. The bit positions are the signal
/// numbers, so the set and the enum cannot drift, and the block under Tests is
/// what says so.
pub const SignalSet = packed struct(u14) {
    ok: bool = false,
    @"error": bool = false,
    debug: bool = false,
    yield: bool = false,
    user0: bool = false,
    user1: bool = false,
    user2: bool = false,
    user3: bool = false,
    user4: bool = false,
    user5: bool = false,
    user6: bool = false,
    user7: bool = false,
    user8: bool = false,
    user9: bool = false,

    pub const none: SignalSet = .{};

    /// The ten user signals: `user0` through `user9`, bits 4 through 13.
    pub const user = fromBits(0x3FF0 >> 0);

    pub inline fn fromBits(value: u14) SignalSet {
        return @bitCast(value);
    }

    pub inline fn bits(self: SignalSet) u14 {
        return @bitCast(self);
    }

    /// Whether this set traps `s`.
    pub inline fn has(self: SignalSet, s: abi.Signal) bool {
        return (self.bits() >> @intCast(@intFromEnum(s))) & 1 != 0;
    }

    pub inline fn with(self: SignalSet, s: abi.Signal) SignalSet {
        return fromBits(self.bits() | (@as(u14, 1) << @intCast(@intFromEnum(s))));
    }

    /// The comptime set constructor, so a mask reads as the signals in it.
    pub fn of(comptime signals: []const abi.Signal) SignalSet {
        comptime var m: u14 = 0;
        inline for (signals) |sig| m |= @as(u14, 1) << @intCast(@intFromEnum(sig));
        return comptime fromBits(m);
    }
};

// ==========================================================================
// Public functions
// ==========================================================================

/// Records that a raise reached an abi, which returned rather than jumping.
///
/// `api/raise.zig` has the argument for why an abi returns.
pub fn cRaiseRecord() void {
    vm_state.current().c_raised = true;
}

/// Returns whether a raise reached an abi since this was last asked, and
/// clears the flag.
///
/// It clears because a raise is consumed exactly once.
pub fn cRaiseTake() bool {
    const v = vm_state.current();
    if (!v.c_raised) return false;
    v.c_raised = false;
    return true;
}

/// The abis of `api/raise.zig`'s entry points: record the raise, then report
/// it.
///
/// `sig` is the signal where there is one, and `message` the value that goes
/// with it. A Zig caller skips these and calls `raise.signal`, `raise.panicv`
/// or `raise.panic` directly, which returns `error.JanetSignal` instead.
///
/// `raise.panicking` does not generate them. It builds an abi for a function
/// that returns a payload on the way through, and there is no way through
/// here: these return no error union, so there is nothing to catch.
pub fn panic(message: [*:0]const u8) void {
    raise.report(raise.panic(message));
}

pub fn panics(message: [*:0]const u8) void {
    raise.report(raise.panicv(wrap.fromString(message)));
}

pub fn panicv(message: repr.Value) void {
    raise.report(raise.panicv(message));
}

pub fn signalv(sig: abi.Signal, message: repr.Value) void {
    raise.report(raise.signal(sig, message));
}

/// Closes a try scope, whether it caught anything or not.
///
/// `state` is the scope `tryInit` filled. Restoring `gc_suspend` is the
/// asymmetric one: `tryInit` only records it, so a callee that locked the
/// collector and then raised has its lock released here rather than where it
/// was taken.
pub fn restore(state: *vm_state.TryState) void {
    // Captured, for the reason `tryInit` gives.
    const v = vm_state.pinned();
    // ...and one outstanding when a scope closes was made inside it. See the
    // note in `tryInit`.
    if (v.c_raised) fatal.fatal("a raise was reported across the C ABI and never consumed");
    v.stackn = state.stackn;
    v.gc.suspend_count = state.gc_handle;
    v.fiber = state.vm_fiber;
    v.return_reg = state.vm_return_reg;
    v.coerce_error = state.coerce_error;
}

/// Publishes the payload and marks the fiber, which is the last thing a raise
/// does before it becomes the caller's problem.
///
/// `message` is the payload. This is separate from `signalPlan` because the
/// plan's `sched_id` bump has to precede the coercion message's formatting and
/// this store has to follow it.
///
/// The flag is what a resume reads to pop a C frame and to turn a raise at a
/// tail call into an implicit return, so setting it is not bookkeeping: a raise
/// that skipped it would resume differently.
///
/// Not exported. `test/signal_core.zig` reaches it by import.
pub fn signalCommit(message: *const repr.Value) void {
    const v = vm_state.current();
    v.return_reg.?.* = message.*;
    if (v.fiber) |fiber| fiber.flags.did_raise = true;
}

/// Arms the innermost live fiber of a chain to raise `sig` the moment it
/// resumes.
///
/// `fiber` is the head of the chain and `sig` the signal.
/// `vm/entry.zig`'s `continueSignal` is what reads it back.
///
/// The signal travels in `gc.flags` rather than in `flags`, and that is
/// deliberate: the interpreter reads it back out of `gc.flags` and clears it
/// there, so the two halves agree, and the fiber's real status in `flags` is
/// left untouched meanwhile.
///
/// It costs an aliasing worth knowing before anyone tidies it.
/// `JANET_FIBER_STATUS_MASK` covers bits 16 through 21 of `gc.flags`, and
/// `JANET_FIBER_EV_FLAG_CANCELED`, `JANET_FIBER_EV_FLAG_SUSPENDED` and
/// `JANET_FIBER_FLAG_ROOT` are bits 16, 17 and 18 of the same word, so
/// clearing the mask clears all three. Nothing observable depends on it today,
/// because `ev.zig`'s `scheduleGeneral` re-sets the root flag on every schedule
/// and the fiber is running between the clear and the next schedule, but the
/// aliasing is real and is recorded rather than tidied.
pub fn signalInject(fiber: *fibers.Fiber, sig: abi.Signal) void {
    var child: *fibers.Fiber = fiber;
    while (child.child) |next| child = next;
    // The signal goes into the *GC header's* copy of the status field, which
    // is `vm.zig`'s reason for reading it back with `@enumFromInt`. `own` is
    // six bits and `@truncate` is what stops a signal number too wide for them
    // from trapping a safe build.
    child.gc.flags.own = @truncate(@intFromEnum(sig));
    child.flags.resume_signal = true;
}

/// Decides what raising `sig` means here, and performs every part of it that
/// is not formatting or jumping.
///
/// `sig` is the signal. The result names the signal to raise with, which
/// differs from `sig` exactly when the scope coerces.
///
/// The `sched_id` bump happens here rather than in the caller because it must
/// precede the coercion message: building that message can itself panic, and a
/// re-entrant raise must find the counter already advanced. `vm/entry.zig`'s
/// `call` writes the same three decisions out on its own return path and has
/// to stay in step with this.
pub fn signalPlan(sig: abi.Signal) Decision {
    const v = vm_state.current();
    if (v.return_reg == null) return .{ .plan = .top_level, .signal = sig };
    if (v.coerce_error and sig != .ok) {
        if (has_ev) {
            if (v.root_fiber) |root| {
                if (sig == abi.Signal.event) root.sched_id +%= 1;
            }
        }
        if (sig != .@"error") return .{ .plan = .coerce, .signal = .@"error" };
        return .{ .plan = .raise, .signal = .@"error" };
    }
    return .{ .plan = .raise, .signal = sig };
}

/// Decides and publishes a raise, without delivering it.
///
/// `sig` is the signal and `message` the value that goes with it. The delivery
/// is the caller's, and every caller delivers by returning `error.JanetSignal`
/// after reading the signal this leaves in the VM's `pending_signal`. This
/// function does not return when the plan is `.top_level`: there is no scope to
/// raise into, so `topLevelSignal` ends the process or the thread.
///
/// The order is Janet's, and one part of it is load-bearing rather than
/// incidental: the `sched_id` bump inside `signalPlan` happens before the
/// coercion message is built, so a panic raised by that formatting finds the
/// counter already advanced and the return register not yet written.
pub fn signalRecord(sig: abi.Signal, message: repr.Value) void {
    const v = vm_state.current();
    const decision = signalPlan(sig);
    const plan = decision.plan;
    // Both messages are built by the formatter, and `%v` runs an abstract
    // type's `tostring`, so both can raise. Neither can take a raise: this is
    // the decision half of a raise, and a second raise recorded from inside it
    // would overwrite the `pending_signal` and the return register the first
    // one is in the middle of committing. So a raise here aborts at the site.
    if (plan == .top_level) {
        const str = raise.total(pp_format.formatc("janet top level signal - %v\n", .{message}), "a top-level signal's message");
        topLevelSignal(@ptrCast(str));
    }
    var payload = message;
    if (plan == .coerce) {
        payload = wrap.fromString(raise.total(
            pp_format.formatc("%v coerced from %s to error", .{ message, utils.signalNames[@intFromEnum(sig)] }),
            "a coerced signal's message",
        ));
    }
    signalCommit(&payload);
    v.pending_signal = decision.signal;
}

/// Ends a raise that has no scope to land in.
///
/// `msg` is the already-formatted message. This function does not return.
///
/// It writes to `stdout` rather than to `stderr`, which looks like a mistake
/// and is reproduced deliberately: a Janet program can redirect one and not the
/// other. Nothing pins the destination, and nothing can from inside this
/// process, because every path here ends the process or the calling thread and
/// a contract that reached this function would not come back to assert
/// anything.
///
/// The sandbox's exit capability is what makes the two endings different.
/// Without it the process ends; with it only the calling thread does, because a
/// sandboxed child interpreter must not be able to take the host down. A WASI
/// build has one thread and no `pthread_exit`, so there the process ends either
/// way, with the status the other ending uses.
pub fn topLevelSignal(msg: [*]const u8) noreturn {
    _ = c.fputs(@ptrCast(msg), stdio.out());
    if (builtin.os.tag == .wasi) {
        c.exit(1);
    } else {
        if (!vm_state.current().sandbox_flags.intersects(vm_lifecycle.Sandbox.of(&.{"exit"}))) {
            c.exit(1);
        }
        c.pthread_exit(null);
    }
}

/// Opens a try scope over the whole VM: six fields saved into the caller's
/// `vm_state.TryState`, and three redirected at it.
///
/// `state` is the caller's scope. `stackn` is read before it is incremented,
/// and that is the one line here where the order is load-bearing: `restore`
/// writes the saved value straight back, so an off-by-one would leak a level of
/// the recursion guard per scope.
///
/// This is the only protected scope there is. A caller opens one by calling
/// this and closes it with `restore`.
pub fn tryInit(state: *vm_state.TryState) void {
    // Captured rather than fetched per use: eight VM fields are read below and
    // on Darwin an uncaptured `current()` is a `_tlv_get_addr` call at each of
    // them. Every resume opens a scope, so `vm/entry.zig`'s `continueNoCheck`
    // pays these per resume. `vm_state.pinned` has the mechanism.
    const v = vm_state.pinned();
    // A report outstanding when a scope opens belongs to whatever ran before
    // it. This assertion and its twin in `restore` bracket an unconsumed
    // report to one scope, which is what makes it findable: the symptom
    // otherwise arrives far from the cause, as a blank value or a raise with
    // no scope. They cost a branch on a path the runtime rarely takes.
    if (v.c_raised) fatal.fatal("a raise was reported across the C ABI and never consumed");
    state.stackn = v.stackn;
    v.stackn += 1;
    state.gc_handle = v.gc.suspend_count;
    state.vm_fiber = v.fiber;
    state.vm_return_reg = v.return_reg;
    state.coerce_error = v.coerce_error;
    v.return_reg = &state.payload;
    v.coerce_error = false;
}

// ==========================================================================
// Tests
// ==========================================================================

comptime {
    // Every member's bit is its signal number, which is what makes `has` a
    // shift rather than a switch.
    for (@typeInfo(SignalSet).@"struct".fields, 0..) |f, i| {
        if (!std.mem.eql(u8, f.name, @typeInfo(abi.Signal).@"enum".fields[i].name))
            @compileError("SignalSet and abi.Signal disagree at bit " ++ f.name);
    }
}
