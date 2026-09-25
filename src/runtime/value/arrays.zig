//! The growable indexed container, its capacity policy, its push and pop
//! primitives, and the `array/*` surface.
//!
//! `new` reserves capacity and `newFrom` copies elements. `push`, `pop` and
//! `peek` are the ends, `ensure` grows the backing store, and `setcount` sets
//! the length, filling any new slots with nil. `weak` builds an array whose
//! elements do not keep their targets alive.
//!
//! `buffers.zig` is the sibling: one data structure with two element types, a
//! collectable header followed by `count`, `capacity` and `data`, with `data`
//! in a separate heap block reallocated in place. They are separate files
//! because Janet's taxonomy separates them: an array is indexed and a buffer
//! is bytes, the distinction `getIndexed` and `getBytes` draw. Neither calls
//! into the other, and the shared layout is a fact rather than a dependency.
//!
//! An array is not traversed here. `gc/mark.zig` walks its elements, nothing
//! below marks, and nothing below frees a collectable block. Nothing below is
//! stranded by a raise either: `gcalloc` can collect and `push` raises on
//! overflow, but no raw block sits between being acquired and being stored
//! where the collector can see it.
//!
//! ## Why `array/ensure` validates both of its arguments
//!
//! The reachable instance that makes that necessary is here rather than in
//! `buffers.zig`. A growth of zero frees the backing store while leaving
//! `count` untouched, which is a use-after-free reachable from pure Janet, and
//! a negative growth asks for almost the whole address space, ending the
//! process where `protect` cannot catch it. `test/buffer_array.zig` pins both
//! refusals, and `ensure` saturates its product rather than trusting it.
//!
//! ## Three asymmetries with `buffers.zig`
//!
//! None of the three is observable. `ensure` charges GC pressure after the
//! reallocation where the buffer's charges before, so a failed growth goes
//! unaccounted and both end the process anyway. `init` adds to
//! `vm.gc.next_collection` directly where the buffer's calls `gcpressure`. And
//! `newFrom` charges nothing at all.
//!
//! ## The nfunction surface
//!
//! A published `NFunction` has no error channel in its signature, so the
//! `nfunArray*` functions deliver a raise through `raise.Error!`. Nothing in
//! them is stranded across a call that can raise, which for a growable
//! container means in particular that no local caches `data` across an
//! `ensure`: a reallocation invalidates it whether or not anything raises.

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
const fatal = @import("../fatal.zig");
const gc_alloc = @import("../gc.zig");
const pp_format = @import("../pp/format.zig");
const raise = @import("../../api/raise.zig");
const repr = @import("repr");
const tables = @import("tables.zig");
const utils = @import("../utils.zig");
const vm_state = @import("../vm/state.zig");
const wrap = @import("helpers/wrap.zig");

// ==========================================================================
// Types
// ==========================================================================

/// The growable indexed container: a collectable header, a count, a capacity,
/// and a payload in a separate heap block.
///
/// The methods below allocate nothing. `ensure` and the constructors are what
/// reach the allocator, because growth reads the collector's state and this
/// type cannot.
pub const Array = struct {
    gc: abi.GCObject = .{},
    count: usize = 0,
    capacity: usize = 0,
    data: ?[*]repr.Value = null,

    /// The live elements. Empty rather than a trap for an array that has never
    /// been grown: `init(a, 0)` leaves `data` null, which is the ordinary state
    /// of `(array/new 0)` and of every fresh `Array` on a fiber's stack.
    pub inline fn slice(self: anytype) utils.View(@TypeOf(self), repr.Value) {
        if (self.count == 0) return &.{};
        return self.data.?[0..self.count];
    }

    /// Stores one element at the end and advances the count. The caller has
    /// already made room, through `arrays.ensure`.
    ///
    /// The slot it writes is one past `slice()`, so it is a method rather than
    /// an index at the call site. `buffers.Buffer` has the same pair, for the
    /// same reason, over bytes.
    pub inline fn appendAssumingCapacity(self: *Array, x: repr.Value) void {
        // Non-negativity is the type's now, not a precondition: `count` is
        // `usize`. Room still is not.
        std.debug.assert(self.count < self.capacity);
        self.data.?[self.count] = x;
        self.count += 1;
    }

    /// The allocation, `capacity` long, for a caller that fills the elements
    /// before declaring the count.
    ///
    /// The parser does that on purpose: it pops its argument stack backwards
    /// into a fresh array and only then says how long the array is, so that a
    /// collection in the middle would never see an uninitialised element.
    /// `slice()` is empty throughout that loop, which is correct and is not
    /// what a reader of the loop would expect.
    pub inline fn reserved(self: *Array) []repr.Value {
        if (self.capacity == 0) return &.{};
        return self.data.?[0..self.capacity];
    }

    /// Removes and returns the last element. The caller has checked that the
    /// array is not empty.
    pub inline fn popAssumingAny(self: *Array) repr.Value {
        const last = self.slice()[self.count - 1];
        self.count -= 1;
        return last;
    }
};

