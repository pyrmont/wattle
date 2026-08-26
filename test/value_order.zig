//! Behavioral contract for hashing, equality and ordering over any Janet
//! value.
//!
//! These three functions are one contract rather than three, and the file is
//! organised that way. A hash table needs `janet_hash` and `janet_equals` to
//! agree; the Robin Hood insert in `struct_table.zig` needs `janet_compare` to
//! totally order whatever `janet_hash` collides. So the last section runs a
//! corpus of values that covers every `JanetType` through all three at once and
//! asserts the relations *between* them, rather than checking each function in
//! isolation and hoping.
//!
//! Two properties get more attention than their size suggests.
//!
//! **The traversal is not recursion.** `janet_equals` and `janet_compare` walk
//! nested tuples and structs with an explicit stack in `janet_vm`, because a
//! literal nested a few thousand deep is a value a parser will hand you and a
//! native stack overflow is not a catchable error. A case that only compares
//! shallow values passes just as happily against a recursive implementation, so
//! the depth cases here use depths that would blow a native stack.
//!
//! **The stack is scratch, not state.** Both entry points reset it on the way
//! in and neither pops what it pushed, so a comparison that returns early
//! leaves nodes behind. That is only correct if the next comparison is
//! unaffected, which is asserted directly rather than assumed.
//!
//! ## The abstract fixtures need no adapter
//!
//! The C original reached each of its three abstract types through
//! `CONTRACT_AT`, which is `test/support.zig`'s pool of pre-built tables: a
//! `JanetAbstractType`'s callbacks have been Zig-ABI since Phase 10's hinge and
//! C can define none of them. The two this file supplies are `compare` and
//! `hash`, which the hinge typed **non**-raising for the reason
//! `abstract_type.zig` gives -- they are called from inside comparisons that
//! must be total, so there is nowhere for a raise to go. They are ordinary
//! `callconv(.c)` functions here and the table is the runtime's own
//! `AbstractType`. Fifteen `CONTRACT_AT` uses went for free.

const std = @import("std");
const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");
const harness = @import("harness.zig");
const value = @import("subsystems").value;

const abstract_type = @import("subsystems").abstract_type;
const structs = @import("subsystems").value.structs;
const tables = @import("subsystems").value.tables;
const gc_alloc = @import("subsystems").gc_alloc;
const tuples = @import("subsystems").value.tuples;
const utils = @import("subsystems").utils;
const order = @import("subsystems").value.order;
const core_env = @import("subsystems").env;
const kind = @import("subsystems").value.kind;
const wrap = @import("subsystems").value.wrap;
const vm_lifecycle = @import("subsystems").lifecycle;
const arrays = @import("subsystems").value.arrays;
const buffers = @import("subsystems").value.buffers;
const abstracts = @import("subsystems").value.abstracts;
const AbstractType = abstract_type.AbstractType;
const assert = std.debug.assert;

// ----------------------------------------------------------------- helpers

fn kw(name: [*:0]const u8) types.Janet {
    return value.fromBytes(std.mem.span(name), .keyword);
}

fn sym(name: [*:0]const u8) types.Janet {
    return value.fromBytes(std.mem.span(name), .symbol);
}

fn str(s: [*:0]const u8) types.Janet {
    return value.fromBytes(std.mem.span(s), .string);
}

fn num(d: f64) types.Janet {
    return wrap.fromNumber(d);
}

fn intv(i: i32) types.Janet {
    return harness.wrapInteger(i);
}

/// A tuple from a slice of values, paren-constructed unless `bracket`.
fn mktuple(items: []const types.Janet, bracket: bool) types.Janet {
    const t = tuples.begin(@intCast(items.len));
    for (items, 0..) |item, i| t[i] = item;
    if (bracket) utils.tupleHead(t).*.gc.flags |= constants.JANET_TUPLE_FLAG_BRACKETCTOR;
    return wrap.fromTuple(tuples.end(t));
}

/// A struct from alternating key/value pairs, with an optional prototype.
fn mkstruct(kvs: []const types.Janet, proto: ?types.JanetStruct) types.Janet {
    const pairs: i32 = @intCast(kvs.len / 2);
    const st = structs.begin(pairs);
    var i: usize = 0;
    while (i < kvs.len) : (i += 2) structs.put(st, kvs[i], kvs[i + 1]);
    if (proto) |p| utils.structHead(st).*.proto = p;
    return wrap.fromStruct(structs.end(st));
}

fn structHash(st: types.JanetStruct) i32 {
    return utils.structHead(st).*.hash;
}

fn structCapacity(st: types.JanetStruct) i32 {
    return utils.structHead(st).*.capacity;
}

fn tupleHash(t: types.JanetTuple) i32 {
    return utils.tupleHead(t).*.hash;
}

/// Depth of the traversal stack in nodes, as the two entry points see it. Zero
/// when nothing has ever been pushed, because the base slot is never used.
fn stackDepth() isize {
    if (c.vm().traversal_base == null) return 0;
    return @divExact(
        @as(isize, @bitCast(@intFromPtr(c.vm().traversal) -% @intFromPtr(c.vm().traversal_base))),
        @sizeOf(types.JanetTraversalNode),
    );
}

fn stackCapacity() isize {
    return @divExact(
        @as(isize, @bitCast(@intFromPtr(c.vm().traversal_top) -% @intFromPtr(c.vm().traversal_base))),
        @sizeOf(types.JanetTraversalNode),
    );
}

// -------------------------------------------------------- abstract fixtures

/// Three abstract types, differing only in which callbacks they supply, so that
/// each branch of the abstract arm of `janet_compare` and of `janet_hash` is
/// reached by a type that reaches no other.
const Cell = extern struct {
    key: i32,
};

fn cellHash(p: ?*anyopaque, len: usize) callconv(.c) i32 {
    _ = len;
    return @as(*Cell, @ptrCast(@alignCast(p))).key;
}

fn cellCompare(lhs: ?*anyopaque, rhs: ?*anyopaque) callconv(.c) c_int {
    const a = @as(*Cell, @ptrCast(@alignCast(lhs))).key;
    const b = @as(*Cell, @ptrCast(@alignCast(rhs))).key;
    if (a == b) return 0;
    return if (a < b) -1 else 1;
}

/// Supplies both callbacks.
const at_cell: AbstractType = .{
    .name = "value-order/cell",
    .compare = &cellCompare,
    .hash = &cellHash,
};

/// Supplies neither, so it falls back to pointer identity for both.
const at_bare: AbstractType = .{ .name = "value-order/bare" };

/// A second callback-less type, so that two abstracts of *different* types can
/// be ordered without either type's `compare` being consulted.
const at_other: AbstractType = .{ .name = "value-order/other" };

