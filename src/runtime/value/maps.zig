//! `core/map` and `core/set`: the persistent map and the persistent set, both
//! a hash array mapped trie with two bitmaps per node.
//!
//! A map and a set are one file because they are one structure. A map's entry
//! is a key and its value, and a set's is an element alone, and nothing else
//! about the trie differs. `Kind` says which a node or a payload belongs to.
//! `map_type` and `set_type` are the abstract types, both with a `Trie` as
//! their payload, and `lib` installs `hash-map`, `hash-set`, `dissoc` and
//! `disj`. `vectors.zig`'s `conj` and `assoc` reach a set and a map through
//! `conjSet` and `assocMap`.
//!
//! A trie's nodes are collector blocks of their own memory types. A map's
//! node is a `map_node` block, and a set's node is a `set_node` block.
//! `newNode` and `newCollision` allocate them. `gc/mark.zig`'s `markNode`
//! marks a node and everything under it, and `gc/sweep.zig` frees an
//! unreachable node with no finalizer.
//!
//! ## The shape of a node
//!
//! Five bits of a key's hash pick a slot at each level. A _bitmap node_
//! records in `datamap` the slots that hold an entry and in `nodemap` the
//! slots that hold a child. Its entries are stored in slot order, and then its
//! children in slot order. Keys whose hashes are equal in all 32 bits cannot
//! be told apart at any depth, and share a _collision node_ instead: a node
//! with `own_collision` set, both bitmaps zero, no children, and the hash its
//! entries share in `hash`.
//!
//! These rules hold for every node:
//!
//! - A node begins with its `GCObject`, so the collector reaches the node's
//!   memory type through the header. The memory type says how wide an entry
//!   is, and a child pointer is `*abi.GCObject` for the same reason.
//!
//! - A node is one block, sized when it is allocated for `len` entries and
//!   one child per bit of `nodemap`. Neither changes afterwards, so adding or
//!   removing an entry or a child allocates a new node.
//!
//! - Every slot of a node holds a valid entry from allocation onwards. An
//!   entry is nil and a child is null until the caller stores one. The mark
//!   phase reads every slot, because it cannot tell a slot the caller has
//!   filled from one it has not.
//!
//! - A node is not changed once a persistent collection refers to it. An
//!   update copies the path from the root to the entry it changes. Two updates
//!   change nodes in place: a transient's, on the nodes with `own_editable`
//!   set, and building a collection from arguments, on nodes no collection
//!   refers to yet.
//!
//! ## The shape of a trie
//!
//! Two tries with equal entries have the same shape however they were built,
//! which is what lets `order.zig` compare two of them node by node. Three
//! rules make it so:
//!
//! - A node other than the root never holds a single entry and nothing else.
//!   A removal that leaves a child so moves the entry into the parent.
//!
//! - A collision node's entries are sorted by `order.compare` on their keys,
//!   so the order they arrived in does not show.
//!
//! - A node other than the root never holds no entries and a collision node
//!   alone. A removal that leaves a child so puts the collision node in the
//!   child's place, where inserting the same keys would have put it.
//!
//! ## Updating a trie in place
//!
//! `transients.zig`'s transient holds a `Trie` and updates it through
//! `transientPut` and `transientRemove`, and `persistent` makes a map or a set
//! of it. These rules make that safe:
//!
//! - A transient update sets `own_editable` on every node it makes, and
//!   changes a node in place only where the bit is set. A node a transient
//!   made is reachable from that transient and from nothing else, because a
//!   transient is made only from a persistent collection and `persistent!`
//!   ends it.
//!
//! - An update makes the whole path from the root editable, so every editable
//!   node's parent is editable. `persistent` clears the bits by walking down
//!   through set bits only, which visits exactly the nodes the transient made.
//!
//! ## Keys and values
//!
//! A key is never nil or NaN. Nil is where `next` starts and ends, and NaN is
//! not equal to itself, so neither could be found again. Storing one raises,
//! and looking one up finds nothing. A map never holds a nil value: storing
//! one removes the key, as in a table.
//!
//! A lookup that finds nothing gives nil, through `get` and `in` alike, as a
//! struct does. A set's lookup gives the element itself, so `each`, `keys`
//! and `values` all give a set's elements.
//!
//! ## Equality, order and hash
//!
//! Two maps, or two sets, are equal when their tries match node by node. They
//! order by count, then by hash, then by the first difference in a walk of
//! both tries in step. A collection's hash is kept current rather than
//! computed when asked: `sum` is the wrapping sum of one term per entry, and a
//! term does not depend on where the entry is.

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
const order = @import("helpers/order.zig");
const pp = @import("../pp.zig");
const pp_format = @import("../pp/format.zig");
const raise = @import("../../api/raise.zig");
const registry = @import("../registry.zig");
const repr = @import("repr");
const tables = @import("tables.zig");
const value = @import("../value.zig");
const vectors = @import("vectors.zig");
const wrap = @import("helpers/wrap.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// The number of bits of a hash one level of the trie consumes.
const bits = 5;

/// The abstract type a map is.
pub const map_type = abstract_type.define(Trie, .{
    .name = "core/map",
    .gcmark = trieMark,
    .get = mapGet,
    .next = mapNext,
    .length = trieLength,
    .hash = trieHash,
    .tostring = mapTostring,
});

/// Bit 1 of the collector header's per-type field: the node is a collision
/// node.
pub const own_collision: u6 = 2;

/// Bit 0 of the collector header's per-type field: a transient made the node
/// and may change it in place.
pub const own_editable: u6 = 1;

/// The abstract type a set is.
pub const set_type = abstract_type.define(Trie, .{
    .name = "core/set",
    .gcmark = trieMark,
    .get = setGet,
    .next = setNext,
    .length = trieLength,
    .hash = trieHash,
    .tostring = setTostring,
});

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

/// Which collection a node or a payload belongs to, which decides its memory
/// type, its abstract type, and how many values an entry is.
pub const Kind = enum {
    map,
    set,

    /// The abstract type of a collection of this kind.
    pub fn abstractType(kind: Kind) *const abi.AbstractType {
        return switch (kind) {
            .map => &map_type,
            .set => &set_type,
        };
    }

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
/// copies any other with the bit set on the copy. `fresh` changes every node
/// in place, for a trie no collection refers to yet. In every mode, a node
/// that gains or loses an entry or a child is a new node.
const Mode = enum { persistent, transient, fresh };

/// A trie node's header: the collector's object, the two bitmaps, a
/// collision node's hash, and the number of entries.
///
/// `newNode` and `newCollision` return a `Node`. `datamap` has a bit for each
/// slot holding an entry and `nodemap` a bit for each slot holding a child,
/// and both are zero in a collision node. `hash` is the hash of every entry in
/// a collision node and zero in a bitmap node. `len` is the number of entries,
/// which in a bitmap node is the number of bits set in `datamap`. `entries`
/// and `children` return the slots that follow the header.
pub const Node = extern struct {
    gc: abi.GCObject = .{},
    datamap: u32 = 0,
    nodemap: u32 = 0,
    hash: u32 = 0,
    len: u32 = 0,
    _entries: [0]repr.Value = .{},
};

/// What `seekNext` found: the key absent from a subtree, the entry after the
/// key, or the key as the last entry of the subtree.
const Seek = union(enum) {
    absent,
    found: []repr.Value,
    last,
};

/// A map's or a set's payload.
///
/// `count` is the number of entries and `root` the trie, null only when
/// `count` is zero. `sum` is the running sum the hash is made from.
pub const Trie = struct {
    count: usize = 0,
    root: ?*Node = null,
    sum: u32 = 0,
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

/// `assoc` for a map: a new map with each key in `argv` associated with the
/// value after it.
///
/// `argv` is a frame whose first argument is a map and the rest keys and
/// values. A nil value removes its key. This function raises if a key has no
/// value, or if a key is nil or NaN.
pub fn assocMap(argv: []const repr.Value) raise.Error!repr.Value {
    const src = toTrie(argv[0], .map).?;
    try vectors.checkPairs(argv);
    var i: usize = 1;
    while (i < argv.len) : (i += 2) try checkKey(argv[i]);
    var built = src.*;
    i = 1;
    while (i < argv.len) : (i += 2) {
        if (repr.checkType(argv[i + 1], repr.Tag.nil)) {
            removeKey(&built, .map, argv[i], .persistent);
        } else {
            putEntry(&built, .map, &.{ argv[i], argv[i + 1] }, .persistent);
        }
    }
    return result(argv[0], src, built, .map);
}

/// Refuses a key that cannot be stored: nil, which is where `next` starts and
/// ends, and NaN, which is not equal to itself.
///
/// This function raises if `key` is nil or NaN.
pub fn checkKey(key: repr.Value) raise.Error!void {
    const nan = repr.checkType(key, repr.Tag.number) and std.math.isNan(wrap.toNumber(key));
    if (repr.checkType(key, repr.Tag.nil) or nan) {
        return pp_format.panicf("cannot use %v as a key", .{key});
    }
}

/// Returns the child slots of `node`, one for each bit set in `nodemap`.
///
/// This function cannot raise.
pub fn children(node: *Node) []?*abi.GCObject {
    const base = @intFromPtr(node) + childOffset(kindOfNode(node), node.len);
    const many: [*]?*abi.GCObject = @ptrFromInt(base);
    return many[0..@popCount(node.nodemap)];
}

/// `conj` for a set: a new set with each element in `argv` added.
///
/// `argv` is a frame whose first argument is a set and the rest elements. This
/// function raises if an element is nil or NaN.
pub fn conjSet(argv: []const repr.Value) raise.Error!repr.Value {
    const src = toTrie(argv[0], .set).?;
    for (argv[1..]) |x| try checkKey(x);
    var built = src.*;
    for (argv[1..]) |x| putEntry(&built, .set, &.{x}, .persistent);
    return result(argv[0], src, built, .set);
}

/// Returns the entry slots of `node`: `len` entries, each as many values as
/// the node's kind says.
///
/// This function cannot raise.
pub fn entries(node: *Node) []repr.Value {
    const many: [*]repr.Value = @ptrCast(&node._entries);
    return many[0 .. node.len * kindOfNode(node).entryWidth()];
}

/// Returns the entry of `t` whose key equals `key`, or null.
///
/// This function cannot raise. The entry is as many values as `kind` says,
/// the key first. A nil or NaN key finds nothing, since neither is stored.
pub fn find(t: *const Trie, kind: Kind, key: repr.Value) ?[]repr.Value {
    const w = kind.entryWidth();
    const hash = keyHash(key);
    var node = t.root orelse return null;
    var shift: u32 = 0;
    while (true) {
        if (isCollision(node)) {
            if (node.hash != hash) return null;
            const items = entries(node);
            for (0..node.len) |i| {
                if (order.equals(key, items[i * w])) return items[i * w ..][0..w];
            }
            return null;
        }
        const bit = bitpos(hash, shift);
        if (node.datamap & bit != 0) {
            const i = dataIndex(node, bit);
            const entry = entries(node)[i * w ..][0..w];
            return if (order.equals(key, entry[0])) entry else null;
        }
        if (node.nodemap & bit == 0) return null;
        node = asNode(children(node)[childIndex(node, bit)].?);
        shift += bits;
    }
}

/// Returns the kind of the node `header` begins, or null if it is not a trie
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
/// environment and registers `core/map` and `core/set`.
///
/// `env` is the environment. This function raises if a registration does.
pub fn lib(env: *tables.Table) raise.Error!void {
    const bindings = comptime [_]corefn.Entry{
        corefn.reg("hash-map", &cfunHashMap, @src(), "(hash-map & kvs)", "Create a new persistent map from alternating keys and values. The pairs are added in order, so a later value for a key replaces an earlier one, and a nil value removes its key. A key cannot be nil or NaN."),
        corefn.reg("hash-set", &cfunHashSet, @src(), "(hash-set & xs)", "Create a new persistent set containing the elements xs. An element cannot be nil or NaN."),
        corefn.reg("dissoc", &cfunDissoc, @src(), "(dissoc map & ks)", "Return a new persistent map without the keys ks. `map` is unchanged."),
        corefn.reg("disj", &cfunDisj, @src(), "(disj set & xs)", "Return a new persistent set without the elements xs. `set` is unchanged."),
    };
    corefn.install(env, bindings);
    try registry.registerAbstractType(&map_type);
    try registry.registerAbstractType(&set_type);
}

/// Marks `t`'s trie.
///
/// This function cannot raise. It is what a `gcmark` callback calls for a
/// payload that includes a `Trie`.
pub fn mark(t: *const Trie) void {
    if (t.root) |root| gc_mark.markNode(&root.gc);
}

/// Returns whether two maps, or two sets, can be equal: whether their counts
/// and hashes are equal.
///
/// This function cannot raise. `order.zig` rejects a pair on this before
/// walking their tries.
pub fn mayEqual(a: *const Trie, b: *const Trie) bool {
    return a.count == b.count and a.sum == b.sum;
}

/// Allocates a collision node for `len` entries whose keys all hash to
/// `hash`, with every entry nil.
///
/// This function cannot raise. The node is unreachable until the caller stores
/// it where the mark phase finds it, so the next collection frees a node the
/// caller has not stored.
pub fn newCollision(kind: Kind, hash: u32, len: u32) *Node {
    const node = allocate(kind, len, 0);
    node.hash = hash;
    node.gc.flags.own |= own_collision;
    return node;
}

/// Allocates a bitmap node with the slots `datamap` and `nodemap` name, with
/// every entry nil and every child null.
///
/// This function cannot raise. The two bitmaps must not share a bit. The node
/// is unreachable until the caller stores it where the mark phase finds it, so
/// the next collection frees a node the caller has not stored.
pub fn newNode(kind: Kind, datamap: u32, nodemap: u32) *Node {
    std.debug.assert(datamap & nodemap == 0);
    const node = allocate(kind, @popCount(datamap), nodemap);
    node.datamap = datamap;
    return node;
}

/// Returns the payload of a map's or a set's abstract header.
///
/// This function cannot raise. `head` must be the header of a `core/map` or a
/// `core/set`, and any other header is illegal behaviour.
pub fn ofHead(head: *const abi.GCObject) *const Trie {
    const abstract_head: *const abi.AbstractHead = @alignCast(@fieldParentPtr("gc", head));
    std.debug.assert(abstract_head.type == &map_type or abstract_head.type == &set_type);
    return @ptrCast(@alignCast(abstracts.data(abstract_head)));
}

/// Returns a new collection of `kind` with `t`'s entries, and clears
/// `own_editable` on every node a transient update of `t` made.
///
/// This function cannot raise. The new collection takes `t`'s nodes, so the
/// caller makes no further transient update of `t`.
pub fn persistent(t: *const Trie, kind: Kind) *Trie {
    if (t.root) |root| clearEditable(root);
    return newTrie(kind, t.*);
}

/// Returns a new collection of `kind` equal to `src` with `entry` added, or
/// with the value of the entry that has its key replaced.
///
/// This function cannot raise. `entry` is as many values as `kind` says, the
/// key first. The key must not be nil or NaN and a map's value must not be
/// nil, and either is illegal behaviour. The new collection shares every node
/// with `src` except those on the path to the entry.
pub fn put(src: *const Trie, kind: Kind, entry: []const repr.Value) *Trie {
    std.debug.assert(entry.len == kind.entryWidth());
    var built = src.*;
    putEntry(&built, kind, entry, .persistent);
    return newTrie(kind, built);
}

/// Returns a new collection of `kind` equal to `src` without the entry whose
/// key is `key`.
///
/// This function cannot raise. Where there is no such entry, the new
/// collection is equal to `src` and shares its trie.
pub fn remove(src: *const Trie, kind: Kind, key: repr.Value) *Trie {
    var built = src.*;
    removeKey(&built, kind, key, .persistent);
    return newTrie(kind, built);
}

/// Returns the payload of `x` if `x` is a collection of `kind`, and null
/// otherwise.
pub fn toTrie(x: repr.Value, kind: Kind) ?*Trie {
    if (!repr.checkType(x, repr.Tag.abstract)) return null;
    const payload = wrap.toAbstract(x);
    if (abi.abstractHead(payload).type != kind.abstractType()) return null;
    return @ptrCast(@alignCast(payload));
}

/// Adds `entry` to `t` in place, or replaces the value of the entry that has
/// its key.
///
/// This function cannot raise. `entry` is as many values as `kind` says, the
/// key first. The key must not be nil or NaN and a map's value must not be
/// nil, and either is illegal behaviour. `t` must be a transient's, since the
/// update changes the nodes it has made.
pub fn transientPut(t: *Trie, kind: Kind, entry: []const repr.Value) void {
    std.debug.assert(entry.len == kind.entryWidth());
    putEntry(t, kind, entry, .transient);
}

/// Removes the entry whose key is `key` from `t` in place, if there is one.
///
/// This function cannot raise. `t` must be a transient's, since the update
/// changes the nodes it has made.
pub fn transientRemove(t: *Trie, kind: Kind, key: repr.Value) void {
    removeKey(t, kind, key, .transient);
}

// ==========================================================================
// Private functions
// ==========================================================================

/// Allocates a node of `kind` for `len` entries and the children `nodemap`
/// names, and makes every slot valid.
fn allocate(kind: Kind, len: u32, nodemap: u32) *Node {
    const child_count: usize = @popCount(nodemap);
    const offset = childOffset(kind, len);
    // A collision node's length is not bounded by the bitmap, so the size is
    // checked as `gcallocWithPayload` checks the payload it adds.
    const child_bytes = child_count * @sizeOf(?*abi.GCObject);
    const size = std.math.add(usize, offset, child_bytes) catch fatal.outOfMemory();
    const node: *Node = @ptrCast(@alignCast(gc_alloc.gcallocBytes(kind.memoryType(), size)));
    node.* = .{ .gc = node.gc, .nodemap = nodemap, .len = len };
    @memset(entries(node), wrap.fromNil());
    @memset(children(node), null);
    return node;
}

/// Returns `node` with `entry` added, where `node` does not already hold its
/// key, and records what changed in `change`.
///
/// `shift` is the bit position `node`'s slots are read from and `hash` the
/// hash of `entry`'s key. The result is the node the parent refers to in
/// `node`'s place, which is `node` itself where nothing changed or where the
/// change was made in place.
fn assocIn(kind: Kind, node: *Node, shift: u32, hash: u32, entry: []const repr.Value, mode: Mode, change: *Change) *Node {
    const w = kind.entryWidth();
    if (isCollision(node)) {
        if (node.hash == hash) {
            const items = entries(node);
            var pos: usize = 0;
            while (pos < node.len) : (pos += 1) {
                const key = items[pos * w];
                if (order.equals(entry[0], key)) return replaceValue(kind, node, pos, entry, mode, change);
                if (order.compare(entry[0], key) < 0) break;
            }
            change.added = true;
            return withCollisionEntry(kind, node, pos, entry, mode);
        }
        // A key with another hash cannot share this node, so the node gains a
        // parent at this level and the entry is added to the parent.
        const parent = newNodeFor(kind, 0, bitpos(node.hash, shift), mode);
        children(parent)[0] = &node.gc;
        return assocIn(kind, parent, shift, hash, entry, mode, change);
    }

    const bit = bitpos(hash, shift);
    if (node.datamap & bit != 0) {
        const i = dataIndex(node, bit);
        const existing = entries(node)[i * w ..][0..w];
        if (order.equals(entry[0], existing[0])) return replaceValue(kind, node, i, entry, mode, change);
        const child = merge(kind, shift + bits, existing, keyHash(existing[0]), entry, hash, mode);
        change.added = true;
        return promote(kind, node, bit, child, mode);
    }
    if (node.nodemap & bit != 0) {
        const ci = childIndex(node, bit);
        const child = asNode(children(node)[ci].?);
        const updated = assocIn(kind, child, shift + bits, hash, entry, mode, change);
        if (updated == child) return node;
        return withChild(node, ci, updated, mode);
    }
    change.added = true;
    return withEntry(kind, node, bit, entry, mode);
}

/// The slot bit `hash` selects at `shift`.
inline fn bitpos(hash: u32, shift: u32) u32 {
    std.debug.assert(shift < 32);
    return @as(u32, 1) << @as(u5, @truncate(hash >> @as(u5, @intCast(shift))));
}

/// `disj`: a new set without the elements.
fn cfunDisj(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, -1);
    const src = try args_core.getAbstract(Trie, argv, 0, &set_type);
    var built = src.*;
    for (argv[1..]) |x| removeKey(&built, .set, x, .persistent);
    return result(argv[0], src, built, .set);
}

/// `dissoc`: a new map without the keys.
fn cfunDissoc(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, -1);
    const src = try args_core.getAbstract(Trie, argv, 0, &map_type);
    var built = src.*;
    for (argv[1..]) |key| removeKey(&built, .map, key, .persistent);
    return result(argv[0], src, built, .map);
}

/// `hash-map`: a map of the key-value pairs in the arguments.
fn cfunHashMap(argv: []repr.Value) raise.Error!repr.Value {
    if (argv.len % 2 != 0) {
        return pp_format.panicf("expected an even number of keys and values, got %d", .{@as(i32, @intCast(argv.len))});
    }
    var i: usize = 0;
    while (i < argv.len) : (i += 2) try checkKey(argv[i]);
    // The trie is built in place, since no collection refers to its nodes
    // until the abstract is made after the last pair.
    var built: Trie = .{};
    i = 0;
    while (i < argv.len) : (i += 2) {
        if (repr.checkType(argv[i + 1], repr.Tag.nil)) {
            removeKey(&built, .map, argv[i], .fresh);
        } else {
            putEntry(&built, .map, argv[i..][0..2], .fresh);
        }
    }
    return wrap.fromAbstract(newTrie(.map, built));
}

/// `hash-set`: a set of the arguments.
fn cfunHashSet(argv: []repr.Value) raise.Error!repr.Value {
    for (argv) |x| try checkKey(x);
    // Built in place, as `hash-map` builds.
    var built: Trie = .{};
    for (argv) |x| putEntry(&built, .set, &.{x}, .fresh);
    return wrap.fromAbstract(newTrie(.set, built));
}

/// The index among `node`'s children of the child in slot `bit`.
inline fn childIndex(node: *const Node, bit: u32) usize {
    return @popCount(node.nodemap & (bit - 1));
}

/// The offset from the start of a node of `kind` with `len` entries to its
/// first child slot.
fn childOffset(kind: Kind, len: u32) usize {
    const values = std.math.mul(usize, len, kind.entryWidth()) catch fatal.outOfMemory();
    const bytes = std.math.mul(usize, values, @sizeOf(repr.Value)) catch fatal.outOfMemory();
    return std.math.add(usize, @offsetOf(Node, "_entries"), bytes) catch fatal.outOfMemory();
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

/// Allocates a copy of `node`, editable where `editable` is true.
fn copyNode(node: *Node, editable: bool) *Node {
    const kind = kindOfNode(node);
    const copy = if (isCollision(node))
        newCollision(kind, node.hash, node.len)
    else
        newNode(kind, node.datamap, node.nodemap);
    @memcpy(entries(copy), entries(node));
    @memcpy(children(copy), children(node));
    if (editable) copy.gc.flags.own |= own_editable;
    return copy;
}

/// The index among `node`'s entries of the entry in slot `bit`.
inline fn dataIndex(node: *const Node, bit: u32) usize {
    return @popCount(node.datamap & (bit - 1));
}

/// Returns a copy of `node` with the child in slot `bit` replaced by `entry`,
/// which was that child's only entry.
fn demote(kind: Kind, node: *Node, bit: u32, entry: []const repr.Value, mode: Mode) *Node {
    const w = kind.entryWidth();
    const i = dataIndex(node, bit);
    const ci = childIndex(node, bit);
    const result_node = newNodeFor(kind, node.datamap | bit, node.nodemap & ~bit, mode);
    insertInto(entries(result_node), entries(node), i * w, entry);
    removeFrom(children(result_node), children(node), ci, 1);
    return result_node;
}

/// Describes the values of `node`'s entries, and then those of its children.
fn describeNode(buffer: *buffers.Buffer, node: *Node, first: *bool) raise.Error!void {
    for (entries(node)) |x| {
        if (!first.*) try buffers.pushU8(buffer, ' ');
        first.* = false;
        try pp.descriptionB(buffer, x);
    }
    for (children(node)) |slot| try describeNode(buffer, asNode(slot.?), first);
}

/// Describes every value of every entry of `t` into `render`, in the order
/// `next` gives the entries, separated by spaces.
fn describeTrie(t: *Trie, render: *abi.Render) raise.Error!void {
    const buffer: *buffers.Buffer = @ptrCast(@alignCast(render));
    var first = true;
    // Nodes do not change, so a node stays valid across the allocations and
    // callbacks describing a value can make.
    if (t.root) |root| try describeNode(buffer, root, &first);
}

/// Returns `node` with the entry whose key is `key` removed, and records what
/// changed in `change`.
///
/// The result is the node the parent refers to in `node`'s place, which is
/// `node` itself where the key is absent or the change was made in place. A
/// result that is not the root may be left with a single entry and nothing
/// else, which the parent then moves into itself.
fn dissocIn(kind: Kind, node: *Node, shift: u32, hash: u32, key: repr.Value, mode: Mode, change: *Change) *Node {
    const w = kind.entryWidth();
    if (isCollision(node)) {
        if (node.hash != hash) return node;
        const items = entries(node);
        for (0..node.len) |i| {
            if (!order.equals(key, items[i * w])) continue;
            recordRemoval(change, items[i * w ..][0..w]);
            return withoutCollisionEntry(kind, node, i, mode);
        }
        return node;
    }

    const bit = bitpos(hash, shift);
    if (node.datamap & bit != 0) {
        const i = dataIndex(node, bit);
        const entry = entries(node)[i * w ..][0..w];
        if (!order.equals(key, entry[0])) return node;
        recordRemoval(change, entry);
        return withoutEntry(kind, node, bit, mode);
    }
    if (node.nodemap & bit != 0) {
        const ci = childIndex(node, bit);
        const child = asNode(children(node)[ci].?);
        const updated = dissocIn(kind, child, shift + bits, hash, key, mode, change);
        if (!change.removed) return node;
        if (updated.len == 1 and updated.nodemap == 0) {
            return demote(kind, node, bit, entries(updated), mode);
        }
        var replacement = updated;
        if (!isCollision(updated) and updated.len == 0 and @popCount(updated.nodemap) == 1) {
            const only = asNode(children(updated)[0].?);
            if (isCollision(only)) replacement = only;
        }
        if (replacement == child) return node;
        return withChild(node, ci, replacement, mode);
    }
    return node;
}

/// The first entry under `node`: its own first entry, or its first child's.
fn firstEntry(node_in: *Node) []repr.Value {
    var node = node_in;
    const w = kindOfNode(node).entryWidth();
    while (node.len == 0) node = asNode(children(node)[0].?);
    return entries(node)[0..w];
}

/// Copies `src` into `dest` with `inserted` placed at `at`. `dest` is exactly
/// as long as the two together.
fn insertInto(dest: anytype, src: anytype, at: usize, inserted: anytype) void {
    const n = inserted.len;
    @memcpy(dest[0..at], src[0..at]);
    @memcpy(dest[at..][0..n], inserted);
    @memcpy(dest[at + n ..], src[at..]);
}

/// Whether `node` is a collision node.
inline fn isCollision(node: *const Node) bool {
    return node.gc.flags.own & own_collision != 0;
}

/// Whether `node` has `own_editable` set.
inline fn isEditable(node: *const Node) bool {
    return node.gc.flags.own & own_editable != 0;
}

/// The hash a key is placed by.
inline fn keyHash(key: repr.Value) u32 {
    return @bitCast(order.hash(key));
}

/// The kind of a node already known to be a trie node.
inline fn kindOfNode(node: *const Node) Kind {
    return kindOf(&node.gc).?;
}

/// `core/map`'s `get` callback: the value at `key`, or nil.
///
/// A missing key is reported as found with nil, so `in` gives nil for it as it
/// does for a struct.
fn mapGet(t: *Trie, key: repr.Value) raise.Error!?repr.Value {
    const entry = find(t, .map, key) orelse return wrap.fromNil();
    return entry[1];
}

/// `core/map`'s `next` callback: the key after `key`.
fn mapNext(t: *Trie, key: repr.Value) raise.Error!repr.Value {
    const entry = nextEntry(t, .map, key) orelse return wrap.fromNil();
    return entry[0];
}

/// `core/map`'s `tostring` callback: each key and value described, separated
/// by spaces.
fn mapTostring(t: *Trie, render: *abi.Render) raise.Error!void {
    try describeTrie(t, render);
}

/// Returns a new subtree holding two entries whose keys differ, placed from
/// `shift` down.
fn merge(kind: Kind, shift: u32, a: []const repr.Value, hash_a: u32, b: []const repr.Value, hash_b: u32, mode: Mode) *Node {
    const w = kind.entryWidth();
    if (hash_a == hash_b) {
        const node = newCollisionFor(kind, hash_a, 2, mode);
        const a_first = order.compare(a[0], b[0]) < 0;
        @memcpy(entries(node)[0..w], if (a_first) a else b);
        @memcpy(entries(node)[w..], if (a_first) b else a);
        return node;
    }
    const bit_a = bitpos(hash_a, shift);
    const bit_b = bitpos(hash_b, shift);
    if (bit_a == bit_b) {
        const child = merge(kind, shift + bits, a, hash_a, b, hash_b, mode);
        const node = newNodeFor(kind, 0, bit_a, mode);
        children(node)[0] = &child.gc;
        return node;
    }
    const node = newNodeFor(kind, bit_a | bit_b, 0, mode);
    @memcpy(entries(node)[0..w], if (bit_a < bit_b) a else b);
    @memcpy(entries(node)[w..], if (bit_a < bit_b) b else a);
    return node;
}

/// Allocates a collision node, editable where `mode` is `transient`.
fn newCollisionFor(kind: Kind, hash: u32, len: u32, mode: Mode) *Node {
    const node = newCollision(kind, hash, len);
    if (mode == .transient) node.gc.flags.own |= own_editable;
    return node;
}

/// Allocates a bitmap node, editable where `mode` is `transient`.
fn newNodeFor(kind: Kind, datamap: u32, nodemap: u32, mode: Mode) *Node {
    const node = newNode(kind, datamap, nodemap);
    if (mode == .transient) node.gc.flags.own |= own_editable;
    return node;
}

/// Allocates a map or a set with the contents of `built`.
fn newTrie(kind: Kind, built: Trie) *Trie {
    const payload: *Trie = @ptrCast(@alignCast(abstracts.newBytes(kind.abstractType(), @sizeOf(Trie))));
    payload.* = built;
    return payload;
}

/// Returns the entry after the one whose key is `key` in `t`, the first entry
/// where `key` is nil, or null where there is none.
fn nextEntry(t: *const Trie, kind: Kind, key: repr.Value) ?[]repr.Value {
    const root = t.root orelse return null;
    if (repr.checkType(key, repr.Tag.nil)) return firstEntry(root);
    return switch (seekNext(kind, root, 0, keyHash(key), key)) {
        .found => |entry| entry,
        .absent, .last => null,
    };
}

/// Returns the node `node` or a copy of it, whichever an update in `mode` may
/// change.
fn ownNode(node: *Node, mode: Mode) *Node {
    return switch (mode) {
        .fresh => node,
        .persistent => copyNode(node, false),
        .transient => if (isEditable(node)) node else copyNode(node, true),
    };
}

/// Returns a copy of `node` with the entry in slot `bit` replaced by `child`,
/// the subtree that now holds that entry and another.
fn promote(kind: Kind, node: *Node, bit: u32, child: *Node, mode: Mode) *Node {
    const w = kind.entryWidth();
    const i = dataIndex(node, bit);
    const ci = childIndex(node, bit);
    const result_node = newNodeFor(kind, node.datamap & ~bit, node.nodemap | bit, mode);
    removeFrom(entries(result_node), entries(node), i * w, w);
    const inserted = [1]?*abi.GCObject{&child.gc};
    insertInto(children(result_node), children(node), ci, &inserted);
    return result_node;
}

/// Adds `entry` to `t`, or replaces the value of the entry with its key,
/// treating the nodes it changes as `mode` says, and keeps `count` and `sum`
/// current.
fn putEntry(t: *Trie, kind: Kind, entry: []const repr.Value, mode: Mode) void {
    const hash = keyHash(entry[0]);
    var change: Change = .{};
    if (t.root) |root| {
        t.root = assocIn(kind, root, 0, hash, entry, mode, &change);
    } else {
        const node = newNodeFor(kind, bitpos(hash, 0), 0, mode);
        @memcpy(entries(node), entry);
        t.root = node;
        change.added = true;
    }
    if (change.added) {
        t.count += 1;
        t.sum +%= term(kind, entry);
    } else if (change.replaced) |old| {
        const before = [2]repr.Value{ entry[0], old };
        t.sum = t.sum -% term(kind, &before) +% term(kind, entry);
    }
}

/// Records in `change` that `entry` was removed.
fn recordRemoval(change: *Change, entry: []const repr.Value) void {
    change.removed = true;
    @memcpy(change.gone[0..entry.len], entry);
}

/// Copies `src` into `dest` without the `n` items at `at`. `dest` is exactly
/// `n` shorter than `src`.
fn removeFrom(dest: anytype, src: anytype, at: usize, n: usize) void {
    @memcpy(dest[0..at], src[0..at]);
    @memcpy(dest[at..], src[at + n ..]);
}

/// Removes the entry whose key is `key` from `t`, if there is one, treating
/// the nodes it changes as `mode` says, and keeps `count` and `sum` current.
fn removeKey(t: *Trie, kind: Kind, key: repr.Value, mode: Mode) void {
    const root = t.root orelse return;
    var change: Change = .{};
    const updated = dissocIn(kind, root, 0, keyHash(key), key, mode, &change);
    if (!change.removed) return;
    t.count -= 1;
    t.sum -%= term(kind, change.gone[0..kind.entryWidth()]);
    t.root = if (updated.len == 0 and updated.nodemap == 0) null else updated;
}

/// Returns `node` with the value of its entry at `index` replaced by
/// `entry`'s, for a map, and `node` unchanged for a set, whose entry is its
/// key alone.
fn replaceValue(kind: Kind, node: *Node, index: usize, entry: []const repr.Value, mode: Mode, change: *Change) *Node {
    if (kind == .set) return node;
    const old = entries(node)[index * 2 + 1];
    change.replaced = old;
    const owned = ownNode(node, mode);
    entries(owned)[index * 2 + 1] = entry[1];
    return owned;
}

/// The value an update returns: the collection it was given, where nothing
/// changed, or a new one with the contents of `built`.
fn result(original: repr.Value, src: *const Trie, built: Trie, kind: Kind) repr.Value {
    if (built.root == src.root) return original;
    return wrap.fromAbstract(newTrie(kind, built));
}

/// Finds the entry after the one whose key is `key` in the subtree under
/// `node`, in the order entries come before children.
fn seekNext(kind: Kind, node: *Node, shift: u32, hash: u32, key: repr.Value) Seek {
    const w = kind.entryWidth();
    if (isCollision(node)) {
        if (node.hash != hash) return .absent;
        const items = entries(node);
        for (0..node.len) |i| {
            if (!order.equals(key, items[i * w])) continue;
            if (i + 1 < node.len) return .{ .found = items[(i + 1) * w ..][0..w] };
            return .last;
        }
        return .absent;
    }

    const bit = bitpos(hash, shift);
    const kids = children(node);
    if (node.datamap & bit != 0) {
        const i = dataIndex(node, bit);
        const items = entries(node);
        if (!order.equals(key, items[i * w])) return .absent;
        if (i + 1 < node.len) return .{ .found = items[(i + 1) * w ..][0..w] };
        if (kids.len > 0) return .{ .found = firstEntry(asNode(kids[0].?)) };
        return .last;
    }
    if (node.nodemap & bit != 0) {
        const ci = childIndex(node, bit);
        const found = seekNext(kind, asNode(kids[ci].?), shift + bits, hash, key);
        if (found != .last) return found;
        if (ci + 1 < kids.len) return .{ .found = firstEntry(asNode(kids[ci + 1].?)) };
        return .last;
    }
    return .absent;
}

/// `core/set`'s `get` callback: the element equal to `key`, or nil.
///
/// A missing element is reported as found with nil, for the reason `mapGet`
/// gives.
fn setGet(t: *Trie, key: repr.Value) raise.Error!?repr.Value {
    const entry = find(t, .set, key) orelse return wrap.fromNil();
    return entry[0];
}

/// `core/set`'s `next` callback: the element after `key`.
fn setNext(t: *Trie, key: repr.Value) raise.Error!repr.Value {
    const entry = nextEntry(t, .set, key) orelse return wrap.fromNil();
    return entry[0];
}

/// `core/set`'s `tostring` callback: each element described, separated by
/// spaces.
fn setTostring(t: *Trie, render: *abi.Render) raise.Error!void {
    try describeTrie(t, render);
}

/// The term the entry `entry` adds to a collection's `sum`.
///
/// A term depends on the entry and not on where it is, so two tries with equal
/// entries have one sum. A map's term mixes the value's hash through a
/// finalizer before the key's, so an entry and one with its key and value
/// swapped give different terms.
fn term(kind: Kind, entry: []const repr.Value) u32 {
    const key: u32 = @bitCast(order.hash(entry[0]));
    return switch (kind) {
        .set => vectors.fmix32(key),
        .map => vectors.fmix32(key ^ vectors.fmix32(@as(u32, @bitCast(order.hash(entry[1]))) +% 0x9e3779b9)),
    };
}

/// `core/map`'s and `core/set`'s `hash` callback: the count mixed with the
/// running sum.
fn trieHash(t: *const Trie, _: usize) i32 {
    return @bitCast(value.hashMix(@truncate(t.count), t.sum));
}

/// `core/map`'s and `core/set`'s `length` callback.
fn trieLength(t: *Trie, _: usize) raise.Error!usize {
    return t.count;
}

/// `core/map`'s and `core/set`'s `gcmark` callback: the trie.
fn trieMark(t: *Trie, _: usize) void {
    mark(t);
}

/// Returns a copy of `node` with `child` in place of its child at `index`, or
/// `node` itself changed where `mode` allows.
fn withChild(node: *Node, index: usize, child: *Node, mode: Mode) *Node {
    const owned = ownNode(node, mode);
    children(owned)[index] = &child.gc;
    return owned;
}

/// Returns a copy of the collision node `node` with `entry` inserted at
/// `index`.
fn withCollisionEntry(kind: Kind, node: *Node, index: usize, entry: []const repr.Value, mode: Mode) *Node {
    const w = kind.entryWidth();
    const result_node = newCollisionFor(kind, node.hash, node.len + 1, mode);
    insertInto(entries(result_node), entries(node), index * w, entry);
    return result_node;
}

/// Returns a copy of the bitmap node `node` with `entry` in slot `bit`.
fn withEntry(kind: Kind, node: *Node, bit: u32, entry: []const repr.Value, mode: Mode) *Node {
    const w = kind.entryWidth();
    const i = dataIndex(node, bit);
    const result_node = newNodeFor(kind, node.datamap | bit, node.nodemap, mode);
    insertInto(entries(result_node), entries(node), i * w, entry);
    @memcpy(children(result_node), children(node));
    return result_node;
}

/// Returns a copy of the collision node `node` without its entry at `index`.
fn withoutCollisionEntry(kind: Kind, node: *Node, index: usize, mode: Mode) *Node {
    const w = kind.entryWidth();
    const result_node = newCollisionFor(kind, node.hash, node.len - 1, mode);
    removeFrom(entries(result_node), entries(node), index * w, w);
    return result_node;
}

/// Returns a copy of the bitmap node `node` without the entry in slot `bit`.
fn withoutEntry(kind: Kind, node: *Node, bit: u32, mode: Mode) *Node {
    const w = kind.entryWidth();
    const i = dataIndex(node, bit);
    const result_node = newNodeFor(kind, node.datamap & ~bit, node.nodemap, mode);
    removeFrom(entries(result_node), entries(node), i * w, w);
    @memcpy(children(result_node), children(node));
    return result_node;
}

// ==========================================================================
// Tests
// ==========================================================================

// `children` places the child slots directly after the entries, which is
// aligned for a child pointer only if a value's alignment is at least a
// pointer's.
comptime {
    std.debug.assert(@alignOf(repr.Value) >= @alignOf(?*abi.GCObject));
    std.debug.assert(@offsetOf(Node, "_entries") % @alignOf(repr.Value) == 0);
}