// ==========================================================================
// Public functions
// ==========================================================================

/// Grows `array` to fit `capacity_in` elements, multiplied by `growth`.
///
/// `growth` is a multiplier, so it is a count of copies rather than a signed
/// quantity: `nfunArrayEnsure` rejects a growth below one, and every internal
/// caller passes one or two. The clamp at `maxInt(i32)` stays, because the
/// capacity it produces is what a marshalled array records.
pub fn ensure(array: *Array, capacity_in: usize, growth: usize) void {
    const old = array.data;
    if (capacity_in <= array.capacity) return;
    // Saturating rather than wrapping: `capacity_in` is at most `maxInt(i32)`
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

/// Installs the `array/` nfunctions into `env`.
pub fn lib(env: *tables.Table) void {
    const entries = comptime [_]corefn.Entry{
        corefn.reg("array/new", &nfunArrayNew, @src(), "(array/new capacity)", "Creates a new empty array with a pre-allocated capacity. The same as " ++
            "`(array)` but can be more efficient if the maximum size of an array is known."),
        corefn.reg("array/weak", &nfunArrayWeak, @src(), "(array/weak capacity)", "Creates a new empty array with a pre-allocated capacity and support for weak references. Similar to ^array/new."),
        corefn.reg("array/new-filled", &nfunArrayNewFilled, @src(), "(array/new-filled count [value])", "Creates a new array of count elements, all set to value, which defaults to nil. Returns the new array."),
        corefn.reg("array/fill", &nfunArrayFill, @src(), "(array/fill arr [value])", "Replaces all elements of an array with value (defaulting to nil) without changing the length of the array. " ++
            "Returns the modified array."),
        corefn.reg("array/pop", &nfunArrayPop, @src(), "(array/pop arr)", "Removes the last element of the array and returns it. If the array is empty, returns nil. Modifies " ++
            "the input array."),
        corefn.reg("array/peek", &nfunArrayPeek, @src(), "(array/peek arr)", "Returns the last element of the array. Does not modify the array."),
        corefn.reg("array/push", &nfunArrayPush, @src(), "(array/push arr & xs)", "Pushes all the elements of xs to the end of an array. Modifies the input array and returns it."),
        corefn.reg("array/ensure", &nfunArrayEnsure, @src(), "(array/ensure arr capacity growth)", "Ensures that the memory backing the array is large enough for capacity " ++
            "items at the given rate of growth. capacity and growth must be integers. " ++
            "If the backing capacity is already enough, then this function does nothing. " ++
            "Otherwise, the backing memory is reallocated so that there is enough space."),
        corefn.reg("array/slice", &nfunArraySlice, @src(), "(array/slice arrtup [start [end]])", "Takes a slice of array or tuple from start to end. The range is half open, " ++
            "[start, end). Indexes can also be negative, indicating indexing from the " ++
            "end of the array. By default, start is 0 and end is the length of the array. " ++
            "Note that if the range is negative, it is taken as (start, end] to allow a full " ++
            "negative slice range. Returns a new array."),
        corefn.reg("array/concat", &nfunArrayConcat, @src(), "(array/concat arr & parts)", "Concatenates a variable number of arrays (and tuples) into the first argument, " ++
            "which must be an array. If any of the parts are arrays or tuples, their elements are " ++
            "inserted into the array. Otherwise, each part in parts is appended to arr in order. " ++
            "Returns the modified array arr."),
        corefn.reg("array/insert", &nfunArrayInsert, @src(), "(array/insert arr at & xs)", "Inserts all xs into array arr at index at. at should be an integer between " ++
            "0 and the length of the array. A negative value for at indexes backwards from " ++
            "the end of the array, inserting after the index such that inserting at -1 appends to " ++
            "the array. Returns the array."),
        corefn.reg("array/remove", &nfunArrayRemove, @src(), "(array/remove arr at [n])", "Removes up to n elements starting at index at in array arr. at can index from " ++
            "the end of the array with a negative index, and n must be a non-negative integer. " ++
            "By default, n is 1. " ++
            "Returns the array."),
        corefn.reg("array/trim", &nfunArrayTrim, @src(), "(array/trim arr)", "Sets the backing capacity of an array to its current length. Returns the modified array."),
        corefn.reg("array/clear", &nfunArrayClear, @src(), "(array/clear arr)", "Empties an array, setting it's count to 0 but does not free the backing capacity. " ++
            "Returns the modified array."),
        corefn.reg("array/join", &nfunArrayJoin, @src(), "(array/join arr & parts)", "Joins a variable number of arrays and tuples into the first argument, " ++
            "which must be an array. " ++
            "Returns the modified array arr."),
    };
    corefn.install(env, entries);
}

/// Allocates an array with room for `capacity` elements and a count of zero.
pub fn new(capacity: usize) *Array {
    const array = gc_alloc.gcalloc(Array, .array);
    init(array, capacity);
    return array;
}

/// Allocates an array of `elements`, copied, with count and capacity both
/// their number.
///
/// `newFrom` allocates and copies where `new` reserves: `new(4)` returns an
/// array of capacity four and count zero, and this returns one of capacity and
/// count four with the elements in it.
///
/// This does not go through `init` and charges no GC pressure for the payload
/// it allocates, which is the third asymmetry the header names.
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

/// Returns `array`'s last element, or nil where it is empty, without modifying
/// the array.
pub fn peek(array: *Array) repr.Value {
    if (array.count != 0) {
        return array.slice()[@intCast(array.count - 1)];
    }
    return wrap.fromNil();
}

/// Removes and returns `array`'s last element, or nil where it is empty.
pub fn pop(array: *Array) repr.Value {
    if (array.count != 0) return array.popAssumingAny();
    return wrap.fromNil();
}

/// Appends `x` to `array`, growing it where there is no room.
///
/// Raises where the count has reached `maxInt(i32)`, which is the ceiling
/// `ensure` clamps a capacity to.
pub fn push(array: *Array, x: repr.Value) raise.Error!void {
    if (array.count == std.math.maxInt(i32)) {
        return raise.panic("array overflow");
    }
    ensure(array, array.count + 1, 2);
    array.appendAssumingCapacity(x);
}

/// Pushes `x` onto the array a `Value` names, refusing anything that is not an
/// array.
///
/// This is the module boundary's form. `*Array` stays off the author surface,
/// so a module names an array the only way it can, by the `Value`, and the tag
/// test is on this side. The refusal names the type and the value and no
/// argument slot, because there is no slot: the array may have come out of a
/// tuple or a dictionary, where a slot number would name nothing the caller can
/// see.
pub fn pushChecked(v: repr.Value, x: repr.Value) raise.Error!void {
    if (!repr.checkType(v, repr.Tag.array)) {
        return pp_format.panicf("expected %T, got %v", .{ repr.TagSet.one(repr.Tag.array), v });
    }
    return push(wrap.toArray(v), x);
}

/// Sets `array`'s length to `count`, filling any newly covered slots with nil.
///
/// The count is a count, so the range check is the type: nothing reaches this
/// with a negative value, there being no `array/setcount` binding and nothing
/// in `capi.zig`, and a caller with a Janet integer converts at its own
/// checked conversion.
pub fn setcount(array: *Array, count: usize) void {
    if (count > array.count) {
        ensure(array, count, 1);
        @memset(array.reserved()[array.count..count], wrap.fromNil());
    }
    array.count = count;
}

/// Allocates an array whose elements do not keep their targets alive.
///
/// The only difference from `new` is the memory type, which puts the block on
/// the weak heap and sends it to `gc/sweep.zig`'s `dropDeadElements` instead
/// of to the marker.
pub fn weak(capacity: usize) *Array {
    const array = gc_alloc.gcalloc(Array, .array_weak);
    init(array, capacity);
    return array;
}

// ==========================================================================
// Private functions
// ==========================================================================

/// Appends the elements of an indexed value to `array`, one run at a time.
///
/// `x` is the value and `it` is its iterator, which this reads to the end.
/// This function raises where `args_core.Chunks.next` does, and where the
/// result would be longer than an array can be.
///
/// The room for every element is reserved before the first run is taken,
/// because a run stays valid only until the next call that can allocate. That
/// reservation is also what can move a run: concatenating an array onto
/// itself makes the array both the source and the destination, and the growth
/// may move the payload the run points into, so the view is taken again after
/// it. A vector's and an abstract's runs come from their own nodes and
/// payloads, which the growth does not touch.
fn appendIndexed(array: *Array, x: repr.Value, it: *args_core.Chunks) raise.Error!void {
    if (array.count +| it.len > std.math.maxInt(i32)) return raise.panic("array overflow");
    const aliased = switch (it.source) {
        .contiguous => |vals| array.data == vals.ptr,
        .vector, .abstract => false,
    };
    ensure(array, array.count + it.len, 2);
    if (aliased) it.source = .{ .contiguous = args_core.items(x).? };
    while (try it.next()) |run| {
        @memcpy(array.reserved()[array.count..][0..run.len], run);
        array.count += run.len;
    }
}

/// `array/clear`: the count set to zero, the backing capacity kept.
fn nfunArrayClear(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    (try args_core.getArray(argv, 0)).count = 0;
    return argv[0];
}

/// `array/concat`: the remaining arguments appended, an indexed part element
/// by element and anything else as a single element.
fn nfunArrayConcat(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, -1);
    const array = try args_core.getArray(argv, 0);
    for (argv[1..]) |part| {
        var source = try args_core.chunks(part);
        if (source) |*it| {
            try appendIndexed(array, part, it);
        } else {
            try push(array, part);
        }
    }
    return wrap.fromArray(array);
}

