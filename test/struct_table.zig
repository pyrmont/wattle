//! Behavioral contract for the key/value containers: structs and tables,
//! including the three weak table variants.
//!
//! The two share the `JanetKV` bucket layout and nothing else about how they
//! use it, so this file is organised around the two probing disciplines rather
//! than around the two halves of the subsystem.
//!
//! A struct's layout is observable and is part of the language contract. Robin
//! Hood insertion exists so that the bucket array depends on the *set* of
//! pairs and not on the order they arrived in, because `janet_struct_end`
//! hashes the array -- `{1 2 3 4}` and `{3 4 1 2}` must be byte-for-byte
//! identical or they would not be `=`. So the struct cases compare whole
//! bucket arrays position by position rather than asserting properties of one
//! of them -- see `sameLayout`, which explains why that is not a `memcmp`.
//!
//! A table's layout is *not* observable and depends on deletion history as
//! well as insertion order. What is checkable there is the policy: the exact
//! capacity after each growth, the tombstone a removal leaves, the fact that a
//! tombstone does not truncate a probe run through it, and the fact that
//! tombstones are reclaimed only by a rehash. Those are asserted as exact
//! numbers, because a policy asserted as an inequality passes for almost any
//! implementation.
//!
//! ## Where the head-layout assertion went
//!
//! The C original opened with `sizeof(JanetStructHead) ==
//! offsetof(JanetStructHead, data)`. `@cImport` drops a flexible array member,
//! so `@offsetOf` does not compile and `c.janet_struct_head` recovers the
//! header with `@sizeOf` -- a translation would compare `@sizeOf` with itself.
//! Phase 11 Part 8 built both replacements: `test/abi.c` keeps the static
//! assertion, because the claim is about `janet.h`, and `test/gc_mark.zig`'s
//! `theHeadOffsets` derives the struct head's offset from the allocator.
//!
//! ## Three things deliberately not covered
//!
//! Weak tables are checked only for the memory type their constructor stamps
//! and for the heap list that type puts them on. What the collector then does
//! with them belongs to `test/gc_sweep.zig`, which already has it.
//!
//! `janet_table_proto_flatten` walks a prototype chain to its end rather than
//! to `JANET_MAX_PROTO_DEPTH`, so a cyclic chain does not terminate.
//! `FOUND.md` records it. No assertion can pin a hang.

const std = @import("std");
const abi = @import("abi");
const c = abi.c;
const harness = @import("harness.zig");

const heap = harness.heap;
const internal = harness.internal;

// --------------------------------------------------------------- helpers

fn structHead(st: [*c]const c.JanetKV) *c.JanetStructHead {
    return c.janet_struct_head(st);
}

fn structLength(st: [*c]const c.JanetKV) i32 {
    return structHead(st).length;
}

fn structCapacity(st: [*c]const c.JanetKV) i32 {
    return structHead(st).capacity;
}

fn structHash(st: [*c]const c.JanetKV) i32 {
    return structHead(st).hash;
}

fn structProto(st: [*c]const c.JanetKV) [*c]const c.JanetKV {
    return structHead(st).proto;
}

fn setStructProto(st: [*c]c.JanetKV, proto: [*c]const c.JanetKV) void {
    structHead(st).proto = proto;
}

fn kw(name: [*:0]const u8) c.Janet {
    return c.janet_ckeywordv(name);
}

/// The bucket a key would like to occupy. Spelled out rather than reusing
/// `janet_maphash`, so that a change to that macro shows up as a failure
/// rather than being tracked silently.
fn idealIndex(capacity: i32, key: c.Janet) i32 {
    const hash: u32 = @bitCast(c.janet_hash(key));
    const mask: u32 = @bitCast(capacity - 1);
    return @bitCast(hash & mask);
}

/// Fill `out` with distinct integer keys that all want the same bucket in an
/// array of `capacity` buckets, and return that bucket's index.
///
/// Searched rather than hard-coded on purpose. Janet's integer hash is a
/// different subsystem and changes outright under `-Dprf`, so a fixed pair of
/// colliding keys would silently stop colliding and every case built on it
/// would keep passing while testing nothing.
fn findColliding(capacity: i32, out: []c.Janet) i32 {
    var target: i32 = 0;
    while (target < capacity) : (target += 1) {
        var found: usize = 0;
        var i: i32 = 0;
        while (i < 200000 and found < out.len) : (i += 1) {
            const key = harness.wrapInteger(i);
            if (idealIndex(capacity, key) == target) {
                out[found] = key;
                found += 1;
            }
        }
        if (found == out.len) return target;
    }
    unreachable; // no set of colliding integer keys was found
}

/// Fill `out` with distinct integer keys whose ideal buckets are pairwise
/// *different*, which is the opposite need and has the same reason: so that a
/// case about accumulating tombstones is not quietly turned into a case about
/// reusing one.
fn findDistinctIndices(capacity: i32, out: []c.Janet) void {
    var used: [64]i32 = undefined;
    var found: usize = 0;
    std.debug.assert(out.len <= capacity and capacity <= 64);

    var i: i32 = 0;
    while (i < 200000 and found < out.len) : (i += 1) {
        const key = harness.wrapInteger(i);
        const index = idealIndex(capacity, key);
        var duplicate = false;
        for (used[0..found]) |seen| {
            if (seen == index) duplicate = true;
        }
        if (!duplicate) {
            used[found] = index;
            out[found] = key;
            found += 1;
        }
    }
    std.debug.assert(found == out.len);
}

/// Do two bucket arrays hold the same thing in the same place?
///
/// Deliberately not a byte comparison. Under `-Dnanbox=false` a `Janet` is a
/// struct with an eight-byte union and a four-byte type tag, so it carries
/// four bytes of tail padding that nothing ever writes -- two identical values
/// compare equal and differ byte for byte. A byte-wise comparison there fails
/// on garbage from the allocator rather than on layout, and passes or fails at
/// random. The layout claim is about which value sits in which bucket, so it
/// is asserted that way.
fn sameLayout(a: [*c]const c.JanetKV, b: [*c]const c.JanetKV, capacity: i32) bool {
    var i: usize = 0;
    while (i < capacity) : (i += 1) {
        if (c.janet_type(a[i].key) != c.janet_type(b[i].key)) return false;
        if (c.janet_type(a[i].value) != c.janet_type(b[i].value)) return false;
        if (!harness.equals(a[i].key, b[i].key)) return false;
        if (!harness.equals(a[i].value, b[i].value)) return false;
    }
    return true;
}

