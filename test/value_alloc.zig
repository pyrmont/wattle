//! Behavioral contract for the allocation of the three remaining collectable
//! kinds: `janet_fiber` and `janet_fiber_reset`, and `janet_funcdef_alloc`,
//! `janet_thunk` and `janet_thunk_delay`.
//!
//! These are almost entirely field initialisation, and field initialisation is
//! what a port silently gets wrong: a missed store leaves whatever
//! `janet_malloc` returned, which is usually the corpse of a previous block and
//! so is usually plausible. So the cases below read every field they can and
//! prefer dirtying a field before the call to asserting a value that a fresh
//! allocation might have had anyway.
//!
//! Four channels carry it:
//!
//!  - The block header. `harness.heap.memoryType` says which of the three
//!    memory types was written, and `janet_vm.blocks` says the collector was
//!    handed the block.
//!  - `janet_vm.next_collection`, which each of these functions charges. A
//!    fiber is charged twice, once by `janet_gcalloc` for the block and once by
//!    hand for the value stack, and the second charge is the one only this
//!    contract sees.
//!  - The fiber's own fields after a *failed* `janet_fiber_reset`. This is the
//!    only way to observe the newborn state: a successful call runs
//!    `janet_fiber_funcframe` over it, which overwrites `frame`, `stackstart`
//!    and `stacktop` before returning.
//!  - `janet_collect`, run with the new object rooted and again with it
//!    unrooted, which is what says the block was initialised well enough for
//!    the mark phase to walk it and the sweep to free it.
//!
//! ## Where the flexible-array assertion went
//!
//! The C original opened with
//! `sizeof(JanetFunction) == offsetof(JanetFunction, envs)`, which is what
//! makes `janet_thunk`'s `@sizeOf(JanetFunction)` the right size for a function
//! with no environments. `@cImport` drops a flexible array member, so
//! `@offsetOf` does not compile here and a translation would compare `@sizeOf`
//! with itself — rules 8 and 20.
//!
//! Rule 24 says to ask where the replacement already lives, and it does:
//! `test/abi.c` has carried this exact assertion since Phase 11 Part 8, beside
//! the four head-offset ones, because it is a claim about `janet.h` and C is
//! the only side that can still spell both halves of it. Nothing was written
//! here.
//!
//! ## One case needs a child process
//!
//! `janet_thunk` refuses a def that needs upvalues, and refuses it *fatally* —
//! the block it allocates is sized for no environments at all, so a caller that
//! got one back would read `envs[0]` off the end of a 24-byte allocation. An
//! abort is what a child process can report back and nothing in-process can.
//! The Windows path is cross-compiled and never executed, so it is left out
//! rather than written blind, exactly as the C original left it out.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");
const harness = @import("harness.zig");
const config = @import("config");
const value = @import("subsystems").value;
const gc_alloc = @import("subsystems").gc_alloc;
const gc_mark = @import("subsystems").gc_mark;
const functions = @import("subsystems").value.functions;
const core_env = @import("subsystems").env;
const vm_entry = @import("subsystems").vm_entry;
const wrap = @import("subsystems").value.wrap;
const vm_lifecycle = @import("subsystems").lifecycle;
const tables = @import("subsystems").value.tables;
const fibers = @import("subsystems").value.fibers;

const heap = harness.heap;
const assert = std.debug.assert;

/// `JANET_EV` decides whether a fiber has the five scheduler fields.
///
/// This used to ask the *translated type* — `@hasField(c.JanetFiber,
/// "sched_id")` — on the stated grounds that "a `JANET_*` macro is not
/// reliable through `@cImport`". Phase 12 increment 1 removed the premise
/// rather than working around it: the build says what it compiled.
const with_ev = config.ev;

const frame_size: i32 = constants.JANET_FRAME_SIZE;

var test_env: *types.JanetTable = undefined;

// ----------------------------------------------------------------- helpers

/// Reach a quiet heap, so that a later collection's effects are attributable
/// to what this contract made rather than to what an earlier case left behind.
fn settle() void {
    gc_mark.collect();
    gc_mark.collect();
}

