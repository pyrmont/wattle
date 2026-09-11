//! Behavioral contract for the value representation: everything
//! `value_wrap.zig` defines.
//!
//! This is the one contract in the tree whose *content* changes shape per
//! target. The two NaN-boxed layouts and the tagged fallback are three
//! different implementations behind one set of signatures, so the cases below
//! come in two kinds and both are needed.
//!
//!  - The layout-independent ones, which are the bulk. A wrapper's type tag, a
//!    round trip through the matching unwrapper, the fact that two wrappers
//!    over the same pointer produce values that are not equal, truthiness, and
//!    the `checkType`/`checkTypes` agreement matrix. These say the
//!    representation is *a* working one.
//!
//!  - The layout-dependent ones, which assert absolute bit patterns computed
//!    from the tag numbering and the payload mask. These say it is *the* one.
//!    Without them a port that shifted every tag by one would pass everything
//!    above.
//!
//! ## The two spellings are compared in one section
//!
//! Each constructor has two spellings: a `wrap.from*` function, which a Zig
//! caller inlines, and the `callconv(.c)` body of the same name in
//! `wrap.abi`, which the library exports. Asserting the two agree is
//! `theTwoSpellingsAgree`'s job and only its. A `wrap.abi` constructor
//! anywhere else below is a way of building a value and nothing more; reading
//! one as half of a comparison would credit its case with a claim it does not
//! make.
//!
//! The two sides of that comparison are the operation a caller gets inlined
//! and the operation the library exports. They are not the same code path, so
//! a disagreement between them would make the interpreter behave differently
//! from the C API about the same value.
//!
//! It is a weaker channel than it looks: both spellings bottom out in `repr`,
//! so it catches an operation wired to the wrong helper and nothing more. The
//! absolute bit patterns below are what catch the helper itself.
//!
//! ## Reading the layout
//!
//! The three-way `#ifdef` chain is unavailable, because a `JANET_*` macro
//! derived from the compiler's predefines is unreliable through `@cImport`:
//! the front end and the compilation can disagree about a predefine. The
//! layout is read off the shape of the translated `Janet` instead, which is
//! what `value_wrap.zig` and `value_order.zig` both do.
//!
//! That the subject and the contract read the same source is not a weakening:
//! neither side ever had an independent opinion about which layout this is.
//! What each side computes *from* it is independent, and that is where the
//! assertions are.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const arrays = @import("subsystems").value.arrays;
const buffers = @import("subsystems").value.buffers;
const config = @import("config");
const corefn = @import("subsystems").corefn;
const expect = @import("expect.zig").expect;

const fibers = @import("subsystems").value.fibers;
const functions = @import("subsystems").value.functions;
const gc_alloc = @import("subsystems").gc_alloc;
const gc_mark = @import("subsystems").gc_mark;
const harness = @import("harness.zig");
const raise = @import("subsystems").raise;
const repr = @import("repr");
const strings = @import("subsystems").value.strings;
const structs = @import("subsystems").value.structs;
const subsystems = @import("subsystems");
const symbols = @import("subsystems").value.symbols;
const tables = @import("subsystems").value.tables;
const tuples = @import("subsystems").value.tuples;
const utils = @import("subsystems").utils;
const vm_lifecycle = @import("subsystems").lifecycle;
const wrap = @import("subsystems").value.wrap;

// ==========================================================================
// Constants
// ==========================================================================

/// Which of the three representations this build compiled with, read off the
/// build's own configuration rather than off the value type.
const layout: Layout = if (config.value_repr == .tagged)
    .tagged
else if (config.value_repr == .nanbox_32)
    .nanbox32
else
    .nanbox64;

// ==========================================================================
// Types
// ==========================================================================

/// The three value representations, as this file names them.
const Layout = enum { nanbox64, nanbox32, tagged };

// ==========================================================================
// Cases
// ==========================================================================

/// Two values are the same value when their payload word and their type agree.
/// `std.mem.eql` over the bytes would be wrong under the tagged layout, whose
/// `Janet` is twelve bytes of content in a sixteen-byte structure: neither
/// implementation writes the padding, and neither is required to.
fn sameValue(a: repr.Value, b: repr.Value) bool {
    return harness.u64Of(a) == harness.u64Of(b) and repr.typeOf(a) == repr.typeOf(b);
}

/// A cfunction to wrap. Its address is the only function pointer in the file,
/// and under a pointer-shifted NaN-box it has to satisfy the same alignment
/// every registered cfunction does, which is what `corefn.alignment` states.
fn aCFunction(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    _ = @as(i32, @intCast(argv.len));

    return wrap.abi.fromNil();
}

/// The same function as the `abi.CFunction` a wrapper takes.
fn theCFunction() abi.CFunction {
    return raise.stored(&aCFunction);
}

