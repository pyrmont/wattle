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
//! it decides whether `janet_vm.fiber.child` is cleared first. No in-tree
//! caller passes zero -- the VM always passes one -- so the whole `next` entry
//! point is reachable only from outside, and it is tested here through a
//! cfunction registered for the purpose.
//!
//! ## What the migration changed, and what it did not
//!
//! The C original counted its panics: forty-nine `EXPECT_PANIC`s and an
//! assertion at the foot that all forty-nine had fired, because each was a
//! twenty-line macro -- open a scope, arm the flag, call the face, read the
//! flag, read the signal, restore, compare the payload -- and with a macro that
//! big it is worth proving every one ran. Here a refusal is a value and each is
//! one line, so a refusal that stops happening fails at the call that expected
//! it rather than in a count at the end. That is a better failure and not
//! merely a shorter one; the tally is gone.
//!
//! The abstract fixtures need no adapter either. Five of the callbacks used
//! here -- `get`, `put`, `next`, `length` and the two methods -- are raising in
//! `abstract_type.zig`, which is exactly why C could not define them and needed
//! `test/support.zig`'s pool. In Zig they are ordinary functions that return
//! `raise.Error!T`.
//!
//! What is deliberately not covered: three undefined-behaviour edges.
//! `(next "abc" 2147483647)` and `putIndex` at `INT32_MAX` are signed overflow,
//! and `next` on a fiber from outside a running fiber is a null dereference.
//! All three are in `FOUND.md`.

const std = @import("std");
const abi = @import("abi");
const c = abi.c;
const raise = @import("raise");
const corefn = @import("corefn");
const harness = @import("harness.zig");

const subsystems = @import("subsystems");
const va = subsystems.value_access;
const args_core = subsystems.args_core;
const abstract_type = subsystems.abstract_type;
const AbstractType = abstract_type.AbstractType;
const assert = std.debug.assert;

// ----------------------------------------------------------------- helpers

fn kw(name: [*:0]const u8) c.Janet {
    return c.janet_ckeywordv(name);
}

fn intv(i: i32) c.Janet {
    return harness.wrapInteger(i);
}

fn isNil(x: c.Janet) bool {
    return harness.isType(x, c.JANET_NIL);
}

/// The refusal a call made, which every panic case here reads. Named rather
/// than spelled at each site so that the `.?` -- "it must have refused" -- is
/// in one place.
fn refusal(function: anytype, args: anytype) harness.Raise {
    return harness.raised(function, args).?;
}

fn returns(function: anytype, args: anytype) void {
    assert(harness.raised(function, args) == null);
}

// ------------------------------------------------------- abstract fixtures

/// Three integer slots, addressed by integer keys, with every callback the
/// accessors reach. `next` walks 0, 1, 2 and stops.
const Slots = extern struct {
    slot: [3]i32,
};

fn slotsGet(p: ?*anyopaque, key: c.Janet, out: [*c]c.Janet) raise.Error!c_int {
    const s: *Slots = @ptrCast(@alignCast(p));
    if (c.janet_checkint(key) == 0) return 0;
    const i = c.janet_unwrap_integer(key);
    if (i < 0 or i > 2) return 0;
    out.* = harness.wrapInteger(s.slot[@intCast(i)]);
    return 1;
}

fn slotsPut(p: ?*anyopaque, key: c.Janet, value: c.Janet) raise.Error!void {
    const s: *Slots = @ptrCast(@alignCast(p));
    if (c.janet_checkint(key) == 0) return raise.panic("slots: bad key");
    const i = c.janet_unwrap_integer(key);
    if (i < 0 or i > 2) return raise.panic("slots: key out of range");
    s.slot[@intCast(i)] = c.janet_unwrap_integer(value);
}

fn slotsNext(p: ?*anyopaque, key: c.Janet) raise.Error!c.Janet {
    _ = p;
    if (harness.isType(key, c.JANET_NIL)) return harness.wrapInteger(0);
    const i = c.janet_unwrap_integer(key) + 1;
    return if (i < 3) harness.wrapInteger(i) else c.janet_wrap_nil();
}

fn slotsLength(p: ?*anyopaque, len: usize) raise.Error!usize {
    _ = p;
    _ = len;
    return 3;
}

const at_slots: AbstractType = .{
    .name = "value-access/slots",
    .get = &slotsGet,
    .put = &slotsPut,
    .next = &slotsNext,
    .length = &slotsLength,
};

/// No callbacks at all: the type every "no getter", "no setter" and "no next"
/// arm is written for.
const at_bare: AbstractType = .{ .name = "value-access/bare" };

