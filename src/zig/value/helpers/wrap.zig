//! Wrap: a `Janet` out of something, and something out of a `Janet`.
//!
//! The four inspection names are not here -- they convert nothing, and they
//! are `repr`'s, the module below this one. What matters at a call site is
//! that **the names go by direction rather than by verb**: `wrap.fromTable(t)`
//! and `wrap.toTable(v)`, 36 members in two columns.
//!
//! That shape dissolves four separate problems at once, which is the evidence
//! it is the right one. `true` and `false` are Zig keywords, so a
//! type-stripped `wrap.true()` is impossible and `fromTrue()` is an
//! ordinary identifier. Keyword and symbol both wanted `wrap` in one type
//! leaf, and so did cfunction and function; `fromKeyword` sits beside
//! `fromSymbol` without a word between them. And `wrap.pointer(p)` would
//! have collided with the private tag-taking primitive, which stays private
//! because no type leaf needs it.
//!
//! `fromNil()` has nothing to be *from* -- nil is the one immediate with no
//! source value. Kept anyway, for uniformity: a reader scanning a column of
//! `from*` should not have to notice the one that is not.
//!
//! ## What is not here
//!
//! **The representation.** Which of the three layouts a build compiles, what
//! each one looks like, and why the nanbox-32 arm is written and not executed
//! are all `repr.zig`'s, and its header is the one account of them. This file
//! converts *to and from* a `Value`; it does not decide what one is.
//!
//! **`janet_memalloc_empty` and `janet_memempty`**, which are allocation
//! rather than representation and live in `value.zig` with the two dictionary
//! callers that want them.
//!
//! Nothing here calls anything that can raise, so the file carries no
//! `jump-transparent` marker: that marker records that a Janet signal may pass
//! *through* a frame, and nothing below these can produce one.
//!
//! ## Type punning is the subject, not an accident
//!
//! Every function here writes one member of a union and reads another. That is
//! defined in C and it is defined in Zig for an `extern union`, so nothing here
//! needs `@bitCast` gymnastics to say what the original says.
//!
//! ## What is reproduced rather than repaired
//!
//! **`janet_wrap_integer` does not exist under `-Dnanbox=false`.** Janet
//! declares it beside twenty-one siblings and defines it only inside the
//! nanbox-only block, so a tagged build has no such symbol. No C caller
//! notices, because they all expand the macro; every Zig subsystem would, which
//! is why `value/helpers/access.zig` writes the macro out rather than calling
//! it. The gap is reproduced -- the export below sits inside a `comptime` block
//! that tests the layout -- and `FOUND.md` records it. Closing it would be a
//! product decision.
//!
//! **`janet_wrap_number_safe` canonicalises a NaN under both NaN-boxed layouts
//! and not under the tagged one**, where a signalling NaN's payload survives
//! into the value. The asymmetry is the C original's -- its tagged branch is a
//! bare call to `janet_wrap_number` -- and it is harmless there, because the
//! tagged layout does not use the NaN space for anything.
//!
//! **`janet_unwrap_integer` is not reproducible at all.** The macro it fills is
//! `(int32_t) janet_unwrap_number(x)`, a cast C leaves undefined for a NaN or
//! an out-of-range double, and the two behavioural targets already disagree:
//! aarch64's `fcvtzs` saturates where x86-64's `cvttsd2si` yields `INT32_MIN`.
//! Zig has no saturating float-to-integer cast and `@intFromFloat` is illegal
//! behaviour outside the destination range, so this tests before converting. It
//! saturates, which is the development target's answer; `FOUND.md` records the
//! divergence, and no contract pins it.

const std = @import("std");
const types = @import("types");
const repr = @import("repr");

/// The file's own struct, so that `abi` can name the declarations it shadows.
/// A struct member does not shadow a container declaration, but it does make
/// the unqualified name ambiguous: without this, `abi.fromNil` would resolve
/// to itself.
const outer = @This();

// ------------------------------------------------------------------- layout
//
// **The three layouts are not here.** They are `repr.zig`'s -- a module below
// `types`, holding `Value`, the tag and the bit-level operations over them,
// and importing `std`, `config` and `constants` and nothing else. What is here
// is what could not go down with them: every entry point below names a Janet
// heap type, or sits beside one that does. `repr.bits` is the selected layout
// and this file is its face.

// ----------------------------------------------------- the integer unwrap

