//! `JanetString`: immutable interned-by-value bytes, their comparison, and the
//! `string/*` surface — along with `symbol/slice` and `keyword/slice`, which
//! are byte operations that happen to return an interned value.
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
//! **This file owns the string head accessors.** `head` and `data` are `pub`
//! so that `symbols.zig` reaches them rather than keeping a copy: a symbol is
//! a string with an entry in `janet_vm.cache`, and two copies of a pointer
//! offset can disagree in a way a caller can see. That is the line batch 1
//! drew — a leaf may duplicate a private predicate, never a definition
//! anything else can observe — and it is `phase_12.md` item 4a's population,
//! which this does not otherwise touch.
//!
//! ## Jump transparency
//!
//! Nothing here calls `janet_panic`, but `janet_gcalloc` can trigger a
//! collection and a finalizer may raise, so a signal can still unwind through
//! these frames. There is no `defer` in this file and `build.zig` checks that
//! there is not.

const std = @import("std");
const corefn = @import("corefn");
const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");
const raise = @import("raise");
const registry = @import("../registry.zig");
const pp_format = @import("../pp/format.zig");
const gc_alloc = @import("../gc.zig");
const utils = @import("../utils.zig");
const wrap = @import("helpers/wrap.zig");
const args_core = @import("../args.zig");
const fatal = @import("../fatal.zig");
const symbols = @import("symbols.zig");
const buffers = @import("buffers.zig");
const arrays = @import("arrays.zig");
const tuples = @import("tuples.zig");
const value = @import("../value.zig");

/// From `src/core/util.c`, declared here rather than imported: `util.h` is
/// never in a translation.
/// `symbols.zig` and `tuples.zig` carry the declarations they need for the
/// same reason; `utils.zig` defines all of them without `pub`.
extern fn safe_memcpy(dest: ?*anyopaque, src: ?*const anyopaque, len: usize) callconv(.c) void;

/// C's conversion of a signed count to `size_t`: sign-extend to the pointer
/// width, then reinterpret. Every length here reaches an allocation size, and a
/// negative length becomes a request C cannot satisfy rather than a trap one
/// statement earlier. Same helper, and same reason, as `buffers.zig`.
inline fn asSize(n: i32) usize {
    return @bitCast(@as(isize, n));
}

pub inline fn lengthOf(s: [*]const u8) i32 {
    return types.stringHead(s).length;
}

pub inline fn hashOf(s: [*]const u8) i32 {
    return types.stringHead(s).hash;
}

/// An interned string's bytes, counted from its head. The NUL past the end is
/// real and is not included, which is what `janet_string_length` has always
/// meant.
pub inline fn bytesOf(s: [*]const u8) []const u8 {
    return s[0..@intCast(types.stringHead(s).length)];
}

/// `janet_wrap_integer`, written out because the function it would call does
/// not exist in every configuration: `janet.h` declares it beside its macro,
/// and `wrap.c` defines the declaration only for the NaN-boxed layouts. Same
/// reasoning, and the same three lines, as `tuples.zig`, `value_access.zig`
/// and `pp_pretty.zig`.
inline fn wrapInteger(x: i32) types.Janet {
    return wrap.fromNumber(@floatFromInt(x));
}

// ------------------------------------------------------------------ string

/// Allocate a string of `length` bytes and terminate it. The bytes themselves
/// are uninitialised and so is the hash: the caller fills the first and
/// `janet_string_end` computes the second.
pub fn begin(length: i32) [*]u8 {
    const hd: *types.JanetStringHead = @ptrCast(@alignCast(gc_alloc.gcalloc(
        constants.JANET_MEMORY_STRING,
        types.string_payload +% asSize(length) +% 1,
    )));
    hd.length = length;
    const payload = types.stringData(hd);
    payload[@intCast(length)] = 0;
    return payload;
}