fn cellType() *const types.JanetAbstractType {
    return abstract_type.stored(&at_cell);
}

fn bareType() *const types.JanetAbstractType {
    return abstract_type.stored(&at_bare);
}

fn otherType() *const types.JanetAbstractType {
    return abstract_type.stored(&at_other);
}

fn mkcell(key: i32) types.Janet {
    const cell: *Cell = @ptrCast(@alignCast(abstracts.new(cellType(), @sizeOf(Cell))));
    cell.key = key;
    return wrap.fromAbstract(cell);
}

fn mkbare(at: *const types.JanetAbstractType) types.Janet {
    const cell: *Cell = @ptrCast(@alignCast(abstracts.new(at, @sizeOf(Cell))));
    cell.key = 0;
    return wrap.fromAbstract(cell);
}

// ------------------------------------------------------------------ hashing

/// The constants, which nothing else pins. `janet_hash` of nil is the identity
/// of an empty bucket in every dictionary in the runtime, and `false` hashing
/// to zero is what makes `false` the one key a zero-capacity table can be
/// looked up with -- see `FOUND.md`.
fn theHashOfTheAtoms() void {
    assert(order.hash(wrap.fromNil()) == 0);
    assert(order.hash(wrap.fromFalse()) == 0);
    assert(order.hash(wrap.fromTrue()) == 1);
}

/// Hashing is a function: the same value hashes the same every time, and two
/// separately built values that are `=` hash alike. The second half is the
/// property every dictionary in the runtime is built on.
fn theHashAgreesWithEquality() void {
    const items = [_]types.Janet{ intv(1), kw("a"), str("s") };
    const a = mktuple(&items, false);
    const b = mktuple(&items, false);
    assert(harness.equals(a, b));
    assert(order.hash(a) == order.hash(a));
    assert(order.hash(a) == order.hash(b));

    const kvs = [_]types.Janet{ kw("x"), intv(1), kw("y"), intv(2) };
    const rev = [_]types.Janet{ kw("y"), intv(2), kw("x"), intv(1) };
    const s1 = mkstruct(&kvs, null);
    const s2 = mkstruct(&rev, null);
    assert(harness.equals(s1, s2));
    assert(order.hash(s1) == order.hash(s2));
}

/// All three string-like types hash their bytes and nothing else, so a keyword,
/// a symbol and a string spelled alike collide while comparing unequal. This is
/// not an accident to be tidied up: it is exactly the collision that makes the
/// `janet_compare` tiebreak in `janet_struct_put_ext` load-bearing, and
/// `test/struct_table.zig` has the other half of the story.
fn theStringLikesShareOneHash() void {
    assert(order.hash(kw("tie")) == order.hash(str("tie")));
    assert(order.hash(sym("tie")) == order.hash(str("tie")));
    assert(!harness.equals(kw("tie"), str("tie")));
    assert(!harness.equals(sym("tie"), str("tie")));
    assert(!harness.equals(kw("tie"), sym("tie")));
}

/// Negative zero is normalized before the number is mixed, so that `0.0` and
/// `-0.0` -- which are `=` -- do not land in different buckets. The `+= 0.0`
/// that does it is one statement and deleting it breaks nothing else.
fn theHashNormalizesNegativeZero() void {
    assert(harness.equals(num(0.0), num(-0.0)));
    assert(order.hash(num(0.0)) == order.hash(num(-0.0)));
    // And the mixing is not a no-op: neighbouring doubles must not share a
    // hash, or the assertion above would hold for a `return 0`.
    assert(order.hash(num(0.0)) != order.hash(num(1.0)));
    assert(order.hash(num(1.0)) != order.hash(num(2.0)));
    assert(order.hash(num(1.0)) != order.hash(num(1.0000000000000002)));
}

/// The exact numbers, which nothing else pins and which are not free to change.
/// A struct's bucket array is part of the language contract -- `{1 2 3 4}` and
/// `{3 4 1 2}` are the same value because they lay out identically -- and the
/// layout is a function of `janet_hash`. So the hash of a double is observable
/// through every struct with a numeric key, and it does not vary with the
/// target or with `-Dprf`: the double's bits are fixed, `murmur64` is fixed,
/// and the result is the *high* word of the mix. Taking the low word instead
/// would be just as good a hash and a different language.
fn theExactNumberHashes() void {
    assert(order.hash(num(1.0)) == -1365709855);
    assert(order.hash(num(2.0)) == 1700046601);
    assert(order.hash(num(-1.0)) == -1784919109);
    assert(order.hash(num(1.5)) == -2007118713);
    assert(order.hash(num(1e300)) == -701392662);
    // Zero is the fixed point of the mixer -- every step of `murmur64` maps
    // zero to zero -- so `0` hashes to the same 0 that `nil` and `false` do.
    // Not a defect, but it is the reason `janet_hash` of a number cannot be
    // assumed nonzero.
    assert(order.hash(num(0.0)) == 0);
}

/// An integer and the double that equals it are the same Janet number, so they
/// must hash alike -- there is no separate integer hash to get wrong.
fn integersAndDoublesHashAlike() void {
    assert(harness.equals(intv(7), num(7.0)));
    assert(order.hash(intv(7)) == order.hash(num(7.0)));
}

/// A bracket-constructed tuple hashes to one more than the paren-constructed
/// tuple with the same contents, and compares unequal to it. The flag is the
/// only case in the language where something other than contents participates
/// in a hash.
fn bracketTuplesHashAndCompareApart() void {
    const items = [_]types.Janet{ intv(1), intv(2) };
    const paren = mktuple(&items, false);
    const bracket = mktuple(&items, true);
    assert(!harness.equals(paren, bracket));
    assert(@as(u32, @bitCast(order.hash(bracket))) ==
        @as(u32, @bitCast(order.hash(paren))) +% 1);
    // And the difference is a *hash* difference, not a length or content one:
    // the stored head hashes are identical.
    assert(tupleHash(wrap.toTuple(paren)) == tupleHash(wrap.toTuple(bracket)));
}

/// The stored hash is returned rather than recomputed, for every type that has
/// one. Asserted by mutating the head after construction: a recomputing
/// implementation would ignore the change.
fn theHashReadsTheStoredHead() void {
    const items = [_]types.Janet{intv(1)};
    const t = mktuple(&items, false);
    utils.tupleHead(wrap.toTuple(t)).*.hash = 0x5eed;
    assert(order.hash(t) == 0x5eed);

    const kvs = [_]types.Janet{ kw("k"), intv(1) };
    const s = mkstruct(&kvs, null);
    utils.structHead(wrap.toStruct(s)).*.hash = 0x5eee;
    assert(order.hash(s) == 0x5eee);

    const v = str("abc");
    utils.stringHead(wrap.toString(v)).*.hash = 0x5eef;
    assert(order.hash(v) == 0x5eef);
}

