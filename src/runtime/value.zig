//! `value.zig` -- the bucket for `value/`.
//!
//! Every directory in the tree has a bucket, the file for whatever does not
//! group neatly into a topic of its own, and this is `value/`'s: the hashing
//! and dictionary machinery `value/tables.zig`, `value/structs.zig`,
//! `value/strings.zig`, `value/symbols.zig`, `value/tuples.zig`,
//! `value/helpers/order.zig` and `value/helpers/access.zig` share -- owned by
//! both dictionary leaves and by neither, which is what a bucket is for.
//!
//! ## The two populations beside it
//!
//! `value/` holds eleven **type leaves**, each naming a type Janet publishes
//! -- `tables`, `strings`, `arrays`, `fibers` -- and, one level down in
//! `value/helpers/`, the three **operations** defined over an arbitrary value
//! rather than over one type: `access` reaches inside, `order` compares and
//! hashes, `wrap` crosses the representation boundary. `DESIGN.md` section 14
//! is the decision.
//!
//! **The subdirectory has no bucket of its own, deliberately**: the rule that
//! every directory has one is about a directory that is a *topic* -- `os/`,
//! `ffi/`, `ev/` -- and one that exists only to group siblings is reached
//! through its parent's bucket, which is this file.
//!
//! **The three helpers are a strict DAG, and the compiler checks it on every
//! build**: `repr <- wrap <- order <- access`. Folding them into one file
//! dissolves that into a namespace where anything may call anything, and a raw
//! line count is not an argument for doing so -- this is the most heavily
//! commented part of the tree, and by code lines the layer is third behind
//! `peg.zig` and `marsh.zig`.

const std = @import("std");
const config = @import("config");
const utils = @import("utils.zig");
const vm_state = @import("vm/state.zig");
const repr = @import("repr");
const constants = @import("constants");

const stringHead = utils.stringHead;

// ------------------------------------------------------------- the leaves
//
// The bucket is also the group namespace, which is what `root.zig` reaches:
// `@import("subsystems").value.tables` is `test/`'s spelling. A runtime file
// imports the leaf directly, because the leaf is the import unit, so the
// re-exports below add a spelling for `test/` and not for the runtime.

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

// ------------------------------------------------------- a value from bytes

/// The three Janet types a run of bytes can become.
///
/// One function over a two-by-three grid -- how the length arrives, and which
/// tag goes on -- where a language without slices or enums needs six.
///
/// Only three of the sixteen types can be built this way, which is what makes
/// a closed enum honest here rather than a stand-in for `repr.Tag`:
/// everything else is built from a pointer to something already allocated.
/// `DESIGN.md` §2 decided the tag should be an enum rather than a bare
/// `c_int`; this is that decision at the three sites that force it.
pub const Bytes = enum { string, symbol, keyword };

/// A `Janet` holding `bytes`, as the named type.
///
/// **The parameter is a slice, and that is the point.** A literal knows its
/// length at comptime, so the common call site scans nothing; a caller holding
/// a bare C pointer has to span it first, which puts the scan where it is
/// visible rather than inside every call.
///
/// A symbol and a keyword are interned identically and differ only in the tag,
/// which is why they share an arm here and why `symbols.zig` serves both.
///
/// This lives in the bucket rather than in a leaf because it is shared by
/// `strings` and `symbols` and belongs to neither, which is the criterion
/// stated at the head of this file. It cannot live in `helpers/wrap.zig`: that
/// file is the bottom of the `wrap <- order <- access` DAG and every
/// leaf imports it, so a wrap that allocates would invert the arrow.
pub inline fn fromBytes(bytes: []const u8, comptime as: Bytes) repr.Value {
    return switch (as) {
        .string => wrap.fromString(strings.new(bytes)),
        .symbol => wrap.fromSymbol(symbols.new(bytes)),
        .keyword => wrap.fromKeyword(symbols.new(bytes)),
    };
}

const hash_seed: u32 = 0x9e3779b9;
const hash_key_size = constants.JANET_HASH_KEY_SIZE;
var hash_key: [hash_key_size]u8 = @splat(0);

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

/// The capacity a dictionary needs to hold `val` entries: the smallest power of
/// two **strictly** greater than it.
///
/// Not `std.math.ceilPowerOfTwo`, which differs at every exact power of two.
/// Strict is what guarantees `dictionaryFind` an empty bucket to stop on, so a
/// probe that finds none terminates.
///
/// The rounding runs in 32 bits and saturates at `INT32_MAX`, which is the
/// largest count any Janet collection carries and therefore the largest
/// capacity a bucket array is asked for.
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
//
// **`hashBytes`, `hashIndexed` and `hashDictionary` are three and not four.**
// Each takes exactly what one of the three views -- bytes, indexed,
// dictionary -- hands back, so the taxonomy is closed at three.

/// Hash a run of values, for `tuples.end`.
///
/// The seed is 33 rather than the 5381 the string hash starts from. Both are
/// upstream Janet's, and a marshalled hash is compared against one it
/// produced, so neither may change.
pub fn hashIndexed(array: []const repr.Value) i32 {
    var hash: u32 = 33;
    for (array) |x| hash = hashMix(hash, @bitCast(order.hash(x)));
    return @bitCast(hash);
}

