//! Interning a symbol, the cache the interned names sit in, and the gensym
//! counter.
//!
//! A `strings.Symbol` is a `strings.String` that also has an entry in
//! `vm.symcache`, so two symbols of one kind with equal bytes are the same
//! pointer and a pointer comparison decides equality.
//!
//! `new`, `csymbol`, `keyword`, `ckeyword`, `gen`, `isKeyword`, `cacheInit`,
//! `cacheDeinit` and `deinit` are the
//! surface. Each fetches the current VM and delegates to a private function
//! that takes the cache, and the counter where it needs the counter, so
//! nothing below the surface asks which VM is current. Nothing here raises.
//!
//! ## What interning costs the collector
//!
//! A symbol is registered in the cache as it is built, so freeing the block
//! without removing the entry would leave the cache pointing at released
//! memory, which the next symbol in that bucket is compared against.
//! `gc/sweep.zig`'s `deinitBlock` calls `deinit` for that reason, and it is
//! the only call the sweep makes out to a structure that is not the
//! collector's.
//!
//! ## The allocation shape
//!
//! A symbol is a `strings.StringHead` and its payload in a single collectable
//! block, sized once and never resized, which is the shape `strings.zig` and
//! `tuples.zig` use as well. The value is the address of the payload, so
//! `strings.head` subtracts an offset to reach the header.
//!
//! `intern` and `gensym` write the hash into the head themselves rather than
//! going through `strings.begin` and `strings.end`: the lookup that decided
//! the name was absent computed the hash already, and a symbol whose head is
//! filled in a second step would be a symbol nothing may put in a dictionary
//! until then.
//!
//! ## Keywords
//!
//! A keyword is a symbol of the other kind, and a value holding either has the
//! symbol tag. The kind is on the block: a keyword's head has `own_keyword` set
//! in its per-type bits, and `isKeyword` reads it. `a` and `:a` are two
//! blocks, not one block under two tags.
//!
//! The cache holds both kinds and tells them apart by hash. A keyword's hash
//! is its bytes' hash with `keyword_hash_mix` xored in, which is nonzero, so a
//! symbol and a keyword with equal bytes never have equal hashes and the
//! cache's comparison of hash and bytes never takes one for the other. The
//! mixed hash is the stored one, so `a` and `:a` also land in different
//! buckets of a table.

// ==========================================================================
// Project imports
// ==========================================================================

