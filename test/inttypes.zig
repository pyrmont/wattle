//! Behavioral contract for the numeric kernels behind `int/s64` and
//! `int/u64`: the hash, the two abstract comparisons, the three mixed-type
//! orderings, the formatters, and floored division.
//!
//! ## The abstract types are reached as themselves
//!
//! The two `AbstractType` values have a raising `tostring`, and this file
//! calls it with `try` over the runtime's own type rather than through
//! anything that would flatten the raise.
//!
//! ## Why comparison goes through a compiled Janet function
//!
//! A double argument written as a Janet literal becomes a compile-time
//! constant, so a contract that wrote its vectors as literals would be
//! asserting about the constant folder as much as about `compare`. Calling a
//! compiled `(fn [a b] (compare a b))` with values built in Zig keeps the
//! folder out of it, so these vectors do not depend on it.
//!
//! ## NaN compares equal to everything
//!
//! That is not a bug being pinned; it is how a comparison restricted to `-1`,
//! `0` and `1` reports "no ordering". It is asserted so that a change to it
//! would be deliberate.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const buffers = @import("subsystems").value.buffers;
const constants = @import("constants");
const core_env = @import("subsystems").env;
const expect = @import("expect.zig").expect;
const functions = @import("subsystems").value.functions;
const gc_alloc = @import("subsystems").gc_alloc;
const harness = @import("harness.zig");
const inttypes = @import("subsystems").inttypes;
const repr = @import("repr");
const strings = @import("subsystems").value.strings;
const subsystems = @import("subsystems");
const tables = @import("subsystems").value.tables;
const vm_entry = @import("subsystems").vm_entry;
const vm_lifecycle = @import("subsystems").lifecycle;
const wrap = @import("subsystems").value.wrap;

// ==========================================================================
// Constants
// ==========================================================================

var compare_fn: *functions.Function = undefined;
var environment: *tables.Table = undefined;

/// The runtime's two abstract types, by import.
///
/// Pointers rather than aliases: an alias of a `const` is a *copy*, so an
/// address taken through one would be an address the runtime never handed out,
/// and an abstract built with it would be refused by its own type.
const s64_type = &inttypes.s64Type;
const u64_type = &inttypes.u64Type;

// ==========================================================================
// Aliased types
// ==========================================================================

const AbstractType = subsystems.abstract_type.AbstractType;

// ==========================================================================
// Cases
// ==========================================================================

fn compareValues(a: repr.Value, b: repr.Value) f64 {
    var argv = [2]repr.Value{ a, b };
    const resumed = vm_entry.pcall(compare_fn, &argv, null);
    expect(resumed.signal == abi.Signal.ok);
    expect(harness.isType(resumed.value, repr.Tag.number));
    return wrap.toNumber(resumed.value);
}

fn compareS64Double(x: i64, y: f64) f64 {
    return compareValues(inttypes.wrapS64(x), wrap.fromNumber(y));
}

fn compareU64Double(x: u64, y: f64) f64 {
    return compareValues(inttypes.wrapU64(x), wrap.fromNumber(y));
}

/// Render through the abstract type's own `tostring`, which raises.
fn render(at: *const AbstractType, p: *const anyopaque, b: *buffers.Buffer) !void {
    try at.tostring.?(@constCast(p), @ptrCast(b));
}

fn bufferIs(b: *buffers.Buffer, expected: []const u8) bool {
    const count: usize = @intCast(b.count);
    return count == expected.len and std.mem.eql(u8, b.slice()[0..count], expected);
}

fn eval(source: [*:0]const u8) repr.Value {
    var out: repr.Value = undefined;
    expect(core_env.dostring(environment, source, "inttypes-contract", &out) == 0);
    return out;
}

/// The hash folds the two halves together, so it is stable and the same for
/// either of the two types over the same bits.
fn theHash() void {
    var a: i64 = 0;
    var b: i64 = 1;
    var low: i64 = std.math.minInt(i64);
    var u: u64 = 1;

    expect(s64_type.hash.?(&a, @sizeOf(i64)) == 0);
    expect(s64_type.hash.?(&b, @sizeOf(i64)) ==
        u64_type.hash.?(&u, @sizeOf(u64)));
    expect(s64_type.hash.?(&low, @sizeOf(i64)) == std.math.minInt(i32));
    expect(s64_type.hash.?(&b, @sizeOf(i64)) !=
        s64_type.hash.?(&a, @sizeOf(i64)));

    // Values differing only in the high word still separate, which is what the
    // fold is for.
    var high: i64 = @as(i64, 1) << 32;
    expect(s64_type.hash.?(&high, @sizeOf(i64)) == 1);
}

