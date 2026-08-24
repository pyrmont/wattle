//! Behavioral contract for the numeric kernels behind `int/s64` and
//! `int/u64`: the hash, the two abstract comparisons, the three mixed-type
//! orderings, the formatters, and floored division.
//!
//! ## The abstract types are reached as themselves
//!
//! `janet_s64_type` and `janet_u64_type` are `AbstractType` values whose
//! `tostring` raises, so the C contract could not call one: it went through
//! `test/support.zig`'s `janet_contract_at_tostring`, one of three shims that
//! exist purely to let C invoke a raising Zig callback. Here the type is
//! declared `extern` with the runtime's own layout and the callback is called
//! with `try`.
//!
//! **That shim does not die with this file.** `test/ev_loop.c` and
//! `test/io_core.c` still use it; it goes when the last of the three moves.
//!
//! ## Why comparison goes through a compiled Janet function
//!
//! A double argument written as a Janet literal becomes a compile-time
//! constant, and `janetc_loadconst` casts such a constant to `int32_t` without
//! excluding NaN first — `FOUND.md` has that defect, unresolved. Calling a
//! compiled `(fn [a b] (compare a b))` with values built in Zig keeps the
//! constant folder out of it, so these vectors do not depend on it.
//!
//! ## NaN compares equal to everything
//!
//! That is not a bug being pinned; it is how a comparison that must answer
//! `-1`, `0` or `1` reports "no ordering". It is asserted so a port cannot
//! decide to answer something else.

const std = @import("std");
const abi = @import("abi");
const c = abi.c;
const harness = @import("harness.zig");
const subsystems = @import("subsystems");

const AbstractType = subsystems.abstract_type.AbstractType;

/// The runtime's two abstract types, with the runtime's layout. `inttypes.zig`
/// declares them `export const`, so they have a symbol but no namespace entry.
extern const janet_s64_type: AbstractType;
extern const janet_u64_type: AbstractType;

var environment: [*c]c.JanetTable = undefined;
var compare_fn: [*c]c.JanetFunction = undefined;

fn compareValues(a: c.Janet, b: c.Janet) f64 {
    var argv = [2]c.Janet{ a, b };
    var out: c.Janet = undefined;
    std.debug.assert(c.janet_pcall(compare_fn, 2, &argv, &out, null) == c.JANET_SIGNAL_OK);
    std.debug.assert(harness.isType(out, c.JANET_NUMBER));
    return c.janet_unwrap_number(out);
}

fn compareS64Double(x: i64, y: f64) f64 {
    return compareValues(c.janet_wrap_s64(x), c.janet_wrap_number(y));
}

fn compareU64Double(x: u64, y: f64) f64 {
    return compareValues(c.janet_wrap_u64(x), c.janet_wrap_number(y));
}

/// Render through the abstract type's own `tostring`, which raises.
fn render(at: *const AbstractType, p: *const anyopaque, b: *c.JanetBuffer) !void {
    try at.tostring.?(@constCast(p), b);
}

fn bufferIs(b: *c.JanetBuffer, expected: []const u8) bool {
    const count: usize = @intCast(b.count);
    return count == expected.len and std.mem.eql(u8, b.data[0..count], expected);
}

// ------------------------------------------------------------------- hash

/// The hash folds the two halves together, so it is stable and independent of
/// which of the two types holds the bits.
fn theHash() void {
    var a: i64 = 0;
    var b: i64 = 1;
    var low: i64 = std.math.minInt(i64);
    var u: u64 = 1;

    std.debug.assert(janet_s64_type.hash.?(&a, @sizeOf(i64)) == 0);
    std.debug.assert(janet_s64_type.hash.?(&b, @sizeOf(i64)) ==
        janet_u64_type.hash.?(&u, @sizeOf(u64)));
    std.debug.assert(janet_s64_type.hash.?(&low, @sizeOf(i64)) == std.math.minInt(i32));
    std.debug.assert(janet_s64_type.hash.?(&b, @sizeOf(i64)) !=
        janet_s64_type.hash.?(&a, @sizeOf(i64)));

    // Values differing only in the high word still separate, which is what the
    // fold is for.
    var high: i64 = @as(i64, 1) << 32;
    std.debug.assert(janet_s64_type.hash.?(&high, @sizeOf(i64)) == 1);
}

// ------------------------------------------------------- abstract compare

