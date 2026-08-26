//! Behavioral contract for the collector's mark phase: the traversal, the
//! recursion guard, and `janet_collect`.
//!
//! Marking has no return value and frees nothing, so almost everything here is
//! observed the same way: clear `JANET_MEM_REACHABLE` on the objects under
//! test, mark one value, and ask which headers came back set. The bit is the
//! result, which is why this file reads block headers directly.
//!
//! Two observations cannot be made that way and use a weak table instead. A
//! collection ends by clearing every `REACHABLE` bit it set, so "was this
//! marked *during* the collection?" is gone by the time the call returns. A
//! weak-valued table answers it: the sweep drops exactly the values the mark
//! phase did not reach, so an entry still there afterwards was marked. That
//! relies on the sweep, which makes it an observation channel rather than part
//! of what is under test.
//!
//! Nothing here exercises a raising `gcmark`. Phase 10's hinge typed `gcmark`
//! and `gc` non-raising precisely because a raise from either has nowhere to
//! go, so the case cannot be written any more — which is the point of typing
//! them that way, and an improvement on `SPIKE-8.md` describing what the C
//! runtime did when one raised anyway.
//!
//! ## The oracle this migration could not keep, and where it went instead
//!
//! `test/gc_mark.c` opened with five assertions of the form
//! `sizeof(Head) == offsetof(Head, data)`, and `gc_mark.zig`'s own comment
//! named that file as the place the assumption is checked. The assumption is
//! load-bearing: `@cImport` **drops flexible array members**, so
//! `@offsetOf(JanetStringHead, "data")` does not compile and every head in the
//! runtime is recovered with `@sizeOf` instead. The two agree only where the
//! flexible array needs no padding after the last declared field.
//!
//! Translating those five lines here would have compared `@sizeOf(X)` with
//! `@sizeOf(X)`: compiled, passed, proved nothing. That is Part 3's rule — *a
//! translation that would make a contract circular must find a different
//! oracle or drop the assertion* — and the different oracle turned out not to
//! belong in this file at all.
//!
//! **The five assertions are in `test/abi.c` now**, unchanged, because the
//! thing they compare is C's `offsetof` against C's `sizeof` and `abi.c` is
//! the file whose whole job is C's view of `janet.h`'s layout. They are static
//! assertions there and cost nothing to run. If `abi.c` is ever deleted rather
//! than rewritten — `phase_11.md` has that open question — they have to go
//! somewhere else that is still C.
//!
//! ## What `theHeadOffsets` below checks instead
//!
//! A *different* property, and the one this file is in a position to see: that
//! the runtime's own `@sizeOf` arithmetic agrees with what its allocator
//! actually did. Each head is a GC block — the runtime allocates
//! `Head + payload` in one `janet_gcalloc` and hands back the address of the
//! flexible array — so the block at the front of `janet_vm.blocks` immediately
//! afterwards *is* the header, and the difference between the two addresses is
//! the offset measured at run time.
//!
//! Keeping both is deliberate. `abi.c` would catch a `janet.h` edit that
//! padded a header; this catches a runtime that computed an offset one way and
//! allocated another. Neither implies the other, and until Part 8 the tree had
//! only the first.

const std = @import("std");
const config = @import("config");
const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");
const value = @import("subsystems").value;
const harness = @import("harness.zig");
const abstract_type = @import("subsystems").abstract_type;
const structs = @import("subsystems").value.structs;
const tables = @import("subsystems").value.tables;
const gc_alloc = @import("subsystems").gc_alloc;
const arrays = @import("subsystems").value.arrays;
const buffers = @import("subsystems").value.buffers;
const strings = @import("subsystems").value.strings;
const tuples = @import("subsystems").value.tuples;
const utils = @import("subsystems").utils;
const gc_mark = @import("subsystems").gc_mark;
const core_env = @import("subsystems").env;
const kind = @import("subsystems").value.kind;
const wrap = @import("subsystems").value.wrap;
const vm_lifecycle = @import("subsystems").lifecycle;
const abstracts = @import("subsystems").value.abstracts;
const vm_entry = @import("subsystems").vm_entry;
const AbstractType = abstract_type.AbstractType;

