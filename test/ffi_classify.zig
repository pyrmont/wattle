//! Behavioral contract for the FFI's calling conventions: register
//! classification and argument allocation for SysV AMD64, Windows x64 and
//! AAPCS64.
//!
//! All three are asserted on every target. Nothing about classification or
//! argument placement is architecture-specific except the rules being
//! encoded, so a build that cannot make a Windows call can still be asked
//! whether it describes a Windows signature correctly. `ffi_call.zig` keeps
//! the conditions that decide which convention a build may actually call
//! through.
//!
//! The AAPCS64 rules differ on Apple platforms, where stack arguments are
//! packed at their natural alignment rather than rounded up to a word. That
//! difference arrives as a parameter rather than a conditional, so both
//! variants are checked whichever one the host would use.
//!
//! Types reach the conventions as a flat pre-order array of nodes rather than
//! as a `Type`, so the cases build them directly and need no Janet heap.
//! Every case is a literal description of a type, which also means a case can
//! describe something `ffi_types.zig` would never build.
//!
//! ## Where the oracles come from
//!
//! The three flat structures are the subject's own. `TypeNode`, `ArgSlot` and
//! `AllocResult` are imported rather than redeclared, so a field added on one
//! side cannot be missed on the other. Redeclaring them would put a layout
//! mirror here that nothing compares.
//!
//! The ordinals are written out, for `test/ffi_layout.zig`'s reason: the
//! numbers are the wire between the classifier and `ffi/call.zig`'s `Spec`
//! enumeration, and reading them out of the subject would be an assertion
//! that cannot fail.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const expect = @import("expect.zig").expect;
const ffi_classify = subsystems.ffi_classify;
const subsystems = @import("subsystems");

// ==========================================================================
// Constants
// ==========================================================================

/// The width of the AAPCS64 trampoline's return buffer, which `ffi_call.zig`
/// passes as the size of a real structure.
const aapcs64_max_ret: u64 = 128;

/// `AllocResult`'s status codes, written out on the same footing as the
/// ordinals below.
const alloc_ok: u32 = 0;
const alloc_unsupported_spec: u32 = 1;
const alloc_return_too_big: u32 = 2;

/// The two classifiers, under the names the cases below use. There is no
/// third: Windows x64 decides a class and allocates a register in one pass,
/// so its cases go straight to the allocator.
const classifyAapcs64 = ffi_classify.classifyAapcs64;

const classifySysv64 = ffi_classify.classifySysv64;

/// `types.PrimType`'s ordinals, copied out rather than imported, so that the
/// assertions have an oracle independent of the enumeration they check.
const prim_void: u32 = 0;
const prim_bool: u32 = 1;
const prim_ptr: u32 = 2;
const prim_string: u32 = 3;
const prim_float: u32 = 4;
const prim_double: u32 = 5;
const prim_int8: u32 = 6;
const prim_uint8: u32 = 7;
const prim_int16: u32 = 8;
const prim_uint16: u32 = 9;
const prim_int32: u32 = 10;
const prim_uint32: u32 = 11;
const prim_int64: u32 = 12;
const prim_uint64: u32 = 13;
const prim_struct: u32 = 14;

/// `types.Spec`'s ordinals, copied out on the same footing. Two of the
/// enumeration's nineteen are missing here, 2 and 12, because no case below
/// reaches `sysv64_sseup` or `win64_stack_ref`.
const sysv64_integer: u32 = 0;
const sysv64_sse: u32 = 1;
const sysv64_pair_intint: u32 = 3;
const sysv64_pair_intsse: u32 = 4;
const sysv64_pair_sseint: u32 = 5;
const sysv64_pair_ssesse: u32 = 6;
const sysv64_no_class: u32 = 7;
const sysv64_memory: u32 = 8;
const win64_register: u32 = 9;
const win64_stack: u32 = 10;
const win64_register_ref: u32 = 11;
const aapcs64_general: u32 = 13;
const aapcs64_sse: u32 = 14;
const aapcs64_general_ref: u32 = 15;
const aapcs64_stack: u32 = 16;
const aapcs64_stack_ref: u32 = 17;
const aapcs64_none: u32 = 18;

// ==========================================================================
// Aliased types
// ==========================================================================

const AllocResult = ffi_classify.AllocResult;
const ArgSlot = ffi_classify.ArgSlot;
const TypeNode = ffi_classify.TypeNode;

// ==========================================================================
// Cases
// ==========================================================================

/// One node of a scalar type, at `offset` within whatever encloses it.
fn leaf(prim: u32, size: u64, offset: u32) TypeNode {
    return .{
        .size = size,
        .struct_size = 0,
        .prim = prim,
        .field_count = 0,
        .is_aligned = 1,
        .offset = offset,
        .array_count = -1,
    };
}

/// The header node of a struct, whose `field_count` fields follow it in the
/// array.
fn structNode(size: u32, field_count: u32, offset: u32) TypeNode {
    return .{
        .size = size,
        .struct_size = size,
        .prim = prim_struct,
        .field_count = field_count,
        .is_aligned = 1,
        .offset = offset,
        .array_count = -1,
    };
}

/// One allocated argument, as a convention reports it.
fn slot(prim: u32, size: u64, alignment: u32, spec: u32) ArgSlot {
    return .{
        .size = size,
        .prim = prim,
        .spec = spec,
        .alignment = alignment,
        .offset = 0,
        .offset2 = 0,
        .hfa_members = 0,
    };
}

/// A homogeneous floating-point aggregate, which `ffi_call.zig` describes by
/// its member count rather than by its width. Zero means the caller could not
/// say, and the allocator falls back to the byte arithmetic there.
fn hfaSlot(size: u64, members: u32) ArgSlot {
    var s = slot(prim_struct, size, 8, aapcs64_sse);
    s.hfa_members = members;
    return s;
}

