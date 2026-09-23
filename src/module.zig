//! The interface a native module imports.
//!
//! Native modules are a design goal. A module is compiled separately from the
//! runtime, as a shared object that the loader opens at run time. This
//! interface is what makes it possible for a module to call back into the
//! runtime. A module author writes `@import("wattle")` to import this
//! interface.
//!
//! A module must be built with the same Zig version as the runtime that loads
//! it. The runtime table's fields are `callconv(.c)`, but an abstract type's
//! eight raising callbacks are not. They return Zig error unions, so the
//! runtime calls into a module through the `.auto` convention. That convention
//! is deterministic for a compiler version and target rather than documented.
//!
//! ## How a module reaches the runtime
//!
//! A module links against nothing, and resolves no runtime symbols. The
//! runtime exports no `janet_*` name at all. Instead `api/interface.zig`
//! declares an `extern struct` of `callconv(.c)` function pointers. The loader
//! passes a module this struct when it loads. A function in this file that
//! needs the runtime calls through one of its fields.
//!
//! A value's tag and the three immediates, a number, `nil` and a boolean, are
//! the exception. `api/repr.zig` is compiled into the module too, and the
//! loader refuses a module whose value representation differs, so `checkTag`,
//! `truthy`, `nil`, `number`, `boolean` and `toNumber` read and write those
//! bits directly. They touch no runtime state and are valid from any thread.
//! A pointer-carrying value, and the integer range test, still go through a
//! field.
//!
//! Each field is a _crossing_: a point where a module's compilation and the
//! runtime's meet.
//!
//! ## What crosses between module and runtime
//!
//! A _view_ is a pointer and a count over a heap type's own storage. It is
//! what a slice becomes at the boundary: a slice cannot cross a `callconv(.c)`
//! signature, so the pointer and the count cross separately. This file
//! rebuilds an author's own type from it: a slice for a string's bytes,
//! `Indexed` for a tuple's elements, which an indexed abstract has in many
//! runs rather than one, and `Dictionary` for a dictionary's pairs, which a
//! table holds with empty slots between them and a dictionary abstract in many
//! runs. How long a getter's result stays valid depends on the
//! type it came from. A string's, a tuple's and a map's are stable while
//! the value is reachable; a buffer's, an array's and a table's are not.
//!
//! A _capability_ is `opaque {}`. It is the authority to perform an operation
//! rather than a handle to data: an author holds a pointer, passes it back to
//! a function here, and can neither read a field nor make a capability. It
//! converts to and from a `Value` in neither direction, so the object behind
//! it is out of a module's reach. `Env`, `Render`, `Marshal` and `Unmarshal`
//! are parameters to a callback. `Wake` is a parameter to a posted callback.
//! `Loop` is the only type an author requests, and the only type a thread with
//! no VM may hold.
//!
//! The other parameters are of type `Value`. This limitation is intentional.
//! The goal is to avoid module authors relying on internal types used in the
//! implementation.
//!
//! ## Declaring an abstract type
//!
//! An abstract is a Janet value whose payload is a module's own Zig type.
//! `define` declares an abstract type from a name and a set of callbacks:
//!
//! ```zig
//! const num_array_type = wattle.define(NumArray, .{
//!     .name = "numarray",
//!     .gc = numArrayGc,
//!     .get = numArrayGet,
//! });
//! ```
//!
//! The result is declared at container level, because an abstract's header
//! stores a pointer to the `AbstractType` it was made with. `define` says what
//! happens when it is not.
//!
//! Every callback is written over `*T`, and every field defaults to null, so a
//! type declares only the callbacks it needs. Seven of the fifteen return no
//! error union and so cannot raise. The groups below are the collector's three,
//! access, identity, rendering, marshalling and indexing.
//!
//! | callback      | signature                          | may raise |
//! | ------------- | ---------------------------------- | --------- |
//! | `gc`          | `fn (*T, usize) void`              | no        |
//! | `gcmark`      | `fn (*T, usize) void`              | no        |
//! | `gcperthread` | `fn (*T, usize) void`              | no        |
//! |               |                                    |           |
//! | `get`         | `fn (*T, Value) Error!?Value`      | yes       |
//! | `put`         | `fn (*T, Value, Value) Error!void` | yes       |
//! | `next`        | `fn (*T, Value) Error!Value`       | yes       |
//! | `length`      | `fn (*T, usize) Error!usize`       | yes       |
//! | `call`        | `fn (*T, []Value) Error!Value`     | yes       |
//! |               |                                    |           |
//! | `compare`     | `fn (*const T, *const T) i32`      | no        |
//! | `hash`        | `fn (*const T, usize) i32`         | no        |
//! |               |                                    |           |
//! | `tostring`    | `fn (*T, *Render) Error!void`      | yes       |
//! | `bytes`       | `fn (*const T, usize) []const u8`  | no        |
//! |               |                                    |           |
//! | `marshal`     | `fn (*T, *Marshal) Error!void`     | yes       |
//! | `unmarshal`   | `fn (*Unmarshal) Error!*T`         | yes       |
//! |               |                                    |           |
//! | `chunk`       | `fn (*T, usize) Chunk`             | no        |
//!
//! `contents` is a field beside the callbacks rather than one of them: what
//! the runs `chunk` returns hold, `elements` or `pairs`. A type sets it
//! exactly when it has `chunk`.
//!
//! The restrictions on the collector's callbacks are in `Spec`, and
//! `examples/numarray` is the worked example.
//!
//! ## Values across a re-entry into Janet code
//!
//! Garbage collection runs at the interpreter's safe points: between
//! instructions, and in the `gccollect` builtin. Allocating does not trigger
//! collection so a value an nfunction builds is safe for as long as that
//! nfunction's frame is live.
//!
//! Re-entering Janet code stops this being true. Three functions callable by a
//! module author may re-enter: `call`, `mcall` and `pcall`. Four rules apply
//! across such a re-entry:
//!
//! - A `Value` reachable from nothing but the module's own stack can be freed.
//!   `gcroot` before and `gcunroot` after is the protection, one pair per
//!   value; nothing here roots on a module's behalf.
//!
//! - The arguments and the result need no root of their own: they are on the
//!   fiber's stack, which the collector does scan.
//!
//! - `argv` itself does not survive, because a call may grow that stack,
//!   which reallocates. Copy what is still needed into a local before the
//!   first call.
//!
//! - A view taken from `argv` is unaffected. It points at the aggregate's own
//!   heap storage. What invalidates a view is a mutation of the aggregate.
//!
//! - An `Indexed` or a `Dictionary` over an abstract does not survive. Janet
//!   code may read the same abstract's runs, and a type may reuse the storage
//!   of a run.
//!
//! Three examples are included to show how to use modules: `examples/digest`
//! (the event loop), `examples/numarray` (an abstract type in a module that
//! owns something) and `examples/url` (the views in a module that owns
//! nothing).

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const abstract_type = @import("api/abstract_type.zig");
const config = @import("config");
const constants = @import("constants");
const fingerprint = @import("api/fingerprint.zig");
const interface = @import("api/interface.zig");
const raise = @import("api/raise.zig");
const repr = @import("repr");

// ==========================================================================
// Constants
// ==========================================================================

/// The most rows `nfuns`, `getMethod` and `nextMethod` accept in one table.
pub const max_table_rows = 128;

/// Raises an error with a string as its message. See `panicFormat` for a
/// formatted message.
pub const panic = raise.panic;

// ==========================================================================
// Aliased types
// ==========================================================================

/// An abstract type: a name and the callbacks the runtime dispatches
/// through. `define` returns an `AbstractType`.
pub const AbstractType = abstract_type.AbstractType;

/// What a value holds: `none`, `elements` or `pairs`. An abstract type
/// declares its own in `define`'s `contents` field.
pub const Contents = abi.Contents;

/// The capability to define a binding in the environment a module is loading
/// into. `entry`'s `defs` function takes a `*Env`.
pub const Env = abi.Env;

/// The status of a fiber, which `fiberStatus` returns.
///
/// The members are `dead`, `error`, `debug`, `pending`, `user0` through
/// `user9`, `new` and `alive`. `pcall`'s block says which of `dead`, `error`
/// and `pending` a fiber has after each signal. `error` is written
/// `.@"error"` in Zig.
pub const FiberStatus = abi.FiberStatus;

/// One key-value pair of a map or a table. `Dictionary.next` returns a
/// `Keyval`, and `mapOf` and `tableOf` take a slice of `Keyval`.
pub const Keyval = abi.Keyval;

/// The capability to queue a callback for the loop thread's next turn.
/// `loop` returns a `*Loop` and `post` takes a `*Loop`.
pub const Loop = abi.Loop;

