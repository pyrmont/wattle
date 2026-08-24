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
//! ## The oracle that did not survive the migration, and what replaced it
//!
//! The C original had a third channel available here and nowhere else.
//! `wrap.c` exists to provide a *function* form of what `janet.h` provides as
//! a *macro*, so for every entry point with both, the two spellings had to
//! agree — and C's rule that a parenthesised name is not macro-expanded is
//! what let one file call both.
//!
//! **A Zig contract cannot reach the macro.** `janet.h` declares
//! `janet_checktype`, `janet_truthy`, `janet_wrap_integer` and their kin as
//! functions *beside* macros of the same name; `@cImport` prefers the
//! function, which is `test/harness.zig`'s `wrapInteger` note from the other
//! direction. So the C spelling `(janet_truthy)(v)` and the spelling
//! `janet_truthy(v)` are one thing here, and asserting they agree would be a
//! case that cannot fail — Part 3's rule 8 exactly.
//!
//! Rules 20 and 24 say to ask what the two sides of the original comparison
//! were and then to look for a replacement that already exists. The two sides
//! were *the operation a caller gets inlined* and *the operation the library
//! exports*, and this runtime has that same pair: `value_wrap.zig`'s `ops`
//! namespace is what `vm_run.zig` reaches for — measured at +89% on the
//! arithmetic workload when it went through the symbol table instead — and the
//! `export fn`s beside it are what everything else calls. Twenty-one
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
//! `port/FOUND.md` has the case. The layout is read off the shape of the
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
//! such symbol and naming it would fail to link. The `ops` form exists under
//! all three, which is itself worth asserting -- see `theIntegerConversions`.

const std = @import("std");
const abi = @import("abi");
const c = abi.c;
const raise = @import("raise");
const harness = @import("harness.zig");
const corefn = @import("corefn");

const ops = @import("subsystems").value_wrap.ops;
const internal = harness.internal;
const assert = std.debug.assert;

// ------------------------------------------------------------------ layout

const Layout = enum { nanbox64, nanbox32, tagged };

/// Which of `janet.h`'s three representations this build compiled with, read
/// off the translated type. See the header for why it is not the `#ifdef`
/// chain, and `value_wrap.zig` for the same three lines with the same reason.
const layout: Layout = if (@hasField(c.Janet, "as"))
    .tagged
else if (@hasField(c.Janet, "tagged"))
    .nanbox32
else
    .nanbox64;

// ----------------------------------------------------------------- helpers

/// Two values are the same value when their payload word and their type agree.
/// `std.mem.eql` over the bytes would be wrong under the tagged layout, whose
/// `Janet` is twelve bytes of content in a sixteen-byte structure: neither
/// implementation writes the padding, and neither is required to.
fn sameValue(a: c.Janet, b: c.Janet) bool {
    return harness.u64Of(a) == harness.u64Of(b) and c.janet_type(a) == c.janet_type(b);
}

/// A cfunction to wrap. Its address is the only function pointer in the file,
/// and under a pointer-shifted NaN-box it has to satisfy the same alignment
/// every registered cfunction does -- which is what `corefn.alignment` is.
fn aCFunction(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    _ = argc;
    _ = argv;
    return c.janet_wrap_nil();
}

fn theCFunction() c.JanetCFunction {
    return raise.stored(&aCFunction);
}

/// Sixteen-byte-aligned storage, so the addresses handed to the pointer
/// wrappers are legal under every value of `JANET_NANBOX_64_POINTER_SHIFT`,
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

fn typeAt(index: usize) c.JanetType {
    return @intCast(index);
}

// -------------------------------------------------- type tags and round trips

