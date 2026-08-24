//! Behavioral contract for the marshalling protocol.
//!
//! The reason this file exists rather than leaning on `test/suite-marsh.janet`:
//! the suite reaches `marshal` and `unmarshal`, and those two cfunctions use a
//! strict subset of the subsystem. Everything below is either unreachable from
//! Janet or unobservable there.
//!
//!  - `JANET_MARSHAL_UNSAFE` has no Janet spelling. `cfun_marshal` never sets
//!    it and `cfun_unmarshal` passes a hard zero, so pointers, cfunctions,
//!    pointer-backed buffers and threaded abstracts -- five of the twenty-nine
//!    lead bytes -- are reachable only from a caller inside the runtime.
//!  - The twenty-function marshal context API is called from an abstract
//!    type's `marshal` and `unmarshal` callbacks and from nowhere else. The
//!    core types that have such callbacks exercise four of the twenty between
//!    them.
//!  - `janet_env_lookup_into`'s `prefix` and `recurse` parameters are both
//!    fixed by `janet_env_lookup`, which is what `env-lookup` calls.
//!  - `unmarshal`'s `next` out-parameter is dropped by `cfun_unmarshal`.
//!
//! The wire format is the other reason. A marshalled stream is a file format,
//! so its bytes are the contract rather than an implementation detail, and the
//! assertions below are written against literal bytes for that reason.
//!
//! ## What the migration changed, and the defect it found
//!
//! **An abstract type's callbacks are Zig functions here, so the probe type is
//! written rather than adapted.** The C original could not define one at all:
//! `abstract_type.zig` types `marshal`, `unmarshal`, `get`, `put`, `next`,
//! `call` and `tostring` as raising, and C has no error union, so
//! `test/support.zig` kept a pool of pre-built tables reached through the
//! `CONTRACT_AT` macro. That pool had eight users at the start of this phase
//! and `test/marsh.c` was the last of them; it dies with this file.
//!
//! What it cost the C contract is worth recording, because it is what a shim
//! count hides. Every read in `probe_unmarshal` had to be followed by
//!
//!     #define BAIL_IF_RAISING(value) \
//!         do { if (janet_contract_raising()) return (value); } while (0)
//!
//! because a raise reached C as a report and the read that followed it would
//! otherwise walk off the end of the stream -- with the truncation section
//! below cutting the stream at every offset, each of those really was reached.
//! Here every one of them is `try`, and `janet_contract_raising` loses its only
//! user in the tree.
//!
//! **And writing the callback as the runtime types it found a live defect in
//! the runtime**, one directory over. `janet_marshal_size` was a
//! `raise.reported` face with no raising twin, and `peg.zig`'s `pegMarshal`
//! and `io_core.zig`'s `fileMarshal` were both calling *the face* from inside
//! a raising callback -- so a buffer that refused to grow at exactly that call
//! became a report nobody consumed. `marsh.marshalSize` is the twin; the
//! increment's entry in `src/zig/README.md` has the reproduction.

const std = @import("std");
const abi = @import("abi");
const c = abi.c;
const raise = @import("raise");
const harness = @import("harness.zig");

const subsystems = @import("subsystems");
const marsh = subsystems.marsh;
const registry = subsystems.registry;
const abstract_type = subsystems.abstract_type;
const AbstractType = abstract_type.AbstractType;

const assert = std.debug.assert;

var test_env: *c.JanetTable = undefined;

/// Values a `Janet` local would not keep alive. The probe types have no
/// `gcmark`, so nothing an abstract holds is a root either.
var rooted: *c.JanetArray = undefined;

fn keep(value: c.Janet) c.Janet {
    c.janet_array_push(rooted, value);
    return value;
}

// ------------------------------------------------------------ wire assertions

/// A buffer's contents against a literal, with both rendered on a mismatch.
///
/// The C original's `check_bytes` printed the two byte strings and then
/// `assert(0)`. Kept, because a wire-format failure is unreadable without
/// them: the assertion that fires says only that two buffers differ.
fn wireIs(b: *c.JanetBuffer, expected: []const u8) void {
    const got = b.data[0..@intCast(b.count)];
    if (std.mem.eql(u8, got, expected)) return;
    std.debug.print("expected {d} bytes:", .{expected.len});
    for (expected) |byte| std.debug.print(" {x:0>2}", .{byte});
    std.debug.print("\n     got {d} bytes:", .{got.len});
    for (got) |byte| std.debug.print(" {x:0>2}", .{byte});
    std.debug.print("\n", .{});
    @panic("wire format mismatch");
}

fn marshalled(x: c.Janet, rreg: [*c]c.JanetTable, flags: c_int) raise.Raising(*c.JanetBuffer) {
    const b = c.janet_buffer(16);
    try marsh.marshal(b, x, rreg, flags);
    return b;
}

fn unmarshalled(b: *c.JanetBuffer, flags: c_int) raise.Raising(c.Janet) {
    return marsh.unmarshal(b.data, @intCast(b.count), flags, null, null);
}

/// `unmarshal` over a literal, which is how every crafted stream below is
/// spelled. Slices rather than pointer-and-length: the length of a Zig string
/// literal is part of it, and the C original had to write `sizeof(x) - 1` at
/// every site to say the same thing.
fn unmarshalBytes(bytes: []const u8, flags: c_int) raise.Raising(c.Janet) {
    return marsh.unmarshal(bytes.ptr, bytes.len, flags, null, null);
}

/// The refusal a crafted stream produced, or null if it was accepted.
fn refusedBy(bytes: []const u8) ?harness.Raise {
    return harness.raised(unmarshalBytes, .{ bytes, @as(c_int, 0) });
}

// ------------------------------------------------------- the probe abstract
//
// One abstract type whose callbacks drive every entry point of the context
// API, so that a round trip through it is a round trip through all twenty.
// The pointer fields are written only in unsafe mode, which is also what makes
// this type a witness for `janet_marshal_flags`.

