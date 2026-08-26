//! Behavioral contract for the runtime's shared substrate: the hashes, the
//! dictionary probe every lookup goes through, the two string comparisons, the
//! key sort, and the four out-of-line head accessors.
//!
//! `port/probe-17/util-remainder.janet` covers what Janet source can reach —
//! the probe and the comparisons are on the path of every table lookup and
//! every printed table. What is here is what only a caller *inside* the
//! runtime can see: the probe's own return value, which distinguishes a
//! tombstone from an empty bucket; the comparisons' behaviour around an
//! embedded NUL; and the collection hashes' one predictable value.
//!
//! ## Nothing in this subsystem raises, so nothing here opens a scope
//!
//! `utils.zig`'s own header says why — it is the half of `src/core/util.c`
//! that owns no VM state and calls nothing that can refuse. So every call
//! below is an ordinary call, there is no `harness.raised` in the file, and
//! `run` needs no `catch`. That is unusual enough among the migrated contracts
//! to be worth saying once here rather than leaving a reader to notice it.
//!
//! ## The oracle this migration lost, and where its two replacements already
//! live
//!
//! `test/utils.c` opened by comparing each head accessor with the macro of the
//! same name — `(janet_string_head)(s) == janet_string_head(s)`, parenthesised
//! on the left so the macro did not eat it. `janet.h` declares both, C callers
//! get the macro and an embedder linking the shared library gets the function,
//! and the port has to keep them the same pointer.
//!
//! **There is one spelling here.** `@cImport` prefers the prototype wherever a
//! header declares both, so a translation of that line would compare
//! `c.janet_string_head` with itself: rule 25's shape, and the third time this
//! phase has met it.
//!
//! Rule 24 says to ask where the comparison already lives before building a
//! third one, and both halves of this one are already built:
//!
//!   - **`test/abi.c`** carries `sizeof(Head) == offsetof(Head, data)` for all
//!     five heads, as static assertions, which is C's view of `janet.h`'s
//!     layout and the only place the flexible array member is visible at all.
//!     Phase 11 Part 8 put them there for exactly this reason.
//!   - **`test/gc_mark.zig`** carries the run-time half: that the runtime's
//!     own `@sizeOf` arithmetic agrees with what the allocator did.
//!
//! What is left for this file is the part neither of those asks, and it is a
//! real question rather than a consolation prize: **the four accessors in
//! `utils.zig` recover what four *other* files wrote.** A string's length is
//! written through `string_symbol.zig`'s private `stringHead` and read here
//! through `utils.zig`'s `headOf`; a struct's through `struct_table.zig`'s. So
//! each case below builds a value with a constructor and reads its head back
//! with the accessor, which is two independent spellings of the same offset
//! after all — just not the two the C file compared.

const std = @import("std");
const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");
const harness = @import("harness.zig");
const config = @import("config");

const abstract_type = @import("subsystems").abstract_type;
const structs = @import("subsystems").value.structs;
const tables = @import("subsystems").value.tables;
const strings = @import("subsystems").value.strings;
const tuples = @import("subsystems").value.tuples;
const utils = @import("subsystems").utils;
const value = @import("subsystems").value;
const order = @import("subsystems").value.order;
const wrap = @import("subsystems").value.wrap;
const vm_lifecycle = @import("subsystems").lifecycle;
const abstracts = @import("subsystems").value.abstracts;
const AbstractType = abstract_type.AbstractType;
const assert = std.debug.assert;

const internal = harness.internal;

// ------------------------------------------------------------------- heads

const head_probe_at: AbstractType = .{ .name = "utils/head-probe" };

/// The distance from a head to the payload Janet hands around, which is what
/// each accessor subtracts.
///
/// **`@sizeOf` here is the oracle and must stay `@sizeOf`.** Since increment
/// 5e the runtime subtracts `types.<kind>_payload`, which is
/// `@offsetOf(Head, "_data")`; this file asserts that what the accessor
/// actually moved by equals the *other* spelling. Rewriting these four to the
/// constant would compare it with itself and the check would pass forever --
/// increment 5d's rule 39 at a third pair of spellings. It is also the Zig
/// replacement for `test/abi.c`'s five `_Static_assert`s, which asked the same
/// question in C back when C was the only language that could.
fn payloadOffset(head: anytype, payload: anytype) usize {
    return @intFromPtr(payload) - @intFromPtr(head);
}

