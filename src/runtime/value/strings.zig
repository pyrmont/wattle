//! Immutable bytes, their comparison, and the `string/*` surface, along with
//! `symbol/slice` and `keyword/slice`, which are byte operations that happen
//! to return an interned value.
//!
//! `new` allocates a string and fills it in one step. `begin` and `end` are
//! the two-step form for a caller that writes the bytes itself: `begin` sizes
//! and terminates the block, and `end` computes the hash. `head` and `data`
//! move between the value and its header, and `compare`, `equal` and
//! `equalconst` are the comparisons.
//!
//! ## One allocation strategy, three files
//!
//! `strings.zig`, `symbols.zig` and `tuples.zig` are one allocation strategy,
//! and that is worth stating rather than assuming: a buffer or an array is a
//! fixed-size block pointing at a payload that can be reallocated, while a
//! string, a symbol or a tuple is a header and its payload in a single
//! `gc.gcallocWithPayload`, sized once and never resized. That is what makes
//! them immutable in the runtime's sense, and it is why the three share:
//!
//!  - A head recovered by pointer arithmetic. The value Janet passes around
//!    is the address of the payload, not of the block, so every operation
//!    subtracts the header size to get back to the header. `gc/sweep.zig`
//!    already does this for the free path; `head` below is the same shape,
//!    subtracting `@offsetOf(StringHead, "_data")`. `test/gc_mark.zig` checks
//!    the offset the allocator actually used.
//!  - A hash computed once, at the end of construction. `begin` leaves `hash`
//!    uninitialised and `end` fills it in, so a value observed between the two
//!    has an indeterminate hash and nothing may put it in a dictionary before
//!    `end` runs.
//!
//! There is no `keywords.zig` because a keyword is a symbol of the other kind,
//! which `symbols.zig` interns and marks in the head. This file owns the string head accessors: `head` and `data` are
//! `pub` so that `symbols.zig` reaches them rather than keeping a copy,
//! because two copies of a pointer offset can disagree where a caller sees it.
//!
//! ## The cfunction surface
//!
//! What raises is the argument layer and the buffer pushes, and the
//! `cfunString*` functions are where both are reached. Nothing above them
//! raises: `gcalloc` can trigger a collection, but an abstract type's `gc` and
//! `gcmark` are `callconv(.c) void` by contract, so a collection has no error
//! to deliver. `KmpState` is the one thing in this file that owns heap memory
//! across a call that can raise, and every user of it owes a `defer`.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const args_core = @import("../args.zig");
const arrays = @import("arrays.zig");
const buffers = @import("buffers.zig");
const c = @import("cabi");
const corefn = @import("../corefn.zig");
const fatal = @import("../fatal.zig");
const gc_alloc = @import("../gc.zig");
const pp_format = @import("../pp/format.zig");
const raise = @import("../../api/raise.zig");
const registry = @import("../registry.zig");
const repr = @import("repr");
const symbols = @import("symbols.zig");
const tables = @import("tables.zig");
const tuples = @import("tuples.zig");
const utils = @import("../utils.zig");
const value = @import("../value.zig");
const wrap = @import("helpers/wrap.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// What `string/trim` and its two halves treat as whitespace where the caller
/// names no set: space, tab, carriage return, newline, vertical tab and form
/// feed.
const default_trim_set = " \t\r\n\x0b\x0c";

/// Where the bytes begin within the block. `@offsetOf` and not `@sizeOf`: the
/// head is Zig's own declaration, so `_data` is an ordinary field whose offset
/// the compiler takes exactly.
pub const string_payload = @offsetOf(StringHead, "_data");

// ==========================================================================
// Aliased types
// ==========================================================================

/// The three byte pointers. A symbol and a keyword have a string's head, and a
/// keyword is a symbol with `symbols.own_keyword` set in it.
pub const Keyword = [*:0]const u8;
pub const String = [*:0]const u8;
pub const Symbol = [*:0]const u8;

// ==========================================================================
// Types
// ==========================================================================

/// Knuth-Morris-Pratt search state, and the one piece of this file that owns
/// heap memory across a call that can raise.
///
/// `lookup` comes from `utils.calloc` and is released by `deinit`, which every
/// user of this state owes a `defer`. Releasing it on each visible path
/// instead misses the paths that are not visible:
/// `registry.textSubstitution` runs a Janet function, and a raise from there
/// returns out of this frame, so a release written as an ordinary statement
/// below the call never runs. `lookup` is `utils.calloc`'s and no collector
/// owns it, so the omission leaks the whole table.
const KmpState = struct {
    i: i32,
    j: i32,
    lookup: [*]i32,
    text: []const u8,
    pat: []const u8,

    /// Builds the state and its jump table. `text` is what is searched and
    /// `pat` the pattern, which must not be empty.
    fn init(text: []const u8, pat: []const u8) raise.Error!KmpState {
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
        var j: i32 = 0;
        for (1..pat.len) |i| {
            while (j != 0 and pat[@intCast(j)] != pat[i]) j = lookup[@intCast(j - 1)];
            if (pat[@intCast(j)] == pat[i]) j += 1;
            lookup[i] = j;
        }
        return s;
    }

    /// Releases the jump table. Owed a `defer` at every construction.
    fn deinit(s: *KmpState) void {
        utils.free(@ptrCast(s.lookup));
    }

    /// Restarts the search at `i`, discarding any partial match.
    fn seti(s: *KmpState, i: i32) void {
        s.i = i;
        s.j = 0;
    }

    /// The index of the next match at or after the current position, or -1
    /// where there is none. The state advances past the match, so repeated
    /// calls walk overlapping matches one at a time.
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

/// A `KmpState` beside the substitution `string/replace` and
/// `string/replace-all` apply at each match.
const ReplaceState = struct { kmp: KmpState, subst: repr.Value };

/// A string's head: the collector's object, the length and the hash, with the
/// bytes following it in the same allocation.
///
/// Symbols and keywords use this head too. The bytes are NUL-terminated past
/// `length`, and the terminator is not counted.
pub const StringHead = extern struct {
    gc: abi.GCObject = .{},
    length: u32 = 0,
    hash: i32 = 0,
    _data: [0]u8 = std.mem.zeroes([0]u8),
};

// ==========================================================================
// Public functions
// ==========================================================================

/// Allocates a string of `length` bytes and terminates it.
///
/// The bytes themselves are uninitialised and so is the hash: the caller fills
/// the first and `end` computes the second.
pub fn begin(length: usize) [*]u8 {
    const hd = gc_alloc.gcallocWithPayload(StringHead, .string, length +% 1);
    hd.length = @intCast(length);
    const payload = data(hd);
    payload[length] = 0;
    return payload;
}

/// An interned string's bytes, counted from its head. The NUL past the end is
/// real and is not included, which is what `lengthOf` reports too.
pub inline fn bytesOf(s: [*]const u8) []const u8 {
    return s[0..head(s).length];
}

/// Orders two strings.
///
/// Shorter is less where one is a prefix of the other, and the `memcmp` result
/// is normalised to -1, 0 or 1 rather than passed through: `memcmp` may return
/// any value of the right sign, and Janet's comparison contract is the
/// three-valued one.
pub fn compare(lhs: [*]const u8, rhs: [*]const u8) c_int {
    const xlen = lengthOf(lhs);
    const ylen = lengthOf(rhs);
    const len = if (xlen > ylen) ylen else xlen;
    const res = c.memcmp(lhs, rhs, @intCast(len));
    if (res != 0) return if (res > 0) 1 else -1;
    if (xlen == ylen) return 0;
    return if (xlen < ylen) -1 else 1;
}

/// Allocates a string from a NUL-terminated one, measuring it with `strlen`.
pub fn cstring(str: [*:0]const u8) [*:0]const u8 {
    return new(str[0..c.strlen(str)]);
}

/// The inverse of `head`, for a block the allocator has just returned.
///
/// `hd` is the head. It is `*const` and the result is mutable: the allocator's
/// caller writes through the result, and a comparison or a hash is given a
/// const head.
pub inline fn data(hd: *const StringHead) [*]u8 {
    return @ptrFromInt(@intFromPtr(hd) +% string_payload);
}

/// Closes a string built by hand, computing its hash and returning it as a
/// terminated string.
///
/// This is the only place a string's hash is written outside `new`, and until
/// it runs the head has whatever the allocator left there.
pub fn end(str: [*]u8) [*:0]const u8 {
    head(str).hash = value.hashBytes(str[0..lengthOf(str)]);
    return @ptrCast(str);
}

/// Whether two interned strings have equal bytes.
pub fn equal(lhs: [*]const u8, rhs: [*]const u8) bool {
    return equalconst(lhs, bytesOf(rhs), hashOf(rhs));
}

/// Compares an interned string against a length and hash the caller has
/// already, which is what makes the symbol cache cheap: an unequal hash
/// rejects without touching the bytes.
pub fn equalconst(lhs: [*]const u8, rhs: []const u8, rhash: i32) bool {
    const lhash = hashOf(lhs);
    const llen = lengthOf(lhs);
    if (lhash != rhash or llen != @as(i32, @intCast(rhs.len))) return false;
    if (lhs == rhs.ptr) return true;
    return c.memcmp(lhs, rhs.ptr, rhs.len) == 0;
}

/// An interned string's hash, read from its head.
pub inline fn hashOf(s: [*]const u8) i32 {
    return head(s).hash;
}

/// Recovers a string's head from the bytes Janet passes around. Symbols and
/// keywords are strings and use this too.
pub inline fn head(s: [*]const u8) *StringHead {
    return @ptrFromInt(@intFromPtr(s) -% string_payload);
}

/// An interned string's length in bytes, read from its head. The terminator is
/// not counted.
pub inline fn lengthOf(s: [*]const u8) u32 {
    return head(s).length;
}

/// Installs the `string/`, `symbol/slice` and `keyword/slice` cfunctions into
/// `env`.
pub fn lib(env: *tables.Table) void {
    const slice_doc = "Returns a substring from a byte sequence. The substring is from " ++
        "index `start` inclusive to index `end`, exclusive. All indexing " ++
        "is from 0. `start` and `end` can also be negative to indicate indexing " ++
        "from the end of the string. Note that if `start` is negative it is " ++
        "exclusive, and if `end` is negative it is inclusive, to allow a full " ++
        "negative slice range.";
    const trim_doc_tail = "whitespace from a byte sequence. If the argument " ++
        "`set` is provided, consider only characters in `set` to be whitespace.";
    const entries = comptime [_]corefn.Entry{
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
    };
    corefn.install(env, entries);
}

/// Allocates a string and fills it from `buf` in one step.
pub fn new(buf: []const u8) [*:0]const u8 {
    const hd = gc_alloc.gcallocWithPayload(StringHead, .string, buf.len +% 1);
    hd.length = @intCast(buf.len);
    hd.hash = value.hashBytes(buf);
    const payload = data(hd);
    @memcpy(payload[0..buf.len], buf);
    payload[buf.len] = 0;
    return @ptrCast(payload);
}

// ==========================================================================
// Private functions
// ==========================================================================

/// `keyword/slice`: `string/slice` returning a keyword.
fn cfunKeywordSlice(argv: []repr.Value) raise.Error!repr.Value {
    const view = try args_core.getBytes(argv, 0);
    const range = try args_core.getSlice(argv);
    return wrap.fromKeyword(symbols.keyword(view.bytes.?[@intCast(range.start)..@intCast(range.end)]));
}

/// `string/ascii-lower`: the ASCII upper-case bytes lowered.
fn cfunStringAsciilower(argv: []repr.Value) raise.Error!repr.Value {
    return try mapCase(65, 90, 32, argv);
}

/// `string/ascii-upper`: the ASCII lower-case bytes raised.
fn cfunStringAsciiupper(argv: []repr.Value) raise.Error!repr.Value {
    return try mapCase(97, 122, -32, argv);
}

/// `string/bytes`: a tuple of the byte values.
fn cfunStringBytes(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const view = try args_core.getBytes(argv, 0);
    const tup = tuples.begin(@intCast(view.len));
    for (0..view.len) |i| tup[i] = wrap.fromInteger(view.bytes.?[i]);
    return wrap.fromTuple(tuples.end(tup));
}

/// `string/check-set`: whether every byte of a string appears in a set.
///
/// The set is 256 bits in eight words, indexed by the top three bits of the
/// byte and masked by the low five.
fn cfunStringCheckset(argv: []repr.Value) raise.Error!repr.Value {
    var bitset: [8]u32 = @splat(0);
    try args_core.fixarity(argv, 2);
    const set = try args_core.getBytes(argv, 0);
    const str = try args_core.getBytes(argv, 1);
    for (0..set.len) |i| {
        const byte = set.bytes.?[i];
        bitset[byte >> 5] |= @as(u32, 1) << @intCast(byte & 0x1F);
    }
    for (0..str.len) |i| {
        const byte = str.bytes.?[i];
        if (bitset[byte >> 5] & (@as(u32, 1) << @intCast(byte & 0x1F)) == 0) {
            return wrap.fromFalse();
        }
    }
    return wrap.fromTrue();
}

/// `string/find`: the index of the first match, or nil.
fn cfunStringFind(argv: []repr.Value) raise.Error!repr.Value {
    var state = try findsetup(argv, 0);
    defer state.deinit();
    const result = state.next();
    return if (result < 0) wrap.fromNil() else wrap.fromInteger(result);
}

/// `string/find-all`: an array of the index of every match, overlapping
/// matches counted one at a time.
fn cfunStringFindall(argv: []repr.Value) raise.Error!repr.Value {
    var state = try findsetup(argv, 0);
    defer state.deinit();
    const array = arrays.new(0);
    while (true) {
        const result = state.next();
        if (result < 0) break;
        try arrays.push(array, wrap.fromInteger(result));
    }
    return wrap.fromArray(array);
}

/// `string/format`: `pp_format.bufferFormat` into a fresh buffer, returned as
/// a string.
fn cfunStringFormat(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, -1);
    const buffer = buffers.new(0);
    const strfrmt = try args_core.getString(argv, 0);
    try pp_format.bufferFormat(buffer, @ptrCast(strfrmt), 1, argv);
    return wrap.fromString(new(buffer.slice()));
}

/// `string/from-bytes`: a string of the byte values given as arguments.
fn cfunStringFrombytes(argv: []repr.Value) raise.Error!repr.Value {
    const buf = begin(argv.len);
    for (0..argv.len) |i| {
        buf[i] = @truncate(@as(u32, @bitCast(try args_core.getInteger(argv, i))));
    }
    return wrap.fromString(end(buf));
}

/// `string/has-prefix?`: whether a byte sequence starts with another.
fn cfunStringHasprefix(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 2);
    const prefix = try args_core.getBytes(argv, 0);
    const str = try args_core.getBytes(argv, 1);
    if (str.len < prefix.len) return wrap.fromFalse();
    const n = prefix.len;
    return wrap.fromBoolean(std.mem.eql(u8, prefix.bytes.?[0..n], str.bytes.?[0..n]));
}

