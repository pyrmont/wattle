//! Behavioral contract for `janet_next` and the indexed and keyed accessors.
//!
//! Nine functions, and the reason they are one contract is that they disagree
//! with each other on purpose. `in`, `getImpl` and `getIndex` answer the same
//! question about the same value and differ only in what a failure is -- a
//! panic, a nil, or a panic for one kind of failure and a nil for another.
//! Testing any one of them in isolation would pin a policy without pinning the
//! differences between the three policies, and the differences are the part a
//! port gets wrong. So the sections below run the same failing input through
//! all three and assert each answer against the others.
//!
//! Three properties get more attention than their size suggests.
//!
//! **The panic messages are the formatter's test.** `%v` puts a `Janet` --
//! eight bytes under nanboxing, sixteen under `-Dnanbox=false` -- through the
//! variadic formatter; `%T` puts a type-flag mask through as an `int`, `%u` a
//! `size_t`, `%d` an `int32_t`. Every one of those is a place where a mismatch
//! would produce a plausible-looking wrong message rather than a crash, so
//! every message here is compared byte for byte rather than merely being
//! expected to appear.
//!
//! **The two length bounds are not the same bound.** `length` rejects an
//! abstract length above `INT32_MAX` and `lengthv` rejects one at or above
//! `JANET_INTMAX_INT64`, so there is a wide band in which one panics and the
//! other succeeds. An implementation that used one bound for both would pass
//! every case that did not look in that band.
//!
//! **`janet_next` on a fiber has two error policies and they are chosen by an
//! argument.** `nextImpl`'s `is_interpreter` flag decides whether a signal from
//! the resumed fiber is re-raised as that signal or converted to a panic, and
//! it decides whether `vm.fiber.child` is cleared first. No in-tree
//! caller passes zero -- the VM always passes one -- so the whole `next` entry
//! point is reachable only from outside, and it is tested here through a
//! cfunction registered for the purpose.
//!
//! ## No panic counter
//!
//! A C contract counts its panics: forty-nine `EXPECT_PANIC`s and an assertion
//! at the foot that all forty-nine fired, because each is a twenty-line macro
//! -- open a scope, arm the flag, call the abi, read the flag, read the signal,
//! restore, compare the payload -- and with a macro that big it is worth
//! proving every one ran. Here a refusal is a value and each is
//! one line, so a refusal that stops happening fails at the call that expected
//! it rather than in a count at the end. That is a better failure and not
//! merely a shorter one; the tally is gone.
//!
//! The abstract fixtures need no adapter either. Five of the callbacks used
//! here -- `get`, `put`, `next`, `length` and the two methods -- are raising in
//! `abstract_type.zig`, which is exactly why C cannot define them and needs a
//! pool of pre-built tables. In Zig they are ordinary functions that return
//! `raise.Error!T`.
//!
//! Three edges the C original leaves undefined are answers here, and each has
//! a case below: `next` at `INT32_MAX` ends the iteration rather than wrapping,
//! `putIndex` bounds its index the way `put` does, and `next` on a fiber with
//! no fiber running resumes it without joining a chain there is none of.

const std = @import("std");
const repr = @import("repr");
const raise = @import("subsystems").raise;
const corefn = @import("subsystems").corefn;
const harness = @import("harness.zig");

const subsystems = @import("subsystems");
const value = @import("subsystems").value;
const structs = @import("subsystems").value.structs;
const tables = @import("subsystems").value.tables;
const gc_alloc = @import("subsystems").gc_alloc;
const arrays = @import("subsystems").value.arrays;
const buffers = @import("subsystems").value.buffers;
const tuples = @import("subsystems").value.tuples;
const utils = @import("subsystems").utils;
const core_env = @import("subsystems").env;
const wrap = @import("subsystems").value.wrap;
const args_core_mod = @import("subsystems").args;
const vm_lifecycle = @import("subsystems").lifecycle;
const abstracts = @import("subsystems").value.abstracts;
const access = @import("subsystems").value.access;
const registry = @import("subsystems").registry;
const abi = @import("abi");
const args_core = subsystems.args;
const abstract_type = subsystems.abstract_type;
const AbstractType = abstract_type.AbstractType;
const expect = @import("expect.zig").expect;

// ----------------------------------------------------------------- helpers

fn kw(name: [*:0]const u8) repr.Value {
    return value.fromBytes(std.mem.span(name), .keyword);
}

fn intv(i: i32) repr.Value {
    return harness.wrapInteger(i);
}

fn isNil(x: repr.Value) bool {
    return harness.isType(x, repr.Tag.nil);
}

/// The refusal a call made, which every panic case here reads. Named rather
/// than spelled at each site so that the `.?` -- "it must have refused" -- is
/// in one place.
fn refusal(function: anytype, args: anytype) harness.Raise {
    return harness.raised(function, args).?;
}

fn returns(function: anytype, args: anytype) void {
    expect(harness.raised(function, args) == null);
}

// ------------------------------------------------------- abstract fixtures

/// Three integer slots, addressed by integer keys, with every callback the
/// accessors reach. `next` walks 0, 1, 2 and stops.
const Slots = extern struct {
    slot: [3]i32,
};

fn slotsGet(s: *Slots, key: repr.Value) raise.Error!?repr.Value {
    if (!args_core_mod.checkint(key)) return null;
    const i = wrap.toInteger(key);
    if (i < 0 or i > 2) return null;
    return harness.wrapInteger(s.slot[@intCast(i)]);
}

fn slotsPut(s: *Slots, key: repr.Value, val: repr.Value) raise.Error!void {
    if (!args_core_mod.checkint(key)) return raise.panic("slots: bad key");
    const i = wrap.toInteger(key);
    if (i < 0 or i > 2) return raise.panic("slots: key out of range");
    s.slot[@intCast(i)] = wrap.toInteger(val);
}

fn slotsNext(_: *Slots, key: repr.Value) raise.Error!repr.Value {
    if (harness.isType(key, repr.Tag.nil)) return harness.wrapInteger(0);
    const i = wrap.toInteger(key) + 1;
    return if (i < 3) harness.wrapInteger(i) else wrap.fromNil();
}

fn slotsLength(_: *Slots, _: usize) raise.Error!usize {
    return 3;
}

const at_slots = abstract_type.define(Slots, .{
    .name = "value-access/slots",
    .get = &slotsGet,
    .put = &slotsPut,
    .next = &slotsNext,
    .length = &slotsLength,
});

/// No callbacks at all: the type every "no getter", "no setter" and "no next"
/// arm is written for.
const at_bare = abstract_type.define(anyopaque, .{ .name = "value-access/bare" });

/// Two lengths chosen to straddle the two different bounds.
fn bigLength(_: *anyopaque, _: usize) raise.Error!usize {
    return 2147483648; // INT32_MAX + 1
}