/// Sixteen-byte-aligned storage, so the addresses given to the pointer
/// wrappers are legal under every value of `repr.pointer_shift`, which ranges
/// up to 4. A shift discards low bits the wrapper never restores, so an
/// under-aligned pointer would round trip on one target and not on another,
/// which is a difference in the test rather than in the code.
var block_a: [64]u8 align(16) = undefined;
var block_b: [64]u8 align(16) = undefined;

/// The address of `block_a`, and `pointerB` that of `block_b`. Two of them,
/// because a case about two wrappers producing different values needs two.
fn pointerA() ?*anyopaque {
    return @ptrCast(&block_a);
}

fn pointerB() ?*anyopaque {
    return @ptrCast(&block_b);
}

fn typeAt(index: usize) repr.Tag {
    return @enumFromInt(index);
}

/// A tag as an array index. The corpus below is one value per tag in tag
/// order, so `values[at(.string)]` is the string one; the tag is an enum, and
/// an enum is deliberately not an integer.
fn at(t: repr.Tag) usize {
    return @intFromEnum(t);
}

/// One value of each type, in tag order, so the matrix below can be written as
/// a loop rather than as a hundred and sixty-nine assertions.
fn buildOneOfEach(out: *[repr.tag_count]repr.Value) void {
    out[at(.number)] = wrap.fromNumber(2.5);
    out[at(.nil)] = wrap.abi.fromNil();
    out[at(.boolean)] = wrap.abi.fromTrue();
    out[at(.fiber)] = wrap.abi.fromFiber(@ptrCast(@alignCast(pointerA())));
    out[at(.string)] = wrap.abi.fromString(strings.cstring("s"));
    out[at(.symbol)] = wrap.abi.fromSymbol(symbols.csymbol("s"));
    out[at(.keyword)] = wrap.abi.fromKeyword(symbols.csymbol("s"));
    out[at(.array)] = wrap.abi.fromArray(arrays.new(0));
    out[at(.tuple)] = wrap.abi.fromTuple(tuples.newFrom(&.{}));
    out[at(.table)] = wrap.abi.fromTable(tables.new(0));
    out[at(.@"struct")] = wrap.abi.fromStruct(structs.end(structs.begin(0)));
    out[at(.buffer)] = wrap.abi.fromBuffer(buffers.new(0));
    out[at(.function)] = wrap.abi.fromFunction(@ptrCast(@alignCast(pointerA())));
    out[at(.cfunction)] = wrap.abi.fromCfunction(theCFunction());
    out[at(.abstract)] = wrap.abi.fromAbstract(pointerB());
    out[at(.pointer)] = wrap.abi.fromPointer(pointerB());
}

/// Every wrapper stamps its own type, and `janet_type` reads it back. This is
/// the whole of the representation's job stated once. The pointers are not
/// dereferenced by anything here: a wrapper stores an address and a tag, and
/// whether the address points at a real object is the collector's problem.
fn eachWrapperStampsItsType() void {
    const p = pointerA();
    expect(repr.typeOf(wrap.abi.fromNil()) == repr.Tag.nil);
    expect(repr.typeOf(wrap.abi.fromTrue()) == repr.Tag.boolean);
    expect(repr.typeOf(wrap.abi.fromFalse()) == repr.Tag.boolean);
    expect(repr.typeOf(wrap.abi.fromBoolean(1)) == repr.Tag.boolean);
    expect(repr.typeOf(wrap.fromNumber(1.5)) == repr.Tag.number);
    expect(repr.typeOf(wrap.abi.fromString(@ptrCast(p))) == repr.Tag.string);
    expect(repr.typeOf(wrap.abi.fromSymbol(@ptrCast(p))) == repr.Tag.symbol);
    expect(repr.typeOf(wrap.abi.fromKeyword(@ptrCast(p))) == repr.Tag.keyword);
    expect(repr.typeOf(wrap.abi.fromArray(@ptrCast(@alignCast(p)))) == repr.Tag.array);
    expect(repr.typeOf(wrap.abi.fromTuple(@ptrCast(@alignCast(p)))) == repr.Tag.tuple);
    expect(repr.typeOf(wrap.abi.fromStruct(@ptrCast(@alignCast(p)))) == repr.Tag.@"struct");
    expect(repr.typeOf(wrap.abi.fromFiber(@ptrCast(@alignCast(p)))) == repr.Tag.fiber);
    expect(repr.typeOf(wrap.abi.fromBuffer(@ptrCast(@alignCast(p)))) == repr.Tag.buffer);
    expect(repr.typeOf(wrap.abi.fromFunction(@ptrCast(@alignCast(p)))) == repr.Tag.function);
    expect(repr.typeOf(wrap.abi.fromCfunction(theCFunction())) == repr.Tag.cfunction);
    expect(repr.typeOf(wrap.abi.fromTable(@ptrCast(@alignCast(p)))) == repr.Tag.table);
    expect(repr.typeOf(wrap.abi.fromAbstract(p)) == repr.Tag.abstract);
    expect(repr.typeOf(wrap.abi.fromPointer(p)) == repr.Tag.pointer);
}

