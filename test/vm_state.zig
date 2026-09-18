//! Behavioral contract for the thread-local VM state: the storage itself, the
//! operations that copy it whole, the interpreter interrupt, and the dynamic
//! bindings that choose between two tables.
//!
//! Nothing below brings a VM up, with one exception. These are operations over
//! the state as a whole, its address, whole-structure copies and an atomic
//! counter, and none of them reads a field the runtime has to have filled in.
//! Keeping the VM uninitialised is deliberate: it lets the destructive cases
//! write whatever they like. The dynamic bindings run last, inside their own
//! `vm_lifecycle.init` and `deinit`, so that the cases above still get an
//! uninitialised VM to scribble on.
//!
//! ## There is no layout section
//!
//! `@sizeOf(vm_state.Vm)` is what `vm_state.vmAlloc` allocates and what
//! `vmSave` copies, so asserting that a size accessor agrees with it would be
//! asserting a definition rather than checking anything. The same goes for the
//! bound on how far a save may copy: `vmSave` is `into.* = current().*`, and a
//! whole-struct assignment writing past the struct is not a behaviour Zig has.
//! Both were worth checking while two compilers had separate views of one
//! header. There is one view now.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");
const builtin = @import("builtin");

// ==========================================================================
// Project imports
// ==========================================================================

const config = @import("config");
const constants = @import("constants");
const expect = @import("expect.zig").expect;
const fibers = @import("subsystems").value.fibers;
const functions = @import("subsystems").value.functions;
const gc_alloc = @import("subsystems").gc_alloc;
const harness = @import("harness.zig");
const repr = @import("repr");
const vm_lifecycle = @import("subsystems").lifecycle;
const vm_state = @import("subsystems").vm_state;
const wrap = @import("subsystems").value.wrap;

// ==========================================================================
// Constants
// ==========================================================================

var child_local_matches = false;
var child_saw_zero = false;
var child_vm: ?*vm_state.Vm = null;

/// The per-thread half of the contract needs a second thread to say it with.
/// `constants.vm_thread_local` is false only in a single-threaded
/// build, where the storage is one process-wide object by construction and
/// there is nothing here to check. Windows is cross-compiled and never
/// executed, so its path is left out rather than written blind, on the same
/// condition and for the same reason as `test/fiber_core.zig`.
const has_threads = constants.vm_thread_local != 0 and builtin.os.tag != .windows;

var main_vm: *vm_state.Vm = undefined;

// ==========================================================================
// Cases
// ==========================================================================

/// The VM this thread is running, through the owner's accessor, as in every
/// other contract.
fn vm() *vm_state.Vm {
    return vm_state.current();
}

/// `vm_state.localVm()` must name the object this thread runs on.
///
/// The assertion is about behaviour rather than about two spellings of an
/// address. Asserting `localVm() == current()` would be asserting that a
/// one-line function calls the function it calls, since there is no second
/// view of that address to compare it against. What is checked instead is that
/// a write through one is a read through the other, in both directions.
fn localVmAnswersThisThread() void {
    vm().stackn = 1234;
    expect(vm_state.localVm().stackn == 1234);
    vm_state.localVm().stackn = 4321;
    expect(vm().stackn == 4321);
    vm().stackn = 0;
}

fn allocAndFree() void {
    const a = vm_state.vmAlloc();
    const b = vm_state.vmAlloc();
    // `expect(a != null)` is a compile error rather than a check:
    // `vm_state.vmAlloc` returns `*vm_state.Vm`, so it either succeeds or
    // reaches `fatal.outOfMemory`, which does not return. The type states the
    // property and there is nothing left to assert about it.
    expect(a != b);
    // A detached VM is a destination for `vmSave` and nothing else, so the
    // only thing to check about a fresh one is that a save lands in it.
    vm_state.vmSave(a);
    vm_state.vmSave(b);
    vm_state.vmFree(a);
    vm_state.vmFree(b);
    vm_state.vmFree(null);
}

/// Two snapshots taken around a change must differ in the changed field and
/// restore independently. `stackn` is the witness because it is a scalar the
/// VM owns outright, where a field reached through one of the VM's pointers
/// would be shared by every snapshot rather than copied.
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
    expect(vm().stackn == 11);
    expect(vm().coerce_error);

    vm_state.vmLoad(second);
    expect(vm().stackn == 22);
    expect(vm().coerce_error == false);

    // A load is a plain copy: loading the same snapshot twice is idempotent,
    // and the snapshot is not consumed.
    vm_state.vmLoad(second);
    expect(vm().stackn == 22);

    vm_state.vmFree(first);
    vm_state.vmFree(second);
    vm().stackn = 0;
    vm().coerce_error = false;
}

