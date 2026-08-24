//! The immutable head-allocated sequences: strings, symbols and the symbol
//! cache, and tuples. This is Part 6b of Phase 8, and it takes the
//! data-structure core of `src/core/string.c`, the whole of
//! `src/core/symcache.c`, and the constructors in `src/core/tuple.c`. The
//! `JANET_CORE_FN` bodies in `string.c` and `tuple.c` stayed in C, along with
//! `string.c`'s Knuth-Morris-Pratt searcher, on the same rule Part 6a followed:
//! the standard-library surface is not value construction. Phase 10 Part 6
//! brought all three here, at the foot of the file.
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
//!    drops the flexible array member. `test/abi.c` pins the equality with a
//!    `_Static_assert` — the last place in the tree that can spell `offsetof` —
//!    and `test/gc_mark.zig` checks the offset the allocator actually used.
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
const corefn = @import("corefn");
const c = abi.c;
const containers = @import("containers.zig");
const raise = @import("raise");
const arglayer = @import("arglayer.zig");
const registration = @import("registration.zig");
const pp_format = @import("pp_format.zig");

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

// ==========================================================================
// tuple/*, the cfunction surface.
//
// Phase 10 Part 6. Everything above this line is value construction, which is
// what Phase 8 took; the standard-library surface stayed in C then because
// every one of these functions raises and nothing in Zig could. It can now,
// though not by returning: a `JanetCFunction` has no error channel in its
// signature, so a cfunction delivers a raise as the jump its C caller is
// waiting for whichever language it is written in. That is why this file's
// `//! jump-transparent` marker matters more than it did -- each of these
// frames may be jumped out of, and none of them holds anything.
// ==========================================================================

/// `janet_wrap_integer`, written out because the function it would call does
/// not exist in every configuration: `janet.h` declares it beside its macro,
/// and `wrap.c` defines the declaration only for the NaN-boxed layouts. Same
/// reasoning, and the same three lines, as `value_access.zig` and
/// `pp_pretty.zig`.
inline fn wrapInteger(x: i32) c.Janet {
    return c.janet_wrap_number(@floatFromInt(x));
}

fn cfunTupleBrackets(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    const tup = janet_tuple_n(argv, argc);
    tupleHead(tup).gc.flags |= @intCast(c.JANET_TUPLE_FLAG_BRACKETCTOR);
    return c.janet_wrap_tuple(tup);
}

fn cfunTupleSlice(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    const view = try arglayer.getIndexed(argv, 0);
    const range = try arglayer.getSlice(argc, argv);
    return c.janet_wrap_tuple(janet_tuple_n(view.items + @as(usize, @intCast(range.start)), range.end - range.start));
}

fn cfunTupleType(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    const tup = try arglayer.getTuple(argv, 0);
    if (tupleHead(tup).gc.flags & @as(i32, @intCast(c.JANET_TUPLE_FLAG_BRACKETCTOR)) != 0) {
        return c.janet_ckeywordv("brackets");
    }
    return c.janet_ckeywordv("parens");
}

fn cfunTupleSourcemap(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    const tup = try arglayer.getTuple(argv, 0);
    var contents: [2]c.Janet = .{
        wrapInteger(tupleHead(tup).sm_line),
        wrapInteger(tupleHead(tup).sm_column),
    };
    return c.janet_wrap_tuple(janet_tuple_n(&contents, 2));
}

fn cfunTupleSetmap(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 3);
    const tup = try arglayer.getTuple(argv, 0);
    tupleHead(tup).sm_line = try arglayer.getInteger(argv, 1);
    tupleHead(tup).sm_column = try arglayer.getInteger(argv, 2);
    return argv[0];
}

