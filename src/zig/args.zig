//! Argument extraction: deciding whether a cfunction's arguments are what it
//! asked for, and saying so.
//!
//! Deciding and saying are one layer here, and were not always: a getter that
//! formats its own complaint allocates, allocation can raise, and while a raise
//! was a `longjmp` no frame holding a buffer could be jumped through. So the
//! layer once reported a code plus a slot and something else turned it into a
//! message. A raise is a returned error now, so the kernels, the wording, every
//! `janet_get*` and `janet_opt*`, and the three view constructors are one
//! subsystem, selected by `-Dargs`.
//!
//! ## The fault descriptor outlives the reason it was invented
//!
//! `JanetArgFault` was a workaround, and the workaround is no longer needed;
//! it stays anyway, because the kernels have consumers that must not raise at
//! all. `janet_indexed_view`, `janet_bytes_view` and `janet_dictionary_view`
//! return 0 for a value of the wrong type and `janet_checkabstract` returns
//! NULL, and each of those is public API with that exact signature. A kernel
//! that raised would need a non-raising twin for them; a kernel that reports
//! serves both, and the wording still lives in exactly one place.
//!
//! Two of the three splits the descriptor forced are now internal rather than
//! cross-language, and both stay:
//!
//!  - **`janet_arg_bytes` classifies the abstract case instead of taking it.**
//!    A byte view of an abstract runs the type's `bytes` callback, which is a
//!    C function pointer supplied by a native module. It raises by jumping
//!    whatever language calls it, which is why this file carries the marker
//!    above; the classification is still a separate step so the kernels stay
//!    usable from `janet_bytes_view`, which may not raise.
//!  - **`janet_arg_cbytes` decides which of three shapes applies and stops.**
//!    Two of them mutate or allocate: one pushes a zero byte onto the buffer,
//!    one calls `janet_smalloc`. Both are carried out by `janet_getcbytes`.
//!
//! The third has gone: `janet_arg_nextmethod` still returns the entry rather
//! than the keyword, but `janet_nextmethod` now wraps it here.
//!
//! ## What raises, and what a raise costs
//!
//! Every exported getter has two abis. The implementation returns
//! `raise.Raising(T)` and is what the `janet_opt*` layer above it calls, so a
//! default-taking wrapper propagates an error rather than being jumped out of;
//! `raise.panicking(...).abi` generates the abi beside it, under the
//! public name. Nothing here catches its own error — the `catch` is in the
//! abi, one frame below, which is what makes the jump it delivers leave a
//! frame that owns nothing.
//!
//! The marker is not only about the `bytes` callback. `janet_getcbytes` calls
//! `janet_smalloc` and `janet_buffer_push_u8`, `janet_optbuffer` and its two
//! siblings allocate, `janet_getslice` calls `janet_length`, and with integer
//! types enabled `janet_getinteger64` calls `janet_unwrap_s64`. Every one of
//! those is a C-ABI call into another selector's subsystem, so every one of
//! them raises by jumping. This file holds nothing across any of them.
//!
//! Two pieces of the C original's arithmetic are reproduced rather than
//! repaired, and both are recorded in `FOUND.md`. The range faults widen their
//! three operands to `int64_t` before handing them to a `%d` that Janet's own
//! formatter reads as an `int32_t`; the widening is preserved here so that the
//! rendering is identical on the targets where it happens to work.
//! `janet_checkfloat` tests against `FLT_MIN`, the smallest positive *normal*
//! float, rather than `-FLT_MAX`, so `janet_getfloat` rejects zero and every
//! negative value. Neither is fixed by this port.

const std = @import("std");
const raise = @import("raise");
const pp_format = @import("pp/format.zig");
const types = @import("types");
const repr = @import("repr");
const constants = @import("constants");
const c = @import("cabi");
const access = @import("value/helpers/access.zig");
const options = @import("options");
const gc_alloc = @import("gc.zig");
const utils = @import("utils.zig");
const wrap = @import("value/helpers/wrap.zig");
pub const tables = @import("value/tables.zig");
pub const arrays = @import("value/arrays.zig");
pub const buffers = @import("value/buffers.zig");
const value = @import("value.zig");

/// The two 64-bit conversions, when the configuration has them.
///
/// `-Dint-types=false` compiles no `inttypes.zig` at all, and `Wide` below
/// names nothing in this namespace in that case -- Zig does not analyse the
/// untaken arm of a comptime-known `if`, which is what makes the empty struct
/// sufficient rather than a stub.
const inttypes = if (options.int_types_core) @import("value/ints.zig") else struct {};

// -------------------------------------------------------------- predicates

/// `janet_checkintrange` and its eight siblings in `janet.h`, written out
/// rather than translated. Each is a range test followed by a round-trip
/// through the integer type, which is what rejects a fractional value.
///
/// The round trip is where C and Zig differ in what they are *allowed* to do
/// rather than in what they produce. In C the cast of an out-of-range double
/// is undefined; here the range test always precedes it, so the conversion
/// below is in range whenever it runs, and Zig's safety check cannot fire.
/// NaN fails the first comparison in both languages and never reaches it.
fn checkRange(comptime T: type, dval: f64) bool {
    const lo: f64 = @floatFromInt(std.math.minInt(T));
    const hi: f64 = @floatFromInt(std.math.maxInt(T));
    if (!(dval >= lo and dval <= hi)) return false;
    const truncated: T = @intFromFloat(dval);
    const back: f64 = @floatFromInt(truncated);
    return dval == back;
}

fn checkNumber(comptime T: type, x: repr.Value) c_int {
    if (!repr.checkType(x, repr.Tag.number)) return 0;
    return @intFromBool(checkRange(T, wrap.toNumber(x)));
}

pub fn checkint(x: repr.Value) c_int {
    return checkNumber(i32, x);
}

pub fn checkuint(x: repr.Value) callconv(.c) c_int {
    return checkNumber(u32, x);
}

pub fn checkint16(x: repr.Value) callconv(.c) c_int {
    return checkNumber(i16, x);
}

pub fn checkuint16(x: repr.Value) callconv(.c) c_int {
    return checkNumber(u16, x);
}

pub fn checkint8(x: repr.Value) callconv(.c) c_int {
    return checkNumber(i8, x);
}

pub fn checkuint8(x: repr.Value) callconv(.c) c_int {
    return checkNumber(u8, x);
}

