//! The mark phase: the traversal that decides what is reachable, the recursion
//! guard that stops it running off the stack, and `janet_collect`, which drives
//! it. This is the second of the three increments `gc.c` is split into.
//! Allocation and the root set moved in Part 3; sweeping, the weak heap and
//! finalization stay in C until Part 5.
//!
//! **Nothing here frees anything.** The traversal only ever sets one bit —
//! `JANET_MEM_REACHABLE` — in a header it did not allocate and will not
//! release. That is what makes the boundary a clean one: the mark phase reads
//! the object graph and writes one bit per object, and everything else `gc.c`
//! does is on the other side of it.
//!
//! **`janet_collect` belongs to this increment rather than to sweeping**, which
//! is worth stating because the plan originally left it for last. It is the
//! only reader of both thread-locals below, so putting it anywhere else would
//! have needed a bridge to reach them. Here it needs none: everything it calls
//! outward — `janet_sweep`, `janet_free_all_scratch`, `janet_ev_mark` — is
//! already declared for other reasons, so this increment adds no seam at all
//! and Part 5 will not have to unpick one.
//!
//! **The file is jump-transparent**, under the rule SPIKE-8 settled. Two calls
//! here reach code this runtime does not own: an abstract type's `gcmark`, and
//! a root fiber's `ev_callback` with `JANET_ASYNC_EVENT_MARK`. Neither may
//! raise, and if one does the signal jumps straight out through every frame of
//! the walk. Those frames own nothing — no `defer` in this file, checked by
//! `build.zig` — so the jump is mechanically harmless and the damage is exactly
//! what the C original suffers: a half-marked heap, no sweep, and
//! `next_collection` left where it was. `SPIKE-8.md` has the measurements.
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
const abi = @import("abi");
const raise = @import("raise");
const abstract_type = @import("abstract_type.zig");
const c = abi.c;
const ev_callback = @import("ev_callback.zig");

/// `janet_vm` as `src/core/state.h` declares it, resolved through `abi.zig`.
inline fn vm() *c.JanetVM {
    return &c.janet_vm;
}

/// `JANET_VM_HAS_EV` in `src/zig/state_abi.h`. Three parts of the traversal are
/// inside `#ifdef JANET_EV` in the C original, and one of them reaches a
/// `janet_vm` field that only exists in that configuration, so this has to
/// gate compilation rather than merely behaviour.
const has_ev = c.JANET_VM_HAS_EV != 0;

/// `janet_ev_mark` is declared in `src/core/util.h`, which `abi.zig`
/// deliberately does not translate. It takes no parameters, so no Janet type
/// crosses and the single-translation rule is not at stake — the case the
/// comment in `abi.zig` describes.
extern fn janet_ev_mark() callconv(.c) void;

const mem_reachable: i32 = c.JANET_MEM_REACHABLE;
const mem_typebits: i32 = c.JANET_MEM_TYPEBITS;
const frame_size: i32 = c.JANET_FRAME_SIZE;

/// The recursion guard, and the count of roots that existed when the current
/// collection began. Both are thread-local in the C original and neither is in
/// `janet_vm`; they move here together because `janet_mark` and
/// `janet_collect` are their only readers and both are in this file.
threadlocal var depth: u32 = c.JANET_RECURSION_GUARD;
threadlocal var orig_rootcount: usize = 0;

// ------------------------------------------------------------ gc.h macros

/// `janet_gc_header`, `janet_gc_mark`, `janet_gc_reachable` and
/// `janet_gc_type` from `src/core/gc.h`, which translate-c does not surface
/// because they are function-like. Every collectable object begins with its
/// `JanetGCObject`, which is what lets all four take any of them.
inline fn gcHeader(mem: anytype) *c.JanetGCObject {
    return @ptrCast(@alignCast(mem));
}

inline fn gcMark(mem: anytype) void {
    gcHeader(mem).flags |= mem_reachable;
}

inline fn gcReachable(mem: anytype) bool {
    return (gcHeader(mem).flags & mem_reachable) != 0;
}

inline fn gcType(mem: anytype) i32 {
    return gcHeader(mem).flags & 0xFF;
}

// --------------------------------------------------------- janet.h macros

