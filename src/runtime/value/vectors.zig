//! `Vector`: the persistent vector, a trie of 32-way nodes with a tail.
//!
//! A vector is a built-in type with the tag `vector`. Its value points at a
//! `Head`, a `vector` block holding the collector's object and a `Vector`.
//! `lib` installs `vector`, `vec`, `conj` and `assoc`, and `at` reads one
//! element. `conj` and `assoc` also take a set and a map, which they pass to
//! `maps.zig`. A program reads a vector as it reads a tuple, by an arm of each
//! switch on the tag, and `chunk` gives the runs `args.chunks` reads.
//!
//! A vector's nodes are collector blocks of their own memory types. An
//! _inner node_ is a `vector_inner` block and has 32 child pointers. A _leaf_
//! is a `vector_leaf` block and has one to 32 elements, as many as its
//! `capacityOf` says, which follow the header in the same block. `newInner` and
//! `newLeaf` allocate them, and `items` gives a leaf's elements. `gc/mark.zig`'s `markNode` marks a node and everything under
//! it, and `gc/sweep.zig` frees an unreachable node with no finalizer. A
//! `vector` block owns nothing outside itself either.
//!
//! ## The shape of a vector
//!
//! The last one to 32 elements are in the _tail_, a leaf the payload points at
//! directly. The rest are in the trie under `root`, in full leaves. While a
//! vector has 32 elements or fewer, `root` is null.
//!
//! A leaf in the trie is always 32 elements; only the tail is ever shorter.
//! The tail is allocated at the capacity it needs and doubles as it fills, so
//! a vector of two elements is a block of two rather than of 32, and a tail
//! reaching 32 is full when it is grafted into the trie. When the trie has one
//! leaf, `root` is that leaf and `shift` is zero. Otherwise `root` is an inner
//! node, and `shift` is the bit position the root's child index is read from.
//!
//! These rules hold for every node:
//!
//! - A node begins with its `GCObject`, so the collector reaches the node's
//!   memory type through the header. An inner node's child pointers are
//!   `*abi.GCObject` for the same reason: the child's type says whether it is
//!   an inner node or a leaf.
//!
//! - Every slot of a node holds a valid entry from allocation onwards. An
//!   unused child is null and an unused element is nil. The mark phase reads
//!   every slot a node has, because a node records how many it has room for
//!   and not how many are in use: how many of a tail's elements a vector is
//!   using follows from the vector's `count`.
//!
//! - A node is not changed once a vector refers to it. An update copies the
//!   path from the root to the element it changes, so the old vector and the
//!   new one share every other node. Two updates change nodes in place: a
//!   transient's, on the nodes it made, and building a vector from a slice,
//!   on nodes no vector refers to yet. A full tail is the one node neither
//!   can change in place, since a block cannot grow where it lies: it is
//!   copied into one of twice the capacity.
//!
//! ## Updating a vector in place
//!
//! `transients.zig`'s transient holds a `Vector` and updates it through
//! `transientConj` and `transientAssoc`, and `persistent` makes a vector of
//! it. These rules make that safe:
//!
//! - A transient update sets `own_editable` on every node it makes, and
//!   changes a node in place only where the bit is set. A node a transient
//!   made is reachable from that transient and from nothing else, because a
//!   transient is made only from a vector and `persistent!` ends it. A tail
//!   the transient made is still copied where it is full, and the copy keeps
//!   the bit.
//!
//! - An update makes the whole path from the root editable, so every editable
//!   node's parent is editable. `persistent` clears the bits by walking down
//!   through set bits only, which visits exactly the nodes the transient made.
//!
//! ## Equality, order and hash
//!
//! Two vectors are equal when their elements are, in order. `order.zig` walks
//! both on its traversal stack, as it walks two tuples, because a `compare`
//! callback may not re-enter a comparison. Vectors order element by element,
//! and then by length.
//!
//! A vector's hash is kept current rather than computed when asked. `sum` is
//! the wrapping sum of one term per element, and each term mixes the
//! element's index with the element's hash. `conj` adds one term and `assoc`
//! replaces one, so neither walks the vector, and hashing a vector nested in
//! another does not recurse.
//!
//! ## Marshalling
//!
//! `marsh.zig` writes a vector as its lead byte, its length and then its
//! elements, and reads it back with `unmarshalAppend`, appending each element
//! in place, as a transient does, to a trie no vector refers to yet. Nodes are not
//! written, so two vectors that share nodes share none once read back.
//!
//! A vector enters the marshaller's reference table after its elements, as a
//! tuple does, not before them, as a table does. Its hash depends
//! on its elements, so a vector that was referred to while it was still being
//! read would hash differently once complete, and a table or a struct that
//! had used it as a key would no longer find it. A later occurrence of the
//! same vector is still written as a reference. A vector reachable from its
//! own elements, through a table or an array, is read back as two equal
//! vectors, the inner one written in full.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const args_core = @import("../args.zig");
const corefn = @import("../corefn.zig");
const gc_alloc = @import("../gc.zig");
const gc_mark = @import("../gc/mark.zig");
const maps = @import("maps.zig");
const order = @import("helpers/order.zig");
const pp_format = @import("../pp/format.zig");
const raise = @import("../../api/raise.zig");
const repr = @import("repr");
const scratch_vector = @import("../scratch_vector.zig");
const tables = @import("tables.zig");
const value = @import("../value.zig");
const wrap = @import("helpers/wrap.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// The number of bits of an index one level of the trie consumes.
const bits = 5;

/// Where a vector's inline tail sits inside its `Head` block.
///
/// `Head`'s own size is rounded up to the leaf's alignment rather than used as
/// it stands. A `Leaf`'s elements are eight-byte aligned at every pointer
/// width, because `repr.Value` holds an `f64`, but `Head` is a pointer-width
/// `Vector` behind a `GCObject` and so is twenty-eight bytes where a pointer
/// is four. A leaf placed at that offset would start four bytes below its
/// alignment. The rounding is a no-op at sixty-four bits, where `Head` is
/// fifty-six bytes.
const inline_leaf_offset: usize = std.mem.alignForward(usize, @sizeOf(Head), @alignOf(Leaf));

/// The low `bits` bits of an index: the slot within one node.
const mask: usize = width - 1;

/// Bit 0 of the collector header's per-type field: a transient made the node
/// and may change it in place.
pub const own_editable: u6 = 1;

/// Bits 1 to 3 of a leaf's collector header: the base-two logarithm of how
/// many elements it has room for. `capacityOf` reads them and `newLeaf` writes
/// them, and nothing else touches them, so `clearEditable` clearing bit 0
/// leaves them alone.
const own_capacity_shift: u3 = 1;
const own_capacity_mask: u6 = 0b1110;

/// Bit 4 of a leaf's collector header: the leaf lives inside the vector's own
/// `Head` block rather than in one of its own, which is what makes a short
/// vector a single allocation.
///
/// It is on the leaf's header rather than the head's so that a holder of the
/// leaf alone can tell: a transient copies the vector payload and so arrives
/// with the tail pointer and nothing else. `allocLeaf` starts from a zeroed
/// header, so a copy of an inline leaf does not inherit it.
pub const own_inline: u6 = 0b10000;

/// The number of slots in a node.
pub const width = 1 << bits;

// ==========================================================================
// Aliased types
// ==========================================================================

/// The type a shift amount has for a `usize`.
const Shift = std.math.Log2Int(usize);

// ==========================================================================
// Types
// ==========================================================================

/// A vector's block: the collector's object and the payload.
///
/// A vector's value points at its `Head`, and `ofHead` and `wrap.toVector`
/// return the `Vector` inside it.
pub const Head = extern struct {
    gc: abi.GCObject = .{},
    vector: Vector = .{},
};

/// A vector's inner node: the collector's object and 32 child pointers.
///
/// `newInner` returns an `Inner`. Each child in `children` is the header of an
/// `Inner` or a `Leaf`, or null where the slot is unused.
pub const Inner = extern struct {
    gc: abi.GCObject = .{},
    children: [width]?*abi.GCObject = @splat(null),
};

/// A vector's leaf: the collector's object and its elements.
///
/// `newLeaf` returns a `Leaf` and `items` gives its elements, which follow the
/// header in the same block. `capacityOf` is how many there is room for, a
/// power of two from one to `width`, and every one of them holds a valid
/// entry, with nil in each unused slot. A leaf in the trie is always `width`
/// long; only a tail is ever shorter, and it doubles as it fills.
///
/// The capacity is three bits of the collector header rather than a field of
/// its own, because a field costs eight bytes: `GCObject` is sixteen bytes and
/// the elements are eight-byte aligned, so a `u32` and its padding move them
/// from offset sixteen to twenty-four. Those eight bytes are most of what a
/// short tail saves, and they made a full leaf larger than it had been, which
/// measured as a five percent regression on building a vector of `width`
/// elements. The header had five bits spare beside `own_editable`.
pub const Leaf = extern struct {
    gc: abi.GCObject = .{},
    _items: [0]repr.Value = .{},
};

/// How an update treats the nodes on the path it changes.
///
/// `persistent` copies every one, for a vector that others may share.
/// `transient` changes a node with `own_editable` set in place, and copies any
/// other with the bit set on the copy. `fresh` changes every one in place, for
/// a trie no vector refers to yet.
const Mode = enum { persistent, transient, fresh };

/// A vector's payload.
///
/// It is the `vector` field of a `Head`, or a transient's own copy. `count` is
/// the number of elements. `root` is the trie and `shift` the bit
/// position its child index is read from, as the file header describes.
/// `tail` is the leaf holding the last elements, and is null only when `count`
/// is zero. `sum` is the running sum the hash is made from.
pub const Vector = extern struct {
    count: usize = 0,
    shift: u32 = 0,
    root: ?*abi.GCObject = null,
    tail: ?*Leaf = null,
    sum: u32 = 0,
};

// ==========================================================================
// Public functions
// ==========================================================================

/// Returns a new vector equal to `src` with the element at `index` replaced by
/// `x`.
///
/// This function cannot raise. `index` must be below `src.count`, and an index
/// at or past it is illegal behaviour. The new vector shares every node with
/// `src` except those on the path to `index`.
pub fn assoc(src: *const Vector, index: usize, x: repr.Value) *Vector {
    const dest = newVector();
    dest.* = src.*;
    replaceIn(dest, index, x, .persistent);
    return dest;
}

/// Returns the element at `index` of `v`.
///
/// This function cannot raise. `index` must be below `v.count`, and an index
/// at or past it is illegal behaviour.
pub fn at(v: *const Vector, index: usize) repr.Value {
    std.debug.assert(index < v.count);
    const offset = tailOffset(v);
    if (index >= offset) return elements(v.tail.?)[index - offset];
    return elements(leafFor(v, index))[index & mask];
}

/// Refuses a key-value list with a key and no value.
///
/// `argv` is a frame whose first argument is the collection and the rest keys
/// and values. This function raises if a key has no value.
pub fn checkPairs(argv: []const repr.Value) raise.Error!void {
    if (argv.len % 2 == 0) {
        return pp_format.panicf("expected an even number of keys and values, got %d", .{@as(i32, @intCast(argv.len - 1))});
    }
}

/// Returns the leaf or the tail that holds `index` of `v`, as a run.
///
/// This function cannot raise. `index` must be below `v.count`. The run is
/// whole rather than cut at `index`, and a run of the tail ends at the last
/// element. A run stays valid while `v` is reachable, since a node does not
/// change once a vector refers to it.
pub fn chunk(v: *const Vector, index: usize) abi.Chunk {
    std.debug.assert(index < v.count);
    const offset = tailOffset(v);
    if (index >= offset) return .{ .items = elements(v.tail.?), .len = v.count - offset, .start = offset };
    return .{ .items = elements(leafFor(v, index)), .len = width, .start = index & ~mask };
}

/// Returns a new vector equal to `src` with `x` appended.
///
/// This function cannot raise. The new vector shares every node with `src`
/// except the tail and, where the tail was full, the path to where it moved.
pub fn conj(src: *const Vector, x: repr.Value) *Vector {
    const dest = newVector();
    dest.* = src.*;
    appendIn(dest, x, .persistent);
    return dest;
}

/// The finalizer from 32-bit MurmurHash3, used on its own as an integer mixer.
///
/// This function cannot raise. `maps.zig` mixes its terms with it too.
pub fn fmix32(h_in: u32) u32 {
    var h = h_in;
    h ^= h >> 16;
    h *%= 0x85ebca6b;
    h ^= h >> 13;
    h *%= 0xc2b2ae35;
    h ^= h >> 16;
    return h;
}

/// Returns a new vector that takes the nodes `unmarshalAppend` built.
///
/// This function cannot raise.
pub fn fromBuilt(built: Vector) *const Vector {
    const v = newVector();
    v.* = built;
    return v;
}

/// Returns a new vector of the elements of `xs`.
///
/// This function cannot raise. `xs` must stay valid while the vector is built,
/// which no allocation this makes can change. The full leaves are grafted into
/// a trie no vector refers to yet, so the graft changes the nodes it reaches
/// rather than copying them.
pub fn fromSlice(xs: []const repr.Value) *Vector {
    const n = xs.len;
    // A vector that is its tail alone is one block, head and leaf together.
    // Anything with a trie keeps the two-block shape: the tail is grafted in
    // as the trie grows, and a leaf that moves cannot be part of the head.
    if (n != 0 and n <= width) {
        const v = newVectorInline(capacityFor(n));
        fillLeaf(v.tail.?, xs);
        v.count = n;
        for (xs, 0..) |x, index| v.sum +%= term(index, x);
        return v;
    }
    const v = newVector();
    if (n == 0) return v;
    const trie_len = ((n - 1) >> bits) << bits;
    var start: usize = 0;
    while (start < trie_len) : (start += width) {
        const leaf = allocLeaf(width);
        fillLeaf(leaf, xs[start..][0..width]);
        pushLeaf(v, leaf, start + width, .fresh);
    }
    const tail = allocLeaf(capacityFor(n - trie_len));
    fillLeaf(tail, xs[trie_len..]);
    v.tail = tail;
    v.count = n;
    for (xs, 0..) |x, index| v.sum +%= term(index, x);
    return v;
}

/// Returns the index in argument `n` of `argv`.
///
/// `count` is the length of the vector the index is into. This function raises
/// if the argument is not a non-negative integer, or is past `count`. An index
/// equal to `count` is where an element is appended.
pub fn getIndex(argv: []const repr.Value, n: usize, count: usize) raise.Error!usize {
    const index = try args_core.getSize(argv, n);
    if (index > count) {
        return pp_format.panicf("index %u out of range for vector of length %u", .{ @as(u64, index), @as(u64, count) });
    }
    return index;
}

/// Returns a vector's hash: its length mixed with the running sum.
///
/// This function cannot raise.
pub fn hash(v: *const Vector) i32 {
    return @bitCast(value.hashMix(@truncate(v.count), v.sum));
}

/// Installs `vector`, `vec`, `conj` and `assoc` into the core environment.
///
/// `env` is the environment.
pub fn lib(env: *tables.Table) void {
    const entries = comptime [_]corefn.Entry{
        corefn.reg("vector", &nfunVector, @src(), "(vector & vals)", "Creates a new persistent vector containing vals."),
        corefn.reg("vec", &nfunVec, @src(), "(vec coll)", "Creates a persistent vector with the elements of coll, an indexed value or a dictionary. The element of a table or map is the vector `[key value]`, in iteration order. A vector is returned unchanged."),
        corefn.reg("conj", &nfunConj, @src(), "(conj p & vals)", "Returns a new collection with vals added to p, a persistent vector or set. For a vector, the elements are added at the end. An element of a set cannot be nil or NaN."),
        corefn.reg("assoc", &nfunAssoc, @src(), "(assoc p key val & kvs)", "Returns a new collection in which each key is associated with the value that follows it, in p, a persistent vector or map. For a vector, a key is an index from 0 up to the length, and a key equal to the length adds the value at the end. Any other index raises an error, and a nil value is stored. For a map, a nil value removes the key."),
    };
    corefn.install(env, entries);
}

/// Returns the element of `v` at `key`, or null.
///
/// This function cannot raise. It returns null if `key` is not an integer at
/// or above zero and below `v.count`.
pub fn lookup(v: *const Vector, key: repr.Value) ?repr.Value {
    if (!args_core.checkint(key)) return null;
    const index = wrap.toInteger(key);
    if (index < 0 or @as(usize, @intCast(index)) >= v.count) return null;
    return at(v, @intCast(index));
}

/// Marks `v`'s trie and tail.
///
/// This function cannot raise. It is what a `gcmark` callback calls for a
/// payload that includes a `Vector`.
pub fn mark(v: *const Vector) void {
    if (v.root) |root| gc_mark.markNode(root);
    if (v.tail) |tail| {
        if (isInline(tail)) {
            for (items(@constCast(tail))) |x| gc_mark.mark(x);
        } else gc_mark.markNode(&tail.gc);
    }
}

/// Returns the elements of `leaf`, all `capacity` of them.
///
/// This function cannot raise. The run is the leaf's own storage, and every
/// slot in it holds a valid entry. How many of them a vector is using is the
/// vector's to say, from its `count`; the leaf does not record it.
pub fn items(leaf: *Leaf) []repr.Value {
    return elements(leaf)[0..capacityOf(leaf)];
}

/// Returns `leaf`'s elements without their bound.
///
/// This function cannot raise. It is for a reader that has already checked its
/// index against the vector's `count`, which is the authority on how many of a
/// tail's slots are in use; reading the capacity as well would be a second
/// bound on a read that is already inside the first.
pub inline fn elements(leaf: *const Leaf) [*]repr.Value {
    return @ptrCast(@constCast(&leaf._items));
}

/// Returns how many elements `leaf` has room for, a power of two from one to
/// `width`.
///
/// This function cannot raise.
pub fn capacityOf(leaf: *const Leaf) u32 {
    const exponent: u3 = @intCast((leaf.gc.flags.own & own_capacity_mask) >> own_capacity_shift);
    return @as(u32, 1) << exponent;
}

/// Returns whether two vectors can be equal: whether their lengths and hashes
/// are equal.
///
/// This function cannot raise. `order.zig` rejects a pair on this before
/// walking their elements.
pub fn mayEqual(a: *const Vector, b: *const Vector) bool {
    return a.count == b.count and a.sum == b.sum;
}

/// Allocates an inner node with every child null.
///
/// This function cannot raise. The node is unreachable until the caller stores
/// it where the mark phase finds it, so the next collection frees a node the
/// caller has not stored.
pub fn newInner() *Inner {
    const node = gc_alloc.gcalloc(Inner, .vector_inner);
    node.children = @splat(null);
    return node;
}

/// Allocates a leaf of `capacity` elements, every one of them nil.
///
/// This function cannot raise. `capacity` must be a power of two from one to
/// `width`. The leaf is unreachable until the caller stores it where the mark
/// phase finds it, so the next collection frees a leaf the caller has not
/// stored.
pub fn newLeaf(capacity: u32) *Leaf {
    const node = allocLeaf(capacity);
    @memset(items(node), wrap.fromNil());
    return node;
}

/// Returns the payload of a vector's block.
///
/// This function cannot raise. `head` must be the header of a `vector` block,
/// and any other header is illegal behaviour.
pub fn ofHead(head: *const abi.GCObject) *const Vector {
    std.debug.assert(gc_alloc.memoryTypeOf(head) == .vector);
    const block: *const Head = @alignCast(@fieldParentPtr("gc", head));
    return &block.vector;
}

/// Returns a new vector with `v`'s elements, and clears `own_editable` on
/// every node a transient update of `v` made.
///
/// This function cannot raise. The new vector takes `v`'s nodes, so the caller
/// makes no further transient update of `v`.
pub fn persistent(v: *const Vector) *Vector {
    const result = newVector();
    result.* = v.*;
    if (result.root) |root| clearEditable(root);
    if (result.tail) |tail| clearEditable(&tail.gc);
    return result;
}

/// Returns the payload of `x` if `x` is a vector, and null otherwise.
pub fn toVector(x: repr.Value) ?*const Vector {
    if (!repr.checkType(x, repr.Tag.vector)) return null;
    return wrap.toVector(x);
}

/// Replaces the element at `index` of `v` with `x` in place, or appends `x`
/// where `index` is `v.count`.
///
/// This function cannot raise. `index` must be at or below `v.count`, and an
/// index past it is illegal behaviour. `v` must be a transient's, since the
/// update changes the nodes it has made.
pub fn transientAssoc(v: *Vector, index: usize, x: repr.Value) void {
    std.debug.assert(index <= v.count);
    if (index == v.count) {
        appendIn(v, x, .transient);
    } else {
        replaceIn(v, index, x, .transient);
    }
}

/// Appends `x` to `v` in place.
///
/// This function cannot raise. `v` must be a transient's, since the update
/// changes the nodes it has made.
pub fn transientConj(v: *Vector, x: repr.Value) void {
    appendIn(v, x, .transient);
}

/// Appends `x` to `v` in place, where no vector refers to `v`'s nodes yet.
///
/// This function cannot raise. `marsh.zig` builds a vector it reads with this
/// on a `Vector` of its own, whose nodes are rooted nowhere, which is safe
/// because no collection runs during unmarshalling. `v` becomes a vector with
/// `fromBuilt`.
pub fn unmarshalAppend(v: *Vector, x: repr.Value) void {
    appendIn(v, x, .fresh);
}

// ==========================================================================
// Private functions
// ==========================================================================

/// Appends `x` to `v`, treating the nodes it changes as `mode` says.
fn appendIn(v: *Vector, x: repr.Value, mode: Mode) void {
    deinlineTail(v);
    const tail_count = v.count - tailOffset(v);
    if (tail_count == width) {
        pushLeaf(v, v.tail.?, v.count, mode);
        v.tail = newLeafFor(1, mode);
    } else if (tail_count == 0) {
        v.tail = newLeafFor(1, mode);
    } else {
        v.tail = growTail(v.tail.?, @intCast(tail_count), mode);
    }
    elements(v.tail.?)[tail_count % width] = x;
    v.sum +%= term(v.count, x);
    v.count += 1;
}

/// The capacity a leaf holding `len` elements is given: `len` rounded up to a
/// power of two, and at least one.
///
/// `len` must be from one to `width`, which is what a tail ever holds.
fn capacityFor(len: usize) u32 {
    std.debug.assert(len >= 1 and len <= width);
    return @intCast(std.math.ceilPowerOfTwoAssert(usize, len));
}

/// Allocates a leaf of `capacity` elements without filling them.
///
/// `capacity` must be a power of two from one to `width`. The caller makes
/// every slot valid before the leaf is stored where the mark phase can find
/// it, which is what `newLeaf` does for a caller that has nothing to put in
/// one yet. An unstored leaf is unreachable, so the collection an allocation
/// in between could schedule never sees the slots the caller has not written.
fn allocLeaf(capacity: u32) *Leaf {
    std.debug.assert(capacity >= 1 and capacity <= width);
    std.debug.assert(std.math.isPowerOfTwo(capacity));
    const size = @offsetOf(Leaf, "_items") + @sizeOf(repr.Value) * capacity;
    const node: *Leaf = @ptrCast(@alignCast(gc_alloc.gcallocBytes(.vector_leaf, size)));
    const exponent: u6 = @intCast(std.math.log2_int(u32, capacity));
    node.gc.flags.own = (node.gc.flags.own & ~own_capacity_mask) |
        (exponent << own_capacity_shift);
    return node;
}

/// Fills `leaf` with `xs` and nil in whatever room is left over.
///
/// `xs` is at most the leaf's capacity. This is the one place a leaf's slots
/// become valid where `newLeaf` did not make them so, and it leaves none
/// unwritten.
fn fillLeaf(leaf: *Leaf, xs: []const repr.Value) void {
    const slots = items(leaf);
    @memcpy(slots[0..xs.len], xs);
    @memset(slots[xs.len..], wrap.fromNil());
}

/// Casts a node header to the inner node it begins.
inline fn asInner(node: *abi.GCObject) *Inner {
    std.debug.assert(gc_alloc.memoryTypeOf(node) == .vector_inner);
    return @alignCast(@fieldParentPtr("gc", node));
}

/// Casts a node header to the leaf it begins.
inline fn asLeaf(node: *abi.GCObject) *Leaf {
    std.debug.assert(gc_alloc.memoryTypeOf(node) == .vector_leaf);
    return @alignCast(@fieldParentPtr("gc", node));
}

/// `assoc`: for a vector, a new vector with each key's element replaced, or
/// appended where the key is the length. A map goes to `maps.assocMap`.
fn nfunAssoc(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 3, -1);
    if (maps.toTree(argv[0], .map) != null) return maps.assocMap(argv);
    var v = toVector(argv[0]) orelse
        return pp_format.panicf("bad slot #0, expected vector or map, got %v", .{argv[0]});
    try checkPairs(argv);
    var i: usize = 1;
    while (i < argv.len) : (i += 2) {
        const index = try getIndex(argv, i, v.count);
        v = if (index == v.count) conj(v, argv[i + 1]) else assoc(v, index, argv[i + 1]);
    }
    return wrap.fromVector(v);
}

