//! The value representation: one machine word with its own type tag.
//!
//! `Value` is that word and `Tag` is its type tag. Files under `api/`,
//! `boot/`, `client/` and `runtime/` import this file directly, and nothing in
//! the tree sits below it. `runtime/value/helpers/wrap.zig` is the layer that
//! adds the Janet heap types to what it declares.
//!
//! It is an authoritative Zig source, and so are `api/constants.zig` and
//! `host/host.zig`. Nothing translates a Janet header into any of the three.
//!
//! A _layout_ is one of the three ways a `Value` stores a payload and a tag.
//! `-Dnanbox` and the target width select it, `layout` names which of the
//! three this build compiled, and `nanbox64`, `nanbox32` and `tagged` are the
//! three implementations.
//!
//! ## What this file may import
//!
//! `std` and `config`, and nothing else. `config` selects the layout and is a
//! leaf over the build options. `build.zig` gives this module no other import,
//! so an import of allocation, tables, the VM or the collector is a build
//! error rather than a review comment.
//!
//! `constants` is not on the list either. The tag numbering is `Tag`'s, here,
//! and `api/constants.zig` imports this module to restate it for a C caller.
//!
//! What the list admits is the operations that name no Janet heap type: the
//! three layouts, the tag, and the bit-level construction and extraction over
//! them. `runtime/value/helpers/wrap.zig`'s `fromTable` takes a
//! `*tables.Table` and cannot come down here, and that file has the
//! operations that could have, so a call site is not split in two by which
//! module declares a payload type.
//!
//! Nothing here can raise. No function in this file calls anything that can
//! raise, allocate or collect, and the import list is what guarantees it.
//!
//! ## Three layouts behind one set of signatures
//!
//! `bits` is the selected arm, and the operations under Constants are aliases
//! of its functions, so they read as one implementation rather than as a
//! three-way switch repeated per operation.
//!
//! - `nanbox64` is a union of `u64`, `i64`, `number` and `pointer`. The
//!   payload is the low 47 bits of a double whose exponent is all ones, and
//!   the tag is the four bits above it. A pointer is stored shifted right by
//!   `pointer_shift`, so a target with more than 47 bits of address space
//!   still fits.
//!
//! - `nanbox32` is a union whose first member is `Nanbox32Tagged`. A payload
//!   and a 32-bit tag are overlaid on a double, with every non-number tag
//!   below `double_offset`, so a double's high word can be biased into the
//!   range above it.
//!
//! - `tagged` is a struct of `as` and `type`, and uses no NaN space. It is
//!   sixteen bytes on a 64-bit target and twelve or sixteen on a 32-bit one,
//!   where either NaN-boxed layout is eight.
//!
//! Every function in an arm writes one member of a union and reads another,
//! which is defined for an `extern union` in Zig, so none needs a `@bitCast`
//! to say so. `nanbox64.fromPointer` is the one place the difference shows: it
//! stores a pointer and then shifts and tags the word.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const config = @import("config");

// ==========================================================================
// Constants
// ==========================================================================

/// The selected layout, named once so that the operations below read as one
/// implementation rather than as a three-way switch repeated per operation.
///
/// This is private, because an arm and the module root both declaring `typeOf`
/// would be two public spellings of one question. The arms are `pub` for
/// `runtime/value/helpers/wrap.zig`'s seven `nanbox*` helpers, which are the
/// one caller that needs a named arm rather than the selected arm.
const bits = switch (layout) {
    .nanbox64 => nanbox64,
    .nanbox32 => nanbox32,
    .tagged => tagged,
};

/// The type test over a `Value` and a `Tag`, returning `bool`. It is the only
/// internal spelling; `runtime/capi.zig` is where the result becomes the
/// published `int`.
pub const checkType = bits.checkType;

/// The bias `nanbox32` adds to a double's high word so that every non-number
/// tag sits below it. `api/constants.zig` records that it is declared here
/// rather than restating the number.
pub const double_offset: c_int = 0xFFFF;

/// Which of the three value representations this build compiled with.
/// `build.zig` decides it, and nothing here inspects a type to find out.
pub const layout: Layout = switch (config.value_repr) {
    .tagged => .tagged,
    .nanbox_32 => .nanbox32,
    .nanbox_64 => .nanbox64,
};

/// The low 47 bits of a NaN-boxed word, which are the payload.
pub const payloadbits: u64 = 0x00007FFFFFFFFFFF;

