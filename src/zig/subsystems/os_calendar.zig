//! `os/date`, `os/strftime` and `os/mktime`: the broken-down calendar, and the
//! second of the two areas Phase 10's decision 4 unparks. This is Part 12.
//!
//! ## What the decision changed, and what it did not
//!
//! `PLAN.md` recorded under "Current state" that these three stay in C
//! permanently, because they work through `struct tm` and the layout is the
//! platform header's. Decision 4 keeps that reasoning for the *structure* and
//! drops it for the *language*: `struct tm` is still libc's, reached through
//! `os_abi.h`, and no C source file is left behind. It translates completely
//! on all five of this project's targets, which is what makes the calendar
//! movable where `struct stat` -- see `os_files.zig` -- is not.
//!
//! A `struct tm` never crosses a boundary here. It is filled and read inside
//! one cfunction and dies with it, which is the property that made the
//! `@cImport` safe rather than the translation succeeding.
//!
//! ## Three host spellings, and one that is not a spelling
//!
//! `localtime` and `gmtime` have a reentrant form on POSIX (`_r`, taking the
//! caller's structure) and a Microsoft form (`_s`, with the arguments the
//! other way round). The C original also has a Plan 9 arm that calls the
//! non-reentrant pair into a static buffer; there is no Zig target for Plan 9
//! in this project, so that arm is recorded here and not written, exactly as
//! `io_core.zig` records the Plan 9 `dup`.
//!
//! `timegm` is the fourth and is not portable at all: POSIX does not have it,
//! every Unix but Solaris does, and Windows spells it `_mkgmtime`. `os.c`
//! declares it by hand for that reason, and so does this file.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi");
const oa = @import("os_abi");
const corefn = @import("corefn");
const raise = @import("raise");
const pp_format = @import("pp_format.zig");
const c = abi.c;
const arglayer = @import("arglayer.zig");
const h = oa.h;

const windows = builtin.os.tag == .windows;

/// `JANET_NO_UTC_MKTIME` is `__sun && !__illumos__` -- Solaris but not
/// illumos -- and both halves are compiler predefines, so it is not read
/// through `@hasDecl` for the reason `os_files.zig` records at length. Zig
/// 0.16 has no Solaris target at all (`std.Target.Os.Tag` carries `illumos`
/// and nothing else in that family), so the condition cannot be true for
/// anything this project can build, and saying so is more honest than a
/// `builtin` test that reads as if it might fire.
const no_utc_mktime = false;

extern fn time(t: ?*h.time_t) callconv(.c) h.time_t;
extern fn mktime(t: *h.struct_tm) callconv(.c) h.time_t;
extern fn timegm(t: *h.struct_tm) callconv(.c) h.time_t;
extern fn _mkgmtime(t: *h.struct_tm) callconv(.c) h.time_t;
extern fn localtime_r(t: *const h.time_t, out: *h.struct_tm) callconv(.c) ?*h.struct_tm;
extern fn gmtime_r(t: *const h.time_t, out: *h.struct_tm) callconv(.c) ?*h.struct_tm;
/// The Microsoft reentrant pair. `localtime_s` and `gmtime_s` are declared in
/// mingw's `<time.h>` but are not symbols its import library exports: the
/// header maps them onto the CRT's `_localtime64_s` and `_gmtime64_s`, and a
/// C build links against those. Calling the declared names compiles and fails
/// to *link*, which is the third thing this increment's cross-compiles caught
/// and the host could not.
///
/// The `64` in those names is the width of the `time_t` they take, so a mingw
/// configured with `_USE_32BIT_TIME_T` would need the other pair. This project
/// cross-compiles only `x86_64-windows-gnu`; the assertion below makes a
/// narrow `time_t` a compile error rather than a silent mismatch.
extern fn _localtime64_s(out: *h.struct_tm, t: *const h.time_t) callconv(.c) c_int;
extern fn _gmtime64_s(out: *h.struct_tm, t: *const h.time_t) callconv(.c) c_int;

comptime {
    if (windows and @sizeOf(h.time_t) != 8)
        @compileError("this build's time_t is not 64 bits; _localtime64_s is the wrong entry point");
}
extern fn strftime(buf: [*]u8, size: usize, fmt: [*:0]const u8, t: *const h.struct_tm) callconv(.c) usize;
extern fn tzset() callconv(.c) void;
extern fn _tzset() callconv(.c) void;

/// `src/core/util.h`, which `abi.zig` deliberately does not translate. Both
/// take primitive parameters or a `Janet`, so no type crosses that the
/// single-translation rule is about.
extern fn janet_strerror(e: c_int) callconv(.c) [*c]const u8;
extern fn janet_table_get_keyword(t: *c.JanetTable, keyword: [*:0]const u8) callconv(.c) c.Janet;

