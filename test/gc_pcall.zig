//! Behavioral contract for the collector's treatment of a fiber entered by
//! `vm_entry.pcall` from a cfunction.
//!
//! ## What the subject is
//!
//! `gc/mark.zig`'s `collect` marks exactly one fiber: `vm.root_fiber`, and
//! then whatever chain of `child` pointers hangs off it. Neither reaches a
//! fiber entered through `pcall` from inside a cfunction. `vm.fiber` is set to
//! the new fiber and `root_fiber` is not, `continueNoCheck` assigning it only
//! when it is null, and `pcall` never sets `child`, because `child` is what
//! `fiber/resume` and `JOP_RESUME` maintain for a *Janet* nesting.
//!
//! So the nested fiber is in no root set, is actively running, and owns the
//! stack every frame above it is executing on. `continueNoCheck` roots it by
//! hand for exactly this reason:
//!
//!     const fiber_rooted = vm_state.current().root_fiber != null;
//!     if (fiber_rooted) gc_alloc.gcroot(wrap.fromFiber(fiber));
//!
//! This file is that line's regression test.
//!
//! ## Why a direct case as well as the stress ones
//!
//! There are three cases and they cover the same line from two directions.
//! `singleNesting` and `deepNesting` drive 200 rounds each at
//! `(gcsetinterval 1024)` and infer the fiber's survival from the results
//! coming back right, which is a real regression test but leaves the timing to
//! chance: each is hoping a collection lands while the nested fiber is live.
//! `directCase` makes the collection happen at a chosen instant instead, and
//! asserts both that the block is still on the heap list and that the root set
//! is why.

// ==========================================================================
// Standard library imports
// ==========================================================================

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const args_core = @import("subsystems").args;
const core_env = @import("subsystems").env;
const expect = @import("expect.zig").expect;
const fibers = @import("subsystems").value.fibers;
const gc_mark = @import("subsystems").gc_mark;
const harness = @import("harness.zig");
const raise = @import("subsystems").raise;
const registry = @import("subsystems").registry;
const repr = @import("repr");
const tables = @import("subsystems").value.tables;
const vm_entry = @import("subsystems").vm_entry;
const vm_lifecycle = @import("subsystems").lifecycle;
const wrap = @import("subsystems").value.wrap;

// ==========================================================================
// Constants
// ==========================================================================

/// How many times `directCase`'s cfunction was reached, read at the end. A
/// cfunction that silently stopped being called would leave every assertion in
/// it unexecuted and the contract green.
var direct_calls: u32 = 0;

var test_env: ?*tables.Table = null;

// ==========================================================================
// Cases
// ==========================================================================

/// The three facts that make a nested `pcall` a collector hazard, read
/// from the runtime at the moment one is running.
///
/// Asserted rather than assumed: every assertion below is about a fiber the
/// collector cannot reach, and each of these is a way for it to become
/// reachable without anybody noticing.
fn assertNested(nested: *fibers.Fiber) void {
    const root = harness.vm().root_fiber;

    // There is an outer fiber, and it is not this one.
    expect(root != null);
    expect(root != nested);

    // This one is what the interpreter is running.
    expect(harness.vm().fiber == nested);

    // And `markFiber`'s `child` walk does not arrive here. It follows the
    // chain to its end, so the whole chain is checked rather than one link.
    var link = root;
    while (link) |current| : (link = current.child) expect(current != nested);
}

/// Whether `fiber` is in the VM's root set.
///
/// The mark phase walks `roots` after `root_fiber`, so this is the whole of
/// what makes a `pcall`ed fiber reachable. Read by scanning rather than by
/// counting, because `gc.gcroot` appends and the position is not a property
/// anything should depend on.
fn rooted(fiber: *fibers.Fiber) bool {
    const v = harness.vm();
    var i: u32 = 0;
    while (i < v.roots.items.len) : (i += 1) {
        const val = v.roots.items[i];
        if (!repr.checkType(val, repr.Tag.fiber)) continue;
        if (wrap.toFiber(val) == fiber) return true;
    }
    return false;
}

/// Collect while a `pcall`ed fiber is the running one, and assert it is still
/// on the heap afterwards.
///
/// Called from Janet source running on the nested fiber, which is the only
/// place the situation exists. Everything it needs is read off the VM rather
/// than passed in, because the point is what the *collector* can see.
fn cfunCollectHere(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 0);

    const nested = harness.vm().fiber.?;
    assertNested(nested);

    // The block is the header, so the fiber pointer is what appears on the
    // heap list. Both reads bracket the collection.
    const block: ?*anyopaque = @ptrCast(nested);
    expect(harness.heap.onList(harness.vm().gc.blocks, block));

    gc_mark.collect();

    // The claim. Without `continueNoCheck`'s rooting this block is unreachable
    // from every root the mark phase has, so the sweep frees it, along with
    // `fiber.data`, the stack this cfunction's caller is executing on.
    expect(harness.heap.onList(harness.vm().gc.blocks, block));

    // And *why* it survived, which the assertion above cannot say on its own.
    //
    // The obvious second reading is the mark bit, and it is unavailable: the
    // sweep clears `JANET_MEM_REACHABLE` on every survivor so that the next
    // mark phase starts from a clean heap, so `harness.heap.reachable` is
    // false here for every live block in the process. Asserting it would be an
    // assertion that cannot succeed.
    //
    // What can be read is the root set, and it is the mechanism itself.
    // `continueNoCheck` roots the fiber precisely because the mark phase
    // reaches it no other way, so a survival with this false would be a
    // survival by accident.
    expect(rooted(nested));

    direct_calls += 1;
    return wrap.fromNil();
}