/// An abstract type's `hash` callback is used when it has one, is passed the
/// abstract's own size, and is not consulted when it does not.
fn theAbstractHashCallback() void {
    assert(order.hash(mkcell(1234)) == 1234);
    assert(order.hash(mkcell(-1)) == -1);

    // Without a callback the pointer is hashed, so the same instance is stable
    // and two instances are (overwhelmingly) not equal. Two draws rather than
    // one, because a constant-returning implementation passes with one.
    const b1 = mkbare(bareType());
    const b2 = mkbare(bareType());
    assert(order.hash(b1) == order.hash(b1));
    assert(order.hash(b1) != order.hash(b2));
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
/// hashes above matter -- a struct keyed by anything that lands here lays out
/// accordingly. `harness.u64Of` is the same payload word `janet_hash` reads,
/// and spells a different field per value representation.
fn thePointerHashIsTheHighWord() void {
    if (@sizeOf(f64) != @sizeOf(*anyopaque)) return;
    const v = wrap.fromTable(tables.new(4));
    assert(order.hash(v) == highWordOf(murmur64Ref(harness.u64Of(v))));

    const w = wrap.fromArray(arrays.new(4));
    assert(order.hash(w) == highWordOf(murmur64Ref(harness.u64Of(w))));
}

/// The pointer fallback is a fallback for every remaining type, not just for
/// abstracts, and it is stable per value.
fn thePointerHashIsStable() void {
    const t = tables.new(4);
    const a = arrays.new(4);
    const b = buffers.new(4);
    assert(order.hash(wrap.fromTable(t)) == order.hash(wrap.fromTable(t)));
    assert(order.hash(wrap.fromArray(a)) == order.hash(wrap.fromArray(a)));
    assert(order.hash(wrap.fromBuffer(b)) == order.hash(wrap.fromBuffer(b)));
    assert(order.hash(wrap.fromTable(t)) != order.hash(wrap.fromArray(a)));
}

// ----------------------------------------------------------------- equality

fn theEqualityOfAtoms() void {
    assert(harness.equals(wrap.fromNil(), wrap.fromNil()));
    assert(harness.equals(wrap.fromTrue(), wrap.fromTrue()));
    assert(harness.equals(wrap.fromFalse(), wrap.fromFalse()));
    assert(!harness.equals(wrap.fromTrue(), wrap.fromFalse()));
    // Different types are never equal, whatever their payloads look like.
    assert(!harness.equals(wrap.fromNil(), wrap.fromFalse()));
    assert(!harness.equals(intv(0), wrap.fromFalse()));
    assert(!harness.equals(kw("a"), str("a")));
}

fn theEqualityOfNumbers() void {
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);
    assert(harness.equals(num(1.5), num(1.5)));
    assert(harness.equals(num(0.0), num(-0.0)));
    assert(!harness.equals(num(1.5), num(2.5)));
    // NaN is not equal to itself, which is the one place equality is not
    // reflexive and the reason a NaN cannot be a table key.
    assert(!harness.equals(num(nan), num(nan)));
    assert(harness.equals(num(inf), num(inf)));
    assert(!harness.equals(num(inf), num(-inf)));
}

/// Strings compare by content and are not interned, so two distinct allocations
/// with the same bytes are equal. Symbols and keywords *are* interned, so the
/// same spelling is the same pointer -- the assertion is that both routes end
/// at the same answer.
fn theEqualityOfStringLikes() void {
    const s1 = str("hello");
    const s2 = str("hello");
    assert(wrap.toString(s1) != wrap.toString(s2));
    assert(harness.equals(s1, s2));
    assert(!harness.equals(s1, str("hellp")));
    assert(!harness.equals(s1, str("hell")));

    assert(wrap.toSymbol(sym("q")) == wrap.toSymbol(sym("q")));
    assert(harness.equals(sym("q"), sym("q")));
    assert(!harness.equals(sym("q"), sym("r")));
    assert(harness.equals(kw("q"), kw("q")));
    assert(!harness.equals(kw("q"), kw("r")));
}

/// Mutable containers are equal only to themselves.
fn theEqualityOfMutableContainers() void {
    const t1 = tables.new(4);
    const t2 = tables.new(4);
    tables.put(t1, kw("a"), intv(1));
    tables.put(t2, kw("a"), intv(1));
    assert(harness.equals(wrap.fromTable(t1), wrap.fromTable(t1)));
    assert(!harness.equals(wrap.fromTable(t1), wrap.fromTable(t2)));

    const a1 = arrays.new(4);
    const a2 = arrays.new(4);
    harness.arrayPush(a1, intv(1));
    harness.arrayPush(a2, intv(1));
    assert(harness.equals(wrap.fromArray(a1), wrap.fromArray(a1)));
    assert(!harness.equals(wrap.fromArray(a1), wrap.fromArray(a2)));
}

/// Tuple equality traverses, and each of the four cheap rejections in front of
/// the traversal is reached by a case that reaches no other.
fn theEqualityOfTuples() void {
    const items = [_]types.Janet{ intv(1), kw("k"), str("s") };
    const other = [_]types.Janet{ intv(1), kw("k"), str("t") };
    const a = mktuple(&items, false);
    const b = mktuple(&items, false);
    assert(wrap.toTuple(a) != wrap.toTuple(b));
    assert(harness.equals(a, b));
    assert(!harness.equals(a, mktuple(&other, false)));
    // Shorter, so the length rejection fires.
    assert(!harness.equals(a, mktuple(items[0..2], false)));
    // Same contents, different constructor, so the flag rejection fires.
    assert(!harness.equals(a, mktuple(&items, true)));
    // Identity short-circuits before any of them.
    assert(harness.equals(a, a));
}

/// A value is equal to itself even when it contains something that is not equal
/// to itself. `janet_equals` short-circuits on pointer identity for a tuple
/// before it looks at any element, so a tuple holding a NaN is `=` to itself
/// and not `=` to a separately built tuple with the same bits.
///
/// Pinned because it is the only observable consequence of that short-circuit
/// -- for every other value the two routes agree -- and because dropping it
/// would silently make `(= x x)` false for a value a program is holding.
fn aTupleHoldingNanEqualsItself() void {
    const items = [_]types.Janet{num(std.math.nan(f64))};
    const a = mktuple(&items, false);
    gc_alloc.gcroot(a);
    defer _ = gc_alloc.gcunroot(a);
    const b = mktuple(&items, false);
    gc_alloc.gcroot(b);
    defer _ = gc_alloc.gcunroot(b);

    assert(harness.equals(a, a));
    // Same length, same stored hash -- the NaN bits are the same bits -- so
    // this one reaches the traversal, and the traversal finds a NaN.
    assert(tupleHash(wrap.toTuple(a)) == tupleHash(wrap.toTuple(b)));
    assert(!harness.equals(a, b));
}

