//! Behavioral contract for the argument extraction layer.
//!
//! What is under test is a set of decisions and a set of messages, and the two
//! are checked separately because the layer separates them. The kernels decide
//! and fill in a `Fault`; `raiseFault` renders it. So every case below drives a
//! getter and compares the payload byte for byte, which is the only way to
//! show that a fault arm and its payload really do reconstruct the message
//! Janet raises. The rendering is what a Janet program sees, and the arms can
//! be exhaustive and right while the formatting drifts, so the message is what
//! each case asserts.
//!
//! The suites reach almost none of this. A Janet program that calls a
//! cfunction with the wrong argument sees one of these messages and stops, so
//! the common shapes are covered incidentally and the rest are not reached at
//! all: every width of integer, both range foldings, the flag ceiling and the
//! three cbytes shapes. They are enumerated here.
//!
//! Three of them are guarantees a module author reaches and a Janet program
//! does not: `checkfloat`'s range is symmetric about zero, `getFlags` refuses
//! a permitted set it cannot represent rather than clamping it, and
//! `getCBytes` gives a terminated string for every shape it accepts, including
//! an abstract's byte view.
//!
//! ## The two 64-bit getters are asserted in both configurations
//!
//! With the integer types compiled in, `getInteger64` and `getUInteger64` fill
//! in no fault of their own: they delegate to the 64-bit unwrap, which raises
//! its own message. Asking *how* each raises is what makes the difference
//! between a raise and a report visible, and a report would end the process
//! with `a raise was reported across the C ABI and never consumed` rather than
//! raising a catchable error. Both are asserted here whether the integer types
//! are compiled in or not.
//!
//! A refusal is a value throughout: `refuses` unwraps a null, so a case that
//! stops raising fails at its own line.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const abstract_type = subsystems.abstract_type;
const abstracts = @import("subsystems").value.abstracts;
const args = subsystems.args;
const arrays = @import("subsystems").value.arrays;
const buffers = @import("subsystems").value.buffers;
const c = @import("cabi");
const config = @import("config");
const constants = @import("constants");
const expect = @import("expect.zig").expect;

const gc_alloc = @import("subsystems").gc_alloc;
const harness = @import("harness.zig");
const method_type = @import("subsystems").method_type;
const raise = @import("subsystems").raise;
const repr = @import("repr");
const strings = @import("subsystems").value.strings;
const subsystems = @import("subsystems");
const tables = @import("subsystems").value.tables;
const tuples = @import("subsystems").value.tuples;
const value = @import("subsystems").value;
const vm_lifecycle = @import("subsystems").lifecycle;
const wrap = @import("subsystems").value.wrap;

// ==========================================================================
// Constants
// ==========================================================================

const method_one = raise.stored(&methodOne);
const method_two = raise.stored(&methodTwo);

const methods = [_]method_type.CMethod{
    .{ .name = "one", .cfun = method_one },
    .{ .name = "two", .cfun = method_two },
    .{ .name = null, .cfun = null },
};

const other_at = abstract_type.define(anyopaque, .{ .name = "args-core/other" });
const probe_at = abstract_type.define(anyopaque, .{ .name = "args-core/probe" });
const probe_bytes_at = abstract_type.define(anyopaque, .{ .name = "args-core/bytes-probe", .bytes = probeBytes });

// ==========================================================================
// Cases
// ==========================================================================

/// The refusal a getter made, or a failure naming the case that did not make
/// one.
fn refusal(function: anytype, arguments: anytype) harness.Raise {
    const r = harness.raised(function, arguments) orelse
        @panic("expected a refusal, got a return");
    expect(r.signal == abi.Signal.@"error");
    expect(harness.isType(r.payload, repr.Tag.string));
    return r;
}

fn refuses(function: anytype, arguments: anytype, message: []const u8) void {
    const r = refusal(function, arguments);
    if (!r.says(message)) {
        const got = wrap.toString(r.payload);
        const length: usize = strings.head(got).length;
        std.debug.print("expected: {s}\n     got: {s}\n", .{ message, got[0..length] });
        @panic("message mismatch");
    }
}

/// An abstract value renders with its address, so those messages are compared
/// by prefix. Everything else is compared whole.
fn refusesWithPrefix(function: anytype, arguments: anytype, prefix: []const u8) void {
    const r = refusal(function, arguments);
    if (!r.beginsWith(prefix)) {
        const got = wrap.toString(r.payload);
        const length: usize = strings.head(got).length;
        std.debug.print("expected prefix: {s}\n            got: {s}\n", .{ prefix, got[0..length] });
        @panic("message prefix mismatch");
    }
}

/// The identity: the argument layer takes a slice, so a contract hands it the
/// slice it built. Kept as a name because sixty call sites read
/// `slots(&.{ ... })` and the word is what says "an argument vector" at each
/// of them.
fn slots(argv: []const repr.Value) []const repr.Value {
    return argv;
}

fn arityIsCheckedAtBothBounds() raise.Error!void {
    const two = slots(&.{ wrap.fromNil(), wrap.fromNil() });
    try args.fixarity(two, 2);
    try args.arity(two, 1, 3);
    try args.arity(two, -1, -1);
    try args.arity(slots(&.{}), -1, 0);
    try args.arityCount(99, 1, -1);

    refuses(args.fixarityCount, .{ 1, 2 }, "arity mismatch, expected 2, got 1");
    refuses(args.fixarityCount, .{ 3, 2 }, "arity mismatch, expected 2, got 3");
    refuses(args.arityCount, .{ 0, 1, 3 }, "arity mismatch, expected at least 1, got 0");
    refuses(args.arityCount, .{ 4, 1, 3 }, "arity mismatch, expected at most 3, got 4");
    // A negative bound is unbounded, so only the other side can fault.
    refuses(args.arityCount, .{ 4, -1, 3 }, "arity mismatch, expected at most 3, got 4");
    refuses(args.arityCount, .{ 0, 1, -1 }, "arity mismatch, expected at least 1, got 0");
    // Zero is a bound on either side, not the unbounded marker.
    refuses(args.arityCount, .{ -1, 0, 2 }, "arity mismatch, expected at least 0, got -1");
    refuses(args.arityCount, .{ 1, 0, 0 }, "arity mismatch, expected at most 0, got 1");
}

