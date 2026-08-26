//! Behavioral contract for the FFI type system's portable kernels: the
//! machine-type and calling-convention name tables, and the struct layout
//! machine that assigns every field its offset.
//!
//! The name tables are pinned name by name, including every alias, because a
//! table is exactly the kind of thing a port drops one entry from. The layout
//! machine is checked two ways: against fixed vectors, and against the offsets
//! a compiler itself assigns to equivalent structures. The second is the
//! stronger check — it says the machine reproduces the platform's ABI rather
//! than merely reproducing whatever the previous implementation did.
//!
//! All four calling-convention names are asserted here even though a build
//! enables at most one of them. Deciding which are enabled stays in
//! `ffi_types.zig`; decoding a name does not depend on the target, and
//! asserting that on every target is the coverage the arch-gated C original
//! could never have.
//!
//! ## What the migration changed
//!
//! **The subject is reached by import, and that is what killed six exported
//! symbols.** `test/ffi_layout.c` hand-declared `janet_ffi_decode_prim` and
//! its five neighbours, because they are in no header — `ffi.c` and this
//! contract were their only callers, and after Phase 10 Part 18 the caller was
//! `ffi_types.zig` reaching a Zig function through the C ABI. Moving this file
//! inside the compilation took the last reason for the symbols to exist, so
//! Phase 11 Part 16 deleted all six along with the second copy of `Layout`
//! that lived at the calling end.
//!
//! **The ordinals are still written out here rather than imported.** That is
//! deliberate and it is the file's only real oracle question. `ffi_layout.zig`
//! spells them as a `PrimType` enumeration; asserting `lookupPrim("void") ==
//! @intFromEnum(PrimType.void)` would be an assertion that cannot fail. The C
//! contract's independent copy of the enumeration *was* the oracle, so the
//! copy survives the migration — the numbers below are the wire between this
//! table and `ffi_types.zig`'s own enumeration, and either end may be wrong.
//!
//! **The host-ABI section keeps both sides.** `test/ffi_layout.c` laid out the
//! equivalent of three C structures and compared every offset with what the
//! host compiler had assigned through `offsetof`. Zig's `extern struct` is the
//! same claim asked of the same C ABI, computed by a different implementation
//! of it — the compiler's, not this hand-written machine's — so `@offsetOf`
//! replaces `offsetof` and the comparison stays a comparison of two
//! descriptions. This is rule 20's question with an answer that happened to be
//! easy; it was worth asking, because a translation that had reached for
//! `Layout` to describe the expectation would have compared the machine with
//! itself.

const std = @import("std");
const subsystems = @import("subsystems");
const config = @import("config");
const ffi_layout = subsystems.ffi_types;
const Layout = ffi_layout.Layout;

const assert = std.debug.assert;

/// `JanetFFIPrimType`, written out rather than imported — see the header.
const prim_void: i32 = 0;
const prim_bool: i32 = 1;
const prim_ptr: i32 = 2;
const prim_string: i32 = 3;
const prim_float: i32 = 4;
const prim_double: i32 = 5;
const prim_int8: i32 = 6;
const prim_uint8: i32 = 7;
const prim_int16: i32 = 8;
const prim_uint16: i32 = 9;
const prim_int32: i32 = 10;
const prim_uint32: i32 = 11;
const prim_int64: i32 = 12;
const prim_uint64: i32 = 13;

/// `JanetFFICallingConvention`, likewise.
const cc_none: i32 = 0;
const cc_sysv64: i32 = 1;
const cc_win64: i32 = 2;
const cc_aapcs64: i32 = 3;

const prim = ffi_layout.lookupPrim;
const cc = ffi_layout.lookupCc;

// ------------------------------------------------------------- name tables

fn primaryMachineTypes() void {
    assert(prim("void") == prim_void);
    assert(prim("bool") == prim_bool);
    assert(prim("ptr") == prim_ptr);
    assert(prim("pointer") == prim_ptr);
    assert(prim("string") == prim_string);
    assert(prim("float") == prim_float);
    assert(prim("double") == prim_double);
    assert(prim("int8") == prim_int8);
    assert(prim("uint8") == prim_uint8);
    assert(prim("int16") == prim_int16);
    assert(prim("uint16") == prim_uint16);
    assert(prim("int32") == prim_int32);
    assert(prim("uint32") == prim_uint32);
    assert(prim("int64") == prim_int64);
    assert(prim("uint64") == prim_uint64);
}

