//! `strings.Symbol`: a string with an entry in `vm.symcache.entries`, the cache
//! itself, and the gensym counter. Keywords are here too, in the sense that
//! there is nothing of them to be here: Janet spells `janet_keyword` as a
//! `#define` onto `janet_symbol`, so a keyword and a symbol are the same
//! interned bytes under a different tag, and the tag lives in
//! `helpers/wrap.zig`.
//!
//! ## One allocation strategy, three files
//!
//! `strings.zig`, `symbols.zig` and `tuples.zig` were one file once. They are
//! still one allocation strategy,
//! and that is worth stating rather than assuming: a buffer or an array is a
//! fixed-size block pointing at a payload that can be reallocated; a string, a
//! symbol or a tuple is a header and its payload in a *single* `janet_gcalloc`,
//! sized once and never resized. That is what makes them immutable in the
//! runtime's sense, and it is why the three share:
//!
//!  - **A head recovered by pointer arithmetic.** The value Janet passes
//!    around is the address of the payload, not of the block, so every
//!    operation subtracts the header size to get back to the header.
//!    `gc/sweep.zig` already does this for the free path; `head` below is the
//!    same shape, `@sizeOf` rather than `@offsetOf` because a flexible array
//!    member does not survive translation. `test/gc_mark.zig` checks the
//!    offset the allocator actually used.
//!  - **A hash computed once, at the end of construction.** `begin` leaves
//!    `hash` uninitialised and `end` fills it in. A value observed between the
//!    two has an indeterminate hash, which is why nothing may put it in a
//!    dictionary before `end` runs. Preserved exactly; nothing here
//!    helpfully zeroes it.
//!
//! The taxonomy that separates them is Janet's own: a string and a symbol are
//! **bytes**, a tuple is **indexed**.
//!
//! **Interning is the whole difference from a string.** `new` is
//! `strings.new` plus a lookup in `vm.symcache.entries`, and the cache is the only
//! structure in this group that is not itself a Janet value. The string head
//! accessors are `strings.head` and `strings.data`, which is the
//! tree's one spelling of them.
//!
//! ## The symbol cache is the collector's one external obligation
//!
//! Everything else the collector frees is self-contained. A symbol is not: it
//! is registered in `vm.symcache.entries` at construction, and if it were freed
//! without being removed the cache would hold a pointer to released memory and
//! the next symbol that hashed to that bucket would compare against it. So
//! `deinitBlock` in `gc/sweep.zig` calls `symbolDeinit` from this file.
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
//! re-insertion reports the key was already present. That cannot happen -- the
//! cache holds no duplicates -- but the `break` abandons every remaining entry
//! while still freeing the old table, so the defensive path is worse than the
//! condition it defends against. Preserved as written. Its other half, a null
//! bucket, is gone: `cacheFindmem` exits the process rather than answering
//! one, and `Lookup` now says so in the type.
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
//! **Nothing here holds anything across a raise**, with one exception.
//! Nothing here raises directly, but `janet_gcalloc` can trigger a collection
//! and a finalizer may raise, so a raise can still pass through these frames.
//!
//! The exception is worth naming, because it is the only place in the group a
//! raw block is held across a call. `new` allocates the symbol, fills in its
//! head, and only then calls `cachePut`, which may allocate a new table -- but
//! the symbol is already on a heap list by then, so a raise from anywhere in
//! `cachePut` loses the *cache entry* rather than the block. The result is a
//! live, uninterned symbol: correct as a value, and a duplicate the next `new`
//! of the same name will not find. That is what Janet does.

const c = @import("cabi");
const vm_state = @import("../vm/state.zig");
const gc_alloc = @import("../gc.zig");
const utils = @import("../utils.zig");
const fatal = @import("../fatal.zig");
const strings = @import("strings.zig");
const value = @import("../value.zig");

/// The symbol cache: open addressing over interned symbol names, with a
/// tombstone for a deleted entry. This file owns the lifecycle.
pub const SymbolCache = struct {
    entries: ?[*]?[*:0]const u8 = null,
    capacity: u32 = 0,
    count: u32 = 0,
    deleted: u32 = 0,
};

/// The gensym odometer: a leading underscore, six base-62 digits, and the byte
/// the terminator overwrites. It lives on the VM rather than in the cache --
/// `gen` needs both -- and this names the shape the two share.
pub const GensymCounter = [8]u8;

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

/// The cache's starting size. A power of two, because the probe masks with
/// `capacity - 1`.
const initial_capacity: u32 = 1024;

/// Allocate the cache. Reached through `cacheInit`, which `janet_init` calls
/// before anything can intern.
fn cacheAlloc(sc: *SymbolCache) void {
    sc.* = .{
        .capacity = initial_capacity,
        .entries = @ptrCast(@alignCast(utils.calloc(1, initial_capacity *% @sizeOf(?*const u8)) orelse
            fatal.outOfMemory())),
    };
}

