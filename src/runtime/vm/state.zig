//! The VM type, the storage that has one, and the accessor that names it.
//!
//! `current()` is the calling thread's `Vm`, and `Vm` is every subsystem's
//! view of the interpreter: the running fiber, the collector, the registry,
//! the symbol cache, the dynamic bindings. `isInitialised` and
//! `requireJanetThread` are the two liveness questions asked of it, `dyn` and
//! `setdyn` read and write a dynamic binding, and `vmAlloc`, `vmSave`,
//! `vmLoad` and `vmFree` move a whole VM in and out of detached storage.
//!
//! This is not `vm/lifecycle.zig` because the two are asked for by different
//! files. `Vm`, the storage and `current()` are what every subsystem needs.
//! Bringing the VM up and tearing it down is a separate concern, asked for by
//! fewer, and it lives next door.
//!
//! ## The VM layout
//!
//! Nothing compares this layout against anything. No host `@cImport` names it,
//! and the only reads of its representation are `@sizeOf` in `vmAlloc` and the
//! `std.mem.zeroes` and `isFresh` pair in `test/vm_state.zig`, neither of
//! which depends on where the compiler puts the padding: `isFresh` compares
//! field by field for exactly that reason.
//!
//! That is what lets the two guarded regions nest as ordinary fields:
//! `strerror_buf`, absent on Windows, and `VmEv` with its four mutually
//! exclusive backend arms. Nesting a guarded region pads the inner struct to
//! its own alignment and moves every field after it, and nothing here minds.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");
const builtin = @import("builtin");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const abstracts = @import("../value/abstracts.zig");
const config = @import("config");
const constants = @import("constants");
const ev_backend = @import("../ev/backend.zig");
const ev_loop = @import("../ev.zig");
const fatal = @import("../fatal.zig");
const fibers = @import("../value/fibers.zig");
const functions = @import("../value/functions.zig");
const gc_alloc = @import("../gc.zig");
const math = @import("../math.zig");
const order = @import("../value/helpers/order.zig");
const registry = @import("../registry.zig");
const repr = @import("repr");
const symbols = @import("../value/symbols.zig");
const tables = @import("../value/tables.zig");
const utils = @import("../utils.zig");
const value = @import("../value.zig");
const vm_lifecycle = @import("lifecycle.zig");
const wrap = @import("../value/helpers/wrap.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// False only in a `-Dsingle-threaded` build, which uses one process-wide VM.
const is_thread_local = constants.JANET_VM_THREAD_LOCAL != 0;

/// `strerror_r`'s scratch. Windows has no such field, and a zero-length array
/// is how a configuration drops one out of a struct without a second
/// declaration of everything around it.
const strerror_buf_len = if (builtin.os.tag == .windows) 0 else 256;

// ==========================================================================
// Types
// ==========================================================================

/// A stack frame's two live bits, and the one the marshaller borrows.
///
/// The word is written to and read from a marshalled fiber as a signed 32-bit
/// integer, so the width and the bit positions are the format. `marsh.zig`
/// asserts them beside the write.
pub const FrameFlags = packed struct(u32) {
    tailcall: bool = false,
    entrance: bool = false,
    _rest: u29 = 0,
    /// Set by the marshaller just before it writes the frame, to say that an
    /// environment follows. It is the sign bit, it is never set in a live
    /// frame, and the unmarshaller clears it again.
    has_env: bool = false,
};

/// One call frame: the function, the program counter, the captured
/// environment, the index of the frame below, and the two flags.
///
/// A frame lives in the `Value` slots immediately below its own stack base;
/// `value/fibers.zig`'s `stackFrame` is what finds it.
pub const StackFrame = struct {
    func: ?*functions.Function = null,
    pc: ?[*]u32 = null,
    env: ?*functions.FuncEnv = null,
    prevframe: i32 = 0,
    flags: FrameFlags = .{},
};

/// What `vm/entry.zig` saves before a protected call and restores after one.
pub const TryState = struct {
    stackn: u32 = 0,
    gc_handle: u32 = 0,
    vm_fiber: ?*fibers.Fiber = null,
    vm_return_reg: ?*repr.Value = null,
    payload: repr.Value = std.mem.zeroes(repr.Value),
    coerce_error: bool = false,
};

/// One interpreter's state. `current()` returns the calling thread's, and
/// `vm/lifecycle.zig` brings one up and tears it down.
pub const Vm = struct {
    user: ?*anyopaque = null,
    top_dyns: ?*tables.Table = null,
    core_env: ?*tables.Table = null,
    stackn: u32 = 0,
    auto_suspend: abi.AtomicInt = 0,
    fiber: ?*fibers.Fiber = null,
    root_fiber: ?*fibers.Fiber = null,
    return_reg: ?*repr.Value = null,
    coerce_error: bool = false,
    pending_signal: abi.Signal = .ok,
    registry: registry.Registry = .{},
    abstract_registry: ?*tables.Table = null,
    symcache: symbols.SymbolCache = .{},
    gensym_counter: symbols.GensymCounter = std.mem.zeroes(symbols.GensymCounter),
    gc: gc_alloc.Collector = .{},
    roots: gc_alloc.Roots = .empty,
    scratch: gc_alloc.ScratchTable = .empty,
    sandbox_flags: vm_lifecycle.Sandbox = .{},
    rng: math.Rng = .{},
    traversal: order.Traversal = .{},
    strerror_buf: [strerror_buf_len]u8 = std.mem.zeroes([strerror_buf_len]u8),
    ev: VmEv = .{},
    c_raised: bool = false,
};

/// The event loop's own state, empty in a build without one.
///
/// An empty `struct` is size 0 and alignment 1, so `-Dev=false` costs the VM
/// nothing and needs no second declaration of everything above it.
pub const VmEv = if (config.ev)
    struct {
        spawn: ev_loop.Queue(ev_loop.Task) = .{},
        /// The timer queue, a min heap ordered by `when`.
        tq: std.ArrayListUnmanaged(ev_loop.Timeout) = .empty,
        ev_rng: math.Rng = .{},
        listener_count: abi.AtomicInt = 0,
        threaded_abstracts: tables.Table = .{},
        active_tasks: tables.Table = .{},
        signal_handlers: tables.Table = .{},
        backend: ev_backend.VmBackend = .{},
    }
else
    struct {};

/// The VM itself.
///
/// The storage class is chosen at compile time, so the variable lives in a
/// container picked by an `if`: `export` cannot be applied conditionally to a
/// declaration, and the address of a thread-local is not comptime-known, so
/// `@export` is not available either.
///
/// It is not exported. Zig 0.16 refuses to export a variable of an
/// automatic-layout type at all, and `Vm` has automatic layout. Nor would a
/// symbol be safe to add: `build.zig` gives `cli.zig` and `boot.zig` `types`,
/// `constants` and `cabi` alone and links the runtime as an object, so
/// `cabi.zig` is compiled a second time inside each of those executables, and
/// a declaration there that read the VM through a symbol would give the client
/// a second VM, initialised by nobody, with nothing to say so.
const storage = if (is_thread_local) struct {
    pub threadlocal var vm: Vm = std.mem.zeroes(Vm);
} else struct {
    pub var vm: Vm = std.mem.zeroes(Vm);
};

// ==========================================================================
// Public functions
// ==========================================================================

/// The VM this thread is running, and the one accessor the runtime has.
///
/// Inside the runtime this is the address of the variable, taken directly.
pub inline fn current() *Vm {
    return &storage.vm;
}

/// The fiber this thread is running, for the callers that have already
/// established there is one.
///
/// The invariant is at or below the interpreter loop. `continueNoCheck`
/// assigns `fiber` before it enters the loop and `signal.restore` puts back
/// whatever was there before, so a cfunction body, an opcode handler, or
/// `vm/entry.zig`'s `call` after its own entry check cannot observe a null
/// here. A caller that can also be reached from outside the loop reads
/// `current().fiber` and handles the null instead.
pub inline fn currentFiber() *fibers.Fiber {
    return current().fiber orelse unreachable;
}

/// The dynamic binding `name` names, or nil.
///
/// The storage is the running fiber's `env` where there is a running fiber,
/// and the VM's `top_dyns` where there is not. Both tables are created lazily
/// by `setdyn`: neither exists until something is bound, so a read before any
/// write is nil rather than a lookup in an empty table.
pub fn dyn(name: [*:0]const u8) repr.Value {
    const v = current();
    if (v.fiber) |fiber| {
        if (fiber.env) |env| return tables.getKeyword(env, name);
        return wrap.fromNil();
    }
    const dyns = v.top_dyns orelse return wrap.fromNil();
    return tables.get(dyns, value.fromBytes(std.mem.span(name), .keyword));
}

/// Asks the interpreter to leave its loop at the next call or backwards jump.
///
/// `vm` is the VM to interrupt, or null for the calling thread's own, which is
/// the form a signal handler uses. The counter is atomic because the caller is
/// usually another thread, and the ordering is `abstracts.atomicInc`'s rather
/// than being chosen here.
pub fn interpreterInterrupt(vm: ?*Vm) void {
    const target = vm orelse current();
    _ = abstracts.atomicInc(&target.auto_suspend);
}

/// Withdraws one `interpreterInterrupt`. `vm` is the VM, or null for the
/// calling thread's own.
pub fn interpreterInterruptHandled(vm: ?*Vm) void {
    const target = vm orelse current();
    _ = abstracts.atomicDec(&target.auto_suspend);
}

/// Whether this thread's VM has been brought up.
///
/// The symbol cache is the probe, read as a liveness question rather than as
/// cache work. `vm/lifecycle.zig`'s `init` calls `symbols.cacheInit` second,
/// before anything a program can reach has interned or allocated, and
/// `symbols.cacheDeinit` puts `entries` back to null on the way out. So a null
/// `entries` means this thread is not between those two calls.
///
/// It reads a `threadlocal var` and dereferences nothing. `storage.vm` is
/// thread-local in every build but `-Dsingle-threaded`, so a thread that never
/// ran `lifecycle.init` sees the zeroed one and this is false; on a thread that
/// did, it is one load and a compare.
///
/// Two callers ask it, for two different failures, and each states its own
/// message. `gc.gcallocBytes` asks whether an embedder forgot to bring the VM
/// up at all. `capi.zig`'s entry points and `args.zig`'s `*Abi` shims ask
/// whether the calling thread is one that runs Janet.
pub inline fn isInitialised() bool {
    return current().symcache.entries != null;
}

/// `current()`, under the name `test/vm_state.zig` calls it by to say that the
/// object is this thread's.
pub fn localVm() *Vm {
    return current();
}

/// The VM pointer, captured once for a hot path, opaque to the optimiser.
///
/// On Darwin every access to a thread-local is a call to libdyld's
/// `_tlv_get_addr`, and LLVM re-derives the address at every use rather than
/// keeping it. Each is an indirect call that clobbers the caller-saved
/// registers, so the cost is the spills around it as much as the call.
///
/// Neither a struct field nor a `noinline` parameter stops that. A field of a
/// constant expression is the constant expression, and interprocedural
/// constant propagation replaces a parameter every caller passes the same
/// constant. An empty `asm` with `"=r"` and `"0"` constraints emits no
/// instructions and makes the value opaque, and it is the only construct
/// measured to work. `std.mem.doNotOptimizeAway` is built on the same one.
///
/// It is gated, because keeping the address is not always right. On an ELF
/// executable local-exec TLS is two instructions and rematerialising costs
/// nothing, so a kept pointer would occupy a register for no gain. In a shared
/// object it is general-dynamic, one `__tls_get_addr` per access, and this
/// should help again.
///
/// To check whether this is still earning its place, count the thread-local
/// fetches left in the interpreter loop:
///
///     otool -tV <binary> \
///       | awk '/^_vm.runVm:/{p=1;next} /^_[A-Za-z][^ ]*:$/{if(p)exit} p' \
///       | grep -B3 blr | grep -c 'adrp.*x0'
///
/// If that is already near zero without the barrier, LLVM has learned to hoist
/// the fetch and this helper is dead weight.
pub inline fn pinned() *Vm {
    const p = current();
    if (comptime !builtin.os.tag.isDarwin()) return p;
    return asm (""
        : [ret] "=r" (-> *Vm),
        : [in] "0" (p),
    );
}

/// Aborts unless the calling thread is running Janet.
///
/// Every published crossing but `janet_post` opens with this. A module with a
/// `Loop` can hand a runtime pointer to a thread the runtime did not start,
/// and every crossing but `post` finds the VM through the thread-local: on a
/// thread that never ran `lifecycle.init` that thread-local is the zeroed
/// one, so a crossing reads a null registry, a null collector and a null
/// symbol cache and does something undefined with them. One load and a
/// compare is what stands between that and a message.
///
/// It lives in the boundary shims only. `capi.zig`'s entry points and
/// `args.zig`'s generated `*Abi` shims are the whole population, so this is
/// declared here rather than in either: they are two files and this is one
/// rule. No runtime-internal path pays it.
///
/// Four crossings are exempt, and each says why at its own definition.
/// `janet_post`, because it is the one a thread with no VM may call, and
/// `raise.zig`'s flag pair and its abort, because none of the three can be the
/// first crossing on a thread and a check that cannot fire first guards
/// nothing.
///
/// It is blind in a `-Dsingle-threaded` build, where the storage is one
/// process-wide `var` and every thread sees an initialised VM. That costs
/// nothing to the rule it enforces: that build has no event loop, `build.zig`
/// making `ev` depend on `!options.single_threaded`, so no module can obtain a
/// `Loop` and no thread the runtime did not start has anything to call a
/// crossing with.
///
/// It is here rather than in `fatal.zig` because the question is about the
/// storage above. `fatal.zig` is how to give up and nothing about a VM.
pub inline fn requireJanetThread() void {
    if (!isInitialised()) fatal.fatal("called from a thread that is not running Janet");
}

/// Binds `name` to `val` in the dynamic bindings.
///
/// The storage is the running fiber's `env` where there is a running fiber,
/// and the VM's `top_dyns` where there is not. Whichever it is, this creates
/// it on the first write.
pub fn setdyn(name: [*:0]const u8, val: repr.Value) void {
    const v = current();
    if (v.fiber) |fiber| {
        const dyns = fiber.env orelse made: {
            const fresh = tables.new(1);
            fiber.env = fresh;
            break :made fresh;
        };
        tables.put(dyns, value.fromBytes(std.mem.span(name), .keyword), val);
    } else {
        const dyns = v.top_dyns orelse made: {
            const fresh = tables.new(10);
            v.top_dyns = fresh;
            break :made fresh;
        };
        tables.put(dyns, value.fromBytes(std.mem.span(name), .keyword), val);
    }
}

/// Allocates a detached `Vm`.
///
/// It comes from the runtime's own allocator, so a build that redirects the
/// allocator redirects this too. A detached VM is a destination for `vmSave`
/// and a source for `vmLoad`; nothing runs on one.
pub fn vmAlloc() *Vm {
    return utils.alloc(Vm);
}

/// Releases a `Vm` from `vmAlloc`. A null argument is a no-op.
pub fn vmFree(vm: ?*Vm) void {
    utils.free(vm);
}

/// Copies the calling thread's VM into `from`'s place.
pub fn vmLoad(from: *const Vm) void {
    current().* = from.*;
}

/// Copies the calling thread's VM into `into`.
pub fn vmSave(into: *Vm) void {
    into.* = current().*;
}
