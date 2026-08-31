//! Behavioral contract for the value representation: everything
//! `value_wrap.zig` defines.
//!
//! This is the one contract in the tree whose *content* changes shape per
//! target. `JANET_NANBOX_64`, `JANET_NANBOX_32` and the tagged fallback are
//! three different implementations behind one set of signatures, so the cases
//! below come in two kinds and both are needed.
//!
//!  - The layout-independent ones, which are the bulk. A wrapper's type tag, a
//!    round trip through the matching unwrapper, the fact that two wrappers
//!    over the same pointer produce values that are not equal, truthiness, and
//!    the `janet_checktype`/`janet_checktypes` agreement matrix. These say the
//!    representation is *a* working one.
//!
//!  - The layout-dependent ones, which assert absolute bit patterns computed
//!    from `janet.h`'s own constants. These say it is *the* one. Without them
//!    a port that shifted every tag by one would pass everything above.
//!
//! ## `c.janet_*` here is the subject, not a call in arrears
//!
//! Every `c.janet_*` below is deliberate: this file's job is to compare the
//! *exported symbol* against the inline surface a Zig caller gets, so pointing
//! a call site here at the internal spelling puts the same function on both
//! sides of an `==`. Those references are also what keep the `cabi.zig`
//! declarations alive, which is what lets `cabi_check.zig` hold a row for
//! each.
//!
//! **A Zig contract cannot reach a macro.** Janet declares `janet_checktype`,
//! `janet_truthy`, `janet_wrap_integer` and their kin as functions *beside*
//! macros of the same name, and C's rule that a parenthesised name is not
//! macro-expanded is what lets a C contract compare the two. There is one
//! spelling here, so asserting they agree would be a case that cannot fail.
//!
//! What the two sides of that comparison really were is *the operation a
//! caller gets inlined* and *the operation the library exports*, and this
//! runtime has that same pair: the `pub inline fn` a caller reaches --
//! measured at +89% on the arithmetic workload when it went through the symbol
//! table instead -- and the `@export`s beside them. Twenty-one
//! operations have both spellings, they are not the same code path, and a
//! disagreement would make the interpreter answer differently from the C API
//! about the same value. `theTwoSpellingsAgree` is that channel, and it is the
//! C original's claim carried over rather than a new one.
//!
//! It is weaker than it looks in the same way the original was, and for the
//! same reason its own header gave: both spellings bottom out in `repr`, so
//! this catches an operation wired to the wrong helper and nothing more. The
//! absolute bit patterns are what catch the helper itself.
//!
//! ## Reading the layout
//!
//! The three-way `#ifdef` chain is unavailable, because a `JANET_*` macro
//! derived from the compiler's predefines is unreliable through `@cImport` --
//! `FOUND.md` has the case. The layout is read off the shape of the
//! translated `Janet` instead, which is what `value_wrap.zig` and
//! `value_order.zig` both do.
//!
//! That the subject and the contract read the same source is not a weakening:
//! the C contract's `#ifdef` chain was `janet.h`'s, and so was `wrap.c`'s.
//! Neither side ever had an independent opinion about which layout this is.
//! What each side computes *from* it is independent, and that is where the
//! assertions are.
//!
//! ## `janet_wrap_integer` is referenced only under a NaN-boxed layout
//!
//! Not tidiness: `value_wrap.zig` exports the symbol only there, reproducing
//! the defect `FOUND.md` records against `wrap.c`, so a tagged build has no
//! such symbol and naming it would fail to link. The inline form exists under
//! all three, which is itself worth asserting -- see `theIntegerConversions`.

const std = @import("std");
const types = @import("types");
const repr = @import("repr");
const c = @import("cabi");
const raise = @import("raise");
const harness = @import("harness.zig");
const corefn = @import("corefn");
const config = @import("config");

const wrap = @import("subsystems").value.wrap;
const structs = @import("subsystems").value.structs;
const tables = @import("subsystems").value.tables;
const gc_alloc = @import("subsystems").gc_alloc;
const strings = @import("subsystems").value.strings;
const symbols = @import("subsystems").value.symbols;
const tuples = @import("subsystems").value.tuples;
const utils = @import("subsystems").utils;
const gc_mark = @import("subsystems").gc_mark;
const internal = harness.internal;
const assert = std.debug.assert;

// ------------------------------------------------------------------ layout

const Layout = enum { nanbox64, nanbox32, tagged };

/// Which of `janet.h`'s three representations this build compiled with, read
/// off the translated type. See the header for why it is not the `#ifdef`
/// chain, and `value_wrap.zig` for the same three lines with the same reason.
const layout: Layout = if (config.value_repr == .tagged)
    .tagged
else if (config.value_repr == .nanbox_32)
    .nanbox32
else
    .nanbox64;

// ----------------------------------------------------------------- helpers

