//! Behavioral contract for the immutable head-allocated sequences: strings,
//! symbols and the symbol cache, and tuples.
//!
//! All three of these types are a header and a payload in one
//! `gc.gcallocWithPayload`,
//! and the value Janet passes around is the address of the payload.
//!
//! The observable surface splits three ways.
//!
//! The fields are directly checkable: a string's length and hash, a tuple's
//! length, hash and source-map position, and the memory type in the GC header
//! that decides which of `gc/sweep.zig`'s `deinitBlock` cases will free it.
//!
//! The symbol cache is checkable through `vm.symcache.count` and
//! `vm.symcache.deleted`, and through pointer identity: interning means two
//! calls with the same name return the same address, and that is a stronger
//! statement than equality. It is also the property that makes symbol
//! comparison a pointer comparison everywhere else in the runtime, so it is
//! the one worth asserting hardest.
//!
//! Hashing is checkable only for consistency, not for value.
//! `value.hashBytes` is a different subsystem and changes under `-Dprf`,
//! so nothing here asserts a particular hash. What it does assert is that the
//! hash a constructor stores is the one that function returns, and that equal
//! contents hash equally.
//!
//! ## Where the head-layout assertion went
//!
//! The head offsets are not pinned here. What would say a string or tuple
//! head is exactly its own size is that the size equals the offset of `data`,
//! and a head with a flexible array member loses it in translation, so
//! `@offsetOf` does not compile against one while `utils.stringHead` recovers
//! the header with `@sizeOf`. The comparison would be `@sizeOf` against
//! itself. `test/gc_mark.zig`'s `theHeadOffsets` derives each offset from the
//! address the allocator recorded and compares it against `@sizeOf`, and it
//! covers the string and tuple heads.
//!
//! ## Two things this deliberately does not cover
//!
//! `strings.begin` and `tuples.begin` leave the hash uninitialised, and there
//! is no way to assert an indeterminate value, so the cases below read it only
//! after the matching `end`. And `cacheFindmem` ends the process when the
//! table is full, which the rehash floor puts out of reach: a case arranged to
//! get there would end the test process rather than fail an assertion.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const core_env = @import("subsystems").env;
const expect = @import("expect.zig").expect;
const gc_alloc = @import("subsystems").gc_alloc;
const gc_mark = @import("subsystems").gc_mark;
const harness = @import("harness.zig");
const heap = harness.heap;

const registry = @import("subsystems").registry;
const repr = @import("repr");
const strings = @import("subsystems").value.strings;
const symbols = @import("subsystems").value.symbols;
const tuples = @import("subsystems").value.tuples;
const utils = @import("subsystems").utils;
const value = @import("subsystems").value;
const vm_lifecycle = @import("subsystems").lifecycle;
const wrap = @import("subsystems").value.wrap;

// ==========================================================================
// Constants
// ==========================================================================

/// The length of a generated name, which is the odometer minus its leading
/// underscore.
const gensym_length: i32 = @as(i32, @intCast(@typeInfo(@TypeOf(harness.vm().gensym_counter)).array.len)) - 1;

// ==========================================================================
// Cases
// ==========================================================================

fn stringLength(s: [*]const u8) u32 {
    return strings.head(s).length;
}

fn stringHash(s: [*]const u8) i32 {
    return strings.head(s).hash;
}

fn bytesOf(s: [*]const u8) []const u8 {
    return s[0..stringLength(s)];
}

fn calchash(bytes: []const u8) i32 {
    return value.hashBytes(bytes);
}

/// Is `symbol` in the cache? Walks the table rather than calling the finder,
/// so that a case can distinguish "interned" from "would be found by the same
/// lookup the implementation uses".
fn inCache(symbol: [*:0]const u8) bool {
    var index: u32 = 0;
    while (index < harness.vm().symcache.capacity) : (index += 1) {
        if (harness.vm().symcache.entries.?[index] == symbol) return true;
    }
    return false;
}