fn everyTypeGetterNamesItsSlotAndItsType() raise.Error!void {
    var argv = [_]repr.Value{
        wrap.fromNil(),
        harness.wrapInteger(7),
        value.fromBytes("hello", .string),
        wrap.fromTrue(),
    };
    const a = slots(&argv);

    // The slot number in the message is the slot that was asked for, not the
    // position of the value in some other list.
    refuses(args.getNumber, .{ a, 0 }, "bad slot #0, expected number, got nil");
    refuses(args.getString, .{ a, 1 }, "bad slot #1, expected string, got 7");
    refuses(args.getArray, .{ a, 2 }, "bad slot #2, expected array, got \"hello\"");
    refuses(args.getTable, .{ a, 3 }, "bad slot #3, expected table, got true");
    refuses(args.getBuffer, .{ a, 0 }, "bad slot #0, expected buffer, got nil");
    refuses(args.getFiber, .{ a, 0 }, "bad slot #0, expected fiber, got nil");
    refuses(args.getFunction, .{ a, 0 }, "bad slot #0, expected function, got nil");
    refuses(args.getCFunction, .{ a, 0 }, "bad slot #0, expected cfunction, got nil");
    refuses(args.getKeyword, .{ a, 0 }, "bad slot #0, expected keyword, got nil");
    refuses(args.getSymbol, .{ a, 0 }, "bad slot #0, expected symbol, got nil");
    refuses(args.getTuple, .{ a, 0 }, "bad slot #0, expected tuple, got nil");
    refuses(args.getStruct, .{ a, 0 }, "bad slot #0, expected struct, got nil");
    refuses(args.getBoolean, .{ a, 0 }, "bad slot #0, expected boolean, got nil");
    refuses(args.getPointer, .{ a, 0 }, "bad slot #0, expected pointer, got nil");

    // The three view getters report a set of types rather than one.
    refuses(args.getIndexed, .{ a, 0 }, "bad slot #0, expected array or tuple, got nil");
    refuses(
        args.getBytes,
        .{ a, 0 },
        "bad slot #0, expected string, symbol, keyword or buffer, got nil",
    );
    refuses(args.getDictionary, .{ a, 0 }, "bad slot #0, expected table or struct, got nil");

    // And the success paths, where the data and the length are what a caller
    // reads rather than a message.
    expect(try args.getNumber(a, 1) == 7.0);
    expect(harness.stringIs(try args.getString(a, 2), "hello"));
    expect(try args.getBoolean(a, 3));
}

fn everyExpectationCodeHasItsOwnNoun() raise.Error!void {
    var argv = [_]repr.Value{
        wrap.fromNil(),
        wrap.fromNumber(1.5),
        wrap.fromNumber(-1.0),
    };
    const a = slots(&argv);

    // Every one of the eleven `Expect` members, in the words `Expect.name`
    // spells them. A member that mapped to the wrong noun would show here and
    // nowhere else.
    refuses(args.getInteger, .{ a, 0 }, "bad slot #0, expected 32 bit signed integer, got nil");
    refuses(args.getInteger, .{ a, 1 }, "bad slot #1, expected 32 bit signed integer, got 1.5");
    refuses(args.getUInteger, .{ a, 2 }, "bad slot #2, expected 32 bit unsigned integer, got -1");
    refuses(args.getInteger16, .{ a, 1 }, "bad slot #1, expected 16 bit signed integer, got 1.5");
    refuses(args.getUInteger16, .{ a, 2 }, "bad slot #2, expected 16 bit unsigned integer, got -1");
    refuses(args.getInteger8, .{ a, 1 }, "bad slot #1, expected 8 bit signed integer, got 1.5");
    refuses(args.getUInteger8, .{ a, 2 }, "bad slot #2, expected 8 bit unsigned integer, got -1");
    refuses(args.getNat, .{ a, 2 }, "bad slot #2, expected non-negative 32 bit signed integer, got -1");
    refuses(args.getFloat, .{ a, 0 }, "bad slot #0, expected float number, got nil");

    // The two widest getters, in whichever configuration this is. With integer
    // types they delegate to `inttypes.unwrapS64`, which raises its own
    // message and names no slot; without them they fill in a fault like the
    // rest. Both arms are asserted, since the first only arrives as a value
    // for a caller inside the compilation.
    if (comptime config.int_types) {
        refuses(
            args.getInteger64,
            .{ a, 0 },
            "can not convert nil nil to 64 bit signed integer",
        );
        refuses(
            args.getUInteger64,
            .{ a, 2 },
            // The two messages disagree about the article: the signed form
            // says "to 64 bit signed integer" and the unsigned one "to a 64
            // bit unsigned integer". Both are asserted as they are.
            "can not convert number -1 to a 64 bit unsigned integer",
        );
    } else {
        refuses(args.getInteger64, .{ a, 1 }, "bad slot #1, expected 64 bit signed integer, got 1.5");
        refuses(args.getUInteger64, .{ a, 2 }, "bad slot #2, expected 64 bit unsigned integer, got -1");
    }
}