/// The two passes over `argv` are the C original's and are not redundant: the
/// first is what rejects a bad argument and what checks the total for
/// overflow, and it has to finish before anything is allocated, because
/// `janet_tuple_begin` would otherwise leave a half-filled tuple behind when
/// the second argument turned out not to be indexed.
fn cfunTupleJoin(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 0, -1);
    var total_len: i32 = 0;
    var i: i32 = 0;
    while (i < argc) : (i += 1) {
        var len: i32 = 0;
        var vals: [*c]const c.Janet = null;
        if (c.janet_indexed_view(argv[@intCast(i)], &vals, &len) == 0) {
            return pp_format.panicf("expected indexed type for argument %d, got %v", .{ i, argv[@intCast(i)] });
        }
        if (std.math.maxInt(i32) - total_len < len) return raise.panic("tuple too large");
        total_len += len;
    }
    const tup = janet_tuple_begin(total_len);
    var cursor = tup;
    i = 0;
    while (i < argc) : (i += 1) {
        var len: i32 = 0;
        var vals: [*c]const c.Janet = null;
        _ = c.janet_indexed_view(argv[@intCast(i)], &vals, &len);
        safe_memcpy(@ptrCast(cursor), @ptrCast(vals), asSize(len) *% @sizeOf(c.Janet));
        cursor += @intCast(len);
    }
    return c.janet_wrap_tuple(janet_tuple_end(tup));
}

export fn janet_lib_tuple(env: *c.JanetTable) callconv(.c) void {
    const entries = [_]corefn.Entry{
        corefn.reg("tuple/brackets", &cfunTupleBrackets, @src(), "(tuple/brackets & xs)", "Creates a new bracketed tuple containing the elements xs."),
        corefn.reg("tuple/slice", &cfunTupleSlice, @src(), "(tuple/slice arrtup [,start=0 [,end=(length arrtup)]])", "Take a sub-sequence of an array or tuple from index `start` " ++
            "inclusive to index `end` exclusive. If `start` or `end` are not provided, " ++
            "they default to 0 and the length of `arrtup`, respectively. " ++
            "`start` and `end` can also be negative to indicate indexing " ++
            "from the end of the input. Note that if `start` is negative it is " ++
            "exclusive, and if `end` is negative it is inclusive, to allow a full " ++
            "negative slice range. Returns the new tuple."),
        corefn.reg("tuple/type", &cfunTupleType, @src(), "(tuple/type tup)", "Checks how the tuple was constructed. Will return the keyword " ++
            ":brackets if the tuple was parsed with brackets, and :parens " ++
            "otherwise. The two types of tuples will behave the same most of " ++
            "the time, but will print differently and be treated differently by " ++
            "the compiler."),
        corefn.reg("tuple/sourcemap", &cfunTupleSourcemap, @src(), "(tuple/sourcemap tup)", "Returns the sourcemap metadata attached to a tuple, " ++
            "which is another tuple (line, column)."),
        corefn.reg("tuple/setmap", &cfunTupleSetmap, @src(), "(tuple/setmap tup line column)", "Set the sourcemap metadata on a tuple. line and column indicate " ++
            "should be integers."),
        corefn.reg("tuple/join", &cfunTupleJoin, @src(), "(tuple/join & parts)", "Create a tuple by joining together other tuples and arrays."),
        corefn.end,
    };
    corefn.install(env, &entries);
}

// ==========================================================================
// string/*, keyword/slice and symbol/slice, the cfunction surface.
// ==========================================================================

/// `src/core/util.h`, provided by `pp_format.zig` or `pp.c` according to
/// `-Dpp`.
extern fn janet_buffer_format(
    b: *c.JanetBuffer,
    strfrmt: [*c]const u8,
    argstart: i32,
    argc: i32,
    argv: [*c]c.Janet,
) callconv(.c) void;

