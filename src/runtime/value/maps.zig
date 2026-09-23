//! The map and `core/set`: the persistent map and the persistent set, both
//! a B-tree ordered by the hash of each key.
//!
//! A map and a set are one file because they are one structure. A map's entry
//! is a key and its value, and a set's is an element alone, and nothing else
//! about the tree differs. `Kind` says which a node or a payload belongs to.
//! A map is a built-in type: its value points at a `Head`, a `map` block
//! holding the collector's object and a `Tree`. A set is the abstract type
//! `set_type`, with a `Tree` as its payload. `lib` installs `hash-map`,
//! `hash-set`, `dissoc` and `disj`. `vectors.zig`'s `conj` and `assoc` reach a
//! set and a map through `conjSet` and `assocMap`.
//!
//! A tree's nodes are collector blocks of their own memory types. A map's
//! node is a `map_node` block, and a set's node is a `set_node` block.
//! `newLeaf` and `newInner` allocate them. `gc/mark.zig`'s `markNode` marks a
//! node and everything under it through `entries` and `children`, and
//! `gc/sweep.zig` frees an unreachable node with no finalizer.
//!
//! ## The order of entries
//!
//! A key's _place hash_ is its hash passed through `vectors.fmix32`. Entries
//! are ordered by place hash, and entries whose keys share a place hash by
//! `order.compare` on the keys. The order depends only on the entries, so two
//! collections with equal entries give them in one order however they were
//! built. The shape of the tree does not, and nothing reads it.
//!
//! ## The shape of a node
//!
//! A node begins with its `GCObject` and `len`. A _leaf_ holds `len` entries,
//! each as many values as its kind says, and then their `len` place hashes.
//! An _inner node_ has `own_inner` set and holds `len` children, then a
//! separator for each child, then the number of entries under each child.
//! These rules hold for every node:
//!
//! - A node is one block, sized when it is allocated. Its `len` does not
//!   change, so adding or removing an entry or a child allocates a new node.
//!
//! - Every slot of a node holds a valid entry or child from allocation onwards.
//!   An entry is nil and a child is null until the caller stores one. The mark
//!   phase reads every slot.
//!
//! - A node is not changed once a persistent collection refers to it. An
//!   update copies the path from the root to the leaf it changes. A transient's
//!   update changes in place the nodes with `own_editable` set.
//!
//! ## The shape of a tree
//!
//! - Every leaf is at the same depth, and no node is empty. A root that is an
//!   inner node has at least two children.
//!
//! - Every place hash under a child is at least the child's separator and
//!   below the next child's. A child's separator is a boundary rather than the
//!   least hash under it, so a removal need not update it.
//!
//! - Entries whose keys share a place hash are in one leaf. A leaf holds at
//!   most `leaf_max` entries, except a leaf whose entries all share one place
//!   hash. An inner node holds at most `inner_max` children.
//!
//! - A node left with fewer than `merge_below` entries or children by a
//!   removal is merged with a neighbour where the two fit in one node.
//!
//! ## Updating a tree in place
//!
//! `transients.zig`'s transient holds a `Tree` and updates it through
//! `transientPut` and `transientRemove`, and `persistent` makes a map or a set
//! of it. These rules make that safe:
//!
//! - A transient update sets `own_editable` on every node it makes, and
//!   changes a node in place only where the bit is set. A node a transient
//!   made is reachable from that transient and from nothing else.
//!
//! - An update makes the whole path from the root editable, so every editable
//!   node's parent is editable. `persistent` clears the bits by walking down
//!   through set bits only.
//!
//! `assoc`, `conj`, `dissoc` and `disj` make their changes the same way on a
//! copy of the payload, and clear the bits before returning the collection.
//!
//! ## Keys and values
//!
//! A key is never nil or NaN. Nil is where `next` starts and ends, and NaN is
//! not equal to itself, so neither could be found again. Storing one raises,
//! and looking one up finds nothing. A map never holds a nil value: storing
//! one removes the key, as in a table.
//!
//! A lookup that finds nothing gives nil, through `get` and `in` alike. A
//! set's lookup gives the element itself, so `each`, `keys` and `values` all
//! give a set's elements.
//!
//! ## Runs
//!
//! A map's contents are `pairs`, and `chunkAt` hands out a leaf's entries as
//! they are stored, a key then its value, with no copy. A leaf's first pair is
//! at the number of entries before it, found from the inner nodes' counts, so
//! its run starts at twice that. `args.zig`'s pair reader has a map source
//! that calls it, where a set has no runs at all: its entry is one value, not
//! a pair.
//!
//! ## The cursor
//!
//! A payload records the leaf and index of the entry `next` last gave. `next`
//! and `get` given that entry's key, bit for bit, start from the cursor rather
//! than the root. A payload made from another's contents starts with no
//! cursor, because its tree may differ.
//!
//! ## Equality, order and hash
//!
//! Two maps, or two sets, are equal when their counts, their hashes and their
//! entries in order are equal. They order by count, then by hash, then by the
//! first difference in their entries in order. `valueAt` reads an entry by
//! position through the counts in inner nodes. A collection's hash is kept
//! current rather than computed when asked: `sum` is the wrapping sum of one
//! term per entry, and a term does not depend on where the entry is.
//!
//! ## Marshalling
//!
//! A map is written under its own lead byte, and a set through the abstract
//! it is. Each is its count and then its entries in order: a key and then its
//! value for a map, and an element for a set. Reading back gathers the entries
//! and builds the tree as `hash-map` does, under its rules: a nil or NaN key
//! raises, a nil value removes its key, and a repeated key replaces the
//! earlier entry.
//!
//! A map or a set enters the marshaller's reference table after its entries,
//! as a vector does and for the reason `vectors.zig` gives: its hash depends
//! on its entries.

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
const fatal = @import("../fatal.zig");
const gc_alloc = @import("../gc.zig");
const gc_mark = @import("../gc/mark.zig");
const marsh = @import("../marsh.zig");
const order = @import("helpers/order.zig");
const pp = @import("../pp.zig");
const pp_format = @import("../pp/format.zig");
const raise = @import("../../api/raise.zig");
const registry = @import("../registry.zig");
const repr = @import("repr");
const scratch_vector = @import("../scratch_vector.zig");
const tables = @import("tables.zig");
const utils = @import("../utils.zig");
const value = @import("../value.zig");
const vectors = @import("vectors.zig");
const wrap = @import("helpers/wrap.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// The number of entries `build` places without allocating its scratch arrays.
const build_stack = 64;

/// The most children an inner node holds.
pub const inner_max = 32;

/// The length at or below which `sortByHash` sorts by insertion rather than
/// by partitioning.
const insertion_sort_max = 12;

/// The most entries a leaf holds, unless every entry shares one place hash.
pub const leaf_max = 32;

/// The length below which a node a removal changed merges with a neighbour.
pub const merge_below = 8;

/// Bit 0 of the collector header's per-type field: a transient made the node
/// and may change it in place.
pub const own_editable: u6 = 1;

/// Bit 1 of the collector header's per-type field: the node is an inner node.
pub const own_inner: u6 = 2;

/// The abstract type a set is.
///
/// A map has no abstract type: it is a built-in, read through its tag.
pub const set_type = abstract_type.define(Tree, .{
    .name = "core/set",
    .gcmark = treeMark,
    .get = setGet,
    .next = setNext,
    .length = treeLength,
    .hash = treeHash,
    .tostring = describeTree,
    .marshal = treeMarshal,
    .unmarshal = setUnmarshal,
});

/// The `hash-set` nfunction as the registry stores it, for the compiler's set
/// literal arm.
///
/// A set literal is built by calling this through a constant slot rather than
/// by an opcode, so `#{}` resolves no name and rebinding `hash-set` does not
/// change what it builds. `notes/LANGUAGE.md` decided against a `make_set` on
/// 2026-09-18: the opcode would buy the few percent a literal saves over a
/// call, and cost four tables to keep in step for a form nothing yet uses.
pub const hash_set_nfunction = raise.stored(&nfunHashSet);

// ==========================================================================
// Types
// ==========================================================================

/// What an update did, which the caller needs to keep `count` and `sum`
/// current.
///
/// `added` says an entry was added, `replaced` is the value a map entry had
/// before an update replaced it, and `removed` says an entry was removed, with
/// its values in `gone`.
const Change = struct {
    added: bool = false,
    replaced: ?repr.Value = null,
    removed: bool = false,
    gone: [2]repr.Value = undefined,
};

/// The order `keepLast` sorts a run of one place hash by: `order.compare` on
/// the keys in `values`, which are `w` values an entry.
const KeyOrder = struct {
    values: []const repr.Value,
    w: usize,

    fn lessThan(ctx: KeyOrder, a: Placed, b: Placed) bool {
        return order.compare(ctx.values[a.at * ctx.w], ctx.values[b.at * ctx.w]) < 0;
    }
};

/// Which collection a node or a payload belongs to, which decides its memory
/// type and how many values an entry is.
pub const Kind = enum {
    map,
    set,

    /// The number of values in one entry: a key and its value for a map, and
    /// an element for a set.
    pub fn entryWidth(kind: Kind) usize {
        return switch (kind) {
            .map => 2,
            .set => 1,
        };
    }

    /// The memory type of a node of this kind.
    pub fn memoryType(kind: Kind) gc_alloc.MemoryType {
        return switch (kind) {
            .map => .map_node,
            .set => .set_node,
        };
    }
};

/// How an update treats the nodes on the path it changes.
///
/// `persistent` copies every node it changes, for a collection that others
/// may share. `transient` changes a node with `own_editable` set in place, and
/// copies any other with the bit set on the copy. In both modes, a node whose
/// length changes is a new node.
const Mode = enum { persistent, transient };

/// A map's block: the collector's object and the payload.
///
/// A map's value points at its `Head`, and `ofHead` and `wrap.toMap` return
/// the `Tree` inside it. A set has no `Head`: its payload is an abstract's.
pub const Head = extern struct {
    gc: abi.GCObject = .{},
    tree: Tree = .{},
};

/// A node header: the collector's object and the node's length.
///
/// `newLeaf` and `newInner` return a `Node`. `len` is the number of entries in
/// a leaf and of children in an inner node. `entries`, `hashes`, `children`,
/// `separators` and `counts` return the slots that follow the header.
pub const Node = extern struct {
    gc: abi.GCObject = .{},
    len: u32 = 0,
    reserved: u32 = 0,
    _items: [0]repr.Value = .{},
};

/// An entry's place in a tree: the leaf holding it and its index among the
/// leaf's entries.
const Place = struct {
    node: *Node,
    index: u32,
};

/// An entry's place in a `build`: the key's place hash and the entry's index
/// in the values `build` was given.
const Placed = struct {
    hash: u32,
    at: u32,
};

/// The nodes that take a node's place after an update: none where the node is
/// left empty, one, or two where it split.
const Replaced = struct {
    nodes: [2]*Node = undefined,
    len: usize,

    fn one(node: *Node) Replaced {
        return .{ .nodes = .{ node, undefined }, .len = 1 };
    }
};

/// What `seekAfter` found: the key absent from a subtree, the place of the
/// entry after the key, or the key as the last entry of the subtree.
const Seek = union(enum) {
    absent,
    found: Place,
    last,
};

/// A map's or a set's payload.
///
/// `count` is the number of entries and `root` the tree, null only when
/// `count` is zero. `sum` is the running sum the hash is made from. `cursor`
/// is the leaf holding the entry `next` last gave and `cursor_index` that
/// entry's index in it, or `cursor` is null.
///
/// `extern` because `Head` is.
pub const Tree = extern struct {
    count: usize = 0,
    root: ?*Node = null,
    sum: u32 = 0,
    cursor_index: u32 = 0,
    cursor: ?*Node = null,
};

// ==========================================================================
// Public functions
// ==========================================================================

/// Returns a node header as the node it begins.
///
/// This function cannot raise. `header` must be the header of a `map_node` or
/// `set_node` block, and any other header is illegal behaviour.
pub inline fn asNode(header: *abi.GCObject) *Node {
    std.debug.assert(kindOf(header) != null);
    return @alignCast(@fieldParentPtr("gc", header));
}

/// Builds a map from `kvs`, which is what `module.mapOf` reaches through
/// `capi.zig`'s `new_map`.
///
/// The pairs are the caller's own, not a dictionary's hash array. A repeated
/// key takes the last value and a nil value drops its pair, as `hash-map`
/// does, because `build` is what both go through.
///
/// A pair whose key a map cannot store is dropped rather than refused: the
/// crossing is `callconv(.c)` and has no way to raise, so the choice is
/// between dropping the pair and building a map that `next` cannot walk.
pub fn buildPairs(kvs: []const abi.Keyval) *Tree {
    var values: scratch_vector.Vector(repr.Value) = .empty;
    for (kvs) |kv| {
        if (!storableKey(kv.key)) continue;
        scratch_vector.push(&values, kv.key);
        scratch_vector.push(&values, kv.value);
    }
    const t = build(.map, values.items);
    scratch_vector.free(&values);
    return t;
}

/// `assoc` for a map: a new map with each key in `argv` associated with the
/// value after it.
///
/// `argv` is a frame whose first argument is a map and the rest keys and
/// values. A nil value removes its key. This function raises if a key has no
/// value, or if a key is nil or NaN.
pub fn assocMap(argv: []const repr.Value) raise.Error!repr.Value {
    const src = toTree(argv[0], .map).?;
    try vectors.checkPairs(argv);
    var i: usize = 1;
    while (i < argv.len) : (i += 2) try checkKey(argv[i]);
    var built = copyTree(src);
    i = 1;
    while (i < argv.len) : (i += 2) {
        if (repr.checkType(argv[i + 1], repr.Tag.nil)) {
            removeKey(&built, .map, argv[i], .transient);
        } else {
            putEntry(&built, .map, argv[i..][0..2], .transient);
        }
    }
    return result(argv[0], src, built, .map);
}

/// Returns a new collection of `kind` with the entries in `values`, each as
/// many values as `kind` says, the key first.
///
/// This function cannot raise. Every key must already have passed `checkKey`,
/// and a key that has not is illegal behaviour. A later entry with a key
/// replaces an earlier one, and a map entry whose value is nil removes its key.
pub fn build(kind: Kind, values: []const repr.Value) *Tree {
    return newTree(kind, buildContents(kind, values));
}

/// Refuses a key that cannot be stored: nil, which is where `next` starts and
/// ends, and NaN, which is not equal to itself.
///
/// This function raises if `key` is nil or NaN.
pub fn checkKey(key: repr.Value) raise.Error!void {
    if (!storableKey(key)) return pp_format.panicf("cannot use %v as a key", .{key});
}

/// Returns the child slots of `node`: `len` of them for an inner node, and
/// none for a leaf.
///
/// This function cannot raise.
pub fn children(node: *Node) []?*abi.GCObject {
    const many: [*]?*abi.GCObject = @ptrCast(@alignCast(&node._items));
    return many[0..if (isInner(node)) node.len else 0];
}

/// `conj` for a set: a new set with each element in `argv` added.
///
/// `argv` is a frame whose first argument is a set and the rest elements. This
/// function raises if an element is nil or NaN.
pub fn conjSet(argv: []const repr.Value) raise.Error!repr.Value {
    const src = toTree(argv[0], .set).?;
    for (argv[1..]) |x| try checkKey(x);
    var built = copyTree(src);
    for (argv[1..]) |x| putEntry(&built, .set, &.{x}, .transient);
    return result(argv[0], src, built, .set);
}

/// Returns a copy of `t` to update, with no cursor.
///
/// This function cannot raise.
pub fn copyTree(t: *const Tree) Tree {
    var copy = t.*;
    copy.cursor = null;
    copy.cursor_index = 0;
    return copy;
}

/// Returns the number of entries under each child of the inner node `node`.
///
/// This function cannot raise. `node` must be an inner node.
pub fn counts(node: *Node) []u32 {
    std.debug.assert(isInner(node));
    const base = @intFromPtr(&node._items) + node.len * (@sizeOf(?*abi.GCObject) + @sizeOf(u32));
    const many: [*]u32 = @ptrFromInt(base);
    return many[0..node.len];
}

/// Returns the entry slots of `node`: `len` entries, each as many values as
/// the node's kind says, for a leaf, and none for an inner node.
///
/// This function cannot raise.
pub fn entries(node: *Node) []repr.Value {
    const many: [*]repr.Value = @ptrCast(&node._items);
    if (isInner(node)) return many[0..0];
    return many[0 .. node.len * kindOfNode(node).entryWidth()];
}

/// Returns the entry of `t` whose key equals `key`, or null.
///
/// This function cannot raise. The entry is as many values as `kind` says,
/// the key first. A nil or NaN key finds nothing, since neither is stored.
pub fn find(t: *const Tree, kind: Kind, key: repr.Value) ?[]repr.Value {
    var node = t.root orelse return null;
    const hash = placeHash(key);
    while (isInner(node)) node = childAt(node, route(node, hash));
    const w = kind.entryWidth();
    const i = indexIn(w, node, hash, key) orelse return null;
    return leafEntries(node, w)[i * w ..][0..w];
}

/// A collection's hash: its count mixed with the running sum of its entries.
///
/// This function cannot raise. It is named with `Of` because `hash` is what
/// every function here calls a place hash.
pub fn hashOf(t: *const Tree) i32 {
    return @bitCast(value.hashMix(@truncate(t.count), t.sum));
}

/// Returns the place hashes of the leaf `node`, one for each entry.
///
/// This function cannot raise. `node` must be a leaf.
pub fn hashes(node: *Node) []u32 {
    std.debug.assert(!isInner(node));
    const base = @intFromPtr(&node._items) + node.len * kindOfNode(node).entryWidth() * @sizeOf(repr.Value);
    const many: [*]u32 = @ptrFromInt(base);
    return many[0..node.len];
}

/// Returns whether `node` is an inner node.
///
/// This function cannot raise.
pub inline fn isInner(node: *const Node) bool {
    return node.gc.flags.own & own_inner != 0;
}

/// Returns the kind of the node `header` begins, or null if it is not a tree
/// node.
///
/// This function cannot raise.
pub fn kindOf(header: *const abi.GCObject) ?Kind {
    return switch (gc_alloc.memoryTypeOf(header)) {
        .map_node => .map,
        .set_node => .set,
        else => null,
    };
}

/// Installs `hash-map`, `hash-set`, `dissoc` and `disj` into the core
/// environment and registers `core/set`.
///
/// `env` is the environment. This function raises if a registration does.
pub fn lib(env: *tables.Table) raise.Error!void {
    const bindings = comptime [_]corefn.Entry{
        corefn.reg("hash-map", &nfunHashMap, @src(), "(hash-map & kvs)", "Create a new persistent map from alternating keys and values. The pairs are added in order, so a later value for a key replaces an earlier one, and a nil value removes its key. A key cannot be nil or NaN."),
        corefn.reg("hash-set", &nfunHashSet, @src(), "(hash-set & xs)", "Create a new persistent set containing the elements xs. An element cannot be nil or NaN."),
        corefn.reg("map/to-table", &nfunMapTotable, @src(), "(map/to-table m)", "Convert a map to a table. Returns a new table."),
        corefn.reg("dissoc", &nfunDissoc, @src(), "(dissoc map & ks)", "Return a new persistent map without the keys ks. `map` is unchanged."),
        corefn.reg("disj", &nfunDisj, @src(), "(disj set & xs)", "Return a new persistent set without the elements xs. `set` is unchanged."),
    };
    corefn.install(env, bindings);
    try registry.registerAbstractType(&set_type);
}

/// Marks `t`'s tree.
///
/// This function cannot raise. It is what a `gcmark` callback calls for a
/// payload that includes a `Tree`.
pub fn mark(t: *const Tree) void {
    if (t.root) |root| gc_mark.markNode(&root.gc);
}

/// Returns whether two maps, or two sets, can be equal: whether their counts
/// and hashes are equal.
///
/// This function cannot raise. `order.zig` rejects a pair on this before
/// reading their entries.
pub fn mayEqual(a: *const Tree, b: *const Tree) bool {
    return a.count == b.count and a.sum == b.sum;
}

/// Allocates an inner node of `kind` for `len` children, with every child
/// null and every separator and count zero.
///
/// This function cannot raise. The node is unreachable until the caller stores
/// it where the mark phase finds it, so the next collection frees a node the
/// caller has not stored.
pub fn newInner(kind: Kind, len: usize) *Node {
    const node = allocate(kind, len, true);
    @memset(children(node), null);
    @memset(separators(node), 0);
    @memset(counts(node), 0);
    return node;
}

/// Allocates a leaf of `kind` for `len` entries, with every entry nil and every
/// place hash zero.
///
/// This function cannot raise. The node is unreachable until the caller stores
/// it where the mark phase finds it, so the next collection frees a node the
/// caller has not stored.
pub fn newLeaf(kind: Kind, len: usize) *Node {
    const node = allocate(kind, len, false);
    @memset(entries(node), wrap.fromNil());
    @memset(hashes(node), 0);
    return node;
}

/// Returns the payload behind a map's or a set's header.
///
/// This function cannot raise. `head` must be the header of a `map` block or
/// of a `core/set` abstract, and any other header is illegal behaviour.
pub fn ofHead(head: *const abi.GCObject) *const Tree {
    if (gc_alloc.memoryTypeOf(head) == .map) {
        const block: *const Head = @alignCast(@fieldParentPtr("gc", head));
        return &block.tree;
    }
    const abstract_head: *const abi.AbstractHead = @alignCast(@fieldParentPtr("gc", head));
    std.debug.assert(abstract_head.type == &set_type);
    return @ptrCast(@alignCast(abstracts.data(abstract_head)));
}

/// Returns a new collection of `kind` with `t`'s entries, and clears
/// `own_editable` on every node a transient update of `t` made.
///
/// This function cannot raise. The new collection takes `t`'s nodes, so the
/// caller makes no further transient update of `t`.
pub fn persistent(t: *const Tree, kind: Kind) *Tree {
    if (t.root) |root| clearEditable(root);
    return newTree(kind, t.*);
}

/// Returns the place hash of `key`, which orders the entries of a tree.
///
/// This function cannot raise.
pub inline fn placeHash(key: repr.Value) u32 {
    return vectors.fmix32(@bitCast(order.hash(key)));
}

/// Returns a new collection of `kind` equal to `src` with `entry` added, or
/// with the value of the entry that has its key replaced.
///
/// This function cannot raise. `entry` is as many values as `kind` says, the
/// key first. The key must not be nil or NaN and a map's value must not be
/// nil, and either is illegal behaviour. The new collection shares every node
/// with `src` except those on the path to the entry.
pub fn put(src: *const Tree, kind: Kind, entry: []const repr.Value) *Tree {
    std.debug.assert(entry.len == kind.entryWidth());
    var built = copyTree(src);
    putEntry(&built, kind, entry, .persistent);
    return newTree(kind, built);
}

/// Returns a new collection of `kind` equal to `src` without the entry whose
/// key is `key`.
///
/// This function cannot raise. Where there is no such entry, the new
/// collection is equal to `src` and shares its tree.
pub fn remove(src: *const Tree, kind: Kind, key: repr.Value) *Tree {
    var built = copyTree(src);
    removeKey(&built, kind, key, .persistent);
    return newTree(kind, built);
}

/// Returns the separators of the inner node `node`, one for each child.
///
/// This function cannot raise. `node` must be an inner node.
pub fn separators(node: *Node) []u32 {
    std.debug.assert(isInner(node));
    const base = @intFromPtr(&node._items) + node.len * @sizeOf(?*abi.GCObject);
    const many: [*]u32 = @ptrFromInt(base);
    return many[0..node.len];
}

/// Marshals `t`'s count and then its entries in order.
///
/// It is half of a set's `marshal` callback and the whole of what a map's
/// arm of the marshaller writes after the lead byte.
pub fn marshalTree(t: *Tree, m: *abi.Marshal) raise.Error!void {
    try marsh.marshalSize(m, t.count);
    // Nodes do not change, so a node stays valid across marshalling a value.
    if (t.root) |root| try marshalNode(m, root);
}

/// Whether `key` may be stored: not nil, which is where `next` starts and
/// ends, and not NaN, which is not equal to itself.
///
/// This function cannot raise. `checkKey` is the raising form, and the parser
/// and the varargs fill, neither of which has a raise to propagate, read this
/// one.
pub inline fn storableKey(key: repr.Value) bool {
    if (repr.checkType(key, repr.Tag.nil)) return false;
    return !(repr.checkType(key, repr.Tag.number) and std.math.isNan(wrap.toNumber(key)));
}

/// Returns the payload of `x` if `x` is a collection of `kind`, and null
/// otherwise.
pub fn toTree(x: repr.Value, kind: Kind) ?*Tree {
    switch (kind) {
        .map => {
            if (!repr.checkType(x, repr.Tag.map)) return null;
            return @constCast(wrap.toMap(x));
        },
        .set => {
            if (!repr.checkType(x, repr.Tag.abstract)) return null;
            const payload = wrap.toAbstract(x);
            if (abi.abstractHead(payload).type != &set_type) return null;
            return @ptrCast(@alignCast(payload));
        },
    }
}

/// Adds `entry` to `t` in place, or replaces the value of the entry that has
/// its key.
///
/// This function cannot raise. `entry` is as many values as `kind` says, the
/// key first. The key must not be nil or NaN and a map's value must not be
/// nil, and either is illegal behaviour. `t` must be a transient's, since the
/// update changes the nodes it has made.
pub fn transientPut(t: *Tree, kind: Kind, entry: []const repr.Value) void {
    std.debug.assert(entry.len == kind.entryWidth());
    putEntry(t, kind, entry, .transient);
}

/// Removes the entry whose key is `key` from `t` in place, if there is one.
///
/// This function cannot raise. `t` must be a transient's, since the update
/// changes the nodes it has made.
pub fn transientRemove(t: *Tree, kind: Kind, key: repr.Value) void {
    removeKey(t, kind, key, .transient);
}

/// Returns value `index` of `t`'s entries in order, counting each value of
/// each entry.
///
/// This function cannot raise. `index` must be below `count` times the width
/// of an entry of `kind`, and a larger one is illegal behaviour.
pub fn valueAt(t: *const Tree, kind: Kind, index: usize) repr.Value {
    const w = kind.entryWidth();
    std.debug.assert(index < t.count * w);
    var node = t.root.?;
    var at = index / w;
    while (isInner(node)) {
        const sizes = counts(node);
        var i: usize = 0;
        while (at >= sizes[i]) : (i += 1) at -= sizes[i];
        node = childAt(node, i);
    }
    return leafEntries(node, w)[at * w + index % w];
}

// ==========================================================================
// Private functions
// ==========================================================================

/// Allocates a node of `kind` for `len` entries or children, as `inner` says.
/// The caller makes every slot valid.
fn allocate(kind: Kind, len: usize, inner: bool) *Node {
    const size = nodeSize(kind, len, inner);
    const node: *Node = @ptrCast(@alignCast(gc_alloc.gcallocBytes(kind.memoryType(), size)));
    node.* = .{ .gc = node.gc, .len = @intCast(len) };
    if (inner) node.gc.flags.own |= own_inner;
    return node;
}

/// Returns the contents of a collection of `kind` with the entries in
/// `values`, as `build` describes.
fn buildContents(kind: Kind, values: []const repr.Value) Tree {
    const w = kind.entryWidth();
    std.debug.assert(values.len % w == 0);
    const n = values.len / w;
    var stack: [2 * build_stack]Placed = undefined;
    const both = if (n <= build_stack)
        stack[0 .. 2 * n]
    else
        utils.heap.alloc(Placed, 2 * n) catch fatal.outOfMemory();
    defer if (n > build_stack) utils.heap.free(both);
    const placed = both[0..n];

    for (placed, 0..) |*p, i| p.* = .{ .hash = placeHash(values[i * w]), .at = @intCast(i) };
    sortByHash(placed, both[n..], 0);
    const kept = keepLast(kind, values, placed);

    var built: Tree = .{ .count = kept.len };
    for (kept) |p| built.sum +%= term(kind, p.hash, values[p.at * w ..][0..w]);
    if (kept.len > 0) built.root = buildTree(kind, values, kept);
    return built;
}

/// Returns the tree holding the entries `placed` names, from the leaves up.
///
/// `placed` is in order, holds no two equal keys, and is not empty.
fn buildTree(kind: Kind, values: []const repr.Value, placed: []const Placed) *Node {
    if (placed.len <= leaf_max) return fillLeaf(kind, values, placed);
    const leaves = (placed.len + leaf_max - 1) / leaf_max;
    // A leaf ended early to keep a run whole leaves more leaves than `leaves`,
    // and there are never more leaves than entries.
    var level_stack: [64]*Node = undefined;
    const level = if (placed.len <= level_stack.len)
        level_stack[0..placed.len]
    else
        utils.heap.alloc(*Node, placed.len) catch fatal.outOfMemory();
    defer if (placed.len > level_stack.len) utils.heap.free(level);

    var made: usize = 0;
    var start: usize = 0;
    while (start < placed.len) : (made += 1) {
        // The rest are shared evenly among the leaves left, up to `leaf_max`
        // each. A run of one place hash is not divided: the leaf ends before
        // the run, or after it where the run began the leaf.
        const parts = if (leaves > made) leaves - made else 1;
        const target = @min(leaf_max, (placed.len - start + parts - 1) / parts);
        var end = start + target;
        if (end < placed.len and placed[end].hash == placed[end - 1].hash) {
            var back = end - 1;
            while (back > start and placed[back].hash == placed[back - 1].hash) back -= 1;
            if (back > start) {
                end = back;
            } else {
                while (end < placed.len and placed[end].hash == placed[end - 1].hash) end += 1;
            }
        }
        level[made] = fillLeaf(kind, values, placed[start..end]);
        start = end;
    }

    var len = made;
    while (len > 1) {
        const parents = (len + inner_max - 1) / inner_max;
        var from: usize = 0;
        for (0..parents) |i| {
            const to = evenEnd(len, parents, i);
            level[i] = innerOver(kind, level[from..to], .persistent);
            from = to;
        }
        len = parents;
    }
    return level[0];
}

/// `disj`: a new set without the elements.
fn nfunDisj(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, -1);
    const src = try args_core.getAbstract(Tree, argv, 0, &set_type);
    var built = copyTree(src);
    for (argv[1..]) |x| removeKey(&built, .set, x, .transient);
    return result(argv[0], src, built, .set);
}

