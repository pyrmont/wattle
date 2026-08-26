//! `value.zig` -- the bucket for `value/`.
//!
//! Every directory in the tree has a bucket, the file for whatever does not
//! group neatly into a topic of its own; `phase_12.md` decision 3 gives
//! `value/` one, and this is it. What it holds is the hashing and dictionary
//! machinery `value/tables.zig`, `value/structs.zig`, `value/strings.zig`,
//! `value/symbols.zig`, `value/tuples.zig`, `value/helpers/order.zig` and
//! `value/helpers/access.zig` share -- shared by both dictionary leaves and
//! belonging to neither, which is what a bucket is for.
//!
//! ## What is beside it, and why the four are one level down
//!
//! `value/` is two populations. Eleven **type leaves** name a type Janet
//! publishes -- `tables`, `strings`, `arrays`, `fibers` -- and four
//! **operations** in `value/helpers/` are defined over an arbitrary `Janet`
//! rather than over one type: `access` reaches inside, `order` compares and
//! hashes, `kind` inspects, `wrap` crosses the representation boundary.
//!
//! Decision 3 first put those four in this file, on the grounds that an
//! operation is not a leaf of a type taxonomy. That landed and was reversed
//! on 2026-08-28: not being a *type leaf* is a reason not to be their sibling,
//! and it is not by itself a reason to be in the bucket. `helpers/` says what
//! they are and keeps the two populations apart without flattening either.
//!
//! **The subdirectory has no bucket of its own, deliberately.** The rule that
//! every directory has one is about a directory that is a *topic* -- `os/`,
//! `ffi/`, `ev/` -- where something has to hold what does not group. A
//! subdirectory that exists only to group siblings does not need one, because
//! the parent's bucket is already the way in. This file is that bucket.
//!
//! **What the fold cost, and what reversing it bought back**, since the round
//! trip is the evidence: the four are a strict DAG -- `wrap <- kind <- order
//! <- access` -- and the compiler checks it on every build. One file dissolves
//! that into a namespace where anything may call anything. Against it, 61 of
//! the 107 files that use these names want two or more of them, so a caller
//! pays in imports for the layering it does not see. Both figures are real;
//! the layering won.
//!
//! **Size was not one of the figures, and this note is here so that it is not
//! measured a third time.** The folded file was 2,901 lines, which reads as
//! the largest in the tree; by *code* it was 1,530 -- third, behind `peg.zig`
//! at 1,833 and `marsh.zig` at 1,603. The value layer is the most heavily
//! commented part of this tree, so a raw line count says nothing here:
//!
//!     awk '$0 !~ /^[[:space:]]*\/\// && $0 !~ /^[[:space:]]*$/' f.zig | wc -l
//!
//! `port/STRUCTURE.md` recorded the same measurement a week before the fold
//! and it did not prevent the question being reopened on size, because the
//! question is asked by someone looking at the file rather than at the design
//! document. `phase_12.md`'s rule 62 is that lesson; this paragraph is its
//! repair.
//!
//! It was `utils.zig`'s, and `utils.zig` had it because `util.c` did. Seven
//! `extern fn` declarations across six leaves reached these through the linker;
//! they are ordinary imports now.
//!
//! **The names are not the C names.** Increment 5d's rule -- strip `janet_`,
//! camelCase the underscores -- transcribes whatever C called a thing, so a bad
//! C name arrives intact and green. These six were the ones worth fixing:
//!
//!     janet_tablen             capacityFor
//!         Not a length. The smallest power of two *strictly* greater than the
//!         argument -- not `std.math.ceilPowerOfTwo`, which differs at every
//!         exact power of two. Strict is what guarantees `dictionaryFind` an
//!         empty bucket to stop on.
//!     janet_string_calchash    hashBytes
//!     janet_array_calchash     hashIndexed
//!     janet_kv_calchash        hashDictionary
//!         "calchash" is not a word. The three names are `janet.h`'s own view
//!         taxonomy -- `janet_indexed_view`, `janet_bytes_view` and
//!         `janet_dictionary_view` -- and each of these takes exactly what the
//!         matching view hands back, so there is no fourth.
//!     janet_dict_find          dictionaryFind
//!     janet_dict_find_keyword  dictionaryFindKeyword
//!         `dict` is `util.h`'s spelling and `dictionary` is `janet.h`'s, so
//!         the abbreviation was carrying the internal/public boundary and
//!         nothing said so. `@export` carries it now, where it is legible.
//!
//! Every linker symbol below is unchanged. The export block at the foot is
//! where the C name lives now.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config");
const utils = @import("utils.zig");
const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");

const stringHead = utils.stringHead;