/// Knuth-Morris-Pratt, and the one piece of this file that owns heap memory
/// across a call that can raise.
///
/// `lookup` comes from `janet_calloc` and is released by `deinit`. The C
/// original releases it on every path it can see and misses the ones it
/// cannot: `janet_text_substitution` runs a Janet function, and a panic from
/// there skips the `kmp_deinit` below it. That leak is reproduced rather than
/// repaired -- `FOUND.md` has it -- and reproducing it is also why nothing
/// here uses `defer` or `errdefer`.
///
/// Phase 10 Part 17f changed the *mechanism* of that raise without changing
/// the leak. A raising builtin now returns an error the `try` on
/// `registration.textSubstitution` propagates, so the skipped `deinit` is a
/// plain early return rather than a jump; a raising Janet *function* still
/// jumps out of `janet_call` inside that call, which is why this file keeps
/// its jump-transparent marker.
const KmpState = struct {
    i: i32,
    j: i32,
    textlen: i32,
    patlen: i32,
    lookup: [*c]i32,
    text: [*c]const u8,
    pat: [*c]const u8,

    fn init(text: [*c]const u8, textlen: i32, pat: [*c]const u8, patlen: i32) raise.Raising(KmpState) {
        if (patlen == 0) return raise.panic("expected non-empty pattern");
        const lookup: [*c]i32 = @ptrCast(@alignCast(c.janet_calloc(@intCast(patlen), @sizeOf(i32)) orelse
            c.janet_zig_out_of_memory()));
        const s: KmpState = .{
            .i = 0,
            .j = 0,
            .text = text,
            .pat = pat,
            .textlen = textlen,
            .patlen = patlen,
            .lookup = lookup,
        };
        var i: i32 = 1;
        var j: i32 = 0;
        while (i < patlen) : (i += 1) {
            while (j != 0 and pat[@intCast(j)] != pat[@intCast(i)]) j = lookup[@intCast(j - 1)];
            if (pat[@intCast(j)] == pat[@intCast(i)]) j += 1;
            lookup[@intCast(i)] = j;
        }
        return s;
    }

    fn deinit(s: *KmpState) void {
        c.janet_free(@ptrCast(s.lookup));
    }

    fn seti(s: *KmpState, i: i32) void {
        s.i = i;
        s.j = 0;
    }

    fn next(s: *KmpState) i32 {
        var i = s.i;
        var j = s.j;
        while (i < s.textlen) {
            if (s.text[@intCast(i)] == s.pat[@intCast(j)]) {
                if (j == s.patlen - 1) {
                    s.i = i + 1;
                    s.j = s.lookup[@intCast(j)];
                    return i - j;
                }
                i += 1;
                j += 1;
            } else if (j > 0) {
                j = s.lookup[@intCast(j - 1)];
            } else {
                i += 1;
            }
        }
        return -1;
    }
};

fn findsetup(argc: i32, argv: [*c]c.Janet, extra: i32) raise.Raising(KmpState) {
    try arglayer.arity(argc, 2, 3 + extra);
    const pat = try arglayer.getBytes(argv, 0);
    const text = try arglayer.getBytes(argv, 1);
    var start: i32 = 0;
    if (argc >= 3) {
        start = try arglayer.getInteger(argv, 2);
        if (start < 0) return raise.panic("expected non-negative start index");
    }
    var s = try KmpState.init(text.bytes, text.len, pat.bytes, pat.len);
    s.i = start;
    return s;
}

fn cfunStringSlice(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    const view = try arglayer.getBytes(argv, 0);
    const range = try arglayer.getSlice(argc, argv);
    return c.janet_wrap_string(janet_string(view.bytes + @as(usize, @intCast(range.start)), range.end - range.start));
}

fn cfunSymbolSlice(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    const view = try arglayer.getBytes(argv, 0);
    const range = try arglayer.getSlice(argc, argv);
    return c.janet_wrap_symbol(janet_symbol(view.bytes + @as(usize, @intCast(range.start)), range.end - range.start));
}

fn cfunKeywordSlice(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    const view = try arglayer.getBytes(argv, 0);
    const range = try arglayer.getSlice(argc, argv);
    // `janet.h` spells `janet_keyword` as a #define onto `janet_symbol`: a
    // keyword and a symbol are the same interned bytes under a different tag.
    return c.janet_wrap_keyword(janet_symbol(view.bytes + @as(usize, @intCast(range.start)), range.end - range.start));
}

fn cfunStringRepeat(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 2);
    const view = try arglayer.getBytes(argv, 0);
    const rep = try arglayer.getInteger(argv, 1);
    if (rep < 0) return raise.panic("expected non-negative number of repetitions");
    if (rep == 0) return c.janet_cstringv("");
    const mulres = @as(i64, rep) * view.len;
    if (mulres > std.math.maxInt(i32)) return raise.panic("result string is too long");
    const newbuf = janet_string_begin(@intCast(mulres));
    var offset: usize = 0;
    const total: usize = @intCast(mulres);
    while (offset < total) : (offset += asSize(view.len)) {
        safe_memcpy(@ptrCast(newbuf + offset), @ptrCast(view.bytes), asSize(view.len));
    }
    return c.janet_wrap_string(janet_string_end(newbuf));
}

