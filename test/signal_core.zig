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
//! ## What the migration changed, and the one assertion it could not keep
//!
//! The C original's `test_jump_delivers_the_recorded_signal` asserted that
//! **the two deliveries agree**: `janet_signalv` recorded the raise and then
//! jumped, and the value `setjmp` returned had to be the signal the record
//! published. Two independent transports, one decision, and a disagreement
//! meant the mechanism had forked.
//!
//! There is one transport now. `raise.signal` calls `janet_zig_signal_record`
//! and returns `error.JanetSignal`; the abi is `raise.report` over exactly
//! that expression, and `report`'s whole body is setting a flag. So the
//! "agreement" is a definition rather than a fact, and asserting it would be
//! rule 8's assertion that cannot fail. It is dropped and said so here.
//!
//! What replaces it is narrower and true: `pending_signal` is where a Zig
//! caller reads the signal, so every raising case below reads it back through
//! `harness.raised` rather than assuming the value it was given.
//!
//! ## The four public abis are still tested, and the reason changed
//!
//! `janet_signalv`, `janet_panicv`, `janet_panic` and `janet_panics` each
//! record through `raise.signal`'s family and then hand the raise to a C
//! caller as a report. Two of them — `janet_panicv` and `janet_panic` — have
//! Zig callers through the C ABI in `interop.zig` and `native_module.zig`.
//! The other two have **no in-tree caller at all** now that the C contract is
//! gone, and stay because they are `janet.h`'s public perimeter: an embedder's
//! `janet_panics` is the only thing that will ever call it. That is the same
//! finding Phase 11 Part 10 recorded for nine `value.c` exports, and it is
//! also why they are worth a section — a public entry point with no in-tree
//! caller is precisely the kind that rots without anything saying so.
//!
//! `harness.abiRaised` is what reads one — this increment's addition to the
//! shared vocabulary, and the C contracts' `janet_contract_arm`/
//! `janet_contract_raised` pair with the shim taken out from under it.

const std = @import("std");
const types = @import("types");
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
const signal_count: c_int = constants.JANET_SIGNAL_USER9 + 1;

/// `JANET_VM_HAS_EV` in `src/zig/state_abi.h`, which is what `signal_core.zig`
/// itself gates the `sched_id` bump on. Reading the same flag rather than a
/// `Selection` field is rule 7's shape: the behaviour is compiled in or it is
/// not, and no subsystem name answers that.
const has_ev = constants.JANET_VM_HAS_EV != 0;

const plan_top_level: types.JanetSignalPlan = @intCast(constants.JANET_SIGNAL_PLAN_TOP_LEVEL);
const plan_raise: types.JanetSignalPlan = @intCast(constants.JANET_SIGNAL_PLAN_RAISE);
const plan_coerce: types.JanetSignalPlan = @intCast(constants.JANET_SIGNAL_PLAN_COERCE);

const sig_ok: types.JanetSignal = @intCast(constants.JANET_SIGNAL_OK);
const sig_error: types.JanetSignal = @intCast(constants.JANET_SIGNAL_ERROR);
const sig_yield: types.JanetSignal = @intCast(constants.JANET_SIGNAL_YIELD);
const sig_event: types.JanetSignal = @intCast(constants.JANET_SIGNAL_EVENT);

var test_env: *types.JanetTable = undefined;

fn vm() *types.JanetVM {
    return c.vm();
}

fn compileFunction(source: [*:0]const u8) *types.JanetFunction {
    var out = wrap.fromNil();
    assert(core_env.dostring(test_env, source, "signal-core-test", &out) == 0);
    assert(harness.isType(out, constants.JANET_FUNCTION));
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
    const old_stackn = vm().stackn;
    const old_gc_suspend = vm().gc_suspend;
    const old_fiber = vm().fiber;
    const old_return_reg = vm().return_reg;
    const old_coerce_error = vm().coerce_error;

    // Set so that clearing it inside the scope is visible.
    vm().coerce_error = 1;

    signal_core_mod.tryInit(&state);

    assert(state.stackn == old_stackn);
    assert(state.gc_handle == old_gc_suspend);
    assert(state.vm_fiber == old_fiber);
    assert(state.vm_return_reg == old_return_reg);
    assert(state.coerce_error == 1);

    // The recursion counter advances by exactly one. The state holds the old
    // value and the VM the new one; getting it backwards would leak one
    // `JANET_RECURSION_GUARD` level per scope, which nothing else here would
    // notice.
    assert(vm().stackn == old_stackn + 1);

    assert(vm().return_reg == &state.payload);
    assert(vm().coerce_error == 0);

    // Whatever the scope's body did to the saved fields is undone rather than
    // merged. `gc_suspend` is the one that matters in practice: a callee that
    // locked the collector and then raised has its lock released here.
    vm().gc_suspend = old_gc_suspend + 7;
    vm().stackn += 3;
    vm().coerce_error = 1;

    signal_core_mod.restore(&state);

    assert(vm().stackn == old_stackn);
    assert(vm().gc_suspend == old_gc_suspend);
    assert(vm().fiber == old_fiber);
    assert(vm().return_reg == old_return_reg);
    assert(vm().coerce_error == 1);

    vm().coerce_error = old_coerce_error;
}

