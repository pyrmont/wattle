//! Structs: Janet's immutable dictionary, and the Robin Hood probe that makes
//! two structs built from the same pairs lay out identically.
//!
//! `tables.zig` is the sibling and the other half of the dictionary group.
//! Phase 12's namespace batch 1 split them out of `struct_table.zig`, whose
//! name was two nouns because C had two files; `port/NAMESPACES.md` has the
//! taxonomy the split follows. They still call each other -- `janet_struct_to_table`
//! calls `tables.put`, `janet_table_to_struct` calls `begin`, `put` and `end`
//! -- so the two files import each other. Zig has no trouble with that; the
//! reason the C original could not be split is that C has no such thing as
//! an import.
//!
//! Both files hold `asSize`, `isNilKey` and `isUnstorableKey`, three inline
//! predicates of two lines each. That is deliberate: neither file is the right
//! owner of a rule about the other's keys, and a fifteenth file in `value/`
//! to hold six lines would contradict the layout `NAMESPACES.md` settled.
//!
//! ## Not "an immutable table"
//!
//! It is tempting to read "struct" as "immutable table" and expect one probe
//! loop. They are not the same algorithm, and the difference is the reason
//! `janet_struct_find` exists beside `value.dictionaryFind` rather than calling it.
//!
//! **A struct probes Robin Hood and has no tombstones.** Nothing is ever
//! removed from a struct, and the ordering rule -- displace the entry that is
//! closer to its ideal slot, breaking ties by hash and then by `janet_compare`
//! on the keys -- makes the final layout a function of the *set* of pairs
//! rather than of the order they arrived in. That is not an optimisation.
//! `janet_struct_end` hashes the bucket array with `value.hashDictionary`, so two
//! structs built from the same pairs in different orders must lay out
//! identically or `{1 2 3 4}` would not equal `{3 4 1 2}`. The comparison
//! tiebreak is what makes the order total.
//!
//! So `find` is the simpler of the two loops despite the harder insert: with
//! no tombstones, the first nil key really is the end. `tables.zig` records
//! the other discipline.
//!
//! ## The count lives in the hash field during construction
//!
//! `janet_struct_begin` sets `head->hash = 0` and every `janet_struct_put`
//! that fills an empty slot increments it. The field is a running count until
//! `janet_struct_end` overwrites it with the real hash, which is also how
//! `put` enforces the declared length -- it returns early once the count
//! reaches `length`, so a struct built with more pairs than it was begun with
//! silently drops the surplus. Preserved exactly, including the aliasing: a
//! struct observed between `begin` and `end` has a hash that is a count.
//!
//! ## The increment SPIKE-8 was written for
//!
//! Every other Phase 8 increment inherited the spike's decision without
//! exercising it. This one exercises it directly. `janet_struct_put_ext` calls
//! `janet_compare` on two keys, which dispatches to a third-party abstract
//! type's callback for an abstract key. Under SPIKE-8 such a callback may not
//! raise, and if one does the signal jumps straight through these frames.
//! There is no `defer` here and `build.zig` checks that there is not.
//!
//! ## What is reproduced rather than repaired
//!
//! `janet_struct_begin` computes `2 * count` in `int32_t`, which is undefined
//! for a count above `INT32_MAX / 2`. The port wraps rather than trapping,
//! which is what every supported target does, and the `capacity < 0` fallback
//! below it is the C author's defence against a case `value.capacityFor` cannot
//! actually produce -- it clamps at `INT32_MAX` rather than overflowing. Both
//! are kept as written.

const std = @import("std");
const config = @import("config");
const corefn = @import("corefn");
const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");
const raise = @import("raise");
const args_core = @import("../args.zig");
const gc_alloc = @import("../gc.zig");
const kind = @import("helpers/kind.zig");
const wrap = @import("helpers/wrap.zig");
const tables = @import("tables.zig");
const order = @import("helpers/order.zig");
const value = @import("../value.zig");

