//! The five smoke tests the image generator runs before it generates anything.
//!
//! `boot.zig`'s `main` calls `all`, which runs the five in order, and nothing
//! else calls them. They run before the core environment exists, so a raise
//! has no protected scope above it and `expect` turns every failure into a
//! panic naming the check.
//!
//! What each covers: `arrayTest` that an array grows, pops and compares
//! elementwise; `bufferTest` that a buffer's two ways of filling it produce
//! the same bytes; `numberTest` that number scanning matches the system's
//! `atof` on base ten; `systemTest` the pointer width, reflexive equality over
//! every immediate and both number forms, and structural equality over
//! strings, symbols and tuples; and `tableTest` that a table puts, gets and
//! removes.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");
const builtin = @import("builtin");

// ==========================================================================
// Project imports
// ==========================================================================

const arrays = subsystems.value.arrays;
const buffers = subsystems.value.buffers;
const config = @import("config");
const order = subsystems.value.order;
const repr = @import("repr");
const scan = subsystems.scan;
const subsystems = @import("subsystems");
const tables = subsystems.value.tables;
const tuples = subsystems.value.tuples;
const value = subsystems.value;
const wrap = subsystems.value.wrap;

// ==========================================================================
// Public functions
// ==========================================================================

/// Runs the five smoke tests in order.
///
/// `boot.zig`'s `main` is the one caller, and it calls this before it
/// generates anything. A failed check panics rather than returning.
pub fn all() void {
    arrayTest();
    bufferTest();
    numberTest();
    systemTest();
    tableTest();
}

/// Checks that an array grows, pops and compares elementwise.
///
/// A failed check panics.
pub fn arrayTest() void {
    const array1 = arrays.new(10);
    const array2 = arrays.new(0);

    const words = [_][*:0]const u8{ "one", "two", "three", "four", "five", "six", "seven" };
    for (words) |w| push(array1, stringv(std.mem.span(w)));
    expect(array1.*.count == 7, "array1 count");
    expect(array1.*.capacity >= 7, "array1 capacity");
    expect(order.equals(array1.*.slice()[0], stringv("one")), "array1 first");

    for (words) |w| push(array2, stringv(std.mem.span(w)));
    var i: i32 = 0;
    while (i < array2.*.count) : (i += 1) {
        expect(
            order.equals(array1.*.slice()[@intCast(i)], array2.*.slice()[@intCast(i)]),
            "arrays agree elementwise",
        );
    }

    _ = arrays.pop(array1);
    _ = arrays.pop(array1);
    expect(array1.*.count == 5, "array1 count after two pops");
}

/// Checks that a buffer's two ways of filling it produce the same bytes.
///
/// One buffer is filled with a C string and the other byte by byte, and the
/// two are compared for count, capacity and contents. A failed check panics.
pub fn bufferTest() void {
    const buffer1 = buffers.new(100);
    const buffer2 = buffers.new(0);

    pushCstring(buffer1, "hello, world!\n");
    for ("hello, world!\n") |byte| pushU8(buffer2, byte);

    expect(buffer1.*.count == buffer2.*.count, "buffer counts agree");
    expect(buffer1.*.capacity >= buffer1.*.count, "buffer1 capacity");
    expect(buffer2.*.capacity >= buffer2.*.count, "buffer2 capacity");
    var i: i32 = 0;
    while (i < buffer1.*.count) : (i += 1) {
        expect(
            buffer1.*.slice()[@intCast(i)] == buffer2.*.slice()[@intCast(i)],
            "buffers agree bytewise",
        );
    }
}

