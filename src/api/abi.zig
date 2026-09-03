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
//! **The rule for what a type may be.** A type crosses to an author only if it
//! is a **read-only view** consumed without a further crossing, or a
//! **capability** the runtime hands in and the author can only hand back.
//! Anything an author can obtain from a `Value` or turn into a `Value` is
//! addressed by that `Value` and never as a pointer, and a capability is never
//! convertible to or from a `Value` on the author's side.
//!
//! A capability is `opaque {}`, so an author holds a *pointer* to one and can
//! neither read a field nor make one. `Env`, `Render`, `Marshal`, `Unmarshal`,
//! `Loop` and `Wake` below are the six; the runtime's `tables.Table`,
//! `buffers.Buffer`, `marsh.MarshalState`, `marsh.UnmarshalState` and -- for
//! the last two -- `vm/state.zig`'s `Vm` keep the layouts they stand for. One
//! pointer crosses, so the two layouts need not agree: the runtime casts where
//! it implements a callback and where it dispatches through one, and
//! `cabi_check.zig`'s `capabilityFor` is where that substitution is written
//! down.
//!
//! The author-side files are `module.zig`, `abstract_type.zig`, `raise.zig`
//! and `crossings.zig` -- the four this package compiles *into* a module --
//! plus whatever the author writes on top of them.

const std = @import("std");
const builtin = @import("builtin");
const repr = @import("repr");

// ---------------------------------------------------------------------------
// The capabilities
// ---------------------------------------------------------------------------

/// The authority to define a binding in the environment a module is loading
/// into.
///
/// **Author-side:** `module.zig`'s `Env` is this type, so it is what a
/// module's entry point is handed and what `module.cfuns` and `module.def`
/// register into. It is named for what it permits rather than for
/// `tables.Table`, which is what the pointer lands on: an author never reads a
/// field of one, because every operation on an environment is a call across
/// the symbol boundary.
pub const Env = opaque {};

/// The authority to append bytes to the buffer a value is being rendered into.
///
/// **Author-side:** `AbstractType.tostring` and `abstract_type.Spec`'s
/// `tostring` slot take a `*Render`, and `module.push` and `module.format` are
/// what an author appends with.
///
/// **It is a capability rather than a `Value` because the buffer behind it may
/// not be collectable.** Which buffer arrives depends on the caller: `%V` into
/// a user's buffer and `print` into one hand the callback an ordinary heap
/// buffer, but `pp.zig`'s `description` and `toString` render into a *stack
/// local* prepared by `buffers.init`, which sets `gc.data.next` to null and
/// the disabled flag so the block is never linked into the heap list. A
/// `Value` an author kept would therefore sometimes outlive the frame it
/// points into, and nothing at the callback says which case it is in.
pub const Render = opaque {};

/// The authority to append to the stream a value is being marshalled into.
///
/// **Author-side:** `abstract_type.Spec`'s `marshal` slot takes a `*Marshal`,
/// and `module.zig`'s `push*` functions are what an author appends with.
///
/// **The push side and the pull side are two types, not one.** The runtime
/// builds each at its own site -- `marsh.zig`'s `marshalOneAbstract` and
/// `unmarshalOneAbstract` -- and one bidirectional type would let a `pull*`
/// inside a `marshal` callback compile and then read a stream that is not
/// there. Two types make that a compile error at the callback's own
/// definition, which is where `DESIGN.md` section 5 puts every other decision
/// about a module author's mistake.
pub const Marshal = opaque {};

/// The authority to read from the stream a value is being unmarshalled from.
///
/// **Author-side:** `abstract_type.Spec`'s `unmarshal` slot takes a
/// `*Unmarshal`, and `module.zig`'s `pull*` functions are what an author reads
/// with. See `Marshal` for why the two directions are separate types.
pub const Unmarshal = opaque {};

/// The authority to ask the event loop to run a callback at its next turn.
///
/// **Author-side:** `module.loop` answers one and `module.post` is the only
/// function that accepts one. A module's own thread holds it across the span
/// it is doing work for, which makes this the first capability an author *asks
/// for* rather than is handed, and the first that is used from a thread the
/// runtime did not start.
///
/// **`post` is the whole of what it permits, and that is why it is not the
/// same type as `Wake`.** Behind both is the `Vm` the loop belongs to. A
/// worker thread that could reach `wake` would resume a fiber from a thread
/// with no VM, on a scheduler queue with no lock; two types make that
/// unspellable rather than merely undocumented.
///
/// **Its lifetime is the runtime's**: valid until the VM that answered it
/// shuts down. A module whose thread holds one is what has to stop that
/// thread first, and that is the one ownership contract on this surface.
pub const Loop = opaque {};

/// The authority to put a fiber back on the run queue with a value.
///
/// **Author-side:** the runtime hands one to a posted callback as its first
/// parameter, and `module.wake` is the only function that accepts one. It is
/// handed in for one call in the way `Render` is, and it is valid for that
/// call only: the callback runs on the loop thread between two fibers, which
/// is the one moment resuming a fiber is safe.
///
/// See `Loop` for why the two are separate types over the same pointer.
pub const Wake = opaque {};

