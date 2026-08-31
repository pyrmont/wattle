//! Janet's value and runtime types, owned by Zig.
//!
//! A constant is not a declaration the compiler can re-derive and neither is a
//! layout, so these were taken from a translation of Janet's headers for four
//! configurations (native nanbox-64, `-Dnanbox=false`, `x86_64-windows-gnu`
//! and `riscv32-linux-musl`) rather than transcribed by hand. Diffing those
//! four is also what established how little actually varies: of 99
//! declarations, only `Janet`, `JanetHandle`, `JanetAtomicInt` and `Vm` differ
//! at all.
//!
//! **The pointers say what is true.** A field that points at one object says
//! `*T` or `?*T`, a field that holds a C string says `[*:0]const u8`, and a
//! counted range is a slice. `DESIGN.md` section 9 has the rules and the
//! exceptions; the core image stayed byte-identical across the pass that
//! applied them, which is what made it the oracle.
//!
//! One section at the foot of the file is not translated at all: the head
//! accessors and the payload offsets they subtract. They are here rather than
//! in the value layer because `@offsetOf` can only be spelled where the struct
//! is, and putting them anywhere else would make every caller re-derive the
//! offset from `@sizeOf` -- which is what twenty-four copies of them did. See
//! the comment above them.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config");
const repr = @import("repr");

// ---------------------------------------------------------------------------
// Foreign types
//
// `janet.h` reached these through system headers. Zig's own declarations are
// the same types; `pthread_attr_t` appears in `Vm` on every POSIX target
// and `FILE` in `JanetFile`.
// ---------------------------------------------------------------------------

pub const FILE = std.c.FILE;

/// The pthread types, from libc rather than from `janet.h` or from `std.c`.
///
/// **`std.c` is wrong for musl and it would not have shown up here.** It
/// carries glibc's `pthread_attr_t` -- 56 bytes of storage plus a `c_long` of
/// alignment -- where musl's is 56 bytes total on 64-bit and 36 on 32-bit.
/// `Vm` embeds one, so taking `std.c`'s would move every field after
/// `new_thread_attr` on every Linux target while remaining correct on macOS.
/// It was caught as `size 56 vs 64` and `36 vs 60`, and only because the
/// cross-compile targets run.
///
/// Reaching libc through `@cImport` is deliberate: "no C in the tree" and "no
/// libc" are different claims, and only the first is a goal. What matters is
/// that the size comes from the platform rather than from a table someone
/// maintains by hand.
///
/// Nothing crosses a translation boundary by value. `ev_loop.zig` declares
/// `pthread_attr_init` and its neighbours itself, taking a pointer, so these
/// types are storage and an address and nothing more.
const libc = if (builtin.os.tag == .windows) struct {
    // No pthreads. `Vm`'s Windows arm has no `new_thread_attr` field, so
    // nothing below is instantiated -- but both names still have to resolve.
    pub const pthread_attr_t = extern struct {};
    pub const pthread_t = ?*anyopaque;
    pub const pthread_mutex_t = extern struct {};
} else @cImport({
    @cInclude("pthread.h");
});

pub const pthread_attr_t = libc.pthread_attr_t;
pub const pthread_t = libc.pthread_t;
pub const pthread_mutex_t = libc.pthread_mutex_t;

/// Windows' mutex, which `ev_channel.zig` selects instead of a
/// `pthread_mutex_t`. From `std.os.windows` rather than from a `@cImport`,
/// because there is one Windows ABI -- the per-libc caveat that made
/// `std.c.pthread_attr_t` wrong does not have an analogue here. `void` off
/// Windows, where the branch selecting it is comptime-false.
pub const CRITICAL_SECTION = if (builtin.os.tag == .windows)
    std.os.windows.CRITICAL_SECTION
else
    void;

// ---------------------------------------------------------------------------
// Types translate-c left anonymous
//
// C allows an unnamed union as a member; Zig does not, so translate-c invents
// `union_unnamed_N` and renumbers it per configuration. Naming them here is
// what makes the four extractions diff cleanly against one another.
// ---------------------------------------------------------------------------

/// `JanetGCObject.data`: a block is either on the heap list or refcounted.
pub const JanetGCData = extern union {
    next: ?*JanetGCObject,
    refcount: JanetAtomicInt,
};

/// `JanetFuncEnv.as`: an environment is either still on a fiber's stack or
/// has been closed over into its own array.
pub const JanetFuncEnvRef = extern union {
    fiber: ?*JanetFiber,
    values: ?[*]repr.Value,
};

/// `JanetBinding.deprecation`. `janet.h` spells it as an unnamed enum.
pub const JanetBindingDeprecation = c_uint;

// ---------------------------------------------------------------------------
// The value representation is not here.
//
// `Value`, its three layouts and the type tag are `repr.zig`'s, a module below
// this one. The `switch (config.value_repr)` that decides whether a value is
// eight bytes or sixteen does not belong among ninety-odd unrelated
// declarations, with the operations over it six modules away.
//
// What stayed is what a heap type is: `JanetKV`, `JanetArray`, `JanetFiber`
// and fourteen more name `repr.Value` as a field or an element, which is the
// reason the representation had to go *below* this file rather than beside it.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Target-dependent scalars
// ---------------------------------------------------------------------------

/// A file or socket descriptor. Windows hands back a `HANDLE`.
pub const JanetHandle = if (builtin.os.tag == .windows) ?*anyopaque else c_int;

/// The width `janet.h` gives its atomics. Windows' `InterlockedIncrement`
/// takes a `LONG`.
pub const JanetAtomicInt = if (builtin.os.tag == .windows) c_long else i32;

// ---------------------------------------------------------------------------
// The VM state
//
// **This was six `extern struct`s and 312 lines.** A C header guarded two
// regions -- `strerror_buf`, absent on Windows, and the event-loop block with
// its four mutually exclusive backend arms -- so six combinations had to be
// written out in full, because nesting each guarded region pads the inner
// struct to its own alignment and moves every field after it.
//
// Nothing compares this layout against anything now: no host `@cImport` names
// it, and the only reads of its representation are `@sizeOf` in `vmAlloc` and
// a `std.mem.zeroes`/`allEqual` pair in `test/vm_state.zig`, each of which
// holds whatever the padding is. Padding is free, so the regions nest and the
// six arms are one.
//
// **It is not `extern` either**, and that took removing the last reason the
// storage had to be a linker symbol. `build.zig` gives `cli.zig` and
// `boot.zig` `types`, `constants` and `cabi` alone and links the runtime as an
// object, so `cabi.zig` is compiled a second time inside each of those
// executables; a declaration there that read the VM through a symbol would
// have given the client a second VM with nothing to say so. Zig 0.16 then
// refuses to export a variable of an automatic-layout type at all:
//
//     error: unable to export type 'Vm'
//     note: struct with automatic layout has no guaranteed in-memory
//           representation
//
// 4e removed the read rather than the constraint. `interop.register` answered
// a `JanetSignal` that its only caller compared against `JANET_SIGNAL_OK` and
// never otherwise looked at, so the field was carrying one bit; it answers a
// `bool` now, the client reaches no runtime state, `janet_vm` is an ordinary
// `threadlocal var`, and this and the seven aggregates below it are ordinary
// structs. `tools/check/layouts.txt` went from 112 rows to 103 and its residue count
// is still 0, which is the check that says the eight were `extern` for this
// reason and no other.
// ---------------------------------------------------------------------------

/// `strerror_r`'s scratch. Windows has no such field, and a zero-length array
/// is how a configuration drops one out of an `extern struct`.
const strerror_buf_len = if (builtin.os.tag == .windows) 0 else 256;

