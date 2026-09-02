//! `Array`: the growable `Janet` container, its capacity policy, its
//! push/pop primitives and the `array/*` surface.
//!
//! `buffers.zig` is the sibling: one data structure with two element types -- a
//! collectable header followed by `count`/`capacity`/`data`, with `data` in a
//! separate heap block reallocated in place. They are separate files because
//! Janet's own taxonomy separates them: an array is **indexed** and a buffer is
//! **bytes**, which is the distinction the indexed and bytes views draw.
//! Neither calls into the other; the shared layout is a fact about the
//! structures, not a dependency.
//!
//! An array is not traversed here. `gc/mark.zig` walks its elements; nothing
//! below marks, and nothing below frees a collectable block.
//!
//! **Nothing here holds anything across a raise.** `gcalloc` can trigger a
//! collection, which runs finalizers, which may raise, and `push` raises on
//! overflow — but nothing below holds a raw block between acquiring it and
//! storing it where the collector can see it.
//!
//! ## Arithmetic reproduced rather than repaired
//!
//! The capacity policy multiplies a caller-supplied count by a caller-supplied
//! growth factor and trusts the product to be positive. C's conversion of the
//! negative result to `size_t` is defined and wraps; Zig's would trap, so the
//! conversions are written out through `asSize` below and the arithmetic uses
//! wrapping operators wherever the C original can wrap.
//!
//! **`array/ensure` validates both of its arguments**, and the reachable
//! instance that makes that necessary is here rather than in `buffers.zig`:
//! passing a growth factor through unchecked lets a growth of zero free an
//! array's backing store while leaving `count` untouched — a use-after-free
//! reachable from pure Janet — and a negative growth request almost the whole
//! address space, ending the process through `JANET_OUT_OF_MEMORY`, which
//! `protect` cannot catch. `test/buffer_array.zig` pins both refusals.
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
const corefn = @import("../corefn.zig");
const repr = @import("repr");
const vm_state = @import("../vm/state.zig");
const raise = @import("../raise.zig");
const pp_format = @import("../pp/format.zig");
const gc_alloc = @import("../gc.zig");
const utils = @import("../utils.zig");
const wrap = @import("helpers/wrap.zig");
const args_core = @import("../args.zig");
const fatal = @import("../fatal.zig");
const abi = @import("abi");
const tables = @import("tables.zig");

pub const Array = struct {
    gc: abi.GCObject = .{},
    count: usize = 0,
    capacity: usize = 0,
    data: ?[*]repr.Value = null,

    /// The live elements. Empty rather than a trap for an array that has
    /// never been grown: `janet_array_init(a, 0)` leaves `data` null, which
    /// is the ordinary state of `(array/new 0)` and of every fresh
    /// `Array` on a fiber's stack.
    pub inline fn slice(self: anytype) utils.View(@TypeOf(self), repr.Value) {
        if (self.count == 0) return &.{};
        return self.data.?[0..self.count];
    }

    /// Store one element at the end and advance the count. **The caller has
    /// already made room** -- `arrays.ensure` -- because growth reads the
    /// collector's allocator and this type cannot.
    ///
    /// The slot it writes is one past `slice()`, which is why it is a method
    /// rather than an index at the call site. See `vm_state.Vector`: the same
    /// pair, for the same reason, on the arrays the VM grows for itself.
    pub inline fn appendAssumingCapacity(self: *Array, x: repr.Value) void {
        // Non-negativity is the type's now, not a precondition: `count` is
        // `usize`. Room still is not.
        std.debug.assert(self.count < self.capacity);
        self.data.?[self.count] = x;
        self.count += 1;
    }

    /// The allocation, `capacity` long, for a caller that fills the elements
    /// *before* declaring the count.
    ///
    /// The parser does that on purpose: it pops its argument stack backwards
    /// into a fresh array and only then says how long the array is, so that
    /// a collection in the middle -- there is none, but the order is the C
    /// original's -- would never see an uninitialised element. `slice()` is
    /// empty throughout that loop, which is correct and not what the writer
    /// wants.
    pub inline fn reserved(self: *Array) []repr.Value {
        if (self.capacity == 0) return &.{};
        return self.data.?[0..self.capacity];
    }

    /// Remove and answer the last element. The caller has checked it is not
    /// empty.
    pub inline fn popAssumingAny(self: *Array) repr.Value {
        const last = self.slice()[self.count - 1];
        self.count -= 1;
        return last;
    }
};