/// `conj`: for a vector, a new vector with the elements appended. A set goes
/// to `maps.conjSet`.
fn nfunConj(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, -1);
    if (maps.toTree(argv[0], .set) != null) return maps.conjSet(argv);
    var v = toVector(argv[0]) orelse
        return pp_format.panicf("bad slot #0, expected vector or core/set, got %v", .{argv[0]});
    for (argv[1..]) |x| v = conj(v, x);
    return wrap.fromVector(v);
}

/// `vec`: a vector of an indexed value's elements, or of a dictionary's
/// entries.
fn nfunVec(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    if (repr.checkType(argv[0], .vector)) return argv[0];
    if (try args_core.keyvals(argv[0])) |pairs| return wrap.fromVector(try entriesOf(pairs));
    // Gathered rather than read a run at a time, because building allocates
    // and a run does not survive an allocation.
    var gathered = try args_core.gatherArg(argv, 0);
    const v = fromSlice(gathered.items);
    gathered.free();
    return wrap.fromVector(v);
}

/// Returns a new vector of the entries `[k v]` that `pairs` reads, in the
/// order it reads them.
///
/// Every key and value is copied out before the first entry is built, because
/// building allocates and a run does not survive an allocation. This function
/// raises where `Keyvals.next` does.
fn entriesOf(pairs: args_core.Keyvals) raise.Error!*Vector {
    var reader = pairs;
    var flat: scratch_vector.Vector(repr.Value) = .empty;
    defer scratch_vector.free(&flat);
    scratch_vector.ensure(&flat, 2 * reader.count);
    while (try reader.next()) |kv| {
        scratch_vector.push(&flat, kv.key);
        scratch_vector.push(&flat, kv.value);
    }
    const n = flat.items.len / 2;
    var built: scratch_vector.Vector(repr.Value) = .empty;
    defer scratch_vector.free(&built);
    scratch_vector.ensure(&built, n);
    for (0..n) |i| scratch_vector.push(&built, wrap.fromVector(fromSlice(flat.items[2 * i ..][0..2])));
    return fromSlice(built.items);
}

