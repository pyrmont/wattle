//! `JanetSymbol`: a string with an entry in `janet_vm.cache`, the cache
//! itself, and the gensym counter. Keywords are here too, in the sense that
//! there is nothing of them to be here: `janet.h` spells `janet_keyword` as a
//! `#define` onto `janet_symbol`, so a keyword and a symbol are the same
//! interned bytes under a different tag, and the tag lives in `value_wrap.zig`.
//!
//! ## One allocation strategy, three files
//!
//! `strings.zig`, `symbols.zig` and `tuples.zig` were `string_symbol.zig`
//! until Phase 12's namespace batch 2. They are still one allocation strategy,
//! and that is worth stating rather than assuming: a buffer or an array is a
//! fixed-size block pointing at a payload that can be reallocated; a string, a
//! symbol or a tuple is a header and its payload in a *single* `janet_gcalloc`,
//! sized once and never resized. That is what makes them immutable in the
//! runtime's sense, and it is why the three share:
//!
//!  - **A head recovered by pointer arithmetic.** The value Janet passes
//!    around is the address of the payload, not of the block, so every
//!    operation subtracts the header size to get back to the header.
//!    `gc_sweep.zig` already does this for the free path; `head` below is the
//!    same shape, `@sizeOf` rather than `@offsetOf` because translate-c drops
//!    the flexible array member. `test/abi.c` pins the equality with a
//!    `_Static_assert` — the last place in the tree that can spell `offsetof` —
//!    and `test/gc_mark.zig` checks the offset the allocator actually used.
//!  - **A hash computed once, at the end of construction.** `begin` leaves
//!    `hash` uninitialised and `end` fills it in. A value observed between the
//!    two has an indeterminate hash, which is why nothing may put it in a
//!    dictionary before `end` runs. Preserved exactly; the port does not
//!    helpfully zero it.
//!
//! The taxonomy that separates them is Janet's own, and it is what the batch
//! followed: a string and a symbol are **bytes**, a tuple is **indexed**.
//! `port/NAMESPACES.md` has it, along with the reason there is no
//! `keywords.zig` — `janet.h` spells `janet_keyword` as a `#define` onto
//! `janet_symbol`, so a keyword and a symbol are the same interned bytes under
//! a different tag, and `helpers/wrap.zig` is where the tag lives.
//!
//! **Interning is the whole difference from a string.** `new` is
//! `strings.new` plus a lookup in `janet_vm.cache`, and the cache is the only
//! structure in this group that is not itself a Janet value. The string head
//! accessors are `types.stringHead` and `types.stringData`, which since
//! increment 5e is the tree's one spelling of them.
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
//! `cacheResize` re-inserts the old entries and `break`s out of the loop if a
//! re-insertion reports the key was already present or returns no bucket.
//! Neither can happen -- the cache holds no duplicates and `cacheFindmem`
//! exits the process rather than returning null -- but the `break` abandons
//! every remaining entry while still freeing the old table, so the defensive
//! path is worse than the condition it defends against. Preserved as written.
//!
//! `cacheFindmem` ends the process through `janet_assert` when the table is
//! full, and the load factor that is supposed to make that impossible has a
//! gap at a capacity of two. It is reachable: a rehash chooses two buckets
//! when `cache_count` is zero, and `janet_init` leaves it at zero because the
//! core environment is built lazily. Five hundred and thirteen transient
//! symbols, one collection and three more symbols abort the process.
//! `FOUND.md` has it, with the reproducer. The port reproduces both the policy
//! and the exit.
//!
//! ## Jump transparency
//!
//! Nothing in this file calls `janet_panic`, but `janet_gcalloc` can trigger a
//! collection and a finalizer may raise, so a signal can still unwind through
//! these frames. There is no `defer` here and `build.zig` checks that there is
//! not.
//!
//! One place is worth naming for that reason, because it is the only one in
//! the group where a raw block is held across a call. `new` allocates the
//! symbol, fills in its head, and only then calls `cachePut`, which may
//! allocate a new table -- but the symbol is already on a heap list by then,
//! so a signal from anywhere in `cachePut` loses the *cache entry* rather than
//! the block. The result is a live, uninterned symbol: correct as a value, and
//! a duplicate the next `new` of the same name will not find. That is what the
//! C does, and the port does not improve on it.

