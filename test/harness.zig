//! What a Zig contract needs, and the deliberately short list of it.
//!
//! The list is deliberately short. A contract inside the runtime's compilation
//! crosses no boundary, so nothing here is an adapter: an equivalent written
//! for a contract on the far side of a symbol table is nine times this size,
//! and almost all of it exists to move a raise or a cfunction across the C
//! ABI. What is left is a protected scope, which is a real mechanism.
//!
//! ## The scope is not a formality
//!
//! A raise consults `vm.return_reg` to decide where it is going.
//! `signal.zig`'s `signalPlan` returns `TOP_LEVEL` when that pointer is null,
//! and a `TOP_LEVEL` raise ends the process rather than reporting. So a
//! contract that means to *observe* a raise has to open a scope first, even
//! though nothing jumps any more: `signal_core.tryInit` points `return_reg`
//! at a payload slot and `signal_core.restore` puts back what was there.
//! `raised` and `abiRaised` below are the two lines of that.
//!
//! Nothing jumps to that scope. `signal_core.tryInit` opens it so that the
//! payload has a slot and `signalPlan` has a non-null `return_reg` to find,
//! which is the whole of what a contract needs from it.
//!
//! ## A contract that expects success needs no scope
//!
//! `try` is enough. If such a call raises anyway the process ends with the
//! runtime's own top-level message, which names the panic: a loud failure and
//! an accurate one. Opening a scope to catch a raise the contract did not
//! expect would only replace that message with a less informative assertion.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const arrays = @import("subsystems").value.arrays;

/// `boundary` rather than `abi`, which `abiRaised` takes as a parameter name.
const boundary = @import("abi");
const config = @import("config");
const constants = @import("constants");
const core_env = @import("subsystems").env;
const debug = @import("subsystems").debug;
const ev = @import("subsystems").ev;
const expect = @import("expect.zig").expect;
const fibers = @import("subsystems").value.fibers;
const gc_alloc = @import("subsystems").gc_alloc;
const order = @import("subsystems").value.order;
const pp_describe = @import("subsystems").pp_describe;
const raise = @import("subsystems").raise;
const registry = @import("subsystems").registry;
const repr = @import("repr");
const scratch_vector = @import("subsystems").scratch_vector;
const signal_core = @import("subsystems").signal;
const strings = @import("subsystems").value.strings;
const structs = @import("subsystems").value.structs;
const tables = @import("subsystems").value.tables;
const utils = @import("subsystems").utils;
const value = @import("subsystems").value;
const vm_entry = @import("subsystems").vm_entry;
const vm_lifecycle = @import("subsystems").lifecycle;
const vm_state = @import("subsystems").vm_state;
const wrap = @import("subsystems").value.wrap;

// ==========================================================================
// Constants
// ==========================================================================

/// Whether this build compiled the event loop, which decides how a form that
/// waits gets driven. Read from `config`, which is the same input the
/// subsystem is gated on rather than a second belief about it.
pub const has_ev = config.ev;

// ==========================================================================
// Aliased types
// ==========================================================================

/// The compiler's growable vector, for a contract that needs one without
/// naming the allocator at each call.
///
/// A vector is a `std.ArrayListUnmanaged` over `gc.scratch_heap`, and `.empty`
/// is one that has never been grown. `vector` below is the operations over it.
///
/// `test/vector.zig` must not reach for this, because it is the contract *on*
/// `scratch_vector.zig` and both sides of its comparison have to come from
/// different files; it names `scratch_vector` directly instead.
pub const Vector = scratch_vector.Vector;

// ==========================================================================
// Types
// ==========================================================================

/// What a raise left behind: the signal it raised with, and the value in the
/// enclosing scope's return register.
pub const Raise = struct {
    signal: boundary.Signal,
    payload: repr.Value,

    /// Whether the payload is the string `expected`. A panic's payload is
    /// usually its message, and asserting on it is what distinguishes "it
    /// refused" from "it refused for the reason this contract is about".
    pub fn says(self: Raise, expected: []const u8) bool {
        if (!isType(self.payload, repr.Tag.string)) return false;
        const message = wrap.toString(self.payload);
        const length: usize = strings.head(message).length;
        return std.mem.eql(u8, message[0..length], expected);
    }

    /// The same for a message only some of which is reproducible. An abstract
    /// renders as `<type/name 0x...>`, so a refusal that names one is pinned
    /// by its prefix and the address left out.
    ///
    /// Every case that needs this is a case about an abstract, so the prefix
    /// always ends where the rendering begins and nothing after it is dropped
    /// silently.
    pub fn beginsWith(self: Raise, expected: []const u8) bool {
        if (!isType(self.payload, repr.Tag.string)) return false;
        const message = wrap.toString(self.payload);
        const length: usize = strings.head(message).length;
        return std.mem.startsWith(u8, message[0..length], expected);
    }

    /// The mirror of `beginsWith`, for a message whose *head* is the part that
    /// cannot be reproduced.
    ///
    /// It exists for `peg`, where a grammar error renders the form being
    /// compiled through `%p` before it says anything: a mutable form
    /// contributes an address there, and a nested one a thousand rules.
    pub fn endsWith(self: Raise, expected: []const u8) bool {
        if (!isType(self.payload, repr.Tag.string)) return false;
        const message = wrap.toString(self.payload);
        const length: usize = strings.head(message).length;
        return std.mem.endsWith(u8, message[0..length], expected);
    }
};