// ------------------------------------------------------ struct: allocation

/// The capacity policy. `janet_tablen` is a *strict* next power of two, so
/// twice the pair count is rounded up past itself: a two-pair struct gets
/// eight buckets, not four. Asserted as exact numbers because the load factor
/// is what bounds Robin Hood displacement, and an off-by-one-doubling would
/// still pass every functional case in this file.
fn structBeginCapacity() void {
    std.debug.assert(structCapacity(c.janet_struct_begin(0)) == 1);
    std.debug.assert(structCapacity(c.janet_struct_begin(1)) == 4);
    std.debug.assert(structCapacity(c.janet_struct_begin(2)) == 8);
    std.debug.assert(structCapacity(c.janet_struct_begin(3)) == 8);
    std.debug.assert(structCapacity(c.janet_struct_begin(4)) == 16);
}

fn structBeginInitialisesTheHead() void {
    const st = c.janet_struct_begin(3);
    std.debug.assert(structLength(st) == 3);
    std.debug.assert(structCapacity(st) == 8);
    // The hash field is a running count of filled slots until `end` runs.
    std.debug.assert(structHash(st) == 0);
    std.debug.assert(structProto(st) == null);
    var i: usize = 0;
    while (i < structCapacity(st)) : (i += 1) {
        std.debug.assert(harness.isType(st[i].key, c.JANET_NIL));
        std.debug.assert(harness.isType(st[i].value, c.JANET_NIL));
    }
    std.debug.assert(heap.memoryType(structHead(st)) == c.JANET_MEMORY_STRUCT);
    std.debug.assert(heap.onList(c.janet_vm.blocks, structHead(st)));
    std.debug.assert(!heap.onList(c.janet_vm.weak_blocks, structHead(st)));
}

// ------------------------------------------------------- struct: insertion

/// The whole reason Robin Hood insertion is here. Two structs built from the
/// same pairs in different orders must have identical bucket arrays, because
/// `janet_struct_end` hashes the array and `janet_equals` compares the hash
/// first. Compared over the entire array rather than pair by pair, so that a
/// difference in *position* fails as loudly as a difference in contents.
fn structLayoutIsOrderIndependent() void {
    var keys: [6]c.Janet = undefined;
    for (&keys, 0..) |*key, i| key.* = harness.wrapInteger(@intCast(i * 37 + 11));

    const a = c.janet_struct_begin(6);
    for (keys, 0..) |key, i| c.janet_struct_put(a, key, harness.wrapInteger(@intCast(i)));
    const b = c.janet_struct_begin(6);
    var i: usize = 6;
    while (i > 0) {
        i -= 1;
        c.janet_struct_put(b, keys[i], harness.wrapInteger(@intCast(i)));
    }
    // And a third order that is neither forwards nor backwards.
    const d = c.janet_struct_begin(6);
    for ([6]usize{ 3, 0, 5, 1, 4, 2 }) |n| {
        c.janet_struct_put(d, keys[n], harness.wrapInteger(@intCast(n)));
    }

    const capacity = structCapacity(a);
    std.debug.assert(structCapacity(b) == capacity);
    std.debug.assert(structCapacity(d) == capacity);

    const sa = c.janet_struct_end(a);
    const sb = c.janet_struct_end(b);
    const sd = c.janet_struct_end(d);

    std.debug.assert(sameLayout(sa, sb, capacity));
    std.debug.assert(sameLayout(sa, sd, capacity));
    std.debug.assert(structHash(sa) == structHash(sb));
    std.debug.assert(structHash(sa) == structHash(sd));
    std.debug.assert(harness.equals(c.janet_wrap_struct(sa), c.janet_wrap_struct(sb)));
}

/// Order-independence alone does not pin the *direction* of the displacement
/// rule: inverting the comparison consistently still yields a layout that is a
/// function of the pair set. What pins the direction is a run of keys that all
/// want the same bucket, where every displacement comparison ties and the full
/// hash decides. The pair with the larger hash keeps the earlier slot.
fn structCollisionRunIsOrderedByHash() void {
    const st = c.janet_struct_begin(3);
    const capacity = structCapacity(st);
    var keys: [3]c.Janet = undefined;
    const index = findColliding(capacity, &keys);

    for (keys, 0..) |key, i| c.janet_struct_put(st, key, harness.wrapInteger(@intCast(i)));
    const s = c.janet_struct_end(st);

    var previous: i32 = 0;
    var n: i32 = 0;
    while (n < 3) : (n += 1) {
        const kv = &s[@intCast(@mod(index + n, capacity))];
        std.debug.assert(!harness.isType(kv.key, c.JANET_NIL));
        const hash = c.janet_hash(kv.key);
        if (n > 0) std.debug.assert(hash < previous);
        previous = hash;
    }

    // Inserted backwards, the run comes out the same.
    const st2 = c.janet_struct_begin(3);
    var i: usize = 3;
    while (i > 0) {
        i -= 1;
        c.janet_struct_put(st2, keys[i], harness.wrapInteger(@intCast(i)));
    }
    std.debug.assert(sameLayout(s, c.janet_struct_end(st2), capacity));
}

/// The last tiebreak, and the only one that reaches outside this subsystem.
///
/// `janet_hash` reads only the bytes for all three string-like types, so a
/// keyword and a string spelled the same have the same hash. They want the
/// same bucket, they tie on displacement and they tie on hash, so
/// `janet_compare` is the only thing left -- and the only thing stopping the
/// second from being taken for a duplicate of the first, which would silently
/// drop it.
fn structHashTieFallsThroughToCompare() void {
    const as_keyword = kw("tie");
    const as_string = c.janet_wrap_string(c.janet_cstring("tie"));
    std.debug.assert(c.janet_hash(as_keyword) == c.janet_hash(as_string));
    std.debug.assert(!harness.equals(as_keyword, as_string));
    // JANET_STRING sorts before JANET_KEYWORD, so the order is by type.
    std.debug.assert(c.janet_compare(as_string, as_keyword) == -1);

    const st = c.janet_struct_begin(2);
    c.janet_struct_put(st, as_keyword, harness.wrapInteger(1));
    c.janet_struct_put(st, as_string, harness.wrapInteger(2));
    // Both landed: neither was mistaken for the other.
    std.debug.assert(structHash(st) == 2);
    const s = c.janet_struct_end(st);
    std.debug.assert(structLength(s) == 2);
    std.debug.assert(harness.equals(c.janet_struct_rawget(s, as_keyword), harness.wrapInteger(1)));
    std.debug.assert(harness.equals(c.janet_struct_rawget(s, as_string), harness.wrapInteger(2)));

    const st2 = c.janet_struct_begin(2);
    c.janet_struct_put(st2, as_string, harness.wrapInteger(2));
    c.janet_struct_put(st2, as_keyword, harness.wrapInteger(1));
    std.debug.assert(sameLayout(s, c.janet_struct_end(st2), structCapacity(s)));
}

