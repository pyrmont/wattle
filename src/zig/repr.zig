//! `repr` -- the value representation, and the floor of the value DAG.
//!
//! One machine word carrying its own type tag. `DESIGN.md` sections 1, 2 and 7
//! are the decision: NaN boxing is kept because a full-width `f64` plus a tag
//! does not fit in 64 bits in any language, the tag is an enum rather than an
//! integer, and the tagged layout survives as this tree's last differential
//! rather than as a portability fallback.
//!
//! ## Why this is a module of its own
//!
//! One foundational module holds the representation and nothing else, and the
//! module graph decides where that can be: **the heap types name `Value` at 28
//! code sites across seventeen aggregates**, so the representation has to be
//! declared below all of them.
//!
//! What that admits is exactly the operations that name no Janet heap type:
//! the three layouts, the tag, and the bit-level construction and extraction
//! over them. `wrap.fromTable` takes a `*tables.Table` and so cannot come
//! down here; it stays in `wrap.zig`, which is the *face* of this floor and
//! where the value DAG already had it. **990 of `wrap.zig`'s 2,382 call sites
//! name no heap type and could have moved**, and they do not: a call site
//! writing `repr.fromNil()` beside `wrap.fromTable(t)` has had one question
//! split in two by an accident of which module declares the payload type. The
//! DAG gains a floor rather than losing a layer:
//!
//!     repr <- wrap <- kind <- order <- access
//!
//! ## What may be imported here
//!
//! `std` and `config` -- and nothing else, ever. `config` selects the layout,
//! and it is a leaf over the build options.
//!
//! **`constants` is not in that list, and the direction is the point.** The tag
//! numbering is `Tag`'s, here, and `constants` imports *this* module to restate
//! it for a C caller. Reversing that would put the numbering above the type
//! that means it. **An import of allocation, tables, the VM or the collector is
//! the failure this module exists to make impossible**, and it is a build error
//! rather than a review comment because none of those is in this module's
//! import list in `build.zig`.
//!
//! ## One file, three layouts, and the type is how you tell them apart
//!
//! This is the one place whose *content* changes shape per target: nanbox-64,
//! nanbox-32 and the tagged fallback are three implementations behind one set
//! of signatures. Which one a build compiles is `config.value_repr`, decided
//! by `build.zig`. Recovering it by asking the shape of a C type is what made
//! a header the place the representation was *decided* rather than merely
//! declared.
//!
//!   - `nanbox64` -- a union of `u64`, `i64`, `number` and `pointer`.
//!   - `nanbox32` -- a union whose first member is the `tagged` struct.
//!   - `tagged`   -- a *struct* of `as` and `type`, sixteen bytes.
//!
//! `layout` names which one this build compiled and `bits` is its
//! implementation, so the operations above read as one implementation rather
//! than as a three-way switch repeated per function.
//!
//! ## The nanbox-32 layout is written, compiled, and not executed
//!
//! `riscv32-linux-musl` is the one 32-bit target the whole tree
//! cross-compiles for, and `tools/testing/matrix.janet` carries it as a **build** job.
//! Zig 0.16 and clang disagree about how many argument registers an
//! eight-byte union consumes under riscv32 ILP32D, so a lone `Value`
//! parameter arrives intact and every argument *behind* one arrives
//! displaced: `janet_type(Value)` answers correctly while
//! `janet_checktype(Value, tag)` reads a garbage tag. That is a
//! toolchain disagreement rather than a property of this code, and it is why
//! `DESIGN.md` section 7 drops the arm. **The deletion is its own increment**
//! -- it has a different oracle to the structural move that put this file
//! here -- so all three arms are carried.
//!
//! ## Type punning is the subject, not an accident
//!
//! Every function here writes one member of a union and reads another. That is
//! defined for an `extern union` in Zig as it is in C, so nothing needs
//! `@bitCast` to say what the original says. The one place the difference
//! shows is `nanbox64.fromPointer`, which stores a pointer and then shifts and
//! tags the *word* -- written here as the same two statements over the same
//! union.
//!
//! ## Nothing here can raise
//!
//! No function in this file calls anything that can raise, allocate or
//! collect. That is not a coincidence to be maintained by hand: it is what the
//! import list above guarantees.

