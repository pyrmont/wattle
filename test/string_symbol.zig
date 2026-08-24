//! Behavioral contract for the immutable head-allocated sequences: strings,
//! symbols and the symbol cache, and tuples.
//!
//! All three of these types are a header and a payload in one `janet_gcalloc`,
//! and the value Janet passes around is the address of the payload.
//!
//! The observable surface splits three ways.
//!
//! The fields are directly checkable: a string's length and hash, a tuple's
//! length, hash and source-map position, and the memory type in the GC header
//! that decides which of `janet_deinit_block`'s cases will eventually free it.
//!
//! The symbol cache is checkable through `janet_vm.cache_count` and
//! `janet_vm.cache_deleted`, and through pointer identity: interning means two
//! calls with the same name return the same address, and that is a stronger
//! statement than equality. It is also the property that makes symbol
//! comparison a pointer comparison everywhere else in the runtime, so it is
//! the one worth asserting hardest.
//!
//! Hashing is checkable only for consistency, not for value.
//! `janet_string_calchash` is a different subsystem and changes under `-Dprf`,
//! so nothing here asserts a particular hash. What it does assert is that the
//! hash a constructor stores is the one that function returns, and that equal
//! contents hash equally.
//!
//! ## Where the head-layout assertion went
//!
//! The C original opened by pinning `sizeof(JanetStringHead) ==
//! offsetof(JanetStringHead, data)` for the string and tuple heads, and then
//! checked the recovery arithmetic in both directions. Neither survives a
//! translation: `@cImport` drops a flexible array member, so `@offsetOf` does
//! not compile and `c.janet_string_head` recovers the header with `@sizeOf` —
//! which makes both comparisons `@sizeOf` against itself.
//!
//! Phase 11 Part 8 already built both replacements when the collector's
//! contracts hit the same wall. `test/abi.c` carries the five static
//! assertions unchanged, because the claim is about `janet.h` and that file is
//! C; `test/gc_mark.zig`'s `theHeadOffsets` derives each offset from the
//! address the allocator recorded and compares it against `@sizeOf`, which is
//! the runtime claim. Both cover the string and tuple heads this file used to.
//!
//! ## Two things deliberately not covered, unchanged from the C original
//!
//! `janet_string_begin` and `janet_tuple_begin` leave the hash uninitialised,
//! and there is no way to assert an indeterminate value; the cases below read
//! it only after the matching `end`. And `janet_symcache_findmem` ends the
//! process when the table is full, which `FOUND.md` records as reachable only
//! at a capacity of two — a state that needs `cache_count` to reach zero and
//! so cannot be arranged while a core environment is loaded.

const std = @import("std");
const abi = @import("abi");
const c = abi.c;
const harness = @import("harness.zig");

const heap = harness.heap;
const internal = harness.internal;

// --------------------------------------------------------------- helpers

fn stringHead(s: [*c]const u8) *c.JanetStringHead {
    return c.janet_string_head(s);
}

fn tupleHead(t: [*c]const c.Janet) *c.JanetTupleHead {
    return c.janet_tuple_head(t);
}

fn stringLength(s: [*c]const u8) i32 {
    return stringHead(s).length;
}

fn stringHash(s: [*c]const u8) i32 {
    return stringHead(s).hash;
}

fn bytesOf(s: [*c]const u8) []const u8 {
    return s[0..@intCast(stringLength(s))];
}

fn calchash(bytes: []const u8) i32 {
    return internal.janet_string_calchash(bytes.ptr, @intCast(bytes.len));
}

/// Is `symbol` in the cache? Walks the table rather than calling the finder,
/// so that a case can distinguish "interned" from "would be found by the same
/// lookup the implementation uses".
fn inCache(symbol: [*c]const u8) bool {
    var index: u32 = 0;
    while (index < c.janet_vm.cache_capacity) : (index += 1) {
        if (c.janet_vm.cache[index] == symbol) return true;
    }
    return false;
}

// ---------------------------------------------------------------- string