fn theHeadAccessorsRecoverWhatTheConstructorsWrote() void {
    const s = strings.cstring("hello");
    const string_head = utils.stringHead(s);
    assert(string_head.*.length == 5);
    assert(payloadOffset(string_head, s) == @sizeOf(types.JanetStringHead));

    var items: [2]types.Janet = .{ harness.wrapInteger(1), harness.wrapInteger(2) };
    const tup = tuples.newFrom(&items, 2);
    const tuple_head = utils.tupleHead(tup);
    assert(tuple_head.*.length == 2);
    assert(payloadOffset(tuple_head, tup) == @sizeOf(types.JanetTupleHead));

    const kvs = structs.begin(1);
    structs.put(kvs, value.fromBytes("k", .keyword), harness.wrapInteger(3));
    const st = structs.end(kvs);
    const struct_head = utils.structHead(st);
    assert(struct_head.*.length == 1);
    assert(payloadOffset(struct_head, st) == @sizeOf(types.JanetStructHead));

    const abst = abstracts.new(abstract_type.stored(&head_probe_at), 8);
    const abstract_head = utils.abstractHead(abst);
    assert(abstract_head.*.size == 8);
    assert(payloadOffset(abstract_head, abst) == @sizeOf(types.JanetAbstractHead));
}

// -------------------------------------------------------------------- hashes

/// The three hash helpers, which need no heap and run before `janet_init`.
///
/// `janet_string_calchash` has two implementations and the configuration picks
/// one. The condition is `config.prf` rather than a field of `options`, for
/// rule 35's reason and `utils.zig`'s own: the subsystem is compiled either
/// way and what changes is which body it compiles, so no `Selection` field
/// answers the question. `JANET_HASH_KEY_SIZE` exists only
/// under the same macro, which is why the key is declared inside the branch.
fn theHashesAreTheOnesTheirCallersExpect() void {
    assert(internal.janet_hash_mix(0, 0) == 0x53a3c667);
    assert(internal.janet_hash_mix(1, 2) == 0x53a3d6f6);
    assert(internal.janet_hash_mix(
        std.math.maxInt(u32),
        std.math.maxInt(u32),
    ) == 0x9c5c4a29);

    const a = "a";
    const hello = "hello";
    const embedded_nul = "Janet\x00Z";

    if (comptime !config.prf) {
        assert(internal.janet_string_calchash(null, 0) == 5381);
        assert(internal.janet_string_calchash(a, a.len) == 2136581281);
        assert(internal.janet_string_calchash(hello, hello.len) == 1719582043);
        assert(internal.janet_string_calchash(embedded_nul, embedded_nul.len) == -1777808027);
    } else {
        var key: [constants.JANET_HASH_KEY_SIZE]u8 = @splat(0);
        for (0..8) |i| key[i] = @intCast(i);
        value.initHashKey(&key);
        assert(internal.janet_string_calchash(a, a.len) == 1520149057);
        assert(internal.janet_string_calchash(hello, hello.len) == 1601058579);
        assert(internal.janet_string_calchash(embedded_nul, embedded_nul.len) == -1601329231);
    }
}

fn tablenRoundsUpToAPowerOfTwo() void {
    assert(internal.janet_tablen(-1) == 0);
    assert(internal.janet_tablen(0) == 1);
    assert(internal.janet_tablen(1) == 2);
    assert(internal.janet_tablen(2) == 4);
    assert(internal.janet_tablen(3) == 4);
    assert(internal.janet_tablen(1024) == 2048);
    // The one value that cannot be rounded up, and is answered unchanged.
    assert(internal.janet_tablen(std.math.maxInt(i32)) == std.math.maxInt(i32));
}

// -------------------------------------------------------------- comparisons

