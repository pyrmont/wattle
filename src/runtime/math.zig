//! Janet's pseudo-random number generator and the numeric kernels behind the
//! `math/` library.
//!
//! The generator is public C ABI and its state is marshalled, so it is
//! bit-exact with Janet by construction rather than by convention.
//!
//! The `math/` cfunctions are at the foot of the file, along with the RNG
//! abstract type. Their bodies are argument extraction that raises on a type
//! or arity mismatch, which is an ordinary returned error here.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");
const builtin = @import("builtin");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const abstract_type = @import("../api/abstract_type.zig");
const abstracts = @import("value/abstracts.zig");
const args_core = @import("args.zig");
const buffers = @import("value/buffers.zig");
const c = @import("cabi");
const corefn = @import("corefn.zig");
const marsh = @import("marsh.zig");
const method_type = @import("method_type.zig");
const raise = @import("../api/raise.zig");
const registry = @import("registry.zig");
const repr = @import("repr");
const tables = @import("value/tables.zig");
const tuples = @import("value/tuples.zig");
const vm_state = @import("vm/state.zig");
const wrap = @import("value/helpers/wrap.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// Whether this target is Plan 9, where libm is missing nine of the functions
/// `libMath` otherwise registers.
const plan9 = (builtin.os.tag == .plan9);

/// The abstract type `math/rng` returns.
///
/// Exported under C's name because `marsh.zig` looks abstract types up by
/// address and eleven of them are published as data symbols.
pub const rngType = abstract_type.define(Rng, .{
    .name = "core/rng",
    .get = &rngGet,
    .marshal = &rngMarshal,
    .unmarshal = &rngUnmarshal,
    .next = &rngNext,
});

/// The methods reached through `(:int rng 10)` and its two siblings.
const rng_methods = [_]method_type.Method{
    .{ .name = "uniform", .cfun = &cfunRngUniform },
    .{ .name = "int", .cfun = &cfunRngInt },
    .{ .name = "buffer", .cfun = &cfunRngBuffer },
    .{ .name = null, .cfun = null },
};

// ==========================================================================
// Types
// ==========================================================================

/// Two arguments in, one double out, through the libm function of the same
/// name.
fn Math2Op(comptime fop: anytype) type {
    return struct {
        fn call(argv: []repr.Value) raise.Error!repr.Value {
            try args_core.fixarity(argv, 2);
            const lhs = try args_core.getNumber(argv, 0);
            const rhs = try args_core.getNumber(argv, 1);
            return wrap.fromNumber(fop(lhs, rhs));
        }
    };
}

/// One row per math op, so that the table and the implementations cannot
/// drift: the name, the libm function and the docstring are given once and the
/// cfunction is generated from them.
///
/// Nine of these are dropped on Plan 9. It is not a target this build
/// supports, and the guard is kept rather than deleted, because removing a
/// configuration is a product decision rather than a prose one.
const MathEntry = struct {
    janet_name: [:0]const u8,
    fop: *const fn (f64) callconv(.c) f64,
    doc: [:0]const u8,
    plan9_only_absent: bool = false,
};

/// One argument in, one double out, through the libm function of the same
/// name.
///
/// libm is called rather than Zig's `@sin` and its kin, and the difference is
/// not stylistic: the results have to be bit for bit what a C Janet produces,
/// and reaching the same implementation is the only way to guarantee that.
fn MathOp(comptime fop: anytype) type {
    return struct {
        fn call(argv: []repr.Value) raise.Error!repr.Value {
            try args_core.fixarity(argv, 1);
            return wrap.fromNumber(fop(try args_core.getNumber(argv, 0)));
        }
    };
}

/// The generator's whole state: four words and a counter, which is what
/// `rngMarshal` writes and `rngUnmarshal` reads back.
pub const Rng = struct {
    a: u32 = 0,
    b: u32 = 0,
    c: u32 = 0,
    d: u32 = 0,
    counter: u32 = 0,
};

// ==========================================================================
// Public functions
// ==========================================================================

/// The VM's own generator, which `math/seedrandom` and `math/random` use when
/// no explicit `Rng` is given.
pub fn defaultRng() *Rng {
    return &vm_state.current().rng;
}

/// The greatest common divisor of two doubles. A NaN in either argument gives
/// a NaN, and an infinity in either gives an infinity.
pub fn gcd(x_in: f64, y_in: f64) f64 {
    var x = x_in;
    var y = y_in;
    if (std.math.isNan(x) or std.math.isNan(y)) return std.math.nan(f64);
    if (std.math.isInf(x) or std.math.isInf(y)) return std.math.inf(f64);
    while (y != 0) {
        const temp = y;
        y = c.fmod(x, y);
        x = temp;
    }
    return x;
}

/// The least common multiple of two doubles, from `gcd`.
pub fn lcm(x: f64, y: f64) f64 {
    return (x / gcd(x, y)) * y;
}

/// Registers `math/*`, `not`, the RNG abstract type, and the numeric constants
/// the bootstrap puts in the image.
pub fn libMath(env: *tables.Table) raise.Error!void {
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

    // Bootstrap-only: the runtime finds these in the image, so defining them
    // again would be work with no effect.
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

/// A double in [0, 1), from the top 52 bits of two draws.
pub fn rngDouble(rng: *Rng) f64 {
    const hi: u64 = rngU32(rng);
    const lo: u64 = rngU32(rng);
    const big = lo | (hi << 32);
    return c.ldexp(@floatFromInt(big >> (64 - 52)), -52);
}

/// Writes `count` random bytes to `out`. A caller reserves the space first,
/// because the reservation can raise and this cannot.
pub fn rngFill(rng: *Rng, out: [*]u8, count: i32) void {
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

/// A uniform integer in [0, max) for max > 0, rejecting the tail of the
/// generator's range that would otherwise bias the modulus.
pub fn rngInt(rng: *Rng, max: i32) i32 {
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

/// Seeds from a byte sequence of any length, folded into the sixteen bytes of
/// state. The state may not be all zero, so a zero first word becomes one.
pub fn rngLongseed(rng: *Rng, bytes: []const u8) void {
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

/// Seeds from one 32-bit number, and draws sixteen times to leave the early
/// numbers behind.
pub fn rngSeed(rng: *Rng, seed: u32) void {
    rng.a = seed;
    rng.b = 0x97654321;
    rng.c = 123871873;
    rng.d = 0xf23f56c8;
    rng.counter = 0;
    // The first several numbers aren't that random.
    for (0..16) |_| _ = rngU32(rng);
}

/// Algorithm "xorwow" from p. 5 of Marsaglia, "Xorshift RNGs".
pub fn rngU32(rng: *Rng) u32 {
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

// ==========================================================================
// Private functions
// ==========================================================================

/// `(math/frexp x)`, as a tuple of the mantissa and the exponent.
fn cfunFrexp(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    var exp: c_int = undefined;
    const mantissa = c.frexp(try args_core.getNumber(argv, 0), &exp);
    const result = tuples.begin(2);
    result[0] = wrap.fromNumber(mantissa);
    result[1] = wrap.fromNumber(@floatFromInt(exp));
    return wrap.fromTuple(tuples.end(result));
}

/// `(math/gcd x y)`.
fn cfunGcd(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 2);
    return wrap.fromNumber(gcd(try args_core.getNumber(argv, 0), try args_core.getNumber(argv, 1)));
}

/// `(math/lcm x y)`.
fn cfunLcm(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 2);
    return wrap.fromNumber(lcm(try args_core.getNumber(argv, 0), try args_core.getNumber(argv, 1)));
}

/// `(math/ldexp m e)`.
fn cfunLdexp(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 2);
    const x = try args_core.getNumber(argv, 0);
    const y = try args_core.getInteger(argv, 1);
    return wrap.fromNumber(c.ldexp(x, y));
}

/// `(not x)`, registered by `libMath` along with the `math/` names.
fn cfunNot(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    return wrap.fromBoolean(!repr.truthy(argv[0]));
}

/// `(math/random)`, from the VM's own generator.
fn cfunRand(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 0);
    return wrap.fromNumber(rngDouble(&vm_state.current().rng));
}

/// `(math/rng-buffer rng n &opt buf)`. The space is reserved through
/// `buffers.extra`, which raises before any byte is written.
fn cfunRngBuffer(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 2, 3);
    const rng: *Rng = try args_core.getAbstract(Rng, argv, 0, &rngType);
    const n: usize = @intCast(try args_core.getNat(argv, 1));
    const buffer = try args_core.optBuffer(argv, 2, n);
    try buffers.extra(buffer, n);
    rngFill(rng, buffer.data.? + buffer.count, @intCast(n));
    buffer.count += n;
    return wrap.fromBuffer(buffer);
}

/// `(math/rng-int rng &opt max)`. A `max` of zero gives zero, and no `max`
/// means the whole non-negative `i32` range.
fn cfunRngInt(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, 2);
    const rng: *Rng = try args_core.getAbstract(Rng, argv, 0, &rngType);
    if (argv.len == 1) return wrap.fromInteger(@bitCast(rngU32(rng) >> 1));
    const max = try args_core.optNat(argv, 1, std.math.maxInt(i32));
    if (max == 0) return wrap.fromNumber(0.0);
    return wrap.fromInteger(rngInt(rng, max));
}

