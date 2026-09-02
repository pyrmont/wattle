//! Behavioral contract for the fiber stack-frame machinery.
//!
//! Almost everything here is exercised constantly by the Janet suites — every
//! function call in the language goes through `fibers.funcframe` — so
//! what this file is for is the edges the suites reach only by accident: the
//! arity boundaries, an empty variadic tail against a non-empty one, a tail
//! call that has to move its arguments down over the frame it is replacing,
//! and the environment validator, whose whole job is to reject input the
//! suites never produce.
//!
//! ## The four pushes have no abi left
//!
//! Each of `fibers.push`, `pushn`, `push2` and `push3` raises "stack overflow"
//! by returning `raise.Error`, and nothing wraps that into a report. A
//! contract on the far side of a symbol table would have to test both forms,
//! because they would be two mechanisms carrying one decision.
//!
//! All four are gone: the interpreter reaches the kernels by import, and a C
//! contract was the last caller of each.
//!
//! **This file predicted that and had to be edited for it**, which is the
//! point worth keeping. The abi case here was the last caller of the push abi
//! in the whole tree -- a contract testing an abi that existed for nobody -- so deleting the abi turned it into a compile error
//! naming its own line. An abi whose only remaining caller is the contract
//! that tests it is an abi with no callers; the test is not a use.
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
const repr = @import("repr");
const constants = @import("constants");
const options = @import("options");
const raise = @import("subsystems").raise;
const value = @import("subsystems").value;
const harness = @import("harness.zig");
const functions = @import("subsystems").value.functions;
const gc_alloc = @import("subsystems").gc_alloc;
const utils = @import("subsystems").utils;
const core_env = @import("subsystems").env;
const vm_entry = @import("subsystems").vm_entry;
const wrap = @import("subsystems").value.wrap;
const vm_lifecycle = @import("subsystems").lifecycle;
const arrays = @import("subsystems").value.arrays;
const fibers = @import("subsystems").value.fibers;
const tuples = @import("subsystems").value.tuples;
const structs = @import("subsystems").value.structs;
const abi = @import("abi");
const vm_state = @import("subsystems").vm_state;
const tables = @import("subsystems").value.tables;

const expect = @import("expect.zig").expect;

/// `options.ev` is `hasEv(options)`, which is already
/// `ev and !single_threaded`. Windows is cross-compiled and never executed
/// here, so its path is left out rather than written blind — the same
/// condition, and the same reason, as `test/gc_stress.zig`.
const has_threads = options.ev and builtin.os.tag != .windows;

const frame_size: i32 = constants.JANET_FRAME_SIZE;

var test_env: *tables.Table = undefined;

// The three frame helpers this file needs: the cast from a stack slot to the
// header below it, that composed with the fiber's frame index, and a
// read-modify-write over the status field. Six lines here rather than at each
// of the twenty sites below.

fn frameAt(fiber: *fibers.Fiber, index: i32) *vm_state.StackFrame {
    const base = fiber.data.? + @as(usize, @intCast(index));
    return @ptrCast(@alignCast(base - @as(usize, @intCast(frame_size))));
}

fn currentFrame(fiber: *fibers.Fiber) *vm_state.StackFrame {
    return frameAt(fiber, fiber.frame);
}

fn setStatus(fiber: *fibers.Fiber, status: fibers.FiberStatus) void {
    fiber.flags.status = @intCast(@intFromEnum(status));
}

fn slot(fiber: *fibers.Fiber, index: i32) repr.Value {
    return fiber.data.?[@intCast(index)];
}

// ------------------------------------------------------- without a runtime

