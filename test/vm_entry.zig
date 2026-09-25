//! Behavioral contract for the interpreter's entry points: the six functions
//! that stand above `run_vm` and decide whether, and in what state, the loop
//! is entered at all.
//!
//! These are the runtime's front door, and almost nothing in the Janet suites
//! looks at them directly: a suite that calls a function exercises `call` only
//! in the sense that a passenger exercises an airframe. What this file pins is
//! the part the suites cannot see.
//!
//! Reporting against raising, per function. Four of the six only ever return a
//! signal, and `step` and `call` raise. Getting that backwards for even one
//! condition turns a recoverable error into an abort.
//!
//! The contract compares the messages byte for byte. The three arity
//! messages matter most, because they are the only place a caller outside the
//! runtime learns why its call was rejected, and the three cases (exact,
//! minimum and maximum) are chosen by a two-branch cascade that reads
//! plausibly when wrong.
//!
//! The state each one leaves behind. `checkCanResume` marks the fiber errored
//! for one of its three refusals and not for the other two. `pcall` writes its
//! out-parameter before it decides whether it failed. `vm/entry.zig`'s `call`
//! restores `stackn`, the gc lock and a dirty stack on the way out. Its `step`
//! writes breakpoints into the shared bytecode and takes them out again, so a
//! function stepped once must still run normally afterwards. None of that is
//! visible in a return value and all of it is asserted.
//!
//! The coercion. `call` sets `coerce_error`, so a signal the loop returns
//! rather than raises, which in practice is a yield, is turned into an error
//! with a message built there rather than in `signal.signalv`. It is the one
//! message in the runtime that names a signal, and reaching it needs a Janet
//! function called through `call` rather than through `JOP_CALL`, which is
//! what the operator fallback below arranges.
//!
//! The three functions the arity messages name are given names on purpose:
//! `%v` renders an unnamed function with its address, and what those three
//! cases are about is the message rather than the pointer.
//!
//! ## The mechanism is in the type
//!
//! Nothing counts refusals here, because the type does the counting.
//! `vm_entry.pcall` and `vm_entry.continueFiber` return a `Resumed` and cannot
//! raise; `vm_entry.step` and `vm_entry.call` return `raise.Error!T`, and
//! `harness.raised` will not compile against anything else. A refusal that
//! changed mechanism would not build, and one that stopped arriving unwraps a
//! null at its own line.
//!
//! One thing is deliberately not pinned: the trace line's argument list is
//! `%p` renderings of whatever was passed, which for a function or a table is
//! an address, so only the fixed prefix is compared. All three statuses
//! `vm_entry.step` refuses are asserted: `:dead` and `:error` below, and
//! `:alive` from inside a running fiber, where `nfunProbe` is the only place
//! that can reach one.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const args_core = subsystems.args;
const config = @import("config");
const constants = @import("constants");
const core_env = @import("subsystems").env;
const expect = @import("expect.zig").expect;
const fibers = @import("subsystems").value.fibers;
const functions = @import("subsystems").value.functions;
const gc_alloc = @import("subsystems").gc_alloc;
const harness = @import("harness.zig");
const pp_describe = @import("subsystems").pp_describe;
const raise = @import("subsystems").raise;
const registry = @import("subsystems").registry;
const repr = @import("repr");
const strings = @import("subsystems").value.strings;
const subsystems = @import("subsystems");
const tables = @import("subsystems").value.tables;
const value = @import("subsystems").value;
const vm_entry = subsystems.vm_entry;
const vm_lifecycle = @import("subsystems").lifecycle;
const wrap = @import("subsystems").value.wrap;

// ==========================================================================
// Constants
// ==========================================================================

/// `vm_has_ev`, which is what `checkCanResume` reads to decide whether
/// its root-fiber refusal may name the scheduler's entry points.
const has_ev = constants.vm_has_ev != 0;
const max_stops = 256;
var test_env: ?*tables.Table = null;

