//! `Tuple`: the immutable indexed sequence, its source map, and the
//! `tuple/*` surface.
//!
//! ## One allocation strategy, three files
//!
//! `strings.zig`, `symbols.zig` and `tuples.zig` were one file once. They are
//! still one allocation strategy,
//! and that is worth stating rather than assuming: a buffer or an array is a
//! fixed-size block pointing at a payload that can be reallocated; a string, a
//! symbol or a tuple is a header and its payload in a *single* `janet_gcalloc`,
//! sized once and never resized. That is what makes them immutable in the
//! runtime's sense, and it is why the three share:
//!
//!  - **A head recovered by pointer arithmetic.** The value Janet passes
//!    around is the address of the payload, not of the block, so every
//!    operation subtracts the header size to get back to the header.
//!    `gc/sweep.zig` already does this for the free path; `head` below is the
//!    same shape, subtracting `@offsetOf(TupleHead, "_data")`.
//!    `test/gc_mark.zig` checks the offset the allocator actually used.
//!  - **A hash computed once, at the end of construction.** `begin` leaves
//!    `hash` uninitialised and `end` fills it in. A value observed between the
//!    two has an indeterminate hash, which is why nothing may put it in a
//!    dictionary before `end` runs. Preserved exactly; nothing here
//!    helpfully zeroes it.
//!
//! The taxonomy that separates them is Janet's own: a string and a symbol are
//! **bytes**, a tuple is **indexed**. There is no `keywords.zig` because a
//! keyword is a symbol under a different tag, and `helpers/wrap.zig` is where
//! the tag lives.
//!
//! A tuple's core is three functions and twenty-five lines, and every one of
//! them is the string pattern with a `Value` in place of a `u8`. The taxonomy
//! is what gives it its own file anyway: a tuple is **indexed**, so
//! `arrays.zig` is its neighbour rather than `strings.zig`. A survey found
//! three `tuple*` functions filed under a name with `string` in
//! it, which is how the misfiling was noticed at all.
//!
//! The source-map fields are set to -1 by `begin`, which is what marks a tuple
//! as having no position rather than one at line zero.
//!
//! **Nothing here holds anything across a raise.** Nothing here raises
//! directly, but `janet_gcalloc` can trigger a collection and a finalizer may
//! raise, so a raise can still pass through these frames.

const std = @import("std");
const corefn = @import("../corefn.zig");
const repr = @import("repr");
const raise = @import("../raise.zig");
const pp_format = @import("../pp/format.zig");
const gc_alloc = @import("../gc.zig");
const wrap = @import("helpers/wrap.zig");
const args_core = @import("../args.zig");
const value = @import("../value.zig");
const abi = @import("abi");
const tables = @import("tables.zig");

/// A tuple's head: the collector's object, the length, the hash and the two
/// source-map fields, with the slots following it in the same allocation.
pub const TupleHead = extern struct {
    gc: abi.GCObject = .{},
    length: u32 = 0,
    hash: i32 = 0,
    sm_line: i32 = 0,
    sm_column: i32 = 0,
    _data: [0]repr.Value = std.mem.zeroes([0]repr.Value),
};

comptime {
    // As `StringHead`: the width is the contract and the sign is not. The two
    // source-map fields stay signed because -1 is what marks a tuple as having
    // no position, and `hash` stays signed because it is a hash.
    const SignedHead = extern struct {
        gc: abi.GCObject = .{},
        length: i32 = 0,
        hash: i32 = 0,
        sm_line: i32 = 0,
        sm_column: i32 = 0,
        _data: [0]repr.Value = std.mem.zeroes([0]repr.Value),
    };
    std.debug.assert(@offsetOf(TupleHead, "_data") == @offsetOf(SignedHead, "_data"));
    std.debug.assert(@offsetOf(TupleHead, "sm_line") == @offsetOf(SignedHead, "sm_line"));
    std.debug.assert(@sizeOf(TupleHead) == @sizeOf(SignedHead));
}

/// Bit 0 of the GC header's per-type field: this tuple was written with
/// brackets rather than parentheses. `tuple/type` answers it, the printer
/// reads it, the comparison and the hash both fold it in, and it travels in a
/// marshalled tuple -- so it is a property of the value and not a hint.
const own_bracket_ctor: u6 = 1;

pub inline fn isBracketed(hd: *const TupleHead) bool {
    return hd.gc.flags.own & own_bracket_ctor != 0;
}

pub inline fn setBracketed(hd: *TupleHead) void {
    hd.gc.flags.own |= own_bracket_ctor;
}

/// Where the slots begin within the block. `@offsetOf` and not `@sizeOf`: the
/// head is Zig's own declaration, so `_data` is an ordinary field whose offset
/// the compiler takes exactly.
pub const tuple_payload = @offsetOf(TupleHead, "_data");

/// The slot array Janet passes a tuple around as.
pub const Tuple = [*]const repr.Value;

/// Recover a tuple's head from its slot array.
pub inline fn head(t: [*]const repr.Value) *TupleHead {
    return @ptrFromInt(@intFromPtr(t) -% tuple_payload);
}

/// The inverse, for a block the allocator has just returned. It takes a
/// `*const` head and hands back a mutable payload: the allocator's caller has
/// to write through it, and a const head is what a comparison or a hash holds.
pub inline fn data(hd: *const TupleHead) [*]repr.Value {
    return @ptrFromInt(@intFromPtr(hd) +% tuple_payload);
}