/// `dissoc`: a new map without the keys.
fn nfunDissoc(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, -1);
    const src = try args_core.getMap(argv, 0);
    var built = copyTree(src);
    for (argv[1..]) |key| removeKey(&built, .map, key, .transient);
    return result(argv[0], src, built, .map);
}

/// `map/to-table`: a map's entries copied into a new table.
fn nfunMapTotable(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const t = try args_core.getMap(argv, 0);
    const table = tables.new(t.count);
    tables.mergeMap(table, t);
    return wrap.fromTable(table);
}

/// `hash-map`: a map of the key-value pairs in the arguments.
fn nfunHashMap(argv: []repr.Value) raise.Error!repr.Value {
    if (argv.len % 2 != 0) {
        return pp_format.panicf("expected an even number of keys and values, got %d", .{@as(i32, @intCast(argv.len))});
    }
    var i: usize = 0;
    while (i < argv.len) : (i += 2) try checkKey(argv[i]);
    return wrap.fromMap(build(.map, argv));
}

/// `hash-set`: a set of the arguments.
fn nfunHashSet(argv: []repr.Value) raise.Error!repr.Value {
    for (argv) |x| try checkKey(x);
    return wrap.fromAbstract(build(.set, argv));
}

/// The child of the inner node `node` at `index`.
inline fn childAt(node: *Node, index: usize) *Node {
    return asNode(children(node)[index].?);
}

