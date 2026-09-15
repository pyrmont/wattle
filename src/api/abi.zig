//! The application binary interface for communication between the runtime and
//! native modules.
//!
//! The runtime and a native module are compiled separately. A module
//! calls back into the runtime through the table of function pointers that
//! `interface.zig` declares. Each field of that table is a _crossing_: a point
//! where a module's compilation and the runtime's meet. Both compilations
//! compile this file, so a type declared here has one declaration for the two.
//! They also compile `src/module.zig`, whose `CFunction`, `Error` and
//! `PostCallback` have one declaration for the same reason.
//!
//! A module author does not import this file. Instead `src/module.zig`
//! re-exports the declarations an author uses.
//!
//! ## What belongs in this file
//!
//! A declaration is here because the runtime's compilation and the module's
//! compilation must agree on it. There are five kinds of declarations:
//!
//! - The three views: `ByteView`, `IndexedView` and `DictView`.
//!
//! - The six capabilities: `Env`, `Loop`, `Marshal`, `Render`, `Unmarshal`
//!   and `Wake`.
//!
//! - The two enums: `Signal` and `FiberStatus`.
//!
//! - The layouts a crossing takes or returns by pointer: `Reg`, `Range`,
//!   `BuildConfig` and `KV`; the heap header an abstract payload
//!   sits behind, `AbstractHead` (which includes `GCObject`, `GCFlags` and
//!   `GCData`); and the function pointer type `CFunction`.
//!
//! - The abstract type, `AbstractType`: a name and the callbacks the
//!   runtime dispatches through.
//!
//! The one constant, the one aliased type and `abstractHead` are here because
//! each is part of, or computed from, a type declared here. `abstract_payload`
//! is an offset into `AbstractHead`, `AtomicInt` sets the width of `GCData`,
//! and `abstractHead` subtracts `abstract_payload`. This file gains a new
//! layout only when the decision on what crosses to an author changes.
//!
//! ## How a view and a capability differ
//!
//! A _view_ is a pointer to a collection of elements and a count over that
//! collection's own storage. This would be a slice in Zig but it is defined as
//! an `extern struct` because it crosses a `callconv(.c)` signature which a
//! slice cannot do. `module.zig` then rebuilds an author's own type from it: a
//! slice for a `ByteView`'s bytes and an `IndexedView`'s elements, and
//! `module.Pairs` for a `DictView`, whose storage is sparse rather than dense
//! and so has no faithful slice. The three views are: `ByteView`,
//! `IndexedView` and `DictView`. A view offers no ability to mutate.
//!
//! A _capability_ is `opaque {}`. It is the authority to perform an operation
//! rather than a handle to data: an author holds a pointer, passes it back to
//! a function in `module.zig`, and can neither read a field nor make a
//! capability. It converts to and from a `Value` in neither direction. The
//! six capabilities are `Env`, `Loop`, `Marshal`, `Render`, `Unmarshal` and
//! `Wake`.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");
const builtin = @import("builtin");

// ==========================================================================
// Project imports
// ==========================================================================

const repr = @import("repr");

// ==========================================================================
// Constants
// ==========================================================================

/// The offset to an abstract's payload from the beginning of its allocation.
pub const abstract_payload = @offsetOf(AbstractHead, "_data");

// ==========================================================================
// Aliased types
// ==========================================================================

/// The width of a refcount.
pub const AtomicInt = if (builtin.os.tag == .windows) c_long else i32;

// ==========================================================================
// Types
// ==========================================================================

/// The header in front of an abstract's payload.
///
/// An abstract's allocation begins with an `AbstractHead` and its payload
/// follows. `abstractHead` recovers the header from a pointer to the
/// payload.
pub const AbstractHead = extern struct {
    gc: GCObject = .{},
    type: *const AbstractType,
    size: usize = 0,
    _data: [0]c_longlong = std.mem.zeroes([0]c_longlong),
};

