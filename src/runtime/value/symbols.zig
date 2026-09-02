//! `strings.Symbol`: a string with an entry in `vm.symcache.entries`, the cache
//! itself, and the gensym counter. A keyword is the same interned bytes under a
//! different tag and the tag lives in `helpers/wrap.zig`.
//!
//! **Interning is the whole difference from a string.** `new` is `strings.new`
//! plus a lookup in `vm.symcache.entries`, and the cache is the only structure
//! in this group that is not itself a Janet value. The head accessors are
//! `strings.head` and `strings.data`, the tree's one spelling of them.
//!
//! `strings.zig`, `symbols.zig` and `tuples.zig` are one allocation strategy: a
//! header and its payload in a single collectable block, sized once and never
//! resized, which is what makes them immutable in the runtime's sense. Two
//! consequences hold for all three. The value is the address of the *payload*,
//! so reaching the header subtracts an offset -- `DESIGN.md` section 3 on why
//! an offset and not a `@sizeOf`. And `end` fills in the hash `begin` leaves
//! indeterminate, so nothing may put a value in a dictionary between the two.
//!
//! **The symbol cache is the collector's one external obligation.** Everything
//! else it frees is self-contained; a symbol is registered in the cache at
//! construction, so `gc/sweep.zig`'s `deinitBlock` calls `deinit` here.
//! Freeing one without removing it leaves the cache pointing at released
//! memory, which the next symbol in that bucket compares against.
//!
//! **A raise passes through these frames without stranding a block.** Nothing
//! here raises, but an allocation can collect and a finalizer may raise. The one
//! place a raw block is held across a call is `new`, which allocates the symbol
//! and only then calls `cachePut`; the block is on a heap list by then, so a
//! raise loses the cache entry and leaves a live uninterned symbol -- correct as
//! a value, and a duplicate the next `new` will miss.

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
/// constant elsewhere in the image: a merged tombstone would alias an object
/// that is not one, and the comparison is by address.
var symcache_deleted: [1]u8 = .{0};

inline fn deleted() [*:0]const u8 {
    return @ptrCast(&symcache_deleted);
}

/// The cache's starting size. A power of two, because the probe masks with
/// `capacity - 1`.
const initial_capacity: u32 = 1024;

/// Allocate the cache. Reached through `cacheInit`, which VM start-up calls
/// before anything can intern.
fn cacheAlloc(sc: *SymbolCache) void {
    sc.* = .{
        .capacity = initial_capacity,
        .entries = @ptrCast(@alignCast(utils.calloc(1, initial_capacity *% @sizeOf(?*const u8)) orelse
            fatal.outOfMemory())),
    };
}

/// Release the cache. The symbols it points at are not freed here: they are
/// ordinary collectable blocks and `gc/sweep.zig`'s `clearMemory` takes them.
fn cacheFree(sc: *SymbolCache) void {
    utils.free(@ptrCast(@constCast(sc.entries)));
    sc.* = .{};
}

/// Where a name sits in the cache, or where it would go. The two cases are
/// separate arms because the slot means two different things -- the entry
/// holding the symbol, or the empty one it would be installed in -- and naming
/// both makes reading the slot as an interned symbol impossible without
/// deciding which it is.
const Lookup = union(enum) {
    /// The entry holding the interned name.
    found: *?[*:0]const u8,
    /// The empty or tombstoned entry the name would go in. Never absent: the
    /// load factor `cachePut` maintains is what makes a full table impossible,
    /// and this fatals rather than answering one.
    vacant: *?[*:0]const u8,
};

/// Find `str` in the cache, or the entry it belongs in.
///
/// The scan covers the whole table in two ranges -- the ideal index to the end,
/// then the start to the ideal index -- and stops at the first genuinely empty
/// slot, because open addressing guarantees nothing lies beyond one. Tombstones
/// do not stop it, but the first one is remembered, and a key found *after* a
/// tombstone is moved back into it. That last move is why this is not a pure
/// lookup: it rewrites the table on a successful find, which keeps probe
/// sequences short without a separate compaction pass.
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

    // The load factor `cachePut` maintains, floor and all, is what makes a
    // full table impossible.
    return .{ .vacant = first_empty orelse fatal.fatal("symcache failed to get memory") };
}

/// `cacheFindmem` over a NUL-terminated name, which is the form every caller
/// in this file has.
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
            // `.found` is unreachable: the fresh table is built from one that
            // holds no duplicates. The `break` is kept because it is what the
            // branch does if the invariant ever fails, and it is worse than
            // the condition it guards -- it abandons every remaining entry
            // while still freeing the old table. Its other half, a null slot,
            // is a state `Lookup` no longer has.
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
        // **Floored at four buckets.** The target is derived from `count`,
        // which is zero once every symbol has died, and `capacityFor` gives
        // one or two for a small count. At those two capacities this load
        // factor -- tested before the increment, so at most `capacity / 2 + 1`
        // entries afterwards -- fills the table, and a full table is what
        // `cacheFindmem` has no answer for.
        const target: u32 = @intCast(value.capacityFor(2 *% sc.count +% 1));
        cacheResize(sc, @max(target, 4));
        slot = switch (cacheFind(sc, x)) {
            .found, .vacant => |found| found,
        };
    }
    sc.count +%= 1;
    slot.* = x;
}

/// Drop a symbol from the cache. Reached through `deinit`, which
/// `gc/sweep.zig`'s `deinitBlock` calls on the way to freeing the block, and it
/// is the collector's one obligation to a structure outside itself.
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

/// The odometer's starting state, which is where `cacheInit` leaves it. The
/// counter lives on the VM rather than in the cache, so it is passed
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

// Everything above takes the cache -- and, where it needs it, the counter --
// so this is the only place in the file that asks which VM is current. The five
// entry points keep the names and signatures the rest of the tree calls them
// by; each fetches once and delegates.

/// Allocate the cache and reset the gensym odometer. VM start-up calls this
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

/// Drop a symbol from the cache. `gc/sweep.zig`'s `deinitBlock` calls this.
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
