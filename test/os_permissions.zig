//! Behavioral contract for permission parsing and formatting: the two kernels
//! under `os/perm-int` and `os/perm-string`.
//!
//! ## What the suites cannot reach
//!
//! The exhaustive round trip. Every one of the 512 portable modes is formatted
//! and parsed back below, which is the only assertion that establishes the two
//! functions are actually inverses rather than agreeing on the handful of
//! examples anybody thinks to write down.
//!
//! ## The parser is permissive, and that is established behaviour
//!
//! It is position-sensitive rather than grammatical: it looks for `r` at
//! position 0, `w` at 1, `x` at 2 and so on, and **any other byte clears that
//! position**. So `"xxxxxxxxx"` parses as 0111 — the `x`s in the execute
//! positions count and the rest do not — and `"rwxgarbage"` parses as 0700.
//! Neither is a string a person would write, and both are recorded here so
//! that a port cannot quietly make the parser stricter. `FOUND.md` is for
//! defects; this is not one, it is a shape.
//!
//! ## The refusals
//!
//! Validation happens above the kernels, in the argument layer, and a contract
//! on the far side of a symbol table can only observe it by compiling a Janet
//! closure with `janet_dostring` and calling it under `janet_pcall` -- three
//! lines and a
//! wrapper function per case, "so they stay off stderr". Here the cfunction is
//! called directly and the refusal is a value, so each case is one line and
//! says which argument was rejected.

const std = @import("std");
const repr = @import("repr");
const c = @import("cabi");
const value = @import("subsystems").value;
const harness = @import("harness.zig");
const wrap = @import("subsystems").value.wrap;
const vm_lifecycle = @import("subsystems").lifecycle;

/// The kernels, by symbol. `janet.h` does not declare them; they are
/// `os_permissions.zig`'s internal surface, reached here the same way the C
/// contract reached them.
extern fn janet_os_parse_permissions(permissions: [*]const u8) callconv(.c) i32;
extern fn janet_os_format_permissions(permissions: i32, out: [*]u8) callconv(.c) void;

fn parse(text: []const u8) i32 {
    return janet_os_parse_permissions(text.ptr);
}

fn expectFormat(mode: i32, expected: *const [9]u8) void {
    // Poisoned rather than zeroed, so that a formatter writing fewer than nine
    // bytes fails here instead of passing on leftover zeroes.
    var actual: [9]u8 = @splat(0xA5);
    janet_os_format_permissions(mode, &actual);
    std.debug.assert(std.mem.eql(u8, &actual, expected));
}

fn theKernels() void {
    std.debug.assert(parse("---------") == 0o000);
    std.debug.assert(parse("rwxrwxrwx") == 0o777);
    std.debug.assert(parse("rw-r--r--") == 0o644);
    std.debug.assert(parse("r-x--x--x") == 0o511);

    // Permissive and position-sensitive; see the header comment.
    std.debug.assert(parse("xxxxxxxxx") == 0o111);
    std.debug.assert(parse("rwxgarbage") == 0o700);

    expectFormat(0o000, "---------");
    expectFormat(0o777, "rwxrwxrwx");
    expectFormat(0o644, "rw-r--r--");
    expectFormat(0o511, "r-x--x--x");
    // The file-type bits of a `st_mode` are outside the portable permission
    // field and are ignored rather than rejected.
    expectFormat(0o100644, "rw-r--r--");
}

fn everyPortableModeRoundTrips() void {
    var formatted: [9]u8 = undefined;
    var mode: i32 = 0;
    while (mode <= 0o777) : (mode += 1) {
        janet_os_format_permissions(mode, &formatted);
        std.debug.assert(parse(&formatted) == mode);
    }
}

fn theCoreFunctions() !void {
    const permInt = harness.core("os/perm-int");
    const permString = harness.core("os/perm-string");
    var args: [1]repr.Value = undefined;

    args[0] = value.fromBytes("rw-r-----", .string);
    std.debug.assert(wrap.toInteger(try permInt(args[0..1])) == 0o640);

    args[0] = harness.wrapInteger(0o640);
    const rendered = try permString(args[0..1]);
    std.debug.assert(harness.stringIs(wrap.toString(rendered), "rw-r-----"));

    // `os/perm-string` accepts a string as well as an integer and answers it
    // back, so that a caller can pass either through without asking which.
    args[0] = value.fromBytes("rwxrwxrwx", .string);
    std.debug.assert(harness.stringIs(wrap.toString(try permString(args[0..1])), "rwxrwxrwx"));

    // The permissive parse survives the public function too.
    args[0] = value.fromBytes("xxxxxxxxx", .string);
    std.debug.assert(wrap.toInteger(try permInt(args[0..1])) == 0o111);
}

/// Validation happens before either kernel is entered, and this is where it is
/// asserted. Both cases would reach a kernel that cannot cope: a three-byte
/// string would be read past its end, and 0o1000 does not fit the field.
fn theRefusals() void {
    const permInt = harness.core("os/perm-int");
    const permString = harness.core("os/perm-string");
    var args: [1]repr.Value = undefined;

    args[0] = value.fromBytes("rwx", .string);
    std.debug.assert(harness.raised(permInt, .{args[0..1]}) != null);

    args[0] = harness.wrapInteger(0o1000);
    std.debug.assert(harness.raised(permString, .{args[0..1]}) != null);

    // And the kernels are still reachable and still correct afterwards, which
    // is what says the refusal happened above them rather than inside one.
    std.debug.assert(parse("rwxrwxrwx") == 0o777);
}

pub fn run() void {
    harness.init();
    theKernels();
    everyPortableModeRoundTrips();
    theCoreFunctions() catch @panic("os_permissions: a core function raised unexpectedly");
    theRefusals();
    vm_lifecycle.deinit();
}