const std = @import("std");
const config = @import("config");

// ---------------------------------------------------------------------------
// The value type
//
// Three layouts, selected by `-Dnanbox` and the target width. `DESIGN.md` §7
// keeps `tagged` as the tree's last differential and drops `nanbox_32`; the
// deletion is its own increment, so all three are carried here.
//
// The three aggregates below lost their `Janet` prefix with the move: they are
// this module's and nothing outside it has ever named one.
// ---------------------------------------------------------------------------

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

/// `Value`'s payload under the tagged layout.
pub const TaggedPayload = extern union {
    u64: u64,
    number: f64,
    integer: i32,
    pointer: ?*anyopaque,
    cpointer: ?*const anyopaque,
};

/// Claret's fundamental word. `extern` because every published `janet_wrap_*`
/// returns one across a `callconv(.c)` boundary; `tools/check/layouts.txt` classes it
/// `abi,field,repr`, which is all three reasons a layout is fixed at once.
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
    // `type` is a `c_uint` rather than a `Tag`, and that is not an oversight
    // waiting to be tidied: an `extern struct` cannot hold an `enum(u4)` --
    // "only integers with 0, 8, 16, 32, 64 and 128 bits are extern
    // compatible" -- and this arm is on the published boundary. The width at
    // the boundary and the width of the truth are different questions;
    // `typeOf` converts.
    .tagged => extern struct {
        as: TaggedPayload = std.mem.zeroes(TaggedPayload),
        type: c_uint = 0,
    },
};

/// The type tag. `DESIGN.md` section 2.
///
/// Four bits, because that is the budget: bits 47-50 of a NaN-boxed word, and
/// section 1's table has the rest. Sixteen primitive types and no seventeenth
/// without changing the representation.
///
/// **The order is Janet's and it is load-bearing**, so the block below asserts
/// every value rather than trusting the transcription. `fiber` is 3, between
/// `boolean` and `string`; `DESIGN.md` section 2 had it fourteenth until this
/// increment checked, and that listing would have shifted twelve tags, moving
/// the bit pattern of every non-number value, the core image and the marshaled
/// surface with them.
///
/// What the enum buys over the `c_uint` it replaces is one thing and it is the
/// one that matters when a type is added: **a `switch` that omits a case does
/// not compile**, and the error names the value.
pub const Tag = enum(u4) {
    number,
    nil,
    boolean,
    fiber,
    string,
    symbol,
    keyword,
    array,
    tuple,
    table,
    @"struct",
    buffer,
    function,
    cfunction,
    abstract,
    pointer,
};

comptime {
    // The tag numbering, against upstream Janet at `17b3f8c4` -- its
    // `JanetType`. Sixteen assertions rather than a count, because a
    // transposition keeps the count.
    const expected = .{
        .{ Tag.number, 0 },    .{ Tag.nil, 1 },        .{ Tag.boolean, 2 },
        .{ Tag.fiber, 3 },     .{ Tag.string, 4 },     .{ Tag.symbol, 5 },
        .{ Tag.keyword, 6 },   .{ Tag.array, 7 },      .{ Tag.tuple, 8 },
        .{ Tag.table, 9 },     .{ Tag.@"struct", 10 }, .{ Tag.buffer, 11 },
        .{ Tag.function, 12 }, .{ Tag.cfunction, 13 }, .{ Tag.abstract, 14 },
        .{ Tag.pointer, 15 },
    };
    for (expected) |pair| {
        if (@intFromEnum(pair[0]) != pair[1])
            @compileError("tag " ++ @tagName(pair[0]) ++ " is not upstream's value");
    }
    if (@typeInfo(Tag).@"enum".fields.len != tag_count)
        @compileError("Tag has grown a member; the four-bit budget is §1's");
}

/// How many tags there are. Sixteen, and the representation cannot hold a
/// seventeenth: `DESIGN.md` §1's bit budget gives the tag four bits.
pub const tag_count = 16;

