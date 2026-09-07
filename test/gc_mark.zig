//! Behavioral contract for the collector's mark phase: the traversal, the
//! recursion guard, and `gc/mark.zig`'s `collect`.
//!
//! Marking has no return value and frees nothing, so almost everything here is
//! observed the same way: clear `JANET_MEM_REACHABLE` on the objects under
//! test, mark one value, and ask which headers came back set. The bit is the
//! result, so this file reads block headers directly.
//!
//! Two observations cannot be made that way and use a weak table instead. A
//! collection ends by clearing every `REACHABLE` bit it set, so "was this
//! marked *during* the collection?" is gone by the time the call returns. A
//! weak-valued table settles it: the sweep drops exactly the values the mark
//! phase did not reach, so an entry still there afterwards was marked. That
//! relies on the sweep, which makes it an observation channel rather than part
//! of what is under test.
//!
//! Nothing here exercises a raising `gcmark`. `gcmark` and `gc` are typed
//! non-raising precisely because a raise from either has nowhere to go, so
//! there is no such case to write.
//!
//! ## The head offsets are measured rather than asserted
//!
//! Asserting `@sizeOf(Head) == @offsetOf(Head, data)` is not available: a head
//! with a flexible array member loses it in translation, so `@offsetOf` does
//! not compile against one and every head in the runtime is recovered with
//! `@sizeOf`. The comparison would be `@sizeOf` against itself.
//!
//! So the question is asked of the *allocator* rather than of the type. Each
//! head is a GC block: the runtime allocates `Head + payload` in one
//! `gc.gcallocWithPayload` and gives back the address of the flexible array,
//! so the block at the front of the heap list immediately afterwards is the
//! header, and the difference between the two addresses is the offset measured
//! at run time. That catches a runtime that computed an offset one way and
//! allocated another, which is the claim worth making here.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const abstract_type = @import("subsystems").abstract_type;
const abstracts = @import("subsystems").value.abstracts;
const arrays = @import("subsystems").value.arrays;
const buffers = @import("subsystems").value.buffers;
const config = @import("config");
const constants = @import("constants");
const core_env = @import("subsystems").env;
const expect = @import("expect.zig").expect;
const functions = @import("subsystems").value.functions;
const gc_alloc = @import("subsystems").gc_alloc;
const gc_mark = @import("subsystems").gc_mark;
const harness = @import("harness.zig");
const repr = @import("repr");
const strings = @import("subsystems").value.strings;
const structs = @import("subsystems").value.structs;
const tables = @import("subsystems").value.tables;
const tuples = @import("subsystems").value.tuples;
const utils = @import("subsystems").utils;
const value = @import("subsystems").value;
const vm_entry = @import("subsystems").vm_entry;
const vm_lifecycle = @import("subsystems").lifecycle;
const vm_state = @import("subsystems").vm_state;
const wrap = @import("subsystems").value.wrap;

// ==========================================================================
// Constants
// ==========================================================================

/// The two probe types. `gcmark` and `gc` are typed non-raising, so the
/// callbacks are ordinary functions and the table is the runtime's own.
const at_marked = abstract_type.define(anyopaque, .{ .name = "gc-mark-test/marked", .gcmark = probeGcmark });
const at_plain = abstract_type.define(anyopaque, .{ .name = "gc-mark-test/plain" });

var probe_child_value: repr.Value = undefined;
var probe_gcmark_calls: i32 = 0;
var probe_root_value: repr.Value = undefined;
var probe_roots_on_mark = false;
var probe_saw_mark_phase: ?bool = null;

// ==========================================================================
// Cases
// ==========================================================================

/// The contract uses the runtime's own arithmetic to *find* a header. That is
/// circular only for the layout question, which `theHeadOffsets` settles from
/// the allocator instead.
fn headerOf(pointer: ?*anyopaque) *abi.GCObject {
    return @ptrCast(@alignCast(pointer.?));
}

fn reachable(pointer: ?*anyopaque) bool {
    return harness.gcBits(headerOf(pointer).flags) & constants.JANET_MEM_REACHABLE != 0;
}