/// Struct equality is layout equality, which the Robin Hood insert exists to
/// make order-independent, plus a prototype check that is *presence* only --
/// two structs whose prototypes differ are still compared through the
/// traversal, not rejected up front.
fn theEqualityOfStructs() void {
    const kvs = [_]types.Janet{ kw("x"), intv(1), kw("y"), intv(2) };
    const rev = [_]types.Janet{ kw("y"), intv(2), kw("x"), intv(1) };
    const diff = [_]types.Janet{ kw("x"), intv(1), kw("y"), intv(3) };
    assert(harness.equals(mkstruct(&kvs, null), mkstruct(&rev, null)));
    assert(!harness.equals(mkstruct(&kvs, null), mkstruct(&diff, null)));
    assert(!harness.equals(mkstruct(&kvs, null), mkstruct(kvs[0..2], null)));

    const pk = [_]types.Janet{ kw("p"), intv(9) };
    const proto = wrap.toStruct(mkstruct(&pk, null));
    const with = mkstruct(&kvs, proto);
    const without = mkstruct(&kvs, null);
    // One has a prototype and the other does not: rejected before traversing.
    assert(!harness.equals(with, without));
    assert(!harness.equals(without, with));
    // Both have one, and it is the same one.
    assert(harness.equals(with, mkstruct(&rev, proto)));
    // Both have one and they differ, which only the traversal can tell.
    const qk = [_]types.Janet{ kw("q"), intv(9) };
    const other_proto = wrap.toStruct(mkstruct(&qk, null));
    assert(!harness.equals(with, mkstruct(&kvs, other_proto)));
}

/// Three checks in `janet_equals` sit behind the stored-hash comparison and are
/// unreachable while the hashes disagree -- which, for values that differ, they
/// essentially always do. They are not dead code: a 32-bit hash collides, and
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
    // element zero, finds it equal, runs out of the shorter side, and -- with
    // `index2` clear, which is what `janet_equals` pushes -- reports that
    // there is nothing more to compare. The answer would be "equal".
    const pair = [_]types.Janet{ intv(1), intv(2) };
    const t1 = mktuple(&pair, false);
    gc_alloc.gcroot(t1);
    defer _ = gc_alloc.gcunroot(t1);
    const t2 = mktuple(&pair, false);
    gc_alloc.gcroot(t2);
    defer _ = gc_alloc.gcunroot(t2);
    assert(harness.equals(t1, t2));
    utils.tupleHead(wrap.toTuple(t2)).*.length = 1;
    assert(tupleHash(wrap.toTuple(t1)) == tupleHash(wrap.toTuple(t2)));
    assert(!harness.equals(t1, t2));

    // Struct length. Same shape, and it matters more here: a struct's capacity
    // is a function of its length, and the traversal bounds the bucket walk by
    // the *left* side's capacity while indexing both. Two structs of different
    // length therefore have different capacities, and comparing them bucket for
    // bucket would read past the end of the shorter one. The length check is
    // what makes that unreachable.
    const kvs = [_]types.Janet{ kw("a"), intv(1) };
    const s1 = mkstruct(&kvs, null);
    gc_alloc.gcroot(s1);
    defer _ = gc_alloc.gcunroot(s1);
    const s2 = mkstruct(&kvs, null);
    gc_alloc.gcroot(s2);
    defer _ = gc_alloc.gcunroot(s2);
    assert(harness.equals(s1, s2));
    utils.structHead(wrap.toStruct(s2)).*.length = 2;
    assert(structHash(wrap.toStruct(s1)) == structHash(wrap.toStruct(s2)));
    assert(!harness.equals(s1, s2));

    // Struct prototype presence. `janet_struct_end` folds the prototype pointer
    // into the hash, so in practice the hash rejects this pair before the
    // presence check is consulted; forcing the hashes together is the only way
    // to reach it. Without it the traversal walks the buckets, finds them
    // identical, reaches the prototype hop, and the hop's `return 3` ends
    // `janet_equals`'s loop the same way a completed traversal would -- so the
    // answer would be "equal".
    const pk = [_]types.Janet{ kw("p"), intv(1) };
    const proto = mkstruct(&pk, null);
    gc_alloc.gcroot(proto);
    defer _ = gc_alloc.gcunroot(proto);
    const with = mkstruct(&kvs, wrap.toStruct(proto));
    gc_alloc.gcroot(with);
    defer _ = gc_alloc.gcunroot(with);
    const without = mkstruct(&kvs, null);
    gc_alloc.gcroot(without);
    defer _ = gc_alloc.gcunroot(without);
    assert(structHash(wrap.toStruct(with)) != structHash(wrap.toStruct(without)));
    utils.structHead(wrap.toStruct(without)).*.hash =
        structHash(wrap.toStruct(with));
    assert(utils.structHead(wrap.toStruct(with)).*.length ==
        utils.structHead(wrap.toStruct(without)).*.length);
    assert(!harness.equals(with, without));
    assert(!harness.equals(without, with));
}