// ------------------------------------------------------------------- array

/// Give an array its initial payload. A capacity of zero leaves `data` null,
/// and the growth paths handle that: `janet_realloc(NULL, n)` allocates.
fn init(array: *Array, capacity: usize) void {
    var data: ?[*]repr.Value = null;
    if (capacity > 0) {
        // Charged directly rather than through `gc.gcpressure`, because the
        // term is the array's own bytes and nothing else.
        vm_state.current().gc.next_collection +%= capacity *% @sizeOf(repr.Value);
        data = @ptrCast(@alignCast(utils.malloc(@sizeOf(repr.Value) *% capacity) orelse
            fatal.outOfMemory()));
    }
    array.count = 0;
    array.capacity = capacity;
    array.data = data;
}

pub fn new(capacity: usize) *Array {
    const array = gc_alloc.gcalloc(Array, .array);
    init(array, capacity);
    return array;
}

/// An array whose elements do not keep their targets alive. The only
/// difference is the memory type, which puts the block on the weak heap and
/// sends it to `dropDeadElements` in `gc_sweep.zig` instead of to the marker.
pub fn weak(capacity: usize) *Array {
    const array = gc_alloc.gcalloc(Array, .array_weak);
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
pub fn newFrom(elements: []const repr.Value) *Array {
    const count: i32 = @intCast(elements.len);
    const array = gc_alloc.gcalloc(Array, .array);
    array.capacity = elements.len;
    array.count = elements.len;
    array.data = @ptrCast(@alignCast(utils.malloc(@sizeOf(repr.Value) *% utils.asSize(count))));
    if (array.data == null) fatal.outOfMemory();
    @memcpy(array.slice(), elements);
    return array;
}

/// Grow an array to hold `capacity_in` elements, multiplied by `growth`.
///
/// `growth` is a multiplier, so it is a count of copies rather than a signed
/// quantity: `cfunArrayEnsure` rejects a growth below one, and every internal
/// caller passes one or two. The clamp at `INT32_MAX` stays,
/// because the capacity it produces is what a marshalled array carries.
pub fn ensure(array: *Array, capacity_in: usize, growth: usize) void {
    const old = array.data;
    if (capacity_in <= array.capacity) return;
    // Saturating rather than wrapping: `capacity_in` is at most `INT32_MAX`
    // and so is `growth`, so the product fits, but the clamp is what decides
    // the result rather than the width.
    const wanted = std.math.mul(usize, capacity_in, growth) catch std.math.maxInt(usize);
    const capacity: usize = @min(wanted, std.math.maxInt(i32));
    const new_data = utils.realloc(@ptrCast(old), capacity *% @sizeOf(repr.Value)) orelse
        fatal.outOfMemory();
    // Charged after the allocation, where the buffer twin charges it before.
    vm_state.current().gc.next_collection +%= (capacity -% array.capacity) *% @sizeOf(repr.Value);
    array.data = @ptrCast(@alignCast(new_data));
    array.capacity = capacity;
}

/// Set an array's length, filling any newly covered slots with nil.
///
/// The count is a count. This took an `i32` and returned on a negative one
/// while there was a C API whose `int32_t` was the door; there is no such door
/// now -- no `array/setcount` binding, nothing in `capi.zig` -- so the range
/// check is the type, and a caller with a Janet integer converts at its own
/// checked conversion.
pub fn setcount(array: *Array, count: usize) void {
    if (count > array.count) {
        ensure(array, count, 1);
        @memset(array.reserved()[array.count..count], wrap.fromNil());
    }
    array.count = count;
}

pub fn push(array: *Array, x: repr.Value) raise.Raising(void) {
    if (array.count == std.math.maxInt(i32)) {
        return raise.panic("array overflow");
    }
    ensure(array, array.count + 1, 2);
    array.appendAssumingCapacity(x);
}

pub fn pop(array: *Array) repr.Value {
    if (array.count != 0) return array.popAssumingAny();
    return wrap.fromNil();
}

pub fn peek(array: *Array) repr.Value {
    if (array.count != 0) {
        return array.slice()[@intCast(array.count - 1)];
    }
    return wrap.fromNil();
}

// ==========================================================================
// The cfunction surface.
//
// These raise, and a published `CFunction` has no error channel, so each
// delivers its raise through an abi. Nothing below holds anything across a
// call that can raise -- which for a growable container means in particular
// that no local caches `data` across an `ensure`, because a reallocation
// invalidates it whether or not anything raises.
// ==========================================================================

/// `array/new` takes a signed integer and C reserved nothing for a negative
/// one: `janet_array(-5)` left `data` null and recorded the negative as the
/// capacity, and every later operation grew from empty. A capacity is a count
/// here, so the floor is written down.
fn cfunArrayNew(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    const capacity = try args_core.getInteger(argv, 0);
    return wrap.fromArray(new(if (capacity < 0) 0 else @intCast(capacity)));
}

fn cfunArrayWeak(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    const capacity = try args_core.getInteger(argv, 0);
    return wrap.fromArray(weak(if (capacity < 0) 0 else @intCast(capacity)));
}

fn cfunArrayNewFilled(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.arity(argv, 1, 2);
    const count: usize = @intCast(try args_core.getNat(argv, 0));
    const x = if (argv.len == 2) argv[1] else wrap.fromNil();
    const array = new(count);
    @memset(array.reserved()[0..count], x);
    array.count = count;
    return wrap.fromArray(array);
}

fn cfunArrayFill(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.arity(argv, 1, 2);
    const array = try args_core.getArray(argv, 0);
    const x = if (argv.len == 2) argv[1] else wrap.fromNil();
    @memset(array.slice(), x);
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
    if (std.math.maxInt(i32) - argv.len + 1 <= array.count) return raise.panic("array overflow");
    // Ordered so it cannot underflow: `argv.len` is at least one (arity is
    // 1..-1), so `count + len - 1` is never below `count`. The signed form
    // this replaces computed `count - 1` first, which is -1 for an empty
    // array and was fine only because it was signed.
    const newcount = array.count + argv.len - 1;
    ensure(array, newcount, 2);
    if (argv.len > 1) {
        @memcpy(array.data.?[array.count..][0 .. argv.len - 1], argv[1..]);
    }
    array.count = newcount;
    return argv[0];
}

fn cfunArrayEnsure(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 3);
    const array = try args_core.getArray(argv, 0);
    const newcount = try args_core.getInteger(argv, 1);
    const growth = try args_core.getInteger(argv, 2);
    // Both arguments, not just the count. Without the second check a growth
    // of zero frees the backing store and leaves `count` claiming the
    // elements, and a negative one asks for most of the address space.
    if (newcount < 1) return raise.panic("expected positive integer");
    if (growth < 1) return raise.panic("expected positive integer");
    ensure(array, @intCast(newcount), @intCast(growth));
    return argv[0];
}

