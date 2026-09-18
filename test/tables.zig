//! Behavioral contract for the table, including the three weak variants.
//!
//! A table's layout is not observable and depends on deletion history as well
//! as insertion order. What is checkable is the policy: the exact capacity
//! after each growth, the tombstone a removal leaves, the fact that a
//! tombstone does not truncate a probe run through it, and the fact that
//! tombstones are reclaimed only by a rehash. Those are asserted as exact
//! numbers, because a policy asserted as an inequality passes for almost any
//! implementation.
//!
//! The immutable dictionary beside it is the map, whose contract is
//! `test/maps.zig`. The two meet in `toMap` and `mergeMap`, which are here
//! because a table is what each of them reads or writes.
//!
//! ## Two things deliberately not covered
//!
//! Weak tables are checked only for the memory type their constructor stamps
//! and for the heap list that type puts them on. What the collector then does
//! with them belongs to `test/gc_sweep.zig`, which already has it.
//!
//! `protoFlatten` walks a prototype chain to `max_proto_depth` and no
//! further, which is what makes a cyclic chain terminate. The suite is where
//! that is pinned, because the value it produces is a Janet-level one.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const config = @import("config");
const core_env = @import("subsystems").env;
const expect = @import("expect.zig").expect;
const gc_alloc = @import("subsystems").gc_alloc;
const harness = @import("harness.zig");
const heap = harness.heap;

const order = @import("subsystems").value.order;
const repr = @import("repr");
const maps = @import("subsystems").value.maps;
const tables = @import("subsystems").value.tables;
const value = @import("subsystems").value;
const vm_lifecycle = @import("subsystems").lifecycle;
const wrap = @import("subsystems").value.wrap;

// ==========================================================================
// Cases
// ==========================================================================

fn kw(name: [*:0]const u8) repr.Value {
    return value.fromBytes(std.mem.span(name), .keyword);
}

/// The bucket a key would like to occupy. Spelled out rather than reusing
/// `value.zig`'s `mapHash`, so that a change there shows up as a failure
/// rather than being tracked silently.
fn idealIndex(capacity: u32, key: repr.Value) u32 {
    const hash: u32 = @bitCast(order.hash(key));
    return hash & (capacity - 1);
}

/// Fill `out` with distinct integer keys that all map to the same bucket in an
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

/// Whether two bucket arrays have the same pair in every position.
///
/// Deliberately not a byte comparison. Under `-Dnanbox=false` a `Janet` is a
/// struct with an eight-byte union and a four-byte type tag, so it has four
/// bytes of tail padding that nothing ever writes, and two identical values
/// compare equal and differ byte for byte. A byte-wise comparison there fails
/// on garbage from the allocator rather than on layout, and passes or fails at
/// random. The layout claim is about which value sits in which bucket, so it
/// is asserted that way.
fn sameLayout(a: [*]const tables.Keyval, b: [*]const tables.Keyval, capacity: u32) bool {
    var i: usize = 0;
    while (i < capacity) : (i += 1) {
        if (repr.typeOf(a[i].key) != repr.typeOf(b[i].key)) return false;
        if (repr.typeOf(a[i].value) != repr.typeOf(b[i].value)) return false;
        if (!harness.equals(a[i].key, b[i].key)) return false;
        if (!harness.equals(a[i].value, b[i].value)) return false;
    }
    return true;
}

/// `value.capacityFor` rounds strictly up, so a request for zero still gets
/// one bucket, there being no such thing as an empty bucket array.
///
/// A *negative* request reaches a capacity of zero, and such a table cannot be
/// looked up in at all: `mapHash` masks the hash with `capacity - 1`, which
/// for a zero capacity is every bit set, so `dictionaryFind` treats the whole
/// hash as a bucket number and both of its loops are bounded by it rather than
/// by the capacity. A capacity is a `usize` here and that request cannot be
/// made, so nothing below builds one.
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
/// safe only because such a table is never `gc.gcalloc`ed, so the flag is
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

/// The growth policy, as exact capacities. A rehash happens when twice the
/// live pairs plus the tombstones plus one would exceed the capacity, and the
/// new capacity is `value.capacityFor(2 * count + 2)`.
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

/// A removal leaves a nil key and a *false* value. The falseness is the
/// tombstone marker: `value.dictionaryFind` stops only where key and value are
/// both nil, so a run of probes passes through the hole instead of ending at
/// it.
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