/// Whether the upper half of that straddle can be *expressed* on this target.
///
/// A `length` callback answers a `size_t`, and `JANET_INTMAX_INT64` is 2^53 --
/// so on a 32-bit target the bound `lengthv` enforces is unreachable through
/// this interface and the case below has nothing to say. The C original wrote
/// the constant anyway and let the cast truncate it silently, which on
/// `riscv32` would have made a case about the 2^53 bound into a case about
/// 4294967295 that quietly asserts the wrong message. Zig refuses the literal,
/// which is how this was found: skip rather than fake, arriving from the
/// compiler instead of from a reading.
const intmax_int64_fits_in_a_length = std.math.maxInt(usize) >= 9007199254740992;

fn hugeLength(_: *anyopaque, _: usize) raise.Error!usize {
    return 9007199254740992; // JANET_INTMAX_INT64
}

const at_big = abstract_type.define(anyopaque, .{ .name = "value-access/big", .length = &bigLength });
const at_huge = abstract_type.define(anyopaque, .{
    .name = "value-access/huge",
    .length = if (intmax_int64_fits_in_a_length) &hugeLength else null,
});

/// A type with no `length` callback but a `:length` method, which is the other
/// half of `length`'s abstract arm. The method is found through `getImpl` --
/// one of the functions under test -- so this arm re-enters the file it is
/// testing.
fn methodSeven(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    _ = @as(i32, @intCast(argv.len));

    return harness.wrapInteger(7);
}

fn methodKeyword(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    _ = @as(i32, @intCast(argv.len));

    return value.fromBytes("not-a-number", .keyword);
}

fn goodMethodGet(_: *anyopaque, key: repr.Value) raise.Error!?repr.Value {
    if (!args_core_mod.keyeq(key, "length")) return null;
    return wrap.fromCfunction(raise.stored(&methodSeven));
}

fn badMethodGet(_: *anyopaque, key: repr.Value) raise.Error!?repr.Value {
    if (!args_core_mod.keyeq(key, "length")) return null;
    return wrap.fromCfunction(raise.stored(&methodKeyword));
}

const at_good_method = abstract_type.define(anyopaque, .{
    .name = "value-access/good-method",
    .get = &goodMethodGet,
});

const at_bad_method = abstract_type.define(anyopaque, .{
    .name = "value-access/bad-method",
    .get = &badMethodGet,
});

var slots_value: repr.Value = undefined;
var bare_value: repr.Value = undefined;
var big_value: repr.Value = undefined;
var huge_value: repr.Value = undefined;
var good_method_value: repr.Value = undefined;
var bad_method_value: repr.Value = undefined;

fn typeOf(at: *const AbstractType) *const abi.AbstractType {
    return at;
}

fn makeAbstracts() void {
    const s: *Slots = @ptrCast(@alignCast(abstracts.newBytes(typeOf(&at_slots), @sizeOf(Slots))));
    s.slot = .{ 10, 11, 12 };
    slots_value = wrap.fromAbstract(s);
    bare_value = wrap.fromAbstract(abstracts.newBytes(typeOf(&at_bare), 8));
    big_value = wrap.fromAbstract(abstracts.newBytes(typeOf(&at_big), 8));
    huge_value = wrap.fromAbstract(abstracts.newBytes(typeOf(&at_huge), 8));
    good_method_value = wrap.fromAbstract(abstracts.newBytes(typeOf(&at_good_method), 8));
    bad_method_value = wrap.fromAbstract(abstracts.newBytes(typeOf(&at_bad_method), 8));
    gc_alloc.gcroot(slots_value);
    gc_alloc.gcroot(bare_value);
    gc_alloc.gcroot(big_value);
    gc_alloc.gcroot(huge_value);
    gc_alloc.gcroot(good_method_value);
    gc_alloc.gcroot(bad_method_value);
}

fn aCFunctionValue() repr.Value {
    return wrap.fromCfunction(raise.stored(&methodSeven));
}

// ------------------------------------------------------------ next: tables

/// The property that matters is completeness, not the order: starting from nil
/// and following `next` has to visit every key exactly once and then stop. A
/// bucket walk that skipped an occupied slot, or that restarted, would still
/// return plausible keys.
fn nextVisitsEveryTableKeyOnce() !void {
    const t = tables.new(0);
    const n = 64;
    for (0..n) |i| tables.put(t, intv(@intCast(i)), intv(@intCast(i * 100)));

    var seen = [_]bool{false} ** n;
    var count: usize = 0;
    var k = try access.next(wrap.fromTable(t), wrap.fromNil());
    while (!isNil(k)) : (k = try access.next(wrap.fromTable(t), k)) {
        expect(args_core_mod.checkint(k));
        const i = wrap.toInteger(k);
        expect(i >= 0 and i < n);
        expect(!seen[@intCast(i)]); // a key was visited twice
        seen[@intCast(i)] = true;
        count += 1;
        expect(count <= n);
    }
    expect(count == n);
}

/// Removing a key leaves a tombstone -- a bucket whose key is nil and whose
/// value is not -- and the walk has to step over it like any other empty bucket
/// rather than stopping at it.
fn nextStepsOverTombstones() !void {
    const t = tables.new(0);
    for (0..16) |i| tables.put(t, intv(@intCast(i)), intv(@intCast(i)));
    var i: i32 = 0;
    while (i < 16) : (i += 2) _ = tables.remove(t, intv(i));

    var count: usize = 0;
    var k = try access.next(wrap.fromTable(t), wrap.fromNil());
    while (!isNil(k)) : (k = try access.next(wrap.fromTable(t), k)) {
        expect(@rem(wrap.toInteger(k), 2) == 1);
        count += 1;
        expect(count <= 8);
    }
    expect(count == 8);
}

fn nextVisitsEveryStructKeyOnce() !void {
    const st = structs.begin(20);
    for (0..20) |i| structs.put(st, intv(@intCast(i)), intv(@intCast(i)));
    const s = wrap.fromStruct(structs.end(st));

    var seen = [_]bool{false} ** 20;
    var count: usize = 0;
    var k = try access.next(s, wrap.fromNil());
    while (!isNil(k)) : (k = try access.next(s, k)) {
        const i = wrap.toInteger(k);
        expect(i >= 0 and i < 20);
        expect(!seen[@intCast(i)]);
        seen[@intCast(i)] = true;
        count += 1;
        expect(count <= 20);
    }
    expect(count == 20);
}

/// Iteration reads the bucket array and nothing else, so a prototype's keys are
/// not visited even though `in` finds them. The two disagree, and that is
/// established behaviour rather than an accident: `(each k s ...)` over a struct
/// with a prototype sees only the struct's own keys.
fn nextDoesNotFollowAStructPrototype() !void {
    const pst = structs.begin(1);
    structs.put(pst, kw("inherited"), intv(1));
    const proto = structs.end(pst);

    const st = structs.begin(1);
    structs.put(st, kw("own"), intv(2));
    utils.structHead(st).proto = proto;
    const s = wrap.fromStruct(structs.end(st));

    const k = try access.next(s, wrap.fromNil());
    expect(harness.equals(k, kw("own")));
    expect(isNil(try access.next(s, k)));

    // ...but the key is reachable through every accessor.
    expect(harness.equals(try access.in(s, kw("inherited")), intv(1)));
    expect(harness.equals(try access.get(s, kw("inherited")), intv(1)));
}

