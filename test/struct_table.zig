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
//! A C contract can open with `sizeof(JanetStructHead) ==
//! offsetof(JanetStructHead, data)`. A translated head drops its flexible
//! array member, so `@offsetOf` does not compile and the header is recovered
//! with `@sizeOf` -- which would compare `@sizeOf` with itself.
//! `test/gc_mark.zig`'s `theHeadOffsets` derives the struct head's offset from
//! the allocator instead.
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
const repr = @import("repr");
const value = @import("subsystems").value;
const gc_alloc = @import("subsystems").gc_alloc;
const harness = @import("harness.zig");
const structs = @import("subsystems").value.structs;
const tables = @import("subsystems").value.tables;
const strings = @import("subsystems").value.strings;
const order = @import("subsystems").value.order;
const core_env = @import("subsystems").env;
const wrap = @import("subsystems").value.wrap;
const vm_lifecycle = @import("subsystems").lifecycle;
const expect = @import("expect.zig").expect;

const heap = harness.heap;

// --------------------------------------------------------------- helpers

fn structLength(st: [*]const tables.KV) u32 {
    return structs.head(st).length;
}

fn structCapacity(st: [*]const tables.KV) u32 {
    return structs.head(st).capacity;
}

fn structHash(st: [*]const tables.KV) i32 {
    return structs.head(st).hash;
}

fn structProto(st: [*]const tables.KV) ?[*]const tables.KV {
    return structs.head(st).proto;
}

fn setStructProto(st: [*]tables.KV, proto: ?[*]const tables.KV) void {
    structs.head(st).proto = proto;
}

fn kw(name: [*:0]const u8) repr.Value {
    return value.fromBytes(std.mem.span(name), .keyword);
}

/// The bucket a key would like to occupy. Spelled out rather than reusing
/// `janet_maphash`, so that a change to that macro shows up as a failure
/// rather than being tracked silently.
fn idealIndex(capacity: u32, key: repr.Value) u32 {
    const hash: u32 = @bitCast(order.hash(key));
    return hash & (capacity - 1);
}