fn sysv64ClassifiesScalars() void {
    const cases = [_]struct { prim: u32, size: u64, expected: u32 }{
        .{ .prim = prim_bool, .size = 1, .expected = sysv64_integer },
        .{ .prim = prim_ptr, .size = 8, .expected = sysv64_integer },
        .{ .prim = prim_string, .size = 8, .expected = sysv64_integer },
        .{ .prim = prim_int8, .size = 1, .expected = sysv64_integer },
        .{ .prim = prim_uint8, .size = 1, .expected = sysv64_integer },
        .{ .prim = prim_int16, .size = 2, .expected = sysv64_integer },
        .{ .prim = prim_uint16, .size = 2, .expected = sysv64_integer },
        .{ .prim = prim_int32, .size = 4, .expected = sysv64_integer },
        .{ .prim = prim_uint32, .size = 4, .expected = sysv64_integer },
        .{ .prim = prim_int64, .size = 8, .expected = sysv64_integer },
        .{ .prim = prim_uint64, .size = 8, .expected = sysv64_integer },
        .{ .prim = prim_float, .size = 4, .expected = sysv64_sse },
        .{ .prim = prim_double, .size = 8, .expected = sysv64_sse },
        .{ .prim = prim_void, .size = 0, .expected = sysv64_no_class },
    };
    for (cases) |case| {
        const node = [_]TypeNode{leaf(case.prim, case.size, 0)};
        expect(classifySysv64(&node) == case.expected);
    }
}

fn sysv64SendsWideStructsToMemory() void {
    const nodes = [_]TypeNode{
        structNode(24, 3, 0),
        leaf(prim_int64, 8, 0),
        leaf(prim_int64, 8, 8),
        leaf(prim_int64, 8, 16),
    };
    expect(classifySysv64(&nodes) == sysv64_memory);

    // Exactly sixteen bytes still fits in the register pair.
    const fits = [_]TypeNode{
        structNode(16, 2, 0),
        leaf(prim_int64, 8, 0),
        leaf(prim_int64, 8, 8),
    };
    expect(classifySysv64(&fits) == sysv64_pair_intint);
}

fn sysv64SendsMisalignedStructsToMemory() void {
    var nodes = [_]TypeNode{
        structNode(9, 2, 0),
        leaf(prim_uint8, 1, 0),
        leaf(prim_uint64, 8, 1),
    };
    nodes[0].is_aligned = 0;
    expect(classifySysv64(&nodes) == sysv64_memory);
}

fn sysv64NamesThePairOfAWideStruct() void {
    const cases = [_]struct { first: u32, second: u32, expected: u32 }{
        .{ .first = prim_int64, .second = prim_int64, .expected = sysv64_pair_intint },
        .{ .first = prim_int64, .second = prim_double, .expected = sysv64_pair_intsse },
        .{ .first = prim_double, .second = prim_int64, .expected = sysv64_pair_sseint },
        .{ .first = prim_double, .second = prim_double, .expected = sysv64_pair_ssesse },
    };
    for (cases) |case| {
        const nodes = [_]TypeNode{
            structNode(16, 2, 0),
            leaf(case.first, 8, 0),
            leaf(case.second, 8, 8),
        };
        expect(classifySysv64(&nodes) == case.expected);
    }
}

fn sysv64MergesANarrowStruct() void {
    // Two floats share one eightbyte and stay in the vector registers.
    const floats = [_]TypeNode{
        structNode(8, 2, 0),
        leaf(prim_float, 4, 0),
        leaf(prim_float, 4, 4),
    };
    expect(classifySysv64(&floats) == sysv64_sse);

    // An integer anywhere in the eightbyte makes the whole of it integer.
    const mixed = [_]TypeNode{
        structNode(8, 2, 0),
        leaf(prim_int32, 4, 0),
        leaf(prim_float, 4, 4),
    };
    expect(classifySysv64(&mixed) == sysv64_integer);

    // An empty struct reaches no class at all.
    const empty = [_]TypeNode{structNode(0, 0, 0)};
    expect(classifySysv64(&empty) == sysv64_no_class);
}

fn sysv64UsesTheOffsetToPickTheEightbyte() void {
    // { float; float; int32; int32 }: the integers sit entirely in the second
    // eightbyte, so the low half is SSE and the high half integer.
    const nodes = [_]TypeNode{
        structNode(16, 4, 0),
        leaf(prim_float, 4, 0),
        leaf(prim_float, 4, 4),
        leaf(prim_int32, 4, 8),
        leaf(prim_int32, 4, 12),
    };
    expect(classifySysv64(&nodes) == sysv64_pair_sseint);

    // Moving one integer down into the first eightbyte moves the class with it.
    const swapped = [_]TypeNode{
        structNode(16, 4, 0),
        leaf(prim_int32, 4, 0),
        leaf(prim_float, 4, 4),
        leaf(prim_float, 4, 8),
        leaf(prim_float, 4, 12),
    };
    expect(classifySysv64(&swapped) == sysv64_pair_intsse);
}

fn sysv64DescendsIntoNestedStructs() void {
    // { { double } ; int64 }: the nested struct classifies SSE on its own
    // and the outer pair is named from the two halves.
    const nodes = [_]TypeNode{
        structNode(16, 2, 0),
        structNode(8, 1, 0),
        leaf(prim_double, 8, 0),
        leaf(prim_int64, 8, 8),
    };
    expect(classifySysv64(&nodes) == sysv64_pair_sseint);

    // A nested struct that reached memory sends the whole enclosing type
    // there too, when that type fits in a single eightbyte and so goes
    // through the merge rule.
    var packed_nodes = [_]TypeNode{
        structNode(8, 1, 0),
        structNode(8, 1, 0),
        leaf(prim_uint64, 8, 0),
    };
    packed_nodes[1].is_aligned = 0;
    expect(classifySysv64(&packed_nodes) == sysv64_memory);
}