/// Checks that number scanning matches the system's `atof`.
///
/// A failed check panics. This returns without checking anything on plan9,
/// which has no `atof` to compare against.
pub fn numberTest() void {
    if (builtin.os.tag == .plan9) return;
    inline for (.{
        "1.0",                                "1",
        "2.1",                                "1e10",
        "2e10",                               "1e-10",
        "2e-10",                              "1.123123e10",
        "1.123123e-10",                       "-1.23e2",
        "-4.5e15",                            "-4.5e151",
        "-4.5e200",                           "-4.5e123",
        "123123123123123123132123",           "0000000011111111111111111111111111",
        ".112312333333323123123123123123123",
    }) |s| validStr(s);
}

/// Checks the pointer width, and equality over every immediate and both
/// number forms.
///
/// Reflexive equality over the immediates is also the test of the NaN-boxed
/// layouts, since a wrapped value that does not compare equal to itself is a
/// wrong tag or a wrong payload. A failed check panics.
pub fn systemTest() void {
    expect(@sizeOf(*anyopaque) == if (!config.bits64) 4 else 8, "pointer width");

    // No version-consistency check, because there is nothing left to compare.
    // `build.zig` has one `version`, and `version_string` is `comptimePrint`ed
    // from `major`, `minor`, `patch` and `version_extra`, so the whole is
    // built from the parts and the comparison would be a tautology.

    // Reflexive equality, which is also the nanbox test.
    expect(order.equals(wrap.fromNil(), wrap.fromNil()), "nil");
    expect(order.equals(wrap.fromFalse(), wrap.fromFalse()), "false");
    expect(order.equals(wrap.fromTrue(), wrap.fromTrue()), "true");
    expect(order.equals(int(1), int(1)), "1");
    expect(order.equals(int(std.math.maxInt(i32)), int(std.math.maxInt(i32))), "INT32_MAX");
    expect(order.equals(int(-2), int(-2)), "-2");
    expect(order.equals(int(std.math.minInt(i32)), int(std.math.minInt(i32))), "INT32_MIN");
    expect(order.equals(wrap.fromNumber(1.4), wrap.fromNumber(1.4)), "1.4");
    expect(
        order.equals(wrap.fromNumber(3.14159265), wrap.fromNumber(3.14159265)),
        "3.14159265",
    );

    // A NaN is still a number, and `std.math.nan` names a NaN directly.
    expect(
        checkType(wrap.fromNumber(std.math.nan(f64)), repr.Tag.number),
        "NaN is a number",
    );

    expect(order.equals(stringv("a string."), stringv("a string.")), "string");
    expect(order.equals(symbolv("sym"), symbolv("sym")), "symbol");

    const t1 = tuples.begin(3);
    t1[0] = wrap.fromNil();
    t1[1] = int(4);
    t1[2] = stringv("hi");
    const tuple1 = wrap.fromTuple(tuples.end(t1));

    const t2 = tuples.begin(3);
    t2[0] = wrap.fromNil();
    t2[1] = int(4);
    t2[2] = stringv("hi");
    const tuple2 = wrap.fromTuple(tuples.end(t2));

    expect(order.equals(tuple1, tuple2), "structurally equal tuples");
}

