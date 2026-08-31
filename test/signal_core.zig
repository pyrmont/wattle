//! Behavioral contract for the try scope, the signal decision, and the signal
//! injection.
//!
//! The reason this file exists rather than leaning on the Janet suites: the
//! suites exercise these paths constantly but observe almost none of them.
//! Every `try` in Janet opens a scope and every `error` raises through the
//! plan, yet what a program can see afterwards is the payload alone. Whether
//! `stackn` came back to the value it started from, whether `coerce_error` was
//! cleared inside the scope and restored outside it, which of fourteen signals
//! coerce and which do not, and whether the injected signal reached the
//! innermost fiber of a chain, are all invisible from Janet and all
//! load-bearing.
//!
//! ## One transport, and the assertion that went with the second
//!
//! A C contract could assert that **the two deliveries agree**: a raise
//! recorded the signal and then jumped, and the value `setjmp` returned had to
//! be the signal the record published. Two independent transports, one
//! decision, and a disagreement meant the mechanism had forked.
//!
//! There is one transport. `raise.signal` calls `signal.signalRecord` and
//! returns `error.JanetSignal`; the abi is `raise.report` over exactly that
//! expression, and `report`'s whole body is setting a flag. So the
//! "agreement" would be a definition rather than a fact, and asserting it
//! would be an assertion that cannot fail. What replaces it is narrower and
//! true: `pending_signal` is where a Zig caller reads the signal, so every
//! raising case below reads it back through `harness.raised` rather than
//! assuming the value it was given.
//!
//! ## The four public abis are still tested
//!
//! `janet_signalv`, `janet_panicv`, `janet_panic` and `janet_panics` each
//! record through `raise.signal`'s family and then hand the raise to a C
//! caller as a report. Two of them -- `janet_panicv` and `janet_panic` -- have
//! Zig callers through the C ABI in `interop.zig` and `native_module.zig`.
//! The other two have **no in-tree caller at all**, and stay because they are
//! the published perimeter: an embedder's `janet_panics` is the only thing
//! that will ever call it. A public entry point with no in-tree caller is
//! precisely the kind that rots without anything saying so.
//!
//! `harness.abiRaised` is what reads one.

const std = @import("std");
const types = @import("types");
const repr = @import("repr");
const constants = @import("constants");
const c = @import("cabi");
const raise = @import("raise");
const harness = @import("harness.zig");

const subsystems = @import("subsystems");
const value = @import("subsystems").value;
const gc_alloc = @import("subsystems").gc_alloc;
const strings = @import("subsystems").value.strings;
const core_env = @import("subsystems").env;
const vm_entry = @import("subsystems").vm_entry;
const signal_core_mod = @import("subsystems").signal;
const wrap = @import("subsystems").value.wrap;
const vm_lifecycle = @import("subsystems").lifecycle;
const fibers = @import("subsystems").value.fibers;
const signal_core = subsystems.signal;
const abstract_type = subsystems.abstract_type;
const AbstractType = abstract_type.AbstractType;

const assert = std.debug.assert;

/// Signals run from OK to USER9; INTERRUPT and EVENT are aliases of USER8 and
/// USER9 rather than values of their own, so counting the enumeration would
/// overcount.
const signal_count: c_int = @intFromEnum(types.Signal.user9) + 1;

/// `config.ev`, which is what `signal.zig` itself gates the `sched_id` bump
/// on. Reading the same fact rather than a `Selection` field is the point: the
/// behaviour is compiled in or it is not, and no subsystem name answers that.
const has_ev = constants.JANET_VM_HAS_EV != 0;

var test_env: *types.JanetTable = undefined;

fn compileFunction(source: [*:0]const u8) *types.JanetFunction {
    var out = wrap.fromNil();
    assert(core_env.dostring(test_env, source, "signal-core-test", &out) == 0);
    assert(harness.isType(out, repr.Tag.function));
    gc_alloc.gcroot(out);
    return wrap.toFunction(out);
}

