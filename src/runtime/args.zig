//! Argument extraction: deciding whether a cfunction's arguments are what it
//! asked for, and saying so.
//!
//! Deciding and saying are one layer here. A getter that formats its own
//! complaint allocates and allocation can raise, so the kernels, the wording,
//! every `get`/`opt` getter, and the three probes are one subsystem.
//!
//! ## Why the kernels report a fault instead of raising
//!
//! Three probes must not raise at all. `indexedView`, `bytesView` and
//! `dictionaryView` answer "not that kind of value" to the pretty printer, the
//! bytecode reader and the compiler's constant folding, and `checkabstract`
//! answers null; a kernel that raised would need a non-raising twin for each
//! of them. A kernel that fills in a `Fault` serves both, and the wording
//! still lives in exactly one place -- `raiseFault`. `argBytes` and
//! `argCbytes` each say at their own declaration where that line falls for
//! them.
//!
//! ## What raises, and what a raise costs
//!
//! A getter returns `raise.Raising(T)` and the `opt` layer above it calls that
//! form, so a default-taking wrapper propagates an error rather than losing
//! one. Nothing here catches its own error.
//!
//! The `bytes` callback is not the only thing here that can raise. `getCBytes`
//! calls `gc.smalloc` and `buffers.pushU8`, `optBuffer` and its two siblings
//! allocate, `getSlice` calls `access.length`, and with integer types enabled
//! `getInteger64` calls `ints.unwrapS64`. This file holds nothing across any
//! of them.

const std = @import("std");
const raise = @import("../api/raise.zig");
const pp_format = @import("pp/format.zig");
const repr = @import("repr");
const access = @import("value/helpers/access.zig");
const options = @import("options");
const gc_alloc = @import("gc.zig");
const fatal = @import("fatal.zig");
const utils = @import("utils.zig");
const wrap = @import("value/helpers/wrap.zig");
pub const tables = @import("value/tables.zig");
pub const arrays = @import("value/arrays.zig");
pub const buffers = @import("value/buffers.zig");
const value = @import("value.zig");
const strings = @import("value/strings.zig");
const tuples = @import("value/tuples.zig");
const structs = @import("value/structs.zig");
const abstracts = @import("value/abstracts.zig");
const abi = @import("abi");
const method_type = @import("method_type.zig");

/// The two 64-bit conversions, when the configuration has them.
///
/// `-Dint-types=false` compiles no `inttypes.zig` at all, and `Wide` below
/// names nothing in this namespace in that case -- Zig does not analyse the
/// untaken arm of a comptime-known `if`, which is what makes the empty struct
/// sufficient rather than a stub.
const inttypes = if (options.int_types_core) @import("value/ints.zig") else struct {};

/// `dictionaryView`'s answer. `cap` is the *capacity* of the backing
/// table, which the caller walks to `cap` rather than to `len`; both are
/// counts.
pub const DictView = extern struct {
    kvs: ?[*]const tables.KV = null,
    len: usize = 0,
    cap: usize = 0,
};

pub const Range = extern struct {
    start: i32 = 0,
    end: i32 = 0,
};

// -------------------------------------------------------------- predicates

/// Whether `dval` is exactly representable in `T`: a range test followed by a
/// round trip through the integer type, which is what rejects a fractional
/// value.
///
/// The range test always precedes the conversion, so the conversion is in range
/// whenever it runs and Zig's safety check cannot fire. NaN fails the first
/// comparison and never reaches it.
fn checkRange(comptime T: type, dval: f64) bool {
    const lo: f64 = @floatFromInt(std.math.minInt(T));
    const hi: f64 = @floatFromInt(std.math.maxInt(T));
    if (!(dval >= lo and dval <= hi)) return false;
    const truncated: T = @intFromFloat(dval);
    const back: f64 = @floatFromInt(truncated);
    return dval == back;
}

fn checkNumber(comptime T: type, x: repr.Value) bool {
    if (!repr.checkType(x, repr.Tag.number)) return false;
    return checkRange(T, wrap.toNumber(x));
}

pub fn checkint(x: repr.Value) bool {
    return checkNumber(i32, x);
}

pub fn checkuint(x: repr.Value) bool {
    return checkNumber(u32, x);
}

pub fn checkint16(x: repr.Value) bool {
    return checkNumber(i16, x);
}

pub fn checkuint16(x: repr.Value) bool {
    return checkNumber(u16, x);
}

pub fn checkint8(x: repr.Value) bool {
    return checkNumber(i8, x);
}

pub fn checkuint8(x: repr.Value) bool {
    return checkNumber(u8, x);
}

/// The 64-bit range is `JANET_INTMAX_DOUBLE`, not `INT64_MAX`: 2^53, the
/// largest integer a double represents exactly. Beyond it the round trip would
/// accept values a double cannot distinguish from their neighbours.
const intmax_double: f64 = 9007199254740992.0;
const intmin_double: f64 = -9007199254740992.0;

pub fn checkint64(x: repr.Value) bool {
    if (!repr.checkType(x, repr.Tag.number)) return false;
    const dval = wrap.toNumber(x);
    if (!(dval >= intmin_double and dval <= intmax_double)) return false;
    const truncated: i64 = @intFromFloat(dval);
    const back: f64 = @floatFromInt(truncated);
    return dval == back;
}

pub fn checkuint64(x: repr.Value) bool {
    if (!repr.checkType(x, repr.Tag.number)) return false;
    const dval = wrap.toNumber(x);
    if (!(dval >= 0 and dval <= intmax_double)) return false;
    const truncated: u64 = @intFromFloat(dval);
    const back: f64 = @floatFromInt(truncated);
    return dval == back;
}

/// Whether a double is exactly representable as an `f32`.
///
/// **The lower bound is `-std.math.floatMax(f32)`, the most negative finite
/// float**, which is what every sibling range test's lower bound is:
/// `checkint8`'s is the minimum `i8`, not one. The smallest positive *normal*
/// float as a bound would reject 0.0, every negative value and every
/// subnormal, and answer that `-1.5` is not representable as a float.
///
/// The round trip is what decides the rest: a value inside the range that does
/// not survive the narrowing is not representable, and a NaN or an infinity
/// fails the range test before it gets there.
pub fn checkfloat(x: repr.Value) bool {
    if (!repr.checkType(x, repr.Tag.number)) return false;
    const dval = wrap.toNumber(x);
    if (!(dval >= -std.math.floatMax(f32) and dval <= std.math.floatMax(f32))) return false;
    const narrowed: f32 = @floatCast(dval);
    const back: f64 = @floatCast(narrowed);
    return dval == back;
}