/// Two lengths chosen to straddle the two different bounds.
fn bigLength(p: ?*anyopaque, len: usize) raise.Error!usize {
    _ = p;
    _ = len;
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
/// which is how this was found -- rule 8's "skip rather than fake", arriving
/// from the compiler instead of from a reading.
const intmax_int64_fits_in_a_length = std.math.maxInt(usize) >= 9007199254740992;

fn hugeLength(p: ?*anyopaque, len: usize) raise.Error!usize {
    _ = p;
    _ = len;
    return 9007199254740992; // JANET_INTMAX_INT64
}

const at_big: AbstractType = .{ .name = "value-access/big", .length = &bigLength };
const at_huge: AbstractType = .{
    .name = "value-access/huge",
    .length = if (intmax_int64_fits_in_a_length) &hugeLength else null,
};

/// A type with no `length` callback but a `:length` method, which is the other
/// half of `length`'s abstract arm. The method is found through `getImpl` --
/// one of the functions under test -- so this arm re-enters the file it is
/// testing.
fn methodSeven(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    _ = argc;
    _ = argv;
    return harness.wrapInteger(7);
}

fn methodKeyword(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    _ = argc;
    _ = argv;
    return c.janet_ckeywordv("not-a-number");
}

fn goodMethodGet(p: ?*anyopaque, key: c.Janet, out: [*c]c.Janet) raise.Error!c_int {
    _ = p;
    if (c.janet_keyeq(key, "length") == 0) return 0;
    out.* = c.janet_wrap_cfunction(raise.stored(&methodSeven));
    return 1;
}

fn badMethodGet(p: ?*anyopaque, key: c.Janet, out: [*c]c.Janet) raise.Error!c_int {
    _ = p;
    if (c.janet_keyeq(key, "length") == 0) return 0;
    out.* = c.janet_wrap_cfunction(raise.stored(&methodKeyword));
    return 1;
}

const at_good_method: AbstractType = .{
    .name = "value-access/good-method",
    .get = &goodMethodGet,
};

const at_bad_method: AbstractType = .{
    .name = "value-access/bad-method",
    .get = &badMethodGet,
};

var slots_value: c.Janet = undefined;
var bare_value: c.Janet = undefined;
var big_value: c.Janet = undefined;
var huge_value: c.Janet = undefined;
var good_method_value: c.Janet = undefined;
var bad_method_value: c.Janet = undefined;

fn typeOf(at: *const AbstractType) [*c]const c.JanetAbstractType {
    return abstract_type.stored(at);
}

fn makeAbstracts() void {
    const s: *Slots = @ptrCast(@alignCast(c.janet_abstract(typeOf(&at_slots), @sizeOf(Slots))));
    s.slot = .{ 10, 11, 12 };
    slots_value = c.janet_wrap_abstract(s);
    bare_value = c.janet_wrap_abstract(c.janet_abstract(typeOf(&at_bare), 8));
    big_value = c.janet_wrap_abstract(c.janet_abstract(typeOf(&at_big), 8));
    huge_value = c.janet_wrap_abstract(c.janet_abstract(typeOf(&at_huge), 8));
    good_method_value = c.janet_wrap_abstract(c.janet_abstract(typeOf(&at_good_method), 8));
    bad_method_value = c.janet_wrap_abstract(c.janet_abstract(typeOf(&at_bad_method), 8));
    c.janet_gcroot(slots_value);
    c.janet_gcroot(bare_value);
    c.janet_gcroot(big_value);
    c.janet_gcroot(huge_value);
    c.janet_gcroot(good_method_value);
    c.janet_gcroot(bad_method_value);
}

fn aCFunctionValue() c.Janet {
    return c.janet_wrap_cfunction(raise.stored(&methodSeven));
}

// ------------------------------------------------------------ next: tables

/// The property that matters is completeness, not the order: starting from nil
/// and following `next` has to visit every key exactly once and then stop. A
/// bucket walk that skipped an occupied slot, or that restarted, would still
/// return plausible keys.
fn nextVisitsEveryTableKeyOnce() !void {
    const t = c.janet_table(0);
    const n = 64;
    for (0..n) |i| c.janet_table_put(t, intv(@intCast(i)), intv(@intCast(i * 100)));

    var seen = [_]bool{false} ** n;
    var count: usize = 0;
    var k = try va.next(c.janet_wrap_table(t), c.janet_wrap_nil());
    while (!isNil(k)) : (k = try va.next(c.janet_wrap_table(t), k)) {
        assert(c.janet_checkint(k) != 0);
        const i = c.janet_unwrap_integer(k);
        assert(i >= 0 and i < n);
        assert(!seen[@intCast(i)]); // a key was visited twice
        seen[@intCast(i)] = true;
        count += 1;
        assert(count <= n);
    }
    assert(count == n);
}

/// Removing a key leaves a tombstone -- a bucket whose key is nil and whose
/// value is not -- and the walk has to step over it like any other empty bucket
/// rather than stopping at it.
fn nextStepsOverTombstones() !void {
    const t = c.janet_table(0);
    for (0..16) |i| c.janet_table_put(t, intv(@intCast(i)), intv(@intCast(i)));
    var i: i32 = 0;
    while (i < 16) : (i += 2) _ = c.janet_table_remove(t, intv(i));

    var count: usize = 0;
    var k = try va.next(c.janet_wrap_table(t), c.janet_wrap_nil());
    while (!isNil(k)) : (k = try va.next(c.janet_wrap_table(t), k)) {
        assert(@rem(c.janet_unwrap_integer(k), 2) == 1);
        count += 1;
        assert(count <= 8);
    }
    assert(count == 8);
}

fn nextVisitsEveryStructKeyOnce() !void {
    const st = c.janet_struct_begin(20);
    for (0..20) |i| c.janet_struct_put(st, intv(@intCast(i)), intv(@intCast(i)));
    const s = c.janet_wrap_struct(c.janet_struct_end(st));

    var seen = [_]bool{false} ** 20;
    var count: usize = 0;
    var k = try va.next(s, c.janet_wrap_nil());
    while (!isNil(k)) : (k = try va.next(s, k)) {
        const i = c.janet_unwrap_integer(k);
        assert(i >= 0 and i < 20);
        assert(!seen[@intCast(i)]);
        seen[@intCast(i)] = true;
        count += 1;
        assert(count <= 20);
    }
    assert(count == 20);
}

/// Iteration reads the bucket array and nothing else, so a prototype's keys are
/// not visited even though `in` finds them. The two disagree, and that is
/// established behaviour rather than an accident: `(each k s ...)` over a struct
/// with a prototype sees only the struct's own keys.
fn nextDoesNotFollowAStructPrototype() !void {
    const pst = c.janet_struct_begin(1);
    c.janet_struct_put(pst, kw("inherited"), intv(1));
    const proto = c.janet_struct_end(pst);

    const st = c.janet_struct_begin(1);
    c.janet_struct_put(st, kw("own"), intv(2));
    c.janet_struct_head(st).*.proto = proto;
    const s = c.janet_wrap_struct(c.janet_struct_end(st));

    const k = try va.next(s, c.janet_wrap_nil());
    assert(harness.equals(k, kw("own")));
    assert(isNil(try va.next(s, k)));

    // ...but the key is reachable through every accessor.
    assert(harness.equals(try va.in(s, kw("inherited")), intv(1)));
    assert(harness.equals(try va.getImpl(s, kw("inherited")), intv(1)));
}

/// A table's prototype behaves the same way, and for the same reason.
fn nextDoesNotFollowATablePrototype() !void {
    const proto = c.janet_table(0);
    c.janet_table_put(proto, kw("inherited"), intv(1));
    const t = c.janet_table(0);
    c.janet_table_put(t, kw("own"), intv(2));
    t.*.proto = proto;

    const k = try va.next(c.janet_wrap_table(t), c.janet_wrap_nil());
    assert(harness.equals(k, kw("own")));
    assert(isNil(try va.next(c.janet_wrap_table(t), k)));
    assert(harness.equals(try va.in(c.janet_wrap_table(t), kw("inherited")), intv(1)));
}

/// An empty dictionary answers nil to the first step rather than walking off the
/// end of a zero-length bucket array.
fn nextOverEmptyDictionaries() !void {
    assert(isNil(try va.next(c.janet_wrap_table(c.janet_table(0)), c.janet_wrap_nil())));
    const empty = c.janet_wrap_struct(c.janet_struct_end(c.janet_struct_begin(0)));
    assert(isNil(try va.next(empty, c.janet_wrap_nil())));
}

// -------------------------------------------------------- next: sequences

fn nextOverEachSequenceType() !void {
    const b = c.janet_buffer(4);
    c.janet_buffer_push_cstring(b, "abc");
    const a = c.janet_array(4);
    for (0..3) |i| c.janet_array_push(a, intv(@intCast(i)));
    const t = c.janet_tuple_begin(3);
    for (0..3) |i| t[i] = intv(@intCast(i));

    const seqs = [_]c.Janet{
        c.janet_cstringv("abc"),
        c.janet_csymbolv("abc"),
        kw("abc"),
        c.janet_wrap_buffer(b),
        c.janet_wrap_array(a),
        c.janet_wrap_tuple(c.janet_tuple_end(t)),
    };

    for (seqs) |seq| {
        var k = try va.next(seq, c.janet_wrap_nil());
        assert(harness.equals(k, intv(0)));
        k = try va.next(seq, k);
        assert(harness.equals(k, intv(1)));
        k = try va.next(seq, k);
        assert(harness.equals(k, intv(2)));
        assert(isNil(try va.next(seq, k)));
    }
}

/// A key that is not an integer is not an error here: iteration simply stops.
/// That is the opposite of what `in` does with the same key on the same value,
/// which is what makes it worth pinning.
fn nextStopsRatherThanPanickingOnABadKey() !void {
    const s = c.janet_cstringv("abc");
    assert(isNil(try va.next(s, kw("x"))));
    assert(isNil(try va.next(s, c.janet_wrap_number(1.5))));
    assert(isNil(try va.next(s, c.janet_wrap_true())));
    assert(refusal(va.in, .{ s, kw("x") })
        .says("expected integer key for string in range [0, 3), got :x"));
}

/// A negative key advances to a still-negative index, which the range test
/// rejects. Both halves of that test are load-bearing: `i < len` alone would
/// accept it.
fn nextFromANegativeKey() !void {
    const s = c.janet_cstringv("abc");
    assert(isNil(try va.next(s, intv(-5))));
    // -1 advances to 0, which is in range.
    assert(harness.equals(try va.next(s, intv(-1)), intv(0)));
}

fn nextPastTheEnd() !void {
    const s = c.janet_cstringv("abc");
    assert(isNil(try va.next(s, intv(2))));
    assert(isNil(try va.next(s, intv(99))));
    assert(isNil(try va.next(c.janet_cstringv(""), c.janet_wrap_nil())));
}

// --------------------------------------------------------- next: the rest

fn nextOnAnAbstract() !void {
    var k = try va.next(slots_value, c.janet_wrap_nil());
    assert(harness.equals(k, intv(0)));
    k = try va.next(slots_value, k);
    assert(harness.equals(k, intv(1)));
    k = try va.next(slots_value, k);
    assert(harness.equals(k, intv(2)));
    assert(isNil(try va.next(slots_value, k)));

    // No `next` callback is not an error, it is an empty iteration.
    assert(isNil(try va.next(bare_value, c.janet_wrap_nil())));
}

fn nextOnANonIterablePanics() void {
    assert(refusal(va.next, .{ intv(5), c.janet_wrap_nil() })
        .says("expected iterable type, got 5"));
    assert(refusal(va.next, .{ c.janet_wrap_nil(), c.janet_wrap_nil() })
        .says("expected iterable type, got nil"));
    assert(refusal(va.next, .{ c.janet_wrap_true(), c.janet_wrap_nil() })
        .says("expected iterable type, got true"));
    assert(refusal(va.next, .{ aCFunctionValue(), c.janet_wrap_nil() })
        .beginsWith("expected iterable type, got <cfunction "));
}

// ----------------------------------------------------------- next: fibers

// `next` writes `janet_vm.fiber.child` before resuming, so every fiber case has
// to run with a fiber on the VM. These cfunctions are how: they are called from
// Janet source, so `janet_vm.fiber` is the fiber running that source.
// `FOUND.md` has what happens without one.

fn cfunNext(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try args_core.fixarity(argc, 2);
    return va.next(argv[0], argv[1]);
}

/// Resume through `next` and report whether the caller's `child` slot was put
/// back to null afterwards. A slot left set keeps the child fiber reachable and
/// misreports the fiber chain, and nothing else observes it.
fn cfunNextChildCleared(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try args_core.fixarity(argc, 2);
    const self = c.janet_vm.fiber;
    _ = try va.next(argv[0], argv[1]);
    return c.janet_wrap_boolean(@intFromBool(self.*.child == null));
}

/// The same, for the path that leaves through a panic. The runtime clears the
/// slot before panicking there and deliberately does not on the interpreter's
/// path, which is the one asymmetry in the function.
fn cfunNextChildClearedOnPanic(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try args_core.fixarity(argc, 2);
    const self = c.janet_vm.fiber;
    if (harness.raised(va.next, .{ argv[0], argv[1] }) == null) {
        return c.janet_wrap_nil(); // did not panic; the caller asserts
    }
    return c.janet_wrap_boolean(@intFromBool(self.*.child == null));
}

const cfuns = [_]c.JanetReg{
    .{ .name = "va/next", .cfun = raise.stored(&cfunNext), .documentation = null },
    .{ .name = "va/next-child-cleared", .cfun = raise.stored(&cfunNextChildCleared), .documentation = null },
    .{ .name = "va/next-child-cleared-on-panic", .cfun = raise.stored(&cfunNextChildClearedOnPanic), .documentation = null },
    .{ .name = null, .cfun = null, .documentation = null },
};

fn run_(src: [*:0]const u8) c.Janet {
    var out: c.Janet = undefined;
    const status = c.janet_dostring(c.janet_core_env(null), src, "value_access", &out);
    if (status != 0) {
        std.debug.print("janet source failed: {s}\n", .{src});
        assert(false);
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
    const v = c.janet_unwrap_tuple(r);
    assert(harness.equals(v[0], intv(0)));
    assert(harness.equals(v[1], kw("a")));
    assert(harness.equals(v[2], intv(0)));
    assert(harness.equals(v[3], kw("b")));
    // The resume that finishes the fiber discards the return value and stops.
    assert(isNil(v[4]));
    assert(harness.equals(v[5], kw("dead")));
    // A dead fiber answers nil without being resumed.
    assert(isNil(v[6]));
}

/// `next` -- the entry point with `is_interpreter` clear -- has no in-tree
/// caller, so this is the only exercise it gets. It agrees with the
/// interpreter's path everywhere except on a signal.
fn theNextEntryPointOnAFiber() void {
    const r = run_("(def f (fiber/new (fn [] (yield :a) :done)))" ++
        "[(va/next f nil) (in f 0) (va/next f 0) (va/next f 0)]");
    const v = c.janet_unwrap_tuple(r);
    assert(harness.equals(v[0], intv(0)));
    assert(harness.equals(v[1], kw("a")));
    assert(isNil(v[2]));
    assert(isNil(v[3]));
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
    const v = c.janet_unwrap_tuple(r);
    assert(harness.equals(v[0], kw("dead")));
    assert(isNil(v[1]));
    assert(harness.equals(v[2], kw("error")));
    assert(isNil(v[3]));
    assert(harness.equals(v[4], kw("alive")));
    assert(isNil(v[5]));
    assert(harness.equals(v[6], kw("user3")));
    assert(isNil(v[7]));
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
    const v = c.janet_unwrap_tuple(r);
    assert(harness.equals(v[0], kw("sig")));
    assert(harness.equals(v[1], kw("user5")));
    assert(harness.equals(v[2], kw("sig")));
    assert(harness.equals(v[3], kw("error")));
}

fn theChildSlotIsCleared() void {
    const r = run_("(def ok (fiber/new (fn [] (yield :a) :done)))" ++
        "(def bad (fiber/new (fn [] (error :boom))))" ++
        "[(va/next-child-cleared ok nil)" ++
        " (va/next-child-cleared-on-panic bad nil)]");
    const v = c.janet_unwrap_tuple(r);
    assert(c.janet_truthy(v[0]) != 0); // child not cleared after a successful resume
    assert(harness.isType(v[1], c.JANET_BOOLEAN)); // the failing resume did not panic
    assert(c.janet_truthy(v[1]) != 0); // child not cleared before the panic
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
    const log = c.janet_unwrap_array(r);
    assert(log.*.count == 1);
    // the resumed fiber was not linked into the caller's chain
    assert(c.janet_unwrap_integer(log.*.data[0]) == 2);
}

// --------------------------------------------------------------- janet_in

fn inReadsEveryContainer() !void {
    const a = c.janet_array(2);
    c.janet_array_push(a, kw("x"));
    c.janet_array_push(a, kw("y"));
    assert(harness.equals(try va.in(c.janet_wrap_array(a), intv(1)), kw("y")));

    const t = c.janet_tuple_begin(2);
    t[0] = kw("x");
    t[1] = kw("y");
    const tup = c.janet_wrap_tuple(c.janet_tuple_end(t));
    assert(harness.equals(try va.in(tup, intv(0)), kw("x")));

    const b = c.janet_buffer(4);
    c.janet_buffer_push_cstring(b, "AB");
    assert(harness.equals(try va.in(c.janet_wrap_buffer(b), intv(1)), intv('B')));

    assert(harness.equals(try va.in(c.janet_cstringv("AB"), intv(0)), intv('A')));
    assert(harness.equals(try va.in(c.janet_csymbolv("AB"), intv(1)), intv('B')));
    assert(harness.equals(try va.in(kw("AB"), intv(0)), intv('A')));

    const tab = c.janet_table(0);
    c.janet_table_put(tab, kw("k"), intv(3));
    assert(harness.equals(try va.in(c.janet_wrap_table(tab), kw("k")), intv(3)));

    const st = c.janet_struct_begin(1);
    c.janet_struct_put(st, kw("k"), intv(4));
    assert(harness.equals(try va.in(c.janet_wrap_struct(c.janet_struct_end(st)), kw("k")), intv(4)));

    assert(harness.equals(try va.in(slots_value, intv(2)), intv(12)));
}

/// A key that is merely absent from a dictionary is nil, not an error. The panic
/// in `in` is about keys that are wrong for the container, and a dictionary
/// accepts every key.
fn inOnAMissingDictionaryKeyIsNil() !void {
    const tab = c.janet_table(0);
    assert(isNil(try va.in(c.janet_wrap_table(tab), kw("nope"))));
    const st = c.janet_wrap_struct(c.janet_struct_end(c.janet_struct_begin(0)));
    assert(isNil(try va.in(st, kw("nope"))));
    // Including keys no sequence would accept.
    assert(isNil(try va.in(c.janet_wrap_table(tab), c.janet_wrap_number(1.5))));
}

/// One message, four ways to earn it, and it names the container's type and the
/// exclusive upper bound. Every sequence type is checked because the type name
/// comes out of the type-name table and a wrong index there would still produce
/// a well-formed message.
fn inPanicsOnABadKey() void {
    const a = c.janet_array(1);
    c.janet_array_push(a, intv(0));
    const arr = c.janet_wrap_array(a);
    assert(refusal(va.in, .{ arr, kw("x") })
        .says("expected integer key for array in range [0, 1), got :x"));
    assert(refusal(va.in, .{ arr, intv(1) })
        .says("expected integer key for array in range [0, 1), got 1"));
    assert(refusal(va.in, .{ arr, intv(-1) })
        .says("expected integer key for array in range [0, 1), got -1"));
    assert(refusal(va.in, .{ arr, c.janet_wrap_number(0.5) })
        .says("expected integer key for array in range [0, 1), got 0.5"));

    const t = c.janet_tuple_begin(1);
    t[0] = intv(0);
    assert(refusal(va.in, .{ c.janet_wrap_tuple(c.janet_tuple_end(t)), intv(3) })
        .says("expected integer key for tuple in range [0, 1), got 3"));
    assert(refusal(va.in, .{ c.janet_wrap_buffer(c.janet_buffer(4)), intv(0) })
        .says("expected integer key for buffer in range [0, 0), got 0"));
    assert(refusal(va.in, .{ c.janet_cstringv("abc"), intv(9) })
        .says("expected integer key for string in range [0, 3), got 9"));
    assert(refusal(va.in, .{ c.janet_csymbolv("abc"), intv(9) })
        .says("expected integer key for symbol in range [0, 3), got 9"));
    assert(refusal(va.in, .{ kw("abc"), intv(9) })
        .says("expected integer key for keyword in range [0, 3), got 9"));
}

const not_lengthable = "expected string, symbol, keyword, array, tuple, " ++
    "table, struct or buffer, got ";

/// The `%T` message, which renders a type-flag mask rather than a value. Two
/// different masks appear in this file and they have to stay different.
fn inOnANonLengthablePanics() void {
    assert(refusal(va.in, .{ intv(5), intv(0) }).says(not_lengthable ++ "5"));
    assert(refusal(va.in, .{ c.janet_wrap_nil(), intv(0) }).says(not_lengthable ++ "nil"));
    assert(refusal(va.in, .{ c.janet_wrap_true(), intv(0) }).says(not_lengthable ++ "true"));
    assert(refusal(va.in, .{ aCFunctionValue(), intv(0) }).beginsWith(not_lengthable));
}

/// An abstract type is the one place where a key that is simply absent is an
/// error, because its `get` reports presence separately from the value.
fn inOnAnAbstract() !void {
    assert(harness.equals(try va.in(slots_value, intv(0)), intv(10)));
    assert(refusal(va.in, .{ slots_value, intv(7) })
        .beginsWith("key 7 not found in <value-access/slots "));
    assert(refusal(va.in, .{ slots_value, kw("nope") })
        .beginsWith("key :nope not found in <value-access/slots "));
    assert(refusal(va.in, .{ bare_value, intv(0) })
        .beginsWith("no getter for <value-access/bare "));
}

fn inOnAFiber() void {
    const r = run_("(def f (fiber/new (fn [] (yield :a) :done)))" ++
        "(next f nil)" ++
        "[(in f 0) (get f 0) (get f 1) (protect (in f 1))]");
    const v = c.janet_unwrap_tuple(r);
    assert(harness.equals(v[0], kw("a")));
    assert(harness.equals(v[1], kw("a")));
    assert(isNil(v[2]));
    // `protect` returns [false message] for a caught error.
    const p = c.janet_unwrap_tuple(v[3]);
    assert(c.janet_truthy(p[0]) == 0);
    assert(harness.equals(p[1], c.janet_cstringv("expected key 0, got 1")));
}

// -------------------------------------------------------------- janet_get

/// Everything `in` panics about, `getImpl` answers nil to -- including the
/// container type itself, which is why `getImpl` accepts a number as a data
/// structure and `in` does not.
fn getAnswersNilWhereInPanics() !void {
    const a = c.janet_array(1);
    c.janet_array_push(a, intv(0));
    const arr = c.janet_wrap_array(a);
    assert(isNil(try va.getImpl(arr, kw("x"))));
    assert(isNil(try va.getImpl(arr, intv(1))));
    assert(isNil(try va.getImpl(arr, intv(-1))));
    assert(isNil(try va.getImpl(arr, c.janet_wrap_number(0.5))));
    assert(isNil(try va.getImpl(c.janet_cstringv("abc"), intv(9))));
    // The string arm has its own negative-index case, separate from the one the
    // array, tuple and buffer arm shares, and both have to be there: an index
    // below zero is not "past the end" and the length test alone lets it
    // through.
    assert(isNil(try va.getImpl(c.janet_cstringv("abc"), intv(-1))));
    assert(isNil(try va.getImpl(c.janet_csymbolv("abc"), intv(-1))));
    assert(isNil(try va.getImpl(kw("abc"), intv(-1))));
    assert(isNil(try va.getImpl(
        c.janet_wrap_tuple(c.janet_tuple_end(c.janet_tuple_begin(0))),
        intv(-1),
    )));
    assert(isNil(try va.getImpl(c.janet_wrap_buffer(c.janet_buffer(4)), intv(0))));
    assert(isNil(try va.getImpl(intv(5), intv(0))));
    assert(isNil(try va.getImpl(c.janet_wrap_nil(), intv(0))));
    assert(isNil(try va.getImpl(c.janet_wrap_true(), kw("x"))));
    assert(isNil(try va.getImpl(bare_value, intv(0))));
    assert(isNil(try va.getImpl(slots_value, intv(7))));
    assert(isNil(try va.getImpl(aCFunctionValue(), intv(0))));
}

/// ...and where both succeed they agree.
fn getAgreesWithInWhereBothSucceed() !void {
    const a = c.janet_array(2);
    c.janet_array_push(a, kw("x"));
    c.janet_array_push(a, kw("y"));
    const t = c.janet_tuple_begin(1);
    t[0] = kw("t");
    const b = c.janet_buffer(4);
    c.janet_buffer_push_cstring(b, "AB");
    const tab = c.janet_table(0);
    c.janet_table_put(tab, kw("k"), intv(3));
    const st = c.janet_struct_begin(1);
    c.janet_struct_put(st, kw("k"), intv(4));

    const pairs = [_][2]c.Janet{
        .{ c.janet_wrap_array(a), intv(1) },
        .{ c.janet_wrap_tuple(c.janet_tuple_end(t)), intv(0) },
        .{ c.janet_wrap_buffer(b), intv(1) },
        .{ c.janet_cstringv("AB"), intv(0) },
        .{ c.janet_wrap_table(tab), kw("k") },
        .{ c.janet_wrap_struct(c.janet_struct_end(st)), kw("k") },
        .{ slots_value, intv(2) },
    };
    for (pairs) |pair| {
        assert(harness.equals(try va.in(pair[0], pair[1]), try va.getImpl(pair[0], pair[1])));
    }
}

// --------------------------------------------------------- janet_getindex

/// The third policy: a negative index and a missing getter panic, and every
/// other failure is nil. The abstract arm is where it parts company with `in` --
/// a `get` that runs and reports absence is an error there and a nil here.
fn theGetIndexPolicies() !void {
    const a = c.janet_array(1);
    c.janet_array_push(a, kw("x"));
    const arr = c.janet_wrap_array(a);
    assert(harness.equals(try va.getIndex(arr, 0), kw("x")));
    assert(isNil(try va.getIndex(arr, 5)));
    assert(refusal(va.getIndex, .{ arr, -1 }).says("expected non-negative index"));
    assert(refusal(va.getIndex, .{ c.janet_wrap_nil(), -1 }).says("expected non-negative index"));

    assert(isNil(try va.getIndex(c.janet_cstringv("ab"), 9)));
    assert(harness.equals(try va.getIndex(c.janet_cstringv("ab"), 1), intv('b')));
    assert(isNil(try va.getIndex(c.janet_wrap_buffer(c.janet_buffer(4)), 0)));

    const t = c.janet_tuple_begin(1);
    t[0] = kw("t");
    const tup = c.janet_wrap_tuple(c.janet_tuple_end(t));
    assert(harness.equals(try va.getIndex(tup, 0), kw("t")));
    assert(isNil(try va.getIndex(tup, 1)));

    // Dictionaries are keyed by the integer, so an out-of-range index is a
    // missing key rather than an out-of-range one.
    const tab = c.janet_table(0);
    c.janet_table_put(tab, intv(7), kw("seven"));
    assert(harness.equals(try va.getIndex(c.janet_wrap_table(tab), 7), kw("seven")));
    assert(isNil(try va.getIndex(c.janet_wrap_table(tab), 0)));

    const st = c.janet_struct_begin(1);
    c.janet_struct_put(st, intv(7), kw("seven"));
    const s = c.janet_wrap_struct(c.janet_struct_end(st));
    assert(harness.equals(try va.getIndex(s, 7), kw("seven")));
    assert(isNil(try va.getIndex(s, 0)));

    // The disagreement with `in`, stated directly.
    assert(isNil(try va.getIndex(slots_value, 7)));
    assert(refusal(va.in, .{ slots_value, intv(7) }).beginsWith("key 7 not found in "));
    assert(refusal(va.getIndex, .{ bare_value, 0 })
        .beginsWith("no getter for <value-access/bare "));
    assert(refusal(va.getIndex, .{ intv(5), 0 }).says(not_lengthable ++ "5"));
}

fn getIndexOnAFiber() !void {
    const r = run_("(def f (fiber/new (fn [] (yield :a) :done)))" ++
        "(next f nil) f");
    assert(harness.equals(try va.getIndex(r, 0), kw("a")));
    assert(isNil(try va.getIndex(r, 1)));
}

// ---------------------------------------------------------------- lengths

fn theLengthOfEveryContainer() !void {
    const a = c.janet_array(3);
    for (0..3) |i| c.janet_array_push(a, intv(@intCast(i)));
    const b = c.janet_buffer(4);
    c.janet_buffer_push_cstring(b, "abcd");
    const t = c.janet_tuple_begin(2);
    t[0] = c.janet_wrap_nil();
    t[1] = c.janet_wrap_nil();
    const tab = c.janet_table(0);
    c.janet_table_put(tab, kw("a"), intv(1));
    c.janet_table_put(tab, kw("b"), intv(2));
    const st = c.janet_struct_begin(1);
    c.janet_struct_put(st, kw("a"), intv(1));

    const cases = [_]struct { value: c.Janet, length: i32 }{
        .{ .value = c.janet_cstringv("abc"), .length = 3 },
        .{ .value = c.janet_csymbolv("abcd"), .length = 4 },
        .{ .value = kw("ab"), .length = 2 },
        .{ .value = c.janet_wrap_array(a), .length = 3 },
        .{ .value = c.janet_wrap_buffer(b), .length = 4 },
        .{ .value = c.janet_wrap_tuple(c.janet_tuple_end(t)), .length = 2 },
        .{ .value = c.janet_wrap_table(tab), .length = 2 },
        .{ .value = c.janet_wrap_struct(c.janet_struct_end(st)), .length = 1 },
    };
    for (cases) |case| {
        assert(try va.length(case.value) == case.length);
        assert(harness.equals(try va.lengthv(case.value), intv(case.length)));
    }

    // A struct's length is its pair count, not its bucket count.
    const wide = c.janet_struct_begin(9);
    for (0..9) |i| c.janet_struct_put(wide, intv(@intCast(i)), intv(@intCast(i)));
    const w = c.janet_wrap_struct(c.janet_struct_end(wide));
    assert(try va.length(w) == 9);
    assert(c.janet_struct_head(c.janet_unwrap_struct(w)).*.capacity > 9);
}

/// A table's length is its live count, so removing a key shortens it even though
/// the tombstone stays in the bucket array.
fn theLengthOfATableIgnoresTombstones() !void {
    const tab = c.janet_table(0);
    for (0..8) |i| c.janet_table_put(tab, intv(@intCast(i)), intv(@intCast(i)));
    assert(try va.length(c.janet_wrap_table(tab)) == 8);
    _ = c.janet_table_remove(tab, intv(0));
    assert(try va.length(c.janet_wrap_table(tab)) == 7);
    assert(tab.*.deleted == 1);
}

fn theAbstractLengthCallback() !void {
    assert(try va.length(slots_value) == 3);
    assert(harness.equals(try va.lengthv(slots_value), c.janet_wrap_number(3.0)));
    // `lengthv` wraps a callback's length as a double rather than as an integer,
    // and the two are equal but not identically represented.
    assert(harness.isType(try va.lengthv(slots_value), c.JANET_NUMBER));
}

/// The band where the two functions disagree. `length` stops at `INT32_MAX`
/// because it returns an `int32_t`; `lengthv` stops at `JANET_INTMAX_INT64`
/// because it returns a double. A length between them panics one and satisfies
/// the other.
fn theTwoLengthBoundsAreDifferent() !void {
    assert(refusal(va.length, .{big_value}).says("invalid integer length 2147483648"));
    const lv = try va.lengthv(big_value);
    assert(harness.isType(lv, c.JANET_NUMBER));
    assert(c.janet_unwrap_number(lv) == 2147483648.0);

    if (intmax_int64_fits_in_a_length) {
        assert(refusal(va.length, .{huge_value}).says("invalid integer length 9007199254740992"));
        assert(refusal(va.lengthv, .{huge_value}).says("integer length 9007199254740992 too large"));
    }
}

/// Without a `length` callback the length comes from a `:length` method, which
/// is looked up through `getImpl` -- so this arm re-enters the file under test.
/// `length` checks the result and `lengthv` does not, which is the second place
/// the two disagree.
fn theLengthFallsBackToAMethod() !void {
    assert(try va.length(good_method_value) == 7);
    assert(harness.equals(try va.lengthv(good_method_value), intv(7)));

    assert(refusal(va.length, .{bad_method_value}).says("invalid integer length :not-a-number"));
    assert(harness.equals(try va.lengthv(bad_method_value), kw("not-a-number")));

    assert(refusal(va.length, .{bare_value})
        .beginsWith("could not find method :length for <value-access/bare "));
    assert(refusal(va.lengthv, .{bare_value})
        .beginsWith("could not find method :length for <value-access/bare "));
}

fn theLengthOfANonLengthablePanics() void {
    assert(refusal(va.length, .{intv(5)}).says(not_lengthable ++ "5"));
    assert(refusal(va.lengthv, .{intv(5)}).says(not_lengthable ++ "5"));
    assert(refusal(va.length, .{c.janet_wrap_nil()}).says(not_lengthable ++ "nil"));
    assert(refusal(va.lengthv, .{c.janet_wrap_nil()}).says(not_lengthable ++ "nil"));
}

// ---------------------------------------------------------------- setters

/// Writing past the end grows the container, and the two growable types fill the
/// gap differently: an array with nil, a buffer with zero.
fn putGrowsAnArrayWithNils() !void {
    const a = c.janet_array(0);
    c.janet_array_push(a, kw("first"));
    try va.put(c.janet_wrap_array(a), intv(4), kw("fifth"));
    assert(a.*.count == 5);
    assert(harness.equals(a.*.data[0], kw("first")));
    for (1..4) |i| assert(isNil(a.*.data[i]));
    assert(harness.equals(a.*.data[4], kw("fifth")));

    // An in-range write does not shorten it.
    try va.put(c.janet_wrap_array(a), intv(0), kw("again"));
    assert(a.*.count == 5);
    assert(harness.equals(a.*.data[0], kw("again")));
}

/// The growth test is `index >= count`, not `index > count`, so appending at
/// exactly the current count grows by one. An off-by-one there writes the value
/// into a slot the count does not cover, which is invisible rather than wrong.
fn putIndexAppendsAtTheCount() !void {
    const a = c.janet_array(8);
    c.janet_array_push(a, kw("a"));
    try va.putIndex(c.janet_wrap_array(a), 1, kw("b"));
    assert(a.*.count == 2);
    assert(harness.equals(a.*.data[1], kw("b")));

    const b = c.janet_buffer(8);
    c.janet_buffer_push_cstring(b, "A");
    try va.putIndex(c.janet_wrap_buffer(b), 1, intv('B'));
    assert(b.*.count == 2);
    assert(b.*.data[1] == 'B');
}

fn putIndexGrowsABufferWithZeroes() !void {
    const b = c.janet_buffer(0);
    c.janet_buffer_push_cstring(b, "A");
    try va.putIndex(c.janet_wrap_buffer(b), 4, intv('E'));
    assert(b.*.count == 5);
    assert(b.*.data[0] == 'A');
    for (1..4) |i| assert(b.*.data[i] == 0);
    assert(b.*.data[4] == 'E');

    try va.putIndex(c.janet_wrap_buffer(b), 0, intv('Z'));
    assert(b.*.count == 5);
    assert(b.*.data[0] == 'Z');
}

/// A buffer stores bytes, and the value is masked to eight bits after being
/// checked for integer-ness rather than being range-checked. So a value out of
/// byte range is stored truncated and does not complain.
fn aBufferTruncatesToAByte() !void {
    const b = c.janet_buffer(4);
    c.janet_buffer_push_bytes(b, "\x00\x00", 2);
    try va.put(c.janet_wrap_buffer(b), intv(0), intv(300));
    assert(b.*.data[0] == 44);
    try va.putIndex(c.janet_wrap_buffer(b), 1, intv(-1));
    assert(b.*.data[1] == 255);
    try va.put(c.janet_wrap_buffer(b), intv(0), intv(256));
    assert(b.*.data[0] == 0);
    // Eight bits, not seven: a value whose low byte has the high bit set
    // survives through both entry points.
    try va.put(c.janet_wrap_buffer(b), intv(0), intv(200));
    assert(b.*.data[0] == 200);
    try va.putIndex(c.janet_wrap_buffer(b), 1, intv(200));
    assert(b.*.data[1] == 200);
}

/// `put` checks the key before the value and `putIndex` has no key to check, so
/// the same two bad arguments produce different messages depending on which
/// function is asked.
fn putChecksTheKeyBeforeTheValue() void {
    const b = c.janet_buffer(4);
    c.janet_buffer_push_cstring(b, "AB");
    assert(refusal(va.put, .{ c.janet_wrap_buffer(b), kw("x"), kw("y") })
        .says("expected integer key for buffer in range [0, 2147483646), got :x"));
    assert(refusal(va.put, .{ c.janet_wrap_buffer(b), intv(0), kw("y") })
        .says("can only put integers in buffers, got :y"));
    assert(refusal(va.putIndex, .{ c.janet_wrap_buffer(b), 0, kw("y") })
        .says("can only put integers in buffers, got :y"));
    // The rejected write left the buffer alone.
    assert(b.*.count == 2 and b.*.data[0] == 'A');
}

/// The value check comes before the growth, so a rejected write to a buffer does
/// not resize it -- which is not true of the key check on an array, where there
/// is nothing to reject after the bound.
fn aRejectedBufferWriteDoesNotGrowIt() void {
    const b = c.janet_buffer(0);
    assert(refusal(va.putIndex, .{ c.janet_wrap_buffer(b), 100, kw("y") })
        .says("can only put integers in buffers, got :y"));
    assert(b.*.count == 0);
}

/// `put` bounds its index at `INT32_MAX - 1`, which is the bound `putIndex` does
/// not have. `FOUND.md` has the other side.
fn putBoundsTheIndex() void {
    const a = c.janet_array(0);
    assert(refusal(va.put, .{ c.janet_wrap_array(a), intv(2147483647), intv(1) })
        .says("expected integer key for array in range [0, 2147483646), got 2147483647"));
    assert(refusal(va.put, .{ c.janet_wrap_array(a), intv(-1), intv(1) })
        .says("expected integer key for array in range [0, 2147483646), got -1"));
    assert(a.*.count == 0);
}

fn putOnATableAndAnAbstract() !void {
    const tab = c.janet_table(0);
    try va.put(c.janet_wrap_table(tab), kw("k"), intv(1));
    assert(harness.equals(try va.in(c.janet_wrap_table(tab), kw("k")), intv(1)));
    try va.putIndex(c.janet_wrap_table(tab), 3, intv(2));
    assert(harness.equals(try va.in(c.janet_wrap_table(tab), intv(3)), intv(2)));

    try va.put(slots_value, intv(0), intv(99));
    assert(harness.equals(try va.in(slots_value, intv(0)), intv(99)));
    try va.putIndex(slots_value, 0, intv(10));
    assert(harness.equals(try va.in(slots_value, intv(0)), intv(10)));
}

/// The second `%T` mask, and it is a different one: writing to a tuple is not a
/// bad key but an impossible operation, so the message names three types rather
/// than eight. Note the trailing space in the abstract message, which is the C
/// original's and is preserved.
fn putOnANonWritablePanics() void {
    const t = c.janet_tuple_begin(1);
    t[0] = intv(0);
    const tup = c.janet_wrap_tuple(c.janet_tuple_end(t));
    const st = c.janet_wrap_struct(c.janet_struct_end(c.janet_struct_begin(0)));

    assert(refusal(va.put, .{ tup, intv(0), intv(1) })
        .beginsWith("expected array, table or buffer, got <tuple "));
    assert(refusal(va.putIndex, .{ st, 0, intv(1) })
        .beginsWith("expected array, table or buffer, got <struct "));
    assert(refusal(va.put, .{ c.janet_cstringv("ab"), intv(0), intv(1) })
        .says("expected array, table or buffer, got \"ab\""));
    assert(refusal(va.putIndex, .{ intv(5), 0, intv(1) })
        .says("expected array, table or buffer, got 5"));
    assert(refusal(va.put, .{ c.janet_wrap_nil(), intv(0), intv(1) })
        .says("expected array, table or buffer, got nil"));
    assert(refusal(va.put, .{ bare_value, intv(0), intv(1) })
        .beginsWith("no setter for <value-access/bare "));
    assert(refusal(va.putIndex, .{ bare_value, 0, intv(1) })
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
    const v = c.janet_unwrap_tuple(out);
    assert(c.janet_unwrap_integer(v[0]) == 6);
    assert(c.janet_unwrap_integer(v[1]) == 3);
    assert(c.janet_unwrap_integer(v[2]) == 3);
    assert(c.janet_unwrap_integer(v[3]) == 1);
    assert(c.janet_unwrap_integer(v[4]) == 20);
    assert(isNil(v[5]));
    assert(isNil(v[6]));
    {
        const p = c.janet_unwrap_tuple(v[7]);
        assert(c.janet_truthy(p[0]) == 0);
        assert(harness.equals(p[1], c.janet_cstringv(
            "expected integer key for tuple in range [0, 3), got 9",
        )));
    }
    {
        const a = c.janet_unwrap_array(v[8]);
        assert(a.*.count == 4);
        assert(c.janet_unwrap_integer(a.*.data[0]) == 1);
        assert(isNil(a.*.data[1]) and isNil(a.*.data[2]));
        assert(harness.equals(a.*.data[3], kw("x")));
    }
    {
        const b = c.janet_unwrap_buffer(v[9]);
        assert(b.*.count == 4);
        assert(b.*.data[0] == 'A' and b.*.data[1] == 0 and b.*.data[2] == 0 and b.*.data[3] == 66);
    }
    assert(c.janet_unwrap_array(v[10]).*.count == 2);
    assert(c.janet_unwrap_array(v[11]).*.count == 1);
    {
        const pair = c.janet_unwrap_tuple(v[12]);
        // The prototype's key reads through `in` and does not appear in `keys`,
        // which walks with `next`.
        assert(c.janet_unwrap_integer(pair[0]) == 2);
        assert(c.janet_unwrap_array(pair[1]).*.count == 1);
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
    c.janet_cfuns(c.janet_core_env(null), null, &cfuns);

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
    _ = c.janet_init();
    body() catch @panic("value_access: an accessor raised unexpectedly");
    c.janet_deinit();

    std.debug.print("value access contract ok\n", .{});
}
