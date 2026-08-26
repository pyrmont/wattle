//! Numeric kernels behind Janet's `int/s64` and `int/u64` abstract types.
//!
//! These are the parts of `src/core/inttypes.c` that are pure arithmetic: the
//! abstract-type hash and comparison callbacks, the polymorphic comparisons
//! that mix 64-bit integers with doubles and with each other, decimal
//! formatting, and floored division and modulo.
//!
//! The arithmetic cfunctions stayed in C, because their bodies unwrap Janet
//! values, allocate abstracts and panic on a type mismatch or a division by
//! zero, and no Janet signal could then unwind across a Zig frame. Phase 10
//! Part 6 brought them here, at the foot of the file, along with both abstract
//! types and the conversions; jump transparency is what makes a frame that
//! raises legal.

const std = @import("std");
const corefn = @import("corefn");
const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");
const raise = @import("raise");
const pp_format = @import("../pp/format.zig");
const registry = @import("../registry.zig");
const marsh = @import("../marsh.zig");
const abstract_type = @import("../abstract_type.zig");
const method_type = @import("../method_type.zig");
const builtin = @import("builtin");
const utils = @import("../utils.zig");
const kind = @import("helpers/kind.zig");
const wrap = @import("helpers/wrap.zig");
const args_core = @import("../args.zig");
const buffers = @import("buffers.zig");
const abstracts = @import("abstracts.zig");

extern fn snprintf(buffer: [*]u8, size: usize, format: [*:0]const u8, ...) callconv(.c) c_int;

/// The contiguous integer range of a double, matching `JANET_INTMAX_DOUBLE`.
const intmax_double: f64 = 9007199254740992.0;
const intmin_double: f64 = -9007199254740992.0;

// The abstract types store a bare 64-bit integer, so both share one hash.
pub fn zigItHash(p: ?*anyopaque, size: usize) callconv(.c) i32 {
    _ = size;
    const words: [*]const i32 = @ptrCast(@alignCast(p.?));
    return words[0] ^ words[1];
}

pub fn zigItS64CompareAbstract(p1: ?*anyopaque, p2: ?*anyopaque) callconv(.c) c_int {
    const x: *const i64 = @ptrCast(@alignCast(p1.?));
    const y: *const i64 = @ptrCast(@alignCast(p2.?));
    return compareScalar(i64, x.*, y.*);
}

pub fn zigItU64CompareAbstract(p1: ?*anyopaque, p2: ?*anyopaque) callconv(.c) c_int {
    const x: *const u64 = @ptrCast(@alignCast(p1.?));
    const y: *const u64 = @ptrCast(@alignCast(p2.?));
    return compareScalar(u64, x.*, y.*);
}

fn compareScalar(comptime T: type, x: T, y: T) c_int {
    if (x == y) return 0;
    return if (x < y) -1 else 1;
}

fn compareDoubles(x: f64, y: f64) c_int {
    if (x < y) return -1;
    return if (x > y) 1 else 0;
}

/// Compare a signed 64-bit integer with a double.
///
/// Inside the double's contiguous integer range the comparison is exact once
/// the integer is widened. Outside it, widening would round, so the double is
/// narrowed instead -- which is only safe after the infinite and out-of-range
/// cases have been separated out.
pub fn zigItCompareS64Double(x: i64, y: f64) c_int {
    if (std.math.isNan(y)) return 0;
    if (y > intmin_double and y < intmax_double) {
        return compareDoubles(@floatFromInt(x), y);
    }
    if (y > @as(f64, @floatFromInt(std.math.maxInt(i64)))) return -1;
    if (y < @as(f64, @floatFromInt(std.math.minInt(i64)))) return 1;
    return compareScalar(i64, x, @intFromFloat(y));
}

pub fn zigItCompareU64Double(x: u64, y: f64) c_int {
    if (std.math.isNan(y)) return 0;
    if (y < 0) return 1;
    if (y < intmax_double) {
        return compareDoubles(@floatFromInt(x), y);
    }
    if (y > @as(f64, @floatFromInt(std.math.maxInt(u64)))) return -1;
    return compareScalar(u64, x, @intFromFloat(y));
}

/// Compare across the two integer types, where neither range contains the
/// other.
pub fn zigItCompareS64U64(x: i64, y: u64) c_int {
    if (x < 0) return -1;
    if (y > std.math.maxInt(i64)) return -1;
    return compareScalar(i64, x, @intCast(y));
}