/// The capability to append to the stream a value is being marshalled into.
/// An abstract type's `marshal` callback takes a `*Marshal`.
pub const Marshal = abi.Marshal;

/// A slice argument's two folded indices, which `getRange` returns.
///
/// `start` and `end` are a half-open interval over the length that was
/// passed to `getRange`, and a negative index has already been folded against
/// it. Both are `i32` because a Janet index is `i32`, so an author slicing
/// Zig memory with them casts:
///
/// ```zig
/// const from: usize = @intCast(range.start);
/// const to: usize = @intCast(range.end);
/// ```
pub const Range = abi.Range;

/// One registration row: a name, an nfunction and three pieces of metadata.
/// `reg` returns a `Reg` and `nfuns` takes a table of `Reg`.
pub const Reg = abi.Reg;

/// The capability to append bytes to the buffer a value is being rendered
/// into. An abstract type's `tostring` callback takes a `*Render`.
pub const Render = abi.Render;

/// How a fiber stopped: a return, a raise, a debug break, a yield or a user
/// signal.
pub const Signal = abi.Signal;

/// The capability to read from the stream a value is being unmarshalled from.
/// An abstract type's `unmarshal` callback takes a `*Unmarshal`.
pub const Unmarshal = abi.Unmarshal;

/// A Janet value, wrapped.
pub const Value = repr.Value;

/// The capability to put a fiber back on the run queue with a value. A posted
/// callback takes a `*Wake` and `wake` takes the same `*Wake`.
pub const Wake = abi.Wake;

// ==========================================================================
// Types
// ==========================================================================

/// The return type of `pcall`.
///
/// `signal` is how the fiber ended: `.ok` on a return, `.error` on a raise,
/// `.yield` on a yield. `value` is the value that goes with it: the return
/// value, the error's payload, or the yielded value. `fiber` is the fiber
/// created, nil if none was created.
///
/// Neither `value` nor `fiber` is rooted so the re-entry rules at the top of
/// this file apply.
pub const Called = struct { signal: Signal, value: Value, fiber: Value };

/// The type of an nfunction.
///
/// An nfunction takes its arguments as one slice and returns a `Value` or
/// raises. `reg` takes a function of this type; a function of any other shape
/// is a compile error.
pub const NFunction = *const fn ([]Value) Error!Value;

/// The return type of an abstract type's `chunk` callback.
///
/// `items` is a run of the type's contents and `start` is the position of the
/// first of them. The run must hold the position `chunk` was called with, and
/// must not reach past the type's length. For `elements` a position is an
/// index. For `pairs` a run alternates keys and values, pair i is at position
/// 2i, a run starts at an even position and has an even length, and the
/// positions end at twice the length, which counts pairs.
///
/// `items` may point into the payload's own storage, or into a buffer the
/// payload keeps. A `Value` that only that buffer refers to must be marked by
/// the type's `gcmark`.
///
/// ```zig
/// fn vecChunk(self: *Vec, index: usize) wattle.Chunk {
///     const start = index - index % 32;
///     return .{ .items = self.leafFor(index), .start = start };
/// }
/// ```
pub const Chunk = struct { items: []const Value, start: usize };

/// The pairs of a table, a map or an abstract whose contents are pairs,
/// read in order.
///
/// `getDictionary` and `toDictionary` return a `Dictionary`. `count` is how
/// many pairs there are, and `len` is how many values the runs hold, which
/// counts a table's empty slots. The other fields are the
/// position reading has reached and the part of a run not yet returned, and an
/// author does not set them.
///
/// A table's slots are one run, read with no crossing. A map's leaves and an
/// abstract's runs are read through `dictionary_chunk`, one crossing per run.
///
/// A `Dictionary` is valid until the module re-enters Janet code or mutates
/// the value it reads. The pairs of a map are stable while it is reachable.
/// A `put` on a table may rehash and move every pair, so a walk finishes
/// before any `put`.
///
/// ```zig
/// var pairs = try getDictionary(argv, 0);
/// while (try pairs.next()) |pair| {
///     // pair.key, pair.value
/// }
/// ```
pub const Dictionary = struct {
    count: usize,
    len: usize,
    value: Value,
    position: usize = 0,
    rest: []const Value = &.{},

    /// Returns the next pair, or null when every pair has been returned. An
    /// empty slot is skipped.
    ///
    /// This function raises if an abstract's `chunk` callback returns a run
    /// that does not start at the next position or does not hold whole pairs.
    pub fn next(self: *Dictionary) Error!?Keyval {
        while (true) {
            while (self.rest.len != 0) {
                const kv: Keyval = .{ .key = self.rest[0], .value = self.rest[1] };
                self.rest = self.rest[2..];
                if (!isNil(kv.key)) return kv;
            }
            self.rest = (try self.nextChunk()) orelse return null;
        }
    }

    /// Returns the values from the next position to the end of its run, key
    /// then value, or null when every run has been returned.
    ///
    /// A table's run includes its empty slots, whose keys are
    /// nil. A run `next` has begun is returned from the next pair on.
    ///
    /// This function raises where `next` does.
    pub fn nextChunk(self: *Dictionary) Error!?[]const Value {
        if (self.rest.len != 0) {
            const run = self.rest;
            self.rest = &.{};
            return run;
        }
        if (self.position >= self.len) return null;
        const run = try fromAbi(interface.rt.dictionary_chunk(self.value, self.position, self.len));
        // The runtime refuses a run that does not start at `position`, so
        // `len` is not zero and `items` is not null.
        self.position += run.len;
        return run.items.?[0..run.len];
    }
};

/// The error a raise returns.
///
/// It has one member. A Zig error has no payload, and the two things a raise
/// includes are stored inside the runtime: the value goes to the fiber's
/// return register and the signal beside it. Every function here that can
/// raise returns `Error!T`.
pub const Error = error{Signal};

/// The elements of an array, a vector, a tuple or an indexed abstract, read by
/// position or in order.
///
/// `getIndexed` and `toIndexed` return an `Indexed`. `len` is how many
/// elements there are. The other fields are the position `next` has reached
/// and the run of elements read most recently, and an author does not set
/// them.
///
/// An array's or a tuple's elements are one run, read with no crossing. A
/// vector's are one run per leaf and an abstract's are read through its
/// `chunk` callback, one crossing per run, and the run read most recently is
/// kept. `get` of an index inside that run makes no crossing.
///
/// An `Indexed` is valid until the module re-enters Janet code or mutates the
/// value it reads. The elements of a tuple or a vector are stable while it is
/// reachable.
/// The elements of an array are not; a push may reallocate. A run of an
/// abstract is valid until the next run is read from the same abstract, so two
/// `Indexed` over one abstract are not read in turn.
///
/// The `Value`s it returns are not rooted. See the file header for when that
/// matters.
///
/// ```zig
/// var items = try getIndexed(argv, 0);
/// const first = try items.get(0);
/// while (try items.next()) |item| {
///     // item is a Value
/// }
/// ```
pub const Indexed = struct {
    len: usize,
    value: Value,
    position: usize = 0,
    run: []const Value = &.{},
    run_start: usize = 0,

    /// Returns the element at `i`, or null if `i` is not below `len`.
    ///
    /// It does not move the position `next` and `nextChunk` read from.
    ///
    /// This function raises if an abstract's `chunk` callback returns a run
    /// that does not hold `i`.
    pub fn get(self: *Indexed, i: usize) Error!?Value {
        if (i >= self.len) return null;
        try self.hold(i);
        return self.run[i - self.run_start];
    }

    /// Returns the next element, or null when every element has been
    /// returned.
    ///
    /// This function raises if an abstract's `chunk` callback returns a run
    /// that does not hold the next index.
    pub fn next(self: *Indexed) Error!?Value {
        if (self.position >= self.len) return null;
        try self.hold(self.position);
        const item = self.run[self.position - self.run_start];
        self.position += 1;
        return item;
    }

    /// Returns the elements from the next position to the end of the run that
    /// holds it, or null when every element has been returned.
    ///
    /// An array or a tuple returns every element not yet returned in one
    /// slice.
    ///
    /// This function raises if an abstract's `chunk` callback returns a run
    /// that does not hold the next index.
    pub fn nextChunk(self: *Indexed) Error!?[]const Value {
        if (self.position >= self.len) return null;
        try self.hold(self.position);
        const items = self.run[self.position - self.run_start ..];
        self.position = self.run_start + self.run.len;
        return items;
    }

    /// Makes `run` the run that holds `i`, reading it if it is not already.
    ///
    /// `i` is below `len`. An array's or a tuple's run holds every index, so
    /// only a vector or an abstract reaches the crossing.
    fn hold(self: *Indexed, i: usize) Error!void {
        if (i >= self.run_start and i - self.run_start < self.run.len) return;
        const run = try fromAbi(interface.rt.indexed_chunk(self.value, i, self.len));
        // The runtime refuses a run that does not hold `i`, so `len` is not
        // zero and `items` is not null.
        self.run = run.items.?[0..run.len];
        self.run_start = run.start;
    }
};

