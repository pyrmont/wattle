//! Behavioral contract for the fiber stack-frame machinery.
//!
//! Almost everything here is exercised constantly by the Janet suites — every
//! function call in the language goes through `janet_fiber_funcframe` — so
//! what this file is for is the edges the suites reach only by accident: the
//! arity boundaries, an empty variadic tail against a non-empty one, a tail
//! call that has to move its arguments down over the frame it is replacing,
//! and the environment validator, whose whole job is to reject input the
//! suites never produce.
//!
//! ## What the migration changed: the four pushes have no face left
//!
//! The C original tested the four pushes *twice over*, and said why: each
//! kernel raises "stack overflow" by returning `raise.Error`, and beside each
//! sat a C face — `janet_fiber_push` and its three siblings — that turned the
//! raise back into what a C caller expects. "Two mechanisms, one decision, and
//! the acceptance rule for the phase is that they are tested separately: the C
//! face is the one that disappears, so it is the one that rots."
//!
//! They disappeared. `janet_fiber_push2`, `janet_fiber_push3` and
//! `janet_fiber_pushn` went with this contract in Phase 11 Part 11: `run_vm`
//! and `janet_call` reach the kernels by import, `fiber.h` is an internal
//! header, and the C contract was the last caller of all three.
//! `janet_fiber_push` survived one part longer on `test/vm_calls.c` and
//! `test/vm_entry.c`, and went when Part 12 migrated both.
//!
//! **This file predicted that and had to be edited for it**, which is the
//! point worth keeping. The face case here was the last caller of
//! `janet_fiber_push` in the whole tree — a contract testing a face that
//! existed for nobody — so deleting the face turned it into a compile error
//! naming its own line. A face whose only remaining caller is the contract
//! that tests it is a face with no callers; the test is not a use.
//!
//! So the overflow section reaches four kernels by import, where the original
//! reached four of each.
//!
//! ## What did not change
//!
//! The bounds are still tested one apart. Each push reserves room for what it
//! is about to write, so a single push refuses only at `INT32_MAX` itself and
//! the three-value push refuses two slots earlier; testing them at a common
//! value would leave three of the four bounds unobserved. Setting `stacktop`
//! by hand reaches the guard in a few instructions and is safe to do because
//! every one of the four checks its bound *before* it touches `fiber.data`.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi");
const c = abi.c;
const options = @import("options");
const raise = @import("raise");
const harness = @import("harness.zig");
const fiber_core = @import("subsystems").fiber_core;

const assert = std.debug.assert;

/// `options.ev_core` is `hasEv(options)`, which is already
/// `ev and !single_threaded`. Windows is cross-compiled and never executed
/// here, so its path is left out rather than written blind — the same
/// condition, and the same reason, as `test/gc_stress.zig`.
const has_threads = options.ev_core and builtin.os.tag != .windows;

const frame_size: i32 = c.JANET_FRAME_SIZE;

var test_env: *c.JanetTable = undefined;

fn vm() *c.JanetVM {
    return &c.janet_vm;
}

// `fiber.h`'s three frame macros, which `@cImport` does not translate.
// `janet_stack_frame` is the cast, `janet_fiber_frame` the composition, and
// `janet_fiber_set_status` a read-modify-write over the status field. Six
// lines here rather than at each of the twenty sites below.

fn frameAt(fiber: *c.JanetFiber, index: i32) *c.JanetStackFrame {
    const base = fiber.data + @as(usize, @intCast(index));
    return @ptrCast(@alignCast(base - @as(usize, @intCast(frame_size))));
}

fn currentFrame(fiber: *c.JanetFiber) *c.JanetStackFrame {
    return frameAt(fiber, fiber.frame);
}

fn setStatus(fiber: *c.JanetFiber, status: c_int) void {
    fiber.flags &= ~@as(i32, c.JANET_FIBER_STATUS_MASK);
    fiber.flags |= status << c.JANET_FIBER_STATUS_OFFSET;
}

fn slot(fiber: *c.JanetFiber, index: i32) c.Janet {
    return fiber.data[@intCast(index)];
}

// ------------------------------------------------------- without a runtime

