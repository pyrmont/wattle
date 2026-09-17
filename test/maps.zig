//! Behavioral contract for `core/map` and `core/set`: the shape of a trie,
//! reading and iterating, persistence across updates, equality, order and
//! hash.
//!
//! The oracle is a list of entries searched by `order.equals`, which shares
//! no code with the trie it checks. Each case updates a list the way it
//! updates a collection, and compares the two by count, by lookup and by
//! iteration.
//!
//! Keys whose hashes the case chooses come from a probe type whose `hash`
//! callback returns a stored hash and whose `compare` callback orders by a
//! stored id. Probes with one hash and different ids are distinct keys that no
//! depth of the trie can separate, and probes whose hashes differ in one bit
//! separate at the level that reads that bit.
//!
//! Every collection a case keeps across a collection is rooted, and so is every
//! key a case keeps outside one.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abstract_type = @import("subsystems").abstract_type;
const abstracts = @import("subsystems").value.abstracts;
const arrays = @import("subsystems").value.arrays;
const expect = @import("expect.zig").expect;
const gc_alloc = @import("subsystems").gc_alloc;
const gc_mark = @import("subsystems").gc_mark;
const harness = @import("harness.zig");
const maps = @import("subsystems").value.maps;
const order = @import("subsystems").value.order;
const repr = @import("repr");
const value = @import("subsystems").value;
const vm_lifecycle = @import("subsystems").lifecycle;
const wrap = @import("subsystems").value.wrap;

// ==========================================================================
// Constants
// ==========================================================================

/// An empty payload, which `maps.put` and `maps.remove` copy rather than
/// change.
const empty_trie: maps.Trie = .{};

/// The index in the key pool of the first probe.
const probe_start = 150;

/// The hash the probes' hashes are made from.
const base_hash: u32 = 0x1234_5678;

/// A probe key: a hash of the case's choosing and an id that tells two probes
/// with one hash apart.
const probe_type = abstract_type.define(Probe, .{
    .name = "maps-test/probe",
    .hash = probeHash,
    .compare = probeCompare,
});

// ==========================================================================
// Types
// ==========================================================================

/// An entry the oracle holds: a key and, for a map, its value.
const Entry = struct {
    key: repr.Value,
    value: repr.Value,
};

/// The oracle: the entries a collection should have, in no order.
const Oracle = std.ArrayListUnmanaged(Entry);

/// A probe's payload.
const Probe = struct {
    hash: u32,
    id: i32,
};

/// A version of a collection and the entries it should have.
const Version = struct {
    trie: *maps.Trie,
    entries: Oracle,
};

// ==========================================================================
// Cases
// ==========================================================================

/// A new probe with `hash` and `id`.
fn probe(hash: u32, id: i32) repr.Value {
    const payload: *Probe = @ptrCast(@alignCast(abstracts.newBytes(&probe_type, @sizeOf(Probe))));
    payload.* = .{ .hash = hash, .id = id };
    return wrap.fromAbstract(payload);
}

fn probeCompare(a: *const Probe, b: *const Probe) i32 {
    return if (a.id < b.id) -1 else if (a.id > b.id) 1 else 0;
}

fn probeHash(p: *const Probe, _: usize) i32 {
    return @bitCast(p.hash);
}

/// The keys the random cases draw from, in a rooted array: integers, strings,
/// and probes in four groups. Four probes share one hash. Two differ from it
/// in bit 31, so they separate only at the deepest level. Two differ in bit
/// 12, and two in bit 0, so they separate at the third level and at the root.
fn keyPool() *arrays.Array {
    const pool = arrays.new(200);
    gc_alloc.gcroot(wrap.fromArray(pool));
    for (0..120) |i| harness.arrayPush(pool, harness.wrapInteger(@intCast(i)));
    for (0..30) |i| {
        var name: [16]u8 = undefined;
        const text = std.fmt.bufPrint(&name, "key-{d}", .{i}) catch unreachable;
        harness.arrayPush(pool, value.fromBytes(text, .string));
    }
    for (0..4) |i| harness.arrayPush(pool, probe(base_hash, @intCast(i)));
    for (4..6) |i| harness.arrayPush(pool, probe(base_hash ^ (1 << 31), @intCast(i)));
    for (6..8) |i| harness.arrayPush(pool, probe(base_hash ^ (1 << 12), @intCast(i)));
    for (8..10) |i| harness.arrayPush(pool, probe(base_hash ^ 1, @intCast(i)));
    return pool;
}