/// Every pointer wrapper round trips through its own unwrapper, for three
/// addresses: two static blocks and one from the allocator, which is the only
/// one the linker does not fix. All three are sixteen-byte aligned, which is
/// what the pointer wrappers require, since a NaN-boxed 64-bit build discards
/// the low bits on every target that nanboxes.
fn pointerRoundTrips() void {
    const heap_block = utils.malloc(64);
    expect(heap_block != null);
    defer utils.free(heap_block);

    for ([_]?*anyopaque{ pointerA(), pointerB(), heap_block }) |p| {
        expect(wrap.toString(wrap.abi.fromString(@ptrCast(p))) == @as(strings.String, @ptrCast(p)));
        expect(wrap.toSymbol(wrap.abi.fromSymbol(@ptrCast(p))) == @as(strings.Symbol, @ptrCast(p)));
        expect(wrap.toKeyword(wrap.abi.fromKeyword(@ptrCast(p))) == @as(strings.Keyword, @ptrCast(p)));
        expect(wrap.toArray(wrap.abi.fromArray(@ptrCast(@alignCast(p)))) == @as(*arrays.Array, @ptrCast(@alignCast(p))));
        expect(wrap.toTuple(wrap.abi.fromTuple(@ptrCast(@alignCast(p)))) == @as(tuples.Tuple, @ptrCast(@alignCast(p))));
        expect(wrap.toStruct(wrap.abi.fromStruct(@ptrCast(@alignCast(p)))) == @as(structs.Struct, @ptrCast(@alignCast(p))));
        expect(wrap.toFiber(wrap.abi.fromFiber(@ptrCast(@alignCast(p)))) == @as(*fibers.Fiber, @ptrCast(@alignCast(p))));
        expect(wrap.toBuffer(wrap.abi.fromBuffer(@ptrCast(@alignCast(p)))) == @as(*buffers.Buffer, @ptrCast(@alignCast(p))));
        expect(wrap.toFunction(wrap.abi.fromFunction(@ptrCast(@alignCast(p)))) == @as(*functions.Function, @ptrCast(@alignCast(p))));
        expect(wrap.toTable(wrap.abi.fromTable(@ptrCast(@alignCast(p)))) == @as(*tables.Table, @ptrCast(@alignCast(p))));
        expect(wrap.toAbstract(wrap.abi.fromAbstract(p)) == p);
        expect(wrap.toPointerAbi(wrap.abi.fromPointer(p)) == p);
    }
    expect(wrap.toCfunction(wrap.abi.fromCfunction(theCFunction())) == theCFunction());
}

/// A null payload is a legal value for every pointer type: `wrap.fromFiber`
/// takes one every time a fiber has no child. It must not be confused with
/// nil, and it must come back null.
fn nullPayloadsRoundTrip() void {
    expect(wrap.toPointer(wrap.abi.fromFiber(null)) == null);
    expect(wrap.toPointerAbi(wrap.abi.fromPointer(null)) == null);
    expect(wrap.toAbstract(wrap.abi.fromAbstract(null)) == null);
    expect(repr.typeOf(wrap.abi.fromFiber(null)) == repr.Tag.fiber);
    expect(!harness.isType(wrap.abi.fromPointer(null), repr.Tag.nil));

    expect(repr.truthy(wrap.abi.fromPointer(null)));
    expect(!repr.truthy(wrap.abi.fromNil()));
    expect(!repr.truthy(wrap.abi.fromFalse()));
    expect(!repr.truthy(wrap.abi.fromBoolean(0)));
    expect(repr.truthy(wrap.abi.fromTrue()));
    expect(repr.truthy(wrap.abi.fromBoolean(1)));
    expect(repr.truthy(wrap.fromNumber(0.0)));
}

/// The same address under two tags is two different values. This is what a
/// representation that dropped or shared a tag would fail, and it is the reason
/// a keyword and a string spelled alike are not `=` even though they hash
/// alike.
fn theTagIsPartOfTheValue() void {
    const p = pointerA();
    const as_array = wrap.abi.fromArray(@ptrCast(@alignCast(p)));
    const as_table = wrap.abi.fromTable(@ptrCast(@alignCast(p)));
    const as_pointer = wrap.abi.fromPointer(p);
    expect(!sameValue(as_array, as_table));
    expect(!sameValue(as_array, as_pointer));
    expect(!sameValue(as_table, as_pointer));
    expect(!sameValue(wrap.abi.fromString(@ptrCast(p)), wrap.abi.fromSymbol(@ptrCast(p))));
    expect(!sameValue(wrap.abi.fromSymbol(@ptrCast(p)), wrap.abi.fromKeyword(@ptrCast(p))));
    expect(!sameValue(wrap.abi.fromTrue(), wrap.abi.fromFalse()));
    expect(!sameValue(wrap.abi.fromNil(), wrap.abi.fromFalse()));
}

