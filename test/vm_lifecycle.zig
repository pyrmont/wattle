//! Behavioral contract for the runtime's lifecycle and for the stack-frame
//! decoding behind `debug/stack`.
//!
//! Two subjects, because Phase 9's fifth increment had two.
//!
//! **`janet_init`, `janet_deinit`, and the sandbox.** These are the first and
//! last functions an embedder calls, and every other test binary in this tree
//! depends on them working without ever looking at them: a suite that reaches
//! `main` has already proved `janet_init` does *something*. What it has not
//! proved is which fields of `janet_vm` are set, which are deliberately left
//! alone, and what `janet_deinit` puts back — and those are the difference
//! between a host that can cycle the runtime and one that cannot. Every field
//! `init` assigns is asserted here, in the state it leaves, and so is the
//! subset `deinit` clears. A second full cycle runs afterwards, because a
//! teardown that leaks a pointer looks identical to one that does not until
//! something reuses it.
//!
//! The sandbox is four lines and one of them is a refusal. It is also one-way
//! by construction — `sandbox` asserts against `JANET_SANDBOX_SANDBOX` before
//! widening the flags — and the one-way property is the whole security claim,
//! so it is pinned directly rather than through a standard-library function
//! that happens to check a flag.
//!
//! **`janet_debug_frame`.** Formerly `doframe`. `debug/stack` is the only
//! caller, and what it returns is a table whose keys are the runtime's answer
//! to "where am I". The Janet suites call it and check almost nothing about it.
//!
//! ## What the migration changed
//!
//! **The guard around the unregistered-cfunction case is gone.** The C
//! original could only run that case under `JANET_ZIG_DEBUG_FRAMES`: the C
//! implementation read the cfunction registry entry without checking it for
//! null, so decoding a cframe whose function was never passed through
//! `janet_cfuns` dereferenced null. `FOUND.md` records it. There is one
//! implementation now and it consumes `janet_trace_frame`, which has the
//! check, so the case is unconditional.
//!
//! **The panic counter is gone.** The C original counted its `EXPECT_PANIC`s
//! and compared the total at the end, because a case that silently stopped
//! raising looked exactly like one that passed. `harness.raised` answers null
//! when nothing raised and every site unwraps it, so a refusal that stops
//! arriving fails at its own line. The count was scaffolding for a macro, not
//! an assertion.
//!
//! **The decoder is reached by import.** The C contract called
//! `janet_debug_frame`, the abi; this calls `debug_frames.debugFrameImpl`,
//! so a raise from a `tostring` callback reached through the trace decoding
//! arrives as `error.JanetSignal` rather than as a report nobody consumes.
//! That abi had no other caller — `debug/stack` already used the
//! implementation — so it goes with this file. It is `state.h`'s, not
//! `janet.h`'s.

const std = @import("std");
const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");
const raise = @import("raise");
const harness = @import("harness.zig");

const subsystems = @import("subsystems");
const value = @import("subsystems").value;
const tables = @import("subsystems").value.tables;
const gc_alloc = @import("subsystems").gc_alloc;
const tuples = @import("subsystems").value.tuples;
const order = @import("subsystems").value.order;
const core_env = @import("subsystems").env;
const wrap = @import("subsystems").value.wrap;
const fibers = @import("subsystems").value.fibers;
const vm_entry = @import("subsystems").vm_entry;
const pp_describe = @import("subsystems").pp_describe;
const registry = @import("subsystems").registry;
const vm_lifecycle = subsystems.lifecycle;
const debug_frames = subsystems.debug;

const assert = std.debug.assert;

fn vm() *types.JanetVM {
    return c.vm();
}

var test_env: ?*types.JanetTable = null;

/// Roots whatever it produces and never unroots it: a Janet value in a Zig
/// local is not a root, and these live across calls that compile source and
/// intern keywords.
fn eval(source: [*:0]const u8) types.Janet {
    var out = wrap.fromNil();
    const status = core_env.dostring(test_env.?, source, "vm-lifecycle-test", &out);
    if (status != 0) {
        std.debug.print("unexpected error from: {s}\n", .{source});
        std.debug.print("                  got: {s}\n", .{pp_describe.toString(out)});
        assert(false);
    }
    gc_alloc.gcroot(out);
    return out;
}