/// The 64-bit range is `JANET_INTMAX_DOUBLE`, not `INT64_MAX`: 2^53, the
/// largest integer a double represents exactly. Beyond it the round trip would
/// accept values a double cannot distinguish from their neighbours.
const intmax_double: f64 = 9007199254740992.0;
const intmin_double: f64 = -9007199254740992.0;

pub fn checkint64(x: repr.Value) callconv(.c) c_int {
    if (!repr.checkType(x, repr.Tag.number)) return 0;
    const dval = wrap.toNumber(x);
    if (!(dval >= intmin_double and dval <= intmax_double)) return 0;
    const truncated: i64 = @intFromFloat(dval);
    const back: f64 = @floatFromInt(truncated);
    return @intFromBool(dval == back);
}

pub fn checkuint64(x: repr.Value) callconv(.c) c_int {
    if (!repr.checkType(x, repr.Tag.number)) return 0;
    const dval = wrap.toNumber(x);
    if (!(dval >= 0 and dval <= intmax_double)) return 0;
    const truncated: u64 = @intFromFloat(dval);
    const back: f64 = @floatFromInt(truncated);
    return @intFromBool(dval == back);
}

/// `janet_checkfloatrange` tests `(x) >= FLT_MIN`, and `FLT_MIN` is the
/// smallest positive normal float rather than the most negative one. So this
/// rejects 0.0, every negative value, and every subnormal, which is almost
/// certainly not what "is this representable as a float" was meant to mean.
/// Recorded in `FOUND.md` and reproduced here: `janet_getfloat` has no caller
/// in the core, so the behavior belongs to third-party modules and changing it
/// is not this port's decision to make.
pub fn checkfloat(x: repr.Value) callconv(.c) c_int {
    if (!repr.checkType(x, repr.Tag.number)) return 0;
    const dval = wrap.toNumber(x);
    if (!(dval >= std.math.floatMin(f32) and dval <= std.math.floatMax(f32))) return 0;
    const narrowed: f32 = @floatCast(dval);
    const back: f64 = @floatCast(narrowed);
    return @intFromBool(dval == back);
}

/// The C original casts to `size_t` before testing, which is undefined for a
/// negative or enormous double and happens to saturate on every supported
/// target. The order is reversed here so the conversion is always in range;
/// every input that is defined in C reaches the same answer, and the ones that
/// are not — negatives, NaN, 1e300 — reach the same answer too, because
/// saturation and rejection agree on all of them.
pub fn checksize(x: repr.Value) callconv(.c) c_int {
    if (!repr.checkType(x, repr.Tag.number)) return 0;
    const dval = wrap.toNumber(x);
    const size_hi: f64 = @floatFromInt(std.math.maxInt(usize));
    if (!(dval >= 0 and dval <= size_hi)) return 0;
    const truncated: usize = @intFromFloat(dval);
    const back: f64 = @floatFromInt(truncated);
    if (dval != back) return 0;
    // SIZE_MAX exceeds 2^53 on every 64-bit target, so this is the branch that
    // runs there; the other is for platforms with a narrower size_t.
    if (size_hi > intmax_double) return @intFromBool(dval <= intmax_double);
    return @intFromBool(dval <= size_hi);
}

// ------------------------------------------------------------------ faults

fn faultExpect(fault: *types.JanetArgFault, expect: c_int, n: i32) void {
    fault.kind = @intCast(constants.JANET_ARG_EXPECT);
    fault.expect = @intCast(expect);
    fault.slot = n;
}

fn faultType(fault: *types.JanetArgFault, n: i32, typeflags: repr.TagSet) void {
    fault.kind = @intCast(constants.JANET_ARG_TYPE);
    fault.slot = n;
    fault.typeflags = typeflags;
}

// ----------------------------------------------------------------- getters

pub fn argChecktype(
    argv: []const repr.Value,
    n: i32,
    janet_type: repr.Tag,
    typeflags: repr.TagSet,
    fault: *types.JanetArgFault,
) c_int {
    if (repr.checkType(argv[@intCast(n)], janet_type)) return 1;
    faultType(fault, n, typeflags);
    return 0;
}

/// The shared head of every `janet_opt*`: an argument past the end of the list,
/// or an explicit nil, both mean "use the default".
pub fn argIsdefault(argv: []const repr.Value, n: i32) c_int {
    if (n >= argv.len) return 1;
    return @intFromBool(repr.checkType(argv[@intCast(n)], repr.Tag.nil));
}

/// Every width except `janet_getinteger` converts the double; that one unwraps
/// an integer, which is a distinct operation under a tagged representation
/// where an integer is not stored as a double.
fn numberGetter(
    comptime T: type,
    comptime expect: c_int,
    comptime check: fn (repr.Value) callconv(.c) c_int,
) fn ([]const repr.Value, i32, *T, *types.JanetArgFault) c_int {
    return struct {
        fn get(argv: []const repr.Value, n: i32, out: *T, fault: *types.JanetArgFault) c_int {
            const x = argv[@intCast(n)];
            if (check(x) == 0) {
                faultExpect(fault, expect, n);
                return 0;
            }
            const dval = wrap.toNumber(x);
            out.* = switch (@typeInfo(T)) {
                .float => @floatCast(dval),
                else => @intFromFloat(dval),
            };
            return 1;
        }
    }.get;
}

pub const argUinteger = numberGetter(u32, constants.JANET_ARG_EXPECT_U32, checkuint);
pub const argInteger16 = numberGetter(i16, constants.JANET_ARG_EXPECT_S16, checkint16);
pub const argUinteger16 = numberGetter(u16, constants.JANET_ARG_EXPECT_U16, checkuint16);
pub const argInteger8 = numberGetter(i8, constants.JANET_ARG_EXPECT_S8, checkint8);
pub const argUinteger8 = numberGetter(u8, constants.JANET_ARG_EXPECT_U8, checkuint8);
pub const argFloat = numberGetter(f32, constants.JANET_ARG_EXPECT_FLOAT, checkfloat);
pub const argInteger64 = numberGetter(i64, constants.JANET_ARG_EXPECT_S64, checkint64);
pub const argUinteger64 = numberGetter(u64, constants.JANET_ARG_EXPECT_U64, checkuint64);
pub const argSize = numberGetter(usize, constants.JANET_ARG_EXPECT_SIZE, checksize);

pub fn argInteger(argv: []const repr.Value, n: i32, out: *i32, fault: *types.JanetArgFault) c_int {
    const x = argv[@intCast(n)];
    if (checkint(x) == 0) {
        faultExpect(fault, constants.JANET_ARG_EXPECT_S32, n);
        return 0;
    }
    out.* = wrap.toInteger(x);
    return 1;
}