/// A fiber's stack frames, as a contract reaches them.
///
/// `at` is `fibers.stackFrame`'s arithmetic, the cast from a stack slot back
/// to the header below it, and `current` is that composed with the fiber's own
/// frame index. Two contracts call them: `vm_lifecycle`, to build a frame to
/// decode, and `vm_entry`, to read the program counter a step stopped at.
///
/// `test/fiber_core.zig` keeps its own `frameAt` and `currentFrame` beside two
/// other stack-frame helpers nothing else needs. Retrofitting it would change
/// a contract that is verified capable of failing in order to change nothing,
/// which is the same call `heap` below records.
pub const frame = struct {
    /// The frame header below the slot at `index`.
    pub fn at(fiber: *fibers.Fiber, index: i32) *vm_state.StackFrame {
        const base = fiber.data.? + @as(usize, @intCast(index));
        return @ptrCast(@alignCast(base - @as(usize, @intCast(constants.JANET_FRAME_SIZE))));
    }

    /// The frame the fiber is stopped in.
    pub fn current(fiber: *fibers.Fiber) *vm_state.StackFrame {
        return at(fiber, fiber.frame);
    }
};

/// The collector's two heap lists, as a contract reads them.
///
/// `abi.zig` owns the head arithmetic these read. Two contracts share them,
/// `gc_pcall` and `value_alloc`, and both ask the same two things: what memory
/// type the constructor stamped, and which list that put the block on. Those
/// two are how a container contract sees the collector at all.
///
/// The collector's own four contracts keep private copies. Each uses its
/// `headerOf` for more than walking a list, and retrofitting them would change
/// four contracts that are verified capable of failing in order to change
/// nothing.
pub const heap = struct {
    /// Every collectable block begins with its `GCObject`, so the block
    /// pointer *is* the header, and this is that cast and nothing else.
    pub fn headerOf(block: ?*anyopaque) *boundary.GCObject {
        return @ptrCast(@alignCast(block.?));
    }

    /// The low byte of the flags word, which is what decides which of
    /// `gc/sweep.zig`'s `deinitBlock` cases will eventually free the block and
    /// which of the two lists it is on.
    pub fn memoryType(block: ?*anyopaque) gc_alloc.MemoryType {
        return gc_alloc.memoryTypeOf(headerOf(block));
    }

    /// The mark bit, which the sweep reads and which a freshly allocated
    /// block must not have set: an allocation that arrived pre-marked would
    /// survive one collection it had no right to.
    pub fn reachable(block: ?*anyopaque) bool {
        return (gcBits(headerOf(block).flags) & constants.JANET_MEM_REACHABLE) != 0;
    }

    /// Whether `block` is on the list headed by `list`. Only ever called for
    /// a block still alive, so nothing freed is dereferenced.
    pub fn onList(list: ?*anyopaque, block: ?*anyopaque) bool {
        var current = list;
        while (current != null) {
            if (current == block) return true;
            current = @ptrCast(headerOf(current).data.next);
        }
        return false;
    }
};

