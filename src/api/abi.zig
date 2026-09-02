//! The declarations a separately compiled module and the runtime must agree
//! on, and nothing else.
//!
//! `src/module.zig` is a real compilation boundary and stays one --
//! `DESIGN.md` section 11 -- so an author's `.so` is built from this package's
//! sources rather than linked against a header. What crosses that boundary is
//! *agreement*: both sides have to spell the same registration row, the same
//! abstract-type vtable, the same signal numbering. **Both `root` and
//! `module.zig` import this file**, so the agreement is by construction rather
//! than by review, and there is nothing here for a check to compare.
//!
//! **Every declaration below names the author-side code that needs it.** That
//! is the membership rule, and it is why this file exists at all. Handing an
//! author the whole type catalogue instead puts fifty-odd declarations their
//! compilation never names into their `.so`, because those shared a file with
//! the eleven it does. A declaration that cannot name an author-side caller
//! does not belong here.
//!
//! **`Table` and `Buffer` are opaque handles.** An author only ever holds a
//! *pointer* to one -- `module.zig`'s `Env` is a `*Table`, and an abstract
//! type's `tostring` renders into a `*Buffer`. The runtime's own
//! `tables.Table` and `buffers.Buffer` stay full structs in `value/`. Both sides pass one
//! pointer, so the two layouts need not agree; the runtime casts where it
//! implements a callback and where it dispatches through one, and
//! `cabi_check.zig` is where that substitution is written down.
//!
//! The author-side files are `module.zig`, `abstract_type.zig`, `raise.zig`
//! and `crossings.zig` -- the four this package compiles *into* a module --
//! plus whatever the author writes on top of them.

const std = @import("std");
const builtin = @import("builtin");
const repr = @import("repr");

// ---------------------------------------------------------------------------
// The two handles
// ---------------------------------------------------------------------------

/// An environment table, as a handle.
///
/// **Author-side:** `module.zig`'s `Env` is this type, so it is what a module's
/// entry point is handed and what `module.cfuns` and `module.def` register
/// into. An author never reads a field of one -- every operation on an
/// environment is a call across the symbol boundary -- so the layout is not
/// part of the agreement and `tables.Table` keeps it.
pub const Table = opaque {};

/// A byte buffer, as a handle.
///
/// **Author-side:** `AbstractType.tostring` and `abstract_type.Spec`'s
/// `tostring` slot take a `*Buffer`, which is the buffer the pretty-printer is
/// rendering into. Same argument as `Table`: one pointer crosses, and
/// `buffers.Buffer` keeps the layout on the runtime's side.
pub const Buffer = opaque {};

// ---------------------------------------------------------------------------
// Signalling
// ---------------------------------------------------------------------------

