//! Behavioral contract for `core/map` and `core/set` and their transients: the
//! shape of a tree, reading and iterating, persistence across updates, what a
//! transient may change, equality, order and hash, and marshalling.
//!
//! The oracle is a list of entries searched by `order.equals`, which shares
//! no code with the tree it checks. Each case updates a list the way it
//! updates a collection, and compares the two by count, by lookup and by
//! iteration.
//!
//! Keys whose hashes the case chooses come from a probe type whose `hash`
//! callback returns a stored hash and whose `compare` callback orders by a
//! stored id. Probes with one hash and different ids are distinct keys with
//! one place hash, which a tree keeps in one leaf ordered by `compare`. A
//! probe marshals its hash and its id, so a collection holding probes can be
//! read back.
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

const abi = @import("abi");
const abstract_type = @import("subsystems").abstract_type;
const abstracts = @import("subsystems").value.abstracts;
const args = @import("subsystems").args;
const arrays = @import("subsystems").value.arrays;
const buffers = @import("subsystems").value.buffers;
const expect = @import("expect.zig").expect;
const gc_alloc = @import("subsystems").gc_alloc;
const gc_mark = @import("subsystems").gc_mark;
const harness = @import("harness.zig");
const maps = @import("subsystems").value.maps;
const marsh = @import("subsystems").marsh;
const order = @import("subsystems").value.order;
const raise = @import("subsystems").raise;
const registry = @import("subsystems").registry;
const repr = @import("repr");
const strings = @import("subsystems").value.strings;
const tables = @import("subsystems").value.tables;
const transients = @import("subsystems").value.transients;
const value = @import("subsystems").value;
const vm_lifecycle = @import("subsystems").lifecycle;
const wrap = @import("subsystems").value.wrap;

// ==========================================================================
// Constants
// ==========================================================================

/// An empty payload, which `maps.put` and `maps.remove` copy rather than
/// change.
const empty_tree: maps.Tree = .{};

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
    .marshal = probeMarshal,
    .unmarshal = probeUnmarshal,
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
    tree: *maps.Tree,
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

fn probeMarshal(p: *Probe, m: *abi.Marshal) raise.Error!void {
    marsh.marshalAbstract(m, p);
    try marsh.marshalInt(m, @bitCast(p.hash));
    try marsh.marshalInt(m, p.id);
}

fn probeUnmarshal(u: *abi.Unmarshal) raise.Error!*Probe {
    const p: *Probe = @ptrCast(@alignCast(try marsh.unmarshalAbstract(u, @sizeOf(Probe))));
    p.hash = @bitCast(try marsh.unmarshalInt(u));
    p.id = try marsh.unmarshalInt(u);
    return p;
}