/// Close a string built by hand. This is the only place a string's hash is
/// written outside `janet_string`, and until it runs the head holds whatever
/// the allocator left there.
pub fn end(str: [*]u8) callconv(.c) [*:0]const u8 {
    types.stringHead(str).hash = value.hashBytes(str[0..@intCast(lengthOf(str))]);
    return @ptrCast(str);
}

/// Allocate a string and fill it from `buf` in one step.
pub fn new(buf: []const u8) [*:0]const u8 {
    const len: i32 = @intCast(buf.len);
    const hd: *types.JanetStringHead = @ptrCast(@alignCast(gc_alloc.gcalloc(
        constants.JANET_MEMORY_STRING,
        types.string_payload +% buf.len +% 1,
    )));
    hd.length = len;
    hd.hash = value.hashBytes(buf);
    const payload = types.stringData(hd);
    safe_memcpy(@ptrCast(payload), @ptrCast(buf.ptr), buf.len);
    payload[buf.len] = 0;
    return @ptrCast(payload);
}

/// Order two strings. Shorter is less when one is a prefix of the other, and
/// the `memcmp` result is normalised to -1, 0 or 1 rather than passed through:
/// `memcmp` may return any value of the right sign, and Janet's comparison
/// contract is the three-valued one.
pub fn compare(lhs: [*]const u8, rhs: [*]const u8) c_int {
    const xlen = lengthOf(lhs);
    const ylen = lengthOf(rhs);
    const len = if (xlen > ylen) ylen else xlen;
    const res = c.memcmp(lhs, rhs, @intCast(len));
    if (res != 0) return if (res > 0) 1 else -1;
    if (xlen == ylen) return 0;
    return if (xlen < ylen) -1 else 1;
}

/// Compare an interned string against a length and hash the caller already has,
/// which is what makes the symbol cache cheap: an unequal hash rejects without
/// touching the bytes.
pub fn equalconst(lhs: [*]const u8, rhs: []const u8, rhash: i32) c_int {
    const lhash = hashOf(lhs);
    const llen = lengthOf(lhs);
    if (lhash != rhash or llen != @as(i32, @intCast(rhs.len))) return 0;
    if (lhs == rhs.ptr) return 1;
    return @intFromBool(c.memcmp(lhs, rhs.ptr, rhs.len) == 0);
}

pub fn equal(lhs: [*]const u8, rhs: [*]const u8) c_int {
    return equalconst(lhs, bytesOf(rhs), hashOf(rhs));
}

pub fn cstring(str: [*:0]const u8) [*:0]const u8 {
    return new(str[0..c.strlen(str)]);
}

// ==========================================================================
// string/*, keyword/slice and symbol/slice, the cfunction surface.
// ==========================================================================

