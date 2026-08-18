//! The value representation itself. This is Part 10 of Phase 8 and it takes
//! the whole of `src/core/wrap.c`: the type and truthiness predicates, the
//! sixteen unwrap entry points, the nineteen wrap entry points, the per-layout
//! nanbox helpers `janet.h` declares beside them, and `janet_memalloc_empty`
//! and `janet_memempty`, which are allocation rather than representation and
//! are what `struct.c` and `table.c` build their bucket arrays with.
//!
//! Porting this moves the representation; it does not change it. Every bit
//! pattern a `Janet` can hold is the one the C original produced, on every
//! target, under every one of the three layouts.
//!
//! ## One file, three implementations, and no `#ifdef` to read them from
//!
//! `wrap.c` is the one file in the phase whose *content* changes shape per
//! target. `JANET_NANBOX_64`, `JANET_NANBOX_32` and the tagged-union fallback
//! are three different implementations behind one set of signatures, and which
//! one a build gets is decided by `janet.h` from the target's pointer width and
//! architecture rather than by a build option alone.
//!
//! translate-c does not surface a macro defined with no value, so none of those
//! three names reaches Zig. They do not need to. The *shape of the translated
//! `Janet`* already distinguishes all three, and reading the layout off the type
//! is exact where restating the `#ifdef` chain would be a second copy of it:
//!
//!   - `JANET_NANBOX_64` -- a union of `u64`, `i64`, `number` and `pointer`.
//!   - `JANET_NANBOX_32` -- a union whose first member is the `tagged` struct.
//!   - the fallback      -- a *struct* of `as` and `type`.
//!
//! `value_order.zig` already selects on `@hasField(c.Janet, "u64")` to spell
//! `janet_u64`; this is the same test carried to its conclusion.
//!
//! ## What each layout exports is not the same set
//!
//! This is the second increment in the phase whose functions do not all exist
//! in every configuration, and unlike Part 8 the variation is three-way rather
//! than on or off. Twenty-four symbols are common to all three. On top of them
//! a NaN-boxed build adds the eighteen wrappers `janet.h` provides as macros
//! and `wrap.c` fills in as functions, plus five nanbox-64 helpers or two
//! nanbox-32 ones; the tagged build defines its wrappers outright, and defines
//! every one of them except `janet_wrap_integer`.
//!
//! That last asymmetry is a defect, recorded in `FOUND.md` before this
//! increment opened the file: `janet_wrap_integer` is declared in `janet.h`
//! beside twenty-one siblings and defined by `wrap.c` only inside the
//! nanbox-only block, so it does not link under `-Dnanbox=false`. No C caller
//! notices, because they all expand the macro; every Zig subsystem would, which
//! is why `value_access.zig` writes the macro out rather than calling it. The
//! port reproduces the gap: the export below is inside a `comptime` block that
//! tests the layout, so a tagged build has no `janet_wrap_integer` symbol, and
//! the two selectors have the same symbol set. Fixing it is a decision the
//! phase has not taken.
//!
//! ## The nanbox-32 layout is written, compiled, and not executed
//!
//! The third layout is real rather than hypothetical: `riscv32-linux-musl` is
//! the one 32-bit target Zig 0.16's translate-c can handle -- musl's 32-bit
//! `time64` `__REDIR` declarations defeat Aro on x86 and arm -- and the whole
//! tree cross-compiles for it. Alpine ships `qemu-riscv32`, so the binaries run.
//!
//! `test/value_wrap.c` **passes there against the C original**, which is what
//! validates the nanbox-32 arm of its bit-layout assertions. It does not pass
//! against this file, and the reason is not in this file. Zig 0.16 and clang
//! disagree about how many argument registers an eight-byte union consumes
//! under riscv32 ILP32D, so a lone `Janet` parameter arrives intact and every
//! argument *behind* one arrives displaced. `janet_type(Janet)` and
//! `janet_truthy(Janet)` therefore answer correctly while
//! `janet_checktype(Janet, JanetType)` reads a garbage type tag — the shape of
//! the failure, and not a property of the code. `PLAN.md` has the measurement
//! that isolated it from the runtime.
//!
//! It is a wall the phase already stood behind. `janet_equals(Janet, Janet)`
//! from Part 7a reads a garbage second value there and so returns 0 for two
//! *identical* arguments, which is why an all-Zig riscv32 build dies inside
//! `janet_init`.
//! Nothing here can move it; `PLAN.md` records it as a toolchain constraint on
//! the phase rather than a defect of any increment.
//!
//! ## Type punning is the subject, not an accident
//!
//! Every function here writes one member of a union and reads another. That is
//! defined in C and it is defined in Zig for an `extern union`, which is what
//! translate-c produces, so the port does not need `@bitCast` gymnastics to say
//! what the original says. The one place the difference is visible is
//! `janet_nanbox_from_pointer`, which stores a pointer and then shifts and tags
//! the *word* -- written here as the same two statements over the same union.
//!
//! ## No `defer`, and no marker either
//!
//! Nothing in this file calls anything that can raise. `janet_memalloc_empty`
//! reaches `janet_malloc` and, on failure, `JANET_OUT_OF_MEMORY`, which exits
//! rather than jumping. So the file needs no `//! jump-transparent` marker: the
//! marker records that a Janet signal may pass *through* these frames, and
//! nothing below them can produce one.
//!
//! ## What is reproduced rather than repaired
//!
//! Three things beyond the missing `janet_wrap_integer`.
//!
//! `janet_memalloc_empty` charges `janet_vm.next_collection` for the block
//! *before* it checks whether the allocation succeeded, so a failed allocation
//! leaves the collection budget advanced. It then exits, so nothing observes
//! it; the order is kept because the rule this phase follows is that a port
//! reproduces the order of writes unless there is a reason to do otherwise.
//!
//! Its `(size_t) count * sizeof(JanetKV)` sign-extends a negative count into an
//! enormous size, which is what makes a negative capacity an out-of-memory exit
//! rather than a small allocation. Reproduced with a sign-extending cast and a
//! wrapping multiply, for the same reason `value_alloc.zig` reproduces
//! `janet_fiber_reset`'s overflow: a trap would be a new behaviour where the C
//! original has one already.
//!
//! `janet_wrap_number_safe` canonicalises a NaN under both NaN-boxed layouts
//! and *not* under the tagged one, where a signalling NaN's payload survives
//! into the value. That asymmetry is in the C original -- the tagged branch is
//! a bare call to `janet_wrap_number` -- and it is harmless there, because the
//! tagged layout does not use the NaN space for anything.
//!
//! One thing is *not* reproducible, and it is `janet_unwrap_integer`. The macro
//! it fills is `(int32_t) janet_unwrap_number(x)`, a cast whose behaviour C
//! leaves undefined for a NaN or an out-of-range double -- and the two
//! behavioural targets already disagree about it, since aarch64's `fcvtzs`
//! saturates where x86-64's `cvttsd2si` yields `INT32_MIN`. Zig has no
//! saturating float-to-integer cast and `@intFromFloat` is illegal behaviour
//! outside the destination range, so the port tests before converting. It
//! saturates, which is the development target's answer; `FOUND.md` records the
//! divergence, and no contract pins it, by the phase's rule about undefined
//! behaviour.