/// `fibers.setcapacity` is reachable without a live VM: it resizes a plain
/// allocation and charges the collector's byte budget, and touches nothing
/// else. Testing it here keeps the arithmetic visible instead of
/// buried under a live heap whose budget is moving for other reasons.
fn setcapacityChargesTheBudget() void {
    var fiber: fibers.Fiber = std.mem.zeroes(fibers.Fiber);
    harness.vm().gc.next_collection = 0;

    fibers.setcapacity(&fiber, 40);
    expect(fiber.capacity == 40);
    expect(fiber.data != null);
    expect(harness.vm().gc.next_collection == 40 * @sizeOf(repr.Value));

    // Growing charges the difference, not the new total.
    fibers.setcapacity(&fiber, 100);
    expect(fiber.capacity == 100);
    expect(harness.vm().gc.next_collection == 100 * @sizeOf(repr.Value));

    // Shrinking gives the difference back. The C original writes this as
    // `next_collection += sizeof(Janet) * diff` with a negative `diff`, so the
    // refund is an unsigned wraparound rather than a subtraction; the result is
    // the same and the spelling is what a port could get wrong.
    const before = harness.vm().gc.next_collection;
    fibers.setcapacity(&fiber, 60);
    expect(fiber.capacity == 60);
    expect(harness.vm().gc.next_collection == before - 40 * @sizeOf(repr.Value));

    utils.free(fiber.data);
    harness.vm().gc.next_collection = 0;
}

var child_charge: usize = 0;
var child_saw_main: usize = 0;

fn chargeChildBudget() void {
    var fiber: fibers.Fiber = std.mem.zeroes(fibers.Fiber);
    child_saw_main = harness.vm().gc.next_collection;
    fibers.setcapacity(&fiber, 16);
    child_charge = harness.vm().gc.next_collection;
    utils.free(fiber.data);
}

/// The budget belongs to the calling thread's VM. This is the one property the
/// port could plausibly get wrong while still linking and passing everything
/// else: reaching a process-wide VM instead of a thread-local one is invisible
/// until two threads run at once.
fn theBudgetIsPerThread() !void {
    if (!has_threads) return;

    harness.vm().gc.next_collection = 4096;
    const main_before = harness.vm().gc.next_collection;
    const thread = try std.Thread.spawn(.{}, chargeChildBudget, .{});
    thread.join();

    expect(child_saw_main == 0);
    expect(child_charge == 16 * @sizeOf(repr.Value));
    expect(harness.vm().gc.next_collection == main_before);
    harness.vm().gc.next_collection = 0;
}

// ----------------------------------------------------------------- helpers

fn compileFunction(source: [*:0]const u8) *functions.Function {
    var out = wrap.fromNil();
    expect(core_env.dostring(test_env, source, "fiber-core-test", &out) == 0);
    expect(harness.isType(out, repr.Tag.function));
    gc_alloc.gcroot(out);
    return wrap.toFunction(out);
}

fn rootedFiber(func: *functions.Function, argv: []const repr.Value) *fibers.Fiber {
    const fiber = fibers.new(func, 32, argv) catch unreachable;
    gc_alloc.gcroot(wrap.fromFiber(fiber));
    return fiber;
}

fn assertNilFrom(fiber: *fibers.Fiber, first: i32, last: i32) void {
    var i = first;
    while (i < last) : (i += 1) expect(harness.isType(slot(fiber, i), repr.Tag.nil));
}

// --------------------------------------------------------------- funcframes

/// A fresh fiber's first frame: base at `JANET_FRAME_SIZE`, arguments at the
/// frame's slot 0, every remaining slot nil because the collector walks them.
fn theFuncframeLayout(add: *functions.Function) void {
    const args = [_]repr.Value{ harness.wrapInteger(11), harness.wrapInteger(22) };
    const fiber = rootedFiber(add, args[0..2]);
    const frame = currentFrame(fiber);

    expect(fiber.frame == frame_size);
    expect(fiber.stackstart == fiber.stacktop);
    expect(fiber.stacktop == frame_size + add.def.?.slotcount + frame_size);
    expect(fiber.capacity >= fiber.stacktop);

    expect(frame.func == add);
    expect(frame.pc == add.def.?.bytecode);
    expect(frame.env == null);
    expect(frame.prevframe == 0);
    // `fibers.reset` adds ENTRANCE after the frame is pushed, so the frame
    // itself must have been left with no other flags set.
    expect(@as(i32, @bitCast(frame.flags)) == constants.JANET_STACKFRAME_ENTRANCE);

    expect(harness.integerIs(slot(fiber, fiber.frame), 11));
    expect(harness.integerIs(slot(fiber, fiber.frame + 1), 22));
    assertNilFrom(fiber, fiber.frame + 2, fiber.frame + add.def.?.slotcount);
}

