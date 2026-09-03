//! Numeric kernels behind Janet's `int/s64` and `int/u64` abstract types.
//!
//! The pure arithmetic: the
//! abstract-type hash and comparison callbacks, the polymorphic comparisons
//! that mix 64-bit integers with doubles and with each other, decimal
//! formatting, and floored division and modulo.
//!
//! The arithmetic cfunctions are at the foot of the file, along with both
//! abstract types and the conversions. Their bodies unwrap Janet values,
//! allocate abstracts and raise on a type mismatch or a division by zero,
//! which is an ordinary returned error here.

const std = @import("std");
const corefn = @import("../corefn.zig");
const repr = @import("repr");
const constants = @import("constants");
const c = @import("cabi");
const raise = @import("../../api/raise.zig");
const pp_format = @import("../pp/format.zig");
const registry = @import("../registry.zig");
const marsh = @import("../marsh.zig");
const abstract_type = @import("../../api/abstract_type.zig");
const abi = @import("abi");
const method_type = @import("../method_type.zig");
const builtin = @import("builtin");
const utils = @import("../utils.zig");
const wrap = @import("helpers/wrap.zig");
const args_core = @import("../args.zig");
const buffers = @import("buffers.zig");
const abstracts = @import("abstracts.zig");
const numscan = @import("../scan.zig");
const strings = @import("strings.zig");
const tables = @import("tables.zig");

/// The contiguous integer range of a double, matching `JANET_INTMAX_DOUBLE`.
const intmax_double: f64 = 9007199254740992.0;
const intmin_double: f64 = -9007199254740992.0;

