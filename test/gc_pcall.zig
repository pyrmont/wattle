//! Behavioral contract for the collector's treatment of a fiber entered by
//! `janet_pcall` from a cfunction.
//!
//! ## What the subject is
//!
//! `janet_collect` marks exactly one fiber: `vm.root_fiber`, and then
//! whatever chain of `child` pointers hangs off it. Neither reaches a fiber
//! entered through `janet_pcall` from inside a cfunction. `vm.fiber` is
//! set to the new fiber and `root_fiber` is not — `continueNoCheck` assigns it
//! only when it is null — and `janet_pcall` never sets `child`, because
//! `child` is what `janet_resume` and `JOP_RESUME` maintain for a *Janet*
//! nesting.
//!
//! So the nested fiber is in no root set, is actively running, and owns the
//! stack every frame above it is executing on. `continueNoCheck` roots it by
//! hand for exactly this reason:
//!
//!     const fiber_rooted = c.vm.root_fiber != null;
//!     if (fiber_rooted) c.janet_gcroot(c.janet_wrap_fiber(fiber));
//!
//! This file is that line's regression test.
//!
//! ## Why a direct case as well as the stress ones
//!
//! **The stress cases are kept and a direct one is added.** Two programs drive
//! 200 rounds each at `(gcsetinterval 1024)` and infer the fiber's survival
//! from the answers coming back right. That is a real regression test and it
//! stays. What it cannot do is *name* the mechanism: it hopes a collection
//! lands while the nested fiber is live. `directCase` below makes the
//! collection happen at a chosen instant and asserts the survival
//! what stops that.

const std = @import("std");
const types = @import("types");
const repr = @import("repr");
const raise = @import("raise");
const harness = @import("harness.zig");

const gc_mark = @import("subsystems").gc_mark;
const core_env = @import("subsystems").env;
const vm_entry = @import("subsystems").vm_entry;
const wrap = @import("subsystems").value.wrap;
const vm_lifecycle = @import("subsystems").lifecycle;
const args_core = @import("subsystems").args;
const registry = @import("subsystems").registry;

const assert = std.debug.assert;

var test_env: ?*types.JanetTable = null;

/// How many times `directCase`'s cfunction was reached. Read at the end,
/// because a cfunction that silently stopped being called would leave every
/// assertion in it unexecuted and the contract green — the failure mode the
/// panic counters in the C contracts existed for.
var direct_calls: u32 = 0;

// ------------------------------------------------------------------ premise

/// The three facts that make a nested `janet_pcall` a collector hazard, read
/// from the runtime at the moment one is running.
///
/// Asserted rather than assumed: every assertion below is about a fiber the
/// collector cannot reach, and each of these is a way for it to become
/// reachable without anybody noticing.
fn assertNested(nested: *types.JanetFiber) void {
    const root = harness.vm().root_fiber;

    // There is an outer fiber, and it is not this one.
    assert(root != null);
    assert(root != nested);

    // This one is what the interpreter is running.
    assert(harness.vm().fiber == nested);

    // And `markFiber`'s `child` walk does not arrive here. It follows the
    // chain to its end, so the whole chain is checked rather than one link.
    var link = root;
    while (link) |current| : (link = current.child) assert(current != nested);
}

/// Whether `fiber` is in `janet_vm`'s root set.
///
/// The mark phase walks `roots` after `root_fiber`, so this is the whole of
/// what makes a `janet_pcall`ed fiber reachable. Read by scanning rather than
/// by counting, because `janet_gcroot` appends and the position is not a
/// property anything should depend on.
fn rooted(fiber: *types.JanetFiber) bool {
    const v = harness.vm();
    var i: u32 = 0;
    while (i < v.roots.count) : (i += 1) {
        const val = v.roots.at(i).*;
        if (!repr.checkType(val, repr.Tag.fiber)) continue;
        if (wrap.toFiber(val) == fiber) return true;
    }
    return false;
}

// -------------------------------------------------------------- direct case