/// A rejected arity must leave the fiber exactly as it was, because
/// `vm/entry.zig`'s `pcall` is built on the return value rather than on
/// recovering from a partially built frame.
fn theFuncframeArityRejection(add: *functions.Function) raise.Raising(void) {
    const args = [_]repr.Value{
        harness.wrapInteger(1),
        harness.wrapInteger(2),
        harness.wrapInteger(3),
    };

    if (fibers.new(add, 32, args[0..1])) |_| expect(false) else |_| {}
    if (fibers.new(add, 32, &args)) |_| expect(false) else |_| {}

    const fiber = rootedFiber(add, args[0..2]);
    const frame = fiber.frame;
    const stackstart = fiber.stackstart;
    const stacktop = fiber.stacktop;

    try fibers.push(fiber, harness.wrapInteger(5));
    expect(std.meta.isError(fibers.funcframe(fiber, add)));
    expect(fiber.frame == frame);
    expect(fiber.stackstart == stackstart);
    expect(fiber.stacktop == stacktop + 1);
}

/// A variadic tail is a tuple, and an empty one is the empty tuple rather than
/// a missing slot — the slot is a live local of the callee either way.
fn theFuncframeVarargs(rest: *functions.Function) void {
    const args = [_]repr.Value{
        harness.wrapInteger(1),
        harness.wrapInteger(2),
        harness.wrapInteger(3),
    };

    var fiber = rootedFiber(rest, args[0..3]);
    var tail = slot(fiber, fiber.frame + rest.def.?.arity);
    expect(harness.isType(tail, repr.Tag.tuple));
    const tuple = wrap.toTuple(tail);
    expect(tuples.head(tuple).length == 2);
    expect(harness.integerIs(tuple[0], 2));
    expect(harness.integerIs(tuple[1], 3));

    fiber = rootedFiber(rest, args[0..1]);
    tail = slot(fiber, fiber.frame + rest.def.?.arity);
    expect(harness.isType(tail, repr.Tag.tuple));
    expect(tuples.head(wrap.toTuple(tail)).length == 0);
}

/// `&keys` sets the funcdef's `structarg` flag, and the tail is built with
/// `structs.put` instead of `tuples.n`. An odd-length tail drops its last
/// value, which is what the C original's own comment says it does and what
/// `makeStructN`'s `i + 1 < len` makes true: the loop condition is the whole
/// difference between ignoring that value and pairing it with the slot past
/// the arguments.
fn theFuncframeStructargs(keyed: *functions.Function) void {
    const args = [_]repr.Value{
        harness.wrapInteger(1),
        value.fromBytes("a", .keyword),
        harness.wrapInteger(7),
        value.fromBytes("b", .keyword),
        harness.wrapInteger(8),
    };

    var fiber = rootedFiber(keyed, args[0..5]);
    var tail = slot(fiber, fiber.frame + keyed.def.?.arity);
    expect(harness.isType(tail, repr.Tag.@"struct"));
    const structure = wrap.toStruct(tail);
    expect(structs.head(structure).length == 2);
    expect(harness.integerIs(harness.field(structure, "a"), 7));
    expect(harness.integerIs(harness.field(structure, "b"), 8));

    fiber = rootedFiber(keyed, args[0..1]);
    tail = slot(fiber, fiber.frame + keyed.def.?.arity);
    expect(harness.isType(tail, repr.Tag.@"struct"));
    expect(structs.head(wrap.toStruct(tail)).length == 0);

    // An odd-length tail: the last key has no value, so it is dropped rather
    // than paired with whatever the slot past the arguments holds. Four
    // arguments -- one fixed and three keyed -- so the struct is one pair.
    const odd = [_]repr.Value{
        harness.wrapInteger(1),
        value.fromBytes("a", .keyword),
        harness.wrapInteger(7),
        value.fromBytes("b", .keyword),
    };
    fiber = rootedFiber(keyed, odd[0..4]);
    tail = slot(fiber, fiber.frame + keyed.def.?.arity);
    expect(harness.isType(tail, repr.Tag.@"struct"));
    const oddstruct = wrap.toStruct(tail);
    expect(structs.head(oddstruct).length == 1);
    expect(harness.integerIs(harness.field(oddstruct, "a"), 7));
    expect(harness.isType(harness.field(oddstruct, "b"), repr.Tag.nil));
}

// --------------------------------------------------------------- tail calls