/// `janet_string_head`, `janet_tuple_head`, `janet_struct_head` and
/// `janet_abstract_head`, plus the indexing of `JanetFunction`'s environment
/// array. All five recover a header, or a slot after one, from the pointer the
/// runtime hands out.
///
/// The C macros subtract `offsetof(Head, data)`, and Zig cannot: **translate-c
/// drops flexible array members entirely**, so `@offsetOf(JanetStringHead,
/// "data")` does not compile. `@sizeOf` is used instead, which is the same
/// number precisely when the flexible array needs no padding after the last
/// declared field — true for all five here, on both 32- and 64-bit layouts,
/// because each header ends on a field at least as aligned as the array
/// element. That is an assumption about C layout rather than about this file,
/// so it is not asserted here: `test/abi.c` compares `sizeof` against
/// `offsetof` for each of the five, in C, where `offsetof` exists.
/// `test/gc_mark.zig` asks the complementary question from this side, deriving
/// each offset from the address the allocator recorded. Part 3 has the same
/// assumption for `JanetScratch` and records it the same way.
inline fn stringHead(s: [*c]const u8) *c.JanetStringHead {
    return @ptrFromInt(@intFromPtr(s) -% @sizeOf(c.JanetStringHead));
}

inline fn tupleHead(t: [*c]const c.Janet) *c.JanetTupleHead {
    return @ptrFromInt(@intFromPtr(t) -% @sizeOf(c.JanetTupleHead));
}

inline fn structHead(st: [*c]const c.JanetKV) *c.JanetStructHead {
    return @ptrFromInt(@intFromPtr(st) -% @sizeOf(c.JanetStructHead));
}

inline fn abstractHead(a: ?*anyopaque) *c.JanetAbstractHead {
    return @ptrFromInt(@intFromPtr(a) -% @sizeOf(c.JanetAbstractHead));
}

/// `func->envs[i]`. The environments follow the header immediately, as
/// `janet_function` allocates them.
inline fn funcEnv(func: [*c]c.JanetFunction, i: i32) [*c]c.JanetFuncEnv {
    const base = @intFromPtr(func) +% @sizeOf(c.JanetFunction);
    const slot: *[*c]c.JanetFuncEnv = @ptrFromInt(base +% @as(usize, @intCast(i)) *% @sizeOf(*c.JanetFuncEnv));
    return slot.*;
}