/// `vector`: a vector of the arguments.
fn nfunVector(argv: []repr.Value) raise.Error!repr.Value {
    return wrap.fromVector(fromSlice(argv));
}

/// Clears `own_editable` on `node` and on every node under it that has it set.
///
/// Every editable node's parent is editable, because a transient update makes
/// the whole path editable, so the walk stops at a node without the bit.
fn clearEditable(node: *abi.GCObject) void {
    if (!isEditable(node)) return;
    node.flags.own &= ~own_editable;
    if (gc_alloc.memoryTypeOf(node) != .vector_inner) return;
    for (asInner(node).children) |slot| {
        if (slot) |child| clearEditable(child);
    }
}

/// Allocates a copy of an inner node.
fn copyInner(node: *const Inner) *Inner {
    const copy = newInner();
    copy.children = node.children;
    return copy;
}

/// Allocates a copy of a leaf, of `capacity` elements.
///
/// `capacity` is at least the leaf's own, so that a copy made to be appended
/// to can be the larger block the append needs. The slots past the original's
/// elements are the nil `newLeaf` left.
fn copyLeaf(node: *Leaf, capacity: u32) *Leaf {
    std.debug.assert(capacity >= capacityOf(node));
    const copy = allocLeaf(capacity);
    fillLeaf(copy, items(node));
    return copy;
}

