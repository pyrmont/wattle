//! Behavioral contract for the argument extraction layer.
//!
//! What is under test is a set of decisions and a set of messages, and the two
//! are checked separately because the port separates them. The kernels decide
//! and fill in a `JanetArgFault`; `raiseFault` renders it. So every case below
//! drives a getter and compares the payload byte for byte, which is the only
//! way to show that a fault code plus a slot really does reconstruct the
//! message the C original raised.
//!
//! The suites reach almost none of this. A Janet program that calls a
//! cfunction with the wrong argument sees one of these messages and stops, so
//! the common shapes are covered incidentally and the rest — every width of
//! integer, both range foldings, the flag ceiling, the three cbytes shapes —
//! are not reached at all. They are enumerated here.
//!
//! Two behaviors are pinned rather than asserted as correct. `janet_checkfloat`
//! tests against `FLT_MIN`, so `getFloat` rejects zero and every negative
//! number; and `getFlags` silently ignores a permitted set longer than 64
//! characters. Both are in `FOUND.md`, both are reproduced by the port, and
//! both are pinned so that a later fix has to be deliberate.
//!
//! ## What the migration changed, and the defect it found
//!
//! **Every getter here is called by import.** This is the largest face family
//! in the tree — seventy-odd `janet_get*` and `janet_opt*` exports, each a
//! `raise.panicking` wrapper — and *none of them may be retired*, because they
//! are exactly what `janet.h` promises an embedder. So this migration retires
//! no face at all and instead adds seventy names to the exported-symbol-surface
//! bullet's list of public exports with no in-tree caller: the runtime reaches
//! the layer through `arglayer.zig`, and the only Zig callers left are
//! `interop.zig` and `native_module.zig`, which wrap each in `raise.crossing`
//! deliberately.
//!
//! **Writing the file found a live defect, and it was in a caller.** The C
//! contract skipped `janet_getinteger64` and `janet_getuinteger64` whenever
//! `JANET_INT_TYPES` was defined, which is the default — its `EXPECTED_PANICS`
//! is 70 with integer types and 74 without — because in that configuration
//! those two do not fill in a fault at all: they delegate to
//! `janet_unwrap_s64`, which raises its own message. Translating that skip
//! into Zig is what raised the question of *how* it raises, and the answer was
//! that `args_core.zig` called the **C face**, so a refusal became a report
//! nobody consumed. `(string/format "%d" "x")` aborted the process with
//! `janet abort: a raise was reported to a C caller and never consumed`
//! instead of raising a catchable error. The fix is in `args_core.zig`'s
//! `Wide`, and the two cases below are asserted in *both* configurations
//! rather than skipped in one — which is the assertion the C contract could
//! not make.
//!
//! **No panic counter.** The C original counted its seventy, because a case
//! that silently stopped raising would otherwise look like one that passed.
//! Here a refusal is a value and `refuses` unwraps a null, so the counter's
//! job is done by the type.

const std = @import("std");
const abi = @import("abi");
const c = abi.c;
const raise = @import("raise");
const harness = @import("harness.zig");

const subsystems = @import("subsystems");
const args = subsystems.args_core;
const abstract_type = subsystems.abstract_type;
const AbstractType = abstract_type.AbstractType;

const assert = std.debug.assert;

// ------------------------------------------------------------- assertions

/// The refusal a getter made, or a failure naming the case that did not make
/// one. This is `EXPECT_PANIC`, minus the try scope, the flag and the four
/// lines of protocol the C original needed to see a report.
fn refusal(function: anytype, arguments: anytype) harness.Raise {
    const r = harness.raised(function, arguments) orelse
        @panic("expected a refusal, got a return");
    assert(r.signal == c.JANET_SIGNAL_ERROR);
    assert(harness.isType(r.payload, c.JANET_STRING));
    return r;
}

fn refuses(function: anytype, arguments: anytype, message: []const u8) void {
    const r = refusal(function, arguments);
    if (!r.says(message)) {
        const got = c.janet_unwrap_string(r.payload);
        const length: usize = @intCast(c.janet_string_length(got));
        std.debug.print("expected: {s}\n     got: {s}\n", .{ message, got[0..length] });
        @panic("message mismatch");
    }
}

/// An abstract value renders with its address, so those messages are compared
/// by prefix. Everything else is compared whole.
fn refusesWithPrefix(function: anytype, arguments: anytype, prefix: []const u8) void {
    const r = refusal(function, arguments);
    if (!r.beginsWith(prefix)) {
        const got = c.janet_unwrap_string(r.payload);
        const length: usize = @intCast(c.janet_string_length(got));
        std.debug.print("expected prefix: {s}\n            got: {s}\n", .{ prefix, got[0..length] });
        @panic("message prefix mismatch");
    }
}