/// What a raise, a yield or an event asks the interpreter to do, and what a
/// resume reports back to its caller.
///
/// **Author-side:** `raise.zig` compiles into the author's module, and
/// `raise.signal` takes one of these -- which is what `module.panic` reaches
/// and what an author's cfunction raises through.
///
/// **Sixteen names over fourteen values.** `interrupt` is `user8` and `event`
/// is `user9`; a Zig enum does not permit a duplicate value, so the two
/// aliases are declarations rather than members. That is the honest rendering
/// — an alias is what they are.
///
/// `enum(c_uint)` rather than a narrower width because the value crosses a
/// compilation boundary and upstream Janet gives it an `int`-sized enum; unlike
/// `repr.Tag` there is no reason here to make the truth narrower than the
/// boundary.
pub const Signal = enum(c_uint) {
    ok = 0,
    @"error" = 1,
    debug = 2,
    yield = 3,
    user0 = 4,
    user1 = 5,
    user2 = 6,
    user3 = 7,
    user4 = 8,
    user5 = 9,
    user6 = 10,
    user7 = 11,
    user8 = 12,
    user9 = 13,

    /// The interpreter's own interrupt, which shares `user8`'s value.
    pub const interrupt: Signal = .user8;
    /// The event loop's wake-up, which shares `user9`'s.
    pub const event: Signal = .user9;

    /// A signal number arriving from outside, brought into the vocabulary.
    ///
    /// **ABI width is not value domain, and this is where the two are kept
    /// apart.** The published entry points are `callconv(.c)`, so a C caller
    /// may pass any `c_uint`; this type has fourteen members. Building the
    /// enum value *is itself* the illegal operation for anything else, so the
    /// conversion cannot be an `@enumFromInt` at the call site -- it has to be
    /// a decision, and this is the one place that decision is made.
    ///
    /// **Clamping is Janet's own answer, not a new one.** `JOP_SIGNAL` takes a
    /// raw number out of an instruction field and does exactly this:
    /// `if (s > JANET_SIGNAL_USER9) s = JANET_SIGNAL_USER9; if (s < 0) s = 0;`.
    /// Applying the interpreter's rule at the C boundary as well is what keeps
    /// an out-of-domain value from travelling through six bits of a fiber's GC
    /// flags.
    ///
    /// What this does *not* preserve is the round trip: Janet returned an
    /// out-of-range injected number to its caller unchanged. `DESIGN.md`
    /// records that divergence and `test/signal_core.zig` pins the
    /// replacement.
    pub fn fromWire(raw: c_uint) Signal {
        return if (raw > @intFromEnum(Signal.user9)) .user9 else @enumFromInt(raw);
    }
};

comptime {
    // Against upstream Janet at `17b3f8c4`. The values are
    // marshalled -- a fiber's status travels in an image -- so a shift here is
    // a wrong answer from a working program rather than a build failure.
    // **One expected-value table per vocabulary, in the header's order.** A
    // sample of four values and a count cannot catch a transposition: swapping
    // two unasserted members leaves both the count and every sampled value
    // correct. The table is the whole population, and the length assertion
    // beside it is what stops a member being added without a row.
    //
    // `FiberStatus`'s table, and the claim that every signal value is also a
    // status value, are in `value/fibers.zig` beside the enum they are about.
    const expected_signal = [_]struct { Signal, comptime_int }{
        .{ .ok, 0 },     .{ .@"error", 1 }, .{ .debug, 2 },  .{ .yield, 3 },
        .{ .user0, 4 },  .{ .user1, 5 },    .{ .user2, 6 },  .{ .user3, 7 },
        .{ .user4, 8 },  .{ .user5, 9 },    .{ .user6, 10 }, .{ .user7, 11 },
        .{ .user8, 12 }, .{ .user9, 13 },
    };
    std.debug.assert(expected_signal.len == @typeInfo(Signal).@"enum".fields.len);
    for (expected_signal) |row| std.debug.assert(@intFromEnum(row[0]) == row[1]);
    std.debug.assert(Signal.interrupt == .user8);
    std.debug.assert(Signal.event == .user9);
}

// ---------------------------------------------------------------------------
// Registering a cfunction
// ---------------------------------------------------------------------------

/// A cfunction in the slot the runtime stores one in.
///
/// **Author-side:** `raise.stored` casts an author's
/// `fn ([]Value) Error!Value` into this slot at registration, and it is what
/// `Reg.cfun` and `Method.cfun` hold on the wire. `raise.zig` compiles into
/// the author's module, so both sides have to mean the same pointer type.
pub const CFunction = ?*const fn (argc: i32, argv: [*c]repr.Value) callconv(.c) repr.Value;

