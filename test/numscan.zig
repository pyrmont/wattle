//! Behavioral contract for Janet's number scanner: `janet_scan_number`, its
//! explicit-base form, the `:s`/`:u`/`:n` suffixes, and `janet_buffer_dtostr`.
//!
//! Janet's reader reaches this for every numeric literal, so the suites
//! exercise it constantly and pin almost none of it: a literal that scans to
//! the wrong double still *is* a double, and a rejection is a parse error that
//! reads the same whatever produced it. What is asserted here is the set of
//! inputs where the answer is a specific bit pattern, and the set where the
//! answer is "no".
//!
//! ## Bit patterns, not values
//!
//! Every comparison below is over the bits rather than over `==`, and that is
//! load-bearing twice: it separates `-0.0` from `0.0`, which several cases turn
//! on, and it refuses to let a NaN compare equal to anything including itself.
//! A contract written with `==` would pass while scanning `-0` to positive zero.
//!
//! ## Two rounding behaviours that are Janet's rather than the host's
//!
//! **Ties go away from zero**, not to even, so `9007199254740993` rounds *up*
//! where a round-to-even `strtod` rounds down. And **the exponent accumulator
//! saturates** rather than wrapping, so `1e99999` is infinity and `1e-99999`
//! is zero instead of whatever a wrapped counter would produce. Neither is
//! reachable as a distinguishable answer from Janet.
//!
//! ## The radix prefixes have three surprises
//!
//! A radix of 0 or 1 falls back to base ten rather than failing. Outside base
//! ten `e` is an ordinary digit, so `&` introduces the exponent instead — and
//! **the exponent's own digits are read in the mantissa's radix**, which makes
//! `2r1&10` equal 4 rather than 1024. `p` is likewise a digit in bases above
//! 25, so `26r1p` is 51.

const std = @import("std");
const types = @import("types");
const repr = @import("repr");
const constants = @import("constants");
const c = @import("cabi");
const options = @import("options");
const harness = @import("harness.zig");
const buffers = @import("subsystems").value.buffers;
const numscan = @import("subsystems").scan;
const wrap = @import("subsystems").value.wrap;
const vm_lifecycle = @import("subsystems").lifecycle;
const inttypes = @import("subsystems").inttypes;
const raise = @import("raise");

/// `janet_buffer_dtostr` is declared in `src/core/util.h`, which no
/// translation ever carried — its dynamic-library section broke the Windows
/// cross-compile for every subsystem at once. Its rule outlived it: a caller
/// declares what it needs directly. `JanetBuffer` is `types.zig`'s, which
/// every file shares, so nothing is duplicated.
extern fn janet_buffer_dtostr(buffer: *types.JanetBuffer, x: f64) callconv(.c) void;

fn scan(text: []const u8, out: *f64) bool {
    return numscan.scanNumber(text, out) == 0;
}

/// Bit-for-bit, for the reason in the header comment.
fn sameDouble(a: f64, b: f64) bool {
    return @as(u64, @bitCast(a)) == @as(u64, @bitCast(b));
}

fn scansTo(text: []const u8, expected: f64) bool {
    // Seeded with a value nothing below scans to, so a scanner that reports
    // success without writing is caught rather than accidentally right.
    var val: f64 = 12345.0;
    if (!scan(text, &val)) return false;
    return sameDouble(val, expected);
}

fn rejects(text: []const u8) bool {
    var val: f64 = 12345.0;
    return !scan(text, &val);
}

const inf = std.math.inf(f64);

fn theIntegers() void {
    std.debug.assert(scansTo("0", 0.0));
    std.debug.assert(scansTo("-0", -0.0));
    std.debug.assert(scansTo("+0", 0.0));
    std.debug.assert(scansTo("1", 1.0));
    std.debug.assert(scansTo("-1", -1.0));
    std.debug.assert(scansTo("+42", 42.0));
    std.debug.assert(scansTo("000123", 123.0));

    // Ties away from zero; see the header comment.
    std.debug.assert(scansTo("9007199254740993", 9007199254740994.0));
    std.debug.assert(scansTo("9007199254740995", 9007199254740996.0));

    // The digit separator, including a trailing one.
    std.debug.assert(scansTo("1_000_000", 1000000.0));
    std.debug.assert(scansTo("1_", 1.0));
}