/// The keys the random cases draw from, in a rooted array: integers, strings,
/// and probes in four groups. Four probes share one hash, and the other three
/// groups of two each share a hash that differs from it in one bit: bit 31,
/// bit 12 and bit 0.
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
fn buildOn(kind: maps.Kind, start: *const maps.Tree, entries: []const Entry) *maps.Tree {
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

/// What `checkNode` finds under a node: its depth to the leaves, its number of
/// entries, and the least and greatest place hashes under it.
const Checked = struct {
    depth: usize,
    count: usize,
    low: u32,
    high: u32,
};

/// Asserts that every node under `node` keeps the rules `maps.zig`'s header
/// gives for the shape of a tree, and returns what it found.
fn checkNode(kind: maps.Kind, node: *maps.Node, is_root: bool) Checked {
    const w = kind.entryWidth();
    expect(maps.kindOf(&node.gc) == kind);
    expect(node.len > 0);
    if (!maps.isInner(node)) {
        const items = maps.entries(node);
        const hs = maps.hashes(node);
        expect(maps.children(node).len == 0);
        // A leaf is over its limit only where one place hash fills it.
        expect(node.len <= maps.leaf_max or hs[0] == hs[hs.len - 1]);
        for (0..node.len) |i| {
            expect(hs[i] == maps.placeHash(items[i * w]));
            if (kind == .map) expect(!harness.isType(items[i * w + 1], repr.Tag.nil));
            if (i == 0) continue;
            expect(hs[i - 1] <= hs[i]);
            if (hs[i - 1] == hs[i]) expect(order.compare(items[(i - 1) * w], items[i * w]) < 0);
        }
        return .{ .depth = 0, .count = node.len, .low = hs[0], .high = hs[hs.len - 1] };
    }
    expect(maps.entries(node).len == 0);
    expect(node.len <= maps.inner_max);
    if (is_root) expect(node.len >= 2);
    const seps = maps.separators(node);
    var found: Checked = undefined;
    var previous_high: u32 = 0;
    for (maps.children(node), maps.counts(node), 0..) |slot, c, i| {
        const under = checkNode(kind, maps.asNode(slot.?), false);
        expect(under.count == c);
        if (i == 0) {
            found = .{ .depth = under.depth + 1, .count = 0, .low = under.low, .high = 0 };
        } else {
            // Every leaf is at one depth, and the separator divides the hashes
            // under this child from those under the one before.
            expect(under.depth + 1 == found.depth);
            expect(previous_high < seps[i] and seps[i] <= under.low);
        }
        found.count += under.count;
        found.high = under.high;
        previous_high = under.high;
    }
    return found;
}

/// Asserts that `t` has exactly the entries of `entries`: by count, by lookup,
/// by iteration through its type's `next` callback, by the shape of its tree,
/// and, for a map, by reading its runs, one per leaf.
fn expectEntries(kind: maps.Kind, t: *maps.Tree, entries: []const Entry) !void {
    expect(t.count == entries.len);
    if (t.root) |root| {
        expect(checkNode(kind, root, true).count == entries.len);
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

    // `t` may be a transient's payload rather than a map's, so the reader is
    // built over the tree itself rather than through `args.keyvals`.
    if (kind == .set) return;
    const over: args.Keyvals = .{
        .source = .{ .abstract = .{ .payload = t, .at = &maps.map_type } },
        .len = 2 * t.count,
    };
    var runs = over;
    var values: usize = 0;
    while (try runs.nextRun()) |leaf| {
        expect(leaf.len != 0);
        values += leaf.len;
    }
    expect(values == 2 * entries.len);
    var pairs = over;
    seen = 0;
    while (try pairs.next()) |kv| {
        const at = oracleFind(entries, kv.key) orelse {
            expect(false);
            continue;
        };
        expect(order.equals(entries[at].value, kv.value));
        seen += 1;
    }
    expect(seen == entries.len);
}

/// Whether two collections of `kind` hold the same entries in the same order,
/// read by position.
fn sameEntries(kind: maps.Kind, a: *const maps.Tree, b: *const maps.Tree) bool {
    if (a.count != b.count or a.sum != b.sum) return false;
    for (0..a.count * kind.entryWidth()) |i| {
        if (!order.equals(maps.valueAt(a, kind, i), maps.valueAt(b, kind, i))) return false;
    }
    return true;
}

/// The number of nodes with `own_editable` set in the tree under `node`,
/// `node` included. The walk follows every child, not only editable ones, so
/// it does not rely on the rule that `persistent` does.
fn editableUnder(node: *maps.Node) usize {
    var count: usize = if (node.gc.flags.own & maps.own_editable != 0) 1 else 0;
    for (maps.children(node)) |slot| count += editableUnder(maps.asNode(slot.?));
    return count;
}

/// The number of nodes with `own_editable` set in `t`'s tree.
fn editableIn(t: *const maps.Tree) usize {
    return if (t.root) |root| editableUnder(root) else 0;
}

/// A transient changes a node in place once it has made the node, and never a
/// node of the collection it came from. `persistent` leaves no node editable,
/// and a second transient of the result copies rather than changing the first
/// transient's nodes.
fn aTransientChangesOnlyItsOwnNodes() !void {
    const allocator = std.heap.c_allocator;
    var entries: [400]Entry = undefined;
    for (&entries, 0..) |*e, i| e.* = .{ .key = harness.wrapInteger(@intCast(i)), .value = harness.wrapInteger(@intCast(i)) };
    const original = buildOn(.map, &empty_tree, &entries);
    gc_alloc.gcroot(wrap.fromAbstract(original));
    defer _ = gc_alloc.gcunroot(wrap.fromAbstract(original));

    const t = transients.fromTree(original, .map);
    gc_alloc.gcroot(wrap.fromAbstract(t));
    defer _ = gc_alloc.gcunroot(wrap.fromAbstract(t));
    const marker = harness.wrapInteger(-1);

    // The first update copies the root, and the second changes the copy.
    maps.transientPut(&t.map, .map, &.{ harness.wrapInteger(7), marker });
    const copied = t.map.root.?;
    expect(copied != original.root.?);
    expect(copied.gc.flags.own & maps.own_editable != 0);
    maps.transientPut(&t.map, .map, &.{ harness.wrapInteger(8), marker });
    expect(t.map.root.? == copied);

    // Additions and then removals of every other key from 100 to 298, with a
    // collection among the additions.
    var expected: [600]Entry = undefined;
    @memcpy(expected[0..400], &entries);
    expected[7].value = marker;
    expected[8].value = marker;
    for (400..600) |i| {
        expected[i] = .{ .key = harness.wrapInteger(@intCast(i)), .value = harness.wrapInteger(@intCast(i)) };
        maps.transientPut(&t.map, .map, entryOf(.map, &expected[i]));
        if (i == 500) gc_mark.collect();
    }
    for (0..100) |i| maps.transientRemove(&t.map, .map, harness.wrapInteger(@intCast(i * 2 + 100)));
    var remaining: std.ArrayListUnmanaged(Entry) = .empty;
    defer remaining.deinit(allocator);
    for (expected, 0..) |e, i| {
        if (i >= 100 and i < 300 and i % 2 == 0) continue;
        try remaining.append(allocator, e);
    }
    expect(editableIn(&t.map) > 0);
    try expectEntries(.map, &t.map, remaining.items);
    try expectEntries(.map, original, &entries);
    expect(editableIn(original) == 0);

    const persisted = maps.toTree(transients.persistent(t), .map).?;
    gc_alloc.gcroot(wrap.fromAbstract(persisted));
    defer _ = gc_alloc.gcunroot(wrap.fromAbstract(persisted));
    expect(t.* == .ended);
    expect(editableIn(persisted) == 0);
    try expectEntries(.map, persisted, remaining.items);
    expect(sameEntries(.map, persisted, buildOn(.map, &empty_tree, remaining.items)));

    const second = transients.fromTree(persisted, .map);
    gc_alloc.gcroot(wrap.fromAbstract(second));
    defer _ = gc_alloc.gcunroot(wrap.fromAbstract(second));
    maps.transientPut(&second.map, .map, &.{ harness.wrapInteger(9), harness.wrapInteger(-2) });
    expect(second.map.root.? != persisted.root.?);
    try expectEntries(.map, persisted, remaining.items);
}

/// A transient that is never persisted is collected with every node it made,
/// and the collection it came from keeps its own.
fn anAbandonedTransientIsCollected() !void {
    var entries: [200]Entry = undefined;
    for (&entries, 0..) |*e, i| e.* = .{ .key = harness.wrapInteger(@intCast(i)), .value = harness.wrapInteger(0) };
    const original = buildOn(.set, &empty_tree, &entries);
    gc_alloc.gcroot(wrap.fromAbstract(original));
    defer _ = gc_alloc.gcunroot(wrap.fromAbstract(original));
    gc_mark.collect();
    const before = harness.vm().gc.block_count;

    const t = transients.fromTree(original, .set);
    for (200..700) |i| maps.transientPut(&t.set, .set, &.{harness.wrapInteger(@intCast(i))});
    for (0..50) |i| maps.transientRemove(&t.set, .set, harness.wrapInteger(@intCast(i)));
    expect(harness.vm().gc.block_count > before + 15);
    gc_mark.collect();
    expect(harness.vm().gc.block_count == before);
    try expectEntries(.set, original, &entries);
}

/// Updates chosen at random from a fixed seed, each applied to a version
/// chosen at random or to the latest, some through a transient, agree with the same updates applied to lists. Every so
/// often a version is rebuilt from its list in a shuffled order, and the two
/// collections hold the same entries in order, are equal, and have one hash.
/// Every version made
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
            _ = gc_alloc.gcunroot(wrap.fromAbstract(version.tree));
            version.entries.deinit(allocator);
        }
        versions.deinit(allocator);
    }

    const empty = maps.remove(&empty_tree, kind, wrap.fromNil());
    gc_alloc.gcroot(wrap.fromAbstract(empty));
    try versions.append(allocator, .{ .tree = empty, .entries = .empty });

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
        var t: *maps.Tree = undefined;
        const choice = random.uintLessThan(u8, 8);
        if (choice == 0) {
            // A batch through a transient, rooted in case the batch collects,
            // with a removal for every two additions.
            const transient = transients.fromTree(source.tree, kind);
            gc_alloc.gcroot(wrap.fromAbstract(transient));
            const tree = switch (transient.*) {
                .map, .set => |*held| held,
                else => unreachable,
            };
            for (0..random.uintLessThan(usize, 60)) |i| {
                const batch_key = keys[random.uintLessThan(usize, keys.len)];
                if (i % 3 == 2) {
                    maps.transientRemove(tree, kind, batch_key);
                    if (oracleFind(entries.items, batch_key)) |at| _ = entries.swapRemove(at);
                } else {
                    const x = harness.wrapInteger(@intCast(round * 100 + i));
                    const e: Entry = .{ .key = batch_key, .value = x };
                    maps.transientPut(tree, kind, entryOf(kind, &e));
                    if (oracleFind(entries.items, batch_key)) |at| {
                        entries.items[at].value = x;
                    } else {
                        try entries.append(allocator, e);
                    }
                }
                if (i == 30) gc_mark.collect();
            }
            t = maps.toTree(transients.persistent(transient), kind).?;
            _ = gc_alloc.gcunroot(wrap.fromAbstract(transient));
            expect(editableIn(t) == 0);
        } else if (choice < 3) {
            t = maps.remove(source.tree, kind, key);
            if (oracleFind(entries.items, key)) |i| _ = entries.swapRemove(i);
        } else {
            const x = harness.wrapInteger(@intCast(round));
            const e: Entry = .{ .key = key, .value = x };
            t = maps.put(source.tree, kind, entryOf(kind, &e));
            if (oracleFind(entries.items, key)) |i| {
                entries.items[i].value = x;
            } else {
                try entries.append(allocator, e);
            }
        }
        gc_alloc.gcroot(wrap.fromAbstract(t));
        try versions.append(allocator, .{ .tree = t, .entries = entries });
        try expectEntries(kind, t, entries.items);
        // A map is read as pairs, to twice its count, and a set is not.
        if (try args.keyvals(wrap.fromAbstract(t))) |pairs| {
            expect(kind == .map and pairs.len == 2 * t.count);
        } else {
            expect(kind == .set);
        }

        if (round % 97 == 0) {
            const shuffled = try allocator.dupe(Entry, entries.items);
            defer allocator.free(shuffled);
            random.shuffle(Entry, shuffled);
            const rebuilt = buildOn(kind, &empty_tree, shuffled);
            expect(sameEntries(kind, t, rebuilt));
            expect(order.equals(wrap.fromAbstract(t), wrap.fromAbstract(rebuilt)));
            expect(order.compare(wrap.fromAbstract(t), wrap.fromAbstract(rebuilt)) == 0);
            expect(order.hash(wrap.fromAbstract(t)) == order.hash(wrap.fromAbstract(rebuilt)));
        }
        if (round % 500 == 0) gc_mark.collect();
    }

    gc_mark.collect();
    for (versions.items) |version| try expectEntries(kind, version.tree, version.entries.items);
}

