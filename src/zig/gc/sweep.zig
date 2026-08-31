//! Sweeping: the pass that acts on the mark phase's decision. Dropping dead
//! weak references, unlinking and freeing unreachable blocks, running
//! finalizers, and tearing the whole heap down at `janet_deinit`.
//!
//! **Everything here frees, and nothing here traverses.** That is the mirror
//! of the mark phase's boundary and it is what makes the split hold: the mark
//! reads the object graph and writes one bit per object, and this file reads
//! that bit and never follows a pointer the bit does not justify. The one
//! place the two touch is `checkLiveref`, which reads the mark of a value the
//! weak heap refers to — a read, not a walk, and the reason a weak reference
//! is dropped in the sweep rather than skipped in the walk.
//!
//! **There is no seam between the three.** `janet_sweep` and
//! `janet_clear_memory` are public API; `deinitBlock` and `checkLiveref` have
//! no caller outside this file. Everything this file calls outward is either
//! public API or `gc.freeAllScratch`.
//!
//! **Nothing here may hold anything across a raise**, and this is the file
//! that rule was written for. `deinitBlock` calls an abstract type's `gc` and
//! `gcperthread` finalizers, and the threaded-abstract sweep calls
//! `gcperthread` again; all three are third-party code. Neither may
//! frames it crosses own nothing — no `defer` in this file, checked by
//! `build.zig` — so the jump is mechanically harmless and the damage is exactly
//! the C original's, which `SPIKE-8.md` measured: the block is still on its
//! list because `janet_deinit_block` runs *before* the unlink, so every later
//! collection finds it unreachable again and finalizes it again.
//!
//! One defect is reproduced rather than repaired, and it is in `FOUND.md`:
//! `janet_clear_memory` frees the main heap and never touches
//! `vm.gc.weak_blocks`, so every weak table and weak array still alive at
//! `janet_deinit` leaks its block and its data array — 32KB per cycle for a
//! 4096-element weak array, measured and recorded in `FOUND.md`. This file walks
//! the same one list the original does, and `test/gc_sweep.zig` asserts the
//! leak's signature so that whichever side is fixed first says so.

const std = @import("std");
const types = @import("types");
const repr = @import("repr");
const constants = @import("constants");
const vm_state = @import("../vm/lifecycle.zig");
const raise = @import("raise");
const abstract_type = @import("../abstract_type.zig");
const gc_alloc = @import("../gc.zig");
const buffers = @import("../value/buffers.zig");
const utils = @import("../utils.zig");
const wrap = @import("../value/helpers/wrap.zig");
const abstracts = @import("../value/abstracts.zig");
const fatal = @import("../fatal.zig");
const ev = @import("../ev.zig");
const symbols = @import("../value/symbols.zig");

/// `config.ev`. Both exported functions have an
/// `#ifdef JANET_EV` region that reaches `vm.ev.threaded_abstracts`, a field
/// that only exists in that configuration, so this has to gate compilation
/// rather than merely behaviour.
const has_ev = constants.JANET_VM_HAS_EV != 0;

const mem_reachable: i32 = constants.JANET_MEM_REACHABLE;
const mem_disabled: i32 = constants.JANET_MEM_DISABLED;

/// The two flags that keep a block through a sweep. `JANET_MEM_DISABLED` is
/// what an embedder sets to hold a block the collector would otherwise free;
/// it is never cleared by the sweep, where `JANET_MEM_REACHABLE` is cleared on
/// every survivor so the next mark phase starts from a clean heap.
const mem_retained: i32 = mem_reachable | mem_disabled;

// ------------------------------------------------------------ gc.h macros

/// `janet_gc_header`, `janet_gc_reachable` and `janet_gc_type` from
/// `src/core/gc.h`, which translate-c does not surface because they are
/// function-like. Every collectable object begins with its `JanetGCObject`,
/// which is what lets all three take any of them.
///
/// The header is recovered through the address rather than with `@ptrCast`,
/// because `checkLiveref` reaches here with the `?*anyopaque` that
/// `janet_unwrap_pointer` returns as well as with typed pointers.
inline fn gcHeader(mem: anytype) *types.JanetGCObject {
    return @ptrFromInt(@intFromPtr(mem));
}

inline fn gcReachable(mem: anytype) bool {
    return (gcHeader(mem).flags & mem_reachable) != 0;
}

inline fn gcType(mem: *types.JanetGCObject) types.MemoryType {
    return mem.memoryType();
}

// --------------------------------------------------------- janet.h macros

/// `((JanetStringHead *) mem)->data`, the bytes a string or symbol block holds.
/// The block pointer this receives is a `JanetGCObject *` off the sweep list,
/// which is the head's first field, so the cast is the identity `janet.h`'s
/// macro performs implicitly.
inline fn stringData(mem: *types.JanetGCObject) [*:0]const u8 {
    return @ptrCast(types.stringData(@ptrCast(@alignCast(mem))));
}