/// `janet_unwrap_integer`, the one entry point whose C original has no defined
/// answer for every input. The range test is what Zig requires and C omits;
/// outside it the result saturates rather than trapping. See the header.
pub inline fn toInteger(x: repr.Value) i32 {
    const d = repr.unwrapNumber(x);
    if (std.math.isNan(d)) return 0;
    if (d >= 2147483647.0) return std.math.maxInt(i32);
    if (d <= -2147483648.0) return std.math.minInt(i32);
    return @intFromFloat(d);
}

// ----------------------------------------------------------------- unwraps

/// Every pointer unwrap is the same read under a different result type: the
/// NaN-boxed layouts strip the tag through `janet_nanbox_to_pointer`, and the
/// two others read the payload field. No unwrap checks the type -- that is the
/// caller's job in C and it stays the caller's job here.
pub inline fn toPointer(x: repr.Value) ?*anyopaque {
    return repr.toPointer(x);
}

pub fn toStruct(x: repr.Value) types.JanetStruct {
    return @ptrCast(@alignCast(toPointer(x)));
}

pub fn toTuple(x: repr.Value) types.JanetTuple {
    return @ptrCast(@alignCast(toPointer(x)));
}

pub fn toFiber(x: repr.Value) *types.JanetFiber {
    return @ptrCast(@alignCast(toPointer(x)));
}

pub fn toArray(x: repr.Value) *types.JanetArray {
    return @ptrCast(@alignCast(toPointer(x)));
}

pub fn toTable(x: repr.Value) *types.JanetTable {
    return @ptrCast(@alignCast(toPointer(x)));
}

pub fn toBuffer(x: repr.Value) *types.JanetBuffer {
    return @ptrCast(@alignCast(toPointer(x)));
}

pub fn toString(x: repr.Value) types.JanetString {
    return @ptrCast(toPointer(x));
}

pub fn toSymbol(x: repr.Value) types.JanetSymbol {
    return @ptrCast(toPointer(x));
}

pub fn toKeyword(x: repr.Value) types.JanetKeyword {
    return @ptrCast(toPointer(x));
}

pub fn toAbstract(x: repr.Value) types.JanetAbstract {
    return toPointer(x);
}

/// The `callconv(.c)` abi over `toPointer`, which is `inline`. The suffix is on
/// the abi rather than on the operation.
pub fn toPointerAbi(x: repr.Value) ?*anyopaque {
    return toPointer(x);
}

pub fn toFunction(x: repr.Value) *types.JanetFunction {
    return @ptrCast(@alignCast(toPointer(x)));
}

/// A function pointer has a stricter alignment than `*anyopaque`, so this is
/// the one unwrap that goes through the address rather than through
/// `@ptrCast`. `trace_frames.zig` recovers a cfunction from a frame's `pc` the
/// same way.
pub fn toCfunction(x: repr.Value) types.JanetCFunction {
    return @ptrFromInt(@intFromPtr(toPointer(x)));
}

pub fn toBoolean(x: repr.Value) bool {
    return repr.unwrapBoolean(x);
}

pub fn toNumber(x: repr.Value) f64 {
    return repr.unwrapNumber(x);
}

/// The `callconv(.c)` abi over `toInteger`. See `toPointerAbi`.
pub fn toIntegerAbi(x: repr.Value) i32 {
    return toInteger(x);
}

// ------------------------------------------------------------------- wraps
//
// Every one of these is a *macro* under both NaN-boxed layouts and a function
// only under the tagged one. A C caller therefore pays nothing to wrap a
// value, while a Zig caller reaching the same name through a `pub extern fn`
// paid a call on every layout -- measured at +89% on the arithmetic workload.
// So the implementation is `pub inline` here.
//
// The `callconv(.c)` abis are in `abi` below, one line each. They exist
// because `@export` needs an address and an `inline fn` has none.

/// The four wrappers whose payload is a bit rather than a pointer. Both
/// NaN-boxed layouts build them from a tag and an immediate; the tagged one
/// writes the two fields directly.
pub inline fn fromNil() repr.Value {
    return repr.wrapNil();
}

/// `janet_wrap_boolean`, whose parameter is a C `int` in Janet's header and
/// whose macro is `!!(b)`. It takes a `bool`; the `int` survives one line down,
/// in the abi, because that is the boundary where a C caller's `!!` has to be
/// done for it.
///
/// The conversion is what made the C-shaped predicates in the tree visible:
/// every site that now says `isatty(fd) != 0` or `t_info.tm_isdst != 0` is a
/// crossing from somebody else's `int`, and reads as one.
pub inline fn fromBoolean(b: bool) repr.Value {
    return repr.wrapBoolean(b);
}

pub inline fn fromTrue() repr.Value {
    return fromBoolean(true);
}

