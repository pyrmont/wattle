//! The key/value containers: structs and tables, including the three weak
//! table variants. This is Part 6c of Phase 8, and it takes the
//! data-structure core of `src/core/struct.c` and of `src/core/table.c`. The
//! `JANET_CORE_FN` bodies in both files stayed in C, on the rule Parts 6a and
//! 6b followed: the standard-library surface is not value construction. Phase
//! 10 Part 6 brought them here, at the foot of the file.
//!
//! These two are one increment because no boundary can be drawn between them.
//! `janet_struct_to_table` calls `janet_table_put`; `janet_table_to_struct`
//! calls `janet_struct_begin`, `janet_struct_put` and `janet_struct_end`. They
//! are mutually recursive across the file boundary, they share the `JanetKV`
//! bucket layout, and each is the other's conversion target.
//!
//! ## One layout, two probing disciplines
//!
//! It is tempting to read "struct" as "immutable table" and expect one probe
//! loop. They are not the same algorithm, and the difference is the reason
//! `janet_struct_find` exists beside `janet_dict_find` rather than calling it:
//!
//!  - **A table probes linearly and carries tombstones.** A removed entry
//!    leaves a nil key with a *false* value behind, which stops a lookup from
//!    treating the hole as the end of a run. `janet_dict_find` in `util.c`
//!    therefore distinguishes "nil key, nil value" -- a true empty slot, and
//!    the end of the search -- from "nil key, non-nil value", which it
//!    remembers as the first reusable bucket and keeps walking past. Table
//!    layout depends on insertion *and deletion* order, and nothing observable
//!    depends on table layout.
//!  - **A struct probes Robin Hood and has no tombstones.** Nothing is ever
//!    removed from a struct, and the ordering rule -- displace the entry that
//!    is closer to its ideal slot, breaking ties by hash and then by
//!    `janet_compare` on the keys -- makes the final layout a function of the
//!    *set* of pairs rather than of the order they arrived in. That is not an
//!    optimisation. `janet_struct_end` hashes the bucket array with
//!    `janet_kv_calchash`, so two structs built from the same pairs in
//!    different orders must lay out identically or `{1 2 3 4}` would not equal
//!    `{3 4 1 2}`. The comparison tiebreak is what makes the order total.
//!
//! So `janet_struct_find` is the simpler of the two loops despite the harder
//! insert: with no tombstones, the first nil key really is the end.
//!
//! ## The count lives in the hash field during construction
//!
//! `janet_struct_begin` sets `head->hash = 0` and every `janet_struct_put`
//! that fills an empty slot increments it. The field is a running count until
//! `janet_struct_end` overwrites it with the real hash, which is also how
//! `put` enforces the declared length -- it returns early once the count
//! reaches `length`, so a struct built with more pairs than it was begun with
//! silently drops the surplus. Preserved exactly, including the aliasing: a
//! struct observed between `begin` and `end` has a hash that is a count.
//!
//! ## The increment SPIKE-8 was written for
//!
//! Every other Phase 8 increment inherited the spike's decision without
//! exercising it. This one exercises it directly. `janet_struct_put_ext` calls
//! `janet_compare` on two keys, and `janet_dict_find` -- reached from every
//! table operation -- calls `janet_equals`; both dispatch to a third-party
//! abstract type's callback for an abstract key. Under SPIKE-8 such a callback
//! may not raise, and if one does the signal jumps straight through these
//! frames. There is no `defer` here and `build.zig` checks that there is not.
//!
//! One consequence is worth naming rather than leaving to be discovered.
//! `janet_table_rehash` publishes the new bucket array into `t->data` before
//! it re-inserts, and holds the old one only in a local. A signal raised out of
//! a key comparison during that loop leaks the old array and leaves the table
//! holding a partially populated new one. The C does the same thing, and the
//! same rule covers both: a callback that raises is out of contract. Nothing
//! is restructured to survive it, because surviving it is not the promise.
//!
//! ## What is reproduced rather than repaired
//!
//! `janet_struct_begin` computes `2 * count` in `int32_t`, which is undefined
//! for a count above `INT32_MAX / 2`. The port wraps rather than trapping,
//! which is what every supported target does, and the `capacity < 0` fallback
//! below it is the C author's defence against a case `janet_tablen` cannot
//! actually produce -- it clamps at `INT32_MAX` rather than overflowing. Both
//! are kept as written.
//!
//! A table whose capacity is zero cannot be looked up in at all, and
//! `janet_table` produces one for any negative capacity. The details are on
//! `tableInitImpl` below; the short version is that `janet_maphash` degenerates
//! into the identity when the mask is all ones, so the whole hash is used as a
//! bucket number and only a hash of zero stays in bounds. Not reachable from
//! Janet source, kept as written, recorded in `FOUND.md`.
//!
//! The tombstone-retiring branch in `janet_table_put` and
//! `tablePutNoOverwrite` is unreachable for the same kind of reason -- the load
//! factor guarantees an empty bucket, and `janet_dict_find` prefers one over a
//! tombstone. Also kept, also recorded.
//!
//! `janet_table_clone` copies with plain `memcpy`. A table with a null bucket
//! array makes that `memcpy(dst, NULL, 0)`, which the standard does not
//! exempt, and `janet_table` produces exactly that for any negative capacity:
//! `janet_tablen` returns 0 only for a negative argument, and 0 is the one
//! result `tableInitImpl` turns into a null `data`. It is not reachable from
//! Janet source -- every Janet-level constructor validates its capacity as a
//! non-negative integer, and `janet_table(0)` has a capacity of *one* -- so
//! this needs a C API caller. `safe_memcpy` exists in `util.c` for exactly
//! this case, "avoid some undefined behavior that was common in the code
//! base", and this call site was missed. The port uses `safe_memcpy` and
//! `FOUND.md` records the C original. No observable behaviour differs.

