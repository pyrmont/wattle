//! Behavioral contract for the growable vector: `stretchy.zig`, which is now
//! `std.ArrayListUnmanaged` over the **scratch** allocator.
//!
//! No Janet program can reach any of this. The vector is the compiler's, the
//! PEG builder's and the marshaller's scratch structure — never wrapped in a
//! `Janet`, never traced — so the only caller that can exercise it is a test
//! that pushes onto one by hand.
//!
//! ## What this file does not check
//!
//! It does not restate the container's layout. `ArrayListUnmanaged` carries its own
//! length and capacity in the value, `std` has its own tests for it, and a
//! restatement here would check Zig's standard library rather than this tree.
//!
//! ## What is left to check, which is the part that is this tree's
//!
//! The allocator. `stretchy.zig` chooses **scratch** over `utils.heap`, and
//! that is a correctness decision rather than a preference: the compiler
//! reaches `deinitCompiler` only if `janetc_value` returns, and a macro that
//! panics is the ordinary way a compile error is reported from Janet code. So
//! the properties below are the ones the choice rests on:
//!
//!   * growth goes through `janet_srealloc`, which fixes up the block's entry
//!     in the scratch table rather than adding one — a vector grown a thousand
//!     times occupies **one** entry, not a thousand;
//!   * `free` removes the entry;
//!   * a vector **abandoned** without `free` — which is what a raise does — is
//!     reclaimed by the next collection.
//!
//! The third is the one that matters, and it is the one no other contract in
//! the tree asserts. If `stretchy.zig` were ever pointed at `utils.heap`, the
//! first two would still pass and this one would leak.

const gc_alloc = @import("subsystems").gc_alloc;
const gc_mark = @import("subsystems").gc_mark;
const utils = @import("subsystems").utils;
const stretchy = @import("subsystems").stretchy;
const harness = @import("harness.zig");
const vm_state = @import("subsystems").vm_state;
const compiler = @import("subsystems").compiler_primitives;
const functions = @import("subsystems").value.functions;
const expect = @import("expect.zig").expect;

/// How many blocks the scratch allocator is holding. Every assertion below is
/// a statement about this number.
fn scratchBlocks() usize {
    return vm_state.current().scratch.count;
}

pub fn run() void {
    harness.init();

    // ------------------------------------------------------------ the empty
    //
    // `.empty` has never been grown and owns nothing, which is what lets a
    // struct field default to it without the VM having to exist yet.
    {
        const empty: stretchy.Vector(i32) = .empty;
        expect(empty.items.len == 0);
        expect(empty.capacity == 0);
    }
    const before = scratchBlocks();

    // ------------------------------------------------ growth is one block
    //
    // A thousand pushes cross the growth policy's threshold many times. Each
    // crossing is a `janet_srealloc`, which finds the block's row in the
    // scratch table and rewrites it in place. If any of them allocated a new
    // block instead — an alloc-copy-free `remap`, say — the table would grow
    // with the vector and this count would not be one.
    var v: stretchy.Vector(i32) = .empty;
    for (0..1024) |i| stretchy.push(&v, @as(i32, @intCast(i)) * 3);

    expect(v.items.len == 1024);
    expect(v.capacity >= 1024);
    expect(scratchBlocks() == before + 1);
    for (v.items, 0..) |element, i| expect(element == @as(i32, @intCast(i)) * 3);

    // `pushN` is the reserve-then-overwrite pattern the PEG compiler uses, and
    // it is one growth rather than `n` of them.
    stretchy.pushN(&v, -1, 500);
    expect(v.items.len == 1524);
    expect(scratchBlocks() == before + 1);
    for (v.items[1024..]) |element| expect(element == -1);

    // -------------------------------------------------------------- flatten
    //
    // `janet_v_flatten`: the elements alone, in `janet_malloc` memory. It is
    // the one operation with no standard equivalent, and the allocator is the
    // reason — `toOwnedSlice` would hand back scratch memory, and a funcdef's
    // constants outlive the collection that would sweep it. So the copy is
    // *not* a scratch block.
    {
        const blocks = scratchBlocks();
        const flattened = stretchy.flatten(i32, v).?;
        expect(scratchBlocks() == blocks);
        for (v.items, 0..) |element, i| expect(flattened[i] == element);
        utils.free(@ptrCast(flattened));
    }

    // An empty vector flattens to null rather than to an empty allocation.
    {
        const empty: stretchy.Vector(i32) = .empty;
        expect(stretchy.flatten(i32, empty) == null);
    }

    // ------------------------------------------------- free takes the entry
    stretchy.free(&v);
    expect(scratchBlocks() == before);
    expect(v.items.len == 0);
    expect(v.capacity == 0);

    // ------------------------------------------- and a collection takes it
    //
    // **The property the allocator choice exists for.** This vector is never
    // freed; it is abandoned exactly as a raise between `janetc_init` and
    // `janetc_deinit` abandons the compiler's. Over `utils.heap` the block
    // would still be live after the collection and this assertion would fail.
    {
        var abandoned: stretchy.Vector(i32) = .empty;
        for (0..64) |i| stretchy.push(&abandoned, @intCast(i));
        expect(scratchBlocks() == before + 1);
    }
    gc_mark.collect();
    expect(scratchBlocks() == before);

    // -------------------------------------------- the alignment the vtable
    //                                               will hand out
    //
    // `janet_smalloc` puts its payload behind a `JanetScratch` header, so the
    // alignment it can promise is that header's. The vtable aborts on a
    // stricter request rather than misaligning silently, which cannot be
    // tested from here — what can be is that no element type the tree pushes
    // asks for more.
    {
        const ceiling = @alignOf(gc_alloc.JanetScratch);
        expect(@alignOf(compiler.JanetSlot) <= ceiling);
        expect(@alignOf(compiler.SymPair) <= ceiling);
        expect(@alignOf(compiler.JanetEnvRef) <= ceiling);
        expect(@alignOf(functions.SourceMapping) <= ceiling);
        expect(@alignOf(functions.SymbolMap) <= ceiling);
    }
}