fn rootedFiber(func: *types.JanetFunction) *types.JanetFiber {
    const fiber = fibers.new(func, 32, 0, null).?;
    gc_alloc.gcroot(wrap.fromFiber(fiber));
    return fiber;
}

fn unroot(fiber: *types.JanetFiber) void {
    _ = gc_alloc.gcunroot(wrap.fromFiber(fiber));
}

// ------------------------------------------------------------- try scopes

/// A scope saves six fields, redirects three, and hands all six back. The two
/// halves are tested together because a save that is never restored is not a
/// scope, and each field is checked for the value it should hold rather than
/// for having merely changed.
fn aTryScopeSavesRedirectsAndRestores() void {
    var state: types.JanetTryState = undefined;
    const old_stackn = harness.vm().stackn;
    const old_gc_suspend = harness.vm().gc.suspend_count;
    const old_fiber = harness.vm().fiber;
    const old_return_reg = harness.vm().return_reg;
    const old_coerce_error = harness.vm().coerce_error;

    // Set so that clearing it inside the scope is visible.
    harness.vm().coerce_error = true;

    signal_core_mod.tryInit(&state);

    assert(state.stackn == old_stackn);
    assert(state.gc_handle == old_gc_suspend);
    assert(state.vm_fiber == old_fiber);
    assert(state.vm_return_reg == old_return_reg);
    // `JanetTryState` is a fixed layout, so its copy of the flag stays
    // `c_int` where the VM's is a `bool`. The crossing is in `signal.zig` and
    // this is where it is asserted.
    assert(state.coerce_error == 1);

    // The recursion counter advances by exactly one. The state holds the old
    // value and the VM the new one; getting it backwards would leak one
    // `JANET_RECURSION_GUARD` level per scope, which nothing else here would
    // notice.
    assert(harness.vm().stackn == old_stackn + 1);

    assert(harness.vm().return_reg == &state.payload);
    assert(harness.vm().coerce_error == false);

    // Whatever the scope's body did to the saved fields is undone rather than
    // merged. `gc_suspend` is the one that matters in practice: a callee that
    // locked the collector and then raised has its lock released here.
    harness.vm().gc.suspend_count = old_gc_suspend + 7;
    harness.vm().stackn += 3;
    harness.vm().coerce_error = true;

    signal_core_mod.restore(&state);

    assert(harness.vm().stackn == old_stackn);
    assert(harness.vm().gc.suspend_count == old_gc_suspend);
    assert(harness.vm().fiber == old_fiber);
    assert(harness.vm().return_reg == old_return_reg);
    assert(harness.vm().coerce_error);

    harness.vm().coerce_error = old_coerce_error;
}

/// Scopes nest, and the inner one's saved fields are the outer one's live
/// fields. This is the property a fiber resumed from a different native frame
/// depends on: each resume opens a fresh scope over whatever the last one
/// left.
fn tryScopesNest() void {
    var outer: types.JanetTryState = undefined;
    var inner: types.JanetTryState = undefined;
    const base = harness.vm().stackn;
    const old_coerce_error = harness.vm().coerce_error;

    signal_core_mod.tryInit(&outer);
    assert(harness.vm().stackn == base + 1);

    signal_core_mod.tryInit(&inner);
    assert(harness.vm().stackn == base + 2);
    assert(inner.vm_return_reg == &outer.payload);

    signal_core_mod.restore(&inner);
    assert(harness.vm().stackn == base + 1);
    assert(harness.vm().return_reg == &outer.payload);

    signal_core_mod.restore(&outer);
    assert(harness.vm().stackn == base);
    harness.vm().coerce_error = old_coerce_error;
}

