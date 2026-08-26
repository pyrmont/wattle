//! Behavioral contract for the interpreter's entry points: the six functions
//! that stand above `run_vm` and decide whether, and in what state, the loop is
//! entered at all.
//!
//! These are the runtime's front door, and almost nothing in the Janet suites
//! looks at them directly: a suite that calls a function exercises `janet_call`
//! only in the sense that a passenger exercises an airframe. What this file
//! pins is the part the suites cannot see.
//!
//! **Reporting versus raising, per function.** Four of the six only ever
//! return a `JanetSignal`; `janet_step` and `janet_call` raise. Getting that
//! backwards for even one condition turns a recoverable error into an abort.
//!
//! **The messages.** Nine of them, compared byte for byte. The three arity
//! messages matter most, because they are the only place a C caller learns why
//! its call was rejected, and the three cases — exact, minimum, maximum — are
//! chosen by a two-branch cascade that reads plausibly when wrong.
//!
//! **The state each one leaves behind.** `checkCanResume` marks the fiber
//! errored for one of its three refusals and not for the other two.
//! `janet_pcall` writes its out-parameter before it decides whether it failed.
//! `callImpl` restores `stackn`, the gc lock, and a dirty stack on the way out.
//! `stepImpl` writes breakpoints into the shared bytecode and takes them out
//! again, so a function stepped once must still run normally afterwards. None
//! of that is visible in a return value and all of it is asserted.
//!
//! **The coercion.** `callImpl` sets `coerce_error`, so a signal the loop hands
//! back rather than raises — a yield, in practice — is turned into an error
//! with a message built there rather than in `janet_signalv`. It is the one
//! message in the runtime that names a signal, and reaching it needs a Janet
//! function called through `janet_call` rather than through `JOP_CALL`, which
//! is what the operator fallback below arranges.
//!
//! The three functions the arity messages name are given names on purpose:
//! `%v` renders an unnamed function with its address, and the point of those
//! three cases is the message, not the pointer.
//!
//! ## What the migration changed
//!
//! **The two counters are gone, and the compiler holds what they held.** The C
//! original counted raises and reports separately and compared both totals at
//! the end, because "the same refusal delivered by the wrong mechanism would
//! still carry the right message" and an `EXPECT_PANIC` that silently stopped
//! firing looked like a pass. Here the mechanism is in the *type*:
//! `janet_pcall` and `janet_continue` return a `JanetSignal` and cannot raise,
//! `stepImpl` and `callImpl` return `raise.Error!T` and `harness.raised` will
//! not compile against anything else. A refusal that changed mechanism would
//! not build, and one that stopped arriving unwraps a null at its own line.
//!
//! Two things are deliberately not pinned. The trace line's argument list holds
//! `%p` renderings of whatever was passed, which for a function or a table is
//! an address, so only the fixed prefix is compared. And `stepImpl`'s refusal
//! for a fiber with status `:alive` is unreachable: stepping requires a fiber
//! that is not running, and there is no way to hand it the current one without
//! going through a frame that has already stopped being able to.

const std = @import("std");
const config = @import("config");
const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");
const raise = @import("raise");
const harness = @import("harness.zig");

const subsystems = @import("subsystems");
const value = @import("subsystems").value;
const gc_alloc = @import("subsystems").gc_alloc;
const core_env = @import("subsystems").env;
const vm_entry_mod = @import("subsystems").vm_entry;
const wrap = @import("subsystems").value.wrap;
const vm_lifecycle = @import("subsystems").lifecycle;
const fibers = @import("subsystems").value.fibers;
const pp_describe = @import("subsystems").pp_describe;
const registry = @import("subsystems").registry;
const vm_entry = subsystems.vm_entry;
const args_core = subsystems.args;

const assert = std.debug.assert;

/// `JANET_VM_HAS_EV`, which is what `checkCanResume` reads to decide whether
/// its root-fiber refusal may name the scheduler's entry points.
const has_ev = constants.JANET_VM_HAS_EV != 0;

fn vm() *types.JanetVM {
    return c.vm();
}

var test_env: ?*types.JanetTable = null;