/// The boundaries of each width, taken from both sides, because an off-by-one
/// in a range test is invisible to every other test here.
fn theWidthsAcceptExactlyTheirRange() raise.Error!void {
    var argv = [_]repr.Value{wrap.fromNil()};

    // A getter cannot be passed as a value, `args.getInteger` being
    // `GetInteger.get` rather than a function pointer, so these take it as an
    // `anytype` parameter instead.
    const Case = struct {
        fn accepts(argv_slot: *repr.Value, getter: anytype, val: f64, expected: anytype) void {
            argv_slot.* = wrap.fromNumber(val);
            const got = getter(slots(@as(*const [1]repr.Value, argv_slot)), 0) catch
                @panic("expected a value, got a refusal");
            expect(got == expected);
        }

        fn rejects(argv_slot: *repr.Value, getter: anytype, val: f64) void {
            argv_slot.* = wrap.fromNumber(val);
            const a2 = slots(@as(*const [1]repr.Value, argv_slot));
            expect(harness.raised(getter, .{ a2[0..1], @as(i32, 0) }) != null);
        }
    };
    const slot = &argv[0];

    Case.accepts(slot, args.getInteger, std.math.maxInt(i32), std.math.maxInt(i32));
    Case.accepts(slot, args.getInteger, std.math.minInt(i32), std.math.minInt(i32));
    Case.rejects(slot, args.getInteger, @as(f64, std.math.maxInt(i32)) + 1.0);
    Case.rejects(slot, args.getInteger, @as(f64, std.math.minInt(i32)) - 1.0);

    Case.accepts(slot, args.getUInteger, std.math.maxInt(u32), std.math.maxInt(u32));
    Case.accepts(slot, args.getUInteger, 0, 0);
    Case.rejects(slot, args.getUInteger, @as(f64, std.math.maxInt(u32)) + 1.0);
    Case.rejects(slot, args.getUInteger, -1.0);

    Case.accepts(slot, args.getInteger16, std.math.maxInt(i16), std.math.maxInt(i16));
    Case.accepts(slot, args.getInteger16, std.math.minInt(i16), std.math.minInt(i16));
    Case.rejects(slot, args.getInteger16, std.math.maxInt(i16) + 1);
    Case.rejects(slot, args.getInteger16, std.math.minInt(i16) - 1);

    Case.accepts(slot, args.getUInteger16, std.math.maxInt(u16), std.math.maxInt(u16));
    Case.rejects(slot, args.getUInteger16, std.math.maxInt(u16) + 1);

    Case.accepts(slot, args.getInteger8, std.math.maxInt(i8), std.math.maxInt(i8));
    Case.accepts(slot, args.getInteger8, std.math.minInt(i8), std.math.minInt(i8));
    Case.rejects(slot, args.getInteger8, std.math.maxInt(i8) + 1);
    Case.rejects(slot, args.getInteger8, std.math.minInt(i8) - 1);

    Case.accepts(slot, args.getUInteger8, std.math.maxInt(u8), std.math.maxInt(u8));
    Case.rejects(slot, args.getUInteger8, std.math.maxInt(u8) + 1);

    Case.accepts(slot, args.getNat, 0, 0);
    Case.accepts(slot, args.getNat, std.math.maxInt(i32), std.math.maxInt(i32));
    Case.rejects(slot, args.getNat, -1);

    // `getSize` tests the range before it converts, so its whole domain
    // is exercised rather than half of it: a negative, a non-finite and an
    // enormous double are rejected as arguments. Casting to `size_t` first is
    // undefined for exactly those, and `(gcsetinterval -1)` reaches it from
    // Janet source.
    Case.accepts(slot, args.getSize, 0, 0);
    Case.accepts(slot, args.getSize, 1, 1);
    Case.rejects(slot, args.getSize, 1.5);
    Case.rejects(slot, args.getSize, -1);
    Case.rejects(slot, args.getSize, -1.5);
    Case.rejects(slot, args.getSize, std.math.inf(f64));
    Case.rejects(slot, args.getSize, -std.math.inf(f64));
    Case.rejects(slot, args.getSize, std.math.nan(f64));
    Case.rejects(slot, args.getSize, 1e300);
    // 2^64, which the largest `usize` rounds to as a double, is refused at
    // the range test: converting it would be out of range.
    Case.rejects(slot, args.getSize, 18446744073709551616.0);

    if (comptime !config.int_types) {
        Case.accepts(slot, args.getInteger64, 9007199254740992.0, 9007199254740992);
        Case.accepts(slot, args.getInteger64, -9007199254740992.0, -9007199254740992);
        // The ceiling is 2^53, not `maxInt(i64)`: past it a double cannot name
        // consecutive integers, so the round trip would accept a value that is
        // not the one that was written.
        Case.rejects(slot, args.getInteger64, 9007199254740994.0);
        Case.accepts(slot, args.getUInteger64, 9007199254740992.0, 9007199254740992);
        Case.rejects(slot, args.getUInteger64, -1.0);
    }

    // A fractional value is rejected at every width, which is the round trip
    // rather than the range test doing the work.
    Case.rejects(slot, args.getInteger, 0.5);
    Case.rejects(slot, args.getUInteger, 0.5);
    Case.rejects(slot, args.getInteger16, 0.5);
    Case.rejects(slot, args.getInteger8, 0.5);
    Case.rejects(slot, args.getNat, 0.5);
}

