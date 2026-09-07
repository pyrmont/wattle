//! Behavioral contract for the marshalling protocol.
//!
//! The reason this file exists rather than leaning on `test/suite-marsh.janet`:
//! the suite reaches `marshal` and `unmarshal`, and those two cfunctions use a
//! strict subset of the subsystem. Everything below is either unreachable from
//! Janet or unobservable there.
//!
//!  - `JANET_MARSHAL_UNSAFE` has no Janet spelling. `cfun_marshal` never sets
//!    it and `cfun_unmarshal` passes a hard zero, so five of the twenty-nine
//!    lead bytes are reachable only from a caller inside the runtime:
//!    pointers, cfunctions, pointer-backed buffers and threaded abstracts.
//!  - The twenty-function marshal context API is called from an abstract
//!    type's `marshal` and `unmarshal` callbacks and from nowhere else. The
//!    core types that have such callbacks exercise four of the twenty between
//!    them.
//!  - `marsh.envLookupInto`'s `prefix` and `recurse` parameters are both
//!    fixed by `marsh.envLookup`, which is what `env-lookup` calls.
//!  - `unmarshal`'s `next` out-parameter is dropped by `cfun_unmarshal`.
//!
//! The wire format is the other reason. A marshalled stream is a file format,
//! so its bytes are the contract rather than an implementation detail, and the
//! assertions below are written against literal bytes for that reason.
//!
//! ## The probe type's callbacks are written here
//!
//! `abstract_type.zig` types `marshal`, `unmarshal`, `get`, `put`, `next`,
//! `call` and `tostring` as raising, and this file writes each one as an
//! ordinary Zig function. Every read inside `probeUnmarshal` is a `try`, which
//! matters because the truncation section below cuts the stream at every
//! offset: a read that continued past a refusal would walk off the end.
//!
//! `marshalSize` is raising for the same reason, and the assertions below
//! cover it: a callback that reached only a reporting form of it would turn a
//! buffer refusing to grow into a report nobody consumes.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const abstract_type = subsystems.abstract_type;
const abstracts = @import("subsystems").value.abstracts;
const arrays = @import("subsystems").value.arrays;
const buffers = @import("subsystems").value.buffers;
const constants = @import("constants");
const core_env = @import("subsystems").env;
const expect = @import("expect.zig").expect;
const fibers = @import("subsystems").value.fibers;
const gc_alloc = @import("subsystems").gc_alloc;
const harness = @import("harness.zig");
const marsh = subsystems.marsh;
const raise = @import("subsystems").raise;
const registry = subsystems.registry;
const repr = @import("repr");
const structs = @import("subsystems").value.structs;
const subsystems = @import("subsystems");
const tables = @import("subsystems").value.tables;
const value = @import("subsystems").value;
const vm_entry = @import("subsystems").vm_entry;
const vm_lifecycle = @import("subsystems").lifecycle;
const wrap = @import("subsystems").value.wrap;

// ==========================================================================
// Constants
// ==========================================================================

/// A type with no callbacks at all, which is what makes a value
/// unmarshallable rather than merely unregistered.
const inert_at = abstract_type.define(anyopaque, .{ .name = "test/marsh-inert" });
const lb_abstract: u8 = 217;
const lb_fiber: u8 = 204;
const lb_funcdef_ref: u8 = 220;
const lb_funcenv_ref: u8 = 219;
const lb_real: u8 = 200;
const lb_symbol: u8 = 207;
const lb_unsafe_cfunction: u8 = 221;
const lb_unsafe_pointer: u8 = 222;

/// The seven weak-container lead bytes are 226 through 232, and they are that
/// in every configuration. The event loop is a feature flag and a lead byte is
/// a wire format, so a build that cannot produce a threaded abstract still
/// gives 224 and 225 away rather than reusing them.
///
/// The number is written here rather than read from `marsh.zig`, which is what
/// makes this a check: the subject and the oracle are independently derived.
const lb_weak_base: u8 = 226;

const never_at = abstract_type.define(anyopaque, .{
    .name = "test/marsh-never",
    .marshal = protocolMarshal,
    .unmarshal = neverUnmarshal,
});

const probe_at = abstract_type.define(Probe, .{
    .name = "test/marsh-probe",
    .marshal = probeMarshal,
    .unmarshal = probeUnmarshal,
});

const refuser_at = abstract_type.define(anyopaque, .{
    .name = "test/marsh-refuser",
    .marshal = refuserMarshal,
    .unmarshal = refuserUnmarshal,
});

/// Values a `Janet` local would not keep alive. The probe types have no
/// `gcmark`, so nothing reachable only from an abstract is a root either.
var rooted: *arrays.Array = undefined;
var test_env: *tables.Table = undefined;

const toobig_at = abstract_type.define(anyopaque, .{
    .name = "test/marsh-toobig",
    .marshal = toobigMarshal,
});