/// A save must copy the fields at the very end of the structure as well as the
/// ones at the front.
///
/// Which field is last depends on the event loop and its backend, so
/// `@hasField` asks the structure rather than asking the configuration what it
/// selected. That is the better question here: a configuration that gains a
/// backend does not need a
/// branch here, and a field that is renamed fails to compile rather than
/// silently dropping out of the sweep.
fn saveSpansTheStructure() void {
    const snapshot = vm_state.vmAlloc();

    vm().user = @ptrFromInt(0x1111);
    vm().registry.rows.capacity = 0x2222;
    vm().roots.capacity = 0x3333;
    vm().sandbox_flags = vm_lifecycle.Sandbox.fromBits(0x4444);
    // Aligned, because `traversal.base` is a typed pointer and Zig rejects a
    // `@ptrFromInt` that cannot satisfy its alignment. The value is a witness
    // rather than an address, so any distinguishable one does.
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
    vm().* = std.mem.zeroes(vm_state.Vm);
    vm_state.vmLoad(snapshot);

    expect(@intFromPtr(vm().user) == 0x1111);
    expect(vm().registry.rows.capacity == 0x2222);
    expect(vm().roots.capacity == 0x3333);
    expect(vm().sandbox_flags.bits() == 0x4444);
    expect(@intFromPtr(vm().traversal.base) == 0x5550);
    if (comptime builtin.os.tag != .windows) {
        expect(vm().strerror_buf[0] == 'z');
        expect(vm().strerror_buf[vm().strerror_buf.len - 1] == 'q');
    }
    if (comptime config.ev) {
        expect(vm().ev.tq.capacity == 0x6666);
        expect(vm().ev.spawn.capacity == 0x7777);
        expect(vm().ev.active_tasks.capacity == 0x8888);
    }
    if (comptime config.ev and builtin.os.tag == .windows) {
        expect(vm().ev.backend.connect_ex_loaded == true);
    } else if (comptime config.ev and (config.ev_epoll or config.ev_kqueue)) {
        expect(vm().ev.backend.timer_enabled == true);
    } else if (comptime config.ev and config.ev_poll) {
        expect(vm().ev.backend.stream_capacity == 0x9999);
    }

    vm_state.vmFree(snapshot);
    vm().* = std.mem.zeroes(vm_state.Vm);
}

/// The interrupt counter is a signed counter, not a flag: nested interrupts
/// are balanced by the same number of handled calls. A null argument means the
/// calling thread's own VM, which is the form `os/sigaction`'s handler uses.
fn interruptCounter() void {
    const self = vm_state.localVm();
    const before = self.auto_suspend;

    vm_state.interpreterInterrupt(null);
    expect(self.auto_suspend == before + 1);
    vm_state.interpreterInterrupt(self);
    expect(self.auto_suspend == before + 2);
    vm_state.interpreterInterruptHandled(null);
    expect(self.auto_suspend == before + 1);
    vm_state.interpreterInterruptHandled(self);
    expect(self.auto_suspend == before);

    // An explicit VM pointer must reach that VM and no other.
    const other = vm_state.vmAlloc();
    vm_state.vmSave(other);
    other.auto_suspend = 0;
    vm_state.interpreterInterrupt(other);
    expect(other.auto_suspend == 1);
    expect(self.auto_suspend == before);
    vm_state.interpreterInterruptHandled(other);
    expect(other.auto_suspend == 0);
    vm_state.vmFree(other);
}

/// Whether every field of `state` is the field a freshly declared `Vm` has.
///
/// Field by field rather than byte by byte. `Vm` has automatic layout, so the
/// padding between its fields is not part of its value, and asserting that all
/// `@sizeOf(vm_state.Vm)` bytes are zero would be a claim about the compiler's
/// field placement and the TLS section rather than about the VM. A field loop
/// compares only what the type means.
///
/// `std.meta.eql` cannot be used on the whole struct: `Vm` reaches
/// `GCData`, an untagged union, and Zig refuses to compare one. Each
/// field's own bytes are compared instead, which is well defined for the
/// scalars and for the fixed layouts whose padding *is* their ABI.
fn isFresh(state: *const vm_state.Vm) bool {
    const fresh = vm_state.Vm{};
    inline for (@typeInfo(vm_state.Vm).@"struct".fields) |f| {
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
/// `test/fiber_core.zig` asserts a neighbouring fact, that the collector's
/// budget is per-thread, and it is not this one: that reads a field through
/// the VM accessor from a second thread, while this reads the *storage*,
/// including that a fresh thread's copy is zeroed. Neither subsumes the other.
fn threadLocalStorage() !void {
    if (!has_threads) return;

    main_vm = vm_state.localVm();
    vm().stackn = 7;
    const thread = try std.Thread.spawn(.{}, child, .{});
    thread.join();

    expect(child_local_matches);
    expect(child_saw_zero);
    expect(child_vm != main_vm);
    expect(vm().stackn == 7);
    expect(vm_state.localVm() == main_vm);
    vm().stackn = 0;
}

/// `vm_state.dyn` and `vm_state.setdyn` choose between two tables, and which
/// one is the VM's business rather than the fiber's: a running fiber's own env
/// where there is one, `vm.top_dyns` where there is not. Both tables are
/// created lazily, and the laziness is the part a port can quietly lose, since
/// a reader that allocated would turn every `(dyn :missing)` into a table.
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
    expect(harness.isType(vm_state.dyn("nope"), repr.Tag.nil));
    expect(vm().top_dyns == null);

    vm_state.setdyn("x", harness.wrapInteger(7));
    expect(vm().top_dyns != null);
    expect(harness.equals(vm_state.dyn("x"), harness.wrapInteger(7)));
    expect(harness.isType(vm_state.dyn("y"), repr.Tag.nil));

    // With a fiber, the same names go to the fiber's env instead, and the VM's
    // table is neither read nor written.
    const fiber = fibers.new(functions.thunkDelay(wrap.fromNil()), 8, &.{}) catch unreachable;
    gc_alloc.gcroot(wrap.fromFiber(fiber));
    expect(fiber.env == null);
    vm().fiber = fiber;

    expect(harness.isType(vm_state.dyn("x"), repr.Tag.nil));
    expect(fiber.env == null);

    vm_state.setdyn("x", harness.wrapInteger(9));
    expect(fiber.env != null);
    expect(harness.equals(vm_state.dyn("x"), harness.wrapInteger(9)));

    vm().fiber = null;
    expect(harness.equals(vm_state.dyn("x"), harness.wrapInteger(7)));

    _ = gc_alloc.gcunroot(wrap.fromFiber(fiber));
    vm().fiber = saved_fiber;
    vm().top_dyns = saved_dyns;
}

// ==========================================================================
// Entry
// ==========================================================================

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
    vm_lifecycle.deinit();
}