/// `checkfloat`'s range is symmetric about zero: `-FLT_MAX` to `FLT_MAX`, the
/// way `checkint8`'s is `INT8_MIN` to `INT8_MAX`. Within it the round trip
/// through `f32` decides, so a double with more precision than a float can
/// represent is refused and a subnormal is not.
///
/// A lower bound of `FLT_MIN`, the smallest positive *normal* float, is the
/// shape this pins against: it would reject zero, every negative value and
/// every subnormal, and report that `-1.5` is not representable as a float.
fn getFloatTakesTheWholeFloatRange() raise.Error!void {
    var argv = [_]repr.Value{wrap.fromNumber(1.5)};
    const a = slots(&argv);
    expect(try args.getFloat(a, 0) == 1.5);

    argv[0] = wrap.fromNumber(0.0);
    expect(try args.getFloat(a, 0) == 0.0);
    argv[0] = wrap.fromNumber(-1.5);
    expect(try args.getFloat(a, 0) == -1.5);

    const flt_min = std.math.floatMin(f32);
    const flt_max = std.math.floatMax(f32);
    expect(args.checkfloat(wrap.fromNumber(0.0)));
    expect(args.checkfloat(wrap.fromNumber(-0.0)));
    expect(args.checkfloat(wrap.fromNumber(-1.0)));
    expect(args.checkfloat(wrap.fromNumber(@as(f64, flt_min) / 2.0)));
    expect(args.checkfloat(wrap.fromNumber(flt_min)));
    expect(args.checkfloat(wrap.fromNumber(-flt_min)));
    expect(args.checkfloat(wrap.fromNumber(flt_max)));
    expect(args.checkfloat(wrap.fromNumber(-@as(f64, flt_max))));
    // Both ends, and the first double past each of them.
    expect(!args.checkfloat(wrap.fromNumber(@as(f64, flt_max) * 2.0)));
    expect(!args.checkfloat(wrap.fromNumber(@as(f64, flt_max) * -2.0)));
    // Neither infinity nor a NaN is a float this converts.
    expect(!args.checkfloat(wrap.fromNumber(std.math.inf(f64))));
    expect(!args.checkfloat(wrap.fromNumber(-std.math.inf(f64))));
    expect(!args.checkfloat(wrap.fromNumberSafe(std.math.nan(f64))));
    // A double with more precision than a float has fails the round trip.
    expect(!args.checkfloat(wrap.fromNumber(1.0000000000000002)));
    // And the refusal still reads the way it always did.
    argv[0] = wrap.fromNumber(1.0000000000000002);
    refuses(args.getFloat, .{ a, 0 }, "bad slot #0, expected float number, got 1");
}

fn theTwoFoldingsDifferInOneEnd() raise.Error!void {
    var argv = [_]repr.Value{
        harness.wrapInteger(0),
        harness.wrapInteger(3),
        harness.wrapInteger(-1),
        wrap.fromNil(),
    };
    const a = slots(&argv);

    // A half range folds a negative index against length + 1 and accepts
    // length itself, because it names a boundary between elements.
    expect(try args.getHalfRange(a, 0, 10, "start") == 0);
    expect(try args.getHalfRange(a, 1, 10, "start") == 3);
    expect(try args.getHalfRange(a, 2, 10, "end") == 10);
    argv[0] = harness.wrapInteger(10);
    expect(try args.getHalfRange(a, 0, 10, "end") == 10);
    argv[0] = harness.wrapInteger(-11);
    expect(try args.getHalfRange(a, 0, 10, "start") == 0);

    argv[0] = harness.wrapInteger(11);
    refuses(args.getHalfRange, .{ a, 0, 10, "start" }, "start index 11 out of range [-11,10]");
    argv[0] = harness.wrapInteger(-12);
    refuses(args.getHalfRange, .{ a, 0, 10, "end" }, "end index -12 out of range [-11,10]");

    // An argument index folds against length and its interval is half open,
    // yet it still accepts length itself, which is the one asymmetry.
    argv[0] = harness.wrapInteger(0);
    expect(try args.getArgIndex(a, 0, 10, "at") == 0);
    argv[0] = harness.wrapInteger(-1);
    expect(try args.getArgIndex(a, 0, 10, "at") == 9);
    argv[0] = harness.wrapInteger(-10);
    expect(try args.getArgIndex(a, 0, 10, "at") == 0);

    argv[0] = harness.wrapInteger(11);
    refuses(args.getArgIndex, .{ a, 0, 10, "at" }, "at index 11 out of range [-10,10)");
    argv[0] = harness.wrapInteger(-11);
    refuses(args.getArgIndex, .{ a, 0, 10, "at" }, "at index -11 out of range [-10,10)");

    // A non-integer faults as an integer before any folding happens, so the
    // message names the type rather than the range.
    argv[0] = value.fromBytes("x", .string);
    refuses(
        args.getHalfRange,
        .{ a, 0, 10, "start" },
        "bad slot #0, expected 32 bit signed integer, got \"x\"",
    );

    // The start and end forms supply a default when the slot is absent or nil,
    // and the defaults are the two ends of the sequence.
    argv[0] = harness.wrapInteger(4);
    expect(try args.getStartRange(a, 3, 10) == 0);
    expect(try args.getEndRange(a, 3, 10) == 10);
    argv[3] = wrap.fromNil();
    expect(try args.getStartRange(a, 3, 10) == 0);
    expect(try args.getEndRange(a, 3, 10) == 10);
    expect(try args.getStartRange(a, 0, 10) == 4);
}