const twice_at = abstract_type.define(anyopaque, .{
    .name = "test/marsh-twice",
    .marshal = protocolMarshal,
    .unmarshal = twiceUnmarshal,
});

// ==========================================================================
// Aliased types
// ==========================================================================

const AbstractType = abstract_type.AbstractType;

// ==========================================================================
// Types
// ==========================================================================

const Probe = extern struct {
    i32_field: i32,
    i64_field: i64,
    sz: usize,
    byte: u8,
    bytes: [4]u8,
    value: repr.Value,
    ptr: ?*anyopaque,
};

// ==========================================================================
// Cases
// ==========================================================================

fn keep(val: repr.Value) repr.Value {
    harness.arrayPush(rooted, val);
    return val;
}

/// A buffer's contents against a literal, with both rendered on a mismatch.
///
/// A byte-string comparison that printed both sides and then
/// `expect(0)`. Kept, because a wire-format failure is unreadable without
/// them: the assertion that fires says only that two buffers differ.
fn wireIs(b: *buffers.Buffer, expected: []const u8) void {
    const got = b.slice();
    if (std.mem.eql(u8, got, expected)) return;
    std.debug.print("expected {d} bytes:", .{expected.len});
    for (expected) |byte| std.debug.print(" {x:0>2}", .{byte});
    std.debug.print("\n     got {d} bytes:", .{got.len});
    for (got) |byte| std.debug.print(" {x:0>2}", .{byte});
    std.debug.print("\n", .{});
    @panic("wire format mismatch");
}

fn marshalled(x: repr.Value, rreg: ?*tables.Table, flags: c_int) raise.Raising(*buffers.Buffer) {
    const b = buffers.new(16);
    try marsh.marshal(b, x, rreg, flags);
    return b;
}

fn unmarshalled(b: *buffers.Buffer, flags: c_int) raise.Raising(repr.Value) {
    return marsh.unmarshal(b.slice(), flags, null, null);
}

/// `unmarshal` over a literal, which is how every crafted stream below is
/// spelled. Slices rather than pointer-and-length: the length of a Zig string
/// literal is part of it, and a length taken from the literal's own size at
/// every site to say the same thing.
fn unmarshalBytes(bytes: []const u8, flags: c_int) raise.Raising(repr.Value) {
    return marsh.unmarshal(bytes, flags, null, null);
}

/// The refusal a crafted stream produced, or null if it was accepted.
fn refusedBy(bytes: []const u8) ?harness.Raise {
    return harness.raised(unmarshalBytes, .{ bytes, @as(c_int, 0) });
}

/// One abstract type's callbacks, between them driving every entry point of
/// the context API, so that a round trip through the probe is a round trip
/// through all twenty. The pointer fields are written only in unsafe mode,
/// which is what makes this type a witness for the context's `flags` field.
fn probeMarshal(probe: *Probe, m: *abi.Marshal) raise.Raising(void) {
    marsh.marshalAbstract(m, probe);
    try marsh.marshalInt(m, probe.i32_field);
    try marsh.marshalInt64(m, probe.i64_field);
    try marsh.marshalSize(m, probe.sz);
    try marsh.marshalByte(m, probe.byte);
    try marsh.marshalBytes(m, &probe.bytes);
    try marsh.marshalJanet(m, probe.value);
    const unsafe = (marsh.marshalFlags(m) & constants.JANET_MARSHAL_UNSAFE) != 0;
    try marsh.marshalByte(m, @intFromBool(unsafe));
    if (unsafe) try marsh.marshalPtr(m, probe.ptr);
}

/// Every read is a `try`, so a refusal stops the walk where it happens rather
/// than at the next read that ran past the end.
fn probeUnmarshal(u: *abi.Unmarshal) raise.Raising(*Probe) {
    const probe: *Probe = @ptrCast(@alignCast(try marsh.unmarshalAbstract(u, @sizeOf(Probe))));
    probe.i32_field = try marsh.unmarshalInt(u);
    probe.i64_field = try marsh.unmarshalInt64(u);
    probe.sz = try marsh.unmarshalSize(u);
    try marsh.unmarshalEnsure(u, 1);
    probe.byte = try marsh.unmarshalByte(u);
    try marsh.unmarshalBytes(u, &probe.bytes, probe.bytes.len);
    probe.value = try marsh.unmarshalJanet(u);
    probe.ptr = null;
    const unsafe = try marsh.unmarshalByte(u);
    if (unsafe != 0) {
        expect((marsh.unmarshalFlags(u) & constants.JANET_MARSHAL_UNSAFE) != 0);
        probe.ptr = try marsh.unmarshalPtr(u);
    }
    return probe;
}

/// A type that always reaches for a pointer, so that the safe-mode refusal has
/// something to refuse.
fn refuserMarshal(p: *anyopaque, m: *abi.Marshal) raise.Raising(void) {
    marsh.marshalAbstract(m, p);
    try marsh.marshalPtr(m, p);
}