fn machineTypeAliases() void {
    assert(prim("r32") == prim_float);
    assert(prim("r64") == prim_double);
    assert(prim("s8") == prim_int8);
    assert(prim("u8") == prim_uint8);
    assert(prim("s16") == prim_int16);
    assert(prim("u16") == prim_uint16);
    assert(prim("s32") == prim_int32);
    assert(prim("u32") == prim_uint32);
    assert(prim("s64") == prim_int64);
    assert(prim("u64") == prim_uint64);
    assert(prim("char") == prim_int8);
    assert(prim("short") == prim_int16);
    assert(prim("int") == prim_int32);
    assert(prim("long") == prim_int64);
    assert(prim("byte") == prim_uint8);
    assert(prim("uchar") == prim_uint8);
    assert(prim("ushort") == prim_uint16);
    assert(prim("uint") == prim_uint32);
    assert(prim("ulong") == prim_uint64);
}

/// The only two names whose meaning depends on the word size.
///
/// The condition is `config.bits64` — the same input the subject reads, rather
/// than the subject's answer, and rather than `@sizeOf(usize)`, which is a
/// different question that happens to agree here. It was `janet.h`'s
/// `JANET_64` until Phase 12 increment 1 moved the answer to `build.zig`; the
/// property this asserts is unchanged, and so is the reason it is asked this
/// way rather than the obvious way.
fn wordSizedMachineTypes() void {
    if (comptime config.bits64) {
        assert(prim("size") == prim_uint64);
        assert(prim("ssize") == prim_int64);
    } else {
        assert(prim("size") == prim_uint32);
        assert(prim("ssize") == prim_int32);
    }
}

fn unknownMachineTypes() void {
    assert(prim("nonesuch") == -1);
    assert(prim("") == -1);
    assert(prim("struct") == -1); // written as a tuple, never as a name
    assert(prim("VOID") == -1); // the table is case sensitive

    // A prefix of a name and a name with something appended are both unknown:
    // the comparison is on the whole length, not on a leading run.
    assert(prim("void"[0..3]) == -1);
    assert(prim("voidx") == -1);

    // A keyword may contain a zero byte, so the length is what delimits the
    // name rather than a terminator. The C contract had to pass a length
    // beside the pointer to say this; a slice carries it.
    assert(prim("vo\x00d") == -1);
    assert(prim("void\x00x") == -1);
}

fn callingConventions() void {
    // Every convention decodes on every target, including the three that this
    // build cannot call through.
    assert(cc("none") == cc_none);
    assert(cc("sysv64") == cc_sysv64);
    assert(cc("win64") == cc_win64);
    assert(cc("aapcs64") == cc_aapcs64);

    // `default` resolves to whichever convention the build enables, which is a
    // property of the target; `ffi_types.zig` maps it before reaching the
    // table.
    assert(cc("default") == -1);

    assert(cc("nonesuch") == -1);
    assert(cc("") == -1);
    assert(cc("win64"[0..4]) == -1);
}

// ------------------------------------------------------------ type extents

fn typeExtents() void {
    const extent = ffi_layout.typeExtent;

    // A negative count means the type is not an array at all.
    assert(extent(8, -1) == 8);
    assert(extent(0, -1) == 0);
    assert(extent(3, -7) == 3);

    // `@[type]` with no count decodes to a count of zero, which is a real zero
    // rather than a missing one.
    assert(extent(8, 0) == 0);

    assert(extent(1, 17) == 17);
    assert(extent(4, 3) == 12);
    assert(extent(8, 1024) == 8192);
}

// -------------------------------------------------------- layout machinery

fn layoutOfNothing() void {
    var layout = Layout.init();
    assert(layout.size == 0);
    assert(layout.alignment == 1);
    assert(layout.is_aligned == 1);
    layout.finish();
    assert(layout.size == 0);
    assert(layout.alignment == 1);
    assert(layout.is_aligned == 1);
}

fn layoutPadsBetweenFields() void {
    var layout = Layout.init();
    assert(layout.place(1, 1, false) == 0);
    // Seven bytes of padding ahead of the eight-byte field.
    assert(layout.place(8, 8, false) == 8);
    assert(layout.place(2, 2, false) == 16);
    layout.finish();
    // 18 bytes rounded up to the struct's own eight-byte alignment.
    assert(layout.size == 24);
    assert(layout.alignment == 8);
    assert(layout.is_aligned == 1);
}