/// Roots whatever it produces and never unroots it, for the reason
/// `vm_calls` gives: a Janet value in a Zig local is not a root, and these
/// live across calls that compile source and intern keywords.
fn eval(source: [*:0]const u8) types.Janet {
    var out = wrap.fromNil();
    const status = core_env.dostring(test_env.?, source, "vm-entry-test", &out);
    if (status != 0) {
        std.debug.print("unexpected error from: {s}\n", .{source});
        std.debug.print("                  got: {s}\n", .{pp_describe.toString(out)});
        assert(false);
    }
    gc_alloc.gcroot(out);
    return out;
}

fn evalfn(source: [*:0]const u8) *types.JanetFunction {
    const v = eval(source);
    assert(harness.isType(v, constants.JANET_FUNCTION));
    return wrap.toFunction(v);
}

/// A fiber over `source`, rooted. Built with `janet_fiber` rather than
/// `fiber/new` so the default flags are the ones `janet_pcall` would have used.
fn fiberOver(source: [*:0]const u8) *types.JanetFiber {
    const fiber = fibers.new(evalfn(source), 64, 0, null).?;
    gc_alloc.gcroot(wrap.fromFiber(fiber));
    return fiber;
}

/// A refusal that arrives as a value. `sig` and `out` are the caller's,
/// already filled in; this only checks that the pair says what it should.
fn expectReport(sig: types.JanetSignal, out: types.Janet, message: [*:0]const u8) void {
    assert(sig == constants.JANET_SIGNAL_ERROR);
    if (!harness.stringValueIs(out, message)) {
        std.debug.print("expected: {s}\n     got: {s}\n", .{ message, pp_describe.toString(out) });
        assert(false);
    }
}

// ------------------------------------------------------------------ pcall

/// `janet_pcall` reports. Nothing it does raises, including the arity failure,
/// which is the whole reason `janet_fiber_reset` returns null instead of
/// panicking the way `janet_fiber_funcframe`'s other caller does.
fn pcallReportsRatherThanRaises() void {
    var out = wrap.fromNil();

    var sig = vm_entry_mod.pcall(evalfn("(fn [] (+ 1 2))"), 0, null, &out, null);
    assert(sig == constants.JANET_SIGNAL_OK);
    assert(harness.integerIs(out, 3));

    var args = [_]types.Janet{ harness.wrapInteger(4), harness.wrapInteger(5) };
    sig = vm_entry_mod.pcall(evalfn("(fn [a b] (* a b))"), 2, &args, &out, null);
    assert(sig == constants.JANET_SIGNAL_OK);
    assert(harness.integerIs(out, 20));

    sig = vm_entry_mod.pcall(evalfn("(fn [] (error \"boom\"))"), 0, null, &out, null);
    expectReport(sig, out, "boom");

    // The fiber `janet_pcall` builds masks yield, so a yield comes back as a
    // signal rather than propagating past it.
    sig = vm_entry_mod.pcall(evalfn("(fn [] (yield 7) 8)"), 0, null, &out, null);
    assert(sig == constants.JANET_SIGNAL_YIELD);
    assert(harness.integerIs(out, 7));
}

/// The out-parameter is written before the null check, so a caller that reuses
/// a fiber across calls sees it cleared by the failure rather than left
/// pointing at the previous one.
fn pcallWithAReusedFiber() void {
    var out = wrap.fromNil();
    var f: ?*types.JanetFiber = null;

    var sig = vm_entry_mod.pcall(evalfn("(fn [] 1)"), 0, null, &out, &f);
    assert(sig == constants.JANET_SIGNAL_OK);
    assert(f != null);
    const first = f;
    gc_alloc.gcroot(wrap.fromFiber(f.?));

    sig = vm_entry_mod.pcall(evalfn("(fn [] 2)"), 0, null, &out, &f);
    assert(sig == constants.JANET_SIGNAL_OK);
    assert(f == first); // a supplied fiber is reset, not replaced
    assert(harness.integerIs(out, 2));

    // Too few arguments for a fixed arity: the frame cannot be built, and the
    // report is a bare "arity mismatch" with no detail, unlike `janet_call`'s.
    sig = vm_entry_mod.pcall(evalfn("(fn [a b] a)"), 0, null, &out, &f);
    expectReport(sig, out, "arity mismatch");
    assert(f == null); // the out-parameter is written before the null check
}

// --------------------------------------------------------- can-resume gate

