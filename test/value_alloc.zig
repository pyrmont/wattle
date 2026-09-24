//! Behavioral contract for the allocation of the three remaining collectable
//! kinds: `fibers.new` and `fibers.reset`, and `functions.FuncDef.new`,
//! `functions.thunk` and `functions.thunkDelay`.
//!
//! These are almost entirely field initialisation, and a missed store leaves
//! whatever the allocator returned, which is usually the corpse of a previous
//! block and so is usually plausible. The cases below therefore read every
//! field they can, and prefer dirtying a field before the call to asserting a
//! value a fresh allocation might have had anyway.
//!
//! Four channels reach these facts:
//!
//!  - The block header. `harness.heap.memoryType` says which of the three
//!    memory types was written, and `vm.gc.blocks` says the collector was
//!    given the block.
//!  - `vm.gc.next_collection`, which each of these functions charges. A fiber
//!    is charged twice, once by `gc.gcalloc` for the block and once by hand
//!    for the value stack, and the second charge is the one only this contract
//!    sees.
//!  - The fiber's own fields after a *failed* `fibers.reset`. This is the only
//!    way to observe the newborn state: a successful call runs
//!    `fibers.funcframe` over it, which overwrites `frame`, `stackstart` and
//!    `stacktop` before returning.
//!  - `gc/mark.zig`'s `collect`, run with the new object rooted and again with
//!    it unrooted, which is what says the block was initialised well enough
//!    for the mark phase to walk it and the sweep to free it.
//!
//! ## The flexible-array assertion is not here
//!
//! What makes `functions.thunk`'s `@sizeOf(Function)` the right size for a
//! function with no environments is that the size equals the offset of `envs`.
//! A head with a flexible array member loses it in translation, so `@offsetOf`
//! does not compile against one and the comparison would be `@sizeOf` against
//! itself. `test/gc_mark.zig` derives the offset from the allocator instead.
//!
//! ## One case needs a child process
//!
//! `functions.thunk` refuses a def that needs upvalues, and refuses it
//! *fatally*: the block it allocates is sized for no environments at all, so a
//! caller that got one back would read `envs[0]` off the end of a 24-byte
//! allocation. An abort is what a child process can report back and nothing
//! in-process can. The Windows path is cross-compiled and never executed, so
//! that case is left out rather than written blind.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");
const builtin = @import("builtin");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const config = @import("config");
const constants = @import("constants");
const core_env = @import("subsystems").env;
const expect = @import("expect.zig").expect;
const fibers = @import("subsystems").value.fibers;
const functions = @import("subsystems").value.functions;
const gc_alloc = @import("subsystems").gc_alloc;
const gc_mark = @import("subsystems").gc_mark;
const harness = @import("harness.zig");
const heap = harness.heap;
const repr = @import("repr");
const tables = @import("subsystems").value.tables;
const value = @import("subsystems").value;
const vm_entry = @import("subsystems").vm_entry;
const vm_lifecycle = @import("subsystems").lifecycle;
const vm_state = @import("subsystems").vm_state;
const wrap = @import("subsystems").value.wrap;

// ==========================================================================
// Constants
// ==========================================================================

const frame_size: i32 = constants.frame_size;
var test_env: *tables.Table = undefined;

/// Whether a fiber has the five scheduler fields, which is whether the event
/// loop was compiled.
///
/// Read from `config`, which is the build's own statement of what it compiled,
/// rather than from the shape of the fiber type.
const with_ev = config.ev;

// ==========================================================================
// Cases
// ==========================================================================

/// Reach a quiet heap, so that a later collection's effects are attributable
/// to what this contract made rather than to what an earlier case left behind.
fn settle() void {
    gc_mark.collect();
    gc_mark.collect();
}

fn compileFunction(source: [*:0]const u8) *functions.Function {
    var out = wrap.fromNil();
    const status = core_env.dostring(test_env, source, "value-alloc-test", &out);
    expect(status == 0);
    expect(harness.isType(out, repr.Tag.function));
    gc_alloc.gcroot(out);
    return wrap.toFunction(out);
}

fn statusOf(fiber: *fibers.Fiber) i32 {
    return fiber.flags.status;
}

fn onBlocks(block: ?*anyopaque) bool {
    return heap.onList(harness.vm().gc.blocks, block);
}