pub fn zigItCompareU64S64(x: u64, y: i64) c_int {
    if (y < 0) return 1;
    if (x > std.math.maxInt(i64)) return 1;
    return compareScalar(i64, @intCast(x), y);
}

/// Write the decimal form into space the caller reserved, returning its length.
/// The reservation stays in C because it can panic.
pub fn zigItS64Tostring(val: i64, out: [*]u8) i32 {
    return snprintf(out, 32, "%lld", val);
}

pub fn zigItU64Tostring(val: u64, out: [*]u8) i32 {
    return snprintf(out, 32, "%llu", val);
}

/// Floored division. The caller rejects a zero divisor first.
///
/// C's division truncates toward zero, so a negative quotient with a remainder
/// is one step above the floor.
pub fn zigItS64Divf(op1: i64, op2: i64) i64 {
    const x = divideTruncating(op1, op2);
    const negative_quotient = (op1 ^ op2) < 0;
    const inexact = x *% op2 != op1;
    return x -% @intFromBool(negative_quotient and inexact);
}

/// Floored modulo, which unlike C's remainder takes the sign of the divisor.
/// A zero divisor yields the dividend unchanged, matching the C original.
pub fn zigItS64Mod(op1: i64, op2: i64) i64 {
    if (op2 == 0) return op1;
    const x = remainderTruncating(op1, op2);
    if ((op1 ^ op2) < 0 and x != 0) return x +% op2;
    return x;
}

/// `INT64_MIN / -1` has no representable result. The `/` and `%` methods
/// reject it with a Janet error, but `div` and `mod` do not, so the C code
/// reaches a division that is undefined and platform-dependent -- see
/// FOUND.md. These reproduce the two's-complement result that the development
/// target produces, rather than introducing an error the C version never
/// raised.
fn divideTruncating(numerator: i64, denominator: i64) i64 {
    if (denominator == -1) return 0 -% numerator;
    return @divTrunc(numerator, denominator);
}

fn remainderTruncating(numerator: i64, denominator: i64) i64 {
    if (denominator == -1) return 0;
    return @rem(numerator, denominator);
}

// ==========================================================================
// int/s64 and int/u64: the abstract types and their cfunction surface.
//
// Phase 10 Part 6. The kernels above were Phase 8's; what arrives here is
// everything that raises -- the two abstract types, the conversions, and the
// thirty-odd arithmetic methods.
// ==========================================================================

const intmax_int64: i64 = 9007199254740992;

/// `src/core/util.h`. Provided by `intscan.zig` or `strtod.c`.
extern fn janet_scan_int64(str: [*]const u8, len: i32, out: *i64) callconv(.c) c_int;
extern fn janet_scan_uint64(str: [*]const u8, len: i32, out: *u64) callconv(.c) c_int;

fn checkInt64Range(d: f64) bool {
    if (!(d >= intmin_double and d <= intmax_double)) return false;
    return d == @as(f64, @floatFromInt(@as(i64, @intFromFloat(d))));
}

fn checkUint64Range(d: f64) bool {
    if (!(d >= 0 and d <= intmax_double)) return false;
    return d == @as(f64, @floatFromInt(@as(u64, @intFromFloat(d))));
}

// ------------------------------------------------------- the abstract types

fn itS64Get(p: ?*anyopaque, key: types.Janet, out: *types.Janet) raise.Raising(c_int) {
    _ = p;
    if (kind.checkType(key, constants.JANET_KEYWORD) == 0) return 0;
    return args_core.getmethod(wrap.toKeyword(key), @ptrCast(&s64_methods), out);
}

fn itU64Get(p: ?*anyopaque, key: types.Janet, out: *types.Janet) raise.Raising(c_int) {
    _ = p;
    if (kind.checkType(key, constants.JANET_KEYWORD) == 0) return 0;
    return args_core.getmethod(wrap.toKeyword(key), @ptrCast(&u64_methods), out);
}

fn int64Next(p: ?*anyopaque, key: types.Janet) raise.Raising(types.Janet) {
    _ = p;
    return args_core.nextmethod(@ptrCast(&s64_methods), key);
}