fn resumingAFiberThatCannotBe() void {
    var out = wrap.fromNil();
    var fiber = fiberOver("(fn [] 1)");

    var sig = vm_entry_mod.continueFiber(fiber, wrap.fromNil(), &out);
    assert(sig == constants.JANET_SIGNAL_OK);
    assert(fibers.status(fiber) == constants.JANET_STATUS_DEAD);

    sig = vm_entry_mod.continueFiber(fiber, wrap.fromNil(), &out);
    expectReport(sig, out, "cannot resume fiber with status :dead");

    // An unmasked user signal leaves the fiber in the matching status, which
    // is inside the band the gate refuses.
    fiber = fiberOver("(fn [] (signal 0 :stopped))");
    sig = vm_entry_mod.continueFiber(fiber, wrap.fromNil(), &out);
    assert(sig == constants.JANET_SIGNAL_USER0);
    assert(fibers.status(fiber) == constants.JANET_STATUS_USER0);
    sig = vm_entry_mod.continueFiber(fiber, wrap.fromNil(), &out);
    expectReport(sig, out, "cannot resume fiber with status :user0");
}

/// The recursion refusal is the only one of the three that marks the fiber,
/// and the mark is what stops a caller from retrying the same fiber forever.
fn theRecursionGuardMarksTheFiber() void {
    var out = wrap.fromNil();
    const fiber = fiberOver("(fn [] 1)");
    const saved = vm().stackn;

    assert(fibers.status(fiber) == constants.JANET_STATUS_NEW);
    vm().stackn = config.recursion_guard;
    const sig = vm_entry_mod.continueFiber(fiber, wrap.fromNil(), &out);
    vm().stackn = saved;

    expectReport(sig, out, "C stack recursed too deeply");
    assert(fibers.status(fiber) == constants.JANET_STATUS_ERROR);
}

/// `janet_continue_signal` injects the signal into the fiber before resuming
/// it, so the fiber wakes where it yielded and raises there rather than
/// receiving a value. Nothing else in the tree reaches `janet_signal_inject`
/// from outside the loop.
fn cancellingASuspendedFiber() void {
    var out = wrap.fromNil();
    var fiber = fiberOver("(fn [] (yield 1) :finished)");
    var sig = vm_entry_mod.continueFiber(fiber, wrap.fromNil(), &out);
    assert(sig == constants.JANET_SIGNAL_YIELD);
    assert(harness.integerIs(out, 1));

    sig = vm_entry_mod.continueSignal(fiber, value.fromBytes("stop", .string), &out, constants.JANET_SIGNAL_ERROR);
    expectReport(sig, out, "stop");
    assert(fibers.status(fiber) == constants.JANET_STATUS_ERROR);

    // `JANET_SIGNAL_OK` injects nothing and resumes normally, which is the
    // branch that keeps `janet_continue_signal` from being `janet_continue`
    // with an extra argument.
    fiber = fiberOver("(fn [] (yield 1) :finished)");
    assert(vm_entry_mod.continueFiber(fiber, wrap.fromNil(), &out) == constants.JANET_SIGNAL_YIELD);
    sig = vm_entry_mod.continueSignal(fiber, wrap.fromNil(), &out, constants.JANET_SIGNAL_OK);
    assert(sig == constants.JANET_SIGNAL_OK);
    assert(harness.keywordIs(out, "finished"));
}

// ------------------------------------------------------------------- step

// Stepping walks the bytecode by writing a breakpoint bit into it and taking
// it out again. The bit lives in the funcdef, which every fiber over that
// function shares, so a step that failed to restore one would leave a
// permanent breakpoint behind — which is what the second half of each case
// checks.

const max_stops = 256;

/// Steps until the fiber finishes, recording the bytecode offset it stopped at
/// each time. The offsets are the subject: a step count says only that
/// stepping happened, while the offsets say which instructions it visited.
fn stepToCompletion(fiber: *types.JanetFiber, out: *types.Janet, stops: *[max_stops]i32) raise.Raising(usize) {
    const def = harness.frame.current(fiber).func.?.def.?;
    var nstops: usize = 0;
    var sig: types.JanetSignal = undefined;
    while (true) {
        sig = try vm_entry.stepImpl(fiber, wrap.fromNil(), out);
        if (sig != constants.JANET_SIGNAL_DEBUG) break;
        assert(nstops < max_stops); // stepping did not terminate
        const pc = harness.frame.current(fiber).pc;
        stops[nstops] = @intCast((@intFromPtr(pc) - @intFromPtr(def.*.bytecode)) / @sizeOf(u32));
        nstops += 1;
    }
    assert(sig == constants.JANET_SIGNAL_OK);
    return nstops;
}