/// Fill the allocator's free list with blocks of `size` whose bytes are all
/// 0xFF, and report whether they come back that way.
///
/// Every assertion that a constructor wrote a terminator is vacuous on a block
/// that arrived zeroed, and whether one does is a property of the C library
/// rather than of Janet: macOS zeroes small allocations and leaves large ones
/// alone, glibc leaves both. So the terminator case probes first and asserts
/// only where the answer makes the assertion mean something.
fn dirtyFreeList(size: usize) bool {
    var junk: [8]?*anyopaque = undefined;
    for (&junk) |*slot| {
        slot.* = c.janet_malloc(size);
        std.debug.assert(slot.* != null);
        @memset(@as([*]u8, @ptrCast(slot.*))[0..size], 0xFF);
    }
    for (junk) |slot| c.janet_free(slot);

    const check: [*]u8 = @ptrCast(c.janet_malloc(size).?);
    const dirty = check[size - 1] != 0;
    @memset(check[0..size], 0xFF);
    c.janet_free(check);
    return dirty;
}

/// Both constructors write a zero one byte past the length, so that a Janet
/// string can be handed to a C function that expects one. Asserted on a block
/// large enough that this allocator does not zero it -- see above.
fn constructorsWriteTheTerminator() void {
    const n: i32 = 8192;
    const block = @sizeOf(c.JanetStringHead) + @as(usize, n) + 1;
    if (!dirtyFreeList(block)) return;

    const begun = c.janet_string_begin(n);
    std.debug.assert(begun[@intCast(n)] == 0);

    const source: [*]u8 = @ptrCast(c.janet_malloc(@intCast(n)).?);
    @memset(source[0..@intCast(n)], 'x');
    _ = dirtyFreeList(block);
    const copied = c.janet_string(source, n);
    std.debug.assert(copied[@intCast(n)] == 0);
    std.debug.assert(std.mem.eql(u8, copied[0..@intCast(n)], source[0..@intCast(n)]));
    c.janet_free(source);
}

/// A string built in two steps: the length is set by `begin`, the terminator
/// is written by `begin`, and the hash is written by `end` and nowhere else.
fn stringBeginAndEnd() void {
    const s = c.janet_string_begin(5);
    std.debug.assert(stringLength(s) == 5);
    std.debug.assert(s[5] == 0);
    std.debug.assert(heap.memoryType(stringHead(s)) == c.JANET_MEMORY_STRING);
    std.debug.assert(heap.onList(c.janet_vm.blocks, stringHead(s)));

    @memcpy(s[0..5], "hello");
    const done = c.janet_string_end(s);
    std.debug.assert(done == s);
    std.debug.assert(stringLength(done) == 5);
    std.debug.assert(stringHash(done) == calchash("hello"));

    // A zero-length string is legal, terminated, and has the empty hash.
    const e = c.janet_string_begin(0);
    std.debug.assert(stringLength(e) == 0);
    std.debug.assert(e[0] == 0);
    std.debug.assert(stringHash(c.janet_string_end(e)) == calchash(""));
}

/// The one-step constructor copies and hashes immediately.
fn stringCopiesAndHashes() void {
    const s = c.janet_string("world", 5);
    std.debug.assert(stringLength(s) == 5);
    std.debug.assert(std.mem.eql(u8, bytesOf(s), "world"));
    std.debug.assert(s[5] == 0);
    std.debug.assert(stringHash(s) == calchash("world"));

    // The source is copied, so a caller's buffer may change afterwards.
    var source = [3]u8{ 'a', 'b', 'c' };
    const copy = c.janet_string(&source, 3);
    source[0] = 'z';
    std.debug.assert(std.mem.eql(u8, bytesOf(copy), "abc"));

    // An interior zero is content, not a terminator: the length comes from the
    // head and the bytes past the zero are part of the string.
    const nul = c.janet_string("a\x00b", 3);
    std.debug.assert(stringLength(nul) == 3);
    std.debug.assert(std.mem.eql(u8, bytesOf(nul), "a\x00b"));
    std.debug.assert(nul[3] == 0);

    // `janet_cstring` takes its length from the bytes instead.
    const cs = c.janet_cstring("a\x00b");
    std.debug.assert(stringLength(cs) == 1);
    std.debug.assert(cs[0] == 'a' and cs[1] == 0);
}

