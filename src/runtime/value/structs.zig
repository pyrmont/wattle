//! Structs: Janet's immutable dictionary, and the Robin Hood probe that makes
//! two structs built from the same pairs lay out identically.
//!
//! `tables.zig` is the sibling and the other half of the dictionary group. The
//! two call each other -- `toTable` calls `tables.put`, `tables.toStruct` calls
//! `begin`, `put` and `end` -- so they import each other, which Zig allows.
//!
//! **A struct is not "an immutable table".** The two are not the same
//! algorithm, which is why `find` exists beside `value.dictionaryFind` rather
//! than calling it.
//!
//! **A struct probes Robin Hood and has no tombstones.** Nothing is ever
//! removed from a struct, and the ordering rule -- displace the entry that is
//! closer to its ideal slot, breaking ties by hash and then by `order.compare`
//! on the keys -- makes the final layout a function of the *set* of pairs
//! rather than of the order they arrived in. That is not an optimisation:
//! `end` hashes the bucket array with `value.hashDictionary`, so two structs
//! built from the same pairs in different orders must lay out identically or
//! `{1 2 3 4}` would not equal `{3 4 1 2}`. The comparison tiebreak is what
//! makes the order total, and `find` is the simpler of the two dictionary loops
//! despite the harder insert: with no tombstones, the first nil key is the end.
//! `tables.zig` records the other discipline.
//!
//! `asSize`, `isNilKey` and `isUnstorableKey` are two-line predicates each file
//! holds its own copy of, because neither is the right owner of a rule about
//! the other's keys and a fifteenth file in `value/` for six lines would earn
//! no name.

const std = @import("std");
const config = @import("config");
const corefn = @import("../corefn.zig");
const repr = @import("repr");
const raise = @import("../../api/raise.zig");
const args_core = @import("../args.zig");
const gc_alloc = @import("../gc.zig");
const wrap = @import("helpers/wrap.zig");
const tables = @import("tables.zig");
const order = @import("helpers/order.zig");
const value = @import("../value.zig");
const abi = @import("abi");

/// A struct's head: the collector's object, the length, the hash, the probe
/// capacity and the prototype, with the buckets following it in the same
/// allocation.
pub const StructHead = extern struct {
    gc: abi.GCObject = .{},
    length: u32 = 0,
    hash: i32 = 0,
    capacity: u32 = 0,
    proto: ?[*]const tables.KV = null,
    _data: [0]tables.KV = std.mem.zeroes([0]tables.KV),
};

comptime {
    // As `StringHead`: same widths, same offsets, and `proto` still sits where
    // the marshaller and the collector expect it. `hash` stays signed, and
    // while a struct is being built it holds the running count of filled slots
    // rather than a hash, which is the one place the two meanings meet.
    const SignedHead = extern struct {
        gc: abi.GCObject = .{},
        length: i32 = 0,
        hash: i32 = 0,
        capacity: i32 = 0,
        proto: ?[*]const tables.KV = null,
        _data: [0]tables.KV = std.mem.zeroes([0]tables.KV),
    };
    std.debug.assert(@offsetOf(StructHead, "_data") == @offsetOf(SignedHead, "_data"));
    std.debug.assert(@offsetOf(StructHead, "proto") == @offsetOf(SignedHead, "proto"));
    std.debug.assert(@sizeOf(StructHead) == @sizeOf(SignedHead));
}

/// Where the buckets begin within the block. `@offsetOf` and not `@sizeOf`:
/// the head is Zig's own declaration, so `_data` is an ordinary field whose
/// offset the compiler takes exactly.
pub const struct_payload = @offsetOf(StructHead, "_data");

/// The bucket array Janet passes a struct around as.
pub const Struct = [*]const tables.KV;

/// Recover a struct's head from its bucket array.
pub inline fn head(st: [*]const tables.KV) *StructHead {
    return @ptrFromInt(@intFromPtr(st) -% struct_payload);
}

/// The inverse, for a block the allocator has just returned. It takes a
/// `*const` head and hands back a mutable payload: the allocator's caller has
/// to write through it, and a const head is what a comparison or a hash holds.
pub inline fn data(hd: *const StructHead) [*]tables.KV {
    return @ptrFromInt(@intFromPtr(hd) +% struct_payload);
}

/// A hash folded into a bucket index. The capacity is always a power of two, so
/// the mask is exact and the result is always in range.
inline fn mapHash(cap: u32, hash: i32) u32 {
    return @as(u32, @bitCast(hash)) & (cap -% 1);
}

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

/// Allocate a struct's bucket array and its head in one block.
///
/// The capacity is the smallest power of two *strictly greater* than twice the
/// declared pair count -- `value.capacityFor` is a strict next-power-of-two, so a
/// count of two gets eight buckets rather than four. That keeps the load factor
/// below one half always and at one quarter whenever `2 * count` is itself a
/// power of two, which is what bounds the Robin Hood displacement chains.
///
/// **The capacity arithmetic cannot overflow for any count a caller can
/// supply.** The doubling is a wrapping `*%` on `usize`, which no reachable
/// count comes near, and `value.capacityFor` saturates at `INT32_MAX` -- so a
/// count no allocator could satisfy fails in the allocator rather than silently
/// building a struct with no buckets.
///
/// **The count lives in the hash field until `end` runs.** `hash` starts at
/// zero and every `put` that fills an empty slot increments it, which is also
/// how `put` enforces the declared length -- it returns early once the count
/// reaches `count`, so a struct given more pairs than it was begun with
/// silently drops the surplus. A struct observed between `begin` and `end`
/// therefore has a hash that is a count, and nothing may put one in a
/// dictionary there.
pub fn begin(count: usize) [*]tables.KV {
    const capacity = value.capacityFor(2 *% count);

    const hd = gc_alloc.gcallocWithPayload(
        StructHead,
        .@"struct",
        capacity *% @sizeOf(tables.KV),
    );
    hd.length = @intCast(count);
    hd.capacity = @intCast(capacity);
    hd.hash = 0;
    hd.proto = null;

    const st = data(hd);
    value.memempty(st[0..capacity]);
    return st;
}

