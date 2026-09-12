//! Behavioral contract for the runtime's lifecycle and for the stack-frame
//! decoding behind `debug/stack`.
//!
//! Two subjects, because they share a lifecycle.
//!
//! `vm_lifecycle.init`, `vm_lifecycle.deinit` and the sandbox are the first
//! and last functions an embedder calls, and every other test binary in this
//! tree depends on them working without ever looking at them: a suite that
//! reaches `main` has already shown `init` does *something*. What it has not
//! shown is which fields of the VM are set, which are deliberately left alone,
//! and what `deinit` puts back, and those are the difference between a host
//! that can cycle the runtime and one that cannot. Every field `init` assigns
//! is asserted here in the state it leaves, and so is the subset `deinit`
//! clears. A second full cycle runs afterwards, because a teardown that leaks
//! a pointer looks identical to one that does not until something reuses it.
//!
//! The sandbox is four lines and one of them is a refusal. It is also one-way
//! by construction, `sandbox` asserting against the sandbox flag itself before
//! widening the flags, and the one-way property is the whole security claim,
//! so it is pinned directly rather than through a standard-library function
//! that happens to check a flag.
//!
//! `debug.debugFrame` is the second subject. `debug/stack` is its only caller,
//! and what it returns is a table whose keys are where the runtime believes it
//! is. The Janet suites call it and check almost nothing about it.
//!
//! ## What only a contract inside the compilation can do
//!
//! The unregistered-cfunction case is unconditional here. Reading the
//! cfunction registry entry without testing it for null would make decoding a
//! cframe whose function was never registered a null dereference; this runtime
//! consumes `debug.traceFrame`, which has the check.
//!
//! A refusal is a value. `harness.raised` returns null where nothing raised
//! and every site unwraps it, so a refusal that stops arriving fails at its
//! own line and nothing counts them at the end.
//!
//! The decoder is reached by import, so a raise from a `tostring` callback
//! reached through the trace decoding arrives as `error.JanetSignal` rather
//! than as a report nobody consumes.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const config = @import("config");
const core_env = @import("subsystems").env;
const debug_frames = subsystems.debug;
const expect = @import("expect.zig").expect;
const fibers = @import("subsystems").value.fibers;
const gc_alloc = @import("subsystems").gc_alloc;
const harness = @import("harness.zig");
const order = @import("subsystems").value.order;
const pp_describe = @import("subsystems").pp_describe;
const raise = @import("subsystems").raise;
const registry = @import("subsystems").registry;
const repr = @import("repr");
const subsystems = @import("subsystems");
const symbols = @import("subsystems").value.symbols;
const tables = @import("subsystems").value.tables;
const tuples = @import("subsystems").value.tuples;
const value = @import("subsystems").value;
const vm_entry = @import("subsystems").vm_entry;
const vm_lifecycle = subsystems.lifecycle;
const vm_state = @import("subsystems").vm_state;
const wrap = @import("subsystems").value.wrap;

// ==========================================================================
// Constants
// ==========================================================================

var scribble_bytes: [64]u8 = undefined;
var scribble_roots: [4]repr.Value = undefined;
var test_env: ?*tables.Table = null;

// ==========================================================================
// Cases
// ==========================================================================

/// Roots whatever it produces and never unroots it: a Janet value in a Zig
/// local is not a root, and these live across calls that compile source and
/// intern keywords.
fn eval(source: [*:0]const u8) repr.Value {
    var out = wrap.fromNil();
    const status = core_env.dostring(test_env.?, source, "vm-lifecycle-test", &out);
    if (status != 0) {
        std.debug.print("unexpected error from: {s}\n", .{source});
        std.debug.print("                  got: {s}\n", .{pp_describe.toString(out)});
        expect(false);
    }
    gc_alloc.gcroot(out);
    return out;
}

/// A key of the table the decoder builds.
fn frameGet(built: repr.Value, key: [*:0]const u8) repr.Value {
    expect(harness.isType(built, repr.Tag.table));
    return tables.get(wrap.toTable(built), value.fromBytes(std.mem.span(key), .keyword));
}