/// A fiber is a collectable block the collector is given immediately, tagged
/// `MemoryType.fiber`, plus a plain allocation for the value stack that hangs
/// off it.
fn aFiberIsACollectableBlock(nullary: *functions.Function) void {
    const fiber = fibers.new(nullary, 32, &.{}) catch unreachable;
    gc_alloc.gcroot(wrap.fromFiber(fiber));
    defer _ = gc_alloc.gcunroot(wrap.fromFiber(fiber));

    expect(heap.memoryType(fiber) == gc_alloc.MemoryType.fiber);
    expect(!heap.reachable(fiber));
    expect(onBlocks(fiber));
    expect(fiber.data != null);
}

/// The 32-slot floor. A caller asking for less gets 32; a caller asking for
/// more gets what it asked for, as long as the first frame fits inside it.
fn theCapacityFloor(nullary: *functions.Function) void {
    expect((fibers.new(nullary, 0, &.{}) catch unreachable).capacity == 32);
    expect((fibers.new(nullary, 31, &.{}) catch unreachable).capacity == 32);
    expect((fibers.new(nullary, -4096, &.{}) catch unreachable).capacity == 32);
    expect((fibers.new(nullary, 4096, &.{}) catch unreachable).capacity == 4096);

    // Exactly 32 is not below the floor, so it is left alone rather than
    // doubled. Only a wrong comparison would tell these two apart.
    expect((fibers.new(nullary, 32, &.{}) catch unreachable).capacity == 32);
}

/// A fiber costs the collector two charges: the block, billed by `gc.gcalloc`,
/// and the value stack, billed by hand. Nothing else in the
/// call allocates, so long as the callee takes no arguments and its frame fits
/// in the capacity asked for.
fn aFiberChargesBlockAndStack(nullary: *functions.Function) void {
    settle();
    var before = harness.vm().gc.next_collection;
    const fiber = fibers.new(nullary, 1024, &.{}) catch unreachable;
    var after = harness.vm().gc.next_collection;

    expect(fiber.capacity == 1024);
    expect(after - before == @sizeOf(fibers.Fiber) + 1024 * @sizeOf(repr.Value));

    // And the floor is charged, not the request: 32 slots for a request of 1.
    before = harness.vm().gc.next_collection;
    _ = fibers.new(nullary, 1, &.{}) catch unreachable;
    after = harness.vm().gc.next_collection;
    expect(after - before == @sizeOf(fibers.Fiber) + 32 * @sizeOf(repr.Value));
}

/// The newborn state, as `fibers.reset` leaves it. Read after a rejected
/// call, where nothing has run over it.
fn assertNewborn(fiber: *fibers.Fiber, expect_stacktop: i32) void {
    expect(fiber.maxstack == config.stack_max);
    expect(fiber.frame == 0);
    expect(fiber.stackstart == frame_size);
    expect(fiber.stacktop == expect_stacktop);
    expect(fiber.child == null);
    expect(fiber.env == null);
    expect(harness.isType(fiber.last_value, repr.Tag.nil));
    // The flag word `resetState` leaves, asserted as the bit pattern rather
    // than through `fibers.FiberFlags`: yield trapped (bit 3),
    // `resume_no_useval` (bit 25) and `resume_no_skip` (bit 26), with the
    // status field masked out.
    // Spelling the number is what keeps the oracle independent of the struct
    // whose layout it is checking.
    expect((@as(u32, @bitCast(fiber.flags)) & ~@as(u32, 0x3F0000)) ==
        (1 << 3) | (1 << 25) | (1 << 26));
    expect(statusOf(fiber) == @intFromEnum(fibers.FiberStatus.new));
    if (with_ev) {
        expect(fiber.sched_id == 0);
        expect(fiber.ev_op == null);
        expect(fiber.supervisor_channel == null);
    }
}

/// Write a distinguishable value into every field `fibers.reset` is
/// supposed to clear, so that the assertions above are about stores rather than
/// about what the allocator happened to hand back.
fn dirty(fiber: *fibers.Fiber, child: *fibers.Fiber, env: *tables.Table) void {
    fiber.maxstack = 7;
    fiber.frame = 11;
    fiber.stackstart = 13;
    fiber.stacktop = 17;
    fiber.child = child;
    fiber.env = env;
    fiber.last_value = harness.wrapInteger(23);
    fiber.flags = .{
        .traps = .of(&.{.@"error"}),
        .did_raise = true,
        .status = @intFromEnum(fibers.FiberStatus.alive),
    };
    if (with_ev) {
        fiber.sched_id = 29;
        fiber.ev_op = @ptrCast(@alignCast(fiber));
        fiber.supervisor_channel = @ptrCast(fiber);
    }
}

