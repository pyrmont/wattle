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
const abi = @import("abi");
const c = abi.c;
const harness = @import("harness.zig");
const abstract_type = @import("subsystems").abstract_type;
const AbstractType = abstract_type.AbstractType;

/// `janet.h` declares all four head accessors as real functions as well as
/// macros, and the runtime exports them — so the contract uses the runtime's
/// own arithmetic to *find* a header. That is circular only for the layout
/// question, which `theHeadOffsets` answers from the allocator instead.
fn headerOf(pointer: ?*anyopaque) *c.JanetGCObject {
    return @ptrCast(@alignCast(pointer.?));
}

fn reachable(pointer: ?*anyopaque) bool {
    return headerOf(pointer).flags & c.JANET_MEM_REACHABLE != 0;
}

fn unmark(pointer: ?*anyopaque) void {
    headerOf(pointer).flags &= ~@as(i32, c.JANET_MEM_REACHABLE);
}

/// The head of whatever `value` refers to, or null for a value the collector
/// does not trace. Mirrors the cases `janet_check_liveref` distinguishes.
fn headOf(value: c.Janet) ?*anyopaque {
    return switch (c.janet_type(value)) {
        c.JANET_ARRAY,
        c.JANET_TABLE,
        c.JANET_FUNCTION,
        c.JANET_BUFFER,
        c.JANET_FIBER,
        => c.janet_unwrap_pointer(value),
        c.JANET_STRING,
        c.JANET_SYMBOL,
        c.JANET_KEYWORD,
        => c.janet_string_head(c.janet_unwrap_string(value)),
        c.JANET_ABSTRACT => c.janet_abstract_head(c.janet_unwrap_abstract(value)),
        c.JANET_TUPLE => c.janet_tuple_head(c.janet_unwrap_tuple(value)),
        c.JANET_STRUCT => c.janet_struct_head(c.janet_unwrap_struct(value)),
        else => null,
    };
}

fn unmarkValue(value: c.Janet) void {
    if (headOf(value)) |head| unmark(head);
}

fn valueReachable(value: c.Janet) bool {
    return reachable(headOf(value).?);
}

/// Start from a heap with no marks left over from an earlier case. A
/// collection ends by clearing every bit it set, so this is the cheapest way
/// to get one.
fn freshHeap() void {
    c.janet_collect();
}

/// The block `janet_gcalloc` most recently prepended to the main heap.
fn newestBlock() usize {
    return @intFromPtr(c.janet_vm.blocks);
}

/// The runtime's `@sizeOf` arithmetic against its own allocator.
///
/// Each case allocates one value of the kind under test and compares the
/// pointer the runtime handed back against the block it just allocated. The
/// C spelling of this question lives in `test/abi.c`; this is the half that
/// needs a running heap, and the two are independent.
fn theHeadOffsets() void {
    freshHeap();

    const string = c.janet_string("head-offset-probe", 17);
    std.debug.assert(@intFromPtr(string) - newestBlock() == @sizeOf(c.JanetStringHead));

    const tuple = c.janet_tuple_begin(1);
    std.debug.assert(@intFromPtr(tuple) - newestBlock() == @sizeOf(c.JanetTupleHead));
    tuple[0] = c.janet_wrap_nil();
    _ = c.janet_tuple_end(tuple);

    const structure = c.janet_struct_begin(1);
    std.debug.assert(@intFromPtr(structure) - newestBlock() == @sizeOf(c.JanetStructHead));
    c.janet_struct_put(structure, c.janet_ckeywordv("k"), c.janet_wrap_nil());
    _ = c.janet_struct_end(structure);

    const abstract = c.janet_abstract(abstract_type.stored(&at_plain), 8);
    std.debug.assert(@intFromPtr(abstract) - newestBlock() == @sizeOf(c.JanetAbstractHead));

    // `JanetFunction`'s environments are its own flexible array, and the
    // function *is* its block — so the oracle is what lives at the computed
    // slot rather than a difference of addresses. A closure with a captured
    // binding puts a real `JanetFuncEnv` there; if the offset were wrong the
    // slot would hold padding, and a padding word is not a live block of type
    // `JANET_MEMORY_FUNCENV`.
    var out: c.Janet = undefined;
    std.debug.assert(c.janet_dostring(
        c.janet_core_env(null),
        "(let [x 1] (fn [] x))",
        "gc-mark-test",
        &out,
    ) == 0);
    const function = c.janet_unwrap_function(out);
    c.janet_gcroot(out);
    std.debug.assert(function.*.def.*.environments_length > 0);

    const slot: *[*c]c.JanetFuncEnv = @ptrFromInt(@intFromPtr(function) + @sizeOf(c.JanetFunction));
    const environment = slot.*;
    std.debug.assert(environment != null);
    std.debug.assert(headerOf(environment).flags & c.JANET_MEM_TYPEBITS == c.JANET_MEMORY_FUNCENV);
    std.debug.assert(onBlockList(environment));

    _ = c.janet_gcunroot(out);
}

