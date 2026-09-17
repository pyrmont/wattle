//! Janet's immutable dictionary, and the Robin Hood probe that makes two
//! structs built from the same pairs lay out identically.
//!
//! A struct is built in three calls: `begin` sizes the bucket array from a
//! declared pair count, `put` fills it, and `end` seals it and gives it its
//! hash. `newFrom` is the three in one call for a caller that has the pairs
//! already. `rawget` reads one back, `get` follows the prototype chain, `getEx`
//! also reports which struct in that chain the value came from, and `toTable`
//! copies the pairs into a mutable table.
//!
//! `tables.zig` is the sibling and the other half of the dictionary group. The
//! two call each other, `toTable` calling `tables.put` and `tables.toStruct`
//! calling `begin`, `put` and `end`, so they import each other, which Zig
//! allows.
//!
//! ## Why a struct is not an immutable table
//!
//! The two are different algorithms, so `find` sits beside
//! `value.dictionaryFind` rather than calling it. A struct probes Robin Hood
//! and has no tombstones. The ordering rule, displace the entry that is closer
//! to its ideal slot and break ties by hash and then by `order.compare` on the
//! keys, makes the final layout a function of the set of pairs rather than of
//! the order they arrived in.
//!
//! That is not an optimisation. `end` hashes the bucket array with
//! `value.hashDictionary`, so two structs built from the same pairs in
//! different orders have to lay out identically or `{1 2 3 4}` would not equal
//! `{3 4 1 2}`. The comparison tiebreak is what makes the order total. With no
//! tombstones the first nil key ends a probe, which makes `find` the simpler
//! of the two dictionary loops despite the harder insert. `tables.zig` records
//! the other discipline.
//!
//! `isNilKey` and `isUnstorableKey` are two-line predicates that this file and
//! `tables.zig` each declare for themselves, because neither file is the right
//! owner of a rule about the other's keys.
//!
//! ## The cfunction surface
//!
//! A published `CFunction` has no error channel in its signature, so the
//! `cfunStruct*` functions deliver a raise through `raise.Error!` and
//! `corefn.reg` stores them. Nothing in them is stranded across a call that
//! can raise.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const args_core = @import("../args.zig");
const config = @import("config");
const corefn = @import("../corefn.zig");
const gc_alloc = @import("../gc.zig");
const order = @import("helpers/order.zig");
const raise = @import("../../api/raise.zig");
const repr = @import("repr");
const tables = @import("tables.zig");
const value = @import("../value.zig");
const wrap = @import("helpers/wrap.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// Where the buckets begin within the block. `@offsetOf` and not `@sizeOf`:
/// the head is Zig's own declaration, so `_data` is an ordinary field whose
/// offset the compiler takes exactly.
pub const struct_payload = @offsetOf(StructHead, "_data");

// ==========================================================================
// Aliased types
// ==========================================================================

/// The bucket array Janet passes a struct around as.
pub const Struct = [*]const tables.Keyval;

// ==========================================================================
// Types
// ==========================================================================

/// The struct twin of `tables.Found`: a value, and which struct in the
/// prototype chain it came from.
pub const Found = struct {
    value: repr.Value,
    holder: ?Struct,
};

/// A struct's head: the collector's object, the length, the hash, the probe
/// capacity and the prototype, with the buckets following it in the same
/// allocation.
///
/// Between `begin` and `end`, `hash` is the running count of filled slots
/// rather than a hash, so a struct observed there may not be put in a
/// dictionary.
pub const StructHead = extern struct {
    gc: abi.GCObject = .{},
    length: u32 = 0,
    hash: i32 = 0,
    capacity: u32 = 0,
    proto: ?[*]const tables.Keyval = null,
    _data: [0]tables.Keyval = std.mem.zeroes([0]tables.Keyval),
};

// ==========================================================================
// Public functions
// ==========================================================================

/// Allocates a struct's bucket array and its head in one block.
///
/// `count` is the declared pair count. The capacity is the smallest power of
/// two strictly greater than twice that: `value.capacityFor` is a strict
/// next-power-of-two, so a count of two gets eight buckets rather than four.
/// That keeps the load factor below one half always, and at one quarter
/// whenever `2 * count` is itself a power of two, which is what bounds the
/// Robin Hood displacement chains.
///
/// The capacity arithmetic cannot overflow for any count a caller can supply.
/// The doubling is a wrapping `*%` on `usize`, which no reachable count comes
/// near, and `value.capacityFor` saturates at `maxInt(i32)`, so a count no
/// allocator could satisfy fails in the allocator rather than silently
/// building a struct with no buckets.
///
/// The count sits in the hash field until `end` runs. `hash` starts at zero
/// and every `put` that fills an empty slot increments it, which is also how
/// `put` enforces the declared length: `put` returns early once the count
/// reaches `count`, so a struct given more pairs than it was begun with
/// silently drops the surplus.
pub fn begin(count: usize) [*]tables.Keyval {
    const capacity = value.capacityFor(2 *% count);

    const hd = gc_alloc.gcallocWithPayload(
        StructHead,
        .@"struct",
        capacity *% @sizeOf(tables.Keyval),
    );
    hd.length = @intCast(count);
    hd.capacity = @intCast(capacity);
    hd.hash = 0;
    hd.proto = null;

    const st = data(hd);
    value.memempty(st[0..capacity]);
    return st;
}

/// The inverse of `head`, for a block the allocator has just returned.
///
/// `hd` is the head. It is `*const` and the result is mutable: the allocator's
/// caller writes through the result, and a comparison or a hash is given a
/// const head.
pub inline fn data(hd: *const StructHead) [*]tables.Keyval {
    return @ptrFromInt(@intFromPtr(hd) +% struct_payload);
}

/// Seals a struct and gives it its hash.
///
/// `st_in` is the array `begin` returned. Where fewer pairs landed than were
/// declared, through duplicates or rejected keys, the bucket array is the
/// wrong size for its contents, so the whole struct is rebuilt at the size it
/// actually needs. The second build always succeeds, because the count it is
/// given is the count that fit. The prototype is copied across by hand, since
/// it is not a bucket.
///
/// The prototype contributes to the hash by a multiply rather than by being
/// walked, so a struct's hash is O(capacity) and not O(prototype depth).
pub fn end(st_in: [*]tables.Keyval) [*]const tables.Keyval {
    var st = st_in;
    if (head(st).hash != head(st).length) {
        const newst = begin(@intCast(head(st).hash));
        for (st[0..head(st).capacity]) |*kv| {
            if (!isNilKey(kv.key)) put(newst, kv.key, kv.value);
        }
        head(newst).proto = head(st).proto;
        st = newst;
    }
    const hd = head(st);
    hd.hash = value.hashDictionary(st[0..hd.capacity]);
    if (hd.proto) |proto| {
        hd.hash = @bitCast(@as(u32, @bitCast(hd.hash)) +%
            2654435761 *% @as(u32, @bitCast(head(proto).hash)));
    }
    return st;
}

/// Returns the bucket with `key` in it, or the first empty bucket on its probe
/// path.
///
/// `st` is the bucket array. A struct has no tombstones, so the first nil key
/// ends the search and there is no reusable-bucket bookkeeping. Null comes
/// back only where the array is entirely full, which `begin`'s capacity policy
/// prevents for any struct built through the public constructors.
pub fn find(st: [*]const tables.Keyval, key: repr.Value) ?*const tables.Keyval {
    const cap = head(st).capacity;
    const index = mapHash(cap, order.hash(key));
    for (st[index..cap]) |*kv| {
        if (isNilKey(kv.key) or order.equals(kv.key, key)) return kv;
    }
    for (st[0..index]) |*kv| {
        if (isNilKey(kv.key) or order.equals(kv.key, key)) return kv;
    }
    return null;
}

/// Looks `key` up in `st_in`, following prototypes to `config.max_proto_depth`.
pub fn get(st_in: [*]const tables.Keyval, key: repr.Value) repr.Value {
    var st: ?Struct = st_in;
    var i: c_int = config.max_proto_depth;
    while (i != 0) : (i -= 1) {
        const cur = st orelse break;
        st = head(cur).proto;
        const kv = find(cur, key) orelse continue;
        if (!isNilKey(kv.key)) return kv.value;
    }
    return wrap.fromNil();
}

/// The same as `get`, also reporting which struct in the prototype chain the
/// value came from.
pub fn getEx(st_in: [*]const tables.Keyval, key: repr.Value) Found {
    var st: ?Struct = st_in;
    var i: c_int = config.max_proto_depth;
    while (i != 0) : (i -= 1) {
        const cur = st orelse break;
        st = head(cur).proto;
        const kv = find(cur, key) orelse continue;
        if (!isNilKey(kv.key)) {
            return .{ .value = kv.value, .holder = cur };
        }
    }
    return .{ .value = wrap.fromNil(), .holder = null };
}

/// Recovers a struct's head from its bucket array.
pub inline fn head(st: [*]const tables.Keyval) *StructHead {
    return @ptrFromInt(@intFromPtr(st) -% struct_payload);
}

/// Installs the `struct/` cfunctions into `env`.
pub fn lib(env: *tables.Table) void {
    const entries = comptime [_]corefn.Entry{
        corefn.reg("struct/with-proto", &cfunStructWithProto, @src(), "(struct/with-proto proto & kvs)", "Create a structure, as with the usual struct constructor but set the " ++
            "struct prototype as well."),
        corefn.reg("struct/getproto", &cfunStructGetproto, @src(), "(struct/getproto st)", "Return the prototype of a struct, or nil if it doesn't have one."),
        corefn.reg("struct/proto-flatten", &cfunStructFlatten, @src(), "(struct/proto-flatten st)", "Convert a struct with prototypes to a struct with no prototypes by merging " ++
            "all key value pairs from recursive prototypes into one new struct."),
        corefn.reg("struct/to-table", &cfunStructToTable, @src(), "(struct/to-table st &opt recursive)", "Convert a struct to a table. If recursive is true, also convert the " ++
            "table's prototypes into the new struct's prototypes as well."),
        corefn.reg("struct/rawget", &cfunStructRawget, @src(), "(struct/rawget st key)", "Gets a value from a struct `st` without looking at the prototype struct. " ++
            "If `st` does not contain the key directly, the function will return " ++
            "nil without checking the prototype. Returns the value in the struct."),
    };
    corefn.install(env, entries);
}

/// Builds a struct from `kvs`, which is what `module.structOf` reaches through
/// `capi.zig`'s `new_struct`.
///
/// The pairs are not a hash array. A struct's storage is `capacity` slots with
/// empties among them; `kvs` is `kvs.len` pairs with nothing empty among them, and
/// `begin` sizes the table from that count. A repeated key replaces without
/// filling a new slot, so the struct is under-filled and `end` re-begins it at
/// the true count, so a caller may pass duplicates and get what a struct
/// literal gives. A nil value or an unstorable key drops its pair,
/// exactly as a literal does.
pub fn newFrom(kvs: []const tables.Keyval) [*]const tables.Keyval {
    const st = begin(kvs.len);
    for (kvs) |kv| put(st, kv.key, kv.value);
    return end(st);
}

/// Inserts into a struct under construction, replacing the value of a
/// duplicate key. `putExt` is the version that takes that choice as an
/// argument.
pub fn put(st: [*]tables.Keyval, key: repr.Value, val: repr.Value) void {
    putExt(st, key, val, true);
}

/// Inserts into a struct that is still under construction.
///
/// `st` is the bucket array, `key_in` and `value_in` the pair, and `replace`
/// whether a duplicate key's value is overwritten. `put` passes true;
/// `struct/proto-flatten` passes false, so that a prototype's binding cannot
/// displace the child's.
///
/// Nil keys, nil values and NaN keys are dropped, and so is everything past
/// the declared length. Collisions are resolved by Robin Hood displacement,
/// which is an in-place insertion sort: the pair further from its ideal slot
/// keeps the slot, ties broken by hash and then by `order.compare` on the
/// keys. The result is that the bucket array depends only on the set of pairs,
/// which is what makes two equal structs hash equal.
///
/// Comparing two keys dispatches to an abstract type's `compare` for an
/// abstract key. `abi.zig` declares that callback `callconv(.c)`, so it has no
/// way to raise, and nothing here is stranded across it.
pub fn putExt(st: [*]tables.Keyval, key_in: repr.Value, value_in: repr.Value, replace: bool) void {
    var key = key_in;
    var val = value_in;
    const hd = head(st);
    const cap = hd.capacity;
    var hash = order.hash(key);
    const index = mapHash(cap, hash);
    const bounds = [4]u32{ index, cap, 0, index };
    if (isUnstorableKey(key) or repr.checkType(val, repr.Tag.nil)) return;
    // Refuse anything past the declared length.
    if (hd.hash == hd.length) return;

    var dist: u32 = 0;
    var j: usize = 0;
    while (j < 4) : (j += 2) {
        var i = bounds[j];
        while (i < bounds[j + 1]) : ({
            i += 1;
            dist += 1;
        }) {
            const kv = &st[i];

            // An empty slot ends the walk: take it and grow the count.
            if (isNilKey(kv.key)) {
                kv.key = key;
                kv.value = val;
                hd.hash += 1;
                return;
            }

            const otherhash = order.hash(kv.key);
            const otherindex = mapHash(cap, otherhash);
            const otherdist = (i +% cap -% otherindex) & (cap -% 1);
            const status: c_int = if (dist < otherdist)
                -1
            else if (otherdist < dist)
                1
            else if (hash < otherhash)
                -1
            else if (otherhash < hash)
                1
            else
                order.compare(key, kv.key);

            if (status == 1) {
                // The occupant is further from home, so it keeps the slot and
                // the pair in transit takes over its displacement and hash.
                const temp = kv.*;
                kv.key = key;
                kv.value = val;
                key = temp.key;
                val = temp.value;
                dist = otherdist;
                hash = otherhash;
            } else if (status == 0) {
                if (replace) kv.value = val;
                return;
            }
        }
    }
}

/// Looks `key` up in `st` alone, without following prototypes.
pub fn rawget(st: [*]const tables.Keyval, key: repr.Value) repr.Value {
    const kv = find(st, key) orelse return wrap.fromNil();
    return kv.value;
}

/// Copies `st`'s own pairs into a fresh table. The prototype is not copied;
/// `struct/to-table` rebuilds the chain itself where asked to.
pub fn toTable(st: [*]const tables.Keyval) *tables.Table {
    const cap = head(st).capacity;
    const table = tables.new(@intCast(cap));
    for (st[0..cap]) |*kv| {
        if (!isNilKey(kv.key)) tables.put(table, kv.key, kv.value);
    }
    return table;
}

// ==========================================================================
// Private functions
// ==========================================================================

/// `struct/proto-flatten`: every pair in the chain merged into one struct with
/// no prototype.
///
/// The pair-count bound is an upper bound and deliberately loose: a key that
/// appears in both a struct and its prototype is counted twice, so the
/// accumulator is over-allocated rather than resized. `end` compacts it.
fn cfunStructFlatten(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const st = try args_core.getStruct(argv, 0);

    var pair_count: i64 = 0;
    var cursor: ?Struct = st;
    while (cursor) |current| {
        pair_count += head(current).length;
        cursor = head(current).proto;
    }
    if (pair_count > std.math.maxInt(i32)) return raise.panic("struct too large");

    const accum = begin(@intCast(pair_count));
    cursor = st;
    while (cursor) |current| {
        for (current[0..head(current).capacity]) |*kv| {
            if (!repr.checkType(kv.key, repr.Tag.nil)) {
                putExt(accum, kv.key, kv.value, false);
            }
        }
        cursor = head(current).proto;
    }
    return wrap.fromStruct(end(accum));
}

/// `struct/getproto`: the prototype, or nil where there is none.
fn cfunStructGetproto(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const st = try args_core.getStruct(argv, 0);
    const proto = head(st).proto;
    return if (proto) |p| wrap.fromStruct(p) else wrap.fromNil();
}

/// `struct/rawget`: a lookup that does not follow the prototype chain.
fn cfunStructRawget(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 2);
    const st = try args_core.getStruct(argv, 0);
    return rawget(st, argv[1]);
}