/// `string/has-suffix?`: whether a byte sequence ends with another.
fn cfunStringHassuffix(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 2);
    const suffix = try args_core.getBytes(argv, 0);
    const str = try args_core.getBytes(argv, 1);
    if (str.len < suffix.len) return wrap.fromFalse();
    const n = suffix.len;
    const tail = str.bytes.? + (str.len - suffix.len);
    return wrap.fromBoolean(std.mem.eql(u8, suffix.bytes.?[0..n], tail[0..n]));
}

/// `string/join`: the parts concatenated, optionally with a separator between
/// them.
fn cfunStringJoin(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, 2);
    var source = try args_core.chunks(argv[0]) orelse {
        return args_core.panicIndexed(argv[0], 0, repr.TagSet.none);
    };
    const joiner: abi.ByteView = if (argv.len == 2)
        try args_core.getBytes(argv, 1)
    else
        .{ .bytes = "", .len = 0 };

    // Two passes, and the first is what rejects a bad part: nothing is
    // allocated until every item is known to be a byte sequence and the total
    // is known to fit.
    var finallen: i64 = 0;
    var counted: usize = 0;
    while (try source.next()) |run| {
        for (run) |part| {
            const chunk = args_core.bytesView(part) orelse {
                return pp_format.panicf("item %d of parts is not a byte sequence, got %v", .{ @as(i64, @intCast(counted)), part });
            };
            if (counted != 0) finallen += @intCast(joiner.len);
            finallen += @intCast(chunk.len);
            if (finallen > std.math.maxInt(i32)) return raise.panic("result string too long");
            counted += 1;
        }
    }

    const total: usize = @intCast(finallen);
    const buf = begin(total);
    // Neither callback can call into Janet code, so the second pass reads what
    // the first measured. The bytes of an unfinished string are not walked by
    // the collector, unlike a tuple's slots, so nothing has to be filled in
    // first.
    var out: usize = 0;
    switch (source.source) {
        // A loop over the parts themselves, which is what an array or a tuple
        // is. Reading it through the iterator instead costs this function 6%
        // on six short parts.
        .contiguous => |parts| {
            for (parts, 0..) |part, i| {
                if (i != 0) {
                    @memcpy(buf[out..][0..joiner.len], args_core.viewBytes(joiner));
                    out += joiner.len;
                }
                const chunk = args_core.bytesView(part).?;
                @memcpy(buf[out..][0..chunk.len], chunk);
                out += chunk.len;
            }
        },
        // Rewound to take the runs again, since a run does not survive the
        // allocation between the passes.
        .vector, .abstract => {
            source.window(0, source.len);
            var index: usize = 0;
            while (try source.next()) |run| {
                for (run) |part| {
                    if (index != 0) {
                        @memcpy(buf[out..][0..joiner.len], args_core.viewBytes(joiner));
                        out += joiner.len;
                    }
                    const chunk = args_core.bytesView(part).?;
                    @memcpy(buf[out..][0..chunk.len], chunk);
                    out += chunk.len;
                    index += 1;
                }
            }
        },
    }
    std.debug.assert(out == total);
    return wrap.fromString(end(buf));
}