/// A string built in two steps: the length is set by `begin`, the terminator
/// is written by `begin`, and the hash is written by `end` and nowhere else.
fn stringBeginAndEnd() void {
    const s = strings.begin(5);
    expect(stringLength(s) == 5);
    expect(s[5] == 0);
    expect(heap.memoryType(strings.head(s)) == gc_alloc.MemoryType.string);
    expect(heap.onList(harness.vm().gc.blocks, strings.head(s)));

    @memcpy(s[0..5], "hello");
    const done = strings.end(s);
    expect(done == s);
    expect(stringLength(done) == 5);
    expect(stringHash(done) == calchash("hello"));

    // A zero-length string is legal, terminated, and has the empty hash.
    const e = strings.begin(0);
    expect(stringLength(e) == 0);
    expect(e[0] == 0);
    expect(stringHash(strings.end(e)) == calchash(""));
}

/// Fill the allocator's free list with blocks of `size` whose bytes are all
/// 0xFF, and report whether they come back that way.
///
/// Every assertion that a constructor wrote a terminator is vacuous on a block
/// that arrived zeroed, and whether one does is a property of the C library
/// rather than of Janet: macOS zeroes small allocations and leaves large ones
/// alone, glibc leaves both. So the terminator case probes first and asserts
/// only where a dirty block makes the assertion mean something.
fn dirtyFreeList(size: usize) bool {
    var junk: [8]?*anyopaque = undefined;
    for (&junk) |*slot| {
        slot.* = utils.malloc(size);
        expect(slot.* != null);
        @memset(@as([*]u8, @ptrCast(slot.*))[0..size], 0xFF);
    }
    for (junk) |slot| utils.free(slot);

    const check: [*]u8 = @ptrCast(utils.malloc(size).?);
    const dirty = check[size - 1] != 0;
    @memset(check[0..size], 0xFF);
    utils.free(check);
    return dirty;
}

/// Both constructors write a zero one byte past the length, so that a Janet
/// string can be handed to a C function that expects one. Asserted on a block
/// large enough that this allocator does not zero it; see `dirtyFreeList`.
fn constructorsWriteTheTerminator() void {
    const n: i32 = 8192;
    const block = @sizeOf(strings.StringHead) + @as(usize, n) + 1;
    if (!dirtyFreeList(block)) return;

    const begun = strings.begin(n);
    expect(begun[@intCast(n)] == 0);

    const source: [*]u8 = @ptrCast(utils.malloc(@intCast(n)).?);
    @memset(source[0..@intCast(n)], 'x');
    _ = dirtyFreeList(block);
    const copied = strings.new(source[0..@intCast(n)]);
    expect(copied[@intCast(n)] == 0);
    expect(std.mem.eql(u8, copied[0..@intCast(n)], source[0..@intCast(n)]));
    utils.free(source);
}

/// `string/repeat` copies exactly `n` times into the string `begin` sized and
/// terminated, so the byte past the last copy is still the terminator. No
/// allocator probe is needed: a copy past the end overwrites the zero `begin`
/// wrote, whatever the block held before.
///
/// It reaches `string/repeat` through the core environment, and building that
/// interns every core name, so it runs after the cases that count the cache.
fn repeatStopsAtTheLength() void {
    var argv = [_]repr.Value{ wrap.fromString(strings.cstring("ab")), harness.wrapInteger(3) };
    const out = harness.callCore("string/repeat", &argv) catch
        @panic("string_symbol: string/repeat raised");
    expect(harness.isType(out, repr.Tag.string));
    const s = wrap.toString(out);
    expect(std.mem.eql(u8, bytesOf(s), "ababab"));
    expect(s[6] == 0);
}

/// The one-step constructor copies and hashes immediately.
fn stringCopiesAndHashes() void {
    const s = strings.new("world");
    expect(stringLength(s) == 5);
    expect(std.mem.eql(u8, bytesOf(s), "world"));
    expect(s[5] == 0);
    expect(stringHash(s) == calchash("world"));

    // The source is copied, so a caller's buffer may change afterwards.
    var source = [3]u8{ 'a', 'b', 'c' };
    const copy = strings.new(source[0..@intCast(3)]);
    source[0] = 'z';
    expect(std.mem.eql(u8, bytesOf(copy), "abc"));

    // An interior zero is content, not a terminator: the length comes from the
    // head and the bytes past the zero are part of the string.
    const nul = strings.new("a\x00b");
    expect(stringLength(nul) == 3);
    expect(std.mem.eql(u8, bytesOf(nul), "a\x00b"));
    expect(nul[3] == 0);

    // `janet_cstring` takes its length from the bytes instead.
    const cs = strings.cstring("a\x00b");
    expect(stringLength(cs) == 1);
    expect(cs[0] == 'a' and cs[1] == 0);
}