const std = @import("std");
const abi = @import("abi");
const corefn = @import("corefn");
const c = abi.c;
const raise = @import("raise");
const arglayer = @import("arglayer.zig");

/// Functions from `src/core/util.c` and `src/core/wrap.c`, declared here rather
/// than imported: `util.h` is deliberately outside `abi.zig` -- see the note at
/// the head of that file.
///
/// Three of these take a `JanetKV *` or a `Janet`, which is the same widening
/// Part 6b recorded for `janet_array_calchash`. The single-translation rule
/// still holds, because the `c.JanetKV` in these signatures is the shared
/// translation's type rather than a second one. What no longer applies is the
/// usual justification that no Janet type crosses. The reason to declare them
/// rather than move them is that all three belong to files this increment does
/// not open: `janet_dict_find` is `util.c`'s, shared with `value.c`'s iteration
/// helper, and `janet_memempty` and `janet_memalloc_empty` sit in `wrap.c`
/// beside the representation-dependent constructors.
extern fn safe_memcpy(dest: ?*anyopaque, src: ?*const anyopaque, len: usize) callconv(.c) void;
extern fn janet_tablen(n: i32) callconv(.c) i32;
extern fn janet_kv_calchash(kvs: [*c]const c.JanetKV, len: i32) callconv(.c) i32;
extern fn janet_dict_find(buckets: [*c]const c.JanetKV, cap: i32, key: c.Janet) callconv(.c) [*c]const c.JanetKV;
extern fn janet_dict_find_keyword(
    buckets: [*c]const c.JanetKV,
    cap: i32,
    cstr: [*c]const u8,
    cstr_len: i32,
) callconv(.c) [*c]const c.JanetKV;
extern fn janet_memempty(mem: [*c]c.JanetKV, count: i32) callconv(.c) void;
extern fn janet_memalloc_empty(count: i32) callconv(.c) ?*anyopaque;

/// A table whose bucket array came from the scratch allocator rather than from
/// `janet_malloc`. `table.c` keeps this out of `janet.h` because it is not part
/// of the public flag vocabulary; it is stored in the same `gc.flags` word the
/// memory type occupies, which is safe only because a scratch table is never
/// `janet_gcalloc`ed.
const table_flag_stack: i32 = 0x10000;

/// C's conversion of a signed count to `size_t`: sign-extend to the pointer
/// width, then reinterpret. Same helper, and same reason, as `buffer_array.zig`
/// and `string_symbol.zig` -- a negative length becomes a request the allocator
/// cannot satisfy rather than a trap one statement earlier.
inline fn asSize(n: i32) usize {
    return @bitCast(@as(isize, n));
}

/// `janet_maphash` from `util.h`. The capacity is always a power of two, so the
/// mask is exact and the result is always in range.
inline fn mapHash(cap: i32, hash: i32) i32 {
    return @bitCast(@as(u32, @bitCast(hash)) & @as(u32, @bitCast(cap -% 1)));
}

/// Recover a struct's head from the bucket address Janet passes around.
/// `@sizeOf` rather than `@offsetOf`, because translate-c drops the flexible
/// array member and the two are equal for this layout; `test/gc_mark.c` and
/// `test/gc_sweep.c` already pin that equality from C, and
/// `test/struct_table.c` pins it again beside the constructor that depends on
/// it.
inline fn structHead(st: [*c]const c.JanetKV) *c.JanetStructHead {
    return @ptrFromInt(@intFromPtr(st) -% @sizeOf(c.JanetStructHead));
}

/// And the inverse, for a block `janet_gcalloc` just returned.
inline fn structData(head: *c.JanetStructHead) [*c]c.JanetKV {
    return @ptrFromInt(@intFromPtr(head) +% @sizeOf(c.JanetStructHead));
}

inline fn isNilKey(key: c.Janet) bool {
    return c.janet_checktype(key, c.JANET_NIL) != 0;
}

/// The two keys a dictionary refuses to store. Nil is the absent-key sentinel,
/// and a NaN is refused because it does not compare equal to itself, so a
/// lookup could never find it again.
inline fn isUnstorableKey(key: c.Janet) bool {
    if (c.janet_checktype(key, c.JANET_NIL) != 0) return true;
    return c.janet_checktype(key, c.JANET_NUMBER) != 0 and
        std.math.isNan(c.janet_unwrap_number(key));
}

// ------------------------------------------------------------------ struct

/// Allocate a struct's bucket array and its head in one block.
///
/// The capacity is the smallest power of two *strictly greater* than twice the
/// declared pair count -- `janet_tablen` is a strict next-power-of-two, so a
/// count of two gets eight buckets rather than four. That keeps the load factor
/// below one half always and at one quarter whenever `2 * count` is itself a
/// power of two, which is what bounds the Robin Hood displacement chains.
/// `2 * count` overflows for a count above
/// `INT32_MAX / 2` -- undefined in C, wrapping here and on every supported
/// target -- and the `capacity < 0` retry below is the C author's defence
/// against a result `janet_tablen` does not produce, since it clamps at
/// `INT32_MAX`. Both are kept.
///
/// `hash` starts at zero and is a running count of filled slots until
/// `janet_struct_end` replaces it.
export fn janet_struct_begin(count: i32) callconv(.c) [*c]c.JanetKV {
    var capacity = janet_tablen(2 *% count);
    if (capacity < 0) capacity = janet_tablen(count +% 1);

    const size = @sizeOf(c.JanetStructHead) +% asSize(capacity) *% @sizeOf(c.JanetKV);
    const head: *c.JanetStructHead = @ptrCast(@alignCast(c.janet_gcalloc(c.JANET_MEMORY_STRUCT, size)));
    head.length = count;
    head.capacity = capacity;
    head.hash = 0;
    head.proto = null;

    const st = structData(head);
    janet_memempty(st, capacity);
    return st;
}

