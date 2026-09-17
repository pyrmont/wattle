//! Behavioral contract for vectors and their transients: the shape at each
//! boundary of the trie, reading a vector as a tuple is read, persistence
//! across updates, what a transient may change, equality, order and hash, and
//! marshalling.
//!
//! The oracle is a tuple. Each case builds the elements a vector should have
//! as a plain array, updates that array the way the vector was updated, and
//! makes a tuple of it. A vector is then read element by element and run by
//! run, and compared with that tuple. The array is updated by indexing, so it
//! shares no code with the trie it checks.
//!
//! Every vector a case keeps across a collection is rooted. Nothing else in a
//! contract keeps a value alive, and a collection in the middle of a case is
//! what shows that the nodes a vector shares are marked through it.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const args = @import("subsystems").args;
const arrays = @import("subsystems").value.arrays;
const buffers = @import("subsystems").value.buffers;
const expect = @import("expect.zig").expect;
const gc_alloc = @import("subsystems").gc_alloc;
const gc_mark = @import("subsystems").gc_mark;
const harness = @import("harness.zig");
const marsh = @import("subsystems").marsh;
const order = @import("subsystems").value.order;
const raise = @import("subsystems").raise;
const repr = @import("repr");
const tables = @import("subsystems").value.tables;
const transients = @import("subsystems").value.transients;
const tuples = @import("subsystems").value.tuples;
const vectors = @import("subsystems").value.vectors;
const vm_lifecycle = @import("subsystems").lifecycle;
const wrap = @import("subsystems").value.wrap;

// ==========================================================================
// Constants
// ==========================================================================

/// The lengths either side of each change in a trie's shape: the tail filling,
/// the root becoming a leaf, then an inner node, then growing a level.
const boundary_lengths = [_]usize{
    0,     1,     31,    32,    33,   63,   64,   65,    96,    97,
    1023,  1024,  1025,  1056,  1057, 1088, 1089, 32767, 32768, 32769,
    32800, 32801, 32833, 33857,
};

// ==========================================================================
// Cases
// ==========================================================================

/// The integers from zero, one per slot. Distinct elements, so an element read
/// from the wrong slot is a failure rather than a coincidence.
fn counting(buffer: []repr.Value) []repr.Value {
    for (buffer, 0..) |*slot, i| slot.* = harness.wrapInteger(@intCast(i));
    return buffer;
}

/// Asserts that `v` has exactly the elements of `expected`, read three ways:
/// by `vectors.at`, run by run through `args.chunks`, and against a tuple of
/// `expected` through `order.equals`.
fn expectElements(v: *const vectors.Vector, expected: []const repr.Value) !void {
    expect(v.count == expected.len);
    for (expected, 0..) |x, i| expect(order.equals(vectors.at(v, i), x));

    var it = (try args.chunks(wrap.fromVector(v))).?;
    expect(it.len == expected.len);
    var read: usize = 0;
    while (try it.next()) |part| {
        expect(part.len > 0 and part.len <= vectors.width);
        for (part) |x| {
            expect(order.equals(x, expected[read]));
            read += 1;
        }
    }
    expect(read == expected.len);

    const tuple = wrap.fromTuple(tuples.newFrom(expected));
    var from_tuple = (try args.chunks(tuple)).?;
    var index: usize = 0;
    while (try from_tuple.next()) |part| {
        for (part) |x| {
            expect(order.equals(x, vectors.at(v, index)));
            index += 1;
        }
    }
    expect(index == v.count);
}

/// The shift a trie of `n` elements has: zero until the trie has more than one
/// leaf, then five for each level above the leaves.
fn expectedShift(n: usize) u32 {
    const trie_leaves = if (n == 0) 0 else (n - 1) / vectors.width;
    var shift: u32 = 0;
    var capacity: usize = 1;
    while (trie_leaves > capacity) {
        capacity *= vectors.width;
        shift += 5;
    }
    return shift;
}