/// **The range test comes before the conversion**, so the conversion is always
/// in range. Converting first, as upstream does, is undefined for a negative
/// or enormous double and saturates on every supported target; the two orders
/// agree on every input -- negatives, NaN, 1e300 included -- because
/// saturation and rejection agree on all of them.
pub fn checksize(x: repr.Value) bool {
    if (!repr.checkType(x, repr.Tag.number)) return false;
    const dval = wrap.toNumber(x);
    const size_hi: f64 = @floatFromInt(std.math.maxInt(usize));
    if (!(dval >= 0 and dval <= size_hi)) return false;
    const truncated: usize = @intFromFloat(dval);
    const back: f64 = @floatFromInt(truncated);
    if (dval != back) return false;
    // SIZE_MAX exceeds 2^53 on every 64-bit target, so this is the branch that
    // runs there; the other is for platforms with a narrower size_t.
    if (size_hi > intmax_double) return dval <= intmax_double;
    return dval <= size_hi;
}

// ------------------------------------------------------------------ faults

/// What a numeric kernel expected, and the only place the nouns are written.
///
/// A kernel reports `.s16` and `Expect.name` decides it is spelled "16 bit
/// signed integer", which is what makes the wording live in one place.
pub const Expect = enum {
    nat,
    size,
    s32,
    u32,
    s16,
    u16,
    s8,
    u8,
    float,
    s64,
    u64,

    fn name(self: Expect) [*:0]const u8 {
        return switch (self) {
            .nat => "non-negative 32 bit signed integer",
            .size => "size",
            .s32 => "32 bit signed integer",
            .u32 => "32 bit unsigned integer",
            .s16 => "16 bit signed integer",
            .u16 => "16 bit unsigned integer",
            .s8 => "8 bit signed integer",
            .u8 => "8 bit unsigned integer",
            .float => "float number",
            .s64 => "64 bit signed integer",
            .u64 => "64 bit unsigned integer",
        };
    }
};

/// Why a kernel refused, carrying exactly what its message renders.
///
/// A tagged union rather than a code beside a wide payload: a field is
/// reachable only from the arm that filled it, so nothing has to say which
/// kinds may read `slot`, and `raiseFault`'s switch is exhaustive without an
/// `else`.
pub const Fault = union(enum) {
    wrong_type: struct { slot: usize, expected: repr.TagSet },
    wrong_abstract: struct { slot: usize, at: *const abi.AbstractType },
    wrong_number: struct { slot: usize, expected: Expect },
    /// Both range kinds. `inclusive` is the closed-interval rendering, which
    /// is `halfRange`'s; `argIndex` reports the half-open one.
    ///
    /// The three quantities are `i64` because the message is contract: `%d`
    /// renders that width, and the digits a program sees are the same for
    /// every index this runtime can produce.
    range: struct { which: [*:0]const u8, raw: i64, lo: i64, hi: i64, inclusive: bool },
    bad_flag: struct { byte: u8, permitted: [*:0]const u8 },
    embedded_zero,
    arity_fix: struct { got: i32, want: i32 },
    arity_min: struct { got: i32, want: i32 },
    arity_max: struct { got: i32, want: i32 },
};

// ----------------------------------------------------------------- getters

pub fn argChecktype(
    argv: []const repr.Value,
    n: usize,
    janet_type: repr.Tag,
    typeflags: repr.TagSet,
    fault: *Fault,
) bool {
    if (repr.checkType(argv[n], janet_type)) return true;
    fault.* = .{ .wrong_type = .{ .slot = n, .expected = typeflags } };
    return false;
}

/// The shared head of every `opt` getter: an argument past the end of the list,
/// or an explicit nil, both mean "use the default".
pub fn argIsdefault(argv: []const repr.Value, n: usize) bool {
    if (n >= argv.len) return true;
    return repr.checkType(argv[n], repr.Tag.nil);
}

/// Every width except `janet_getinteger` converts the double; that one unwraps
/// an integer, which is a distinct operation under a tagged representation
/// where an integer is not stored as a double.
fn numberGetter(
    comptime T: type,
    comptime expect: Expect,
    comptime check: fn (repr.Value) bool,
) fn ([]const repr.Value, usize, *Fault) ?T {
    return struct {
        fn get(argv: []const repr.Value, n: usize, fault: *Fault) ?T {
            const x = argv[n];
            if (!check(x)) {
                fault.* = .{ .wrong_number = .{ .slot = n, .expected = expect } };
                return null;
            }
            const dval = wrap.toNumber(x);
            return switch (@typeInfo(T)) {
                .float => @floatCast(dval),
                else => @intFromFloat(dval),
            };
        }
    }.get;
}

pub const argUinteger = numberGetter(u32, .u32, checkuint);
pub const argInteger16 = numberGetter(i16, .s16, checkint16);
pub const argUinteger16 = numberGetter(u16, .u16, checkuint16);
pub const argInteger8 = numberGetter(i8, .s8, checkint8);
pub const argUinteger8 = numberGetter(u8, .u8, checkuint8);
pub const argFloat = numberGetter(f32, .float, checkfloat);
pub const argInteger64 = numberGetter(i64, .s64, checkint64);
pub const argUinteger64 = numberGetter(u64, .u64, checkuint64);
pub const argSize = numberGetter(usize, .size, checksize);

pub fn argInteger(argv: []const repr.Value, n: usize, fault: *Fault) ?i32 {
    const x = argv[n];
    if (!checkint(x)) {
        fault.* = .{ .wrong_number = .{ .slot = n, .expected = .s32 } };
        return null;
    }
    return wrap.toInteger(x);
}

pub fn argNat(argv: []const repr.Value, n: usize, fault: *Fault) ?i32 {
    const x = argv[n];
    if (checkint(x)) {
        const ret = wrap.toInteger(x);
        if (ret >= 0) return ret;
    }
    fault.* = .{ .wrong_number = .{ .slot = n, .expected = .nat } };
    return null;
}

/// The erased payload address, or nothing.
///
/// **The pointer stays erased here on purpose.** This is the classification
/// layer, and its answer is "an abstract of that type is at this address";
/// the type arrives one layer up, at `getAbstract(comptime T, ...)` and at
/// `module.zig`'s form for authors, where the cast is the checked one. Making
/// the kernel generic over `T` would drag the fault protocol into the typed
/// layer, where the getters already raise and have no use for it.
pub fn argAbstract(
    argv: []const repr.Value,
    n: usize,
    at: *const abi.AbstractType,
    fault: *Fault,
) ?*anyopaque {
    const x = argv[n];
    if (repr.checkType(x, repr.Tag.abstract)) {
        const abstractx = wrap.toAbstract(x);
        if (abi.abstractHead(abstractx).type == at) return abstractx;
    }
    fault.* = .{ .wrong_abstract = .{ .slot = n, .at = at } };
    return null;
}

