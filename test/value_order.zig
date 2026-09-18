//! Behavioral contract for hashing, equality and ordering over any Janet
//! value.
//!
//! These three functions are one contract rather than three, and the file is
//! organised that way. A hash table needs the hash and the equality to agree;
//! a struct's Robin Hood insert needs the comparison to totally order whatever
//! the hash collides. So the last section runs a
//! corpus of values that covers every `repr.Tag` through all three at once and
//! asserts the relations *between* them, rather than checking each function in
//! isolation and hoping.
//!
//! Two properties get more attention than their size suggests.
//!
//! The traversal is not recursion. `order.equals` and `order.compare` walk
//! nested tuples and structs with an explicit stack on the VM, because a
//! literal nested a few thousand deep is a value a parser will produce and a
//! native stack overflow is not a catchable error. A case that only compares
//! shallow values passes just as happily against a recursive implementation,
//! so the depth cases here use depths that would blow a native stack.
//!
//! The stack is scratch rather than state. Both entry points reset it on the
//! way in and neither pops what it pushed, so a comparison that returns early
//! leaves nodes behind. That is only correct if the next comparison is
//! unaffected, which is asserted directly rather than assumed.
//!
//! ## The abstract fixtures
//!
//! `abstract_type.define` takes Zig callbacks, so the three probe types below
//! are ordinary declarations and the table is the runtime's own
//! `AbstractType`. The two callbacks this file supplies are `compare` and
//! `hash`, typed non-raising for the reason `abstract_type.zig` gives: they
//! are called from inside comparisons that must be total, so there is nowhere
//! for a raise to go.

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
const arrays = @import("subsystems").value.arrays;
const buffers = @import("subsystems").value.buffers;
const core_env = @import("subsystems").env;
const expect = @import("expect.zig").expect;

const gc_alloc = @import("subsystems").gc_alloc;
const harness = @import("harness.zig");
const order = @import("subsystems").value.order;
const repr = @import("repr");
const maps = @import("subsystems").value.maps;
const tables = @import("subsystems").value.tables;
const tuples = @import("subsystems").value.tuples;
const utils = @import("subsystems").utils;
const value = @import("subsystems").value;
const vm_lifecycle = @import("subsystems").lifecycle;
const vm_state = @import("subsystems").vm_state;
const wrap = @import("subsystems").value.wrap;

// ==========================================================================
// Constants
// ==========================================================================

/// Supplies neither, so it falls back to pointer identity for both.
const at_bare = abstract_type.define(anyopaque, .{ .name = "value-order/bare" });

/// Supplies both callbacks.
const at_cell = abstract_type.define(Cell, .{
    .name = "value-order/cell",
    .compare = &cellCompare,
    .hash = &cellHash,
});

/// A second callback-less type, so that two abstracts of *different* types can
/// be ordered without either type's `compare` being consulted.
const at_other = abstract_type.define(anyopaque, .{ .name = "value-order/other" });

// ==========================================================================
// Types
// ==========================================================================

/// Three abstract types, differing only in which callbacks they supply, so that
/// each branch of the abstract arm of `order.compare` and of `order.hash` is
/// reached by a type that reaches no other.
const Cell = extern struct {
    key: i32,
};

// ==========================================================================
// Cases
// ==========================================================================

fn kw(name: [*:0]const u8) repr.Value {
    return value.fromBytes(std.mem.span(name), .keyword);
}

fn sym(name: [*:0]const u8) repr.Value {
    return value.fromBytes(std.mem.span(name), .symbol);
}

fn str(s: [*:0]const u8) repr.Value {
    return value.fromBytes(std.mem.span(s), .string);
}

fn num(d: f64) repr.Value {
    return wrap.fromNumber(d);
}

fn intv(i: i32) repr.Value {
    return harness.wrapInteger(i);
}

/// A tuple from a slice of values.
fn mktuple(items: []const repr.Value) repr.Value {
    const t = tuples.begin(@intCast(items.len));
    for (items, 0..) |item, i| t[i] = item;
    return wrap.fromTuple(tuples.end(t));
}

/// A map from alternating key/value pairs.
fn mkmap(kvs: []const repr.Value) repr.Value {
    return wrap.fromMap(maps.build(.map, kvs));
}

/// A map's payload, which the forging cases below write to.
fn mapOf(x: repr.Value) *maps.Tree {
    return @constCast(wrap.toMap(x));
}

fn tupleHash(t: tuples.Tuple) i32 {
    return utils.tupleHead(t).hash;
}

/// Depth of the traversal stack in nodes, as the two entry points see it. Zero
/// when nothing has ever been pushed, because the base slot is never used.
fn stackDepth() isize {
    if (harness.vm().traversal.base == null) return 0;
    return @divExact(
        @as(isize, @bitCast(@intFromPtr(harness.vm().traversal.at) -% @intFromPtr(harness.vm().traversal.base))),
        @sizeOf(order.TraversalNode),
    );
}

fn stackCapacity() isize {
    return @divExact(
        @as(isize, @bitCast(@intFromPtr(harness.vm().traversal.top) -% @intFromPtr(harness.vm().traversal.base))),
        @sizeOf(order.TraversalNode),
    );
}

fn cellHash(cell: *const Cell, _: usize) i32 {
    return cell.key;
}

fn cellCompare(lhs: *const Cell, rhs: *const Cell) i32 {
    if (lhs.key == rhs.key) return 0;
    return if (lhs.key < rhs.key) -1 else 1;
}

fn cellType() *const abi.AbstractType {
    return &at_cell;
}

fn bareType() *const abi.AbstractType {
    return &at_bare;
}

fn otherType() *const abi.AbstractType {
    return &at_other;
}

fn mkcell(key: i32) repr.Value {
    const cell: *Cell = @ptrCast(@alignCast(abstracts.newBytes(cellType(), @sizeOf(Cell))));
    cell.key = key;
    return wrap.fromAbstract(cell);
}

fn mkbare(at: *const abi.AbstractType) repr.Value {
    const cell: *Cell = abstracts.newFor(Cell, at);
    cell.key = 0;
    return wrap.fromAbstract(cell);
}