/// Whether a block is still on the main heap list. Only ever called for a
/// block known to be live, so nothing freed is dereferenced.
fn onBlockList(block: ?*anyopaque) bool {
    var current = c.janet_vm.blocks;
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
var probe_root_value: c.Janet = undefined;
var probe_child_value: c.Janet = undefined;

fn probeGcmark(_: ?*anyopaque, _: usize) callconv(.c) c_int {
    probe_gcmark_calls += 1;
    probe_saw_mark_phase = c.janet_vm.gc_mark_phase;
    c.janet_mark(probe_child_value);
    if (probe_roots_on_mark) c.janet_gcroot(probe_root_value);
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
    const roots = c.janet_vm.root_count;
    var local: usize = 0;

    c.janet_mark(c.janet_wrap_nil());
    c.janet_mark(c.janet_wrap_true());
    c.janet_mark(c.janet_wrap_number(3.5));
    c.janet_mark(harness.wrapInteger(-7));
    c.janet_mark(c.janet_wrap_pointer(&local));

    std.debug.assert(c.janet_vm.root_count == roots);

    const string = c.janet_cstringv("after-immediates");
    unmarkValue(string);
    c.janet_mark(string);
    std.debug.assert(valueReachable(string));
}

fn theThreeStringKinds() void {
    const string = c.janet_cstringv("a string");
    const keyword = c.janet_ckeywordv("a-keyword");
    const symbol = c.janet_csymbolv("a-symbol");

    unmarkValue(string);
    unmarkValue(keyword);
    unmarkValue(symbol);

    c.janet_mark(string);
    c.janet_mark(keyword);
    c.janet_mark(symbol);

    std.debug.assert(valueReachable(string));
    std.debug.assert(valueReachable(keyword));
    std.debug.assert(valueReachable(symbol));
}

fn aBuffer() void {
    const buffer = c.janet_buffer(8);
    _ = c.janet_buffer_push_cstring(buffer, "contents");
    unmark(buffer);
    c.janet_mark(c.janet_wrap_buffer(buffer));
    std.debug.assert(reachable(buffer));
}

// ----------------------------------------------------------------- arrays

fn anArrayMarksItsElements() void {
    const array = c.janet_array(2);
    const string = c.janet_cstringv("in an array");
    c.janet_array_push(array, string);

    unmark(array);
    unmarkValue(string);
    c.janet_mark(c.janet_wrap_array(array));

    std.debug.assert(reachable(array));
    std.debug.assert(valueReachable(string));
}

/// A weak array is marked but not traversed. The type test in the array walk
/// is the only thing that distinguishes the two kinds during marking, and it
/// is easy to mistake for a redundant check.
fn aWeakArrayDoesNotMarkItsElements() void {
    const array = c.janet_array_weak(2);
    const string = c.janet_cstringv("in a weak array");
    c.janet_array_push(array, string);

    unmark(array);
    unmarkValue(string);
    c.janet_mark(c.janet_wrap_array(array));

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
        make: *const fn (i32) callconv(.c) [*c]c.JanetTable,
        keeps_key: bool,
        keeps_value: bool,
    };
    const cases = [_]Case{
        .{ .make = c.janet_table, .keeps_key = true, .keeps_value = true },
        .{ .make = c.janet_table_weakk, .keeps_key = false, .keeps_value = true },
        .{ .make = c.janet_table_weakv, .keeps_key = true, .keeps_value = false },
        .{ .make = c.janet_table_weakkv, .keeps_key = false, .keeps_value = false },
    };

    for (cases) |case| {
        const table = case.make(4);
        const key = c.janet_cstringv("the key");
        const value = c.janet_cstringv("the value");
        c.janet_table_put(table, key, value);

        unmark(table);
        unmarkValue(key);
        unmarkValue(value);
        c.janet_mark(c.janet_wrap_table(table));

        std.debug.assert(reachable(table));
        std.debug.assert(valueReachable(key) == case.keeps_key);
        std.debug.assert(valueReachable(value) == case.keeps_value);
    }
}