/// `janet_fiber_setcapacity` is reachable without `janet_init`: it resizes a
/// plain allocation and charges the collector's byte budget, and touches
/// nothing else. Testing it here keeps the arithmetic visible instead of
/// buried under a live heap whose budget is moving for other reasons.
fn setcapacityChargesTheBudget() void {
    var fiber: c.JanetFiber = std.mem.zeroes(c.JanetFiber);
    vm().next_collection = 0;

    c.janet_fiber_setcapacity(&fiber, 40);
    assert(fiber.capacity == 40);
    assert(fiber.data != null);
    assert(vm().next_collection == 40 * @sizeOf(c.Janet));

    // Growing charges the difference, not the new total.
    c.janet_fiber_setcapacity(&fiber, 100);
    assert(fiber.capacity == 100);
    assert(vm().next_collection == 100 * @sizeOf(c.Janet));

    // Shrinking gives the difference back. The C original writes this as
    // `next_collection += sizeof(Janet) * diff` with a negative `diff`, so the
    // refund is an unsigned wraparound rather than a subtraction; the result is
    // the same and the spelling is what a port could get wrong.
    const before = vm().next_collection;
    c.janet_fiber_setcapacity(&fiber, 60);
    assert(fiber.capacity == 60);
    assert(vm().next_collection == before - 40 * @sizeOf(c.Janet));

    c.janet_free(fiber.data);
    vm().next_collection = 0;
}

var child_charge: usize = 0;
var child_saw_main: usize = 0;

fn chargeChildBudget() void {
    var fiber: c.JanetFiber = std.mem.zeroes(c.JanetFiber);
    child_saw_main = vm().next_collection;
    c.janet_fiber_setcapacity(&fiber, 16);
    child_charge = vm().next_collection;
    c.janet_free(fiber.data);
}

/// The budget belongs to the calling thread's VM. This is the one property the
/// port could plausibly get wrong while still linking and passing everything
/// else: reaching a process-wide `janet_vm` instead of a thread-local one is
/// invisible until two threads run at once.
fn theBudgetIsPerThread() !void {
    if (!has_threads) return;

    vm().next_collection = 4096;
    const main_before = vm().next_collection;
    const thread = try std.Thread.spawn(.{}, chargeChildBudget, .{});
    thread.join();

    assert(child_saw_main == 0);
    assert(child_charge == 16 * @sizeOf(c.Janet));
    assert(vm().next_collection == main_before);
    vm().next_collection = 0;
}

// ----------------------------------------------------------------- helpers

fn compileFunction(source: [*:0]const u8) *c.JanetFunction {
    var out = c.janet_wrap_nil();
    assert(c.janet_dostring(test_env, source, "fiber-core-test", &out) == 0);
    assert(harness.isType(out, c.JANET_FUNCTION));
    c.janet_gcroot(out);
    return c.janet_unwrap_function(out);
}

fn rootedFiber(func: *c.JanetFunction, argc: i32, argv: [*c]const c.Janet) *c.JanetFiber {
    const fiber = c.janet_fiber(func, 32, argc, argv);
    assert(fiber != null);
    c.janet_gcroot(c.janet_wrap_fiber(fiber));
    return fiber;
}

fn assertNilFrom(fiber: *c.JanetFiber, first: i32, last: i32) void {
    var i = first;
    while (i < last) : (i += 1) assert(harness.isType(slot(fiber, i), c.JANET_NIL));
}

// --------------------------------------------------------------- funcframes

/// A fresh fiber's first frame: base at `JANET_FRAME_SIZE`, arguments at the
/// frame's slot 0, every remaining slot nil because the collector walks them.
fn theFuncframeLayout(add: *c.JanetFunction) void {
    const args = [_]c.Janet{ harness.wrapInteger(11), harness.wrapInteger(22) };
    const fiber = rootedFiber(add, 2, &args);
    const frame = currentFrame(fiber);

    assert(fiber.frame == frame_size);
    assert(fiber.stackstart == fiber.stacktop);
    assert(fiber.stacktop == frame_size + add.def.*.slotcount + frame_size);
    assert(fiber.capacity >= fiber.stacktop);

    assert(frame.func == add);
    assert(frame.pc == add.def.*.bytecode);
    assert(frame.env == null);
    assert(frame.prevframe == 0);
    // `janet_fiber_reset` adds ENTRANCE after the frame is pushed, so the
    // frame itself must have been left with no other flags set.
    assert(frame.flags == c.JANET_STACKFRAME_ENTRANCE);

    assert(harness.integerIs(slot(fiber, fiber.frame), 11));
    assert(harness.integerIs(slot(fiber, fiber.frame + 1), 22));
    assertNilFrom(fiber, fiber.frame + 2, fiber.frame + add.def.*.slotcount);
}