/// `janet.h` declares all four head accessors as real functions as well as
/// macros, and the runtime exports them — so the contract uses the runtime's
/// own arithmetic to *find* a header. That is circular only for the layout
/// question, which `theHeadOffsets` answers from the allocator instead.
fn headerOf(pointer: ?*anyopaque) *types.JanetGCObject {
    return @ptrCast(@alignCast(pointer.?));
}

fn reachable(pointer: ?*anyopaque) bool {
    return headerOf(pointer).flags & constants.JANET_MEM_REACHABLE != 0;
}

fn unmark(pointer: ?*anyopaque) void {
    headerOf(pointer).flags &= ~@as(i32, constants.JANET_MEM_REACHABLE);
}

/// The head of whatever `value` refers to, or null for a value the collector
/// does not trace. Mirrors the cases `janet_check_liveref` distinguishes.
fn headOf(val: types.Janet) ?*anyopaque {
    return switch (kind.typeOf(val)) {
        constants.JANET_ARRAY,
        constants.JANET_TABLE,
        constants.JANET_FUNCTION,
        constants.JANET_BUFFER,
        constants.JANET_FIBER,
        => wrap.toPointer(val),
        constants.JANET_STRING,
        constants.JANET_SYMBOL,
        constants.JANET_KEYWORD,
        => utils.stringHead(wrap.toString(val)),
        constants.JANET_ABSTRACT => utils.abstractHead(wrap.toAbstract(val)),
        constants.JANET_TUPLE => utils.tupleHead(wrap.toTuple(val)),
        constants.JANET_STRUCT => utils.structHead(wrap.toStruct(val)),
        else => null,
    };
}

fn unmarkValue(val: types.Janet) void {
    if (headOf(val)) |head| unmark(head);
}

fn valueReachable(val: types.Janet) bool {
    return reachable(headOf(val).?);
}

/// Start from a heap with no marks left over from an earlier case. A
/// collection ends by clearing every bit it set, so this is the cheapest way
/// to get one.
fn freshHeap() void {
    gc_mark.collect();
}

/// The block `janet_gcalloc` most recently prepended to the main heap.
fn newestBlock() usize {
    return @intFromPtr(c.vm().blocks);
}

/// The runtime's payload offsets against its own allocator.
///
/// Each case allocates one value of the kind under test and compares the
/// pointer the runtime handed back against the block it just allocated. The
/// C spelling of this question lives in `test/abi.c`; this is the half that
/// needs a running heap, and the two are independent.
///
/// **`@sizeOf` here is the oracle and must stay `@sizeOf`**, for the reason
/// `test/utils.zig` gives at `payloadOffset`: the allocator uses
/// `types.<kind>_payload` since increment 5e, and this compares what it did
/// against the other spelling of the same number.
fn theHeadOffsets() void {
    freshHeap();

    const string = strings.new("head-offset-probe");
    std.debug.assert(@intFromPtr(string) - newestBlock() == @sizeOf(types.JanetStringHead));

    const tuple = tuples.begin(1);
    std.debug.assert(@intFromPtr(tuple) - newestBlock() == @sizeOf(types.JanetTupleHead));
    tuple[0] = wrap.fromNil();
    _ = tuples.end(tuple);

    const structure = structs.begin(1);
    std.debug.assert(@intFromPtr(structure) - newestBlock() == @sizeOf(types.JanetStructHead));
    structs.put(structure, value.fromBytes("k", .keyword), wrap.fromNil());
    _ = structs.end(structure);

    const abstract = abstracts.new(abstract_type.stored(&at_plain), 8);
    std.debug.assert(@intFromPtr(abstract) - newestBlock() == @sizeOf(types.JanetAbstractHead));

    // `JanetFunction`'s environments are its own flexible array, and the
    // function *is* its block — so the oracle is what lives at the computed
    // slot rather than a difference of addresses. A closure with a captured
    // binding puts a real `JanetFuncEnv` there; if the offset were wrong the
    // slot would hold padding, and a padding word is not a live block of type
    // `JANET_MEMORY_FUNCENV`.
    var out: types.Janet = undefined;
    std.debug.assert(core_env.dostring(
        harness.coreEnv(),
        "(let [x 1] (fn [] x))",
        "gc-mark-test",
        &out,
    ) == 0);
    const function = wrap.toFunction(out);
    gc_alloc.gcroot(out);
    std.debug.assert(function.*.def.?.environments_length > 0);

    const slot: **types.JanetFuncEnv = @ptrFromInt(@intFromPtr(function) + @sizeOf(types.JanetFunction));
    const environment = slot.*;
    std.debug.assert(@intFromPtr(environment) != 0);
    std.debug.assert(headerOf(environment).flags & constants.JANET_MEM_TYPEBITS == constants.JANET_MEMORY_FUNCENV);
    std.debug.assert(onBlockList(environment));

    _ = gc_alloc.gcunroot(out);
}