/// A tail call reuses the current frame: the arguments move down over the
/// outgoing function's slots, the rest are nil'd, and the frame is repointed
/// without its base moving.
fn theFuncframeTail(add: *functions.Function, other: *functions.Function) raise.Raising(void) {
    const args = [_]repr.Value{ harness.wrapInteger(1), harness.wrapInteger(2) };
    const fiber = rootedFiber(add, args[0..2]);
    const base = fiber.frame;

    try fibers.push2(fiber, harness.wrapInteger(30), harness.wrapInteger(40));
    expect(!std.meta.isError(fibers.funcframeTail(fiber, other)));

    const frame = currentFrame(fiber);
    expect(fiber.frame == base);
    expect(frame.func == other);
    expect(frame.pc == other.def.?.bytecode);
    expect(frame.env == null);
    expect(@as(i32, @bitCast(frame.flags)) & constants.JANET_STACKFRAME_TAILCALL != 0);
    // The entrance flag belongs to the frame, not to the function in it, and a
    // tail call must not clear it.
    expect(@as(i32, @bitCast(frame.flags)) & constants.JANET_STACKFRAME_ENTRANCE != 0);

    expect(harness.integerIs(slot(fiber, base), 30));
    expect(harness.integerIs(slot(fiber, base + 1), 40));
    assertNilFrom(fiber, base + 2, base + other.def.?.slotcount);
    expect(fiber.stacktop == base + other.def.?.slotcount + frame_size);
    expect(fiber.stackstart == fiber.stacktop);
}

fn theFuncframeTailArityRejection(add: *functions.Function, other: *functions.Function) raise.Raising(void) {
    const args = [_]repr.Value{ harness.wrapInteger(1), harness.wrapInteger(2) };
    const fiber = rootedFiber(add, args[0..2]);
    try fibers.push(fiber, harness.wrapInteger(9));

    const frame = fiber.frame;
    const stackstart = fiber.stackstart;
    const stacktop = fiber.stacktop;
    expect(std.meta.isError(fibers.funcframeTail(fiber, other)));
    expect(fiber.frame == frame);
    expect(fiber.stackstart == stackstart);
    expect(fiber.stacktop == stacktop);
    expect(currentFrame(fiber).func == add);
}

/// The variadic tail of a tail call is built before the arguments move,
/// because the move copies the tail's slot along with them. Getting that order
/// wrong moves an uninitialised slot and loses the tail.
fn theFuncframeTailVarargs(add: *functions.Function, rest: *functions.Function) raise.Raising(void) {
    const args = [_]repr.Value{ harness.wrapInteger(1), harness.wrapInteger(2) };
    var fiber = rootedFiber(add, args[0..2]);
    var base = fiber.frame;

    try fibers.push3(
        fiber,
        harness.wrapInteger(7),
        harness.wrapInteger(8),
        harness.wrapInteger(9),
    );
    expect(!std.meta.isError(fibers.funcframeTail(fiber, rest)));

    expect(harness.integerIs(slot(fiber, base), 7));
    var tail = slot(fiber, base + rest.def.?.arity);
    expect(harness.isType(tail, repr.Tag.tuple));
    const tuple = wrap.toTuple(tail);
    expect(tuples.head(tuple).length == 2);
    expect(harness.integerIs(tuple[0], 8));
    expect(harness.integerIs(tuple[1], 9));

    // An empty tail in a tail call takes the other branch, which has to grow
    // the stack itself before it can nil the gap it leaves behind.
    fiber = rootedFiber(add, args[0..2]);
    base = fiber.frame;
    try fibers.push(fiber, harness.wrapInteger(5));
    expect(!std.meta.isError(fibers.funcframeTail(fiber, rest)));
    expect(harness.integerIs(slot(fiber, base), 5));
    tail = slot(fiber, base + rest.def.?.arity);
    expect(harness.isType(tail, repr.Tag.tuple));
    expect(tuples.head(wrap.toTuple(tail)).length == 0);
}

// ----------------------------------------------------------------- c frames

fn aCfunction(argv: []repr.Value) raise.Raising(repr.Value) {
    _ = @as(i32, @intCast(argv.len));

    return wrap.fromNil();
}