/// Scopes nest, and the inner one's saved fields are the outer one's live
/// fields. This is the property a fiber resumed from a different native frame
/// depends on: each resume opens a fresh scope over whatever the last one
/// left.
fn tryScopesNest() void {
    var outer: types.JanetTryState = undefined;
    var inner: types.JanetTryState = undefined;
    const base = vm().stackn;
    const old_coerce_error = vm().coerce_error;

    signal_core_mod.tryInit(&outer);
    assert(vm().stackn == base + 1);

    signal_core_mod.tryInit(&inner);
    assert(vm().stackn == base + 2);
    assert(inner.vm_return_reg == &outer.payload);

    signal_core_mod.restore(&inner);
    assert(vm().stackn == base + 1);
    assert(vm().return_reg == &outer.payload);

    signal_core_mod.restore(&outer);
    assert(vm().stackn == base);
    vm().coerce_error = old_coerce_error;
}

/// The scope and the raise end to end: `janet_try_init` points the return
/// register at this frame's payload slot, `raise.panic` decides and records,
/// and the payload arrives in the scope's own slot.
///
/// The scope is not a formality even though nothing jumps any more —
/// `janet_signal_plan` answers `TOP_LEVEL` when `return_reg` is null and a
/// `TOP_LEVEL` raise ends the process. `harness.raised` is that scope.
fn aScopeCatchesAPanic() void {
    const base = vm().stackn;
    const r = harness.raised(panicWith, .{"caught me"}).?;
    assert(r.signal == sig_error);
    assert(r.says("caught me"));
    assert(vm().stackn == base);
}

// ------------------------------------------------------------ the decision

/// No return register means no jump target, so nothing is decided and nothing
/// is coerced: the caller reports at top level with the message it was given.
fn thePlanWithoutAReturnRegister() void {
    const old_return_reg = vm().return_reg;
    const old_coerce_error = vm().coerce_error;
    var out: types.JanetSignal = sig_ok;

    vm().return_reg = null;
    // Set so that a plan which consulted it before the null test would show.
    vm().coerce_error = 1;

    assert(signal_core_mod.signalPlan(sig_yield, &out) == plan_top_level);
    assert(out == sig_yield);

    vm().return_reg = old_return_reg;
    vm().coerce_error = old_coerce_error;
}

/// Outside a coercing scope every signal passes through unchanged. All
/// fourteen are checked rather than a representative few, because the coercion
/// branch below distinguishes three groups among them and the pass-through
/// branch must distinguish none.
fn thePlanWithoutCoercion() void {
    var reg = wrap.fromNil();
    const old_return_reg = vm().return_reg;
    const old_coerce_error = vm().coerce_error;

    vm().return_reg = &reg;
    vm().coerce_error = 0;

    var s: c_int = 0;
    while (s < signal_count) : (s += 1) {
        const sig: types.JanetSignal = @intCast(s);
        var out: types.JanetSignal = sig_ok;
        assert(signal_core_mod.signalPlan(sig, &out) == plan_raise);
        assert(out == sig);
    }

    vm().return_reg = old_return_reg;
    vm().coerce_error = old_coerce_error;
}