/// Whether a block is still on the main heap list. Only ever called for a
/// block known to be live, so nothing freed is dereferenced.
fn onBlockList(block: ?*anyopaque) bool {
    var current = c.vm().blocks;
    while (current != null) {
        if (current == block) return true;
        current = @ptrCast(headerOf(current).data.next);
    }
    return false;
}

// ------------------------------------------------------------- probe types

var probe_gcmark_calls: i32 = 0;
var probe_saw_mark_phase: i32 = -1;
var probe_roots_on_mark = false;
var probe_root_value: types.Janet = undefined;
var probe_child_value: types.Janet = undefined;

fn probeGcmark(_: ?*anyopaque, _: usize) callconv(.c) c_int {
    probe_gcmark_calls += 1;
    probe_saw_mark_phase = c.vm().gc_mark_phase;
    gc_mark.mark(probe_child_value);
    if (probe_roots_on_mark) gc_alloc.gcroot(probe_root_value);
    return 0;
}

/// Declared with the runtime's own `AbstractType` rather than `janet.h`'s.
///
/// The C contracts reach `janet_contract_abstract_type` — `support.zig`'s
/// adapter pool — because since the hinge a `JanetAbstractType`'s callbacks
/// are Zig-ABI and C can define neither. Here there is nothing to adapt: the
/// two callbacks this file needs are `gcmark` and `gc`, which the hinge typed
/// **non**-raising, so they are ordinary `callconv(.c)` functions and the
/// table is the runtime's own.
const at_marked: AbstractType = .{ .name = "gc-mark-test/marked", .gcmark = probeGcmark };
const at_plain: AbstractType = .{ .name = "gc-mark-test/plain" };

// ------------------------------------------------------------ leaf marking

/// The types the collector does not trace must be accepted and ignored, and
/// must not disturb the guard: the string marked afterwards proves `depth`
/// came back to where it started.
fn immediatesAreIgnored() void {
    const roots = c.vm().root_count;
    var local: usize = 0;

    gc_mark.mark(wrap.fromNil());
    gc_mark.mark(wrap.fromTrue());
    gc_mark.mark(wrap.fromNumber(3.5));
    gc_mark.mark(harness.wrapInteger(-7));
    gc_mark.mark(wrap.fromPointer(&local));

    std.debug.assert(c.vm().root_count == roots);

    const string = value.fromBytes("after-immediates", .string);
    unmarkValue(string);
    gc_mark.mark(string);
    std.debug.assert(valueReachable(string));
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

    std.debug.assert(valueReachable(string));
    std.debug.assert(valueReachable(keyword));
    std.debug.assert(valueReachable(symbol));
}

fn aBuffer() void {
    const buffer = buffers.new(8);
    _ = buffers.pushCstringAbi(buffer, "contents");
    unmark(buffer);
    gc_mark.mark(wrap.fromBuffer(buffer));
    std.debug.assert(reachable(buffer));
}

// ----------------------------------------------------------------- arrays