/// The alignment a function pointer must carry to survive being wrapped.
///
/// Under 64-bit nanboxing with a nonzero pointer shift, `repr.fromPointer`
/// stores a pointer shifted right and `repr.toPointer` shifts it back, so the
/// low `nanbox_pointer_shift` bits are discarded. `16` satisfies every shift
/// the build accepts. `module.fn_align` is this, and its doc is where an
/// author reads it.
pub const fn_align = 16;

/// What `post` asks the loop thread to run.
///
/// `callconv(.c)` because it travels through the runtime's own event message,
/// and a plain pointer beside it because the context is the module's and the
/// runtime never reads it. **It cannot raise**, which is the same contract the
/// six non-raising abstract-type slots carry and for the same reason: it runs
/// off the self-pipe with no scope above it to raise into.
///
/// Building a `Value` inside one is allowed. Allocating through the collector
/// is fatal on failure rather than a raise, and no safe point runs between
/// fibers on the loop thread -- `ev.zig`'s `loop1` calls `continueSignal` once
/// per queued task and reaches nothing else that collects.
///
/// **The alignment is in the type, and it has to be.** `capi.zig`'s `post`
/// carries this pointer to the loop thread in the event message's `argj` slot,
/// which is a `repr.Value` -- and a pointer-tagged `Value` discards the low
/// `nanbox_pointer_shift` bits. A cfunction meets the same hazard and answers
/// it the same way, except that a cfunction's alignment is checked at
/// registration by `registry.checkPointerAlign` and a posted callback is
/// registered nowhere. Stating it here makes an under-aligned one a coercion
/// error at the author's own `&callback`, which is the only place it can still
/// be diagnosed.
pub const PostCallback = *align(fn_align) const fn (wake: *Wake, ctx: *anyopaque) callconv(.c) void;

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
    // `FiberStatus`'s own table is below, beside that enum; the claim that
    // every signal value is also a status value is there too, because it is a
    // claim about the wider of the two vocabularies.
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

/// What a fiber's status is, which is what `pcall` hands back a fiber to be
/// asked.
///
/// **Author-side:** `module.pcall` answers a fiber and `module.fiberStatus`
/// answers this over it, so a module that has to look at a yield rather than
/// propagate it reads the status here. `value/fibers.zig` aliases the name and
/// holds every operation over a fiber, which is the split `KV`, `Method` and
/// `ByteView` already have.
///
/// **This is a vocabulary and not a layout**, which is the distinction
/// `DESIGN.md` section 15's invariant turns on: an enum is a numbering the two
/// compilations agree on, where a layout is a type an author is handed. So
/// this file gains a declaration and `tools/check/layouts.txt` gains no row.
///
/// **The first fourteen are the signal's**, which is why `utils.zig` carries
/// two name tables rather than one and why `vm.zig` can read a status out of a
/// fiber's flag word and use it as a signal. `new` and `alive` are the two a
/// signal has no name for.
///
/// The stored width is six bits of `fibers.FiberFlags`, and the assertion that
/// every member fits is in `value/fibers.zig` beside `statusOf`, the reader
/// that narrows to it: this file cannot see the flag word.
pub const FiberStatus = enum(c_uint) {
    dead = 0,
    @"error" = 1,
    debug = 2,
    pending = 3,
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
    new = 14,
    alive = 15,
};