/// Ordering is three-valued and by prefix. The normalisation matters:
/// `memcmp` may return any value of the right sign, and callers compare
/// against 1 and -1.
fn stringCompareIsThreeValued() void {
    const a = strings.cstring("abc");
    const b = strings.cstring("abd");
    const prefix = strings.cstring("ab");
    const same = strings.cstring("abc");

    expect(strings.compare(a, b) == -1);
    expect(strings.compare(b, a) == 1);
    expect(strings.compare(a, same) == 0);
    expect(strings.compare(a, a) == 0);

    // A prefix is less than what extends it, whichever side it is on.
    expect(strings.compare(prefix, a) == -1);
    expect(strings.compare(a, prefix) == 1);

    // A large byte difference still normalises to exactly one.
    const low = strings.new("\x01");
    const high = strings.new("\xFF");
    expect(strings.compare(low, high) == -1);
    expect(strings.compare(high, low) == 1);

    // The empty string is least, and equal to itself.
    const empty = strings.cstring("");
    expect(strings.compare(empty, a) == -1);
    expect(strings.compare(empty, empty) == 0);
}

/// Equality rejects on the hash or the length before it touches the bytes, and
/// short-circuits on identity. Both are what make the symbol cache cheap.
fn stringEquality() void {
    const a = strings.cstring("abc");
    const b = strings.cstring("abc");
    const d = strings.cstring("abd");

    expect(strings.equal(a, b));
    expect(strings.equal(a, a));
    expect(!strings.equal(a, d));

    // Same bytes, right hash and length: equal.
    expect(strings.equalconst(a, "abc", calchash("abc")));

    // A wrong hash rejects even when the bytes are identical, because this
    // entry point trusts the hash it is given rather than recomputing it.
    expect(!strings.equalconst(a, "abc", calchash("zzz")));

    // The length and byte checks are harder to reach honestly, because the
    // hash mixes the length in and so rejects almost every mismatched argument
    // before either runs. They are reachable through the public API, though,
    // which is what these two do: pass the hash `lhs` actually has, and vary
    // only the thing being tested. Without this, the length comparison and the
    // `memcmp` are both dead code that no case distinguishes.
    expect(!strings.equalconst(a, "abc"[0..2], stringHash(a)));
    expect(!strings.equalconst(a, "abd", stringHash(a)));

    // And the same arguments with nothing varied still match, so the two above
    // are rejections rather than an entry point that rejects everything.
    expect(strings.equalconst(a, "abc", stringHash(a)));

    // Interior zeros are compared, not stopped at.
    const n1 = strings.new("a\x00b");
    const n2 = strings.new("a\x00c");
    expect(!strings.equal(n1, n2));
}

/// Interning is pointer identity, which is stronger than equality and is what
/// the rest of the runtime relies on.
fn symbolInterns() void {
    const before = harness.vm().symcache.count;

    const s1 = symbols.csymbol("interned-test-symbol");
    expect(harness.vm().symcache.count == before + 1);
    expect(heap.memoryType(strings.head(s1)) == gc_alloc.MemoryType.symbol);
    expect(heap.onList(harness.vm().gc.blocks, strings.head(s1)));
    expect(inCache(s1));

    // The same name returns the same address and allocates nothing.
    const s2 = symbols.csymbol("interned-test-symbol");
    expect(s2 == s1);
    expect(harness.vm().symcache.count == before + 1);

    // A different name is a different address.
    const s3 = symbols.csymbol("interned-test-symbol-2");
    expect(s3 != s1);
    expect(harness.vm().symcache.count == before + 2);

    // Interning is by length as well as by bytes, so an interior zero
    // distinguishes two symbols a C string could not tell apart.
    const z1 = symbols.new("zz\x00a");
    const z2 = symbols.new("zz\x00b");
    expect(z1 != z2);
    expect(symbols.new("zz\x00a") == z1);

    // A symbol and a string with the same bytes are different objects with
    // different memory types, and still compare equal as byte strings.
    const str = strings.cstring("interned-test-symbol");
    expect(str != s1);
    expect(heap.memoryType(strings.head(str)) == gc_alloc.MemoryType.string);
    expect(strings.equal(str, s1));
}