/// `string/repeat`: `n` copies of a byte sequence concatenated.
fn cfunStringRepeat(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 2);
    const view = try args_core.getBytes(argv, 0);
    const rep = try args_core.getInteger(argv, 1);
    if (rep < 0) return raise.panic("expected non-negative number of repetitions");
    if (rep == 0) return value.fromBytes("", .string);
    const mulres = @as(i64, rep) * @as(i64, @intCast(view.len));
    if (mulres > std.math.maxInt(i32)) return raise.panic("result string is too long");
    const newbuf = begin(@intCast(mulres));
    var offset: usize = 0;
    const total: usize = @intCast(mulres);
    while (offset < total) : (offset += view.len) {
        @memcpy(newbuf[offset..][0..view.len], args_core.viewBytes(view));
    }
    return wrap.fromString(end(newbuf));
}

/// `string/replace`: the first match replaced.
fn cfunStringReplace(argv: []repr.Value) raise.Error!repr.Value {
    var s = try replacesetup(argv);
    defer s.kmp.deinit();
    const result = s.kmp.next();
    if (result < 0) return wrap.fromString(new(s.kmp.text));
    const at: usize = @intCast(result);
    const subst = try registry.textSubstitution(
        &s.subst,
        s.kmp.text[at..][0..s.kmp.pat.len],
        null,
    );
    const buf = begin(@intCast(s.kmp.text.len - s.kmp.pat.len + subst.len));
    const tail = s.kmp.text[at + s.kmp.pat.len ..];
    @memcpy(buf[0..at], s.kmp.text[0..at]);
    @memcpy(buf[at..][0..subst.len], args_core.viewBytes(subst));
    @memcpy(buf[at + subst.len ..][0..tail.len], tail);
    return wrap.fromString(end(buf));
}