const Probe = extern struct {
    i32_field: i32,
    i64_field: i64,
    sz: usize,
    byte: u8,
    bytes: [4]u8,
    value: c.Janet,
    ptr: ?*anyopaque,
};

fn probeMarshal(pointer: ?*anyopaque, ctx: [*c]c.JanetMarshalContext) raise.Raising(void) {
    const probe: *Probe = @ptrCast(@alignCast(pointer));
    c.janet_marshal_abstract(ctx, pointer);
    try marsh.marshalInt(ctx, probe.i32_field);
    try marsh.marshalInt64(ctx, probe.i64_field);
    try marsh.marshalSize(ctx, probe.sz);
    try marsh.marshalByte(ctx, probe.byte);
    try marsh.marshalBytes(ctx, &probe.bytes, probe.bytes.len);
    try marsh.marshalJanet(ctx, probe.value);
    const unsafe = (c.janet_marshal_flags(ctx) & c.JANET_MARSHAL_UNSAFE) != 0;
    try marsh.marshalByte(ctx, @intFromBool(unsafe));
    if (unsafe) try marsh.marshalPtr(ctx, probe.ptr);
}

/// Every read is a `try`, which is the whole of what the C original spelled as
/// a `BAIL_IF_RAISING` after each one -- see the header comment.
fn probeUnmarshal(ctx: [*c]c.JanetMarshalContext) raise.Raising(?*anyopaque) {
    const probe: *Probe = @ptrCast(@alignCast(try marsh.unmarshalAbstract(ctx, @sizeOf(Probe))));
    probe.i32_field = try marsh.unmarshalInt(ctx);
    probe.i64_field = try marsh.unmarshalInt64(ctx);
    probe.sz = try marsh.unmarshalSize(ctx);
    try marsh.unmarshalEnsure(ctx, 1);
    probe.byte = try marsh.unmarshalByte(ctx);
    try marsh.unmarshalBytes(ctx, &probe.bytes, probe.bytes.len);
    probe.value = try marsh.unmarshalJanet(ctx);
    probe.ptr = null;
    const unsafe = try marsh.unmarshalByte(ctx);
    if (unsafe != 0) {
        assert((c.janet_unmarshal_flags(ctx) & c.JANET_MARSHAL_UNSAFE) != 0);
        probe.ptr = try marsh.unmarshalPtr(ctx);
    }
    return probe;
}

const probe_at: AbstractType = .{
    .name = "test/marsh-probe",
    .marshal = probeMarshal,
    .unmarshal = probeUnmarshal,
};

/// A type that always reaches for a pointer, so that the safe-mode refusal has
/// something to refuse.
fn refuserMarshal(pointer: ?*anyopaque, ctx: [*c]c.JanetMarshalContext) raise.Raising(void) {
    c.janet_marshal_abstract(ctx, pointer);
    try marsh.marshalPtr(ctx, pointer);
}

fn refuserUnmarshal(ctx: [*c]c.JanetMarshalContext) raise.Raising(?*anyopaque) {
    const p = try marsh.unmarshalAbstract(ctx, @sizeOf(i32));
    _ = try marsh.unmarshalPtr(ctx);
    return p;
}

const refuser_at: AbstractType = .{
    .name = "test/marsh-refuser",
    .marshal = refuserMarshal,
    .unmarshal = refuserUnmarshal,
};

/// A type that writes more bytes than a Janet buffer can index.
fn toobigMarshal(pointer: ?*anyopaque, ctx: [*c]c.JanetMarshalContext) raise.Raising(void) {
    c.janet_marshal_abstract(ctx, pointer);
    try marsh.marshalBytes(ctx, @ptrCast(pointer), @as(usize, std.math.maxInt(i32)) + 1);
}

const toobig_at: AbstractType = .{
    .name = "test/marsh-toobig",
    .marshal = toobigMarshal,
};

/// The marshal half of the three types whose *unmarshal* half breaks the
/// abstract protocol.
fn protocolMarshal(pointer: ?*anyopaque, ctx: [*c]c.JanetMarshalContext) raise.Raising(void) {
    c.janet_marshal_abstract(ctx, pointer);
    try marsh.marshalByte(ctx, @as(*u8, @ptrCast(pointer)).*);
}

/// Registers itself twice.
fn twiceUnmarshal(ctx: [*c]c.JanetMarshalContext) raise.Raising(?*anyopaque) {
    const p = try marsh.unmarshalAbstract(ctx, 1);
    try marsh.unmarshalAbstractReuse(ctx, p);
    return p;
}

const twice_at: AbstractType = .{
    .name = "test/marsh-twice",
    .marshal = protocolMarshal,
    .unmarshal = twiceUnmarshal,
};

/// Never registers at all.
fn neverUnmarshal(ctx: [*c]c.JanetMarshalContext) raise.Raising(?*anyopaque) {
    _ = try marsh.unmarshalByte(ctx);
    return c.janet_abstract(abstract_type.stored(&probe_at), @sizeOf(Probe));
}

const never_at: AbstractType = .{
    .name = "test/marsh-never",
    .marshal = protocolMarshal,
    .unmarshal = neverUnmarshal,
};

fn threadedUnmarshal(ctx: [*c]c.JanetMarshalContext) raise.Raising(?*anyopaque) {
    return marsh.unmarshalAbstractThreaded(ctx, 1);
}

const threaded_at: AbstractType = .{
    .name = "test/marsh-threaded",
    .marshal = protocolMarshal,
    .unmarshal = threadedUnmarshal,
};

/// A type with no callbacks at all, which is what makes a value
/// unmarshallable rather than merely unregistered.
const inert_at: AbstractType = .{ .name = "test/marsh-inert" };

fn stored(at: *const AbstractType) [*c]const c.JanetAbstractType {
    return abstract_type.stored(at);
}