/// A C frame carries the function in the slot a Janet frame uses for its
/// program counter, and is recognised by its null `func`.
fn theCframeAndPopframe(add: *functions.Function) raise.Raising(void) {
    const args = [_]repr.Value{ harness.wrapInteger(1), harness.wrapInteger(2) };
    const fiber = rootedFiber(add, args[0..2]);
    const base = fiber.frame;
    var stacktop = fiber.stacktop;

    try fibers.push2(fiber, harness.wrapInteger(3), harness.wrapInteger(4));
    const cfun = raise.stored(&aCfunction);
    fibers.cframe(fiber, cfun);
    const frame = currentFrame(fiber);

    expect(fiber.frame == stacktop);
    expect(frame.func == null);
    expect(@intFromPtr(frame.pc) == @intFromPtr(cfun));
    expect(frame.env == null);
    expect(@as(i32, @bitCast(frame.flags)) == 0);
    expect(frame.prevframe == base);
    expect(fiber.stacktop == stacktop + 2 + frame_size);
    expect(fiber.stackstart == fiber.stacktop);
    // The arguments stay where they were pushed, below the new frame.
    expect(harness.integerIs(slot(fiber, fiber.frame), 3));
    expect(harness.integerIs(slot(fiber, fiber.frame + 1), 4));

    fibers.popframe(fiber);
    expect(fiber.frame == base);
    expect(fiber.stacktop == stacktop);
    expect(fiber.stackstart == stacktop);
    expect(currentFrame(fiber).func == add);

    // Popping the outermost frame is a no-op rather than an underflow. The
    // fiber stays rooted for the rest of the run, so it is put back into a
    // state the collector can walk.
    fibers.popframe(fiber);
    expect(fiber.frame == 0);
    stacktop = fiber.stacktop;
    fibers.popframe(fiber);
    expect(fiber.frame == 0);
    expect(fiber.stacktop == stacktop);
    expect(fiber.stackstart == stacktop);
}

// ------------------------------------------------------------------ pushes

fn thePushes(add: *functions.Function) raise.Raising(void) {
    const args = [_]repr.Value{ harness.wrapInteger(1), harness.wrapInteger(2) };
    const fiber = rootedFiber(add, args[0..2]);
    const start = fiber.stacktop;

    try fibers.push(fiber, harness.wrapInteger(100));
    expect(fiber.stacktop == start + 1);
    try fibers.push2(fiber, harness.wrapInteger(101), harness.wrapInteger(102));
    expect(fiber.stacktop == start + 3);
    try fibers.push3(
        fiber,
        harness.wrapInteger(103),
        harness.wrapInteger(104),
        harness.wrapInteger(105),
    );
    expect(fiber.stacktop == start + 6);
    const values = [_]repr.Value{
        harness.wrapInteger(106),
        harness.wrapInteger(107),
        harness.wrapInteger(108),
    };
    try fibers.pushn(fiber, &values);
    expect(fiber.stacktop == start + 9);
    var i: i32 = 0;
    while (i < 9) : (i += 1) expect(harness.integerIs(slot(fiber, start + i), 100 + i));

    // A zero-length push accepts a null array. That is what `safe_memcpy` is
    // for — `memcpy` with a null source is undefined however long it is told
    // to copy — and `pushn` is called that way.
    try fibers.pushn(fiber, &.{});
    expect(fiber.stacktop == start + 9);

    // Growth doubles what was needed, so a fiber that is exactly full doubles
    // its capacity on the next single push.
    while (fiber.stacktop < fiber.capacity) {
        try fibers.push(fiber, harness.wrapInteger(0));
    }
    expect(fiber.stacktop == fiber.capacity);
    var old_capacity = fiber.capacity;
    try fibers.push(fiber, harness.wrapInteger(1));
    expect(fiber.capacity == 2 * old_capacity);

    // A multi-value push sizes the growth from the top it is about to reach,
    // not from the top it starts at.
    while (fiber.stacktop < fiber.capacity - 1) {
        try fibers.push(fiber, harness.wrapInteger(0));
    }
    old_capacity = fiber.capacity;
    try fibers.push3(
        fiber,
        harness.wrapInteger(1),
        harness.wrapInteger(2),
        harness.wrapInteger(3),
    );
    expect(fiber.capacity == 2 * (old_capacity + 2));
}

