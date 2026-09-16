//! `core/vector`: the persistent vector, a trie of 32-way nodes with a tail.
//!
//! A vector is an abstract whose payload is a `Vector`. `vector_type` is the
//! abstract type, `lib` installs `vector`, `vec`, `conj` and `assoc`, and
//! `at` reads one element. A Janet program reads a vector as it reads a
//! tuple, through `chunk`: the runtime derives `get` and `next` from it, and
//! every site that reads an indexed value accepts one.
//!
//! A vector's nodes are collector blocks of their own memory types. An
//! _inner node_ is a `vector_inner` block and has 32 child pointers. A _leaf_
//! is a `vector_leaf` block and has 32 elements. `newInner` and `newLeaf`
//! allocate them. `gc/mark.zig`'s `markNode` marks a node and everything under
//! it, and `gc/sweep.zig` frees an unreachable node with no finalizer.
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
//!   new one share every other node. A node a transient made has
//!   `own_editable` set, and only such a node is changed in place. Building a
//!   vector from a slice changes the nodes it has just allocated, before any
//!   vector refers to them.
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

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const abstract_type = @import("../../api/abstract_type.zig");
const abstracts = @import("abstracts.zig");
const args_core = @import("../args.zig");
const buffers = @import("buffers.zig");
const corefn = @import("../corefn.zig");
const gc_alloc = @import("../gc.zig");
const gc_mark = @import("../gc/mark.zig");
const order = @import("helpers/order.zig");
const pp = @import("../pp.zig");
const pp_format = @import("../pp/format.zig");
const raise = @import("../../api/raise.zig");
const registry = @import("../registry.zig");
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

/// The abstract type a vector is.
pub const vector_type = abstract_type.define(Vector, .{
    .name = "core/vector",
    .gcmark = vectorMark,
    .length = vectorLength,
    .hash = vectorHash,
    .tostring = vectorTostring,
    .chunk = vectorChunk,
});

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

