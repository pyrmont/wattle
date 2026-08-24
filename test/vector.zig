//! Behavioral contract for the growable vector: `janet_v_grow` and
//! `janet_v_flattenmem`, and the header arithmetic the macros in
//! `src/core/vector.h` do around them.
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
//! Restating is not a loss here, it is closer to what the contract is for. The
//! C original asserted the same arithmetic through the macros, so it could
//! only ever have caught a disagreement between `vector.zig` and *itself*.
//! Written out, the two descriptions of the layout come from different files
//! and a drift in either is a failure.
//!
//! ## Why this is the first contract in the new driver
//!
//! Phase 11 Part 1 needed one subject to prove the arrangement on, and this is
//! the smallest: two functions, no raise, no cfunction, no abstract type.
//! What it proves is only the frame — that a contract can live in the
//! runtime's compilation, reach it by import, and run under
//! `test/contracts.zig` — which is what every contract after it depends on and
//! none of them re-establishes.

const std = @import("std");
const abi = @import("abi");
const c = abi.c;

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
        vector.* = @ptrCast(@alignCast(c.janet_v_grow(
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
    if (vector) |v| c.janet_sfree(@ptrCast(raw(v)));
}

pub fn run() void {
    var vector: ?[*]i32 = null;

    _ = c.janet_init();
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
        const flattened: [*]i32 = @ptrCast(@alignCast(c.janet_v_flattenmem(
            @ptrCast(grown),
            @sizeOf(i32),
        ).?));
        for (0..1024) |i| std.debug.assert(flattened[i] == grown[i]);
        c.janet_free(@ptrCast(flattened));
    }

    // A null vector flattens to null rather than to an empty allocation. The C
    // contract never asked, because `janet_v_flatten(NULL)` reads
    // `sizeof(*(v))` off a null pointer expression and is only well defined
    // because `sizeof` does not evaluate it.
    std.debug.assert(c.janet_v_flattenmem(null, @sizeOf(i32)) == null);

    free(grown);
    c.janet_deinit();
}
