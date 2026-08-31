//! `JanetArray`: the growable `Janet` container, its capacity policy, its
//! push/pop primitives and the `array/*` surface.
//!
//! `buffers.zig` is the sibling, and the two were one file: they are one data
//! structure with two element types -- a `JanetGCObject` header followed by
//! `count`/`capacity`/`data`, with `data` in a separate `janet_malloc` block
//! reallocated in place. They are separate because Janet's own taxonomy
//! separates them: an array is **indexed** and a buffer is **bytes**, which is
//! the distinction `janet_indexed_view` and `janet_bytes_view` draw.
//!
//! Nothing here calls into `buffers.zig` and nothing there calls in here. The
//! shared layout is a fact about the structures, not a dependency.
//!
//! An array is not traversed here either. `gc/mark.zig` walks its elements;
//! nothing below marks, and nothing below frees a collectable block.
//!
//! **Nothing here holds anything across a raise**, because
//!
//! **The file is jump-transparent**, under the rule SPIKE-8 settled:
//! `janet_gcalloc` can trigger a collection, which runs finalizers, which
//! SPIKE-8 permits to raise, and `push` raises on overflow. A signal unwinds
//! straight through these frames, so there is no `defer` in this file and
//! `build.zig` checks that there is not. Nothing below holds a raw block
//! between acquiring it and storing it where the collector can see it.
//!
//! ## Arithmetic reproduced rather than repaired
//!
//! The capacity policy multiplies a caller-supplied count by a caller-supplied
//! growth factor and trusts the product to be positive. C's conversion of the
//! negative result to `size_t` is defined and wraps; Zig's would trap, so the
//! conversions are written out through `asSize` below and the arithmetic uses
//! wrapping operators wherever the C original can wrap.
//!
//! This is not hypothetical, and the reachable instance is here rather than in
//! `buffers.zig`. `array/ensure` passes its third argument to
//! `janet_array_ensure` unchecked, so a growth of zero frees an array's backing
//! store while leaving `count` untouched — a use-after-free reachable from pure
//! Janet — and a negative growth requests almost the whole address space and
//! ends the process through `JANET_OUT_OF_MEMORY`, which `protect` cannot catch.
//! `FOUND.md` records both symptoms and the measurement; they are left unfixed
//! under the usual rule and reproduced exactly here. `test/buffer_array.zig`
//! pins them.
//!
//! Two asymmetries with `buffers.zig` are preserved for the same reason, and
//! neither is a defect:
//!
//!  - `janet_array_ensure` charges GC pressure *after* the `janet_realloc`
//!    where `janet_buffer_ensure` charges it before, so a failed array growth
//!    is not accounted for. Both exit the process on failure, so nothing
//!    observes the difference.
//!  - `initImpl` adds to `vm.gc.next_collection` directly where the
//!    buffer's calls `janet_gcpressure`. The two are the same operation; the
//!    direct form is mirrored directly so that the byte counts charged match
//!    the C term for term.
//!
//! `n` — `janet_array_n` — charges no pressure at all, which is a third
//! asymmetry and also preserved.

const std = @import("std");
const corefn = @import("corefn");
const types = @import("types");
const repr = @import("repr");
const vm_state = @import("../vm/lifecycle.zig");
const raise = @import("raise");
const pp_format = @import("../pp/format.zig");
const gc_alloc = @import("../gc.zig");
const utils = @import("../utils.zig");
const wrap = @import("helpers/wrap.zig");
const args_core = @import("../args.zig");
const fatal = @import("../fatal.zig");

/// `safe_memcpy` from `src/core/util.c`. Declared here rather than imported:
/// `util.h` was never in a translation, and this function's parameters are
/// primitive, so no Janet type crosses. `buffers.zig` has
/// the same declaration for the same reason; `utils.zig` defines it without
/// `pub`, and making it `pub` is what deletes both.
extern fn safe_memcpy(dest: ?*anyopaque, src: ?*const anyopaque, len: usize) callconv(.c) void;

/// C's conversion of a signed count to `size_t`: sign-extend to the pointer
/// width, then reinterpret. For a negative count that yields a very large
/// size, which is exactly what the C code does and what `FOUND.md` records for
/// `array/ensure`. Written out because Zig has no implicit signed-to-unsigned
/// conversion and `@intCast` would trap on the values this reaches.
inline fn asSize(n: i32) usize {
    return @bitCast(@as(isize, n));
}

// ------------------------------------------------------------------- array