/// Build a tuple nested `depth` levels deep: `(0 (1 (2 ... leaf)))`.
///
/// Twenty thousand levels is megabytes of allocation and the collector will
/// run part way through, so the accumulator is rooted across every allocation
/// that could trigger one. A value reachable only from a Zig local is not
/// reachable to the collector, and each level here is kept alive by the level
/// above it alone, so losing the accumulator for the length of one
/// `tuples.begin` would free the whole chain built so far. The successor is
/// rooted before its predecessor is released, never the other way round.
///
/// The result is left rooted and the caller unroots it.
fn nestTuples(depth: i32, leaf: repr.Value) repr.Value {
    var acc = leaf;
    gc_alloc.gcroot(acc);
    var i: i32 = 0;
    while (i < depth) : (i += 1) {
        const items = [_]repr.Value{ intv(i), acc };
        const next = mktuple(&items);
        gc_alloc.gcroot(next);
        _ = gc_alloc.gcunroot(acc);
        acc = next;
    }
    return acc;
}

/// The constants, which nothing else pins. `order.hash` of nil is the identity
/// of an empty bucket in every dictionary in the runtime, and `false` hashes
/// to zero.
fn theHashOfTheAtoms() void {
    expect(order.hash(wrap.fromNil()) == 0);
    expect(order.hash(wrap.fromFalse()) == 0);
    expect(order.hash(wrap.fromTrue()) == 1);
}

/// Hashing is a function: the same value hashes the same every time, and two
/// separately built values that are `=` hash alike. The second half is the
/// property every dictionary in the runtime is built on.
fn theHashAgreesWithEquality() void {
    const items = [_]repr.Value{ intv(1), kw("a"), str("s") };
    const a = mktuple(&items);
    const b = mktuple(&items);
    expect(harness.equals(a, b));
    expect(order.hash(a) == order.hash(a));
    expect(order.hash(a) == order.hash(b));

    const kvs = [_]repr.Value{ kw("x"), intv(1), kw("y"), intv(2) };
    const rev = [_]repr.Value{ kw("y"), intv(2), kw("x"), intv(1) };
    const m1 = mkmap(&kvs);
    const m2 = mkmap(&rev);
    expect(harness.equals(m1, m2));
    expect(order.hash(m1) == order.hash(m2));
}

/// A symbol and a string hash their bytes and nothing else, so the two spelled
/// alike collide while comparing unequal. This is not an accident to be tidied
/// up: it is exactly the collision that makes the `order.compare` tiebreak in
/// a map's place-hash run load-bearing, and `test/maps.zig` has the other half
/// of the story. A keyword shares a tag with a symbol, so its hash is mixed to
/// keep it from colliding with the symbol of the same name.
fn theStringLikesShareOneHash() void {
    expect(order.hash(sym("tie")) == order.hash(str("tie")));
    expect(order.hash(kw("tie")) != order.hash(sym("tie")));
    expect(!harness.equals(kw("tie"), str("tie")));
    expect(!harness.equals(sym("tie"), str("tie")));
    expect(!harness.equals(kw("tie"), sym("tie")));
}

/// Negative zero is normalized before the number is mixed, so that `0.0` and
/// `-0.0`, which are `=`, do not land in different buckets. The `+= 0.0` that
/// does it is one statement and deleting it breaks nothing else.
fn theHashNormalizesNegativeZero() void {
    expect(harness.equals(num(0.0), num(-0.0)));
    expect(order.hash(num(0.0)) == order.hash(num(-0.0)));
    // And the mixing is not a no-op: neighbouring doubles must not share a
    // hash, or a `return 0` would satisfy the assertion above.
    expect(order.hash(num(0.0)) != order.hash(num(1.0)));
    expect(order.hash(num(1.0)) != order.hash(num(2.0)));
    expect(order.hash(num(1.0)) != order.hash(num(1.0000000000000002)));
}

/// The exact numbers, which nothing else pins and which are not free to change.
/// A struct's bucket array is part of the language contract, `{1 2 3 4}` and
/// `{3 4 1 2}` being the same value because they lay out identically, and the
/// layout is a function of `order.hash`. So the hash of a double is observable
/// through every struct with a numeric key, and it does not vary with the
/// target or with `-Dprf`: the double's bits are fixed, `murmur64` is fixed,
/// and the result is the *high* word of the mix. Taking the low word instead
/// would be just as good a hash and a different language.
fn theExactNumberHashes() void {
    expect(order.hash(num(1.0)) == -1365709855);
    expect(order.hash(num(2.0)) == 1700046601);
    expect(order.hash(num(-1.0)) == -1784919109);
    expect(order.hash(num(1.5)) == -2007118713);
    expect(order.hash(num(1e300)) == -701392662);
    // Zero is the fixed point of the mixer, every step of `murmur64` mapping
    // zero to zero, so `0` hashes to the same 0 that `nil` and `false` do.
    // Not a defect, but it is the reason `order.hash` of a number cannot be
    // assumed nonzero.
    expect(order.hash(num(0.0)) == 0);
}

/// An integer and the double that equals it are the same Janet number, so
/// they must hash alike; there is no separate integer hash to get wrong.
fn integersAndDoublesHashAlike() void {
    expect(harness.equals(intv(7), num(7.0)));
    expect(order.hash(intv(7)) == order.hash(num(7.0)));
}

/// The stored hash is returned rather than recomputed, for every type that has
/// one. Asserted by mutating the head after construction: a recomputing
/// implementation would ignore the change.
fn theHashReadsTheStoredHead() void {
    const items = [_]repr.Value{intv(1)};
    const t = mktuple(&items);
    utils.tupleHead(wrap.toTuple(t)).hash = 0x5eed;
    expect(order.hash(t) == 0x5eed);

    const v = str("abc");
    utils.stringHead(wrap.toString(v)).hash = 0x5eef;
    expect(order.hash(v) == 0x5eef);
}