/// A struct from a caller's pairs, which is what the module boundary's
/// `structOf` answers.
///
/// **The pairs are not a hash array.** A `DictView` is `cap` slots with
/// empties among them; this is `kvs.len` pairs with nothing empty among them,
/// and `begin` sizes the table from that count. A repeated key replaces
/// without filling a new slot, so the struct is under-filled and `end`
/// re-begins it at the true count -- which is why a caller may pass
/// duplicates and get what a struct literal gives.
///
/// A nil value or an unstorable key drops its pair, exactly as a literal does.
pub fn newFrom(kvs: []const tables.KV) [*]const tables.KV {
    const st = begin(kvs.len);
    for (kvs) |kv| put(st, kv.key, kv.value);
    return end(st);
}

/// Find the bucket holding `key`, or the first empty bucket on its probe path.
///
/// A struct has no tombstones, so the first nil key ends the search and there
/// is no reusable-bucket bookkeeping. Returns null only when the array is
/// entirely full, which `begin`'s capacity policy prevents for any
/// struct built through the public constructors.
pub fn find(st: [*]const tables.KV, key: repr.Value) ?*const tables.KV {
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

/// Insert into a struct that is still under construction.
///
/// Nil keys, nil values and NaN keys are dropped, and so is everything past the
/// declared length. Collisions are resolved by Robin Hood displacement, which
/// is an in-place insertion sort: the pair further from its ideal slot keeps
/// the slot, ties broken by hash and then by `order.compare` on the keys. The
/// result is that the bucket array depends only on the set of pairs, which is
/// what makes two equal structs hash equal.
///
/// `replace` distinguishes the two entry points: `put` overwrites a duplicate
/// key's value, and `struct/proto-flatten` passes false so that a prototype's
/// binding cannot displace the child's.
///
/// **A third-party callback runs in the middle of this.** Comparing two keys
/// dispatches to an abstract type's `compare` for an abstract key. Such a
/// callback may not raise, and nothing here holds anything across one.
pub fn putExt(st: [*]tables.KV, key_in: repr.Value, value_in: repr.Value, replace: bool) void {
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
                // The occupant is further from home: it keeps the slot and the
                // pair we are carrying takes over its displacement and hash.
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

/// Insert, replacing the value of a duplicate key.
pub fn put(st: [*]tables.KV, key: repr.Value, val: repr.Value) void {
    putExt(st, key, val, true);
}

/// Seal a struct and give it its hash.
///
/// If fewer pairs landed than were declared -- duplicates, or rejected keys --
/// the bucket array is the wrong size for its contents, so the whole struct is
/// rebuilt at the size it actually needs. The second build always succeeds,
/// because the count it is given is the count that fit. The prototype is
/// carried across by hand, since it is not a bucket.
///
/// The prototype contributes to the hash by a multiply rather than by being
/// walked, so a struct's hash is O(capacity) and not O(prototype depth).
pub fn end(st_in: [*]tables.KV) [*]const tables.KV {
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

/// Look up a key in this struct only.
pub fn rawget(st: [*]const tables.KV, key: repr.Value) repr.Value {
    const kv = find(st, key) orelse return wrap.fromNil();
    return kv.value;
}

/// Look up a key, following prototypes to a fixed depth.
pub fn get(st_in: [*]const tables.KV, key: repr.Value) repr.Value {
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

/// Look up a key and report which struct in the prototype chain held it.
/// The struct twin of `tables.Found`: the value, and which struct in the
/// prototype chain held it.
pub const Found = struct {
    value: repr.Value,
    holder: ?Struct,
};

pub fn getEx(st_in: [*]const tables.KV, key: repr.Value) Found {
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

/// Copy a struct's own pairs into a fresh table. The prototype is not carried;
/// `struct/to-table` rebuilds the chain itself when asked to.
pub fn toTable(st: [*]const tables.KV) *tables.Table {
    const cap = head(st).capacity;
    const table = tables.new(@intCast(cap));
    for (st[0..cap]) |*kv| {
        if (!isNilKey(kv.key)) tables.put(table, kv.key, kv.value);
    }
    return table;
}

// ==========================================================================
// The cfunction surface.
//
// A published `CFunction` has no error channel in its signature, so these
// deliver a raise through an abi. Nothing below holds anything across a call
// that can raise.
// ==========================================================================

fn cfunStructWithProto(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
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

fn cfunStructGetproto(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    const st = try args_core.getStruct(argv, 0);
    const proto = head(st).proto;
    return if (proto) |p| wrap.fromStruct(p) else wrap.fromNil();
}

/// The bound is an upper one and deliberately loose: a key that appears in
/// both a struct and its prototype is counted twice, so the accumulator is
/// over-allocated rather than resized. `end` compacts it.
fn cfunStructFlatten(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
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

/// The loop is a `do`/`while` in C and the difference matters: a struct with
/// no prototype still produces one table, and `recursive` only decides whether
/// the walk continues past the first.
fn cfunStructToTable(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
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
    // assigns `tab`, so the only way out of the loop is with a table in hand.
    return wrap.fromTable(tab orelse unreachable);
}

fn cfunStructRawget(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 2);
    const st = try args_core.getStruct(argv, 0);
    return rawget(st, argv[1]);
}

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
