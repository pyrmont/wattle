//! The five smoke tests the image generator runs before it generates anything.
//!
//! They predate every contract in `test/` and they check the things a broken
//! build breaks first: that an array grows, that a buffer's two ways of filling
//! it agree, that number scanning matches the system's `atof`, that the version
//! macros are self-consistent, and that a table round-trips. `PLAN.md`'s exit
//! gate names them beside the Janet suites.
//!
//! They were `src/boot/*_test.c` until Phase 10 Part 18. Nothing about them
//! needed C; they were the last five files under `src/boot` that were not the
//! generator itself.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config");
const types = @import("types");
const constants = @import("constants");

/// `janet_cstringv` and its two siblings, which `cabi.zig` stopped carrying at
/// increment 5e.
///
/// **This program is an embedder.** `build.zig` gives its module only `config`,
/// `types`, `constants` and `cabi`, because it *links* the runtime object
/// rather than importing it. `value.fromBytes` is therefore out of reach here,
/// and should be: importing `value.zig` would compile a second copy of the
/// whole value layer into an executable that already links one. So these spell
/// the two C calls the macro composed, which is what any embedder writes.
///
/// They take a slice for the same reason `value.fromBytes` does -- a literal
/// knows its own length, and `janet_cstring`'s `strlen` was rediscovering it.
inline fn stringv(bytes: []const u8) types.Janet {
    return c.janet_wrap_string(c.janet_string(bytes.ptr, @intCast(bytes.len)));
}

inline fn symbolv(bytes: []const u8) types.Janet {
    return c.janet_wrap_symbol(c.janet_symbol(bytes.ptr, @intCast(bytes.len)));
}

/// A keyword is a symbol under a different tag; `janet.h:1844` is
/// `#define janet_keyword janet_symbol`.
inline fn keywordv(bytes: []const u8) types.Janet {
    return c.janet_wrap_keyword(c.janet_symbol(bytes.ptr, @intCast(bytes.len)));
}
const c = @import("cabi");

/// `janet_wrap_integer`, written out. `janet.h` declares it beside its macro
/// and `wrap.c` defined it only for the two nanbox layouts, so a Zig caller
/// reaching the declaration does not link against `-Dnanbox=false`.
inline fn int(x: i32) types.Janet {
    return c.janet_wrap_number(@floatFromInt(x));
}

fn expect(ok: bool, comptime what: []const u8) void {
    if (!ok) std.debug.panic("boot test failed: " ++ what, .{});
}

pub fn arrayTest() void {
    const array1 = c.janet_array(10);
    const array2 = c.janet_array(0);

    const words = [_][*:0]const u8{ "one", "two", "three", "four", "five", "six", "seven" };
    for (words) |w| c.janet_array_push(array1, stringv(std.mem.span(w)));
    expect(array1.*.count == 7, "array1 count");
    expect(array1.*.capacity >= 7, "array1 capacity");
    expect(c.janet_equals(array1.*.data.?[0], stringv("one")) != 0, "array1 first");

    for (words) |w| c.janet_array_push(array2, stringv(std.mem.span(w)));
    var i: i32 = 0;
    while (i < array2.*.count) : (i += 1) {
        expect(
            c.janet_equals(array1.*.data.?[@intCast(i)], array2.*.data.?[@intCast(i)]) != 0,
            "arrays agree elementwise",
        );
    }

    _ = c.janet_array_pop(array1);
    _ = c.janet_array_pop(array1);
    expect(array1.*.count == 5, "array1 count after two pops");
}

pub fn bufferTest() void {
    const buffer1 = c.janet_buffer(100);
    const buffer2 = c.janet_buffer(0);

    _ = c.janet_buffer_push_cstring(buffer1, "hello, world!\n");
    for ("hello, world!\n") |byte| _ = c.janet_buffer_push_u8(buffer2, byte);

    expect(buffer1.*.count == buffer2.*.count, "buffer counts agree");
    expect(buffer1.*.capacity >= buffer1.*.count, "buffer1 capacity");
    expect(buffer2.*.capacity >= buffer2.*.count, "buffer2 capacity");
    var i: i32 = 0;
    while (i < buffer1.*.count) : (i += 1) {
        expect(
            buffer1.*.data.?[@intCast(i)] == buffer2.*.data.?[@intCast(i)],
            "buffers agree bytewise",
        );
    }
}

extern fn atof(str: [*:0]const u8) callconv(.c) f64;

/// Check a subset of numbers against the system implementation.
///
/// This depends on the system's `atof` being correct, which may not hold on an
/// old or non-compliant one, and it can only check base ten. Both caveats are
/// the C original's and both still apply.
fn validStr(comptime str: [:0]const u8) void {
    var jnum: f64 = 0.0;
    const err = c.janet_scan_number(str.ptr, @intCast(str.len), &jnum);
    expect(err == 0, "scan_number accepts " ++ str);
    expect(atof(str.ptr) == jnum, "scan_number agrees with atof on " ++ str);
}

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