/// One row of a method table: a name and an nfunction that raises.
///
/// `getMethod` and `nextMethod` take a slice of `Method`. `name` is the
/// method's name without its colon, and `nfun` is a pointer to an nfunction of
/// the shape `NFunction` describes. A row is written:
///
/// ```zig
/// .{ .name = "scale", .nfun = &scale }
/// ```
pub const Method = extern struct {
    name: ?[*:0]const u8 = null,
    nfun: ?NFunction = null,
};

/// The callback that `post` queues for the loop thread.
///
/// An author writes:
///
/// ```zig
/// fn hashDone(w: *wattle.Wake, raw: *anyopaque) callconv(.c) void
/// ```
///
/// The callback cannot raise. The second parameter is the `ctx` that was
/// passed to `post`, and the runtime never reads it. The callback may build a
/// `Value` and pass it to `wake`.
pub const PostCallback = *const fn (wake: *Wake, ctx: *anyopaque) callconv(.c) void;

/// The callbacks an abstract type is declared with, over `*T`.
///
/// `define` takes a struct literal of this shape and returns an
/// `AbstractType`. Every field defaults to null, so a type declares only the
/// callbacks it needs, and a null slot is not called.
///
/// `T` is the type of the payload's header rather than of the whole
/// allocation, and every callback that takes a `len` is given the allocation's
/// size, because an abstract may have bytes after its fields. A callback that
/// ignores those bytes ignores `len`.
///
/// `compare` takes two `*const T`. The runtime orders abstracts of different
/// types by name and reaches this callback only when both payloads are of
/// this type.
///
/// `gc`, `gcmark`, `gcperthread`, `compare`, `hash` and `bytes` return no
/// error union and so cannot raise. The runtime calls them where nothing could
/// act on a report: the first two run inside a collection, and the rest inside
/// an operation that has to produce a result.
///
/// ```zig
/// const num_array_type = wattle.define(NumArray, .{
///     .name = "numarray",
///     .gc = numArrayGc,
///     .get = numArrayGet,
///     .put = numArrayPut,
/// });
/// ```
pub fn Spec(comptime T: type) type {
    return struct {
        name: []const u8,

        // The collector.

        /// The finalizer, run inside a collection on an object that is
        /// already unreachable. It may allocate, and what it allocates
        /// survives that collection and is collected on the next.
        gc: ?*const fn (*T, usize) void = null,
        /// Marks the values in the payload. It may not retain anything it
        /// allocates: an object allocated during the mark phase is swept in
        /// the same collection.
        gcmark: ?*const fn (*T, usize) void = null,
        gcperthread: ?*const fn (*T, usize) void = null,

        // Access.

        get: ?*const fn (*T, Value) Error!?Value = null,
        put: ?*const fn (*T, Value, Value) Error!void = null,
        next: ?*const fn (*T, Value) Error!Value = null,
        /// Returns the number of elements. It may raise, but may not call
        /// into Janet code, so a caller can read a length while it holds
        /// `argv` or a value nothing roots, and it gives the same answer until
        /// the payload changes, so a caller can read it twice. A type without
        /// it has no length: the runtime does not fall back to a `:length`
        /// method.
        length: ?*const fn (*T, usize) Error!usize = null,
        call: ?*const fn (*T, []Value) Error!Value = null,

        // Identity.

        /// Orders two payloads of this type. It may not allocate through the
        /// collector and may not re-enter a comparison, because a comparison
        /// runs while a dictionary is still being built.
        compare: ?*const fn (*const T, *const T) i32 = null,
        /// Hashes a payload. It may not allocate through the collector, for
        /// the reason `compare` may not.
        hash: ?*const fn (*const T, usize) i32 = null,

        // Rendering.

        tostring: ?*const fn (*T, *Render) Error!void = null,
        bytes: ?*const fn (*const T, usize) []const u8 = null,

        // Marshalling.

        marshal: ?*const fn (*T, *Marshal) Error!void = null,
        unmarshal: ?*const fn (*Unmarshal) Error!*T = null,

        // Contents.

        /// Returns the run of contents that holds `index`, which is below
        /// the type's length, or twice it for `pairs`. A type with `chunk`
        /// must also have `length` and a `contents` other than `none`. It may
        /// not allocate or call into Janet code. The run stays valid until the
        /// next call that can do either, or until the next `chunk` call on the
        /// same payload.
        chunk: ?*const fn (*T, usize) Chunk = null,
        /// What `chunk`'s runs hold: `elements` for an indexed type and
        /// `pairs` for a dictionary. A type without `chunk` leaves it `none`.
        contents: Contents = .none,
    };
}

// ==========================================================================
// Public functions
// ==========================================================================

/// Wraps an abstract type's payload.
pub fn abstract(p: *anyopaque) Value {
    return interface.rt.wrap_abstract(p);
}

/// Allocates `n` contiguous zeroed `T` from the runtime's allocator.
///
/// The memory belongs to an abstract type. The abstract type's `gc` callback
/// is responsible for freeing it.
///
/// The result is null when the allocation fails. The caller is responsible for
/// calling `panic` if that is appropriate. See
/// `examples/numarray/numarray.zig` for a worked instance.
///
/// A `T` aligned more strictly than `max_align_t` is a compile error. The
/// allocator is malloc-backed.
pub inline fn alloc(comptime T: type, n: usize) ?[]T {
    if (@alignOf(T) > @alignOf(std.c.max_align_t)) @compileError(std.fmt.comptimePrint(
        "alloc({s}): this type's alignment is {d}. The runtime's allocator is " ++
            "malloc-backed, so its guaranteed alignment is `max_align_t`. A payload " ++
            "needing more must align its own storage inside an allocation from `alloc`.",
        .{ @typeName(T), @alignOf(T) },
    ));
    const p = interface.rt.calloc(n, @sizeOf(T)) orelse return null;
    const many: [*]T = @ptrCast(@alignCast(p));
    return many[0..n];
}

/// Checks that the number of arguments is between `lo` and `hi`.
///
/// This function raises if the check fails. Pass `-1` for "no bound".
pub fn arity(argv: []const Value, lo: i32, hi: i32) Error!void {
    return fromAbi(interface.rt.arity(@intCast(argv.len), lo, hi));
}

/// Wraps a slice of `Value` as an array.
pub fn array(items: []const Value) Value {
    return interface.rt.new_array(items.ptr, items.len);
}

/// Appends to a wrapped array.
pub fn arrayPush(v: Value, x: Value) Error!void {
    return fromAbi(interface.rt.array_push_value(v, x));
}

/// Suspends the fiber running this function.
///
/// The suspension is a raise with the event signal, so an nfunction ends
/// with `return wattle.await()`. Whatever will wake the fiber, usually a worker
/// thread, should be started first. This does not cause a race: the loop is
/// single-threaded, so a `post` made before the nfunction returns is not
/// processed until the fiber has suspended.
pub fn await() Error {
    return raise.signal(.event, nil());
}

/// Wraps `true` or `false`.
pub fn boolean(b: bool) Value {
    return repr.wrapBoolean(b);
}

/// Wraps a slice of `u8` as a buffer.
pub fn buffer(bytes: []const u8) Value {
    return interface.rt.new_buffer(bytes.ptr, bytes.len);
}

/// Appends to a wrapped buffer.
pub fn bufferPush(v: Value, bytes: []const u8) Error!void {
    return fromAbi(interface.rt.buffer_push_value(v, bytes.ptr, bytes.len));
}

/// Returns an optional slice into the payload of a wrapped string, symbol,
/// keyword, buffer or byte-like abstract.
pub fn bytesView(v: Value) ?[]const u8 {
    var out: abi.ByteView = undefined;
    if (!interface.rt.bytes_view(v, &out)) return null;
    const p = out.bytes orelse return &.{};
    return p[0..out.len];
}

/// Calls `f` with `args` on the Janet VM.
///
/// `f` is a function or an nfunction. Any other value raises "expected
/// function or nfunction, got x". A method call on a keyword is `mcall`.
///
/// This function raises on anything but a return. An error from Janet code
/// arrives as `Error.Signal` with the error's payload. A yield or a
/// debug signal arrives coerced as the same type.
///
/// This function re-enters Janet code, so the re-entry rules at the top of
/// this file apply (including those regarding the lifetime of `argv`). The
/// recursion guard is the runtime's.
///
/// This is the equivalent of `(f ;args)` in Janet code. See also `mcall` and
/// `pcall`.
pub fn call(f: Value, args: []const Value) Error!Value {
    return fromAbi(interface.rt.call_value(f, args.ptr, args.len));
}

