//! The growable vector — `src/core/vector.h`'s `janet_v_*` family — and the
//! one place its arithmetic is written down.
//!
//! A vector is a bare `?[*]T` with a two-word `i32` prefix sitting *behind*
//! the elements: capacity in word 0, count in word 1. `null` is an empty
//! vector that has never been grown, which is why every reader here takes the
//! optional rather than asking its caller to unwrap. The memory is the
//! scratch allocator's, not the collector's, so a vector is freed explicitly
//! and is never wrapped in a `Value`.
//!
//! ## Why there is a typed surface here
//!
//! `janet_v_push`, `janet_v_count`, `janet_v_capacity`, `janet_v_empty` and
//! `janet_v_free` are function-like C macros over an lvalue, which no
//! translation carries across -- so every caller had to write the four lines
//! of prefix arithmetic out. Six subsystems did:
//! prefix arithmetic out. Six subsystems did: `marsh.zig`, `compiler.zig`,
//! `peg.zig`, `compiler/emit.zig`, `compiler/specials.zig` and
//! `compiler/optimize.zig` each carried a private copy, twenty-eight function
//! definitions between them and six separate declarations of the prefix size,
//! with eleven further sites doing `@intFromPtr(v) - vector_header_size` by
//! hand. `test/harness.zig` carried a seventh set for the contracts.
//!
//! They are one now. `vGrow` and `vFlattenmem` were always shared; what was
//! copied is the *typing* around them, which is exactly the part a header
//! cannot express in C and Zig can.
//!
//! **`test/vector.zig` restates this arithmetic**, and that is deliberate:
//! it is the contract on it, so both sides of the comparison have to come
//! from different files. Converting it would check this file against itself.
//!
//! ## The element type is spelled at every call
//!
//! `count(u32, v)` rather than `count(v)`. The pointer alone does determine
//! the element, so `anytype` would work and read shorter. Spelling the type
//! catches an element-type *mismatch* and puts the intended element in front
//! of the reader at the call site.
//!
//! **It does not encode provenance, and saying so would be wrong.** An
//! arbitrary `[*]u32` satisfies `count(u32, ptr)` exactly as a real vector
//! does, and the function will read the two words before it either way. A
//! bare many-item pointer cannot carry the fact that something allocated a
//! hidden prefix behind it; only an owning or branded value could, and none of
//! these functions takes one.

const gc_alloc = @import("gc.zig");
const utils = @import("utils.zig");
const fatal = @import("fatal.zig");

pub const header_words = 2;
pub const header_size = header_words * @sizeOf(i32);

// ---------------------------------------------------------------------------
// The allocation half, which was always shared
// ---------------------------------------------------------------------------

pub fn vGrow(
    vector: ?*anyopaque,
    increment: i32,
    item_size: i32,
) callconv(.c) ?*anyopaque {
    const current_capacity = if (vector) |v| rawWords(v)[0] else 0;
    const current_count = if (vector) |v| rawWords(v)[1] else 0;
    const doubled_capacity = current_capacity *% 2;
    const minimum_capacity = current_count +% increment;
    const new_capacity = @max(doubled_capacity, minimum_capacity);
    const allocation_size = @as(usize, @intCast(item_size)) *%
        @as(usize, @intCast(new_capacity)) +% header_size;

    const allocation = gc_alloc.srealloc(
        if (vector) |v| @ptrFromInt(@intFromPtr(v) - header_size) else null,
        allocation_size,
    ) orelse {
        fatal.outOfMemory();
    };
    const words: [*]i32 = @ptrCast(@alignCast(allocation));
    words[0] = new_capacity;
    if (vector == null) words[1] = 0;
    return @ptrCast(&words[header_words]);
}

pub fn vFlattenmem(vector: ?*anyopaque, item_size: i32) ?*anyopaque {
    const source = vector orelse return null;
    const count_of = rawWords(source)[1];
    const size = @as(usize, @intCast(item_size)) *% @as(usize, @intCast(count_of));
    const allocation = utils.malloc(size) orelse {
        fatal.outOfMemory();
    };

    const destination_bytes: [*]u8 = @ptrCast(allocation);
    const source_bytes: [*]const u8 = @ptrCast(source);
    @memcpy(destination_bytes[0..size], source_bytes[0..size]);
    return allocation;
}

fn rawWords(vector: *anyopaque) [*]i32 {
    return @ptrFromInt(@intFromPtr(vector) - header_size);
}

// ---------------------------------------------------------------------------
// The typed half, which was copied six times
// ---------------------------------------------------------------------------

/// The prefix behind the elements. Private: a caller that wants word 0 or
/// word 1 wants `capacity` or `count`, and a caller that wants anything else
/// is reading a layout this file owns.
fn header(comptime T: type, vector: [*]T) [*]i32 {
    return @ptrFromInt(@intFromPtr(vector) - header_size);
}

/// `janet_v_count`, which answers zero for a vector that was never grown.
pub fn count(comptime T: type, vector: ?[*]T) i32 {
    return if (vector) |v| header(T, v)[1] else 0;
}

/// `janet_v_capacity`, zero for a vector that was never grown.
pub fn capacity(comptime T: type, vector: ?[*]T) i32 {
    return if (vector) |v| header(T, v)[0] else 0;
}

/// The count written directly. `janet_v_empty` is `setCount(T, v, 0)` and the
/// two assembler paths that truncate a buffer are the other callers; nothing
/// else has a reason to say a length the elements do not already have.
pub fn setCount(comptime T: type, vector: ?[*]T, n: i32) void {
    if (vector) |v| header(T, v)[1] = n;
}

/// `janet_v_push`: grow if the next element would not fit, then store it and
/// advance the count.
///
/// It takes the vector *variable*, because growing it moves the allocation.
/// The growth test is the C macro's — `count + 1 >= capacity`, which leaves
/// one slot spare rather than filling the last — and is reproduced rather
/// than tightened.
pub fn push(comptime T: type, vector: *?[*]T, val: T) void {
    var items = vector.*;
    const at = count(T, items);
    if (items == null or at + 1 >= capacity(T, items)) {
        const grown = vGrow(if (items) |v| @ptrCast(v) else null, 1, @sizeOf(T));
        items = @ptrCast(@alignCast(grown));
        vector.* = items;
    }
    items.?[@intCast(at)] = val;
    header(T, items.?)[1] = at + 1;
}

/// `janet_v_free`, which is `janet_sfree` on the prefix rather than on the
/// elements. A no-op on a vector that was never grown.
pub fn free(comptime T: type, vector: ?[*]T) void {
    if (vector) |v| gc_alloc.sfree(header(T, v));
}

/// `janet_v_flatten`: the elements alone, in `janet_malloc`ed memory, with no
/// prefix and no capacity. Answers null for a vector that was never grown.
pub fn flatten(comptime T: type, vector: ?[*]T) ?[*]T {
    const opaque_vector: ?*anyopaque = if (vector) |v| @ptrCast(v) else null;
    return @ptrCast(@alignCast(vFlattenmem(opaque_vector, @sizeOf(T))));
}

/// The elements as a slice, which is what a reader almost always wants.
///
/// **Two cases answer the empty slice rather than trapping**, and they are
/// `gc/mark.zig`'s two: a null pointer is an empty vector, and a count that
/// has been driven below zero — `setCount` is public and the assembler uses
/// it — would trap on `@intCast` where the C loop simply ran zero times.
pub fn slice(comptime T: type, vector: ?[*]T) []T {
    const n = count(T, vector);
    if (n <= 0) return &.{};
    return vector.?[0..@intCast(n)];
}