pub fn argNat(argv: []const repr.Value, n: i32, out: *i32, fault: *types.JanetArgFault) c_int {
    const x = argv[@intCast(n)];
    if (checkint(x) != 0) {
        const ret = wrap.toInteger(x);
        if (ret >= 0) {
            out.* = ret;
            return 1;
        }
    }
    faultExpect(fault, constants.JANET_ARG_EXPECT_NAT, n);
    return 0;
}

pub fn argAbstract(
    argv: []const repr.Value,
    n: i32,
    at: *const types.AbstractType,
    out: *?*anyopaque,
    fault: *types.JanetArgFault,
) c_int {
    const x = argv[@intCast(n)];
    if (repr.checkType(x, repr.Tag.abstract)) {
        const abstractx = wrap.toAbstract(x);
        if (types.abstractHead(abstractx).type == at) {
            out.* = abstractx;
            return 1;
        }
    }
    fault.kind = @intCast(constants.JANET_ARG_ABSTRACT);
    fault.slot = n;
    fault.at = at;
    return 0;
}

// ------------------------------------------------------------------- views

pub fn argIndexed(
    argv: []const repr.Value,
    n: i32,
    out: *types.JanetView,
    fault: *types.JanetArgFault,
) c_int {
    const x = argv[@intCast(n)];
    if (repr.checkType(x, repr.Tag.array)) {
        const array = wrap.toArray(x);
        out.items = array.*.data;
        out.len = array.*.count;
        return 1;
    } else if (repr.checkType(x, repr.Tag.tuple)) {
        const tuple = wrap.toTuple(x);
        out.items = tuple;
        out.len = types.tupleHead(tuple).length;
        return 1;
    }
    faultType(fault, n, repr.TagSet.indexed);
    return 0;
}

pub fn argDictionary(
    argv: []const repr.Value,
    n: i32,
    out: *types.JanetDictView,
    fault: *types.JanetArgFault,
) c_int {
    const x = argv[@intCast(n)];
    if (repr.checkType(x, repr.Tag.table)) {
        const table = wrap.toTable(x);
        out.kvs = table.*.data.?;
        out.cap = table.*.capacity;
        out.len = table.*.count;
        return 1;
    } else if (repr.checkType(x, repr.Tag.@"struct")) {
        const structure = wrap.toStruct(x);
        out.kvs = structure;
        out.cap = types.structHead(structure).capacity;
        out.len = types.structHead(structure).length;
        return 1;
    }
    faultType(fault, n, repr.TagSet.dictionary);
    return 0;
}

/// Classifies, and for the abstract case stops. Running `bytes` here would put
/// third-party code below a frame that must not be jumped through.
pub fn argBytes(
    x: repr.Value,
    n: i32,
    out: *types.JanetByteView,
    fault: *types.JanetArgFault,
) callconv(.c) c_uint {
    switch (repr.typeOf(x)) {
        repr.Tag.string, repr.Tag.symbol, repr.Tag.keyword => {
            const string = wrap.toString(x);
            out.bytes = string;
            out.len = types.stringHead(string).length;
            return @intCast(constants.JANET_ARG_BYTES_STRING);
        },
        repr.Tag.buffer => {
            const buffer = wrap.toBuffer(x);
            out.bytes = buffer.*.data.?;
            out.len = buffer.*.count;
            return @intCast(constants.JANET_ARG_BYTES_BUFFER);
        },
        repr.Tag.abstract => {
            const abst = wrap.toAbstract(x);
            if (types.abstractHead(abst).type.*.bytes != null) {
                return @intCast(constants.JANET_ARG_BYTES_ABSTRACT);
            }
        },
        else => {},
    }
    faultType(fault, n, repr.TagSet.bytes);
    return @intCast(constants.JANET_ARG_BYTES_FAULT);
}

/// Which shape `janet_getcbytes` must use. Both buffer shapes mutate or
/// allocate, so neither is carried out here; the third is an ordinary byte
/// view and its own failure is reported by `janet_arg_bytes`.
pub fn argCbytes(argv: []const repr.Value, n: i32, fault: *types.JanetArgFault) c_uint {
    _ = fault;
    const x = argv[@intCast(n)];
    if (repr.checkType(x, repr.Tag.buffer)) {
        const buffer = wrap.toBuffer(x);
        const no_realloc: i32 = @intCast(constants.JANET_BUFFER_FLAG_NO_REALLOC);
        if ((buffer.*.gc.flags & no_realloc) != 0 and buffer.*.count == buffer.*.capacity) {
            return @intCast(constants.JANET_ARG_CBYTES_COPY);
        }
        return @intCast(constants.JANET_ARG_CBYTES_TERMINATE);
    }
    return @intCast(constants.JANET_ARG_CBYTES_VIEW);
}

pub fn argZeros(bytes: [*:0]const u8, len: i32, fault: *types.JanetArgFault) c_int {
    if (std.mem.len(bytes) == @as(usize, @intCast(len))) return 1;
    fault.kind = @intCast(constants.JANET_ARG_ZEROS);
    return 0;
}

// ------------------------------------------------------------------ ranges

/// `janet_gethalfrange` and `janet_getargindex` differ in two places and are
/// otherwise the same walk: the half-range folds a negative index against
/// `length + 1` and reports a closed interval, the argument index folds against
/// `length` and reports a half-open one. Both accept `length` itself.
fn range(
    argv: []const repr.Value,
    n: i32,
    length: i32,
    which: [*:0]const u8,
    out: *i32,
    fault: *types.JanetArgFault,
    comptime inclusive: bool,
) c_int {
    var raw: i32 = undefined;
    if (argInteger(argv, n, &raw, fault) == 0) return 0;
    const fold: i64 = if (inclusive) @as(i64, length) + 1 else @as(i64, length);
    var not_raw: i64 = raw;
    if (not_raw < 0) not_raw += fold;
    if (not_raw < 0 or not_raw > length) {
        fault.kind = @intCast(if (inclusive)
            constants.JANET_ARG_RANGE_INCLUSIVE
        else
            constants.JANET_ARG_RANGE_EXCLUSIVE);
        fault.which = which;
        // Widened to int64_t exactly as the C original widens them, for a "%d"
        // that reads an int32_t. See FOUND.md; reproduced, not repaired.
        fault.raw = raw;
        fault.lo = -fold;
        fault.hi = length;
        return 0;
    }
    out.* = @intCast(not_raw);
    return 1;
}