fn expectString(built: repr.Value, key: [*:0]const u8, expected: [*:0]const u8) void {
    const v = frameGet(built, key);
    if (!harness.stringValueIs(v, expected)) {
        std.debug.print("key {s}: expected {s}, got {s}\n", .{ key, expected, pp_describe.toString(v) });
        expect(false);
    }
}

fn expectInteger(built: repr.Value, key: [*:0]const u8, expected: i32) void {
    const v = frameGet(built, key);
    if (!harness.integerIs(v, expected)) {
        std.debug.print("key {s}: expected {d}, got {s}\n", .{ key, expected, pp_describe.toString(v) });
        expect(false);
    }
}

fn expectAbsent(built: repr.Value, key: [*:0]const u8) void {
    const v = frameGet(built, key);
    if (!harness.isType(v, repr.Tag.nil)) {
        std.debug.print("key {s}: expected nil, got {s}\n", .{ key, pp_describe.toString(v) });
        expect(false);
    }
}

/// The same refusal reached through the standard library rather than through
/// the assert directly. Wrapped in a fiber rather than handed to
/// `env.dostring`, because `dostring` prints a stack trace on the way out and
/// catches the error itself.
fn expectSandboxRefusal(source: []const u8) void {
    var buffer: [512]u8 = undefined;
    const wrapped = std.fmt.bufPrintZ(&buffer, "(fiber/new (fn [] {s}) :ye)", .{source}) catch unreachable;
    const fiberv = eval(wrapped);
    const resumed = vm_entry.continueFiber(wrap.toFiber(fiberv), wrap.fromNil());
    expect(resumed.signal == abi.Signal.@"error");
    expect(harness.stringValueIs(resumed.value, "operation forbidden by sandbox"));
}

/// `debug.debugFrame`. It is `raise.Error!Value` because
/// the trace decoding under it can reach an abstract's `tostring`; nothing in
/// this file builds such a frame, so a raise here would be a defect rather
/// than a case.
fn decode(f: *vm_state.StackFrame) repr.Value {
    return debug_frames.debugFrame(f) catch @panic("vm_lifecycle: decoding a frame raised");
}

// `init` assigns rather than assumes, and a host that reuses a thread depends
// on that, as does one that calls it after a previous runtime was torn down by
// something other than `deinit`. Every field it sets is scribbled on first, so
// the assertions below are about what `init` wrote rather than about what a
// freshly zeroed VM started with.

fn scribbleOverTheVm() void {
    const bytes: *abi.GCObject = @ptrCast(@alignCast(&scribble_bytes));
    harness.vm().gc.blocks = bytes;
    harness.vm().gc.weak_blocks = bytes;
    harness.vm().gc.next_collection = 4242;
    harness.vm().gc.interval = 99;
    harness.vm().gc.block_count = 77;
    harness.vm().gc.mark_phase = true;
    // `vm_lifecycle.init` never assigned this one and `gc.collectorInit` does.
    // Scribbling it is what makes the assertion in `theStateInitLeaves`
    // capable of failing.
    harness.vm().gc.suspend_count = 11;
    harness.vm().roots.items = scribble_roots[0..3];
    harness.vm().roots.capacity = 4;
    harness.vm().user = bytes;
    harness.vm().scratch.items = @as([*]*gc_alloc.ScratchBlock, @ptrCast(@alignCast(bytes)))[0..5];
    harness.vm().scratch.capacity = 6;
    harness.vm().sandbox_flags = vm_lifecycle.Sandbox.of(&.{"asm"});
    harness.vm().registry.rows.capacity = 7;
    harness.vm().registry.dirty = true;
    harness.vm().abstract_registry = null;
    harness.vm().traversal.at = @ptrCast(@alignCast(bytes));
    harness.vm().traversal.base = @ptrCast(@alignCast(bytes));
    harness.vm().traversal.top = @ptrCast(@alignCast(bytes));
    harness.vm().core_env = @ptrCast(@alignCast(bytes));
    harness.vm().auto_suspend = 1;
    harness.vm().top_dyns = @ptrCast(@alignCast(bytes));
    harness.vm().fiber = @ptrCast(@alignCast(bytes));
    harness.vm().root_fiber = @ptrCast(@alignCast(bytes));
    harness.vm().stackn = 9;
}