fn cfunStringBytes(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    const view = try arglayer.getBytes(argv, 0);
    const tup = janet_tuple_begin(view.len);
    var i: i32 = 0;
    while (i < view.len) : (i += 1) tup[@intCast(i)] = wrapInteger(view.bytes[@intCast(i)]);
    return c.janet_wrap_tuple(janet_tuple_end(tup));
}

fn cfunStringFrombytes(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    const buf = janet_string_begin(argc);
    var i: i32 = 0;
    while (i < argc) : (i += 1) {
        buf[@intCast(i)] = @truncate(@as(u32, @bitCast(try arglayer.getInteger(argv, i))));
    }
    return c.janet_wrap_string(janet_string_end(buf));
}

/// ASCII only, as the docstring says: the two case functions test the byte
/// ranges directly rather than calling `tolower`, so a locale cannot change
/// what they do.
fn mapCase(comptime lo: u8, comptime hi: u8, comptime delta: i8, argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    const view = try arglayer.getBytes(argv, 0);
    const buf = janet_string_begin(view.len);
    var i: i32 = 0;
    while (i < view.len) : (i += 1) {
        const byte = view.bytes[@intCast(i)];
        buf[@intCast(i)] = if (byte >= lo and byte <= hi)
            @intCast(@as(i16, byte) + delta)
        else
            byte;
    }
    return c.janet_wrap_string(janet_string_end(buf));
}

fn cfunStringAsciilower(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    return try mapCase(65, 90, 32, argc, argv);
}

fn cfunStringAsciiupper(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    return try mapCase(97, 122, -32, argc, argv);
}

fn cfunStringReverse(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    const view = try arglayer.getBytes(argv, 0);
    const buf = janet_string_begin(view.len);
    var i: i32 = 0;
    while (i < view.len) : (i += 1) buf[@intCast(i)] = view.bytes[@intCast(view.len - 1 - i)];
    return c.janet_wrap_string(janet_string_end(buf));
}

fn cfunStringFind(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    var state = try findsetup(argc, argv, 0);
    const result = state.next();
    state.deinit();
    return if (result < 0) c.janet_wrap_nil() else wrapInteger(result);
}

fn cfunStringHasprefix(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 2);
    const prefix = try arglayer.getBytes(argv, 0);
    const str = try arglayer.getBytes(argv, 1);
    if (str.len < prefix.len) return c.janet_wrap_false();
    const n = asSize(prefix.len);
    return c.janet_wrap_boolean(@intFromBool(std.mem.eql(u8, prefix.bytes[0..n], str.bytes[0..n])));
}

fn cfunStringHassuffix(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 2);
    const suffix = try arglayer.getBytes(argv, 0);
    const str = try arglayer.getBytes(argv, 1);
    if (str.len < suffix.len) return c.janet_wrap_false();
    const n = asSize(suffix.len);
    const tail = str.bytes + asSize(str.len - suffix.len);
    return c.janet_wrap_boolean(@intFromBool(std.mem.eql(u8, suffix.bytes[0..n], tail[0..n])));
}

fn cfunStringFindall(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    var state = try findsetup(argc, argv, 0);
    const array = c.janet_array(0);
    while (true) {
        const result = state.next();
        if (result < 0) break;
        try containers.arrayPush(array, wrapInteger(result));
    }
    state.deinit();
    return c.janet_wrap_array(array);
}

const ReplaceState = struct { kmp: KmpState, subst: c.Janet };

fn replacesetup(argc: i32, argv: [*c]c.Janet) raise.Raising(ReplaceState) {
    try arglayer.arity(argc, 3, 4);
    const pat = try arglayer.getBytes(argv, 0);
    const subst = argv[1];
    const text = try arglayer.getBytes(argv, 2);
    var start: i32 = 0;
    if (argc == 4) {
        start = try arglayer.getInteger(argv, 3);
        if (start < 0) return raise.panic("expected non-negative start index");
    }
    var s: ReplaceState = .{
        .kmp = try KmpState.init(text.bytes, text.len, pat.bytes, pat.len),
        .subst = subst,
    };
    s.kmp.i = start;
    return s;
}

