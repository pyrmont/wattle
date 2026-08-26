//! Janet's value and runtime types, owned by Zig.
//!
//! Until Phase 12 these came from `@cImport`, translated out of
//! `src/include/janet.h` and the internal core headers. That made the header
//! the place the value representation was *resolved* rather than merely
//! declared -- `value_wrap.zig` recovered the layout by asking whether the
//! translated `Janet` had an `as` or a `tagged` field -- and it meant every
//! `callconv(.c)` signature in the tree was checked against a declaration
//! rather than against its definition.
//!
//! The definitions here were taken from translate-c's own output for four
//! configurations (native nanbox-64, `-Dnanbox=false`, `x86_64-windows-gnu`
//! and `riscv32-linux-musl`) rather than transcribed from the header by hand,
//! so the layouts are the compiler's reading of the C and not a person's.
//! Diffing those four is also what established how little actually varies:
//! of 99 declarations, only `Janet`, `JanetHandle`, `JanetAtomicInt` and
//! `JanetVM` differ at all.
//!
//! **`[*c]` was kept deliberately, and increment 5h spent most of it.** It is
//! translate-c's rendering of `T *`, and replacing it with `[*]`, `?*` or a
//! slice is a per-site judgement about nullability and count that restores
//! checking rather than preserving it. That was a separate pass, and it is
//! batch E: a field that points at one object says `*T` or `?*T`, a field
//! that holds a C string says `[*:0]const u8`, and `DESIGN.md` section 9 has
//! the rules and how each answer was arrived at. The image stayed
//! byte-identical across both, which is what made it the oracle.
//!
//! What is left is two populations and neither is an oversight. A field that
//! points at *many* -- an array, a stretchy vector, `JanetVM.cache` -- is
//! batch F. The `callconv(.c)` callback typedefs are the boundary the exit
//! gate names, beside `capi.zig` and `cabi.zig`: they are the shape a C
//! module author fills in, and `[*c]` is honest there.
//!
//! One section at the foot of the file is not translate-c's: the head
//! accessors and the payload offsets they subtract. They are here rather than
//! in the value layer because `@offsetOf` can only be spelled where the struct
//! is, and putting them anywhere else would make every caller re-derive the
//! offset from `@sizeOf` -- which is what twenty-four copies of them did until
//! increment 5e. See the comment above them.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config");

// ---------------------------------------------------------------------------
// Foreign types
//
// `janet.h` reached these through system headers. Zig's own declarations are
// the same types; `pthread_attr_t` appears in `JanetVM` on every POSIX target
// and `FILE` in `JanetFile`.
// ---------------------------------------------------------------------------

pub const FILE = std.c.FILE;

/// The pthread types, from libc rather than from `janet.h` or from `std.c`.
///
/// **`std.c` is wrong for musl and it would not have shown up here.** It
/// carries glibc's `pthread_attr_t` -- 56 bytes of storage plus a `c_long` of
/// alignment -- where musl's is 56 bytes total on 64-bit and 36 on 32-bit.
/// `JanetVM` embeds one, so taking `std.c`'s would have moved every field
/// after `new_thread_attr` on every Linux target while remaining correct on
/// macOS. `types_check` caught it as `size 56 vs 64` and `36 vs 60`, and only
/// because the cross-compile targets run.
///
/// Reaching libc through `@cImport` is not the thing this phase is removing:
/// Phase 10's decision 4 draws that line explicitly -- "no C in the tree" and
/// "no libc" are different claims, and only the first is a goal. What matters
/// is that the size comes from the platform rather than from a table someone
/// maintains by hand.
///
/// Nothing crosses a translation boundary by value. `ev_loop.zig` declares
/// `pthread_attr_init` and its neighbours itself, taking a pointer, so these
/// types are storage and an address and nothing more.
const libc = if (builtin.os.tag == .windows) struct {
    // No pthreads. `JanetVM`'s Windows arm has no `new_thread_attr` field, so
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
    values: ?[*]Janet,
};

/// `JanetBinding.deprecation`. `janet.h` spells it as an unnamed enum.
pub const JanetBindingDeprecation = c_uint;

// ---------------------------------------------------------------------------
// The value representation
//
// Three layouts, selected by `-Dnanbox` and the target width. `DESIGN.md` §7
// keeps `tagged` as the tree's last differential and drops `nanbox_32`; the
// deletion is its own increment, so all three are carried here.
// ---------------------------------------------------------------------------

