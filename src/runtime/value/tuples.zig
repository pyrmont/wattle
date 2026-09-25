//! `Tuple`: the immutable indexed sequence, its source map, and the `tuple/*`
//! surface.
//!
//! `strings.zig`, `symbols.zig` and `tuples.zig` are one allocation strategy: a
//! header and its payload in a single collectable block, sized once and never
//! resized, which is what makes them immutable in the runtime's sense. An array
//! or a buffer is the other shape, a fixed-size block pointing at a payload
//! that can be reallocated. Two consequences follow for all three:
//!
//! - A head is recovered by pointer arithmetic. The value Janet passes around
//!   is the address of the payload rather than of the block, so `head`
//!   subtracts `tuple_payload`. `test/gc_mark.zig` checks the offset the
//!   allocator actually used.
//!
//! - A hash is computed once, at the end of construction. `begin` leaves `hash`
//!   uninitialised and `end` fills it in, so a value observed between the two
//!   has an indeterminate hash and nothing may put it in a dictionary.
//!
//! The taxonomy that separates them is Janet's own: a string and a symbol are
//! bytes, a tuple is indexed. There is no `keywords.zig` because a keyword is a
//! symbol of the other kind, which `symbols.zig` interns.
//! A tuple's core is the string pattern with a `Value` in place of a `u8`; what
//! gives it its own file is that taxonomy, which makes `arrays.zig` its
//! neighbour rather than `strings.zig`.
//!
//! Nothing here keeps a value across a raise. Allocating does not collect, so a
//! tuple between `begin` and `end` is safe while nothing runs Janet code: it is
//! unreachable, and the collector neither marks it nor reads its slots, and a
//! raise leaves it for the next sweep with its slots unwritten. Code that can
//! collect, such as an abstract's `length` callback, has to run before
//! `begin`.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const args_core = @import("../args.zig");
const corefn = @import("../corefn.zig");
const gc_alloc = @import("../gc.zig");
const pp_format = @import("../pp/format.zig");
const raise = @import("../../api/raise.zig");
const repr = @import("repr");
const tables = @import("tables.zig");
const value = @import("../value.zig");
const vectors = @import("vectors.zig");
const wrap = @import("helpers/wrap.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// Bit 0 of the collector header's per-type field: the tuple was written with
/// Where the slots begin within the block.
///
/// `@offsetOf` rather than `@sizeOf`: the head is Zig's own declaration, so
/// `_data` is an ordinary field whose offset the compiler takes exactly.
pub const tuple_payload = @offsetOf(TupleHead, "_data");

// ==========================================================================
// Types
// ==========================================================================

/// The slot array Janet passes a tuple around as.
pub const Tuple = [*]const repr.Value;

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

// ==========================================================================
// Public functions
// ==========================================================================

/// Allocates a tuple of `length` slots.
///
/// `length` is the slot count. The slots and the hash are uninitialised, and
/// the source-map fields are set to -1, which is what marks a tuple as having
/// no position rather than one at line zero.
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

/// Returns the payload of a block the allocator has just returned.
///
/// `hd` is the head. It takes a `*const` head and gives back a mutable payload:
/// the allocator's caller has to write through it, and a const head is what a
/// comparison or a hash is given.
pub inline fn data(hd: *const TupleHead) [*]repr.Value {
    return @ptrFromInt(@intFromPtr(hd) +% tuple_payload);
}

/// Closes a tuple, which is where its hash comes from.
///
/// `tuple` is the slot array. Every slot must be filled before this runs,
/// because the hash covers all of them.
pub fn end(tuple: [*]repr.Value) [*]const repr.Value {
    head(tuple).hash = value.hashIndexed(tuple[0..head(tuple).length]);
    return tuple;
}

/// Recovers a tuple's head from its slot array.
pub inline fn head(t: [*]const repr.Value) *TupleHead {
    return @ptrFromInt(@intFromPtr(t) -% tuple_payload);
}

/// Installs the `tuple/*` nfunctions into the core environment.
pub fn lib(env: *tables.Table) void {
    const entries = comptime [_]corefn.Entry{
        corefn.reg("tuple/slice", &nfunTupleSlice, @src(), "(tuple/slice ind)\n(tuple/slice ind start)\n(tuple/slice ind start end)", "Takes a sub-sequence of ind, an indexed type, from index start " ++
            "inclusive to index end exclusive. If start or end are not provided, " ++
            "they default to 0 and the length of ind, respectively. " ++
            "start and end can also be negative to indicate indexing " ++
            "from the end of the input. Note that if start is negative it is " ++
            "exclusive, and if end is negative it is inclusive, to allow a full " ++
            "negative slice range. Returns the new tuple, whatever the type of ind."),
        corefn.reg("tuple/sourcemap", &nfunTupleSourcemap, @src(), "(tuple/sourcemap tup)", "Returns the sourcemap metadata attached to tup, a tuple, " ++
            "as a vector of the line and the column."),
        corefn.reg("tuple/sourcemap!", &nfunTupleSetSourcemap, @src(), "(tuple/sourcemap! tup sourcemap)", "Sets the sourcemap metadata on a tuple. sourcemap " ++
            "is a pair of integers (line, column), as ^tuple/sourcemap returns. Returns the modified tuple."),
        corefn.reg("tuple/join", &nfunTupleJoin, @src(), "(tuple/join & inds)", "Creates a new tuple by joining the elements of each ind, an indexed type."),
    };
    corefn.install(env, entries);
}

/// Allocates and closes a tuple over `values`.
/// Builds a tuple from the runs `it` gives, which must total `length`.
///
/// `it` is an iterator, windowed by the caller where only part of the value is
/// wanted, and this reads it to the end. `length` is how many elements that
/// window holds, which the caller has from the same range it windowed with.
///
/// This function raises where `args.Chunks.next` does. That is the only call
/// between `begin` and `end`, and a `chunk` callback cannot run code, so the
/// slots need no fill: a raise leaves an unreachable tuple, which the sweep
/// frees without reading them. `next` returns every element of the window or
/// raises, so the runs total `length`.
pub fn newFromChunks(it: *args_core.Chunks, length: usize) raise.Error![*]const repr.Value {
    const tup = begin(length);
    var written: usize = 0;
    while (try it.next()) |run| {
        @memcpy(tup[written..][0..run.len], run);
        written += run.len;
    }
    std.debug.assert(written == length);
    return end(tup);
}

pub fn newFrom(values: []const repr.Value) [*]const repr.Value {
    const t = begin(values.len);
    @memcpy(t[0..values.len], values);
    return end(t);
}

/// Returns a tuple's elements.
///
/// `t` is the slot array. The length is in the head, so this is the pairing
/// said once, the way `arrays.slice` and `FuncDef`'s accessors say theirs.
pub inline fn view(t: [*]const repr.Value) []const repr.Value {
    const length = head(t).length;
    if (length == 0) return &.{};
    return t[0..length];
}

// ==========================================================================
// Private functions
// ==========================================================================

/// The `tuple/*` nfunctions.
///
/// Everything above is value construction. A published nfunction has no error
/// channel in its signature, so each of these delivers its raise through an
/// abi, and none keeps a value across a call that can raise.
///
/// `nfunTupleJoin` checks every argument and counts every element before it
/// allocates, so a refusal leaves nothing behind.
fn nfunTupleJoin(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 0, -1);
    var total: usize = 0;
    for (argv) |arg| {
        const vals = args_core.items(arg) orelse return joinParts(argv);
        total = try joinedLength(total, vals.len);
    }
    // Every argument is an array or a tuple, so nothing here runs code and
    // every count is the one the copy reads. This arm is the one a Janet
    // program reaches, and it is the copy this function has always done.
    const tup = begin(total);
    var cursor = tup;
    for (argv) |arg| {
        const vals = args_core.items(arg).?;
        @memcpy(cursor[0..vals.len], vals);
        cursor += vals.len;
    }
    return wrap.fromTuple(end(tup));
}