/// A rejected arity is reported by returning `error.Arity`, and leaves the
/// fiber in the newborn state rather than half-built, `vm/entry.zig`'s `pcall`
/// being built on the return value rather than on recovering a partial frame.
/// This is also the only vantage point from which `fibers.reset`'s own stores
/// are visible.
fn aRejectedResetLeavesANewborn(binary: *functions.Function, nullary: *functions.Function) void {
    const fiber = fibers.new(nullary, 64, &.{}) catch unreachable;
    const child = fibers.new(nullary, 32, &.{}) catch unreachable;
    const env = tables.new(0);
    const root = wrap.fromFiber(fiber);

    gc_alloc.gcroot(root);
    gc_alloc.gcroot(wrap.fromFiber(child));
    gc_alloc.gcroot(wrap.fromTable(env));
    defer {
        _ = gc_alloc.gcunroot(wrap.fromTable(env));
        _ = gc_alloc.gcunroot(wrap.fromFiber(child));
        _ = gc_alloc.gcunroot(root);
    }

    dirty(fiber, child, env);
    if (fibers.reset(fiber, binary, &.{})) |_| expect(false) else |_| {}
    assertNewborn(fiber, frame_size);
}

/// Recycling keeps the stack the fiber already paid for. This is the whole
/// reason `fibers.reset` exists as a separate entry point, and a port that
/// cleared capacity or data would still pass everything else here.
fn aResetKeepsTheStack(binary: *functions.Function, nullary: *functions.Function) void {
    const fiber = fibers.new(nullary, 4096, &.{}) catch unreachable;
    const data = fiber.data;

    gc_alloc.gcroot(wrap.fromFiber(fiber));
    defer _ = gc_alloc.gcunroot(wrap.fromFiber(fiber));
    settle();
    const before = harness.vm().gc.next_collection;

    if (fibers.reset(fiber, binary, &.{})) |_| expect(false) else |_| {}
    expect(fiber.capacity == 4096);
    expect(fiber.data == data);
    expect(harness.vm().gc.next_collection == before);
}

/// Arguments are copied into the slots above the frame base, and a null argv is
/// a request for that many nils rather than a request for nothing. Read through
/// a rejected callee so the frame machinery has not moved anything.
fn argumentsLandAboveTheFrame(binary: *functions.Function, nullary: *functions.Function) void {
    const fiber = fibers.new(nullary, 64, &.{}) catch unreachable;
    gc_alloc.gcroot(wrap.fromFiber(fiber));
    defer _ = gc_alloc.gcunroot(wrap.fromFiber(fiber));

    var args = [_]repr.Value{
        harness.wrapInteger(101),
        harness.wrapInteger(102),
        harness.wrapInteger(103),
    };

    // Three arguments to a function of two: rejected, but only after the
    // arguments have been placed.
    if (fibers.reset(fiber, binary, &args)) |_| expect(false) else |_| {}
    expect(fiber.stacktop == frame_size + 3);
    expect(fiber.stackstart == frame_size);
    for (0..3) |i| {
        expect(wrap.toInteger(fiber.data.?[@intCast(frame_size + @as(i32, @intCast(i)))]) ==
            101 + @as(i32, @intCast(i)));
    }

    // Three nils, and they land in every slot. C spelled this as a null `argv`
    // with a count of three; the slice says it.
    for (0..3) |i| {
        fiber.data.?[@intCast(frame_size + @as(i32, @intCast(i)))] = harness.wrapInteger(-1);
    }
    const three_nils = [_]repr.Value{wrap.fromNil()} ** 3;
    if (fibers.reset(fiber, binary, &three_nils)) |_| expect(false) else |_| {}
    expect(fiber.stacktop == frame_size + 3);
    for (0..3) |i| {
        expect(harness.isType(fiber.data.?[@intCast(frame_size + @as(i32, @intCast(i)))], repr.Tag.nil));
    }

    // Zero arguments touch neither the stack pointer nor the slots.
    fiber.data.?[@intCast(frame_size)] = harness.wrapInteger(-7);
    if (fibers.reset(fiber, binary, &.{})) |_| expect(false) else |_| {}
    expect(fiber.stacktop == frame_size);
    expect(wrap.toInteger(fiber.data.?[@intCast(frame_size)]) == -7);
}

