//! Behavioral contract for `core/vector`: its shape at each boundary of the
//! trie, reading it as a tuple is read, persistence across updates, and
//! equality, order and hash.
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

const args = @import("subsystems").args;
const expect = @import("expect.zig").expect;
const gc_alloc = @import("subsystems").gc_alloc;
const gc_mark = @import("subsystems").gc_mark;
const harness = @import("harness.zig");
const order = @import("subsystems").value.order;
const repr = @import("repr");
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
fn expectElements(v: *vectors.Vector, expected: []const repr.Value) !void {
    expect(v.count == expected.len);
    for (expected, 0..) |x, i| expect(order.equals(vectors.at(v, i), x));

    var it = (try args.chunks(wrap.fromAbstract(v))).?;
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
    gc_alloc.gcroot(wrap.fromAbstract(v));
    var next_boundary: usize = 0;
    for (0..most + 1) |n| {
        if (n == boundary_lengths[next_boundary]) {
            expect(v.shift == expectedShift(n));
            try expectElements(v, elements[0..n]);
            const built = vectors.fromSlice(elements[0..n]);
            expect(order.equals(wrap.fromAbstract(v), wrap.fromAbstract(built)));
            expect(order.hash(wrap.fromAbstract(v)) == order.hash(wrap.fromAbstract(built)));
            next_boundary += 1;
        }
        if (n == most) break;
        const bigger = vectors.conj(v, elements[n]);
        _ = gc_alloc.gcunroot(wrap.fromAbstract(v));
        v = bigger;
        gc_alloc.gcroot(wrap.fromAbstract(v));
    }
    _ = gc_alloc.gcunroot(wrap.fromAbstract(v));
}

/// A chunk is a node's own storage: a full leaf for an index below the tail,
/// and the tail's filled slots for an index in it. The runs start at multiples
/// of the width.
fn aChunkIsALeafOrTheTail() !void {
    var buffer: [100]repr.Value = undefined;
    const v = vectors.fromSlice(counting(&buffer));
    const at = vectors.vector_type.chunk.?;

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
    gc_alloc.gcroot(wrap.fromAbstract(original));

    const marker = harness.wrapInteger(-1);
    const updated = vectors.assoc(original, 40, marker);
    gc_alloc.gcroot(wrap.fromAbstract(updated));
    const appended = vectors.conj(original, marker);
    gc_alloc.gcroot(wrap.fromAbstract(appended));

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
    const at = vectors.vector_type.chunk.?;
    expect(at(original, 40).items.? != at(updated, 40).items.?);
    expect(at(original, 0).items.? == at(updated, 0).items.?);
    expect(at(original, 1000).items.? == at(updated, 1000).items.?);
    expect(at(original, 1000).items.? == at(appended, 1000).items.?);

    _ = gc_alloc.gcunroot(wrap.fromAbstract(appended));
    _ = gc_alloc.gcunroot(wrap.fromAbstract(updated));
    _ = gc_alloc.gcunroot(wrap.fromAbstract(original));
}

/// A version and the elements it should have.
const Version = struct {
    vector: *vectors.Vector,
    elements: std.ArrayListUnmanaged(repr.Value),
};

/// Updates chosen at random from a fixed seed, each applied to a version
/// chosen at random, agree with the same updates applied to arrays. Every
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
            _ = gc_alloc.gcunroot(wrap.fromAbstract(version.vector));
            version.elements.deinit(allocator);
        }
        versions.deinit(allocator);
    }

    const empty = vectors.fromSlice(&.{});
    gc_alloc.gcroot(wrap.fromAbstract(empty));
    try versions.append(allocator, .{ .vector = empty, .elements = .empty });

    for (0..3000) |round| {
        const source = versions.items[random.uintLessThan(usize, versions.items.len)];
        var elements = try source.elements.clone(allocator);
        const x = harness.wrapInteger(@intCast(round));
        var v: *vectors.Vector = undefined;
        if (elements.items.len == 0 or random.uintLessThan(u8, 3) != 0) {
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
        gc_alloc.gcroot(wrap.fromAbstract(v));
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
    const built = wrap.fromAbstract(vectors.fromSlice(elements));

    var grown = vectors.fromSlice(&.{});
    for (elements) |x| grown = vectors.conj(grown, x);
    expect(order.equals(built, wrap.fromAbstract(grown)));
    expect(order.compare(built, wrap.fromAbstract(grown)) == 0);
    expect(order.hash(built) == order.hash(wrap.fromAbstract(grown)));

    // Replacing an element and putting it back restores the hash.
    const changed = vectors.assoc(grown, 50, harness.wrapInteger(-5));
    expect(!order.equals(built, wrap.fromAbstract(changed)));
    const restored = vectors.assoc(changed, 50, elements[50]);
    expect(order.equals(built, wrap.fromAbstract(restored)));
    expect(order.hash(built) == order.hash(wrap.fromAbstract(restored)));

    // The first element that differs decides, and a lower one sorts first.
    expect(order.compare(wrap.fromAbstract(changed), built) == -1);
    expect(order.compare(built, wrap.fromAbstract(changed)) == 1);
    const last_lower = wrap.fromAbstract(vectors.assoc(grown, 69, harness.wrapInteger(-5)));
    expect(order.compare(last_lower, built) == -1);
    expect(order.compare(built, last_lower) == 1);

    // A hash depends on where an element is, not only on which elements
    // there are.
    const forwards = wrap.fromAbstract(vectors.fromSlice(elements[0..2]));
    const backwards = wrap.fromAbstract(vectors.fromSlice(&.{ elements[1], elements[0] }));
    expect(order.hash(forwards) != order.hash(backwards));

    // A prefix sorts before the vector it is a prefix of, and is not equal.
    const prefix = wrap.fromAbstract(vectors.fromSlice(elements[0..69]));
    expect(order.compare(prefix, built) == -1);
    expect(order.compare(built, prefix) == 1);
    expect(!order.equals(prefix, built));

    // Elements compare by the runtime's equality: negative zero equals zero.
    const zero = wrap.fromAbstract(vectors.fromSlice(&.{wrap.fromNumber(0.0)}));
    const negative = wrap.fromAbstract(vectors.fromSlice(&.{wrap.fromNumber(-0.0)}));
    expect(order.equals(zero, negative));
    expect(order.hash(zero) == order.hash(negative));

    // Vectors nest, and compare through the nesting.
    const inner_a = wrap.fromAbstract(vectors.fromSlice(elements[0..3]));
    const inner_b = wrap.fromAbstract(vectors.fromSlice(elements[0..3]));
    const outer_a = wrap.fromAbstract(vectors.fromSlice(&.{ inner_a, elements[9] }));
    const outer_b = wrap.fromAbstract(vectors.fromSlice(&.{ inner_b, elements[9] }));
    expect(order.equals(outer_a, outer_b));
    expect(order.hash(outer_a) == order.hash(outer_b));

    expect(!order.equals(built, wrap.fromTuple(tuples.newFrom(elements))));
}

// ==========================================================================
// Entry
// ==========================================================================

fn body() !void {
    try theShapeAtEachBoundary();
    try aChunkIsALeafOrTheTail();
    try anUpdateKeepsTheOriginal();
    try randomUpdatesAgainstArrays();
    equalityOrderAndHash();
}

pub fn run() void {
    harness.init();
    body() catch @panic("vectors: a read raised or an allocation failed");
    vm_lifecycle.deinit();
}