/// The prototype chain is followed iteratively, and the reachability test is
/// what terminates a cycle. Both halves are checked here: a three-link chain
/// is marked to its end, and a two-table cycle returns rather than spinning.
fn thePrototypeChain() void {
    const a = c.janet_table(1);
    const b = c.janet_table(1);
    const d = c.janet_table(1);
    a.*.proto = b;
    b.*.proto = d;

    const deep = c.janet_cstringv("in the last proto");
    c.janet_table_put(d, c.janet_ckeywordv("k"), deep);

    unmark(a);
    unmark(b);
    unmark(d);
    unmarkValue(deep);
    c.janet_mark(c.janet_wrap_table(a));

    std.debug.assert(reachable(a) and reachable(b) and reachable(d));
    std.debug.assert(valueReachable(deep));

    const x = c.janet_table(1);
    const y = c.janet_table(1);
    x.*.proto = y;
    y.*.proto = x;
    unmark(x);
    unmark(y);
    c.janet_mark(c.janet_wrap_table(x));
    std.debug.assert(reachable(x) and reachable(y));
}

// -------------------------------------------------------- structs, tuples

fn aStructMarksItsProtoAndEntries() void {
    const proto_builder = c.janet_struct_begin(1);
    const proto_value = c.janet_cstringv("in the struct proto");
    c.janet_struct_put(proto_builder, c.janet_ckeywordv("p"), proto_value);
    const proto = c.janet_struct_end(proto_builder);

    const builder = c.janet_struct_begin(1);
    const key = c.janet_cstringv("struct key");
    const value = c.janet_cstringv("struct value");
    c.janet_struct_put(builder, key, value);
    const structure = c.janet_struct_end(builder);
    c.janet_struct_head(structure).*.proto = proto;

    unmark(c.janet_struct_head(structure));
    unmark(c.janet_struct_head(proto));
    unmarkValue(key);
    unmarkValue(value);
    unmarkValue(proto_value);

    c.janet_mark(c.janet_wrap_struct(structure));

    std.debug.assert(reachable(c.janet_struct_head(structure)));
    std.debug.assert(reachable(c.janet_struct_head(proto)));
    std.debug.assert(valueReachable(key));
    std.debug.assert(valueReachable(value));
    std.debug.assert(valueReachable(proto_value));
}

fn aTupleMarksItsElements() void {
    var items = [2]c.Janet{
        c.janet_cstringv("tuple element one"),
        c.janet_cstringv("tuple element two"),
    };
    const tuple = c.janet_tuple_n(&items, 2);

    unmark(c.janet_tuple_head(tuple));
    unmarkValue(items[0]);
    unmarkValue(items[1]);

    c.janet_mark(c.janet_wrap_tuple(tuple));

    std.debug.assert(reachable(c.janet_tuple_head(tuple)));
    std.debug.assert(valueReachable(items[0]));
    std.debug.assert(valueReachable(items[1]));
}

// -------------------------------------------------------------- abstracts

/// The callback runs once per collection, not once per reference: the
/// reachability test in front of it is what stops a shared abstract from being
/// walked again by every holder.
fn anAbstractMarksThroughItsCallbackOnce() void {
    const abstract = c.janet_abstract(abstract_type.stored(&at_marked), 8);
    probe_child_value = c.janet_cstringv("reached by gcmark");
    probe_gcmark_calls = 0;

    unmark(c.janet_abstract_head(abstract));
    unmarkValue(probe_child_value);

    c.janet_mark(c.janet_wrap_abstract(abstract));
    std.debug.assert(reachable(c.janet_abstract_head(abstract)));
    std.debug.assert(probe_gcmark_calls == 1);
    std.debug.assert(valueReachable(probe_child_value));

    c.janet_mark(c.janet_wrap_abstract(abstract));
    std.debug.assert(probe_gcmark_calls == 1);
}

