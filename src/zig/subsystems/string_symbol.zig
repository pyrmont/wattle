//! jump-transparent
//!
//! The immutable head-allocated sequences: strings, symbols and the symbol
//! cache, and tuples. This is Part 6b of Phase 8, and it takes the
//! data-structure core of `src/core/string.c`, the whole of
//! `src/core/symcache.c`, and the constructors in `src/core/tuple.c`. The
//! `JANET_CORE_FN` bodies in `string.c` and `tuple.c` stay in C, along with
//! `string.c`'s Knuth-Morris-Pratt searcher, on the same rule Part 6a followed:
//! the standard-library surface is not value construction.
//!
//! These three belong together because they are one allocation strategy. A
//! buffer or an array is a fixed-size block pointing at a payload that can be
//! reallocated; a string, a symbol or a tuple is a header and its payload in a
//! *single* `janet_gcalloc`, sized once and never resized. That is what makes
//! them immutable in the runtime's sense, and it is why they share three
//! things the growable containers do not have:
//!
//!  - **A head recovered by pointer arithmetic.** The value Janet passes
//!    around is the address of the payload, not of the block, so every
//!    operation subtracts the header size to get back to the header. `gc_sweep.zig`
//!    already does this for the free path; `stringHead` and `tupleHead` below
//!    are the same shape, `@sizeOf` rather than `@offsetOf` because translate-c
//!    drops the flexible array member. `test/gc_sweep.c` pins the equality from
//!    C and `test/string_symbol.c` pins it again for the tuple head.
//!  - **A hash computed once, at the end of construction.** `janet_string_begin`
//!    and `janet_tuple_begin` leave `hash` uninitialised and `janet_string_end`
//!    and `janet_tuple_end` fill it in. A value observed between the two has an
//!    indeterminate hash, which is why nothing may put it in a dictionary
//!    before `end` runs. Preserved exactly; the port does not helpfully zero it.
//!  - **Interning, for symbols.** `janet_symbol` is `janet_string` plus a
//!    lookup in `janet_vm.cache`, and the cache is the only structure in this
//!    file that is not itself a Janet value.
//!
//! Tuples ride along rather than forming a group of their own: `tuple.c`'s core
//! is three functions and twenty-five lines, and every one of them is the
//! string pattern with `Janet` in place of `uint8_t`.
//!
//! ## The symbol cache is the collector's one external obligation
//!
//! Everything else the collector frees is self-contained. A symbol is not: it
//! is registered in `janet_vm.cache` at construction, and if it were freed
//! without being removed the cache would hold a pointer to released memory and
//! the next symbol that hashed to that bucket would compare against it. So
//! `janet_deinit_block` in `gc_sweep.zig` calls `janet_symbol_deinit` from this
//! file, which is why Part 5 already needed a declaration for it -- and why
//! that declaration now resolves to Zig on both ends.
//!
//! The cache is open-addressed with tombstones, and the tombstone is compared
//! by address rather than by content. `symcache_deleted` below is declared
//! `var` for that reason: a `const` single zero byte is exactly the sort of
//! object a linker may merge with an identical constant elsewhere in the image,
//! and a merged tombstone would alias something that is not one.
//!
//! ## What is reproduced rather than repaired
//!
//! `janet_cache_resize` re-inserts the old entries and `break`s out of the loop
//! if a re-insertion reports the key was already present or returns no bucket.
//! Neither can happen -- the cache holds no duplicates and `janet_symcache_findmem`
//! exits the process rather than returning null -- but the `break` abandons
//! every remaining entry while still freeing the old table, so the defensive
//! path is worse than the condition it defends against. Preserved as written.
//!
//! `janet_symcache_findmem` ends the process through `janet_assert` when the
//! table is full, and the load factor that is supposed to make that impossible
//! has a gap at a capacity of two. It is reachable: a rehash chooses two
//! buckets when `cache_count` is zero, and `janet_init` leaves it at zero
//! because the core environment is built lazily. Five hundred and thirteen
//! transient symbols, one collection and three more symbols abort the process.
//! `FOUND.md` has it, with the reproducer. The port
//! reproduces both the policy and the exit.
//!
//! ## Jump transparency
//!
//! Nothing in this file calls `janet_panic`, but `janet_gcalloc` can trigger a
//! collection and a finalizer may raise, so a signal can still unwind through
//! these frames. There is no `defer` here and `build.zig` checks that there is
//! not.
//!
//! One place in this file is worth naming for that reason, because it is the
//! only one where a raw block is held across a call. `janet_symbol` allocates
//! the symbol, fills in its head, and only then calls `janet_symcache_put`,
//! which may allocate a new table -- but the symbol is already on a heap list
//! by then, so a signal from anywhere in `put` loses the *cache entry* rather
//! than the block. The result is a live, uninterned symbol: correct as a value,
//! and a duplicate the next `janet_symbol` of the same name will not find. That
//! is what the C does, and the port does not improve on it.