/// Field by field, in the state `init` leaves.
///
/// Three of these are not literally what `init` assigned: `blocks` and
/// `next_collection` have moved because the abstract registry is allocated
/// during init, and `root_count` is one because that registry is rooted.
/// Asserting those rather than the assigned values is deliberate: they are
/// what the next line of an embedder's code sees.
fn theStateInitLeaves() raise.Error!void {
    scribbleOverTheVm();
    expect(try vm_lifecycle.init() == 0);

    // The three that would otherwise be invisible: they are zero in a freshly
    // zeroed VM, so only the scribble above can tell an assignment from an
    // assumption.
    expect(harness.vm().gc.next_collection < 4242);
    expect(harness.vm().gc.weak_blocks == null);
    expect(harness.vm().gc.block_count == 1);

    // Collector.
    expect(harness.vm().gc.interval == 0x400000);
    expect(harness.vm().gc.mark_phase == false);
    expect(harness.vm().gc.blocks != null); // the abstract registry is allocated during init

    // Roots: empty except for the abstract registry.
    expect(harness.vm().roots.items.len == 1);
    expect(harness.vm().abstract_registry != null);
    expect(harness.equals(harness.vm().roots.items[0], wrap.fromTable(harness.vm().abstract_registry.?)));

    // ScratchTable memory, asserted as the whole type against what
    // `scratchInit` starts from rather than field by field: a field added to
    // `gc_alloc.ScratchTable` is covered without this line being edited, and a
    // field left out of the reset has no way to pass.
    expect(harness.vm().user == null);
    expect(std.meta.eql(harness.vm().scratch, gc_alloc.ScratchTable.empty));

    // The suspension depth, which `vm_lifecycle.init` never assigned and
    // `gc.collectorInit` does. The scribble above set it, so this fails
    // against the old code.
    expect(harness.vm().gc.suspend_count == 0);

    // Sandbox.
    expect(harness.vm().sandbox_flags == vm_lifecycle.Sandbox.none);

    // Cfunction registry: empty, and not yet sorted.
    expect(std.meta.eql(harness.vm().registry, registry.Registry{}));

    // The empty case of a grown array, which is the ordinary state of three
    // of the VM's four at this point and which the pointer they replaced could
    // not be asked about without unwrapping a null.
    // `scratch`, `registry.rows` and the timer queue have never been grown,
    // so their `items` is null and `slice()` must be empty rather than a
    // trap. `roots` has the abstract registry in it and is the non-empty case
    // beside them.
    expect(harness.vm().scratch.items.len == 0);
    expect(harness.vm().scratch.capacity == 0);
    expect(harness.vm().registry.rows.items.len == 0);
    expect(harness.vm().registry.rows.capacity == 0);
    expect(harness.vm().roots.items.len == 1);
    expect(harness.equals(harness.vm().roots.items[0], wrap.fromTable(harness.vm().abstract_registry.?)));
    if (comptime config.ev) {
        expect(harness.vm().ev.tq.items.len == 0);
        expect(harness.vm().ev.tq.capacity == 0);
    }

    // Traversal, used by marshalling.
    expect(std.meta.eql(harness.vm().traversal, order.Traversal{}));

    // Environments and fibers.
    expect(harness.vm().core_env == null); // the core env is built lazily
    expect(harness.vm().top_dyns == null);
    expect(harness.vm().fiber == null);
    expect(harness.vm().root_fiber == null);
    expect(harness.vm().stackn == 0);
    expect(harness.vm().auto_suspend == 0);

    // The symbol cache belongs to `symbols.cacheInit`, which `init` calls
    // after the collector's fields and before the first allocation.
    expect(harness.vm().symcache.entries != null);
    expect(harness.vm().symcache.count == 0);
    expect(harness.vm().symcache.deleted == 0);
    expect(harness.vm().symcache.capacity > 0);

    vm_lifecycle.deinit();
}

/// One level of nesting, so that `order.equals` has to descend and therefore
/// has to push a traversal node. A flat pair is compared without ever growing
/// the stack.
fn deepen(inner: repr.Value) repr.Value {
    const t = tuples.begin(1);
    t[0] = inner;
    return wrap.fromTuple(tuples.end(t));
}