// ------------------------------------------------------------- finalizing

/// `janet_assert(!callback(...), message)` from `src/core/util.h`. A finalizer
/// that reports failure is not an error to be raised — the C original prints
/// and calls `abort`, which is what `janet_zig_fatal` does.
inline fn assertFinalized(status: c_int, message: [*:0]const u8) void {
    if (status != 0) fatal.fatal(message);
}

/// Release everything a block owns outside its own allocation, without freeing
/// the block itself. Both callers free it immediately afterwards; they are
/// separate steps because `janet_sweep` has to unlink the block in between.
///
/// The types with no case are not an omission. A string, keyword, tuple,
/// struct or function stores its payload inside the same allocation, so
/// freeing the block frees the payload; a symbol is the one immutable type
/// with an external obligation, because it has to leave the symbol cache.
fn deinitBlock(mem: *types.JanetGCObject) void {
    switch (mem.memoryType()) {
        types.MemoryType.symbol => symbols.deinit(stringData(mem)),

        types.MemoryType.array, types.MemoryType.array_weak => {
            const array: *types.JanetArray = @ptrCast(@alignCast(mem));
            utils.free(@ptrCast(array.*.data));
        },

        types.MemoryType.table,
        types.MemoryType.table_weakk,
        types.MemoryType.table_weakv,
        types.MemoryType.table_weakkv,
        => {
            const table: *types.JanetTable = @ptrCast(@alignCast(mem));
            utils.free(@ptrCast(table.*.data));
        },

        types.MemoryType.fiber => {
            const f: *types.JanetFiber = @ptrCast(@alignCast(mem));
            if (has_ev) {
                // The two flags live in different words, and deliberately:
                // `ev.c` keeps `IN_FLIGHT` in the fiber's own flags and
                // `SUSPENDED` in the GC header's, and this reads each where it
                // is written.
                if (f.*.ev_state != null and (f.*.flags & constants.JANET_FIBER_EV_FLAG_IN_FLIGHT) == 0) {
                    ev.evDecRefcount();
                    utils.free(f.*.ev_state);
                } else if ((f.*.gc.flags & constants.JANET_FIBER_EV_FLAG_SUSPENDED) != 0) {
                    ev.evDecRefcount();
                }
            }
            utils.free(@ptrCast(f.*.data));
        },

        types.MemoryType.buffer => buffers.deinit(@ptrCast(@alignCast(mem))),

        types.MemoryType.abstract => {
            const head: *types.JanetAbstractHead = @ptrCast(@alignCast(mem));
            if (head.type.*.gcperthread) |gcperthread| {
                assertFinalized(gcperthread(types.abstractData(head), head.size), "per-thread finalizer failed");
            }
            if (head.type.gc) |gc| {
                // A finalizer cannot raise -- `abstract_type.zig` has the
                // contract, and `FOUND.md`'s "A panicking finalizer poisons
                // the heap and kills the process at deinit" is what allowing
                // it costs. The nonzero return is the failure channel, and
                // this is `janet_assert(!head->type->gc(...))` unchanged.
                assertFinalized(gc(types.abstractData(head), head.size), "finalizer failed");
            }
        },

        types.MemoryType.funcenv => {
            const env: *types.JanetFuncEnv = @ptrCast(@alignCast(mem));
            // A non-zero offset means the values are still on a fiber's stack
            // and belong to the fiber, not to this environment.
            if (env.*.offset == 0) utils.free(@ptrCast(env.*.as.values));
        },

        types.MemoryType.funcdef => {
            const def: *types.JanetFuncDef = @ptrCast(@alignCast(mem));
            utils.free(@ptrCast(def.*.defs));
            utils.free(@ptrCast(def.*.environments));
            utils.free(@ptrCast(def.*.constants));
            utils.free(@ptrCast(def.*.bytecode));
            utils.free(@ptrCast(def.*.sourcemap));
            utils.free(@ptrCast(def.*.closure_bitset));
            utils.free(@ptrCast(def.*.symbolmap));
        },

        // The C original reached these through `default`. Listing them is what
        // makes a new memory type a compile error here rather than a silent
        // no-op: a collectable whose deinitialisation was forgotten leaks
        // whatever it owns, and nothing else would say so.
        types.MemoryType.none,
        types.MemoryType.string,
        types.MemoryType.tuple,
        types.MemoryType.@"struct",
        types.MemoryType.function,
        types.MemoryType.threaded_abstract,
        => {},
    }
}

// ------------------------------------------------------------- weak refs