fn layoutTakesTheStrictestAlignment() void {
    var layout = Layout.init();
    assert(layout.place(2, 2, false) == 0);
    assert(layout.place(4, 4, false) == 4);
    assert(layout.place(1, 1, false) == 8);
    layout.finish();
    assert(layout.size == 12);
    assert(layout.alignment == 4);
}

fn layoutOfASingleField() void {
    var layout = Layout.init();
    assert(layout.place(4, 4, false) == 0);
    layout.finish();
    assert(layout.size == 4);
    assert(layout.alignment == 4);
}

/// An array member contributes its whole extent but only its element's
/// alignment, which is what `typeExtent` and `typeAlign` produce together.
fn layoutOfAnArrayMember() void {
    var layout = Layout.init();
    assert(layout.place(1, 1, false) == 0);
    assert(layout.place(ffi_layout.typeExtent(4, 3), 4, false) == 4);
    layout.finish();
    assert(layout.size == 16);
    assert(layout.alignment == 4);
}

fn packedFieldsLeaveNoPadding() void {
    var layout = Layout.init();
    assert(layout.place(1, 1, true) == 0);
    assert(layout.place(8, 8, true) == 1);
    assert(layout.place(2, 2, true) == 9);
    layout.finish();
    // Nothing was padded and nothing raised the struct's alignment, so the
    // total is the plain sum.
    assert(layout.size == 11);
    assert(layout.alignment == 1);
    // Two of the three landed off their natural boundary.
    assert(layout.is_aligned == 0);
}

fn packedFieldsCanStillBeAligned() void {
    var layout = Layout.init();
    assert(layout.place(4, 4, true) == 0);
    assert(layout.place(4, 4, true) == 4);
    layout.finish();
    assert(layout.size == 8);
    // A packed field contributes nothing to the struct's alignment even when
    // it happens to sit on its own boundary.
    assert(layout.alignment == 1);
    assert(layout.is_aligned == 1);
}

/// `:pack` packs one member and `:pack-all` packs the rest, so a layout can
/// mix the two kinds of placement.
fn layoutMixesPackedAndAlignedFields() void {
    var layout = Layout.init();
    assert(layout.place(1, 1, false) == 0);
    assert(layout.place(4, 4, true) == 1);
    assert(layout.place(8, 8, false) == 8);
    layout.finish();
    assert(layout.size == 16);
    assert(layout.alignment == 8);
    assert(layout.is_aligned == 0);
}

/// The rounding at the end is what makes an array of the struct place every
/// element on the alignment its fields demand.
fn layoutRoundsTheTotalUp() void {
    var layout = Layout.init();
    assert(layout.place(8, 8, false) == 0);
    assert(layout.place(1, 1, false) == 8);
    assert(layout.size == 9);
    layout.finish();
    assert(layout.size == 16);
    assert(layout.size % layout.alignment == 0);
}

// --------------------------------------------- agreement with the host ABI

const HostCharDouble = extern struct {
    a: u8,
    b: f64,
};

const HostMixed = extern struct {
    a: u8,
    b: i32,
    c: u8,
    d: f64,
    e: i16,
};

const HostNested = extern struct {
    a: i16,
    b: HostCharDouble,
    c: u8,
};

/// Lay out the equivalent of a C structure and compare every offset and the
/// total against what the compiler assigned to an `extern struct`.
///
/// `extern struct` is Zig's implementation of the platform C ABI, and this
/// machine is a hand-written one; the two agreeing is what says the machine
/// reproduces the ABI rather than only its own past output. That is the same
/// pairing `test/ffi_layout.c` had with `offsetof`, one compiler over.
fn layoutMatchesTheCompiler() void {
    var layout = Layout.init();
    assert(layout.place(@sizeOf(u8), @alignOf(u8), false) == @offsetOf(HostCharDouble, "a"));
    assert(layout.place(@sizeOf(f64), @alignOf(f64), false) == @offsetOf(HostCharDouble, "b"));
    layout.finish();
    assert(layout.size == @sizeOf(HostCharDouble));
    assert(layout.alignment == @alignOf(f64));

    layout = Layout.init();
    assert(layout.place(@sizeOf(u8), @alignOf(u8), false) == @offsetOf(HostMixed, "a"));
    assert(layout.place(@sizeOf(i32), @alignOf(i32), false) == @offsetOf(HostMixed, "b"));
    assert(layout.place(@sizeOf(u8), @alignOf(u8), false) == @offsetOf(HostMixed, "c"));
    assert(layout.place(@sizeOf(f64), @alignOf(f64), false) == @offsetOf(HostMixed, "d"));
    assert(layout.place(@sizeOf(i16), @alignOf(i16), false) == @offsetOf(HostMixed, "e"));
    layout.finish();
    assert(layout.size == @sizeOf(HostMixed));

    // A nested structure enters as its own size and alignment, which is how
    // `typeSize` and `typeAlign` present one.
    layout = Layout.init();
    assert(layout.place(@sizeOf(i16), @alignOf(i16), false) == @offsetOf(HostNested, "a"));
    assert(layout.place(@sizeOf(HostCharDouble), @alignOf(f64), false) == @offsetOf(HostNested, "b"));
    assert(layout.place(@sizeOf(u8), @alignOf(u8), false) == @offsetOf(HostNested, "c"));
    layout.finish();
    assert(layout.size == @sizeOf(HostNested));
}