/// A field that reaches memory sends the whole aggregate to memory at both
/// sizes. The merge rule does it for a struct of eight bytes or fewer, and
/// the two-eightbyte rules do it here.
///
/// Looking only for integer classes across the two halves drops the memory
/// field instead, so the same field decides the argument at one size and
/// counts for nothing at another. A packed nested aggregate then goes in a
/// register pair while the callee's compiler reads it from the stack, which
/// misplaces it and every argument after it.
fn sysv64CarriesAMemoryFieldOutOfAPair() void {
    var nodes = [_]TypeNode{
        structNode(16, 2, 0),
        structNode(8, 1, 0),
        leaf(prim_uint64, 8, 0),
        leaf(prim_double, 8, 8),
    };
    nodes[1].is_aligned = 0;
    expect(classifySysv64(&nodes) == sysv64_memory);

    // The same shape with the nested struct aligned is the pair it was always
    // meant to be, which is what says the forcing is the memory class's doing
    // rather than the nesting's.
    nodes[1].is_aligned = 1;
    expect(classifySysv64(&nodes) == sysv64_pair_intsse);
}

/// A struct's fields must be walked in full even when a class is decided
/// before reaching them, or the node cursor lands on the wrong field.
fn sysv64SkipsADecidedSubtreeCorrectly() void {
    // An outer struct wider than sixteen bytes is memory outright, and the walk
    // must still consume every node beneath it.
    const nodes = [_]TypeNode{
        structNode(32, 2, 0),
        structNode(24, 3, 0),
        leaf(prim_int64, 8, 0),
        leaf(prim_int64, 8, 8),
        leaf(prim_int64, 8, 16),
        leaf(prim_double, 8, 24),
    };
    expect(classifySysv64(&nodes) == sysv64_memory);

    // { {float; float} ; int64 }: the second field of the outer struct is the
    // trailing integer, and reading one of the nested floats instead would name
    // the pair SSESSE rather than SSEINT.
    const nested = [_]TypeNode{
        structNode(16, 2, 0),
        structNode(8, 2, 0),
        leaf(prim_float, 4, 0),
        leaf(prim_float, 4, 4),
        leaf(prim_int64, 8, 8),
    };
    expect(classifySysv64(&nested) == sysv64_pair_sseint);
}

fn aapcs64ClassifiesScalars() void {
    const cases = [_]struct { prim: u32, size: u64, expected: u32 }{
        .{ .prim = prim_bool, .size = 1, .expected = aapcs64_general },
        .{ .prim = prim_ptr, .size = 8, .expected = aapcs64_general },
        .{ .prim = prim_string, .size = 8, .expected = aapcs64_general },
        .{ .prim = prim_int8, .size = 1, .expected = aapcs64_general },
        .{ .prim = prim_uint64, .size = 8, .expected = aapcs64_general },
        .{ .prim = prim_float, .size = 4, .expected = aapcs64_sse },
        .{ .prim = prim_double, .size = 8, .expected = aapcs64_sse },
        .{ .prim = prim_void, .size = 0, .expected = aapcs64_none },
    };
    for (cases) |case| {
        const node = [_]TypeNode{leaf(case.prim, case.size, 0)};
        expect(classifyAapcs64(&node) == case.expected);
    }
}

fn aapcs64RecognisesHomogeneousFloatAggregates() void {
    // Up to four members of one floating-point type travel in the vector
    // registers, however wide that makes the aggregate.
    var count: u32 = 1;
    while (count <= 4) : (count += 1) {
        var nodes: [5]TypeNode = undefined;
        nodes[0] = structNode(count * 8, count, 0);
        var i: u32 = 0;
        while (i < count) : (i += 1) nodes[1 + i] = leaf(prim_double, 8, i * 8);
        expect(classifyAapcs64(nodes[0 .. 1 + count]) == aapcs64_sse);
    }

    // A fifth member is one too many, and forty bytes then goes by reference.
    var five: [6]TypeNode = undefined;
    five[0] = structNode(40, 5, 0);
    var i: u32 = 0;
    while (i < 5) : (i += 1) five[1 + i] = leaf(prim_double, 8, i * 8);
    expect(classifyAapcs64(&five) == aapcs64_general_ref);
}

fn aapcs64RejectsInhomogeneousAggregates() void {
    // Float and double are both floating point but not the same type.
    const mixed = [_]TypeNode{
        structNode(16, 2, 0),
        leaf(prim_float, 4, 0),
        leaf(prim_double, 8, 8),
    };
    expect(classifyAapcs64(&mixed) == aapcs64_general);

    // A leading integer takes it out of the floating-point case at the first
    // test.
    const leading = [_]TypeNode{
        structNode(16, 2, 0),
        leaf(prim_int64, 8, 0),
        leaf(prim_double, 8, 8),
    };
    expect(classifyAapcs64(&leading) == aapcs64_general);
}

fn aapcs64PassesWideAggregatesByReference() void {
    const narrow = [_]TypeNode{
        structNode(16, 2, 0),
        leaf(prim_int64, 8, 0),
        leaf(prim_int64, 8, 8),
    };
    expect(classifyAapcs64(&narrow) == aapcs64_general);

    const wide = [_]TypeNode{
        structNode(24, 3, 0),
        leaf(prim_int64, 8, 0),
        leaf(prim_int64, 8, 8),
        leaf(prim_int64, 8, 16),
    };
    expect(classifyAapcs64(&wide) == aapcs64_general_ref);
}