fn anAbstractWithoutAGcmark() void {
    const abstract = c.janet_abstract(abstract_type.stored(&at_plain), 8);
    unmark(c.janet_abstract_head(abstract));
    c.janet_mark(c.janet_wrap_abstract(abstract));
    std.debug.assert(reachable(c.janet_abstract_head(abstract)));
}

// ------------------------------------------------------ functions, fibers

/// `func->envs[i]`, which `@cImport` cannot spell: `envs` is a flexible array
/// member. `theHeadOffsets` is what makes this arithmetic safe to write.
fn funcEnv(function: [*c]c.JanetFunction, index: usize) [*c]c.JanetFuncEnv {
    const base = @intFromPtr(function) + @sizeOf(c.JanetFunction);
    const slot: *[*c]c.JanetFuncEnv = @ptrFromInt(base + index * @sizeOf(*c.JanetFuncEnv));
    return slot.*;
}

/// Every value a closure can still reach has to be marked through it: the
/// definition, the definition's source name, and the captured environment. The
/// environment is the interesting one — the mark detaches it from its dead
/// fiber first, so what is marked is the copied-out values rather than the
/// fiber.
fn aClosureMarksItsCapturedEnvironment() void {
    var out: c.Janet = undefined;
    std.debug.assert(c.janet_dostring(
        c.janet_core_env(null),
        "(let [x \"captured-by-closure\"] (fn [] x))",
        "gc-mark-test",
        &out,
    ) == 0);
    std.debug.assert(harness.isType(out, c.JANET_FUNCTION));
    c.janet_gcroot(out);

    const function = c.janet_unwrap_function(out);
    std.debug.assert(function.*.def != null);
    std.debug.assert(function.*.def.*.environments_length > 0);

    unmark(function);
    unmark(function.*.def);
    if (function.*.def.*.source != null) unmark(c.janet_string_head(function.*.def.*.source));
    var index: usize = 0;
    while (index < function.*.def.*.environments_length) : (index += 1) {
        unmark(funcEnv(function, index));
    }

    c.janet_mark(out);

    std.debug.assert(reachable(function));
    std.debug.assert(reachable(function.*.def));
    if (function.*.def.*.source != null) {
        std.debug.assert(reachable(c.janet_string_head(function.*.def.*.source)));
    }

    // The environment is detached by the mark, so its values are off the stack
    // and every one of them must have been marked in place.
    const environment = funcEnv(function, 0);
    std.debug.assert(reachable(environment));
    std.debug.assert(environment.*.offset == 0);
    var found: i32 = 0;
    var slot: i32 = 0;
    while (slot < environment.*.length) : (slot += 1) {
        const head = headOf(environment.*.as.values[@intCast(slot)]) orelse continue;
        std.debug.assert(reachable(head));
        found += 1;
    }
    std.debug.assert(found > 0);

    _ = c.janet_gcunroot(out);
}

/// A suspended fiber holds its frames, and each frame holds a function whose
/// only reference may be that frame. The fiber below is stopped inside a call,
/// so `frame->func` is set and the frame walk is what reaches it.
fn aSuspendedFiberMarksItsFrames() void {
    var out: c.Janet = undefined;
    std.debug.assert(c.janet_dostring(
        c.janet_core_env(null),
        "(fiber/new (fn [] (yield \"suspended\") nil))",
        "gc-mark-test",
        &out,
    ) == 0);
    std.debug.assert(harness.isType(out, c.JANET_FIBER));
    c.janet_gcroot(out);

    const fiber = c.janet_unwrap_fiber(out);
    var resumed: c.Janet = undefined;
    _ = c.janet_continue(fiber, c.janet_wrap_nil(), &resumed);
    std.debug.assert(fiber.*.frame > 0);

    const frame: *c.JanetStackFrame = @ptrCast(@alignCast(
        fiber.*.data + @as(usize, @intCast(fiber.*.frame - c.JANET_FRAME_SIZE)),
    ));
    std.debug.assert(frame.func != null);

    const dyns = c.janet_table(1);
    fiber.*.env = dyns;
    const last = c.janet_cstringv("the last value");
    fiber.*.last_value = last;

    unmark(fiber);
    unmark(frame.func);
    unmark(dyns);
    unmarkValue(last);

    c.janet_mark(out);

    std.debug.assert(reachable(fiber));
    std.debug.assert(reachable(frame.func));
    std.debug.assert(reachable(dyns));
    std.debug.assert(valueReachable(last));

    _ = c.janet_gcunroot(out);
}