fn cstrcmpStopsAtWhicheverEndComesFirst() void {
    // A Janet string knows its length; the C string ends at a NUL. So the
    // comparison stops at whichever comes first, and equality needs both to
    // end together.
    assert(utils.cstrcmp(strings.cstring("abc"), "abc") == 0);
    assert(utils.cstrcmp(strings.cstring(""), "") == 0);
    assert(utils.cstrcmp(strings.cstring("abc"), "abd") == -1);
    assert(utils.cstrcmp(strings.cstring("abd"), "abc") == 1);

    // A prefix on either side. The shorter Janet string runs out first and the
    // result is decided after the loop; the shorter C string is found by the
    // NUL test inside it.
    assert(utils.cstrcmp(strings.cstring("ab"), "abc") == -1);
    assert(utils.cstrcmp(strings.cstring("abc"), "ab") == 1);

    // A Janet string may contain a NUL, and then it compares *equal* to the C
    // string that stops there: the loop breaks with both bytes zero, and
    // nothing follows in the C string to decide otherwise.
    const embedded = strings.new("a\x00b");
    assert(utils.stringHead(embedded).*.length == 3);
    assert(utils.cstrcmp(embedded, "a") == 0);
    assert(utils.cstrcmp(embedded, "a\x00b") == 0);
}

// `janet_strbinsearch` wants an array of structs whose first member is a
// `char *`, sorted by it. Two shapes, to prove the item size is respected
// rather than assumed.
const SearchSmall = extern struct {
    name: [*]const u8,
    value: c_int,
};

const SearchBig = extern struct {
    name: [*]const u8,
    a: f64,
    b: f64,
    d: f64,
};

const small_table = [_]SearchSmall{
    .{ .name = "alpha", .value = 1 },
    .{ .name = "beta", .value = 2 },
    .{ .name = "delta", .value = 3 },
    .{ .name = "gamma", .value = 4 },
    .{ .name = "omega", .value = 5 },
};

const big_table = [_]SearchBig{
    .{ .name = "alpha", .a = 0, .b = 0, .d = 0 },
    .{ .name = "beta", .a = 0, .b = 0, .d = 0 },
    .{ .name = "gamma", .a = 0, .b = 0, .d = 0 },
};

fn findSmall(count: usize, key: [*:0]const u8) ?*const SearchSmall {
    const hit = internal.janet_strbinsearch(
        &small_table,
        count,
        @sizeOf(SearchSmall),
        strings.cstring(key),
    );
    return @ptrCast(@alignCast(hit));
}

fn strbinsearchRespectsTheItemSize() void {
    assert(findSmall(5, "alpha").?.value == 1);
    assert(findSmall(5, "omega").?.value == 5);
    assert(findSmall(5, "delta").?.value == 3);
    assert(findSmall(5, "zeta") == null);
    assert(findSmall(5, "aa") == null);
    assert(findSmall(5, "") == null);
    // An empty table finds nothing rather than reading the first element.
    assert(findSmall(0, "alpha") == null);

    const bighit: ?*const SearchBig = @ptrCast(@alignCast(internal.janet_strbinsearch(
        &big_table,
        3,
        @sizeOf(SearchBig),
        strings.cstring("gamma"),
    )));
    assert(bighit == &big_table[2]);
}

fn safeMemcpyToleratesAZeroLengthNullCopy() void {
    var dest = [_]u8{ 'w', 'x', 'y', 'z' };
    // The whole point: a zero length with null pointers must not be handed to
    // memcpy, which is undefined even then.
    internal.safe_memcpy(null, null, 0);
    internal.safe_memcpy(&dest, null, 0);
    assert(dest[0] == 'w');
    internal.safe_memcpy(&dest, "ab", 2);
    assert(dest[0] == 'a' and dest[1] == 'b' and dest[2] == 'y');
}

// ------------------------------------------------------------- the probe