// ==========================================================================
// Cases
// ==========================================================================

/// Roots whatever it produces and never unroots it, for the reason
/// `vm_calls` gives: a Janet value in a Zig local is not a root, and these
/// live across calls that compile source and intern keywords.
fn eval(source: [*:0]const u8) repr.Value {
    var out = wrap.fromNil();
    const status = core_env.dostring(test_env.?, source, "vm-entry-test", &out);
    if (status != 0) {
        std.debug.print("unexpected error from: {s}\n", .{source});
        std.debug.print("                  got: {s}\n", .{pp_describe.toString(out)});
        expect(false);
    }
    gc_alloc.gcroot(out);
    return out;
}

fn evalfn(source: [*:0]const u8) *functions.Function {
    const v = eval(source);
    expect(harness.isType(v, repr.Tag.function));
    return wrap.toFunction(v);
}

/// A fiber over `source`, rooted. Built with `fibers.new` rather than
/// `fiber/new` so the default flags are the ones `pcall` would have used.
fn fiberOver(source: [*:0]const u8) *fibers.Fiber {
    const fiber = fibers.new(evalfn(source), 64, &.{}) catch unreachable;
    gc_alloc.gcroot(wrap.fromFiber(fiber));
    return fiber;
}

/// A refusal that arrives as a value. `resumed` is the caller's, already
/// returned; this only checks that the pair says what it should.
fn expectReport(resumed: vm_entry.Resumed, message: [*:0]const u8) void {
    expect(resumed.signal == abi.Signal.@"error");
    if (!harness.stringValueIs(resumed.value, message)) {
        std.debug.print("expected: {s}\n     got: {s}\n", .{ message, pp_describe.toString(resumed.value) });
        expect(false);
    }
}

/// `vm_entry.pcall` reports. Nothing it does raises, including the arity
/// failure, which is the whole reason `fibers.reset` returns `error.Arity`
/// instead of panicking the way `fibers.funcframe`'s other caller does.
fn pcallReportsRatherThanRaises() void {
    var resumed = vm_entry.pcall(evalfn("(fn [] (+ 1 2))"), &.{}, null);
    expect(resumed.signal == abi.Signal.ok);
    expect(harness.integerIs(resumed.value, 3));

    var args = [_]repr.Value{ harness.wrapInteger(4), harness.wrapInteger(5) };
    resumed = vm_entry.pcall(evalfn("(fn [a b] (* a b))"), &args, null);
    expect(resumed.signal == abi.Signal.ok);
    expect(harness.integerIs(resumed.value, 20));

    resumed = vm_entry.pcall(evalfn("(fn [] (error \"boom\"))"), &.{}, null);
    expectReport(resumed, "boom");

    // The fiber `pcall` builds masks yield, so a yield comes back as a
    // signal rather than propagating past it.
    resumed = vm_entry.pcall(evalfn("(fn [] (yield 7) 8)"), &.{}, null);
    expect(resumed.signal == abi.Signal.yield);
    expect(harness.integerIs(resumed.value, 7));
}

/// The out-parameter is written before the null check, so a caller that reuses
/// a fiber across calls sees it cleared by the failure rather than left
/// pointing at the previous one.
fn pcallWithAReusedFiber() void {
    var f: ?*fibers.Fiber = null;

    var resumed = vm_entry.pcall(evalfn("(fn [] 1)"), &.{}, &f);
    expect(resumed.signal == abi.Signal.ok);
    expect(f != null);
    const first = f;
    gc_alloc.gcroot(wrap.fromFiber(f.?));

    resumed = vm_entry.pcall(evalfn("(fn [] 2)"), &.{}, &f);
    expect(resumed.signal == abi.Signal.ok);
    expect(f == first); // a supplied fiber is reset, not replaced
    expect(harness.integerIs(resumed.value, 2));

    // Too few arguments for a fixed arity: the frame cannot be built, and the
    // report is a bare "arity mismatch" with no detail, unlike
    // `vm_entry.call`'s.
    resumed = vm_entry.pcall(evalfn("(fn [a b] a)"), &.{}, &f);
    expectReport(resumed, "arity mismatch");
    expect(f == null); // the out-parameter is written before the null check
}