// -------------------------------------------------------- the integer codec

/// `pushInt` picks one of three encodings by range, and `readInt` picks by
/// lead byte. Neither boundary is observable from Janet, where a marshalled
/// integer is just an integer coming back.
fn theThreeIntegerEncodings() raise.Raising(void) {
    const w = harness.wrapInteger;
    wireIs(try marshalled(w(0), null, 0), "\x00");
    wireIs(try marshalled(w(127), null, 0), "\x7f");
    wireIs(try marshalled(w(128), null, 0), "\x80\x80");
    wireIs(try marshalled(w(8191), null, 0), "\x9f\xff");
    wireIs(try marshalled(w(8192), null, 0), "\xcd\x00\x00\x20\x00");
    wireIs(try marshalled(w(-1), null, 0), "\xbf\xff");
    wireIs(try marshalled(w(-8192), null, 0), "\xa0\x00");
    wireIs(try marshalled(w(-8193), null, 0), "\xcd\xff\xff\xdf\xff");
    wireIs(try marshalled(w(std.math.minInt(i32)), null, 0), "\xcd\x80\x00\x00\x00");
    wireIs(try marshalled(w(std.math.maxInt(i32)), null, 0), "\xcd\x7f\xff\xff\xff");

    // And back. The two-byte form sign extends its eighteen most significant
    // bits, which is the half of `readInt` a positive value never reaches.
    const cases = [_]struct { bytes: []const u8, value: i32 }{
        .{ .bytes = "\x00", .value = 0 },
        .{ .bytes = "\x7f", .value = 127 },
        .{ .bytes = "\x80\x80", .value = 128 },
        .{ .bytes = "\x9f\xff", .value = 8191 },
        .{ .bytes = "\xa0\x00", .value = -8192 },
        .{ .bytes = "\xbf\xff", .value = -1 },
        .{ .bytes = "\xcd\x80\x00\x00\x00", .value = std.math.minInt(i32) },
        .{ .bytes = "\xcd\x7f\xff\xff\xff", .value = std.math.maxInt(i32) },
    };
    for (cases) |case| {
        assert(harness.integerIs(try unmarshalBytes(case.bytes, 0), case.value));
    }
}

/// A double that is not an exact int32 takes the eight-byte path and is
/// recorded as a reference; an integral one never is.
fn realsAndIntegralDoublesDiffer() raise.Raising(void) {
    var b = try marshalled(c.janet_wrap_number(0.5), null, 0);
    assert(b.count == 9);
    assert(b.data[0] == lb_real);
    assert(c.janet_unwrap_number(try unmarshalled(b, 0)) == 0.5);

    wireIs(try marshalled(c.janet_wrap_number(3.0), null, 0), "\x03");

    // 2^31 is integral and outside int32, so it is a real.
    b = try marshalled(c.janet_wrap_number(2147483648.0), null, 0);
    assert(b.count == 9 and b.data[0] == lb_real);
    assert(c.janet_unwrap_number(try unmarshalled(b, 0)) == 2147483648.0);
}

// -------------------------------------------------------- the 64-bit codec

/// `push64` is length-prefixed above 0xF0 and bare below it, and only the
/// context API reaches it.
fn theSizeEncodingBoundaries() raise.Raising(void) {
    const values = [_]u64{
        0,          1,          0xEF,               0xF0, 0xF1, 0xFF, 0x100, 0xFFFFFFFF,
        0x01020304, 0x05060708, 0xFFFFFFFFFFFFFFFF,
    };
    for (values) |value| {
        const probe: *Probe = @ptrCast(@alignCast(c.janet_abstract(stored(&probe_at), @sizeOf(Probe))));
        probe.* = std.mem.zeroes(Probe);
        probe.i64_field = @bitCast(value);
        probe.sz = @truncate(value);
        probe.value = c.janet_wrap_nil();
        const b = try marshalled(keep(c.janet_wrap_abstract(probe)), null, 0);
        const back: *Probe = @ptrCast(@alignCast(c.janet_unwrap_abstract(try unmarshalled(b, 0))));
        assert(@as(u64, @bitCast(back.i64_field)) == value);
        assert(back.sz == @as(usize, @truncate(value)));
    }

    // The prefix byte counts the bytes that follow, little endian.
    const probe: *Probe = @ptrCast(@alignCast(c.janet_abstract(stored(&probe_at), @sizeOf(Probe))));
    probe.* = std.mem.zeroes(Probe);
    probe.i64_field = 0x0102;
    probe.value = c.janet_wrap_nil();
    const b = try marshalled(keep(c.janet_wrap_abstract(probe)), null, 0);
    // ...LB_ABSTRACT, name, i32 = 0, then the int64.
    const tail = 3 // the i64: prefix and two bytes
        + 1 // sz, zero
        + 1 // byte
        + 4 // bytes
        + 1 // value: nil
        + 1; // the unsafe marker
    const at = b.data + @as(usize, @intCast(b.count)) - tail;
    assert(at[0] == 0xF2 and at[1] == 0x02 and at[2] == 0x01);

    // Nine bytes of length is not a 64-bit integer.
    assert(refusedBy("\xf9\x00\x00\x00\x00\x00\x00\x00\x00\x00").?.says("unknown byte f9 at index 0"));
}

// ---------------------------------------------------------- the context API

fn makeProbe() *Probe {
    const probe: *Probe = @ptrCast(@alignCast(c.janet_abstract(stored(&probe_at), @sizeOf(Probe))));
    probe.i32_field = -12345;
    probe.i64_field = -0x0102030405060708;
    probe.sz = 0x1234;
    probe.byte = 0xAB;
    probe.bytes = "wxyz".*;
    probe.value = c.janet_cstringv("payload");
    probe.ptr = @ptrCast(@constCast(stored(&probe_at)));
    _ = keep(c.janet_wrap_abstract(probe));
    return probe;
}