/// Functions from `src/core/util.c` and `src/core/wrap.c`, declared here rather
/// than in `cabi.zig`: `util.h` was internal, and never in a translation.
///
/// Both are Zig now -- `utils.zig` defines `tablen` and `kvCalchash` -- and
/// neither is `pub`, so this still has to reach them by symbol. `memempty`
/// was a third until batch 4: that batch opened `value_wrap.zig` to split it,
/// so making its two bucket-array functions `pub` cost nothing, and
/// `wrap.memempty` is an import now. The remaining two need `utils.zig`
/// opened, which is where the rest of this population is.
/// C's conversion of a signed count to `size_t`: sign-extend to the pointer
/// width, then reinterpret. Same helper, and same reason, as `buffer_array.zig`
/// and `string_symbol.zig` -- a negative length becomes a request the allocator
/// cannot satisfy rather than a trap one statement earlier.
inline fn asSize(n: i32) usize {
    return @bitCast(@as(isize, n));
}

/// `janet_maphash` from `util.h`. The capacity is always a power of two, so the
/// mask is exact and the result is always in range.
inline fn mapHash(cap: i32, hash: i32) i32 {
    return @bitCast(@as(u32, @bitCast(hash)) & @as(u32, @bitCast(cap -% 1)));
}

inline fn isNilKey(key: types.Janet) bool {
    return kind.checkType(key, constants.JANET_NIL) != 0;
}

/// The two keys a dictionary refuses to store. Nil is the absent-key sentinel,
/// and a NaN is refused because it does not compare equal to itself, so a
/// lookup could never find it again.
inline fn isUnstorableKey(key: types.Janet) bool {
    if (kind.checkType(key, constants.JANET_NIL) != 0) return true;
    return kind.checkType(key, constants.JANET_NUMBER) != 0 and
        std.math.isNan(wrap.toNumber(key));
}

/// Allocate a struct's bucket array and its head in one block.
///
/// The capacity is the smallest power of two *strictly greater* than twice the
/// declared pair count -- `value.capacityFor` is a strict next-power-of-two, so a
/// count of two gets eight buckets rather than four. That keeps the load factor
/// below one half always and at one quarter whenever `2 * count` is itself a
/// power of two, which is what bounds the Robin Hood displacement chains.
/// `2 * count` overflows for a count above
/// `INT32_MAX / 2` -- undefined in C, wrapping here and on every supported
/// target -- and the `capacity < 0` retry below is the C author's defence
/// against a result `value.capacityFor` does not produce, since it clamps at
/// `INT32_MAX`. Both are kept.
///
/// `hash` starts at zero and is a running count of filled slots until
/// `janet_struct_end` replaces it.
pub fn begin(count: i32) [*]types.JanetKV {
    var capacity = value.capacityFor(2 *% count);
    if (capacity < 0) capacity = value.capacityFor(count +% 1);

    const size = types.struct_payload +% asSize(capacity) *% @sizeOf(types.JanetKV);
    const hd: *types.JanetStructHead = @ptrCast(@alignCast(gc_alloc.gcalloc(constants.JANET_MEMORY_STRUCT, size)));
    hd.length = count;
    hd.capacity = capacity;
    hd.hash = 0;
    hd.proto = null;

    const st = types.structData(hd);
    wrap.memempty(st, capacity);
    return st;
}

/// Find the bucket holding `key`, or the first empty bucket on its probe path.
///
/// A struct has no tombstones, so the first nil key ends the search and there
/// is no reusable-bucket bookkeeping. Returns null only when the array is
/// entirely full, which `janet_struct_begin`'s capacity policy prevents for any
/// struct built through the public constructors.
pub fn find(st: [*]const types.JanetKV, key: types.Janet) ?*const types.JanetKV {
    const cap = types.structHead(st).capacity;
    const index = mapHash(cap, order.hash(key));
    var i = index;
    while (i < cap) : (i += 1) {
        if (isNilKey(st[@intCast(i)].key) or order.equals(st[@intCast(i)].key, key) != 0) return &st[@intCast(i)];
    }
    i = 0;
    while (i < index) : (i += 1) {
        if (isNilKey(st[@intCast(i)].key) or order.equals(st[@intCast(i)].key, key) != 0) return &st[@intCast(i)];
    }
    return null;
}

