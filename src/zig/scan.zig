//! Text to number, in the three shapes the runtime needs one.
//!
//! Three files once -- doubles, the 64-bit integer types, and the character
//! classification both lean on. None has a name Janet publishes and none
//! exists because a platform differs, so they are the bucket.
//!
//! `isDecimal` was declared identically in two of the three, for the reason
//! any duplicate on this tree exists: neither file could see the other's.
const std = @import("std");
const config = @import("config");
const types = @import("types");
const repr = @import("repr");
const c = @import("cabi");
const raise = @import("raise");
const buffers = @import("value/buffers.zig");
const utils = @import("utils.zig");
const wrap = @import("value/helpers/wrap.zig");
const fatal = @import("fatal.zig");
const inttypes = @import("value/ints.zig");

// -------------------------------------------------------------------------
// Doubles -- what `numscan.zig` was.
// -------------------------------------------------------------------------

/// Reject absurd inputs outright rather than auditing every exponent for
/// overflow, matching `JANET_NUMBER_LENGTH_RIDICULOUS`.
const ridiculous_length: i32 = 0xFFFF;

const bignat_nbit = 31;
const bignat_base: u64 = 0x80000000;

/// Bound for the base-2 size estimate. Any radix and exponent Janet accepts
/// stays far inside this, and staying inside it keeps the estimate's arithmetic
/// away from `i64` overflow.
const exp2_approx_limit: i64 = 1 << 48;

const int_types_enabled = config.int_types;

extern fn ldexp(val: f64, exponent: c_int) callconv(.c) f64;
extern fn log2(val: f64) callconv(.c) f64;
extern fn snprintf(buffer: [*]u8, size: usize, format: [*:0]const u8, ...) callconv(.c) c_int;

/// The three wraps this scanner produces. They were three one-line C functions
/// in `strtod.c` for as long as `-Dnumber-scan` had a C arm to share them
/// with; `value_wrap.zig` has the same three and `janet_wrap_s64` and
/// `janet_wrap_u64` are ordinary exported functions rather than macros, so
/// nothing here needs a shim.
inline fn numscanWrapNumber(val: f64) repr.Value {
    return wrap.fromNumber(val);
}
inline fn numscanWrapS64(val: i64) repr.Value {
    return inttypes.wrapS64(val);
}
inline fn numscanWrapU64(val: u64) repr.Value {
    return inttypes.wrapU64(val);
}

comptime {
    if (int_types_enabled) {}
}

/// Values of characters when parsing numbers. Digits 0-9 and a-z (and A-Z),
/// where A-Z have values 10 through 35. Invalid characters map to 0xff, which
/// the caller rejects by comparing against the radix.
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

