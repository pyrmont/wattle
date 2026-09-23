//! The `int/s64` and `int/u64` abstract types, their arithmetic, and the
//! numeric kernels behind both.
//!
//! `wrapS64` and `wrapU64` box an integer, `unwrapS64` and `unwrapU64` take
//! one back out of a number, a string or either box, and `isInt` says which of
//! the two an abstract is. `s64Type` and `u64Type` are the abstract types
//! themselves, and `libInttypes` registers them along with the `int/`
//! bindings.
//!
//! The pure arithmetic is the rest: the abstract-type hash and comparison
//! callbacks, the polymorphic comparisons that mix 64-bit integers with
//! doubles and with each other, decimal formatting, and floored division and
//! modulo. None of that raises.
//!
//! The arithmetic methods are generated. `OpMethod`, `OpMethodInvert`,
//! `NotMethod` and `DivMethod` each build an nfunction from a type and an
//! operation, `S64` and `U64` name one instantiation per row, and
//! `s64_methods` and `u64_methods` are the tables `itS64Get` and `itU64Get`
//! look a method name up in. Those bodies unwrap Janet values, allocate
//! abstracts, and raise on a type mismatch or a division by zero.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");
const builtin = @import("builtin");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const abstract_type = @import("../../api/abstract_type.zig");
const abstracts = @import("abstracts.zig");
const args_core = @import("../args.zig");
const buffers = @import("buffers.zig");
const c = @import("cabi");
const constants = @import("constants");
const corefn = @import("../corefn.zig");
const marsh = @import("../marsh.zig");
const method_type = @import("../method_type.zig");
const numscan = @import("../scan.zig");
const pp_format = @import("../pp/format.zig");
const raise = @import("../../api/raise.zig");
const registry = @import("../registry.zig");
const repr = @import("repr");
const strings = @import("strings.zig");
const tables = @import("tables.zig");
const utils = @import("../utils.zig");
const wrap = @import("helpers/wrap.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// Whether the host is big-endian, decided at compile time. `nfunToBytes`
/// compares a caller's keyword against it.
const big_endian = (builtin.cpu.arch.endian() == .big);

/// The ends of the contiguous integer range of a double, matching
/// `constants.intmax_double`. Past them a double cannot tell
/// neighbouring integers apart.
const intmax_double: f64 = 9007199254740992.0;
const intmin_double: f64 = -9007199254740992.0;

/// The same bound as an `i64`, matching `constants.intmax_int64`.
/// `nfunToNumber` refuses a box outside it.
const intmax_int64: i64 = 9007199254740992;

/// The first double past each type's range, 2^63 and 2^64, exact as doubles.
/// `maxInt(i64)` and `maxInt(u64)` are not exact and round up to these, so the
/// range tests that come before a conversion are exclusive at them.
const s64_limit: f64 = std.math.ldexp(@as(f64, 1.0), @bitSizeOf(i64) - 1);
const u64_limit: f64 = std.math.ldexp(@as(f64, 1.0), @bitSizeOf(u64));

/// The abstract type `int/s64` boxes an `i64` in.
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

/// `int/s64`'s methods, terminated by a null name.
///
/// The `r`-prefixed entries are what the interpreter reaches when the boxed
/// integer is the right-hand operand. Note which of them point at the plain
/// method rather than the inverted one: `+`, `*`, `&`, `|` and `^` commute, so
/// they need no inversion and the same function serves both entries.
const s64_methods = [_]method_type.Method{
    method("+", &S64.add),           method("r+", &S64.add),
    method("-", &S64.sub),           method("r-", &S64.subi),
    method("*", &S64.mul),           method("r*", &S64.mul),
    method("/", &S64.div),           method("r/", &S64.divi),
    method("div", &nfunS64Divf),     method("rdiv", &nfunS64Divfi),
    method("mod", &nfunS64Mod),      method("rmod", &nfunS64Modi),
    method("%", &S64.rem),           method("r%", &S64.remi),
    method("&", &S64.band),          method("r&", &S64.band),
    method("|", &S64.bor),           method("r|", &S64.bor),
    method("^", &S64.bxor),          method("r^", &S64.bxor),
    method("~", &S64.bnot),          method("<<", &S64.shl),
    method(">>", &S64.shr),          method("compare", &nfunS64Compare),
    .{ .name = null, .nfun = null },
};

/// The abstract type `int/u64` boxes a `u64` in.
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

/// `int/u64`'s methods, terminated by a null name.
///
/// It differs from the signed table in the four division rows. `div` and
/// `rdiv` are ordinary truncating division here, because for unsigned values
/// flooring and truncating agree, so there is no separate `divf`. `mod` and
/// `rmod` are `DivMethod` with the identity-on-zero rule rather than the
/// hand-written `s64Mod`, because for unsigned values the remainder and the
/// floored modulo agree as well.
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
    method(">>", &U64.shr),          method("compare", &nfunU64Compare),
    .{ .name = null, .nfun = null },
};