fn unmark(pointer: ?*anyopaque) void {
    headerOf(pointer).flags = @bitCast(harness.gcBits(headerOf(pointer).flags) & ~@as(u32, constants.JANET_MEM_REACHABLE));
}

/// The head of whatever `value` refers to, or null for a value the collector
/// does not trace. Mirrors the cases `gc/sweep.zig`'s `checkLiveref`
/// distinguishes.
fn headOf(val: repr.Value) ?*anyopaque {
    return switch (repr.typeOf(val)) {
        repr.Tag.array,
        repr.Tag.table,
        repr.Tag.function,
        repr.Tag.buffer,
        repr.Tag.fiber,
        => wrap.toPointer(val),
        repr.Tag.string,
        repr.Tag.symbol,
        repr.Tag.keyword,
        => utils.stringHead(wrap.toString(val)),
        repr.Tag.abstract => utils.abstractHead(wrap.toAbstract(val)),
        repr.Tag.tuple => utils.tupleHead(wrap.toTuple(val)),
        repr.Tag.@"struct" => utils.structHead(wrap.toStruct(val)),
        else => null,
    };
}

fn unmarkValue(val: repr.Value) void {
    if (headOf(val)) |head| unmark(head);
}

fn valueReachable(val: repr.Value) bool {
    return reachable(headOf(val).?);
}

/// Start from a heap with no marks left over from an earlier case. A
/// collection ends by clearing every bit it set, so this is the cheapest way
/// to get one.
fn freshHeap() void {
    gc_mark.collect();
}

fn probeGcmark(_: *anyopaque, _: usize) void {
    probe_gcmark_calls += 1;
    probe_saw_mark_phase = harness.vm().gc.mark_phase;
    gc_mark.mark(probe_child_value);
    if (probe_roots_on_mark) gc_alloc.gcroot(probe_root_value);
}

/// The block the allocator most recently prepended to the main heap.
fn newestBlock() usize {
    return @intFromPtr(harness.vm().gc.blocks);
}

/// Whether a block is still on the main heap list. Only ever called for a
/// block still alive, so nothing freed is dereferenced.
fn onBlockList(block: ?*anyopaque) bool {
    var current = harness.vm().gc.blocks;
    while (current) |header| {
        if (@as(?*anyopaque, @ptrCast(header)) == block) return true;
        current = header.data.next;
    }
    return false;
}

/// The runtime's payload offsets against its own allocator.
///
/// Each case allocates one value of the kind under test and compares the
/// pointer the runtime handed back against the block it just allocated.
///
/// `@sizeOf` here is the oracle and has to stay `@sizeOf`, for the reason
/// `test/utils.zig` gives at `payloadOffset`: the allocator uses
/// `types.<kind>_payload`, and this compares what it did against the other
/// spelling of the same number.
fn theHeadOffsets() void {
    freshHeap();

    const string = strings.new("head-offset-probe");
    expect(@intFromPtr(string) - newestBlock() == @sizeOf(strings.StringHead));

    const tuple = tuples.begin(1);
    expect(@intFromPtr(tuple) - newestBlock() == @sizeOf(tuples.TupleHead));
    tuple[0] = wrap.fromNil();
    _ = tuples.end(tuple);

    const structure = structs.begin(1);
    expect(@intFromPtr(structure) - newestBlock() == @sizeOf(structs.StructHead));
    structs.put(structure, value.fromBytes("k", .keyword), wrap.fromNil());
    _ = structs.end(structure);

    const abstract = abstracts.newBytes(&at_plain, 8);
    expect(@intFromPtr(abstract) - newestBlock() == @sizeOf(abi.AbstractHead));

    // `functions.Function`'s environments are its own flexible array and the
    // function is its own block, so the oracle is what lives at the computed
    // slot rather than a difference of addresses. A closure with a captured
    // binding puts a real `functions.FuncEnv` there; if the offset were wrong
    // the slot would be padding, and a padding word is not a live block of
    // the funcenv memory type.
    var out: repr.Value = undefined;
    expect(core_env.dostring(
        harness.coreEnv(),
        "(let [x 1] (fn [] x))",
        "gc-mark-test",
        &out,
    ) == 0);
    const function = wrap.toFunction(out);
    gc_alloc.gcroot(out);
    expect(function.def.?.environments_length > 0);

    const slot: **functions.FuncEnv = @ptrFromInt(@intFromPtr(function) + @sizeOf(functions.Function));
    const environment = slot.*;
    expect(@intFromPtr(environment) != 0);
    expect(gc_alloc.memoryTypeOf(headerOf(environment)) == .funcenv);
    expect(onBlockList(environment));

    _ = gc_alloc.gcunroot(out);
}