fn uint64Next(p: ?*anyopaque, key: types.Janet) raise.Raising(types.Janet) {
    _ = p;
    return args_core.nextmethod(@ptrCast(&u64_methods), key);
}

/// Both boxes marshal identically: eight bytes, and the type comes from the
/// abstract header rather than from the payload.
fn int64Marshal(p: ?*anyopaque, ctx: *types.JanetMarshalContext) raise.Raising(void) {
    marsh.marshalAbstract(ctx, p);
    const box: *i64 = @ptrCast(@alignCast(p));
    try marsh.marshalInt64(ctx, box.*);
}

fn int64Unmarshal(ctx: *types.JanetMarshalContext) raise.Raising(?*anyopaque) {
    const box: *i64 = @ptrCast(@alignCast(try marsh.unmarshalAbstract(ctx, @sizeOf(i64))));
    box.* = try marsh.unmarshalInt64(ctx);
    return box;
}

/// The reservation of 32 bytes is the C original's and is what makes writing
/// straight into `buffer->data + buffer->count` safe: the longest decimal
/// rendering of a 64-bit integer is 20 characters.
fn itS64Tostring(p: ?*anyopaque, buffer: *types.JanetBuffer) raise.Raising(void) {
    const box: *i64 = @ptrCast(@alignCast(p));
    try buffers.extra(buffer, 32);
    buffer.*.count += zigItS64Tostring(box.*, buffer.*.data.? + @as(usize, @intCast(buffer.*.count)));
}

fn itU64Tostring(p: ?*anyopaque, buffer: *types.JanetBuffer) raise.Raising(void) {
    const box: *u64 = @ptrCast(@alignCast(p));
    try buffers.extra(buffer, 32);
    buffer.*.count += zigItU64Tostring(box.*, buffer.*.data.? + @as(usize, @intCast(buffer.*.count)));
}

pub const s64Type: abstract_type.AbstractType = .{
    .name = "core/s64",
    .gc = null,
    .gcmark = null,
    .get = &itS64Get,
    .put = null,
    .marshal = &int64Marshal,
    .unmarshal = &int64Unmarshal,
    .tostring = &itS64Tostring,
    .compare = &zigItS64CompareAbstract,
    .hash = &zigItHash,
    .next = &int64Next,
    .call = null,
    .length = null,
    .bytes = null,
    .gcperthread = null,
};

pub const u64Type: abstract_type.AbstractType = .{
    .name = "core/u64",
    .gc = null,
    .gcmark = null,
    .get = &itU64Get,
    .put = null,
    .marshal = &int64Marshal,
    .unmarshal = &int64Unmarshal,
    .tostring = &itU64Tostring,
    .compare = &zigItU64CompareAbstract,
    .hash = &zigItHash,
    .next = &uint64Next,
    .call = null,
    .length = null,
    .bytes = null,
    .gcperthread = null,
};

// ------------------------------------------------------- the conversions

/// A boxed value of *either* type converts, and the payload is reinterpreted
/// rather than range-checked -- so `(int/s64 (int/u64 0xFFFFFFFFFFFFFFFF))` is
/// -1 rather than an error. That is the C original's behaviour.
fn janet_unwrap_s64Impl(x: types.Janet) raise.Raising(i64) {
    switch (kind.typeOf(x)) {
        constants.JANET_NUMBER => {
            const d = wrap.toNumber(x);
            if (checkInt64Range(d)) return @intFromFloat(d);
        },
        constants.JANET_STRING => {
            var val: i64 = undefined;
            const str = wrap.toString(x);
            if (janet_scan_int64(str, types.stringHead(str).length, &val) != 0) return val;
        },
        constants.JANET_ABSTRACT => {
            const abst = wrap.toAbstract(x);
            const at = types.abstractHead(abst).type;
            if (at == abstract_type.stored(&s64Type) or at == abstract_type.stored(&u64Type)) {
                return @as(*i64, @ptrCast(@alignCast(abst))).*;
            }
        },
        else => {},
    }
    return pp_format.panicf("can not convert %t %q to 64 bit signed integer", .{ x, x });
}

pub fn janet_unwrap_s64(x: types.Janet) i64 {
    return raise.reported(janet_unwrap_s64Impl(x));
}