/// Two values are the same value when their payload word and their type agree.
/// `std.mem.eql` over the bytes would be wrong under the tagged layout, whose
/// `Janet` is twelve bytes of content in a sixteen-byte structure: neither
/// implementation writes the padding, and neither is required to.
fn sameValue(a: repr.Value, b: repr.Value) bool {
    return harness.u64Of(a) == harness.u64Of(b) and c.janet_type(a) == c.janet_type(b);
}

/// A cfunction to wrap. Its address is the only function pointer in the file,
/// and under a pointer-shifted NaN-box it has to satisfy the same alignment
/// every registered cfunction does -- which is what `corefn.alignment` is.
fn aCFunction(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    _ = @as(i32, @intCast(argv.len));

    return c.janet_wrap_nil();
}

fn theCFunction() types.JanetCFunction {
    return raise.stored(&aCFunction);
}

/// Sixteen-byte-aligned storage, so the addresses handed to the pointer
/// wrappers are legal under every value of `repr.pointer_shift`,
/// which ranges up to 4. A shift discards low bits that the wrapper never
/// restores, so an under-aligned pointer would not round trip on aarch64 Linux
/// and would on macOS -- a difference in the test rather than in the code.
var block_a: [64]u8 align(16) = undefined;
var block_b: [64]u8 align(16) = undefined;

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

// -------------------------------------------------- type tags and round trips

/// Every wrapper stamps its own type, and `janet_type` reads it back. This is
/// the whole of the representation's job stated once. The pointers are not
/// dereferenced by anything here: a wrapper stores an address and a tag, and
/// whether the address points at a real object is the collector's problem.
fn eachWrapperStampsItsType() void {
    const p = pointerA();
    assert(c.janet_type(c.janet_wrap_nil()) == @intFromEnum(repr.Tag.nil));
    assert(c.janet_type(c.janet_wrap_true()) == @intFromEnum(repr.Tag.boolean));
    assert(c.janet_type(c.janet_wrap_false()) == @intFromEnum(repr.Tag.boolean));
    assert(c.janet_type(c.janet_wrap_boolean(1)) == @intFromEnum(repr.Tag.boolean));
    assert(c.janet_type(wrap.fromNumber(1.5)) == @intFromEnum(repr.Tag.number));
    assert(c.janet_type(c.janet_wrap_string(@ptrCast(p))) == @intFromEnum(repr.Tag.string));
    assert(c.janet_type(c.janet_wrap_symbol(@ptrCast(p))) == @intFromEnum(repr.Tag.symbol));
    assert(c.janet_type(c.janet_wrap_keyword(@ptrCast(p))) == @intFromEnum(repr.Tag.keyword));
    assert(c.janet_type(c.janet_wrap_array(@ptrCast(@alignCast(p)))) == @intFromEnum(repr.Tag.array));
    assert(c.janet_type(c.janet_wrap_tuple(@ptrCast(@alignCast(p)))) == @intFromEnum(repr.Tag.tuple));
    assert(c.janet_type(c.janet_wrap_struct(@ptrCast(@alignCast(p)))) == @intFromEnum(repr.Tag.@"struct"));
    assert(c.janet_type(c.janet_wrap_fiber(@ptrCast(@alignCast(p)))) == @intFromEnum(repr.Tag.fiber));
    assert(c.janet_type(c.janet_wrap_buffer(@ptrCast(@alignCast(p)))) == @intFromEnum(repr.Tag.buffer));
    assert(c.janet_type(c.janet_wrap_function(@ptrCast(@alignCast(p)))) == @intFromEnum(repr.Tag.function));
    assert(c.janet_type(c.janet_wrap_cfunction(theCFunction())) == @intFromEnum(repr.Tag.cfunction));
    assert(c.janet_type(c.janet_wrap_table(@ptrCast(@alignCast(p)))) == @intFromEnum(repr.Tag.table));
    assert(c.janet_type(c.janet_wrap_abstract(p)) == @intFromEnum(repr.Tag.abstract));
    assert(c.janet_type(c.janet_wrap_pointer(p)) == @intFromEnum(repr.Tag.pointer));
}