// ------------------------------------------------------------------- views

/// The elements of an array or a tuple, as the range they are.
///
/// A collection with no elements has a null data pointer -- `arrays.init(a,
/// 0)` leaves it so -- and slicing a null pointer traps even for an empty
/// range, so the empty slice is built here rather than at each caller.
pub fn argIndexed(
    argv: []const repr.Value,
    n: usize,
    fault: *Fault,
) ?[]const repr.Value {
    const x = argv[n];
    if (repr.checkType(x, repr.Tag.array)) {
        const array = wrap.toArray(x);
        const items = array.data orelse return &.{};
        return items[0..@intCast(array.count)];
    } else if (repr.checkType(x, repr.Tag.tuple)) {
        const tuple = wrap.toTuple(x);
        return tuple[0..tuples.head(tuple).length];
    }
    fault.* = .{ .wrong_type = .{ .slot = n, .expected = repr.TagSet.indexed } };
    return null;
}

/// A table's or a struct's entries. Three quantities rather than two: the
/// slice is the whole hash array, `cap` long, and `len` is how many of its
/// slots are occupied -- a walk over a dictionary reads every slot and skips
/// the empty ones, so neither number alone describes it.
pub fn argDictionary(
    argv: []const repr.Value,
    n: usize,
    fault: *Fault,
) ?DictView {
    const x = argv[n];
    if (repr.checkType(x, repr.Tag.table)) {
        const table = wrap.toTable(x);
        return .{
            .kvs = table.data.?,
            .cap = @intCast(table.capacity),
            .len = @intCast(table.count),
        };
    } else if (repr.checkType(x, repr.Tag.@"struct")) {
        const structure = wrap.toStruct(x);
        return .{
            .kvs = structure,
            .cap = structs.head(structure).capacity,
            .len = structs.head(structure).length,
        };
    }
    fault.* = .{ .wrong_type = .{ .slot = n, .expected = repr.TagSet.dictionary } };
    return null;
}

/// Either the bytes, or the abstract whose callback still has to be run.
///
/// **The second arm is a leftover, and nothing depends on it.** The split was
/// built for a `bytes` callback that could raise, so that a caller which may
/// not raise could stop before reaching one. It cannot raise -- `Spec.bytes`
/// answers `abi.ByteView` -- and both callers of `argBytes` take this arm
/// straight into `abstractBytes`, so the kernel could answer the view itself.
/// Collapsing it is a later increment's; nothing here is wrong, only wider
/// than it needs to be.
pub const Bytes = union(enum) {
    view: abi.ByteView,
    abstract: abstracts.Abstract,
};

/// Classifies, and for the abstract case stops. See `Bytes` for why the stop
/// buys nothing now, and what would collapse it.
pub fn argBytes(x: repr.Value, n: usize, fault: *Fault) ?Bytes {
    switch (repr.typeOf(x)) {
        repr.Tag.string, repr.Tag.symbol, repr.Tag.keyword => {
            const string = wrap.toString(x);
            return .{ .view = .{
                .bytes = string,
                .len = strings.head(string).length,
            } };
        },
        repr.Tag.buffer => {
            const buffer = wrap.toBuffer(x);
            return .{ .view = .{
                .bytes = buffer.data.?,
                .len = @intCast(buffer.count),
            } };
        },
        repr.Tag.abstract => {
            const abst = wrap.toAbstract(x);
            if (abi.abstractHead(abst).type.bytes != null) return .{ .abstract = abst };
        },
        else => {},
    }
    fault.* = .{ .wrong_type = .{ .slot = n, .expected = repr.TagSet.bytes } };
    return null;
}

/// Runs an abstract's `bytes` callback: the one place third-party code is
/// reached for a byte view.
///
/// `bytes` is one of the six callbacks that cannot raise -- `api/abstract_type.zig`
/// carries the contract -- which is what lets `bytesView`, a frame that
/// reports no raise at all, reach it as freely as `getBytes` does.
inline fn abstractBytes(abst: abstracts.Abstract) abi.ByteView {
    const head = abi.abstractHead(abst);
    return head.type.bytes.?(abst, head.size);
}

/// Which shape `getCBytes` must use.
///
/// **`view` is only for the shapes that carry their own terminator**: a string,
/// a symbol and a keyword are interned with one. An abstract's `bytes` callback
/// answers a view of the module author's choosing and nothing requires a
/// terminator after it, so it is copied and terminated the way an unresizable
/// buffer is -- otherwise `getCBytes` would hand back a pointer whose C string
/// runs past the end of the view.
///
/// Both copying shapes mutate or allocate, so neither is carried out here. It
/// cannot fault, so it takes no fault.
pub const CBytes = enum { copy_buffer, copy_view, terminate, view };

pub fn argCbytes(argv: []const repr.Value, n: usize) CBytes {
    const x = argv[n];
    if (repr.checkType(x, repr.Tag.buffer)) {
        const buffer = wrap.toBuffer(x);
        if (buffers.isForeign(buffer) and buffer.count == buffer.capacity) {
            return .copy_buffer;
        }
        return .terminate;
    }
    if (repr.checkType(x, repr.Tag.abstract)) return .copy_view;
    return .view;
}

/// Whether `bytes` holds no zero, over the length the caller measured.
///
/// **The view is what is searched, not a walk to the first terminator.** The
/// two are the same question only where a terminator is known to sit at `len`;
/// for a view that carries no terminator, walking reads past the end and
/// answers about whatever follows it.
pub fn argZeros(bytes: []const u8, fault: *Fault) bool {
    if (std.mem.indexOfScalar(u8, bytes, 0) == null) return true;
    fault.* = .embedded_zero;
    return false;
}

// ------------------------------------------------------------------ ranges

/// `halfRange` and `argIndex` differ in two places and are otherwise the same
/// walk: the half-range folds a negative index against
/// `length + 1` and reports a closed interval, the argument index folds against
/// `length` and reports a half-open one. Both accept `length` itself.
fn range(
    argv: []const repr.Value,
    n: usize,
    length: i32,
    which: [*:0]const u8,
    fault: *Fault,
    comptime inclusive: bool,
) ?i32 {
    const raw = argInteger(argv, n, fault) orelse return null;
    const fold: i64 = if (inclusive) @as(i64, length) + 1 else @as(i64, length);
    var not_raw: i64 = raw;
    if (not_raw < 0) not_raw += fold;
    if (not_raw < 0 or not_raw > length) {
        fault.* = .{ .range = .{
            .which = which,
            .raw = raw,
            .lo = -fold,
            .hi = length,
            .inclusive = inclusive,
        } };
        return null;
    }
    return @intCast(not_raw);
}