/// The event loop's per-mechanism state. Four arms, chosen the way
/// `build.zig` chooses the backend, and each holds exactly what its own
/// `ev/backend.zig` arm reads.
///
/// `new_thread_attr` and `selfpipe` are in three of the four rather than in
/// `VmEv`: they are what a POSIX backend needs to start a thread and to wake
/// itself, and Windows does neither that way.
pub const VmBackend = if (builtin.os.tag == .windows)
    struct {
        iocp: ?[*]?*anyopaque = null,
        connect_ex: ?*anyopaque = null,
        connect_ex_loaded: bool = false,
    }
else if (config.ev_epoll)
    struct {
        new_thread_attr: pthread_attr_t = std.mem.zeroes(pthread_attr_t),
        selfpipe: [2]JanetHandle = std.mem.zeroes([2]JanetHandle),
        epoll: c_int = 0,
        timerfd: c_int = 0,
        timer_enabled: bool = false,
    }
else if (config.ev_kqueue)
    struct {
        new_thread_attr: pthread_attr_t = std.mem.zeroes(pthread_attr_t),
        selfpipe: [2]JanetHandle = std.mem.zeroes([2]JanetHandle),
        kq: c_int = 0,
        timer_enabled: bool = false,
    }
else
    struct {
        new_thread_attr: pthread_attr_t = std.mem.zeroes(pthread_attr_t),
        selfpipe: [2]JanetHandle = std.mem.zeroes([2]JanetHandle),
        streams: ?[*]*JanetStream = null,
        stream_count: usize = 0,
        stream_capacity: usize = 0,
        fds: ?[*]std.c.pollfd = null,
    };

/// The event loop's own state, empty in a build without one.
///
/// An empty `struct` is size 0 and alignment 1, so `-Dev=false` costs
/// the VM nothing and needs no second declaration of everything above it.
pub const VmEv = if (config.ev)
    struct {
        spawn: JanetQueue = std.mem.zeroes(JanetQueue),
        /// The timer queue, a min heap ordered by `when`.
        tq: Vector(JanetTimeout) = .{},
        ev_rng: JanetRNG = std.mem.zeroes(JanetRNG),
        listener_count: JanetAtomicInt = 0,
        threaded_abstracts: JanetTable = std.mem.zeroes(JanetTable),
        active_tasks: JanetTable = std.mem.zeroes(JanetTable),
        signal_handlers: JanetTable = std.mem.zeroes(JanetTable),
        backend: VmBackend = .{},
    }
else
    struct {};

/// The two heap lists, what the collector is owed, and what suspends it.
///
/// `gc.zig` owns the lifecycle -- `gc.collectorInit` and `gc/sweep.zig`'s
/// `clearMemory` -- rather than this declaration, because a `deinit` needs
/// Janet's allocator and `types` is below the subsystems in the module graph.
pub const Collector = struct {
    /// The main heap: every block `janet_gcalloc` returns, newest first.
    blocks: ?*anyopaque = null,
    /// The weak heap, which `janet_clear_memory` deliberately does not walk.
    weak_blocks: ?*anyopaque = null,
    /// Bytes allocated since the last collection, and the threshold that ends
    /// the interval.
    next_collection: usize = 0,
    interval: usize = 0,
    block_count: usize = 0,
    /// Nesting depth, not a flag: `gcSuspend` answers the previous value and
    /// `gcResume` restores it, so a scope may nest inside another.
    suspend_count: c_int = 0,
    mark_phase: c_int = 0,
};

/// A pointer, a count and a capacity -- the shape of every array the VM grows
/// for itself -- with the rule that a null pointer is an empty collection
/// stated once rather than at each read.
///
/// **It owns the representation and not the memory**, and both halves of that
/// are deliberate. This file's import list is `config` and `repr`, so nothing
/// here can reach `janet_realloc` at all. And the four owners would not agree
/// on a shared growth if they could: the root set grows when
/// `count + 1 > capacity` and doubles `count + 1`, the registry grows on
/// `count == capacity` to `(count + 1) * 2` with a floor of 512, the scratch
/// table to `2 * capacity + 2` and deliberately multiplies by
/// `@sizeOf(JanetScratch)` where the element is a pointer (`FOUND.md`, and
/// `gc.zig`'s header), and the event loop's timer queue reports an allocation
/// failure with its own source location. Each owner keeps its rule; what they
/// share is the shape and the reads.
///
pub fn Vector(comptime T: type) type {
    return struct {
        items: ?[*]T = null,
        count: usize = 0,
        capacity: usize = 0,

        const Self = @This();

        /// The live elements.
        ///
        /// Empty rather than a trap when the collection is empty: `items` is
        /// null until the first growth, and `items.?[0..0]` traps on exactly
        /// that. It is the ordinary state of a VM that has rooted nothing,
        /// allocated no scratch and scheduled no timeout.
        pub fn slice(self: Self) []T {
            if (self.count == 0) return &.{};
            return self.items.?[0..self.count];
        }

        /// One element, by index. Bounds-checked in the modes that check,
        /// which the raw `items.?[i]` this replaces was not.
        pub fn at(self: Self, index: usize) *T {
            return &self.slice()[index];
        }

        pub fn isEmpty(self: Self) bool {
            return self.count == 0;
        }

        /// Store one element at the end and advance the count. **The caller
        /// has already made room**: growth is the owner's, for the reason in
        /// this type's header, so this is the half of an append that is the
        /// same everywhere.
        ///
        /// The slot it writes is one past the live range, which is why this
        /// is a method rather than an `at` at the call site: `at(count)` is
        /// out of bounds by construction and each of the four owners was
        /// spelling the raw `items.?[count]` to get round it.
        pub fn appendAssumingCapacity(self: *Self, val: T) void {
            // The precondition, asserted. The write goes through a many-item
            // pointer, so a slice bounds check does not stand behind it even
            // in a safe build, and an owner that forgot to grow would write
            // past the allocation with nothing to say so.
            std.debug.assert(self.count < self.capacity);
            self.items.?[self.count] = val;
            self.count += 1;
        }

        /// Remove the element at `index`, filling the hole from the end.
        ///
        /// The C originals shrink first and then read `items[count]` -- the
        /// same element, and one past the range the count then describes.
        /// Filling before shrinking is the same operation with every access
        /// inside the slice, which is what makes it checkable. Neither the
        /// root set nor the scratch table has an order a caller may depend
        /// on, which is what licenses the fill in the first place.
        pub fn swapRemove(self: *Self, index: usize) void {
            self.at(index).* = self.at(self.count - 1).*;
            self.count -= 1;
        }

        /// Remove and answer the last element.
        pub fn pop(self: *Self) T {
            const last = self.at(self.count - 1).*;
            self.count -= 1;
            return last;
        }
    };
}

/// The GC root set. A stretchy array of values the collector marks first.
pub const Roots = Vector(repr.Value);

/// The scratch table: allocations freed together at the next
/// `janet_free_all_scratch` rather than by the collector.
pub const Scratch = Vector(*JanetScratch);

/// The cfunction registry: one row per builtin, sorted by function pointer so
/// that a lookup can bisect. `registry.zig` owns the lifecycle.
///
/// `dirty` is what says the sort is owed; `registryPut` sets it and
/// `registrySort` clears it. It is the reason this is a struct holding a
/// vector rather than a vector: the sortedness is a fourth fact about the
/// rows, and it is not the vector's.
pub const Registry = struct {
    rows: Vector(JanetCFunRegistry) = .{},
    dirty: bool = false,
};

/// The symbol cache: open addressing over interned symbol names, with a
/// tombstone for a deleted entry. `value/symbols.zig` owns the lifecycle.
pub const SymbolCache = struct {
    entries: ?[*]?[*:0]const u8 = null,
    capacity: u32 = 0,
    count: u32 = 0,
    deleted: u32 = 0,
};

