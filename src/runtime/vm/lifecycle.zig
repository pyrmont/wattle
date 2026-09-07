//! The VM's lifetime: bringing one up, the sandbox that narrows it, and
//! tearing it down.
//!
//! `init` sets up every aggregate a `Vm` has and `deinit` releases them, in
//! the order the file describes. `sandbox` gives up a capability and
//! `sandboxAssert` is the check a guarded cfunction opens with.
//!
//! The state these calls initialise, the type and the storage and the one
//! accessor, is `vm/state.zig`, which every subsystem imports and this file is
//! one of. Neither publishes a Janet name of its own, the module being `vm`,
//! so the two are leaves beside `vm/entry.zig`.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const constants = @import("constants");
const ev_backend = @import("../ev/backend.zig");
const ev_loop = @import("../ev.zig");
const gc_alloc = @import("../gc.zig");
const gc_sweep = @import("../gc/sweep.zig");
const math = @import("../math.zig");
const net = @import("../net.zig");
const order = @import("../value/helpers/order.zig");
const raise = @import("../../api/raise.zig");
const registry = @import("../registry.zig");
const symbols = @import("../value/symbols.zig");
const tables = @import("../value/tables.zig");
const vm_state = @import("state.zig");
const wrap = @import("../value/helpers/wrap.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// `config.ev` and `config.net`, as comptime constants. Each guards a pair of
/// calls whose declarations exist only in a build that sets it, and Zig
/// resolves a name in every branch a runtime `if` analyses.
const has_ev = constants.JANET_VM_HAS_EV != 0;
const has_net = constants.JANET_VM_HAS_NET != 0;

// ==========================================================================
// Types
// ==========================================================================

/// Which capabilities have been given up.
///
/// Twenty independent bits, with `all` and three names for smaller unions of
/// them. The bit order is Janet's value order, because a `packed struct`'s
/// first field is its least significant bit, and the assertion block at the
/// foot of the file checks every position.
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

    /// Every bit set, including the twelve reserved ones. Nothing reads a
    /// reserved bit and `(os/sandbox :all)` only ever ands with this, so the
    /// width costs nothing.
    pub const all = fromBits(0xFFFFFFFF);

    /// The three named unions, which are what `(os/sandbox)` accepts by name.
    pub const ffi = of(&.{ "ffi_define", "ffi_use", "ffi_jit" });
    pub const fs = of(&.{ "fs_write", "fs_read", "fs_temp" });
    pub const net = of(&.{ "net_connect", "net_listen" });

    /// A `Sandbox` with the named bits set. `names` are field names, checked
    /// at comptime.
    pub fn of(comptime names: []const [:0]const u8) Sandbox {
        comptime var out: Sandbox = .{};
        inline for (names) |n| @field(out, n) = true;
        return comptime out;
    }

    /// `self` with every bit of `other` set as well.
    pub fn with(self: Sandbox, other: Sandbox) Sandbox {
        return fromBits(self.bits() | other.bits());
    }

    /// Whether any capability in `other` is in `self`. This is the whole of
    /// `sandboxAssert`: a forbidden set meets the given-up set.
    pub fn intersects(self: Sandbox, other: Sandbox) bool {
        return (self.bits() & other.bits()) != 0;
    }

    /// The flag word as an integer.
    pub fn bits(self: Sandbox) u32 {
        return @bitCast(self);
    }

    /// The inverse of `bits`.
    pub fn fromBits(m: u32) Sandbox {
        return @bitCast(m);
    }
};

// ==========================================================================
// Public functions
// ==========================================================================

/// Clears all memory associated with the VM.
///
/// The order matters at the head and not after it. `gc/sweep.zig`'s
/// `clearMemory` walks the block lists and runs what finalizers there are, so
/// it has to see the root set and the registry still standing. Everything
/// after that call is release and reset.
pub fn deinit() void {
    gc_sweep.clearMemory();
    symbols.cacheDeinit();
    gc_alloc.rootsDeinit(&vm_state.current().roots);
    vm_state.current().abstract_registry = null;
    vm_state.current().core_env = null;
    vm_state.current().top_dyns = null;
    vm_state.current().user = null;
    order.traversalDeinit(&vm_state.current().traversal);
    vm_state.current().fiber = null;
    vm_state.current().root_fiber = null;
    registry.registryDeinit(&vm_state.current().registry);
    if (has_ev) ev_backend.evDeinit();
    if (has_net) net.netDeinit();
}

/// `deinit`, published as a crossing.
pub fn deinitAbi() void {
    // Nothing here can raise: `gc` and `gcmark` are typed non-raising, and a
    // finalizer reached through `clearMemory` is the only thing teardown could
    // ever have raised from. The type is what closes that path, at the
    // callback's own definition.
    deinit();
}

/// Sets up the VM, and returns zero.
///
/// Every aggregate a `Vm` has is initialised here. The order is not arbitrary:
/// the root set is set up before the first thing that gets rooted, and the
/// event loop and the network layer come last because both may allocate
/// through everything above them.
pub fn init() raise.Raising(c_int) {

    // Garbage collection, the root set and the scratch table: three aggregates
    // `gc.zig` owns, initialised by the three calls below.
    gc_alloc.collectorInit(&vm_state.current().gc);

    symbols.cacheInit();

    gc_alloc.rootsInit(&vm_state.current().roots);

    // `user` is the embedder's slot rather than the collector's.
    vm_state.current().user = null;
    gc_alloc.scratchInit(&vm_state.current().scratch);

    // Sandbox flags.
    vm_state.current().sandbox_flags = Sandbox.none;

    // Initialize registry.
    registry.registryInit(&vm_state.current().registry);

    // Initialize abstract registry. The first allocation of the process, and
    // the first thing rooted, so the root set is set up above it.
    vm_state.current().abstract_registry = tables.new(0);
    gc_alloc.gcroot(wrap.fromTable(vm_state.current().abstract_registry.?));

    // Traversal.
    order.traversalInit(&vm_state.current().traversal);

    // Core env.
    vm_state.current().core_env = null;

    // Auto suspension.
    vm_state.current().auto_suspend = 0;

    // Dynamic bindings.
    vm_state.current().top_dyns = null;

    // Seed RNG.
    math.rngSeed(math.defaultRng(), 0);

    // Fibers.
    vm_state.current().fiber = null;
    vm_state.current().root_fiber = null;
    vm_state.current().stackn = 0;

    if (has_ev) try ev_loop.evInit();
    if (has_net) net.netInit();
    return 0;
}

/// Gives up the capabilities in `flags`, with no way to re-enable them.
///
/// This is itself guarded by the `sandbox` capability, so a program that has
/// given that up cannot narrow the sandbox further.
pub fn sandbox(flags: Sandbox) raise.Raising(void) {
    try sandboxAssert(Sandbox.of(&.{"sandbox"}));
    const v = vm_state.current();
    v.sandbox_flags = v.sandbox_flags.with(flags);
}

/// Raises if any capability in `forbidden_flags` has been sandboxed away.
///
/// This is what a guarded cfunction opens with, and it is the most-called
/// raise in the runtime after the argument layer's.
pub fn sandboxAssert(forbidden_flags: Sandbox) raise.Raising(void) {
    if (forbidden_flags.intersects(vm_state.current().sandbox_flags)) {
        return raise.panic("operation forbidden by sandbox");
    }
}

// ==========================================================================
// Tests
// ==========================================================================

// `Sandbox` against the bit positions a published constant fixes. Reordering
// the fields fails here rather than silently giving away a different
// capability.
comptime {
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