const std = @import("std");
const abi = @import("abi");
const c = abi.c;

/// `janet_vm` as `src/core/state.h` declares it, resolved through `abi.zig`.
inline fn vm() *c.JanetVM {
    return &c.janet_vm;
}

// ------------------------------------------------------------------- layout

const Layout = enum { nanbox64, nanbox32, tagged };

/// Which of `janet.h`'s three value representations this build compiled with,
/// read off the translated type rather than from a macro. See the header.
const layout: Layout = if (@hasField(c.Janet, "as"))
    .tagged
else if (@hasField(c.Janet, "tagged"))
    .nanbox32
else
    .nanbox64;

const is_nanbox = layout != .tagged;

/// `janet.h` exposes the type tags as `c_int`; every layout stores them in a
/// narrower or differently-signed field, so the conversions are collected here
/// rather than spelled at each of the thirty-odd use sites.
inline fn tagOf(comptime t: c_int) c.JanetType {
    return @intCast(t);
}

// -------------------------------------------------------- the three layouts

/// `JANET_NANBOX_64`. The payload lives in the low 47 bits of a double whose
/// exponent is all ones, the type in the four bits above it, and a pointer is
/// stored shifted right by `JANET_NANBOX_64_POINTER_SHIFT` so that a target
/// with more than 47 bits of address space still fits.
const nanbox64 = struct {
    const tagbits: u64 = c.JANET_NANBOX_TAGBITS;
    const payloadbits: u64 = c.JANET_NANBOX_PAYLOADBITS;
    const pointer_shift = c.JANET_NANBOX_64_POINTER_SHIFT;

    /// `janet_nanbox_lowtag` and `janet_nanbox_tag`, which are function-like
    /// macros and so do not survive translation.
    inline fn tag(t: c_int) u64 {
        return (@as(u64, @intCast(t)) | 0x1FFF0) << 47;
    }

    inline fn fromBits(bits: u64) c.Janet {
        return .{ .u64 = bits };
    }

    inline fn fromDouble(d: f64) c.Janet {
        return .{ .number = d };
    }

    inline fn fromPayload(t: c_int, payload: u64) c.Janet {
        return fromBits(tag(t) | payload);
    }

    /// `janet_nanbox_to_pointer`. Mask the tag off, undo the alignment shift,
    /// and read the word back as a pointer.
    ///
    /// The C original masks through `x.i64`, the *signed* member, and this uses
    /// `x.u64`. They are the same operation: `JANET_NANBOX_PAYLOADBITS` is an
    /// `unsigned long long`, so C converts the left operand to it before the
    /// `&` and converts the non-negative result back, and the mask's top bit is
    /// clear so nothing is lost either way. Written unsigned here because the
    /// two statements that follow are unsigned and mixing the members would
    /// suggest a distinction that is not there.
    inline fn toPointer(x_in: c.Janet) ?*anyopaque {
        var x = x_in;
        x.u64 &= payloadbits;
        x.u64 <<= pointer_shift;
        return x.pointer;
    }

    /// `janet_nanbox_from_pointer`. The C original writes the pointer into the
    /// union and then shifts and tags the word; the commented-out alignment
    /// assertion it carries is left commented out here too, because turning it
    /// on would reject pointers the collector currently accepts.
    inline fn fromPointer(p: ?*anyopaque, tagmask: u64) c.Janet {
        var ret: c.Janet = undefined;
        ret.pointer = p;
        ret.u64 >>= pointer_shift;
        ret.u64 |= tagmask;
        return ret;
    }

    inline fn fromCPointer(p: ?*const anyopaque, tagmask: u64) c.Janet {
        return fromPointer(@constCast(p), tagmask);
    }

    inline fn wrapPointer(p: ?*anyopaque, comptime t: c_int) c.Janet {
        return fromPointer(p, tag(t));
    }

    inline fn wrapCPointer(p: ?*const anyopaque, comptime t: c_int) c.Janet {
        return fromCPointer(p, tag(t));
    }

    inline fn typeOf(x: c.Janet) c.JanetType {
        return if (std.math.isNan(x.number))
            @intCast((x.u64 >> 47) & 0xF)
        else
            tagOf(c.JANET_NUMBER);
    }

    inline fn isNumber(x: c.Janet) bool {
        return !std.math.isNan(x.number) or ((x.u64 >> 47) & 0xF) == c.JANET_NUMBER;
    }

    inline fn checkType(x: c.Janet, t: c.JanetType) bool {
        return if (t == c.JANET_NUMBER)
            isNumber(x)
        else
            (x.u64 & tagbits) == tag(@intCast(t));
    }

    inline fn truthy(x: c.Janet) bool {
        return !checkType(x, tagOf(c.JANET_NIL)) and
            (!checkType(x, tagOf(c.JANET_BOOLEAN)) or (x.u64 & 0x1) != 0);
    }

    inline fn unwrapBoolean(x: c.Janet) c_int {
        return @intCast(x.u64 & 0x1);
    }

    inline fn unwrapNumber(x: c.Janet) f64 {
        return x.number;
    }

    inline fn wrapNumber(d: f64) c.Janet {
        return fromDouble(d);
    }

    /// `janet_wrap_number_safe`. A NaN is replaced by the canonical quiet one,
    /// so that a payload smuggled in through a marshalled double cannot be read
    /// back as a tagged value.
    inline fn wrapNumberSafe(d: f64) c.Janet {
        var ret: c.Janet = undefined;
        ret.number = if (std.math.isNan(d)) std.math.nan(f64) else d;
        return ret;
    }
};