/// The same refusal reached through the standard library rather than through
/// the assert directly. Wrapped in a fiber rather than handed to
/// `janet_dostring`, because `janet_dostring` prints a stack trace on the way
/// out and catches the error itself.
fn expectSandboxRefusal(source: []const u8) void {
    var buffer: [512]u8 = undefined;
    const wrapped = std.fmt.bufPrintZ(&buffer, "(fiber/new (fn [] {s}) :ye)", .{source}) catch unreachable;
    const fiberv = eval(wrapped);
    var out = wrap.fromNil();
    const sig = vm_entry.continueFiber(wrap.toFiber(fiberv), wrap.fromNil(), &out);
    assert(sig == constants.JANET_SIGNAL_ERROR);
    assert(harness.stringValueIs(out, "operation forbidden by sandbox"));
}

// ---------------------------------------------------------- frame readers

/// A key of the table the decoder builds.
fn frameGet(built: types.Janet, key: [*:0]const u8) types.Janet {
    assert(harness.isType(built, constants.JANET_TABLE));
    return tables.get(wrap.toTable(built), value.fromBytes(std.mem.span(key), .keyword));
}

fn expectString(built: types.Janet, key: [*:0]const u8, expected: [*:0]const u8) void {
    const v = frameGet(built, key);
    if (!harness.stringValueIs(v, expected)) {
        std.debug.print("key {s}: expected {s}, got {s}\n", .{ key, expected, pp_describe.toString(v) });
        assert(false);
    }
}

fn expectInteger(built: types.Janet, key: [*:0]const u8, expected: i32) void {
    const v = frameGet(built, key);
    if (!harness.integerIs(v, expected)) {
        std.debug.print("key {s}: expected {d}, got {s}\n", .{ key, expected, pp_describe.toString(v) });
        assert(false);
    }
}

fn expectAbsent(built: types.Janet, key: [*:0]const u8) void {
    const v = frameGet(built, key);
    if (!harness.isType(v, constants.JANET_NIL)) {
        std.debug.print("key {s}: expected nil, got {s}\n", .{ key, pp_describe.toString(v) });
        assert(false);
    }
}

/// `janet_debug_frame`'s implementation. It is `raise.Raising(Janet)` because
/// the trace decoding under it can reach an abstract's `tostring`; nothing in
/// this file builds such a frame, so a raise here would be a defect rather
/// than a case.
fn decode(f: *types.JanetStackFrame) types.Janet {
    return debug_frames.debugFrameImpl(f) catch @panic("vm_lifecycle: decoding a frame raised");
}

// --------------------------------------------------------------- init state

// `init` assigns rather than assumes, and a host that reuses a thread — or
// that calls it after a previous runtime was torn down by something other than
// `deinit` — depends on that. Every field it sets is scribbled on first, so the
// assertions below are about what init wrote rather than about what a freshly
// zeroed `janet_vm` already held.

var scribble_roots: [4]types.Janet = undefined;
var scribble_bytes: [64]u8 = undefined;

fn scribbleOverTheVm() void {
    const bytes: *anyopaque = @ptrCast(&scribble_bytes);
    vm().blocks = bytes;
    vm().weak_blocks = bytes;
    vm().next_collection = 4242;
    vm().gc_interval = 99;
    vm().block_count = 77;
    vm().gc_mark_phase = 1;
    vm().roots = &scribble_roots;
    vm().root_count = 3;
    vm().root_capacity = 4;
    vm().user = bytes;
    vm().scratch_mem = @ptrCast(@alignCast(bytes));
    vm().scratch_len = 5;
    vm().scratch_cap = 6;
    vm().sandbox_flags = constants.JANET_SANDBOX_ASM;
    vm().registry = @ptrCast(@alignCast(bytes));
    vm().registry_cap = 7;
    vm().registry_count = 8;
    vm().registry_dirty = 1;
    vm().abstract_registry = null;
    vm().traversal = @ptrCast(@alignCast(bytes));
    vm().traversal_base = @ptrCast(@alignCast(bytes));
    vm().traversal_top = @ptrCast(@alignCast(bytes));
    vm().core_env = @ptrCast(@alignCast(bytes));
    vm().auto_suspend = 1;
    vm().top_dyns = @ptrCast(@alignCast(bytes));
    vm().fiber = @ptrCast(@alignCast(bytes));
    vm().root_fiber = @ptrCast(@alignCast(bytes));
    vm().stackn = 9;
}