/// The types the collector does not trace must be accepted and ignored, and
/// must not disturb the guard: the string marked afterwards proves `depth`
/// came back to where it started.
fn immediatesAreIgnored() void {
    const roots = harness.vm().roots.items.len;
    var local: usize = 0;

    gc_mark.mark(wrap.fromNil());
    gc_mark.mark(wrap.fromTrue());
    gc_mark.mark(wrap.fromNumber(3.5));
    gc_mark.mark(harness.wrapInteger(-7));
    gc_mark.mark(wrap.fromPointer(&local));

    expect(harness.vm().roots.items.len == roots);

    const string = value.fromBytes("after-immediates", .string);
    unmarkValue(string);
    gc_mark.mark(string);
    expect(valueReachable(string));
}

fn theThreeStringKinds() void {
    const string = value.fromBytes("a string", .string);
    const keyword = value.fromBytes("a-keyword", .keyword);
    const symbol = value.fromBytes("a-symbol", .symbol);

    unmarkValue(string);
    unmarkValue(keyword);
    unmarkValue(symbol);

    gc_mark.mark(string);
    gc_mark.mark(keyword);
    gc_mark.mark(symbol);

    expect(valueReachable(string));
    expect(valueReachable(keyword));
    expect(valueReachable(symbol));
}

fn aBuffer() void {
    const buffer = buffers.new(8);
    _ = buffers.pushCstringAbi(buffer, "contents");
    unmark(buffer);
    gc_mark.mark(wrap.fromBuffer(buffer));
    expect(reachable(buffer));
}

fn anArrayMarksItsElements() void {
    const array = arrays.new(2);
    const string = value.fromBytes("in an array", .string);
    harness.arrayPush(array, string);

    unmark(array);
    unmarkValue(string);
    gc_mark.mark(wrap.fromArray(array));

    expect(reachable(array));
    expect(valueReachable(string));
}

/// A weak array is marked but not traversed. The type test in the array walk
/// is the only thing that distinguishes the two kinds during marking, and it
/// is easy to mistake for a redundant check.
fn aWeakArrayDoesNotMarkItsElements() void {
    const array = arrays.weak(2);
    const string = value.fromBytes("in a weak array", .string);
    harness.arrayPush(array, string);

    unmark(array);
    unmarkValue(string);
    gc_mark.mark(wrap.fromArray(array));

    expect(reachable(array));
    expect(!valueReachable(string));
}

/// Which half of an entry the mark phase follows is what makes a table weak.
/// All four kinds are checked together because the difference between them is
/// the contract: a weak-keyed table keeps its values alive, a weak-valued
/// table keeps its keys, and one weak in both keeps neither.
fn theFourTableKinds() void {
    const Case = struct {
        make: *const fn (usize) *tables.Table,
        keeps_key: bool,
        keeps_value: bool,
    };
    const cases = [_]Case{
        .{ .make = tables.new, .keeps_key = true, .keeps_value = true },
        .{ .make = tables.weakk, .keeps_key = false, .keeps_value = true },
        .{ .make = tables.weakv, .keeps_key = true, .keeps_value = false },
        .{ .make = tables.weakkv, .keeps_key = false, .keeps_value = false },
    };

    for (cases) |case| {
        const table = case.make(4);
        const key = value.fromBytes("the key", .string);
        const val = value.fromBytes("the value", .string);
        tables.put(table, key, val);

        unmark(table);
        unmarkValue(key);
        unmarkValue(val);
        gc_mark.mark(wrap.fromTable(table));

        expect(reachable(table));
        expect(valueReachable(key) == case.keeps_key);
        expect(valueReachable(val) == case.keeps_value);
    }
}

