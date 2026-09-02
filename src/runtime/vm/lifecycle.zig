//! The VM's lifetime: bringing one up, the sandbox that narrows it, and
//! tearing it down.
//!
//! The state these calls initialise -- the type, the storage and the one
//! accessor -- is `vm/state.zig`, which every subsystem imports and this file
//! is one of. Neither has a name Janet publishes on its own -- the module is
//! `vm` -- so they are two leaves beside `vm/entry.zig`.
const std = @import("std");
const constants = @import("constants");
const ev_loop = @import("../ev.zig");
const raise = @import("../../api/raise.zig");
const gc_sweep = @import("../gc/sweep.zig");
const gc_alloc = @import("../gc.zig");
const math = @import("../math.zig");
const wrap = @import("../value/helpers/wrap.zig");
const tables = @import("../value/tables.zig");
const net = @import("../net.zig");
const ev_backend = @import("../ev/backend.zig");
const registry = @import("../registry.zig");
const order = @import("../value/helpers/order.zig");
const symbols = @import("../value/symbols.zig");
const vm_state = @import("state.zig");

/// `config.ev` and `config.net`, as comptime constants: each guards a pair of
/// calls whose declarations exist only in a build that sets it, and Zig
/// resolves a name in every branch a runtime `if` analyses.
const has_ev = constants.JANET_VM_HAS_EV != 0;
const has_net = constants.JANET_VM_HAS_NET != 0;

// ------------------------------------------------------------------ setup

/// Set up the VM.
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
    // the first thing rooted, which is why the root set is set up above it.
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

// ---------------------------------------------------------------- sandbox

/// Disable some features at run time with no way to re-enable them.
pub fn sandbox(flags: Sandbox) raise.Raising(void) {
    try sandboxAssert(Sandbox.of(&.{"sandbox"}));
    const v = vm_state.current();
    v.sandbox_flags = v.sandbox_flags.with(flags);
}

/// Raise if any of `forbidden_flags` has been sandboxed away.
///
/// Fifty-eight cfunctions open with this, which makes it the most-called raise
/// in the runtime after the argument layer's.
pub fn sandboxAssert(forbidden_flags: Sandbox) raise.Raising(void) {
    if (forbidden_flags.intersects(vm_state.current().sandbox_flags)) {
        return raise.panic("operation forbidden by sandbox");
    }
}

// --------------------------------------------------------------- teardown

/// Clear all memory associated with the VM.
///
/// The order matters at the head and not after it: `gc/sweep.zig`'s
/// `clearMemory` walks the block lists and runs what finalizers there are, so
/// it has to see the root set and the registry still standing. Everything below it is release
/// and reset.
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

pub fn deinitAbi() void {
    // Nothing here can raise: `gc` and `gcmark` are typed non-raising, and a
    // finalizer reached through `clearMemory` is the only thing teardown could
    // ever have raised from. The type is what closes that path, at the
    // callback's own definition.
    deinit();
}

/// Which capabilities have been given up.
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

    /// The three named unions, which are what `(os/sandbox)` accepts by name.
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
    // Against upstream Janet at `17b3f8c4`. Reordering the fields above fails
    // here rather than silently giving away a different capability.
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
