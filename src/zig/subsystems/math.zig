//! Janet's pseudo-random number generator and the numeric kernels behind the
//! `math/` library.
//!
//! The RNG is public C ABI and its state is marshalled, so this port is
//! bit-exact with the C original by construction rather than by convention.
//! None of these functions touch Janet values or raise signals.
//!
//! The `math/` cfunctions themselves stayed in C, because their bodies are
//! argument extraction that panics on a type or arity mismatch and no Janet
//! signal could then unwind across a Zig frame. Phase 10 Part 6 brought them
//! here, at the foot of the file, along with the RNG abstract type; jump
//! transparency is what makes a frame that raises legal.

const std = @import("std");
const abi = @import("abi");
const corefn = @import("corefn");
const c = abi.c;
const marshalling = @import("marshalling.zig");
const containers = @import("containers.zig");
const raise = @import("raise");
const registration = @import("registration.zig");
const arglayer = @import("arglayer.zig");
const marsh = @import("marsh.zig");
const abstract_type = @import("abstract_type.zig");

extern fn ldexp(value: f64, exponent: c_int) callconv(.c) f64;
extern fn fmod(numerator: f64, denominator: f64) callconv(.c) f64;

/// Algorithm "xorwow" from p. 5 of Marsaglia, "Xorshift RNGs".
export fn janet_rng_u32(rng: *c.JanetRNG) callconv(.c) u32 {
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

export fn janet_rng_seed(rng: *c.JanetRNG, seed: u32) callconv(.c) void {
    rng.a = seed;
    rng.b = 0x97654321;
    rng.c = 123871873;
    rng.d = 0xf23f56c8;
    rng.counter = 0;
    // The first several numbers aren't that random.
    for (0..16) |_| _ = janet_rng_u32(rng);
}

export fn janet_rng_longseed(rng: *c.JanetRNG, bytes: [*c]const u8, len: i32) callconv(.c) void {
    var state: [16]u8 = @splat(0);
    var index: i32 = 0;
    while (index < len) : (index += 1) {
        state[@intCast(index & 0xF)] ^= bytes[@intCast(index)];
    }
    rng.a = std.mem.readInt(u32, state[0..4], .little);
    rng.b = std.mem.readInt(u32, state[4..8], .little);
    rng.c = std.mem.readInt(u32, state[8..12], .little);
    rng.d = std.mem.readInt(u32, state[12..16], .little);
    rng.counter = 0;
    // a, b, c, and d cannot all be zero.
    if (rng.a == 0) rng.a = 1;
    for (0..16) |_| _ = janet_rng_u32(rng);
}

export fn janet_rng_double(rng: *c.JanetRNG) callconv(.c) f64 {
    const hi: u64 = janet_rng_u32(rng);
    const lo: u64 = janet_rng_u32(rng);
    const big = lo | (hi << 32);
    return ldexp(@floatFromInt(big >> (64 - 52)), -52);
}

/// Draw a uniform integer in [0, max) for max > 0, rejecting the tail of the
/// generator's range that would otherwise bias the modulus.
export fn janet_zig_math_rng_int(rng: *c.JanetRNG, max: i32) callconv(.c) i32 {
    const modulo: u32 = @bitCast(max);
    const maxgen: u32 = std.math.maxInt(i32);
    const maxword = maxgen - (maxgen % modulo);
    var word: u32 = undefined;
    while (true) {
        word = janet_rng_u32(rng) >> 1;
        if (word <= maxword) break;
    }
    return @bitCast(word % modulo);
}

/// Write `count` random bytes. Callers reserve the space first, because the
/// reservation can panic.
export fn janet_zig_math_rng_fill(rng: *c.JanetRNG, out: [*c]u8, count: i32) callconv(.c) void {
    const total: usize = @intCast(count);
    var index: usize = 0;
    while (index + 4 <= total) : (index += 4) {
        std.mem.writeInt(u32, out[index..][0..4], janet_rng_u32(rng), .little);
    }
    if (index < total) {
        var word: [4]u8 = undefined;
        std.mem.writeInt(u32, &word, janet_rng_u32(rng), .little);
        @memcpy(out[index..total], word[0 .. total - index]);
    }
}

export fn janet_zig_math_gcd(x_in: f64, y_in: f64) callconv(.c) f64 {
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

export fn janet_zig_math_lcm(x: f64, y: f64) callconv(.c) f64 {
    return (x / janet_zig_math_gcd(x, y)) * y;
}

// ==========================================================================
// math/*, `not`, and the RNG abstract type: the cfunction surface.
//
// Phase 10 Part 6. `-Dmath-core` already owned the generator and the two
// kernels above; what arrives here is the standard-library surface over them,
// which stayed in C because every entry point raises.
//
// One consequence is visible in `cfunRngBuffer` below. The C original reserves
// the buffer space on its side of the seam with a comment saying why -- "a
// Janet signal must not unwind across a Zig frame" -- and that rule went in
// Phase 8. The reservation stays where it is because `janet_buffer_extra` is
// still what grows the buffer, but it is now an ordinary call in an ordinary
// frame rather than a boundary arrangement.
// ==========================================================================

const plan9 = @hasDecl(c, "JANET_PLAN9");

/// `JANET_DEFINE_MATHOP` and `JANET_DEFINE_NAMED_MATHOP`: one argument in, one
/// double out, through the C library function of the same name.
///
/// The libm function is called rather than Zig's `@sin` and friends, and the
/// difference is not stylistic: `-Dmath-core=c` and the default have to agree
/// bit for bit, and the only way to guarantee that is for both to reach the
/// same implementation.
fn MathOp(comptime fop: anytype) type {
    return struct {
        fn call(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
            try arglayer.fixarity(argc, 1);
            return c.janet_wrap_number(fop(try arglayer.getNumber(argv, 0)));
        }
    };
}

/// `JANET_DEFINE_MATH2OP`.
fn Math2Op(comptime fop: anytype) type {
    return struct {
        fn call(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
            try arglayer.fixarity(argc, 2);
            const lhs = try arglayer.getNumber(argv, 0);
            const rhs = try arglayer.getNumber(argv, 1);
            return c.janet_wrap_number(fop(lhs, rhs));
        }
    };
}

inline fn wrapInteger(x: i32) c.Janet {
    return c.janet_wrap_number(@floatFromInt(x));
}

// ------------------------------------------------------------ the RNG type

const rng_methods = [_]corefn.Method{
    .{ .name = "uniform", .cfun = &cfunRngUniform },
    .{ .name = "int", .cfun = &cfunRngInt },
    .{ .name = "buffer", .cfun = &cfunRngBuffer },
    .{ .name = null, .cfun = null },
};

fn rngGet(p: ?*anyopaque, key: c.Janet, out: [*c]c.Janet) raise.Raising(c_int) {
    _ = p;
    if (c.janet_checktype(key, c.JANET_KEYWORD) == 0) return 0;
    return c.janet_getmethod(c.janet_unwrap_keyword(key), @ptrCast(&rng_methods), out);
}

fn rngNext(p: ?*anyopaque, key: c.Janet) raise.Raising(c.Janet) {
    _ = p;
    return c.janet_nextmethod(@ptrCast(&rng_methods), key);
}

fn rngMarshal(p: ?*anyopaque, ctx: [*c]c.JanetMarshalContext) raise.Raising(void) {
    const rng: *c.JanetRNG = @ptrCast(@alignCast(p));
    c.janet_marshal_abstract(ctx, p);
    try marshalling.marshalInt(ctx, @bitCast(rng.a));
    try marshalling.marshalInt(ctx, @bitCast(rng.b));
    try marshalling.marshalInt(ctx, @bitCast(rng.c));
    try marshalling.marshalInt(ctx, @bitCast(rng.d));
    try marshalling.marshalInt(ctx, @bitCast(rng.counter));
}

fn rngUnmarshal(ctx: [*c]c.JanetMarshalContext) raise.Raising(?*anyopaque) {
    const rng: *c.JanetRNG = @ptrCast(@alignCast(try marsh.unmarshalAbstract(ctx, @sizeOf(c.JanetRNG))));
    rng.a = @bitCast(try marsh.unmarshalInt(ctx));
    rng.b = @bitCast(try marsh.unmarshalInt(ctx));
    rng.c = @bitCast(try marsh.unmarshalInt(ctx));
    rng.d = @bitCast(try marsh.unmarshalInt(ctx));
    rng.counter = @bitCast(try marsh.unmarshalInt(ctx));
    return rng;
}

/// Exported under C's name because `janet.h` declares it and `marsh.c` looks
/// abstract types up by address. Field order follows the struct definition
/// rather than the C initialiser's positional list, which is the same thing
/// said unambiguously.
export const janet_rng_type: abstract_type.AbstractType = .{
    .name = "core/rng",
    .gc = null,
    .gcmark = null,
    .get = &rngGet,
    .put = null,
    .marshal = &rngMarshal,
    .unmarshal = &rngUnmarshal,
    .tostring = null,
    .compare = null,
    .hash = null,
    .next = &rngNext,
    .call = null,
    .length = null,
    .bytes = null,
    .gcperthread = null,
};

// ----------------------------------------------------------- the cfunctions

fn cfunRngMake(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 0, 1);
    const rng: *c.JanetRNG = @ptrCast(@alignCast(c.janet_abstract(abstract_type.stored(&janet_rng_type), @sizeOf(c.JanetRNG))));
    if (argc == 1) {
        if (c.janet_checkint(argv[0]) != 0) {
            janet_rng_seed(rng, @bitCast(try arglayer.getInteger(argv, 0)));
        } else {
            const bytes = try arglayer.getBytes(argv, 0);
            janet_rng_longseed(rng, bytes.bytes, bytes.len);
        }
    } else {
        janet_rng_seed(rng, 0);
    }
    return c.janet_wrap_abstract(rng);
}

fn cfunRngUniform(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    const rng: *c.JanetRNG = @ptrCast(@alignCast(try arglayer.getAbstract(argv, 0, abstract_type.stored(&janet_rng_type))));
    return c.janet_wrap_number(janet_rng_double(rng));
}

fn cfunRngInt(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 1, 2);
    const rng: *c.JanetRNG = @ptrCast(@alignCast(try arglayer.getAbstract(argv, 0, abstract_type.stored(&janet_rng_type))));
    if (argc == 1) return wrapInteger(@bitCast(janet_rng_u32(rng) >> 1));
    const max = try arglayer.optNat(argv, argc, 1, std.math.maxInt(i32));
    if (max == 0) return c.janet_wrap_number(0.0);
    return wrapInteger(janet_zig_math_rng_int(rng, max));
}