/// Every pointer wrapper round trips through its own unwrapper, for three
/// addresses: two static blocks and one from the allocator, which is the only
/// one whose value is not known at link time. Sixteen-byte aligned, which is
/// what the pointer wrappers require -- a NaN-boxed 64-bit build discards the
/// low bits on every target that nanboxes.
fn pointerRoundTrips() void {
    const heap_block = utils.malloc(64);
    assert(heap_block != null);
    defer utils.free(heap_block);

    for ([_]?*anyopaque{ pointerA(), pointerB(), heap_block }) |p| {
        assert(wrap.toString(c.janet_wrap_string(@ptrCast(p))) == @as(types.JanetString, @ptrCast(p)));
        assert(wrap.toSymbol(c.janet_wrap_symbol(@ptrCast(p))) == @as(types.JanetSymbol, @ptrCast(p)));
        assert(wrap.toKeyword(c.janet_wrap_keyword(@ptrCast(p))) == @as(types.JanetKeyword, @ptrCast(p)));
        assert(wrap.toArray(c.janet_wrap_array(@ptrCast(@alignCast(p)))) == @as(*types.JanetArray, @ptrCast(@alignCast(p))));
        assert(wrap.toTuple(c.janet_wrap_tuple(@ptrCast(@alignCast(p)))) == @as(types.JanetTuple, @ptrCast(@alignCast(p))));
        assert(wrap.toStruct(c.janet_wrap_struct(@ptrCast(@alignCast(p)))) == @as(types.JanetStruct, @ptrCast(@alignCast(p))));
        assert(wrap.toFiber(c.janet_wrap_fiber(@ptrCast(@alignCast(p)))) == @as(*types.JanetFiber, @ptrCast(@alignCast(p))));
        assert(wrap.toBuffer(c.janet_wrap_buffer(@ptrCast(@alignCast(p)))) == @as(*types.JanetBuffer, @ptrCast(@alignCast(p))));
        assert(wrap.toFunction(c.janet_wrap_function(@ptrCast(@alignCast(p)))) == @as(*types.JanetFunction, @ptrCast(@alignCast(p))));
        assert(wrap.toTable(c.janet_wrap_table(@ptrCast(@alignCast(p)))) == @as(*types.JanetTable, @ptrCast(@alignCast(p))));
        assert(wrap.toAbstract(c.janet_wrap_abstract(p)) == p);
        assert(c.janet_unwrap_pointer(c.janet_wrap_pointer(p)) == p);
    }
    assert(wrap.toCfunction(c.janet_wrap_cfunction(theCFunction())) == theCFunction());
}

/// A null payload is a legal value for every pointer type -- `janet_wrap_fiber`
/// is called with one every time a fiber has no child. It must not be confused
/// with nil, and it must come back null.
fn nullPayloadsRoundTrip() void {
    assert(wrap.toPointer(c.janet_wrap_fiber(null)) == null);
    assert(c.janet_unwrap_pointer(c.janet_wrap_pointer(null)) == null);
    assert(wrap.toAbstract(c.janet_wrap_abstract(null)) == null);
    assert(c.janet_type(c.janet_wrap_fiber(null)) == @intFromEnum(repr.Tag.fiber));
    assert(!harness.isType(c.janet_wrap_pointer(null), repr.Tag.nil));

    assert(repr.truthy(c.janet_wrap_pointer(null)));
    assert(!repr.truthy(c.janet_wrap_nil()));
    assert(!repr.truthy(c.janet_wrap_false()));
    assert(!repr.truthy(c.janet_wrap_boolean(0)));
    assert(repr.truthy(c.janet_wrap_true()));
    assert(repr.truthy(c.janet_wrap_boolean(1)));
    assert(repr.truthy(wrap.fromNumber(0.0)));
}

/// The same address under two tags is two different values. This is what a
/// representation that dropped or shared a tag would fail, and it is the reason
/// a keyword and a string spelled alike are not `=` even though they hash
/// alike.
fn theTagIsPartOfTheValue() void {
    const p = pointerA();
    const as_array = c.janet_wrap_array(@ptrCast(@alignCast(p)));
    const as_table = c.janet_wrap_table(@ptrCast(@alignCast(p)));
    const as_pointer = c.janet_wrap_pointer(p);
    assert(!sameValue(as_array, as_table));
    assert(!sameValue(as_array, as_pointer));
    assert(!sameValue(as_table, as_pointer));
    assert(!sameValue(c.janet_wrap_string(@ptrCast(p)), c.janet_wrap_symbol(@ptrCast(p))));
    assert(!sameValue(c.janet_wrap_symbol(@ptrCast(p)), c.janet_wrap_keyword(@ptrCast(p))));
    assert(!sameValue(c.janet_wrap_true(), c.janet_wrap_false()));
    assert(!sameValue(c.janet_wrap_nil(), c.janet_wrap_false()));
}

// ------------------------------------------------------------------- numbers

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
        assert(c.janet_type(v) == @intFromEnum(repr.Tag.number));
        assert(harness.isType(v, repr.Tag.number));
        assert(wrap.toNumber(v) == x);
    }
    // Negative zero is preserved as a bit pattern, not merely as a value:
    // `janet_hash` normalizes it away and the representation must not.
    assert(wrap.toNumber(wrap.fromNumber(-0.0)) == 0.0);
    assert(1.0 / wrap.toNumber(wrap.fromNumber(-0.0)) < 0.0);
}

/// A NaN is a number, not a tagged value. Under a NaN-boxed layout this is the
/// one case where the tag space and the payload space collide, and `janet_type`
/// has to answer `JANET_NUMBER` for a quiet NaN whose bits look like a tag.
///
/// The C original ran this twice, once through `janet.h`'s macros and once
/// through the functions, because the second arm of `janet_nanbox_isnumber`
/// was otherwise reachable only through the macro -- a mutation sweep said so.
/// Here the pair is the export and the inline surface; see
/// `theTwoSpellingsAgree`, which covers this value among its awkward ones.
fn nanIsANumber() void {
    const nan = std.math.nan(f64);
    const v = wrap.fromNumber(nan);
    assert(c.janet_type(v) == @intFromEnum(repr.Tag.number));
    assert(harness.isType(v, repr.Tag.number));
    assert(!harness.isType(v, repr.Tag.nil));
    assert(std.math.isNan(wrap.toNumber(v)));
    assert(repr.truthy(v));
    assert(repr.checkTypes(v, repr.TagSet.one(.number)));
    assert(c.janet_truthy(v) != 0);
    assert(c.janet_checktypes(v, repr.TagSet.one(.number).bits()) != 0);
}