// ==========================================================================
// Types
// ==========================================================================

/// The binary operators the generated methods are built from.
///
/// Every operand is widened to `u64`, operated on, and reinterpreted back.
/// Zig's wrapping operators would give the same bits without the detour; the
/// detour is kept because it is the route the wire format and the published
/// behaviour are defined by.
const BinOp = enum { add, sub, mul, band, bor, bxor, shl, shr };

/// The per-type pieces a generated method needs: the abstract type, the
/// raising unwrap, and the box constructor.
fn Box(comptime T: type) type {
    return struct {
        const at: *const abi.AbstractType = if (T == i64) &s64Type else &u64Type;
        /// The raising conversion, not the abi beside it.
        ///
        /// Reaching the abi from a raise-capable caller swallows the
        /// refusal: every `call` below is raise-capable, so a binding that
        /// named the abi would make `(+ (int/s64 1) {})` kill the process
        /// instead of raising a catchable error.
        ///
        /// A comptime alias is why neither the compiler nor a grep for the
        /// abi's name finds it: the call sites read `Box(T).unwrap(...)`.
        /// `res/check/swallowed.janet` follows an alias.
        const unwrap = if (T == i64) unwrapS64 else unwrapU64;
        /// Boxes `val` in this type's abstract.
        inline fn make(val: T) repr.Value {
            return boxed(T, at, val);
        }
    };
}

/// The four callbacks `core/s64` and `core/u64` share, over a typed payload.
///
/// A typed payload makes them two instantiations of one generic family rather
/// than four erased functions bound to both types. `compare` gets the sharper
/// half of that: `order.compareAbstract` reaches it only when both abstracts
/// have this type, so the second operand really is a `T`.
pub fn Boxed(comptime T: type) type {
    return struct {
        /// Orders two boxes of this type.
        pub fn compare(x: *const T, y: *const T) c_int {
            return compareScalar(T, x.*, y.*);
        }

        /// Two 32-bit words exclusive-ored, whatever the signedness.
        pub fn hash(box: *const T, _: usize) i32 {
            const words: *const [2]i32 = @ptrCast(box);
            return words[0] ^ words[1];
        }

        /// Both boxes marshal identically: eight bytes, with the type coming
        /// from the abstract header rather than from the payload.
        pub fn marshal(box: *T, m: *abi.Marshal) raise.Error!void {
            marsh.marshalAbstract(m, box);
            try marsh.marshalInt64(m, @bitCast(box.*));
        }

        /// Reads back what `marshal` wrote, into a fresh abstract.
        pub fn unmarshal(u: *abi.Unmarshal) raise.Error!*T {
            const box: *T = @ptrCast(@alignCast(try marsh.unmarshalAbstract(u, @sizeOf(T))));
            box.* = @bitCast(try marsh.unmarshalInt64(u));
            return box;
        }
    };
}

/// `Boxed` at each of the two payload types, which is what `s64Type` and
/// `u64Type` take their callbacks from.
pub const BoxedS64 = Boxed(i64);
pub const BoxedU64 = Boxed(u64);