/// What `deinit` puts back, asserted as *every pointer the teardown frees*
/// rather than as the list of fields it happens to assign.
///
/// The difference matters. A list written from the assignments in `deinit`
/// can only ever agree with `deinit`, and would say nothing about a pointer
/// teardown frees and leaves set. A `gc.smalloc` between a `deinit` and the
/// next `init` would then write through a freed pointer, which nothing but an
/// allocator's own hardening would notice.
///
/// So what this pins is the invariant rather than the code: anything teardown
/// frees, teardown clears, and `init` assigning a field is what says the field
/// is part of the reset.
fn whatDeinitClears() raise.Error!void {
    var dummy: i32 = 0;
    expect(try vm_lifecycle.init() == 0);
    _ = harness.coreEnv();
    harness.vm().user = &dummy;

    // The scratch table and the traversal stack are both allocated lazily, so
    // each needs something to have used it before the teardown can be asked
    // whether it cleaned up. Without these two the assertions below are
    // vacuous, and a teardown that cleared nothing would pass them.
    const scratch = gc_alloc.smalloc(16);
    gc_alloc.sfree(scratch);
    var nested_l = wrap.fromTuple(tuples.end(tuples.begin(0)));
    var nested_r = wrap.fromTuple(tuples.end(tuples.begin(0)));
    nested_l = deepen(nested_l);
    nested_r = deepen(nested_r);
    _ = order.equals(nested_l, nested_r);

    // Preconditions, so that the assertions below are about the teardown.
    expect(harness.vm().core_env != null);
    expect(harness.vm().registry.rows.items.len != 0);
    expect(harness.vm().roots.items.len != 0);
    expect(harness.vm().symcache.count > 0);
    expect(harness.vm().scratch.capacity != 0);
    expect(harness.vm().traversal.base != null);

    vm_lifecycle.deinit();

    // The five teardown owns entire, asserted as types rather than as the
    // fields somebody remembered. Each owner's `deinit` ends in `.* = .{}`,
    // so this is that statement read back, and a field added to any of the
    // five is covered without this contract being edited.
    expect(std.meta.eql(harness.vm().scratch, gc_alloc.ScratchTable.empty));
    expect(std.meta.eql(harness.vm().roots, gc_alloc.Roots.empty));
    expect(std.meta.eql(harness.vm().traversal, order.Traversal{}));
    expect(std.meta.eql(harness.vm().symcache, symbols.SymbolCache{}));

    // The registry. A teardown that frees the rows and leaves `count`,
    // `capacity` and `dirty` set makes `registryGet` bisect null over a
    // non-zero count in the window before the next init. Comparing the whole
    // `Registry` is what catches that; asserting `rows == null` alone is
    // exactly the assertion that misses it.
    expect(std.meta.eql(harness.vm().registry, registry.Registry{}));

    expect(harness.vm().abstract_registry == null);
    expect(harness.vm().core_env == null);
    expect(harness.vm().top_dyns == null);
    expect(harness.vm().user == null); // an embedder's pointer is dropped, not freed
    expect(harness.vm().fiber == null);
    expect(harness.vm().root_fiber == null);

    // `clearMemory` ran: it is the one line of teardown whose effect is a heap
    // rather than a field, and this is the only field it leaves behind to say
    // so. It does not reset `block_count`, so that is not asserted.
    expect(harness.vm().gc.blocks == null);
}