/// The shift that lets a target with more than 47 bits of address space still
/// fit a pointer in the payload. It is `config.nanbox_pointer_shift` and
/// nothing else, so the two cannot drift.
pub const pointer_shift: c_int = config.nanbox_pointer_shift;

/// How many tags there are. Sixteen, and the tag's four bits leave no room
/// for a seventeenth.
pub const tag_count = 16;

/// The NaN marker and the four tag bits together.
pub const tagbits: u64 = 0xFFFF800000000000;

/// The payload conversions. `wrapPointer` and `wrapCPointer` take the tag at
/// comptime because it is a constant at every call site: all thirteen are in
/// `runtime/value/helpers/wrap.zig`, one per `from*` constructor.
pub const toPointer = bits.toPointer;
pub const wrapCPointer = bits.wrapCPointer;
pub const wrapPointer = bits.wrapPointer;

/// Everything but `nil` and `false`.
pub const truthy = bits.truthy;

/// The tag of a value, which under both NaN-boxed layouts is a shift and a
/// mask of the word and under the tagged layout is a field read.
pub const typeOf = bits.typeOf;

/// The four immediates and the two number forms.
pub const unwrapBoolean = bits.unwrapBoolean;
pub const unwrapNumber = bits.unwrapNumber;
pub const wrapBoolean = bits.wrapBoolean;
pub const wrapNil = bits.wrapNil;
pub const wrapNumber = bits.wrapNumber;
pub const wrapNumberSafe = bits.wrapNumberSafe;

// ==========================================================================
// Types
// ==========================================================================

/// Which of the three value representations a build uses. `layout` is the
/// value for this build.
pub const Layout = enum { nanbox64, nanbox32, tagged };

/// `Value`'s payload under the 32-bit NaN box.
pub const Nanbox32Payload = extern union {
    integer: i32,
    pointer: ?*anyopaque,
};

/// The tagged half of the 32-bit NaN box.
pub const Nanbox32Tagged = extern struct {
    payload: Nanbox32Payload = std.mem.zeroes(Nanbox32Payload),
    type: u32 = 0,
};

/// The type tag, as four bits.
///
/// Four bits is the budget, so there are sixteen primitive types and no
/// seventeenth without changing the representation. The order is load-bearing,
/// so the block under Tests asserts every value rather than trusting the
/// declaration: it is the order values of different types sort in, and the
/// order a type set names its types in a message.
///
/// The order is Wattle's. After the three constants, each mutable built-in
/// comes before its immutable one: buffer and string, array and vector, table
/// and map. A keyword is a symbol, and its kind is on the interned object
/// rather than in the tag: `value/symbols.zig` has how.
///
/// A four-bit enum rather than a bare integer, so that a `switch` omitting a
/// case does not compile and the error names the value.
pub const Tag = enum(u4) {
    number,
    nil,
    boolean,
    buffer,
    string,
    array,
    vector,
    table,
    map,
    symbol,
    tuple,
    fiber,
    function,
    nfunction,
    abstract,
    pointer,
};

/// A set of tags. The wire and the messages spell a set as `1 << tag` or'd
/// together, and this is the type over that arithmetic.
///
/// The bit layout is the declaration order, because a `packed struct`'s first
/// field is its least significant bit, and the order here is `Tag`'s. The
/// block under Tests asserts all sixteen positions and the five composites
/// against fixed numbers, so reordering either
/// declaration is a build failure rather than a set that quietly means
/// something else.
///
/// The set is sixteen bits. A bit above fifteen names no tag, so nothing is
/// lost where a wider word arrives and is narrowed.
pub const TagSet = packed struct(u16) {
    number: bool = false,
    nil: bool = false,
    boolean: bool = false,
    buffer: bool = false,
    string: bool = false,
    array: bool = false,
    vector: bool = false,
    table: bool = false,
    map: bool = false,
    symbol: bool = false,
    tuple: bool = false,
    fiber: bool = false,
    function: bool = false,
    nfunction: bool = false,
    abstract: bool = false,
    pointer: bool = false,

    pub const none: TagSet = .{};
    pub const all = fromBits(std.math.maxInt(u16));

    /// The five named unions, which a message or a check names directly.
    pub const bytes = of(&.{ .string, .symbol, .buffer });
    pub const indexed = of(&.{ .array, .vector, .tuple });
    pub const dictionary = of(&.{ .table, .map });
    pub const lengthable = bytes.with(indexed).with(dictionary);
    pub const callable = of(&.{ .function, .nfunction, .abstract }).with(lengthable);

    pub fn one(t: Tag) TagSet {
        return fromBits(@as(u16, 1) << @intFromEnum(t));
    }

    /// Builds a set from a list of tags at comptime, so a set reads as the
    /// tags in it rather than as an or-chain of sixteen names.
    pub fn of(comptime tags: []const Tag) TagSet {
        comptime var m: u16 = 0;
        inline for (tags) |t| m |= @as(u16, 1) << @intFromEnum(t);
        return comptime fromBits(m);
    }

    pub fn has(self: TagSet, t: Tag) bool {
        return (self.bits() >> @intFromEnum(t)) & 1 != 0;
    }

    pub fn with(self: TagSet, other: TagSet) TagSet {
        return fromBits(self.bits() | other.bits());
    }

    /// Returns the set as a number, which is the only place it is spelled
    /// that way.
    pub fn bits(self: TagSet) u16 {
        return @bitCast(self);
    }
    pub fn fromBits(m: u16) TagSet {
        return @bitCast(m);
    }
};