/// `janet_compare` orders two structs by capacity, then by stored hash, and
/// only then by contents. Each of the first two is isolated by forcing the
/// later criteria to disagree with it: an implementation that dropped either
/// would still order most structs plausibly and would no longer be reproducing
/// this one.
fn theStructOrderingCriteriaAreInOrder() void {
    const one = [_]types.Janet{ kw("a"), intv(1) };
    const two = [_]types.Janet{ kw("a"), intv(1), kw("b"), intv(2) };
    const small = mkstruct(&one, null);
    gc_alloc.gcroot(small);
    defer _ = gc_alloc.gcunroot(small);
    const large = mkstruct(&two, null);
    gc_alloc.gcroot(large);
    defer _ = gc_alloc.gcunroot(large);
    assert(structCapacity(wrap.toStruct(small)) < structCapacity(wrap.toStruct(large)));

    // Capacity beats hash: the larger struct is given the smaller hash.
    utils.structHead(wrap.toStruct(small)).*.hash = 100;
    utils.structHead(wrap.toStruct(large)).*.hash = 1;
    assert(order.compare(small, large) == -1);
    assert(order.compare(large, small) == 1);

    // Hash beats contents: two structs of equal capacity whose hashes are
    // forced to the opposite order from their values.
    const lo = [_]types.Janet{ kw("a"), intv(1) };
    const hi = [_]types.Janet{ kw("a"), intv(2) };
    const a = mkstruct(&lo, null);
    gc_alloc.gcroot(a);
    defer _ = gc_alloc.gcunroot(a);
    const b = mkstruct(&hi, null);
    gc_alloc.gcroot(b);
    defer _ = gc_alloc.gcunroot(b);
    assert(structCapacity(wrap.toStruct(a)) == structCapacity(wrap.toStruct(b)));
    utils.structHead(wrap.toStruct(a)).*.hash = 9;
    utils.structHead(wrap.toStruct(b)).*.hash = 3;
    assert(order.compare(a, b) == 1);
    assert(order.compare(b, a) == -1);

    // And below both of them, the traversal, which is the only thing that looks
    // at a struct's contents. Reaching it needs everything above it to tie:
    // same capacity, same key, and the hash forced to agree. Then the *values*
    // decide, which is the only case in the file where a struct's value slot is
    // compared at all -- every other pair of structs is settled by the stored
    // hash long before.
    const c1 = mkstruct(&lo, null);
    gc_alloc.gcroot(c1);
    defer _ = gc_alloc.gcunroot(c1);
    const c2 = mkstruct(&hi, null);
    gc_alloc.gcroot(c2);
    defer _ = gc_alloc.gcunroot(c2);
    utils.structHead(wrap.toStruct(c2)).*.hash = structHash(wrap.toStruct(c1));
    assert(harness.equals(structs.get(wrap.toStruct(c1), kw("a")), intv(1)));
    assert(harness.equals(structs.get(wrap.toStruct(c2), kw("a")), intv(2)));
    assert(order.compare(c1, c2) == -1);
    assert(order.compare(c2, c1) == 1);
    // `janet_equals` reaches it on the same terms and for the same reason.
    assert(!harness.equals(c1, c2));
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
    assert(wrap.toAbstract(a) != wrap.toAbstract(b));
    assert(harness.equals(a, b));
    assert(!harness.equals(a, d));

    // Without a callback, only identity.
    const p = mkbare(bareType());
    const q = mkbare(bareType());
    assert(harness.equals(p, p));
    assert(!harness.equals(p, q));

    // Different abstract types are never equal even with equal payloads.
    const r = mkbare(otherType());
    assert(!harness.equals(p, r));
}

// ----------------------------------------------------------------- ordering

/// Across types the order is the `JanetType` enumeration, which makes it
/// arbitrary and stable -- both of which the sort in the standard library
/// depends on.
fn theOrderAcrossTypes() void {
    // In enumeration order, which is *not* the order a reader would guess:
    // `JANET_NUMBER` is zero and `JANET_NIL` follows it.
    const ordered = [_]types.Janet{
        num(0.0), wrap.fromNil(), wrap.fromFalse(),
        str("s"), sym("s"),       kw("s"),
    };
    assert(constants.JANET_NUMBER < constants.JANET_NIL);
    assert(constants.JANET_NIL < constants.JANET_BOOLEAN);
    assert(constants.JANET_BOOLEAN < constants.JANET_STRING);
    for (ordered, 0..) |left, i| {
        for (ordered, 0..) |right, j| {
            if (i == j) continue;
            const expect: c_int = if (i < j) -1 else 1;
            assert(order.compare(left, right) == expect);
        }
    }
}

fn theOrderOfNumbers() void {
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);
    assert(order.compare(num(1.0), num(2.0)) == -1);
    assert(order.compare(num(2.0), num(1.0)) == 1);
    assert(order.compare(num(1.0), num(1.0)) == 0);
    assert(order.compare(num(-0.0), num(0.0)) == 0);
    assert(order.compare(num(-inf), num(inf)) == -1);
    // NaN is not orderable and the C says so in a comment: both directions
    // return 1, so `janet_compare` is not antisymmetric on NaN. Pinned because
    // it is the behaviour, not because it is desirable.
    assert(order.compare(num(nan), num(1.0)) == 1);
    assert(order.compare(num(1.0), num(nan)) == 1);
    assert(order.compare(num(nan), num(nan)) == 1);
}

fn theOrderOfBooleans() void {
    assert(order.compare(wrap.fromFalse(), wrap.fromTrue()) == -1);
    assert(order.compare(wrap.fromTrue(), wrap.fromFalse()) == 1);
    assert(order.compare(wrap.fromTrue(), wrap.fromTrue()) == 0);
}

/// Strings order lexicographically by byte, with a shorter prefix first, and
/// the same routine orders symbols and keywords.
fn theOrderOfStringLikes() void {
    assert(order.compare(str("a"), str("b")) < 0);
    assert(order.compare(str("b"), str("a")) > 0);
    assert(order.compare(str("ab"), str("abc")) < 0);
    assert(order.compare(str("abc"), str("ab")) > 0);
    assert(order.compare(str("abc"), str("abc")) == 0);
    assert(order.compare(sym("a"), sym("b")) < 0);
    assert(order.compare(kw("a"), kw("b")) < 0);
}

/// Tuples order element-wise, and a prefix sorts before its extension -- which
/// the traversal decides, not a length check up front. The bracket flag is
/// checked before any element and outranks all of them.
fn theOrderOfTuples() void {
    const a = [_]types.Janet{ intv(1), intv(2) };
    const b = [_]types.Janet{ intv(1), intv(2), intv(3) };
    const cc = [_]types.Janet{ intv(1), intv(3) };
    const big = [_]types.Janet{ intv(9), intv(0) };
    assert(order.compare(mktuple(&a, false), mktuple(&b, false)) == -1);
    assert(order.compare(mktuple(&b, false), mktuple(&a, false)) == 1);
    assert(order.compare(mktuple(&a, false), mktuple(&cc, false)) == -1);
    assert(order.compare(mktuple(&a, false), mktuple(&a, false)) == 0);
    // Element-wise beats length: a longer tuple whose first element is larger
    // still sorts after. And a shorter one whose first element is larger sorts
    // after too, which is the same claim from the other side.
    assert(order.compare(mktuple(&big, false), mktuple(&b, false)) == 1);

    // The bracket flag outranks the contents in both directions.
    assert(order.compare(mktuple(&a, true), mktuple(&b, false)) == 1);
    assert(order.compare(mktuple(&b, false), mktuple(&a, true)) == -1);
}