/// A table's prototype behaves the same way, and for the same reason.
fn nextDoesNotFollowATablePrototype() !void {
    const proto = tables.new(0);
    tables.put(proto, kw("inherited"), intv(1));
    const t = tables.new(0);
    tables.put(t, kw("own"), intv(2));
    t.proto = proto;

    const k = try access.next(wrap.fromTable(t), wrap.fromNil());
    expect(harness.equals(k, kw("own")));
    expect(isNil(try access.next(wrap.fromTable(t), k)));
    expect(harness.equals(try access.in(wrap.fromTable(t), kw("inherited")), intv(1)));
}

/// An empty dictionary answers nil to the first step rather than walking off the
/// end of a zero-length bucket array.
fn nextOverEmptyDictionaries() !void {
    expect(isNil(try access.next(wrap.fromTable(tables.new(0)), wrap.fromNil())));
    const empty = wrap.fromStruct(structs.end(structs.begin(0)));
    expect(isNil(try access.next(empty, wrap.fromNil())));
}

// -------------------------------------------------------- next: sequences

fn nextOverEachSequenceType() !void {
    const b = buffers.new(4);
    buffers.pushCstringAbi(b, "abc");
    const a = arrays.new(4);
    for (0..3) |i| harness.arrayPush(a, intv(@intCast(i)));
    const t = tuples.begin(3);
    for (0..3) |i| t[i] = intv(@intCast(i));

    const seqs = [_]repr.Value{
        value.fromBytes("abc", .string),
        value.fromBytes("abc", .symbol),
        kw("abc"),
        wrap.fromBuffer(b),
        wrap.fromArray(a),
        wrap.fromTuple(tuples.end(t)),
    };

    for (seqs) |seq| {
        var k = try access.next(seq, wrap.fromNil());
        expect(harness.equals(k, intv(0)));
        k = try access.next(seq, k);
        expect(harness.equals(k, intv(1)));
        k = try access.next(seq, k);
        expect(harness.equals(k, intv(2)));
        expect(isNil(try access.next(seq, k)));
    }
}

/// A key that is not an integer is not an error here: iteration simply stops.
/// That is the opposite of what `in` does with the same key on the same value,
/// which is what makes it worth pinning.
fn nextStopsRatherThanPanickingOnABadKey() !void {
    const s = value.fromBytes("abc", .string);
    expect(isNil(try access.next(s, kw("x"))));
    expect(isNil(try access.next(s, wrap.fromNumber(1.5))));
    expect(isNil(try access.next(s, wrap.fromTrue())));
    expect(refusal(access.in, .{ s, kw("x") })
        .says("expected integer key for string in range [0, 3), got :x"));
}

/// A negative key advances to a still-negative index, which the range test
/// rejects. Both halves of that test are load-bearing: `i < len` alone would
/// accept it.
fn nextFromANegativeKey() !void {
    const s = value.fromBytes("abc", .string);
    expect(isNil(try access.next(s, intv(-5))));
    // -1 advances to 0, which is in range.
    expect(harness.equals(try access.next(s, intv(-1)), intv(0)));
}

fn nextPastTheEnd() !void {
    const s = value.fromBytes("abc", .string);
    expect(isNil(try access.next(s, intv(2))));
    expect(isNil(try access.next(s, intv(99))));
    expect(isNil(try access.next(value.fromBytes("", .string), wrap.fromNil())));

    // The last representable index has no successor, so the iteration ends
    // there. Answering nil by adding one and being rejected for going negative
    // is the same answer by an accident that only holds where the addition
    // wraps.
    expect(isNil(try access.next(s, intv(2147483647))));
    expect(isNil(try access.next(s, intv(2147483646))));
}

// --------------------------------------------------------- next: the rest

fn nextOnAnAbstract() !void {
    var k = try access.next(slots_value, wrap.fromNil());
    expect(harness.equals(k, intv(0)));
    k = try access.next(slots_value, k);
    expect(harness.equals(k, intv(1)));
    k = try access.next(slots_value, k);
    expect(harness.equals(k, intv(2)));
    expect(isNil(try access.next(slots_value, k)));

    // No `next` callback is not an error, it is an empty iteration.
    expect(isNil(try access.next(bare_value, wrap.fromNil())));
}

fn nextOnANonIterablePanics() void {
    expect(refusal(access.next, .{ intv(5), wrap.fromNil() })
        .says("expected iterable type, got 5"));
    expect(refusal(access.next, .{ wrap.fromNil(), wrap.fromNil() })
        .says("expected iterable type, got nil"));
    expect(refusal(access.next, .{ wrap.fromTrue(), wrap.fromNil() })
        .says("expected iterable type, got true"));
    expect(refusal(access.next, .{ aCFunctionValue(), wrap.fromNil() })
        .beginsWith("expected iterable type, got <cfunction "));
}

// ----------------------------------------------------------- next: fibers

// `next` writes `vm.fiber.child` before resuming *when there is a fiber*, so
// the cases about the chain have to run with one on the VM. These cfunctions
// are how: they are called from Janet source, so `vm.fiber` is the fiber
// running that source. The case with no fiber is separate, below.

fn cfunNext(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 2);
    return access.next(argv[0], argv[1]);
}

/// Resume through `next` and report whether the caller's `child` slot was put
/// back to null afterwards. A slot left set keeps the child fiber reachable and
/// misreports the fiber chain, and nothing else observes it.
fn cfunNextChildCleared(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 2);
    const self = harness.vm().fiber.?;
    _ = try access.next(argv[0], argv[1]);
    return wrap.fromBoolean(self.child == null);
}

/// The same, for the path that leaves through a panic. The runtime clears the
/// slot before panicking there and deliberately does not on the interpreter's
/// path, which is the one asymmetry in the function.
fn cfunNextChildClearedOnPanic(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 2);
    const self = harness.vm().fiber.?;
    if (harness.raised(access.next, .{ argv[0], argv[1] }) == null) {
        return wrap.fromNil(); // did not panic; the caller asserts
    }
    return wrap.fromBoolean(self.child == null);
}

const cfuns = [_]abi.Reg{
    .{ .name = "va/next", .cfun = raise.stored(&cfunNext), .documentation = null },
    .{ .name = "va/next-child-cleared", .cfun = raise.stored(&cfunNextChildCleared), .documentation = null },
    .{ .name = "va/next-child-cleared-on-panic", .cfun = raise.stored(&cfunNextChildClearedOnPanic), .documentation = null },
};

fn run_(src: [*:0]const u8) repr.Value {
    var out: repr.Value = undefined;
    const status = core_env.dostring(harness.coreEnv(), src, "value_access", &out);
    if (status != 0) {
        std.debug.print("janet source failed: {s}\n", .{src});
        expect(false);
    }
    return out;
}