fn stoppedAt(stops: []const i32, offset: i32) bool {
    return std.mem.indexOfScalar(i32, stops, offset) != null;
}

fn steppingStraightLineCode() raise.Raising(void) {
    // Four instructions, no jumps: two loads, an add and a return.
    const source = "(fn [] (let [a 1 b 2] (+ a b)))";
    var out = wrap.fromNil();
    const fiber = fiberOver(source);
    const fun = harness.frame.current(fiber).func.?;
    var stops: [max_stops]i32 = undefined;
    const nstops = try stepToCompletion(fiber, &out, &stops);

    // Every instruction after the first is stopped at, in order. The first is
    // executed by the step that installs the breakpoint on the second, and the
    // last is a return, which is one of the four opcodes `stepImpl` declines
    // to set a breakpoint past.
    assert(nstops == @as(usize, @intCast(fun.def.?.bytecode_length - 1)));
    for (stops[0..nstops], 0..) |at, i| {
        assert(at == @as(i32, @intCast(i)) + 1); // stepping visits every instruction in order
    }
    assert(harness.integerIs(out, 3));

    // The same funcdef, run without stepping: every breakpoint was taken out.
    assert(vm_entry_mod.pcall(fun, 0, null, &out, null) == constants.JANET_SIGNAL_OK);
    assert(harness.integerIs(out, 3));
}

/// A branch has two candidate successors, and both get a breakpoint. That is
/// the only place `nextb` is ever set, and it is the difference between
/// stepping a program and stepping the parts of it that fall through.
///
/// Asserted structurally rather than by counting steps. The step count does
/// separate the two — nineteen with the second breakpoint, fifteen without —
/// but it pins the compiler's instruction selection for one expression rather
/// than the property being tested.
fn steppingAcrossBranches() raise.Raising(void) {
    const source = "(fn [] (var i 0) (while (< i 3) (++ i)) (if (= i 3) :yes :no))";
    var out = wrap.fromNil();
    const fiber = fiberOver(source);
    const fun = harness.frame.current(fiber).func.?;
    const def = fun.def.?;
    var stops: [max_stops]i32 = undefined;
    const nstops = try stepToCompletion(fiber, &out, &stops);

    assert(harness.keywordIs(out, "yes"));

    // Every Janet instruction is one word, so the bytecode can be scanned
    // directly for the first conditional jump.
    var cond: i32 = -1;
    var i: i32 = 0;
    while (i < def.*.bytecode_length) : (i += 1) {
        const operation = def.*.bytecode.?[@intCast(i)] & 0x7F;
        if (operation == harness.op(constants.JOP_JUMP_IF) or operation == harness.op(constants.JOP_JUMP_IF_NOT)) {
            cond = i;
            break;
        }
    }
    assert(cond >= 0); // the loop condition compiles to a conditional jump
    const fallthrough = cond + 1;
    const target = cond + (@as(i32, @bitCast(def.*.bytecode.?[@intCast(cond)])) >> 16);
    assert(stoppedAt(stops[0..nstops], fallthrough)); // stepped into the fallthrough
    assert(stoppedAt(stops[0..nstops], target)); // stepped into the branch target

    // The same funcdef, run without stepping: every breakpoint was taken out.
    assert(vm_entry_mod.pcall(fun, 0, null, &out, null) == constants.JANET_SIGNAL_OK);
    assert(harness.keywordIs(out, "yes"));
}

/// Stepping raises, where resuming reports, and it refuses a different set of
/// statuses: a fiber suspended on a user signal can be stepped, while a dead
/// one cannot.
fn steppingAFiberThatCannotBe() void {
    var out = wrap.fromNil();
    const dead = fiberOver("(fn [] 1)");
    const errored = fiberOver("(fn [] (error \"boom\"))");

    assert(vm_entry_mod.continueFiber(dead, wrap.fromNil(), &out) == constants.JANET_SIGNAL_OK);
    assert(harness.raised(vm_entry.stepImpl, .{ dead, wrap.fromNil(), &out }).?.says("cannot step fiber with status :dead"));

    assert(vm_entry_mod.continueFiber(errored, wrap.fromNil(), &out) == constants.JANET_SIGNAL_ERROR);
    assert(harness.raised(vm_entry.stepImpl, .{ errored, wrap.fromNil(), &out }).?.says("cannot step fiber with status :error"));
}