/// `JANET_NANBOX_32`. A twelve-byte value on a four-byte-pointer target: the
/// payload and a 32-bit type tag overlaid on a double, with every non-number
/// tag below `JANET_DOUBLE_OFFSET` so that a double's high word can be biased
/// into the range above it.
const nanbox32 = struct {
    const double_offset: u32 = c.JANET_DOUBLE_OFFSET;

    /// `janet_nanbox32_from_tagi`.
    inline fn fromTagI(t: u32, integer: i32) c.Janet {
        var ret: c.Janet = undefined;
        ret.tagged.type = t;
        ret.tagged.payload.integer = integer;
        return ret;
    }

    /// `janet_nanbox32_from_tagp`.
    inline fn fromTagP(t: u32, p: ?*anyopaque) c.Janet {
        var ret: c.Janet = undefined;
        ret.tagged.type = t;
        ret.tagged.payload.pointer = p;
        return ret;
    }

    inline fn wrapPointer(p: ?*anyopaque, comptime t: c_int) c.Janet {
        return fromTagP(@intCast(t), p);
    }

    inline fn wrapCPointer(p: ?*const anyopaque, comptime t: c_int) c.Janet {
        return fromTagP(@intCast(t), @constCast(p));
    }

    inline fn typeOf(x: c.Janet) c.JanetType {
        return if (x.tagged.type < double_offset)
            @intCast(x.tagged.type)
        else
            tagOf(c.JANET_NUMBER);
    }

    inline fn checkType(x: c.Janet, t: c.JanetType) bool {
        return if (t == c.JANET_NUMBER)
            x.tagged.type >= double_offset
        else
            x.tagged.type == @as(u32, @intCast(t));
    }

    inline fn truthy(x: c.Janet) bool {
        return x.tagged.type != c.JANET_NIL and
            (x.tagged.type != c.JANET_BOOLEAN or (x.tagged.payload.integer & 0x1) != 0);
    }

    inline fn unwrapBoolean(x: c.Janet) c_int {
        return x.tagged.payload.integer;
    }

    /// `janet_unwrap_number`, which is a *function* under this layout rather
    /// than a macro: the bias has to come back off the high word before the
    /// double can be read.
    inline fn unwrapNumber(x_in: c.Janet) f64 {
        var x = x_in;
        x.tagged.type -%= double_offset;
        return x.number;
    }

    /// `janet_wrap_number`, likewise a function here. The addition is on a
    /// `uint32_t` and so wraps by definition in C; the wrapping operator says
    /// the same thing.
    inline fn wrapNumber(d: f64) c.Janet {
        var ret: c.Janet = undefined;
        ret.number = d;
        ret.tagged.type +%= double_offset;
        return ret;
    }

    inline fn wrapNumberSafe(d: f64) c.Janet {
        return wrapNumber(if (std.math.isNan(d)) std.math.nan(f64) else d);
    }
};