/// Inside a coercing scope the fourteen signals fall into three groups, and
/// the plan reports a different answer for each. OK is not an error and is
/// left alone; ERROR is already one and needs no message; everything else
/// becomes an error and needs the message the caller formats.
fn thePlanCoerces() void {
    var reg = wrap.fromNil();
    const old_return_reg = vm().return_reg;
    const old_coerce_error = vm().coerce_error;
    var out: types.JanetSignal = undefined;

    vm().return_reg = &reg;
    vm().coerce_error = 1;

    out = sig_yield;
    assert(signal_core_mod.signalPlan(sig_ok, &out) == plan_raise);
    assert(out == sig_ok);

    out = sig_yield;
    assert(signal_core_mod.signalPlan(sig_error, &out) == plan_raise);
    assert(out == sig_error);

    var s: c_int = constants.JANET_SIGNAL_DEBUG;
    while (s < signal_count) : (s += 1) {
        out = sig_ok;
        assert(signal_core_mod.signalPlan(@intCast(s), &out) == plan_coerce);
        assert(out == sig_error);
    }

    vm().return_reg = old_return_reg;
    vm().coerce_error = old_coerce_error;
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
    const old_return_reg = vm().return_reg;
    const old_coerce_error = vm().coerce_error;
    const old_root_fiber = vm().root_fiber;
    const fiber = rootedFiber(nothing);
    defer unroot(fiber);
    var out: types.JanetSignal = undefined;

    vm().return_reg = &reg;
    vm().coerce_error = 1;
    vm().root_fiber = fiber;
    const base = fiber.sched_id;

    assert(signal_core_mod.signalPlan(sig_event, &out) == plan_coerce);
    assert(fiber.sched_id == base +% 1);

    // Only EVENT.
    assert(signal_core_mod.signalPlan(sig_yield, &out) == plan_coerce);
    assert(fiber.sched_id == base +% 1);

    // Only while coercing.
    vm().coerce_error = 0;
    assert(signal_core_mod.signalPlan(sig_event, &out) == plan_raise);
    assert(fiber.sched_id == base +% 1);

    // Only with a root fiber — and without one it must not dereference null.
    vm().coerce_error = 1;
    vm().root_fiber = null;
    assert(signal_core_mod.signalPlan(sig_event, &out) == plan_coerce);
    assert(fiber.sched_id == base +% 1);

    vm().root_fiber = old_root_fiber;
    vm().return_reg = old_return_reg;
    vm().coerce_error = old_coerce_error;
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
    const old_return_reg = vm().return_reg;
    const old_fiber = vm().fiber;
    const fiber = rootedFiber(nothing);
    defer unroot(fiber);

    gc_alloc.gcroot(message);
    defer _ = gc_alloc.gcunroot(message);

    fiber.flags &= ~@as(i32, constants.JANET_FIBER_DID_RAISE);
    vm().return_reg = &reg;
    vm().fiber = fiber;

    signal_core.signalCommit(&message);
    assert(harness.equals(reg, message));
    assert(fiber.flags & constants.JANET_FIBER_DID_RAISE != 0);

    // With no current fiber the register is still written and nothing is
    // dereferenced. `janet_zig_signal_record` reaches this whenever a panic is
    // raised outside any fiber at all.
    reg = wrap.fromNil();
    vm().fiber = null;
    signal_core.signalCommit(&message);
    assert(harness.equals(reg, message));

    vm().fiber = old_fiber;
    vm().return_reg = old_return_reg;
}

// ------------------------------------------------------- recording a raise

// `janet_zig_signal_record` is the whole of a raise except the delivery. Its
// two observable outputs are the payload in the return register and the signal
// in `janet_vm.pending_signal`, and the second is the one that carries: a Zig
// caller reads the signal out of that field, where under the jump it travelled
// as `longjmp`'s second argument and was never stored anywhere.

/// The ordinary case. Nothing coerces, so the message and the signal both
/// arrive unaltered, and the fiber is marked exactly as `signalCommit` marks
/// it.
fn theRecordPublishesSignalAndPayload(nothing: *types.JanetFunction) void {
    var reg = wrap.fromNil();
    const message = value.fromBytes("recorded", .string);
    const old_return_reg = vm().return_reg;
    const old_fiber = vm().fiber;
    const old_coerce_error = vm().coerce_error;
    const fiber = rootedFiber(nothing);
    defer unroot(fiber);

    gc_alloc.gcroot(message);
    defer _ = gc_alloc.gcunroot(message);

    fiber.flags &= ~@as(i32, constants.JANET_FIBER_DID_RAISE);
    vm().return_reg = &reg;
    vm().fiber = fiber;
    vm().coerce_error = 0;
    // Scribbled first, so that a record which never writes it is caught rather
    // than passing because the field already held the value wanted.
    vm().pending_signal = @intCast(constants.JANET_SIGNAL_USER9);

    signal_core_mod.zigSignalRecord(sig_error, message);
    assert(vm().pending_signal == sig_error);
    assert(harness.equals(reg, message));
    assert(fiber.flags & constants.JANET_FIBER_DID_RAISE != 0);

    // A signal that does not coerce travels unaltered, which is what makes
    // `pending_signal` worth reading rather than assuming.
    vm().pending_signal = @intCast(constants.JANET_SIGNAL_USER9);
    signal_core_mod.zigSignalRecord(sig_yield, message);
    assert(vm().pending_signal == sig_yield);
    assert(harness.equals(reg, message));

    vm().coerce_error = old_coerce_error;
    vm().fiber = old_fiber;
    vm().return_reg = old_return_reg;
}

