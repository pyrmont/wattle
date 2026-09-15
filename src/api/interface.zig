//! The runtime a separately compiled module calls, as one table of pointers.
//!
//! `Runtime` is that table, and `rt` is the module's pointer to it.
//! `runtime/env.zig` passes `&capi.table` to `_wattle_init` at load,
//! `module.entry`'s shim stores it in `rt`, and every call an author makes
//! goes through it. The runtime exports no `janet_*` name and a module
//! declares none, so there is no name for a linker to resolve and none for a
//! second copy of the runtime to capture.
//!
//! A _crossing_ is one field of `Runtime`: a function of the runtime that a
//! module may call.
//!
//! ## One description of each crossing
//!
//! A field's type is the crossing's shape. Both compilations read that type
//! from this file, and `runtime/capi.zig`'s initializer is type-checked
//! against it by the compiler that builds the runtime, so a field that
//! disagrees with its definition does not compile.
//!
//! ## What a crossing may be
//!
//! The `comptime` block at the end asserts two rules over every field:
//!
//! - A field is a `*const fn (...) callconv(.c)`. That convention is what
//!   makes the table an ABI rather than a Zig detail. Zig's own convention is
//!   deterministic for a compiler version and target rather than documented,
//!   and the two compilations agree on it only because `module.zig` requires
//!   both to be built by the same compiler.
//!
//! - No parameter or return is a slice, an optional slice or an error union.
//!   None of the three has a guaranteed representation, so a slice crosses as
//!   a pointer and a length, and a raise crosses on `raise.zig`'s flag.
//!
//! A slice and an error union are not allowed in an `extern fn`. A function
//! pointer type is not checked that way, so the block is here.
//!
//! ## How a crossing is named
//!
//! A field's name is the crossing's name with its symbol-table prefix
//! dropped: `janet_*`, and the `zig_` that marked a name the retired header
//! never had. A field is already qualified by `rt.`, so a prefix that kept
//! these apart in one flat namespace buys nothing.
//!
//! The `new_` and `_value` marks stay. They say that a crossing does not share
//! the shape of its namesake in the retired header: `new_` where it constructs
//! and `_value` where it mutates. What a mark records is what crosses rather
//! than how wide it is, so `getboolean` is unmarked and returns a `bool`
//! where the header declared an `int`. Nothing links against these by C
//! signature, so the Zig type is free to say the true thing.
//!
//! ## The guard
//!
//! `api/fingerprint.zig` hashes this table, and the rest of what the two
//! compilations share, into one number. Both compute it from this file, the
//! module reports its own through `_wattle_mod_config`, and the loader compares
//! the two before it calls into the module at all. That comparison is what
//! decides compatibility. It is an exact match by design, so the table is free
//! to change in any way: a field nothing crosses is removed rather than kept,
//! and a shorter table is not an older one. A module built against a shorter
//! table does not load on a longer one, and append-only compatibility is not a
//! goal.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const method_type = @import("../runtime/method_type.zig");
const module = @import("../module.zig");
const repr = @import("repr");

// ==========================================================================
// Constants
// ==========================================================================

/// The table the module was loaded with.
///
/// `module.entry`'s `_wattle_init` shim writes this once, before any author
/// code runs, and everything on the author's side reads it after that. It is
/// `undefined` until then, which is not a hazard a module can meet: the shim
/// is the only way into a module, and it assigns before it calls `defs`.
///
/// The runtime's own compilation never reads this. `raise.zig` compiles into
/// both, and its `config.native_module` arm is the only code here that names
/// `rt`. Inside the runtime the other arm calls `runtime/signal.zig` and
/// `runtime/fatal.zig` by import, so this variable exists once per loaded
/// module and not at all in `libwattle`.
pub var rt: *const Runtime = undefined;

// ==========================================================================
// Aliased types
// ==========================================================================

/// A Janet value, as a field's signature spells it.
const Value = repr.Value;

// ==========================================================================
// Types
// ==========================================================================