/// Checks that a table puts, gets and removes.
///
/// Removing a key and putting nil are the same operation, and the test covers
/// both. A failed check panics.
pub fn tableTest() void {
    const t1 = tables.new(10);
    const t2 = tables.new(0);

    tables.put(t1, stringv("hello"), int(2));
    tables.put(t1, stringv("akey"), int(5));
    tables.put(t1, stringv("box"), wrap.fromBoolean(false));
    tables.put(t1, stringv("square"), stringv("avalue"));

    expect(t1.*.count == 4, "t1 count");
    expect(t1.*.capacity >= t1.*.count, "t1 capacity");
    expect(order.equals(tables.get(t1, stringv("hello")), int(2)), "t1 hello");
    expect(order.equals(tables.get(t1, stringv("akey")), int(5)), "t1 akey");
    expect(
        order.equals(tables.get(t1, stringv("box")), wrap.fromBoolean(false)),
        "t1 box",
    );
    expect(
        order.equals(tables.get(t1, stringv("square")), stringv("avalue")),
        "t1 square",
    );

    // Removing a key and putting nil are the same thing, and both shrink it.
    _ = tables.remove(t1, stringv("hello"));
    tables.put(t1, stringv("box"), wrap.fromNil());
    expect(t1.*.count == 2, "t1 count after removals");
    expect(
        order.equals(tables.get(t1, stringv("hello")), wrap.fromNil()),
        "t1 hello gone",
    );
    expect(
        order.equals(tables.get(t1, stringv("box")), wrap.fromNil()),
        "t1 box gone",
    );

    tables.put(t2, symbolv("t2key1"), int(10));
    tables.put(t2, symbolv("t2key2"), int(100));
    tables.put(t2, symbolv("some key "), int(-2));
    tables.put(t2, symbolv("a thing"), int(10));

    expect(order.equals(tables.get(t2, symbolv("t2key1")), int(10)), "t2key1");
    expect(order.equals(tables.get(t2, symbolv("t2key2")), int(100)), "t2key2");
    expect(t2.*.count == 4, "t2 count");
    expect(order.equals(tables.remove(t2, symbolv("t2key1")), int(10)), "remove t2key1");
    expect(t2.*.count == 3, "t2 count after one removal");
    expect(order.equals(tables.remove(t2, symbolv("t2key2")), int(100)), "remove t2key2");
    expect(t2.*.count == 2, "t2 count after two removals");
}

// ==========================================================================
// Private functions
// ==========================================================================

/// The C library's string-to-double conversion, which `validStr` compares
/// number scanning against.
extern fn atof(str: [*:0]const u8) callconv(.c) f64;

/// Whether a value has this tag.
fn checkType(x: repr.Value, tag: repr.Tag) bool {
    return repr.checkType(x, tag);
}

/// Panics unless `ok`, naming `what` in the message.
///
/// These tests run before the core environment exists, so there is no
/// protected scope above them and a failure is a broken build rather than a
/// program error.
fn expect(ok: bool, comptime what: []const u8) void {
    if (!ok) std.debug.panic("boot test failed: " ++ what, .{});
}

/// An integer as a Janet number.
///
/// `wrap.fromInteger` exists under every layout, and writing the conversion
/// out here says that the generator's own numbers are doubles like any other,
/// which is what the reflexive-equality checks in `systemTest` rest on.
inline fn int(x: i32) repr.Value {
    return wrap.fromNumber(@floatFromInt(x));
}

/// The three raising primitives, with a raise turned into a failed check.
///
/// These run before the core environment exists, so there is no protected
/// scope above them and a raise is a broken build rather than a program
/// error. `expect` says the same of every other line.
fn push(array: *arrays.Array, x: repr.Value) void {
    arrays.push(array, x) catch expect(false, "array push raised");
}

fn pushCstring(buffer: *buffers.Buffer, str: [*:0]const u8) void {
    buffers.pushCString(buffer, str) catch expect(false, "buffer push raised");
}

fn pushU8(buffer: *buffers.Buffer, byte: u8) void {
    buffers.pushU8(buffer, byte) catch expect(false, "buffer push raised");
}

/// A slice of bytes as a Janet string.
inline fn stringv(bytes: []const u8) repr.Value {
    return value.fromBytes(bytes, .string);
}

/// A slice of bytes as a Janet symbol.
inline fn symbolv(bytes: []const u8) repr.Value {
    return value.fromBytes(bytes, .symbol);
}

/// Checks one number literal against the system's `atof`.
///
/// `str` is the literal, and it appears in the message of a failed check.
/// This depends on the system's `atof` being correct, which may not hold on
/// an old or non-compliant implementation, and it can only check base ten.
fn validStr(comptime str: [:0]const u8) void {
    const jnum = scan.scanNumber(str);
    expect(jnum != null, "scan_number accepts " ++ str);
    expect(atof(str.ptr) == jnum.?, "scan_number agrees with atof on " ++ str);
}