/// A leaf left below `merge_below` entries by a removal merges with its
/// neighbour where the two fit, and so does an inner node left below it
/// children, and a root left with one child is replaced by it. Built from 64
/// elements, a set is two leaves of 32. Emptying 25 of the second and then 25
/// of the first leaves one leaf of 14. Built from 1,088 elements, it is 34
/// leaves under two inner nodes of 17. Emptying the first ten leaves leaves
/// one inner node of 24 leaves as the root. The same removals through a
/// transient give the same trees.
fn removalsMergeNodes() !void {
    for ([_]bool{ false, true }) |through_transient| {
        var small: [64]repr.Value = undefined;
        for (&small, 0..) |*x, i| x.* = harness.wrapInteger(@intCast(i));
        const two_leaves = maps.build(.set, &small);
        gc_alloc.gcroot(wrap.fromAbstract(two_leaves));
        defer _ = gc_alloc.gcunroot(wrap.fromAbstract(two_leaves));
        const top = two_leaves.root.?;
        expect(maps.isInner(top) and top.len == 2);
        expect(maps.asNode(maps.children(top)[0].?).len == 32);

        var doomed: [50]repr.Value = undefined;
        for (doomed[0..25], 0..) |*x, i| x.* = maps.valueAt(two_leaves, .set, 32 + i);
        for (doomed[25..], 0..) |*x, i| x.* = maps.valueAt(two_leaves, .set, i);
        const merged = removeAll(two_leaves, &doomed, through_transient);
        expect(!maps.isInner(merged.root.?) and merged.root.?.len == 14);
        expect(merged.count == 14);
        _ = checkNode(.set, merged.root.?, true);

        var large: [1088]repr.Value = undefined;
        for (&large, 0..) |*x, i| x.* = harness.wrapInteger(@intCast(i));
        const tall = maps.build(.set, &large);
        gc_alloc.gcroot(wrap.fromAbstract(tall));
        defer _ = gc_alloc.gcunroot(wrap.fromAbstract(tall));
        expect(tall.root.?.len == 2);
        expect(maps.asNode(maps.children(tall.root.?)[0].?).len == 17);

        var first_ten: [320]repr.Value = undefined;
        for (&first_ten, 0..) |*x, i| x.* = maps.valueAt(tall, .set, i);
        const shorter = removeAll(tall, &first_ten, through_transient);
        const root = shorter.root.?;
        expect(maps.isInner(root) and root.len == 24);
        expect(!maps.isInner(maps.asNode(maps.children(root)[0].?)));
        expect(shorter.count == 1088 - 320);
        _ = checkNode(.set, root, true);
    }
}

