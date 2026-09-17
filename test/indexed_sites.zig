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
//! only until the next run is taken from the same value, and a `length`
//! callback runs code, so it can answer differently each time it is called
//! and can collect. `tuple/join` has to read each length once, and before it
//! allocates the tuple.
//! Neither property can be reached from Janet, because nothing a Janet
//! program can make implements the callback at all, and neither can be
//! reached from `test/zig-native.janet`, because a module written to be
//! correct answers consistently.
//!
//! ## What this file cannot cover
//!
//! The collector is driven here only from a `length` callback. A raise part
//! way through a copy leaves a tuple nothing reaches, which the sweep frees
//! without reading its slots, and `test/gc_stress.zig` is where that belongs.
//! What is asserted here is that the raise happens at all.

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
const gc_mark = @import("subsystems").gc_mark;
const harness = @import("harness.zig");
const raise = @import("subsystems").raise;
const registry = @import("subsystems").registry;
const repr = @import("repr");
const tuples = @import("subsystems").value.tuples;
const vm_entry = @import("subsystems").vm_entry;
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
    .{ .name = "sites/held", .cfun = raise.stored(&cfunHeld), .documentation = null },
    .{ .name = "sites/reenter", .cfun = raise.stored(&cfunReenter), .documentation = null },
};

/// Numbers as `Join` gives them, with a `length` that calls a Janet function
/// on a fresh fiber every time after the first.
///
/// A module's `pcall` resumes a fiber without suspending the collector, so a
/// `length` callback is a place a collection can run. A site that allocates
/// and then calls `length` holds a block nothing roots across that
/// collection.
const Reenter = struct {
    count: usize,
    calls: usize,
    callback: repr.Value,
    buffer: [3]repr.Value,
};

const reenter_at = abstract_type.define(Reenter, .{
    .name = "indexed-sites/reenter",
    .length = reenterLength,
    .chunk = reenterChunk,
    .gcmark = reenterMark,
});

fn reenterChunk(self: *Reenter, index: usize) abstract_type.Chunk {
    const start = index - index % 3;
    for (&self.buffer, start..) |*slot, i| slot.* = wrap.fromInteger(@intCast(i * 10));
    return .{ .items = &self.buffer, .start = start };
}

fn reenterLength(self: *Reenter, _: usize) raise.Error!usize {
    defer self.calls += 1;
    if (self.calls > 0) _ = vm_entry.pcall(wrap.toFunction(self.callback), &.{}, null);
    return self.count;
}

fn reenterMark(self: *Reenter, _: usize) void {
    gc_mark.mark(self.callback);
}

fn cfunReenter(argv: []repr.Value) raise.Error!repr.Value {
    try args.fixarity(argv, 2);
    const count = try args.getSize(argv, 0);
    const callback = try args.getFunction(argv, 1);
    const raw = abstracts.newBytes(&reenter_at, @sizeOf(Reenter));
    const reenter: *Reenter = @ptrCast(@alignCast(raw));
    reenter.* = .{ .count = count, .calls = 0, .callback = wrap.fromFunction(callback), .buffer = undefined };
    return wrap.fromAbstract(raw);
}

/// Values given at construction, handed out in runs of a chosen size.
///
/// `Join` hands out numbers it computes, which suits a site that compares
/// elements. A site that reads what the elements *are* needs to be given them,
/// so this one holds them and marks them: they are on the collector's heap and
/// the payload is the only thing pointing at them.
///
/// The run size is a parameter because a clause of two elements arriving as
/// two runs of one is the case a site gathering into a fixed buffer has to
/// get right.
const Held = struct {
    count: usize,
    run: usize,
    items: [max_held]repr.Value,

    /// The most values one of these can be given, which is the width of the
    /// array rather than anything a site requires.
    const max_held = 8;
};

const held_at = abstract_type.define(Held, .{
    .name = "indexed-sites/held",
    .length = heldLength,
    .chunk = heldChunk,
    .gcmark = heldMark,
});

