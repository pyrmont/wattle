//! Sweeping: the pass that acts on the mark phase's decision. Dropping dead
//! weak references, unlinking and freeing unreachable blocks, running
//! finalizers, and tearing the whole heap down at `janet_deinit`. This is the
//! last of the three increments `gc.c` is split into; allocation and the root
//! set moved in Part 3, the traversal and `janet_collect` in Part 4.
//!
//! **Everything here frees, and nothing here traverses.** That is the mirror
//! of Part 4's boundary and it is what makes the split hold: the mark phase
//! reads the object graph and writes one bit per object, and this file reads
//! that bit and never follows a pointer the bit does not justify. The one
//! place the two touch is `checkLiveref`, which reads the mark of a value the
//! weak heap refers to — a read, not a walk, and the reason a weak reference
//! is dropped in the sweep rather than skipped in the walk.
//!
//! **Part 4 left no seam and this increment needs none.** `janet_sweep` and
//! `janet_clear_memory` are both public API in `janet.h`; `janet_deinit_block`
//! and `janet_check_liveref` were `static` in `gc.c` with no caller outside the
//! region that moved with them. Everything this file calls outward is either
//! public API or `janet_free_all_scratch`, declared in `gc.h` since Part 3. So
//! `gc.c` is now split three ways without a single declaration added for the
//! benefit of the split itself.
//!
//! **The file is jump-transparent**, under the rule SPIKE-8 settled, and this
//! is the increment that rule was written for. `deinitBlock` calls an abstract
//! type's `gc` and `gcperthread` finalizers, and the threaded-abstract sweep
//! calls `gcperthread` again; all three are third-party code. Neither may
//! raise, and if one does the signal jumps straight out through the sweep. The
//! frames it crosses own nothing — no `defer` in this file, checked by
//! `build.zig` — so the jump is mechanically harmless and the damage is exactly
//! the C original's, which `SPIKE-8.md` measured: the block is still on its
//! list because `janet_deinit_block` runs *before* the unlink, so every later
//! collection finds it unreachable again and finalizes it again.
//!
//! One defect is reproduced rather than repaired, and it is in `FOUND.md`:
//! `janet_clear_memory` frees the main heap and never touches
//! `janet_vm.weak_blocks`, so every weak table and weak array still alive at
//! `janet_deinit` leaks its block and its data array — 32KB per cycle for a
//! 4096-element weak array, measured and recorded in `FOUND.md`. This file walks
//! the same one list the original does, and `test/gc_sweep.zig` asserts the
//! leak's signature so that whichever side is fixed first says so.

const std = @import("std");
const abi = @import("abi");
const c = abi.c;
const raise = @import("raise");
const abstract_type = @import("abstract_type.zig");

/// `janet_vm` as `src/core/state.h` declares it, resolved through `abi.zig`.
inline fn vm() *c.JanetVM {
    return &c.janet_vm;
}

/// `JANET_VM_HAS_EV` in `src/zig/state_abi.h`. Both exported functions have an
/// `#ifdef JANET_EV` region that reaches `janet_vm.threaded_abstracts`, a field
/// that only exists in that configuration, so this has to gate compilation
/// rather than merely behaviour.
const has_ev = c.JANET_VM_HAS_EV != 0;

/// `janet_symbol_deinit` is declared in `src/core/symcache.h`, which `abi.zig`
/// does not translate. It takes a `const uint8_t *`, so no Janet type crosses
/// and the single-translation rule is not at stake — the same case `gc_mark.zig`
/// makes for `janet_ev_mark`.
extern fn janet_symbol_deinit(sym: [*c]const u8) callconv(.c) void;

const mem_typebits: i32 = c.JANET_MEM_TYPEBITS;
const mem_reachable: i32 = c.JANET_MEM_REACHABLE;
const mem_disabled: i32 = c.JANET_MEM_DISABLED;

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
inline fn gcHeader(mem: anytype) *c.JanetGCObject {
    return @ptrFromInt(@intFromPtr(mem));
}

inline fn gcReachable(mem: anytype) bool {
    return (gcHeader(mem).flags & mem_reachable) != 0;
}

inline fn gcType(mem: [*c]c.JanetGCObject) i32 {
    return mem.*.flags & mem_typebits;
}

// --------------------------------------------------------- janet.h macros

