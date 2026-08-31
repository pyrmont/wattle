//! Janet's pseudo-random number generator and the numeric kernels behind the
//! `math/` library.
//!
//! The RNG is public C ABI and its state is marshalled, so this is bit-exact
//! with Janet by construction rather than by convention.
//!
//! The `math/` cfunctions are at the foot of the file, along with the RNG
//! abstract type. Their bodies are argument extraction that raises on a type
//! or arity mismatch, which is an ordinary returned error here.

const std = @import("std");
const corefn = @import("corefn");
const types = @import("types");
const repr = @import("repr");
const c = @import("cabi");
const vm_state = @import("vm/lifecycle.zig");
const buffers = @import("value/buffers.zig");
const raise = @import("raise");
const registry = @import("registry.zig");
const marsh = @import("marsh.zig");
const abstract_type = @import("abstract_type.zig");
const method_type = @import("method_type.zig");
const builtin = @import("builtin");
const tuples = @import("value/tuples.zig");
const wrap = @import("value/helpers/wrap.zig");
const args_core = @import("args.zig");
const abstracts = @import("value/abstracts.zig");

extern fn ldexp(val: f64, exponent: c_int) callconv(.c) f64;
extern fn fmod(numerator: f64, denominator: f64) callconv(.c) f64;

/// Algorithm "xorwow" from p. 5 of Marsaglia, "Xorshift RNGs".
pub fn rngU32(rng: *types.JanetRNG) u32 {
    var t = rng.d;
    const s = rng.a;
    rng.d = rng.c;
    rng.c = rng.b;
    rng.b = s;
    t ^= t >> 2;
    t ^= t << 1;
    t ^= s ^ (s << 4);
    rng.a = t;
    rng.counter +%= 362437;
    return t +% rng.counter;
}

pub fn rngSeed(rng: *types.JanetRNG, seed: u32) void {
    rng.a = seed;
    rng.b = 0x97654321;
    rng.c = 123871873;
    rng.d = 0xf23f56c8;
    rng.counter = 0;
    // The first several numbers aren't that random.
    for (0..16) |_| _ = rngU32(rng);
}

pub fn rngLongseed(rng: *types.JanetRNG, bytes: []const u8) void {
    var state: [16]u8 = @splat(0);
    for (bytes, 0..) |byte, index| {
        state[index & 0xF] ^= byte;
    }
    rng.a = std.mem.readInt(u32, state[0..4], .little);
    rng.b = std.mem.readInt(u32, state[4..8], .little);
    rng.c = std.mem.readInt(u32, state[8..12], .little);
    rng.d = std.mem.readInt(u32, state[12..16], .little);
    rng.counter = 0;
    // a, b, c, and d cannot all be zero.
    if (rng.a == 0) rng.a = 1;
    for (0..16) |_| _ = rngU32(rng);
}

pub fn rngDouble(rng: *types.JanetRNG) f64 {
    const hi: u64 = rngU32(rng);
    const lo: u64 = rngU32(rng);
    const big = lo | (hi << 32);
    return ldexp(@floatFromInt(big >> (64 - 52)), -52);
}

/// Draw a uniform integer in [0, max) for max > 0, rejecting the tail of the
/// generator's range that would otherwise bias the modulus.
pub fn zigMathRngInt(rng: *types.JanetRNG, max: i32) i32 {
    const modulo: u32 = @bitCast(max);
    const maxgen: u32 = std.math.maxInt(i32);
    const maxword = maxgen - (maxgen % modulo);
    var word: u32 = undefined;
    while (true) {
        word = rngU32(rng) >> 1;
        if (word <= maxword) break;
    }
    return @bitCast(word % modulo);
}

/// Write `count` random bytes. Callers reserve the space first, because the
/// reservation can panic.
pub fn zigMathRngFill(rng: *types.JanetRNG, out: [*]u8, count: i32) void {
    const total: usize = @intCast(count);
    var index: usize = 0;
    while (index + 4 <= total) : (index += 4) {
        std.mem.writeInt(u32, out[index..][0..4], rngU32(rng), .little);
    }
    if (index < total) {
        var word: [4]u8 = undefined;
        std.mem.writeInt(u32, &word, rngU32(rng), .little);
        @memcpy(out[index..total], word[0 .. total - index]);
    }
}

pub fn zigMathGcd(x_in: f64, y_in: f64) f64 {
    var x = x_in;
    var y = y_in;
    if (std.math.isNan(x) or std.math.isNan(y)) return std.math.nan(f64);
    if (std.math.isInf(x) or std.math.isInf(y)) return std.math.inf(f64);
    while (y != 0) {
        const temp = y;
        y = fmod(x, y);
        x = temp;
    }
    return x;
}