/// The four bounds, one apart, all four reached by import. The header comment
/// has the argument for why they are no longer eight cases.
fn thePushBounds(add: *functions.Function) raise.Raising(void) {
    const args = [_]repr.Value{ harness.wrapInteger(1), harness.wrapInteger(2) };
    const fiber = rootedFiber(add, args[0..2]);
    const saved = fiber.stacktop;
    const zero = harness.wrapInteger(0);

    // An abi case for the push stood here; the header says why it could not
    // survive the abi's removal.
    fiber.stacktop = std.math.maxInt(i32);
    expect(harness.raised(fibers.push, .{ fiber, zero }).?.says("stack overflow"));

    fiber.stacktop = std.math.maxInt(i32) - 1;
    expect(harness.raised(fibers.push2, .{ fiber, zero, zero }).?.says("stack overflow"));

    fiber.stacktop = std.math.maxInt(i32) - 2;
    expect(harness.raised(fibers.push3, .{ fiber, zero, zero, zero }).?.says("stack overflow"));

    const values = [_]repr.Value{ zero, zero, zero };
    fiber.stacktop = std.math.maxInt(i32) - 2;
    expect(harness.raised(fibers.pushn, .{ fiber, @as([]const repr.Value, &values) }).?.says("stack overflow"));

    // One below each bound still succeeds, so the assertions above are testing
    // a boundary rather than a poisoned fiber. The capacity is raised first
    // because a push that is allowed to proceed does write.
    fiber.stacktop = saved;
    try fibers.push(fiber, harness.wrapInteger(7));
    expect(fiber.stacktop == saved + 1);

    fiber.stacktop = saved;
}

/// The whole path, reached the only way it can be: through `run_vm`.
///
/// `JOP_PUSH_ARRAY` is the one push whose count comes from a value rather than
/// from the instruction, so an array claiming `INT32_MAX` elements drives
/// `pushn` past its bound without the contract having to reach inside a
/// running fiber. Nothing dereferences the claim — `args.indexedView` copies
/// the pointer and the count, and `pushn` checks the count first — but the
/// collector would, so the array exists only inside a `gc.gclock`.
///
/// What this observes that the section above cannot: the raise leaves
/// `runVm`'s frame as a returned error, crosses the loop, and arrives at
/// `vm_entry.pcall` as a signal.
fn anOverflowThroughTheInterpreter() void {
    const splice = compileFunction("(fn [f xs] (f ;xs))");
    const identity = compileFunction("(fn [& xs] xs)");
    const arr = arrays.new(4);
    const args = [_]repr.Value{ wrap.fromFunction(identity), wrap.fromArray(arr) };

    const handle = gc_alloc.gclock();
    arr.count = std.math.maxInt(i32);
    var resumed = vm_entry.pcall(splice, &args, null);
    arr.count = 0;
    gc_alloc.gcunlock(handle);

    expect(resumed.signal == abi.Signal.@"error");
    expect(harness.stringValueIs(resumed.value, "stack overflow"));

    // And the same call with an honest array returns, so the assertion above
    // is about the count rather than about splicing.
    arr.count = 2;
    arr.slice()[0] = harness.wrapInteger(11);
    arr.slice()[1] = harness.wrapInteger(12);
    resumed = vm_entry.pcall(splice, &args, null);
    expect(resumed.signal == abi.Signal.ok);
    expect(harness.isType(resumed.value, repr.Tag.tuple));
    expect(tuples.head(wrap.toTuple(resumed.value)).length == 2);
}

// --------------------------------------------------- function environments