fn getSliceCollapsesAnInvertedRange() raise.Error!void {
    var argv = [_]repr.Value{ wrap.fromNil(), wrap.fromNil(), wrap.fromNil() };
    const array = arrays.new(0);
    harness.arrayPush(array, harness.wrapInteger(1));
    harness.arrayPush(array, harness.wrapInteger(2));
    harness.arrayPush(array, harness.wrapInteger(3));
    argv[0] = wrap.fromArray(array);
    const a = slots(&argv);

    var r = try args.getSlice(a);
    expect(r.start == 0 and r.end == 3);

    argv[1] = harness.wrapInteger(1);
    r = try args.getSlice(a);
    expect(r.start == 1 and r.end == 3);

    argv[2] = harness.wrapInteger(2);
    r = try args.getSlice(a);
    expect(r.start == 1 and r.end == 2);

    // An end before the start collapses to an empty range rather than
    // faulting, which is the one piece of arithmetic `getSlice` does itself.
    argv[1] = harness.wrapInteger(3);
    argv[2] = harness.wrapInteger(1);
    r = try args.getSlice(a);
    expect(r.start == 3 and r.end == 3);

    refuses(args.getSlice, .{a[0..0]}, "arity mismatch, expected at least 1, got 0");
    refuses(
        args.getSlice,
        .{slots(&[_]repr.Value{ argv[0], argv[1], argv[2], argv[2] })},
        "arity mismatch, expected at most 3, got 4",
    );
}

fn eachCharacterContributesTheBitAtItsPosition() raise.Error!void {
    var argv = [_]repr.Value{ value.fromBytes("acb", .keyword), value.fromBytes("z", .keyword) };
    const a = slots(&argv);

    // Each character contributes the bit at its position in the permitted set,
    // and the order of the keyword does not matter.
    expect(try args.getFlags(a, 0, "abc") == 0x7);
    argv[0] = value.fromBytes("", .keyword);
    expect(try args.getFlags(a, 0, "abc") == 0);
    argv[0] = value.fromBytes("c", .keyword);
    expect(try args.getFlags(a, 0, "abc") == 0x4);
    // A repeated character sets the same bit twice, which is not an error.
    argv[0] = value.fromBytes("aa", .keyword);
    expect(try args.getFlags(a, 0, "abc") == 0x1);

    refuses(args.getFlags, .{ a, 1, "abc" }, "unexpected flag z, expected one of \"abc\"");

    // Not a keyword at all faults before any scanning.
    argv[0] = value.fromBytes("a", .string);
    refuses(args.getFlags, .{ a, 0, "abc" }, "bad slot #0, expected keyword, got \"a\"");

    // Exactly 64 is the ceiling and the last character still counts. A `u64`
    // has a bit for it and none for a sixty-fifth, and a set longer than that
    // ends the process rather than clamping, so only the boundary can be
    // asserted here.
    var wide: [80]u8 = @splat(0);
    for (0..64) |i| wide[i] = '0' + @as(u8, @intCast(i % 10));
    wide[63] = 'Z';
    wide[64] = 0;
    argv[0] = value.fromBytes("Z", .keyword);
    expect(try args.getFlags(a, 0, @as([*:0]const u8, @ptrCast(&wide))) ==
        @as(u64, 1) << 63);
}

fn theByteAndCstringShapes() raise.Error!void {
    var argv = [_]repr.Value{
        value.fromBytes("hi", .string),
        wrap.fromBuffer(buffers.new(8)),
        value.fromBytes("kw", .keyword),
        wrap.fromNil(),
    };
    buffers.pushCstringAbi(wrap.toBuffer(argv[1]), "buf");
    const a = slots(&argv);

    var v = try args.getBytes(a, 0);
    expect(v.len == 2 and std.mem.eql(u8, v.bytes.?[0..2], "hi"));
    v = try args.getBytes(a, 1);
    expect(v.len == 3 and std.mem.eql(u8, v.bytes.?[0..3], "buf"));
    v = try args.getBytes(a, 2);
    expect(v.len == 2 and std.mem.eql(u8, v.bytes.?[0..2], "kw"));

    expect(std.mem.eql(u8, std.mem.span(try args.getCString(a, 0)), "hi"));
    expect(std.mem.eql(u8, std.mem.span(try args.getCBytes(a, 1)), "buf"));
    // The terminating shape leaves the buffer's visible count alone: the zero
    // is written past the end and the count is put back.
    expect(wrap.toBuffer(argv[1]).count == 3);

    // A full buffer that may be reallocated is terminated in place. Only one
    // that is both full and not reallocatable is copied.
    {
        const full = buffers.new(4);
        for ("full") |byte| buffers.pushU8(full, byte) catch @panic("args_core: buffer push raised");
        expect(full.count == full.capacity);
        var one = [_]repr.Value{wrap.fromBuffer(full)};
        expect(args.argCbytes(slots(&one), 0) == .terminate);
    }

    refuses(args.getCString, .{ a, 1 }, "bad slot #1, expected string, got @\"buf\"");
    refuses(args.getCString, .{ a, 3 }, "bad slot #3, expected string, got nil");
    refuses(
        args.getCBytes,
        .{ a, 3 },
        "bad slot #3, expected string, symbol, keyword or buffer, got nil",
    );

    // An embedded zero is rejected for every shape that can contain one.
    {
        const b = buffers.new(8);
        buffers.pushU8(b, 'a') catch @panic("args_core: buffer push raised");
        buffers.pushU8(b, 0) catch @panic("args_core: buffer push raised");
        buffers.pushU8(b, 'b') catch @panic("args_core: buffer push raised");
        argv[0] = wrap.fromBuffer(b);
        refuses(args.getCBytes, .{ a, 0 }, "bytes contain embedded 0s");
    }
    {
        argv[0] = wrap.fromString(strings.new("a\x00b"));
        refuses(args.getCString, .{ a, 0 }, "bytes contain embedded 0s");
    }
}