/// A vector built from a slice, and one built from empty by `conj`, has the
/// same shape and the same elements as the tuple of that slice at every length
/// where the shape changes.
fn theShapeAtEachBoundary() !void {
    const most = boundary_lengths[boundary_lengths.len - 1];
    const buffer = try std.heap.c_allocator.alloc(repr.Value, most);
    defer std.heap.c_allocator.free(buffer);
    const elements = counting(buffer);

    for (boundary_lengths) |n| {
        const v = vectors.fromSlice(elements[0..n]);
        expect((v.root == null) == (n <= vectors.width));
        expect((v.tail == null) == (n == 0));
        expect(v.shift == expectedShift(n));
        try expectElements(v, elements[0..n]);
    }

    // Built one element at a time, checked at every boundary on the way.
    var v = vectors.fromSlice(&.{});
    gc_alloc.gcroot(wrap.fromVector(v));
    var next_boundary: usize = 0;
    for (0..most + 1) |n| {
        if (n == boundary_lengths[next_boundary]) {
            expect(v.shift == expectedShift(n));
            try expectElements(v, elements[0..n]);
            const built = vectors.fromSlice(elements[0..n]);
            expect(order.equals(wrap.fromVector(v), wrap.fromVector(built)));
            expect(order.hash(wrap.fromVector(v)) == order.hash(wrap.fromVector(built)));
            next_boundary += 1;
        }
        if (n == most) break;
        const bigger = vectors.conj(v, elements[n]);
        _ = gc_alloc.gcunroot(wrap.fromVector(v));
        v = bigger;
        gc_alloc.gcroot(wrap.fromVector(v));
    }
    _ = gc_alloc.gcunroot(wrap.fromVector(v));
}

/// A chunk is a node's own storage: a full leaf for an index below the tail,
/// and the tail's filled slots for an index in it. The runs start at multiples
/// of the width.
fn aChunkIsALeafOrTheTail() !void {
    var buffer: [100]repr.Value = undefined;
    const v = vectors.fromSlice(counting(&buffer));
    const at = vectors.chunk;

    const first = at(v, 5);
    expect(first.start == 0 and first.len == vectors.width);
    const second = at(v, 63);
    expect(second.start == 32 and second.len == vectors.width);
    const tail = at(v, 99);
    expect(tail.start == 96 and tail.len == 4);
    expect(tail.items.? == @as([*]const repr.Value, &v.tail.?.items));
}

/// An update leaves the vector it was made from unchanged, and shares every
/// leaf not on its path. The old and new vectors are both read after a
/// collection, so a shared node that was not marked would already be freed.
fn anUpdateKeepsTheOriginal() !void {
    var buffer: [1100]repr.Value = undefined;
    const elements = counting(&buffer);
    const original = vectors.fromSlice(elements);
    gc_alloc.gcroot(wrap.fromVector(original));

    const marker = harness.wrapInteger(-1);
    const updated = vectors.assoc(original, 40, marker);
    gc_alloc.gcroot(wrap.fromVector(updated));
    const appended = vectors.conj(original, marker);
    gc_alloc.gcroot(wrap.fromVector(appended));

    gc_mark.collect();

    try expectElements(original, elements);
    var changed: [1100]repr.Value = undefined;
    @memcpy(&changed, elements);
    changed[40] = marker;
    try expectElements(updated, &changed);
    var longer: [1101]repr.Value = undefined;
    @memcpy(longer[0..1100], elements);
    longer[1100] = marker;
    try expectElements(appended, &longer);

    // Only the leaf holding index 40 differs between the two tries.
    const at = vectors.chunk;
    expect(at(original, 40).items.? != at(updated, 40).items.?);
    expect(at(original, 0).items.? == at(updated, 0).items.?);
    expect(at(original, 1000).items.? == at(updated, 1000).items.?);
    expect(at(original, 1000).items.? == at(appended, 1000).items.?);

    _ = gc_alloc.gcunroot(wrap.fromVector(appended));
    _ = gc_alloc.gcunroot(wrap.fromVector(updated));
    _ = gc_alloc.gcunroot(wrap.fromVector(original));
}

/// The number of nodes with `own_editable` set in the trie under `node`,
/// `node` included. The walk follows every child, not only editable ones, so
/// it does not rely on the rule that `persistent` does.
fn editableUnder(node: *abi.GCObject) usize {
    var count: usize = if (node.flags.own & vectors.own_editable != 0) 1 else 0;
    if (gc_alloc.memoryTypeOf(node) == .vector_inner) {
        const inner: *vectors.Inner = @alignCast(@fieldParentPtr("gc", node));
        for (inner.children) |slot| {
            if (slot) |child| count += editableUnder(child);
        }
    }
    return count;
}