/// Hash a run of key-value pairs, for `structs.end`.
pub fn hashDictionary(kvs: []const tables.KV) i32 {
    var hash: u32 = 33;
    for (kvs) |kv| {
        hash = hashMix(hash, @bitCast(order.hash(kv.key)));
        hash = hashMix(hash, @bitCast(order.hash(kv.value)));
    }
    return @bitCast(hash);
}

/// A hash folded into a bucket index.
///
/// The mask is `cap - 1` rather than `cap % capacity` because every capacity
/// the runtime produces is a power of two. **It is not written to survive a
/// capacity of zero**, and no constructor produces one: the mask would become
/// `0xFFFFFFFF`, the identity, and the probes below would run off the array.
///
/// The subtraction wraps rather than trapping. No reachable call passes
/// `INT32_MIN` -- `capacityFor` never answers it -- so a trap here would be
/// inventing a behaviour for an argument nothing supplies.
inline fn mapHash(cap: i32, hash: i32) i32 {
    return @bitCast(@as(u32, @bitCast(hash)) & @as(u32, @bitCast(cap -% 1)));
}

inline fn isNil(val: repr.Value) bool {
    return repr.checkType(val, repr.Tag.nil);
}

/// Find the bucket holding `key`, or the first bucket it could be put in.
///
/// The two loops are one circular scan from `index`. A bucket whose key *and*
/// value are nil has never
/// been used and ends the scan; a bucket whose key is nil and whose value is
/// not is a tombstone, remembered as a candidate and scanned past, because the
/// key may still be further along. So the answer is the key's own bucket if it
/// is present, the first tombstone if it is not, and a truly empty bucket
/// otherwise -- which is the order `tables.put` depends on, and the reason it
/// never has a tombstone to retire.
///
/// A capacity of zero sends this off the array; see `mapHash`. No constructor
/// produces one, and a safety-checked build traps at the first index rather
/// than reading below the array.
pub fn dictionaryFind(buckets: []const tables.KV, key: repr.Value) ?*const tables.KV {
    const cap: i32 = @intCast(buckets.len);
    const index = mapHash(cap, order.hash(key));
    var first_bucket: ?*const tables.KV = null;

    // **Index loops, not `for (buckets[start..]) |*kv|`, and this is measured.**
    // Zig's `for` over a sub-slice with a pointer capture keeps both the
    // element pointer and the index live, so the probe carries three induction
    // updates per iteration (`add`, `add`, `subs`) where an index carries two.
    // On a body this small that is about 10% per iteration, and the probe is
    // the hottest loop in the tree: `methods` measured 3-5% slower over an
    // isolated proto-chain benchmark with the `for` form. `DESIGN.md` section
    // 13 decides it: a measured regression is a reason to choose the faster
    // shape.
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

/// The same probe for a key given as bytes rather than as a `Janet`.
///
/// It exists so that a lookup by name neither interns a symbol nor allocates:
/// the comparison is against the bucket's own string head, so a keyword, a
/// symbol and a string with the same bytes all match. The type check names
/// `repr.Tag.keyword` alone, and that is not an oversight: the three tags
/// share one representation, and the head is what the comparison reads.
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

/// The bucket test the two halves of `dictionaryFindKeyword` share.
///
/// The hash is compared before the bytes, which is what makes the probe cheap:
/// a string carries its hash in its head, so a mismatch costs one load.
fn matchesKeyword(key: repr.Value, hash: i32, cstr: []const u8) bool {
    if (!repr.checkType(key, repr.Tag.keyword)) return false;
    const str = wrap.toString(key);
    const head = stringHead(str);
    if (head.hash != hash or head.length != cstr.len) return false;
    return std.mem.eql(u8, str[0..cstr.len], cstr);
}

/// Look a key up in a struct or table's buckets, answering nil for absent.
pub fn dictionaryGet(data: []const tables.KV, key: repr.Value) repr.Value {
    const kv = dictionaryFind(data, key) orelse return wrap.fromNil();
    if (!isNil(kv.key)) return kv.value;
    return wrap.fromNil();
}

/// Walk the occupied buckets of a struct or table in bucket order.
///
/// A null `kv` starts the walk and a null return ends it, so a caller writes
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

// -------------------------------------------------------- empty bucket arrays
//
// They are allocation rather than representation -- a `utils.rawAlloc`, a
// collection charge and an out-of-memory exit -- and what they allocate is a
// bucket array, which is this bucket's subject: `tables.zig` and `structs.zig`
// are the two callers.

/// A bucket array's size in bytes. The multiply wraps; a bucket count is a
/// `usize` and `capacityFor`, which clamps at `INT32_MAX`, is the only thing
/// that produces one.
inline fn kvBytes(count: usize) usize {
    return count *% @sizeOf(tables.KV);
}

/// A heap block of `count` key/value pairs, every one of them nil, charged
/// against the collection budget.
///
/// `utils.rawAlloc` exits the process rather than answering null, so the
/// charge below it runs only on the path that got the memory.
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

/// The same fill over a block the caller already owns, which
/// is how a table is cleared and how a struct's bucket array is initialised
/// from the scratch allocator.
pub fn memempty(mem: []tables.KV) void {
    for (mem) |*kv| {
        kv.key = wrap.fromNil();
        kv.value = wrap.fromNil();
    }
}
