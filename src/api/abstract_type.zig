//! The machinery behind an abstract type: how a `define` literal becomes the
//! vtable the runtime dispatches through.
//!
//! A module author reads `module.zig`, which declares `Spec` and `define` and
//! documents the fifteen callbacks. This file is what those two are built
//! from, and it re-exports both under the names the runtime's own code uses,
//! so `module.define` and the files under `src/runtime/` declare an abstract
//! type through the same code.
//!
//! ## From a declaration to a vtable
//!
//! A _slot_ is one callback of an abstract type, named by the field an author
//! writes in the `define` literal. `slots` lists the fifteen in the order the
//! vtable stores them. `define` runs three steps over the literal: `check`
//! rejects a field that names no slot and a callback of the wrong shape,
//! `collect` moves the fields into a `Spec(T)`, and `Erased` generates the
//! vtable stored in the result.
//!
//! A stored slot takes the payload as `*anyopaque`, because the runtime
//! dispatches without the payload's type. `Erased` is the one place that
//! pointer is cast back to `*T`, from the type given to `define`, so a
//! callback writes no cast of its own. A dispatch begins in the runtime with
//! `ofAbstract`, which reads a live abstract's header for its `AbstractType`.
//! There is one description of an abstract type, so nothing converts between
//! the runtime's and a module's.
//!
//! ## The compile errors
//!
//! `check` and `checkSlot` build what an author sees for a wrong `define`
//! literal. Two rules hold over them:
//!
//! - A shape a check does not recognise is left alone and reaches the
//!   coercion in `define`. A check can improve a message and cannot hide one.
//!
//! - A message and its phrase in `build.zig` change together. The
//!   `module-errors` step compiles a fixture under `test/module-errors/` and
//!   matches the message's tail as written, so an edit to one alone fails the
//!   step.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const module = @import("../module.zig");
const raise = @import("raise.zig");
const repr = @import("repr");

// ==========================================================================
// Constants
// ==========================================================================

/// Declares an abstract type whose payload is `T`. This is `module.define`,
/// under the name the runtime's own code uses, and what `spec` may contain and
/// where the result is declared are documented there.
pub const define = module.define;

/// The fifteen callback names, in the order the erased vtable stores them.
/// `collect` walks this list, and `check` names it when a field matches no
/// slot.
pub const slots = [_][:0]const u8{
    "gc",
    "gcmark",
    "gcperthread",
    "get",
    "put",
    "next",
    "length",
    "call",
    "compare",
    "hash",
    "tostring",
    "bytes",
    "marshal",
    "unmarshal",
    "chunk",
};

// ==========================================================================
// Aliased types
// ==========================================================================

/// The description the runtime dispatches an abstract through. `define`
/// returns an `AbstractType` and `ofAbstract` returns a pointer to the
/// `AbstractType` with which a live abstract was made.
pub const AbstractType = abi.AbstractType;

/// What a `chunk` callback returns: a run of elements and the index of its
/// first. This is `module.Chunk`, under the name the runtime's own code uses.
pub const Chunk = module.Chunk;

/// The callbacks an abstract type is declared with, over `*T`. This is
/// `module.Spec`, under the name the runtime's own code uses, and the shapes
/// and the restrictions on the garbage collector's callbacks are documented
/// there.
pub const Spec = module.Spec;

// ==========================================================================
// Types
// ==========================================================================

/// The erased vtable `define` stores, generated from one `Spec(T)`.
///
/// `T` is the payload type and `spec` is the collected callbacks over `*T`.
/// The returned type has one `pub` function per slot, in the order `slots`
/// names them. Each takes the payload as `*anyopaque`, which is the shape the
/// runtime stores, casts it back to `*T` or `*const T`, and calls the callback
/// in `spec`.
///
/// That cast is written here and nowhere else, generated from the type given
/// to `define`, so an author writes no cast in a callback.
pub fn Erased(comptime T: type, comptime spec: Spec(T)) type {
    return struct {
        inline fn mut(p: *anyopaque) *T {
            return @ptrCast(@alignCast(p));
        }
        inline fn ro(p: *anyopaque) *const T {
            return @ptrCast(@alignCast(p));
        }

        // The erased slots.

        pub fn gc(p: *anyopaque, len: usize) callconv(.c) void {
            return spec.gc.?(mut(p), len);
        }
        pub fn gcmark(p: *anyopaque, len: usize) callconv(.c) void {
            return spec.gcmark.?(mut(p), len);
        }
        pub fn gcperthread(p: *anyopaque, len: usize) callconv(.c) void {
            return spec.gcperthread.?(mut(p), len);
        }
        pub fn get(p: *anyopaque, key: repr.Value) raise.Error!?repr.Value {
            return spec.get.?(mut(p), key);
        }
        pub fn put(p: *anyopaque, key: repr.Value, value: repr.Value) raise.Error!void {
            return spec.put.?(mut(p), key, value);
        }
        pub fn next(p: *anyopaque, key: repr.Value) raise.Error!repr.Value {
            return spec.next.?(mut(p), key);
        }
        pub fn length(p: *anyopaque, len: usize) raise.Error!usize {
            return spec.length.?(mut(p), len);
        }
        /// Rebuilds the argument slice from the pointer and count the
        /// interpreter dispatches with.
        ///
        /// This is the one slot whose shape changes on the way through. A
        /// module author writes `call` over a `[]Value`, as a cfunction is
        /// written.
        pub fn call(p: *anyopaque, argc: i32, argv: [*]repr.Value) raise.Error!repr.Value {
            return spec.call.?(mut(p), argv[0..@intCast(argc)]);
        }
        pub fn compare(lhs: *anyopaque, rhs: *anyopaque) callconv(.c) i32 {
            return spec.compare.?(ro(lhs), ro(rhs));
        }
        pub fn hash(p: *anyopaque, len: usize) callconv(.c) i32 {
            return spec.hash.?(ro(p), len);
        }
        pub fn tostring(p: *anyopaque, render: *abi.Render) raise.Error!void {
            return spec.tostring.?(mut(p), render);
        }
        pub fn bytes(p: *anyopaque, len: usize) callconv(.c) abi.ByteView {
            const b = spec.bytes.?(ro(p), len);
            return .{ .bytes = b.ptr, .len = b.len };
        }
        pub fn marshal(p: *anyopaque, m: *abi.Marshal) raise.Error!void {
            return spec.marshal.?(mut(p), m);
        }
        pub fn unmarshal(u: *abi.Unmarshal) raise.Error!?*anyopaque {
            return try spec.unmarshal.?(u);
        }
        pub fn chunk(p: *anyopaque, index: usize) callconv(.c) abi.Chunk {
            const c = spec.chunk.?(mut(p), index);
            return .{ .items = c.items.ptr, .len = c.items.len, .start = c.start };
        }
    };
}