fn theAbstractCompare() void {
    var s_small: i64 = -5;
    var s_big: i64 = 5;
    var s_min: i64 = std.math.minInt(i64);
    var s_max: i64 = std.math.maxInt(i64);
    var u_small: u64 = 5;
    var u_big: u64 = std.math.maxInt(u64);

    expect(s64_type.compare.?(&s_small, &s_big) == -1);
    expect(s64_type.compare.?(&s_big, &s_small) == 1);
    expect(s64_type.compare.?(&s_big, &s_big) == 0);
    expect(s64_type.compare.?(&s_min, &s_max) == -1);
    expect(s64_type.compare.?(&s_max, &s_min) == 1);

    // The unsigned comparison must not borrow the signed ordering.
    expect(u64_type.compare.?(&u_small, &u_big) == -1);
    expect(u64_type.compare.?(&u_big, &u_small) == 1);
    expect(u64_type.compare.?(&u_big, &u_big) == 0);

    var high_bit: u64 = @as(u64, 1) << 63;
    var one: u64 = 1;
    expect(u64_type.compare.?(&high_bit, &one) == 1);
}

fn theSignedAgainstDoubles() void {
    const inf = std.math.inf(f64);
    const nan = std.math.nan(f64);

    // Inside the double's contiguous integer range the comparison is exact.
    expect(compareS64Double(0, 0.0) == 0);
    expect(compareS64Double(5, 5.0) == 0);
    expect(compareS64Double(5, 5.5) == -1);
    expect(compareS64Double(6, 5.5) == 1);
    expect(compareS64Double(-5, -5.0) == 0);
    expect(compareS64Double(-6, -5.5) == -1);
    expect(compareS64Double(-5, -5.5) == 1);

    // NaN compares equal to everything; see the header comment.
    expect(compareS64Double(0, nan) == 0);
    expect(compareS64Double(std.math.maxInt(i64), nan) == 0);

    // Infinities sit outside every integer.
    expect(compareS64Double(std.math.maxInt(i64), inf) == -1);
    expect(compareS64Double(std.math.minInt(i64), -inf) == 1);

    // Beyond 2^53 the integer cannot be widened without rounding, so the
    // double is narrowed instead.
    expect(compareS64Double(std.math.maxInt(i64), 1e300) == -1);
    expect(compareS64Double(std.math.minInt(i64), -1e300) == 1);
    expect(compareS64Double(std.math.maxInt(i64), 9.3e18) == -1);
    expect(compareS64Double(std.math.minInt(i64), -9.3e18) == 1);

    // 2^53 itself is the edge of the exact range.
    expect(compareS64Double(9007199254740992, 9007199254740992.0) == 0);
    expect(compareS64Double(9007199254740993, 9007199254740992.0) == 1);
    expect(compareS64Double(-9007199254740993, -9007199254740992.0) == -1);

    // 2^63 is the first double past the range, and it orders above every box
    // from either side. The doubles either side of it are the bracket.
    const two_63 = 9223372036854775808.0;
    expect(compareS64Double(1, two_63) == -1);
    expect(compareS64Double(std.math.maxInt(i64), two_63) == -1);
    expect(compareValues(wrap.fromNumber(two_63), inttypes.wrapS64(1)) == 1);
    expect(compareS64Double(1, two_63 - 1024) == -1);
    expect(compareS64Double(1, 2 * two_63) == -1);
    // Below 2^63 the double is still inside the range and compared exactly.
    expect(compareS64Double(std.math.maxInt(i64), 4611686018427387904.0) == 1);
}