// The abstract types store a bare 64-bit integer, so both share one hash.
/// The three callbacks `core/s64` and `core/u64` share.
///
/// A typed payload makes them two instantiations of one generic family rather
/// than three erased functions bound to both types, which is what they are.
///
/// `compare` gets the sharper half of the change. `order.compareAbstract`
/// only reaches it when *both* abstracts carry this type, so the second
/// operand really is a `T`; in C both are `void *` and the callback casts
/// each on faith.
pub fn Boxed(comptime T: type) type {
    return struct {
        pub fn compare(x: *const T, y: *const T) c_int {
            return compareScalar(T, x.*, y.*);
        }

        /// Two 32-bit words exclusive-ored, whatever the signedness. The C
        /// original is one function for both types for the same reason.
        pub fn hash(box: *const T, _: usize) i32 {
            const words: *const [2]i32 = @ptrCast(box);
            return words[0] ^ words[1];
        }

        /// Both boxes marshal identically: eight bytes, and the type comes
        /// from the abstract header rather than from the payload.
        pub fn marshal(box: *T, m: *abi.Marshal) raise.Raising(void) {
            marsh.marshalAbstract(m, box);
            try marsh.marshalInt64(m, @bitCast(box.*));
        }

        pub fn unmarshal(u: *abi.Unmarshal) raise.Raising(*T) {
            const box: *T = @ptrCast(@alignCast(try marsh.unmarshalAbstract(u, @sizeOf(T))));
            box.* = @bitCast(try marsh.unmarshalInt64(u));
            return box;
        }
    };
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
pub fn compareS64Double(x: i64, y: f64) c_int {
    if (std.math.isNan(y)) return 0;
    if (y > intmin_double and y < intmax_double) {
        return compareDoubles(@floatFromInt(x), y);
    }
    if (y > @as(f64, @floatFromInt(std.math.maxInt(i64)))) return -1;
    if (y < @as(f64, @floatFromInt(std.math.minInt(i64)))) return 1;
    return compareScalar(i64, x, @intFromFloat(y));
}

pub fn compareU64Double(x: u64, y: f64) c_int {
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
pub fn compareS64U64(x: i64, y: u64) c_int {
    if (x < 0) return -1;
    if (y > std.math.maxInt(i64)) return -1;
    return compareScalar(i64, x, @intCast(y));
}

pub fn compareU64S64(x: u64, y: i64) c_int {
    if (y < 0) return 1;
    if (x > std.math.maxInt(i64)) return 1;
    return compareScalar(i64, @intCast(x), y);
}

/// Write the decimal form into space the caller reserved, returning its length.
/// `itS64Tostring` below does the reserving, because that is the half that can
/// raise; this half cannot, so it stays a plain function.
pub fn formatS64(val: i64, out: [*]u8) i32 {
    return c.snprintf(out, 32, "%lld", val);
}

pub fn formatU64(val: u64, out: [*]u8) i32 {
    return c.snprintf(out, 32, "%llu", val);
}

/// Floored division. The caller rejects a zero divisor first.
///
/// C's division truncates toward zero, so a negative quotient with a remainder
/// is one step above the floor.
pub fn s64Divf(op1: i64, op2: i64) i64 {
    const x = @divTrunc(op1, op2);
    const negative_quotient = (op1 ^ op2) < 0;
    const inexact = x *% op2 != op1;
    return x -% @intFromBool(negative_quotient and inexact);
}

/// Floored modulo, which takes the sign of the divisor rather than of the
/// dividend. **A zero divisor answers the dividend unchanged**, and that is
/// contract rather than an accident.
pub fn s64Mod(op1: i64, op2: i64) i64 {
    if (op2 == 0) return op1;
    const x = @rem(op1, op2);
    if ((op1 ^ op2) < 0 and x != 0) return x +% op2;
    return x;
}

/// `INT64_MIN / -1` has no representable result, so every method that can
/// reach it refuses it. `divCheck` is the refusal and the four hand-written
/// methods below call it where the generated `/` and `%` make the same test
/// inline; without it the division is a trap on x86-64 and the dividend on
/// AArch64, which is two answers and neither of them one.
fn divCheck(op1: i64, op2: i64) raise.Raising(void) {
    if (op2 == -1 and op1 == std.math.minInt(i64)) {
        return raise.panic("INT64_MIN divided by -1");
    }
}

// ==========================================================================
// int/s64 and int/u64: the abstract types and their cfunction surface.
//
// The two abstract types, the conversions, and the thirty-odd arithmetic
// methods -- everything that raises.
// ==========================================================================

const intmax_int64: i64 = 9007199254740992;

fn checkInt64Range(d: f64) bool {
    if (!(d >= intmin_double and d <= intmax_double)) return false;
    return d == @as(f64, @floatFromInt(@as(i64, @intFromFloat(d))));
}

fn checkUint64Range(d: f64) bool {
    if (!(d >= 0 and d <= intmax_double)) return false;
    return d == @as(f64, @floatFromInt(@as(u64, @intFromFloat(d))));
}

// ------------------------------------------------------- the abstract types

fn itS64Get(_: *i64, key: repr.Value) raise.Raising(?repr.Value) {
    return args_core.findMethod(key, @ptrCast(&s64_methods));
}

fn itU64Get(_: *u64, key: repr.Value) raise.Raising(?repr.Value) {
    return args_core.findMethod(key, @ptrCast(&u64_methods));
}

fn int64Next(_: *i64, key: repr.Value) raise.Raising(repr.Value) {
    return args_core.nextmethod(@ptrCast(&s64_methods), key);
}

fn uint64Next(_: *u64, key: repr.Value) raise.Raising(repr.Value) {
    return args_core.nextmethod(@ptrCast(&u64_methods), key);
}

// The two `tostring` slots take `abi.Render`, the capability a module author is
// offered in place of the buffer's layout. These two types are the runtime's
// own and never cross, so each recovers `buffers.Buffer` on its first line and
// pushes with an ordinary Zig call. See `abi.zig`'s header.

/// The reservation of 32 bytes is what makes writing straight into
/// `buffer->data + buffer->count` safe: the longest decimal rendering of a
/// 64-bit integer is 20 characters.
fn itS64Tostring(box: *i64, render: *abi.Render) raise.Raising(void) {
    const buffer: *buffers.Buffer = @ptrCast(@alignCast(render));
    try buffers.extra(buffer, 32);
    buffer.count += @intCast(formatS64(box.*, buffer.data.? + @as(usize, @intCast(buffer.count))));
}

fn itU64Tostring(box: *u64, render: *abi.Render) raise.Raising(void) {
    const buffer: *buffers.Buffer = @ptrCast(@alignCast(render));
    try buffers.extra(buffer, 32);
    buffer.count += @intCast(formatU64(box.*, buffer.data.? + @as(usize, @intCast(buffer.count))));
}

pub const BoxedS64 = Boxed(i64);
pub const BoxedU64 = Boxed(u64);

pub const s64Type = abstract_type.define(i64, .{
    .name = "core/s64",
    .get = &itS64Get,
    .marshal = &BoxedS64.marshal,
    .unmarshal = &BoxedS64.unmarshal,
    .tostring = &itS64Tostring,
    .compare = &BoxedS64.compare,
    .hash = &BoxedS64.hash,
    .next = &int64Next,
});

pub const u64Type = abstract_type.define(u64, .{
    .name = "core/u64",
    .get = &itU64Get,
    .marshal = &BoxedU64.marshal,
    .unmarshal = &BoxedU64.unmarshal,
    .tostring = &itU64Tostring,
    .compare = &BoxedU64.compare,
    .hash = &BoxedU64.hash,
    .next = &uint64Next,
});

// ------------------------------------------------------- the conversions

/// A boxed value of *either* type converts, and the payload is reinterpreted
/// rather than range-checked -- so `(int/s64 (int/u64 0xFFFFFFFFFFFFFFFF))` is
/// -1 rather than an error, which is what a program sees.
pub fn unwrapS64(x: repr.Value) raise.Raising(i64) {
    switch (repr.typeOf(x)) {
        repr.Tag.number => {
            const d = wrap.toNumber(x);
            if (checkInt64Range(d)) return @intFromFloat(d);
        },
        repr.Tag.string => {
            const str = wrap.toString(x);
            if (numscan.scanInt64(str[0..strings.head(str).length])) |val| return val;
        },
        repr.Tag.abstract => {
            const abst = wrap.toAbstract(x);
            const at = abi.abstractHead(abst).type;
            if (at == &s64Type or at == &u64Type) {
                return @as(*i64, @ptrCast(@alignCast(abst))).*;
            }
        },
        else => {},
    }
    return pp_format.panicf("can not convert %t %q to 64 bit signed integer", .{ x, x });
}

pub fn unwrapU64(x: repr.Value) raise.Raising(u64) {
    switch (repr.typeOf(x)) {
        repr.Tag.number => {
            const d = wrap.toNumber(x);
            if (checkUint64Range(d)) return @intFromFloat(d);
        },
        repr.Tag.string => {
            const str = wrap.toString(x);
            if (numscan.scanUint64(str[0..strings.head(str).length])) |val| return val;
        },
        repr.Tag.abstract => {
            const abst = wrap.toAbstract(x);
            const at = abi.abstractHead(abst).type;
            if (at == &s64Type or at == &u64Type) {
                return @as(*u64, @ptrCast(@alignCast(abst))).*;
            }
        },
        else => {},
    }
    return pp_format.panicf("can not convert %t %q to a 64 bit unsigned integer", .{ x, x });
}

pub fn isInt(x: repr.Value) constants.IntType {
    if (!repr.checkType(x, repr.Tag.abstract)) return .none;
    const at = abi.abstractHead(wrap.toAbstract(x)).type;
    if (at == &s64Type) return .s64;
    if (at == &u64Type) return .u64;
    return .none;
}

/// Allocate a boxed integer of the given abstract type.
fn boxed(comptime T: type, at: *const abi.AbstractType, val: T) repr.Value {
    const p: *T = abstracts.newFor(T, at);
    p.* = val;
    return wrap.fromAbstract(p);
}

pub fn wrapS64(x: i64) repr.Value {
    return boxed(i64, &s64Type, x);
}

pub fn wrapU64(x: u64) repr.Value {
    return boxed(u64, &u64Type, x);
}

// ------------------------------------------------------- the arithmetic

/// The binary operators, and the reason they all go through `u64`.
///
/// Every operand is widened to `u64`, operated on, and reinterpreted back.
/// Zig's wrapping operators would give the same bits without the detour; the
/// detour is kept because it is the route the wire format and the published
/// behaviour are defined by.
const BinOp = enum { add, sub, mul, band, bor, bxor, shl, shr };

fn applyBin(comptime op: BinOp, lhs: u64, rhs: u64) u64 {
    return switch (op) {
        .add => lhs +% rhs,
        .sub => lhs -% rhs,
        .mul => lhs *% rhs,
        .band => lhs & rhs,
        .bor => lhs | rhs,
        .bxor => lhs ^ rhs,
        // **The count is taken modulo the operand's width**, which is the
        // answer the interpreter's own `<<` on an ordinary integer gives at
        // 32 bits and the answer both supported architectures' shift
        // instructions give. `@truncate` decides a count at or beyond the
        // width, once, for every build.
        .shl => lhs << @truncate(rhs),
        .shr => lhs >> @truncate(rhs),
    };
}

fn Box(comptime T: type) type {
    return struct {
        const at: *const abi.AbstractType = if (T == i64) &s64Type else &u64Type;
        /// The *raising* conversion, not the abi beside it.
        ///
        /// Reaching the abi from a `raise.Raising` caller swallows the
        /// refusal: every `call` below is `raise.Raising`, so a binding that
        /// named the abi made `(+ (int/s64 1) {})` kill the process instead of
        /// raising a catchable error.
        ///
        /// A comptime alias is why neither the compiler nor a grep for the
        /// abi's name found it: the call sites read `Box(T).unwrap(...)`.
        /// `tools/check/swallowed.janet` follows an alias now.
        const unwrap = if (T == i64) unwrapS64 else unwrapU64;
        inline fn make(val: T) repr.Value {
            return boxed(T, at, val);
        }
    };
}

/// `OPMETHOD`: variadic, left-folded over the arguments.
fn OpMethod(comptime T: type, comptime op: BinOp) type {
    return struct {
        fn call(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
            try args_core.arity(argv, 2, -1);
            var acc: u64 = @bitCast(try Box(T).unwrap(argv[0]));
            for (argv[1..]) |arg| {
                acc = applyBin(op, acc, @bitCast(try Box(T).unwrap(arg)));
            }
            return Box(T).make(@bitCast(acc));
        }
    };
}

/// `OPMETHODINVERT`: the `r`-prefixed methods, which the interpreter reaches
/// when the boxed integer is the *right* operand, so the arguments swap.
fn OpMethodInvert(comptime T: type, comptime op: BinOp) type {
    return struct {
        fn call(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
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
        fn call(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
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
            // Signed division has one more trapping case than unsigned, and
            // it is tested for explicitly rather than left to the hardware.
            if (T == i64 and val == -1 and acc.* == std.math.minInt(i64)) {
                return raise.panic("INT64_MIN divided by -1");
            }
            acc.* = if (rem) @rem(acc.*, val) else @divTrunc(acc.*, val);
        }

        fn call(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
            try args_core.arity(argv, 2, -1);
            var acc = try Box(T).unwrap(argv[0]);
            for (argv[1..]) |arg| try apply(&acc, try Box(T).unwrap(arg));
            return Box(T).make(acc);
        }

        fn calli(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
            try args_core.fixarity(argv, 2);
            var acc = try Box(T).unwrap(argv[1]);
            try apply(&acc, try Box(T).unwrap(argv[0]));
            return Box(T).make(acc);
        }
    };
}

fn cfunS64Divf(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 2);
    const op1 = try unwrapS64(argv[0]);
    const op2 = try unwrapS64(argv[1]);
    if (op2 == 0) return raise.panic("division by zero");
    try divCheck(op1, op2);
    return boxed(i64, &s64Type, s64Divf(op1, op2));
}

fn cfunS64Divfi(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 2);
    const op2 = try unwrapS64(argv[0]);
    const op1 = try unwrapS64(argv[1]);
    if (op2 == 0) return raise.panic("division by zero");
    try divCheck(op1, op2);
    return boxed(i64, &s64Type, s64Divf(op1, op2));
}

fn cfunS64Mod(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 2);
    const op1 = try unwrapS64(argv[0]);
    const op2 = try unwrapS64(argv[1]);
    try divCheck(op1, op2);
    return boxed(i64, &s64Type, s64Mod(op1, op2));
}