const std = @import("std");
const abi = @import("abi");
const c = abi.c;

/// `janet_vm` as `src/core/state.h` declares it, resolved through `abi.zig`.
inline fn vm() *c.JanetVM {
    return &c.janet_vm;
}

/// Three functions from `src/core/util.c`, declared here rather than imported.
/// `util.h` is deliberately outside `abi.zig` -- see the note at the head of
/// that file.
///
/// `janet_array_calchash` widens the standing rule slightly and it is worth
/// saying so: the other two take primitive parameters, and this one takes a
/// `const Janet *`. The single-translation rule is still satisfied, because the
/// `c.Janet` in the signature below is the shared translation's type rather
/// than a second one -- but the justification usually given for declaring a
/// `util.h` function directly, that no Janet type crosses, does not apply here.
/// What applies instead is that hashing belongs to `value.c` and moves in Part
/// 7; until then this is the only way to reach it.
extern fn safe_memcpy(dest: ?*anyopaque, src: ?*const anyopaque, len: usize) callconv(.c) void;
extern fn janet_string_calchash(str: [*c]const u8, len: i32) callconv(.c) i32;
extern fn janet_array_calchash(array: [*c]const c.Janet, len: i32) callconv(.c) i32;
extern fn janet_tablen(n: i32) callconv(.c) i32;

/// C's conversion of a signed count to `size_t`: sign-extend to the pointer
/// width, then reinterpret. Every length here reaches an allocation size, and a
/// negative length becomes a request C cannot satisfy rather than a trap one
/// statement earlier. Same helper, and same reason, as `buffer_array.zig`.
inline fn asSize(n: i32) usize {
    return @bitCast(@as(isize, n));
}

// ------------------------------------------------------------------- heads

/// Recover a head from the payload address Janet passes around. `@sizeOf`
/// rather than `@offsetOf`, because translate-c drops the flexible array
/// member and the two are equal for these layouts.
inline fn stringHead(s: [*c]const u8) *c.JanetStringHead {
    return @ptrFromInt(@intFromPtr(s) -% @sizeOf(c.JanetStringHead));
}

inline fn tupleHead(t: [*c]const c.Janet) *c.JanetTupleHead {
    return @ptrFromInt(@intFromPtr(t) -% @sizeOf(c.JanetTupleHead));
}

/// And the inverse, for a block that `janet_gcalloc` just returned.
inline fn stringData(head: *c.JanetStringHead) [*c]u8 {
    return @ptrFromInt(@intFromPtr(head) +% @sizeOf(c.JanetStringHead));
}

inline fn tupleData(head: *c.JanetTupleHead) [*c]c.Janet {
    return @ptrFromInt(@intFromPtr(head) +% @sizeOf(c.JanetTupleHead));
}

inline fn stringLength(s: [*c]const u8) i32 {
    return stringHead(s).length;
}

inline fn stringHash(s: [*c]const u8) i32 {
    return stringHead(s).hash;
}

// ------------------------------------------------------------------ string

/// Allocate a string of `length` bytes and terminate it. The bytes themselves
/// are uninitialised and so is the hash: the caller fills the first and
/// `janet_string_end` computes the second.
export fn janet_string_begin(length: i32) callconv(.c) [*c]u8 {
    const head: *c.JanetStringHead = @ptrCast(@alignCast(c.janet_gcalloc(
        c.JANET_MEMORY_STRING,
        @sizeOf(c.JanetStringHead) +% asSize(length) +% 1,
    )));
    head.length = length;
    const data = stringData(head);
    data[@intCast(length)] = 0;
    return data;
}

