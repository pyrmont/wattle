//! `os/date`, `os/strftime` and `os/mktime`: the broken-down calendar.
//!
//! `struct tm` has a layout only the platform header fixes, so it stays
//! libc's, reached through `os/abi.h`. It translates completely on all five of
//! this project's targets, which is what makes the calendar movable where
//! `struct stat`, in `os/fs/host_stat.zig`, is not.
//!
//! A `struct tm` never crosses a boundary here. It is filled and read inside
//! one cfunction and dies with it, which is the property that made the
//! `@cImport` safe rather than the translation succeeding.
//!
//! `localtime` and `gmtime` have a reentrant form on POSIX (`_r`, taking the
//! caller's structure) and a Microsoft form (`_s`, with the arguments the
//! other way round). Plan 9 has a third arm, which calls the non-reentrant
//! pair into a static buffer; there is no Zig target for Plan 9 in this
//! project, so that arm is recorded here and not written, exactly as `io.zig`
//! records the Plan 9 `dup`.
//!
//! `timegm` is the fourth and is not portable at all: POSIX does not have it,
//! every Unix but Solaris does, and Windows spells it `_mkgmtime`, so this file
//! declares it by hand.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");
const builtin = @import("builtin");

// ==========================================================================
// Project imports
// ==========================================================================

const access = @import("../value/helpers/access.zig");
const args_core = @import("../args.zig");
const c = @import("cabi");
const corefn = @import("../corefn.zig");
const maps = @import("../value/maps.zig");
const oa = @import("abi.zig");
const pp_format = @import("../pp/format.zig");
const raise = @import("../../api/raise.zig");
const repr = @import("repr");
const tables = @import("../value/tables.zig");
const utils = @import("../utils.zig");
const value = @import("../value.zig");
const wrap = @import("../value/helpers/wrap.zig");

/// `os/abi.zig`'s translation, which is where `struct tm` and `time_t` come
/// from.
const h = oa.h;

// ==========================================================================
// Constants
// ==========================================================================

/// Whether this platform has no UTC `mktime`: Solaris but not illumos. Zig
/// 0.16 has no Solaris target at all (`std.Target.Os.Tag` has `illumos` and
/// nothing else in that family), so the condition cannot be true for anything
/// this project can build, and saying so is more honest than a `builtin` test
/// that reads as if it might fire.
const no_utc_mktime = false;

/// `SIZETIMEFMT`.
const time_fmt_size = 250;

/// ANSI X3.159-1989, section 4.12.3.5. The specifier check is Janet's own and
/// runs before the timestamp is read, so a bad format is reported whatever the
/// time argument is.
const valid_specifiers = "aAbBcdHIjmMpSUwWxXyYZ%";

/// Whether this target takes the Microsoft `_s` entry points rather than the
/// POSIX `_r` ones.
const windows = builtin.os.tag == .windows;

// ==========================================================================
// Aliased types
// ==========================================================================

/// The width `os/mktime` accepts for a field, which is 32 bits on Windows and
/// 64 elsewhere. The check and the message differ with it, so both are written
/// out rather than folded.
const timeint_t = if (windows) i32 else i64;

// ==========================================================================
// Public functions
// ==========================================================================

/// The three registrations, which `os.zig` installs.
pub fn entries() []const corefn.Entry {
    const list = comptime [_]corefn.Entry{
        corefn.reg("os/mktime", &cfunMktime, @src(), "(os/mktime date &opt local)", "Get the broken down date expressed as the number " ++
            "of seconds since January 1, 1970, the Unix epoch. " ++
            "Returns a real number. " ++
            "Date is given in UTC unless `local` is truthy, in which case the " ++
            "date is computed for the local timezone.\n\n" ++
            "Inverse function to os/date."),
        corefn.reg("os/date", &cfunDate, @src(), "(os/date &opt time local)", "Returns the given time as a date map, or the current time if `time` is not given. " ++
            "Date is given in UTC unless `local` is truthy, in which case the date is formatted for " ++
            "the local timezone. Returns a map with following key values. Note that all numbers are 0-indexed.\n\n" ++
            "* :seconds - number of seconds [0-61]\n\n" ++
            "* :minutes - number of minutes [0-59]\n\n" ++
            "* :hours - number of hours [0-23]\n\n" ++
            "* :month-day - day of month [0-30]\n\n" ++
            "* :month - month of year [0, 11]\n\n" ++
            "* :year - years since year 0 (e.g. 2019)\n\n" ++
            "* :week-day - day of the week [0-6]\n\n" ++
            "* :year-day - day of the year [0-365]\n\n" ++
            "* :dst - if Day Light Savings is in effect\n\n" ++
            "You can set local timezone by setting TZ environment variable. " ++
            "See tzset(<time.h>) or _tzset(<time.h>) for further details."),
        corefn.reg("os/strftime", &cfunStrftime, @src(), "(os/strftime fmt &opt time local)", "Format the given time as a string, or the current time if `time` is not given. " ++
            "The time is formatted according to the same rules as the ISO C89 function strftime(). " ++
            "The time is formatted in UTC unless `local` is truthy, in which case the date is formatted for " ++
            "the local timezone. You can set local timezone by setting TZ environment variable. " ++
            "See tzset(<time.h>) or _tzset(<time.h>) for further details."),
    };
    return &list;
}