/// `Value`'s payload under the tagged layout.
pub const TaggedPayload = extern union {
    u64: u64,
    number: f64,
    integer: i32,
    pointer: ?*anyopaque,
    cpointer: ?*const anyopaque,
};

/// The fundamental word. It is `extern` because a `Value` crosses the
/// published C ABI by value, in `get`'s return and in the
/// argument of every crossing that takes one, and
/// `res/check/layouts.txt` classes it `abi,field,repr`, which is all three
/// reasons a layout is fixed at once.
pub const Value = switch (config.value_repr) {
    .nanbox_64 => extern union {
        u64: u64,
        i64: i64,
        number: f64,
        pointer: ?*anyopaque,
    },
    .nanbox_32 => extern union {
        tagged: Nanbox32Tagged,
        number: f64,
        u64: u64,
    },
    // `type` is a `c_uint` rather than a `Tag`. An `extern struct` cannot
    // have a field of type `enum(u4)`, because only integers of 0, 8, 16, 32,
    // 64 and 128 bits are extern compatible, and this arm is on the published
    // boundary. `typeOf` converts between the two widths.
    .tagged => extern struct {
        as: TaggedPayload = std.mem.zeroes(TaggedPayload),
        type: c_uint = 0,
    },
};

/// The 32-bit NaN box: an eight-byte value on a four-byte-pointer target.
///
/// `build.zig` selects this arm wherever the pointer is four bytes wide and
/// `-Dnanbox` is not false, which is the default on such a target.
/// `res/testing/matrix.janet` runs the suites on it under wasmtime through
/// the `wasm32-wasi` entry, and builds it for `riscv32-linux-musl`,
/// `x86-linux-musl` and `arm-linux-musleabihf`.
pub const nanbox32 = struct {
    const bias: u32 = @intCast(double_offset);

    /// A tagged 32-bit integer.
    pub inline fn fromTagI(t: u32, integer: i32) Value {
        var ret: Value = undefined;
        ret.tagged.type = t;
        ret.tagged.payload.integer = integer;
        return ret;
    }

    /// A tagged pointer.
    pub inline fn fromTagP(t: u32, p: ?*anyopaque) Value {
        var ret: Value = undefined;
        ret.tagged.type = t;
        ret.tagged.payload.pointer = p;
        return ret;
    }

    inline fn wrapPointer(p: ?*anyopaque, comptime t: Tag) Value {
        return fromTagP(@intFromEnum(t), p);
    }

    inline fn wrapCPointer(p: ?*const anyopaque, comptime t: Tag) Value {
        return fromTagP(@intFromEnum(t), @constCast(p));
    }

    inline fn typeOf(x: Value) Tag {
        return if (x.tagged.type < bias)
            @enumFromInt(x.tagged.type)
        else
            .number;
    }

    inline fn checkType(x: Value, t: Tag) bool {
        return if (t == .number)
            x.tagged.type >= bias
        else
            x.tagged.type == @as(u32, @intFromEnum(t));
    }

    inline fn truthy(x: Value) bool {
        return x.tagged.type != @intFromEnum(Tag.nil) and
            (x.tagged.type != @intFromEnum(Tag.boolean) or (x.tagged.payload.integer & 0x1) != 0);
    }

    inline fn unwrapBoolean(x: Value) bool {
        return x.tagged.payload.integer != 0;
    }

    /// Takes the bias back off the high word before reading the double, so
    /// this is a call where the 64-bit arm is a field read.
    inline fn unwrapNumber(x_in: Value) f64 {
        var x = x_in;
        x.tagged.type -%= bias;
        return x.number;
    }

    /// Adds the bias to the high word, which is also a call where the 64-bit
    /// arm is a field write. The addition is on the `u32` tag word and is
    /// meant to wrap, so it is written `+%`: `+` would trap on a double whose
    /// high word is already near the top of the range.
    inline fn wrapNumber(d: f64) Value {
        var ret: Value = undefined;
        ret.number = d;
        ret.tagged.type +%= bias;
        return ret;
    }

    inline fn wrapNumberSafe(d: f64) Value {
        return nanbox32.wrapNumber(if (std.math.isNan(d)) std.math.nan(f64) else d);
    }

    inline fn toPointer(x: Value) ?*anyopaque {
        return x.tagged.payload.pointer;
    }

    inline fn wrapNil() Value {
        return fromTagI(@intFromEnum(Tag.nil), 0);
    }

    inline fn wrapBoolean(b: bool) Value {
        return fromTagI(@intFromEnum(Tag.boolean), @intFromBool(b));
    }
};