pub fn argHalfrange(
    argv: []const repr.Value,
    n: usize,
    length: i32,
    which: [*:0]const u8,
    fault: *Fault,
) ?i32 {
    return range(argv, n, length, which, fault, true);
}

pub fn argArgindex(
    argv: []const repr.Value,
    n: usize,
    length: i32,
    which: [*:0]const u8,
    fault: *Fault,
) ?i32 {
    return range(argv, n, length, which, fault, false);
}

// ------------------------------------------------------------------- flags

/// **The 64-flag ceiling is the result type's, and exceeding it is the
/// caller's mistake rather than the user's.** A `u64` has no bit for a
/// sixty-fifth flag, so a `flags` set longer than 64 characters cannot be
/// honoured; clamping it instead turns the caller's mistake into a wrong
/// answer about the *user's* input, rejecting a keyword that names a character
/// the quoted set visibly contains. The set is written by whoever registered
/// the cfunction, so that is who the diagnosis names.
pub fn argFlags(
    keyw: [*]const u8,
    klen: usize,
    flags: [*:0]const u8,
    fault: *Fault,
) ?u64 {
    var ret: u64 = 0;
    const flen: usize = std.mem.len(flags);
    if (flen > 64) fatal.fatal("permitted flag set is longer than 64 characters");
    for (keyw[0..klen]) |byte| {
        var i: usize = 0;
        while (i < flen) : (i += 1) {
            if (flags[i] == byte) {
                ret |= @as(u64, 1) << @intCast(i);
                break;
            }
        }
        if (i == flen) {
            fault.* = .{ .bad_flag = .{ .byte = byte, .permitted = flags } };
            return null;
        }
    }
    return ret;
}

// ------------------------------------------------------------------- arity

pub fn argFixarity(count: i32, fix: i32, fault: *Fault) bool {
    if (count == fix) return true;
    fault.* = .{ .arity_fix = .{ .got = count, .want = fix } };
    return false;
}

/// A negative bound means "unbounded on that side", which is how a cfunction
/// with no maximum spells itself.
pub fn argArity(count: i32, min: i32, max: i32, fault: *Fault) bool {
    if (min >= 0 and count < min) {
        fault.* = .{ .arity_min = .{ .got = count, .want = min } };
        return false;
    }
    if (max >= 0 and count > max) {
        fault.* = .{ .arity_max = .{ .got = count, .want = max } };
        return false;
    }
    return true;
}

// ----------------------------------------------------------------- strlike

pub fn argStrlike(janet_type: repr.Tag, x: repr.Value, cstring: [*:0]const u8) bool {
    if (repr.typeOf(x) != janet_type) return false;
    return utils.cstrcmp(wrap.toString(x), cstring) == 0;
}

// ----------------------------------------------------------------- methods

pub fn argMethod(
    method: [*:0]const u8,
    methods: [*]const method_type.CMethod,
) ?*const method_type.CMethod {
    var entry = methods;
    while (entry[0].name) |name| : (entry += 1) {
        if (utils.cstrcmp(method, name) == 0) return &entry[0];
    }
    return null;
}

/// Returns the entry whose name the caller should wrap as a keyword, or the
/// terminating entry — the one with a null name — when the walk runs off the
/// end. Wrapping allocates, so it is not done here.
///
/// The walk advances past the matched entry *and* past every entry it rejects,
/// which is what makes this an iterator rather than a lookup: a nil key starts
/// at the head, and any other key resumes after the one it names.
pub fn argNextmethod(
    methods: [*]const method_type.CMethod,
    key: repr.Value,
) [*]const method_type.CMethod {
    var entry = methods;
    if (!repr.checkType(key, repr.Tag.nil)) {
        while (entry[0].name) |name| {
            const matched = keyeq(key, name);
            entry += 1;
            if (matched) break;
        }
    }
    return entry;
}

// ====================================================================
// The exported surface.
//
// Each entry is a kernel call and, on failure, a raise -- a returned error, so
// an `opt*` wrapper propagates what its `get*` kernel decided rather than
// losing it.
// ====================================================================

// ------------------------------------------------------------ the two slot
// diagnostics, which are public API of their own

/// The wrong type in a slot. It lives with the argument layer rather than with
/// the rest of the panic family so that the two slot diagnostics' format
/// strings sit in one place, beside the faults that build them.
pub fn panicType(x: repr.Value, n: i32, expected: repr.TagSet) raise.Error {
    return pp_format.panicf("bad slot #%d, expected %T, got %v", .{ n, expected, x });
}

pub fn panicAbstract(x: repr.Value, n: i32, at: *const abi.AbstractType) raise.Error {
    return pp_format.panicf("bad slot #%d, expected %s, got %v", .{ n, at.name, x });
}

/// The abi keeps Janet's `int`. A mask bit above fifteen names no tag, so the
/// narrowing loses nothing; the internal set is sixteen bits wide and this is
/// one of the two symbols that convert.
pub fn panicTypeAbi(x: repr.Value, n: i32, expected: c_int) void {
    raise.report(panicType(x, n, repr.TagSet.fromBits(@truncate(@as(c_uint, @bitCast(expected))))));
}

pub fn panicAbstractAbi(x: repr.Value, n: i32, at: *const abi.AbstractType) void {
    raise.report(panicAbstract(x, n, at));
}

// -------------------------------------------------------------- the raise