fn refuserUnmarshal(u: *abi.Unmarshal) raise.Raising(*anyopaque) {
    const p = (try marsh.unmarshalAbstract(u, @sizeOf(i32))).?;
    _ = try marsh.unmarshalPtr(u);
    return p;
}

/// A type that writes more bytes than a Janet buffer can index.
fn toobigMarshal(p: *anyopaque, m: *abi.Marshal) raise.Raising(void) {
    marsh.marshalAbstract(m, p);
    const bytes: [*]const u8 = @ptrCast(p);
    try marsh.marshalBytes(m, bytes[0 .. @as(usize, std.math.maxInt(i32)) + 1]);
}

/// The marshal half of the three types whose *unmarshal* half breaks the
/// abstract protocol.
fn protocolMarshal(p: *anyopaque, m: *abi.Marshal) raise.Raising(void) {
    marsh.marshalAbstract(m, p);
    try marsh.marshalByte(m, @as(*u8, @ptrCast(p)).*);
}

/// Registers itself twice.
fn twiceUnmarshal(u: *abi.Unmarshal) raise.Raising(*anyopaque) {
    const p = (try marsh.unmarshalAbstract(u, 1)).?;
    try marsh.unmarshalAbstractReuse(u, p);
    return p;
}

/// Never registers at all.
fn neverUnmarshal(u: *abi.Unmarshal) raise.Raising(*anyopaque) {
    _ = try marsh.unmarshalByte(u);
    return abstracts.newFor(Probe, &probe_at);
}

fn stored(at: *const AbstractType) *const abi.AbstractType {
    return at;
}

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
        expect(harness.integerIs(try unmarshalBytes(case.bytes, 0), case.value));
    }
}

/// A double that is not an exact int32 takes the eight-byte path and is
/// recorded as a reference; an integral one never is.
fn realsAndIntegralDoublesDiffer() raise.Raising(void) {
    var b = try marshalled(wrap.fromNumber(0.5), null, 0);
    expect(b.count == 9);
    expect(b.slice()[0] == lb_real);
    expect(wrap.toNumber(try unmarshalled(b, 0)) == 0.5);

    wireIs(try marshalled(wrap.fromNumber(3.0), null, 0), "\x03");

    // 2^31 is integral and outside int32, so it is a real.
    b = try marshalled(wrap.fromNumber(2147483648.0), null, 0);
    expect(b.count == 9 and b.slice()[0] == lb_real);
    expect(wrap.toNumber(try unmarshalled(b, 0)) == 2147483648.0);
}

/// `push64` is length-prefixed above 0xF0 and bare below it, and only the
/// context API reaches it.
fn theSizeEncodingBoundaries() raise.Raising(void) {
    const values = [_]u64{
        0,          1,          0xEF,               0xF0, 0xF1, 0xFF, 0x100, 0xFFFFFFFF,
        0x01020304, 0x05060708, 0xFFFFFFFFFFFFFFFF,
    };
    for (values) |val| {
        const probe: *Probe = @ptrCast(@alignCast(abstracts.newBytes(stored(&probe_at), @sizeOf(Probe))));
        probe.* = std.mem.zeroes(Probe);
        probe.i64_field = @bitCast(val);
        probe.sz = @truncate(val);
        probe.value = wrap.fromNil();
        const b = try marshalled(keep(wrap.fromAbstract(probe)), null, 0);
        const back: *Probe = @ptrCast(@alignCast(wrap.toAbstract(try unmarshalled(b, 0))));
        expect(@as(u64, @bitCast(back.i64_field)) == val);
        expect(back.sz == @as(usize, @truncate(val)));
    }

    // The prefix byte counts the bytes that follow, little endian.
    const probe: *Probe = @ptrCast(@alignCast(abstracts.newBytes(stored(&probe_at), @sizeOf(Probe))));
    probe.* = std.mem.zeroes(Probe);
    probe.i64_field = 0x0102;
    probe.value = wrap.fromNil();
    const b = try marshalled(keep(wrap.fromAbstract(probe)), null, 0);
    // ...LB_ABSTRACT, name, i32 = 0, then the int64.
    const tail = 3 // the i64: prefix and two bytes
        + 1 // sz, zero
        + 1 // byte
        + 4 // bytes
        + 1 // value: nil
        + 1; // the unsafe marker
    const at = b.data.? + @as(usize, @intCast(b.count)) - tail;
    expect(at[0] == 0xF2 and at[1] == 0x02 and at[2] == 0x01);

    // Nine bytes of length is not a 64-bit integer.
    expect(refusedBy("\xf9\x00\x00\x00\x00\x00\x00\x00\x00\x00").?.says("unknown byte f9 at index 0"));
}

