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
//! symbol under a different tag, and `helpers/wrap.zig` is where the tag lives.
//! A tuple's core is the string pattern with a `Value` in place of a `u8`; what
//! gives it its own file is that taxonomy, which makes `arrays.zig` its
//! neighbour rather than `strings.zig`.
//!
//! Nothing here keeps a value across a raise. Nothing here raises directly, but
//! `gcalloc` can trigger a collection and a finalizer may raise, so a raise can
//! still pass through these frames.

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
const wrap = @import("helpers/wrap.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// Bit 0 of the collector header's per-type field: the tuple was written with
/// brackets rather than parentheses.
///
/// `tuple/type` reports it, the printer reads it, the comparison and the hash
/// both fold it in, and it travels in a marshalled tuple, so it is a property
/// of the value rather than a hint.
const own_bracket_ctor: u6 = 1;

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

/// Whether the tuple was written with brackets.
pub inline fn isBracketed(hd: *const TupleHead) bool {
    return hd.gc.flags.own & own_bracket_ctor != 0;
}

/// Installs the `tuple/*` cfunctions into the core environment.
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
        corefn.reg("tuple/setmap", &cfunTupleSetmap, @src(), "(tuple/setmap tup line column)", "Set the sourcemap metadata on a tuple. `line` and `column` " ++
            "should be integers. Returns the modified tuple."),
        corefn.reg("tuple/join", &cfunTupleJoin, @src(), "(tuple/join & parts)", "Create a tuple by joining together other tuples and arrays."),
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
/// This function raises where `args.Chunks.next` does, and where the runs do
/// not total `length`: the count came from a `length` callback for an
/// abstract, and a second call to that callback can answer differently.
///
/// Where the source is an abstract the slots are filled with nil first, since
/// `begin` links the block into the collector's list with them unwritten and
/// anything raised below allocates. A contiguous source reads no callback, so
/// nothing between `begin` and `end` can raise and every slot is written.
pub fn newFromChunks(it: *args_core.Chunks, length: usize) raise.Error![*]const repr.Value {
    const tup = begin(length);
    if (it.source == .abstract) @memset(tup[0..length], wrap.fromNil());
    var written: usize = 0;
    while (try it.next()) |run| {
        if (length - written < run.len) return raise.panic(args_core.grew_message);
        @memcpy(tup[written..][0..run.len], run);
        written += run.len;
    }
    if (written != length) return raise.panic(args_core.shrank_message);
    return end(tup);
}

pub fn newFrom(values: []const repr.Value) [*]const repr.Value {
    const t = begin(values.len);
    @memcpy(t[0..values.len], values);
    return end(t);
}

/// Marks the tuple as written with brackets.
pub inline fn setBracketed(hd: *TupleHead) void {
    hd.gc.flags.own |= own_bracket_ctor;
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

/// The `tuple/*` cfunctions.
///
/// Everything above is value construction. A published cfunction has no error
/// channel in its signature, so each of these delivers its raise through an
/// abi, and none keeps a value across a call that can raise.
///
/// `cfunTupleJoin`'s two passes over `argv` are not redundant: the first is
/// what rejects a bad argument and checks the total for overflow, and it has to
/// finish before anything is allocated, because `begin` would otherwise leave a
/// half-filled tuple behind when a later argument turned out not to be indexed.
/// The second pass can raise all the same, which is why the slots are filled
/// with nil before it runs.
fn cfunTupleBrackets(argv: []repr.Value) raise.Error!repr.Value {
    const tup = newFrom(argv);
    setBracketed(head(tup));
    return wrap.fromTuple(tup);
}

fn cfunTupleJoin(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 0, -1);
    var total_len: i32 = 0;
    var any_abstract = false;
    for (argv, 0..) |arg, index| {
        var len: usize = undefined;
        if (args_core.items(arg)) |vals| {
            len = vals.len;
        } else {
            const counted = try args_core.chunks(arg) orelse {
                return pp_format.panicf("expected indexed type for argument %d, got %v", .{ @as(i32, @intCast(index)), arg });
            };
            any_abstract = true;
            len = counted.len;
        }
        if (std.math.maxInt(i32) - total_len < @as(i64, @intCast(len))) return raise.panic("tuple too large");
        total_len += @intCast(len);
    }
    const total: usize = @intCast(total_len);
    const tup = begin(total);

    // With no abstract among the arguments, nothing between the two passes
    // runs code: `begin` allocates and every count came from a view rather
    // than a callback. So the counts cannot have changed, nothing below can
    // raise, and every slot is written. This arm is the one a Janet program
    // reaches, and it is the copy this function has always done.
    if (!any_abstract) {
        var cursor = tup;
        for (argv) |arg| {
            const vals = args_core.items(arg).?;
            @memcpy(cursor[0..vals.len], vals);
            cursor += vals.len;
        }
        return wrap.fromTuple(end(tup));
    }

    // An abstract is among them, so a `length` callback runs again below and
    // a `chunk` callback can answer with a run that is refused. The slots are
    // filled first because `begin` links the block into the collector's list
    // with them uninitialised, and building a raised value allocates, an
    // allocation can collect, and a collection walks every slot of this
    // tuple.
    @memset(tup[0..total], wrap.fromNil());
    var written: usize = 0;
    for (argv) |arg| {
        var source = (try args_core.chunks(arg)).?;
        while (try source.next()) |run| {
            // The count this pass reads is not the count the first pass read:
            // both come from a callback that runs code, so the two can
            // disagree and the copy holds itself to the total the tuple was
            // made for.
            if (total - written < run.len) return raise.panic(args_core.grew_message);
            @memcpy(tup[written..][0..run.len], run);
            written += run.len;
        }
    }
    if (written != total) return raise.panic(args_core.shrank_message);
    return wrap.fromTuple(end(tup));
}

fn cfunTupleSetmap(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 3);
    const tup = try args_core.getTuple(argv, 0);
    head(tup).sm_line = try args_core.getInteger(argv, 1);
    head(tup).sm_column = try args_core.getInteger(argv, 2);
    return argv[0];
}

fn cfunTupleSlice(argv: []repr.Value) raise.Error!repr.Value {
    const x = args_core.argSlot(argv, 0);
    var source = try args_core.chunks(x) orelse {
        return args_core.panicIndexed(x, 0, repr.TagSet.none);
    };
    const range = try args_core.getSlice(argv);
    source.window(@intCast(range.start), @intCast(range.end));
    const length: usize = @intCast(range.end - range.start);
    return wrap.fromTuple(try newFromChunks(&source, length));
}

fn cfunTupleSourcemap(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const tup = try args_core.getTuple(argv, 0);
    var contents: [2]repr.Value = .{
        wrap.fromInteger(head(tup).sm_line),
        wrap.fromInteger(head(tup).sm_column),
    };
    return wrap.fromTuple(newFrom(&contents));
}

fn cfunTupleType(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const tup = try args_core.getTuple(argv, 0);
    if (isBracketed(head(tup))) {
        return value.fromBytes("brackets", .keyword);
    }
    return value.fromBytes("parens", .keyword);
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