/// `janet_wrap_number_safe` is the entry point unmarshalling uses for a double
/// that came off the wire, and its job is to make sure a crafted payload cannot
/// be read back as a tagged value. Under both NaN-boxed layouts it replaces any
/// NaN with the canonical quiet one; under the tagged layout it does not,
/// because there is no tag space in the double to protect. That asymmetry is in
/// the C original and is reproduced.
fn wrapNumberSafe() void {
    for ([_]f64{ 0.0, -3.25, std.math.inf(f64) }) |x| {
        assert(sameValue(wrap.fromNumberSafe(x), wrap.fromNumber(x)));
    }
    assert(c.janet_type(wrap.fromNumberSafe(std.math.nan(f64))) == @intFromEnum(repr.Tag.number));

    if (layout != .tagged) {
        // A signalling NaN with a payload in the low bits, which is what a
        // hostile marshalled double looks like.
        const hostile: f64 = @bitCast(@as(u64, 0x7FF0000000000123));
        assert(std.math.isNan(hostile));
        assert(sameValue(
            wrap.fromNumberSafe(hostile),
            wrap.fromNumberSafe(std.math.nan(f64)),
        ));
    }
}

/// `janet_unwrap_integer` truncates toward zero. Only in-range inputs are
/// checked: Janet's cast is undefined outside the destination range and the
/// two behavioural targets already disagree about it, so nothing here can be
/// asserted for both. `FOUND.md` records what this runtime does instead.
fn theIntegerConversions() void {
    assert(c.janet_unwrap_integer(wrap.fromNumber(0.0)) == 0);
    assert(c.janet_unwrap_integer(wrap.fromNumber(1.9)) == 1);
    assert(c.janet_unwrap_integer(wrap.fromNumber(-1.9)) == -1);
    assert(c.janet_unwrap_integer(wrap.fromNumber(2147483647.0)) == std.math.maxInt(i32));
    assert(c.janet_unwrap_integer(wrap.fromNumber(-2147483648.0)) == std.math.minInt(i32));

    // The inline form exists under all three layouts; the *symbol* exists
    // under two. Asserting the inline one here is what keeps the tagged build
    // covered at all, and asserting the symbol below is what pins the
    // asymmetry rather than merely tolerating it.
    assert(sameValue(wrap.fromInteger(7), wrap.fromNumber(7.0)));
    assert(sameValue(wrap.fromInteger(std.math.minInt(i32)), wrap.fromNumber(-2147483648.0)));
    assert(wrap.toInteger(wrap.fromInteger(-5)) == -5);
    assert(sameValue(wrap.fromInteger(-5), harness.wrapInteger(-5)));

    if (layout != .tagged) {
        // Not referenced under the tagged layout, where the symbol does not
        // exist. See the header and `FOUND.md`.
        assert(sameValue(c.janet_wrap_integer(7), wrap.fromNumber(7.0)));
        assert(c.janet_unwrap_integer(c.janet_wrap_integer(-5)) == -5);
        assert(c.janet_unwrap_integer(c.janet_wrap_integer(std.math.maxInt(i32))) == std.math.maxInt(i32));
    }
}

// ------------------------------------------------------- booleans and truth

/// `janet_wrap_boolean` normalizes: any non-zero argument makes the same value
/// as `janet_wrap_true`, and `janet_unwrap_boolean` answers 0 or 1 rather than
/// whatever went in.
fn booleansNormalize() void {
    assert(sameValue(c.janet_wrap_boolean(1), c.janet_wrap_true()));
    assert(sameValue(c.janet_wrap_boolean(2), c.janet_wrap_true()));
    assert(sameValue(c.janet_wrap_boolean(-1), c.janet_wrap_true()));
    assert(sameValue(c.janet_wrap_boolean(0), c.janet_wrap_false()));
    assert(wrap.toBoolean(c.janet_wrap_true()));
    assert(!wrap.toBoolean(c.janet_wrap_false()));
    assert(wrap.toBoolean(c.janet_wrap_boolean(37)));
}