/// An abstract type specification.
///
/// Janet supports user-defined abstract types. To enable these types to
/// function within the runtime, a module author must provide certain
/// information: a name for the type, and the callbacks to which the runtime
/// dispatches. An `AbstractType` is that information in a form that the
/// runtime can store.
///
/// A module author creates a custom type using `module.define`. This requires
/// the author's custom Zig type as the first argument and a struct literal of
/// the name and the callbacks as the second. An `AbstractType` is what
/// `module.define` returns rather than what it takes: the literal's callbacks
/// are written over `*T` while the ones in `AbstractType` are erased.
///
/// The result is declared at the container level because a type is identified
/// by the address of its `AbstractType`. `module.new` records that address in
/// the abstract it allocates and `module.getAbstract` refuses a payload whose
/// address differs, so two copies of the same description are two types that
/// do not recognise each other's values.
///
/// Every callback but `unmarshal` takes a pointer to the custom Zig type as
/// its first argument. It is written here in its type erased form (as
/// `*anyopaque` rather than `*T`) but the module author should use `*T` in
/// their callbacks. `module.define` generates the shim that handles this
/// casting. `unmarshal` builds a payload rather than receiving one, and its
/// result is optional so that the runtime can test it: `runtime/marsh.zig`
/// ends the process with "null pointer abstract" where a module returned
/// null.
///
/// Six of the callbacks cannot raise: `gc`, `gcmark`, `gcperthread`,
/// `compare`, `hash` and `bytes`. Their types have no error union, so a module
/// author cannot report a failure from inside these callbacks and must handle
/// it on the spot. The runtime calls them where nothing could act on a report
/// anyway: `gc` runs mid-sweep on an object that is already unreachable,
/// `gcmark` mid-traversal, and `compare` and `hash` from inside a comparison
/// that cannot raise. The other eight run inside an interpreter frame, where a
/// raise reaches the fiber that called it.
pub const AbstractType = struct {
    name: []const u8,

    // The collector.
    gc: ?*const fn (data: *anyopaque, len: usize) callconv(.c) void = null,
    gcmark: ?*const fn (data: *anyopaque, len: usize) callconv(.c) void = null,
    gcperthread: ?*const fn (data: *anyopaque, len: usize) callconv(.c) void = null,

    // Access.
    get: ?*const fn (data: *anyopaque, key: repr.Value) error{JanetSignal}!?repr.Value = null,
    put: ?*const fn (data: *anyopaque, key: repr.Value, value: repr.Value) error{JanetSignal}!void = null,
    next: ?*const fn (p: *anyopaque, key: repr.Value) error{JanetSignal}!repr.Value = null,
    length: ?*const fn (p: *anyopaque, len: usize) error{JanetSignal}!usize = null,
    call: ?*const fn (p: *anyopaque, argc: i32, argv: [*]repr.Value) error{JanetSignal}!repr.Value = null,

    // Identity.
    compare: ?*const fn (lhs: *anyopaque, rhs: *anyopaque) callconv(.c) i32 = null,
    hash: ?*const fn (p: *anyopaque, len: usize) callconv(.c) i32 = null,

    // Rendering.
    tostring: ?*const fn (p: *anyopaque, render: *Render) error{JanetSignal}!void = null,
    bytes: ?*const fn (p: *anyopaque, len: usize) callconv(.c) ByteView = null,

    // Marshalling.
    marshal: ?*const fn (p: *anyopaque, m: *Marshal) error{JanetSignal}!void = null,
    unmarshal: ?*const fn (u: *Unmarshal) error{JanetSignal}!?*anyopaque = null,
};

/// What a module was built against: a Janet version, the configuration bits,
/// the interface fingerprint and the compiler's version.
///
/// `module.entry` exports a function named `_wattle_mod_config` that writes a
/// `BuildConfig`. The loader looks `_wattle_mod_config` up in the loaded shared
/// object, calls what it finds, and compares three fields in this order:
/// `bits`, `zig` and `api`. A difference in any of the three is a refusal
/// naming that field.
///
/// `api` is `api/fingerprint.zig`'s number, and `zig` is the compiler's
/// version string NUL-padded to thirty-two bytes and compared byte for byte.
/// `major`, `minor` and `patch` are the Janet version. They appear in a
/// refusal message and are not compared, so a module built against one release
/// loads into another whose interface is the same.
///
/// The loader reads this struct field by field, so both `_wattle_mod_config`
/// and this layout are part of the published interface. `_wattle_mod_config`
/// takes the width the loader has and returns the width the module has, so a
/// later loader can read a shorter, older `BuildConfig` than its own.
pub const BuildConfig = extern struct {
    major: c_uint = 0,
    minor: c_uint = 0,
    patch: c_uint = 0,
    bits: c_uint = 0,
    api: u64 = 0,
    zig: [32]u8 = std.mem.zeroes([32]u8),
};

/// A byte sequence and its length.
///
/// `module.getBytes` and `module.bytesView` return a `[]const u8` built from
/// the `ByteView` the runtime gives them.
///
/// A module author writes the `bytes` callback of an abstract type to return
/// a `[]const u8`, not a `ByteView`. The callback the author writes and the
/// `bytes` field of `AbstractType` below are two different declarations:
/// `api/abstract_type.zig` checks the author's struct literal against
/// `Spec(T)`, whose `bytes` field is `fn (*const T, usize) []const u8`, and a
/// callback of any other shape is a compile error there. `module.define`
/// generates the shim that calls the author's callback and converts the slice
/// it returns into the `ByteView` the erased field declares.
///
/// `len` is a `usize`, so indexing the bytes with it needs no cast.
pub const ByteView = extern struct {
    bytes: ?[*]const u8,
    len: usize = 0,
};