/// Whether a value the weak heap refers to was reached by the mark phase.
///
/// Only collectable types can answer no. The immediates and the two number
/// types have no header to consult and are always live, which is what the
/// default arm means — a weak table keyed by integers never drops an entry.
fn checkLiveref(x: repr.Value) bool {
    return switch (repr.typeOf(x)) {
        repr.Tag.array,
        repr.Tag.table,
        repr.Tag.function,
        repr.Tag.buffer,
        repr.Tag.fiber,
        => gcReachable(wrap.toPointer(x)),
        repr.Tag.string, repr.Tag.symbol, repr.Tag.keyword => gcReachable(types.stringHead(wrap.toString(x))),
        repr.Tag.abstract => gcReachable(types.abstractHead(wrap.toAbstract(x))),
        repr.Tag.tuple => gcReachable(types.tupleHead(wrap.toTuple(x))),
        repr.Tag.@"struct" => gcReachable(types.structHead(wrap.toStruct(x))),
        else => true,
    };
}

/// Nil out the elements of a surviving weak array that nothing else reached.
fn dropDeadElements(array: *types.JanetArray) void {
    // The C original counts with a `uint32_t` against `(uint32_t) array->count`,
    // and the cast is kept rather than dropped: a negative count is not
    // reachable through the API, but if one ever were, dropping the cast would
    // change which memory the loop touches rather than merely where it stops.
    var i: u32 = 0;
    const count: u32 = @bitCast(array.*.count);
    while (i < count) : (i += 1) {
        if (!checkLiveref(array.*.slice()[i])) {
            array.*.slice()[i] = wrap.fromNil();
        }
    }
}

/// Remove the entries of a surviving weak table whose weak half died.
///
/// Which half is checked is what makes a table weak, and it mirrors the mark
/// phase exactly: a weak-keyed table did not mark its keys, so its keys are
/// what may have died. The removal is `janet_table_remove` with the search
/// skipped, since the entry is already in hand — the count drops, the deleted
/// count rises, and the slot becomes the (nil, false) tombstone that keeps
/// later probes walking past it.
fn dropDeadEntries(table: *types.JanetTable, memtype: types.MemoryType) void {
    const check_values = memtype == .table_weakv or memtype == .table_weakkv;
    const check_keys = memtype == .table_weakk or memtype == .table_weakkv;
    // The C original walks a pointer to `data + capacity`; an index covers the
    // same slots for any capacity a table can hold, which is never negative.
    var i: i32 = 0;
    while (i < table.*.capacity) : (i += 1) {
        const kv = &table.*.slots()[@intCast(i)];
        var drop = false;
        if (check_keys and !checkLiveref(kv.key)) drop = true;
        if (check_values and !checkLiveref(kv.value)) drop = true;
        if (drop) {
            table.*.count -= 1;
            table.*.deleted += 1;
            kv.key = wrap.fromNil();
            kv.value = wrap.fromFalse();
        }
    }
}

// ----------------------------------------------------------------- sweep

/// Unlink and free every unreachable block on one heap list, clearing the
/// reachable flag on the survivors so the next mark phase starts clean.
///
/// `janet_deinit_block` runs before the unlink, which is the C original's
/// order and is load-bearing for the jump-transparency note above: a finalizer
/// that raises leaves the block on the list and it is finalized again next
/// time. The list is passed by pointer because the head is a `janet_vm` field
/// and both lists are swept the same way.
fn freeUnreachable(list: *?*anyopaque) void {
    const g = &vm_state.current().gc;
    var previous: ?*types.JanetGCObject = null;
    var current: ?*types.JanetGCObject = @ptrCast(@alignCast(list.*));
    while (current) |block| {
        const next = block.data.next;
        if ((block.flags & mem_retained) != 0) {
            previous = current;
            block.flags &= ~mem_reachable;
        } else {
            g.block_count -%= 1;
            deinitBlock(block);
            if (previous != null) {
                previous.?.data.next = next;
            } else {
                list.* = @ptrCast(next);
            }
            utils.free(@ptrCast(current));
        }
        current = next;
    }
}

/// Free everything the mark phase did not reach, and drop the weak references
/// to it.
///
/// The weak heap is swept twice, and the order is the whole point. A dead weak
/// reference has to be nilled out while the object it names is still allocated,
/// because the test is a read of that object's header; freeing first would
/// leave the second pass reading freed memory. So the first pass reads every
/// surviving weak container and the second frees, and no pass does both.
pub fn sweep() void {
    const g = &vm_state.current().gc;

    // Sweep weak heap to drop weak refs.
    var current: ?*types.JanetGCObject = @ptrCast(@alignCast(g.weak_blocks));
    while (current) |block| {
        const next = block.data.next;
        if ((block.flags & mem_retained) != 0) {
            const memtype = gcType(current.?);
            if (memtype == .array_weak) {
                dropDeadElements(@ptrCast(@alignCast(current)));
            } else {
                dropDeadEntries(@ptrCast(@alignCast(current)), memtype);
            }
        }
        current = next;
    }

    // Sweep weak heap to free blocks, then the main heap.
    freeUnreachable(&g.weak_blocks);
    freeUnreachable(&g.blocks);

    if (has_ev) sweepThreadedAbstracts();
}

