//! Behavioral contract for the host clock services: `janet_gettime`'s three
//! sources, the wall clock behind `os/time`, and `janet_os_sleep`.
//!
//! A clock cannot be pinned to fixed vectors the way a parser can, so what is
//! asserted here is a set of *invariants* rather than values: which ranges each
//! source falls in, which orderings hold between two readings, what an
//! unrecognised source does, and that a sleep actually advances a monotonic
//! clock. Those are the properties a port can break while still returning
//! plausible numbers, and no Janet suite reaches `janet_gettime` at all.
//!
//! ## The bounds are deliberately wide
//!
//! Every numeric bound below is loose on purpose, and the reason is that this
//! runs on a shared machine under a matrix at `-j2`. A tight upper bound on a
//! sleep would fail for scheduling reasons and cost an afternoon proving it —
//! `AGENTS.md` has that story under `deadline expired`. So the *lower* bound
//! is the contract and the upper bound is only there to catch a sleep that
//! multiplied its argument by the wrong factor.
//!
//! ## The fallback for an unknown source is established behaviour
//!
//! `janet_gettime` given a source it does not recognise answers the real-time
//! clock and reports success, rather than failing. That is the C shim's
//! behaviour — it initialises its clock id before testing the source — and it
//! is asserted here so a port cannot quietly start refusing.

const std = @import("std");
const types = @import("types");
const repr = @import("repr");
const c = @import("cabi");
const value = @import("subsystems").value;
const harness = @import("harness.zig");
const core_env = @import("subsystems").env;
const vm_lifecycle = @import("subsystems").lifecycle;

/// `enum JanetTimeSource` and the three kernels, declared rather than
/// translated: they live in `src/core/util.h`, which no translation ever
/// carried, and they take primitives so nothing Janet-shaped crosses.
const Source = enum(c_int) {
    realtime = 0,
    monotonic = 1,
    cputime = 2,
    /// Not a source. Used to reach the fallback below.
    unrecognised = 99,
};

const TimeSpec = extern struct {
    seconds: isize,
    nanoseconds: isize,
};

extern fn janet_gettime(spec: *TimeSpec, source: Source) callconv(.c) c_int;
extern fn janet_os_time_now() callconv(.c) f64;
extern fn janet_os_sleep(seconds: f64) callconv(.c) void;

/// Any run of this is after the start of 2023 and before the end of 2200.
const epoch_lower = 1672531200;
const epoch_upper = 7289654400;

fn read(source: Source) TimeSpec {
    var spec: TimeSpec = undefined;
    std.debug.assert(janet_gettime(&spec, source) == 0);
    // Normalised: the nanosecond field is a remainder, not a free-running
    // count, so a port that forgot to carry would show up here.
    std.debug.assert(spec.nanoseconds >= 0);
    std.debug.assert(spec.nanoseconds < 1_000_000_000);
    return spec;
}

fn seconds(spec: TimeSpec) f64 {
    return @as(f64, @floatFromInt(spec.seconds)) +
        @as(f64, @floatFromInt(spec.nanoseconds)) / 1e9;
}

fn theRealtimeClock() void {
    const spec = read(.realtime);
    std.debug.assert(spec.seconds > epoch_lower);
    std.debug.assert(spec.seconds < epoch_upper);

    // The wall clock behind `os/time` is the same clock, so the two agree to
    // within the time it takes to call them twice.
    const now = janet_os_time_now();
    std.debug.assert(now > @as(f64, epoch_lower));
    std.debug.assert(now < @as(f64, epoch_upper));
    std.debug.assert(@abs(now - @as(f64, @floatFromInt(spec.seconds))) <= 2.0);
}

fn theMonotonicClockDoesNotGoBackwards() void {
    const first = read(.monotonic);
    const second = read(.monotonic);
    std.debug.assert(seconds(second) >= seconds(first));
}

fn theCputimeClockAccumulates() void {
    const before = read(.cputime);

    // Work the optimiser cannot remove, so that the clock has something to
    // measure. `volatile` in the C original; a mutable sink read afterwards
    // does the same job here.
    var sink: f64 = 0;
    var i: i32 = 0;
    while (i < 8_000_000) : (i += 1) sink += @floatFromInt(i);
    std.debug.assert(sink > 0);

    const after = read(.cputime);
    // Measured from process start, so it is positive and never decreases.
    std.debug.assert(seconds(before) > 0);
    std.debug.assert(seconds(after) >= seconds(before));
}