/// Installs a table of nfunctions into an environment.
///
/// `env` is the environment passed to the module's `defs` function. The
/// `native` nfunction either creates it or takes it from the second argument
/// of `(native path env)`, then passes it to `_wattle_init`.
pub fn nfuns(env: *Env, prefix: ?[*:0]const u8, regs: []const Reg) void {
    const terminated = terminate(Reg, regs);
    interface.rt.nfuns_ext(env, prefix, @ptrCast(&terminated));
}

/// Wraps a NUL-terminated slice of `u8` as a string.
pub fn cstring(bytes: [:0]const u8) Value {
    return string(bytes);
}

/// Defines a non-function binding.
pub fn def(env: *Env, comptime name: [:0]const u8, val: Value, comptime doc: ?[:0]const u8) void {
    interface.rt.def(env, name.ptr, val, if (doc) |d| d.ptr else null);
}

/// Declares an abstract type whose payload is `T`.
///
/// `spec` is a struct literal of the shape `Spec(T)` describes. A callback of
/// the wrong shape is a compile error naming the slot and what it should have
/// been.
///
/// ```zig
/// const num_array_type = wattle.define(NumArray, .{
///     .name = "numarray",
///     .gc = numArrayGc,   // fn (*NumArray, usize) void
///     .get = numArrayGet, // fn (*NumArray, Value) Error!?Value
///     .put = numArrayPut,
/// });
/// ```
///
/// The result is declared at container level, because an abstract's header
/// stores a pointer to the `AbstractType` it was made with, and the collector
/// reads that pointer again at teardown. A type bound inside a function is
/// gone by then:
///
/// ```zig
/// fn defs(env: *wattle.Env) wattle.Error!void {
///     const t = wattle.define(NumArray, .{ ... }); // WRONG
/// }
/// ```
///
/// The failure is a crash during teardown with nothing pointing back at the
/// declaration that caused it, and Zig offers no way to require the placement,
/// so this is a rule rather than a check. `examples/numarray` shows it.
pub fn define(comptime T: type, comptime spec: anytype) AbstractType {
    comptime abstract_type.check(T, spec);
    const cb = comptime abstract_type.collect(T, spec);
    const E = abstract_type.Erased(T, cb);
    return .{
        .name = cb.name,
        .gc = if (cb.gc != null) &E.gc else null,
        .gcmark = if (cb.gcmark != null) &E.gcmark else null,
        .gcperthread = if (cb.gcperthread != null) &E.gcperthread else null,
        .get = if (cb.get != null) &E.get else null,
        .put = if (cb.put != null) &E.put else null,
        .next = if (cb.next != null) &E.next else null,
        .length = if (cb.length != null) &E.length else null,
        .call = if (cb.call != null) &E.call else null,
        .compare = if (cb.compare != null) &E.compare else null,
        .hash = if (cb.hash != null) &E.hash else null,
        .tostring = if (cb.tostring != null) &E.tostring else null,
        .bytes = if (cb.bytes != null) &E.bytes else null,
        .marshal = if (cb.marshal != null) &E.marshal else null,
        .unmarshal = if (cb.unmarshal != null) &E.unmarshal else null,
        .chunk = if (cb.chunk != null) &E.chunk else null,
        .contents = cb.contents,
    };
}

/// Exports the two symbols the loader looks up by name.
///
/// A module writes:
///
/// ```zig
/// comptime { module.entry(defs); }
/// ```
///
/// where `defs` is of type `fn (*module.Env) Error!void`.
///
/// `_wattle_mod_config` reports the configuration bits, the interface
/// fingerprint and the compiler's version, and the loader refuses the module
/// unless all three match the runtime's own. `_wattle_init` takes the
/// environment to define into and the runtime table, and runs `defs`.
///
/// A module built for linking into an executable, which `build.zig`'s
/// `quickbin` configures with `static_name`, exports the same two functions as
/// `_wattle_mod_config_<name>` and `_wattle_init_<name>`, so that several can be
/// linked into one binary.
pub fn entry(comptime defs: fn (*Env) Error!void) void {
    const Shim = struct {
        /// Writes this module's `abi.BuildConfig` and returns its own width.
        ///
        /// `size` is the width the loader has room for and `out` is where
        /// the bytes go. Writing the smaller of the two widths lets a loader
        /// whose `abi.BuildConfig` is longer than this module's read the
        /// fields the module does have.
        fn modConfig(out: *abi.BuildConfig, size: usize) callconv(.c) usize {
            const mine = @sizeOf(abi.BuildConfig);
            const written = @min(size, mine);
            const source = std.mem.asBytes(&fingerprint.build_config);
            @memcpy(@as([*]u8, @ptrCast(out))[0..written], source[0..written]);
            return mine;
        }
        /// Stores the runtime table, then runs `defs`.
        ///
        /// This function does not raise because the symbol the loader looks up
        /// is `callconv(.c)` and cannot return an error union. Instead a
        /// flattened error is sent.
        fn modInit(env: *Env, rt: *const interface.Runtime) callconv(.c) void {
            interface.rt = rt;
            return raise.toAbi(defs(env));
        }
    };
    const suffix = if (config.static_name) |name| "_" ++ name else "";
    @export(&Shim.modConfig, .{ .name = "_wattle_mod_config" ++ suffix });
    @export(&Shim.modInit, .{ .name = "_wattle_init" ++ suffix });
}

/// Returns the status of a wrapped fiber.
///
/// This function raises if passed a value that is not a wrapped fiber.
pub fn fiberStatus(fiber: Value) Error!FiberStatus {
    return fromAbi(interface.rt.fiber_status_value(fiber));
}

/// Checks that there are exactly `n` arguments.
///
/// This function raises if the arity of the function does not match.
pub fn fixarity(argv: []const Value, n: i32) Error!void {
    return fromAbi(interface.rt.fixarity(@intCast(argv.len), n));
}

/// Appends a formatted string to the buffer into which a value is being
/// rendered.
///
/// See `push`, which this is a convenience over: it formats the string and
/// appends it in one step. The formatting syntax is Zig's `std.fmt` rather
/// than Janet's pretty printer.
pub fn format(r: *Render, comptime fmt: []const u8, args: anytype) Error!void {
    const len = std.fmt.count(fmt, args);
    if (len == 0) return;
    var stack: [256]u8 = undefined;
    if (len <= stack.len) return push(r, std.fmt.bufPrint(&stack, fmt, args) catch unreachable);
    const heap = alloc(u8, len) orelse return panic("out of memory");
    defer free(heap);
    return push(r, std.fmt.bufPrint(heap, fmt, args) catch unreachable);
}

/// Frees the memory allocated by `alloc`.
///
/// `mem` is either the slice or the pointer to the location of memory.
pub inline fn free(mem: anytype) void {
    const p = switch (@typeInfo(@TypeOf(mem)).pointer.size) {
        .slice => mem.ptr,
        else => mem,
    };
    interface.rt.free(@ptrCast(p));
}

/// Keeps `v` reachable across a re-entry into Janet code by preventing garbage
/// collection.
///
/// Each call adds one rooting and `gcunroot` removes one, so the two are
/// called in pairs. Rooting the same value twice requires two calls to
/// `gcunroot` before the value is eligible for collection.
///
/// This is not `mark`. `mark` applies to a garbage collection already in
/// progress. This adds `v` to the set of roots from which every later
/// collection begins.
pub fn gcroot(v: Value) void {
    interface.rt.gcroot(v);
}

/// Drops one rooting of `v` and returns whether there was one to drop.
///
/// If this function returns `false`, there is an unbalanced number of `gcroot`
/// and `gcunroot` calls.
pub fn gcunroot(v: Value) bool {
    return interface.rt.gcunroot(v);
}

/// Returns the wrapped value in the wrapped data structure under the wrapped
/// key.
///
/// Generally, a miss will result in a wrapped nil. However, an abstract type
/// can raise an error in its `get` function.
///
/// This is the equivalent of `(get ds k)` in Janet code.
pub fn get(v: Value, key: Value) Error!Value {
    return fromAbi(interface.rt.get(v, key));
}

/// Gets and unwraps an abstract type from a slice of `Value`.
///
/// `argv` is named as such because this function is typically used to
/// get the unwrapped value at index `n` in an argument list.
///
/// This function raises if the wrapped value does not match the abstract type
/// defined by `at`.
pub fn getAbstract(comptime T: type, argv: []const Value, n: i32, at: *const AbstractType) Error!*T {
    const p = try fromAbi(interface.rt.getabstract(argv.ptr, n, at));
    return @ptrCast(@alignCast(p.?));
}