/// A set of tags. The wire and the messages spell it as `1 << tag` or'd
/// together; this is the type that arithmetic was standing in for.
///
/// **The bit layout is the declaration order**, because a `packed struct`'s
/// first field is its least significant bit, and the order here is `Tag`'s.
/// The `comptime` block below asserts all sixteen positions and the five
/// composites against the values upstream Janet computes, so a reordering of
/// either declaration is a build failure rather than a set that quietly means
/// something else.
///
/// It is sixteen bits. A bit above fifteen names no tag, so nothing is lost
/// where a wider word arrives and is narrowed.
pub const TagSet = packed struct(u16) {
    number: bool = false,
    nil: bool = false,
    boolean: bool = false,
    fiber: bool = false,
    string: bool = false,
    symbol: bool = false,
    keyword: bool = false,
    array: bool = false,
    tuple: bool = false,
    table: bool = false,
    @"struct": bool = false,
    buffer: bool = false,
    function: bool = false,
    cfunction: bool = false,
    abstract: bool = false,
    pointer: bool = false,

    pub const none: TagSet = .{};
    pub const all = fromBits(std.math.maxInt(u16));

    /// The five named unions: the ones a message or a check asks for by name.
    pub const bytes = of(&.{ .string, .symbol, .buffer, .keyword });
    pub const indexed = of(&.{ .array, .tuple });
    pub const dictionary = of(&.{ .table, .@"struct" });
    pub const lengthable = bytes.with(indexed).with(dictionary);
    pub const callable = of(&.{ .function, .cfunction, .abstract }).with(lengthable);

    pub fn one(t: Tag) TagSet {
        return fromBits(@as(u16, 1) << @intFromEnum(t));
    }

    /// The comptime constructor, so a set reads as the tags in it rather than
    /// as an or-chain of sixteen names.
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

    pub fn isEmpty(self: TagSet) bool {
        return self.bits() == 0;
    }

    /// The only place the set is spelled as a number.
    pub fn bits(self: TagSet) u16 {
        return @bitCast(self);
    }
    pub fn fromBits(m: u16) TagSet {
        return @bitCast(m);
    }
};

comptime {
    // Sixteen positions and five composites, against the values upstream Janet
    // computes at `17b3f8c4`. Reordering `Tag` or the fields above fails here
    // rather than in a program.
    std.debug.assert(@sizeOf(TagSet) == 2);
    std.debug.assert(TagSet.one(.number).bits() == 0x0001);
    std.debug.assert(TagSet.one(.nil).bits() == 0x0002);
    std.debug.assert(TagSet.one(.boolean).bits() == 0x0004);
    std.debug.assert(TagSet.one(.fiber).bits() == 0x0008);
    std.debug.assert(TagSet.one(.string).bits() == 0x0010);
    std.debug.assert(TagSet.one(.symbol).bits() == 0x0020);
    std.debug.assert(TagSet.one(.keyword).bits() == 0x0040);
    std.debug.assert(TagSet.one(.array).bits() == 0x0080);
    std.debug.assert(TagSet.one(.tuple).bits() == 0x0100);
    std.debug.assert(TagSet.one(.table).bits() == 0x0200);
    std.debug.assert(TagSet.one(.@"struct").bits() == 0x0400);
    std.debug.assert(TagSet.one(.buffer).bits() == 0x0800);
    std.debug.assert(TagSet.one(.function).bits() == 0x1000);
    std.debug.assert(TagSet.one(.cfunction).bits() == 0x2000);
    std.debug.assert(TagSet.one(.abstract).bits() == 0x4000);
    std.debug.assert(TagSet.one(.pointer).bits() == 0x8000);
    std.debug.assert(TagSet.bytes.bits() == 0x0870);
    std.debug.assert(TagSet.indexed.bits() == 0x0180);
    std.debug.assert(TagSet.dictionary.bits() == 0x0600);
    std.debug.assert(TagSet.lengthable.bits() == 0x0FF0);
    std.debug.assert(TagSet.callable.bits() == 0x7FF0);
    // A named bit is its own field, so the struct and the shift agree by
    // construction only if the declaration order does. This is the check that
    // says so.
    for (0..tag_count) |i| {
        const t: Tag = @enumFromInt(i);
        std.debug.assert(TagSet.one(t).has(t));
        std.debug.assert(!TagSet.none.has(t));
        std.debug.assert(TagSet.all.has(t));
    }
}