/// `string/replace-all`: every non-overlapping match replaced.
fn cfunStringReplaceall(argv: []repr.Value) raise.Error!repr.Value {
    var s = try replacesetup(argv);
    defer s.kmp.deinit();
    var b: buffers.Buffer = undefined;
    var lastindex: i32 = 0;
    _ = buffers.init(&b, @intCast(s.kmp.text.len));
    // `buffers.init` takes its storage from `utils.malloc` and marks the header
    // disabled, so the collector never owns it and only this `defer` returns
    // it. The substitution below raises, which is what the `defer` is for.
    defer buffers.deinit(&b);
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
    return wrap.fromString(new(b.slice()));
}

/// `string/reverse`: the bytes in the opposite order.
fn cfunStringReverse(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const view = try args_core.getBytes(argv, 0);
    const buf = begin(@intCast(view.len));
    for (0..view.len) |i| buf[i] = view.bytes.?[view.len - 1 - i];
    return wrap.fromString(end(buf));
}

/// `string/slice`: a new string over a half-open range of a byte sequence.
fn cfunStringSlice(argv: []repr.Value) raise.Error!repr.Value {
    const view = try args_core.getBytes(argv, 0);
    const range = try args_core.getSlice(argv);
    return wrap.fromString(new(view.bytes.?[@intCast(range.start)..@intCast(range.end)]));
}