/// The number of nodes with `own_editable` set in `v`'s trie and tail.
fn editableIn(v: *const vectors.Vector) usize {
    var count: usize = 0;
    if (v.root) |root| count += editableUnder(root);
    if (v.tail) |tail| count += editableUnder(&tail.gc);
    return count;
}

/// A transient changes a node in place once it has made the node, and never a
/// node of the vector it came from. `persistent` leaves no node editable, and
/// a second transient of the result copies rather than changing the first
/// transient's nodes, which is the case where one bit and not an edit token
/// has to be enough.
fn aTransientChangesOnlyItsOwnNodes() !void {
    var buffer: [1100]repr.Value = undefined;
    const elements = counting(&buffer);
    const original = vectors.fromSlice(elements);
    gc_alloc.gcroot(wrap.fromVector(original));
    const at = vectors.chunk;

    const t = transients.fromVector(original);
    gc_alloc.gcroot(wrap.fromAbstract(t));
    const marker = harness.wrapInteger(-1);

    // The first update copies the leaf, and the second changes the copy.
    vectors.transientAssoc(&t.vector, 40, marker);
    const copied = at(&t.vector, 40).items.?;
    expect(copied != at(original, 40).items.?);
    vectors.transientAssoc(&t.vector, 41, marker);
    expect(at(&t.vector, 41).items.? == copied);
    expect(at(&t.vector, 63).items.? == copied);

    // Appends past two leaves, with a collection between them.
    var tail_made: *vectors.Leaf = undefined;
    var expected: [1200]repr.Value = undefined;
    @memcpy(expected[0..1100], elements);
    expected[40] = marker;
    expected[41] = marker;
    for (1100..1200) |i| {
        expected[i] = harness.wrapInteger(@intCast(i * 7));
        vectors.transientConj(&t.vector, expected[i]);
        if (i == 1150) gc_mark.collect();
        // Index 1184 starts a new tail. The transient made it, so the next
        // append changes it in place.
        if (i == 1184) tail_made = t.vector.tail.?;
        if (i == 1185) expect(t.vector.tail.? == tail_made);
    }
    expect(editableIn(&t.vector) > 0);
    try expectElements(original, elements);
    expect(editableIn(original) == 0);

    const v = vectors.toVector(transients.persistent(t)).?;
    gc_alloc.gcroot(wrap.fromVector(v));
    expect(t.* == .ended);
    expect(editableIn(v) == 0);
    try expectElements(v, &expected);
    const built = vectors.fromSlice(&expected);
    expect(order.equals(wrap.fromVector(v), wrap.fromVector(built)));
    expect(order.hash(wrap.fromVector(v)) == order.hash(wrap.fromVector(built)));

    // A second transient of the result must not change it.
    const second = transients.fromVector(v);
    vectors.transientAssoc(&second.vector, 41, harness.wrapInteger(-2));
    vectors.transientConj(&second.vector, harness.wrapInteger(-3));
    try expectElements(v, &expected);
    expect(at(&second.vector, 41).items.? != at(v, 41).items.?);

    _ = gc_alloc.gcunroot(wrap.fromVector(v));
    _ = gc_alloc.gcunroot(wrap.fromAbstract(t));
    _ = gc_alloc.gcunroot(wrap.fromVector(original));
}

/// A transient that is never persisted is collected with every node it made,
/// and the vector it came from keeps its own.
fn anAbandonedTransientIsCollected() !void {
    var buffer: [40]repr.Value = undefined;
    const elements = counting(&buffer);
    const original = vectors.fromSlice(elements);
    gc_alloc.gcroot(wrap.fromVector(original));
    gc_mark.collect();
    const before = harness.vm().gc.block_count;

    const t = transients.fromVector(original);
    for (0..500) |i| vectors.transientConj(&t.vector, harness.wrapInteger(@intCast(i)));
    vectors.transientAssoc(&t.vector, 3, harness.wrapInteger(-1));
    expect(harness.vm().gc.block_count > before + 15);

    gc_mark.collect();
    expect(harness.vm().gc.block_count == before);
    try expectElements(original, elements);
    _ = gc_alloc.gcunroot(wrap.fromVector(original));
}