/// Clears `own_editable` on `node` and on every node under it that has it set.
///
/// Every editable node's parent is editable, because a transient update makes
/// the whole path editable, so the walk stops at a node without the bit.
fn clearEditable(node: *Node) void {
    if (!isEditable(node)) return;
    node.gc.flags.own &= ~own_editable;
    for (children(node)) |slot| clearEditable(asNode(slot.?));
}

/// Copies the entry of `w` values at the start of `src` to the start of `dest`.
///
/// The width is one of two, so each is copied without a call to `memcpy`.
inline fn copyEntry(dest: []repr.Value, src: []const repr.Value, w: usize) void {
    dest[0] = src[0];
    if (w == 2) dest[1] = src[1];
}

/// Allocates a copy of `node`, editable where `editable` is true.
fn copyNode(node: *Node, editable: bool) *Node {
    const kind = kindOfNode(node);
    const inner = isInner(node);
    const copy = allocate(kind, node.len, inner);
    const body = nodeSize(kind, node.len, inner) - @offsetOf(Node, "_items");
    const from: [*]const u8 = @ptrCast(&node._items);
    const to: [*]u8 = @ptrCast(&copy._items);
    @memcpy(to[0..body], from[0..body]);
    if (editable) copy.gc.flags.own |= own_editable;
    return copy;
}