/// `data + index` for a fiber's stack, reproducing C pointer arithmetic for a
/// signed index. The mark walk computes frame addresses by subtracting
/// `JANET_FRAME_SIZE`, so an index may be negative on a malformed fiber; C
/// forms the wild pointer and only faults if it is dereferenced, and this does
/// the same rather than trapping earlier than the original would.
inline fn stackAt(data: [*c]c.Janet, index: i32) [*c]c.Janet {
    const offset: usize = @bitCast(@as(isize, index) *% @as(isize, @sizeOf(c.Janet)));
    return @ptrFromInt(@intFromPtr(data) +% offset);
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
export fn janet_mark(x: c.Janet) callconv(.c) void {
    if (depth != 0) {
        depth -= 1;
        switch (c.janet_type(x)) {
            c.JANET_STRING, c.JANET_KEYWORD, c.JANET_SYMBOL => markString(c.janet_unwrap_string(x)),
            c.JANET_FUNCTION => markFunction(c.janet_unwrap_function(x)),
            c.JANET_ARRAY => markArray(c.janet_unwrap_array(x)),
            c.JANET_TABLE => markTable(c.janet_unwrap_table(x)),
            c.JANET_STRUCT => markStruct(c.janet_unwrap_struct(x)),
            c.JANET_TUPLE => markTuple(c.janet_unwrap_tuple(x)),
            c.JANET_BUFFER => markBuffer(c.janet_unwrap_buffer(x)),
            c.JANET_FIBER => markFiber(c.janet_unwrap_fiber(x)),
            c.JANET_ABSTRACT => markAbstract(c.janet_unwrap_abstract(x)),
            else => {},
        }
        depth += 1;
    } else {
        c.janet_gcroot(x);
    }
}

fn markString(str: [*c]const u8) void {
    gcMark(stringHead(str));
}

fn markBuffer(buffer: [*c]c.JanetBuffer) void {
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
    const head = abstractHead(adata);
    if (has_ev) {
        if ((head.gc.flags & mem_typebits) == c.JANET_MEMORY_THREADED_ABSTRACT) {
            c.janet_table_put(&vm().threaded_abstracts, c.janet_wrap_abstract(adata), c.janet_wrap_true());
            return;
        }
    }
    if (gcReachable(head)) return;
    gcMark(head);
    // A `gcmark` cannot raise, and the type says so. It ran through rule
    // 11's jump for one part of the hinge, which is how it became clear that
    // the collector had nowhere to deliver one to; `abstract_type.zig` has
    // the contract.
    if (abstract_type.of(head.type).gcmark) |gcmark| {
        _ = gcmark(adata, head.size);
    }
}

/// Mark `n` values. The null test is the C original's, and it is load-bearing:
/// a partially constructed array or a detached environment can have a null
/// data pointer while its count still says otherwise.
fn markMany(values: [*c]const c.Janet, n: i32) void {
    if (values == null) return;
    var i: i32 = 0;
    while (i < n) : (i += 1) {
        janet_mark(values[@intCast(i)]);
    }
}

fn markKeys(kvs: [*c]const c.JanetKV, n: i32) void {
    var i: i32 = 0;
    while (i < n) : (i += 1) {
        janet_mark(kvs[@intCast(i)].key);
    }
}

fn markValues(kvs: [*c]const c.JanetKV, n: i32) void {
    var i: i32 = 0;
    while (i < n) : (i += 1) {
        janet_mark(kvs[@intCast(i)].value);
    }
}

fn markKvs(kvs: [*c]const c.JanetKV, n: i32) void {
    var i: i32 = 0;
    while (i < n) : (i += 1) {
        janet_mark(kvs[@intCast(i)].key);
        janet_mark(kvs[@intCast(i)].value);
    }
}

/// A weak array is marked but not traversed: the elements are exactly what a
/// weak array does not keep alive, and the sweep nils out whichever of them the
/// rest of the heap did not reach. The type test is the whole difference
/// between the two array kinds during marking.
fn markArray(array: [*c]c.JanetArray) void {
    if (gcReachable(array)) return;
    gcMark(array);
    if (gcType(array) == c.JANET_MEMORY_ARRAY) {
        markMany(array.*.data, array.*.count);
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
fn markTable(table_in: [*c]c.JanetTable) void {
    var table = table_in;
    while (true) {
        if (gcReachable(table)) return;
        gcMark(table);
        const memtype = gcType(table);
        if (memtype == c.JANET_MEMORY_TABLE_WEAKK) {
            markValues(table.*.data, table.*.capacity);
        } else if (memtype == c.JANET_MEMORY_TABLE_WEAKV) {
            markKeys(table.*.data, table.*.capacity);
        } else if (memtype == c.JANET_MEMORY_TABLE) {
            markKvs(table.*.data, table.*.capacity);
        }
        // Nothing for JANET_MEMORY_TABLE_WEAKKV.
        if (table.*.proto != null) {
            table = table.*.proto;
            continue;
        }
        return;
    }
}

fn markStruct(st_in: [*c]const c.JanetKV) void {
    var st = st_in;
    while (true) {
        const head = structHead(st);
        if (gcReachable(head)) return;
        gcMark(head);
        markKvs(st, head.capacity);
        st = head.proto;
        if (st == null) return;
    }
}

fn markTuple(tuple: [*c]const c.Janet) void {
    const head = tupleHead(tuple);
    if (gcReachable(head)) return;
    gcMark(head);
    markMany(tuple, head.length);
}

/// Mark a function environment, detaching it from a dead fiber first if it can
/// be. The detach is not an optimisation the collector could skip: an
/// environment that still points at a dead fiber would keep the whole fiber —
/// stack included — alive through the mark below.
fn markFuncenv(env: [*c]c.JanetFuncEnv) void {
    if (gcReachable(env)) return;
    gcMark(env);
    c.janet_env_maybe_detach(env);
    if (env.*.offset > 0) {
        markFiber(env.*.as.fiber);
    } else {
        markMany(env.*.as.values, env.*.length);
    }
}

fn markFuncdef(def: [*c]c.JanetFuncDef) void {
    if (gcReachable(def)) return;
    gcMark(def);
    markMany(def.*.constants, def.*.constants_length);
    var i: i32 = 0;
    while (i < def.*.defs_length) : (i += 1) {
        markFuncdef(def.*.defs[@intCast(i)]);
    }
    if (def.*.source != null) markString(def.*.source);
    if (def.*.name != null) markString(def.*.name);
    if (def.*.symbolmap != null) {
        var j: i32 = 0;
        while (j < def.*.symbolmap_length) : (j += 1) {
            markString(def.*.symbolmap[@intCast(j)].symbol);
        }
    }
}

/// The null test on `def` is not defensive: a function is allocated, marked
/// reachable, and only then given its definition, so a collection triggered
/// between those two steps sees exactly this state.
fn markFunction(func: [*c]c.JanetFunction) void {
    if (gcReachable(func)) return;
    gcMark(func);
    if (func.*.def != null) {
        const numenvs = func.*.def.*.environments_length;
        var i: i32 = 0;
        while (i < numenvs) : (i += 1) {
            markFuncenv(funcEnv(func, i));
        }
        markFuncdef(func.*.def);
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
fn markFiber(fiber_in: [*c]c.JanetFiber) void {
    var fiber = fiber_in;
    while (true) {
        if (gcReachable(fiber)) return;
        gcMark(fiber);

        janet_mark(fiber.*.last_value);

        // Values on the argument stack.
        markMany(stackAt(fiber.*.data, fiber.*.stackstart), fiber.*.stacktop -% fiber.*.stackstart);

        var i = fiber.*.frame;
        var j = fiber.*.stackstart -% frame_size;
        while (i > 0) {
            const frame: *c.JanetStackFrame = @ptrCast(@alignCast(stackAt(fiber.*.data, i -% frame_size)));
            if (frame.func != null) markFunction(frame.func);
            if (frame.env != null) markFuncenv(frame.env);
            // Locals of this frame, up to where the frame above it starts.
            markMany(stackAt(fiber.*.data, i), j -% i);
            j = i -% frame_size;
            i = frame.prevframe;
        }

        if (fiber.*.env != null) markTable(fiber.*.env);

        if (has_ev) {
            if (fiber.*.supervisor_channel != null) {
                markAbstract(fiber.*.supervisor_channel);
            }
            if (fiber.*.ev_stream != null) {
                markAbstract(fiber.*.ev_stream);
            }
            if (fiber.*.ev_callback) |callback| {
                ev_callback.dispatchTotal(ev_callback.of(callback), fiber, c.JANET_ASYNC_EVENT_MARK);
            }
        }

        if (fiber.*.child != null) {
            fiber = fiber.*.child;
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
export fn janet_collect() callconv(.c) void {
    const v = vm();
    if (v.gc_suspend != 0) return;
    depth = c.JANET_RECURSION_GUARD;
    v.gc_mark_phase = 1;

    // Prevent many major collections back to back. A full collection is
    // O(block_count), so a large heap gets a proportionally larger interval;
    // the products wrap rather than trap, as the C original's do.
    if (v.block_count *% 8 > v.gc_interval) {
        v.gc_interval = v.block_count *% @sizeOf(c.JanetGCObject);
    }

    orig_rootcount = v.root_count;

    if (has_ev) janet_ev_mark();

    // Null outside the interpreter loop, which `janet_collect` may be called from.
    if (v.root_fiber != null) markFiber(v.root_fiber);

    // The counter is 32-bit in the C original while the bound it is compared
    // against is a `size_t`; see the note at the head of this file.
    var i: u32 = 0;
    while (i < orig_rootcount) : (i +%= 1) {
        janet_mark(v.roots[i]);
    }
    while (orig_rootcount < v.root_count) {
        v.root_count -= 1;
        const x = v.roots[v.root_count];
        janet_mark(x);
    }

    v.gc_mark_phase = 0;
    c.janet_sweep();
    v.next_collection = 0;
    c.janet_free_all_scratch();
}