/// The tagged fallback: a payload union and a separate `JanetType` field, and
/// no NaN space in use at all. Sixteen bytes on a 64-bit target where either
/// NaN-boxed layout is eight or twelve.
const tagged = struct {
    /// `JANET_WRAP_DEFINE`'s body. The `as.u64 = 0` is what the macro's own
    /// comment calls zeroing the other bits in case of a 32-bit payload, and it
    /// has to precede the narrower store rather than follow it.
    inline fn wrapPointer(p: ?*anyopaque, comptime t: c_int) c.Janet {
        var y: c.Janet = undefined;
        y.type = tagOf(t);
        y.as.u64 = 0;
        y.as.pointer = p;
        return y;
    }

    inline fn wrapCPointer(p: ?*const anyopaque, comptime t: c_int) c.Janet {
        var y: c.Janet = undefined;
        y.type = tagOf(t);
        y.as.u64 = 0;
        y.as.cpointer = p;
        return y;
    }

    inline fn typeOf(x: c.Janet) c.JanetType {
        return x.type;
    }

    inline fn checkType(x: c.Janet, t: c.JanetType) bool {
        return x.type == t;
    }

    inline fn truthy(x: c.Janet) bool {
        return x.type != c.JANET_NIL and
            (x.type != c.JANET_BOOLEAN or (x.as.u64 & 0x1) != 0);
    }

    inline fn unwrapBoolean(x: c.Janet) c_int {
        return @intCast(x.as.u64 & 0x1);
    }

    inline fn unwrapNumber(x: c.Janet) f64 {
        return x.as.number;
    }

    inline fn wrapNumber(d: f64) c.Janet {
        var y: c.Janet = undefined;
        y.type = tagOf(c.JANET_NUMBER);
        y.as.u64 = 0;
        y.as.number = d;
        return y;
    }

    /// The one layout whose `janet_wrap_number_safe` does *not* canonicalise a
    /// NaN, because it has no NaN space to protect. Reproduced.
    inline fn wrapNumberSafe(d: f64) c.Janet {
        return wrapNumber(d);
    }

    inline fn wrapNil() c.Janet {
        var y: c.Janet = undefined;
        y.type = tagOf(c.JANET_NIL);
        y.as.u64 = 0;
        return y;
    }

    inline fn wrapBooleanBits(bit: u64) c.Janet {
        var y: c.Janet = undefined;
        y.type = tagOf(c.JANET_BOOLEAN);
        y.as.u64 = bit;
        return y;
    }
};