/// The property the tombstone exists for: two keys that map to one bucket,
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

/// A rehash is the only thing that reclaims a tombstone.
///
/// It is tempting to expect re-inserting the key that was just removed to fill
/// its own hole, and the decrement of `deleted` in `tables.put` reads as
/// though it does. It does not. `value.dictionaryFind` returns the first
/// *truly* empty bucket it reaches and falls back on a remembered tombstone if
/// the array has no empty bucket anywhere, and the growth policy keeps the
/// array at most half full counting tombstones, so an empty bucket always
/// exists. The re-inserted key therefore takes the slot *after* its own hole
/// and the tombstone stays, so `put` has none to retire.
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
    // driven by the tombstone count alone, and a table with no live pairs
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
    // `value.capacityFor(2 * 0 + 2)` is 4: the new array is sized from the
    // live count, so a table that was only ever churned shrinks.
    expect(churned.capacity == 4);
    expect(churned.deleted == 0);
    expect(churned.count == 1);
    expect(harness.equals(
        tables.rawget(churned, keys[4]),
        harness.wrapInteger(4),
    ));
}

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

fn tableGetBoundsThePrototypeChain() void {
    const top: i32 = config.max_proto_depth + 4;
    const last: i32 = top - (config.max_proto_depth - 1);
    var deep: ?*tables.Table = null;
    var i: i32 = 0;
    while (i < config.max_proto_depth + 5) : (i += 1) {
        const t = tables.new(1);
        tables.put(t, harness.wrapInteger(i), harness.wrapInteger(i));
        // The last table the walk reaches and the first it does not also hold
        // a keyword, for `getKeyword`.
        if (i == last) tables.put(t, kw("last"), harness.wrapInteger(i));
        if (i == last - 1) tables.put(t, kw("past"), harness.wrapInteger(i));
        t.proto = deep;
        deep = t;
    }
    expect(harness.equals(
        tables.get(deep.?, harness.wrapInteger(top)),
        harness.wrapInteger(top),
    ));
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

    // `getEx`, `getKeyword` and `protoFlatten` walk the same bound.
    const found = tables.getEx(deep.?, harness.wrapInteger(last));
    expect(harness.equals(found.value, harness.wrapInteger(last)));
    expect(harness.equals(
        tables.rawget(found.holder.?, harness.wrapInteger(last)),
        harness.wrapInteger(last),
    ));
    expect(tables.getEx(deep.?, harness.wrapInteger(last - 1)).holder == null);
    expect(harness.equals(tables.getKeyword(deep.?, "last"), harness.wrapInteger(last)));
    expect(harness.isType(tables.getKeyword(deep.?, "past"), repr.Tag.nil));
    const flat = tables.protoFlatten(deep.?);
    expect(flat.count == config.max_proto_depth + 1);
    expect(harness.equals(
        tables.rawget(flat, harness.wrapInteger(last)),
        harness.wrapInteger(last),
    ));
    expect(harness.isType(tables.rawget(flat, harness.wrapInteger(last - 1)), repr.Tag.nil));
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

    // Nor is it when the two hashes are equal: the length is compared too.
    // `word` and `wordmdtlsu` have the same unkeyed byte hash, and `-Dprf`
    // keys the hash per process, so no fixed pair collides there.
    if (!config.prf) {
        expect(value.hashBytes("word") == value.hashBytes("wordmdtlsu"));
        const long = tables.new(4);
        tables.put(long, kw("wordmdtlsu"), harness.wrapInteger(3));
        expect(harness.isType(tables.getKeyword(long, "word"), repr.Tag.nil));
        expect(harness.equals(
            tables.getKeyword(long, "wordmdtlsu"),
            harness.wrapInteger(3),
        ));
    }
}

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

/// Cloning a table with no bucket array, which is the `memcpy(dst, NULL, 0)`
/// that `safe_memcpy` exists for. The clone's fields are the only thing
/// asserted here, not its usability: a zero-capacity table cannot be looked up
/// in, for which see `tableCapacityRounding`, so a clone of one is not
/// either.
fn tableCloneOfAnEmptyArray() void {
    // No constructor produces a null bucket array, for which see
    // `tableCapacityRounding`, so the state is built directly. It is what a
    // caller that zeroed a `Table` and never initialised it would have.
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

    tables.mergeMap(destination, maps.build(.map, &.{
        kw("c"), harness.wrapInteger(3),
        kw("d"), harness.wrapInteger(4),
    }));
    expect(harness.equals(
        tables.rawget(destination, kw("c")),
        harness.wrapInteger(3),
    ));
    expect(harness.equals(
        tables.rawget(destination, kw("d")),
        harness.wrapInteger(4),
    ));
}