/// Field by field, in the state `init` leaves.
///
/// Three of these are not literally what `init` assigned: `blocks` and
/// `next_collection` have moved because the abstract registry is allocated
/// during init, and `root_count` is one because that registry is rooted.
/// Asserting those rather than the assigned values is the point — they are
/// what the next line of an embedder's code sees.
fn theStateInitLeaves() raise.Raising(void) {
    scribbleOverTheVm();
    assert(try vm_lifecycle.init() == 0);

    // The three that would otherwise be invisible: they are zero in a freshly
    // zeroed `janet_vm`, so only the scribble above can tell an assignment
    // from an assumption.
    assert(vm().next_collection < 4242);
    assert(vm().weak_blocks == null);
    assert(vm().block_count == 1);

    // Collector.
    assert(vm().gc_interval == 0x400000);
    assert(vm().gc_mark_phase == 0);
    assert(vm().blocks != null); // the abstract registry is allocated during init

    // Roots: empty except for the abstract registry.
    assert(vm().roots != null);
    assert(vm().root_count == 1);
    assert(vm().abstract_registry != null);
    assert(harness.equals(vm().roots.?[0], wrap.fromTable(vm().abstract_registry.?)));

    // Scratch memory.
    assert(vm().user == null);
    assert(vm().scratch_mem == null);
    assert(vm().scratch_len == 0);
    assert(vm().scratch_cap == 0);

    // Sandbox.
    assert(vm().sandbox_flags == 0);

    // Cfunction registry: empty, and not yet sorted.
    assert(vm().registry == null);
    assert(vm().registry_cap == 0);
    assert(vm().registry_count == 0);
    assert(vm().registry_dirty == 0);

    // Traversal, used by marshalling.
    assert(vm().traversal == null);
    assert(vm().traversal_base == null);
    assert(vm().traversal_top == null);

    // Environments and fibers.
    assert(vm().core_env == null); // the core env is built lazily
    assert(vm().top_dyns == null);
    assert(vm().fiber == null);
    assert(vm().root_fiber == null);
    assert(vm().stackn == 0);
    assert(vm().auto_suspend == 0);

    // The symbol cache belongs to `janet_symcache_init`, which `init` calls
    // after the collector's fields and before the first allocation.
    assert(vm().cache != null);
    assert(vm().cache_count == 0);
    assert(vm().cache_deleted == 0);
    assert(vm().cache_capacity > 0);

    vm_lifecycle.deinit();
}

/// What `deinit` puts back, and what it deliberately does not touch.
/// What `janet_deinit` leaves behind, and it is asserted as *every pointer the
/// teardown frees* rather than as the list of fields it happens to assign.
///
/// The difference is Phase 11 Part 27's whole finding. This function used to
/// enumerate the assignments in `deinit`, which means it was written from the
/// implementation and could only ever agree with it -- so it said nothing about
/// `scratch_mem` or the three traversal fields, the two things teardown freed
/// and did not clear. A `janet_smalloc` between a `janet_deinit` and the next
/// `janet_init` therefore wrote eight bytes through a freed pointer, and only
/// glibc's allocator hardening ever said so. `FOUND.md` has the bisection.
///
/// So the rule this pins is the invariant and not the code: **anything
/// teardown frees, teardown clears**, and `janet_init` assigning a field is
/// what says the field is part of the reset.
/// One level of nesting, so that `janet_equals` has to descend and therefore
/// has to push a traversal node. A flat pair is compared without ever growing
/// the stack.
fn deepen(inner: types.Janet) types.Janet {
    const t = tuples.begin(1);
    t[0] = inner;
    return wrap.fromTuple(tuples.end(t));
}