/// `Janet`'s payload under the 32-bit NaN box.
pub const JanetNanbox32Payload = extern union {
    integer: i32,
    pointer: ?*anyopaque,
};

/// The tagged half of the 32-bit NaN box.
pub const JanetNanbox32Tagged = extern struct {
    payload: JanetNanbox32Payload = std.mem.zeroes(JanetNanbox32Payload),
    type: u32 = 0,
};

/// `Janet`'s payload under the tagged layout.
pub const JanetTaggedPayload = extern union {
    u64: u64,
    number: f64,
    integer: i32,
    pointer: ?*anyopaque,
    cpointer: ?*const anyopaque,
};

pub const Janet = switch (config.value_repr) {
    .nanbox_64 => extern union {
        u64: u64,
        i64: i64,
        number: f64,
        pointer: ?*anyopaque,
    },
    .nanbox_32 => extern union {
        tagged: JanetNanbox32Tagged,
        number: f64,
        u64: u64,
    },
    .tagged => extern struct {
        as: JanetTaggedPayload = std.mem.zeroes(JanetTaggedPayload),
        type: JanetType = std.mem.zeroes(JanetType),
    },
};

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
// `state.h` guards two regions: `strerror_buf` is absent on Windows, and the
// event-loop block has four mutually exclusive backend arms that vanish
// without `JANET_EV`. Six combinations, and every one is written out in full.
//
// **The duplication is deliberate and the alternatives were tried.** Zig 0.16
// removed type reification, so a field list cannot be assembled at comptime.
// Nesting each guarded region in its own `extern struct` compiles, reads far
// better, and is *wrong*: an inner struct pads to its own alignment, so
// `JanetVMEvBackend` ending in `timer_enabled: c_int` rounds up to 16 where
// flat C packs `timer_enabled` and `c_raised` into one eight-byte slot.
// `types_check` caught it as 848 against 840. While the `@cImport` spelling
// and this one coexist, a size disagreement on `janet_vm` is memory
// corruption, not a cosmetic difference -- so the layout is `state.h`'s to
// the byte until the header goes, and the check is what says so.
// ---------------------------------------------------------------------------