/// An abstract type's `hash` callback is used when it has one, is passed the
/// abstract's own size, and is not consulted when it does not.
fn theAbstractHashCallback() void {
    expect(order.hash(mkcell(1234)) == 1234);
    expect(order.hash(mkcell(-1)) == -1);

    // Without a callback the pointer is hashed, so the same instance is stable
    // and two instances are (overwhelmingly) not equal. Two draws rather than
    // one, because a constant-returning implementation passes with one.
    const b1 = mkbare(bareType());
    const b2 = mkbare(bareType());
    expect(order.hash(b1) == order.hash(b1));
    expect(order.hash(b1) != order.hash(b2));
}

/// `murmur64`, restated. Not shared with the implementation on purpose: the
/// point of the case below is that the mixer and the word it takes are what
/// they are, and a case that called the same function could not say so.
fn murmur64Ref(h_in: u64) u64 {
    var h = h_in;
    h ^= h >> 33;
    h *%= 0xff51afd7ed558ccd;
    h ^= h >> 33;
    h *%= 0xc4ceb9fe1a85ec53;
    h ^= h >> 33;
    return h;
}

fn highWordOf(mixed: u64) i32 {
    return @bitCast(@as(u32, @truncate(mixed >> 32)));
}

/// The pointer hash is the *high* word of the mix of the payload word, which
/// nothing else can pin: a pointer is not a constant, so this is the only way
/// to say which half of the mix is taken. Taking the low word would be just as
/// good a hash and a different language, for the same reason the exact number
/// hashes above matter: a struct keyed by anything that lands here lays out
/// accordingly. `harness.u64Of` is the same payload word `order.hash` reads,
/// and spells a different field per value representation.
fn thePointerHashIsTheHighWord() void {
    if (@sizeOf(f64) != @sizeOf(*anyopaque)) return;
    const v = wrap.fromTable(tables.new(4));
    expect(order.hash(v) == highWordOf(murmur64Ref(harness.u64Of(v))));

    const w = wrap.fromArray(arrays.new(4));
    expect(order.hash(w) == highWordOf(murmur64Ref(harness.u64Of(w))));
}

/// The pointer fallback is a fallback for every remaining type, not just for
/// abstracts, and it is stable per value.
fn thePointerHashIsStable() void {
    const t = tables.new(4);
    const a = arrays.new(4);
    const b = buffers.new(4);
    expect(order.hash(wrap.fromTable(t)) == order.hash(wrap.fromTable(t)));
    expect(order.hash(wrap.fromArray(a)) == order.hash(wrap.fromArray(a)));
    expect(order.hash(wrap.fromBuffer(b)) == order.hash(wrap.fromBuffer(b)));
    expect(order.hash(wrap.fromTable(t)) != order.hash(wrap.fromArray(a)));
}

fn theEqualityOfAtoms() void {
    expect(harness.equals(wrap.fromNil(), wrap.fromNil()));
    expect(harness.equals(wrap.fromTrue(), wrap.fromTrue()));
    expect(harness.equals(wrap.fromFalse(), wrap.fromFalse()));
    expect(!harness.equals(wrap.fromTrue(), wrap.fromFalse()));
    // Different types are never equal, whatever their payloads look like.
    expect(!harness.equals(wrap.fromNil(), wrap.fromFalse()));
    expect(!harness.equals(intv(0), wrap.fromFalse()));
    expect(!harness.equals(kw("a"), str("a")));
}

fn theEqualityOfNumbers() void {
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);
    expect(harness.equals(num(1.5), num(1.5)));
    expect(harness.equals(num(0.0), num(-0.0)));
    expect(!harness.equals(num(1.5), num(2.5)));
    // NaN is not equal to itself, which is the one place equality is not
    // reflexive and the reason a NaN cannot be a table key.
    expect(!harness.equals(num(nan), num(nan)));
    expect(harness.equals(num(inf), num(inf)));
    expect(!harness.equals(num(inf), num(-inf)));
}

/// Strings compare by content and are not interned, so two distinct
/// allocations with the same bytes are equal. Symbols and keywords *are*
/// interned, so the same spelling is the same pointer, and the assertion is
/// that both routes end at the same place.
fn theEqualityOfStringLikes() void {
    const s1 = str("hello");
    const s2 = str("hello");
    expect(wrap.toString(s1) != wrap.toString(s2));
    expect(harness.equals(s1, s2));
    expect(!harness.equals(s1, str("hellp")));
    expect(!harness.equals(s1, str("hell")));

    expect(wrap.toSymbol(sym("q")) == wrap.toSymbol(sym("q")));
    expect(harness.equals(sym("q"), sym("q")));
    expect(!harness.equals(sym("q"), sym("r")));
    expect(harness.equals(kw("q"), kw("q")));
    expect(!harness.equals(kw("q"), kw("r")));
}

/// Mutable containers are equal only to themselves.
fn theEqualityOfMutableContainers() void {
    const t1 = tables.new(4);
    const t2 = tables.new(4);
    tables.put(t1, kw("a"), intv(1));
    tables.put(t2, kw("a"), intv(1));
    expect(harness.equals(wrap.fromTable(t1), wrap.fromTable(t1)));
    expect(!harness.equals(wrap.fromTable(t1), wrap.fromTable(t2)));

    const a1 = arrays.new(4);
    const a2 = arrays.new(4);
    harness.arrayPush(a1, intv(1));
    harness.arrayPush(a2, intv(1));
    expect(harness.equals(wrap.fromArray(a1), wrap.fromArray(a1)));
    expect(!harness.equals(wrap.fromArray(a1), wrap.fromArray(a2)));
}

/// Tuple equality traverses, and each of the three cheap rejections in front
/// of the traversal is reached by a case that reaches no other.
fn theEqualityOfTuples() void {
    const items = [_]repr.Value{ intv(1), kw("k"), str("s") };
    const other = [_]repr.Value{ intv(1), kw("k"), str("t") };
    const a = mktuple(&items);
    const b = mktuple(&items);
    expect(wrap.toTuple(a) != wrap.toTuple(b));
    expect(harness.equals(a, b));
    expect(!harness.equals(a, mktuple(&other)));
    // Shorter, so the length rejection fires.
    expect(!harness.equals(a, mktuple(items[0..2])));
    // Identity short-circuits before any of them.
    expect(harness.equals(a, a));
}

