//! The runtime's shared substrate: everything in `src/core/util.c` that is not
//! registration, resolution or the clock.
//!
//! Phase 5 took the three hash helpers and `janet_tablen`; Phase 10 Part 5
//! added the four out-of-line head accessors; Phase 10 Part 17f took the rest
//! of what `-Dutilities` owns — the collection hashes, the dictionary probe
//! every table and struct lookup goes through, the two string comparisons, the
//! key sort, and the four host services `util.c` kept beside them.
//!
//! Nothing here raises. That is what makes it the part of `util.c` that could
//! be ported without touching the raise mechanism, and it is why the file has
//! no jump-transparent marker: there is no frame here a C raise can be thrown
//! through, so `defer` is legal and used.
//!
//! `registry.zig` has the half that does own VM state — the cfunction
//! registry, the registration entry points, the abstract-type registry, and
//! bindings.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi");
const c = abi.c;

const hash_seed: u32 = 0x9e3779b9;
const hash_key_size = c.JANET_HASH_KEY_SIZE;

const windows = builtin.os.tag == .windows;

var hash_key: [hash_key_size]u8 = @splat(0);

comptime {
    if (@hasDecl(c, "JANET_PRF")) {
        @export(&initHashKey, .{ .name = "janet_init_hash_key" });
    }
}

export fn janet_hash_mix(input: u32, more: u32) callconv(.c) u32 {
    const mix = more +% hash_seed +% (input << 6) +% (input >> 2);
    return input ^ (hash_seed +% (mix << 6) +% (mix >> 2));
}

export fn janet_string_calchash(string: [*c]const u8, length: i32) callconv(.c) i32 {
    if (@hasDecl(c, "JANET_PRF")) {
        return @bitCast(halfSipHash(string, @intCast(length), &hash_key));
    }

    if (string == null or length == 0) return 5381;
    var hash: u32 = 5381;
    for (string[0..@intCast(length)]) |byte| {
        hash = (hash << 5) +% hash +% byte;
    }
    return @bitCast(janet_hash_mix(hash, @bitCast(length)));
}

export fn janet_tablen(value: i32) callconv(.c) i32 {
    if (value < 0) return 0;
    var result = value;
    result |= result >> 1;
    result |= result >> 2;
    result |= result >> 4;
    result |= result >> 8;
    result |= result >> 16;
    return if (result == std.math.maxInt(i32)) result else result + 1;
}

fn initHashKey(new_key: [*c]u8) callconv(.c) void {
    @memcpy(&hash_key, new_key[0..hash_key.len]);
}