fn theUnsignedAgainstDoubles() void {
    const inf = std.math.inf(f64);
    const nan = std.math.nan(f64);
    const max = std.math.maxInt(u64);

    expect(compareU64Double(0, 0.0) == 0);
    expect(compareU64Double(5, 5.0) == 0);
    expect(compareU64Double(5, 5.5) == -1);
    expect(compareU64Double(6, 5.5) == 1);

    // Every unsigned value is above every negative double, including zero
    // against a small negative, which is the case a naive cast gets wrong.
    expect(compareU64Double(0, -0.5) == 1);
    expect(compareU64Double(0, -1e300) == 1);
    expect(compareU64Double(max, -1.0) == 1);

    expect(compareU64Double(0, nan) == 0);
    expect(compareU64Double(max, nan) == 0);
    expect(compareU64Double(max, inf) == -1);
    expect(compareU64Double(max, 1e300) == -1);

    expect(compareU64Double(9007199254740992, 9007199254740992.0) == 0);
    expect(compareU64Double(9007199254740993, 9007199254740992.0) == 1);

    // 2^64 is the first double past the range, from either side, bracketed by
    // the double below it and 2^65.
    const two_64 = 18446744073709551616.0;
    expect(compareU64Double(1, two_64) == -1);
    expect(compareU64Double(max, two_64) == -1);
    expect(compareValues(wrap.fromNumber(two_64), inttypes.wrapU64(1)) == 1);
    expect(compareU64Double(1, two_64 - 2048) == -1);
    expect(compareU64Double(1, 2 * two_64) == -1);
}

/// The two 64-bit types against each other, where neither can be widened into
/// the other without losing a value.
fn theTwoTypesAgainstEachOther() void {
    const s_neg = inttypes.wrapS64(-1);
    const s_zero = inttypes.wrapS64(0);
    const s_max = inttypes.wrapS64(std.math.maxInt(i64));
    const u_zero = inttypes.wrapU64(0);
    const u_small = inttypes.wrapU64(1);
    const u_huge = inttypes.wrapU64(@as(u64, std.math.maxInt(i64)) + 1);
    const u_max = inttypes.wrapU64(std.math.maxInt(u64));

    // A negative signed value is below every unsigned value.
    expect(compareValues(s_neg, u_zero) == -1);
    expect(compareValues(s_neg, u_max) == -1);
    expect(compareValues(u_zero, s_neg) == 1);
    expect(compareValues(u_max, s_neg) == 1);

    // An unsigned value above INT64_MAX is above every signed value.
    expect(compareValues(s_max, u_huge) == -1);
    expect(compareValues(u_huge, s_max) == 1);
    expect(compareValues(s_max, u_max) == -1);

    // Inside the overlap the ordering is ordinary.
    expect(compareValues(s_zero, u_zero) == 0);
    expect(compareValues(s_zero, u_small) == -1);
    expect(compareValues(u_small, s_zero) == 1);
    expect(compareValues(s_max, inttypes.wrapU64(std.math.maxInt(i64))) == 0);
}

fn theFormatters() !void {
    const b: *buffers.Buffer = buffers.new(0);

    var s: i64 = 0;
    try render(s64_type, &s, b);
    expect(bufferIs(b, "0"));

    b.count = 0;
    s = std.math.minInt(i64);
    try render(s64_type, &s, b);
    expect(bufferIs(b, "-9223372036854775808"));

    b.count = 0;
    s = std.math.maxInt(i64);
    try render(s64_type, &s, b);
    expect(bufferIs(b, "9223372036854775807"));

    // The unsigned formatter must not print the high bit as a sign.
    b.count = 0;
    var u: u64 = std.math.maxInt(u64);
    try render(u64_type, &u, b);
    expect(bufferIs(b, "18446744073709551615"));

    // Formatting appends rather than replacing.
    b.count = 0;
    _ = buffers.pushCstringAbi(b, "n=");
    u = 42;
    try render(u64_type, &u, b);
    expect(bufferIs(b, "n=42"));
}

