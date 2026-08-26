//! `JanetTuple`: the immutable indexed sequence, its source map, and the
//! `tuple/*` surface.
//!
//! ## One allocation strategy, three files
//!
//! `strings.zig`, `symbols.zig` and `tuples.zig` were `string_symbol.zig`
//! until Phase 12's namespace batch 2. They are still one allocation strategy,
//! and that is worth stating rather than assuming: a buffer or an array is a
//! fixed-size block pointing at a payload that can be reallocated; a string, a
//! symbol or a tuple is a header and its payload in a *single* `janet_gcalloc`,
//! sized once and never resized. That is what makes them immutable in the
//! runtime's sense, and it is why the three share:
//!
//!  - **A head recovered by pointer arithmetic.** The value Janet passes
//!    around is the address of the payload, not of the block, so every
//!    operation subtracts the header size to get back to the header.
//!    `gc_sweep.zig` already does this for the free path; `head` below is the
//!    same shape, `@sizeOf` rather than `@offsetOf` because translate-c drops
//!    the flexible array member. `test/abi.c` pins the equality with a
//!    `_Static_assert` — the last place in the tree that can spell `offsetof` —
//!    and `test/gc_mark.zig` checks the offset the allocator actually used.
//!  - **A hash computed once, at the end of construction.** `begin` leaves
//!    `hash` uninitialised and `end` fills it in. A value observed between the
//!    two has an indeterminate hash, which is why nothing may put it in a
//!    dictionary before `end` runs. Preserved exactly; the port does not
//!    helpfully zero it.
//!
//! The taxonomy that separates them is Janet's own, and it is what the batch
//! followed: a string and a symbol are **bytes**, a tuple is **indexed**.
//! `port/NAMESPACES.md` has it, along with the reason there is no
//! `keywords.zig` — `janet.h` spells `janet_keyword` as a `#define` onto
//! `janet_symbol`, so a keyword and a symbol are the same interned bytes under
//! a different tag, and `helpers/wrap.zig` is where the tag lives.
//!
//! Tuples rode along in `string_symbol.zig` rather than forming a group of
//! their own, because `tuple.c`'s core is three functions and twenty-five
//! lines and every one of them is the string pattern with `Janet` in place of
//! `uint8_t`. The taxonomy is what separated them: a tuple is **indexed**, and
//! `arrays.zig` is its neighbour there rather than `strings.zig`. Batch 1's
//! survey found three `tuple*` functions filed under a name with `string` in
//! it, which is how the misfiling was noticed at all.
//!
//! The source-map fields are set to -1 by `begin`, which is what marks a tuple
//! as having no position rather than one at line zero.
//!
//! ## Jump transparency
//!
//! Nothing here calls `janet_panic`, but `janet_gcalloc` can trigger a
//! collection and a finalizer may raise, so a signal can still unwind through
//! these frames. There is no `defer` in this file and `build.zig` checks that
//! there is not.

const std = @import("std");
const corefn = @import("corefn");
const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");
const raise = @import("raise");
const pp_format = @import("../pp/format.zig");
const gc_alloc = @import("../gc.zig");
const wrap = @import("helpers/wrap.zig");
const args_core = @import("../args.zig");
const value = @import("../value.zig");

/// From `src/core/util.c`, declared here rather than imported: `util.h` is
/// never in a translation.
/// `strings.zig` and `symbols.zig` carry the declarations they need for the
/// same reason; `utils.zig` defines all of them without `pub`.
extern fn safe_memcpy(dest: ?*anyopaque, src: ?*const anyopaque, len: usize) callconv(.c) void;

/// C's conversion of a signed count to `size_t`: sign-extend to the pointer
/// width, then reinterpret. Same helper, and same reason, as `strings.zig`.
inline fn asSize(n: i32) usize {
    return @bitCast(@as(isize, n));
}

/// Allocate a tuple of `length` slots. The slots and the hash are
/// uninitialised; the source-map fields are set to -1, which is what marks a
/// tuple as having no position rather than one at line zero.
pub fn begin(length: i32) [*]types.Janet {
    const size = types.tuple_payload +% (asSize(length) *% @sizeOf(types.Janet));
    const hd: *types.JanetTupleHead = @ptrCast(@alignCast(gc_alloc.gcalloc(constants.JANET_MEMORY_TUPLE, size)));
    hd.sm_line = -1;
    hd.sm_column = -1;
    hd.length = length;
    return types.tupleData(hd);
}

/// Close a tuple, which is where its hash comes from. Every slot must be
/// filled before this runs -- the hash covers all of them.
pub fn end(tuple: [*]types.Janet) callconv(.c) [*]const types.Janet {
    types.tupleHead(tuple).hash = value.hashIndexed(tuple, types.tupleHead(tuple).length);
    return tuple;
}