/// Turn a fault into the raise its message renders.
///
/// `argv` may be null for the arms that name no slot -- the arity kinds, the
/// range kinds, the flag kind and the embedded zero all render without
/// touching the argument list, and the two arity checks are reached from a
/// count with no argument list to pass.
fn raiseFault(argv: ?[]const repr.Value, fault: Fault) raise.Error {
    return switch (fault) {
        .wrong_type => |f| panicType(argv.?[f.slot], @intCast(f.slot), f.expected),
        .wrong_abstract => |f| panicAbstract(argv.?[f.slot], @intCast(f.slot), f.at),
        .wrong_number => |f| pp_format.panicf(
            "bad slot #%d, expected %s, got %v",
            .{ @as(i32, @intCast(f.slot)), f.expected.name(), argv.?[f.slot] },
        ),
        // The three arguments to "%d" below are `i64`. There is no va_list
        // here: "%d" renders the 64 bits its specifier asks for, so the width
        // the arguments carry is the width the conversion reads, and the
        // digits are what a program sees for every index this runtime can
        // produce.
        .range => |f| if (f.inclusive) pp_format.panicf(
            "%s index %d out of range [%d,%d]",
            .{ f.which, f.raw, f.lo, f.hi },
        ) else pp_format.panicf(
            "%s index %d out of range [%d,%d)",
            .{ f.which, f.raw, f.lo, f.hi },
        ),
        // The byte is cast to `c_char` before it is passed, so a keyword byte
        // above 127 reaches "%c" as a negative int wherever `char` is signed.
        // It makes no difference to what prints -- "%c" converts its argument
        // back to an `unsigned char` -- and the cast is kept because the sign
        // is visible to anything that reads the argument as an int first.
        .bad_flag => |f| pp_format.panicf(
            "unexpected flag %c, expected one of \"%s\"",
            .{ @as(c_char, @bitCast(f.byte)), f.permitted },
        ),
        .embedded_zero => raise.panic("bytes contain embedded 0s"),
        .arity_fix => |f| pp_format.panicf(
            "arity mismatch, expected %d, got %d",
            .{ f.want, f.got },
        ),
        .arity_min => |f| pp_format.panicf(
            "arity mismatch, expected at least %d, got %d",
            .{ f.want, f.got },
        ),
        .arity_max => |f| pp_format.panicf(
            "arity mismatch, expected at most %d, got %d",
            .{ f.want, f.got },
        ),
    };
}

// ------------------------------------------------------------------ arity

pub fn fixArity(count: i32, fix: i32) raise.Raising(void) {
    var fault: Fault = undefined;
    if (!argFixarity(count, fix, &fault)) return raiseFault(null, fault);
}

pub fn checkArity(count: i32, min: i32, max: i32) raise.Raising(void) {
    var fault: Fault = undefined;
    if (!argArity(count, min, max, &fault)) return raiseFault(null, fault);
}

// ---------------------------------------------------------------- getters

/// A getter: check the type, then unwrap it.
///
/// The payload type is read off the unwrap function rather than written out
/// fourteen times, so a representation change -- `-Dnanbox=false` returns a
/// different Zig type for several of these -- cannot make the published
/// signature disagree with what the getter returns.
fn TypeGetter(comptime unwrap: anytype, comptime janet_type: repr.Tag, comptime typeflags: repr.TagSet) type {
    return struct {
        pub const Value = @typeInfo(@TypeOf(unwrap)).@"fn".return_type.?;
        pub fn get(argv: []const repr.Value, n: usize) raise.Raising(Value) {
            var fault: Fault = undefined;
            if (!argChecktype(argv, n, janet_type, typeflags, &fault)) {
                return raiseFault(argv, fault);
            }
            return unwrap(argv[n]);
        }
        pub const abi = IndexAbi(get).abi;
    };
}

/// A getter over the numeric widths, whose kernels answer through a `*Fault`
/// rather than raising.
fn ArgGetter(comptime T: type, comptime kernel: anytype) type {
    return struct {
        pub const Value = T;
        pub fn get(argv: []const repr.Value, n: usize) raise.Raising(T) {
            var fault: Fault = undefined;
            return kernel(argv, n, &fault) orelse raiseFault(argv, fault);
        }
        pub const abi = IndexAbi(get).abi;
    };
}

/// An optional argument: the default when the slot is absent or nil, and `G`'s
/// answer otherwise. The fall-through is a `return` of an error union, so a bad
/// argument does not jump out of the frame that decided to look at it.
pub fn Opt(comptime G: type) type {
    // A pointer default may be absent; a number default may not.  `[*c]` is
    // already nullable and is left alone, or the abi below would want an
    // optional in a `callconv(.c)` signature.
    const D = if (@typeInfo(G.Value) == .pointer and @typeInfo(G.Value).pointer.size != .c)
        ?G.Value
    else
        G.Value;
    return struct {
        pub fn get(argv: []const repr.Value, n: usize, dflt: D) raise.Raising(D) {
            if (argIsdefault(argv, n)) return dflt;
            return @as(D, try G.get(argv, n));
        }
    };
}

/// The three mutable containers, whose default is a fresh empty one of the
/// given capacity rather than a value the caller supplies.
pub fn OptLen(comptime G: type, comptime construct: anytype) type {
    return struct {
        pub fn get(argv: []const repr.Value, n: usize, dflt_len: usize) raise.Raising(G.Value) {
            if (argIsdefault(argv, n)) return construct(dflt_len);
            return G.get(argv, n);
        }
    };
}

pub const GetNumber = TypeGetter(wrap.toNumber, repr.Tag.number, repr.TagSet.one(.number));
pub const GetArray = TypeGetter(wrap.toArray, repr.Tag.array, repr.TagSet.one(.array));
pub const GetTuple = TypeGetter(wrap.toTuple, repr.Tag.tuple, repr.TagSet.one(.tuple));
pub const GetTable = TypeGetter(wrap.toTable, repr.Tag.table, repr.TagSet.one(.table));
pub const GetStruct = TypeGetter(wrap.toStruct, repr.Tag.@"struct", repr.TagSet.one(.@"struct"));
pub const GetString = TypeGetter(wrap.toString, repr.Tag.string, repr.TagSet.one(.string));
pub const GetKeyword = TypeGetter(wrap.toKeyword, repr.Tag.keyword, repr.TagSet.one(.keyword));
pub const GetSymbol = TypeGetter(wrap.toSymbol, repr.Tag.symbol, repr.TagSet.one(.symbol));
pub const GetBuffer = TypeGetter(wrap.toBuffer, repr.Tag.buffer, repr.TagSet.one(.buffer));
pub const GetFiber = TypeGetter(wrap.toFiber, repr.Tag.fiber, repr.TagSet.one(.fiber));
pub const GetFunction = TypeGetter(wrap.toFunction, repr.Tag.function, repr.TagSet.one(.function));
pub const GetCFunction = TypeGetter(wrap.toCfunction, repr.Tag.cfunction, repr.TagSet.one(.cfunction));
pub const GetBoolean = TypeGetter(wrap.toBoolean, repr.Tag.boolean, repr.TagSet.one(.boolean));
pub const GetPointer = TypeGetter(wrap.toPointer, repr.Tag.pointer, repr.TagSet.one(.pointer));

pub const GetNat = ArgGetter(i32, argNat);
pub const GetInteger = ArgGetter(i32, argInteger);
pub const GetUInteger = ArgGetter(u32, argUinteger);
pub const GetInteger16 = ArgGetter(i16, argInteger16);
pub const GetUInteger16 = ArgGetter(u16, argUinteger16);
pub const GetInteger8 = ArgGetter(i8, argInteger8);
pub const GetUInteger8 = ArgGetter(u8, argUinteger8);
pub const GetFloat = ArgGetter(f32, argFloat);
pub const GetSize = ArgGetter(usize, argSize);