/// Doubles survive the representation exactly, including the ones that are
/// awkward to store beside a tag: both zeroes, both infinities, the smallest
/// subnormal, and the largest finite. Under either NaN-boxed layout the
/// exponent field these share with the tag is what makes the case worth
/// writing.
fn numbersRoundTrip() void {
    const xs = [_]f64{
        0.0,                    -0.0,
        1.0,                    -1.0,
        0.5,                    std.math.inf(f64),
        -std.math.inf(f64),     5e-324,
        1.7976931348623157e308,
    };
    for (xs) |x| {
        const v = wrap.fromNumber(x);
        expect(repr.typeOf(v) == repr.Tag.number);
        expect(harness.isType(v, repr.Tag.number));
        expect(wrap.toNumber(v) == x);
    }
    // Negative zero is preserved as a bit pattern, not merely as a value:
    // `order.hash` normalizes it away and the representation must not.
    expect(wrap.toNumber(wrap.fromNumber(-0.0)) == 0.0);
    expect(1.0 / wrap.toNumber(wrap.fromNumber(-0.0)) < 0.0);
}

/// A NaN is a number, not a tagged value. Under a NaN-boxed layout this is
/// the one case where the tag space and the payload space collide, so
/// `repr.typeOf` has to report a number for a quiet NaN whose bits look like a
/// tag.
///
/// Checked through both spellings, the published abi and the inline surface,
/// because the second arm of the NaN test is reachable through only one of
/// them. `theTwoSpellingsAgree` covers this value among its awkward ones.
fn nanIsANumber() void {
    const nan = std.math.nan(f64);
    const v = wrap.fromNumber(nan);
    expect(repr.typeOf(v) == repr.Tag.number);
    expect(harness.isType(v, repr.Tag.number));
    expect(!harness.isType(v, repr.Tag.nil));
    expect(std.math.isNan(wrap.toNumber(v)));
    expect(repr.truthy(v));
    expect(repr.checkTypes(v, repr.TagSet.one(.number)));
}

/// `wrap.fromNumberSafe` is the entry point unmarshalling uses for a double
/// that came off the wire, and its job is to make sure a crafted payload cannot
/// be read back as a tagged value. Under both NaN-boxed layouts it replaces any
/// NaN with the canonical quiet one; under the tagged layout it does not,
/// because there is no tag space in the double to protect. That asymmetry is
/// deliberate, and both arms are asserted below.
fn wrapNumberSafe() void {
    for ([_]f64{ 0.0, -3.25, std.math.inf(f64) }) |x| {
        expect(sameValue(wrap.fromNumberSafe(x), wrap.fromNumber(x)));
    }
    expect(repr.typeOf(wrap.fromNumberSafe(std.math.nan(f64))) == repr.Tag.number);

    if (layout != .tagged) {
        // A signalling NaN with a payload in the low bits, which is what a
        // hostile marshalled double looks like.
        const hostile: f64 = @bitCast(@as(u64, 0x7FF0000000000123));
        expect(std.math.isNan(hostile));
        expect(sameValue(
            wrap.fromNumberSafe(hostile),
            wrap.fromNumberSafe(std.math.nan(f64)),
        ));
    }
}

/// `wrap.toIntegerAbi` truncates toward zero. Only in-range inputs are
/// checked, because an unchecked cast is undefined outside the destination
/// range and the two behavioural targets differ there: aarch64's `fcvtzs`
/// saturates where x86-64's `cvttsd2si` yields `INT32_MIN`, so nothing out of
/// range can be asserted for both. This runtime tests before converting and
/// saturates.
fn theIntegerConversions() void {
    expect(wrap.toIntegerAbi(wrap.fromNumber(0.0)) == 0);
    expect(wrap.toIntegerAbi(wrap.fromNumber(1.9)) == 1);
    expect(wrap.toIntegerAbi(wrap.fromNumber(-1.9)) == -1);
    expect(wrap.toIntegerAbi(wrap.fromNumber(2147483647.0)) == std.math.maxInt(i32));
    expect(wrap.toIntegerAbi(wrap.fromNumber(-2147483648.0)) == std.math.minInt(i32));

    // The inline form exists under all three layouts; the *symbol* exists
    // under two. Asserting the inline one here is what keeps the tagged build
    // covered at all, and asserting the symbol below is what pins the
    // asymmetry rather than merely tolerating it.
    expect(sameValue(wrap.fromInteger(7), wrap.fromNumber(7.0)));
    expect(sameValue(wrap.fromInteger(std.math.minInt(i32)), wrap.fromNumber(-2147483648.0)));
    expect(wrap.toInteger(wrap.fromInteger(-5)) == -5);
    expect(sameValue(wrap.fromInteger(-5), harness.wrapInteger(-5)));

    {
        // `wrap.abi.fromInteger` is compiled under all three layouts and the
        // contract imports it rather than linking against an export, so these
        // run everywhere.
        expect(sameValue(wrap.abi.fromInteger(7), wrap.fromNumber(7.0)));
        expect(wrap.toIntegerAbi(wrap.abi.fromInteger(-5)) == -5);
        expect(wrap.toIntegerAbi(wrap.abi.fromInteger(std.math.maxInt(i32))) == std.math.maxInt(i32));
    }
}