/// Every pair that lands moves the running count in the hash field.
fn structPutCountsInTheHashField() void {
    const st = c.janet_struct_begin(3);
    c.janet_struct_put(st, kw("a"), harness.wrapInteger(1));
    std.debug.assert(structHash(st) == 1);
    c.janet_struct_put(st, kw("b"), harness.wrapInteger(2));
    std.debug.assert(structHash(st) == 2);
    // A duplicate replaces rather than adds, so the count stands still.
    c.janet_struct_put(st, kw("a"), harness.wrapInteger(9));
    std.debug.assert(structHash(st) == 2);
}

fn structPutRejectsUnstorablePairs() void {
    const st = c.janet_struct_begin(4);
    c.janet_struct_put(st, c.janet_wrap_nil(), harness.wrapInteger(1));
    std.debug.assert(structHash(st) == 0);
    c.janet_struct_put(st, kw("k"), c.janet_wrap_nil());
    std.debug.assert(structHash(st) == 0);
    c.janet_struct_put(st, c.janet_wrap_number_safe(std.math.nan(f64)), harness.wrapInteger(1));
    std.debug.assert(structHash(st) == 0);
    // And one that is storable, so the three above are shown to be the reason
    // the count stayed at zero rather than the puts not working at all.
    c.janet_struct_put(st, kw("k"), harness.wrapInteger(1));
    std.debug.assert(structHash(st) == 1);
}

/// Past the declared length, a put is silently dropped.
fn structPutDropsTheSurplus() void {
    const st = c.janet_struct_begin(1);
    c.janet_struct_put(st, kw("a"), harness.wrapInteger(1));
    c.janet_struct_put(st, kw("b"), harness.wrapInteger(2));
    std.debug.assert(structHash(st) == 1);
    const s = c.janet_struct_end(st);
    std.debug.assert(structLength(s) == 1);
    std.debug.assert(harness.equals(c.janet_struct_rawget(s, kw("a")), harness.wrapInteger(1)));
    std.debug.assert(harness.isType(c.janet_struct_rawget(s, kw("b")), c.JANET_NIL));
}

/// `replace` is what separates `janet_struct_put` from the flattening path:
/// `struct/proto-flatten` walks child first and must not let a prototype's
/// binding overwrite the child's.
fn structPutExtHonoursReplace() void {
    const keep = c.janet_struct_begin(2);
    internal.janet_struct_put_ext(keep, kw("a"), harness.wrapInteger(1), 0);
    internal.janet_struct_put_ext(keep, kw("a"), harness.wrapInteger(2), 0);
    std.debug.assert(harness.equals(
        c.janet_struct_rawget(c.janet_struct_end(keep), kw("a")),
        harness.wrapInteger(1),
    ));

    const over = c.janet_struct_begin(2);
    internal.janet_struct_put_ext(over, kw("a"), harness.wrapInteger(1), 1);
    internal.janet_struct_put_ext(over, kw("a"), harness.wrapInteger(2), 1);
    std.debug.assert(harness.equals(
        c.janet_struct_rawget(c.janet_struct_end(over), kw("a")),
        harness.wrapInteger(2),
    ));
}

// ------------------------------------------------------------ struct: end

/// When fewer pairs land than were declared, the array is the wrong size for
/// its contents and the whole struct is rebuilt at the size that fit.
fn structEndRebuildsOnAShortCount() void {
    const proto = c.janet_struct_begin(1);
    c.janet_struct_put(proto, kw("p"), harness.wrapInteger(7));
    const sproto = c.janet_struct_end(proto);

    const st = c.janet_struct_begin(3);
    c.janet_struct_put(st, kw("a"), harness.wrapInteger(1));
    c.janet_struct_put(st, kw("a"), harness.wrapInteger(2));
    c.janet_struct_put(st, kw("b"), harness.wrapInteger(3));
    setStructProto(st, sproto);
    std.debug.assert(structCapacity(st) == 8);

    const s = c.janet_struct_end(st);
    std.debug.assert(s != st);
    std.debug.assert(structLength(s) == 2);
    std.debug.assert(structCapacity(s) == 8);
    std.debug.assert(harness.equals(c.janet_struct_rawget(s, kw("a")), harness.wrapInteger(2)));
    std.debug.assert(harness.equals(c.janet_struct_rawget(s, kw("b")), harness.wrapInteger(3)));
    // The prototype is not a bucket, so it is carried across by hand.
    std.debug.assert(structProto(s) == sproto);
}

fn structEndKeepsTheArrayWhenTheCountIsExact() void {
    const st = c.janet_struct_begin(2);
    c.janet_struct_put(st, kw("a"), harness.wrapInteger(1));
    c.janet_struct_put(st, kw("b"), harness.wrapInteger(2));
    std.debug.assert(c.janet_struct_end(st) == st);
}

/// The prototype contributes to the hash by a multiply, so it costs one read
/// rather than a walk -- and two structs with the same pairs and different
/// prototypes are distinguishable.
fn structEndFoldsThePrototypeIntoTheHash() void {
    const p = c.janet_struct_begin(1);
    c.janet_struct_put(p, kw("p"), harness.wrapInteger(1));
    const sp = c.janet_struct_end(p);

    const bare = c.janet_struct_begin(1);
    c.janet_struct_put(bare, kw("a"), harness.wrapInteger(1));
    const sbare = c.janet_struct_end(bare);

    const with = c.janet_struct_begin(1);
    c.janet_struct_put(with, kw("a"), harness.wrapInteger(1));
    setStructProto(with, sp);
    const swith = c.janet_struct_end(with);

    std.debug.assert(sameLayout(sbare, swith, structCapacity(sbare)));
    std.debug.assert(structHash(sbare) != structHash(swith));

    const buckets: u32 = @bitCast(internal.janet_kv_calchash(swith, structCapacity(swith)));
    const proto: u32 = @bitCast(structHash(sp));
    const expected: i32 = @bitCast(buckets +% 2654435761 *% proto);
    std.debug.assert(structHash(swith) == expected);
}