/// A keyword is a symbol of the other kind. The two kinds of one name are two
/// blocks in one cache, each interned on its own, and a value of either has
/// the symbol tag. The kind is the keyword bit in the head, and a keyword's
/// stored hash is its bytes' hash mixed with `keyword_hash_mix`, which is what
/// keeps the cache and a table from taking one kind for the other.
fn aKeywordIsASymbolOfTheOtherKind() void {
    const before = harness.vm().symcache.count;
    const s = symbols.csymbol("interned-test-kind");
    const k = symbols.ckeyword("interned-test-kind");
    expect(k != s);
    expect(harness.vm().symcache.count == before + 2);
    expect(symbols.ckeyword("interned-test-kind") == k);
    expect(symbols.csymbol("interned-test-kind") == s);
    expect(harness.vm().symcache.count == before + 2);

    expect(symbols.isKeyword(k) and !symbols.isKeyword(s));
    expect(heap.memoryType(strings.head(k)) == gc_alloc.MemoryType.symbol);
    expect(strings.head(s).hash == calchash(bytesOf(s)));
    expect(strings.head(k).hash == calchash(bytesOf(k)) ^ symbols.keyword_hash_mix);
    expect(strings.head(k).hash != strings.head(s).hash);

    const kv = wrap.fromKeyword(k);
    const sv = wrap.fromSymbol(s);
    expect(repr.typeOf(kv) == repr.Tag.symbol and repr.typeOf(sv) == repr.Tag.symbol);
    expect(wrap.isKeyword(kv) and !wrap.isSymbol(kv));
    expect(wrap.isSymbol(sv) and !wrap.isKeyword(sv));
    expect(wrap.toKeyword(value.fromBytes("interned-test-kind", .keyword)) == k);
}

/// Removing a symbol leaves a tombstone: the count falls, the deleted count
/// rises, and the name is available again, at a new address.
fn symbolDeinitLeavesATombstone() void {
    var count = harness.vm().symcache.count;
    var deleted = harness.vm().symcache.deleted;

    const s = symbols.csymbol("tombstone-test-symbol");
    expect(harness.vm().symcache.count == count + 1);
    expect(inCache(s));

    symbols.deinit(s);
    expect(harness.vm().symcache.count == count);
    expect(harness.vm().symcache.deleted == deleted + 1);
    expect(!inCache(s));

    // The name interns again, to a different block.
    const again = symbols.csymbol("tombstone-test-symbol");
    expect(again != s);
    expect(harness.vm().symcache.count == count + 1);
    expect(inCache(again));

    // Removing something that was never there changes nothing.
    count = harness.vm().symcache.count;
    deleted = harness.vm().symcache.deleted;
    const loose = strings.new("never-interned");
    symbols.deinit(loose);
    expect(harness.vm().symcache.count == count);
    expect(harness.vm().symcache.deleted == deleted);
}

/// Where in the table is `symbol`, and where would a name ideally go? Together
/// these make the probe sequence observable, which is the only way to see what
/// a lookup does to the table on its way past a tombstone.
fn cacheIndexOf(symbol: [*:0]const u8) ?u32 {
    var index: u32 = 0;
    while (index < harness.vm().symcache.capacity) : (index += 1) {
        if (harness.vm().symcache.entries.?[index] == symbol) return index;
    }
    return null;
}

fn idealIndex(name: []const u8) u32 {
    const hash: u32 = @bitCast(calchash(name));
    return hash & (harness.vm().symcache.capacity - 1);
}