/// `array/ensure`: the backing store grown to a capacity at a rate of growth.
///
/// Both arguments are checked and not only the count. The header says what the
/// second check prevents.
fn nfunArrayEnsure(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 3);
    const array = try args_core.getArray(argv, 0);
    const newcount = try args_core.getInteger(argv, 1);
    const growth = try args_core.getInteger(argv, 2);
    // Both arguments, not just the count. Without the second check a growth
    // of zero frees the backing store and leaves `count` claiming the
    // elements, and a negative growth asks for most of the address space.
    if (newcount < 1) return raise.panic("expected positive integer");
    if (growth < 1) return raise.panic("expected positive integer");
    ensure(array, @intCast(newcount), @intCast(growth));
    return argv[0];
}

/// `array/fill`: every live element replaced, the length unchanged.
fn nfunArrayFill(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, 2);
    const array = try args_core.getArray(argv, 0);
    const x = if (argv.len == 2) argv[1] else wrap.fromNil();
    @memset(array.slice(), x);
    return argv[0];
}

/// `array/insert`: values inserted at an index, which may count back from the
/// end.
fn nfunArrayInsert(argv: []repr.Value) raise.Error!repr.Value {
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
    // Guarded, because `(array/insert a n)` inserts nothing. With no values to
    // copy, `ensure` may not have allocated at all, so `data` is still null and
    // unwrapping it panics. `test/suite-array.wattle` pins the case.
    if (inserted != 0) {
        @memcpy(array.data.?[@intCast(at)..][0..inserted], argv[2..]);
    }
    array.count += inserted;
    return argv[0];
}