/// Close a string built by hand. This is the only place a string's hash is
/// written outside `janet_string`, and until it runs the head holds whatever
/// the allocator left there.
export fn janet_string_end(str: [*c]u8) callconv(.c) [*c]const u8 {
    stringHead(str).hash = janet_string_calchash(str, stringLength(str));
    return str;
}

/// Allocate a string and fill it from `buf` in one step.
export fn janet_string(buf: [*c]const u8, len: i32) callconv(.c) [*c]const u8 {
    const head: *c.JanetStringHead = @ptrCast(@alignCast(c.janet_gcalloc(
        c.JANET_MEMORY_STRING,
        @sizeOf(c.JanetStringHead) +% asSize(len) +% 1,
    )));
    head.length = len;
    head.hash = janet_string_calchash(buf, len);
    const data = stringData(head);
    safe_memcpy(@ptrCast(data), @ptrCast(buf), asSize(len));
    data[@intCast(len)] = 0;
    return data;
}

/// Order two strings. Shorter is less when one is a prefix of the other, and
/// the `memcmp` result is normalised to -1, 0 or 1 rather than passed through:
/// `memcmp` may return any value of the right sign, and Janet's comparison
/// contract is the three-valued one.
export fn janet_string_compare(lhs: [*c]const u8, rhs: [*c]const u8) callconv(.c) c_int {
    const xlen = stringLength(lhs);
    const ylen = stringLength(rhs);
    const len = if (xlen > ylen) ylen else xlen;
    const res = c.memcmp(lhs, rhs, @intCast(len));
    if (res != 0) return if (res > 0) 1 else -1;
    if (xlen == ylen) return 0;
    return if (xlen < ylen) -1 else 1;
}

/// Compare an interned string against a length and hash the caller already has,
/// which is what makes the symbol cache cheap: an unequal hash rejects without
/// touching the bytes.
export fn janet_string_equalconst(lhs: [*c]const u8, rhs: [*c]const u8, rlen: i32, rhash: i32) callconv(.c) c_int {
    const lhash = stringHash(lhs);
    const llen = stringLength(lhs);
    if (lhash != rhash or llen != rlen) return 0;
    if (lhs == rhs) return 1;
    return @intFromBool(c.memcmp(lhs, rhs, @intCast(rlen)) == 0);
}

export fn janet_string_equal(lhs: [*c]const u8, rhs: [*c]const u8) callconv(.c) c_int {
    return janet_string_equalconst(lhs, rhs, stringLength(rhs), stringHash(rhs));
}

export fn janet_cstring(str: [*c]const u8) callconv(.c) [*c]const u8 {
    return janet_string(str, @intCast(c.strlen(str)));
}

// ------------------------------------------------------------ symbol cache

/// The tombstone, compared by address and never dereferenced. Declared `var`
/// so that the linker cannot merge this single zero byte with an identical
/// constant elsewhere in the image; the C original is a `static const` in a
/// translation unit of its own, which has the same effect for a different
/// reason.
var symcache_deleted: [1]u8 = .{0};

inline fn deleted() [*c]const u8 {
    return @ptrCast(&symcache_deleted);
}

/// Allocate the cache. Called from `janet_init` before anything can intern.
export fn janet_symcache_init() callconv(.c) void {
    const v = vm();
    v.cache_capacity = 1024;
    v.cache = @ptrCast(@alignCast(c.janet_calloc(1, @as(usize, v.cache_capacity) *% @sizeOf(?*const u8)) orelse
        c.janet_zig_out_of_memory()));
    @memset(&v.gensym_counter, '0');
    v.gensym_counter[0] = '_';
    v.cache_count = 0;
    v.cache_deleted = 0;
}

/// Release the cache. The symbols it points at are not freed here: they are
/// ordinary collectable blocks and `janet_clear_memory` deals with them.
export fn janet_symcache_deinit() callconv(.c) void {
    const v = vm();
    c.janet_free(@ptrCast(@constCast(v.cache)));
    v.cache = null;
    v.cache_capacity = 0;
    v.cache_count = 0;
    v.cache_deleted = 0;
}