/// The probe's three answers: the key's own bucket, the first tombstone, and a
/// never-used bucket. Only a caller inside the runtime sees which one it got.
fn theProbeDistinguishesATombstoneFromAnEmptyBucket() void {
    const t = tables.new(8);
    const present = value.fromBytes("present", .keyword);
    const absent = value.fromBytes("absent", .keyword);

    tables.put(t, present, harness.wrapInteger(1));

    var kv = internal.janet_dict_find(t.*.data.?, t.*.capacity, present);
    assert(kv != null);
    assert(harness.equals(kv.?.key, present));
    assert(wrap.toInteger(kv.?.value) == 1);

    // An absent key lands on a bucket whose key is nil -- that is what makes
    // it a place to put one.
    kv = internal.janet_dict_find(t.*.data.?, t.*.capacity, absent);
    assert(kv != null);
    assert(harness.isType(kv.?.key, constants.JANET_NIL));

    // Deleting leaves a tombstone: key nil, value not nil. The probe must scan
    // *past* it to find a key that hashed to the same bucket, which is what
    // this checks by filling the table and deleting from the middle.
    var i: i32 = 0;
    while (i < 16) : (i += 1) {
        tables.put(t, harness.wrapInteger(i), harness.wrapInteger(i * 10));
    }
    i = 0;
    while (i < 16) : (i += 2) {
        tables.put(t, harness.wrapInteger(i), wrap.fromNil());
    }
    i = 1;
    while (i < 16) : (i += 2) {
        kv = internal.janet_dict_find(t.*.data.?, t.*.capacity, harness.wrapInteger(i));
        assert(kv != null);
        assert(harness.equals(kv.?.key, harness.wrapInteger(i)));
        assert(wrap.toInteger(kv.?.value) == i * 10);
    }
}

/// A struct takes the same probe, and `janet_dictionary_get` is the wrapper
/// that turns "found a nil key" into nil.
fn dictionaryGetTurnsAMissIntoNil() void {
    const kvs = structs.begin(2);
    structs.put(kvs, value.fromBytes("a", .keyword), harness.wrapInteger(1));
    structs.put(kvs, value.fromBytes("b", .keyword), harness.wrapInteger(2));
    const st = structs.end(kvs);
    const capacity = utils.structHead(st).*.capacity;

    assert(wrap.toInteger(
        value.dictionaryGet(st, capacity, value.fromBytes("a", .keyword)),
    ) == 1);
    assert(harness.isType(
        value.dictionaryGet(st, capacity, value.fromBytes("z", .keyword)),
        constants.JANET_NIL,
    ));
}

/// `janet_dict_find_keyword` matches by bytes without interning, so a lookup
/// needs neither a `Janet` nor a symbol table entry.
fn theKeywordProbeComparesLengthBeforeBytes() void {
    const kt = tables.new(4);
    tables.put(kt, value.fromBytes("kw", .keyword), harness.wrapInteger(9));

    var kv = internal.janet_dict_find_keyword(kt.*.data.?, kt.*.capacity, "kw", 2);
    assert(kv != null);
    assert(wrap.toInteger(kv.?.value) == 9);

    kv = internal.janet_dict_find_keyword(kt.*.data.?, kt.*.capacity, "nope", 4);
    assert(kv != null);
    assert(harness.isType(kv.?.key, constants.JANET_NIL));

    // A prefix of a stored key must miss: the length is compared before the
    // bytes.
    kv = internal.janet_dict_find_keyword(kt.*.data.?, kt.*.capacity, "k", 1);
    assert(kv != null);
    assert(harness.isType(kv.?.key, constants.JANET_NIL));
}

fn dictionaryNextSkipsTombstones() void {
    const t = tables.new(8);
    var kv: ?*const types.JanetKV = null;

    // An empty dictionary ends immediately.
    assert(value.dictionaryNext(t.*.data.?, t.*.capacity, null) == null);

    tables.put(t, value.fromBytes("a", .keyword), harness.wrapInteger(1));
    tables.put(t, value.fromBytes("b", .keyword), harness.wrapInteger(2));
    tables.put(t, value.fromBytes("c", .keyword), harness.wrapInteger(3));

    var seen: i32 = 0;
    kv = value.dictionaryNext(t.*.data.?, t.*.capacity, null);
    while (kv != null) : (kv = value.dictionaryNext(t.*.data.?, t.*.capacity, kv)) {
        assert(!harness.isType(kv.?.key, constants.JANET_NIL));
        seen += 1;
    }
    assert(seen == 3);

    // A deleted entry is skipped: its key is nil even though its value is not.
    tables.put(t, value.fromBytes("b", .keyword), wrap.fromNil());
    seen = 0;
    kv = value.dictionaryNext(t.*.data.?, t.*.capacity, null);
    while (kv != null) : (kv = value.dictionaryNext(t.*.data.?, t.*.capacity, kv)) {
        seen += 1;
    }
    assert(seen == 2);
}