/// A successful lookup is not a pure read: if the key was found *after* a
/// tombstone, it is moved back into the tombstone's slot and its old slot
/// becomes one. That keeps probe sequences short as symbols come and go, and
/// without it a table that has churned degrades toward a full scan per lookup.
///
/// It needs two names that collide, so this searches for a pair rather than
/// assuming one. Nothing here may cross the load factor, or a rehash would
/// relocate everything and hide what is being tested.
fn lookupReclaimsATombstone() void {
    var first_buffer: [32]u8 = undefined;
    var second_buffer: [40]u8 = undefined;
    var first: [:0]u8 = undefined;
    var second: [:0]u8 = undefined;
    var found = false;

    var i: u32 = 0;
    outer: while (i < 20000) : (i += 1) {
        first = std.fmt.bufPrintZ(&first_buffer, "collide-a-{d}", .{i}) catch unreachable;
        const target = idealIndex(first);
        var j: u32 = 0;
        while (j < 400) : (j += 1) {
            second = std.fmt.bufPrintZ(&second_buffer, "collide-b-{d}-{d}", .{ i, j }) catch unreachable;
            if (idealIndex(second) == target) {
                found = true;
                break :outer;
            }
        }
    }
    expect(found);

    const capacity = harness.vm().symcache.capacity;
    const a = symbols.csymbol(first.ptr);
    const b = symbols.csymbol(second.ptr);
    gc_alloc.gcroot(wrap.fromSymbol(a));
    gc_alloc.gcroot(wrap.fromSymbol(b));
    expect(harness.vm().symcache.capacity == capacity);

    const pos_a = cacheIndexOf(a).?;
    const pos_b = cacheIndexOf(b).?;
    expect(pos_a != pos_b);
    expect(pos_a == idealIndex(first));

    // Delete the first, leaving a tombstone directly in the second's path.
    symbols.deinit(a);
    expect(cacheIndexOf(a) == null);
    expect(harness.vm().symcache.entries.?[pos_a] != null);

    // Looking the second one up moves it into that slot. Its address does
    // not change, interning still being identity; only its position does.
    expect(symbols.csymbol(second.ptr) == b);
    expect(cacheIndexOf(b).? == pos_a);
    expect(harness.vm().symcache.entries.?[pos_b] != null);
    expect(harness.vm().symcache.entries.?[pos_b] != b);
    expect(harness.vm().symcache.capacity == capacity);

    _ = gc_alloc.gcunroot(wrap.fromSymbol(a));
    _ = gc_alloc.gcunroot(wrap.fromSymbol(b));
}

/// Growing past the load factor rehashes: the capacity rises, every tombstone
/// is dropped, and every live symbol is still found at its original address.
fn cacheResizesAndKeepsIdentity() void {
    var name: [40]u8 = undefined;
    var kept: [400][*:0]const u8 = undefined;

    // Keep them alive across the resize by rooting them.
    for (&kept, 0..) |*slot, i| {
        const text = std.fmt.bufPrintZ(&name, "resize-probe-{d}", .{i}) catch unreachable;
        slot.* = symbols.csymbol(text.ptr);
        gc_alloc.gcroot(wrap.fromSymbol(slot.*));
    }

    // Delete half, which raises the tombstone count without lowering capacity.
    var i: usize = 0;
    while (i < 400) : (i += 2) symbols.deinit(kept[i]);
    expect(harness.vm().symcache.deleted >= 200);

    // Force enough puts to cross the load factor and rehash.
    const capacity_before = harness.vm().symcache.capacity;
    for (0..1200) |n| {
        const text = std.fmt.bufPrintZ(&name, "resize-filler-{d}", .{n}) catch unreachable;
        gc_alloc.gcroot(wrap.fromSymbol(symbols.csymbol(text.ptr)));
    }
    expect(harness.vm().symcache.capacity > capacity_before);

    // Every survivor is still interned, at the address it always had.
    i = 1;
    while (i < 400) : (i += 2) {
        const text = std.fmt.bufPrintZ(&name, "resize-probe-{d}", .{i}) catch unreachable;
        expect(symbols.csymbol(text.ptr) == kept[i]);
        expect(inCache(kept[i]));
    }

    // Every deleted one interns fresh rather than coming back.
    i = 0;
    while (i < 400) : (i += 2) {
        const text = std.fmt.bufPrintZ(&name, "resize-probe-{d}", .{i}) catch unreachable;
        expect(symbols.csymbol(text.ptr) != kept[i]);
    }

    for (kept) |symbol| _ = gc_alloc.gcunroot(wrap.fromSymbol(symbol));
}

/// Tombstones count toward the load factor, and that is what keeps a table
/// that churns from degrading. A symbol created and immediately deleted leaves
/// `cache_count` where it was and `cache_deleted` one higher, so a long run of
/// them adds no entries at all and still has to force a rehash. If only live
/// entries were counted the tombstones would accumulate without bound until no
/// empty slot remained and the finder gave up.
fn tombstonesForceARehash() void {
    var high_water: u32 = 0;
    var rehashed = false;
    var name: [40]u8 = undefined;

    for (0..200000) |i| {
        const text = std.fmt.bufPrintZ(&name, "churn-symbol-{d}", .{i}) catch unreachable;
        const s = symbols.csymbol(text.ptr);

        if (harness.vm().symcache.deleted > high_water) high_water = harness.vm().symcache.deleted;
        // The invariant a live count alone would not maintain.
        expect(harness.vm().symcache.deleted < harness.vm().symcache.capacity);

        if (harness.vm().symcache.deleted == 0 and high_water > 8) {
            rehashed = true;
            symbols.deinit(s);
            break;
        }
        symbols.deinit(s);
    }
    expect(rehashed);
}