/// Find `str` in the cache, or the bucket it belongs in.
///
/// The scan covers the whole table in two ranges -- the ideal index to the end,
/// then the start to the ideal index -- and stops at the first genuinely empty
/// slot, because open addressing guarantees nothing lies beyond one. Tombstones
/// do not stop it, but the first one is remembered, and a key found *after* a
/// tombstone is moved back into it. That last move is why this function is not
/// a pure lookup: it rewrites the table on a successful find, which keeps
/// probe sequences short without a separate compaction pass.
fn symcacheFindmem(str: [*c]const u8, len: i32, hash: i32, success: *c_int) [*c][*c]const u8 {
    const v = vm();
    var first_empty: [*c][*c]const u8 = null;

    const index: u32 = @as(u32, @bitCast(hash)) & (v.cache_capacity -% 1);
    const bounds = [4]u32{ index, v.cache_capacity, 0, index };

    scan: {
        var j: usize = 0;
        while (j < 4) : (j += 2) {
            var i: u32 = bounds[j];
            while (i < bounds[j + 1]) : (i += 1) {
                const entry = v.cache[i];
                if (entry == null) {
                    if (first_empty == null) first_empty = v.cache + i;
                    break :scan;
                }
                if (deleted() == entry) {
                    if (first_empty == null) first_empty = v.cache + i;
                    continue;
                }
                if (janet_string_equalconst(entry, str, len, hash) != 0) {
                    success.* = 1;
                    if (first_empty != null) {
                        first_empty.* = entry;
                        v.cache[i] = deleted();
                        return first_empty;
                    }
                    return v.cache + i;
                }
            }
        }
    }

    success.* = 0;
    // The load factor `janet_symcache_put` maintains is what makes a full table
    // impossible, and `FOUND.md` records the one capacity where it does not.
    if (first_empty == null) c.janet_zig_fatal("symcache failed to get memory");
    return first_empty;
}

/// `janet_symcache_find` in `symcache.c`, which is a macro there.
inline fn symcacheFind(str: [*c]const u8, success: *c_int) [*c][*c]const u8 {
    return symcacheFindmem(str, stringLength(str), stringHash(str), success);
}

/// Rebuild the table at a new capacity, dropping every tombstone.
fn cacheResize(new_capacity: u32) void {
    const v = vm();
    const old_cache = v.cache;
    const new_cache: [*c][*c]const u8 = @ptrCast(@alignCast(c.janet_calloc(1, @as(usize, new_capacity) *% @sizeOf(?*const u8)) orelse
        c.janet_zig_out_of_memory()));
    const old_capacity = v.cache_capacity;
    v.cache = new_cache;
    v.cache_capacity = new_capacity;
    v.cache_deleted = 0;
    var i: u32 = 0;
    while (i < old_capacity) : (i += 1) {
        const x = old_cache[i];
        if (x != null and deleted() != x) {
            var status: c_int = 0;
            const bucket = symcacheFind(x, &status);
            // Neither condition is reachable, and the recovery abandons every
            // remaining entry while still freeing the old table. Preserved.
            if (status != 0 or bucket == null) break;
            bucket.* = x;
        }
    }
    c.janet_free(@ptrCast(@constCast(old_cache)));
}

/// Install `x` in `bucket`, growing the table first if it is half full.
/// Counting tombstones toward the load factor is what stops a long run of
/// create-and-collect from degrading every probe to a full scan.
fn symcachePut(x: [*c]const u8, bucket_in: [*c][*c]const u8) void {
    const v = vm();
    var bucket = bucket_in;
    if ((v.cache_count +% v.cache_deleted) *% 2 > v.cache_capacity) {
        var status: c_int = 0;
        cacheResize(@bitCast(janet_tablen(@bitCast(2 *% v.cache_count +% 1))));
        bucket = symcacheFind(x, &status);
    }
    v.cache_count +%= 1;
    bucket.* = x;
}

/// Drop a symbol from the cache. Called by `janet_deinit_block` on the way to
/// freeing the block, and it is the collector's one obligation to a structure
/// outside itself.
export fn janet_symbol_deinit(sym: [*c]const u8) callconv(.c) void {
    const v = vm();
    var status: c_int = 0;
    const bucket = symcacheFind(sym, &status);
    if (status != 0) {
        v.cache_count -%= 1;
        v.cache_deleted +%= 1;
        bucket.* = deleted();
    }
}