/// A vector's payload.
///
/// `count` is the number of elements. `root` is the trie and `shift` the bit
/// position its child index is read from, as the file header describes.
/// `tail` is the leaf holding the last elements, and is null only when `count`
/// is zero. `sum` is the running sum the hash is made from.
pub const Vector = struct {
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
    const offset = tailOffset(src);
    var old: repr.Value = undefined;
    if (index >= offset) {
        const tail = copyLeaf(src.tail.?);
        old = tail.items[index - offset];
        tail.items[index - offset] = x;
        dest.tail = tail;
    } else {
        // Copy the path from the root down, replacing each child with its copy.
        var level: usize = src.shift;
        var node = src.root.?;
        var slot: *?*abi.GCObject = &dest.root;
        while (level > 0) : (level -= bits) {
            const copy = copyInner(asInner(node));
            slot.* = &copy.gc;
            const child_index = (index >> @as(Shift, @intCast(level))) & mask;
            node = copy.children[child_index].?;
            slot = &copy.children[child_index];
        }
        const leaf = copyLeaf(asLeaf(node));
        old = leaf.items[index & mask];
        leaf.items[index & mask] = x;
        slot.* = &leaf.gc;
    }
    dest.sum = src.sum -% term(index, old) +% term(index, x);
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

/// Returns a new vector equal to `src` with `x` appended.
///
/// This function cannot raise. The new vector shares every node with `src`
/// except the tail and, where the tail was full, the path to where it moved.
pub fn conj(src: *const Vector, x: repr.Value) *Vector {
    const dest = newVector();
    dest.* = src.*;
    const tail_count = src.count - tailOffset(src);
    const tail = if (tail_count == 0 or tail_count == width) newLeaf() else copyLeaf(src.tail.?);
    if (tail_count == width) pushLeaf(dest, src.tail.?, src.count, true);
    tail.items[tail_count % width] = x;
    dest.tail = tail;
    dest.count = src.count + 1;
    dest.sum = src.sum +% term(src.count, x);
    return dest;
}

/// Returns a new vector of the elements of `xs`.
///
/// This function cannot raise. `xs` must stay valid while the vector is built,
/// which no allocation this makes can change. The full leaves are grafted into a trie no vector refers to yet, so the
/// graft changes the nodes it reaches rather than copying them.
pub fn fromSlice(xs: []const repr.Value) *Vector {
    const v = newVector();
    const n = xs.len;
    if (n == 0) return v;
    const trie_len = ((n - 1) >> bits) << bits;
    var start: usize = 0;
    while (start < trie_len) : (start += width) {
        const leaf = newLeaf();
        leaf.items = xs[start..][0..width].*;
        pushLeaf(v, leaf, start + width, false);
    }
    const tail = newLeaf();
    @memcpy(tail.items[0 .. n - trie_len], xs[trie_len..]);
    v.tail = tail;
    v.count = n;
    for (xs, 0..) |x, index| v.sum +%= term(index, x);
    return v;
}

/// Installs `vector`, `vec`, `conj` and `assoc` into the core environment and
/// registers `core/vector`.
///
/// `env` is the environment. This function raises if the registration does.
pub fn lib(env: *tables.Table) raise.Error!void {
    const entries = comptime [_]corefn.Entry{
        corefn.reg("vector", &cfunVector, @src(), "(vector & xs)", "Create a new persistent vector containing the elements xs."),
        corefn.reg("vec", &cfunVec, @src(), "(vec ind)", "Create a persistent vector with the elements of the indexed value `ind`. A vector is returned unchanged."),
        corefn.reg("conj", &cfunConj, @src(), "(conj coll & xs)", "Return a new collection with the elements xs added to `coll`. For a vector, the elements are added at the end."),
        corefn.reg("assoc", &cfunAssoc, @src(), "(assoc coll key val & kvs)", "Return a new collection in which each key is associated with the value that follows it. For a vector, a key is an index from 0 up to the length, and a key equal to the length adds the value at the end."),
    };
    corefn.install(env, entries);
    try registry.registerAbstractType(&vector_type);
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

/// Returns the payload of a vector's abstract header.
///
/// This function cannot raise. `head` must be the header of a `core/vector`,
/// and any other header is illegal behaviour.
pub fn ofHead(head: *const abi.GCObject) *const Vector {
    const abstract_head: *const abi.AbstractHead = @alignCast(@fieldParentPtr("gc", head));
    std.debug.assert(abstract_head.type == &vector_type);
    return @ptrCast(@alignCast(abstracts.data(abstract_head)));
}

/// Returns the payload of `x` if `x` is a vector, and null otherwise.
pub fn toVector(x: repr.Value) ?*Vector {
    if (!repr.checkType(x, repr.Tag.abstract)) return null;
    const payload = wrap.toAbstract(x);
    if (abi.abstractHead(payload).type != &vector_type) return null;
    return @ptrCast(@alignCast(payload));
}

// ==========================================================================
// Private functions
// ==========================================================================

/// `assoc`: a new vector with each key's element replaced, or appended where
/// the key is the length.
fn cfunAssoc(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 3, -1);
    if (argv.len % 2 == 0) return pp_format.panicf("expected an even number of keys and values, got %d", .{@as(i32, @intCast(argv.len - 1))});
    var v = try args_core.getAbstract(Vector, argv, 0, &vector_type);
    var i: usize = 1;
    while (i < argv.len) : (i += 2) {
        const index = try args_core.getSize(argv, i);
        if (index > v.count) {
            return pp_format.panicf("index %u out of range for vector of length %u", .{ @as(u64, index), @as(u64, v.count) });
        }
        v = if (index == v.count) conj(v, argv[i + 1]) else assoc(v, index, argv[i + 1]);
    }
    return wrap.fromAbstract(v);
}

/// `conj`: a new vector with the elements appended.
fn cfunConj(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, -1);
    var v = try args_core.getAbstract(Vector, argv, 0, &vector_type);
    for (argv[1..]) |x| v = conj(v, x);
    return wrap.fromAbstract(v);
}

