//! Behavioral contract for the thread-local VM state: the storage of
//! `janet_vm` itself, the operations that copy it whole, the interpreter
//! interrupt, and the dynamic bindings that choose between two tables.
//!
//! Nothing below calls `janet_init`, with one exception. These are operations
//! over the state as a whole — its address, whole-structure copies, an atomic
//! counter — and none of them reads a field the runtime has to have filled in.
//! Keeping the VM uninitialised is deliberate: it lets the destructive cases
//! write whatever they like. The dynamic bindings run last, inside their own
//! `janet_init`/`janet_deinit`, so that the cases above still get an
//! uninitialised VM to scribble on.
//!
//! ## The layout section is gone, and the deletion is the argument
//!
//! The C original opened with three assertions and they were the reason
//! `janet_vm_state_size`, `janet_vm_state_align` and `JanetVMAlignProbe`
//! existed:
//!
//!     assert(janet_vm_state_size() == sizeof(JanetVM));
//!     assert(janet_vm_state_align() == offsetof(JanetVMAlignProbe, vm));
//!
//! The two sides were two *compilers'* views of `src/core/state.h` — the C
//! build's, and the Zig build's through `@cImport`. `janet_vm_save` copies the
//! whole structure using the owner's length, so a disagreement would truncate
//! or overrun a copy and neither would be a compile error. That was a real
//! oracle for as long as C files read `janet_vm.field`.
//!
//! Phase 10 deleted the last of those. There is one view now: `@sizeOf(c.JanetVM)`
//! is what `janet_vm_alloc` allocates, what `janet_vm_save` copies, and what
//! `janet_vm_state_size` returned — so a Zig contract asserting the equality
//! asserts a definition, which is rule 8's assertion that cannot fail. Rules
//! 20 and 24 say to ask what the two sides were and where the replacement
//! lives; here the second side was **the C implementation**, and it is not
//! somewhere else in `test/` but gone.
//!
//! So the section is dropped rather than translated, and the three
//! declarations it was the only caller of go with it. The guard-page case —
//! "a save must copy no further than the end of the structure" — is the same
//! claim from the other end and goes for the same reason: `janet_vm_save` is
//! `into.* = currentVm().*`, and a whole-struct assignment writing past the
//! struct is not a behaviour Zig has.
//!
//! What *is* still a fact about two independently produced things, and is
//! kept: `janet_local_vm()` must answer the address of the object every
//! translation unit reaches as `c.janet_vm`. One side is the exported symbol
//! the linker resolved, the other the value the function returns.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");
const harness = @import("harness.zig");
const config = @import("config");
const gc_alloc = @import("subsystems").gc_alloc;
const functions = @import("subsystems").value.functions;
const vm_state = @import("subsystems").lifecycle;
const wrap = @import("subsystems").value.wrap;
const vm_lifecycle = @import("subsystems").lifecycle;
const fibers = @import("subsystems").value.fibers;

const assert = std.debug.assert;

fn vm() *types.JanetVM {
    return c.vm();
}

/// The per-thread half of the contract needs a second thread to say it with.
/// `JANET_VM_THREAD_LOCAL` is `src/zig/state_abi.h`'s answer to the question
/// this section asks — it is false only in a single-threaded build, where the
/// storage is one process-wide object by construction and there is nothing
/// here to check. Windows is cross-compiled and never executed, so its path is
/// left out rather than written blind, which is `fiber_core.zig`'s condition
/// and its reason.
const has_threads = constants.JANET_VM_THREAD_LOCAL != 0 and builtin.os.tag != .windows;

// ------------------------------------------------------------------ address

/// `janet_local_vm()` must name the same object as `janet_vm`.
///
/// This is the one layout-adjacent claim the migration keeps, and it is not
/// circular: the left side is what the function computes and the right side is
/// where the linker put the symbol `state.h` declares. Through Phase 10 it was
/// what let Zig define the storage while every core C file went on writing
/// `janet_vm.field`; what it pins now is that `@import("cabi")`'s view of the
/// extern and the definition in `vm_state.zig` are one object rather than two.
fn localVmIsJanetVm() void {
    assert(vm_state.localVm() == vm());
    assert(vm_state.localVm() == vm_state.localVm());

    vm().stackn = 1234;
    assert(vm_state.localVm().*.stackn == 1234);
    vm_state.localVm().*.stackn = 4321;
    assert(vm().stackn == 4321);
    vm().stackn = 0;
}

// --------------------------------------------------------------- allocation

fn allocAndFree() void {
    const a = vm_state.vmAlloc();
    const b = vm_state.vmAlloc();
    // `assert(a != null)` stood here until Phase 12 increment 5d and cannot
    // be written now: `janet.h` declared `janet_vm_alloc` as `[*c]JanetVM`,
    // so through the C ABI the result was "maybe null, maybe many" and the
    // assertion was a real check. The definition returns `*c.JanetVM` and
    // either succeeds or reaches `janet_zig_out_of_memory`, which does not
    // return -- so the property is carried by the type and comparing with
    // null is a compile error. `DESIGN.md` §3: the property stops being an
    // agreement between two spellings and becomes a construction from one.
    assert(a != b);
    // A detached VM is a destination for `janet_vm_save` and nothing else, so
    // the only thing to check about a fresh one is that it can hold a save.
    vm_state.vmSave(a);
    vm_state.vmSave(b);
    vm_state.vmFree(a);
    vm_state.vmFree(b);
    vm_state.vmFree(null);
}

