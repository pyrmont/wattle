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
//!    caller does next is the caller's: every caller in the tree returns
//!    `error.JanetSignal` and reads what this file left in `pending_signal`,
//!    which is what stops the decision and the delivery drifting apart.
//!
//!  - **The coercion message is built here.** Rendering a Janet value runs an
//!    abstract type's `tostring` callback, which can raise, and the order that
//!    handles it is Janet's exactly: a raise *by* the formatting happens after
//!    the `sched_id` bump and before the return register is written.
//!
//!  - **A try scope is not a `setjmp`.** There is no `setjmp` anywhere in this
//!    runtime. `tryInit` points the return register at the scope's payload,
//!    which is what decides a raise has somewhere to go; the travel is an
//!    ordinary Zig `return`.

const raise = @import("../api/raise.zig");
const pp_format = @import("pp/format.zig");
const repr = @import("repr");
const constants = @import("constants");
const c = @import("cabi");
const vm_state = @import("vm/state.zig");
const stdio = @import("stdio.zig");
const wrap = @import("value/helpers/wrap.zig");
const fatal = @import("fatal.zig");
const utils = @import("utils.zig");
const abi = @import("abi");
const vm_lifecycle = @import("vm/lifecycle.zig");
const std = @import("std");
const fibers = @import("value/fibers.zig");

/// `config.ev`. A fiber carries `sched_id` in every configuration; only the
/// bump below is the event loop's, so this guards the behaviour and not the
/// field.
const has_ev = constants.JANET_VM_HAS_EV != 0;

const status_mask: i32 = @intCast(constants.JANET_FIBER_STATUS_MASK);
const status_offset: u5 = @intCast(constants.JANET_FIBER_STATUS_OFFSET);

// ------------------------------------------------------------- try scopes

/// Open a try scope over the whole VM: six fields saved into the caller's
/// `vm_state.TryState`, and three redirected at it.
///
/// `stackn` is read before it is incremented, and that is the one line here
/// where the order is load-bearing: `restore` writes the saved value straight
/// back, so an off-by-one would leak a level of `JANET_RECURSION_GUARD` per
/// scope.
///
/// This is the only protected scope there is. A caller opens one by calling
/// this and closes it with `restore`.
pub fn tryInit(state: *vm_state.TryState) void {
    const v = vm_state.current();
    // A report outstanding when a scope opens belongs to whatever ran before
    // it. This assertion and its twin in `restore` bracket an unconsumed
    // report to one scope, which is what makes it findable: the symptom
    // otherwise arrives far from the cause, as a blank value or a raise with
    // no scope. They cost a branch on a path the runtime rarely takes.
    if (v.c_raised) fatal.fatal("a raise was reported to a C caller and never consumed");
    state.stackn = v.stackn;
    v.stackn += 1;
    state.gc_handle = v.gc.suspend_count;
    state.vm_fiber = v.fiber;
    state.vm_return_reg = v.return_reg;
    state.coerce_error = v.coerce_error;
    v.return_reg = &state.payload;
    v.coerce_error = false;
}

/// Close a try scope, whether it caught anything or not. Restoring `gc_suspend`
/// is the asymmetric one: `tryInit` only records it, so a callee that
/// locked the collector and then raised has its lock released here rather than
/// where it was taken.
pub fn restore(state: *vm_state.TryState) void {
    const v = vm_state.current();
    // ...and one outstanding when a scope closes was made inside it. See the
    // note in `tryInit`.
    if (v.c_raised) fatal.fatal("a raise was reported to a C caller and never consumed");
    v.stackn = state.stackn;
    v.gc.suspend_count = state.gc_handle;
    v.fiber = state.vm_fiber;
    v.return_reg = state.vm_return_reg;
    v.coerce_error = state.coerce_error;
}

// ------------------------------------------- a raise handed to a C caller

/// Record that a raise reached an abi, which returned rather than jumping.
/// `src/api/raise.zig` has the argument.
pub fn cRaiseRecord() void {
    vm_state.current().c_raised = true;
}

/// Whether a raise reached an abi since the last time this was asked.
/// Clears, because a raise is consumed exactly once.
pub fn cRaiseTake() bool {
    const v = vm_state.current();
    if (!v.c_raised) return false;
    v.c_raised = false;
    return true;
}

// ---------------------------------------------------------------- raising

/// What `signalPlan` decides. It is this file's because nothing outside the
/// raise protocol names it and no symbol carries it: `tools/check/exports.txt`
/// has no row for it.
pub const Plan = enum(c_uint) {
    /// No protected scope above, so the raise ends the process.
    top_level = 0,
    /// Deliver the signal as it stands.
    raise = 1,
    /// Deliver it as an error instead, which is what `coerce_error` asks for.
    coerce = 2,
};

/// The plan and the signal it decides, together: the coercion that answers
/// `.coerce` is the same step that turns the signal into an `error`, so the
/// two are never produced apart.
pub const Decision = struct {
    plan: Plan,
    signal: abi.Signal,
};

/// Decide what raising `sig` means here, and perform every part of it that is
/// not formatting or jumping. The answer carries the signal to raise with,
/// which differs from `sig` exactly when the scope coerces.
///
/// The `sched_id` bump happens here rather than in the caller because it must
/// precede the coercion message: building that message can itself panic, and a
/// re-entrant raise must find the counter already advanced. `vm/entry.zig`'s
/// `call` open-codes the same three decisions on its own return path and has
/// to stay in step; its comment says so.
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