/// A teardown that leaks looks exactly like one that does not until something
/// reuses the runtime. Two full cycles, each doing real work.
fn aSecondCycle() raise.Error!void {
    for (0..2) |_| {
        var out = wrap.fromNil();
        expect(try vm_lifecycle.init() == 0);
        test_env = harness.coreEnv();
        expect(core_env.dostring(test_env.?, "(+ 1 2)", "cycle", &out) == 0);
        expect(wrap.toInteger(out) == 3);
        vm_lifecycle.deinit();
    }
    test_env = null;
}

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
    // there, the symbol map says so, and `scoped`'s register still has
    // something in it by then, which is what makes its absence an assertion
    // rather
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
    expect(harness.isType(frames, repr.Tag.array));
    // [0] is the `debug/stack` cframe itself; [1] is `probe`.
    expect(wrap.toArray(frames).count >= 2);
    const built = wrap.toArray(frames).slice()[1];

    expectString(built, "name", "probe");
    expectString(built, "source", "vm-lifecycle-test");
    expect(harness.isType(frameGet(built, "function"), repr.Tag.function));
    expect(harness.isType(frameGet(built, "pc"), repr.Tag.number));
    expectAbsent(built, "c");

    // The source map, not the program counter, supplies the location for a
    // funcdef that has one.
    const function = wrap.toFunction(frameGet(built, "function"));
    if (function.def.?.sourcemap != null) {
        expectInteger(built, "source-line", 4);
        expectInteger(built, "source-column", 11);
    }

    // The register file is copied whole, its length is the funcdef's, and its
    // contents are the frame's, with the arguments in the first two registers.
    const slots = frameGet(built, "slots");
    expect(harness.isType(slots, repr.Tag.array));
    expect(wrap.toArray(slots).count == function.def.?.slotcount);
    expect(wrap.toArray(slots).count >= 2);
    expect(harness.integerIs(wrap.toArray(slots).slice()[0], 3));
    expect(harness.integerIs(wrap.toArray(slots).slice()[1], 4));

    // Local bindings, by name, live at the point the frame stopped.
    const locals = frameGet(built, "locals");
    expect(harness.isType(locals, repr.Tag.table));
    const bindings = wrap.toTable(locals);
    expect(harness.integerIs(tables.get(bindings, value.fromBytes("a", .symbol)), 3));
    expect(harness.integerIs(tables.get(bindings, value.fromBytes("b", .symbol)), 4));
    expect(harness.integerIs(tables.get(bindings, value.fromBytes("total", .symbol)), 7));

    // And a binding that is not live there is absent. Two of them, for two
    // different reasons: `st` is written by the call this frame is stopped at
    // and has not happened yet, and `scoped` left its scope two lines above
    // while its register still has a value in it. Only the second can tell a
    // missing death bound from a working one: a table with a nil value is a
    // table without the key, so a binding reported live but set to nil looks
    // exactly like one correctly left out.
    expect(harness.isType(tables.get(bindings, value.fromBytes("st", .symbol)), repr.Tag.nil));
    expect(harness.isType(tables.get(bindings, value.fromBytes("scoped", .symbol)), repr.Tag.nil));
}

/// An anonymous function reports no name and still reports everything else,
/// which is the classification `debug.traceFrame` calls NAME_ANONYMOUS and
/// which this consumer renders as the absence of a key.
fn anAnonymousJanetFrame() void {
    const frames = eval("((fn [] (debug/stack (fiber/current))))");
    const built = wrap.toArray(frames).slice()[1];
    expectAbsent(built, "name");
    expect(harness.isType(frameGet(built, "function"), repr.Tag.function));
    expectString(built, "source", "vm-lifecycle-test");
}

/// A closure reads a captured binding out of its environment rather than out
/// of its own registers: the symbol map encodes the environment index in
/// `death_pc` and marks it with a birth of UINT32_MAX. Nothing else in the
/// tree reaches that branch.
fn aCapturedBinding() void {
    // `(f)` is deliberately not in tail position. A tail call replaces the
    // caller's frame, `outer` would be gone, and the environment would have
    // been detached, which is the other branch of the same test, reading the
    // captured value off the stack rather than out of it. Keeping `outer`
    // alive is what makes this the on-stack case.
    const frames = eval(
        "(do (defn outer [captured]" ++
            "      (def f (fn [] (+ captured 0) (debug/stack (fiber/current))))" ++
            "      (def r (f))" ++
            "      (if (= captured 11) r r))" ++
            "    (outer 11))",
    );
    const built = wrap.toArray(frames).slice()[1];
    const locals = frameGet(built, "locals");
    expect(harness.isType(locals, repr.Tag.table));
    expectAbsent(built, "name");
    expect(harness.integerIs(
        tables.get(wrap.toTable(locals), value.fromBytes("captured", .symbol)),
        11,
    ));
}