/// Ordering is three-valued and by prefix. The normalisation matters:
/// `memcmp` may return any value of the right sign, and callers compare
/// against 1 and -1.
fn stringCompareIsThreeValued() void {
    const a = c.janet_cstring("abc");
    const b = c.janet_cstring("abd");
    const prefix = c.janet_cstring("ab");
    const same = c.janet_cstring("abc");

    std.debug.assert(c.janet_string_compare(a, b) == -1);
    std.debug.assert(c.janet_string_compare(b, a) == 1);
    std.debug.assert(c.janet_string_compare(a, same) == 0);
    std.debug.assert(c.janet_string_compare(a, a) == 0);

    // A prefix is less than what extends it, whichever side it is on.
    std.debug.assert(c.janet_string_compare(prefix, a) == -1);
    std.debug.assert(c.janet_string_compare(a, prefix) == 1);

    // A large byte difference still normalises to exactly one.
    const low = c.janet_string("\x01", 1);
    const high = c.janet_string("\xFF", 1);
    std.debug.assert(c.janet_string_compare(low, high) == -1);
    std.debug.assert(c.janet_string_compare(high, low) == 1);

    // The empty string is least, and equal to itself.
    const empty = c.janet_cstring("");
    std.debug.assert(c.janet_string_compare(empty, a) == -1);
    std.debug.assert(c.janet_string_compare(empty, empty) == 0);
}

/// Equality rejects on the hash or the length before it touches the bytes, and
/// short-circuits on identity. Both are what make the symbol cache cheap.
fn stringEquality() void {
    const a = c.janet_cstring("abc");
    const b = c.janet_cstring("abc");
    const d = c.janet_cstring("abd");

    std.debug.assert(c.janet_string_equal(a, b) != 0);
    std.debug.assert(c.janet_string_equal(a, a) != 0);
    std.debug.assert(c.janet_string_equal(a, d) == 0);

    // Same bytes, right hash and length: equal.
    std.debug.assert(c.janet_string_equalconst(a, "abc", 3, calchash("abc")) != 0);

    // A wrong hash rejects even when the bytes are identical -- the hash is
    // trusted, not recomputed, which is the whole point of this entry point.
    std.debug.assert(c.janet_string_equalconst(a, "abc", 3, calchash("zzz")) == 0);

    // The length and byte checks are harder to reach honestly, because the
    // hash mixes the length in and so rejects almost every mismatched argument
    // before either runs. They are reachable through the public API, though,
    // which is what these two do: pass the hash `lhs` actually has, and vary
    // only the thing being tested. Without this, the length comparison and the
    // `memcmp` are both dead code that no case distinguishes.
    std.debug.assert(c.janet_string_equalconst(a, "abc", 2, stringHash(a)) == 0);
    std.debug.assert(c.janet_string_equalconst(a, "abd", 3, stringHash(a)) == 0);

    // And the same arguments with nothing varied still match, so the two above
    // are rejections rather than an entry point that rejects everything.
    std.debug.assert(c.janet_string_equalconst(a, "abc", 3, stringHash(a)) != 0);

    // Interior zeros are compared, not stopped at.
    const n1 = c.janet_string("a\x00b", 3);
    const n2 = c.janet_string("a\x00c", 3);
    std.debug.assert(c.janet_string_equal(n1, n2) == 0);
}

// ---------------------------------------------------------------- symbol