/// `struct/to-table`: the pairs as a mutable table.
///
/// The loop body runs at least once, so a struct with no prototype still
/// produces one table, and `recursive` decides only whether the walk continues
/// past the first.
fn cfunStructToTable(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, 2);
    const st = try args_core.getStruct(argv, 0);
    const recursive = argv.len > 1 and repr.truthy(argv[1]);
    var tab: ?*tables.Table = null;
    var cursor: Struct = st;
    var tab_cursor: ?*tables.Table = null;
    while (true) {
        if (tab != null) {
            tab_cursor.?.proto = tables.new(head(cursor).length);
            tab_cursor = tab_cursor.?.proto;
        } else {
            tab = tables.new(head(cursor).length);
            tab_cursor = tab;
        }
        for (cursor[0..head(cursor).capacity]) |*kv| {
            if (!repr.checkType(kv.key, repr.Tag.nil)) {
                tables.put(tab_cursor.?, kv.key, kv.value);
            }
        }
        if (!recursive) break;
        cursor = head(cursor).proto orelse break;
    }
    // The loop body runs at least once and its first pass is the branch that
    // assigns `tab`, so the only way out of the loop is with a table made.
    return wrap.fromTable(tab orelse unreachable);
}

/// `struct/with-proto`: the struct constructor with a prototype in front of
/// the pairs.
fn cfunStructWithProto(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, -1);
    const proto = try args_core.optStruct(argv, 0, null);
    if (argv.len & 1 == 0) return raise.panic("expected odd number of arguments");
    const st = begin(@intCast(argv.len / 2));
    var i: usize = 1;
    while (i + 1 < argv.len) : (i += 2) {
        put(st, argv[i], argv[i + 1]);
    }
    head(st).proto = proto;
    return wrap.fromStruct(end(st));
}