fn resumingAFiberThatCannotBe() void {
    var fiber = fiberOver("(fn [] 1)");

    var resumed = vm_entry.continueFiber(fiber, wrap.fromNil());
    expect(resumed.signal == abi.Signal.ok);
    expect(fibers.status(fiber) == fibers.FiberStatus.dead);

    resumed = vm_entry.continueFiber(fiber, wrap.fromNil());
    expectReport(resumed, "cannot resume fiber with status :dead");

    // An unmasked user signal leaves the fiber in the matching status, which
    // is inside the band the gate refuses.
    fiber = fiberOver("(fn [] (signal 0 :stopped))");
    resumed = vm_entry.continueFiber(fiber, wrap.fromNil());
    expect(resumed.signal == abi.Signal.user0);
    expect(fibers.status(fiber) == fibers.FiberStatus.user0);
    resumed = vm_entry.continueFiber(fiber, wrap.fromNil());
    expectReport(resumed, "cannot resume fiber with status :user0");
}

/// The recursion refusal is the only one of the three that marks the fiber,
/// and the mark is what stops a caller from retrying the same fiber forever.
fn theRecursionGuardMarksTheFiber() void {
    const fiber = fiberOver("(fn [] 1)");
    const saved = harness.vm().stackn;

    expect(fibers.status(fiber) == fibers.FiberStatus.new);
    harness.vm().stackn = config.recursion_guard;
    const resumed = vm_entry.continueFiber(fiber, wrap.fromNil());
    harness.vm().stackn = saved;

    expectReport(resumed, "C stack recursed too deeply");
    expect(fibers.status(fiber) == fibers.FiberStatus.@"error");
}

/// `vm_entry.continueSignal` injects the signal into the fiber before resuming
/// it, so the fiber wakes where it yielded and raises there rather than
/// receiving a value. Nothing else in the tree reaches `signal.signalInject`
/// from outside the loop.
fn cancellingASuspendedFiber() void {
    var fiber = fiberOver("(fn [] (yield 1) :finished)");
    var resumed = vm_entry.continueFiber(fiber, wrap.fromNil());
    expect(resumed.signal == abi.Signal.yield);
    expect(harness.integerIs(resumed.value, 1));

    resumed = vm_entry.continueSignal(fiber, value.fromBytes("stop", .string), abi.Signal.@"error");
    expectReport(resumed, "stop");
    expect(fibers.status(fiber) == fibers.FiberStatus.@"error");

    // `abi.Signal.ok` injects nothing and resumes normally, which is the
    // branch that keeps `continueSignal` from being `continueFiber` with an
    // extra argument.
    fiber = fiberOver("(fn [] (yield 1) :finished)");
    expect(vm_entry.continueFiber(fiber, wrap.fromNil()).signal == abi.Signal.yield);
    resumed = vm_entry.continueSignal(fiber, wrap.fromNil(), abi.Signal.ok);
    expect(resumed.signal == abi.Signal.ok);
    expect(harness.keywordIs(resumed.value, "finished"));
}