fn cfunStringReplace(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    var s = try replacesetup(argc, argv);
    const result = s.kmp.next();
    if (result < 0) {
        const text = s.kmp.text;
        const textlen = s.kmp.textlen;
        s.kmp.deinit();
        return c.janet_wrap_string(janet_string(text, textlen));
    }
    const subst = try registration.textSubstitution(
        &s.subst,
        s.kmp.text + @as(usize, @intCast(result)),
        @intCast(s.kmp.patlen),
        null,
    );
    const buf = janet_string_begin(s.kmp.textlen - s.kmp.patlen + subst.len);
    safe_memcpy(@ptrCast(buf), @ptrCast(s.kmp.text), asSize(result));
    safe_memcpy(@ptrCast(buf + asSize(result)), @ptrCast(subst.bytes), asSize(subst.len));
    safe_memcpy(
        @ptrCast(buf + asSize(result) + asSize(subst.len)),
        @ptrCast(s.kmp.text + asSize(result) + asSize(s.kmp.patlen)),
        asSize(s.kmp.textlen - result - s.kmp.patlen),
    );
    s.kmp.deinit();
    return c.janet_wrap_string(janet_string_end(buf));
}

fn cfunStringReplaceall(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    var s = try replacesetup(argc, argv);
    var b: c.JanetBuffer = undefined;
    var lastindex: i32 = 0;
    _ = c.janet_buffer_init(&b, s.kmp.textlen);
    while (true) {
        const result = s.kmp.next();
        if (result < 0) break;
        const subst = try registration.textSubstitution(
            &s.subst,
            s.kmp.text + @as(usize, @intCast(result)),
            @intCast(s.kmp.patlen),
            null,
        );
        try containers.bufferPushBytes(&b, s.kmp.text + asSize(lastindex), result - lastindex);
        try containers.bufferPushBytes(&b, subst.bytes, subst.len);
        lastindex = result + s.kmp.patlen;
        s.kmp.seti(lastindex);
    }
    try containers.bufferPushBytes(&b, s.kmp.text + asSize(lastindex), s.kmp.textlen - lastindex);
    const ret = janet_string(b.data, b.count);
    c.janet_buffer_deinit(&b);
    s.kmp.deinit();
    return c.janet_wrap_string(ret);
}

/// The limit arithmetic is the C original's, decrement and all: `limit`
/// defaults to -1, so `--limit` runs away from zero and never stops the loop,
/// and an explicit limit of 0 behaves like an explicit 1. Reproduced.
fn cfunStringSplit(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    var limit: i32 = -1;
    var lastindex: i32 = 0;
    if (argc == 4) limit = try arglayer.getInteger(argv, 3);
    var state = try findsetup(argc, argv, 1);
    const array = c.janet_array(0);
    while (true) {
        const result = state.next();
        if (result < 0) break;
        limit -%= 1;
        if (limit == 0) break;
        const slice = janet_string(state.text + asSize(lastindex), result - lastindex);
        try containers.arrayPush(array, c.janet_wrap_string(slice));
        lastindex = result + state.patlen;
        state.seti(lastindex);
    }
    const slice = janet_string(state.text + asSize(lastindex), state.textlen - lastindex);
    try containers.arrayPush(array, c.janet_wrap_string(slice));
    state.deinit();
    return c.janet_wrap_array(array);
}