/// Every wrapper stamps its own type, and `janet_type` reads it back. This is
/// the whole of the representation's job stated once. The pointers are not
/// dereferenced by anything here: a wrapper stores an address and a tag, and
/// whether the address points at a real object is the collector's problem.
fn eachWrapperStampsItsType() void {
    const p = pointerA();
    assert(c.janet_type(c.janet_wrap_nil()) == c.JANET_NIL);
    assert(c.janet_type(c.janet_wrap_true()) == c.JANET_BOOLEAN);
    assert(c.janet_type(c.janet_wrap_false()) == c.JANET_BOOLEAN);
    assert(c.janet_type(c.janet_wrap_boolean(1)) == c.JANET_BOOLEAN);
    assert(c.janet_type(c.janet_wrap_number(1.5)) == c.JANET_NUMBER);
    assert(c.janet_type(c.janet_wrap_string(@ptrCast(p))) == c.JANET_STRING);
    assert(c.janet_type(c.janet_wrap_symbol(@ptrCast(p))) == c.JANET_SYMBOL);
    assert(c.janet_type(c.janet_wrap_keyword(@ptrCast(p))) == c.JANET_KEYWORD);
    assert(c.janet_type(c.janet_wrap_array(@ptrCast(@alignCast(p)))) == c.JANET_ARRAY);
    assert(c.janet_type(c.janet_wrap_tuple(@ptrCast(@alignCast(p)))) == c.JANET_TUPLE);
    assert(c.janet_type(c.janet_wrap_struct(@ptrCast(@alignCast(p)))) == c.JANET_STRUCT);
    assert(c.janet_type(c.janet_wrap_fiber(@ptrCast(@alignCast(p)))) == c.JANET_FIBER);
    assert(c.janet_type(c.janet_wrap_buffer(@ptrCast(@alignCast(p)))) == c.JANET_BUFFER);
    assert(c.janet_type(c.janet_wrap_function(@ptrCast(@alignCast(p)))) == c.JANET_FUNCTION);
    assert(c.janet_type(c.janet_wrap_cfunction(theCFunction())) == c.JANET_CFUNCTION);
    assert(c.janet_type(c.janet_wrap_table(@ptrCast(@alignCast(p)))) == c.JANET_TABLE);
    assert(c.janet_type(c.janet_wrap_abstract(p)) == c.JANET_ABSTRACT);
    assert(c.janet_type(c.janet_wrap_pointer(p)) == c.JANET_POINTER);
}

/// Every pointer wrapper round trips through its own unwrapper, for three
/// addresses: two static blocks and one from the allocator, which is the only
/// one whose value is not known at link time. Sixteen-byte aligned, which is
/// what the pointer wrappers require -- a NaN-boxed 64-bit build discards the
/// low bits on every target that nanboxes.
fn pointerRoundTrips() void {
    const heap_block = c.janet_malloc(64);
    assert(heap_block != null);
    defer c.janet_free(heap_block);

    for ([_]?*anyopaque{ pointerA(), pointerB(), heap_block }) |p| {
        assert(c.janet_unwrap_string(c.janet_wrap_string(@ptrCast(p))) == @as(c.JanetString, @ptrCast(p)));
        assert(c.janet_unwrap_symbol(c.janet_wrap_symbol(@ptrCast(p))) == @as(c.JanetSymbol, @ptrCast(p)));
        assert(c.janet_unwrap_keyword(c.janet_wrap_keyword(@ptrCast(p))) == @as(c.JanetKeyword, @ptrCast(p)));
        assert(c.janet_unwrap_array(c.janet_wrap_array(@ptrCast(@alignCast(p)))) == @as([*c]c.JanetArray, @ptrCast(@alignCast(p))));
        assert(c.janet_unwrap_tuple(c.janet_wrap_tuple(@ptrCast(@alignCast(p)))) == @as(c.JanetTuple, @ptrCast(@alignCast(p))));
        assert(c.janet_unwrap_struct(c.janet_wrap_struct(@ptrCast(@alignCast(p)))) == @as(c.JanetStruct, @ptrCast(@alignCast(p))));
        assert(c.janet_unwrap_fiber(c.janet_wrap_fiber(@ptrCast(@alignCast(p)))) == @as([*c]c.JanetFiber, @ptrCast(@alignCast(p))));
        assert(c.janet_unwrap_buffer(c.janet_wrap_buffer(@ptrCast(@alignCast(p)))) == @as([*c]c.JanetBuffer, @ptrCast(@alignCast(p))));
        assert(c.janet_unwrap_function(c.janet_wrap_function(@ptrCast(@alignCast(p)))) == @as([*c]c.JanetFunction, @ptrCast(@alignCast(p))));
        assert(c.janet_unwrap_table(c.janet_wrap_table(@ptrCast(@alignCast(p)))) == @as([*c]c.JanetTable, @ptrCast(@alignCast(p))));
        assert(c.janet_unwrap_abstract(c.janet_wrap_abstract(p)) == p);
        assert(c.janet_unwrap_pointer(c.janet_wrap_pointer(p)) == p);
    }
    assert(c.janet_unwrap_cfunction(c.janet_wrap_cfunction(theCFunction())) == theCFunction());
}