/// The 64-bit NaN box.
///
/// The payload is the low 47 bits of a double whose exponent is all ones, and
/// the tag is the four bits above it. A pointer is stored shifted right by
/// `pointer_shift`, so a target with more than 47 bits of address space still
/// fits.
pub const nanbox64 = struct {
    /// The tag word in the high bits of a value of type `t`.
    inline fn tag(t: Tag) u64 {
        return (@as(u64, @intFromEnum(t)) | 0x1FFF0) << 47;
    }

    pub inline fn fromBits(word: u64) Value {
        return .{ .u64 = word };
    }

    pub inline fn fromDouble(d: f64) Value {
        return .{ .number = d };
    }

    inline fn fromPayload(t: Tag, payload: u64) Value {
        return fromBits(tag(t) | payload);
    }

    /// Masks the tag off, undoes the alignment shift, and reads the word back
    /// as a pointer.
    ///
    /// The mask is applied to `x.u64` rather than to `x.i64`. The mask's top
    /// bit is clear, so both members give the same result, and `x.u64` is
    /// written because mixing the two would suggest a distinction that is not
    /// there.
    pub inline fn toPointer(x_in: Value) ?*anyopaque {
        var x = x_in;
        x.u64 &= payloadbits;
        x.u64 <<= pointer_shift;
        return x.pointer;
    }

    /// Writes the pointer into the union, then shifts and tags the word.
    ///
    /// `p` must have its low `pointer_shift` bits clear, because the shift
    /// discards them and `toPointer` does not restore them. When the shift is
    /// nonzero, a Debug or ReleaseSafe build asserts this on every wrap.
    /// `runtime/registry.zig`'s `checkPointerAlign` also checks each nfunction
    /// and abstract type once, at registration, in every build mode.
    pub inline fn fromPointer(p: ?*anyopaque, tagmask: u64) Value {
        if (pointer_shift != 0) {
            const low_bits: usize = (@as(usize, 1) << pointer_shift) - 1;
            std.debug.assert(@intFromPtr(p) & low_bits == 0);
        }
        var ret: Value = undefined;
        ret.pointer = p;
        ret.u64 >>= pointer_shift;
        ret.u64 |= tagmask;
        return ret;
    }

    pub inline fn fromCPointer(p: ?*const anyopaque, tagmask: u64) Value {
        return nanbox64.fromPointer(@constCast(p), tagmask);
    }

    // Qualified because a struct member does not shadow a container
    // declaration; the unqualified name would be ambiguous.
    inline fn wrapPointer(p: ?*anyopaque, comptime t: Tag) Value {
        return nanbox64.fromPointer(p, tag(t));
    }

    inline fn wrapCPointer(p: ?*const anyopaque, comptime t: Tag) Value {
        return fromCPointer(p, tag(t));
    }

    inline fn typeOf(x: Value) Tag {
        return if (std.math.isNan(x.number))
            @enumFromInt((x.u64 >> 47) & 0xF)
        else
            .number;
    }

    inline fn isNumber(x: Value) bool {
        return !std.math.isNan(x.number) or ((x.u64 >> 47) & 0xF) == @intFromEnum(Tag.number);
    }

    inline fn checkType(x: Value, t: Tag) bool {
        return if (t == .number)
            isNumber(x)
        else
            (x.u64 & tagbits) == tag(t);
    }

    inline fn truthy(x: Value) bool {
        return !nanbox64.checkType(x, .nil) and
            (!nanbox64.checkType(x, .boolean) or (x.u64 & 0x1) != 0);
    }

    inline fn unwrapBoolean(x: Value) bool {
        return (x.u64 & 0x1) != 0;
    }

    inline fn unwrapNumber(x: Value) f64 {
        return x.number;
    }

    inline fn wrapNumber(d: f64) Value {
        return fromDouble(d);
    }

    /// Replaces a NaN with the canonical quiet NaN, so that a payload
    /// smuggled in through a marshalled double cannot be read back as a
    /// tagged value.
    inline fn wrapNumberSafe(d: f64) Value {
        var ret: Value = undefined;
        ret.number = if (std.math.isNan(d)) std.math.nan(f64) else d;
        return ret;
    }

    inline fn wrapNil() Value {
        return fromPayload(.nil, 1);
    }

    inline fn wrapBoolean(b: bool) Value {
        return fromPayload(.boolean, @intFromBool(b));
    }
};