/// Release the cache. The symbols it points at are not freed here: they are
/// ordinary collectable blocks and `janet_clear_memory` deals with them.
fn cacheFree(sc: *SymbolCache) void {
    utils.free(@ptrCast(@constCast(sc.entries)));
    sc.* = .{};
}

/// Find `str` in the cache, or the entry it belongs in.
///
/// The scan covers the whole table in two ranges -- the ideal index to the end,
/// then the start to the ideal index -- and stops at the first genuinely empty
/// slot, because open addressing guarantees nothing lies beyond one. Tombstones
/// do not stop it, but the first one is remembered, and a key found *after* a
/// tombstone is moved back into it. That last move is why this function is not
/// a pure lookup: it rewrites the table on a successful find, which keeps
/// probe sequences short without a separate compaction pass.
/// Where a name sits in the cache, or where it would go.
///
/// It was a slot pointer beside a `*c_int` success flag, and the slot means
/// two different things depending on the flag: the entry holding the symbol,
/// or the empty one it would be installed in. Naming both makes reading the
/// slot as an interned symbol impossible without deciding which it is.
const Lookup = union(enum) {
    /// The entry holding the interned name.
    found: *?[*:0]const u8,
    /// The empty or tombstoned entry the name would go in. Never absent: the
    /// load factor `cachePut` maintains is what makes a full table impossible,
    /// and this fatals rather than answering one.
    vacant: *?[*:0]const u8,
};

fn cacheFindmem(sc: *SymbolCache, str: []const u8, hash: i32) Lookup {
    var first_empty: ?*?[*:0]const u8 = null;

    const index: u32 = @as(u32, @bitCast(hash)) & (sc.capacity -% 1);
    const bounds = [4]u32{ index, sc.capacity, 0, index };

    scan: {
        var j: usize = 0;
        while (j < 4) : (j += 2) {
            for (bounds[j]..bounds[j + 1]) |i| {
                const entry = sc.entries.?[i] orelse {
                    if (first_empty == null) first_empty = &sc.entries.?[i];
                    break :scan;
                };
                if (deleted() == entry) {
                    if (first_empty == null) first_empty = &sc.entries.?[i];
                    continue;
                }
                if (strings.equalconst(entry, str, hash)) {
                    if (first_empty) |slot| {
                        slot.* = entry;
                        sc.entries.?[i] = deleted();
                        return .{ .found = slot };
                    }
                    return .{ .found = &sc.entries.?[i] };
                }
            }
        }
    }

    // The load factor `cachePut` maintains is what makes a full table
    // impossible, and `FOUND.md` records the one capacity where it does not.
    return .{ .vacant = first_empty orelse fatal.fatal("symcache failed to get memory") };
}

/// `janet_symcache_find` in `symcache.c`, which is a macro there.
inline fn cacheFind(sc: *SymbolCache, str: [*:0]const u8) Lookup {
    return cacheFindmem(sc, strings.bytesOf(str), strings.hashOf(str));
}

/// Rebuild the table at a new capacity, dropping every tombstone.
fn cacheResize(sc: *SymbolCache, new_capacity: u32) void {
    const old_cache = sc.entries;
    const new_cache: [*]?[*:0]const u8 = @ptrCast(@alignCast(utils.calloc(1, @as(usize, new_capacity) *% @sizeOf(?*const u8)) orelse
        fatal.outOfMemory()));
    const old_capacity = sc.capacity;
    sc.entries = new_cache;
    sc.capacity = new_capacity;
    sc.deleted = 0;
    for (0..old_capacity) |i| {
        const x = old_cache.?[i] orelse continue;
        if (deleted() != x) {
            // A name already in the fresh table is not reachable -- it was
            // built from a table that holds no duplicates -- and the recovery
            // abandons every remaining entry while still freeing the old one.
            // Preserved. Its other half, a null slot, is now a state the type
            // forbids.
            switch (cacheFind(sc, x)) {
                .found => break,
                .vacant => |slot| slot.* = x,
            }
        }
    }
    utils.free(@ptrCast(@constCast(old_cache)));
}

/// Install `x` in `vacant`, growing the table first if it is half full.
/// Counting tombstones toward the load factor is what stops a long run of
/// create-and-collect from degrading every probe to a full scan.
fn cachePut(sc: *SymbolCache, x: [*:0]const u8, vacant: *?[*:0]const u8) void {
    var slot = vacant;
    if ((sc.count +% sc.deleted) *% 2 > sc.capacity) {
        cacheResize(sc, @intCast(value.capacityFor(2 *% sc.count +% 1)));
        slot = switch (cacheFind(sc, x)) {
            .found, .vacant => |found| found,
        };
    }
    sc.count +%= 1;
    slot.* = x;
}