/// The set `src` without each of `keys`, removed one at a time, checking the
/// tree after each removal, either persistently or through one transient.
fn removeAll(src: *maps.Tree, keys: []const repr.Value, through_transient: bool) *maps.Tree {
    if (through_transient) {
        const t = transients.fromTree(src, .set);
        for (keys) |key| {
            maps.transientRemove(&t.set, .set, key);
            if (t.set.root) |root| _ = checkNode(.set, root, true);
        }
        return maps.toTree(transients.persistent(t), .set).?;
    }
    var current = src;
    for (keys) |key| {
        current = maps.remove(current, .set, key);
        if (current.root) |root| _ = checkNode(.set, root, true);
    }
    return current;
}

/// A bulk build holds the entries that adding them one at a time holds, in
/// the same order, with a later entry for a key replacing an earlier one and a
/// nil map value removing its key. The batches draw on the probes, so some
/// keys share a place hash, and some are longer than `build` places without
/// allocating.
fn aBulkBuildHoldsWhatInsertionHolds(kind: maps.Kind, seed: u64) !void {
    const allocator = std.heap.c_allocator;
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    const pool = keyPool();
    defer _ = gc_alloc.gcunroot(wrap.fromArray(pool));
    const keys = pool.slice();
    const w = kind.entryWidth();

    var values: std.ArrayListUnmanaged(repr.Value) = .empty;
    defer values.deinit(allocator);
    var entries: Oracle = .empty;
    defer entries.deinit(allocator);

    for (0..600) |round| {
        values.clearRetainingCapacity();
        entries.clearRetainingCapacity();
        const len = if (round % 5 == 0) random.uintLessThan(usize, 300) else random.uintLessThan(usize, 40);
        var incremental = maps.remove(&empty_tree, kind, wrap.fromNil());
        for (0..len) |i| {
            const key = if (random.uintLessThan(u8, 3) == 0)
                keys[probe_start + random.uintLessThan(usize, keys.len - probe_start)]
            else
                keys[random.uintLessThan(usize, keys.len)];
            const removes = kind == .map and random.uintLessThan(u8, 8) == 0;
            const x = if (removes) wrap.fromNil() else harness.wrapInteger(@intCast(i));
            try values.append(allocator, key);
            if (kind == .map) try values.append(allocator, x);
            if (removes) {
                incremental = maps.remove(incremental, kind, key);
                if (oracleFind(entries.items, key)) |at| _ = entries.swapRemove(at);
            } else {
                const e: Entry = .{ .key = key, .value = x };
                incremental = maps.put(incremental, kind, entryOf(kind, &e));
                if (oracleFind(entries.items, key)) |at| {
                    entries.items[at].value = x;
                } else {
                    try entries.append(allocator, e);
                }
            }
        }
        std.debug.assert(values.items.len == len * w);
        const built = maps.build(kind, values.items);
        expect(sameEntries(kind, built, incremental));
        expect(built.sum == incremental.sum);
        try expectEntries(kind, built, entries.items);
        if (round % 50 == 0) gc_mark.collect();
    }
}