/// The cache resizes at the first put past half full and not at half. A put
/// that finds `count + deleted` at exactly half the capacity leaves the
/// capacity alone, and the next put resizes to `capacityFor(2 * count + 1)`.
fn cacheGrowsPastHalf() void {
    const cache = &harness.vm().symcache;
    var name: [40]u8 = undefined;
    var n: usize = 0;
    while ((cache.count + cache.deleted) * 2 != cache.capacity) : (n += 1) {
        const text = std.fmt.bufPrintZ(&name, "half-probe-{d}", .{n}) catch unreachable;
        _ = symbols.csymbol(text.ptr);
    }

    const capacity = cache.capacity;
    _ = symbols.csymbol("half-probe-at-half");
    expect(cache.capacity == capacity);
    expect((cache.count + cache.deleted) * 2 == capacity + 2);

    const live = cache.count;
    _ = symbols.csymbol("half-probe-past-half");
    expect(cache.capacity == value.capacityFor(2 * live + 1));
    expect(cache.deleted == 0);
    expect(cache.count == live + 1);
}

/// The leading underscore comes from `symbols.cacheInit` and nothing else
/// ever writes it, so it is the one part of the counter's initial state that
/// survives to be observed. This case has to run before the one below, which
/// resets the counter itself and would make the same assertion vacuous.
fn generatedNamesComeFromTheInitialCounter() void {
    const g = symbols.gen();
    gc_alloc.gcroot(wrap.fromSymbol(g));
    expect(g[0] == '_');
    expect(stringLength(g) == gensym_length);
    for (bytesOf(g)[1..]) |byte| {
        expect(std.ascii.isAlphanumeric(byte));
    }
    _ = gc_alloc.gcunroot(wrap.fromSymbol(g));
}

/// Reset the odometer to the state `symbols.cacheInit` leaves.
fn resetGensymCounter() void {
    @memset(&harness.vm().gensym_counter, '0');
    harness.vm().gensym_counter[0] = '_';
}

/// A generated symbol is interned like any other, and the counter advances
/// only when a name is already taken, so the sequence is exactly the
/// odometer.
fn gensymAdvancesTheOdometer() void {
    // Start from the state `symbols.cacheInit` leaves, so the sequence is
    // predictable however many gensyms ran before this. Collecting first drops
    // the ones earlier cases made, which would otherwise still be cached and
    // would make the counter skip past them.
    gc_mark.collect();
    resetGensymCounter();

    const last: usize = @intCast(gensym_length - 1);
    var seen: [40][*:0]const u8 = undefined;
    for (&seen) |*slot| {
        slot.* = symbols.gen();
        gc_alloc.gcroot(wrap.fromSymbol(slot.*));
        expect(stringLength(slot.*) == gensym_length);
        expect(slot.*[0] == '_');
        expect(heap.memoryType(strings.head(slot.*)) == gc_alloc.MemoryType.symbol);
        expect(inCache(slot.*));
    }

    // All distinct, and each is the one the cache has interned for its name.
    for (seen, 0..) |symbol, i| {
        for (seen[i + 1 ..]) |other| expect(symbol != other);
        expect(symbols.new(symbol[0..@intCast(gensym_length)]) == symbol);
    }

    // The last character walks '0'..'9', then 'a'..'z', then 'A'..'Z', and
    // the two rollovers at '9' and at 'z' are the whole of what the counter
    // does beyond incrementing a byte. Only the final position moves over
    // forty names, so the rest stay where the reset above put them.
    //
    // The starting point is read from the first name rather than assumed to be
    // '0', because a name already in the cache is skipped rather than
    // reused, and a symbol surviving from the boot process would shift the
    // whole run by one.
    const alphabet = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
    const start = std.mem.indexOfScalar(u8, alphabet, seen[0][last]).?;
    expect(start + 40 <= alphabet.len);
    for (seen, 0..) |symbol, i| {
        expect(symbol[last] == alphabet[start + i]);
        for (bytesOf(symbol)[1..last]) |byte| expect(byte == '0');
    }

    for (seen) |symbol| _ = gc_alloc.gcunroot(wrap.fromSymbol(symbol));
}