/// Find the bucket holding `key`, or the first empty bucket on its probe path.
///
/// A struct has no tombstones, so the first nil key ends the search and there
/// is no reusable-bucket bookkeeping. Returns null only when the array is
/// entirely full, which `janet_struct_begin`'s capacity policy prevents for any
/// struct built through the public constructors.
export fn janet_struct_find(st: [*c]const c.JanetKV, key: c.Janet) callconv(.c) [*c]const c.JanetKV {
    const cap = structHead(st).capacity;
    const index = mapHash(cap, c.janet_hash(key));
    var i = index;
    while (i < cap) : (i += 1) {
        if (isNilKey(st[@intCast(i)].key) or c.janet_equals(st[@intCast(i)].key, key) != 0) return st + @as(usize, @intCast(i));
    }
    i = 0;
    while (i < index) : (i += 1) {
        if (isNilKey(st[@intCast(i)].key) or c.janet_equals(st[@intCast(i)].key, key) != 0) return st + @as(usize, @intCast(i));
    }
    return null;
}

/// Insert into a struct that is still under construction.
///
/// Nil keys, nil values and NaN keys are dropped, and so is everything past the
/// declared length. Collisions are resolved by Robin Hood displacement, which
/// is an in-place insertion sort: the pair further from its ideal slot keeps
/// the slot, ties broken by hash and then by `janet_compare` on the keys. The
/// result is that the bucket array depends only on the set of pairs, which is
/// what makes two equal structs hash equal.
///
/// `replace` distinguishes the two entry points. `janet_struct_put` overwrites
/// a duplicate key's value; `struct/proto-flatten` passes zero so that a
/// prototype's binding cannot displace the child's.
export fn janet_struct_put_ext(st: [*c]c.JanetKV, key_in: c.Janet, value_in: c.Janet, replace: c_int) callconv(.c) void {
    var key = key_in;
    var value = value_in;
    const head = structHead(st);
    const cap = head.capacity;
    var hash = c.janet_hash(key);
    const index = mapHash(cap, hash);
    const bounds = [4]i32{ index, cap, 0, index };
    if (isUnstorableKey(key) or c.janet_checktype(value, c.JANET_NIL) != 0) return;
    // Refuse anything past the declared length.
    if (head.hash == head.length) return;

    var dist: i32 = 0;
    var j: usize = 0;
    while (j < 4) : (j += 2) {
        var i = bounds[j];
        while (i < bounds[j + 1]) : ({
            i += 1;
            dist += 1;
        }) {
            const kv = &st[@intCast(i)];

            // An empty slot ends the walk: take it and grow the count.
            if (isNilKey(kv.key)) {
                kv.key = key;
                kv.value = value;
                head.hash += 1;
                return;
            }

            const otherhash = c.janet_hash(kv.key);
            const otherindex = mapHash(cap, otherhash);
            const otherdist = (i +% cap -% otherindex) & (cap -% 1);
            const status: c_int = if (dist < otherdist)
                -1
            else if (otherdist < dist)
                1
            else if (hash < otherhash)
                -1
            else if (otherhash < hash)
                1
            else
                c.janet_compare(key, kv.key);

            if (status == 1) {
                // The occupant is further from home: it keeps the slot and the
                // pair we are carrying takes over its displacement and hash.
                const temp = kv.*;
                kv.key = key;
                kv.value = value;
                key = temp.key;
                value = temp.value;
                dist = otherdist;
                hash = otherhash;
            } else if (status == 0) {
                if (replace != 0) kv.value = value;
                return;
            }
        }
    }
}

/// Insert, replacing the value of a duplicate key.
export fn janet_struct_put(st: [*c]c.JanetKV, key: c.Janet, value: c.Janet) callconv(.c) void {
    janet_struct_put_ext(st, key, value, 1);
}

/// Seal a struct and give it its hash.
///
/// If fewer pairs landed than were declared -- duplicates, or rejected keys --
/// the bucket array is the wrong size for its contents, so the whole struct is
/// rebuilt at the size it actually needs. The second build always succeeds,
/// because the count it is given is the count that fit. The prototype is
/// carried across by hand, since it is not a bucket.
///
/// The prototype contributes to the hash by a multiply rather than by being
/// walked, so a struct's hash is O(capacity) and not O(prototype depth).
export fn janet_struct_end(st_in: [*c]c.JanetKV) callconv(.c) [*c]const c.JanetKV {
    var st = st_in;
    if (structHead(st).hash != structHead(st).length) {
        const newst = janet_struct_begin(structHead(st).hash);
        var i: i32 = 0;
        while (i < structHead(st).capacity) : (i += 1) {
            const kv = &st[@intCast(i)];
            if (!isNilKey(kv.key)) janet_struct_put(newst, kv.key, kv.value);
        }
        structHead(newst).proto = structHead(st).proto;
        st = newst;
    }
    const head = structHead(st);
    head.hash = janet_kv_calchash(st, head.capacity);
    if (head.proto != null) {
        head.hash = @bitCast(@as(u32, @bitCast(head.hash)) +%
            2654435761 *% @as(u32, @bitCast(structHead(head.proto).hash)));
    }
    return st;
}

/// Look up a key in this struct only.
export fn janet_struct_rawget(st: [*c]const c.JanetKV, key: c.Janet) callconv(.c) c.Janet {
    const kv = janet_struct_find(st, key);
    return if (kv != null) kv.*.value else c.janet_wrap_nil();
}