/// Structs order by capacity, then by hash, and only then element-wise. The
/// first two are asserted with pairs that isolate them, because an
/// implementation that dropped either would still order most structs
/// "correctly" and would silently stop being a total order.
fn theOrderOfStructs() void {
    const one = [_]types.Janet{ kw("a"), intv(1) };
    const two = [_]types.Janet{ kw("a"), intv(1), kw("b"), intv(2) };
    const s1 = mkstruct(&one, null);
    const s2 = mkstruct(&two, null);
    assert(structCapacity(wrap.toStruct(s1)) < structCapacity(wrap.toStruct(s2)));
    assert(order.compare(s1, s2) == -1);
    assert(order.compare(s2, s1) == 1);
    assert(order.compare(s1, s1) == 0);
    assert(order.compare(s1, mkstruct(&one, null)) == 0);

    // Same capacity, different contents: the hash decides, and whichever way it
    // decides it must be antisymmetric and it must agree with equality.
    const alt = [_]types.Janet{ kw("z"), intv(1) };
    const s3 = mkstruct(&alt, null);
    assert(structCapacity(wrap.toStruct(s1)) == structCapacity(wrap.toStruct(s3)));
    assert(!harness.equals(s1, s3));
    const fwd = order.compare(s1, s3);
    const rev = order.compare(s3, s1);
    assert(fwd != 0 and fwd == -rev);
}

/// A struct with a prototype sorts after one without, and two with different
/// prototypes are decided by comparing the prototypes. Both of these are the
/// prototype hop at the bottom of the traversal, which is the only place it
/// replaces a stack node instead of pushing one.
fn theOrderOfStructPrototypes() void {
    const kvs = [_]types.Janet{ kw("a"), intv(1) };
    const pk = [_]types.Janet{ kw("p"), intv(1) };
    const qk = [_]types.Janet{ kw("p"), intv(2) };
    const p = wrap.toStruct(mkstruct(&pk, null));
    const q = wrap.toStruct(mkstruct(&qk, null));
    const bare = mkstruct(&kvs, null);
    const with_p = mkstruct(&kvs, p);
    const with_q = mkstruct(&kvs, q);

    assert(order.compare(with_p, bare) == 1);
    assert(order.compare(bare, with_p) == -1);
    assert(order.compare(with_p, mkstruct(&kvs, p)) == 0);

    const fwd = order.compare(with_p, with_q);
    const rev = order.compare(with_q, with_p);
    assert(fwd != 0 and fwd == -rev);
    assert(!harness.equals(with_p, with_q));
}

/// Mutable containers order by pointer, which is arbitrary but must be a
/// consistent total order within a run.
fn theOrderOfMutableContainers() void {
    const t1 = tables.new(4);
    const t2 = tables.new(4);
    const a = wrap.fromTable(t1);
    const b = wrap.fromTable(t2);
    assert(order.compare(a, a) == 0);
    const fwd = order.compare(a, b);
    assert(fwd != 0 and fwd == -order.compare(b, a));
    assert(order.compare(a, b) == fwd);
    // And the direction, not merely its consistency: the larger address sorts
    // after. Asserted absolutely because "some stable order" is satisfied by
    // the reverse of this one, and the reverse is a different language.
    assert(fwd == @as(c_int, if (@intFromPtr(t1) > @intFromPtr(t2)) 1 else -1));
}

/// Abstracts: identity first, then the abstract *type* pointer when the types
/// differ -- which is what lets two unrelated abstract types be sorted into one
/// array without either knowing about the other -- and only then the type's own
/// `compare`.
fn theOrderOfAbstracts() void {
    const a = mkcell(1);
    const b = mkcell(2);
    assert(order.compare(a, b) == -1);
    assert(order.compare(b, a) == 1);
    assert(order.compare(a, a) == 0);
    assert(order.compare(a, mkcell(1)) == 0);

    // No callback: pointer order, consistent both ways and in that direction.
    const p = mkbare(bareType());
    const q = mkbare(bareType());
    const fwd = order.compare(p, q);
    assert(fwd != 0 and fwd == -order.compare(q, p));
    assert(fwd == @as(c_int, if (@intFromPtr(wrap.toAbstract(p)) >
        @intFromPtr(wrap.toAbstract(q))) 1 else -1));

    // Different types: decided by the type pointers, before either type's
    // callback could be consulted -- the cell type has one and it is not used.
    const r = mkbare(otherType());
    const cross = order.compare(p, r);
    assert(cross != 0 and cross == -order.compare(r, p));
    assert(cross == @as(c_int, if (@intFromPtr(bareType()) > @intFromPtr(otherType())) 1 else -1));

    assert(order.compare(a, p) ==
        @as(c_int, if (@intFromPtr(cellType()) > @intFromPtr(bareType())) 1 else -1));
}

// --------------------------------------------------------------- traversal

/// Build a tuple nested `depth` levels deep: `(0 (1 (2 ... leaf)))`.
///
/// Twenty thousand levels is megabytes of allocation and the collector will run
/// part way through, so the accumulator is rooted across every allocation that
/// could trigger one. A value held only in a Zig local is not reachable, and
/// each level here is kept alive solely by the level above it -- so losing the
/// accumulator for the length of one `janet_tuple_begin` would free the entire
/// chain built so far. The successor is rooted before its predecessor is
/// released, never the other way round.
///
/// The result is left rooted and the caller unroots it.
fn nestTuples(depth: i32, leaf: types.Janet) types.Janet {
    var acc = leaf;
    gc_alloc.gcroot(acc);
    var i: i32 = 0;
    while (i < depth) : (i += 1) {
        const items = [_]types.Janet{ intv(i), acc };
        const next = mktuple(&items, false);
        gc_alloc.gcroot(next);
        _ = gc_alloc.gcunroot(acc);
        acc = next;
    }
    return acc;
}

/// Build a struct nested `depth` levels deep: `{:k {:k {:k leaf}}}`, rooted the
/// same way and on the same terms.
fn nestStructs(depth: i32, leaf: types.Janet) types.Janet {
    var acc = leaf;
    gc_alloc.gcroot(acc);
    var i: i32 = 0;
    while (i < depth) : (i += 1) {
        const kvs = [_]types.Janet{ kw("k"), acc };
        const next = mkstruct(&kvs, null);
        gc_alloc.gcroot(next);
        _ = gc_alloc.gcunroot(acc);
        acc = next;
    }
    return acc;
}

/// The traversal is an explicit stack, not recursion. Twenty thousand levels of
/// nesting is a value a parser will produce and a depth a recursive comparison
/// would not survive on any default thread stack.
///
/// Both directions are asserted: equal all the way down, and differing only at
/// the very bottom, so that the walk is shown to reach the leaf rather than
/// stopping early and returning a hopeful answer.
fn deepTuplesDoNotRecurse() void {
    const a = nestTuples(20000, intv(0));
    const b = nestTuples(20000, intv(0));
    const d = nestTuples(20000, intv(1));
    defer {
        _ = gc_alloc.gcunroot(a);
        _ = gc_alloc.gcunroot(b);
        _ = gc_alloc.gcunroot(d);
    }

    assert(harness.equals(a, b));
    assert(!harness.equals(a, d));
    assert(order.compare(a, b) == 0);
    assert(order.compare(a, d) == -1);
    assert(order.compare(d, a) == 1);
}