/// Interning is pointer identity, which is stronger than equality and is what
/// the rest of the runtime relies on.
fn symbolInterns() void {
    const before = c.janet_vm.cache_count;

    const s1 = c.janet_csymbol("interned-test-symbol");
    std.debug.assert(c.janet_vm.cache_count == before + 1);
    std.debug.assert(heap.memoryType(stringHead(s1)) == c.JANET_MEMORY_SYMBOL);
    std.debug.assert(heap.onList(c.janet_vm.blocks, stringHead(s1)));
    std.debug.assert(inCache(s1));

    // The same name returns the same address and allocates nothing.
    const s2 = c.janet_csymbol("interned-test-symbol");
    std.debug.assert(s2 == s1);
    std.debug.assert(c.janet_vm.cache_count == before + 1);

    // A different name is a different address.
    const s3 = c.janet_csymbol("interned-test-symbol-2");
    std.debug.assert(s3 != s1);
    std.debug.assert(c.janet_vm.cache_count == before + 2);

    // Interning is by length as well as by bytes, so an interior zero
    // distinguishes two symbols a C string could not tell apart.
    const z1 = c.janet_symbol("zz\x00a", 4);
    const z2 = c.janet_symbol("zz\x00b", 4);
    std.debug.assert(z1 != z2);
    std.debug.assert(c.janet_symbol("zz\x00a", 4) == z1);

    // A symbol and a string with the same bytes are different objects with
    // different memory types, and still compare equal as byte strings.
    const str = c.janet_cstring("interned-test-symbol");
    std.debug.assert(str != s1);
    std.debug.assert(heap.memoryType(stringHead(str)) == c.JANET_MEMORY_STRING);
    std.debug.assert(c.janet_string_equal(str, s1) != 0);
}

/// Removing a symbol leaves a tombstone: the count falls, the deleted count
/// rises, and the name is available again -- at a new address.
fn symbolDeinitLeavesATombstone() void {
    var count = c.janet_vm.cache_count;
    var deleted = c.janet_vm.cache_deleted;

    const s = c.janet_csymbol("tombstone-test-symbol");
    std.debug.assert(c.janet_vm.cache_count == count + 1);
    std.debug.assert(inCache(s));

    internal.janet_symbol_deinit(s);
    std.debug.assert(c.janet_vm.cache_count == count);
    std.debug.assert(c.janet_vm.cache_deleted == deleted + 1);
    std.debug.assert(!inCache(s));

    // The name interns again, to a different block.
    const again = c.janet_csymbol("tombstone-test-symbol");
    std.debug.assert(again != s);
    std.debug.assert(c.janet_vm.cache_count == count + 1);
    std.debug.assert(inCache(again));

    // Removing something that was never there changes nothing.
    count = c.janet_vm.cache_count;
    deleted = c.janet_vm.cache_deleted;
    const loose = c.janet_string("never-interned", 14);
    internal.janet_symbol_deinit(loose);
    std.debug.assert(c.janet_vm.cache_count == count);
    std.debug.assert(c.janet_vm.cache_deleted == deleted);
}

/// Where in the table is `symbol`, and where would a name ideally go? Together
/// these make the probe sequence observable, which is the only way to see what
/// a lookup does to the table on its way past a tombstone.
fn cacheIndexOf(symbol: [*c]const u8) ?u32 {
    var index: u32 = 0;
    while (index < c.janet_vm.cache_capacity) : (index += 1) {
        if (c.janet_vm.cache[index] == symbol) return index;
    }
    return null;
}

fn idealIndex(name: []const u8) u32 {
    const hash: u32 = @bitCast(calchash(name));
    return hash & (c.janet_vm.cache_capacity - 1);
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
    std.debug.assert(found);

    const capacity = c.janet_vm.cache_capacity;
    const a = c.janet_csymbol(first.ptr);
    const b = c.janet_csymbol(second.ptr);
    c.janet_gcroot(c.janet_wrap_symbol(a));
    c.janet_gcroot(c.janet_wrap_symbol(b));
    std.debug.assert(c.janet_vm.cache_capacity == capacity);

    const pos_a = cacheIndexOf(a).?;
    const pos_b = cacheIndexOf(b).?;
    std.debug.assert(pos_a != pos_b);
    std.debug.assert(pos_a == idealIndex(first));

    // Delete the first, leaving a tombstone directly in the second's path.
    internal.janet_symbol_deinit(a);
    std.debug.assert(cacheIndexOf(a) == null);
    std.debug.assert(c.janet_vm.cache[pos_a] != null);

    // Looking the second one up moves it into that slot. Its address does not
    // change -- interning is still identity -- only its position does.
    std.debug.assert(c.janet_csymbol(second.ptr) == b);
    std.debug.assert(cacheIndexOf(b).? == pos_a);
    std.debug.assert(c.janet_vm.cache[pos_b] != null);
    std.debug.assert(c.janet_vm.cache[pos_b] != b);
    std.debug.assert(c.janet_vm.cache_capacity == capacity);

    _ = c.janet_gcunroot(c.janet_wrap_symbol(a));
    _ = c.janet_gcunroot(c.janet_wrap_symbol(b));
}