/// A 256-bit set held in eight words, indexed by the top three bits of the
/// byte and masked by the low five. The same arithmetic as the C original,
/// which is worth keeping because a `[256]bool` would be clearer and slower.
fn cfunStringCheckset(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    var bitset: [8]u32 = @splat(0);
    try arglayer.fixarity(argc, 2);
    const set = try arglayer.getBytes(argv, 0);
    const str = try arglayer.getBytes(argv, 1);
    var i: i32 = 0;
    while (i < set.len) : (i += 1) {
        const byte = set.bytes[@intCast(i)];
        bitset[byte >> 5] |= @as(u32, 1) << @intCast(byte & 0x1F);
    }
    i = 0;
    while (i < str.len) : (i += 1) {
        const byte = str.bytes[@intCast(i)];
        if (bitset[byte >> 5] & (@as(u32, 1) << @intCast(byte & 0x1F)) == 0) {
            return c.janet_wrap_false();
        }
    }
    return c.janet_wrap_true();
}

fn cfunStringJoin(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 1, 2);
    const parts = try arglayer.getIndexed(argv, 0);
    const joiner: c.JanetByteView = if (argc == 2)
        try arglayer.getBytes(argv, 1)
    else
        .{ .bytes = null, .len = 0 };

    // Two passes, and the first one is what rejects a bad part: nothing is
    // allocated until every item is known to be a byte sequence and the total
    // is known to fit.
    var i: i32 = 0;
    var finallen: i64 = 0;
    while (i < parts.len) : (i += 1) {
        var chunk: [*c]const u8 = null;
        var chunklen: i32 = 0;
        if (c.janet_bytes_view(parts.items[@intCast(i)], &chunk, &chunklen) == 0) {
            return pp_format.panicf("item %d of parts is not a byte sequence, got %v", .{ i, parts.items[@intCast(i)] });
        }
        if (i != 0) finallen += joiner.len;
        finallen += chunklen;
        if (finallen > std.math.maxInt(i32)) return raise.panic("result string too long");
    }

    const buf = janet_string_begin(@intCast(finallen));
    var out: usize = 0;
    i = 0;
    while (i < parts.len) : (i += 1) {
        var chunk: [*c]const u8 = null;
        var chunklen: i32 = 0;
        if (i != 0) {
            safe_memcpy(@ptrCast(buf + out), @ptrCast(joiner.bytes), asSize(joiner.len));
            out += asSize(joiner.len);
        }
        _ = c.janet_bytes_view(parts.items[@intCast(i)], &chunk, &chunklen);
        safe_memcpy(@ptrCast(buf + out), @ptrCast(chunk), asSize(chunklen));
        out += asSize(chunklen);
    }
    return c.janet_wrap_string(janet_string_end(buf));
}

fn cfunStringFormat(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 1, -1);
    const buffer = c.janet_buffer(0);
    const strfrmt = try arglayer.getString(argv, 0);
    try pp_format.bufferFormat(buffer, @ptrCast(strfrmt), 0, argc, argv);
    return c.janet_wrap_string(janet_string(buffer.*.data, buffer.*.count));
}

const default_trim_set = " \t\r\n\x0b\x0c";

fn trimArgs(argc: i32, argv: [*c]c.Janet, str: *c.JanetByteView, set: *c.JanetByteView) raise.Raising(void) {
    try arglayer.arity(argc, 1, 2);
    str.* = try arglayer.getBytes(argv, 0);
    if (argc >= 2) {
        set.* = try arglayer.getBytes(argv, 1);
    } else {
        set.* = .{ .bytes = default_trim_set, .len = default_trim_set.len };
    }
}

fn inSet(set: c.JanetByteView, x: u8) bool {
    var j: i32 = 0;
    while (j < set.len) : (j += 1) if (set.bytes[@intCast(j)] == x) return true;
    return false;
}

fn leftEdge(str: c.JanetByteView, set: c.JanetByteView) i32 {
    var i: i32 = 0;
    while (i < str.len) : (i += 1) if (!inSet(set, str.bytes[@intCast(i)])) return i;
    return str.len;
}

fn rightEdge(str: c.JanetByteView, set: c.JanetByteView) i32 {
    var i: i32 = str.len - 1;
    while (i >= 0) : (i -= 1) if (!inSet(set, str.bytes[@intCast(i)])) return i + 1;
    return 0;
}

fn cfunStringTrim(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    var str: c.JanetByteView = undefined;
    var set: c.JanetByteView = undefined;
    try trimArgs(argc, argv, &str, &set);
    const left = leftEdge(str, set);
    const right = rightEdge(str, set);
    if (right < left) return c.janet_wrap_string(janet_string(null, 0));
    return c.janet_wrap_string(janet_string(str.bytes + asSize(left), right - left));
}

