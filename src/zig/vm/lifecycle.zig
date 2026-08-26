//! The VM's lifetime and the state it owns.
//!
//! Two files until Phase 12 increment 6f.  `vm_lifecycle.zig` is `janet_init`,
//! `janet_deinit` and the sandbox; `vm_state.zig` is the `janet_vm` storage
//! they initialise.  Neither has a name Janet publishes on its own -- the
//! module is `vm` -- so they are one leaf beside `vm/entry.zig`.
const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");
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

// -------------------------------------------------------------------------
// Init, deinit and the sandbox -- what `vm_lifecycle.zig` was.
// -------------------------------------------------------------------------

/// `JANET_VM_HAS_EV` and `JANET_VM_HAS_NET` in `src/zig/state_abi.h`. Both
/// guard a pair of calls whose declarations live inside the same `#ifdef` in
/// `state.h`, so these have to be comptime constants: Zig resolves a name in a
/// branch it analyses, and a runtime `if` would analyse both.
const has_ev = constants.JANET_VM_HAS_EV != 0;
const has_net = constants.JANET_VM_HAS_NET != 0;

/// `src/core/symcache.h`, declared here rather than in `cabi.zig`, on the
/// tree's standing rule: a symbol the seam file does not carry is declared
/// where it is called. These take no parameters, so no Janet type crosses.
extern fn janet_symcache_init() callconv(.c) void;
extern fn janet_symcache_deinit() callconv(.c) void;

// ------------------------------------------------------------------ setup

/// Set up the VM.
pub fn init() raise.Raising(c_int) {

    // Garbage collection.
    c.vm().blocks = null;
    c.vm().weak_blocks = null;
    c.vm().next_collection = 0;
    c.vm().gc_interval = 0x400000;
    c.vm().block_count = 0;
    c.vm().gc_mark_phase = 0;

    janet_symcache_init();

    // Initialize gc roots.
    c.vm().roots = null;
    c.vm().root_count = 0;
    c.vm().root_capacity = 0;

    // Scratch memory.
    c.vm().user = null;
    c.vm().scratch_mem = null;
    c.vm().scratch_len = 0;
    c.vm().scratch_cap = 0;

    // Sandbox flags.
    c.vm().sandbox_flags = 0;

    // Initialize registry.
    c.vm().registry = null;
    c.vm().registry_cap = 0;
    c.vm().registry_count = 0;
    c.vm().registry_dirty = 0;

    // Initialize abstract registry. The first allocation of the process, and
    // the first thing rooted, which is why the root set is set up above it.
    c.vm().abstract_registry = tables.new(0);
    gc_alloc.gcroot(wrap.fromTable(c.vm().abstract_registry.?));

    // Traversal.
    c.vm().traversal = null;
    c.vm().traversal_base = null;
    c.vm().traversal_top = null;

    // Core env.
    c.vm().core_env = null;

    // Auto suspension.
    c.vm().auto_suspend = 0;

    // Dynamic bindings.
    c.vm().top_dyns = null;

    // Seed RNG.
    math.rngSeed(math.defaultRng(), 0);

    // Fibers.
    c.vm().fiber = null;
    c.vm().root_fiber = null;
    c.vm().stackn = 0;

    if (has_ev) try ev_loop.evInit();
    if (has_net) net.netInit();
    return 0;
}

pub fn janet_init() c_int {
    return raise.reported(init());
}

// ---------------------------------------------------------------- sandbox

/// Disable some features at run time with no way to re-enable them.
pub fn sandbox(flags: u32) raise.Raising(void) {
    try sandboxAssert(constants.JANET_SANDBOX_SANDBOX);
    c.vm().sandbox_flags |= flags;
}

pub fn janet_sandbox(flags: u32) void {
    raise.reported(sandbox(flags));
}

/// Raise if any of `forbidden_flags` has been sandboxed away.
///
/// Fifty-eight cfunctions open with this, which makes it the most-called raise
/// in the runtime after the argument layer's, and Part 17d is where it stopped
/// jumping.
pub fn sandboxAssert(forbidden_flags: u32) raise.Raising(void) {
    if ((forbidden_flags & c.vm().sandbox_flags) != 0) {
        return raise.panic("operation forbidden by sandbox");
    }
}