/// The third cbytes shape: a buffer that cannot be realloced and is exactly
/// full, where pushing a terminator would raise. It is copied with the scratch
/// allocator instead, which the suites never reach: nothing in the runtime
/// sets `JANET_BUFFER_FLAG_NO_REALLOC`, so such a buffer is only ever built by
/// hand, as this case does.
fn cbytesCopiesAFullNoReallocBuffer() raise.Error!void {
    const b = buffers.new(0);
    var backing = [_]u8{ 'a', 'b', 'c' };

    // Not `buffers.init`, which is for a buffer the caller owns: it sets
    // `gc.data.next = null` and `gc.flags = JANET_MEM_DISABLED`, and on a
    // *collectable* buffer that writes through the block at the head of the
    // heap list and severs it.
    //
    // `buffers.deinit` is what this needs: it frees the payload and nulls the
    // pointer, leaving the block on the list and its type intact.
    buffers.deinit(b);
    b.data = &backing;
    b.count = 3;
    b.capacity = 3;
    harness.gcSetBits(&b.gc.flags, constants.JANET_BUFFER_FLAG_NO_REALLOC);

    // The block is on the heap list now, and a value reachable only from a
    // local is
    // not a root. Nothing between here and the restore allocates a collectable
    // block today; the `gcroot` is what keeps that from being load-bearing.
    gc_alloc.gcroot(wrap.fromBuffer(b));
    defer _ = gc_alloc.gcunroot(wrap.fromBuffer(b));

    var argv = [_]repr.Value{wrap.fromBuffer(b)};
    const s = try args.getCBytes(slots(&argv), 0);
    expect(std.mem.eql(u8, std.mem.span(s), "abc"));
    // The copy is a separate allocation, not the buffer's own storage.
    expect(@intFromPtr(s) != @intFromPtr(&backing));
    expect(b.count == 3);
    expect(std.mem.eql(u8, &backing, "abc"));

    // Put it back into a shape `buffers.deinit` can free.
    b.data = null;
    b.count = 0;
    b.capacity = 0;
    b.gc.flags = @bitCast(harness.gcBits(b.gc.flags) & ~@as(u32, constants.JANET_BUFFER_FLAG_NO_REALLOC));
}

/// A `bytes` callback, non-raising because it is reached from paths that
/// cannot act on a refusal, so it is an ordinary Zig function and
/// `abstract_type.define` supplies the calling convention with the cast.
fn probeBytes(p: *const anyopaque, _: usize) []const u8 {
    return @as([*]const u8, @ptrCast(p))[0..3];
}

fn theAbstractGettersAndTheBytesCallback() raise.Error!void {
    const p = abstracts.newBytes(&probe_at, 4);
    const q = abstracts.newBytes(&probe_bytes_at, 4);
    @memcpy(@as([*]u8, @ptrCast(q))[0..3], "xyz");

    var argv = [_]repr.Value{
        wrap.fromAbstract(p),
        wrap.fromAbstract(q),
        wrap.fromNil(),
    };
    const a = slots(&argv);

    expect(try args.getAbstractPtr(a, 0, &probe_at) == p);
    expect(args.checkabstract(argv[0], &probe_at) == p);
    // `checkabstract` reports the mismatch by returning null rather than by
    // raising: it is the same decision with the other half discarded.
    expect(args.checkabstract(argv[0], &other_at) == null);
    expect(args.checkabstract(argv[2], &probe_at) == null);

    refusesWithPrefix(
        args.getAbstractPtr,
        .{ a, 0, &other_at },
        "bad slot #0, expected args-core/other, got <args-core/probe 0x",
    );
    refuses(
        args.getAbstractPtr,
        .{ a, 2, &probe_at },
        "bad slot #2, expected args-core/probe, got nil",
    );

    // An abstract with a `bytes` callback is byte-viewable. One without is
    // not, and faults as an ordinary type mismatch.
    const v = try args.getBytes(a, 1);
    expect(v.len == 3 and std.mem.eql(u8, v.bytes.?[0..3], "xyz"));
    expect(args.bytesView(argv[1]).?.len == 3);
    refusesWithPrefix(
        args.getBytes,
        .{ a, 0 },
        "bad slot #0, expected string, symbol, keyword or buffer, got <args-core/probe 0x",
    );

    expect(try args.optAbstract(a, 0, &probe_at, null) == p);
    expect(try args.optAbstract(a, 2, &probe_at, p) == p);
    expect(try args.optAbstract(a[0..1], 2, &probe_at, p) == p);
}