pub const JanetVM = if (builtin.os.tag == .windows)
    (if (config.ev)
        extern struct {
            user: ?*anyopaque = null,
            top_dyns: ?*JanetTable = null,
            core_env: ?*JanetTable = null,
            stackn: c_int = 0,
            auto_suspend: JanetAtomicInt = 0,
            fiber: ?*JanetFiber = null,
            root_fiber: ?*JanetFiber = null,
            return_reg: ?*Janet = null,
            coerce_error: c_int = 0,
            pending_signal: JanetSignal = std.mem.zeroes(JanetSignal),
            registry: ?[*]JanetCFunRegistry = null,
            registry_cap: usize = 0,
            registry_count: usize = 0,
            registry_dirty: c_int = 0,
            abstract_registry: ?*JanetTable = null,
            cache: ?[*]?[*:0]const u8 = null,
            cache_capacity: u32 = 0,
            cache_count: u32 = 0,
            cache_deleted: u32 = 0,
            gensym_counter: [8]u8 = std.mem.zeroes([8]u8),
            blocks: ?*anyopaque = null,
            weak_blocks: ?*anyopaque = null,
            gc_interval: usize = 0,
            next_collection: usize = 0,
            block_count: usize = 0,
            gc_suspend: c_int = 0,
            gc_mark_phase: c_int = 0,
            roots: ?[*]Janet = null,
            root_count: usize = 0,
            root_capacity: usize = 0,
            scratch_mem: ?[*]*JanetScratch = null,
            scratch_cap: usize = 0,
            scratch_len: usize = 0,
            sandbox_flags: u32 = 0,
            rng: JanetRNG = std.mem.zeroes(JanetRNG),
            traversal: ?[*]JanetTraversalNode = null,
            traversal_top: ?[*]JanetTraversalNode = null,
            traversal_base: ?[*]JanetTraversalNode = null,
            tq_count: usize = 0,
            tq_capacity: usize = 0,
            spawn: JanetQueue = std.mem.zeroes(JanetQueue),
            tq: ?[*]JanetTimeout = null,
            ev_rng: JanetRNG = std.mem.zeroes(JanetRNG),
            listener_count: JanetAtomicInt = 0,
            threaded_abstracts: JanetTable = std.mem.zeroes(JanetTable),
            active_tasks: JanetTable = std.mem.zeroes(JanetTable),
            signal_handlers: JanetTable = std.mem.zeroes(JanetTable),
            iocp: ?[*]?*anyopaque = null,
            connect_ex: ?*anyopaque = null,
            connect_ex_loaded: c_int = 0,
            c_raised: i32 = 0,
        }
    else
        extern struct {
            user: ?*anyopaque = null,
            top_dyns: ?*JanetTable = null,
            core_env: ?*JanetTable = null,
            stackn: c_int = 0,
            auto_suspend: JanetAtomicInt = 0,
            fiber: ?*JanetFiber = null,
            root_fiber: ?*JanetFiber = null,
            return_reg: ?*Janet = null,
            coerce_error: c_int = 0,
            pending_signal: JanetSignal = std.mem.zeroes(JanetSignal),
            registry: ?[*]JanetCFunRegistry = null,
            registry_cap: usize = 0,
            registry_count: usize = 0,
            registry_dirty: c_int = 0,
            abstract_registry: ?*JanetTable = null,
            cache: ?[*]?[*:0]const u8 = null,
            cache_capacity: u32 = 0,
            cache_count: u32 = 0,
            cache_deleted: u32 = 0,
            gensym_counter: [8]u8 = std.mem.zeroes([8]u8),
            blocks: ?*anyopaque = null,
            weak_blocks: ?*anyopaque = null,
            gc_interval: usize = 0,
            next_collection: usize = 0,
            block_count: usize = 0,
            gc_suspend: c_int = 0,
            gc_mark_phase: c_int = 0,
            roots: ?[*]Janet = null,
            root_count: usize = 0,
            root_capacity: usize = 0,
            scratch_mem: ?[*]*JanetScratch = null,
            scratch_cap: usize = 0,
            scratch_len: usize = 0,
            sandbox_flags: u32 = 0,
            rng: JanetRNG = std.mem.zeroes(JanetRNG),
            traversal: ?[*]JanetTraversalNode = null,
            traversal_top: ?[*]JanetTraversalNode = null,
            traversal_base: ?[*]JanetTraversalNode = null,
            c_raised: i32 = 0,
        })
else if (!config.ev)
    extern struct {
        user: ?*anyopaque = null,
        top_dyns: ?*JanetTable = null,
        core_env: ?*JanetTable = null,
        stackn: c_int = 0,
        auto_suspend: JanetAtomicInt = 0,
        fiber: ?*JanetFiber = null,
        root_fiber: ?*JanetFiber = null,
        return_reg: ?*Janet = null,
        coerce_error: c_int = 0,
        pending_signal: JanetSignal = std.mem.zeroes(JanetSignal),
        registry: ?[*]JanetCFunRegistry = null,
        registry_cap: usize = 0,
        registry_count: usize = 0,
        registry_dirty: c_int = 0,
        abstract_registry: ?*JanetTable = null,
        cache: ?[*]?[*:0]const u8 = null,
        cache_capacity: u32 = 0,
        cache_count: u32 = 0,
        cache_deleted: u32 = 0,
        gensym_counter: [8]u8 = std.mem.zeroes([8]u8),
        blocks: ?*anyopaque = null,
        weak_blocks: ?*anyopaque = null,
        gc_interval: usize = 0,
        next_collection: usize = 0,
        block_count: usize = 0,
        gc_suspend: c_int = 0,
        gc_mark_phase: c_int = 0,
        roots: ?[*]Janet = null,
        root_count: usize = 0,
        root_capacity: usize = 0,
        scratch_mem: ?[*]*JanetScratch = null,
        scratch_cap: usize = 0,
        scratch_len: usize = 0,
        sandbox_flags: u32 = 0,
        rng: JanetRNG = std.mem.zeroes(JanetRNG),
        traversal: ?[*]JanetTraversalNode = null,
        traversal_top: ?[*]JanetTraversalNode = null,
        traversal_base: ?[*]JanetTraversalNode = null,
        strerror_buf: [256]u8 = std.mem.zeroes([256]u8),
        c_raised: i32 = 0,
    }