fn anArrayMarksItsElements() void {
    const array = arrays.new(2);
    const string = value.fromBytes("in an array", .string);
    harness.arrayPush(array, string);

    unmark(array);
    unmarkValue(string);
    gc_mark.mark(wrap.fromArray(array));

    std.debug.assert(reachable(array));
    std.debug.assert(valueReachable(string));
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

    std.debug.assert(reachable(array));
    std.debug.assert(!valueReachable(string));
}

// ----------------------------------------------------------------- tables

/// Which half of an entry the mark phase follows is what makes a table weak.
/// All four kinds are checked together because the difference between them is
/// the contract: a weak-keyed table keeps its values alive, a weak-valued
/// table keeps its keys, and one weak in both keeps neither — the last being
/// the case with no branch of its own in the C original.
fn theFourTableKinds() void {
    const Case = struct {
        make: *const fn (i32) *types.JanetTable,
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

        std.debug.assert(reachable(table));
        std.debug.assert(valueReachable(key) == case.keeps_key);
        std.debug.assert(valueReachable(val) == case.keeps_value);
    }
}

/// The prototype chain is followed iteratively, and the reachability test is
/// what terminates a cycle. Both halves are checked here: a three-link chain
/// is marked to its end, and a two-table cycle returns rather than spinning.
fn thePrototypeChain() void {
    const a = tables.new(1);
    const b = tables.new(1);
    const d = tables.new(1);
    a.*.proto = b;
    b.*.proto = d;

    const deep = value.fromBytes("in the last proto", .string);
    tables.put(d, value.fromBytes("k", .keyword), deep);

    unmark(a);
    unmark(b);
    unmark(d);
    unmarkValue(deep);
    gc_mark.mark(wrap.fromTable(a));

    std.debug.assert(reachable(a) and reachable(b) and reachable(d));
    std.debug.assert(valueReachable(deep));

    const x = tables.new(1);
    const y = tables.new(1);
    x.*.proto = y;
    y.*.proto = x;
    unmark(x);
    unmark(y);
    gc_mark.mark(wrap.fromTable(x));
    std.debug.assert(reachable(x) and reachable(y));
}

// -------------------------------------------------------- structs, tuples

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
    utils.structHead(structure).*.proto = proto;

    unmark(utils.structHead(structure));
    unmark(utils.structHead(proto));
    unmarkValue(key);
    unmarkValue(val);
    unmarkValue(proto_value);

    gc_mark.mark(wrap.fromStruct(structure));

    std.debug.assert(reachable(utils.structHead(structure)));
    std.debug.assert(reachable(utils.structHead(proto)));
    std.debug.assert(valueReachable(key));
    std.debug.assert(valueReachable(val));
    std.debug.assert(valueReachable(proto_value));
}

fn aTupleMarksItsElements() void {
    var items = [2]types.Janet{
        value.fromBytes("tuple element one", .string),
        value.fromBytes("tuple element two", .string),
    };
    const tuple = tuples.newFrom(&items, 2);

    unmark(utils.tupleHead(tuple));
    unmarkValue(items[0]);
    unmarkValue(items[1]);

    gc_mark.mark(wrap.fromTuple(tuple));

    std.debug.assert(reachable(utils.tupleHead(tuple)));
    std.debug.assert(valueReachable(items[0]));
    std.debug.assert(valueReachable(items[1]));
}

// -------------------------------------------------------------- abstracts

/// The callback runs once per collection, not once per reference: the
/// reachability test in front of it is what stops a shared abstract from being
/// walked again by every holder.
fn anAbstractMarksThroughItsCallbackOnce() void {
    const abstract = abstracts.new(abstract_type.stored(&at_marked), 8);
    probe_child_value = value.fromBytes("reached by gcmark", .string);
    probe_gcmark_calls = 0;

    unmark(utils.abstractHead(abstract));
    unmarkValue(probe_child_value);

    gc_mark.mark(wrap.fromAbstract(abstract));
    std.debug.assert(reachable(utils.abstractHead(abstract)));
    std.debug.assert(probe_gcmark_calls == 1);
    std.debug.assert(valueReachable(probe_child_value));

    gc_mark.mark(wrap.fromAbstract(abstract));
    std.debug.assert(probe_gcmark_calls == 1);
}