fn theAbstractCompare() void {
    var s_small: i64 = -5;
    var s_big: i64 = 5;
    var s_min: i64 = std.math.minInt(i64);
    var s_max: i64 = std.math.maxInt(i64);
    var u_small: u64 = 5;
    var u_big: u64 = std.math.maxInt(u64);

    std.debug.assert(janet_s64_type.compare.?(&s_small, &s_big) == -1);
    std.debug.assert(janet_s64_type.compare.?(&s_big, &s_small) == 1);
    std.debug.assert(janet_s64_type.compare.?(&s_big, &s_big) == 0);
    std.debug.assert(janet_s64_type.compare.?(&s_min, &s_max) == -1);
    std.debug.assert(janet_s64_type.compare.?(&s_max, &s_min) == 1);

    // The unsigned comparison must not borrow the signed ordering.
    std.debug.assert(janet_u64_type.compare.?(&u_small, &u_big) == -1);
    std.debug.assert(janet_u64_type.compare.?(&u_big, &u_small) == 1);
    std.debug.assert(janet_u64_type.compare.?(&u_big, &u_big) == 0);

    var high_bit: u64 = @as(u64, 1) << 63;
    var one: u64 = 1;
    std.debug.assert(janet_u64_type.compare.?(&high_bit, &one) == 1);
}

// ----------------------------------------------------- mixed with doubles

fn theSignedAgainstDoubles() void {
    const inf = std.math.inf(f64);
    const nan = std.math.nan(f64);

    // Inside the double's contiguous integer range the comparison is exact.
    std.debug.assert(compareS64Double(0, 0.0) == 0);
    std.debug.assert(compareS64Double(5, 5.0) == 0);
    std.debug.assert(compareS64Double(5, 5.5) == -1);
    std.debug.assert(compareS64Double(6, 5.5) == 1);
    std.debug.assert(compareS64Double(-5, -5.0) == 0);
    std.debug.assert(compareS64Double(-6, -5.5) == -1);
    std.debug.assert(compareS64Double(-5, -5.5) == 1);

    // NaN compares equal to everything; see the header comment.
    std.debug.assert(compareS64Double(0, nan) == 0);
    std.debug.assert(compareS64Double(std.math.maxInt(i64), nan) == 0);

    // Infinities sit outside every integer.
    std.debug.assert(compareS64Double(std.math.maxInt(i64), inf) == -1);
    std.debug.assert(compareS64Double(std.math.minInt(i64), -inf) == 1);

    // Beyond 2^53 the integer cannot be widened without rounding, so the
    // double is narrowed instead.
    std.debug.assert(compareS64Double(std.math.maxInt(i64), 1e300) == -1);
    std.debug.assert(compareS64Double(std.math.minInt(i64), -1e300) == 1);
    std.debug.assert(compareS64Double(std.math.maxInt(i64), 9.3e18) == -1);
    std.debug.assert(compareS64Double(std.math.minInt(i64), -9.3e18) == 1);

    // 2^53 itself is the edge of the exact range.
    std.debug.assert(compareS64Double(9007199254740992, 9007199254740992.0) == 0);
    std.debug.assert(compareS64Double(9007199254740993, 9007199254740992.0) == 1);
    std.debug.assert(compareS64Double(-9007199254740993, -9007199254740992.0) == -1);
}

fn theUnsignedAgainstDoubles() void {
    const inf = std.math.inf(f64);
    const nan = std.math.nan(f64);
    const max = std.math.maxInt(u64);

    std.debug.assert(compareU64Double(0, 0.0) == 0);
    std.debug.assert(compareU64Double(5, 5.0) == 0);
    std.debug.assert(compareU64Double(5, 5.5) == -1);
    std.debug.assert(compareU64Double(6, 5.5) == 1);

    // Every unsigned value is above every negative double, including zero
    // against a small negative — the case a naive cast gets wrong.
    std.debug.assert(compareU64Double(0, -0.5) == 1);
    std.debug.assert(compareU64Double(0, -1e300) == 1);
    std.debug.assert(compareU64Double(max, -1.0) == 1);

    std.debug.assert(compareU64Double(0, nan) == 0);
    std.debug.assert(compareU64Double(max, nan) == 0);
    std.debug.assert(compareU64Double(max, inf) == -1);
    std.debug.assert(compareU64Double(max, 1e300) == -1);

    std.debug.assert(compareU64Double(9007199254740992, 9007199254740992.0) == 0);
    std.debug.assert(compareU64Double(9007199254740993, 9007199254740992.0) == 1);
}