/// A bulk build of more keys with one hash than `build` sorts by insertion
/// holds what adding them one at a time holds, with the last of a repeated
/// key's values, and so does one of more keys than `build` places without
/// allocating. Forty keys with one hash are a leaf over `leaf_max`, which
/// keeps its rules as its keys are removed.
fn aBulkBuildOfManyKeysWithOneHash() !void {
    const allocator = std.heap.c_allocator;
    var prng = std.Random.DefaultPrng.init(0x636f_6c6c);
    const random = prng.random();
    const holder = arrays.new(80);
    gc_alloc.gcroot(wrap.fromArray(holder));
    defer _ = gc_alloc.gcunroot(wrap.fromArray(holder));
    for (0..40) |i| harness.arrayPush(holder, probe(base_hash, @intCast(i)));
    for (40..80) |i| harness.arrayPush(holder, probe(base_hash ^ (1 << 20), @intCast(i)));
    const probes = holder.slice();

    var values: std.ArrayListUnmanaged(repr.Value) = .empty;
    defer values.deinit(allocator);
    for ([_]usize{ 20, 40, 80 }) |pool_len| {
        values.clearRetainingCapacity();
        var incremental = maps.remove(&empty_tree, .map, wrap.fromNil());
        for (0..pool_len * 2) |i| {
            const key = probes[random.uintLessThan(usize, pool_len)];
            const x = harness.wrapInteger(@intCast(i));
            try values.appendSlice(allocator, &.{ key, x });
            incremental = maps.put(incremental, .map, &.{ key, x });
        }
        const built = maps.build(.map, values.items);
        expect(sameEntries(.map, built, incremental));
        expect(built.count == incremental.count and built.sum == incremental.sum);
        _ = checkNode(.map, built.root.?, true);
        _ = checkNode(.map, incremental.root.?, true);
    }

    var all: [80]repr.Value = undefined;
    for (&all, probes) |*x, key| x.* = key;
    var shrinking = maps.build(.set, &all);
    gc_alloc.gcroot(wrap.fromAbstract(shrinking));
    const first = shrinking;
    expect(longestLeaf(shrinking.root.?) == 40);
    random.shuffle(repr.Value, &all);
    for (all, 0..) |key, i| {
        shrinking = maps.remove(shrinking, .set, key);
        if (shrinking.root) |root| _ = checkNode(.set, root, true);
        expect(shrinking.count == all.len - i - 1);
    }
    _ = gc_alloc.gcunroot(wrap.fromAbstract(first));
}

/// The number of entries in the longest leaf under `node`.
fn longestLeaf(node: *maps.Node) u32 {
    if (!maps.isInner(node)) return node.len;
    var longest: u32 = 0;
    for (maps.children(node)) |slot| longest = @max(longest, longestLeaf(maps.asNode(slot.?)));
    return longest;
}

/// `next` and `get` read from the entry `next` last gave where the key is that
/// entry's, and search from the root otherwise, with the same results. A key
/// equal to a stored one but not identical to it finds the same entry, a
/// jump to any key gives that key's successor, and a collection made from
/// another by an update reads its own entries after the original was
/// iterated. The collections hold probes, so some keys share a place hash.
fn theCursorReadsAsTheRootDoes(kind: maps.Kind) !void {
    const allocator = std.heap.c_allocator;
    var prng = std.Random.DefaultPrng.init(0x6375_7273);
    const random = prng.random();
    const pool = keyPool();
    defer _ = gc_alloc.gcunroot(wrap.fromArray(pool));
    const keys = pool.slice();
    const at = kind.abstractType();

    var values: std.ArrayListUnmanaged(repr.Value) = .empty;
    defer values.deinit(allocator);
    for (keys, 0..) |key, i| {
        try values.append(allocator, key);
        if (kind == .map) try values.append(allocator, harness.wrapInteger(@intCast(i)));
    }
    const t = maps.build(kind, values.items);
    gc_alloc.gcroot(wrap.fromAbstract(t));
    defer _ = gc_alloc.gcunroot(wrap.fromAbstract(t));

    // The order `next` gives, read with the cursor cleared before each step,
    // so every step searches from the root.
    var in_order: std.ArrayListUnmanaged(repr.Value) = .empty;
    defer in_order.deinit(allocator);
    var key = try at.next.?(t, wrap.fromNil());
    while (!harness.isType(key, repr.Tag.nil)) {
        try in_order.append(allocator, key);
        t.cursor = null;
        key = try at.next.?(t, key);
    }
    expect(in_order.items.len == keys.len);

    for (0..2000) |_| {
        const i = random.uintLessThan(usize, in_order.items.len);
        const k = in_order.items[i];
        const after = try at.next.?(t, k);
        if (i + 1 < in_order.items.len) {
            expect(order.equals(after, in_order.items[i + 1]));
        } else {
            expect(harness.isType(after, repr.Tag.nil));
        }
        // Where there is a successor, the cursor is now on it.
        const read = if (harness.isType(after, repr.Tag.nil)) k else after;
        const got = (try at.get.?(t, read)).?;
        const expected = maps.find(t, kind, read).?;
        expect(order.equals(got, if (kind == .map) expected[1] else expected[0]));
    }

    // A string equal to a stored key but not the same string.
    for (in_order.items, 0..) |k, i| {
        if (!harness.isType(k, repr.Tag.string)) continue;
        const text = wrap.toString(k);
        const copy = value.fromBytes(text[0..strings.head(text).length], .string);
        expect(!std.mem.eql(u8, std.mem.asBytes(&copy), std.mem.asBytes(&k)));
        const after = try at.next.?(t, copy);
        if (i + 1 < in_order.items.len) {
            expect(order.equals(after, in_order.items[i + 1]));
        } else {
            expect(harness.isType(after, repr.Tag.nil));
        }
        expect(order.equals((try at.get.?(t, copy)).?, (try at.get.?(t, k)).?));
    }

    // Leave the cursor on a key, then replace that key's value, or remove the
    // key, in a new collection.
    const target = in_order.items[in_order.items.len / 2];
    _ = try at.next.?(t, in_order.items[in_order.items.len / 2 - 1]);
    expect(t.cursor != null);
    const marker = harness.wrapInteger(-7);
    const updated = switch (kind) {
        .map => maps.put(t, kind, &.{ target, marker }),
        .set => maps.remove(t, kind, target),
    };
    expect(updated.cursor == null);
    const read = (try at.get.?(updated, target)).?;
    switch (kind) {
        .map => expect(harness.integerIs(read, -7)),
        .set => expect(harness.isType(read, repr.Tag.nil)),
    }
}