/// Growing past the load factor rehashes: the capacity rises, every tombstone
/// is dropped, and every live symbol is still found at its original address.
fn cacheResizesAndKeepsIdentity() void {
    var name: [40]u8 = undefined;
    var kept: [400][*c]const u8 = undefined;

    // Keep them alive across the resize by rooting them.
    for (&kept, 0..) |*slot, i| {
        const text = std.fmt.bufPrintZ(&name, "resize-probe-{d}", .{i}) catch unreachable;
        slot.* = c.janet_csymbol(text.ptr);
        c.janet_gcroot(c.janet_wrap_symbol(slot.*));
    }

    // Delete half, which raises the tombstone count without lowering capacity.
    var i: usize = 0;
    while (i < 400) : (i += 2) internal.janet_symbol_deinit(kept[i]);
    std.debug.assert(c.janet_vm.cache_deleted >= 200);

    // Force enough puts to cross the load factor and rehash.
    const capacity_before = c.janet_vm.cache_capacity;
    for (0..1200) |n| {
        const text = std.fmt.bufPrintZ(&name, "resize-filler-{d}", .{n}) catch unreachable;
        c.janet_gcroot(c.janet_wrap_symbol(c.janet_csymbol(text.ptr)));
    }
    std.debug.assert(c.janet_vm.cache_capacity > capacity_before);

    // Every survivor is still interned, at the address it always had.
    i = 1;
    while (i < 400) : (i += 2) {
        const text = std.fmt.bufPrintZ(&name, "resize-probe-{d}", .{i}) catch unreachable;
        std.debug.assert(c.janet_csymbol(text.ptr) == kept[i]);
        std.debug.assert(inCache(kept[i]));
    }

    // Every deleted one interns fresh rather than coming back.
    i = 0;
    while (i < 400) : (i += 2) {
        const text = std.fmt.bufPrintZ(&name, "resize-probe-{d}", .{i}) catch unreachable;
        std.debug.assert(c.janet_csymbol(text.ptr) != kept[i]);
    }

    for (kept) |symbol| _ = c.janet_gcunroot(c.janet_wrap_symbol(symbol));
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
        const s = c.janet_csymbol(text.ptr);

        if (c.janet_vm.cache_deleted > high_water) high_water = c.janet_vm.cache_deleted;
        // The invariant a live count alone would not maintain.
        std.debug.assert(c.janet_vm.cache_deleted < c.janet_vm.cache_capacity);

        if (c.janet_vm.cache_deleted == 0 and high_water > 8) {
            rehashed = true;
            internal.janet_symbol_deinit(s);
            break;
        }
        internal.janet_symbol_deinit(s);
    }
    std.debug.assert(rehashed);
}

/// The length of a generated name, which is the odometer minus its leading
/// underscore.
const gensym_length: i32 = @as(i32, @intCast(@typeInfo(@TypeOf(c.janet_vm.gensym_counter)).array.len)) - 1;

/// The leading underscore comes from `janet_symcache_init` and nothing else
/// ever writes it, so it is the one part of the counter's initial state that
/// survives to be observed. This case has to run before the one below, which
/// resets the counter itself and would make the same assertion vacuous.
fn generatedNamesComeFromTheInitialCounter() void {
    const g = c.janet_symbol_gen();
    c.janet_gcroot(c.janet_wrap_symbol(g));
    std.debug.assert(g[0] == '_');
    std.debug.assert(stringLength(g) == gensym_length);
    for (bytesOf(g)[1..]) |byte| {
        std.debug.assert(std.ascii.isAlphanumeric(byte));
    }
    _ = c.janet_gcunroot(c.janet_wrap_symbol(g));
}