/// `array/join`: the same as `array/concat` but for one thing, that a part
/// which is not indexed is an error here and is appended as a single element
/// there.
fn nfunArrayJoin(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, -1);
    const array = try args_core.getArray(argv, 0);
    for (argv[1..], 1..) |part, i| {
        var source = try args_core.chunks(part);
        if (source) |*it| {
            try appendIndexed(array, part, it);
        } else {
            return pp_format.panicf("expected indexed type for argument %d, got %v", .{ @as(i64, @intCast(i)), part });
        }
    }
    return wrap.fromArray(array);
}

/// `array/new`: an empty array with capacity reserved.
///
/// The binding takes a signed integer, and a negative one reserves nothing:
/// `(array/new -5)` is an empty array that every later operation grows from.
/// A capacity is a count here, so the floor at zero is written down rather
/// than arrived at through a negative capacity nothing can satisfy.
fn nfunArrayNew(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const capacity = try args_core.getInteger(argv, 0);
    return wrap.fromArray(new(if (capacity < 0) 0 else @intCast(capacity)));
}

/// `array/new-filled`: an array of `count` elements, all set to one value.
fn nfunArrayNewFilled(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, 2);
    const count: usize = @intCast(try args_core.getNat(argv, 0));
    const x = if (argv.len == 2) argv[1] else wrap.fromNil();
    const array = new(count);
    @memset(array.reserved()[0..count], x);
    array.count = count;
    return wrap.fromArray(array);
}