/// The comparison and marshalling traversal stack: `base` and `top` bound the
/// allocation and `at` is the cursor into it, which is why all three go
/// together. `value/helpers/order.zig` owns it, and its header explains why the
/// stack is the shape rather than an optimisation.
///
/// A dangling `base` is `FOUND.md`'s -- `push` decides whether to grow on
/// `base == null`, so a freed one sends it to `janet_realloc` with a pointer
/// that is already free.
pub const Traversal = struct {
    at: ?[*]JanetTraversalNode = null,
    top: ?[*]JanetTraversalNode = null,
    base: ?[*]JanetTraversalNode = null,
};

/// One interpreter's state. `janet_vm` is the thread's, and `vm/lifecycle.zig`
/// owns it.
pub const Vm = struct {
    user: ?*anyopaque = null,
    top_dyns: ?*JanetTable = null,
    core_env: ?*JanetTable = null,
    stackn: c_int = 0,
    auto_suspend: JanetAtomicInt = 0,
    fiber: ?*JanetFiber = null,
    root_fiber: ?*JanetFiber = null,
    return_reg: ?*repr.Value = null,
    coerce_error: bool = false,
    pending_signal: Signal = .ok,
    registry: Registry = .{},
    abstract_registry: ?*JanetTable = null,
    symcache: SymbolCache = .{},
    gensym_counter: [8]u8 = std.mem.zeroes([8]u8),
    gc: Collector = .{},
    roots: Roots = .{},
    scratch: Scratch = .{},
    sandbox_flags: Sandbox = .{},
    rng: JanetRNG = std.mem.zeroes(JanetRNG),
    traversal: Traversal = .{},
    strerror_buf: [strerror_buf_len]u8 = std.mem.zeroes([strerror_buf_len]u8),
    ev: VmEv = .{},
    c_raised: i32 = 0,
};

// ---------------------------------------------------------------------------
// Types translate-c left anonymous but that are not `Janet`-prefixed
// ---------------------------------------------------------------------------

/// `JanetParseState`'s per-state consumer. `janet.h` names it `Consumer`.
pub const Consumer = ?*const fn (p: *JanetParser, state: *JanetParseState, c: u8) callconv(.c) c_int;

// ---------------------------------------------------------------------------
// Everything else
//
// Identical across all four configurations extracted, so carried verbatim.
// ---------------------------------------------------------------------------

pub const JanetBuildConfig = extern struct {
    major: c_uint = 0,
    minor: c_uint = 0,
    patch: c_uint = 0,
    bits: c_uint = 0,
};
pub const JanetOSMutex = opaque {};
pub const JanetOSRWLock = opaque {};
pub const JanetChannel = opaque {};
/// `JanetSignal`. What a raise, a yield or an event asks the interpreter to
/// do, and what `janet_continue` reports back to its caller.
///
/// **Sixteen names over fourteen values.** `17b3f8c4:src/include/janet.h`
/// writes `JANET_SIGNAL_INTERRUPT = JANET_SIGNAL_USER8` and
/// `JANET_SIGNAL_EVENT = JANET_SIGNAL_USER9`; a C enum permits a duplicate
/// value and a Zig one does not, so the two aliases are declarations rather
/// than members. That is the honest rendering — an alias is what they are, and
/// a reader of the old constant list could not see it.
///
/// `enum(c_uint)` rather than a narrower width because the value crosses the C
/// ABI at eight symbols and Janet gives it an `int`-sized enum; unlike
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
    /// records that divergence and `test/signal_domain.zig` pins the
    /// replacement.
    pub fn fromWire(raw: c_uint) Signal {
        return if (raw > @intFromEnum(Signal.user9)) .user9 else @enumFromInt(raw);
    }
};

/// `JanetFiberStatus`. Stored in six bits of the fiber's flag word; see
/// `value/fibers.zig`, which owns the accessor and asserts the width.
///
/// **The first fourteen are the signal's**, which is why `utils.zig` carries
/// two name tables rather than one and why `vm.zig` can read a status out of
/// the flag word and use it as a signal. `new` and `alive` are the two a
/// signal has no name for.
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
    // Against `17b3f8c4:src/include/janet.h` lines 436-473. The values are
    // marshalled -- a fiber's status travels in an image -- so a shift here is
    // a wrong answer from a working program rather than a build failure.
    // **One expected-value table per vocabulary, in the header's order.** A
    // sample of four values and a count cannot catch a transposition: swapping
    // two unasserted members leaves both the count and every sampled value
    // correct. The table is the whole population, and the length assertion
    // beside it is what stops a member being added without a row.
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
    // signal. It is a claim about *values* and not about names: `ok` is
    // `dead` at 0 and `yield` is `pending` at 3, and ten of the fourteen names
    // do coincide, which is why `utils.zig` carries two tables.
    for (@typeInfo(Signal).@"enum".fields) |f| {
        var found = false;
        for (@typeInfo(FiberStatus).@"enum".fields) |g| {
            if (g.value == f.value) found = true;
        }
        std.debug.assert(found);
    }
}
/// Which heap type a block is, stored in the low byte of its GC header's
/// flags.
///
/// The stored width is `JANET_MEM_TYPEBITS`, which is `0xFF` -- so the field
/// is a byte, `JANET_MEM_REACHABLE` and `JANET_MEM_DISABLED` sit above it at
/// `0x100` and `0x200`, and reading the type is a truncation rather than a
/// mask. `enum(u8)` says both halves of that at once.
pub const MemoryType = enum(u8) {
    none = 0,
    string = 1,
    symbol = 2,
    array = 3,
    tuple = 4,
    table = 5,
    @"struct" = 6,
    fiber = 7,
    buffer = 8,
    function = 9,
    abstract = 10,
    funcenv = 11,
    funcdef = 12,
    threaded_abstract = 13,
    table_weakk = 14,
    table_weakv = 15,
    table_weakkv = 16,
    array_weak = 17,
};

/// `JANET_SANDBOX_*`: which capabilities have been given up.
///
/// Twenty independent bits and four names for unions of them. The bit order is
/// Janet's value order, because a `packed struct`'s first field is its least
/// significant bit; the `comptime` block asserts every position.
pub const Sandbox = packed struct(u32) {
    sandbox: bool = false,
    subprocess: bool = false,
    net_connect: bool = false,
    net_listen: bool = false,
    ffi_define: bool = false,
    fs_write: bool = false,
    fs_read: bool = false,
    hrtime: bool = false,
    env: bool = false,
    dynamic_modules: bool = false,
    fs_temp: bool = false,
    ffi_use: bool = false,
    ffi_jit: bool = false,
    signal: bool = false,
    chroot: bool = false,
    compile: bool = false,
    @"asm": bool = false,
    threads: bool = false,
    unmarshal: bool = false,
    exit: bool = false,
    _reserved: u12 = 0,

    pub const none: Sandbox = .{};

    /// `JANET_SANDBOX_ALL` is `0xFFFFFFFF` and so sets the twelve reserved
    /// bits too. That is upstream's, reproduced rather than tidied: nothing
    /// reads a reserved bit, `(os/sandbox :all)` only ever ands with it, and
    /// narrowing it would be a change to a published constant's value.
    pub const all = fromBits(0xFFFFFFFF);

    /// The three unions `janet.h` names.
    pub const ffi = of(&.{ "ffi_define", "ffi_use", "ffi_jit" });
    pub const fs = of(&.{ "fs_write", "fs_read", "fs_temp" });
    pub const net = of(&.{ "net_connect", "net_listen" });

    pub fn of(comptime names: []const [:0]const u8) Sandbox {
        comptime var out: Sandbox = .{};
        inline for (names) |n| @field(out, n) = true;
        return comptime out;
    }

    pub fn with(self: Sandbox, other: Sandbox) Sandbox {
        return fromBits(self.bits() | other.bits());
    }

    /// Whether any capability in `other` is in `self`. This is the whole of
    /// `sandboxAssert`: a forbidden set meets the given-up set.
    pub fn intersects(self: Sandbox, other: Sandbox) bool {
        return (self.bits() & other.bits()) != 0;
    }

    pub fn bits(self: Sandbox) u32 {
        return @bitCast(self);
    }
    pub fn fromBits(m: u32) Sandbox {
        return @bitCast(m);
    }
};