fn heldChunk(self: *Held, index: usize) abstract_type.Chunk {
    const start = index - index % self.run;
    const end = @min(start + self.run, self.count);
    return .{ .items = self.items[start..end], .start = start };
}

fn heldLength(self: *Held, _: usize) raise.Error!usize {
    return self.count;
}

fn heldMark(self: *Held, _: usize) void {
    for (self.items[0..self.count]) |item| gc_mark.mark(item);
}

fn cfunHeld(argv: []repr.Value) raise.Error!repr.Value {
    try args.arity(argv, 1, -1);
    const per_run = try args.getSize(argv, 0);
    const values = argv[1..];
    if (per_run == 0 or values.len > Held.max_held) return raise.panic("bad probe");
    const raw = abstracts.newBytes(&held_at, @sizeOf(Held));
    const held: *Held = @ptrCast(@alignCast(raw));
    held.* = .{ .count = values.len, .run = per_run, .items = undefined };
    // Every slot written before the value is reachable, so `gcmark` never
    // walks one that was never set.
    for (&held.items) |*item| item.* = wrap.fromNil();
    @memcpy(held.items[0..values.len], values);
    return wrap.fromAbstract(raw);
}

/// `tuple/join` counts every argument, allocates, and then copies. A tuple
/// holding the same elements is the oracle. A `length` that would answer
/// differently a second time is read once, so the tuple has the elements of
/// the first answer.
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
        \\(check "a length that would grow is read once"
        \\       (= (tuple/join oracle) (tuple/join (sites/join 9 1))))
        \\(check "a length that would shrink is read once"
        \\       (= (tuple/join oracle) (tuple/join (sites/join 9 2))))
        \\(check "and after a tuple"
        \\       (= (tuple/join [:a] oracle) (tuple/join [:a] (sites/join 9 1))))
        \\(check "what is not indexed is still refused"
        \\       (= "expected indexed type for argument 0, got 5"
        \\          (refusal tuple/join 5)))
        \\(check "and after an abstract"
        \\       (= "expected indexed type for argument 2, got 5"
        \\          (refusal tuple/join [:a] v 5)))
        \\(check "more arguments than fit on the stack"
        \\       (= (tuple/join ;(map (fn [_] oracle) (range 12)))
        \\          (tuple/join ;(map (fn [i] (if (even? i) (sites/join 9) oracle))
        \\                            (range 12)))))
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