/// One registration row: a name, a cfunction, and three pieces of metadata a
/// build may omit.
///
/// **Author-side:** `module.reg` builds one and `module.cfuns` hands a table of
/// them to `janet_cfuns_ext`, which is a symbol the runtime exports -- so the
/// field order is the agreement.
///
/// **`DESIGN.md` section 6.** Janet has two structs and four `JANET_REG_*`
/// macros here, and the reason is the preprocessor: `JANET_NO_DOCSTRINGS` and
/// `JANET_NO_SOURCEMAPS` decide which fields a build populates, and a macro's
/// only way to express that is a separate initialiser per combination. A
/// comptime `if` expresses it directly, so one struct does the work of all six
/// spellings.
///
/// `extern` because this *is* the layout `janet_cfuns_ext` receives, which is
/// the one published name that takes a registration table.
pub const Reg = extern struct {
    name: ?[*:0]const u8 = null,
    cfun: CFunction = null,
    documentation: ?[*:0]const u8 = null,
    source_file: ?[*:0]const u8 = null,
    source_line: i32 = 0,
};

/// One row of a method table: a name and a cfunction, with the cfunction typed
/// as raising.
///
/// **Author-side:** `module.getMethod` and `module.nextMethod` take a slice of
/// these and pass a terminated copy to `janet_getmethod` and
/// `janet_nextmethod`, which is how an abstract type's `get` answers a
/// `:keyword`. It is its own type because a method table is not a registration
/// -- `DESIGN.md` section 6 keeps them apart for that reason.
///
/// The layout is Janet's exactly -- a name and a pointer -- and the pointer is
/// the same pointer. What differs from `CFunction` is the *declared* type
/// of the function it points at, which is what makes a method's `try` a
/// compile error to omit. Where one of these arrays meets a signature the C
/// ABI still fixes -- `janet_getmethod`, `janet_nextmethod`,
/// `ev/stream.zig`'s `Stream.methods` -- it is cast, because a layout is all
/// those need.
pub const Method = extern struct {
    name: ?[*:0]const u8 = null,
    cfun: ?*const fn ([]repr.Value) error{JanetSignal}!repr.Value = null,
};

/// The version and feature bits a module was built against.
///
/// **Author-side:** `module.entry` exports `_janet_mod_config`, which returns
/// one of these; the loader reads it to refuse a module built for a different
/// runtime. It is one of the two entry points `dynlib.zig` looks up by name,
/// so its layout is as much of the published surface as the names are.
pub const BuildConfig = extern struct {
    major: c_uint = 0,
    minor: c_uint = 0,
    patch: c_uint = 0,
    bits: c_uint = 0,
};

// ---------------------------------------------------------------------------
// Abstract types
// ---------------------------------------------------------------------------

/// A byte sequence and its length, as `args.bytesView` answers it.
///
/// **Author-side:** `abstract_type.Spec`'s `bytes` callback returns one, so an
/// author writing a byte-like abstract declares this shape and the runtime
/// reads it back.
///
/// `len` is `usize` because it is a length, where upstream declares the same
/// field `int32_t`. Every loop in the tree that walks a byte view takes its
/// counter's type from this field, so the width here is what decides whether
/// the indexing needs a cast.
pub const ByteView = extern struct {
    bytes: ?[*]const u8,
    len: usize = 0,
};

/// The state a marshalling or unmarshalling callback is handed.
///
/// **Author-side:** `abstract_type.Spec`'s `marshal` and `unmarshal` callbacks
/// take a `*MarshalContext`, and an author's callback passes it back to
/// the runtime's marshalling entry points.
pub const MarshalContext = struct {
    m_state: ?*anyopaque = null,
    u_state: ?*anyopaque = null,
    flags: c_int = 0,
    data: ?[*]const u8 = null,
    at: ?*const AbstractType = null,
};