fn whatDeinitClears() raise.Raising(void) {
    var dummy: i32 = 0;
    assert(try vm_lifecycle.init() == 0);
    _ = harness.coreEnv();
    vm().user = &dummy;

    // The scratch table and the traversal stack are both allocated lazily, so
    // each needs something to have used it before the teardown can be asked
    // whether it cleaned up. Without these two the assertions below hold
    // vacuously, which is exactly how the omission survived.
    const scratch = gc_alloc.smalloc(16) orelse unreachable;
    gc_alloc.sfree(scratch);
    var nested_l = wrap.fromTuple(tuples.end(tuples.begin(0)));
    var nested_r = wrap.fromTuple(tuples.end(tuples.begin(0)));
    nested_l = deepen(nested_l);
    nested_r = deepen(nested_r);
    _ = order.equals(nested_l, nested_r);

    // Preconditions, so that the assertions below are about the teardown.
    assert(vm().core_env != null);
    assert(vm().registry != null);
    assert(vm().roots != null);
    assert(vm().cache_count > 0);
    assert(vm().scratch_mem != null);
    assert(vm().traversal_base != null);

    vm_lifecycle.deinit();

    assert(vm().scratch_mem == null);
    assert(vm().scratch_len == 0);
    assert(vm().scratch_cap == 0);
    assert(vm().traversal == null);
    assert(vm().traversal_base == null);
    assert(vm().traversal_top == null);

    assert(vm().roots == null);
    assert(vm().root_count == 0);
    assert(vm().root_capacity == 0);
    assert(vm().abstract_registry == null);
    assert(vm().core_env == null);
    assert(vm().top_dyns == null);
    assert(vm().user == null); // an embedder's pointer is dropped, not freed
    assert(vm().fiber == null);
    assert(vm().root_fiber == null);
    assert(vm().registry == null);
    assert(vm().cache == null);
    assert(vm().cache_count == 0);

    // `clearMemory` ran: it is the one line of teardown whose effect is a heap
    // rather than a field, and this is the only field it leaves behind to say
    // so. It does not reset `block_count`, which is why that is not asserted.
    assert(vm().blocks == null);
}

/// A teardown that leaks looks exactly like one that does not until something
/// reuses the runtime. Two full cycles, each doing real work.
fn aSecondCycle() raise.Raising(void) {
    for (0..2) |_| {
        var out = wrap.fromNil();
        assert(try vm_lifecycle.init() == 0);
        test_env = harness.coreEnv();
        assert(core_env.dostring(test_env.?, "(+ 1 2)", "cycle", &out) == 0);
        assert(wrap.toInteger(out) == 3);
        vm_lifecycle.deinit();
    }
    test_env = null;
}

// ------------------------------------------------------------------ sandbox

/// The sandbox accumulates and never narrows, and `sandboxAssert` is the only
/// thing that reads it. Run in its own cycle, because nothing can undo it.
fn theSandboxIsOneWay() raise.Raising(void) {
    assert(try vm_lifecycle.init() == 0);
    test_env = harness.coreEnv();

    // Nothing forbidden yet.
    try vm_lifecycle.sandboxAssert(constants.JANET_SANDBOX_ALL);
    assert(vm().sandbox_flags == 0);

    try vm_lifecycle.sandbox(constants.JANET_SANDBOX_ASM);
    assert(vm().sandbox_flags == constants.JANET_SANDBOX_ASM);
    assert(harness.raised(vm_lifecycle.sandboxAssert, .{@as(u32, constants.JANET_SANDBOX_ASM)}).?.says("operation forbidden by sandbox"));

    // A flag that was not set is still allowed, and the assert takes a mask
    // rather than a single flag.
    try vm_lifecycle.sandboxAssert(constants.JANET_SANDBOX_HRTIME);
    assert(harness.raised(
        vm_lifecycle.sandboxAssert,
        .{@as(u32, constants.JANET_SANDBOX_ASM | constants.JANET_SANDBOX_HRTIME)},
    ).?.says("operation forbidden by sandbox"));

    // Flags accumulate rather than replace.
    try vm_lifecycle.sandbox(constants.JANET_SANDBOX_HRTIME);
    assert(vm().sandbox_flags == (constants.JANET_SANDBOX_ASM | constants.JANET_SANDBOX_HRTIME));

    // Reached through the standard library, which is how it is used. `asm` is
    // absent from a build without the assembler, and an absent binding is a
    // compile error inside `eval` rather than the sandbox refusal being
    // asserted — so the environment is asked rather than `options`, which
    // names subsystems and not registrations.
    if (harness.coreOptional("asm") != null) {
        expectSandboxRefusal("(asm '{:arity 0 :bytecode [(ret 0)]})");
    }

    // And the lock: once the sandbox itself is forbidden, nothing more can be
    // added, including nothing.
    try vm_lifecycle.sandbox(constants.JANET_SANDBOX_SANDBOX);
    assert(harness.raised(vm_lifecycle.sandbox, .{@as(u32, 0)}).?.says("operation forbidden by sandbox"));
    assert(vm().sandbox_flags ==
        (constants.JANET_SANDBOX_ASM | constants.JANET_SANDBOX_HRTIME | constants.JANET_SANDBOX_SANDBOX));

    vm_lifecycle.deinit();
    test_env = null;
}