/// The type of the slot a cfunction pointer is stored in.
///
/// A module author writes a cfunction as `fn ([]Value) Error!Value`, which is
/// `module.CFunction`, declared in `module.zig` and re-exported by
/// `api/raise.zig`. `CFunction` here is a different type: it is the C ABI's
/// shape for the same pointer, and it is what the runtime stores in `Reg.cfun`
/// and in `runtime/method_type.zig`'s `CMethod.cfun`.
///
/// `api/raise.zig` converts between the two. Its `stored` casts an author's
/// cfunction into this type at registration, and its `cfunction` casts the
/// stored pointer back before the runtime makes a call.
pub const CFunction = ?*const fn (argc: i32, argv: [*c]repr.Value) callconv(.c) repr.Value;

/// A sparse sequence of key-value pairs.
///
/// `module.getDictionary` and `module.dictionaryView` return a `module.Pairs`
/// over a `DictView`.
///
/// `kvs` is the whole hash array and is `cap` long. `len` is how many of its
/// slots are occupied, so a walk reads every slot and skips the empty ones.
pub const DictView = extern struct {
    kvs: ?[*]const KV = null,
    len: usize = 0,
    cap: usize = 0,
};

/// The capability to define a binding in the environment into which a module
/// is loaded.
///
/// This type is an argument passed to `module.cfuns` and `module.def`,
/// typically within a function (traditionally called `defs`) that is passed as
/// an argument to `module.entry`. See `examples/numarray/numarray.zig`.
pub const Env = opaque {};

/// The status of a fiber.
///
/// `module.pcall` returns a `Called`, whose `fiber` field is the fiber that
/// ran the call. `module.fiberStatus` takes that fiber and returns a
/// `FiberStatus`, which is how a module distinguishes between the reasons a
/// fiber has stopped (e.g. a yield, a return, etc). `value/fibers.zig`
/// aliases this type and declares the runtime's own operations over a fiber.
///
/// The first fourteen values are the same as with `Signal`. This allows a
/// fiber's flag word to be read as a signal. The additional values are `new`
/// and `alive`.
pub const FiberStatus = enum(c_uint) {
    dead = 0,
    @"error" = 1,
    debug = 2,
    pending = 3,
    user0 = 4,
    user1 = 5,
    user2 = 6,
    user3 = 7,
    user4 = 8,
    user5 = 9,
    user6 = 10,
    user7 = 11,
    user8 = 12,
    user9 = 13,
    new = 14,
    alive = 15,
};

/// The next block on the heap list or a refcount.
///
/// The `data` field of `GCObject` is this type. `next` links a block the
/// garbage collector owns to the next block on its list. `refcount` is what a
/// threaded abstract, which isn't kept on a list, has instead.
pub const GCData = extern union {
    next: ?*GCObject,
    refcount: AtomicInt,
};

/// A heap block's flag word.
///
/// The `flags` field of `GCObject` is this type. `type` is the block's memory
/// type, as the integer with which the allocator numbers it. `own` is bits 16
/// through 21. Their meaning is determined by `type`.
pub const GCFlags = packed struct(u32) {
    type: u8 = 0,
    reachable: bool = false,
    disabled: bool = false,
    _reserved: u6 = 0,
    own: u6 = 0,
    _high: u10 = 0,
};

/// A 'heap block' used for garbage collection.
///
/// The `gc` field of `AbstractHead` is this type. The runtime reaches the
/// header in front of an abstract's payload through the `abstractHead`
/// function. `flags` is the block's flag word and `data` is its heap-list link
/// or its refcount.
pub const GCObject = extern struct {
    flags: GCFlags = .{},
    data: GCData = std.mem.zeroes(GCData),
};

/// The elements of an array or tuple.
///
/// `module.getIndexed` and `module.indexedView` return a `[]const Value`
/// built from the `IndexedView` the runtime gives them.
///
/// `items` is the aggregate's own storage and `len` is how many elements are
/// in it. `items` is null when the aggregate is empty, because an empty array
/// has no storage to point at. `module.getIndexed` and `module.indexedView`
/// substitute the empty slice for a null `items` so a caller of those two
/// receives a slice and never a null pointer.
pub const IndexedView = extern struct {
    items: ?[*]const repr.Value = null,
    len: usize = 0,
};