fn compileFunction(source: [*:0]const u8) *types.JanetFunction {
    var out = wrap.fromNil();
    const status = core_env.dostring(test_env, source, "value-alloc-test", &out);
    assert(status == 0);
    assert(harness.isType(out, constants.JANET_FUNCTION));
    gc_alloc.gcroot(out);
    return wrap.toFunction(out);
}

fn statusOf(fiber: *types.JanetFiber) i32 {
    return (fiber.flags & constants.JANET_FIBER_STATUS_MASK) >> constants.JANET_FIBER_STATUS_OFFSET;
}

/// `janet_fiber_frame` from `fiber.h`, which translate-c does not surface: a
/// frame lives in the four `Janet` slots immediately below the frame's base.
fn fiberFrame(fiber: *types.JanetFiber) *types.JanetStackFrame {
    return @ptrCast(@alignCast(fiber.data.? + @as(usize, @intCast(fiber.frame - frame_size))));
}

/// The newborn state, as `janet_fiber_reset` leaves it. Read after a rejected
/// call, where nothing has run over it.
fn assertNewborn(fiber: *types.JanetFiber, expect_stacktop: i32) void {
    assert(fiber.maxstack == config.stack_max);
    assert(fiber.frame == 0);
    assert(fiber.stackstart == frame_size);
    assert(fiber.stacktop == expect_stacktop);
    assert(fiber.child == null);
    assert(fiber.env == null);
    assert(harness.isType(fiber.last_value, constants.JANET_NIL));
    assert((fiber.flags & ~@as(i32, constants.JANET_FIBER_STATUS_MASK)) ==
        (constants.JANET_FIBER_MASK_YIELD | constants.JANET_FIBER_RESUME_NO_USEVAL | constants.JANET_FIBER_RESUME_NO_SKIP));
    assert(statusOf(fiber) == constants.JANET_STATUS_NEW);
    if (with_ev) {
        assert(fiber.sched_id == 0);
        assert(fiber.ev_callback == null);
        assert(fiber.ev_state == null);
        assert(fiber.ev_stream == null);
        assert(fiber.supervisor_channel == null);
    }
}

/// Write a distinguishable value into every field `janet_fiber_reset` is
/// supposed to clear, so that the assertions above are about stores rather than
/// about what the allocator happened to hand back.
fn dirty(fiber: *types.JanetFiber, child: *types.JanetFiber, env: *types.JanetTable) void {
    fiber.maxstack = 7;
    fiber.frame = 11;
    fiber.stackstart = 13;
    fiber.stacktop = 17;
    fiber.child = child;
    fiber.env = env;
    fiber.last_value = harness.wrapInteger(23);
    fiber.flags = constants.JANET_FIBER_MASK_ERROR | constants.JANET_FIBER_DID_RAISE |
        (constants.JANET_STATUS_ALIVE << constants.JANET_FIBER_STATUS_OFFSET);
    if (with_ev) {
        fiber.sched_id = 29;
        fiber.ev_callback = null;
        fiber.ev_state = @ptrCast(fiber);
        fiber.ev_stream = null;
        fiber.supervisor_channel = @ptrCast(fiber);
    }
}

fn onBlocks(block: ?*anyopaque) bool {
    return heap.onList(c.vm().blocks, block);
}

// ------------------------------------------------------------ fiber blocks

/// A fiber is a collectable block the collector is given immediately, tagged
/// `JANET_MEMORY_FIBER`, plus a plain allocation for the value stack that hangs
/// off it.
fn aFiberIsACollectableBlock(nullary: *types.JanetFunction) void {
    const fiber = fibers.new(nullary, 32, 0, null).?;
    gc_alloc.gcroot(wrap.fromFiber(fiber));
    defer _ = gc_alloc.gcunroot(wrap.fromFiber(fiber));

    assert(heap.memoryType(fiber) == constants.JANET_MEMORY_FIBER);
    assert(!heap.reachable(fiber));
    assert(onBlocks(fiber));
    assert(fiber.*.data != null);
}