// ---------------------------------------------------------- struct: lookup

fn structFindReturnsAnEmptyBucketForAnAbsentKey() void {
    const st = c.janet_struct_begin(2);
    c.janet_struct_put(st, kw("a"), harness.wrapInteger(1));
    const s = c.janet_struct_end(st);

    const hit = c.janet_struct_find(s, kw("a"));
    std.debug.assert(hit != null);
    std.debug.assert(harness.equals(hit.*.value, harness.wrapInteger(1)));

    const miss = c.janet_struct_find(s, kw("zz"));
    std.debug.assert(miss != null);
    std.debug.assert(harness.isType(miss.*.key, c.JANET_NIL));
    std.debug.assert(harness.isType(c.janet_struct_rawget(s, kw("zz")), c.JANET_NIL));
}

/// Build a chain `depth` deep and return the deepest struct. Entry `i` holds
/// the key `i` and its prototype is entry `i - 1`.
fn structChain(depth: i32) [*c]const c.JanetKV {
    var proto: [*c]const c.JanetKV = null;
    var i: i32 = 0;
    while (i < depth) : (i += 1) {
        const st = c.janet_struct_begin(1);
        c.janet_struct_put(st, harness.wrapInteger(i), harness.wrapInteger(i));
        setStructProto(st, proto);
        proto = c.janet_struct_end(st);
    }
    return proto;
}

/// The chain walk is bounded, and the bound is enumerated rather than sampled:
/// the last reachable depth and the first unreachable one are both asserted.
fn structGetBoundsThePrototypeChain() void {
    const deep = structChain(c.JANET_MAX_PROTO_DEPTH + 5);
    // The head holds the highest key; the walk descends toward key 0.
    const top: i32 = c.JANET_MAX_PROTO_DEPTH + 4;
    std.debug.assert(harness.equals(
        c.janet_struct_get(deep, harness.wrapInteger(top)),
        harness.wrapInteger(top),
    ));
    const last: i32 = top - (c.JANET_MAX_PROTO_DEPTH - 1);
    std.debug.assert(harness.equals(
        c.janet_struct_get(deep, harness.wrapInteger(last)),
        harness.wrapInteger(last),
    ));
    std.debug.assert(harness.isType(
        c.janet_struct_get(deep, harness.wrapInteger(last - 1)),
        c.JANET_NIL,
    ));
    // rawget never leaves the head at all.
    std.debug.assert(harness.isType(
        c.janet_struct_rawget(deep, harness.wrapInteger(top - 1)),
        c.JANET_NIL,
    ));
}

fn structGetExReportsTheOwner() void {
    const p = c.janet_struct_begin(1);
    c.janet_struct_put(p, kw("a"), harness.wrapInteger(1));
    const sp = c.janet_struct_end(p);

    const ch = c.janet_struct_begin(1);
    c.janet_struct_put(ch, kw("b"), harness.wrapInteger(2));
    setStructProto(ch, sp);
    const sch = c.janet_struct_end(ch);

    var which: [*c]const c.JanetKV = null;
    std.debug.assert(harness.equals(
        c.janet_struct_get_ex(sch, kw("b"), &which),
        harness.wrapInteger(2),
    ));
    std.debug.assert(which == sch);
    which = null;
    std.debug.assert(harness.equals(
        c.janet_struct_get_ex(sch, kw("a"), &which),
        harness.wrapInteger(1),
    ));
    std.debug.assert(which == sp);
}

// ------------------------------------------------------ struct: conversion

/// The new table is sized from the struct's *capacity*, not its pair count,
/// which is why a two-pair struct becomes a sixteen-bucket table.
fn structToTable() void {
    const p = c.janet_struct_begin(1);
    c.janet_struct_put(p, kw("p"), harness.wrapInteger(9));
    const sp = c.janet_struct_end(p);

    const st = c.janet_struct_begin(2);
    c.janet_struct_put(st, kw("a"), harness.wrapInteger(1));
    c.janet_struct_put(st, kw("b"), harness.wrapInteger(2));
    setStructProto(st, sp);
    const s = c.janet_struct_end(st);

    const t = c.janet_struct_to_table(s);
    std.debug.assert(t.*.count == 2);
    std.debug.assert(t.*.capacity == internal.janet_tablen(structCapacity(s)));
    std.debug.assert(t.*.capacity == 16);
    std.debug.assert(harness.equals(c.janet_table_rawget(t, kw("a")), harness.wrapInteger(1)));
    std.debug.assert(harness.equals(c.janet_table_rawget(t, kw("b")), harness.wrapInteger(2)));
    // The prototype is not carried; `struct/to-table` rebuilds it itself.
    std.debug.assert(t.*.proto == null);
    std.debug.assert(harness.isType(c.janet_table_get(t, kw("p")), c.JANET_NIL));
}

// ------------------------------------------------------- table: allocation

/// `janet_tablen` rounds strictly up, so a requested capacity of zero still
/// gets one bucket -- there is no such thing as an empty bucket array reached
/// from a non-negative request.
///
/// A *negative* request produces one, and the resulting table cannot be looked
/// up in at all: `janet_maphash` masks the hash with `capacity - 1`, which for
/// a zero capacity is every bit set, so `janet_dict_find` treats the whole
/// hash as a bucket number and both of its loops are bounded by it rather than
/// by the capacity. Only a hash of exactly zero survives. `FOUND.md` records
/// it, with the reproducer. Nothing below touches such a table beyond its
/// fields, because the behaviour is undefined and a contract cannot pin it.
fn tableCapacityRounding() void {
    std.debug.assert(c.janet_table(0).*.capacity == 1);
    std.debug.assert(c.janet_table(1).*.capacity == 2);
    std.debug.assert(c.janet_table(4).*.capacity == 8);

    const empty = c.janet_table(-1);
    std.debug.assert(empty.*.capacity == 0);
    std.debug.assert(empty.*.data == null);
    std.debug.assert(empty.*.count == 0);
    std.debug.assert(empty.*.deleted == 0);
}