fn theFractions() void {
    std.debug.assert(scansTo("1.5", 1.5));
    std.debug.assert(scansTo("-1.5", -1.5));
    // A leading or trailing point is allowed on its own.
    std.debug.assert(scansTo(".5", 0.5));
    std.debug.assert(scansTo("0.5", 0.5));
    std.debug.assert(scansTo("5.", 5.0));
    std.debug.assert(scansTo("0.0", 0.0));
    std.debug.assert(scansTo("-0.0", -0.0));
    std.debug.assert(scansTo("0.000", 0.0));
    // The three that are not exactly representable.
    std.debug.assert(scansTo("0.1", 0.1));
    std.debug.assert(scansTo("0.2", 0.2));
    std.debug.assert(scansTo("0.3", 0.3));
    // The largest finite double, pi, and the smallest normal.
    std.debug.assert(scansTo("1.7976931348623157", 1.7976931348623157));
    std.debug.assert(scansTo("3.141592653589793", 3.141592653589793));
    std.debug.assert(scansTo("2.2250738585072014", 2.2250738585072014));
}

fn theExponents() void {
    std.debug.assert(scansTo("1e2", 100.0));
    std.debug.assert(scansTo("1E2", 100.0));
    std.debug.assert(scansTo("1e+2", 100.0));
    std.debug.assert(scansTo("1e-2", 0.01));
    std.debug.assert(scansTo("1e0", 1.0));
    std.debug.assert(scansTo("1e00002", 100.0));
    std.debug.assert(scansTo("1.5e3", 1500.0));

    // The four ends of the range, including the smallest denormal.
    std.debug.assert(scansTo("1e308", 1e308));
    std.debug.assert(scansTo("1e-308", 1e-308));
    std.debug.assert(scansTo("5e-324", 5e-324));
    std.debug.assert(scansTo("1e309", inf));
    std.debug.assert(scansTo("-1e309", -inf));
    std.debug.assert(scansTo("1e-400", 0.0));
    std.debug.assert(scansTo("-1e-400", -0.0));

    // Saturating rather than wrapping; see the header comment.
    std.debug.assert(scansTo("1e99999", inf));
    std.debug.assert(scansTo("1e-99999", 0.0));

    // Zero short-circuits before any exponent is applied, so the sign
    // survives and the saturation never runs.
    std.debug.assert(scansTo("0e99999", 0.0));
    std.debug.assert(scansTo("-0e99999", -0.0));
}

fn theRadixPrefixes() void {
    std.debug.assert(scansTo("0xff", 255.0));
    std.debug.assert(scansTo("0xFF", 255.0));
    std.debug.assert(scansTo("-0xff", -255.0));
    std.debug.assert(scansTo("0xdeadbeef", 3735928559.0));
    std.debug.assert(scansTo("2r1010", 10.0));
    std.debug.assert(scansTo("8r777", 511.0));
    std.debug.assert(scansTo("16rdeadbeef", 3735928559.0));
    std.debug.assert(scansTo("36rZZ", 1295.0));
    std.debug.assert(scansTo("36rz", 35.0));

    // A radix of 0 or 1 falls back to base ten rather than failing.
    std.debug.assert(scansTo("0r55", 55.0));
    std.debug.assert(scansTo("1r0", 0.0));

    // Outside base ten `e` is a digit, so `&` introduces the exponent.
    std.debug.assert(scansTo("16r1&2", 256.0));
    std.debug.assert(scansTo("10r1&2", 100.0));
    // And the exponent's digits are read in the mantissa's radix: 1 * 2^2.
    std.debug.assert(scansTo("2r1&10", 4.0));
    std.debug.assert(scansTo("16r1e", 30.0));

    std.debug.assert(rejects("2r102"));
    std.debug.assert(rejects("37r1"));
    std.debug.assert(rejects("1r2"));
}

/// `p` switches to a base-2 mantissa with a base-10 exponent and rescales the
/// fractional digits already seen.
fn theHexFloats() void {
    std.debug.assert(scansTo("0x1p4", 16.0));
    std.debug.assert(scansTo("0x1p-4", 0.0625));
    std.debug.assert(scansTo("0x1.8p1", 3.0));
    std.debug.assert(scansTo("0x1.8P1", 3.0));
    std.debug.assert(scansTo("16r1.8p1", 3.0));
    std.debug.assert(scansTo("-0x1.8p1", -3.0));
    std.debug.assert(scansTo("0xffp0", 255.0));
    // `p` is an ordinary digit in bases above 25.
    std.debug.assert(scansTo("26r1p", 51.0));
}