/// The argument block grows the stack when it would exactly fill it, not only
/// when it would overrun it. The two differ by one comparison and by a factor
/// of two in the resulting capacity: a stack that is grown here reaches
/// `2 * newstacktop`, and one that is not stays at its old size, because the
/// frame that follows is small enough to fit either way.
///
/// The frame that follows is `2 * frame_size + slotcount` regardless of
/// how many arguments were pushed, because `funcframe` measures from
/// `stackstart` and the argument block does not move it. So the assertion
/// below is independent of the vararg function's arity.
fn theArgumentBlockGrowsOnEquality(variadic: *functions.Function) void {
    const argc: i32 = 32 - frame_size;
    var args: [28]repr.Value = undefined;
    for (0..@intCast(argc)) |i| args[i] = harness.wrapInteger(@intCast(i));
    expect(2 * frame_size + variadic.def.?.slotcount < 64);

    const fiber = fibers.new(variadic, 32, &args) catch unreachable;
    gc_alloc.gcroot(wrap.fromFiber(fiber));
    defer _ = gc_alloc.gcunroot(wrap.fromFiber(fiber));

    // `frame_size + argc == 32 == the capacity asked for`, so the stack
    // was doubled to 64 before the arguments were written.
    expect(fiber.capacity == 64);
}

/// A frame's header, which lives in the slots immediately below the frame's
/// base.
fn fiberFrame(fiber: *fibers.Fiber) *vm_state.StackFrame {
    return @ptrCast(@alignCast(fiber.data.? + @as(usize, @intCast(fiber.frame - frame_size))));
}

/// A fiber built by `fibers.new` is left with its first frame pushed and
/// marked as an entrance frame, and, under the event loop, with no
/// supervisor.
fn aFiberIsReadyToRun(binary: *functions.Function) void {
    var args = [_]repr.Value{ harness.wrapInteger(3), harness.wrapInteger(4) };
    const fiber = fibers.new(binary, 32, &args) catch unreachable;
    gc_alloc.gcroot(wrap.fromFiber(fiber));
    defer _ = gc_alloc.gcunroot(wrap.fromFiber(fiber));

    const frame = fiberFrame(fiber);
    expect(fiber.frame == frame_size);
    expect(frame.func == binary);
    var flags = frame.flags;
    expect(flags.argc == 2);
    flags.argc = 0;
    expect(@as(i32, @bitCast(flags)) == constants.stackframe_entrance);
    expect(statusOf(fiber) == @intFromEnum(fibers.FiberStatus.new));
    if (with_ev) expect(fiber.supervisor_channel == null);
}

/// A fiber allocated here has to survive the collector: marked while rooted,
/// and freed with its value stack when it is not. Nothing else in this file
/// runs the sweep over a block these functions produced.
fn aFiberSurvivesACollection(nullary: *functions.Function) void {
    const fiber = fibers.new(nullary, 128, &.{}) catch unreachable;
    const root = wrap.fromFiber(fiber);

    gc_alloc.gcroot(root);
    gc_mark.collect();
    expect(heap.memoryType(fiber) == gc_alloc.MemoryType.fiber);
    expect(fiber.capacity == 128);
    expect(onBlocks(fiber));

    _ = gc_alloc.gcunroot(root);
    settle();
    const blocks_before = harness.vm().gc.block_count;
    gc_mark.collect();
    expect(harness.vm().gc.block_count == blocks_before);
}

/// Every field `functions.FuncDef.new` writes.
///
/// A missing store here is only visible when the memory underneath it was
/// something else, and on macOS it never is: a block is zeroed on free, so a
/// recycled block reads exactly like a correctly emptied one. Every field
/// below whose correct value is zero is therefore out of reach of an
/// in-process contract on that platform. Only `max_arity`, which starts at
/// `INT32_MAX`, is checkable here.
fn assertEmptyFuncdef(def: *functions.FuncDef) void {
    expect(def.environments == null);
    expect(def.constants == null);
    expect(def.bytecode == null);
    expect(def.closure_bitset == null);
    expect(def.sourcemap == null);
    expect(def.source == null);
    expect(def.name == null);
    expect(def.symbolmap == null);

    // Every bit clear, read as the word rather than against the type's field
    // defaults, which are what `defs.new` writes.
    expect(@as(u32, @bitCast(def.flags)) == 0);
    expect(def.slotcount == 0);
    expect(def.arity == 0);
    expect(def.min_arity == 0);
    expect(def.max_arity == std.math.maxInt(i32));
    expect(def.constants_length == 0);
    expect(def.bytecode_length == 0);
    expect(def.environments_length == 0);
    expect(def.defs == null);
    expect(def.defs_length == 0);
    expect(def.symbolmap_length == 0);
}