/// `wrap.abi.fromBoolean` normalizes: any non-zero argument makes the same
/// value as `wrap.abi.fromTrue`, and `wrap.toBoolean` reads back the
/// normalized value rather than whatever went in.
fn booleansNormalize() void {
    expect(sameValue(wrap.abi.fromBoolean(1), wrap.abi.fromTrue()));
    expect(sameValue(wrap.abi.fromBoolean(2), wrap.abi.fromTrue()));
    expect(sameValue(wrap.abi.fromBoolean(-1), wrap.abi.fromTrue()));
    expect(sameValue(wrap.abi.fromBoolean(0), wrap.abi.fromFalse()));
    expect(wrap.toBoolean(wrap.abi.fromTrue()));
    expect(!wrap.toBoolean(wrap.abi.fromFalse()));
    expect(wrap.toBoolean(wrap.abi.fromBoolean(37)));
}

/// Exactly two values are false and everything else is true, including zero,
/// the empty string and an empty array, which is where Janet's truthiness
/// parts company with C's.
fn truthiness() void {
    expect(!repr.truthy(wrap.abi.fromNil()));
    expect(!repr.truthy(wrap.abi.fromFalse()));
    expect(!repr.truthy(wrap.abi.fromBoolean(0)));
    expect(repr.truthy(wrap.abi.fromTrue()));
    expect(repr.truthy(wrap.abi.fromBoolean(1)));
    expect(repr.truthy(wrap.fromNumber(0.0)));
    expect(repr.truthy(wrap.fromNumber(std.math.nan(f64))));
    expect(repr.truthy(wrap.abi.fromString(strings.cstring(""))));
    expect(repr.truthy(wrap.abi.fromArray(arrays.new(0))));
    expect(repr.truthy(wrap.abi.fromPointer(null)));
}

/// The type predicate agrees with `repr.typeOf` for every value against every
/// type. It is the full matrix rather than the diagonal, because under a
/// NaN-boxed layout the number case is tested differently from the rest, so a
/// wrong result is as likely to be a false positive as a false negative.
fn theCheckTypeMatrix() void {
    var values: [repr.tag_count]repr.Value = undefined;
    buildOneOfEach(&values);
    for (values, 0..) |value, i| {
        for (0..repr.tag_count) |j| {
            expect(harness.isType(value, typeAt(j)) == (i == j));
        }
        expect(repr.typeOf(value) == typeAt(i));
    }
}

/// `repr.checkTypes` is the type as a bit in a mask, and the *exported* form
/// returns the masked bit rather than a normalized boolean, where the internal
/// one returns a `bool`. Both halves are asserted here and the bit only of the
/// abi form.
fn checkTypes() void {
    var values: [repr.tag_count]repr.Value = undefined;
    buildOneOfEach(&values);
    for (values, 0..) |value, i| {
        const tag: repr.Tag = @enumFromInt(i);
        const set = repr.TagSet.one(tag);
        expect(repr.checkTypes(value, set));
        expect(!repr.checkTypes(value, repr.TagSet.fromBits(~set.bits())));
        expect(repr.checkTypes(value, repr.TagSet.all));
        expect(!repr.checkTypes(value, repr.TagSet.none));
        // A set of every bit there is, including the ones above fifteen that
        // name no tag, still selects this value.
        expect(repr.checkTypes(value, repr.TagSet.fromBits(~@as(u16, 0))));
    }
    expect(repr.checkTypes(values[at(.string)], repr.TagSet.bytes));
    expect(repr.checkTypes(values[at(.symbol)], repr.TagSet.bytes));
    expect(repr.checkTypes(values[at(.keyword)], repr.TagSet.bytes));
    expect(repr.checkTypes(values[at(.buffer)], repr.TagSet.bytes));
    expect(!repr.checkTypes(values[at(.array)], repr.TagSet.bytes));
}

/// Every predicate with both an internal and an exported form, checked
/// against each other for the one value `v`. Factored out because the set of
/// values that matters is larger than one per type; see the call site.
///
/// Both sides are spelled out here rather than borrowed. These read the
/// published form directly instead of `harness.isType`, because a harness
/// helper pointing at the internal spelling would turn every comparison here
/// into a function compared against itself.
///
/// `capi.janet_checktype` is the only predicate left with two
/// implementations. It guards the tag against `repr.tag_count` and gives 0 for
/// a number outside the vocabulary, which `repr.checkType` does not do and
/// cannot, its argument already being a `Tag`. So the loop below is the range
/// guard as much as it is the agreement.
fn agreeOn(v: repr.Value) void {
    for (0..repr.tag_count) |j| {
        expect(repr.checkType(v, typeAt(j)) == (subsystems.capi.janet_checktype(v, @intCast(j)) != 0));
    }
    expect(subsystems.capi.janet_checktype(v, repr.tag_count) == 0);
    expect(subsystems.capi.janet_checktype(v, std.math.maxInt(c_uint)) == 0);
}