/// Call a Janet function on a fresh fiber, from C's position.
///
/// The shape of the whole hazard: a cfunction that re-enters the interpreter.
/// `pcall` reports its signal rather than raising, so the refusal is re-raised
/// here through `raise.panicv`, which is what makes a failure inside the
/// callback arrive at the Janet caller as an ordinary error.
fn cfunCallViaPcall(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const function = try args_core.getFunction(argv, 0);

    var fiber: ?*fibers.Fiber = null;
    const resumed = vm_entry.pcall(function, &.{}, &fiber);
    if (resumed.signal != abi.Signal.ok) return raise.panicv(resumed.value);
    return resumed.value;
}

const cfuns = [_]abi.Reg{
    .{ .name = "gcpcall/call", .cfun = raise.stored(&cfunCallViaPcall), .documentation = null },
    .{ .name = "gcpcall/collect-here", .cfun = raise.stored(&cfunCollectHere), .documentation = null },
};

fn eval(source: [*:0]const u8) void {
    var out = wrap.fromNil();
    expect(core_env.dostring(test_env.?, source, "gc-pcall-test", &out) == 0);
}

/// The direct case: one nesting, one collection, at a chosen instant.
///
/// Two rounds rather than one, so that the second runs against a heap the
/// first has already swept.
fn directCase() void {
    eval(
        \\(gcsetinterval 1024)
        \\(def cb (fn [] (gcpcall/collect-here) :ok))
        \\(for round 0 2
        \\  (assert (= :ok (gcpcall/call cb))
        \\    (string "direct round " round)))
    );
    expect(direct_calls == 2);
}

/// Single nesting, under collection pressure.
///
/// `F1 -> gcpcall/call -> pcall -> F2`, where F2 is `vm.fiber` and not
/// `root_fiber`. Every allocation is made from Janet source on purpose:
/// `gc.gcallocBytes` does not itself collect and the VM loop's collection
/// check is what does, so an allocation made from Zig would not put the
/// pressure where the hazard is.
fn singleNesting() void {
    eval(
        \\(gcsetinterval 1024)
        \\(def cb
        \\  (do
        \\    (def captured @{:key "value" :nested @[1 2 3 4 5]})
        \\    (fn []
        \\      (var result nil)
        \\      (for i 0 500
        \\        (def t @{:i i :s (string "iter-" i) :arr @[i (+ i 1) (+ i 2)]})
        \\        (set result (get captured :key)))
        \\      result)))
        \\(for round 0 200
        \\  (def result (gcpcall/call cb))
        \\  (assert (= result "value")
        \\    (string "round " round ": expected 'value', got " (describe result))))
    );
}

/// Deep nesting, under collection pressure.
///
/// `F1 -> gcpcall/call -> vm_entry.pcall -> F2 -> gcpcall/call ->
/// vm_entry.pcall -> F3`. F2 is the one at risk here and it is worse placed
/// than F2 above: it is
/// neither `root_fiber` (F1 is) nor `vm.fiber` (F3 is), and the only
/// reference to it is a `vm_state.TryState` on the native stack, which is not
/// a root.
fn deepNesting() void {
    eval(
        \\(gcsetinterval 1024)
        \\(def inner-cb
        \\  (do
        \\    (def captured @{:key "deep" :nested @[10 20 30]})
        \\    (fn []
        \\      (var result nil)
        \\      (for i 0 500
        \\        (def t @{:i i :s (string "iter-" i) :arr @[i (+ i 1) (+ i 2)]})
        \\        (set result (get captured :key)))
        \\      result)))
        \\
        \\(def outer-cb
        \\  (do
        \\    (def state @{:count 0 :data @["a" "b" "c" "d" "e"]})
        \\    (fn []
        \\      # Runs on F2. Calling gcpcall/call here creates F3, and F2 stops
        \\      # being vm.fiber without ever having been root_fiber.
        \\      (def inner-result (gcpcall/call inner-cb))
        \\      # If F2 was collected during F3's execution, `state` is read
        \\      # through freed memory here.
        \\      (put state :count (+ (state :count) 1))
        \\      (string inner-result "-" (state :count)))))
        \\
        \\(for round 0 200
        \\  (def result (gcpcall/call outer-cb))
        \\  (def expected (string "deep-" (+ round 1)))
        \\  (assert (= result expected)
        \\    (string "round " round ": expected '" expected "', got '" (describe result) "'")))
    );
}

// ==========================================================================
// Entry
// ==========================================================================

pub fn run() void {
    harness.init();
    test_env = harness.coreEnv();
    registry.cfuns(test_env.?, null, &cfuns);

    directCase();
    singleNesting();
    deepNesting();

    vm_lifecycle.deinit();
}
