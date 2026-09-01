//! The mark phase: the traversal that decides what is reachable, the recursion
//! guard that stops it running off the stack, and `janet_collect`, which drives
//! it.
//!
//! **Nothing here frees anything.** The traversal only ever sets one bit --
//! `JANET_MEM_REACHABLE` -- in a header it did not allocate and will not
//! release. That is what makes the boundary a clean one: the mark phase reads
//! the object graph and writes one bit per object, and the sweep is on the
//! other side of it.
//!
//! **`janet_collect` belongs here rather than with the sweep.** It is the only
//! writer of the collector's two per-collection fields -- the recursion guard
//! and the root count the collection began with -- and `janet_mark` below is
//! their only other reader, so putting it anywhere else would separate the
//! pair.
//!
//! **Nothing here may hold anything across a raise.** Two calls reach code
//! this runtime does not own: an abstract type's `gcmark`, and a root fiber's
//! `ev_callback` with `JANET_ASYNC_EVENT_MARK`. Neither may raise, and if one
//! does the raise leaves through every frame of the walk. Those frames own
//! nothing, so the damage is exactly what Janet suffers: a half-marked heap,
//! no sweep, and `next_collection` left where it was.
//!
//! Three details of the C original are reproduced rather than repaired, and all
//! three are in `FOUND.md`:
//!
//!  - `janet_collect` indexes the root set with a `uint32_t` while the bound is
//!    a `size_t`, so a root set above 2^32 entries would loop forever. The
//!    counter here wraps for the same reason rather than trapping.
//!  - The collection-interval heuristic multiplies `block_count` by 8 and by
//!    `sizeof(JanetGCObject)` without a check, so a heap large enough to
//!    overflow `size_t` would compute a nonsense interval. Wrapping arithmetic
//!    keeps the two implementations bit-identical there.
//!  - `janet_mark_array` marks elements only for `JANET_MEMORY_ARRAY`, so a
//!    weak array's contents are skipped here and dropped in the sweep. That one
//!    is deliberate in the original; it is listed because the type test is easy
//!    to read as redundant and is not.

const std = @import("std");
const config = @import("config");
const repr = @import("repr");
const constants = @import("constants");
const vm_state = @import("../vm/state.zig");
const ev_callback = @import("../callback_type.zig");
const tables = @import("../value/tables.zig");
const gc_alloc = @import("../gc.zig");
const gc_sweep = @import("sweep.zig");
const functions = @import("../value/functions.zig");
const wrap = @import("../value/helpers/wrap.zig");
const ev_loop = @import("../ev.zig");
const buffers = @import("../value/buffers.zig");
const arrays = @import("../value/arrays.zig");
const strings = @import("../value/strings.zig");
const tuples = @import("../value/tuples.zig");
const structs = @import("../value/structs.zig");
const abi = @import("abi");
const fibers = @import("../value/fibers.zig");

/// `config.ev`. Three parts of the traversal are
/// inside `#ifdef JANET_EV` in the C original, and one of them reaches a
/// `janet_vm` field that only exists in that configuration, so this has to
/// gate compilation rather than merely behaviour.
const has_ev = constants.JANET_VM_HAS_EV != 0;

const mem_reachable: i32 = constants.JANET_MEM_REACHABLE;
const frame_size: i32 = constants.JANET_FRAME_SIZE;

// The recursion guard and the count of roots the current collection began
// with are `Collector` fields -- `gc.zig`'s `depth` and `orig_rootcount`.
// They are thread-local file statics in the C original and in neither
// `janet_vm` nor its collector, but they are per-collection state owned by the
// collector that spends them, and the two functions below reach them through
// it rather than beside it.

// ------------------------------------------------------ the header accessors

/// Every collectable object *has* a `JanetGCObject`, which is what lets these
/// four take any of them. Taking its address says exactly that, where a
/// `@ptrCast` would say the stronger and unchecked thing that the header sits
/// at offset zero.
inline fn gcHeader(mem: anytype) *abi.JanetGCObject {
    return &mem.gc;
}

inline fn gcMark(mem: anytype) void {
    gcHeader(mem).flags |= mem_reachable;
}

inline fn gcReachable(mem: anytype) bool {
    return (gcHeader(mem).flags & mem_reachable) != 0;
}

inline fn gcType(mem: anytype) gc_alloc.MemoryType {
    return gc_alloc.memoryTypeOf(gcHeader(mem));
}

// ------------------------------------------------------------ the walk helpers

/// A function's `i`th captured environment. They follow the header immediately,
/// as the allocator lays them out.
inline fn funcEnv(func: *functions.Function, i: usize) *functions.FuncEnv {
    return functions.envsOf(func)[i].?;
}