/// The inline spelling of each operation against the exported one, for every
/// value in the sample and for the awkward ones beside it. The header says
/// what that channel does and does not catch.
fn theTwoSpellingsAgree() void {
    var values: [repr.tag_count]repr.Value = undefined;
    buildOneOfEach(&values);
    const p = pointerA();

    // The constructors. Each inline declaration is the body of the
    // identically named export, so a disagreement means one of the two is
    // wired to the wrong helper.
    expect(sameValue(wrap.fromNil(), wrap.abi.fromNil()));
    expect(sameValue(wrap.fromTrue(), wrap.abi.fromTrue()));
    expect(sameValue(wrap.fromFalse(), wrap.abi.fromFalse()));
    expect(sameValue(wrap.fromBoolean(true), wrap.abi.fromBoolean(3)));
    expect(sameValue(wrap.fromBoolean(false), wrap.abi.fromBoolean(0)));
    expect(sameValue(wrap.fromNumber(2.5), wrap.abi.fromNumber(2.5)));
    expect(sameValue(wrap.fromArray(@ptrCast(@alignCast(p))), wrap.abi.fromArray(@ptrCast(@alignCast(p)))));
    expect(sameValue(wrap.fromTable(@ptrCast(@alignCast(p))), wrap.abi.fromTable(@ptrCast(@alignCast(p)))));
    expect(sameValue(wrap.fromBuffer(@ptrCast(@alignCast(p))), wrap.abi.fromBuffer(@ptrCast(@alignCast(p)))));
    expect(sameValue(wrap.fromFunction(@ptrCast(@alignCast(p))), wrap.abi.fromFunction(@ptrCast(@alignCast(p)))));
    expect(sameValue(wrap.fromStruct(@ptrCast(@alignCast(p))), wrap.abi.fromStruct(@ptrCast(@alignCast(p)))));
    expect(sameValue(wrap.fromTuple(@ptrCast(@alignCast(p))), wrap.abi.fromTuple(@ptrCast(@alignCast(p)))));

    // The predicates, over one value per type...
    for (values) |value| agreeOn(value);

    // ...and then over the values that take the *other* arm of each. One
    // value per type is not enough, because `buildOneOfEach` samples `2.5`
    // and `true`, which take the ordinary arm of every predicate. A NaN's
    // type nibble under a NaN-boxed layout reads as the number tag, so it is
    // recognized by the second half of `isNumber` rather than the first, and
    // `false` is the only value whose truthiness depends on the payload
    // rather than on the tag.
    const awkward = [_]repr.Value{
        wrap.fromNumber(std.math.nan(f64)),
        wrap.fromNumber(std.math.inf(f64)),
        wrap.fromNumber(-std.math.inf(f64)),
        wrap.fromNumber(0.0),
        wrap.fromNumber(-0.0),
        wrap.abi.fromFalse(),
        wrap.abi.fromBoolean(0),
        wrap.abi.fromBoolean(3),
        wrap.abi.fromPointer(null),
    };
    for (awkward) |value| agreeOn(value);

    // The one accessor with two implementations. `toIntegerAbi` truncates
    // toward zero through a `c_int` where `toInteger` reads the payload. The
    // other unwraps have one body each.
    expect(wrap.toInteger(wrap.fromNumber(-9.5)) == wrap.toIntegerAbi(wrap.fromNumber(-9.5)));
}

/// The assertions that say this is *the* representation rather than a working
/// one. Each is computed from the tag numbering and the payload mask, and none
/// of them goes through an implementation of the thing under test.
///
/// One per layout, selected below. Zig analyses only the body it is handed,
/// so the two that do not apply are never compiled, and they could not be:
/// each layout's helpers exist only in that layout's build.
fn exactLayoutNanbox64() void {
    const p = pointerA();
    const nil_tag: u64 = (@as(u64, @intFromEnum(repr.Tag.nil)) | 0x1FFF0) << 47;
    const bool_tag: u64 = (@as(u64, @intFromEnum(repr.Tag.boolean)) | 0x1FFF0) << 47;
    const array_tag: u64 = (@as(u64, @intFromEnum(repr.Tag.array)) | 0x1FFF0) << 47;

    // The three immediate values are a tag with a one-bit payload.
    expect(harness.u64Of(wrap.abi.fromNil()) == (nil_tag | 1));
    expect(harness.u64Of(wrap.abi.fromTrue()) == (bool_tag | 1));
    expect(harness.u64Of(wrap.abi.fromFalse()) == bool_tag);

    // A double is stored unchanged.
    const bits: u64 = @bitCast(@as(f64, 1.5));
    expect(harness.u64Of(wrap.fromNumber(1.5)) == bits);
    expect(harness.u64Of(wrap.nanboxFromDouble(1.5)) == bits);
    expect(harness.u64Of(wrap.nanboxFromBits(bits)) == bits);

    // A pointer is shifted right by the alignment shift and then tagged, and
    // the payload bits are the only ones it may occupy.
    const word = harness.u64Of(wrap.abi.fromArray(@ptrCast(@alignCast(p))));
    expect((word & repr.tagbits) == array_tag);
    expect((word & repr.payloadbits) ==
        (@as(u64, @intFromPtr(p)) >> repr.pointer_shift));
    expect(wrap.nanboxToPointer(wrap.nanboxFromPointer(p, array_tag)) == p);
    expect(wrap.nanboxToPointer(wrap.nanboxFromCPointer(p, array_tag)) == p);
    expect(harness.u64Of(wrap.nanboxFromPointer(p, array_tag)) == word);

    // The canonical NaN is what `wrap.fromNumberSafe` stores, and it is not
    // mistaken for a tagged value.
    const canonical: u64 = @bitCast(wrap.toNumber(wrap.fromNumberSafe(std.math.nan(f64))));
    expect(repr.typeOf(wrap.fromNumberSafe(std.math.nan(f64))) == repr.Tag.number);
    expect((canonical & repr.payloadbits) == 0);
}

