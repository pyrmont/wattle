//! The growable vector: `std.ArrayListUnmanaged` over the **scratch**
//! allocator, plus the three conventions the standard container does not carry.
//!
//! **Which allocator is a correctness question, not a preference.** The three
//! users are the compiler, the PEG builder and the marshaller, and each can
//! raise between allocating a vector and freeing it -- `compiler.zig`'s
//! `compileLintImpl` reaches `deinitCompiler` only if `valueImpl` returns, and a
//! macro that panics is the ordinary way a compile error is reported from Janet
//! code. The scratch sweep at the end of a collection is what reclaims a failed
//! compile's vectors; over `utils.heap` that would be one leak per compile
//! error. So: **`utils.heap` for memory the runtime owns and frees,
//! `gc.scratch_heap` for memory a raise may abandon.**
//!
//! `push`, `pushN` and `ensure` exist because Janet aborts on allocation
//! failure where `std`'s containers report it, and `catch fatal.outOfMemory()`
//! written thirty times is worse than written once. `free` exists so the
//! allocator choice is made in one place rather than at each `deinit`.
//! `flatten` has no standard equivalent: it copies the elements into plain heap
//! memory, which is where a funcdef's payload has to live. Everything else is
//! the standard container's own surface -- `.items.len`, `.items`, `.capacity`,
//! and `.shrinkRetainingCapacity(n)` for the truncation the assembler paths do.
//!
//! **`test/vector.zig` is the contract**, and it pins what this file is
//! responsible for: that growth goes through the scratch allocator and occupies
//! one scratch table entry rather than accumulating them, that a block
//! abandoned by a raise is reclaimed by the next collection, and that `free`
//! removes the entry.

const std = @import("std");
const gc_alloc = @import("gc.zig");
const utils = @import("utils.zig");
const fatal = @import("fatal.zig");

/// A vector, spelled once so a reader of a struct field knows which allocator
/// it belongs to without following the pushes.
pub fn Vector(comptime T: type) type {
    return std.ArrayListUnmanaged(T);
}

/// The element type of a `*Vector(T)`, so that `push(&v, .{ ... })` gives the
/// literal a type to be. `anytype` would leave it an anonymous struct and the
/// error would name this file rather than the call.
fn Elem(comptime List: type) type {
    return std.meta.Elem(@typeInfo(List).pointer.child.Slice);
}

/// Append one element over the scratch heap, aborting on allocation failure.
pub fn push(list: anytype, value: Elem(@TypeOf(list))) void {
    list.append(gc_alloc.scratch_heap, value) catch fatal.outOfMemory();
}

/// `n` copies of one value: the shape a caller wants when it reserves slots a
/// later pass overwrites, as the PEG compiler does for its arguments. One call
/// grows the vector once where a loop of `push` grows it as many times as the
/// growth policy decides.
pub fn pushN(list: anytype, value: Elem(@TypeOf(list)), n: usize) void {
    list.appendNTimes(gc_alloc.scratch_heap, value, n) catch fatal.outOfMemory();
}

/// Room for `n` elements without growing again.
pub fn ensure(list: anytype, n: usize) void {
    list.ensureTotalCapacity(gc_alloc.scratch_heap, n) catch fatal.outOfMemory();
}

/// Release the vector. A no-op on one that was never grown.
///
/// **It leaves the vector empty rather than `undefined`**, which is what makes
/// a second free a no-op and a later read see an empty vector. `deinit` on its
/// own ends with `self.* = undefined`, and callers depend on the weaker state:
/// `compiler/specials.zig` frees `named_parameters` on one path and reaches
/// `cleanupFunctionError` -- which frees it again -- on another. Resetting
/// here holds that for all eight call sites at once; `deinit` is still what
/// releases the block.
pub fn free(list: anytype) void {
    list.deinit(gc_alloc.scratch_heap);
    list.* = .empty;
}

/// The elements alone, in plain heap memory rather than scratch, with no
/// capacity and no owner but the caller. Answers null for an empty vector.
///
/// This is the one operation with no standard equivalent, and the reason is
/// the allocator: `std.ArrayListUnmanaged.toOwnedSlice` would hand back
/// scratch memory, and a
/// funcdef's constants and defs outlive the collection that would sweep it.
pub fn flatten(comptime T: type, list: std.ArrayListUnmanaged(T)) ?[*]T {
    if (list.items.len == 0) return null;
    const size = list.items.len * @sizeOf(T);
    const allocation = utils.malloc(size) orelse fatal.outOfMemory();
    const destination: [*]T = @ptrCast(@alignCast(allocation));
    @memcpy(destination[0..list.items.len], list.items);
    return destination;
}