/// `src/core/util.h`, provided by `pp_format.zig` or `pp.c` according to
/// `-Dpp`.
extern fn janet_buffer_format(
    b: *types.JanetBuffer,
    strfrmt: [*]const u8,
    argstart: i32,
    argc: i32,
    argv: [*]types.Janet,
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
    lookup: [*]i32,
    text: []const u8,
    pat: []const u8,

    fn init(text: []const u8, pat: []const u8) raise.Raising(KmpState) {
        if (pat.len == 0) return raise.panic("expected non-empty pattern");
        const lookup: [*]i32 = @ptrCast(@alignCast(utils.calloc(pat.len, @sizeOf(i32)) orelse
            fatal.outOfMemory()));
        const s: KmpState = .{
            .i = 0,
            .j = 0,
            .text = text,
            .pat = pat,
            .lookup = lookup,
        };
        var i: usize = 1;
        var j: i32 = 0;
        while (i < pat.len) : (i += 1) {
            while (j != 0 and pat[@intCast(j)] != pat[i]) j = lookup[@intCast(j - 1)];
            if (pat[@intCast(j)] == pat[i]) j += 1;
            lookup[i] = j;
        }
        return s;
    }

    fn deinit(s: *KmpState) void {
        utils.free(@ptrCast(s.lookup));
    }

    fn seti(s: *KmpState, i: i32) void {
        s.i = i;
        s.j = 0;
    }

    fn next(s: *KmpState) i32 {
        var i = s.i;
        var j = s.j;
        while (i < @as(i32, @intCast(s.text.len))) {
            if (s.text[@intCast(i)] == s.pat[@intCast(j)]) {
                if (j == @as(i32, @intCast(s.pat.len)) - 1) {
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

fn findsetup(argv: []types.Janet, extra: i32) raise.Raising(KmpState) {
    try args_core.arity(argv, 2, 3 + extra);
    const pat = try args_core.getBytes(argv, 0);
    const text = try args_core.getBytes(argv, 1);
    var start: i32 = 0;
    if (@as(i32, @intCast(argv.len)) >= 3) {
        start = try args_core.getInteger(argv, 2);
        if (start < 0) return raise.panic("expected non-negative start index");
    }
    var s = try KmpState.init(args_core.viewBytes(text), args_core.viewBytes(pat));
    s.i = start;
    return s;
}

fn cfunStringSlice(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    const view = try args_core.getBytes(argv, 0);
    const range = try args_core.getSlice(argv);
    return wrap.fromString(new(view.bytes.?[@intCast(range.start)..@intCast(range.end)]));
}

fn cfunSymbolSlice(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    const view = try args_core.getBytes(argv, 0);
    const range = try args_core.getSlice(argv);
    return wrap.fromSymbol(symbols.new(view.bytes.?[@intCast(range.start)..@intCast(range.end)]));
}

fn cfunKeywordSlice(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    const view = try args_core.getBytes(argv, 0);
    const range = try args_core.getSlice(argv);
    // `janet.h` spells `janet_keyword` as a #define onto `janet_symbol`: a
    // keyword and a symbol are the same interned bytes under a different tag.
    return wrap.fromKeyword(symbols.new(view.bytes.?[@intCast(range.start)..@intCast(range.end)]));
}

fn cfunStringRepeat(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 2);
    const view = try args_core.getBytes(argv, 0);
    const rep = try args_core.getInteger(argv, 1);
    if (rep < 0) return raise.panic("expected non-negative number of repetitions");
    if (rep == 0) return value.fromBytes("", .string);
    const mulres = @as(i64, rep) * view.len;
    if (mulres > std.math.maxInt(i32)) return raise.panic("result string is too long");
    const newbuf = begin(@intCast(mulres));
    var offset: usize = 0;
    const total: usize = @intCast(mulres);
    while (offset < total) : (offset += asSize(view.len)) {
        safe_memcpy(@ptrCast(newbuf + offset), @ptrCast(view.bytes), asSize(view.len));
    }
    return wrap.fromString(end(newbuf));
}

fn cfunStringBytes(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 1);
    const view = try args_core.getBytes(argv, 0);
    const tup = tuples.begin(view.len);
    var i: i32 = 0;
    while (i < view.len) : (i += 1) tup[@intCast(i)] = wrapInteger(view.bytes.?[@intCast(i)]);
    return wrap.fromTuple(tuples.end(tup));
}

fn cfunStringFrombytes(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    const buf = begin(@as(i32, @intCast(argv.len)));
    var i: i32 = 0;
    while (i < @as(i32, @intCast(argv.len))) : (i += 1) {
        buf[@intCast(i)] = @truncate(@as(u32, @bitCast(try args_core.getInteger(argv, i))));
    }
    return wrap.fromString(end(buf));
}

/// ASCII only, as the docstring says: the two case functions test the byte
/// ranges directly rather than calling `tolower`, so a locale cannot change
/// what they do.
fn mapCase(comptime lo: u8, comptime hi: u8, comptime delta: i8, argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 1);
    const view = try args_core.getBytes(argv, 0);
    const buf = begin(view.len);
    var i: i32 = 0;
    while (i < view.len) : (i += 1) {
        const byte = view.bytes.?[@intCast(i)];
        buf[@intCast(i)] = if (byte >= lo and byte <= hi)
            @intCast(@as(i16, byte) + delta)
        else
            byte;
    }
    return wrap.fromString(end(buf));
}

fn cfunStringAsciilower(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    return try mapCase(65, 90, 32, argv);
}

fn cfunStringAsciiupper(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    return try mapCase(97, 122, -32, argv);
}

fn cfunStringReverse(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 1);
    const view = try args_core.getBytes(argv, 0);
    const buf = begin(view.len);
    var i: i32 = 0;
    while (i < view.len) : (i += 1) buf[@intCast(i)] = view.bytes.?[@intCast(view.len - 1 - i)];
    return wrap.fromString(end(buf));
}

fn cfunStringFind(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    var state = try findsetup(argv, 0);
    const result = state.next();
    state.deinit();
    return if (result < 0) wrap.fromNil() else wrapInteger(result);
}

fn cfunStringHasprefix(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 2);
    const prefix = try args_core.getBytes(argv, 0);
    const str = try args_core.getBytes(argv, 1);
    if (str.len < prefix.len) return wrap.fromFalse();
    const n = asSize(prefix.len);
    return wrap.fromBoolean(@intFromBool(std.mem.eql(u8, prefix.bytes.?[0..n], str.bytes.?[0..n])));
}