/// The Zig entry points, for a caller inside the compilation.
///
/// Phase 11 Part 13. `args_core.zig`'s `getInteger64` and `getUInteger64`
/// reached these through the `export fn`s above, from inside a
/// `raise.Raising` function -- so a refusal became a report nobody consumed,
/// the getter answered `reportToC`'s zero, and the process died at the next
/// scope boundary. `(string/format "%d" "x")` was enough to reproduce it.
/// That is rule 32's family, found by a contract's type rather than by a grep.
pub const unwrapS64 = janet_unwrap_s64Impl;
pub const unwrapU64 = janet_unwrap_u64Impl;

fn janet_unwrap_u64Impl(x: types.Janet) raise.Raising(u64) {
    switch (kind.typeOf(x)) {
        constants.JANET_NUMBER => {
            const d = wrap.toNumber(x);
            if (checkUint64Range(d)) return @intFromFloat(d);
        },
        constants.JANET_STRING => {
            var val: u64 = undefined;
            const str = wrap.toString(x);
            if (janet_scan_uint64(str, types.stringHead(str).length, &val) != 0) return val;
        },
        constants.JANET_ABSTRACT => {
            const abst = wrap.toAbstract(x);
            const at = types.abstractHead(abst).type;
            if (at == abstract_type.stored(&s64Type) or at == abstract_type.stored(&u64Type)) {
                return @as(*u64, @ptrCast(@alignCast(abst))).*;
            }
        },
        else => {},
    }
    return pp_format.panicf("can not convert %t %q to a 64 bit unsigned integer", .{ x, x });
}

pub fn janet_unwrap_u64(x: types.Janet) u64 {
    return raise.reported(janet_unwrap_u64Impl(x));
}

pub fn isInt(x: types.Janet) types.JanetIntType {
    if (kind.checkType(x, constants.JANET_ABSTRACT) == 0) return constants.JANET_INT_NONE;
    const at = types.abstractHead(wrap.toAbstract(x)).type;
    if (at == abstract_type.stored(&s64Type)) return constants.JANET_INT_S64;
    if (at == abstract_type.stored(&u64Type)) return constants.JANET_INT_U64;
    return constants.JANET_INT_NONE;
}

/// Allocate a boxed integer of the given abstract type.
fn boxed(comptime T: type, at: *const types.JanetAbstractType, val: T) types.Janet {
    const p: *T = @ptrCast(@alignCast(abstracts.new(at, @sizeOf(T))));
    p.* = val;
    return wrap.fromAbstract(p);
}

pub fn wrapS64(x: i64) types.Janet {
    return boxed(i64, abstract_type.stored(&s64Type), x);
}

pub fn wrapU64(x: u64) types.Janet {
    return boxed(u64, abstract_type.stored(&u64Type), x);
}

// ------------------------------------------------------- the arithmetic

/// The binary operators, and the reason they all go through `u64`.
///
/// Signed overflow is undefined in C and two's-complement wraparound is not,
/// so the C original casts both operands to `uint64_t`, operates, and casts
/// back -- a comment above `OPMETHOD` says so and cites why. Zig has wrapping
/// operators and would not need the detour, but taking it produces the same
/// bits by the same route, and the route is what a reader of both files has to
/// be able to check.
const BinOp = enum { add, sub, mul, band, bor, bxor, shl, shr };

fn applyBin(comptime op: BinOp, lhs: u64, rhs: u64) u64 {
    return switch (op) {
        .add => lhs +% rhs,
        .sub => lhs -% rhs,
        .mul => lhs *% rhs,
        .band => lhs & rhs,
        .bor => lhs | rhs,
        .bxor => lhs ^ rhs,
        // A shift count of 64 or more is undefined in C, and a Debug build
        // traps on it rather than producing a value -- `FOUND.md` has the
        // reproducer. `@intCast` reproduces both halves of that: it traps in a
        // safe build and is undefined in a release one, exactly where the C
        // does.
        .shl => lhs << @intCast(rhs),
        .shr => lhs >> @intCast(rhs),
    };
}