/// The 32-slot floor. A caller asking for less gets 32; a caller asking for
/// more gets what it asked for, as long as the first frame fits inside it.
fn theCapacityFloor(nullary: *types.JanetFunction) void {
    assert(fibers.new(nullary, 0, 0, null).?.*.capacity == 32);
    assert(fibers.new(nullary, 31, 0, null).?.*.capacity == 32);
    assert(fibers.new(nullary, -4096, 0, null).?.*.capacity == 32);
    assert(fibers.new(nullary, 4096, 0, null).?.*.capacity == 4096);

    // Exactly 32 is not below the floor, so it is left alone rather than
    // doubled. Only a wrong comparison would tell these two apart.
    assert(fibers.new(nullary, 32, 0, null).?.*.capacity == 32);
}

/// A fiber costs the collector two charges: the block, billed by
/// `janet_gcalloc`, and the value stack, billed by hand. Nothing else in the
/// call allocates, so long as the callee takes no arguments and its frame fits
/// in the capacity asked for.
fn aFiberChargesBlockAndStack(nullary: *types.JanetFunction) void {
    settle();
    var before = c.vm().next_collection;
    const fiber = fibers.new(nullary, 1024, 0, null).?;
    var after = c.vm().next_collection;

    assert(fiber.*.capacity == 1024);
    assert(after - before == @sizeOf(types.JanetFiber) + 1024 * @sizeOf(types.Janet));

    // And the floor is charged, not the request: 32 slots for a request of 1.
    before = c.vm().next_collection;
    _ = fibers.new(nullary, 1, 0, null);
    after = c.vm().next_collection;
    assert(after - before == @sizeOf(types.JanetFiber) + 32 * @sizeOf(types.Janet));
}

// -------------------------------------------------------------- fiber_reset

/// A rejected arity is reported by returning null, and leaves the fiber in the
/// newborn state rather than half-built -- callers use the return value to
/// implement `janet_pcall`, not to recover a partial frame. This is also the
/// only vantage point from which `janet_fiber_reset`'s own stores are visible.
fn aRejectedResetLeavesANewborn(binary: *types.JanetFunction, nullary: *types.JanetFunction) void {
    const fiber = fibers.new(nullary, 64, 0, null).?;
    const child = fibers.new(nullary, 32, 0, null).?;
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
    assert(fibers.reset(fiber, binary, 0, null) == null);
    assertNewborn(fiber, frame_size);
}

/// Recycling keeps the stack the fiber already paid for. This is the whole
/// reason `janet_fiber_reset` exists as a separate entry point, and a port that
/// cleared capacity or data would still pass everything else here.
fn aResetKeepsTheStack(binary: *types.JanetFunction, nullary: *types.JanetFunction) void {
    const fiber = fibers.new(nullary, 4096, 0, null).?;
    const data = fiber.*.data;

    gc_alloc.gcroot(wrap.fromFiber(fiber));
    defer _ = gc_alloc.gcunroot(wrap.fromFiber(fiber));
    settle();
    const before = c.vm().next_collection;

    assert(fibers.reset(fiber, binary, 0, null) == null);
    assert(fiber.*.capacity == 4096);
    assert(fiber.*.data == data);
    assert(c.vm().next_collection == before);
}

/// Arguments are copied into the slots above the frame base, and a null argv is
/// a request for that many nils rather than a request for nothing. Read through
/// a rejected callee so the frame machinery has not moved anything.
fn argumentsLandAboveTheFrame(binary: *types.JanetFunction, nullary: *types.JanetFunction) void {
    const fiber = fibers.new(nullary, 64, 0, null).?;
    gc_alloc.gcroot(wrap.fromFiber(fiber));
    defer _ = gc_alloc.gcunroot(wrap.fromFiber(fiber));

    var args = [_]types.Janet{
        harness.wrapInteger(101),
        harness.wrapInteger(102),
        harness.wrapInteger(103),
    };

    // Three arguments to a function of two: rejected, but only after the
    // arguments have been placed.
    assert(fibers.reset(fiber, binary, 3, &args) == null);
    assert(fiber.*.stacktop == frame_size + 3);
    assert(fiber.*.stackstart == frame_size);
    for (0..3) |i| {
        assert(wrap.toInteger(fiber.*.data.?[@intCast(frame_size + @as(i32, @intCast(i)))]) ==
            101 + @as(i32, @intCast(i)));
    }

    // No argv means nil, and means it for every slot.
    for (0..3) |i| {
        fiber.*.data.?[@intCast(frame_size + @as(i32, @intCast(i)))] = harness.wrapInteger(-1);
    }
    assert(fibers.reset(fiber, binary, 3, null) == null);
    assert(fiber.*.stacktop == frame_size + 3);
    for (0..3) |i| {
        assert(harness.isType(fiber.*.data.?[@intCast(frame_size + @as(i32, @intCast(i)))], constants.JANET_NIL));
    }

    // Zero arguments touch neither the stack pointer nor the slots.
    fiber.*.data.?[@intCast(frame_size)] = harness.wrapInteger(-7);
    assert(fibers.reset(fiber, binary, 0, null) == null);
    assert(fiber.*.stacktop == frame_size);
    assert(wrap.toInteger(fiber.*.data.?[@intCast(frame_size)]) == -7);
}