/// The number of entries under `node`.
fn countOf(node: *Node) u32 {
    if (!isInner(node)) return node.len;
    var total: u32 = 0;
    for (counts(node)) |c| total += c;
    return total;
}

/// Returns the entry at `t`'s cursor if its key is `key` bit for bit, and null
/// otherwise.
inline fn cursorEntry(t: *const Tree, kind: Kind, key: repr.Value) ?[]repr.Value {
    const leaf = t.cursor orelse return null;
    const w = kind.entryWidth();
    const entry = leafEntries(leaf, w)[t.cursor_index * w ..][0..w];
    return if (identical(key, entry[0])) entry else null;
}

/// Describes the values of every entry under `node`, in order.
fn describeNode(buffer: *buffers.Buffer, node: *Node, first: *bool) raise.Error!void {
    for (entries(node)) |x| {
        if (!first.*) try buffers.pushU8(buffer, ' ');
        first.* = false;
        try pp.descriptionB(buffer, x);
    }
    for (children(node)) |slot| try describeNode(buffer, asNode(slot.?), first);
}

/// `core/set`'s `tostring` callback, and the map's printed form: each value of each
/// entry described, in order, separated by spaces.
/// Pushes a collection's entries, separated by spaces, into `render`.
///
/// It is the `tostring` callback of a set and what `pp.zig` calls for a map,
/// which has no callback to be reached through.
pub fn describeTree(t: *Tree, render: *abi.Render) raise.Error!void {
    const buffer: *buffers.Buffer = @ptrCast(@alignCast(render));
    var first = true;
    // Nodes do not change, so a node stays valid across the allocations and
    // callbacks describing a value can make.
    if (t.root) |root| try describeNode(buffer, root, &first);
}