fn theExplicitBase() void {
    var val: f64 = 0.0;
    const scanBase = struct {
        fn f(text: []const u8, base: i32, out: *f64) bool {
            return numscan.scanNumberBase(text.ptr, @intCast(text.len), base, out) == 0;
        }
    }.f;

    std.debug.assert(scanBase("ff", 16, &val) and sameDouble(val, 255.0));
    std.debug.assert(scanBase("1010", 2, &val) and sameDouble(val, 10.0));
    std.debug.assert(scanBase("z", 36, &val) and sameDouble(val, 35.0));
    std.debug.assert(scanBase("10", 10, &val) and sameDouble(val, 10.0));
    std.debug.assert(scanBase("1e2", 10, &val) and sameDouble(val, 100.0));

    // An explicit base suppresses prefix detection: `0x` is not special, and
    // `x` is not a digit in base 16.
    std.debug.assert(!scanBase("0xff", 16, &val));
    std.debug.assert(!scanBase("2r10", 10, &val));

    // Base 0 means "detect".
    std.debug.assert(scanBase("0xff", 0, &val) and sameDouble(val, 255.0));
}

fn theRejections() void {
    for ([_][]const u8{
        "",      "-",     "+",  ".",   "-.",
        "e5",    "1.2.3", "1e", "1e+", "1e5e5",
        "1e1.5", "_1",    "0x", "abc", "1abc",
        // Neither spelling of a non-finite literal is accepted.
        "nan",   "inf",
        // Surrounding space is not trimmed.
          " 1", "1 ",
        // A trailing non-ASCII byte is not a digit.
         "1\xff",
    }) |text| {
        std.debug.assert(rejects(text));
    }

    // Repeated separators *after* a digit are fine, which is the case the list
    // above would otherwise suggest is refused.
    std.debug.assert(scansTo("1__0", 10.0));

    // A zero and a negative length both fail rather than reading the pointer.
    //
    // The two halves are asserted at different levels. The
    // Zig function takes a `[]const u8`, so an empty range is the only one of
    // the pair it can still be handed; the negative one is a state the type
    // forbids. But `janet_scan_number` publishes an `int32_t` and a C caller
    // can still pass -1, so the refusal moved to `capi.zig`'s `cbytes` and is
    // asserted here through the C entry point rather than dropped.
    var val: f64 = 0.0;
    std.debug.assert(numscan.scanNumber("1"[0..0], &val) == 1);
    std.debug.assert(c.janet_scan_number("1", -1, &val) == 1);
}

/// 0xFFFF bytes is the documented cutoff, and the two sides of it are the
/// assertion. Static rather than stack: 64 KB is past what a contract should
/// put on one.
var digits: [0x10002]u8 = undefined;

fn theLongInput() void {
    var val: f64 = 0.0;

    @memset(&digits, '0');
    digits[0] = '1';

    // At the cutoff: accepted, and overflows to infinity.
    std.debug.assert(numscan.scanNumber(digits[0..@intCast(0xFFFF)], &val) == 0);
    std.debug.assert(std.math.isInf(val) and val > 0);
    // One past it: refused rather than truncated.
    std.debug.assert(numscan.scanNumber(digits[0..@intCast(0x10000)], &val) == 1);

    // A long fractional tail drives the exponent very negative without
    // wrapping it.
    digits[0] = '0';
    digits[1] = '.';
    digits[0xFFFE] = '1';
    std.debug.assert(numscan.scanNumber(digits[0..@intCast(0xFFFF)], &val) == 0);
    std.debug.assert(sameDouble(val, 0.0));
}