// ------------------------------------------------------------- stack frames

/// The Janet-function case, with everything a funcdef can contribute: a name,
/// a source, a source map, a program counter, the register file, and the
/// symbol map that turns registers back into names.
fn aJanetFrame() void {
    // Written with its geometry fixed, because a source map that swapped line
    // for column would pass any assertion that only checked both were numbers.
    // `(debug/stack` opens at line 4, column 11.
    //
    //     1  (defn probe [a b]
    //     2    (let [scoped (* a 10)] (+ scoped b))
    //     3    (def total (+ a b))
    //     4    (def st (debug/stack (fiber/current)))
    //     5    (if (= total 7) st st))
    //
    // `total` is read after the call on purpose and `scoped` goes out of scope
    // before it: a binding whose last use is before the frame stops is dead
    // there, the symbol map says so, and `scoped`'s register still holds
    // something by then, which is what makes its absence an assertion rather
    // than an accident. The contract is about what is live at the program
    // counter, not about what the source mentions.
    const frames = eval(
        \\(defn probe [a b]
        \\  (let [scoped (* a 10)] (+ scoped b))
        \\  (def total (+ a b))
        \\  (def st (debug/stack (fiber/current)))
        \\  (if (= total 7) st st))
        \\(probe 3 4)
    );
    assert(harness.isType(frames, constants.JANET_ARRAY));
    // [0] is the `debug/stack` cframe itself; [1] is `probe`.
    assert(wrap.toArray(frames).*.count >= 2);
    const built = wrap.toArray(frames).*.data.?[1];

    expectString(built, "name", "probe");
    expectString(built, "source", "vm-lifecycle-test");
    assert(harness.isType(frameGet(built, "function"), constants.JANET_FUNCTION));
    assert(harness.isType(frameGet(built, "pc"), constants.JANET_NUMBER));
    expectAbsent(built, "c");

    // The source map, not the program counter, supplies the location for a
    // funcdef that has one.
    const function = wrap.toFunction(frameGet(built, "function"));
    if (function.*.def.?.sourcemap != null) {
        expectInteger(built, "source-line", 4);
        expectInteger(built, "source-column", 11);
    }

    // The register file is copied whole, its length is the funcdef's, and its
    // contents are the frame's — the first two registers hold the arguments.
    const slots = frameGet(built, "slots");
    assert(harness.isType(slots, constants.JANET_ARRAY));
    assert(wrap.toArray(slots).*.count == function.*.def.?.slotcount);
    assert(wrap.toArray(slots).*.count >= 2);
    assert(harness.integerIs(wrap.toArray(slots).*.data.?[0], 3));
    assert(harness.integerIs(wrap.toArray(slots).*.data.?[1], 4));

    // Local bindings, by name, live at the point the frame stopped.
    const locals = frameGet(built, "locals");
    assert(harness.isType(locals, constants.JANET_TABLE));
    const bindings = wrap.toTable(locals);
    assert(harness.integerIs(tables.get(bindings, value.fromBytes("a", .symbol)), 3));
    assert(harness.integerIs(tables.get(bindings, value.fromBytes("b", .symbol)), 4));
    assert(harness.integerIs(tables.get(bindings, value.fromBytes("total", .symbol)), 7));

    // And a binding that is not live there is absent. Two of them, for two
    // different reasons: `st` is written by the call this frame is stopped at
    // and has not happened yet, and `scoped` left its scope two lines above
    // while its register still holds a value. Only the second can tell a
    // missing death bound from a working one — a table with a nil value is a
    // table without the key, so a binding reported live but holding nil looks
    // exactly like one correctly left out.
    assert(harness.isType(tables.get(bindings, value.fromBytes("st", .symbol)), constants.JANET_NIL));
    assert(harness.isType(tables.get(bindings, value.fromBytes("scoped", .symbol)), constants.JANET_NIL));
}