/// The layout selected for this build, named once so the bodies below read as
/// one implementation rather than as a three-way switch repeated per function.
const repr = switch (layout) {
    .nanbox64 => nanbox64,
    .nanbox32 => nanbox32,
    .tagged => tagged,
};

// ------------------------------------------------------------ shared spellings

/// The four wrappers whose payload is a bit rather than a pointer. Both
/// NaN-boxed layouts build them from a tag and an immediate; the tagged one
/// writes the two fields directly.
inline fn wrapNil() c.Janet {
    return switch (layout) {
        .nanbox64 => nanbox64.fromPayload(c.JANET_NIL, 1),
        .nanbox32 => nanbox32.fromTagI(c.JANET_NIL, 0),
        .tagged => tagged.wrapNil(),
    };
}

inline fn wrapBoolean(b: bool) c.Janet {
    const bit: u64 = @intFromBool(b);
    return switch (layout) {
        .nanbox64 => nanbox64.fromPayload(c.JANET_BOOLEAN, bit),
        .nanbox32 => nanbox32.fromTagI(c.JANET_BOOLEAN, @intCast(bit)),
        .tagged => tagged.wrapBooleanBits(bit),
    };
}

/// `janet_wrap_integer`, which is `janet_wrap_number((int32_t)(x))` under every
/// layout. Named here because the export it feeds exists only under two of
/// them; see the header.
inline fn wrapInteger(x: i32) c.Janet {
    return repr.wrapNumber(@floatFromInt(x));
}

/// `janet_unwrap_integer`, the one entry point whose C original has no defined
/// answer for every input. The range test is what Zig requires and C omits;
/// outside it the result saturates rather than trapping. See the header.
inline fn unwrapInteger(x: c.Janet) i32 {
    const d = repr.unwrapNumber(x);
    if (std.math.isNan(d)) return 0;
    if (d >= 2147483647.0) return std.math.maxInt(i32);
    if (d <= -2147483648.0) return std.math.minInt(i32);
    return @intFromFloat(d);
}

// ------------------------------------------------------------- macro fills

export fn janet_type(x: c.Janet) callconv(.c) c.JanetType {
    return repr.typeOf(x);
}

export fn janet_checktype(x: c.Janet, t: c.JanetType) callconv(.c) c_int {
    return @intFromBool(repr.checkType(x, t));
}

export fn janet_checktypes(x: c.Janet, typeflags: c_int) callconv(.c) c_int {
    const bit = @as(c_int, 1) << @intCast(repr.typeOf(x));
    return bit & typeflags;
}