/// The child chain is followed iteratively, and a fiber already marked ends
/// it. Built by hand because reaching this state from Janet source needs a
/// fiber suspended inside another one.
fn theFiberChildChain() void {
    var parent_value: c.Janet = undefined;
    var child_value: c.Janet = undefined;
    const env = c.janet_core_env(null);
    std.debug.assert(c.janet_dostring(env, "(fiber/new (fn [] nil))", "gc-mark-test", &parent_value) == 0);
    std.debug.assert(c.janet_dostring(env, "(fiber/new (fn [] nil))", "gc-mark-test", &child_value) == 0);
    c.janet_gcroot(parent_value);
    c.janet_gcroot(child_value);

    const parent = c.janet_unwrap_fiber(parent_value);
    const child = c.janet_unwrap_fiber(child_value);
    const saved = parent.*.child;
    parent.*.child = child;

    const held = c.janet_cstringv("held by the child fiber");
    child.*.last_value = held;

    unmark(parent);
    unmark(child);
    unmarkValue(held);

    c.janet_mark(parent_value);

    std.debug.assert(reachable(parent));
    std.debug.assert(reachable(child));
    std.debug.assert(valueReachable(held));

    parent.*.child = saved;
    _ = c.janet_gcunroot(child_value);
    _ = c.janet_gcunroot(parent_value);
}

// --------------------------------------------------------- recursion guard

/// Build a chain of `n` single-element arrays, each holding the next.
/// Collection is suspended for the duration: nothing roots the chain until it
/// is finished, and it is long enough that building it would otherwise trigger
/// one.
fn buildChain(chain: [][*c]c.JanetArray) void {
    const handle = c.janet_gclock();
    chain[0] = c.janet_array(1);
    for (1..chain.len) |index| {
        chain[index] = c.janet_array(1);
        c.janet_array_push(chain[index - 1], c.janet_wrap_array(chain[index]));
    }
    c.janet_gcunlock(handle);
}

/// The guard is exact, and where it stops is the contract. Marking a chain one
/// link longer than `JANET_RECURSION_GUARD` marks every link up to the limit
/// and *roots* the one after it — rooting rather than recursing is what keeps
/// the traversal off the C stack, and rooting rather than dropping is what
/// keeps the rest of the graph from being collected.
fn theGuardRootsTheOverflow() !void {
    const n: usize = c.JANET_RECURSION_GUARD + 2;
    const chain = try std.heap.c_allocator.alloc([*c]c.JanetArray, n);
    defer std.heap.c_allocator.free(chain);
    buildChain(chain);

    const head = c.janet_wrap_array(chain[0]);
    c.janet_gcroot(head);

    for (chain) |link| unmark(link);
    const roots = c.janet_vm.root_count;

    c.janet_mark(head);

    std.debug.assert(c.janet_vm.root_count == roots + 1);
    std.debug.assert(c.janet_unwrap_pointer(c.janet_vm.roots[roots]) ==
        @as(?*anyopaque, chain[c.JANET_RECURSION_GUARD]));
    std.debug.assert(reachable(chain[c.JANET_RECURSION_GUARD - 1]));
    std.debug.assert(!reachable(chain[c.JANET_RECURSION_GUARD]));
    std.debug.assert(!reachable(chain[c.JANET_RECURSION_GUARD + 1]));

    // Drop the root the guard added, then the chain itself.
    c.janet_vm.root_count = roots;
    _ = c.janet_gcunroot(head);
}

