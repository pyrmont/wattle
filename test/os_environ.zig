//! Behavioral contract for environment scanning and the host operations under
//! `os/getenv`, `os/setenv` and `os/environ`.
//!
//! The four kernels are `os_environ.zig`'s whole surface and none of them
//! raises: they take and answer C strings, and Janet's validation and
//! allocation happen above them. So half of this file reaches them by symbol,
//! exactly as the C original did, and asserts on the scanning arithmetic —
//! `janet_os_environ_separator` in particular, whose three interesting inputs
//! are an entry with no `=` at all, an entry whose value is empty, and the
//! `=C:=C:\work` form Windows puts in its environment for a drive's working
//! directory, where the separator is at index zero and must not be read as
//! "missing".
//!
//! ## The cfunctions are called directly
//!
//! A cfunction is not a C function: it returns `error{JanetSignal}!Value` over
//! Zig's calling convention, so a contract on the far side of a symbol table
//! can neither call one nor learn that one had raised except through a report.
//! This file calls one directly and writes `try`.
//!
//! That is what makes `theRefusals` below possible at all. The C contract
//! asserted only the calls that *succeed*; a refusal was reachable only as a
//! flag it would have had to arm, test and clear around every call. Here a
//! refusal is a value, so the contract can say which refusals the two
//! functions owe and what each one says — and `os/setenv` refusing a keyword
//! where it wants a string is precisely the boundary between this subsystem
//! and the argument layer.

const std = @import("std");
const repr = @import("repr");
const types = @import("types");
const c = @import("cabi");
const harness = @import("harness.zig");
const value = @import("subsystems").value;
const builtin = @import("builtin");
const tables = @import("subsystems").value.tables;
const wrap = @import("subsystems").value.wrap;
const vm_lifecycle = @import("subsystems").lifecycle;

/// The kernels, by symbol. `os_environ.zig` exports them with C's calling
/// convention and `janet.h` does not declare them, so this is the same
/// hand-written block the C contract carried, in Zig.
extern fn janet_os_environ_count(environ: [*]const ?[*:0]const u8) callconv(.c) i32;
extern fn janet_os_environ_separator(entry: [*:0]const u8) callconv(.c) i32;
extern fn janet_os_getenv(name: [*:0]const u8) callconv(.c) ?[*:0]const u8;
extern fn janet_os_setenv(name: [*:0]const u8, val: ?[*:0]const u8) callconv(.c) i32;

/// Unlikely to collide with a real variable, which matters because this
/// contract writes to the process's own environment and does not restore it.
const test_name = "JANET_ZIG_OS_ENVIRON_CONTRACT_6F6B4D";
const missing_name = "JANET_ZIG_OS_ENVIRON_MISSING_7A21C9";

fn theScanning() void {
    const entries = [_]?[*:0]const u8{ "A=1", "EMPTY=", "=C:=C:\\work", null };

    std.debug.assert(janet_os_environ_count(&entries) == 3);
    std.debug.assert(janet_os_environ_count(entries[3..]) == 0);
    std.debug.assert(janet_os_environ_separator("A=1") == 1);
    std.debug.assert(janet_os_environ_separator("EMPTY=") == 5);
    std.debug.assert(janet_os_environ_separator("=C:=C:\\work") == 0);
    std.debug.assert(janet_os_environ_separator("missing") == -1);
    std.debug.assert(janet_os_environ_separator("") == -1);
}

fn theHostOperations() void {
    std.debug.assert(janet_os_setenv(test_name, null) == 0);
    std.debug.assert(janet_os_getenv(test_name) == null);

    std.debug.assert(janet_os_setenv(test_name, "") == 0);
    const empty = janet_os_getenv(test_name).?;
    std.debug.assert(empty[0] == 0);

    // A value holding the separator, which the scanner above has to split on
    // the first `=` rather than the last.
    std.debug.assert(janet_os_setenv(test_name, "first=second") == 0);
    std.debug.assert(std.mem.orderZ(u8, janet_os_getenv(test_name).?, "first=second") == .eq);
    std.debug.assert(janet_os_setenv(test_name, "replacement") == 0);
    std.debug.assert(std.mem.orderZ(u8, janet_os_getenv(test_name).?, "replacement") == .eq);

    std.debug.assert(janet_os_setenv(test_name, null) == 0);
    std.debug.assert(janet_os_getenv(test_name) == null);
}