/// The four `*_head` macros, and the two inverses that recover the payload a
/// header precedes. All six cross the same fixed distance in one direction or
/// the other.
///
/// The C macros use `offsetof(Head, data)`, and Zig cannot: **translate-c drops
/// flexible array members entirely**, so `@offsetOf(JanetStringHead, "data")`
/// does not compile. `@sizeOf` is used instead, which is the same number
/// precisely when the flexible array needs no padding after the last declared
/// field — true for all four heads here, because each ends on a field at least
/// as aligned as the array element. That is an assumption about C layout
/// rather than about this file, so `test/abi.c` pins it in C, where
/// `offsetof` exists, and `test/gc_mark.zig` checks the offset the allocator
/// actually used.
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

/// `((JanetStringHead *) mem)->data`, the bytes a string or symbol block holds.
inline fn stringData(mem: [*c]c.JanetGCObject) [*c]const u8 {
    return @ptrFromInt(@intFromPtr(mem) +% @sizeOf(c.JanetStringHead));
}

/// `head->data`, which is the same pointer the runtime hands out for the
/// abstract — `janet_abstract_head` and this are inverses.
inline fn abstractData(head: *c.JanetAbstractHead) ?*anyopaque {
    return @ptrFromInt(@intFromPtr(head) +% @sizeOf(c.JanetAbstractHead));
}

// ------------------------------------------------------------- finalizing

/// `janet_assert(!callback(...), message)` from `src/core/util.h`. A finalizer
/// that reports failure is not an error to be raised — the C original prints
/// and calls `abort`, which is what `janet_zig_fatal` does.
inline fn assertFinalized(status: c_int, message: [*c]const u8) void {
    if (status != 0) c.janet_zig_fatal(message);
}

/// Release everything a block owns outside its own allocation, without freeing
/// the block itself. Both callers free it immediately afterwards; they are
/// separate steps because `janet_sweep` has to unlink the block in between.
///
/// The types with no case are not an omission. A string, keyword, tuple,
/// struct or function stores its payload inside the same allocation, so
/// freeing the block frees the payload; a symbol is the one immutable type
/// with an external obligation, because it has to leave the symbol cache.
fn deinitBlock(mem: [*c]c.JanetGCObject) void {
    switch (mem.*.flags & mem_typebits) {
        c.JANET_MEMORY_SYMBOL => janet_symbol_deinit(stringData(mem)),

        c.JANET_MEMORY_ARRAY, c.JANET_MEMORY_ARRAY_WEAK => {
            const array: [*c]c.JanetArray = @ptrCast(@alignCast(mem));
            c.janet_free(@ptrCast(array.*.data));
        },

        c.JANET_MEMORY_TABLE,
        c.JANET_MEMORY_TABLE_WEAKK,
        c.JANET_MEMORY_TABLE_WEAKV,
        c.JANET_MEMORY_TABLE_WEAKKV,
        => {
            const table: [*c]c.JanetTable = @ptrCast(@alignCast(mem));
            c.janet_free(@ptrCast(table.*.data));
        },

        c.JANET_MEMORY_FIBER => {
            const f: [*c]c.JanetFiber = @ptrCast(@alignCast(mem));
            if (has_ev) {
                // The two flags live in different words, and deliberately:
                // `ev.c` keeps `IN_FLIGHT` in the fiber's own flags and
                // `SUSPENDED` in the GC header's, and this reads each where it
                // is written.
                if (f.*.ev_state != null and (f.*.flags & c.JANET_FIBER_EV_FLAG_IN_FLIGHT) == 0) {
                    c.janet_ev_dec_refcount();
                    c.janet_free(f.*.ev_state);
                } else if ((f.*.gc.flags & c.JANET_FIBER_EV_FLAG_SUSPENDED) != 0) {
                    c.janet_ev_dec_refcount();
                }
            }
            c.janet_free(@ptrCast(f.*.data));
        },

        c.JANET_MEMORY_BUFFER => c.janet_buffer_deinit(@ptrCast(@alignCast(mem))),

        c.JANET_MEMORY_ABSTRACT => {
            const head: *c.JanetAbstractHead = @ptrCast(@alignCast(mem));
            if (head.type.*.gcperthread) |gcperthread| {
                assertFinalized(gcperthread(abstractData(head), head.size), "per-thread finalizer failed");
            }
            if (abstract_type.of(head.type).gc) |gc| {
                // A finalizer cannot raise -- `abstract_type.zig` has the
                // contract, and `FOUND.md`'s "A panicking finalizer poisons
                // the heap and kills the process at deinit" is what allowing
                // it costs. The nonzero return is the failure channel, and
                // this is `janet_assert(!head->type->gc(...))` unchanged.
                assertFinalized(gc(abstractData(head), head.size), "finalizer failed");
            }
        },

        c.JANET_MEMORY_FUNCENV => {
            const env: [*c]c.JanetFuncEnv = @ptrCast(@alignCast(mem));
            // A non-zero offset means the values are still on a fiber's stack
            // and belong to the fiber, not to this environment.
            if (env.*.offset == 0) c.janet_free(@ptrCast(env.*.as.values));
        },

        c.JANET_MEMORY_FUNCDEF => {
            const def: [*c]c.JanetFuncDef = @ptrCast(@alignCast(mem));
            c.janet_free(@ptrCast(def.*.defs));
            c.janet_free(@ptrCast(def.*.environments));
            c.janet_free(@ptrCast(def.*.constants));
            c.janet_free(@ptrCast(def.*.bytecode));
            c.janet_free(@ptrCast(def.*.sourcemap));
            c.janet_free(@ptrCast(def.*.closure_bitset));
            c.janet_free(@ptrCast(def.*.symbolmap));
        },

        // JANET_MEMORY_FUNCTION, and the C original's `default`.
        else => {},
    }
}

