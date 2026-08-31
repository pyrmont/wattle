//! The abstract-type interface: what an abstract type is, and how a module
//! author declares one.
//!
//! The description itself is `types.AbstractType` -- see its comment for why
//! it is declared there and not here. This file owns the *interface*: the
//! payload contract, the callback shapes, and the dispatch helper the runtime
//! reaches an object's type through.
//!
//! ## One description
//!
//! Eight of this table's callbacks can raise, and they are typed as raising.
//! That was impossible while a C signature fixed the same table: a C signature
//! has no error channel, so the two descriptions had to be kept agreeing field
//! for field and bridged by `@ptrCast`. Every callback is pointer-sized, so a
//! field inserted into one and removed from the other would have left
//! `@sizeOf` unmoved and every later slot reading as its neighbour -- a
//! comptime walk over both field lists is what kept that from happening.
//!
//! There is one description now, and `ofAbstract` below is the only survivor
//! of the three helpers that bridged them. It is not a cast between
//! descriptions but a read of a live object's header.
//!
//! ## The six that cannot raise, and why `gc` and `gcmark` are among them
//!
//! `compare`, `hash`, `bytes` and `gcperthread` cannot raise in any
//! implementation in the tree, and none of them is reached from a path that
//! could grow one: `compare` and `hash` are called from `value/helpers/order.zig`
//! inside comparisons that must be total.
//!
//! **`gc` and `gcmark` are in that group by contract rather than by
//! measurement.** Typing all ten raising callbacks alike would leave three
//! sites the collector could do nothing with. The reason is not that the tree
//! happens to have no raising finalizer -- it is *when* the collector calls
//! them:
//!
//! > A finalizer runs mid-sweep on an object that is already unreachable, and
//! > `gcmark` runs mid-traversal. There is no scope above either, no caller
//! > that could act on an error, and nothing to retry.
//!
//! So a raise from one has nowhere to go **for anybody**, including a native
//! module. `FOUND.md`'s "A panicking finalizer poisons the heap and kills the
//! process at deinit" is what C's attempt to allow it costs: the block is
//! finalized but neither freed nor unlinked, every later sweep finalizes it
//! again, and `janet_deinit` eventually exits the process.
//!
//! Typing them non-raising is what turns that into a **compile error at the
//! callback's own definition**, which is the only place the diagnosis is
//! cheap. It takes nothing away: both already return `c_int`, and the
//! runtime's own call site treats a nonzero return as the failure channel.
//!
//! Measured before deciding: of the sixteen `gc` and `gcmark` implementations
//! in the tree, **fifteen never raised**, and the one that did -- `streamGC`,
//! through `closeImplHandle` to the backend's `unregister` -- was reporting a
//! failed `epoll_ctl`/`kevent` from inside the collector, where no caller
//! could have acted on it either.
//!
//! The other eight run inside an interpreter frame with a real scope above
//! them, and a module author reporting an error from one is ordinary.

const std = @import("std");
const raise = @import("raise");
const types = @import("types");
const repr = @import("repr");

/// The dispatch description, re-exported under the name this file's callers
/// use. It is one type, not a second description: `types.AbstractType` is
/// where it has to be declared and this is where it is documented.
pub const AbstractType = types.AbstractType;

/// The abstract type of a live abstract, which is where a dispatch starts.
///
/// This is a read of the object's header rather than a conversion between two
/// descriptions -- the last of the three helpers that did that.
pub inline fn ofAbstract(abst: ?*anyopaque) *const AbstractType {
    return types.abstractHead(abst).type;
}

// ==========================================================================
// Declaring one: the typed constructor
// ==========================================================================