/// The whole of what a module may call.
///
/// Every field is one crossing. The fields are in alphabetical order, and
/// nothing reads any of them by position.
///
/// The six raising crossings are what a module's `raise.zig` reaches: a signal
/// to record, a message to build, the C-raise flag to take, and an abort.
/// Inside the runtime the same six are ordinary Zig calls to
/// `runtime/signal.zig` and `runtime/fatal.zig`, and `config.native_module`
/// picks the arm.
///
/// `module.zig` is the only caller of every other field. The three views cross
/// as the `extern` structs `abi.zig` declares, and `module.zig` rebuilds a
/// slice from each. `getrange` takes the argument count as well, because an
/// absent second slot is what makes the end default. `bytes_view`,
/// `indexed_view` and `dictionary_view` read a `Value` that is not in an
/// argument slot, such as an element of a tuple; each returns `?T` in `module.zig`, and a
/// `callconv(.c)` return admits neither an optional nor a slice, so the
/// optional is the out-parameter. None of the three can raise.
///
/// `cfuns_ext` and `def` take a capability rather than an aggregate.
/// `abi.Env` and `abi.Render` are `opaque {}` over `runtime/value/tables.zig`'s
/// `Table` and `runtime/value/buffers.zig`'s `Buffer`, and
/// `runtime/capi.zig`'s definitions cast on their first line.
///
/// One marshalling field stands for each `runtime/marsh.zig` entry point, and
/// `module.zig` names them `push*` and `pull*`. An `*abi.Marshal` points at a
/// `marsh.MarshalState` and an `*abi.Unmarshal` at a `marsh.UnmarshalState`,
/// and `marsh.zig` casts back at each entry point. The runtime's own abstract
/// types call `marsh.*` directly and reach none of these. Four cannot fail and
/// so report nothing: the two flag reads, `marshal_abstract` and
/// `unmarshal_remaining`.
///
/// Every constructing field takes a `Value` or returns a `Value`, and none
/// takes a pointer to an aggregate. Upstream's constructors return the
/// unwrapped heap type, an interned string or an array's pointer, and wrapping
/// it is a second call; returning the `Value` is one crossing rather than two
/// and puts no heap pointer on the author's side. The bytes, the items and the
/// pairs cross as a pointer and a length, and `module.zig` is where the slice
/// is taken apart.
///
/// `get`, `put` and `length` are Janet's own, over any value, so a module
/// needs no switch per collection. `get` cannot fail on a type, because
/// Janet's `get` returns nil for anything with no indexed access, but it can
/// raise from an abstract type's `get` callback. `array_push_value` and
/// `buffer_push_value` are the two appends, which `get` and `put` have no
/// spelling for: `put` writes at an index and these extend.
///
/// `call_value` and `pcall_value` are the runtime's two call shapes.
/// `runtime/vm/entry.zig`'s `call` runs a callee on the current fiber and
/// raises on anything but a return; its `pcall` runs a callee on a fresh fiber
/// and reports the signal, the value and the fiber. `call_value` flattens a
/// raise into a report like every other raising crossing, and takes a
/// function or a cfunction; `pcall_value` takes a function. `mcall` looks a
/// method up by name in the first argument and calls it with every argument. `pcall_value`
/// reports by its own nature and needs no report of its own: the signal is its
/// result, and its two out-parameters are there because a `callconv(.c)`
/// return cannot take a struct of a `Value` and an enum without an `extern`
/// layout. `gcroot` and `gcunroot` are the only rooting that crosses, and are
/// what a module holding a value across either call needs. `gclock` and
/// `gcunlock` do not cross.
///
/// The event loop is one sentence: when something happens, a fiber is resumed
/// with a value. A module brings its own source of the something, its own
/// thread or its own library's poll, and three operations join it to the loop:
/// suspend, knock and wake. `await` is the suspend and needs no field.
/// `post` is the knock and `wake` is the wake, and `current_loop` and
/// `root_fiber_value` are what a cfunction saves before it suspends. All four
/// are filled in every build, because `runtime/capi.zig`'s `loop_ops` has a
/// `-Dev=false` arm, so a build without the loop raises at `current_loop`
/// rather than reaching a null pointer. `post` is the one crossing callable
/// from a thread with no VM, and the only one that does not check that its
/// caller is running Janet; it reads no thread-local, because
/// `runtime/ev.zig`'s `evPostEvent` takes the target VM explicitly and an
/// `*abi.Loop` is that pointer. `GenericMessage`, which the runtime moves the
/// callback and the
/// context in, does not cross.
pub const Runtime = extern struct {
    abstract: *const fn (at: *const abi.AbstractType, size: usize) callconv(.c) ?*anyopaque,
    arity: *const fn (argc: i32, min: i32, max: i32) callconv(.c) void,
    array_push_value: *const fn (v: Value, x: Value) callconv(.c) void,
    /// Appends to the buffer an `*abi.Render` stands for, which is the whole
    /// of what an author may do with a render. The pointer and the length are
    /// the slice `runtime/value/buffers.zig`'s `pushBytes` takes.
    buffer_push_bytes: *const fn (render: *abi.Render, bytes: [*]const u8, len: usize) callconv(.c) void,
    buffer_push_value: *const fn (v: Value, bytes: [*]const u8, len: usize) callconv(.c) void,
    bytes_view: *const fn (x: Value, out: *abi.ByteView) callconv(.c) bool,
    c_raise_record: *const fn () callconv(.c) void,
    c_raise_take: *const fn () callconv(.c) c_int,
    call_value: *const fn (f: Value, args: [*]const Value, len: usize) callconv(.c) Value,
    calloc: *const fn (n: usize, size: usize) callconv(.c) ?*anyopaque,
    cfuns_ext: *const fn (env: ?*abi.Env, prefix: ?[*:0]const u8, table: [*]const abi.Reg) callconv(.c) void,
    checkint: *const fn (x: Value) callconv(.c) c_int,
    cstring: *const fn (str: [*:0]const u8) callconv(.c) [*:0]const u8,
    /// The loop this cfunction is running on. Raises where the build has none.
    current_loop: *const fn () callconv(.c) *abi.Loop,
    def: *const fn (env: *abi.Env, name: [*:0]const u8, val: Value, doc: ?[*:0]const u8) callconv(.c) void,
    dictionary_view: *const fn (x: Value, out: *abi.DictView) callconv(.c) bool,
    fatal: *const fn (message: [*:0]const u8) callconv(.c) noreturn,
    fiber_status_value: *const fn (fiber: Value) callconv(.c) abi.FiberStatus,
    fixarity: *const fn (argc: i32, fix: i32) callconv(.c) void,
    free: *const fn (p: ?*anyopaque) callconv(.c) void,
    gcroot: *const fn (v: Value) callconv(.c) void,
    gcunroot: *const fn (v: Value) callconv(.c) bool,
    get: *const fn (ds: Value, key: Value) callconv(.c) Value,
    getabstract: *const fn (argv: [*]const Value, n: i32, at: *const abi.AbstractType) callconv(.c) ?*anyopaque,
    getboolean: *const fn (argv: [*]const Value, n: i32) callconv(.c) bool,
    getbytes: *const fn (argv: [*]const Value, n: i32) callconv(.c) abi.ByteView,
    getdictionary: *const fn (argv: [*]const Value, n: i32) callconv(.c) abi.DictView,
    getindexed: *const fn (argv: [*]const Value, n: i32) callconv(.c) abi.IndexedView,
    getinteger: *const fn (argv: [*]const Value, n: i32) callconv(.c) i32,
    /// Takes `method_type.CMethod` rather than `module.Method`. The two share
    /// one layout and differ only in the declared type of `cfun`. This field
    /// declares the C form because a table field is a crossing, and
    /// `runtime/method_type.zig` asserts that the two layouts match.
    getmethod: *const fn (method: [*:0]const u8, methods: [*]const method_type.CMethod, out: *Value) callconv(.c) c_int,
    getnumber: *const fn (argv: [*]const Value, n: i32) callconv(.c) f64,
    getrange: *const fn (argv: [*]const Value, argc: i32, n: i32, length: i32) callconv(.c) abi.Range,
    getsize: *const fn (argv: [*]const Value, n: i32) callconv(.c) usize,
    getuinteger: *const fn (argv: [*]const Value, n: i32) callconv(.c) u32,
    indexed_view: *const fn (x: Value, out: *abi.IndexedView) callconv(.c) bool,
    length: *const fn (x: Value) callconv(.c) i32,
    mark: *const fn (x: Value) callconv(.c) void,
    marshal_abstract: *const fn (m: *abi.Marshal, p: ?*anyopaque) callconv(.c) void,
    marshal_byte: *const fn (m: *abi.Marshal, b: u8) callconv(.c) void,
    marshal_bytes: *const fn (m: *abi.Marshal, bytes: [*]const u8, len: usize) callconv(.c) void,
    marshal_flags: *const fn (m: *abi.Marshal) callconv(.c) c_int,
    marshal_int: *const fn (m: *abi.Marshal, x: i32) callconv(.c) void,
    marshal_int64: *const fn (m: *abi.Marshal, x: i64) callconv(.c) void,
    marshal_janet: *const fn (m: *abi.Marshal, x: Value) callconv(.c) void,
    marshal_ptr: *const fn (m: *abi.Marshal, p: ?*const anyopaque) callconv(.c) void,
    marshal_size: *const fn (m: *abi.Marshal, n: usize) callconv(.c) void,
    mcall: *const fn (name: [*:0]const u8, args: [*]const Value, len: usize) callconv(.c) Value,
    new_array: *const fn (items: [*]const Value, len: usize) callconv(.c) Value,
    new_buffer: *const fn (bytes: [*]const u8, len: usize) callconv(.c) Value,
    new_keyword: *const fn (bytes: [*]const u8, len: usize) callconv(.c) Value,
    new_string: *const fn (bytes: [*]const u8, len: usize) callconv(.c) Value,
    new_struct: *const fn (kvs: [*]const abi.KV, len: usize) callconv(.c) Value,
    new_symbol: *const fn (bytes: [*]const u8, len: usize) callconv(.c) Value,
    new_table: *const fn (kvs: [*]const abi.KV, len: usize) callconv(.c) Value,
    new_tuple: *const fn (items: [*]const Value, len: usize) callconv(.c) Value,
    nextmethod: *const fn (methods: [*]const method_type.CMethod, key: Value) callconv(.c) Value,
    pcall_value: *const fn (
        f: Value,
        args: [*]const Value,
        len: usize,
        out_value: *Value,
        out_fiber: *Value,
    ) callconv(.c) abi.Signal,
    /// Queues `cb(wake, ctx)` for the loop thread's next turn. Cannot raise
    /// and does not allocate.
    post: *const fn (l: *abi.Loop, cb: module.PostCallback, ctx: *anyopaque) callconv(.c) void,
    put: *const fn (ds: Value, key: Value, val: Value) callconv(.c) void,
    /// Records an abstract type under its name, so the unmarshaller can find
    /// it again. It raises when the name is already taken by a different type,
    /// because a marshalled abstract includes its type's name and one name
    /// resolving to two types would make the stream ambiguous.
    register_abstract_type: *const fn (at: *const abi.AbstractType) callconv(.c) void,
    /// The fiber `await` suspends and `wake` puts back. Raises where there is
    /// none, which is a program not running under the loop at all.
    root_fiber_value: *const fn () callconv(.c) Value,
    signal_record: *const fn (sig: c_uint, message: Value) callconv(.c) void,
    unmarshal_abstract: *const fn (u: *abi.Unmarshal, size: usize) callconv(.c) ?*anyopaque,
    unmarshal_abstract_reuse: *const fn (u: *abi.Unmarshal, p: ?*anyopaque) callconv(.c) void,
    unmarshal_byte: *const fn (u: *abi.Unmarshal) callconv(.c) u8,
    unmarshal_bytes: *const fn (u: *abi.Unmarshal, dest: [*]u8, len: usize) callconv(.c) void,
    unmarshal_ensure: *const fn (u: *abi.Unmarshal, size: usize) callconv(.c) void,
    unmarshal_flags: *const fn (u: *abi.Unmarshal) callconv(.c) c_int,
    unmarshal_int: *const fn (u: *abi.Unmarshal) callconv(.c) i32,
    unmarshal_int64: *const fn (u: *abi.Unmarshal) callconv(.c) i64,
    unmarshal_janet: *const fn (u: *abi.Unmarshal) callconv(.c) Value,
    unmarshal_ptr: *const fn (u: *abi.Unmarshal) callconv(.c) ?*anyopaque,
    unmarshal_remaining: *const fn (u: *abi.Unmarshal) callconv(.c) usize,
    unmarshal_size: *const fn (u: *abi.Unmarshal) callconv(.c) usize,
    unwrap_integer: *const fn (x: Value) callconv(.c) i32,
    unwrap_pointer: *const fn (x: Value) callconv(.c) ?*anyopaque,
    /// Puts `fiber` back on the run queue with `value`, and returns whether it
    /// took. Cannot raise: the callback it runs inside has no scope above it.
    wake: *const fn (w: *abi.Wake, fiber: Value, value: Value) callconv(.c) bool,
    wrap_abstract: *const fn (p: ?*anyopaque) callconv(.c) Value,
    wrap_pointer: *const fn (p: ?*anyopaque) callconv(.c) Value,
    wrap_string: *const fn (x: [*:0]const u8) callconv(.c) Value,
};