/// Returns the tail an append may write at `len`, which is the number of
/// elements it already holds.
///
/// A tail that is not full is `ownLeaf`'s answer, copied or not as `mode`
/// says. A full one is copied into a block of twice the capacity whatever the
/// mode, since a block cannot grow where it lies. Doubling from one reaches
/// `width` exactly, so a tail grafted into the trie is always `width` long,
/// and an append costs an amortised constant number of copied elements rather
/// than the whole `width` every time.
fn growTail(tail: *Leaf, len: u32, mode: Mode) *Leaf {
    if (len < capacityOf(tail)) return ownLeaf(tail, mode);
    std.debug.assert(len == capacityOf(tail) and capacityOf(tail) < width);
    const grown = copyLeaf(tail, capacityOf(tail) * 2);
    if (mode == .transient) grown.gc.flags.own |= own_editable;
    return grown;
}

/// Whether `node` has `own_editable` set.
inline fn isEditable(node: *const abi.GCObject) bool {
    return node.flags.own & own_editable != 0;
}

/// Returns the leaf in `v`'s trie that holds `index`, which is below the tail.
fn leafFor(v: *const Vector, index: usize) *Leaf {
    var node = v.root.?;
    var level: usize = v.shift;
    while (level > 0) : (level -= bits) {
        node = asInner(node).children[(index >> @as(Shift, @intCast(level))) & mask].?;
    }
    return asLeaf(node);
}