/// Look up a key, following prototypes to a fixed depth.
export fn janet_struct_get(st_in: [*c]const c.JanetKV, key: c.Janet) callconv(.c) c.Janet {
    var st = st_in;
    var i: c_int = c.JANET_MAX_PROTO_DEPTH;
    while (st != null and i != 0) : ({
        i -= 1;
        st = structHead(st).proto;
    }) {
        const kv = janet_struct_find(st, key);
        if (kv != null and !isNilKey(kv.*.key)) return kv.*.value;
    }
    return c.janet_wrap_nil();
}

/// Look up a key and report which struct in the prototype chain held it.
export fn janet_struct_get_ex(st_in: [*c]const c.JanetKV, key: c.Janet, which: [*c][*c]const c.JanetKV) callconv(.c) c.Janet {
    var st = st_in;
    var i: c_int = c.JANET_MAX_PROTO_DEPTH;
    while (st != null and i != 0) : ({
        i -= 1;
        st = structHead(st).proto;
    }) {
        const kv = janet_struct_find(st, key);
        if (kv != null and !isNilKey(kv.*.key)) {
            which.* = st;
            return kv.*.value;
        }
    }
    return c.janet_wrap_nil();
}

/// Copy a struct's own pairs into a fresh table. The prototype is not carried;
/// `struct/to-table` rebuilds the chain itself when asked to.
export fn janet_struct_to_table(st: [*c]const c.JanetKV) callconv(.c) *c.JanetTable {
    const cap = structHead(st).capacity;
    const table = janet_table(cap);
    var i: i32 = 0;
    while (i < cap) : (i += 1) {
        const kv = &st[@intCast(i)];
        if (!isNilKey(kv.key)) janet_table_put(table, kv.key, kv.value);
    }
    return table;
}

// ------------------------------------------------------------------- table

/// Allocate an empty bucket array from the scratch allocator.
///
/// Unlike `janet_memalloc_empty` this adds no collection pressure and does not
/// check for failure: `janet_smalloc` exits the process rather than returning
/// null. Scratch memory is released wholesale by `janet_free_all_scratch`,
/// which is also what recovers it if a signal unwinds past a scratch table.
fn memallocEmptyLocal(count: i32) [*c]c.JanetKV {
    const mem: [*c]c.JanetKV = @ptrCast(@alignCast(c.janet_smalloc(asSize(count) *% @sizeOf(c.JanetKV))));
    var i: i32 = 0;
    while (i < count) : (i += 1) {
        mem[@intCast(i)].key = c.janet_wrap_nil();
        mem[@intCast(i)].value = c.janet_wrap_nil();
    }
    return mem;
}

/// Give a table its initial bucket array.
///
/// The requested capacity is rounded up by `janet_tablen`, which returns the
/// smallest power of two strictly greater than its argument -- so `janet_table(0)`
/// gets *one* bucket, not none. The only argument that yields zero is a
/// negative one, and that is the sole route to a table with a null `data`.
///
/// Such a table cannot be used. `janet_maphash` masks the hash with
/// `capacity - 1`, which at a capacity of zero is every bit set, so the mask is
/// the identity and the "bucket index" `janet_dict_find` works from is the
/// whole 32-bit hash. Both of its loops are then bounded by that number rather
/// than by the capacity -- the first runs when the hash is negative, the second
/// when it is positive -- so exactly one hash value is survivable, and it is
/// zero. `janet_table_put` reaches the same call before the rehash that would
/// have given the table buckets, so it cannot recover either.
///
/// `FOUND.md` records it, with the reproducer. It needs a
/// C API caller, since every route from Janet source validates the capacity as
/// a non-negative integer. `janet_dict_find` is in `util.c` and stays there, so
/// both selectors behave identically.
///
/// The stack flag is *assigned* rather than or-ed, which overwrites the memory
/// type in `gc.flags`. That is safe only because a scratch table is never
/// `janet_gcalloc`ed -- `janet_table_init` is called on caller-owned memory the
/// collector never sees.
fn tableInitImpl(table: *c.JanetTable, capacity_in: i32, stackalloc: bool) *c.JanetTable {
    const capacity = janet_tablen(capacity_in);
    if (stackalloc) table.gc.flags = table_flag_stack;
    if (capacity != 0) {
        const data: [*c]c.JanetKV = if (stackalloc)
            memallocEmptyLocal(capacity)
        else
            @ptrCast(@alignCast(janet_memalloc_empty(capacity) orelse c.janet_zig_out_of_memory()));
        table.data = data;
        table.capacity = capacity;
    } else {
        table.data = null;
        table.capacity = 0;
    }
    table.count = 0;
    table.deleted = 0;
    table.proto = null;
    return table;
}

/// Initialise a caller-owned table whose buckets come from scratch memory.
export fn janet_table_init(table: *c.JanetTable, capacity: i32) callconv(.c) *c.JanetTable {
    return tableInitImpl(table, capacity, true);
}

/// Initialise a caller-owned table whose buckets come from the ordinary heap.
export fn janet_table_init_raw(table: *c.JanetTable, capacity: i32) callconv(.c) *c.JanetTable {
    return tableInitImpl(table, capacity, false);
}

/// Release a table's bucket array to whichever allocator produced it. Also
/// called from `janet_deinit_block` in `gc_sweep.zig`, which is the collectable
/// table's only route here -- so a table's allocate/release round trip is now
/// entirely inside Zig, as a buffer's became in Part 6a.
export fn janet_table_deinit(table: *c.JanetTable) callconv(.c) void {
    if ((table.gc.flags & table_flag_stack) != 0) {
        c.janet_sfree(@ptrCast(table.data));
    } else {
        c.janet_free(@ptrCast(table.data));
    }
}