fn makeProbe() *Probe {
    const probe: *Probe = @ptrCast(@alignCast(abstracts.newBytes(stored(&probe_at), @sizeOf(Probe))));
    probe.i32_field = -12345;
    probe.i64_field = -0x0102030405060708;
    probe.sz = 0x1234;
    probe.byte = 0xAB;
    probe.bytes = "wxyz".*;
    probe.value = value.fromBytes("payload", .string);
    probe.ptr = @ptrCast(@constCast(stored(&probe_at)));
    _ = keep(wrap.fromAbstract(probe));
    return probe;
}

fn theContextApiRoundTrips() raise.Raising(void) {
    const probe = makeProbe();
    var b = try marshalled(wrap.fromAbstract(probe), null, 0);
    const out = keep(try unmarshalled(b, 0));
    expect(harness.isType(out, repr.Tag.abstract));
    expect(abi.abstractHead(wrap.toAbstract(out)).type == stored(&probe_at));
    var back: *Probe = @ptrCast(@alignCast(wrap.toAbstract(out)));
    expect(back != probe);
    expect(back.i32_field == probe.i32_field);
    expect(back.i64_field == probe.i64_field);
    expect(back.sz == probe.sz);
    expect(back.byte == probe.byte);
    expect(std.mem.eql(u8, &back.bytes, "wxyz"));
    expect(harness.equals(back.value, probe.value));
    // Safe mode: the pointer was not written, so it does not come back.
    expect(back.ptr == null);

    // Unsafe mode lets it through.
    b = try marshalled(wrap.fromAbstract(probe), null, constants.JANET_MARSHAL_UNSAFE);
    back = @ptrCast(@alignCast(wrap.toAbstract(
        keep(try unmarshalled(b, constants.JANET_MARSHAL_UNSAFE)),
    )));
    expect(back.ptr == @as(?*anyopaque, @ptrCast(@constCast(stored(&probe_at)))));

    // The stream opens with LB_ABSTRACT and the type's name as a symbol.
    const name = probe_at.name;
    expect(b.slice()[0] == lb_abstract);
    expect(b.slice()[1] == lb_symbol);
    expect(b.slice()[2] == name.len);
    expect(std.mem.eql(u8, b.slice()[3 .. 3 + name.len], name));
}

/// The abstract is entered into the reference table before its fields are
/// read, so a value that contains itself resolves rather than recursing.
fn anAbstractCanContainItself() raise.Raising(void) {
    const probe = makeProbe();
    const self = wrap.fromAbstract(probe);
    const holder = arrays.new(1);
    harness.arrayPush(holder, self);
    probe.value = wrap.fromArray(holder);

    const b = try marshalled(self, null, 0);
    const back: *Probe = @ptrCast(@alignCast(wrap.toAbstract(keep(try unmarshalled(b, 0)))));
    expect(harness.isType(back.value, repr.Tag.array));
    const back_holder = wrap.toArray(back.value);
    expect(back_holder.count == 1);
    expect(wrap.toAbstract(back_holder.slice()[0]) == @as(?*anyopaque, back));
}

fn theAbstractProtocolIsEnforced() raise.Raising(void) {
    const twice: *u8 = @ptrCast(abstracts.newBytes(stored(&twice_at), 1));
    twice.* = 7;
    var b = try marshalled(keep(wrap.fromAbstract(twice)), null, 0);
    expect(harness.raised(unmarshalled, .{ b, @as(c_int, 0) }).?
        .says("janet_unmarshal_abstract called more than once"));

    const never: *u8 = @ptrCast(abstracts.newBytes(stored(&never_at), 1));
    never.* = 7;
    b = try marshalled(keep(wrap.fromAbstract(never)), null, 0);
    expect(harness.raised(unmarshalled, .{ b, @as(c_int, 0) }).?
        .says("janet_unmarshal_abstract not called"));

    const inert: *i32 = @ptrCast(@alignCast(abstracts.newBytes(stored(&inert_at), @sizeOf(i32))));
    inert.* = 7;
    expect(harness.raised(
        marshalled,
        .{ keep(wrap.fromAbstract(inert)), @as(?*tables.Table, null), @as(c_int, 0) },
    ).?.beginsWith("cannot marshal <test/marsh-inert 0x"));
}

fn theUnsafeGateOnTheContextApi() raise.Raising(void) {
    const refuser = keep(wrap.fromAbstract(abstracts.newBytes(stored(&refuser_at), @sizeOf(i32))));
    expect(harness.raised(
        marshalled,
        .{ refuser, @as(?*tables.Table, null), @as(c_int, 0) },
    ).?.says("can only marshal pointers in unsafe mode"));

    const b = try marshalled(refuser, null, constants.JANET_MARSHAL_UNSAFE);
    expect(harness.raised(unmarshalled, .{ b, @as(c_int, 0) }).?
        .says("can only unmarshal pointers in unsafe mode"));
    // And succeeds when the flag is given.
    expect(harness.isType(try unmarshalled(b, constants.JANET_MARSHAL_UNSAFE), repr.Tag.abstract));

    // A length that cannot be a buffer index is refused before anything is
    // read from it.
    const toobig = keep(wrap.fromAbstract(abstracts.newBytes(stored(&toobig_at), @sizeOf(i32))));
    expect(harness.raised(
        marshalled,
        .{ toobig, @as(?*tables.Table, null), @as(c_int, 0) },
    ).?.says("size_t too large to fit in buffer"));
}