/// A key-value pair from a struct or table.
///
/// `DictView.kvs` points at an array of `KV`, `module.Pairs.next` returns a
/// `KV`, and `module.structOf` and `module.tableOf` take a slice of `KV`.
/// `module.Pair` is this type. A pair whose `key` is nil is an empty slot.
pub const KV = extern struct {
    key: repr.Value = std.mem.zeroes(repr.Value),
    value: repr.Value = std.mem.zeroes(repr.Value),
};

/// The capability to queue a callback for the loop thread's next turn.
///
/// `module.loop` returns a `*Loop` and `module.post` takes a `*Loop`. Any
/// thread may hold a `*Loop`, including a thread the runtime did not start. A
/// `*Loop` is valid until the runtime that returned it shuts down, and a
/// `module.post` after that point reads state teardown has released.
///
/// Nothing signals the shutdown to such a thread, so a thread cannot wait for
/// it. The join goes in a finalizer instead: the custom abstract type should
/// own the thread and stop it from that abstract type's `gc` callback. Teardown
/// runs every finalizer before it releases the loop, so a join there finishes
/// while the `*Loop` is still valid.
pub const Loop = opaque {};

/// The capability to append to the stream into which a value is being
/// marshalled.
///
/// An abstract type's `marshal` callback takes a `*Marshal`, as do the
/// `module.push*` functions and `module.isUnsafe`. A `*Marshal` is valid for
/// the duration of that callback only.
pub const Marshal = opaque {};

/// A slice argument's two folded indices.
///
/// `module.getRange` returns a `Range`. Both are indices, `start` included and
/// `end` excluded with `0 <= start <= end <= len`. Negative indices are handled
/// by `module.getRange` so that the values in `Range` are always non-negative.
/// However, both are `i32` because a Janet index is `i32`. A module author
/// slicing Zig memory with them must cast, since `i32` does not coerce to the
/// `usize` a slice expression takes.
pub const Range = extern struct {
    start: i32 = 0,
    end: i32 = 0,
};

/// One registration row: a name, a cfunction and three pieces of metadata.
///
/// `module.reg` returns a `Reg` and `module.cfuns` takes a table of `Reg`.
/// `documentation` is the docstring, and `source_file` and `source_line` are
/// where the cfunction is defined, for the source map. `module.reg` fills
/// `documentation` and leaves the other two at their defaults.
pub const Reg = extern struct {
    name: ?[*:0]const u8 = null,
    cfun: CFunction = null,
    documentation: ?[*:0]const u8 = null,
    source_file: ?[*:0]const u8 = null,
    source_line: i32 = 0,
};

/// The capability to append bytes to the buffer a value is being rendered
/// into.
///
/// An abstract type's `tostring` callback takes a `*Render`, and
/// `module.push` and `module.format` take a `*Render`. A `*Render` is valid
/// for the duration of that callback only.
pub const Render = opaque {};

/// The reason a fiber stopped: a return, a raise, a debug break, a yield or a
/// user signal.
///
/// Resuming a fiber returns the `Signal` that fiber stopped with. Raising is
/// what stops a fiber and selects that signal.
///
/// `module.pcall` returns a `Called` whose `signal` field is a `Signal`, and
/// `api/raise.zig`'s `signal` takes a `Signal`: `module.panic` raises with
/// `.error` and `module.await` with `.event`.
/// `runtime/signal.zig` declares the runtime's own operations over a signal.
///
/// The first fourteen values of `FiberStatus` are the same as these, so a
/// fiber's flag word can be read as a signal. `interrupt` and `event` share
/// the values of `user8` and `user9`, so they are declarations rather than
/// members; a use site still writes `.interrupt` or `.event`, as
/// `module.await` does.
pub const Signal = enum(c_uint) {
    ok = 0,
    @"error" = 1,
    debug = 2,
    yield = 3,
    user0 = 4,
    user1 = 5,
    user2 = 6,
    user3 = 7,
    user4 = 8,
    user5 = 9,
    user6 = 10,
    user7 = 11,
    user8 = 12,
    user9 = 13,

    /// The interpreter's own interrupt, which shares `user8`'s value.
    pub const interrupt: Signal = .user8;
    /// The event loop's wake-up, which shares `user9`'s value.
    pub const event: Signal = .user9;

    /// Converts a raw signal number into a `Signal`.
    ///
    /// `raw` is the number a `callconv(.c)` caller passed, which may be any
    /// `c_uint`. A number above `user9` converts to `user9`. This function
    /// cannot raise.
    pub fn fromWire(raw: c_uint) Signal {
        return if (raw > @intFromEnum(Signal.user9)) .user9 else @enumFromInt(raw);
    }
};