/// A rejected arity must leave the fiber exactly as it was, because callers
/// use the return value to implement `janet_pcall` rather than to recover from
/// a partially built frame.
fn theFuncframeArityRejection(add: *c.JanetFunction) raise.Raising(void) {
    const args = [_]c.Janet{
        harness.wrapInteger(1),
        harness.wrapInteger(2),
        harness.wrapInteger(3),
    };

    assert(c.janet_fiber(add, 32, 1, &args) == null);
    assert(c.janet_fiber(add, 32, 3, &args) == null);

    const fiber = rootedFiber(add, 2, &args);
    const frame = fiber.frame;
    const stackstart = fiber.stackstart;
    const stacktop = fiber.stacktop;

    try fiber_core.push(fiber, harness.wrapInteger(5));
    assert(c.janet_fiber_funcframe(fiber, add) == 1);
    assert(fiber.frame == frame);
    assert(fiber.stackstart == stackstart);
    assert(fiber.stacktop == stacktop + 1);
}

/// A variadic tail is a tuple, and an empty one is the empty tuple rather than
/// a missing slot — the slot is a live local of the callee either way.
fn theFuncframeVarargs(rest: *c.JanetFunction) void {
    const args = [_]c.Janet{
        harness.wrapInteger(1),
        harness.wrapInteger(2),
        harness.wrapInteger(3),
    };

    var fiber = rootedFiber(rest, 3, &args);
    var tail = slot(fiber, fiber.frame + rest.def.*.arity);
    assert(harness.isType(tail, c.JANET_TUPLE));
    const tuple = c.janet_unwrap_tuple(tail);
    assert(c.janet_tuple_length(tuple) == 2);
    assert(harness.integerIs(tuple[0], 2));
    assert(harness.integerIs(tuple[1], 3));

    fiber = rootedFiber(rest, 1, &args);
    tail = slot(fiber, fiber.frame + rest.def.*.arity);
    assert(harness.isType(tail, c.JANET_TUPLE));
    assert(c.janet_tuple_length(c.janet_unwrap_tuple(tail)) == 0);
}

/// `&keys` sets `JANET_FUNCDEF_FLAG_STRUCTARG`, and the tail is built with
/// `janet_struct_put` instead of `janet_tuple_n`. Only even-length tails are
/// asserted here: an odd one reads a slot past the arguments, which is a
/// defect in `makeStructN` recorded in `FOUND.md`, so pinning it would pin an
/// out-of-range read rather than a behavior.
fn theFuncframeStructargs(keyed: *c.JanetFunction) void {
    const args = [_]c.Janet{
        harness.wrapInteger(1),
        c.janet_ckeywordv("a"),
        harness.wrapInteger(7),
        c.janet_ckeywordv("b"),
        harness.wrapInteger(8),
    };

    var fiber = rootedFiber(keyed, 5, &args);
    var tail = slot(fiber, fiber.frame + keyed.def.*.arity);
    assert(harness.isType(tail, c.JANET_STRUCT));
    const structure = c.janet_unwrap_struct(tail);
    assert(c.janet_struct_length(structure) == 2);
    assert(harness.integerIs(harness.field(structure, "a"), 7));
    assert(harness.integerIs(harness.field(structure, "b"), 8));

    fiber = rootedFiber(keyed, 1, &args);
    tail = slot(fiber, fiber.frame + keyed.def.*.arity);
    assert(harness.isType(tail, c.JANET_STRUCT));
    assert(c.janet_struct_length(c.janet_unwrap_struct(tail)) == 0);
}

// --------------------------------------------------------------- tail calls