/// What a module author writes: the callbacks, over `*T`.
///
/// `T` is the **header** type, not the whole allocation, and `len` stays.
/// Abstracts are not all fixed-size -- `janet_address_type` is allocated at
/// `socklen`, `janet_peg_type` at `total_size`, `janet_stream_type` at `size`
/// -- so the typed form removes the cast and keeps the length. A callback that
/// ignores trailing data ignores `len`; one that walks it has the same
/// information it always had. `DESIGN.md` section 5.
///
/// **`compare` takes two `*const T` and that is a strengthening, not a
/// convenience.** `value/helpers/order.zig`'s `compareAbstract` orders two
/// abstracts of *different* types by the address of their type and only calls
/// the callback when both are this type, so the second payload really is a
/// `T`. In C both parameters are `void *` and the author casts both,
/// with nothing saying the second is theirs.
///
/// The six callbacks with no `raise.Error` in their return type cannot raise,
/// and that is a contract. The head of this file has the argument.
pub fn Spec(comptime T: type) type {
    return struct {
        name: []const u8,
        gc: ?*const fn (*T, usize) c_int = null,
        gcmark: ?*const fn (*T, usize) c_int = null,
        get: ?*const fn (*T, repr.Value, *repr.Value) raise.Error!c_int = null,
        put: ?*const fn (*T, repr.Value, repr.Value) raise.Error!void = null,
        marshal: ?*const fn (*T, *types.JanetMarshalContext) raise.Error!void = null,
        unmarshal: ?*const fn (*types.JanetMarshalContext) raise.Error!*T = null,
        tostring: ?*const fn (*T, *types.JanetBuffer) raise.Error!void = null,
        compare: ?*const fn (*const T, *const T) c_int = null,
        hash: ?*const fn (*const T, usize) i32 = null,
        next: ?*const fn (*T, repr.Value) raise.Error!repr.Value = null,
        call: ?*const fn (*T, []repr.Value) raise.Error!repr.Value = null,
        length: ?*const fn (*T, usize) raise.Error!usize = null,
        bytes: ?*const fn (*const T, usize) types.JanetByteView = null,
        gcperthread: ?*const fn (*T, usize) c_int = null,
    };
}

/// The slots, in the erased vtable's order. Used by `check` to say what a
/// misspelled field could have been.
// zig fmt: off
const slots = [_][:0]const u8{
    "gc", "gcmark", "get", "put", "marshal", "unmarshal", "tostring",
    "compare", "hash", "next", "call", "length", "bytes", "gcperthread",
};
// zig fmt: on

/// The erased vtable `define` stores, generated from one `Spec(T)`.
///
/// This is where the cast lives, and it is the whole point: it is written
/// once, here, over the type the author gave `define`, in code the author does
/// not write and cannot get wrong. The C interface put it on the first line of
/// every callback instead, where nothing could check it.
fn Erased(comptime T: type, comptime spec: Spec(T)) type {
    return struct {
        /// The erased slot says `?*anyopaque` because that is the stored
        /// shape; the runtime never dispatches with a null payload, because
        /// a dispatch starts from a live abstract's header. The `.?` states
        /// that rather than letting `@ptrCast` assert it silently -- which
        /// matters, because the two differ in what a wrong caller sees.
        inline fn mut(p: ?*anyopaque) *T {
            return @ptrCast(@alignCast(p.?));
        }
        inline fn ro(p: ?*anyopaque) *const T {
            return @ptrCast(@alignCast(p.?));
        }

        fn gc(p: ?*anyopaque, len: usize) callconv(.c) c_int {
            return spec.gc.?(mut(p), len);
        }
        fn gcmark(p: ?*anyopaque, len: usize) callconv(.c) c_int {
            return spec.gcmark.?(mut(p), len);
        }
        fn get(p: ?*anyopaque, key: repr.Value, out: *repr.Value) raise.Error!c_int {
            return spec.get.?(mut(p), key, out);
        }
        fn put(p: ?*anyopaque, key: repr.Value, value: repr.Value) raise.Error!void {
            return spec.put.?(mut(p), key, value);
        }
        fn marshal(p: ?*anyopaque, ctx: *types.JanetMarshalContext) raise.Error!void {
            return spec.marshal.?(mut(p), ctx);
        }
        fn unmarshal(ctx: *types.JanetMarshalContext) raise.Error!?*anyopaque {
            return try spec.unmarshal.?(ctx);
        }
        fn tostring(p: ?*anyopaque, buffer: *types.JanetBuffer) raise.Error!void {
            return spec.tostring.?(mut(p), buffer);
        }
        fn compare(lhs: ?*anyopaque, rhs: ?*anyopaque) callconv(.c) c_int {
            return spec.compare.?(ro(lhs), ro(rhs));
        }
        fn hash(p: ?*anyopaque, len: usize) callconv(.c) i32 {
            return spec.hash.?(ro(p), len);
        }
        fn next(p: ?*anyopaque, key: repr.Value) raise.Error!repr.Value {
            return spec.next.?(mut(p), key);
        }
        /// The one slot whose shape changes on the way through: a module
        /// author takes the arguments as a slice, exactly as a cfunction does
        /// and the erased form keeps the
        /// pointer/count pair the interpreter dispatches with.
        fn call(p: ?*anyopaque, argc: i32, argv: [*]repr.Value) raise.Error!repr.Value {
            return spec.call.?(mut(p), argv[0..@intCast(argc)]);
        }
        fn length(p: ?*anyopaque, len: usize) raise.Error!usize {
            return spec.length.?(mut(p), len);
        }
        fn bytes(p: ?*anyopaque, len: usize) callconv(.c) types.JanetByteView {
            return spec.bytes.?(ro(p), len);
        }
        fn gcperthread(p: ?*anyopaque, len: usize) callconv(.c) c_int {
            return spec.gcperthread.?(mut(p), len);
        }
    };
}