comptime {
    // Against `17b3f8c4:src/include/janet.h`. Reordering the fields above
    // fails here rather than silently giving away a different capability.
    std.debug.assert(@sizeOf(Sandbox) == 4);
    const S = Sandbox;
    std.debug.assert(S.of(&.{"sandbox"}).bits() == 1);
    std.debug.assert(S.of(&.{"subprocess"}).bits() == 2);
    std.debug.assert(S.of(&.{"net_connect"}).bits() == 4);
    std.debug.assert(S.of(&.{"net_listen"}).bits() == 8);
    std.debug.assert(S.of(&.{"ffi_define"}).bits() == 16);
    std.debug.assert(S.of(&.{"fs_write"}).bits() == 32);
    std.debug.assert(S.of(&.{"fs_read"}).bits() == 64);
    std.debug.assert(S.of(&.{"hrtime"}).bits() == 128);
    std.debug.assert(S.of(&.{"env"}).bits() == 256);
    std.debug.assert(S.of(&.{"dynamic_modules"}).bits() == 512);
    std.debug.assert(S.of(&.{"fs_temp"}).bits() == 1024);
    std.debug.assert(S.of(&.{"ffi_use"}).bits() == 2048);
    std.debug.assert(S.of(&.{"ffi_jit"}).bits() == 4096);
    std.debug.assert(S.of(&.{"signal"}).bits() == 8192);
    std.debug.assert(S.of(&.{"chroot"}).bits() == 16384);
    std.debug.assert(S.of(&.{"compile"}).bits() == 32768);
    std.debug.assert(S.of(&.{"asm"}).bits() == 65536);
    std.debug.assert(S.of(&.{"threads"}).bits() == 131072);
    std.debug.assert(S.of(&.{"unmarshal"}).bits() == 262144);
    std.debug.assert(S.of(&.{"exit"}).bits() == 524288);
    std.debug.assert(S.ffi.bits() == 16 | 2048 | 4096);
    std.debug.assert(S.fs.bits() == 32 | 64 | 1024);
    std.debug.assert(S.net.bits() == 4 | 8);
    std.debug.assert(S.all.bits() == 0xFFFFFFFF);
}

pub const JanetGCObject = extern struct {
    flags: i32 = 0,
    data: JanetGCData = std.mem.zeroes(JanetGCData),

    /// The block's type, which is the low byte of `flags`. One owner: three
    /// files each carried a `mem_typebits` local and the mask before 6d.
    pub inline fn memoryType(self: *const JanetGCObject) MemoryType {
        return @enumFromInt(@as(u8, @truncate(@as(u32, @bitCast(self.flags)))));
    }

    /// Write it, leaving `JANET_MEM_REACHABLE` and `JANET_MEM_DISABLED` alone.
    pub inline fn setMemoryType(self: *JanetGCObject, to: MemoryType) void {
        self.flags = (self.flags & ~@as(i32, 0xFF)) | @as(i32, @intFromEnum(to));
    }
};

comptime {
    // Against `17b3f8c4:src/core/gc.h` lines 34 and 46-64: eighteen values in
    // the header's order, and a byte-wide field to hold them.
    std.debug.assert(@sizeOf(MemoryType) == 1);
    // Every value, for the reason given beside the signal table above: five of
    // eighteen sampled left thirteen members in which a transposition would
    // compile, and this one is read out of a marshalled image.
    const expected_memory = [_]struct { MemoryType, comptime_int }{
        .{ .none, 0 },         .{ .string, 1 },             .{ .symbol, 2 },
        .{ .array, 3 },        .{ .tuple, 4 },              .{ .table, 5 },
        .{ .@"struct", 6 },    .{ .fiber, 7 },              .{ .buffer, 8 },
        .{ .function, 9 },     .{ .abstract, 10 },          .{ .funcenv, 11 },
        .{ .funcdef, 12 },     .{ .threaded_abstract, 13 }, .{ .table_weakk, 14 },
        .{ .table_weakv, 15 }, .{ .table_weakkv, 16 },      .{ .array_weak, 17 },
    };
    std.debug.assert(expected_memory.len == @typeInfo(MemoryType).@"enum".fields.len);
    for (expected_memory) |row| std.debug.assert(@intFromEnum(row[0]) == row[1]);
    // The stored field is `JANET_MEM_TYPEBITS` wide and `JANET_MEM_REACHABLE`
    // is the first bit above it, so a type can never collide with a flag.
    for (@typeInfo(MemoryType).@"enum".fields) |f| std.debug.assert(f.value <= 0xFF);
}
/// The element view a fixed-layout accessor returns, carrying the receiver's
/// constness into the result.
///
/// **Zig's constness is shallow, so an accessor has to do this by hand.** A
/// `*const JanetFuncDef` names a pointer that may not be written *through*,
/// and the `[*]u32` inside it is a separate pointer with its own constness --
/// so `fn instructions(self: *const JanetFuncDef) []u32` compiles, and lets a
/// caller holding a read-only funcdef rewrite its bytecode. Making every
/// result `[]const T` is not the answer either: there are legitimate writers,
/// and they hold a mutable receiver already.
///
/// Taking `self: anytype` and mapping the pointer's constness onto the result
/// leaves both call sites alone and makes only the wrong one a compile error.
/// `reserved` and `spare` deliberately do *not* use this: their whole purpose
/// is to hand a writer the storage outside the live range, so they keep a
/// mutable receiver and a mutable result.
fn View(comptime Self: type, comptime T: type) type {
    const info = @typeInfo(Self);
    if (info != .pointer) @compileError("a fixed-layout accessor takes a pointer receiver");
    return if (info.pointer.is_const) []const T else []T;
}