// ------------------------------------------------------------- the leaves
//
// The bucket is also the group namespace, which is what `root.zig` reaches:
// `@import("subsystems").value.tables` is `test/`'s spelling and there are 446
// sites of that shape. A runtime file still imports the leaf directly -- the
// leaf is the import unit, per `port/NAMESPACES.md` -- so nothing below is a
// second spelling for `src/zig`, only the barrel's one level.

pub const arrays = @import("value/arrays.zig");
pub const tuples = @import("value/tuples.zig");
pub const buffers = @import("value/buffers.zig");
pub const strings = @import("value/strings.zig");
pub const symbols = @import("value/symbols.zig");
pub const tables = @import("value/tables.zig");
pub const structs = @import("value/structs.zig");
pub const abstracts = @import("value/abstracts.zig");
pub const fibers = @import("value/fibers.zig");
pub const functions = @import("value/functions.zig");
pub const order = @import("value/helpers/order.zig");
pub const access = @import("value/helpers/access.zig");
pub const wrap = @import("value/helpers/wrap.zig");
pub const kind = @import("value/helpers/kind.zig");

// ------------------------------------------------------- a value from bytes

/// The three Janet types a run of bytes can become.
///
/// `janet.h` spells this two-by-three grid as six macros -- `janet_stringv`
/// and `janet_cstringv`, and the symbol and keyword pairs beside them -- where
/// the two halves of the grid are *how the length arrives* and *which tag goes
/// on*. C needs six because it has no slice and no enum. Zig needs one.
///
/// Only three of the sixteen types can be built this way, which is what makes
/// a closed enum honest here rather than a stand-in for `JanetType`:
/// everything else is built from a pointer to something already allocated.
/// `DESIGN.md` §2 decided the tag should be an enum rather than a bare
/// `c_int`; this is that decision at the three sites that force it.
pub const Bytes = enum { string, symbol, keyword };

/// A `Janet` holding `bytes`, as the named type.
///
/// **The parameter is a slice, and that is the point.** `janet_cstringv(p)`
/// took a bare `const char *` and called `strlen` to find out how long it was
/// -- work the caller usually already knew the answer to and had thrown away.
/// A literal knows its length at comptime, so the common call site loses the
/// `strlen` entirely; a caller holding a real C pointer spans it, which puts
/// the scan where it is visible and where increment 5h can see it.
///
/// A symbol and a keyword are interned identically -- `janet.h:1844` reads
/// `#define janet_keyword janet_symbol` -- and differ only in the tag, which
/// is why they share an arm here and why `symbols.zig` serves both.
///
/// This lives in the bucket rather than in a leaf because it is shared by
/// `strings` and `symbols` and belongs to neither, which is the criterion
/// stated at the head of this file. It cannot live in `helpers/wrap.zig`: that
/// file is the bottom of the `wrap <- kind <- order <- access` DAG and every
/// leaf imports it, so a wrap that allocates would invert the arrow.
pub inline fn fromBytes(bytes: []const u8, comptime as: Bytes) types.Janet {
    return switch (as) {
        .string => wrap.fromString(strings.new(bytes)),
        .symbol => wrap.fromSymbol(symbols.new(bytes)),
        .keyword => wrap.fromKeyword(symbols.new(bytes)),
    };
}

const hash_seed: u32 = 0x9e3779b9;
const hash_key_size = constants.JANET_HASH_KEY_SIZE;
var hash_key: [hash_key_size]u8 = @splat(0);
comptime {
    if (config.prf) {}
}

pub fn hashMix(input: u32, more: u32) u32 {
    const mix = more +% hash_seed +% (input << 6) +% (input >> 2);
    return input ^ (hash_seed +% (mix << 6) +% (mix >> 2));
}

pub fn hashBytes(bytes: []const u8) i32 {
    if (config.prf) {
        return @bitCast(halfSipHash(bytes, &hash_key));
    }

    if (bytes.len == 0) return 5381;
    var hash: u32 = 5381;
    for (bytes) |byte| {
        hash = (hash << 5) +% hash +% byte;
    }
    return @bitCast(hashMix(hash, @bitCast(@as(i32, @intCast(bytes.len)))));
}

pub fn capacityFor(val: i32) i32 {
    if (val < 0) return 0;
    var result = val;
    result |= result >> 1;
    result |= result >> 2;
    result |= result >> 4;
    result |= result >> 8;
    result |= result >> 16;
    return if (result == std.math.maxInt(i32)) result else result + 1;
}

pub fn initHashKey(new_key: [*]u8) void {
    @memcpy(&hash_key, new_key[0..hash_key.len]);
}