/// An anonymous function reports no name and still reports everything else,
/// which is the classification `janet_trace_frame` calls NAME_ANONYMOUS and
/// which this consumer renders as the absence of a key.
fn anAnonymousJanetFrame() void {
    const frames = eval("((fn [] (debug/stack (fiber/current))))");
    const built = wrap.toArray(frames).*.data.?[1];
    expectAbsent(built, "name");
    assert(harness.isType(frameGet(built, "function"), constants.JANET_FUNCTION));
    expectString(built, "source", "vm-lifecycle-test");
}

/// A closure reads a captured binding out of its environment rather than out
/// of its own registers: the symbol map encodes the environment index in
/// `death_pc` and marks it with a birth of UINT32_MAX. Nothing else in the
/// tree reaches that branch.
fn aCapturedBinding() void {
    // `(f)` is deliberately not in tail position. A tail call replaces the
    // caller's frame, `outer` would be gone, and the environment would have
    // been detached — which is the other branch of the same test, reading the
    // captured value off the stack rather than out of it. Keeping `outer`
    // alive is what makes this the on-stack case.
    const frames = eval(
        "(do (defn outer [captured]" ++
            "      (def f (fn [] (+ captured 0) (debug/stack (fiber/current))))" ++
            "      (def r (f))" ++
            "      (if (= captured 11) r r))" ++
            "    (outer 11))",
    );
    const built = wrap.toArray(frames).*.data.?[1];
    const locals = frameGet(built, "locals");
    assert(harness.isType(locals, constants.JANET_TABLE));
    expectAbsent(built, "name");
    assert(harness.integerIs(
        tables.get(wrap.toTable(locals), value.fromBytes("captured", .symbol)),
        11,
    ));
}

/// The same closure entered by a tail call: `outer`'s frame is replaced, its
/// environment is detached, and the captured value is read from the
/// environment rather than from the stack it used to live on.
fn aCapturedBindingOffTheStack() void {
    const frames = eval(
        "(do (defn outer2 [captured]" ++
            "      (def f (fn [] (+ captured 0) (debug/stack (fiber/current))))" ++
            "      (f))" ++
            "    (outer2 12))",
    );
    const built = wrap.toArray(frames).*.data.?[1];
    const locals = frameGet(built, "locals");
    assert(harness.isType(locals, constants.JANET_TABLE));
    assert(harness.integerIs(
        tables.get(wrap.toTable(locals), value.fromBytes("captured", .symbol)),
        12,
    ));
}

/// The registered-cfunction case. `debug/stack` is itself the top frame, so it
/// describes its own registration: a prefixed name, the source file it was
/// declared in, the line, and a column of one — which is not a column anybody
/// measured, but a constant this consumer supplies because the registry has no
/// column to give.
fn aRegisteredCfunctionFrame() void {
    const frames = eval("(debug/stack (fiber/current))");
    const built = wrap.toArray(frames).*.data.?[0];

    assert(harness.equals(frameGet(built, "c"), wrap.fromTrue()));
    expectAbsent(built, "function");
    expectAbsent(built, "slots");
    expectAbsent(built, "pc");

    // A registered cfunction reports prefix/name.
    expectString(built, "name", "debug/stack");

    assert(harness.isType(frameGet(built, "source"), constants.JANET_STRING));
    assert(harness.isType(frameGet(built, "source-line"), constants.JANET_NUMBER));
    expectInteger(built, "source-column", 1);
}

/// A tail call is reported, and it is the one key that comes from the frame's
/// own flags rather than from anything it points at.
fn aTailCallFrame() void {
    const frames = eval(
        "(do (defn inner [] (debug/stack (fiber/current)))" ++
            "    (defn outer [] (inner))" ++
            "    (outer))",
    );
    // `inner` was entered by a tail call from `outer`, so `outer`'s frame is
    // gone and `inner`'s carries the flag.
    const built = wrap.toArray(frames).*.data.?[1];
    expectString(built, "name", "inner");
    assert(harness.equals(frameGet(built, "tail"), wrap.fromTrue()));
}