/// Steps until the fiber finishes, recording the bytecode offset it stopped at
/// each time. The offsets are the subject: a step count says only that
/// stepping happened, while the offsets say which instructions it visited.
///
/// Stepping walks the bytecode by writing a breakpoint bit into it and taking
/// it out again. The bit lives in the funcdef, which every fiber over that
/// function shares, so a step that failed to restore one would leave a
/// permanent breakpoint behind, which is what the second half of each case
/// below checks.
fn stepToCompletion(fiber: *fibers.Fiber, out: *repr.Value, stops: *[max_stops]i32) raise.Error!usize {
    const def = harness.frame.current(fiber).func.?.def.?;
    var nstops: usize = 0;
    var sig: abi.Signal = undefined;
    while (true) {
        sig = try vm_entry.step(fiber, wrap.fromNil(), out);
        if (sig != abi.Signal.debug) break;
        expect(nstops < max_stops); // stepping did not terminate
        const pc = harness.frame.current(fiber).pc.bytecode;
        stops[nstops] = @intCast((@intFromPtr(pc) - @intFromPtr(def.bytecode)) / @sizeOf(u32));
        nstops += 1;
    }
    expect(sig == abi.Signal.ok);
    return nstops;
}

fn steppingStraightLineCode() raise.Error!void {
    // Four instructions, no jumps: two loads, an add and a return.
    const source = "(fn [] (let [a 1 b 2] (+ a b)))";
    var out = wrap.fromNil();
    const fiber = fiberOver(source);
    const fun = harness.frame.current(fiber).func.?;
    var stops: [max_stops]i32 = undefined;
    const nstops = try stepToCompletion(fiber, &out, &stops);

    // Every instruction after the first is stopped at, in order. The first is
    // executed by the step that installs the breakpoint on the second, and the
    // last is a return, which is one of the four opcodes `vm_entry.step`
    // declines to set a breakpoint past.
    expect(nstops == @as(usize, @intCast(fun.def.?.bytecode_length - 1)));
    for (stops[0..nstops], 0..) |at, i| {
        expect(at == @as(i32, @intCast(i)) + 1); // stepping visits every instruction in order
    }
    expect(harness.integerIs(out, 3));

    // The same funcdef, run without stepping: every breakpoint was taken out.
    const resumed = vm_entry.pcall(fun, &.{}, null);
    expect(resumed.signal == abi.Signal.ok);
    expect(harness.integerIs(resumed.value, 3));
}

fn stoppedAt(stops: []const i32, offset: i32) bool {
    return std.mem.indexOfScalar(i32, stops, offset) != null;
}

/// A branch has two candidate successors, and both get a breakpoint. That is
/// the only place `nextb` is ever set, and it is the difference between
/// stepping a program and stepping the parts of it that fall through.
///
/// Asserted structurally rather than by counting steps. The step count does
/// separate the two, nineteen with the second breakpoint and fifteen without,
/// but it pins the compiler's instruction selection for one expression rather
/// than the property being tested.
fn steppingAcrossBranches() raise.Error!void {
    const source = "(fn [] (var i 0) (while (< i 3) (++ i)) (if (= i 3) :yes :no))";
    var out = wrap.fromNil();
    const fiber = fiberOver(source);
    const fun = harness.frame.current(fiber).func.?;
    const def = fun.def.?;
    var stops: [max_stops]i32 = undefined;
    const nstops = try stepToCompletion(fiber, &out, &stops);

    expect(harness.keywordIs(out, "yes"));

    // Every Janet instruction is one word, so the bytecode can be scanned
    // directly for the first conditional jump.
    var cond: i32 = -1;
    var i: i32 = 0;
    while (i < def.bytecode_length) : (i += 1) {
        const operation = def.instructions()[@intCast(i)] & 0x7F;
        if (operation == harness.op(constants.Opcode.jump_if) or operation == harness.op(constants.Opcode.jump_if_not)) {
            cond = i;
            break;
        }
    }
    expect(cond >= 0); // the loop condition compiles to a conditional jump
    const fallthrough = cond + 1;
    const target = cond + (@as(i32, @bitCast(def.instructions()[@intCast(cond)])) >> 16);
    expect(stoppedAt(stops[0..nstops], fallthrough)); // stepped into the fallthrough
    expect(stoppedAt(stops[0..nstops], target)); // stepped into the branch target

    // The same funcdef, run without stepping: every breakpoint was taken out.
    const resumed = vm_entry.pcall(fun, &.{}, null);
    expect(resumed.signal == abi.Signal.ok);
    expect(harness.keywordIs(resumed.value, "yes"));
}