/// The operations over a `Vector`, named the way a contract reads them.
///
/// `count` and `capacity` are the two fields under names that say what they
/// are; `push` and `free` are `scratch_vector`'s own, re-exported so that a
/// contract reaches the whole set through one name.
pub const vector = struct {
    /// How many elements are in the vector.
    pub fn count(v: anytype) usize {
        return v.items.len;
    }

    /// How many it has room for before the next growth.
    pub fn capacity(v: anytype) usize {
        return v.capacity;
    }

    /// Takes the vector *variable* rather than its value, because growing it
    /// moves the allocation.
    pub const push = scratch_vector.push;

    /// The count goes to zero and the allocation stays.
    pub fn empty(v: anytype) void {
        v.shrinkRetainingCapacity(0);
    }

    /// The count written directly, which `test/emit_core.zig` needs to fill a
    /// constant pool that would take quadratic time to fill honestly. Nothing
    /// but a contract has a reason to do this, and it reserves first because
    /// the memory has to exist before the length names it.
    pub fn setCount(v: anytype, n: usize) void {
        scratch_vector.ensure(v, n);
        v.items.len = n;
    }

    /// A vector belongs to the scratch allocator rather than to the
    /// collector.
    pub const free = scratch_vector.free;
};

// ==========================================================================
// Public functions
// ==========================================================================

/// Call `abi` with `args` under a protected scope and consume the report it
/// left, which is what a contract does with a published entry point that is
/// still a `raise.toAbi` wrapper.
///
/// That is the whole protocol from this side: the flag `raise.tookCRaise`
/// reads is the VM's `c_raised`, and a contract inside the compilation reads
/// it directly.
///
/// The report is taken before `signal_core.restore` runs. `restore` aborts on
/// an outstanding report, which is what makes a leaked one surface at a scope
/// boundary rather than at the raise, and it would fire here instead of
/// reporting what this was asked.
///
/// Use `raised` instead wherever the subject is a Zig function.
pub fn abiRaised(abi: anytype, args: anytype) ?Raise {
    var state: vm_state.TryState = undefined;
    signal_core.tryInit(&state);
    defer signal_core.restore(&state);
    // Discarded rather than called bare, because an abi need not return
    // void: on the raising path it returns `reportToAbi`'s zero value rather
    // than anything a contract should read.
    _ = @call(.auto, abi, args);
    if (!raise.tookCRaise()) return null;
    return .{ .signal = vm_state.current().pending_signal, .payload = state.payload };
}

/// `arrays.push`, reached by import and its raise turned into a panic, on
/// the same rule as `init`.
///
/// The raise `buffer_array.arrayPush` can make is a capacity overflow, and
/// every site in the contracts pushes onto an array it has just made, so none
/// of them is arranging one. A contract that means to test *that* should call
/// `arrays.push` itself under `raised`.
pub fn arrayPush(array: *arrays.Array, val: repr.Value) void {
    arrays.push(array, val) catch @panic("harness: janet_array_push raised");
}

/// Call a core cfunction by name over a slice of arguments.
///
/// This is the `argc`/`argv` split, which a contract otherwise spells at every
/// call from an array it already has.
///
/// It is here rather than in each contract because `net_sockets` and
/// `filewatch_core` drive their whole surface this way. Use it with `try`
/// where the value is what the case is about, and `coreRaised` where the
/// refusal is.
pub fn callCore(name: [*:0]const u8, argv: []repr.Value) raise.Error!repr.Value {
    return core(name)(argv);
}

/// A core cfunction by name, with the calling convention it actually has.
///
/// `registry.resolveCore` returns a `Value` wrapping a `CFunction`, which is
/// a pointer to a raising Zig function rather than to a C one.
/// `raise.cfunction` is the cast that says so.
pub fn core(name: [*:0]const u8) raise.CFunction {
    const val = registry.resolveCore(name);
    expect(isType(val, repr.Tag.cfunction));
    return raise.cfunction(wrap.toCfunction(val));
}

/// `core_env.coreEnv(null)`, on the same rule as `init` and `arrayPush`.
///
/// The table is never null.
pub fn coreEnv() *tables.Table {
    return core_env.coreEnv(null) catch @panic("harness: janet_core_env raised");
}

/// `core`, for a name a reduced build may not register at all: null rather
/// than a failed assertion where the binding is absent.
///
/// A contract that covers one section of a subsystem the configuration
/// compiled out has two ways to skip it: read a condition out of `options`, or
/// ask the environment. Asking is the better one where the two would agree,
/// because `options` names *subsystems* and what is missing here is a
/// *registration*. `os/cpu-count` is absent from a reduced-OS build while
/// `os_platform` itself is compiled either way, so no field of `Selection`
/// covers it.
pub fn coreOptional(name: [*:0]const u8) ?raise.CFunction {
    const val = registry.resolveCore(name);
    if (!isType(val, repr.Tag.cfunction)) return null;
    return raise.cfunction(wrap.toCfunction(val));
}

/// `callCore` under a protected scope, returning the raise it made, or null
/// where it returned. This is `raised` with the name resolution and the
/// argument split folded in.
pub fn coreRaised(name: [*:0]const u8, argv: []repr.Value) ?Raise {
    return raised(core(name), .{argv});
}