/// A collection of `kind` made from `start` by adding the entries of
/// `entries` in the order given.
fn buildOn(kind: maps.Kind, start: *const maps.Trie, entries: []const Entry) *maps.Trie {
    var t = maps.remove(start, kind, wrap.fromNil());
    for (entries) |*e| t = maps.put(t, kind, entryOf(kind, e));
    return t;
}

/// The values of `e` as an entry of `kind`.
fn entryOf(kind: maps.Kind, e: *const Entry) []const repr.Value {
    const both: *const [2]repr.Value = @ptrCast(e);
    return both[0..kind.entryWidth()];
}

/// The index in `entries` of the entry whose key is `key`, or null.
fn oracleFind(entries: []const Entry, key: repr.Value) ?usize {
    for (entries, 0..) |e, i| {
        if (order.equals(e.key, key)) return i;
    }
    return null;
}

/// Asserts that every node under `node` keeps the rules `maps.zig`'s header
/// gives for the shape of a trie, and returns how many entries there are.
fn checkNode(kind: maps.Kind, node: *maps.Node, shift: u32, is_root: bool) usize {
    const w = kind.entryWidth();
    const items = maps.entries(node);
    const kids = maps.children(node);
    const collision = node.gc.flags.own & maps.own_collision != 0;
    expect(maps.kindOf(&node.gc) == kind);
    if (collision) {
        expect(!is_root);
        expect(node.len >= 2);
        expect(node.datamap == 0 and node.nodemap == 0);
        for (0..node.len) |i| {
            expect(@as(u32, @bitCast(order.hash(items[i * w]))) == node.hash);
            if (i > 0) expect(order.compare(items[(i - 1) * w], items[i * w]) < 0);
        }
        return node.len;
    }
    expect(node.hash == 0);
    expect(node.len == @popCount(node.datamap));
    expect(node.datamap & node.nodemap == 0);
    // Each entry's key selects the slot it is stored in, and the entries are
    // in slot order.
    var datamap = node.datamap;
    var i: usize = 0;
    while (datamap != 0) : (i += 1) {
        const slot: u5 = @intCast(@ctz(datamap));
        datamap &= datamap - 1;
        const hash: u32 = @bitCast(order.hash(items[i * w]));
        expect((hash >> @as(u5, @intCast(shift))) & 31 == slot);
        if (kind == .map) expect(!harness.isType(items[i * w + 1], repr.Tag.nil));
    }
    if (!is_root) {
        expect(node.len + kids.len > 0);
        expect(!(node.len == 1 and kids.len == 0));
        if (node.len == 0 and kids.len == 1) {
            const only = maps.asNode(kids[0].?);
            expect(only.gc.flags.own & maps.own_collision == 0);
        }
    }
    var total: usize = node.len;
    for (kids) |slot| total += checkNode(kind, maps.asNode(slot.?), shift + 5, false);
    return total;
}

/// Asserts that `t` has exactly the entries of `entries`: by count, by lookup,
/// by iteration through its type's `next` callback, and by the shape of its
/// trie.
fn expectEntries(kind: maps.Kind, t: *maps.Trie, entries: []const Entry) !void {
    expect(t.count == entries.len);
    if (t.root) |root| {
        expect(checkNode(kind, root, 0, true) == entries.len);
    } else {
        expect(entries.len == 0);
    }
    for (entries) |e| {
        const found = maps.find(t, kind, e.key) orelse {
            expect(false);
            continue;
        };
        expect(order.equals(found[0], e.key));
        if (kind == .map) expect(order.equals(found[1], e.value));
    }

    const next = kind.abstractType().next.?;
    var seen: usize = 0;
    var key = try next(t, wrap.fromNil());
    while (!harness.isType(key, repr.Tag.nil)) : (key = try next(t, key)) {
        expect(oracleFind(entries, key) != null);
        seen += 1;
        expect(seen <= entries.len);
    }
    expect(seen == entries.len);
}