/// The tagged layout: a payload union and a separate tag field, with no NaN
/// space in use. Sixteen bytes on a 64-bit target and twelve or sixteen on a
/// 32-bit one, where either NaN-boxed layout is eight.
pub const tagged = struct {
    /// The `as.u64 = 0` clears the whole payload word, so that a target whose
    /// pointer is narrower than eight bytes leaves no bits of a previous value
    /// beside the pointer stored. It has to precede the narrower store rather
    /// than follow it.
    inline fn wrapPointer(p: ?*anyopaque, comptime t: Tag) Value {
        var y: Value = undefined;
        y.type = @intFromEnum(t);
        y.as.u64 = 0;
        y.as.pointer = p;
        return y;
    }

    inline fn wrapCPointer(p: ?*const anyopaque, comptime t: Tag) Value {
        var y: Value = undefined;
        y.type = @intFromEnum(t);
        y.as.u64 = 0;
        y.as.cpointer = p;
        return y;
    }

    inline fn typeOf(x: Value) Tag {
        return @enumFromInt(x.type);
    }

    inline fn checkType(x: Value, t: Tag) bool {
        return x.type == @intFromEnum(t);
    }

    inline fn truthy(x: Value) bool {
        return x.type != @intFromEnum(Tag.nil) and
            (x.type != @intFromEnum(Tag.boolean) or (x.as.u64 & 0x1) != 0);
    }

    inline fn unwrapBoolean(x: Value) bool {
        return (x.as.u64 & 0x1) != 0;
    }

    inline fn unwrapNumber(x: Value) f64 {
        return x.as.number;
    }

    inline fn wrapNumber(d: f64) Value {
        var y: Value = undefined;
        y.type = @intFromEnum(Tag.number);
        y.as.u64 = 0;
        y.as.number = d;
        return y;
    }

    /// The one layout whose `wrapNumberSafe` leaves a NaN alone, because it
    /// has no NaN space to protect.
    inline fn wrapNumberSafe(d: f64) Value {
        return tagged.wrapNumber(d);
    }

    inline fn toPointer(x: Value) ?*anyopaque {
        return x.as.pointer;
    }

    inline fn wrapNil() Value {
        var y: Value = undefined;
        y.type = @intFromEnum(Tag.nil);
        y.as.u64 = 0;
        return y;
    }

    inline fn wrapBoolean(b: bool) Value {
        var y: Value = undefined;
        y.type = @intFromEnum(Tag.boolean);
        y.as.u64 = @intFromBool(b);
        return y;
    }
};

// ==========================================================================
// Public functions
// ==========================================================================

/// Returns whether a value's tag is in a set.
///
/// `x` is the value and `set` is the set of tags. This function cannot raise.
///
/// It is here rather than with the value helpers because it names no Janet
/// heap type: the tag and the set of tags are both this module's.
pub fn checkTypes(x: Value, set: TagSet) bool {
    return set.has(typeOf(x));
}

// ==========================================================================
// Tests
// ==========================================================================