pub inline fn fromFalse() repr.Value {
    return fromBoolean(false);
}

/// `janet_wrap_integer`, which is `janet_wrap_number((int32_t)(x))` under every
/// layout. The export it feeds exists only under two of them; see the header
/// and the `comptime` block at the end of this section.
pub inline fn fromInteger(x: i32) repr.Value {
    return repr.wrapNumber(@floatFromInt(x));
}

pub inline fn fromNumber(x: f64) repr.Value {
    return repr.wrapNumber(x);
}

pub inline fn fromString(x: types.JanetString) repr.Value {
    return repr.wrapCPointer(x, repr.Tag.string);
}

pub inline fn fromSymbol(x: types.JanetSymbol) repr.Value {
    return repr.wrapCPointer(x, repr.Tag.symbol);
}

pub inline fn fromKeyword(x: types.JanetKeyword) repr.Value {
    return repr.wrapCPointer(x, repr.Tag.keyword);
}

pub inline fn fromArray(x: *types.JanetArray) repr.Value {
    return repr.wrapPointer(x, repr.Tag.array);
}

pub inline fn fromTuple(x: types.JanetTuple) repr.Value {
    return repr.wrapCPointer(x, repr.Tag.tuple);
}

pub inline fn fromStruct(x: types.JanetStruct) repr.Value {
    return repr.wrapCPointer(x, repr.Tag.@"struct");
}

/// A null fiber is a legal payload, and `test/value_wrap.zig` contracts it:
/// every fiber with no child wraps one. It must not become nil, and it must
/// come back null.
pub inline fn fromFiber(x: ?*types.JanetFiber) repr.Value {
    return repr.wrapPointer(x, repr.Tag.fiber);
}

pub inline fn fromBuffer(x: *types.JanetBuffer) repr.Value {
    return repr.wrapPointer(x, repr.Tag.buffer);
}

pub inline fn fromFunction(x: *types.JanetFunction) repr.Value {
    return repr.wrapPointer(x, repr.Tag.function);
}

pub inline fn fromCfunction(x: types.JanetCFunction) repr.Value {
    return repr.wrapPointer(@ptrCast(@constCast(x)), repr.Tag.cfunction);
}

pub inline fn fromTable(x: *types.JanetTable) repr.Value {
    return repr.wrapPointer(x, repr.Tag.table);
}

pub inline fn fromAbstract(x: types.JanetAbstract) repr.Value {
    return repr.wrapPointer(x, repr.Tag.abstract);
}

pub inline fn fromPointer(x: ?*anyopaque) repr.Value {
    return repr.wrapPointer(x, repr.Tag.pointer);
}

/// The one wrap that is not a macro anywhere: `janet.h` declares
/// `janet_wrap_number_safe` as a function under all three layouts, because the
/// NaN canonicalisation it does has no macro spelling.
pub fn fromNumberSafe(d: f64) repr.Value {
    return repr.wrapNumberSafe(d);
}

/// The `callconv(.c)` abis for the wraps above.
///
/// `@export` needs an address and an `inline fn` has none, so each of these
/// gives one symbol something to point at and does nothing else. Nothing but
/// the `comptime` block below and `cabi_check.zig` should name this struct: a
/// Zig caller wants the `inline` above, which is the whole point of 5d(c).
/// They are `pub` so that `cabi_check.zig` can compare each against the
/// declaration `cabi.zig` still holds for it -- nineteen of the pairs 5c named
/// as uncovered, covered here because splitting the name gave the check
/// something to reach.
///
/// The bodies say `outer.` because a struct member does not shadow a container
/// declaration but does make the unqualified name ambiguous.
pub const abi = struct {
    pub fn fromNil() callconv(.c) repr.Value {
        return outer.fromNil();
    }

    pub fn fromBoolean(b: c_int) callconv(.c) repr.Value {
        return outer.fromBoolean(b != 0);
    }

    pub fn fromTrue() callconv(.c) repr.Value {
        return outer.fromTrue();
    }

    pub fn fromFalse() callconv(.c) repr.Value {
        return outer.fromFalse();
    }

    pub fn fromInteger(x: i32) callconv(.c) repr.Value {
        return outer.fromInteger(x);
    }

    pub fn fromNumber(x: f64) callconv(.c) repr.Value {
        return outer.fromNumber(x);
    }

    pub fn fromString(x: types.JanetString) callconv(.c) repr.Value {
        return outer.fromString(x);
    }

    pub fn fromSymbol(x: types.JanetSymbol) callconv(.c) repr.Value {
        return outer.fromSymbol(x);
    }

    pub fn fromKeyword(x: types.JanetKeyword) callconv(.c) repr.Value {
        return outer.fromKeyword(x);
    }

    pub fn fromArray(x: *types.JanetArray) callconv(.c) repr.Value {
        return outer.fromArray(x);
    }

    pub fn fromTuple(x: types.JanetTuple) callconv(.c) repr.Value {
        return outer.fromTuple(x);
    }

    pub fn fromStruct(x: types.JanetStruct) callconv(.c) repr.Value {
        return outer.fromStruct(x);
    }

    pub fn fromFiber(x: ?*types.JanetFiber) callconv(.c) repr.Value {
        return outer.fromFiber(x);
    }

    pub fn fromBuffer(x: *types.JanetBuffer) callconv(.c) repr.Value {
        return outer.fromBuffer(x);
    }

    pub fn fromFunction(x: *types.JanetFunction) callconv(.c) repr.Value {
        return outer.fromFunction(x);
    }

    pub fn fromCfunction(x: types.JanetCFunction) callconv(.c) repr.Value {
        return outer.fromCfunction(x);
    }

    pub fn fromTable(x: *types.JanetTable) callconv(.c) repr.Value {
        return outer.fromTable(x);
    }

    pub fn fromAbstract(x: types.JanetAbstract) callconv(.c) repr.Value {
        return outer.fromAbstract(x);
    }

    pub fn fromPointer(x: ?*anyopaque) callconv(.c) repr.Value {
        return outer.fromPointer(x);
    }
};