else if (config.ev_epoll)
    extern struct {
        user: ?*anyopaque = null,
        top_dyns: ?*JanetTable = null,
        core_env: ?*JanetTable = null,
        stackn: c_int = 0,
        auto_suspend: JanetAtomicInt = 0,
        fiber: ?*JanetFiber = null,
        root_fiber: ?*JanetFiber = null,
        return_reg: ?*Janet = null,
        coerce_error: c_int = 0,
        pending_signal: JanetSignal = std.mem.zeroes(JanetSignal),
        registry: ?[*]JanetCFunRegistry = null,
        registry_cap: usize = 0,
        registry_count: usize = 0,
        registry_dirty: c_int = 0,
        abstract_registry: ?*JanetTable = null,
        cache: ?[*]?[*:0]const u8 = null,
        cache_capacity: u32 = 0,
        cache_count: u32 = 0,
        cache_deleted: u32 = 0,
        gensym_counter: [8]u8 = std.mem.zeroes([8]u8),
        blocks: ?*anyopaque = null,
        weak_blocks: ?*anyopaque = null,
        gc_interval: usize = 0,
        next_collection: usize = 0,
        block_count: usize = 0,
        gc_suspend: c_int = 0,
        gc_mark_phase: c_int = 0,
        roots: ?[*]Janet = null,
        root_count: usize = 0,
        root_capacity: usize = 0,
        scratch_mem: ?[*]*JanetScratch = null,
        scratch_cap: usize = 0,
        scratch_len: usize = 0,
        sandbox_flags: u32 = 0,
        rng: JanetRNG = std.mem.zeroes(JanetRNG),
        traversal: ?[*]JanetTraversalNode = null,
        traversal_top: ?[*]JanetTraversalNode = null,
        traversal_base: ?[*]JanetTraversalNode = null,
        strerror_buf: [256]u8 = std.mem.zeroes([256]u8),
        tq_count: usize = 0,
        tq_capacity: usize = 0,
        spawn: JanetQueue = std.mem.zeroes(JanetQueue),
        tq: ?[*]JanetTimeout = null,
        ev_rng: JanetRNG = std.mem.zeroes(JanetRNG),
        listener_count: JanetAtomicInt = 0,
        threaded_abstracts: JanetTable = std.mem.zeroes(JanetTable),
        active_tasks: JanetTable = std.mem.zeroes(JanetTable),
        signal_handlers: JanetTable = std.mem.zeroes(JanetTable),
        new_thread_attr: pthread_attr_t = std.mem.zeroes(pthread_attr_t),
        selfpipe: [2]JanetHandle = std.mem.zeroes([2]JanetHandle),
        epoll: c_int = 0,
        timerfd: c_int = 0,
        timer_enabled: c_int = 0,
        c_raised: i32 = 0,
    }
else if (config.ev_kqueue)
    extern struct {
        user: ?*anyopaque = null,
        top_dyns: ?*JanetTable = null,
        core_env: ?*JanetTable = null,
        stackn: c_int = 0,
        auto_suspend: JanetAtomicInt = 0,
        fiber: ?*JanetFiber = null,
        root_fiber: ?*JanetFiber = null,
        return_reg: ?*Janet = null,
        coerce_error: c_int = 0,
        pending_signal: JanetSignal = std.mem.zeroes(JanetSignal),
        registry: ?[*]JanetCFunRegistry = null,
        registry_cap: usize = 0,
        registry_count: usize = 0,
        registry_dirty: c_int = 0,
        abstract_registry: ?*JanetTable = null,
        cache: ?[*]?[*:0]const u8 = null,
        cache_capacity: u32 = 0,
        cache_count: u32 = 0,
        cache_deleted: u32 = 0,
        gensym_counter: [8]u8 = std.mem.zeroes([8]u8),
        blocks: ?*anyopaque = null,
        weak_blocks: ?*anyopaque = null,
        gc_interval: usize = 0,
        next_collection: usize = 0,
        block_count: usize = 0,
        gc_suspend: c_int = 0,
        gc_mark_phase: c_int = 0,
        roots: ?[*]Janet = null,
        root_count: usize = 0,
        root_capacity: usize = 0,
        scratch_mem: ?[*]*JanetScratch = null,
        scratch_cap: usize = 0,
        scratch_len: usize = 0,
        sandbox_flags: u32 = 0,
        rng: JanetRNG = std.mem.zeroes(JanetRNG),
        traversal: ?[*]JanetTraversalNode = null,
        traversal_top: ?[*]JanetTraversalNode = null,
        traversal_base: ?[*]JanetTraversalNode = null,
        strerror_buf: [256]u8 = std.mem.zeroes([256]u8),
        tq_count: usize = 0,
        tq_capacity: usize = 0,
        spawn: JanetQueue = std.mem.zeroes(JanetQueue),
        tq: ?[*]JanetTimeout = null,
        ev_rng: JanetRNG = std.mem.zeroes(JanetRNG),
        listener_count: JanetAtomicInt = 0,
        threaded_abstracts: JanetTable = std.mem.zeroes(JanetTable),
        active_tasks: JanetTable = std.mem.zeroes(JanetTable),
        signal_handlers: JanetTable = std.mem.zeroes(JanetTable),
        new_thread_attr: pthread_attr_t = std.mem.zeroes(pthread_attr_t),
        selfpipe: [2]JanetHandle = std.mem.zeroes([2]JanetHandle),
        kq: c_int = 0,
        timer: c_int = 0,
        timer_enabled: c_int = 0,
        c_raised: i32 = 0,
    }