/// The argument block grows the stack when it would exactly fill it, not only
/// when it would overrun it. The two differ by one comparison and by a factor
/// of two in the resulting capacity: a stack that is grown here reaches
/// `2 * newstacktop`, and one that is not stays at its old size, because the
/// frame that follows is small enough to fit either way.
///
/// The frame that follows is `2 * JANET_FRAME_SIZE + slotcount` regardless of
/// how many arguments were pushed -- `funcframe` measures from `stackstart`,
/// which the argument block does not move -- so the assertion below is
/// independent of the vararg function's arity.
fn theArgumentBlockGrowsOnEquality(variadic: *types.JanetFunction) void {
    const argc: i32 = 32 - frame_size;
    var args: [28]types.Janet = undefined;
    for (0..@intCast(argc)) |i| args[i] = harness.wrapInteger(@intCast(i));
    assert(2 * frame_size + variadic.def.?.slotcount < 64);

    const fiber = fibers.new(variadic, 32, argc, &args).?;
    gc_alloc.gcroot(wrap.fromFiber(fiber));
    defer _ = gc_alloc.gcunroot(wrap.fromFiber(fiber));

    // `JANET_FRAME_SIZE + argc == 32 == the capacity asked for`, so the stack
    // was doubled to 64 before the arguments were written.
    assert(fiber.*.capacity == 64);
}

/// A fiber built by `janet_fiber` is left with its first frame pushed and
/// marked as an entrance frame, and -- under the event loop -- with no
/// supervisor.
fn aFiberIsReadyToRun(binary: *types.JanetFunction) void {
    var args = [_]types.Janet{ harness.wrapInteger(3), harness.wrapInteger(4) };
    const fiber = fibers.new(binary, 32, 2, &args).?;
    gc_alloc.gcroot(wrap.fromFiber(fiber));
    defer _ = gc_alloc.gcunroot(wrap.fromFiber(fiber));

    const frame = fiberFrame(fiber);
    assert(fiber.*.frame == frame_size);
    assert(frame.func == binary);
    assert(frame.flags == constants.JANET_STACKFRAME_ENTRANCE);
    assert(statusOf(fiber) == constants.JANET_STATUS_NEW);
    if (with_ev) assert(fiber.*.supervisor_channel == null);
}

/// A fiber allocated here has to survive the collector: marked while rooted,
/// and freed with its value stack when it is not. Nothing else in this file
/// runs the sweep over a block these functions produced.
fn aFiberSurvivesACollection(nullary: *types.JanetFunction) void {
    const fiber = fibers.new(nullary, 128, 0, null).?;
    const root = wrap.fromFiber(fiber);

    gc_alloc.gcroot(root);
    gc_mark.collect();
    assert(heap.memoryType(fiber) == constants.JANET_MEMORY_FIBER);
    assert(fiber.*.capacity == 128);
    assert(onBlocks(fiber));

    _ = gc_alloc.gcunroot(root);
    settle();
    const blocks_before = c.vm().block_count;
    gc_mark.collect();
    assert(c.vm().block_count == blocks_before);
}

// ----------------------------------------------------------------- funcdefs