/// A value is equal to itself even when it contains something that is not
/// equal to itself. `order.equals` short-circuits on pointer identity for a
/// tuple before it looks at any element, so a tuple with a NaN in it is `=` to
/// itself and not `=` to a separately built tuple with the same bits.
///
/// Pinned because it is the only observable consequence of that
/// short-circuit, the two routes agreeing for every other value, and because
/// dropping it would silently make `(= x x)` false for a value in a live
/// variable.
fn aTupleHoldingNanEqualsItself() void {
    const items = [_]repr.Value{num(std.math.nan(f64))};
    const a = mktuple(&items);
    gc_alloc.gcroot(a);
    defer _ = gc_alloc.gcunroot(a);
    const b = mktuple(&items);
    gc_alloc.gcroot(b);
    defer _ = gc_alloc.gcunroot(b);

    expect(harness.equals(a, a));
    // Same length and the same stored hash, the NaN bits being the same
    // bits, so this one reaches the traversal, and the traversal finds a NaN.
    expect(tupleHash(wrap.toTuple(a)) == tupleHash(wrap.toTuple(b)));
    expect(!harness.equals(a, b));
}

/// Map equality is the entries in order, which is a function of the entries
/// alone, so two maps built from the same pairs in different orders are equal.
/// A map has no prototype.
fn theEqualityOfMaps() void {
    const kvs = [_]repr.Value{ kw("x"), intv(1), kw("y"), intv(2) };
    const rev = [_]repr.Value{ kw("y"), intv(2), kw("x"), intv(1) };
    const diff = [_]repr.Value{ kw("x"), intv(1), kw("y"), intv(3) };
    expect(harness.equals(mkmap(&kvs), mkmap(&rev)));
    expect(!harness.equals(mkmap(&kvs), mkmap(&diff)));
    expect(!harness.equals(mkmap(&kvs), mkmap(kvs[0..2])));
}

/// Three checks in `order.equals` sit behind the stored-hash comparison and
/// are unreachable while the hashes disagree, which for values that differ is
/// almost always. They are not dead code: a 32-bit hash collides, and
/// when it does these are what stop the traversal from reading a bucket array
/// off the end of itself or from reporting two different values equal.
///
/// A collision cannot be constructed to order, so it is forged: the head hash
/// of one value is overwritten after construction, which is exactly the state a
/// collision produces. Nothing else in the file does this, and these values are
/// used for nothing afterwards.
fn theChecksBehindTheHash() void {
    // Tuple length. Two identical two-element tuples, one of which claims to
    // be one element long. Without the length check the traversal compares
    // element zero, finds it equal, runs out of the shorter side, and, with
    // `index2` clear as `order.equals` pushes it, reports that there is
    // nothing more to compare. The result would be "equal".
    const pair = [_]repr.Value{ intv(1), intv(2) };
    const t1 = mktuple(&pair);
    gc_alloc.gcroot(t1);
    defer _ = gc_alloc.gcunroot(t1);
    const t2 = mktuple(&pair);
    gc_alloc.gcroot(t2);
    defer _ = gc_alloc.gcunroot(t2);
    expect(harness.equals(t1, t2));
    utils.tupleHead(wrap.toTuple(t2)).length = 1;
    expect(tupleHash(wrap.toTuple(t1)) == tupleHash(wrap.toTuple(t2)));
    expect(!harness.equals(t1, t2));

    // Map count. Same shape: the traversal reads both maps by position and
    // bounds the walk by the *left* side's count, so two maps of different
    // counts compared entry for entry would read past the end of the shorter
    // one. The count check is what makes that unreachable, and it is reached
    // only once the running sums agree, which is what is forced here.
    const kvs = [_]repr.Value{ kw("a"), intv(1) };
    const m1 = mkmap(&kvs);
    gc_alloc.gcroot(m1);
    defer _ = gc_alloc.gcunroot(m1);
    const m2 = mkmap(&[_]repr.Value{ kw("a"), intv(1), kw("b"), intv(2) });
    gc_alloc.gcroot(m2);
    defer _ = gc_alloc.gcunroot(m2);
    expect(!harness.equals(m1, m2));
    mapOf(m2).sum = mapOf(m1).sum;
    expect(mapOf(m1).count != mapOf(m2).count);
    expect(!harness.equals(m1, m2));
    expect(!harness.equals(m2, m1));
}

/// `order.compare` orders two maps by count, then by running sum, and only
/// then by entries. Each of the first two is isolated by forcing the later
/// criteria to disagree with it, because an implementation that dropped either
/// would still order most maps plausibly.
fn theMapOrderingCriteriaAreInOrder() void {
    const one = [_]repr.Value{ kw("a"), intv(1) };
    const two = [_]repr.Value{ kw("a"), intv(1), kw("b"), intv(2) };
    const small = mkmap(&one);
    gc_alloc.gcroot(small);
    defer _ = gc_alloc.gcunroot(small);
    const large = mkmap(&two);
    gc_alloc.gcroot(large);
    defer _ = gc_alloc.gcunroot(large);
    expect(mapOf(small).count < mapOf(large).count);

    // Count beats sum: the larger map is given the smaller sum.
    mapOf(small).sum = 100;
    mapOf(large).sum = 1;
    expect(order.compare(small, large) == -1);
    expect(order.compare(large, small) == 1);

    // Sum beats entries: two maps of equal count whose sums are forced to the
    // opposite order from their values.
    const lo = [_]repr.Value{ kw("a"), intv(1) };
    const hi = [_]repr.Value{ kw("a"), intv(2) };
    const a = mkmap(&lo);
    gc_alloc.gcroot(a);
    defer _ = gc_alloc.gcunroot(a);
    const b = mkmap(&hi);
    gc_alloc.gcroot(b);
    defer _ = gc_alloc.gcunroot(b);
    expect(mapOf(a).count == mapOf(b).count);
    mapOf(a).sum = 9;
    mapOf(b).sum = 3;
    expect(order.compare(a, b) == 1);
    expect(order.compare(b, a) == -1);

    // And below both of them, the traversal, which is the only thing that
    // looks at a map's entries. Reaching it needs everything above it to tie:
    // same count, same key, and the sum forced to agree. Then the *values*
    // decide, which is the only case in the file where a map's value slot is
    // compared at all.
    const c1 = mkmap(&lo);
    gc_alloc.gcroot(c1);
    defer _ = gc_alloc.gcunroot(c1);
    const c2 = mkmap(&hi);
    gc_alloc.gcroot(c2);
    defer _ = gc_alloc.gcunroot(c2);
    mapOf(c2).sum = mapOf(c1).sum;
    expect(harness.equals(maps.lookup(mapOf(c1), kw("a")), intv(1)));
    expect(harness.equals(maps.lookup(mapOf(c2), kw("a")), intv(2)));
    expect(order.compare(c1, c2) == -1);
    expect(order.compare(c2, c1) == 1);
    // `order.equals` reaches it on the same terms and for the same reason.
    expect(!harness.equals(c1, c2));
}