fn theContextApiRoundTrips() raise.Raising(void) {
    const probe = makeProbe();
    var b = try marshalled(c.janet_wrap_abstract(probe), null, 0);
    const out = keep(try unmarshalled(b, 0));
    assert(harness.isType(out, c.JANET_ABSTRACT));
    assert(c.janet_abstract_type(c.janet_unwrap_abstract(out)) == stored(&probe_at));
    var back: *Probe = @ptrCast(@alignCast(c.janet_unwrap_abstract(out)));
    assert(back != probe);
    assert(back.i32_field == probe.i32_field);
    assert(back.i64_field == probe.i64_field);
    assert(back.sz == probe.sz);
    assert(back.byte == probe.byte);
    assert(std.mem.eql(u8, &back.bytes, "wxyz"));
    assert(harness.equals(back.value, probe.value));
    // Safe mode: the pointer was not written, so it does not come back.
    assert(back.ptr == null);

    // Unsafe mode carries it.
    b = try marshalled(c.janet_wrap_abstract(probe), null, c.JANET_MARSHAL_UNSAFE);
    back = @ptrCast(@alignCast(c.janet_unwrap_abstract(
        keep(try unmarshalled(b, c.JANET_MARSHAL_UNSAFE)),
    )));
    assert(back.ptr == @as(?*anyopaque, @ptrCast(@constCast(stored(&probe_at)))));

    // The stream opens with LB_ABSTRACT and the type's name as a symbol.
    const name = std.mem.span(probe_at.name);
    assert(b.data[0] == lb_abstract);
    assert(b.data[1] == lb_symbol);
    assert(b.data[2] == name.len);
    assert(std.mem.eql(u8, b.data[3 .. 3 + name.len], name));
}

/// The abstract is entered into the reference table before its fields are
/// read, so a value that contains itself resolves rather than recursing.
fn anAbstractCanContainItself() raise.Raising(void) {
    const probe = makeProbe();
    const self = c.janet_wrap_abstract(probe);
    const holder = c.janet_array(1);
    c.janet_array_push(holder, self);
    probe.value = c.janet_wrap_array(holder);

    const b = try marshalled(self, null, 0);
    const back: *Probe = @ptrCast(@alignCast(c.janet_unwrap_abstract(keep(try unmarshalled(b, 0)))));
    assert(harness.isType(back.value, c.JANET_ARRAY));
    const back_holder = c.janet_unwrap_array(back.value);
    assert(back_holder.*.count == 1);
    assert(c.janet_unwrap_abstract(back_holder.*.data[0]) == @as(?*anyopaque, back));
}

fn theAbstractProtocolIsEnforced() raise.Raising(void) {
    const twice: *u8 = @ptrCast(c.janet_abstract(stored(&twice_at), 1));
    twice.* = 7;
    var b = try marshalled(keep(c.janet_wrap_abstract(twice)), null, 0);
    assert(harness.raised(unmarshalled, .{ b, @as(c_int, 0) }).?
        .says("janet_unmarshal_abstract called more than once"));

    const never: *u8 = @ptrCast(c.janet_abstract(stored(&never_at), 1));
    never.* = 7;
    b = try marshalled(keep(c.janet_wrap_abstract(never)), null, 0);
    assert(harness.raised(unmarshalled, .{ b, @as(c_int, 0) }).?
        .says("janet_unmarshal_abstract not called"));

    const threaded: *u8 = @ptrCast(c.janet_abstract(stored(&threaded_at), 1));
    threaded.* = 7;
    b = try marshalled(keep(c.janet_wrap_abstract(threaded)), null, 0);
    // `JANET_THREADS` is defined by no build in this tree, so this arm is the
    // only one that has ever been compiled. See `FOUND.md`.
    assert(harness.raised(unmarshalled, .{ b, @as(c_int, 0) }).?
        .says("threaded abstracts not supported"));

    const inert: *i32 = @ptrCast(@alignCast(c.janet_abstract(stored(&inert_at), @sizeOf(i32))));
    inert.* = 7;
    assert(harness.raised(
        marshalled,
        .{ keep(c.janet_wrap_abstract(inert)), @as([*c]c.JanetTable, null), @as(c_int, 0) },
    ).?.beginsWith("cannot marshal <test/marsh-inert 0x"));
}

fn theUnsafeGateOnTheContextApi() raise.Raising(void) {
    const refuser = keep(c.janet_wrap_abstract(c.janet_abstract(stored(&refuser_at), @sizeOf(i32))));
    assert(harness.raised(
        marshalled,
        .{ refuser, @as([*c]c.JanetTable, null), @as(c_int, 0) },
    ).?.says("can only marshal pointers in unsafe mode"));

    const b = try marshalled(refuser, null, c.JANET_MARSHAL_UNSAFE);
    assert(harness.raised(unmarshalled, .{ b, @as(c_int, 0) }).?
        .says("can only unmarshal pointers in unsafe mode"));
    // And succeeds when the flag is given.
    assert(harness.isType(try unmarshalled(b, c.JANET_MARSHAL_UNSAFE), c.JANET_ABSTRACT));

    // A length that cannot be a buffer index is refused before anything is
    // read from it.
    const toobig = keep(c.janet_wrap_abstract(c.janet_abstract(stored(&toobig_at), @sizeOf(i32))));
    assert(harness.raised(
        marshalled,
        .{ toobig, @as([*c]c.JanetTable, null), @as(c_int, 0) },
    ).?.says("size_t too large to fit in buffer"));
}

// ------------------------------------------------------- the unsafe payloads

/// A cfunction that exists to be a value with an address.
///
/// `align(corefn.alignment)` for `test/registry.zig`'s reason: nanbox-64 with
/// a pointer shift steals the low bits of a cfunction pointer, and
/// `-Dnanbox-pointer-shift=2` is a matrix entry. The C original got the same
/// requirement from `JANET_CFUNCTION_ALIGN`.
fn aCfunction(argc: i32, argv: [*c]c.Janet) align(@import("corefn").alignment) raise.Raising(c.Janet) {
    _ = argc;
    _ = argv;
    return harness.wrapInteger(1729);
}