/// A natural number with a large mantissa. Digits are base 2^31, least
/// significant first, with the first digit stored inline so that ordinary
/// numbers never allocate.
const BigNat = struct {
    first_digit: u32 = 0,
    n: i32 = 0,
    cap: i32 = 0,
    digits: ?[*]u32 = null,

    fn deinit(self: *BigNat) void {
        utils.free(@as(?*anyopaque, @ptrCast(self.digits)));
    }

    /// Allocate `count` more digits and return a pointer to them.
    fn extra(self: *BigNat, count: i32) [*]u32 {
        const old_n = self.n;
        const new_n = old_n + count;
        if (self.cap < new_n) {
            const new_cap = 2 * new_n;
            const memory = utils.realloc(
                @as(?*anyopaque, @ptrCast(self.digits)),
                @as(usize, @intCast(new_cap)) * @sizeOf(u32),
            ) orelse fatal.outOfMemory();
            self.cap = new_cap;
            self.digits = @ptrCast(@alignCast(memory));
        }
        self.n = new_n;
        return self.digits.? + @as(usize, @intCast(old_n));
    }

    fn append(self: *BigNat, digit: u32) void {
        self.extra(1)[0] = digit;
    }

    /// Multiply by `factor` and add `term` in one pass. For a valid radix
    /// `factor` is between 2 and 36^4 and `term` is between 0 and 36.
    fn muladd(self: *BigNat, factor: u32, term: u32) void {
        const wide_factor: u64 = factor;
        var carry: u64 = @as(u64, self.first_digit) * wide_factor + term;
        self.first_digit = @intCast(carry % bignat_base);
        carry /= bignat_base;
        var index: i32 = 0;
        while (index < self.n) : (index += 1) {
            const slot = &self.digits.?[@intCast(index)];
            carry += @as(u64, slot.*) * wide_factor;
            slot.* = @intCast(carry % bignat_base);
            carry /= bignat_base;
        }
        if (carry != 0) self.append(@truncate(carry));
    }

    /// Divide by `divisor`, dropping the remainder.
    fn div(self: *BigNat, divisor: u32) void {
        const wide_divisor: u64 = divisor;
        var remainder: u32 = 0;
        var quotient: u32 = 0;
        var dividend: u64 = undefined;
        var index: i32 = self.n - 1;
        while (index >= 0) : (index -= 1) {
            const digits = self.digits.?;
            dividend = @as(u64, remainder) * bignat_base + digits[@intCast(index)];
            if (index < self.n - 1) digits[@intCast(index + 1)] = quotient;
            quotient = @truncate(dividend / wide_divisor);
            remainder = @truncate(dividend % wide_divisor);
            digits[@intCast(index)] = remainder;
        }
        dividend = @as(u64, remainder) * bignat_base + self.first_digit;
        if (self.n != 0 and self.digits.?[@intCast(self.n - 1)] == 0) self.n -= 1;
        self.first_digit = @truncate(dividend / wide_divisor);
    }

    /// Shift left by `count` whole digits, i.e. by `count * 31` bits.
    fn lshiftN(self: *BigNat, count: i32) void {
        if (count == 0) return;
        const old_n: usize = @intCast(self.n);
        _ = self.extra(count);
        const shift: usize = @intCast(count);
        const digits = self.digits.?;
        std.mem.copyBackwards(u32, digits[shift .. shift + old_n], digits[0..old_n]);
        @memset(digits[0 .. shift - 1], 0);
        digits[shift - 1] = self.first_digit;
        self.first_digit = 0;
    }

    /// Extract a double from the mantissa, scaled by 2^`exponent2`.
    fn extract(self: *BigNat, exponent2_in: i32) f64 {
        var exponent2 = exponent2_in;
        var top53: u64 = undefined;
        const n = self.n;
        if (n != 0) {
            // Take the most significant 53 bits, which is a large right shift.
            const digits = self.digits.?;
            const d1: u64 = digits[@intCast(n - 1)]; // MSD, non-zero
            const d2: u64 = if (n == 1) self.first_digit else digits[@intCast(n - 2)];
            const d3: u64 = if (n > 2)
                digits[@intCast(n - 3)]
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
            exponent2 += (@as(i32, nbits) - 53) + bignat_nbit * n;
        } else {
            top53 = self.first_digit;
        }
        return ldexp(@floatFromInt(top53), exponent2);
    }
};

/// Read a mantissa and exponent of a given radix and produce the double value,
/// handling zeros, infinities, and denormalized numbers.
fn convert(negative: bool, mant: *BigNat, base: i32, exponent_in: i32) f64 {
    var exponent = exponent_in;
    var exponent2: i32 = 0;

    // The C original computes the base-2 size estimate before short-circuiting
    // zero. That ordering is unobservable, and evaluating `log2` first makes an
    // out-of-range radix produce a NaN conversion, so the zero test comes first
    // here. See FOUND.md.
    if (mant.n == 0 and mant.first_digit == 0) return if (negative) -0.0 else 0.0;

    // Estimate the base-2 exponent of the result to within a factor of about
    // 2^32, then reject values far outside the IEEE-754 exponent range with a
    // healthy buffer for the approximation and for denormals.
    const mant_exp2_approx: i64 = @as(i64, mant.n) * 32 + 16;
    const exp_exp2_approx: i64 = saturatingFloatToInt(
        @floor(log2(@floatFromInt(base)) * @as(f64, @floatFromInt(exponent))),
    );
    const exp2_approx = mant_exp2_approx + exp_exp2_approx;

    if (exp2_approx > 1176) return if (negative) -std.math.inf(f64) else std.math.inf(f64);
    if (exp2_approx < -1175) return if (negative) -0.0 else 0.0;

    // The value is mant * base^exponent * 2^exponent2. Drive exponent to zero
    // while holding the value constant.
    const factor1: u32 = @bitCast(base);
    const factor2: u32 = @bitCast(base *% base);
    const factor4: u32 = @bitCast(base *% base *% base *% base);

    while (exponent > 3) : (exponent -= 4) mant.muladd(factor4, 0);
    while (exponent > 1) : (exponent -= 2) mant.muladd(factor2, 0);
    while (exponent > 0) : (exponent -= 1) mant.muladd(factor1, 0);

    // Negative exponents need a premultiply so integer division does not throw
    // away significant bits.
    if (exponent < 0) {
        const shamt = 5 - @divTrunc(exponent, 4);
        mant.lshiftN(shamt);
        exponent2 -= shamt * bignat_nbit;
        while (exponent < -3) : (exponent += 4) mant.div(factor4);
        while (exponent < -1) : (exponent += 2) mant.div(factor2);
        while (exponent < 0) : (exponent += 1) mant.div(factor1);
    }

    return if (negative) -mant.extract(exponent2) else mant.extract(exponent2);
}