/// The prototype chain is followed iteratively, and the reachability test is
/// what terminates a cycle. Both halves are checked here: a three-link chain
/// is marked to its end, and a two-table cycle returns rather than spinning.
fn thePrototypeChain() void {
    const a = tables.new(1);
    const b = tables.new(1);
    const d = tables.new(1);
    a.proto = b;
    b.proto = d;

    const deep = value.fromBytes("in the last proto", .string);
    tables.put(d, value.fromBytes("k", .keyword), deep);

    unmark(a);
    unmark(b);
    unmark(d);
    unmarkValue(deep);
    gc_mark.mark(wrap.fromTable(a));

    expect(reachable(a) and reachable(b) and reachable(d));
    expect(valueReachable(deep));

    const x = tables.new(1);
    const y = tables.new(1);
    x.proto = y;
    y.proto = x;
    unmark(x);
    unmark(y);
    gc_mark.mark(wrap.fromTable(x));
    expect(reachable(x) and reachable(y));
}

fn aStructMarksItsProtoAndEntries() void {
    const proto_builder = structs.begin(1);
    const proto_value = value.fromBytes("in the struct proto", .string);
    structs.put(proto_builder, value.fromBytes("p", .keyword), proto_value);
    const proto = structs.end(proto_builder);

    const builder = structs.begin(1);
    const key = value.fromBytes("struct key", .string);
    const val = value.fromBytes("struct value", .string);
    structs.put(builder, key, val);
    const structure = structs.end(builder);
    utils.structHead(structure).proto = proto;

    unmark(utils.structHead(structure));
    unmark(utils.structHead(proto));
    unmarkValue(key);
    unmarkValue(val);
    unmarkValue(proto_value);

    gc_mark.mark(wrap.fromStruct(structure));

    expect(reachable(utils.structHead(structure)));
    expect(reachable(utils.structHead(proto)));
    expect(valueReachable(key));
    expect(valueReachable(val));
    expect(valueReachable(proto_value));
}

fn aTupleMarksItsElements() void {
    var items = [2]repr.Value{
        value.fromBytes("tuple element one", .string),
        value.fromBytes("tuple element two", .string),
    };
    const tuple = tuples.newFrom(&items);

    unmark(utils.tupleHead(tuple));
    unmarkValue(items[0]);
    unmarkValue(items[1]);

    gc_mark.mark(wrap.fromTuple(tuple));

    expect(reachable(utils.tupleHead(tuple)));
    expect(valueReachable(items[0]));
    expect(valueReachable(items[1]));
}

/// The callback runs once per collection, not once per reference: the
/// reachability test in front of it is what stops a shared abstract from being
/// walked again by every holder.
fn anAbstractMarksThroughItsCallbackOnce() void {
    const abstract = abstracts.newBytes(&at_marked, 8);
    probe_child_value = value.fromBytes("reached by gcmark", .string);
    probe_gcmark_calls = 0;

    unmark(utils.abstractHead(abstract));
    unmarkValue(probe_child_value);

    gc_mark.mark(wrap.fromAbstract(abstract));
    expect(reachable(utils.abstractHead(abstract)));
    expect(probe_gcmark_calls == 1);
    expect(valueReachable(probe_child_value));

    gc_mark.mark(wrap.fromAbstract(abstract));
    expect(probe_gcmark_calls == 1);
}

fn anAbstractWithoutAGcmark() void {
    const abstract = abstracts.newBytes(&at_plain, 8);
    unmark(utils.abstractHead(abstract));
    gc_mark.mark(wrap.fromAbstract(abstract));
    expect(reachable(utils.abstractHead(abstract)));
}