/// The same closure entered by a tail call: `outer`'s frame is replaced, its
/// environment is detached, and the captured value is read from the
/// environment rather than from the stack slot it was captured from.
fn aCapturedBindingOffTheStack() void {
    const frames = eval(
        "(do (defn outer2 [captured]" ++
            "      (def f (fn [] (+ captured 0) (debug/stack (fiber/current))))" ++
            "      (f))" ++
            "    (outer2 12))",
    );
    const built = wrap.toArray(frames).slice()[1];
    const locals = frameGet(built, "locals");
    expect(harness.isType(locals, repr.Tag.table));
    expect(harness.integerIs(
        tables.get(wrap.toTable(locals), value.fromBytes("captured", .symbol)),
        12,
    ));
}

/// The registered-cfunction case. `debug/stack` is itself the top frame, so it
/// describes its own registration: a prefixed name, the source file it was
/// declared in, the line, and a column of one. That column is not measured
/// from anything; it is a constant this consumer supplies, the registry having
/// no column to give.
fn aRegisteredCfunctionFrame() void {
    const frames = eval("(debug/stack (fiber/current))");
    const built = wrap.toArray(frames).slice()[0];

    expect(harness.equals(frameGet(built, "c"), wrap.fromTrue()));
    expectAbsent(built, "function");
    expectAbsent(built, "slots");
    expectAbsent(built, "pc");

    // A registered cfunction reports prefix/name.
    expectString(built, "name", "debug/stack");

    expect(harness.isType(frameGet(built, "source"), repr.Tag.string));
    expect(harness.isType(frameGet(built, "source-line"), repr.Tag.number));
    expectInteger(built, "source-column", 1);
}

fn aPrefixedCfunctionFrame() void {
    const built = eval("(selfframe)");
    expect(harness.equals(frameGet(built, "c"), wrap.fromTrue()));
    expectString(built, "name", "vmlife/selfframe");
    expectAbsent(built, "source");
    expectAbsent(built, "source-line");
    expectAbsent(built, "source-column");
    expectAbsent(built, "function");
}

/// A cfunction registered with a prefix, which the core's own are not: every
/// core registration puts the qualified name in `name` and leaves
/// `name_prefix` null, so `debug/stack` above cannot tell a dropped prefix
/// from a kept one. This one is registered through `registry.cfuns` with a
/// prefix, and with neither a source file nor a source line, so it also pins
/// the two keys a registry entry without them must not produce.
///
/// It reports its own frame, which is the only way to see a cframe that is not
/// `debug/stack` itself.
fn cfunSelfframe(argv: []repr.Value) raise.Error!repr.Value {
    try subsystems.args.fixarity(argv, 0);
    return decode(harness.frame.current(harness.vm().fiber.?));
}

const cfuns = [_]abi.Reg{
    .{ .name = "selfframe", .cfun = raise.stored(&cfunSelfframe), .documentation = "(selfframe)\n\nIts own stack frame." },
};

/// A tail call is reported, and it is the one key that comes from the frame's
/// own flags rather than from anything it points at.
fn aTailCallFrame() void {
    const frames = eval(
        "(do (defn inner [] (debug/stack (fiber/current)))" ++
            "    (defn outer [] (inner))" ++
            "    (outer))",
    );
    // `inner` was entered by a tail call from `outer`, so `outer`'s frame is
    // gone and `inner`'s is the one with the flag.
    const built = wrap.toArray(frames).slice()[1];
    expectString(built, "name", "inner");
    expect(harness.equals(frameGet(built, "tail"), wrap.fromTrue()));
}

