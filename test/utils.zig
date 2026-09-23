//! Behavioral contract for the runtime's shared substrate: the hashes, the
//! dictionary probe every lookup goes through, the two string comparisons, the
//! key sort, and the four out-of-line head accessors.
//!
//! The probe and the comparisons are on the path of every table lookup and
//! every printed table, so Janet source reaches them constantly. What is here
//! is what only a caller *inside* the runtime can see: the probe's own return
//! value, which distinguishes a tombstone from an empty bucket; the
//! comparisons' behaviour around an embedded NUL; and the collection hashes'
//! one predictable value.
//!
//! ## Nothing in this subsystem raises, so nothing here opens a scope
//!
//! `utils.zig` owns no VM state and calls nothing that can refuse. So every
//! call below is an ordinary call, there is no `harness.raised` in the file,
//! and `run` needs no `catch`.
//!
//! ## The four accessors recover what four other files wrote
//!
//! A string's length is written through `value/strings.zig`'s own `head` and
//! read back here through `utils.zig`'s accessor; a tuple's through
//! `value/tuples.zig`'s. So each case below builds a value with a constructor
//! and reads its head back with the accessor, which puts two independent
//! spellings of the same offset against each other.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");
const builtin = @import("builtin");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const abstract_type = @import("subsystems").abstract_type;
const abstracts = @import("subsystems").value.abstracts;
const config = @import("config");
const constants = @import("constants");
const expect = @import("expect.zig").expect;

const harness = @import("harness.zig");
const maps = @import("subsystems").value.maps;
const order = @import("subsystems").value.order;
const repr = @import("repr");
const strings = @import("subsystems").value.strings;
const tables = @import("subsystems").value.tables;
const tuples = @import("subsystems").value.tuples;
const utils = @import("subsystems").utils;
const value = @import("subsystems").value;
const vm_lifecycle = @import("subsystems").lifecycle;
const wrap = @import("subsystems").value.wrap;

// ==========================================================================
// Constants
// ==========================================================================

/// The hosts whose `cryptorand` draws from `arc4random_buf`, written out here
/// rather than read from `utils.zig`, which keeps its own copy private.
const bsd = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .netbsd, .openbsd, .dragonfly => true,
    else => false,
};

const big_table = [_]SearchBig{
    .{ .name = "alpha", .a = 0, .b = 0, .d = 0 },
    .{ .name = "beta", .a = 0, .b = 0, .d = 0 },
    .{ .name = "gamma", .a = 0, .b = 0, .d = 0 },
};

const head_probe_at = abstract_type.define(anyopaque, .{ .name = "utils/head-probe" });

const small_table = [_]SearchSmall{
    .{ .name = "alpha", .value = 1 },
    .{ .name = "beta", .value = 2 },
    .{ .name = "delta", .value = 3 },
    .{ .name = "gamma", .value = 4 },
    .{ .name = "omega", .value = 5 },
};

// ==========================================================================
// Types
// ==========================================================================

const SearchBig = extern struct {
    name: [*]const u8,
    a: f64,
    b: f64,
    d: f64,
};

const SearchSmall = extern struct {
    name: [*]const u8,
    value: c_int,
};

// ==========================================================================
// Cases
// ==========================================================================

/// The distance from a head to the payload Janet hands around, which is what
/// each accessor subtracts.
///
/// `@sizeOf` here is the oracle and has to stay `@sizeOf`. The runtime
/// subtracts `types.<kind>_payload`, which is `@offsetOf(Head, "_data")`, and
/// this file asserts that what the accessor moved by equals the *other*
/// spelling. Rewriting these four to the constant would compare it with itself
/// and the check would pass forever.
fn payloadOffset(head: anytype, payload: anytype) usize {
    return @intFromPtr(payload) - @intFromPtr(head);
}