/// A tail call reuses the current frame: the arguments move down over the
/// outgoing function's slots, the rest are nil'd, and the frame is repointed
/// without its base moving.
fn theFuncframeTail(add: *c.JanetFunction, other: *c.JanetFunction) raise.Raising(void) {
    const args = [_]c.Janet{ harness.wrapInteger(1), harness.wrapInteger(2) };
    const fiber = rootedFiber(add, 2, &args);
    const base = fiber.frame;

    try fiber_core.push2(fiber, harness.wrapInteger(30), harness.wrapInteger(40));
    assert(c.janet_fiber_funcframe_tail(fiber, other) == 0);

    const frame = currentFrame(fiber);
    assert(fiber.frame == base);
    assert(frame.func == other);
    assert(frame.pc == other.def.*.bytecode);
    assert(frame.env == null);
    assert(frame.flags & c.JANET_STACKFRAME_TAILCALL != 0);
    // The entrance flag belongs to the frame, not to the function in it, and a
    // tail call must not clear it.
    assert(frame.flags & c.JANET_STACKFRAME_ENTRANCE != 0);

    assert(harness.integerIs(slot(fiber, base), 30));
    assert(harness.integerIs(slot(fiber, base + 1), 40));
    assertNilFrom(fiber, base + 2, base + other.def.*.slotcount);
    assert(fiber.stacktop == base + other.def.*.slotcount + frame_size);
    assert(fiber.stackstart == fiber.stacktop);
}

fn theFuncframeTailArityRejection(add: *c.JanetFunction, other: *c.JanetFunction) raise.Raising(void) {
    const args = [_]c.Janet{ harness.wrapInteger(1), harness.wrapInteger(2) };
    const fiber = rootedFiber(add, 2, &args);
    try fiber_core.push(fiber, harness.wrapInteger(9));

    const frame = fiber.frame;
    const stackstart = fiber.stackstart;
    const stacktop = fiber.stacktop;
    assert(c.janet_fiber_funcframe_tail(fiber, other) == 1);
    assert(fiber.frame == frame);
    assert(fiber.stackstart == stackstart);
    assert(fiber.stacktop == stacktop);
    assert(currentFrame(fiber).func == add);
}

/// The variadic tail of a tail call is built before the arguments move,
/// because the move copies the tail's slot along with them. Getting that order
/// wrong moves an uninitialised slot and loses the tail.
fn theFuncframeTailVarargs(add: *c.JanetFunction, rest: *c.JanetFunction) raise.Raising(void) {
    const args = [_]c.Janet{ harness.wrapInteger(1), harness.wrapInteger(2) };
    var fiber = rootedFiber(add, 2, &args);
    var base = fiber.frame;

    try fiber_core.push3(
        fiber,
        harness.wrapInteger(7),
        harness.wrapInteger(8),
        harness.wrapInteger(9),
    );
    assert(c.janet_fiber_funcframe_tail(fiber, rest) == 0);

    assert(harness.integerIs(slot(fiber, base), 7));
    var tail = slot(fiber, base + rest.def.*.arity);
    assert(harness.isType(tail, c.JANET_TUPLE));
    const tuple = c.janet_unwrap_tuple(tail);
    assert(c.janet_tuple_length(tuple) == 2);
    assert(harness.integerIs(tuple[0], 8));
    assert(harness.integerIs(tuple[1], 9));

    // An empty tail in a tail call takes the other branch, which has to grow
    // the stack itself before it can nil the gap it leaves behind.
    fiber = rootedFiber(add, 2, &args);
    base = fiber.frame;
    try fiber_core.push(fiber, harness.wrapInteger(5));
    assert(c.janet_fiber_funcframe_tail(fiber, rest) == 0);
    assert(harness.integerIs(slot(fiber, base), 5));
    tail = slot(fiber, base + rest.def.*.arity);
    assert(harness.isType(tail, c.JANET_TUPLE));
    assert(c.janet_tuple_length(c.janet_unwrap_tuple(tail)) == 0);
}

// ----------------------------------------------------------------- c frames

fn aCfunction(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    _ = argc;
    _ = argv;
    return c.janet_wrap_nil();
}