/// An array of a struct measures wider than the struct itself, and it is the
/// array's width that decides whether it goes by reference.
fn aapcs64UsesTheWholeExtentOfAnArray() void {
    var nodes = [_]TypeNode{
        structNode(16, 2, 0),
        leaf(prim_int64, 8, 0),
        leaf(prim_int64, 8, 8),
    };
    nodes[0].size = 48; // three copies of a sixteen-byte struct
    nodes[0].array_count = 3;
    expect(classifyAapcs64(&nodes) == aapcs64_general_ref);
}

/// A zero-field struct is reachable, since a type of `[:pack]` names a member
/// that is not there, so the classifier tests the field count before it reads
/// a first field.
fn aapcs64HandlesAnEmptyStruct() void {
    const empty = [_]TypeNode{structNode(0, 0, 0)};
    expect(classifyAapcs64(&empty) == aapcs64_general);
}

/// Neither classifier is given a node to look at. Both open with a guard for
/// the zero-length walk, and `ffi_call.zig` always serializes at least the
/// root of a type, so this is the only caller either guard has.
fn bothClassifiersAcceptNoNodes() void {
    const none: []const TypeNode = &.{};
    expect(classifySysv64(none) == sysv64_no_class);
    expect(classifyAapcs64(none) == aapcs64_none);
}

fn win64FillsFourRegistersThenTheStack() void {
    var ret = slot(prim_int64, 8, 8, 0);
    var args: [6]ArgSlot = undefined;
    for (&args) |*a| a.* = slot(prim_int64, 8, 8, 0);
    var result: AllocResult = undefined;
    ffi_classify.allocWin64(&result, &ret, &args);

    expect(result.error_kind == alloc_ok);
    for (0..4) |i| {
        expect(args[i].spec == win64_register);
        expect(args[i].offset == i);
    }
    expect(args[4].spec == win64_stack);
    expect(args[4].offset == 0);
    expect(args[5].spec == win64_stack);
    expect(args[5].offset == 1);
    expect(result.stack_count == 2);
}

fn win64MarksFloatingRegistersInTheVariant() void {
    // Each of the first four arguments owns one bit, counted from the top.
    for (0..4) |position| {
        var ret = slot(prim_void, 0, 1, 0);
        var args: [4]ArgSlot = undefined;
        for (&args) |*a| a.* = slot(prim_int64, 8, 8, 0);
        args[position] = slot(prim_double, 8, 8, 0);
        var result: AllocResult = undefined;
        ffi_classify.allocWin64(&result, &ret, &args);
        expect(result.variant == (@as(u32, 1) << @intCast(3 - position)));
    }

    // A floating-point return adds its own bit above those four.
    var ret = slot(prim_double, 8, 8, 0);
    var args = [_]ArgSlot{slot(prim_float, 4, 4, 0)};
    var result: AllocResult = undefined;
    ffi_classify.allocWin64(&result, &ret, &args);
    expect(result.variant == 16 + 8);
}

fn win64PassesOddSizesByReference() void {
    // Anything that is not one, two, four, or eight bytes wide goes through the
    // reference area rather than a register.
    var ret = slot(prim_void, 0, 1, 0);
    var args = [_]ArgSlot{
        slot(prim_struct, 12, 4, 0),
        slot(prim_int64, 8, 8, 0),
    };
    var result: AllocResult = undefined;
    ffi_classify.allocWin64(&result, &ret, &args);

    expect(args[0].spec == win64_register_ref);
    expect(args[0].offset == 0);
    expect(args[1].spec == win64_register);
    expect(args[1].offset == 1);
    // One sixteen-byte reference slot, so two eight-byte stack words.
    expect(result.stack_count == 2);
    // The reference offset is measured down from the top of the stack area.
    expect(args[0].offset2 == 0);
}

fn win64ReservesARegisterForAWideReturn() void {
    var ret = slot(prim_struct, 24, 8, 0);
    var args: [4]ArgSlot = undefined;
    for (&args) |*a| a.* = slot(prim_int64, 8, 8, 0);
    var result: AllocResult = undefined;
    ffi_classify.allocWin64(&result, &ret, &args);

    expect(ret.spec == win64_register_ref);
    // The return pointer takes the first register, so only three arguments
    // fit and the fourth spills.
    expect(args[0].offset == 1);
    expect(args[2].spec == win64_register);
    expect(args[3].spec == win64_stack);
}

fn win64RoundsTheStackToAnEvenNumberOfWords() void {
    var ret = slot(prim_void, 0, 1, 0);
    var args: [5]ArgSlot = undefined;
    for (&args) |*a| a.* = slot(prim_int64, 8, 8, 0);
    var result: AllocResult = undefined;
    ffi_classify.allocWin64(&result, &ret, &args);
    // One argument on the stack, rounded up to a pair.
    expect(result.stack_count == 2);
}

fn sysv64FillsTheIntegerRegisters() void {
    var ret = slot(prim_void, 0, 1, sysv64_no_class);
    var args: [8]ArgSlot = undefined;
    for (&args) |*a| a.* = slot(prim_int64, 8, 8, sysv64_integer);
    var result: AllocResult = undefined;
    ffi_classify.allocSysv64(&result, &ret, &args);

    expect(result.error_kind == alloc_ok);
    for (0..6) |i| {
        expect(args[i].spec == sysv64_integer);
        expect(args[i].offset == i);
    }
    expect(args[6].spec == sysv64_memory);
    expect(args[6].offset == 0);
    expect(args[7].spec == sysv64_memory);
    expect(args[7].offset == 1);
    expect(result.stack_count == 2);
}

fn sysv64CountsTheVectorRegistersSeparately() void {
    var ret = slot(prim_void, 0, 1, sysv64_no_class);
    var args: [10]ArgSlot = undefined;
    for (&args) |*a| a.* = slot(prim_double, 8, 8, sysv64_sse);
    var result: AllocResult = undefined;
    ffi_classify.allocSysv64(&result, &ret, &args);

    for (0..8) |i| {
        expect(args[i].spec == sysv64_sse);
        expect(args[i].offset == i);
    }
    expect(args[8].spec == sysv64_memory);
    expect(args[9].spec == sysv64_memory);
}