fn Box(comptime T: type) type {
    return struct {
        const at: *const types.JanetAbstractType = if (T == i64) abstract_type.stored(&s64Type) else abstract_type.stored(&u64Type);
        /// The *raising* conversion, not the abi beside it.
        ///
        /// This was `janet_unwrap_s64` until Phase 11 Part 15, which is Part
        /// 13's defect in the file Part 13 fixed it for. That part gave
        /// `args_core.zig`'s `Wide` the `unwrapS64`/`unwrapU64` entry points
        /// because reaching the abi from a `raise.Raising` caller swallowed
        /// the refusal; every `call` below is `raise.Raising` too, and this
        /// binding kept them on the abi. `(+ (int/s64 1) {})` killed the
        /// process instead of raising a catchable error.
        ///
        /// A comptime alias is why neither the compiler nor a grep for
        /// `c.janet_unwrap_s64` found it: the call sites read
        /// `Box(T).unwrap(...)`, and the abi is a bare identifier in this
        /// file rather than a `c.` one. `port/swallowed.py` follows both now.
        const unwrap = if (T == i64) janet_unwrap_s64Impl else janet_unwrap_u64Impl;
        inline fn make(val: T) types.Janet {
            return boxed(T, at, val);
        }
    };
}

/// `OPMETHOD`: variadic, left-folded over the arguments.
fn OpMethod(comptime T: type, comptime op: BinOp) type {
    return struct {
        fn call(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
            try args_core.arity(argv, 2, -1);
            var acc: u64 = @bitCast(try Box(T).unwrap(argv[0]));
            var i: i32 = 1;
            while (i < @as(i32, @intCast(argv.len))) : (i += 1) {
                acc = applyBin(op, acc, @bitCast(try Box(T).unwrap(argv[@intCast(i)])));
            }
            return Box(T).make(@bitCast(acc));
        }
    };
}

/// `OPMETHODINVERT`: the `r`-prefixed methods, which the interpreter reaches
/// when the boxed integer is the *right* operand, so the arguments swap.
fn OpMethodInvert(comptime T: type, comptime op: BinOp) type {
    return struct {
        fn call(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
            try args_core.fixarity(argv, 2);
            const lhs: u64 = @bitCast(try Box(T).unwrap(argv[1]));
            const rhs: u64 = @bitCast(try Box(T).unwrap(argv[0]));
            return Box(T).make(@bitCast(applyBin(op, lhs, rhs)));
        }
    };
}

/// `UNARYMETHOD`, of which there is one: bitwise complement.
fn NotMethod(comptime T: type) type {
    return struct {
        fn call(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
            try args_core.fixarity(argv, 1);
            return Box(T).make(~try Box(T).unwrap(argv[0]));
        }
    };
}

/// What a zero divisor does, which is the one thing the three division
/// methods disagree about: `div` and `rem` raise and `mod` returns the
/// numerator untouched.
const DivZero = enum { panic, identity };

fn DivMethod(comptime T: type, comptime rem: bool, comptime on_zero: DivZero) type {
    return struct {
        fn apply(acc: *T, val: T) raise.Raising(void) {
            if (val == 0) {
                switch (on_zero) {
                    .panic => return raise.panic("division by zero"),
                    // `mod` leaves the accumulator alone and keeps folding,
                    // which for the only caller means returning it unchanged.
                    .identity => return,
                }
            }
            // Signed division has one more undefined case than unsigned, and
            // the C original tests for it explicitly rather than letting the
            // hardware trap.
            if (T == i64 and val == -1 and acc.* == std.math.minInt(i64)) {
                return raise.panic("INT64_MIN divided by -1");
            }
            acc.* = if (rem) @rem(acc.*, val) else @divTrunc(acc.*, val);
        }

        fn call(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
            try args_core.arity(argv, 2, -1);
            var acc = try Box(T).unwrap(argv[0]);
            var i: i32 = 1;
            while (i < @as(i32, @intCast(argv.len))) : (i += 1) try apply(&acc, try Box(T).unwrap(argv[@intCast(i)]));
            return Box(T).make(acc);
        }

        fn calli(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
            try args_core.fixarity(argv, 2);
            var acc = try Box(T).unwrap(argv[1]);
            try apply(&acc, try Box(T).unwrap(argv[0]));
            return Box(T).make(acc);
        }
    };
}

fn cfunS64Divf(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 2);
    const op1 = try janet_unwrap_s64Impl(argv[0]);
    const op2 = try janet_unwrap_s64Impl(argv[1]);
    if (op2 == 0) return raise.panic("division by zero");
    return boxed(i64, abstract_type.stored(&s64Type), zigItS64Divf(op1, op2));
}

