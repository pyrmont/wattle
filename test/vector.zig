//! Behavioral contract for the growable vector, `scratch_vector.zig`: a
//! `std.ArrayListUnmanaged` over the scratch allocator.
//!
//! No Janet program can reach any of this. The vector is the compiler's, the
//! PEG builder's and the marshaller's scratch structure, never wrapped in a
//! `Janet` and never traced, so the only caller that can exercise it is a test
//! that pushes onto one by hand.
//!
//! ## What this file does not check
//!
//! It does not restate the container's layout. `ArrayListUnmanaged` keeps its
//! own length and capacity in the value, `std` has its own tests for it, and a
//! restatement here would check Zig's standard library rather than this tree.
//!
//! ## What is left, which is the part that is this tree's
//!
//! The allocator. `scratch_vector.zig` chooses `gc.scratch_heap` over
//! `utils.heap`, and that is a correctness decision rather than a preference:
//! `compiler.zig`'s `compileLintImpl` reaches `deinitCompiler` only if
//! `valueImpl` returns, and a macro that panics is the ordinary way a compile
//! error is reported from Janet code. So the properties below are the ones
//! that choice rests on:
//!
//!   * growth goes through `gc_alloc.srealloc`, which fixes up the block's
//!     entry in the scratch table rather than adding one, so a vector grown a
//!     thousand times occupies one entry and not a thousand;
//!   * `free` removes the entry;
//!   * a vector abandoned without `free`, which is what a raise does, is
//!     reclaimed by the next collection.
//!
//! The third is the one that matters and the one no other contract in the tree
//! asserts. Pointed at `utils.heap` the first two would still pass and this
//! one would leak.

// ==========================================================================
// Project imports
// ==========================================================================

const compiler = @import("subsystems").compiler_primitives;
const expect = @import("expect.zig").expect;
const functions = @import("subsystems").value.functions;
const gc_alloc = @import("subsystems").gc_alloc;
const gc_mark = @import("subsystems").gc_mark;
const harness = @import("harness.zig");
const scratch_vector = @import("subsystems").scratch_vector;
const utils = @import("subsystems").utils;
const vm_state = @import("subsystems").vm_state;

// ==========================================================================
// Public functions
// ==========================================================================

pub fn run() void {
    harness.init();

    // The empty vector: `.empty` has never been grown and owns nothing, which
    // is what lets a struct field default to it before the VM exists.
    {
        const empty: scratch_vector.Vector(i32) = .empty;
        expect(empty.items.len == 0);
        expect(empty.capacity == 0);
    }
    const before = scratchBlocks();

    // Growth is one block. A thousand pushes cross the growth policy's
    // threshold many times, and each crossing is a `gc_alloc.srealloc`, which
    // finds the block's row in the scratch table and rewrites it in place. If
    // any of them allocated a new block instead, an alloc-copy-free `remap`
    // say, the table would grow with the vector and this count would not be
    // one.
    var v: scratch_vector.Vector(i32) = .empty;
    for (0..1024) |i| scratch_vector.push(&v, @as(i32, @intCast(i)) * 3);

    expect(v.items.len == 1024);
    expect(v.capacity >= 1024);
    expect(scratchBlocks() == before + 1);
    for (v.items, 0..) |element, i| expect(element == @as(i32, @intCast(i)) * 3);

    // `pushN` is the reserve-then-overwrite pattern the PEG compiler uses,
    // and it is one growth rather than `n` of them.
    scratch_vector.pushN(&v, -1, 500);
    expect(v.items.len == 1524);
    expect(scratchBlocks() == before + 1);
    for (v.items[1024..]) |element| expect(element == -1);

    // `scratch_vector.flatten` is the elements alone, in heap memory. It is
    // the one operation with no standard equivalent, and the allocator is the
    // reason: `std.ArrayListUnmanaged.toOwnedSlice` over this vector's own
    // allocator would give back scratch memory, and a funcdef's constants
    // outlive the collection that would sweep it. So the copy is *not* a
    // scratch block.
    {
        const blocks = scratchBlocks();
        const flattened = scratch_vector.flatten(i32, v).?;
        expect(scratchBlocks() == blocks);
        for (v.items, 0..) |element, i| expect(flattened[i] == element);
        utils.free(@ptrCast(flattened));
    }

    // An empty vector flattens to null rather than to an empty allocation.
    {
        const empty: scratch_vector.Vector(i32) = .empty;
        expect(scratch_vector.flatten(i32, empty) == null);
    }

    // `free` takes the entry back out of the scratch table.
    scratch_vector.free(&v);
    expect(scratchBlocks() == before);
    expect(v.items.len == 0);
    expect(v.capacity == 0);

    // And so does a collection, which is the property the allocator choice
    // exists for. This vector is never freed; it is abandoned exactly as a
    // raise between `initCompiler` and `deinitCompiler` abandons the
    // compiler's. Over `utils.heap` the block would still be live after the
    // collection and this assertion would fail.
    {
        var abandoned: scratch_vector.Vector(i32) = .empty;
        for (0..64) |i| scratch_vector.push(&abandoned, @intCast(i));
        expect(scratchBlocks() == before + 1);
    }
    gc_mark.collect();
    expect(scratchBlocks() == before);

    // The alignment the vtable can promise. `gc_alloc.smalloc` puts its payload
    // behind a `ScratchBlock` header, so that header's alignment is the
    // ceiling. The vtable aborts on a stricter request rather than
    // misaligning silently, which cannot be tested from here; what can be is
    // that no element type the tree pushes asks for more.
    {
        const ceiling = @alignOf(gc_alloc.ScratchBlock);
        expect(@alignOf(compiler.Slot) <= ceiling);
        expect(@alignOf(compiler.SymPair) <= ceiling);
        expect(@alignOf(compiler.EnvRef) <= ceiling);
        expect(@alignOf(functions.SourceMapping) <= ceiling);
        expect(@alignOf(functions.SymbolMap) <= ceiling);
    }
}

// ==========================================================================
// Private functions
// ==========================================================================

/// How many blocks the scratch allocator has. Every assertion in `run` is a
/// statement about this number.
fn scratchBlocks() usize {
    return vm_state.current().scratch.items.len;
}