// ==========================================================================
// Private functions
// ==========================================================================

/// `(os/date &opt time local)`.
fn cfunDate(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 0, 2);
    var t_info: h.struct_tm = undefined;
    try timeToTm(argv, 0, &t_info);
    const fields = [_]repr.Value{
        value.fromBytes("seconds", .keyword),   wrap.fromNumber(@floatFromInt(t_info.tm_sec)),
        value.fromBytes("minutes", .keyword),   wrap.fromNumber(@floatFromInt(t_info.tm_min)),
        value.fromBytes("hours", .keyword),     wrap.fromNumber(@floatFromInt(t_info.tm_hour)),
        value.fromBytes("month-day", .keyword), wrap.fromNumber(@floatFromInt(t_info.tm_mday - 1)),
        value.fromBytes("month", .keyword),     wrap.fromNumber(@floatFromInt(t_info.tm_mon)),
        value.fromBytes("year", .keyword),      wrap.fromNumber(@floatFromInt(t_info.tm_year + 1900)),
        value.fromBytes("week-day", .keyword),  wrap.fromNumber(@floatFromInt(t_info.tm_wday)),
        value.fromBytes("year-day", .keyword),  wrap.fromNumber(@floatFromInt(t_info.tm_yday)),
        value.fromBytes("dst", .keyword),       wrap.fromBoolean(t_info.tm_isdst != 0),
    };
    return wrap.fromMap(maps.build(.map, &fields));
}

/// `(os/mktime date-struct &opt local)`.
fn cfunMktime(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, 2);
    // Zeroed whole, so that no field is left as whatever the frame had.
    var t_info: h.struct_tm = std.mem.zeroes(h.struct_tm);

    if (!args_core.checkdictionary(argv[0])) {
        return args_core.panicDictionary(argv[0], 0, repr.TagSet.none);
    }

    t_info.tm_sec = @intCast(try entryGetInt(argv[0], "seconds"));
    t_info.tm_min = @intCast(try entryGetInt(argv[0], "minutes"));
    t_info.tm_hour = @intCast(try entryGetInt(argv[0], "hours"));
    t_info.tm_mday = @intCast(try entryGetInt(argv[0], "month-day") + 1);
    t_info.tm_mon = @intCast(try entryGetInt(argv[0], "month"));
    t_info.tm_year = @intCast(try entryGetInt(argv[0], "year") - 1900);
    t_info.tm_isdst = try entryGetDst(argv[0]);

    var t: h.time_t = undefined;
    if (argv.len >= 2 and repr.truthy(argv[1])) {
        t = oa.mktime(&t_info);
    } else if (no_utc_mktime) {
        return raise.panic("os/mktime UTC not supported on this platform");
    } else {
        t = if (windows) oa._mkgmtime(&t_info) else oa.timegm(&t_info);
    }

    if (t == @as(h.time_t, -1)) return pp_format.panicf("%s", .{utils.strerrorSafe(c.errno())});
    return wrap.fromNumber(@floatFromInt(t));
}

