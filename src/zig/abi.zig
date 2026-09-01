//! The declarations a separately compiled module and the runtime must agree
//! on, and nothing else.
//!
//! `src/zig/module.zig` is a real compilation boundary and stays one --
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
//! type's `tostring` renders into a `*Buffer`. The runtime's own `JanetTable`
//! and `JanetBuffer` stay full structs in `value/`. Both sides pass one
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
/// `types.JanetBuffer` keeps the layout on the runtime's side.
pub const Buffer = opaque {};

// ---------------------------------------------------------------------------
// Signalling
// ---------------------------------------------------------------------------

/// `JanetSignal`. What a raise, a yield or an event asks the interpreter to
/// do, and what `janet_continue` reports back to its caller.
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
    /// Applying the interpreter's rule at the C boundary as well makes one
    /// rule where there were two, and turns what used to be an out-of-domain
    /// value travelling through six bits of a fiber's GC flags into a signal
    /// the runtime can name.
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
pub const JanetCFunction = ?*const fn (argc: i32, argv: [*c]repr.Value) callconv(.c) repr.Value;

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
/// The narrow three-field layout survives as `capi.zig`'s `CReg`, because
/// `janet_cfuns` and `janet_cfuns_prefix` are published names that receive a
/// C table in that shape. It is a boundary type there and the runtime does
/// not use it.
///
/// `extern` because this *is* the layout `janet_cfuns_ext` receives.
pub const Reg = extern struct {
    name: ?[*:0]const u8 = null,
    cfun: JanetCFunction = null,
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
/// **There was one of these on each side of the boundary.** `module.zig` and
/// `method_type.zig` each declared an `extern struct Method` with these two
/// fields, and `tools/check/layouts.txt` carried a row for each; the layout is
/// the agreement, so declaring it twice was the thing this file exists to
/// stop. Both now name this one.
///
/// The layout is Janet's exactly -- a name and a pointer -- and the pointer is
/// the same pointer. What differs from `JanetCFunction` is the *declared* type
/// of the function it points at, which is what makes a method's `try` a
/// compile error to omit. Where one of these arrays meets a signature the C
/// ABI still fixes -- `janet_getmethod`, `janet_nextmethod`,
/// `JanetStream.methods` -- it is cast, because a layout is all those need.
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
pub const JanetBuildConfig = extern struct {
    major: c_uint = 0,
    minor: c_uint = 0,
    patch: c_uint = 0,
    bits: c_uint = 0,
};

// ---------------------------------------------------------------------------
// Abstract types
// ---------------------------------------------------------------------------

/// `janet_bytes_view`'s answer: a byte sequence and its length.
///
/// **Author-side:** `abstract_type.Spec`'s `bytes` callback returns one, so an
/// author writing a byte-like abstract declares this shape and the runtime
/// reads it back.
///
/// `len` is `usize` because it is a length. It was `i32` because
/// `janet_bytes_view` declared it that way, and every loop in the tree that
/// walks a byte view took its counter's type from this field -- which is
/// what made the counters `i32` and the indexing a cast.
pub const JanetByteView = extern struct {
    bytes: ?[*]const u8,
    len: usize = 0,
};

/// The state a marshalling or unmarshalling callback is handed.
///
/// **Author-side:** `abstract_type.Spec`'s `marshal` and `unmarshal` callbacks
/// take a `*JanetMarshalContext`, and an author's callback passes it back to
/// the runtime's marshalling entry points.
pub const JanetMarshalContext = struct {
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
/// There is one, and there was very nearly two: an erased C description here
/// and a raising one in `abstract_type.zig`, held together by a comptime walk
/// over both field lists and bridged at 155 call sites. That existed so a C
/// header could keep declaring the erased shape while Zig dispatched through
/// the error union, and with no such header the two were describing one thing
/// twice.
///
/// It is declared *here* rather than in `abstract_type.zig`, which owns the
/// interface, because `JanetAbstractHead.type` and `JanetMarshalContext.at`
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
/// `DESIGN.md` section 5 entire. Eleven of these objects were published as
/// *data* symbols -- `janet_peg_type`, `janet_stream_type`, `janet_file_type`
/// and eight more -- and Zig refuses to `@export` a struct with automatic
/// layout, which a slice field forces. All eleven were retired, on the ground
/// that a data export is unusable without a layout to read it by and no such
/// layout is published. Nothing observes the field order, so nothing has to
/// fix it.
pub const AbstractType = struct {
    name: []const u8,
    gc: ?*const fn (data: ?*anyopaque, len: usize) callconv(.c) void = null,
    gcmark: ?*const fn (data: ?*anyopaque, len: usize) callconv(.c) void = null,
    get: ?*const fn (data: ?*anyopaque, key: repr.Value) error{JanetSignal}!?repr.Value = null,
    put: ?*const fn (data: ?*anyopaque, key: repr.Value, value: repr.Value) error{JanetSignal}!void = null,
    marshal: ?*const fn (p: ?*anyopaque, ctx: *JanetMarshalContext) error{JanetSignal}!void = null,
    unmarshal: ?*const fn (ctx: *JanetMarshalContext) error{JanetSignal}!?*anyopaque = null,
    tostring: ?*const fn (p: ?*anyopaque, buffer: *Buffer) error{JanetSignal}!void = null,
    compare: ?*const fn (lhs: ?*anyopaque, rhs: ?*anyopaque) callconv(.c) i32 = null,
    hash: ?*const fn (p: ?*anyopaque, len: usize) callconv(.c) i32 = null,
    next: ?*const fn (p: ?*anyopaque, key: repr.Value) error{JanetSignal}!repr.Value = null,
    call: ?*const fn (p: ?*anyopaque, argc: i32, argv: [*]repr.Value) error{JanetSignal}!repr.Value = null,
    length: ?*const fn (p: ?*anyopaque, len: usize) error{JanetSignal}!usize = null,
    bytes: ?*const fn (p: ?*anyopaque, len: usize) callconv(.c) JanetByteView = null,
    gcperthread: ?*const fn (data: ?*anyopaque, len: usize) callconv(.c) void = null,
};

/// The width of a refcount. Windows' `InterlockedIncrement` takes a `LONG`;
/// everywhere else it is an `i32`.
///
/// **Author-side, at one remove:** `JanetGCData.refcount` is one, so it fixes
/// that union's size and with it where `JanetAbstractHead.type` sits. See
/// `JanetGCObject`.
pub const JanetAtomicInt = if (builtin.os.tag == .windows) c_long else i32;

/// `JanetGCObject.data`: a block is either on the heap list or refcounted.
///
/// **Author-side, at one remove:** a by-value field of `JanetGCObject`. See
/// there.
pub const JanetGCData = extern union {
    next: ?*JanetGCObject,
    refcount: JanetAtomicInt,
};

/// The collector's header, which every heap block opens with.
///
/// **Author-side, at one remove:** `JanetAbstractHead` opens with one, so its
/// size and alignment are what put `type` where `abstract_type.ofAbstract`
/// reads it. An author never touches the flags; the layout still has to agree,
/// which is why this travelled with the head rather than staying behind.
/// It carries no methods, and that is deliberate. `memoryType` and
/// `setMemoryType` used to be declared here, and a method cannot live outside
/// its struct -- so `MemoryType` had to be in this file too, with no
/// author-side caller of its own. Nothing an author compiles reads a memory
/// type. The two accessors are `gc.memoryTypeOf` and `gc.setMemoryTypeOf`, and
/// the enum went with them.
pub const JanetGCObject = extern struct {
    flags: i32 = 0,
    data: JanetGCData = std.mem.zeroes(JanetGCData),
};

/// The header in front of an abstract's payload.
///
/// **Author-side:** `abstract_type.ofAbstract` reads `type` out of one to start
/// a dispatch, and that is the whole of what an author's compilation does with
/// it -- but doing it needs the field order, so the layout is agreed.
pub const JanetAbstractHead = extern struct {
    gc: JanetGCObject = .{},
    type: *const AbstractType,
    size: usize = 0,
    _data: [0]c_longlong = std.mem.zeroes([0]c_longlong),
    pub fn data(_self: anytype) @TypeOf(&_self._data[0]) {
        return @ptrCast(@alignCast(&_self._data));
    }
};

/// Where an abstract's payload begins inside its allocation.
///
/// **Author-side:** the offset `abstractHead` subtracts. It is `@offsetOf`
/// rather than `@sizeOf` of the head, for the reason `DESIGN.md` section 3
/// gives: the compiler reports where it put the payload rather than where it
/// ought to go. The two agree on every layout Claret builds today.
pub const abstract_payload = @offsetOf(JanetAbstractHead, "_data");

/// Recover an abstract's head from its payload.
///
/// **Author-side:** `abstract_type.ofAbstract` calls it. **The subtraction is
/// here and not duplicated across the boundary** -- that is the reason it is
/// in this file rather than reimplemented on the author's side, where a stale
/// copy would read a live object at the wrong offset and say nothing.
///
/// The parameter is `?*const anyopaque` rather than `JanetAbstract` so that a
/// `*const` caller needs no cast; the head itself is mutable, as every caller
/// marks or frees through it.
pub inline fn abstractHead(a: ?*const anyopaque) *JanetAbstractHead {
    return @ptrFromInt(@intFromPtr(a) -% abstract_payload);
}