/// Exactly two values are false, and everything else is true -- including zero,
/// the empty string and an empty array, which is the difference between Janet's
/// truthiness and C's.
fn truthiness() void {
    assert(!repr.truthy(c.janet_wrap_nil()));
    assert(!repr.truthy(c.janet_wrap_false()));
    assert(!repr.truthy(c.janet_wrap_boolean(0)));
    assert(repr.truthy(c.janet_wrap_true()));
    assert(repr.truthy(c.janet_wrap_boolean(1)));
    assert(repr.truthy(wrap.fromNumber(0.0)));
    assert(repr.truthy(wrap.fromNumber(std.math.nan(f64))));
    assert(repr.truthy(c.janet_wrap_string(strings.cstring(""))));
    assert(repr.truthy(c.janet_wrap_array(c.janet_array(0))));
    assert(repr.truthy(c.janet_wrap_pointer(null)));
}

// ------------------------------------------------- checktype and checktypes

/// One value of each type, in tag order, so the matrix below can be written as
/// a loop rather than as a hundred and sixty-nine assertions.
fn buildOneOfEach(out: *[repr.tag_count]repr.Value) void {
    out[at(.number)] = wrap.fromNumber(2.5);
    out[at(.nil)] = c.janet_wrap_nil();
    out[at(.boolean)] = c.janet_wrap_true();
    out[at(.fiber)] = c.janet_wrap_fiber(@ptrCast(@alignCast(pointerA())));
    out[at(.string)] = c.janet_wrap_string(strings.cstring("s"));
    out[at(.symbol)] = c.janet_wrap_symbol(symbols.csymbol("s"));
    out[at(.keyword)] = c.janet_wrap_keyword(symbols.csymbol("s"));
    out[at(.array)] = c.janet_wrap_array(c.janet_array(0));
    out[at(.tuple)] = c.janet_wrap_tuple(tuples.newFrom(&.{}));
    out[at(.table)] = c.janet_wrap_table(c.janet_table(0));
    out[at(.@"struct")] = c.janet_wrap_struct(structs.end(structs.begin(0)));
    out[at(.buffer)] = c.janet_wrap_buffer(c.janet_buffer(0));
    out[at(.function)] = c.janet_wrap_function(@ptrCast(@alignCast(pointerA())));
    out[at(.cfunction)] = c.janet_wrap_cfunction(theCFunction());
    out[at(.abstract)] = c.janet_wrap_abstract(pointerB());
    out[at(.pointer)] = c.janet_wrap_pointer(pointerB());
}

/// `janet_checktype` agrees with `janet_type` for every value against every
/// type, and it is the full matrix rather than the diagonal: under a NaN-boxed
/// layout the number case is tested differently from the rest, so a wrong
/// answer is as likely to be a false positive as a false negative.
fn theCheckTypeMatrix() void {
    var values: [repr.tag_count]repr.Value = undefined;
    buildOneOfEach(&values);
    for (values, 0..) |value, i| {
        for (0..repr.tag_count) |j| {
            assert(harness.isType(value, typeAt(j)) == (i == j));
        }
        assert(c.janet_type(value) == @intFromEnum(typeAt(i)));
    }
}

/// `janet_checktypes` is the type as a bit in a mask, and the *exported* form
/// answers the masked bit rather than a normalized boolean -- Janet's
/// contract, kept when the internal one became `bool`, so both halves are
/// asserted here and the bit is asserted only of the symbol.
fn checkTypes() void {
    var values: [repr.tag_count]repr.Value = undefined;
    buildOneOfEach(&values);
    for (values, 0..) |value, i| {
        const tag: repr.Tag = @enumFromInt(i);
        const set = repr.TagSet.one(tag);
        const bit = @as(c_int, set.bits());
        assert(repr.checkTypes(value, set));
        assert(!repr.checkTypes(value, repr.TagSet.fromBits(~set.bits())));
        assert(repr.checkTypes(value, repr.TagSet.all));
        assert(!repr.checkTypes(value, repr.TagSet.none));
        // The exported symbol still takes and answers an `int`, and answers
        // the masked bit rather than a boolean. `-1` is a caller's `~0`, whose
        // bits above fifteen name no tag.
        assert(c.janet_checktypes(value, bit) == bit);
        assert(c.janet_checktypes(value, ~bit) == 0);
        assert(c.janet_checktypes(value, -1) == bit);
        assert(c.janet_checktypes(value, 0) == 0);
    }
    assert(repr.checkTypes(values[at(.string)], repr.TagSet.bytes));
    assert(repr.checkTypes(values[at(.symbol)], repr.TagSet.bytes));
    assert(repr.checkTypes(values[at(.keyword)], repr.TagSet.bytes));
    assert(repr.checkTypes(values[at(.buffer)], repr.TagSet.bytes));
    assert(!repr.checkTypes(values[at(.array)], repr.TagSet.bytes));
}

// --------------------------------------------- the two spellings agree