fn cfunRngBuffer(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 2, 3);
    const rng: *c.JanetRNG = @ptrCast(@alignCast(try arglayer.getAbstract(argv, 0, abstract_type.stored(&janet_rng_type))));
    const n = try arglayer.getNat(argv, 1);
    const buffer = try arglayer.optBuffer(argv, argc, 2, n);
    try containers.bufferExtra(buffer, n);
    janet_zig_math_rng_fill(rng, buffer.*.data + @as(usize, @intCast(buffer.*.count)), n);
    buffer.*.count += n;
    return c.janet_wrap_buffer(buffer);
}

fn cfunRand(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    _ = argv;
    try arglayer.fixarity(argc, 0);
    return c.janet_wrap_number(janet_rng_double(&c.janet_vm.rng));
}

fn cfunSrand(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    if (c.janet_checkint(argv[0]) != 0) {
        janet_rng_seed(&c.janet_vm.rng, @bitCast(try arglayer.getInteger(argv, 0)));
    } else {
        const bytes = try arglayer.getBytes(argv, 0);
        janet_rng_longseed(&c.janet_vm.rng, bytes.bytes, bytes.len);
    }
    return c.janet_wrap_nil();
}

fn cfunNot(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    return c.janet_wrap_boolean(@intFromBool(c.janet_truthy(argv[0]) == 0));
}