const c = @import("cabi");
const fatal = @import("../fatal.zig");
const gc_alloc = @import("../gc.zig");
const strings = @import("strings.zig");
const utils = @import("../utils.zig");
const value = @import("../value.zig");
const vm_state = @import("../vm/state.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// The cache's starting size. A power of two, because a probe masks with
/// `capacity - 1`.
const initial_capacity: u32 = 1024;

/// What a keyword's hash has xored into its bytes' hash. Any nonzero value
/// keeps the two kinds apart; this one also spreads the bits.
pub const keyword_hash_mix: i32 = @bitCast(@as(u32, 0x9e3779b9));

/// Bit 0 of the collector header's per-type field: the symbol is a keyword.
pub const own_keyword: u6 = 1;

/// The tombstone, compared by address and never dereferenced.
///
/// Declared `var` so that the linker cannot merge this single zero byte with
/// an identical constant elsewhere in the image: a merged tombstone would
/// alias an object that is not the tombstone, and the comparison is by
/// address.
var symcache_deleted: [1]u8 = .{0};

// ==========================================================================
// Aliased types
// ==========================================================================

/// The gensym odometer: a leading underscore, six base-62 digits, and the byte
/// the terminator overwrites. It sits on the VM beside the cache rather than
/// inside it, because `gen` reaches both, and this names the shape they share.
pub const GensymCounter = [8]u8;

// ==========================================================================
// Types
// ==========================================================================

/// Which of the two interned kinds a name is.
pub const Kind = enum { symbol, keyword };

/// Where a name sits in the cache, or where it would go.
///
/// The two cases are separate arms because the slot means two different
/// things, the entry with the interned symbol in it or the empty entry the
/// name would be installed in, and naming both is what makes reading the slot
/// as an interned symbol impossible without first deciding which case it is.
const Lookup = union(enum) {
    /// The entry with the interned name in it.
    found: *?[*:0]const u8,
    /// The empty or tombstoned entry the name would go in. Never absent: the
    /// load factor `cachePut` maintains is what makes a full table impossible,
    /// and `cacheFindmem` calls `fatal.fatal` rather than returning a third
    /// case.
    vacant: *?[*:0]const u8,
};

/// The symbol cache: open addressing over interned symbol names, with a
/// tombstone for a deleted entry. `vm/state.zig`'s `Vm` has one, and this file
/// owns its lifecycle.
pub const SymbolCache = struct {
    entries: ?[*]?[*:0]const u8 = null,
    capacity: u32 = 0,
    count: u32 = 0,
    deleted: u32 = 0,
};

// ==========================================================================
// Public functions
// ==========================================================================

/// Releases the current VM's cache. `vm/lifecycle.zig` calls this on the way
/// down.
pub fn cacheDeinit() void {
    cacheFree(&vm_state.current().symcache);
}

/// Allocates the current VM's cache and resets its gensym odometer.
/// `vm/lifecycle.zig` calls this before anything can intern.
pub fn cacheInit() void {
    const v = vm_state.current();
    cacheAlloc(&v.symcache);
    gensymInit(&v.gensym_counter);
}

/// Interns a NUL-terminated name and returns the keyword. This is `keyword`
/// for a caller that has a C string rather than a slice.
pub fn ckeyword(cstr: [*:0]const u8) [*:0]const u8 {
    return keyword(cstr[0..c.strlen(cstr)]);
}

/// Interns a NUL-terminated name and returns the symbol.
///
/// `cstr` is the name, measured with `strlen` here. This is `new` for a caller
/// that has a C string rather than a slice.
pub fn csymbol(cstr: [*:0]const u8) [*:0]const u8 {
    return new(cstr[0..c.strlen(cstr)]);
}

/// Drops `sym` from the current VM's cache. `gc/sweep.zig`'s `deinitBlock`
/// calls this as it frees the block.
pub fn deinit(sym: [*:0]const u8) void {
    cacheRemove(&vm_state.current().symcache, sym);
}

/// Returns a fresh gensym from the current VM's cache and counter.
pub fn gen() [*:0]const u8 {
    const v = vm_state.current();
    return gensym(&v.symcache, &v.gensym_counter);
}

/// Whether the interned name `sym` is a keyword rather than a symbol.
///
/// It reads the block's head and cannot raise.
pub inline fn isKeyword(sym: [*:0]const u8) bool {
    return strings.head(sym).gc.flags.own & own_keyword != 0;
}

/// Interns `str` as a keyword in the current VM's cache and returns it.
///
/// The result is the existing keyword where one with the name is already
/// cached. A symbol with the same bytes is a different block.
pub fn keyword(str: []const u8) [*:0]const u8 {
    return intern(&vm_state.current().symcache, str, .keyword);
}

/// Interns `str` in the current VM's cache and returns the symbol.
///
/// The result is the existing symbol where the name is already cached, so two
/// calls with equal bytes return the same pointer. A keyword with the same
/// bytes is a different block.
pub fn new(str: []const u8) [*:0]const u8 {
    return intern(&vm_state.current().symcache, str, .symbol);
}

// ==========================================================================
// Private functions
// ==========================================================================

/// Allocates `sc`'s table at `initial_capacity`. Reached through `cacheInit`.
fn cacheAlloc(sc: *SymbolCache) void {
    sc.* = .{
        .capacity = initial_capacity,
        .entries = @ptrCast(@alignCast(utils.calloc(1, initial_capacity *% @sizeOf(?*const u8)) orelse
            fatal.outOfMemory())),
    };
}

/// `cacheFindmem` over a NUL-terminated name, which is the form every caller
/// in this file has.
inline fn cacheFind(sc: *SymbolCache, str: [*:0]const u8) Lookup {
    return cacheFindmem(sc, strings.bytesOf(str), strings.hashOf(str));
}

/// Finds `str` in `sc`, or the entry it belongs in.
///
/// `hash` is `str`'s hash, which the caller has computed already.
///
/// The scan covers the whole table in two ranges, the ideal index to the end
/// and then the start to the ideal index, and stops at the first genuinely
/// empty slot, because open addressing puts nothing beyond an empty slot.
/// Tombstones do not stop it, but the first tombstone is remembered, and a key
/// found after a tombstone is moved back into it. That last move is why this
/// is not a pure lookup: it rewrites the table on a successful find, which
/// keeps probe sequences short without a separate compaction pass.
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

/// Frees `sc`'s table and resets it.
///
/// The symbols it pointed at are not freed here: they are ordinary
/// collectable blocks and `gc/sweep.zig`'s `clearMemory` takes them.
fn cacheFree(sc: *SymbolCache) void {
    utils.free(@ptrCast(@constCast(sc.entries)));
    sc.* = .{};
}

/// Installs `x` in `vacant`, growing `sc` first if it is half full.
///
/// Counting tombstones toward the load factor is what stops a long run of
/// create-and-collect from degrading every probe to a full scan.
fn cachePut(sc: *SymbolCache, x: [*:0]const u8, vacant: *?[*:0]const u8) void {
    var slot = vacant;
    if ((sc.count +% sc.deleted) *% 2 > sc.capacity) {
        // Floored at four buckets. The target is derived from `count`, which
        // is zero once every symbol has died, and `capacityFor` gives one or
        // two for a small count. At those two capacities this load factor,
        // tested before the increment and so allowing at most
        // `capacity / 2 + 1` entries afterwards, fills the table, and a full
        // table is a state `cacheFindmem` has no case for.
        const target: u32 = @intCast(value.capacityFor(2 *% sc.count +% 1));
        cacheResize(sc, @max(target, 4));
        slot = switch (cacheFind(sc, x)) {
            .found, .vacant => |found| found,
        };
    }
    sc.count +%= 1;
    slot.* = x;
}

/// Drops `sym` from `sc`, leaving a tombstone behind. Reached through
/// `deinit`, which the collector calls as it frees the block.
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

/// Rebuilds `sc`'s table at `new_capacity`, dropping every tombstone.
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
            // `.found` is unreachable: the fresh table is built from a table
            // with no duplicates in it. The `break` is kept because it is what
            // the branch does if the invariant ever fails, and it is worse
            // than the condition it guards, abandoning every remaining entry
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

/// The tombstone as a name pointer, for comparison against a cache entry.
inline fn deleted() [*:0]const u8 {
    return @ptrCast(&symcache_deleted);
}

/// Returns a symbol from `sc` that collides with no live symbol.
///
/// `counter` is the odometer, advanced until a name is found that the cache
/// does not already have. That last part matters because a gensym from an
/// earlier cycle may still be alive.
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
    // byte, so the name is the first `hd.length` characters of the odometer.
    @memcpy(sym[0..counter.len], counter);
    sym[hd.length] = 0;
    const interned: [*:0]const u8 = @ptrCast(sym);
    cachePut(sc, interned, vacant);
    return interned;
}