pub fn zigMathLcm(x: f64, y: f64) f64 {
    return (x / zigMathGcd(x, y)) * y;
}

// ==========================================================================
// math/*, `not`, and the RNG abstract type: the cfunction surface.
//
// `math.zig` owns the generator, the two kernels above, and the
// standard-library surface over them.
//
// One consequence is visible in `cfunRngBuffer` below. Janet reserves the
// buffer space on its side of a seam with a comment saying why -- "a Janet
// signal must not unwind across a Zig frame". The reservation stays where it
// is because `janet_buffer_extra` is still what grows the buffer, but it is an
// ordinary call in an ordinary frame rather than a boundary arrangement.
// ==========================================================================

const plan9 = (builtin.os.tag == .plan9);

/// `JANET_DEFINE_MATHOP` and `JANET_DEFINE_NAMED_MATHOP`: one argument in, one
/// double out, through the C library function of the same name.
///
/// The libm function is called rather than Zig's `@sin` and friends, and the
/// difference is not stylistic: `-Dmath-core=c` and the default have to agree
/// bit for bit, and the only way to guarantee that is for both to reach the
/// same implementation.
fn MathOp(comptime fop: anytype) type {
    return struct {
        fn call(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
            try args_core.fixarity(argv, 1);
            return wrap.fromNumber(fop(try args_core.getNumber(argv, 0)));
        }
    };
}

/// `JANET_DEFINE_MATH2OP`.
fn Math2Op(comptime fop: anytype) type {
    return struct {
        fn call(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
            try args_core.fixarity(argv, 2);
            const lhs = try args_core.getNumber(argv, 0);
            const rhs = try args_core.getNumber(argv, 1);
            return wrap.fromNumber(fop(lhs, rhs));
        }
    };
}

inline fn wrapInteger(x: i32) repr.Value {
    return wrap.fromNumber(@floatFromInt(x));
}

// ------------------------------------------------------------ the RNG type

const rng_methods = [_]method_type.Method{
    .{ .name = "uniform", .cfun = &cfunRngUniform },
    .{ .name = "int", .cfun = &cfunRngInt },
    .{ .name = "buffer", .cfun = &cfunRngBuffer },
    .{ .name = null, .cfun = null },
};

fn rngGet(_: *types.JanetRNG, key: repr.Value, out: *repr.Value) raise.Raising(c_int) {
    if (!repr.checkType(key, repr.Tag.keyword)) return 0;
    return args_core.getmethod(wrap.toKeyword(key), @ptrCast(&rng_methods), out);
}

fn rngNext(_: *types.JanetRNG, key: repr.Value) raise.Raising(repr.Value) {
    return args_core.nextmethod(@ptrCast(&rng_methods), key);
}

fn rngMarshal(rng: *types.JanetRNG, ctx: *types.JanetMarshalContext) raise.Raising(void) {
    marsh.marshalAbstract(ctx, rng);
    try marsh.marshalInt(ctx, @bitCast(rng.a));
    try marsh.marshalInt(ctx, @bitCast(rng.b));
    try marsh.marshalInt(ctx, @bitCast(rng.c));
    try marsh.marshalInt(ctx, @bitCast(rng.d));
    try marsh.marshalInt(ctx, @bitCast(rng.counter));
}

fn rngUnmarshal(ctx: *types.JanetMarshalContext) raise.Raising(*types.JanetRNG) {
    const rng: *types.JanetRNG = @ptrCast(@alignCast(try marsh.unmarshalAbstract(ctx, @sizeOf(types.JanetRNG))));
    rng.a = @bitCast(try marsh.unmarshalInt(ctx));
    rng.b = @bitCast(try marsh.unmarshalInt(ctx));
    rng.c = @bitCast(try marsh.unmarshalInt(ctx));
    rng.d = @bitCast(try marsh.unmarshalInt(ctx));
    rng.counter = @bitCast(try marsh.unmarshalInt(ctx));
    return rng;
}

/// Exported under C's name because `marsh.zig` looks abstract types up by
/// address and eleven of them are published as data symbols.
pub const rngType = abstract_type.define(types.JanetRNG, .{
    .name = "core/rng",
    .get = &rngGet,
    .marshal = &rngMarshal,
    .unmarshal = &rngUnmarshal,
    .next = &rngNext,
});

// ----------------------------------------------------------- the cfunctions