/// `functions.envValid` exists for unmarshalled environments, which record their
/// stack offset negated and are trusted only if a live frame of the fiber they
/// name still matches them in offset, identity, and slot count. Each of those
/// three is checked separately, because a validator that ignored one would
/// pass every test built only from valid input.
fn theEnvironmentValidator(add: *functions.Function, other: *functions.Function) void {
    const args = [_]repr.Value{ harness.wrapInteger(1), harness.wrapInteger(2) };
    const fiber = rootedFiber(add, args[0..2]);
    var env: functions.FuncEnv = std.mem.zeroes(functions.FuncEnv);
    var decoy: functions.FuncEnv = std.mem.zeroes(functions.FuncEnv);

    // A non-negative offset is already on the stack and is accepted as is.
    env.offset = 4;
    expect(functions.envValid(&env));
    expect(env.offset == 4);

    // The matching case restores the offset's sign.
    env.offset = -fiber.frame;
    env.length = add.def.?.slotcount;
    env.as.fiber = fiber;
    currentFrame(fiber).env = &env;
    expect(functions.envValid(&env));
    expect(env.offset == fiber.frame);

    // Wrong offset: no frame lives there.
    env.offset = -(fiber.frame + 1);
    expect(!functions.envValid(&env));
    expect(env.offset == 0);
    expect(env.length == 0);
    expect(env.as.values == null);

    // Right offset, but the frame points at a different environment.
    env.offset = -fiber.frame;
    env.length = add.def.?.slotcount;
    env.as.fiber = fiber;
    currentFrame(fiber).env = &decoy;
    expect(!functions.envValid(&env));
    expect(env.offset == 0);

    // Right offset and identity, but a slot count the frame's function does
    // not have.
    env.offset = -fiber.frame;
    env.length = other.def.?.slotcount + 1;
    env.as.fiber = fiber;
    currentFrame(fiber).env = &env;
    expect(!functions.envValid(&env));
    expect(env.offset == 0);

    currentFrame(fiber).env = null;
}

/// An environment is detached when its fiber can no longer change the slots it
/// points at. Until then it must keep sharing them, which is what makes a
/// closure over a running fiber see that fiber's updates.
fn anEnvironmentDetachesWhenItsFiberStops(add: *functions.Function) void {
    const args = [_]repr.Value{ harness.wrapInteger(1), harness.wrapInteger(2) };
    const fiber = rootedFiber(add, args[0..2]);
    // This half wants the unfiltered copy, which is what a function with no
    // inner closure gets.
    expect(add.def.?.closure_bitset == null);

    var env: functions.FuncEnv = std.mem.zeroes(functions.FuncEnv);
    env.offset = fiber.frame;
    env.length = add.def.?.slotcount;
    env.as.fiber = fiber;

    setStatus(fiber, fibers.FiberStatus.pending);
    functions.envMaybeDetach(&env);
    expect(env.offset == fiber.frame);
    expect(env.as.fiber == fiber);

    setStatus(fiber, fibers.FiberStatus.dead);
    functions.envMaybeDetach(&env);
    expect(env.offset == 0);
    expect(env.length == add.def.?.slotcount);
    expect(env.as.values != null);
    expect(env.as.values.? != fiber.data.? + @as(usize, @intCast(fiber.frame)));
    expect(harness.integerIs(env.as.values.?[0], 1));
    expect(harness.integerIs(env.as.values.?[1], 2));

    // The copy is independent: the fiber's slots may still be reused.
    fiber.data.?[@intCast(fiber.frame)] = harness.wrapInteger(99);
    expect(harness.integerIs(env.as.values.?[0], 1));

    utils.free(env.as.values);
}

/// An environment the validator rejects is already the empty off-stack
/// variant, so detaching it has nothing to do. The path matters because an
/// unmarshalled environment can name a frame that does not exist, and the
/// frame walk that drops it detaches whatever it finds.
fn detachingARejectedEnvironmentIsANoOp(add: *functions.Function) void {
    const args = [_]repr.Value{ harness.wrapInteger(1), harness.wrapInteger(2) };
    const fiber = rootedFiber(add, args[0..2]);

    var env: functions.FuncEnv = std.mem.zeroes(functions.FuncEnv);
    // A negative offset naming no frame of this fiber: what an unmarshalled
    // environment looks like when the stream is not one `marsh` wrote.
    env.offset = -(fiber.frame + 8);
    env.length = 2;
    env.as.fiber = fiber;

    functions.envDetach(&env);
    expect(env.offset == 0);
    expect(env.length == 0);
    expect(env.as.values == null);
}