/// Intern a symbol: return the existing one if the name is already cached, and
/// otherwise build it and register it.
export fn janet_symbol(str: [*c]const u8, len: i32) callconv(.c) [*c]const u8 {
    const hash = janet_string_calchash(str, len);
    var success: c_int = 0;
    const bucket = symcacheFindmem(str, len, hash, &success);
    if (success != 0) return bucket.*;

    const head: *c.JanetStringHead = @ptrCast(@alignCast(c.janet_gcalloc(
        c.JANET_MEMORY_SYMBOL,
        @sizeOf(c.JanetStringHead) +% asSize(len) +% 1,
    )));
    head.hash = hash;
    head.length = len;
    const newstr = stringData(head);
    safe_memcpy(@ptrCast(newstr), @ptrCast(str), asSize(len));
    newstr[@intCast(len)] = 0;
    symcachePut(newstr, bucket);
    return newstr;
}

export fn janet_csymbol(cstr: [*c]const u8) callconv(.c) [*c]const u8 {
    return janet_symbol(cstr, @intCast(c.strlen(cstr)));
}

/// Increment the gensym counter, a base-62 odometer over positions 1 through 6.
/// Position 0 holds the leading underscore and is never touched, so the counter
/// wraps silently after 62^6 names rather than growing.
fn incGensym() void {
    const v = vm();
    var i: usize = v.gensym_counter.len - 2;
    while (i != 0) : (i -= 1) {
        if (v.gensym_counter[i] == '9') {
            v.gensym_counter[i] = 'a';
            break;
        } else if (v.gensym_counter[i] == 'z') {
            v.gensym_counter[i] = 'A';
            break;
        } else if (v.gensym_counter[i] == 'Z') {
            v.gensym_counter[i] = '0';
        } else {
            v.gensym_counter[i] += 1;
            break;
        }
    }
}

/// A symbol guaranteed not to collide with any live one. The counter is
/// advanced until a name is found that the cache does not already hold, which
/// matters because a gensym from an earlier cycle may still be alive.
export fn janet_symbol_gen() callconv(.c) [*c]const u8 {
    const v = vm();
    const name_len: i32 = @intCast(v.gensym_counter.len - 1);
    var bucket: [*c][*c]const u8 = null;
    var hash: i32 = 0;
    var status: c_int = 0;
    while (true) {
        hash = janet_string_calchash(&v.gensym_counter, name_len);
        bucket = symcacheFindmem(&v.gensym_counter, name_len, hash, &status);
        if (status == 0) break;
        incGensym();
    }
    const head: *c.JanetStringHead = @ptrCast(@alignCast(c.janet_gcalloc(
        c.JANET_MEMORY_SYMBOL,
        @sizeOf(c.JanetStringHead) +% v.gensym_counter.len,
    )));
    head.length = name_len;
    head.hash = hash;
    const sym = stringData(head);
    // The whole counter is copied and the terminator then overwrites its last
    // byte, so the name is the first `len` characters of the odometer.
    @memcpy(sym[0..v.gensym_counter.len], &v.gensym_counter);
    sym[@intCast(head.length)] = 0;
    symcachePut(sym, bucket);
    return sym;
}

// ------------------------------------------------------------------- tuple

/// Allocate a tuple of `length` slots. The slots and the hash are
/// uninitialised; the source-map fields are set to -1, which is what marks a
/// tuple as having no position rather than one at line zero.
export fn janet_tuple_begin(length: i32) callconv(.c) [*c]c.Janet {
    const size = @sizeOf(c.JanetTupleHead) +% (asSize(length) *% @sizeOf(c.Janet));
    const head: *c.JanetTupleHead = @ptrCast(@alignCast(c.janet_gcalloc(c.JANET_MEMORY_TUPLE, size)));
    head.sm_line = -1;
    head.sm_column = -1;
    head.length = length;
    return tupleData(head);
}

/// Close a tuple, which is where its hash comes from. Every slot must be
/// filled before this runs -- the hash covers all of them.
export fn janet_tuple_end(tuple: [*c]c.Janet) callconv(.c) [*c]const c.Janet {
    tupleHead(tuple).hash = janet_array_calchash(tuple, tupleHead(tuple).length);
    return tuple;
}

export fn janet_tuple_n(values: [*c]const c.Janet, n: i32) callconv(.c) [*c]const c.Janet {
    const t = janet_tuple_begin(n);
    safe_memcpy(@ptrCast(t), @ptrCast(values), @sizeOf(c.Janet) *% asSize(n));
    return janet_tuple_end(t);
}