/// A cfunction that exists to be a value with an address.
///
/// `align(corefn.alignment)` for `test/registry.zig`'s reason: nanbox-64 with
/// a pointer shift steals the low bits of a cfunction pointer, and
/// `-Dnanbox-pointer-shift=2` is a matrix entry.
fn aCfunction(argv: []repr.Value) align(@import("subsystems").corefn.alignment) raise.Raising(repr.Value) {
    _ = @as(i32, @intCast(argv.len));

    return harness.wrapInteger(1729);
}

fn pointersAndCfunctionsNeedTheUnsafeFlag() raise.Raising(void) {
    const ptr = wrap.fromPointer(@ptrCast(@constCast(stored(&probe_at))));
    const cfun = wrap.fromCfunction(raise.stored(&aCfunction));

    expect(harness.raised(marshalled, .{ ptr, @as(?*tables.Table, null), @as(c_int, 0) }).?
        .beginsWith("no registry value and cannot marshal <pointer 0x"));
    expect(harness.raised(marshalled, .{ cfun, @as(?*tables.Table, null), @as(c_int, 0) }).?
        .beginsWith("no registry value and cannot marshal <cfunction 0x"));

    var b = try marshalled(ptr, null, constants.JANET_MARSHAL_UNSAFE);
    expect(b.slice()[0] == lb_unsafe_pointer);
    expect(b.count == 1 + @sizeOf(*anyopaque));
    expect(wrap.toPointer(try unmarshalled(b, constants.JANET_MARSHAL_UNSAFE)) ==
        @as(?*anyopaque, @ptrCast(@constCast(stored(&probe_at)))));
    expect(harness.raised(unmarshalled, .{ b, @as(c_int, 0) }).?
        .says("unsafe flag not given, will not unmarshal raw pointer at index 1"));

    b = try marshalled(cfun, null, constants.JANET_MARSHAL_UNSAFE);
    expect(b.slice()[0] == lb_unsafe_cfunction);
    const back = try unmarshalled(b, constants.JANET_MARSHAL_UNSAFE);
    expect(wrap.toCfunction(back) == raise.stored(&aCfunction));
    expect(harness.raised(unmarshalled, .{ b, @as(c_int, 0) }).?
        .says("unsafe flag not given, will not unmarshal function pointer at index 1"));
}

fn theWeakLeadBytesAreTheSameInEveryConfiguration() raise.Raising(void) {
    const weakk = tables.weakk(1);
    const weakv = tables.weakv(1);
    const weakkv = tables.weakkv(1);
    const weak_array = arrays.weak(0);

    expect((try marshalled(wrap.fromTable(weakk), null, 0)).slice()[0] == lb_weak_base + 0);
    expect((try marshalled(wrap.fromTable(weakv), null, 0)).slice()[0] == lb_weak_base + 1);
    expect((try marshalled(wrap.fromTable(weakkv), null, 0)).slice()[0] == lb_weak_base + 2);
    expect((try marshalled(wrap.fromArray(weak_array), null, 0)).slice()[0] == lb_weak_base + 6);

    weakk.proto = tables.new(0);
    weakv.proto = tables.new(0);
    weakkv.proto = tables.new(0);
    expect((try marshalled(wrap.fromTable(weakk), null, 0)).slice()[0] == lb_weak_base + 3);
    expect((try marshalled(wrap.fromTable(weakv), null, 0)).slice()[0] == lb_weak_base + 4);
    expect((try marshalled(wrap.fromTable(weakkv), null, 0)).slice()[0] == lb_weak_base + 5);

    // And each comes back as the same flavour of weak container.
    var b = try marshalled(wrap.fromArray(weak_array), null, 0);
    var back = try unmarshalled(b, 0);
    expect(harness.isType(back, repr.Tag.array));
    b = try marshalled(wrap.fromTable(weakkv), null, 0);
    back = try unmarshalled(b, 0);
    expect(harness.isType(back, repr.Tag.table));
    expect(wrap.toTable(back).proto != null);
}