// -------------------------------------------------------------- invariants

/// Sweep every combination of a few sizes and alignments and check the rules
/// that must hold whatever the inputs were, rather than a stored expectation
/// for each one.
fn layoutInvariantsOverASweep() void {
    const alignments = [_]usize{ 1, 2, 4, 8, 16 };
    const sizes = [_]usize{ 1, 2, 3, 4, 7, 8, 12, 16, 31 };

    for (alignments) |first_align| {
        for (sizes) |first_size| {
            for (alignments) |second_align| {
                for (sizes) |second_size| {
                    var layout = Layout.init();

                    const first = layout.place(first_size, first_align, false);
                    assert(first == 0);
                    assert(layout.size == first_size);

                    const second = layout.place(second_size, second_align, false);
                    // Each field starts on its own boundary, never before the
                    // end of the field ahead of it, and never further past it
                    // than that boundary requires.
                    assert(second % second_align == 0);
                    assert(second >= first_size);
                    assert(second - first_size < second_align);
                    assert(layout.size == second + second_size);

                    const before_rounding = layout.size;
                    layout.finish();

                    // The struct takes the strictest alignment any field asked
                    // for, its total is a whole number of those, and rounding
                    // never loses a byte or adds a needless one.
                    assert(layout.alignment == @max(first_align, second_align));
                    assert(layout.size % layout.alignment == 0);
                    assert(layout.size >= before_rounding);
                    assert(layout.size - before_rounding < layout.alignment);
                    // Nothing was packed, so the layout is a natural one.
                    assert(layout.is_aligned == 1);
                }
            }
        }
    }
}

/// A packed sweep: no padding anywhere, no contribution to the alignment, and
/// the aligned flag reporting exactly whether every field happened to land on
/// its own boundary.
fn packedLayoutInvariantsOverASweep() void {
    const alignments = [_]usize{ 1, 2, 4, 8, 16 };
    const sizes = [_]usize{ 1, 3, 4, 5, 8, 13 };

    for (alignments) |first_align| {
        for (sizes) |first_size| {
            for (alignments) |second_align| {
                for (sizes) |second_size| {
                    var layout = Layout.init();

                    assert(layout.place(first_size, first_align, true) == 0);
                    assert(layout.place(second_size, second_align, true) == first_size);

                    layout.finish();
                    assert(layout.alignment == 1);
                    assert(layout.size == first_size + second_size);

                    // The first field sits at zero and so is always natural;
                    // the second is natural exactly when the first field's
                    // size is a multiple of its alignment.
                    const both_natural = 0 == first_size % second_align;
                    assert((layout.is_aligned == 1) == both_natural);
                }
            }
        }
    }
}

pub fn run() void {
    primaryMachineTypes();
    machineTypeAliases();
    wordSizedMachineTypes();
    unknownMachineTypes();
    callingConventions();

    typeExtents();

    layoutOfNothing();
    layoutPadsBetweenFields();
    layoutTakesTheStrictestAlignment();
    layoutOfASingleField();
    layoutOfAnArrayMember();
    packedFieldsLeaveNoPadding();
    packedFieldsCanStillBeAligned();
    layoutMixesPackedAndAlignedFields();
    layoutRoundsTheTotalUp();

    layoutMatchesTheCompiler();
    layoutInvariantsOverASweep();
    packedLayoutInvariantsOverASweep();

    std.debug.print("ffi_layout: all tests passed\n", .{});
}