/// Give an array its initial payload. A capacity of zero leaves `data` null,
/// and the growth paths handle that: `janet_realloc(NULL, n)` allocates.
fn init(array: *types.JanetArray, capacity: i32) void {
    var data: ?[*]repr.Value = null;
    if (capacity > 0) {
        // Written as the C original writes it, rather than through
        // `janet_gcpressure`, so the two selectors charge the same term.
        vm_state.current().gc.next_collection +%= asSize(capacity) *% @sizeOf(repr.Value);
        data = @ptrCast(@alignCast(utils.malloc(@sizeOf(repr.Value) *% asSize(capacity)) orelse
            fatal.outOfMemory()));
    }
    array.count = 0;
    array.capacity = capacity;
    array.data = data;
}

pub fn new(capacity: i32) *types.JanetArray {
    const array: *types.JanetArray = @ptrCast(@alignCast(gc_alloc.gcalloc(types.MemoryType.array, @sizeOf(types.JanetArray))));
    init(array, capacity);
    return array;
}

/// An array whose elements do not keep their targets alive. The only
/// difference is the memory type, which puts the block on the weak heap and
/// sends it to `dropDeadElements` in `gc_sweep.zig` instead of to the marker.
pub fn weak(capacity: i32) *types.JanetArray {
    const array: *types.JanetArray = @ptrCast(@alignCast(gc_alloc.gcalloc(types.MemoryType.array_weak, @sizeOf(types.JanetArray))));
    init(array, capacity);
    return array;
}

/// Build an array from `count` elements. Note that this does not go through
/// `initImpl` and charges no GC pressure for the payload it allocates; the
/// asymmetry is the C original's and is preserved.
///
/// **`newFrom` allocates and copies; `new` reserves.** `new(4)` returns an
/// array of capacity four and count *zero*; this returns one of capacity and
/// count four, holding the elements it was handed. The distinction is the
/// whole reason for the name.
///
/// Stripping the type from `janet_array_n` leaves `n`, which is the most
/// collision-prone identifier there is — it shadowed `asSize`'s parameter and
/// a local in `array/insert` on the first build. The first replacement was
/// `newN`, and it was wrong for a reason a build cannot catch: beside
/// `new(capacity)` it reads as "new, of size N" rather than "new, *from* N
/// elements", which is exactly how it was misread. `newFrom` says which
/// argument the number describes. `tuples.newFrom` is the same decision.
///
/// Worth knowing when this looks inconsistent: `strings.new(buf, len)` and
/// `symbols.new(str, len)` have this same shape and are called `new`, because
/// `janet_string` copies where `janet_array` reserves. The C API is
/// inconsistent here and the namespace inherits it rather than causing it.
pub fn newFrom(elements: []const repr.Value) *types.JanetArray {
    const count: i32 = @intCast(elements.len);
    const array: *types.JanetArray = @ptrCast(@alignCast(gc_alloc.gcalloc(types.MemoryType.array, @sizeOf(types.JanetArray))));
    array.capacity = count;
    array.count = count;
    array.data = @ptrCast(@alignCast(utils.malloc(@sizeOf(repr.Value) *% asSize(count))));
    if (array.data == null) fatal.outOfMemory();
    safe_memcpy(@ptrCast(array.data), @ptrCast(elements.ptr), @sizeOf(repr.Value) *% asSize(count));
    return array;
}

/// Grow an array to at least `capacity`, overshooting by `growth`.
///
/// This is the function `FOUND.md` records against: `array/ensure` hands a
/// script's growth factor straight through, and a factor of zero or less
/// produces a zero or negative capacity that this passes to `janet_realloc`
/// while leaving `count` alone. Reproduced exactly, wrapping operators and all.
pub fn ensure(array: *types.JanetArray, capacity_in: i32, growth: i32) void {
    var capacity = capacity_in;
    const old = array.data;
    if (capacity <= array.capacity) return;
    // Cannot overflow: both factors fit in 32 bits, so the product fits in 62.
    var new_capacity: i64 = @as(i64, capacity) * @as(i64, growth);
    if (new_capacity > std.math.maxInt(i32)) new_capacity = std.math.maxInt(i32);
    capacity = @truncate(new_capacity);
    const new_data = utils.realloc(@ptrCast(old), asSize(capacity) *% @sizeOf(repr.Value)) orelse
        fatal.outOfMemory();
    // Charged after the allocation, where the buffer twin charges it before.
    vm_state.current().gc.next_collection +%= asSize(capacity -% array.capacity) *% @sizeOf(repr.Value);
    array.data = @ptrCast(@alignCast(new_data));
    array.capacity = capacity;
}