/// Iterating a fiber runs it, and the key it yields is always the integer zero
/// -- a fiber has no index. The value comes back through `in`, which is the
/// whole reason the accessors have a `JANET_FIBER` arm at all.
fn nextResumesAFiber() void {
    const r = run_("(def f (fiber/new (fn [] (yield :a) (yield :b) :done)))" ++
        "[(next f nil) (in f 0)" ++
        " (next f 0)   (in f 0)" ++
        " (next f 0)   (fiber/status f)" ++
        " (next f 0)]");
    const v = wrap.toTuple(r);
    expect(harness.equals(v[0], intv(0)));
    expect(harness.equals(v[1], kw("a")));
    expect(harness.equals(v[2], intv(0)));
    expect(harness.equals(v[3], kw("b")));
    // The resume that finishes the fiber discards the return value and stops.
    expect(isNil(v[4]));
    expect(harness.equals(v[5], kw("dead")));
    // A dead fiber answers nil without being resumed.
    expect(isNil(v[6]));
}

/// `next` -- the entry point with `is_interpreter` clear -- has no in-tree
/// caller, so this is the only exercise it gets. It agrees with the
/// interpreter's path everywhere except on a signal.
fn theNextEntryPointOnAFiber() void {
    const r = run_("(def f (fiber/new (fn [] (yield :a) :done)))" ++
        "[(va/next f nil) (in f 0) (va/next f 0) (va/next f 0)]");
    const v = wrap.toTuple(r);
    expect(harness.equals(v[0], intv(0)));
    expect(harness.equals(v[1], kw("a")));
    expect(isNil(v[2]));
    expect(isNil(v[3]));
}

/// The published entry point with no fiber running, which is the state a
/// native module calling it from its own code is in. There is no chain to join,
/// so the fiber is resumed without one and the iteration is otherwise the same
/// as `theNextEntryPointOnAFiber`'s.
///
/// This case is called from the contract body rather than through `run_`,
/// because running it from Janet source is exactly what would give it a fiber.
fn theNextEntryPointOutsideAnyFiber() !void {
    expect(harness.vm().fiber == null);
    const f = run_("(fiber/new (fn [] (yield :a) :done))");
    gc_alloc.gcroot(f);
    defer _ = gc_alloc.gcunroot(f);
    const first = try access.next(f, wrap.fromNil());
    expect(harness.equals(first, intv(0)));
    expect(harness.vm().fiber == null);
    expect(harness.equals(try access.in(f, intv(0)), kw("a")));
    expect(isNil(try access.next(f, intv(0))));
}

/// Every status that cannot be resumed answers nil without touching the fiber.
/// `:new` and `:pending` are the two that can, and the list below is the
/// complement of those two.
fn nextOnAnUnresumableFiber() void {
    // One form, because `(fiber/current)` has to be read and used inside the
    // same fiber -- `janet_dostring` runs each top-level form in its own.
    const r = run_("(do" ++
        " (def dead (fiber/new (fn [] 1))) (resume dead)" ++
        " (def errd (fiber/new (fn [] (error :x)) :e)) (resume errd)" ++
        " (def alive (fiber/current))" ++
        " (def user (fiber/new (fn [] (signal 3 :s)) :3)) (resume user)" ++
        " [(fiber/status dead)  (next dead nil)" ++
        "  (fiber/status errd)  (next errd nil)" ++
        "  (fiber/status alive) (next alive nil)" ++
        "  (fiber/status user)  (next user nil)])");
    const v = wrap.toTuple(r);
    expect(harness.equals(v[0], kw("dead")));
    expect(isNil(v[1]));
    expect(harness.equals(v[2], kw("error")));
    expect(isNil(v[3]));
    expect(harness.equals(v[4], kw("alive")));
    expect(isNil(v[5]));
    expect(harness.equals(v[6], kw("user3")));
    expect(isNil(v[7]));
}

/// The `is_interpreter` asymmetry, which is the only thing the two entry points
/// disagree about. A signal the resumed fiber raises and does not trap reaches
/// the caller as that same signal through `nextImpl(..., 1)`, and as a plain
/// error through `nextImpl(..., 0)`. The payload survives either way, so the
/// status is the only thing that distinguishes them.
fn theInterpreterFlagChoosesTheErrorPolicy() void {
    const r = run_("(def mk (fn [] (fiber/new (fn [] (signal 5 :sig)))))" ++
        "(def viaint (fiber/new (fn [] (next (mk) nil)) :5))" ++
        "(def viacapi (fiber/new (fn [] (va/next (mk) nil)) :5e))" ++
        "[(resume viaint)  (fiber/status viaint)" ++
        " (resume viacapi) (fiber/status viacapi)]");
    const v = wrap.toTuple(r);
    expect(harness.equals(v[0], kw("sig")));
    expect(harness.equals(v[1], kw("user5")));
    expect(harness.equals(v[2], kw("sig")));
    expect(harness.equals(v[3], kw("error")));
}

fn theChildSlotIsCleared() void {
    const r = run_("(def ok (fiber/new (fn [] (yield :a) :done)))" ++
        "(def bad (fiber/new (fn [] (error :boom))))" ++
        "[(va/next-child-cleared ok nil)" ++
        " (va/next-child-cleared-on-panic bad nil)]");
    const v = wrap.toTuple(r);
    expect(repr.truthy(v[0])); // child not cleared after a successful resume
    expect(harness.isType(v[1], repr.Tag.boolean)); // the failing resume did not panic
    expect(repr.truthy(v[1])); // child not cleared before the panic
}

/// Resuming through `next` links the child into the caller's fiber chain before
/// it runs, and that link is what `debug/lineage` walks -- and, through the same
/// chain, what puts the resumed fiber's frames into a stack trace. The link is
/// only observable while the child is running, so the child observes it itself.
fn theResumedFiberJoinsTheLineage() void {
    const r = run_("(do" ++
        " (def log @[])" ++
        " (var outer nil)" ++
        " (def child (fiber/new (fn []" ++
        "   (array/push log (length (debug/lineage outer)))" ++
        "   (yield 1))))" ++
        " (set outer (fiber/new (fn [] (next child nil))))" ++
        " (resume outer)" ++
        " log)");
    const log = wrap.toArray(r);
    expect(log.count == 1);
    // the resumed fiber was not linked into the caller's chain
    expect(wrap.toInteger(log.slice()[0]) == 2);
}

// --------------------------------------------------------------- janet_in

fn inReadsEveryContainer() !void {
    const a = arrays.new(2);
    harness.arrayPush(a, kw("x"));
    harness.arrayPush(a, kw("y"));
    expect(harness.equals(try access.in(wrap.fromArray(a), intv(1)), kw("y")));

    const t = tuples.begin(2);
    t[0] = kw("x");
    t[1] = kw("y");
    const tup = wrap.fromTuple(tuples.end(t));
    expect(harness.equals(try access.in(tup, intv(0)), kw("x")));

    const b = buffers.new(4);
    buffers.pushCstringAbi(b, "AB");
    expect(harness.equals(try access.in(wrap.fromBuffer(b), intv(1)), intv('B')));

    expect(harness.equals(try access.in(value.fromBytes("AB", .string), intv(0)), intv('A')));
    expect(harness.equals(try access.in(value.fromBytes("AB", .symbol), intv(1)), intv('B')));
    expect(harness.equals(try access.in(kw("AB"), intv(0)), intv('A')));

    const tab = tables.new(0);
    tables.put(tab, kw("k"), intv(3));
    expect(harness.equals(try access.in(wrap.fromTable(tab), kw("k")), intv(3)));

    const st = structs.begin(1);
    structs.put(st, kw("k"), intv(4));
    expect(harness.equals(try access.in(wrap.fromStruct(structs.end(st)), kw("k")), intv(4)));

    expect(harness.equals(try access.in(slots_value, intv(2)), intv(12)));
}