fn anAbstractWithoutAGcmark() void {
    const abstract = abstracts.new(abstract_type.stored(&at_plain), 8);
    unmark(utils.abstractHead(abstract));
    gc_mark.mark(wrap.fromAbstract(abstract));
    std.debug.assert(reachable(utils.abstractHead(abstract)));
}

// ------------------------------------------------------ functions, fibers

/// `func->envs[i]`, which `@cImport` cannot spell: `envs` is a flexible array
/// member. `theHeadOffsets` is what makes this arithmetic safe to write.
fn funcEnv(function: *types.JanetFunction, index: usize) *types.JanetFuncEnv {
    const base = @intFromPtr(function) + @sizeOf(types.JanetFunction);
    const slot: **types.JanetFuncEnv = @ptrFromInt(base + index * @sizeOf(*types.JanetFuncEnv));
    return slot.*;
}

/// Every value a closure can still reach has to be marked through it: the
/// definition, the definition's source name, and the captured environment. The
/// environment is the interesting one — the mark detaches it from its dead
/// fiber first, so what is marked is the copied-out values rather than the
/// fiber.
fn aClosureMarksItsCapturedEnvironment() void {
    var out: types.Janet = undefined;
    std.debug.assert(core_env.dostring(
        harness.coreEnv(),
        "(let [x \"captured-by-closure\"] (fn [] x))",
        "gc-mark-test",
        &out,
    ) == 0);
    std.debug.assert(harness.isType(out, constants.JANET_FUNCTION));
    gc_alloc.gcroot(out);

    const function = wrap.toFunction(out);
    std.debug.assert(function.*.def != null);
    std.debug.assert(function.*.def.?.environments_length > 0);

    unmark(function);
    unmark(function.*.def);
    if (function.*.def.?.source) |source| unmark(utils.stringHead(source));
    var index: usize = 0;
    while (index < function.*.def.?.environments_length) : (index += 1) {
        unmark(funcEnv(function, index));
    }

    gc_mark.mark(out);

    std.debug.assert(reachable(function));
    std.debug.assert(reachable(function.*.def));
    if (function.*.def.?.source) |source| {
        std.debug.assert(reachable(utils.stringHead(source)));
    }

    // The environment is detached by the mark, so its values are off the stack
    // and every one of them must have been marked in place.
    const environment = funcEnv(function, 0);
    std.debug.assert(reachable(environment));
    std.debug.assert(environment.*.offset == 0);
    var found: i32 = 0;
    var slot: i32 = 0;
    while (slot < environment.*.length) : (slot += 1) {
        const head = headOf(environment.*.as.values.?[@intCast(slot)]) orelse continue;
        std.debug.assert(reachable(head));
        found += 1;
    }
    std.debug.assert(found > 0);

    _ = gc_alloc.gcunroot(out);
}

/// A suspended fiber holds its frames, and each frame holds a function whose
/// only reference may be that frame. The fiber below is stopped inside a call,
/// so `frame->func` is set and the frame walk is what reaches it.
fn aSuspendedFiberMarksItsFrames() void {
    var out: types.Janet = undefined;
    std.debug.assert(core_env.dostring(
        harness.coreEnv(),
        "(fiber/new (fn [] (yield \"suspended\") nil))",
        "gc-mark-test",
        &out,
    ) == 0);
    std.debug.assert(harness.isType(out, constants.JANET_FIBER));
    gc_alloc.gcroot(out);

    const fiber = wrap.toFiber(out);
    var resumed: types.Janet = undefined;
    _ = vm_entry.continueFiber(fiber, wrap.fromNil(), &resumed);
    std.debug.assert(fiber.*.frame > 0);

    const frame: *types.JanetStackFrame = @ptrCast(@alignCast(
        fiber.*.data.? + @as(usize, @intCast(fiber.*.frame - constants.JANET_FRAME_SIZE)),
    ));
    std.debug.assert(frame.func != null);

    const dyns = tables.new(1);
    fiber.*.env = dyns;
    const last = value.fromBytes("the last value", .string);
    fiber.*.last_value = last;

    unmark(fiber);
    unmark(frame.func);
    unmark(dyns);
    unmarkValue(last);

    gc_mark.mark(out);

    std.debug.assert(reachable(fiber));
    std.debug.assert(reachable(frame.func));
    std.debug.assert(reachable(dyns));
    std.debug.assert(valueReachable(last));

    _ = gc_alloc.gcunroot(out);
}

