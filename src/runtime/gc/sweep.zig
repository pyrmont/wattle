//! Sweeping: the pass that acts on the mark phase's decision. Dropping dead
//! weak references, unlinking and freeing unreachable blocks, running
//! finalizers, and tearing the heap down at VM shutdown.
//!
//! `sweep` and `clearMemory` are the file's surface, and every other
//! declaration here is private. `gc/mark.zig`'s `collect` calls `sweep` at the
//! end of a collection; `vm/lifecycle.zig` calls `clearMemory` at shutdown.
//!
//! Everything here frees and nothing here traverses. That is the mirror of the
//! mark phase's boundary and what makes the split work: the mark reads the
//! object graph and writes one bit per object, and this file reads that bit
//! and never follows a pointer the bit does not justify. The one place the two
//! touch is `checkLiveref`, which reads the mark of a value the weak heap
//! refers to. That is a read rather than a walk, and it is the reason a weak
//! reference is dropped in the sweep rather than skipped in the walk.
//!
//! ## Nothing here is stranded by a raise
//!
//! `deinitBlock` runs an abstract type's `gc` and `gcperthread` finalizers,
//! and `sweepThreadedAbstracts` runs `gcperthread` again. All three are
//! third-party code, and `abi.zig` declares both slots `callconv(.c) void`, so
//! none has a way to raise. The frames a raise would cross own nothing in any
//! case, and what one would cost is bounded: `deinitBlock` runs before the
//! unlink, so the block stays on its list and every later collection finalizes
//! it again.
//!
//! ## Teardown walks both heaps
//!
//! Freeing the main heap and leaving `vm.gc.weak_blocks` alone leaks a block
//! and a data array for every weak table and weak array alive at teardown, and
//! then nulls the list head, dropping the last pointer to them.
//! `clearMemory` walks both lists with one body, and `test/gc_sweep.zig` pins
//! that both come back empty.

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const abstracts = @import("../value/abstracts.zig");
const arrays = @import("../value/arrays.zig");
const buffers = @import("../value/buffers.zig");
const constants = @import("constants");
const ev = @import("../ev.zig");
const fibers = @import("../value/fibers.zig");
const functions = @import("../value/functions.zig");
const gc_alloc = @import("../gc.zig");
const repr = @import("repr");
const strings = @import("../value/strings.zig");
const symbols = @import("../value/symbols.zig");
const tables = @import("../value/tables.zig");
const tuples = @import("../value/tuples.zig");
const utils = @import("../utils.zig");
const vm_state = @import("../vm/state.zig");
const wrap = @import("../value/helpers/wrap.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// Whether this build has the event loop. Three regions here reach
/// `vm.ev.threaded_abstracts`, a field that exists only in that configuration,
/// so this gates compilation and not merely behaviour.
const has_ev = constants.vm_has_ev != 0;

// ==========================================================================
// Public functions
// ==========================================================================

/// Frees the whole heap, at VM shutdown.
///
/// This is not a collection: nothing is marked, no block is spared, and the
/// list is not unlinked as it goes. Every finalizer runs, in heap order, which
/// is allocation order reversed.
pub fn clearMemory() void {
    // Teardown reaches three aggregates and each is named: the scheduler's
    // threaded-abstract table, the main heap, and the scratch table. A
    // function this broad should name them rather than take one `v` and index
    // into it.
    const v = vm_state.current();
    const g = &v.gc;

    if (has_ev) {
        // The scheduler's visit record, which is the only part of `VmEv` the
        // collector touches. The binding is inside the guard because `VmEv` is
        // an empty `struct` without an event loop, and naming a field of it
        // above the `if` is a reference a `-Dev=false` build cannot resolve.
        const threaded = &v.ev.threaded_abstracts;
        // Every threaded abstract this interpreter still refers to loses that
        // reference, whether or not anything else still refers to it.
        const items = threaded.data;
        for (0..threaded.capacity) |i| {
            const kv = &items.?[i];
            if (repr.checkType(kv.key, repr.Tag.abstract)) {
                const abst = wrap.toAbstract(kv.key);
                const head = abi.abstractHead(abst);
                if (head.type.gcperthread) |gcperthread| {
                    gcperthread(abstracts.data(head), head.size);
                }
                _ = abstracts.decrefMaybeFree(abst);
            }
        }
    }

    // Both heaps, with one body. Walking `blocks` and not `weak_blocks` leaks
    // the block and the `data` array for every weak table and weak array still
    // allocated at teardown, and the list head is nulled next, which drops the
    // last pointer to them and makes the memory unrecoverable rather than
    // merely retained.
    //
    // Nothing a running program observes moves: the weak heap is reached only
    // at teardown, and everything on it is unreachable by then by
    // construction.
    for ([_]*?*abi.GCObject{ &g.blocks, &g.weak_blocks }) |head| {
        var current = head.*;
        while (current) |block| {
            deinitBlock(block);
            const next = block.data.next;
            utils.free(@ptrCast(block));
            current = next;
        }
        head.* = null;
    }

    // The scratch table, whose pointer and capacity go together for the reason
    // `gc.scratchDeinit` gives: freeing the storage and leaving the list's
    // pointer dangling with its capacity at the old value lets an `smalloc`
    // before the next VM write through the freed pointer. It is heap
    // corruption that only glibc's allocator hardening detects.
    //
    // Clearing here makes that path correct rather than loud: the next
    // `smalloc` finds an empty list, takes the growth path, and allocates a
    // fresh table rather than trapping. So it removes the corruption without
    // diagnosing the caller, and the contract that calls in after shutdown is
    // what catches the mistake.
    gc_alloc.scratchDeinit(&v.scratch);
}

/// Frees everything the mark phase did not reach, and drops the weak
/// references to it.
///
/// The weak heap is swept twice, and the order matters. A dead weak reference
/// has to be nilled out while the object it names is still allocated, because
/// the test is a read of that object's header; freeing first would leave the
/// second pass reading freed memory. So the first pass reads every surviving
/// weak container and the second frees, and no pass does both.
pub fn sweep() void {
    const g = &vm_state.current().gc;

    // Sweep the weak heap to drop weak refs.
    var current = g.weak_blocks;
    while (current) |block| {
        const next = block.data.next;
        if (retained(block.flags)) {
            const memtype = gcType(block);
            if (memtype == .array_weak) {
                dropDeadElements(@alignCast(@fieldParentPtr("gc", block)));
            } else {
                dropDeadEntries(@alignCast(@fieldParentPtr("gc", block)), memtype);
            }
        }
        current = next;
    }

    // Sweep the weak heap to free blocks, then the main heap.
    freeUnreachable(&g.weak_blocks);
    freeUnreachable(&g.blocks);

    if (has_ev) sweepThreadedAbstracts();
}

// ==========================================================================
// Private functions
// ==========================================================================

/// Whether a value the weak heap refers to was reached by the mark phase.
///
/// Only a collectable type can be false. The immediates and the two number
/// types have no header to consult and are always live, which is what the
/// default arm means: a weak table keyed by integers never drops an entry.
fn checkLiveref(x: repr.Value) bool {
    return switch (repr.typeOf(x)) {
        repr.Tag.array,
        repr.Tag.table,
        repr.Tag.function,
        repr.Tag.buffer,
        repr.Tag.fiber,
        => gcReachable(wrap.toPointer(x)),
        repr.Tag.string, repr.Tag.symbol => gcReachable(strings.head(wrap.toString(x))),
        repr.Tag.abstract => gcReachable(abi.abstractHead(wrap.toAbstract(x))),
        repr.Tag.tuple => gcReachable(tuples.head(wrap.toTuple(x))),
        repr.Tag.map, repr.Tag.vector => gcReachable(wrap.toPointer(x)),
        else => true,
    };
}

/// Releases everything a block owns outside its own allocation, without
/// freeing the block itself.
///
/// Every arm reaches its heap type with `@fieldParentPtr("gc", mem)`, which
/// computes the offset and so works at whatever the layout turns out to be.
/// A `@ptrCast` would be correct only while `gc` sits at offset zero.
///
/// The `@alignCast` beside it is load-bearing on 32-bit only. There the offset
/// `gc` sits at proves no more than two-byte alignment for the parent, while a
/// heap type with a pointer or an `f64` in it needs more, so recovering the
/// parent raises the alignment and Zig will not do that silently. The
/// assertion is sound because every block on this list was allocated by
/// `gcalloc` for its own type and already has that type's alignment. On a
/// 64-bit target it compiles to nothing, so the 32-bit cross-builds are the
/// only thing that exercises it.
///
/// Both callers free the block immediately afterwards. They are separate steps
/// because the sweep has to unlink it in between.
///
/// The types with no case are not an omission. A string, keyword, tuple,
/// struct, function, vector or collection node stores its payload inside the same
/// allocation, so freeing the block frees the payload. A collection node's
/// children are blocks of their own, which the sweep frees when they are
/// unreachable. A symbol is the one immutable type
/// with an external obligation, because it has to leave the symbol cache.
fn deinitBlock(mem: *abi.GCObject) void {
    switch (gc_alloc.memoryTypeOf(mem)) {
        gc_alloc.MemoryType.symbol => symbols.deinit(stringData(mem)),

        gc_alloc.MemoryType.array, gc_alloc.MemoryType.array_weak => {
            const array: *arrays.Array = @alignCast(@fieldParentPtr("gc", mem));
            utils.free(@ptrCast(array.data));
        },

        gc_alloc.MemoryType.table,
        gc_alloc.MemoryType.table_weakk,
        gc_alloc.MemoryType.table_weakv,
        gc_alloc.MemoryType.table_weakkv,
        => {
            const table: *tables.Table = @alignCast(@fieldParentPtr("gc", mem));
            utils.free(@ptrCast(table.data));
        },

        gc_alloc.MemoryType.fiber => {
            const f: *fibers.Fiber = @alignCast(@fieldParentPtr("gc", mem));
            if (has_ev) {
                // No event-loop allocation is freed here. An operation is
                // owned by the stream's list and released by `ev.zig`'s
                // `asyncRelease`, and a fiber with one is traced from that
                // list, so a fiber reaching this sweep has none. The
                // suspended bit is the GC header's and is the one reference
                // this fiber still holds.
                if (fibers.evFlags(f).suspended) ev.evDecRefcount();
            }
            utils.free(@ptrCast(f.data));
        },

        gc_alloc.MemoryType.buffer => buffers.deinit(@alignCast(@fieldParentPtr("gc", mem))),

        gc_alloc.MemoryType.abstract => {
            const head: *abi.AbstractHead = @alignCast(@fieldParentPtr("gc", mem));
            if (head.type.gcperthread) |gcperthread| {
                gcperthread(abstracts.data(head), head.size);
            }
            if (head.type.gc) |gc| {
                // A finalizer has no way to raise: `abi.zig` declares the slot
                // `callconv(.c) void` and `api/abstract_type.zig` states the
                // contract. It returns `void`, so a finalizer that fails
                // cannot say so and nothing here could act on it.
                gc(abstracts.data(head), head.size);
            }
        },

        gc_alloc.MemoryType.funcenv => {
            const env: *functions.FuncEnv = @alignCast(@fieldParentPtr("gc", mem));
            // A non-zero offset means the values are still on a fiber's stack
            // and belong to the fiber, not to this environment.
            if (env.offset == 0) utils.free(@ptrCast(env.as.values));
        },

        gc_alloc.MemoryType.funcdef => {
            const def: *functions.FuncDef = @alignCast(@fieldParentPtr("gc", mem));
            utils.free(@ptrCast(def.defs));
            utils.free(@ptrCast(def.environments));
            utils.free(@ptrCast(def.constants));
            utils.free(@ptrCast(def.bytecode));
            utils.free(@ptrCast(def.sourcemap));
            utils.free(@ptrCast(def.closure_bitset));
            utils.free(@ptrCast(def.symbolmap));
        },

        // Listed rather than reached through an `else`, which is what
        // makes a new memory type a compile error here rather than a silent
        // no-op: a collectable whose deinitialisation was forgotten leaks
        // whatever it owns, and nothing else would say so.
        gc_alloc.MemoryType.none,
        gc_alloc.MemoryType.string,
        gc_alloc.MemoryType.tuple,
        gc_alloc.MemoryType.map,
        gc_alloc.MemoryType.function,
        gc_alloc.MemoryType.threaded_abstract,
        gc_alloc.MemoryType.vector,
        gc_alloc.MemoryType.vector_inner,
        gc_alloc.MemoryType.vector_leaf,
        gc_alloc.MemoryType.map_node,
        gc_alloc.MemoryType.set_node,
        => {},
    }
}

/// Nils out the elements of a surviving weak array that nothing else reached.
fn dropDeadElements(array: *arrays.Array) void {
    for (array.slice()) |*element| {
        if (!checkLiveref(element.*)) element.* = wrap.fromNil();
    }
}

/// Removes the entries of a surviving weak table whose weak half died.
///
/// `memtype` selects which half is checked, and that selection is what makes a
/// table weak. It mirrors the mark phase exactly: a weak-keyed table did not
/// mark its keys, so its keys are what may have died. The removal is
/// `tables.remove` with the search skipped, since the entry is already
/// located: the count drops, the deleted count rises, and the slot becomes the
/// nil-key, false-value tombstone that keeps later probes walking past it.
fn dropDeadEntries(table: *tables.Table, memtype: gc_alloc.MemoryType) void {
    const check_values = memtype == .table_weakv or memtype == .table_weakkv;
    const check_keys = memtype == .table_weakk or memtype == .table_weakkv;
    // An index rather than a pointer to `data + capacity`: it covers the same
    // slots at any capacity a table can have, and a capacity is never
    // negative.
    for (0..table.capacity) |i| {
        const kv = &table.slots()[i];
        var drop = false;
        if (check_keys and !checkLiveref(kv.key)) drop = true;
        if (check_values and !checkLiveref(kv.value)) drop = true;
        if (drop) {
            table.count -= 1;
            table.deleted += 1;
            kv.key = wrap.fromNil();
            kv.value = wrap.fromFalse();
        }
    }
}

/// Unlinks and frees every unreachable block on one heap list, clearing the
/// reachable flag on the survivors so the next mark phase starts clean.
///
/// `list` is the head of a heap list, passed by pointer because the head is a
/// `Vm` field and both lists are swept the same way.
///
/// `deinitBlock` runs before the unlink, and that order is what bounds the
/// cost the file header describes.
///
/// The predecessor is re-derived after the finalizer rather than saved before
/// it. A finalizer may allocate, `gcalloc` prepends, and the block being freed
/// may be the head, in which case the head has moved and restoring it from the
/// saved `next` would unlink whatever the finalizer allocated from every list
/// there is. Those blocks are then reachable from nothing: never
/// marked, never swept, never freed at teardown, and still counted.
fn freeUnreachable(list: *?*abi.GCObject) void {
    const g = &vm_state.current().gc;
    var previous: ?*abi.GCObject = null;
    var current = list.*;
    while (current) |block| {
        const next = block.data.next;
        if (retained(block.flags)) {
            previous = current;
            block.flags.reachable = false;
        } else {
            g.block_count -%= 1;
            deinitBlock(block);
            if (previous == null and list.* != current) previous = predecessorOf(list.*, block);
            if (previous) |p| {
                p.data.next = next;
            } else {
                list.* = next;
            }
            utils.free(@ptrCast(current));
        }
        current = next;
    }
}

/// Every collectable object begins with its `GCObject`, which is what lets
/// these three take any of them.
///
/// The header is recovered through the address rather than with `@ptrCast`,
/// because `checkLiveref` reaches here with the `?*anyopaque` a value unwraps
/// to as well as with typed pointers.
inline fn gcHeader(mem: anytype) *abi.GCObject {
    return @ptrFromInt(@intFromPtr(mem));
}

inline fn gcReachable(mem: anytype) bool {
    return gcHeader(mem).flags.reachable;
}

inline fn gcType(mem: *abi.GCObject) gc_alloc.MemoryType {
    return gc_alloc.memoryTypeOf(mem);
}

/// The block whose `next` is `target`, walking from `head`.
///
/// Null when `target` is the head, which is the case the caller has already
/// ruled out. Null for any other reason would mean the list no longer contains
/// the block being freed, and the caller then falls back to moving the head.
fn predecessorOf(head: ?*abi.GCObject, target: *abi.GCObject) ?*abi.GCObject {
    var node = head;
    while (node) |block| : (node = block.data.next) {
        if (block.data.next == target) return block;
    }
    return null;
}

/// The two flags that keep a block through a sweep.
///
/// `disabled` is what an embedder sets on a block the collector would
/// otherwise free, and the sweep never clears it. `reachable` is cleared on
/// every survivor, so the next mark phase starts from a clean heap.
inline fn retained(flags: abi.GCFlags) bool {
    return flags.reachable or flags.disabled;
}

/// The bytes in a string or symbol block. The pointer this takes is a
/// `*GCObject` off the sweep list; see `deinitBlock` for the `@alignCast`.
inline fn stringData(mem: *abi.GCObject) [*:0]const u8 {
    const head: *strings.StringHead = @alignCast(@fieldParentPtr("gc", mem));
    return @ptrCast(strings.data(head));
}

/// Drops this interpreter's reference to every threaded abstract the mark
/// phase did not visit.
///
/// The table is a per-collection visit record rather than a heap.
/// `gc/mark.zig` writes true into it for every threaded abstract it reaches,
/// and this reads the entry and then resets it to false for the next
/// collection. An entry still false is one no live value in this interpreter
/// refers to, so this interpreter's refcount goes with it. The abstract is
/// freed only by whichever interpreter takes the count to zero, which is what
/// makes the finalizer run exactly once.
fn sweepThreadedAbstracts() void {
    const v = vm_state.current();
    // The scheduler's visit record, which is the only part of `VmEv` the
    // collector touches.
    const threaded = &v.ev.threaded_abstracts;
    const items = threaded.data;
    for (0..threaded.capacity) |i| {
        const kv = &items.?[i];
        if (repr.checkType(kv.key, repr.Tag.abstract)) {
            if (!repr.truthy(kv.value)) {
                const abst = wrap.toAbstract(kv.key);
                const head = abi.abstractHead(abst);
                if (head.type.gcperthread) |gcperthread| {
                    gcperthread(abstracts.data(head), head.size);
                }
                _ = abstracts.decrefMaybeFree(abst);

                // Mark as tombstone in place.
                kv.key = wrap.fromNil();
                kv.value = wrap.fromFalse();
                threaded.deleted += 1;
                threaded.count -= 1;
            }

            // Reset for the next sweep. Reached whether or not the entry was
            // just tombstoned, because the type test above ran before the key
            // was replaced.
            kv.value = wrap.fromFalse();
        }
    }
}