// ----------------------------------------------------------- entry checks

/// Both entry conditions raise, and both are reachable only from outside a
/// running fiber or with the recursion counter already at its limit.
fn callingWithoutAFiber() void {
    const fun = evalfn("(fn [] 1)");
    assert(vm().fiber == null); // top level runs outside any fiber
    assert(harness.raised(vm_entry.callImpl, .{ fun, &.{} }).?.says("janet_call failed because there is no current fiber"));
}

// ------------------------------------------------- inside a running fiber

/// Five things need `janet_vm.fiber` to be set, and the only honest way to get
/// that is to be called by the interpreter.
fn cfunProbe(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 0);

    var out = wrap.fromNil();
    const self = vm().fiber.?;

    // The fiber running this cfunction is alive, and the gate refuses it.
    var sig = vm_entry_mod.continueFiber(self, wrap.fromNil(), &out);
    expectReport(sig, out, "cannot resume fiber with status :alive");

    // A fiber marked as a task belongs to the scheduler, and the refusal names
    // the scheduler's own entry points when there is one.
    {
        const rooted = fiberOver("(fn [] 1)");
        rooted.gc.flags |= constants.JANET_FIBER_FLAG_ROOT;
        sig = vm_entry_mod.continueFiber(rooted, wrap.fromNil(), &out);
        expectReport(sig, out, if (has_ev) "cannot resume root fiber, use ev/go" else "cannot resume root fiber");
        sig = vm_entry_mod.continueSignal(rooted, wrap.fromNil(), &out, constants.JANET_SIGNAL_ERROR);
        expectReport(sig, out, if (has_ev) "cannot cancel root fiber, use ev/cancel" else "cannot cancel root fiber");
    }

    // The three arity messages. The cascade that picks between them tests
    // `min == max` first, then a minimum, and falls through to a maximum, so
    // all three shapes have to be present for any of them to be trusted.
    var args = [_]types.Janet{ harness.wrapInteger(1), harness.wrapInteger(2) };
    const fun = evalfn("(do (defn exactly-two [a b] a) exactly-two)");
    assert(harness.raised(vm_entry.callImpl, .{ fun, args[0..1] }).?.says("arity mismatch in <function exactly-two>, expected 2, got 1"));

    // `callImpl` raises on its own entry condition too, and does it before
    // touching the fiber.
    const saved = vm().stackn;
    vm().stackn = config.recursion_guard;
    assert(harness.raised(vm_entry.callImpl, .{ fun, args[0..2] }).?.says("C stack recursed too deeply"));
    vm().stackn = saved;

    // A dirty stack: values pushed above `stackstart` that `callImpl` must not
    // overwrite. It pushes a guard frame to protect them and pops it again, so
    // both the pushed value and the two stack marks survive the call.
    {
        try fibers.push(self, harness.wrapInteger(99));
        const start_before = self.*.stackstart;
        const top_before = self.*.stacktop;
        args[0] = harness.wrapInteger(4);
        const result = try vm_entry.callImpl(evalfn("(fn [x] (* x 10))"), args[0..1]);
        assert(harness.integerIs(result, 40));
        assert(self.*.stackstart == start_before); // stackstart restored
        assert(self.*.stacktop == top_before); // stacktop restored
        assert(harness.integerIs(self.*.data.?[@intCast(top_before - 1)], 99));
        self.*.stacktop = start_before;
    }

    // The gc lock is balanced across a successful call.
    {
        const before = vm().gc_suspend;
        args[0] = harness.wrapInteger(3);
        _ = try vm_entry.callImpl(evalfn("(fn [x] (+ x 1))"), args[0..1]);
        assert(vm().gc_suspend == before); // the gc lock is released
        assert(vm().stackn == saved); // stackn is restored
    }

    return wrap.fromNil();
}