/// A key that is merely absent from a dictionary is nil, not an error. The panic
/// in `in` is about keys that are wrong for the container, and a dictionary
/// accepts every key.
fn inOnAMissingDictionaryKeyIsNil() !void {
    const tab = tables.new(0);
    expect(isNil(try access.in(wrap.fromTable(tab), kw("nope"))));
    const st = wrap.fromStruct(structs.end(structs.begin(0)));
    expect(isNil(try access.in(st, kw("nope"))));
    // Including keys no sequence would accept.
    expect(isNil(try access.in(wrap.fromTable(tab), wrap.fromNumber(1.5))));
}

/// One message, four ways to earn it, and it names the container's type and the
/// exclusive upper bound. Every sequence type is checked because the type name
/// comes out of the type-name table and a wrong index there would still produce
/// a well-formed message.
fn inPanicsOnABadKey() void {
    const a = arrays.new(1);
    harness.arrayPush(a, intv(0));
    const arr = wrap.fromArray(a);
    expect(refusal(access.in, .{ arr, kw("x") })
        .says("expected integer key for array in range [0, 1), got :x"));
    expect(refusal(access.in, .{ arr, intv(1) })
        .says("expected integer key for array in range [0, 1), got 1"));
    expect(refusal(access.in, .{ arr, intv(-1) })
        .says("expected integer key for array in range [0, 1), got -1"));
    expect(refusal(access.in, .{ arr, wrap.fromNumber(0.5) })
        .says("expected integer key for array in range [0, 1), got 0.5"));

    const t = tuples.begin(1);
    t[0] = intv(0);
    expect(refusal(access.in, .{ wrap.fromTuple(tuples.end(t)), intv(3) })
        .says("expected integer key for tuple in range [0, 1), got 3"));
    expect(refusal(access.in, .{ wrap.fromBuffer(buffers.new(4)), intv(0) })
        .says("expected integer key for buffer in range [0, 0), got 0"));
    expect(refusal(access.in, .{ value.fromBytes("abc", .string), intv(9) })
        .says("expected integer key for string in range [0, 3), got 9"));
    expect(refusal(access.in, .{ value.fromBytes("abc", .symbol), intv(9) })
        .says("expected integer key for symbol in range [0, 3), got 9"));
    expect(refusal(access.in, .{ kw("abc"), intv(9) })
        .says("expected integer key for keyword in range [0, 3), got 9"));
}

const not_lengthable = "expected string, symbol, keyword, array, tuple, " ++
    "table, struct or buffer, got ";

/// The `%T` message, which renders a type-flag mask rather than a value. Two
/// different masks appear in this file and they have to stay different.
fn inOnANonLengthablePanics() void {
    expect(refusal(access.in, .{ intv(5), intv(0) }).says(not_lengthable ++ "5"));
    expect(refusal(access.in, .{ wrap.fromNil(), intv(0) }).says(not_lengthable ++ "nil"));
    expect(refusal(access.in, .{ wrap.fromTrue(), intv(0) }).says(not_lengthable ++ "true"));
    expect(refusal(access.in, .{ aCFunctionValue(), intv(0) }).beginsWith(not_lengthable));
}

/// An abstract type is the one place where a key that is simply absent is an
/// error, because its `get` reports presence separately from the value.
fn inOnAnAbstract() !void {
    expect(harness.equals(try access.in(slots_value, intv(0)), intv(10)));
    expect(refusal(access.in, .{ slots_value, intv(7) })
        .beginsWith("key 7 not found in <value-access/slots "));
    expect(refusal(access.in, .{ slots_value, kw("nope") })
        .beginsWith("key :nope not found in <value-access/slots "));
    expect(refusal(access.in, .{ bare_value, intv(0) })
        .beginsWith("no getter for <value-access/bare "));
}

fn inOnAFiber() void {
    const r = run_("(def f (fiber/new (fn [] (yield :a) :done)))" ++
        "(next f nil)" ++
        "[(in f 0) (get f 0) (get f 1) (protect (in f 1))]");
    const v = wrap.toTuple(r);
    expect(harness.equals(v[0], kw("a")));
    expect(harness.equals(v[1], kw("a")));
    expect(isNil(v[2]));
    // `protect` returns [false message] for a caught error.
    const p = wrap.toTuple(v[3]);
    expect(!repr.truthy(p[0]));
    expect(harness.equals(p[1], value.fromBytes("expected key 0, got 1", .string)));
}

// -------------------------------------------------------------- janet_get

/// Everything `in` panics about, `getImpl` answers nil to -- including the
/// container type itself, which is why `getImpl` accepts a number as a data
/// structure and `in` does not.
fn getAnswersNilWhereInPanics() !void {
    const a = arrays.new(1);
    harness.arrayPush(a, intv(0));
    const arr = wrap.fromArray(a);
    expect(isNil(try access.get(arr, kw("x"))));
    expect(isNil(try access.get(arr, intv(1))));
    expect(isNil(try access.get(arr, intv(-1))));
    expect(isNil(try access.get(arr, wrap.fromNumber(0.5))));
    expect(isNil(try access.get(value.fromBytes("abc", .string), intv(9))));
    // The string arm has its own negative-index case, separate from the one the
    // array, tuple and buffer arm shares, and both have to be there: an index
    // below zero is not "past the end" and the length test alone lets it
    // through.
    expect(isNil(try access.get(value.fromBytes("abc", .string), intv(-1))));
    expect(isNil(try access.get(value.fromBytes("abc", .symbol), intv(-1))));
    expect(isNil(try access.get(kw("abc"), intv(-1))));
    expect(isNil(try access.get(
        wrap.fromTuple(tuples.end(tuples.begin(0))),
        intv(-1),
    )));
    expect(isNil(try access.get(wrap.fromBuffer(buffers.new(4)), intv(0))));
    expect(isNil(try access.get(intv(5), intv(0))));
    expect(isNil(try access.get(wrap.fromNil(), intv(0))));
    expect(isNil(try access.get(wrap.fromTrue(), kw("x"))));
    expect(isNil(try access.get(bare_value, intv(0))));
    expect(isNil(try access.get(slots_value, intv(7))));
    expect(isNil(try access.get(aCFunctionValue(), intv(0))));
}