/// Every field `janet_funcdef_alloc` writes.
///
/// A missing store here is only visible when the memory underneath it held
/// something else, and on the development target it never does: macOS zeroes a
/// block on free, so a recycled block reads exactly like a correctly emptied
/// one. Every field below whose right answer is zero is therefore beyond an
/// in-process contract on this platform, and the mutation sweep says so. Only
/// `max_arity`, which starts at `INT32_MAX`, is checkable here.
fn assertEmptyFuncdef(def: *types.JanetFuncDef) void {
    assert(def.environments == null);
    assert(def.constants == null);
    assert(def.bytecode == null);
    assert(def.closure_bitset == null);
    assert(def.sourcemap == null);
    assert(def.source == null);
    assert(def.name == null);
    assert(def.symbolmap == null);

    assert(def.flags == 0);
    assert(def.slotcount == 0);
    assert(def.arity == 0);
    assert(def.min_arity == 0);
    assert(def.*.max_arity == std.math.maxInt(i32));
    assert(def.constants_length == 0);
    assert(def.bytecode_length == 0);
    assert(def.environments_length == 0);
    assert(def.defs == null);
    assert(def.defs_length == 0);
    assert(def.symbolmap_length == 0);
    assert(def.named_args_count == 0);
}

/// An empty funcdef: every pointer null, every length zero, and `max_arity` at
/// `INT32_MAX` rather than at zero, because an unfinished funcdef accepts
/// anything until the assembler or the compiler narrows it.
fn aFuncdefStartsEmpty() void {
    const def = functions.defs.new();
    const root = wrap.fromFunction(functions.thunk(def));

    gc_alloc.gcroot(root);
    defer _ = gc_alloc.gcunroot(root);

    assert(heap.memoryType(def) == constants.JANET_MEMORY_FUNCDEF);
    assert(!heap.reachable(def));
    assert(onBlocks(def));
    assertEmptyFuncdef(def);
}

/// Two funcdefs are two blocks. A port that cached or reused one would pass
/// every field assertion above.
fn funcdefsAreDistinct() void {
    const a = functions.defs.new();
    const b = functions.defs.new();
    assert(a != b);
    assert(onBlocks(a));
    assert(onBlocks(b));
}

/// The funcdef block is charged at its own size.
fn aFuncdefChargesItsBlock() void {
    settle();
    const before = c.vm().next_collection;
    _ = functions.defs.new();
    const after = c.vm().next_collection;
    assert(after - before == @sizeOf(types.JanetFuncDef));
}

/// An empty funcdef is initialised well enough for the mark phase to walk it
/// and the sweep to free it. This is what the field-by-field assertions are
/// actually protecting: the collector reads every one of those pointers.
fn anEmptyFuncdefSurvivesACollection() void {
    const def = functions.defs.new();
    const root = wrap.fromFunction(functions.thunk(def));

    gc_alloc.gcroot(root);
    gc_mark.collect();
    assert(heap.memoryType(def) == constants.JANET_MEMORY_FUNCDEF);
    assert(def.*.max_arity == std.math.maxInt(i32));

    _ = gc_alloc.gcunroot(root);
    settle();
    const blocks_before = c.vm().block_count;
    gc_mark.collect();
    assert(c.vm().block_count == blocks_before);
}

// ------------------------------------------------------------------- thunks

/// A thunk is a `JANET_MEMORY_FUNCTION` block wrapping one funcdef and no
/// environments, sized for exactly that.
fn aThunkWrapsTheDef() void {
    const def = functions.defs.new();
    const func = functions.thunk(def);
    const root = wrap.fromFunction(func);

    gc_alloc.gcroot(root);
    defer _ = gc_alloc.gcunroot(root);

    assert(heap.memoryType(func) == constants.JANET_MEMORY_FUNCTION);
    assert(!heap.reachable(func));
    assert(onBlocks(func));
    assert(func.*.def == def);
}

fn aThunkChargesItsBlock() void {
    const def = functions.defs.new();
    settle();
    const before = c.vm().next_collection;
    _ = functions.thunk(def);
    const after = c.vm().next_collection;
    assert(after - before == @sizeOf(types.JanetFunction));
}

/// Two thunks over one def are two functions that agree about the def.
fn thunksAreDistinct() void {
    const def = functions.defs.new();
    const a = functions.thunk(def);
    const b = functions.thunk(def);
    assert(a != b);
    assert(a.*.def == def);
    assert(b.*.def == def);
}