/// A C frame carries the function in the slot a Janet frame uses for its
/// program counter, and is recognised by its null `func`.
fn theCframeAndPopframe(add: *c.JanetFunction) raise.Raising(void) {
    const args = [_]c.Janet{ harness.wrapInteger(1), harness.wrapInteger(2) };
    const fiber = rootedFiber(add, 2, &args);
    const base = fiber.frame;
    var stacktop = fiber.stacktop;

    try fiber_core.push2(fiber, harness.wrapInteger(3), harness.wrapInteger(4));
    const cfun = raise.stored(&aCfunction);
    c.janet_fiber_cframe(fiber, cfun);
    const frame = currentFrame(fiber);

    assert(fiber.frame == stacktop);
    assert(frame.func == null);
    assert(@intFromPtr(frame.pc) == @intFromPtr(cfun));
    assert(frame.env == null);
    assert(frame.flags == 0);
    assert(frame.prevframe == base);
    assert(fiber.stacktop == stacktop + 2 + frame_size);
    assert(fiber.stackstart == fiber.stacktop);
    // The arguments stay where they were pushed, below the new frame.
    assert(harness.integerIs(slot(fiber, fiber.frame), 3));
    assert(harness.integerIs(slot(fiber, fiber.frame + 1), 4));

    c.janet_fiber_popframe(fiber);
    assert(fiber.frame == base);
    assert(fiber.stacktop == stacktop);
    assert(fiber.stackstart == stacktop);
    assert(currentFrame(fiber).func == add);

    // Popping the outermost frame is a no-op rather than an underflow. The
    // fiber stays rooted for the rest of the run, so it is put back into a
    // state the collector can walk.
    c.janet_fiber_popframe(fiber);
    assert(fiber.frame == 0);
    stacktop = fiber.stacktop;
    c.janet_fiber_popframe(fiber);
    assert(fiber.frame == 0);
    assert(fiber.stacktop == stacktop);
    assert(fiber.stackstart == stacktop);
}

// ------------------------------------------------------------------ pushes

fn thePushes(add: *c.JanetFunction) raise.Raising(void) {
    const args = [_]c.Janet{ harness.wrapInteger(1), harness.wrapInteger(2) };
    const fiber = rootedFiber(add, 2, &args);
    const start = fiber.stacktop;

    try fiber_core.push(fiber, harness.wrapInteger(100));
    assert(fiber.stacktop == start + 1);
    try fiber_core.push2(fiber, harness.wrapInteger(101), harness.wrapInteger(102));
    assert(fiber.stacktop == start + 3);
    try fiber_core.push3(
        fiber,
        harness.wrapInteger(103),
        harness.wrapInteger(104),
        harness.wrapInteger(105),
    );
    assert(fiber.stacktop == start + 6);
    const values = [_]c.Janet{
        harness.wrapInteger(106),
        harness.wrapInteger(107),
        harness.wrapInteger(108),
    };
    try fiber_core.pushn(fiber, &values, 3);
    assert(fiber.stacktop == start + 9);
    var i: i32 = 0;
    while (i < 9) : (i += 1) assert(harness.integerIs(slot(fiber, start + i), 100 + i));

    // A zero-length push accepts a null array. That is what `safe_memcpy` is
    // for — `memcpy` with a null source is undefined however long it is told
    // to copy — and `pushn` is called that way.
    try fiber_core.pushn(fiber, null, 0);
    assert(fiber.stacktop == start + 9);

    // Growth doubles what was needed, so a fiber that is exactly full doubles
    // its capacity on the next single push.
    while (fiber.stacktop < fiber.capacity) {
        try fiber_core.push(fiber, harness.wrapInteger(0));
    }
    assert(fiber.stacktop == fiber.capacity);
    var old_capacity = fiber.capacity;
    try fiber_core.push(fiber, harness.wrapInteger(1));
    assert(fiber.capacity == 2 * old_capacity);

    // A multi-value push sizes the growth from the top it is about to reach,
    // not from the top it starts at.
    while (fiber.stacktop < fiber.capacity - 1) {
        try fiber_core.push(fiber, harness.wrapInteger(0));
    }
    old_capacity = fiber.capacity;
    try fiber_core.push3(
        fiber,
        harness.wrapInteger(1),
        harness.wrapInteger(2),
        harness.wrapInteger(3),
    );
    assert(fiber.capacity == 2 * (old_capacity + 2));
}