/// ...and where both succeed they agree.
fn getAgreesWithInWhereBothSucceed() !void {
    const a = arrays.new(2);
    harness.arrayPush(a, kw("x"));
    harness.arrayPush(a, kw("y"));
    const t = tuples.begin(1);
    t[0] = kw("t");
    const b = buffers.new(4);
    buffers.pushCstringAbi(b, "AB");
    const tab = tables.new(0);
    tables.put(tab, kw("k"), intv(3));
    const st = structs.begin(1);
    structs.put(st, kw("k"), intv(4));

    const pairs = [_][2]repr.Value{
        .{ wrap.fromArray(a), intv(1) },
        .{ wrap.fromTuple(tuples.end(t)), intv(0) },
        .{ wrap.fromBuffer(b), intv(1) },
        .{ value.fromBytes("AB", .string), intv(0) },
        .{ wrap.fromTable(tab), kw("k") },
        .{ wrap.fromStruct(structs.end(st)), kw("k") },
        .{ slots_value, intv(2) },
    };
    for (pairs) |pair| {
        expect(harness.equals(try access.in(pair[0], pair[1]), try access.get(pair[0], pair[1])));
    }
}

// --------------------------------------------------------- janet_getindex

/// The third policy: a negative index and a missing getter panic, and every
/// other failure is nil. The abstract arm is where it parts company with `in` --
/// a `get` that runs and reports absence is an error there and a nil here.
fn theGetIndexPolicies() !void {
    const a = arrays.new(1);
    harness.arrayPush(a, kw("x"));
    const arr = wrap.fromArray(a);
    expect(harness.equals(try access.getIndex(arr, 0), kw("x")));
    expect(isNil(try access.getIndex(arr, 5)));
    expect(refusal(access.getIndex, .{ arr, -1 }).says("expected non-negative index"));
    expect(refusal(access.getIndex, .{ wrap.fromNil(), -1 }).says("expected non-negative index"));

    expect(isNil(try access.getIndex(value.fromBytes("ab", .string), 9)));
    expect(harness.equals(try access.getIndex(value.fromBytes("ab", .string), 1), intv('b')));
    expect(isNil(try access.getIndex(wrap.fromBuffer(buffers.new(4)), 0)));

    const t = tuples.begin(1);
    t[0] = kw("t");
    const tup = wrap.fromTuple(tuples.end(t));
    expect(harness.equals(try access.getIndex(tup, 0), kw("t")));
    expect(isNil(try access.getIndex(tup, 1)));

    // Dictionaries are keyed by the integer, so an out-of-range index is a
    // missing key rather than an out-of-range one.
    const tab = tables.new(0);
    tables.put(tab, intv(7), kw("seven"));
    expect(harness.equals(try access.getIndex(wrap.fromTable(tab), 7), kw("seven")));
    expect(isNil(try access.getIndex(wrap.fromTable(tab), 0)));

    const st = structs.begin(1);
    structs.put(st, intv(7), kw("seven"));
    const s = wrap.fromStruct(structs.end(st));
    expect(harness.equals(try access.getIndex(s, 7), kw("seven")));
    expect(isNil(try access.getIndex(s, 0)));

    // The disagreement with `in`, stated directly.
    expect(isNil(try access.getIndex(slots_value, 7)));
    expect(refusal(access.in, .{ slots_value, intv(7) }).beginsWith("key 7 not found in "));
    expect(refusal(access.getIndex, .{ bare_value, 0 })
        .beginsWith("no getter for <value-access/bare "));
    expect(refusal(access.getIndex, .{ intv(5), 0 }).says(not_lengthable ++ "5"));
}

fn getIndexOnAFiber() !void {
    const r = run_("(def f (fiber/new (fn [] (yield :a) :done)))" ++
        "(next f nil) f");
    expect(harness.equals(try access.getIndex(r, 0), kw("a")));
    expect(isNil(try access.getIndex(r, 1)));
}

// ---------------------------------------------------------------- lengths

fn theLengthOfEveryContainer() !void {
    const a = arrays.new(3);
    for (0..3) |i| harness.arrayPush(a, intv(@intCast(i)));
    const b = buffers.new(4);
    buffers.pushCstringAbi(b, "abcd");
    const t = tuples.begin(2);
    t[0] = wrap.fromNil();
    t[1] = wrap.fromNil();
    const tab = tables.new(0);
    tables.put(tab, kw("a"), intv(1));
    tables.put(tab, kw("b"), intv(2));
    const st = structs.begin(1);
    structs.put(st, kw("a"), intv(1));

    const cases = [_]struct { value: repr.Value, length: i32 }{
        .{ .value = value.fromBytes("abc", .string), .length = 3 },
        .{ .value = value.fromBytes("abcd", .symbol), .length = 4 },
        .{ .value = kw("ab"), .length = 2 },
        .{ .value = wrap.fromArray(a), .length = 3 },
        .{ .value = wrap.fromBuffer(b), .length = 4 },
        .{ .value = wrap.fromTuple(tuples.end(t)), .length = 2 },
        .{ .value = wrap.fromTable(tab), .length = 2 },
        .{ .value = wrap.fromStruct(structs.end(st)), .length = 1 },
    };
    for (cases) |case| {
        expect(try access.length(case.value) == case.length);
        expect(harness.equals(try access.lengthv(case.value), intv(case.length)));
    }

    // A struct's length is its pair count, not its bucket count.
    const wide = structs.begin(9);
    for (0..9) |i| structs.put(wide, intv(@intCast(i)), intv(@intCast(i)));
    const w = wrap.fromStruct(structs.end(wide));
    expect(try access.length(w) == 9);
    expect(utils.structHead(wrap.toStruct(w)).capacity > 9);
}

/// A table's length is its live count, so removing a key shortens it even though
/// the tombstone stays in the bucket array.
fn theLengthOfATableIgnoresTombstones() !void {
    const tab = tables.new(0);
    for (0..8) |i| tables.put(tab, intv(@intCast(i)), intv(@intCast(i)));
    expect(try access.length(wrap.fromTable(tab)) == 8);
    _ = tables.remove(tab, intv(0));
    expect(try access.length(wrap.fromTable(tab)) == 7);
    expect(tab.deleted == 1);
}

fn theAbstractLengthCallback() !void {
    expect(try access.length(slots_value) == 3);
    expect(harness.equals(try access.lengthv(slots_value), wrap.fromNumber(3.0)));
    // `lengthv` wraps a callback's length as a double rather than as an integer,
    // and the two are equal but not identically represented.
    expect(harness.isType(try access.lengthv(slots_value), repr.Tag.number));
}

/// The band where the two functions disagree. `length` stops at `INT32_MAX`
/// because it returns an `int32_t`; `lengthv` stops at `JANET_INTMAX_INT64`
/// because it returns a double. A length between them panics one and satisfies
/// the other.
fn theTwoLengthBoundsAreDifferent() !void {
    expect(refusal(access.length, .{big_value}).says("invalid integer length 2147483648"));
    const lv = try access.lengthv(big_value);
    expect(harness.isType(lv, repr.Tag.number));
    expect(wrap.toNumber(lv) == 2147483648.0);

    if (intmax_int64_fits_in_a_length) {
        expect(refusal(access.length, .{huge_value}).says("invalid integer length 9007199254740992"));
        expect(refusal(access.lengthv, .{huge_value}).says("integer length 9007199254740992 too large"));
    }
}