fn halfSipHash(input: [*c]const u8, length: usize, key: *const [hash_key_size]u8) u32 {
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

    const word_bytes = length - (length % 4);
    var offset: usize = 0;
    while (offset < word_bytes) : (offset += 4) {
        const message = readU32Little(input[offset..][0..4]);
        v3 ^= message;
        sipRound(&v0, &v1, &v2, &v3);
        sipRound(&v0, &v1, &v2, &v3);
        v0 ^= message;
    }

    var final: u32 = @as(u32, @truncate(length)) << 24;
    const remaining = length - word_bytes;
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

fn rotateLeft(value: u32, comptime amount: u5) u32 {
    return std.math.rotl(u32, value, amount);
}

fn readU32Little(bytes: *const [4]u8) u32 {
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}

// ------------------------------------------------------------------- heads

// The out-of-line twins of four macros in `janet.h`, moved out of `capi.c` in
// Phase 10 Part 5. C spells each `(janet_struct_head)(st)` -- parenthesised so
// the macro does not eat the definition -- and provides it for an embedder who
// reaches Janet through the shared library rather than the header.
//
// The arithmetic is written out rather than delegated to `c.janet_*_head`.
// Each name is both a macro and a prototype in `janet.h`, and which of the two
// translate-c hands back is not something this file should depend on: if it
// were the prototype, the body below would be a call to itself.

// The offset is recovered by `@sizeOf` rather than `@offsetOf`, because
// translate-c drops the flexible array member the C macro takes the offset of.
// The two agree because `data` is maximally aligned within every one of these
// heads; `test/utils.c` checks that from the C side, where the member is
// visible.
fn headOf(comptime Head: type, comptime Data: type, data: [*c]const Data) [*c]Head {
    return @ptrFromInt(@intFromPtr(data) -% @sizeOf(Head));
}

export fn janet_struct_head(st: [*c]const c.JanetKV) callconv(.c) [*c]c.JanetStructHead {
    return headOf(c.JanetStructHead, c.JanetKV, st);
}

export fn janet_abstract_head(abstract: ?*const anyopaque) callconv(.c) [*c]c.JanetAbstractHead {
    return @ptrFromInt(@intFromPtr(abstract) -% @sizeOf(c.JanetAbstractHead));
}

export fn janet_string_head(s: [*c]const u8) callconv(.c) [*c]c.JanetStringHead {
    return headOf(c.JanetStringHead, u8, s);
}

export fn janet_tuple_head(tuple: [*c]const c.Janet) callconv(.c) [*c]c.JanetTupleHead {
    return headOf(c.JanetTupleHead, c.Janet, tuple);
}

// ------------------------------------------------------------- name tables
//
// Four tables of static strings. `janet.h` exports the three name tables and
// `util.h` the base64 alphabet, and between them they are read from eleven Zig
// files and from `fiber.c` and `debug.c` -- every type name a message prints,
// every fiber status a trace names, and the two hex digits an escape is built
// from.
//
// They are data rather than code, and they move here because they were the
// last thing in `util.c` and because `-Dutilities` is where the rest of that
// file's substrate went. The C declarations are unchanged, so a reader of
// either arm sees the same symbols.

export const janet_base64: [65]u8 = ("0123456789" ++
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ" ++
    "abcdefghijklmnopqrstuvwxyz" ++
    "_=" ++ "\x00").*;

/// Indexed by `JanetType`, so the order is `janet.h`'s and not alphabetical.
export const janet_type_names: [16][*c]const u8 = .{
    "number",
    "nil",
    "boolean",
    "fiber",
    "string",
    "symbol",
    "keyword",
    "array",
    "tuple",
    "table",
    "struct",
    "buffer",
    "function",
    "cfunction",
    "abstract",
    "pointer",
};

/// Indexed by `JanetSignal`. Fourteen rather than sixteen: the eight user
/// signals are the middle of the range and `interrupt` and `await` close it.
export const janet_signal_names: [14][*c]const u8 = .{
    "ok",
    "error",
    "debug",
    "yield",
    "user0",
    "user1",
    "user2",
    "user3",
    "user4",
    "user5",
    "user6",
    "user7",
    "interrupt",
    "await",
};

/// Indexed by `JanetFiberStatus`. The first twelve line up with the signal
/// names above and the last four do not, which is why there are two tables.
export const janet_status_names: [16][*c]const u8 = .{
    "dead",
    "error",
    "debug",
    "pending",
    "user0",
    "user1",
    "user2",
    "user3",
    "user4",
    "user5",
    "user6",
    "user7",
    "interrupted",
    "suspended",
    "new",
    "alive",
};

// -------------------------------------------------- hashes over collections

/// Hash a run of values, for `janet_tuple_end`.
///
/// The seed is 33 rather than the 5381 the string hash starts from; both are
/// the C original's and neither is explained there.
export fn janet_array_calchash(array: [*c]const c.Janet, len: i32) callconv(.c) i32 {
    var hash: u32 = 33;
    var i: i32 = 0;
    while (i < len) : (i += 1) {
        hash = janet_hash_mix(hash, @bitCast(c.janet_hash(array[@intCast(i)])));
    }
    return @bitCast(hash);
}

/// Hash a run of key-value pairs, for `janet_struct_end`.
export fn janet_kv_calchash(kvs: [*c]const c.JanetKV, len: i32) callconv(.c) i32 {
    var hash: u32 = 33;
    var i: i32 = 0;
    while (i < len) : (i += 1) {
        const kv = kvs[@intCast(i)];
        hash = janet_hash_mix(hash, @bitCast(c.janet_hash(kv.key)));
        hash = janet_hash_mix(hash, @bitCast(c.janet_hash(kv.value)));
    }
    return @bitCast(hash);
}

// ------------------------------------------------------ the dictionary probe

/// `memcpy` that tolerates a zero length with a null pointer.
///
/// The C original's comment says it exists to "avoid some undefined behavior
/// that was common in the code base", and the behaviour is C's rule that a
/// null pointer may not be passed to `memcpy` even for zero bytes. Zig has the
/// same rule from the other side: a zero-length slice cannot be constructed
/// from a null pointer, so the early return is load-bearing here rather than
/// merely careful.
export fn safe_memcpy(dest: ?*anyopaque, src: ?*const anyopaque, len: usize) callconv(.c) void {
    if (len == 0) return;
    const to: [*]u8 = @ptrCast(dest.?);
    const from: [*]const u8 = @ptrCast(src.?);
    @memcpy(to[0..len], from[0..len]);
}

/// `janet_maphash` from `src/core/util.h`, which `abi.zig` does not translate.
///
/// The mask is `cap - 1` rather than `cap % capacity` because every capacity
/// the runtime produces is a power of two. It is not written to survive a
/// capacity of zero, and `FOUND.md`'s "A zero-capacity table cannot be looked
/// up in" is what happens when one arrives: the mask becomes `0xFFFFFFFF`, the
/// identity, and the probes below run off the array.
///
/// The subtraction wraps rather than trapping. `cap` is `INT32_MIN` in no
/// reachable call — `janet_tablen` never returns it — and C's own subtraction
/// would be undefined there, so there is nothing to reproduce and a trap would
/// be the port inventing a behaviour.
inline fn mapHash(cap: i32, hash: i32) i32 {
    return @bitCast(@as(u32, @bitCast(hash)) & @as(u32, @bitCast(cap -% 1)));
}

inline fn isNil(value: c.Janet) bool {
    return c.janet_checktype(value, c.JANET_NIL) != 0;
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
export fn janet_dict_find(buckets: [*c]const c.JanetKV, cap: i32, key: c.Janet) callconv(.c) [*c]const c.JanetKV {
    const index = mapHash(cap, c.janet_hash(key));
    var first_bucket: [*c]const c.JanetKV = null;

    var i: i32 = index;
    while (i < cap) : (i += 1) {
        const kv = &buckets[@intCast(i)];
        if (isNil(kv.key)) {
            if (isNil(kv.value)) return kv;
            if (first_bucket == null) first_bucket = kv;
        } else if (c.janet_equals(kv.key, key) != 0) {
            return kv;
        }
    }

    i = 0;
    while (i < index) : (i += 1) {
        const kv = &buckets[@intCast(i)];
        if (isNil(kv.key)) {
            if (isNil(kv.value)) return kv;
            if (first_bucket == null) first_bucket = kv;
        } else if (c.janet_equals(kv.key, key) != 0) {
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
export fn janet_dict_find_keyword(
    buckets: [*c]const c.JanetKV,
    cap: i32,
    cstr: [*c]const u8,
    cstr_len: i32,
) callconv(.c) [*c]const c.JanetKV {
    const hash = janet_string_calchash(cstr, cstr_len);
    const index = mapHash(cap, hash);
    var first_bucket: [*c]const c.JanetKV = null;

    var i: i32 = index;
    while (i < cap) : (i += 1) {
        const kv = &buckets[@intCast(i)];
        if (isNil(kv.key)) {
            if (isNil(kv.value)) return kv;
            if (first_bucket == null) first_bucket = kv;
        } else if (matchesKeyword(kv.key, hash, cstr, cstr_len)) {
            return kv;
        }
    }

    i = 0;
    while (i < index) : (i += 1) {
        const kv = &buckets[@intCast(i)];
        if (isNil(kv.key)) {
            if (isNil(kv.value)) return kv;
            if (first_bucket == null) first_bucket = kv;
        } else if (matchesKeyword(kv.key, hash, cstr, cstr_len)) {
            return kv;
        }
    }

    return first_bucket;
}

/// The bucket test the two halves of `janet_dict_find_keyword` share.
///
/// The hash is compared before the bytes, which is what makes the probe cheap:
/// a string carries its hash in its head, so a mismatch costs one load.
fn matchesKeyword(key: c.Janet, hash: i32, cstr: [*c]const u8, cstr_len: i32) bool {
    if (c.janet_checktype(key, c.JANET_KEYWORD) == 0) return false;
    const str = c.janet_unwrap_string(key);
    const head = janet_string_head(str);
    if (head.*.hash != hash or head.*.length != cstr_len) return false;
    const len: usize = @intCast(cstr_len);
    return std.mem.eql(u8, str[0..len], cstr[0..len]);
}

/// Look a key up in a struct or table's buckets, answering nil for absent.
export fn janet_dictionary_get(data: [*c]const c.JanetKV, cap: i32, key: c.Janet) callconv(.c) c.Janet {
    const kv = janet_dict_find(data, cap, key);
    if (kv != null and !isNil(kv.*.key)) return kv.*.value;
    return c.janet_wrap_nil();
}

/// Walk the occupied buckets of a struct or table in bucket order.
///
/// A null `kv` starts the walk and a null return ends it, so the whole
/// iteration is `while (kv = janet_dictionary_next(...)) != null`. Bucket order
/// is not insertion order and is not stable across a rehash.
export fn janet_dictionary_next(
    kvs: [*c]const c.JanetKV,
    cap: i32,
    kv: [*c]const c.JanetKV,
) callconv(.c) [*c]const c.JanetKV {
    const end = kvs + @as(usize, @intCast(cap));
    var cursor = if (kv == null) kvs else kv + 1;
    while (@intFromPtr(cursor) < @intFromPtr(end)) : (cursor += 1) {
        if (!isNil(cursor.*.key)) return cursor;
    }
    return null;
}

// ------------------------------------------------------ strings and searching

/// Compare a Janet string with a C string, without interning the second.
///
/// The Janet string knows its length and may contain a NUL; the C string ends
/// at one. So the loop stops at whichever comes first and the answer is decided
/// after it: equal only if both ended together.
///
/// `index` outlives the loop, which is why it is declared above it here as it
/// is in the C original -- the value it holds when the loop breaks is what
/// decides the result.
export fn janet_cstrcmp(str: [*c]const u8, other: [*c]const u8) callconv(.c) c_int {
    const len = janet_string_head(str).*.length;
    var index: i32 = 0;
    while (index < len) : (index += 1) {
        const at: usize = @intCast(index);
        const mine = str[at];
        const theirs = other[at];
        if (mine < theirs) return -1;
        if (mine > theirs) return 1;
        if (theirs == 0) break;
    }
    return if (other[@intCast(index)] == 0) 0 else -1;
}

/// Binary search a sorted array of structs whose first member is a `char *`.
///
/// The item size is a parameter rather than a type because the callers' element
/// types differ and C has no generics; the one invariant is that the name is
/// first. Zig could express this properly, and deliberately does not: the
/// signature is `janet.h`'s and every caller is still reached through it.
export fn janet_strbinsearch(
    tab: ?*const anyopaque,
    tabcount: usize,
    itemsize: usize,
    key: [*c]const u8,
) callconv(.c) ?*const anyopaque {
    const base: [*]const u8 = @ptrCast(tab.?);
    var low: usize = 0;
    var hi: usize = tabcount;
    while (low < hi) {
        const mid = low + ((hi - low) / 2);
        const item: *const [*c]const u8 = @ptrCast(@alignCast(base + mid * itemsize));
        const comp = janet_cstrcmp(key, item.*);
        if (comp < 0) {
            hi = mid;
        } else if (comp > 0) {
            low = mid + 1;
        } else {
            return @ptrCast(item);
        }
    }
    return null;
}

/// Fill `index_buffer` with the occupied bucket indices of a dictionary, in
/// key order, and answer how many there were.
///
/// The caller owns a buffer of at least `cap` entries. The sort is insertion
/// sort over the indices rather than over the buckets, so nothing in the
/// dictionary moves; the C original's comment calls it "simple insertion sort
/// here for now" and the port keeps both the algorithm and the comparison
/// order, because `janet_compare` decides key order for every printed table.
export fn janet_sorted_keys(
    dict: [*c]const c.JanetKV,
    cap: i32,
    index_buffer: [*c]i32,
) callconv(.c) i32 {
    var next_index: i32 = 0;
    var i: i32 = 0;
    while (i < cap) : (i += 1) {
        if (!isNil(dict[@intCast(i)].key)) {
            index_buffer[@intCast(next_index)] = i;
            next_index += 1;
        }
    }

    i = 1;
    while (i < next_index) : (i += 1) {
        const index_to_insert = index_buffer[@intCast(i)];
        const lhs = dict[@intCast(index_to_insert)].key;
        var j: i32 = i - 1;
        while (j >= 0) : (j -= 1) {
            index_buffer[@intCast(j + 1)] = index_buffer[@intCast(j)];
            const rhs = dict[@intCast(index_buffer[@intCast(j)])].key;
            if (c.janet_compare(lhs, rhs) >= 0) {
                index_buffer[@intCast(j + 1)] = index_to_insert;
                break;
            } else if (j == 0) {
                index_buffer[0] = index_to_insert;
            }
        }
    }

    return next_index;
}

// --------------------------------------------------------------- host services

/// `strerror` that is thread-safe where the host offers it.
///
/// Three cases, and they are the C original's. Microsoft's `strerror` is
/// already thread-safe, so Windows calls it directly. glibc's `strerror_r`
/// is the GNU one -- it *returns* the message and may not touch the buffer at
/// all, which is why its result is returned rather than the buffer. Everyone
/// else has the XSI one, which fills the buffer and returns an `int`.
///
/// The buffer is `janet_vm.strerror_buf`, so the answer is valid until the next
/// call on the same thread.
export fn janet_strerror(e: c_int) callconv(.c) [*c]const u8 {
    if (windows) return @ptrCast(strerror(e));
    const buf: [*]u8 = @ptrCast(&c.janet_vm.strerror_buf);
    const size = @sizeOf(@TypeOf(c.janet_vm.strerror_buf));
    if (builtin.target.isGnuLibC()) return @ptrCast(gnuStrerrorR(e, buf, size));
    _ = strerror_r(e, buf, size);
    return @ptrCast(buf);
}

extern fn strerror(e: c_int) callconv(.c) [*c]u8;

/// The XSI signature, which is the one every libc in this project's reach but
/// glibc actually has.
extern fn strerror_r(e: c_int, buf: [*]u8, len: usize) callconv(.c) c_int;

/// glibc's `strerror_r` is a different function with the same name: it returns
/// `char *`, and may answer a static string without touching the buffer at all.
/// One symbol cannot be declared twice, so the second signature is a cast of
/// the first rather than a second `extern`, and the cast is reached only under
/// the comptime test above.
const GnuStrerrorR = *const fn (c_int, [*]u8, usize) callconv(.c) [*c]u8;
const gnuStrerrorR: GnuStrerrorR = @ptrCast(&strerror_r);

/// Fill `out` with `n` cryptographically random bytes, answering 0 on success.
///
/// Three implementations, exactly as the C original picks them. Windows draws
/// from `rand_s` an `unsigned int` at a time; BSD and macOS have
/// `arc4random_buf`; everywhere else reads `/dev/urandom`, because the C
/// original's comment records that `getrandom` "doesn't seem to be uniformly
/// supported on linux distros".
///
/// Only one of the three is compiled for any target, which is the shape Phase
/// 10's rule 5 warns about: the Linux arm is type-checked by the Linux
/// cross-compile in the acceptance matrix and by nothing on this host.
export fn janet_cryptorand(out: [*c]u8, n: usize) callconv(.c) c_int {
    if (@hasDecl(c, "JANET_NO_CRYPTORAND")) return -1;

    if (windows) {
        var i: usize = 0;
        while (i < n) : (i += @sizeOf(c_uint)) {
            var v: c_uint = undefined;
            if (rand_s(&v) != 0) return -1;
            var j: usize = 0;
            while (j < @sizeOf(c_uint) and i + j < n) : (j += 1) {
                out[i + j] = @truncate(v & 0xff);
                v = v >> 8;
            }
        }
        return 0;
    }

    if (has_arc4random) {
        arc4random_buf(out, n);
        return 0;
    }

    var randfd: c_int = undefined;
    while (true) {
        randfd = std.c.open("/dev/urandom", .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
        if (!(randfd < 0 and errno() == EINTR)) break;
    }
    if (randfd < 0) return -1;

    var cursor = out;
    var left = n;
    while (left > 0) {
        var nread: isize = undefined;
        while (true) {
            nread = std.c.read(randfd, cursor, left);
            if (!(nread < 0 and errno() == EINTR)) break;
        }
        if (nread <= 0) {
            closeRetrying(randfd);
            return -1;
        }
        cursor += @intCast(nread);
        left -= @intCast(nread);
    }
    closeRetrying(randfd);
    return 0;
}

fn closeRetrying(fd: c_int) void {
    while (true) {
        if (!(std.c.close(fd) < 0 and errno() == EINTR)) break;
    }
}

/// `JANET_BSD || MAC_OS_X_VERSION_10_7` as the C original spells it. The second
/// comes from `<AvailabilityMacros.h>` and is defined on every macOS the
/// project supports, so the test is "a BSD, Apple included".
const has_arc4random = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .netbsd, .openbsd, .dragonfly => true,
    else => false,
};

extern fn arc4random_buf(buf: [*c]u8, nbytes: usize) callconv(.c) void;
extern fn rand_s(v: *c_uint) callconv(.c) c_int;

inline fn errno() c_int {
    return std.c._errno().*;
}

const EINTR: c_int = @intFromEnum(std.c.E.INTR);

// ------------------------------------------------------ dynamic module names

/// Turn a bare module name into a path the dynamic loader will treat as
/// relative to the working directory.
///
/// `dlopen("foo.so")` searches the loader's path; `dlopen("./foo.so")` does
/// not. A name that already starts with `.` or contains a `/` is left alone
/// and returned as-is, which is why the caller must not free the result
/// unconditionally -- it may be the argument. The C original's signature drops
/// the `const` to say so, and the port keeps that rather than improving it.
export fn get_processed_name(name: [*c]const u8) callconv(.c) [*c]u8 {
    if (name[0] == '.') return @constCast(name);
    var len: usize = 0;
    while (name[len] != 0) : (len += 1) {
        if (name[len] == '/') return @constCast(name);
    }
    const ret: [*c]u8 = @ptrCast(std.c.malloc(len + 3) orelse c.janet_zig_out_of_memory());
    ret[0] = '.';
    ret[1] = '/';
    @memcpy(ret[2 .. len + 3], name[0 .. len + 1]);
    return ret;
}

// `error_clib`, `load_clib`, `symbol_clib` and `free_clib` are not here.
// `get_processed_name` above is the part of `util.c`'s dynamic-module section
// that is the same on every platform; the rest is per-platform and lives in
// `dynlib.zig`, under this same selector, because one of the four raises and
// two callers share all of them.

// ------------------------------------------------------- allocator wrappers

// `janet.h` declares each of these beside a macro of the same name, the way it
// does the four head accessors above, and for the same reason: an embedder who
// reaches Janet through the shared library has no macro. Inside the runtime
// every call takes the macro, so nothing in the tree calls these four.
//
// They are ported rather than deleted. Phase 10's second decision ends the C
// ABI, which makes them dead weight -- but what the finished runtime exports is
// Phase 11's question, and deleting an exported symbol here would answer it
// early.

export fn janet_malloc(size: usize) callconv(.c) ?*anyopaque {
    return std.c.malloc(size);
}

export fn janet_free(ptr: ?*anyopaque) callconv(.c) void {
    std.c.free(ptr);
}

export fn janet_calloc(nmemb: usize, size: usize) callconv(.c) ?*anyopaque {
    return std.c.calloc(nmemb, size);
}

export fn janet_realloc(ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    return std.c.realloc(ptr, size);
}