fn cfunRngMake(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.arity(argv, 0, 1);
    const rng: *types.JanetRNG = @ptrCast(@alignCast(abstracts.new(&rngType, @sizeOf(types.JanetRNG))));
    if (@as(i32, @intCast(argv.len)) == 1) {
        if (args_core.checkint(argv[0]) != 0) {
            rngSeed(rng, @bitCast(try args_core.getInteger(argv, 0)));
        } else {
            const bytes = try args_core.getBytes(argv, 0);
            rngLongseed(rng, args_core.viewBytes(bytes));
        }
    } else {
        rngSeed(rng, 0);
    }
    return wrap.fromAbstract(rng);
}

fn cfunRngUniform(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    const rng: *types.JanetRNG = @ptrCast(@alignCast(try args_core.getAbstract(argv, 0, &rngType)));
    return wrap.fromNumber(rngDouble(rng));
}

fn cfunRngInt(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.arity(argv, 1, 2);
    const rng: *types.JanetRNG = @ptrCast(@alignCast(try args_core.getAbstract(argv, 0, &rngType)));
    if (@as(i32, @intCast(argv.len)) == 1) return wrapInteger(@bitCast(rngU32(rng) >> 1));
    const max = try args_core.optNat(argv, 1, std.math.maxInt(i32));
    if (max == 0) return wrap.fromNumber(0.0);
    return wrapInteger(zigMathRngInt(rng, max));
}

fn cfunRngBuffer(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.arity(argv, 2, 3);
    const rng: *types.JanetRNG = @ptrCast(@alignCast(try args_core.getAbstract(argv, 0, &rngType)));
    const n = try args_core.getNat(argv, 1);
    const buffer = try args_core.optBuffer(argv, 2, n);
    try buffers.extra(buffer, n);
    zigMathRngFill(rng, buffer.*.data.? + @as(usize, @intCast(buffer.*.count)), n);
    buffer.*.count += n;
    return wrap.fromBuffer(buffer);
}

fn cfunRand(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 0);
    return wrap.fromNumber(rngDouble(&vm_state.current().rng));
}

fn cfunSrand(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    if (args_core.checkint(argv[0]) != 0) {
        rngSeed(&vm_state.current().rng, @bitCast(try args_core.getInteger(argv, 0)));
    } else {
        const bytes = try args_core.getBytes(argv, 0);
        rngLongseed(&vm_state.current().rng, args_core.viewBytes(bytes));
    }
    return wrap.fromNil();
}

fn cfunNot(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    return wrap.fromBoolean(!repr.truthy(argv[0]));
}

fn cfunGcd(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 2);
    return wrap.fromNumber(zigMathGcd(try args_core.getNumber(argv, 0), try args_core.getNumber(argv, 1)));
}

fn cfunLcm(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 2);
    return wrap.fromNumber(zigMathLcm(try args_core.getNumber(argv, 0), try args_core.getNumber(argv, 1)));
}

fn cfunFrexp(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    var exp: c_int = undefined;
    const mantissa = c.frexp(try args_core.getNumber(argv, 0), &exp);
    const result = tuples.begin(2);
    result[0] = wrap.fromNumber(mantissa);
    result[1] = wrap.fromNumber(@floatFromInt(exp));
    return wrap.fromTuple(tuples.end(result));
}

fn cfunLdexp(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 2);
    const x = try args_core.getNumber(argv, 0);
    const y = try args_core.getInteger(argv, 1);
    return wrap.fromNumber(c.ldexp(x, y));
}

/// One row per math op, so the table and the implementations cannot drift:
/// the name, the libm function and the docstring are given once and the
/// cfunction is generated from them.
///
/// `JANET_PLAN9` drops nine of these in the C original, and the entries are
/// dropped here the same way. Plan 9 is not a target this build supports, but
/// the guard is reproduced rather than deleted -- removing a configuration is
/// not a port decision.
const MathEntry = struct {
    janet_name: [:0]const u8,
    fop: *const fn (f64) callconv(.c) f64,
    doc: [:0]const u8,
    plan9_only_absent: bool = false,
};