/// Every predicate with both an internal and an exported form, checked
/// against each other for one value. Factored out because the set of values
/// that matters is larger than one per type -- see the call site.
///
/// **Both sides are spelled here rather than borrowed.** These read
/// `c.janet_*` directly instead of `harness.isType`, and that is the whole
/// point of the function: a harness helper that pointed at the internal
/// spelling would turn every comparison here into a function against itself.
fn agreeOn(v: repr.Value) void {
    assert(repr.truthy(v) == (c.janet_truthy(v) != 0));
    for (0..repr.tag_count) |j| {
        assert(repr.checkType(v, typeAt(j)) == (c.janet_checktype(v, @intCast(j)) != 0));
        const set = repr.TagSet.one(typeAt(j));
        const bit = @as(c_int, set.bits());
        assert(repr.checkTypes(v, set) == (c.janet_checktypes(v, bit) != 0));
    }
    assert(repr.checkTypes(v, repr.TagSet.all) == (c.janet_checktypes(v, -1) != 0));
    assert(repr.checkTypes(v, repr.TagSet.none) == (c.janet_checktypes(v, 0) != 0));
}

/// The channel the C original had as macro-against-function, restated as
/// inline-against-export. See the header for why the two are not the same
/// question and why this one is the closest replacement available.
fn theTwoSpellingsAgree() void {
    var values: [repr.tag_count]repr.Value = undefined;
    buildOneOfEach(&values);
    const p = pointerA();

    // The constructors. Each inline declaration is the body of the identically
    // named export, so a disagreement means one of the two was wired to the
    // wrong helper -- which is exactly what the C channel could catch and no
    // more.
    assert(sameValue(wrap.fromNil(), c.janet_wrap_nil()));
    assert(sameValue(wrap.fromTrue(), c.janet_wrap_true()));
    assert(sameValue(wrap.fromFalse(), c.janet_wrap_false()));
    assert(sameValue(wrap.fromBoolean(true), c.janet_wrap_boolean(3)));
    assert(sameValue(wrap.fromBoolean(false), c.janet_wrap_boolean(0)));
    assert(sameValue(wrap.fromNumber(2.5), wrap.fromNumber(2.5)));
    assert(sameValue(wrap.fromArray(@ptrCast(@alignCast(p))), c.janet_wrap_array(@ptrCast(@alignCast(p)))));
    assert(sameValue(wrap.fromTable(@ptrCast(@alignCast(p))), c.janet_wrap_table(@ptrCast(@alignCast(p)))));
    assert(sameValue(wrap.fromBuffer(@ptrCast(@alignCast(p))), c.janet_wrap_buffer(@ptrCast(@alignCast(p)))));
    assert(sameValue(wrap.fromFunction(@ptrCast(@alignCast(p))), c.janet_wrap_function(@ptrCast(@alignCast(p)))));
    assert(sameValue(wrap.fromStruct(@ptrCast(@alignCast(p))), c.janet_wrap_struct(@ptrCast(@alignCast(p)))));
    assert(sameValue(wrap.fromTuple(@ptrCast(@alignCast(p))), c.janet_wrap_tuple(@ptrCast(@alignCast(p)))));

    // The predicates, over one value per type...
    for (values) |value| agreeOn(value);

    // ...and then over the values that take the *other* arm of each. One value
    // per type is not enough, and a mutation sweep against the C original is
    // what said so: `buildOneOfEach` samples `2.5` and `true`, which take the
    // ordinary arm of every predicate. A NaN's type nibble under a NaN-boxed
    // layout reads as `JANET_NUMBER`, so it is recognized by the second half of
    // `isNumber` rather than the first; `false` is the only value whose
    // truthiness depends on the payload rather than on the tag.
    const awkward = [_]repr.Value{
        wrap.fromNumber(std.math.nan(f64)),
        wrap.fromNumber(std.math.inf(f64)),
        wrap.fromNumber(-std.math.inf(f64)),
        wrap.fromNumber(0.0),
        wrap.fromNumber(-0.0),
        c.janet_wrap_false(),
        c.janet_wrap_boolean(0),
        c.janet_wrap_boolean(3),
        c.janet_wrap_pointer(null),
    };
    for (awkward) |value| agreeOn(value);

    // The accessors.
    assert(wrap.toInteger(wrap.fromNumber(-9.5)) == c.janet_unwrap_integer(wrap.fromNumber(-9.5)));
    assert(wrap.toFunction(values[at(.function)]) == c.janet_unwrap_function(values[at(.function)]));
    assert(wrap.toBoolean(values[at(.boolean)]) == (c.janet_unwrap_boolean(values[at(.boolean)]) != 0));
}

// ------------------------------------------------------ the exact bit layout