/// The four bounds, one apart, all four reached by import. The header comment
/// has the argument for why they are no longer eight cases.
fn thePushBounds(add: *c.JanetFunction) raise.Raising(void) {
    const args = [_]c.Janet{ harness.wrapInteger(1), harness.wrapInteger(2) };
    const fiber = rootedFiber(add, 2, &args);
    const saved = fiber.stacktop;
    const zero = harness.wrapInteger(0);

    // `janet_fiber_push`'s face case stood here until Phase 11 Part 12 spent
    // the face; the header says why it could not survive it.
    fiber.stacktop = std.math.maxInt(i32);
    assert(harness.raised(fiber_core.push, .{ fiber, zero }).?.says("stack overflow"));

    fiber.stacktop = std.math.maxInt(i32) - 1;
    assert(harness.raised(fiber_core.push2, .{ fiber, zero, zero }).?.says("stack overflow"));

    fiber.stacktop = std.math.maxInt(i32) - 2;
    assert(harness.raised(fiber_core.push3, .{ fiber, zero, zero, zero }).?.says("stack overflow"));

    const values = [_]c.Janet{ zero, zero, zero };
    fiber.stacktop = std.math.maxInt(i32) - 2;
    assert(harness.raised(fiber_core.pushn, .{ fiber, &values, @as(i32, 3) }).?.says("stack overflow"));

    // One below each bound still succeeds, so the assertions above are testing
    // a boundary rather than a poisoned fiber. The capacity is raised first
    // because a push that is allowed to proceed does write.
    fiber.stacktop = saved;
    try fiber_core.push(fiber, harness.wrapInteger(7));
    assert(fiber.stacktop == saved + 1);

    fiber.stacktop = saved;
}

/// The whole path, reached the only way it can be: through `run_vm`.
///
/// `JOP_PUSH_ARRAY` is the one push whose count comes from a value rather than
/// from the instruction, so an array claiming `INT32_MAX` elements drives
/// `pushn` past its bound without the contract having to reach inside a
/// running fiber. Nothing dereferences the claim — `janet_indexed_view` copies
/// the pointer and the count, and `pushn` checks the count first — but the
/// collector would, so the array exists only inside a `janet_gclock`.
///
/// What this observes that the section above cannot: the raise leaves
/// `run_vm`'s frame as a returned error, crosses the loop, and arrives at
/// `janet_pcall` as a signal.
fn anOverflowThroughTheInterpreter() void {
    const splice = compileFunction("(fn [f xs] (f ;xs))");
    const identity = compileFunction("(fn [& xs] xs)");
    const arr = c.janet_array(4);
    const args = [_]c.Janet{ c.janet_wrap_function(identity), c.janet_wrap_array(arr) };
    var out = c.janet_wrap_nil();

    const handle = c.janet_gclock();
    arr.*.count = std.math.maxInt(i32);
    var sig = c.janet_pcall(splice, 2, &args, &out, null);
    arr.*.count = 0;
    c.janet_gcunlock(handle);

    assert(sig == c.JANET_SIGNAL_ERROR);
    assert(harness.stringValueIs(out, "stack overflow"));

    // And the same call with an honest array returns, so the assertion above
    // is about the count rather than about splicing.
    arr.*.count = 2;
    arr.*.data[0] = harness.wrapInteger(11);
    arr.*.data[1] = harness.wrapInteger(12);
    sig = c.janet_pcall(splice, 2, &args, &out, null);
    assert(sig == c.JANET_SIGNAL_OK);
    assert(harness.isType(out, c.JANET_TUPLE));
    assert(c.janet_tuple_length(c.janet_unwrap_tuple(out)) == 2);
}

// --------------------------------------------------- function environments