/// Gets and unwraps a boolean from a slice of `Value`.
///
/// `argv` is named as such because this function is typically used to
/// get the unwrapped value at index `n` in an argument list.
///
/// This function raises if the unwrapped value is not a boolean.
pub fn getBoolean(argv: []const Value, n: i32) Error!bool {
    return fromAbi(interface.rt.getboolean(argv.ptr, n));
}

/// Gets and unwraps the bytes of a string, symbol, keyword, buffer or
/// byte-like abstract from a slice of `Value`.
///
/// `argv` is named as such because this function is typically used to
/// get the unwrapped value at index `n` in an argument list.
///
/// This function raises if the unwrapped value is none of those types.
///
/// The bytes of a string, symbol or keyword are stable while the value is
/// reachable. The bytes of a buffer are not; a push may reallocate the
/// block.
pub fn getBytes(argv: []const Value, n: i32) Error![]const u8 {
    const view = try fromAbi(interface.rt.getbytes(argv.ptr, n));
    const p = view.bytes orelse return &.{};
    return p[0..view.len];
}

/// Gets the pairs of a table, a map or a dictionary abstract from a slice of
/// `Value`.
///
/// `argv` is named as such because this function is typically used to
/// get the unwrapped value at index `n` in an argument list.
///
/// This function raises if the value is none of those types, or if an
/// abstract's `length` callback raises.
///
/// See `Dictionary`, which is what the reading and the validity of the result
/// are described on.
pub fn getDictionary(argv: []const Value, n: i32) Error!Dictionary {
    return dictionaryOf(try fromAbi(interface.rt.getdictionary(argv.ptr, n)));
}

/// Gets the elements of an array, a vector, a tuple or an indexed abstract from
/// a slice of `Value`.
///
/// `argv` is named as such because this function is typically used to
/// get the unwrapped value at index `n` in an argument list.
///
/// This function raises if the value is none of those types, or if an
/// abstract's `length` callback raises.
///
/// See `Indexed`, which is what the reading and the validity of the result are
/// described on.
pub fn getIndexed(argv: []const Value, n: i32) Error!Indexed {
    return indexedOf(try fromAbi(interface.rt.getindexed(argv.ptr, n)));
}

/// Gets and unwraps a 32-bit signed integer from a slice of `Value`.
///
/// `argv` is named as such because this function is typically used to
/// get the unwrapped value at index `n` in an argument list.
///
/// This function raises if the unwrapped value is not a 32-bit signed integer.
pub fn getInteger(argv: []const Value, n: i32) Error!i32 {
    return fromAbi(interface.rt.getinteger(argv.ptr, n));
}

/// Gets a method from a method table by keyword.
///
/// An abstract type's `get` callback delegates to this when the key is a
/// keyword, which is how `(:scale a 5)` finds `scale`.
///
/// This function returns null if `key` is not a keyword or names no method in
/// `methods`.
pub fn getMethod(key: Value, methods: []const Method) Error!?Value {
    const name = toKeyword(key) orelse return null;
    const rows = terminate(Method, methods);
    var res: Value = undefined;
    if (try fromAbi(interface.rt.getmethod(name.ptr, @ptrCast(&rows), &res)) == 0) return null;
    return res;
}

/// Gets and unwraps a number from a slice of `Value`.
///
/// `argv` is named as such because this function is typically used to
/// get the unwrapped value at index `n` in an argument list.
///
/// This function raises if the unwrapped value is not a number.
pub fn getNumber(argv: []const Value, n: i32) Error!f64 {
    return fromAbi(interface.rt.getnumber(argv.ptr, n));
}

/// Gets and unwraps a pair of optional indices from a slice of `Value`,
/// folded against `len`.
///
/// `argv` is named as such because this function is typically used to get the
/// unwrapped values at indices `n` and `n + 1` in an argument list. `len` is
/// the caller's own count, not that of a wrapped value.
///
/// A negative index counts from the end. An absent or nil start defaults to
/// 0, and an absent or nil end defaults to `len`. An end below the start is
/// clamped up to it. These are the same rules that functions like
/// `string/slice` follow.
///
/// This function raises if either index is present and is not a valid index,
/// or if `len` is above `maxInt(i32)`.
///
/// This can be used for a function like `(f x &opt start end)`.
pub fn getRange(argv: []const Value, n: i32, len: usize) Error!Range {
    if (len > std.math.maxInt(i32)) return panic("length exceeds the range a Wattle index can name");
    return fromAbi(interface.rt.getrange(argv.ptr, @intCast(argv.len), n, @intCast(len)));
}

/// Gets and unwraps a size from a slice of `Value`.
///
/// `argv` is named as such because this function is typically used to
/// get the unwrapped value at index `n` in an argument list.
///
/// This function raises if the unwrapped value is not a number that fits a
/// `usize`.
pub fn getSize(argv: []const Value, n: i32) Error!usize {
    return fromAbi(interface.rt.getsize(argv.ptr, n));
}

/// Gets and unwraps a 32-bit unsigned integer from a slice of `Value`.
///
/// `argv` is named as such because this function is typically used to
/// get the unwrapped value at index `n` in an argument list.
///
/// This function raises if the unwrapped value is not a 32-bit unsigned
/// integer.
pub fn getUInteger(argv: []const Value, n: i32) Error!u32 {
    return fromAbi(interface.rt.getuinteger(argv.ptr, n));
}

/// Returns whether a wrapped value is an array.
pub fn isArray(v: Value) bool {
    return checkTag(v, .array);
}

/// Returns whether a wrapped value is a boolean.
pub fn isBoolean(v: Value) bool {
    return checkTag(v, .boolean);
}

/// Returns whether a wrapped value is a buffer.
pub fn isBuffer(v: Value) bool {
    return checkTag(v, .buffer);
}

/// Returns whether a wrapped value is an nfunction.
pub fn isNFunction(v: Value) bool {
    return checkTag(v, .nfunction);
}

/// Returns whether a wrapped value is a function.
pub fn isFunction(v: Value) bool {
    return checkTag(v, .function);
}

/// Returns whether a wrapped value is an integer that fits an `i32`.
pub fn isInteger(v: Value) bool {
    return interface.rt.checkint(v) != 0;
}

/// Returns whether a wrapped value is a keyword.
pub fn isKeyword(v: Value) bool {
    return checkTag(v, .symbol) and interface.rt.is_keyword(v);
}

/// Returns whether a wrapped value is nil.
pub fn isNil(v: Value) bool {
    return checkTag(v, .nil);
}

/// Returns whether a wrapped value is a number.
pub fn isNumber(v: Value) bool {
    return checkTag(v, .number);
}

/// Returns whether a wrapped value is a raw pointer.
pub fn isPointer(v: Value) bool {
    return checkTag(v, .pointer);
}

/// Returns whether a wrapped value is a string.
pub fn isString(v: Value) bool {
    return checkTag(v, .string);
}

/// Returns whether a wrapped value is a map.
pub fn isMap(v: Value) bool {
    return checkTag(v, .map);
}

/// Returns whether a wrapped value is a symbol.
pub fn isSymbol(v: Value) bool {
    return checkTag(v, .symbol) and !interface.rt.is_keyword(v);
}

/// Returns whether a wrapped value is a table.
pub fn isTable(v: Value) bool {
    return checkTag(v, .table);
}

/// Returns whether a wrapped value is a tuple.
pub fn isTuple(v: Value) bool {
    return checkTag(v, .tuple);
}

/// Returns whether the marshalling is in unsafe mode.
///
/// Unsafe mode means the user who started the marshalling has declared that
/// the bytes will not leave this process. As a result, raw addresses written
/// into them are still meaningful when they are read back.
///
/// `pushPointer` and `pullPointer` work only in unsafe mode and raise an error
/// otherwise, so a callback that handles a pointer checks this first:
///
/// ```zig
/// if (!isUnsafe(m)) return panic("cannot marshal a handle in safe mode");
/// ```
///
/// If `capability` is a type other than `*Marshal` or `*Unmarshal`, it is a
/// compile error.
pub fn isUnsafe(capability: anytype) bool {
    const Given = @TypeOf(capability);
    if (Given != *Marshal and Given != *Unmarshal) @compileError(
        "isUnsafe takes the `*Marshal` a `marshal` callback receives or the " ++
            "`*Unmarshal` an `unmarshal` callback receives. The type given is `" ++
            @typeName(Given) ++ "`.",
    );
    const flags = if (Given == *Marshal)
        interface.rt.marshal_flags(capability)
    else
        interface.rt.unmarshal_flags(capability);
    return (flags & constants.marshal_unsafe) != 0;
}

/// Wraps a slice of `u8` as a keyword.
pub fn keyword(bytes: []const u8) Value {
    return interface.rt.new_keyword(bytes.ptr, bytes.len);
}