/// Whether `key` is the nil that marks an empty bucket.
inline fn isNilKey(key: repr.Value) bool {
    return repr.checkType(key, repr.Tag.nil);
}

/// The two keys a dictionary refuses to store. Nil is the absent-key sentinel,
/// and a NaN is refused because it does not compare equal to itself, so a
/// lookup could never find it again.
inline fn isUnstorableKey(key: repr.Value) bool {
    if (repr.checkType(key, repr.Tag.nil)) return true;
    return repr.checkType(key, repr.Tag.number) and
        std.math.isNan(wrap.toNumber(key));
}

/// A hash folded into a bucket index. The capacity is always a power of two,
/// so the mask is exact and the result is always in range.
inline fn mapHash(cap: u32, hash: i32) u32 {
    return @as(u32, @bitCast(hash)) & (cap -% 1);
}

// ==========================================================================
// Tests
// ==========================================================================

// `StructHead` against the signed head the marshaller and the collector were
// written for: same widths, same offsets, and `proto` still where they expect
// it. `hash` stays signed, and while a struct is being built it is the running
// count of filled slots rather than a hash, which is the one place the two
// meanings meet.
comptime {
    const SignedHead = extern struct {
        gc: abi.GCObject = .{},
        length: i32 = 0,
        hash: i32 = 0,
        capacity: i32 = 0,
        proto: ?[*]const tables.Keyval = null,
        _data: [0]tables.Keyval = std.mem.zeroes([0]tables.Keyval),
    };
    std.debug.assert(@offsetOf(StructHead, "_data") == @offsetOf(SignedHead, "_data"));
    std.debug.assert(@offsetOf(StructHead, "proto") == @offsetOf(SignedHead, "proto"));
    std.debug.assert(@sizeOf(StructHead) == @sizeOf(SignedHead));
}
