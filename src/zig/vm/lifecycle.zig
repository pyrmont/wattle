//! The VM's lifetime and the state it owns.
//!
//! Two files once: `janet_init`, `janet_deinit` and the sandbox in one, the VM
//! storage they initialise in the other. Neither has a name Janet publishes on
//! its own -- the module is `vm` -- so they are one leaf beside `vm/entry.zig`.
const types = @import("types");
const repr = @import("repr");
const constants = @import("constants");
const ev_loop = @import("../ev.zig");
const raise = @import("raise");
const gc_sweep = @import("../gc/sweep.zig");
const gc_alloc = @import("../gc.zig");
const utils = @import("../utils.zig");
const math = @import("../math.zig");
const wrap = @import("../value/helpers/wrap.zig");
const tables = @import("../value/tables.zig");
const std = @import("std");
const abstracts = @import("../value/abstracts.zig");
const value = @import("../value.zig");
const fatal = @import("../fatal.zig");
const net = @import("../net.zig");
const ev_backend = @import("../ev/backend.zig");
const registry = @import("../registry.zig");
const order = @import("../value/helpers/order.zig");
const symbols = @import("../value/symbols.zig");

// -------------------------------------------------------------------------
// Init, deinit and the sandbox -- what `vm_lifecycle.zig` was.
// -------------------------------------------------------------------------

/// `config.ev` and `config.net`. Both
/// guard a pair of calls whose declarations live inside the same `#ifdef` in
/// `state.h`, so these have to be comptime constants: Zig resolves a name in a
/// branch it analyses, and a runtime `if` would analyse both.
const has_ev = constants.JANET_VM_HAS_EV != 0;
const has_net = constants.JANET_VM_HAS_NET != 0;

// ------------------------------------------------------------------ setup

/// Set up the VM.
pub fn init() raise.Raising(c_int) {

    // Garbage collection, the root set and the scratch table: three aggregates
    // `gc.zig` owns, initialised by the three calls below.
    gc_alloc.collectorInit(&current().gc);

    symbols.cacheInit();

    gc_alloc.rootsInit(&current().roots);

    // `user` is the embedder's slot rather than the collector's, and it sat
    // under this comment because `janet_init` groups it with the scratch
    // table. It is neither, so it is on its own.
    current().user = null;
    gc_alloc.scratchInit(&current().scratch);

    // Sandbox flags.
    current().sandbox_flags = types.Sandbox.none;

    // Initialize registry.
    registry.registryInit(&current().registry);

    // Initialize abstract registry. The first allocation of the process, and
    // the first thing rooted, which is why the root set is set up above it.
    current().abstract_registry = tables.new(0);
    gc_alloc.gcroot(wrap.fromTable(current().abstract_registry.?));

    // Traversal.
    order.traversalInit(&current().traversal);

    // Core env.
    current().core_env = null;

    // Auto suspension.
    current().auto_suspend = 0;

    // Dynamic bindings.
    current().top_dyns = null;

    // Seed RNG.
    math.rngSeed(math.defaultRng(), 0);

    // Fibers.
    current().fiber = null;
    current().root_fiber = null;
    current().stackn = 0;

    if (has_ev) try ev_loop.evInit();
    if (has_net) net.netInit();
    return 0;
}

pub fn initAbi() c_int {
    return raise.reported(init());
}

// ---------------------------------------------------------------- sandbox

/// Disable some features at run time with no way to re-enable them.
pub fn sandbox(flags: types.Sandbox) raise.Raising(void) {
    try sandboxAssert(types.Sandbox.of(&.{"sandbox"}));
    const v = current();
    v.sandbox_flags = v.sandbox_flags.with(flags);
}

/// The abi keeps Janet's `uint32_t`: a capability set is a bit pattern on the
/// published boundary and a type inside.
pub fn sandboxAbi(flags: u32) void {
    raise.reported(sandbox(types.Sandbox.fromBits(flags)));
}

/// Raise if any of `forbidden_flags` has been sandboxed away.
///
/// Fifty-eight cfunctions open with this, which makes it the most-called raise
/// in the runtime after the argument layer's.
pub fn sandboxAssert(forbidden_flags: types.Sandbox) raise.Raising(void) {
    if (forbidden_flags.intersects(current().sandbox_flags)) {
        return raise.panic("operation forbidden by sandbox");
    }
}

pub fn sandboxAssertAbi(forbidden_flags: u32) void {
    raise.reported(sandboxAssert(types.Sandbox.fromBits(forbidden_flags)));
}

// --------------------------------------------------------------- teardown

/// Clear all memory associated with the VM.
///
/// The order matters at the head and not after it: `janet_clear_memory` walks
/// the block lists and runs what finalizers there are, so it has to see the
/// root set and the registry still standing. Everything below it is release
/// and reset.
pub fn deinit() void {
    gc_sweep.clearMemory();
    symbols.cacheDeinit();
    gc_alloc.rootsDeinit(&current().roots);
    current().abstract_registry = null;
    current().core_env = null;
    current().top_dyns = null;
    current().user = null;
    order.traversalDeinit(&current().traversal);
    current().fiber = null;
    current().root_fiber = null;
    registry.registryDeinit(&current().registry);
    if (has_ev) ev_backend.evDeinit();
    if (has_net) net.netDeinit();
}