/// A cfunction registered with a prefix, which the core's own are not: every
/// core registration puts the qualified name in `name` and leaves
/// `name_prefix` null, so `debug/stack` above cannot tell a dropped prefix
/// from a kept one. This one is registered through `janet_cfuns` with a
/// prefix, and with neither a source file nor a source line, so it also pins
/// the two keys a registry entry without them must not produce.
///
/// It reports its own frame, which is the only way to see a cframe that is not
/// `debug/stack` itself.
fn cfunSelfframe(argv: []types.Janet) raise.Raising(types.Janet) {
    try subsystems.args.fixarity(argv, 0);
    return decode(harness.frame.current(c.vm().fiber.?));
}

const cfuns = [_]types.JanetReg{
    .{ .name = "selfframe", .cfun = raise.stored(&cfunSelfframe), .documentation = "(selfframe)\n\nIts own stack frame." },
    .{ .name = null, .cfun = null, .documentation = null },
};

fn aPrefixedCfunctionFrame() void {
    const built = eval("(selfframe)");
    assert(harness.equals(frameGet(built, "c"), wrap.fromTrue()));
    expectString(built, "name", "vmlife/selfframe");
    expectAbsent(built, "source");
    expectAbsent(built, "source-line");
    expectAbsent(built, "source-column");
    expectAbsent(built, "function");
}

/// A frame that has a function and no program counter reports the function and
/// nothing that depends on where it stopped. Nothing in the runtime builds one
/// — `janet_fiber_funcframe` always sets `pc` — so it is constructed here,
/// which is also the only way to reach the guard that skips the second half of
/// the decoding.
fn aFrameWithNoProgramCounter() void {
    const fnv = eval("(do (defn named [] nil) named)");
    const fiber = fibers.new(wrap.toFunction(fnv), 64, 0, null).?;
    gc_alloc.gcroot(wrap.fromFiber(fiber));
    const fr = harness.frame.current(fiber);
    assert(fr.func != null and fr.pc != null);
    fr.pc = null;

    const built = decode(fr);
    expectString(built, "name", "named");
    assert(harness.isType(frameGet(built, "function"), constants.JANET_FUNCTION));
    expectAbsent(built, "pc");
    expectAbsent(built, "slots");
    expectAbsent(built, "locals");
    expectAbsent(built, "source");
    expectAbsent(built, "source-line");
}

/// A cfunction that was never passed through `janet_cfuns` has no registry
/// entry. The C implementation read the entry anyway; this one asks
/// `janet_trace_frame`, which checks. See the header.
fn unregisteredCfunction(argv: []types.Janet) raise.Raising(types.Janet) {
    _ = @as(i32, @intCast(argv.len));

    return wrap.fromNil();
}

fn anUnregisteredCfunctionFrame() void {
    const fnv = eval("(fn [] nil)");
    const fiber = fibers.new(wrap.toFunction(fnv), 64, 0, null).?;
    gc_alloc.gcroot(wrap.fromFiber(fiber));
    fibers.cframe(fiber, raise.stored(&unregisteredCfunction));

    const built = decode(harness.frame.current(fiber));
    assert(harness.equals(frameGet(built, "c"), wrap.fromTrue()));
    expectAbsent(built, "name");
    expectAbsent(built, "source");
    expectAbsent(built, "source-line");
    expectAbsent(built, "function");
}

// ------------------------------------------------------------------- entry

fn body() raise.Raising(void) {
    // Three cycles of their own, before anything shared exists.
    try theStateInitLeaves();
    try whatDeinitClears();
    try aSecondCycle();

    _ = try vm_lifecycle.init();
    test_env = harness.coreEnv();
    registry.cfuns(test_env, "vmlife", &cfuns);

    aJanetFrame();
    anAnonymousJanetFrame();
    aCapturedBinding();
    aCapturedBindingOffTheStack();
    aRegisteredCfunctionFrame();
    aPrefixedCfunctionFrame();
    aTailCallFrame();
    aFrameWithNoProgramCounter();
    anUnregisteredCfunctionFrame();

    vm_lifecycle.deinit();
    test_env = null;

    // Last, because it cannot be undone.
    try theSandboxIsOneWay();
}

pub fn run() void {
    body() catch @panic("vm_lifecycle: an operation raised unexpectedly");
    std.debug.print("vm lifecycle contract ok\n", .{});
}