fn tableConstructorMarksAndLists() void {
    const Case = struct {
        make: *const @TypeOf(c.janet_table),
        memory: i32,
        weak: bool,
    };
    const cases = [_]Case{
        .{ .make = &c.janet_table, .memory = c.JANET_MEMORY_TABLE, .weak = false },
        .{ .make = &c.janet_table_weakk, .memory = c.JANET_MEMORY_TABLE_WEAKK, .weak = true },
        .{ .make = &c.janet_table_weakv, .memory = c.JANET_MEMORY_TABLE_WEAKV, .weak = true },
        .{ .make = &c.janet_table_weakkv, .memory = c.JANET_MEMORY_TABLE_WEAKKV, .weak = true },
    };
    for (cases) |case| {
        const t = case.make(4);
        std.debug.assert(heap.memoryType(t) == case.memory);
        std.debug.assert(t.*.capacity == 8);
        std.debug.assert(t.*.count == 0);
        std.debug.assert(t.*.deleted == 0);
        std.debug.assert(t.*.proto == null);
        // The memory type is what decides the heap list, and the two weak
        // variants of that decision are what the sweep depends on.
        std.debug.assert(heap.onList(c.janet_vm.weak_blocks, t) == case.weak);
        std.debug.assert(heap.onList(c.janet_vm.blocks, t) == !case.weak);
        // All four behave identically as dictionaries.
        c.janet_table_put(t, kw("a"), harness.wrapInteger(1));
        std.debug.assert(harness.equals(c.janet_table_rawget(t, kw("a")), harness.wrapInteger(1)));
    }
}

/// A scratch table is caller-owned memory whose buckets come from the scratch
/// allocator. The flag lives in the same word as the memory type, which is
/// safe only because such a table is never `janet_gcalloc`ed -- so the flag is
/// asserted as the whole word, not as a bit.
fn tableInitUsesScratchMemory() void {
    var local: c.JanetTable = undefined;
    @memset(std.mem.asBytes(&local), 0xEE);
    _ = c.janet_table_init(&local, 4);
    std.debug.assert(local.gc.flags == 0x10000);
    std.debug.assert(local.capacity == 8);
    std.debug.assert(local.count == 0);
    std.debug.assert(local.deleted == 0);
    std.debug.assert(local.proto == null);

    // Grow it, so the rehash takes the scratch branch too.
    var i: i32 = 0;
    while (i < 40) : (i += 1) {
        c.janet_table_put(&local, harness.wrapInteger(i), harness.wrapInteger(i * 2));
    }
    std.debug.assert(local.count == 40);
    std.debug.assert(local.gc.flags == 0x10000);
    i = 0;
    while (i < 40) : (i += 1) {
        std.debug.assert(harness.equals(
            c.janet_table_rawget(&local, harness.wrapInteger(i)),
            harness.wrapInteger(i * 2),
        ));
    }
    c.janet_table_deinit(&local);
}

fn tableInitRawLeavesTheFlagClear() void {
    var local: c.JanetTable = undefined;
    @memset(std.mem.asBytes(&local), 0);
    _ = c.janet_table_init_raw(&local, 4);
    std.debug.assert(local.gc.flags == 0);
    std.debug.assert(local.capacity == 8);
    c.janet_table_put(&local, kw("a"), harness.wrapInteger(1));
    std.debug.assert(harness.equals(c.janet_table_rawget(&local, kw("a")), harness.wrapInteger(1)));
    c.janet_table_deinit(&local);
}

// ---------------------------------------------------------- table: growth

/// The growth policy, as exact capacities. A rehash happens when twice the
/// live pairs plus the tombstones plus one would exceed the capacity, and the
/// new capacity is `janet_tablen(2 * count + 2)`.
fn tableGrowthCapacities() void {
    const t = c.janet_table(0);
    const expected = [9]i32{ 4, 4, 8, 8, 16, 16, 16, 16, 32 };
    for (expected, 0..) |capacity, n| {
        const i: i32 = @intCast(n);
        c.janet_table_put(t, harness.wrapInteger(i), harness.wrapInteger(i));
        std.debug.assert(t.*.count == i + 1);
        std.debug.assert(t.*.capacity == capacity);
    }
    var i: i32 = 0;
    while (i < 9) : (i += 1) {
        std.debug.assert(harness.equals(
            c.janet_table_rawget(t, harness.wrapInteger(i)),
            harness.wrapInteger(i),
        ));
    }
}

// --------------------------------------------------------- table: removal

/// A removal leaves a nil key and a *false* value. The falseness is the
/// tombstone marker: `janet_dict_find` stops only where key and value are both
/// nil, so a run of probes passes through the hole instead of ending at it.
fn removeLeavesATombstone() void {
    const t = c.janet_table(4);
    c.janet_table_put(t, kw("a"), harness.wrapInteger(1));
    const bucket = c.janet_table_find(t, kw("a"));
    std.debug.assert(!harness.isType(bucket.*.key, c.JANET_NIL));

    const gone = c.janet_table_remove(t, kw("a"));
    std.debug.assert(harness.equals(gone, harness.wrapInteger(1)));
    std.debug.assert(t.*.count == 0);
    std.debug.assert(t.*.deleted == 1);
    std.debug.assert(harness.isType(bucket.*.key, c.JANET_NIL));
    std.debug.assert(harness.isType(bucket.*.value, c.JANET_BOOLEAN));
    std.debug.assert(c.janet_truthy(bucket.*.value) == 0);

    // Removing an absent key changes nothing.
    std.debug.assert(harness.isType(c.janet_table_remove(t, kw("zz")), c.JANET_NIL));
    std.debug.assert(t.*.count == 0);
    std.debug.assert(t.*.deleted == 1);
}

/// The property the tombstone exists for. Two keys that want the same bucket,
/// the first removed: the second must still be found through the hole.
fn aTombstoneDoesNotTruncateAProbeRun() void {
    const t = c.janet_table(4);
    std.debug.assert(t.*.capacity == 8);
    var keys: [2]c.Janet = undefined;
    const index = findColliding(t.*.capacity, &keys);

    c.janet_table_put(t, keys[0], harness.wrapInteger(10));
    c.janet_table_put(t, keys[1], harness.wrapInteger(20));
    std.debug.assert(t.*.count == 2);
    std.debug.assert(t.*.capacity == 8);
    // The second key really did displace: it is not in its ideal bucket.
    std.debug.assert(c.janet_table_find(t, keys[1]) != t.*.data + @as(usize, @intCast(index)));

    _ = c.janet_table_remove(t, keys[0]);
    std.debug.assert(harness.equals(c.janet_table_rawget(t, keys[1]), harness.wrapInteger(20)));
    std.debug.assert(harness.isType(c.janet_table_rawget(t, keys[0]), c.JANET_NIL));
}