/// Allocate a collectable table with strong references to keys and values.
export fn janet_table(capacity: i32) callconv(.c) *c.JanetTable {
    const table: *c.JanetTable = @ptrCast(@alignCast(c.janet_gcalloc(c.JANET_MEMORY_TABLE, @sizeOf(c.JanetTable))));
    return tableInitImpl(table, capacity, false);
}

/// The three weak variants differ from `janet_table` only in their memory type,
/// which is what puts them on `janet_vm.weak_blocks` instead of
/// `janet_vm.blocks` and tells `gc_sweep.zig` which half of each pair to drop
/// when its referent is unreachable.
export fn janet_table_weakk(capacity: i32) callconv(.c) *c.JanetTable {
    const table: *c.JanetTable = @ptrCast(@alignCast(c.janet_gcalloc(c.JANET_MEMORY_TABLE_WEAKK, @sizeOf(c.JanetTable))));
    return tableInitImpl(table, capacity, false);
}

export fn janet_table_weakv(capacity: i32) callconv(.c) *c.JanetTable {
    const table: *c.JanetTable = @ptrCast(@alignCast(c.janet_gcalloc(c.JANET_MEMORY_TABLE_WEAKV, @sizeOf(c.JanetTable))));
    return tableInitImpl(table, capacity, false);
}

export fn janet_table_weakkv(capacity: i32) callconv(.c) *c.JanetTable {
    const table: *c.JanetTable = @ptrCast(@alignCast(c.janet_gcalloc(c.JANET_MEMORY_TABLE_WEAKKV, @sizeOf(c.JanetTable))));
    return tableInitImpl(table, capacity, false);
}

/// Find the bucket holding `key`, or the bucket it should go in.
export fn janet_table_find(t: *c.JanetTable, key: c.Janet) callconv(.c) [*c]c.JanetKV {
    return @constCast(janet_dict_find(t.data, t.capacity, key));
}

/// Move a table's contents into a bucket array of `size` buckets.
///
/// Tombstones are not carried over, which is the only thing that ever reclaims
/// them: `deleted` is reset to zero and only live pairs are re-inserted. The
/// new array is published into `t->data` before the loop runs, because
/// `janet_table_find` reads it -- which is also why a signal raised out of a
/// key comparison here strands the old array.
fn tableRehash(t: *c.JanetTable, size: i32) void {
    const olddata = t.data;
    const islocal = (t.gc.flags & table_flag_stack) != 0;
    const newdata: [*c]c.JanetKV = if (islocal)
        memallocEmptyLocal(size)
    else
        @ptrCast(@alignCast(janet_memalloc_empty(size) orelse c.janet_zig_out_of_memory()));
    const oldcapacity = t.capacity;
    t.data = newdata;
    t.capacity = size;
    t.deleted = 0;
    var i: i32 = 0;
    while (i < oldcapacity) : (i += 1) {
        const kv = &olddata[@intCast(i)];
        if (!isNilKey(kv.key)) {
            const newkv = janet_table_find(t, kv.key);
            newkv.* = kv.*;
        }
    }
    if (islocal) {
        c.janet_sfree(@ptrCast(olddata));
    } else {
        c.janet_free(@ptrCast(olddata));
    }
}

/// Look up a key, following prototypes to a fixed depth.
export fn janet_table_get(t_in: *c.JanetTable, key: c.Janet) callconv(.c) c.Janet {
    var t: ?*c.JanetTable = t_in;
    var i: c_int = c.JANET_MAX_PROTO_DEPTH;
    while (t != null and i != 0) : ({
        t = t.?.proto;
        i -= 1;
    }) {
        const bucket = janet_table_find(t.?, key);
        if (bucket != null and !isNilKey(bucket.*.key)) return bucket.*.value;
    }
    return c.janet_wrap_nil();
}

/// Look up a keyword, symbol or string key given as raw bytes.
///
/// Used by the compiler to read the core environment without interning a
/// symbol first. `janet_dict_find_keyword` hashes the bytes the way a string
/// is hashed and compares byte-wise, so it finds the same bucket the interned
/// key would.
export fn janet_table_get_keyword(t_in: *c.JanetTable, keyword: [*c]const u8) callconv(.c) c.Janet {
    const keyword_len: i32 = @intCast(c.strlen(keyword));
    var t: ?*c.JanetTable = t_in;
    var i: c_int = c.JANET_MAX_PROTO_DEPTH;
    while (t != null and i != 0) : ({
        t = t.?.proto;
        i -= 1;
    }) {
        const bucket = janet_dict_find_keyword(t.?.data, t.?.capacity, keyword, keyword_len);
        if (bucket != null and !isNilKey(bucket.*.key)) return bucket.*.value;
    }
    return c.janet_wrap_nil();
}

/// Look up a key and report which table in the prototype chain held it.
export fn janet_table_get_ex(t_in: *c.JanetTable, key: c.Janet, which: [*c]?*c.JanetTable) callconv(.c) c.Janet {
    var t: ?*c.JanetTable = t_in;
    var i: c_int = c.JANET_MAX_PROTO_DEPTH;
    while (t != null and i != 0) : ({
        t = t.?.proto;
        i -= 1;
    }) {
        const bucket = janet_table_find(t.?, key);
        if (bucket != null and !isNilKey(bucket.*.key)) {
            which.* = t;
            return bucket.*.value;
        }
    }
    return c.janet_wrap_nil();
}

/// Look up a key in this table only.
export fn janet_table_rawget(t: *c.JanetTable, key: c.Janet) callconv(.c) c.Janet {
    const bucket = janet_table_find(t, key);
    if (bucket != null and !isNilKey(bucket.*.key)) return bucket.*.value;
    return c.janet_wrap_nil();
}