/// `getCBytes` gives a terminated string for an abstract's byte view, and the
/// zero check measures the view rather than the memory behind it.
///
/// An abstract's `bytes` callback returns whatever the module author chose and
/// nothing requires a terminator after it, which makes this the one shape
/// where the two questions come apart:
///
///  - a check that walks to the first zero measures the memory *after* the
///    view, so a view with no zero in it is refused for containing one as soon
///    as the bytes behind it are non-zero;
///  - a view given back as it stands is a C string that runs past its own end.
///
/// The payload here is eight bytes of `Z` with `xyz` written over the first
/// three, so a walk from the view's start reaches byte 8 and the view reaches
/// byte 3. Both are asserted.
fn cbytesTerminatesAnAbstractsView() raise.Error!void {
    const q = abstracts.newBytes(&probe_bytes_at, 8);
    @memset(@as([*]u8, @ptrCast(q))[0..8], 'Z');
    @memcpy(@as([*]u8, @ptrCast(q))[0..3], "xyz");

    var argv = [_]repr.Value{wrap.fromAbstract(q)};
    const a = slots(&argv);

    // The view is three bytes and the five behind it are not zero, so a walk
    // and a measurement disagree about it. The walk is asserted to pass the
    // view rather than to stop anywhere: where it stops is a property of
    // whatever the allocator put after the payload, which is the reason a walk
    // is the wrong instrument here.
    const v = try args.getBytes(a, 0);
    expect(v.len == 3);
    expect(std.mem.len(@as([*:0]const u8, @ptrCast(v.bytes.?))) >= 8);

    // What comes back is a terminated copy of the view rather than the view.
    const s = try args.getCBytes(a, 0);
    expect(std.mem.eql(u8, std.mem.span(s), "xyz"));
    expect(@intFromPtr(s) != @intFromPtr(v.bytes.?));
    // And the payload is untouched.
    expect(std.mem.eql(u8, @as([*]const u8, @ptrCast(q))[0..8], "xyzZZZZZ"));

    // A zero *inside* the view is still an embedded zero.
    @as([*]u8, @ptrCast(q))[1] = 0;
    refuses(args.getCBytes, .{ a, 0 }, "bytes contain embedded 0s");
}

fn pastTheEndAndAnExplicitNilBothMeanTheDefault() raise.Error!void {
    var argv = [_]repr.Value{
        harness.wrapInteger(5),
        wrap.fromNil(),
        value.fromBytes("s", .string),
    };
    const a = slots(&argv);

    expect(try args.optInteger(a, 0, 99) == 5);
    expect(try args.optInteger(a, 1, 99) == 99);
    expect(try args.optInteger(a, 7, 99) == 99);
    expect(try args.optNat(a, 1, 4) == 4);
    expect(try args.optSize(a, 1, 8) == 8);
    expect(try args.optUInteger(a, 1, 8) == 8);
    expect(try args.optUInteger64(a, 1, 8) == 8);
    expect(try args.optInteger64(a, 1, 8) == 8);
    expect(try args.optNumber(a, 0, 0.0) == 5.0);
    expect(harness.stringIs((try args.optString(a, 2, null)).?, "s"));
    expect(try args.optString(a, 1, null) == null);
    expect(harness.stringIs((try args.optCString(a, 2, "d")).?, "s"));
    expect(std.mem.eql(u8, std.mem.span((try args.optCString(a, 1, "d")).?), "d"));
    expect(std.mem.eql(u8, std.mem.span((try args.optCBytes(a, 1, "d")).?), "d"));
    expect(try args.optBoolean(a, 1, true));
    expect(try args.optPointer(a, 1, null) == null);
    expect(try args.optCFunction(a, 1, null) == null);
    expect(try args.optFiber(a, 1, null) == null);
    expect(try args.optFunction(a, 1, null) == null);
    expect(try args.optTuple(a, 1, null) == null);
    expect(try args.optStruct(a, 1, null) == null);
    expect(try args.optKeyword(a, 1, null) == null);
    expect(try args.optSymbol(a, 1, null) == null);

    // Anything else is delegated to the strict getter, faults included.
    refuses(
        args.optInteger,
        .{ a, 2, 99 },
        "bad slot #2, expected 32 bit signed integer, got \"s\"",
    );

    // The three length-defaulted getters build an empty collection instead of
    // taking one, so the default is a capacity rather than a value.
    const b = try args.optBuffer(a, 1, 16);
    const t = try args.optTable(a, 1, 4);
    const array = try args.optArray(a, 1, 4);
    expect(b.count == 0 and b.capacity >= 16);
    expect(t.count == 0);
    expect(array.count == 0);
    argv[1] = wrap.fromBuffer(b);
    expect(try args.optBuffer(a, 1, 16) == b);
    argv[1] = wrap.fromNil();
}

fn theThreeStrlikeComparisonsCheckTheTypeToo() void {
    expect(args.keyeq(value.fromBytes("a", .keyword), "a"));
    expect(!args.keyeq(value.fromBytes("a", .keyword), "b"));
    // The type has to match as well as the bytes, which is the whole reason
    // there are three of these rather than one.
    expect(!args.keyeq(value.fromBytes("a", .string), "a"));
    expect(!args.keyeq(value.fromBytes("a", .symbol), "a"));
    expect(args.streq(value.fromBytes("a", .string), "a"));
    expect(!args.streq(value.fromBytes("a", .keyword), "a"));
    expect(args.symeq(value.fromBytes("a", .symbol), "a"));
    expect(!args.symeq(value.fromBytes("a", .string), "a"));
    expect(!args.streq(wrap.fromNil(), "a"));
    expect(args.streq(value.fromBytes("", .string), ""));
}

fn methodOne(argv: []repr.Value) raise.Error!repr.Value {
    _ = @as(i32, @intCast(argv.len));

    return harness.wrapInteger(1);
}

fn methodTwo(argv: []repr.Value) raise.Error!repr.Value {
    _ = @as(i32, @intCast(argv.len));

    return harness.wrapInteger(2);
}

