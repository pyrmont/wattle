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
//! is a `vector_leaf` block and has 32 elements. `newInner` and `newLeaf`
//! allocate them. `gc/mark.zig`'s `markNode` marks a node and everything under
//! it, and `gc/sweep.zig` frees an unreachable node with no finalizer. A
//! `vector` block owns nothing outside itself either.
//!
//! ## The shape of a vector
//!
//! The last one to 32 elements are in the _tail_, a leaf the payload points at
//! directly. The rest are in the trie under `root`, in full leaves. While a
//! vector has 32 elements or fewer, `root` is null. When the trie has one
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
//!   all 32 slots, because a node does not record how many are in use.
//!
//! - A node is not changed once a vector refers to it. An update copies the
//!   path from the root to the element it changes, so the old vector and the
//!   new one share every other node. Two updates change nodes in place: a
//!   transient's, on the nodes it made, and building a vector from a slice,
//!   on nodes no vector refers to yet.
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
//!   transient is made only from a vector and `persistent!` ends it.
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
const tables = @import("tables.zig");
const value = @import("../value.zig");
const wrap = @import("helpers/wrap.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// The number of bits of an index one level of the trie consumes.
const bits = 5;

/// The low `bits` bits of an index: the slot within one node.
const mask: usize = width - 1;

/// Bit 0 of the collector header's per-type field: a transient made the node
/// and may change it in place.
pub const own_editable: u6 = 1;

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

/// A vector's leaf: the collector's object and 32 elements.
///
/// `newLeaf` returns a `Leaf`. `items` holds the elements, with nil in each
/// unused slot.
pub const Leaf = extern struct {
    gc: abi.GCObject = .{},
    items: [width]repr.Value,
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
    if (index >= offset) return v.tail.?.items[index - offset];
    return leafFor(v, index).items[index & mask];
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
    if (index >= offset) return .{ .items = &v.tail.?.items, .len = v.count - offset, .start = offset };
    return .{ .items = &leafFor(v, index).items, .len = width, .start = index & ~mask };
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
    const v = newVector();
    const n = xs.len;
    if (n == 0) return v;
    const trie_len = ((n - 1) >> bits) << bits;
    var start: usize = 0;
    while (start < trie_len) : (start += width) {
        const leaf = newLeaf();
        leaf.items = xs[start..][0..width].*;
        pushLeaf(v, leaf, start + width, .fresh);
    }
    const tail = newLeaf();
    @memcpy(tail.items[0 .. n - trie_len], xs[trie_len..]);
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
        corefn.reg("vector", &cfunVector, @src(), "(vector & xs)", "Create a new persistent vector containing the elements xs."),
        corefn.reg("vec", &cfunVec, @src(), "(vec ind)", "Create a persistent vector with the elements of the indexed value `ind`. A vector is returned unchanged."),
        corefn.reg("conj", &cfunConj, @src(), "(conj coll & xs)", "Return a new collection with the elements xs added to `coll`, a vector or a set. For a vector, the elements are added at the end."),
        corefn.reg("assoc", &cfunAssoc, @src(), "(assoc coll key val & kvs)", "Return a new collection in which each key is associated with the value that follows it, in the vector or map `coll`. For a vector, a key is an index from 0 up to the length, and a key equal to the length adds the value at the end. For a map, a nil value removes the key."),
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
    if (v.tail) |tail| gc_mark.markNode(&tail.gc);
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

/// Allocates a leaf with every element nil.
///
/// This function cannot raise. The leaf is unreachable until the caller stores
/// it where the mark phase finds it, so the next collection frees a leaf the
/// caller has not stored.
pub fn newLeaf() *Leaf {
    const node = gc_alloc.gcalloc(Leaf, .vector_leaf);
    node.items = @splat(wrap.fromNil());
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
    const tail_count = v.count - tailOffset(v);
    if (tail_count == width) {
        pushLeaf(v, v.tail.?, v.count, mode);
        v.tail = newLeafFor(mode);
    } else if (tail_count == 0) {
        v.tail = newLeafFor(mode);
    } else {
        v.tail = ownLeaf(v.tail.?, mode);
    }
    v.tail.?.items[tail_count % width] = x;
    v.sum +%= term(v.count, x);
    v.count += 1;
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
fn cfunAssoc(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 3, -1);
    if (maps.toTree(argv[0], .map) != null) return maps.assocMap(argv);
    var v = toVector(argv[0]) orelse
        return pp_format.panicf("bad slot #0, expected vector or core/map, got %v", .{argv[0]});
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
fn cfunConj(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, -1);
    if (maps.toTree(argv[0], .set) != null) return maps.conjSet(argv);
    var v = toVector(argv[0]) orelse
        return pp_format.panicf("bad slot #0, expected vector or core/set, got %v", .{argv[0]});
    for (argv[1..]) |x| v = conj(v, x);
    return wrap.fromVector(v);
}

/// `vec`: a vector of an indexed value's elements.
fn cfunVec(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    if (repr.checkType(argv[0], .vector)) return argv[0];
    // Gathered rather than read a run at a time, because building allocates
    // and a run does not survive an allocation.
    var gathered = try args_core.gatherArg(argv, 0);
    const v = fromSlice(gathered.items);
    gathered.free();
    return wrap.fromVector(v);
}

/// `vector`: a vector of the arguments.
fn cfunVector(argv: []repr.Value) raise.Error!repr.Value {
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

/// Allocates a copy of a leaf.
fn copyLeaf(node: *const Leaf) *Leaf {
    const copy = newLeaf();
    copy.items = node.items;
    return copy;
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

/// Allocates a leaf, editable where `mode` is `transient`.
fn newLeafFor(mode: Mode) *Leaf {
    const node = newLeaf();
    if (mode == .transient) node.gc.flags.own |= own_editable;
    return node;
}

/// Allocates an empty vector.
fn newVector() *Vector {
    const block = gc_alloc.gcalloc(Head, .vector);
    block.vector = .{};
    return &block.vector;
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
        .persistent => copyLeaf(node),
        .transient => if (isEditable(&node.gc)) node else blk: {
            const copy = copyLeaf(node);
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
        old = tail.items[index - offset];
        tail.items[index - offset] = x;
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
        old = leaf.items[index & mask];
        leaf.items[index & mask] = x;
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