/// An empty funcdef: every pointer null, every length zero, and `max_arity` at
/// `INT32_MAX` rather than at zero, because an unfinished funcdef accepts
/// anything until the assembler or the compiler narrows it.
fn aFuncdefStartsEmpty() void {
    const def = functions.defs.new();
    const root = wrap.fromFunction(functions.thunk(def));

    gc_alloc.gcroot(root);
    defer _ = gc_alloc.gcunroot(root);

    expect(heap.memoryType(def) == gc_alloc.MemoryType.funcdef);
    expect(!heap.reachable(def));
    expect(onBlocks(def));
    assertEmptyFuncdef(def);
}

/// Two funcdefs are two blocks. A port that cached or reused one would pass
/// every field assertion above.
fn funcdefsAreDistinct() void {
    const a = functions.defs.new();
    const b = functions.defs.new();
    expect(a != b);
    expect(onBlocks(a));
    expect(onBlocks(b));
}

/// The funcdef block is charged at its own size.
fn aFuncdefChargesItsBlock() void {
    settle();
    const before = harness.vm().gc.next_collection;
    _ = functions.defs.new();
    const after = harness.vm().gc.next_collection;
    expect(after - before == @sizeOf(functions.FuncDef));
}

/// An empty funcdef is initialised well enough for the mark phase to walk it
/// and the sweep to free it. This is what the field-by-field assertions are
/// actually protecting: the collector reads every one of those pointers.
fn anEmptyFuncdefSurvivesACollection() void {
    const def = functions.defs.new();
    const root = wrap.fromFunction(functions.thunk(def));

    gc_alloc.gcroot(root);
    gc_mark.collect();
    expect(heap.memoryType(def) == gc_alloc.MemoryType.funcdef);
    expect(def.max_arity == std.math.maxInt(i32));

    _ = gc_alloc.gcunroot(root);
    settle();
    const blocks_before = harness.vm().gc.block_count;
    gc_mark.collect();
    expect(harness.vm().gc.block_count == blocks_before);
}

/// A thunk is a `MemoryType.function` block wrapping one funcdef and no
/// environments, sized for exactly that.
fn aThunkWrapsTheDef() void {
    const def = functions.defs.new();
    const func = functions.thunk(def);
    const root = wrap.fromFunction(func);

    gc_alloc.gcroot(root);
    defer _ = gc_alloc.gcunroot(root);

    expect(heap.memoryType(func) == gc_alloc.MemoryType.function);
    expect(!heap.reachable(func));
    expect(onBlocks(func));
    expect(func.def == def);
}

fn aThunkChargesItsBlock() void {
    const def = functions.defs.new();
    settle();
    const before = harness.vm().gc.next_collection;
    _ = functions.thunk(def);
    const after = harness.vm().gc.next_collection;
    expect(after - before == @sizeOf(functions.Function));
}

/// Two thunks over one def are two functions that agree about the def.
fn thunksAreDistinct() void {
    const def = functions.defs.new();
    const a = functions.thunk(def);
    const b = functions.thunk(def);
    expect(a != b);
    expect(a.def == def);
    expect(b.def == def);
}

/// A thunk over a def that needs upvalues is refused, and refused fatally: the
/// block `functions.thunk` allocates is sized for no environments at all, so a
/// caller that got one back would read `envs[0]` off the end of a 24-byte
/// allocation. `fatal.fatal` aborts, and abort is what a child process can
/// report back.
///
/// `std.fork` rather than the runtime's own `os_process.forkProcess`, because
/// what this observes is the abort rather than the process subsystem, and
/// because that subsystem is not compiled in every configuration this contract
/// runs under.
fn aThunkRefusesUpvalues() void {
    const child = std.c.fork();
    expect(child >= 0);

    if (child == 0) {
        const def = functions.defs.new();
        def.environments_length = 1;
        // The abort message is the point of the exercise, not of the log.
        const null_fd = std.c.open("/dev/null", .{ .ACCMODE = .WRONLY });
        if (null_fd >= 0) _ = std.c.dup2(null_fd, 2);
        _ = functions.thunk(def);
        std.c._exit(0);
    }

    var status: c_int = 0;
    expect(std.c.waitpid(child, &status, 0) == child);
    const bits: u32 = @bitCast(status);
    expect(std.c.W.IFSIGNALED(bits));
    expect(std.c.W.TERMSIG(bits) == std.c.SIG.ABRT);
}