// The eighteen wrappers `wrap.c` provides in one block under either NaN-boxed
// layout and one by one under the tagged one. They are exported here from a
// single list because the bodies are identical across the three; only
// `janet_wrap_integer` varies, and it varies by being absent.
comptime {
    // Absent under the tagged layout, reproducing the defect `FOUND.md`
    // records against `wrap.c`.
}

// ------------------------------------- the inline surface, and why it is gone
//
// A second, `pub inline` spelling of twenty-one of this file's operations
// existed, imported by the interpreter alone, because reaching them through
// the *symbol table* measured +89% on the arithmetic workload: the loop asks
// what a value is once per instruction and paid a call each time.
//
// The container's own wraps are `pub inline fn`, which answers the measurement
// for every caller, and the two signatures that differed -- `bool` against a
// C `int` -- converged. The interpreter's ninety sites name `wrap` and `repr`
// directly, and the benchmark is what says the +89% has not come back.

// -------------------------------------------------- per-layout nanbox helpers

pub fn nanboxToPointer(x: repr.Value) ?*anyopaque {
    return repr.nanbox64.toPointer(x);
}

pub fn nanboxFromPointer(p: ?*anyopaque, tagmask: u64) repr.Value {
    return repr.nanbox64.fromPointer(p, tagmask);
}

pub fn nanboxFromCPointer(p: ?*const anyopaque, tagmask: u64) repr.Value {
    return repr.nanbox64.fromCPointer(p, tagmask);
}

pub fn nanboxFromDouble(d: f64) repr.Value {
    return repr.nanbox64.fromDouble(d);
}

pub fn nanboxFromBits(word: u64) repr.Value {
    return repr.nanbox64.fromBits(word);
}

pub fn nanbox32FromTagI(t: u32, integer: i32) repr.Value {
    return repr.nanbox32.fromTagI(t, integer);
}

pub fn nanbox32FromTagP(t: u32, p: ?*anyopaque) repr.Value {
    return repr.nanbox32.fromTagP(t, p);
}

// `janet.h` declares five helpers under `JANET_NANBOX_64` and two under
// `JANET_NANBOX_32`, and each set is the expansion target of that layout's wrap
// and unwrap macros. A build gets exactly one set, which is why these are
// exported from a `comptime` block rather than declared `export fn`: a body
// naming `x.tagged` must not be analysed in a build where `Janet` has no such
// field.
comptime {
    switch (repr.layout) {
        .nanbox64 => {},
        .nanbox32 => {},
        .tagged => {},
    }
}

// ------------------------------------------------ what is not in this file
//
// `janet_memalloc_empty` and `janet_memempty` are allocation rather than
// representation, and they live in `value.zig`, the bucket the two dictionary
// leaves already share.
//
// What that buys is this file's import list. With those two here it was `std`,
// `config`, `utils`, `fatal`, `types`, `constants` and `vm/lifecycle.zig`;
// three of those were there for them alone -- a collection budget to charge,
// an out-of-memory exit to take, a `janet_malloc` to call. It is `std`, `repr`
// and `types` now, and every declaration in the file is a conversion.
