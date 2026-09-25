//! A native module, written in Zig against the published interface.
//!
//! `build.zig` builds this module and `examples/numarray/test/numarray.wattle`
//! loads it. `zig build test` runs that test file.
//!
//! ## Differences with the C version
//!
//! This file is `numarray.c`, the sample that shipped with Janet, brought
//! over to the interface `module.zig` documents. Two things
//! the C original contains are absent from the Zig version.
//!
//! ### Type casting
//!
//! The C original opens every callback with a cast:
//!
//! ```c
//! static int num_array_gc(void *p, size_t s) {
//!     num_array *array = (num_array *)p;   /* nothing checks this */
//! ```
//!
//! Nothing in the language or the runtime reports that cast as wrong.
//! `wattle.define(NumArray, .{ ... })` takes the payload type once and
//! generates the erased dispatch. A callback is written over `*NumArray`, so
//! a mistake is a compile error at the callback's own definition. Break a
//! callback on purpose and `zig build module-errors` shows what an author
//! sees.
//!
//! ### Callback list
//!
//! C needs sixteen macros to let an author fill in the first few fields of a
//! positional initializer without a warning. Zig's default field values are
//! that mechanism. A declaration names the fields it sets, and a callback
//! added later breaks nobody's source.

const wattle = @import("wattle");

/// The payload of a `numarray` abstract.
///
/// `wattle.define` names this type once, below, and every callback is
/// written over `*NumArray`. `data` is the elements' storage and `size` is
/// how many elements it holds.
const NumArray = struct {
    data: [*]f64,
    size: usize,

    /// Returns the elements of `self` as a slice.
    fn slice(self: *NumArray) []f64 {
        return self.data[0..self.size];
    }
};

// ==========================================================================
// The callbacks
// ==========================================================================

/// Frees the elements of `self`. Implements the `gc` callback.
///
/// This function cannot raise, as `module.zig`'s `define` records: a
/// finalizer runs inside a collection, where nothing could act on a report.
fn numArrayGc(self: *NumArray, _: usize) void {
    wattle.free(self.data);
}

/// Returns the element of `self` at `key`, or a method of `self` when `key`
/// is a keyword. Implements the `get` callback.
///
/// `key` is an integer index or a keyword naming a row of `methods`.
///
/// This function raises if `key` is neither an integer nor a keyword. It
/// returns null if an integer `key` addresses no element, and null if a
/// keyword `key` names no row of `methods`.
fn numArrayGet(self: *NumArray, key: wattle.Value) wattle.Error!?wattle.Value {
    if (wattle.isKeyword(key)) return wattle.getMethod(key, &methods);
    const i = wattle.toInteger(key) orelse return wattle.panic("expected integer key");
    // A negative index is out of range rather than index zero.
    const index = inRange(self, i) orelse return null;
    return wattle.number(self.slice()[index]);
}

/// Returns `i` as an index into `self`, or null if `i` addresses no element.
///
/// `i` is a Wattle index and may be negative.
///
/// This function returns null if `i` is negative or if `i` is not below
/// `self.size`.
fn inRange(self: *const NumArray, i: i32) ?usize {
    // The C original cast `i` to `size_t`, so -1 became a large unsigned
    // index that the `>= size` test rejected. Checking the sign gives the
    // same result without relying on wraparound; clamping with `@max(0, i)`
    // would not, because `(a -1)` would read element zero.
    if (i < 0) return null;
    const index: usize = @intCast(i);
    return if (index < self.size) index else null;
}

/// Sets the element of `self` at `key` to `value`. Implements the `put`
/// callback.
///
/// `key` is an integer index and `value` is a number.
///
/// This function raises if `key` is not an integer or `value` is not a
/// number. A `key` that addresses no element is ignored rather than refused,
/// which is the C original's behaviour.
fn numArrayPut(self: *NumArray, key: wattle.Value, value: wattle.Value) wattle.Error!void {
    const i = wattle.toInteger(key) orelse return wattle.panic("expected integer key");
    const x = wattle.toNumber(value) orelse return wattle.panic("expected number value");
    // An index outside the array ends the call without a write.
    const index = inRange(self, i) orelse return;
    self.slice()[index] = x;
}

/// Renders `self` as its elements, separated by spaces, in square brackets.
/// Implements the `tostring` callback.
///
/// `render` is the capability to append to the buffer being built.
///
/// This function raises if an append fails.
///
/// `(string a)`, `(print a)` and `%V` print exactly what this callback pushes.
/// `(describe a)` and `%v` print the same bytes inside `<numarray ...>`; the
/// runtime adds that wrapper.
fn numArrayTostring(self: *NumArray, render: *wattle.Render) wattle.Error!void {
    try wattle.push(render, "[");
    // `wattle.format` is a convenience over `wattle.push`; either would do.
    for (self.slice(), 0..) |cell, i| {
        if (i != 0) try wattle.push(render, " ");
        try wattle.format(render, "{d}", .{cell});
    }
    try wattle.push(render, "]");
}

/// Writes `self` to a stream: the element count, then the elements.
/// Implements the `marshal` callback.
///
/// `m` is the capability to append to the stream.
///
/// This function raises if a push fails.
fn numArrayMarshal(self: *NumArray, m: *wattle.Marshal) wattle.Error!void {
    // Before the payload; `numArrayUnmarshal` calls `wattle.pullAbstract` at
    // the same point.
    wattle.pushAbstract(m, self);
    try wattle.pushSize(m, self.size);
    // As `Value`s rather than raw bytes, so the encoding does not depend on
    // the writing machine's byte order.
    for (self.slice()) |cell| try wattle.pushNumber(m, cell);
}