/// Set an array's length, filling any newly covered slots with nil.
pub fn setcount(array: *types.JanetArray, count: i32) void {
    if (count < 0) return;
    if (count > array.count) {
        ensure(array, count, 1);
        @memset(array.reserved()[@intCast(array.count)..@intCast(count)], wrap.fromNil());
    }
    array.count = count;
}

pub fn push(array: *types.JanetArray, x: repr.Value) raise.Raising(void) {
    if (array.count == std.math.maxInt(i32)) {
        return raise.panic("array overflow");
    }
    ensure(array, array.count + 1, 2);
    array.appendAssumingCapacity(x);
}

pub fn pop(array: *types.JanetArray) repr.Value {
    if (array.count != 0) return array.popAssumingAny();
    return wrap.fromNil();
}

pub fn peek(array: *types.JanetArray) repr.Value {
    if (array.count != 0) {
        return array.slice()[@intCast(array.count - 1)];
    }
    return wrap.fromNil();
}

pub fn pushAbi(array: *types.JanetArray, x: repr.Value) void {
    raise.reported(push(array, x));
}

// ==========================================================================
// The cfunction surface.
//
// These raise, and a published `JanetCFunction` has no error channel, so each
// delivers its raise through an abi. Nothing below holds anything across a
// call that can raise -- which for a growable container means in particular
// that no local caches `data` across an `ensure`, because a reallocation
// invalidates it whether or not anything raises.
// ==========================================================================

fn cfunArrayNew(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    return wrap.fromArray(new(try args_core.getInteger(argv, 0)));
}

fn cfunArrayWeak(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    return wrap.fromArray(weak(try args_core.getInteger(argv, 0)));
}

fn cfunArrayNewFilled(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.arity(argv, 1, 2);
    const count = try args_core.getNat(argv, 0);
    const x = if (@as(i32, @intCast(argv.len)) == 2) argv[1] else wrap.fromNil();
    const array = new(count);
    @memset(array.*.reserved()[0..@intCast(count)], x);
    array.*.count = count;
    return wrap.fromArray(array);
}

fn cfunArrayFill(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.arity(argv, 1, 2);
    const array = try args_core.getArray(argv, 0);
    const x = if (@as(i32, @intCast(argv.len)) == 2) argv[1] else wrap.fromNil();
    @memset(array.*.slice(), x);
    return argv[0];
}

fn cfunArrayPop(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    return pop(try args_core.getArray(argv, 0));
}

fn cfunArrayPeek(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    return peek(try args_core.getArray(argv, 0));
}

fn cfunArrayPush(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.arity(argv, 1, -1);
    const array = try args_core.getArray(argv, 0);
    if (std.math.maxInt(i32) - @as(i32, @intCast(argv.len)) + 1 <= array.*.count) return raise.panic("array overflow");
    const newcount = array.*.count - 1 + @as(i32, @intCast(argv.len));
    ensure(array, newcount, 2);
    if (@as(i32, @intCast(argv.len)) > 1) {
        safe_memcpy(
            @ptrCast(array.*.data.? + @as(usize, @intCast(array.*.count))),
            @ptrCast(argv[1..]),
            @as(usize, @intCast(@as(i32, @intCast(argv.len)) - 1)) *% @sizeOf(repr.Value),
        );
    }
    array.*.count = newcount;
    return argv[0];
}

fn cfunArrayEnsure(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 3);
    const array = try args_core.getArray(argv, 0);
    const newcount = try args_core.getInteger(argv, 1);
    const growth = try args_core.getInteger(argv, 2);
    if (newcount < 1) return raise.panic("expected positive integer");
    ensure(array, newcount, growth);
    return argv[0];
}

fn cfunArraySlice(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    const view = try args_core.getIndexed(argv, 0);
    const range = try args_core.getSlice(argv);
    const len = range.end - range.start;
    const array = new(len);
    if (array.*.data != null) {
        safe_memcpy(
            @ptrCast(array.*.data),
            @ptrCast(view.items.? + @as(usize, @intCast(range.start))),
            @sizeOf(repr.Value) *% asSize(len),
        );
    }
    array.*.count = len;
    return wrap.fromArray(array);
}

/// The aliasing check is the C original's and is not paranoia: concatenating
/// an array onto itself grows it, and the growth may move the payload, so the
/// view is reserved first and then taken again. It is done here rather than in
/// the loop because `janet_array_push` grows one element at a time.
fn appendIndexed(array: *types.JanetArray, x: repr.Value, vals_in: ?[*]const repr.Value, len_in: i32) raise.Raising(void) {
    var vals: ?[*]const repr.Value = vals_in;
    var len = len_in;
    if (array.*.data == vals) {
        ensure(array, array.*.count + len, 2);
        _ = args_core.indexedView(x, &vals, &len);
    }
    var j: i32 = 0;
    while (j < len) : (j += 1) try push(array, vals.?[@intCast(j)]);
}