fn cfunS64Divfi(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 2);
    const op2 = try janet_unwrap_s64Impl(argv[0]);
    const op1 = try janet_unwrap_s64Impl(argv[1]);
    if (op2 == 0) return raise.panic("division by zero");
    return boxed(i64, abstract_type.stored(&s64Type), zigItS64Divf(op1, op2));
}

fn cfunS64Mod(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 2);
    const op1 = try janet_unwrap_s64Impl(argv[0]);
    const op2 = try janet_unwrap_s64Impl(argv[1]);
    return boxed(i64, abstract_type.stored(&s64Type), zigItS64Mod(op1, op2));
}

fn cfunS64Modi(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 2);
    const op2 = try janet_unwrap_s64Impl(argv[0]);
    const op1 = try janet_unwrap_s64Impl(argv[1]);
    return boxed(i64, abstract_type.stored(&s64Type), zigItS64Mod(op1, op2));
}

// ------------------------------------------------------- the comparisons

/// The `(x < y) ? -1 : (x > y ? 1 : 0)` the C original writes out at each
/// same-type comparison.
fn threeWay(comptime T: type, x: T, y: T) f64 {
    if (x < y) return -1;
    if (x > y) return 1;
    return 0;
}

fn cfunS64Compare(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 2);
    if (isInt(argv[0]) != constants.JANET_INT_S64) {
        return raise.panic("compare method requires int/s64 as first argument");
    }
    const x = try janet_unwrap_s64Impl(argv[0]);
    switch (kind.typeOf(argv[1])) {
        constants.JANET_NUMBER => {
            return wrap.fromNumber(@floatFromInt(zigItCompareS64Double(x, wrap.toNumber(argv[1]))));
        },
        constants.JANET_ABSTRACT => {
            const abst = wrap.toAbstract(argv[1]);
            const at = types.abstractHead(abst).type;
            if (at == abstract_type.stored(&s64Type)) {
                const y = @as(*i64, @ptrCast(@alignCast(abst))).*;
                return wrap.fromNumber(threeWay(i64, x, y));
            } else if (at == abstract_type.stored(&u64Type)) {
                const y = @as(*u64, @ptrCast(@alignCast(abst))).*;
                return wrap.fromNumber(@floatFromInt(zigItCompareS64U64(x, y)));
            }
        },
        else => {},
    }
    return wrap.fromNil();
}

fn cfunU64Compare(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 2);
    if (isInt(argv[0]) != constants.JANET_INT_U64) {
        return raise.panic("compare method requires int/u64 as first argument");
    }
    const x = try janet_unwrap_u64Impl(argv[0]);
    switch (kind.typeOf(argv[1])) {
        constants.JANET_NUMBER => {
            return wrap.fromNumber(@floatFromInt(zigItCompareU64Double(x, wrap.toNumber(argv[1]))));
        },
        constants.JANET_ABSTRACT => {
            const abst = wrap.toAbstract(argv[1]);
            const at = types.abstractHead(abst).type;
            if (at == abstract_type.stored(&u64Type)) {
                const y = @as(*u64, @ptrCast(@alignCast(abst))).*;
                return wrap.fromNumber(threeWay(u64, x, y));
            } else if (at == abstract_type.stored(&s64Type)) {
                const y = @as(*i64, @ptrCast(@alignCast(abst))).*;
                return wrap.fromNumber(@floatFromInt(zigItCompareU64S64(x, y)));
            }
        },
        else => {},
    }
    return wrap.fromNil();
}

// ----------------------------------------------------- the method tables

const S64 = struct {
    const add = OpMethod(i64, .add).call;
    const sub = OpMethod(i64, .sub).call;
    const subi = OpMethodInvert(i64, .sub).call;
    const mul = OpMethod(i64, .mul).call;
    const div = DivMethod(i64, false, .panic).call;
    const divi = DivMethod(i64, false, .panic).calli;
    const rem = DivMethod(i64, true, .panic).call;
    const remi = DivMethod(i64, true, .panic).calli;
    const band = OpMethod(i64, .band).call;
    const bor = OpMethod(i64, .bor).call;
    const bxor = OpMethod(i64, .bxor).call;
    const bnot = NotMethod(i64).call;
    const shl = OpMethod(i64, .shl).call;
    const shr = OpMethod(i64, .shr).call;
};

