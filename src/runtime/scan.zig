//! Text to number, in the three shapes the runtime needs.
//!
//! `scanNumber` and `scanNumberBase` read a double, `scanInt64` and
//! `scanUint64` read a 64-bit integer, and `scanNumeric` reads whichever of
//! the three a `:n`, `:s` or `:u` suffix names. Each reports a string that is
//! not a number as a null optional. `bufferDtostr` is the way back, appending
//! a double to a buffer.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const buffers = @import("value/buffers.zig");
const c = @import("cabi");
const config = @import("config");
const fatal = @import("fatal.zig");
const inttypes = @import("value/ints.zig");
const raise = @import("../api/raise.zig");
const repr = @import("repr");
const utils = @import("utils.zig");
const wrap = @import("value/helpers/wrap.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// The radix a `BigNat` digit is in, and the number of bits that radix takes.
const bignat_base: u64 = 0x80000000;
const bignat_nbit = 31;

/// The value of each character when parsing a number: 0-9, then a-z with the
/// values 10 through 35, with A-Z the same as a-z. A character that is no
/// digit maps to 0xff, which a caller rejects by comparing against the radix.
/// Indexed by the low seven bits, so a caller rejects a byte above 127 first.
const digit_lookup = blk: {
    var table: [128]u8 = @splat(0xff);
    for (&table, 0..) |*slot, index| {
        const byte: u8 = @intCast(index);
        slot.* = switch (byte) {
            '0'...'9' => byte - '0',
            'A'...'Z' => byte - 'A' + 10,
            'a'...'z' => byte - 'a' + 10,
            else => 0xff,
        };
    }
    break :blk table;
};

/// Bound for the base-2 size estimate. Any radix and exponent Janet accepts
/// stays far inside this, and staying inside it keeps the estimate's
/// arithmetic away from `i64` overflow.
const exp2_approx_limit: i64 = 1 << 48;

/// The longest string `scanUnsigned` reads, the integer scanners' equivalent
/// of `ridiculous_length`.
const max_literal_length = 0xffff;

/// Rejects an absurd input outright rather than auditing every exponent for
/// overflow, matching `JANET_NUMBER_LENGTH_RIDICULOUS`.
const ridiculous_length: i32 = 0xFFFF;

// ==========================================================================
// Types
// ==========================================================================

/// A natural number with a large mantissa. Digits are base 2^31, least
/// significant first, with the first digit stored inline so that an ordinary
/// number needs no allocation.
const BigNat = struct {
    first_digit: u32 = 0,
    digits: std.ArrayListUnmanaged(u32) = .empty,

    fn deinit(self: *BigNat) void {
        self.digits.deinit(utils.heap);
        self.digits = .empty;
    }

    /// Makes room for `count` more digits and returns them uninitialised.
    /// `lshiftN` writes over the whole run before reading any of it.
    fn extra(self: *BigNat, count: usize) []u32 {
        return self.digits.addManyAsSlice(utils.heap, count) catch fatal.outOfMemory();
    }

    fn append(self: *BigNat, digit: u32) void {
        self.digits.append(utils.heap, digit) catch fatal.outOfMemory();
    }

    /// Multiplies by `factor` and adds `term` in one pass. For a valid radix
    /// `factor` is between 2 and 36^4 and `term` is between 0 and 36.
    fn muladd(self: *BigNat, factor: u32, term: u32) void {
        const wide_factor: u64 = factor;
        var carry: u64 = @as(u64, self.first_digit) * wide_factor + term;
        self.first_digit = @intCast(carry % bignat_base);
        carry /= bignat_base;
        for (self.digits.items) |*slot| {
            carry += @as(u64, slot.*) * wide_factor;
            slot.* = @intCast(carry % bignat_base);
            carry /= bignat_base;
        }
        if (carry != 0) self.append(@truncate(carry));
    }

    /// Divides by `divisor`, dropping the remainder.
    fn div(self: *BigNat, divisor: u32) void {
        const wide_divisor: u64 = divisor;
        var remainder: u32 = 0;
        var quotient: u32 = 0;
        var dividend: u64 = undefined;
        const digits = self.digits.items;
        var index = digits.len;
        while (index > 0) {
            index -= 1;
            dividend = @as(u64, remainder) * bignat_base + digits[index];
            if (index < digits.len - 1) digits[index + 1] = quotient;
            quotient = @truncate(dividend / wide_divisor);
            remainder = @truncate(dividend % wide_divisor);
            digits[index] = remainder;
        }
        dividend = @as(u64, remainder) * bignat_base + self.first_digit;
        if (digits.len != 0 and digits[digits.len - 1] == 0) {
            self.digits.shrinkRetainingCapacity(digits.len - 1);
        }
        self.first_digit = @truncate(dividend / wide_divisor);
    }

    /// Shifts left by `shift` whole digits, which is `shift * 31` bits.
    fn lshiftN(self: *BigNat, shift: usize) void {
        if (shift == 0) return;
        const old_n = self.digits.items.len;
        _ = self.extra(shift);
        const digits = self.digits.items;
        std.mem.copyBackwards(u32, digits[shift .. shift + old_n], digits[0..old_n]);
        @memset(digits[0 .. shift - 1], 0);
        digits[shift - 1] = self.first_digit;
        self.first_digit = 0;
    }

    /// Extracts a double from the mantissa, scaled by 2^`exponent2`.
    fn extract(self: *BigNat, exponent2_in: i32) f64 {
        var exponent2 = exponent2_in;
        var top53: u64 = undefined;
        const n = self.digits.items.len;
        if (n != 0) {
            // Take the most significant 53 bits, which is a large right shift.
            const digits = self.digits.items;
            const d1: u64 = digits[n - 1]; // MSD, non-zero
            const d2: u64 = if (n == 1) self.first_digit else digits[n - 2];
            const d3: u64 = if (n > 2)
                digits[n - 3]
            else if (n == 2)
                self.first_digit
            else
                0;
            const nbits: u6 = @intCast(32 - @clz(@as(u32, @truncate(d1))));
            // Gather 54 bits, then round on the lowest one.
            top53 = (d2 << (54 - bignat_nbit)) + (d3 >> (2 * bignat_nbit - 54));
            top53 >>= nbits;
            top53 |= d1 << @intCast(54 - @as(i32, nbits));
            if (top53 & 1 != 0) top53 += 1;
            top53 >>= 1;
            if (top53 > 0x1FffffFFFFffff) {
                top53 >>= 1;
                exponent2 += 1;
            }
            // Correct for the large right shift applied to the mantissa.
            exponent2 += (@as(i32, nbits) - 53) + bignat_nbit * @as(i32, @intCast(n));
        } else {
            top53 = self.first_digit;
        }
        return c.ldexp(@floatFromInt(top53), exponent2);
    }
};

/// What `scanUnsigned` read: the magnitude, and whether a `-` preceded it.
const ParsedUnsigned = struct {
    value: u64,
    negative: bool,
};

// ==========================================================================
// Public functions
// ==========================================================================

/// Appends `val` to `buffer` in decimal, reserving the room first.
///
/// The reservation is `buffers.extra`, which raises, so this does too and its
/// one caller in `pp/pretty.zig` `try`s it. `bufferDtostrAbi` beside it is the
/// reporting form.
pub fn bufferDtostr(buffer: *buffers.Buffer, val: f64) raise.Error!void {
    try buffers.extra(buffer, 32);
    fill(buffer, val);
}

/// `bufferDtostr` for a caller with no error channel, reporting a raise
/// through `raise.toAbi`.
pub fn bufferDtostrAbi(buffer: *buffers.Buffer, val: f64) void {
    raise.toAbi(bufferDtostr(buffer, val));
}

/// Whether `str` is a number as the parser reads a token: as `scanNumeric`
/// scans it in a build with `int_types`, and as `scanNumber` scans it
/// otherwise.
///
/// No number is wrapped, so this function allocates nothing.
pub fn isNumber(str: []const u8) bool {
    if (!config.int_types) return scanNumber(str) != null;
    if (str.len < 2 or str[str.len - 2] != ':') return scanNumber(str) != null;
    const digits = str[0 .. str.len - 2];
    return switch (str[str.len - 1]) {
        'n' => scanNumber(digits) != null,
        's' => scanInt64(digits) != null,
        'u' => scanUint64(digits) != null,
        else => false,
    };
}

/// Scans a signed 64-bit integer from `string`, or nothing where the string is
/// not an integer or the value will not fit.
///
/// See `scanUnsigned` for the spellings accepted.
pub fn scanInt64(string: []const u8) ?i64 {
    const parsed = scanUnsigned(string) orelse return null;
    if (parsed.negative) {
        const minimum_magnitude = @as(u64, std.math.maxInt(i64)) + 1;
        if (parsed.value > minimum_magnitude) return null;
        if (parsed.value == minimum_magnitude) return std.math.minInt(i64);
        return -@as(i64, @intCast(parsed.value));
    }
    if (parsed.value > std.math.maxInt(i64)) return null;
    return @intCast(parsed.value);
}

/// Scans a double from `str` at radix 10, or nothing where the string is
/// not a number. A `0x` or `NNr` prefix still names its own radix.
pub fn scanNumber(str: []const u8) ?f64 {
    return scanNumberBase(str.ptr, @intCast(str.len), 0);
}

/// Scans a double from the `len` bytes at `str`, or nothing where they are not
/// a number.
///
/// `base_arg` is the radix, or zero to take it from a leading `0x` or `NNr`.
/// A `.` places a fractional part, `_` separates digits, and `&`, `e` at radix
/// 10 or `p` at radix 16 introduces an exponent.
pub fn scanNumberBase(
    str: [*]const u8,
    len: i32,
    base_arg: i32,
) ?f64 {
    var mant: BigNat = .{};
    defer mant.deinit();

    // Reject a ridiculous input so the exponent cannot wrap: 2GB of zeros
    // after the decimal point would otherwise drive `ex` positive.
    if (len > ridiculous_length) return null;
    if (len <= 0) return null;
    const bytes = str[0..@intCast(len)];

    var index: usize = 0;
    var seen_a_digit = false;
    var ex: i32 = 0;
    var seen_point = false;
    var found_exp = false;
    var negative = false;
    var base = base_arg;

    if (bytes[index] == '-') {
        negative = true;
        index += 1;
    } else if (bytes[index] == '+') {
        index += 1;
    }

    // Check for a leading 0x, or a one- or two-digit radix prefix.
    if (base == 0) {
        if (index + 1 < bytes.len and bytes[index] == '0' and bytes[index + 1] == 'x') {
            base = 16;
            index += 2;
        } else if (index + 1 < bytes.len and
            isDecimal(bytes[index]) and bytes[index + 1] == 'r')
        {
            base = bytes[index] - '0';
            index += 2;
        } else if (index + 2 < bytes.len and
            isDecimal(bytes[index]) and isDecimal(bytes[index + 1]) and bytes[index + 2] == 'r')
        {
            base = 10 * @as(i32, bytes[index] - '0') + @as(i32, bytes[index + 1] - '0');
            if (base < 2 or base > 36) return null;
            index += 3;
        }
    }

    if (base == 0) base = 10;
    var exp_base = base;

    // Skip leading zeros.
    while (index < bytes.len and (bytes[index] == '0' or bytes[index] == '.')) : (index += 1) {
        if (seen_point) ex -= 1;
        if (bytes[index] == '.') {
            if (seen_point) return null;
            seen_point = true;
        } else {
            seen_a_digit = true;
        }
    }

    // Parse significant digits.
    while (index < bytes.len) : (index += 1) {
        const byte = bytes[index];
        if (byte == '.') {
            if (seen_point) return null;
            seen_point = true;
        } else if (byte == '&') {
            found_exp = true;
            break;
        } else if (base == 16 and (byte == 'P' or byte == 'p')) {
            // IEEE hex float. Correct the exponent accumulated so far for the
            // change of radix.
            found_exp = true;
            exp_base = 10;
            base = 2;
            ex *= 4;
            break;
        } else if (base == 10 and (byte == 'E' or byte == 'e')) {
            found_exp = true;
            break;
        } else if (byte == '_') {
            if (!seen_a_digit) return null;
        } else {
            if (byte > 127) return null;
            const digit = digit_lookup[byte & 0x7F];
            if (@as(i32, digit) >= base) return null;
            if (seen_point) ex -= 1;
            mant.muladd(@bitCast(base), digit);
            seen_a_digit = true;
        }
    }

    if (!seen_a_digit) return null;

    // Read the exponent.
    if (index < bytes.len and found_exp) {
        var exponent_negative = false;
        var ee: i32 = 0;
        seen_a_digit = false;
        index += 1;
        if (index >= bytes.len) return null;
        if (bytes[index] == '-') {
            exponent_negative = true;
            index += 1;
        } else if (bytes[index] == '+') {
            index += 1;
        }
        while (index < bytes.len and bytes[index] == '0') : (index += 1) {
            seen_a_digit = true;
        }
        for (bytes[index..]) |byte| {
            if (byte > 127) return null;
            const digit = digit_lookup[byte & 0x7F];
            if (@as(i32, digit) >= exp_base) return null;
            if (ee < @divTrunc(std.math.maxInt(i32), 40)) {
                ee = exp_base *% ee +% digit;
            }
            seen_a_digit = true;
        }
        if (exponent_negative) ex -%= ee else ex +%= ee;
    }

    if (!seen_a_digit) return null;

    return convert(negative, &mant, base, ex);
}

/// Scans whichever of the three number types `str`'s suffix names, or
/// nothing where it is not that number.
///
/// `:n` is a double, `:s` a signed 64-bit integer and `:u` an unsigned one,
/// and a string with no suffix is a double. The optional is the failure
/// channel: a scan that fails has no value to wrap, and wrapping the scratch
/// anyway would leave every caller to check the failure before reading it.
pub fn scanNumeric(str: []const u8) ?repr.Value {
    const len: i32 = @intCast(str.len);
    if (len < 2 or str[str.len - 2] != ':') {
        return numscanWrapNumber(scanNumberBase(str.ptr, len, 0) orelse return null);
    }
    return switch (str[@intCast(len - 1)]) {
        'n' => numscanWrapNumber(scanNumberBase(str.ptr, len - 2, 0) orelse return null),
        's' => numscanWrapS64(scanInt64(str[0..@intCast(len - 2)]) orelse return null),
        'u' => numscanWrapU64(scanUint64(str[0..@intCast(len - 2)]) orelse return null),
        else => null,
    };
}

/// Scans an unsigned 64-bit integer from `string`, or nothing where the string
/// is not an integer, is negative, or the value will not fit.
///
/// See `scanUnsigned`, which reads the magnitude, for the spellings accepted.
pub fn scanUint64(string: []const u8) ?u64 {
    const parsed = scanUnsigned(string) orelse return null;
    if (parsed.negative) return null;
    return parsed.value;
}

// ==========================================================================
// Private functions
// ==========================================================================

/// Turns a mantissa and an exponent of radix `base` into the double they name,
/// with `negative` the sign. Zero, an overflow to infinity and a denormalised
/// result are each handled here rather than by the caller.
fn convert(negative: bool, mant: *BigNat, base: i32, exponent_in: i32) f64 {
    var exponent = exponent_in;
    var exponent2: i32 = 0;

    // The zero test comes before the base-2 size estimate. The ordering is
    // unobservable for an in-range radix, and evaluating `c.log2` first makes
    // an out-of-range one produce a NaN conversion.
    if (mant.digits.items.len == 0 and mant.first_digit == 0) return if (negative) -0.0 else 0.0;

    // Estimate the base-2 exponent of the result to within a factor of about
    // 2^32, then reject a value far outside the IEEE-754 exponent range,
    // leaving room for the approximation and for a denormal.
    const mant_exp2_approx: i64 = @as(i64, @intCast(mant.digits.items.len)) * 32 + 16;
    const exp_exp2_approx: i64 = saturatingFloatToInt(
        @floor(c.log2(@floatFromInt(base)) * @as(f64, @floatFromInt(exponent))),
    );
    const exp2_approx = mant_exp2_approx + exp_exp2_approx;

    if (exp2_approx > 1176) return if (negative) -std.math.inf(f64) else std.math.inf(f64);
    if (exp2_approx < -1175) return if (negative) -0.0 else 0.0;

    // The value is mant * base^exponent * 2^exponent2. Drive exponent to zero
    // without changing that value.
    const factor1: u32 = @bitCast(base);
    const factor2: u32 = @bitCast(base *% base);
    const factor4: u32 = @bitCast(base *% base *% base *% base);

    while (exponent > 3) : (exponent -= 4) mant.muladd(factor4, 0);
    while (exponent > 1) : (exponent -= 2) mant.muladd(factor2, 0);
    while (exponent > 0) : (exponent -= 1) mant.muladd(factor1, 0);

    // A negative exponent needs a premultiply so that integer division does
    // not throw away significant bits.
    if (exponent < 0) {
        const shamt = 5 - @divTrunc(exponent, 4);
        mant.lshiftN(@intCast(shamt));
        exponent2 -= shamt * bignat_nbit;
        while (exponent < -3) : (exponent += 4) mant.div(factor4);
        while (exponent < -1) : (exponent += 2) mant.div(factor2);
        while (exponent < 0) : (exponent += 1) mant.div(factor1);
    }

    return if (negative) -mant.extract(exponent2) else mant.extract(exponent2);
}

/// The value of one digit character in any radix up to 36, or nothing where
/// the byte is no digit.
fn digitValue(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'A'...'Z' => byte - 'A' + 10,
        'a'...'z' => byte - 'a' + 10,
        else => null,
    };
}