fn deepStructsDoNotRecurse() void {
    const a = nestStructs(20000, intv(0));
    const b = nestStructs(20000, intv(0));
    const d = nestStructs(20000, intv(1));
    defer {
        _ = gc_alloc.gcunroot(a);
        _ = gc_alloc.gcunroot(b);
        _ = gc_alloc.gcunroot(d);
    }

    assert(harness.equals(a, b));
    assert(!harness.equals(a, d));
    assert(order.compare(a, b) == 0);
    assert(order.compare(a, d) == -1);
}

/// A long prototype chain is walked by the same stack, and the hop at the
/// bottom of the traversal replaces the current node rather than pushing on top
/// of it -- so comparing a chain of N prototypes does not need N nodes.
///
/// A successful comparison ends with the stack pointer back at the base, so the
/// depth afterwards says nothing. What does say something is the *capacity*,
/// which only ever grows and starts at a floor of 128: if the hop pushed, five
/// hundred levels would have forced two doublings. This is why this case runs
/// before the deep ones -- they grow the array past the floor and it is never
/// given back.
fn thePrototypeHopReplacesTheNode() void {
    const kvs = [_]types.Janet{ kw("a"), intv(1) };
    var a = wrap.fromNil();
    var b = wrap.fromNil();
    gc_alloc.gcroot(a);
    gc_alloc.gcroot(b);
    defer {
        _ = gc_alloc.gcunroot(a);
        _ = gc_alloc.gcunroot(b);
    }

    var i: i32 = 0;
    while (i < 500) : (i += 1) {
        const pa: ?types.JanetStruct = if (harness.isType(a, constants.JANET_NIL)) null else wrap.toStruct(a);
        const next_a = mkstruct(&kvs, pa);
        gc_alloc.gcroot(next_a);
        _ = gc_alloc.gcunroot(a);
        a = next_a;
        const pb: ?types.JanetStruct = if (harness.isType(b, constants.JANET_NIL)) null else wrap.toStruct(b);
        const next_b = mkstruct(&kvs, pb);
        gc_alloc.gcroot(next_b);
        _ = gc_alloc.gcunroot(b);
        b = next_b;
    }

    const chain_a = wrap.toStruct(a);
    assert(harness.equals(a, b));
    assert(stackDepth() == 0);
    assert(order.compare(a, b) == 0);
    assert(c.vm().traversal_base != null);
    assert(stackCapacity() == 128);

    // And the chains are genuinely five hundred deep, so the walk had that many
    // hops to make.
    var levels: i32 = 0;
    var p: ?types.JanetStruct = chain_a;
    while (p) |current| : (p = utils.structHead(current).*.proto) levels += 1;
    assert(levels == 500);
}

/// Neither entry point pops what it pushed: an early rejection deep inside a
/// traversal leaves nodes on the stack. That is only sound because the next
/// comparison resets the pointer on the way in, which is asserted by running a
/// comparison that must return 1 immediately after one that bailed out deep.
fn theStackIsResetNotUnwound() void {
    const deep_a = nestTuples(200, intv(0));
    const deep_b = nestTuples(200, intv(1));

    // `janet_compare`, because it is the one that descends: see
    // `theBaseSlotIsDead`. Two hundred levels down it finds the leaf and
    // returns, leaving two hundred nodes behind it.
    assert(order.compare(deep_a, deep_b) == -1);
    assert(stackDepth() == 200);

    // The next comparison sees a stack with two hundred nodes still on it and
    // must not be affected by any of them.
    assert(harness.equals(intv(1), intv(1)));
    assert(stackDepth() == 0);
    const deep_c = nestTuples(200, intv(0));
    assert(harness.equals(deep_a, deep_c));
    assert(order.compare(deep_a, deep_b) == -1);
    assert(order.compare(deep_b, deep_a) == 1);
    assert(!harness.equals(deep_a, deep_b));

    _ = gc_alloc.gcunroot(deep_a);
    _ = gc_alloc.gcunroot(deep_b);
    _ = gc_alloc.gcunroot(deep_c);
}

/// The stack grows by doubling from a floor of 128 nodes and never shrinks, so
/// a deep comparison after a shallow one reuses the array. Asserted on the
/// capacity in nodes, which is the growth policy and nothing else.
fn theStackGrowthPolicy() void {
    assert(harness.equals(intv(1), intv(1)));
    if (c.vm().traversal_base != null) assert(stackCapacity() >= 128);

    const a = nestTuples(5000, intv(0));
    const b = nestTuples(5000, intv(0));
    defer {
        _ = gc_alloc.gcunroot(a);
        _ = gc_alloc.gcunroot(b);
    }
    assert(harness.equals(a, b));

    const grown = stackCapacity();
    assert(grown >= 5000);
    // Doubling, so never far past what was needed.
    assert(grown < 4 * 5001);

    // And the array is not given back: a shallow comparison afterwards leaves
    // the capacity where it was.
    assert(harness.equals(intv(1), intv(1)));
    assert(stackCapacity() == grown);
}

/// The base slot is never used: the stack pointer is pre-incremented before a
/// node is stored, and the walk stops strictly above the base. So a comparison
/// that pushes exactly one node and stops inside it leaves the pointer one past
/// the base, and one that runs to the end leaves it *at* the base.
///
/// Observed through `janet_compare` rather than `janet_equals`, and the reason
/// is worth stating because it governs the two cases above as well.
/// `janet_equals` compares the stored hashes of two tuples before it pushes
/// anything, so two tuples that differ almost never reach the traversal at all
/// -- the only inputs that get `janet_equals` into the stack are ones that are
/// *equal*, which then run to completion. `janet_compare` has no such exit,
/// since an ordering cannot stop at "different", so it always pushes.
fn theBaseSlotIsDead() void {
    const items = [_]types.Janet{intv(0)};
    const other = [_]types.Janet{intv(1)};
    const a = mktuple(&items, false);
    const b = mktuple(&items, false);
    const d = mktuple(&other, false);

    assert(harness.equals(a, b));
    assert(stackDepth() == 0);
    assert(order.compare(a, b) == 0);
    assert(stackDepth() == 0);

    // Stops inside the tuple's node, which is therefore still on the stack.
    assert(order.compare(a, d) == -1);
    assert(stackDepth() == 1);

    // And `janet_equals` settles the same pair on the stored hash, without
    // pushing at all -- which is the claim the comment above makes.
    assert(tupleHash(wrap.toTuple(a)) != tupleHash(wrap.toTuple(d)));
    assert(!harness.equals(a, d));
    assert(stackDepth() == 0);
}