// ------------------------------------------------------------ save and load

/// Two snapshots taken around a change must differ in the changed field and
/// restore independently. `stackn` is the witness because it is a scalar the
/// VM owns outright — a field reached through one of the VM's pointers would
/// be shared by every snapshot rather than copied.
fn saveLoadRoundTrip() void {
    const first = vm_state.vmAlloc();
    const second = vm_state.vmAlloc();

    vm().stackn = 11;
    vm().coerce_error = 1;
    vm_state.vmSave(first);

    vm().stackn = 22;
    vm().coerce_error = 0;
    vm_state.vmSave(second);

    vm().stackn = 33;
    vm().coerce_error = 1;

    vm_state.vmLoad(first);
    assert(vm().stackn == 11);
    assert(vm().coerce_error == 1);

    vm_state.vmLoad(second);
    assert(vm().stackn == 22);
    assert(vm().coerce_error == 0);

    // A load is a plain copy: loading the same snapshot twice is idempotent,
    // and the snapshot is not consumed.
    vm_state.vmLoad(second);
    assert(vm().stackn == 22);

    vm_state.vmFree(first);
    vm_state.vmFree(second);
    vm().stackn = 0;
    vm().coerce_error = 0;
}

/// A save must copy the fields at the very end of the structure as well as the
/// ones at the front.
///
/// The C original reached the last member through a cascade of `#ifdef`s over
/// `JANET_EV`, `JANET_WINDOWS`, `JANET_EV_EPOLL` and `JANET_EV_KQUEUE` —
/// four configuration questions asked in order to find out one structural
/// fact. `@hasField` asks the structure instead, which is both shorter and a
/// better question: a configuration that gains a backend does not need a
/// branch here, and a field that is renamed fails to compile rather than
/// silently dropping out of the sweep.
fn saveSpansTheStructure() void {
    const snapshot = vm_state.vmAlloc();

    vm().user = @ptrFromInt(0x1111);
    vm().registry_count = 0x2222;
    vm().root_capacity = 0x3333;
    vm().sandbox_flags = 0x4444;
    // Aligned, unlike the C original's 0x5555: `traversal_base` is a typed
    // pointer and Zig rejects a `@ptrFromInt` that cannot satisfy its
    // alignment. The value is a witness rather than an address, so any
    // distinguishable one does.
    vm().traversal_base = @ptrFromInt(0x5550);
    if (comptime builtin.os.tag != .windows) {
        vm().strerror_buf[0] = 'z';
        vm().strerror_buf[vm().strerror_buf.len - 1] = 'q';
    }
    if (comptime config.ev) {
        vm().tq_capacity = 0x6666;
        vm().spawn.capacity = 0x7777;
        vm().active_tasks.capacity = 0x8888;
    }
    // Whichever of the four event-loop backends this build has, its last
    // field is the furthest into the structure a save has to reach.
    if (comptime config.ev and builtin.os.tag == .windows) {
        vm().connect_ex_loaded = 0x9999;
    } else if (comptime config.ev and (config.ev_epoll or config.ev_kqueue)) {
        vm().timer_enabled = 0x9999;
    } else if (comptime config.ev and config.ev_poll) {
        vm().stream_capacity = 0x9999;
    }

    vm_state.vmSave(snapshot);
    vm().* = std.mem.zeroes(types.JanetVM);
    vm_state.vmLoad(snapshot);

    assert(@intFromPtr(vm().user) == 0x1111);
    assert(vm().registry_count == 0x2222);
    assert(vm().root_capacity == 0x3333);
    assert(vm().sandbox_flags == 0x4444);
    assert(@intFromPtr(vm().traversal_base) == 0x5550);
    if (comptime builtin.os.tag != .windows) {
        assert(vm().strerror_buf[0] == 'z');
        assert(vm().strerror_buf[vm().strerror_buf.len - 1] == 'q');
    }
    if (comptime config.ev) {
        assert(vm().tq_capacity == 0x6666);
        assert(vm().spawn.capacity == 0x7777);
        assert(vm().active_tasks.capacity == 0x8888);
    }
    if (comptime config.ev and builtin.os.tag == .windows) {
        assert(vm().connect_ex_loaded == 0x9999);
    } else if (comptime config.ev and (config.ev_epoll or config.ev_kqueue)) {
        assert(vm().timer_enabled == 0x9999);
    } else if (comptime config.ev and config.ev_poll) {
        assert(vm().stream_capacity == 0x9999);
    }

    vm_state.vmFree(snapshot);
    vm().* = std.mem.zeroes(types.JanetVM);
}

// ------------------------------------------------------------- interruption