const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");
const gc_alloc = @import("../gc.zig");
const utils = @import("../utils.zig");
const fatal = @import("../fatal.zig");
const strings = @import("strings.zig");
const value = @import("../value.zig");

/// From `src/core/util.c`, declared here rather than imported: `util.h` is
/// never in a translation.
/// `strings.zig` and `tuples.zig` carry the declarations they need for the
/// same reason; `utils.zig` defines all of them without `pub`.
extern fn safe_memcpy(dest: ?*anyopaque, src: ?*const anyopaque, len: usize) callconv(.c) void;

/// `janet_vm`, whose layout is `types.JanetVM`'s and whose address
/// `cabi.vm()` takes.
inline fn vm() *types.JanetVM {
    return c.vm();
}

/// C's conversion of a signed count to `size_t`: sign-extend to the pointer
/// width, then reinterpret. Same helper, and same reason, as `strings.zig`.
inline fn asSize(n: i32) usize {
    return @bitCast(@as(isize, n));
}

// ------------------------------------------------------------ symbol cache

/// The tombstone, compared by address and never dereferenced. Declared `var`
/// so that the linker cannot merge this single zero byte with an identical
/// constant elsewhere in the image; the C original is a `static const` in a
/// translation unit of its own, which has the same effect for a different
/// reason.
var symcache_deleted: [1]u8 = .{0};

inline fn deleted() [*:0]const u8 {
    return @ptrCast(&symcache_deleted);
}

/// Allocate the cache. Called from `janet_init` before anything can intern.
pub fn cacheInit() void {
    const v = vm();
    v.cache_capacity = 1024;
    v.cache = @ptrCast(@alignCast(utils.calloc(1, @as(usize, v.cache_capacity) *% @sizeOf(?*const u8)) orelse
        fatal.outOfMemory()));
    @memset(&v.gensym_counter, '0');
    v.gensym_counter[0] = '_';
    v.cache_count = 0;
    v.cache_deleted = 0;
}

