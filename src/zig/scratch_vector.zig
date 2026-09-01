//! The growable vector: `std.ArrayListUnmanaged` over the **scratch**
//! allocator, plus the three conventions the standard container does not
//! carry.
//!
//! ## Why scratch, and not `utils.heap`
//!
//! **This is a correctness question, not a preference.** The three users are
//! the compiler, the PEG builder and the marshaller, and every one of them can
//! raise between allocating a vector and freeing it — `compiler.zig`'s
//! `compileLintImpl` reaches `deinitCompiler` only if `valueImpl` returns, and a
//! macro that panics is the ordinary way a compile error is reported from
//! Janet code.
//!
//! So the scratch sweep at the end of a collection is what reclaims a failed
//! compile's vectors. Over `utils.heap` this would be a leak per compile
//! error, and `test/vector.zig` is the contract that says so.
//!
//! `gc.scratch_heap` is that allocator as the standard interface. The rule for
//! choosing between the two: **`utils.heap` for memory the runtime owns and
//! frees, `gc.scratch_heap` for memory a raise may abandon.**
//!
//! ## The conventions this file still carries
//!
//! `push`, `pushN` and `ensure` exist because Janet aborts on allocation
//! failure and `std`'s containers report it — `catch fatal.outOfMemory()`
//! written thirty times is worse than written once. `free` exists so the
//! allocator choice above is made in one place rather than at each `deinit`.
//! `flatten` has no standard equivalent at all: it copies the elements into
//! `janet_malloc` memory, which is where a funcdef's payload has to live.
//!
//! Everything else a caller wants is the standard container's own surface:
//! `.items.len` for the count, `.items` for the slice, `.capacity`, and
//! `.shrinkRetainingCapacity(n)` for the truncation `janet_v_empty` and the
//! two assembler paths do.
//!
//! **`test/vector.zig` is the contract**, and it pins what this file is
//! actually responsible for: that growth goes through `janet_srealloc` and
//! occupies one scratch table entry rather than accumulating them, that a
//! block abandoned by a raise is reclaimed by the next collection, and that
//! `free` removes the entry.

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

/// `janet_v_push`, over the scratch heap, aborting on failure as Janet does.
pub fn push(list: anytype, value: Elem(@TypeOf(list))) void {
    list.append(gc_alloc.scratch_heap, value) catch fatal.outOfMemory();
}

/// `n` copies of one value. The pattern it replaces is a `while` loop pushing
/// a placeholder that a later pass overwrites — the PEG compiler reserves its
/// argument slots this way — and one `appendNTimes` grows once where the loop
/// grew as many times as the policy decided to.
pub fn pushN(list: anytype, value: Elem(@TypeOf(list)), n: usize) void {
    list.appendNTimes(gc_alloc.scratch_heap, value, n) catch fatal.outOfMemory();
}

/// Room for `n` elements without growing again.
pub fn ensure(list: anytype, n: usize) void {
    list.ensureTotalCapacity(gc_alloc.scratch_heap, n) catch fatal.outOfMemory();
}

/// `janet_v_free`. A no-op on a vector that was never grown.
///
/// **It leaves the vector empty rather than `undefined`.** `deinit` ends with
/// `self.* = undefined`, and the C original's callers all wrote `v = NULL`
/// after `janet_v_free(v)` precisely so that a second free was a no-op and a
/// later read saw an empty vector. `compiler/specials.zig` frees
/// `named_parameters` on one path and reaches `cleanupFunctionError` -- which
/// frees it again -- on another. Doing it here keeps that safe by
/// construction instead of at each of the eight call sites, and `deinit` is
/// still what releases the block.
pub fn free(list: anytype) void {
    list.deinit(gc_alloc.scratch_heap);
    list.* = .empty;
}

/// `janet_v_flatten`: the elements alone, in `janet_malloc`ed memory, with no
/// capacity and no owner but the caller. Answers null for an empty vector.
///
/// This is the one operation with no standard equivalent, and the reason is
/// the allocator: `toOwnedSlice` would hand back scratch memory, and a
/// funcdef's constants and defs outlive the collection that would sweep it.
pub fn flatten(comptime T: type, list: std.ArrayListUnmanaged(T)) ?[*]T {
    if (list.items.len == 0) return null;
    const size = list.items.len * @sizeOf(T);
    const allocation = utils.malloc(size) orelse fatal.outOfMemory();
    const destination: [*]T = @ptrCast(@alignCast(allocation));
    @memcpy(destination[0..list.items.len], list.items);
    return destination;
}