/// Abstract equality is `compare == 0`, because the abstract type interface has
/// no equality callback at all: a third-party type supplies an ordering and
/// equality is defined as its zero. So two distinct instances that compare
/// equal *are* equal, which is a real observable difference from pointer
/// identity and the only way to see the callback being used.
fn theEqualityOfAbstracts() void {
    const a = mkcell(5);
    const b = mkcell(5);
    const d = mkcell(6);
    expect(wrap.toAbstract(a) != wrap.toAbstract(b));
    expect(harness.equals(a, b));
    expect(!harness.equals(a, d));

    // Without a callback, only identity.
    const p = mkbare(bareType());
    const q = mkbare(bareType());
    expect(harness.equals(p, p));
    expect(!harness.equals(p, q));

    // Different abstract types are never equal even with equal payloads.
    const r = mkbare(otherType());
    expect(!harness.equals(p, r));
}

/// Across types the order is the `repr.Tag` enumeration, which makes it
/// arbitrary and stable, and the sort in the standard library depends on
/// both.
fn theOrderAcrossTypes() void {
    // In enumeration order, which is *not* the order a reader would guess:
    // `repr.Tag.number` is zero and `repr.Tag.nil` follows it.
    const ordered = [_]repr.Value{
        num(0.0), wrap.fromNil(), wrap.fromFalse(),
        str("s"), sym("s"),       kw("s"),
    };
    expect(@intFromEnum(repr.Tag.number) < @intFromEnum(repr.Tag.nil));
    expect(@intFromEnum(repr.Tag.nil) < @intFromEnum(repr.Tag.boolean));
    expect(@intFromEnum(repr.Tag.boolean) < @intFromEnum(repr.Tag.string));
    for (ordered, 0..) |left, i| {
        for (ordered, 0..) |right, j| {
            if (i == j) continue;
            const expected: c_int = if (i < j) -1 else 1;
            expect(order.compare(left, right) == expected);
        }
    }
}

fn theOrderOfNumbers() void {
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);
    expect(order.compare(num(1.0), num(2.0)) == -1);
    expect(order.compare(num(2.0), num(1.0)) == 1);
    expect(order.compare(num(1.0), num(1.0)) == 0);
    expect(order.compare(num(-0.0), num(0.0)) == 0);
    expect(order.compare(num(-inf), num(inf)) == -1);
    // NaN is not orderable: both directions return 1, so `order.compare` is
    // not antisymmetric on NaN. Pinned because it is the behaviour, not
    // because it is desirable.
    expect(order.compare(num(nan), num(1.0)) == 1);
    expect(order.compare(num(1.0), num(nan)) == 1);
    expect(order.compare(num(nan), num(nan)) == 1);
}

fn theOrderOfBooleans() void {
    expect(order.compare(wrap.fromFalse(), wrap.fromTrue()) == -1);
    expect(order.compare(wrap.fromTrue(), wrap.fromFalse()) == 1);
    expect(order.compare(wrap.fromTrue(), wrap.fromTrue()) == 0);
}

/// Strings order lexicographically by byte, with a shorter prefix first, and
/// the same routine orders symbols and keywords.
fn theOrderOfStringLikes() void {
    expect(order.compare(str("a"), str("b")) < 0);
    expect(order.compare(str("b"), str("a")) > 0);
    expect(order.compare(str("ab"), str("abc")) < 0);
    expect(order.compare(str("abc"), str("ab")) > 0);
    expect(order.compare(str("abc"), str("abc")) == 0);
    expect(order.compare(sym("a"), sym("b")) < 0);
    expect(order.compare(kw("a"), kw("b")) < 0);
}

/// Tuples order element-wise, and a prefix sorts before its extension, which
/// the traversal decides rather than a length check up front.
fn theOrderOfTuples() void {
    const a = [_]repr.Value{ intv(1), intv(2) };
    const b = [_]repr.Value{ intv(1), intv(2), intv(3) };
    const cc = [_]repr.Value{ intv(1), intv(3) };
    const big = [_]repr.Value{ intv(9), intv(0) };
    expect(order.compare(mktuple(&a), mktuple(&b)) == -1);
    expect(order.compare(mktuple(&b), mktuple(&a)) == 1);
    expect(order.compare(mktuple(&a), mktuple(&cc)) == -1);
    expect(order.compare(mktuple(&a), mktuple(&a)) == 0);
    // Element-wise beats length: a longer tuple whose first element is larger
    // still sorts after. And a shorter one whose first element is larger sorts
    // after too, which is the same claim from the other side.
    expect(order.compare(mktuple(&big), mktuple(&b)) == 1);
}