/// The assertions that say this is *the* representation rather than a working
/// one. Each is computed from `janet.h`'s own constants and none of them goes
/// through an implementation of the thing under test.
///
/// One per layout, selected below. Zig analyses only the body it is handed, so
/// the two that do not apply are never compiled -- which they could not be:
/// `janet.h` declares each layout's nanbox helpers only under that layout's
/// `#ifdef`, so the symbols the other two name do not exist here.
fn exactLayoutNanbox64() void {
    const p = pointerA();
    const nil_tag: u64 = (@as(u64, @intFromEnum(repr.Tag.nil)) | 0x1FFF0) << 47;
    const bool_tag: u64 = (@as(u64, @intFromEnum(repr.Tag.boolean)) | 0x1FFF0) << 47;
    const array_tag: u64 = (@as(u64, @intFromEnum(repr.Tag.array)) | 0x1FFF0) << 47;

    // The three immediate values are a tag with a one-bit payload.
    assert(harness.u64Of(c.janet_wrap_nil()) == (nil_tag | 1));
    assert(harness.u64Of(c.janet_wrap_true()) == (bool_tag | 1));
    assert(harness.u64Of(c.janet_wrap_false()) == bool_tag);

    // A double is stored unchanged.
    const bits: u64 = @bitCast(@as(f64, 1.5));
    assert(harness.u64Of(wrap.fromNumber(1.5)) == bits);
    assert(harness.u64Of(c.janet_nanbox_from_double(1.5)) == bits);
    assert(harness.u64Of(c.janet_nanbox_from_bits(bits)) == bits);

    // A pointer is shifted right by the alignment shift and then tagged, and
    // the payload bits are the only ones it may occupy.
    const word = harness.u64Of(c.janet_wrap_array(@ptrCast(@alignCast(p))));
    assert((word & repr.tagbits) == array_tag);
    assert((word & repr.payloadbits) ==
        (@as(u64, @intFromPtr(p)) >> repr.pointer_shift));
    assert(c.janet_nanbox_to_pointer(c.janet_nanbox_from_pointer(p, array_tag)) == p);
    assert(c.janet_nanbox_to_pointer(c.janet_nanbox_from_cpointer(p, array_tag)) == p);
    assert(harness.u64Of(c.janet_nanbox_from_pointer(p, array_tag)) == word);

    // The canonical NaN is what `janet_wrap_number_safe` stores, and it is not
    // mistaken for a tagged value.
    const canonical: u64 = @bitCast(wrap.toNumber(wrap.fromNumberSafe(std.math.nan(f64))));
    assert(c.janet_type(wrap.fromNumberSafe(std.math.nan(f64))) == @intFromEnum(repr.Tag.number));
    assert((canonical & repr.payloadbits) == 0);
}

fn exactLayoutNanbox32() void {
    const p = pointerA();

    // Every non-number tag is stored raw in the high word, below the offset
    // that biases a double's exponent out of the way.
    assert(c.janet_wrap_nil().tagged.type == @as(u32, @intFromEnum(repr.Tag.nil)));
    assert(c.janet_wrap_nil().tagged.payload.integer == 0);
    assert(c.janet_wrap_true().tagged.type == @as(u32, @intFromEnum(repr.Tag.boolean)));
    assert(c.janet_wrap_true().tagged.payload.integer == 1);
    assert(c.janet_wrap_false().tagged.payload.integer == 0);
    assert(c.janet_wrap_array(@ptrCast(@alignCast(p))).tagged.type == @as(u32, @intFromEnum(repr.Tag.array)));
    assert(c.janet_wrap_array(@ptrCast(@alignCast(p))).tagged.payload.pointer == p);
    assert(@as(u32, @intFromEnum(repr.Tag.pointer)) < @as(u32, repr.double_offset));

    // A double is biased by `repr.double_offset` in its high word, which is
    // what keeps every number above every tag.
    const bits: u64 = @bitCast(@as(f64, 1.5));
    assert(harness.u64Of(wrap.fromNumber(1.5)) == bits +% (@as(u64, repr.double_offset) << 32));
    assert(wrap.toNumber(wrap.fromNumber(1.5)) == 1.5);

    assert(c.janet_nanbox32_from_tagi(@as(u32, @intFromEnum(repr.Tag.boolean)), 1).tagged.payload.integer == 1);
    assert(c.janet_nanbox32_from_tagp(@as(u32, @intFromEnum(repr.Tag.array)), p).tagged.payload.pointer == p);
    assert(c.janet_nanbox32_from_tagp(@as(u32, @intFromEnum(repr.Tag.array)), p).tagged.type == @as(u32, @intFromEnum(repr.Tag.array)));

    const canonical: u64 = @bitCast(wrap.toNumber(wrap.fromNumberSafe(std.math.nan(f64))));
    assert((canonical & 0x000FFFFFFFFFFFFF) == 0x0008000000000000);
}

fn exactLayoutTagged() void {
    const p = pointerA();

    // The tag is a field of its own, and the payload union is zeroed before
    // the narrower member is written -- which is what the `as.u64 = 0` in
    // `JANET_WRAP_DEFINE` is for, and the only way to see it is through a
    // member narrower than the union.
    assert(c.janet_wrap_nil().type == @intFromEnum(repr.Tag.nil));
    assert(harness.u64Of(c.janet_wrap_nil()) == 0);
    assert(c.janet_wrap_true().type == @intFromEnum(repr.Tag.boolean));
    assert(harness.u64Of(c.janet_wrap_true()) == 1);
    assert(harness.u64Of(c.janet_wrap_false()) == 0);
    assert(c.janet_wrap_array(@ptrCast(@alignCast(p))).type == @intFromEnum(repr.Tag.array));
    assert(harness.u64Of(c.janet_wrap_array(@ptrCast(@alignCast(p)))) == @as(u64, @intFromPtr(p)));
    assert(harness.u64Of(c.janet_wrap_pointer(null)) == 0);

    assert(harness.u64Of(wrap.fromNumber(1.5)) == @as(u64, @bitCast(@as(f64, 1.5))));

    // The one layout that does not canonicalize a NaN, because it has no tag
    // space in the double to protect. `FOUND.md` has the asymmetry.
    const hostile: u64 = 0x7FF0000000000123;
    assert(harness.u64Of(wrap.fromNumberSafe(@bitCast(hostile))) == hostile);
}