/// Insert into a struct that is still under construction.
///
/// Nil keys, nil values and NaN keys are dropped, and so is everything past the
/// declared length. Collisions are resolved by Robin Hood displacement, which
/// is an in-place insertion sort: the pair further from its ideal slot keeps
/// the slot, ties broken by hash and then by `janet_compare` on the keys. The
/// result is that the bucket array depends only on the set of pairs, which is
/// what makes two equal structs hash equal.
///
/// `replace` distinguishes the two entry points. `janet_struct_put` overwrites
/// a duplicate key's value; `struct/proto-flatten` passes zero so that a
/// prototype's binding cannot displace the child's.
pub fn putExt(st: [*]types.JanetKV, key_in: types.Janet, value_in: types.Janet, replace: c_int) void {
    var key = key_in;
    var val = value_in;
    const hd = types.structHead(st);
    const cap = hd.capacity;
    var hash = order.hash(key);
    const index = mapHash(cap, hash);
    const bounds = [4]i32{ index, cap, 0, index };
    if (isUnstorableKey(key) or kind.checkType(val, constants.JANET_NIL) != 0) return;
    // Refuse anything past the declared length.
    if (hd.hash == hd.length) return;

    var dist: i32 = 0;
    var j: usize = 0;
    while (j < 4) : (j += 2) {
        var i = bounds[j];
        while (i < bounds[j + 1]) : ({
            i += 1;
            dist += 1;
        }) {
            const kv = &st[@intCast(i)];

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
                if (replace != 0) kv.value = val;
                return;
            }
        }
    }
}

/// Insert, replacing the value of a duplicate key.
pub fn put(st: [*]types.JanetKV, key: types.Janet, val: types.Janet) void {
    putExt(st, key, val, 1);
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
pub fn end(st_in: [*]types.JanetKV) callconv(.c) [*]const types.JanetKV {
    var st = st_in;
    if (types.structHead(st).hash != types.structHead(st).length) {
        const newst = begin(types.structHead(st).hash);
        var i: i32 = 0;
        while (i < types.structHead(st).capacity) : (i += 1) {
            const kv = &st[@intCast(i)];
            if (!isNilKey(kv.key)) put(newst, kv.key, kv.value);
        }
        types.structHead(newst).proto = types.structHead(st).proto;
        st = newst;
    }
    const hd = types.structHead(st);
    hd.hash = value.hashDictionary(st, hd.capacity);
    if (hd.proto != null) {
        hd.hash = @bitCast(@as(u32, @bitCast(hd.hash)) +%
            2654435761 *% @as(u32, @bitCast(types.structHead(hd.proto.?).hash)));
    }
    return st;
}

/// Look up a key in this struct only.
pub fn rawget(st: [*]const types.JanetKV, key: types.Janet) types.Janet {
    const kv = find(st, key) orelse return wrap.fromNil();
    return kv.value;
}

/// Look up a key, following prototypes to a fixed depth.
pub fn get(st_in: [*]const types.JanetKV, key: types.Janet) types.Janet {
    var st: ?types.JanetStruct = st_in;
    var i: c_int = config.max_proto_depth;
    while (st != null and i != 0) : ({
        i -= 1;
        st = types.structHead(st.?).proto;
    }) {
        const kv = find(st.?, key) orelse continue;
        if (!isNilKey(kv.key)) return kv.value;
    }
    return wrap.fromNil();
}

/// Look up a key and report which struct in the prototype chain held it.
pub fn getEx(st_in: [*]const types.JanetKV, key: types.Janet, which: *?types.JanetStruct) types.Janet {
    var st: ?types.JanetStruct = st_in;
    var i: c_int = config.max_proto_depth;
    while (st != null and i != 0) : ({
        i -= 1;
        st = types.structHead(st.?).proto;
    }) {
        const kv = find(st.?, key) orelse continue;
        if (!isNilKey(kv.key)) {
            which.* = st;
            return kv.value;
        }
    }
    return wrap.fromNil();
}

/// Copy a struct's own pairs into a fresh table. The prototype is not carried;
/// `struct/to-table` rebuilds the chain itself when asked to.
pub fn toTable(st: [*]const types.JanetKV) *types.JanetTable {
    const cap = types.structHead(st).capacity;
    const table = tables.new(cap);
    var i: i32 = 0;
    while (i < cap) : (i += 1) {
        const kv = &st[@intCast(i)];
        if (!isNilKey(kv.key)) tables.put(table, kv.key, kv.value);
    }
    return table;
}

// ==========================================================================
// The cfunction surface.
//
// Phase 10 Part 6, on the same footing as every other cfunction that phase
// moved: a `JanetCFunction` has no error channel in its signature, so these
// deliver a raise as the jump their C caller expects whatever language they
// are written in, and the file's jump-transparent marker is what makes that
// legal. Nothing below holds anything across a call that can raise.
// ==========================================================================

fn cfunStructWithProto(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    try args_core.arity(argv, 1, -1);
    const proto = try args_core.optStruct(argv, 0, null);
    if (@as(i32, @intCast(argv.len)) & 1 == 0) return raise.panic("expected odd number of arguments");
    const st = begin(@divTrunc(@as(i32, @intCast(argv.len)), 2));
    var i: i32 = 1;
    while (i < @as(i32, @intCast(argv.len))) : (i += 2) {
        put(st, argv[@intCast(i)], argv[@intCast(i + 1)]);
    }
    types.structHead(st).proto = proto;
    return wrap.fromStruct(end(st));
}

fn cfunStructGetproto(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 1);
    const st = try args_core.getStruct(argv, 0);
    const proto = types.structHead(st).proto;
    return if (proto) |p| wrap.fromStruct(p) else wrap.fromNil();
}