/// `janet_env_valid` exists for unmarshalled environments, which record their
/// stack offset negated and are trusted only if a live frame of the fiber they
/// name still matches them in offset, identity, and slot count. Each of those
/// three is checked separately, because a validator that ignored one would
/// pass every test built only from valid input.
fn theEnvironmentValidator(add: *c.JanetFunction, other: *c.JanetFunction) void {
    const args = [_]c.Janet{ harness.wrapInteger(1), harness.wrapInteger(2) };
    const fiber = rootedFiber(add, 2, &args);
    var env: c.JanetFuncEnv = std.mem.zeroes(c.JanetFuncEnv);
    var decoy: c.JanetFuncEnv = std.mem.zeroes(c.JanetFuncEnv);

    // A non-negative offset is already on the stack and is accepted as is.
    env.offset = 4;
    assert(c.janet_env_valid(&env) == 1);
    assert(env.offset == 4);

    // The matching case restores the offset's sign.
    env.offset = -fiber.frame;
    env.length = add.def.*.slotcount;
    env.as.fiber = fiber;
    currentFrame(fiber).env = &env;
    assert(c.janet_env_valid(&env) == 1);
    assert(env.offset == fiber.frame);

    // Wrong offset: no frame lives there.
    env.offset = -(fiber.frame + 1);
    assert(c.janet_env_valid(&env) == 0);
    assert(env.offset == 0);
    assert(env.length == 0);
    assert(env.as.values == null);

    // Right offset, but the frame points at a different environment.
    env.offset = -fiber.frame;
    env.length = add.def.*.slotcount;
    env.as.fiber = fiber;
    currentFrame(fiber).env = &decoy;
    assert(c.janet_env_valid(&env) == 0);
    assert(env.offset == 0);

    // Right offset and identity, but a slot count the frame's function does
    // not have.
    env.offset = -fiber.frame;
    env.length = other.def.*.slotcount + 1;
    env.as.fiber = fiber;
    currentFrame(fiber).env = &env;
    assert(c.janet_env_valid(&env) == 0);
    assert(env.offset == 0);

    currentFrame(fiber).env = null;
}

/// An environment is detached when its fiber can no longer change the slots it
/// points at. Until then it must keep sharing them, which is what makes a
/// closure over a running fiber see that fiber's updates.
fn anEnvironmentDetachesWhenItsFiberStops(add: *c.JanetFunction) void {
    const args = [_]c.Janet{ harness.wrapInteger(1), harness.wrapInteger(2) };
    const fiber = rootedFiber(add, 2, &args);
    // This half wants the unfiltered copy, which is what a function with no
    // inner closure gets.
    assert(add.def.*.closure_bitset == null);

    var env: c.JanetFuncEnv = std.mem.zeroes(c.JanetFuncEnv);
    env.offset = fiber.frame;
    env.length = add.def.*.slotcount;
    env.as.fiber = fiber;

    setStatus(fiber, c.JANET_STATUS_PENDING);
    c.janet_env_maybe_detach(&env);
    assert(env.offset == fiber.frame);
    assert(env.as.fiber == fiber);

    setStatus(fiber, c.JANET_STATUS_DEAD);
    c.janet_env_maybe_detach(&env);
    assert(env.offset == 0);
    assert(env.length == add.def.*.slotcount);
    assert(env.as.values != null);
    assert(env.as.values != fiber.data + @as(usize, @intCast(fiber.frame)));
    assert(harness.integerIs(env.as.values[0], 1));
    assert(harness.integerIs(env.as.values[1], 2));

    // The copy is independent: the fiber's slots may still be reused.
    fiber.data[@intCast(fiber.frame)] = harness.wrapInteger(99);
    assert(harness.integerIs(env.as.values[0], 1));

    c.janet_free(env.as.values);
}

/// A detached copy keeps only the slots an inner closure actually captured.
/// The rest are nil'd rather than copied, which is what stops a closure from
/// rooting every local of the frame it was made in.
fn detachHonoursTheClosureBitset(capturing: *c.JanetFunction) void {
    const args = [_]c.Janet{ harness.wrapInteger(41), harness.wrapInteger(42) };
    const fiber = rootedFiber(capturing, 2, &args);
    const bitset = capturing.def.*.closure_bitset;
    assert(bitset != null);

    var env: c.JanetFuncEnv = std.mem.zeroes(c.JanetFuncEnv);
    env.offset = fiber.frame;
    env.length = capturing.def.*.slotcount;
    env.as.fiber = fiber;

    setStatus(fiber, c.JANET_STATUS_DEAD);
    c.janet_env_maybe_detach(&env);
    assert(env.offset == 0);
    assert(env.as.values != null);

    var kept: i32 = 0;
    var i: i32 = 0;
    while (i < env.length) : (i += 1) {
        const captured = (bitset[@intCast(i >> 5)] >> @intCast(i & 31)) & 1;
        if (captured != 0) {
            kept += 1;
            assert(harness.equals(env.as.values[@intCast(i)], slot(fiber, fiber.frame + i)));
        } else {
            assert(harness.isType(env.as.values[@intCast(i)], c.JANET_NIL));
        }
    }
    // A bitset that kept nothing, or kept everything, would make the loop
    // above vacuous in one direction or the other.
    assert(kept > 0);
    assert(kept < env.length);

    c.janet_free(env.as.values);
}

