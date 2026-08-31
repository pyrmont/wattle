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
//!     assert(janet_vm_state_size() == sizeof(Vm));
//!     assert(janet_vm_state_align() == offsetof(JanetVMAlignProbe, vm));
//!
//! The two sides were two *compilers'* views of one C header: a C build's, and
//! a Zig build's through `@cImport`. `janet_vm_save` copies the whole structure
//! using the owner's length, so a disagreement would truncate or overrun a copy
//! and neither would be a compile error. That was a real oracle for as long as
//! C files read `janet_vm.field`.
//!
//! There is one view now: `@sizeOf(types.Vm)` is what `janet_vm_alloc`
//! allocates, what `janet_vm_save` copies, and what `janet_vm_state_size`
//! returned -- so asserting the equality would be asserting a definition. The
//! second side was **the C implementation**, and it is not somewhere else in
//! `test/` but gone.
//!
//! So the section is dropped rather than translated, and the three
//! declarations it was the only caller of go with it. The guard-page case --
//! "a save must copy no further than the end of the structure" -- is the same
//! claim from the other end and goes for the same reason: `janet_vm_save` is
//! `into.* = current().*`, and a whole-struct assignment writing past the
//! struct is not a behaviour Zig has.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types");
const repr = @import("repr");
const constants = @import("constants");
const harness = @import("harness.zig");
const config = @import("config");
const gc_alloc = @import("subsystems").gc_alloc;
const functions = @import("subsystems").value.functions;
const vm_state = @import("subsystems").lifecycle;
const wrap = @import("subsystems").value.wrap;
const fibers = @import("subsystems").value.fibers;

const assert = std.debug.assert;

/// The VM this thread is running, through the owner's accessor, as in every
/// other contract.
fn vm() *types.Vm {
    return vm_state.current();
}

/// The per-thread half of the contract needs a second thread to say it with.
/// `constants.JANET_VM_THREAD_LOCAL` is the answer to the question this
/// section asks — it is false only in a single-threaded build, where the
/// storage is one process-wide object by construction and there is nothing
/// here to check. Windows is cross-compiled and never executed, so its path is
/// left out rather than written blind, which is `fiber_core.zig`'s condition
/// and its reason.
const has_threads = constants.JANET_VM_THREAD_LOCAL != 0 and builtin.os.tag != .windows;

// ------------------------------------------------------------------ address