fn cfunArrayConcat(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.arity(argv, 1, -1);
    const array = try args_core.getArray(argv, 0);
    var i: i32 = 1;
    while (i < @as(i32, @intCast(argv.len))) : (i += 1) {
        switch (repr.typeOf(argv[@intCast(i)])) {
            repr.Tag.array, repr.Tag.tuple => {
                var len: i32 = 0;
                var vals: ?[*]const repr.Value = null;
                _ = args_core.indexedView(argv[@intCast(i)], &vals, &len);
                try appendIndexed(array, argv[@intCast(i)], vals, len);
            },
            else => try push(array, argv[@intCast(i)]),
        }
    }
    return wrap.fromArray(array);
}

/// `array/join` differs from `array/concat` in exactly one way: a part that is
/// not indexed is an error here and is appended as a single element there.
fn cfunArrayJoin(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.arity(argv, 1, -1);
    const array = try args_core.getArray(argv, 0);
    var i: i32 = 1;
    while (i < @as(i32, @intCast(argv.len))) : (i += 1) {
        var len: i32 = 0;
        var vals: ?[*]const repr.Value = null;
        if (args_core.indexedView(argv[@intCast(i)], &vals, &len) == 0) {
            return pp_format.panicf("expected indexed type for argument %d, got %v", .{ i, argv[@intCast(i)] });
        }
        try appendIndexed(array, argv[@intCast(i)], vals, len);
    }
    return wrap.fromArray(array);
}

fn cfunArrayInsert(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.arity(argv, 2, -1);
    const array = try args_core.getArray(argv, 0);
    var at = try args_core.getInteger(argv, 1);
    if (at < 0) at = array.*.count + at + 1;
    if (at < 0 or at > array.*.count) {
        return pp_format.panicf("insertion index %d out of range [0,%d]", .{ at, array.*.count });
    }
    const chunksize = @as(usize, @intCast(@as(i32, @intCast(argv.len)) - 2)) *% @sizeOf(repr.Value);
    const restsize = @as(usize, @intCast(array.*.count - at)) *% @sizeOf(repr.Value);
    if (std.math.maxInt(i32) - (@as(i32, @intCast(argv.len)) - 2) < array.*.count) return raise.panic("array overflow");
    ensure(array, array.*.count + @as(i32, @intCast(argv.len)) - 2, 2);
    if (restsize != 0) {
        const dest = array.*.data.? + @as(usize, @intCast(at + @as(i32, @intCast(argv.len)) - 2));
        const src = array.*.data.? + @as(usize, @intCast(at));
        std.mem.copyBackwards(u8, @as([*]u8, @ptrCast(dest))[0..restsize], @as([*]const u8, @ptrCast(src))[0..restsize]);
    }
    safe_memcpy(@ptrCast(array.*.data.? + @as(usize, @intCast(at))), @ptrCast(argv[2..]), chunksize);
    array.*.count += @as(i32, @intCast(argv.len)) - 2;
    return argv[0];
}

fn cfunArrayRemove(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.arity(argv, 2, 3);
    const array = try args_core.getArray(argv, 0);
    var at = try args_core.getInteger(argv, 1);
    var n: i32 = 1;
    if (at < 0) at = array.*.count + at;
    if (at < 0 or at > array.*.count) {
        return pp_format.panicf("removal index %d out of range [0,%d]", .{ at, array.*.count });
    }
    if (@as(i32, @intCast(argv.len)) == 3) {
        n = try args_core.getInteger(argv, 2);
        if (n < 0) return pp_format.panicf("expected non-negative integer for argument n, got %v", .{argv[2]});
    }
    if (at + n > array.*.count) n = array.*.count - at;
    const moved = @as(usize, @intCast(array.*.count - at - n)) *% @sizeOf(repr.Value);
    if (moved != 0) {
        const dest = array.*.data.? + @as(usize, @intCast(at));
        const src = array.*.data.? + @as(usize, @intCast(at + n));
        std.mem.copyForwards(u8, @as([*]u8, @ptrCast(dest))[0..moved], @as([*]const u8, @ptrCast(src))[0..moved]);
    }
    array.*.count -= n;
    return argv[0];
}