/// `func->envs[i]`, which `@cImport` cannot spell: `envs` is a flexible array
/// member. `theHeadOffsets` is what makes this arithmetic safe to write.
fn funcEnv(function: *functions.Function, index: usize) *functions.FuncEnv {
    const base = @intFromPtr(function) + @sizeOf(functions.Function);
    const slot: **functions.FuncEnv = @ptrFromInt(base + index * @sizeOf(*functions.FuncEnv));
    return slot.*;
}

/// Every value a closure can still reach has to be marked through it: the
/// definition, the definition's source name, and the captured environment. The
/// environment is the interesting one: the mark detaches it from its dead
/// fiber first, so what is marked is the copied-out values rather than the
/// fiber.
fn aClosureMarksItsCapturedEnvironment() void {
    var out: repr.Value = undefined;
    expect(core_env.dostring(
        harness.coreEnv(),
        "(let [x \"captured-by-closure\"] (fn [] x))",
        "gc-mark-test",
        &out,
    ) == 0);
    expect(harness.isType(out, repr.Tag.function));
    gc_alloc.gcroot(out);

    const function = wrap.toFunction(out);
    expect(function.def != null);
    expect(function.def.?.environments_length > 0);

    unmark(function);
    unmark(function.def);
    if (function.def.?.source) |source| unmark(utils.stringHead(source));
    var index: usize = 0;
    while (index < function.def.?.environments_length) : (index += 1) {
        unmark(funcEnv(function, index));
    }

    gc_mark.mark(out);

    expect(reachable(function));
    expect(reachable(function.def));
    if (function.def.?.source) |source| {
        expect(reachable(utils.stringHead(source)));
    }

    // The environment is detached by the mark, so its values are off the stack
    // and every one of them must have been marked in place.
    const environment = funcEnv(function, 0);
    expect(reachable(environment));
    expect(environment.offset == 0);
    var found: i32 = 0;
    var slot: i32 = 0;
    while (slot < environment.length) : (slot += 1) {
        const head = headOf(environment.as.values.?[@intCast(slot)]) orelse continue;
        expect(reachable(head));
        found += 1;
    }
    expect(found > 0);

    _ = gc_alloc.gcunroot(out);
}

/// A suspended fiber keeps its frames, and a frame may be the only reference
/// to the function it names. The fiber below is stopped inside a call,
/// so `frame->func` is set and the frame walk is what reaches it.
fn aSuspendedFiberMarksItsFrames() void {
    var out: repr.Value = undefined;
    expect(core_env.dostring(
        harness.coreEnv(),
        "(fiber/new (fn [] (yield \"suspended\") nil))",
        "gc-mark-test",
        &out,
    ) == 0);
    expect(harness.isType(out, repr.Tag.fiber));
    gc_alloc.gcroot(out);

    const fiber = wrap.toFiber(out);
    _ = vm_entry.continueFiber(fiber, wrap.fromNil());
    expect(fiber.frame > 0);

    const frame: *vm_state.StackFrame = @ptrCast(@alignCast(
        fiber.data.? + @as(usize, @intCast(fiber.frame - constants.JANET_FRAME_SIZE)),
    ));
    expect(frame.func != null);

    const dyns = tables.new(1);
    fiber.env = dyns;
    const last = value.fromBytes("the last value", .string);
    fiber.last_value = last;

    unmark(fiber);
    unmark(frame.func);
    unmark(dyns);
    unmarkValue(last);

    gc_mark.mark(out);

    expect(reachable(fiber));
    expect(reachable(frame.func));
    expect(reachable(dyns));
    expect(valueReachable(last));

    _ = gc_alloc.gcunroot(out);
}