/// The child chain is followed iteratively, and a fiber already marked ends
/// it. Built by hand because reaching this state from Janet source needs a
/// fiber suspended inside another one.
fn theFiberChildChain() void {
    var parent_value: types.Janet = undefined;
    var child_value: types.Janet = undefined;
    const env = harness.coreEnv();
    std.debug.assert(core_env.dostring(env, "(fiber/new (fn [] nil))", "gc-mark-test", &parent_value) == 0);
    std.debug.assert(core_env.dostring(env, "(fiber/new (fn [] nil))", "gc-mark-test", &child_value) == 0);
    gc_alloc.gcroot(parent_value);
    gc_alloc.gcroot(child_value);

    const parent = wrap.toFiber(parent_value);
    const child = wrap.toFiber(child_value);
    const saved = parent.*.child;
    parent.*.child = child;

    const held = value.fromBytes("held by the child fiber", .string);
    child.*.last_value = held;

    unmark(parent);
    unmark(child);
    unmarkValue(held);

    gc_mark.mark(parent_value);

    std.debug.assert(reachable(parent));
    std.debug.assert(reachable(child));
    std.debug.assert(valueReachable(held));

    parent.*.child = saved;
    _ = gc_alloc.gcunroot(child_value);
    _ = gc_alloc.gcunroot(parent_value);
}

// --------------------------------------------------------- recursion guard

/// Build a chain of `n` single-element arrays, each holding the next.
/// Collection is suspended for the duration: nothing roots the chain until it
/// is finished, and it is long enough that building it would otherwise trigger
/// one.
fn buildChain(chain: []*types.JanetArray) void {
    const handle = gc_alloc.gclock();
    chain[0] = arrays.new(1);
    for (1..chain.len) |index| {
        chain[index] = arrays.new(1);
        harness.arrayPush(chain[index - 1], wrap.fromArray(chain[index]));
    }
    gc_alloc.gcunlock(handle);
}

/// The guard is exact, and where it stops is the contract. Marking a chain one
/// link longer than `JANET_RECURSION_GUARD` marks every link up to the limit
/// and *roots* the one after it — rooting rather than recursing is what keeps
/// the traversal off the C stack, and rooting rather than dropping is what
/// keeps the rest of the graph from being collected.
fn theGuardRootsTheOverflow() !void {
    const n: usize = config.recursion_guard + 2;
    const chain = try std.heap.c_allocator.alloc(*types.JanetArray, n);
    defer std.heap.c_allocator.free(chain);
    buildChain(chain);

    const head = wrap.fromArray(chain[0]);
    gc_alloc.gcroot(head);

    for (chain) |link| unmark(link);
    const roots = c.vm().root_count;

    gc_mark.mark(head);

    std.debug.assert(c.vm().root_count == roots + 1);
    std.debug.assert(wrap.toPointer(c.vm().roots.?[roots]) ==
        @as(?*anyopaque, chain[config.recursion_guard]));
    std.debug.assert(reachable(chain[config.recursion_guard - 1]));
    std.debug.assert(!reachable(chain[config.recursion_guard]));
    std.debug.assert(!reachable(chain[config.recursion_guard + 1]));

    // Drop the root the guard added, then the chain itself.
    c.vm().root_count = roots;
    _ = gc_alloc.gcunroot(head);
}

