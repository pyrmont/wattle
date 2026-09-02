//! The VM type, the storage that holds one, and the accessor that names it.
//!
//! This is not `vm/lifecycle.zig` because the two are asked for by different
//! files. `Vm`, the storage and `current()` are what *every* subsystem
//! needs -- a file that wants the running fiber, the GC, the registry or a
//! dynamic binding reaches for the state and nothing else -- twenty-nine files
//! do. Bringing the VM up and tearing it down is a separate concern that
//! sixteen ask for, and it lives next door.
const repr = @import("repr");
const config = @import("config");
const constants = @import("constants");
const std = @import("std");
const builtin = @import("builtin");
const utils = @import("../utils.zig");
const wrap = @import("../value/helpers/wrap.zig");
const tables = @import("../value/tables.zig");
const abstracts = @import("../value/abstracts.zig");
const value = @import("../value.zig");
const gc_alloc = @import("../gc.zig");
const registry = @import("../registry.zig");
const symbols = @import("../value/symbols.zig");
const order = @import("../value/helpers/order.zig");
const math = @import("../math.zig");
const ev_loop = @import("../ev.zig");
const ev_backend = @import("../ev/backend.zig");
const abi = @import("abi");
const vm_lifecycle = @import("lifecycle.zig");
const functions = @import("../value/functions.zig");
const fibers = @import("../value/fibers.zig");

// ---------------------------------------------------------------------------
// The VM state
//
// Nothing compares this layout against anything: no host `@cImport` names it,
// and the only reads of its representation are `@sizeOf` in `vmAlloc` and the
// `std.mem.zeroes`/`isFresh` pair in `test/vm_state.zig`, neither of which
// depends on where the compiler puts the padding -- `isFresh` compares field
// by field for exactly that reason. That is what lets the two guarded regions --
// `strerror_buf`, absent on Windows, and the event-loop block with its four
// mutually exclusive backend arms -- nest as ordinary fields: nesting a
// guarded region pads the inner struct to its own alignment and moves every
// field after it, and nothing here minds.
// ---------------------------------------------------------------------------

/// `strerror_r`'s scratch. Windows has no such field, and a zero-length array
/// is how a configuration drops one out of a struct without a second
/// declaration of everything around it.
const strerror_buf_len = if (builtin.os.tag == .windows) 0 else 256;

/// The event loop's own state, empty in a build without one.
///
/// An empty `struct` is size 0 and alignment 1, so `-Dev=false` costs
/// the VM nothing and needs no second declaration of everything above it.
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

/// One interpreter's state. `current()` below answers the calling thread's,
/// and `vm/lifecycle.zig` brings one up and tears it down.
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

/// False only in a `-Dsingle-threaded` build, which wants one process-wide VM.
const is_thread_local = constants.JANET_VM_THREAD_LOCAL != 0;

/// The VM itself. The storage class is chosen at compile time, which is why
/// the variable lives in a container picked by an `if`: `export` cannot be
/// applied conditionally to a declaration, and the address of a thread-local
/// is not comptime-known, so `@export` is not available either.
///
/// **It is not exported.** Zig 0.16 refuses to export a variable of an
/// automatic-layout type at all, and `Vm` has automatic layout. Nor would a
/// symbol be safe to add: `build.zig` gives `cli.zig` and `boot.zig` `types`,
/// `constants` and `cabi` alone and links the runtime as an *object*, so
/// `cabi.zig` is compiled a second time inside each of those executables, and
/// a declaration there that read the VM through a symbol would give the client
/// a second VM, initialised by nobody, with nothing to say so.
const storage = if (is_thread_local) struct {
    pub threadlocal var vm: Vm = std.mem.zeroes(Vm);
} else struct {
    pub var vm: Vm = std.mem.zeroes(Vm);
};

/// The VM this thread is running, and **the one accessor the runtime has**.
///
/// Inside the runtime this is the address of the variable, taken directly.
pub inline fn current() *Vm {
    return &storage.vm;
}