/// A detached copy keeps only the slots an inner closure actually captured.
/// The rest are nil'd rather than copied, which is what stops a closure from
/// rooting every local of the frame it was made in.
fn detachHonoursTheClosureBitset(capturing: *functions.Function) void {
    const args = [_]repr.Value{ harness.wrapInteger(41), harness.wrapInteger(42) };
    const fiber = rootedFiber(capturing, args[0..2]);
    const bitset = capturing.def.?.closure_bitset;
    expect(bitset != null);

    var env: functions.FuncEnv = std.mem.zeroes(functions.FuncEnv);
    env.offset = fiber.frame;
    env.length = capturing.def.?.slotcount;
    env.as.fiber = fiber;

    setStatus(fiber, fibers.FiberStatus.dead);
    functions.envMaybeDetach(&env);
    expect(env.offset == 0);
    expect(env.as.values != null);

    var kept: i32 = 0;
    var i: i32 = 0;
    while (i < env.length) : (i += 1) {
        const captured = (bitset.?[@intCast(i >> 5)] >> @intCast(i & 31)) & 1;
        if (captured != 0) {
            kept += 1;
            expect(harness.equals(env.as.values.?[@intCast(i)], slot(fiber, fiber.frame + i)));
        } else {
            expect(harness.isType(env.as.values.?[@intCast(i)], repr.Tag.nil));
        }
    }
    // A bitset that kept nothing, or kept everything, would make the loop
    // above vacuous in one direction or the other.
    expect(kept > 0);
    expect(kept < env.length);

    utils.free(env.as.values);
}

// --------------------------------------------------------------- inspection

fn statusAndResumability(add: *functions.Function) void {
    const args = [_]repr.Value{ harness.wrapInteger(1), harness.wrapInteger(2) };
    const fiber = rootedFiber(add, args[0..2]);

    // Every member of the vocabulary, which an exhaustive walk over the enum
    // states rather than a numeric range that has to be kept in step with it.
    inline for (@typeInfo(fibers.FiberStatus).@"enum".fields) |field| {
        const status: fibers.FiberStatus = @enumFromInt(field.value);
        // The oracle, listed member by member. An `else` here would make the
        // contract agree with the subject about any status neither of them had
        // thought about, which is the disagreement worth catching.
        const finished = switch (status) {
            .dead, .@"error", .user0, .user1, .user2, .user3, .user4 => true,
            .debug, .pending, .user5, .user6, .user7, .user8, .user9, .new, .alive => false,
        };
        fiber.flags = .{ .traps = .of(&.{.yield}), .breakpoint = true };
        setStatus(fiber, status);
        expect(fibers.status(fiber) == status);
        expect(fibers.canResume(fiber) == !finished);
        // Setting a status must leave the other flag bits alone.
        expect(fiber.flags.traps.has(.yield));
        expect(fiber.flags.breakpoint);
    }
}

fn theCurrentAndRootFiber(add: *functions.Function) void {
    const args = [_]repr.Value{ harness.wrapInteger(1), harness.wrapInteger(2) };
    const saved_fiber = harness.vm().fiber;
    const saved_root = harness.vm().root_fiber;
    const fiber = rootedFiber(add, args[0..2]);

    expect(fibers.current() == saved_fiber);
    expect(fibers.root() == saved_root);

    harness.vm().fiber = fiber;
    harness.vm().root_fiber = null;
    expect(fibers.current() == fiber);
    expect(fibers.root() == null);

    harness.vm().fiber = saved_fiber;
    harness.vm().root_fiber = saved_root;
}

// ------------------------------------------------------------------- main

fn body() raise.Raising(void) {
    test_env = harness.coreEnv();
    gc_alloc.gcroot(wrap.fromTable(test_env));

    const add = compileFunction("(fn [a b] (+ a b))");
    const other = compileFunction("(fn [x y] (let [p (* x y) q (+ x y) r (- x y)] [p q r p q r]))");
    const rest = compileFunction("(fn [a & r] r)");
    const keyed = compileFunction("(fn [a &keys kw] kw)");
    const capturing = compileFunction("(fn [a b] (def unused (+ a b)) (fn [] a))");
    // The tail-call cases need two functions of the same arity and different
    // slot counts, so that a wrong slot count shows up as a wrong stack top.
    expect(other.def.?.slotcount != add.def.?.slotcount);

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
    detachingARejectedEnvironmentIsANoOp(add);
    detachHonoursTheClosureBitset(capturing);
    statusAndResumability(add);
    theCurrentAndRootFiber(add);
}

pub fn run() void {
    setcapacityChargesTheBudget();
    theBudgetIsPerThread() catch @panic("fiber_core: could not spawn a thread");

    harness.init();
    body() catch @panic("fiber_core: a fiber operation raised unexpectedly");
    vm_lifecycle.deinit();

    std.debug.print("fiber core contract ok\n", .{});
}