fn sysv64ReservesARegisterForAMemoryReturn() void {
    var ret = slot(prim_struct, 32, 8, sysv64_memory);
    var args: [6]ArgSlot = undefined;
    for (&args) |*a| a.* = slot(prim_int64, 8, 8, sysv64_integer);
    var result: AllocResult = undefined;
    ffi_classify.allocSysv64(&result, &ret, &args);

    // The hidden return pointer takes the first register.
    expect(args[0].offset == 1);
    expect(args[4].offset == 5);
    expect(args[5].spec == sysv64_memory);
    expect(result.stack_count == 1);
}

fn sysv64PlacesRegisterPairs() void {
    var ret = slot(prim_void, 0, 1, sysv64_no_class);
    var args = [_]ArgSlot{
        slot(prim_struct, 16, 8, sysv64_pair_intint),
        slot(prim_struct, 16, 8, sysv64_pair_intsse),
        slot(prim_struct, 16, 8, sysv64_pair_sseint),
        slot(prim_struct, 16, 8, sysv64_pair_ssesse),
    };
    var result: AllocResult = undefined;
    ffi_classify.allocSysv64(&result, &ret, &args);

    // Two integer registers.
    expect(args[0].offset == 0 and args[0].offset2 == 1);
    // One integer then one vector.
    expect(args[1].offset == 2 and args[1].offset2 == 0);
    // A vector first, then an integer, so the offsets swap roles.
    expect(args[2].offset == 1 and args[2].offset2 == 3);
    // Two vector registers.
    expect(args[3].offset == 2 and args[3].offset2 == 3);
    expect(result.stack_count == 0);
}

/// An integer pair needs two free registers, and the check is strict: five
/// used of six is not enough.
fn sysv64SpillsAPairThatCannotFit() void {
    var ret = slot(prim_void, 0, 1, sysv64_no_class);
    var args: [6]ArgSlot = undefined;
    for (args[0..5]) |*a| a.* = slot(prim_int64, 8, 8, sysv64_integer);
    args[5] = slot(prim_struct, 16, 8, sysv64_pair_intint);
    var result: AllocResult = undefined;
    ffi_classify.allocSysv64(&result, &ret, &args);

    expect(args[5].spec == sysv64_memory);
    expect(args[5].offset == 0);
    expect(result.stack_count == 2);
}

fn sysv64NamesTheReturnVariant() void {
    const cases = [_]struct { ret_spec: u32, expected: u32 }{
        .{ .ret_spec = sysv64_integer, .expected = 0 },
        .{ .ret_spec = sysv64_sse, .expected = 1 },
        .{ .ret_spec = sysv64_pair_intsse, .expected = 2 },
        .{ .ret_spec = sysv64_pair_sseint, .expected = 3 },
        .{ .ret_spec = sysv64_pair_intint, .expected = 0 },
        .{ .ret_spec = sysv64_memory, .expected = 0 },
    };
    for (cases) |case| {
        var ret = slot(prim_struct, 16, 8, case.ret_spec);
        var args = [_]ArgSlot{slot(prim_int64, 8, 8, sysv64_integer)};
        var result: AllocResult = undefined;
        ffi_classify.allocSysv64(&result, &ret, &args);
        expect(result.variant == case.expected);
    }
}

fn sysv64ReportsASpecItCannotPlace() void {
    var ret = slot(prim_void, 0, 1, sysv64_no_class);
    var args = [_]ArgSlot{
        slot(prim_int64, 8, 8, sysv64_integer),
        slot(prim_void, 0, 1, sysv64_no_class),
    };
    var result: AllocResult = undefined;
    ffi_classify.allocSysv64(&result, &ret, &args);

    expect(result.error_kind == alloc_unsupported_spec);
    expect(result.error_arg == 1);
}

fn aapcs64FillsBothRegisterBanks() void {
    var ret = slot(prim_void, 0, 1, aapcs64_none);
    var args = [_]ArgSlot{
        slot(prim_int64, 8, 8, aapcs64_general),
        slot(prim_double, 8, 8, aapcs64_sse),
        slot(prim_int64, 8, 8, aapcs64_general),
        slot(prim_double, 8, 8, aapcs64_sse),
    };
    var result: AllocResult = undefined;
    ffi_classify.allocAapcs64(&result, &ret, &args, false, aapcs64_max_ret);

    expect(result.error_kind == alloc_ok);
    expect(args[0].offset == 0);
    expect(args[1].offset == 0);
    expect(args[2].offset == 1);
    expect(args[3].offset == 1);
    expect(result.stack_count == 0);
}

/// A general aggregate occupies as many registers as it is words wide, and it
/// must fit entirely or go to the stack.
fn aapcs64TakesSeveralRegistersForAnAggregate() void {
    var ret = slot(prim_void, 0, 1, aapcs64_none);
    var args: [3]ArgSlot = undefined;
    for (&args) |*a| a.* = slot(prim_struct, 16, 8, aapcs64_general);
    var result: AllocResult = undefined;
    ffi_classify.allocAapcs64(&result, &ret, &args, false, aapcs64_max_ret);

    expect(args[0].offset == 0);
    expect(args[1].offset == 2);
    expect(args[2].offset == 4);
    expect(result.stack_count == 0);
}