/// The end of run `i` when `n` items are split into `parts` runs of nearly
/// equal length.
fn evenEnd(n: usize, parts: usize, i: usize) usize {
    return (n * (i + 1) + parts - 1) / parts;
}

/// Fills the leaf `dest` with the entries of the leaf `src` with `entry`, whose
/// key's place hash is `hash`, inserted at `pos`, taking them from position
/// `from` of that sequence.
fn fillInserted(kind: Kind, dest: *Node, src: *Node, pos: usize, hash: u32, entry: []const repr.Value, from: usize) void {
    const w = kind.entryWidth();
    const to = from + dest.len;
    const items = leafEntries(src, w);
    const hs = leafHashes(src, w);
    const out = leafEntries(dest, w);
    const out_hs = leafHashes(dest, w);
    // The positions before `pos` come from the same positions of `src`, and
    // those after it from one position earlier.
    const before_end = @min(to, pos);
    if (from < before_end) {
        @memcpy(out[0 .. (before_end - from) * w], items[from * w .. before_end * w]);
        @memcpy(out_hs[0 .. before_end - from], hs[from..before_end]);
    }
    if (from <= pos and pos < to) {
        copyEntry(out[(pos - from) * w ..], entry, w);
        out_hs[pos - from] = hash;
    }
    const after_start = @max(from, pos + 1);
    if (after_start < to) {
        @memcpy(out[(after_start - from) * w .. (to - from) * w], items[(after_start - 1) * w .. (to - 1) * w]);
        @memcpy(out_hs[after_start - from .. to - from], hs[after_start - 1 .. to - 1]);
    }
}

/// The place hash that bounds `node` from below: the first hash of a leaf, or
/// the first separator of an inner node.
fn firstHash(node: *Node) u32 {
    return if (isInner(node)) separators(node)[0] else hashes(node)[0];
}

/// The place of the first entry under `node`.
fn firstPlace(node_in: *Node) Place {
    var node = node_in;
    while (isInner(node)) node = childAt(node, 0);
    return .{ .node = node, .index = 0 };
}

/// Whether `a` and `b` are the same value bit for bit.
///
/// Two such values are equal unless they are NaN, which is never a key.
inline fn identical(a: repr.Value, b: repr.Value) bool {
    return std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));
}

/// The index in the leaf `leaf`, whose entries are `w` values each, of the
/// entry whose key is `key`, whose place hash is `hash`, or null.
fn indexIn(w: usize, leaf: *Node, hash: u32, key: repr.Value) ?u32 {
    const hs = leafHashes(leaf, w);
    const items = leafEntries(leaf, w);
    var i = lowerBound(hs, hash);
    while (i < hs.len and hs[i] == hash) : (i += 1) {
        if (keysEqual(key, items[i * w])) return i;
    }
    return null;
}

/// Returns an inner node over `kids`, with their separators and counts.
fn innerOver(kind: Kind, kids: []const *Node, mode: Mode) *Node {
    const node = newInnerFor(kind, kids.len, mode);
    for (kids, children(node), separators(node), counts(node)) |kid, *slot, *sep, *c| {
        slot.* = &kid.gc;
        sep.* = firstHash(kid);
        c.* = countOf(kid);
    }
    return node;
}

/// Returns what replaces `node` once `entry`, whose key's place hash is
/// `hash`, is added under it or its value replaced, and records what changed
/// in `change`.
fn insertIn(kind: Kind, node: *Node, hash: u32, entry: []const repr.Value, mode: Mode, change: *Change) Replaced {
    if (isInner(node)) {
        const ci = route(node, hash);
        const replaced = insertIn(kind, childAt(node, ci), hash, entry, mode, change);
        if (!change.added and change.replaced == null) return Replaced.one(node);
        return replaceChildren(kind, node, ci, 1, replaced.nodes[0..replaced.len], mode);
    }
    const w = kind.entryWidth();
    const hs = leafHashes(node, w);
    const items = leafEntries(node, w);
    var pos = lowerBound(hs, hash);
    while (pos < hs.len and hs[pos] == hash) : (pos += 1) {
        const key = items[pos * w];
        if (keysEqual(entry[0], key)) {
            if (kind == .set) return Replaced.one(node);
            change.replaced = items[pos * 2 + 1];
            const owned = ownNode(node, mode);
            entries(owned)[pos * 2 + 1] = entry[1];
            return Replaced.one(owned);
        }
        if (order.compare(entry[0], key) < 0) break;
    }
    change.added = true;
    return leafWithEntry(kind, node, pos, hash, entry, mode);
}

/// Whether `node` has `own_editable` set.
inline fn isEditable(node: *const Node) bool {
    return node.gc.flags.own & own_editable != 0;
}

