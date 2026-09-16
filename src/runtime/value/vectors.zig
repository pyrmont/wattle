//! `core/vector`: the persistent vector, a trie of 32-way nodes with a tail.
//!
//! A vector's nodes are collector blocks of their own memory types. An
//! _inner node_ is a `vector_inner` block and has 32 child pointers. A _leaf_
//! is a `vector_leaf` block and has 32 elements. `newInner` and `newLeaf`
//! allocate them. `gc/mark.zig`'s `markNode` marks a node and everything under
//! it, and `gc/sweep.zig` frees an unreachable node with no finalizer.
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
//! - A node is not changed once a persistent vector refers to it. A node a
//!   transient made has `own_editable` set, and only such a node is changed in
//!   place.

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const gc_alloc = @import("../gc.zig");
const repr = @import("repr");
const wrap = @import("helpers/wrap.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// Bit 0 of the collector header's per-type field: a transient made the node
/// and may change it in place.
pub const own_editable: u6 = 1;

/// The number of slots in a node.
pub const width = 32;

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

// ==========================================================================
// Public functions
// ==========================================================================

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