/// What the guard defers, `janet_collect` finishes. The chain below is three
/// times the guard's depth, and the only reference to its last link is through
/// every link before it; if the drain loop stopped early or dropped what it
/// popped, the weak table would lose the entry in the sweep.
fn aCollectionFinishesDeepGraphs() !void {
    const n: usize = 3 * config.recursion_guard;
    const chain = try std.heap.c_allocator.alloc(*types.JanetArray, n);
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

    const roots = c.vm().root_count;
    gc_mark.collect();

    std.debug.assert(c.vm().root_count == roots);
    std.debug.assert(harness.equals(tables.get(witness, key), tail));

    _ = gc_alloc.gcunroot(witness_value);
    _ = gc_alloc.gcunroot(head);
}

// ------------------------------------------------------------- collection

/// A root added while the collection is running is consumed by it: marked, and
/// removed. Only the roots that predate the collection survive it.
fn aCollectionDrainsRootsAddedDuringMarking() void {
    freshHeap();

    const abstract = abstracts.new(abstract_type.stored(&at_marked), 8);
    const abstract_value = wrap.fromAbstract(abstract);
    gc_alloc.gcroot(abstract_value);

    probe_child_value = value.fromBytes("marked by gcmark", .string);
    probe_root_value = value.fromBytes("rooted by gcmark", .string);
    probe_roots_on_mark = true;
    probe_gcmark_calls = 0;
    probe_saw_mark_phase = -1;

    const witness = tables.weakv(2);
    const witness_value = wrap.fromTable(witness);
    gc_alloc.gcroot(witness_value);
    const key = value.fromBytes("rooted", .keyword);
    tables.put(witness, key, probe_root_value);

    const roots = c.vm().root_count;
    gc_mark.collect();

    std.debug.assert(probe_gcmark_calls == 1);
    std.debug.assert(c.vm().root_count == roots);
    std.debug.assert(harness.equals(tables.get(witness, key), probe_root_value));

    probe_roots_on_mark = false;
    _ = gc_alloc.gcunroot(witness_value);
    _ = gc_alloc.gcunroot(abstract_value);
}

/// The flag is set for the duration of the traversal and clear once it is
/// over. A `gcmark` callback is the only thing that can see it set.
fn theMarkPhaseFlag() void {
    const abstract = abstracts.new(abstract_type.stored(&at_marked), 8);
    const abstract_value = wrap.fromAbstract(abstract);
    gc_alloc.gcroot(abstract_value);
    probe_child_value = wrap.fromNil();
    probe_saw_mark_phase = -1;

    std.debug.assert(c.vm().gc_mark_phase == 0);
    gc_mark.collect();
    std.debug.assert(probe_saw_mark_phase == 1);
    std.debug.assert(c.vm().gc_mark_phase == 0);

    _ = gc_alloc.gcunroot(abstract_value);
}

/// A locked collector does nothing at all — not even the bookkeeping at the
/// end of a collection, which is how the early return is told apart from a
/// collection that found nothing to do.
fn aLockedCollectorDoesNothing() void {
    freshHeap();

    const handle = gc_alloc.gclock();
    c.vm().next_collection = 4242;
    const blocks = c.vm().block_count;

    gc_mark.collect();

    std.debug.assert(c.vm().next_collection == 4242);
    std.debug.assert(c.vm().block_count == blocks);

    gc_alloc.gcunlock(handle);
    gc_mark.collect();
    std.debug.assert(c.vm().next_collection == 0);
}

/// The interval heuristic keeps a large heap from being collected on every
/// allocation. It runs before the sweep, so it is sized by the block count
/// going in, and it only ever raises the interval.
fn theIntervalHeuristic() void {
    const saved = c.vm().gc_interval;

    c.vm().gc_interval = 0;
    const blocks = c.vm().block_count;
    gc_mark.collect();
    std.debug.assert(c.vm().gc_interval == blocks * @sizeOf(types.JanetGCObject));

    const high = std.math.maxInt(usize) / 2;
    c.vm().gc_interval = high;
    gc_mark.collect();
    std.debug.assert(c.vm().gc_interval == high);

    c.vm().gc_interval = saved;
}

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