/// The scope and the raise end to end: `janet_try_init` points the return
/// register at this frame's payload slot, `raise.panic` decides and records,
/// and the payload arrives in the scope's own slot.
///
/// The scope is not a formality even though nothing jumps any more —
/// `janet_signal_plan` answers `TOP_LEVEL` when `return_reg` is null and a
/// `TOP_LEVEL` raise ends the process. `harness.raised` is that scope.
fn aScopeCatchesAPanic() void {
    const base = harness.vm().stackn;
    const r = harness.raised(panicWith, .{"caught me"}).?;
    assert(r.signal == types.Signal.@"error");
    assert(r.says("caught me"));
    assert(harness.vm().stackn == base);
}

// ------------------------------------------------------------ the decision

/// No return register means no jump target, so nothing is decided and nothing
/// is coerced: the caller reports at top level with the message it was given.
fn thePlanWithoutAReturnRegister() void {
    const old_return_reg = harness.vm().return_reg;
    const old_coerce_error = harness.vm().coerce_error;
    var out: types.Signal = types.Signal.ok;

    harness.vm().return_reg = null;
    // Set so that a plan which consulted it before the null test would show.
    harness.vm().coerce_error = true;

    assert(signal_core_mod.signalPlan(types.Signal.yield, &out) == signal_core_mod.Plan.top_level);
    assert(out == types.Signal.yield);

    harness.vm().return_reg = old_return_reg;
    harness.vm().coerce_error = old_coerce_error;
}

/// Outside a coercing scope every signal passes through unchanged. All
/// fourteen are checked rather than a representative few, because the coercion
/// branch below distinguishes three groups among them and the pass-through
/// branch must distinguish none.
fn thePlanWithoutCoercion() void {
    var reg = wrap.fromNil();
    const old_return_reg = harness.vm().return_reg;
    const old_coerce_error = harness.vm().coerce_error;

    harness.vm().return_reg = &reg;
    harness.vm().coerce_error = false;

    var s: c_int = 0;
    while (s < signal_count) : (s += 1) {
        const sig: types.Signal = @enumFromInt(@as(c_uint, @intCast(s)));
        var out: types.Signal = types.Signal.ok;
        assert(signal_core_mod.signalPlan(sig, &out) == signal_core_mod.Plan.raise);
        assert(out == sig);
    }

    harness.vm().return_reg = old_return_reg;
    harness.vm().coerce_error = old_coerce_error;
}

/// Inside a coercing scope the fourteen signals fall into three groups, and
/// the plan reports a different answer for each. OK is not an error and is
/// left alone; ERROR is already one and needs no message; everything else
/// becomes an error and needs the message the caller formats.
fn thePlanCoerces() void {
    var reg = wrap.fromNil();
    const old_return_reg = harness.vm().return_reg;
    const old_coerce_error = harness.vm().coerce_error;
    var out: types.Signal = undefined;

    harness.vm().return_reg = &reg;
    harness.vm().coerce_error = true;

    out = types.Signal.yield;
    assert(signal_core_mod.signalPlan(types.Signal.ok, &out) == signal_core_mod.Plan.raise);
    assert(out == types.Signal.ok);

    out = types.Signal.yield;
    assert(signal_core_mod.signalPlan(types.Signal.@"error", &out) == signal_core_mod.Plan.raise);
    assert(out == types.Signal.@"error");

    var s: c_int = @intFromEnum(types.Signal.debug);
    while (s < signal_count) : (s += 1) {
        out = types.Signal.ok;
        assert(signal_core_mod.signalPlan(@enumFromInt(@as(c_uint, @intCast(s))), &out) == signal_core_mod.Plan.coerce);
        assert(out == types.Signal.@"error");
    }

    harness.vm().return_reg = old_return_reg;
    harness.vm().coerce_error = old_coerce_error;
}