/// Collect while a `janet_pcall`ed fiber is the running one, and assert it is
/// still on the heap afterwards.
///
/// Called from Janet source running on the nested fiber, which is the only
/// place the situation exists. Everything it needs is read out of `janet_vm`
/// rather than passed in, because the point is what the *collector* can see.
fn cfunCollectHere(argv: []repr.Value) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 0);

    const nested = harness.vm().fiber.?;
    assertNested(nested);

    // The block is the header, so the fiber pointer is what the heap list
    // holds. Both reads bracket the collection.
    const block: ?*anyopaque = @ptrCast(nested);
    assert(harness.heap.onList(harness.vm().gc.blocks, block));

    gc_mark.collect();

    // The claim. Without `continueNoCheck`'s rooting this block is unreachable
    // from every root the mark phase has, so the sweep frees it -- along with
    // `fiber->data`, the stack this cfunction's caller is executing on.
    assert(harness.heap.onList(harness.vm().gc.blocks, block));

    // And *why* it survived, which the assertion above cannot say on its own.
    //
    // The obvious second reading is the mark bit, and it is unavailable: the
    // sweep clears `JANET_MEM_REACHABLE` on every survivor so that the next
    // mark phase starts from a clean heap, so `harness.heap.reachable` answers
    // false here for every live block in the process. Asserting it would be an
    // assertion that cannot succeed.
    //
    // What can be read is the root set, and it is the mechanism itself.
    // `continueNoCheck` roots the fiber precisely because `janet_collect`
    // reaches no other way to it, so a survival with this false would be a
    // survival by accident.
    assert(rooted(nested));

    direct_calls += 1;
    return wrap.fromNil();
}

/// Call a Janet function on a fresh fiber, from C's position.
///
/// This is the original's `cfun_call_via_pcall` and the shape of the whole
/// hazard: a cfunction that re-enters the interpreter. `janet_pcall` reports
/// its signal rather than raising, so the refusal is re-raised here — which is
/// what the C version's `janet_panicv` did and what makes a failure inside the
/// callback arrive at the Janet caller as an ordinary error.
fn cfunCallViaPcall(argv: []repr.Value) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    const function = try args_core.getFunction(argv, 0);

    var result: repr.Value = wrap.fromNil();
    var fiber: ?*types.JanetFiber = null;
    const sig = vm_entry.pcall(function, 0, null, &result, &fiber);
    if (sig != types.Signal.ok) return raise.panicv(result);
    return result;
}

const cfuns = [_]types.Reg{
    .{ .name = "gcpcall/call", .cfun = raise.stored(&cfunCallViaPcall), .documentation = null },
    .{ .name = "gcpcall/collect-here", .cfun = raise.stored(&cfunCollectHere), .documentation = null },
};

// ------------------------------------------------------------------ evaluate

fn eval(source: [*:0]const u8) void {
    var out = wrap.fromNil();
    assert(core_env.dostring(test_env.?, source, "gc-pcall-test", &out) == 0);
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
    assert(direct_calls == 2);
}

/// Single nesting, under collection pressure.
///
/// `F1 -> gcpcall/call -> janet_pcall -> F2`, where F2 is `vm.fiber` and
/// not `root_fiber`. Every allocation is made from Janet source on purpose:
/// `janet_gcalloc` does not itself collect, and the VM loop's `vm_checkgc_next`
/// is what does — so a C-side allocation would not put the pressure where the
/// hazard is.
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
/// `F1 -> gcpcall/call -> janet_pcall -> F2 -> gcpcall/call -> janet_pcall ->
/// F3`. F2 is the one at risk here and it is worse placed than F2 above: it is
/// neither `root_fiber` (F1 is) nor `vm.fiber` (F3 is), and the only
/// thing holding it is a `JanetTryState` on the C stack, which is not a root.
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

pub fn run() void {
    harness.init();
    test_env = harness.coreEnv();
    registry.cfuns(test_env.?, null, &cfuns);

    directCase();
    singleNesting();
    deepNesting();

    vm_lifecycle.deinit();
    std.debug.print("gc pcall contract ok\n", .{});
}
