//! The thread-local `JanetVM` and the operations over it as a whole: reaching
//! the current thread's VM, allocating a detached one, copying a VM in and out
//! of the current thread, and the interpreter interrupt.
//!
//! This is Phase 7's first port, and its point is the seam rather than the
//! code. The functions here are small; what they establish is that Zig owns
//! the storage. `janet_vm` is defined below, and C's `extern
//! JANET_THREAD_LOCAL JanetVM janet_vm` in `src/core/state.h` resolves to it —
//! same address, same per-thread instance, same zero initialisation. Every
//! later runtime port inherits that: Zig reads and writes VM fields directly,
//! by name, with no bridge function and no mirrored structure.
//!
//! The rules that go with owning it are in `src/zig/README.md` under "Owning
//! the thread-local VM state". Two are worth repeating where the code is:
//!
//!  - The VM is a plain aggregate. Nothing here allocates, frees, or traces
//!    anything it points at; `janet_init` and `janet_deinit` in `vm.c` still
//!    own the fields' contents, and a copy made by `janet_vm_save` aliases
//!    every one of them.
//!  - `janet_vm_alloc` returns *uninitialised* memory, exactly as the C
//!    implementation did. It is a destination for `janet_vm_save`, never a VM
//!    in its own right, and reading a field of one before saving into it is a
//!    caller error rather than something this file defends against.

const std = @import("std");
const abi = @import("abi");
const c = abi.c;

/// `JANET_VM_THREAD_LOCAL` in `src/zig/state_abi.h`: false only in a
/// single-threaded build, where `janet.h` expands JANET_THREAD_LOCAL to
/// nothing and C expects one process-wide VM.
const is_thread_local = c.JANET_VM_THREAD_LOCAL != 0;

/// The VM itself, exported under C's name so that `janet_vm.field` throughout
/// `src/core` binds to this object. The storage class is chosen at compile
/// time, which is why the variable lives in a container picked by an `if`:
/// `export` cannot be applied conditionally to a declaration, and the address
/// of a thread-local is not comptime-known, so `@export` is not available
/// either.
const storage = if (is_thread_local) struct {
    pub export threadlocal var janet_vm: c.JanetVM = std.mem.zeroes(c.JanetVM);
} else struct {
    pub export var janet_vm: c.JanetVM = std.mem.zeroes(c.JanetVM);
};

inline fn currentVm() *c.JanetVM {
    return &storage.janet_vm;
}

export fn janet_local_vm() callconv(.c) *c.JanetVM {
    return currentVm();
}

/// `janet_malloc` here is the out-of-line function in `util.c`, not the macro
/// in `janet.h`; the function forwards to the macro, so a build that redirects
/// Janet's allocator is honoured either way.
export fn janet_vm_alloc() callconv(.c) *c.JanetVM {
    const mem = c.janet_malloc(@sizeOf(c.JanetVM)) orelse c.janet_zig_out_of_memory();
    return @ptrCast(@alignCast(mem));
}

export fn janet_vm_free(vm: ?*c.JanetVM) callconv(.c) void {
    c.janet_free(vm);
}

export fn janet_vm_save(into: *c.JanetVM) callconv(.c) void {
    into.* = currentVm().*;
}

export fn janet_vm_load(from: *const c.JanetVM) callconv(.c) void {
    currentVm().* = from.*;
}

/// Ask the interpreter to leave its loop at the next call or backwards jump.
/// A null argument means the calling thread's own VM, which is the form a
/// signal handler uses. The counter is atomic because the caller is usually
/// another thread; the ordering matches `janet_atomic_inc` and
/// `janet_atomic_dec` rather than being chosen here.
export fn janet_interpreter_interrupt(vm: ?*c.JanetVM) callconv(.c) void {
    const target = vm orelse currentVm();
    _ = c.janet_atomic_inc(&target.auto_suspend);
}

export fn janet_interpreter_interrupt_handled(vm: ?*c.JanetVM) callconv(.c) void {
    const target = vm orelse currentVm();
    _ = c.janet_atomic_dec(&target.auto_suspend);
}

// ------------------------------------------------------- dynamic bindings

// `janet_dyn` and `janet_setdyn` came from `capi.c` in Phase 10 Part 5. They
// are here rather than with the fiber because the storage they choose between
// is the VM's: a running fiber's `env` when there is one, and `janet_vm.top_dyns`
// when there is not. The lazy creation of both tables is the C original's --
// neither exists until something is bound.

/// `src/core/util.h`, which `abi.zig` does not translate.
extern fn janet_table_get_keyword(t: *c.JanetTable, keyword: [*c]const u8) callconv(.c) c.Janet;

export fn janet_dyn(name: [*c]const u8) callconv(.c) c.Janet {
    const v = currentVm();
    if (v.fiber == null) {
        const dyns = v.top_dyns orelse return c.janet_wrap_nil();
        return c.janet_table_get(dyns, c.janet_ckeywordv(name));
    }
    if (v.fiber.*.env) |env| return janet_table_get_keyword(env, name);
    return c.janet_wrap_nil();
}

export fn janet_setdyn(name: [*c]const u8, value: c.Janet) callconv(.c) void {
    const v = currentVm();
    if (v.fiber == null) {
        if (v.top_dyns == null) v.top_dyns = c.janet_table(10);
        c.janet_table_put(v.top_dyns, c.janet_ckeywordv(name), value);
    } else {
        if (v.fiber.*.env == null) v.fiber.*.env = c.janet_table(1);
        c.janet_table_put(v.fiber.*.env, c.janet_ckeywordv(name), value);
    }
}