/// Maps order by count, then by running sum, and only then entry-wise. The
/// first two are asserted with pairs that isolate them, because an
/// implementation that dropped either would still order most maps "correctly"
/// and would silently stop being a total order.
fn theOrderOfMaps() void {
    const one = [_]repr.Value{ kw("a"), intv(1) };
    const two = [_]repr.Value{ kw("a"), intv(1), kw("b"), intv(2) };
    const m1 = mkmap(&one);
    const m2 = mkmap(&two);
    expect(mapOf(m1).count < mapOf(m2).count);
    expect(order.compare(m1, m2) == -1);
    expect(order.compare(m2, m1) == 1);
    expect(order.compare(m1, m1) == 0);
    expect(order.compare(m1, mkmap(&one)) == 0);

    // Same count, different contents: the sum decides, and whichever way it
    // decides it must be antisymmetric and it must agree with equality.
    const alt = [_]repr.Value{ kw("z"), intv(1) };
    const m3 = mkmap(&alt);
    expect(mapOf(m1).count == mapOf(m3).count);
    expect(!harness.equals(m1, m3));
    const fwd = order.compare(m1, m3);
    const rev = order.compare(m3, m1);
    expect(fwd != 0 and fwd == -rev);
}

/// Mutable containers order by pointer, which is arbitrary but must be a
/// consistent total order within a run.
fn theOrderOfMutableContainers() void {
    const t1 = tables.new(4);
    const t2 = tables.new(4);
    const a = wrap.fromTable(t1);
    const b = wrap.fromTable(t2);
    expect(order.compare(a, a) == 0);
    const fwd = order.compare(a, b);
    expect(fwd != 0 and fwd == -order.compare(b, a));
    expect(order.compare(a, b) == fwd);
    // And the direction, not merely its consistency: the larger address sorts
    // after. Asserted absolutely because "some stable order" is satisfied by
    // the reverse of this one, and the reverse is a different language.
    expect(fwd == @as(c_int, if (@intFromPtr(t1) > @intFromPtr(t2)) 1 else -1));
}

/// Abstracts: identity first, then the abstract type's *name* when the types
/// differ, which is what lets two unrelated abstract types be sorted into one
/// array in an order that survives a relink and needs nothing of either type.
/// The type's own `compare` is consulted only after that.
fn theOrderOfAbstracts() void {
    const a = mkcell(1);
    const b = mkcell(2);
    expect(order.compare(a, b) == -1);
    expect(order.compare(b, a) == 1);
    expect(order.compare(a, a) == 0);
    expect(order.compare(a, mkcell(1)) == 0);

    // No callback: pointer order, consistent both ways and in that direction.
    const p = mkbare(bareType());
    const q = mkbare(bareType());
    const fwd = order.compare(p, q);
    expect(fwd != 0 and fwd == -order.compare(q, p));
    expect(fwd == @as(c_int, if (@intFromPtr(wrap.toAbstract(p)) >
        @intFromPtr(wrap.toAbstract(q))) 1 else -1));

    // Different types: decided by the names, before either type's callback
    // could be consulted, and the cell type has one that is not used. The
    // direction is asserted absolutely, from the names spelled out here rather
    // than read off the descriptors, because "some stable order" is satisfied
    // by the reverse of this one and the reverse is a different language.
    const r = mkbare(otherType());
    const cross = order.compare(p, r);
    expect(cross != 0 and cross == -order.compare(r, p));
    expect(std.mem.lessThan(u8, "value-order/bare", "value-order/other"));
    expect(cross == -1);

    // "cell" before "bare" would be the wrong way round, so this also says the
    // comparison is on the whole name rather than on its first byte.
    expect(std.mem.lessThan(u8, "value-order/bare", "value-order/cell"));
    expect(order.compare(a, p) == 1);

    // And the order does not depend on where the descriptors landed, which
    // the identity comparison above it does.
    expect(@intFromPtr(bareType()) != @intFromPtr(otherType()));
}

/// The base slot is never used: the stack pointer is pre-incremented before a
/// node is stored, and the walk stops strictly above the base. So a comparison
/// that pushes exactly one node and stops inside it leaves the pointer one past
/// the base, and one that runs to the end leaves it *at* the base.
///
/// Observed through `order.compare` rather than `order.equals`, and the reason
/// is worth stating because it governs the two cases above as well. `equals`
/// compares the stored hashes of two tuples before it pushes anything, so two
/// tuples that differ almost never reach the traversal at all: the only inputs
/// that get `equals` into the stack are ones that are *equal*, and those run
/// to completion. `compare` has no such exit, an ordering being unable to stop
/// at "different", so it always pushes.
fn theBaseSlotIsDead() void {
    const items = [_]repr.Value{intv(0)};
    const other = [_]repr.Value{intv(1)};
    const a = mktuple(&items);
    const b = mktuple(&items);
    const d = mktuple(&other);

    expect(harness.equals(a, b));
    expect(stackDepth() == 0);
    expect(order.compare(a, b) == 0);
    expect(stackDepth() == 0);

    // Stops inside the tuple's node, which is therefore still on the stack.
    expect(order.compare(a, d) == -1);
    expect(stackDepth() == 1);

    // And `order.equals` settles the same pair on the stored hash, without
    // pushing at all, which is what the block above claims.
    expect(tupleHash(wrap.toTuple(a)) != tupleHash(wrap.toTuple(d)));
    expect(!harness.equals(a, d));
    expect(stackDepth() == 0);
}

/// The stack grows by doubling from a floor of 128 nodes and never shrinks, so
/// a deep comparison after a shallow one reuses the array. Asserted on the
/// capacity in nodes, which is the growth policy and nothing else.
fn theStackGrowthPolicy() void {
    expect(harness.equals(intv(1), intv(1)));
    if (harness.vm().traversal.base != null) expect(stackCapacity() >= 128);

    const a = nestTuples(5000, intv(0));
    const b = nestTuples(5000, intv(0));
    defer {
        _ = gc_alloc.gcunroot(a);
        _ = gc_alloc.gcunroot(b);
    }
    expect(harness.equals(a, b));

    const grown = stackCapacity();
    expect(grown >= 5000);
    // Doubling, so never far past what was needed.
    expect(grown < 4 * 5001);

    // And the array is not given back: a shallow comparison afterwards leaves
    // the capacity where it was.
    expect(harness.equals(intv(1), intv(1)));
    expect(stackCapacity() == grown);
}