comptime {
    // `Tag`'s numbering. Sixteen assertions rather than a count, because a
    // transposition leaves the count unchanged.
    const expected = .{
        .{ Tag.number, 0 },    .{ Tag.nil, 1 },        .{ Tag.boolean, 2 },
        .{ Tag.buffer, 3 },    .{ Tag.string, 4 },     .{ Tag.array, 5 },
        .{ Tag.vector, 6 },    .{ Tag.table, 7 },      .{ Tag.map, 8 },
        .{ Tag.symbol, 9 },    .{ Tag.tuple, 10 },     .{ Tag.fiber, 11 },
        .{ Tag.function, 12 }, .{ Tag.nfunction, 13 }, .{ Tag.abstract, 14 },
        .{ Tag.pointer, 15 },
    };
    for (expected) |pair| {
        if (@intFromEnum(pair[0]) != pair[1])
            @compileError("tag " ++ @tagName(pair[0]) ++ " has moved");
    }
    if (@typeInfo(Tag).@"enum".fields.len != tag_count)
        @compileError("Tag has grown a member; the tag has four bits, so " ++
            "there is no room for a seventeenth");
}

comptime {
    // `TagSet`'s sixteen positions and five composites, against fixed
    // numbers. Reordering `Tag` or `TagSet`'s fields fails here rather than in
    // a program.
    std.debug.assert(@sizeOf(TagSet) == 2);
    std.debug.assert(TagSet.one(.number).bits() == 0x0001);
    std.debug.assert(TagSet.one(.nil).bits() == 0x0002);
    std.debug.assert(TagSet.one(.boolean).bits() == 0x0004);
    std.debug.assert(TagSet.one(.buffer).bits() == 0x0008);
    std.debug.assert(TagSet.one(.string).bits() == 0x0010);
    std.debug.assert(TagSet.one(.array).bits() == 0x0020);
    std.debug.assert(TagSet.one(.vector).bits() == 0x0040);
    std.debug.assert(TagSet.one(.table).bits() == 0x0080);
    std.debug.assert(TagSet.one(.map).bits() == 0x0100);
    std.debug.assert(TagSet.one(.symbol).bits() == 0x0200);
    std.debug.assert(TagSet.one(.tuple).bits() == 0x0400);
    std.debug.assert(TagSet.one(.fiber).bits() == 0x0800);
    std.debug.assert(TagSet.one(.function).bits() == 0x1000);
    std.debug.assert(TagSet.one(.nfunction).bits() == 0x2000);
    std.debug.assert(TagSet.one(.abstract).bits() == 0x4000);
    std.debug.assert(TagSet.one(.pointer).bits() == 0x8000);
    std.debug.assert(TagSet.bytes.bits() == 0x0218);
    std.debug.assert(TagSet.indexed.bits() == 0x0460);
    std.debug.assert(TagSet.dictionary.bits() == 0x0180);
    std.debug.assert(TagSet.lengthable.bits() == 0x07F8);
    std.debug.assert(TagSet.callable.bits() == 0x77F8);
    // A named bit is its own field, so the struct and the shift agree only
    // if the two declaration orders do.
    for (0..tag_count) |i| {
        const t: Tag = @enumFromInt(i);
        std.debug.assert(TagSet.one(t).has(t));
        std.debug.assert(!TagSet.none.has(t));
        std.debug.assert(TagSet.all.has(t));
    }
}

comptime {
    // Each arm of `nanbox64`, `nanbox32` and `tagged` publishes only the
    // operations listed here, so one operation has one public spelling.
    // `@typeInfo`'s `decls` lists only the public declarations, so this
    // allowlist is each arm's published surface, and a `pub` added to an arm
    // fails the build rather than giving `typeOf` a second address.
    //
    // Seven operations need a named arm, and all seven are in
    // `runtime/value/helpers/wrap.zig`: the five `nanbox*` helpers over
    // `nanbox64` and the two `nanbox32*` over `nanbox32`. Every other
    // operation is reached at this module's root, on the selected layout.
    const allowed = .{
        .{ nanbox64, [_][]const u8{ "toPointer", "fromPointer", "fromCPointer", "fromDouble", "fromBits" } },
        .{ nanbox32, [_][]const u8{ "fromTagI", "fromTagP" } },
        .{ tagged, [_][]const u8{} },
    };
    for (allowed) |entry| {
        for (@typeInfo(entry[0]).@"struct".decls) |decl| {
            var ok = false;
            for (entry[1]) |name| {
                if (std.mem.eql(u8, decl.name, name)) ok = true;
            }
            if (!ok) @compileError(
                "`repr." ++ @typeName(entry[0]) ++ "." ++ decl.name ++
                    "` is public, which gives one operation two public spellings. " ++
                    "Reach it through `repr` instead, or add it to the allowlist here " ++
                    "with the reason a named arm is what the caller wants.",
            );
        }
    }
}