fn theCoreFunctions() !void {
    const setenv = harness.core("os/setenv");
    const getenv = harness.core("os/getenv");
    var args: [2]repr.Value = undefined;

    args[0] = value.fromBytes(test_name, .string);
    args[1] = value.fromBytes("public-value", .string);
    std.debug.assert(harness.isType(try setenv(args[0..2]), repr.Tag.nil));

    const found = try getenv(args[0..1]);
    std.debug.assert(harness.isType(found, repr.Tag.string));
    std.debug.assert(harness.stringIs(wrap.toString(found), "public-value"));

    // `os/environ` is absent on Plan 9, where there is no `environ` to walk.
    if (!(builtin.os.tag == .plan9)) {
        const environ = harness.core("os/environ");
        const snapshot = wrap.toTable(try environ(&.{}));
        const captured = tables.get(snapshot, args[0]);
        std.debug.assert(harness.isType(captured, repr.Tag.string));
        std.debug.assert(harness.stringIs(wrap.toString(captured), "public-value"));
    }

    // A second argument to `os/getenv` is the value answered when the variable
    // is unset, and it is answered as-is rather than coerced to a string.
    args[0] = value.fromBytes(missing_name, .string);
    args[1] = value.fromBytes("fallback", .keyword);
    std.debug.assert(harness.equals(try getenv(args[0..2]), args[1]));

    // One argument to `os/setenv` unsets, which is the same path
    // `janet_os_setenv(name, NULL)` takes above and a different caller of it.
    args[0] = value.fromBytes(test_name, .string);
    std.debug.assert(harness.isType(try setenv(args[0..1]), repr.Tag.nil));
    std.debug.assert(harness.isType(try getenv(args[0..1]), repr.Tag.nil));
}

/// What the two functions refuse, which the C contract could not ask.
fn theRefusals() void {
    const setenv = harness.core("os/setenv");
    const getenv = harness.core("os/getenv");
    var args: [2]repr.Value = undefined;

    // Arity. `os/setenv` takes one or two, `os/getenv` one or two.
    std.debug.assert(harness.raised(setenv, .{args[0..0]}) != null);
    std.debug.assert(harness.raised(getenv, .{args[0..0]}) != null);
    args[0] = value.fromBytes(test_name, .string);
    args[1] = value.fromBytes("value", .string);
    var three = [_]repr.Value{ args[0], args[1], args[1] };
    std.debug.assert(harness.raised(setenv, .{&three}) != null);

    // Type. A keyword is not a string, and the refusal comes from the argument
    // layer with the slot number in it.
    args[0] = value.fromBytes("not-a-string", .keyword);
    const bad_name = harness.raised(setenv, .{args[0..1]}).?;
    std.debug.assert(bad_name.signal == types.Signal.@"error");
    std.debug.assert(harness.isType(bad_name.payload, repr.Tag.string));

    // The second argument is checked too, and only when it is present.
    args[0] = value.fromBytes(test_name, .string);
    args[1] = harness.wrapInteger(7);
    std.debug.assert(harness.raised(setenv, .{args[0..2]}) != null);

    // And the variable is not set as a side effect of the refusal.
    std.debug.assert(janet_os_getenv(test_name) == null);
}

pub fn run() void {
    theScanning();
    theHostOperations();

    harness.init();
    theCoreFunctions() catch @panic("os_environ: a core function raised unexpectedly");
    theRefusals();
    vm_lifecycle.deinit();
}