/// The interrupt counter is a signed counter, not a flag: nested interrupts
/// are balanced by the same number of handled calls. A null argument means the
/// calling thread's own VM, which is the form `os/sigaction`'s handler uses.
fn interruptCounter() void {
    const self = vm_state.localVm();
    const before = self.*.auto_suspend;

    vm_state.interpreterInterrupt(null);
    assert(self.*.auto_suspend == before + 1);
    vm_state.interpreterInterrupt(self);
    assert(self.*.auto_suspend == before + 2);
    vm_state.interpreterInterruptHandled(null);
    assert(self.*.auto_suspend == before + 1);
    vm_state.interpreterInterruptHandled(self);
    assert(self.*.auto_suspend == before);

    // An explicit VM pointer must reach that VM and no other.
    const other = vm_state.vmAlloc();
    vm_state.vmSave(other);
    other.*.auto_suspend = 0;
    vm_state.interpreterInterrupt(other);
    assert(other.*.auto_suspend == 1);
    assert(self.*.auto_suspend == before);
    vm_state.interpreterInterruptHandled(other);
    assert(other.*.auto_suspend == 0);
    vm_state.vmFree(other);
}

// ------------------------------------------------------------------ threads

var main_vm: *types.JanetVM = undefined;
var child_vm: ?*types.JanetVM = null;
var child_saw_zero = false;
var child_local_matches = false;

fn child() void {
    const bytes: [*]const u8 = @ptrCast(c.vm());
    child_saw_zero = std.mem.allEqual(u8, bytes[0..@sizeOf(types.JanetVM)], 0);
    child_vm = vm_state.localVm();
    child_local_matches = child_vm == c.vm();
    c.vm().stackn = 99;
}

/// Each thread gets its own VM, zero-initialised, and writing one leaves the
/// others alone. This is the property that makes the storage thread-local
/// rather than merely global, and it is the one thing a Zig `threadlocal var`
/// could plausibly get wrong while still linking.
///
/// `fiber_core.zig` asserts a neighbouring fact — that the collector's budget
/// is per-thread — and it is not this one: that reads a field through
/// `janet_vm` from a second thread, while this reads the *storage*, including
/// that a fresh thread's copy is zeroed and that `janet_local_vm` answers it
/// there too. Neither subsumes the other.
fn threadLocalStorage() !void {
    if (!has_threads) return;

    main_vm = vm_state.localVm();
    vm().stackn = 7;
    const thread = try std.Thread.spawn(.{}, child, .{});
    thread.join();

    assert(child_local_matches);
    assert(child_saw_zero);
    assert(child_vm != main_vm);
    assert(vm().stackn == 7);
    assert(vm_state.localVm() == main_vm);
    vm().stackn = 0;
}

// ------------------------------------------------------ dynamic bindings

/// `janet_dyn` and `janet_setdyn` choose between two tables, and which one is
/// the VM's business rather than the fiber's: a running fiber's own env when
/// there is one, `janet_vm.top_dyns` when there is not. Both tables are
/// created lazily, and the laziness is the part a port can quietly lose — a
/// reader that allocated would turn every `(dyn :missing)` into a table.
///
/// The Janet suites exercise this constantly through `setdyn` and `dyn`, but
/// always with a fiber running, so the no-fiber half below is reached by
/// nothing else.
fn dynamicBindings() void {
    const saved_fiber = vm().fiber;
    const saved_dyns = vm().top_dyns;

    vm().fiber = null;
    vm().top_dyns = null;

    // A read finds nothing and creates nothing.
    assert(harness.isType(vm_state.dyn("nope"), constants.JANET_NIL));
    assert(vm().top_dyns == null);

    vm_state.setdyn("x", harness.wrapInteger(7));
    assert(vm().top_dyns != null);
    assert(harness.equals(vm_state.dyn("x"), harness.wrapInteger(7)));
    assert(harness.isType(vm_state.dyn("y"), constants.JANET_NIL));

    // With a fiber, the same names go to the fiber's env instead, and the VM's
    // table is neither read nor written.
    const fiber = fibers.new(functions.thunkDelay(wrap.fromNil()), 8, 0, null).?;
    gc_alloc.gcroot(wrap.fromFiber(fiber));
    assert(fiber.*.env == null);
    vm().fiber = fiber;

    assert(harness.isType(vm_state.dyn("x"), constants.JANET_NIL));
    assert(fiber.*.env == null);

    vm_state.setdyn("x", harness.wrapInteger(9));
    assert(fiber.*.env != null);
    assert(harness.equals(vm_state.dyn("x"), harness.wrapInteger(9)));

    vm().fiber = null;
    assert(harness.equals(vm_state.dyn("x"), harness.wrapInteger(7)));

    _ = gc_alloc.gcunroot(wrap.fromFiber(fiber));
    vm().fiber = saved_fiber;
    vm().top_dyns = saved_dyns;
}

// ------------------------------------------------------------------- entry

pub fn run() void {
    localVmIsJanetVm();
    allocAndFree();
    saveLoadRoundTrip();
    saveSpansTheStructure();
    interruptCounter();
    threadLocalStorage() catch @panic("vm_state: could not spawn a thread");

    // Last, and the only case here that needs a live runtime.
    harness.init();
    dynamicBindings();
    vm_lifecycle.deinit();

    std.debug.print("vm state contract ok\n", .{});
}