/// A tuple and a struct are marked seen *after* their contents are written and
/// everything else before, which decides whether a self-reference is
/// expressible at all.
fn whenAValueBecomesAReference() raise.Raising(void) {
    const a = arrays.new(1);
    harness.arrayPush(a, wrap.fromArray(a));
    var b = try marshalled(keep(wrap.fromArray(a)), null, 0);
    // LB_ARRAY, count 1, then LB_REFERENCE 0.
    wireIs(b, "\xd1\x01\xda\x00");
    var back_a = wrap.toArray(keep(try unmarshalled(b, 0)));
    expect(back_a.count == 1 and wrap.toArray(back_a.slice()[0]) == back_a);

    // The same array twice is one reference and one back-reference.
    const outer = arrays.new(2);
    const inner = arrays.new(0);
    harness.arrayPush(outer, wrap.fromArray(inner));
    harness.arrayPush(outer, wrap.fromArray(inner));
    b = try marshalled(keep(wrap.fromArray(outer)), null, 0);
    wireIs(b, "\xd1\x02\xd1\x00\xda\x01");
    back_a = wrap.toArray(keep(try unmarshalled(b, 0)));
    expect(wrap.toArray(back_a.slice()[0]) == wrap.toArray(back_a.slice()[1]));

    // With cycles switched off nothing is recorded, so the same array is
    // written twice and the copies come back distinct.
    b = try marshalled(wrap.fromArray(outer), null, constants.JANET_MARSHAL_NO_CYCLES);
    wireIs(b, "\xd1\x02\xd1\x00\xd1\x00");
    back_a = wrap.toArray(keep(try unmarshalled(b, 0)));
    expect(wrap.toArray(back_a.slice()[0]) != wrap.toArray(back_a.slice()[1]));

    // And a cyclic value has nothing to stop it but the recursion guard.
    expect(harness.raised(marshalled, .{
        wrap.fromArray(a),
        @as(?*tables.Table, null),
        @as(c_int, constants.JANET_MARSHAL_NO_CYCLES),
    }).?.says("stack overflow"));
}

fn aReferenceIndexIsBoundsChecked() void {
    expect(refusedBy("\xda\x00").?.says("invalid reference 0"));
    // Neither of the other two reference bytes is a lead byte: a funcenv
    // reference is only read where a funcenv is expected, and a funcdef
    // reference where a funcdef is.
    expect(refusedBy("\xdb\x00").?.says("unknown byte db at index 0"));
    expect(refusedBy("\xdc\x00").?.says("unknown byte dc at index 0"));
    // A function with no environments, whose funcdef is a reference into an
    // empty table.
    expect(refusedBy("\xd7\x00\xdc\x00").?.says("invalid funcdef reference 0"));
}

fn onlyIndexOf(b: *buffers.Buffer, lead: u8) i32 {
    var found: i32 = -1;
    var i: i32 = 0;
    while (i < b.count) : (i += 1) {
        if (b.slice()[@intCast(i)] != lead) continue;
        expect(found < 0); // expected exactly one occurrence of this lead byte
        found = i;
    }
    expect(found >= 0); // expected this lead byte to appear
    return found;
}

fn callThunk(f: repr.Value) i32 {
    var fiber: ?*fibers.Fiber = null;
    const resumed = vm_entry.pcall(wrap.toFunction(f), &.{}, &fiber);
    expect(resumed.signal == abi.Signal.ok);
    return wrap.toInteger(resumed.value);
}

fn evaluate(source: [*:0]const u8) repr.Value {
    var out: repr.Value = undefined;
    expect(core_env.dostring(test_env, source, "marsh-test", &out) == 0);
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
    _ = keep(wrap.fromBuffer(b));
    var at = onlyIndexOf(b, lb_funcenv_ref);
    var closures = keep(try unmarshalled(b, 0));
    var back = wrap.toTuple(closures);
    expect(callThunk(back[0]) == 41);
    expect(callThunk(back[1]) == 42);
    b.slice()[@intCast(at + 1)] = 0x7f;
    expect(harness.raised(unmarshalled, .{ b, @as(c_int, 0) }).?
        .says("invalid funcenv reference 127"));

    // Two instances of one `fn` share a funcdef, and only the second is a back
    // reference; the closed-over values are still written twice.
    out = evaluate("(tuple ;(map (fn [x] (fn [] x)) [7 8]))");
    b = try marshalled(out, null, 0);
    _ = keep(wrap.fromBuffer(b));
    at = onlyIndexOf(b, lb_funcdef_ref);
    closures = keep(try unmarshalled(b, 0));
    back = wrap.toTuple(closures);
    expect(callThunk(back[0]) == 7);
    expect(callThunk(back[1]) == 8);
    b.slice()[@intCast(at + 1)] = 0x7f;
    expect(harness.raised(unmarshalled, .{ b, @as(c_int, 0) }).?
        .says("invalid funcdef reference 127"));

    // A function has at most 255 environments on the wire.
    expect(refusedBy("\xd7\xcd\x00\x00\x01\x00").?
        .says("invalid function - too many environments (256)"));

    // A funcdef is verified before it is handed back. This one declares no
    // flags, no slots, no constants and no bytecode, which is the smallest
    // well-formed header a stream can have and still not be a function.
    expect(refusedBy("\xd7\x00\x00\x00\x00\x00\x00\x00\x00").?
        .says("funcdef has invalid bytecode"));
}