/// A tombstone is not an entry, so it does not reach the map.
fn tableToMapIgnoresTombstones() void {
    const t = tables.new(4);
    var i: i32 = 0;
    while (i < 6) : (i += 1) tables.put(t, harness.wrapInteger(i), harness.wrapInteger(i));
    _ = tables.remove(t, harness.wrapInteger(2));
    _ = tables.remove(t, harness.wrapInteger(3));
    expect(t.count == 4);
    expect(t.deleted == 2);

    const m = tables.toMap(t);
    expect(m.count == 4);
    expect(harness.equals(
        maps.lookup(m, harness.wrapInteger(0)),
        harness.wrapInteger(0),
    ));
    expect(harness.isType(
        maps.lookup(m, harness.wrapInteger(2)),
        repr.Tag.nil,
    ));

    // Round-tripping a map through a table and back gives an equal map, which
    // is the order-independence property seen from the other side: the table
    // hands the pairs back in bucket order, not insertion order.
    const back = tables.toMap(t);
    expect(harness.equals(wrap.fromMap(back), wrap.fromMap(m)));
}

/// Flattening walks child first and never overwrites, so a binding nearer the
/// child wins, which is the precedence a chained lookup would have given.
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

    // A tombstone in a source table does not reach the result.
    _ = tables.remove(child, kw("a"));
    const again = tables.protoFlatten(child);
    expect(again.deleted == 0);
    expect(harness.equals(tables.rawget(again, kw("a")), harness.wrapInteger(2)));

    // The result grows by `put`'s policy, as exact capacities: a table of `n`
    // keys flattens into the capacity `tableGrowthCapacities` has after `n`
    // puts.
    const expected = [9]usize{ 4, 4, 8, 8, 16, 16, 16, 16, 32 };
    const source = tables.new(16);
    for (expected, 0..) |capacity, n| {
        tables.put(source, harness.wrapInteger(@intCast(n)), harness.wrapInteger(@intCast(n)));
        const grown = tables.protoFlatten(source);
        expect(grown.count == n + 1);
        expect(grown.capacity == capacity);
    }
}

/// The same properties once more, reached the way a Janet program reaches
/// them, so that the entry points above are shown to be the ones the language
/// is actually built on.
fn fromJanet() void {
    var out: repr.Value = undefined;
    const source =
        \\[(= {1 2 3 4} {3 4 1 2})
        \\ (= (hash {1 2 3 4}) (hash {3 4 1 2}))
        \\ (do (def t !{:a 1}) (put t :a nil) (length t))
        \\ (do (def t !{:a 1}) (table/setproto t !{:b 2}) (get t :b))
        \\ (table/proto-flatten (table/setproto !{:a 1} !{:a 2 :b 3}))
        \\ (length (table/to-map (do (def t !{:a 1 :b 2}) (put t :a nil) t)))
        \\ (do (def t !{:a 1}) (table/clear t) (length t))]
    ;
    expect(core_env.dostring(harness.coreEnv(), source, "tables", &out) == 0);
    const r = harness.elems(out);
    expect(repr.truthy(r[0]));
    expect(repr.truthy(r[1]));
    expect(harness.integerIs(r[2], 0));
    expect(harness.integerIs(r[3], 2));
    const flat = wrap.toTable(r[4]);
    expect(harness.equals(tables.rawget(flat, kw("a")), harness.wrapInteger(1)));
    expect(harness.equals(tables.rawget(flat, kw("b")), harness.wrapInteger(3)));
    expect(harness.integerIs(r[5], 1));
    expect(harness.integerIs(r[6], 0));
}

// ==========================================================================
// Entry
// ==========================================================================

pub fn run() void {
    harness.init();

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
    tableToMapIgnoresTombstones();
    tableProtoFlatten();

    fromJanet();

    vm_lifecycle.deinit();
}