pub const JanetKV = extern struct {
    key: repr.Value = std.mem.zeroes(repr.Value),
    value: repr.Value = std.mem.zeroes(repr.Value),
};
pub const JanetTable = extern struct {
    gc: JanetGCObject = std.mem.zeroes(JanetGCObject),
    count: i32 = 0,
    capacity: i32 = 0,
    deleted: i32 = 0,
    data: ?[*]JanetKV = null,
    proto: ?*JanetTable = null,

    /// The open-addressed slot array, `capacity` long. **Not the entries**:
    /// `count` is how many slots are occupied and `deleted` how many hold a
    /// tombstone, so a walk over a table is a walk over this with a nil-key
    /// test inside it. Named `slots` rather than `slice` for that reason --
    /// `JanetArray` and `JanetBuffer` answer their live contents and this
    /// answers the probe table.
    ///
    /// Empty rather than a trap for a table that has never been grown:
    /// `janet_table_init(t, 0)` leaves `data` null with `capacity` zero, and
    /// `data.?[0..0]` traps on exactly that.
    pub inline fn slots(self: anytype) View(@TypeOf(self), JanetKV) {
        if (self.capacity <= 0) return &.{};
        return self.data.?[0..@intCast(self.capacity)];
    }
};
pub const JanetEVCallback = ?*const fn (fiber: *JanetFiber, event: JanetAsyncEvent) callconv(.c) void;
pub const JanetStream = extern struct {
    handle: JanetHandle = std.mem.zeroes(JanetHandle),
    flags: u32 = 0,
    index: u32 = 0,
    read_fiber: ?*JanetFiber = null,
    write_fiber: ?*JanetFiber = null,
    methods: ?*const anyopaque = null,
};
/// `janet.h` guards the last five fields with `#ifdef JANET_EV`: they only
/// matter for a fiber scheduled on the event loop as a root fiber.
pub const JanetFiber = if (config.ev) extern struct {
    gc: JanetGCObject = std.mem.zeroes(JanetGCObject),
    flags: i32 = 0,
    frame: i32 = 0,
    stackstart: i32 = 0,
    stacktop: i32 = 0,
    capacity: i32 = 0,
    maxstack: i32 = 0,
    env: ?*JanetTable = null,
    data: ?[*]repr.Value = null,
    child: ?*JanetFiber = null,
    last_value: repr.Value = std.mem.zeroes(repr.Value),
    sched_id: u32 = 0,
    ev_callback: JanetEVCallback = null,
    ev_stream: ?*JanetStream = null,
    ev_state: ?*anyopaque = null,
    supervisor_channel: ?*anyopaque = null,
} else extern struct {
    gc: JanetGCObject = std.mem.zeroes(JanetGCObject),
    flags: i32 = 0,
    frame: i32 = 0,
    stackstart: i32 = 0,
    stacktop: i32 = 0,
    capacity: i32 = 0,
    maxstack: i32 = 0,
    env: ?*JanetTable = null,
    data: ?[*]repr.Value = null,
    child: ?*JanetFiber = null,
    last_value: repr.Value = std.mem.zeroes(repr.Value),
};
pub const JanetScratchFinalizer = ?*const fn (?*anyopaque) callconv(.c) void;
pub const JanetScratch = extern struct {
    finalize: JanetScratchFinalizer = null,
    _mem: [0]c_longlong = std.mem.zeroes([0]c_longlong),
    pub fn mem(_self: anytype) @TypeOf(&_self.*._mem[0]) {
        return @ptrCast(@alignCast(&_self.*._mem));
    }
};
pub const JanetRNG = extern struct {
    a: u32 = 0,
    b: u32 = 0,
    c: u32 = 0,
    d: u32 = 0,
    counter: u32 = 0,
};
pub const JanetSourceMapping = extern struct {
    line: i32 = 0,
    column: i32 = 0,
};
pub const JanetString = [*:0]const u8;
pub const JanetSymbolMap = extern struct {
    birth_pc: u32 = 0,
    death_pc: u32 = 0,
    slot_index: u32 = 0,
    symbol: ?[*:0]const u8 = null,
};
pub const JanetFuncDef = extern struct {
    gc: JanetGCObject = std.mem.zeroes(JanetGCObject),
    environments: ?[*]i32 = null,
    constants: ?[*]repr.Value = null,
    defs: ?[*]*JanetFuncDef = null,
    bytecode: ?[*]u32 = null,
    closure_bitset: ?[*]u32 = null,
    sourcemap: ?[*]JanetSourceMapping = null,
    source: ?JanetString = null,
    name: ?JanetString = null,
    symbolmap: ?[*]JanetSymbolMap = null,
    flags: i32 = 0,
    slotcount: i32 = 0,
    arity: i32 = 0,
    min_arity: i32 = 0,
    max_arity: i32 = 0,
    constants_length: i32 = 0,
    bytecode_length: i32 = 0,
    environments_length: i32 = 0,
    defs_length: i32 = 0,
    symbolmap_length: i32 = 0,
    named_args_count: i32 = 0,

    // The seven runs, each a pointer with a length somewhere else in the
    // structure. The pairing is what the accessor states, and it is not
    // derivable from the field names -- `sourcemap` is as long as the
    // *bytecode*, and `closure_bitset` is a bit per slot rounded up to a word.
    // The layout is fixed by `abi,field,repr` and does not move; what these
    // replace is 110 raw indexings.

    /// The constant pool. `JOP_LOAD_CONSTANT` indexes it.
    pub inline fn constantValues(self: anytype) View(@TypeOf(self), repr.Value) {
        if (self.constants_length <= 0) return &.{};
        return self.constants.?[0..@intCast(self.constants_length)];
    }

    /// The bytecode.
    pub inline fn instructions(self: anytype) View(@TypeOf(self), u32) {
        if (self.bytecode_length <= 0) return &.{};
        return self.bytecode.?[0..@intCast(self.bytecode_length)];
    }

    /// The captured environments, by index into the enclosing function's.
    pub inline fn environmentIndices(self: anytype) View(@TypeOf(self), i32) {
        if (self.environments_length <= 0) return &.{};
        return self.environments.?[0..@intCast(self.environments_length)];
    }

    /// The nested function definitions this one closes over.
    pub inline fn subdefs(self: anytype) View(@TypeOf(self), *JanetFuncDef) {
        if (self.defs_length <= 0) return &.{};
        return self.defs.?[0..@intCast(self.defs_length)];
    }

    /// The debug symbol map: one entry per named slot, with the range of
    /// instructions it is live over.
    pub inline fn symbols(self: anytype) View(@TypeOf(self), JanetSymbolMap) {
        if (self.symbolmap_length <= 0) return &.{};
        return self.symbolmap.?[0..@intCast(self.symbolmap_length)];
    }

    /// One source position per instruction. **Its length is
    /// `bytecode_length`**, which is the pairing this accessor exists to say:
    /// there is no `sourcemap_length` field and every caller was deriving it.
    /// Null with a non-zero bytecode length under `-Dsourcemaps=false`, which
    /// is why the pointer is tested and not only the count.
    pub inline fn sourceMappings(self: anytype) View(@TypeOf(self), JanetSourceMapping) {
        if (self.bytecode_length <= 0) return &.{};
        const map = self.sourcemap orelse return &.{};
        return map[0..@intCast(self.bytecode_length)];
    }

    /// One bit per slot, rounded up to a word, saying which slots a closure
    /// captures. Absent -- null -- when the function captures nothing, which
    /// is the ordinary case and is why this answers empty rather than
    /// unwrapping.
    pub inline fn closureBits(self: anytype) View(@TypeOf(self), u32) {
        const bits = self.closure_bitset orelse return &.{};
        if (self.slotcount <= 0) return &.{};
        return bits[0..@intCast((self.slotcount + 31) >> 5)];
    }
};
pub const JanetFuncEnv = extern struct {
    gc: JanetGCObject = std.mem.zeroes(JanetGCObject),
    as: JanetFuncEnvRef = std.mem.zeroes(JanetFuncEnvRef),
    length: i32 = 0,
    offset: i32 = 0,
};
pub const JanetFunction = extern struct {
    gc: JanetGCObject = std.mem.zeroes(JanetGCObject),
    def: ?*JanetFuncDef = null,
    _envs: [0]?*JanetFuncEnv = std.mem.zeroes([0]?*JanetFuncEnv),
    pub fn envs(_self: anytype) @TypeOf(&_self.*._envs[0]) {
        return @ptrCast(@alignCast(&_self.*._envs));
    }
};
pub const JanetArray = extern struct {
    gc: JanetGCObject = std.mem.zeroes(JanetGCObject),
    count: i32 = 0,
    capacity: i32 = 0,
    data: ?[*]repr.Value = null,

    /// The live elements. Empty rather than a trap for an array that has
    /// never been grown: `janet_array_init(a, 0)` leaves `data` null, which
    /// is the ordinary state of `(array/new 0)` and of every fresh
    /// `JanetArray` on a fiber's stack.
    pub inline fn slice(self: anytype) View(@TypeOf(self), repr.Value) {
        if (self.count <= 0) return &.{};
        return self.data.?[0..@intCast(self.count)];
    }

    /// Store one element at the end and advance the count. **The caller has
    /// already made room** -- `arrays.ensure` -- because growth reads the
    /// collector's allocator and this type cannot.
    ///
    /// The slot it writes is one past `slice()`, which is why it is a method
    /// rather than an index at the call site. See `Vector` above: the same
    /// pair, for the same reason, on the arrays the VM grows for itself.
    pub inline fn appendAssumingCapacity(self: *JanetArray, x: repr.Value) void {
        // See `Vector.appendAssumingCapacity`. The count is signed in this
        // fixed layout, so non-negativity is part of the precondition rather
        // than a property of the type.
        std.debug.assert(self.count >= 0);
        std.debug.assert(self.count < self.capacity);
        self.data.?[@intCast(self.count)] = x;
        self.count += 1;
    }

    /// The allocation, `capacity` long, for a caller that fills the elements
    /// *before* declaring the count.
    ///
    /// The parser does that on purpose: it pops its argument stack backwards
    /// into a fresh array and only then says how long the array is, so that
    /// a collection in the middle -- there is none, but the order is the C
    /// original's -- would never see an uninitialised element. `slice()` is
    /// empty throughout that loop, which is correct and not what the writer
    /// wants.
    pub inline fn reserved(self: *JanetArray) []repr.Value {
        if (self.capacity <= 0) return &.{};
        return self.data.?[0..@intCast(self.capacity)];
    }

    /// Remove and answer the last element. The caller has checked it is not
    /// empty.
    pub inline fn popAssumingAny(self: *JanetArray) repr.Value {
        const last = self.slice()[@intCast(self.count - 1)];
        self.count -= 1;
        return last;
    }
};
pub const JanetBuffer = extern struct {
    gc: JanetGCObject = std.mem.zeroes(JanetGCObject),
    count: i32 = 0,
    capacity: i32 = 0,
    data: ?[*]u8 = null,

    /// The bytes written so far. Empty rather than a trap for a buffer that
    /// has never been grown: `janet_buffer_init(b, 0)` leaves `data` null,
    /// and `@"" ` is the commonest value in the suites.
    pub inline fn slice(self: anytype) View(@TypeOf(self), u8) {
        if (self.count <= 0) return &.{};
        return self.data.?[0..@intCast(self.count)];
    }

    /// Store one byte at the end and advance the count. **The caller has
    /// already made room** -- `buffers.extra` or `buffers.ensure`.
    pub inline fn appendAssumingCapacity(self: *JanetBuffer, byte: u8) void {
        std.debug.assert(self.count >= 0);
        std.debug.assert(self.count < self.capacity);
        self.data.?[@intCast(self.count)] = byte;
        self.count += 1;
    }

    /// The allocation, `capacity` long, for the two callers that read or
    /// write outside the live range on purpose: `snprintf` fills past the
    /// end and then says how much it wrote, and the pretty-printer's
    /// newline compaction shortens the count first and then compacts what
    /// is still there into the space that leaves.
    pub inline fn reserved(self: *JanetBuffer) []u8 {
        if (self.capacity <= 0) return &.{};
        return self.data.?[0..@intCast(self.capacity)];
    }

    /// The room past the end, `capacity - count` bytes of it.
    pub inline fn spare(self: *JanetBuffer) []u8 {
        if (self.capacity <= self.count) return &.{};
        return self.reserved()[@intCast(self.count)..];
    }
};
pub const JanetTupleHead = extern struct {
    gc: JanetGCObject = std.mem.zeroes(JanetGCObject),
    length: i32 = 0,
    hash: i32 = 0,
    sm_line: i32 = 0,
    sm_column: i32 = 0,
    _data: [0]repr.Value = std.mem.zeroes([0]repr.Value),
    pub fn data(_self: anytype) @TypeOf(&_self.*._data[0]) {
        return @ptrCast(@alignCast(&_self.*._data));
    }
};
pub const JanetStructHead = extern struct {
    gc: JanetGCObject = std.mem.zeroes(JanetGCObject),
    length: i32 = 0,
    hash: i32 = 0,
    capacity: i32 = 0,
    proto: ?[*]const JanetKV = null,
    _data: [0]JanetKV = std.mem.zeroes([0]JanetKV),
    pub fn data(_self: anytype) @TypeOf(&_self.*._data[0]) {
        return @ptrCast(@alignCast(&_self.*._data));
    }
};
pub const JanetStringHead = extern struct {
    gc: JanetGCObject = std.mem.zeroes(JanetGCObject),
    length: i32 = 0,
    hash: i32 = 0,
    _data: [0]u8 = std.mem.zeroes([0]u8),
    pub fn data(_self: anytype) @TypeOf(&_self.*._data[0]) {
        return @ptrCast(@alignCast(&_self.*._data));
    }
};
pub const JanetMarshalContext = extern struct {
    m_state: ?*anyopaque = null,
    u_state: ?*anyopaque = null,
    flags: c_int = 0,
    data: ?[*]const u8 = null,
    at: ?*const AbstractType = null,
};
pub const JanetByteView = extern struct {
    bytes: ?[*]const u8,
    len: i32 = 0,
};
/// An abstract type's dispatch description: the one the runtime stores, the
/// one a module author declares, and the only one there is.
///
/// There is one, and there was very nearly two: an erased C description here
/// and a raising one in `abstract_type.zig`, held together by a comptime walk
/// over both field lists and bridged at 155 call sites. That existed so a C
/// header could keep declaring the erased shape while Zig dispatched through
/// the error union, and with no such header the two were describing one thing
/// twice.
///
/// It is declared *here* rather than in `abstract_type.zig`, which owns the
/// interface, because three structures in this file name it by pointer --
/// `JanetAbstractHead.type`, `JanetMarshalContext.at` and `JanetArgFault.at`
/// -- and `types` is a module below the subsystems.
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
    gc: ?*const fn (data: ?*anyopaque, len: usize) callconv(.c) c_int = null,
    gcmark: ?*const fn (data: ?*anyopaque, len: usize) callconv(.c) c_int = null,
    get: ?*const fn (data: ?*anyopaque, key: repr.Value, out: *repr.Value) error{JanetSignal}!c_int = null,
    put: ?*const fn (data: ?*anyopaque, key: repr.Value, value: repr.Value) error{JanetSignal}!void = null,
    marshal: ?*const fn (p: ?*anyopaque, ctx: *JanetMarshalContext) error{JanetSignal}!void = null,
    unmarshal: ?*const fn (ctx: *JanetMarshalContext) error{JanetSignal}!?*anyopaque = null,
    tostring: ?*const fn (p: ?*anyopaque, buffer: *JanetBuffer) error{JanetSignal}!void = null,
    compare: ?*const fn (lhs: ?*anyopaque, rhs: ?*anyopaque) callconv(.c) c_int = null,
    hash: ?*const fn (p: ?*anyopaque, len: usize) callconv(.c) i32 = null,
    next: ?*const fn (p: ?*anyopaque, key: repr.Value) error{JanetSignal}!repr.Value = null,
    call: ?*const fn (p: ?*anyopaque, argc: i32, argv: [*]repr.Value) error{JanetSignal}!repr.Value = null,
    length: ?*const fn (p: ?*anyopaque, len: usize) error{JanetSignal}!usize = null,
    bytes: ?*const fn (p: ?*anyopaque, len: usize) callconv(.c) JanetByteView = null,
    gcperthread: ?*const fn (data: ?*anyopaque, len: usize) callconv(.c) c_int = null,
};
pub const JanetAbstractHead = extern struct {
    gc: JanetGCObject = std.mem.zeroes(JanetGCObject),
    type: *const AbstractType,
    size: usize = 0,
    _data: [0]c_longlong = std.mem.zeroes([0]c_longlong),
    pub fn data(_self: anytype) @TypeOf(&_self.*._data[0]) {
        return @ptrCast(@alignCast(&_self.*._data));
    }
};
pub const JanetStackFrame = extern struct {
    func: ?*JanetFunction = null,
    pc: ?[*]u32 = null,
    env: ?*JanetFuncEnv = null,
    prevframe: i32 = 0,
    flags: i32 = 0,
};
pub const JanetCFunction = ?*const fn (argc: i32, argv: [*c]repr.Value) callconv(.c) repr.Value;
/// One registration row: a name, a cfunction, and three pieces of metadata a
/// build may omit.
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
pub const JanetMethod = extern struct {
    name: ?[*:0]const u8 = null,
    cfun: JanetCFunction = null,
};
pub const JanetView = extern struct {
    items: ?[*]const repr.Value = null,
    len: i32 = 0,
};
pub const JanetDictView = extern struct {
    kvs: ?[*]const JanetKV = null,
    len: i32 = 0,
    cap: i32 = 0,
};
pub const JanetRange = extern struct {
    start: i32 = 0,
    end: i32 = 0,
};
pub const JanetSymbol = [*:0]const u8;
pub const JanetKeyword = [*:0]const u8;
pub const JanetTuple = [*]const repr.Value;
pub const JanetStruct = [*]const JanetKV;
pub const JanetAbstract = ?*anyopaque;
pub const JanetAsyncEvent = c_uint;
pub const JanetAsyncMode = c_uint;
pub const JanetParser = extern struct {
    args: ?[*]repr.Value = null,
    @"error": ?[*:0]const u8 = null,
    states: ?[*]JanetParseState = null,
    buf: ?[*]u8 = null,
    argcount: usize = 0,
    argcap: usize = 0,
    statecount: usize = 0,
    statecap: usize = 0,
    bufcount: usize = 0,
    bufcap: usize = 0,
    line: usize = 0,
    column: usize = 0,
    pending: usize = 0,
    lookback: c_int = 0,
    flag: c_int = 0,
};
pub const JanetParseState = extern struct {
    counter: i32 = 0,
    argn: i32 = 0,
    flags: c_int = 0,
    line: usize = 0,
    column: usize = 0,
    consumer: Consumer = null,
};
pub const JanetParserStatus = c_uint;
pub const JanetFile = extern struct {
    file: ?*FILE = null,
    flags: i32 = 0,
    vbufsize: usize = 0,
};
pub const JanetTryState = extern struct {
    stackn: i32 = 0,
    gc_handle: c_int = 0,
    vm_fiber: ?*JanetFiber = null,
    vm_return_reg: ?*repr.Value = null,
    payload: repr.Value = std.mem.zeroes(repr.Value),
    coerce_error: c_int = 0,
};
pub const JanetOpArgType = c_uint;
pub const JanetInstructionType = c_uint;
pub const JanetOpCode = c_uint;
pub const JanetEVGenericMessage = extern struct {
    tag: c_int = 0,
    argi: c_int = 0,
    argp: ?*anyopaque = null,
    argj: repr.Value = std.mem.zeroes(repr.Value),
    fiber: ?*JanetFiber = null,
};
pub const JanetThreadedSubroutine = ?*const fn (arguments: JanetEVGenericMessage) callconv(.c) JanetEVGenericMessage;
pub const JanetCallback = ?*const fn (return_value: JanetEVGenericMessage) callconv(.c) void;
pub const JanetThreadedCallback = ?*const fn (return_value: JanetEVGenericMessage) callconv(.c) void;
pub const JanetAssembleStatus = c_uint;
pub const JanetAssembleResult = extern struct {
    funcdef: ?*JanetFuncDef = null,
    @"error": ?JanetString = null,
    status: JanetAssembleStatus = std.mem.zeroes(JanetAssembleStatus),
};
pub const JanetCompileStatus = c_uint;
pub const JanetCompileResult = extern struct {
    funcdef: ?*JanetFuncDef = null,
    @"error": ?JanetString = null,
    macrofiber: ?*JanetFiber = null,
    error_mapping: JanetSourceMapping = std.mem.zeroes(JanetSourceMapping),
    status: JanetCompileStatus = std.mem.zeroes(JanetCompileStatus),
};
pub const JanetModule = ?*const fn ([*c]JanetTable) callconv(.c) void;
pub const JanetModconf = ?*const fn () callconv(.c) JanetBuildConfig;
pub const JanetBindingType = c_uint;
pub const JanetBinding = extern struct {
    type: JanetBindingType = std.mem.zeroes(JanetBindingType),
    value: repr.Value = std.mem.zeroes(repr.Value),
    deprecation: JanetBindingDeprecation = std.mem.zeroes(JanetBindingDeprecation),
};
pub const JanetPegOpcode = c_uint;
pub const JanetPeg = extern struct {
    bytecode: ?[*]u32 = null,
    constants: ?[*]repr.Value = null,
    bytecode_len: usize = 0,
    num_constants: u32 = 0,
    has_backref: c_int = 0,

    /// The two runs, named as `JanetFuncDef`'s are. A compiled PEG is
    /// marshalled and unmarshalled, so the widths here are observable and
    /// stay: `bytecode_len` is a `usize` and `num_constants` a `u32` because
    /// that is what the serialized form carries.
    pub inline fn instructions(self: anytype) View(@TypeOf(self), u32) {
        if (self.bytecode_len == 0) return &.{};
        return self.bytecode.?[0..self.bytecode_len];
    }

    pub inline fn constantValues(self: anytype) View(@TypeOf(self), repr.Value) {
        if (self.num_constants == 0) return &.{};
        return self.constants.?[0..self.num_constants];
    }
};
pub const JanetIntType = c_uint;
pub const JanetTimestamp = i64;
pub const JanetTraversalNode = extern struct {
    self: ?*JanetGCObject = null,
    other: ?*JanetGCObject = null,
    index: i32 = 0,
    index2: i32 = 0,
};
pub const JanetQueue = extern struct {
    capacity: i32 = 0,
    head: i32 = 0,
    tail: i32 = 0,
    data: ?*anyopaque = null,
};
/// `state.h` gives the waiter thread two `HANDLE`s on Windows and one
/// `pthread_t` elsewhere, so this is 56 bytes there and 48 here.
pub const JanetTimeout = if (builtin.os.tag == .windows) extern struct {
    when: JanetTimestamp = 0,
    fiber: ?*JanetFiber = null,
    curr_fiber: ?*JanetFiber = null,
    sched_id: u32 = 0,
    is_error: c_int = 0,
    has_worker: c_int = 0,
    worker: ?*anyopaque = null,
    worker_event: ?*anyopaque = null,
} else extern struct {
    when: JanetTimestamp = 0,
    fiber: ?*JanetFiber = null,
    curr_fiber: ?*JanetFiber = null,
    sched_id: u32 = 0,
    is_error: c_int = 0,
    has_worker: c_int = 0,
    worker: pthread_t = std.mem.zeroes(pthread_t),
};
pub const JanetCFunRegistry = extern struct {
    cfun: JanetCFunction = null,
    name: ?[*:0]const u8 = null,
    name_prefix: ?[*:0]const u8 = null,
    source_file: ?[*:0]const u8 = null,
    source_line: i32 = 0,
};
pub const JanetTraceName = c_uint;
pub const JanetTraceLoc = c_uint;
pub const JanetTraceFrame = struct {
    name: ?[*:0]const u8 = null,
    name_prefix: ?[*:0]const u8 = null,
    source: ?[*:0]const u8 = null,
    pc: i32 = 0,
    line: i32 = 0,
    column: i32 = 0,
    name_kind: u8 = 0,
    loc_kind: u8 = 0,
    tail: u8 = 0,
};
pub const JanetArgExpect = c_uint;
pub const JanetArgFaultKind = c_uint;
pub const JanetArgFault = struct {
    kind: u8 = 0,
    expect: u8 = 0,
    slot: i32 = 0,
    typeflags: repr.TagSet = .{},
    at: ?*const AbstractType = null,
    /// Both are rendered with `%s`, which walks to a NUL by the specifier's
    /// own definition -- so the sentinel here is earned rather than assumed.
    which: [*:0]const u8,
    flags: [*:0]const u8,
    raw: i64 = 0,
    lo: i64 = 0,
    hi: i64 = 0,
    arity: i32 = 0,
    bound: i32 = 0,
};
pub const JanetArgBytes = c_uint;
pub const JanetArgCBytes = c_uint;
pub const JanetcRegisterTemp = c_uint;
pub const JanetcRegisterAllocator = extern struct {
    chunks: ?[*]u32 = null,
    count: i32 = 0,
    capacity: i32 = 0,
    max: i32 = 0,
    regtemps: i32 = 0,
};
pub const JanetCompileLintLevel = c_uint;
pub const JanetSlot = extern struct {
    constant: repr.Value = std.mem.zeroes(repr.Value),
    index: i32 = 0,
    envindex: i32 = 0,
    flags: u32 = 0,
};
pub const JanetEnvRef = extern struct {
    envindex: i32 = 0,
    scope: ?*JanetScope = null,
};
pub const JanetScope = extern struct {
    name: [*]const u8,
    parent: ?*JanetScope = null,
    child: ?*JanetScope = null,
    consts: ?[*]repr.Value = null,
    syms: ?[*]SymPair = null,
    defs: ?[*]*JanetFuncDef = null,
    ra: JanetcRegisterAllocator = std.mem.zeroes(JanetcRegisterAllocator),
    ua: JanetcRegisterAllocator = std.mem.zeroes(JanetcRegisterAllocator),
    envs: ?[*]JanetEnvRef = null,
    bytecode_start: i32 = 0,
    flags: c_int = 0,
};
pub const JanetCompiler = extern struct {
    scope: ?*JanetScope = null,
    buffer: ?[*]u32 = null,
    mapbuffer: ?[*]JanetSourceMapping = null,
    env: ?*JanetTable = null,
    source: ?[*:0]const u8 = null,
    result: JanetCompileResult = std.mem.zeroes(JanetCompileResult),
    current_mapping: JanetSourceMapping = std.mem.zeroes(JanetSourceMapping),
    recursion_guard: c_int = 0,
    lints: ?*JanetArray = null,
    is_redef: c_int = 0,
};
pub const JanetFopts = extern struct {
    compiler: *JanetCompiler,
    hint: JanetSlot = std.mem.zeroes(JanetSlot),
    flags: u32 = 0,
};
pub const JanetFunOptimizer = struct {
    can_optimize: ?*const fn (opts: JanetFopts, args: ?[*]JanetSlot) callconv(.c) c_int = null,
    optimize: ?*const fn (opts: JanetFopts, args: ?[*]JanetSlot) callconv(.c) JanetSlot = null,
};
pub const JanetZigLine = struct {
    bytes: ?[*]u8 = null,
    length: i32 = 0,
};