/// A null payload is a legal value for every pointer type -- `janet_wrap_fiber`
/// is called with one every time a fiber has no child. It must not be confused
/// with nil, and it must come back null.
fn nullPayloadsRoundTrip() void {
    assert(c.janet_unwrap_fiber(c.janet_wrap_fiber(null)) == null);
    assert(c.janet_unwrap_pointer(c.janet_wrap_pointer(null)) == null);
    assert(c.janet_unwrap_abstract(c.janet_wrap_abstract(null)) == null);
    assert(c.janet_type(c.janet_wrap_fiber(null)) == c.JANET_FIBER);
    assert(!harness.isType(c.janet_wrap_pointer(null), c.JANET_NIL));

    assert(c.janet_truthy(c.janet_wrap_pointer(null)) != 0);
    assert(c.janet_truthy(c.janet_wrap_nil()) == 0);
    assert(c.janet_truthy(c.janet_wrap_false()) == 0);
    assert(c.janet_truthy(c.janet_wrap_boolean(0)) == 0);
    assert(c.janet_truthy(c.janet_wrap_true()) != 0);
    assert(c.janet_truthy(c.janet_wrap_boolean(1)) != 0);
    assert(c.janet_truthy(c.janet_wrap_number(0.0)) != 0);
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
        const v = c.janet_wrap_number(x);
        assert(c.janet_type(v) == c.JANET_NUMBER);
        assert(harness.isType(v, c.JANET_NUMBER));
        assert(c.janet_unwrap_number(v) == x);
    }
    // Negative zero is preserved as a bit pattern, not merely as a value:
    // `janet_hash` normalizes it away and the representation must not.
    assert(c.janet_unwrap_number(c.janet_wrap_number(-0.0)) == 0.0);
    assert(1.0 / c.janet_unwrap_number(c.janet_wrap_number(-0.0)) < 0.0);
}

/// A NaN is a number, not a tagged value. Under a NaN-boxed layout this is the
/// one case where the tag space and the payload space collide, and `janet_type`
/// has to answer `JANET_NUMBER` for a quiet NaN whose bits look like a tag.
///
/// The C original ran this twice, once through `janet.h`'s macros and once
/// through the functions, because the second arm of `janet_nanbox_isnumber`
/// was otherwise reachable only through the macro -- a mutation sweep said so.
/// Here the pair is the export and `ops`; see `theTwoSpellingsAgree`, which
/// covers this value among its awkward ones.
fn nanIsANumber() void {
    const nan = std.math.nan(f64);
    const v = c.janet_wrap_number(nan);
    assert(c.janet_type(v) == c.JANET_NUMBER);
    assert(harness.isType(v, c.JANET_NUMBER));
    assert(!harness.isType(v, c.JANET_NIL));
    assert(std.math.isNan(c.janet_unwrap_number(v)));
    assert(c.janet_truthy(v) != 0);
    assert(c.janet_checktypes(v, c.JANET_TFLAG_NUMBER) != 0);

    assert(ops.isNumber(v));
    assert(ops.checkType(v, @intCast(c.JANET_NUMBER)));
    assert(!ops.checkType(v, @intCast(c.JANET_NIL)));
    assert(ops.truthy(v));
    assert(ops.checkTypes(v, c.JANET_TFLAG_NUMBER));
}

/// `janet_wrap_number_safe` is the entry point unmarshalling uses for a double
/// that came off the wire, and its job is to make sure a crafted payload cannot
/// be read back as a tagged value. Under both NaN-boxed layouts it replaces any
/// NaN with the canonical quiet one; under the tagged layout it does not,
/// because there is no tag space in the double to protect. That asymmetry is in
/// the C original and is reproduced.
fn wrapNumberSafe() void {
    for ([_]f64{ 0.0, -3.25, std.math.inf(f64) }) |x| {
        assert(sameValue(c.janet_wrap_number_safe(x), c.janet_wrap_number(x)));
    }
    assert(c.janet_type(c.janet_wrap_number_safe(std.math.nan(f64))) == c.JANET_NUMBER);

    if (layout != .tagged) {
        // A signalling NaN with a payload in the low bits, which is what a
        // hostile marshalled double looks like.
        const hostile: f64 = @bitCast(@as(u64, 0x7FF0000000000123));
        assert(std.math.isNan(hostile));
        assert(sameValue(
            c.janet_wrap_number_safe(hostile),
            c.janet_wrap_number_safe(std.math.nan(f64)),
        ));
    }
}