pub fn deinitAbi() void {
    // Nothing here can raise since the hinge typed `gc` and `gcmark`
    // non-raising: the only thing teardown could ever raise was a finalizer,
    // through `clearMemory`. `FOUND.md`'s "A panicking finalizer poisons the
    // heap and kills the process at deinit" was the report of that path, and
    // the type is what closed it.
    deinit();
}

// -------------------------------------------------------------------------
// The `janet_vm` storage -- what `vm_state.zig` was.
// -------------------------------------------------------------------------

/// False only in a `-Dsingle-threaded` build, which wants one process-wide VM.
const is_thread_local = constants.JANET_VM_THREAD_LOCAL != 0;

/// The VM itself. The storage class is chosen at compile time, which is why
/// the variable lives in a container picked by an `if`: `export` cannot be
/// applied conditionally to a declaration, and the address of a thread-local
/// is not comptime-known, so `@export` is not available either.
///
/// **It is not exported**, and the two constraints that made it so are gone.
/// `build.zig` gives `cli.zig` and `boot.zig` `types`, `constants` and `cabi`
/// alone and links the runtime as an *object*, so `cabi.zig` is compiled a
/// second time inside each of those executables; while anything there read the
/// VM through a symbol, a storage the linker could not merge would have given
/// the client a second VM, initialised by nobody, with nothing to say so.
/// Nothing reads it that way now. And Zig 0.16 refuses to export a variable of
/// an automatic-layout type at all, which `types.Vm` became when its guarded
/// regions were allowed to nest.
const storage = if (is_thread_local) struct {
    pub threadlocal var vm: types.Vm = std.mem.zeroes(types.Vm);
} else struct {
    pub var vm: types.Vm = std.mem.zeroes(types.Vm);
};

/// The VM this thread is running, and **the one accessor the runtime has**.
///
/// Every subsystem once read the storage below through an `@extern`, so a file
/// that needed the current fiber imported the C ABI to get it, and the
/// dependency named the wrong owner. No `@extern` is left: `janet_vm` is not a
/// symbol in any build, and `cabi.zig` says so where the declaration used to
/// be.
///
/// Inside the runtime this is the address of the variable, taken directly.
pub inline fn current() *types.Vm {
    return &storage.vm;
}

pub fn localVm() *types.Vm {
    return current();
}

/// `janet_malloc` here is the out-of-line function in `util.c`, not the macro
/// in `janet.h`; the function forwards to the macro, so a build that redirects
/// Janet's allocator is honoured either way.
pub fn vmAlloc() *types.Vm {
    const mem = utils.malloc(@sizeOf(types.Vm)) orelse fatal.outOfMemory();
    return @ptrCast(@alignCast(mem));
}

pub fn vmFree(vm: ?*types.Vm) void {
    utils.free(vm);
}

pub fn vmSave(into: *types.Vm) void {
    into.* = current().*;
}

pub fn vmLoad(from: *const types.Vm) void {
    current().* = from.*;
}

/// Ask the interpreter to leave its loop at the next call or backwards jump.
/// A null argument means the calling thread's own VM, which is the form a
/// signal handler uses. The counter is atomic because the caller is usually
/// another thread; the ordering matches `janet_atomic_inc` and
/// `janet_atomic_dec` rather than being chosen here.
pub fn interpreterInterrupt(vm: ?*types.Vm) void {
    const target = vm orelse current();
    _ = abstracts.atomicInc(&target.auto_suspend);
}

pub fn interpreterInterruptHandled(vm: ?*types.Vm) void {
    const target = vm orelse current();
    _ = abstracts.atomicDec(&target.auto_suspend);
}

// ------------------------------------------------------- dynamic bindings

// `janet_dyn` and `janet_setdyn` are here rather than with the fiber because
// the storage they choose between is the VM's: a running fiber's `env` when
// there is one, and the VM's `top_dyns` when there is not. The lazy creation
// of both tables is Janet's --
// neither exists until something is bound.

pub fn dyn(name: [*:0]const u8) repr.Value {
    const v = current();
    if (v.fiber == null) {
        const dyns = v.top_dyns orelse return wrap.fromNil();
        return tables.get(dyns, value.fromBytes(std.mem.span(name), .keyword));
    }
    if (v.fiber.?.env) |env| return tables.getKeyword(env, name);
    return wrap.fromNil();
}

pub fn setdyn(name: [*:0]const u8, val: repr.Value) void {
    const v = current();
    if (v.fiber == null) {
        if (v.top_dyns == null) v.top_dyns = tables.new(10);
        tables.put(v.top_dyns.?, value.fromBytes(std.mem.span(name), .keyword), val);
    } else {
        if (v.fiber.?.env == null) v.fiber.?.env = tables.new(1);
        tables.put(v.fiber.?.env.?, value.fromBytes(std.mem.span(name), .keyword), val);
    }
}
