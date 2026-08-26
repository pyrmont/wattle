//! Behavioral contract for the collector's treatment of a fiber entered by
//! `janet_pcall` from a cfunction, and Phase 11 Part 23's migration of
//! `test/c/test-gc-pcall.c`.
//!
//! ## What the subject is
//!
//! `janet_collect` marks exactly one fiber: `janet_vm.root_fiber`, and then
//! whatever chain of `child` pointers hangs off it. Neither reaches a fiber
//! entered through `janet_pcall` from inside a cfunction. `janet_vm.fiber` is
//! set to the new fiber and `root_fiber` is not — `continueNoCheck` assigns it
//! only when it is null — and `janet_pcall` never sets `child`, because
//! `child` is what `janet_resume` and `JOP_RESUME` maintain for a *Janet*
//! nesting.
//!
//! So the nested fiber is in no root set, is actively running, and owns the
//! stack every frame above it is executing on. `continueNoCheck` roots it by
//! hand for exactly this reason:
//!
//!     const fiber_rooted = c.janet_vm.root_fiber != null;
//!     if (fiber_rooted) c.janet_gcroot(c.janet_wrap_fiber(fiber));
//!
//! This file is that line's regression test.
//!
//! ## What the migration changed, and it is the whole reason to do it
//!
//! **The C original could not run.** `test/c/test-gc-pcall.c` was in no build
//! step — not `build.zig`, not `Makefile`, not `meson.build` — and would not
//! have worked if it had been: it registers `call-via-pcall` with
//! `janet_wrap_cfunction` over a C function, and a `JanetCFunction` has been a
//! raising Zig function since Phase 10 Part 17g. `janet.h` still declares the C
//! one, so the registration succeeds and the *call* segfaults. A regression
//! test for a live fix has therefore been dead for the whole rewrite, which is
//! rule 22's blindness in its third home: a `.c` file nothing compiles
//! announces nothing at all.
//!
//! **The stress cases are kept and a direct one is added.** The original's two
//! programs drive 200 rounds each at `(gcsetinterval 1024)` and infer the
//! fiber's survival from the answers coming back right. That is a real
//! regression test and it stays. What it cannot do is *name* the mechanism: it
//! hopes a collection lands while the nested fiber is live. `directCase` below
//! makes the collection happen at a chosen instant and asserts the survival
//! itself.
//!
//! The difference was measured rather than assumed. Rebuilt with
//! `continueNoCheck`'s rooting spent — `const fiber_rooted = false;` — **both
//! halves catch it, and they read nothing like each other**. `directCase`
//! stops at this file's line 137, `harness.heap.onList` after the collect,
//! which is the claim in the words it was written in. The stress cases
//! segfault at `vm_run.zig`'s `self.stack[fA(self.pc)] = value`, a null store
//! in the interpreter loop, naming neither the collector nor a fiber. So the
//! direct case is not a stronger check than the stress ones; it is a
//! diagnosable one, which is rule 36's second half arriving in a file that had
//! no assertion to attach it to before.
//!
//! **And it asserts its own premise**, which is rule 36's lesson arriving at a
//! pointer rather than at an address. The case is only a case while
//! `root_fiber` is neither the running fiber nor an ancestor of it through
//! `child`. If a future `janet_pcall` were to maintain `child`, `markFiber`
//! would reach the nested fiber on its own, the rooting line could be deleted,
//! and this contract would still pass — testing nothing. `assertNested` is
//! what stops that.

const std = @import("std");
const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");
const raise = @import("raise");
const harness = @import("harness.zig");

const gc_mark = @import("subsystems").gc_mark;
const core_env = @import("subsystems").env;
const vm_entry = @import("subsystems").vm_entry;
const kind = @import("subsystems").value.kind;
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
/// Asserted rather than assumed for rule 36's reason: every assertion below is
/// about a fiber the collector cannot reach, and each of these is a way for it
/// to become reachable without anybody noticing.
fn assertNested(nested: *types.JanetFiber) void {
    const root = c.vm().root_fiber;

    // There is an outer fiber, and it is not this one.
    assert(root != null);
    assert(root != nested);

    // This one is what the interpreter is running.
    assert(c.vm().fiber == nested);

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
    const v = c.vm();
    var i: u32 = 0;
    while (i < v.root_count) : (i += 1) {
        const val = v.roots.?[i];
        if (kind.checkType(val, constants.JANET_FIBER) == 0) continue;
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
fn cfunCollectHere(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 0);

    const nested = c.vm().fiber.?;
    assertNested(nested);

    // The block is the header, so the fiber pointer is what the heap list
    // holds. Both reads bracket the collection.
    const block: ?*anyopaque = @ptrCast(nested);
    assert(harness.heap.onList(c.vm().blocks, block));

    gc_mark.collect();

    // The claim. Without `continueNoCheck`'s rooting this block is unreachable
    // from every root the mark phase has, so the sweep frees it -- along with
    // `fiber->data`, the stack this cfunction's caller is executing on.
    assert(harness.heap.onList(c.vm().blocks, block));

    // And *why* it survived, which the assertion above cannot say on its own.
    //
    // The obvious second reading is the mark bit, and it is unavailable: the
    // sweep clears `JANET_MEM_REACHABLE` on every survivor so that the next
    // mark phase starts from a clean heap, so `harness.heap.reachable` answers
    // false here for every live block in the process. Asserting it would be
    // rule 8's circularity in its other form -- an assertion that cannot
    // succeed rather than one that cannot fail.
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
fn cfunCallViaPcall(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 1);
    const function = try args_core.getFunction(argv, 0);

    var result: types.Janet = wrap.fromNil();
    var fiber: ?*types.JanetFiber = null;
    const sig = vm_entry.pcall(function, 0, null, &result, &fiber);
    if (sig != constants.JANET_SIGNAL_OK) return raise.panicv(result);
    return result;
}

const cfuns = [_]types.JanetReg{
    .{ .name = "gcpcall/call", .cfun = raise.stored(&cfunCallViaPcall), .documentation = null },
    .{ .name = "gcpcall/collect-here", .cfun = raise.stored(&cfunCollectHere), .documentation = null },
    .{ .name = null, .cfun = null, .documentation = null },
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
/// `F1 -> gcpcall/call -> janet_pcall -> F2`, where F2 is `janet_vm.fiber` and
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
/// neither `root_fiber` (F1 is) nor `janet_vm.fiber` (F3 is), and the only
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
        \\      # being janet_vm.fiber without ever having been root_fiber.
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