pub fn libMath(env: *types.JanetTable) raise.Raising(void) {
    const ops = [_]MathEntry{
        .{ .janet_name = "acos", .fop = &c.acos, .doc = "Returns the arccosine of x." },
        .{ .janet_name = "asin", .fop = &c.asin, .doc = "Returns the arcsin of x." },
        .{ .janet_name = "atan", .fop = &c.atan, .doc = "Returns the arctangent of x." },
        .{ .janet_name = "cos", .fop = &c.cos, .doc = "Returns the cosine of x." },
        .{ .janet_name = "cosh", .fop = &c.cosh, .doc = "Returns the hyperbolic cosine of x." },
        .{ .janet_name = "acosh", .fop = &c.acosh, .doc = "Returns the hyperbolic arccosine of x." },
        .{ .janet_name = "sin", .fop = &c.sin, .doc = "Returns the sine of x." },
        .{ .janet_name = "sinh", .fop = &c.sinh, .doc = "Returns the hyperbolic sine of x." },
        .{ .janet_name = "tan", .fop = &c.tan, .doc = "Returns the tangent of x." },
        .{ .janet_name = "tanh", .fop = &c.tanh, .doc = "Returns the hyperbolic tangent of x." },
        .{ .janet_name = "exp", .fop = &c.exp, .doc = "Returns e to the power of x." },
        .{ .janet_name = "exp2", .fop = &c.exp2, .doc = "Returns 2 to the power of x." },
        .{ .janet_name = "log1p", .fop = &c.log1p, .doc = "Returns (log base e of x) + 1 more accurately than (+ (math/log x) 1)" },
        .{ .janet_name = "log", .fop = &c.log, .doc = "Returns the natural logarithm of x." },
        .{ .janet_name = "log10", .fop = &c.log10, .doc = "Returns the log base 10 of x." },
        .{ .janet_name = "log2", .fop = &c.log2, .doc = "Returns the log base 2 of x." },
        .{ .janet_name = "sqrt", .fop = &c.sqrt, .doc = "Returns the square root of x." },
        .{ .janet_name = "ceil", .fop = &c.ceil, .doc = "Returns the smallest integer value number that is not less than x." },
        .{ .janet_name = "floor", .fop = &c.floor, .doc = "Returns the largest integer value number that is not greater than x." },
        .{ .janet_name = "trunc", .fop = &c.trunc, .doc = "Returns the integer between x and 0 nearest to x." },
        .{ .janet_name = "round", .fop = &c.round, .doc = "Returns the integer nearest to x." },
        .{ .janet_name = "abs", .fop = &c.fabs, .doc = "Return the absolute value of x." },
    };
    const plan9_absent_ops = [_]MathEntry{
        .{ .janet_name = "expm1", .fop = &c.expm1, .doc = "Returns e to the power of x minus 1." },
        .{ .janet_name = "cbrt", .fop = &c.cbrt, .doc = "Returns the cube root of x." },
        .{ .janet_name = "erf", .fop = &c.erf, .doc = "Returns the error function of x." },
        .{ .janet_name = "erfc", .fop = &c.erfc, .doc = "Returns the complementary error function of x." },
        .{ .janet_name = "log-gamma", .fop = &c.lgamma, .doc = "Returns log-gamma(x)." },
        .{ .janet_name = "gamma", .fop = &c.tgamma, .doc = "Returns gamma(x)." },
        .{ .janet_name = "atanh", .fop = &c.atanh, .doc = "Returns the hyperbolic arctangent of x." },
        .{ .janet_name = "asinh", .fop = &c.asinh, .doc = "Returns the hyperbolic arcsine of x." },
    };

    const two_arg = [_]struct {
        janet_name: [:0]const u8,
        fop: *const fn (f64, f64) callconv(.c) f64,
        usage: [:0]const u8,
        doc: [:0]const u8,
    }{
        .{ .janet_name = "atan2", .fop = &c.atan2, .usage = "(math/atan2 y x)", .doc = "Returns the arctangent of y/x. Works even when x is 0." },
        .{ .janet_name = "pow", .fop = &c.pow, .usage = "(math/pow a x)", .doc = "Returns a to the power of x." },
        .{ .janet_name = "hypot", .fop = &c.hypot, .usage = "(math/hypot a b)", .doc = "Returns c from the equation c^2 = a^2 + b^2." },
    };

    // The table is built at comptime so that every `corefn.reg` still gets a
    // literal name, usage and docstring: `@src()` cannot be taken in a loop
    // that means anything, so each generated row records this line and the
    // hand-written rows below record their own.
    const generated = comptime blk: {
        var list: []const corefn.Entry = &.{};
        for (ops) |op| {
            list = list ++ [_]corefn.Entry{corefn.reg(
                "math/" ++ op.janet_name,
                &MathOp(op.fop).call,
                @src(),
                "(math/" ++ op.janet_name ++ " x)",
                op.doc,
            )};
        }
        if (!plan9) for (plan9_absent_ops) |op| {
            list = list ++ [_]corefn.Entry{corefn.reg(
                "math/" ++ op.janet_name,
                &MathOp(op.fop).call,
                @src(),
                "(math/" ++ op.janet_name ++ " x)",
                op.doc,
            )};
        };
        for (two_arg) |op| {
            list = list ++ [_]corefn.Entry{corefn.reg(
                "math/" ++ op.janet_name,
                &Math2Op(op.fop).call,
                @src(),
                op.usage,
                op.doc,
            )};
        }
        if (!plan9) list = list ++ [_]corefn.Entry{corefn.reg(
            "math/next",
            &Math2Op(&c.nextafter).call,
            @src(),
            "(math/next x y)",
            "Returns the next representable floating point value after x in the direction of y.",
        )};
        break :blk list;
    };

    const written = comptime [_]corefn.Entry{
        corefn.reg("not", &cfunNot, @src(), "(not x)", "Returns the boolean inverse of x."),
        corefn.reg("math/random", &cfunRand, @src(), "(math/random)", "Returns a uniformly distributed random number between 0 and 1."),
        corefn.reg("math/seedrandom", &cfunSrand, @src(), "(math/seedrandom seed)", "Set the seed for the random number generator. `seed` should be " ++
            "an integer or a buffer."),
        corefn.reg("math/rng", &cfunRngMake, @src(), "(math/rng &opt seed)", "Creates a Pseudo-Random number generator, with an optional seed. " ++
            "The seed should be an unsigned 32 bit integer or a buffer. " ++
            "Do not use this for cryptography. Returns a core/rng abstract type."),
        corefn.reg("math/rng-uniform", &cfunRngUniform, @src(), "(math/rng-uniform rng)", "Extract a random number in the range [0, 1) from the RNG."),
        corefn.reg("math/rng-int", &cfunRngInt, @src(), "(math/rng-int rng &opt max)", "Extract a random integer in the range [0, max) for max > 0 from the RNG.  " ++
            "If max is 0, return 0.  If no max is given, the default is 2^31 - 1."),
        corefn.reg("math/rng-buffer", &cfunRngBuffer, @src(), "(math/rng-buffer rng n &opt buf)", "Get n random bytes and put them in a buffer. Creates a new buffer if no buffer is " ++
            "provided, otherwise appends to the given buffer. Returns the buffer."),
        corefn.reg("math/gcd", &cfunGcd, @src(), "(math/gcd x y)", "Returns the greatest common divisor between x and y."),
        corefn.reg("math/lcm", &cfunLcm, @src(), "(math/lcm x y)", "Returns the least common multiple of x and y."),
        corefn.reg("math/frexp", &cfunFrexp, @src(), "(math/frexp x)", "Returns a tuple of (mantissa, exponent) from number."),
        corefn.reg("math/ldexp", &cfunLdexp, @src(), "(math/ldexp m e)", "Creates a new number from a mantissa and an exponent."),
    };

    corefn.install(env, generated ++ written);
    try registry.registerAbstractType(&rngType);

    // Bootstrap-only, exactly as in the C original: the runtime finds these in
    // the image and defining them again would be work with no effect.
    const inf = std.math.inf(f64);
    corefn.def(env, "math/pi", wrap.fromNumber(3.1415926535897931), @src(), "The value pi.");
    corefn.def(env, "math/e", wrap.fromNumber(2.7182818284590451), @src(), "The base of the natural log.");
    corefn.def(env, "math/inf", wrap.fromNumber(inf), @src(), "The number representing positive infinity");
    corefn.def(env, "math/-inf", wrap.fromNumber(-inf), @src(), "The number representing negative infinity");
    corefn.def(env, "math/int32-min", wrap.fromNumber(@floatFromInt(std.math.minInt(i32))), @src(), "The minimum contiguous integer representable by a 32 bit signed integer");
    corefn.def(env, "math/int32-max", wrap.fromNumber(@floatFromInt(std.math.maxInt(i32))), @src(), "The maximum contiguous integer representable by a 32 bit signed integer");
    corefn.def(env, "math/int-min", wrap.fromNumber(-9007199254740992.0), @src(), "The minimum contiguous integer representable by a double (-(2^53))");
    corefn.def(env, "math/int-max", wrap.fromNumber(9007199254740992.0), @src(), "The maximum contiguous integer representable by a double (2^53)");
    corefn.def(env, "math/nan", wrap.fromNumber(std.math.nan(f64)), @src(), "Not a number (IEEE-754 NaN)");
}

pub fn libMathAbi(env: *types.JanetTable) void {
    raise.reported(libMath(env));
}

/// `janet_default_rng`. The VM's own generator, which `math/seed` and
/// `math/random` use when no explicit `JanetRNG` is given.
///
/// It was the last symbol `math.c` defined, and it was there only because
/// `janet_vm` was C's. It is one field access.
pub fn defaultRng() *types.JanetRNG {
    return &vm_state.current().rng;
}