fn theHeadAccessorsRecoverWhatTheConstructorsWrote() void {
    const s = strings.cstring("hello");
    const string_head = utils.stringHead(s);
    expect(string_head.length == 5);
    expect(payloadOffset(string_head, s) == @sizeOf(strings.StringHead));

    var items: [2]repr.Value = .{ harness.wrapInteger(1), harness.wrapInteger(2) };
    const tup = tuples.newFrom(&items);
    const tuple_head = utils.tupleHead(tup);
    expect(tuple_head.length == 2);
    expect(payloadOffset(tuple_head, tup) == @sizeOf(tuples.TupleHead));

    const abst = abstracts.newBytes(&head_probe_at, 8);
    const abstract_head = utils.abstractHead(abst);
    expect(abstract_head.size == 8);
    expect(payloadOffset(abstract_head, abst) == @sizeOf(abi.AbstractHead));
}

/// The three hash helpers, which need no heap and run before a VM exists.
///
/// `value.hashBytes` has two implementations and the configuration picks
/// one. The condition is `config.prf` rather than a field of `options`: the
/// subsystem is compiled either way and what changes is which body it
/// compiles, so no `Selection` field covers it. The hash key size exists only
/// under the same condition, so the key is declared inside the branch.
fn theHashesAreTheOnesTheirCallersExpect() void {
    expect(value.hashMix(0, 0) == 0x53a3c667);
    expect(value.hashMix(1, 2) == 0x53a3d6f6);
    expect(value.hashMix(
        std.math.maxInt(u32),
        std.math.maxInt(u32),
    ) == 0x9c5c4a29);

    const a = "a";
    const hello = "hello";
    const embedded_nul = "Janet\x00Z";

    if (comptime !config.prf) {
        expect(value.hashBytes("") == 5381);
        expect(value.hashBytes(a) == 2136581281);
        expect(value.hashBytes(hello) == 1719582043);
        expect(value.hashBytes(embedded_nul) == -1777808027);
    } else {
        var key: [constants.hash_key_size]u8 = @splat(0);
        for (0..8) |i| key[i] = @intCast(i);
        value.initHashKey(&key);
        expect(value.hashBytes(a) == 1520149057);
        expect(value.hashBytes(hello) == 1601058579);
        expect(value.hashBytes(embedded_nul) == -1601329231);
    }
}

/// `value.capacityFor` takes a `usize`, so there is no negative argument to
/// round down and no route to a bucket array of no buckets. Its result is at
/// least one for everything it can be given.
fn tablenRoundsUpToAPowerOfTwo() void {
    expect(value.capacityFor(0) == 1);
    expect(value.capacityFor(1) == 2);
    expect(value.capacityFor(2) == 4);
    expect(value.capacityFor(3) == 4);
    expect(value.capacityFor(1024) == 2048);
    // The one value that cannot be rounded up, and comes back unchanged.
    expect(value.capacityFor(std.math.maxInt(i32)) == std.math.maxInt(i32));
}

fn cstrcmpStopsAtWhicheverEndComesFirst() void {
    // A Janet string has its length in its head and a C string ends at a NUL,
    // so the comparison stops at whichever comes first and equality needs both
    // to end together.
    expect(utils.cstrcmp(strings.cstring("abc"), "abc") == 0);
    expect(utils.cstrcmp(strings.cstring(""), "") == 0);
    expect(utils.cstrcmp(strings.cstring("abc"), "abd") == -1);
    expect(utils.cstrcmp(strings.cstring("abd"), "abc") == 1);

    // A prefix on either side. The shorter Janet string runs out first and the
    // result is decided after the loop; the shorter C string is found by the
    // NUL test inside it.
    expect(utils.cstrcmp(strings.cstring("ab"), "abc") == -1);
    expect(utils.cstrcmp(strings.cstring("abc"), "ab") == 1);

    // A Janet string may contain a NUL, and then it compares *equal* to the C
    // string that stops there: the loop breaks with both bytes zero, and
    // nothing follows in the C string to decide otherwise.
    const embedded = strings.new("a\x00b");
    expect(utils.stringHead(embedded).length == 3);
    expect(utils.cstrcmp(embedded, "a") == 0);
    expect(utils.cstrcmp(embedded, "a\x00b") == 0);
}

// `utils.strbinsearch` takes an array of structs whose first member is a
// `char *`, sorted by it. Two shapes, to show the item size is respected
// rather than assumed.

fn findSmall(count: usize, key: [*:0]const u8) ?*const SearchSmall {
    const hit = utils.strbinsearch(
        &small_table,
        count,
        @sizeOf(SearchSmall),
        strings.cstring(key),
    );
    return @ptrCast(@alignCast(hit));
}