inline fn errno() c_int {
    return std.c._errno().*;
}

/// `SIZETIMEFMT`.
const time_fmt_size = 250;

/// `time_to_tm`: the optional timestamp at `n` and the optional local flag at
/// `n + 1`, into the caller's structure.
///
/// The failure mode of the two host calls is not checked, exactly as the C
/// original does not check it: `localtime_r` answers NULL for a timestamp its
/// arithmetic cannot represent, and both implementations then read the
/// structure they passed in. Reproduced rather than repaired, and recorded in
/// `FOUND.md`.
fn timeToTm(argv: [*c]const c.Janet, argc: i32, n: i32, out: *h.struct_tm) raise.Raising(void) {
    var t: h.time_t = undefined;
    if (argc > n and c.janet_checktype(argv[@intCast(n)], c.JANET_NIL) == 0) {
        t = @intCast(try arglayer.getInteger64(argv, n));
    } else {
        t = time(null);
    }
    const local = argc > n + 1 and c.janet_truthy(argv[@intCast(n + 1)]) != 0;
    if (local) {
        if (windows) {
            _tzset();
            _ = _localtime64_s(out, &t);
        } else {
            tzset();
            _ = localtime_r(&t, out);
        }
    } else {
        if (windows) {
            _ = _gmtime64_s(out, &t);
        } else {
            _ = gmtime_r(&t, out);
        }
    }
}

fn dateImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 0, 2);
    var t_info: h.struct_tm = undefined;
    try timeToTm(argv, argc, 0, &t_info);
    const st = c.janet_struct_begin(9);
    c.janet_struct_put(st, c.janet_ckeywordv("seconds"), c.janet_wrap_number(@floatFromInt(t_info.tm_sec)));
    c.janet_struct_put(st, c.janet_ckeywordv("minutes"), c.janet_wrap_number(@floatFromInt(t_info.tm_min)));
    c.janet_struct_put(st, c.janet_ckeywordv("hours"), c.janet_wrap_number(@floatFromInt(t_info.tm_hour)));
    c.janet_struct_put(st, c.janet_ckeywordv("month-day"), c.janet_wrap_number(@floatFromInt(t_info.tm_mday - 1)));
    c.janet_struct_put(st, c.janet_ckeywordv("month"), c.janet_wrap_number(@floatFromInt(t_info.tm_mon)));
    c.janet_struct_put(st, c.janet_ckeywordv("year"), c.janet_wrap_number(@floatFromInt(t_info.tm_year + 1900)));
    c.janet_struct_put(st, c.janet_ckeywordv("week-day"), c.janet_wrap_number(@floatFromInt(t_info.tm_wday)));
    c.janet_struct_put(st, c.janet_ckeywordv("year-day"), c.janet_wrap_number(@floatFromInt(t_info.tm_yday)));
    c.janet_struct_put(st, c.janet_ckeywordv("dst"), c.janet_wrap_boolean(t_info.tm_isdst));
    return c.janet_wrap_struct(c.janet_struct_end(st));
}

/// ANSI X3.159-1989, section 4.12.3.5. The specifier check is Janet's own and
/// runs before the timestamp is read, so a bad format is reported whatever the
/// time argument is.
const valid_specifiers = "aAbBcdHIjmMpSUwWxXyYZ%";

fn strftimeImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 1, 3);
    const fmt = try arglayer.getCString(argv, 0);
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
    try timeToTm(argv, argc, 1, &t_info);
    var buf: [time_fmt_size]u8 = undefined;
    // The result is deliberately discarded: `strftime` answers 0 both for an
    // empty result and for one that did not fit, and the C original prints
    // whatever the buffer holds either way.
    _ = strftime(&buf, buf.len, @ptrCast(fmt), &t_info);
    return c.janet_cstringv(&buf);
}

/// `entry_getdst`: -1 where the entry says nothing, which is `tm_isdst`'s
/// "unknown".
fn entryGetDst(entry: c.Janet) c_int {
    var v: c.Janet = undefined;
    if (c.janet_checktype(entry, c.JANET_TABLE) != 0) {
        v = janet_table_get_keyword(c.janet_unwrap_table(entry), "dst");
    } else if (c.janet_checktype(entry, c.JANET_STRUCT) != 0) {
        v = c.janet_struct_get(c.janet_unwrap_struct(entry), c.janet_ckeywordv("dst"));
    } else {
        v = c.janet_wrap_nil();
    }
    if (c.janet_checktype(v, c.JANET_NIL) != 0) return -1;
    return c.janet_truthy(v);
}