/// The two 64-bit types against each other, where neither can be widened into
/// the other without losing a value.
fn theTwoTypesAgainstEachOther() void {
    const s_neg = c.janet_wrap_s64(-1);
    const s_zero = c.janet_wrap_s64(0);
    const s_max = c.janet_wrap_s64(std.math.maxInt(i64));
    const u_zero = c.janet_wrap_u64(0);
    const u_small = c.janet_wrap_u64(1);
    const u_huge = c.janet_wrap_u64(@as(u64, std.math.maxInt(i64)) + 1);
    const u_max = c.janet_wrap_u64(std.math.maxInt(u64));

    // A negative signed value is below every unsigned value.
    std.debug.assert(compareValues(s_neg, u_zero) == -1);
    std.debug.assert(compareValues(s_neg, u_max) == -1);
    std.debug.assert(compareValues(u_zero, s_neg) == 1);
    std.debug.assert(compareValues(u_max, s_neg) == 1);

    // An unsigned value above INT64_MAX is above every signed value.
    std.debug.assert(compareValues(s_max, u_huge) == -1);
    std.debug.assert(compareValues(u_huge, s_max) == 1);
    std.debug.assert(compareValues(s_max, u_max) == -1);

    // Inside the overlap the ordering is ordinary.
    std.debug.assert(compareValues(s_zero, u_zero) == 0);
    std.debug.assert(compareValues(s_zero, u_small) == -1);
    std.debug.assert(compareValues(u_small, s_zero) == 1);
    std.debug.assert(compareValues(s_max, c.janet_wrap_u64(std.math.maxInt(i64))) == 0);
}

// ------------------------------------------------------------- formatting

fn theFormatters() !void {
    const b: *c.JanetBuffer = c.janet_buffer(0);

    var s: i64 = 0;
    try render(&janet_s64_type, &s, b);
    std.debug.assert(bufferIs(b, "0"));

    b.count = 0;
    s = std.math.minInt(i64);
    try render(&janet_s64_type, &s, b);
    std.debug.assert(bufferIs(b, "-9223372036854775808"));

    b.count = 0;
    s = std.math.maxInt(i64);
    try render(&janet_s64_type, &s, b);
    std.debug.assert(bufferIs(b, "9223372036854775807"));

    // The unsigned formatter must not print the high bit as a sign.
    b.count = 0;
    var u: u64 = std.math.maxInt(u64);
    try render(&janet_u64_type, &u, b);
    std.debug.assert(bufferIs(b, "18446744073709551615"));

    // Formatting appends rather than replacing.
    b.count = 0;
    _ = c.janet_buffer_push_cstring(b, "n=");
    u = 42;
    try render(&janet_u64_type, &u, b);
    std.debug.assert(bufferIs(b, "n=42"));
}

// -------------------------------------------------- floored division

/// Floored division and modulo, through the `div` and `mod` methods.
///
/// `INT64_MIN / -1` is deliberately absent. The `/` and `%` methods reject it
/// with a Janet error, but `div` and `mod` do not guard it and reach an
/// undefined division — `FOUND.md` has it, unresolved. Pinning either outcome
/// would assert behaviour that has not been decided.
fn theFlooredDivision() !void {
    const cases = [_]struct { []const u8, []const u8 }{
        // Floored division rounds toward negative infinity, unlike `/`.
        .{ "(div (int/s64 7) (int/s64 2))", "3" },
        .{ "(div (int/s64 -7) (int/s64 2))", "-4" },
        .{ "(div (int/s64 7) (int/s64 -2))", "-4" },
        .{ "(div (int/s64 -7) (int/s64 -2))", "3" },
        .{ "(div (int/s64 8) (int/s64 2))", "4" },
        .{ "(div (int/s64 -8) (int/s64 2))", "-4" },
        .{ "(div (int/s64 0) (int/s64 -3))", "0" },
        // `rdiv` swaps the operands.
        .{ "(:rdiv (int/s64 2) (int/s64 -7))", "-4" },
        // Floored modulo takes the sign of the divisor, unlike `%`.
        .{ "(mod (int/s64 7) (int/s64 2))", "1" },
        .{ "(mod (int/s64 -7) (int/s64 2))", "1" },
        .{ "(mod (int/s64 7) (int/s64 -2))", "-1" },
        .{ "(mod (int/s64 -7) (int/s64 -2))", "-1" },
        .{ "(mod (int/s64 -8) (int/s64 2))", "0" },
        .{ "(% (int/s64 -7) (int/s64 2))", "-1" },
        // A zero divisor returns the dividend rather than raising.
        .{ "(mod (int/s64 7) (int/s64 0))", "7" },
        .{ "(mod (int/s64 -7) (int/s64 0))", "-7" },
        .{ "(:rmod (int/s64 2) (int/s64 -7))", "1" },
        // The extremes still divide when the result is representable.
        .{ "(div (int/s64 \"-9223372036854775808\") (int/s64 2))", "-4611686018427387904" },
        .{ "(mod (int/s64 \"-9223372036854775808\") (int/s64 3))", "1" },
    };

    for (cases) |case| {
        var result: c.Janet = undefined;
        std.debug.assert(c.janet_dostring(environment, case[0].ptr, "inttypes-contract", &result) == 0);
        std.debug.assert(c.janet_is_int(result) == c.JANET_INT_S64);

        const b: *c.JanetBuffer = c.janet_buffer(0);
        try render(&janet_s64_type, c.janet_unwrap_abstract(result).?, b);
        std.debug.assert(bufferIs(b, case[1]));
    }

    // Dividing by zero raises, while the modulo above does not.
    //
    // Through `janet_pcall` rather than `harness.raised`, and the reason is
    // worth stating because it is the first case in this phase where the new
    // mechanism is the *wrong* tool: `div` is not a cfunction. It is a Janet
    // function that dispatches to the abstract type's `div` method, so there
    // is no `raise.CFunction` to call and no error to catch — the raise
    // happens inside the interpreter, and a protected call is exactly the
    // instrument for that. `harness.core("div")` fails its type assertion,
    // which is how this was found.
    const closure = eval("(fn [] (div (int/s64 1) (int/s64 0)))");
    var out: c.Janet = undefined;
    std.debug.assert(c.janet_pcall(
        c.janet_unwrap_function(closure),
        0,
        null,
        &out,
        null,
    ) == c.JANET_SIGNAL_ERROR);
}