fn cfunStringTriml(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    var str: c.JanetByteView = undefined;
    var set: c.JanetByteView = undefined;
    try trimArgs(argc, argv, &str, &set);
    const left = leftEdge(str, set);
    return c.janet_wrap_string(janet_string(str.bytes + asSize(left), str.len - left));
}

fn cfunStringTrimr(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    var str: c.JanetByteView = undefined;
    var set: c.JanetByteView = undefined;
    try trimArgs(argc, argv, &str, &set);
    return c.janet_wrap_string(janet_string(str.bytes, rightEdge(str, set)));
}

export fn janet_lib_string(env: *c.JanetTable) callconv(.c) void {
    const slice_doc = "Returns a substring from a byte sequence. The substring is from " ++
        "index `start` inclusive to index `end`, exclusive. All indexing " ++
        "is from 0. `start` and `end` can also be negative to indicate indexing " ++
        "from the end of the string. Note that if `start` is negative it is " ++
        "exclusive, and if `end` is negative it is inclusive, to allow a full " ++
        "negative slice range.";
    const trim_doc_tail = "whitespace from a byte sequence. If the argument " ++
        "`set` is provided, consider only characters in `set` to be whitespace.";
    const entries = [_]corefn.Entry{
        corefn.reg("string/slice", &cfunStringSlice, @src(), "(string/slice bytes &opt start end)", slice_doc),
        corefn.reg("keyword/slice", &cfunKeywordSlice, @src(), "(keyword/slice bytes &opt start end)", "Same as string/slice, but returns a keyword."),
        corefn.reg("symbol/slice", &cfunSymbolSlice, @src(), "(symbol/slice bytes &opt start end)", "Same as string/slice, but returns a symbol."),
        corefn.reg("string/repeat", &cfunStringRepeat, @src(), "(string/repeat bytes n)", "Returns a string that is `n` copies of `bytes` concatenated."),
        corefn.reg("string/bytes", &cfunStringBytes, @src(), "(string/bytes str)", "Returns a tuple of integers that are the byte values of the string."),
        corefn.reg("string/from-bytes", &cfunStringFrombytes, @src(), "(string/from-bytes & byte-vals)", "Creates a string from integer parameters with byte values. All integers " ++
            "will be coerced to the range of 1 byte 0-255."),
        corefn.reg("string/ascii-lower", &cfunStringAsciilower, @src(), "(string/ascii-lower str)", "Returns a new string where all bytes are replaced with the " ++
            "lowercase version of themselves in ASCII. Does only a very simple " ++
            "case check, meaning no unicode support."),
        corefn.reg("string/ascii-upper", &cfunStringAsciiupper, @src(), "(string/ascii-upper str)", "Returns a new string where all bytes are replaced with the " ++
            "uppercase version of themselves in ASCII. Does only a very simple " ++
            "case check, meaning no unicode support."),
        corefn.reg("string/reverse", &cfunStringReverse, @src(), "(string/reverse str)", "Returns a string that is the reversed version of `str`."),
        corefn.reg("string/find", &cfunStringFind, @src(), "(string/find patt str &opt start-index)", "Searches for the first instance of pattern `patt` in string " ++
            "`str`. Returns the index of the first character in `patt` if found, " ++
            "otherwise returns nil."),
        corefn.reg("string/find-all", &cfunStringFindall, @src(), "(string/find-all patt str &opt start-index)", "Searches for all instances of pattern `patt` in string " ++
            "`str`. Returns an array of all indices of found patterns. Overlapping " ++
            "instances of the pattern are counted individually, meaning a byte in `str` " ++
            "may contribute to multiple found patterns."),
        corefn.reg("string/has-prefix?", &cfunStringHasprefix, @src(), "(string/has-prefix? pfx str)", "Tests whether `str` starts with `pfx`."),
        corefn.reg("string/has-suffix?", &cfunStringHassuffix, @src(), "(string/has-suffix? sfx str)", "Tests whether `str` ends with `sfx`."),
        corefn.reg("string/replace", &cfunStringReplace, @src(), "(string/replace patt subst str)", "Replace the first occurrence of `patt` with `subst` in the string `str`. " ++
            "If `subst` is a function, it will be called with `patt` only if a match is found, " ++
            "and should return the actual replacement text to use. " ++
            "Will return the new string if `patt` is found, otherwise returns `str`."),
        corefn.reg("string/replace-all", &cfunStringReplaceall, @src(), "(string/replace-all patt subst str)", "Replace all instances of `patt` with `subst` in the string `str`. Overlapping " ++
            "matches will not be counted, only the first match in such a span will be replaced. " ++
            "If `subst` is a function, it will be called with `patt` once for each match, " ++
            "and should return the actual replacement text to use. " ++
            "Will return the new string if `patt` is found, otherwise returns `str`."),
        corefn.reg("string/split", &cfunStringSplit, @src(), "(string/split delim str &opt start limit)", "Splits a string `str` with delimiter `delim` and returns an array of " ++
            "substrings. The substrings will not contain the delimiter `delim`. If `delim` " ++
            "is not found, the returned array will have one element. Will start searching " ++
            "for `delim` at the index `start` (if provided), and return up to a maximum " ++
            "of `limit` results (if provided)."),
        corefn.reg("string/check-set", &cfunStringCheckset, @src(), "(string/check-set set str)", "Checks that the string `str` only contains bytes that appear in the string `set`. " ++
            "Returns true if all bytes in `str` appear in `set`, false if some bytes in `str` do " ++
            "not appear in `set`."),
        corefn.reg("string/join", &cfunStringJoin, @src(), "(string/join parts &opt sep)", "Joins an array of strings into one string, optionally separated by " ++
            "a separator string `sep`."),
        corefn.reg("string/format", &cfunStringFormat, @src(), "(string/format format & values)", "Similar to C's `snprintf`, but specialized for operating with Janet values. Returns " ++
            "a new string.\n\n" ++
            "The following conversion specifiers are supported, where the upper case specifiers generate " ++
            "upper case output:\n" ++
            "- `c`: ASCII character.\n" ++
            "- `d`, `i`: integer, formatted as a decimal number.\n" ++
            "- `x`, `X`: integer, formatted as a hexadecimal number.\n" ++
            "- `o`: integer, formatted as an octal number.\n" ++
            "- `f`, `F`: floating point number, formatted as a decimal number.\n" ++
            "- `e`, `E`: floating point number, formatted in scientific notation.\n" ++
            "- `g`, `G`: floating point number, formatted in its shortest form.\n" ++
            "- `a`, `A`: floating point number, formatted as a hexadecimal number.\n" ++
            "- `s`: formatted as a string, precision indicates padding and maximum length.\n" ++
            "- `t`: emit the type of the given value.\n" ++
            "- `v`: format with (describe x)\n" ++
            "- `V`: format with (string x)\n" ++
            "- `j`: format to jdn (Janet data notation).\n" ++
            "\n" ++
            "The following conversion specifiers are used for \"pretty-printing\", where the upper-case " ++
            "variants generate colored output. These specifiers can take a precision " ++
            "argument to specify the maximum nesting depth to print. " ++
            "The multiline specifiers can also take a width argument, " ++
            "which defaults to 80 columns.\n" ++
            "- `p`, `P`: pretty format, truncating if necessary\n" ++
            "- `m`, `M`: pretty format without truncating.\n" ++
            "- `q`, `Q`: pretty format on one line, truncating if necessary.\n" ++
            "- `n`, `N`: pretty format on one line without truncation.\n"),
        corefn.reg("string/trim", &cfunStringTrim, @src(), "(string/trim str &opt set)", "Trim leading and trailing " ++ trim_doc_tail),
        corefn.reg("string/triml", &cfunStringTriml, @src(), "(string/triml str &opt set)", "Trim leading " ++ trim_doc_tail),
        corefn.reg("string/trimr", &cfunStringTrimr, @src(), "(string/trimr str &opt set)", "Trim trailing " ++ trim_doc_tail),
        corefn.end,
    };
    corefn.install(env, &entries);
}