/// A thunk over a def that needs upvalues is refused, and refused fatally: the
/// block `janet_thunk` allocates is sized for no environments at all, so a
/// caller that got one back would read `envs[0]` off the end of a 24-byte
/// allocation. `janet_zig_fatal` aborts, and abort is what a child process can
/// report back.
///
/// `std.c.fork` rather than the runtime's own `janet_os_fork`, because the
/// point is to observe the abort rather than to exercise the process
/// subsystem — and because `os_procs` is not compiled in every configuration
/// this contract runs under.
fn aThunkRefusesUpvalues() void {
    const child = std.c.fork();
    assert(child >= 0);

    if (child == 0) {
        const def = functions.defs.new();
        def.*.environments_length = 1;
        // The abort message is the point of the exercise, not of the log.
        const null_fd = std.c.open("/dev/null", .{ .ACCMODE = .WRONLY });
        if (null_fd >= 0) _ = std.c.dup2(null_fd, 2);
        _ = functions.thunk(def);
        std.c._exit(0);
    }

    var status: c_int = 0;
    assert(std.c.waitpid(child, &status, 0) == child);
    const bits: u32 = @bitCast(status);
    assert(std.c.W.IFSIGNALED(bits));
    assert(std.c.W.TERMSIG(bits) == std.c.SIG.ABRT);
}

// --------------------------------------------------------------- pressure

/// Repeated allocation of all three kinds, with collections in between, so that
/// a block whose header or fields were written wrongly is swept rather than
/// merely inspected.
fn repeatedCycles(nullary: *types.JanetFunction) void {
    var i: i32 = 0;
    while (i < 64) : (i += 1) {
        const fiber = wrap.fromFiber(fibers.new(nullary, i, 0, null).?);
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

// -------------------------------------------------------- delayed thunks

/// `janet_thunk_delay` assembles a funcdef by hand rather than compiling one,
/// and every field it sets is one the interpreter will read. The two
/// allocations are `janet_malloc` and not `janet_gcalloc` deliberately: a
/// funcdef owns its bytecode and constants outright.
///
/// The last assertion is the one that matters. Every field could be right and
/// the bytecode still be wrong -- `JOP_LOAD_CONSTANT` takes its constant index
/// from the instruction, and a zeroed second word would return an empty slot
/// instead of the value. Calling it is the only check that covers that.
fn aDelayedThunkReturnsItsValue() void {
    var x = value.fromBytes("delayed", .string);
    var out = wrap.fromNil();

    gc_alloc.gcroot(x);
    defer _ = gc_alloc.gcunroot(x);
    const f = functions.thunkDelay(x);
    gc_alloc.gcroot(wrap.fromFunction(f));
    defer _ = gc_alloc.gcunroot(wrap.fromFunction(f));

    assert(f.*.def.?.arity == 0);
    assert(f.*.def.?.min_arity == 0);
    assert(f.*.def.?.max_arity == std.math.maxInt(i32));
    assert((f.*.def.?.flags & constants.JANET_FUNCDEF_FLAG_VARARG) != 0);
    assert(f.*.def.?.slotcount == 1);
    assert(f.*.def.?.bytecode_length == 2);
    assert(f.*.def.?.constants_length == 1);
    assert(harness.equals(f.*.def.?.constants.?[0], x));
    assert(f.*.def.?.name == null);
    assert(f.*.def.?.environments_length == 0);

    assert(vm_entry.pcall(f, 0, null, &out, null) == constants.JANET_SIGNAL_OK);
    assert(harness.equals(out, x));

    // Varargs: it ignores whatever it is called with.
    assert(vm_entry.pcall(f, 1, @ptrCast(&x), &out, null) == constants.JANET_SIGNAL_OK);
    assert(harness.equals(out, x));
}

// ------------------------------------------------------------------- main

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
    if (builtin.os.tag != .windows) aThunkRefusesUpvalues();

    aDelayedThunkReturnsItsValue();

    repeatedCycles(nullary);

    std.debug.print("value alloc contract ok\n", .{});
}