/// `order.equals` as a predicate, for the same reason as `isType`.
pub inline fn equals(left: repr.Value, right: repr.Value) bool {
    return order.equals(left, right);
}

/// A struct's field by keyword name. Every contract that reads a structure the
/// runtime built spells this, and spelling it once keeps the `ckeywordv` out
/// of the assertions.
pub fn field(structure: structs.Struct, name: [*:0]const u8) repr.Value {
    return structs.get(structure, value.fromBytes(std.mem.span(name), .keyword));
}

/// The GC header's flag word as the thirty-two bits C had.
///
/// `abi.GCObject.flags` is a `packed struct(u32)`, and a contract that
/// asserted through its *fields* would be asserting that the runtime agrees
/// with itself. The masks in `constants.zig` are the independent statement of
/// where each bit sits, so the contracts keep using them and these two are the
/// only conversion.
pub inline fn gcBits(flags: boundary.GCFlags) u32 {
    return @bitCast(flags);
}

pub inline fn gcSetBits(flags: *boundary.GCFlags, bits: anytype) void {
    flags.* = @bitCast(gcBits(flags.*) | @as(u32, @intCast(bits)));
}

/// One Janet form, run in a fiber of its own and driven to completion.
///
/// `env.zig`'s `dostring` evaluates each *top level* form in a fiber of its
/// own and does not drive the event loop, so a form that spawns a process and
/// then waits on it can outlive the wait that follows: the spawn is scheduled,
/// the wait suspends, `dostring` returns, and the next form runs against a
/// fiber that has not finished. Wrapping the whole source in `(fn [] ...)`
/// makes it one form, and scheduling that one fiber and running the loop is
/// what makes "the source finished" mean what it says.
///
/// Two contracts call it, `os_process` and `os_surface`, the two whose
/// subjects spawn.
///
/// The fiber is rooted for the length of the run. It is reachable from the
/// scheduler while it is queued but not between `fibers.new` and
/// `ev.schedule`, and compiling the *next* source is an allocation that can
/// collect.
pub fn inFiber(environment: *tables.Table, source: []const u8) void {
    var buffer: [16384]u8 = undefined;
    const wrapped = std.fmt.bufPrintZ(&buffer, "(fn [] {s})", .{source}) catch
        @panic("harness.inFiber: source does not fit");

    var val = wrap.fromNil();
    if (core_env.dostring(environment, wrapped, "contract", &val) != 0) {
        std.debug.print("harness.inFiber: could not compile\n{s}\n", .{source});
        std.debug.print("             got: {s}\n", .{pp_describe.toString(val)});
        @panic("harness.inFiber: compile failed");
    }
    expect(isType(val, repr.Tag.function));

    const fiber = fibers.new(wrap.toFunction(val), 64, &.{}) catch unreachable;
    fiber.env = environment;

    if (has_ev) {
        const wrapped_fiber = wrap.fromFiber(fiber);
        gc_alloc.gcroot(wrapped_fiber);
        defer _ = gc_alloc.gcunroot(wrapped_fiber);
        ev.schedule(fiber, wrap.fromNil());
        raise.toAbi(ev.loop());
        if (fibers.status(fiber) != fibers.FiberStatus.dead) {
            std.debug.print("harness.inFiber: did not finish\n{s}\n", .{source});
            @panic("harness.inFiber: fiber is not dead");
        }
    } else {
        const resumed = vm_entry.continueFiber(fiber, wrap.fromNil());
        if (resumed.signal != boundary.Signal.ok) {
            raise.toAbi(debug.stacktraceExt(fiber, resumed.value, ""));
            std.debug.print("harness.inFiber: raised\n{s}\n", .{source});
            @panic("harness.inFiber: unexpected signal");
        }
    }
}

/// The VM's initialisation, reached by import rather than through a symbol.
///
/// `vm_lifecycle.init` raises, because the core image can fail to unmarshal,
/// which is what a broken bootstrap looks like from here. Reached by import
/// that is an error rather than a report, so the `@panic` names both the
/// harness and the cause instead of the process dying at whichever protected
/// scope comes next.
///
/// A contract that means to *observe* an init failure calls
/// `vm_lifecycle.init` itself under `raised`. This is for the contracts that
/// only need a VM, which is most of them.
pub fn init() void {
    _ = vm_lifecycle.init() catch @panic("harness: janet_init raised");
}