fn nextmethodIsAnIterator() void {
    var out = wrap.fromNil();

    expect(args.getmethod(strings.cstring("one"), &methods, &out) != 0);
    expect(wrap.toCfunction(out) == method_one);
    expect(args.getmethod(strings.cstring("two"), &methods, &out) != 0);
    expect(wrap.toCfunction(out) == method_two);
    expect(args.getmethod(strings.cstring("three"), &methods, &out) == 0);

    // `nextmethod` is an iterator: nil starts at the head, and any other key
    // resumes after the entry it names. Running off the end yields nil, and so
    // does a key that is not in the table at all, since it walks to the end
    // looking for it.
    var k = args.nextmethod(&methods, wrap.fromNil());
    expect(args.keyeq(k, "one"));
    k = args.nextmethod(&methods, k);
    expect(args.keyeq(k, "two"));
    k = args.nextmethod(&methods, k);
    expect(harness.isType(k, repr.Tag.nil));
    expect(harness.isType(args.nextmethod(&methods, value.fromBytes("nope", .keyword)), repr.Tag.nil));
}

/// The ten check functions are the argument layer's own vocabulary, and
/// `getSize` is the only caller of `args.checksize` that could otherwise show
/// a disagreement between the two. Each predicate is asserted against the
/// getter beside it, so a check that drifted from what its getter accepts
/// would show here.
fn thePredicatesAgreeWithTheGetters() void {
    expect(args.checkint(harness.wrapInteger(0)));
    expect(!args.checkint(wrap.fromNil()));
    expect(!args.checkint(value.fromBytes("1", .string)));
    expect(!args.checkuint(wrap.fromNumber(-0.0001)));
    expect(args.checkuint(wrap.fromNumber(0.0)));

    expect(!args.checksize(wrap.fromNumber(0.5)));
    expect(args.checksize(wrap.fromNumber(0.0)));
    expect(args.checksize(wrap.fromNumber(1.0)));
    // The largest size and the first double past it, which is a different pair
    // per pointer width: a 64-bit `size_t` exceeds 2^53, so the cap there is
    // the last integer a double holds exactly, and a 32-bit one caps at
    // `SIZE_MAX` itself.
    if (@bitSizeOf(usize) == 64) {
        expect(args.checksize(wrap.fromNumber(9007199254740992.0)));
        expect(!args.checksize(wrap.fromNumber(9007199254740994.0)));
    } else {
        expect(args.checksize(wrap.fromNumber(4294967295.0)));
        expect(!args.checksize(wrap.fromNumber(4294967296.0)));
    }

    // `getInteger64` reaches `checkint64` only in a build without integer
    // types, so the predicate is asserted here: both ends of its range, the
    // first double past each, and a value that is not a number.
    expect(args.checkint64(wrap.fromNumber(9007199254740992.0)));
    expect(args.checkint64(wrap.fromNumber(-9007199254740992.0)));
    expect(!args.checkint64(wrap.fromNumber(9007199254740994.0)));
    expect(!args.checkint64(wrap.fromNumber(-9007199254740994.0)));
    expect(!args.checkint64(value.fromBytes("1", .string)));

    // NaN and the infinities fail the first comparison at every width rather
    // than reaching a conversion.
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);
    expect(!args.checkint(wrap.fromNumber(nan)));
    expect(!args.checkuint(wrap.fromNumber(nan)));
    expect(!args.checkfloat(wrap.fromNumber(nan)));
    expect(!args.checkint(wrap.fromNumber(inf)));
    expect(!args.checkint(wrap.fromNumber(-inf)));
    expect(!args.checkfloat(wrap.fromNumber(inf)));
    // `args.checksize` is absent here for the reason given above.
}

// helpers, which are the substrate the getters are built on and move with
// them. Their failure is a null rather than a fault.

fn theViewHelpersAnswerNothingRatherThanRefusing() void {
    const array = arrays.new(0);
    harness.arrayPush(array, harness.wrapInteger(1));
    const from_array = args.indexedView(wrap.fromArray(array)).?;
    expect(from_array.len == 1);
    const tuple = wrap.fromTuple(tuples.newFrom(from_array[0..1]));
    expect(args.indexedView(tuple).?.len == 1);
    expect(args.indexedView(wrap.fromNil()) == null);

    expect(args.bytesView(value.fromBytes("ab", .string)).?.len == 2);
    expect(args.bytesView(value.fromBytes("ab", .symbol)).?.len == 2);
    expect(args.bytesView(harness.wrapInteger(1)) == null);

    const t = tables.new(1);
    tables.put(t, value.fromBytes("k", .keyword), harness.wrapInteger(1));
    const dict = args.dictionaryView(wrap.fromTable(t)).?;
    expect(dict.len == 1 and dict.cap == t.capacity);
    expect(args.dictionaryView(wrap.fromNil()) == null);
}

// ==========================================================================
// Entry
// ==========================================================================

fn body() raise.Error!void {
    try arityIsCheckedAtBothBounds();
    try everyTypeGetterNamesItsSlotAndItsType();
    try everyExpectationCodeHasItsOwnNoun();
    try theWidthsAcceptExactlyTheirRange();
    try getFloatTakesTheWholeFloatRange();
    try theTwoFoldingsDifferInOneEnd();
    try getSliceCollapsesAnInvertedRange();
    try eachCharacterContributesTheBitAtItsPosition();
    try theByteAndCstringShapes();
    try cbytesCopiesAFullNoReallocBuffer();
    try theAbstractGettersAndTheBytesCallback();
    try cbytesTerminatesAnAbstractsView();
    try pastTheEndAndAnExplicitNilBothMeanTheDefault();
    theThreeStrlikeComparisonsCheckTheTypeToo();
    nextmethodIsAnIterator();
    thePredicatesAgreeWithTheGetters();
    theViewHelpersAnswerNothingRatherThanRefusing();
}

pub fn run() void {
    harness.init();
    body() catch @panic("args_core: a getter raised unexpectedly");
    vm_lifecycle.deinit();
}