/// Drop this interpreter's reference to every threaded abstract the mark phase
/// did not visit.
///
/// The table is a per-collection visit record rather than a heap: `janet_mark`
/// writes true into it for every threaded abstract it reaches, and this reads
/// the entry and then resets it to false for the next collection. An entry
/// still false is one no live value in this interpreter refers to, so this
/// interpreter's refcount goes with it — and the abstract is freed only by
/// whichever interpreter takes the count to zero, which is what makes the
/// finalizer run exactly once.
fn sweepThreadedAbstracts() void {
    const v = vm_state.current();
    // The scheduler's visit record, which is the only part of `VmEv` the
    // collector touches.
    const threaded = &v.ev.threaded_abstracts;
    const items = threaded.data;
    var i: i32 = 0;
    while (i < threaded.capacity) : (i += 1) {
        const kv = &items.?[@intCast(i)];
        if (repr.checkType(kv.key, repr.Tag.abstract)) {
            if (!repr.truthy(kv.value)) {
                const abst = wrap.toAbstract(kv.key);
                const head = types.abstractHead(abst);
                if (head.type.*.gcperthread) |gcperthread| {
                    assertFinalized(gcperthread(types.abstractData(head), head.size), "per-thread finalizer failed");
                }
                _ = abstracts.decrefMaybeFree(abst);

                // Mark as tombstone in place.
                kv.key = wrap.fromNil();
                kv.value = wrap.fromFalse();
                threaded.deleted += 1;
                threaded.count -= 1;
            }

            // Reset for next sweep. Reached whether or not the entry was just
            // tombstoned, because the type test above ran before the key was
            // replaced.
            kv.value = wrap.fromFalse();
        }
    }
}

// ------------------------------------------------------------- teardown

/// Free the whole heap, at `janet_deinit`.
///
/// This is not a collection: nothing is marked, no block is spared, and the
/// list is not unlinked as it goes. Every finalizer runs, in heap order, which
/// is allocation order reversed.
pub fn clearMemory() void {
    // Teardown reaches three aggregates and each is named: the scheduler's
    // threaded-abstract table, the main heap, and the scratch table. A
    // function this broad should say so rather than hold one `v`.
    const v = vm_state.current();
    const g = &v.gc;

    if (has_ev) {
        // The scheduler's visit record, which is the only part of `VmEv` the
        // collector touches. **The binding lives inside the guard**, because
        // `VmEv` is an empty `extern struct` without an event loop and naming
        // one of its fields above the `if` is a reference a `-Dev=false` build
        // cannot resolve.
        const threaded = &v.ev.threaded_abstracts;
        // Every threaded abstract this interpreter still holds loses its
        // reference, whether or not anything still refers to it.
        const items = threaded.data;
        var i: i32 = 0;
        while (i < threaded.capacity) : (i += 1) {
            const kv = &items.?[@intCast(i)];
            if (repr.checkType(kv.key, repr.Tag.abstract)) {
                const abst = wrap.toAbstract(kv.key);
                const head = types.abstractHead(abst);
                if (head.type.*.gcperthread) |gcperthread| {
                    assertFinalized(gcperthread(types.abstractData(head), head.size), "per-thread finalizer failed");
                }
                _ = abstracts.decrefMaybeFree(abst);
            }
        }
    }

    // The main heap only. `weak_blocks` is not walked here and that is Janet's
    // behaviour rather than an omission; see the note at the head of this file
    // and the entry in `FOUND.md`.
    var current: ?*types.JanetGCObject = @ptrCast(@alignCast(g.blocks));
    while (current) |block| {
        deinitBlock(block);
        const next = block.data.next;
        utils.free(@ptrCast(block));
        current = next;
    }
    g.blocks = null;

    // The scratch table, whose three fields go together for the reason
    // `gc.scratchDeinit` carries: upstream frees the table and leaves
    // `scratch_mem` dangling with `scratch_cap` at its old value, so a
    // `janet_smalloc` before the next `janet_init` writes through the pointer
    // It is heap corruption that only glibc's allocator hardening detects;
    // `FOUND.md` has the bisection.
    //
    // Nulling here makes that path **correct** rather than loud, and the
    // difference is worth stating: with all three cleared, the next
    // `janet_smalloc` finds `scratch_len == scratch_cap == 0`, takes the growth
    // path, and allocates a fresh table. It does not trap. So this removes the
    // corruption and does not diagnose the caller -- which is why the contract
    // that calls in after `janet_deinit` is the actual fix, and this is
    // defence in depth behind it.
    gc_alloc.scratchDeinit(&v.scratch);
}

pub fn clearMemoryAbi() void {
    clearMemory();
}