fn strbinsearchRespectsTheItemSize() void {
    expect(findSmall(5, "alpha").?.value == 1);
    expect(findSmall(5, "omega").?.value == 5);
    expect(findSmall(5, "delta").?.value == 3);
    expect(findSmall(5, "zeta") == null);
    expect(findSmall(5, "aa") == null);
    expect(findSmall(5, "") == null);
    // An empty table finds nothing rather than reading the first element.
    expect(findSmall(0, "alpha") == null);

    const bighit: ?*const SearchBig = @ptrCast(@alignCast(utils.strbinsearch(
        &big_table,
        3,
        @sizeOf(SearchBig),
        strings.cstring("gamma"),
    )));
    expect(bighit == &big_table[2]);
}

/// The three buckets the probe can return: the key's own, the first
/// tombstone, and a never-used one. Only a caller inside the runtime sees
/// which it got.
fn theProbeDistinguishesATombstoneFromAnEmptyBucket() void {
    const t = tables.new(8);
    const present = value.fromBytes("present", .keyword);
    const absent = value.fromBytes("absent", .keyword);

    tables.put(t, present, harness.wrapInteger(1));

    var kv = value.dictionaryFind(t.slots(), present);
    expect(kv != null);
    expect(harness.equals(kv.?.key, present));
    expect(wrap.toInteger(kv.?.value) == 1);

    // An absent key lands on a bucket whose key is nil, which is what makes
    // it a place to put one.
    kv = value.dictionaryFind(t.slots(), absent);
    expect(kv != null);
    expect(harness.isType(kv.?.key, repr.Tag.nil));

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
        kv = value.dictionaryFind(t.slots(), harness.wrapInteger(i));
        expect(kv != null);
        expect(harness.equals(kv.?.key, harness.wrapInteger(i)));
        expect(wrap.toInteger(kv.?.value) == i * 10);
    }
}

/// `value.dictionaryGet` is the wrapper over the probe that turns "found a nil
/// key" into nil.
fn dictionaryGetTurnsAMissIntoNil() void {
    const t = tables.new(2);
    _ = tables.put(t, value.fromBytes("a", .keyword), harness.wrapInteger(1));
    _ = tables.put(t, value.fromBytes("b", .keyword), harness.wrapInteger(2));

    expect(wrap.toInteger(
        value.dictionaryGet(t.slots(), value.fromBytes("a", .keyword)),
    ) == 1);
    expect(harness.isType(
        value.dictionaryGet(t.slots(), value.fromBytes("z", .keyword)),
        repr.Tag.nil,
    ));
}

/// `value.dictionaryFindKeyword` matches by bytes without interning, so a
/// lookup needs neither a `Janet` nor a symbol table entry.
fn theKeywordProbeComparesLengthBeforeBytes() void {
    const kt = tables.new(4);
    tables.put(kt, value.fromBytes("kw", .keyword), harness.wrapInteger(9));

    var kv = value.dictionaryFindKeyword(kt.slots(), "kw", 2);
    expect(kv != null);
    expect(wrap.toInteger(kv.?.value) == 9);

    kv = value.dictionaryFindKeyword(kt.slots(), "nope", 4);
    expect(kv != null);
    expect(harness.isType(kv.?.key, repr.Tag.nil));

    // A prefix of a stored key must miss: the length is compared before the
    // bytes.
    kv = value.dictionaryFindKeyword(kt.slots(), "k", 1);
    expect(kv != null);
    expect(harness.isType(kv.?.key, repr.Tag.nil));
}

fn dictionaryNextSkipsTombstones() void {
    const t = tables.new(8);
    var kv: ?*const tables.Keyval = null;

    // An empty dictionary ends immediately.
    expect(value.dictionaryNext(t.slots(), null) == null);

    tables.put(t, value.fromBytes("a", .keyword), harness.wrapInteger(1));
    tables.put(t, value.fromBytes("b", .keyword), harness.wrapInteger(2));
    tables.put(t, value.fromBytes("c", .keyword), harness.wrapInteger(3));

    var seen: i32 = 0;
    kv = value.dictionaryNext(t.slots(), null);
    while (kv != null) : (kv = value.dictionaryNext(t.slots(), kv)) {
        expect(!harness.isType(kv.?.key, repr.Tag.nil));
        seen += 1;
    }
    expect(seen == 3);

    // A deleted entry is skipped: its key is nil even though its value is not.
    tables.put(t, value.fromBytes("b", .keyword), wrap.fromNil());
    seen = 0;
    kv = value.dictionaryNext(t.slots(), null);
    while (kv != null) : (kv = value.dictionaryNext(t.slots(), kv)) {
        seen += 1;
    }
    expect(seen == 2);
}