/// `functions.thunkDelay` assembles a funcdef by hand rather than compiling
/// one, and every field it sets is one the interpreter will read. The two
/// allocations come from the plain heap allocator rather than from `gc.gcalloc`
/// deliberately: a funcdef owns its bytecode and constants outright.
///
/// The last assertion is the one that matters. Every field could be right and
/// the bytecode still be wrong: the load-constant opcode takes its constant
/// index from the instruction, and a zeroed second word would give back an
/// empty slot instead of the value. Calling the thunk is the only check that
/// covers it.
fn aDelayedThunkReturnsItsValue() void {
    var x = value.fromBytes("delayed", .string);

    gc_alloc.gcroot(x);
    defer _ = gc_alloc.gcunroot(x);
    const f = functions.thunkDelay(x);
    gc_alloc.gcroot(wrap.fromFunction(f));
    defer _ = gc_alloc.gcunroot(wrap.fromFunction(f));

    expect(f.def.?.arity == 0);
    expect(f.def.?.min_arity == 0);
    expect(f.def.?.max_arity == std.math.maxInt(i32));
    expect(f.def.?.flags.vararg);
    expect(f.def.?.slotcount == 1);
    expect(f.def.?.bytecode_length == 2);
    expect(f.def.?.constants_length == 1);
    expect(harness.equals(f.def.?.constantValues()[0], x));
    expect(f.def.?.name == null);
    expect(f.def.?.environments_length == 0);

    var resumed = vm_entry.pcall(f, &.{}, null);
    expect(resumed.signal == abi.Signal.ok);
    expect(harness.equals(resumed.value, x));

    // Varargs: it ignores whatever it is called with.
    resumed = vm_entry.pcall(f, (&x)[0..1], null);
    expect(resumed.signal == abi.Signal.ok);
    expect(harness.equals(resumed.value, x));
}

/// Repeated allocation of all three kinds, with collections in between, so that
/// a block whose header or fields were written wrongly is swept rather than
/// merely inspected.
fn repeatedCycles(nullary: *functions.Function) void {
    var i: i32 = 0;
    while (i < 64) : (i += 1) {
        const fiber = wrap.fromFiber(fibers.new(nullary, i, &.{}) catch unreachable);
        const thunk = wrap.fromFunction(functions.thunk(functions.defs.new()));
        gc_alloc.gcroot(fiber);
        gc_alloc.gcroot(thunk);
        gc_mark.collect();
        _ = functions.defs.new();
        _ = gc_alloc.gcunroot(thunk);
        _ = gc_alloc.gcunroot(fiber);
        gc_mark.collect();
    }
}

// ==========================================================================
// Entry
// ==========================================================================

pub fn run() void {
    harness.init();
    defer vm_lifecycle.deinit();

    test_env = harness.coreEnv();
    gc_alloc.gcroot(wrap.fromTable(test_env));

    const nullary = compileFunction("(fn [] 1)");
    const binary = compileFunction("(fn [a b] (+ a b))");
    const variadic = compileFunction("(fn [& args] (length args))");

    aFiberIsACollectableBlock(nullary);
    theCapacityFloor(nullary);
    aFiberChargesBlockAndStack(nullary);

    aRejectedResetLeavesANewborn(binary, nullary);
    aResetKeepsTheStack(binary, nullary);
    argumentsLandAboveTheFrame(binary, nullary);
    theArgumentBlockGrowsOnEquality(variadic);
    aFiberIsReadyToRun(binary);
    aFiberSurvivesACollection(nullary);

    aFuncdefStartsEmpty();
    funcdefsAreDistinct();
    aFuncdefChargesItsBlock();
    anEmptyFuncdefSurvivesACollection();

    aThunkWrapsTheDef();
    aThunkChargesItsBlock();
    thunksAreDistinct();
    // Windows has no `fork`, and neither does WASI, which runs one process.
    if (builtin.os.tag != .windows and builtin.os.tag != .wasi) aThunkRefusesUpvalues();

    aDelayedThunkReturnsItsValue();

    repeatedCycles(nullary);
}