comptime {
    // Against upstream Janet at `17b3f8c4`. The values are marshalled -- a
    // fiber's status travels in an image -- so a shift here is a wrong answer
    // from a working program rather than a build failure. The table is the
    // whole population, for the reason `Signal`'s is.
    const expected_status = [_]struct { FiberStatus, comptime_int }{
        .{ .dead, 0 },   .{ .@"error", 1 }, .{ .debug, 2 },  .{ .pending, 3 },
        .{ .user0, 4 },  .{ .user1, 5 },    .{ .user2, 6 },  .{ .user3, 7 },
        .{ .user4, 8 },  .{ .user5, 9 },    .{ .user6, 10 }, .{ .user7, 11 },
        .{ .user8, 12 }, .{ .user9, 13 },   .{ .new, 14 },   .{ .alive, 15 },
    };
    std.debug.assert(expected_status.len == @typeInfo(FiberStatus).@"enum".fields.len);
    for (expected_status) |row| std.debug.assert(@intFromEnum(row[0]) == row[1]);
    // Every signal value is also a status value, which is what lets `vm.zig`
    // read six bits out of a fiber's flag word and hand the result on as a
    // signal. It is a claim about *values* and not about names: `ok` is `dead`
    // at 0 and `yield` is `pending` at 3, and ten of the fourteen names do
    // coincide, which is why `utils.zig` carries two tables.
    for (@typeInfo(Signal).@"enum".fields) |f| {
        var found = false;
        for (@typeInfo(FiberStatus).@"enum".fields) |g| {
            if (f.value == g.value) found = true;
        }
        std.debug.assert(found);
    }
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
// The views
// ---------------------------------------------------------------------------
//
// **A view is a pointer to elements and a count, and the three differ only in
// what an element is**: a `u8`, a `Value`, or a `KV`. They are the other half
// of `DESIGN.md` section 15's rule -- a heap type an author can obtain from a
// `Value` is read through a view and never handed over as a pointer to the
// aggregate itself, so `strings`, `tuples.Tuple`, `arrays.Array`,
// `structs.Struct`, `tables.Table` and `buffers.Buffer` all stay inside the
// runtime while their contents cross. `Range` is here for the same reason and
// is not a view: it is the pair of folded indices a slice argument answers.
//
// **A view is not a capability**, and does not go in `cabi_check.zig`'s
// `capabilityFor`. It carries no authority and is handed back to nothing: the
// runtime answers one and the author reads it. How long one stays valid
// differs by what it points into, and that is stated at the `module.zig`
// getter that answers it, which is where an author meets it.
//
// **They are `extern` because each crosses a `callconv(.c)` signature.** A
// slice has no guaranteed in-memory representation, so the crossing carries
// the struct and `module.zig` rebuilds the slice on the author's side. The
// heads these point into -- a string's, a tuple's, a struct's, and the
// `Table` and `Array` structs -- stay internal; `DESIGN.md` section 4 is that
// decision and nothing here weakens it.

/// A byte sequence and its length, as `args.bytesView` answers it.
///
/// **Author-side:** `abstract_type.Spec`'s `bytes` callback returns one, so an
/// author writing a byte-like abstract declares this shape and the runtime
/// reads it back; and `janet_getbytes` answers one, which `module.getBytes`
/// rebuilds as a `[]const u8`.
///
/// `len` is `usize` because it is a length, where upstream declares the same
/// field `int32_t`. Every loop in the tree that walks a byte view takes its
/// counter's type from this field, so the width here is what decides whether
/// the indexing needs a cast.
pub const ByteView = extern struct {
    bytes: ?[*]const u8,
    len: usize = 0,
};

/// The elements of a tuple or an array, as `args.argIndexed` answers them.
///
/// **Author-side:** `janet_getindexed` returns one and `module.getIndexed`
/// rebuilds the `[]const Value`. It is `ByteView`'s analogue over the other
/// element type, and it is a separate declaration for the only reason a view
/// ever is: the element type is what a view *is*.
///
/// **`items` is optional, and no runtime path answers the null.** An empty
/// array does have a null data pointer -- `arrays.init(a, 0)` leaves it so and
/// `array/trim` restores it -- but `args.argIndexed` substitutes the empty
/// slice for it *before* this struct is built, so what crosses is always a
/// real pointer with a zero length. The optional is the field's declared
/// default and a formality on the author's side, not a case the runtime
/// produces.
pub const IndexedView = extern struct {
    items: ?[*]const repr.Value = null,
    len: usize = 0,
};

/// One entry of a table or a struct: a key beside its value.
///
/// **Author-side:** `DictView` points at an array of these, so an author
/// walking a dictionary reads both fields of each.
///
/// **The declaration is here and every operation over it is in
/// `value/tables.zig`**, which aliases this name -- the treatment
/// `AbstractHead`, `Method` and `ByteView` already get. A layout both
/// compilations spell has to be declared once, and `tools/check/layouts.txt`
/// carries the single row this produces.
pub const KV = extern struct {
    key: repr.Value = std.mem.zeroes(repr.Value),
    value: repr.Value = std.mem.zeroes(repr.Value),
};

/// A table's or a struct's entries, as `args.dictionaryView` answers them.
///
/// **Author-side:** `janet_getdictionary` returns one and
/// `module.getDictionary` hands it straight over, because unlike the other two
/// there is no slice to rebuild -- a dictionary walk needs all three numbers.
///
/// **Three quantities rather than two.** `kvs` is the whole hash array, `cap`
/// long, and `len` is how many of its slots are occupied: a walk reads every
/// slot and skips the empty ones, so neither number alone describes it. Both
/// are counts.
pub const DictView = extern struct {
    kvs: ?[*]const KV = null,
    len: usize = 0,
    cap: usize = 0,
};

/// A slice argument's two folded indices, as `args.getSlice` answers them.
///
/// **Author-side:** `janet_getrange` returns one and `module.getRange` hands
/// it over unchanged.
///
/// **`i32` because a Janet index is `i32`**, not because the C original said
/// so: `args.range` folds a negative index against the length and reports a
/// half-open interval in the same width the interpreter indexes with. An
/// author slicing Zig memory with one casts, and that cast is at the boundary
/// where a Janet integer becomes a Zig one, which is where `DESIGN.md`
/// section 9 puts it.
pub const Range = extern struct {
    start: i32 = 0,
    end: i32 = 0,
};

// ---------------------------------------------------------------------------
// Abstract types
// ---------------------------------------------------------------------------

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
/// interface, because `AbstractHead` names it by pointer and that is a
/// boundary declaration too.
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
    marshal: ?*const fn (p: ?*anyopaque, m: *Marshal) error{JanetSignal}!void = null,
    unmarshal: ?*const fn (u: *Unmarshal) error{JanetSignal}!?*anyopaque = null,
    tostring: ?*const fn (p: ?*anyopaque, render: *Render) error{JanetSignal}!void = null,
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