fn pointersAndCfunctionsNeedTheUnsafeFlag() raise.Raising(void) {
    const ptr = c.janet_wrap_pointer(@ptrCast(@constCast(stored(&probe_at))));
    const cfun = c.janet_wrap_cfunction(raise.stored(&aCfunction));

    assert(harness.raised(marshalled, .{ ptr, @as([*c]c.JanetTable, null), @as(c_int, 0) }).?
        .beginsWith("no registry value and cannot marshal <pointer 0x"));
    assert(harness.raised(marshalled, .{ cfun, @as([*c]c.JanetTable, null), @as(c_int, 0) }).?
        .beginsWith("no registry value and cannot marshal <cfunction 0x"));

    var b = try marshalled(ptr, null, c.JANET_MARSHAL_UNSAFE);
    assert(b.data[0] == lb_unsafe_pointer);
    assert(b.count == 1 + @sizeOf(*anyopaque));
    assert(c.janet_unwrap_pointer(try unmarshalled(b, c.JANET_MARSHAL_UNSAFE)) ==
        @as(?*anyopaque, @ptrCast(@constCast(stored(&probe_at)))));
    assert(harness.raised(unmarshalled, .{ b, @as(c_int, 0) }).?
        .says("unsafe flag not given, will not unmarshal raw pointer at index 1"));

    b = try marshalled(cfun, null, c.JANET_MARSHAL_UNSAFE);
    assert(b.data[0] == lb_unsafe_cfunction);
    const back = try unmarshalled(b, c.JANET_MARSHAL_UNSAFE);
    assert(c.janet_unwrap_cfunction(back) == raise.stored(&aCfunction));
    assert(harness.raised(unmarshalled, .{ b, @as(c_int, 0) }).?
        .says("unsafe flag not given, will not unmarshal function pointer at index 1"));
}

// ------------------------------------------------------- the weak vocabulary

/// `LB_THREADED_ABSTRACT` and `LB_POINTER_BUFFER` are inside `#ifdef JANET_EV`
/// in the lead-byte enum and the seven weak-container bytes that follow them
/// are not, so the weak bytes renumber with the build. That is a defect, it is
/// upstream's, and this pins it in whichever configuration is being built --
/// see `FOUND.md`.
///
/// The C original spelled the two cases as an `#ifdef JANET_EV` cascade, and
/// this is the same question asked of the same input: `JANET_VM_HAS_EV` is the
/// config header's, which is what `marsh.zig`'s own `has_ev` reads. What must
/// *not* be read here is `marsh.zig`'s `weak_base`, which is the arithmetic
/// under test -- rule 8's circularity, one import away.
///
/// The lead-byte enumeration is private to the subsystem, so there is no
/// `LB_POINTER_BUFFER` in the translation to ask instead.
const lb_weak_base: u8 = if (c.JANET_VM_HAS_EV != 0) 226 else 224;

// The lead bytes this file names by number, so that the numbers appear once.
// Every one is a wire-format constant: `janet.h` does not export the enum and
// a renumbering would silently invalidate every stored image.
const lb_real: u8 = 200;
const lb_fiber: u8 = 204;
const lb_symbol: u8 = 207;
const lb_abstract: u8 = 217;
const lb_funcenv_ref: u8 = 219;
const lb_funcdef_ref: u8 = 220;
const lb_unsafe_cfunction: u8 = 221;
const lb_unsafe_pointer: u8 = 222;

fn theWeakLeadBytesMoveWithTheEventLoop() raise.Raising(void) {
    const weakk = c.janet_table_weakk(1);
    const weakv = c.janet_table_weakv(1);
    const weakkv = c.janet_table_weakkv(1);
    const weak_array = c.janet_array_weak(0);

    assert((try marshalled(c.janet_wrap_table(weakk), null, 0)).data[0] == lb_weak_base + 0);
    assert((try marshalled(c.janet_wrap_table(weakv), null, 0)).data[0] == lb_weak_base + 1);
    assert((try marshalled(c.janet_wrap_table(weakkv), null, 0)).data[0] == lb_weak_base + 2);
    assert((try marshalled(c.janet_wrap_array(weak_array), null, 0)).data[0] == lb_weak_base + 6);

    weakk.*.proto = c.janet_table(0);
    weakv.*.proto = c.janet_table(0);
    weakkv.*.proto = c.janet_table(0);
    assert((try marshalled(c.janet_wrap_table(weakk), null, 0)).data[0] == lb_weak_base + 3);
    assert((try marshalled(c.janet_wrap_table(weakv), null, 0)).data[0] == lb_weak_base + 4);
    assert((try marshalled(c.janet_wrap_table(weakkv), null, 0)).data[0] == lb_weak_base + 5);

    // And each comes back as the same flavour of weak container.
    var b = try marshalled(c.janet_wrap_array(weak_array), null, 0);
    var back = try unmarshalled(b, 0);
    assert(harness.isType(back, c.JANET_ARRAY));
    b = try marshalled(c.janet_wrap_table(weakkv), null, 0);
    back = try unmarshalled(b, 0);
    assert(harness.isType(back, c.JANET_TABLE));
    assert(c.janet_unwrap_table(back).*.proto != null);
}

// ------------------------------------------------------- the reference table