/// The rollover between positions, which the forty-name run above cannot
/// reach: exhausting a position wraps it to '0' and advances the one to its
/// left. Getting there by counting would take sixty-three names, so the
/// odometer is set to its last value at the lowest position and stepped once.
fn gensymCarriesBetweenPositions() void {
    gc_mark.collect();
    const last: usize = @intCast(gensym_length - 1);
    resetGensymCounter();
    harness.vm().gensym_counter[last] = 'Z';

    const before = symbols.gen();
    gc_alloc.gcroot(wrap.fromSymbol(before));
    expect(before[last] == 'Z');
    for (bytesOf(before)[1..last]) |byte| expect(byte == '0');

    const carried = symbols.gen();
    gc_alloc.gcroot(wrap.fromSymbol(carried));
    expect(carried != before);
    expect(carried[last] == '0');
    expect(carried[last - 1] == '1');
    for (bytesOf(carried)[1 .. last - 1]) |byte| expect(byte == '0');

    _ = gc_alloc.gcunroot(wrap.fromSymbol(before));
    _ = gc_alloc.gcunroot(wrap.fromSymbol(carried));
}

/// The collector's one external obligation: a symbol that dies leaves the
/// cache. `gc/sweep.zig`'s `deinitBlock` calls `symbols.deinit` from this
/// subsystem, so the round trip is entirely inside Zig.
fn collectedSymbolLeavesTheCache() void {
    gc_mark.collect();
    const before = harness.vm().symcache.count;

    var name: [40]u8 = undefined;
    for (0..50) |i| {
        const text = std.fmt.bufPrintZ(&name, "doomed-symbol-{d}", .{i}) catch unreachable;
        _ = symbols.csymbol(text.ptr);
    }
    expect(harness.vm().symcache.count == before + 50);

    gc_mark.collect();
    expect(harness.vm().symcache.count == before);

    // A rooted one survives the same collection and keeps its address.
    const kept = symbols.csymbol("kept-symbol");
    gc_alloc.gcroot(wrap.fromSymbol(kept));
    gc_mark.collect();
    expect(symbols.csymbol("kept-symbol") == kept);
    expect(inCache(kept));
    _ = gc_alloc.gcunroot(wrap.fromSymbol(kept));
}

/// A tuple built in two steps. `begin` sets the length and marks the
/// source-map position absent with -1; `end` computes the hash over every
/// slot.
fn tupleBeginAndEnd() void {
    const t = tuples.begin(3);
    expect(tuples.head(t).length == 3);
    expect(tuples.head(t).sm_line == -1);
    expect(tuples.head(t).sm_column == -1);
    expect(heap.memoryType(tuples.head(t)) == gc_alloc.MemoryType.tuple);
    expect(heap.onList(harness.vm().gc.blocks, tuples.head(t)));

    t[0] = harness.wrapInteger(1);
    t[1] = wrap.fromNil();
    t[2] = value.fromBytes("k", .keyword);
    const done = tuples.end(t);
    expect(done == t);
    expect(tuples.head(done).hash == value.hashIndexed(t[0..3]));

    // A zero-length tuple is legal and hashes as the empty sequence.
    const empty = tuples.end(tuples.begin(0));
    expect(tuples.head(empty).length == 0);
    expect(tuples.head(empty).hash == value.hashIndexed(empty[0..0]));
}