/// Returns the length of a value.
///
/// `v` may be a string, symbol, keyword, buffer, array, tuple, map or
/// table. It may also be an abstract type with a `length` callback. A type
/// without one has no length, whatever methods it has: a `:length` method is
/// not called, as it would be in C Janet.
///
/// This function raises an error for any other value, and for an abstract type
/// without a `length` callback. It never runs Janet code.
pub fn length(v: Value) Error!usize {
    return @intCast(try fromAbi(interface.rt.length(v)));
}

/// Returns the event loop on which an nfunction is running.
///
/// The result may be used from any thread. It is valid until the VM that
/// provided the result shuts down, and a `post` after that point reads state
/// teardown has already released.
///
/// Nothing signals the shutdown to a module's own thread, so such a thread
/// cannot wait for it. A module should stop the thread from a finalizer
/// instead: let an abstract value own the thread and join it in the `gc`
/// callback passed to `define`. Teardown runs every finalizer before it
/// releases the loop, so a join there finishes while the `Loop` is still
/// valid.
///
/// In a build without the event loop, this function raises an error at run
/// time with the message "event loop not enabled".
pub fn loop() Error!*Loop {
    return fromAbi(interface.rt.current_loop());
}

/// Keeps a value reachable during an in-progress garbage collection.
pub fn mark(v: Value) void {
    interface.rt.mark(v);
}

/// Calls the method `name` on the first of `args`.
///
/// The method is looked up in `args[0]` under the keyword `name` and called
/// with all of `args`, so the receiver is its first argument.
///
/// This function raises "method :name expected at least 1 argument" when
/// `args` is empty and "could not find method :name for x" when the lookup
/// is nil. Otherwise it raises as `call` does.
///
/// This function re-enters Janet code, so the re-entry rules at the top of
/// this file apply.
///
/// This is the equivalent of `(:name ;args)` in Janet code. See also `call`.
pub fn mcall(name: [:0]const u8, args: []const Value) Error!Value {
    return fromAbi(interface.rt.mcall(name.ptr, args.ptr, args.len));
}

/// Allocates an abstract of this type, as a `*T`.
///
/// `size` is the total number of bytes to allocate and defaults to
/// `@sizeOf(T)`.
///
/// A larger `size` is for a payload with extra bytes after its fields.
/// Those bytes need not be an array: the runtime allocates a socket address
/// this way, and so does a compiled PEG. Accordingly, `T` describes only the
/// fixed part, and the caller can pass `@sizeOf(T)` plus the number of bytes
/// that follow.
pub fn new(comptime T: type, at: *const AbstractType, size: ?usize) *T {
    const p = interface.rt.abstract(at, size orelse @sizeOf(T));
    return @ptrCast(@alignCast(p.?));
}

/// Returns the next method name after `key`, or nil at the end.
///
/// This walks `methods`, the same slice `getMethod` searches. An abstract
/// type's `next` callback uses it to iterate its own method names.
pub fn nextMethod(methods: []const Method, key: Value) Error!Value {
    const rows = terminate(Method, methods);
    return fromAbi(interface.rt.nextmethod(@ptrCast(&rows), key));
}

/// Returns the wrapped nil value.
pub inline fn nil() Value {
    return repr.wrapNil();
}

/// Returns the wrapped number value.
pub inline fn number(x: f64) Value {
    return repr.wrapNumber(x);
}

/// Raises a formatted refusal.
///
/// ```zig
/// return panicFormat("invalid option :{s}", .{name});
/// ```
///
/// The formatter is Zig's `std.fmt` rather than Janet's pretty printer.
///
/// This returns the error rather than raising it, so a call site reads
/// `return panicFormat(...)` and not `try panicFormat(...)`. There is no
/// success value to return, so returning the error is all a caller does.
pub fn panicFormat(comptime fmt: []const u8, args: anytype) Error {
    const len = std.fmt.count(fmt, args);
    var stack: [256]u8 = undefined;
    if (len < stack.len) return panic(std.fmt.bufPrintZ(&stack, fmt, args) catch unreachable);
    const heap = alloc(u8, len + 1) orelse return panic("out of memory building a refusal");
    defer free(heap);
    return panic(std.fmt.bufPrintZ(heap, fmt, args) catch unreachable);
}

/// Calls `f` with `args` on a fresh fiber and returns rather than raises.
///
/// The result is a `Called` value. The `.signal` member is how the fiber ended
/// (`.ok` for a normal return, `.error` for a raise, `.yield` for a yield or
/// one of the other ordinary signals). The `.value` member is the value that
/// accompanies the signal. The `.fiber` member is the fiber that ran the call
/// and it is by construction always fresh.
///
/// The fiber can be resumed from Janet only after `.yield`, when its status is
/// `:pending`; after `.ok` it is `:dead` and after `.error` it is `:error`.
///
/// The fresh fiber starts with no dynamic bindings. `(dyn ...)` inside `f` is
/// nil unless `f` sets the binding itself, and a `setdyn` inside `f` is not
/// seen by the caller. `call` runs on the caller's fiber and shares its
/// bindings.
///
/// `f` is a function, because a fiber runs nothing else. An nfunction, a
/// keyword or any other value is reported as `.error` with the message
/// "expected function, got <type>" and a nil `.fiber`.
///
/// This function re-enters Janet code, so the re-entry rules at the top of
/// this file apply.
///
/// See also `call` and `mcall`.
pub fn pcall(f: Value, args: []const Value) Called {
    var out_value: Value = nil();
    var out_fiber: Value = nil();
    const signal = interface.rt.pcall_value(f, args.ptr, args.len, &out_value, &out_fiber);
    return .{ .signal = signal, .value = out_value, .fiber = out_fiber };
}

/// Wraps a raw pointer.
///
/// The runtime does not directly dereference the result. A module may access
/// it using `toPointer` (to read it back) and `pushPointer` (to write it to a
/// marshalling stream).
///
/// On aarch64 other than Apple's, `p` must be aligned to 4 bytes; elsewhere it
/// need not be aligned. The runtime there stores an address shifted right by
/// two, which discards its low bits, so an under-aligned pointer does not come
/// back as the pointer that was passed in. A Debug or ReleaseSafe runtime
/// asserts the alignment; any other build does not check it.
pub fn pointer(p: ?*anyopaque) Value {
    return interface.rt.wrap_pointer(p);
}

/// Asks the loop thread to run `cb(wake, ctx)` on the next iteration of the
/// loop.
///
/// This function may be called from any thread. `ctx` is the module's
/// responsibility and the Janet VM does not read or free it.
///
/// Back-pressure is a block, not a drop: the self-pipe's write side is
/// blocking, so a thread posting faster than the loop drains waits in the
/// write. Callbacks run one at a time on the loop thread, in arrival order.
pub fn post(l: *Loop, cb: PostCallback, ctx: *anyopaque) void {
    interface.rt.post(l, cb, ctx);
}

/// Allocates this type's payload and enters it into the unmarshalling
/// stream's reference table.
///
/// This is `pushAbstract`'s counterpart. `size` defaults to `@sizeOf(T)`. See
/// `new` for what to pass when the payload is larger than that.
pub fn pullAbstract(u: *Unmarshal, comptime T: type, size: ?usize) Error!*T {
    const p = try fromAbi(interface.rt.unmarshal_abstract(u, size orelse @sizeOf(T)));
    return @ptrCast(@alignCast(p.?));
}

/// Enters an already-allocated payload into the unmarshalling stream's
/// reference table.
///
/// An `unmarshal` callback registers its payload exactly once, so that a
/// back-reference later in the stream resolves to it. Either call
/// `pullAbstract`, which allocates and registers in one step, or allocate with
/// `new` and register with this. Doing both, or neither, is an error.
pub fn pullAbstractReuse(u: *Unmarshal, p: *anyopaque) Error!void {
    return fromAbi(interface.rt.unmarshal_abstract_reuse(u, p));
}

/// Reads a single byte from the unmarshalling stream.
pub fn pullByte(u: *Unmarshal) Error!u8 {
    return fromAbi(interface.rt.unmarshal_byte(u));
}

/// Reads `dest.len` bytes from the unmarshalling stream into `dest`.
pub fn pullBytes(u: *Unmarshal, dest: []u8) Error!void {
    return fromAbi(interface.rt.unmarshal_bytes(u, dest.ptr, dest.len));
}

/// Raises an error if fewer than `n` bytes remain in the unmarshalling
/// stream.
pub fn pullEnsure(u: *Unmarshal, n: usize) Error!void {
    return fromAbi(interface.rt.unmarshal_ensure(u, n));
}

/// Reads a 64-bit signed integer from the unmarshalling stream.
pub fn pullInt64(u: *Unmarshal) Error!i64 {
    return fromAbi(interface.rt.unmarshal_int64(u));
}

