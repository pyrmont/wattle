//! jump-transparent
//!
//! The runtime's lifecycle: `janet_init`, `janet_deinit`, and the sandbox.
//! This is Part 5 of Phase 9.
//!
//! These are the first and last functions any embedder calls, and between them
//! they own every field of `janet_vm` that is not owned by a subsystem. The
//! port is a transcription: the same fields in the same order, because the
//! order is load-bearing in one place — `janet_symcache_init` runs after the
//! collector's fields are set and before anything allocates, and the abstract
//! registry is created and rooted after the root set exists.
//!
//! ## What `janet_init` does not initialise, and why that is not a bug here
//!
//! `JanetVM` has more fields than `janet_init` assigns. `signal_buf`,
//! `return_reg` and `coerce_error` are established by `janet_try`; `gc_suspend`
//! by `janet_gclock`; the symbol cache's four fields by `janet_symcache_init`;
//! `rng` by `janet_rng_seed` through `janet_default_rng`; and the event loop's
//! by `janet_ev_init`. The C original leaves them alone in exactly the same
//! places, and a port that helpfully zeroed them would be changing established
//! behaviour rather than transcribing it. `test/vm_lifecycle.c` asserts the
//! post-`janet_init` state field by field, against the C selector first.
//!
//! ## The sandbox
//!
//! Two functions, four lines, and the only part of this file that raises.
//! `janet_sandbox_assert` is called from twenty-odd places across the standard
//! library and panics when a forbidden capability is used; `janet_sandbox`
//! calls it on itself first, which is what makes the sandbox one-way — a
//! sandbox that forbids `JANET_SANDBOX_SANDBOX` cannot be widened again.
//!
//! Nothing here holds a resource across that panic, so the file carries the
//! jump-transparent marker and `build.zig` enforces the absence of `defer`.

const abi = @import("abi");
const c = abi.c;

/// `JANET_VM_HAS_EV` and `JANET_VM_HAS_NET` in `src/zig/state_abi.h`. Both
/// guard a pair of calls whose declarations live inside the same `#ifdef` in
/// `state.h`, so these have to be comptime constants: Zig resolves a name in a
/// branch it analyses, and a runtime `if` would analyse both.
const has_ev = c.JANET_VM_HAS_EV != 0;
const has_net = c.JANET_VM_HAS_NET != 0;

/// `src/core/symcache.h`, declared here rather than translated. `abi.zig` gives
/// the rule: a subsystem that needs a function from a header the shared
/// translation does not carry declares it directly, and these take no
/// parameters, so no Janet type crosses.
extern fn janet_symcache_init() callconv(.c) void;
extern fn janet_symcache_deinit() callconv(.c) void;

// ------------------------------------------------------------------ setup

/// Set up the VM.
export fn janet_init() callconv(.c) c_int {

    // Garbage collection.
    c.janet_vm.blocks = null;
    c.janet_vm.weak_blocks = null;
    c.janet_vm.next_collection = 0;
    c.janet_vm.gc_interval = 0x400000;
    c.janet_vm.block_count = 0;
    c.janet_vm.gc_mark_phase = 0;

    janet_symcache_init();

    // Initialize gc roots.
    c.janet_vm.roots = null;
    c.janet_vm.root_count = 0;
    c.janet_vm.root_capacity = 0;

    // Scratch memory.
    c.janet_vm.user = null;
    c.janet_vm.scratch_mem = null;
    c.janet_vm.scratch_len = 0;
    c.janet_vm.scratch_cap = 0;

    // Sandbox flags.
    c.janet_vm.sandbox_flags = 0;

    // Initialize registry.
    c.janet_vm.registry = null;
    c.janet_vm.registry_cap = 0;
    c.janet_vm.registry_count = 0;
    c.janet_vm.registry_dirty = 0;

    // Initialize abstract registry. The first allocation of the process, and
    // the first thing rooted, which is why the root set is set up above it.
    c.janet_vm.abstract_registry = c.janet_table(0);
    c.janet_gcroot(c.janet_wrap_table(c.janet_vm.abstract_registry));

    // Traversal.
    c.janet_vm.traversal = null;
    c.janet_vm.traversal_base = null;
    c.janet_vm.traversal_top = null;

    // Core env.
    c.janet_vm.core_env = null;

    // Auto suspension.
    c.janet_vm.auto_suspend = 0;

    // Dynamic bindings.
    c.janet_vm.top_dyns = null;

    // Seed RNG.
    c.janet_rng_seed(c.janet_default_rng(), 0);

    // Fibers.
    c.janet_vm.fiber = null;
    c.janet_vm.root_fiber = null;
    c.janet_vm.stackn = 0;

    if (has_ev) c.janet_ev_init();
    if (has_net) c.janet_net_init();
    return 0;
}

// ---------------------------------------------------------------- sandbox

/// Disable some features at run time with no way to re-enable them.
export fn janet_sandbox(flags: u32) callconv(.c) void {
    janet_sandbox_assert(c.JANET_SANDBOX_SANDBOX);
    c.janet_vm.sandbox_flags |= flags;
}

/// Panic if any of `forbidden_flags` has been sandboxed away.
export fn janet_sandbox_assert(forbidden_flags: u32) callconv(.c) void {
    if ((forbidden_flags & c.janet_vm.sandbox_flags) != 0) {
        c.janet_panics(c.janet_cstring("operation forbidden by sandbox"));
        unreachable;
    }
}

// --------------------------------------------------------------- teardown

/// Clear all memory associated with the VM.
///
/// The order matters at the head and not after it: `janet_clear_memory` walks
/// the block lists and runs what finalizers there are, so it has to see the
/// root set and the registry still standing. Everything below it is release
/// and reset.
export fn janet_deinit() callconv(.c) void {
    c.janet_clear_memory();
    janet_symcache_deinit();
    c.janet_free(c.janet_vm.roots);
    c.janet_vm.roots = null;
    c.janet_vm.root_count = 0;
    c.janet_vm.root_capacity = 0;
    c.janet_vm.abstract_registry = null;
    c.janet_vm.core_env = null;
    c.janet_vm.top_dyns = null;
    c.janet_vm.user = null;
    c.janet_free(c.janet_vm.traversal_base);
    c.janet_vm.fiber = null;
    c.janet_vm.root_fiber = null;
    c.janet_free(c.janet_vm.registry);
    c.janet_vm.registry = null;
    if (has_ev) c.janet_ev_deinit();
    if (has_net) c.janet_net_deinit();
}
