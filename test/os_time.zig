//! Behavioral contract for the host clock services: `os.gettimeAbi`'s three
//! sources, the wall clock behind `os/time`, and `os.sleepFor`.
//!
//! A clock cannot be pinned to fixed vectors the way a parser can, so what is
//! asserted here is a set of *invariants* rather than values: which ranges each
//! source falls in, which orderings two readings guarantee, what an
//! unrecognised source does, and that a sleep actually advances a monotonic
//! clock. Those are the properties a port can break while still returning
//! plausible numbers, and no Janet suite reaches `os.gettimeAbi` at all.
//!
//! ## The bounds are deliberately wide
//!
//! Every numeric bound below is loose on purpose, and the reason is that this
//! runs on a shared machine under a matrix at `-j2`. A tight upper bound on a
//! sleep would fail for scheduling reasons and cost an afternoon proving it.
//! So the *lower* bound is the contract and the upper bound is only there to
//! catch a sleep that multiplied its argument by the wrong factor.
//!
//! ## The fallback for an unknown source is established behaviour
//!
//! `os.gettimeAbi` given a source it does not recognise gives the real-time
//! clock and reports success rather than failing, because it initialises its
//! clock id before it tests the source. That is asserted here so a change to
//! it would be deliberate.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const core_env = @import("subsystems").env;
const expect = @import("expect.zig").expect;
const harness = @import("harness.zig");
const os = @import("subsystems").os;
const repr = @import("repr");
const tables = @import("subsystems").value.tables;
const value = @import("subsystems").value;
const vm_lifecycle = @import("subsystems").lifecycle;
const wrap = @import("subsystems").value.wrap;

// ==========================================================================
// Constants
// ==========================================================================

var environment: *tables.Table = undefined;

/// Any run of this is after the start of 2023 and before the end of 2200.
const epoch_lower = 1672531200;
const epoch_upper = 7289654400;

// ==========================================================================
// Types
// ==========================================================================

/// The three clock sources, restated here so that a renumbering on either side
/// fails rather than agreeing with itself.
const Source = enum(c_int) {
    realtime = 0,
    monotonic = 1,
    cputime = 2,
    /// Not a source, and the value that reaches the fallback below.
    unrecognised = 99,
};

/// The `struct timespec` the entry point fills, declared here rather than
/// borrowed from `os.zig`: the field offsets are what this contract is
/// checking, so reading them from the subject would make the check circular.
const TimeSpec = extern struct {
    seconds: isize,
    nanoseconds: isize,
};

// ==========================================================================
// Cases
// ==========================================================================

fn read(source: Source) TimeSpec {
    // `os.Timespec` is the host's `struct timespec` and this is the contract's
    // independent restatement of it, so the two are separate types with the
    // same fields. On riscv32 the host's is more strictly aligned than a pair
    // of `isize`s, which is what the `@alignCast` says, and which is itself
    // a claim: if the two ever disagreed on size or offsets, the fields read
    // below would be wrong.
    var spec: TimeSpec align(@alignOf(os.Timespec)) = undefined;
    expect(os.gettimeAbi(@ptrCast(&spec), @bitCast(@intFromEnum(source))) == 0);
    // Normalised: the nanosecond field is a remainder, not a free-running
    // count, so a nanosecond field at or above a second would show up here.
    expect(spec.nanoseconds >= 0);
    expect(spec.nanoseconds < 1_000_000_000);
    return spec;
}

fn seconds(spec: TimeSpec) f64 {
    return @as(f64, @floatFromInt(spec.seconds)) +
        @as(f64, @floatFromInt(spec.nanoseconds)) / 1e9;
}

fn eval(source: [*:0]const u8) void {
    var result: repr.Value = undefined;
    expect(core_env.dostring(environment, source, "os-time-contract", &result) == 0);
}

fn theRealtimeClock() void {
    const spec = read(.realtime);
    expect(spec.seconds > epoch_lower);
    expect(spec.seconds < epoch_upper);

    // The wall clock behind `os/time` is the same clock, so the two agree to
    // within the time it takes to call them twice.
    const now = os.timeNow();
    expect(now > @as(f64, epoch_lower));
    expect(now < @as(f64, epoch_upper));
    expect(@abs(now - @as(f64, @floatFromInt(spec.seconds))) <= 2.0);
}

fn theMonotonicClockDoesNotGoBackwards() void {
    const first = read(.monotonic);
    const second = read(.monotonic);
    expect(seconds(second) >= seconds(first));
}

fn theCputimeClockAccumulates() void {
    const before = read(.cputime);

    // Work the optimiser cannot remove, so that the clock has something to
    // measure: a mutable sink, read afterwards so nothing can fold it away.
    var sink: f64 = 0;
    var i: i32 = 0;
    while (i < 8_000_000) : (i += 1) sink += @floatFromInt(i);
    expect(sink > 0);

    const after = read(.cputime);
    // Measured from process start, so it is positive and never decreases.
    expect(seconds(before) > 0);
    expect(seconds(after) >= seconds(before));
}

/// An unrecognised source falls back to the real-time clock; see the header.
fn anUnknownSourceIsTheRealtimeClock() void {
    const realtime = read(.realtime);
    const unknown = read(.unrecognised);
    expect(@abs(seconds(unknown) - seconds(realtime)) <= 2.0);
}

fn sleepingAdvancesTheMonotonicClock() void {
    const before = read(.monotonic);
    os.sleepFor(0.05);
    const after = read(.monotonic);

    const elapsed = seconds(after) - seconds(before);
    // The lower bound is the contract; see the header on the upper one.
    expect(elapsed >= 0.04);
    expect(elapsed < 10.0);

    // A zero delay returns rather than blocking.
    const idle_before = read(.monotonic);
    os.sleepFor(0);
    const idle_after = read(.monotonic);
    expect(seconds(idle_after) - seconds(idle_before) < 10.0);
}

/// `os/clock` takes a source and a format, and the combinations are what the
/// suites do not cover. Written in Janet rather than in Zig because each of
/// these is one assertion about a returned value's shape, which Janet says in
/// a quarter of the space, and because `:tuple` returns a tuple of two
/// numbers whose second field is a nanosecond remainder, which is far easier
/// to state as a predicate than to unwrap.
fn theSourcesAndFormats() void {
    // Absent from a reduced-OS build, and `options.os_time` does not say so:
    // that field is `hasGettime`, which is true there because the *subsystem*
    // is still compiled, the event loop needing `os.gettimeAbi` whether or not
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

/// The refusals, which validation makes above the kernels. Each is read as a
/// value rather than through `protect`.
fn theRefusals() void {
    const clock = harness.coreOptional("os/clock") orelse return;
    const sleep = harness.coreOptional("os/sleep") orelse return;
    var argument: [2]repr.Value = undefined;

    argument[0] = value.fromBytes("nope", .keyword);
    expect(harness.raised(clock, .{argument[0..1]}) != null);

    argument[0] = value.fromBytes("realtime", .keyword);
    argument[1] = value.fromBytes("nope", .keyword);
    expect(harness.raised(clock, .{argument[0..2]}) != null);

    // A negative sleep is refused rather than treated as zero.
    argument[0] = harness.wrapInteger(-1);
    expect(harness.raised(sleep, .{argument[0..1]}) != null);

    // So is a NaN, which names no duration.
    argument[0] = wrap.fromNumber(std.math.nan(f64));
    expect(harness.raised(sleep, .{argument[0..1]}).?.says("invalid argument to sleep"));
}

// ==========================================================================
// Entry
// ==========================================================================

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