const U64 = struct {
    const add = OpMethod(u64, .add).call;
    const sub = OpMethod(u64, .sub).call;
    const subi = OpMethodInvert(u64, .sub).call;
    const mul = OpMethod(u64, .mul).call;
    const div = DivMethod(u64, false, .panic).call;
    const divi = DivMethod(u64, false, .panic).calli;
    const rem = DivMethod(u64, true, .panic).call;
    const remi = DivMethod(u64, true, .panic).calli;
    const mod = DivMethod(u64, true, .identity).call;
    const modi = DivMethod(u64, true, .identity).calli;
    const band = OpMethod(u64, .band).call;
    const bor = OpMethod(u64, .bor).call;
    const bxor = OpMethod(u64, .bxor).call;
    const bnot = NotMethod(u64).call;
    const shl = OpMethod(u64, .shl).call;
    const shr = OpMethod(u64, .shr).call;
};

fn method(comptime name: [:0]const u8, comptime f: anytype) method_type.Method {
    return .{ .name = name, .cfun = f };
}

/// The `r`-prefixed entries are what the interpreter reaches when the boxed
/// integer is the right-hand operand. Note which ones point at the plain
/// method rather than the inverted one: `+`, `*`, `&`, `|` and `^` commute, so
/// they need no inversion, and the C original shares the pointer rather than
/// generating a second function.
const s64_methods = [_]method_type.Method{
    method("+", &S64.add),           method("r+", &S64.add),
    method("-", &S64.sub),           method("r-", &S64.subi),
    method("*", &S64.mul),           method("r*", &S64.mul),
    method("/", &S64.div),           method("r/", &S64.divi),
    method("div", &cfunS64Divf),     method("rdiv", &cfunS64Divfi),
    method("mod", &cfunS64Mod),      method("rmod", &cfunS64Modi),
    method("%", &S64.rem),           method("r%", &S64.remi),
    method("&", &S64.band),          method("r&", &S64.band),
    method("|", &S64.bor),           method("r|", &S64.bor),
    method("^", &S64.bxor),          method("r^", &S64.bxor),
    method("~", &S64.bnot),          method("<<", &S64.shl),
    method(">>", &S64.shr),          method("compare", &cfunS64Compare),
    .{ .name = null, .cfun = null },
};

/// The unsigned table differs from the signed one in two rows: `div` and
/// `rdiv` are ordinary truncating division here, because for unsigned values
/// flooring and truncating agree, so there is no separate `divf`.
const u64_methods = [_]method_type.Method{
    method("+", &U64.add),           method("r+", &U64.add),
    method("-", &U64.sub),           method("r-", &U64.subi),
    method("*", &U64.mul),           method("r*", &U64.mul),
    method("/", &U64.div),           method("r/", &U64.divi),
    method("div", &U64.div),         method("rdiv", &U64.divi),
    method("mod", &U64.mod),         method("rmod", &U64.modi),
    method("%", &U64.rem),           method("r%", &U64.remi),
    method("&", &U64.band),          method("r&", &U64.band),
    method("|", &U64.bor),           method("r|", &U64.bor),
    method("^", &U64.bxor),          method("r^", &U64.bxor),
    method("~", &U64.bnot),          method("<<", &U64.shl),
    method(">>", &U64.shr),          method("compare", &cfunU64Compare),
    .{ .name = null, .cfun = null },
};

// ------------------------------------------------------- the cfunctions

fn cfunS64New(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 1);
    return wrapS64(try janet_unwrap_s64Impl(argv[0]));
}

fn cfunU64New(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 1);
    return wrapU64(try janet_unwrap_u64Impl(argv[0]));
}

/// The bound is `JANET_INTMAX_INT64`, 2^53, and not `INT64_MAX`: beyond it a
/// double cannot tell neighbouring integers apart, so the conversion would
/// silently round.
fn cfunToNumber(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 1);
    if (kind.typeOf(argv[0]) == constants.JANET_ABSTRACT) {
        const abst = wrap.toAbstract(argv[0]);
        const at = types.abstractHead(abst).type;
        if (at == abstract_type.stored(&s64Type)) {
            const val = @as(*i64, @ptrCast(@alignCast(abst))).*;
            try if (val > intmax_int64 or val < -intmax_int64) outOfRange(argv[0]);
            return wrap.fromNumber(@floatFromInt(val));
        }
        if (at == abstract_type.stored(&u64Type)) {
            const val = @as(*u64, @ptrCast(@alignCast(abst))).*;
            try if (val > intmax_int64) outOfRange(argv[0]);
            return wrap.fromNumber(@floatFromInt(val));
        }
    }
    return pp_format.panicf("expected int/u64 or int/s64, got %q", .{argv[0]});
}