fn sortedKeysAnswersBucketIndicesInKeyOrder() void {
    const t = tables.new(8);
    var buffer: [32]i32 = undefined;

    // An empty dictionary sorts to nothing and writes nothing.
    assert(utils.sortedKeys(t.*.data.?, t.*.capacity, &buffer) == 0);

    var i: i32 = 5;
    while (i >= 0) : (i -= 1) {
        tables.put(t, harness.wrapInteger(i), harness.wrapInteger(i));
    }
    var n = utils.sortedKeys(t.*.data.?, t.*.capacity, &buffer);
    assert(n == 6);
    // The answer is bucket *indices*, in key order.
    i = 0;
    while (i < n) : (i += 1) {
        const key = t.*.data.?[@intCast(buffer[@intCast(i)])].key;
        assert(wrap.toInteger(key) == i);
    }

    // Deleted entries are not counted.
    tables.put(t, harness.wrapInteger(3), wrap.fromNil());
    n = utils.sortedKeys(t.*.data.?, t.*.capacity, &buffer);
    assert(n == 5);
    i = 1;
    while (i < n) : (i += 1) {
        const previous = t.*.data.?[@intCast(buffer[@intCast(i - 1)])].key;
        const current = t.*.data.?[@intCast(buffer[@intCast(i)])].key;
        assert(order.compare(previous, current) < 0);
    }
}

fn theCollectionHashesAreWhatTheHeadsStore() void {
    var items: [3]types.Janet = .{
        harness.wrapInteger(1),
        harness.wrapInteger(2),
        harness.wrapInteger(3),
    };

    // The seed is 33, so a zero-length run hashes to it. That is the one value
    // of the two collection hashes a caller can predict.
    assert(internal.janet_array_calchash(&items, 0) == 33);
    assert(internal.janet_kv_calchash(null, 0) == 33);

    // A tuple's stored hash is what `janet_array_calchash` computed, and the
    // head it is stored in is recovered by the accessor above.
    const tup = tuples.newFrom(&items, 3);
    assert(utils.tupleHead(tup).*.hash == internal.janet_array_calchash(tup, 3));

    const kvs = structs.begin(1);
    structs.put(kvs, value.fromBytes("k", .keyword), harness.wrapInteger(1));
    const st = structs.end(kvs);
    const head = utils.structHead(st);
    assert(head.*.hash == internal.janet_kv_calchash(st, head.*.capacity));
}

pub fn run() void {
    // The three helpers that touch no heap, run before there is one — as the C
    // original did, and for the same reason: nothing here needs a VM, and a
    // hash that needed one would be a finding.
    theHashesAreTheOnesTheirCallersExpect();
    tablenRoundsUpToAPowerOfTwo();

    harness.init();

    theHeadAccessorsRecoverWhatTheConstructorsWrote();
    cstrcmpStopsAtWhicheverEndComesFirst();
    strbinsearchRespectsTheItemSize();
    safeMemcpyToleratesAZeroLengthNullCopy();
    theProbeDistinguishesATombstoneFromAnEmptyBucket();
    dictionaryGetTurnsAMissIntoNil();
    theKeywordProbeComparesLengthBeforeBytes();
    dictionaryNextSkipsTombstones();
    sortedKeysAnswersBucketIndicesInKeyOrder();
    theCollectionHashesAreWhatTheHeadsStore();

    vm_lifecycle.deinit();

    std.debug.print("utils contract ok\n", .{});
}