/// `compile.h`'s shadowing verdict, which `janetc_shadowcheck` returns.
///
/// **A prefix is not a population.** A sweep for `Janet`-prefixed names
/// collected `Consumer` and `SymPair`, both spelled `c.Consumer` and
/// `c.SymPair` at their call sites, and missed this one; enumerating every
/// `c.<name>` the tree spells rather than every `c.Janet*` is what found it.
pub const Shadowing = c_uint;

pub const SymPair = extern struct {
    slot: JanetSlot = std.mem.zeroes(JanetSlot),
    sym: ?[*:0]const u8 = null,
    sym2: ?[*:0]const u8 = null,
    keep: c_int = 0,
    referenced: c_int = 0,
    birth_pc: u32 = 0,
    death_pc: u32 = 0,
};

// ---------------------------------------------------------------------------
// The heads, and where a payload begins
//
// Not translate-c's. This is the one hand-written section of this file, and it
// exists because the four heads above are the only declarations here that
// something has to *do* arithmetic with.
//
// A string, tuple, struct or abstract is one allocation holding a head
// followed by its payload, and the value Janet passes around is the address of
// the payload -- `DESIGN.md` §3. The head is recovered by subtracting the
// payload's offset within that allocation, and the allocator adds the same
// offset to reach the payload it just made room for.
//
// **That offset is `@offsetOf`, and saying so is what this section is for.**
// Twenty-one copies of this arithmetic were scattered across `src/zig` and
// three more across `test/`, every one of them spelling the offset as
// `@sizeOf` of the head: a translated C head drops the flexible array member
// C takes the offset of, so Zig could not spell `@offsetOf` and only a C
// static assertion could check that the two agreed.
//
// These definitions are Zig's own, so `_data` is an ordinary field and
// `@offsetOf` takes its offset exactly. The equality that needed the
// assertion is now the definition. Where `@sizeOf` and `@offsetOf` could
// differ -- a head whose last field leaves padding before an element more
// strictly aligned -- the offset is right and the size is wrong, so this is a
// correction and not only a tidying, even though the two agree on every layout
// Claret builds today.
//
// `test/gc_mark.zig` and `test/utils.zig` still spell `@sizeOf` and are left
// alone deliberately. They compare the offset the allocator *actually used*
// against the other spelling, which is the cross-check a C static assertion
// used to carry -- now in Zig and on every target the matrix builds.
// Converting them would compare the constant with itself.
// ---------------------------------------------------------------------------