/// Reset the odometer to the state `janet_symcache_init` leaves.
fn resetGensymCounter() void {
    @memset(&c.janet_vm.gensym_counter, '0');
    c.janet_vm.gensym_counter[0] = '_';
}

/// A generated symbol is interned like any other, and the counter advances
/// only when a name is already taken -- so the sequence is exactly the
/// odometer.
fn gensymAdvancesTheOdometer() void {
    // Start from the state `janet_symcache_init` leaves, so the sequence is
    // predictable however many gensyms ran before this. Collecting first drops
    // the ones earlier cases made, which would otherwise still be cached and
    // would make the counter skip past them.
    c.janet_collect();
    resetGensymCounter();

    const last: usize = @intCast(gensym_length - 1);
    var seen: [40][*c]const u8 = undefined;
    for (&seen) |*slot| {
        slot.* = c.janet_symbol_gen();
        c.janet_gcroot(c.janet_wrap_symbol(slot.*));
        std.debug.assert(stringLength(slot.*) == gensym_length);
        std.debug.assert(slot.*[0] == '_');
        std.debug.assert(heap.memoryType(stringHead(slot.*)) == c.JANET_MEMORY_SYMBOL);
        std.debug.assert(inCache(slot.*));
    }

    // All distinct, and each is the one the cache holds for its own name.
    for (seen, 0..) |symbol, i| {
        for (seen[i + 1 ..]) |other| std.debug.assert(symbol != other);
        std.debug.assert(c.janet_symbol(symbol, gensym_length) == symbol);
    }

    // The last character walks '0'..'9', then 'a'..'z', then 'A'..'Z' -- the
    // two carries at '9' and at 'z' are the whole of what `inc_gensym` does
    // beyond incrementing a byte. Only the final position moves over forty
    // names, so the rest stay where the reset above put them.
    //
    // The starting point is read from the first name rather than assumed to be
    // '0', because a name the cache already holds is skipped rather than
    // reused, and a symbol surviving from the boot process would shift the
    // whole run by one.
    const alphabet = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
    const start = std.mem.indexOfScalar(u8, alphabet, seen[0][last]).?;
    std.debug.assert(start + 40 <= alphabet.len);
    for (seen, 0..) |symbol, i| {
        std.debug.assert(symbol[last] == alphabet[start + i]);
        for (bytesOf(symbol)[1..last]) |byte| std.debug.assert(byte == '0');
    }

    for (seen) |symbol| _ = c.janet_gcunroot(c.janet_wrap_symbol(symbol));
}

/// The third carry, which the forty-name run above cannot reach: exhausting a
/// position wraps it to '0' and advances the one to its left. Reaching it by
/// counting would take sixty-three names, so the odometer is set to its last
/// value at the lowest position and stepped once.
fn gensymCarriesBetweenPositions() void {
    c.janet_collect();
    const last: usize = @intCast(gensym_length - 1);
    resetGensymCounter();
    c.janet_vm.gensym_counter[last] = 'Z';

    const before = c.janet_symbol_gen();
    c.janet_gcroot(c.janet_wrap_symbol(before));
    std.debug.assert(before[last] == 'Z');
    for (bytesOf(before)[1..last]) |byte| std.debug.assert(byte == '0');

    const carried = c.janet_symbol_gen();
    c.janet_gcroot(c.janet_wrap_symbol(carried));
    std.debug.assert(carried != before);
    std.debug.assert(carried[last] == '0');
    std.debug.assert(carried[last - 1] == '1');
    for (bytesOf(carried)[1 .. last - 1]) |byte| std.debug.assert(byte == '0');

    _ = c.janet_gcunroot(c.janet_wrap_symbol(before));
    _ = c.janet_gcunroot(c.janet_wrap_symbol(carried));
}