const exactLayout = switch (layout) {
    .nanbox64 => exactLayoutNanbox64,
    .nanbox32 => exactLayoutNanbox32,
    .tagged => exactLayoutTagged,
};

// ------------------------------------------------------ empty bucket arrays

/// `janet_memalloc_empty` is the allocator every dictionary's bucket array
/// comes from. Three things are its contract: the block is `count` pairs long,
/// every pair is nil/nil, and the collection budget is charged for the bytes.
/// The charge is what only this case sees -- `janet_gcalloc` bills its own
/// blocks and this one is a plain `janet_malloc`.
fn memallocEmpty() void {
    for ([_]i32{ 1, 8, 257 }) |n| {
        const before = harness.vm().gc.next_collection;
        const kvs: ?[*]types.JanetKV = @ptrCast(@alignCast(internal.janet_memalloc_empty(n)));
        // Reaching this line is the null check: the failure path exits.
        assert(kvs != null);
        assert(harness.vm().gc.next_collection - before == @as(usize, @intCast(n)) * @sizeOf(types.JanetKV));
        var i: i32 = 0;
        while (i < n) : (i += 1) {
            assert(harness.isType(kvs.?[@intCast(i)].key, repr.Tag.nil));
            assert(harness.isType(kvs.?[@intCast(i)].value, repr.Tag.nil));
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
    const mem = internal.janet_memalloc_empty(0);
    assert(harness.vm().gc.next_collection == before);
    utils.free(mem);
}

/// `janet_memempty` clears a block the caller already owns. The block is
/// dirtied first with values of a type that is not nil under every layout, so a
/// fill that did nothing at all would be caught rather than passing on whatever
/// the allocator happened to leave.
fn mememptyClearsADirtyBlock() void {
    const n = 16;
    const kvs: [*]types.JanetKV = @ptrCast(@alignCast(internal.janet_memalloc_empty(n)));
    defer utils.free(kvs);

    for (0..n) |i| {
        kvs[i].key = harness.wrapInteger(@intCast(i + 1));
        kvs[i].value = c.janet_wrap_boolean(1);
        assert(!harness.isType(kvs[i].key, repr.Tag.nil));
        assert(!harness.isType(kvs[i].value, repr.Tag.nil));
    }

    internal.janet_memempty(kvs, n);
    for (0..n) |i| {
        assert(harness.isType(kvs[i].key, repr.Tag.nil));
        assert(harness.isType(kvs[i].value, repr.Tag.nil));
        assert(sameValue(kvs[i].key, c.janet_wrap_nil()));
        assert(sameValue(kvs[i].value, c.janet_wrap_nil()));
    }

    // A zero count leaves the block alone rather than clearing one pair.
    kvs[0].key = c.janet_wrap_boolean(1);
    internal.janet_memempty(kvs, 0);
    assert(harness.isType(kvs[0].key, repr.Tag.boolean));
}

// -------------------------------------------------------------- collection

/// Values built by these wrappers are what the collector traverses, so the last
/// case is that a heap object reached only through a wrapped value survives a
/// collection while rooted and is freed once it is not.
fn repeatedCycles() void {
    var i: i32 = 0;
    while (i < 64) : (i += 1) {
        const array = c.janet_wrap_array(c.janet_array(4));
        const table = c.janet_wrap_table(c.janet_table(4));
        const buffer = c.janet_wrap_buffer(c.janet_buffer(4));
        const string = c.janet_wrap_string(strings.cstring("cycle"));
        harness.arrayPush(wrap.toArray(array), string);
        tables.put(wrap.toTable(table), harness.wrapInteger(i), buffer);
        gc_alloc.gcroot(array);
        gc_alloc.gcroot(table);
        gc_mark.collect();
        assert(c.janet_type(array) == @intFromEnum(repr.Tag.array));
        assert(wrap.toArray(array).*.count == 1);
        assert(sameValue(wrap.toArray(array).slice()[0], string));
        assert(sameValue(
            tables.get(wrap.toTable(table), harness.wrapInteger(i)),
            buffer,
        ));
        _ = gc_alloc.gcunroot(table);
        _ = gc_alloc.gcunroot(array);
        gc_mark.collect();
    }
}

// ------------------------------------------------------------------- main

pub fn run() void {
    harness.init();
    defer c.janet_deinit();

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

    std.debug.print("value wrap contract ok\n", .{});
}