/// The bound is an upper one and deliberately loose: a key that appears in
/// both a struct and its prototype is counted twice, so the accumulator is
/// over-allocated rather than resized. `janet_struct_end` compacts it.
fn cfunStructFlatten(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 1);
    const st = try args_core.getStruct(argv, 0);

    var pair_count: i64 = 0;
    var cursor: ?types.JanetStruct = st;
    while (cursor) |current| {
        pair_count += types.structHead(current).length;
        cursor = types.structHead(current).proto;
    }
    if (pair_count > std.math.maxInt(i32)) return raise.panic("struct too large");

    const accum = begin(@intCast(pair_count));
    cursor = st;
    while (cursor) |current| {
        var i: i32 = 0;
        while (i < types.structHead(current).capacity) : (i += 1) {
            const kv = &current[@intCast(i)];
            if (kind.checkType(kv.key, constants.JANET_NIL) == 0) {
                putExt(accum, kv.key, kv.value, 0);
            }
        }
        cursor = types.structHead(current).proto;
    }
    return wrap.fromStruct(end(accum));
}

/// The loop is a `do`/`while` in C and the difference matters: a struct with
/// no prototype still produces one table, and `recursive` only decides whether
/// the walk continues past the first.
fn cfunStructToTable(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    try args_core.arity(argv, 1, 2);
    const st = try args_core.getStruct(argv, 0);
    const recursive = @as(i32, @intCast(argv.len)) > 1 and kind.truthy(argv[1]) != 0;
    var tab: ?*types.JanetTable = null;
    var cursor: types.JanetStruct = st;
    var tab_cursor: ?*types.JanetTable = null;
    while (true) {
        if (tab != null) {
            tab_cursor.?.proto = tables.new(types.structHead(cursor).length);
            tab_cursor = tab_cursor.?.proto;
        } else {
            tab = tables.new(types.structHead(cursor).length);
            tab_cursor = tab;
        }
        var i: i32 = 0;
        while (i < types.structHead(cursor).capacity) : (i += 1) {
            const kv = &cursor[@intCast(i)];
            if (kind.checkType(kv.key, constants.JANET_NIL) == 0) {
                tables.put(tab_cursor.?, kv.key, kv.value);
            }
        }
        if (!recursive) break;
        cursor = types.structHead(cursor).proto orelse break;
    }
    return wrap.fromTable(tab.?);
}

fn cfunStructRawget(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 2);
    const st = try args_core.getStruct(argv, 0);
    return rawget(st, argv[1]);
}

pub fn lib(env: *types.JanetTable) void {
    const entries = [_]corefn.Entry{
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
        corefn.end,
    };
    corefn.install(env, &entries);
}