/// The collector's one external obligation: a symbol that dies leaves the
/// cache. `janet_deinit_block` calls `janet_symbol_deinit` from this
/// subsystem, so the round trip is entirely inside Zig.
fn collectedSymbolLeavesTheCache() void {
    c.janet_collect();
    const before = c.janet_vm.cache_count;

    var name: [40]u8 = undefined;
    for (0..50) |i| {
        const text = std.fmt.bufPrintZ(&name, "doomed-symbol-{d}", .{i}) catch unreachable;
        _ = c.janet_csymbol(text.ptr);
    }
    std.debug.assert(c.janet_vm.cache_count == before + 50);

    c.janet_collect();
    std.debug.assert(c.janet_vm.cache_count == before);

    // A rooted one survives the same collection and keeps its address.
    const kept = c.janet_csymbol("kept-symbol");
    c.janet_gcroot(c.janet_wrap_symbol(kept));
    c.janet_collect();
    std.debug.assert(c.janet_csymbol("kept-symbol") == kept);
    std.debug.assert(inCache(kept));
    _ = c.janet_gcunroot(c.janet_wrap_symbol(kept));
}

// ----------------------------------------------------------------- tuple

/// A tuple built in two steps. `begin` sets the length and marks the
/// source-map position absent with -1; `end` computes the hash over every
/// slot.
fn tupleBeginAndEnd() void {
    const t = c.janet_tuple_begin(3);
    std.debug.assert(tupleHead(t).length == 3);
    std.debug.assert(tupleHead(t).sm_line == -1);
    std.debug.assert(tupleHead(t).sm_column == -1);
    std.debug.assert(heap.memoryType(tupleHead(t)) == c.JANET_MEMORY_TUPLE);
    std.debug.assert(heap.onList(c.janet_vm.blocks, tupleHead(t)));

    t[0] = harness.wrapInteger(1);
    t[1] = c.janet_wrap_nil();
    t[2] = c.janet_wrap_keyword(c.janet_cstring("k"));
    const done = c.janet_tuple_end(t);
    std.debug.assert(done == t);
    std.debug.assert(tupleHead(done).hash == internal.janet_array_calchash(t, 3));

    // A zero-length tuple is legal and hashes as the empty sequence.
    const empty = c.janet_tuple_end(c.janet_tuple_begin(0));
    std.debug.assert(tupleHead(empty).length == 0);
    std.debug.assert(tupleHead(empty).hash == internal.janet_array_calchash(empty, 0));
}

/// The one-step constructor copies its elements and closes the tuple, so equal
/// contents give equal hashes -- which is what the dictionaries need.
fn tupleNCopiesAndHashes() void {
    var source = [3]c.Janet{
        harness.wrapInteger(10),
        c.janet_wrap_true(),
        c.janet_wrap_string(c.janet_cstring("s")),
    };

    const a = c.janet_tuple_n(&source, 3);
    std.debug.assert(tupleHead(a).length == 3);
    std.debug.assert(harness.equals(a[0], source[0]));
    std.debug.assert(harness.equals(a[1], source[1]));
    std.debug.assert(harness.equals(a[2], source[2]));
    std.debug.assert(tupleHead(a).sm_line == -1);

    // Copied, not aliased.
    source[0] = harness.wrapInteger(99);
    std.debug.assert(harness.equals(a[0], harness.wrapInteger(10)));

    // Equal contents, equal hash; different contents, different tuple.
    var again = [3]c.Janet{
        harness.wrapInteger(10),
        c.janet_wrap_true(),
        c.janet_wrap_string(c.janet_cstring("s")),
    };
    const b = c.janet_tuple_n(&again, 3);
    std.debug.assert(b != a);
    std.debug.assert(tupleHead(b).hash == tupleHead(a).hash);
    std.debug.assert(harness.equals(c.janet_wrap_tuple(a), c.janet_wrap_tuple(b)));

    again[0] = harness.wrapInteger(11);
    const different = c.janet_tuple_n(&again, 3);
    std.debug.assert(!harness.equals(c.janet_wrap_tuple(a), c.janet_wrap_tuple(different)));

    // Zero elements needs no source at all.
    const none = c.janet_tuple_n(null, 0);
    std.debug.assert(tupleHead(none).length == 0);
}

