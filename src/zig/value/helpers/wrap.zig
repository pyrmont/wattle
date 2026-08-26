//! Wrap: a `Janet` out of something, and something out of a `Janet`.
//!
//! Phase 12's namespace batch 4 split `value_wrap.zig` into this file and
//! `kind.zig` -- the four inspection names went there because they convert
//! nothing -- and increment 6f moved both into `value/helpers/` and retired
//! the gerunds. `port/NAMESPACES.md` has the scheme; what matters at a call
//! site is that **the names go by direction rather than by verb**:
//! `wrap.fromTable(t)` and `wrap.toTable(v)`, 36 members in two columns.
//!
//! That shape dissolves four separate problems at once, which is the evidence
//! it is the right one. `true` and `false` are Zig keywords, so a
//! type-stripped `wrap.true()` is impossible and `fromTrue()` is an
//! ordinary identifier. Keyword and symbol both wanted `wrap` in one type
//! leaf, and so did cfunction and function; `fromKeyword` sits beside
//! `fromSymbol` without a word between them. And `wrap.pointer(p)` would
//! have collided with the private tag-taking primitive, which stays private
//! because no type leaf needs it.
//!
//! `fromNil()` has nothing to be *from* -- nil is the one immediate with no
//! source value. Kept anyway, for uniformity: a reader scanning a column of
//! `from*` should not have to notice the one that is not.
//!
//! **An earlier draft split this file by type instead**, moving `wrapArray`
//! and `unwrapArray` onto `arrays.zig` and so on, so that every type leaf was
//! complete. `NAMESPACES.md` reverted that and records why: `wrapArray` is
//! `repr.wrapPointer(x, JANET_ARRAY)`, so ten type leaves would each need a
//! layout primitive made public, and layout-dependent code would scatter
//! across ten files when the reason this is one file at all is that the three
//! layouts share `repr`. **A cohesive file should not be split for symmetry
//! at the call site.**
//!
//! `janet_memalloc_empty` and `janet_memempty` are still here and are still
//! allocation rather than representation -- see below. They are `pub` now
//! rather than reached by symbol, which deletes three of the `extern fn`
//! declarations increment 6a named in `tables.zig` and `structs.zig`; where
//! they should actually live is a dictionary question, and
//! `NAMESPACES.md` open question 2c has it.
//!
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
//! Both this file and `value_order.zig` used to recover which of the three was
//! compiled by asking the *translated type* — `@hasField(c.Janet, "u64")` for
//! `janet_u64`, `@hasField(c.Janet, "as")` here. Phase 12 increment 1 replaced
//! both with `config.value_repr`: reading the layout off the C type is what
//! made `janet.h` the place the value representation was *decided* rather than
//! merely declared.
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
//! `test/value_wrap.c` **passed there against the C original**, which is what
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
const config = @import("config");
const utils = @import("../../utils.zig");
const fatal = @import("../../fatal.zig");
const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");

/// The file's own struct, so that `abi` and `ops` can name the declarations
/// they shadow. A struct member does not shadow a container declaration, but
/// it does make the unqualified name ambiguous: without this, `ops.wrapNil`
/// would resolve to itself.
const outer = @This();

/// `janet_vm`, whose layout is `types.JanetVM`'s and whose address
/// `cabi.vm()` takes.
inline fn vm() *types.JanetVM {
    return c.vm();
}

// ------------------------------------------------------------------- layout

const Layout = enum { nanbox64, nanbox32, tagged };

/// Which of the three value representations this build compiled with.
///
/// Until Phase 12 increment 1 this was read off the *translated type* --
/// `@hasField(c.Janet, "as")` and `@hasField(c.Janet, "tagged")` -- which made
/// `janet.h` the place the value representation was decided rather than merely
/// declared. `build.zig` decides it now and says so.
const layout: Layout = switch (config.value_repr) {
    .tagged => .tagged,
    .nanbox_32 => .nanbox32,
    .nanbox_64 => .nanbox64,
};

const is_nanbox = layout != .tagged;

/// `janet.h` exposes the type tags as `c_int`; every layout stores them in a
/// narrower or differently-signed field, so the conversions are collected here
/// rather than spelled at each of the thirty-odd use sites.
inline fn tagOf(comptime t: c_int) types.JanetType {
    return @intCast(t);
}

