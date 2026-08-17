//! Numeric kernels behind Janet's `int/s64` and `int/u64` abstract types.
//!
//! These are the parts of `src/core/inttypes.c` that are pure arithmetic: the
//! abstract-type hash and comparison callbacks, the polymorphic comparisons
//! that mix 64-bit integers with doubles and with each other, decimal
//! formatting, and floored division and modulo.
//!
//! The arithmetic C functions stay in C. Their bodies unwrap Janet values,
//! allocate abstracts, and panic on a type mismatch or a division by zero, and
//! a Janet signal must not unwind across a Zig frame.

const std = @import("std");
const abi = @import("abi");
const c = abi.c;

extern fn snprintf(buffer: [*c]u8, size: usize, format: [*:0]const u8, ...) callconv(.c) c_int;

/// The contiguous integer range of a double, matching `JANET_INTMAX_DOUBLE`.
const intmax_double: f64 = 9007199254740992.0;
const intmin_double: f64 = -9007199254740992.0;

// The abstract types store a bare 64-bit integer, so both share one hash.
export fn janet_zig_it_hash(p: ?*anyopaque, size: usize) callconv(.c) i32 {
    _ = size;
    const words: [*]const i32 = @ptrCast(@alignCast(p.?));
    return words[0] ^ words[1];
}

export fn janet_zig_it_s64_compare_abstract(p1: ?*anyopaque, p2: ?*anyopaque) callconv(.c) c_int {
    const x: *const i64 = @ptrCast(@alignCast(p1.?));
    const y: *const i64 = @ptrCast(@alignCast(p2.?));
    return compareScalar(i64, x.*, y.*);
}

export fn janet_zig_it_u64_compare_abstract(p1: ?*anyopaque, p2: ?*anyopaque) callconv(.c) c_int {
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
export fn janet_zig_it_compare_s64_double(x: i64, y: f64) callconv(.c) c_int {
    if (std.math.isNan(y)) return 0;
    if (y > intmin_double and y < intmax_double) {
        return compareDoubles(@floatFromInt(x), y);
    }
    if (y > @as(f64, @floatFromInt(std.math.maxInt(i64)))) return -1;
    if (y < @as(f64, @floatFromInt(std.math.minInt(i64)))) return 1;
    return compareScalar(i64, x, @intFromFloat(y));
}

export fn janet_zig_it_compare_u64_double(x: u64, y: f64) callconv(.c) c_int {
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
export fn janet_zig_it_compare_s64_u64(x: i64, y: u64) callconv(.c) c_int {
    if (x < 0) return -1;
    if (y > std.math.maxInt(i64)) return -1;
    return compareScalar(i64, x, @intCast(y));
}

export fn janet_zig_it_compare_u64_s64(x: u64, y: i64) callconv(.c) c_int {
    if (y < 0) return 1;
    if (x > std.math.maxInt(i64)) return 1;
    return compareScalar(i64, @intCast(x), y);
}

/// Write the decimal form into space the caller reserved, returning its length.
/// The reservation stays in C because it can panic.
export fn janet_zig_it_s64_tostring(value: i64, out: [*c]u8) callconv(.c) i32 {
    return snprintf(out, 32, "%lld", value);
}

export fn janet_zig_it_u64_tostring(value: u64, out: [*c]u8) callconv(.c) i32 {
    return snprintf(out, 32, "%llu", value);
}

/// Floored division. The caller rejects a zero divisor first.
///
/// C's division truncates toward zero, so a negative quotient with a remainder
/// is one step above the floor.
export fn janet_zig_it_s64_divf(op1: i64, op2: i64) callconv(.c) i64 {
    const x = divideTruncating(op1, op2);
    const negative_quotient = (op1 ^ op2) < 0;
    const inexact = x *% op2 != op1;
    return x -% @intFromBool(negative_quotient and inexact);
}

/// Floored modulo, which unlike C's remainder takes the sign of the divisor.
/// A zero divisor yields the dividend unchanged, matching the C original.
export fn janet_zig_it_s64_mod(op1: i64, op2: i64) callconv(.c) i64 {
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
