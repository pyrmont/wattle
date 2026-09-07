//! Wrap: a `Value` out of something, and something out of a `Value`.
//!
//! The names go by direction rather than by verb: `wrap.fromTable(t)` and
//! `wrap.toTable(v)`, in two columns. `fromNil()` has nothing to be from and is
//! kept anyway, so that a reader scanning the `from*` column does not have to
//! notice the one that is not there. The four inspection names are `repr`'s:
//! they convert nothing.
//!
//! The representation is not here. Which of the three layouts a build compiles,
//! what each looks like, and why the nanbox-32 arm is written and not executed
//! are all `api/repr.zig`'s. This file converts to and from a `Value`; it does
//! not decide what one is. Neither is the empty-memory allocation:
//! `memallocEmpty` and `memempty` are in `value.zig` with their two dictionary
//! callers. Nothing here raises.
//!
//! Type punning is the subject rather than an accident. Every function here
//! writes one member of a union and reads another, which is defined for an
//! `extern union`, so nothing here needs a `@bitCast`.
//!
//! `fromNumberSafe` canonicalises a NaN under either NaN-boxed layout and not
//! under the tagged one, where a signalling NaN's payload survives into the
//! value. That asymmetry is what a program sees, and it is harmless, because
//! the tagged layout does not use the NaN space.
//!
//! `toInteger` saturates and is defined for every double. Converting an
//! out-of-range double or a NaN to an `i32` has no portable result, since
//! aarch64's `fcvtzs` saturates where x86-64's `cvttsd2si` gives `INT32_MIN`,
//! and `@intFromFloat` is illegal behaviour outside the destination range, so
//! it tests before converting and saturates on either target.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abstracts = @import("../abstracts.zig");
const arrays = @import("../arrays.zig");
/// `boundary` rather than `abi`: this file declares a `pub const abi` for the
/// `callconv(.c)` shims, and the two names would collide.
const boundary = @import("abi");
const buffers = @import("../buffers.zig");
const fibers = @import("../fibers.zig");
const functions = @import("../functions.zig");
const repr = @import("repr");
const strings = @import("../strings.zig");
const structs = @import("../structs.zig");
const tables = @import("../tables.zig");
const tuples = @import("../tuples.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// The file's own struct, so that `abi` can name the declarations it shadows.
///
/// A struct member does not shadow a container declaration, but it does make
/// the unqualified name ambiguous: without this, `abi.fromNil` would resolve to
/// itself.
const outer = @This();

// ==========================================================================
// Types
// ==========================================================================

/// The out-of-line bodies for the wraps.
///
/// A table field takes an address and an `inline fn` has none, so each of these
/// gives `runtime/capi.zig`'s initializer something to point at and does
/// nothing else. A Zig caller takes the `inline` spelling instead; nothing but
/// `capi.zig` should name this struct.
///
/// Five declare `callconv(.c)` and the rest do not, and those five are exactly
/// the ones `capi.zig` puts in the table: `fromNil`, `fromNumber`,
/// `fromString`, `fromAbstract` and `fromPointer` fill `wrap_nil`,
/// `wrap_number`, `wrap_string`, `wrap_abstract` and `wrap_pointer`. A
/// convention on the others would be an ABI nothing crosses, and
/// `tools/check/callconv.janet` is the check that says so. They stay `pub`
/// because `test/value_wrap.zig` asserts each against the inline spelling
/// beside it.
///
/// The bodies say `outer.` because a struct member does not shadow a container
/// declaration but does make the unqualified name ambiguous.
pub const abi = struct {
    pub fn fromNil() callconv(.c) repr.Value {
        return outer.fromNil();
    }

    pub fn fromBoolean(b: c_int) repr.Value {
        return outer.fromBoolean(b != 0);
    }

    pub fn fromTrue() repr.Value {
        return outer.fromTrue();
    }

    pub fn fromFalse() repr.Value {
        return outer.fromFalse();
    }

    pub fn fromInteger(x: i32) repr.Value {
        return outer.fromInteger(x);
    }

    pub fn fromNumber(x: f64) callconv(.c) repr.Value {
        return outer.fromNumber(x);
    }

    pub fn fromString(x: strings.String) callconv(.c) repr.Value {
        return outer.fromString(x);
    }

    pub fn fromSymbol(x: strings.Symbol) repr.Value {
        return outer.fromSymbol(x);
    }

    pub fn fromKeyword(x: strings.Keyword) repr.Value {
        return outer.fromKeyword(x);
    }

    pub fn fromArray(x: *arrays.Array) repr.Value {
        return outer.fromArray(x);
    }

    pub fn fromTuple(x: tuples.Tuple) repr.Value {
        return outer.fromTuple(x);
    }

    pub fn fromStruct(x: structs.Struct) repr.Value {
        return outer.fromStruct(x);
    }

    pub fn fromFiber(x: ?*fibers.Fiber) repr.Value {
        return outer.fromFiber(x);
    }

    pub fn fromBuffer(x: *buffers.Buffer) repr.Value {
        return outer.fromBuffer(x);
    }

    pub fn fromFunction(x: *functions.Function) repr.Value {
        return outer.fromFunction(x);
    }

    pub fn fromCfunction(x: boundary.CFunction) repr.Value {
        return outer.fromCfunction(x);
    }

    pub fn fromTable(x: *tables.Table) repr.Value {
        return outer.fromTable(x);
    }

    pub fn fromAbstract(x: abstracts.Abstract) callconv(.c) repr.Value {
        return outer.fromAbstract(x);
    }

    pub fn fromPointer(x: ?*anyopaque) callconv(.c) repr.Value {
        return outer.fromPointer(x);
    }
};

// ==========================================================================
// Public functions
// ==========================================================================

/// The wraps: a `Value` out of each Janet type.
///
/// Each is `pub inline fn`, so a caller pays no call for what is a macro under
/// both NaN-boxed layouts. The out-of-line bodies the runtime table points at
/// are in `abi` above.
///
/// `fromNumberSafe` is the one that does more than tag: it canonicalises a NaN
/// first under either NaN-boxed layout, for the reason the file header gives.
pub inline fn fromAbstract(x: abstracts.Abstract) repr.Value {
    return repr.wrapPointer(x, repr.Tag.abstract);
}

pub inline fn fromArray(x: *arrays.Array) repr.Value {
    return repr.wrapPointer(x, repr.Tag.array);
}

pub inline fn fromBoolean(b: bool) repr.Value {
    return repr.wrapBoolean(b);
}

pub inline fn fromBuffer(x: *buffers.Buffer) repr.Value {
    return repr.wrapPointer(x, repr.Tag.buffer);
}

pub inline fn fromCfunction(x: boundary.CFunction) repr.Value {
    return repr.wrapPointer(@ptrCast(@constCast(x)), repr.Tag.cfunction);
}

pub inline fn fromFalse() repr.Value {
    return fromBoolean(false);
}

pub inline fn fromFiber(x: ?*fibers.Fiber) repr.Value {
    return repr.wrapPointer(x, repr.Tag.fiber);
}

pub inline fn fromFunction(x: *functions.Function) repr.Value {
    return repr.wrapPointer(x, repr.Tag.function);
}

pub inline fn fromInteger(x: i32) repr.Value {
    return repr.wrapNumber(@floatFromInt(x));
}

pub inline fn fromKeyword(x: strings.Keyword) repr.Value {
    return repr.wrapCPointer(x, repr.Tag.keyword);
}

pub inline fn fromNil() repr.Value {
    return repr.wrapNil();
}

pub inline fn fromNumber(x: f64) repr.Value {
    return repr.wrapNumber(x);
}

pub fn fromNumberSafe(d: f64) repr.Value {
    return repr.wrapNumberSafe(d);
}

pub inline fn fromPointer(x: ?*anyopaque) repr.Value {
    return repr.wrapPointer(x, repr.Tag.pointer);
}

pub inline fn fromString(x: strings.String) repr.Value {
    return repr.wrapCPointer(x, repr.Tag.string);
}

pub inline fn fromStruct(x: structs.Struct) repr.Value {
    return repr.wrapCPointer(x, repr.Tag.@"struct");
}

pub inline fn fromSymbol(x: strings.Symbol) repr.Value {
    return repr.wrapCPointer(x, repr.Tag.symbol);
}

pub inline fn fromTable(x: *tables.Table) repr.Value {
    return repr.wrapPointer(x, repr.Tag.table);
}

pub inline fn fromTrue() repr.Value {
    return fromBoolean(true);
}

pub inline fn fromTuple(x: tuples.Tuple) repr.Value {
    return repr.wrapCPointer(x, repr.Tag.tuple);
}

/// The per-layout helpers, each one layout's own.
///
/// A build analyses only its own arm: a body naming `x.tagged` must not be
/// reached in a build where a value has no such field. These are the one caller
/// that needs a named arm rather than the selected one.
pub fn nanbox32FromTagI(t: u32, integer: i32) repr.Value {
    return repr.nanbox32.fromTagI(t, integer);
}

pub fn nanbox32FromTagP(t: u32, p: ?*anyopaque) repr.Value {
    return repr.nanbox32.fromTagP(t, p);
}

pub fn nanboxFromBits(word: u64) repr.Value {
    return repr.nanbox64.fromBits(word);
}

pub fn nanboxFromCPointer(p: ?*const anyopaque, tagmask: u64) repr.Value {
    return repr.nanbox64.fromCPointer(p, tagmask);
}

pub fn nanboxFromDouble(d: f64) repr.Value {
    return repr.nanbox64.fromDouble(d);
}

pub fn nanboxFromPointer(p: ?*anyopaque, tagmask: u64) repr.Value {
    return repr.nanbox64.fromPointer(p, tagmask);
}

pub fn nanboxToPointer(x: repr.Value) ?*anyopaque {
    return repr.nanbox64.toPointer(x);
}

/// The unwraps: each Janet type out of a `Value`.
///
/// Every pointer unwrap is the same read under a different result type: the
/// NaN-boxed layouts strip the tag through `repr.toPointer`, and the tagged one
/// reads the payload field. No unwrap checks the type, and the caller tests it
/// first.
///
/// `toInteger` is the one whose input has values it cannot represent. The range
/// test comes before the conversion, and outside the range the result saturates
/// rather than trapping, for the reason the file header gives.
pub fn toAbstract(x: repr.Value) abstracts.Abstract {
    return toPointer(x);
}

pub fn toArray(x: repr.Value) *arrays.Array {
    return @ptrCast(@alignCast(toPointer(x)));
}

pub fn toBoolean(x: repr.Value) bool {
    return repr.unwrapBoolean(x);
}

pub fn toBuffer(x: repr.Value) *buffers.Buffer {
    return @ptrCast(@alignCast(toPointer(x)));
}

pub fn toCfunction(x: repr.Value) boundary.CFunction {
    return @ptrFromInt(@intFromPtr(toPointer(x)));
}

pub fn toFiber(x: repr.Value) *fibers.Fiber {
    return @ptrCast(@alignCast(toPointer(x)));
}

pub fn toFunction(x: repr.Value) *functions.Function {
    return @ptrCast(@alignCast(toPointer(x)));
}

pub inline fn toInteger(x: repr.Value) i32 {
    const d = repr.unwrapNumber(x);
    if (std.math.isNan(d)) return 0;
    if (d >= 2147483647.0) return std.math.maxInt(i32);
    if (d <= -2147483648.0) return std.math.minInt(i32);
    return @intFromFloat(d);
}

pub fn toIntegerAbi(x: repr.Value) i32 {
    return toInteger(x);
}

pub fn toKeyword(x: repr.Value) strings.Keyword {
    return @ptrCast(toPointer(x));
}

pub fn toNumber(x: repr.Value) f64 {
    return repr.unwrapNumber(x);
}

pub inline fn toPointer(x: repr.Value) ?*anyopaque {
    return repr.toPointer(x);
}

pub fn toPointerAbi(x: repr.Value) ?*anyopaque {
    return toPointer(x);
}

pub fn toString(x: repr.Value) strings.String {
    return @ptrCast(toPointer(x));
}

pub fn toStruct(x: repr.Value) structs.Struct {
    return @ptrCast(@alignCast(toPointer(x)));
}

pub fn toSymbol(x: repr.Value) strings.Symbol {
    return @ptrCast(toPointer(x));
}

pub fn toTable(x: repr.Value) *tables.Table {
    return @ptrCast(@alignCast(toPointer(x)));
}

pub fn toTuple(x: repr.Value) tuples.Tuple {
    return @ptrCast(@alignCast(toPointer(x)));
}