pub fn localVm() *Vm {
    return current();
}

/// The fiber this thread is running, for the callers that have already
/// established there is one.
///
/// **The invariant is "at or below the interpreter loop".** `continueNoCheck`
/// assigns `fiber` before it enters the loop and `signal.restore` puts back
/// whatever was there before, so a cfunction body, an opcode handler, or
/// `vm/entry.zig`'s `call` after its own entry check cannot observe a null
/// here. A caller
/// that can also be reached from outside the loop reads `current().fiber` and
/// handles the null instead.
pub inline fn currentFiber() *fibers.Fiber {
    return current().fiber orelse unreachable;
}

/// The VM pointer, captured once for a hot path, opaque to the optimiser.
///
/// **This exists because of a measurement, and it carries its own oracle so it
/// can be deleted when the measurement changes.** On Darwin every access to a
/// thread-local is a call to libdyld's `_tlv_get_addr`, and LLVM re-derives
/// the address at every *use* rather than holding it: `vm.runVm` compiled to
/// **58** of those call sequences when this was measured, against three in a
/// clang build of the same loop, and 58 of the whole binary's 349. Each is an
/// indirect call that clobbers the caller-saved registers, so the cost is the
/// spills around it as much as the call.
///
/// Neither a struct field nor a `noinline` parameter stops it -- a field of a
/// constant expression is the constant expression, and interprocedural
/// constant propagation replaces a parameter every caller passes the same
/// constant. An empty `asm` with `"=r"`/`"0"` constraints emits no
/// instructions and makes the value opaque, which is the only thing measured
/// to work. `std.mem.doNotOptimizeAway` is built on the same construct.
///
/// **Gated, because holding the address is not always right.** On an ELF
/// executable local-exec TLS is two instructions and rematerialising costs
/// nothing, so a held pointer would occupy a register for no gain. In a shared
/// object it is general-dynamic (`__tls_get_addr` per access) and this should
/// help again.
///
/// To check whether this is still earning its place:
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

/// The `Vm` itself comes from the runtime's own allocator, so a build that
/// redirects it redirects this too.
pub fn vmAlloc() *Vm {
    return utils.alloc(Vm);
}

pub fn vmFree(vm: ?*Vm) void {
    utils.free(vm);
}

pub fn vmSave(into: *Vm) void {
    into.* = current().*;
}

pub fn vmLoad(from: *const Vm) void {
    current().* = from.*;
}

/// Ask the interpreter to leave its loop at the next call or backwards jump.
/// A null argument means the calling thread's own VM, which is the form a
/// signal handler uses. The counter is atomic because the caller is usually
/// another thread, and the ordering is `abstracts.atomicInc`'s and
/// `abstracts.atomicDec`'s rather than being chosen here.
pub fn interpreterInterrupt(vm: ?*Vm) void {
    const target = vm orelse current();
    _ = abstracts.atomicInc(&target.auto_suspend);
}

pub fn interpreterInterruptHandled(vm: ?*Vm) void {
    const target = vm orelse current();
    _ = abstracts.atomicDec(&target.auto_suspend);
}

// ------------------------------------------------------- dynamic bindings

// `dyn` and `setdyn` are here rather than with the fiber because the storage
// they choose between is the VM's: a running fiber's `env` when there is one,
// and the VM's `top_dyns` when there is not. **Both tables are created
// lazily**, and that is contract: neither exists until something is bound.

pub fn dyn(name: [*:0]const u8) repr.Value {
    const v = current();
    if (v.fiber) |fiber| {
        if (fiber.env) |env| return tables.getKeyword(env, name);
        return wrap.fromNil();
    }
    const dyns = v.top_dyns orelse return wrap.fromNil();
    return tables.get(dyns, value.fromBytes(std.mem.span(name), .keyword));
}

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