/// The child chain is followed iteratively, and a fiber already marked ends
/// it. Built by hand because reaching this state from Janet source needs a
/// fiber suspended inside another one.
fn theFiberChildChain() void {
    var parent_value: repr.Value = undefined;
    var child_value: repr.Value = undefined;
    const env = harness.coreEnv();
    expect(core_env.dostring(env, "(fiber/new (fn [] nil))", "gc-mark-test", &parent_value) == 0);
    expect(core_env.dostring(env, "(fiber/new (fn [] nil))", "gc-mark-test", &child_value) == 0);
    gc_alloc.gcroot(parent_value);
    gc_alloc.gcroot(child_value);

    const parent = wrap.toFiber(parent_value);
    const child = wrap.toFiber(child_value);
    const saved = parent.child;
    parent.child = child;

    const held = value.fromBytes("held by the child fiber", .string);
    child.last_value = held;

    unmark(parent);
    unmark(child);
    unmarkValue(held);

    gc_mark.mark(parent_value);

    expect(reachable(parent));
    expect(reachable(child));
    expect(valueReachable(held));

    parent.child = saved;
    _ = gc_alloc.gcunroot(child_value);
    _ = gc_alloc.gcunroot(parent_value);
}

/// Build a chain of single-element arrays, each pointing at the next.
/// Collection is suspended for the duration: nothing roots the chain until it
/// is finished, and it is long enough that building it would otherwise trigger
/// one.
fn buildChain(chain: []*arrays.Array) void {
    const handle = gc_alloc.gclock();
    chain[0] = arrays.new(1);
    for (1..chain.len) |index| {
        chain[index] = arrays.new(1);
        harness.arrayPush(chain[index - 1], wrap.fromArray(chain[index]));
    }
    gc_alloc.gcunlock(handle);
}

/// The guard is exact, and where it stops is the contract. Marking a chain one
/// link longer than `config.recursion_guard` marks every link up to the limit
/// and *roots* the one after it. Rooting rather than recursing is what keeps
/// the traversal off the native stack, and rooting rather than dropping is
/// what keeps the rest of the graph from being collected.
fn theGuardRootsTheOverflow() !void {
    const n: usize = config.recursion_guard + 2;
    const chain = try std.heap.c_allocator.alloc(*arrays.Array, n);
    defer std.heap.c_allocator.free(chain);
    buildChain(chain);

    const head = wrap.fromArray(chain[0]);
    gc_alloc.gcroot(head);

    for (chain) |link| unmark(link);
    const roots = harness.vm().roots.items.len;

    gc_mark.mark(head);

    expect(harness.vm().roots.items.len == roots + 1);
    expect(wrap.toPointer(harness.vm().roots.items[roots]) ==
        @as(?*anyopaque, chain[config.recursion_guard]));
    expect(reachable(chain[config.recursion_guard - 1]));
    expect(!reachable(chain[config.recursion_guard]));
    expect(!reachable(chain[config.recursion_guard + 1]));

    // Drop the root the guard added, then the chain itself.
    harness.vm().roots.items.len = roots;
    _ = gc_alloc.gcunroot(head);
}

/// What the guard defers, the drain loop in `collect` finishes. The chain
/// below is three times the guard's depth and the only reference to its last
/// link is through every link before it, so if the drain loop stopped early or
/// dropped what it popped, the weak table would lose the entry in the sweep.
fn aCollectionFinishesDeepGraphs() !void {
    const n: usize = 3 * config.recursion_guard;
    const chain = try std.heap.c_allocator.alloc(*arrays.Array, n);
    defer std.heap.c_allocator.free(chain);
    buildChain(chain);

    const head = wrap.fromArray(chain[0]);
    gc_alloc.gcroot(head);

    const witness = tables.weakv(2);
    const witness_value = wrap.fromTable(witness);
    gc_alloc.gcroot(witness_value);
    const key = value.fromBytes("tail", .keyword);
    const tail = wrap.fromArray(chain[n - 1]);
    tables.put(witness, key, tail);

    const roots = harness.vm().roots.items.len;
    gc_mark.collect();

    expect(harness.vm().roots.items.len == roots);
    expect(harness.equals(tables.get(witness, key), tail));

    _ = gc_alloc.gcunroot(witness_value);
    _ = gc_alloc.gcunroot(head);
}