/// `data + index` for a fiber's stack.
///
/// **The index is never negative here**, and the assertion is what says so
/// rather than arithmetic that accommodates one. The frame layout makes every
/// quantity in the walk non-negative -- `funcframe` leaves `stackstart =
/// frame + slotcount + frame_size`, so `j - i` is `slotcount` -- and the only
/// way to build a fiber that breaks it is unmarshalling, which validates
/// `frame + frame_size <= stackstart <= stacktop <= maxstack` before the
/// collector can ever see one.
///
/// This reproduced C's wild pointer until 2026-08-31; `FOUND.md`'s "The
/// collector's frame walk forms a wild pointer rather than checking" records
/// what it was and why it went.
inline fn stackAt(data: [*]repr.Value, index: i32) [*]repr.Value {
    std.debug.assert(index >= 0);
    return data + @as(usize, @intCast(index));
}

// ------------------------------------------------------------------- mark

/// Mark a value as reachable, along with everything it refers to.
///
/// The guard is the whole shape of this function. Every recursive marker
/// re-enters here, so decrementing on the way in and restoring on the way out
/// bounds the C stack the traversal can consume. When the budget is exhausted
/// the value is *rooted* instead of traversed, and `janet_collect`'s second
/// loop drains those roots and marks them from a fresh budget — so a graph
/// deeper than `JANET_RECURSION_GUARD` is marked completely, in slices, rather
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

fn markString(str: [*]const u8) void {
    gcMark(strings.head(str));
}

fn markBuffer(buffer: *buffers.Buffer) void {
    gcMark(buffer);
}

/// Mark an abstract, and hand control to its `gcmark` callback if it has one.
///
/// A threaded abstract is not marked at all: it is recorded in
/// `threaded_abstracts` instead, and the sweep uses that table to decide which
/// references this interpreter still holds. The bookkeeping is a table write,
/// which can allocate, so this is one of the few places in the walk that can
/// fail — and the only place it can fail before anything has been marked.
fn markAbstract(adata: ?*anyopaque) void {
    const head = abi.abstractHead(adata);
    if (has_ev) {
        if (gc_alloc.memoryTypeOf(&head.gc) == .threaded_abstract) {
            tables.put(&vm_state.current().ev.threaded_abstracts, wrap.fromAbstract(adata), wrap.fromTrue());
            return;
        }
    }
    if (gcReachable(head)) return;
    gcMark(head);
    // A `gcmark` cannot raise, and the type says so: the collector has
    // nowhere to deliver one to. `abstract_type.zig` has the contract.
    if (head.type.gcmark) |gcmark| {
        _ = gcmark(adata, head.size);
    }
}

/// The run of `n` items at `p`, or nothing.
///
/// **Two things a slice cannot hold, and this is where they are held.** A null
/// pointer with a count that still says otherwise is a partially constructed
/// array or a detached environment, and the C original's null test is what
/// stops the walk there; `p.?[0..n]` would trap on exactly that case. And a
/// *negative* count reaches this from a malformed fiber, where the mark walk
/// subtracts `JANET_FRAME_SIZE` from a frame address -- C's `while (i < n)`
/// runs zero times and `@intCast` would trap. Both were implied by the loop
/// condition and are stated here instead.
inline fn run(comptime T: type, p: ?[*]const T, n: i32) []const T {
    if (n <= 0) return &.{};
    const items = p orelse return &.{};
    return items[0..@intCast(n)];
}

fn markMany(values: []const repr.Value) void {
    for (values) |x| mark(x);
}

fn markKeys(kvs: []const tables.KV) void {
    for (kvs) |kv| mark(kv.key);
}

fn markValues(kvs: []const tables.KV) void {
    for (kvs) |kv| mark(kv.value);
}

fn markKvs(kvs: []const tables.KV) void {
    for (kvs) |kv| {
        mark(kv.key);
        mark(kv.value);
    }
}

/// A weak array is marked but not traversed: the elements are exactly what a
/// weak array does not keep alive, and the sweep nils out whichever of them the
/// rest of the heap did not reach. The type test is the whole difference
/// between the two array kinds during marking.
fn markArray(array: *arrays.Array) void {
    if (gcReachable(array)) return;
    gcMark(array);
    if (gcType(array) == gc_alloc.MemoryType.array) {
        markMany(run(repr.Value, array.data, @intCast(array.count)));
    }
}