fn halfSipHash(input: []const u8, key: *const [hash_key_size]u8) u32 {
    var v0: u32 = 0;
    var v1: u32 = 0;
    var v2: u32 = 0x6c796765;
    var v3: u32 = 0x74656462;
    const k0 = readU32Little(key[0..4]);
    const k1 = readU32Little(key[4..8]);

    v3 ^= k1;
    v2 ^= k0;
    v1 ^= k1;
    v0 ^= k0;

    const word_bytes = input.len - (input.len % 4);
    var offset: usize = 0;
    while (offset < word_bytes) : (offset += 4) {
        const message = readU32Little(input[offset..][0..4]);
        v3 ^= message;
        sipRound(&v0, &v1, &v2, &v3);
        sipRound(&v0, &v1, &v2, &v3);
        v0 ^= message;
    }

    var final: u32 = @as(u32, @truncate(input.len)) << 24;
    const remaining = input.len - word_bytes;
    if (remaining >= 3) final |= @as(u32, input[offset + 2]) << 16;
    if (remaining >= 2) final |= @as(u32, input[offset + 1]) << 8;
    if (remaining >= 1) final |= input[offset];

    v3 ^= final;
    sipRound(&v0, &v1, &v2, &v3);
    sipRound(&v0, &v1, &v2, &v3);
    v0 ^= final;
    v2 ^= 0xff;
    inline for (0..4) |_| sipRound(&v0, &v1, &v2, &v3);
    return v1 ^ v3;
}

fn sipRound(v0: *u32, v1: *u32, v2: *u32, v3: *u32) void {
    v0.* +%= v1.*;
    v1.* = rotateLeft(v1.*, 5);
    v1.* ^= v0.*;
    v0.* = rotateLeft(v0.*, 16);
    v2.* +%= v3.*;
    v3.* = rotateLeft(v3.*, 8);
    v3.* ^= v2.*;
    v0.* +%= v3.*;
    v3.* = rotateLeft(v3.*, 7);
    v3.* ^= v0.*;
    v2.* +%= v1.*;
    v1.* = rotateLeft(v1.*, 13);
    v1.* ^= v2.*;
    v2.* = rotateLeft(v2.*, 16);
}

fn rotateLeft(val: u32, comptime amount: u5) u32 {
    return std.math.rotl(u32, val, amount);
}

fn readU32Little(bytes: *const [4]u8) u32 {
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}

// -------------------------------------------------- hashes over collections

/// Hash a run of values, for `janet_tuple_end`.
///
/// The seed is 33 rather than the 5381 the string hash starts from; both are
/// the C original's and neither is explained there.
pub fn hashIndexed(array: ?[*]const types.Janet, len: i32) i32 {
    var hash: u32 = 33;
    var i: i32 = 0;
    while (i < len) : (i += 1) {
        hash = hashMix(hash, @bitCast(order.hash(array.?[@intCast(i)])));
    }
    return @bitCast(hash);
}

/// Hash a run of key-value pairs, for `janet_struct_end`.
pub fn hashDictionary(kvs: ?[*]const types.JanetKV, len: i32) i32 {
    var hash: u32 = 33;
    var i: i32 = 0;
    while (i < len) : (i += 1) {
        const kv = kvs.?[@intCast(i)];
        hash = hashMix(hash, @bitCast(order.hash(kv.key)));
        hash = hashMix(hash, @bitCast(order.hash(kv.value)));
    }
    return @bitCast(hash);
}

/// `janet_maphash` from `src/core/util.h`.
///
/// The mask is `cap - 1` rather than `cap % capacity` because every capacity
/// the runtime produces is a power of two. It is not written to survive a
/// capacity of zero, and `FOUND.md`'s "A zero-capacity table cannot be looked
/// up in" is what happens when one arrives: the mask becomes `0xFFFFFFFF`, the
/// identity, and the probes below run off the array.
///
/// The subtraction wraps rather than trapping. `cap` is `INT32_MIN` in no
/// reachable call — `janet_capacityFor` never returns it — and C's own subtraction
/// would be undefined there, so there is nothing to reproduce and a trap would
/// be the port inventing a behaviour.
inline fn mapHash(cap: i32, hash: i32) i32 {
    return @bitCast(@as(u32, @bitCast(hash)) & @as(u32, @bitCast(cap -% 1)));
}

inline fn isNil(val: types.Janet) bool {
    return kind.checkType(val, constants.JANET_NIL) != 0;
}