fn aapcs64PacksTheStackByPlatform() void {
    // Ten one-byte arguments: eight take the general registers and the rest go
    // to the stack. Both variants round the total to sixteen, so the difference
    // shows in where the second stack argument lands.
    for ([_]bool{ false, true }) |apple| {
        var ret = slot(prim_void, 0, 1, aapcs64_none);
        var args: [10]ArgSlot = undefined;
        for (&args) |*a| a.* = slot(prim_uint8, 1, 1, aapcs64_general);
        var result: AllocResult = undefined;
        ffi_classify.allocAapcs64(&result, &ret, &args, apple, aapcs64_max_ret);

        expect(args[8].spec == aapcs64_stack);
        expect(args[8].offset == 0);
        expect(args[9].spec == aapcs64_stack);
        // Apple packs the second byte next to the first; the generic standard
        // gives each a whole word.
        expect(args[9].offset == @as(u32, if (apple) 1 else 8));
        expect(result.stack_count == 16);
    }
}

fn aapcs64AlignsStackAggregatesToAWord() void {
    // A struct on the stack is aligned as a word under both variants, even when
    // its own alignment is finer.
    for ([_]bool{ false, true }) |apple| {
        var ret = slot(prim_void, 0, 1, aapcs64_none);
        var args: [10]ArgSlot = undefined;
        for (args[0..9]) |*a| a.* = slot(prim_uint8, 1, 1, aapcs64_general);
        args[9] = slot(prim_struct, 3, 1, aapcs64_general);
        var result: AllocResult = undefined;
        ffi_classify.allocAapcs64(&result, &ret, &args, apple, aapcs64_max_ret);

        expect(args[9].spec == aapcs64_stack);
        expect(args[9].offset == 8);
    }
}

/// One vector register per member.
///
/// Sizing an HFA by bytes agrees with the ABI exactly when a member is eight
/// bytes wide, so an aggregate of `double` comes out right by coincidence and
/// one of `float` is given half the registers the callee reads. Both are
/// here, and the `double` case is the one that passes either way.
fn aapcs64GivesAnHfaOneRegisterPerMember() void {
    // Two floats: eight bytes, two members, two registers. The byte
    // arithmetic gave this one.
    {
        var ret = slot(prim_void, 0, 1, aapcs64_none);
        var args = [_]ArgSlot{ hfaSlot(8, 2), slot(prim_double, 8, 8, aapcs64_sse) };
        var result: AllocResult = undefined;
        ffi_classify.allocAapcs64(&result, &ret, &args, false, aapcs64_max_ret);
        expect(args[0].spec == aapcs64_sse);
        expect(args[0].offset == 0);
        // The scalar behind it starts at the third register, not the second.
        expect(args[1].offset == 2);
    }

    // Four floats: sixteen bytes, four members, four registers.
    {
        var ret = slot(prim_void, 0, 1, aapcs64_none);
        var args = [_]ArgSlot{ hfaSlot(16, 4), slot(prim_double, 8, 8, aapcs64_sse) };
        var result: AllocResult = undefined;
        ffi_classify.allocAapcs64(&result, &ret, &args, false, aapcs64_max_ret);
        expect(args[0].offset == 0);
        expect(args[1].offset == 4);
    }

    // Four doubles: thirty-two bytes, four members, four registers either way.
    {
        var ret = slot(prim_void, 0, 1, aapcs64_none);
        var args = [_]ArgSlot{ hfaSlot(32, 4), slot(prim_double, 8, 8, aapcs64_sse) };
        var result: AllocResult = undefined;
        ffi_classify.allocAapcs64(&result, &ret, &args, false, aapcs64_max_ret);
        expect(args[0].offset == 0);
        expect(args[1].offset == 4);
    }

    // A member count of zero means the caller could not say, either a scalar
    // or an array whose extent the conventions ignore, and the byte
    // arithmetic stands there.
    {
        var ret = slot(prim_void, 0, 1, aapcs64_none);
        var args = [_]ArgSlot{ slot(prim_float, 4, 4, aapcs64_sse), slot(prim_double, 8, 8, aapcs64_sse) };
        var result: AllocResult = undefined;
        ffi_classify.allocAapcs64(&result, &ret, &args, false, aapcs64_max_ret);
        expect(args[0].offset == 0);
        expect(args[1].offset == 1);
    }
}

/// The register count decides where an aggregate lands, so an HFA that no
/// longer fits goes to the stack whole. Seven of the eight vector registers
/// are spent, and a two-member aggregate needs two.
fn aapcs64SpillsAnHfaThatNoLongerFits() void {
    var ret = slot(prim_void, 0, 1, aapcs64_none);
    var args: [8]ArgSlot = undefined;
    for (args[0..7]) |*a| a.* = slot(prim_double, 8, 8, aapcs64_sse);
    args[7] = hfaSlot(8, 2);
    var result: AllocResult = undefined;
    ffi_classify.allocAapcs64(&result, &ret, &args, false, aapcs64_max_ret);

    expect(args[6].spec == aapcs64_sse);
    expect(args[6].offset == 6);
    expect(args[7].spec == aapcs64_stack);
    expect(args[7].offset == 0);
}

fn aapcs64PlacesTheReferenceAreaAfterTheStack() void {
    var ret = slot(prim_void, 0, 1, aapcs64_none);
    var args = [_]ArgSlot{
        slot(prim_struct, 24, 8, aapcs64_general_ref),
        slot(prim_struct, 32, 8, aapcs64_general_ref),
    };
    var result: AllocResult = undefined;
    ffi_classify.allocAapcs64(&result, &ret, &args, false, aapcs64_max_ret);

    // Both pointers fit in registers, so nothing sits in the stack area and the
    // reference area starts at zero.
    expect(args[0].spec == aapcs64_general_ref);
    expect(args[0].offset == 0);
    expect(args[0].offset2 == 0);
    expect(args[1].offset == 1);
    // The first copy is twenty-four bytes, rounded up to the next word.
    expect(args[1].offset2 == 24);
    // Twenty-four plus thirty-two, rounded up to sixteen.
    expect(result.stack_count == 64);
}