pub fn systemTest() void {
    expect(@sizeOf(*anyopaque) == if (!config.bits64) 4 else 8, "pointer width");

    // "The version defines are self-consistent" stood here, comparing
    // `JANET_VERSION` against `{MAJOR}.{MINOR}.{PATCH}{EXTRA}` rebuilt from
    // the parts. It was checking that two hand-maintained lines of
    // `janetconf.h` agreed.
    //
    // Increment 4 gave `build.zig` one `version`, and `version_string` is
    // `comptimePrint`ed from `major`, `minor`, `patch` and `version_extra` --
    // the same values `makeConfigHeader` emits. So the header's whole is
    // built from the header's parts and the comparison became a tautology at
    // that moment, not at the header's removal. `DESIGN.md` §3's phrase for
    // exactly this: the property "stops being an agreement and becomes a
    // construction".
    //
    // What is worth checking is `Config` against the header, and
    // `constants_check.zig` does it -- `version_major` and its four
    // neighbours, every build, every configuration. That one dies with the
    // header; this one was already dead.

    // Reflexive equality, which is also the nanbox test.
    expect(c.janet_equals(c.janet_wrap_nil(), c.janet_wrap_nil()) != 0, "nil");
    expect(c.janet_equals(c.janet_wrap_false(), c.janet_wrap_false()) != 0, "false");
    expect(c.janet_equals(c.janet_wrap_true(), c.janet_wrap_true()) != 0, "true");
    expect(c.janet_equals(int(1), int(1)) != 0, "1");
    expect(c.janet_equals(int(std.math.maxInt(i32)), int(std.math.maxInt(i32))) != 0, "INT32_MAX");
    expect(c.janet_equals(int(-2), int(-2)) != 0, "-2");
    expect(c.janet_equals(int(std.math.minInt(i32)), int(std.math.minInt(i32))) != 0, "INT32_MIN");
    expect(c.janet_equals(c.janet_wrap_number(1.4), c.janet_wrap_number(1.4)) != 0, "1.4");
    expect(
        c.janet_equals(c.janet_wrap_number(3.14159265), c.janet_wrap_number(3.14159265)) != 0,
        "3.14159265",
    );

    // A NaN is still a number. The C reached for `NAN` and fell back to
    // `0.0 / 0.0` where the macro was absent; Zig has the value directly.
    expect(
        c.janet_checktype(c.janet_wrap_number(std.math.nan(f64)), constants.JANET_NUMBER) != 0,
        "NaN is a number",
    );

    expect(c.janet_equals(stringv("a string."), stringv("a string.")) != 0, "string");
    expect(c.janet_equals(symbolv("sym"), symbolv("sym")) != 0, "symbol");

    const t1 = c.janet_tuple_begin(3);
    t1[0] = c.janet_wrap_nil();
    t1[1] = int(4);
    t1[2] = stringv("hi");
    const tuple1 = c.janet_wrap_tuple(c.janet_tuple_end(t1));

    const t2 = c.janet_tuple_begin(3);
    t2[0] = c.janet_wrap_nil();
    t2[1] = int(4);
    t2[2] = stringv("hi");
    const tuple2 = c.janet_wrap_tuple(c.janet_tuple_end(t2));

    expect(c.janet_equals(tuple1, tuple2) != 0, "structurally equal tuples");
}

pub fn tableTest() void {
    const t1 = c.janet_table(10);
    const t2 = c.janet_table(0);

    c.janet_table_put(t1, stringv("hello"), int(2));
    c.janet_table_put(t1, stringv("akey"), int(5));
    c.janet_table_put(t1, stringv("box"), c.janet_wrap_boolean(0));
    c.janet_table_put(t1, stringv("square"), stringv("avalue"));

    expect(t1.*.count == 4, "t1 count");
    expect(t1.*.capacity >= t1.*.count, "t1 capacity");
    expect(c.janet_equals(c.janet_table_get(t1, stringv("hello")), int(2)) != 0, "t1 hello");
    expect(c.janet_equals(c.janet_table_get(t1, stringv("akey")), int(5)) != 0, "t1 akey");
    expect(
        c.janet_equals(c.janet_table_get(t1, stringv("box")), c.janet_wrap_boolean(0)) != 0,
        "t1 box",
    );
    expect(
        c.janet_equals(c.janet_table_get(t1, stringv("square")), stringv("avalue")) != 0,
        "t1 square",
    );

    // Removing a key and putting nil are the same thing, and both shrink it.
    _ = c.janet_table_remove(t1, stringv("hello"));
    c.janet_table_put(t1, stringv("box"), c.janet_wrap_nil());
    expect(t1.*.count == 2, "t1 count after removals");
    expect(
        c.janet_equals(c.janet_table_get(t1, stringv("hello")), c.janet_wrap_nil()) != 0,
        "t1 hello gone",
    );
    expect(
        c.janet_equals(c.janet_table_get(t1, stringv("box")), c.janet_wrap_nil()) != 0,
        "t1 box gone",
    );

    c.janet_table_put(t2, symbolv("t2key1"), int(10));
    c.janet_table_put(t2, symbolv("t2key2"), int(100));
    c.janet_table_put(t2, symbolv("some key "), int(-2));
    c.janet_table_put(t2, symbolv("a thing"), int(10));

    expect(c.janet_equals(c.janet_table_get(t2, symbolv("t2key1")), int(10)) != 0, "t2key1");
    expect(c.janet_equals(c.janet_table_get(t2, symbolv("t2key2")), int(100)) != 0, "t2key2");
    expect(t2.*.count == 4, "t2 count");
    expect(c.janet_equals(c.janet_table_remove(t2, symbolv("t2key1")), int(10)) != 0, "remove t2key1");
    expect(t2.*.count == 3, "t2 count after one removal");
    expect(c.janet_equals(c.janet_table_remove(t2, symbolv("t2key2")), int(100)) != 0, "remove t2key2");
    expect(t2.*.count == 2, "t2 count after two removals");
}

pub fn all() void {
    arrayTest();
    bufferTest();
    numberTest();
    systemTest();
    tableTest();
}