/// Fill `out` with distinct integer keys that all want the same bucket in an
/// array of `capacity` buckets, and return that bucket's index.
///
/// Searched rather than hard-coded on purpose. Janet's integer hash is a
/// different subsystem and changes outright under `-Dprf`, so a fixed pair of
/// colliding keys would silently stop colliding and every case built on it
/// would keep passing while testing nothing.
fn findColliding(capacity: u32, out: []repr.Value) u32 {
    var target: u32 = 0;
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
fn findDistinctIndices(capacity: u32, out: []repr.Value) void {
    var used: [64]u32 = undefined;
    var found: usize = 0;
    expect(out.len <= capacity and capacity <= 64);

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
    expect(found == out.len);
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
fn sameLayout(a: [*]const tables.KV, b: [*]const tables.KV, capacity: u32) bool {
    var i: usize = 0;
    while (i < capacity) : (i += 1) {
        if (repr.typeOf(a[i].key) != repr.typeOf(b[i].key)) return false;
        if (repr.typeOf(a[i].value) != repr.typeOf(b[i].value)) return false;
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
    expect(structCapacity(structs.begin(0)) == 1);
    expect(structCapacity(structs.begin(1)) == 4);
    expect(structCapacity(structs.begin(2)) == 8);
    expect(structCapacity(structs.begin(3)) == 8);
    expect(structCapacity(structs.begin(4)) == 16);
}

fn structBeginInitialisesTheHead() void {
    const st = structs.begin(3);
    expect(structLength(st) == 3);
    expect(structCapacity(st) == 8);
    // The hash field is a running count of filled slots until `end` runs.
    expect(structHash(st) == 0);
    expect(structProto(st) == null);
    var i: usize = 0;
    while (i < structCapacity(st)) : (i += 1) {
        expect(harness.isType(st[i].key, repr.Tag.nil));
        expect(harness.isType(st[i].value, repr.Tag.nil));
    }
    expect(heap.memoryType(structs.head(st)) == gc_alloc.MemoryType.@"struct");
    expect(heap.onList(harness.vm().gc.blocks, structs.head(st)));
    expect(!heap.onList(harness.vm().gc.weak_blocks, structs.head(st)));
}

// ------------------------------------------------------- struct: insertion

/// The whole reason Robin Hood insertion is here. Two structs built from the
/// same pairs in different orders must have identical bucket arrays, because
/// `janet_struct_end` hashes the array and `janet_equals` compares the hash
/// first. Compared over the entire array rather than pair by pair, so that a
/// difference in *position* fails as loudly as a difference in contents.
fn structLayoutIsOrderIndependent() void {
    var keys: [6]repr.Value = undefined;
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
    expect(structCapacity(b) == capacity);
    expect(structCapacity(d) == capacity);

    const sa = structs.end(a);
    const sb = structs.end(b);
    const sd = structs.end(d);

    expect(sameLayout(sa, sb, capacity));
    expect(sameLayout(sa, sd, capacity));
    expect(structHash(sa) == structHash(sb));
    expect(structHash(sa) == structHash(sd));
    expect(harness.equals(wrap.fromStruct(sa), wrap.fromStruct(sb)));
}

/// Order-independence alone does not pin the *direction* of the displacement
/// rule: inverting the comparison consistently still yields a layout that is a
/// function of the pair set. What pins the direction is a run of keys that all
/// want the same bucket, where every displacement comparison ties and the full
/// hash decides. The pair with the larger hash keeps the earlier slot.
fn structCollisionRunIsOrderedByHash() void {
    const st = structs.begin(3);
    const capacity = structCapacity(st);
    var keys: [3]repr.Value = undefined;
    const index = findColliding(capacity, &keys);

    for (keys, 0..) |key, i| structs.put(st, key, harness.wrapInteger(@intCast(i)));
    const s = structs.end(st);

    var previous: i32 = 0;
    var n: u32 = 0;
    while (n < 3) : (n += 1) {
        const kv = &s[@mod(index + n, capacity)];
        expect(!harness.isType(kv.key, repr.Tag.nil));
        const hash = order.hash(kv.key);
        if (n > 0) expect(hash < previous);
        previous = hash;
    }

    // Inserted backwards, the run comes out the same.
    const st2 = structs.begin(3);
    var i: usize = 3;
    while (i > 0) {
        i -= 1;
        structs.put(st2, keys[i], harness.wrapInteger(@intCast(i)));
    }
    expect(sameLayout(s, structs.end(st2), capacity));
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
    expect(order.hash(as_keyword) == order.hash(as_string));
    expect(!harness.equals(as_keyword, as_string));
    // JANET_STRING sorts before JANET_KEYWORD, so the order is by type.
    expect(order.compare(as_string, as_keyword) == -1);

    const st = structs.begin(2);
    structs.put(st, as_keyword, harness.wrapInteger(1));
    structs.put(st, as_string, harness.wrapInteger(2));
    // Both landed: neither was mistaken for the other.
    expect(structHash(st) == 2);
    const s = structs.end(st);
    expect(structLength(s) == 2);
    expect(harness.equals(structs.rawget(s, as_keyword), harness.wrapInteger(1)));
    expect(harness.equals(structs.rawget(s, as_string), harness.wrapInteger(2)));

    const st2 = structs.begin(2);
    structs.put(st2, as_string, harness.wrapInteger(2));
    structs.put(st2, as_keyword, harness.wrapInteger(1));
    expect(sameLayout(s, structs.end(st2), structCapacity(s)));
}

/// Every pair that lands moves the running count in the hash field.
fn structPutCountsInTheHashField() void {
    const st = structs.begin(3);
    structs.put(st, kw("a"), harness.wrapInteger(1));
    expect(structHash(st) == 1);
    structs.put(st, kw("b"), harness.wrapInteger(2));
    expect(structHash(st) == 2);
    // A duplicate replaces rather than adds, so the count stands still.
    structs.put(st, kw("a"), harness.wrapInteger(9));
    expect(structHash(st) == 2);
}

fn structPutRejectsUnstorablePairs() void {
    const st = structs.begin(4);
    structs.put(st, wrap.fromNil(), harness.wrapInteger(1));
    expect(structHash(st) == 0);
    structs.put(st, kw("k"), wrap.fromNil());
    expect(structHash(st) == 0);
    structs.put(st, wrap.fromNumberSafe(std.math.nan(f64)), harness.wrapInteger(1));
    expect(structHash(st) == 0);
    // And one that is storable, so the three above are shown to be the reason
    // the count stayed at zero rather than the puts not working at all.
    structs.put(st, kw("k"), harness.wrapInteger(1));
    expect(structHash(st) == 1);
}

/// Past the declared length, a put is silently dropped.
fn structPutDropsTheSurplus() void {
    const st = structs.begin(1);
    structs.put(st, kw("a"), harness.wrapInteger(1));
    structs.put(st, kw("b"), harness.wrapInteger(2));
    expect(structHash(st) == 1);
    const s = structs.end(st);
    expect(structLength(s) == 1);
    expect(harness.equals(structs.rawget(s, kw("a")), harness.wrapInteger(1)));
    expect(harness.isType(structs.rawget(s, kw("b")), repr.Tag.nil));
}

/// `replace` is what separates `janet_struct_put` from the flattening path:
/// `struct/proto-flatten` walks child first and must not let a prototype's
/// binding overwrite the child's.
fn structPutExtHonoursReplace() void {
    const keep = structs.begin(2);
    structs.putExt(keep, kw("a"), harness.wrapInteger(1), false);
    structs.putExt(keep, kw("a"), harness.wrapInteger(2), false);
    expect(harness.equals(
        structs.rawget(structs.end(keep), kw("a")),
        harness.wrapInteger(1),
    ));

    const over = structs.begin(2);
    structs.putExt(over, kw("a"), harness.wrapInteger(1), true);
    structs.putExt(over, kw("a"), harness.wrapInteger(2), true);
    expect(harness.equals(
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
    expect(structCapacity(st) == 8);

    const s = structs.end(st);
    expect(s != st);
    expect(structLength(s) == 2);
    expect(structCapacity(s) == 8);
    expect(harness.equals(structs.rawget(s, kw("a")), harness.wrapInteger(2)));
    expect(harness.equals(structs.rawget(s, kw("b")), harness.wrapInteger(3)));
    // The prototype is not a bucket, so it is carried across by hand.
    expect(structProto(s) == sproto);
}

fn structEndKeepsTheArrayWhenTheCountIsExact() void {
    const st = structs.begin(2);
    structs.put(st, kw("a"), harness.wrapInteger(1));
    structs.put(st, kw("b"), harness.wrapInteger(2));
    expect(structs.end(st) == st);
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

    expect(sameLayout(sbare, swith, structCapacity(sbare)));
    expect(structHash(sbare) != structHash(swith));

    const buckets: u32 = @bitCast(value.hashDictionary(swith[0..structCapacity(swith)]));
    const proto: u32 = @bitCast(structHash(sp));
    const expected: i32 = @bitCast(buckets +% 2654435761 *% proto);
    expect(structHash(swith) == expected);
}

// ---------------------------------------------------------- struct: lookup

fn structFindReturnsAnEmptyBucketForAnAbsentKey() void {
    const st = structs.begin(2);
    structs.put(st, kw("a"), harness.wrapInteger(1));
    const s = structs.end(st);

    const hit = structs.find(s, kw("a"));
    expect(hit != null);
    expect(harness.equals(hit.?.value, harness.wrapInteger(1)));

    const miss = structs.find(s, kw("zz"));
    expect(miss != null);
    expect(harness.isType(miss.?.key, repr.Tag.nil));
    expect(harness.isType(structs.rawget(s, kw("zz")), repr.Tag.nil));
}

/// Build a chain `depth` deep and return the deepest struct. Entry `i` holds
/// the key `i` and its prototype is entry `i - 1`.
fn structChain(depth: i32) [*]const tables.KV {
    var proto: ?[*]const tables.KV = null;
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
    expect(harness.equals(
        structs.get(deep, harness.wrapInteger(top)),
        harness.wrapInteger(top),
    ));
    const last: i32 = top - (config.max_proto_depth - 1);
    expect(harness.equals(
        structs.get(deep, harness.wrapInteger(last)),
        harness.wrapInteger(last),
    ));
    expect(harness.isType(
        structs.get(deep, harness.wrapInteger(last - 1)),
        repr.Tag.nil,
    ));
    // rawget never leaves the head at all.
    expect(harness.isType(
        structs.rawget(deep, harness.wrapInteger(top - 1)),
        repr.Tag.nil,
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

    const own = structs.getEx(sch, kw("b"));
    expect(harness.equals(own.value, harness.wrapInteger(2)));
    expect(own.holder == sch);
    const inherited = structs.getEx(sch, kw("a"));
    expect(harness.equals(inherited.value, harness.wrapInteger(1)));
    expect(inherited.holder == sp);
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
    expect(t.count == 2);
    expect(t.capacity == value.capacityFor(structCapacity(s)));
    expect(t.capacity == 16);
    expect(harness.equals(tables.rawget(t, kw("a")), harness.wrapInteger(1)));
    expect(harness.equals(tables.rawget(t, kw("b")), harness.wrapInteger(2)));
    // The prototype is not carried; `struct/to-table` rebuilds it itself.
    expect(t.proto == null);
    expect(harness.isType(tables.get(t, kw("p")), repr.Tag.nil));
}

// ------------------------------------------------------- table: allocation

/// `janet_tablen` rounds strictly up, so a requested capacity of zero still
/// gets one bucket -- there is no such thing as an empty bucket array.
///
/// C reached one from a *negative* request, and the resulting table could not
/// be looked up in at all: `janet_maphash` masks the hash with `capacity - 1`,
/// which for a zero capacity is every bit set, so `janet_dict_find` treats the
/// whole hash as a bucket number and both of its loops are bounded by it
/// rather than by the capacity. `FOUND.md` records it, with the reproducer.
/// A capacity is a `usize` here and that request cannot be made, which is why
/// nothing below builds one.
fn tableCapacityRounding() void {
    expect(tables.new(0).capacity == 1);
    expect(tables.new(1).capacity == 2);
    expect(tables.new(4).capacity == 8);
}

fn tableConstructorMarksAndLists() void {
    const Case = struct {
        make: *const @TypeOf(tables.new),
        memory: gc_alloc.MemoryType,
        weak: bool,
    };
    const cases = [_]Case{
        .{ .make = &tables.new, .memory = gc_alloc.MemoryType.table, .weak = false },
        .{ .make = &tables.weakk, .memory = gc_alloc.MemoryType.table_weakk, .weak = true },
        .{ .make = &tables.weakv, .memory = gc_alloc.MemoryType.table_weakv, .weak = true },
        .{ .make = &tables.weakkv, .memory = gc_alloc.MemoryType.table_weakkv, .weak = true },
    };
    for (cases) |case| {
        const t = case.make(4);
        expect(heap.memoryType(t) == case.memory);
        expect(t.capacity == 8);
        expect(t.count == 0);
        expect(t.deleted == 0);
        expect(t.proto == null);
        // The memory type is what decides the heap list, and the two weak
        // variants of that decision are what the sweep depends on.
        expect(heap.onList(harness.vm().gc.weak_blocks, t) == case.weak);
        expect(heap.onList(harness.vm().gc.blocks, t) == !case.weak);
        // All four behave identically as dictionaries.
        tables.put(t, kw("a"), harness.wrapInteger(1));
        expect(harness.equals(tables.rawget(t, kw("a")), harness.wrapInteger(1)));
    }
}

/// A scratch table is caller-owned memory whose buckets come from the scratch
/// allocator. The flag lives in the same word as the memory type, which is
/// safe only because such a table is never `janet_gcalloc`ed -- so the flag is
/// asserted as the whole word, not as a bit.
fn tableInitUsesScratchMemory() void {
    var local: tables.Table = undefined;
    @memset(std.mem.asBytes(&local), 0xEE);
    _ = tables.init(&local, 4);
    expect(harness.gcBits(local.gc.flags) == 0x10000);
    expect(local.capacity == 8);
    expect(local.count == 0);
    expect(local.deleted == 0);
    expect(local.proto == null);

    // Grow it, so the rehash takes the scratch branch too.
    var i: i32 = 0;
    while (i < 40) : (i += 1) {
        tables.put(&local, harness.wrapInteger(i), harness.wrapInteger(i * 2));
    }
    expect(local.count == 40);
    expect(harness.gcBits(local.gc.flags) == 0x10000);
    i = 0;
    while (i < 40) : (i += 1) {
        expect(harness.equals(
            tables.rawget(&local, harness.wrapInteger(i)),
            harness.wrapInteger(i * 2),
        ));
    }
    tables.deinit(&local);
}

fn tableInitRawLeavesTheFlagClear() void {
    var local: tables.Table = undefined;
    @memset(std.mem.asBytes(&local), 0);
    _ = tables.initRaw(&local, 4);
    expect(harness.gcBits(local.gc.flags) == 0);
    expect(local.capacity == 8);
    tables.put(&local, kw("a"), harness.wrapInteger(1));
    expect(harness.equals(tables.rawget(&local, kw("a")), harness.wrapInteger(1)));
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
        expect(t.count == i + 1);
        expect(t.capacity == capacity);
    }
    var i: i32 = 0;
    while (i < 9) : (i += 1) {
        expect(harness.equals(
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
    expect(!harness.isType(bucket.?.key, repr.Tag.nil));

    const gone = tables.remove(t, kw("a"));
    expect(harness.equals(gone, harness.wrapInteger(1)));
    expect(t.count == 0);
    expect(t.deleted == 1);
    expect(harness.isType(bucket.?.key, repr.Tag.nil));
    expect(harness.isType(bucket.?.value, repr.Tag.boolean));
    expect(!repr.truthy(bucket.?.value));

    // Removing an absent key changes nothing.
    expect(harness.isType(tables.remove(t, kw("zz")), repr.Tag.nil));
    expect(t.count == 0);
    expect(t.deleted == 1);
}

/// The property the tombstone exists for. Two keys that want the same bucket,
/// the first removed: the second must still be found through the hole.
fn aTombstoneDoesNotTruncateAProbeRun() void {
    const t = tables.new(4);
    expect(t.capacity == 8);
    var keys: [2]repr.Value = undefined;
    const index = findColliding(@intCast(t.capacity), &keys);

    tables.put(t, keys[0], harness.wrapInteger(10));
    tables.put(t, keys[1], harness.wrapInteger(20));
    expect(t.count == 2);
    expect(t.capacity == 8);
    // The second key really did displace: it is not in its ideal bucket.
    expect(tables.find(t, keys[1]) != &t.slots()[@as(usize, @intCast(index))]);

    _ = tables.remove(t, keys[0]);
    expect(harness.equals(tables.rawget(t, keys[1]), harness.wrapInteger(20)));
    expect(harness.isType(tables.rawget(t, keys[0]), repr.Tag.nil));
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
    expect(t.deleted == 1);
    tables.put(t, kw("a"), harness.wrapInteger(2));
    expect(t.count == 1);
    expect(t.deleted == 1);
    expect(tables.find(t, kw("a")) != first);
    expect(harness.isType(first.?.key, repr.Tag.nil));
    expect(harness.isType(first.?.value, repr.Tag.boolean));
    expect(harness.equals(tables.rawget(t, kw("a")), harness.wrapInteger(2)));

    // Otherwise a tombstone is reclaimed only by a rehash, and the rehash is
    // driven by the tombstone count alone -- a table with no live pairs at all
    // still grows. Keys at pairwise-distinct ideal buckets, so that each
    // removal leaves a tombstone instead of the next insert reusing the last
    // one. Capacity 8 trips at `count + deleted >= 4`.
    const churned = tables.new(4);
    expect(churned.capacity == 8);
    var keys: [5]repr.Value = undefined;
    findDistinctIndices(@intCast(churned.capacity), &keys);
    for (keys[0..4], 0..) |key, i| {
        tables.put(churned, key, harness.wrapInteger(@intCast(i)));
        _ = tables.remove(churned, key);
    }
    expect(churned.count == 0);
    expect(churned.deleted == 4);
    expect(churned.capacity == 8);

    tables.put(churned, keys[4], harness.wrapInteger(4));
    // `janet_tablen(2 * 0 + 2)` is 4: the new array is sized from the live
    // count, so a table that was only ever churned shrinks.
    expect(churned.capacity == 4);
    expect(churned.deleted == 0);
    expect(churned.count == 1);
    expect(harness.equals(
        tables.rawget(churned, keys[4]),
        harness.wrapInteger(4),
    ));
}

// -------------------------------------------------------- table: put rules

fn tablePutRejectsUnstorableKeys() void {
    const t = tables.new(4);
    tables.put(t, wrap.fromNil(), harness.wrapInteger(1));
    expect(t.count == 0);
    tables.put(t, wrap.fromNumberSafe(std.math.nan(f64)), harness.wrapInteger(1));
    expect(t.count == 0);
    tables.put(t, kw("k"), harness.wrapInteger(1));
    expect(t.count == 1);
}

/// A nil value is a removal, not a stored nil. This is what makes an absent
/// key and a nil-valued key indistinguishable.
fn tablePutNilRemoves() void {
    const t = tables.new(4);
    tables.put(t, kw("a"), harness.wrapInteger(1));
    expect(t.count == 1);
    tables.put(t, kw("a"), wrap.fromNil());
    expect(t.count == 0);
    expect(t.deleted == 1);
    expect(harness.isType(tables.rawget(t, kw("a")), repr.Tag.nil));

    // And a nil value for an absent key is not a removal of anything.
    tables.put(t, kw("zz"), wrap.fromNil());
    expect(t.count == 0);
    expect(t.deleted == 1);
}

fn tablePutUpdatesInPlace() void {
    const t = tables.new(4);
    tables.put(t, kw("a"), harness.wrapInteger(1));
    const bucket = tables.find(t, kw("a"));
    const capacity = t.capacity;
    tables.put(t, kw("a"), harness.wrapInteger(2));
    expect(t.count == 1);
    expect(t.capacity == capacity);
    expect(tables.find(t, kw("a")) == bucket);
    expect(harness.equals(bucket.?.value, harness.wrapInteger(2)));
}

// ----------------------------------------------------------- table: lookup

fn tableGetBoundsThePrototypeChain() void {
    var deep: ?*tables.Table = null;
    var i: i32 = 0;
    while (i < config.max_proto_depth + 5) : (i += 1) {
        const t = tables.new(1);
        tables.put(t, harness.wrapInteger(i), harness.wrapInteger(i));
        t.proto = deep;
        deep = t;
    }
    const top: i32 = config.max_proto_depth + 4;
    expect(harness.equals(
        tables.get(deep.?, harness.wrapInteger(top)),
        harness.wrapInteger(top),
    ));
    const last: i32 = top - (config.max_proto_depth - 1);
    expect(harness.equals(
        tables.get(deep.?, harness.wrapInteger(last)),
        harness.wrapInteger(last),
    ));
    expect(harness.isType(
        tables.get(deep.?, harness.wrapInteger(last - 1)),
        repr.Tag.nil,
    ));
    expect(harness.isType(
        tables.rawget(deep.?, harness.wrapInteger(top - 1)),
        repr.Tag.nil,
    ));
}

fn tableGetExReportsTheOwner() void {
    const proto = tables.new(2);
    tables.put(proto, kw("a"), harness.wrapInteger(1));
    const child = tables.new(2);
    tables.put(child, kw("b"), harness.wrapInteger(2));
    child.proto = proto;

    const own = tables.getEx(child, kw("b"));
    expect(harness.equals(own.value, harness.wrapInteger(2)));
    expect(own.holder == child);
    const inherited = tables.getEx(child, kw("a"));
    expect(harness.equals(inherited.value, harness.wrapInteger(1)));
    expect(inherited.holder == proto);
}

/// Looking a key up from raw bytes, without interning it first. Used by the
/// compiler against the core environment.
fn tableGetKeyword() void {
    const proto = tables.new(4);
    tables.put(proto, kw("deep"), harness.wrapInteger(2));
    const t = tables.new(4);
    tables.put(t, kw("hello"), harness.wrapInteger(1));
    t.proto = proto;

    expect(harness.equals(
        tables.getKeyword(t, "hello"),
        harness.wrapInteger(1),
    ));
    expect(harness.equals(
        tables.getKeyword(t, "deep"),
        harness.wrapInteger(2),
    ));
    expect(harness.isType(tables.getKeyword(t, "missing"), repr.Tag.nil));
    // A prefix of a present key is not that key.
    expect(harness.isType(tables.getKeyword(t, "hell"), repr.Tag.nil));
}

// -------------------------------------------------------- table: wholesale

/// Clearing keeps the bucket array and the prototype, and drops both counts.
fn tableClear() void {
    const proto = tables.new(2);
    const t = tables.new(4);
    t.proto = proto;
    var i: i32 = 0;
    while (i < 6) : (i += 1) tables.put(t, harness.wrapInteger(i), harness.wrapInteger(i));
    _ = tables.remove(t, harness.wrapInteger(0));
    const capacity = t.capacity;
    const data = t.data;
    expect(t.deleted == 1);

    tables.clear(t);
    expect(t.count == 0);
    expect(t.deleted == 0);
    expect(t.capacity == capacity);
    expect(t.data == data);
    expect(t.proto == proto);
    var n: usize = 0;
    while (n < capacity) : (n += 1) {
        expect(harness.isType(data.?[n].key, repr.Tag.nil));
        expect(harness.isType(data.?[n].value, repr.Tag.nil));
    }
}

/// A clone copies the bucket array verbatim, so it keeps the original's
/// tombstones and its `deleted` count rather than compacting them away.
fn tableCloneCopiesTheLayout() void {
    const proto = tables.new(2);
    const t = tables.new(4);
    t.proto = proto;
    var i: i32 = 0;
    while (i < 4) : (i += 1) tables.put(t, harness.wrapInteger(i), harness.wrapInteger(i));
    _ = tables.remove(t, harness.wrapInteger(1));
    expect(t.deleted == 1);

    const clone = tables.clone(t);
    expect(clone != t);
    expect(clone.data != t.data);
    expect(clone.count == t.count);
    expect(clone.capacity == t.capacity);
    expect(clone.deleted == t.deleted);
    // The prototype is shared, not cloned.
    expect(clone.proto == proto);
    expect(heap.memoryType(clone) == gc_alloc.MemoryType.table);
    expect(sameLayout(clone.data.?, t.data.?, @intCast(t.capacity)));

    // And the two are independent afterwards.
    tables.put(clone, kw("new"), harness.wrapInteger(9));
    expect(harness.isType(tables.rawget(t, kw("new")), repr.Tag.nil));
}

/// Cloning a table with no bucket array. This is the `memcpy(dst, NULL, 0)`
/// that `FOUND.md` records against the C original, and it is the only thing
/// asserted here: the clone's fields, not its usability. A zero-capacity table
/// cannot be looked up in on either side -- see `tableCapacityRounding` -- so
/// a clone of one cannot be either.
fn tableCloneOfAnEmptyArray() void {
    // No constructor produces a null bucket array any more -- see
    // `tableCapacityRounding` -- so the state is built directly, which is what
    // a caller that zeroed a `Table` and never initialised it would hold.
    var zeroed: tables.Table = .{};
    const empty: *tables.Table = &zeroed;
    expect(empty.data == null);
    const clone = tables.clone(empty);
    expect(clone != empty);
    expect(clone.count == 0);
    expect(clone.capacity == 0);
    expect(clone.deleted == 0);
    expect(heap.memoryType(clone) == gc_alloc.MemoryType.table);
}

/// Merging takes the source's own pairs only. Its prototype is not consulted,
/// which is what separates a merge from a flatten.
fn tableMerge() void {
    const proto = tables.new(2);
    tables.put(proto, kw("p"), harness.wrapInteger(9));
    const source = tables.new(2);
    tables.put(source, kw("a"), harness.wrapInteger(1));
    source.proto = proto;

    const destination = tables.new(2);
    tables.put(destination, kw("a"), harness.wrapInteger(0));
    tables.put(destination, kw("b"), harness.wrapInteger(2));
    tables.mergeTable(destination, source);
    expect(harness.equals(
        tables.rawget(destination, kw("a")),
        harness.wrapInteger(1),
    ));
    expect(harness.equals(
        tables.rawget(destination, kw("b")),
        harness.wrapInteger(2),
    ));
    expect(harness.isType(tables.rawget(destination, kw("p")), repr.Tag.nil));

    const sp = structs.begin(1);
    structs.put(sp, kw("s"), harness.wrapInteger(5));
    const sproto = structs.end(sp);
    const ss = structs.begin(1);
    structs.put(ss, kw("c"), harness.wrapInteger(3));
    setStructProto(ss, sproto);
    const s = structs.end(ss);

    tables.mergeStruct(destination, s);
    expect(harness.equals(
        tables.rawget(destination, kw("c")),
        harness.wrapInteger(3),
    ));
    expect(harness.isType(tables.rawget(destination, kw("s")), repr.Tag.nil));
}

/// The struct is begun at the table's live count, so tombstones cost nothing.
fn tableToStructIgnoresTombstones() void {
    const t = tables.new(4);
    var i: i32 = 0;
    while (i < 6) : (i += 1) tables.put(t, harness.wrapInteger(i), harness.wrapInteger(i));
    _ = tables.remove(t, harness.wrapInteger(2));
    _ = tables.remove(t, harness.wrapInteger(3));
    expect(t.count == 4);
    expect(t.deleted == 2);

    const s = tables.toStruct(t);
    expect(structLength(s) == 4);
    expect(structProto(s) == null);
    expect(harness.equals(
        structs.rawget(s, harness.wrapInteger(0)),
        harness.wrapInteger(0),
    ));
    expect(harness.isType(
        structs.rawget(s, harness.wrapInteger(2)),
        repr.Tag.nil,
    ));

    // Round-tripping a struct through a table and back reproduces it exactly,
    // which is the order-independence property seen from the other side: the
    // table hands the pairs back in bucket order, not insertion order.
    const back = tables.toStruct(structs.toTable(s));
    expect(structCapacity(back) == structCapacity(s));
    expect(sameLayout(back, s, structCapacity(s)));
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
    parent.proto = grandparent;
    const child = tables.new(2);
    tables.put(child, kw("a"), harness.wrapInteger(1));
    child.proto = parent;

    const flat = tables.protoFlatten(child);
    expect(flat.proto == null);
    expect(flat.count == 3);
    expect(harness.equals(tables.rawget(flat, kw("a")), harness.wrapInteger(1)));
    expect(harness.equals(tables.rawget(flat, kw("b")), harness.wrapInteger(20)));
    expect(harness.equals(tables.rawget(flat, kw("c")), harness.wrapInteger(30)));

    // A tombstone in a source table is not carried into the result.
    _ = tables.remove(child, kw("a"));
    const again = tables.protoFlatten(child);
    expect(again.deleted == 0);
    expect(harness.equals(tables.rawget(again, kw("a")), harness.wrapInteger(2)));
}

// ---------------------------------------------------- through the runtime

/// The same properties once more, reached the way a Janet program reaches
/// them, so that the entry points above are shown to be the ones the language
/// is actually built on.
fn fromJanet() void {
    var out: repr.Value = undefined;
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
    expect(core_env.dostring(harness.coreEnv(), source, "struct_table", &out) == 0);
    const r = wrap.toTuple(out);
    expect(repr.truthy(r[0]));
    expect(repr.truthy(r[1]));
    expect(harness.integerIs(r[2], 1));
    expect(harness.isType(r[3], repr.Tag.nil));
    expect(harness.integerIs(r[4], 0));
    expect(harness.integerIs(r[5], 2));
    const flat = wrap.toTable(r[6]);
    expect(harness.equals(tables.rawget(flat, kw("a")), harness.wrapInteger(1)));
    expect(harness.equals(tables.rawget(flat, kw("b")), harness.wrapInteger(3)));
    expect(harness.integerIs(r[7], 1));
    expect(harness.integerIs(r[8], 0));
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