// ==========================================================================
// Private functions
// ==========================================================================

/// Checks that `T` may appear in a field's signature.
///
/// `name` is the field's name, which opens the message, and `T` is one of its
/// parameter types or its return type. A slice, an optional slice or an error
/// union is a compile error. An optional is checked through to its child.
fn assertCrossable(comptime name: []const u8, comptime T: type) void {
    switch (@typeInfo(T)) {
        .pointer => |p| if (p.size == .slice) @compileError(
            "`" ++ name ++ "` has the slice `" ++ @typeName(T) ++ "`, which has no ABI",
        ),
        .optional => |o| assertCrossable(name, o.child),
        .error_union => @compileError(
            "`" ++ name ++ "` has the error union `" ++ @typeName(T) ++
                "`; a raise crosses on `raise.zig`'s flag instead",
        ),
        else => {},
    }
}

// ==========================================================================
// Tests
// ==========================================================================

comptime {
    // Twice the walk's need, which is an iteration per field, per parameter
    // and per byte of field name `std.mem.eql` compares: under 1200 for the
    // table as it stands, and the room above that is for the table to grow.
    @setEvalBranchQuota(2400);

    // Every field of `Runtime` is a C-ABI function pointer over types that
    // cross. A slice and an error union have no guaranteed representation, so
    // either one in a field's signature is a shape the two compilations would
    // agree on only by accident. Both are compile errors in an `extern fn`,
    // and a function pointer type is not checked that way.
    for (@typeInfo(Runtime).@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, "size")) {
            if (field.type != usize) @compileError("`size` must be a `usize`");
            continue;
        }
        const p = switch (@typeInfo(field.type)) {
            .pointer => |p| p,
            else => @compileError("`" ++ field.name ++ "` is not a function pointer"),
        };
        if (p.size != .one or !p.is_const) @compileError(
            "`" ++ field.name ++ "` must be a `*const fn (...)`",
        );
        const f = switch (@typeInfo(p.child)) {
            .@"fn" => |f| f,
            else => @compileError("`" ++ field.name ++ "` does not point at a function"),
        };
        if (!std.meta.eql(f.calling_convention, std.builtin.CallingConvention.c)) @compileError(
            "`" ++ field.name ++ "` is not `callconv(.c)`",
        );
        assertCrossable(field.name, f.return_type orelse
            @compileError("`" ++ field.name ++ "` has a generic return"));
        for (f.params) |param| {
            assertCrossable(field.name, param.type orelse
                @compileError("`" ++ field.name ++ "` has a generic parameter"));
        }
    }
}