/// `array/peek`: the last element, without modifying the array.
fn nfunArrayPeek(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    return peek(try args_core.getArray(argv, 0));
}

/// `array/pop`: the last element, removed.
fn nfunArrayPop(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    return pop(try args_core.getArray(argv, 0));
}

/// `array/push`: every remaining argument appended.
fn nfunArrayPush(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, -1);
    const array = try args_core.getArray(argv, 0);
    if (std.math.maxInt(i32) - argv.len + 1 <= array.count) return raise.panic("array overflow");
    // Ordered so it cannot underflow: `argv.len` is at least one (arity is
    // 1..-1), so `count + len - 1` is never below `count`. Computing
    // `count - 1` first would underflow on an empty array.
    const newcount = array.count + argv.len - 1;
    ensure(array, newcount, 2);
    if (argv.len > 1) {
        @memcpy(array.data.?[array.count..][0 .. argv.len - 1], argv[1..]);
    }
    array.count = newcount;
    return argv[0];
}

/// `array/remove`: up to `n` elements dropped from an index.
fn nfunArrayRemove(argv: []repr.Value) raise.Error!repr.Value {
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

/// `array/slice`: a new array over a half-open range of an indexed value.
///
/// The array is allocated before the first run is taken, which is the order
/// every site reading chunks keeps: a run stays valid only until the next call
/// that can allocate. Its slots need no fill, unlike a tuple's, because the
/// collector reads an array's elements up to `count` and that is set last.
fn nfunArraySlice(argv: []repr.Value) raise.Error!repr.Value {
    const x = args_core.argSlot(argv, 0);
    var source = try args_core.chunks(x) orelse {
        return args_core.panicIndexed(x, 0, repr.TagSet.none);
    };
    const range = try args_core.getSlice(argv);
    const len: usize = @intCast(range.end - range.start);
    const array = new(len);
    source.window(@intCast(range.start), @intCast(range.end));
    var written: usize = 0;
    while (try source.next()) |run| {
        @memcpy(array.data.?[written..][0..run.len], run);
        written += run.len;
    }
    std.debug.assert(written == len);
    array.count = len;
    return wrap.fromArray(array);
}

/// `array/trim`: the backing capacity set to the current length.
fn nfunArrayTrim(argv: []repr.Value) raise.Error!repr.Value {
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

/// `array/weak`: `array/new` on the weak heap.
fn nfunArrayWeak(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const capacity = try args_core.getInteger(argv, 0);
    return wrap.fromArray(weak(if (capacity < 0) 0 else @intCast(capacity)));
}

/// Gives `array` its initial payload. A capacity of zero leaves `data` null,
/// and the growth paths handle that: a `realloc` of null allocates.
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
