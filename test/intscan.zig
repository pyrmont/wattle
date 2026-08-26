//! Behavioral contract for the two integer scanners, `janet_scan_int64` and
//! `janet_scan_uint64`.
//!
//! Janet's own `scan-number` goes through the *floating-point* scanner, so
//! nothing in the language reaches these two except `int/s64` and `int/u64`,
//! and those are compiled out of a `-Dint-types=false` build entirely. What
//! that leaves untested from Janet is every boundary these functions exist to
//! get right: the two extremes of each range, the value one past each, the
//! radix prefixes, and the digit separator.
//!
//! Both take a length rather than a terminator, so a Zig slice is the natural
//! argument and the `strlen` the C original needed is gone.

const std = @import("std");
const c = @import("cabi");
const scan = @import("subsystems").scan;

fn signed(text: []const u8, out: *i64) bool {
    return scan.scanInt64(text, out) != 0;
}

fn unsigned(text: []const u8, out: *u64) bool {
    return scan.scanUint64(text, out) != 0;
}

fn theSignedRange() void {
    var value: i64 = 123;

    std.debug.assert(signed("0", &value) and value == 0);
    std.debug.assert(signed("-0", &value) and value == 0);
    std.debug.assert(signed("+42", &value) and value == 42);
    std.debug.assert(signed("-9223372036854775808", &value) and value == std.math.minInt(i64));
    std.debug.assert(signed("9223372036854775807", &value) and value == std.math.maxInt(i64));
    // `<radix>r<digits>`, which is Janet's own spelling and not C's.
    std.debug.assert(signed("16r7fff_ffff_ffff_ffff", &value) and value == std.math.maxInt(i64));

    // One past each end. These are the assertions the suites cannot make.
    std.debug.assert(!signed("9223372036854775808", &value));
    std.debug.assert(!signed("-9223372036854775809", &value));
}

fn theUnsignedRange() void {
    var value: u64 = 123;

    std.debug.assert(unsigned("18446744073709551615", &value) and value == std.math.maxInt(u64));
    std.debug.assert(unsigned("0xffff_ffff_ffff_ffff", &value) and value == std.math.maxInt(u64));
    std.debug.assert(unsigned("2r101010", &value) and value == 42);
    // Radix 36 is the largest, and its last digit is `Z`.
    std.debug.assert(unsigned("36rZ", &value) and value == 35);
    std.debug.assert(unsigned("1_000_000", &value) and value == 1000000);

    std.debug.assert(!unsigned("18446744073709551616", &value));
    // Negative is not "out of range" here, it is not a `uint64` at all.
    std.debug.assert(!unsigned("-1", &value));
    // A separator may not lead, a prefix may not stand alone, radix 37 does
    // not exist, and a trailing non-digit is not ignored.
    std.debug.assert(!unsigned("_1", &value));
    std.debug.assert(!unsigned("0x", &value));
    std.debug.assert(!unsigned("37r1", &value));
    std.debug.assert(!unsigned("12z", &value));
}

pub fn run() void {
    theSignedRange();
    theUnsignedRange();
}