/// An unrecognised source falls back to the real-time clock; see the header.
fn anUnknownSourceIsTheRealtimeClock() void {
    const realtime = read(.realtime);
    const unknown = read(.unrecognised);
    std.debug.assert(@abs(seconds(unknown) - seconds(realtime)) <= 2.0);
}

fn sleepingAdvancesTheMonotonicClock() void {
    const before = read(.monotonic);
    janet_os_sleep(0.05);
    const after = read(.monotonic);

    const elapsed = seconds(after) - seconds(before);
    // The lower bound is the contract; see the header on the upper one.
    std.debug.assert(elapsed >= 0.04);
    std.debug.assert(elapsed < 10.0);

    // A zero delay returns rather than blocking.
    const idle_before = read(.monotonic);
    janet_os_sleep(0);
    const idle_after = read(.monotonic);
    std.debug.assert(seconds(idle_after) - seconds(idle_before) < 10.0);
}

// -------------------------------------------------------- the Janet surface

var environment: *types.JanetTable = undefined;

fn eval(source: [*:0]const u8) void {
    var result: repr.Value = undefined;
    std.debug.assert(core_env.dostring(environment, source, "os-time-contract", &result) == 0);
}

/// `os/clock` takes a source and a format, and the combinations are what the
/// suites do not cover. Written in Janet rather than in Zig because each of
/// these is one assertion about a returned value's shape, which Janet says in
/// a quarter of the space -- and because `:tuple` returns a tuple of two
/// numbers whose second field is a nanosecond remainder, which is far easier
/// to state as a predicate than to unwrap.
fn theSourcesAndFormats() void {
    // Absent from a reduced-OS build, and `options.os_time` does not say so:
    // that field is `hasGettime`, which is true there because the *subsystem*
    // is still compiled -- the event loop needs `janet_gettime` whether or not
    // `os/clock` is registered. The kernels above run either way; only this
    // section and `theRefusals` depend on the registration.
    if (harness.coreOptional("os/clock") == null) return;

    eval(
        \\(assert (number? (os/clock)))
        \\(assert (number? (os/clock :realtime)))
        \\(assert (number? (os/clock :monotonic)))
        \\(assert (number? (os/clock :cputime)))
        \\(assert (number? (os/clock :realtime :double)))
    );

    eval(
        \\(def whole (os/clock :realtime :int))
        \\(assert (= whole (math/floor whole)))
        \\(def parts (os/clock :monotonic :tuple))
        \\(assert (tuple? parts))
        \\(assert (= 2 (length parts)))
        \\(assert (= (parts 0) (math/floor (parts 0))))
        \\(assert (>= (parts 1) 0))
        \\(assert (< (parts 1) 1000000000))
    );

    eval(
        \\(assert (< (math/abs (- (os/time) (os/clock :realtime :int))) 2))
        \\(assert (> (os/time) 1672531200))
        \\(def earlier (os/clock :monotonic))
        \\(assert (>= (os/clock :monotonic) earlier))
    );

    eval(
        \\(def before (os/clock :monotonic))
        \\(os/sleep 0.05)
        \\(def elapsed (- (os/clock :monotonic) before))
        \\(assert (>= elapsed 0.04))
        \\(assert (< elapsed 10))
        \\(assert (nil? (os/sleep 0)))
    );
}

/// The refusals, which validation makes above the kernels. Read as values
/// rather than through `protect`, which is what the C contract had to use.
fn theRefusals() void {
    const clock = harness.coreOptional("os/clock") orelse return;
    const sleep = harness.coreOptional("os/sleep") orelse return;
    var argument: [2]repr.Value = undefined;

    argument[0] = value.fromBytes("nope", .keyword);
    std.debug.assert(harness.raised(clock, .{argument[0..1]}) != null);

    argument[0] = value.fromBytes("realtime", .keyword);
    argument[1] = value.fromBytes("nope", .keyword);
    std.debug.assert(harness.raised(clock, .{argument[0..2]}) != null);

    // A negative sleep is refused rather than treated as zero.
    argument[0] = harness.wrapInteger(-1);
    std.debug.assert(harness.raised(sleep, .{argument[0..1]}) != null);
}

pub fn run() void {
    theRealtimeClock();
    theMonotonicClockDoesNotGoBackwards();
    theCputimeClockAccumulates();
    anUnknownSourceIsTheRealtimeClock();
    sleepingAdvancesTheMonotonicClock();

    harness.init();
    environment = harness.coreEnv();
    theSourcesAndFormats();
    theRefusals();
    vm_lifecycle.deinit();
}