/// Without a `length` callback the length comes from a `:length` method, which
/// is looked up through `getImpl` -- so this arm re-enters the file under test.
/// `length` checks the result and `lengthv` does not, which is the second place
/// the two disagree.
fn theLengthFallsBackToAMethod() !void {
    expect(try access.length(good_method_value) == 7);
    expect(harness.equals(try access.lengthv(good_method_value), intv(7)));

    expect(refusal(access.length, .{bad_method_value}).says("invalid integer length :not-a-number"));
    expect(harness.equals(try access.lengthv(bad_method_value), kw("not-a-number")));

    expect(refusal(access.length, .{bare_value})
        .beginsWith("could not find method :length for <value-access/bare "));
    expect(refusal(access.lengthv, .{bare_value})
        .beginsWith("could not find method :length for <value-access/bare "));
}

fn theLengthOfANonLengthablePanics() void {
    expect(refusal(access.length, .{intv(5)}).says(not_lengthable ++ "5"));
    expect(refusal(access.lengthv, .{intv(5)}).says(not_lengthable ++ "5"));
    expect(refusal(access.length, .{wrap.fromNil()}).says(not_lengthable ++ "nil"));
    expect(refusal(access.lengthv, .{wrap.fromNil()}).says(not_lengthable ++ "nil"));
}

// ---------------------------------------------------------------- setters

/// Writing past the end grows the container, and the two growable types fill the
/// gap differently: an array with nil, a buffer with zero.
fn putGrowsAnArrayWithNils() !void {
    const a = arrays.new(0);
    harness.arrayPush(a, kw("first"));
    try access.put(wrap.fromArray(a), intv(4), kw("fifth"));
    expect(a.count == 5);
    expect(harness.equals(a.slice()[0], kw("first")));
    for (1..4) |i| expect(isNil(a.slice()[i]));
    expect(harness.equals(a.slice()[4], kw("fifth")));

    // An in-range write does not shorten it.
    try access.put(wrap.fromArray(a), intv(0), kw("again"));
    expect(a.count == 5);
    expect(harness.equals(a.slice()[0], kw("again")));
}

/// The growth test is `index >= count`, not `index > count`, so appending at
/// exactly the current count grows by one. An off-by-one there writes the value
/// into a slot the count does not cover, which is invisible rather than wrong.
fn putIndexAppendsAtTheCount() !void {
    const a = arrays.new(8);
    harness.arrayPush(a, kw("a"));
    try access.putIndex(wrap.fromArray(a), 1, kw("b"));
    expect(a.count == 2);
    expect(harness.equals(a.slice()[1], kw("b")));

    const b = buffers.new(8);
    buffers.pushCstringAbi(b, "A");
    try access.putIndex(wrap.fromBuffer(b), 1, intv('B'));
    expect(b.count == 2);
    expect(b.slice()[1] == 'B');
}

fn putIndexGrowsABufferWithZeroes() !void {
    const b = buffers.new(0);
    buffers.pushCstringAbi(b, "A");
    try access.putIndex(wrap.fromBuffer(b), 4, intv('E'));
    expect(b.count == 5);
    expect(b.slice()[0] == 'A');
    for (1..4) |i| expect(b.slice()[i] == 0);
    expect(b.slice()[4] == 'E');

    try access.putIndex(wrap.fromBuffer(b), 0, intv('Z'));
    expect(b.count == 5);
    expect(b.slice()[0] == 'Z');
}

/// A buffer stores bytes, and the value is masked to eight bits after being
/// checked for integer-ness rather than being range-checked. So a value out of
/// byte range is stored truncated and does not complain.
fn aBufferTruncatesToAByte() !void {
    const b = buffers.new(4);
    buffers.pushBytes(b, "\x00\x00") catch @panic("value_access: buffer push raised");
    try access.put(wrap.fromBuffer(b), intv(0), intv(300));
    expect(b.slice()[0] == 44);
    try access.putIndex(wrap.fromBuffer(b), 1, intv(-1));
    expect(b.slice()[1] == 255);
    try access.put(wrap.fromBuffer(b), intv(0), intv(256));
    expect(b.slice()[0] == 0);
    // Eight bits, not seven: a value whose low byte has the high bit set
    // survives through both entry points.
    try access.put(wrap.fromBuffer(b), intv(0), intv(200));
    expect(b.slice()[0] == 200);
    try access.putIndex(wrap.fromBuffer(b), 1, intv(200));
    expect(b.slice()[1] == 200);
}

/// `put` checks the key before the value and `putIndex` has no key to check, so
/// the same two bad arguments produce different messages depending on which
/// function is asked.
fn putChecksTheKeyBeforeTheValue() void {
    const b = buffers.new(4);
    buffers.pushCstringAbi(b, "AB");
    expect(refusal(access.put, .{ wrap.fromBuffer(b), kw("x"), kw("y") })
        .says("expected integer key for buffer in range [0, 2147483646), got :x"));
    expect(refusal(access.put, .{ wrap.fromBuffer(b), intv(0), kw("y") })
        .says("can only put integers in buffers, got :y"));
    expect(refusal(access.putIndex, .{ wrap.fromBuffer(b), 0, kw("y") })
        .says("can only put integers in buffers, got :y"));
    // The rejected write left the buffer alone.
    expect(b.count == 2 and b.slice()[0] == 'A');
}

/// The value check comes before the growth, so a rejected write to a buffer does
/// not resize it -- which is not true of the key check on an array, where there
/// is nothing to reject after the bound.
fn aRejectedBufferWriteDoesNotGrowIt() void {
    const b = buffers.new(0);
    expect(refusal(access.putIndex, .{ wrap.fromBuffer(b), 100, kw("y") })
        .says("can only put integers in buffers, got :y"));
    expect(b.count == 0);
}

/// `put` bounds its index at `INT32_MAX - 1` so that the `index + 1` its
/// growth arm computes cannot overflow, and `putIndex` takes the same bound
/// from the same helper -- so the two refuse the same indices with the same
/// message, whichever a caller reaches.
fn putBoundsTheIndex() void {
    const a = arrays.new(0);
    expect(refusal(access.put, .{ wrap.fromArray(a), intv(2147483647), intv(1) })
        .says("expected integer key for array in range [0, 2147483646), got 2147483647"));
    expect(refusal(access.put, .{ wrap.fromArray(a), intv(-1), intv(1) })
        .says("expected integer key for array in range [0, 2147483646), got -1"));
    expect(a.count == 0);

    expect(refusal(access.putIndex, .{ wrap.fromArray(a), 2147483647, intv(1) })
        .says("expected integer key for array in range [0, 2147483646), got 2147483647"));
    expect(refusal(access.putIndex, .{ wrap.fromArray(a), -1, intv(1) })
        .says("expected integer key for array in range [0, 2147483646), got -1"));
    expect(a.count == 0);

    const b = buffers.new(0);
    expect(refusal(access.putIndex, .{ wrap.fromBuffer(b), 2147483647, intv(1) })
        .says("expected integer key for buffer in range [0, 2147483646), got 2147483647"));
    expect(b.count == 0);
}