/// `janet_unwrap_integer` truncates toward zero. Only in-range inputs are
/// checked: the C original's cast is undefined outside the destination range
/// and the two behavioural targets already disagree about it, so nothing here
/// can be asserted for both. `FOUND.md` records what the port does instead.
fn theIntegerConversions() void {
    assert(c.janet_unwrap_integer(c.janet_wrap_number(0.0)) == 0);
    assert(c.janet_unwrap_integer(c.janet_wrap_number(1.9)) == 1);
    assert(c.janet_unwrap_integer(c.janet_wrap_number(-1.9)) == -1);
    assert(c.janet_unwrap_integer(c.janet_wrap_number(2147483647.0)) == std.math.maxInt(i32));
    assert(c.janet_unwrap_integer(c.janet_wrap_number(-2147483648.0)) == std.math.minInt(i32));

    // The inline form exists under all three layouts; the *symbol* exists
    // under two. Asserting the inline one here is what keeps the tagged build
    // covered at all, and asserting the symbol below is what pins the
    // asymmetry rather than merely tolerating it.
    assert(sameValue(ops.wrapInteger(7), c.janet_wrap_number(7.0)));
    assert(sameValue(ops.wrapInteger(std.math.minInt(i32)), c.janet_wrap_number(-2147483648.0)));
    assert(ops.unwrapInteger(ops.wrapInteger(-5)) == -5);
    assert(sameValue(ops.wrapInteger(-5), harness.wrapInteger(-5)));

    if (layout != .tagged) {
        // Not referenced under the tagged layout, where the symbol does not
        // exist. See the header and `FOUND.md`.
        assert(sameValue(c.janet_wrap_integer(7), c.janet_wrap_number(7.0)));
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
    assert(c.janet_unwrap_boolean(c.janet_wrap_true()) == 1);
    assert(c.janet_unwrap_boolean(c.janet_wrap_false()) == 0);
    assert(c.janet_unwrap_boolean(c.janet_wrap_boolean(37)) == 1);
}

/// Exactly two values are false, and everything else is true -- including zero,
/// the empty string and an empty array, which is the difference between Janet's
/// truthiness and C's.
fn truthiness() void {
    assert(c.janet_truthy(c.janet_wrap_nil()) == 0);
    assert(c.janet_truthy(c.janet_wrap_false()) == 0);
    assert(c.janet_truthy(c.janet_wrap_boolean(0)) == 0);
    assert(c.janet_truthy(c.janet_wrap_true()) != 0);
    assert(c.janet_truthy(c.janet_wrap_boolean(1)) != 0);
    assert(c.janet_truthy(c.janet_wrap_number(0.0)) != 0);
    assert(c.janet_truthy(c.janet_wrap_number(std.math.nan(f64))) != 0);
    assert(c.janet_truthy(c.janet_wrap_string(c.janet_cstring(""))) != 0);
    assert(c.janet_truthy(c.janet_wrap_array(c.janet_array(0))) != 0);
    assert(c.janet_truthy(c.janet_wrap_pointer(null)) != 0);
}

// ------------------------------------------------- checktype and checktypes

/// One value of each type, in tag order, so the matrix below can be written as
/// a loop rather than as a hundred and sixty-nine assertions.
fn buildOneOfEach(out: *[c.JANET_COUNT_TYPES]c.Janet) void {
    out[c.JANET_NUMBER] = c.janet_wrap_number(2.5);
    out[c.JANET_NIL] = c.janet_wrap_nil();
    out[c.JANET_BOOLEAN] = c.janet_wrap_true();
    out[c.JANET_FIBER] = c.janet_wrap_fiber(@ptrCast(@alignCast(pointerA())));
    out[c.JANET_STRING] = c.janet_wrap_string(c.janet_cstring("s"));
    out[c.JANET_SYMBOL] = c.janet_wrap_symbol(c.janet_csymbol("s"));
    out[c.JANET_KEYWORD] = c.janet_wrap_keyword(c.janet_ckeyword("s"));
    out[c.JANET_ARRAY] = c.janet_wrap_array(c.janet_array(0));
    out[c.JANET_TUPLE] = c.janet_wrap_tuple(c.janet_tuple_n(null, 0));
    out[c.JANET_TABLE] = c.janet_wrap_table(c.janet_table(0));
    out[c.JANET_STRUCT] = c.janet_wrap_struct(c.janet_struct_end(c.janet_struct_begin(0)));
    out[c.JANET_BUFFER] = c.janet_wrap_buffer(c.janet_buffer(0));
    out[c.JANET_FUNCTION] = c.janet_wrap_function(@ptrCast(@alignCast(pointerA())));
    out[c.JANET_CFUNCTION] = c.janet_wrap_cfunction(theCFunction());
    out[c.JANET_ABSTRACT] = c.janet_wrap_abstract(pointerB());
    out[c.JANET_POINTER] = c.janet_wrap_pointer(pointerB());
}

/// `janet_checktype` agrees with `janet_type` for every value against every
/// type, and it is the full matrix rather than the diagonal: under a NaN-boxed
/// layout the number case is tested differently from the rest, so a wrong
/// answer is as likely to be a false positive as a false negative.
fn theCheckTypeMatrix() void {
    var values: [c.JANET_COUNT_TYPES]c.Janet = undefined;
    buildOneOfEach(&values);
    for (values, 0..) |value, i| {
        for (0..c.JANET_COUNT_TYPES) |j| {
            assert(harness.isType(value, typeAt(j)) == (i == j));
        }
        assert(c.janet_type(value) == typeAt(i));
    }
}

/// `janet_checktypes` is the type as a bit in a mask, and it returns the masked
/// bit rather than a normalized boolean -- which is why every caller in the
/// tree tests it against zero.
fn checkTypes() void {
    var values: [c.JANET_COUNT_TYPES]c.Janet = undefined;
    buildOneOfEach(&values);
    for (values, 0..) |value, i| {
        const bit = @as(c_int, 1) << @intCast(i);
        assert(c.janet_checktypes(value, bit) == bit);
        assert(c.janet_checktypes(value, ~bit) == 0);
        assert(c.janet_checktypes(value, -1) == bit);
        assert(c.janet_checktypes(value, 0) == 0);
    }
    assert(c.janet_checktypes(values[c.JANET_STRING], c.JANET_TFLAG_BYTES) != 0);
    assert(c.janet_checktypes(values[c.JANET_SYMBOL], c.JANET_TFLAG_BYTES) != 0);
    assert(c.janet_checktypes(values[c.JANET_KEYWORD], c.JANET_TFLAG_BYTES) != 0);
    assert(c.janet_checktypes(values[c.JANET_BUFFER], c.JANET_TFLAG_BYTES) != 0);
    assert(c.janet_checktypes(values[c.JANET_ARRAY], c.JANET_TFLAG_BYTES) == 0);
}

// --------------------------------------------- the two spellings agree

/// Every predicate that has both an exported and an inlined form, checked
/// against each other for one value. Factored out because the set of values
/// that matters is larger than one per type -- see the call site.
fn agreeOn(v: c.Janet) void {
    assert(ops.truthy(v) == (c.janet_truthy(v) != 0));
    assert(ops.isNumber(v) == harness.isType(v, c.JANET_NUMBER));
    for (0..c.JANET_COUNT_TYPES) |j| {
        assert(ops.checkType(v, typeAt(j)) == harness.isType(v, typeAt(j)));
        const bit = @as(c_int, 1) << @intCast(j);
        assert(ops.checkTypes(v, bit) == (c.janet_checktypes(v, bit) != 0));
    }
    assert(ops.checkTypes(v, -1) == (c.janet_checktypes(v, -1) != 0));
    assert(ops.checkTypes(v, 0) == (c.janet_checktypes(v, 0) != 0));
}

/// The channel the C original had as macro-against-function, restated as
/// inline-against-export. See the header for why the two are not the same
/// question and why this one is the closest replacement available.
fn theTwoSpellingsAgree() void {
    var values: [c.JANET_COUNT_TYPES]c.Janet = undefined;
    buildOneOfEach(&values);
    const p = pointerA();

    // The constructors. Each `ops` member is the body of the identically named
    // export, so a disagreement means one of the two was wired to the wrong
    // helper -- which is exactly what the C channel could catch and no more.
    assert(sameValue(ops.wrapNil(), c.janet_wrap_nil()));
    assert(sameValue(ops.wrapTrue(), c.janet_wrap_true()));
    assert(sameValue(ops.wrapFalse(), c.janet_wrap_false()));
    assert(sameValue(ops.wrapBoolean(true), c.janet_wrap_boolean(3)));
    assert(sameValue(ops.wrapBoolean(false), c.janet_wrap_boolean(0)));
    assert(sameValue(ops.wrapNumber(2.5), c.janet_wrap_number(2.5)));
    assert(sameValue(ops.wrapArray(@ptrCast(@alignCast(p))), c.janet_wrap_array(@ptrCast(@alignCast(p)))));
    assert(sameValue(ops.wrapTable(@ptrCast(@alignCast(p))), c.janet_wrap_table(@ptrCast(@alignCast(p)))));
    assert(sameValue(ops.wrapBuffer(@ptrCast(@alignCast(p))), c.janet_wrap_buffer(@ptrCast(@alignCast(p)))));
    assert(sameValue(ops.wrapFunction(@ptrCast(@alignCast(p))), c.janet_wrap_function(@ptrCast(@alignCast(p)))));
    assert(sameValue(ops.wrapStruct(@ptrCast(@alignCast(p))), c.janet_wrap_struct(@ptrCast(@alignCast(p)))));
    assert(sameValue(ops.wrapTuple(@ptrCast(@alignCast(p))), c.janet_wrap_tuple(@ptrCast(@alignCast(p)))));

    // The predicates, over one value per type...
    for (values) |value| agreeOn(value);

    // ...and then over the values that take the *other* arm of each. One value
    // per type is not enough, and a mutation sweep against the C original is
    // what said so: `buildOneOfEach` samples `2.5` and `true`, which take the
    // ordinary arm of every predicate. A NaN's type nibble under a NaN-boxed
    // layout reads as `JANET_NUMBER`, so it is recognized by the second half of
    // `isNumber` rather than the first; `false` is the only value whose
    // truthiness depends on the payload rather than on the tag.
    const awkward = [_]c.Janet{
        c.janet_wrap_number(std.math.nan(f64)),
        c.janet_wrap_number(std.math.inf(f64)),
        c.janet_wrap_number(-std.math.inf(f64)),
        c.janet_wrap_number(0.0),
        c.janet_wrap_number(-0.0),
        c.janet_wrap_false(),
        c.janet_wrap_boolean(0),
        c.janet_wrap_boolean(3),
        c.janet_wrap_pointer(null),
    };
    for (awkward) |value| agreeOn(value);

    // The accessors.
    assert(ops.unwrapNumber(values[c.JANET_NUMBER]) == c.janet_unwrap_number(values[c.JANET_NUMBER]));
    assert(ops.unwrapInteger(c.janet_wrap_number(-9.5)) == c.janet_unwrap_integer(c.janet_wrap_number(-9.5)));
    assert(ops.unwrapFunction(values[c.JANET_FUNCTION]) == c.janet_unwrap_function(values[c.JANET_FUNCTION]));
    assert(ops.unwrapCFunction(values[c.JANET_CFUNCTION]) == c.janet_unwrap_cfunction(values[c.JANET_CFUNCTION]));
    assert(ops.unwrapFiber(values[c.JANET_FIBER]) == c.janet_unwrap_fiber(values[c.JANET_FIBER]));
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
    const nil_tag: u64 = (@as(u64, c.JANET_NIL) | 0x1FFF0) << 47;
    const bool_tag: u64 = (@as(u64, c.JANET_BOOLEAN) | 0x1FFF0) << 47;
    const array_tag: u64 = (@as(u64, c.JANET_ARRAY) | 0x1FFF0) << 47;

    // The three immediate values are a tag with a one-bit payload.
    assert(harness.u64Of(c.janet_wrap_nil()) == (nil_tag | 1));
    assert(harness.u64Of(c.janet_wrap_true()) == (bool_tag | 1));
    assert(harness.u64Of(c.janet_wrap_false()) == bool_tag);

    // A double is stored unchanged.
    const bits: u64 = @bitCast(@as(f64, 1.5));
    assert(harness.u64Of(c.janet_wrap_number(1.5)) == bits);
    assert(harness.u64Of(c.janet_nanbox_from_double(1.5)) == bits);
    assert(harness.u64Of(c.janet_nanbox_from_bits(bits)) == bits);

    // A pointer is shifted right by the alignment shift and then tagged, and
    // the payload bits are the only ones it may occupy.
    const word = harness.u64Of(c.janet_wrap_array(@ptrCast(@alignCast(p))));
    assert((word & c.JANET_NANBOX_TAGBITS) == array_tag);
    assert((word & c.JANET_NANBOX_PAYLOADBITS) ==
        (@as(u64, @intFromPtr(p)) >> c.JANET_NANBOX_64_POINTER_SHIFT));
    assert(c.janet_nanbox_to_pointer(c.janet_nanbox_from_pointer(p, array_tag)) == p);
    assert(c.janet_nanbox_to_pointer(c.janet_nanbox_from_cpointer(p, array_tag)) == p);
    assert(harness.u64Of(c.janet_nanbox_from_pointer(p, array_tag)) == word);

    // The canonical NaN is what `janet_wrap_number_safe` stores, and it is not
    // mistaken for a tagged value.
    const canonical: u64 = @bitCast(c.janet_unwrap_number(c.janet_wrap_number_safe(std.math.nan(f64))));
    assert(c.janet_type(c.janet_wrap_number_safe(std.math.nan(f64))) == c.JANET_NUMBER);
    assert((canonical & c.JANET_NANBOX_PAYLOADBITS) == 0);
}

fn exactLayoutNanbox32() void {
    const p = pointerA();

    // Every non-number tag is stored raw in the high word, below the offset
    // that biases a double's exponent out of the way.
    assert(c.janet_wrap_nil().tagged.type == @as(u32, c.JANET_NIL));
    assert(c.janet_wrap_nil().tagged.payload.integer == 0);
    assert(c.janet_wrap_true().tagged.type == @as(u32, c.JANET_BOOLEAN));
    assert(c.janet_wrap_true().tagged.payload.integer == 1);
    assert(c.janet_wrap_false().tagged.payload.integer == 0);
    assert(c.janet_wrap_array(@ptrCast(@alignCast(p))).tagged.type == @as(u32, c.JANET_ARRAY));
    assert(c.janet_wrap_array(@ptrCast(@alignCast(p))).tagged.payload.pointer == p);
    assert(@as(u32, c.JANET_POINTER) < @as(u32, c.JANET_DOUBLE_OFFSET));

    // A double is biased by JANET_DOUBLE_OFFSET in its high word, which is
    // what keeps every number above every tag.
    const bits: u64 = @bitCast(@as(f64, 1.5));
    assert(harness.u64Of(c.janet_wrap_number(1.5)) == bits +% (@as(u64, c.JANET_DOUBLE_OFFSET) << 32));
    assert(c.janet_unwrap_number(c.janet_wrap_number(1.5)) == 1.5);

    assert(c.janet_nanbox32_from_tagi(@as(u32, c.JANET_BOOLEAN), 1).tagged.payload.integer == 1);
    assert(c.janet_nanbox32_from_tagp(@as(u32, c.JANET_ARRAY), p).tagged.payload.pointer == p);
    assert(c.janet_nanbox32_from_tagp(@as(u32, c.JANET_ARRAY), p).tagged.type == @as(u32, c.JANET_ARRAY));

    const canonical: u64 = @bitCast(c.janet_unwrap_number(c.janet_wrap_number_safe(std.math.nan(f64))));
    assert((canonical & 0x000FFFFFFFFFFFFF) == 0x0008000000000000);
}

fn exactLayoutTagged() void {
    const p = pointerA();

    // The tag is a field of its own, and the payload union is zeroed before
    // the narrower member is written -- which is what the `as.u64 = 0` in
    // `JANET_WRAP_DEFINE` is for, and the only way to see it is through a
    // member narrower than the union.
    assert(c.janet_wrap_nil().type == c.JANET_NIL);
    assert(harness.u64Of(c.janet_wrap_nil()) == 0);
    assert(c.janet_wrap_true().type == c.JANET_BOOLEAN);
    assert(harness.u64Of(c.janet_wrap_true()) == 1);
    assert(harness.u64Of(c.janet_wrap_false()) == 0);
    assert(c.janet_wrap_array(@ptrCast(@alignCast(p))).type == c.JANET_ARRAY);
    assert(harness.u64Of(c.janet_wrap_array(@ptrCast(@alignCast(p)))) == @as(u64, @intFromPtr(p)));
    assert(harness.u64Of(c.janet_wrap_pointer(null)) == 0);

    assert(harness.u64Of(c.janet_wrap_number(1.5)) == @as(u64, @bitCast(@as(f64, 1.5))));

    // The one layout that does not canonicalize a NaN, because it has no tag
    // space in the double to protect. `FOUND.md` has the asymmetry.
    const hostile: u64 = 0x7FF0000000000123;
    assert(harness.u64Of(c.janet_wrap_number_safe(@bitCast(hostile))) == hostile);
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
        const before = c.janet_vm.next_collection;
        const kvs: [*c]c.JanetKV = @ptrCast(@alignCast(internal.janet_memalloc_empty(n)));
        // Reaching this line is the null check: the failure path exits.
        assert(kvs != null);
        assert(c.janet_vm.next_collection - before == @as(usize, @intCast(n)) * @sizeOf(c.JanetKV));
        var i: i32 = 0;
        while (i < n) : (i += 1) {
            assert(harness.isType(kvs[@intCast(i)].key, c.JANET_NIL));
            assert(harness.isType(kvs[@intCast(i)].value, c.JANET_NIL));
        }
        c.janet_free(kvs);
    }
}