/// `string/split`: an array of the pieces between matches of a delimiter.
///
/// The limit arithmetic is the contract, decrement and all. `limit` defaults
/// to -1 and is tested against zero after each decrement, so the default runs
/// away from zero and never stops the loop. An explicit 0 decrements to -1 and
/// therefore behaves like the default rather than like a limit of one.
fn cfunStringSplit(argv: []repr.Value) raise.Error!repr.Value {
    var limit: i32 = -1;
    var lastindex: i32 = 0;
    if (argv.len == 4) limit = try args_core.getInteger(argv, 3);
    var state = try findsetup(argv, 1);
    defer state.deinit();
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
    return wrap.fromArray(array);
}

/// `string/trim`: leading and trailing bytes of a set dropped.
fn cfunStringTrim(argv: []repr.Value) raise.Error!repr.Value {
    var str: abi.ByteView = undefined;
    var set: abi.ByteView = undefined;
    try trimArgs(argv, &str, &set);
    const left = leftEdge(str, set);
    const right = rightEdge(str, set);
    if (right < left) return wrap.fromString(new(""));
    return wrap.fromString(new(str.bytes.?[left..right]));
}

/// `string/triml`: leading bytes of a set dropped.
fn cfunStringTriml(argv: []repr.Value) raise.Error!repr.Value {
    var str: abi.ByteView = undefined;
    var set: abi.ByteView = undefined;
    try trimArgs(argv, &str, &set);
    const left = leftEdge(str, set);
    return wrap.fromString(new(str.bytes.?[left..str.len]));
}