/// The coercing case. Both halves are checked: the signal the caller passed is
/// replaced by ERROR, and the payload is replaced by a string naming the
/// original signal — so a port that coerced the signal but forwarded the
/// message unchanged, which is the plausible slip, fails here rather than in a
/// suite.
fn theRecordCoercesMessageAndSignal(nothing: *types.JanetFunction) void {
    var reg = wrap.fromNil();
    const message = value.fromBytes("original", .string);
    const old_return_reg = vm().return_reg;
    const old_fiber = vm().fiber;
    const old_coerce_error = vm().coerce_error;
    const fiber = rootedFiber(nothing);
    defer unroot(fiber);

    gc_alloc.gcroot(message);
    defer _ = gc_alloc.gcunroot(message);

    vm().return_reg = &reg;
    vm().fiber = fiber;
    vm().coerce_error = 1;
    vm().pending_signal = @intCast(constants.JANET_SIGNAL_USER9);

    signal_core_mod.zigSignalRecord(sig_yield, message);
    assert(vm().pending_signal == sig_error);
    assert(harness.isType(reg, constants.JANET_STRING));
    const rendered = wrap.toString(reg);
    const text = rendered[0..@intCast(types.stringHead(rendered).length)];
    assert(std.mem.indexOf(u8, text, "coerced from") != null);
    assert(std.mem.indexOf(u8, text, "yield") != null);

    // ERROR under coercion is a raise rather than a coercion: the signal is
    // already what it would be coerced to, so the message must survive.
    reg = wrap.fromNil();
    signal_core_mod.zigSignalRecord(sig_error, message);
    assert(vm().pending_signal == sig_error);
    assert(harness.equals(reg, message));

    vm().coerce_error = old_coerce_error;
    vm().fiber = old_fiber;
    vm().return_reg = old_return_reg;
}

// -------------------------------------------------- the public perimeter

// The Zig entry points, which is what every raise in the runtime is made of.
// Each is `raise.Error` rather than an error union, so it needs a one-line
// wrapper before `harness.raised` can call it: that helper reads the payload
// out of the scope it opened, and a bare error set has nothing to capture.
//
// Kept local rather than put in `test/harness.zig`. Rule 6 says shared
// vocabulary goes there on the group that first needs it, and no other
// contract calls a `raise.*` entry point directly — every other one reaches a
// raise through the subsystem function that made it.

fn panicWith(message: [*:0]const u8) raise.Error!void {
    return raise.panic(message);
}

fn panicvWith(message: types.Janet) raise.Error!void {
    return raise.panicv(message);
}

fn signalWith(sig: types.JanetSignal, message: types.Janet) raise.Error!void {
    return raise.signal(sig, message);
}

/// The three Zig entry points, which is where a raise in this runtime comes
/// from. `raise.panic` interns a NUL-terminated string, `raise.panicv` takes
/// any value at all, and `raise.signal` carries a signal that is not an error.
fn theEntryPoints() void {
    const plain = harness.raised(panicWith, .{"plain"}).?;
    assert(plain.signal == sig_error);
    assert(plain.says("plain"));

    // The payload is not coerced to a string: `panicv` takes any value.
    const valued = harness.raised(panicvWith, .{harness.wrapInteger(11)}).?;
    assert(valued.signal == sig_error);
    assert(harness.equals(valued.payload, harness.wrapInteger(11)));

    // A non-error signal reaches `pending_signal` unaltered, which is the
    // field a Zig caller reads instead of the value a `setjmp` returned.
    const yielded = harness.raised(signalWith, .{ sig_yield, value.fromBytes("suspended", .string) }).?;
    assert(yielded.signal == sig_yield);
    assert(yielded.says("suspended"));
}