/// The stack grows on the push that would take its last slot. A fresh stack
/// of 128 nodes holds 127, the base slot being dead, and the 128th push grows
/// it to `2 * 127 + 1`. The stack is released first so that the floor is the
/// capacity the case starts from.
fn theStackGrowsAtItsLastSlot() void {
    order.traversalDeinit(&harness.vm().traversal);
    order.traversalInit(&harness.vm().traversal);
    const a = nestTuples(127, intv(0));
    const b = nestTuples(127, intv(1));
    const c = nestTuples(128, intv(0));
    const d = nestTuples(128, intv(1));
    defer {
        for ([_]repr.Value{ a, b, c, d }) |x| _ = gc_alloc.gcunroot(x);
    }

    expect(order.compare(a, b) == -1);
    expect(stackDepth() == 127);
    expect(stackCapacity() == 128);
    expect(order.compare(c, d) == -1);
    expect(stackDepth() == 128);
    expect(stackCapacity() == 255);
}

/// A tuple that runs out first orders first, whatever its storage holds past
/// its length. The shorter tuple is built with two slots and its length cut to
/// one, so the slot past its end holds a value that would order the pair the
/// other way if it were read.
fn aShorterTupleIsNotReadPastItsEnd() void {
    const t = tuples.begin(2);
    t[0] = intv(1);
    t[1] = intv(9);
    const short = tuples.end(t);
    utils.tupleHead(short).length = 1;
    const long = [_]repr.Value{ intv(1), intv(5) };
    expect(order.compare(mktuple(&long), wrap.fromTuple(short)) == 1);
    expect(order.compare(wrap.fromTuple(short), mktuple(&long)) == -1);
}

/// Neither entry point pops what it pushed: an early rejection deep inside a
/// traversal leaves nodes on the stack. That is only sound because the next
/// comparison resets the pointer on the way in, which is asserted by running a
/// comparison that must return 1 immediately after one that bailed out deep.
fn theStackIsResetNotUnwound() void {
    const deep_a = nestTuples(200, intv(0));
    const deep_b = nestTuples(200, intv(1));

    // `order.compare`, because it is the one that descends: see
    // `theBaseSlotIsDead`. Two hundred levels down it finds the leaf and
    // returns, leaving two hundred nodes behind it.
    expect(order.compare(deep_a, deep_b) == -1);
    expect(stackDepth() == 200);

    // The next comparison sees a stack with two hundred nodes still on it and
    // must not be affected by any of them.
    expect(harness.equals(intv(1), intv(1)));
    expect(stackDepth() == 0);
    const deep_c = nestTuples(200, intv(0));
    expect(harness.equals(deep_a, deep_c));
    expect(order.compare(deep_a, deep_b) == -1);
    expect(order.compare(deep_b, deep_a) == 1);
    expect(!harness.equals(deep_a, deep_b));

    _ = gc_alloc.gcunroot(deep_a);
    _ = gc_alloc.gcunroot(deep_b);
    _ = gc_alloc.gcunroot(deep_c);
}

/// The traversal is an explicit stack, not recursion. Twenty thousand levels of
/// nesting is a value a parser will produce and a depth a recursive comparison
/// would not survive on any default thread stack.
///
/// Both directions are asserted: equal all the way down, and differing only
/// at the very bottom, so that the walk is shown to reach the leaf rather than
/// stopping early on a guess.
fn deepTuplesDoNotRecurse() void {
    const a = nestTuples(20000, intv(0));
    const b = nestTuples(20000, intv(0));
    const d = nestTuples(20000, intv(1));
    defer {
        _ = gc_alloc.gcunroot(a);
        _ = gc_alloc.gcunroot(b);
        _ = gc_alloc.gcunroot(d);
    }

    expect(harness.equals(a, b));
    expect(!harness.equals(a, d));
    expect(order.compare(a, b) == 0);
    expect(order.compare(a, d) == -1);
    expect(order.compare(d, a) == 1);
}

/// Build a map nested `depth` levels deep: `{:k {:k {:k leaf}}}`, rooted the
/// same way and on the same terms.
fn nestMaps(depth: i32, leaf: repr.Value) repr.Value {
    var acc = leaf;
    gc_alloc.gcroot(acc);
    var i: i32 = 0;
    while (i < depth) : (i += 1) {
        const kvs = [_]repr.Value{ kw("k"), acc };
        const next = mkmap(&kvs);
        gc_alloc.gcroot(next);
        _ = gc_alloc.gcunroot(acc);
        acc = next;
    }
    return acc;
}

fn deepMapsDoNotRecurse() void {
    const a = nestMaps(20000, intv(0));
    const b = nestMaps(20000, intv(0));
    const d = nestMaps(20000, intv(1));
    defer {
        _ = gc_alloc.gcunroot(a);
        _ = gc_alloc.gcunroot(b);
        _ = gc_alloc.gcunroot(d);
    }

    expect(harness.equals(a, b));
    expect(!harness.equals(a, d));
    expect(order.compare(a, b) == 0);
    // Structs order by hash before their entries, so which of `a` and `d`
    // comes first depends on the hashes, and only that the two disagree is
    // pinned.
    expect(order.compare(a, d) != 0);
    expect(order.compare(a, d) == -order.compare(d, a));
}