// ------------------------------------------------------------ the contract

/// The three functions against one corpus covering every `JanetType`, checking
/// the relations that hold *between* them rather than any one in isolation:
///
///   - `janet_compare` is a total order: reflexive, antisymmetric, and its sign
///     agrees with `janet_equals` being zero.
///   - `janet_equals` implies equal `janet_hash`.
///
/// NaN is excluded, since it satisfies none of them and the C says so.
fn theRelationsHoldOverACorpus() void {
    // Built under a lock and rooted before it is released: the corpus is a Zig
    // array, so every element after the first would be unreachable during the
    // allocation of the next one.
    const lock = gc_alloc.gclock();
    const root = tables.new(64);
    gc_alloc.gcroot(wrap.fromTable(root));
    defer _ = gc_alloc.gcunroot(wrap.fromTable(root));

    const items = [_]types.Janet{ intv(1), kw("k") };
    const kvs = [_]types.Janet{ kw("x"), intv(1), kw("y"), intv(2) };
    const corpus = [_]types.Janet{
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
        mktuple(&items, false),
        mktuple(&items, true),
        mktuple(items[0..1], false),
        mkstruct(&kvs, null),
        mkstruct(kvs[0..2], null),
        wrap.fromArray(arrays.new(1)),
        wrap.fromTable(tables.new(1)),
        wrap.fromBuffer(buffers.new(1)),
        mkcell(42),
        mkbare(bareType()),
        wrap.fromPointer(@ptrCast(@constCast(cellType()))),
        wrap.fromCfunction(null),
    };
    for (corpus, 0..) |entry, i| tables.put(root, intv(@intCast(i)), entry);
    gc_alloc.gcunlock(lock);

    for (corpus) |left| {
        assert(order.compare(left, left) == 0);
        assert(harness.equals(left, left));
        for (corpus) |right| {
            const fwd = order.compare(left, right);
            const rev = order.compare(right, left);
            assert(fwd == -rev);
            const eq = harness.equals(left, right);
            assert((fwd == 0) == eq);
            if (eq) assert(order.hash(left) == order.hash(right));
        }
    }

    // Transitivity across the whole corpus, which is what "total order"
    // actually claims and what a sort will exercise.
    for (corpus) |x| {
        for (corpus) |y| {
            if (order.compare(x, y) >= 0) continue;
            for (corpus) |z| {
                if (order.compare(y, z) < 0) assert(order.compare(x, z) < 0);
            }
        }
    }
}

// ------------------------------------------------------- through the runtime

/// The same properties once more, reached the way a Janet program reaches them,
/// so that the entry points above are shown to be the ones the language is
/// actually built on.
fn fromJanet() void {
    var out: types.Janet = undefined;
    const src =
        "[(= [1 2] [1 2]) " ++
        " (= [1 2] (tuple 1 2)) " ++
        " (= (hash :tie) (hash \"tie\")) " ++
        " (= :tie \"tie\") " ++
        " (compare [1 2] [1 2 3]) " ++
        " (compare 1 2) " ++
        " (compare \"a\" \"b\") " ++
        " (= (hash 0.0) (hash -0.0)) " ++
        " (deep= {:a [1 {:b 2}]} {:a [1 {:b 2}]}) " ++
        " (sorted [3 1 2 :a \"s\" nil true]) " ++
        " (= (do (var t nil) (for i 0 5000 (set t [i t])) t) " ++
        "    (do (var t nil) (for i 0 5000 (set t [i t])) t))]";
    assert(core_env.dostring(harness.coreEnv(), src, "value_order", &out) == 0);
    const r = wrap.toTuple(out);
    assert(kind.truthy(r[0]) != 0);
    assert(kind.truthy(r[1]) != 0);
    assert(kind.truthy(r[2]) != 0);
    assert(kind.truthy(r[3]) == 0);
    assert(wrap.toInteger(r[4]) == -1);
    assert(wrap.toInteger(r[5]) == -1);
    assert(wrap.toInteger(r[6]) == -1);
    assert(kind.truthy(r[7]) != 0);
    assert(kind.truthy(r[8]) != 0);
    // `sorted` puts the types in `JanetType` order, which is the ordering
    // across types this file pins from the outside -- and that order starts
    // with numbers, because `JANET_NUMBER` is zero. It returns an array, not a
    // tuple.
    const sortd = wrap.toArray(r[9]).*.data;
    assert(wrap.toInteger(sortd.?[0]) == 1);
    assert(wrap.toInteger(sortd.?[1]) == 2);
    assert(wrap.toInteger(sortd.?[2]) == 3);
    assert(harness.isType(sortd.?[3], constants.JANET_NIL));
    assert(harness.isType(sortd.?[4], constants.JANET_BOOLEAN));
    assert(harness.isType(sortd.?[5], constants.JANET_STRING));
    assert(harness.isType(sortd.?[6], constants.JANET_KEYWORD));
    assert(kind.truthy(r[10]) != 0);
}

// ------------------------------------------------------------------- main

pub fn run() void {
    harness.init();
    defer vm_lifecycle.deinit();

    theHashOfTheAtoms();
    theHashAgreesWithEquality();
    theStringLikesShareOneHash();
    theHashNormalizesNegativeZero();
    theExactNumberHashes();
    integersAndDoublesHashAlike();
    bracketTuplesHashAndCompareApart();
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
    theEqualityOfStructs();
    theChecksBehindTheHash();
    theStructOrderingCriteriaAreInOrder();
    theEqualityOfAbstracts();

    theOrderAcrossTypes();
    theOrderOfNumbers();
    theOrderOfBooleans();
    theOrderOfStringLikes();
    theOrderOfTuples();
    theOrderOfStructs();
    theOrderOfStructPrototypes();
    theOrderOfMutableContainers();
    theOrderOfAbstracts();

    // Order matters here and nowhere else in this file. The traversal array
    // only ever grows, so every case that asserts a capacity has to run before
    // the ones that grow it past the floor.
    theBaseSlotIsDead();
    thePrototypeHopReplacesTheNode();
    theStackGrowthPolicy();
    theStackIsResetNotUnwound();
    deepTuplesDoNotRecurse();
    deepStructsDoNotRecurse();

    theRelationsHoldOverACorpus();

    fromJanet();

    std.debug.print("value order contract ok\n", .{});
}