fn cfunArraySlice(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    const view = try args_core.getIndexed(argv, 0);
    const range = try args_core.getSlice(argv);
    const len: usize = @intCast(range.end - range.start);
    const array = new(len);
    if (len != 0) @memcpy(array.data.?[0..len], view[@intCast(range.start)..][0..len]);
    array.count = len;
    return wrap.fromArray(array);
}

/// The aliasing check is the C original's and is not paranoia: concatenating
/// an array onto itself grows it, and the growth may move the payload, so the
/// view is reserved first and then taken again. It is done here rather than in
/// the loop because `janet_array_push` grows one element at a time.
fn appendIndexed(array: *Array, x: repr.Value, vals_in: []const repr.Value) raise.Raising(void) {
    var vals = vals_in;
    if (array.data == vals.ptr) {
        ensure(array, array.count + vals.len, 2);
        vals = args_core.indexedView(x).?;
    }
    for (vals) |val| try push(array, val);
}

fn cfunArrayConcat(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.arity(argv, 1, -1);
    const array = try args_core.getArray(argv, 0);
    for (argv[1..]) |part| {
        switch (repr.typeOf(part)) {
            repr.Tag.array, repr.Tag.tuple => {
                const vals = args_core.indexedView(part).?;
                try appendIndexed(array, part, vals);
            },
            else => try push(array, part),
        }
    }
    return wrap.fromArray(array);
}