/// `janet_checktypes`, which asks whether a value's tag is in a set. It is
/// here rather than with the value helpers because it names no Janet heap
/// type: the tag and the set of tags are both this module's.
pub fn checkTypes(x: Value, set: TagSet) bool {
    return set.has(typeOf(x));
}

// --------------------------------------------------------- layout constants
//
// These came down with the tag for one reason: this module imports `config`
// and nothing else, so "the representation module does not import allocation,
// tables, the VM or the collector" is a fact about `build.zig`'s import list
// rather than a rule somebody has to keep. Outside this file exactly two
// callers read one -- `registry.zig`'s pointer-alignment check and
// `test/value_wrap.zig`, which is the contract on the bit layout.
// the contract on the bit layout.

/// The NaN marker and the four tag bits together.
pub const tagbits: u64 = 0xFFFF800000000000;

/// The low 47 bits a value carries.
pub const payloadbits: u64 = 0x00007FFFFFFFFFFF;

/// The shift that lets a target with more than 47 bits of address space still
/// fit a pointer in the payload. It is `config.nanbox_pointer_shift` and
/// nothing else, so the two cannot drift -- they had, once, and
/// `constants.zig` records what that cost.
pub const pointer_shift: c_int = config.nanbox_pointer_shift;

/// `JANET_DOUBLE_OFFSET`: the bias nanbox-32 adds to a double's high word so
/// that every non-number tag sits below it.
pub const double_offset: c_int = 0xFFFF;

pub const Layout = enum { nanbox64, nanbox32, tagged };

/// Which of the three value representations this build compiled with.
///
/// `build.zig` decides it and says so. Reading it off the shape of a
/// translated type is what made a header the place the value representation
/// was decided rather than merely declared.
pub const layout: Layout = switch (config.value_repr) {
    .tagged => .tagged,
    .nanbox_32 => .nanbox32,
    .nanbox_64 => .nanbox64,
};

// -------------------------------------------------------- the three layouts