/// The three functions against one corpus covering every `repr.Tag`, checking
/// the relations *between* them rather than any one in isolation:
///
///   - `order.compare` is a total order: reflexive, antisymmetric, and its
///     sign agrees with `order.equals` being zero.
///   - `order.equals` implies equal `order.hash`.
///
/// NaN is excluded, since it satisfies none of them.
fn theRelationsHoldOverACorpus() void {
    // Built under a lock and rooted before it is released: the corpus is a Zig
    // array, so every element after the first would be unreachable during the
    // allocation of the next one.
    const lock = gc_alloc.gclock(vm_state.current());
    const root = tables.new(64);
    gc_alloc.gcroot(wrap.fromTable(root));
    defer _ = gc_alloc.gcunroot(wrap.fromTable(root));

    const items = [_]repr.Value{ intv(1), kw("k") };
    const kvs = [_]repr.Value{ kw("x"), intv(1), kw("y"), intv(2) };
    const corpus = [_]repr.Value{
        wrap.fromNil(),
        wrap.fromFalse(),
        wrap.fromTrue(),
        num(-1.5),
        num(0.0),
        num(-0.0),
        intv(0),
        intv(1),
        num(std.math.inf(f64)),
        str("a"),
        str("b"),
        str(""),
        sym("a"),
        kw("a"),
        mktuple(&items),
        mktuple(&items),
        mktuple(items[0..1]),
        mkmap(&kvs),
        mkmap(kvs[0..2]),
        wrap.fromArray(arrays.new(1)),
        wrap.fromTable(tables.new(1)),
        wrap.fromBuffer(buffers.new(1)),
        mkcell(42),
        mkbare(bareType()),
        wrap.fromPointer(@ptrCast(@constCast(cellType()))),
        wrap.fromCfunction(null),
    };
    for (corpus, 0..) |entry, i| tables.put(root, intv(@intCast(i)), entry);
    gc_alloc.gcunlock(vm_state.current(), lock);

    for (corpus) |left| {
        expect(order.compare(left, left) == 0);
        expect(harness.equals(left, left));
        for (corpus) |right| {
            const fwd = order.compare(left, right);
            const rev = order.compare(right, left);
            expect(fwd == -rev);
            const eq = harness.equals(left, right);
            expect((fwd == 0) == eq);
            if (eq) expect(order.hash(left) == order.hash(right));
        }
    }

    // Transitivity across the whole corpus, which is what "total order"
    // actually claims and what a sort will exercise.
    for (corpus) |x| {
        for (corpus) |y| {
            if (order.compare(x, y) >= 0) continue;
            for (corpus) |z| {
                if (order.compare(y, z) < 0) expect(order.compare(x, z) < 0);
            }
        }
    }
}

/// The same properties once more, reached the way a Janet program reaches them,
/// so that the entry points above are shown to be the ones the language is
/// actually built on.
fn fromWattle() void {
    var out: repr.Value = undefined;
    const src =
        "[(= [1 2] [1 2]) " ++
        " (= [1 2] (vector 1 2)) " ++
        " (= (hash 'tie) (hash \"tie\")) " ++
        " (= 'tie \"tie\") " ++
        " (compare [1 2] [1 2 3]) " ++
        " (compare 1 2) " ++
        " (compare \"a\" \"b\") " ++
        " (= (hash 0.0) (hash -0.0)) " ++
        " (deep= {:a [1 {:b 2}]} {:a [1 {:b 2}]}) " ++
        " (sorted [3 1 2 :a \"s\" nil true]) " ++
        " (= (do (var t nil) (for i 0 5000 (set t [i t])) t) " ++
        "    (do (var t nil) (for i 0 5000 (set t [i t])) t))]";
    expect(core_env.dostring(harness.coreEnv(), src, "value_order", &out) == 0);
    const r = harness.elems(out);
    expect(repr.truthy(r[0]));
    expect(repr.truthy(r[1]));
    expect(repr.truthy(r[2]));
    expect(!repr.truthy(r[3]));
    expect(wrap.toInteger(r[4]) == -1);
    expect(wrap.toInteger(r[5]) == -1);
    expect(wrap.toInteger(r[6]) == -1);
    expect(repr.truthy(r[7]));
    expect(repr.truthy(r[8]));
    // `sorted` puts the types in `repr.Tag` order, which is the ordering
    // across types this file pins from the outside, and that order starts with
    // numbers because the number tag is zero. It returns an array rather than
    // a tuple.
    const sortd = wrap.toArray(r[9]).data;
    expect(wrap.toInteger(sortd.?[0]) == 1);
    expect(wrap.toInteger(sortd.?[1]) == 2);
    expect(wrap.toInteger(sortd.?[2]) == 3);
    expect(harness.isType(sortd.?[3], repr.Tag.nil));
    expect(harness.isType(sortd.?[4], repr.Tag.boolean));
    expect(harness.isType(sortd.?[5], repr.Tag.string));
    expect(wrap.isKeyword(sortd.?[6]));
    expect(repr.truthy(r[10]));
}

// ==========================================================================
// Entry
// ==========================================================================

pub fn run() void {
    harness.init();
    defer vm_lifecycle.deinit();

    theHashOfTheAtoms();
    theHashAgreesWithEquality();
    theStringLikesShareOneHash();
    theHashNormalizesNegativeZero();
    theExactNumberHashes();
    integersAndDoublesHashAlike();
    theHashReadsTheStoredHead();
    theAbstractHashCallback();
    thePointerHashIsTheHighWord();
    thePointerHashIsStable();

    theEqualityOfAtoms();
    theEqualityOfNumbers();
    theEqualityOfStringLikes();
    theEqualityOfMutableContainers();
    theEqualityOfTuples();
    aTupleHoldingNanEqualsItself();
    theEqualityOfMaps();
    theChecksBehindTheHash();
    theMapOrderingCriteriaAreInOrder();
    theEqualityOfAbstracts();

    theOrderAcrossTypes();
    theOrderOfNumbers();
    theOrderOfBooleans();
    theOrderOfStringLikes();
    theOrderOfTuples();
    theOrderOfMaps();
    theOrderOfMutableContainers();
    theOrderOfAbstracts();

    // Order matters here and nowhere else in this file. The traversal array
    // only ever grows, so every case that asserts a capacity has to run before
    // the ones that grow it past the floor.
    theBaseSlotIsDead();
    theStackGrowthPolicy();
    theStackGrowsAtItsLastSlot();
    aShorterTupleIsNotReadPastItsEnd();
    theStackIsResetNotUnwound();
    deepTuplesDoNotRecurse();
    deepMapsDoNotRecurse();

    theRelationsHoldOverACorpus();

    fromWattle();
}