/// Mark a table and its prototype chain, following the chain iteratively as
/// the C original does — a long chain of prototypes must not cost a C frame
/// each, and marking a prototype is not a recursive step in the guard's budget.
///
/// Which half of each entry is traversed is what makes a table weak: a
/// weak-keyed table keeps its values alive, a weak-valued table keeps its keys,
/// and a table weak in both keeps neither. The fourth case is the one with no
/// branch of its own.
fn markTable(table_in: *tables.Table) void {
    var table = table_in;
    while (true) {
        if (gcReachable(table)) return;
        gcMark(table);
        const memtype = gcType(table);
        if (memtype == gc_alloc.MemoryType.table_weakk) {
            markValues(run(tables.KV, table.data, @intCast(table.capacity)));
        } else if (memtype == gc_alloc.MemoryType.table_weakv) {
            markKeys(run(tables.KV, table.data, @intCast(table.capacity)));
        } else if (memtype == gc_alloc.MemoryType.table) {
            markKvs(run(tables.KV, table.data, @intCast(table.capacity)));
        }
        // Nothing for JANET_MEMORY_TABLE_WEAKKV.
        if (table.proto) |proto| {
            table = proto;
            continue;
        }
        return;
    }
}

fn markStruct(st_in: [*]const tables.KV) void {
    var st = st_in;
    while (true) {
        const head = structs.head(st);
        if (gcReachable(head)) return;
        gcMark(head);
        markKvs(run(tables.KV, st, head.capacity));
        st = head.proto orelse return;
    }
}

fn markTuple(tuple: [*]const repr.Value) void {
    const head = tuples.head(tuple);
    if (gcReachable(head)) return;
    gcMark(head);
    markMany(run(repr.Value, tuple, head.length));
}

/// Mark a function environment, detaching it from a dead fiber first if it can
/// be. The detach is not an optimisation the collector could skip: an
/// environment that still points at a dead fiber would keep the whole fiber —
/// stack included — alive through the mark below.
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

fn markFuncdef(def: *functions.FuncDef) void {
    if (gcReachable(def)) return;
    gcMark(def);
    markMany(run(repr.Value, def.constants, @intCast(def.constants_length)));
    var i: usize = 0;
    while (i < def.defs_length) : (i += 1) {
        markFuncdef(def.subdefs()[i]);
    }
    if (def.source) |source| markString(source);
    if (def.name) |name| markString(name);
    if (def.symbolmap != null) {
        var j: usize = 0;
        while (j < def.symbolmap_length) : (j += 1) {
            markString(def.symbols()[j].symbol.?);
        }
    }
}

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

/// Mark a fiber: its last value, the arguments above the top frame, every
/// frame's function, environment and locals, its dynamic bindings, and — under
/// the event loop — whatever it is waiting on.
///
/// The frame walk goes down the `prevframe` chain rather than up the stack,
/// because the region belonging to a frame is bounded by where the *next* one
/// starts, and that is only known once it has been seen. `j` carries that
/// boundary from one iteration to the next.
///
/// The child chain is followed iteratively for the same reason the prototype
/// chain is: a long chain of resumed fibers would otherwise cost a C frame per
/// link, on top of the frames the fiber's own contents already need.
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
                markAbstract(fiber.supervisor_channel);
            }
            if (fiber.ev_stream != null) {
                markAbstract(fiber.ev_stream);
            }
            if (fiber.ev_callback) |callback| {
                ev_callback.dispatchTotal(ev_callback.of(callback), fiber, constants.JANET_ASYNC_EVENT_MARK);
            }
        }

        if (fiber.child) |child| {
            fiber = child;
            continue;
        }
        return;
    }
}

// ---------------------------------------------------------------- collect

/// Run a full collection: mark from every root, then sweep.
///
/// Two things about the root loops are contracts rather than details. The first
/// walks the roots that existed when the collection began; the second *drains*
/// everything added since — including the roots `janet_mark` created when the
/// depth guard ran out, and any a `gcmark` callback added — marking each one and
/// removing it. So a root added during a collection is consumed by that
/// collection, and only roots that predate it survive it.
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
    // O(block_count), so a large heap gets a proportionally larger interval;
    // the products wrap rather than trap, as the C original's do.
    if (g.block_count *% 8 > g.interval) {
        g.interval = g.block_count *% @sizeOf(abi.JanetGCObject);
    }

    g.orig_rootcount = roots.count;

    if (has_ev) ev_loop.evMark();

    // Null outside the interpreter loop, which `janet_collect` may be called from.
    if (v.root_fiber) |root| markFiber(root);

    // The counter is 32-bit while the bound it is compared against is a
    // `usize`; see the note at the head of this file.
    var i: u32 = 0;
    while (i < g.orig_rootcount) : (i +%= 1) {
        mark(roots.at(i).*);
    }
    while (g.orig_rootcount < roots.count) {
        const x = roots.pop();
        mark(x);
    }

    g.mark_phase = false;
    gc_sweep.sweep();
    g.next_collection = 0;
    gc_alloc.freeAllScratch(&v.scratch);
}
