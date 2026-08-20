//! Janet's custom number scanner.
//!
//! This is a direct port of the surviving half of `src/core/strtod.c`; Phase 4
//! already moved `janet_scan_int64` and `janet_scan_uint64` into
//! `subsystems/intscan.zig`. The scanner holds no Janet values and performs no
//! non-local control flow, so it needs no signal bridge. Only the final
//! representation-sensitive wrapping in `janet_scan_numeric` and the buffer
//! reservation in `janet_buffer_dtostr` stay behind narrow C helpers.

const std = @import("std");
const abi = @import("abi");
const c = abi.c;
const raise = @import("raise");
const containers = @import("containers.zig");

/// Reject absurd inputs outright rather than auditing every exponent for
/// overflow, matching `JANET_NUMBER_LENGTH_RIDICULOUS`.
const ridiculous_length: i32 = 0xFFFF;

const bignat_nbit = 31;
const bignat_base: u64 = 0x80000000;

/// Bound for the base-2 size estimate. Any radix and exponent Janet accepts
/// stays far inside this, and staying inside it keeps the estimate's arithmetic
/// away from `i64` overflow.
const exp2_approx_limit: i64 = 1 << 48;

const int_types_enabled = @hasDecl(c, "janet_scan_numeric");

extern fn ldexp(value: f64, exponent: c_int) callconv(.c) f64;
extern fn log2(value: f64) callconv(.c) f64;
extern fn snprintf(buffer: [*c]u8, size: usize, format: [*:0]const u8, ...) callconv(.c) c_int;

/// The three wraps this scanner produces. They were three one-line C functions
/// in `strtod.c` for as long as `-Dnumber-scan` had a C arm to share them
/// with; `value_wrap.zig` has the same three and `janet_wrap_s64` and
/// `janet_wrap_u64` are ordinary exported functions rather than macros, so
/// nothing here needs a shim.
inline fn janet_c_numscan_wrap_number(value: f64) c.Janet {
    return c.janet_wrap_number(value);
}
inline fn janet_c_numscan_wrap_s64(value: i64) c.Janet {
    return c.janet_wrap_s64(value);
}
inline fn janet_c_numscan_wrap_u64(value: u64) c.Janet {
    return c.janet_wrap_u64(value);
}

comptime {
    if (int_types_enabled) {
        @export(&scanNumeric, .{ .name = "janet_scan_numeric" });
    }
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
        c.janet_free(@as(?*anyopaque, @ptrCast(self.digits)));
    }

    /// Allocate `count` more digits and return a pointer to them.
    fn extra(self: *BigNat, count: i32) [*]u32 {
        const old_n = self.n;
        const new_n = old_n + count;
        if (self.cap < new_n) {
            const new_cap = 2 * new_n;
            const memory = c.janet_realloc(
                @as(?*anyopaque, @ptrCast(self.digits)),
                @as(usize, @intCast(new_cap)) * @sizeOf(u32),
            ) orelse c.janet_zig_out_of_memory();
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
export fn janet_scan_number_base(
    str: [*c]const u8,
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

export fn janet_scan_number(str: [*c]const u8, len: i32, out: *f64) callconv(.c) c_int {
    return janet_scan_number_base(str, len, 0, out);
}

/// Like `janet_scan_number`, but also recognizes the `:s` and `:u` 64-bit
/// integer suffixes and the explicit `:n` double suffix.
fn scanNumeric(str: [*c]const u8, len: i32, out: *c.Janet) callconv(.c) c_int {
    // The C original leaves `num` indeterminate when scanning fails and still
    // wraps it. Callers only read `*out` on success, so producing a zero here
    // is unobservable. See FOUND.md.
    var num: f64 = 0.0;
    var i64_value: i64 = 0;
    var u64_value: u64 = 0;

    if (len < 2 or str[@intCast(len - 2)] != ':') {
        const result = janet_scan_number_base(str, len, 0, &num);
        out.* = janet_c_numscan_wrap_number(num);
        return result;
    }
    switch (str[@intCast(len - 1)]) {
        'n' => {
            const result = janet_scan_number_base(str, len - 2, 0, &num);
            out.* = janet_c_numscan_wrap_number(num);
            return result;
        },
        // The integer scanners return success as 1, so the result is inverted.
        's' => {
            const result = @intFromBool(c.janet_scan_int64(str, len - 2, &i64_value) == 0);
            out.* = janet_c_numscan_wrap_s64(i64_value);
            return result;
        },
        'u' => {
            const result = @intFromBool(c.janet_scan_uint64(str, len - 2, &u64_value) == 0);
            out.* = janet_c_numscan_wrap_u64(u64_value);
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
/// and the C half is gone. The face keeps the C name because `janet.h`
/// declares it.
fn bufferDtostr(buffer: *c.JanetBuffer, value: f64) raise.Raising(void) {
    try containers.bufferExtra(buffer, 32);
    fill(buffer, value);
}

fn bufferDtostrFace(buffer: *c.JanetBuffer, value: f64) callconv(.c) void {
    raise.reported(bufferDtostr(buffer, value));
}

comptime {
    @export(&bufferDtostrFace, .{ .name = "janet_buffer_dtostr" });
}

/// Format `value` into space the caller has already reserved.
fn fill(buffer: *c.JanetBuffer, value: f64) void {
    const start: usize = @intCast(buffer.count);
    const target = buffer.data + start;
    const count = snprintf(target, 32, "%.17g", value);
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
fn saturatingFloatToInt(value: f64) i64 {
    if (std.math.isNan(value)) return 0;
    if (value >= @as(f64, exp2_approx_limit)) return exp2_approx_limit;
    if (value <= -@as(f64, exp2_approx_limit)) return -exp2_approx_limit;
    return @intFromFloat(value);
}