else
    extern struct {
        user: ?*anyopaque = null,
        top_dyns: ?*JanetTable = null,
        core_env: ?*JanetTable = null,
        stackn: c_int = 0,
        auto_suspend: JanetAtomicInt = 0,
        fiber: ?*JanetFiber = null,
        root_fiber: ?*JanetFiber = null,
        return_reg: ?*Janet = null,
        coerce_error: c_int = 0,
        pending_signal: JanetSignal = std.mem.zeroes(JanetSignal),
        registry: ?[*]JanetCFunRegistry = null,
        registry_cap: usize = 0,
        registry_count: usize = 0,
        registry_dirty: c_int = 0,
        abstract_registry: ?*JanetTable = null,
        cache: ?[*]?[*:0]const u8 = null,
        cache_capacity: u32 = 0,
        cache_count: u32 = 0,
        cache_deleted: u32 = 0,
        gensym_counter: [8]u8 = std.mem.zeroes([8]u8),
        blocks: ?*anyopaque = null,
        weak_blocks: ?*anyopaque = null,
        gc_interval: usize = 0,
        next_collection: usize = 0,
        block_count: usize = 0,
        gc_suspend: c_int = 0,
        gc_mark_phase: c_int = 0,
        roots: ?[*]Janet = null,
        root_count: usize = 0,
        root_capacity: usize = 0,
        scratch_mem: ?[*]*JanetScratch = null,
        scratch_cap: usize = 0,
        scratch_len: usize = 0,
        sandbox_flags: u32 = 0,
        rng: JanetRNG = std.mem.zeroes(JanetRNG),
        traversal: ?[*]JanetTraversalNode = null,
        traversal_top: ?[*]JanetTraversalNode = null,
        traversal_base: ?[*]JanetTraversalNode = null,
        strerror_buf: [256]u8 = std.mem.zeroes([256]u8),
        tq_count: usize = 0,
        tq_capacity: usize = 0,
        spawn: JanetQueue = std.mem.zeroes(JanetQueue),
        tq: ?[*]JanetTimeout = null,
        ev_rng: JanetRNG = std.mem.zeroes(JanetRNG),
        listener_count: JanetAtomicInt = 0,
        threaded_abstracts: JanetTable = std.mem.zeroes(JanetTable),
        active_tasks: JanetTable = std.mem.zeroes(JanetTable),
        signal_handlers: JanetTable = std.mem.zeroes(JanetTable),
        streams: ?[*]*JanetStream = null,
        stream_count: usize = 0,
        stream_capacity: usize = 0,
        new_thread_attr: pthread_attr_t = std.mem.zeroes(pthread_attr_t),
        selfpipe: [2]JanetHandle = std.mem.zeroes([2]JanetHandle),
        fds: ?[*]std.c.pollfd = null,
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
pub const JanetSignal = c_uint;
pub const JanetFiberStatus = c_uint;
pub const JanetGCObject = extern struct {
    flags: i32 = 0,
    data: JanetGCData = std.mem.zeroes(JanetGCData),
};
pub const JanetKV = extern struct {
    key: Janet = std.mem.zeroes(Janet),
    value: Janet = std.mem.zeroes(Janet),
};
pub const JanetTable = extern struct {
    gc: JanetGCObject = std.mem.zeroes(JanetGCObject),
    count: i32 = 0,
    capacity: i32 = 0,
    deleted: i32 = 0,
    data: ?[*]JanetKV = null,
    proto: ?*JanetTable = null,
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
    data: ?[*]Janet = null,
    child: ?*JanetFiber = null,
    last_value: Janet = std.mem.zeroes(Janet),
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
    data: ?[*]Janet = null,
    child: ?*JanetFiber = null,
    last_value: Janet = std.mem.zeroes(Janet),
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
    constants: ?[*]Janet = null,
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
    data: ?[*]Janet = null,
};
pub const JanetBuffer = extern struct {
    gc: JanetGCObject = std.mem.zeroes(JanetGCObject),
    count: i32 = 0,
    capacity: i32 = 0,
    data: ?[*]u8 = null,
};
pub const JanetTupleHead = extern struct {
    gc: JanetGCObject = std.mem.zeroes(JanetGCObject),
    length: i32 = 0,
    hash: i32 = 0,
    sm_line: i32 = 0,
    sm_column: i32 = 0,
    _data: [0]Janet = std.mem.zeroes([0]Janet),
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
    at: ?*const JanetAbstractType = null,
};
pub const JanetByteView = extern struct {
    bytes: ?[*]const u8,
    len: i32 = 0,
};
pub const JanetAbstractType = extern struct {
    name: [*:0]const u8,
    gc: ?*const fn (data: ?*anyopaque, len: usize) callconv(.c) c_int = null,
    gcmark: ?*const fn (data: ?*anyopaque, len: usize) callconv(.c) c_int = null,
    get: ?*const fn (data: ?*anyopaque, key: Janet, out: [*c]Janet) callconv(.c) c_int = null,
    put: ?*const fn (data: ?*anyopaque, key: Janet, value: Janet) callconv(.c) void = null,
    marshal: ?*const fn (p: ?*anyopaque, ctx: [*c]JanetMarshalContext) callconv(.c) void = null,
    unmarshal: ?*const fn (ctx: [*c]JanetMarshalContext) callconv(.c) ?*anyopaque = null,
    tostring: ?*const fn (p: ?*anyopaque, buffer: [*c]JanetBuffer) callconv(.c) void = null,
    compare: ?*const fn (lhs: ?*anyopaque, rhs: ?*anyopaque) callconv(.c) c_int = null,
    hash: ?*const fn (p: ?*anyopaque, len: usize) callconv(.c) i32 = null,
    next: ?*const fn (p: ?*anyopaque, key: Janet) callconv(.c) Janet = null,
    call: ?*const fn (p: ?*anyopaque, argc: i32, argv: [*c]Janet) callconv(.c) Janet = null,
    length: ?*const fn (p: ?*anyopaque, len: usize) callconv(.c) usize = null,
    bytes: ?*const fn (p: ?*anyopaque, len: usize) callconv(.c) JanetByteView = null,
    gcperthread: ?*const fn (data: ?*anyopaque, len: usize) callconv(.c) c_int = null,
};
pub const JanetAbstractHead = extern struct {
    gc: JanetGCObject = std.mem.zeroes(JanetGCObject),
    type: *const JanetAbstractType,
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
pub const JanetCFunction = ?*const fn (argc: i32, argv: [*c]Janet) callconv(.c) Janet;
pub const JanetReg = extern struct {
    name: ?[*:0]const u8 = null,
    cfun: JanetCFunction = null,
    documentation: ?[*:0]const u8 = null,
};
pub const JanetRegExt = extern struct {
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
    items: ?[*]const Janet = null,
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
pub const JanetType = c_uint;
pub const JanetSymbol = [*:0]const u8;
pub const JanetKeyword = [*:0]const u8;
pub const JanetTuple = [*]const Janet;
pub const JanetStruct = [*]const JanetKV;
pub const JanetAbstract = ?*anyopaque;
pub const JanetAsyncEvent = c_uint;
pub const JanetAsyncMode = c_uint;
pub const JanetParser = extern struct {
    args: ?[*]Janet = null,
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
    vm_return_reg: ?*Janet = null,
    payload: Janet = std.mem.zeroes(Janet),
    coerce_error: c_int = 0,
};
pub const JanetOpArgType = c_uint;
pub const JanetInstructionType = c_uint;
pub const JanetOpCode = c_uint;
pub const JanetEVGenericMessage = extern struct {
    tag: c_int = 0,
    argi: c_int = 0,
    argp: ?*anyopaque = null,
    argj: Janet = std.mem.zeroes(Janet),
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
    value: Janet = std.mem.zeroes(Janet),
    deprecation: JanetBindingDeprecation = std.mem.zeroes(JanetBindingDeprecation),
};
pub const JanetPegOpcode = c_uint;
pub const JanetPeg = extern struct {
    bytecode: ?[*]u32 = null,
    constants: ?[*]Janet = null,
    bytecode_len: usize = 0,
    num_constants: u32 = 0,
    has_backref: c_int = 0,
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
pub const JanetSignalPlan = c_uint;
pub const JanetTraceName = c_uint;
pub const JanetTraceLoc = c_uint;
pub const JanetTraceFrame = extern struct {
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
pub const JanetArgFault = extern struct {
    kind: u8 = 0,
    expect: u8 = 0,
    slot: i32 = 0,
    typeflags: i32 = 0,
    at: ?*const JanetAbstractType = null,
    which: [*]const u8,
    flags: [*]const u8,
    raw: i64 = 0,
    lo: i64 = 0,
    hi: i64 = 0,
    arity: i32 = 0,
    bound: i32 = 0,
};
pub const JanetArgBytes = c_uint;
pub const JanetArgCBytes = c_uint;
pub const JanetMemoryType = c_uint;
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
    constant: Janet = std.mem.zeroes(Janet),
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
    consts: ?[*]Janet = null,
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
pub const JanetFunOptimizer = extern struct {
    can_optimize: ?*const fn (opts: JanetFopts, args: ?[*]JanetSlot) callconv(.c) c_int = null,
    optimize: ?*const fn (opts: JanetFopts, args: ?[*]JanetSlot) callconv(.c) JanetSlot = null,
};
pub const JanetSpecial = extern struct {
    name: [*]const u8,
    compile: ?*const fn (opts: JanetFopts, argn: i32, argv: [*]const Janet) callconv(.c) JanetSlot = null,
};
pub const JanetZigLine = extern struct {
    bytes: ?[*]u8 = null,
    length: i32 = 0,
};

/// `compile.h`'s shadowing verdict, which `janetc_shadowcheck` returns.
///
/// **Missed by increment 3**, which swept the translation for `Janet`-prefixed
/// names and so collected `Consumer` and `SymPair` -- both spelled at their
/// call sites as `c.Consumer` and `c.SymPair` -- but not this one. The gap was
/// found by increment 4 enumerating every `c.<name>` the tree spells rather
/// than every `c.Janet*`. `phase_12.md`'s rule 17: a population named by a
/// prefix is a population measured over the prefix.
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
// three more across `test/`, every one of them spelling the offset `@sizeOf`
// of the head and every one carrying a comment explaining why: translate-c
// drops the flexible array member C takes the offset of, so Zig could not
// spell `@offsetOf`, and `test/abi.c` asserted from C -- the only place that
// could still ask -- that the two agree.
//
// That was true of `@cImport`'s heads. It stopped being true at increment 5b,
// when these definitions became Zig's own: `_data` is an ordinary field here
// and `@offsetOf` takes its offset exactly. The equality that needed a C
// static assertion is now the definition. Where `@sizeOf` and `@offsetOf`
// could differ -- a head whose last field leaves padding before an element
// more strictly aligned -- the offset is right and the size is wrong, so this
// is a correction and not only a tidying, even though the two agree on every
// layout Claret builds today.
//
// `test/gc_mark.zig` and `test/utils.zig` still spell `@sizeOf` and are left
// alone deliberately. They compare the offset the allocator *actually used*
// against the other spelling, which is the cross-check `test/abi.c` was
// carrying, now in Zig and on every target the matrix builds. Converting them
// would compare the constant with itself.
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
pub inline fn tupleHead(t: [*]const Janet) *JanetTupleHead {
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

pub inline fn tupleData(hd: *const JanetTupleHead) [*]Janet {
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
/// unavailable. `test/abi.c` groups it with them too, as the fifth of its five
/// assertions.
pub const function_envs = @offsetOf(JanetFunction, "_envs");

/// `func->envs`, as an array the caller indexes. Both shapes the tree wants
/// come off it: `envsOf(f)[i]` is the environment and `&envsOf(f)[i]` is the
/// slot a marshaller writes through.
pub inline fn envsOf(func: *JanetFunction) [*]?*JanetFuncEnv {
    return @ptrFromInt(@intFromPtr(func) +% function_envs);
}
