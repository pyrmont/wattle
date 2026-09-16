//! Behavioral contract for the language-facing sites that read a value
//! through `args.chunks`, as seen by a type whose runs a real collection
//! would not hand out.
//!
//! The sites themselves are pinned where their subjects are: the splice
//! opcode in `vm_run.zig`, `array/concat` and `array/join` in
//! `buffer_array.zig`. What is here is `tuple/join`, which has no contract of
//! its own because every other thing it does has a Janet spelling and
//! `suite-corelib.janet` covers it.
//!
//! What no Janet suite can cover is a type that answers badly. A run is valid
//! only until the next run is taken from the same value, and the two counts
//! `tuple/join` reads come from a `length` callback that runs code between
//! them, so the site has to hold itself to the total the tuple was made for.
//! Neither property can be reached from Janet, because nothing a Janet
//! program can make implements the callback at all, and neither can be
//! reached from `test/zig-native.janet`, because a module written to be
//! correct answers consistently.
//!
//! ## What this file cannot cover
//!
//! The collector is not driven here. A raise part way through the copy leaves
//! a tuple whose slots were filled with nil before the copy began, and
//! `test/gc_stress.zig` is where a walk over a half-built value belongs. What
//! is asserted here is that the raise happens at all.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const abstract_type = @import("subsystems").abstract_type;
const abstracts = @import("subsystems").value.abstracts;
const args = @import("subsystems").args;
const core_env = @import("subsystems").env;
const expect = @import("expect.zig").expect;
const harness = @import("harness.zig");
const raise = @import("subsystems").raise;
const registry = @import("subsystems").registry;
const repr = @import("repr");
const vm_lifecycle = @import("subsystems").lifecycle;
const wrap = @import("subsystems").value.wrap;

// ==========================================================================
// Cases
// ==========================================================================

/// Numbers in runs of three from one buffer the callback overwrites on every
/// call, with a `length` that can disagree with itself.
///
/// `count` is what `length` reports the first time. `lie` is what it reports
/// afterwards, which is how the two counts `tuple/join` reads are made to
/// differ: a real type answers the same both times.
///
/// Every run is three long, so `count` is a multiple of three wherever the
/// elements are read rather than the disagreement. The elements are numbers,
/// so nothing in the buffer has to be marked.
const Join = struct {
    count: usize,
    lie: Lie,
    calls: usize,
    buffer: [3]repr.Value,

    const Lie = enum { none, grow, shrink };
};

const join_at = abstract_type.define(Join, .{
    .name = "indexed-sites/join",
    .length = joinLength,
    .chunk = joinChunk,
});

/// Element `i` is `i * 10`, in the run of three that holds `index`.
///
/// The buffer is reused, so a reader holding two runs of one value at once
/// reads the second run's elements twice instead of both runs once.
fn joinChunk(self: *Join, index: usize) abstract_type.Chunk {
    const start = index - index % 3;
    for (&self.buffer, start..) |*slot, i| slot.* = wrap.fromInteger(@intCast(i * 10));
    return .{ .items = &self.buffer, .start = start };
}

/// Reports `count`, and then what `lie` asks for on every later call.
fn joinLength(self: *Join, _: usize) raise.Error!usize {
    defer self.calls += 1;
    if (self.calls == 0) return self.count;
    return switch (self.lie) {
        .none => self.count,
        .grow => self.count + 3,
        .shrink => self.count - 3,
    };
}

fn cfunJoin(argv: []repr.Value) raise.Error!repr.Value {
    try args.arity(argv, 1, 2);
    const count = try args.getInteger(argv, 0);
    const lie: Join.Lie = if (argv.len == 2) switch (try args.getInteger(argv, 1)) {
        1 => .grow,
        2 => .shrink,
        else => .none,
    } else .none;
    const raw = abstracts.newBytes(&join_at, @sizeOf(Join));
    const join: *Join = @ptrCast(@alignCast(raw));
    join.* = .{ .count = @intCast(count), .lie = lie, .calls = 0, .buffer = undefined };
    return wrap.fromAbstract(raw);
}

const cfuns = [_]abi.Reg{
    .{ .name = "sites/join", .cfun = raise.stored(&cfunJoin), .documentation = null },
};