fn slots(argv: []const c.Janet) [*c]const c.Janet {
    return argv.ptr;
}

// ------------------------------------------------------------------ arity

fn arityIsCheckedAtBothBounds() raise.Raising(void) {
    try args.fixarity(2, 2);
    try args.arity(2, 1, 3);
    try args.arity(2, -1, -1);
    try args.arity(0, -1, 0);
    try args.arity(99, 1, -1);

    refuses(args.fixarity, .{ 1, 2 }, "arity mismatch, expected 2, got 1");
    refuses(args.fixarity, .{ 3, 2 }, "arity mismatch, expected 2, got 3");
    refuses(args.arity, .{ 0, 1, 3 }, "arity mismatch, expected at least 1, got 0");
    refuses(args.arity, .{ 4, 1, 3 }, "arity mismatch, expected at most 3, got 4");
    // A negative bound is unbounded, so only the other side can fault.
    refuses(args.arity, .{ 4, -1, 3 }, "arity mismatch, expected at most 3, got 4");
    refuses(args.arity, .{ 0, 1, -1 }, "arity mismatch, expected at least 1, got 0");
}

// ------------------------------------------------------------- type faults

fn everyTypeGetterNamesItsSlotAndItsType() raise.Raising(void) {
    var argv = [_]c.Janet{
        c.janet_wrap_nil(),
        harness.wrapInteger(7),
        c.janet_cstringv("hello"),
        c.janet_wrap_true(),
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

    // And the success paths, which have to agree with the C original about
    // where the data and the length come from.
    assert(try args.getNumber(a, 1) == 7.0);
    assert(harness.stringIs(try args.getString(a, 2), "hello"));
    assert(try args.getBoolean(a, 3) == 1);
}

// --------------------------------------------------------- numeric getters

fn everyExpectationCodeHasItsOwnNoun() raise.Raising(void) {
    var argv = [_]c.Janet{
        c.janet_wrap_nil(),
        c.janet_wrap_number(1.5),
        c.janet_wrap_number(-1.0),
    };
    const a = slots(&argv);

    // Every one of the eleven expectation codes, in the words `expectName`
    // spells them. A code that mapped to the wrong noun would show here and
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
    // rest. **Both arms are asserted**: the C contract could only assert the
    // second, because in the first the refusal reached it as a report rather
    // than as a value and it skipped the cases entirely.
    if (comptime @hasDecl(c, "janet_unwrap_s64")) {
        refuses(
            args.getInteger64,
            .{ a, 0 },
            "can not convert nil nil to 64 bit signed integer",
        );
        refuses(
            args.getUInteger64,
            .{ a, 2 },
            // The article is upstream's and the two messages disagree about it:
            // the signed form says "to 64 bit signed integer" and the
            // unsigned one "to a 64 bit unsigned integer". Reproduced rather
            // than tidied.
            "can not convert number -1 to a 64 bit unsigned integer",
        );
    } else {
        refuses(args.getInteger64, .{ a, 1 }, "bad slot #1, expected 64 bit signed integer, got 1.5");
        refuses(args.getUInteger64, .{ a, 2 }, "bad slot #2, expected 64 bit unsigned integer, got -1");
    }
}

/// The boundaries of each width, taken from both sides, because an off-by-one
/// in a range test is invisible to every other test here.
fn theWidthsAcceptExactlyTheirRange() raise.Raising(void) {
    var argv = [_]c.Janet{c.janet_wrap_nil()};

    // `ACCEPTS` and `REJECTS`, which the C original spelled as two macros over
    // a getter name. A Zig contract cannot pass a generic function as a value
    // -- `args.getInteger` is `GetInteger.get`, an ordinary declaration -- so
    // these take it as an `anytype` parameter instead, which is the same thing
    // one indirection later.
    const Case = struct {
        fn accepts(argv_slot: *c.Janet, getter: anytype, value: f64, expected: anytype) void {
            argv_slot.* = c.janet_wrap_number(value);
            const got = getter(slots(@as(*const [1]c.Janet, argv_slot)), 0) catch
                @panic("expected a value, got a refusal");
            assert(got == expected);
        }

        fn rejects(argv_slot: *c.Janet, getter: anytype, value: f64) void {
            argv_slot.* = c.janet_wrap_number(value);
            const a2 = slots(@as(*const [1]c.Janet, argv_slot));
            assert(harness.raised(getter, .{ a2, @as(i32, 0) }) != null);
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

    // Only the defined half of `janet_checksize`'s domain is exercised. The C
    // original casts to `size_t` before testing the round trip, which is
    // undefined for a negative, infinite or enormous double and aborts a
    // sanitizer build outright — reachable from Janet source as
    // `(gcsetinterval -1)`. It is in `FOUND.md`, and per this phase's rules
    // undefined behavior gets no contract, because the result would belong to
    // the development target rather than to the language.
    Case.accepts(slot, args.getSize, 0, 0);
    Case.accepts(slot, args.getSize, 1, 1);
    Case.rejects(slot, args.getSize, 1.5);

    if (comptime !@hasDecl(c, "janet_unwrap_s64")) {
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

/// `janet_checkfloat` tests `>= FLT_MIN`, and `FLT_MIN` is the smallest
/// positive *normal* float rather than the most negative finite one. So
/// `getFloat` rejects zero, every negative value, and every subnormal, and
/// accepts only positive normals that survive a round trip through `f32`.
/// This is a defect in the C implementation, recorded in `FOUND.md`, and it is
/// pinned rather than asserted as correct: the port reproduces it, and a later
/// fix has to be a deliberate change to this test.
fn getFloatRejectsZeroAndNegatives() raise.Raising(void) {
    var argv = [_]c.Janet{c.janet_wrap_number(1.5)};
    const a = slots(&argv);
    assert(try args.getFloat(a, 0) == 1.5);

    argv[0] = c.janet_wrap_number(0.0);
    refuses(args.getFloat, .{ a, 0 }, "bad slot #0, expected float number, got 0");
    argv[0] = c.janet_wrap_number(-1.5);
    refuses(args.getFloat, .{ a, 0 }, "bad slot #0, expected float number, got -1.5");

    const flt_min = std.math.floatMin(f32);
    const flt_max = std.math.floatMax(f32);
    assert(c.janet_checkfloat(c.janet_wrap_number(0.0)) == 0);
    assert(c.janet_checkfloat(c.janet_wrap_number(-1.0)) == 0);
    assert(c.janet_checkfloat(c.janet_wrap_number(@as(f64, flt_min) / 2.0)) == 0);
    assert(c.janet_checkfloat(c.janet_wrap_number(flt_min)) != 0);
    assert(c.janet_checkfloat(c.janet_wrap_number(flt_max)) != 0);
    assert(c.janet_checkfloat(c.janet_wrap_number(@as(f64, flt_max) * 2.0)) == 0);
    // A double with more precision than a float holds fails the round trip.
    assert(c.janet_checkfloat(c.janet_wrap_number(1.0000000000000002)) == 0);
}

// ----------------------------------------------------------------- ranges

fn theTwoFoldingsDifferInOneEnd() raise.Raising(void) {
    var argv = [_]c.Janet{
        harness.wrapInteger(0),
        harness.wrapInteger(3),
        harness.wrapInteger(-1),
        c.janet_wrap_nil(),
    };
    const a = slots(&argv);

    // A half range folds a negative index against length + 1 and accepts
    // length itself, because it names a boundary between elements.
    assert(try args.getHalfRange(a, 0, 10, "start") == 0);
    assert(try args.getHalfRange(a, 1, 10, "start") == 3);
    assert(try args.getHalfRange(a, 2, 10, "end") == 10);
    argv[0] = harness.wrapInteger(10);
    assert(try args.getHalfRange(a, 0, 10, "end") == 10);
    argv[0] = harness.wrapInteger(-11);
    assert(try args.getHalfRange(a, 0, 10, "start") == 0);

    argv[0] = harness.wrapInteger(11);
    refuses(args.getHalfRange, .{ a, 0, 10, "start" }, "start index 11 out of range [-11,10]");
    argv[0] = harness.wrapInteger(-12);
    refuses(args.getHalfRange, .{ a, 0, 10, "end" }, "end index -12 out of range [-11,10]");

    // An argument index folds against length and its interval is half open,
    // yet it still accepts length itself — the one asymmetry between the two.
    argv[0] = harness.wrapInteger(0);
    assert(try args.getArgIndex(a, 0, 10, "at") == 0);
    argv[0] = harness.wrapInteger(-1);
    assert(try args.getArgIndex(a, 0, 10, "at") == 9);
    argv[0] = harness.wrapInteger(-10);
    assert(try args.getArgIndex(a, 0, 10, "at") == 0);

    argv[0] = harness.wrapInteger(11);
    refuses(args.getArgIndex, .{ a, 0, 10, "at" }, "at index 11 out of range [-10,10)");
    argv[0] = harness.wrapInteger(-11);
    refuses(args.getArgIndex, .{ a, 0, 10, "at" }, "at index -11 out of range [-10,10)");

    // A non-integer faults as an integer before any folding happens, so the
    // message names the type rather than the range.
    argv[0] = c.janet_cstringv("x");
    refuses(
        args.getHalfRange,
        .{ a, 0, 10, "start" },
        "bad slot #0, expected 32 bit signed integer, got \"x\"",
    );

    // The start and end forms supply a default when the slot is absent or nil,
    // and the defaults are the two ends of the sequence.
    argv[0] = harness.wrapInteger(4);
    assert(try args.getStartRange(a, 1, 3, 10) == 0);
    assert(try args.getEndRange(a, 1, 3, 10) == 10);
    argv[3] = c.janet_wrap_nil();
    assert(try args.getStartRange(a, 4, 3, 10) == 0);
    assert(try args.getEndRange(a, 4, 3, 10) == 10);
    assert(try args.getStartRange(a, 4, 0, 10) == 4);
}

fn getSliceCollapsesAnInvertedRange() raise.Raising(void) {
    var argv = [_]c.Janet{ c.janet_wrap_nil(), c.janet_wrap_nil(), c.janet_wrap_nil() };
    const array = c.janet_array(0);
    c.janet_array_push(array, harness.wrapInteger(1));
    c.janet_array_push(array, harness.wrapInteger(2));
    c.janet_array_push(array, harness.wrapInteger(3));
    argv[0] = c.janet_wrap_array(array);
    const a = slots(&argv);

    var r = try args.getSlice(1, a);
    assert(r.start == 0 and r.end == 3);

    argv[1] = harness.wrapInteger(1);
    r = try args.getSlice(2, a);
    assert(r.start == 1 and r.end == 3);

    argv[2] = harness.wrapInteger(2);
    r = try args.getSlice(3, a);
    assert(r.start == 1 and r.end == 2);

    // An end before the start collapses to an empty range rather than
    // faulting, which is the one piece of arithmetic `getSlice` does itself.
    argv[1] = harness.wrapInteger(3);
    argv[2] = harness.wrapInteger(1);
    r = try args.getSlice(3, a);
    assert(r.start == 3 and r.end == 3);

    refuses(args.getSlice, .{ 0, a }, "arity mismatch, expected at least 1, got 0");
    refuses(args.getSlice, .{ 4, a }, "arity mismatch, expected at most 3, got 4");
}

// ------------------------------------------------------------------ flags

fn eachCharacterContributesTheBitAtItsPosition() raise.Raising(void) {
    var argv = [_]c.Janet{ c.janet_ckeywordv("acb"), c.janet_ckeywordv("z") };
    const a = slots(&argv);

    // Each character contributes the bit at its position in the permitted set,
    // and the order of the keyword does not matter.
    assert(try args.getFlags(a, 0, "abc") == 0x7);
    argv[0] = c.janet_ckeywordv("");
    assert(try args.getFlags(a, 0, "abc") == 0);
    argv[0] = c.janet_ckeywordv("c");
    assert(try args.getFlags(a, 0, "abc") == 0x4);
    // A repeated character sets the same bit twice, which is not an error.
    argv[0] = c.janet_ckeywordv("aa");
    assert(try args.getFlags(a, 0, "abc") == 0x1);

    refuses(args.getFlags, .{ a, 1, "abc" }, "unexpected flag z, expected one of \"abc\"");

    // Not a keyword at all faults before any scanning.
    argv[0] = c.janet_cstringv("a");
    refuses(args.getFlags, .{ a, 0, "abc" }, "bad slot #0, expected keyword, got \"a\"");

    // A permitted set longer than 64 characters has its tail silently ignored,
    // so a character that appears only past the ceiling is reported as
    // unexpected rather than accepted. Pinned, not endorsed: `FOUND.md`.
    var wide: [80]u8 = @splat(0);
    for (0..70) |i| wide[i] = '0' + @as(u8, @intCast(i % 10));
    wide[64] = 'Z';
    wide[70] = 0;
    argv[0] = c.janet_ckeywordv("Z");
    refuses(
        args.getFlags,
        .{ a, 0, @as([*c]const u8, &wide) },
        "unexpected flag Z, expected one of " ++
            "\"0123456789012345678901234567890123456789012345678901234567890123Z56789\"",
    );
}

// ------------------------------------------------------------- byte access

fn theByteAndCstringShapes() raise.Raising(void) {
    var argv = [_]c.Janet{
        c.janet_cstringv("hi"),
        c.janet_wrap_buffer(c.janet_buffer(8)),
        c.janet_ckeywordv("kw"),
        c.janet_wrap_nil(),
    };
    c.janet_buffer_push_cstring(c.janet_unwrap_buffer(argv[1]), "buf");
    const a = slots(&argv);

    var v = try args.getBytes(a, 0);
    assert(v.len == 2 and std.mem.eql(u8, v.bytes[0..2], "hi"));
    v = try args.getBytes(a, 1);
    assert(v.len == 3 and std.mem.eql(u8, v.bytes[0..3], "buf"));
    v = try args.getBytes(a, 2);
    assert(v.len == 2 and std.mem.eql(u8, v.bytes[0..2], "kw"));

    assert(std.mem.eql(u8, std.mem.span(@as([*:0]const u8, @ptrCast(try args.getCString(a, 0)))), "hi"));
    assert(std.mem.eql(u8, std.mem.span(@as([*:0]const u8, @ptrCast(try args.getCBytes(a, 1)))), "buf"));
    // The terminating shape leaves the buffer's visible count alone: the zero
    // is written past the end and the count is put back.
    assert(c.janet_unwrap_buffer(argv[1]).*.count == 3);

    refuses(args.getCString, .{ a, 1 }, "bad slot #1, expected string, got @\"buf\"");
    refuses(args.getCString, .{ a, 3 }, "bad slot #3, expected string, got nil");
    refuses(
        args.getCBytes,
        .{ a, 3 },
        "bad slot #3, expected string, symbol, keyword or buffer, got nil",
    );

    // An embedded zero is rejected for every shape that can carry one.
    {
        const b = c.janet_buffer(8);
        c.janet_buffer_push_u8(b, 'a');
        c.janet_buffer_push_u8(b, 0);
        c.janet_buffer_push_u8(b, 'b');
        argv[0] = c.janet_wrap_buffer(b);
        refuses(args.getCBytes, .{ a, 0 }, "bytes contain embedded 0s");
    }
    {
        argv[0] = c.janet_wrap_string(c.janet_string("a\x00b", 3));
        refuses(args.getCString, .{ a, 0 }, "bytes contain embedded 0s");
    }
}

/// The third cbytes shape: a buffer that cannot be realloced and is exactly
/// full, where pushing a terminator would raise. It is copied with the scratch
/// allocator instead, which the suites never reach because a no-realloc buffer
/// only comes from `janet_buffer_init_custom` paths.
fn cbytesCopiesAFullNoReallocBuffer() raise.Raising(void) {
    const b = c.janet_buffer(0);
    var backing = [_]u8{ 'a', 'b', 'c' };

    // **Not `janet_buffer_init`.** That is for a buffer the caller owns: it
    // sets `gc.data.next = null` and `gc.flags = JANET_MEM_DISABLED`, which on
    // a *collectable* buffer writes through the block at the head of
    // `janet_vm.blocks` and severs the heap list behind it. This contract did
    // that for the whole of Phase 11 and orphaned eighty-four blocks, which is
    // the eighty-eight `leaks --atExit` has been reporting since Part 1.
    //
    // `janet_buffer_deinit` alone is what this needs: it frees the payload and
    // nulls the pointer, leaving the block on the list and its type intact.
    c.janet_buffer_deinit(b);
    b.*.data = &backing;
    b.*.count = 3;
    b.*.capacity = 3;
    b.*.gc.flags |= c.JANET_BUFFER_FLAG_NO_REALLOC;

    // The block is on the heap list now, and nothing on the Zig stack roots
    // it -- `AGENTS.md`'s rule about a `Janet` in a local. Nothing between
    // here and the restore allocates a collectable block today; the root is
    // what keeps that from being load-bearing.
    c.janet_gcroot(c.janet_wrap_buffer(b));
    defer _ = c.janet_gcunroot(c.janet_wrap_buffer(b));

    var argv = [_]c.Janet{c.janet_wrap_buffer(b)};
    const s = try args.getCBytes(slots(&argv), 0);
    assert(std.mem.eql(u8, std.mem.span(@as([*:0]const u8, @ptrCast(s))), "abc"));
    // The copy is a separate allocation, not the buffer's own storage.
    assert(@intFromPtr(s) != @intFromPtr(&backing));
    assert(b.*.count == 3);
    assert(std.mem.eql(u8, &backing, "abc"));

    // Put it back into a shape `janet_buffer_deinit` can free.
    b.*.data = null;
    b.*.count = 0;
    b.*.capacity = 0;
    b.*.gc.flags &= ~@as(i32, c.JANET_BUFFER_FLAG_NO_REALLOC);
}

// ---------------------------------------------------------------- abstract

const probe_at: AbstractType = .{ .name = "args-core/probe" };
const other_at: AbstractType = .{ .name = "args-core/other" };

/// A `bytes` callback, which the hinge left non-raising because it is reached
/// from paths that cannot act on a refusal. So this is an ordinary
/// `callconv(.c)` function and the C contract's `CONTRACT_AT` pool is not
/// needed to install it.
fn probeBytes(p: ?*anyopaque, len: usize) callconv(.c) c.JanetByteView {
    _ = len;
    return .{ .bytes = @ptrCast(p), .len = 3 };
}

const probe_bytes_at: AbstractType = .{ .name = "args-core/bytes-probe", .bytes = probeBytes };

fn theAbstractGettersAndTheBytesCallback() raise.Raising(void) {
    const p = c.janet_abstract(abstract_type.stored(&probe_at), 4);
    const q = c.janet_abstract(abstract_type.stored(&probe_bytes_at), 4);
    @memcpy(@as([*]u8, @ptrCast(q))[0..3], "xyz");

    var argv = [_]c.Janet{
        c.janet_wrap_abstract(p),
        c.janet_wrap_abstract(q),
        c.janet_wrap_nil(),
    };
    const a = slots(&argv);

    assert(try args.getAbstract(a, 0, abstract_type.stored(&probe_at)) == p);
    assert(c.janet_checkabstract(argv[0], abstract_type.stored(&probe_at)) == p);
    // `checkabstract` reports the mismatch by returning null rather than by
    // raising: it is the same decision with the other half discarded.
    assert(c.janet_checkabstract(argv[0], abstract_type.stored(&other_at)) == null);
    assert(c.janet_checkabstract(argv[2], abstract_type.stored(&probe_at)) == null);

    refusesWithPrefix(
        args.getAbstract,
        .{ a, 0, abstract_type.stored(&other_at) },
        "bad slot #0, expected args-core/other, got <args-core/probe 0x",
    );
    refuses(
        args.getAbstract,
        .{ a, 2, abstract_type.stored(&probe_at) },
        "bad slot #2, expected args-core/probe, got nil",
    );

    // An abstract with a `bytes` callback is byte-viewable. One without is
    // not, and faults as an ordinary type mismatch.
    var v = try args.getBytes(a, 1);
    assert(v.len == 3 and std.mem.eql(u8, v.bytes[0..3], "xyz"));
    assert(c.janet_bytes_view(argv[1], &v.bytes, &v.len) != 0);
    assert(v.len == 3);
    refusesWithPrefix(
        args.getBytes,
        .{ a, 0 },
        "bad slot #0, expected string, symbol, keyword or buffer, got <args-core/probe 0x",
    );

    assert(try args.optAbstract(a, 3, 0, abstract_type.stored(&probe_at), null) == p);
    assert(try args.optAbstract(a, 3, 2, abstract_type.stored(&probe_at), p) == p);
    assert(try args.optAbstract(a, 1, 2, abstract_type.stored(&probe_at), p) == p);
}

// -------------------------------------------------------------- defaulting

fn pastTheEndAndAnExplicitNilBothMeanTheDefault() raise.Raising(void) {
    var argv = [_]c.Janet{
        harness.wrapInteger(5),
        c.janet_wrap_nil(),
        c.janet_cstringv("s"),
    };
    const a = slots(&argv);

    assert(try args.optInteger(a, 3, 0, 99) == 5);
    assert(try args.optInteger(a, 3, 1, 99) == 99);
    assert(try args.optInteger(a, 3, 7, 99) == 99);
    assert(try args.optNat(a, 3, 1, 4) == 4);
    assert(try args.optSize(a, 3, 1, 8) == 8);
    assert(try args.optUInteger(a, 3, 1, 8) == 8);
    assert(try args.optUInteger64(a, 3, 1, 8) == 8);
    assert(try args.optInteger64(a, 3, 1, 8) == 8);
    assert(try args.optNumber(a, 3, 0, 0.0) == 5.0);
    assert(harness.stringIs(try args.optString(a, 3, 2, null), "s"));
    assert(try args.optString(a, 3, 1, null) == null);
    assert(harness.stringIs(@ptrCast(try args.optCString(a, 3, 2, "d")), "s"));
    assert(std.mem.eql(u8, std.mem.span(@as([*:0]const u8, @ptrCast(try args.optCString(a, 3, 1, "d")))), "d"));
    assert(std.mem.eql(u8, std.mem.span(@as([*:0]const u8, @ptrCast(try args.optCBytes(a, 3, 1, "d")))), "d"));
    assert(try args.optBoolean(a, 3, 1, 1) == 1);
    assert(try args.optPointer(a, 3, 1, null) == null);
    assert(try args.optCFunction(a, 3, 1, null) == null);
    assert(try args.optFiber(a, 3, 1, null) == null);
    assert(try args.optFunction(a, 3, 1, null) == null);
    assert(try args.optTuple(a, 3, 1, null) == null);
    assert(try args.optStruct(a, 3, 1, null) == null);
    assert(try args.optKeyword(a, 3, 1, null) == null);
    assert(try args.optSymbol(a, 3, 1, null) == null);

    // Anything else is delegated to the strict getter, faults included.
    refuses(
        args.optInteger,
        .{ a, 3, 2, 99 },
        "bad slot #2, expected 32 bit signed integer, got \"s\"",
    );

    // The three length-defaulted getters build an empty collection instead of
    // taking one, so the default is a capacity rather than a value.
    const b = try args.optBuffer(a, 3, 1, 16);
    const t = try args.optTable(a, 3, 1, 4);
    const array = try args.optArray(a, 3, 1, 4);
    assert(b != null and b.*.count == 0 and b.*.capacity >= 16);
    assert(t != null and t.*.count == 0);
    assert(array != null and array.*.count == 0);
    argv[1] = c.janet_wrap_buffer(b);
    assert(try args.optBuffer(a, 3, 1, 16) == b);
    argv[1] = c.janet_wrap_nil();
}

// ---------------------------------------------------------------- strlike

fn theThreeStrlikeComparisonsCheckTheTypeToo() void {
    assert(c.janet_keyeq(c.janet_ckeywordv("a"), "a") != 0);
    assert(c.janet_keyeq(c.janet_ckeywordv("a"), "b") == 0);
    // The type has to match as well as the bytes, which is the whole reason
    // there are three of these rather than one.
    assert(c.janet_keyeq(c.janet_cstringv("a"), "a") == 0);
    assert(c.janet_keyeq(c.janet_csymbolv("a"), "a") == 0);
    assert(c.janet_streq(c.janet_cstringv("a"), "a") != 0);
    assert(c.janet_streq(c.janet_ckeywordv("a"), "a") == 0);
    assert(c.janet_symeq(c.janet_csymbolv("a"), "a") != 0);
    assert(c.janet_symeq(c.janet_cstringv("a"), "a") == 0);
    assert(c.janet_streq(c.janet_wrap_nil(), "a") == 0);
    assert(c.janet_streq(c.janet_cstringv(""), "") != 0);
}

// ---------------------------------------------------------------- methods

fn methodOne(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    _ = argc;
    _ = argv;
    return harness.wrapInteger(1);
}

fn methodTwo(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    _ = argc;
    _ = argv;
    return harness.wrapInteger(2);
}

const method_one = raise.stored(&methodOne);
const method_two = raise.stored(&methodTwo);

const methods = [_]c.JanetMethod{
    .{ .name = "one", .cfun = method_one },
    .{ .name = "two", .cfun = method_two },
    .{ .name = null, .cfun = null },
};

fn nextmethodIsAnIterator() void {
    var out = c.janet_wrap_nil();

    assert(c.janet_getmethod(c.janet_cstring("one"), &methods, &out) != 0);
    assert(c.janet_unwrap_cfunction(out) == method_one);
    assert(c.janet_getmethod(c.janet_cstring("two"), &methods, &out) != 0);
    assert(c.janet_unwrap_cfunction(out) == method_two);
    assert(c.janet_getmethod(c.janet_cstring("three"), &methods, &out) == 0);

    // `nextmethod` is an iterator: nil starts at the head, and any other key
    // resumes after the entry it names. Running off the end yields nil, and so
    // does a key that is not in the table at all — it walks to the end looking
    // for it.
    var k = c.janet_nextmethod(&methods, c.janet_wrap_nil());
    assert(c.janet_keyeq(k, "one") != 0);
    k = c.janet_nextmethod(&methods, k);
    assert(c.janet_keyeq(k, "two") != 0);
    k = c.janet_nextmethod(&methods, k);
    assert(harness.isType(k, c.JANET_NIL));
    assert(harness.isType(c.janet_nextmethod(&methods, c.janet_ckeywordv("nope")), c.JANET_NIL));
}

// ------------------------------------------------------------- predicates

/// The ten check functions are public API in their own right, and `getSize` is
/// the only caller of `janet_checksize` that could otherwise show a
/// disagreement. The C original casts to `size_t` before testing, which is
/// undefined for a negative or enormous double; the port tests before casting.
/// Every input either language defines has to reach the same answer.
fn thePredicatesAgreeWithTheGetters() void {
    assert(c.janet_checkint(harness.wrapInteger(0)) != 0);
    assert(c.janet_checkint(c.janet_wrap_nil()) == 0);
    assert(c.janet_checkint(c.janet_cstringv("1")) == 0);
    assert(c.janet_checkuint(c.janet_wrap_number(-0.0001)) == 0);
    assert(c.janet_checkuint(c.janet_wrap_number(0.0)) != 0);

    assert(c.janet_checksize(c.janet_wrap_number(0.5)) == 0);
    assert(c.janet_checksize(c.janet_wrap_number(0.0)) != 0);
    assert(c.janet_checksize(c.janet_wrap_number(1.0)) != 0);
    assert(c.janet_checksize(c.janet_wrap_number(9007199254740992.0)) != 0);
    assert(c.janet_checksize(c.janet_wrap_number(9007199254740994.0)) == 0);

    // NaN and the infinities fail the first comparison at every width rather
    // than reaching a conversion.
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);
    assert(c.janet_checkint(c.janet_wrap_number(nan)) == 0);
    assert(c.janet_checkuint(c.janet_wrap_number(nan)) == 0);
    assert(c.janet_checkfloat(c.janet_wrap_number(nan)) == 0);
    assert(c.janet_checkint(c.janet_wrap_number(inf)) == 0);
    assert(c.janet_checkint(c.janet_wrap_number(-inf)) == 0);
    assert(c.janet_checkfloat(c.janet_wrap_number(inf)) == 0);
    // `janet_checksize` is absent here for the reason given above.
}

// ---------------------------------------------------------------- the view
// helpers, which are the substrate the getters are built on and move with
// them. Their failure is a return value rather than a fault.

fn theViewHelpersAnswerFalseRatherThanRefusing() void {
    var items: [*c]const c.Janet = undefined;
    var bytes: [*c]const u8 = undefined;
    var kvs: [*c]const c.JanetKV = undefined;
    var len: i32 = 0;
    var cap: i32 = 0;

    const array = c.janet_array(0);
    c.janet_array_push(array, harness.wrapInteger(1));
    assert(c.janet_indexed_view(c.janet_wrap_array(array), &items, &len) != 0);
    assert(len == 1);
    const tuple = c.janet_wrap_tuple(c.janet_tuple_n(items, 1));
    assert(c.janet_indexed_view(tuple, &items, &len) != 0);
    assert(len == 1);
    assert(c.janet_indexed_view(c.janet_wrap_nil(), &items, &len) == 0);

    assert(c.janet_bytes_view(c.janet_cstringv("ab"), &bytes, &len) != 0);
    assert(len == 2);
    assert(c.janet_bytes_view(c.janet_csymbolv("ab"), &bytes, &len) != 0);
    assert(len == 2);
    assert(c.janet_bytes_view(harness.wrapInteger(1), &bytes, &len) == 0);

    const t = c.janet_table(1);
    c.janet_table_put(t, c.janet_ckeywordv("k"), harness.wrapInteger(1));
    assert(c.janet_dictionary_view(c.janet_wrap_table(t), &kvs, &len, &cap) != 0);
    assert(len == 1 and cap == t.*.capacity);
    assert(c.janet_dictionary_view(c.janet_wrap_nil(), &kvs, &len, &cap) == 0);
}

// ------------------------------------------------------------------ entry

fn body() raise.Raising(void) {
    try arityIsCheckedAtBothBounds();
    try everyTypeGetterNamesItsSlotAndItsType();
    try everyExpectationCodeHasItsOwnNoun();
    try theWidthsAcceptExactlyTheirRange();
    try getFloatRejectsZeroAndNegatives();
    try theTwoFoldingsDifferInOneEnd();
    try getSliceCollapsesAnInvertedRange();
    try eachCharacterContributesTheBitAtItsPosition();
    try theByteAndCstringShapes();
    try cbytesCopiesAFullNoReallocBuffer();
    try theAbstractGettersAndTheBytesCallback();
    try pastTheEndAndAnExplicitNilBothMeanTheDefault();
    theThreeStrlikeComparisonsCheckTheTypeToo();
    nextmethodIsAnIterator();
    thePredicatesAgreeWithTheGetters();
    theViewHelpersAnswerFalseRatherThanRefusing();
}

pub fn run() void {
    _ = c.janet_init();
    body() catch @panic("args_core: a getter raised unexpectedly");
    c.janet_deinit();

    std.debug.print("args core contract ok\n", .{});
}