/// Builds the two division methods for a type: `rem` selects remainder over
/// quotient, and `on_zero` what a zero divisor does.
fn DivMethod(comptime T: type, comptime rem: bool, comptime on_zero: DivZero) type {
    return struct {
        fn apply(acc: *T, val: T) raise.Error!void {
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

        fn call(argv: []repr.Value) raise.Error!repr.Value {
            try args_core.arity(argv, 2, -1);
            var acc = try Box(T).unwrap(argv[0]);
            for (argv[1..]) |arg| try apply(&acc, try Box(T).unwrap(arg));
            return Box(T).make(acc);
        }

        fn calli(argv: []repr.Value) raise.Error!repr.Value {
            try args_core.fixarity(argv, 2);
            var acc = try Box(T).unwrap(argv[1]);
            try apply(&acc, try Box(T).unwrap(argv[0]));
            return Box(T).make(acc);
        }
    };
}

/// What a zero divisor does, which is the one thing the three division
/// methods disagree about: `div` and `rem` raise and `mod` returns the
/// numerator untouched.
const DivZero = enum { panic, identity };

/// Builds the one unary method, bitwise complement.
fn NotMethod(comptime T: type) type {
    return struct {
        fn call(argv: []repr.Value) raise.Error!repr.Value {
            try args_core.fixarity(argv, 1);
            return Box(T).make(~try Box(T).unwrap(argv[0]));
        }
    };
}

/// Builds a variadic method that folds `op` left over its arguments.
fn OpMethod(comptime T: type, comptime op: BinOp) type {
    return struct {
        fn call(argv: []repr.Value) raise.Error!repr.Value {
            try args_core.arity(argv, 2, -1);
            var acc: u64 = @bitCast(try Box(T).unwrap(argv[0]));
            for (argv[1..]) |arg| {
                acc = applyBin(op, acc, @bitCast(try Box(T).unwrap(arg)));
            }
            return Box(T).make(@bitCast(acc));
        }
    };
}

/// Builds the `r`-prefixed form of `OpMethod`, which the interpreter reaches
/// when the boxed integer is the right operand, so the arguments swap. It is
/// fixed-arity where the plain form is variadic.
fn OpMethodInvert(comptime T: type, comptime op: BinOp) type {
    return struct {
        fn call(argv: []repr.Value) raise.Error!repr.Value {
            try args_core.fixarity(argv, 2);
            const lhs: u64 = @bitCast(try Box(T).unwrap(argv[1]));
            const rhs: u64 = @bitCast(try Box(T).unwrap(argv[0]));
            return Box(T).make(@bitCast(applyBin(op, lhs, rhs)));
        }
    };
}

/// One instantiation of each generated method at `i64`, named by the row it
/// fills in `s64_methods`.
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

/// One instantiation of each generated method at `u64`, named by the row it
/// fills in `u64_methods`.
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

// ==========================================================================
// Public functions
// ==========================================================================

/// Compares a signed 64-bit integer with a double.
///
/// Inside the double's contiguous integer range the comparison is exact once
/// the integer is widened. Outside it, widening would round, so the double is
/// narrowed instead, which is safe only after the infinite and out-of-range
/// cases have been separated out.
pub fn compareS64Double(x: i64, y: f64) c_int {
    if (std.math.isNan(y)) return 0;
    if (y > intmin_double and y < intmax_double) {
        return compareDoubles(@floatFromInt(x), y);
    }
    if (y >= s64_limit) return -1;
    if (y < @as(f64, @floatFromInt(std.math.minInt(i64)))) return 1;
    return compareScalar(i64, x, @intFromFloat(y));
}

/// Compares across the two integer types, where neither range contains the
/// other.
pub fn compareS64U64(x: i64, y: u64) c_int {
    if (x < 0) return -1;
    if (y > std.math.maxInt(i64)) return -1;
    return compareScalar(i64, x, @intCast(y));
}

/// Compares an unsigned 64-bit integer with a double, the same way
/// `compareS64Double` does.
pub fn compareU64Double(x: u64, y: f64) c_int {
    if (std.math.isNan(y)) return 0;
    if (y < 0) return 1;
    if (y < intmax_double) {
        return compareDoubles(@floatFromInt(x), y);
    }
    if (y >= u64_limit) return -1;
    return compareScalar(u64, x, @intFromFloat(y));
}

/// The inverse of `compareS64U64`.
pub fn compareU64S64(x: u64, y: i64) c_int {
    if (y < 0) return 1;
    if (x > std.math.maxInt(i64)) return 1;
    return compareScalar(i64, @intCast(x), y);
}

/// Writes the decimal form of `val` into space the caller reserved, returning
/// its length.
///
/// `itS64Tostring` does the reserving, because that is the half that can
/// raise; this half cannot, so it stays a plain function.
pub fn formatS64(val: i64, out: [*]u8) i32 {
    return c.snprintf(out, 32, "%lld", val);
}

/// The unsigned form of `formatS64`, with the same reservation rule.
pub fn formatU64(val: u64, out: [*]u8) i32 {
    return c.snprintf(out, 32, "%llu", val);
}

/// Which of the two integer types `x` is an abstract of, or `.none`.
pub fn isInt(x: repr.Value) constants.IntType {
    if (!repr.checkType(x, repr.Tag.abstract)) return .none;
    const at = abi.abstractHead(wrap.toAbstract(x)).type;
    if (at == &s64Type) return .s64;
    if (at == &u64Type) return .u64;
    return .none;
}

/// Installs the `int/` nfunctions into `env` and registers both abstract
/// types.
pub fn libInttypes(env: *tables.Table) raise.Error!void {
    const entries = comptime [_]corefn.Entry{
        corefn.reg("int/s64", &nfunS64New, @src(), "(int/s64 value)", "Create a boxed signed 64 bit integer from a string value or a number."),
        corefn.reg("int/u64", &nfunU64New, @src(), "(int/u64 value)", "Create a boxed unsigned 64 bit integer from a string value or a number."),
        corefn.reg("int/to-number", &nfunToNumber, @src(), "(int/to-number value)", "Convert an int/u64 or int/s64 to a number. Fails if the number is out of range for an int64."),
        corefn.reg("int/to-bytes", &nfunToBytes, @src(), "(int/to-bytes value &opt endianness buffer)", "Write the bytes of an `int/s64` or `int/u64` into a buffer.\n" ++
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

/// Floored division. The caller rejects a zero divisor first.
///
/// Truncating division rounds toward zero, so a negative quotient with a
/// remainder is one step above the floor.
pub fn s64Divf(op1: i64, op2: i64) i64 {
    const x = @divTrunc(op1, op2);
    const negative_quotient = (op1 ^ op2) < 0;
    const inexact = x *% op2 != op1;
    return x -% @intFromBool(negative_quotient and inexact);
}

/// Floored modulo, which takes the sign of the divisor rather than of the
/// dividend. A zero divisor returns the dividend unchanged, deliberately.
pub fn s64Mod(op1: i64, op2: i64) i64 {
    if (op2 == 0) return op1;
    const x = @rem(op1, op2);
    if ((op1 ^ op2) < 0 and x != 0) return x +% op2;
    return x;
}

/// Converts `x` to a signed 64-bit integer, raising where it will not convert.
///
/// A number, a string of digits, and a box of either type all convert. A box's
/// payload is reinterpreted rather than range-checked, so
/// `(int/s64 (int/u64 0xFFFFFFFFFFFFFFFF))` is -1 rather than an error, which
/// is what a program sees.
pub fn unwrapS64(x: repr.Value) raise.Error!i64 {
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

/// The unsigned form of `unwrapS64`, with the same reinterpretation rule.
pub fn unwrapU64(x: repr.Value) raise.Error!u64 {
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

/// Boxes `x` as an `int/s64`.
pub fn wrapS64(x: i64) repr.Value {
    return boxed(i64, &s64Type, x);
}

/// Boxes `x` as an `int/u64`.
pub fn wrapU64(x: u64) repr.Value {
    return boxed(u64, &u64Type, x);
}

// ==========================================================================
// Private functions
// ==========================================================================

/// Applies `op` to two operands already widened to `u64`.
fn applyBin(comptime op: BinOp, lhs: u64, rhs: u64) u64 {
    return switch (op) {
        .add => lhs +% rhs,
        .sub => lhs -% rhs,
        .mul => lhs *% rhs,
        .band => lhs & rhs,
        .bor => lhs | rhs,
        .bxor => lhs ^ rhs,
        // The count is taken modulo the operand's width, which is what the
        // interpreter's own `<<` on an ordinary integer gives at 32 bits and
        // what both supported architectures' shift instructions give.
        // `@truncate` decides a count at or beyond the width, once, for every
        // build.
        .shl => lhs << @truncate(rhs),
        .shr => lhs >> @truncate(rhs),
    };
}

/// Allocates a boxed integer of the abstract type `at`.
fn boxed(comptime T: type, at: *const abi.AbstractType, val: T) repr.Value {
    const p: *T = abstracts.newFor(T, at);
    p.* = val;
    return wrap.fromAbstract(p);
}

/// The `compare` method of `int/s64`, which orders a box against a number, an
/// `int/s64` or an `int/u64`, and returns nil for anything else.
fn nfunS64Compare(argv: []repr.Value) raise.Error!repr.Value {
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

/// `div`: floored division, refusing a zero divisor.
fn nfunS64Divf(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 2);
    const op1 = try unwrapS64(argv[0]);
    const op2 = try unwrapS64(argv[1]);
    if (op2 == 0) return raise.panic("division by zero");
    try divCheck(op1, op2);
    return boxed(i64, &s64Type, s64Divf(op1, op2));
}

/// `rdiv`: `div` with the operands swapped.
fn nfunS64Divfi(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 2);
    const op2 = try unwrapS64(argv[0]);
    const op1 = try unwrapS64(argv[1]);
    if (op2 == 0) return raise.panic("division by zero");
    try divCheck(op1, op2);
    return boxed(i64, &s64Type, s64Divf(op1, op2));
}

/// `mod`: floored modulo, which returns the dividend for a zero divisor.
fn nfunS64Mod(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 2);
    const op1 = try unwrapS64(argv[0]);
    const op2 = try unwrapS64(argv[1]);
    try divCheck(op1, op2);
    return boxed(i64, &s64Type, s64Mod(op1, op2));
}

/// `rmod`: `mod` with the operands swapped.
fn nfunS64Modi(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 2);
    const op2 = try unwrapS64(argv[0]);
    const op1 = try unwrapS64(argv[1]);
    try divCheck(op1, op2);
    return boxed(i64, &s64Type, s64Mod(op1, op2));
}

/// `int/s64`: a boxed signed integer from a number, a string or another box.
fn nfunS64New(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    return wrapS64(try unwrapS64(argv[0]));
}

/// `int/to-bytes`: the eight bytes of a box, in a chosen order, appended to a
/// buffer.
fn nfunToBytes(argv: []repr.Value) raise.Error!repr.Value {
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

/// `int/to-number`: a box as a double, refusing one that would not survive the
/// conversion.
///
/// The bound is `intmax_int64` and not `maxInt(i64)`: beyond it a double
/// cannot tell neighbouring integers apart, so the conversion would silently
/// round.
fn nfunToNumber(argv: []repr.Value) raise.Error!repr.Value {
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

/// The `compare` method of `int/u64`, the unsigned twin of `nfunS64Compare`.
fn nfunU64Compare(argv: []repr.Value) raise.Error!repr.Value {
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

/// `int/u64`: a boxed unsigned integer from a number, a string or another box.
fn nfunU64New(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    return wrapU64(try unwrapU64(argv[0]));
}

/// Whether `d` is an integer a signed 64-bit box represents exactly.
fn checkInt64Range(d: f64) bool {
    if (!(d >= intmin_double and d <= intmax_double)) return false;
    return d == @as(f64, @floatFromInt(@as(i64, @intFromFloat(d))));
}

/// Whether `d` is an integer an unsigned 64-bit box represents exactly.
fn checkUint64Range(d: f64) bool {
    if (!(d >= 0 and d <= intmax_double)) return false;
    return d == @as(f64, @floatFromInt(@as(u64, @intFromFloat(d))));
}

/// Orders two doubles, with NaN comparing equal to everything.
fn compareDoubles(x: f64, y: f64) c_int {
    if (x < y) return -1;
    return if (x > y) 1 else 0;
}

/// Orders two values of one scalar type, three-valued.
fn compareScalar(comptime T: type, x: T, y: T) c_int {
    if (x == y) return 0;
    return if (x < y) -1 else 1;
}

/// Refuses the one signed division with no representable result.
///
/// `minInt(i64) / -1` overflows, so every method that can reach it refuses it
/// first. The four hand-written division methods call this where the generated
/// `/` and `%` make the same test inline; without it `@divTrunc` and `@rem`
/// have illegal behaviour there.
fn divCheck(op1: i64, op2: i64) raise.Error!void {
    if (op2 == -1 and op1 == std.math.minInt(i64)) {
        return raise.panic("INT64_MIN divided by -1");
    }
}

/// `int/s64`'s `next` method: the name of the method after `key` in the table.
fn int64Next(_: *i64, key: repr.Value) raise.Error!repr.Value {
    return args_core.nextmethod(@ptrCast(&s64_methods), key);
}

/// `int/s64`'s `get` callback: a method looked up by name.
fn itS64Get(_: *i64, key: repr.Value) raise.Error!?repr.Value {
    return args_core.findMethod(key, @ptrCast(&s64_methods));
}

/// `int/s64`'s `tostring` callback.
///
/// The `abi.Render` slot is the capability a module author is offered in place
/// of the buffer's layout. These two types are the runtime's own and never
/// cross, so this recovers `buffers.Buffer` on its first line and pushes with
/// an ordinary Zig call.
///
/// Reserving 32 bytes is what makes writing straight into
/// `buffer.data + buffer.count` safe: the longest decimal rendering of a
/// 64-bit integer is 20 characters.
fn itS64Tostring(box: *i64, render: *abi.Render) raise.Error!void {
    const buffer: *buffers.Buffer = @ptrCast(@alignCast(render));
    try buffers.extra(buffer, 32);
    buffer.count += @intCast(formatS64(box.*, buffer.data.? + @as(usize, @intCast(buffer.count))));
}

/// `int/u64`'s `get` callback: a method looked up by name.
fn itU64Get(_: *u64, key: repr.Value) raise.Error!?repr.Value {
    return args_core.findMethod(key, @ptrCast(&u64_methods));
}

/// `int/u64`'s `tostring` callback, the unsigned twin of `itS64Tostring`.
fn itU64Tostring(box: *u64, render: *abi.Render) raise.Error!void {
    const buffer: *buffers.Buffer = @ptrCast(@alignCast(render));
    try buffers.extra(buffer, 32);
    buffer.count += @intCast(formatU64(box.*, buffer.data.? + @as(usize, @intCast(buffer.count))));
}

/// Builds one method table row.
fn method(comptime name: [:0]const u8, comptime f: anytype) method_type.Method {
    return .{ .name = name, .nfun = f };
}

/// The refusal `nfunToNumber` raises for a box outside a double's exact range.
fn outOfRange(x: repr.Value) raise.Error {
    return pp_format.panicf("cannot convert %q to a number, must be in the range [%q, %q]", .{ x, wrap.fromNumber(-9007199254740992.0), wrap.fromNumber(9007199254740992.0) });
}

/// The three-way comparison every same-type comparison goes through, as the
/// double a `compare` method returns.
fn threeWay(comptime T: type, x: T, y: T) f64 {
    if (x < y) return -1;
    if (x > y) return 1;
    return 0;
}

/// `int/u64`'s `next` method: the name of the method after `key` in the table.
fn uint64Next(_: *u64, key: repr.Value) raise.Error!repr.Value {
    return args_core.nextmethod(@ptrCast(&u64_methods), key);
}