/// A rehash is the only thing that reclaims a tombstone.
///
/// It is tempting to expect re-inserting the key that was just removed to fill
/// its own hole, and the `--t->deleted` branch in `janet_table_put` reads as
/// though it does. It does not. `janet_dict_find` returns the first *truly*
/// empty bucket it reaches and falls back on a remembered tombstone only if
/// the array has no empty bucket anywhere -- and the growth policy keeps the
/// array at most half full counting tombstones, so an empty bucket always
/// exists. The re-inserted key therefore takes the slot *after* its own hole
/// and the tombstone stays. `FOUND.md` records the branch as unreachable.
fn tombstonesAreReclaimed() void {
    const t = c.janet_table(4);
    c.janet_table_put(t, kw("a"), harness.wrapInteger(1));
    const first = c.janet_table_find(t, kw("a"));
    _ = c.janet_table_remove(t, kw("a"));
    std.debug.assert(t.*.deleted == 1);
    c.janet_table_put(t, kw("a"), harness.wrapInteger(2));
    std.debug.assert(t.*.count == 1);
    std.debug.assert(t.*.deleted == 1);
    std.debug.assert(c.janet_table_find(t, kw("a")) != first);
    std.debug.assert(harness.isType(first.*.key, c.JANET_NIL));
    std.debug.assert(harness.isType(first.*.value, c.JANET_BOOLEAN));
    std.debug.assert(harness.equals(c.janet_table_rawget(t, kw("a")), harness.wrapInteger(2)));

    // Otherwise a tombstone is reclaimed only by a rehash, and the rehash is
    // driven by the tombstone count alone -- a table with no live pairs at all
    // still grows. Keys at pairwise-distinct ideal buckets, so that each
    // removal leaves a tombstone instead of the next insert reusing the last
    // one. Capacity 8 trips at `count + deleted >= 4`.
    const churned = c.janet_table(4);
    std.debug.assert(churned.*.capacity == 8);
    var keys: [5]c.Janet = undefined;
    findDistinctIndices(churned.*.capacity, &keys);
    for (keys[0..4], 0..) |key, i| {
        c.janet_table_put(churned, key, harness.wrapInteger(@intCast(i)));
        _ = c.janet_table_remove(churned, key);
    }
    std.debug.assert(churned.*.count == 0);
    std.debug.assert(churned.*.deleted == 4);
    std.debug.assert(churned.*.capacity == 8);

    c.janet_table_put(churned, keys[4], harness.wrapInteger(4));
    // `janet_tablen(2 * 0 + 2)` is 4: the new array is sized from the live
    // count, so a table that was only ever churned shrinks.
    std.debug.assert(churned.*.capacity == 4);
    std.debug.assert(churned.*.deleted == 0);
    std.debug.assert(churned.*.count == 1);
    std.debug.assert(harness.equals(
        c.janet_table_rawget(churned, keys[4]),
        harness.wrapInteger(4),
    ));
}

// -------------------------------------------------------- table: put rules

fn tablePutRejectsUnstorableKeys() void {
    const t = c.janet_table(4);
    c.janet_table_put(t, c.janet_wrap_nil(), harness.wrapInteger(1));
    std.debug.assert(t.*.count == 0);
    c.janet_table_put(t, c.janet_wrap_number_safe(std.math.nan(f64)), harness.wrapInteger(1));
    std.debug.assert(t.*.count == 0);
    c.janet_table_put(t, kw("k"), harness.wrapInteger(1));
    std.debug.assert(t.*.count == 1);
}

/// A nil value is a removal, not a stored nil. This is what makes an absent
/// key and a nil-valued key indistinguishable.
fn tablePutNilRemoves() void {
    const t = c.janet_table(4);
    c.janet_table_put(t, kw("a"), harness.wrapInteger(1));
    std.debug.assert(t.*.count == 1);
    c.janet_table_put(t, kw("a"), c.janet_wrap_nil());
    std.debug.assert(t.*.count == 0);
    std.debug.assert(t.*.deleted == 1);
    std.debug.assert(harness.isType(c.janet_table_rawget(t, kw("a")), c.JANET_NIL));

    // And a nil value for an absent key is not a removal of anything.
    c.janet_table_put(t, kw("zz"), c.janet_wrap_nil());
    std.debug.assert(t.*.count == 0);
    std.debug.assert(t.*.deleted == 1);
}

fn tablePutUpdatesInPlace() void {
    const t = c.janet_table(4);
    c.janet_table_put(t, kw("a"), harness.wrapInteger(1));
    const bucket = c.janet_table_find(t, kw("a"));
    const capacity = t.*.capacity;
    c.janet_table_put(t, kw("a"), harness.wrapInteger(2));
    std.debug.assert(t.*.count == 1);
    std.debug.assert(t.*.capacity == capacity);
    std.debug.assert(c.janet_table_find(t, kw("a")) == bucket);
    std.debug.assert(harness.equals(bucket.*.value, harness.wrapInteger(2)));
}

// ----------------------------------------------------------- table: lookup

fn tableGetBoundsThePrototypeChain() void {
    var deep: [*c]c.JanetTable = null;
    var i: i32 = 0;
    while (i < c.JANET_MAX_PROTO_DEPTH + 5) : (i += 1) {
        const t = c.janet_table(1);
        c.janet_table_put(t, harness.wrapInteger(i), harness.wrapInteger(i));
        t.*.proto = deep;
        deep = t;
    }
    const top: i32 = c.JANET_MAX_PROTO_DEPTH + 4;
    std.debug.assert(harness.equals(
        c.janet_table_get(deep, harness.wrapInteger(top)),
        harness.wrapInteger(top),
    ));
    const last: i32 = top - (c.JANET_MAX_PROTO_DEPTH - 1);
    std.debug.assert(harness.equals(
        c.janet_table_get(deep, harness.wrapInteger(last)),
        harness.wrapInteger(last),
    ));
    std.debug.assert(harness.isType(
        c.janet_table_get(deep, harness.wrapInteger(last - 1)),
        c.JANET_NIL,
    ));
    std.debug.assert(harness.isType(
        c.janet_table_rawget(deep, harness.wrapInteger(top - 1)),
        c.JANET_NIL,
    ));
}

fn tableGetExReportsTheOwner() void {
    const proto = c.janet_table(2);
    c.janet_table_put(proto, kw("a"), harness.wrapInteger(1));
    const child = c.janet_table(2);
    c.janet_table_put(child, kw("b"), harness.wrapInteger(2));
    child.*.proto = proto;

    var which: [*c]c.JanetTable = null;
    std.debug.assert(harness.equals(
        c.janet_table_get_ex(child, kw("b"), &which),
        harness.wrapInteger(2),
    ));
    std.debug.assert(which == child);
    which = null;
    std.debug.assert(harness.equals(
        c.janet_table_get_ex(child, kw("a"), &which),
        harness.wrapInteger(1),
    ));
    std.debug.assert(which == proto);
}

