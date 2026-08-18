//! Argument extraction: deciding whether a cfunction's arguments are what it
//! asked for, without being able to say so.
//!
//! This is the layer Phase 7's fifth rule named and did not build, and the one
//! that blocked three Phase 6 bullets. Every `janet_get*` and `janet_opt*` in
//! `src/core/capi.c` ends a failure in `janet_panicf`, which allocates a Janet
//! string, and allocation can panic. A non-panicking getter that formatted
//! eagerly would therefore need a panic-free allocator; reporting a code plus
//! the slot and formatting only at the C boundary avoids that, and it makes the
//! two implementations word-identical by construction rather than by
//! inspection. `JanetArgFault` in `src/core/state.h` is that report, and
//! `janet_arg_raise` in `capi.c` is the only place the format strings live.
//!
//! **Nothing here holds a Janet value in the descriptor.** The slot index is
//! enough for the boundary to recover `argv[slot]` and render it with `%v`,
//! which runs an abstract type's `tostring` callback. Same reasoning as
//! `JanetTraceFrame`, and the same reason the coercion message stayed in C in
//! Part 8 of Phase 7.
//!
//! Three things are deliberately *not* done here, each for the same rule —
//! nothing Zig calls may raise:
//!
//!  - **`janet_arg_bytes` reports the abstract case instead of taking it.** A
//!    byte view of an abstract runs the type's `bytes` callback, which is
//!    third-party code and may panic. The classification happens here and the
//!    call happens in `capi.c` and `util.c`, so no jump crosses the frame that
//!    classified.
//!  - **`janet_arg_cbytes` decides which of three shapes applies and stops.**
//!    Two of them mutate or allocate: one pushes a zero byte onto the buffer,
//!    one calls `janet_smalloc`. Both are carried out by the caller.
//!  - **`janet_arg_nextmethod` returns the entry, not the keyword.** Wrapping
//!    the name allocates.
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
const c = abi.c;

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

export fn janet_arg_fixarity(arity: i32, fix: i32, fault: *c.JanetArgFault) c_int {
    if (arity == fix) return 1;
    fault.kind = @intCast(c.JANET_ARG_ARITY_FIX);
    fault.arity = arity;
    fault.bound = fix;
    return 0;
}

/// A negative bound means "unbounded on that side", which is how a cfunction
/// with no maximum spells itself.
export fn janet_arg_arity(arity: i32, min: i32, max: i32, fault: *c.JanetArgFault) c_int {
    if (min >= 0 and arity < min) {
        fault.kind = @intCast(c.JANET_ARG_ARITY_MIN);
        fault.arity = arity;
        fault.bound = min;
        return 0;
    }
    if (max >= 0 and arity > max) {
        fault.kind = @intCast(c.JANET_ARG_ARITY_MAX);
        fault.arity = arity;
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