/// An abstract type's dispatch description: the one the runtime stores, the
/// one a module author declares, and the only one there is.
///
/// **Author-side:** `abstract_type.define` builds one from an author's
/// callbacks and the author declares it at container level;
/// `module.getAbstract` and `module.new` take a `*const AbstractType`, and the
/// runtime reads the same fourteen slots out of it. It is the largest single
/// reason this file exists.
///
/// It is declared *here* rather than in `abstract_type.zig`, which owns the
/// interface, because `AbstractHead.type` and `MarshalContext.at`
/// name it by pointer and both of those are boundary declarations too.
///
/// The payload is `?*anyopaque` here because this is the *erased* vtable;
/// `abstract_type.define` generates it from callbacks written over `*T`, which
/// is where the cast is got right once. `DESIGN.md` section 5.
///
/// Six callbacks cannot raise and that is a contract, not a measurement:
/// `gc`, `gcmark`, `compare`, `hash`, `bytes` and `gcperthread` are each
/// called where no scope above them could act on an error. See
/// `abstract_type.zig` for the argument.
///
/// **`name` is a slice and this struct is not `extern`**, which is
/// `DESIGN.md` section 5 entire. Zig refuses to `@export` a struct with
/// automatic layout, which a slice field forces, so none of these objects can
/// be published as a *data* symbol -- and none is, on the ground that a data
/// export is unusable without a layout to read it by and no such layout is
/// published. Nothing observes the field order, so nothing has to fix it.
pub const AbstractType = struct {
    name: []const u8,
    gc: ?*const fn (data: ?*anyopaque, len: usize) callconv(.c) void = null,
    gcmark: ?*const fn (data: ?*anyopaque, len: usize) callconv(.c) void = null,
    get: ?*const fn (data: ?*anyopaque, key: repr.Value) error{JanetSignal}!?repr.Value = null,
    put: ?*const fn (data: ?*anyopaque, key: repr.Value, value: repr.Value) error{JanetSignal}!void = null,
    marshal: ?*const fn (p: ?*anyopaque, ctx: *MarshalContext) error{JanetSignal}!void = null,
    unmarshal: ?*const fn (ctx: *MarshalContext) error{JanetSignal}!?*anyopaque = null,
    tostring: ?*const fn (p: ?*anyopaque, buffer: *Buffer) error{JanetSignal}!void = null,
    compare: ?*const fn (lhs: ?*anyopaque, rhs: ?*anyopaque) callconv(.c) i32 = null,
    hash: ?*const fn (p: ?*anyopaque, len: usize) callconv(.c) i32 = null,
    next: ?*const fn (p: ?*anyopaque, key: repr.Value) error{JanetSignal}!repr.Value = null,
    call: ?*const fn (p: ?*anyopaque, argc: i32, argv: [*]repr.Value) error{JanetSignal}!repr.Value = null,
    length: ?*const fn (p: ?*anyopaque, len: usize) error{JanetSignal}!usize = null,
    bytes: ?*const fn (p: ?*anyopaque, len: usize) callconv(.c) ByteView = null,
    gcperthread: ?*const fn (data: ?*anyopaque, len: usize) callconv(.c) void = null,
};

/// The width of a refcount. Windows' `InterlockedIncrement` takes a `LONG`;
/// everywhere else it is an `i32`.
///
/// **Author-side, at one remove:** `GCData.refcount` is one, so it fixes
/// that union's size and with it where `AbstractHead.type` sits. See
/// `GCObject`.
pub const AtomicInt = if (builtin.os.tag == .windows) c_long else i32;

/// `GCObject.data`: a block is either on the heap list or refcounted.
///
/// **Author-side, at one remove:** a by-value field of `GCObject`. See
/// there.
pub const GCData = extern union {
    next: ?*GCObject,
    refcount: AtomicInt,
};

/// The collector's header, which every heap block opens with.
///
/// **Author-side, at one remove:** `AbstractHead` opens with one, so its
/// size and alignment are what put `type` where `abstract_type.ofAbstract`
/// reads it. An author never touches the flags; the layout still has to agree,
/// which is why it is here alongside the head.
/// **It carries no methods, and that is what keeps `MemoryType` out of this
/// file.** A method cannot live outside its struct, so an accessor here would
/// drag the memory-type vocabulary into every author's compilation -- and
/// nothing an author compiles reads a memory type. `gc.memoryTypeOf` reads the
/// field from outside instead, and the enum lives beside it.
pub const GCObject = extern struct {
    flags: GCFlags = .{},
    data: GCData = std.mem.zeroes(GCData),
};