/// Find the bucket holding `key`, or the first bucket it could be put in.
///
/// The two loops are one circular scan from `index`, written out because C has
/// no way to say it in one. A bucket whose key *and* value are nil has never
/// been used and ends the scan; a bucket whose key is nil and whose value is
/// not is a tombstone, remembered as a candidate and scanned past, because the
/// key may still be further along. So the answer is the key's own bucket if it
/// is present, the first tombstone if it is not, and a truly empty bucket
/// otherwise -- which is the order `janet_table_put` depends on and the reason
/// its tombstone-retiring branch is dead code, in `FOUND.md`.
///
/// A capacity of zero sends this off the array; see `mapHash`. That is
/// undefined in C and the port does not reproduce it: a safety-checked build
/// traps at the first index rather than reading two gigabytes below the null
/// page.
pub fn dictionaryFind(buckets: [*]const types.JanetKV, cap: i32, key: types.Janet) ?*const types.JanetKV {
    const index = mapHash(cap, order.hash(key));
    var first_bucket: ?*const types.JanetKV = null;

    var i: i32 = index;
    while (i < cap) : (i += 1) {
        const kv = &buckets[@intCast(i)];
        if (isNil(kv.key)) {
            if (isNil(kv.value)) return kv;
            if (first_bucket == null) first_bucket = kv;
        } else if (order.equals(kv.key, key) != 0) {
            return kv;
        }
    }

    i = 0;
    while (i < index) : (i += 1) {
        const kv = &buckets[@intCast(i)];
        if (isNil(kv.key)) {
            if (isNil(kv.value)) return kv;
            if (first_bucket == null) first_bucket = kv;
        } else if (order.equals(kv.key, key) != 0) {
            return kv;
        }
    }

    return first_bucket;
}

/// The same probe for a key given as bytes rather than as a `Janet`.
///
/// It exists so that a lookup by name neither interns a symbol nor allocates:
/// the comparison is against the bucket's own string head, so a keyword, a
/// symbol and a string with the same bytes all match. The type check is
/// `JANET_KEYWORD` alone, and that is not a bug — the three share a
/// representation and the C original says so in a comment.
pub fn dictionaryFindKeyword(
    buckets: [*]const types.JanetKV,
    cap: i32,
    cstr: [*]const u8,
    cstr_len: i32,
) callconv(.c) ?*const types.JanetKV {
    const key_bytes = cstr[0..@intCast(cstr_len)];
    const hash = hashBytes(key_bytes);
    const index = mapHash(cap, hash);
    var first_bucket: ?*const types.JanetKV = null;

    var i: i32 = index;
    while (i < cap) : (i += 1) {
        const kv = &buckets[@intCast(i)];
        if (isNil(kv.key)) {
            if (isNil(kv.value)) return kv;
            if (first_bucket == null) first_bucket = kv;
        } else if (matchesKeyword(kv.key, hash, key_bytes)) {
            return kv;
        }
    }

    i = 0;
    while (i < index) : (i += 1) {
        const kv = &buckets[@intCast(i)];
        if (isNil(kv.key)) {
            if (isNil(kv.value)) return kv;
            if (first_bucket == null) first_bucket = kv;
        } else if (matchesKeyword(kv.key, hash, key_bytes)) {
            return kv;
        }
    }

    return first_bucket;
}

/// The bucket test the two halves of `janet_dict_find_keyword` share.
///
/// The hash is compared before the bytes, which is what makes the probe cheap:
/// a string carries its hash in its head, so a mismatch costs one load.
fn matchesKeyword(key: types.Janet, hash: i32, cstr: []const u8) bool {
    if (kind.checkType(key, constants.JANET_KEYWORD) == 0) return false;
    const str = wrap.toString(key);
    const head = stringHead(str);
    if (head.*.hash != hash or head.*.length != @as(i32, @intCast(cstr.len))) return false;
    return std.mem.eql(u8, str[0..cstr.len], cstr);
}

/// Look a key up in a struct or table's buckets, answering nil for absent.
pub fn dictionaryGet(data: [*]const types.JanetKV, cap: i32, key: types.Janet) types.Janet {
    const kv = dictionaryFind(data, cap, key) orelse return wrap.fromNil();
    if (!isNil(kv.key)) return kv.value;
    return wrap.fromNil();
}

/// Walk the occupied buckets of a struct or table in bucket order.
///
/// A null `kv` starts the walk and a null return ends it, so the whole
/// iteration is `while (kv = janet_dictionary_next(...)) != null`. Bucket order
/// is not insertion order and is not stable across a rehash.
pub fn dictionaryNext(
    kvs: [*]const types.JanetKV,
    cap: i32,
    kv: ?*const types.JanetKV,
) callconv(.c) ?*const types.JanetKV {
    const end = kvs + @as(usize, @intCast(cap));
    var cursor: [*]const types.JanetKV = if (kv) |at| @as([*]const types.JanetKV, @ptrCast(at)) + 1 else kvs;
    while (@intFromPtr(cursor) < @intFromPtr(end)) : (cursor += 1) {
        if (!isNil(cursor[0].key)) return &cursor[0];
    }
    return null;
}