/// Looking a key up from raw bytes, without interning it first. Used by the
/// compiler against the core environment.
fn tableGetKeyword() void {
    const proto = c.janet_table(4);
    c.janet_table_put(proto, kw("deep"), harness.wrapInteger(2));
    const t = c.janet_table(4);
    c.janet_table_put(t, kw("hello"), harness.wrapInteger(1));
    t.*.proto = proto;

    std.debug.assert(harness.equals(
        internal.janet_table_get_keyword(t, "hello"),
        harness.wrapInteger(1),
    ));
    std.debug.assert(harness.equals(
        internal.janet_table_get_keyword(t, "deep"),
        harness.wrapInteger(2),
    ));
    std.debug.assert(harness.isType(internal.janet_table_get_keyword(t, "missing"), c.JANET_NIL));
    // A prefix of a present key is not that key.
    std.debug.assert(harness.isType(internal.janet_table_get_keyword(t, "hell"), c.JANET_NIL));
}

// -------------------------------------------------------- table: wholesale

/// Clearing keeps the bucket array and the prototype, and drops both counts.
fn tableClear() void {
    const proto = c.janet_table(2);
    const t = c.janet_table(4);
    t.*.proto = proto;
    var i: i32 = 0;
    while (i < 6) : (i += 1) c.janet_table_put(t, harness.wrapInteger(i), harness.wrapInteger(i));
    _ = c.janet_table_remove(t, harness.wrapInteger(0));
    const capacity = t.*.capacity;
    const data = t.*.data;
    std.debug.assert(t.*.deleted == 1);

    c.janet_table_clear(t);
    std.debug.assert(t.*.count == 0);
    std.debug.assert(t.*.deleted == 0);
    std.debug.assert(t.*.capacity == capacity);
    std.debug.assert(t.*.data == data);
    std.debug.assert(t.*.proto == proto);
    var n: usize = 0;
    while (n < capacity) : (n += 1) {
        std.debug.assert(harness.isType(data[n].key, c.JANET_NIL));
        std.debug.assert(harness.isType(data[n].value, c.JANET_NIL));
    }
}

/// A clone copies the bucket array verbatim, so it keeps the original's
/// tombstones and its `deleted` count rather than compacting them away.
fn tableCloneCopiesTheLayout() void {
    const proto = c.janet_table(2);
    const t = c.janet_table(4);
    t.*.proto = proto;
    var i: i32 = 0;
    while (i < 4) : (i += 1) c.janet_table_put(t, harness.wrapInteger(i), harness.wrapInteger(i));
    _ = c.janet_table_remove(t, harness.wrapInteger(1));
    std.debug.assert(t.*.deleted == 1);

    const clone = c.janet_table_clone(t);
    std.debug.assert(clone != t);
    std.debug.assert(clone.*.data != t.*.data);
    std.debug.assert(clone.*.count == t.*.count);
    std.debug.assert(clone.*.capacity == t.*.capacity);
    std.debug.assert(clone.*.deleted == t.*.deleted);
    // The prototype is shared, not cloned.
    std.debug.assert(clone.*.proto == proto);
    std.debug.assert(heap.memoryType(clone) == c.JANET_MEMORY_TABLE);
    std.debug.assert(sameLayout(clone.*.data, t.*.data, t.*.capacity));

    // And the two are independent afterwards.
    c.janet_table_put(clone, kw("new"), harness.wrapInteger(9));
    std.debug.assert(harness.isType(c.janet_table_rawget(t, kw("new")), c.JANET_NIL));
}

/// Cloning a table with no bucket array. This is the `memcpy(dst, NULL, 0)`
/// that `FOUND.md` records against the C original, and it is the only thing
/// asserted here: the clone's fields, not its usability. A zero-capacity table
/// cannot be looked up in on either side -- see `tableCapacityRounding` -- so
/// a clone of one cannot be either.
fn tableCloneOfAnEmptyArray() void {
    const empty = c.janet_table(-1);
    std.debug.assert(empty.*.data == null);
    const clone = c.janet_table_clone(empty);
    std.debug.assert(clone != empty);
    std.debug.assert(clone.*.count == 0);
    std.debug.assert(clone.*.capacity == 0);
    std.debug.assert(clone.*.deleted == 0);
    std.debug.assert(heap.memoryType(clone) == c.JANET_MEMORY_TABLE);
}

/// Merging takes the source's own pairs only. Its prototype is not consulted,
/// which is what separates a merge from a flatten.
fn tableMerge() void {
    const proto = c.janet_table(2);
    c.janet_table_put(proto, kw("p"), harness.wrapInteger(9));
    const source = c.janet_table(2);
    c.janet_table_put(source, kw("a"), harness.wrapInteger(1));
    source.*.proto = proto;

    const destination = c.janet_table(2);
    c.janet_table_put(destination, kw("a"), harness.wrapInteger(0));
    c.janet_table_put(destination, kw("b"), harness.wrapInteger(2));
    c.janet_table_merge_table(destination, source);
    std.debug.assert(harness.equals(
        c.janet_table_rawget(destination, kw("a")),
        harness.wrapInteger(1),
    ));
    std.debug.assert(harness.equals(
        c.janet_table_rawget(destination, kw("b")),
        harness.wrapInteger(2),
    ));
    std.debug.assert(harness.isType(c.janet_table_rawget(destination, kw("p")), c.JANET_NIL));

    const sp = c.janet_struct_begin(1);
    c.janet_struct_put(sp, kw("s"), harness.wrapInteger(5));
    const sproto = c.janet_struct_end(sp);
    const ss = c.janet_struct_begin(1);
    c.janet_struct_put(ss, kw("c"), harness.wrapInteger(3));
    setStructProto(ss, sproto);
    const s = c.janet_struct_end(ss);

    c.janet_table_merge_struct(destination, s);
    std.debug.assert(harness.equals(
        c.janet_table_rawget(destination, kw("c")),
        harness.wrapInteger(3),
    ));
    std.debug.assert(harness.isType(c.janet_table_rawget(destination, kw("s")), c.JANET_NIL));
}