fn sortedKeysAnswersBucketIndicesInKeyOrder() void {
    const t = tables.new(8);
    var buffer: [32]i32 = undefined;

    // An empty dictionary sorts to nothing and writes nothing.
    expect(utils.sortedKeys(t.data.?, @intCast(t.capacity), &buffer) == 0);

    var i: i32 = 5;
    while (i >= 0) : (i -= 1) {
        tables.put(t, harness.wrapInteger(i), harness.wrapInteger(i));
    }
    var n = utils.sortedKeys(t.data.?, @intCast(t.capacity), &buffer);
    expect(n == 6);
    // What comes back is bucket *indices*, in key order.
    i = 0;
    while (i < n) : (i += 1) {
        const key = t.slots()[@intCast(buffer[@intCast(i)])].key;
        expect(wrap.toInteger(key) == i);
    }

    // Deleted entries are not counted.
    tables.put(t, harness.wrapInteger(3), wrap.fromNil());
    n = utils.sortedKeys(t.data.?, @intCast(t.capacity), &buffer);
    expect(n == 5);
    i = 1;
    while (i < n) : (i += 1) {
        const previous = t.slots()[@intCast(buffer[@intCast(i - 1)])].key;
        const current = t.slots()[@intCast(buffer[@intCast(i)])].key;
        expect(order.compare(previous, current) < 0);
    }
}

fn theCollectionHashesAreWhatTheHeadsStore() void {
    var items: [3]repr.Value = .{
        harness.wrapInteger(1),
        harness.wrapInteger(2),
        harness.wrapInteger(3),
    };

    // The seed is 33, so a zero-length run hashes to it. That is the one
    // value of the collection hash a caller can predict.
    expect(value.hashIndexed(items[0..0]) == 33);

    // A tuple's stored hash is what `value.hashIndexed` computed, and the
    // head it is stored in is recovered by the accessor above.
    const tup = tuples.newFrom(&items);
    expect(utils.tupleHead(tup).hash == value.hashIndexed(tup[0..3]));

    // A map keeps a running sum rather than a hash over a bucket array, and
    // its stored hash is that sum mixed with its count.
    const built = maps.build(.map, &.{ value.fromBytes("k", .keyword), harness.wrapInteger(1) });
    expect(maps.hashOf(built) == order.hash(wrap.fromMap(built)));
}

/// `utils.base64` and the three name tables, checked by position.
///
/// The expectations are written out rather than read from `utils.zig`: the
/// alphabet is the documented one, and the three tables are indexed by a
/// numeric tag rather than by a Zig enum, so nothing checks their *order*
/// except this. That is the independent derivation, and it is the way a table
/// indexed by an integer breaks.
fn theTablesAreIndexedByTheNumbersACallerHas() void {
    // 0-9, A-Z, a-z, `_`, `=`, and the terminator.
    expect(utils.base64[0] == '0');
    expect(utils.base64[10] == 'A');
    expect(utils.base64[36] == 'a');
    expect(utils.base64[62] == '_');
    expect(utils.base64[63] == '=');
    expect(utils.base64[64] == 0);

    // The tag order, which is not alphabetical and is not the order `repr.Tag`
    // would produce if it were sorted.
    const expected_types = [_][:0]const u8{
        "number",   "nil",       "boolean",  "buffer",  "string", "array",
        "vector",   "table",     "map",      "symbol",  "tuple",  "fiber",
        "function", "nfunction", "abstract", "pointer",
    };
    for (expected_types, 0..) |want, i| {
        expect(std.mem.eql(u8, utils.typeNames[i], want));
    }

    expect(std.mem.eql(u8, std.mem.span(utils.statusNames[0]), "dead"));
    expect(std.mem.eql(u8, std.mem.span(utils.statusNames[1]), "error"));
    expect(std.mem.eql(u8, std.mem.span(utils.signalNames[0]), "ok"));
    expect(std.mem.eql(u8, std.mem.span(utils.signalNames[1]), "error"));

    // Every entry is a real string in both tables: an array that grew a slot
    // without a name is the failure this catches.
    for (0..16) |i| expect(std.mem.span(utils.statusNames[i]).len > 0);
    for (0..14) |i| expect(std.mem.span(utils.signalNames[i]).len > 0);
}