fn exactLayoutNanbox32() void {
    const p = pointerA();

    // Every non-number tag is stored raw in the high word, below the offset
    // that biases a double's exponent out of the way.
    expect(wrap.abi.fromNil().tagged.type == @as(u32, @intFromEnum(repr.Tag.nil)));
    expect(wrap.abi.fromNil().tagged.payload.integer == 0);
    expect(wrap.abi.fromTrue().tagged.type == @as(u32, @intFromEnum(repr.Tag.boolean)));
    expect(wrap.abi.fromTrue().tagged.payload.integer == 1);
    expect(wrap.abi.fromFalse().tagged.payload.integer == 0);
    expect(wrap.abi.fromArray(@ptrCast(@alignCast(p))).tagged.type == @as(u32, @intFromEnum(repr.Tag.array)));
    expect(wrap.abi.fromArray(@ptrCast(@alignCast(p))).tagged.payload.pointer == p);
    expect(@as(u32, @intFromEnum(repr.Tag.pointer)) < @as(u32, repr.double_offset));

    // A double is biased by `repr.double_offset` in its high word, which is
    // what keeps every number above every tag.
    const bits: u64 = @bitCast(@as(f64, 1.5));
    expect(harness.u64Of(wrap.fromNumber(1.5)) == bits +% (@as(u64, repr.double_offset) << 32));
    expect(wrap.toNumber(wrap.fromNumber(1.5)) == 1.5);

    expect(wrap.nanbox32FromTagI(@as(u32, @intFromEnum(repr.Tag.boolean)), 1).tagged.payload.integer == 1);
    expect(wrap.nanbox32FromTagP(@as(u32, @intFromEnum(repr.Tag.array)), p).tagged.payload.pointer == p);
    expect(wrap.nanbox32FromTagP(@as(u32, @intFromEnum(repr.Tag.array)), p).tagged.type == @as(u32, @intFromEnum(repr.Tag.array)));

    const canonical: u64 = @bitCast(wrap.toNumber(wrap.fromNumberSafe(std.math.nan(f64))));
    expect((canonical & 0x000FFFFFFFFFFFFF) == 0x0008000000000000);
}

fn exactLayoutTagged() void {
    const p = pointerA();

    // The tag is a field of its own, and the payload union is zeroed before
    // the narrower member is written, which is what the `as.u64 = 0` in
    // `repr.zig`'s wrappers is for. The only way to see it is through a member
    // narrower than the union.
    expect(wrap.abi.fromNil().type == @intFromEnum(repr.Tag.nil));
    expect(harness.u64Of(wrap.abi.fromNil()) == 0);
    expect(wrap.abi.fromTrue().type == @intFromEnum(repr.Tag.boolean));
    expect(harness.u64Of(wrap.abi.fromTrue()) == 1);
    expect(harness.u64Of(wrap.abi.fromFalse()) == 0);
    expect(wrap.abi.fromArray(@ptrCast(@alignCast(p))).type == @intFromEnum(repr.Tag.array));
    expect(harness.u64Of(wrap.abi.fromArray(@ptrCast(@alignCast(p)))) == @as(u64, @intFromPtr(p)));
    expect(harness.u64Of(wrap.abi.fromPointer(null)) == 0);

    expect(harness.u64Of(wrap.fromNumber(1.5)) == @as(u64, @bitCast(@as(f64, 1.5))));

    // The one layout that does not canonicalize a NaN, because it has no tag
    // space in the double to protect: canonicalization exists to keep a
    // payload out of the bits a NaN-boxed layout reads as a tag, and the
    // tagged layout reads none of them.
    const hostile: u64 = 0x7FF0000000000123;
    expect(harness.u64Of(wrap.fromNumberSafe(@bitCast(hostile))) == hostile);
}

const exactLayout = switch (layout) {
    .nanbox64 => exactLayoutNanbox64,
    .nanbox32 => exactLayoutNanbox32,
    .tagged => exactLayoutTagged,
};