/// Removes from `placed` every entry whose key a later entry repeats, and every
/// map entry whose value is nil, sorts each run of one place hash by key, and
/// returns what is left.
///
/// `placed` is sorted by `hash`, and entries with equal hashes are in the order
/// they were given, so equal keys are adjacent within a run in that order.
fn keepLast(kind: Kind, values: []const repr.Value, placed: []Placed) []Placed {
    const w = kind.entryWidth();
    var kept: usize = 0;
    var i: usize = 0;
    while (i < placed.len) {
        var end = i + 1;
        while (end < placed.len and placed[end].hash == placed[i].hash) end += 1;
        const run_start = kept;
        for (i..end) |j| {
            const key = values[placed[j].at * w];
            const repeated = for (placed[j + 1 .. end]) |later| {
                if (keysEqual(key, values[later.at * w])) break true;
            } else false;
            if (repeated) continue;
            if (kind == .map and repr.checkType(values[placed[j].at * w + 1], repr.Tag.nil)) continue;
            placed[kept] = placed[j];
            kept += 1;
        }
        if (kept - run_start > 1) {
            std.sort.insertion(Placed, placed[run_start..kept], KeyOrder{ .values = values, .w = w }, KeyOrder.lessThan);
        }
        i = end;
    }
    return placed[0..kept];
}

/// Whether two keys are equal, testing whether they are identical before
/// calling `order.equals`.
///
/// `b` must not be NaN, and so must be a stored key.
inline fn keysEqual(a: repr.Value, b: repr.Value) bool {
    return identical(a, b) or order.equals(a, b);
}

/// The entries of the leaf `leaf`, whose entries are `w` values each.
inline fn leafEntries(leaf: *Node, w: usize) []repr.Value {
    const many: [*]repr.Value = @ptrCast(&leaf._items);
    return many[0 .. leaf.len * w];
}

/// The place hashes of the leaf `leaf`, whose entries are `w` values each.
inline fn leafHashes(leaf: *Node, w: usize) []u32 {
    const many: [*]u32 = @ptrFromInt(@intFromPtr(&leaf._items) + leaf.len * w * @sizeOf(repr.Value));
    return many[0..leaf.len];
}

/// The kind of a node already known to be a tree node.
inline fn kindOfNode(node: *const Node) Kind {
    return kindOf(&node.gc).?;
}

/// Returns what replaces the leaf `leaf` once `entry`, whose key's place hash
/// is `hash`, is inserted at `pos`: one leaf, or two where it no longer fits.
fn leafWithEntry(kind: Kind, leaf: *Node, pos: usize, hash: u32, entry: []const repr.Value, mode: Mode) Replaced {
    const total = leaf.len + 1;
    var split = total;
    if (total > leaf_max) {
        const hs = hashes(leaf);
        // The split does not divide a run of one place hash. Where the middle
        // is inside a run, it moves to the run's end, or else its start, and a
        // leaf that is one run is not split.
        split = total / 2;
        while (split < total and sameHashAt(hs, pos, hash, split)) split += 1;
        if (split == total) {
            split = total / 2;
            while (split > 0 and sameHashAt(hs, pos, hash, split)) split -= 1;
            if (split == 0) split = total;
        }
    }
    const left = newLeafFor(kind, split, mode);
    fillInserted(kind, left, leaf, pos, hash, entry, 0);
    if (split == total) return Replaced.one(left);
    const right = newLeafFor(kind, total - split, mode);
    fillInserted(kind, right, leaf, pos, hash, entry, split);
    return .{ .nodes = .{ left, right }, .len = 2 };
}

/// Returns a leaf holding the entries `placed` names, in order.
fn fillLeaf(kind: Kind, values: []const repr.Value, placed: []const Placed) *Node {
    const w = kind.entryWidth();
    const leaf = newLeafFor(kind, placed.len, .persistent);
    const items = leafEntries(leaf, w);
    for (placed, leafHashes(leaf, w), 0..) |p, *h, i| {
        copyEntry(items[i * w ..], values[p.at * w ..], w);
        h.* = p.hash;
    }
    return leaf;
}