// ------------------------------------------------------------- weak refs

/// Whether a value the weak heap refers to was reached by the mark phase.
///
/// Only collectable types can answer no. The immediates and the two number
/// types have no header to consult and are always live, which is what the
/// default arm means — a weak table keyed by integers never drops an entry.
fn checkLiveref(x: c.Janet) bool {
    return switch (c.janet_type(x)) {
        c.JANET_ARRAY,
        c.JANET_TABLE,
        c.JANET_FUNCTION,
        c.JANET_BUFFER,
        c.JANET_FIBER,
        => gcReachable(c.janet_unwrap_pointer(x)),
        c.JANET_STRING, c.JANET_SYMBOL, c.JANET_KEYWORD => gcReachable(stringHead(c.janet_unwrap_string(x))),
        c.JANET_ABSTRACT => gcReachable(abstractHead(c.janet_unwrap_abstract(x))),
        c.JANET_TUPLE => gcReachable(tupleHead(c.janet_unwrap_tuple(x))),
        c.JANET_STRUCT => gcReachable(structHead(c.janet_unwrap_struct(x))),
        else => true,
    };
}

/// Nil out the elements of a surviving weak array that nothing else reached.
fn dropDeadElements(array: [*c]c.JanetArray) void {
    // The C original counts with a `uint32_t` against `(uint32_t) array->count`,
    // and the cast is kept rather than dropped: a negative count is not
    // reachable through the API, but if one ever were, dropping the cast would
    // change which memory the loop touches rather than merely where it stops.
    var i: u32 = 0;
    const count: u32 = @bitCast(array.*.count);
    while (i < count) : (i += 1) {
        if (!checkLiveref(array.*.data[i])) {
            array.*.data[i] = c.janet_wrap_nil();
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
fn dropDeadEntries(table: [*c]c.JanetTable, memtype: i32) void {
    const check_values = memtype == c.JANET_MEMORY_TABLE_WEAKV or memtype == c.JANET_MEMORY_TABLE_WEAKKV;
    const check_keys = memtype == c.JANET_MEMORY_TABLE_WEAKK or memtype == c.JANET_MEMORY_TABLE_WEAKKV;
    // The C original walks a pointer to `data + capacity`; an index covers the
    // same slots for any capacity a table can hold, which is never negative.
    var i: i32 = 0;
    while (i < table.*.capacity) : (i += 1) {
        const kv = &table.*.data[@intCast(i)];
        var drop = false;
        if (check_keys and !checkLiveref(kv.key)) drop = true;
        if (check_values and !checkLiveref(kv.value)) drop = true;
        if (drop) {
            table.*.count -= 1;
            table.*.deleted += 1;
            kv.key = c.janet_wrap_nil();
            kv.value = c.janet_wrap_false();
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
    const v = vm();
    var previous: [*c]c.JanetGCObject = null;
    var current: [*c]c.JanetGCObject = @ptrCast(@alignCast(list.*));
    while (current != null) {
        const next = current.*.data.next;
        if ((current.*.flags & mem_retained) != 0) {
            previous = current;
            current.*.flags &= ~mem_reachable;
        } else {
            v.block_count -%= 1;
            deinitBlock(current);
            if (previous != null) {
                previous.*.data.next = next;
            } else {
                list.* = @ptrCast(next);
            }
            c.janet_free(@ptrCast(current));
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
export fn janet_sweep() callconv(.c) void {
    const v = vm();

    // Sweep weak heap to drop weak refs.
    var current: [*c]c.JanetGCObject = @ptrCast(@alignCast(v.weak_blocks));
    while (current != null) {
        const next = current.*.data.next;
        if ((current.*.flags & mem_retained) != 0) {
            const memtype = gcType(current);
            if (memtype == c.JANET_MEMORY_ARRAY_WEAK) {
                dropDeadElements(@ptrCast(@alignCast(current)));
            } else {
                dropDeadEntries(@ptrCast(@alignCast(current)), memtype);
            }
        }
        current = next;
    }

    // Sweep weak heap to free blocks, then the main heap.
    freeUnreachable(&v.weak_blocks);
    freeUnreachable(&v.blocks);

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
    const v = vm();
    const items = v.threaded_abstracts.data;
    var i: i32 = 0;
    while (i < v.threaded_abstracts.capacity) : (i += 1) {
        const kv = &items[@intCast(i)];
        if (c.janet_checktype(kv.key, c.JANET_ABSTRACT) != 0) {
            if (c.janet_truthy(kv.value) == 0) {
                const abst = c.janet_unwrap_abstract(kv.key);
                const head = abstractHead(abst);
                if (head.type.*.gcperthread) |gcperthread| {
                    assertFinalized(gcperthread(abstractData(head), head.size), "per-thread finalizer failed");
                }
                _ = c.janet_abstract_decref_maybe_free(abst);

                // Mark as tombstone in place.
                kv.key = c.janet_wrap_nil();
                kv.value = c.janet_wrap_false();
                v.threaded_abstracts.deleted += 1;
                v.threaded_abstracts.count -= 1;
            }

            // Reset for next sweep. Reached whether or not the entry was just
            // tombstoned, because the type test above ran before the key was
            // replaced.
            kv.value = c.janet_wrap_false();
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
    const v = vm();

    if (has_ev) {
        // Every threaded abstract this interpreter still holds loses its
        // reference, whether or not anything still refers to it.
        const items = v.threaded_abstracts.data;
        var i: i32 = 0;
        while (i < v.threaded_abstracts.capacity) : (i += 1) {
            const kv = &items[@intCast(i)];
            if (c.janet_checktype(kv.key, c.JANET_ABSTRACT) != 0) {
                const abst = c.janet_unwrap_abstract(kv.key);
                const head = abstractHead(abst);
                if (head.type.*.gcperthread) |gcperthread| {
                    assertFinalized(gcperthread(abstractData(head), head.size), "per-thread finalizer failed");
                }
                _ = c.janet_abstract_decref_maybe_free(abst);
            }
        }
    }

    // The main heap only. `weak_blocks` is not walked here and that is the C
    // original's behaviour, not an omission in the port; see the note at the
    // head of this file and the entry in `FOUND.md`.
    var current: [*c]c.JanetGCObject = @ptrCast(@alignCast(v.blocks));
    while (current != null) {
        deinitBlock(current);
        const next = current.*.data.next;
        c.janet_free(@ptrCast(current));
        current = next;
    }
    v.blocks = null;

    c.janet_free_all_scratch();
    c.janet_free(@ptrCast(v.scratch_mem));

    // **The three fields go with the block.** `janet_free_all_scratch` sets
    // `scratch_len` to zero and the line above frees the table, but upstream's
    // `janet_clear_memory` leaves `scratch_mem` dangling and `scratch_cap` at
    // its old value -- so a `janet_smalloc` after a `janet_deinit` and before
    // the next `janet_init` finds `scratch_len != scratch_cap`, takes the
    // no-growth path, and writes `scratch_mem[0] = s` **through the pointer
    // just freed**.
    //
    // `janet_init` resets all three, so a program that re-initialises never
    // sees it; what does see it is anything that calls into the runtime
    // between the two. Phase 11 Part 27 found it as heap corruption that only
    // glibc's allocator hardening detects -- `FOUND.md` has the entry and the
    // bisection.
    //
    // Nulling here makes that path **correct** rather than loud, and the
    // difference is worth stating because the first write-up of this got it
    // backwards: with all three cleared, the next `janet_smalloc` finds
    // `scratch_len == scratch_cap == 0`, takes the growth path, and allocates
    // a fresh table. It does not trap. So this removes the corruption and
    // does not diagnose the caller -- which is why the actual fix for Part
    // 27's defect is the contract that called in after `janet_deinit`, and
    // this is defence in depth behind it.
    v.scratch_mem = null;
    v.scratch_cap = 0;
    v.scratch_len = 0;
}

export fn janet_clear_memory() callconv(.c) void {
    clearMemory();
}