/// With integer types enabled these accept an `int/s64` or `int/u64` abstract
/// as well as a number, and the conversion raises its own message rather than
/// filling in a fault, so the whole decision is there and there is nothing for
/// a kernel to report.
///
/// **`inttypes.unwrapS64` is reached by import and its raise is returned, and
/// the difference is not cosmetic.** A `raise.reported` form here would turn a
/// refusal into a report nobody consumes: the getter answers zero, its caller
/// carries on with a value the user never supplied, and the outstanding report
/// kills the process at the next scope boundary with a message naming neither
/// the slot nor the builtin. `(string/format "%d" "x")` is the reproduction,
/// because `pp/format.zig` is one of the callers. It is the defect
/// `tools/check/swallowed.janet` exists to find.
const int_types_enabled = options.int_types_core;

fn Wide(comptime T: type, comptime unwrap: anytype, comptime kernel: anytype) type {
    return struct {
        pub const Value = T;
        pub fn get(argv: []const repr.Value, n: usize) raise.Raising(T) {
            if (int_types_enabled) return unwrap(argv[n]);
            var fault: Fault = undefined;
            return kernel(argv, n, &fault) orelse raiseFault(argv, fault);
        }
        pub const abi = IndexAbi(get).abi;
    };
}

pub const GetInteger64 = Wide(i64, if (int_types_enabled) inttypes.unwrapS64 else {}, argInteger64);
pub const GetUInteger64 = Wide(u64, if (int_types_enabled) inttypes.unwrapU64 else {}, argUinteger64);

// ----------------------------------------------------------------- ranges

pub fn halfRange(argv: []const repr.Value, n: usize, length: i32, which: [*:0]const u8) raise.Raising(i32) {
    var fault: Fault = undefined;
    return argHalfrange(argv, n, length, which, &fault) orelse raiseFault(argv, fault);
}

pub fn argIndex(argv: []const repr.Value, n: usize, length: i32, which: [*:0]const u8) raise.Raising(i32) {
    var fault: Fault = undefined;
    return argArgindex(argv, n, length, which, &fault) orelse raiseFault(argv, fault);
}

pub fn startRange(argv: []const repr.Value, n: usize, length: i32) raise.Raising(i32) {
    if (argIsdefault(argv, n)) return 0;
    return halfRange(argv, n, length, "start");
}

pub fn endRange(argv: []const repr.Value, n: usize, length: i32) raise.Raising(i32) {
    if (argIsdefault(argv, n)) return length;
    return halfRange(argv, n, length, "end");
}

/// `access.length` can raise through this frame, which holds nothing at that
/// point.
pub fn getSlice(argv: []const repr.Value) raise.Raising(Range) {
    try checkArity(@intCast(argv.len), 1, 3);
    var range_out: Range = undefined;
    const length = try access.length(argv[0]);
    range_out.start = try startRange(argv, 1, length);
    range_out.end = try endRange(argv, 2, length);
    if (range_out.end < range_out.start) range_out.end = range_out.start;
    return range_out;
}

// ------------------------------------------------------------------ views

pub fn getIndexed(argv: []const repr.Value, n: usize) raise.Raising([]const repr.Value) {
    var fault: Fault = undefined;
    return argIndexed(argv, n, &fault) orelse raiseFault(argv, fault);
}

pub fn getDictionary(argv: []const repr.Value, n: usize) raise.Raising(DictView) {
    var fault: Fault = undefined;
    return argDictionary(argv, n, &fault) orelse raiseFault(argv, fault);
}

/// The abstract branch runs the type's `bytes` callback, which is a function
/// pointer from a native module. It runs here rather than inside `argBytes`
/// for the reason `Bytes` gives, which no longer decides anything.
pub fn getBytes(argv: []const repr.Value, n: usize) raise.Raising(abi.ByteView) {
    var fault: Fault = undefined;
    const bytes = argBytes(argv[n], n, &fault) orelse return raiseFault(argv, fault);
    return switch (bytes) {
        .view => |view| view,
        .abstract => |abst| abstractBytes(abst),
    };
}

/// The erased form, which is what `janet_getabstract` publishes and what
/// `optAbstract` and the typed form below are written over. A payload address
/// is never null -- it is a fixed offset into a block the allocator just
/// returned -- but the published signature answers a nullable pointer and the
/// boundary is where that stays.
pub fn getAbstractPtr(argv: []const repr.Value, n: usize, at: *const abi.AbstractType) raise.Raising(?*anyopaque) {
    var fault: Fault = undefined;
    return argAbstract(argv, n, at, &fault) orelse raiseFault(argv, fault);
}

/// An argument of this abstract type, already cast to its payload -- the shape
/// `module.zig` gives a module author, given to the runtime as well. The
/// runtime checked the type against `at`, so the cast is the checked one and
/// not a claim the caller is making on its own.
pub inline fn getAbstract(
    comptime T: type,
    argv: []const repr.Value,
    n: usize,
    at: *const abi.AbstractType,
) raise.Raising(*T) {
    return @ptrCast(@alignCast((try getAbstractPtr(argv, n, at)).?));
}

pub fn optAbstract(
    argv: []const repr.Value,
    n: usize,
    at: *const abi.AbstractType,
    dflt: ?*anyopaque,
) raise.Raising(?*anyopaque) {
    if (argIsdefault(argv, n)) return dflt;
    return getAbstractPtr(argv, n, at);
}

/// The non-raising probe. It is why the kernels report rather than raise:
/// this one has to answer null, not stop the caller.
pub fn checkabstract(x: repr.Value, at: *const abi.AbstractType) ?*anyopaque {
    var argv = [_]repr.Value{x};
    var fault: Fault = undefined;
    return argAbstract(&argv, 0, at, &fault);
}

// --------------------------------------------------------------- c strings