/// The header's flag word, which is three things at once.
///
/// **Author-side:** none of it, directly. It is here because `GCObject`
/// is, and a `packed struct(u32)` field is extern-compatible, so the header
/// keeps its layout and every heap type keeps its declared field order.
///
/// `type` is a `u8` rather than `gc.MemoryType` because `abi` may not import
/// `gc`: the enum lives with the allocator that reads it (`DESIGN.md` §14) and
/// `gc.memoryTypeOf` is the one place the byte becomes one.
///
/// `own` is bits 16 through 21, and what they mean is decided by `type`. Each
/// owner file names its own -- `tuples.isBracketed`, `functions.isTraced`,
/// `buffers.isForeign`, `tables.isScratch`, `fibers.evFlags` -- and a fiber
/// also reads the whole field at once, as the signal `signal.signalInject`
/// arms it to raise. That overlap is real: arming a resume signal clears the
/// three fiber bits, which nothing observes because a fiber is running between
/// the write and the next schedule.
pub const GCFlags = packed struct(u32) {
    type: u8 = 0,
    reachable: bool = false,
    disabled: bool = false,
    _reserved: u6 = 0,
    own: u6 = 0,
    _high: u10 = 0,
};

comptime {
    // The word is `int32_t` in the C original and travels in a core image as a
    // tuple's `flags >> 16`, so the width and the bit positions are the
    // contract. Compared against a mask table rather than against a
    // re-declaration, because what has to hold is where each bit sits.
    std.debug.assert(@sizeOf(GCFlags) == @sizeOf(i32));
    std.debug.assert(@as(u32, @bitCast(GCFlags{ .type = 0xFF })) == 0xFF);
    std.debug.assert(@as(u32, @bitCast(GCFlags{ .reachable = true })) == 0x100);
    std.debug.assert(@as(u32, @bitCast(GCFlags{ .disabled = true })) == 0x200);
    std.debug.assert(@as(u32, @bitCast(GCFlags{ .own = 0x3F })) == 0x3F0000);
}

/// The header in front of an abstract's payload.
///
/// **Author-side:** `abstract_type.ofAbstract` reads `type` out of one to start
/// a dispatch, and that is the whole of what an author's compilation does with
/// it -- but doing it needs the field order, so the layout is agreed.
pub const AbstractHead = extern struct {
    gc: GCObject = .{},
    type: *const AbstractType,
    size: usize = 0,
    _data: [0]c_longlong = std.mem.zeroes([0]c_longlong),
};

/// Where an abstract's payload begins inside its allocation.
///
/// **Author-side:** the offset `abstractHead` subtracts. It is `@offsetOf`
/// rather than `@sizeOf` of the head, for the reason `DESIGN.md` section 3
/// gives: the compiler reports where it put the payload rather than where it
/// ought to go. The two agree on every layout Claret builds today.
pub const abstract_payload = @offsetOf(AbstractHead, "_data");

/// Recover an abstract's head from its payload.
///
/// **Author-side:** `abstract_type.ofAbstract` calls it. **The subtraction is
/// here and not duplicated across the boundary** -- that is the reason it is
/// in this file rather than reimplemented on the author's side, where a stale
/// copy would read a live object at the wrong offset and say nothing.
///
/// The parameter is `?*const anyopaque` rather than `abstracts.Abstract` so
/// that a
/// `*const` caller needs no cast; the head itself is mutable, as every caller
/// marks or frees through it.
pub inline fn abstractHead(a: ?*const anyopaque) *AbstractHead {
    return @ptrFromInt(@intFromPtr(a) -% abstract_payload);
}