/// The capability to read from the stream into which a value is being
/// unmarshalled.
///
/// An abstract type's `unmarshal` callback takes an `*Unmarshal`, and the
/// `module.pull*` functions and `module.isUnsafe` take an `*Unmarshal`. An
/// `*Unmarshal` is valid for the duration of that callback only.
pub const Unmarshal = opaque {};

/// The capability to put a fiber back on the run queue with a value.
///
/// A posted callback takes a `*Wake` as its first parameter, and
/// `module.wake` takes a `*Wake`. A `*Wake` is valid for the duration of that
/// callback and on the loop thread only.
pub const Wake = opaque {};

// ==========================================================================
// Public functions
// ==========================================================================

/// Recovers an abstract's head from its payload.
///
/// `a` is a pointer to the payload of an abstract. This function cannot raise.
/// Nothing checks that `a` is an abstract's payload: any other pointer gives
/// back an `AbstractHead` that is garbage. `module.getAbstract` and
/// `module.toAbstract` check that a value is an abstract of a given type and
/// return its payload.
///
/// The parameter is `?*const anyopaque` so that a `*const` caller needs no
/// cast. The result is mutable because a caller marks or frees through it.
pub inline fn abstractHead(a: ?*const anyopaque) *AbstractHead {
    return @ptrFromInt(@intFromPtr(a) -% abstract_payload);
}

// ==========================================================================
// Tests
// ==========================================================================

comptime {
    // `FiberStatus` numbers its own members, and this table restates each
    // number. A member added, removed or renumbered fails here until the table
    // changes with it.
    const expected_status = [_]struct { FiberStatus, comptime_int }{
        .{ .dead, 0 },   .{ .@"error", 1 }, .{ .debug, 2 },  .{ .pending, 3 },
        .{ .user0, 4 },  .{ .user1, 5 },    .{ .user2, 6 },  .{ .user3, 7 },
        .{ .user4, 8 },  .{ .user5, 9 },    .{ .user6, 10 }, .{ .user7, 11 },
        .{ .user8, 12 }, .{ .user9, 13 },   .{ .new, 14 },   .{ .alive, 15 },
    };
    std.debug.assert(expected_status.len == @typeInfo(FiberStatus).@"enum".fields.len);
    for (expected_status) |row| std.debug.assert(@intFromEnum(row[0]) == row[1]);
    // Every `Signal` value is also a `FiberStatus` value. The claim is about
    // values rather than names: `ok` is `dead` at 0 and `yield` is `pending`
    // at 3.
    for (@typeInfo(Signal).@"enum".fields) |f| {
        var found = false;
        for (@typeInfo(FiberStatus).@"enum".fields) |g| {
            if (f.value == g.value) found = true;
        }
        std.debug.assert(found);
    }
}

comptime {
    // Each field of `GCFlags` is checked against the mask its bits form. Where
    // a bit sits is what has to be right, so the comparison is against a number
    // rather than against a second declaration.
    std.debug.assert(@sizeOf(GCFlags) == @sizeOf(i32));
    std.debug.assert(@as(u32, @bitCast(GCFlags{ .type = 0xFF })) == 0xFF);
    std.debug.assert(@as(u32, @bitCast(GCFlags{ .reachable = true })) == 0x100);
    std.debug.assert(@as(u32, @bitCast(GCFlags{ .disabled = true })) == 0x200);
    std.debug.assert(@as(u32, @bitCast(GCFlags{ .own = 0x3F })) == 0x3F0000);
}

comptime {
    // `Signal` numbers its own members, and this table restates each number. A
    // member added, removed or renumbered fails here until the table changes
    // with it. The last two assertions pin `interrupt` and `event` to the
    // values they share.
    const expected_signal = [_]struct { Signal, comptime_int }{
        .{ .ok, 0 },     .{ .@"error", 1 }, .{ .debug, 2 },  .{ .yield, 3 },
        .{ .user0, 4 },  .{ .user1, 5 },    .{ .user2, 6 },  .{ .user3, 7 },
        .{ .user4, 8 },  .{ .user5, 9 },    .{ .user6, 10 }, .{ .user7, 11 },
        .{ .user8, 12 }, .{ .user9, 13 },
    };
    std.debug.assert(expected_signal.len == @typeInfo(Signal).@"enum".fields.len);
    for (expected_signal) |row| std.debug.assert(@intFromEnum(row[0]) == row[1]);
    std.debug.assert(Signal.interrupt == .user8);
    std.debug.assert(Signal.event == .user9);
}