/// Scan a double from a string. Returns 0 on success and 1 when the string is
/// not a number.
pub fn scanNumberBase(
    str: [*]const u8,
    len: i32,
    base_arg: i32,
    out: *f64,
) callconv(.c) c_int {
    var mant: BigNat = .{};
    defer mant.deinit();

    // Reject ridiculous inputs so the exponent cannot wrap; for example, 2GB of
    // zeros after the decimal point would otherwise drive `ex` positive.
    if (len > ridiculous_length) return 1;
    if (len <= 0) return 1;
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
            if (base < 2 or base > 36) return 1;
            index += 3;
        }
    }

    if (base == 0) base = 10;
    var exp_base = base;

    // Skip leading zeros.
    while (index < bytes.len and (bytes[index] == '0' or bytes[index] == '.')) : (index += 1) {
        if (seen_point) ex -= 1;
        if (bytes[index] == '.') {
            if (seen_point) return 1;
            seen_point = true;
        } else {
            seen_a_digit = true;
        }
    }

    // Parse significant digits.
    while (index < bytes.len) : (index += 1) {
        const byte = bytes[index];
        if (byte == '.') {
            if (seen_point) return 1;
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
            if (!seen_a_digit) return 1;
        } else {
            if (byte > 127) return 1;
            const digit = digit_lookup[byte & 0x7F];
            if (@as(i32, digit) >= base) return 1;
            if (seen_point) ex -= 1;
            mant.muladd(@bitCast(base), digit);
            seen_a_digit = true;
        }
    }

    if (!seen_a_digit) return 1;

    // Read the exponent.
    if (index < bytes.len and found_exp) {
        var exponent_negative = false;
        var ee: i32 = 0;
        seen_a_digit = false;
        index += 1;
        if (index >= bytes.len) return 1;
        if (bytes[index] == '-') {
            exponent_negative = true;
            index += 1;
        } else if (bytes[index] == '+') {
            index += 1;
        }
        while (index < bytes.len and bytes[index] == '0') : (index += 1) {
            seen_a_digit = true;
        }
        while (index < bytes.len) : (index += 1) {
            const byte = bytes[index];
            if (byte > 127) return 1;
            const digit = digit_lookup[byte & 0x7F];
            if (@as(i32, digit) >= exp_base) return 1;
            if (ee < @divTrunc(std.math.maxInt(i32), 40)) {
                ee = exp_base *% ee +% digit;
            }
            seen_a_digit = true;
        }
        if (exponent_negative) ex -%= ee else ex +%= ee;
    }

    if (!seen_a_digit) return 1;

    out.* = convert(negative, &mant, base, ex);
    return 0;
}

pub fn scanNumber(str: []const u8, out: *f64) c_int {
    return scanNumberBase(str.ptr, @intCast(str.len), 0, out);
}

/// Like `janet_scan_number`, but also recognizes the `:s` and `:u` 64-bit
/// integer suffixes and the explicit `:n` double suffix.
pub fn scanNumeric(str: []const u8, out: *repr.Value) c_int {
    // The C original leaves `num` indeterminate when scanning fails and still
    // wraps it. Callers only read `*out` on success, so producing a zero here
    // is unobservable. See FOUND.md.
    var num: f64 = 0.0;
    var i64_value: i64 = 0;
    var u64_value: u64 = 0;

    const len: i32 = @intCast(str.len);
    if (len < 2 or str[str.len - 2] != ':') {
        const result = scanNumberBase(str.ptr, len, 0, &num);
        out.* = numscanWrapNumber(num);
        return result;
    }
    switch (str[@intCast(len - 1)]) {
        'n' => {
            const result = scanNumberBase(str.ptr, len - 2, 0, &num);
            out.* = numscanWrapNumber(num);
            return result;
        },
        // The integer scanners return success as 1, so the result is inverted.
        's' => {
            const result = @intFromBool(scanInt64(str[0..@intCast(len - 2)], &i64_value) == 0);
            out.* = numscanWrapS64(i64_value);
            return result;
        },
        'u' => {
            const result = @intFromBool(scanUint64(str[0..@intCast(len - 2)], &u64_value) == 0);
            out.* = numscanWrapU64(u64_value);
            return result;
        },
        else => return 1,
    }
}