fn cfunStringHassuffix(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 2);
    const suffix = try args_core.getBytes(argv, 0);
    const str = try args_core.getBytes(argv, 1);
    if (str.len < suffix.len) return wrap.fromFalse();
    const n = asSize(suffix.len);
    const tail = str.bytes.? + asSize(str.len - suffix.len);
    return wrap.fromBoolean(@intFromBool(std.mem.eql(u8, suffix.bytes.?[0..n], tail[0..n])));
}

fn cfunStringFindall(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    var state = try findsetup(argv, 0);
    const array = arrays.new(0);
    while (true) {
        const result = state.next();
        if (result < 0) break;
        try arrays.push(array, wrapInteger(result));
    }
    state.deinit();
    return wrap.fromArray(array);
}

const ReplaceState = struct { kmp: KmpState, subst: types.Janet };

fn replacesetup(argv: []types.Janet) raise.Raising(ReplaceState) {
    try args_core.arity(argv, 3, 4);
    const pat = try args_core.getBytes(argv, 0);
    const subst = argv[1];
    const text = try args_core.getBytes(argv, 2);
    var start: i32 = 0;
    if (@as(i32, @intCast(argv.len)) == 4) {
        start = try args_core.getInteger(argv, 3);
        if (start < 0) return raise.panic("expected non-negative start index");
    }
    var s: ReplaceState = .{
        .kmp = try KmpState.init(args_core.viewBytes(text), args_core.viewBytes(pat)),
        .subst = subst,
    };
    s.kmp.i = start;
    return s;
}

fn cfunStringReplace(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    var s = try replacesetup(argv);
    const result = s.kmp.next();
    if (result < 0) {
        const text = s.kmp.text;
        s.kmp.deinit();
        return wrap.fromString(new(text));
    }
    const at: usize = @intCast(result);
    const subst = try registry.textSubstitution(
        &s.subst,
        s.kmp.text[at..][0..s.kmp.pat.len],
        null,
    );
    const buf = begin(@as(i32, @intCast(s.kmp.text.len - s.kmp.pat.len)) + subst.len);
    safe_memcpy(@ptrCast(buf), @ptrCast(s.kmp.text.ptr), at);
    safe_memcpy(@ptrCast(buf + at), @ptrCast(subst.bytes), asSize(subst.len));
    safe_memcpy(
        @ptrCast(buf + at + asSize(subst.len)),
        @ptrCast(s.kmp.text.ptr + at + s.kmp.pat.len),
        s.kmp.text.len - at - s.kmp.pat.len,
    );
    s.kmp.deinit();
    return wrap.fromString(end(buf));
}

