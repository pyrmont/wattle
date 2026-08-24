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
const abi = @import("abi");
const c = abi.c;
const harness = @import("harness.zig");

const abstract_type = @import("subsystems").abstract_type;
const AbstractType = abstract_type.AbstractType;
const assert = std.debug.assert;

// ----------------------------------------------------------------- helpers

fn kw(name: [*:0]const u8) c.Janet {
    return c.janet_ckeywordv(name);
}

fn sym(name: [*:0]const u8) c.Janet {
    return c.janet_csymbolv(name);
}

fn str(s: [*:0]const u8) c.Janet {
    return c.janet_cstringv(s);
}

fn num(d: f64) c.Janet {
    return c.janet_wrap_number(d);
}

fn intv(i: i32) c.Janet {
    return harness.wrapInteger(i);
}

/// A tuple from a slice of values, paren-constructed unless `bracket`.
fn mktuple(items: []const c.Janet, bracket: bool) c.Janet {
    const t = c.janet_tuple_begin(@intCast(items.len));
    for (items, 0..) |item, i| t[i] = item;
    if (bracket) c.janet_tuple_head(t).*.gc.flags |= c.JANET_TUPLE_FLAG_BRACKETCTOR;
    return c.janet_wrap_tuple(c.janet_tuple_end(t));
}

/// A struct from alternating key/value pairs, with an optional prototype.
fn mkstruct(kvs: []const c.Janet, proto: c.JanetStruct) c.Janet {
    const pairs: i32 = @intCast(kvs.len / 2);
    const st = c.janet_struct_begin(pairs);
    var i: usize = 0;
    while (i < kvs.len) : (i += 2) c.janet_struct_put(st, kvs[i], kvs[i + 1]);
    if (proto != null) c.janet_struct_head(st).*.proto = proto;
    return c.janet_wrap_struct(c.janet_struct_end(st));
}

fn structHash(st: c.JanetStruct) i32 {
    return c.janet_struct_head(st).*.hash;
}

fn structCapacity(st: c.JanetStruct) i32 {
    return c.janet_struct_head(st).*.capacity;
}

fn tupleHash(t: c.JanetTuple) i32 {
    return c.janet_tuple_head(t).*.hash;
}

/// Depth of the traversal stack in nodes, as the two entry points see it. Zero
/// when nothing has ever been pushed, because the base slot is never used.
fn stackDepth() isize {
    if (c.janet_vm.traversal_base == null) return 0;
    return @divExact(
        @as(isize, @bitCast(@intFromPtr(c.janet_vm.traversal) -% @intFromPtr(c.janet_vm.traversal_base))),
        @sizeOf(c.JanetTraversalNode),
    );
}