// -------------------------------------------------------- the three layouts

/// `JANET_NANBOX_64`. The payload lives in the low 47 bits of a double whose
/// exponent is all ones, the type in the four bits above it, and a pointer is
/// stored shifted right by `JANET_NANBOX_64_POINTER_SHIFT` so that a target
/// with more than 47 bits of address space still fits.
const nanbox64 = struct {
    const tagbits: u64 = constants.JANET_NANBOX_TAGBITS;
    const payloadbits: u64 = constants.JANET_NANBOX_PAYLOADBITS;
    const pointer_shift = constants.JANET_NANBOX_64_POINTER_SHIFT;

    /// `janet_nanbox_lowtag` and `janet_nanbox_tag`, which are function-like
    /// macros and so do not survive translation.
    inline fn tag(t: c_int) u64 {
        return (@as(u64, @intCast(t)) | 0x1FFF0) << 47;
    }

    inline fn fromBits(bits: u64) types.Janet {
        return .{ .u64 = bits };
    }

    inline fn fromDouble(d: f64) types.Janet {
        return .{ .number = d };
    }

    inline fn fromPayload(t: c_int, payload: u64) types.Janet {
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
    inline fn toPointer(x_in: types.Janet) ?*anyopaque {
        var x = x_in;
        x.u64 &= payloadbits;
        x.u64 <<= pointer_shift;
        return x.pointer;
    }

    /// `janet_nanbox_from_pointer`. The C original writes the pointer into the
    /// union and then shifts and tags the word; the commented-out alignment
    /// assertion it carries is left commented out here too, because turning it
    /// on would reject pointers the collector currently accepts.
    inline fn fromPointer(p: ?*anyopaque, tagmask: u64) types.Janet {
        var ret: types.Janet = undefined;
        ret.pointer = p;
        ret.u64 >>= pointer_shift;
        ret.u64 |= tagmask;
        return ret;
    }

    inline fn fromCPointer(p: ?*const anyopaque, tagmask: u64) types.Janet {
        return nanbox64.fromPointer(@constCast(p), tagmask);
    }

    // Qualified because batch 4 renamed the container's `wrapPointer` to
    // `fromPointer`, and a struct member does not shadow a container
    // declaration -- it makes the unqualified name ambiguous. Same reason
    // `abi` and `ops` say `outer.`, pointing the other way.
    inline fn wrapPointer(p: ?*anyopaque, comptime t: c_int) types.Janet {
        return nanbox64.fromPointer(p, tag(t));
    }

    inline fn wrapCPointer(p: ?*const anyopaque, comptime t: c_int) types.Janet {
        return fromCPointer(p, tag(t));
    }

    pub inline fn typeOf(x: types.Janet) types.JanetType {
        return if (std.math.isNan(x.number))
            @intCast((x.u64 >> 47) & 0xF)
        else
            tagOf(constants.JANET_NUMBER);
    }

    inline fn isNumber(x: types.Janet) bool {
        return !std.math.isNan(x.number) or ((x.u64 >> 47) & 0xF) == constants.JANET_NUMBER;
    }

    pub inline fn checkType(x: types.Janet, t: types.JanetType) bool {
        return if (t == constants.JANET_NUMBER)
            isNumber(x)
        else
            (x.u64 & tagbits) == tag(@intCast(t));
    }

    pub inline fn truthy(x: types.Janet) bool {
        return !checkType(x, tagOf(constants.JANET_NIL)) and
            (!checkType(x, tagOf(constants.JANET_BOOLEAN)) or (x.u64 & 0x1) != 0);
    }

    inline fn unwrapBoolean(x: types.Janet) c_int {
        return @intCast(x.u64 & 0x1);
    }

    inline fn unwrapNumber(x: types.Janet) f64 {
        return x.number;
    }

    inline fn wrapNumber(d: f64) types.Janet {
        return fromDouble(d);
    }

    /// `janet_wrap_number_safe`. A NaN is replaced by the canonical quiet one,
    /// so that a payload smuggled in through a marshalled double cannot be read
    /// back as a tagged value.
    inline fn wrapNumberSafe(d: f64) types.Janet {
        var ret: types.Janet = undefined;
        ret.number = if (std.math.isNan(d)) std.math.nan(f64) else d;
        return ret;
    }
};

/// `JANET_NANBOX_32`. A twelve-byte value on a four-byte-pointer target: the
/// payload and a 32-bit type tag overlaid on a double, with every non-number
/// tag below `JANET_DOUBLE_OFFSET` so that a double's high word can be biased
/// into the range above it.
const nanbox32 = struct {
    const double_offset: u32 = constants.JANET_DOUBLE_OFFSET;

    /// `janet_nanbox32_from_tagi`.
    inline fn fromTagI(t: u32, integer: i32) types.Janet {
        var ret: types.Janet = undefined;
        ret.tagged.type = t;
        ret.tagged.payload.integer = integer;
        return ret;
    }

    /// `janet_nanbox32_from_tagp`.
    inline fn fromTagP(t: u32, p: ?*anyopaque) types.Janet {
        var ret: types.Janet = undefined;
        ret.tagged.type = t;
        ret.tagged.payload.pointer = p;
        return ret;
    }

    inline fn wrapPointer(p: ?*anyopaque, comptime t: c_int) types.Janet {
        return fromTagP(@intCast(t), p);
    }

    inline fn wrapCPointer(p: ?*const anyopaque, comptime t: c_int) types.Janet {
        return fromTagP(@intCast(t), @constCast(p));
    }

    pub inline fn typeOf(x: types.Janet) types.JanetType {
        return if (x.tagged.type < double_offset)
            @intCast(x.tagged.type)
        else
            tagOf(constants.JANET_NUMBER);
    }

    pub inline fn checkType(x: types.Janet, t: types.JanetType) bool {
        return if (t == constants.JANET_NUMBER)
            x.tagged.type >= double_offset
        else
            x.tagged.type == @as(u32, @intCast(t));
    }

    pub inline fn truthy(x: types.Janet) bool {
        return x.tagged.type != constants.JANET_NIL and
            (x.tagged.type != constants.JANET_BOOLEAN or (x.tagged.payload.integer & 0x1) != 0);
    }

    inline fn unwrapBoolean(x: types.Janet) c_int {
        return x.tagged.payload.integer;
    }

    /// `janet_unwrap_number`, which is a *function* under this layout rather
    /// than a macro: the bias has to come back off the high word before the
    /// double can be read.
    inline fn unwrapNumber(x_in: types.Janet) f64 {
        var x = x_in;
        x.tagged.type -%= double_offset;
        return x.number;
    }

    /// `janet_wrap_number`, likewise a function here. The addition is on a
    /// `uint32_t` and so wraps by definition in C; the wrapping operator says
    /// the same thing.
    inline fn wrapNumber(d: f64) types.Janet {
        var ret: types.Janet = undefined;
        ret.number = d;
        ret.tagged.type +%= double_offset;
        return ret;
    }

    inline fn wrapNumberSafe(d: f64) types.Janet {
        return nanbox32.wrapNumber(if (std.math.isNan(d)) std.math.nan(f64) else d);
    }
};

/// The tagged fallback: a payload union and a separate `JanetType` field, and
/// no NaN space in use at all. Sixteen bytes on a 64-bit target where either
/// NaN-boxed layout is eight or twelve.
const tagged = struct {
    /// `JANET_WRAP_DEFINE`'s body. The `as.u64 = 0` is what the macro's own
    /// comment calls zeroing the other bits in case of a 32-bit payload, and it
    /// has to precede the narrower store rather than follow it.
    inline fn wrapPointer(p: ?*anyopaque, comptime t: c_int) types.Janet {
        var y: types.Janet = undefined;
        y.type = tagOf(t);
        y.as.u64 = 0;
        y.as.pointer = p;
        return y;
    }

    inline fn wrapCPointer(p: ?*const anyopaque, comptime t: c_int) types.Janet {
        var y: types.Janet = undefined;
        y.type = tagOf(t);
        y.as.u64 = 0;
        y.as.cpointer = p;
        return y;
    }

    pub inline fn typeOf(x: types.Janet) types.JanetType {
        return x.type;
    }

    pub inline fn checkType(x: types.Janet, t: types.JanetType) bool {
        return x.type == t;
    }

    pub inline fn truthy(x: types.Janet) bool {
        return x.type != constants.JANET_NIL and
            (x.type != constants.JANET_BOOLEAN or (x.as.u64 & 0x1) != 0);
    }

    inline fn unwrapBoolean(x: types.Janet) c_int {
        return @intCast(x.as.u64 & 0x1);
    }

    inline fn unwrapNumber(x: types.Janet) f64 {
        return x.as.number;
    }

    inline fn wrapNumber(d: f64) types.Janet {
        var y: types.Janet = undefined;
        y.type = tagOf(constants.JANET_NUMBER);
        y.as.u64 = 0;
        y.as.number = d;
        return y;
    }

    /// The one layout whose `janet_wrap_number_safe` does *not* canonicalise a
    /// NaN, because it has no NaN space to protect. Reproduced.
    inline fn wrapNumberSafe(d: f64) types.Janet {
        return tagged.wrapNumber(d);
    }

    inline fn wrapNil() types.Janet {
        var y: types.Janet = undefined;
        y.type = tagOf(constants.JANET_NIL);
        y.as.u64 = 0;
        return y;
    }

    inline fn wrapBooleanBits(bit: u64) types.Janet {
        var y: types.Janet = undefined;
        y.type = tagOf(constants.JANET_BOOLEAN);
        y.as.u64 = bit;
        return y;
    }
};

/// The layout selected for this build, named once so the bodies below read as
/// one implementation rather than as a three-way switch repeated per function.
/// The layout's own implementation, chosen at comptime.
///
/// `pub` for exactly one reader: `kind.zig`, which asks the same three
/// questions of the same representation. Batch 4 split the inspection names
/// out of this file and the layout knowledge could not go with them --
/// duplicating `repr` would be two copies of the bit patterns, which is the
/// definition batch 2 said a leaf may never hold twice. Nothing else should
/// name it; every caller outside `value/` wants `fromX`, `toX`, or one of
/// `kind`'s four.
pub const repr = switch (layout) {
    .nanbox64 => nanbox64,
    .nanbox32 => nanbox32,
    .tagged => tagged,
};

// ----------------------------------------------------- the integer unwrap

/// `janet_unwrap_integer`, the one entry point whose C original has no defined
/// answer for every input. The range test is what Zig requires and C omits;
/// outside it the result saturates rather than trapping. See the header.
pub inline fn toInteger(x: types.Janet) i32 {
    const d = repr.unwrapNumber(x);
    if (std.math.isNan(d)) return 0;
    if (d >= 2147483647.0) return std.math.maxInt(i32);
    if (d <= -2147483648.0) return std.math.minInt(i32);
    return @intFromFloat(d);
}

// ----------------------------------------------------------------- unwraps

/// Every pointer unwrap is the same read under a different result type: the
/// NaN-boxed layouts strip the tag through `janet_nanbox_to_pointer`, and the
/// two others read the payload field. No unwrap checks the type -- that is the
/// caller's job in C and it stays the caller's job here.
pub inline fn toPointer(x: types.Janet) ?*anyopaque {
    return switch (layout) {
        .nanbox64 => nanbox64.toPointer(x),
        .nanbox32 => x.tagged.payload.pointer,
        .tagged => x.as.pointer,
    };
}

pub fn toStruct(x: types.Janet) types.JanetStruct {
    return @ptrCast(@alignCast(toPointer(x)));
}

pub fn toTuple(x: types.Janet) types.JanetTuple {
    return @ptrCast(@alignCast(toPointer(x)));
}

pub fn toFiber(x: types.Janet) *types.JanetFiber {
    return @ptrCast(@alignCast(toPointer(x)));
}

pub fn toArray(x: types.Janet) *types.JanetArray {
    return @ptrCast(@alignCast(toPointer(x)));
}

pub fn toTable(x: types.Janet) *types.JanetTable {
    return @ptrCast(@alignCast(toPointer(x)));
}

pub fn toBuffer(x: types.Janet) *types.JanetBuffer {
    return @ptrCast(@alignCast(toPointer(x)));
}

pub fn toString(x: types.Janet) types.JanetString {
    return @ptrCast(toPointer(x));
}

pub fn toSymbol(x: types.Janet) types.JanetSymbol {
    return @ptrCast(toPointer(x));
}

pub fn toKeyword(x: types.Janet) types.JanetKeyword {
    return @ptrCast(toPointer(x));
}

pub fn toAbstract(x: types.Janet) types.JanetAbstract {
    return toPointer(x);
}

/// The `callconv(.c)` abi over `toPointer`, which is `inline`. The suffix is
/// on the abi rather than the kernel, after the convention increment 5d's
/// population (c1) established.
pub fn toPointerAbi(x: types.Janet) ?*anyopaque {
    return toPointer(x);
}

pub fn toFunction(x: types.Janet) *types.JanetFunction {
    return @ptrCast(@alignCast(toPointer(x)));
}

/// A function pointer has a stricter alignment than `*anyopaque`, so this is
/// the one unwrap that goes through the address rather than through
/// `@ptrCast`. `trace_frames.zig` recovers a cfunction from a frame's `pc` the
/// same way.
pub fn toCfunction(x: types.Janet) types.JanetCFunction {
    return @ptrFromInt(@intFromPtr(toPointer(x)));
}

pub fn toBoolean(x: types.Janet) c_int {
    return repr.unwrapBoolean(x);
}

pub fn toNumber(x: types.Janet) f64 {
    return repr.unwrapNumber(x);
}

/// The `callconv(.c)` abi over `toInteger`. See `toPointerAbi`.
pub fn toIntegerAbi(x: types.Janet) i32 {
    return toInteger(x);
}

// ------------------------------------------------------------------- wraps
//
// Every one of these is a *macro* under both NaN-boxed layouts -- `janet.h`
// spells `janet_wrap_array(s)` and its fifteen neighbours as one under
// `JANET_NANBOX_64` -- and a function only under the tagged one. A C caller
// therefore pays nothing to wrap a value, while the Zig tree, reaching the
// same names through `cabi.zig`'s `pub extern fn`, paid a call on every
// layout. `vm_run.zig` measured that at +89% on the arithmetic workload and
// imported `ops` below to escape it for itself; Phase 12 increment 5d(c)
// gives the rest of the tree the same escape, by making the implementation
// `pub inline` here.
//
// The `callconv(.c)` abis the header also declares are in `abi` below, and
// they are one line each. They exist because `@export` needs an address and
// an `inline fn` has none.

/// The four wrappers whose payload is a bit rather than a pointer. Both
/// NaN-boxed layouts build them from a tag and an immediate; the tagged one
/// writes the two fields directly.
pub inline fn fromNil() types.Janet {
    return switch (layout) {
        .nanbox64 => nanbox64.fromPayload(constants.JANET_NIL, 1),
        .nanbox32 => nanbox32.fromTagI(constants.JANET_NIL, 0),
        .tagged => tagged.wrapNil(),
    };
}

/// `janet_wrap_boolean`, whose parameter is a C `int` in the header and whose
/// macro is `!!(b)`. It keeps the header's type rather than Zig's `bool`
/// because that is what the call sites hold -- `@intFromBool(...)`,
/// `isatty(fd)`, `tm_isdst`, `checktype(...)`. `ops.wrapBoolean` is the
/// `bool` spelling, for a caller that has one.
pub inline fn fromBoolean(b: c_int) types.Janet {
    const bit: u64 = @intFromBool(b != 0);
    return switch (layout) {
        .nanbox64 => nanbox64.fromPayload(constants.JANET_BOOLEAN, bit),
        .nanbox32 => nanbox32.fromTagI(constants.JANET_BOOLEAN, @intCast(bit)),
        .tagged => tagged.wrapBooleanBits(bit),
    };
}

pub inline fn fromTrue() types.Janet {
    return fromBoolean(1);
}

pub inline fn fromFalse() types.Janet {
    return fromBoolean(0);
}

/// `janet_wrap_integer`, which is `janet_wrap_number((int32_t)(x))` under every
/// layout. The export it feeds exists only under two of them; see the header
/// and the `comptime` block at the end of this section.
pub inline fn fromInteger(x: i32) types.Janet {
    return repr.wrapNumber(@floatFromInt(x));
}

pub inline fn fromNumber(x: f64) types.Janet {
    return repr.wrapNumber(x);
}

pub inline fn fromString(x: types.JanetString) types.Janet {
    return repr.wrapCPointer(x, constants.JANET_STRING);
}

pub inline fn fromSymbol(x: types.JanetSymbol) types.Janet {
    return repr.wrapCPointer(x, constants.JANET_SYMBOL);
}

pub inline fn fromKeyword(x: types.JanetKeyword) types.Janet {
    return repr.wrapCPointer(x, constants.JANET_KEYWORD);
}

pub inline fn fromArray(x: *types.JanetArray) types.Janet {
    return repr.wrapPointer(x, constants.JANET_ARRAY);
}

pub inline fn fromTuple(x: types.JanetTuple) types.Janet {
    return repr.wrapCPointer(x, constants.JANET_TUPLE);
}

pub inline fn fromStruct(x: types.JanetStruct) types.Janet {
    return repr.wrapCPointer(x, constants.JANET_STRUCT);
}

/// A null fiber is a legal payload, and `test/value_wrap.zig` contracts it:
/// every fiber with no child wraps one. It must not become nil, and it must
/// come back null.
pub inline fn fromFiber(x: ?*types.JanetFiber) types.Janet {
    return repr.wrapPointer(x, constants.JANET_FIBER);
}

pub inline fn fromBuffer(x: *types.JanetBuffer) types.Janet {
    return repr.wrapPointer(x, constants.JANET_BUFFER);
}

pub inline fn fromFunction(x: *types.JanetFunction) types.Janet {
    return repr.wrapPointer(x, constants.JANET_FUNCTION);
}

pub inline fn fromCfunction(x: types.JanetCFunction) types.Janet {
    return repr.wrapPointer(@ptrCast(@constCast(x)), constants.JANET_CFUNCTION);
}

pub inline fn fromTable(x: *types.JanetTable) types.Janet {
    return repr.wrapPointer(x, constants.JANET_TABLE);
}

pub inline fn fromAbstract(x: types.JanetAbstract) types.Janet {
    return repr.wrapPointer(x, constants.JANET_ABSTRACT);
}

pub inline fn fromPointer(x: ?*anyopaque) types.Janet {
    return repr.wrapPointer(x, constants.JANET_POINTER);
}

/// The one wrap that is not a macro anywhere: `janet.h` declares
/// `janet_wrap_number_safe` as a function under all three layouts, because the
/// NaN canonicalisation it does has no macro spelling.
pub fn fromNumberSafe(d: f64) types.Janet {
    return repr.wrapNumberSafe(d);
}

/// The `callconv(.c)` abis for the wraps above.
///
/// `@export` needs an address and an `inline fn` has none, so each of these
/// gives one symbol something to point at and does nothing else. Nothing but
/// the `comptime` block below and `cabi_check.zig` should name this struct: a
/// Zig caller wants the `inline` above, which is the whole point of 5d(c).
/// They are `pub` so that `cabi_check.zig` can compare each against the
/// declaration `cabi.zig` still holds for it -- nineteen of the pairs 5c named
/// as uncovered, covered here because splitting the name gave the check
/// something to reach.
///
/// The bodies say `outer.` because a struct member does not shadow a container
/// declaration but does make the unqualified name ambiguous -- the same reason
/// `ops` says it.
pub const abi = struct {
    pub fn fromNil() callconv(.c) types.Janet {
        return outer.fromNil();
    }

    pub fn fromBoolean(b: c_int) callconv(.c) types.Janet {
        return outer.fromBoolean(b);
    }

    pub fn fromTrue() callconv(.c) types.Janet {
        return outer.fromTrue();
    }

    pub fn fromFalse() callconv(.c) types.Janet {
        return outer.fromFalse();
    }

    pub fn fromInteger(x: i32) callconv(.c) types.Janet {
        return outer.fromInteger(x);
    }

    pub fn fromNumber(x: f64) callconv(.c) types.Janet {
        return outer.fromNumber(x);
    }

    pub fn fromString(x: types.JanetString) callconv(.c) types.Janet {
        return outer.fromString(x);
    }

    pub fn fromSymbol(x: types.JanetSymbol) callconv(.c) types.Janet {
        return outer.fromSymbol(x);
    }

    pub fn fromKeyword(x: types.JanetKeyword) callconv(.c) types.Janet {
        return outer.fromKeyword(x);
    }

    pub fn fromArray(x: *types.JanetArray) callconv(.c) types.Janet {
        return outer.fromArray(x);
    }

    pub fn fromTuple(x: types.JanetTuple) callconv(.c) types.Janet {
        return outer.fromTuple(x);
    }

    pub fn fromStruct(x: types.JanetStruct) callconv(.c) types.Janet {
        return outer.fromStruct(x);
    }

    pub fn fromFiber(x: ?*types.JanetFiber) callconv(.c) types.Janet {
        return outer.fromFiber(x);
    }

    pub fn fromBuffer(x: *types.JanetBuffer) callconv(.c) types.Janet {
        return outer.fromBuffer(x);
    }

    pub fn fromFunction(x: *types.JanetFunction) callconv(.c) types.Janet {
        return outer.fromFunction(x);
    }

    pub fn fromCfunction(x: types.JanetCFunction) callconv(.c) types.Janet {
        return outer.fromCfunction(x);
    }

    pub fn fromTable(x: *types.JanetTable) callconv(.c) types.Janet {
        return outer.fromTable(x);
    }

    pub fn fromAbstract(x: types.JanetAbstract) callconv(.c) types.Janet {
        return outer.fromAbstract(x);
    }

    pub fn fromPointer(x: ?*anyopaque) callconv(.c) types.Janet {
        return outer.fromPointer(x);
    }
};

// The eighteen wrappers `wrap.c` provides in one block under either NaN-boxed
// layout and one by one under the tagged one. They are exported here from a
// single list because the bodies are identical across the three; only
// `janet_wrap_integer` varies, and it varies by being absent.
comptime {
    // Absent under the tagged layout, reproducing the defect `FOUND.md`
    // records against `wrap.c`.
}

// --------------------------------------------------------- the inline surface

/// The same operations `janet.h` hands a C caller as macros, gathered for a Zig
/// caller that needs them inlined rather than called.
///
/// `run_vm` is the only such caller and the reason this exists. An interpreter
/// that pays a function call to ask what a value is spends more time asking
/// than acting: measured at +89% on the arithmetic workload with these reached
/// through the symbol table, against the same loop with them reached through
/// here. `vm_run.zig`'s `value_wrap` import was a comptime `if` resolving to
/// this file or to `value_wrap_extern.zig` until Phase 11 Part 26; it names
/// this file now, and the shim is gone with the selector Phase 10 Part 18
/// spent.
///
/// Every member delegates to the identically named declaration above rather
/// than holding a second copy of the body. Phase 12 increment 5d(c) is what
/// made that true of the wraps: until then this struct and the exports were
/// two spellings of the same arithmetic, and the comment was an intention.
///
/// What remains here is what the container cannot spell, because a
/// `callconv(.c)` abi already holds the name -- `truthy` returning `bool`
/// rather than `c_int`, `checkType` where the export is `janet_checktype`. A
/// caller that only wants a wrap should reach for the container declaration.
///
/// **Batch 4 shrank the reason and did not spend it.** Since increment 5d(c)
/// the container's own wraps are `pub inline fn` too, so the +89% measurement
/// above is about the *symbol table* and no longer distinguishes
/// `ops.fromNil()` from `fromNil()` -- both inline. Nineteen of the
/// twenty-one members here are now pure aliases. What is left is the type
/// predicates answering `bool` where `kind.zig` answers `c_int`,
/// `fromBoolean` taking a `bool`, and `toCFunction`'s capital F. Retiring the
/// struct means deciding whether those signatures converge, over about three
/// hundred call sites; `port/NAMESPACES.md` open question 2b has it, beside
/// the two facades.
pub const ops = struct {
    pub inline fn checkType(x: types.Janet, t: types.JanetType) bool {
        return repr.checkType(x, t);
    }
    pub inline fn checkTypes(x: types.Janet, typeflags: c_int) bool {
        return ((@as(c_int, 1) << @intCast(repr.typeOf(x))) & typeflags) != 0;
    }
    pub inline fn isNumber(x: types.Janet) bool {
        return repr.checkType(x, constants.JANET_NUMBER);
    }
    pub inline fn truthy(x: types.Janet) bool {
        return repr.truthy(x);
    }
    pub inline fn toNumber(x: types.Janet) f64 {
        return repr.unwrapNumber(x);
    }
    pub inline fn toInteger(x: types.Janet) i32 {
        return outer.toInteger(x);
    }
    pub inline fn fromNumber(d: f64) types.Janet {
        return outer.fromNumber(d);
    }
    pub inline fn fromInteger(n: i32) types.Janet {
        return outer.fromInteger(n);
    }
    pub inline fn fromBoolean(b: bool) types.Janet {
        return outer.fromBoolean(@intFromBool(b));
    }
    pub inline fn fromNil() types.Janet {
        return outer.fromNil();
    }
    pub inline fn fromTrue() types.Janet {
        return outer.fromTrue();
    }
    pub inline fn fromFalse() types.Janet {
        return outer.fromFalse();
    }
    pub inline fn fromFunction(x: *types.JanetFunction) types.Janet {
        return outer.fromFunction(x);
    }
    pub inline fn fromArray(x: *types.JanetArray) types.Janet {
        return outer.fromArray(x);
    }
    pub inline fn fromTable(x: *types.JanetTable) types.Janet {
        return outer.fromTable(x);
    }
    pub inline fn fromBuffer(x: *types.JanetBuffer) types.Janet {
        return outer.fromBuffer(x);
    }
    pub inline fn fromStruct(x: types.JanetStruct) types.Janet {
        return outer.fromStruct(x);
    }
    pub inline fn fromTuple(x: types.JanetTuple) types.Janet {
        return outer.fromTuple(x);
    }
    pub inline fn toFunction(x: types.Janet) *types.JanetFunction {
        return @ptrCast(@alignCast(toPointer(x)));
    }
    pub inline fn toCFunction(x: types.Janet) types.JanetCFunction {
        return @ptrFromInt(@intFromPtr(toPointer(x)));
    }
    pub inline fn toFiber(x: types.Janet) *types.JanetFiber {
        return @ptrCast(@alignCast(toPointer(x)));
    }
};

// -------------------------------------------------- per-layout nanbox helpers

pub fn nanboxToPointer(x: types.Janet) ?*anyopaque {
    return nanbox64.toPointer(x);
}

pub fn nanboxFromPointer(p: ?*anyopaque, tagmask: u64) types.Janet {
    return nanbox64.fromPointer(p, tagmask);
}

pub fn nanboxFromCPointer(p: ?*const anyopaque, tagmask: u64) types.Janet {
    return nanbox64.fromCPointer(p, tagmask);
}

pub fn nanboxFromDouble(d: f64) types.Janet {
    return nanbox64.fromDouble(d);
}

pub fn nanboxFromBits(bits: u64) types.Janet {
    return nanbox64.fromBits(bits);
}

pub fn nanbox32FromTagI(t: u32, integer: i32) types.Janet {
    return nanbox32.fromTagI(t, integer);
}

pub fn nanbox32FromTagP(t: u32, p: ?*anyopaque) types.Janet {
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
        .nanbox64 => {},
        .nanbox32 => {},
        .tagged => {},
    }
}