pub const string_payload = @offsetOf(JanetStringHead, "_data");
pub const tuple_payload = @offsetOf(JanetTupleHead, "_data");
pub const struct_payload = @offsetOf(JanetStructHead, "_data");
pub const abstract_payload = @offsetOf(JanetAbstractHead, "_data");

/// Recover a string's head from the bytes Janet passes around. Symbols and
/// keywords are strings and use this too.
pub inline fn stringHead(s: [*]const u8) *JanetStringHead {
    return @ptrFromInt(@intFromPtr(s) -% string_payload);
}

/// Recover a tuple's head from its slot array.
pub inline fn tupleHead(t: [*]const repr.Value) *JanetTupleHead {
    return @ptrFromInt(@intFromPtr(t) -% tuple_payload);
}

/// Recover a struct's head from its bucket array.
pub inline fn structHead(st: [*]const JanetKV) *JanetStructHead {
    return @ptrFromInt(@intFromPtr(st) -% struct_payload);
}

/// Recover an abstract's head from its payload. The parameter is
/// `?*const anyopaque` rather than `JanetAbstract` so that a `*const` caller
/// needs no cast; the head itself is mutable, as every caller marks or frees
/// through it.
pub inline fn abstractHead(a: ?*const anyopaque) *JanetAbstractHead {
    return @ptrFromInt(@intFromPtr(a) -% abstract_payload);
}

