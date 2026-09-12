//! The mark phase: the traversal that decides what is reachable, the recursion
//! guard that stops it running off the stack, and `collect`, which drives it.
//!
//! `collect` runs a whole collection and `mark` marks one value and everything
//! it refers to. Everything else here is one type's step of the walk.
//!
//! Nothing here frees anything. The traversal only ever sets `reachable` in a
//! header it did not allocate and will not release. That is what makes the
//! boundary a clean one: the mark phase reads the object graph and writes one
//! bit per object, and the sweep is on the other side of it.
//!
//! `collect` is here rather than with the sweep because it is the only writer
//! of the collector's two per-collection fields, `gc.zig`'s `depth` and
//! `orig_rootcount`, and `mark` is their only other reader. Both are
//! `Collector` fields rather than file-level state, because they are owned by
//! the collector that spends them.
//!
//! ## Nothing here is stranded by a raise
//!
//! Two calls reach code this runtime does not own: an abstract type's
//! `gcmark`, and a root fiber's `ev_callback` with `constants.AsyncEvent.mark`.
//! `abi.zig` declares `gcmark` as `callconv(.c) void`, so it has no way to
//! raise. The callback's type does admit a raise, and
//! `callback_type.dispatchTotal` is what the walk reaches it through: a raise
//! from the mark event aborts there rather than travelling. Either way the
//! frames of the walk own nothing.
//!
//! One detail of the walk reads as redundant and is not: `markArray` marks
//! elements only for `MemoryType.array`, so a weak array's contents are
//! skipped here and dropped in the sweep. That is what makes the array weak.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const arrays = @import("../value/arrays.zig");
const buffers = @import("../value/buffers.zig");
const config = @import("config");
const constants = @import("constants");
const ev_callback = @import("../callback_type.zig");
const ev_loop = @import("../ev.zig");
const fibers = @import("../value/fibers.zig");
const functions = @import("../value/functions.zig");
const gc_alloc = @import("../gc.zig");
const gc_sweep = @import("sweep.zig");
const repr = @import("repr");
const strings = @import("../value/strings.zig");
const structs = @import("../value/structs.zig");
const tables = @import("../value/tables.zig");
const tuples = @import("../value/tuples.zig");
const vm_state = @import("../vm/state.zig");
const wrap = @import("../value/helpers/wrap.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// A stack frame's size in `Value` slots, named locally so the frame
/// arithmetic in `markFiber` reads as arithmetic.
const frame_size: i32 = constants.JANET_FRAME_SIZE;

/// Whether this build has the event loop. Three parts of the traversal are the
/// event loop's, and one of them reaches a `Vm` field that exists only in that
/// configuration, so this gates compilation and not merely behaviour.
const has_ev = constants.JANET_VM_HAS_EV != 0;

// ==========================================================================
// Public functions
// ==========================================================================

/// Runs a full collection: mark from every root, then sweep.
///
/// The two root loops behave differently on purpose. The first walks the roots
/// that existed when the collection began. The second drains everything added
/// since, including the roots `mark` created when the depth guard ran out and
/// any a `gcmark` callback added, marking each and removing it. So a root
/// added during a collection is consumed by that collection, and only roots
/// that predate it survive it.
pub fn collect() void {
    // Three of the VM's aggregates and one ambient field, each named: the
    // collector's own counters, the root set it walks, the scratch table it
    // empties at the end, and the root fiber, which is language state rather
    // than collector state.
    const v = vm_state.current();
    const g = &v.gc;
    const roots = &v.roots;
    if (g.suspend_count != 0) return;
    g.depth = config.recursion_guard;
    g.mark_phase = true;

    // Prevent many major collections back to back. A full collection is
    // O(block_count), so a large heap gets a proportionally larger interval.
    // Both products saturate: the value is a heuristic, so a heap too large to
    // multiply gets the largest interval there is rather than a wrapped one,
    // which would be an interval smaller than the heap it was derived from.
    if (g.block_count *| 8 > g.interval) {
        g.interval = g.block_count *| @sizeOf(abi.GCObject);
    }

    g.orig_rootcount = roots.items.len;

    if (has_ev) ev_loop.evMark();

    // Null outside the interpreter loop, which `collect` may be called from.
    if (v.root_fiber) |root| markFiber(root);

    var i: usize = 0;
    while (i < g.orig_rootcount) : (i += 1) {
        mark(roots.items[i]);
    }
    while (g.orig_rootcount < roots.items.len) {
        const x = roots.pop().?;
        mark(x);
    }

    g.mark_phase = false;
    gc_sweep.sweep();
    g.next_collection = 0;
    gc_alloc.freeAllScratch(&v.scratch);
}

/// Marks `x` as reachable, along with everything it refers to.
///
/// The guard is the whole shape of this function. Every recursive marker
/// re-enters here, so decrementing on the way in and restoring on the way out
/// bounds the stack the traversal can consume. When the budget is exhausted
/// the value is rooted instead of traversed, and `collect`'s second loop
/// drains those roots and marks them from a fresh budget. A graph deeper than
/// `config.recursion_guard` is therefore marked completely, in slices, rather
/// than overflowing the stack or being lost.
pub fn mark(x: repr.Value) void {
    const g = &vm_state.current().gc;
    if (g.depth != 0) {
        g.depth -= 1;
        switch (repr.typeOf(x)) {
            repr.Tag.string, repr.Tag.keyword, repr.Tag.symbol => markString(wrap.toString(x)),
            repr.Tag.function => markFunction(wrap.toFunction(x)),
            repr.Tag.array => markArray(wrap.toArray(x)),
            repr.Tag.table => markTable(wrap.toTable(x)),
            repr.Tag.@"struct" => markStruct(wrap.toStruct(x)),
            repr.Tag.tuple => markTuple(wrap.toTuple(x)),
            repr.Tag.buffer => markBuffer(wrap.toBuffer(x)),
            repr.Tag.fiber => markFiber(wrap.toFiber(x)),
            repr.Tag.abstract => markAbstract(wrap.toAbstract(x)),
            else => {},
        }
        g.depth += 1;
    } else {
        gc_alloc.gcroot(x);
    }
}

// ==========================================================================
// Private functions
// ==========================================================================

/// A function's `i`th captured environment. They follow the header
/// immediately, as the allocator lays them out.
inline fn funcEnv(func: *functions.Function, i: usize) *functions.FuncEnv {
    return functions.envsOf(func)[i].?;
}

/// Every collectable object has a `GCObject`, which is what lets these four
/// take any of them. Taking its address says exactly that, where a `@ptrCast`
/// would say the stronger and unchecked thing that the header sits at offset
/// zero.
inline fn gcHeader(mem: anytype) *abi.GCObject {
    return &mem.gc;
}

inline fn gcMark(mem: anytype) void {
    gcHeader(mem).flags.reachable = true;
}

inline fn gcReachable(mem: anytype) bool {
    return gcHeader(mem).flags.reachable;
}

inline fn gcType(mem: anytype) gc_alloc.MemoryType {
    return gc_alloc.memoryTypeOf(gcHeader(mem));
}

/// Marks an abstract, and dispatches to its `gcmark` callback if it has one.
///
/// A threaded abstract is not marked at all. It is recorded in
/// `vm.ev.threaded_abstracts` instead, and the sweep reads that table to
/// decide which references this interpreter still has. The bookkeeping is a
/// table write, which can allocate, so this is one of the few places in the
/// walk that can end the process, and the only place it can do so before
/// anything has been marked.
fn markAbstract(adata: *anyopaque) void {
    const head = abi.abstractHead(adata);
    if (has_ev) {
        if (gc_alloc.memoryTypeOf(&head.gc) == .threaded_abstract) {
            tables.put(&vm_state.current().ev.threaded_abstracts, wrap.fromAbstract(adata), wrap.fromTrue());
            return;
        }
    }
    if (gcReachable(head)) return;
    gcMark(head);
    // A `gcmark` has no way to raise: `abi.zig` declares the slot
    // `callconv(.c) void` and `api/abstract_type.zig` states the contract. The
    // collector has nowhere to deliver a raise to.
    if (head.type.gcmark) |gcmark| {
        _ = gcmark(adata, head.size);
    }
}

/// A weak array is marked but not traversed. The elements are exactly what a
/// weak array does not keep alive, and the sweep nils out whichever of them
/// the rest of the heap did not reach. The type test is the whole difference
/// between the two array kinds during marking.
fn markArray(array: *arrays.Array) void {
    if (gcReachable(array)) return;
    gcMark(array);
    if (gcType(array) == gc_alloc.MemoryType.array) {
        markMany(array.slice());
    }
}

/// Marks a buffer. Its bytes are not values, so there is nothing to traverse.
fn markBuffer(buffer: *buffers.Buffer) void {
    gcMark(buffer);
}

/// Marks a fiber: its last value, the arguments above the top frame, every
/// frame's function, environment and locals, its dynamic bindings, and, under
/// the event loop, whatever it is waiting on.
///
/// The frame walk goes down the `prevframe` chain rather than up the stack,
/// because the region belonging to a frame is bounded by where the next frame
/// starts, and that is only known once it has been seen. `j` moves that
/// boundary from one iteration to the next.
///
/// The child chain is followed iteratively for the same reason the prototype
/// chain is: a long chain of resumed fibers would otherwise cost a stack frame
/// per link, on top of the frames the fiber's own contents already need.
fn markFiber(fiber_in: *fibers.Fiber) void {
    var fiber = fiber_in;
    while (true) {
        if (gcReachable(fiber)) return;
        gcMark(fiber);

        mark(fiber.last_value);

        // Values on the argument stack.
        markMany(run(repr.Value, stackAt(fiber.data.?, fiber.stackstart), fiber.stacktop -% fiber.stackstart));

        var i = fiber.frame;
        var j = fiber.stackstart -% frame_size;
        while (i > 0) {
            const frame: *vm_state.StackFrame = @ptrCast(@alignCast(stackAt(fiber.data.?, i -% frame_size)));
            if (frame.func) |func| markFunction(func);
            if (frame.env) |env| markFuncenv(env);
            // Locals of this frame, up to where the frame above it starts.
            markMany(run(repr.Value, stackAt(fiber.data.?, i), j -% i));
            j = i -% frame_size;
            i = frame.prevframe;
        }

        if (fiber.env) |env| markTable(env);

        if (has_ev) {
            if (fiber.supervisor_channel != null) {
                markAbstract(fiber.supervisor_channel.?);
            }
            if (fiber.ev_stream != null) {
                markAbstract(fiber.ev_stream.?);
            }
            if (fiber.ev_callback) |callback| {
                ev_callback.dispatchTotal(ev_callback.of(callback), fiber, constants.AsyncEvent.mark);
            }
        }

        if (fiber.child) |child| {
            fiber = child;
            continue;
        }
        return;
    }
}

/// Marks a funcdef, its constants, its nested definitions and its debug
/// strings.
fn markFuncdef(def: *functions.FuncDef) void {
    if (gcReachable(def)) return;
    gcMark(def);
    markMany(def.constantValues());
    for (def.subdefs()) |subdef| markFuncdef(subdef);
    if (def.source) |source| markString(source);
    if (def.name) |name| markString(name);
    if (def.symbolmap != null) {
        for (def.symbols()) |entry| markString(entry.symbol.?);
    }
}

/// Marks a function environment, detaching it from a dead fiber first where it
/// can be.
///
/// The detach is not an optimisation the collector could skip: an environment
/// that still points at a dead fiber would keep the whole fiber alive, stack
/// included, through the mark below.
fn markFuncenv(env: *functions.FuncEnv) void {
    if (gcReachable(env)) return;
    gcMark(env);
    functions.envMaybeDetach(env);
    if (env.offset > 0) {
        markFiber(env.as.fiber.?);
    } else {
        markMany(run(repr.Value, env.as.values, env.length));
    }
}

/// Marks a closure, its captured environments and its definition.
///
/// The null test on `def` is not defensive: a function is allocated, marked
/// reachable, and only then given its definition, so a collection triggered
/// between those two steps sees exactly this state.
fn markFunction(func: *functions.Function) void {
    if (gcReachable(func)) return;
    gcMark(func);
    if (func.def) |def| {
        const numenvs = def.environments_length;
        for (0..numenvs) |i| {
            markFuncenv(funcEnv(func, i));
        }
        markFuncdef(def);
    }
}

/// Marks the key of every entry in `kvs`, for a weak-valued table.
fn markKeys(kvs: []const tables.KV) void {
    for (kvs) |kv| mark(kv.key);
}

/// Marks both halves of every entry in `kvs`.
fn markKvs(kvs: []const tables.KV) void {
    for (kvs) |kv| {
        mark(kv.key);
        mark(kv.value);
    }
}

/// Marks every value in `values`.
fn markMany(values: []const repr.Value) void {
    for (values) |x| mark(x);
}

/// Marks a string, symbol or keyword, all three of which are one head with no
/// values under it.
fn markString(str: [*]const u8) void {
    gcMark(strings.head(str));
}

/// Marks a struct, its entries and its prototype chain, following the chain
/// iteratively so that a long chain costs no stack frame per link.
fn markStruct(st_in: [*]const tables.KV) void {
    var st = st_in;
    while (true) {
        const head = structs.head(st);
        if (gcReachable(head)) return;
        gcMark(head);
        markKvs(st[0..head.capacity]);
        st = head.proto orelse return;
    }
}

/// Marks a table and its prototype chain, following the chain iteratively: a
/// long chain of prototypes must not cost a stack frame each, and marking a
/// prototype is not a recursive step in the guard's budget.
///
/// Which half of each entry is traversed is what makes a table weak. A
/// weak-keyed table keeps its values alive, a weak-valued table keeps its
/// keys, and a table weak in both keeps neither, which is the case with no
/// branch of its own.
fn markTable(table_in: *tables.Table) void {
    var table = table_in;
    while (true) {
        if (gcReachable(table)) return;
        gcMark(table);
        const memtype = gcType(table);
        if (memtype == gc_alloc.MemoryType.table_weakk) {
            markValues(table.slots());
        } else if (memtype == gc_alloc.MemoryType.table_weakv) {
            markKeys(table.slots());
        } else if (memtype == gc_alloc.MemoryType.table) {
            markKvs(table.slots());
        }
        // Nothing for `MemoryType.table_weakkv`.
        if (table.proto) |proto| {
            table = proto;
            continue;
        }
        return;
    }
}

/// Marks a tuple and its elements.
fn markTuple(tuple: [*]const repr.Value) void {
    const head = tuples.head(tuple);
    if (gcReachable(head)) return;
    gcMark(head);
    markMany(tuple[0..head.length]);
}

/// Marks the value of every entry in `kvs`, for a weak-keyed table.
fn markValues(kvs: []const tables.KV) void {
    for (kvs) |kv| mark(kv.value);
}

/// The run of `n` items at `p`, or an empty slice.
///
/// A slice cannot express either of the two states this takes. A null pointer
/// with a count that still says otherwise is a partially constructed array or
/// a detached environment, and the null test is what stops the walk there;
/// `p.?[0..n]` would trap on exactly that. A negative count reaches this from
/// a malformed fiber, where the walk subtracts `frame_size` from a frame
/// address, and an empty run is the result where `@intCast` would trap.
///
/// `n` is `anytype` so that a `usize` count reaches it without a cast that
/// says nothing.
inline fn run(comptime T: type, p: ?[*]const T, n: anytype) []const T {
    if (n <= 0) return &.{};
    const items = p orelse return &.{};
    return items[0..@intCast(n)];
}

/// `data + index` for a fiber's stack.
///
/// The index is never negative here, and the assertion is what says so rather
/// than arithmetic that accommodates one. The frame layout makes every
/// quantity in the walk non-negative, `funcframe` leaving
/// `stackstart = frame + slotcount + frame_size` so that `j - i` is
/// `slotcount`, and the only way to build a fiber that breaks it is
/// unmarshalling, which validates
/// `frame + frame_size <= stackstart <= stacktop <= maxstack` before the
/// collector can ever see one.
///
/// Without the assertion a negative index forms a pointer before the array,
/// which the walk then reads through.
inline fn stackAt(data: [*]repr.Value, index: i32) [*]repr.Value {
    std.debug.assert(index >= 0);
    return data + @as(usize, @intCast(index));
}
