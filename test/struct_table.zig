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
const config = @import("config");
const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");
const value = @import("subsystems").value;
const harness = @import("harness.zig");
const structs = @import("subsystems").value.structs;
const tables = @import("subsystems").value.tables;
const strings = @import("subsystems").value.strings;
const order = @import("subsystems").value.order;
const core_env = @import("subsystems").env;
const kind = @import("subsystems").value.kind;
const wrap = @import("subsystems").value.wrap;
const vm_lifecycle = @import("subsystems").lifecycle;

const heap = harness.heap;
const internal = harness.internal;

// --------------------------------------------------------------- helpers

fn structLength(st: [*]const types.JanetKV) i32 {
    return types.structHead(st).length;
}

fn structCapacity(st: [*]const types.JanetKV) i32 {
    return types.structHead(st).capacity;
}

fn structHash(st: [*]const types.JanetKV) i32 {
    return types.structHead(st).hash;
}

fn structProto(st: [*]const types.JanetKV) ?[*]const types.JanetKV {
    return types.structHead(st).proto;
}

fn setStructProto(st: [*]types.JanetKV, proto: ?[*]const types.JanetKV) void {
    types.structHead(st).proto = proto;
}

fn kw(name: [*:0]const u8) types.Janet {
    return value.fromBytes(std.mem.span(name), .keyword);
}