/// Declare an abstract type whose payload is `T`.
///
/// ```zig
/// const num_array_type = abstract_type.define(NumArray, .{
///     .name = "numarray",
///     .gc = numArrayGc,   // fn (*NumArray, usize) c_int
///     .get = numArrayGet, // fn (*NumArray, Value, *Value) raise.Error!c_int
///     .put = numArrayPut,
/// });
/// ```
///
/// **The result must live for as long as the runtime does, so declare it at
/// container level.** This returns a value, and Zig will happily let a caller
/// bind one inside a function:
///
/// ```zig
/// fn defs(env: *janet.Env) void {
///     const t = abstract_type.define(NumArray, .{ ... }); // WRONG
///     ...
/// }
/// ```
///
/// Every abstract the runtime creates keeps the *address* of the type it was
/// given, and the collector reads that address again at teardown -- long after
/// the frame above has returned. The failure is a crash during `janet_deinit`
/// with nothing pointing back at the declaration that caused it. The example
/// above is written as a `const` at file scope for that reason, and not merely
/// as a matter of style.
///
/// Zig offers no way to require this of a returned value, so it is a rule
/// stated here rather than one the compiler holds. `examples/numarray` shows
/// the correct placement.
///
/// `spec` is `anytype` rather than `Spec(T)` so that a wrong callback can be
/// diagnosed as the mistake it is -- see `check`. Everything it does not
/// object to is then coerced to `Spec(T)`, so Zig has the last word.
pub fn define(comptime T: type, comptime spec: anytype) AbstractType {
    comptime check(T, spec);
    const cb = comptime collect(T, spec);
    const E = Erased(T, cb);
    return .{
        .name = cb.name,
        .gc = if (cb.gc != null) &E.gc else null,
        .gcmark = if (cb.gcmark != null) &E.gcmark else null,
        .get = if (cb.get != null) &E.get else null,
        .put = if (cb.put != null) &E.put else null,
        .marshal = if (cb.marshal != null) &E.marshal else null,
        .unmarshal = if (cb.unmarshal != null) &E.unmarshal else null,
        .tostring = if (cb.tostring != null) &E.tostring else null,
        .compare = if (cb.compare != null) &E.compare else null,
        .hash = if (cb.hash != null) &E.hash else null,
        .next = if (cb.next != null) &E.next else null,
        .call = if (cb.call != null) &E.call else null,
        .length = if (cb.length != null) &E.length else null,
        .bytes = if (cb.bytes != null) &E.bytes else null,
        .gcperthread = if (cb.gcperthread != null) &E.gcperthread else null,
    };
}

/// Move the literal's fields into a `Spec(T)`, one slot at a time.
///
/// A whole-struct coercion would be shorter and Zig will not do it: once
/// `spec` has arrived through `anytype` it has a concrete anonymous type, and
/// `Spec(T)` is not that type. Assigning field by field is what puts each
/// callback through the coercion its own slot declares, which is where a shape
/// `check` did not recognise still becomes an error.
fn collect(comptime T: type, comptime spec: anytype) Spec(T) {
    comptime var cb: Spec(T) = .{ .name = spec.name };
    inline for (slots) |s| {
        if (@hasField(@TypeOf(spec), s)) {
            const given = @field(spec, s);
            if (@TypeOf(given) != @TypeOf(null)) @field(cb, s) = given;
        }
    }
    return cb;
}

// ------------------------------------------------------- the compile errors