/// And the four inverses, for a block the allocator has just returned. Each
/// takes a `*const` head and hands back a mutable payload: the allocator's
/// caller has to write through it, and a const head is what a comparison or a
/// hash holds. `janet.h`'s macros make the same trade by being macros.
pub inline fn stringData(hd: *const JanetStringHead) [*]u8 {
    return @ptrFromInt(@intFromPtr(hd) +% string_payload);
}

pub inline fn tupleData(hd: *const JanetTupleHead) [*]repr.Value {
    return @ptrFromInt(@intFromPtr(hd) +% tuple_payload);
}

pub inline fn structData(hd: *const JanetStructHead) [*]JanetKV {
    return @ptrFromInt(@intFromPtr(hd) +% struct_payload);
}

pub inline fn abstractData(hd: *const JanetAbstractHead) ?*anyopaque {
    return @ptrFromInt(@intFromPtr(hd) +% abstract_payload);
}

/// **And the fifth flexible array, which is not a head.** `JanetFunction`
/// carries its captured environments in the same allocation, so
/// `func.envs[i]` is the same arithmetic -- but the value Janet passes around
/// is the address of the *struct*, not of the payload, so nothing subtracts
/// and no negative offset appears anywhere. `DESIGN.md` §3's rule: point at
/// the payload only when the payload has to be raw, and an environment array
/// does not.
///
/// It is grouped here because it shared the four heads' stale justification
/// rather than their shape -- four private copies wrote
/// `@sizeOf(JanetFunction)` for this offset and said `@offsetOf` was
/// unavailable.
pub const function_envs = @offsetOf(JanetFunction, "_envs");

/// `func->envs`, as an array the caller indexes. Both shapes the tree wants
/// come off it: `envsOf(f)[i]` is the environment and `&envsOf(f)[i]` is the
/// slot a marshaller writes through.
pub inline fn envsOf(func: *JanetFunction) [*]?*JanetFuncEnv {
    return @ptrFromInt(@intFromPtr(func) +% function_envs);
}