/// Whether two tries are the same node by node.
fn sameShape(a: ?*maps.Node, b: ?*maps.Node) bool {
    const x = a orelse return b == null;
    const y = b orelse return false;
    if (x.gc.flags.own & maps.own_collision != y.gc.flags.own & maps.own_collision) return false;
    if (x.datamap != y.datamap or x.nodemap != y.nodemap or x.len != y.len or x.hash != y.hash) return false;
    for (maps.entries(x), maps.entries(y)) |p, q| {
        if (!order.equals(p, q)) return false;
    }
    for (maps.children(x), maps.children(y)) |p, q| {
        if (!sameShape(maps.asNode(p.?), maps.asNode(q.?))) return false;
    }
    return true;
}

/// Updates chosen at random from a fixed seed, each applied to a version
/// chosen at random or to the latest, agree with the same updates applied to lists. Every so
/// often a version is rebuilt from its list in a shuffled order, and the two
/// tries are the same node by node, equal, and of one hash. Every version made
/// is kept and rooted, and every one is checked again after the last update
/// and a collection, so an update that changed a node another version shares
/// is a failure here.
fn randomUpdatesAgainstLists(kind: maps.Kind, seed: u64) !void {
    const allocator = std.heap.c_allocator;
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    const pool = keyPool();
    defer _ = gc_alloc.gcunroot(wrap.fromArray(pool));
    const keys = pool.slice();

    var versions: std.ArrayListUnmanaged(Version) = .empty;
    defer {
        for (versions.items) |*version| {
            _ = gc_alloc.gcunroot(wrap.fromAbstract(version.trie));
            version.entries.deinit(allocator);
        }
        versions.deinit(allocator);
    }

    const empty = maps.remove(&empty_trie, kind, wrap.fromNil());
    gc_alloc.gcroot(wrap.fromAbstract(empty));
    try versions.append(allocator, .{ .trie = empty, .entries = .empty });

    for (0..4000) |round| {
        // Half the updates are to the latest version, so versions grow large
        // enough to hold several probes of one hash at once, and a third of
        // the keys are probes.
        const pick = if (random.boolean()) versions.items.len - 1 else random.uintLessThan(usize, versions.items.len);
        const source = versions.items[pick];
        var entries = try source.entries.clone(allocator);
        const key = if (random.uintLessThan(u8, 3) == 0)
            keys[probe_start + random.uintLessThan(usize, keys.len - probe_start)]
        else
            keys[random.uintLessThan(usize, keys.len)];
        var t: *maps.Trie = undefined;
        if (random.uintLessThan(u8, 3) == 0) {
            t = maps.remove(source.trie, kind, key);
            if (oracleFind(entries.items, key)) |i| _ = entries.swapRemove(i);
        } else {
            const x = harness.wrapInteger(@intCast(round));
            const e: Entry = .{ .key = key, .value = x };
            t = maps.put(source.trie, kind, entryOf(kind, &e));
            if (oracleFind(entries.items, key)) |i| {
                entries.items[i].value = x;
            } else {
                try entries.append(allocator, e);
            }
        }
        gc_alloc.gcroot(wrap.fromAbstract(t));
        try versions.append(allocator, .{ .trie = t, .entries = entries });
        try expectEntries(kind, t, entries.items);

        if (round % 97 == 0) {
            const shuffled = try allocator.dupe(Entry, entries.items);
            defer allocator.free(shuffled);
            random.shuffle(Entry, shuffled);
            const rebuilt = buildOn(kind, &empty_trie, shuffled);
            expect(sameShape(t.root, rebuilt.root));
            expect(order.equals(wrap.fromAbstract(t), wrap.fromAbstract(rebuilt)));
            expect(order.compare(wrap.fromAbstract(t), wrap.fromAbstract(rebuilt)) == 0);
            expect(order.hash(wrap.fromAbstract(t)) == order.hash(wrap.fromAbstract(rebuilt)));
        }
        if (round % 500 == 0) gc_mark.collect();
    }

    gc_mark.collect();
    for (versions.items) |version| try expectEntries(kind, version.trie, version.entries.items);
}