fn theReverseRegistryShortCircuits() raise.Raising(void) {
    const rreg = tables.new(1);
    const a = arrays.new(0);
    tables.put(rreg, wrap.fromArray(a), value.fromBytes("an-array", .symbol));

    var b = try marshalled(wrap.fromArray(a), rreg, 0);
    // LB_REGISTRY, length, name.
    wireIs(b, "\xd8\x08an-array");

    // Without a forward table the name resolves to nil.
    expect(harness.isType(try unmarshalled(b, 0), repr.Tag.nil));

    const reg = tables.new(1);
    tables.put(reg, value.fromBytes("an-array", .symbol), wrap.fromArray(a));
    const back = try marsh.unmarshal(b.slice(), 0, reg, null);
    expect(wrap.toArray(back) == a);

    // A registry hit is still recorded as a reference, so a second occurrence
    // is a back-reference rather than a second name.
    const outer = arrays.new(2);
    harness.arrayPush(outer, wrap.fromArray(a));
    harness.arrayPush(outer, wrap.fromArray(a));
    b = try marshalled(wrap.fromArray(outer), rreg, 0);
    wireIs(b, "\xd1\x02\xd8\x08an-array\xda\x01");
}

fn anEntry(key: [*:0]const u8, val: repr.Value) repr.Value {
    const entry = tables.new(1);
    tables.put(entry, value.fromBytes(std.mem.span(key), .keyword), val);
    return wrap.fromTable(entry);
}

fn envLookupIntoPrefixesAndRecurses() void {
    const w = harness.wrapInteger;
    const proto = tables.new(2);
    tables.put(proto, value.fromBytes("inherited", .symbol), anEntry("value", w(1)));

    const env = tables.new(4);
    env.proto = proto;
    tables.put(env, value.fromBytes("plain", .symbol), anEntry("value", w(2)));
    tables.put(env, value.fromBytes("by-ref", .symbol), anEntry("ref", w(3)));
    // A struct entry is read the same way a table entry is.
    const st = structs.begin(1);
    structs.put(st, value.fromBytes("value", .keyword), w(4));
    tables.put(env, value.fromBytes("from-struct", .symbol), wrap.fromStruct(structs.end(st)));
    // Anything else has no value at all, and a non-symbol key is skipped.
    tables.put(env, value.fromBytes("opaque", .symbol), w(99));
    tables.put(env, value.fromBytes("not-a-symbol", .keyword), anEntry("value", w(5)));

    const flat = tables.new(0);
    marsh.envLookupInto(flat, env, null, 1);
    expect(harness.integerIs(tables.get(flat, value.fromBytes("plain", .symbol)), 2));
    expect(harness.integerIs(tables.get(flat, value.fromBytes("by-ref", .symbol)), 3));
    expect(harness.integerIs(tables.get(flat, value.fromBytes("from-struct", .symbol)), 4));
    expect(harness.integerIs(tables.get(flat, value.fromBytes("inherited", .symbol)), 1));
    expect(harness.isType(tables.get(flat, value.fromBytes("opaque", .symbol)), repr.Tag.nil));
    expect(harness.isType(tables.get(flat, value.fromBytes("not-a-symbol", .keyword)), repr.Tag.nil));

    // Without recursion the prototype is not walked.
    const shallow = tables.new(0);
    marsh.envLookupInto(shallow, env, null, 0);
    expect(harness.integerIs(tables.get(shallow, value.fromBytes("plain", .symbol)), 2));
    expect(harness.isType(tables.get(shallow, value.fromBytes("inherited", .symbol)), repr.Tag.nil));

    // A prefix is prepended to the symbol, not to the entry.
    const prefixed = tables.new(0);
    marsh.envLookupInto(prefixed, env, "mod/", 1);
    expect(harness.integerIs(tables.get(prefixed, value.fromBytes("mod/plain", .symbol)), 2));
    expect(harness.integerIs(tables.get(prefixed, value.fromBytes("mod/inherited", .symbol)), 1));
    expect(harness.isType(tables.get(prefixed, value.fromBytes("plain", .symbol)), repr.Tag.nil));

    // An empty prefix is not the same code path as a null one, and gives the
    // same result.
    const empty = tables.new(0);
    marsh.envLookupInto(empty, env, "", 1);
    expect(harness.integerIs(tables.get(empty, value.fromBytes("plain", .symbol)), 2));

    // `marsh.envLookup` is the recursive, unprefixed case with a fresh table.
    const made = marsh.envLookup(env);
    expect(harness.integerIs(tables.get(made, value.fromBytes("inherited", .symbol)), 1));
}