fn aapcs64SpillsAReferencePointer() void {
    var ret = slot(prim_void, 0, 1, aapcs64_none);
    var args: [9]ArgSlot = undefined;
    for (args[0..8]) |*a| a.* = slot(prim_int64, 8, 8, aapcs64_general);
    args[8] = slot(prim_struct, 24, 8, aapcs64_general_ref);
    var result: AllocResult = undefined;
    ffi_classify.allocAapcs64(&result, &ret, &args, false, aapcs64_max_ret);

    expect(args[8].spec == aapcs64_stack_ref);
    expect(args[8].offset == 0);
    // The pointer occupies one stack word, rounded to sixteen, and the copy
    // follows it.
    expect(args[8].offset2 == 16);
    expect(result.stack_count == 16 + 32);
}

fn aapcs64NamesTheReturnVariant() void {
    const cases = [_]struct { ret_spec: u32, ret_size: u64, expected: u32 }{
        .{ .ret_spec = aapcs64_general, .ret_size = 8, .expected = 0 },
        .{ .ret_spec = aapcs64_sse, .ret_size = 8, .expected = 1 },
        .{ .ret_spec = aapcs64_general_ref, .ret_size = 24, .expected = 2 },
        .{ .ret_spec = aapcs64_none, .ret_size = 0, .expected = 0 },
    };
    for (cases) |case| {
        var ret = slot(prim_struct, case.ret_size, 8, case.ret_spec);
        var args = [_]ArgSlot{slot(prim_int64, 8, 8, aapcs64_general)};
        var result: AllocResult = undefined;
        ffi_classify.allocAapcs64(&result, &ret, &args, false, aapcs64_max_ret);
        expect(result.error_kind == alloc_ok);
        expect(result.variant == case.expected);
    }
}

fn aapcs64ReportsAnOversizedReturn() void {
    var ret = slot(prim_struct, aapcs64_max_ret + 1, 8, aapcs64_general_ref);
    var args = [_]ArgSlot{slot(prim_int64, 8, 8, aapcs64_general)};
    var result: AllocResult = undefined;
    ffi_classify.allocAapcs64(&result, &ret, &args, false, aapcs64_max_ret);

    expect(result.error_kind == alloc_return_too_big);
    expect(result.error_arg == -1);

    // Exactly the buffer's width is still allowed.
    var exact = slot(prim_struct, aapcs64_max_ret, 8, aapcs64_general_ref);
    ffi_classify.allocAapcs64(&result, &exact, &args, false, aapcs64_max_ret);
    expect(result.error_kind == alloc_ok);
}

fn aapcs64ReportsASpecItCannotPlace() void {
    var ret = slot(prim_void, 0, 1, aapcs64_none);
    var args = [_]ArgSlot{
        slot(prim_int64, 8, 8, aapcs64_general),
        slot(prim_void, 0, 1, aapcs64_none),
    };
    var result: AllocResult = undefined;
    ffi_classify.allocAapcs64(&result, &ret, &args, false, aapcs64_max_ret);

    expect(result.error_kind == alloc_unsupported_spec);
    expect(result.error_arg == 1);
}

/// Whatever the mix of arguments, a convention must never give two of them
/// the same register, and every register it names must be one that exists.
fn noConventionReusesARegister() void {
    const sysv_specs = [_]u32{
        sysv64_integer,     sysv64_sse,         sysv64_pair_intint,
        sysv64_pair_intsse, sysv64_pair_sseint, sysv64_pair_ssesse,
    };

    // Walk a wide range of argument sequences by treating the case number as a
    // base-six numeral over the specs above.
    for (0..4096) |seed| {
        var ret = slot(prim_void, 0, 1, sysv64_no_class);
        var args: [5]ArgSlot = undefined;
        var n = seed;
        for (&args) |*a| {
            a.* = slot(prim_struct, 16, 8, sysv_specs[n % sysv_specs.len]);
            n /= sysv_specs.len;
        }
        var result: AllocResult = undefined;
        ffi_classify.allocSysv64(&result, &ret, &args);
        expect(result.error_kind == alloc_ok);

        var int_used = [_]bool{false} ** 6;
        var fp_used = [_]bool{false} ** 8;
        var stack_words: u32 = 0;
        for (args) |arg| {
            switch (arg.spec) {
                sysv64_integer => {
                    expect(arg.offset < 6);
                    expect(!int_used[arg.offset]);
                    int_used[arg.offset] = true;
                },
                sysv64_sse => {
                    expect(arg.offset < 8);
                    expect(!fp_used[arg.offset]);
                    fp_used[arg.offset] = true;
                },
                sysv64_pair_intint => {
                    expect(arg.offset < 6 and arg.offset2 < 6);
                    expect(!int_used[arg.offset] and !int_used[arg.offset2]);
                    int_used[arg.offset] = true;
                    int_used[arg.offset2] = true;
                },
                sysv64_pair_intsse => {
                    expect(arg.offset < 6 and arg.offset2 < 8);
                    expect(!int_used[arg.offset] and !fp_used[arg.offset2]);
                    int_used[arg.offset] = true;
                    fp_used[arg.offset2] = true;
                },
                sysv64_pair_sseint => {
                    expect(arg.offset < 8 and arg.offset2 < 6);
                    expect(!fp_used[arg.offset] and !int_used[arg.offset2]);
                    fp_used[arg.offset] = true;
                    int_used[arg.offset2] = true;
                },
                sysv64_pair_ssesse => {
                    expect(arg.offset < 8 and arg.offset2 < 8);
                    expect(!fp_used[arg.offset] and !fp_used[arg.offset2]);
                    fp_used[arg.offset] = true;
                    fp_used[arg.offset2] = true;
                },
                sysv64_memory => {
                    // Two words per sixteen-byte argument, laid down in order.
                    expect(arg.offset == stack_words);
                    stack_words += 2;
                },
                else => unreachable,
            }
        }
        expect(result.stack_count == stack_words);
    }
}