/// Removing the key that kept a collision node below its neighbours leaves the
/// trie inserting the remaining keys would have made, and so does removing a
/// key from a collision node until one is left, and removing the only key of
/// a trie. The keys are added in every order.
fn removalsLeaveTheShapeInsertionMakes() !void {
    const a = probe(base_hash, 1);
    const b = probe(base_hash, 2);
    const c = probe(base_hash ^ (1 << 12), 3);
    const d = probe(base_hash ^ (1 << 31), 4);
    const holder = arrays.new(4);
    gc_alloc.gcroot(wrap.fromArray(holder));
    defer _ = gc_alloc.gcunroot(wrap.fromArray(holder));
    for ([_]repr.Value{ a, b, c, d }) |k| harness.arrayPush(holder, k);

    const one = harness.wrapInteger(1);
    const all = [_]Entry{ .{ .key = a, .value = one }, .{ .key = b, .value = one }, .{ .key = c, .value = one }, .{ .key = d, .value = one } };
    const orders = [_][4]usize{ .{ 0, 1, 2, 3 }, .{ 3, 2, 1, 0 }, .{ 2, 0, 3, 1 }, .{ 1, 3, 0, 2 } };

    for ([_]maps.Kind{ .map, .set }) |kind| {
        const ab = buildOn(kind, &empty_trie, &.{ all[0], all[1] });
        const ab_d = buildOn(kind, &empty_trie, &.{ all[0], all[1], all[3] });
        const b_only = buildOn(kind, &empty_trie, &.{all[1]});
        for (orders) |o| {
            const every = [_]Entry{ all[o[0]], all[o[1]], all[o[2]], all[o[3]] };
            const full = buildOn(kind, &empty_trie, &every);
            try expectEntries(kind, full, &all);

            const without_c = maps.remove(full, kind, c);
            expect(sameShape(without_c.root, ab_d.root));
            const without_cd = maps.remove(without_c, kind, d);
            expect(sameShape(without_cd.root, ab.root));
            const without_acd = maps.remove(without_cd, kind, a);
            expect(sameShape(without_acd.root, b_only.root));
            try expectEntries(kind, without_acd, &.{all[1]});
            const emptied = maps.remove(without_acd, kind, b);
            expect(emptied.root == null and emptied.count == 0 and emptied.sum == 0);
        }
    }
}

/// An update leaves the collection it was made from unchanged, and a removal
/// of a key that is absent shares the whole trie.
fn anUpdateKeepsTheOriginal() !void {
    var entries: [300]Entry = undefined;
    for (&entries, 0..) |*e, i| e.* = .{ .key = harness.wrapInteger(@intCast(i)), .value = harness.wrapInteger(@intCast(i * 2)) };
    const original = buildOn(.map, &empty_trie, &entries);
    gc_alloc.gcroot(wrap.fromAbstract(original));
    defer _ = gc_alloc.gcunroot(wrap.fromAbstract(original));

    const changed = maps.put(original, .map, &.{ harness.wrapInteger(7), harness.wrapInteger(-1) });
    gc_alloc.gcroot(wrap.fromAbstract(changed));
    defer _ = gc_alloc.gcunroot(wrap.fromAbstract(changed));
    const absent = maps.remove(original, .map, harness.wrapInteger(1000));
    expect(absent.root == original.root);

    gc_mark.collect();
    try expectEntries(.map, original, &entries);
    expect(harness.integerIs(maps.find(changed, .map, harness.wrapInteger(7)).?[1], -1));
    expect(changed.count == original.count);
    expect(changed.sum != original.sum);
}