/// Drop a symbol from the cache. Reached through `deinit`, which
/// `janet_deinit_block` calls on the way to freeing the block, and it is the
/// collector's one obligation to a structure outside itself.
fn cacheRemove(sc: *SymbolCache, sym: [*:0]const u8) void {
    switch (cacheFind(sc, sym)) {
        .found => |slot| {
            sc.count -%= 1;
            sc.deleted +%= 1;
            slot.* = deleted();
        },
        .vacant => {},
    }
}

/// Intern a symbol: return the existing one if the name is already cached, and
/// otherwise build it and register it.
fn intern(sc: *SymbolCache, str: []const u8) [*:0]const u8 {
    const hash = value.hashBytes(str);
    const vacant = switch (cacheFindmem(sc, str, hash)) {
        .found => |slot| return slot.*.?,
        .vacant => |slot| slot,
    };

    const hd = gc_alloc.gcallocWithPayload(strings.StringHead, .symbol, str.len +% 1);
    hd.hash = hash;
    hd.length = @intCast(str.len);
    const newstr = strings.data(hd);
    @memcpy(newstr[0..str.len], str);
    newstr[str.len] = 0;
    const interned: [*:0]const u8 = @ptrCast(newstr);
    cachePut(sc, interned, vacant);
    return interned;
}

pub fn csymbol(cstr: [*:0]const u8) [*:0]const u8 {
    return new(cstr[0..c.strlen(cstr)]);
}

/// The odometer's starting state, which is where `janet_symcache_init` leaves
/// it. The counter lives on the VM rather than in the cache, so it is passed
/// in like anything else this file works on.
fn gensymInit(counter: *GensymCounter) void {
    @memset(counter, '0');
    counter[0] = '_';
}

/// Increment the gensym counter, a base-62 odometer over positions 1 through 6.
/// Position 0 holds the leading underscore and is never touched, so the counter
/// wraps silently after 62^6 names rather than growing.
fn incGensym(counter: *GensymCounter) void {
    var i: usize = counter.len - 2;
    while (i != 0) : (i -= 1) {
        if (counter[i] == '9') {
            counter[i] = 'a';
            break;
        } else if (counter[i] == 'z') {
            counter[i] = 'A';
            break;
        } else if (counter[i] == 'Z') {
            counter[i] = '0';
        } else {
            counter[i] += 1;
            break;
        }
    }
}

/// A symbol guaranteed not to collide with any live one. The counter is
/// advanced until a name is found that the cache does not already hold, which
/// matters because a gensym from an earlier cycle may still be alive.
fn gensym(sc: *SymbolCache, counter: *GensymCounter) [*:0]const u8 {
    const name_len: i32 = @intCast(counter.len - 1);
    var vacant: *?[*:0]const u8 = undefined;
    var hash: i32 = 0;
    while (true) {
        hash = value.hashBytes(counter[0..@intCast(name_len)]);
        switch (cacheFindmem(sc, counter[0..@intCast(name_len)], hash)) {
            .vacant => |slot| {
                vacant = slot;
                break;
            },
            .found => incGensym(counter),
        }
    }
    const hd = gc_alloc.gcallocWithPayload(strings.StringHead, .symbol, counter.len);
    hd.length = name_len;
    hd.hash = hash;
    const sym = strings.data(hd);
    // The whole counter is copied and the terminator then overwrites its last
    // byte, so the name is the first `len` characters of the odometer.
    @memcpy(sym[0..counter.len], counter);
    sym[hd.length] = 0;
    const interned: [*:0]const u8 = @ptrCast(sym);
    cachePut(sc, interned, vacant);
    return interned;
}

// ----------------------------------------------------- the current VM's cache

// Six functions above used to fetch `vm_state.current()` inside themselves to
// find the cache they were already operating on. Everything above now takes
// the cache -- and, where it needs it, the counter -- so this is the only
// place in the file that asks which VM is current. The five entry points keep
// the names and signatures the rest of the tree, the C API and `gc/sweep.zig`
// call them by; each fetches once and delegates.

/// Allocate the cache and reset the gensym odometer. `janet_init` calls this
/// before anything can intern.
pub fn cacheInit() void {
    const v = vm_state.current();
    cacheAlloc(&v.symcache);
    gensymInit(&v.gensym_counter);
}

/// Release the cache.
pub fn cacheDeinit() void {
    cacheFree(&vm_state.current().symcache);
}

/// Drop a symbol from the cache. `janet_deinit_block` calls this.
pub fn deinit(sym: [*:0]const u8) void {
    cacheRemove(&vm_state.current().symcache, sym);
}

/// Intern a symbol in the current VM's cache.
pub fn new(str: []const u8) [*:0]const u8 {
    return intern(&vm_state.current().symcache, str);
}

/// A fresh gensym from the current VM's cache and counter.
pub fn gen() [*:0]const u8 {
    const v = vm_state.current();
    return gensym(&v.symcache, &v.gensym_counter);
}