fn cfunS64Modi(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 2);
    const op2 = try unwrapS64(argv[0]);
    const op1 = try unwrapS64(argv[1]);
    try divCheck(op1, op2);
    return boxed(i64, &s64Type, s64Mod(op1, op2));
}

// ------------------------------------------------------- the comparisons

/// The three-way comparison every same-type comparison below goes through.
fn threeWay(comptime T: type, x: T, y: T) f64 {
    if (x < y) return -1;
    if (x > y) return 1;
    return 0;
}

fn cfunS64Compare(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 2);
    if (isInt(argv[0]) != .s64) {
        return raise.panic("compare method requires int/s64 as first argument");
    }
    const x = try unwrapS64(argv[0]);
    switch (repr.typeOf(argv[1])) {
        repr.Tag.number => {
            return wrap.fromNumber(@floatFromInt(compareS64Double(x, wrap.toNumber(argv[1]))));
        },
        repr.Tag.abstract => {
            const abst = wrap.toAbstract(argv[1]);
            const at = abi.abstractHead(abst).type;
            if (at == &s64Type) {
                const y = @as(*i64, @ptrCast(@alignCast(abst))).*;
                return wrap.fromNumber(threeWay(i64, x, y));
            } else if (at == &u64Type) {
                const y = @as(*u64, @ptrCast(@alignCast(abst))).*;
                return wrap.fromNumber(@floatFromInt(compareS64U64(x, y)));
            }
        },
        else => {},
    }
    return wrap.fromNil();
}