/// The first index of `hs` whose hash is not below `hash`.
fn lowerBound(hs: []const u32, hash: u32) u32 {
    var lo: u32 = 0;
    var hi: u32 = @intCast(hs.len);
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (hs[mid] < hash) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// The entries of the leaf that holds the pair
/// at `position`, which counts values, so pair i is at 2i.
///
/// `t` is not empty, because `position` is below twice its count. This
/// function cannot raise.
/// The run of entries holding the pair at `position`, which counts values, so
/// pair i is at position 2i.
///
/// This function cannot raise. `t` must hold the pair, and a position at or
/// past twice its count is illegal behaviour. The run is a leaf's own storage,
/// so it stays valid until the next update of `t`.
pub fn chunkAt(t: *const Tree, position: usize) abstract_type.Chunk {
    var node = t.root.?;
    var at = position / 2;
    var first: usize = 0;
    while (isInner(node)) {
        const sizes = counts(node);
        var i: usize = 0;
        while (at >= sizes[i]) : (i += 1) {
            at -= sizes[i];
            first += sizes[i];
        }
        node = childAt(node, i);
    }
    return .{ .items = leafEntries(node, 2), .start = first * 2 };
}

/// The value at `key`, or nil.
///
/// A missing key is reported as found with nil, so `in` gives nil for it.
/// The value `key` is associated with in `t`, or nil where it has none.
///
/// This function cannot raise, so a caller with no raise to propagate, such as
/// the assembler, may read a map through it.
pub fn lookup(t: *const Tree, key: repr.Value) repr.Value {
    const entry = cursorEntry(t, .map, key) orelse find(t, .map, key) orelse return wrap.fromNil();
    return entry[1];
}

/// The key after `key`.
/// The key after `key` in `t`, the first key where `key` is nil, or nil at the
/// end.
///
/// This function cannot raise. It moves `t`'s cursor to the entry returned.
pub fn nextKey(t: *Tree, key: repr.Value) repr.Value {
    const entry = nextEntry(t, .map, key) orelse return wrap.fromNil();
    return entry[0];
}

/// The element after `element` in the set `t`, or nil at its end.
///
/// `nextKey`'s sibling rather than a special case of it: a kind gives its
/// entries a stride, 2 for a map and 1 for a set, so a set walked with
/// `nextKey` returns every other element and then reads past the last node.
pub fn nextElement(t: *Tree, element: repr.Value) repr.Value {
    const entry = nextEntry(t, .set, element) orelse return wrap.fromNil();
    return entry[0];
}

/// Reads back what a map's or a set's marshalled form holds.
/// Marshals the values of every entry under `node`, in order.
fn marshalNode(m: *abi.Marshal, node: *Node) raise.Error!void {
    for (entries(node)) |x| try marsh.marshalValue(m, x);
    for (children(node)) |slot| try marshalNode(m, asNode(slot.?));
}

/// Returns the node holding the entries or children of `left` and then of
/// `right`, two neighbours of one kind and depth. `boundary` is the separator
/// the parent holds for `right`.
fn mergeNodes(kind: Kind, left: *Node, right: *Node, boundary: u32, mode: Mode) *Node {
    const len = left.len + right.len;
    if (!isInner(left)) {
        const w = kind.entryWidth();
        const node = newLeafFor(kind, len, mode);
        @memcpy(entries(node)[0 .. left.len * w], entries(left));
        @memcpy(entries(node)[left.len * w ..], entries(right));
        @memcpy(hashes(node)[0..left.len], hashes(left));
        @memcpy(hashes(node)[left.len..], hashes(right));
        return node;
    }
    const node = newInnerFor(kind, len, mode);
    @memcpy(children(node)[0..left.len], children(left));
    @memcpy(children(node)[left.len..], children(right));
    @memcpy(separators(node)[0..left.len], separators(left));
    @memcpy(separators(node)[left.len..], separators(right));
    separators(node)[left.len] = boundary;
    @memcpy(counts(node)[0..left.len], counts(left));
    @memcpy(counts(node)[left.len..], counts(right));
    return node;
}

/// Allocates an inner node, editable where `mode` is `transient`. The caller
/// fills every slot.
fn newInnerFor(kind: Kind, len: usize, mode: Mode) *Node {
    const node = allocate(kind, len, true);
    if (mode == .transient) node.gc.flags.own |= own_editable;
    return node;
}

/// Allocates a leaf, editable where `mode` is `transient`. The caller fills
/// every slot.
fn newLeafFor(kind: Kind, len: usize, mode: Mode) *Node {
    const node = allocate(kind, len, false);
    if (mode == .transient) node.gc.flags.own |= own_editable;
    return node;
}

/// Allocates a map or a set with the contents of `built` and no cursor.
///
/// A map is a `map` block and a set an abstract, so the two allocate
/// differently and everything above this function works on the `Tree` alike.
fn newTree(kind: Kind, built: Tree) *Tree {
    const payload: *Tree = switch (kind) {
        .map => &gc_alloc.gcalloc(Head, .map).tree,
        .set => @ptrCast(@alignCast(abstracts.newBytes(&set_type, @sizeOf(Tree)))),
    };
    payload.* = copyTree(&built);
    return payload;
}

/// Returns the entry after the one whose key is `key` in `t`, the first entry
/// where `key` is nil, or null where there is none, and moves `t`'s cursor to
/// the entry returned.
///
/// Where `key` is the key at the cursor and its successor is in the same leaf,
/// the search starts from the cursor rather than from the root.
fn nextEntry(t: *Tree, kind: Kind, key: repr.Value) ?[]repr.Value {
    const root = t.root orelse return null;
    var place: Place = undefined;
    if (repr.checkType(key, repr.Tag.nil)) {
        place = firstPlace(root);
    } else if (cursorEntry(t, kind, key) != null and t.cursor_index + 1 < t.cursor.?.len) {
        place = .{ .node = t.cursor.?, .index = t.cursor_index + 1 };
    } else {
        place = switch (seekAfter(root, placeHash(key), key)) {
            .found => |found| found,
            .absent, .last => return null,
        };
    }
    t.cursor = place.node;
    t.cursor_index = place.index;
    const w = kind.entryWidth();
    return leafEntries(place.node, w)[place.index * w ..][0..w];
}

/// The size of a node of `kind` with `len` entries or children, as `inner`
/// says.
fn nodeSize(kind: Kind, len: usize, inner: bool) usize {
    const slot: usize = if (inner)
        @sizeOf(?*abi.GCObject) + 2 * @sizeOf(u32)
    else
        kind.entryWidth() * @sizeOf(repr.Value) + @sizeOf(u32);
    const body = std.math.mul(usize, len, slot) catch fatal.outOfMemory();
    const size = std.math.add(usize, @offsetOf(Node, "_items"), body) catch fatal.outOfMemory();
    return std.mem.alignForward(usize, size, @alignOf(repr.Value));
}

/// Returns the node `node` or a copy of it, whichever an update in `mode` may
/// change.
fn ownNode(node: *Node, mode: Mode) *Node {
    return switch (mode) {
        .persistent => copyNode(node, false),
        .transient => if (isEditable(node)) node else copyNode(node, true),
    };
}

/// Whether `a` comes before `b` in a `build`'s order.
fn placedLessThan(_: void, a: Placed, b: Placed) bool {
    return a.hash < b.hash;
}

/// Adds `entry` to `t`, or replaces the value of the entry with its key,
/// treating the nodes it changes as `mode` says, and keeps `count` and `sum`
/// current.
fn putEntry(t: *Tree, kind: Kind, entry: []const repr.Value, mode: Mode) void {
    const hash = placeHash(entry[0]);
    var change: Change = .{};
    if (t.root) |root| {
        const replaced = insertIn(kind, root, hash, entry, mode, &change);
        if (!change.added and change.replaced == null) return;
        t.root = if (replaced.len == 2) innerOver(kind, &replaced.nodes, mode) else replaced.nodes[0];
    } else {
        const leaf = newLeafFor(kind, 1, mode);
        @memcpy(entries(leaf), entry);
        hashes(leaf)[0] = hash;
        t.root = leaf;
        change.added = true;
    }
    if (change.added) {
        t.count += 1;
        t.sum +%= term(kind, hash, entry);
    } else if (change.replaced) |old| {
        const before = [2]repr.Value{ entry[0], old };
        t.sum = t.sum -% term(kind, hash, &before) +% term(kind, hash, entry);
    }
}

/// Removes the entry whose key is `key` from `t`, if there is one, treating
/// the nodes it changes as `mode` says, and keeps `count` and `sum` current.
fn removeKey(t: *Tree, kind: Kind, key: repr.Value, mode: Mode) void {
    const root = t.root orelse return;
    var change: Change = .{};
    const hash = placeHash(key);
    const replaced = removeIn(kind, root, hash, key, mode, &change);
    if (!change.removed) return;
    t.count -= 1;
    t.sum -%= term(kind, hash, change.gone[0..kind.entryWidth()]);
    if (replaced.len == 0) {
        t.root = null;
        return;
    }
    var top = replaced.nodes[0];
    while (isInner(top) and top.len == 1) top = childAt(top, 0);
    t.root = top;
}

/// Returns what replaces `node` once the entry whose key is `key`, whose place
/// hash is `hash`, is removed from under it, and records what changed in
/// `change`. The replacement is no node where `node` is left empty.
fn removeIn(kind: Kind, node: *Node, hash: u32, key: repr.Value, mode: Mode, change: *Change) Replaced {
    if (!isInner(node)) {
        const w = kind.entryWidth();
        const i = indexIn(w, node, hash, key) orelse return Replaced.one(node);
        change.removed = true;
        @memcpy(change.gone[0..w], entries(node)[i * w ..][0..w]);
        if (node.len == 1) return .{ .len = 0 };
        const leaf = newLeafFor(kind, node.len - 1, mode);
        const items = entries(node);
        @memcpy(entries(leaf)[0 .. i * w], items[0 .. i * w]);
        @memcpy(entries(leaf)[i * w ..], items[(i + 1) * w ..]);
        @memcpy(hashes(leaf)[0..i], hashes(node)[0..i]);
        @memcpy(hashes(leaf)[i..], hashes(node)[i + 1 ..]);
        return Replaced.one(leaf);
    }
    const ci = route(node, hash);
    const replaced = removeIn(kind, childAt(node, ci), hash, key, mode, change);
    if (!change.removed) return Replaced.one(node);
    if (replaced.len == 0) return replaceChildren(kind, node, ci, 1, &.{}, mode);
    const changed = replaced.nodes[0];
    if (changed.len < merge_below and node.len > 1) {
        const left = if (ci + 1 < node.len) ci else ci - 1;
        const left_node = if (left == ci) changed else childAt(node, left);
        const right_node = if (left == ci) childAt(node, ci + 1) else changed;
        const limit: usize = if (isInner(changed)) inner_max else leaf_max;
        if (left_node.len + right_node.len <= limit) {
            const merged = mergeNodes(kind, left_node, right_node, separators(node)[left + 1], mode);
            return replaceChildren(kind, node, left, 2, &.{merged}, mode);
        }
    }
    return replaceChildren(kind, node, ci, 1, &.{changed}, mode);
}

/// Returns what replaces the inner node `node` once its `removed` children
/// from `at` are replaced by `with`: no node, one, or two where it no longer
/// fits.
///
/// The first of `with` keeps the separator of the child at `at`, and each
/// other takes its own first hash.
fn replaceChildren(kind: Kind, node: *Node, at: usize, removed: usize, with: []const *Node, mode: Mode) Replaced {
    const len = node.len - removed + with.len;
    if (len == 0) return .{ .len = 0 };
    if (removed == 1 and with.len == 1 and mode == .transient and isEditable(node)) {
        children(node)[at] = &with[0].gc;
        counts(node)[at] = countOf(with[0]);
        return Replaced.one(node);
    }

    var kids: [inner_max + 2]*Node = undefined;
    var seps: [inner_max + 2]u32 = undefined;
    var sizes: [inner_max + 2]u32 = undefined;
    const old_kids = children(node);
    const old_seps = separators(node);
    const old_counts = counts(node);
    var n: usize = 0;
    for (0..at) |i| {
        kids[n] = asNode(old_kids[i].?);
        seps[n] = old_seps[i];
        sizes[n] = old_counts[i];
        n += 1;
    }
    for (with, 0..) |kid, i| {
        kids[n] = kid;
        seps[n] = if (i == 0) old_seps[at] else firstHash(kid);
        sizes[n] = countOf(kid);
        n += 1;
    }
    for (at + removed..node.len) |i| {
        kids[n] = asNode(old_kids[i].?);
        seps[n] = old_seps[i];
        sizes[n] = old_counts[i];
        n += 1;
    }
    std.debug.assert(n == len);

    const parts: usize = if (len > inner_max) 2 else 1;
    var out: Replaced = .{ .len = parts };
    var from: usize = 0;
    for (0..parts) |p| {
        const to = evenEnd(len, parts, p);
        const made = newInnerFor(kind, to - from, mode);
        for (children(made), separators(made), counts(made), from..to) |*slot, *sep, *c, i| {
            slot.* = &kids[i].gc;
            sep.* = seps[i];
            c.* = sizes[i];
        }
        out.nodes[p] = made;
        from = to;
    }
    return out;
}

/// The value an update returns: the collection it was given, where nothing
/// changed, or a new one with the contents of `built`, whose editable nodes
/// are cleared.
fn result(original: repr.Value, src: *const Tree, built: Tree, kind: Kind) repr.Value {
    if (built.root == src.root) return original;
    if (built.root) |root| clearEditable(root);
    const made = newTree(kind, built);
    return switch (kind) {
        .map => wrap.fromMap(made),
        .set => wrap.fromAbstract(made),
    };
}

/// The index of the child of the inner node `node` whose range holds `hash`.
fn route(node: *Node, hash: u32) usize {
    const seps = separators(node);
    var chosen: usize = 0;
    var i: usize = 1;
    while (i < seps.len and seps[i] <= hash) : (i += 1) chosen = i;
    return chosen;
}

/// Whether the place hash at `i` of the leaf hashes `hs` with `hash` inserted
/// at `pos` equals the one before it.
fn sameHashAt(hs: []const u32, pos: usize, hash: u32, i: usize) bool {
    const at = struct {
        fn get(src: []const u32, p: usize, h: u32, j: usize) u32 {
            return if (j < p) src[j] else if (j == p) h else src[j - 1];
        }
    }.get;
    return at(hs, pos, hash, i) == at(hs, pos, hash, i - 1);
}

/// Finds the entry after the one whose key is `key`, whose place hash is
/// `hash`, under `node`.
fn seekAfter(node: *Node, hash: u32, key: repr.Value) Seek {
    if (!isInner(node)) {
        const i = indexIn(kindOfNode(node).entryWidth(), node, hash, key) orelse return .absent;
        if (i + 1 < node.len) return .{ .found = .{ .node = node, .index = i + 1 } };
        return .last;
    }
    const ci = route(node, hash);
    const found = seekAfter(childAt(node, ci), hash, key);
    if (found != .last) return found;
    if (ci + 1 < node.len) return .{ .found = firstPlace(childAt(node, ci + 1)) };
    return .last;
}

/// `core/set`'s `get` callback: the element equal to `key`, or nil.
///
/// A missing element is reported as found with nil rather than as absent, so
/// that the runtime does not fall back to a method lookup on it.
fn setGet(t: *Tree, key: repr.Value) raise.Error!?repr.Value {
    const entry = cursorEntry(t, .set, key) orelse find(t, .set, key) orelse return wrap.fromNil();
    return entry[0];
}

/// `core/set`'s `next` callback: the element after `key`.
fn setNext(t: *Tree, key: repr.Value) raise.Error!repr.Value {
    const entry = nextEntry(t, .set, key) orelse return wrap.fromNil();
    return entry[0];
}

/// `core/set`'s `unmarshal` callback: reads what `treeMarshal` wrote.
fn setUnmarshal(u: *abi.Unmarshal) raise.Error!*Tree {
    return unmarshalTree(u, .set);
}

/// Sorts `placed` by `hash`, keeping entries with equal hashes in the order
/// they are in.
///
/// Every entry of `placed` agrees on the digits read before `level`. `scratch`
/// is at least as long as `placed`, and its contents are lost.
fn sortByHash(placed: []Placed, scratch: []Placed, level: u32) void {
    if (placed.len <= insertion_sort_max) {
        std.sort.insertion(Placed, placed, {}, placedLessThan);
        return;
    }
    // Every digit has been read, so the entries share a hash.
    if (level > 6) return;
    var tally = [_]u32{0} ** 32;
    for (placed) |p| tally[sortDigit(p.hash, level)] += 1;
    var starts: [32]u32 = undefined;
    var total: u32 = 0;
    for (&starts, tally) |*start, c| {
        start.* = total;
        total += c;
    }
    var cursors = starts;
    for (placed) |p| {
        const d = sortDigit(p.hash, level);
        scratch[cursors[d]] = p;
        cursors[d] += 1;
    }
    @memcpy(placed, scratch[0..placed.len]);
    for (starts, tally) |start, c| {
        if (c < 2) continue;
        sortByHash(placed[start..][0..c], scratch[start..], level + 1);
    }
}

/// The digit of `hash` a partition at `level` reads: five bits from the most
/// significant down, and the last two bits at level 6.
inline fn sortDigit(hash: u32, level: u32) u5 {
    if (level < 6) return @truncate(hash >> @intCast(27 - 5 * level));
    return @truncate(hash & 3);
}

/// The term the entry `entry`, whose key's place hash is `hash`, adds to a
/// collection's `sum`.
///
/// A term depends on the entry and not on where it is, so two trees with equal
/// entries have one sum. A map's term mixes the value's hash through a
/// finalizer before the key's, so an entry and one with its key and value
/// swapped give different terms.
fn term(kind: Kind, hash: u32, entry: []const repr.Value) u32 {
    return switch (kind) {
        .set => vectors.fmix32(hash),
        .map => vectors.fmix32(hash ^ vectors.fmix32(@as(u32, @bitCast(order.hash(entry[1]))) +% 0x9e3779b9)),
    };
}

/// `core/set`'s `hash` callback: the count mixed with the
/// running sum.
fn treeHash(t: *const Tree, _: usize) i32 {
    return hashOf(t);
}

/// `core/set`'s `length` callback.
fn treeLength(t: *Tree, _: usize) raise.Error!usize {
    return t.count;
}

/// `core/set`'s `marshal` callback: the count, then each
/// entry's values in order.
///
/// The collection is entered in the reference table last. The file header
/// says why.
fn treeMarshal(t: *Tree, m: *abi.Marshal) raise.Error!void {
    try marshalTree(t, m);
    marsh.marshalAbstract(m, t);
}

/// `core/set`'s `gcmark` callback: the tree.
fn treeMark(t: *Tree, _: usize) void {
    mark(t);
}

/// Reads a collection of `kind` that `treeMarshal` wrote.
///
/// The values are gathered in a scratch vector, which a raise leaves to the
/// next collection, and the tree is built from them under `hash-map`'s rules.
/// Nothing is rooted, which is safe because no collection runs during
/// unmarshalling. The abstract is made and entered in the reference table
/// after the last entry. This function raises if a key is nil or NaN.
fn unmarshalTree(u: *abi.Unmarshal, kind: Kind) raise.Error!*Tree {
    // Nothing is allocated for the count up front, so a count longer than the
    // stream needs no check of its own: the read past the end refuses it.
    const count = try marsh.unmarshalSize(u);
    var values: scratch_vector.Vector(repr.Value) = .empty;
    for (0..count) |_| {
        const key = try marsh.unmarshalValue(u);
        try checkKey(key);
        scratch_vector.push(&values, key);
        if (kind == .map) scratch_vector.push(&values, try marsh.unmarshalValue(u));
    }
    const built = buildContents(kind, values.items);
    scratch_vector.free(&values);
    const t: *Tree = @ptrCast(@alignCast(try marsh.unmarshalAbstract(u, @sizeOf(Tree))));
    t.* = built;
    return t;
}

// ==========================================================================
// Tests
// ==========================================================================

// `children`, `separators` and `counts` follow the header directly, which is
// aligned for a child pointer only if a value's alignment is at least a
// pointer's.
comptime {
    std.debug.assert(@alignOf(repr.Value) >= @alignOf(?*abi.GCObject));
    std.debug.assert(@offsetOf(Node, "_items") % @alignOf(repr.Value) == 0);
}
