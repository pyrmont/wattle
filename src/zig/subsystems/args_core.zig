//! Argument extraction: deciding whether a cfunction's arguments are what it
//! asked for, and saying so.
//!
//! Phase 7 built the deciding half and left the saying in C. A getter that
//! formatted its own complaint would allocate, allocation can panic, and
//! through Phase 9 no Zig frame could be jumped through — so the layer
//! reported a code plus a slot and `janet_arg_raise` in `capi.c` turned it
//! into a message. Phase 10 Part 5 removes that constraint twice over: a panic
//! is a returned error, and a frame that holds nothing may be jumped through
//! anyway. `-Dargs-core` now selects the whole layer — the kernels, the
//! wording, `janet_arg_raise`, every exported `janet_get*` and `janet_opt*`,
//! and the three view constructors that used to sit in `util.c`.
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
//! Every exported getter has two faces. The implementation returns
//! `raise.Raising(T)` and is what the `janet_opt*` layer above it calls, so a
//! default-taking wrapper propagates an error rather than being jumped out of;
//! `raise.panicking(...).face` generates the C-ABI face beside it, under the
//! public name. Nothing here catches its own error — the `catch` is in the
//! face, one frame below, which is what makes the jump it delivers leave a
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
const abi = @import("abi");
const raise = @import("raise");
const pp_format = @import("pp_format.zig");
const c = abi.c;
const containers = @import("containers.zig");
const access = @import("access.zig");

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

fn checkNumber(comptime T: type, x: c.Janet) c_int {
    if (c.janet_checktype(x, c.JANET_NUMBER) == 0) return 0;
    return @intFromBool(checkRange(T, c.janet_unwrap_number(x)));
}

export fn janet_checkint(x: c.Janet) c_int {
    return checkNumber(i32, x);
}

export fn janet_checkuint(x: c.Janet) c_int {
    return checkNumber(u32, x);
}

export fn janet_checkint16(x: c.Janet) c_int {
    return checkNumber(i16, x);
}

export fn janet_checkuint16(x: c.Janet) c_int {
    return checkNumber(u16, x);
}

export fn janet_checkint8(x: c.Janet) c_int {
    return checkNumber(i8, x);
}

export fn janet_checkuint8(x: c.Janet) c_int {
    return checkNumber(u8, x);
}

/// The 64-bit range is `JANET_INTMAX_DOUBLE`, not `INT64_MAX`: 2^53, the
/// largest integer a double represents exactly. Beyond it the round trip would
/// accept values a double cannot distinguish from their neighbours.
const intmax_double: f64 = 9007199254740992.0;
const intmin_double: f64 = -9007199254740992.0;

export fn janet_checkint64(x: c.Janet) c_int {
    if (c.janet_checktype(x, c.JANET_NUMBER) == 0) return 0;
    const dval = c.janet_unwrap_number(x);
    if (!(dval >= intmin_double and dval <= intmax_double)) return 0;
    const truncated: i64 = @intFromFloat(dval);
    const back: f64 = @floatFromInt(truncated);
    return @intFromBool(dval == back);
}