pub fn argHalfrange(
    argv: []const repr.Value,
    n: i32,
    length: i32,
    which: [*:0]const u8,
    out: *i32,
    fault: *types.JanetArgFault,
) c_int {
    return range(argv, n, length, which, out, fault, true);
}

pub fn argArgindex(
    argv: []const repr.Value,
    n: i32,
    length: i32,
    which: [*:0]const u8,
    out: *i32,
    fault: *types.JanetArgFault,
) c_int {
    return range(argv, n, length, which, out, fault, false);
}

// ------------------------------------------------------------------- flags

/// The 64-flag ceiling is the C original's, and it truncates silently rather
/// than reporting: a `flags` string longer than 64 characters has its tail
/// ignored, so a keyword naming one of those characters is rejected as
/// unexpected. Preserved.
pub fn argFlags(
    keyw: [*]const u8,
    klen: i32,
    flags: [*:0]const u8,
    out: *u64,
    fault: *types.JanetArgFault,
) callconv(.c) c_int {
    var ret: u64 = 0;
    var flen: usize = std.mem.len(flags);
    if (flen > 64) flen = 64;
    var j: usize = 0;
    while (j < @as(usize, @intCast(klen))) : (j += 1) {
        var i: usize = 0;
        while (i < flen) : (i += 1) {
            if (flags[i] == keyw[j]) {
                ret |= @as(u64, 1) << @intCast(i);
                break;
            }
        }
        if (i == flen) {
            fault.kind = @intCast(constants.JANET_ARG_FLAG);
            fault.raw = keyw[j];
            fault.flags = flags;
            return 0;
        }
    }
    out.* = ret;
    return 1;
}

// ------------------------------------------------------------------- arity

pub fn argFixarity(count: i32, fix: i32, fault: *types.JanetArgFault) c_int {
    if (count == fix) return 1;
    fault.kind = @intCast(constants.JANET_ARG_ARITY_FIX);
    fault.arity = count;
    fault.bound = fix;
    return 0;
}

/// A negative bound means "unbounded on that side", which is how a cfunction
/// with no maximum spells itself.
pub fn argArity(count: i32, min: i32, max: i32, fault: *types.JanetArgFault) c_int {
    if (min >= 0 and count < min) {
        fault.kind = @intCast(constants.JANET_ARG_ARITY_MIN);
        fault.arity = count;
        fault.bound = min;
        return 0;
    }
    if (max >= 0 and count > max) {
        fault.kind = @intCast(constants.JANET_ARG_ARITY_MAX);
        fault.arity = count;
        fault.bound = max;
        return 0;
    }
    return 1;
}

// ----------------------------------------------------------------- strlike

pub fn argStrlike(janet_type: repr.Tag, x: repr.Value, cstring: [*:0]const u8) c_int {
    if (repr.typeOf(x) != janet_type) return 0;
    return @intFromBool(utils.cstrcmp(wrap.toString(x), cstring) == 0);
}

// ----------------------------------------------------------------- methods

pub fn argMethod(
    method: [*:0]const u8,
    methods: [*]const types.JanetMethod,
    out: *[*]const types.JanetMethod,
) callconv(.c) c_int {
    var entry = methods;
    while (entry[0].name) |name| : (entry += 1) {
        if (utils.cstrcmp(method, name) == 0) {
            out.* = entry;
            return 1;
        }
    }
    return 0;
}

/// Returns the entry whose name the caller should wrap as a keyword, or the
/// terminating entry — the one with a null name — when the walk runs off the
/// end. Wrapping allocates, so it is not done here.
///
/// The C original advances past the matched entry *and* past every entry it
/// rejects, which is what makes this an iterator rather than a lookup: a nil
/// key starts at the head, and any other key resumes after the one it names.
pub fn argNextmethod(
    methods: [*]const types.JanetMethod,
    key: repr.Value,
) callconv(.c) [*]const types.JanetMethod {
    var entry = methods;
    if (!repr.checkType(key, repr.Tag.nil)) {
        while (entry[0].name) |name| {
            const matched = keyeq(key, name) != 0;
            entry += 1;
            if (matched) break;
        }
    }
    return entry;
}

// ====================================================================
// The exported surface.
//
// Each entry is a kernel call and, on failure, a raise -- a returned error
// rather than a jump, so `janet_opt*` can propagate what `janet_get*` decided
// instead of being jumped out of.
// ====================================================================

// ----------------------------------------------------------------- wording

/// The only place the nouns appear. A getter reports `JANET_ARG_EXPECT_S16`
/// and this decides it is spelled "16 bit signed integer", which is what makes
/// the two implementations word-identical without either of them formatting.
fn expectName(expect: u8) [*:0]const u8 {
    return switch (@as(c_uint, expect)) {
        constants.JANET_ARG_EXPECT_NAT => "non-negative 32 bit signed integer",
        constants.JANET_ARG_EXPECT_SIZE => "size",
        constants.JANET_ARG_EXPECT_S32 => "32 bit signed integer",
        constants.JANET_ARG_EXPECT_U32 => "32 bit unsigned integer",
        constants.JANET_ARG_EXPECT_S16 => "16 bit signed integer",
        constants.JANET_ARG_EXPECT_U16 => "16 bit unsigned integer",
        constants.JANET_ARG_EXPECT_S8 => "8 bit signed integer",
        constants.JANET_ARG_EXPECT_U8 => "8 bit unsigned integer",
        constants.JANET_ARG_EXPECT_FLOAT => "float number",
        constants.JANET_ARG_EXPECT_S64 => "64 bit signed integer",
        else => "64 bit unsigned integer",
    };
}

// ------------------------------------------------------------ the two slot
// diagnostics, which are public API of their own

/// `janet_panic_type`. It lives with the argument layer rather than with the
/// rest of the panic family in `signal_core.zig` for a reason the seam
/// decides: `raiseFault` needs the *error*, not the jump, and an error union
/// cannot cross the C ABI between two selectable subsystems. Keeping the two
/// slot diagnostics here keeps their format strings in one place and lets the
/// fault path return.
pub fn panicType(x: repr.Value, n: i32, expected: repr.TagSet) raise.Error {
    return pp_format.panicf("bad slot #%d, expected %T, got %v", .{ n, expected, x });
}

pub fn panicAbstract(x: repr.Value, n: i32, at: *const types.AbstractType) raise.Error {
    return pp_format.panicf("bad slot #%d, expected %s, got %v", .{ n, at.name, x });
}