fn cfunArityVariants(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 0);

    const args = [_]types.Janet{ harness.wrapInteger(1), harness.wrapInteger(2), harness.wrapInteger(3) };

    var fun = evalfn("(do (defn at-least-two [a b & rest] a) at-least-two)");
    assert(harness.raised(vm_entry.callImpl, .{ fun, args[0..1] }).?.says("arity mismatch in <function at-least-two>, expected at least 2, got 1"));

    fun = evalfn("(do (defn at-most-two [&opt a b] a) at-most-two)");
    assert(harness.raised(vm_entry.callImpl, .{ fun, args[0..3] }).?.says("arity mismatch in <function at-most-two>, expected at most 2, got 3"));

    return wrap.fromNil();
}

const cfuns = [_]types.JanetReg{
    .{ .name = "vmentry/probe", .cfun = raise.stored(&cfunProbe), .documentation = null },
    .{ .name = "vmentry/arity", .cfun = raise.stored(&cfunArityVariants), .documentation = null },
    .{ .name = null, .cfun = null, .documentation = null },
};

// ------------------------------------------------------- the coercion path

/// `callImpl` sets `coerce_error`, so a signal the loop returns rather than
/// raises becomes an error with a message naming the signal it came from.
/// Reaching it needs a Janet function entered through `janet_call`, which the
/// binary operator fallback arranges: `(+ t 1)` on a table looks up `:+` and
/// invokes it as a method, and `janet_method_invoke` calls `janet_call` for a
/// Janet function.
fn aSignalTheLoopReturnsIsCoerced() void {
    var out = wrap.fromNil();
    const sig = vm_entry_mod.pcall(
        evalfn("(fn [] (def t @{:+ (fn [self other] (yield 5))}) (+ t 1))"),
        0,
        null,
        &out,
        null,
    );
    expectReport(sig, out, "5 coerced from yield to error");
}

// ------------------------------------------------------------- the tracing

/// The trace line goes through `janet_eprintf`, which writes to the `:err`
/// dynamic binding when it holds a buffer. Only the prefix is compared: the
/// argument list renders a table and a function with `%p`, and both carry
/// addresses.
fn aTracedCall() void {
    const named = eval(
        "(do (def buf @\"\")" ++
            "    (defn adder [self other] 5)" ++
            "    (trace adder)" ++
            "    (def t @{:+ adder})" ++
            "    (with-dyns [:err buf] (+ t 1))" ++
            "    (string buf))",
    );
    const text = wrap.toString(named);
    const length: usize = @intCast(types.stringHead(text).length);
    const line = text[0..length];
    if (!std.mem.startsWith(u8, line, "trace (adder ")) {
        std.debug.print("expected a trace line for a named function, got: {s}\n", .{line});
        assert(false);
    }
    assert(line[length - 1] == '\n');
    assert(line[length - 2] == ')');

    const anon = eval(
        "(do (def buf @\"\")" ++
            "    (def t @{:+ (trace (fn [self other] 5))})" ++
            "    (with-dyns [:err buf] (+ t 1))" ++
            "    (string buf))",
    );
    const anon_text = wrap.toString(anon);
    const anon_length: usize = @intCast(types.stringHead(anon_text).length);
    if (!std.mem.startsWith(u8, anon_text[0..anon_length], "trace (<function")) {
        std.debug.print("expected a trace line for an unnamed function, got: {s}\n", .{anon_text[0..anon_length]});
        assert(false);
    }
}

// ------------------------------------------------------------------- entry

fn body() raise.Raising(void) {
    test_env = harness.coreEnv();
    registry.cfuns(test_env, null, &cfuns);

    pcallReportsRatherThanRaises();
    pcallWithAReusedFiber();

    resumingAFiberThatCannotBe();
    theRecursionGuardMarksTheFiber();
    cancellingASuspendedFiber();

    try steppingStraightLineCode();
    try steppingAcrossBranches();
    steppingAFiberThatCannotBe();

    callingWithoutAFiber();

    // Everything that needs a running fiber underneath it.
    _ = eval("(vmentry/probe)");
    _ = eval("(vmentry/arity)");

    aSignalTheLoopReturnsIsCoerced();
    aTracedCall();
}

pub fn run() void {
    harness.init();
    body() catch @panic("vm_entry: an operation raised unexpectedly");
    vm_lifecycle.deinit();

    std.debug.print("vm entry contract ok\n", .{});
}