/// The four abis, each `raise.report` over one of the entry points above.
///
/// `janet_panicf` was asserted here once and is in `test/pp_format.zig` now:
/// Phase 10 Part 18 made the format string a `comptime` parameter, so a caller
/// instantiates the raise rather than calling it, and it sits beside the
/// engine that builds its message.
fn thePublicAbis() void {
    const plain = harness.abiRaised(signal_core_mod.panic, .{"plain"}).?;
    assert(plain.signal == sig_error);
    assert(plain.says("plain"));

    const interned = harness.abiRaised(signal_core_mod.panics, .{strings.cstring("interned")}).?;
    assert(interned.signal == sig_error);
    assert(interned.says("interned"));

    const valued = harness.abiRaised(signal_core_mod.panicv, .{harness.wrapInteger(11)}).?;
    assert(valued.signal == sig_error);
    assert(harness.equals(valued.payload, harness.wrapInteger(11)));

    const signalled = harness.abiRaised(signal_core_mod.signalv, .{ sig_yield, value.fromBytes("suspended", .string) }).?;
    assert(signalled.signal == sig_yield);
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
    assert(raw.signal == sig_error);
    assert(harness.isType(raw.payload, constants.JANET_STRING));
    const payload = wrap.toString(raw.payload);
    assert(types.stringHead(payload).length == 3);
    assert(std.mem.eql(u8, payload[0..3], "a\x00b"));
}

/// The two slot diagnostics live with the argument layer, under
/// `-Dargs-core`, because the fault path there needs the error and not a
/// report. Their wording is pinned by `test/args_core.c` against every fault
/// kind; what is pinned here is that the two public abis still deliver.
fn theSlotDiagnostics() void {
    const at_probe: AbstractType = .{ .name = "signal-core/probe" };

    const wrong_type = harness.abiRaised(c.janet_panic_type, .{ wrap.fromNil(), 3, constants.JANET_TFLAG_NUMBER }).?;
    assert(wrong_type.signal == sig_error);
    assert(wrong_type.says("bad slot #3, expected number, got nil"));

    const wrong_abstract = harness.abiRaised(c.janet_panic_abstract, .{
        wrap.fromNil(),
        @as(i32, 0),
        abstract_type.stored(&at_probe),
    }).?;
    assert(wrong_abstract.signal == sig_error);
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

    signal_core_mod.signalInject(parent, @intCast(constants.JANET_SIGNAL_USER3));

    assert(grandchild.flags & constants.JANET_FIBER_RESUME_SIGNAL != 0);
    assert((grandchild.gc.flags & constants.JANET_FIBER_STATUS_MASK) >> constants.JANET_FIBER_STATUS_OFFSET ==
        constants.JANET_SIGNAL_USER3);

    // The fiber's real status lives in `flags` and is untouched.
    assert(fibers.status(grandchild) == constants.JANET_STATUS_NEW);

    // Neither of the fibers above it is disturbed.
    assert(parent.flags == parent_flags);
    assert(child.flags == child_flags);

    // A chain of one is its own innermost fiber.
    grandchild.gc.flags &= ~@as(i32, constants.JANET_FIBER_STATUS_MASK);
    grandchild.flags &= ~@as(i32, constants.JANET_FIBER_RESUME_SIGNAL);
    parent.child = null;
    child.child = null;
    signal_core_mod.signalInject(grandchild, @intCast(constants.JANET_SIGNAL_USER1));
    assert(grandchild.flags & constants.JANET_FIBER_RESUME_SIGNAL != 0);
    assert((grandchild.gc.flags & constants.JANET_FIBER_STATUS_MASK) >> constants.JANET_FIBER_STATUS_OFFSET ==
        constants.JANET_SIGNAL_USER1);

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

    assert(vm_entry.continueFiber(fiber, wrap.fromNil(), &out) == constants.JANET_SIGNAL_YIELD);

    const sig = vm_entry.continueSignal(fiber, value.fromBytes("cancelled", .string), &out, sig_error);
    assert(sig == constants.JANET_SIGNAL_ERROR);
    assert(harness.stringValueIs(out, "cancelled"));
}

/// A signal of OK is not injected at all: `janet_continue_signal` resumes
/// normally, and the fiber sees the value rather than a raise.
fn aContinueSignalOfOkIsAnOrdinaryResume(yielder: *types.JanetFunction) void {
    const fiber = rootedFiber(yielder);
    defer unroot(fiber);
    var out = wrap.fromNil();

    assert(vm_entry.continueFiber(fiber, wrap.fromNil(), &out) == constants.JANET_SIGNAL_YIELD);

    const sig = vm_entry.continueSignal(fiber, harness.wrapInteger(7), &out, sig_ok);
    assert(sig == constants.JANET_SIGNAL_OK);
    assert(harness.integerIs(out, 7));
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

    vm_lifecycle.deinit();
    std.debug.print("signal core contract ok\n", .{});
}