/// `(math/rng &opt seed)`, seeding from an integer or from a byte sequence.
fn cfunRngMake(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 0, 1);
    const rng: *Rng = abstracts.newFor(Rng, &rngType);
    if (argv.len == 1) {
        if (args_core.checkint(argv[0])) {
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

/// `(math/rng-uniform rng)`.
fn cfunRngUniform(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const rng: *Rng = try args_core.getAbstract(Rng, argv, 0, &rngType);
    return wrap.fromNumber(rngDouble(rng));
}

/// `(math/seedrandom seed)`, seeding the VM's own generator.
fn cfunSrand(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    if (args_core.checkint(argv[0])) {
        rngSeed(&vm_state.current().rng, @bitCast(try args_core.getInteger(argv, 0)));
    } else {
        const bytes = try args_core.getBytes(argv, 0);
        rngLongseed(&vm_state.current().rng, args_core.viewBytes(bytes));
    }
    return wrap.fromNil();
}

/// The method lookup behind `(:int rng 10)` and its siblings.
fn rngGet(_: *Rng, key: repr.Value) raise.Error!?repr.Value {
    return args_core.findMethod(key, @ptrCast(&rng_methods));
}

/// Writes the five words of state.
fn rngMarshal(rng: *Rng, m: *abi.Marshal) raise.Error!void {
    marsh.marshalAbstract(m, rng);
    try marsh.marshalInt(m, @bitCast(rng.a));
    try marsh.marshalInt(m, @bitCast(rng.b));
    try marsh.marshalInt(m, @bitCast(rng.c));
    try marsh.marshalInt(m, @bitCast(rng.d));
    try marsh.marshalInt(m, @bitCast(rng.counter));
}

/// The iteration order behind `next` and `(keys rng)`.
fn rngNext(_: *Rng, key: repr.Value) raise.Error!repr.Value {
    return args_core.nextmethod(@ptrCast(&rng_methods), key);
}

/// Reads the five words of state back.
fn rngUnmarshal(u: *abi.Unmarshal) raise.Error!*Rng {
    const rng: *Rng = @ptrCast(@alignCast(try marsh.unmarshalAbstract(u, @sizeOf(Rng))));
    rng.a = @bitCast(try marsh.unmarshalInt(u));
    rng.b = @bitCast(try marsh.unmarshalInt(u));
    rng.c = @bitCast(try marsh.unmarshalInt(u));
    rng.d = @bitCast(try marsh.unmarshalInt(u));
    rng.counter = @bitCast(try marsh.unmarshalInt(u));
    return rng;
}