/// Enough significant digits to force multi-digit BigNat arithmetic in both
/// the multiply and the premultiply-and-divide paths.
fn theWideMantissa() void {
    std.debug.assert(scansTo(
        "123456789012345678901234567890123456789012345678901234567890",
        123456789012345678901234567890123456789012345678901234567890.0,
    ));
    std.debug.assert(scansTo(
        "0.000000000000000000000000000000000000000000000000000000000001234567890123456789",
        1.234567890123456789e-60,
    ));
    std.debug.assert(scansTo(
        "1234567890123456789012345678901234567890e-40",
        1234567890123456789012345678901234567890e-40,
    ));
    std.debug.assert(scansTo("0.1e-300", 0.1e-300));
    std.debug.assert(scansTo("1234567890123456789e289", 1234567890123456789e289));
}

/// The `:s`, `:u` and `:n` suffixes, which exist only where the integer types
/// do. A suffix is exactly the last two bytes, so a colon anywhere else is not
/// one.
fn theNumericSuffixes() void {
    var val: repr.Value = undefined;

    std.debug.assert(numscan.scanNumeric("12", &val) == 0);
    std.debug.assert(harness.isType(val, repr.Tag.number));
    std.debug.assert(wrap.toNumber(val) == 12.0);

    std.debug.assert(numscan.scanNumeric("12:n", &val) == 0);
    std.debug.assert(harness.isType(val, repr.Tag.number));
    std.debug.assert(wrap.toNumber(val) == 12.0);

    // Both extremes, which are exactly the values a double cannot hold.
    std.debug.assert(numscan.scanNumeric("-9223372036854775808:s", &val) == 0);
    std.debug.assert(inttypes.isInt(val) == constants.JANET_INT_S64);
    std.debug.assert(raise.reported(inttypes.unwrapS64(val)) == std.math.minInt(i64));

    std.debug.assert(numscan.scanNumeric("18446744073709551615:u", &val) == 0);
    std.debug.assert(inttypes.isInt(val) == constants.JANET_INT_U64);
    std.debug.assert(raise.reported(inttypes.unwrapU64(val)) == std.math.maxInt(u64));

    // Out of range for the requested width, a sign the width cannot hold, an
    // unknown suffix, and a bad mantissa all report failure.
    std.debug.assert(numscan.scanNumeric("18446744073709551616:u", &val) == 1);
    std.debug.assert(numscan.scanNumeric("-1:u", &val) == 1);
    std.debug.assert(numscan.scanNumeric("1:q", &val) == 1);
    std.debug.assert(numscan.scanNumeric("x:n", &val) == 1);

    // A colon anywhere but the second-to-last byte is not a suffix.
    std.debug.assert(numscan.scanNumeric("1:", &val) == 1);
    std.debug.assert(numscan.scanNumeric(":s", &val) == 1);
}

/// `janet_buffer_dtostr` is the inverse and appends rather than replacing.
fn theDoubleToString() void {
    const b: *types.JanetBuffer = buffers.new(0);

    janet_buffer_dtostr(b, 1.0);
    std.debug.assert(b.count == 1 and b.slice()[0] == '1');

    // Seventeen significant digits, which is what round-trips.
    b.count = 0;
    janet_buffer_dtostr(b, 0.1);
    std.debug.assert(b.count == 19);
    std.debug.assert(std.mem.eql(u8, b.slice()[0..19], "0.10000000000000001"));

    // Negative zero keeps its sign here, unlike in the printer.
    b.count = 0;
    janet_buffer_dtostr(b, -0.0);
    std.debug.assert(b.count == 2 and std.mem.eql(u8, b.slice()[0..2], "-0"));

    // Appending preserves the existing contents.
    b.count = 0;
    _ = buffers.pushCstringAbi(b, "x=");
    janet_buffer_dtostr(b, 2.5);
    std.debug.assert(b.count == 5 and std.mem.eql(u8, b.slice()[0..5], "x=2.5"));

    // No comma survives regardless of locale, which is the one thing about
    // this function that depends on the host.
    b.count = 0;
    janet_buffer_dtostr(b, 1234.5678);
    const count: usize = @intCast(b.count);
    std.debug.assert(std.mem.indexOfScalar(u8, b.slice()[0..count], ',') == null);
}

pub fn run() void {
    harness.init();

    theIntegers();
    theFractions();
    theExponents();
    theRadixPrefixes();
    theHexFloats();
    theExplicitBase();
    theRejections();
    theLongInput();
    theWideMantissa();
    if (options.int_types_core) theNumericSuffixes();
    theDoubleToString();

    vm_lifecycle.deinit();
}