/// Whether `value` is the number `expected`, which is the assertion a contract
/// over bytecode or a decoded structure makes most often. Both halves matter:
/// a value of the wrong *type* unwraps to something arbitrary rather than
/// failing, so checking the type first is what makes the comparison mean
/// anything.
pub fn integerIs(val: repr.Value, expected: i32) bool {
    return isType(val, repr.Tag.number) and wrap.toInteger(val) == expected;
}

/// A type test as a predicate, so a contract writes `isType(v, .string)`
/// rather than spelling out the tag comparison at several hundred sites.
pub inline fn isType(val: repr.Value, want: anytype) bool {
    return repr.checkType(val, want);
}

/// An opcode widened to the `u32` a bytecode word is.
///
/// A contract that builds a bytecode word by hand needs the operation in the
/// low byte of a `u32`, and `constants.Opcode` is a `u8`, so the widening has
/// to happen somewhere: here, once, rather than at each site. It takes
/// `anytype` because a `constants.PegRule` and a bare number are both spelled
/// this way too.
pub inline fn op(operation: anytype) u32 {
    return switch (@TypeOf(operation)) {
        constants.Opcode => operation.number(),
        constants.PegRule => operation.number(),
        else => @intCast(operation),
    };
}

/// Call `function` with `args` under a protected scope, and return the raise
/// it made, or null where it returned.
///
/// The result is discarded on the returning path. A contract that needs the
/// value calls the function directly with `try`; this is for the cases where
/// the refusal *is* the behaviour under test.
///
///     const r = harness.raised(subsystems.args.getBytes, .{ argv, 0 }).?;
///     expect(r.says("bad slot #0, expected bytes, got nil"));
///
/// The payload is read before `signal_core.restore` runs, because restoring is
/// what puts the outer scope's return register back.
pub fn raised(function: anytype, args: anytype) ?Raise {
    var state: vm_state.TryState = undefined;
    signal_core.tryInit(&state);
    defer signal_core.restore(&state);
    if (@call(.auto, function, args)) |_| {
        return null;
    } else |_| {
        return .{ .signal = vm_state.current().pending_signal, .payload = state.payload };
    }
}

/// `utils.cstrcmp` as a predicate, which is how every contract reads it.
pub fn stringIs(string: strings.String, expected: [*:0]const u8) bool {
    return utils.cstrcmp(string, expected) == 0;
}

/// The same for the three string-like types, which a contract has to tell
/// apart: `wrap.toString` will happily read a keyword.
pub fn stringValueIs(val: repr.Value, expected: [*:0]const u8) bool {
    return isType(val, repr.Tag.string) and stringIs(wrap.toString(val), expected);
}

pub fn symbolIs(val: repr.Value, expected: [*:0]const u8) bool {
    return isType(val, repr.Tag.symbol) and stringIs(wrap.toSymbol(val), expected);
}

pub fn keywordIs(val: repr.Value, expected: [*:0]const u8) bool {
    return isType(val, repr.Tag.keyword) and stringIs(wrap.toKeyword(val), expected);
}

/// The sixty-four bits of payload. This is the one reading whose *spelling*
/// changes with the value representation, `x.u64` under either NaN-boxed
/// layout, where a value is a union, and `x.as.u64` under the tagged one,
/// where it is a struct wrapping one.
///
/// It has no function form, so unlike `repr.checkType` a Zig caller writes it
/// out. It is here rather than in each contract because two call it:
/// `value_wrap` for "same value" and for its bit-layout section, and
/// `value_order` for the pointer hash.
///
/// The layout is read off `config.value_repr`, which is what the build
/// selected, rather than off anything derived from the compiler's predefines.
pub inline fn u64Of(x: repr.Value) u64 {
    return if (comptime config.value_repr != .tagged) @field(x, "u64") else @field(x.as, "u64");
}

/// The VM this thread is running.
///
/// `vm/state.zig`'s `current()` is the owner's accessor, and a contract is
/// inside the compilation, so it can call it. There is no second view to
/// compare it against: the storage is not a symbol, so no file reaches it
/// through the symbol table and no contract can put two spellings of one
/// address on either side of an `==`.
pub fn vm() *vm_state.Vm {
    return vm_state.current();
}

/// An `i32` as a Janet number, which is what a Janet integer is.
///
/// Here rather than at each site because every contract that builds an integer
/// argument needs the conversion, and the runtime's own subsystems already
/// spell it out one by one.
pub inline fn wrapInteger(x: i32) repr.Value {
    return wrap.fromNumber(@floatFromInt(x));
}