/// An EVENT signal coerced to an error invalidates the root fiber's scheduling
/// id, so that a callback which completes later cannot resume a fiber that has
/// already moved on. The bump belongs to the plan rather than to its caller
/// because it has to happen before the coercion message is built: building
/// that message can panic, and the re-entrant raise must find the counter
/// already advanced.
///
/// Three conditions gate it and each is checked separately, since any one of
/// them dropped would leave the common path working.
fn thePlanBumpsTheRootFiber(nothing: *types.JanetFunction) void {
    if (!has_ev) return;

    var reg = wrap.fromNil();
    const old_return_reg = harness.vm().return_reg;
    const old_coerce_error = harness.vm().coerce_error;
    const old_root_fiber = harness.vm().root_fiber;
    const fiber = rootedFiber(nothing);
    defer unroot(fiber);
    var out: types.Signal = undefined;

    harness.vm().return_reg = &reg;
    harness.vm().coerce_error = true;
    harness.vm().root_fiber = fiber;
    const base = fiber.sched_id;

    assert(signal_core_mod.signalPlan(types.Signal.event, &out) == signal_core_mod.Plan.coerce);
    assert(fiber.sched_id == base +% 1);

    // Only EVENT.
    assert(signal_core_mod.signalPlan(types.Signal.yield, &out) == signal_core_mod.Plan.coerce);
    assert(fiber.sched_id == base +% 1);

    // Only while coercing.
    harness.vm().coerce_error = false;
    assert(signal_core_mod.signalPlan(types.Signal.event, &out) == signal_core_mod.Plan.raise);
    assert(fiber.sched_id == base +% 1);

    // Only with a root fiber — and without one it must not dereference null.
    harness.vm().coerce_error = true;
    harness.vm().root_fiber = null;
    assert(signal_core_mod.signalPlan(types.Signal.event, &out) == signal_core_mod.Plan.coerce);
    assert(fiber.sched_id == base +% 1);

    harness.vm().root_fiber = old_root_fiber;
    harness.vm().return_reg = old_return_reg;
    harness.vm().coerce_error = old_coerce_error;
}

/// The commit publishes the payload and marks the fiber. The flag is not
/// bookkeeping: a resume reads it to pop a C frame and to turn a raise at a
/// tail call into an implicit return, so a raise that skipped it would resume
/// differently from one that set it.
///
/// Reached by import rather than by symbol, and that is the whole of what this
/// part changed about it: `janet_signal_commit` was an `export fn` with a
/// declaration in `state.h` whose only caller outside its own file was this
/// contract. It is `signalCommit` now.
fn theCommitPublishesAndMarks(nothing: *types.JanetFunction) void {
    var reg = wrap.fromNil();
    const message = value.fromBytes("payload", .string);
    const old_return_reg = harness.vm().return_reg;
    const old_fiber = harness.vm().fiber;
    const fiber = rootedFiber(nothing);
    defer unroot(fiber);

    gc_alloc.gcroot(message);
    defer _ = gc_alloc.gcunroot(message);

    fiber.flags &= ~@as(i32, constants.JANET_FIBER_DID_RAISE);
    harness.vm().return_reg = &reg;
    harness.vm().fiber = fiber;

    signal_core.signalCommit(&message);
    assert(harness.equals(reg, message));
    assert(fiber.flags & constants.JANET_FIBER_DID_RAISE != 0);

    // With no current fiber the register is still written and nothing is
    // dereferenced. `janet_zig_signal_record` reaches this whenever a panic is
    // raised outside any fiber at all.
    reg = wrap.fromNil();
    harness.vm().fiber = null;
    signal_core.signalCommit(&message);
    assert(harness.equals(reg, message));

    harness.vm().fiber = old_fiber;
    harness.vm().return_reg = old_return_reg;
}

// ------------------------------------------------------- recording a raise

// `janet_zig_signal_record` is the whole of a raise except the delivery. Its
// two observable outputs are the payload in the return register and the signal
// in `vm.pending_signal`, and the second is the one that carries: a Zig
// caller reads the signal out of that field, where under the jump it travelled
// as `longjmp`'s second argument and was never stored anywhere.