/// The two buffer shapes are carried out here rather than in the kernel: one
/// pushes a byte and one calls `janet_smalloc`, and both can raise.
pub fn getCBytes(argv: []const repr.Value, n: usize) raise.Raising([*c]const u8) {
    var fault: Fault = undefined;
    var cstr: [*c]const u8 = undefined;
    var len: usize = undefined;
    switch (argCbytes(argv, n)) {
        .copy_buffer => {
            // Make a copy with janet_smalloc in the rare case we have a buffer
            // that cannot be realloced and pushing a 0 byte would raise.
            const buffer = wrap.toBuffer(argv[n]);
            const count: usize = @intCast(buffer.count);
            const copy: [*]u8 = @ptrCast(gc_alloc.smalloc(count + 1));
            @memcpy(copy[0..count], buffer.slice()[0..count]);
            copy[count] = 0;
            cstr = copy;
            len = @intCast(buffer.count);
        },
        .copy_view => {
            // An abstract's `bytes` callback answers a view with no terminator
            // of its own, so the terminator is added here. A zero-length view
            // still gets the one byte, which is the terminator.
            const view = try getBytes(argv, n);
            const copy: [*]u8 = @ptrCast(gc_alloc.smalloc(view.len + 1));
            if (view.len != 0) @memcpy(copy[0..view.len], view.bytes.?[0..view.len]);
            copy[view.len] = 0;
            cstr = copy;
            len = view.len;
        },
        .terminate => {
            // Ensure trailing 0
            const buffer = wrap.toBuffer(argv[n]);
            try buffers.pushU8(buffer, 0);
            buffer.count -= 1;
            cstr = buffer.data;
            len = buffer.count;
        },
        .view => {
            const view = try getBytes(argv, n);
            cstr = view.bytes;
            len = view.len;
        },
    }
    if (!argZeros(cstr[0..len], &fault)) return raiseFault(argv, fault);
    return cstr;
}

pub fn getCString(argv: []const repr.Value, n: usize) raise.Raising([*c]const u8) {
    var fault: Fault = undefined;
    if (!argChecktype(argv, n, repr.Tag.string, repr.TagSet.one(.string), &fault)) {
        return raiseFault(argv, fault);
    }
    return getCBytes(argv, n);
}

pub fn optCString(argv: []const repr.Value, n: usize, dflt: [*c]const u8) raise.Raising([*c]const u8) {
    if (argIsdefault(argv, n)) return dflt;
    return getCString(argv, n);
}

pub fn optCBytes(argv: []const repr.Value, n: usize, dflt: [*c]const u8) raise.Raising([*c]const u8) {
    if (argIsdefault(argv, n)) return dflt;
    return getCBytes(argv, n);
}

// ------------------------------------------------------------------ flags

pub fn getFlags(argv: []const repr.Value, n: usize, flags: [*:0]const u8) raise.Raising(u64) {
    const keyw = try GetKeyword.get(argv, n);
    var fault: Fault = undefined;
    return argFlags(keyw, strings.head(keyw).length, flags, &fault) orelse
        raiseFault(argv, fault);
}

// ---------------------------------------------------------------- strlike

pub fn keyeq(x: repr.Value, cstring: [*:0]const u8) bool {
    return argStrlike(repr.Tag.keyword, x, cstring);
}

pub fn streq(x: repr.Value, cstring: [*:0]const u8) bool {
    return argStrlike(repr.Tag.string, x, cstring);
}

pub fn symeq(x: repr.Value, cstring: [*:0]const u8) bool {
    return argStrlike(repr.Tag.symbol, x, cstring);
}

// ---------------------------------------------------------------- methods

pub fn getmethod(
    method: [*:0]const u8,
    methods: [*]const method_type.CMethod,
    out: *repr.Value,
) c_int {
    const found = argMethod(method, methods) orelse return 0;
    out.* = wrap.fromCfunction(found.cfun);
    return 1;
}

/// The method a keyword names, or nothing.
///
/// The `?Value` form of `getmethod` above, and what an abstract type's `get`
/// callback answers: absence is `null` rather than a zero beside an
/// out-parameter the caller then has to know not to read.
pub fn findMethod(key: repr.Value, methods: [*]const method_type.CMethod) ?repr.Value {
    if (!repr.checkType(key, repr.Tag.keyword)) return null;
    const found = argMethod(wrap.toKeyword(key), methods) orelse return null;
    return wrap.fromCfunction(found.cfun);
}

/// Wrapping the name allocates, which is why the kernel stops at the entry.
pub fn nextmethod(methods: [*]const method_type.CMethod, key: repr.Value) repr.Value {
    const found = argNextmethod(methods, key);
    if (found[0].name) |name| return value.fromBytes(std.mem.span(name), .keyword);
    return wrap.fromNil();
}

// ------------------------------------------------------- the three probes
//
// The classification without the raise: what a caller that must not stop --
// the pretty printer, the bytecode reader, the compiler's constant folding --
// asks when it wants to know whether a value is indexed, byte-like or a
// dictionary, and get on with something else when it is not.
//
// They are why the kernels report into a `Fault` instead of returning
// `raise.Raising`, and the reason is internal rather than published:
// `DESIGN.md` section 11. The shape is the point -- absence is `null`, not a
// zero beside an out-parameter a caller has to know not to read.

/// A byte view as the range it describes.
///
/// `ByteView` is `extern` because an abstract type's `bytes` callback
/// answers one across the module boundary, so its two fields cannot be a
/// slice -- and its pointer is genuinely null for an empty collection:
/// `buffers.init(b, 0)` leaves `data` null and the callback may hand that
/// straight back. Slicing a null pointer traps *even for an empty range*, so
/// the recovery is here rather than at each of the forty-odd call sites.
pub inline fn viewBytes(view: abi.ByteView) []const u8 {
    if (view.bytes) |p| return p[0..view.len];
    return &.{};
}

/// The elements of anything indexed, or nothing.
pub fn indexedView(seq: repr.Value) ?[]const repr.Value {
    var argv = [_]repr.Value{seq};
    var fault: Fault = undefined;
    return argIndexed(&argv, 0, &fault);
}

/// The bytes of anything byte-like, or nothing.
///
/// The abstract arm runs third-party code, and this frame reports no raise at
/// all -- which it can do because `bytes` is one of the six callbacks that
/// cannot raise. The arm is spelled out here rather than shared with
/// `getBytes` because the two answer different types: a slice and a view.
pub fn bytesView(str: repr.Value) ?[]const u8 {
    var fault: Fault = undefined;
    const bytes = argBytes(str, 0, &fault) orelse return null;
    return switch (bytes) {
        .view => |view| viewBytes(view),
        .abstract => |abst| viewBytes(abstractBytes(abst)),
    };
}

/// The entries of a table or a struct, or nothing.
pub fn dictionaryView(tab: repr.Value) ?DictView {
    var argv = [_]repr.Value{tab};
    var fault: Fault = undefined;
    return argDictionary(&argv, 0, &fault);
}