/// Stepping raises, where resuming reports, and it refuses a different set of
/// statuses: a fiber suspended on a user signal can be stepped, while a dead
/// one cannot.
fn steppingAFiberThatCannotBe() void {
    var out = wrap.fromNil();
    const dead = fiberOver("(fn [] 1)");
    const errored = fiberOver("(fn [] (error \"boom\"))");

    expect(vm_entry.continueFiber(dead, wrap.fromNil()).signal == abi.Signal.ok);
    expect(harness.raised(vm_entry.step, .{ dead, wrap.fromNil(), &out }).?.says("cannot step fiber with status :dead"));

    expect(vm_entry.continueFiber(errored, wrap.fromNil()).signal == abi.Signal.@"error");
    expect(harness.raised(vm_entry.step, .{ errored, wrap.fromNil(), &out }).?.says("cannot step fiber with status :error"));
}

/// Both entry conditions raise, and both are reachable only from outside a
/// running fiber or with the recursion counter already at its limit.
fn callingWithoutAFiber() void {
    const fun = evalfn("(fn [] 1)");
    expect(harness.vm().fiber == null); // top level runs outside any fiber
    expect(harness.raised(vm_entry.call, .{ fun, &.{} }).?.says("call_value failed because there is no current fiber"));
}

/// Five things need `vm.fiber` to be set, and the only honest way to get
/// that is to be called by the interpreter.
fn nfunProbe(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 0);

    const self = harness.vm().fiber.?;

    // The fiber running this nfunction is alive, and both gates refuse it.
    var resumed = vm_entry.continueFiber(self, wrap.fromNil());
    expectReport(resumed, "cannot resume fiber with status :alive");

    var stepped = wrap.fromNil();
    expect(harness.raised(vm_entry.step, .{ self, wrap.fromNil(), &stepped }).?
        .says("cannot step fiber with status :alive"));

    // A fiber marked as a task belongs to the scheduler, and the refusal names
    // the scheduler's own entry points when there is one.
    {
        const rooted = fiberOver("(fn [] 1)");
        harness.gcSetBits(&rooted.gc.flags, constants.fiber_flag_root);
        resumed = vm_entry.continueFiber(rooted, wrap.fromNil());
        expectReport(resumed, if (has_ev) "cannot resume root fiber, use ev/go" else "cannot resume root fiber");
        resumed = vm_entry.continueSignal(rooted, wrap.fromNil(), abi.Signal.@"error");
        expectReport(resumed, if (has_ev) "cannot cancel root fiber, use ev/cancel" else "cannot cancel root fiber");
    }

    // A fixed arity reports its exact bound. The cases below exercise a
    // lower bound and a range through the same formatter.
    var args = [_]repr.Value{ harness.wrapInteger(1), harness.wrapInteger(2) };
    const fun = evalfn("(do (defn exactly-two [a b] a) exactly-two)");
    expect(harness.raised(vm_entry.call, .{ fun, args[0..1] }).?.says("<function exactly-two> called with 1 argument, expected 2"));

    // `vm_entry.call` raises on its own entry condition too, and does it before
    // touching the fiber. The scope `harness.raised` opens counts itself into
    // `stackn`, so one below the guard here is the guard at the call; without
    // a scope the same count is one below it at the call, and the call runs.
    const saved = harness.vm().stackn;
    harness.vm().stackn = config.recursion_guard - 1;
    expect(harness.raised(vm_entry.call, .{ fun, args[0..2] }).?.says("C stack recursed too deeply"));
    expect(harness.integerIs(try vm_entry.call(fun, args[0..2]), 1));
    harness.vm().stackn = saved;

    // A dirty stack: values pushed above `stackstart` that `vm_entry.call`
    // must not overwrite. It pushes a guard frame to protect them and pops it
    // again, so both the pushed value and the two stack marks survive the
    // call.
    {
        try fibers.push(self, harness.wrapInteger(99));
        const start_before = self.stackstart;
        const top_before = self.stacktop;
        args[0] = harness.wrapInteger(4);
        const result = try vm_entry.call(evalfn("(fn [x] (* x 10))"), args[0..1]);
        expect(harness.integerIs(result, 40));
        expect(self.stackstart == start_before); // stackstart restored
        expect(self.stacktop == top_before); // stacktop restored
        expect(harness.integerIs(self.data.?[@intCast(top_before - 1)], 99));
        self.stacktop = start_before;
    }

    // The gc lock is balanced across a successful call.
    {
        const before = harness.vm().gc.suspend_count;
        args[0] = harness.wrapInteger(3);
        _ = try vm_entry.call(evalfn("(fn [x] (+ x 1))"), args[0..1]);
        expect(harness.vm().gc.suspend_count == before); // the gc lock is released
        expect(harness.vm().stackn == saved); // stackn is restored
    }

    return wrap.fromNil();
}