/// Allocates an inner node, editable where `mode` is `transient`.
fn newInnerFor(mode: Mode) *Inner {
    const node = newInner();
    if (mode == .transient) node.gc.flags.own |= own_editable;
    return node;
}

/// Allocates a leaf of `capacity` elements, editable where `mode` is
/// `transient`.
fn newLeafFor(capacity: u32, mode: Mode) *Leaf {
    const node = newLeaf(capacity);
    if (mode == .transient) node.gc.flags.own |= own_editable;
    return node;
}

/// Allocates an empty vector.
fn newVector() *Vector {
    const block = gc_alloc.gcalloc(Head, .vector);
    block.vector = .{};
    return &block.vector;
}

/// Allocates a vector whose tail of `capacity` elements is inside its own
/// block, and returns it with `tail` already pointing at that leaf.
fn newVectorInline(capacity: u32) *Vector {
    std.debug.assert(capacity >= 1 and capacity <= width);
    std.debug.assert(std.math.isPowerOfTwo(capacity));
    const size = inline_leaf_offset + @offsetOf(Leaf, "_items") + @sizeOf(repr.Value) * capacity;
    const block: *Head = @ptrCast(@alignCast(gc_alloc.gcallocBytes(.vector, size)));
    block.vector = .{};
    const leaf: *Leaf = @ptrCast(@alignCast(@as([*]u8, @ptrCast(block)) + inline_leaf_offset));
    leaf.gc = .{};
    const exponent: u6 = @intCast(std.math.log2_int(u32, capacity));
    leaf.gc.flags.own = (exponent << own_capacity_shift) | own_inline;
    block.vector.tail = leaf;
    return &block.vector;
}

