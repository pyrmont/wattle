//! Janet's pseudo-random number generator and the numeric kernels behind the
//! `math/` library.
//!
//! The RNG is public C ABI and its state is marshalled, so this port is
//! bit-exact with the C original by construction rather than by convention.
//! None of these functions touch Janet values or raise signals.
//!
//! The `math/` C functions themselves stay in C: their bodies are argument
//! extraction that panics on a type or arity mismatch, and a Janet signal must
//! not unwind across a Zig frame. They call into this module for the parts that
//! are actually computation.

const std = @import("std");
const abi = @import("abi");
const c = abi.c;

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