/// Reject a wrong `spec` with a message about the contract rather than about
/// the type.
///
/// `PLAN.md`'s "Target" is the reason this exists: **a decision about a
/// callback type is a decision about somebody else's compile error.** Zig's
/// own coercion failure names two function types and leaves the author to
/// diff them, and for the two mistakes an author actually makes -- the wrong
/// payload, and a `gc` that raises -- the diff is not the point. The reason
/// is.
///
/// Anything this does not recognise falls through to the coercion in `define`,
/// so the check can only make a message better, never hide one.
fn check(comptime T: type, comptime spec: anytype) void {
    const Given = @TypeOf(spec);
    const info = @typeInfo(Given);
    if (info != .@"struct") {
        @compileError("abstract_type.define takes a struct literal of callbacks, not " ++
            @typeName(Given));
    }
    for (info.@"struct".fields) |f| {
        if (comptime std.mem.eql(u8, f.name, "name")) continue;
        comptime var known = false;
        inline for (slots) |s| {
            if (comptime std.mem.eql(u8, f.name, s)) known = true;
        }
        if (!known) {
            @compileError("abstract type '" ++ spec.name ++ "' has no callback named '" ++
                f.name ++ "'. The callbacks are: " ++ slotList());
        }
        checkSlot(T, spec.name, f.name, @TypeOf(@field(spec, f.name)));
    }
}

fn slotList() []const u8 {
    comptime var out: []const u8 = "";
    inline for (slots, 0..) |s, i| {
        out = out ++ (if (i == 0) "" else ", ") ++ s;
    }
    return out;
}

/// True for the eight slots that run inside an interpreter frame with a real
/// scope above them. The other six are the contract the head of this file
/// argues for.
fn raises(comptime slot: []const u8) bool {
    const yes = [_][]const u8{ "get", "put", "marshal", "unmarshal", "tostring", "next", "call", "length" };
    for (yes) |y| {
        if (std.mem.eql(u8, slot, y)) return true;
    }
    return false;
}

fn checkSlot(comptime T: type, comptime name: []const u8, comptime slot: []const u8, comptime Given: type) void {
    // A field written `.gc = null` is the default said out loud.
    if (Given == @TypeOf(null)) return;

    const fn_info = switch (@typeInfo(Given)) {
        .@"fn" => |fi| fi,
        .pointer => |p| switch (@typeInfo(p.child)) {
            .@"fn" => |fi| fi,
            else => return, // not a function at all; let the coercion say so
        },
        .optional => return,
        else => return,
    };

    const where = "abstract type '" ++ name ++ "', callback '" ++ slot ++ "': ";

    // The raising contract, which is the message that carries a reason.
    const returns_error = if (fn_info.return_type) |R| @typeInfo(R) == .error_union else false;
    if (returns_error and !comptime raises(slot)) {
        @compileError(where ++ "this callback cannot raise, and that is a contract rather " ++
            "than an oversight. `gc` and `gcmark` run inside the collector -- a finalizer " ++
            "on an object that is already unreachable, a mark mid-traversal -- and " ++
            "`compare`, `hash`, `bytes` and `gcperthread` run inside operations that must " ++
            "be total. There is no scope above any of them and nothing to retry, so a " ++
            "raise would have nowhere to go. Report failure with the return value instead.");
    }
    if (!returns_error and comptime raises(slot)) {
        @compileError(where ++ "this callback may raise and its return type must say so: " ++
            "write `raise.Error!" ++ payloadName(T, slot) ++ "`. It runs inside an " ++
            "interpreter frame with a real scope above it.");
    }

    // The payload, which is the other mistake worth naming.
    if (fn_info.params.len > 0 and !std.mem.eql(u8, slot, "unmarshal")) {
        if (fn_info.params[0].type) |P0| {
            const ok = P0 == *T or P0 == *const T;
            if (!ok) {
                @compileError(where ++ "the first parameter must be `*" ++ @typeName(T) ++
                    "`, the payload type given to `define` -- it is `" ++ @typeName(P0) ++
                    "`. `define` generates the cast from the runtime's erased pointer, so " ++
                    "the callback never writes one.");
            }
        }
    }
}

/// The return payload named in the "may raise" message, so it reads as the
/// signature the author should write rather than as a lecture.
fn payloadName(comptime T: type, comptime slot: []const u8) []const u8 {
    if (std.mem.eql(u8, slot, "get")) return "c_int";
    if (std.mem.eql(u8, slot, "put")) return "void";
    if (std.mem.eql(u8, slot, "marshal")) return "void";
    if (std.mem.eql(u8, slot, "unmarshal")) return "*" ++ @typeName(T);
    if (std.mem.eql(u8, slot, "tostring")) return "void";
    if (std.mem.eql(u8, slot, "next")) return "Value";
    if (std.mem.eql(u8, slot, "call")) return "Value";
    return "usize";
}