/// Reads a 32-bit signed integer from the unmarshalling stream.
pub fn pullInteger(u: *Unmarshal) Error!i32 {
    return fromAbi(interface.rt.unmarshal_int(u));
}

/// Reads a number from the unmarshalling stream.
pub fn pullNumber(u: *Unmarshal) Error!f64 {
    const v = try pullValue(u);
    return toNumber(v) orelse return panic("expected a number in the stream");
}

/// Reads a raw pointer from the unmarshalling stream.
///
/// This raises an error unless the stream is in unsafe mode. See `isUnsafe`.
pub fn pullPointer(u: *Unmarshal) Error!?*anyopaque {
    return fromAbi(interface.rt.unmarshal_ptr(u));
}

/// Returns how many bytes of the unmarshalling stream are still unread.
///
/// A callback that reads a count and then reads that many elements can use
/// this to reject an impossible count before allocating for it. No element
/// occupies less than one byte, so a count larger than this is malformed.
pub fn pullRemaining(u: *Unmarshal) usize {
    return interface.rt.unmarshal_remaining(u);
}

/// Reads a size from the unmarshalling stream.
pub fn pullSize(u: *Unmarshal) Error!usize {
    return fromAbi(interface.rt.unmarshal_size(u));
}

/// Reads a `Value` from the unmarshalling stream, re-entering the
/// unmarshaller's own traversal.
pub fn pullValue(u: *Unmarshal) Error!Value {
    return fromAbi(interface.rt.unmarshal_value(u));
}

/// Appends bytes to the buffer into which a value is being rendered.
///
/// This function, together with `format`, is the way in which an abstract
/// type's `tostring` callback writes its output.
///
/// The callback appends to the buffer it is given rather than returning a
/// string, so no storage of its own has to outlive its return, and so that its
/// output can sit inside a larger rendering.
pub fn push(r: *Render, bytes: []const u8) Error!void {
    return fromAbi(interface.rt.buffer_push_bytes(r, bytes.ptr, bytes.len));
}

/// Enters the abstract into the marshalling stream's reference table.
///
/// A caller calls this before pushing the payload, and `unmarshal` must call
/// `pullAbstract` or `pullAbstractReuse` in the same position. That is what
/// lets a value reached later in the stream refer back to this object. An
/// `unmarshal` that never registers raises an error.
pub fn pushAbstract(m: *Marshal, p: *anyopaque) void {
    interface.rt.marshal_abstract(m, p);
}

/// Writes a single byte to the marshalling stream.
pub fn pushByte(m: *Marshal, b: u8) Error!void {
    return fromAbi(interface.rt.marshal_byte(m, b));
}

/// Writes `bytes` to the marshalling stream.
pub fn pushBytes(m: *Marshal, bytes: []const u8) Error!void {
    return fromAbi(interface.rt.marshal_bytes(m, bytes.ptr, bytes.len));
}

/// Writes a 64-bit signed integer to the marshalling stream.
pub fn pushInt64(m: *Marshal, x: i64) Error!void {
    return fromAbi(interface.rt.marshal_int64(m, x));
}

/// Writes a 32-bit signed integer to the marshalling stream.
pub fn pushInteger(m: *Marshal, x: i32) Error!void {
    return fromAbi(interface.rt.marshal_int(m, x));
}

/// Writes a number to the marshalling stream, as a `Value`.
///
/// The marshaller has no entry point for a bare `f64`, so this wraps the
/// number and writes that instead. Writing the eight raw bytes with
/// `pushBytes` would record them in the writing machine's byte order, and a
/// machine with the opposite order would read back a different number.
pub fn pushNumber(m: *Marshal, x: f64) Error!void {
    return pushValue(m, number(x));
}

/// Writes a raw pointer to the marshalling stream.
///
/// This raises an error unless the stream is in unsafe mode, because an
/// address means nothing to another process. Check `isUnsafe` first.
pub fn pushPointer(m: *Marshal, p: ?*const anyopaque) Error!void {
    return fromAbi(interface.rt.marshal_ptr(m, p));
}

/// Writes a size to the marshalling stream.
pub fn pushSize(m: *Marshal, n: usize) Error!void {
    return fromAbi(interface.rt.marshal_size(m, n));
}

/// Writes a `Value` to the marshalling stream, re-entering the marshaller's
/// own traversal.
pub fn pushValue(m: *Marshal, v: Value) Error!void {
    return fromAbi(interface.rt.marshal_value(m, v));
}

/// Puts `x` in `d` associated with `key`.
///
/// `d` may be an array, a buffer or a table. It may also be an abstract type,
/// which is handled by that type's `put` callback if the type declares that
/// callback.
///
/// This function raises an error for any other value type and for an abstract
/// type with no `put` callback.
pub fn put(d: Value, key: Value, x: Value) Error!void {
    return fromAbi(interface.rt.put(d, key, x));
}

/// Builds one registration row.
///
/// `nfun` must be of type `fn (argv: []Value) Error!Value`. A function of any
/// other shape is a compile error describing what is wrong with it.
pub fn reg(comptime name: [:0]const u8, nfun: anytype, comptime doc: ?[:0]const u8) Reg {
    comptime checkNFunction(name, @TypeOf(nfun));
    return .{
        .name = name.ptr,
        .nfun = raise.stored(nfun),
        .documentation = if (doc) |d| d.ptr else null,
    };
}

/// Records an abstract type under its name so the unmarshaller can find it.
///
/// A marshalled abstract includes its type's name, and unmarshalling resolves
/// that name. A type with an `unmarshal` callback is unreachable without this.
/// It is called from `entry`'s `defs`.
///
/// Registering the same type twice is allowed. Registering a different type
/// under a name already taken raises an error, as one name resolving to two
/// types would make a marshalled stream ambiguous.
pub fn registerAbstract(at: *const AbstractType) Error!void {
    return fromAbi(interface.rt.register_abstract_type(at));
}

/// Returns the fiber for use by `await` and `wake`.
///
/// A caller wishing to use `await` reads the fiber, passes it to `gcroot`,
/// keeps it across the wait, passes it to `wake` in the posted callback, and
/// then passes it to `gcunroot`.
///
/// The `gcroot` is needed because until `wake` runs, nothing the garbage
/// collector scans refers to the fiber and the rooting is the only thing
/// keeping it alive. From `wake` onwards the event loop refers to it as well.
pub fn rootFiber() Error!Value {
    return fromAbi(interface.rt.root_fiber_value());
}

/// Wraps a slice of `u8` as a string.
pub fn string(bytes: []const u8) Value {
    return interface.rt.new_string(bytes.ptr, bytes.len);
}

/// Wraps key-value pairs as a map.
///
/// If a key is repeated, the last key is associated with the value. A nil
/// value drops its pair. `pairs` is the caller's own pairs, not a dictionary's
/// hash array.
///
/// The name is `mapOf` rather than `map` because `map` is what a caller is
/// likely to have named something of its own.
pub fn mapOf(pairs: []const Keyval) Value {
    return interface.rt.new_map(pairs.ptr, pairs.len);
}

/// Wraps a slice of `u8` as a symbol.
pub fn symbol(bytes: []const u8) Value {
    return interface.rt.new_symbol(bytes.ptr, bytes.len);
}

/// Wraps key-value pairs as a table.
///
/// See `mapOf` for a further explanation of duplicate keys and nil values.
/// The name matches `mapOf`.
pub fn tableOf(pairs: []const Keyval) Value {
    return interface.rt.new_table(pairs.ptr, pairs.len);
}

/// Returns the payload of an abstract of the type `at` describes.
///
/// `v` is a value read out of a view rather than an argument slot, such as an
/// element of a tuple.
///
/// This function returns null if `v` is not an abstract, or is an abstract of
/// another type. It cannot raise.
///
/// This function does not check that `T` is `at`'s payload type. Passing
/// another type reads the payload as that type.
///
/// See `getAbstract`, which reads the same payload out of an argument slot.
pub fn toAbstract(comptime T: type, v: Value, at: *const AbstractType) ?*T {
    if (!checkTag(v, .abstract)) return null;
    const p = interface.rt.unwrap_pointer(v) orelse return null;
    if (abstract_type.ofAbstract(p) != at) return null;
    return @ptrCast(@alignCast(p));
}

/// Returns the pairs of a table, a map or a dictionary abstract.
///
/// `v` is a value read out of a view rather than an argument slot, such as an
/// element of a tuple.
///
/// This function returns null if `v` is none of those types. It raises if an
/// abstract's `length` callback raises.
///
/// See `Dictionary`, which is what the reading and the validity of the result
/// are described on.
pub fn toDictionary(v: Value) Error!?Dictionary {
    var out: abi.Dictionary = undefined;
    if (!try fromAbi(interface.rt.to_dictionary(v, &out))) return null;
    return dictionaryOf(out);
}