/// A tuple and a struct are marked seen *after* their contents are written and
/// everything else before, which decides whether a self-reference is
/// expressible at all.
fn whenAValueBecomesAReference() raise.Raising(void) {
    const a = c.janet_array(1);
    c.janet_array_push(a, c.janet_wrap_array(a));
    var b = try marshalled(keep(c.janet_wrap_array(a)), null, 0);
    // LB_ARRAY, count 1, then LB_REFERENCE 0.
    wireIs(b, "\xd1\x01\xda\x00");
    var back_a = c.janet_unwrap_array(keep(try unmarshalled(b, 0)));
    assert(back_a.*.count == 1 and c.janet_unwrap_array(back_a.*.data[0]) == back_a);

    // The same array twice is one reference and one back-reference.
    const outer = c.janet_array(2);
    const inner = c.janet_array(0);
    c.janet_array_push(outer, c.janet_wrap_array(inner));
    c.janet_array_push(outer, c.janet_wrap_array(inner));
    b = try marshalled(keep(c.janet_wrap_array(outer)), null, 0);
    wireIs(b, "\xd1\x02\xd1\x00\xda\x01");
    back_a = c.janet_unwrap_array(keep(try unmarshalled(b, 0)));
    assert(c.janet_unwrap_array(back_a.*.data[0]) == c.janet_unwrap_array(back_a.*.data[1]));

    // With cycles switched off nothing is recorded, so the same array is
    // written twice and the copies come back distinct.
    b = try marshalled(c.janet_wrap_array(outer), null, c.JANET_MARSHAL_NO_CYCLES);
    wireIs(b, "\xd1\x02\xd1\x00\xd1\x00");
    back_a = c.janet_unwrap_array(keep(try unmarshalled(b, 0)));
    assert(c.janet_unwrap_array(back_a.*.data[0]) != c.janet_unwrap_array(back_a.*.data[1]));

    // And a cyclic value has nothing to stop it but the recursion guard.
    assert(harness.raised(marshalled, .{
        c.janet_wrap_array(a),
        @as([*c]c.JanetTable, null),
        @as(c_int, c.JANET_MARSHAL_NO_CYCLES),
    }).?.says("stack overflow"));
}

fn aReferenceIndexIsBoundsChecked() void {
    assert(refusedBy("\xda\x00").?.says("invalid reference 0"));
    // Neither of the other two reference bytes is a lead byte: a funcenv
    // reference is only read where a funcenv is expected, and a funcdef
    // reference where a funcdef is.
    assert(refusedBy("\xdb\x00").?.says("unknown byte db at index 0"));
    assert(refusedBy("\xdc\x00").?.says("unknown byte dc at index 0"));
    // A function with no environments, whose funcdef is a reference into an
    // empty table.
    assert(refusedBy("\xd7\x00\xdc\x00").?.says("invalid funcdef reference 0"));
}

// -------------------------------------------------- functions and closures

fn onlyIndexOf(b: *c.JanetBuffer, lead: u8) i32 {
    var found: i32 = -1;
    var i: i32 = 0;
    while (i < b.count) : (i += 1) {
        if (b.data[@intCast(i)] != lead) continue;
        assert(found < 0); // expected exactly one occurrence of this lead byte
        found = i;
    }
    assert(found >= 0); // expected this lead byte to appear
    return found;
}

fn callThunk(f: c.Janet) i32 {
    var result = c.janet_wrap_nil();
    var fiber: [*c]c.JanetFiber = null;
    const sig = c.janet_pcall(c.janet_unwrap_function(f), 0, null, &result, &fiber);
    assert(sig == c.JANET_SIGNAL_OK);
    return c.janet_unwrap_integer(result);
}

fn evaluate(source: [*:0]const u8) c.Janet {
    var out: c.Janet = undefined;
    assert(c.janet_dostring(test_env, source, "marsh-test", &out) == 0);
    return keep(out);
}

/// The funcenv and funcdef tables are the two reference tables that have no
/// Janet-visible effect: sharing is preserved rather than observed, so what
/// pins them is the wire format and the failure of a corrupted index.
fn functionStreamsAndTheirBackReferences() raise.Raising(void) {
    // Two closures over one variable share a funcenv, so the second is written
    // as a back reference.
    var out = evaluate("(do (var x 41) [(fn [] x) (fn [] (+ x 1))])");
    var b = try marshalled(out, null, 0);
    _ = keep(c.janet_wrap_buffer(b));
    var at = onlyIndexOf(b, lb_funcenv_ref);
    var closures = keep(try unmarshalled(b, 0));
    var back = c.janet_unwrap_tuple(closures);
    assert(callThunk(back[0]) == 41);
    assert(callThunk(back[1]) == 42);
    b.data[@intCast(at + 1)] = 0x7f;
    assert(harness.raised(unmarshalled, .{ b, @as(c_int, 0) }).?
        .says("invalid funcenv reference 127"));

    // Two instances of one `fn` share a funcdef, and only the second is a back
    // reference -- the closed-over values are still written twice.
    out = evaluate("(tuple ;(map (fn [x] (fn [] x)) [7 8]))");
    b = try marshalled(out, null, 0);
    _ = keep(c.janet_wrap_buffer(b));
    at = onlyIndexOf(b, lb_funcdef_ref);
    closures = keep(try unmarshalled(b, 0));
    back = c.janet_unwrap_tuple(closures);
    assert(callThunk(back[0]) == 7);
    assert(callThunk(back[1]) == 8);
    b.data[@intCast(at + 1)] = 0x7f;
    assert(harness.raised(unmarshalled, .{ b, @as(c_int, 0) }).?
        .says("invalid funcdef reference 127"));

    // A function carries at most 255 environments on the wire.
    assert(refusedBy("\xd7\xcd\x00\x00\x01\x00").?
        .says("invalid function - too many environments (256)"));

    // A funcdef is verified before it is handed back. This one declares no
    // flags, no slots, no constants and no bytecode, which is the smallest
    // well-formed header a stream can carry and still not be a function.
    assert(refusedBy("\xd7\x00\x00\x00\x00\x00\x00\x00\x00").?
        .says("funcdef has invalid bytecode"));
}

// ------------------------------------------------------------- the registry