/// Publish the payload and mark the fiber, which is the last thing a raise does
/// before it becomes the caller's problem. Separate from `signalPlan` because
/// the plan's `sched_id` bump has to precede the coercion message's formatting
/// and this store has to follow it.
///
/// The flag is what a resume reads to pop a C frame and to turn a raise at a
/// tail call into an implicit return, so setting it is not bookkeeping: a raise
/// that skipped it would resume differently.
///
/// **Not exported.** `test/signal_core.zig` reaches it by import.
pub fn signalCommit(message: *const repr.Value) void {
    const v = vm_state.current();
    v.return_reg.?.* = message.*;
    if (v.fiber) |fiber| fiber.flags.did_raise = true;
}

/// Arm the innermost live fiber of a chain to raise `sig` the moment it
/// resumes, for `vm/entry.zig`'s `continueSignal`.
///
/// The signal travels in `gc.flags`, not in `flags`, and that is deliberate
/// rather than a slip: the interpreter reads it back out of `gc.flags` and
/// clears it there, so the two halves agree, and the fiber's real status in
/// `flags` is left untouched meanwhile.
///
/// It costs an aliasing that is worth knowing before anyone tidies it.
/// `JANET_FIBER_STATUS_MASK` covers bits 16 through 21 of
/// `gc.flags`, and `JANET_FIBER_EV_FLAG_CANCELED`, `..._SUSPENDED` and
/// `JANET_FIBER_FLAG_ROOT` are bits 16, 17 and 18 of the same word. Clearing
/// the mask therefore clears all three. Nothing observable depends on it today
/// — `ev.zig`'s `scheduleGeneral` re-sets `FLAG_ROOT` on every schedule, and
/// the fiber is running between the clear and the next schedule, so no other
/// code can look — but the aliasing is real and is recorded rather than
/// tidied.
pub fn signalInject(fiber: *fibers.Fiber, sig: abi.Signal) void {
    var child: *fibers.Fiber = fiber;
    while (child.child) |next| child = next;
    // The signal goes into the *GC header's* copy of the status field, which
    // is `vm.zig`'s reason for reading it back with `@enumFromInt`. `own` is
    // six bits and `@truncate` is what keeps a signal number too wide for them
    // from trapping a safe build.
    child.gc.flags.own = @truncate(@intFromEnum(sig));
    child.flags.resume_signal = true;
}

// ------------------------------------------ the decision half of a raise

/// Decide and publish a raise, without delivering it.
///
/// This is the decision half; the delivery is the caller's, and every caller
/// delivers by returning `error.JanetSignal` after reading the signal this
/// leaves in the VM's `pending_signal`.
///
/// The order is Janet's, and one part of it is load-bearing rather than
/// incidental: the `sched_id` bump inside `signalPlan` happens *before* the
/// coercion message is built, so a panic raised by that formatting finds the
/// counter already advanced and the return register not yet written. Do not
/// tidy that.
///
/// Does not return when the plan is `TOP_LEVEL`: there is no scope to raise
/// into, so `topLevelSignal` below ends the process or the thread.
pub fn signalRecord(sig: abi.Signal, message: repr.Value) void {
    const v = vm_state.current();
    const decision = signalPlan(sig);
    const plan = decision.plan;
    // Both messages are built by the formatter, and `%v` runs an abstract
    // type's `tostring`, so both can raise. Neither can carry one: this is the
    // decision half of a raise, and a second raise recorded from inside it
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

// ------------------------------------------------ the public raise perimeter

// Each of these is the abi of an entry point in `raise.zig` and nothing else:
// record the raise, then report it. A Zig caller skips the abi and calls
// `raise.signal`, `raise.panicv` or `raise.panic` directly, which returns
// `error.JanetSignal` instead.
//
// `raise.panicking` does not generate these. It builds an abi for a function
// that *returns* a payload on the way through, and there is no way through
// here: the Zig entry points return the bare error set rather than an error
// union, so there is nothing to catch.

pub fn signalv(sig: abi.Signal, message: repr.Value) void {
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

/// The end of a raise that has no scope to land in.
///
/// It writes to `stdout` rather than to `stderr`, which looks like a mistake
/// and is reproduced deliberately: a Janet program can redirect one and not
/// the other.
///
/// **Nothing pins the destination**, and nothing can from inside this process:
/// every path here ends it or ends the calling thread, so a contract that
/// reached this function would not come back to assert anything.
///
/// `JANET_SANDBOX_EXIT` is what makes the two endings different. Without it the
/// process ends; with it only the calling thread does, because a sandboxed
/// child interpreter must not be able to take the host down.
pub fn topLevelSignal(msg: [*]const u8) noreturn {
    _ = c.fputs(@ptrCast(msg), stdio.out());
    if (!vm_state.current().sandbox_flags.intersects(vm_lifecycle.Sandbox.of(&.{"exit"}))) {
        c.exit(1);
    }
    c.pthread_exit(null);
}

/// A set of signals, one bit per `abi.Signal`.
///
/// A fiber's flag word carries one in its low fourteen bits: the signals it
/// *traps* rather than propagating to its caller. The bit positions are the
/// signal numbers, so the set and the enum cannot drift, and the `comptime`
/// block below is what says so.
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

comptime {
    // Every member's bit is its signal number, which is what makes `has` a
    // shift rather than a switch.
    for (@typeInfo(SignalSet).@"struct".fields, 0..) |f, i| {
        if (!std.mem.eql(u8, f.name, @typeInfo(abi.Signal).@"enum".fields[i].name))
            @compileError("SignalSet and abi.Signal disagree at bit " ++ f.name);
    }
}