// --------------------------------------------------------------- inspection

fn statusAndResumability(add: *c.JanetFunction) void {
    const args = [_]c.Janet{ harness.wrapInteger(1), harness.wrapInteger(2) };
    const fiber = rootedFiber(add, 2, &args);

    var status: c_int = c.JANET_STATUS_DEAD;
    while (status <= c.JANET_STATUS_ALIVE) : (status += 1) {
        const finished = status == c.JANET_STATUS_DEAD or
            status == c.JANET_STATUS_ERROR or
            (status >= c.JANET_STATUS_USER0 and status <= c.JANET_STATUS_USER4);
        fiber.flags = c.JANET_FIBER_MASK_YIELD | c.JANET_FIBER_BREAKPOINT;
        setStatus(fiber, status);
        assert(@as(c_int, @intCast(c.janet_fiber_status(fiber))) == status);
        assert((c.janet_fiber_can_resume(fiber) != 0) == !finished);
        // Setting a status must leave the other flag bits alone.
        assert(fiber.flags & c.JANET_FIBER_MASK_YIELD != 0);
        assert(fiber.flags & c.JANET_FIBER_BREAKPOINT != 0);
    }
}

fn theCurrentAndRootFiber(add: *c.JanetFunction) void {
    const args = [_]c.Janet{ harness.wrapInteger(1), harness.wrapInteger(2) };
    const saved_fiber = vm().fiber;
    const saved_root = vm().root_fiber;
    const fiber = rootedFiber(add, 2, &args);

    assert(c.janet_current_fiber() == saved_fiber);
    assert(c.janet_root_fiber() == saved_root);

    vm().fiber = fiber;
    vm().root_fiber = null;
    assert(c.janet_current_fiber() == fiber);
    assert(c.janet_root_fiber() == null);

    vm().fiber = saved_fiber;
    vm().root_fiber = saved_root;
}

// ------------------------------------------------------------------- main

fn body() raise.Raising(void) {
    test_env = c.janet_core_env(null);
    c.janet_gcroot(c.janet_wrap_table(test_env));

    const add = compileFunction("(fn [a b] (+ a b))");
    const other = compileFunction("(fn [x y] (let [p (* x y) q (+ x y) r (- x y)] [p q r p q r]))");
    const rest = compileFunction("(fn [a & r] r)");
    const keyed = compileFunction("(fn [a &keys kw] kw)");
    const capturing = compileFunction("(fn [a b] (def unused (+ a b)) (fn [] a))");
    // The tail-call cases need two functions of the same arity and different
    // slot counts, so that a wrong slot count shows up as a wrong stack top.
    assert(other.def.*.slotcount != add.def.*.slotcount);

    theFuncframeLayout(add);
    try theFuncframeArityRejection(add);
    theFuncframeVarargs(rest);
    theFuncframeStructargs(keyed);
    try theFuncframeTail(add, other);
    try theFuncframeTailArityRejection(add, other);
    try theFuncframeTailVarargs(add, rest);
    try theCframeAndPopframe(add);
    try thePushes(add);
    try thePushBounds(add);
    anOverflowThroughTheInterpreter();
    theEnvironmentValidator(add, other);
    anEnvironmentDetachesWhenItsFiberStops(add);
    detachHonoursTheClosureBitset(capturing);
    statusAndResumability(add);
    theCurrentAndRootFiber(add);
}

pub fn run() void {
    setcapacityChargesTheBudget();
    theBudgetIsPerThread() catch @panic("fiber_core: could not spawn a thread");

    _ = c.janet_init();
    body() catch @panic("fiber_core: a fiber operation raised unexpectedly");
    c.janet_deinit();

    std.debug.print("fiber core contract ok\n", .{});
}