/// Remove a key and return the value it held.
///
/// The bucket is left with a nil key and a *false* value, which is the
/// tombstone: `janet_dict_find` stops only at a bucket whose key and value are
/// both nil, so the hole does not truncate a probe run through it. `deleted`
/// counts tombstones and is what eventually forces a rehash.
export fn janet_table_remove(t: *c.JanetTable, key: c.Janet) callconv(.c) c.Janet {
    const bucket = janet_table_find(t, key);
    if (bucket != null and !isNilKey(bucket.*.key)) {
        const ret = bucket.*.value;
        t.count -= 1;
        t.deleted += 1;
        bucket.*.key = c.janet_wrap_nil();
        bucket.*.value = c.janet_wrap_false();
        return ret;
    }
    return c.janet_wrap_nil();
}

/// Insert, update or remove a pair.
///
/// A nil value is a removal rather than a stored nil, which is the same rule
/// that makes a table's absent keys and its nil-valued keys indistinguishable.
/// Growth is triggered when the live pairs *plus the tombstones* would pass
/// half the capacity, so a table that is churned rather than grown still
/// rehashes and reclaims its tombstones.
export fn janet_table_put(t: *c.JanetTable, key: c.Janet, value: c.Janet) callconv(.c) void {
    if (isUnstorableKey(key)) return;
    if (c.janet_checktype(value, c.JANET_NIL) != 0) {
        _ = janet_table_remove(t, key);
        return;
    }
    var bucket = janet_table_find(t, key);
    if (bucket != null and !isNilKey(bucket.*.key)) {
        bucket.*.value = value;
        return;
    }
    if (bucket == null or 2 *% (t.count +% t.deleted +% 1) > t.capacity) {
        tableRehash(t, janet_tablen(2 *% t.count +% 2));
    }
    bucket = janet_table_find(t, key);
    // A boolean in an empty bucket's value is the tombstone marker, so filling
    // that bucket would retire one. It never happens: `janet_dict_find` returns
    // a remembered tombstone only when the array holds no empty bucket at all,
    // and the growth test above keeps the array at most half full counting
    // tombstones. So a rehash is the only thing that ever reclaims one, and
    // this branch is dead. `FOUND.md` records it. Kept, because the port
    // reproduces rather than tidies.
    if (c.janet_checktype(bucket.*.value, c.JANET_BOOLEAN) != 0) t.deleted -= 1;
    bucket.*.key = key;
    bucket.*.value = value;
    t.count += 1;
}

/// Insert only if the key is absent. Internal, so the key is not validated --
/// every caller is copying pairs that a table or struct already accepted.
fn tablePutNoOverwrite(t: *c.JanetTable, key: c.Janet, value: c.Janet) void {
    var bucket = janet_table_find(t, key);
    if (bucket != null and !isNilKey(bucket.*.key)) return;
    if (bucket == null or 2 *% (t.count +% t.deleted +% 1) > t.capacity) {
        tableRehash(t, janet_tablen(2 *% t.count +% 2));
    }
    bucket = janet_table_find(t, key);
    if (c.janet_checktype(bucket.*.value, c.JANET_BOOLEAN) != 0) t.deleted -= 1;
    bucket.*.key = key;
    bucket.*.value = value;
    t.count += 1;
}

/// Empty a table without releasing its bucket array. The capacity survives, and
/// so does the prototype.
export fn janet_table_clear(t: *c.JanetTable) callconv(.c) void {
    janet_memempty(t.data, t.capacity);
    t.count = 0;
    t.deleted = 0;
}

/// Copy a table, bucket array and all.
///
/// The layout is copied verbatim rather than rebuilt, so the clone keeps the
/// original's tombstones and its `deleted` count along with its pairs. The
/// prototype is shared, not copied.
///
/// `safe_memcpy` rather than `memcpy`: an empty table has a null `data` and a
/// zero capacity, and `memcpy(dst, NULL, 0)` is undefined behaviour the C
/// original reaches from `(table/clone @{})`. `FOUND.md` has it. Nothing
/// observable differs.
export fn janet_table_clone(table: *c.JanetTable) callconv(.c) *c.JanetTable {
    const new_table: *c.JanetTable = @ptrCast(@alignCast(c.janet_gcalloc(c.JANET_MEMORY_TABLE, @sizeOf(c.JanetTable))));
    new_table.count = table.count;
    new_table.capacity = table.capacity;
    new_table.deleted = table.deleted;
    new_table.proto = table.proto;
    const bytes = asSize(new_table.capacity) *% @sizeOf(c.JanetKV);
    new_table.data = @ptrCast(@alignCast(c.janet_malloc(bytes) orelse c.janet_zig_out_of_memory()));
    safe_memcpy(@ptrCast(new_table.data), @ptrCast(table.data), asSize(table.capacity) *% @sizeOf(c.JanetKV));
    return new_table;
}

/// Copy every live pair out of a bucket array into a table.
fn tableMergeKV(table: *c.JanetTable, kvs: [*c]const c.JanetKV, cap: i32) void {
    var i: i32 = 0;
    while (i < cap) : (i += 1) {
        const kv = &kvs[@intCast(i)];
        if (!isNilKey(kv.key)) janet_table_put(table, kv.key, kv.value);
    }
}

/// Merge another table's own pairs in. Its prototype is not consulted.
export fn janet_table_merge_table(table: *c.JanetTable, other: *c.JanetTable) callconv(.c) void {
    tableMergeKV(table, other.data, other.capacity);
}

/// Merge a struct's own pairs in. Its prototype is not consulted.
export fn janet_table_merge_struct(table: *c.JanetTable, other: [*c]const c.JanetKV) callconv(.c) void {
    tableMergeKV(table, other, structHead(other).capacity);
}