/// The same property for AAPCS64, where an aggregate can claim a run of
/// registers rather than just one or two.
fn aapcs64NeverReusesARegister() void {
    const sizes = [_]u64{ 1, 8, 16, 24 };
    const specs = [_]u32{ aapcs64_general, aapcs64_sse, aapcs64_general_ref };

    for ([_]bool{ false, true }) |apple| {
        for (0..4096) |seed| {
            var ret = slot(prim_void, 0, 1, aapcs64_none);
            var args: [6]ArgSlot = undefined;
            var n = seed;
            for (&args) |*a| {
                const spec = specs[n % specs.len];
                n /= specs.len;
                const size = sizes[n % sizes.len];
                n /= sizes.len;
                a.* = slot(prim_struct, size, 8, spec);
            }
            var result: AllocResult = undefined;
            ffi_classify.allocAapcs64(&result, &ret, &args, apple, aapcs64_max_ret);
            expect(result.error_kind == alloc_ok);

            var general_used = [_]bool{false} ** 8;
            var fp_used = [_]bool{false} ** 8;
            for (args) |arg| {
                const words: u32 = @max(1, @as(u32, @intCast((arg.size + 7) / 8)));
                switch (arg.spec) {
                    aapcs64_general => {
                        for (0..words) |w| {
                            expect(arg.offset + w < 8);
                            expect(!general_used[arg.offset + w]);
                            general_used[arg.offset + w] = true;
                        }
                    },
                    aapcs64_sse => {
                        for (0..words) |w| {
                            expect(arg.offset + w < 8);
                            expect(!fp_used[arg.offset + w]);
                            fp_used[arg.offset + w] = true;
                        }
                    },
                    aapcs64_general_ref => {
                        expect(arg.offset < 8);
                        expect(!general_used[arg.offset]);
                        general_used[arg.offset] = true;
                    },
                    // Everything on the stack lies inside the area the
                    // convention reserved for it.
                    aapcs64_stack, aapcs64_stack_ref => expect(arg.offset < result.stack_count),
                    else => unreachable,
                }
                if (arg.spec == aapcs64_general_ref or arg.spec == aapcs64_stack_ref) {
                    expect(arg.offset2 + arg.size <= result.stack_count);
                }
            }
            expect(result.stack_count % 16 == 0);
        }
    }
}

/// Once the registers are gone every later argument must stay on the stack: a
/// convention may not skip a wide argument and give a narrow one the register
/// it could not use.
fn aapcs64DoesNotBackfillRegisters() void {
    var ret = slot(prim_void, 0, 1, aapcs64_none);
    var args = [_]ArgSlot{
        slot(prim_struct, 56, 8, aapcs64_general), // seven words
        slot(prim_struct, 16, 8, aapcs64_general), // two words: will not fit
        slot(prim_int64, 8, 8, aapcs64_general), // one word: would fit
    };
    var result: AllocResult = undefined;
    ffi_classify.allocAapcs64(&result, &ret, &args, false, aapcs64_max_ret);

    expect(args[0].offset == 0);
    expect(args[1].spec == aapcs64_stack);
    expect(args[2].spec == aapcs64_stack);
}

// ==========================================================================
// Entry
// ==========================================================================

pub fn run() void {
    sysv64ClassifiesScalars();
    sysv64SendsWideStructsToMemory();
    sysv64SendsMisalignedStructsToMemory();
    sysv64NamesThePairOfAWideStruct();
    sysv64MergesANarrowStruct();
    sysv64UsesTheOffsetToPickTheEightbyte();
    sysv64DescendsIntoNestedStructs();
    sysv64CarriesAMemoryFieldOutOfAPair();
    sysv64SkipsADecidedSubtreeCorrectly();

    aapcs64ClassifiesScalars();
    aapcs64RecognisesHomogeneousFloatAggregates();
    aapcs64RejectsInhomogeneousAggregates();
    aapcs64PassesWideAggregatesByReference();
    aapcs64UsesTheWholeExtentOfAnArray();
    aapcs64HandlesAnEmptyStruct();
    bothClassifiersAcceptNoNodes();

    win64FillsFourRegistersThenTheStack();
    win64MarksFloatingRegistersInTheVariant();
    win64PassesOddSizesByReference();
    win64ReservesARegisterForAWideReturn();
    win64RoundsTheStackToAnEvenNumberOfWords();

    sysv64FillsTheIntegerRegisters();
    sysv64CountsTheVectorRegistersSeparately();
    sysv64ReservesARegisterForAMemoryReturn();
    sysv64PlacesRegisterPairs();
    sysv64SpillsAPairThatCannotFit();
    sysv64NamesTheReturnVariant();
    sysv64ReportsASpecItCannotPlace();

    aapcs64FillsBothRegisterBanks();
    aapcs64TakesSeveralRegistersForAnAggregate();
    aapcs64PacksTheStackByPlatform();
    aapcs64AlignsStackAggregatesToAWord();
    aapcs64GivesAnHfaOneRegisterPerMember();
    aapcs64SpillsAnHfaThatNoLongerFits();
    aapcs64PlacesTheReferenceAreaAfterTheStack();
    aapcs64SpillsAReferencePointer();
    aapcs64NamesTheReturnVariant();
    aapcs64ReportsAnOversizedReturn();
    aapcs64ReportsASpecItCannotPlace();

    noConventionReusesARegister();
    aapcs64NeverReusesARegister();
    aapcs64DoesNotBackfillRegisters();

    std.debug.print("ffi_classify: all tests passed\n", .{});
}