/// The ordinary case. Nothing coerces, so the message and the signal both
/// arrive unaltered, and the fiber is marked exactly as `signalCommit` marks
/// it.
fn theRecordPublishesSignalAndPayload(nothing: *types.JanetFunction) void {
    var reg = wrap.fromNil();
    const message = value.fromBytes("recorded", .string);
    const old_return_reg = harness.vm().return_reg;
    const old_fiber = harness.vm().fiber;
    const old_coerce_error = harness.vm().coerce_error;
    const fiber = rootedFiber(nothing);
    defer unroot(fiber);

    gc_alloc.gcroot(message);
    defer _ = gc_alloc.gcunroot(message);

    fiber.flags &= ~@as(i32, constants.JANET_FIBER_DID_RAISE);
    harness.vm().return_reg = &reg;
    harness.vm().fiber = fiber;
    harness.vm().coerce_error = false;
    // Scribbled first, so that a record which never writes it is caught rather
    // than passing because the field already held the value wanted.
    harness.vm().pending_signal = types.Signal.user9;

    signal_core_mod.zigSignalRecord(types.Signal.@"error", message);
    assert(harness.vm().pending_signal == types.Signal.@"error");
    assert(harness.equals(reg, message));
    assert(fiber.flags & constants.JANET_FIBER_DID_RAISE != 0);

    // A signal that does not coerce travels unaltered, which is what makes
    // `pending_signal` worth reading rather than assuming.
    harness.vm().pending_signal = types.Signal.user9;
    signal_core_mod.zigSignalRecord(types.Signal.yield, message);
    assert(harness.vm().pending_signal == types.Signal.yield);
    assert(harness.equals(reg, message));

    harness.vm().coerce_error = old_coerce_error;
    harness.vm().fiber = old_fiber;
    harness.vm().return_reg = old_return_reg;
}

/// The coercing case. Both halves are checked: the signal the caller passed is
/// replaced by ERROR, and the payload is replaced by a string naming the
/// original signal — so a port that coerced the signal but forwarded the
/// message unchanged, which is the plausible slip, fails here rather than in a
/// suite.
fn theRecordCoercesMessageAndSignal(nothing: *types.JanetFunction) void {
    var reg = wrap.fromNil();
    const message = value.fromBytes("original", .string);
    const old_return_reg = harness.vm().return_reg;
    const old_fiber = harness.vm().fiber;
    const old_coerce_error = harness.vm().coerce_error;
    const fiber = rootedFiber(nothing);
    defer unroot(fiber);

    gc_alloc.gcroot(message);
    defer _ = gc_alloc.gcunroot(message);

    harness.vm().return_reg = &reg;
    harness.vm().fiber = fiber;
    harness.vm().coerce_error = true;
    harness.vm().pending_signal = types.Signal.user9;

    signal_core_mod.zigSignalRecord(types.Signal.yield, message);
    assert(harness.vm().pending_signal == types.Signal.@"error");
    assert(harness.isType(reg, repr.Tag.string));
    const rendered = wrap.toString(reg);
    const text = rendered[0..@intCast(types.stringHead(rendered).length)];
    assert(std.mem.indexOf(u8, text, "coerced from") != null);
    assert(std.mem.indexOf(u8, text, "yield") != null);

    // ERROR under coercion is a raise rather than a coercion: the signal is
    // already what it would be coerced to, so the message must survive.
    reg = wrap.fromNil();
    signal_core_mod.zigSignalRecord(types.Signal.@"error", message);
    assert(harness.vm().pending_signal == types.Signal.@"error");
    assert(harness.equals(reg, message));

    harness.vm().coerce_error = old_coerce_error;
    harness.vm().fiber = old_fiber;
    harness.vm().return_reg = old_return_reg;
}

// -------------------------------------------------- the public perimeter

// The Zig entry points, which is what every raise in the runtime is made of.
// Each is `raise.Error` rather than an error union, so it needs a one-line
// wrapper before `harness.raised` can call it: that helper reads the payload
// out of the scope it opened, and a bare error set has nothing to capture.
//
// Kept local rather than put in `test/harness.zig`: no other contract calls a
// `raise.*` entry point directly -- every other one reaches a raise through
// the subsystem function that made it.

fn panicWith(message: [*:0]const u8) raise.Error!void {
    return raise.panic(message);
}