fn nfunArityVariants(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 0);

    const args = [_]repr.Value{ harness.wrapInteger(1), harness.wrapInteger(2), harness.wrapInteger(3) };

    var fun = evalfn("(do (defn at-least-two [a b & rest] a) at-least-two)");
    expect(harness.raised(vm_entry.call, .{ fun, args[0..1] }).?.says("<function at-least-two> called with 1 argument, expected at least 2"));

    fun = evalfn("(do (defn at-most-two ([] nil) ([a] a) ([a _b] a)) at-most-two)");
    expect(harness.raised(vm_entry.call, .{ fun, args[0..3] }).?.says("<function at-most-two> called with 3 arguments, expected 0 to 2"));

    return wrap.fromNil();
}

fn nfunMapTail(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 0);

    const fun = evalfn("(do (defn host-map-tail [& {value :value}] value) host-map-tail)");
    const args = [_]repr.Value{harness.wrapInteger(1)};
    expect(harness.raised(vm_entry.call, .{ fun, &args }).?.says("<function host-map-tail> called with no value for key 1"));

    return wrap.fromNil();
}

/// The assembler keeps `min_arity` at or below `max_arity` and the
/// unmarshaller does not check it. With the two crossed, a call with exactly
/// the minimum is refused for passing the maximum, and says so.
///
/// An nfunction of its own because a refused call leaves its arguments pushed,
/// and a second call after it finds the stack dirty and pushes a guard frame
/// that the refusal leaves standing too.
fn nfunCrossedArity(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 0);

    const args = [_]repr.Value{ harness.wrapInteger(1), harness.wrapInteger(2), harness.wrapInteger(3) };
    const fun = evalfn("(do (defn crossed [a] a) crossed)");
    fun.def.?.min_arity = 3;
    fun.def.?.max_arity = 1;
    expect(harness.raised(vm_entry.call, .{ fun, args[0..3] }).?.says("<function crossed> called with 3 arguments, expected at most 1"));

    return wrap.fromNil();
}

/// `stackn` as a number, for a Janet function to report the depth it runs at.
fn nfunDepth(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 0);
    return harness.wrapInteger(@intCast(harness.vm().stackn));
}

const nfuns = [_]abi.Reg{
    .{ .name = "vmentry/probe", .nfun = raise.stored(&nfunProbe), .documentation = null },
    .{ .name = "vmentry/arity", .nfun = raise.stored(&nfunArityVariants), .documentation = null },
    .{ .name = "vmentry/map-tail", .nfun = raise.stored(&nfunMapTail), .documentation = null },
    .{ .name = "vmentry/crossed", .nfun = raise.stored(&nfunCrossedArity), .documentation = null },
    .{ .name = "vmentry/depth", .nfun = raise.stored(&nfunDepth), .documentation = null },
};