/// `(os/strftime fmt &opt time local)`.
fn cfunStrftime(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, 3);
    const fmt = try args_core.getCString(argv, 0);
    var i: usize = 0;
    while (fmt[i] != 0) : (i += 1) {
        if (fmt[i] != '%') continue;
        i += 1;
        if (fmt[i] == 0) return raise.panic("invalid conversion specifier");
        if (std.mem.indexOfScalar(u8, valid_specifiers, fmt[i]) == null) {
            return pp_format.panicf("invalid conversion specifier '%%%c'", .{@as(c_int, fmt[i])});
        }
    }
    var t_info: h.struct_tm = undefined;
    try timeToTm(argv, 1, &t_info);
    var buf: [time_fmt_size]u8 = undefined;
    // The result is deliberately discarded: `strftime` gives back 0 both for
    // an empty result and for one that did not fit, and what a program sees is
    // whatever is in the buffer either way.
    _ = oa.strftime(&buf, buf.len, @ptrCast(fmt), &t_info);
    return value.fromBytes(std.mem.sliceTo(&buf, 0), .string);
}

/// The value a date dictionary holds for the keyword `field`, or nil.
///
/// A table is read with its prototype, and a map or a dictionary abstract
/// through its own entries. Anything else holds nothing.
fn entryField(entry: repr.Value, comptime field: [:0]const u8) raise.Error!repr.Value {
    return switch (repr.typeOf(entry)) {
        .table => tables.getKeyword(wrap.toTable(entry), field),
        .map => maps.lookup(wrap.toMap(entry), value.fromBytes(field, .keyword)),
        .abstract => if (args_core.checkdictionary(entry))
            access.get(entry, value.fromBytes(field, .keyword))
        else
            wrap.fromNil(),
        else => wrap.fromNil(),
    };
}

/// The DST field an entry names: -1 where it says nothing, which is
/// `tm_isdst`'s "unknown".
fn entryGetDst(entry: repr.Value) raise.Error!c_int {
    const v = try entryField(entry, "dst");
    if (repr.checkType(v, repr.Tag.nil)) return -1;
    // `tm_isdst` is a tri-state and stays `c_int` for it: -1 is "unknown", not
    // "false".
    return @intFromBool(repr.truthy(v));
}

/// One integer field of a date struct or table, or zero where it is absent.
fn entryGetInt(entry: repr.Value, comptime field: [:0]const u8) raise.Error!timeint_t {
    const i = try entryField(entry, field);
    if (repr.checkType(i, repr.Tag.nil)) return 0;
    if (windows) {
        if (!args_core.checkint(i)) {
            return pp_format.panicf(
                "bad slot #%s, expected 32 bit signed integer, got %v",
                .{ field.ptr, i },
            );
        }
    } else {
        if (!args_core.checkint64(i)) {
            return pp_format.panicf(
                "bad slot #%s, expected 64 bit signed integer, got %v",
                .{ field.ptr, i },
            );
        }
    }
    return @intFromFloat(wrap.toNumber(i));
}

/// `time_to_tm`: the optional timestamp at `n` and the optional local flag at
/// `n + 1`, into the caller's structure.
///
/// The two host calls are checked. `localtime_r` and `gmtime_r` give back NULL
/// for a timestamp their arithmetic cannot represent, and they are documented
/// to leave the caller's structure unspecified when they do, so reading it
/// regardless would report whatever the conversion left behind, and on a host
/// whose `_r` functions return without writing it, the stack. The Windows and
/// Plan 9 entry points report the same failure as a nonzero return.
fn timeToTm(argv: []const repr.Value, n: usize, out: *h.struct_tm) raise.Error!void {
    var t: h.time_t = undefined;
    if (argv.len > n and !repr.checkType(argv[n], repr.Tag.nil)) {
        t = @intCast(try args_core.getInteger64(argv, n));
    } else {
        t = oa.time(null);
    }
    const local = argv.len > n + 1 and repr.truthy(argv[n + 1]);
    const filled = if (local) blk: {
        if (windows) {
            c._tzset();
            break :blk oa._localtime64_s(out, &t) == 0;
        }
        // WASI has no time zones and no `tzset`; local time is UTC there.
        if (builtin.os.tag != .wasi) c.tzset();
        break :blk oa.localtime_r(&t, out) != null;
    } else blk: {
        if (windows) break :blk oa._gmtime64_s(out, &t) == 0;
        break :blk oa.gmtime_r(&t, out) != null;
    };
    if (!filled) return raise.panic("cannot convert timestamp to a date");
}

// ==========================================================================
// Tests
// ==========================================================================

comptime {
    if (windows and @sizeOf(h.time_t) != 8)
        @compileError("this build's time_t is not 64 bits; _localtime64_s is the wrong entry point");
}