fn panicvWith(message: repr.Value) raise.Error!void {
    return raise.panicv(message);
}

fn signalWith(sig: types.Signal, message: repr.Value) raise.Error!void {
    return raise.signal(sig, message);
}

/// The three Zig entry points, which is where a raise in this runtime comes
/// from. `raise.panic` interns a NUL-terminated string, `raise.panicv` takes
/// any value at all, and `raise.signal` carries a signal that is not an error.
fn theEntryPoints() void {
    const plain = harness.raised(panicWith, .{"plain"}).?;
    assert(plain.signal == types.Signal.@"error");
    assert(plain.says("plain"));

    // The payload is not coerced to a string: `panicv` takes any value.
    const valued = harness.raised(panicvWith, .{harness.wrapInteger(11)}).?;
    assert(valued.signal == types.Signal.@"error");
    assert(harness.equals(valued.payload, harness.wrapInteger(11)));

    // A non-error signal reaches `pending_signal` unaltered, which is the
    // field a Zig caller reads instead of the value a `setjmp` returned.
    const yielded = harness.raised(signalWith, .{ types.Signal.yield, value.fromBytes("suspended", .string) }).?;
    assert(yielded.signal == types.Signal.yield);
    assert(yielded.says("suspended"));
}

/// The four abis, each `raise.report` over one of the entry points above.
///
/// `janet_panicf` is in `test/pp_format.zig`: its format string is a
/// `comptime` parameter, so a caller instantiates the raise rather than
/// calling it, and it sits beside the engine that builds its message.
fn thePublicAbis() void {
    const plain = harness.abiRaised(signal_core_mod.panic, .{"plain"}).?;
    assert(plain.signal == types.Signal.@"error");
    assert(plain.says("plain"));

    const interned = harness.abiRaised(signal_core_mod.panics, .{strings.cstring("interned")}).?;
    assert(interned.signal == types.Signal.@"error");
    assert(interned.says("interned"));

    const valued = harness.abiRaised(signal_core_mod.panicv, .{harness.wrapInteger(11)}).?;
    assert(valued.signal == types.Signal.@"error");
    assert(harness.equals(valued.payload, harness.wrapInteger(11)));

    const signalled = harness.abiRaised(signal_core_mod.signalv, .{ types.Signal.yield, value.fromBytes("suspended", .string) }).?;
    assert(signalled.signal == types.Signal.yield);
    assert(signalled.says("suspended"));

    // `janet_panics` takes a `JanetString`, which carries its own length, and
    // must not re-intern it through a C string. Nothing else in the tree
    // notices: every other message raised anywhere is NUL-free, so a
    // `janet_cstring` inserted here would produce an equal string in every
    // case but this one. A mutation sweep found that hole, which is why the
    // case exists.
    const embedded = strings.new("a\x00b");
    gc_alloc.gcroot(wrap.fromString(embedded));
    defer _ = gc_alloc.gcunroot(wrap.fromString(embedded));
    const raw = harness.abiRaised(signal_core_mod.panics, .{embedded}).?;
    assert(raw.signal == types.Signal.@"error");
    assert(harness.isType(raw.payload, repr.Tag.string));
    const payload = wrap.toString(raw.payload);
    assert(types.stringHead(payload).length == 3);
    assert(std.mem.eql(u8, payload[0..3], "a\x00b"));
}

/// The two slot diagnostics live with the argument layer, under
/// `-Dargs-core`, because the fault path there needs the error and not a
/// report. Their wording is pinned by `test/args_core.zig` against every fault
/// kind; what is pinned here is that the two public abis still deliver.
fn theSlotDiagnostics() void {
    const at_probe = abstract_type.define(anyopaque, .{ .name = "signal-core/probe" });

    const wrong_type = harness.abiRaised(c.janet_panic_type, .{ wrap.fromNil(), 3, repr.TagSet.one(.number).bits() }).?;
    assert(wrong_type.signal == types.Signal.@"error");
    assert(wrong_type.says("bad slot #3, expected number, got nil"));

    const wrong_abstract = harness.abiRaised(c.janet_panic_abstract, .{
        wrap.fromNil(),
        @as(i32, 0),
        &at_probe,
    }).?;
    assert(wrong_abstract.signal == types.Signal.@"error");
    assert(wrong_abstract.says("bad slot #0, expected signal-core/probe, got nil"));
}