/// Returns the elements of an array, a vector, a tuple or an indexed abstract.
///
/// `v` is a value read out of a view rather than an argument slot, such as an
/// element of a tuple.
///
/// This function returns null if `v` is none of those types. It raises if an
/// abstract's `length` callback raises.
///
/// See `Indexed`, which is what the reading and the validity of the result are
/// described on.
pub fn toIndexed(v: Value) Error!?Indexed {
    var out: abi.Indexed = undefined;
    if (!try fromAbi(interface.rt.to_indexed(v, &out))) return null;
    return indexedOf(out);
}

/// Returns the unwrapped number value as an `i32`.
///
/// This function returns null if `v` is not a number that an `i32` represents
/// exactly. A fraction and a number out of range are both null, rather than a
/// truncated or clamped result.
pub fn toInteger(v: Value) ?i32 {
    if (!isInteger(v)) return null;
    return interface.rt.unwrap_integer(v);
}

/// Returns a keyword's name, without the leading colon.
///
/// This function returns null if `v` is not a keyword.
///
/// The result is `[:0]` because a keyword is interned with a terminator. The
/// bytes are stable while the value is reachable.
pub fn toKeyword(v: Value) ?[:0]const u8 {
    if (!isKeyword(v)) return null;
    return toCString(v, .symbol);
}

/// Returns the unwrapped number value as `f64`.
///
/// This function returns null if `v` is not a number.
pub fn toNumber(v: Value) ?f64 {
    if (!checkTag(v, .number)) return null;
    return repr.unwrapNumber(v);
}

/// Returns the unwrapped raw pointer.
///
/// This function returns null if `v` is not a pointer. The result is optional
/// twice: the inner null is the null pointer that `pointer(null)` wraps.
pub fn toPointer(v: Value) ??*anyopaque {
    if (!checkTag(v, .pointer)) return null;
    return interface.rt.unwrap_pointer(v);
}

/// Returns a string's bytes.
///
/// This function returns null if `v` is not a string. A buffer has no
/// terminator, so `bytesView` is what reads a buffer.
///
/// The result is `[:0]` because a string is allocated with a terminator past
/// its length. The bytes are stable while the value is reachable.
pub fn toString(v: Value) ?[:0]const u8 {
    return toCString(v, .string);
}

/// Returns a symbol's name.
///
/// This function returns null if `v` is not a symbol.
///
/// The result is `[:0]` because a symbol is interned with a terminator. The
/// bytes are stable while the value is reachable.
pub fn toSymbol(v: Value) ?[:0]const u8 {
    if (!isSymbol(v)) return null;
    return toCString(v, .symbol);
}

/// Returns the truthiness of the value.
///
/// In Janet, every value other than `nil` and `false` is considered truthy.
///
/// This is the only way to read a boolean out of a `Value`.
pub fn truthy(v: Value) bool {
    return repr.truthy(v);
}

/// Wraps a slice of `Value` as a tuple.
pub fn tuple(items: []const Value) Value {
    return interface.rt.new_tuple(items.ptr, items.len);
}

/// Schedules `fiber` to be resumed with `value` and returns whether it was
/// scheduled.
///
/// This function may only be called from a posted callback, which receives a
/// `*Wake` as its first parameter, and only for a fiber belonging to the same
/// loop. In practice that is the fiber `rootFiber` returned. Passing a fiber
/// from another VM is undefined and is not detected.
///
/// This returns `false` if `fiber` is not a fiber, if it has already finished
/// or if `ev/cancel` has cancelled it. Nothing is scheduled in those cases.
/// The callback still owns its context and still has to free it and call
/// `gcunroot` regardless of the value returned.
///
/// A fiber that has not yet run is started rather than resumed. Scheduling a
/// fiber that is already scheduled adds a second entry to the loop's queue.
/// Each entry records the fiber's scheduling count as it stood when the entry
/// was made, and the loop runs an entry only while that count still matches,
/// so the earlier entry is discarded and the later entry runs. This function
/// cannot raise.
pub fn wake(w: *Wake, fiber: Value, value: Value) bool {
    return interface.rt.wake(w, fiber, value);
}

// ==========================================================================
// Private functions
// ==========================================================================

/// Checks that `Given` is a function of the shape an nfunction must have.
///
/// `name` is the registered name of the function.
fn checkNFunction(comptime name: []const u8, comptime Given: type) void {
    const where = "nfunction '" ++ name ++ "': ";
    const wanted = "It must be `fn (argv: []Value) Error!Value`";

    const fn_info = switch (@typeInfo(Given)) {
        .@"fn" => |fi| fi,
        .pointer => |ptr| switch (@typeInfo(ptr.child)) {
            .@"fn" => |fi| fi,
            else => @compileError(where ++ "this is not a function. " ++ wanted),
        },
        else => @compileError(where ++ "this is not a function. " ++ wanted),
    };
    if (fn_info.params.len != 1 or fn_info.params[0].type != []Value) {
        @compileError(where ++ "it takes its arguments as one `[]Value` slice, not " ++
            "a count and a pointer. " ++ wanted);
    }
    const R = fn_info.return_type orelse @compileError(where ++ wanted);
    if (R != Error!Value) {
        // The exact type, not the shape of it: `anyerror!Value` would be a
        // broader error set reinterpreted at the call rather than diagnosed at
        // the definition, which is the one place it can be.
        @compileError(where ++ "its return type is `" ++ @typeName(R) ++
            "`. An nfunction returns a `Value` or raises, so the type is exactly " ++
            "`Error!Value`: a wider error set is reinterpreted at the call rather " ++
            "than diagnosed here.");
    }
}

/// Returns whether a wrapped value has this tag.
///
/// The test reads the bits `api/repr.zig` lays out and makes no crossing; the
/// file header says why both compilations agree on them. It touches no runtime
/// state, so it is valid from any thread.
inline fn checkTag(v: Value, comptime t: repr.Tag) bool {
    return repr.checkType(v, t);
}

/// Turns a runtime report back into an error.
///
/// A refusal made by the runtime arrives as a report rather than as an error
/// because the table field it crossed has a C calling convention.
inline fn fromAbi(v: anytype) Error!@TypeOf(v) {
    return raise.fromAbi(v);
}

/// Builds a `Dictionary` from the `abi.Dictionary` the runtime gives.
///
/// A table's slots are the one run, so reading starts past it
/// with the run as what is not yet returned. A null `items` is an empty value
/// or an abstract, and either starts with no run.
fn dictionaryOf(view: abi.Dictionary) Dictionary {
    if (view.items) |p| {
        return .{ .count = view.count, .len = view.len, .value = view.value, .position = view.len, .rest = p[0..view.len] };
    }
    return .{ .count = view.count, .len = view.len, .value = view.value };
}

/// Builds an `Indexed` from the `abi.Indexed` the runtime gives.
///
/// An array's or a tuple's storage is the one run. A null `items` is an empty
/// value, a vector or an abstract, and each starts with no run.
fn indexedOf(view: abi.Indexed) Indexed {
    const run: []const Value = if (view.items) |p| p[0..view.len] else &.{};
    return .{ .len = view.len, .value = view.value, .run = run };
}

/// Appends a null-name row to a table.
///
/// `nfuns_ext`, `getmethod` and `nextmethod` each take a table that ends with
/// a null-name row.
fn terminate(comptime Row: type, rows: []const Row) [max_table_rows + 1]Row {
    std.debug.assert(rows.len <= max_table_rows);
    var out: [max_table_rows + 1]Row = @splat(.{});
    @memcpy(out[0..rows.len], rows);
    return out;
}

/// Returns the NUL-terminated bytes of a value with this tag.
///
/// The one place the sentinel is claimed: `toKeyword`, `toString` and
/// `toSymbol` all reach it, so which tags have a terminator is decided in one
/// place. A string, a symbol and a keyword are each allocated a byte longer
/// than their length and terminated there. A buffer is not terminated.
///
/// This function returns null if `v` does not have the tag `t`.
fn toCString(v: Value, comptime t: repr.Tag) ?[:0]const u8 {
    if (!checkTag(v, t)) return null;
    // Not `bytesView`: it returns the empty slice for a null pointer, and an
    // empty slice has nowhere to put a sentinel.
    var out: abi.ByteView = undefined;
    if (!interface.rt.bytes_view(v, &out)) return null;
    // A value with one of these three tags always has a payload: the
    // shortest is one byte, the terminator of an empty string. The arm is
    // here because the field is optional, not because it can be taken.
    const p = out.bytes orelse return null;
    return p[0..out.len :0];
}