/// A zero-length request charges nothing and writes nothing. The pointer it
/// returns is whatever the platform's `malloc(0)` gives, which is a block on
/// macOS and on musl; if it were null the process would have exited inside the
/// call, so the assertion below is about the charge and not about the pointer.
fn memallocEmptyOfZero() void {
    const before = c.janet_vm.next_collection;
    const mem = internal.janet_memalloc_empty(0);
    assert(c.janet_vm.next_collection == before);
    c.janet_free(mem);
}

/// `janet_memempty` clears a block the caller already owns. The block is
/// dirtied first with values of a type that is not nil under every layout, so a
/// fill that did nothing at all would be caught rather than passing on whatever
/// the allocator happened to leave.
fn mememptyClearsADirtyBlock() void {
    const n = 16;
    const kvs: [*c]c.JanetKV = @ptrCast(@alignCast(internal.janet_memalloc_empty(n)));
    defer c.janet_free(kvs);

    for (0..n) |i| {
        kvs[i].key = harness.wrapInteger(@intCast(i + 1));
        kvs[i].value = c.janet_wrap_boolean(1);
        assert(!harness.isType(kvs[i].key, c.JANET_NIL));
        assert(!harness.isType(kvs[i].value, c.JANET_NIL));
    }

    internal.janet_memempty(kvs, n);
    for (0..n) |i| {
        assert(harness.isType(kvs[i].key, c.JANET_NIL));
        assert(harness.isType(kvs[i].value, c.JANET_NIL));
        assert(sameValue(kvs[i].key, c.janet_wrap_nil()));
        assert(sameValue(kvs[i].value, c.janet_wrap_nil()));
    }

    // A zero count leaves the block alone rather than clearing one pair.
    kvs[0].key = c.janet_wrap_boolean(1);
    internal.janet_memempty(kvs, 0);
    assert(harness.isType(kvs[0].key, c.JANET_BOOLEAN));
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
        const string = c.janet_wrap_string(c.janet_cstring("cycle"));
        c.janet_array_push(c.janet_unwrap_array(array), string);
        c.janet_table_put(c.janet_unwrap_table(table), harness.wrapInteger(i), buffer);
        c.janet_gcroot(array);
        c.janet_gcroot(table);
        c.janet_collect();
        assert(c.janet_type(array) == c.JANET_ARRAY);
        assert(c.janet_unwrap_array(array).*.count == 1);
        assert(sameValue(c.janet_unwrap_array(array).*.data[0], string));
        assert(sameValue(
            c.janet_table_get(c.janet_unwrap_table(table), harness.wrapInteger(i)),
            buffer,
        ));
        _ = c.janet_gcunroot(table);
        _ = c.janet_gcunroot(array);
        c.janet_collect();
    }
}

// ------------------------------------------------------------------- main

pub fn run() void {
    _ = c.janet_init();
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