/// Reads a `NumArray` back from a stream. Implements the `unmarshal`
/// callback.
///
/// `u` is the capability to read from the stream.
///
/// This function raises if a pull fails, if the count exceeds the bytes
/// remaining, or if the allocation fails. It reads the element count and
/// then the elements, which is the order `numArrayMarshal` writes them in.
fn numArrayUnmarshal(u: *wattle.Unmarshal) wattle.Error!*NumArray {
    const size = try wattle.pullSize(u);
    // A malformed stream can claim more elements than it has bytes.
    if (size > wattle.pullRemaining(u)) return wattle.panic("numarray is longer than the stream");
    // Allocated before `wattle.pullAbstract`: from the moment that returns, the
    // block is on the collector's heap list and `numArrayGc` may run on it,
    // so `data` must be valid by then.
    const data = wattle.alloc(f64, size) orelse return wattle.panic("out of memory");
    const array = try wattle.pullAbstract(u, NumArray, null);
    array.* = .{ .data = data.ptr, .size = size };
    for (array.slice()) |*cell| cell.* = try wattle.pullNumber(u);
    return array;
}

/// The `numarray` abstract type: one payload type and the six callbacks this
/// module has. `new` passes it to `wattle.new`, `scale`, `sum` and `length`
/// pass it to `wattle.getAbstract`, and `defs` registers it.
const num_array_type = wattle.define(NumArray, .{
    .name = "numarray",
    .gc = numArrayGc,
    .get = numArrayGet,
    .put = numArrayPut,
    .tostring = numArrayTostring,
    .marshal = numArrayMarshal,
    .unmarshal = numArrayUnmarshal,
});

// ==========================================================================
// The nfunctions
// ==========================================================================

/// Creates a numarray of `size` zeroed elements. Implements
/// `(numarray/new size)`.
///
/// `argv` slot 0 is the element count.
///
/// This function raises if the arity is wrong, if slot 0 is not an integer,
/// if the count is negative, or if the allocation fails.
fn new(argv: []wattle.Value) wattle.Error!wattle.Value {
    try wattle.fixarity(argv, 1);
    // Refused rather than clamped to zero. The C original converted it to
    // `size_t`, so `(numarray/new -1)` asked for more memory than exists.
    const requested = try wattle.getInteger(argv, 0);
    if (requested < 0) return wattle.panic("expected a non-negative size");
    const size: usize = @intCast(requested);
    // Allocated before `wattle.new`: `wattle.new` returns a block that is
    // already on the collector's heap list, so a sweep may call `numArrayGc`
    // on it from that moment, and `data` must be valid by then.
    const data = wattle.alloc(f64, size) orelse return wattle.panic("out of memory");
    const array = wattle.new(NumArray, &num_array_type, null);
    array.* = .{ .data = data.ptr, .size = size };
    return wattle.abstract(array);
}

/// Scales every element of the array by `factor` and returns the array.
/// Implements `(numarray/scale numarray factor)`.
///
/// `argv` slot 0 is the numarray and slot 1 is the factor. The elements are
/// scaled in place.
///
/// This function raises if the arity is wrong, if slot 0 is not a numarray,
/// or if slot 1 is not a number.
fn scale(argv: []wattle.Value) wattle.Error!wattle.Value {
    try wattle.fixarity(argv, 2);
    const array = try wattle.getAbstract(NumArray, argv, 0, &num_array_type);
    const factor = try wattle.getNumber(argv, 1);
    for (array.slice()) |*cell| cell.* *= factor;
    return argv[0];
}

/// Returns the sum of the array's elements. Implements
/// `(numarray/sum numarray)`.
///
/// `argv` slot 0 is the numarray.
///
/// This function raises if the arity is wrong or if slot 0 is not a
/// numarray.
fn sum(argv: []wattle.Value) wattle.Error!wattle.Value {
    try wattle.fixarity(argv, 1);
    const array = try wattle.getAbstract(NumArray, argv, 0, &num_array_type);
    var total: f64 = 0;
    for (array.slice()) |cell| total += cell;
    return wattle.number(total);
}

/// Returns the number of elements in the array. Implements
/// `(numarray/length numarray)`.
///
/// `argv` slot 0 is the numarray.
///
/// This function raises if the arity is wrong or if slot 0 is not a
/// numarray.
fn length(argv: []wattle.Value) wattle.Error!wattle.Value {
    try wattle.fixarity(argv, 1);
    const array = try wattle.getAbstract(NumArray, argv, 0, &num_array_type);
    return wattle.number(@floatFromInt(array.size));
}

/// The method table `numArrayGet` looks a keyword key up in, with a row for
/// `scale`, `sum` and `length`.
const methods = [_]wattle.Method{
    .{ .name = "scale", .nfun = &scale },
    .{ .name = "sum", .nfun = &sum },
    .{ .name = "length", .nfun = &length },
};

// ==========================================================================
// The module
// ==========================================================================

/// Registers the abstract type and defines the module's four nfunctions.
///
/// `env` is the capability to define a binding in the environment the module
/// is loading into. `wattle.entry` below passes `defs` to the loader.
///
/// This function raises if `wattle.registerAbstract` refuses.
fn defs(env: *wattle.Env) wattle.Error!void {
    // A marshalled abstract names its type, and unmarshalling a name the
    // registry does not have raises `unknown abstract type`.
    try wattle.registerAbstract(&num_array_type);
    wattle.nfuns(env, "numarray", &.{
        wattle.reg("new", &new, "(numarray/new size)", "Create new numarray"),
        wattle.reg("scale", &scale, "(numarray/scale numarray factor)", "Scale numarray by factor"),
        wattle.reg("sum", &sum, "(numarray/sum numarray)", "Sum numarray"),
        wattle.reg("length", &length, "(numarray/length numarray)", "Length of numarray"),
    });
}

comptime {
    wattle.entry(defs);
}