// -------------------------------------------------------- empty bucket arrays

/// `sizeof(JanetKV) * count` as C computes it: the `int32_t` is converted to
/// `size_t`, which sign-extends a negative count into an enormous size, and the
/// multiply wraps. Both are reproduced -- the enormous size is what turns a
/// negative capacity into an out-of-memory exit.
inline fn kvBytes(count: i32) usize {
    return @as(usize, @bitCast(@as(isize, count))) *% @sizeOf(types.JanetKV);
}

/// `janet_memalloc_empty`. A `janet_malloc` block of `count` key/value pairs,
/// every one of them nil, charged against the collection budget.
///
/// The charge happens before the null check, exactly as in C; nothing observes
/// the difference, because the failure path exits.
pub fn memallocEmpty(count: i32) ?*anyopaque {
    const bytes = kvBytes(count);
    const mem = utils.malloc(bytes);
    vm().next_collection +%= bytes;
    if (mem == null) fatal.outOfMemory();
    const mmem: [*]types.JanetKV = @ptrCast(@alignCast(mem));
    var i: i32 = 0;
    while (i < count) : (i += 1) {
        const kv = &mmem[@intCast(i)];
        kv.key = fromNil();
        kv.value = fromNil();
    }
    return mem;
}

/// `janet_memempty`. The same fill over a block the caller already owns, which
/// is how a table is cleared and how a struct's bucket array is initialised
/// from the scratch allocator.
pub fn memempty(mem: [*]types.JanetKV, count: i32) void {
    var i: i32 = 0;
    while (i < count) : (i += 1) {
        mem[@intCast(i)].key = fromNil();
        mem[@intCast(i)].value = fromNil();
    }
}