// ==========================================================================
// Public functions
// ==========================================================================

/// Checks a `define` literal against the slots of an abstract type.
///
/// `T` is the payload type and `spec` is the literal an author wrote.
///
/// It is a compile error if `spec` is not a struct, if a field names no slot,
/// if a callback returns an error union where its slot cannot raise or omits
/// one where its slot may, if a callback's first parameter is not `*T` or
/// `*const T`, if `chunk` is given without `length`, or if `chunk` is given
/// without a `contents` or a `contents` without `chunk`. The parameter check
/// skips `unmarshal`, which takes no payload.
///
/// A shape this does not recognise is left alone and reaches the coercion in
/// `define`, so `check` can improve a message but cannot suppress an error.
pub fn check(comptime T: type, comptime spec: anytype) void {
    const Given = @TypeOf(spec);
    const info = @typeInfo(Given);
    if (info != .@"struct") {
        @compileError("define takes a struct literal of callbacks, not " ++
            @typeName(Given));
    }
    for (info.@"struct".fields) |f| {
        if (comptime std.mem.eql(u8, f.name, "name")) continue;
        if (comptime std.mem.eql(u8, f.name, "contents")) continue;
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
    if (sets(spec, "chunk") and !sets(spec, "length")) {
        @compileError("abstract type '" ++ spec.name ++ "', callback 'chunk': a type with " ++
            "`chunk` must also have `length`. The length bounds the index `chunk` is " ++
            "called with.");
    }
    const contents = comptime contentsOf(spec);
    if (sets(spec, "chunk") and contents == .none) {
        @compileError("abstract type '" ++ spec.name ++ "', callback 'chunk': a type with " ++
            "`chunk` must say what its runs hold. Set `contents` to `.elements` or `.pairs`.");
    }
    if (!sets(spec, "chunk") and contents != .none) {
        @compileError("abstract type '" ++ spec.name ++ "', field 'contents': a type whose " ++
            "contents are not `.none` must have `chunk`, which is how its contents are read.");
    }
}

/// Moves a `define` literal's fields into a `Spec(T)`, one slot at a time.
///
/// `T` is the payload type and `spec` is the literal an author wrote. A field
/// written `null` is skipped, so its slot is left at its default.
///
/// Each field is assigned on its own, which puts every callback through the
/// coercion its slot declares. That is what makes a shape a compile error if
/// `check` did not recognise it rather than a callback stored unchecked.
/// Assigning the literal whole would skip those coercions, and does not compile
/// in any case: through `anytype` it has a concrete anonymous type, which Zig
/// will not coerce to `Spec(T)`.
pub fn collect(comptime T: type, comptime spec: anytype) Spec(T) {
    comptime var cb: Spec(T) = .{ .name = spec.name, .contents = contentsOf(spec) };
    inline for (slots) |s| {
        if (@hasField(@TypeOf(spec), s)) {
            const given = @field(spec, s);
            if (@TypeOf(given) != @TypeOf(null)) @field(cb, s) = given;
        }
    }
    return cb;
}

/// Returns the abstract type of a live abstract.
///
/// `abst` is a pointer to the abstract's payload, and the result is read from
/// the header in front of it. A dispatch on an abstract starts here. This
/// function cannot raise.
///
/// Nothing checks that `abst` is an abstract's payload. Any other pointer
/// gives back whatever lies in front of it, read as a pointer to an
/// `AbstractType`. `module.toAbstract` checks a value first.
pub inline fn ofAbstract(abst: ?*anyopaque) *const AbstractType {
    return abi.abstractHead(abst).type;
}

// ==========================================================================
// Private functions
// ==========================================================================

/// Checks one field of a `define` literal against the slot it names.
///
/// `T` is the payload type, `name` is the abstract type's name, `slot` is the
/// field an author wrote and `Given` is the type of what they wrote there.
/// `name` and `slot` open the message. A callback whose raising does not match
/// its slot, or whose first parameter is not `*T` or `*const T`, is a compile
/// error.
///
/// A `Given` that is null, optional or not a function returns without an
/// error and reaches the coercion in `define`.
fn checkSlot(comptime T: type, comptime name: []const u8, comptime slot: []const u8, comptime Given: type) void {
    // A field written `.gc = null` is the default written out.
    if (Given == @TypeOf(null)) return;

    const fn_info = switch (@typeInfo(Given)) {
        .@"fn" => |fi| fi,
        .pointer => |p| switch (@typeInfo(p.child)) {
            .@"fn" => |fi| fi,
            else => return, // not a function; the coercion in `define` reports this shape
        },
        .optional => return,
        else => return,
    };

    const where = "abstract type '" ++ name ++ "', callback '" ++ slot ++ "': ";

    // Whether the callback raises must match the slot.
    const returns_error = if (fn_info.return_type) |R| @typeInfo(R) == .error_union else false;
    if (returns_error and !comptime raises(slot)) {
        @compileError(where ++ "this callback cannot raise. `gc` and `gcmark` run inside " ++
            "a collection. `compare`, `hash`, `bytes` and `gcperthread` run inside an " ++
            "operation that must produce a result. `chunk` hands out storage a reader " ++
            "holds while it reads. None of the seven has a return type to report a " ++
            "raise through.");
    }
    if (!returns_error and comptime raises(slot)) {
        @compileError(where ++ "this callback may raise, so write `raise.Error!" ++
            payloadName(T, slot) ++ "` as its return type. The slot runs inside an " ++
            "interpreter frame with a scope above it.");
    }

    // The first parameter must be the payload type.
    if (fn_info.params.len > 0 and !std.mem.eql(u8, slot, "unmarshal")) {
        if (fn_info.params[0].type) |P0| {
            const ok = P0 == *T or P0 == *const T;
            if (!ok) {
                @compileError(where ++ "the first parameter must be `*" ++ @typeName(T) ++
                    "`, the payload type given to `define`. The type given is `" ++
                    @typeName(P0) ++ "`. `define` generates the cast from the runtime's " ++
                    "erased pointer.");
            }
        }
    }
}

/// Returns the `contents` a `define` literal declares, or `none` where it
/// declares none.
///
/// `spec` is the literal an author wrote.
fn contentsOf(comptime spec: anytype) abi.Contents {
    if (!@hasField(@TypeOf(spec), "contents")) return .none;
    return spec.contents;
}

/// Returns the payload of a slot's return type, spelled as the "may raise"
/// message spells it.
///
/// `T` is the payload type and `slot` is the field an author wrote. The result
/// completes `raise.Error!` in that message, so an author reads the return
/// type to write.
fn payloadName(comptime T: type, comptime slot: []const u8) []const u8 {
    if (std.mem.eql(u8, slot, "get")) return "?Value";
    if (std.mem.eql(u8, slot, "put")) return "void";
    if (std.mem.eql(u8, slot, "marshal")) return "void";
    if (std.mem.eql(u8, slot, "unmarshal")) return "*" ++ @typeName(T);
    if (std.mem.eql(u8, slot, "tostring")) return "void";
    if (std.mem.eql(u8, slot, "next")) return "Value";
    if (std.mem.eql(u8, slot, "call")) return "Value";
    return "usize";
}

/// Returns whether a slot's callback may raise.
///
/// `slot` is the field an author wrote. The eight that may raise are `get`,
/// `put`, `next`, `length`, `call`, `tostring`, `marshal` and `unmarshal`. The
/// other seven return no error union. `checkSlot` compares this against the
/// callback an author gave.
fn raises(comptime slot: []const u8) bool {
    const yes = [_][]const u8{ "get", "put", "marshal", "unmarshal", "tostring", "next", "call", "length" };
    for (yes) |y| {
        if (std.mem.eql(u8, slot, y)) return true;
    }
    return false;
}

/// Returns whether a `define` literal sets a slot to something other than null.
///
/// `spec` is the literal an author wrote and `slot` is the field to look for.
/// A field written `null` counts as not given, as `collect` treats it.
fn sets(comptime spec: anytype, comptime slot: []const u8) bool {
    if (!@hasField(@TypeOf(spec), slot)) return false;
    return @TypeOf(@field(spec, slot)) != @TypeOf(null);
}

/// Returns the slot names as one comma-separated string.
///
/// `check` puts the result in the message for a field that names no slot.
fn slotList() []const u8 {
    comptime var out: []const u8 = "";
    inline for (slots, 0..) |s, i| {
        out = out ++ (if (i == 0) "" else ", ") ++ s;
    }
    return out;
}