/// The struct is begun at the table's live count, so tombstones cost nothing.
fn tableToStructIgnoresTombstones() void {
    const t = c.janet_table(4);
    var i: i32 = 0;
    while (i < 6) : (i += 1) c.janet_table_put(t, harness.wrapInteger(i), harness.wrapInteger(i));
    _ = c.janet_table_remove(t, harness.wrapInteger(2));
    _ = c.janet_table_remove(t, harness.wrapInteger(3));
    std.debug.assert(t.*.count == 4);
    std.debug.assert(t.*.deleted == 2);

    const s = c.janet_table_to_struct(t);
    std.debug.assert(structLength(s) == 4);
    std.debug.assert(structProto(s) == null);
    std.debug.assert(harness.equals(
        c.janet_struct_rawget(s, harness.wrapInteger(0)),
        harness.wrapInteger(0),
    ));
    std.debug.assert(harness.isType(
        c.janet_struct_rawget(s, harness.wrapInteger(2)),
        c.JANET_NIL,
    ));

    // Round-tripping a struct through a table and back reproduces it exactly,
    // which is the order-independence property seen from the other side: the
    // table hands the pairs back in bucket order, not insertion order.
    const back = c.janet_table_to_struct(c.janet_struct_to_table(s));
    std.debug.assert(structCapacity(back) == structCapacity(s));
    std.debug.assert(sameLayout(back, s, structCapacity(s)));
}

/// Flattening walks child first and never overwrites, so a binding nearer the
/// child wins -- the same precedence a chained lookup would have given.
fn tableProtoFlatten() void {
    const grandparent = c.janet_table(2);
    c.janet_table_put(grandparent, kw("a"), harness.wrapInteger(3));
    c.janet_table_put(grandparent, kw("c"), harness.wrapInteger(30));
    const parent = c.janet_table(2);
    c.janet_table_put(parent, kw("a"), harness.wrapInteger(2));
    c.janet_table_put(parent, kw("b"), harness.wrapInteger(20));
    parent.*.proto = grandparent;
    const child = c.janet_table(2);
    c.janet_table_put(child, kw("a"), harness.wrapInteger(1));
    child.*.proto = parent;

    const flat = internal.janet_table_proto_flatten(child);
    std.debug.assert(flat.proto == null);
    std.debug.assert(flat.count == 3);
    std.debug.assert(harness.equals(c.janet_table_rawget(flat, kw("a")), harness.wrapInteger(1)));
    std.debug.assert(harness.equals(c.janet_table_rawget(flat, kw("b")), harness.wrapInteger(20)));
    std.debug.assert(harness.equals(c.janet_table_rawget(flat, kw("c")), harness.wrapInteger(30)));

    // A tombstone in a source table is not carried into the result.
    _ = c.janet_table_remove(child, kw("a"));
    const again = internal.janet_table_proto_flatten(child);
    std.debug.assert(again.deleted == 0);
    std.debug.assert(harness.equals(c.janet_table_rawget(again, kw("a")), harness.wrapInteger(2)));
}

// ---------------------------------------------------- through the runtime

/// The same properties once more, reached the way a Janet program reaches
/// them, so that the entry points above are shown to be the ones the language
/// is actually built on.
fn fromJanet() void {
    var out: c.Janet = undefined;
    const source =
        \\[(= {1 2 3 4} {3 4 1 2})
        \\ (= (hash {1 2 3 4}) (hash {3 4 1 2}))
        \\ (get (struct/with-proto {:p 1} :a 2) :p)
        \\ (struct/rawget (struct/with-proto {:p 1} :a 2) :p)
        \\ (do (def t @{:a 1}) (put t :a nil) (length t))
        \\ (do (def t @{:a 1}) (table/setproto t @{:b 2}) (get t :b))
        \\ (table/proto-flatten (table/setproto @{:a 1} @{:a 2 :b 3}))
        \\ (length (table/to-struct (do (def t @{:a 1 :b 2}) (put t :a nil) t)))
        \\ (do (def t @{:a 1}) (table/clear t) (length t))]
    ;
    std.debug.assert(c.janet_dostring(c.janet_core_env(null), source, "struct_table", &out) == 0);
    const r = c.janet_unwrap_tuple(out);
    std.debug.assert(c.janet_truthy(r[0]) != 0);
    std.debug.assert(c.janet_truthy(r[1]) != 0);
    std.debug.assert(harness.integerIs(r[2], 1));
    std.debug.assert(harness.isType(r[3], c.JANET_NIL));
    std.debug.assert(harness.integerIs(r[4], 0));
    std.debug.assert(harness.integerIs(r[5], 2));
    const flat = c.janet_unwrap_table(r[6]);
    std.debug.assert(harness.equals(c.janet_table_rawget(flat, kw("a")), harness.wrapInteger(1)));
    std.debug.assert(harness.equals(c.janet_table_rawget(flat, kw("b")), harness.wrapInteger(3)));
    std.debug.assert(harness.integerIs(r[7], 1));
    std.debug.assert(harness.integerIs(r[8], 0));
}

pub fn run() void {
    _ = c.janet_init();

    structBeginCapacity();
    structBeginInitialisesTheHead();
    structLayoutIsOrderIndependent();
    structCollisionRunIsOrderedByHash();
    structHashTieFallsThroughToCompare();
    structPutCountsInTheHashField();
    structPutRejectsUnstorablePairs();
    structPutDropsTheSurplus();
    structPutExtHonoursReplace();
    structEndRebuildsOnAShortCount();
    structEndKeepsTheArrayWhenTheCountIsExact();
    structEndFoldsThePrototypeIntoTheHash();
    structFindReturnsAnEmptyBucketForAnAbsentKey();
    structGetBoundsThePrototypeChain();
    structGetExReportsTheOwner();
    structToTable();

    tableCapacityRounding();
    tableConstructorMarksAndLists();
    tableInitUsesScratchMemory();
    tableInitRawLeavesTheFlagClear();
    tableGrowthCapacities();
    removeLeavesATombstone();
    aTombstoneDoesNotTruncateAProbeRun();
    tombstonesAreReclaimed();
    tablePutRejectsUnstorableKeys();
    tablePutNilRemoves();
    tablePutUpdatesInPlace();
    tableGetBoundsThePrototypeChain();
    tableGetExReportsTheOwner();
    tableGetKeyword();
    tableClear();
    tableCloneCopiesTheLayout();
    tableCloneOfAnEmptyArray();
    tableMerge();
    tableToStructIgnoresTombstones();
    tableProtoFlatten();

    fromJanet();

    c.janet_deinit();
}