fn cfunStringReplaceall(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    var s = try replacesetup(argv);
    var b: types.JanetBuffer = undefined;
    var lastindex: i32 = 0;
    _ = buffers.init(&b, @intCast(s.kmp.text.len));
    while (true) {
        const result = s.kmp.next();
        if (result < 0) break;
        const subst = try registry.textSubstitution(
            &s.subst,
            s.kmp.text[@intCast(result)..][0..s.kmp.pat.len],
            null,
        );
        try buffers.pushBytes(&b, s.kmp.text[@intCast(lastindex)..@intCast(result)]);
        try buffers.pushBytes(&b, args_core.viewBytes(subst));
        lastindex = result + @as(i32, @intCast(s.kmp.pat.len));
        s.kmp.seti(lastindex);
    }
    try buffers.pushBytes(&b, s.kmp.text[@intCast(lastindex)..]);
    const ret = new(b.data.?[0..@intCast(b.count)]);
    buffers.deinit(&b);
    s.kmp.deinit();
    return wrap.fromString(ret);
}

/// The limit arithmetic is the C original's, decrement and all: `limit`
/// defaults to -1, so `--limit` runs away from zero and never stops the loop,
/// and an explicit limit of 0 behaves like an explicit 1. Reproduced.
fn cfunStringSplit(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    var limit: i32 = -1;
    var lastindex: i32 = 0;
    if (@as(i32, @intCast(argv.len)) == 4) limit = try args_core.getInteger(argv, 3);
    var state = try findsetup(argv, 1);
    const array = arrays.new(0);
    while (true) {
        const result = state.next();
        if (result < 0) break;
        limit -%= 1;
        if (limit == 0) break;
        const slice = new(state.text[@intCast(lastindex)..@intCast(result)]);
        try arrays.push(array, wrap.fromString(slice));
        lastindex = result + @as(i32, @intCast(state.pat.len));
        state.seti(lastindex);
    }
    const slice = new(state.text[@intCast(lastindex)..]);
    try arrays.push(array, wrap.fromString(slice));
    state.deinit();
    return wrap.fromArray(array);
}

/// A 256-bit set held in eight words, indexed by the top three bits of the
/// byte and masked by the low five. The same arithmetic as the C original,
/// which is worth keeping because a `[256]bool` would be clearer and slower.
fn cfunStringCheckset(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    var bitset: [8]u32 = @splat(0);
    try args_core.fixarity(argv, 2);
    const set = try args_core.getBytes(argv, 0);
    const str = try args_core.getBytes(argv, 1);
    var i: i32 = 0;
    while (i < set.len) : (i += 1) {
        const byte = set.bytes.?[@intCast(i)];
        bitset[byte >> 5] |= @as(u32, 1) << @intCast(byte & 0x1F);
    }
    i = 0;
    while (i < str.len) : (i += 1) {
        const byte = str.bytes.?[@intCast(i)];
        if (bitset[byte >> 5] & (@as(u32, 1) << @intCast(byte & 0x1F)) == 0) {
            return wrap.fromFalse();
        }
    }
    return wrap.fromTrue();
}