/// A version and the elements it should have.
const Version = struct {
    vector: *const vectors.Vector,
    elements: std.ArrayListUnmanaged(repr.Value),
};

/// Updates chosen at random from a fixed seed, each applied to a version
/// chosen at random, agree with the same updates applied to arrays. Some
/// rounds make a batch of updates through a transient. Every
/// version made is kept and rooted, and every one is read again after the last
/// update and a collection, so an update that changed a node another version
/// shares is a failure here.
fn randomUpdatesAgainstArrays() !void {
    const allocator = std.heap.c_allocator;
    var prng = std.Random.DefaultPrng.init(0x7665_6374);
    const random = prng.random();

    var versions: std.ArrayListUnmanaged(Version) = .empty;
    defer {
        for (versions.items) |*version| {
            _ = gc_alloc.gcunroot(wrap.fromVector(version.vector));
            version.elements.deinit(allocator);
        }
        versions.deinit(allocator);
    }

    const empty = vectors.fromSlice(&.{});
    gc_alloc.gcroot(wrap.fromVector(empty));
    try versions.append(allocator, .{ .vector = empty, .elements = .empty });

    for (0..3000) |round| {
        const source = versions.items[random.uintLessThan(usize, versions.items.len)];
        var elements = try source.elements.clone(allocator);
        const x = harness.wrapInteger(@intCast(round));
        var v: *const vectors.Vector = undefined;
        const choice = random.uintLessThan(u8, 4);
        if (choice == 3) {
            // A batch through a transient, rooted in case the batch collects.
            const t = transients.fromVector(source.vector);
            gc_alloc.gcroot(wrap.fromAbstract(t));
            for (0..random.uintLessThan(usize, 100)) |i| {
                const element = harness.wrapInteger(@intCast(round * 100 + i));
                const len = elements.items.len;
                if (len == 0 or random.boolean()) {
                    vectors.transientConj(&t.vector, element);
                    try elements.append(allocator, element);
                } else {
                    const index = random.uintLessThan(usize, len);
                    vectors.transientAssoc(&t.vector, index, element);
                    elements.items[index] = element;
                }
                if (i == 50 and round % 10 == 0) gc_mark.collect();
            }
            _ = gc_alloc.gcunroot(wrap.fromAbstract(t));
            v = vectors.toVector(transients.persistent(t)).?;
            expect(editableIn(v) == 0);
        } else if (elements.items.len == 0 or choice != 0) {
            // Appends outnumber replacements, so the versions grow past a
            // trie level.
            const count = 1 + random.uintLessThan(usize, 80);
            v = source.vector;
            for (0..count) |i| {
                const element = harness.wrapInteger(@intCast(round * 100 + i));
                v = vectors.conj(v, element);
                try elements.append(allocator, element);
            }
        } else {
            const index = random.uintLessThan(usize, elements.items.len);
            v = vectors.assoc(source.vector, index, x);
            elements.items[index] = x;
        }
        gc_alloc.gcroot(wrap.fromVector(v));
        try versions.append(allocator, .{ .vector = v, .elements = elements });
        if (round % 500 == 0) gc_mark.collect();
    }

    gc_mark.collect();
    for (versions.items) |version| try expectElements(version.vector, version.elements.items);
}