// ==========================================================================
// Entry
// ==========================================================================

/// A bare name gets `./` in front of it in a fresh allocation. A name that
/// starts with a dot or holds a slash anywhere comes back as the same pointer.
///
/// Every name here has an even length and two have their slash at an odd
/// index, so a scan that skipped a byte would still stop at the terminator,
/// having missed the slash, rather than read on into whatever follows it.
fn getProcessedNameAnchorsABareName() void {
    const bare = utils.getProcessedName("food");
    expect(std.mem.eql(u8, std.mem.span(@as([*:0]const u8, @ptrCast(bare))), "./food"));
    utils.free(bare);
    for ([_][*:0]const u8{ ".foo", "a/bc", "abc/de", "ab/c", "/abs" }) |name| {
        expect(@intFromPtr(utils.getProcessedName(name)) == @intFromPtr(name));
    }
}

/// Janet's heap resizes in place to a block's own length or shorter, and
/// refuses to grow in place, because `realloc` may move the block.
fn theHeapResizesInPlaceOnlyDownward() void {
    const block = utils.heap.alloc(u8, 32) catch unreachable;
    expect(utils.heap.resize(block, 32));
    expect(utils.heap.resize(block, 16));
    const shrunk: []u8 = block[0..16];
    expect(!utils.heap.resize(shrunk, 64));
    utils.heap.free(shrunk);
}

/// On a BSD host, macOS among them, `cryptorand` draws from `arc4random_buf`
/// and opens nothing, so it answers with no descriptor free. The soft limit on
/// descriptors is lowered to the lowest free one for the call and put back.
/// Other hosts read `/dev/urandom` and skip the case.
fn cryptorandOpensNoDescriptorOnABsd() void {
    if (comptime bsd and config.cryptorand) {
        var saved: std.c.rlimit = undefined;
        expect(std.c.getrlimit(.NOFILE, &saved) == 0);
        const lowest = std.c.open("/dev/null", .{ .ACCMODE = .RDONLY });
        expect(lowest >= 0);
        _ = std.c.close(lowest);
        var lowered = saved;
        lowered.cur = @intCast(lowest);
        expect(std.c.setrlimit(.NOFILE, &lowered) == 0);
        const refused = std.c.open("/dev/urandom", .{ .ACCMODE = .RDONLY });
        var out: [16]u8 = undefined;
        const answer = utils.cryptorand(&out, out.len);
        expect(std.c.setrlimit(.NOFILE, &saved) == 0);
        if (refused >= 0) _ = std.c.close(refused);
        expect(refused < 0);
        expect(answer == 0);
    }
}

pub fn run() void {
    // The two cases that touch no heap, run before there is one. Nothing in
    // either needs a VM, and a hash that needed one would be a finding.
    theHashesAreTheOnesTheirCallersExpect();
    tablenRoundsUpToAPowerOfTwo();

    harness.init();

    theHeadAccessorsRecoverWhatTheConstructorsWrote();
    cstrcmpStopsAtWhicheverEndComesFirst();
    strbinsearchRespectsTheItemSize();
    theProbeDistinguishesATombstoneFromAnEmptyBucket();
    dictionaryGetTurnsAMissIntoNil();
    theKeywordProbeComparesLengthBeforeBytes();
    dictionaryNextSkipsTombstones();
    sortedKeysAnswersBucketIndicesInKeyOrder();
    theCollectionHashesAreWhatTheHeadsStore();
    theTablesAreIndexedByTheNumbersACallerHas();
    getProcessedNameAnchorsABareName();
    theHeapResizesInPlaceOnlyDownward();
    cryptorandOpensNoDescriptorOnABsd();

    vm_lifecycle.deinit();
}