/// The one-step constructor copies its elements and closes the tuple, so
/// equal contents give equal hashes, which is what the dictionaries need.
fn tupleNCopiesAndHashes() void {
    var source = [3]repr.Value{
        harness.wrapInteger(10),
        wrap.fromTrue(),
        wrap.fromString(strings.cstring("s")),
    };

    const a = tuples.newFrom(&source);
    expect(tuples.head(a).length == 3);
    expect(harness.equals(a[0], source[0]));
    expect(harness.equals(a[1], source[1]));
    expect(harness.equals(a[2], source[2]));
    expect(tuples.head(a).sm_line == -1);

    // Copied, not aliased.
    source[0] = harness.wrapInteger(99);
    expect(harness.equals(a[0], harness.wrapInteger(10)));

    // Equal contents, equal hash; different contents, different tuple.
    var again = [3]repr.Value{
        harness.wrapInteger(10),
        wrap.fromTrue(),
        wrap.fromString(strings.cstring("s")),
    };
    const b = tuples.newFrom(&again);
    expect(b != a);
    expect(tuples.head(b).hash == tuples.head(a).hash);
    expect(harness.equals(wrap.fromTuple(a), wrap.fromTuple(b)));

    again[0] = harness.wrapInteger(11);
    const different = tuples.newFrom(&again);
    expect(!harness.equals(wrap.fromTuple(a), wrap.fromTuple(different)));

    // Zero elements needs no source at all.
    const none = tuples.newFrom(&.{});
    expect(tuples.head(none).length == 0);
}

/// The standard library reaches all of this through the core environment, so
/// the Zig entry points above have to agree with what Janet sees.
fn fromJanet() void {
    var out: repr.Value = undefined;
    const env = harness.coreEnv();
    const source =
        \\(let [s (string "ab" "cd")
        \\      y (symbol "sy" "mb")
        \\      g1 (gensym)
        \\      g2 (gensym)
        \\      t (tuple 1 2 3)]
        \\  [s (length s) (= y (symbol "symb")) (not= g1 g2)
        \\   (= t '(1 2 3)) (= (hash '(1 2 3)) (hash t)) (tuple/slice t 1)])
    ;
    expect(core_env.dostring(env, source, "string-symbol-test", &out) == 0);
    const r = harness.elems(out);
    expect(harness.stringValueIs(r[0], "abcd"));
    expect(harness.integerIs(r[1], 4));
    expect(repr.truthy(r[2]));
    expect(repr.truthy(r[3]));
    expect(repr.truthy(r[4]));
    expect(repr.truthy(r[5]));
    expect(harness.elems(r[6]).len == 2);
}

/// Every core cfunction is registered with the file and line it was declared
/// on, and that pair is what a stack trace prints for a frame that is not a
/// Janet function. The location comes from `@src()` at the registration table
/// row rather than from the line of the definition, and what this asserts is
/// that there is one at all.
///
/// It is here rather than in a Janet suite because nothing in Janet reads the
/// registry directly: the `:source-map` of a binding comes from the image, so
/// a runtime that recorded nothing would still print `(doc)` correctly and
/// only stack traces would go blank.
fn theRegistryRecordsALocation() void {
    const names = [_][*:0]const u8{
        "tuple/join",  "string/split",  "buffer/blit", "array/concat",
        "table/clone", "struct/rawget", "math/log2",   "int/to-number",
    };
    for (names) |name| {
        const binding = registry.resolveCore(name);
        // A build without integer types has no int/ functions to look up.
        if (harness.isType(binding, repr.Tag.nil)) continue;
        expect(harness.isType(binding, repr.Tag.cfunction));
        const entry = registry.registryGet(wrap.toCfunction(binding));
        expect(entry != null);
        expect(entry.?.name != null);
        expect(std.mem.eql(u8, std.mem.span(entry.?.name.?), std.mem.span(name)));
        expect(entry.?.source_file != null);
        expect(entry.?.source_line > 0);
    }
}

// ==========================================================================
// Entry
// ==========================================================================

pub fn run() void {
    harness.init();

    stringBeginAndEnd();
    constructorsWriteTheTerminator();
    stringCopiesAndHashes();
    stringCompareIsThreeValued();
    stringEquality();

    symbolInterns();
    aKeywordIsASymbolOfTheOtherKind();
    symbolDeinitLeavesATombstone();
    lookupReclaimsATombstone();
    cacheResizesAndKeepsIdentity();
    tombstonesForceARehash();
    cacheGrowsPastHalf();
    generatedNamesComeFromTheInitialCounter();
    gensymAdvancesTheOdometer();
    gensymCarriesBetweenPositions();
    collectedSymbolLeavesTheCache();

    tupleBeginAndEnd();
    tupleNCopiesAndHashes();

    repeatStopsAtTheLength();
    fromJanet();

    theRegistryRecordsALocation();

    vm_lifecycle.deinit();
}