/// `value.memallocEmpty` is the allocator every dictionary's bucket array
/// comes from. Three things are its contract: the block is `count` pairs long,
/// every pair is nil/nil, and the collection budget is charged for the bytes.
/// The charge is what only this case sees: `gc.gcallocBytes` bills its own
/// blocks and this one is a plain heap allocation.
fn memallocEmpty() void {
    for ([_]i32{ 1, 8, 257 }) |n| {
        const before = harness.vm().gc.next_collection;
        const kvs: ?[*]tables.KV = @ptrCast(@alignCast(subsystems.value.memallocEmpty(@intCast(n))));
        // Reaching this line is the null check: the failure path exits.
        expect(kvs != null);
        expect(harness.vm().gc.next_collection - before == @as(usize, @intCast(n)) * @sizeOf(tables.KV));
        var i: i32 = 0;
        while (i < n) : (i += 1) {
            expect(harness.isType(kvs.?[@intCast(i)].key, repr.Tag.nil));
            expect(harness.isType(kvs.?[@intCast(i)].value, repr.Tag.nil));
        }
        utils.free(kvs);
    }
}

/// A zero-length request charges nothing and writes nothing. The pointer it
/// returns is whatever the platform's `malloc(0)` gives, which is a block on
/// macOS and on musl; if it were null the process would have exited inside the
/// call, so the assertion below is about the charge and not about the pointer.
fn memallocEmptyOfZero() void {
    const before = harness.vm().gc.next_collection;
    const mem = subsystems.value.memallocEmpty(0);
    expect(harness.vm().gc.next_collection == before);
    utils.free(mem);
}

/// `value.memempty` clears a block the caller already owns. The block is
/// dirtied first with values of a type that is not nil under every layout, so a
/// fill that did nothing at all would be caught rather than passing on whatever
/// the allocator happened to leave.
fn mememptyClearsADirtyBlock() void {
    const n = 16;
    const kvs: [*]tables.KV = @ptrCast(@alignCast(subsystems.value.memallocEmpty(@intCast(n))));
    defer utils.free(kvs);

    for (0..n) |i| {
        kvs[i].key = harness.wrapInteger(@intCast(i + 1));
        kvs[i].value = wrap.abi.fromBoolean(1);
        expect(!harness.isType(kvs[i].key, repr.Tag.nil));
        expect(!harness.isType(kvs[i].value, repr.Tag.nil));
    }

    subsystems.value.memempty(kvs[0..n]);
    for (0..n) |i| {
        expect(harness.isType(kvs[i].key, repr.Tag.nil));
        expect(harness.isType(kvs[i].value, repr.Tag.nil));
        expect(sameValue(kvs[i].key, wrap.abi.fromNil()));
        expect(sameValue(kvs[i].value, wrap.abi.fromNil()));
    }

    // A zero count leaves the block alone rather than clearing one pair.
    kvs[0].key = wrap.abi.fromBoolean(1);
    subsystems.value.memempty(kvs[0..0]);
    expect(harness.isType(kvs[0].key, repr.Tag.boolean));
}

/// Values built by these wrappers are what the collector traverses, so the last
/// case is that a heap object reached only through a wrapped value survives a
/// collection while rooted and is freed once it is not.
fn repeatedCycles() void {
    var i: i32 = 0;
    while (i < 64) : (i += 1) {
        const array = wrap.abi.fromArray(arrays.new(4));
        const table = wrap.abi.fromTable(tables.new(4));
        const buffer = wrap.abi.fromBuffer(buffers.new(4));
        const string = wrap.abi.fromString(strings.cstring("cycle"));
        harness.arrayPush(wrap.toArray(array), string);
        tables.put(wrap.toTable(table), harness.wrapInteger(i), buffer);
        gc_alloc.gcroot(array);
        gc_alloc.gcroot(table);
        gc_mark.collect();
        expect(repr.typeOf(array) == repr.Tag.array);
        expect(wrap.toArray(array).count == 1);
        expect(sameValue(wrap.toArray(array).slice()[0], string));
        expect(sameValue(
            tables.get(wrap.toTable(table), harness.wrapInteger(i)),
            buffer,
        ));
        _ = gc_alloc.gcunroot(table);
        _ = gc_alloc.gcunroot(array);
        gc_mark.collect();
    }
}

// ==========================================================================
// Entry
// ==========================================================================

pub fn run() void {
    harness.init();
    defer vm_lifecycle.deinitAbi();

    eachWrapperStampsItsType();
    pointerRoundTrips();
    nullPayloadsRoundTrip();
    theTagIsPartOfTheValue();

    numbersRoundTrip();
    nanIsANumber();
    wrapNumberSafe();
    theIntegerConversions();

    booleansNormalize();
    truthiness();

    theCheckTypeMatrix();
    checkTypes();

    theTwoSpellingsAgree();
    exactLayout();

    memallocEmpty();
    memallocEmptyOfZero();
    mememptyClearsADirtyBlock();

    repeatedCycles();
}
