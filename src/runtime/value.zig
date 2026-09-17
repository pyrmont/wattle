//! The bucket for `value/`: the hashing and dictionary machinery the value
//! leaves and helpers share.
//!
//! Every directory in the tree has a bucket, the file for whatever does not
//! group into a topic of its own, and this is `value/`'s. `value/tables.zig`,
//! `value/structs.zig`, `value/strings.zig`, `value/symbols.zig`,
//! `value/tuples.zig`, `value/helpers/order.zig` and
//! `value/helpers/access.zig` all reach it, and what is here is owned by both
//! dictionary leaves and by neither, which is what a bucket is for.
//!
//! ## The two populations beside it
//!
//! `value/` has eleven type leaves in it, each naming a type Janet publishes:
//! `tables`, `strings`, `arrays`, `fibers` and the rest. One level down,
//! `value/helpers/` has the three operations defined over an arbitrary value
//! rather than over one type: `access` reaches inside, `order` compares and
//! hashes, and `wrap` crosses the representation boundary.
//!
//! The subdirectory has no bucket of its own, deliberately. The rule that every
//! directory has one is about a directory that is a topic, as `os/`, `ffi/` and
//! `ev/` are, and one that exists only to group siblings is reached through its
//! parent's bucket, which is this file.
//!
//! The three helpers are a strict chain, and the compiler checks it on every
//! build: `repr <- wrap <- order <- access`. Folding them into one file
//! dissolves that into a namespace where anything may call anything.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const config = @import("config");
const constants = @import("constants");
const repr = @import("repr");
const utils = @import("utils.zig");
const vm_state = @import("vm/state.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// The per-process key the pseudo-random hash draws from, and its width.
/// `initHashKey` fills it at startup.
const hash_key_size = constants.JANET_HASH_KEY_SIZE;
var hash_key: [hash_key_size]u8 = @splat(0);

/// The seed both byte hashes start their mixing from. It is upstream Janet's,
/// and a marshalled hash is compared against one it produced, so it may not
/// change.
const hash_seed: u32 = 0x9e3779b9;

/// The leaves and helpers, re-exported so that `root.zig` reaches them as one
/// group.
///
/// The bucket is also the group namespace, which is what `test/` spells as
/// `@import("subsystems").value.tables`. A runtime file imports the leaf
/// directly, because the leaf is the import unit, so these add a spelling for
/// `test/` rather than for the runtime.
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
pub const vectors = @import("value/vectors.zig");
pub const transients = @import("value/transients.zig");
pub const order = @import("value/helpers/order.zig");
pub const access = @import("value/helpers/access.zig");
pub const wrap = @import("value/helpers/wrap.zig");

/// A string's head, under the name this file uses.
const stringHead = utils.stringHead;

// ==========================================================================
// Types
// ==========================================================================

/// The three Janet types a run of bytes can become.
///
/// One function over a two-by-three grid, how the length arrives and which tag
/// goes on, where a language without slices or enums needs six.
///
/// Only three of the sixteen types can be built this way, which is what makes a
/// closed enum honest here rather than a stand-in for `repr.Tag`: everything
/// else is built from a pointer to something already allocated.
pub const Bytes = enum { string, symbol, keyword };

// ==========================================================================
// Public functions
// ==========================================================================

/// Returns the capacity a dictionary needs for `val` entries: the smallest
/// power of two strictly greater than it.
///
/// `val` is the entry count. Not `std.math.ceilPowerOfTwo`, which differs at
/// every exact power of two. Strict is what guarantees `dictionaryFind` an
/// empty bucket to stop on, so a probe that finds none terminates.
///
/// The rounding runs in 32 bits and saturates at `INT32_MAX`, which is the
/// largest count any Janet collection has and therefore the largest capacity a
/// bucket array is asked for.
pub fn capacityFor(val: usize) usize {
    if (val > std.math.maxInt(i32)) return std.math.maxInt(i32);
    var result: u32 = @intCast(val);
    result |= result >> 1;
    result |= result >> 2;
    result |= result >> 4;
    result |= result >> 8;
    result |= result >> 16;
    return if (result == std.math.maxInt(i32)) result else result + 1;
}

/// Returns the bucket with `key` in it, or the first bucket it could be put in.
///
/// `buckets` is the hash array and `key` the key. The two loops are one
/// circular scan from the mapped index. A bucket whose key and value are both
/// nil has never been used and ends the scan; a bucket whose key is nil and
/// whose value is not is a tombstone, remembered as a candidate and scanned
/// past, because the key may still be further along. So the result is the key's
/// own bucket if it is present, the first truly empty bucket if it is not, and
/// the first tombstone only when the scan meets no empty bucket, which is the
/// order `tables.put` depends on and the reason it never has a tombstone to
/// retire.
///
/// A capacity of zero sends this off the array; see `mapHash`. No constructor
/// produces one, and a safety-checked build traps at the first index rather
/// than reading below the array.
pub fn dictionaryFind(buckets: []const tables.KV, key: repr.Value) ?*const tables.KV {
    const cap: i32 = @intCast(buckets.len);
    const index = mapHash(cap, order.hash(key));
    var first_bucket: ?*const tables.KV = null;

    // Index loops, rather than `for (buckets[start..]) |*kv|`. Zig's `for`
    // over a sub-slice with a pointer capture leaves both the element pointer
    // and the index live, so the probe runs three induction updates per
    // iteration where an index runs two. This is the hottest loop in the
    // tree, and the faster shape is the one it takes.
    const start: usize = @intCast(index);
    var i: usize = start;
    while (i < buckets.len) : (i += 1) {
        const kv = &buckets[i];
        if (isNil(kv.key)) {
            if (isNil(kv.value)) return kv;
            if (first_bucket == null) first_bucket = kv;
        } else if (order.equals(kv.key, key)) {
            return kv;
        }
    }

    i = 0;
    while (i < start) : (i += 1) {
        const kv = &buckets[i];
        if (isNil(kv.key)) {
            if (isNil(kv.value)) return kv;
            if (first_bucket == null) first_bucket = kv;
        } else if (order.equals(kv.key, key)) {
            return kv;
        }
    }

    return first_bucket;
}

/// The same probe for a key given as bytes rather than as a `Value`.
///
/// `buckets` is the hash array, and `cstr` and `cstr_len` the bytes. It exists
/// so that a lookup by name neither interns a symbol nor allocates: the
/// comparison is against the bucket's own string head, so a keyword, a symbol
/// and a string with the same bytes all match. The type check names
/// `repr.Tag.keyword` alone, and that is not an oversight: the three tags share
/// one representation, and the head is what the comparison reads.
pub fn dictionaryFindKeyword(
    buckets: []const tables.KV,
    cstr: [*]const u8,
    cstr_len: i32,
) ?*const tables.KV {
    const cap: i32 = @intCast(buckets.len);
    const key_bytes = cstr[0..@intCast(cstr_len)];
    const hash = hashBytes(key_bytes);
    const index = mapHash(cap, hash);
    var first_bucket: ?*const tables.KV = null;

    // Index loops for the reason `dictionaryFind` states above, and measured
    // with it: this is the same probe over the same buckets.
    const start: usize = @intCast(index);
    var i: usize = start;
    while (i < buckets.len) : (i += 1) {
        const kv = &buckets[i];
        if (isNil(kv.key)) {
            if (isNil(kv.value)) return kv;
            if (first_bucket == null) first_bucket = kv;
        } else if (matchesKeyword(kv.key, hash, key_bytes)) {
            return kv;
        }
    }

    i = 0;
    while (i < start) : (i += 1) {
        const kv = &buckets[i];
        if (isNil(kv.key)) {
            if (isNil(kv.value)) return kv;
            if (first_bucket == null) first_bucket = kv;
        } else if (matchesKeyword(kv.key, hash, key_bytes)) {
            return kv;
        }
    }

    return first_bucket;
}

/// Looks a key up in a struct or table's buckets, and gives nil for absent.
///
/// `data` is the hash array and `key` the key.
pub fn dictionaryGet(data: []const tables.KV, key: repr.Value) repr.Value {
    const kv = dictionaryFind(data, key) orelse return wrap.fromNil();
    if (!isNil(kv.key)) return kv.value;
    return wrap.fromNil();
}

/// Walks the occupied buckets of a struct or table in bucket order.
///
/// `kvs` is the hash array and `kv` the previous bucket. A null `kv` starts the
/// walk and a null result ends it, so a caller writes
/// `while (dictionaryNext(kvs, at)) |kv|`. Bucket order is not insertion order
/// and is not stable across a rehash.
pub fn dictionaryNext(
    kvs: []const tables.KV,
    kv: ?*const tables.KV,
) ?*const tables.KV {
    const start: usize = if (kv) |at|
        (@intFromPtr(at) - @intFromPtr(kvs.ptr)) / @sizeOf(tables.KV) + 1
    else
        0;
    for (kvs[start..]) |*bucket| {
        if (!isNil(bucket.key)) return bucket;
    }
    return null;
}

/// Returns a `Value` over `bytes`, as the named type.
///
/// `bytes` is the run of bytes and `as` the type. The parameter is a slice: a
/// literal has its length at comptime, so the common call site scans nothing,
/// and a caller with a bare C pointer has to span it first, which puts the scan
/// where it is visible rather than inside every call.
///
/// A symbol and a keyword are interned identically and differ only in the tag,
/// so they share an arm here and `value/symbols.zig` serves both.
///
/// This is in the bucket rather than in a leaf because `strings` and `symbols`
/// share it and neither owns it. It cannot be in `value/helpers/wrap.zig`: that
/// file is the bottom of the `wrap <- order <- access` chain and every leaf
/// imports it, so a wrap that allocates would invert the arrow.
pub inline fn fromBytes(bytes: []const u8, comptime as: Bytes) repr.Value {
    return switch (as) {
        .string => wrap.fromString(strings.new(bytes)),
        .symbol => wrap.fromSymbol(symbols.new(bytes)),
        .keyword => wrap.fromKeyword(symbols.new(bytes)),
    };
}

/// Returns the hash of a run of bytes.
///
/// `bytes` is the run. Under `-Dprf` this is the pseudo-random half-SipHash
/// over the per-process key; otherwise it is upstream Janet's own mix, whose
/// constants a marshalled hash is compared against.
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

/// Returns the hash of a run of key-value pairs, for `structs.end`.
///
/// `kvs` is the run.
pub fn hashDictionary(kvs: []const tables.KV) i32 {
    var hash: u32 = 33;
    for (kvs) |kv| {
        hash = hashMix(hash, @bitCast(order.hash(kv.key)));
        hash = hashMix(hash, @bitCast(order.hash(kv.value)));
    }
    return @bitCast(hash);
}

/// Returns the hash of a run of values, for `tuples.end`.
///
/// `array` is the run. The seed is 33 rather than the 5381 the byte hash starts
/// from. Both are upstream Janet's, and a marshalled hash is compared against
/// one it produced, so neither may change.
pub fn hashIndexed(array: []const repr.Value) i32 {
    var hash: u32 = 33;
    for (array) |x| hash = hashMix(hash, @bitCast(order.hash(x)));
    return @bitCast(hash);
}

/// Mixes two hash words.
///
/// `input` and `more` are the two. `hashBytes`, `hashIndexed` and
/// `hashDictionary` are three and not four: each covers one of the three kinds
/// the getters read, bytes, indexed or dictionary, so the taxonomy is closed at
/// three.
pub fn hashMix(input: u32, more: u32) u32 {
    const mix = more +% hash_seed +% (input << 6) +% (input >> 2);
    return input ^ (hash_seed +% (mix << 6) +% (mix >> 2));
}

/// Fills the per-process hash key.
///
/// `new_key` is at least `hash_key_size` bytes of randomness.
pub fn initHashKey(new_key: [*]u8) void {
    @memcpy(&hash_key, new_key[0..hash_key.len]);
}

/// Allocates a heap block of `count` key-value pairs, every one of them nil,
/// charged against the collection budget.
///
/// `count` is the bucket count. `utils.rawAlloc` exits the process rather than
/// giving null, so the charge below it runs only on the path that got the
/// memory.
///
/// This and `memempty` are allocation rather than representation, a
/// `utils.rawAlloc`, a collection charge and an out-of-memory exit, and what
/// they allocate is a bucket array, which is this bucket's subject.
/// `value/tables.zig` and `value/structs.zig` are the two callers.
pub fn memallocEmpty(count: usize) [*]tables.KV {
    const bytes = kvBytes(count);
    const mmem: [*]tables.KV = @ptrCast(@alignCast(utils.rawAlloc(bytes)));
    vm_state.current().gc.next_collection +%= bytes;
    for (mmem[0..count]) |*kv| {
        kv.key = wrap.fromNil();
        kv.value = wrap.fromNil();
    }
    return mmem;
}

/// The same fill over a block the caller already owns.
///
/// `mem` is the block. This is how a table is cleared and how a struct's
/// bucket array is initialised from the scratch allocator.
pub fn memempty(mem: []tables.KV) void {
    for (mem) |*kv| {
        kv.key = wrap.fromNil();
        kv.value = wrap.fromNil();
    }
}

// ==========================================================================
// Private functions
// ==========================================================================

/// Returns the half-SipHash of `input` under `key`, for `-Dprf` builds.
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

/// Whether a value is nil. `dictionaryFind`, `dictionaryGet` and
/// `dictionaryNext` are the callers.
inline fn isNil(val: repr.Value) bool {
    return repr.checkType(val, repr.Tag.nil);
}

/// Returns a bucket array's size in bytes.
///
/// `count` is the bucket count. The multiply wraps; a bucket count is a `usize`
/// and `capacityFor`, which clamps at `INT32_MAX`, is the only thing that
/// produces one.
inline fn kvBytes(count: usize) usize {
    return count *% @sizeOf(tables.KV);
}

/// Returns a hash folded into a bucket index.
///
/// `cap` is the capacity and `hash` the hash. The mask is `cap - 1` rather than
/// a remainder because every capacity the runtime produces is a power of two.
/// It is not written to survive a capacity of zero, and no constructor produces
/// one: the mask would become the identity and the probes would run off the
/// array.
///
/// The subtraction wraps rather than trapping. No reachable call passes
/// `INT32_MIN`, since `capacityFor` never gives it, so a trap here would be
/// inventing a behaviour for an argument nothing supplies.
inline fn mapHash(cap: i32, hash: i32) i32 {
    return @bitCast(@as(u32, @bitCast(hash)) & @as(u32, @bitCast(cap -% 1)));
}

/// The bucket test the two halves of `dictionaryFindKeyword` share.
///
/// `key` is the bucket's key, `hash` the sought hash and `cstr` the sought
/// bytes. The hash is compared before the bytes, which is what makes the probe
/// cheap: a string has its hash in its head, so a mismatch costs one load.
fn matchesKeyword(key: repr.Value, hash: i32, cstr: []const u8) bool {
    if (!repr.checkType(key, repr.Tag.keyword)) return false;
    const str = wrap.toString(key);
    const head = stringHead(str);
    if (head.hash != hash or head.length != cstr.len) return false;
    return std.mem.eql(u8, str[0..cstr.len], cstr);
}

/// Reads four bytes as a little-endian `u32`, for `halfSipHash`.
fn readU32Little(bytes: *const [4]u8) u32 {
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}

/// Rotates `val` left by `amount`, for `halfSipHash`.
fn rotateLeft(val: u32, comptime amount: u5) u32 {
    return std.math.rotl(u32, val, amount);
}

/// One SipHash round over the four state words.
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