/// A collection run by an argument's `length` callback does not free the
/// tuple `tuple/join` is building. The tuple is checked against the heap list
/// by address before anything reads it, so a tuple the sweep freed fails here
/// rather than being read.
fn tupleJoinSurvivesACollectionInACallback() void {
    var out: repr.Value = undefined;
    const env = harness.coreEnv();
    registry.cfuns(env, null, &cfuns);
    const source =
        \\(tuple/join [:a] (sites/reenter 9 (fn [] (gccollect))) [:b])
    ;
    expect(core_env.dostring(env, source, "indexed-sites-test", &out) == 0);
    expect(harness.isType(out, repr.Tag.tuple));
    const tup = wrap.toTuple(out);
    expect(harness.heap.onList(harness.vm().gc.blocks, tuples.head(tup)));
    const view = tuples.view(tup);
    expect(view.len == 11);
    expect(harness.keywordIs(view[0], "a") and harness.keywordIs(view[10], "b"));
    for (view[1..10], 0..) |x, i| expect(harness.integerIs(x, @intCast(i * 10)));
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

/// `string/join` reads its parts through the protocol, and `ev/select` reads
/// a write clause through it. Both are given an abstract whose runs are
/// shorter than what they read, so each crosses a run boundary.
///
/// `string/join` counts its parts across runs to name a bad one by index, and
/// the collection here is what shows the probe's `gcmark` doing its work: the
/// strings it holds are reachable from nothing else.
///
/// The `ev/select` half is left out of the source where the build has no
/// event loop. A Janet program resolves every symbol when it compiles, so a
/// branch that would not run still refuses to compile.
fn joinAndSelectReadAnIndexedAbstract() void {
    var out: repr.Value = undefined;
    const env = harness.coreEnv();
    const select =
        \\# `ev/select` takes a write clause as two elements. Given in two runs
        \\# of one, both have to reach the gather.
        \\(def ch (ev/chan 1))
        \\(def result (ev/select (sites/held 1 ch :v)))
        \\(check "ev/select reads a write clause given in two runs"
        \\       (= [:give ch] result))
        \\(check "and the value it wrote is the one read back"
        \\       (= :v (get (ev/select ch) 2)))
    ;
    const has_select = harness.coreOptional("ev/select") != null;

    var buffer: [2048]u8 = undefined;
    const source = std.fmt.bufPrintZ(&buffer,
        \\(def failures @[])
        \\(defn- check [label ok] (unless ok (array/push failures label)))
        \\(defn- refusal [f & a] (let [r (protect (f ;a))] (get r 1)))
        \\(def oracle ["ab" "cd" "ef"])
        \\(check "string/join over runs of two"
        \\       (= (string/join (sites/held 2 "ab" "cd" "ef")) (string/join oracle)))
        \\(check "and with a separator between the parts"
        \\       (= (string/join (sites/held 2 "ab" "cd" "ef") "-") (string/join oracle "-")))
        \\(check "runs of one reach the same string"
        \\       (= (string/join (sites/held 1 "ab" "cd" "ef")) (string/join oracle)))
        \\(check "an empty abstract joins to the empty string"
        \\       (= "" (string/join (sites/held 1))))
        \\(check "a part that is not a byte sequence is named by its index"
        \\       (= (refusal string/join (sites/held 2 "ab" "cd" 5))
        \\          (refusal string/join ["ab" "cd" 5])))
        \\# The strings are built rather than written as literals, so nothing
        \\# but the abstract's payload points at them.
        \\(def held (sites/held 2 (string "x" "y") (string "z" "w")))
        \\(gccollect)
        \\(check "the values an abstract holds survive a collection"
        \\       (= "xyzw" (string/join held)))
        \\{s}
        \\failures
    , .{if (has_select) select else ""}) catch unreachable;
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

/// The three sites that cannot read a run at a time gather instead, and give
/// the same answer for an abstract as for the array or tuple beside it.
///
/// `os/execute` hands its arguments to the operating system as one array of C
/// strings. The FFI writes a value into a native layout, passing the elements
/// on as an argument list and an index into it. Neither shape can be fed by an
/// iterator, so both take a block, borrowed from an array or a tuple and
/// copied from an abstract.
///
/// Each half is left out of the source where its subsystem is not in the
/// build, which is what `coreOptional` answers. A Janet program resolves every
/// symbol when it compiles, so a branch that would not run still refuses to
/// compile.
fn theGatheringSitesReadAnIndexedAbstract() void {
    var out: repr.Value = undefined;
    const env = harness.coreEnv();
    const ffi =
        \\# A held abstract is neither an array nor a tuple, so it decodes as a
        \\# struct type, which is the arm a tuple takes.
        \\(check "a struct type given as an abstract"
        \\       (= (ffi/size [:u8 :u16]) (ffi/size (sites/held 1 :u8 :u16))))
        \\(def from-abstract @"")
        \\(def from-tuple @"")
        \\(ffi/write [:u8 :u16] (sites/held 1 1 2) from-abstract)
        \\(ffi/write [:u8 :u16] [1 2] from-tuple)
        \\(check "a struct written from an abstract"
        \\       (= (string from-abstract) (string from-tuple)))
        \\(def arr-abstract @"")
        \\(def arr-array @"")
        \\(ffi/write @[:u8 3] (sites/held 2 1 2 3) arr-abstract)
        \\(ffi/write @[:u8 3] @[1 2 3] arr-array)
        \\(check "an array written from an abstract in two runs"
        \\       (= (string arr-abstract) (string arr-array)))
        \\(check "and a wrong count is still refused"
        \\       (string/has-prefix? "bad array length"
        \\                           (let [r (protect (ffi/write @[:u8 3] (sites/held 2 1 2)))] (get r 1))))
    ;
    const execute =
        \\(check "os/execute takes its arguments from an abstract"
        \\       (= 0 (os/execute (sites/held 1 "true") :p)))
        \\(check "and an empty one is still refused"
        \\       (= "expected at least 1 command line argument"
        \\          (let [r (protect (os/execute (sites/held 1) :p))] (get r 1))))
    ;
    const has_ffi = harness.coreOptional("ffi/size") != null;
    const has_execute = harness.coreOptional("os/execute") != null;
    if (!has_ffi and !has_execute) return;

    var buffer: [2048]u8 = undefined;
    const source = std.fmt.bufPrintZ(&buffer,
        \\(def failures @[])
        \\(defn- check [label ok] (unless ok (array/push failures label)))
        \\{[ffi]s}
        \\{[exec]s}
        \\failures
    , .{ .ffi = if (has_ffi) ffi else "", .exec = if (has_execute) execute else "" }) catch unreachable;

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

/// A `cms` rule splices what its function returns into the captures, and reads
/// that value through the protocol.
///
/// The elements are gathered rather than streamed: `pushcap` grows the capture
/// array, so a run taken from the value would not survive the first element
/// being pushed.
fn aPegSpliceReadsAnIndexedAbstract() void {
    var out: repr.Value = undefined;
    const env = harness.coreEnv();
    if (harness.coreOptional("peg/match") == null) return;
    const source =
        \\(def failures @[])
        \\(defn- check [label ok] (unless ok (array/push failures label)))
        \\# The expected captures are written out rather than taken from a
        \\# tuple beside them: a tuple reaches the same converted code, so an
        \\# oracle built that way moves whenever the subject does.
        \\(check "a cms splicing an abstract in runs of two"
        \\       (deep= @[:p :q :r]
        \\              (peg/match ~(cms "a" ,(fn [& _] (sites/held 2 :p :q :r))) "a")))
        \\(check "runs of one reach the same captures"
        \\       (deep= @[:p :q :r]
        \\              (peg/match ~(cms "a" ,(fn [& _] (sites/held 1 :p :q :r))) "a")))
        \\(check "and a tuple still reaches them too"
        \\       (deep= @[:p :q :r]
        \\              (peg/match ~(cms "a" ,(fn [& _] [:p :q :r])) "a")))
        \\(check "an empty abstract splices nothing"
        \\       (deep= @[] (peg/match ~(cms "a" ,(fn [& _] (sites/held 1))) "a")))
        \\# A value that is not indexed is one capture, which is the arm the
        \\# conversion leaves alone.
        \\(check "a value that is not indexed is a single capture"
        \\       (deep= @[:solo] (peg/match ~(cms "a" ,(fn [& _] :solo)) "a")))
        \\# Enough elements to grow the capture array part way through, which is
        \\# what a borrowed run would not survive.
        \\(check "a splice long enough to grow the captures"
        \\       (deep= @[1 2 3 4 5 6 7 8]
        \\              (peg/match ~(cms "a" ,(fn [& _] (sites/held 2 1 2 3 4 5 6 7 8))) "a")))
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
    tupleJoinSurvivesACollectionInACallback();
    sliceReadsAWindowOfAnIndexedAbstract();
    joinAndSelectReadAnIndexedAbstract();
    theGatheringSitesReadAnIndexedAbstract();
    aPegSpliceReadsAnIndexedAbstract();
    vm_lifecycle.deinit();
}