/// An update leaves the collection it was made from unchanged, and a removal
/// of a key that is absent shares the whole tree.
fn anUpdateKeepsTheOriginal() !void {
    var entries: [300]Entry = undefined;
    for (&entries, 0..) |*e, i| e.* = .{ .key = harness.wrapInteger(@intCast(i)), .value = harness.wrapInteger(@intCast(i * 2)) };
    const original = buildOn(.map, &empty_tree, &entries);
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
/// hash, then the first difference in their entries in order. The order is antisymmetric
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
        harness.arrayPush(batch, wrap.fromAbstract(buildOn(kind, &empty_tree, &entries)));
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
    const as_map = maps.put(&empty_tree, .map, &.{ key, one });
    const as_set = maps.put(&empty_tree, .set, &.{key});
    expect(!order.equals(wrap.fromAbstract(as_map), wrap.fromAbstract(as_set)));
    const other_value = maps.put(as_map, .map, &.{ key, harness.wrapInteger(2) });
    expect(!order.equals(wrap.fromAbstract(as_map), wrap.fromAbstract(other_value)));
    // Two probes with one hash give two maps, and two sets, whose counts and
    // sums are equal, so only the walk through their entries tells them apart.
    const p = probe(base_hash, 1);
    const q = probe(base_hash, 2);
    const probes = arrays.new(2);
    gc_alloc.gcroot(wrap.fromArray(probes));
    defer _ = gc_alloc.gcunroot(wrap.fromArray(probes));
    harness.arrayPush(probes, p);
    harness.arrayPush(probes, q);
    for ([_]maps.Kind{ .map, .set }) |kind| {
        const with_p = wrap.fromAbstract(buildOn(kind, &empty_tree, &.{.{ .key = p, .value = one }}));
        const with_q = wrap.fromAbstract(buildOn(kind, &empty_tree, &.{.{ .key = q, .value = one }}));
        expect(maps.toTree(with_p, kind).?.sum == maps.toTree(with_q, kind).?.sum);
        expect(!order.equals(with_p, with_q));
        expect(order.compare(with_p, with_q) < 0 and order.compare(with_q, with_p) > 0);
    }

    const empty_a = maps.remove(&empty_tree, .map, key);
    const empty_b = maps.remove(as_map, .map, key);
    expect(order.equals(wrap.fromAbstract(empty_a), wrap.fromAbstract(empty_b)));
    expect(order.compare(wrap.fromAbstract(empty_a), wrap.fromAbstract(as_map)) < 0);
}

/// `x` marshalled into a new buffer.
fn marshalled(x: repr.Value) raise.Error!*buffers.Buffer {
    const b = buffers.new(16);
    try marsh.marshal(b, x, null, 0);
    return b;
}

/// The value `bytes` unmarshals to.
fn unmarshalled(bytes: []const u8) raise.Error!repr.Value {
    return marsh.unmarshal(bytes, 0, null, null);
}