/// `vec`: a vector of an indexed value's elements.
fn cfunVec(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    if (toVector(argv[0]) != null) return argv[0];
    // Gathered rather than read a run at a time, because building allocates
    // and a run does not survive an allocation.
    var gathered = try args_core.gatherArg(argv, 0);
    const v = fromSlice(gathered.items);
    gathered.free();
    return wrap.fromAbstract(v);
}

/// `vector`: a vector of the arguments.
fn cfunVector(argv: []repr.Value) raise.Error!repr.Value {
    return wrap.fromAbstract(fromSlice(argv));
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

/// The finalizer from 32-bit MurmurHash3, used on its own as an integer mixer.
fn fmix32(h_in: u32) u32 {
    var h = h_in;
    h ^= h >> 16;
    h *%= 0x85ebca6b;
    h ^= h >> 13;
    h *%= 0xc2b2ae35;
    h ^= h >> 16;
    return h;
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

/// Allocates an empty vector.
fn newVector() *Vector {
    const payload: *Vector = @ptrCast(@alignCast(abstracts.newBytes(&vector_type, @sizeOf(Vector))));
    payload.* = .{};
    return payload;
}

/// Grafts a full leaf into `v`'s trie, growing the root by a level where the
/// trie is full.
///
/// `leaf` becomes the last leaf of the trie, and `old_count` is the number of
/// elements up to and including it. Where `copy` is true, every inner node on
/// the path is copied before it changes. Where it is false, the path's nodes
/// belong to a vector nothing else refers to and change in place.
fn pushLeaf(v: *Vector, leaf: *Leaf, old_count: usize, copy: bool) void {
    if (old_count == width) {
        v.root = &leaf.gc;
        return;
    }
    var root: *Inner = undefined;
    if ((old_count >> bits) > (@as(usize, 1) << @as(Shift, @intCast(v.shift)))) {
        root = newInner();
        root.children[0] = v.root;
        v.shift += bits;
    } else {
        root = if (copy) copyInner(asInner(v.root.?)) else asInner(v.root.?);
    }
    v.root = &root.gc;

    const index = old_count - width;
    var node = root;
    var level: usize = v.shift;
    while (level > bits) : (level -= bits) {
        const child_index = (index >> @as(Shift, @intCast(level))) & mask;
        const child = if (node.children[child_index]) |existing|
            (if (copy) copyInner(asInner(existing)) else asInner(existing))
        else
            newInner();
        node.children[child_index] = &child.gc;
        node = child;
    }
    node.children[(index >> bits) & mask] = &leaf.gc;
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

/// `core/vector`'s `chunk` callback: the leaf or the tail that holds `index`.
fn vectorChunk(v: *Vector, index: usize) abstract_type.Chunk {
    const offset = tailOffset(v);
    if (index >= offset) return .{ .items = v.tail.?.items[0 .. v.count - offset], .start = offset };
    return .{ .items = &leafFor(v, index).items, .start = index & ~mask };
}

/// `core/vector`'s `hash` callback: the length mixed with the running sum.
fn vectorHash(v: *const Vector, _: usize) i32 {
    return @bitCast(value.hashMix(@truncate(v.count), v.sum));
}

/// `core/vector`'s `length` callback.
fn vectorLength(v: *Vector, _: usize) raise.Error!usize {
    return v.count;
}

/// `core/vector`'s `gcmark` callback: the trie and the tail.
fn vectorMark(v: *Vector, _: usize) void {
    if (v.root) |root| gc_mark.markNode(root);
    if (v.tail) |tail| gc_mark.markNode(&tail.gc);
}

/// `core/vector`'s `tostring` callback: each element described, separated by
/// spaces.
fn vectorTostring(v: *Vector, render: *abi.Render) raise.Error!void {
    const buffer: *buffers.Buffer = @ptrCast(@alignCast(render));
    // The runs are nodes, which do not change, so a run stays valid across the
    // allocations and callbacks describing an element can make.
    var index: usize = 0;
    while (index < v.count) {
        const run = vectorChunk(v, index);
        for (run.items) |x| {
            if (index > 0) try buffers.pushU8(buffer, ' ');
            try pp.descriptionB(buffer, x);
            index += 1;
        }
    }
}