/// Whether `leaf` lives inside a vector's head block.
pub inline fn isInline(leaf: *const Leaf) bool {
    return leaf.gc.flags.own & own_inline != 0;
}

/// Moves an inline tail into a block of its own, so that it may be grown,
/// grafted, or held by something that does not own the head it sits in.
///
/// Every path that does more than read a tail calls this first. The copy is an
/// ordinary leaf: `allocLeaf` starts from a zeroed header, so the flag does
/// not travel.
pub fn deinlineTail(v: *Vector) void {
    const tail = v.tail orelse return;
    if (!isInline(tail)) return;
    v.tail = copyLeaf(tail, capacityOf(tail));
}

/// Returns the inner node `node` or a copy of it, whichever an update in `mode`
/// may change.
fn ownInner(node: *abi.GCObject, mode: Mode) *Inner {
    return switch (mode) {
        .fresh => asInner(node),
        .persistent => copyInner(asInner(node)),
        .transient => if (isEditable(node)) asInner(node) else blk: {
            const copy = copyInner(asInner(node));
            copy.gc.flags.own |= own_editable;
            break :blk copy;
        },
    };
}

/// Returns the leaf `node` or a copy of it, whichever an update in `mode` may
/// change.
fn ownLeaf(node: *Leaf, mode: Mode) *Leaf {
    return switch (mode) {
        .fresh => node,
        .persistent => copyLeaf(node, capacityOf(node)),
        .transient => if (isEditable(&node.gc)) node else blk: {
            const copy = copyLeaf(node, capacityOf(node));
            copy.gc.flags.own |= own_editable;
            break :blk copy;
        },
    };
}