/// Formats `val` into space the caller has already reserved, at most 32 bytes
/// of it, and replaces a locale's decimal comma with a point.
fn fill(buffer: *buffers.Buffer, val: f64) void {
    const start: usize = @intCast(buffer.count);
    const target = buffer.data.? + start;
    const count = c.snprintf(target, 32, "%.17g", val);
    // Repair a locale's decimal comma.
    for (target[0..@intCast(count)]) |*byte| {
        if (byte.* == ',') byte.* = '.';
    }
    buffer.count += @as(usize, @intCast(count));
}

/// Whether `byte` is an ASCII digit.
fn isDecimal(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

/// The three wraps this scanner produces. `value/helpers/wrap.zig` has the
/// same three; these are local so that the scanner's own arms read as one
/// family.
inline fn numscanWrapNumber(val: f64) repr.Value {
    return wrap.fromNumber(val);
}

inline fn numscanWrapS64(val: i64) repr.Value {
    return inttypes.wrapS64(val);
}

inline fn numscanWrapU64(val: u64) repr.Value {
    return inttypes.wrapU64(val);
}

/// Converts `val` to an `i64`, clamping to `exp2_approx_limit` either side and
/// mapping a NaN to zero.
///
/// `@intFromFloat` is illegal behaviour for a value outside the destination
/// range, which an out-of-range radix can produce. Clamping preserves the
/// sense of both comparisons that consume the estimate.
fn saturatingFloatToInt(val: f64) i64 {
    if (std.math.isNan(val)) return 0;
    if (val >= @as(f64, exp2_approx_limit)) return exp2_approx_limit;
    if (val <= -@as(f64, exp2_approx_limit)) return -exp2_approx_limit;
    return @intFromFloat(val);
}

/// Scans the magnitude and the sign the two 64-bit scanners share, accepting a
/// `0x`, `NNr` or digit-separating `_`, or nothing where `string` is not an
/// integer or the magnitude will not fit a `u64`.
fn scanUnsigned(string: []const u8) ?ParsedUnsigned {
    if (string.len > max_literal_length) return null;
    const bytes = string;
    var index: usize = 0;
    var negative = false;
    var base: u8 = 10;
    var seen_digit = false;
    var accumulator: u64 = 0;

    if (bytes.len == 0) return null;
    if (bytes[index] == '-') {
        negative = true;
        index += 1;
    } else if (bytes[index] == '+') {
        index += 1;
    }

    if (index + 1 < bytes.len and bytes[index] == '0' and bytes[index + 1] == 'x') {
        base = 16;
        index += 2;
    } else if (index + 1 < bytes.len and isDecimal(bytes[index]) and bytes[index + 1] == 'r') {
        base = bytes[index] - '0';
        index += 2;
    } else if (index + 2 < bytes.len and isDecimal(bytes[index]) and isDecimal(bytes[index + 1]) and bytes[index + 2] == 'r') {
        base = 10 * (bytes[index] - '0') + (bytes[index + 1] - '0');
        if (base < 2 or base > 36) return null;
        index += 3;
    }

    while (index < bytes.len and bytes[index] == '0') : (index += 1) {
        seen_digit = true;
    }

    for (bytes[index..]) |byte| {
        if (byte == '_') {
            if (!seen_digit) return null;
            continue;
        }
        const digit = digitValue(byte) orelse return null;
        if (digit >= base) return null;
        const wide_digit: u64 = digit;
        const wide_base: u64 = base;
        if (accumulator > (std.math.maxInt(u64) - wide_digit) / wide_base) return null;
        accumulator = accumulator * wide_base + wide_digit;
        seen_digit = true;
    }

    if (!seen_digit) return null;
    return .{ .value = accumulator, .negative = negative };
}