/// A frame that has a function and no program counter reports the function and
/// nothing that depends on where it stopped. Nothing in the runtime builds
/// one, `fibers.funcframe` always setting `pc`, so it is constructed here,
/// which is also the only way to reach the guard that skips the second half of
/// the decoding.
fn aFrameWithNoProgramCounter() void {
    const fnv = eval("(do (defn named [] nil) named)");
    const fiber = fibers.new(wrap.toFunction(fnv), 64, &.{}) catch unreachable;
    gc_alloc.gcroot(wrap.fromFiber(fiber));
    const fr = harness.frame.current(fiber);
    expect(fr.func != null and fr.pc.bytecode != null);
    fr.pc = .{ .bytecode = null };

    const built = decode(fr);
    expectString(built, "name", "named");
    expect(harness.isType(frameGet(built, "function"), repr.Tag.function));
    expectAbsent(built, "pc");
    expectAbsent(built, "slots");
    expectAbsent(built, "locals");
    expectAbsent(built, "source");
    expectAbsent(built, "source-line");
}

/// A cfunction that was never passed through `registry.cfuns` has no registry
/// entry. The C implementation read the entry anyway; `debug.traceFrame`
/// checks. See the header.
fn unregisteredCfunction(argv: []repr.Value) raise.Error!repr.Value {
    _ = @as(i32, @intCast(argv.len));

    return wrap.fromNil();
}

fn anUnregisteredCfunctionFrame() void {
    const fnv = eval("(fn [] nil)");
    const fiber = fibers.new(wrap.toFunction(fnv), 64, &.{}) catch unreachable;
    gc_alloc.gcroot(wrap.fromFiber(fiber));
    fibers.cframe(fiber, raise.stored(&unregisteredCfunction));

    const built = decode(harness.frame.current(fiber));
    expect(harness.equals(frameGet(built, "c"), wrap.fromTrue()));
    expectAbsent(built, "name");
    expectAbsent(built, "source");
    expectAbsent(built, "source-line");
    expectAbsent(built, "function");
}

/// The sandbox accumulates and never narrows, and `sandboxAssert` is the only
/// thing that reads it. Run in its own cycle, because nothing can undo it.
fn theSandboxIsOneWay() raise.Error!void {
    expect(try vm_lifecycle.init() == 0);
    test_env = harness.coreEnv();

    // Nothing forbidden yet.
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.all);
    expect(harness.vm().sandbox_flags == vm_lifecycle.Sandbox.none);

    try vm_lifecycle.sandbox(vm_lifecycle.Sandbox.of(&.{"asm"}));
    expect(harness.vm().sandbox_flags == vm_lifecycle.Sandbox.of(&.{"asm"}));
    expect(harness.raised(vm_lifecycle.sandboxAssert, .{vm_lifecycle.Sandbox.of(&.{"asm"})}).?.says("operation forbidden by sandbox"));

    // A flag that was not set is still allowed, and the assert takes a mask
    // rather than a single flag.
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"hrtime"}));
    expect(harness.raised(
        vm_lifecycle.sandboxAssert,
        .{vm_lifecycle.Sandbox.of(&.{ "asm", "hrtime" })},
    ).?.says("operation forbidden by sandbox"));

    // Flags accumulate rather than replace.
    try vm_lifecycle.sandbox(vm_lifecycle.Sandbox.of(&.{"hrtime"}));
    expect(harness.vm().sandbox_flags == vm_lifecycle.Sandbox.of(&.{ "asm", "hrtime" }));

    // Reached through the standard library, which is how it is used. `asm` is
    // absent from a build without the assembler, and an absent binding is a
    // compile error inside `eval` rather than the sandbox refusal being
    // asserted, so the environment is asked rather than `options`, which
    // names subsystems rather than registrations.
    if (harness.coreOptional("asm") != null) {
        expectSandboxRefusal("(asm '{:arity 0 :bytecode [(ret 0)]})");
    }

    // And the lock: once the sandbox itself is forbidden, nothing more can be
    // added, including nothing.
    try vm_lifecycle.sandbox(vm_lifecycle.Sandbox.of(&.{"sandbox"}));
    expect(harness.raised(vm_lifecycle.sandbox, .{vm_lifecycle.Sandbox.none}).?.says("operation forbidden by sandbox"));
    expect(harness.vm().sandbox_flags == vm_lifecycle.Sandbox.of(&.{ "asm", "hrtime", "sandbox" }));

    vm_lifecycle.deinit();
    test_env = null;
}

// ==========================================================================
// Entry
// ==========================================================================

fn body() raise.Error!void {
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
}