fn nfunTupleSetSourcemap(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 2);
    const tup = try args_core.getTuple(argv, 0);
    var source = try args_core.chunks(argv[1]) orelse {
        return args_core.panicIndexed(argv[1], 1, repr.TagSet.none);
    };
    if (source.len != 2) return raise.panic("expected a sourcemap of two integers");
    var pair: [2]repr.Value = undefined;
    var filled: usize = 0;
    while (try source.next()) |run| {
        for (run) |element| {
            pair[filled] = element;
            filled += 1;
        }
    }
    var fault: args_core.Fault = undefined;
    const line = args_core.argInteger(&pair, 0, &fault) orelse return raise.panic("expected a sourcemap of two integers");
    const column = args_core.argInteger(&pair, 1, &fault) orelse return raise.panic("expected a sourcemap of two integers");
    head(tup).sm_line = line;
    head(tup).sm_column = column;
    return argv[0];
}

fn nfunTupleSlice(argv: []repr.Value) raise.Error!repr.Value {
    const x = args_core.argSlot(argv, 0);
    var source = try args_core.chunks(x) orelse {
        return args_core.panicIndexed(x, 0, repr.TagSet.none);
    };
    const range = try args_core.getSlice(argv);
    source.window(@intCast(range.start), @intCast(range.end));
    const length: usize = @intCast(range.end - range.start);
    return wrap.fromTuple(try newFromChunks(&source, length));
}

fn nfunTupleSourcemap(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const tup = try args_core.getTuple(argv, 0);
    const pair = [2]repr.Value{
        wrap.fromInteger(head(tup).sm_line),
        wrap.fromInteger(head(tup).sm_column),
    };
    return wrap.fromVector(vectors.fromSlice(&pair));
}

/// `tuple/join` where an argument is not an array or a tuple.
///
/// Each argument is read twice, once to count and once to copy, since a run
/// does not survive the allocation between. Neither `length` nor `chunk` can
/// call into Janet code, so the second read gives what the first counted and
/// nothing can collect the tuple before `end`.
fn joinParts(argv: []repr.Value) raise.Error!repr.Value {
    var total: usize = 0;
    for (argv, 0..) |arg, index| {
        const source = try args_core.chunks(arg) orelse {
            return pp_format.panicf("expected indexed type for argument %d, got %v", .{ @as(i32, @intCast(index)), arg });
        };
        total = try joinedLength(total, source.len);
    }
    const tup = begin(total);
    var written: usize = 0;
    for (argv) |arg| {
        var source = (try args_core.chunks(arg)).?;
        while (try source.next()) |run| {
            @memcpy(tup[written..][0..run.len], run);
            written += run.len;
        }
    }
    std.debug.assert(written == total);
    return wrap.fromTuple(end(tup));
}

/// The total so far with `len` more elements, refused past what a tuple holds.
fn joinedLength(total: usize, len: usize) raise.Error!usize {
    if (@as(usize, std.math.maxInt(i32)) - total < len) return raise.panic("tuple too large");
    return total + len;
}

// ==========================================================================
// Tests
// ==========================================================================

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