fn cfunGcd(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 2);
    return c.janet_wrap_number(janet_zig_math_gcd(try arglayer.getNumber(argv, 0), try arglayer.getNumber(argv, 1)));
}

fn cfunLcm(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 2);
    return c.janet_wrap_number(janet_zig_math_lcm(try arglayer.getNumber(argv, 0), try arglayer.getNumber(argv, 1)));
}

fn cfunFrexp(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    var exp: c_int = undefined;
    const mantissa = c.frexp(try arglayer.getNumber(argv, 0), &exp);
    const result = c.janet_tuple_begin(2);
    result[0] = c.janet_wrap_number(mantissa);
    result[1] = c.janet_wrap_number(@floatFromInt(exp));
    return c.janet_wrap_tuple(c.janet_tuple_end(result));
}

fn cfunLdexp(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 2);
    const x = try arglayer.getNumber(argv, 0);
    const y = try arglayer.getInteger(argv, 1);
    return c.janet_wrap_number(c.ldexp(x, y));
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

pub fn janet_lib_mathImpl(env: *c.JanetTable) raise.Raising(void) {
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

    const written = [_]corefn.Entry{
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

    const entries = generated ++ written ++ [_]corefn.Entry{corefn.end};
    corefn.install(env, entries);
    try registration.registerAbstractType(abstract_type.stored(&janet_rng_type));

    // Bootstrap-only, exactly as in the C original: the runtime finds these in
    // the image and defining them again would be work with no effect.
    const inf = std.math.inf(f64);
    corefn.def(env, "math/pi", c.janet_wrap_number(3.1415926535897931), @src(), "The value pi.");
    corefn.def(env, "math/e", c.janet_wrap_number(2.7182818284590451), @src(), "The base of the natural log.");
    corefn.def(env, "math/inf", c.janet_wrap_number(inf), @src(), "The number representing positive infinity");
    corefn.def(env, "math/-inf", c.janet_wrap_number(-inf), @src(), "The number representing negative infinity");
    corefn.def(env, "math/int32-min", c.janet_wrap_number(@floatFromInt(std.math.minInt(i32))), @src(), "The minimum contiguous integer representable by a 32 bit signed integer");
    corefn.def(env, "math/int32-max", c.janet_wrap_number(@floatFromInt(std.math.maxInt(i32))), @src(), "The maximum contiguous integer representable by a 32 bit signed integer");
    corefn.def(env, "math/int-min", c.janet_wrap_number(-9007199254740992.0), @src(), "The minimum contiguous integer representable by a double (-(2^53))");
    corefn.def(env, "math/int-max", c.janet_wrap_number(9007199254740992.0), @src(), "The maximum contiguous integer representable by a double (2^53)");
    corefn.def(env, "math/nan", c.janet_wrap_number(std.math.nan(f64)), @src(), "Not a number (IEEE-754 NaN)");
}

export fn janet_lib_math(env: *c.JanetTable) callconv(.c) void {
    raise.reported(janet_lib_mathImpl(env));
}

/// `janet_default_rng`. The VM's own generator, which `math/seed` and
/// `math/random` use when no explicit `JanetRNG` is given.
///
/// It was the last symbol `math.c` defined, and it was there only because
/// `janet_vm` was C's. It is one field access.
fn defaultRng() callconv(.c) *c.JanetRNG {
    return &c.janet_vm.rng;
}

comptime {
    @export(&defaultRng, .{ .name = "janet_default_rng" });
}