// ------------------------------------------------------ across the seam

/// The standard library reaches all of this through the core environment, so
/// the Zig entry points above have to agree with what Janet sees.
fn fromJanet() void {
    var out: c.Janet = undefined;
    const env = c.janet_core_env(null);
    const source =
        \\(let [s (string "ab" "cd")
        \\      y (symbol "sy" "mb")
        \\      g1 (gensym)
        \\      g2 (gensym)
        \\      t (tuple 1 2 3)]
        \\  [s (length s) (= y (symbol "symb")) (not= g1 g2)
        \\   (= t [1 2 3]) (= (hash [1 2 3]) (hash t)) (tuple/slice t 1)])
    ;
    std.debug.assert(c.janet_dostring(env, source, "string-symbol-test", &out) == 0);
    const r = c.janet_unwrap_tuple(out);
    std.debug.assert(harness.stringValueIs(r[0], "abcd"));
    std.debug.assert(harness.integerIs(r[1], 4));
    std.debug.assert(c.janet_truthy(r[2]) != 0);
    std.debug.assert(c.janet_truthy(r[3]) != 0);
    std.debug.assert(c.janet_truthy(r[4]) != 0);
    std.debug.assert(c.janet_truthy(r[5]) != 0);
    std.debug.assert(tupleHead(c.janet_unwrap_tuple(r[6])).length == 2);
}

// ------------------------------------------------------ the registration

/// Every core cfunction is registered with the file and line it was declared
/// on, and that pair is what a stack trace prints for a frame that is not a
/// Janet function. Phase 10 Part 6 moved the registration of every surface in
/// this subsystem to Zig, where the location comes from `@src()` at the table
/// row rather than from `__LINE__` at the definition; what has to hold either
/// way is that there *is* one.
///
/// This is here rather than in a Janet suite because nothing in Janet reads
/// the registry directly -- the `:source-map` a binding carries comes from the
/// image, so a runtime that recorded nothing would still answer `(doc)`
/// correctly and only stack traces would go blank. A mutation sweep found that
/// hole.
fn theRegistryRecordsALocation() void {
    const names = [_][*:0]const u8{
        "tuple/join",  "string/split",  "buffer/blit", "array/concat",
        "table/clone", "struct/rawget", "math/log2",   "int/to-number",
    };
    for (names) |name| {
        const binding = c.janet_resolve_core(name);
        // A build without integer types has no int/ functions to look up.
        if (harness.isType(binding, c.JANET_NIL)) continue;
        std.debug.assert(harness.isType(binding, c.JANET_CFUNCTION));
        const entry = internal.janet_registry_get(c.janet_unwrap_cfunction(binding));
        std.debug.assert(entry != null);
        std.debug.assert(entry.*.name != null);
        std.debug.assert(std.mem.eql(u8, std.mem.span(entry.*.name), std.mem.span(name)));
        std.debug.assert(entry.*.source_file != null);
        std.debug.assert(entry.*.source_line > 0);
    }
}

pub fn run() void {
    _ = c.janet_init();

    stringBeginAndEnd();
    constructorsWriteTheTerminator();
    stringCopiesAndHashes();
    stringCompareIsThreeValued();
    stringEquality();

    symbolInterns();
    symbolDeinitLeavesATombstone();
    lookupReclaimsATombstone();
    cacheResizesAndKeepsIdentity();
    tombstonesForceARehash();
    generatedNamesComeFromTheInitialCounter();
    gensymAdvancesTheOdometer();
    gensymCarriesBetweenPositions();
    collectedSymbolLeavesTheCache();

    tupleBeginAndEnd();
    tupleNCopiesAndHashes();

    fromJanet();

    theRegistryRecordsALocation();

    c.janet_deinit();
}