/// Floored division and modulo, through the `div` and `mod` methods.
///
/// `INT64_MIN / -1` has no representable result, and all six methods refuse
/// it with one message. The refusal is asserted at the end, because it is the
/// one input the division has no result to render for.
fn theFlooredDivision() !void {
    const cases = [_]struct { [:0]const u8, []const u8 }{
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
        var result: repr.Value = undefined;
        expect(core_env.dostring(environment, case[0].ptr, "inttypes-contract", &result) == 0);
        expect(inttypes.isInt(result) == constants.IntType.s64);

        const b: *buffers.Buffer = buffers.new(0);
        try render(s64_type, wrap.toAbstract(result), b);
        expect(bufferIs(b, case[1]));
    }

    // Dividing by zero raises, while the modulo above does not.
    //
    // Through `vm_entry.pcall` rather than `harness.raised`, because `div` is
    // not an nfunction. It is a Janet function that dispatches to the abstract
    // type's `div` method, so there is no `raise.NFunction` to call and no
    // error to catch: the raise happens inside the interpreter, and a
    // protected call is the instrument for that. `harness.core("div")` fails
    // its type assertion.
    const closure = eval("(fn [] (div (int/s64 1) (int/s64 0)))");
    expect(vm_entry.pcall(
        wrap.toFunction(closure),
        &.{},
        null,
    ).signal == abi.Signal.@"error");

    // `INT64_MIN / -1`, through every method that can reach it. Each is a
    // Janet-level dispatch for the reason above, so each is a protected call.
    for ([_][:0]const u8{
        "(fn [] (/ (int/s64 \"-9223372036854775808\") (int/s64 -1)))",
        "(fn [] (% (int/s64 \"-9223372036854775808\") (int/s64 -1)))",
        "(fn [] (div (int/s64 \"-9223372036854775808\") (int/s64 -1)))",
        "(fn [] (mod (int/s64 \"-9223372036854775808\") (int/s64 -1)))",
        "(fn [] (:rdiv (int/s64 -1) (int/s64 \"-9223372036854775808\")))",
        "(fn [] (:rmod (int/s64 -1) (int/s64 \"-9223372036854775808\")))",
    }) |source| {
        const fn_value = eval(source.ptr);
        expect(vm_entry.pcall(wrap.toFunction(fn_value), &.{}, null).signal == abi.Signal.@"error");
    }

    // And the neighbouring divisors, which are representable and must not be
    // caught by the guard.
    for ([_][:0]const u8{
        "(fn [] (div (int/s64 \"-9223372036854775808\") (int/s64 1)))",
        "(fn [] (div (int/s64 \"-9223372036854775807\") (int/s64 -1)))",
    }) |source| {
        const fn_value = eval(source.ptr);
        expect(vm_entry.pcall(wrap.toFunction(fn_value), &.{}, null).signal == abi.Signal.ok);
    }
}

/// An operand the boxed types cannot convert refuses *catchably*.
///
/// Asserted from Janet rather than through `harness.raised` for the reason
/// above: this is reached by the interpreter's binop fallback rather than
/// called directly. What is under test is not that the conversion refuses,
/// which `theSignedAgainstDoubles` covers, but that the refusal *arrives*.
///
/// A `Box(T).unwrap` bound to a reporting form of the conversion from inside a
/// raise-capable method would end the process with `a raise was reported
/// across the C ABI and never consumed` instead of raising, and it would be
/// hidden behind a comptime alias. `res/check/swallowed.janet` is what looks
/// for that shape.
fn anUnconvertibleOperandRefusesCatchably() void {
    const cases = [_][*:0]const u8{
        "(fn [] (+ (int/s64 1) {}))",
        "(fn [] (+ (int/s64 1) \"x\"))",
        "(fn [] (* (int/u64 2) [1]))",
        "(fn [] (- (int/s64 1) !{}))",
        // The `r`-prefixed methods, which the fallback reaches when the boxed
        // integer is the right operand.
        "(fn [] (+ {} (int/s64 1)))",
        // The in-place folds, which read through the same alias.
        "(fn [] (band (int/u64 1) :nope))",
    };
    for (cases) |source| {
        const closure = eval(source);
        const resumed = vm_entry.pcall(
            wrap.toFunction(closure),
            &.{},
            null,
        );
        expect(resumed.signal == abi.Signal.@"error");
        // And the payload is the conversion's own message, which is what says
        // the refusal travelled rather than being manufactured downstream.
        expect(harness.isType(resumed.value, repr.Tag.string));
        const message = wrap.toString(resumed.value);
        const length: usize = strings.head(message).length;
        expect(std.mem.indexOf(u8, message[0..length], "can not convert") != null);
    }
}

// ==========================================================================
// Entry
// ==========================================================================

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
    harness.init();
    environment = harness.coreEnv();

    const fun = eval("(fn [a b] (compare a b))");
    compare_fn = wrap.toFunction(fun);
    gc_alloc.gcroot(fun);

    body() catch @panic("inttypes: a kernel raised unexpectedly");

    vm_lifecycle.deinit();
}