/// `tuple/join` counts every argument, allocates, and then copies, and it
/// reads each argument twice to do it. A tuple holding the same elements is
/// the oracle, and a count that changes between the two reads is refused
/// rather than copied past the end of the tuple.
fn tupleJoinReadsAnIndexedAbstract() void {
    var out: repr.Value = undefined;
    const env = harness.coreEnv();
    registry.cfuns(env, null, &cfuns);
    const source =
        \\(def failures @[])
        \\(defn- check [label ok] (unless ok (array/push failures label)))
        \\(defn- refusal [f & a] (let [[ok r] (protect (f ;a))] (unless ok r)))
        \\(def v (sites/join 9))
        \\(def oracle [0 10 20 30 40 50 60 70 80])
        \\(check "one abstract" (= (tuple/join v) (tuple/join oracle)))
        \\(check "the same value twice"
        \\       (= (tuple/join (sites/join 9) (sites/join 9))
        \\          (tuple/join oracle oracle)))
        \\(check "mixed with tuples"
        \\       (= (tuple/join [:a] v [:b]) (tuple/join [:a] oracle [:b])))
        \\(check "no arguments is the empty tuple" (= [] (tuple/join)))
        \\(check "a count that grows between the two reads"
        \\       (= "indexed value grew while being read"
        \\          (refusal tuple/join (sites/join 9 1))))
        \\(check "a count that shrinks between the two reads"
        \\       (= "indexed value shrank while being read"
        \\          (refusal tuple/join (sites/join 9 2))))
        \\(check "what is not indexed is still refused"
        \\       (= "expected indexed type for argument 0, got 5"
        \\          (refusal tuple/join 5)))
        \\failures
    ;
    expect(core_env.dostring(env, source, "indexed-sites-test", &out) == 0);
    expect(harness.isType(out, repr.Tag.array));
    const failed = wrap.toArray(out);
    if (failed.count != 0) {
        for (failed.slice()) |label| {
            std.debug.print("indexed-sites check failed: {s}\n", .{wrap.toString(label)});
        }
        expect(false);
    }
}

/// The three slice bindings read a window of an indexed value, so a run that
/// begins before the window or reaches past it is cut to fit rather than
/// refused. The same range of a tuple is the oracle for each case.
///
/// The probe's runs are three long, so a window starting or ending inside one
/// is what cuts a run at that end.
fn sliceReadsAWindowOfAnIndexedAbstract() void {
    var out: repr.Value = undefined;
    const env = harness.coreEnv();
    const source =
        \\(def failures @[])
        \\(defn- check [label ok] (unless ok (array/push failures label)))
        \\(defn- refusal [f & a] (let [r (protect (f ;a))] (get r 1)))
        \\(def v (sites/join 9))
        \\(def oracle [0 10 20 30 40 50 60 70 80])
        \\(check "a window cut at both ends"
        \\       (= (tuple/slice v 2 7) (tuple/slice oracle 2 7)))
        \\(check "and into an array"
        \\       (deep= (array/slice v 2 7) (array/slice oracle 2 7)))
        \\(check "and through slice"
        \\       (= (slice v 2 7) (slice oracle 2 7)))
        \\(check "a window over one whole run"
        \\       (= (tuple/slice v 3 6) (tuple/slice oracle 3 6)))
        \\(check "a window over everything"
        \\       (= (tuple/slice v) (tuple/slice oracle)))
        \\(check "an empty window"
        \\       (= (tuple/slice v 4 4) (tuple/slice oracle 4 4)))
        \\(check "the last element alone"
        \\       (= (tuple/slice v 8) (tuple/slice oracle 8)))
        \\(check "a negative index counts from the end"
        \\       (= (tuple/slice v -2) (tuple/slice oracle -2)))
        \\(check "an array slice of everything"
        \\       (deep= (array/slice v) (array/slice oracle)))
        \\(check "a range past the end is still refused"
        \\       (= (refusal tuple/slice v 12) (refusal tuple/slice oracle 12)))
        \\# A count that grows between the two reads is caught by the run
        \\# check rather than by the total: `getSlice` reads the larger count,
        \\# so the window runs past the length `chunks` read, and the callback
        \\# is asked for an index its own length does not cover.
        \\(check "a count that grows between the two reads"
        \\       (= "chunk of indexed-sites/join does not hold index 9"
        \\          (refusal tuple/slice (sites/join 9 1))))
        \\# A count that shrinks gives a smaller range, which is read whole.
        \\(check "a count that shrinks between the two reads"
        \\       (= (tuple/slice oracle 0 6) (tuple/slice (sites/join 9 2))))
        \\failures
    ;
    expect(core_env.dostring(env, source, "indexed-sites-test", &out) == 0);
    expect(harness.isType(out, repr.Tag.array));
    const failed = wrap.toArray(out);
    if (failed.count != 0) {
        for (failed.slice()) |label| {
            std.debug.print("indexed-sites check failed: {s}\n", .{wrap.toString(label)});
        }
        expect(false);
    }
}

// ==========================================================================
// Entry
// ==========================================================================

pub fn run() void {
    harness.init();
    tupleJoinReadsAnIndexedAbstract();
    sliceReadsAWindowOfAnIndexedAbstract();
    vm_lifecycle.deinit();
}