fn theReverseRegistryShortCircuits() raise.Raising(void) {
    const rreg = c.janet_table(1);
    const a = c.janet_array(0);
    c.janet_table_put(rreg, c.janet_wrap_array(a), c.janet_csymbolv("an-array"));

    var b = try marshalled(c.janet_wrap_array(a), rreg, 0);
    // LB_REGISTRY, length, name.
    wireIs(b, "\xd8\x08an-array");

    // Without a forward table the name resolves to nil.
    assert(harness.isType(try unmarshalled(b, 0), c.JANET_NIL));

    const reg = c.janet_table(1);
    c.janet_table_put(reg, c.janet_csymbolv("an-array"), c.janet_wrap_array(a));
    const back = try marsh.unmarshal(b.data, @intCast(b.count), 0, reg, null);
    assert(c.janet_unwrap_array(back) == a);

    // A registry hit is still recorded as a reference, so a second occurrence
    // is a back-reference rather than a second name.
    const outer = c.janet_array(2);
    c.janet_array_push(outer, c.janet_wrap_array(a));
    c.janet_array_push(outer, c.janet_wrap_array(a));
    b = try marshalled(c.janet_wrap_array(outer), rreg, 0);
    wireIs(b, "\xd1\x02\xd8\x08an-array\xda\x01");
}

// -------------------------------------------------------- the environment API

fn anEntry(key: [*:0]const u8, value: c.Janet) c.Janet {
    const entry = c.janet_table(1);
    c.janet_table_put(entry, c.janet_ckeywordv(key), value);
    return c.janet_wrap_table(entry);
}

fn envLookupIntoPrefixesAndRecurses() void {
    const w = harness.wrapInteger;
    const proto = c.janet_table(2);
    c.janet_table_put(proto, c.janet_csymbolv("inherited"), anEntry("value", w(1)));

    const env = c.janet_table(4);
    env.*.proto = proto;
    c.janet_table_put(env, c.janet_csymbolv("plain"), anEntry("value", w(2)));
    c.janet_table_put(env, c.janet_csymbolv("by-ref"), anEntry("ref", w(3)));
    // A struct entry is read the same way a table entry is.
    const st = c.janet_struct_begin(1);
    c.janet_struct_put(st, c.janet_ckeywordv("value"), w(4));
    c.janet_table_put(env, c.janet_csymbolv("from-struct"), c.janet_wrap_struct(c.janet_struct_end(st)));
    // Anything else has no value at all, and a non-symbol key is skipped.
    c.janet_table_put(env, c.janet_csymbolv("opaque"), w(99));
    c.janet_table_put(env, c.janet_ckeywordv("not-a-symbol"), anEntry("value", w(5)));

    const flat = c.janet_table(0);
    c.janet_env_lookup_into(flat, env, null, 1);
    assert(harness.integerIs(c.janet_table_get(flat, c.janet_csymbolv("plain")), 2));
    assert(harness.integerIs(c.janet_table_get(flat, c.janet_csymbolv("by-ref")), 3));
    assert(harness.integerIs(c.janet_table_get(flat, c.janet_csymbolv("from-struct")), 4));
    assert(harness.integerIs(c.janet_table_get(flat, c.janet_csymbolv("inherited")), 1));
    assert(harness.isType(c.janet_table_get(flat, c.janet_csymbolv("opaque")), c.JANET_NIL));
    assert(harness.isType(c.janet_table_get(flat, c.janet_ckeywordv("not-a-symbol")), c.JANET_NIL));

    // Without recursion the prototype is not walked.
    const shallow = c.janet_table(0);
    c.janet_env_lookup_into(shallow, env, null, 0);
    assert(harness.integerIs(c.janet_table_get(shallow, c.janet_csymbolv("plain")), 2));
    assert(harness.isType(c.janet_table_get(shallow, c.janet_csymbolv("inherited")), c.JANET_NIL));

    // A prefix is prepended to the symbol, not to the entry.
    const prefixed = c.janet_table(0);
    c.janet_env_lookup_into(prefixed, env, "mod/", 1);
    assert(harness.integerIs(c.janet_table_get(prefixed, c.janet_csymbolv("mod/plain")), 2));
    assert(harness.integerIs(c.janet_table_get(prefixed, c.janet_csymbolv("mod/inherited")), 1));
    assert(harness.isType(c.janet_table_get(prefixed, c.janet_csymbolv("plain")), c.JANET_NIL));

    // An empty prefix is not the same code path as a null one, and gives the
    // same answer.
    const empty = c.janet_table(0);
    c.janet_env_lookup_into(empty, env, "", 1);
    assert(harness.integerIs(c.janet_table_get(empty, c.janet_csymbolv("plain")), 2));

    // `janet_env_lookup` is the recursive, unprefixed case with a fresh table.
    const made = c.janet_env_lookup(env);
    assert(harness.integerIs(c.janet_table_get(made, c.janet_csymbolv("inherited")), 1));
}

// -------------------------------------------------------------- truncation

/// Every read is bounds checked, and the check is what stops a corrupt stream
/// from reading past the buffer rather than merely producing a wrong value.
///
/// This is the section the C original's `BAIL_IF_RAISING` existed for: cutting
/// the stream at every offset drives a raise out of every read in
/// `probeUnmarshal` in turn, and a C callback that carried on past one would
/// read from beyond the end of the source.
fn aTruncatedStreamIsRefusedAtEveryLength() raise.Raising(void) {
    const probe = makeProbe();
    const a = c.janet_array(2);
    c.janet_array_push(a, c.janet_wrap_abstract(probe));
    c.janet_array_push(a, c.janet_cstringv("tail"));
    const whole = try marshalled(keep(c.janet_wrap_array(a)), null, 0);
    _ = keep(c.janet_wrap_buffer(whole));

    var len: usize = 0;
    while (len < @as(usize, @intCast(whole.count))) : (len += 1) {
        const refusal = harness.raised(unmarshalBytes, .{ whole.data[0..len], @as(c_int, 0) });
        if (refusal == null) {
            std.debug.print("prefix of {d} bytes unmarshalled without error\n", .{len});
            @panic("a truncated stream was accepted");
        }
        assert(refusal.?.signal == c.JANET_SIGNAL_ERROR);
    }
    // The whole thing is fine.
    assert(harness.isType(try unmarshalled(whole, 0), c.JANET_ARRAY));
}