/// `vm_entry.call` sets `coerce_error`, so a signal the loop returns rather
/// than raises becomes an error with a message naming the signal it came from.
/// Reaching it needs a Janet function entered through `call`, which the binary
/// operator fallback arranges: `(+ t 1)` on a table looks up `:+` and invokes
/// it as a method, and `vm.methodInvoke` calls `call` for a Janet function.
fn aSignalTheLoopReturnsIsCoerced() void {
    const resumed = vm_entry.pcall(
        evalfn("(fn [] (def t !{:+ (fn [self other] (yield 5))}) (+ t 1))"),
        &.{},
        null,
    );
    expectReport(resumed, "5 coerced from yield to error");
}

/// The trace line goes through a `(dyn :err)` write, which lands in the `:err`
/// dynamic binding where that binding is a buffer. Only the prefix is
/// compared, because the argument list renders a table and a function with
/// `%p` and both give
/// addresses.
fn aTracedCall() void {
    const named = eval(
        "(do (def buf !\"\")" ++
            "    (defn adder [self other] 5)" ++
            "    (trace adder)" ++
            "    (def t !{:+ adder})" ++
            "    (with-dyns [:err buf] (+ t 1))" ++
            "    (string buf))",
    );
    const text = wrap.toString(named);
    const length: usize = strings.head(text).length;
    const line = text[0..length];
    if (!std.mem.startsWith(u8, line, "trace (adder ")) {
        std.debug.print("expected a trace line for a named function, got: {s}\n", .{line});
        expect(false);
    }
    expect(line[length - 1] == '\n');
    expect(line[length - 2] == ')');

    const anon = eval(
        "(do (def buf !\"\")" ++
            "    (def t !{:+ (trace (fn [self other] 5))})" ++
            "    (with-dyns [:err buf] (+ t 1))" ++
            "    (string buf))",
    );
    const anon_text = wrap.toString(anon);
    const anon_length: usize = strings.head(anon_text).length;
    if (!std.mem.startsWith(u8, anon_text[0..anon_length], "trace (<function")) {
        std.debug.print("expected a trace line for an unnamed function, got: {s}\n", .{anon_text[0..anon_length]});
        expect(false);
    }
}

/// `call` runs its callee one level deeper in `stackn` than its caller, and a
/// traced call counts the trace only while the trace prints. Each pair is the
/// depth read directly and the depth the operator fallback's callee reads
/// through `call`, in the same `with-dyns` body, untraced and then traced.
fn theDepthACallRunsAt() void {
    const depths = eval(
        "(do (def buf !\"\")" ++
            "    (defn probe-depth [self other] (vmentry/depth))" ++
            "    (def t !{:+ probe-depth})" ++
            "    (def plain (with-dyns [:err buf] [(vmentry/depth) (+ t 1)]))" ++
            "    (trace probe-depth)" ++
            "    (def traced (with-dyns [:err buf] [(vmentry/depth) (+ t 1)]))" ++
            "    [|plain |traced])",
    );
    const four = harness.elems(depths);
    expect(four.len == 4);
    expect(harness.integerIs(four[1], wrap.toInteger(four[0]) + 1));
    expect(harness.integerIs(four[3], wrap.toInteger(four[2]) + 1));
}

// ==========================================================================
// Entry
// ==========================================================================

fn body() raise.Error!void {
    test_env = harness.coreEnv();
    registry.nfuns(test_env, null, &nfuns);

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
    _ = eval("(vmentry/map-tail)");
    _ = eval("(vmentry/crossed)");

    aSignalTheLoopReturnsIsCoerced();
    aTracedCall();
    theDepthACallRunsAt();
}

pub fn run() void {
    harness.init();
    body() catch @panic("vm_entry: an operation raised unexpectedly");
    vm_lifecycle.deinit();
}