/// A stack frame's two live bits, and the one the marshaller borrows.
///
/// The word is written to and read from a marshalled fiber as a signed 32-bit
/// integer, so the width and the bit positions are the contract:
/// `marsh.zig` asserts them beside the write.
pub const FrameFlags = packed struct(u32) {
    tailcall: bool = false,
    entrance: bool = false,
    _rest: u29 = 0,
    /// Set by the marshaller just before it writes the frame, to say that an
    /// environment follows. It is the sign bit, it is never set in a live
    /// frame, and the unmarshaller clears it again.
    has_env: bool = false,
};

pub const StackFrame = struct {
    func: ?*functions.Function = null,
    pc: ?[*]u32 = null,
    env: ?*functions.FuncEnv = null,
    prevframe: i32 = 0,
    flags: FrameFlags = .{},
};

pub const TryState = struct {
    stackn: u32 = 0,
    gc_handle: u32 = 0,
    vm_fiber: ?*fibers.Fiber = null,
    vm_return_reg: ?*repr.Value = null,
    payload: repr.Value = std.mem.zeroes(repr.Value),
    coerce_error: bool = false,
};

/// A pointer, a count and a capacity -- the shape of every array the VM grows
/// for itself -- with the rule that a null pointer is an empty collection
/// stated once rather than at each read.
///
/// **It owns the representation and not the memory**, and both halves of that
/// are deliberate. Growth is the owner's, and the owners would not agree on a
/// shared rule if they could: the root set grows when `count + 1 > capacity`
/// and doubles `count + 1`, the registry grows on `count == capacity` to
/// `(count + 1) * 2` with a floor of 512, and the event loop's timer queue
/// reports an allocation failure with its own source location. Each owner
/// keeps its rule; what they share is the shape and the reads.
///
pub fn Vector(comptime T: type) type {
    return struct {
        items: ?[*]T = null,
        count: usize = 0,
        capacity: usize = 0,

        const Self = @This();

        /// The live elements.
        ///
        /// Empty rather than a trap when the collection is empty: `items` is
        /// null until the first growth, and `items.?[0..0]` traps on exactly
        /// that. It is the ordinary state of a VM that has rooted nothing,
        /// allocated no scratch and scheduled no timeout.
        pub fn slice(self: Self) []T {
            if (self.count == 0) return &.{};
            return self.items.?[0..self.count];
        }

        /// One element, by index. Bounds-checked in the modes that check,
        /// which a raw `items.?[i]` is not.
        pub fn at(self: Self, index: usize) *T {
            return &self.slice()[index];
        }

        pub fn isEmpty(self: Self) bool {
            return self.count == 0;
        }

        /// Store one element at the end and advance the count. **The caller
        /// has already made room**: growth is the owner's, for the reason in
        /// this type's header, so this is the half of an append that is the
        /// same everywhere.
        ///
        /// The slot it writes is one past the live range, which is why this
        /// is a method rather than an `at` at the call site: `at(count)` is
        /// out of bounds by construction.
        pub fn appendAssumingCapacity(self: *Self, val: T) void {
            // The precondition, asserted. The write goes through a many-item
            // pointer, so a slice bounds check does not stand behind it even
            // in a safe build, and an owner that forgot to grow would write
            // past the allocation with nothing to say so.
            std.debug.assert(self.count < self.capacity);
            self.items.?[self.count] = val;
            self.count += 1;
        }

        /// Remove the element at `index`, filling the hole from the end.
        ///
        /// Filling before shrinking keeps every access inside the slice,
        /// which is what makes it checkable. Neither the root set nor the
        /// scratch table has an order a caller may depend on, which is what
        /// licenses the fill in the first place.
        pub fn swapRemove(self: *Self, index: usize) void {
            self.at(index).* = self.at(self.count - 1).*;
            self.count -= 1;
        }

        /// Remove and answer the last element.
        pub fn pop(self: *Self) T {
            const last = self.at(self.count - 1).*;
            self.count -= 1;
            return last;
        }
    };
}