/// A map or a set read back from its marshalled form has the entries, their
/// order and the hash of the one written, keys that share a hash included, and none
/// of its nodes is editable. It is read again after a collection, so a node
/// the unmarshaller made and did not store is a failure here.
fn marshallingRoundTrips() !void {
    const allocator = std.heap.c_allocator;
    var prng = std.Random.DefaultPrng.init(0x6d61_7273);
    const random = prng.random();
    const pool = keyPool();
    defer _ = gc_alloc.gcunroot(wrap.fromArray(pool));
    const keys = pool.slice();

    const shuffled = try allocator.alloc(Entry, keys.len);
    defer allocator.free(shuffled);
    for (shuffled, keys) |*e, key| e.* = .{ .key = key, .value = keys[random.uintLessThan(usize, keys.len)] };
    random.shuffle(Entry, shuffled);

    for ([_]maps.Kind{ .map, .set }) |kind| {
        for ([_]usize{ 0, 1, 2, 31, 33, 100, keys.len }) |n| {
            const written = wrap.fromAbstract(buildOn(kind, &empty_tree, shuffled[0..n]));
            gc_alloc.gcroot(written);
            defer _ = gc_alloc.gcunroot(written);
            const back = try unmarshalled((try marshalled(written)).slice());
            gc_alloc.gcroot(back);
            defer _ = gc_alloc.gcunroot(back);
            gc_mark.collect();
            const t = maps.toTree(back, kind).?;
            try expectEntries(kind, t, shuffled[0..n]);
            expect(sameEntries(kind, t, maps.toTree(written, kind).?));
            expect(editableIn(t) == 0);
            expect(order.equals(back, written));
            expect(order.hash(back) == order.hash(written));
        }
    }
}

/// The bytes of a marshalled map and set: the abstract's lead byte and type
/// name, the count in `marshalSize`'s encoding, and then each entry's values.
/// A marshalled stream is a file format, so the bytes are the contract.
fn theWireFormat() !void {
    const lb_abstract = 217;
    const lb_symbol = 207;
    const one = harness.wrapInteger(1);
    const two = harness.wrapInteger(2);
    const map = try marshalled(wrap.fromAbstract(maps.put(&empty_tree, .map, &.{ one, two })));
    expect(std.mem.eql(u8, map.slice(), &[_]u8{ lb_abstract, lb_symbol, 8 } ++ "core/map".* ++ [_]u8{ 1, 1, 2 }));
    const set = try marshalled(wrap.fromAbstract(maps.put(&empty_tree, .set, &.{one})));
    expect(std.mem.eql(u8, set.slice(), &[_]u8{ lb_abstract, lb_symbol, 8 } ++ "core/set".* ++ [_]u8{ 1, 1 }));
    const empty = try marshalled(wrap.fromAbstract(maps.remove(&empty_tree, .set, one)));
    expect(std.mem.eql(u8, empty.slice(), &[_]u8{ lb_abstract, lb_symbol, 8 } ++ "core/set".* ++ [_]u8{0}));
}

/// A collection that occurs twice in what is marshalled is read back as one,
/// and equal collections are too. A collection reachable from its own entry is
/// read back as two equal collections, and a table that has the inner one as a
/// key still finds it, which is why a collection enters the reference table
/// after its entries.
fn marshallingKeepsIdentityAndHashes() !void {
    var entries: [40]Entry = undefined;
    for (&entries, 0..) |*e, i| e.* = .{ .key = harness.wrapInteger(@intCast(i)), .value = harness.wrapInteger(@intCast(i * 3)) };
    for ([_]maps.Kind{ .map, .set }) |kind| {
        const shared = wrap.fromAbstract(buildOn(kind, &empty_tree, &entries));
        const equal = wrap.fromAbstract(buildOn(kind, &empty_tree, &entries));
        const holder = arrays.new(3);
        harness.arrayPush(holder, shared);
        harness.arrayPush(holder, shared);
        harness.arrayPush(holder, equal);
        const back = try unmarshalled((try marshalled(wrap.fromArray(holder))).slice());
        const items = wrap.toArray(back).slice();
        expect(items.len == 3);
        expect(wrap.toAbstract(items[0]) == wrap.toAbstract(items[1]));
        expect(wrap.toAbstract(items[0]) == wrap.toAbstract(items[2]));
        try expectEntries(kind, maps.toTree(items[0], kind).?, &entries);

        // A table holding, as a key, the collection that holds the table: as
        // a map's value, and as a set's element.
        const t = tables.new(1);
        const entry = [2]repr.Value{ harness.wrapInteger(1), wrap.fromTable(t) };
        const outer = wrap.fromAbstract(switch (kind) {
            .map => maps.put(&empty_tree, .map, &entry),
            .set => maps.put(&empty_tree, .set, entry[1..]),
        });
        tables.put(t, outer, harness.wrapInteger(7));
        const cycled = try unmarshalled((try marshalled(outer)).slice());
        const back_t = wrap.toTable(switch (kind) {
            .map => maps.find(maps.toTree(cycled, .map).?, .map, entry[0]).?[1],
            .set => maps.entries(maps.toTree(cycled, .set).?.root.?)[0],
        });
        expect(harness.integerIs(tables.get(back_t, cycled), 7));
        for (back_t.slots()[0..back_t.capacity]) |kv| {
            if (repr.checkType(kv.key, repr.Tag.nil)) continue;
            expect(wrap.toAbstract(kv.key) != wrap.toAbstract(cycled));
        }
    }
}