// ------------------------------------------------- the published bridges
//
// A published getter receives a bare `const Janet *` and, in most of the
// family, no count at all: `janet_getbytes(argv, n)` has nowhere to put one.
// The Zig side of the layer takes a slice, because the tree calls it a
// thousand times and `argv[n]` should be checked; these two make the join.
//
// **A bare pointer stays here on purpose; `[*c]` did not.** `DESIGN.md`
// section 9 draws the line at the border rather than at the directory: what a
// C caller hands over *is* a bare pointer, and a slice built here would carry
// a length the caller never passed. What each bridge does is write down the
// assertion the caller is already making by calling at all.
//
// That argument is about slices, and it never reached the *spelling*. `argv`
// is `[*]const repr.Value` -- still a bare pointer, still sliced no further
// than the `n` the caller passed, and now saying that null is not among the
// things it accepts. Tightening it is what named three call sites passing the
// address of a scalar, and a `raiseFault` whose own doc comment already said
// its `argv` may be null.

/// The index family: `f(argv, n)` published as `abi(argv, n)`. Passing `n`
/// asserts that `n` is in range, so the slice is exactly long enough to hold
/// it.
///
/// Two shapes rather than five. Section 11 of `DESIGN.md` left four getters on
/// this bridge, none of them boolean and none of them past three parameters, so
/// the `bool`-to-`c_int` conversion and the arities above three are gone with
/// the surface that needed them.
fn IndexAbi(comptime f: anytype) type {
    const info = @typeInfo(@TypeOf(f)).@"fn";
    const P = @typeInfo(info.return_type.?).error_union.payload;
    return switch (info.params.len) {
        2 => struct {
            pub fn abi(argv: [*]const repr.Value, n: i32) callconv(.c) P {
                return f(argv[0..@intCast(n + 1)], @intCast(n)) catch raise.reportToC(P);
            }
        },
        3 => struct {
            pub fn abi(argv: [*]const repr.Value, n: i32, third: info.params[2].type.?) callconv(.c) P {
                return f(argv[0..@intCast(n + 1)], @intCast(n), third) catch raise.reportToC(P);
            }
        },
        else => @compileError("IndexAbi: unhandled arity"),
    };
}

// ---------------------------------------------------------------- the abis
//
// The C-ABI shims `capi.zig` publishes for a native module. Each is a
// dedicated shim with no other caller, which is why `capi.zig` states its
// signature at the `publish` rather than declaring an entry point over it.

pub const fixArityAbi = raise.panicking(fixArity).abi;
pub const checkArityAbi = raise.panicking(checkArity).abi;

pub const getAbstractAbi = IndexAbi(getAbstractPtr).abi;

// ----------------------------------------------- the Zig side of the layer
//
// Everything above has two faces: an implementation returning
// `raise.Raising(T)`, and a `raise.panicking` wrapper published under the C
// name. A Zig caller wants the first, and these are the names it is reachable
// by. Nothing here is `export`ed -- they are aliases for an importer, and the
// exported set is unchanged.
//
// The names are upstream's with the prefix dropped and the words separated,
// which is the only liberty taken: upstream's `getcstring` reads `getCString`
// here, and a reader should not have to wonder whether that is the same
// function.

/// The tree's arity checks, which take the argument slice.
///
/// `fixArity` and `checkArity` keep their count-taking form beside these,
/// because `janet_fixarity(int32_t argc, int32_t fix)` is a published entry
/// point handed a count and no `argv` at all -- there is nothing for a slice
/// to be made of. Two names for one implementation; Zig has no overloading and
/// this is the shape that would want it.
pub fn fixarity(argv: []const repr.Value, fix: i32) raise.Raising(void) {
    return fixArity(@intCast(argv.len), fix);
}

pub fn arity(argv: []const repr.Value, min: i32, max: i32) raise.Raising(void) {
    return checkArity(@intCast(argv.len), min, max);
}

/// The same two by count, for a caller that has one and no vector.
///
/// `janet_fixarity` is published this way, and `test/args_core.zig` asserts
/// against counts no contract would build a vector for -- `arityCount(99, 1,
/// -1)` says what ninety-nine arguments would do without allocating them.
pub const fixarityCount = fixArity;
pub const arityCount = checkArity;

pub const getNumber = GetNumber.get;
pub const getArray = GetArray.get;
pub const getTuple = GetTuple.get;
pub const getTable = GetTable.get;
pub const getStruct = GetStruct.get;
pub const getString = GetString.get;
pub const getKeyword = GetKeyword.get;
pub const getSymbol = GetSymbol.get;
pub const getBuffer = GetBuffer.get;
pub const getFiber = GetFiber.get;
pub const getFunction = GetFunction.get;
pub const getCFunction = GetCFunction.get;
pub const getBoolean = GetBoolean.get;
pub const getPointer = GetPointer.get;

pub const optNumber = Opt(GetNumber).get;
pub const optTuple = Opt(GetTuple).get;
pub const optStruct = Opt(GetStruct).get;
pub const optString = Opt(GetString).get;
pub const optKeyword = Opt(GetKeyword).get;
pub const optSymbol = Opt(GetSymbol).get;
pub const optFiber = Opt(GetFiber).get;
pub const optFunction = Opt(GetFunction).get;
pub const optCFunction = Opt(GetCFunction).get;
pub const optBoolean = Opt(GetBoolean).get;
pub const optPointer = Opt(GetPointer).get;

pub const optBuffer = OptLen(GetBuffer, buffers.new).get;
pub const optTable = OptLen(GetTable, tables.new).get;
pub const optArray = OptLen(GetArray, arrays.new).get;

pub const getNat = GetNat.get;
pub const getInteger = GetInteger.get;
pub const getUInteger = GetUInteger.get;
pub const getInteger16 = GetInteger16.get;
pub const getUInteger16 = GetUInteger16.get;
pub const getInteger8 = GetInteger8.get;
pub const getUInteger8 = GetUInteger8.get;
pub const getFloat = GetFloat.get;
pub const getSize = GetSize.get;
pub const getInteger64 = GetInteger64.get;
pub const getUInteger64 = GetUInteger64.get;

pub const optNat = Opt(GetNat).get;
pub const optInteger = Opt(GetInteger).get;
pub const optInteger64 = Opt(GetInteger64).get;
pub const optSize = Opt(GetSize).get;
pub const optUInteger = Opt(GetUInteger).get;
pub const optUInteger64 = Opt(GetUInteger64).get;

// `getSlice`, `getIndexed`, `getBytes` and their neighbours already wear these
// names above and are simply `pub` there; only the four range helpers need an
// alias, because the C name says `get` and the implementation does not.
pub const getHalfRange = halfRange;
pub const getArgIndex = argIndex;
pub const getStartRange = startRange;
pub const getEndRange = endRange;

// The two fault reporters never return. A Zig caller `return`s one rather than
// calling it: they answer with the bare error set, so there is nothing to
// `try`. They are `pub` above.