/// A root added while the collection is running is consumed by it: marked, and
/// removed. Only the roots that predate the collection survive it.
fn aCollectionDrainsRootsAddedDuringMarking() void {
    freshHeap();

    const abstract = abstracts.newBytes(&at_marked, 8);
    const abstract_value = wrap.fromAbstract(abstract);
    gc_alloc.gcroot(abstract_value);

    probe_child_value = value.fromBytes("marked by gcmark", .string);
    probe_root_value = value.fromBytes("rooted by gcmark", .string);
    probe_roots_on_mark = true;
    probe_gcmark_calls = 0;
    probe_saw_mark_phase = null;

    const witness = tables.weakv(2);
    const witness_value = wrap.fromTable(witness);
    gc_alloc.gcroot(witness_value);
    const key = value.fromBytes("rooted", .keyword);
    tables.put(witness, key, probe_root_value);

    const roots = harness.vm().roots.items.len;
    gc_mark.collect();

    expect(probe_gcmark_calls == 1);
    expect(harness.vm().roots.items.len == roots);
    expect(harness.equals(tables.get(witness, key), probe_root_value));

    probe_roots_on_mark = false;
    _ = gc_alloc.gcunroot(witness_value);
    _ = gc_alloc.gcunroot(abstract_value);
}

/// The flag is set for the duration of the traversal and clear once it is
/// over. A `gcmark` callback is the only thing that can see it set.
fn theMarkPhaseFlag() void {
    const abstract = abstracts.newBytes(&at_marked, 8);
    const abstract_value = wrap.fromAbstract(abstract);
    gc_alloc.gcroot(abstract_value);
    probe_child_value = wrap.fromNil();
    probe_saw_mark_phase = null;

    expect(harness.vm().gc.mark_phase == false);
    gc_mark.collect();
    expect(probe_saw_mark_phase == true);
    expect(harness.vm().gc.mark_phase == false);

    _ = gc_alloc.gcunroot(abstract_value);
}

/// A locked collector does nothing at all, not even the bookkeeping at the end
/// of a collection, which is how the early return is told apart from a
/// collection that found nothing to do.
fn aLockedCollectorDoesNothing() void {
    freshHeap();

    const handle = gc_alloc.gclock();
    harness.vm().gc.next_collection = 4242;
    const blocks = harness.vm().gc.block_count;

    gc_mark.collect();

    expect(harness.vm().gc.next_collection == 4242);
    expect(harness.vm().gc.block_count == blocks);

    gc_alloc.gcunlock(handle);
    gc_mark.collect();
    expect(harness.vm().gc.next_collection == 0);
}

/// The interval heuristic keeps a large heap from being collected on every
/// allocation. It runs before the sweep, so it is sized by the block count
/// going in, and it only ever raises the interval.
fn theIntervalHeuristic() void {
    const saved = harness.vm().gc.interval;

    harness.vm().gc.interval = 0;
    const blocks = harness.vm().gc.block_count;
    gc_mark.collect();
    expect(harness.vm().gc.interval == blocks * @sizeOf(abi.GCObject));

    const high = std.math.maxInt(usize) / 2;
    harness.vm().gc.interval = high;
    gc_mark.collect();
    expect(harness.vm().gc.interval == high);

    harness.vm().gc.interval = saved;
}

// ==========================================================================
// Entry
// ==========================================================================

fn body() !void {
    theHeadOffsets();

    immediatesAreIgnored();
    theThreeStringKinds();
    aBuffer();

    anArrayMarksItsElements();
    aWeakArrayDoesNotMarkItsElements();

    theFourTableKinds();
    thePrototypeChain();

    aStructMarksItsProtoAndEntries();
    aTupleMarksItsElements();

    anAbstractMarksThroughItsCallbackOnce();
    anAbstractWithoutAGcmark();

    aClosureMarksItsCapturedEnvironment();
    aSuspendedFiberMarksItsFrames();
    theFiberChildChain();

    try theGuardRootsTheOverflow();
    try aCollectionFinishesDeepGraphs();

    aCollectionDrainsRootsAddedDuringMarking();
    theMarkPhaseFlag();
    aLockedCollectorDoesNothing();
    theIntervalHeuristic();
}

pub fn run() void {
    harness.init();
    body() catch @panic("gc_mark: out of memory building a chain");
    vm_lifecycle.deinit();
}