// ------------------------------------------------------------- injection

/// An injected signal goes to the innermost fiber of the chain, not to the one
/// named, and it travels in `gc.flags` while the resume flag travels in
/// `flags`. That split is deliberate — `run_vm` reads the signal back out of
/// `gc.flags` and clears it there — and a port that "tidied" it into one word
/// would compile, pass the suites, and deliver every injected signal as status
/// NEW.
fn injectionReachesTheInnermostFiber(nothing: *types.JanetFunction) void {
    const parent = rootedFiber(nothing);
    const child = rootedFiber(nothing);
    const grandchild = rootedFiber(nothing);
    defer unroot(parent);
    defer unroot(child);
    defer unroot(grandchild);

    parent.child = child;
    child.child = grandchild;

    // Preload the carrier so that a plan which only ORs shows up.
    grandchild.gc.flags |= constants.JANET_FIBER_STATUS_MASK;
    const parent_flags = parent.flags;
    const child_flags = child.flags;

    signal_core_mod.signalInject(parent, types.Signal.user3);

    assert(grandchild.flags & constants.JANET_FIBER_RESUME_SIGNAL != 0);
    assert((grandchild.gc.flags & constants.JANET_FIBER_STATUS_MASK) >> constants.JANET_FIBER_STATUS_OFFSET ==
        @intFromEnum(types.Signal.user3));

    // The fiber's real status lives in `flags` and is untouched.
    assert(fibers.status(grandchild) == types.FiberStatus.new);

    // Neither of the fibers above it is disturbed.
    assert(parent.flags == parent_flags);
    assert(child.flags == child_flags);

    // A chain of one is its own innermost fiber.
    grandchild.gc.flags &= ~@as(i32, constants.JANET_FIBER_STATUS_MASK);
    grandchild.flags &= ~@as(i32, constants.JANET_FIBER_RESUME_SIGNAL);
    parent.child = null;
    child.child = null;
    signal_core_mod.signalInject(grandchild, types.Signal.user1);
    assert(grandchild.flags & constants.JANET_FIBER_RESUME_SIGNAL != 0);
    assert((grandchild.gc.flags & constants.JANET_FIBER_STATUS_MASK) >> constants.JANET_FIBER_STATUS_OFFSET ==
        @intFromEnum(types.Signal.user1));

    grandchild.gc.flags &= ~@as(i32, constants.JANET_FIBER_STATUS_MASK);
    grandchild.flags &= ~@as(i32, constants.JANET_FIBER_RESUME_SIGNAL);
}

/// The injection and the resume that consumes it, end to end. This is what
/// `ev/cancel` is built on, and it is the only check here that the carrier the
/// injection writes is the one `run_vm` reads.
fn aContinueSignalDeliversAnError(yielder: *types.JanetFunction) void {
    const fiber = rootedFiber(yielder);
    defer unroot(fiber);
    var out = wrap.fromNil();

    assert(vm_entry.continueFiber(fiber, wrap.fromNil(), &out) == types.Signal.yield);

    const sig = vm_entry.continueSignal(fiber, value.fromBytes("cancelled", .string), &out, types.Signal.@"error");
    assert(sig == types.Signal.@"error");
    assert(harness.stringValueIs(out, "cancelled"));
}