/// The bucket a key would like to occupy. Spelled out rather than reusing
/// `janet_maphash`, so that a change to that macro shows up as a failure
/// rather than being tracked silently.
fn idealIndex(capacity: i32, key: types.Janet) i32 {
    const hash: u32 = @bitCast(order.hash(key));
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
fn findColliding(capacity: i32, out: []types.Janet) i32 {
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
fn findDistinctIndices(capacity: i32, out: []types.Janet) void {
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
fn sameLayout(a: [*]const types.JanetKV, b: [*]const types.JanetKV, capacity: i32) bool {
    var i: usize = 0;
    while (i < capacity) : (i += 1) {
        if (kind.typeOf(a[i].key) != kind.typeOf(b[i].key)) return false;
        if (kind.typeOf(a[i].value) != kind.typeOf(b[i].value)) return false;
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
    std.debug.assert(structCapacity(structs.begin(0)) == 1);
    std.debug.assert(structCapacity(structs.begin(1)) == 4);
    std.debug.assert(structCapacity(structs.begin(2)) == 8);
    std.debug.assert(structCapacity(structs.begin(3)) == 8);
    std.debug.assert(structCapacity(structs.begin(4)) == 16);
}

fn structBeginInitialisesTheHead() void {
    const st = structs.begin(3);
    std.debug.assert(structLength(st) == 3);
    std.debug.assert(structCapacity(st) == 8);
    // The hash field is a running count of filled slots until `end` runs.
    std.debug.assert(structHash(st) == 0);
    std.debug.assert(structProto(st) == null);
    var i: usize = 0;
    while (i < structCapacity(st)) : (i += 1) {
        std.debug.assert(harness.isType(st[i].key, constants.JANET_NIL));
        std.debug.assert(harness.isType(st[i].value, constants.JANET_NIL));
    }
    std.debug.assert(heap.memoryType(types.structHead(st)) == constants.JANET_MEMORY_STRUCT);
    std.debug.assert(heap.onList(c.vm().blocks, types.structHead(st)));
    std.debug.assert(!heap.onList(c.vm().weak_blocks, types.structHead(st)));
}

// ------------------------------------------------------- struct: insertion

/// The whole reason Robin Hood insertion is here. Two structs built from the
/// same pairs in different orders must have identical bucket arrays, because
/// `janet_struct_end` hashes the array and `janet_equals` compares the hash
/// first. Compared over the entire array rather than pair by pair, so that a
/// difference in *position* fails as loudly as a difference in contents.
fn structLayoutIsOrderIndependent() void {
    var keys: [6]types.Janet = undefined;
    for (&keys, 0..) |*key, i| key.* = harness.wrapInteger(@intCast(i * 37 + 11));

    const a = structs.begin(6);
    for (keys, 0..) |key, i| structs.put(a, key, harness.wrapInteger(@intCast(i)));
    const b = structs.begin(6);
    var i: usize = 6;
    while (i > 0) {
        i -= 1;
        structs.put(b, keys[i], harness.wrapInteger(@intCast(i)));
    }
    // And a third order that is neither forwards nor backwards.
    const d = structs.begin(6);
    for ([6]usize{ 3, 0, 5, 1, 4, 2 }) |n| {
        structs.put(d, keys[n], harness.wrapInteger(@intCast(n)));
    }

    const capacity = structCapacity(a);
    std.debug.assert(structCapacity(b) == capacity);
    std.debug.assert(structCapacity(d) == capacity);

    const sa = structs.end(a);
    const sb = structs.end(b);
    const sd = structs.end(d);

    std.debug.assert(sameLayout(sa, sb, capacity));
    std.debug.assert(sameLayout(sa, sd, capacity));
    std.debug.assert(structHash(sa) == structHash(sb));
    std.debug.assert(structHash(sa) == structHash(sd));
    std.debug.assert(harness.equals(wrap.fromStruct(sa), wrap.fromStruct(sb)));
}

/// Order-independence alone does not pin the *direction* of the displacement
/// rule: inverting the comparison consistently still yields a layout that is a
/// function of the pair set. What pins the direction is a run of keys that all
/// want the same bucket, where every displacement comparison ties and the full
/// hash decides. The pair with the larger hash keeps the earlier slot.
fn structCollisionRunIsOrderedByHash() void {
    const st = structs.begin(3);
    const capacity = structCapacity(st);
    var keys: [3]types.Janet = undefined;
    const index = findColliding(capacity, &keys);

    for (keys, 0..) |key, i| structs.put(st, key, harness.wrapInteger(@intCast(i)));
    const s = structs.end(st);

    var previous: i32 = 0;
    var n: i32 = 0;
    while (n < 3) : (n += 1) {
        const kv = &s[@intCast(@mod(index + n, capacity))];
        std.debug.assert(!harness.isType(kv.key, constants.JANET_NIL));
        const hash = order.hash(kv.key);
        if (n > 0) std.debug.assert(hash < previous);
        previous = hash;
    }

    // Inserted backwards, the run comes out the same.
    const st2 = structs.begin(3);
    var i: usize = 3;
    while (i > 0) {
        i -= 1;
        structs.put(st2, keys[i], harness.wrapInteger(@intCast(i)));
    }
    std.debug.assert(sameLayout(s, structs.end(st2), capacity));
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
    const as_string = wrap.fromString(strings.cstring("tie"));
    std.debug.assert(order.hash(as_keyword) == order.hash(as_string));
    std.debug.assert(!harness.equals(as_keyword, as_string));
    // JANET_STRING sorts before JANET_KEYWORD, so the order is by type.
    std.debug.assert(order.compare(as_string, as_keyword) == -1);

    const st = structs.begin(2);
    structs.put(st, as_keyword, harness.wrapInteger(1));
    structs.put(st, as_string, harness.wrapInteger(2));
    // Both landed: neither was mistaken for the other.
    std.debug.assert(structHash(st) == 2);
    const s = structs.end(st);
    std.debug.assert(structLength(s) == 2);
    std.debug.assert(harness.equals(structs.rawget(s, as_keyword), harness.wrapInteger(1)));
    std.debug.assert(harness.equals(structs.rawget(s, as_string), harness.wrapInteger(2)));

    const st2 = structs.begin(2);
    structs.put(st2, as_string, harness.wrapInteger(2));
    structs.put(st2, as_keyword, harness.wrapInteger(1));
    std.debug.assert(sameLayout(s, structs.end(st2), structCapacity(s)));
}

/// Every pair that lands moves the running count in the hash field.
fn structPutCountsInTheHashField() void {
    const st = structs.begin(3);
    structs.put(st, kw("a"), harness.wrapInteger(1));
    std.debug.assert(structHash(st) == 1);
    structs.put(st, kw("b"), harness.wrapInteger(2));
    std.debug.assert(structHash(st) == 2);
    // A duplicate replaces rather than adds, so the count stands still.
    structs.put(st, kw("a"), harness.wrapInteger(9));
    std.debug.assert(structHash(st) == 2);
}

fn structPutRejectsUnstorablePairs() void {
    const st = structs.begin(4);
    structs.put(st, wrap.fromNil(), harness.wrapInteger(1));
    std.debug.assert(structHash(st) == 0);
    structs.put(st, kw("k"), wrap.fromNil());
    std.debug.assert(structHash(st) == 0);
    structs.put(st, wrap.fromNumberSafe(std.math.nan(f64)), harness.wrapInteger(1));
    std.debug.assert(structHash(st) == 0);
    // And one that is storable, so the three above are shown to be the reason
    // the count stayed at zero rather than the puts not working at all.
    structs.put(st, kw("k"), harness.wrapInteger(1));
    std.debug.assert(structHash(st) == 1);
}

/// Past the declared length, a put is silently dropped.
fn structPutDropsTheSurplus() void {
    const st = structs.begin(1);
    structs.put(st, kw("a"), harness.wrapInteger(1));
    structs.put(st, kw("b"), harness.wrapInteger(2));
    std.debug.assert(structHash(st) == 1);
    const s = structs.end(st);
    std.debug.assert(structLength(s) == 1);
    std.debug.assert(harness.equals(structs.rawget(s, kw("a")), harness.wrapInteger(1)));
    std.debug.assert(harness.isType(structs.rawget(s, kw("b")), constants.JANET_NIL));
}

/// `replace` is what separates `janet_struct_put` from the flattening path:
/// `struct/proto-flatten` walks child first and must not let a prototype's
/// binding overwrite the child's.
fn structPutExtHonoursReplace() void {
    const keep = structs.begin(2);
    internal.janet_struct_put_ext(keep, kw("a"), harness.wrapInteger(1), 0);
    internal.janet_struct_put_ext(keep, kw("a"), harness.wrapInteger(2), 0);
    std.debug.assert(harness.equals(
        structs.rawget(structs.end(keep), kw("a")),
        harness.wrapInteger(1),
    ));

    const over = structs.begin(2);
    internal.janet_struct_put_ext(over, kw("a"), harness.wrapInteger(1), 1);
    internal.janet_struct_put_ext(over, kw("a"), harness.wrapInteger(2), 1);
    std.debug.assert(harness.equals(
        structs.rawget(structs.end(over), kw("a")),
        harness.wrapInteger(2),
    ));
}

// ------------------------------------------------------------ struct: end

/// When fewer pairs land than were declared, the array is the wrong size for
/// its contents and the whole struct is rebuilt at the size that fit.
fn structEndRebuildsOnAShortCount() void {
    const proto = structs.begin(1);
    structs.put(proto, kw("p"), harness.wrapInteger(7));
    const sproto = structs.end(proto);

    const st = structs.begin(3);
    structs.put(st, kw("a"), harness.wrapInteger(1));
    structs.put(st, kw("a"), harness.wrapInteger(2));
    structs.put(st, kw("b"), harness.wrapInteger(3));
    setStructProto(st, sproto);
    std.debug.assert(structCapacity(st) == 8);

    const s = structs.end(st);
    std.debug.assert(s != st);
    std.debug.assert(structLength(s) == 2);
    std.debug.assert(structCapacity(s) == 8);
    std.debug.assert(harness.equals(structs.rawget(s, kw("a")), harness.wrapInteger(2)));
    std.debug.assert(harness.equals(structs.rawget(s, kw("b")), harness.wrapInteger(3)));
    // The prototype is not a bucket, so it is carried across by hand.
    std.debug.assert(structProto(s) == sproto);
}

fn structEndKeepsTheArrayWhenTheCountIsExact() void {
    const st = structs.begin(2);
    structs.put(st, kw("a"), harness.wrapInteger(1));
    structs.put(st, kw("b"), harness.wrapInteger(2));
    std.debug.assert(structs.end(st) == st);
}

/// The prototype contributes to the hash by a multiply, so it costs one read
/// rather than a walk -- and two structs with the same pairs and different
/// prototypes are distinguishable.
fn structEndFoldsThePrototypeIntoTheHash() void {
    const p = structs.begin(1);
    structs.put(p, kw("p"), harness.wrapInteger(1));
    const sp = structs.end(p);

    const bare = structs.begin(1);
    structs.put(bare, kw("a"), harness.wrapInteger(1));
    const sbare = structs.end(bare);

    const with = structs.begin(1);
    structs.put(with, kw("a"), harness.wrapInteger(1));
    setStructProto(with, sp);
    const swith = structs.end(with);

    std.debug.assert(sameLayout(sbare, swith, structCapacity(sbare)));
    std.debug.assert(structHash(sbare) != structHash(swith));

    const buckets: u32 = @bitCast(internal.janet_kv_calchash(swith, structCapacity(swith)));
    const proto: u32 = @bitCast(structHash(sp));
    const expected: i32 = @bitCast(buckets +% 2654435761 *% proto);
    std.debug.assert(structHash(swith) == expected);
}

// ---------------------------------------------------------- struct: lookup

fn structFindReturnsAnEmptyBucketForAnAbsentKey() void {
    const st = structs.begin(2);
    structs.put(st, kw("a"), harness.wrapInteger(1));
    const s = structs.end(st);

    const hit = structs.find(s, kw("a"));
    std.debug.assert(hit != null);
    std.debug.assert(harness.equals(hit.?.value, harness.wrapInteger(1)));

    const miss = structs.find(s, kw("zz"));
    std.debug.assert(miss != null);
    std.debug.assert(harness.isType(miss.?.key, constants.JANET_NIL));
    std.debug.assert(harness.isType(structs.rawget(s, kw("zz")), constants.JANET_NIL));
}

/// Build a chain `depth` deep and return the deepest struct. Entry `i` holds
/// the key `i` and its prototype is entry `i - 1`.
fn structChain(depth: i32) [*]const types.JanetKV {
    var proto: ?[*]const types.JanetKV = null;
    var i: i32 = 0;
    while (i < depth) : (i += 1) {
        const st = structs.begin(1);
        structs.put(st, harness.wrapInteger(i), harness.wrapInteger(i));
        setStructProto(st, proto);
        proto = structs.end(st);
    }
    return proto.?;
}

/// The chain walk is bounded, and the bound is enumerated rather than sampled:
/// the last reachable depth and the first unreachable one are both asserted.
fn structGetBoundsThePrototypeChain() void {
    const deep = structChain(config.max_proto_depth + 5);
    // The head holds the highest key; the walk descends toward key 0.
    const top: i32 = config.max_proto_depth + 4;
    std.debug.assert(harness.equals(
        structs.get(deep, harness.wrapInteger(top)),
        harness.wrapInteger(top),
    ));
    const last: i32 = top - (config.max_proto_depth - 1);
    std.debug.assert(harness.equals(
        structs.get(deep, harness.wrapInteger(last)),
        harness.wrapInteger(last),
    ));
    std.debug.assert(harness.isType(
        structs.get(deep, harness.wrapInteger(last - 1)),
        constants.JANET_NIL,
    ));
    // rawget never leaves the head at all.
    std.debug.assert(harness.isType(
        structs.rawget(deep, harness.wrapInteger(top - 1)),
        constants.JANET_NIL,
    ));
}

fn structGetExReportsTheOwner() void {
    const p = structs.begin(1);
    structs.put(p, kw("a"), harness.wrapInteger(1));
    const sp = structs.end(p);

    const ch = structs.begin(1);
    structs.put(ch, kw("b"), harness.wrapInteger(2));
    setStructProto(ch, sp);
    const sch = structs.end(ch);

    var which: ?[*]const types.JanetKV = null;
    std.debug.assert(harness.equals(
        structs.getEx(sch, kw("b"), &which),
        harness.wrapInteger(2),
    ));
    std.debug.assert(which == sch);
    which = null;
    std.debug.assert(harness.equals(
        structs.getEx(sch, kw("a"), &which),
        harness.wrapInteger(1),
    ));
    std.debug.assert(which == sp);
}

// ------------------------------------------------------ struct: conversion

/// The new table is sized from the struct's *capacity*, not its pair count,
/// which is why a two-pair struct becomes a sixteen-bucket table.
fn structToTable() void {
    const p = structs.begin(1);
    structs.put(p, kw("p"), harness.wrapInteger(9));
    const sp = structs.end(p);

    const st = structs.begin(2);
    structs.put(st, kw("a"), harness.wrapInteger(1));
    structs.put(st, kw("b"), harness.wrapInteger(2));
    setStructProto(st, sp);
    const s = structs.end(st);

    const t = structs.toTable(s);
    std.debug.assert(t.*.count == 2);
    std.debug.assert(t.*.capacity == internal.janet_tablen(structCapacity(s)));
    std.debug.assert(t.*.capacity == 16);
    std.debug.assert(harness.equals(tables.rawget(t, kw("a")), harness.wrapInteger(1)));
    std.debug.assert(harness.equals(tables.rawget(t, kw("b")), harness.wrapInteger(2)));
    // The prototype is not carried; `struct/to-table` rebuilds it itself.
    std.debug.assert(t.*.proto == null);
    std.debug.assert(harness.isType(tables.get(t, kw("p")), constants.JANET_NIL));
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
    std.debug.assert(tables.new(0).*.capacity == 1);
    std.debug.assert(tables.new(1).*.capacity == 2);
    std.debug.assert(tables.new(4).*.capacity == 8);

    const empty = tables.new(-1);
    std.debug.assert(empty.*.capacity == 0);
    std.debug.assert(empty.*.data == null);
    std.debug.assert(empty.*.count == 0);
    std.debug.assert(empty.*.deleted == 0);
}

fn tableConstructorMarksAndLists() void {
    const Case = struct {
        make: *const @TypeOf(tables.new),
        memory: i32,
        weak: bool,
    };
    const cases = [_]Case{
        .{ .make = &tables.new, .memory = constants.JANET_MEMORY_TABLE, .weak = false },
        .{ .make = &tables.weakk, .memory = constants.JANET_MEMORY_TABLE_WEAKK, .weak = true },
        .{ .make = &tables.weakv, .memory = constants.JANET_MEMORY_TABLE_WEAKV, .weak = true },
        .{ .make = &tables.weakkv, .memory = constants.JANET_MEMORY_TABLE_WEAKKV, .weak = true },
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
        std.debug.assert(heap.onList(c.vm().weak_blocks, t) == case.weak);
        std.debug.assert(heap.onList(c.vm().blocks, t) == !case.weak);
        // All four behave identically as dictionaries.
        tables.put(t, kw("a"), harness.wrapInteger(1));
        std.debug.assert(harness.equals(tables.rawget(t, kw("a")), harness.wrapInteger(1)));
    }
}

/// A scratch table is caller-owned memory whose buckets come from the scratch
/// allocator. The flag lives in the same word as the memory type, which is
/// safe only because such a table is never `janet_gcalloc`ed -- so the flag is
/// asserted as the whole word, not as a bit.
fn tableInitUsesScratchMemory() void {
    var local: types.JanetTable = undefined;
    @memset(std.mem.asBytes(&local), 0xEE);
    _ = tables.init(&local, 4);
    std.debug.assert(local.gc.flags == 0x10000);
    std.debug.assert(local.capacity == 8);
    std.debug.assert(local.count == 0);
    std.debug.assert(local.deleted == 0);
    std.debug.assert(local.proto == null);

    // Grow it, so the rehash takes the scratch branch too.
    var i: i32 = 0;
    while (i < 40) : (i += 1) {
        tables.put(&local, harness.wrapInteger(i), harness.wrapInteger(i * 2));
    }
    std.debug.assert(local.count == 40);
    std.debug.assert(local.gc.flags == 0x10000);
    i = 0;
    while (i < 40) : (i += 1) {
        std.debug.assert(harness.equals(
            tables.rawget(&local, harness.wrapInteger(i)),
            harness.wrapInteger(i * 2),
        ));
    }
    tables.deinit(&local);
}

fn tableInitRawLeavesTheFlagClear() void {
    var local: types.JanetTable = undefined;
    @memset(std.mem.asBytes(&local), 0);
    _ = tables.initRaw(&local, 4);
    std.debug.assert(local.gc.flags == 0);
    std.debug.assert(local.capacity == 8);
    tables.put(&local, kw("a"), harness.wrapInteger(1));
    std.debug.assert(harness.equals(tables.rawget(&local, kw("a")), harness.wrapInteger(1)));
    tables.deinit(&local);
}

// ---------------------------------------------------------- table: growth

/// The growth policy, as exact capacities. A rehash happens when twice the
/// live pairs plus the tombstones plus one would exceed the capacity, and the
/// new capacity is `janet_tablen(2 * count + 2)`.
fn tableGrowthCapacities() void {
    const t = tables.new(0);
    const expected = [9]i32{ 4, 4, 8, 8, 16, 16, 16, 16, 32 };
    for (expected, 0..) |capacity, n| {
        const i: i32 = @intCast(n);
        tables.put(t, harness.wrapInteger(i), harness.wrapInteger(i));
        std.debug.assert(t.*.count == i + 1);
        std.debug.assert(t.*.capacity == capacity);
    }
    var i: i32 = 0;
    while (i < 9) : (i += 1) {
        std.debug.assert(harness.equals(
            tables.rawget(t, harness.wrapInteger(i)),
            harness.wrapInteger(i),
        ));
    }
}

// --------------------------------------------------------- table: removal

/// A removal leaves a nil key and a *false* value. The falseness is the
/// tombstone marker: `janet_dict_find` stops only where key and value are both
/// nil, so a run of probes passes through the hole instead of ending at it.
fn removeLeavesATombstone() void {
    const t = tables.new(4);
    tables.put(t, kw("a"), harness.wrapInteger(1));
    const bucket = tables.find(t, kw("a"));
    std.debug.assert(!harness.isType(bucket.?.key, constants.JANET_NIL));

    const gone = tables.remove(t, kw("a"));
    std.debug.assert(harness.equals(gone, harness.wrapInteger(1)));
    std.debug.assert(t.*.count == 0);
    std.debug.assert(t.*.deleted == 1);
    std.debug.assert(harness.isType(bucket.?.key, constants.JANET_NIL));
    std.debug.assert(harness.isType(bucket.?.value, constants.JANET_BOOLEAN));
    std.debug.assert(kind.truthy(bucket.?.value) == 0);

    // Removing an absent key changes nothing.
    std.debug.assert(harness.isType(tables.remove(t, kw("zz")), constants.JANET_NIL));
    std.debug.assert(t.*.count == 0);
    std.debug.assert(t.*.deleted == 1);
}

/// The property the tombstone exists for. Two keys that want the same bucket,
/// the first removed: the second must still be found through the hole.
fn aTombstoneDoesNotTruncateAProbeRun() void {
    const t = tables.new(4);
    std.debug.assert(t.*.capacity == 8);
    var keys: [2]types.Janet = undefined;
    const index = findColliding(t.*.capacity, &keys);

    tables.put(t, keys[0], harness.wrapInteger(10));
    tables.put(t, keys[1], harness.wrapInteger(20));
    std.debug.assert(t.*.count == 2);
    std.debug.assert(t.*.capacity == 8);
    // The second key really did displace: it is not in its ideal bucket.
    std.debug.assert(tables.find(t, keys[1]) != &t.*.data.?[@as(usize, @intCast(index))]);

    _ = tables.remove(t, keys[0]);
    std.debug.assert(harness.equals(tables.rawget(t, keys[1]), harness.wrapInteger(20)));
    std.debug.assert(harness.isType(tables.rawget(t, keys[0]), constants.JANET_NIL));
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
    const t = tables.new(4);
    tables.put(t, kw("a"), harness.wrapInteger(1));
    const first = tables.find(t, kw("a"));
    _ = tables.remove(t, kw("a"));
    std.debug.assert(t.*.deleted == 1);
    tables.put(t, kw("a"), harness.wrapInteger(2));
    std.debug.assert(t.*.count == 1);
    std.debug.assert(t.*.deleted == 1);
    std.debug.assert(tables.find(t, kw("a")) != first);
    std.debug.assert(harness.isType(first.?.key, constants.JANET_NIL));
    std.debug.assert(harness.isType(first.?.value, constants.JANET_BOOLEAN));
    std.debug.assert(harness.equals(tables.rawget(t, kw("a")), harness.wrapInteger(2)));

    // Otherwise a tombstone is reclaimed only by a rehash, and the rehash is
    // driven by the tombstone count alone -- a table with no live pairs at all
    // still grows. Keys at pairwise-distinct ideal buckets, so that each
    // removal leaves a tombstone instead of the next insert reusing the last
    // one. Capacity 8 trips at `count + deleted >= 4`.
    const churned = tables.new(4);
    std.debug.assert(churned.*.capacity == 8);
    var keys: [5]types.Janet = undefined;
    findDistinctIndices(churned.*.capacity, &keys);
    for (keys[0..4], 0..) |key, i| {
        tables.put(churned, key, harness.wrapInteger(@intCast(i)));
        _ = tables.remove(churned, key);
    }
    std.debug.assert(churned.*.count == 0);
    std.debug.assert(churned.*.deleted == 4);
    std.debug.assert(churned.*.capacity == 8);

    tables.put(churned, keys[4], harness.wrapInteger(4));
    // `janet_tablen(2 * 0 + 2)` is 4: the new array is sized from the live
    // count, so a table that was only ever churned shrinks.
    std.debug.assert(churned.*.capacity == 4);
    std.debug.assert(churned.*.deleted == 0);
    std.debug.assert(churned.*.count == 1);
    std.debug.assert(harness.equals(
        tables.rawget(churned, keys[4]),
        harness.wrapInteger(4),
    ));
}

// -------------------------------------------------------- table: put rules

fn tablePutRejectsUnstorableKeys() void {
    const t = tables.new(4);
    tables.put(t, wrap.fromNil(), harness.wrapInteger(1));
    std.debug.assert(t.*.count == 0);
    tables.put(t, wrap.fromNumberSafe(std.math.nan(f64)), harness.wrapInteger(1));
    std.debug.assert(t.*.count == 0);
    tables.put(t, kw("k"), harness.wrapInteger(1));
    std.debug.assert(t.*.count == 1);
}

/// A nil value is a removal, not a stored nil. This is what makes an absent
/// key and a nil-valued key indistinguishable.
fn tablePutNilRemoves() void {
    const t = tables.new(4);
    tables.put(t, kw("a"), harness.wrapInteger(1));
    std.debug.assert(t.*.count == 1);
    tables.put(t, kw("a"), wrap.fromNil());
    std.debug.assert(t.*.count == 0);
    std.debug.assert(t.*.deleted == 1);
    std.debug.assert(harness.isType(tables.rawget(t, kw("a")), constants.JANET_NIL));

    // And a nil value for an absent key is not a removal of anything.
    tables.put(t, kw("zz"), wrap.fromNil());
    std.debug.assert(t.*.count == 0);
    std.debug.assert(t.*.deleted == 1);
}

fn tablePutUpdatesInPlace() void {
    const t = tables.new(4);
    tables.put(t, kw("a"), harness.wrapInteger(1));
    const bucket = tables.find(t, kw("a"));
    const capacity = t.*.capacity;
    tables.put(t, kw("a"), harness.wrapInteger(2));
    std.debug.assert(t.*.count == 1);
    std.debug.assert(t.*.capacity == capacity);
    std.debug.assert(tables.find(t, kw("a")) == bucket);
    std.debug.assert(harness.equals(bucket.?.value, harness.wrapInteger(2)));
}

// ----------------------------------------------------------- table: lookup

fn tableGetBoundsThePrototypeChain() void {
    var deep: ?*types.JanetTable = null;
    var i: i32 = 0;
    while (i < config.max_proto_depth + 5) : (i += 1) {
        const t = tables.new(1);
        tables.put(t, harness.wrapInteger(i), harness.wrapInteger(i));
        t.*.proto = deep;
        deep = t;
    }
    const top: i32 = config.max_proto_depth + 4;
    std.debug.assert(harness.equals(
        tables.get(deep.?, harness.wrapInteger(top)),
        harness.wrapInteger(top),
    ));
    const last: i32 = top - (config.max_proto_depth - 1);
    std.debug.assert(harness.equals(
        tables.get(deep.?, harness.wrapInteger(last)),
        harness.wrapInteger(last),
    ));
    std.debug.assert(harness.isType(
        tables.get(deep.?, harness.wrapInteger(last - 1)),
        constants.JANET_NIL,
    ));
    std.debug.assert(harness.isType(
        tables.rawget(deep.?, harness.wrapInteger(top - 1)),
        constants.JANET_NIL,
    ));
}

fn tableGetExReportsTheOwner() void {
    const proto = tables.new(2);
    tables.put(proto, kw("a"), harness.wrapInteger(1));
    const child = tables.new(2);
    tables.put(child, kw("b"), harness.wrapInteger(2));
    child.*.proto = proto;

    var which: ?*types.JanetTable = null;
    std.debug.assert(harness.equals(
        tables.getEx(child, kw("b"), &which),
        harness.wrapInteger(2),
    ));
    std.debug.assert(which == child);
    which = null;
    std.debug.assert(harness.equals(
        tables.getEx(child, kw("a"), &which),
        harness.wrapInteger(1),
    ));
    std.debug.assert(which == proto);
}

/// Looking a key up from raw bytes, without interning it first. Used by the
/// compiler against the core environment.
fn tableGetKeyword() void {
    const proto = tables.new(4);
    tables.put(proto, kw("deep"), harness.wrapInteger(2));
    const t = tables.new(4);
    tables.put(t, kw("hello"), harness.wrapInteger(1));
    t.*.proto = proto;

    std.debug.assert(harness.equals(
        internal.janet_table_get_keyword(t, "hello"),
        harness.wrapInteger(1),
    ));
    std.debug.assert(harness.equals(
        internal.janet_table_get_keyword(t, "deep"),
        harness.wrapInteger(2),
    ));
    std.debug.assert(harness.isType(internal.janet_table_get_keyword(t, "missing"), constants.JANET_NIL));
    // A prefix of a present key is not that key.
    std.debug.assert(harness.isType(internal.janet_table_get_keyword(t, "hell"), constants.JANET_NIL));
}

// -------------------------------------------------------- table: wholesale

/// Clearing keeps the bucket array and the prototype, and drops both counts.
fn tableClear() void {
    const proto = tables.new(2);
    const t = tables.new(4);
    t.*.proto = proto;
    var i: i32 = 0;
    while (i < 6) : (i += 1) tables.put(t, harness.wrapInteger(i), harness.wrapInteger(i));
    _ = tables.remove(t, harness.wrapInteger(0));
    const capacity = t.*.capacity;
    const data = t.*.data;
    std.debug.assert(t.*.deleted == 1);

    tables.clear(t);
    std.debug.assert(t.*.count == 0);
    std.debug.assert(t.*.deleted == 0);
    std.debug.assert(t.*.capacity == capacity);
    std.debug.assert(t.*.data == data);
    std.debug.assert(t.*.proto == proto);
    var n: usize = 0;
    while (n < capacity) : (n += 1) {
        std.debug.assert(harness.isType(data.?[n].key, constants.JANET_NIL));
        std.debug.assert(harness.isType(data.?[n].value, constants.JANET_NIL));
    }
}

/// A clone copies the bucket array verbatim, so it keeps the original's
/// tombstones and its `deleted` count rather than compacting them away.
fn tableCloneCopiesTheLayout() void {
    const proto = tables.new(2);
    const t = tables.new(4);
    t.*.proto = proto;
    var i: i32 = 0;
    while (i < 4) : (i += 1) tables.put(t, harness.wrapInteger(i), harness.wrapInteger(i));
    _ = tables.remove(t, harness.wrapInteger(1));
    std.debug.assert(t.*.deleted == 1);

    const clone = tables.clone(t);
    std.debug.assert(clone != t);
    std.debug.assert(clone.*.data != t.*.data);
    std.debug.assert(clone.*.count == t.*.count);
    std.debug.assert(clone.*.capacity == t.*.capacity);
    std.debug.assert(clone.*.deleted == t.*.deleted);
    // The prototype is shared, not cloned.
    std.debug.assert(clone.*.proto == proto);
    std.debug.assert(heap.memoryType(clone) == constants.JANET_MEMORY_TABLE);
    std.debug.assert(sameLayout(clone.*.data.?, t.*.data.?, t.*.capacity));

    // And the two are independent afterwards.
    tables.put(clone, kw("new"), harness.wrapInteger(9));
    std.debug.assert(harness.isType(tables.rawget(t, kw("new")), constants.JANET_NIL));
}

/// Cloning a table with no bucket array. This is the `memcpy(dst, NULL, 0)`
/// that `FOUND.md` records against the C original, and it is the only thing
/// asserted here: the clone's fields, not its usability. A zero-capacity table
/// cannot be looked up in on either side -- see `tableCapacityRounding` -- so
/// a clone of one cannot be either.
fn tableCloneOfAnEmptyArray() void {
    const empty = tables.new(-1);
    std.debug.assert(empty.*.data == null);
    const clone = tables.clone(empty);
    std.debug.assert(clone != empty);
    std.debug.assert(clone.*.count == 0);
    std.debug.assert(clone.*.capacity == 0);
    std.debug.assert(clone.*.deleted == 0);
    std.debug.assert(heap.memoryType(clone) == constants.JANET_MEMORY_TABLE);
}

/// Merging takes the source's own pairs only. Its prototype is not consulted,
/// which is what separates a merge from a flatten.
fn tableMerge() void {
    const proto = tables.new(2);
    tables.put(proto, kw("p"), harness.wrapInteger(9));
    const source = tables.new(2);
    tables.put(source, kw("a"), harness.wrapInteger(1));
    source.*.proto = proto;

    const destination = tables.new(2);
    tables.put(destination, kw("a"), harness.wrapInteger(0));
    tables.put(destination, kw("b"), harness.wrapInteger(2));
    tables.mergeTable(destination, source);
    std.debug.assert(harness.equals(
        tables.rawget(destination, kw("a")),
        harness.wrapInteger(1),
    ));
    std.debug.assert(harness.equals(
        tables.rawget(destination, kw("b")),
        harness.wrapInteger(2),
    ));
    std.debug.assert(harness.isType(tables.rawget(destination, kw("p")), constants.JANET_NIL));

    const sp = structs.begin(1);
    structs.put(sp, kw("s"), harness.wrapInteger(5));
    const sproto = structs.end(sp);
    const ss = structs.begin(1);
    structs.put(ss, kw("c"), harness.wrapInteger(3));
    setStructProto(ss, sproto);
    const s = structs.end(ss);

    tables.mergeStruct(destination, s);
    std.debug.assert(harness.equals(
        tables.rawget(destination, kw("c")),
        harness.wrapInteger(3),
    ));
    std.debug.assert(harness.isType(tables.rawget(destination, kw("s")), constants.JANET_NIL));
}

/// The struct is begun at the table's live count, so tombstones cost nothing.
fn tableToStructIgnoresTombstones() void {
    const t = tables.new(4);
    var i: i32 = 0;
    while (i < 6) : (i += 1) tables.put(t, harness.wrapInteger(i), harness.wrapInteger(i));
    _ = tables.remove(t, harness.wrapInteger(2));
    _ = tables.remove(t, harness.wrapInteger(3));
    std.debug.assert(t.*.count == 4);
    std.debug.assert(t.*.deleted == 2);

    const s = tables.toStruct(t);
    std.debug.assert(structLength(s) == 4);
    std.debug.assert(structProto(s) == null);
    std.debug.assert(harness.equals(
        structs.rawget(s, harness.wrapInteger(0)),
        harness.wrapInteger(0),
    ));
    std.debug.assert(harness.isType(
        structs.rawget(s, harness.wrapInteger(2)),
        constants.JANET_NIL,
    ));

    // Round-tripping a struct through a table and back reproduces it exactly,
    // which is the order-independence property seen from the other side: the
    // table hands the pairs back in bucket order, not insertion order.
    const back = tables.toStruct(structs.toTable(s));
    std.debug.assert(structCapacity(back) == structCapacity(s));
    std.debug.assert(sameLayout(back, s, structCapacity(s)));
}

/// Flattening walks child first and never overwrites, so a binding nearer the
/// child wins -- the same precedence a chained lookup would have given.
fn tableProtoFlatten() void {
    const grandparent = tables.new(2);
    tables.put(grandparent, kw("a"), harness.wrapInteger(3));
    tables.put(grandparent, kw("c"), harness.wrapInteger(30));
    const parent = tables.new(2);
    tables.put(parent, kw("a"), harness.wrapInteger(2));
    tables.put(parent, kw("b"), harness.wrapInteger(20));
    parent.*.proto = grandparent;
    const child = tables.new(2);
    tables.put(child, kw("a"), harness.wrapInteger(1));
    child.*.proto = parent;

    const flat = internal.janet_table_proto_flatten(child);
    std.debug.assert(flat.proto == null);
    std.debug.assert(flat.count == 3);
    std.debug.assert(harness.equals(tables.rawget(flat, kw("a")), harness.wrapInteger(1)));
    std.debug.assert(harness.equals(tables.rawget(flat, kw("b")), harness.wrapInteger(20)));
    std.debug.assert(harness.equals(tables.rawget(flat, kw("c")), harness.wrapInteger(30)));

    // A tombstone in a source table is not carried into the result.
    _ = tables.remove(child, kw("a"));
    const again = internal.janet_table_proto_flatten(child);
    std.debug.assert(again.deleted == 0);
    std.debug.assert(harness.equals(tables.rawget(again, kw("a")), harness.wrapInteger(2)));
}

// ---------------------------------------------------- through the runtime

/// The same properties once more, reached the way a Janet program reaches
/// them, so that the entry points above are shown to be the ones the language
/// is actually built on.
fn fromJanet() void {
    var out: types.Janet = undefined;
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
    std.debug.assert(core_env.dostring(harness.coreEnv(), source, "struct_table", &out) == 0);
    const r = wrap.toTuple(out);
    std.debug.assert(kind.truthy(r[0]) != 0);
    std.debug.assert(kind.truthy(r[1]) != 0);
    std.debug.assert(harness.integerIs(r[2], 1));
    std.debug.assert(harness.isType(r[3], constants.JANET_NIL));
    std.debug.assert(harness.integerIs(r[4], 0));
    std.debug.assert(harness.integerIs(r[5], 2));
    const flat = wrap.toTable(r[6]);
    std.debug.assert(harness.equals(tables.rawget(flat, kw("a")), harness.wrapInteger(1)));
    std.debug.assert(harness.equals(tables.rawget(flat, kw("b")), harness.wrapInteger(3)));
    std.debug.assert(harness.integerIs(r[7], 1));
    std.debug.assert(harness.integerIs(r[8], 0));
}

pub fn run() void {
    harness.init();

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

    vm_lifecycle.deinit();
}