fn putOnATableAndAnAbstract() !void {
    const tab = tables.new(0);
    try access.put(wrap.fromTable(tab), kw("k"), intv(1));
    expect(harness.equals(try access.in(wrap.fromTable(tab), kw("k")), intv(1)));
    try access.putIndex(wrap.fromTable(tab), 3, intv(2));
    expect(harness.equals(try access.in(wrap.fromTable(tab), intv(3)), intv(2)));

    try access.put(slots_value, intv(0), intv(99));
    expect(harness.equals(try access.in(slots_value, intv(0)), intv(99)));
    try access.putIndex(slots_value, 0, intv(10));
    expect(harness.equals(try access.in(slots_value, intv(0)), intv(10)));
}

/// The second `%T` mask, and it is a different one: writing to a tuple is not a
/// bad key but an impossible operation, so the message names three types rather
/// than eight. Note the trailing space in the abstract message, which is the C
/// original's and is preserved.
fn putOnANonWritablePanics() void {
    const t = tuples.begin(1);
    t[0] = intv(0);
    const tup = wrap.fromTuple(tuples.end(t));
    const st = wrap.fromStruct(structs.end(structs.begin(0)));

    expect(refusal(access.put, .{ tup, intv(0), intv(1) })
        .beginsWith("expected array, table or buffer, got <tuple "));
    expect(refusal(access.putIndex, .{ st, 0, intv(1) })
        .beginsWith("expected array, table or buffer, got <struct "));
    expect(refusal(access.put, .{ value.fromBytes("ab", .string), intv(0), intv(1) })
        .says("expected array, table or buffer, got \"ab\""));
    expect(refusal(access.putIndex, .{ intv(5), 0, intv(1) })
        .says("expected array, table or buffer, got 5"));
    expect(refusal(access.put, .{ wrap.fromNil(), intv(0), intv(1) })
        .says("expected array, table or buffer, got nil"));
    expect(refusal(access.put, .{ bare_value, intv(0), intv(1) })
        .beginsWith("no setter for <value-access/bare "));
    expect(refusal(access.putIndex, .{ bare_value, 0, intv(1) })
        .beginsWith("no setter for <value-access/bare "));
}

// ------------------------------------------------------- from Janet source

fn fromJanet() void {
    const out = run_(
        "[(do (var n 0) (each x @{:a 1 :b 2 :c 3} (+= n x)) n) " ++
            " (do (var n 0) (eachk k [:a :b :c] (+= n k)) n) " ++
            " (length \"abc\") " ++
            " (length @{:a 1}) " ++
            " (in [10 20 30] 1) " ++
            " (get [10 20 30] 9) " ++
            " (get \"abc\" :x) " ++
            " (protect (in [10 20 30] 9)) " ++
            " (do (def a @[1]) (put a 3 :x) a) " ++
            " (do (def b @\"A\") (put b 3 66) b) " ++
            " (keys @{:a 1 :b 2}) " ++
            " (values {:a 1}) " ++
            " (do (def s (table/setproto @{:own 1} @{:up 2})) [(in s :up) (keys s)])]",
    );
    const v = wrap.toTuple(out);
    expect(wrap.toInteger(v[0]) == 6);
    expect(wrap.toInteger(v[1]) == 3);
    expect(wrap.toInteger(v[2]) == 3);
    expect(wrap.toInteger(v[3]) == 1);
    expect(wrap.toInteger(v[4]) == 20);
    expect(isNil(v[5]));
    expect(isNil(v[6]));
    {
        const p = wrap.toTuple(v[7]);
        expect(!repr.truthy(p[0]));
        expect(harness.equals(p[1], value.fromBytes("expected integer key for tuple in range [0, 3), got 9", .string)));
    }
    {
        const a = wrap.toArray(v[8]);
        expect(a.count == 4);
        expect(wrap.toInteger(a.slice()[0]) == 1);
        expect(isNil(a.slice()[1]) and isNil(a.slice()[2]));
        expect(harness.equals(a.slice()[3], kw("x")));
    }
    {
        const b = wrap.toBuffer(v[9]);
        expect(b.count == 4);
        expect(b.slice()[0] == 'A' and b.slice()[1] == 0 and b.slice()[2] == 0 and b.slice()[3] == 66);
    }
    expect(wrap.toArray(v[10]).count == 2);
    expect(wrap.toArray(v[11]).count == 1);
    {
        const pair = wrap.toTuple(v[12]);
        // The prototype's key reads through `in` and does not appear in `keys`,
        // which walks with `next`.
        expect(wrap.toInteger(pair[0]) == 2);
        expect(wrap.toArray(pair[1]).count == 1);
    }
}

// ------------------------------------------------------------------- main

/// The body, so that a raise on a *success* path ends the run with a named
/// panic rather than being caught and reported. `test/harness.zig`'s header has
/// the argument: a contract that expects a call to succeed needs no scope, and
/// opening one would replace the runtime's own message -- which names the panic
/// -- with a less informative assertion.
fn body() !void {
    makeAbstracts();
    registry.cfuns(harness.coreEnv(), null, &cfuns);

    try nextVisitsEveryTableKeyOnce();
    try nextStepsOverTombstones();
    try nextVisitsEveryStructKeyOnce();
    try nextDoesNotFollowAStructPrototype();
    try nextDoesNotFollowATablePrototype();
    try nextOverEmptyDictionaries();

    try nextOverEachSequenceType();
    try nextStopsRatherThanPanickingOnABadKey();
    try nextFromANegativeKey();
    try nextPastTheEnd();

    try nextOnAnAbstract();
    nextOnANonIterablePanics();

    nextResumesAFiber();
    theNextEntryPointOnAFiber();
    try theNextEntryPointOutsideAnyFiber();
    nextOnAnUnresumableFiber();
    theInterpreterFlagChoosesTheErrorPolicy();
    theChildSlotIsCleared();
    theResumedFiberJoinsTheLineage();

    try inReadsEveryContainer();
    try inOnAMissingDictionaryKeyIsNil();
    inPanicsOnABadKey();
    inOnANonLengthablePanics();
    try inOnAnAbstract();
    inOnAFiber();

    try getAnswersNilWhereInPanics();
    try getAgreesWithInWhereBothSucceed();

    try theGetIndexPolicies();
    try getIndexOnAFiber();

    try theLengthOfEveryContainer();
    try theLengthOfATableIgnoresTombstones();
    try theAbstractLengthCallback();
    try theTwoLengthBoundsAreDifferent();
    try theLengthFallsBackToAMethod();
    theLengthOfANonLengthablePanics();

    try putGrowsAnArrayWithNils();
    try putIndexAppendsAtTheCount();
    try putIndexGrowsABufferWithZeroes();
    try aBufferTruncatesToAByte();
    putChecksTheKeyBeforeTheValue();
    aRejectedBufferWriteDoesNotGrowIt();
    putBoundsTheIndex();
    try putOnATableAndAnAbstract();
    putOnANonWritablePanics();

    fromJanet();
}

pub fn run() void {
    harness.init();
    body() catch @panic("value_access: an accessor raised unexpectedly");
    vm_lifecycle.deinit();

    std.debug.print("value access contract ok\n", .{});
}