/// A signal of OK is not injected at all: `janet_continue_signal` resumes
/// normally, and the fiber sees the value rather than a raise.
fn aContinueSignalOfOkIsAnOrdinaryResume(yielder: *types.JanetFunction) void {
    const fiber = rootedFiber(yielder);
    defer unroot(fiber);
    var out = wrap.fromNil();

    assert(vm_entry.continueFiber(fiber, wrap.fromNil(), &out) == types.Signal.yield);

    const sig = vm_entry.continueSignal(fiber, harness.wrapInteger(7), &out, types.Signal.ok);
    assert(sig == types.Signal.ok);
    assert(harness.integerIs(out, 7));
}

/// A signal number a C caller may legally pass but the vocabulary has no
/// member for.
///
/// **The published boundary takes the wire width, not the enum.** Every
/// signal-taking entry point is `callconv(.c)`, so its argument is whatever
/// `c_uint` the caller wrote. `types.Signal` has fourteen members, and
/// *building* an enum value outside them is the illegal operation -- it is not
/// deferred to a later `switch`. So 42 arriving at `janet_continue_signal`
/// used to be illegal behaviour before anything looked at it, and the six bits
/// it travelled through in the fiber's GC header made the read-back illegal
/// too.
///
/// `Signal.fromWire` clamps, which is what `JOP_SIGNAL` already did with the
/// raw number in an instruction field. This pins the two ends: the number goes
/// in as 42 and comes back as `user9`, and neither end traps.
fn anOutOfDomainSignalClamps(yielder: *types.JanetFunction) void {
    const fiber = rootedFiber(yielder);
    defer unroot(fiber);
    var out = wrap.fromNil();

    assert(vm_entry.continueFiber(fiber, wrap.fromNil(), &out) == types.Signal.yield);

    // Reached through the symbol table rather than by import, because the
    // published entry point is what owns the conversion -- the internal
    // `continueSignal` already takes a member and could not be handed 42.
    const published = struct {
        extern fn janet_continue_signal(
            fiber: *types.JanetFiber,
            in: repr.Value,
            out: *repr.Value,
            sig: c_uint,
        ) callconv(.c) types.Signal;
    };
    const sig = published.janet_continue_signal(fiber, wrap.fromNil(), &out, 42);
    assert(sig == types.Signal.user9);

    // The whole six-bit range the GC header can hold, including the value
    // above the enum's largest member and the one at the far end.
    assert(types.Signal.fromWire(0) == types.Signal.ok);
    assert(types.Signal.fromWire(13) == types.Signal.user9);
    assert(types.Signal.fromWire(14) == types.Signal.user9);
    assert(types.Signal.fromWire(63) == types.Signal.user9);
    assert(types.Signal.fromWire(std.math.maxInt(c_uint)) == types.Signal.user9);

    // A member converts to itself, so an internal caller pays nothing.
    inline for (@typeInfo(types.Signal).@"enum".fields) |f| {
        assert(types.Signal.fromWire(f.value) == @as(types.Signal, @enumFromInt(f.value)));
    }
}

// ------------------------------------------------------------------- main

pub fn run() void {
    harness.init();
    test_env = harness.coreEnv();
    gc_alloc.gcroot(wrap.fromTable(test_env));

    const nothing = compileFunction("(fn [] nil)");
    // Yields once, then returns whatever it was resumed with.
    const yielder = compileFunction("(fn [] (yield 1))");

    aTryScopeSavesRedirectsAndRestores();
    tryScopesNest();
    aScopeCatchesAPanic();

    thePlanWithoutAReturnRegister();
    thePlanWithoutCoercion();
    thePlanCoerces();
    thePlanBumpsTheRootFiber(nothing);
    theCommitPublishesAndMarks(nothing);

    theRecordPublishesSignalAndPayload(nothing);
    theRecordCoercesMessageAndSignal(nothing);

    theEntryPoints();
    thePublicAbis();
    theSlotDiagnostics();

    injectionReachesTheInnermostFiber(nothing);
    aContinueSignalDeliversAnError(yielder);
    aContinueSignalOfOkIsAnOrdinaryResume(yielder);
    anOutOfDomainSignalClamps(yielder);

    vm_lifecycle.deinit();
    std.debug.print("signal core contract ok\n", .{});
}