fn theDiagnosticsNameAByteAndAnOffset() void {
    // The byte is rendered by `%x`, which reads a 64-bit argument from a call
    // that passes a 32-bit one in the C original -- see `FOUND.md`.
    assert(refusedBy("\xff").?.says("unknown byte ff at index 0"));
    assert(refusedBy("\xd1\x01\xff").?.says("unknown byte ff at index 2"));
    // A lead byte in [192, 200) is not an integer encoding.
    assert(refusedBy("\xd1\xc0").?.says("expected integer, got byte c0 at index 1"));
    // A count has to be a natural number.
    assert(refusedBy("\xd1\xbf\xff").?.says("expected integer >= 0, got -1"));
    assert(refusedBy("").?.says("unexpected end of source"));
}

/// A struct's prototype has to be a struct and a table's a table, and the
/// message names the type set rather than the type.
fn aPrototypeIsTypeChecked() void {
    assert(refusedBy("\xdf\x00\x00").?.says("expected type struct, got 0"));
    assert(refusedBy("\xd4\x00\x00").?.says("expected type table, got 0"));
}

// ------------------------------------------------------------------- fibers

/// A fiber is only ALIVE while it is running, so the refusal can only be
/// provoked from inside one.
fn aLiveFiberCannotBeMarshalled() raise.Raising(void) {
    var out = evaluate("(fn [] (marshal (fiber/current)))");
    var result = c.janet_wrap_nil();
    var fiber: [*c]c.JanetFiber = null;
    const sig = c.janet_pcall(c.janet_unwrap_function(out), 0, null, &result, &fiber);
    assert(sig == c.JANET_SIGNAL_ERROR);
    assert(harness.stringValueIs(result, "cannot marshal alive fiber"));

    // A suspended one round-trips, and the reader checks the frame arithmetic
    // the writer produced.
    out = evaluate("(fiber/new (fn [] (yield 1) 2))");
    const b = try marshalled(out, null, 0);
    assert(b.data[0] == lb_fiber);
    assert(harness.isType(try unmarshalled(b, 0), c.JANET_FIBER));

    assert(refusedBy("\xcc\x00\x01\x00\x00\x00").?.says("fiber has incorrect stack setup"));
    // A status field of 16 is one past `JANET_STATUS_ALIVE` and still inside
    // the six-bit status mask, so it survives every other check.
    assert(refusedBy("\xcc\xcd\x00\x10\x00\x00\x00\x04\x04\x04\xc9").?
        .says("invalid fiber status"));
}

// ---------------------------------------------------- what `next` reports

/// `cfun_unmarshal` drops the out-parameter, so this is the only caller that
/// can see where a value ended -- which is what makes a stream of concatenated
/// values readable at all.
fn nextPointsPastTheValue() raise.Raising(void) {
    const b = c.janet_buffer(16);
    try marsh.marshal(b, harness.wrapInteger(1), null, 0);
    const first: usize = @intCast(b.*.count);
    try marsh.marshal(b, c.janet_cstringv("second"), null, 0);

    var next: [*c]const u8 = null;
    const one = try marsh.unmarshal(b.*.data, @intCast(b.*.count), 0, null, &next);
    assert(harness.integerIs(one, 1));
    assert(next == b.*.data + first);

    const two = try marsh.unmarshal(next, @as(usize, @intCast(b.*.count)) - first, 0, null, &next);
    assert(harness.stringValueIs(two, "second"));
    assert(next == b.*.data + @as(usize, @intCast(b.*.count)));
}

// -------------------------------------------------------------------- entry

fn body() raise.Raising(void) {
    test_env = c.janet_core_env(null);
    c.janet_gcroot(c.janet_wrap_table(test_env));
    rooted = c.janet_array(0);
    c.janet_gcroot(c.janet_wrap_array(rooted));

    try registry.registerAbstractType(stored(&probe_at));
    try registry.registerAbstractType(stored(&refuser_at));
    try registry.registerAbstractType(stored(&twice_at));
    try registry.registerAbstractType(stored(&never_at));
    try registry.registerAbstractType(stored(&threaded_at));
    try registry.registerAbstractType(stored(&inert_at));
    try registry.registerAbstractType(stored(&toobig_at));

    try theThreeIntegerEncodings();
    try realsAndIntegralDoublesDiffer();
    try theSizeEncodingBoundaries();
    try theContextApiRoundTrips();
    try anAbstractCanContainItself();
    try theAbstractProtocolIsEnforced();
    try theUnsafeGateOnTheContextApi();
    try pointersAndCfunctionsNeedTheUnsafeFlag();
    try theWeakLeadBytesMoveWithTheEventLoop();
    try whenAValueBecomesAReference();
    aReferenceIndexIsBoundsChecked();
    try functionStreamsAndTheirBackReferences();
    try theReverseRegistryShortCircuits();
    envLookupIntoPrefixesAndRecurses();
    try aTruncatedStreamIsRefusedAtEveryLength();
    theDiagnosticsNameAByteAndAnOffset();
    aPrototypeIsTypeChecked();
    try aLiveFiberCannotBeMarshalled();
    try nextPointsPastTheValue();
}

pub fn run() void {
    _ = c.janet_init();
    body() catch @panic("marsh: an entry point raised unexpectedly");
    c.janet_deinit();

    std.debug.print("marsh contract ok\n", .{});
}