/// Allocate a tuple of `length` slots. The slots and the hash are
/// uninitialised; the source-map fields are set to -1, which is what marks a
/// tuple as having no position rather than one at line zero.
/// The tuple's elements. The length lives in the head, so every caller that
/// wants to walk a tuple was writing the pair out; this is the pairing said
/// once, the way `arrays.slice` and `FuncDef`'s accessors say theirs.
pub inline fn view(t: [*]const repr.Value) []const repr.Value {
    const length = head(t).length;
    if (length == 0) return &.{};
    return t[0..length];
}

pub fn begin(length: usize) [*]repr.Value {
    const hd = gc_alloc.gcallocWithPayload(
        TupleHead,
        .tuple,
        length *% @sizeOf(repr.Value),
    );
    hd.sm_line = -1;
    hd.sm_column = -1;
    hd.length = @intCast(length);
    return data(hd);
}

/// Close a tuple, which is where its hash comes from. Every slot must be
/// filled before this runs -- the hash covers all of them.
pub fn end(tuple: [*]repr.Value) [*]const repr.Value {
    head(tuple).hash = value.hashIndexed(tuple[0..head(tuple).length]);
    return tuple;
}

pub fn newFrom(values: []const repr.Value) [*]const repr.Value {
    const t = begin(values.len);
    @memcpy(t[0..values.len], values);
    return end(t);
}

// ==========================================================================
// tuple/*, the cfunction surface.
//
// Everything above this line is value construction. A published
// `CFunction` has no error channel in its signature, so each of these
// delivers its raise through an abi. Nothing below holds anything across a
// call that can raise.
// ==========================================================================

fn cfunTupleBrackets(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    const tup = newFrom(argv);
    setBracketed(head(tup));
    return wrap.fromTuple(tup);
}

fn cfunTupleSlice(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    const indexed = try args_core.getIndexed(argv, 0);
    const range = try args_core.getSlice(argv);
    return wrap.fromTuple(newFrom(indexed[@intCast(range.start)..@intCast(range.end)]));
}

fn cfunTupleType(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    const tup = try args_core.getTuple(argv, 0);
    if (isBracketed(head(tup))) {
        return value.fromBytes("brackets", .keyword);
    }
    return value.fromBytes("parens", .keyword);
}

fn cfunTupleSourcemap(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    const tup = try args_core.getTuple(argv, 0);
    var contents: [2]repr.Value = .{
        wrap.fromInteger(head(tup).sm_line),
        wrap.fromInteger(head(tup).sm_column),
    };
    return wrap.fromTuple(newFrom(&contents));
}

fn cfunTupleSetmap(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 3);
    const tup = try args_core.getTuple(argv, 0);
    head(tup).sm_line = try args_core.getInteger(argv, 1);
    head(tup).sm_column = try args_core.getInteger(argv, 2);
    return argv[0];
}

/// The two passes over `argv` are the C original's and are not redundant: the
/// first is what rejects a bad argument and what checks the total for
/// overflow, and it has to finish before anything is allocated, because
/// `janet_tuple_begin` would otherwise leave a half-filled tuple behind when
/// the second argument turned out not to be indexed.
fn cfunTupleJoin(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.arity(argv, 0, -1);
    var total_len: i32 = 0;
    for (argv, 0..) |arg, index| {
        const vals = args_core.indexedView(arg) orelse {
            return pp_format.panicf("expected indexed type for argument %d, got %v", .{ @as(i32, @intCast(index)), arg });
        };
        if (std.math.maxInt(i32) - total_len < @as(i64, @intCast(vals.len))) return raise.panic("tuple too large");
        total_len += @intCast(vals.len);
    }
    const tup = begin(@intCast(total_len));
    var cursor = tup;
    for (argv) |arg| {
        const vals = args_core.indexedView(arg).?;
        @memcpy(cursor[0..vals.len], vals);
        cursor += vals.len;
    }
    return wrap.fromTuple(end(tup));
}

pub fn lib(env: *tables.Table) void {
    const entries = comptime [_]corefn.Entry{
        corefn.reg("tuple/brackets", &cfunTupleBrackets, @src(), "(tuple/brackets & xs)", "Creates a new bracketed tuple containing the elements xs."),
        corefn.reg("tuple/slice", &cfunTupleSlice, @src(), "(tuple/slice arrtup [,start=0 [,end=(length arrtup)]])", "Take a sub-sequence of an array or tuple from index `start` " ++
            "inclusive to index `end` exclusive. If `start` or `end` are not provided, " ++
            "they default to 0 and the length of `arrtup`, respectively. " ++
            "`start` and `end` can also be negative to indicate indexing " ++
            "from the end of the input. Note that if `start` is negative it is " ++
            "exclusive, and if `end` is negative it is inclusive, to allow a full " ++
            "negative slice range. Returns the new tuple."),
        corefn.reg("tuple/type", &cfunTupleType, @src(), "(tuple/type tup)", "Checks how the tuple was constructed. Will return the keyword " ++
            ":brackets if the tuple was parsed with brackets, and :parens " ++
            "otherwise. The two types of tuples will behave the same most of " ++
            "the time, but will print differently and be treated differently by " ++
            "the compiler."),
        corefn.reg("tuple/sourcemap", &cfunTupleSourcemap, @src(), "(tuple/sourcemap tup)", "Returns the sourcemap metadata attached to a tuple, " ++
            "which is another tuple (line, column)."),
        corefn.reg("tuple/setmap", &cfunTupleSetmap, @src(), "(tuple/setmap tup line column)", "Set the sourcemap metadata on a tuple. line and column indicate " ++
            "should be integers."),
        corefn.reg("tuple/join", &cfunTupleJoin, @src(), "(tuple/join & parts)", "Create a tuple by joining together other tuples and arrays."),
    };
    corefn.install(env, entries);
}