/// Freeze a table's own pairs into a struct.
///
/// The struct is begun at `count` rather than at `capacity`, so tombstones cost
/// nothing here. The prototype is not carried; `table/to-struct` takes the
/// struct's prototype as a separate argument.
export fn janet_table_to_struct(t: *c.JanetTable) callconv(.c) [*c]const c.JanetKV {
    const st = janet_struct_begin(t.count);
    var kv = t.data;
    const end = t.data + @as(usize, @intCast(t.capacity));
    while (@intFromPtr(kv) < @intFromPtr(end)) : (kv += 1) {
        if (!isNilKey(kv.*.key)) janet_struct_put(st, kv.*.key, kv.*.value);
    }
    return janet_struct_end(st);
}

/// Collapse a prototype chain into one table.
///
/// Walked child first with `tablePutNoOverwrite`, so a binding nearer the child
/// wins -- the same precedence a lookup through the chain would have given. The
/// chain is followed to its end rather than to `JANET_MAX_PROTO_DEPTH`, so a
/// cyclic prototype chain does not terminate here. That is the C behaviour and
/// it is left alone: `table/setproto` accepts a cycle, and the lookup paths
/// that bound their depth are the reason it is otherwise survivable.
export fn janet_table_proto_flatten(t_in: *c.JanetTable) callconv(.c) *c.JanetTable {
    const new_table = janet_table(0);
    var t: ?*c.JanetTable = t_in;
    while (t != null) : (t = t.?.proto) {
        var kv = t.?.data;
        const end = t.?.data + @as(usize, @intCast(t.?.capacity));
        while (@intFromPtr(kv) < @intFromPtr(end)) : (kv += 1) {
            if (!isNilKey(kv.*.key)) tablePutNoOverwrite(new_table, kv.*.key, kv.*.value);
        }
    }
    return new_table;
}

// ==========================================================================
// struct/* and table/*, the cfunction surfaces.
//
// Phase 10 Part 6, on the same footing as every other cfunction this phase
// moves: a `JanetCFunction` has no error channel in its signature, so these
// deliver a raise as the jump their C caller expects whatever language they
// are written in, and the file's jump-transparent marker is what makes that
// legal. Nothing below holds anything across a call that can raise.
// ==========================================================================

fn cfunStructWithProto(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 1, -1);
    const proto = try arglayer.optStruct(argv, argc, 0, null);
    if (argc & 1 == 0) return raise.panic("expected odd number of arguments");
    const st = c.janet_struct_begin(@divTrunc(argc, 2));
    var i: i32 = 1;
    while (i < argc) : (i += 2) {
        c.janet_struct_put(st, argv[@intCast(i)], argv[@intCast(i + 1)]);
    }
    structHead(st).proto = proto;
    return c.janet_wrap_struct(c.janet_struct_end(st));
}

fn cfunStructGetproto(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    const st = try arglayer.getStruct(argv, 0);
    const proto = structHead(st).proto;
    return if (proto != null) c.janet_wrap_struct(proto) else c.janet_wrap_nil();
}

/// The bound is an upper one and deliberately loose: a key that appears in
/// both a struct and its prototype is counted twice, so the accumulator is
/// over-allocated rather than resized. `janet_struct_end` compacts it.
fn cfunStructFlatten(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    const st = try arglayer.getStruct(argv, 0);

    var pair_count: i64 = 0;
    var cursor = st;
    while (cursor != null) {
        pair_count += structHead(cursor).length;
        cursor = structHead(cursor).proto;
    }
    if (pair_count > std.math.maxInt(i32)) return raise.panic("struct too large");

    const accum = c.janet_struct_begin(@intCast(pair_count));
    cursor = st;
    while (cursor != null) {
        var i: i32 = 0;
        while (i < structHead(cursor).capacity) : (i += 1) {
            const kv = &cursor[@intCast(i)];
            if (c.janet_checktype(kv.key, c.JANET_NIL) == 0) {
                janet_struct_put_ext(accum, kv.key, kv.value, 0);
            }
        }
        cursor = structHead(cursor).proto;
    }
    return c.janet_wrap_struct(c.janet_struct_end(accum));
}

/// The loop is a `do`/`while` in C and the difference matters: a struct with
/// no prototype still produces one table, and `recursive` only decides whether
/// the walk continues past the first.
fn cfunStructToTable(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 1, 2);
    const st = try arglayer.getStruct(argv, 0);
    const recursive = argc > 1 and c.janet_truthy(argv[1]) != 0;
    var tab: [*c]c.JanetTable = null;
    var cursor = st;
    var tab_cursor: [*c]c.JanetTable = null;
    while (true) {
        if (tab != null) {
            tab_cursor.*.proto = c.janet_table(structHead(cursor).length);
            tab_cursor = tab_cursor.*.proto;
        } else {
            tab = c.janet_table(structHead(cursor).length);
            tab_cursor = tab;
        }
        var i: i32 = 0;
        while (i < structHead(cursor).capacity) : (i += 1) {
            const kv = &cursor[@intCast(i)];
            if (c.janet_checktype(kv.key, c.JANET_NIL) == 0) {
                c.janet_table_put(tab_cursor, kv.key, kv.value);
            }
        }
        cursor = structHead(cursor).proto;
        if (!(recursive and cursor != null)) break;
    }
    return c.janet_wrap_table(tab);
}

fn cfunStructRawget(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 2);
    const st = try arglayer.getStruct(argv, 0);
    return c.janet_struct_rawget(st, argv[1]);
}