/// Grafts a full leaf into `v`'s trie, growing the root by a level where the
/// trie is full.
///
/// `leaf` becomes the last leaf of the trie, and `old_count` is the number of
/// elements up to and including it. `mode` says whether an inner node on the
/// path is copied before it changes.
fn pushLeaf(v: *Vector, leaf: *Leaf, old_count: usize, mode: Mode) void {
    std.debug.assert(capacityOf(leaf) == width);
    if (old_count == width) {
        v.root = &leaf.gc;
        return;
    }
    var root: *Inner = undefined;
    if ((old_count >> bits) > (@as(usize, 1) << @as(Shift, @intCast(v.shift)))) {
        root = newInnerFor(mode);
        root.children[0] = v.root;
        v.shift += bits;
    } else {
        root = ownInner(v.root.?, mode);
    }
    v.root = &root.gc;

    const index = old_count - width;
    var node = root;
    var level: usize = v.shift;
    while (level > bits) : (level -= bits) {
        const child_index = (index >> @as(Shift, @intCast(level))) & mask;
        const child = if (node.children[child_index]) |existing|
            ownInner(existing, mode)
        else
            newInnerFor(mode);
        node.children[child_index] = &child.gc;
        node = child;
    }
    node.children[(index >> bits) & mask] = &leaf.gc;
}