/// `timeint_t`: the width `os/mktime` accepts for a field, which is 32 bits on
/// Windows and 64 elsewhere. The check and the message differ with it, so both
/// are written out rather than folded.
const timeint_t = if (windows) i32 else i64;

fn entryGetInt(entry: c.Janet, comptime field: [:0]const u8) raise.Raising(timeint_t) {
    var i: c.Janet = undefined;
    if (c.janet_checktype(entry, c.JANET_TABLE) != 0) {
        i = janet_table_get_keyword(c.janet_unwrap_table(entry), field);
    } else if (c.janet_checktype(entry, c.JANET_STRUCT) != 0) {
        i = c.janet_struct_get(c.janet_unwrap_struct(entry), c.janet_ckeywordv(field));
    } else {
        return 0;
    }
    if (c.janet_checktype(i, c.JANET_NIL) != 0) return 0;
    if (windows) {
        if (c.janet_checkint(i) == 0) {
            return pp_format.panicf(
                "bad slot #%s, expected 32 bit signed integer, got %v",
                .{ field.ptr, i },
            );
        }
    } else {
        if (c.janet_checkint64(i) == 0) {
            return pp_format.panicf(
                "bad slot #%s, expected 64 bit signed integer, got %v",
                .{ field.ptr, i },
            );
        }
    }
    return @intFromFloat(c.janet_unwrap_number(i));
}

fn mktimeImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 1, 2);
    // `= {0}` draws a paranoid warning from the macOS compiler, which is why
    // the C original zeroes it this way; the Zig equivalent is the same thing
    // said once.
    var t_info: h.struct_tm = std.mem.zeroes(h.struct_tm);

    if (c.janet_checktype(argv[0], c.JANET_TABLE) == 0 and
        c.janet_checktype(argv[0], c.JANET_STRUCT) == 0)
    {
        // `-Dargs-core`'s C face, so this raise arrives as a jump through a
        // frame that holds nothing -- the same call and the same reasoning as
        // `core_env.zig`'s `slice`. The message is the fault layer's and has
        // no spelling on this side of the seam.
        return arglayer.panicType(argv[0], 0, c.JANET_TFLAG_DICTIONARY);
    }

    t_info.tm_sec = @intCast(try entryGetInt(argv[0], "seconds"));
    t_info.tm_min = @intCast(try entryGetInt(argv[0], "minutes"));
    t_info.tm_hour = @intCast(try entryGetInt(argv[0], "hours"));
    t_info.tm_mday = @intCast(try entryGetInt(argv[0], "month-day") + 1);
    t_info.tm_mon = @intCast(try entryGetInt(argv[0], "month"));
    t_info.tm_year = @intCast(try entryGetInt(argv[0], "year") - 1900);
    t_info.tm_isdst = entryGetDst(argv[0]);

    var t: h.time_t = undefined;
    if (argc >= 2 and c.janet_truthy(argv[1]) != 0) {
        t = mktime(&t_info);
    } else if (no_utc_mktime) {
        return raise.panic("os/mktime UTC not supported on this platform");
    } else {
        t = if (windows) _mkgmtime(&t_info) else timegm(&t_info);
    }

    if (t == @as(h.time_t, -1)) return pp_format.panicf("%s", .{janet_strerror(errno())});
    return c.janet_wrap_number(@floatFromInt(t));
}

pub fn entries() []const corefn.Entry {
    const list = comptime [_]corefn.Entry{
        corefn.reg("os/mktime", &mktimeImpl, @src(), "(os/mktime date-struct &opt local)", "Get the broken down date-struct time expressed as the number " ++
            "of seconds since January 1, 1970, the Unix epoch. " ++
            "Returns a real number. " ++
            "Date is given in UTC unless `local` is truthy, in which case the " ++
            "date is computed for the local timezone.\n\n" ++
            "Inverse function to os/date."),
        corefn.reg("os/date", &dateImpl, @src(), "(os/date &opt time local)", "Returns the given time as a date struct, or the current time if `time` is not given. " ++
            "Date is given in UTC unless `local` is truthy, in which case the date is formatted for " ++
            "the local timezone. Returns a struct with following key values. Note that all numbers are 0-indexed.\n\n" ++
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
        corefn.reg("os/strftime", &strftimeImpl, @src(), "(os/strftime fmt &opt time local)", "Format the given time as a string, or the current time if `time` is not given. " ++
            "The time is formatted according to the same rules as the ISO C89 function strftime(). " ++
            "The time is formatted in UTC unless `local` is truthy, in which case the date is formatted for " ++
            "the local timezone. You can set local timezone by setting TZ environment variable. " ++
            "See tzset(<time.h>) or _tzset(<time.h>) for further details."),
    };
    return &list;
}
