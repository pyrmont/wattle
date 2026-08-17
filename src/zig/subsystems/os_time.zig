//! Host clock services: the platform clock shim behind `janet_gettime`, the
//! wall-clock reading behind `os/time`, and the host wait behind `os/sleep`.
//!
//! `janet_gettime` is used by `os/clock` and by the event loop's deadlines, so
//! this subsystem is on the path of every timeout in the runtime.
//!
//! Values cross the boundary as separate seconds and nanoseconds rather than as
//! a `struct timespec`, because that structure's layout varies by platform and
//! libc. C keeps the one-line conversion into its own `struct timespec`, along
//! with sandbox checks, keyword validation, Janet value construction, and every
//! panic path.

const std = @import("std");
const builtin = @import("builtin");

const windows = builtin.os.tag == .windows;

/// Mirrors `enum JanetTimeSource` in `src/core/util.h`.
const source_realtime: i32 = 0;
const source_monotonic: i32 = 1;
const source_cputime: i32 = 2;

/// Windows file times count 100-nanosecond intervals from January 1, 1601.
const windows_epoch_offset: i64 = 116444736000000000;
const hundred_ns_per_second: i64 = 10000000;

const FILETIME = extern struct {
    low: u32,
    high: u32,
};

extern "kernel32" fn GetSystemTimeAsFileTime(*FILETIME) callconv(.winapi) void;
extern "kernel32" fn QueryPerformanceCounter(*i64) callconv(.winapi) c_int;
extern "kernel32" fn QueryPerformanceFrequency(*i64) callconv(.winapi) c_int;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcessTimes(?*anyopaque, *FILETIME, *FILETIME, *FILETIME, *FILETIME) callconv(.winapi) c_int;
extern "kernel32" fn Sleep(u32) callconv(.winapi) void;

extern fn time(?*TimeT) callconv(.c) TimeT;

const TimeT = if (windows) i64 else std.c.time_t;

fn fileTimeToInt(ft: FILETIME) i64 {
    return @as(i64, ft.low) | (@as(i64, ft.high) << 32);
}

/// Read a clock source, reporting seconds and nanoseconds separately.
///
/// Returns 0 on success and -1 on failure, matching the C shim. An unrecognized
/// source falls back to the real-time clock, as the C implementation's
/// initialized-then-overwritten clock id does.
export fn janet_os_gettime(source: i32, sec_out: *i64, nsec_out: *i64) callconv(.c) i32 {
    if (windows) {
        switch (source) {
            source_monotonic => {
                var count: i64 = undefined;
                var frequency: i64 = undefined;
                _ = QueryPerformanceCounter(&count);
                _ = QueryPerformanceFrequency(&frequency);
                sec_out.* = @divTrunc(count, frequency);
                const remainder = @rem(count, frequency);
                nsec_out.* = @divTrunc(remainder * 1000000000, frequency);
            },
            source_cputime => {
                var creation: FILETIME = undefined;
                var exit: FILETIME = undefined;
                var kernel: FILETIME = undefined;
                var user: FILETIME = undefined;
                _ = GetProcessTimes(GetCurrentProcess(), &creation, &exit, &kernel, &user);
                const ticks = fileTimeToInt(user);
                sec_out.* = @divTrunc(ticks, hundred_ns_per_second);
                nsec_out.* = @rem(ticks, hundred_ns_per_second) * 100;
            },
            else => {
                var ft: FILETIME = undefined;
                GetSystemTimeAsFileTime(&ft);
                const ticks = fileTimeToInt(ft) - windows_epoch_offset;
                sec_out.* = @divTrunc(ticks, hundred_ns_per_second);
                nsec_out.* = @rem(ticks, hundred_ns_per_second) * 100;
            },
        }
        return 0;
    }

    const clock_id: std.c.clockid_t = switch (source) {
        source_monotonic => .MONOTONIC,
        source_cputime => .PROCESS_CPUTIME_ID,
        else => .REALTIME,
    };
    var spec: std.c.timespec = undefined;
    if (std.c.clock_gettime(clock_id, &spec) != 0) return -1;
    sec_out.* = @intCast(spec.sec);
    nsec_out.* = @intCast(spec.nsec);
    return 0;
}

/// Whole seconds since the Unix epoch, as `os/time` reports them.
export fn janet_os_time_now() callconv(.c) f64 {
    return @floatFromInt(time(null));
}

/// Suspend the caller for `seconds`, which C has already checked is not
/// negative.
///
/// The C implementation zeroes the fractional part above `UINT32_MAX` seconds,
/// because the subtraction it uses to isolate that part goes through a
/// `uint32_t`; that is preserved. Converting the whole-second part of a very
/// large delay is undefined in C, so the port saturates instead. Both cases are
/// far longer than any process runs.
export fn janet_os_sleep(seconds: f64) callconv(.c) void {
    if (windows) {
        Sleep(saturatingCast(u32, seconds * 1000));
        return;
    }

    const whole = saturatingCast(i64, seconds);
    const fraction = if (seconds <= @as(f64, std.math.maxInt(u32)))
        (seconds - @as(f64, @floatFromInt(@as(u32, @intFromFloat(seconds))))) * 1000000000
    else
        0;
    var spec: std.c.timespec = .{
        .sec = @intCast(whole),
        .nsec = @intFromFloat(fraction),
    };
    while (true) {
        const rc = std.c.nanosleep(&spec, &spec);
        if (rc == 0) return;
        if (std.c._errno().* != @intFromEnum(std.c.E.INTR)) return;
    }
}

/// Convert toward zero, clamping instead of trapping. This reproduces the
/// AArch64 conversion the C implementation performs without a sanitizer: a NaN
/// becomes zero and an out-of-range value becomes the nearest bound. A NaN is
/// separated first because `@intFromFloat` is illegal for it and because the
/// ordinary comparisons below would otherwise send it to the low bound.
fn saturatingCast(comptime T: type, value: f64) T {
    if (std.math.isNan(value)) return 0;
    const low: f64 = @floatFromInt(@as(T, std.math.minInt(T)));
    const high: f64 = @floatFromInt(@as(T, std.math.maxInt(T)));
    if (!(value > low)) return std.math.minInt(T);
    if (value >= high) return std.math.maxInt(T);
    return @intFromFloat(value);
}

test "saturating conversion clamps rather than trapping" {
    try std.testing.expectEqual(@as(u32, 0), saturatingCast(u32, -1.0));
    try std.testing.expectEqual(@as(i64, 0), saturatingCast(i64, std.math.nan(f64)));
    try std.testing.expectEqual(@as(u32, 5), saturatingCast(u32, 5.9));
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), saturatingCast(u32, 1e30));
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), saturatingCast(i64, 1e300));
}