fn outOfRange(x: types.Janet) raise.Error {
    return pp_format.panicf("cannot convert %q to a number, must be in the range [%q, %q]", .{ x, wrap.fromNumber(-9007199254740992.0), wrap.fromNumber(9007199254740992.0) });
}

fn cfunToBytes(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    try args_core.arity(argv, 1, 3);
    if (isInt(argv[0]) == constants.JANET_INT_NONE) {
        return pp_format.panicf("int/to-bytes: expected an int/s64 or int/u64, got %q", .{argv[0]});
    }

    var reverse = false;
    if (@as(i32, @intCast(argv.len)) > 1 and kind.checkType(argv[1], constants.JANET_NIL) == 0) {
        const endianness = try args_core.getKeyword(argv, 1);
        if (utils.cstrcmp(endianness, "le") == 0) {
            reverse = big_endian;
        } else if (utils.cstrcmp(endianness, "be") == 0) {
            reverse = !big_endian;
        } else {
            return pp_format.panicf("int/to-bytes: expected endianness :le, :be or nil, got %v", .{argv[1]});
        }
    }

    // Unlike `buffer/*`, an explicit buffer here is required to be a buffer
    // rather than fetched through `janet_getbuffer`, so the message names this
    // function rather than the slot.
    var buffer: *types.JanetBuffer = undefined;
    if (@as(i32, @intCast(argv.len)) > 2 and kind.checkType(argv[2], constants.JANET_NIL) == 0) {
        if (kind.checkType(argv[2], constants.JANET_BUFFER) == 0) {
            return pp_format.panicf("int/to-bytes: expected buffer or nil, got %q", .{argv[2]});
        }
        buffer = wrap.toBuffer(argv[2]);
        try buffers.extra(buffer, 8);
    } else {
        buffer = buffers.new(8);
    }

    const bytes: [*]const u8 = @ptrCast(wrap.toAbstract(argv[0]));
    const out = buffer.*.data.? + @as(usize, @intCast(buffer.*.count));
    if (reverse) {
        for (0..8) |i| out[7 - i] = bytes[i];
    } else {
        @memcpy(out[0..8], bytes[0..8]);
    }
    buffer.*.count += 8;
    return wrap.fromBuffer(buffer);
}

const big_endian = (builtin.cpu.arch.endian() == .big);

pub fn janet_lib_inttypesImpl(env: *types.JanetTable) raise.Raising(void) {
    const entries = [_]corefn.Entry{
        corefn.reg("int/s64", &cfunS64New, @src(), "(int/s64 value)", "Create a boxed signed 64 bit integer from a string value or a number."),
        corefn.reg("int/u64", &cfunU64New, @src(), "(int/u64 value)", "Create a boxed unsigned 64 bit integer from a string value or a number."),
        corefn.reg("int/to-number", &cfunToNumber, @src(), "(int/to-number value)", "Convert an int/u64 or int/s64 to a number. Fails if the number is out of range for an int64."),
        corefn.reg("int/to-bytes", &cfunToBytes, @src(), "(int/to-bytes value &opt endianness buffer)", "Write the bytes of an `int/s64` or `int/u64` into a buffer.\n" ++
            "The `buffer` parameter specifies an existing buffer to write to, if unset a new buffer will be created.\n" ++
            "Returns the modified buffer.\n" ++
            "The `endianness` parameter indicates the byte order:\n" ++
            "- `nil` (unset): system byte order\n" ++
            "- `:le`: little-endian, least significant byte first\n" ++
            "- `:be`: big-endian, most significant byte first\n"),
        corefn.end,
    };
    corefn.install(env, &entries);
    try registry.registerAbstractType(abstract_type.stored(&s64Type));
    try registry.registerAbstractType(abstract_type.stored(&u64Type));
}

pub fn libInttypes(env: *types.JanetTable) void {
    raise.reported(janet_lib_inttypesImpl(env));
}