pub fn janet_sandbox_assert(forbidden_flags: u32) void {
    raise.reported(sandboxAssert(forbidden_flags));
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
    janet_symcache_deinit();
    utils.free(c.vm().roots);
    c.vm().roots = null;
    c.vm().root_count = 0;
    c.vm().root_capacity = 0;
    c.vm().abstract_registry = null;
    c.vm().core_env = null;
    c.vm().top_dyns = null;
    c.vm().user = null;
    utils.free(c.vm().traversal_base);
    // Cleared for the reason `clearMemory` clears the scratch table, and found
    // in the same audit: `value_order.zig` decides whether to grow the
    // traversal stack with `traversal_base == null`, so a dangling one sends
    // it down the grow path to `janet_realloc` a pointer that is already free.
    // Every other field this function releases is cleared right after --
    // `roots`, `registry`, and the symbol cache's four in
    // `janet_symcache_deinit` -- and these two were the exceptions.
    //
    // All three, because `janet_init` sets all three: nulling only the base
    // would be enough for correctness -- `is_new` short-circuits the other two
    // out of the comparison -- but it would leave `traversal` and
    // `traversal_top` pointing into the freed block, which is the same
    // inconsistency one field over.
    c.vm().traversal = null;
    c.vm().traversal_base = null;
    c.vm().traversal_top = null;
    c.vm().fiber = null;
    c.vm().root_fiber = null;
    utils.free(c.vm().registry);
    c.vm().registry = null;
    if (has_ev) ev_backend.evDeinit();
    if (has_net) net.netDeinit();
}

pub fn janet_deinit() void {
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

/// `JANET_VM_THREAD_LOCAL` in `src/zig/state_abi.h`: false only in a
/// single-threaded build, where `janet.h` expands JANET_THREAD_LOCAL to
/// nothing and C expects one process-wide VM.
const is_thread_local = constants.JANET_VM_THREAD_LOCAL != 0;

/// The VM itself, exported under C's name so that `janet_vm.field` throughout
/// `src/core` binds to this object. The storage class is chosen at compile
/// time, which is why the variable lives in a container picked by an `if`:
/// `export` cannot be applied conditionally to a declaration, and the address
/// of a thread-local is not comptime-known, so `@export` is not available
/// either.
const storage = if (is_thread_local) struct {
    pub export threadlocal var janet_vm: types.JanetVM = std.mem.zeroes(types.JanetVM);
} else struct {
    pub export var janet_vm: types.JanetVM = std.mem.zeroes(types.JanetVM);
};

inline fn currentVm() *types.JanetVM {
    return &storage.janet_vm;
}

pub fn localVm() *types.JanetVM {
    return currentVm();
}

/// `janet_malloc` here is the out-of-line function in `util.c`, not the macro
/// in `janet.h`; the function forwards to the macro, so a build that redirects
/// Janet's allocator is honoured either way.
pub fn vmAlloc() *types.JanetVM {
    const mem = utils.malloc(@sizeOf(types.JanetVM)) orelse fatal.outOfMemory();
    return @ptrCast(@alignCast(mem));
}

pub fn vmFree(vm: ?*types.JanetVM) void {
    utils.free(vm);
}

pub fn vmSave(into: *types.JanetVM) void {
    into.* = currentVm().*;
}

pub fn vmLoad(from: *const types.JanetVM) void {
    currentVm().* = from.*;
}

/// Ask the interpreter to leave its loop at the next call or backwards jump.
/// A null argument means the calling thread's own VM, which is the form a
/// signal handler uses. The counter is atomic because the caller is usually
/// another thread; the ordering matches `janet_atomic_inc` and
/// `janet_atomic_dec` rather than being chosen here.
pub fn interpreterInterrupt(vm: ?*types.JanetVM) void {
    const target = vm orelse currentVm();
    _ = abstracts.atomicInc(&target.auto_suspend);
}

pub fn interpreterInterruptHandled(vm: ?*types.JanetVM) void {
    const target = vm orelse currentVm();
    _ = abstracts.atomicDec(&target.auto_suspend);
}

// ------------------------------------------------------- dynamic bindings

// `janet_dyn` and `janet_setdyn` came from `capi.c` in Phase 10 Part 5. They
// are here rather than with the fiber because the storage they choose between
// is the VM's: a running fiber's `env` when there is one, and `janet_vm.top_dyns`
// when there is not. The lazy creation of both tables is the C original's --
// neither exists until something is bound.

/// `src/core/util.h`, declared here rather than in `cabi.zig`.
extern fn janet_table_get_keyword(t: *types.JanetTable, keyword: [*]const u8) callconv(.c) types.Janet;

pub fn dyn(name: [*:0]const u8) types.Janet {
    const v = currentVm();
    if (v.fiber == null) {
        const dyns = v.top_dyns orelse return wrap.fromNil();
        return tables.get(dyns, value.fromBytes(std.mem.span(name), .keyword));
    }
    if (v.fiber.?.env) |env| return janet_table_get_keyword(env, name);
    return wrap.fromNil();
}

pub fn setdyn(name: [*:0]const u8, val: types.Janet) void {
    const v = currentVm();
    if (v.fiber == null) {
        if (v.top_dyns == null) v.top_dyns = tables.new(10);
        tables.put(v.top_dyns.?, value.fromBytes(std.mem.span(name), .keyword), val);
    } else {
        if (v.fiber.?.env == null) v.fiber.?.env = tables.new(1);
        tables.put(v.fiber.?.env.?, value.fromBytes(std.mem.span(name), .keyword), val);
    }
}