/// An operand the boxed types cannot convert refuses *catchably*.
///
/// Phase 11 Part 15, and the reason it is asserted from Janet rather than
/// through `harness.raised` is the reason above: the operator methods are
/// reached by the interpreter's binop fallback, not called directly. What is
/// under test is not that the conversion refuses — `theSignedAgainstDoubles`
/// covers that — but that the refusal *arrives*.
///
/// `Box(T).unwrap` was bound to `janet_unwrap_s64`, the C face, from inside
/// `raise.Raising` methods, so every one of these killed the process with
/// `a raise was reported to a C caller and never consumed` instead of raising.
/// That is Part 13's defect in the file Part 13 fixed it for, hidden behind a
/// comptime alias; `port/swallowed.py` is what now looks for the class.
fn anUnconvertibleOperandRefusesCatchably() void {
    const cases = [_][*:0]const u8{
        "(fn [] (+ (int/s64 1) {}))",
        "(fn [] (+ (int/s64 1) \"x\"))",
        "(fn [] (* (int/u64 2) [1]))",
        "(fn [] (- (int/s64 1) @{}))",
        // The `r`-prefixed methods, which the fallback reaches when the boxed
        // integer is the right operand.
        "(fn [] (+ {} (int/s64 1)))",
        // The in-place folds, which read through the same alias.
        "(fn [] (band (int/u64 1) :nope))",
    };
    for (cases) |source| {
        const closure = eval(source);
        var out: c.Janet = undefined;
        std.debug.assert(c.janet_pcall(
            c.janet_unwrap_function(closure),
            0,
            null,
            &out,
            null,
        ) == c.JANET_SIGNAL_ERROR);
        // And the payload is the conversion's own message, which is what says
        // the refusal travelled rather than being manufactured downstream.
        std.debug.assert(harness.isType(out, c.JANET_STRING));
        const message = c.janet_unwrap_string(out);
        const length: usize = @intCast(c.janet_string_length(message));
        std.debug.assert(std.mem.indexOf(u8, message[0..length], "can not convert") != null);
    }
}

fn eval(source: [*:0]const u8) c.Janet {
    var out: c.Janet = undefined;
    std.debug.assert(c.janet_dostring(environment, source, "inttypes-contract", &out) == 0);
    return out;
}

fn body() !void {
    theHash();
    theAbstractCompare();
    theSignedAgainstDoubles();
    theUnsignedAgainstDoubles();
    theTwoTypesAgainstEachOther();
    try theFormatters();
    try theFlooredDivision();
    anUnconvertibleOperandRefusesCatchably();
}

pub fn run() void {
    _ = c.janet_init();
    environment = c.janet_core_env(null);

    const fun = eval("(fn [a b] (compare a b))");
    compare_fn = c.janet_unwrap_function(fun);
    c.janet_gcroot(fun);

    body() catch @panic("inttypes: a kernel raised unexpectedly");

    c.janet_deinit();
}