/// `string/trimr`: trailing bytes of a set dropped.
fn cfunStringTrimr(argv: []repr.Value) raise.Error!repr.Value {
    var str: abi.ByteView = undefined;
    var set: abi.ByteView = undefined;
    try trimArgs(argv, &str, &set);
    return wrap.fromString(new(str.bytes.?[0..rightEdge(str, set)]));
}

/// `symbol/slice`: `string/slice` returning a symbol.
fn cfunSymbolSlice(argv: []repr.Value) raise.Error!repr.Value {
    const view = try args_core.getBytes(argv, 0);
    const range = try args_core.getSlice(argv);
    return wrap.fromSymbol(symbols.new(view.bytes.?[@intCast(range.start)..@intCast(range.end)]));
}

/// The shared argument handling of `string/find`, `string/find-all` and
/// `string/split`, returning the search state positioned at the start index.
///
/// `extra` is how many optional arguments the caller takes beyond the start
/// index. The result owns heap memory, so the caller owes a `defer`.
fn findsetup(argv: []repr.Value, extra: i32) raise.Error!KmpState {
    try args_core.arity(argv, 2, 3 + extra);
    const pat = try args_core.getBytes(argv, 0);
    const text = try args_core.getBytes(argv, 1);
    var start: i32 = 0;
    if (argv.len >= 3) {
        start = try args_core.getInteger(argv, 2);
        if (start < 0) return raise.panic("expected non-negative start index");
    }
    var s = try KmpState.init(args_core.viewBytes(text), args_core.viewBytes(pat));
    s.i = start;
    return s;
}