/// Maps and sets are equal when their entries are, and order by count, then
/// hash, then the first difference in their tries. The order is antisymmetric
/// and transitive over a batch of collections that share counts and, for some
/// pairs, hashes. A map is never equal to a set, nor to a struct.
fn equalityOrderAndHash() !void {
    var prng = std.Random.DefaultPrng.init(0x6d61_7073);
    const random = prng.random();
    const pool = keyPool();
    defer _ = gc_alloc.gcunroot(wrap.fromArray(pool));
    const keys = pool.slice();

    const batch = arrays.new(64);
    gc_alloc.gcroot(wrap.fromArray(batch));
    defer _ = gc_alloc.gcunroot(wrap.fromArray(batch));
    for (0..60) |i| {
        var entries: [4]Entry = undefined;
        for (&entries) |*e| e.* = .{ .key = keys[probe_start - 2 + random.uintLessThan(usize, 12)], .value = harness.wrapInteger(@intCast(random.uintLessThan(u8, 2))) };
        const kind: maps.Kind = if (i % 2 == 0) .map else .set;
        harness.arrayPush(batch, wrap.fromAbstract(buildOn(kind, &empty_trie, &entries)));
    }
    const items = batch.slice();
    for (items) |x| {
        expect(order.equals(x, x) and order.compare(x, x) == 0);
        for (items) |y| {
            const xy = order.compare(x, y);
            expect(xy == -order.compare(y, x));
            expect((xy == 0) == order.equals(x, y));
            if (xy == 0) expect(order.hash(x) == order.hash(y));
            for (items) |z| {
                if (xy <= 0 and order.compare(y, z) <= 0) expect(order.compare(x, z) <= 0);
            }
        }
    }

    const one = harness.wrapInteger(1);
    const key = harness.wrapInteger(1);
    const as_map = maps.put(&empty_trie, .map, &.{ key, one });
    const as_set = maps.put(&empty_trie, .set, &.{key});
    expect(!order.equals(wrap.fromAbstract(as_map), wrap.fromAbstract(as_set)));
    const other_value = maps.put(as_map, .map, &.{ key, harness.wrapInteger(2) });
    expect(!order.equals(wrap.fromAbstract(as_map), wrap.fromAbstract(other_value)));
    // Two probes with one hash give two maps, and two sets, whose counts and
    // sums are equal, so only the walk through the tries tells them apart.
    const p = probe(base_hash, 1);
    const q = probe(base_hash, 2);
    const probes = arrays.new(2);
    gc_alloc.gcroot(wrap.fromArray(probes));
    defer _ = gc_alloc.gcunroot(wrap.fromArray(probes));
    harness.arrayPush(probes, p);
    harness.arrayPush(probes, q);
    for ([_]maps.Kind{ .map, .set }) |kind| {
        const with_p = wrap.fromAbstract(buildOn(kind, &empty_trie, &.{.{ .key = p, .value = one }}));
        const with_q = wrap.fromAbstract(buildOn(kind, &empty_trie, &.{.{ .key = q, .value = one }}));
        expect(maps.toTrie(with_p, kind).?.sum == maps.toTrie(with_q, kind).?.sum);
        expect(!order.equals(with_p, with_q));
        expect(order.compare(with_p, with_q) < 0 and order.compare(with_q, with_p) > 0);
    }

    const empty_a = maps.remove(&empty_trie, .map, key);
    const empty_b = maps.remove(as_map, .map, key);
    expect(order.equals(wrap.fromAbstract(empty_a), wrap.fromAbstract(empty_b)));
    expect(order.compare(wrap.fromAbstract(empty_a), wrap.fromAbstract(as_map)) < 0);
}

// ==========================================================================
// Entry
// ==========================================================================

fn body() !void {
    try randomUpdatesAgainstLists(.map, 0x6d61_70);
    try randomUpdatesAgainstLists(.set, 0x7365_74);
    try removalsLeaveTheShapeInsertionMakes();
    try anUpdateKeepsTheOriginal();
    try equalityOrderAndHash();
}

pub fn run() void {
    harness.init();
    body() catch @panic("maps: a read raised or an allocation failed");
    vm_lifecycle.deinit();
}