/// `janet_local_vm()` must name the object this thread runs on.
///
/// **The comparison it used to make is gone with its subject.** The left side
/// was what the function computed and the right side was where the linker put
/// an exported symbol, which is what let Zig define the storage while C files
/// wrote `janet_vm.field`. There is no export, so there is no second view, and
/// asserting `localVm() == current()` would be asserting that a one-line
/// function calls the function it calls.
///
/// What is left is not circular: the exported entry point must answer a VM
/// that reads and writes as this thread's, which is a claim about behaviour
/// rather than about two spellings of an address.
fn localVmAnswersThisThread() void {
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
    // `assert(a != null)` cannot be written: a translated `[*c]Vm` made the
    // result "maybe null, maybe many" and the assertion a real check. The
    // definition returns `*types.Vm` and either succeeds or reaches
    // `janet_zig_out_of_memory`, which does not return -- so the property is
    // carried by the type and comparing with null is a compile error.
    // `DESIGN.md` section 3: the property stops being an agreement between two
    // spellings and becomes a construction from one.
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
    vm().coerce_error = true;
    vm_state.vmSave(first);

    vm().stackn = 22;
    vm().coerce_error = false;
    vm_state.vmSave(second);

    vm().stackn = 33;
    vm().coerce_error = true;

    vm_state.vmLoad(first);
    assert(vm().stackn == 11);
    assert(vm().coerce_error);

    vm_state.vmLoad(second);
    assert(vm().stackn == 22);
    assert(vm().coerce_error == false);

    // A load is a plain copy: loading the same snapshot twice is idempotent,
    // and the snapshot is not consumed.
    vm_state.vmLoad(second);
    assert(vm().stackn == 22);

    vm_state.vmFree(first);
    vm_state.vmFree(second);
    vm().stackn = 0;
    vm().coerce_error = false;
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
    vm().registry.rows.count = 0x2222;
    vm().roots.capacity = 0x3333;
    vm().sandbox_flags = types.Sandbox.fromBits(0x4444);
    // Aligned, unlike the C original's 0x5555: `traversal_base` is a typed
    // pointer and Zig rejects a `@ptrFromInt` that cannot satisfy its
    // alignment. The value is a witness rather than an address, so any
    // distinguishable one does.
    vm().traversal.base = @ptrFromInt(0x5550);
    if (comptime builtin.os.tag != .windows) {
        vm().strerror_buf[0] = 'z';
        vm().strerror_buf[vm().strerror_buf.len - 1] = 'q';
    }
    if (comptime config.ev) {
        vm().ev.tq.capacity = 0x6666;
        vm().ev.spawn.capacity = 0x7777;
        vm().ev.active_tasks.capacity = 0x8888;
    }
    // Whichever of the four event-loop backends this build has, its last
    // field is the furthest into the structure a save has to reach.
    if (comptime config.ev and builtin.os.tag == .windows) {
        vm().ev.backend.connect_ex_loaded = true;
    } else if (comptime config.ev and (config.ev_epoll or config.ev_kqueue)) {
        vm().ev.backend.timer_enabled = true;
    } else if (comptime config.ev and config.ev_poll) {
        vm().ev.backend.stream_capacity = 0x9999;
    }

    vm_state.vmSave(snapshot);
    vm().* = std.mem.zeroes(types.Vm);
    vm_state.vmLoad(snapshot);

    assert(@intFromPtr(vm().user) == 0x1111);
    assert(vm().registry.rows.count == 0x2222);
    assert(vm().roots.capacity == 0x3333);
    assert(vm().sandbox_flags.bits() == 0x4444);
    assert(@intFromPtr(vm().traversal.base) == 0x5550);
    if (comptime builtin.os.tag != .windows) {
        assert(vm().strerror_buf[0] == 'z');
        assert(vm().strerror_buf[vm().strerror_buf.len - 1] == 'q');
    }
    if (comptime config.ev) {
        assert(vm().ev.tq.capacity == 0x6666);
        assert(vm().ev.spawn.capacity == 0x7777);
        assert(vm().ev.active_tasks.capacity == 0x8888);
    }
    if (comptime config.ev and builtin.os.tag == .windows) {
        assert(vm().ev.backend.connect_ex_loaded == true);
    } else if (comptime config.ev and (config.ev_epoll or config.ev_kqueue)) {
        assert(vm().ev.backend.timer_enabled == true);
    } else if (comptime config.ev and config.ev_poll) {
        assert(vm().ev.backend.stream_capacity == 0x9999);
    }

    vm_state.vmFree(snapshot);
    vm().* = std.mem.zeroes(types.Vm);
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

var main_vm: *types.Vm = undefined;
var child_vm: ?*types.Vm = null;
var child_saw_zero = false;
var child_local_matches = false;

/// Whether every field of `state` is the field a freshly declared `Vm` has.
///
/// **Field by field, not byte by byte.** `Vm` has automatic layout, so the
/// padding between its fields is not part of its value; asserting that all
/// `@sizeOf(types.Vm)` bytes are zero is a claim about the compiler's field
/// placement and the TLS section rather than about the VM. A field loop
/// compares only what the type means.
///
/// `std.meta.eql` cannot be used on the whole struct: `Vm` reaches
/// `JanetGCData`, an untagged union, and Zig refuses to compare one. Each
/// field's own bytes are compared instead, which is well defined for the
/// scalars and for the fixed layouts whose padding *is* their ABI.
fn isFresh(state: *const types.Vm) bool {
    const fresh = types.Vm{};
    inline for (@typeInfo(types.Vm).@"struct".fields) |f| {
        const a = std.mem.asBytes(&@field(state, f.name));
        const b = std.mem.asBytes(&@field(fresh, f.name));
        if (!std.mem.eql(u8, a, b)) return false;
    }
    return true;
}

fn child() void {
    child_saw_zero = isFresh(vm_state.current());
    child_vm = vm_state.localVm();
    child_local_matches = child_vm == vm_state.current();
    vm_state.current().stackn = 99;
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
/// there is one, `vm.top_dyns` when there is not. Both tables are
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
    assert(harness.isType(vm_state.dyn("nope"), repr.Tag.nil));
    assert(vm().top_dyns == null);

    vm_state.setdyn("x", harness.wrapInteger(7));
    assert(vm().top_dyns != null);
    assert(harness.equals(vm_state.dyn("x"), harness.wrapInteger(7)));
    assert(harness.isType(vm_state.dyn("y"), repr.Tag.nil));

    // With a fiber, the same names go to the fiber's env instead, and the VM's
    // table is neither read nor written.
    const fiber = fibers.new(functions.thunkDelay(wrap.fromNil()), 8, 0, null).?;
    gc_alloc.gcroot(wrap.fromFiber(fiber));
    assert(fiber.*.env == null);
    vm().fiber = fiber;

    assert(harness.isType(vm_state.dyn("x"), repr.Tag.nil));
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
    localVmAnswersThisThread();
    allocAndFree();
    saveLoadRoundTrip();
    saveSpansTheStructure();
    interruptCounter();
    threadLocalStorage() catch @panic("vm_state: could not spawn a thread");

    // Last, and the only case here that needs a live runtime.
    harness.init();
    dynamicBindings();
    vm_state.deinit();

    std.debug.print("vm state contract ok\n", .{});
}