/// Sets `counter` to the odometer's starting state, which is where `cacheInit`
/// leaves it.
fn gensymInit(counter: *GensymCounter) void {
    @memset(counter, '0');
    counter[0] = '_';
}

/// Advances `counter`, a base-62 odometer over positions 1 through 6. Position
/// 0 is the leading underscore and is never touched, so the counter wraps
/// silently after 62^6 names rather than growing.
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

/// Returns the symbol of `kind` for `str` in `sc`, building and registering it
/// where the name is not cached already as that kind.
fn intern(sc: *SymbolCache, str: []const u8, kind: Kind) [*:0]const u8 {
    const hash = switch (kind) {
        .symbol => value.hashBytes(str),
        .keyword => value.hashBytes(str) ^ keyword_hash_mix,
    };
    const vacant = switch (cacheFindmem(sc, str, hash)) {
        .found => |slot| return slot.*.?,
        .vacant => |slot| slot,
    };

    const hd = gc_alloc.gcallocWithPayload(strings.StringHead, .symbol, str.len +% 1);
    if (kind == .keyword) hd.gc.flags.own |= own_keyword;
    hd.hash = hash;
    hd.length = @intCast(str.len);
    const newstr = strings.data(hd);
    @memcpy(newstr[0..str.len], str);
    newstr[str.len] = 0;
    const interned: [*:0]const u8 = @ptrCast(newstr);
    cachePut(sc, interned, vacant);
    return interned;
}