export fn janet_truthy(x: c.Janet) callconv(.c) c_int {
    return @intFromBool(repr.truthy(x));
}

// ----------------------------------------------------------------- unwraps

/// Every pointer unwrap is the same read under a different result type: the
/// NaN-boxed layouts strip the tag through `janet_nanbox_to_pointer`, and the
/// two others read the payload field. No unwrap checks the type -- that is the
/// caller's job in C and it stays the caller's job here.
inline fn unwrapPointer(x: c.Janet) ?*anyopaque {
    return switch (layout) {
        .nanbox64 => nanbox64.toPointer(x),
        .nanbox32 => x.tagged.payload.pointer,
        .tagged => x.as.pointer,
    };
}

export fn janet_unwrap_struct(x: c.Janet) callconv(.c) c.JanetStruct {
    return @ptrCast(@alignCast(unwrapPointer(x)));
}

export fn janet_unwrap_tuple(x: c.Janet) callconv(.c) c.JanetTuple {
    return @ptrCast(@alignCast(unwrapPointer(x)));
}

export fn janet_unwrap_fiber(x: c.Janet) callconv(.c) [*c]c.JanetFiber {
    return @ptrCast(@alignCast(unwrapPointer(x)));
}

export fn janet_unwrap_array(x: c.Janet) callconv(.c) [*c]c.JanetArray {
    return @ptrCast(@alignCast(unwrapPointer(x)));
}

export fn janet_unwrap_table(x: c.Janet) callconv(.c) [*c]c.JanetTable {
    return @ptrCast(@alignCast(unwrapPointer(x)));
}

export fn janet_unwrap_buffer(x: c.Janet) callconv(.c) [*c]c.JanetBuffer {
    return @ptrCast(@alignCast(unwrapPointer(x)));
}

export fn janet_unwrap_string(x: c.Janet) callconv(.c) c.JanetString {
    return @ptrCast(unwrapPointer(x));
}

export fn janet_unwrap_symbol(x: c.Janet) callconv(.c) c.JanetSymbol {
    return @ptrCast(unwrapPointer(x));
}

export fn janet_unwrap_keyword(x: c.Janet) callconv(.c) c.JanetKeyword {
    return @ptrCast(unwrapPointer(x));
}

export fn janet_unwrap_abstract(x: c.Janet) callconv(.c) c.JanetAbstract {
    return unwrapPointer(x);
}

export fn janet_unwrap_pointer(x: c.Janet) callconv(.c) ?*anyopaque {
    return unwrapPointer(x);
}

export fn janet_unwrap_function(x: c.Janet) callconv(.c) [*c]c.JanetFunction {
    return @ptrCast(@alignCast(unwrapPointer(x)));
}

/// A function pointer has a stricter alignment than `*anyopaque`, so this is
/// the one unwrap that goes through the address rather than through
/// `@ptrCast`. `trace_frames.zig` recovers a cfunction from a frame's `pc` the
/// same way.
export fn janet_unwrap_cfunction(x: c.Janet) callconv(.c) c.JanetCFunction {
    return @ptrFromInt(@intFromPtr(unwrapPointer(x)));
}

export fn janet_unwrap_boolean(x: c.Janet) callconv(.c) c_int {
    return repr.unwrapBoolean(x);
}

export fn janet_unwrap_number(x: c.Janet) callconv(.c) f64 {
    return repr.unwrapNumber(x);
}

export fn janet_unwrap_integer(x: c.Janet) callconv(.c) i32 {
    return unwrapInteger(x);
}

// ------------------------------------------------------------------- wraps

fn wrapNilFn() callconv(.c) c.Janet {
    return wrapNil();
}

fn wrapTrue() callconv(.c) c.Janet {
    return wrapBoolean(true);
}

fn wrapFalse() callconv(.c) c.Janet {
    return wrapBoolean(false);
}

fn wrapBooleanFn(x: c_int) callconv(.c) c.Janet {
    return wrapBoolean(x != 0);
}

fn wrapString(x: c.JanetString) callconv(.c) c.Janet {
    return repr.wrapCPointer(x, c.JANET_STRING);
}