/// `janet_buffer_dtostr`. Reserve, then format.
///
/// The two halves were split across languages for as long as a panic was a
/// jump: `janet_buffer_extra` can raise, and no Zig frame could be unwound
/// through, so the reservation stayed in `strtod.c` and only the formatting was
/// here. A raise is a returned error now, so the split has no reason to exist
/// and the C half is gone. The abi keeps the C name because `janet.h`
/// declares it.
fn bufferDtostr(buffer: *types.JanetBuffer, val: f64) raise.Raising(void) {
    try buffers.extra(buffer, 32);
    fill(buffer, val);
}

pub fn bufferDtostrAbi(buffer: *types.JanetBuffer, val: f64) void {
    raise.reported(bufferDtostr(buffer, val));
}

/// Format `value` into space the caller has already reserved.
fn fill(buffer: *types.JanetBuffer, val: f64) void {
    const start: usize = @intCast(buffer.count);
    const target = buffer.data.? + start;
    const count = snprintf(target, 32, "%.17g", val);
    // Repair locale-dependent decimal commas.
    var index: c_int = 0;
    while (index < count) : (index += 1) {
        if (target[@intCast(index)] == ',') target[@intCast(index)] = '.';
    }
    buffer.count += count;
}

fn isDecimal(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

/// `@intFromFloat` is illegal behavior for values outside the destination
/// range, which an out-of-range radix can produce. Clamping preserves the sense
/// of both comparisons that consume the estimate.
fn saturatingFloatToInt(val: f64) i64 {
    if (std.math.isNan(val)) return 0;
    if (val >= @as(f64, exp2_approx_limit)) return exp2_approx_limit;
    if (val <= -@as(f64, exp2_approx_limit)) return -exp2_approx_limit;
    return @intFromFloat(val);
}

// -------------------------------------------------------------------------
// The 64-bit integer types -- what `intscan.zig` was.
// -------------------------------------------------------------------------

const max_literal_length = 0xffff;

pub fn scanInt64(string: []const u8, out: *i64) c_int {
    const parsed = scanUnsigned(string) orelse return 0;
    if (parsed.negative) {
        const minimum_magnitude = @as(u64, std.math.maxInt(i64)) + 1;
        if (parsed.value > minimum_magnitude) return 0;
        out.* = if (parsed.value == minimum_magnitude)
            std.math.minInt(i64)
        else
            -@as(i64, @intCast(parsed.value));
        return 1;
    }
    if (parsed.value > std.math.maxInt(i64)) return 0;
    out.* = @intCast(parsed.value);
    return 1;
}

pub fn scanUint64(string: []const u8, out: *u64) c_int {
    const parsed = scanUnsigned(string) orelse return 0;
    if (parsed.negative) return 0;
    out.* = parsed.value;
    return 1;
}

const ParsedUnsigned = struct {
    value: u64,
    negative: bool,
};

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

    while (index < bytes.len) : (index += 1) {
        const byte = bytes[index];
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

fn digitValue(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'A'...'Z' => byte - 'A' + 10,
        'a'...'z' => byte - 'a' + 10,
        else => null,
    };
}

// -------------------------------------------------------------------------
// Character classification -- what `textscan.zig` was.
// -------------------------------------------------------------------------
const symbol_characters = [8]u32{
    0x00000000, 0xf7ffec72, 0xc7ffffff, 0x07fffffe,
    0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff,
};

pub fn isSymbolChar(character: u8) c_int {
    const mask = symbol_characters[character >> 5] & (@as(u32, 1) << @intCast(character & 0x1f));
    return @bitCast(mask);
}

pub fn validUtf8(string: []const u8) c_int {
    const bytes = string;
    var index: usize = 0;
    while (index < bytes.len) {
        const first = bytes[index];
        const width: usize = if (first < 0x80)
            1
        else if (first >> 5 == 0x06)
            2
        else if (first >> 4 == 0x0e)
            3
        else if (first >> 3 == 0x1e)
            4
        else
            return 0;

        const next = index + width;
        if (next > bytes.len) return 0;
        for (bytes[index + 1 .. next]) |continuation| {
            if (continuation >> 6 != 2) return 0;
        }
        if (width == 2 and first < 0xc2) return 0;
        if (first == 0xe0 and bytes[index + 1] < 0xa0) return 0;
        if (first == 0xf0 and bytes[index + 1] < 0x90) return 0;
        index = next;
    }
    return 1;
}