pub fn newFrom(values: ?[*]const types.Janet, n: i32) [*]const types.Janet {
    const t = begin(n);
    safe_memcpy(@ptrCast(t), @ptrCast(values), @sizeOf(types.Janet) *% asSize(n));
    return end(t);
}

// ==========================================================================
// tuple/*, the cfunction surface.
//
// Phase 10 Part 6. Everything above this line is value construction, which is
// what Phase 8 took; the standard-library surface stayed in C then because
// every one of these functions raises and nothing in Zig could. It can now,
// though not by returning: a `JanetCFunction` has no error channel in its
// signature, so a cfunction delivers a raise as the jump its C caller is
// waiting for whichever language it is written in. That is why this file's
// `//! jump-transparent` marker matters more than it did -- each of these
// frames may be jumped out of, and none of them holds anything.
// ==========================================================================

/// `janet_wrap_integer`, written out because the function it would call does
/// not exist in every configuration: `janet.h` declares it beside its macro,
/// and `wrap.c` defines the declaration only for the NaN-boxed layouts. Same
/// reasoning, and the same three lines, as `value_access.zig` and
/// `pp_pretty.zig`.
inline fn wrapInteger(x: i32) types.Janet {
    return wrap.fromNumber(@floatFromInt(x));
}

fn cfunTupleBrackets(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    const tup = newFrom(argv.ptr, @as(i32, @intCast(argv.len)));
    types.tupleHead(tup).gc.flags |= @intCast(constants.JANET_TUPLE_FLAG_BRACKETCTOR);
    return wrap.fromTuple(tup);
}

fn cfunTupleSlice(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    const view = try args_core.getIndexed(argv, 0);
    const range = try args_core.getSlice(argv);
    return wrap.fromTuple(newFrom(view.items.? + @as(usize, @intCast(range.start)), range.end - range.start));
}

fn cfunTupleType(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 1);
    const tup = try args_core.getTuple(argv, 0);
    if (types.tupleHead(tup).gc.flags & @as(i32, @intCast(constants.JANET_TUPLE_FLAG_BRACKETCTOR)) != 0) {
        return value.fromBytes("brackets", .keyword);
    }
    return value.fromBytes("parens", .keyword);
}

fn cfunTupleSourcemap(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 1);
    const tup = try args_core.getTuple(argv, 0);
    var contents: [2]types.Janet = .{
        wrapInteger(types.tupleHead(tup).sm_line),
        wrapInteger(types.tupleHead(tup).sm_column),
    };
    return wrap.fromTuple(newFrom(&contents, 2));
}

fn cfunTupleSetmap(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 3);
    const tup = try args_core.getTuple(argv, 0);
    types.tupleHead(tup).sm_line = try args_core.getInteger(argv, 1);
    types.tupleHead(tup).sm_column = try args_core.getInteger(argv, 2);
    return argv[0];
}

/// The two passes over `argv` are the C original's and are not redundant: the
/// first is what rejects a bad argument and what checks the total for
/// overflow, and it has to finish before anything is allocated, because
/// `janet_tuple_begin` would otherwise leave a half-filled tuple behind when
/// the second argument turned out not to be indexed.
fn cfunTupleJoin(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    try args_core.arity(argv, 0, -1);
    var total_len: i32 = 0;
    var i: i32 = 0;
    while (i < @as(i32, @intCast(argv.len))) : (i += 1) {
        var len: i32 = 0;
        var vals: ?[*]const types.Janet = null;
        if (args_core.indexedView(argv[@intCast(i)], &vals, &len) == 0) {
            return pp_format.panicf("expected indexed type for argument %d, got %v", .{ i, argv[@intCast(i)] });
        }
        if (std.math.maxInt(i32) - total_len < len) return raise.panic("tuple too large");
        total_len += len;
    }
    const tup = begin(total_len);
    var cursor = tup;
    i = 0;
    while (i < @as(i32, @intCast(argv.len))) : (i += 1) {
        var len: i32 = 0;
        var vals: ?[*]const types.Janet = null;
        _ = args_core.indexedView(argv[@intCast(i)], &vals, &len);
        safe_memcpy(@ptrCast(cursor), @ptrCast(vals), asSize(len) *% @sizeOf(types.Janet));
        cursor += @intCast(len);
    }
    return wrap.fromTuple(end(tup));
}

pub fn lib(env: *types.JanetTable) void {
    const entries = [_]corefn.Entry{
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
        corefn.end,
    };
    corefn.install(env, &entries);
}