/// The abi keeps Janet's `int`. A mask bit above fifteen names no tag, so the
/// narrowing loses nothing; the internal set is sixteen bits wide and this is
/// one of the two symbols that convert.
pub fn panicTypeAbi(x: repr.Value, n: i32, expected: c_int) void {
    raise.report(panicType(x, n, repr.TagSet.fromBits(@truncate(@as(c_uint, @bitCast(expected))))));
}

pub fn panicAbstractAbi(x: repr.Value, n: i32, at: *const types.AbstractType) void {
    raise.report(panicAbstract(x, n, at));
}

// -------------------------------------------------------------- the raise

/// The argument a fault names. Read inside the three slot kinds and nowhere
/// else. The other eight leave `slot` unwritten -- a kernel fills in only the
/// fields its message uses -- and the two arity kinds are raised with a null
/// `argv` besides, having no argument list to name. Reading either at the head
/// of `raiseFault` instead of inside the branch is the mistake this exists to
/// make visible; `test/args_core.zig` catches it on its first assertion.
inline fn slotOf(argv: ?[]const repr.Value, fault: *const types.JanetArgFault) repr.Value {
    // The `.?` is the claim the doc comment on `raiseFault` already makes:
    // only the kinds that name a slot reach here.
    return argv.?[@intCast(fault.slot)];
}

/// Turn a filled-in `JanetArgFault` into the message the C original raised.
///
/// `argv` may be null for the kinds that do not name a slot -- the arity
/// kinds, the range kinds, the flag kind and the embedded-zero kind all render
/// without touching the argument.
fn raiseFault(argv: ?[]const repr.Value, fault: *const types.JanetArgFault) raise.Error {
    return switch (@as(c_uint, fault.kind)) {
        constants.JANET_ARG_TYPE => panicType(slotOf(argv, fault), fault.slot, fault.typeflags),
        constants.JANET_ARG_ABSTRACT => panicAbstract(slotOf(argv, fault), fault.slot, fault.at.?),
        constants.JANET_ARG_EXPECT => pp_format.panicf(
            "bad slot #%d, expected %s, got %v",
            .{ fault.slot, expectName(fault.expect), slotOf(argv, fault) },
        ),
        // The three int64_t arguments to "%d" below are the C original's, and
        // C's "%d" read an int32_t from the va_list before widening it, which
        // is undefined and is recorded in FOUND.md. It was reproduced here
        // while the other implementation was C and could be compared against.
        // There is no va_list here: "%d" renders the 64 bits its specifier
        // always asked for, so these are simply correct. The digits are
        // unchanged for any index that fits in an int32_t, which is every
        // index either implementation was ever observed on.
        constants.JANET_ARG_RANGE_INCLUSIVE => pp_format.panicf(
            "%s index %d out of range [%d,%d]",
            .{ fault.which, fault.raw, fault.lo, fault.hi },
        ),
        constants.JANET_ARG_RANGE_EXCLUSIVE => pp_format.panicf(
            "%s index %d out of range [%d,%d)",
            .{ fault.which, fault.raw, fault.lo, fault.hi },
        ),
        // The C original casts the byte to `char` before the variadic
        // promotion, so a keyword byte above 127 reaches "%c" as a negative int
        // wherever `char` is signed. It makes no difference to what prints --
        // "%c" converts its argument back to an `unsigned char` -- but the cast
        // is reproduced rather than dropped, because the sign is visible to
        // anything that reads the argument as an int first.
        constants.JANET_ARG_FLAG => pp_format.panicf(
            "unexpected flag %c, expected one of \"%s\"",
            .{ @as(c_char, @bitCast(@as(u8, @truncate(@as(u64, @bitCast(fault.raw)))))), fault.flags },
        ),
        constants.JANET_ARG_ZEROS => raise.panic("bytes contain embedded 0s"),
        constants.JANET_ARG_ARITY_FIX => pp_format.panicf(
            "arity mismatch, expected %d, got %d",
            .{ fault.bound, fault.arity },
        ),
        constants.JANET_ARG_ARITY_MIN => pp_format.panicf(
            "arity mismatch, expected at least %d, got %d",
            .{ fault.bound, fault.arity },
        ),
        constants.JANET_ARG_ARITY_MAX => pp_format.panicf(
            "arity mismatch, expected at most %d, got %d",
            .{ fault.bound, fault.arity },
        ),
        else => raise.panic("argument fault with no kind"),
    };
}

/// The abi of `raiseFault`, still declared in `state.h` because the kernels
/// are usable on their own and a C caller of one needs a way to report what it
/// found. `janet_arg_raise` never returns, so there is no error to hand back
/// and `raise.panicking` does not apply.
pub fn argRaise(argv: ?[*]const repr.Value, fault: *const types.JanetArgFault) void {
    raise.report(raiseFault(argv, fault));
}

// ------------------------------------------------------------------ arity

fn fixArity(count: i32, fix: i32) raise.Raising(void) {
    var fault: types.JanetArgFault = undefined;
    if (argFixarity(count, fix, &fault) == 0) return raiseFault(null, &fault);
}

fn checkArity(count: i32, min: i32, max: i32) raise.Raising(void) {
    var fault: types.JanetArgFault = undefined;
    if (argArity(count, min, max, &fault) == 0) return raiseFault(null, &fault);
}

// ---------------------------------------------------------------- getters

/// `DEFINE_GETTER` from `capi.c`: check the type, then unwrap it.
///
/// The payload type is read off the unwrap function rather than written out
/// fourteen times, so a representation change -- `-Dnanbox=false` returns a
/// different Zig type for several of these -- cannot make the exported
/// signature disagree with `janet.h`.
fn TypeGetter(comptime unwrap: anytype, comptime janet_type: repr.Tag, comptime typeflags: repr.TagSet) type {
    return struct {
        pub const Value = @typeInfo(@TypeOf(unwrap)).@"fn".return_type.?;
        pub fn get(argv: []const repr.Value, n: i32) raise.Raising(Value) {
            var fault: types.JanetArgFault = undefined;
            if (argChecktype(argv, n, janet_type, typeflags, &fault) == 0) {
                return raiseFault(argv, &fault);
            }
            return unwrap(argv[@intCast(n)]);
        }
        pub const abi = IndexAbi(get).abi;
    };
}

/// `DEFINE_ARG_GETTER`: the numeric widths, whose kernels answer with an
/// out-parameter and an expectation code.
fn ArgGetter(comptime T: type, comptime kernel: anytype) type {
    return struct {
        pub const Value = T;
        pub fn get(argv: []const repr.Value, n: i32) raise.Raising(T) {
            var out: T = undefined;
            var fault: types.JanetArgFault = undefined;
            if (kernel(argv, n, &out, &fault) == 0) return raiseFault(argv, &fault);
            return out;
        }
        pub const abi = IndexAbi(get).abi;
    };
}