export fn janet_lib_struct(env: *c.JanetTable) callconv(.c) void {
    const entries = [_]corefn.Entry{
        corefn.reg("struct/with-proto", &cfunStructWithProto, @src(), "(struct/with-proto proto & kvs)", "Create a structure, as with the usual struct constructor but set the " ++
            "struct prototype as well."),
        corefn.reg("struct/getproto", &cfunStructGetproto, @src(), "(struct/getproto st)", "Return the prototype of a struct, or nil if it doesn't have one."),
        corefn.reg("struct/proto-flatten", &cfunStructFlatten, @src(), "(struct/proto-flatten st)", "Convert a struct with prototypes to a struct with no prototypes by merging " ++
            "all key value pairs from recursive prototypes into one new struct."),
        corefn.reg("struct/to-table", &cfunStructToTable, @src(), "(struct/to-table st &opt recursive)", "Convert a struct to a table. If recursive is true, also convert the " ++
            "table's prototypes into the new struct's prototypes as well."),
        corefn.reg("struct/rawget", &cfunStructRawget, @src(), "(struct/rawget st key)", "Gets a value from a struct `st` without looking at the prototype struct. " ++
            "If `st` does not contain the key directly, the function will return " ++
            "nil without checking the prototype. Returns the value in the struct."),
        corefn.end,
    };
    corefn.install(env, &entries);
}

fn cfunTableNew(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    return c.janet_wrap_table(c.janet_table(try arglayer.getNat(argv, 0)));
}

fn cfunTableWeak(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    return c.janet_wrap_table(janet_table_weakkv(try arglayer.getNat(argv, 0)));
}

fn cfunTableWeakKeys(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    return c.janet_wrap_table(janet_table_weakk(try arglayer.getNat(argv, 0)));
}

fn cfunTableWeakValues(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    return c.janet_wrap_table(janet_table_weakv(try arglayer.getNat(argv, 0)));
}

fn cfunTableGetproto(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    const t = try arglayer.getTable(argv, 0);
    return if (t.*.proto != null) c.janet_wrap_table(t.*.proto) else c.janet_wrap_nil();
}

/// An explicit nil clears the prototype rather than faulting, which is why the
/// second argument is tested before it is fetched instead of going through
/// `janet_opttable` -- that would build an empty table for the default.
fn cfunTableSetproto(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 2);
    const table = try arglayer.getTable(argv, 0);
    var proto: [*c]c.JanetTable = null;
    if (c.janet_checktype(argv[1], c.JANET_NIL) == 0) proto = try arglayer.getTable(argv, 1);
    table.*.proto = proto;
    return argv[0];
}

fn cfunTableTostruct(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 1, 2);
    const t = try arglayer.getTable(argv, 0);
    const proto = try arglayer.optStruct(argv, argc, 1, null);
    const st = janet_table_to_struct(t);
    structHead(st).proto = proto;
    return c.janet_wrap_struct(st);
}

fn cfunTableRawget(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 2);
    return janet_table_rawget(try arglayer.getTable(argv, 0), argv[1]);
}

fn cfunTableClone(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    return c.janet_wrap_table(janet_table_clone(try arglayer.getTable(argv, 0)));
}

fn cfunTableClear(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    const table = try arglayer.getTable(argv, 0);
    janet_table_clear(table);
    return c.janet_wrap_table(table);
}

fn cfunTableProtoFlatten(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    return c.janet_wrap_table(janet_table_proto_flatten(try arglayer.getTable(argv, 0)));
}

export fn janet_lib_table(env: *c.JanetTable) callconv(.c) void {
    const entries = [_]corefn.Entry{
        corefn.reg("table/new", &cfunTableNew, @src(), "(table/new capacity)", "Creates a new empty table with pre-allocated memory " ++
            "for `capacity` entries. This means that if one knows the number of " ++
            "entries going into a table on creation, extra memory allocation " ++
            "can be avoided. " ++
            "Returns the new table."),
        corefn.reg("table/weak", &cfunTableWeak, @src(), "(table/weak capacity)", "Creates a new empty table with weak references to keys and values. Similar to `table/new`. " ++
            "Returns the new table."),
        corefn.reg("table/weak-keys", &cfunTableWeakKeys, @src(), "(table/weak-keys capacity)", "Creates a new empty table with weak references to keys and normal references to values. Similar to `table/new`. " ++
            "Returns the new table."),
        corefn.reg("table/weak-values", &cfunTableWeakValues, @src(), "(table/weak-values capacity)", "Creates a new empty table with normal references to keys and weak references to values. Similar to `table/new`. " ++
            "Returns the new table."),
        corefn.reg("table/to-struct", &cfunTableTostruct, @src(), "(table/to-struct tab &opt proto)", "Convert a table to a struct. Returns a new struct."),
        corefn.reg("table/getproto", &cfunTableGetproto, @src(), "(table/getproto tab)", "Get the prototype table of a table. Returns nil if the table " ++
            "has no prototype, otherwise returns the prototype."),
        corefn.reg("table/setproto", &cfunTableSetproto, @src(), "(table/setproto tab proto)", "Set the prototype of a table. Returns the original table `tab`."),
        corefn.reg("table/rawget", &cfunTableRawget, @src(), "(table/rawget tab key)", "Gets a value from a table `tab` without looking at the prototype table. " ++
            "If `tab` does not contain the key directly, the function will return " ++
            "nil without checking the prototype. Returns the value in the table."),
        corefn.reg("table/clone", &cfunTableClone, @src(), "(table/clone tab)", "Create a copy of a table. Updates to the new table will not change the old table, " ++
            "and vice versa."),
        corefn.reg("table/clear", &cfunTableClear, @src(), "(table/clear tab)", "Remove all key-value pairs in a table and return the modified table `tab`."),
        corefn.reg("table/proto-flatten", &cfunTableProtoFlatten, @src(), "(table/proto-flatten tab)", "Create a new table that is the result of merging all prototypes into a new table."),
        corefn.end,
    };
    corefn.install(env, &entries);
}