fn cfunStringJoin(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    try args_core.arity(argv, 1, 2);
    const parts = try args_core.getIndexed(argv, 0);
    const joiner: types.JanetByteView = if (@as(i32, @intCast(argv.len)) == 2)
        try args_core.getBytes(argv, 1)
    else
        .{ .bytes = "", .len = 0 };

    // Two passes, and the first one is what rejects a bad part: nothing is
    // allocated until every item is known to be a byte sequence and the total
    // is known to fit.
    var i: i32 = 0;
    var finallen: i64 = 0;
    while (i < parts.len) : (i += 1) {
        var chunk: ?[*]const u8 = undefined;
        var chunklen: i32 = 0;
        if (args_core.bytesView(parts.items.?[@intCast(i)], &chunk, &chunklen) == 0) {
            return pp_format.panicf("item %d of parts is not a byte sequence, got %v", .{ i, parts.items.?[@intCast(i)] });
        }
        if (i != 0) finallen += joiner.len;
        finallen += chunklen;
        if (finallen > std.math.maxInt(i32)) return raise.panic("result string too long");
    }

    const buf = begin(@intCast(finallen));
    var out: usize = 0;
    i = 0;
    while (i < parts.len) : (i += 1) {
        var chunk: ?[*]const u8 = undefined;
        var chunklen: i32 = 0;
        if (i != 0) {
            safe_memcpy(@ptrCast(buf + out), @ptrCast(joiner.bytes), asSize(joiner.len));
            out += asSize(joiner.len);
        }
        _ = args_core.bytesView(parts.items.?[@intCast(i)], &chunk, &chunklen);
        safe_memcpy(@ptrCast(buf + out), @ptrCast(chunk), asSize(chunklen));
        out += asSize(chunklen);
    }
    return wrap.fromString(end(buf));
}

fn cfunStringFormat(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    try args_core.arity(argv, 1, -1);
    const buffer = buffers.new(0);
    const strfrmt = try args_core.getString(argv, 0);
    try pp_format.bufferFormat(buffer, @ptrCast(strfrmt), 0, argv);
    return wrap.fromString(new(buffer.*.data.?[0..@intCast(buffer.*.count)]));
}

const default_trim_set = " \t\r\n\x0b\x0c";

fn trimArgs(argv: []types.Janet, str: *types.JanetByteView, set: *types.JanetByteView) raise.Raising(void) {
    try args_core.arity(argv, 1, 2);
    str.* = try args_core.getBytes(argv, 0);
    if (@as(i32, @intCast(argv.len)) >= 2) {
        set.* = try args_core.getBytes(argv, 1);
    } else {
        set.* = .{ .bytes = default_trim_set, .len = default_trim_set.len };
    }
}

fn inSet(set: types.JanetByteView, x: u8) bool {
    var j: i32 = 0;
    while (j < set.len) : (j += 1) if (set.bytes.?[@intCast(j)] == x) return true;
    return false;
}

fn leftEdge(str: types.JanetByteView, set: types.JanetByteView) i32 {
    var i: i32 = 0;
    while (i < str.len) : (i += 1) if (!inSet(set, str.bytes.?[@intCast(i)])) return i;
    return str.len;
}

fn rightEdge(str: types.JanetByteView, set: types.JanetByteView) i32 {
    var i: i32 = str.len - 1;
    while (i >= 0) : (i -= 1) if (!inSet(set, str.bytes.?[@intCast(i)])) return i + 1;
    return 0;
}

fn cfunStringTrim(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    var str: types.JanetByteView = undefined;
    var set: types.JanetByteView = undefined;
    try trimArgs(argv, &str, &set);
    const left = leftEdge(str, set);
    const right = rightEdge(str, set);
    if (right < left) return wrap.fromString(new(""));
    return wrap.fromString(new(str.bytes.?[@intCast(left)..@intCast(right)]));
}

fn cfunStringTriml(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    var str: types.JanetByteView = undefined;
    var set: types.JanetByteView = undefined;
    try trimArgs(argv, &str, &set);
    const left = leftEdge(str, set);
    return wrap.fromString(new(str.bytes.?[@intCast(left)..@intCast(str.len)]));
}

fn cfunStringTrimr(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    var str: types.JanetByteView = undefined;
    var set: types.JanetByteView = undefined;
    try trimArgs(argv, &str, &set);
    return wrap.fromString(new(str.bytes.?[0..@intCast(rightEdge(str, set))]));
}

pub fn lib(env: *types.JanetTable) void {
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