fn cfunU64Compare(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 2);
    if (isInt(argv[0]) != .u64) {
        return raise.panic("compare method requires int/u64 as first argument");
    }
    const x = try unwrapU64(argv[0]);
    switch (repr.typeOf(argv[1])) {
        repr.Tag.number => {
            return wrap.fromNumber(@floatFromInt(compareU64Double(x, wrap.toNumber(argv[1]))));
        },
        repr.Tag.abstract => {
            const abst = wrap.toAbstract(argv[1]);
            const at = abi.abstractHead(abst).type;
            if (at == &u64Type) {
                const y = @as(*u64, @ptrCast(@alignCast(abst))).*;
                return wrap.fromNumber(threeWay(u64, x, y));
            } else if (at == &s64Type) {
                const y = @as(*i64, @ptrCast(@alignCast(abst))).*;
                return wrap.fromNumber(@floatFromInt(compareU64S64(x, y)));
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
/// they need no inversion and the same function serves both entries.
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

fn cfunS64New(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    return wrapS64(try unwrapS64(argv[0]));
}

fn cfunU64New(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    return wrapU64(try unwrapU64(argv[0]));
}

/// The bound is `JANET_INTMAX_INT64`, 2^53, and not `INT64_MAX`: beyond it a
/// double cannot tell neighbouring integers apart, so the conversion would
/// silently round.
fn cfunToNumber(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    if (repr.typeOf(argv[0]) == repr.Tag.abstract) {
        const abst = wrap.toAbstract(argv[0]);
        const at = abi.abstractHead(abst).type;
        if (at == &s64Type) {
            const val = @as(*i64, @ptrCast(@alignCast(abst))).*;
            try if (val > intmax_int64 or val < -intmax_int64) outOfRange(argv[0]);
            return wrap.fromNumber(@floatFromInt(val));
        }
        if (at == &u64Type) {
            const val = @as(*u64, @ptrCast(@alignCast(abst))).*;
            try if (val > intmax_int64) outOfRange(argv[0]);
            return wrap.fromNumber(@floatFromInt(val));
        }
    }
    return pp_format.panicf("expected int/u64 or int/s64, got %q", .{argv[0]});
}

fn outOfRange(x: repr.Value) raise.Error {
    return pp_format.panicf("cannot convert %q to a number, must be in the range [%q, %q]", .{ x, wrap.fromNumber(-9007199254740992.0), wrap.fromNumber(9007199254740992.0) });
}

fn cfunToBytes(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.arity(argv, 1, 3);
    if (isInt(argv[0]) == .none) {
        return pp_format.panicf("int/to-bytes: expected an int/s64 or int/u64, got %q", .{argv[0]});
    }

    var reverse = false;
    if (argv.len > 1 and !repr.checkType(argv[1], repr.Tag.nil)) {
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
    // rather than fetched through `args.getBuffer`, so the message names this
    // function rather than the slot.
    var buffer: *buffers.Buffer = undefined;
    if (argv.len > 2 and !repr.checkType(argv[2], repr.Tag.nil)) {
        if (!repr.checkType(argv[2], repr.Tag.buffer)) {
            return pp_format.panicf("int/to-bytes: expected buffer or nil, got %q", .{argv[2]});
        }
        buffer = wrap.toBuffer(argv[2]);
        try buffers.extra(buffer, 8);
    } else {
        buffer = buffers.new(8);
    }

    const bytes: [*]const u8 = @ptrCast(wrap.toAbstract(argv[0]));
    const out = buffer.data.? + @as(usize, @intCast(buffer.count));
    if (reverse) {
        for (0..8) |i| out[7 - i] = bytes[i];
    } else {
        @memcpy(out[0..8], bytes[0..8]);
    }
    buffer.count += 8;
    return wrap.fromBuffer(buffer);
}

const big_endian = (builtin.cpu.arch.endian() == .big);

pub fn libInttypes(env: *tables.Table) raise.Raising(void) {
    const entries = comptime [_]corefn.Entry{
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
    };
    corefn.install(env, entries);
    try registry.registerAbstractType(&s64Type);
    try registry.registerAbstractType(&u64Type);
}
