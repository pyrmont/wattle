//! Behavioral contract for the growable vector: `stretchy.zig`'s typed
//! surface, `janet_v_grow` and `janet_v_flattenmem`, and the header
//! arithmetic the macros in `src/core/vector.h` do around them.
//!
//! No Janet program can reach any of this. The vector is the compiler's and
//! the assembler's scratch structure — malloc'd rather than collected, freed
//! explicitly, and never wrapped in a `Janet` — so the only caller that can
//! exercise it is a test that pushes onto one by hand.
//!
//! ## The macros are written out, and that is the point of them
//!
//! `janet_v_push`, `janet_v_count` and `janet_v_flatten` are function-like C
//! macros over an lvalue, and translate-c does not carry one across. So this
//! file restates the four lines of pointer arithmetic they perform — the
//! two-word header sitting *behind* the elements, the capacity in word 0 and
//! the count in word 1 — and then checks `janet_v_grow` against that
//! restatement.
//!
//! Restating is not a loss here, it is closer to what the contract is for. A
//! contract that asserted the same arithmetic through the subject's own
//! helpers could only ever have caught a disagreement between the subject and
//! *itself*. Written out, the two descriptions of the layout come from
//! different files and a drift in either is a failure.
//!
//! **So this file may never be pointed at `stretchy.zig`'s helpers**, however
//! mechanical the substitution looks. That file's `count`, `capacity`, `push`,
//! `setCount`, `free`, `flatten` and `slice` replaced six private copies,
//! which were duplication; this restatement stays because it is the oracle.
//! The second half of `run` below is the other subject: the typed surface,
//! checked against the restatement rather than against itself. Collapsing
//! exactly this distinction elsewhere left a file green and testing nothing.

const std = @import("std");
const gc_alloc = @import("subsystems").gc_alloc;
const utils = @import("subsystems").utils;
const vector_mod = @import("subsystems").stretchy;
const harness = @import("harness.zig");
const vm_lifecycle = @import("subsystems").lifecycle;

/// The header `vector.h` keeps behind the elements: capacity, then count.
const header_words = 2;
const header_size = header_words * @sizeOf(i32);

fn raw(vector: [*]i32) [*]i32 {
    return @ptrFromInt(@intFromPtr(vector) - header_size);
}

/// `janet_v_count`, which answers zero for a vector that was never grown.
fn count(vector: ?[*]i32) i32 {
    return if (vector) |v| raw(v)[1] else 0;
}

fn capacity(vector: [*]i32) i32 {
    return raw(vector)[0];
}

/// `janet_v_push`, split into the grow test and the store so that each is
/// visible. The C macro is one expression and does the same two things.
fn push(vector: *?[*]i32, value: i32) void {
    const needs_growth = if (vector.*) |v|
        raw(v)[1] + 1 >= raw(v)[0]
    else
        true;
    if (needs_growth) {
        vector.* = @ptrCast(@alignCast(vector_mod.vGrow(
            if (vector.*) |v| @ptrCast(v) else null,
            1,
            @sizeOf(i32),
        )));
    }
    const v = vector.*.?;
    raw(v)[1] += 1;
    v[@intCast(raw(v)[1] - 1)] = value;
}

/// `janet_v_free`, which is a no-op on a vector that was never grown.
fn free(vector: ?[*]i32) void {
    if (vector) |v| gc_alloc.sfree(@ptrCast(raw(v)));
}

pub fn run() void {
    var vector: ?[*]i32 = null;

    harness.init();
    std.debug.assert(count(vector) == 0);

    for (0..1024) |i| push(&vector, @as(i32, @intCast(i)) * 3);

    const grown = vector.?;
    std.debug.assert(count(grown) == 1024);
    // The doubling rule, which the C contract could not see: `janet_v_grow`
    // takes the larger of twice the capacity and the count plus the
    // increment, so a vector pushed onto one element at a time never has a
    // capacity below its count.
    std.debug.assert(capacity(grown) >= 1024);
    for (0..1024) |i| std.debug.assert(grown[i] == @as(i32, @intCast(i)) * 3);

    {
        const flattened: [*]i32 = @ptrCast(@alignCast(vector_mod.vFlattenmem(
            @ptrCast(grown),
            @sizeOf(i32),
        ).?));
        for (0..1024) |i| std.debug.assert(flattened[i] == grown[i]);
        utils.free(@ptrCast(flattened));
    }

    // A null vector flattens to null rather than to an empty allocation. The C
    // contract never asked, because `janet_v_flatten(NULL)` reads
    // `sizeof(*(v))` off a null pointer expression and is only well defined
    // because `sizeof` does not evaluate it.
    std.debug.assert(vector_mod.vFlattenmem(null, @sizeOf(i32)) == null);

    free(grown);

    // ---------------------------------------------------------------------
    // The typed surface, against the restatement above
    //
    // Every assertion here reads one side through `stretchy` and the other
    // through this file's own arithmetic.
    // ---------------------------------------------------------------------

    std.debug.assert(vector_mod.count(i32, null) == 0);
    std.debug.assert(vector_mod.capacity(i32, null) == 0);
    std.debug.assert(vector_mod.slice(i32, null).len == 0);

    var typed: ?[*]i32 = null;
    for (0..1024) |i| vector_mod.push(i32, &typed, @as(i32, @intCast(i)) * 7);

    const built = typed.?;
    std.debug.assert(count(built) == 1024);
    std.debug.assert(vector_mod.count(i32, built) == count(built));
    std.debug.assert(vector_mod.capacity(i32, built) == capacity(built));
    for (0..1024) |i| std.debug.assert(built[i] == @as(i32, @intCast(i)) * 7);

    {
        const view = vector_mod.slice(i32, built);
        std.debug.assert(view.len == @as(usize, @intCast(count(built))));
        std.debug.assert(view.ptr == built);
        for (view, 0..) |x, i| std.debug.assert(x == @as(i32, @intCast(i)) * 7);
    }

    // `setCount` writes word 1 and nothing else: the elements and the
    // capacity are untouched, which is what `janet_v_empty` relies on.
    const held = capacity(built);
    vector_mod.setCount(i32, built, 0);
    std.debug.assert(count(built) == 0);
    std.debug.assert(capacity(built) == held);
    std.debug.assert(vector_mod.slice(i32, built).len == 0);
    std.debug.assert(built[7] == 49);

    // A count driven below zero answers the empty slice rather than trapping
    // on `@intCast`. The C loop `for (i = 0; i < n; i++)` runs zero times
    // there, and `gc/mark.zig`'s `run` carries the same case for the mark
    // walk over a malformed fiber.
    vector_mod.setCount(i32, built, -1);
    std.debug.assert(vector_mod.slice(i32, built).len == 0);
    vector_mod.setCount(i32, built, 1024);

    // `flatten` copies the elements out with no prefix, and answers null for
    // a vector that was never grown.
    {
        const flat = vector_mod.flatten(i32, built).?;
        for (0..1024) |i| std.debug.assert(flat[i] == built[i]);
        utils.free(@ptrCast(flat));
    }
    std.debug.assert(vector_mod.flatten(i32, null) == null);

    vector_mod.free(i32, typed);
    vector_mod.free(i32, @as(?[*]i32, null));

    vm_lifecycle.deinit();
}