/// Whether `x` is one of `set`'s bytes.
fn inSet(set: abi.ByteView, x: u8) bool {
    for (0..set.len) |j| if (set.bytes.?[j] == x) return true;
    return false;
}

/// The index of the first byte of `str` that is not in `set`, or `str.len`
/// where every byte is.
fn leftEdge(str: abi.ByteView, set: abi.ByteView) usize {
    for (0..str.len) |i| if (!inSet(set, str.bytes.?[i])) return i;
    return str.len;
}

/// The shared body of `string/ascii-lower` and `string/ascii-upper`: the bytes
/// from `lo` through `hi` shifted by `delta` and the rest copied.
///
/// ASCII only, as the docstring says: the byte ranges are tested directly
/// rather than through `tolower`, so a locale cannot change what they do.
fn mapCase(comptime lo: u8, comptime hi: u8, comptime delta: i8, argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const view = try args_core.getBytes(argv, 0);
    const buf = begin(@intCast(view.len));
    for (0..view.len) |i| {
        const byte = view.bytes.?[i];
        buf[i] = if (byte >= lo and byte <= hi)
            @intCast(@as(i16, byte) + delta)
        else
            byte;
    }
    return wrap.fromString(end(buf));
}

/// The shared argument handling of `string/replace` and
/// `string/replace-all`, returning the search state and the substitution. The
/// result owns heap memory, so the caller owes a `defer`.
fn replacesetup(argv: []repr.Value) raise.Error!ReplaceState {
    try args_core.arity(argv, 3, 4);
    const pat = try args_core.getBytes(argv, 0);
    const subst = argv[1];
    const text = try args_core.getBytes(argv, 2);
    var start: i32 = 0;
    if (argv.len == 4) {
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

/// One past the index of the last byte of `str` that is not in `set`, or zero
/// where every byte is.
///
/// The walk is backwards and the counter is unsigned anyway, because the
/// decrement is separable from the use: guard, step, then read.
fn rightEdge(str: abi.ByteView, set: abi.ByteView) usize {
    var i = str.len;
    while (i > 0) {
        i -= 1;
        if (!inSet(set, str.bytes.?[i])) return i + 1;
    }
    return 0;
}

/// The shared argument handling of the three trims: the byte sequence and the
/// set, which defaults to `default_trim_set`.
fn trimArgs(argv: []repr.Value, str: *abi.ByteView, set: *abi.ByteView) raise.Error!void {
    try args_core.arity(argv, 1, 2);
    str.* = try args_core.getBytes(argv, 0);
    if (argv.len >= 2) {
        set.* = try args_core.getBytes(argv, 1);
    } else {
        set.* = .{ .bytes = default_trim_set, .len = default_trim_set.len };
    }
}

// ==========================================================================
// Tests
// ==========================================================================

// `StringHead` against a re-declaration with a signed length. The width is the
// contract, a marshalled string records it and the payload sits behind it, and
// the sign is not, so the comparison is against that re-declaration rather than
// against a remembered offset, which would be a different number per target.
// `hash` stays signed: it is a hash, and `value.hashBytes` returns an `i32`.
comptime {
    const SignedHead = extern struct {
        gc: abi.GCObject = .{},
        length: i32 = 0,
        hash: i32 = 0,
        _data: [0]u8 = std.mem.zeroes([0]u8),
    };
    std.debug.assert(@offsetOf(StringHead, "_data") == @offsetOf(SignedHead, "_data"));
    std.debug.assert(@offsetOf(StringHead, "hash") == @offsetOf(SignedHead, "hash"));
    std.debug.assert(@sizeOf(StringHead) == @sizeOf(SignedHead));
}