fn cfunArrayTrim(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    const array = try args_core.getArray(argv, 0);
    if (array.*.count != 0) {
        if (array.*.count < array.*.capacity) {
            const new_data = utils.realloc(
                @ptrCast(array.*.data),
                @as(usize, @intCast(array.*.count)) *% @sizeOf(repr.Value),
            ) orelse fatal.outOfMemory();
            array.*.data = @ptrCast(@alignCast(new_data));
            array.*.capacity = array.*.count;
        }
    } else {
        array.*.capacity = 0;
        utils.free(@ptrCast(array.*.data));
        array.*.data = null;
    }
    return argv[0];
}

fn cfunArrayClear(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    (try args_core.getArray(argv, 0)).*.count = 0;
    return argv[0];
}

pub fn lib(env: *types.JanetTable) void {
    const entries = comptime [_]corefn.Entry{
        corefn.reg("array/new", &cfunArrayNew, @src(), "(array/new capacity)", "Creates a new empty array with a pre-allocated capacity. The same as " ++
            "`(array)` but can be more efficient if the maximum size of an array is known."),
        corefn.reg("array/weak", &cfunArrayWeak, @src(), "(array/weak capacity)", "Creates a new empty array with a pre-allocated capacity and support for weak references. Similar to `array/new`."),
        corefn.reg("array/new-filled", &cfunArrayNewFilled, @src(), "(array/new-filled count &opt value)", "Creates a new array of `count` elements, all set to `value`, which defaults to nil. Returns the new array."),
        corefn.reg("array/fill", &cfunArrayFill, @src(), "(array/fill arr &opt value)", "Replace all elements of an array with `value` (defaulting to nil) without changing the length of the array. " ++
            "Returns the modified array."),
        corefn.reg("array/pop", &cfunArrayPop, @src(), "(array/pop arr)", "Remove the last element of the array and return it. If the array is empty, will return nil. Modifies " ++
            "the input array."),
        corefn.reg("array/peek", &cfunArrayPeek, @src(), "(array/peek arr)", "Returns the last element of the array. Does not modify the array."),
        corefn.reg("array/push", &cfunArrayPush, @src(), "(array/push arr & xs)", "Push all the elements of xs to the end of an array. Modifies the input array and returns it."),
        corefn.reg("array/ensure", &cfunArrayEnsure, @src(), "(array/ensure arr capacity growth)", "Ensures that the memory backing the array is large enough for `capacity` " ++
            "items at the given rate of growth. `capacity` and `growth` must be integers. " ++
            "If the backing capacity is already enough, then this function does nothing. " ++
            "Otherwise, the backing memory will be reallocated so that there is enough space."),
        corefn.reg("array/slice", &cfunArraySlice, @src(), "(array/slice arrtup &opt start end)", "Takes a slice of array or tuple from `start` to `end`. The range is half open, " ++
            "[start, end). Indexes can also be negative, indicating indexing from the " ++
            "end of the array. By default, `start` is 0 and `end` is the length of the array. " ++
            "Note that if the range is negative, it is taken as (start, end] to allow a full " ++
            "negative slice range. Returns a new array."),
        corefn.reg("array/concat", &cfunArrayConcat, @src(), "(array/concat arr & parts)", "Concatenates a variable number of arrays (and tuples) into the first argument, " ++
            "which must be an array. If any of the parts are arrays or tuples, their elements will " ++
            "be inserted into the array. Otherwise, each part in `parts` will be appended to `arr` in order. " ++
            "Return the modified array `arr`."),
        corefn.reg("array/insert", &cfunArrayInsert, @src(), "(array/insert arr at & xs)", "Insert all `xs` into array `arr` at index `at`. `at` should be an integer between " ++
            "0 and the length of the array. A negative value for `at` will index backwards from " ++
            "the end of the array, inserting after the index such that inserting at -1 appends to " ++
            "the array. Returns the array."),
        corefn.reg("array/remove", &cfunArrayRemove, @src(), "(array/remove arr at &opt n)", "Remove up to `n` elements starting at index `at` in array `arr`. `at` can index from " ++
            "the end of the array with a negative index, and `n` must be a non-negative integer. " ++
            "By default, `n` is 1. " ++
            "Returns the array."),
        corefn.reg("array/trim", &cfunArrayTrim, @src(), "(array/trim arr)", "Set the backing capacity of an array to its current length. Returns the modified array."),
        corefn.reg("array/clear", &cfunArrayClear, @src(), "(array/clear arr)", "Empties an array, setting it's count to 0 but does not free the backing capacity. " ++
            "Returns the modified array."),
        corefn.reg("array/join", &cfunArrayJoin, @src(), "(array/join arr & parts)", "Join a variable number of arrays and tuples into the first argument, " ++
            "which must be an array. " ++
            "Return the modified array `arr`."),
    };
    corefn.install(env, entries);
}