/// A stream a marshaller did not write is read under `hash-map`'s rules: a
/// repeated key replaces the earlier entry, a nil value removes its key, and a
/// nil or NaN key is refused. What is read back keeps every rule of a tree's
/// shape.
fn aForgedStreamIsReadAsHashMapReadsItsArguments() !void {
    const lb_abstract = 217;
    const lb_symbol = 207;
    const lb_nil = 201;
    const map_head = [_]u8{ lb_abstract, lb_symbol, 8 } ++ "core/map".*;
    const set_head = [_]u8{ lb_abstract, lb_symbol, 8 } ++ "core/set".*;
    const one = harness.wrapInteger(1);
    const three = harness.wrapInteger(3);

    const repeated = try unmarshalled(&(map_head ++ [_]u8{ 2, 1, 2, 1, 3 }));
    try expectEntries(.map, maps.toTree(repeated, .map).?, &.{.{ .key = one, .value = three }});
    const twice = try unmarshalled(&(set_head ++ [_]u8{ 3, 1, 3, 1 }));
    try expectEntries(.set, maps.toTree(twice, .set).?, &.{ .{ .key = one, .value = one }, .{ .key = three, .value = three } });
    const removed = try unmarshalled(&(map_head ++ [_]u8{ 3, 1, 2, 3, 4, 1, lb_nil }));
    try expectEntries(.map, maps.toTree(removed, .map).?, &.{.{ .key = three, .value = harness.wrapInteger(4) }});
    const emptied = try unmarshalled(&(map_head ++ [_]u8{ 1, 1, lb_nil }));
    expect(maps.toTree(emptied, .map).?.root == null);

    const nil_key = harness.raised(unmarshalled, .{@as([]const u8, &(map_head ++ [_]u8{ 1, lb_nil, 2 }))});
    expect(nil_key != null and nil_key.?.says("cannot use nil as a key"));
    const nan = try marshalled(wrap.fromNumber(std.math.nan(f64)));
    var nan_stream: [set_head.len + 1 + 9]u8 = undefined;
    @memcpy(nan_stream[0..set_head.len], &set_head);
    nan_stream[set_head.len] = 1;
    @memcpy(nan_stream[set_head.len + 1 ..], nan.slice());
    const nan_key = harness.raised(unmarshalled, .{@as([]const u8, &nan_stream)});
    expect(nan_key != null and nan_key.?.beginsWith("cannot use nan"));
}

/// A stream cut short anywhere is refused, and so is a count the rest of the
/// stream is too short to hold.
fn aShortStreamIsRefused() !void {
    var entries: [70]Entry = undefined;
    for (&entries, 0..) |*e, i| e.* = .{ .key = harness.wrapInteger(@intCast(i)), .value = harness.wrapInteger(@intCast(i)) };
    entries[40].value = wrap.fromAbstract(buildOn(.set, &empty_tree, entries[0..3]));
    const whole = try marshalled(wrap.fromAbstract(buildOn(.map, &empty_tree, &entries)));
    gc_alloc.gcroot(wrap.fromBuffer(whole));
    for (0..@intCast(whole.count)) |len| {
        const refusal = harness.raised(unmarshalled, .{whole.slice()[0..len]});
        expect(refusal != null and refusal.?.signal == abi.Signal.@"error");
    }
    _ = gc_alloc.gcunroot(wrap.fromBuffer(whole));

    const lb_abstract = 217;
    const lb_symbol = 207;
    const lying = [_]u8{ lb_abstract, lb_symbol, 8 } ++ "core/set".* ++ [_]u8{ 0xF1, 0xF0, 1, 2 };
    expect(harness.raised(unmarshalled, .{@as([]const u8, &lying)}).?.says("unexpected end of source"));
}

/// A transient has no `marshal` callback, so marshalling one of a map or a
/// set is refused.
fn aTransientIsNotMarshalled() !void {
    const one = harness.wrapInteger(1);
    for ([_]maps.Kind{ .map, .set }) |kind| {
        const source = maps.put(&empty_tree, kind, (&[2]repr.Value{ one, one })[0..kind.entryWidth()]);
        const refusal = harness.raised(marshalled, .{wrap.fromAbstract(transients.fromTree(source, kind))});
        expect(refusal != null and refusal.?.beginsWith("cannot marshal"));
    }
}

// ==========================================================================
// Entry
// ==========================================================================

fn body() !void {
    try randomUpdatesAgainstLists(.map, 0x6d61_70);
    try randomUpdatesAgainstLists(.set, 0x7365_74);
    try removalsMergeNodes();
    try aBulkBuildHoldsWhatInsertionHolds(.map, 0x6275_6c6b);
    try aBulkBuildHoldsWhatInsertionHolds(.set, 0x6275_6c6c);
    try aBulkBuildOfManyKeysWithOneHash();
    try theCursorReadsAsTheRootDoes(.map);
    try theCursorReadsAsTheRootDoes(.set);
    try anUpdateKeepsTheOriginal();
    try aTransientChangesOnlyItsOwnNodes();
    try anAbandonedTransientIsCollected();
    try equalityOrderAndHash();
    // Unmarshalling finds a type by name in the registry, and building the
    // core environment is what registers `core/map` and `core/set`.
    _ = harness.coreEnv();
    try registry.registerAbstractType(&probe_type);
    try marshallingRoundTrips();
    try theWireFormat();
    try marshallingKeepsIdentityAndHashes();
    try aForgedStreamIsReadAsHashMapReadsItsArguments();
    try aShortStreamIsRefused();
    try aTransientIsNotMarshalled();
}

pub fn run() void {
    harness.init();
    body() catch @panic("maps: a read raised or an allocation failed");
    vm_lifecycle.deinit();
}