/// Replaces the element at `index` of `v` with `x`, treating the nodes on the
/// path as `mode` says. `index` is below `v.count`.
fn replaceIn(v: *Vector, index: usize, x: repr.Value, mode: Mode) void {
    const offset = tailOffset(v);
    var old: repr.Value = undefined;
    if (index >= offset) {
        const tail = ownLeaf(v.tail.?, mode);
        old = elements(tail)[index - offset];
        elements(tail)[index - offset] = x;
        v.tail = tail;
    } else {
        // Each node on the path is replaced in its parent by the node an
        // update in `mode` may change, from the root down.
        var level: usize = v.shift;
        var node = v.root.?;
        var slot: *?*abi.GCObject = &v.root;
        while (level > 0) : (level -= bits) {
            const inner = ownInner(node, mode);
            slot.* = &inner.gc;
            const child_index = (index >> @as(Shift, @intCast(level))) & mask;
            node = inner.children[child_index].?;
            slot = &inner.children[child_index];
        }
        const leaf = ownLeaf(asLeaf(node), mode);
        old = elements(leaf)[index & mask];
        elements(leaf)[index & mask] = x;
        slot.* = &leaf.gc;
    }
    v.sum = v.sum -% term(index, old) +% term(index, x);
}

/// The index of the first element in `v`'s tail.
inline fn tailOffset(v: *const Vector) usize {
    if (v.count == 0) return 0;
    return ((v.count - 1) >> bits) << bits;
}

/// The term the element `x` at `index` adds to a vector's `sum`.
///
/// Both halves go through a finalizer, so a term changes in every bit when the
/// index does. A term that was close to linear in the index would give a sum
/// that does not change when two elements trade places.
inline fn term(index: usize, x: repr.Value) u32 {
    const position = fmix32(@as(u32, @truncate(index)) +% 0x9e3779b9);
    return fmix32(@as(u32, @bitCast(order.hash(x))) ^ position);
}

// ==========================================================================
// Tests
// ==========================================================================

// A short vector's tail follows its `Head` in the same block, at
// `inline_leaf_offset`.
//
// The first two assertions are facts this file does not choose: that the
// compiler puts a leaf's elements at a multiple of their own alignment, as
// `maps.zig` asserts of a node's, and that `malloc` returns a block aligned
// for a leaf at all. The offset is measured from the block's base, and
// `gcallocBytes` promises only a `GCObject`'s alignment, which is four bytes
// where a pointer is four and below a leaf's eight.
//
// The last two are a regression guard. The current definition folds them to
// true, so they are worth their lines only because an edit to it would not:
// placing the leaf at `@sizeOf(Head)`, as this file did until 2026-09-19,
// fails them at compile time on every 32-bit target rather than trapping at
// run time on the one of the four that runs.
comptime {
    std.debug.assert(@offsetOf(Leaf, "_items") % @alignOf(repr.Value) == 0);
    std.debug.assert(@alignOf(Leaf) <= @alignOf(std.c.max_align_t));
    std.debug.assert(inline_leaf_offset >= @sizeOf(Head));
    std.debug.assert(inline_leaf_offset % @alignOf(Leaf) == 0);
}