fn stackCapacity() isize {
    return @divExact(
        @as(isize, @bitCast(@intFromPtr(c.janet_vm.traversal_top) -% @intFromPtr(c.janet_vm.traversal_base))),
        @sizeOf(c.JanetTraversalNode),
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

fn cellType() [*c]const c.JanetAbstractType {
    return abstract_type.stored(&at_cell);
}

fn bareType() [*c]const c.JanetAbstractType {
    return abstract_type.stored(&at_bare);
}

fn otherType() [*c]const c.JanetAbstractType {
    return abstract_type.stored(&at_other);
}

fn mkcell(key: i32) c.Janet {
    const cell: *Cell = @ptrCast(@alignCast(c.janet_abstract(cellType(), @sizeOf(Cell))));
    cell.key = key;
    return c.janet_wrap_abstract(cell);
}

fn mkbare(at: [*c]const c.JanetAbstractType) c.Janet {
    const cell: *Cell = @ptrCast(@alignCast(c.janet_abstract(at, @sizeOf(Cell))));
    cell.key = 0;
    return c.janet_wrap_abstract(cell);
}

// ------------------------------------------------------------------ hashing

/// The constants, which nothing else pins. `janet_hash` of nil is the identity
/// of an empty bucket in every dictionary in the runtime, and `false` hashing
/// to zero is what makes `false` the one key a zero-capacity table can be
/// looked up with -- see `FOUND.md`.
fn theHashOfTheAtoms() void {
    assert(c.janet_hash(c.janet_wrap_nil()) == 0);
    assert(c.janet_hash(c.janet_wrap_false()) == 0);
    assert(c.janet_hash(c.janet_wrap_true()) == 1);
}

/// Hashing is a function: the same value hashes the same every time, and two
/// separately built values that are `=` hash alike. The second half is the
/// property every dictionary in the runtime is built on.
fn theHashAgreesWithEquality() void {
    const items = [_]c.Janet{ intv(1), kw("a"), str("s") };
    const a = mktuple(&items, false);
    const b = mktuple(&items, false);
    assert(harness.equals(a, b));
    assert(c.janet_hash(a) == c.janet_hash(a));
    assert(c.janet_hash(a) == c.janet_hash(b));

    const kvs = [_]c.Janet{ kw("x"), intv(1), kw("y"), intv(2) };
    const rev = [_]c.Janet{ kw("y"), intv(2), kw("x"), intv(1) };
    const s1 = mkstruct(&kvs, null);
    const s2 = mkstruct(&rev, null);
    assert(harness.equals(s1, s2));
    assert(c.janet_hash(s1) == c.janet_hash(s2));
}

/// All three string-like types hash their bytes and nothing else, so a keyword,
/// a symbol and a string spelled alike collide while comparing unequal. This is
/// not an accident to be tidied up: it is exactly the collision that makes the
/// `janet_compare` tiebreak in `janet_struct_put_ext` load-bearing, and
/// `test/struct_table.zig` has the other half of the story.
fn theStringLikesShareOneHash() void {
    assert(c.janet_hash(kw("tie")) == c.janet_hash(str("tie")));
    assert(c.janet_hash(sym("tie")) == c.janet_hash(str("tie")));
    assert(!harness.equals(kw("tie"), str("tie")));
    assert(!harness.equals(sym("tie"), str("tie")));
    assert(!harness.equals(kw("tie"), sym("tie")));
}

/// Negative zero is normalized before the number is mixed, so that `0.0` and
/// `-0.0` -- which are `=` -- do not land in different buckets. The `+= 0.0`
/// that does it is one statement and deleting it breaks nothing else.
fn theHashNormalizesNegativeZero() void {
    assert(harness.equals(num(0.0), num(-0.0)));
    assert(c.janet_hash(num(0.0)) == c.janet_hash(num(-0.0)));
    // And the mixing is not a no-op: neighbouring doubles must not share a
    // hash, or the assertion above would hold for a `return 0`.
    assert(c.janet_hash(num(0.0)) != c.janet_hash(num(1.0)));
    assert(c.janet_hash(num(1.0)) != c.janet_hash(num(2.0)));
    assert(c.janet_hash(num(1.0)) != c.janet_hash(num(1.0000000000000002)));
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
    assert(c.janet_hash(num(1.0)) == -1365709855);
    assert(c.janet_hash(num(2.0)) == 1700046601);
    assert(c.janet_hash(num(-1.0)) == -1784919109);
    assert(c.janet_hash(num(1.5)) == -2007118713);
    assert(c.janet_hash(num(1e300)) == -701392662);
    // Zero is the fixed point of the mixer -- every step of `murmur64` maps
    // zero to zero -- so `0` hashes to the same 0 that `nil` and `false` do.
    // Not a defect, but it is the reason `janet_hash` of a number cannot be
    // assumed nonzero.
    assert(c.janet_hash(num(0.0)) == 0);
}

/// An integer and the double that equals it are the same Janet number, so they
/// must hash alike -- there is no separate integer hash to get wrong.
fn integersAndDoublesHashAlike() void {
    assert(harness.equals(intv(7), num(7.0)));
    assert(c.janet_hash(intv(7)) == c.janet_hash(num(7.0)));
}

/// A bracket-constructed tuple hashes to one more than the paren-constructed
/// tuple with the same contents, and compares unequal to it. The flag is the
/// only case in the language where something other than contents participates
/// in a hash.
fn bracketTuplesHashAndCompareApart() void {
    const items = [_]c.Janet{ intv(1), intv(2) };
    const paren = mktuple(&items, false);
    const bracket = mktuple(&items, true);
    assert(!harness.equals(paren, bracket));
    assert(@as(u32, @bitCast(c.janet_hash(bracket))) ==
        @as(u32, @bitCast(c.janet_hash(paren))) +% 1);
    // And the difference is a *hash* difference, not a length or content one:
    // the stored head hashes are identical.
    assert(tupleHash(c.janet_unwrap_tuple(paren)) == tupleHash(c.janet_unwrap_tuple(bracket)));
}

/// The stored hash is returned rather than recomputed, for every type that has
/// one. Asserted by mutating the head after construction: a recomputing
/// implementation would ignore the change.
fn theHashReadsTheStoredHead() void {
    const items = [_]c.Janet{intv(1)};
    const t = mktuple(&items, false);
    c.janet_tuple_head(c.janet_unwrap_tuple(t)).*.hash = 0x5eed;
    assert(c.janet_hash(t) == 0x5eed);

    const kvs = [_]c.Janet{ kw("k"), intv(1) };
    const s = mkstruct(&kvs, null);
    c.janet_struct_head(c.janet_unwrap_struct(s)).*.hash = 0x5eee;
    assert(c.janet_hash(s) == 0x5eee);

    const v = str("abc");
    c.janet_string_head(c.janet_unwrap_string(v)).*.hash = 0x5eef;
    assert(c.janet_hash(v) == 0x5eef);
}

/// An abstract type's `hash` callback is used when it has one, is passed the
/// abstract's own size, and is not consulted when it does not.
fn theAbstractHashCallback() void {
    assert(c.janet_hash(mkcell(1234)) == 1234);
    assert(c.janet_hash(mkcell(-1)) == -1);

    // Without a callback the pointer is hashed, so the same instance is stable
    // and two instances are (overwhelmingly) not equal. Two draws rather than
    // one, because a constant-returning implementation passes with one.
    const b1 = mkbare(bareType());
    const b2 = mkbare(bareType());
    assert(c.janet_hash(b1) == c.janet_hash(b1));
    assert(c.janet_hash(b1) != c.janet_hash(b2));
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
    const v = c.janet_wrap_table(c.janet_table(4));
    assert(c.janet_hash(v) == highWordOf(murmur64Ref(harness.u64Of(v))));

    const w = c.janet_wrap_array(c.janet_array(4));
    assert(c.janet_hash(w) == highWordOf(murmur64Ref(harness.u64Of(w))));
}

/// The pointer fallback is a fallback for every remaining type, not just for
/// abstracts, and it is stable per value.
fn thePointerHashIsStable() void {
    const t = c.janet_table(4);
    const a = c.janet_array(4);
    const b = c.janet_buffer(4);
    assert(c.janet_hash(c.janet_wrap_table(t)) == c.janet_hash(c.janet_wrap_table(t)));
    assert(c.janet_hash(c.janet_wrap_array(a)) == c.janet_hash(c.janet_wrap_array(a)));
    assert(c.janet_hash(c.janet_wrap_buffer(b)) == c.janet_hash(c.janet_wrap_buffer(b)));
    assert(c.janet_hash(c.janet_wrap_table(t)) != c.janet_hash(c.janet_wrap_array(a)));
}

// ----------------------------------------------------------------- equality

fn theEqualityOfAtoms() void {
    assert(harness.equals(c.janet_wrap_nil(), c.janet_wrap_nil()));
    assert(harness.equals(c.janet_wrap_true(), c.janet_wrap_true()));
    assert(harness.equals(c.janet_wrap_false(), c.janet_wrap_false()));
    assert(!harness.equals(c.janet_wrap_true(), c.janet_wrap_false()));
    // Different types are never equal, whatever their payloads look like.
    assert(!harness.equals(c.janet_wrap_nil(), c.janet_wrap_false()));
    assert(!harness.equals(intv(0), c.janet_wrap_false()));
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
    assert(c.janet_unwrap_string(s1) != c.janet_unwrap_string(s2));
    assert(harness.equals(s1, s2));
    assert(!harness.equals(s1, str("hellp")));
    assert(!harness.equals(s1, str("hell")));

    assert(c.janet_unwrap_symbol(sym("q")) == c.janet_unwrap_symbol(sym("q")));
    assert(harness.equals(sym("q"), sym("q")));
    assert(!harness.equals(sym("q"), sym("r")));
    assert(harness.equals(kw("q"), kw("q")));
    assert(!harness.equals(kw("q"), kw("r")));
}

/// Mutable containers are equal only to themselves.
fn theEqualityOfMutableContainers() void {
    const t1 = c.janet_table(4);
    const t2 = c.janet_table(4);
    c.janet_table_put(t1, kw("a"), intv(1));
    c.janet_table_put(t2, kw("a"), intv(1));
    assert(harness.equals(c.janet_wrap_table(t1), c.janet_wrap_table(t1)));
    assert(!harness.equals(c.janet_wrap_table(t1), c.janet_wrap_table(t2)));

    const a1 = c.janet_array(4);
    const a2 = c.janet_array(4);
    c.janet_array_push(a1, intv(1));
    c.janet_array_push(a2, intv(1));
    assert(harness.equals(c.janet_wrap_array(a1), c.janet_wrap_array(a1)));
    assert(!harness.equals(c.janet_wrap_array(a1), c.janet_wrap_array(a2)));
}

/// Tuple equality traverses, and each of the four cheap rejections in front of
/// the traversal is reached by a case that reaches no other.
fn theEqualityOfTuples() void {
    const items = [_]c.Janet{ intv(1), kw("k"), str("s") };
    const other = [_]c.Janet{ intv(1), kw("k"), str("t") };
    const a = mktuple(&items, false);
    const b = mktuple(&items, false);
    assert(c.janet_unwrap_tuple(a) != c.janet_unwrap_tuple(b));
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
    const items = [_]c.Janet{num(std.math.nan(f64))};
    const a = mktuple(&items, false);
    c.janet_gcroot(a);
    defer _ = c.janet_gcunroot(a);
    const b = mktuple(&items, false);
    c.janet_gcroot(b);
    defer _ = c.janet_gcunroot(b);

    assert(harness.equals(a, a));
    // Same length, same stored hash -- the NaN bits are the same bits -- so
    // this one reaches the traversal, and the traversal finds a NaN.
    assert(tupleHash(c.janet_unwrap_tuple(a)) == tupleHash(c.janet_unwrap_tuple(b)));
    assert(!harness.equals(a, b));
}

/// Struct equality is layout equality, which the Robin Hood insert exists to
/// make order-independent, plus a prototype check that is *presence* only --
/// two structs whose prototypes differ are still compared through the
/// traversal, not rejected up front.
fn theEqualityOfStructs() void {
    const kvs = [_]c.Janet{ kw("x"), intv(1), kw("y"), intv(2) };
    const rev = [_]c.Janet{ kw("y"), intv(2), kw("x"), intv(1) };
    const diff = [_]c.Janet{ kw("x"), intv(1), kw("y"), intv(3) };
    assert(harness.equals(mkstruct(&kvs, null), mkstruct(&rev, null)));
    assert(!harness.equals(mkstruct(&kvs, null), mkstruct(&diff, null)));
    assert(!harness.equals(mkstruct(&kvs, null), mkstruct(kvs[0..2], null)));

    const pk = [_]c.Janet{ kw("p"), intv(9) };
    const proto = c.janet_unwrap_struct(mkstruct(&pk, null));
    const with = mkstruct(&kvs, proto);
    const without = mkstruct(&kvs, null);
    // One has a prototype and the other does not: rejected before traversing.
    assert(!harness.equals(with, without));
    assert(!harness.equals(without, with));
    // Both have one, and it is the same one.
    assert(harness.equals(with, mkstruct(&rev, proto)));
    // Both have one and they differ, which only the traversal can tell.
    const qk = [_]c.Janet{ kw("q"), intv(9) };
    const other_proto = c.janet_unwrap_struct(mkstruct(&qk, null));
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
    const pair = [_]c.Janet{ intv(1), intv(2) };
    const t1 = mktuple(&pair, false);
    c.janet_gcroot(t1);
    defer _ = c.janet_gcunroot(t1);
    const t2 = mktuple(&pair, false);
    c.janet_gcroot(t2);
    defer _ = c.janet_gcunroot(t2);
    assert(harness.equals(t1, t2));
    c.janet_tuple_head(c.janet_unwrap_tuple(t2)).*.length = 1;
    assert(tupleHash(c.janet_unwrap_tuple(t1)) == tupleHash(c.janet_unwrap_tuple(t2)));
    assert(!harness.equals(t1, t2));

    // Struct length. Same shape, and it matters more here: a struct's capacity
    // is a function of its length, and the traversal bounds the bucket walk by
    // the *left* side's capacity while indexing both. Two structs of different
    // length therefore have different capacities, and comparing them bucket for
    // bucket would read past the end of the shorter one. The length check is
    // what makes that unreachable.
    const kvs = [_]c.Janet{ kw("a"), intv(1) };
    const s1 = mkstruct(&kvs, null);
    c.janet_gcroot(s1);
    defer _ = c.janet_gcunroot(s1);
    const s2 = mkstruct(&kvs, null);
    c.janet_gcroot(s2);
    defer _ = c.janet_gcunroot(s2);
    assert(harness.equals(s1, s2));
    c.janet_struct_head(c.janet_unwrap_struct(s2)).*.length = 2;
    assert(structHash(c.janet_unwrap_struct(s1)) == structHash(c.janet_unwrap_struct(s2)));
    assert(!harness.equals(s1, s2));

    // Struct prototype presence. `janet_struct_end` folds the prototype pointer
    // into the hash, so in practice the hash rejects this pair before the
    // presence check is consulted; forcing the hashes together is the only way
    // to reach it. Without it the traversal walks the buckets, finds them
    // identical, reaches the prototype hop, and the hop's `return 3` ends
    // `janet_equals`'s loop the same way a completed traversal would -- so the
    // answer would be "equal".
    const pk = [_]c.Janet{ kw("p"), intv(1) };
    const proto = mkstruct(&pk, null);
    c.janet_gcroot(proto);
    defer _ = c.janet_gcunroot(proto);
    const with = mkstruct(&kvs, c.janet_unwrap_struct(proto));
    c.janet_gcroot(with);
    defer _ = c.janet_gcunroot(with);
    const without = mkstruct(&kvs, null);
    c.janet_gcroot(without);
    defer _ = c.janet_gcunroot(without);
    assert(structHash(c.janet_unwrap_struct(with)) != structHash(c.janet_unwrap_struct(without)));
    c.janet_struct_head(c.janet_unwrap_struct(without)).*.hash =
        structHash(c.janet_unwrap_struct(with));
    assert(c.janet_struct_head(c.janet_unwrap_struct(with)).*.length ==
        c.janet_struct_head(c.janet_unwrap_struct(without)).*.length);
    assert(!harness.equals(with, without));
    assert(!harness.equals(without, with));
}

/// `janet_compare` orders two structs by capacity, then by stored hash, and
/// only then by contents. Each of the first two is isolated by forcing the
/// later criteria to disagree with it: an implementation that dropped either
/// would still order most structs plausibly and would no longer be reproducing
/// this one.
fn theStructOrderingCriteriaAreInOrder() void {
    const one = [_]c.Janet{ kw("a"), intv(1) };
    const two = [_]c.Janet{ kw("a"), intv(1), kw("b"), intv(2) };
    const small = mkstruct(&one, null);
    c.janet_gcroot(small);
    defer _ = c.janet_gcunroot(small);
    const large = mkstruct(&two, null);
    c.janet_gcroot(large);
    defer _ = c.janet_gcunroot(large);
    assert(structCapacity(c.janet_unwrap_struct(small)) < structCapacity(c.janet_unwrap_struct(large)));

    // Capacity beats hash: the larger struct is given the smaller hash.
    c.janet_struct_head(c.janet_unwrap_struct(small)).*.hash = 100;
    c.janet_struct_head(c.janet_unwrap_struct(large)).*.hash = 1;
    assert(c.janet_compare(small, large) == -1);
    assert(c.janet_compare(large, small) == 1);

    // Hash beats contents: two structs of equal capacity whose hashes are
    // forced to the opposite order from their values.
    const lo = [_]c.Janet{ kw("a"), intv(1) };
    const hi = [_]c.Janet{ kw("a"), intv(2) };
    const a = mkstruct(&lo, null);
    c.janet_gcroot(a);
    defer _ = c.janet_gcunroot(a);
    const b = mkstruct(&hi, null);
    c.janet_gcroot(b);
    defer _ = c.janet_gcunroot(b);
    assert(structCapacity(c.janet_unwrap_struct(a)) == structCapacity(c.janet_unwrap_struct(b)));
    c.janet_struct_head(c.janet_unwrap_struct(a)).*.hash = 9;
    c.janet_struct_head(c.janet_unwrap_struct(b)).*.hash = 3;
    assert(c.janet_compare(a, b) == 1);
    assert(c.janet_compare(b, a) == -1);

    // And below both of them, the traversal, which is the only thing that looks
    // at a struct's contents. Reaching it needs everything above it to tie:
    // same capacity, same key, and the hash forced to agree. Then the *values*
    // decide, which is the only case in the file where a struct's value slot is
    // compared at all -- every other pair of structs is settled by the stored
    // hash long before.
    const c1 = mkstruct(&lo, null);
    c.janet_gcroot(c1);
    defer _ = c.janet_gcunroot(c1);
    const c2 = mkstruct(&hi, null);
    c.janet_gcroot(c2);
    defer _ = c.janet_gcunroot(c2);
    c.janet_struct_head(c.janet_unwrap_struct(c2)).*.hash = structHash(c.janet_unwrap_struct(c1));
    assert(harness.equals(c.janet_struct_get(c.janet_unwrap_struct(c1), kw("a")), intv(1)));
    assert(harness.equals(c.janet_struct_get(c.janet_unwrap_struct(c2), kw("a")), intv(2)));
    assert(c.janet_compare(c1, c2) == -1);
    assert(c.janet_compare(c2, c1) == 1);
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
    assert(c.janet_unwrap_abstract(a) != c.janet_unwrap_abstract(b));
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
    const ordered = [_]c.Janet{
        num(0.0), c.janet_wrap_nil(), c.janet_wrap_false(),
        str("s"), sym("s"),           kw("s"),
    };
    assert(c.JANET_NUMBER < c.JANET_NIL);
    assert(c.JANET_NIL < c.JANET_BOOLEAN);
    assert(c.JANET_BOOLEAN < c.JANET_STRING);
    for (ordered, 0..) |left, i| {
        for (ordered, 0..) |right, j| {
            if (i == j) continue;
            const expect: c_int = if (i < j) -1 else 1;
            assert(c.janet_compare(left, right) == expect);
        }
    }
}

fn theOrderOfNumbers() void {
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);
    assert(c.janet_compare(num(1.0), num(2.0)) == -1);
    assert(c.janet_compare(num(2.0), num(1.0)) == 1);
    assert(c.janet_compare(num(1.0), num(1.0)) == 0);
    assert(c.janet_compare(num(-0.0), num(0.0)) == 0);
    assert(c.janet_compare(num(-inf), num(inf)) == -1);
    // NaN is not orderable and the C says so in a comment: both directions
    // return 1, so `janet_compare` is not antisymmetric on NaN. Pinned because
    // it is the behaviour, not because it is desirable.
    assert(c.janet_compare(num(nan), num(1.0)) == 1);
    assert(c.janet_compare(num(1.0), num(nan)) == 1);
    assert(c.janet_compare(num(nan), num(nan)) == 1);
}

fn theOrderOfBooleans() void {
    assert(c.janet_compare(c.janet_wrap_false(), c.janet_wrap_true()) == -1);
    assert(c.janet_compare(c.janet_wrap_true(), c.janet_wrap_false()) == 1);
    assert(c.janet_compare(c.janet_wrap_true(), c.janet_wrap_true()) == 0);
}

/// Strings order lexicographically by byte, with a shorter prefix first, and
/// the same routine orders symbols and keywords.
fn theOrderOfStringLikes() void {
    assert(c.janet_compare(str("a"), str("b")) < 0);
    assert(c.janet_compare(str("b"), str("a")) > 0);
    assert(c.janet_compare(str("ab"), str("abc")) < 0);
    assert(c.janet_compare(str("abc"), str("ab")) > 0);
    assert(c.janet_compare(str("abc"), str("abc")) == 0);
    assert(c.janet_compare(sym("a"), sym("b")) < 0);
    assert(c.janet_compare(kw("a"), kw("b")) < 0);
}

/// Tuples order element-wise, and a prefix sorts before its extension -- which
/// the traversal decides, not a length check up front. The bracket flag is
/// checked before any element and outranks all of them.
fn theOrderOfTuples() void {
    const a = [_]c.Janet{ intv(1), intv(2) };
    const b = [_]c.Janet{ intv(1), intv(2), intv(3) };
    const cc = [_]c.Janet{ intv(1), intv(3) };
    const big = [_]c.Janet{ intv(9), intv(0) };
    assert(c.janet_compare(mktuple(&a, false), mktuple(&b, false)) == -1);
    assert(c.janet_compare(mktuple(&b, false), mktuple(&a, false)) == 1);
    assert(c.janet_compare(mktuple(&a, false), mktuple(&cc, false)) == -1);
    assert(c.janet_compare(mktuple(&a, false), mktuple(&a, false)) == 0);
    // Element-wise beats length: a longer tuple whose first element is larger
    // still sorts after. And a shorter one whose first element is larger sorts
    // after too, which is the same claim from the other side.
    assert(c.janet_compare(mktuple(&big, false), mktuple(&b, false)) == 1);

    // The bracket flag outranks the contents in both directions.
    assert(c.janet_compare(mktuple(&a, true), mktuple(&b, false)) == 1);
    assert(c.janet_compare(mktuple(&b, false), mktuple(&a, true)) == -1);
}

/// Structs order by capacity, then by hash, and only then element-wise. The
/// first two are asserted with pairs that isolate them, because an
/// implementation that dropped either would still order most structs
/// "correctly" and would silently stop being a total order.
fn theOrderOfStructs() void {
    const one = [_]c.Janet{ kw("a"), intv(1) };
    const two = [_]c.Janet{ kw("a"), intv(1), kw("b"), intv(2) };
    const s1 = mkstruct(&one, null);
    const s2 = mkstruct(&two, null);
    assert(structCapacity(c.janet_unwrap_struct(s1)) < structCapacity(c.janet_unwrap_struct(s2)));
    assert(c.janet_compare(s1, s2) == -1);
    assert(c.janet_compare(s2, s1) == 1);
    assert(c.janet_compare(s1, s1) == 0);
    assert(c.janet_compare(s1, mkstruct(&one, null)) == 0);

    // Same capacity, different contents: the hash decides, and whichever way it
    // decides it must be antisymmetric and it must agree with equality.
    const alt = [_]c.Janet{ kw("z"), intv(1) };
    const s3 = mkstruct(&alt, null);
    assert(structCapacity(c.janet_unwrap_struct(s1)) == structCapacity(c.janet_unwrap_struct(s3)));
    assert(!harness.equals(s1, s3));
    const fwd = c.janet_compare(s1, s3);
    const rev = c.janet_compare(s3, s1);
    assert(fwd != 0 and fwd == -rev);
}

/// A struct with a prototype sorts after one without, and two with different
/// prototypes are decided by comparing the prototypes. Both of these are the
/// prototype hop at the bottom of the traversal, which is the only place it
/// replaces a stack node instead of pushing one.
fn theOrderOfStructPrototypes() void {
    const kvs = [_]c.Janet{ kw("a"), intv(1) };
    const pk = [_]c.Janet{ kw("p"), intv(1) };
    const qk = [_]c.Janet{ kw("p"), intv(2) };
    const p = c.janet_unwrap_struct(mkstruct(&pk, null));
    const q = c.janet_unwrap_struct(mkstruct(&qk, null));
    const bare = mkstruct(&kvs, null);
    const with_p = mkstruct(&kvs, p);
    const with_q = mkstruct(&kvs, q);

    assert(c.janet_compare(with_p, bare) == 1);
    assert(c.janet_compare(bare, with_p) == -1);
    assert(c.janet_compare(with_p, mkstruct(&kvs, p)) == 0);

    const fwd = c.janet_compare(with_p, with_q);
    const rev = c.janet_compare(with_q, with_p);
    assert(fwd != 0 and fwd == -rev);
    assert(!harness.equals(with_p, with_q));
}

/// Mutable containers order by pointer, which is arbitrary but must be a
/// consistent total order within a run.
fn theOrderOfMutableContainers() void {
    const t1 = c.janet_table(4);
    const t2 = c.janet_table(4);
    const a = c.janet_wrap_table(t1);
    const b = c.janet_wrap_table(t2);
    assert(c.janet_compare(a, a) == 0);
    const fwd = c.janet_compare(a, b);
    assert(fwd != 0 and fwd == -c.janet_compare(b, a));
    assert(c.janet_compare(a, b) == fwd);
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
    assert(c.janet_compare(a, b) == -1);
    assert(c.janet_compare(b, a) == 1);
    assert(c.janet_compare(a, a) == 0);
    assert(c.janet_compare(a, mkcell(1)) == 0);

    // No callback: pointer order, consistent both ways and in that direction.
    const p = mkbare(bareType());
    const q = mkbare(bareType());
    const fwd = c.janet_compare(p, q);
    assert(fwd != 0 and fwd == -c.janet_compare(q, p));
    assert(fwd == @as(c_int, if (@intFromPtr(c.janet_unwrap_abstract(p)) >
        @intFromPtr(c.janet_unwrap_abstract(q))) 1 else -1));

    // Different types: decided by the type pointers, before either type's
    // callback could be consulted -- the cell type has one and it is not used.
    const r = mkbare(otherType());
    const cross = c.janet_compare(p, r);
    assert(cross != 0 and cross == -c.janet_compare(r, p));
    assert(cross == @as(c_int, if (@intFromPtr(bareType()) > @intFromPtr(otherType())) 1 else -1));

    assert(c.janet_compare(a, p) ==
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
fn nestTuples(depth: i32, leaf: c.Janet) c.Janet {
    var acc = leaf;
    c.janet_gcroot(acc);
    var i: i32 = 0;
    while (i < depth) : (i += 1) {
        const items = [_]c.Janet{ intv(i), acc };
        const next = mktuple(&items, false);
        c.janet_gcroot(next);
        _ = c.janet_gcunroot(acc);
        acc = next;
    }
    return acc;
}

/// Build a struct nested `depth` levels deep: `{:k {:k {:k leaf}}}`, rooted the
/// same way and on the same terms.
fn nestStructs(depth: i32, leaf: c.Janet) c.Janet {
    var acc = leaf;
    c.janet_gcroot(acc);
    var i: i32 = 0;
    while (i < depth) : (i += 1) {
        const kvs = [_]c.Janet{ kw("k"), acc };
        const next = mkstruct(&kvs, null);
        c.janet_gcroot(next);
        _ = c.janet_gcunroot(acc);
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
        _ = c.janet_gcunroot(a);
        _ = c.janet_gcunroot(b);
        _ = c.janet_gcunroot(d);
    }

    assert(harness.equals(a, b));
    assert(!harness.equals(a, d));
    assert(c.janet_compare(a, b) == 0);
    assert(c.janet_compare(a, d) == -1);
    assert(c.janet_compare(d, a) == 1);
}

fn deepStructsDoNotRecurse() void {
    const a = nestStructs(20000, intv(0));
    const b = nestStructs(20000, intv(0));
    const d = nestStructs(20000, intv(1));
    defer {
        _ = c.janet_gcunroot(a);
        _ = c.janet_gcunroot(b);
        _ = c.janet_gcunroot(d);
    }

    assert(harness.equals(a, b));
    assert(!harness.equals(a, d));
    assert(c.janet_compare(a, b) == 0);
    assert(c.janet_compare(a, d) == -1);
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
    const kvs = [_]c.Janet{ kw("a"), intv(1) };
    var a = c.janet_wrap_nil();
    var b = c.janet_wrap_nil();
    c.janet_gcroot(a);
    c.janet_gcroot(b);
    defer {
        _ = c.janet_gcunroot(a);
        _ = c.janet_gcunroot(b);
    }

    var i: i32 = 0;
    while (i < 500) : (i += 1) {
        const pa: c.JanetStruct = if (harness.isType(a, c.JANET_NIL)) null else c.janet_unwrap_struct(a);
        const next_a = mkstruct(&kvs, pa);
        c.janet_gcroot(next_a);
        _ = c.janet_gcunroot(a);
        a = next_a;
        const pb: c.JanetStruct = if (harness.isType(b, c.JANET_NIL)) null else c.janet_unwrap_struct(b);
        const next_b = mkstruct(&kvs, pb);
        c.janet_gcroot(next_b);
        _ = c.janet_gcunroot(b);
        b = next_b;
    }

    const chain_a = c.janet_unwrap_struct(a);
    assert(harness.equals(a, b));
    assert(stackDepth() == 0);
    assert(c.janet_compare(a, b) == 0);
    assert(c.janet_vm.traversal_base != null);
    assert(stackCapacity() == 128);

    // And the chains are genuinely five hundred deep, so the walk had that many
    // hops to make.
    var levels: i32 = 0;
    var p = chain_a;
    while (p != null) : (p = c.janet_struct_head(p).*.proto) levels += 1;
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
    assert(c.janet_compare(deep_a, deep_b) == -1);
    assert(stackDepth() == 200);

    // The next comparison sees a stack with two hundred nodes still on it and
    // must not be affected by any of them.
    assert(harness.equals(intv(1), intv(1)));
    assert(stackDepth() == 0);
    const deep_c = nestTuples(200, intv(0));
    assert(harness.equals(deep_a, deep_c));
    assert(c.janet_compare(deep_a, deep_b) == -1);
    assert(c.janet_compare(deep_b, deep_a) == 1);
    assert(!harness.equals(deep_a, deep_b));

    _ = c.janet_gcunroot(deep_a);
    _ = c.janet_gcunroot(deep_b);
    _ = c.janet_gcunroot(deep_c);
}

/// The stack grows by doubling from a floor of 128 nodes and never shrinks, so
/// a deep comparison after a shallow one reuses the array. Asserted on the
/// capacity in nodes, which is the growth policy and nothing else.
fn theStackGrowthPolicy() void {
    assert(harness.equals(intv(1), intv(1)));
    if (c.janet_vm.traversal_base != null) assert(stackCapacity() >= 128);

    const a = nestTuples(5000, intv(0));
    const b = nestTuples(5000, intv(0));
    defer {
        _ = c.janet_gcunroot(a);
        _ = c.janet_gcunroot(b);
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
    const items = [_]c.Janet{intv(0)};
    const other = [_]c.Janet{intv(1)};
    const a = mktuple(&items, false);
    const b = mktuple(&items, false);
    const d = mktuple(&other, false);

    assert(harness.equals(a, b));
    assert(stackDepth() == 0);
    assert(c.janet_compare(a, b) == 0);
    assert(stackDepth() == 0);

    // Stops inside the tuple's node, which is therefore still on the stack.
    assert(c.janet_compare(a, d) == -1);
    assert(stackDepth() == 1);

    // And `janet_equals` settles the same pair on the stored hash, without
    // pushing at all -- which is the claim the comment above makes.
    assert(tupleHash(c.janet_unwrap_tuple(a)) != tupleHash(c.janet_unwrap_tuple(d)));
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
    const lock = c.janet_gclock();
    const root = c.janet_table(64);
    c.janet_gcroot(c.janet_wrap_table(root));
    defer _ = c.janet_gcunroot(c.janet_wrap_table(root));

    const items = [_]c.Janet{ intv(1), kw("k") };
    const kvs = [_]c.Janet{ kw("x"), intv(1), kw("y"), intv(2) };
    const corpus = [_]c.Janet{
        c.janet_wrap_nil(),
        c.janet_wrap_false(),
        c.janet_wrap_true(),
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
        c.janet_wrap_array(c.janet_array(1)),
        c.janet_wrap_table(c.janet_table(1)),
        c.janet_wrap_buffer(c.janet_buffer(1)),
        mkcell(42),
        mkbare(bareType()),
        c.janet_wrap_pointer(@ptrCast(@constCast(cellType()))),
        c.janet_wrap_cfunction(null),
    };
    for (corpus, 0..) |value, i| c.janet_table_put(root, intv(@intCast(i)), value);
    c.janet_gcunlock(lock);

    for (corpus) |left| {
        assert(c.janet_compare(left, left) == 0);
        assert(harness.equals(left, left));
        for (corpus) |right| {
            const fwd = c.janet_compare(left, right);
            const rev = c.janet_compare(right, left);
            assert(fwd == -rev);
            const eq = harness.equals(left, right);
            assert((fwd == 0) == eq);
            if (eq) assert(c.janet_hash(left) == c.janet_hash(right));
        }
    }

    // Transitivity across the whole corpus, which is what "total order"
    // actually claims and what a sort will exercise.
    for (corpus) |x| {
        for (corpus) |y| {
            if (c.janet_compare(x, y) >= 0) continue;
            for (corpus) |z| {
                if (c.janet_compare(y, z) < 0) assert(c.janet_compare(x, z) < 0);
            }
        }
    }
}

// ------------------------------------------------------- through the runtime

/// The same properties once more, reached the way a Janet program reaches them,
/// so that the entry points above are shown to be the ones the language is
/// actually built on.
fn fromJanet() void {
    var out: c.Janet = undefined;
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
    assert(c.janet_dostring(c.janet_core_env(null), src, "value_order", &out) == 0);
    const r = c.janet_unwrap_tuple(out);
    assert(c.janet_truthy(r[0]) != 0);
    assert(c.janet_truthy(r[1]) != 0);
    assert(c.janet_truthy(r[2]) != 0);
    assert(c.janet_truthy(r[3]) == 0);
    assert(c.janet_unwrap_integer(r[4]) == -1);
    assert(c.janet_unwrap_integer(r[5]) == -1);
    assert(c.janet_unwrap_integer(r[6]) == -1);
    assert(c.janet_truthy(r[7]) != 0);
    assert(c.janet_truthy(r[8]) != 0);
    // `sorted` puts the types in `JanetType` order, which is the ordering
    // across types this file pins from the outside -- and that order starts
    // with numbers, because `JANET_NUMBER` is zero. It returns an array, not a
    // tuple.
    const sortd = c.janet_unwrap_array(r[9]).*.data;
    assert(c.janet_unwrap_integer(sortd[0]) == 1);
    assert(c.janet_unwrap_integer(sortd[1]) == 2);
    assert(c.janet_unwrap_integer(sortd[2]) == 3);
    assert(harness.isType(sortd[3], c.JANET_NIL));
    assert(harness.isType(sortd[4], c.JANET_BOOLEAN));
    assert(harness.isType(sortd[5], c.JANET_STRING));
    assert(harness.isType(sortd[6], c.JANET_KEYWORD));
    assert(c.janet_truthy(r[10]) != 0);
}

// ------------------------------------------------------------------- main

pub fn run() void {
    _ = c.janet_init();
    defer c.janet_deinit();

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