/// What the guard defers, `janet_collect` finishes. The chain below is three
/// times the guard's depth, and the only reference to its last link is through
/// every link before it; if the drain loop stopped early or dropped what it
/// popped, the weak table would lose the entry in the sweep.
fn aCollectionFinishesDeepGraphs() !void {
    const n: usize = 3 * c.JANET_RECURSION_GUARD;
    const chain = try std.heap.c_allocator.alloc([*c]c.JanetArray, n);
    defer std.heap.c_allocator.free(chain);
    buildChain(chain);

    const head = c.janet_wrap_array(chain[0]);
    c.janet_gcroot(head);

    const witness = c.janet_table_weakv(2);
    const witness_value = c.janet_wrap_table(witness);
    c.janet_gcroot(witness_value);
    const key = c.janet_ckeywordv("tail");
    const tail = c.janet_wrap_array(chain[n - 1]);
    c.janet_table_put(witness, key, tail);

    const roots = c.janet_vm.root_count;
    c.janet_collect();

    std.debug.assert(c.janet_vm.root_count == roots);
    std.debug.assert(harness.equals(c.janet_table_get(witness, key), tail));

    _ = c.janet_gcunroot(witness_value);
    _ = c.janet_gcunroot(head);
}

// ------------------------------------------------------------- collection

/// A root added while the collection is running is consumed by it: marked, and
/// removed. Only the roots that predate the collection survive it.
fn aCollectionDrainsRootsAddedDuringMarking() void {
    freshHeap();

    const abstract = c.janet_abstract(abstract_type.stored(&at_marked), 8);
    const abstract_value = c.janet_wrap_abstract(abstract);
    c.janet_gcroot(abstract_value);

    probe_child_value = c.janet_cstringv("marked by gcmark");
    probe_root_value = c.janet_cstringv("rooted by gcmark");
    probe_roots_on_mark = true;
    probe_gcmark_calls = 0;
    probe_saw_mark_phase = -1;

    const witness = c.janet_table_weakv(2);
    const witness_value = c.janet_wrap_table(witness);
    c.janet_gcroot(witness_value);
    const key = c.janet_ckeywordv("rooted");
    c.janet_table_put(witness, key, probe_root_value);

    const roots = c.janet_vm.root_count;
    c.janet_collect();

    std.debug.assert(probe_gcmark_calls == 1);
    std.debug.assert(c.janet_vm.root_count == roots);
    std.debug.assert(harness.equals(c.janet_table_get(witness, key), probe_root_value));

    probe_roots_on_mark = false;
    _ = c.janet_gcunroot(witness_value);
    _ = c.janet_gcunroot(abstract_value);
}

/// The flag is set for the duration of the traversal and clear once it is
/// over. A `gcmark` callback is the only thing that can see it set.
fn theMarkPhaseFlag() void {
    const abstract = c.janet_abstract(abstract_type.stored(&at_marked), 8);
    const abstract_value = c.janet_wrap_abstract(abstract);
    c.janet_gcroot(abstract_value);
    probe_child_value = c.janet_wrap_nil();
    probe_saw_mark_phase = -1;

    std.debug.assert(c.janet_vm.gc_mark_phase == 0);
    c.janet_collect();
    std.debug.assert(probe_saw_mark_phase == 1);
    std.debug.assert(c.janet_vm.gc_mark_phase == 0);

    _ = c.janet_gcunroot(abstract_value);
}

/// A locked collector does nothing at all — not even the bookkeeping at the
/// end of a collection, which is how the early return is told apart from a
/// collection that found nothing to do.
fn aLockedCollectorDoesNothing() void {
    freshHeap();

    const handle = c.janet_gclock();
    c.janet_vm.next_collection = 4242;
    const blocks = c.janet_vm.block_count;

    c.janet_collect();

    std.debug.assert(c.janet_vm.next_collection == 4242);
    std.debug.assert(c.janet_vm.block_count == blocks);

    c.janet_gcunlock(handle);
    c.janet_collect();
    std.debug.assert(c.janet_vm.next_collection == 0);
}

/// The interval heuristic keeps a large heap from being collected on every
/// allocation. It runs before the sweep, so it is sized by the block count
/// going in, and it only ever raises the interval.
fn theIntervalHeuristic() void {
    const saved = c.janet_vm.gc_interval;

    c.janet_vm.gc_interval = 0;
    const blocks = c.janet_vm.block_count;
    c.janet_collect();
    std.debug.assert(c.janet_vm.gc_interval == blocks * @sizeOf(c.JanetGCObject));

    const high = std.math.maxInt(usize) / 2;
    c.janet_vm.gc_interval = high;
    c.janet_collect();
    std.debug.assert(c.janet_vm.gc_interval == high);

    c.janet_vm.gc_interval = saved;
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
    _ = c.janet_init();
    body() catch @panic("gc_mark: out of memory building a chain");
    c.janet_deinit();
}