/// `DEFINE_OPT` and `DEFINE_ARG_OPT`, which differ only in which getter they
/// fall through to. The fall-through is a `return` of an error union, so a bad
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
        pub fn get(argv: []const repr.Value, n: i32, dflt: D) raise.Raising(D) {
            if (argIsdefault(argv, n) != 0) return dflt;
            return @as(D, try G.get(argv, n));
        }
        pub const abi = CountAbi(get).abi;
    };
}

/// `DEFINE_OPTLEN`: the three mutable containers, whose default is a fresh
/// empty one of the given capacity rather than a value the caller supplies.
pub fn OptLen(comptime G: type, comptime construct: anytype) type {
    return struct {
        pub fn get(argv: []const repr.Value, n: i32, dflt_len: i32) raise.Raising(G.Value) {
            if (argIsdefault(argv, n) != 0) return construct(dflt_len);
            return G.get(argv, n);
        }
        pub const abi = CountAbi(get).abi;
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
/// **The conversion is reached by import rather than through its abi, and the
/// difference is not cosmetic.** `janet_unwrap_s64` is `raise.reported` over
/// `ints.unwrapS64`, so calling *it* from inside a `raise.Raising` function
/// would turn a refusal into a report nobody consumes: the getter answers
/// zero, its caller carries on with a value the user never supplied, and the
/// outstanding report kills the process at the next scope boundary with a
/// message naming neither the slot nor the builtin. `(string/format "%d" "x")`
/// reproduced exactly that, because `pp/format.zig` is one of the seven
/// callers. It is the defect `tools/check/swallowed.janet` exists to find.
const int_types_enabled = options.int_types_core;

fn Wide(comptime T: type, comptime unwrap: anytype, comptime kernel: anytype) type {
    return struct {
        pub const Value = T;
        pub fn get(argv: []const repr.Value, n: i32) raise.Raising(T) {
            if (int_types_enabled) return unwrap(argv[@intCast(n)]);
            var out: T = undefined;
            var fault: types.JanetArgFault = undefined;
            if (kernel(argv, n, &out, &fault) == 0) return raiseFault(argv, &fault);
            return out;
        }
        pub const abi = IndexAbi(get).abi;
    };
}

pub const GetInteger64 = Wide(i64, if (int_types_enabled) inttypes.unwrapS64 else {}, argInteger64);
pub const GetUInteger64 = Wide(u64, if (int_types_enabled) inttypes.unwrapU64 else {}, argUinteger64);

// ----------------------------------------------------------------- ranges

pub fn halfRange(argv: []const repr.Value, n: i32, length: i32, which: [*:0]const u8) raise.Raising(i32) {
    var out: i32 = undefined;
    var fault: types.JanetArgFault = undefined;
    if (argHalfrange(argv, n, length, which, &out, &fault) == 0) return raiseFault(argv, &fault);
    return out;
}

pub fn argIndex(argv: []const repr.Value, n: i32, length: i32, which: [*:0]const u8) raise.Raising(i32) {
    var out: i32 = undefined;
    var fault: types.JanetArgFault = undefined;
    if (argArgindex(argv, n, length, which, &out, &fault) == 0) return raiseFault(argv, &fault);
    return out;
}

pub fn startRange(argv: []const repr.Value, n: i32, length: i32) raise.Raising(i32) {
    if (argIsdefault(argv, n) != 0) return 0;
    return halfRange(argv, n, length, "start");
}

pub fn endRange(argv: []const repr.Value, n: i32, length: i32) raise.Raising(i32) {
    if (argIsdefault(argv, n) != 0) return length;
    return halfRange(argv, n, length, "end");
}

/// `janet_length` is a C-ABI call into `-Dvalue-access` and raises by jumping
/// through this frame, which holds nothing at that point.
pub fn getSlice(argv: []const repr.Value) raise.Raising(types.JanetRange) {
    try checkArity(@intCast(argv.len), 1, 3);
    var range_out: types.JanetRange = undefined;
    const length = try access.length(argv[0]);
    range_out.start = try startRange(argv, 1, length);
    range_out.end = try endRange(argv, 2, length);
    if (range_out.end < range_out.start) range_out.end = range_out.start;
    return range_out;
}

// ------------------------------------------------------------------ views

pub fn getIndexed(argv: []const repr.Value, n: i32) raise.Raising(types.JanetView) {
    var view: types.JanetView = undefined;
    var fault: types.JanetArgFault = undefined;
    if (argIndexed(argv, n, &view, &fault) == 0) return raiseFault(argv, &fault);
    return view;
}

pub fn getDictionary(argv: []const repr.Value, n: i32) raise.Raising(types.JanetDictView) {
    var view: types.JanetDictView = undefined;
    var fault: types.JanetArgFault = undefined;
    if (argDictionary(argv, n, &view, &fault) == 0) return raiseFault(argv, &fault);
    return view;
}

/// The abstract branch runs the type's `bytes` callback, which is a C function
/// pointer from a native module: third-party code that raises by jumping. It
/// runs outside the kernel so that a caller which may not raise at all --
/// `janet_bytes_view` below -- can still use the classification.
pub fn getBytes(argv: []const repr.Value, n: i32) raise.Raising(types.JanetByteView) {
    var view: types.JanetByteView = undefined;
    var fault: types.JanetArgFault = undefined;
    switch (argBytes(argv[@intCast(n)], n, &view, &fault)) {
        constants.JANET_ARG_BYTES_STRING, constants.JANET_ARG_BYTES_BUFFER => return view,
        constants.JANET_ARG_BYTES_ABSTRACT => {
            const abst = wrap.toAbstract(argv[@intCast(n)]);
            return types.abstractHead(abst).type.*.bytes.?(abst, types.abstractHead(abst).size);
        },
        else => return raiseFault(argv, &fault),
    }
}

pub fn getAbstract(argv: []const repr.Value, n: i32, at: *const types.AbstractType) raise.Raising(?*anyopaque) {
    var out: ?*anyopaque = undefined;
    var fault: types.JanetArgFault = undefined;
    if (argAbstract(argv, n, at, &out, &fault) == 0) return raiseFault(argv, &fault);
    return out;
}

pub fn optAbstract(
    argv: []const repr.Value,
    n: i32,
    at: *const types.AbstractType,
    dflt: ?*anyopaque,
) raise.Raising(?*anyopaque) {
    if (argIsdefault(argv, n) != 0) return dflt;
    return getAbstract(argv, n, at);
}

/// The public non-raising probe. It is why the kernels report rather than
/// raise: this one has to answer NULL, not stop the caller.
pub fn checkabstract(x: repr.Value, at: *const types.AbstractType) ?*anyopaque {
    var argv = [_]repr.Value{x};
    var out: ?*anyopaque = undefined;
    var fault: types.JanetArgFault = undefined;
    if (argAbstract(&argv, 0, at, &out, &fault) == 0) return null;
    return out;
}

// --------------------------------------------------------------- c strings

/// The two buffer shapes are carried out here rather than in the kernel: one
/// pushes a byte and one calls `janet_smalloc`, and both can raise.
pub fn getCBytes(argv: []const repr.Value, n: i32) raise.Raising([*c]const u8) {
    var fault: types.JanetArgFault = undefined;
    var cstr: [*c]const u8 = undefined;
    var len: i32 = undefined;
    switch (argCbytes(argv, n, &fault)) {
        constants.JANET_ARG_CBYTES_COPY => {
            // Make a copy with janet_smalloc in the rare case we have a buffer
            // that cannot be realloced and pushing a 0 byte would raise.
            const buffer = wrap.toBuffer(argv[@intCast(n)]);
            const count: usize = @intCast(buffer.*.count);
            const copy: [*]u8 = @ptrCast(gc_alloc.smalloc(count + 1));
            @memcpy(copy[0..count], buffer.*.slice()[0..count]);
            copy[count] = 0;
            cstr = copy;
            len = buffer.*.count;
        },
        constants.JANET_ARG_CBYTES_TERMINATE => {
            // Ensure trailing 0
            const buffer = wrap.toBuffer(argv[@intCast(n)]);
            try buffers.pushU8(buffer, 0);
            buffer.*.count -= 1;
            cstr = buffer.*.data;
            len = buffer.*.count;
        },
        else => {
            const view = try getBytes(argv, n);
            cstr = view.bytes;
            len = view.len;
        },
    }
    if (argZeros(cstr, len, &fault) == 0) return raiseFault(argv, &fault);
    return cstr;
}

pub fn getCString(argv: []const repr.Value, n: i32) raise.Raising([*c]const u8) {
    var fault: types.JanetArgFault = undefined;
    if (argChecktype(argv, n, repr.Tag.string, repr.TagSet.one(.string), &fault) == 0) {
        return raiseFault(argv, &fault);
    }
    return getCBytes(argv, n);
}

pub fn optCString(argv: []const repr.Value, n: i32, dflt: [*c]const u8) raise.Raising([*c]const u8) {
    if (argIsdefault(argv, n) != 0) return dflt;
    return getCString(argv, n);
}

pub fn optCBytes(argv: []const repr.Value, n: i32, dflt: [*c]const u8) raise.Raising([*c]const u8) {
    if (argIsdefault(argv, n) != 0) return dflt;
    return getCBytes(argv, n);
}

// ------------------------------------------------------------------ flags

pub fn getFlags(argv: []const repr.Value, n: i32, flags: [*:0]const u8) raise.Raising(u64) {
    const keyw = try GetKeyword.get(argv, n);
    var out: u64 = undefined;
    var fault: types.JanetArgFault = undefined;
    if (argFlags(keyw, types.stringHead(keyw).length, flags, &out, &fault) == 0) {
        return raiseFault(argv, &fault);
    }
    return out;
}

// ---------------------------------------------------------------- strlike

pub fn keyeq(x: repr.Value, cstring: [*:0]const u8) c_int {
    return argStrlike(repr.Tag.keyword, x, cstring);
}

pub fn streq(x: repr.Value, cstring: [*:0]const u8) c_int {
    return argStrlike(repr.Tag.string, x, cstring);
}

pub fn symeq(x: repr.Value, cstring: [*:0]const u8) c_int {
    return argStrlike(repr.Tag.symbol, x, cstring);
}

// ---------------------------------------------------------------- methods

pub fn getmethod(
    method: [*:0]const u8,
    methods: [*]const types.JanetMethod,
    out: *repr.Value,
) callconv(.c) c_int {
    var found: [*]const types.JanetMethod = undefined;
    if (argMethod(method, methods, &found) == 0) return 0;
    out.* = wrap.fromCfunction(found[0].cfun);
    return 1;
}

/// Wrapping the name allocates, which is why the kernel stops at the entry.
pub fn nextmethod(methods: [*]const types.JanetMethod, key: repr.Value) repr.Value {
    const found = argNextmethod(methods, key);
    if (found[0].name) |name| return value.fromBytes(std.mem.span(name), .keyword);
    return wrap.fromNil();
}

// ------------------------------------------------------- the view builders
//
// These moved out of `util.c` with the layer they are built on. All three are
// public API with a fixed signature that reports failure by returning 0, which
// is the constraint that keeps the kernels non-raising.

/// A view as the range it describes.
///
/// The three view structs are `extern`, so their two fields cannot be a slice
/// -- and their pointer is genuinely null for an empty collection:
/// `janet_array_init(a, 0)` and `janet_buffer_init(b, 0)` each leave `data`
/// NULL, and `janet_indexed_view` hands that straight back. Slicing a null
/// pointer traps *even for an empty range*, which is the hazard `capi.zig`'s
/// `cbytes` exists for, so the recovery is here rather than at each of the
/// forty-odd call sites.
pub inline fn viewBytes(view: types.JanetByteView) []const u8 {
    if (view.bytes) |p| return p[0..@intCast(view.len)];
    return &.{};
}

pub inline fn viewItems(view: types.JanetView) []const repr.Value {
    if (view.items) |p| return p[0..@intCast(view.len)];
    return &.{};
}

pub inline fn viewKvs(view: types.JanetDictView) []const types.JanetKV {
    if (view.kvs) |p| return p[0..@intCast(view.len)];
    return &.{};
}

pub fn indexedView(seq: repr.Value, data: *?[*]const repr.Value, len: *i32) c_int {
    var argv = [_]repr.Value{seq};
    var view: types.JanetView = undefined;
    var fault: types.JanetArgFault = undefined;
    if (argIndexed(&argv, 0, &view, &fault) == 0) return 0;
    data.* = view.items;
    len.* = view.len;
    return 1;
}

pub fn bytesView(str: repr.Value, data: *?[*]const u8, len: *i32) c_int {
    var view: types.JanetByteView = undefined;
    var fault: types.JanetArgFault = undefined;
    switch (argBytes(str, 0, &view, &fault)) {
        constants.JANET_ARG_BYTES_STRING, constants.JANET_ARG_BYTES_BUFFER => {},
        constants.JANET_ARG_BYTES_ABSTRACT => {
            // Third-party code, and the reason the classification above is a
            // separate step: it raises by jumping, and this frame may not
            // report a raise at all.
            const abst = wrap.toAbstract(str);
            view = types.abstractHead(abst).type.*.bytes.?(abst, types.abstractHead(abst).size);
        },
        else => return 0,
    }
    data.* = view.bytes;
    len.* = view.len;
    return 1;
}

pub fn dictionaryView(
    tab: repr.Value,
    data: *?[*]const types.JanetKV,
    len: *i32,
    cap: *i32,
) callconv(.c) c_int {
    var argv = [_]repr.Value{tab};
    var view: types.JanetDictView = undefined;
    var fault: types.JanetArgFault = undefined;
    if (argDictionary(&argv, 0, &view, &fault) == 0) return 0;
    data.* = view.kvs;
    len.* = view.len;
    cap.* = view.cap;
    return 1;
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

/// The C ABI has no `bool`. Janet declares `janet_getboolean` and
/// `janet_optboolean` returning `int`, and Zig's `bool` is one byte, so the
/// two bridges below convert -- once here rather than at each symbol, which is
/// also what keeps `capi.zig` mechanical rather than hand-patched.
fn Abi(comptime T: type) type {
    return if (T == bool) c_int else T;
}
inline fn toAbi(comptime T: type, v: T) Abi(T) {
    return if (T == bool) @intFromBool(v) else v;
}
inline fn fromAbi(comptime T: type, v: Abi(T)) T {
    return if (T == bool) v != 0 else v;
}

/// The index family: `f(argv, n, ...)` published as `abi(argv, n, ...)`.
/// Passing `n` asserts that `n` is in range, so the slice is exactly long
/// enough to hold it.
fn IndexAbi(comptime f: anytype) type {
    const info = @typeInfo(@TypeOf(f)).@"fn";
    const P = @typeInfo(info.return_type.?).error_union.payload;
    const p = info.params;
    return switch (p.len) {
        2 => struct {
            pub fn abi(argv: [*]const repr.Value, n: i32) callconv(.c) Abi(P) {
                return toAbi(P, f(argv[0..@intCast(n + 1)], n) catch raise.reportToC(P));
            }
        },
        3 => struct {
            pub fn abi(argv: [*]const repr.Value, n: i32, third: Abi(p[2].type.?)) callconv(.c) Abi(P) {
                return toAbi(P, f(argv[0..@intCast(n + 1)], n, fromAbi(p[2].type.?, third)) catch raise.reportToC(P));
            }
        },
        4 => struct {
            pub fn abi(argv: [*]const repr.Value, n: i32, third: Abi(p[2].type.?), fourth: Abi(p[3].type.?)) callconv(.c) Abi(P) {
                return toAbi(P, f(argv[0..@intCast(n + 1)], n, fromAbi(p[2].type.?, third), fromAbi(p[3].type.?, fourth)) catch raise.reportToC(P));
            }
        },
        else => @compileError("IndexAbi: unhandled arity"),
    };
}

/// The `opt` family, which *is* given a count -- `janet_optnumber(argv, argc,
/// n, dflt)` -- so its bridge uses the one it was handed.
fn CountAbi(comptime f: anytype) type {
    const info = @typeInfo(@TypeOf(f)).@"fn";
    const P = @typeInfo(info.return_type.?).error_union.payload;
    const p = info.params;
    return switch (p.len) {
        2 => struct {
            pub fn abi(argv: [*]const repr.Value, argc: i32, n: i32) callconv(.c) Abi(P) {
                return toAbi(P, f(argv[0..@intCast(argc)], n) catch raise.reportToC(P));
            }
        },
        3 => struct {
            pub fn abi(argv: [*]const repr.Value, argc: i32, n: i32, third: Abi(p[2].type.?)) callconv(.c) Abi(P) {
                return toAbi(P, f(argv[0..@intCast(argc)], n, fromAbi(p[2].type.?, third)) catch raise.reportToC(P));
            }
        },
        4 => struct {
            pub fn abi(argv: [*]const repr.Value, argc: i32, n: i32, third: Abi(p[2].type.?), fourth: Abi(p[3].type.?)) callconv(.c) Abi(P) {
                return toAbi(P, f(argv[0..@intCast(argc)], n, fromAbi(p[2].type.?, third), fromAbi(p[3].type.?, fourth)) catch raise.reportToC(P));
            }
        },
        else => @compileError("CountAbi: unhandled arity"),
    };
}

// ------------------------------------------------------------- the exports
//
// Public API, so no hidden visibility: these are the names `janet.h` promises.

pub const fixArityAbi = raise.panicking(fixArity).abi;
pub const checkArityAbi = raise.panicking(checkArity).abi;

pub const getSliceAbi = raise.panickingArgv(getSlice).abi;
pub const halfRangeAbi = IndexAbi(halfRange).abi;
pub const argIndexAbi = IndexAbi(argIndex).abi;
pub const startRangeAbi = CountAbi(startRange).abi;
pub const endRangeAbi = CountAbi(endRange).abi;

pub const getIndexedAbi = IndexAbi(getIndexed).abi;
pub const getDictionaryAbi = IndexAbi(getDictionary).abi;
pub const getBytesAbi = IndexAbi(getBytes).abi;
pub const getAbstractAbi = IndexAbi(getAbstract).abi;
pub const optAbstractAbi = CountAbi(optAbstract).abi;

pub const getCBytesAbi = IndexAbi(getCBytes).abi;
pub const getCStringAbi = IndexAbi(getCString).abi;
pub const optCBytesAbi = CountAbi(optCBytes).abi;
pub const optCStringAbi = CountAbi(optCString).abi;
pub const getFlagsAbi = IndexAbi(getFlags).abi;

// ----------------------------------------------- the Zig side of the layer
//
// Everything above has two faces: an implementation returning
// `raise.Raising(T)`, and a `raise.panicking` wrapper published under the C
// name. A Zig caller wants the first, and these are the names it is reachable
// by. Nothing here is `export`ed -- they are aliases for an importer, and the
// exported set is unchanged.
//
// The names are the C ones with the prefix dropped and the words separated,
// which is the only liberty taken. `janet_getcstring` reads `getCString` here
// and a reader should not have to wonder whether that is the same function.

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

comptime {}