fn wrapSymbol(x: c.JanetSymbol) callconv(.c) c.Janet {
    return repr.wrapCPointer(x, c.JANET_SYMBOL);
}

fn wrapKeyword(x: c.JanetKeyword) callconv(.c) c.Janet {
    return repr.wrapCPointer(x, c.JANET_KEYWORD);
}

fn wrapArray(x: [*c]c.JanetArray) callconv(.c) c.Janet {
    return repr.wrapPointer(x, c.JANET_ARRAY);
}

fn wrapTuple(x: c.JanetTuple) callconv(.c) c.Janet {
    return repr.wrapCPointer(x, c.JANET_TUPLE);
}

fn wrapStruct(x: c.JanetStruct) callconv(.c) c.Janet {
    return repr.wrapCPointer(x, c.JANET_STRUCT);
}

fn wrapFiber(x: [*c]c.JanetFiber) callconv(.c) c.Janet {
    return repr.wrapPointer(x, c.JANET_FIBER);
}

fn wrapBuffer(x: [*c]c.JanetBuffer) callconv(.c) c.Janet {
    return repr.wrapPointer(x, c.JANET_BUFFER);
}

fn wrapFunction(x: [*c]c.JanetFunction) callconv(.c) c.Janet {
    return repr.wrapPointer(x, c.JANET_FUNCTION);
}

fn wrapCFunction(x: c.JanetCFunction) callconv(.c) c.Janet {
    return repr.wrapPointer(@constCast(@ptrCast(x)), c.JANET_CFUNCTION);
}

fn wrapTable(x: [*c]c.JanetTable) callconv(.c) c.Janet {
    return repr.wrapPointer(x, c.JANET_TABLE);
}

fn wrapAbstract(x: c.JanetAbstract) callconv(.c) c.Janet {
    return repr.wrapPointer(x, c.JANET_ABSTRACT);
}

fn wrapPointerFn(x: ?*anyopaque) callconv(.c) c.Janet {
    return repr.wrapPointer(x, c.JANET_POINTER);
}

fn wrapIntegerFn(x: i32) callconv(.c) c.Janet {
    return wrapInteger(x);
}

export fn janet_wrap_number(x: f64) callconv(.c) c.Janet {
    return repr.wrapNumber(x);
}

export fn janet_wrap_number_safe(d: f64) callconv(.c) c.Janet {
    return repr.wrapNumberSafe(d);
}

// The eighteen wrappers `wrap.c` provides in one block under either NaN-boxed
// layout and one by one under the tagged one. They are exported here from a
// single list because the bodies are identical across the three; only
// `janet_wrap_integer` varies, and it varies by being absent.
comptime {
    @export(&wrapNilFn, .{ .name = "janet_wrap_nil" });
    @export(&wrapTrue, .{ .name = "janet_wrap_true" });
    @export(&wrapFalse, .{ .name = "janet_wrap_false" });
    @export(&wrapBooleanFn, .{ .name = "janet_wrap_boolean" });
    @export(&wrapString, .{ .name = "janet_wrap_string" });
    @export(&wrapSymbol, .{ .name = "janet_wrap_symbol" });
    @export(&wrapKeyword, .{ .name = "janet_wrap_keyword" });
    @export(&wrapArray, .{ .name = "janet_wrap_array" });
    @export(&wrapTuple, .{ .name = "janet_wrap_tuple" });
    @export(&wrapStruct, .{ .name = "janet_wrap_struct" });
    @export(&wrapFiber, .{ .name = "janet_wrap_fiber" });
    @export(&wrapBuffer, .{ .name = "janet_wrap_buffer" });
    @export(&wrapFunction, .{ .name = "janet_wrap_function" });
    @export(&wrapCFunction, .{ .name = "janet_wrap_cfunction" });
    @export(&wrapTable, .{ .name = "janet_wrap_table" });
    @export(&wrapAbstract, .{ .name = "janet_wrap_abstract" });
    @export(&wrapPointerFn, .{ .name = "janet_wrap_pointer" });
    // Absent under the tagged layout, reproducing the defect `FOUND.md`
    // records against `wrap.c`.
    if (is_nanbox) @export(&wrapIntegerFn, .{ .name = "janet_wrap_integer" });
}