/// `array/join` differs from `array/concat` in exactly one way: a part that is
/// not indexed is an error here and is appended as a single element there.
fn cfunArrayJoin(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.arity(argv, 1, -1);
    const array = try args_core.getArray(argv, 0);
    for (argv[1..], 1..) |part, i| {
        const vals = args_core.indexedView(part) orelse {
            return pp_format.panicf("expected indexed type for argument %d, got %v", .{ @as(i64, @intCast(i)), part });
        };
        try appendIndexed(array, part, vals);
    }
    return wrap.fromArray(array);
}

fn cfunArrayInsert(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.arity(argv, 2, -1);
    const array = try args_core.getArray(argv, 0);
    var at = try args_core.getInteger(argv, 1);
    const count: i32 = @intCast(array.count);
    if (at < 0) at = count + at + 1;
    if (at < 0 or at > count) {
        return pp_format.panicf("insertion index %d out of range [0,%d]", .{ at, count });
    }
    const inserted = argv.len - 2;
    const rest = @as(usize, @intCast(count - at));
    if (std.math.maxInt(i32) - @as(i32, @intCast(inserted)) < count) return raise.panic("array overflow");
    ensure(array, array.count + inserted, 2);
    if (rest != 0) {
        const from = @as(usize, @intCast(at));
        const slots = array.reserved();
        std.mem.copyBackwards(repr.Value, slots[from + inserted ..][0..rest], slots[from..][0..rest]);
    }
    // **Guarded, because `(array/insert a n)` inserts nothing.** With no values
    // to copy `ensure` may not have allocated at all, so `data` is still null
    // and unwrapping it panics -- where C reached `memcpy(NULL, NULL, 0)` and
    // returned the array unchanged. `test/suite-array.janet` pins the case.
    if (inserted != 0) {
        @memcpy(array.data.?[@intCast(at)..][0..inserted], argv[2..]);
    }
    array.count += inserted;
    return argv[0];
}

fn cfunArrayRemove(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.arity(argv, 2, 3);
    const array = try args_core.getArray(argv, 0);
    var at = try args_core.getInteger(argv, 1);
    var n: i32 = 1;
    const count: i32 = @intCast(array.count);
    if (at < 0) at = count + at;
    if (at < 0 or at > count) {
        return pp_format.panicf("removal index %d out of range [0,%d]", .{ at, count });
    }
    if (argv.len == 3) {
        n = try args_core.getInteger(argv, 2);
        if (n < 0) return pp_format.panicf("expected non-negative integer for argument n, got %v", .{argv[2]});
    }
    if (at + n > count) n = count - at;
    const moved = @as(usize, @intCast(count - at - n)) *% @sizeOf(repr.Value);
    if (moved != 0) {
        const dest = array.data.? + @as(usize, @intCast(at));
        const src = array.data.? + @as(usize, @intCast(at + n));
        std.mem.copyForwards(u8, @as([*]u8, @ptrCast(dest))[0..moved], @as([*]const u8, @ptrCast(src))[0..moved]);
    }
    array.count -= @as(usize, @intCast(n));
    return argv[0];
}

fn cfunArrayTrim(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    const array = try args_core.getArray(argv, 0);
    if (array.count != 0) {
        if (array.count < array.capacity) {
            array.data = utils.resizeMany(repr.Value, array.data, @intCast(array.count));
            array.capacity = array.count;
        }
    } else {
        array.capacity = 0;
        utils.free(@ptrCast(array.data));
        array.data = null;
    }
    return argv[0];
}

fn cfunArrayClear(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    (try args_core.getArray(argv, 0)).count = 0;
    return argv[0];
}

pub fn lib(env: *tables.Table) void {
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