/// Release the cache. The symbols it points at are not freed here: they are
/// ordinary collectable blocks and `janet_clear_memory` deals with them.
pub fn cacheDeinit() void {
    const v = vm();
    utils.free(@ptrCast(@constCast(v.cache)));
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
fn cacheFindmem(str: []const u8, hash: i32, success: *c_int) ?*?[*:0]const u8 {
    const v = vm();
    var first_empty: ?*?[*:0]const u8 = null;

    const index: u32 = @as(u32, @bitCast(hash)) & (v.cache_capacity -% 1);
    const bounds = [4]u32{ index, v.cache_capacity, 0, index };

    scan: {
        var j: usize = 0;
        while (j < 4) : (j += 2) {
            var i: u32 = bounds[j];
            while (i < bounds[j + 1]) : (i += 1) {
                const entry = v.cache.?[i];
                if (entry == null) {
                    if (first_empty == null) first_empty = &v.cache.?[i];
                    break :scan;
                }
                if (deleted() == entry) {
                    if (first_empty == null) first_empty = &v.cache.?[i];
                    continue;
                }
                if (strings.equalconst(entry.?, str, hash) != 0) {
                    success.* = 1;
                    if (first_empty) |slot| {
                        slot.* = entry;
                        v.cache.?[i] = deleted();
                        return slot;
                    }
                    return &v.cache.?[i];
                }
            }
        }
    }

    success.* = 0;
    // The load factor `janet_symcache_put` maintains is what makes a full table
    // impossible, and `FOUND.md` records the one capacity where it does not.
    if (first_empty == null) fatal.fatal("symcache failed to get memory");
    return first_empty;
}

/// `janet_symcache_find` in `symcache.c`, which is a macro there.
inline fn cacheFind(str: [*:0]const u8, success: *c_int) ?*?[*:0]const u8 {
    return cacheFindmem(strings.bytesOf(str), strings.hashOf(str), success);
}

/// Rebuild the table at a new capacity, dropping every tombstone.
fn cacheResize(new_capacity: u32) void {
    const v = vm();
    const old_cache = v.cache;
    const new_cache: [*]?[*:0]const u8 = @ptrCast(@alignCast(utils.calloc(1, @as(usize, new_capacity) *% @sizeOf(?*const u8)) orelse
        fatal.outOfMemory()));
    const old_capacity = v.cache_capacity;
    v.cache = new_cache;
    v.cache_capacity = new_capacity;
    v.cache_deleted = 0;
    var i: u32 = 0;
    while (i < old_capacity) : (i += 1) {
        const x = old_cache.?[i];
        if (x != null and deleted() != x) {
            var status: c_int = 0;
            const bucket = cacheFind(x.?, &status);
            // Neither condition is reachable, and the recovery abandons every
            // remaining entry while still freeing the old table. Preserved.
            if (status != 0 or bucket == null) break;
            bucket.?.* = x;
        }
    }
    utils.free(@ptrCast(@constCast(old_cache)));
}

/// Install `x` in `bucket`, growing the table first if it is half full.
/// Counting tombstones toward the load factor is what stops a long run of
/// create-and-collect from degrading every probe to a full scan.
fn cachePut(x: [*:0]const u8, bucket_in: ?*?[*:0]const u8) void {
    const v = vm();
    var bucket = bucket_in;
    if ((v.cache_count +% v.cache_deleted) *% 2 > v.cache_capacity) {
        var status: c_int = 0;
        cacheResize(@bitCast(value.capacityFor(@bitCast(2 *% v.cache_count +% 1))));
        bucket = cacheFind(x, &status);
    }
    v.cache_count +%= 1;
    bucket.?.* = x;
}

/// Drop a symbol from the cache. Called by `janet_deinit_block` on the way to
/// freeing the block, and it is the collector's one obligation to a structure
/// outside itself.
pub fn deinit(sym: [*:0]const u8) void {
    const v = vm();
    var status: c_int = 0;
    const bucket = cacheFind(sym, &status);
    if (status != 0) {
        v.cache_count -%= 1;
        v.cache_deleted +%= 1;
        bucket.?.* = deleted();
    }
}

/// Intern a symbol: return the existing one if the name is already cached, and
/// otherwise build it and register it.
pub fn new(str: []const u8) [*:0]const u8 {
    const hash = value.hashBytes(str);
    var success: c_int = 0;
    const bucket = cacheFindmem(str, hash, &success);
    if (success != 0) return bucket.?.*.?;

    const hd: *types.JanetStringHead = @ptrCast(@alignCast(gc_alloc.gcalloc(
        constants.JANET_MEMORY_SYMBOL,
        types.string_payload +% str.len +% 1,
    )));
    hd.hash = hash;
    hd.length = @intCast(str.len);
    const newstr = types.stringData(hd);
    safe_memcpy(@ptrCast(newstr), @ptrCast(str.ptr), str.len);
    newstr[str.len] = 0;
    const interned: [*:0]const u8 = @ptrCast(newstr);
    cachePut(interned, bucket);
    return interned;
}

pub fn csymbol(cstr: [*:0]const u8) [*:0]const u8 {
    return new(cstr[0..c.strlen(cstr)]);
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
pub fn gen() [*:0]const u8 {
    const v = vm();
    const name_len: i32 = @intCast(v.gensym_counter.len - 1);
    var bucket: ?*?[*:0]const u8 = null;
    var hash: i32 = 0;
    var status: c_int = 0;
    while (true) {
        hash = value.hashBytes(v.gensym_counter[0..@intCast(name_len)]);
        bucket = cacheFindmem(v.gensym_counter[0..@intCast(name_len)], hash, &status);
        if (status == 0) break;
        incGensym();
    }
    const hd: *types.JanetStringHead = @ptrCast(@alignCast(gc_alloc.gcalloc(
        constants.JANET_MEMORY_SYMBOL,
        types.string_payload +% v.gensym_counter.len,
    )));
    hd.length = name_len;
    hd.hash = hash;
    const sym = types.stringData(hd);
    // The whole counter is copied and the terminator then overwrites its last
    // byte, so the name is the first `len` characters of the odometer.
    @memcpy(sym[0..v.gensym_counter.len], &v.gensym_counter);
    sym[@intCast(hd.length)] = 0;
    const interned: [*:0]const u8 = @ptrCast(sym);
    cachePut(interned, bucket);
    return interned;
}