export fn janet_checkuint64(x: c.Janet) c_int {
    if (c.janet_checktype(x, c.JANET_NUMBER) == 0) return 0;
    const dval = c.janet_unwrap_number(x);
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
export fn janet_checkfloat(x: c.Janet) c_int {
    if (c.janet_checktype(x, c.JANET_NUMBER) == 0) return 0;
    const dval = c.janet_unwrap_number(x);
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
export fn janet_checksize(x: c.Janet) c_int {
    if (c.janet_checktype(x, c.JANET_NUMBER) == 0) return 0;
    const dval = c.janet_unwrap_number(x);
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

fn faultExpect(fault: *c.JanetArgFault, expect: c_int, n: i32) void {
    fault.kind = @intCast(c.JANET_ARG_EXPECT);
    fault.expect = @intCast(expect);
    fault.slot = n;
}

fn faultType(fault: *c.JanetArgFault, n: i32, typeflags: i32) void {
    fault.kind = @intCast(c.JANET_ARG_TYPE);
    fault.slot = n;
    fault.typeflags = typeflags;
}

// ----------------------------------------------------------------- getters

export fn janet_arg_checktype(
    argv: [*c]const c.Janet,
    n: i32,
    janet_type: i32,
    typeflags: i32,
    fault: *c.JanetArgFault,
) c_int {
    if (c.janet_checktype(argv[@intCast(n)], @intCast(janet_type)) != 0) return 1;
    faultType(fault, n, typeflags);
    return 0;
}

/// The shared head of every `janet_opt*`: an argument past the end of the list,
/// or an explicit nil, both mean "use the default".
export fn janet_arg_isdefault(argv: [*c]const c.Janet, argc: i32, n: i32) c_int {
    if (n >= argc) return 1;
    return @intFromBool(c.janet_checktype(argv[@intCast(n)], c.JANET_NIL) != 0);
}

/// Every width except `janet_getinteger` converts the double; that one unwraps
/// an integer, which is a distinct operation under a tagged representation
/// where an integer is not stored as a double.
fn numberGetter(
    comptime T: type,
    comptime expect: c_int,
    comptime check: fn (c.Janet) callconv(.c) c_int,
) fn ([*c]const c.Janet, i32, *T, *c.JanetArgFault) callconv(.c) c_int {
    return struct {
        fn get(argv: [*c]const c.Janet, n: i32, out: *T, fault: *c.JanetArgFault) callconv(.c) c_int {
            const x = argv[@intCast(n)];
            if (check(x) == 0) {
                faultExpect(fault, expect, n);
                return 0;
            }
            const dval = c.janet_unwrap_number(x);
            out.* = switch (@typeInfo(T)) {
                .float => @floatCast(dval),
                else => @intFromFloat(dval),
            };
            return 1;
        }
    }.get;
}

pub const janet_arg_uinteger = numberGetter(u32, c.JANET_ARG_EXPECT_U32, janet_checkuint);
pub const janet_arg_integer16 = numberGetter(i16, c.JANET_ARG_EXPECT_S16, janet_checkint16);
pub const janet_arg_uinteger16 = numberGetter(u16, c.JANET_ARG_EXPECT_U16, janet_checkuint16);
pub const janet_arg_integer8 = numberGetter(i8, c.JANET_ARG_EXPECT_S8, janet_checkint8);
pub const janet_arg_uinteger8 = numberGetter(u8, c.JANET_ARG_EXPECT_U8, janet_checkuint8);
pub const janet_arg_float = numberGetter(f32, c.JANET_ARG_EXPECT_FLOAT, janet_checkfloat);
pub const janet_arg_integer64 = numberGetter(i64, c.JANET_ARG_EXPECT_S64, janet_checkint64);
pub const janet_arg_uinteger64 = numberGetter(u64, c.JANET_ARG_EXPECT_U64, janet_checkuint64);
pub const janet_arg_size = numberGetter(usize, c.JANET_ARG_EXPECT_SIZE, janet_checksize);

comptime {
    @export(&janet_arg_uinteger, .{ .name = "janet_arg_uinteger" });
    @export(&janet_arg_integer16, .{ .name = "janet_arg_integer16" });
    @export(&janet_arg_uinteger16, .{ .name = "janet_arg_uinteger16" });
    @export(&janet_arg_integer8, .{ .name = "janet_arg_integer8" });
    @export(&janet_arg_uinteger8, .{ .name = "janet_arg_uinteger8" });
    @export(&janet_arg_float, .{ .name = "janet_arg_float" });
    @export(&janet_arg_integer64, .{ .name = "janet_arg_integer64" });
    @export(&janet_arg_uinteger64, .{ .name = "janet_arg_uinteger64" });
    @export(&janet_arg_size, .{ .name = "janet_arg_size" });
}

export fn janet_arg_integer(argv: [*c]const c.Janet, n: i32, out: *i32, fault: *c.JanetArgFault) c_int {
    const x = argv[@intCast(n)];
    if (janet_checkint(x) == 0) {
        faultExpect(fault, c.JANET_ARG_EXPECT_S32, n);
        return 0;
    }
    out.* = c.janet_unwrap_integer(x);
    return 1;
}

export fn janet_arg_nat(argv: [*c]const c.Janet, n: i32, out: *i32, fault: *c.JanetArgFault) c_int {
    const x = argv[@intCast(n)];
    if (janet_checkint(x) != 0) {
        const ret = c.janet_unwrap_integer(x);
        if (ret >= 0) {
            out.* = ret;
            return 1;
        }
    }
    faultExpect(fault, c.JANET_ARG_EXPECT_NAT, n);
    return 0;
}

export fn janet_arg_abstract(
    argv: [*c]const c.Janet,
    n: i32,
    at: *const c.JanetAbstractType,
    out: *?*anyopaque,
    fault: *c.JanetArgFault,
) c_int {
    const x = argv[@intCast(n)];
    if (c.janet_checktype(x, c.JANET_ABSTRACT) != 0) {
        const abstractx = c.janet_unwrap_abstract(x);
        if (c.janet_abstract_type(abstractx) == at) {
            out.* = abstractx;
            return 1;
        }
    }
    fault.kind = @intCast(c.JANET_ARG_ABSTRACT);
    fault.slot = n;
    fault.at = at;
    return 0;
}

// ------------------------------------------------------------------- views

export fn janet_arg_indexed(
    argv: [*c]const c.Janet,
    n: i32,
    out: *c.JanetView,
    fault: *c.JanetArgFault,
) c_int {
    const x = argv[@intCast(n)];
    if (c.janet_checktype(x, c.JANET_ARRAY) != 0) {
        const array = c.janet_unwrap_array(x);
        out.items = array.*.data;
        out.len = array.*.count;
        return 1;
    } else if (c.janet_checktype(x, c.JANET_TUPLE) != 0) {
        const tuple = c.janet_unwrap_tuple(x);
        out.items = tuple;
        out.len = c.janet_tuple_length(tuple);
        return 1;
    }
    faultType(fault, n, @intCast(c.JANET_TFLAG_INDEXED));
    return 0;
}

export fn janet_arg_dictionary(
    argv: [*c]const c.Janet,
    n: i32,
    out: *c.JanetDictView,
    fault: *c.JanetArgFault,
) c_int {
    const x = argv[@intCast(n)];
    if (c.janet_checktype(x, c.JANET_TABLE) != 0) {
        const table = c.janet_unwrap_table(x);
        out.kvs = table.*.data;
        out.cap = table.*.capacity;
        out.len = table.*.count;
        return 1;
    } else if (c.janet_checktype(x, c.JANET_STRUCT) != 0) {
        const structure = c.janet_unwrap_struct(x);
        out.kvs = structure;
        out.cap = c.janet_struct_capacity(structure);
        out.len = c.janet_struct_length(structure);
        return 1;
    }
    faultType(fault, n, @intCast(c.JANET_TFLAG_DICTIONARY));
    return 0;
}

/// Classifies, and for the abstract case stops. Running `bytes` here would put
/// third-party code below a frame that must not be jumped through.
export fn janet_arg_bytes(
    x: c.Janet,
    n: i32,
    out: *c.JanetByteView,
    fault: *c.JanetArgFault,
) c_uint {
    switch (c.janet_type(x)) {
        c.JANET_STRING, c.JANET_SYMBOL, c.JANET_KEYWORD => {
            const string = c.janet_unwrap_string(x);
            out.bytes = string;
            out.len = c.janet_string_length(string);
            return @intCast(c.JANET_ARG_BYTES_STRING);
        },
        c.JANET_BUFFER => {
            const buffer = c.janet_unwrap_buffer(x);
            out.bytes = buffer.*.data;
            out.len = buffer.*.count;
            return @intCast(c.JANET_ARG_BYTES_BUFFER);
        },
        c.JANET_ABSTRACT => {
            const abst = c.janet_unwrap_abstract(x);
            if (c.janet_abstract_type(abst).*.bytes != null) {
                return @intCast(c.JANET_ARG_BYTES_ABSTRACT);
            }
        },
        else => {},
    }
    faultType(fault, n, @intCast(c.JANET_TFLAG_BYTES));
    return @intCast(c.JANET_ARG_BYTES_FAULT);
}

/// Which shape `janet_getcbytes` must use. Both buffer shapes mutate or
/// allocate, so neither is carried out here; the third is an ordinary byte
/// view and its own failure is reported by `janet_arg_bytes`.
export fn janet_arg_cbytes(argv: [*c]const c.Janet, n: i32, fault: *c.JanetArgFault) c_uint {
    _ = fault;
    const x = argv[@intCast(n)];
    if (c.janet_checktype(x, c.JANET_BUFFER) != 0) {
        const buffer = c.janet_unwrap_buffer(x);
        const no_realloc: i32 = @intCast(c.JANET_BUFFER_FLAG_NO_REALLOC);
        if ((buffer.*.gc.flags & no_realloc) != 0 and buffer.*.count == buffer.*.capacity) {
            return @intCast(c.JANET_ARG_CBYTES_COPY);
        }
        return @intCast(c.JANET_ARG_CBYTES_TERMINATE);
    }
    return @intCast(c.JANET_ARG_CBYTES_VIEW);
}

export fn janet_arg_zeros(bytes: [*c]const u8, len: i32, fault: *c.JanetArgFault) c_int {
    if (std.mem.len(bytes) == @as(usize, @intCast(len))) return 1;
    fault.kind = @intCast(c.JANET_ARG_ZEROS);
    return 0;
}

// ------------------------------------------------------------------ ranges

/// `janet_gethalfrange` and `janet_getargindex` differ in two places and are
/// otherwise the same walk: the half-range folds a negative index against
/// `length + 1` and reports a closed interval, the argument index folds against
/// `length` and reports a half-open one. Both accept `length` itself.
fn range(
    argv: [*c]const c.Janet,
    n: i32,
    length: i32,
    which: [*c]const u8,
    out: *i32,
    fault: *c.JanetArgFault,
    comptime inclusive: bool,
) c_int {
    var raw: i32 = undefined;
    if (janet_arg_integer(argv, n, &raw, fault) == 0) return 0;
    const fold: i64 = if (inclusive) @as(i64, length) + 1 else @as(i64, length);
    var not_raw: i64 = raw;
    if (not_raw < 0) not_raw += fold;
    if (not_raw < 0 or not_raw > length) {
        fault.kind = @intCast(if (inclusive)
            c.JANET_ARG_RANGE_INCLUSIVE
        else
            c.JANET_ARG_RANGE_EXCLUSIVE);
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

export fn janet_arg_halfrange(
    argv: [*c]const c.Janet,
    n: i32,
    length: i32,
    which: [*c]const u8,
    out: *i32,
    fault: *c.JanetArgFault,
) c_int {
    return range(argv, n, length, which, out, fault, true);
}

export fn janet_arg_argindex(
    argv: [*c]const c.Janet,
    n: i32,
    length: i32,
    which: [*c]const u8,
    out: *i32,
    fault: *c.JanetArgFault,
) c_int {
    return range(argv, n, length, which, out, fault, false);
}

// ------------------------------------------------------------------- flags

/// The 64-flag ceiling is the C original's, and it truncates silently rather
/// than reporting: a `flags` string longer than 64 characters has its tail
/// ignored, so a keyword naming one of those characters is rejected as
/// unexpected. Preserved.
export fn janet_arg_flags(
    keyw: [*c]const u8,
    klen: i32,
    flags: [*c]const u8,
    out: *u64,
    fault: *c.JanetArgFault,
) c_int {
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
            fault.kind = @intCast(c.JANET_ARG_FLAG);
            fault.raw = keyw[j];
            fault.flags = flags;
            return 0;
        }
    }
    out.* = ret;
    return 1;
}

// ------------------------------------------------------------------- arity

export fn janet_arg_fixarity(count: i32, fix: i32, fault: *c.JanetArgFault) c_int {
    if (count == fix) return 1;
    fault.kind = @intCast(c.JANET_ARG_ARITY_FIX);
    fault.arity = count;
    fault.bound = fix;
    return 0;
}

/// A negative bound means "unbounded on that side", which is how a cfunction
/// with no maximum spells itself.
export fn janet_arg_arity(count: i32, min: i32, max: i32, fault: *c.JanetArgFault) c_int {
    if (min >= 0 and count < min) {
        fault.kind = @intCast(c.JANET_ARG_ARITY_MIN);
        fault.arity = count;
        fault.bound = min;
        return 0;
    }
    if (max >= 0 and count > max) {
        fault.kind = @intCast(c.JANET_ARG_ARITY_MAX);
        fault.arity = count;
        fault.bound = max;
        return 0;
    }
    return 1;
}

// ----------------------------------------------------------------- strlike

export fn janet_arg_strlike(janet_type: i32, x: c.Janet, cstring: [*c]const u8) c_int {
    if (c.janet_type(x) != janet_type) return 0;
    return @intFromBool(c.janet_cstrcmp(c.janet_unwrap_string(x), cstring) == 0);
}

// ----------------------------------------------------------------- methods

export fn janet_arg_method(
    method: [*c]const u8,
    methods: [*c]const c.JanetMethod,
    out: *[*c]const c.JanetMethod,
) c_int {
    var entry = methods;
    while (entry.*.name != null) : (entry += 1) {
        if (c.janet_cstrcmp(method, entry.*.name) == 0) {
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
export fn janet_arg_nextmethod(
    methods: [*c]const c.JanetMethod,
    key: c.Janet,
) [*c]const c.JanetMethod {
    var entry = methods;
    if (c.janet_checktype(key, c.JANET_NIL) == 0) {
        while (entry.*.name != null) {
            const matched = c.janet_keyeq(key, entry.*.name) != 0;
            entry += 1;
            if (matched) break;
        }
    }
    return entry;
}

// ====================================================================
// The exported surface.
//
// Everything below was `capi.c`'s half of the layer until Phase 10 Part 5.
// Each entry is a kernel call and, on failure, a raise -- which is now a
// returned error rather than a jump, so `janet_opt*` can propagate what
// `janet_get*` decided instead of being jumped out of.
// ====================================================================

// ----------------------------------------------------------------- wording

/// The only place the nouns appear. A getter reports `JANET_ARG_EXPECT_S16`
/// and this decides it is spelled "16 bit signed integer", which is what makes
/// the two implementations word-identical without either of them formatting.
fn expectName(expect: u8) [*:0]const u8 {
    return switch (@as(c_uint, expect)) {
        c.JANET_ARG_EXPECT_NAT => "non-negative 32 bit signed integer",
        c.JANET_ARG_EXPECT_SIZE => "size",
        c.JANET_ARG_EXPECT_S32 => "32 bit signed integer",
        c.JANET_ARG_EXPECT_U32 => "32 bit unsigned integer",
        c.JANET_ARG_EXPECT_S16 => "16 bit signed integer",
        c.JANET_ARG_EXPECT_U16 => "16 bit unsigned integer",
        c.JANET_ARG_EXPECT_S8 => "8 bit signed integer",
        c.JANET_ARG_EXPECT_U8 => "8 bit unsigned integer",
        c.JANET_ARG_EXPECT_FLOAT => "float number",
        c.JANET_ARG_EXPECT_S64 => "64 bit signed integer",
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
pub fn panicType(x: c.Janet, n: i32, expected: c_int) raise.Error {
    return pp_format.panicf("bad slot #%d, expected %T, got %v", .{ n, expected, x });
}

pub fn panicAbstract(x: c.Janet, n: i32, at: *const c.JanetAbstractType) raise.Error {
    return pp_format.panicf("bad slot #%d, expected %s, got %v", .{ n, at.name, x });
}

export fn janet_panic_type(x: c.Janet, n: i32, expected: c_int) callconv(.c) void {
    raise.report(panicType(x, n, expected));
}

export fn janet_panic_abstract(x: c.Janet, n: i32, at: *const c.JanetAbstractType) callconv(.c) void {
    raise.report(panicAbstract(x, n, at));
}

// -------------------------------------------------------------- the raise

/// The argument a fault names. Read inside the three slot kinds and nowhere
/// else. The other eight leave `slot` unwritten -- a kernel fills in only the
/// fields its message uses -- and the two arity kinds are raised with a null
/// `argv` besides, having no argument list to name. Reading either at the head
/// of `raiseFault` instead of inside the branch is the mistake this exists to
/// make visible; `test/args_core.c` catches it on its first assertion.
inline fn slotOf(argv: [*c]const c.Janet, fault: *const c.JanetArgFault) c.Janet {
    return argv[@intCast(fault.slot)];
}

/// Turn a filled-in `JanetArgFault` into the message the C original raised.
///
/// `argv` may be null for the kinds that do not name a slot -- the arity
/// kinds, the range kinds, the flag kind and the embedded-zero kind all render
/// without touching the argument.
fn raiseFault(argv: [*c]const c.Janet, fault: *const c.JanetArgFault) raise.Error {
    return switch (@as(c_uint, fault.kind)) {
        c.JANET_ARG_TYPE => panicType(slotOf(argv, fault), fault.slot, fault.typeflags),
        c.JANET_ARG_ABSTRACT => panicAbstract(slotOf(argv, fault), fault.slot, fault.at.?),
        c.JANET_ARG_EXPECT => pp_format.panicf(
            "bad slot #%d, expected %s, got %v",
            .{ fault.slot, expectName(fault.expect), slotOf(argv, fault) },
        ),
        // The three int64_t arguments to "%d" below are the C original's, and
        // C's "%d" read an int32_t from the va_list before widening it, which
        // is undefined and is recorded in FOUND.md. It was reproduced here
        // while the other implementation was C and could be compared against.
        // Part 18 removed the va_list: "%d" renders the 64 bits its rewritten
        // specifier always asked for, so these are simply correct now. The
        // digits are unchanged for any index that fits in an int32_t, which
        // is every index either implementation was ever observed on.
        c.JANET_ARG_RANGE_INCLUSIVE => pp_format.panicf(
            "%s index %d out of range [%d,%d]",
            .{ fault.which, fault.raw, fault.lo, fault.hi },
        ),
        c.JANET_ARG_RANGE_EXCLUSIVE => pp_format.panicf(
            "%s index %d out of range [%d,%d)",
            .{ fault.which, fault.raw, fault.lo, fault.hi },
        ),
        // The C original casts the byte to `char` before the variadic
        // promotion, so a keyword byte above 127 reaches "%c" as a negative int
        // wherever `char` is signed. It makes no difference to what prints --
        // "%c" converts its argument back to an `unsigned char` -- but the cast
        // is reproduced rather than dropped, because the sign is visible to
        // anything that reads the argument as an int first.
        c.JANET_ARG_FLAG => pp_format.panicf(
            "unexpected flag %c, expected one of \"%s\"",
            .{ @as(c_char, @bitCast(@as(u8, @truncate(@as(u64, @bitCast(fault.raw)))))), fault.flags },
        ),
        c.JANET_ARG_ZEROS => raise.panic("bytes contain embedded 0s"),
        c.JANET_ARG_ARITY_FIX => pp_format.panicf(
            "arity mismatch, expected %d, got %d",
            .{ fault.bound, fault.arity },
        ),
        c.JANET_ARG_ARITY_MIN => pp_format.panicf(
            "arity mismatch, expected at least %d, got %d",
            .{ fault.bound, fault.arity },
        ),
        c.JANET_ARG_ARITY_MAX => pp_format.panicf(
            "arity mismatch, expected at most %d, got %d",
            .{ fault.bound, fault.arity },
        ),
        else => raise.panic("argument fault with no kind"),
    };
}

/// The C face of `raiseFault`, still declared in `state.h` because the kernels
/// are usable on their own and a C caller of one needs a way to report what it
/// found. `janet_arg_raise` never returns, so there is no error to hand back
/// and `raise.panicking` does not apply.
export fn janet_arg_raise(argv: [*c]const c.Janet, fault: *const c.JanetArgFault) callconv(.c) void {
    raise.report(raiseFault(argv, fault));
}

// ------------------------------------------------------------------ arity

fn fixArity(count: i32, fix: i32) raise.Raising(void) {
    var fault: c.JanetArgFault = undefined;
    if (janet_arg_fixarity(count, fix, &fault) == 0) return raiseFault(null, &fault);
}

fn checkArity(count: i32, min: i32, max: i32) raise.Raising(void) {
    var fault: c.JanetArgFault = undefined;
    if (janet_arg_arity(count, min, max, &fault) == 0) return raiseFault(null, &fault);
}

// ---------------------------------------------------------------- getters

/// `DEFINE_GETTER` from `capi.c`: check the type, then unwrap it.
///
/// The payload type is read off the unwrap function rather than written out
/// fourteen times, so a representation change -- `-Dnanbox=false` returns a
/// different Zig type for several of these -- cannot make the exported
/// signature disagree with `janet.h`.
fn TypeGetter(comptime unwrap: anytype, comptime janet_type: anytype, comptime typeflags: anytype) type {
    return struct {
        pub const Value = @typeInfo(@TypeOf(unwrap)).@"fn".return_type.?;
        pub fn get(argv: [*c]const c.Janet, n: i32) raise.Raising(Value) {
            var fault: c.JanetArgFault = undefined;
            if (janet_arg_checktype(argv, n, @intCast(janet_type), @intCast(typeflags), &fault) == 0) {
                return raiseFault(argv, &fault);
            }
            return unwrap(argv[@intCast(n)]);
        }
        pub const face = raise.panicking(get).face;
    };
}

/// `DEFINE_ARG_GETTER`: the numeric widths, whose kernels answer with an
/// out-parameter and an expectation code.
fn ArgGetter(comptime T: type, comptime kernel: anytype) type {
    return struct {
        pub const Value = T;
        pub fn get(argv: [*c]const c.Janet, n: i32) raise.Raising(T) {
            var out: T = undefined;
            var fault: c.JanetArgFault = undefined;
            if (kernel(argv, n, &out, &fault) == 0) return raiseFault(argv, &fault);
            return out;
        }
        pub const face = raise.panicking(get).face;
    };
}

/// `DEFINE_OPT` and `DEFINE_ARG_OPT`, which differ only in which getter they
/// fall through to. This is the shape Part 5 exists for: the fall-through is a
/// `return` of an error union, so a bad argument no longer jumps out of the
/// frame that decided to look at it.
fn Opt(comptime G: type) type {
    return struct {
        pub fn get(argv: [*c]const c.Janet, argc: i32, n: i32, dflt: G.Value) raise.Raising(G.Value) {
            if (janet_arg_isdefault(argv, argc, n) != 0) return dflt;
            return G.get(argv, n);
        }
        pub const face = raise.panicking(get).face;
    };
}

/// `DEFINE_OPTLEN`: the three mutable containers, whose default is a fresh
/// empty one of the given capacity rather than a value the caller supplies.
fn OptLen(comptime G: type, comptime construct: anytype) type {
    return struct {
        pub fn get(argv: [*c]const c.Janet, argc: i32, n: i32, dflt_len: i32) raise.Raising(G.Value) {
            if (janet_arg_isdefault(argv, argc, n) != 0) return construct(dflt_len);
            return G.get(argv, n);
        }
        pub const face = raise.panicking(get).face;
    };
}

const GetNumber = TypeGetter(c.janet_unwrap_number, c.JANET_NUMBER, c.JANET_TFLAG_NUMBER);
const GetArray = TypeGetter(c.janet_unwrap_array, c.JANET_ARRAY, c.JANET_TFLAG_ARRAY);
const GetTuple = TypeGetter(c.janet_unwrap_tuple, c.JANET_TUPLE, c.JANET_TFLAG_TUPLE);
const GetTable = TypeGetter(c.janet_unwrap_table, c.JANET_TABLE, c.JANET_TFLAG_TABLE);
const GetStruct = TypeGetter(c.janet_unwrap_struct, c.JANET_STRUCT, c.JANET_TFLAG_STRUCT);
const GetString = TypeGetter(c.janet_unwrap_string, c.JANET_STRING, c.JANET_TFLAG_STRING);
const GetKeyword = TypeGetter(c.janet_unwrap_keyword, c.JANET_KEYWORD, c.JANET_TFLAG_KEYWORD);
const GetSymbol = TypeGetter(c.janet_unwrap_symbol, c.JANET_SYMBOL, c.JANET_TFLAG_SYMBOL);
const GetBuffer = TypeGetter(c.janet_unwrap_buffer, c.JANET_BUFFER, c.JANET_TFLAG_BUFFER);
const GetFiber = TypeGetter(c.janet_unwrap_fiber, c.JANET_FIBER, c.JANET_TFLAG_FIBER);
const GetFunction = TypeGetter(c.janet_unwrap_function, c.JANET_FUNCTION, c.JANET_TFLAG_FUNCTION);
const GetCFunction = TypeGetter(c.janet_unwrap_cfunction, c.JANET_CFUNCTION, c.JANET_TFLAG_CFUNCTION);
const GetBoolean = TypeGetter(c.janet_unwrap_boolean, c.JANET_BOOLEAN, c.JANET_TFLAG_BOOLEAN);
const GetPointer = TypeGetter(c.janet_unwrap_pointer, c.JANET_POINTER, c.JANET_TFLAG_POINTER);

const GetNat = ArgGetter(i32, janet_arg_nat);
const GetInteger = ArgGetter(i32, janet_arg_integer);
const GetUInteger = ArgGetter(u32, janet_arg_uinteger);
const GetInteger16 = ArgGetter(i16, janet_arg_integer16);
const GetUInteger16 = ArgGetter(u16, janet_arg_uinteger16);
const GetInteger8 = ArgGetter(i8, janet_arg_integer8);
const GetUInteger8 = ArgGetter(u8, janet_arg_uinteger8);
const GetFloat = ArgGetter(f32, janet_arg_float);
const GetSize = ArgGetter(usize, janet_arg_size);

/// With integer types enabled these accept an `int/s64` or `int/u64` abstract
/// as well as a number, and `janet_unwrap_s64` raises its own message. There
/// is no fault for a kernel to report, so the whole decision is there -- and
/// it is a C-ABI call into `-Dint-types-core`, so that raise arrives as a jump
/// through this frame rather than as an error. Nothing is held across it.
const int_types_enabled = @hasDecl(c, "janet_unwrap_s64");

fn Wide(comptime T: type, comptime unwrap: anytype, comptime kernel: anytype) type {
    return struct {
        pub const Value = T;
        pub fn get(argv: [*c]const c.Janet, n: i32) raise.Raising(T) {
            if (int_types_enabled) return unwrap(argv[@intCast(n)]);
            var out: T = undefined;
            var fault: c.JanetArgFault = undefined;
            if (kernel(argv, n, &out, &fault) == 0) return raiseFault(argv, &fault);
            return out;
        }
        pub const face = raise.panicking(get).face;
    };
}

const GetInteger64 = Wide(i64, if (int_types_enabled) c.janet_unwrap_s64 else {}, janet_arg_integer64);
const GetUInteger64 = Wide(u64, if (int_types_enabled) c.janet_unwrap_u64 else {}, janet_arg_uinteger64);

// ----------------------------------------------------------------- ranges

pub fn halfRange(argv: [*c]const c.Janet, n: i32, length: i32, which: [*c]const u8) raise.Raising(i32) {
    var out: i32 = undefined;
    var fault: c.JanetArgFault = undefined;
    if (janet_arg_halfrange(argv, n, length, which, &out, &fault) == 0) return raiseFault(argv, &fault);
    return out;
}

pub fn argIndex(argv: [*c]const c.Janet, n: i32, length: i32, which: [*c]const u8) raise.Raising(i32) {
    var out: i32 = undefined;
    var fault: c.JanetArgFault = undefined;
    if (janet_arg_argindex(argv, n, length, which, &out, &fault) == 0) return raiseFault(argv, &fault);
    return out;
}

pub fn startRange(argv: [*c]const c.Janet, argc: i32, n: i32, length: i32) raise.Raising(i32) {
    if (janet_arg_isdefault(argv, argc, n) != 0) return 0;
    return halfRange(argv, n, length, "start");
}

pub fn endRange(argv: [*c]const c.Janet, argc: i32, n: i32, length: i32) raise.Raising(i32) {
    if (janet_arg_isdefault(argv, argc, n) != 0) return length;
    return halfRange(argv, n, length, "end");
}

/// `janet_length` is a C-ABI call into `-Dvalue-access` and raises by jumping
/// through this frame, which holds nothing at that point.
pub fn getSlice(argc: i32, argv: [*c]const c.Janet) raise.Raising(c.JanetRange) {
    try checkArity(argc, 1, 3);
    var range_out: c.JanetRange = undefined;
    const length = try access.length(argv[0]);
    range_out.start = try startRange(argv, argc, 1, length);
    range_out.end = try endRange(argv, argc, 2, length);
    if (range_out.end < range_out.start) range_out.end = range_out.start;
    return range_out;
}

// ------------------------------------------------------------------ views

pub fn getIndexed(argv: [*c]const c.Janet, n: i32) raise.Raising(c.JanetView) {
    var view: c.JanetView = undefined;
    var fault: c.JanetArgFault = undefined;
    if (janet_arg_indexed(argv, n, &view, &fault) == 0) return raiseFault(argv, &fault);
    return view;
}

pub fn getDictionary(argv: [*c]const c.Janet, n: i32) raise.Raising(c.JanetDictView) {
    var view: c.JanetDictView = undefined;
    var fault: c.JanetArgFault = undefined;
    if (janet_arg_dictionary(argv, n, &view, &fault) == 0) return raiseFault(argv, &fault);
    return view;
}

/// The abstract branch runs the type's `bytes` callback, which is a C function
/// pointer from a native module: third-party code that raises by jumping. It
/// runs outside the kernel so that a caller which may not raise at all --
/// `janet_bytes_view` below -- can still use the classification.
pub fn getBytes(argv: [*c]const c.Janet, n: i32) raise.Raising(c.JanetByteView) {
    var view: c.JanetByteView = undefined;
    var fault: c.JanetArgFault = undefined;
    switch (janet_arg_bytes(argv[@intCast(n)], n, &view, &fault)) {
        c.JANET_ARG_BYTES_STRING, c.JANET_ARG_BYTES_BUFFER => return view,
        c.JANET_ARG_BYTES_ABSTRACT => {
            const abst = c.janet_unwrap_abstract(argv[@intCast(n)]);
            return c.janet_abstract_type(abst).*.bytes.?(abst, c.janet_abstract_size(abst));
        },
        else => return raiseFault(argv, &fault),
    }
}

pub fn getAbstract(argv: [*c]const c.Janet, n: i32, at: *const c.JanetAbstractType) raise.Raising(?*anyopaque) {
    var out: ?*anyopaque = undefined;
    var fault: c.JanetArgFault = undefined;
    if (janet_arg_abstract(argv, n, at, &out, &fault) == 0) return raiseFault(argv, &fault);
    return out;
}

pub fn optAbstract(
    argv: [*c]const c.Janet,
    argc: i32,
    n: i32,
    at: *const c.JanetAbstractType,
    dflt: ?*anyopaque,
) raise.Raising(?*anyopaque) {
    if (janet_arg_isdefault(argv, argc, n) != 0) return dflt;
    return getAbstract(argv, n, at);
}

/// The public non-raising probe. It is why the kernels report rather than
/// raise: this one has to answer NULL, not stop the caller.
export fn janet_checkabstract(x: c.Janet, at: *const c.JanetAbstractType) callconv(.c) ?*anyopaque {
    var value = x;
    var out: ?*anyopaque = undefined;
    var fault: c.JanetArgFault = undefined;
    if (janet_arg_abstract(&value, 0, at, &out, &fault) == 0) return null;
    return out;
}

// --------------------------------------------------------------- c strings

/// The two buffer shapes are carried out here rather than in the kernel: one
/// pushes a byte and one calls `janet_smalloc`, and both can raise.
pub fn getCBytes(argv: [*c]const c.Janet, n: i32) raise.Raising([*c]const u8) {
    var fault: c.JanetArgFault = undefined;
    var cstr: [*c]const u8 = undefined;
    var len: i32 = undefined;
    switch (janet_arg_cbytes(argv, n, &fault)) {
        c.JANET_ARG_CBYTES_COPY => {
            // Make a copy with janet_smalloc in the rare case we have a buffer
            // that cannot be realloced and pushing a 0 byte would raise.
            const buffer = c.janet_unwrap_buffer(argv[@intCast(n)]);
            const count: usize = @intCast(buffer.*.count);
            const copy: [*]u8 = @ptrCast(c.janet_smalloc(count + 1));
            @memcpy(copy[0..count], buffer.*.data[0..count]);
            copy[count] = 0;
            cstr = copy;
            len = buffer.*.count;
        },
        c.JANET_ARG_CBYTES_TERMINATE => {
            // Ensure trailing 0
            const buffer = c.janet_unwrap_buffer(argv[@intCast(n)]);
            try containers.bufferPushU8(buffer, 0);
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
    if (janet_arg_zeros(cstr, len, &fault) == 0) return raiseFault(argv, &fault);
    return cstr;
}

pub fn getCString(argv: [*c]const c.Janet, n: i32) raise.Raising([*c]const u8) {
    var fault: c.JanetArgFault = undefined;
    const tflag: i32 = @intCast(c.JANET_TFLAG_STRING);
    if (janet_arg_checktype(argv, n, @intCast(c.JANET_STRING), tflag, &fault) == 0) {
        return raiseFault(argv, &fault);
    }
    return getCBytes(argv, n);
}

pub fn optCString(argv: [*c]const c.Janet, argc: i32, n: i32, dflt: [*c]const u8) raise.Raising([*c]const u8) {
    if (janet_arg_isdefault(argv, argc, n) != 0) return dflt;
    return getCString(argv, n);
}

pub fn optCBytes(argv: [*c]const c.Janet, argc: i32, n: i32, dflt: [*c]const u8) raise.Raising([*c]const u8) {
    if (janet_arg_isdefault(argv, argc, n) != 0) return dflt;
    return getCBytes(argv, n);
}

// ------------------------------------------------------------------ flags

pub fn getFlags(argv: [*c]const c.Janet, n: i32, flags: [*c]const u8) raise.Raising(u64) {
    const keyw = try GetKeyword.get(argv, n);
    var out: u64 = undefined;
    var fault: c.JanetArgFault = undefined;
    if (janet_arg_flags(keyw, c.janet_string_length(keyw), flags, &out, &fault) == 0) {
        return raiseFault(argv, &fault);
    }
    return out;
}

// ---------------------------------------------------------------- strlike

export fn janet_keyeq(x: c.Janet, cstring: [*c]const u8) callconv(.c) c_int {
    return janet_arg_strlike(@intCast(c.JANET_KEYWORD), x, cstring);
}

export fn janet_streq(x: c.Janet, cstring: [*c]const u8) callconv(.c) c_int {
    return janet_arg_strlike(@intCast(c.JANET_STRING), x, cstring);
}

export fn janet_symeq(x: c.Janet, cstring: [*c]const u8) callconv(.c) c_int {
    return janet_arg_strlike(@intCast(c.JANET_SYMBOL), x, cstring);
}

// ---------------------------------------------------------------- methods

export fn janet_getmethod(
    method: [*c]const u8,
    methods: [*c]const c.JanetMethod,
    out: *c.Janet,
) callconv(.c) c_int {
    var found: [*c]const c.JanetMethod = undefined;
    if (janet_arg_method(method, methods, &found) == 0) return 0;
    out.* = c.janet_wrap_cfunction(found.*.cfun);
    return 1;
}

/// Wrapping the name allocates, which is why the kernel stops at the entry.
export fn janet_nextmethod(methods: [*c]const c.JanetMethod, key: c.Janet) callconv(.c) c.Janet {
    const found = janet_arg_nextmethod(methods, key);
    if (found.*.name != null) return c.janet_ckeywordv(found.*.name);
    return c.janet_wrap_nil();
}

// ------------------------------------------------------- the view builders
//
// These moved out of `util.c` with the layer they are built on. All three are
// public API with a fixed signature that reports failure by returning 0, which
// is the constraint that keeps the kernels non-raising.

export fn janet_indexed_view(seq: c.Janet, data: *[*c]const c.Janet, len: *i32) callconv(.c) c_int {
    var value = seq;
    var view: c.JanetView = undefined;
    var fault: c.JanetArgFault = undefined;
    if (janet_arg_indexed(&value, 0, &view, &fault) == 0) return 0;
    data.* = view.items;
    len.* = view.len;
    return 1;
}

export fn janet_bytes_view(str: c.Janet, data: *[*c]const u8, len: *i32) callconv(.c) c_int {
    var view: c.JanetByteView = undefined;
    var fault: c.JanetArgFault = undefined;
    switch (janet_arg_bytes(str, 0, &view, &fault)) {
        c.JANET_ARG_BYTES_STRING, c.JANET_ARG_BYTES_BUFFER => {},
        c.JANET_ARG_BYTES_ABSTRACT => {
            // Third-party code, and the reason the classification above is a
            // separate step: it raises by jumping, and this frame may not
            // report a raise at all.
            const abst = c.janet_unwrap_abstract(str);
            view = c.janet_abstract_type(abst).*.bytes.?(abst, c.janet_abstract_size(abst));
        },
        else => return 0,
    }
    data.* = view.bytes;
    len.* = view.len;
    return 1;
}

export fn janet_dictionary_view(
    tab: c.Janet,
    data: *[*c]const c.JanetKV,
    len: *i32,
    cap: *i32,
) callconv(.c) c_int {
    var value = tab;
    var view: c.JanetDictView = undefined;
    var fault: c.JanetArgFault = undefined;
    if (janet_arg_dictionary(&value, 0, &view, &fault) == 0) return 0;
    data.* = view.kvs;
    len.* = view.len;
    cap.* = view.cap;
    return 1;
}

// ------------------------------------------------------------- the exports
//
// Public API, so no hidden visibility: these are the names `janet.h` promises.

pub const janet_fixarity = raise.panicking(fixArity).face;
pub const janet_arity = raise.panicking(checkArity).face;

pub const janet_getslice = raise.panicking(getSlice).face;
pub const janet_gethalfrange = raise.panicking(halfRange).face;
pub const janet_getargindex = raise.panicking(argIndex).face;
pub const janet_getstartrange = raise.panicking(startRange).face;
pub const janet_getendrange = raise.panicking(endRange).face;

pub const janet_getindexed = raise.panicking(getIndexed).face;
pub const janet_getdictionary = raise.panicking(getDictionary).face;
pub const janet_getbytes = raise.panicking(getBytes).face;
pub const janet_getabstract = raise.panicking(getAbstract).face;
pub const janet_optabstract = raise.panicking(optAbstract).face;

pub const janet_getcbytes = raise.panicking(getCBytes).face;
pub const janet_getcstring = raise.panicking(getCString).face;
pub const janet_optcbytes = raise.panicking(optCBytes).face;
pub const janet_optcstring = raise.panicking(optCString).face;
pub const janet_getflags = raise.panicking(getFlags).face;

// ----------------------------------------------- the Zig face of the layer
//
// Phase 10 Part 17b. Everything above this line has had two faces since Part 5
// -- an implementation returning `raise.Raising(T)` and a `raise.panicking`
// wrapper under the public C name -- and until now only the C one had callers
// outside this file, because a subsystem in another object could reach it only
// through the symbol table. Part 17a put every subsystem in one compilation,
// so the implementation is reachable directly, and these are the names it is
// reachable by.
//
// `subsystems/arglayer.zig` is what a caller imports; it picks between this and
// `args_core_extern.zig` on the selector. Nothing here is `export`ed: these are
// aliases for a Zig caller, and the exported set is unchanged.
//
// The names are the C ones with the prefix dropped and the words separated,
// which is the only liberty taken. `janet_getcstring` reads `getCString` here
// and a reader should not have to wonder whether that is the same function.

pub const fixarity = fixArity;
pub const arity = checkArity;

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

pub const optBuffer = OptLen(GetBuffer, c.janet_buffer).get;
pub const optTable = OptLen(GetTable, c.janet_table).get;
pub const optArray = OptLen(GetArray, c.janet_array).get;

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

comptime {
    @export(&janet_fixarity, .{ .name = "janet_fixarity" });
    @export(&janet_arity, .{ .name = "janet_arity" });

    @export(&GetNumber.face, .{ .name = "janet_getnumber" });
    @export(&GetArray.face, .{ .name = "janet_getarray" });
    @export(&GetTuple.face, .{ .name = "janet_gettuple" });
    @export(&GetTable.face, .{ .name = "janet_gettable" });
    @export(&GetStruct.face, .{ .name = "janet_getstruct" });
    @export(&GetString.face, .{ .name = "janet_getstring" });
    @export(&GetKeyword.face, .{ .name = "janet_getkeyword" });
    @export(&GetSymbol.face, .{ .name = "janet_getsymbol" });
    @export(&GetBuffer.face, .{ .name = "janet_getbuffer" });
    @export(&GetFiber.face, .{ .name = "janet_getfiber" });
    @export(&GetFunction.face, .{ .name = "janet_getfunction" });
    @export(&GetCFunction.face, .{ .name = "janet_getcfunction" });
    @export(&GetBoolean.face, .{ .name = "janet_getboolean" });
    @export(&GetPointer.face, .{ .name = "janet_getpointer" });

    @export(&Opt(GetNumber).face, .{ .name = "janet_optnumber" });
    @export(&Opt(GetTuple).face, .{ .name = "janet_opttuple" });
    @export(&Opt(GetStruct).face, .{ .name = "janet_optstruct" });
    @export(&Opt(GetString).face, .{ .name = "janet_optstring" });
    @export(&Opt(GetKeyword).face, .{ .name = "janet_optkeyword" });
    @export(&Opt(GetSymbol).face, .{ .name = "janet_optsymbol" });
    @export(&Opt(GetFiber).face, .{ .name = "janet_optfiber" });
    @export(&Opt(GetFunction).face, .{ .name = "janet_optfunction" });
    @export(&Opt(GetCFunction).face, .{ .name = "janet_optcfunction" });
    @export(&Opt(GetBoolean).face, .{ .name = "janet_optboolean" });
    @export(&Opt(GetPointer).face, .{ .name = "janet_optpointer" });

    @export(&OptLen(GetBuffer, c.janet_buffer).face, .{ .name = "janet_optbuffer" });
    @export(&OptLen(GetTable, c.janet_table).face, .{ .name = "janet_opttable" });
    @export(&OptLen(GetArray, c.janet_array).face, .{ .name = "janet_optarray" });

    @export(&GetNat.face, .{ .name = "janet_getnat" });
    @export(&GetInteger.face, .{ .name = "janet_getinteger" });
    @export(&GetUInteger.face, .{ .name = "janet_getuinteger" });
    @export(&GetInteger16.face, .{ .name = "janet_getinteger16" });
    @export(&GetUInteger16.face, .{ .name = "janet_getuinteger16" });
    @export(&GetInteger8.face, .{ .name = "janet_getinteger8" });
    @export(&GetUInteger8.face, .{ .name = "janet_getuinteger8" });
    @export(&GetFloat.face, .{ .name = "janet_getfloat" });
    @export(&GetSize.face, .{ .name = "janet_getsize" });
    @export(&GetInteger64.face, .{ .name = "janet_getinteger64" });
    @export(&GetUInteger64.face, .{ .name = "janet_getuinteger64" });

    @export(&Opt(GetNat).face, .{ .name = "janet_optnat" });
    @export(&Opt(GetInteger).face, .{ .name = "janet_optinteger" });
    @export(&Opt(GetInteger64).face, .{ .name = "janet_optinteger64" });
    @export(&Opt(GetSize).face, .{ .name = "janet_optsize" });
    @export(&Opt(GetUInteger).face, .{ .name = "janet_optuinteger" });
    @export(&Opt(GetUInteger64).face, .{ .name = "janet_optuinteger64" });

    @export(&janet_getslice, .{ .name = "janet_getslice" });
    @export(&janet_gethalfrange, .{ .name = "janet_gethalfrange" });
    @export(&janet_getargindex, .{ .name = "janet_getargindex" });
    @export(&janet_getstartrange, .{ .name = "janet_getstartrange" });
    @export(&janet_getendrange, .{ .name = "janet_getendrange" });

    @export(&janet_getindexed, .{ .name = "janet_getindexed" });
    @export(&janet_getdictionary, .{ .name = "janet_getdictionary" });
    @export(&janet_getbytes, .{ .name = "janet_getbytes" });
    @export(&janet_getabstract, .{ .name = "janet_getabstract" });
    @export(&janet_optabstract, .{ .name = "janet_optabstract" });

    @export(&janet_getcbytes, .{ .name = "janet_getcbytes" });
    @export(&janet_getcstring, .{ .name = "janet_getcstring" });
    @export(&janet_optcbytes, .{ .name = "janet_optcbytes" });
    @export(&janet_optcstring, .{ .name = "janet_optcstring" });
    @export(&janet_getflags, .{ .name = "janet_getflags" });
}