/// Equal vectors are equal however they were built, and have one hash.
/// Vectors order element by element and then by length. A vector is not equal
/// to a tuple of the same elements, as an array is not.
fn equalityOrderAndHash() void {
    var buffer: [70]repr.Value = undefined;
    const elements = counting(&buffer);
    const built = wrap.fromVector(vectors.fromSlice(elements));

    var grown = vectors.fromSlice(&.{});
    for (elements) |x| grown = vectors.conj(grown, x);
    expect(order.equals(built, wrap.fromVector(grown)));
    expect(order.compare(built, wrap.fromVector(grown)) == 0);
    expect(order.hash(built) == order.hash(wrap.fromVector(grown)));

    // Replacing an element and putting it back restores the hash.
    const changed = vectors.assoc(grown, 50, harness.wrapInteger(-5));
    expect(!order.equals(built, wrap.fromVector(changed)));
    const restored = vectors.assoc(changed, 50, elements[50]);
    expect(order.equals(built, wrap.fromVector(restored)));
    expect(order.hash(built) == order.hash(wrap.fromVector(restored)));

    // The first element that differs decides, and a lower one sorts first.
    expect(order.compare(wrap.fromVector(changed), built) == -1);
    expect(order.compare(built, wrap.fromVector(changed)) == 1);
    const last_lower = wrap.fromVector(vectors.assoc(grown, 69, harness.wrapInteger(-5)));
    expect(order.compare(last_lower, built) == -1);
    expect(order.compare(built, last_lower) == 1);

    // A hash depends on where an element is, not only on which elements
    // there are.
    const forwards = wrap.fromVector(vectors.fromSlice(elements[0..2]));
    const backwards = wrap.fromVector(vectors.fromSlice(&.{ elements[1], elements[0] }));
    expect(order.hash(forwards) != order.hash(backwards));

    // A prefix sorts before the vector it is a prefix of, and is not equal.
    const prefix = wrap.fromVector(vectors.fromSlice(elements[0..69]));
    expect(order.compare(prefix, built) == -1);
    expect(order.compare(built, prefix) == 1);
    expect(!order.equals(prefix, built));

    // Elements compare by the runtime's equality: negative zero equals zero.
    const zero = wrap.fromVector(vectors.fromSlice(&.{wrap.fromNumber(0.0)}));
    const negative = wrap.fromVector(vectors.fromSlice(&.{wrap.fromNumber(-0.0)}));
    expect(order.equals(zero, negative));
    expect(order.hash(zero) == order.hash(negative));

    // Vectors nest, and compare through the nesting.
    const inner_a = wrap.fromVector(vectors.fromSlice(elements[0..3]));
    const inner_b = wrap.fromVector(vectors.fromSlice(elements[0..3]));
    const outer_a = wrap.fromVector(vectors.fromSlice(&.{ inner_a, elements[9] }));
    const outer_b = wrap.fromVector(vectors.fromSlice(&.{ inner_b, elements[9] }));
    expect(order.equals(outer_a, outer_b));
    expect(order.hash(outer_a) == order.hash(outer_b));

    expect(!order.equals(built, wrap.fromTuple(tuples.newFrom(elements))));
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

/// A vector read back from its marshalled form has the shape, the elements
/// and the hash of the one written, at every length where the shape changes,
/// and none of its nodes is editable. It is read again after a collection, so
/// a node the unmarshaller made and did not store is a failure here.
fn marshallingRoundTripsAtEachBoundary() !void {
    const most = boundary_lengths[boundary_lengths.len - 1];
    const buffer = try std.heap.c_allocator.alloc(repr.Value, most);
    defer std.heap.c_allocator.free(buffer);
    const elements = counting(buffer);

    for (boundary_lengths) |n| {
        const written = wrap.fromVector(vectors.fromSlice(elements[0..n]));
        const bytes = try marshalled(written);
        const back = try unmarshalled(bytes.slice());
        const v = vectors.toVector(back).?;
        gc_alloc.gcroot(back);
        gc_mark.collect();
        expect(v.shift == expectedShift(n));
        expect(editableIn(v) == 0);
        try expectElements(v, elements[0..n]);
        expect(order.hash(back) == order.hash(wrap.fromVector(vectors.fromSlice(elements[0..n]))));
        _ = gc_alloc.gcunroot(back);
    }
}

/// The bytes of a marshalled vector: its own lead byte, the length as a
/// marshalled integer, and then each element, as a tuple is written but with
/// no flags. A marshalled stream is a file format, so the bytes are the
/// contract.
fn theWireFormat() !void {
    const lb_vector = 233;
    const three = wrap.fromVector(vectors.fromSlice(&.{
        harness.wrapInteger(1), harness.wrapInteger(2), harness.wrapInteger(3),
    }));
    const b = try marshalled(three);
    expect(std.mem.eql(u8, b.slice(), &[_]u8{ lb_vector, 3, 1, 2, 3 }));

    // A length from 128 to 8191 is two bytes, the high six bits under 0x80
    // and then the low byte.
    var many: [300]repr.Value = undefined;
    const long = try marshalled(wrap.fromVector(vectors.fromSlice(counting(&many))));
    expect(std.mem.eql(u8, long.slice()[0..3], &[_]u8{ lb_vector, 0x81, 0x2C }));
    expect(long.slice()[3] == 0);
}

/// A vector that occurs twice in what is marshalled is read back as one
/// vector, and equal vectors are too, as equal tuples are. A vector reachable
/// from its own element is read back as two equal vectors, and a table that
/// has the inner one as a key still finds it, which is why a vector enters the
/// reference table after its elements.
fn marshallingKeepsIdentityAndHashes() !void {
    var buffer: [40]repr.Value = undefined;
    const shared = wrap.fromVector(vectors.fromSlice(counting(&buffer)));
    const equal = wrap.fromVector(vectors.fromSlice(counting(&buffer)));
    const holder = arrays.new(3);
    harness.arrayPush(holder, shared);
    harness.arrayPush(holder, shared);
    harness.arrayPush(holder, equal);
    const back = try unmarshalled((try marshalled(wrap.fromArray(holder))).slice());
    const items = wrap.toArray(back).slice();
    expect(items.len == 3);
    expect(wrap.toVector(items[0]) == wrap.toVector(items[1]));
    expect(wrap.toVector(items[0]) == wrap.toVector(items[2]));
    try expectElements(vectors.toVector(items[0]).?, counting(&buffer));

    // A table holding, as a key, the vector that holds the table.
    const t = tables.new(1);
    const outer = wrap.fromVector(vectors.fromSlice(&.{wrap.fromTable(t)}));
    tables.put(t, outer, harness.wrapInteger(7));
    const cycled = try unmarshalled((try marshalled(outer)).slice());
    const back_v = vectors.toVector(cycled).?;
    expect(back_v.count == 1);
    const back_t = wrap.toTable(vectors.at(back_v, 0));
    expect(harness.integerIs(tables.get(back_t, cycled), 7));
    for (back_t.slots()[0..back_t.capacity]) |kv| {
        if (repr.checkType(kv.key, repr.Tag.nil)) continue;
        expect(wrap.toVector(kv.key) != wrap.toVector(cycled));
    }
}

/// A stream cut short anywhere is refused, and so is a length the rest of the
/// stream is too short to hold.
fn aShortStreamIsRefused() !void {
    var buffer: [70]repr.Value = undefined;
    const elements = counting(&buffer);
    elements[40] = wrap.fromVector(vectors.fromSlice(elements[0..3]));
    const whole = try marshalled(wrap.fromVector(vectors.fromSlice(elements)));
    gc_alloc.gcroot(wrap.fromBuffer(whole));
    for (0..@intCast(whole.count)) |len| {
        const refusal = harness.raised(unmarshalled, .{whole.slice()[0..len]});
        expect(refusal != null and refusal.?.signal == abi.Signal.@"error");
    }
    _ = gc_alloc.gcunroot(wrap.fromBuffer(whole));

    // A length of 200 with two elements after it.
    const lb_vector = 233;
    const lying = [_]u8{ lb_vector, 0x80, 0xC8, 1, 2 };
    expect(harness.raised(unmarshalled, .{@as([]const u8, &lying)}).?.says("unexpected end of source"));
}

/// A transient has no `marshal` callback, so marshalling one is refused.
fn aTransientIsNotMarshalled() !void {
    const t = transients.fromVector(vectors.fromSlice(&.{harness.wrapInteger(1)}));
    const refusal = harness.raised(marshalled, .{wrap.fromAbstract(t)});
    expect(refusal != null and refusal.?.beginsWith("cannot marshal"));
}

// ==========================================================================
// Entry
// ==========================================================================

fn body() !void {
    try theShapeAtEachBoundary();
    try aChunkIsALeafOrTheTail();
    try anUpdateKeepsTheOriginal();
    try aTransientChangesOnlyItsOwnNodes();
    try anAbandonedTransientIsCollected();
    try randomUpdatesAgainstArrays();
    equalityOrderAndHash();
    try marshallingRoundTripsAtEachBoundary();
    try theWireFormat();
    try marshallingKeepsIdentityAndHashes();
    try aShortStreamIsRefused();
    try aTransientIsNotMarshalled();
}

pub fn run() void {
    harness.init();
    body() catch @panic("vectors: a read raised or an allocation failed");
    vm_lifecycle.deinit();
}