/// `JANET_NANBOX_64`. The payload lives in the low 47 bits of a double whose
/// exponent is all ones, the type in the four bits above it, and a pointer is
/// stored shifted right by `JANET_NANBOX_64_POINTER_SHIFT` so that a target
/// with more than 47 bits of address space still fits.
pub const nanbox64 = struct {
    /// `janet_nanbox_lowtag` and `janet_nanbox_tag`, which are function-like
    /// macros and so do not survive translation.
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
    pub inline fn toPointer(x_in: Value) ?*anyopaque {
        var x = x_in;
        x.u64 &= payloadbits;
        x.u64 <<= pointer_shift;
        return x.pointer;
    }

    /// `janet_nanbox_from_pointer`. The C original writes the pointer into the
    /// union and then shifts and tags the word; the commented-out alignment
    /// assertion it carries is left commented out here too, because turning it
    /// on would reject pointers the collector currently accepts.
    pub inline fn fromPointer(p: ?*anyopaque, tagmask: u64) Value {
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
    // declaration -- it makes the unqualified name ambiguous. Same reason
    // `abi` and `ops` say `outer.`, pointing the other way.
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

    /// `janet_wrap_number_safe`. A NaN is replaced by the canonical quiet one,
    /// so that a payload smuggled in through a marshalled double cannot be read
    /// back as a tagged value.
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

/// `JANET_NANBOX_32`. A twelve-byte value on a four-byte-pointer target: the
/// payload and a 32-bit type tag overlaid on a double, with every non-number
/// tag below `JANET_DOUBLE_OFFSET` so that a double's high word can be biased
/// into the range above it.
pub const nanbox32 = struct {
    const bias: u32 = @intCast(double_offset);

    /// `janet_nanbox32_from_tagi`.
    pub inline fn fromTagI(t: u32, integer: i32) Value {
        var ret: Value = undefined;
        ret.tagged.type = t;
        ret.tagged.payload.integer = integer;
        return ret;
    }

    /// `janet_nanbox32_from_tagp`.
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

    /// `janet_unwrap_number`, which is a *function* under this layout rather
    /// than a macro: the bias has to come back off the high word before the
    /// double can be read.
    inline fn unwrapNumber(x_in: Value) f64 {
        var x = x_in;
        x.tagged.type -%= bias;
        return x.number;
    }

    /// `janet_wrap_number`, likewise a function here. The addition is on a
    /// `uint32_t` and so wraps by definition in C; the wrapping operator says
    /// the same thing.
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

/// The tagged fallback: a payload union and a separate tag field, and
/// no NaN space in use at all. Sixteen bytes on a 64-bit target where either
/// NaN-boxed layout is eight or twelve.
pub const tagged = struct {
    /// `JANET_WRAP_DEFINE`'s body. The `as.u64 = 0` is what the macro's own
    /// comment calls zeroing the other bits in case of a 32-bit payload, and it
    /// has to precede the narrower store rather than follow it.
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

    /// The one layout whose `janet_wrap_number_safe` does *not* canonicalise a
    /// NaN, because it has no NaN space to protect. Reproduced.
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

comptime {
    // **One public spelling per operation, as a structural gate.** Making the
    // arms' common operations private is what removes the second spelling;
    // this is what keeps it removed. `@typeInfo`'s `decls` lists only the
    // public ones, so the allowlist below *is* each arm's published surface,
    // and a `pub` added to an arm fails the build rather than quietly giving
    // `typeOf` a second address.
    //
    // Only seven operations need a named arm, and all seven are the
    // compatibility entry points in `wrap.zig`: the five `janet_nanbox_*` and
    // the two `janet_nanbox32_*`. Those are declared per layout by Janet and
    // are the one caller that genuinely wants a *named* arm rather than the
    // selected one. Everything else is a selected-layout operation and is
    // reached at this module's root.
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

/// The selected layout, named once so that the aliases below read as one
/// implementation rather than as a three-way switch repeated per operation.
///
/// **Private**, because an arm and the module root both answering `typeOf`
/// would be two public spellings of one question. The arms themselves are
/// `pub` for the seven `janet_nanbox*` entry points, which Janet declares per
/// layout and which are the one caller that genuinely wants a *named* arm
/// rather than the selected one.
const bits = switch (layout) {
    .nanbox64 => nanbox64,
    .nanbox32 => nanbox32,
    .tagged => tagged,
};

// --------------------------------------------------- the module's operations
//
// Aliases rather than wrappers: `pub const typeOf = bits.typeOf` is the same
// function under a second name, where `pub inline fn typeOf(x) { return
// bits.typeOf(x); }` would be a second declaration for the optimizer to fold
// and for a reader to check. Everything a caller outside this file needs of
// the representation is here; `value/helpers/wrap.zig` is the layer that adds
// the Janet heap types to it.

/// `janet_type`. The tag, which under both NaN-boxed layouts is a shift and a
/// mask of the word and under the tagged layout is a field read.
pub const typeOf = bits.typeOf;

/// `janet_checktype`, answering `bool`. It is the only internal spelling;
/// `capi.zig` is where the answer becomes the published `int`.
pub const checkType = bits.checkType;

/// `janet_truthy`. Everything but `nil` and `false`.
pub const truthy = bits.truthy;

/// The four immediates and the two number forms.
pub const wrapNil = bits.wrapNil;
pub const wrapBoolean = bits.wrapBoolean;
pub const wrapNumber = bits.wrapNumber;
pub const wrapNumberSafe = bits.wrapNumberSafe;
pub const unwrapNumber = bits.unwrapNumber;
pub const unwrapBoolean = bits.unwrapBoolean;

/// The payload conversions. `wrapPointer` and `wrapCPointer` take the tag at
/// comptime because every caller knows it: there are sixteen of them and each
/// is one `wrap.fromX`.
pub const toPointer = bits.toPointer;
pub const wrapPointer = bits.wrapPointer;
pub const wrapCPointer = bits.wrapCPointer;