/// Every read is bounds checked, and the check is what stops a corrupt stream
/// from reading past the buffer rather than merely producing a wrong value.
///
/// Cutting
/// the stream at every offset drives a raise out of every read in
/// `probeUnmarshal` in turn, and a callback that continued past one would
/// read from beyond the end of the source.
fn aTruncatedStreamIsRefusedAtEveryLength() raise.Raising(void) {
    const probe = makeProbe();
    const a = arrays.new(2);
    harness.arrayPush(a, wrap.fromAbstract(probe));
    harness.arrayPush(a, value.fromBytes("tail", .string));
    const whole = try marshalled(keep(wrap.fromArray(a)), null, 0);
    _ = keep(wrap.fromBuffer(whole));

    var len: usize = 0;
    while (len < @as(usize, @intCast(whole.count))) : (len += 1) {
        const refusal = harness.raised(unmarshalBytes, .{ whole.slice()[0..len], @as(c_int, 0) });
        if (refusal == null) {
            std.debug.print("prefix of {d} bytes unmarshalled without error\n", .{len});
            @panic("a truncated stream was accepted");
        }
        expect(refusal.?.signal == abi.Signal.@"error");
    }
    // The whole thing is fine.
    expect(harness.isType(try unmarshalled(whole, 0), repr.Tag.array));
}

fn theDiagnosticsNameAByteAndAnOffset() void {
    // The byte is rendered by `%x`, which takes 64 bits and rejects a narrower
    // or signed argument at compile time.
    expect(refusedBy("\xff").?.says("unknown byte ff at index 0"));
    expect(refusedBy("\xd1\x01\xff").?.says("unknown byte ff at index 2"));
    // A lead byte in [192, 200) is not an integer encoding.
    expect(refusedBy("\xd1\xc0").?.says("expected integer, got byte c0 at index 1"));
    // A count has to be a natural number.
    expect(refusedBy("\xd1\xbf\xff").?.says("expected integer >= 0, got -1"));
    expect(refusedBy("").?.says("unexpected end of source"));
}

/// A struct's prototype has to be a struct and a table's a table, and the
/// message names the type set rather than the type.
fn aPrototypeIsTypeChecked() void {
    expect(refusedBy("\xdf\x00\x00").?.says("expected type struct, got 0"));
    expect(refusedBy("\xd4\x00\x00").?.says("expected type table, got 0"));
}

/// A fiber is only ALIVE while it is running, so the refusal can only be
/// provoked from inside one.
fn aLiveFiberCannotBeMarshalled() raise.Raising(void) {
    var out = evaluate("(fn [] (marshal (fiber/current)))");
    var fiber: ?*fibers.Fiber = null;
    const resumed = vm_entry.pcall(wrap.toFunction(out), &.{}, &fiber);
    expect(resumed.signal == abi.Signal.@"error");
    expect(harness.stringValueIs(resumed.value, "cannot marshal alive fiber"));

    // A suspended one round-trips, and the reader checks the frame arithmetic
    // the writer produced.
    out = evaluate("(fiber/new (fn [] (yield 1) 2))");
    const b = try marshalled(out, null, 0);
    expect(b.slice()[0] == lb_fiber);
    expect(harness.isType(try unmarshalled(b, 0), repr.Tag.fiber));

    expect(refusedBy("\xcc\x00\x01\x00\x00\x00").?.says("fiber has incorrect stack setup"));
    // A status field of 16 is one past the last `FiberStatus` and still inside
    // the six-bit status mask, so it survives every other check.
    expect(refusedBy("\xcc\xcd\x00\x10\x00\x00\x00\x04\x04\x04\xc9").?
        .says("invalid fiber status"));
}

/// `cfun_unmarshal` drops the out-parameter, so this is the only caller that
/// can see where a value ended, which is what makes a stream of concatenated
/// values readable at all.
fn nextPointsPastTheValue() raise.Raising(void) {
    const b = buffers.new(16);
    try marsh.marshal(b, harness.wrapInteger(1), null, 0);
    const first: usize = @intCast(b.count);
    try marsh.marshal(b, value.fromBytes("second", .string), null, 0);

    var next: [*]const u8 = undefined;
    const one = try marsh.unmarshal(b.slice(), 0, null, &next);
    expect(harness.integerIs(one, 1));
    expect(next == b.data.? + first);

    const two = try marsh.unmarshal(next[0..@intCast(@as(usize, @intCast(b.count)) - first)], 0, null, &next);
    expect(harness.stringValueIs(two, "second"));
    expect(next == b.data.? + @as(usize, @intCast(b.count)));
}

// ==========================================================================
// Entry
// ==========================================================================

fn body() raise.Raising(void) {
    test_env = harness.coreEnv();
    gc_alloc.gcroot(wrap.fromTable(test_env));
    rooted = arrays.new(0);
    gc_alloc.gcroot(wrap.fromArray(rooted));

    try registry.registerAbstractType(stored(&probe_at));
    try registry.registerAbstractType(stored(&refuser_at));
    try registry.registerAbstractType(stored(&twice_at));
    try registry.registerAbstractType(stored(&never_at));
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
    try theWeakLeadBytesAreTheSameInEveryConfiguration();
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
    harness.init();
    body() catch @panic("marsh: an entry point raised unexpectedly");
    vm_lifecycle.deinit();

    std.debug.print("marsh contract ok\n", .{});
}