// -------------------------------------------------- per-layout nanbox helpers

fn nanboxToPointer(x: c.Janet) callconv(.c) ?*anyopaque {
    return nanbox64.toPointer(x);
}

fn nanboxFromPointer(p: ?*anyopaque, tagmask: u64) callconv(.c) c.Janet {
    return nanbox64.fromPointer(p, tagmask);
}

fn nanboxFromCPointer(p: ?*const anyopaque, tagmask: u64) callconv(.c) c.Janet {
    return nanbox64.fromCPointer(p, tagmask);
}

fn nanboxFromDouble(d: f64) callconv(.c) c.Janet {
    return nanbox64.fromDouble(d);
}

fn nanboxFromBits(bits: u64) callconv(.c) c.Janet {
    return nanbox64.fromBits(bits);
}

fn nanbox32FromTagI(t: u32, integer: i32) callconv(.c) c.Janet {
    return nanbox32.fromTagI(t, integer);
}

fn nanbox32FromTagP(t: u32, p: ?*anyopaque) callconv(.c) c.Janet {
    return nanbox32.fromTagP(t, p);
}

// `janet.h` declares five helpers under `JANET_NANBOX_64` and two under
// `JANET_NANBOX_32`, and each set is the expansion target of that layout's wrap
// and unwrap macros. A build gets exactly one set, which is why these are
// exported from a `comptime` block rather than declared `export fn`: a body
// naming `x.tagged` must not be analysed in a build where `Janet` has no such
// field.
comptime {
    switch (layout) {
        .nanbox64 => {
            @export(&nanboxToPointer, .{ .name = "janet_nanbox_to_pointer" });
            @export(&nanboxFromPointer, .{ .name = "janet_nanbox_from_pointer" });
            @export(&nanboxFromCPointer, .{ .name = "janet_nanbox_from_cpointer" });
            @export(&nanboxFromDouble, .{ .name = "janet_nanbox_from_double" });
            @export(&nanboxFromBits, .{ .name = "janet_nanbox_from_bits" });
        },
        .nanbox32 => {
            @export(&nanbox32FromTagI, .{ .name = "janet_nanbox32_from_tagi" });
            @export(&nanbox32FromTagP, .{ .name = "janet_nanbox32_from_tagp" });
        },
        .tagged => {},
    }
}

// -------------------------------------------------------- empty bucket arrays

/// `sizeof(JanetKV) * count` as C computes it: the `int32_t` is converted to
/// `size_t`, which sign-extends a negative count into an enormous size, and the
/// multiply wraps. Both are reproduced -- the enormous size is what turns a
/// negative capacity into an out-of-memory exit.
inline fn kvBytes(count: i32) usize {
    return @as(usize, @bitCast(@as(isize, count))) *% @sizeOf(c.JanetKV);
}

/// `janet_memalloc_empty`. A `janet_malloc` block of `count` key/value pairs,
/// every one of them nil, charged against the collection budget.
///
/// The charge happens before the null check, exactly as in C; nothing observes
/// the difference, because the failure path exits.
export fn janet_memalloc_empty(count: i32) callconv(.c) ?*anyopaque {
    const bytes = kvBytes(count);
    const mem = c.janet_malloc(bytes);
    vm().next_collection +%= bytes;
    if (mem == null) c.janet_zig_out_of_memory();
    const mmem: [*]c.JanetKV = @ptrCast(@alignCast(mem));
    var i: i32 = 0;
    while (i < count) : (i += 1) {
        const kv = &mmem[@intCast(i)];
        kv.key = wrapNil();
        kv.value = wrapNil();
    }
    return mem;
}

/// `janet_memempty`. The same fill over a block the caller already owns, which
/// is how a table is cleared and how a struct's bucket array is initialised
/// from the scratch allocator.
export fn janet_memempty(mem: [*c]c.JanetKV, count: i32) callconv(.c) void {
    var i: i32 = 0;
    while (i < count) : (i += 1) {
        mem[@intCast(i)].key = wrapNil();
        mem[@intCast(i)].value = wrapNil();
    }
}
