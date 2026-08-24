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
const abi = @import("abi");
const c = abi.c;
const harness = @import("harness.zig");

const heap = harness.heap;
const assert = std.debug.assert;

/// `JANET_EV` decides whether a fiber has the five scheduler fields, and a
/// `JANET_*` macro is not reliable through `@cImport` — so the question is put
/// to the translated type, which is where the answer actually is.
const with_ev = @hasField(c.JanetFiber, "sched_id");

const frame_size: i32 = c.JANET_FRAME_SIZE;

var test_env: *c.JanetTable = undefined;

// ----------------------------------------------------------------- helpers

/// Reach a quiet heap, so that a later collection's effects are attributable
/// to what this contract made rather than to what an earlier case left behind.
fn settle() void {
    c.janet_collect();
    c.janet_collect();
}

fn compileFunction(source: [*:0]const u8) *c.JanetFunction {
    var out = c.janet_wrap_nil();
    const status = c.janet_dostring(test_env, source, "value-alloc-test", &out);
    assert(status == 0);
    assert(harness.isType(out, c.JANET_FUNCTION));
    c.janet_gcroot(out);
    return c.janet_unwrap_function(out);
}

fn statusOf(fiber: *c.JanetFiber) i32 {
    return (fiber.flags & c.JANET_FIBER_STATUS_MASK) >> c.JANET_FIBER_STATUS_OFFSET;
}

/// `janet_fiber_frame` from `fiber.h`, which translate-c does not surface: a
/// frame lives in the four `Janet` slots immediately below the frame's base.
fn fiberFrame(fiber: *c.JanetFiber) *c.JanetStackFrame {
    return @ptrCast(@alignCast(fiber.data + @as(usize, @intCast(fiber.frame - frame_size))));
}

/// The newborn state, as `janet_fiber_reset` leaves it. Read after a rejected
/// call, where nothing has run over it.
fn assertNewborn(fiber: *c.JanetFiber, expect_stacktop: i32) void {
    assert(fiber.maxstack == c.JANET_STACK_MAX);
    assert(fiber.frame == 0);
    assert(fiber.stackstart == frame_size);
    assert(fiber.stacktop == expect_stacktop);
    assert(fiber.child == null);
    assert(fiber.env == null);
    assert(harness.isType(fiber.last_value, c.JANET_NIL));
    assert((fiber.flags & ~@as(i32, c.JANET_FIBER_STATUS_MASK)) ==
        (c.JANET_FIBER_MASK_YIELD | c.JANET_FIBER_RESUME_NO_USEVAL | c.JANET_FIBER_RESUME_NO_SKIP));
    assert(statusOf(fiber) == c.JANET_STATUS_NEW);
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
fn dirty(fiber: *c.JanetFiber, child: *c.JanetFiber, env: *c.JanetTable) void {
    fiber.maxstack = 7;
    fiber.frame = 11;
    fiber.stackstart = 13;
    fiber.stacktop = 17;
    fiber.child = child;
    fiber.env = env;
    fiber.last_value = harness.wrapInteger(23);
    fiber.flags = c.JANET_FIBER_MASK_ERROR | c.JANET_FIBER_DID_RAISE |
        (c.JANET_STATUS_ALIVE << c.JANET_FIBER_STATUS_OFFSET);
    if (with_ev) {
        fiber.sched_id = 29;
        fiber.ev_callback = null;
        fiber.ev_state = @ptrCast(fiber);
        fiber.ev_stream = null;
        fiber.supervisor_channel = @ptrCast(fiber);
    }
}

fn onBlocks(block: ?*anyopaque) bool {
    return heap.onList(c.janet_vm.blocks, block);
}

// ------------------------------------------------------------ fiber blocks

/// A fiber is a collectable block the collector is given immediately, tagged
/// `JANET_MEMORY_FIBER`, plus a plain allocation for the value stack that hangs
/// off it.
fn aFiberIsACollectableBlock(nullary: *c.JanetFunction) void {
    const fiber = c.janet_fiber(nullary, 32, 0, null);
    assert(fiber != null);
    c.janet_gcroot(c.janet_wrap_fiber(fiber));
    defer _ = c.janet_gcunroot(c.janet_wrap_fiber(fiber));

    assert(heap.memoryType(fiber) == c.JANET_MEMORY_FIBER);
    assert(!heap.reachable(fiber));
    assert(onBlocks(fiber));
    assert(fiber.*.data != null);
}

/// The 32-slot floor. A caller asking for less gets 32; a caller asking for
/// more gets what it asked for, as long as the first frame fits inside it.
fn theCapacityFloor(nullary: *c.JanetFunction) void {
    assert(c.janet_fiber(nullary, 0, 0, null).*.capacity == 32);
    assert(c.janet_fiber(nullary, 31, 0, null).*.capacity == 32);
    assert(c.janet_fiber(nullary, -4096, 0, null).*.capacity == 32);
    assert(c.janet_fiber(nullary, 4096, 0, null).*.capacity == 4096);

    // Exactly 32 is not below the floor, so it is left alone rather than
    // doubled. Only a wrong comparison would tell these two apart.
    assert(c.janet_fiber(nullary, 32, 0, null).*.capacity == 32);
}

/// A fiber costs the collector two charges: the block, billed by
/// `janet_gcalloc`, and the value stack, billed by hand. Nothing else in the
/// call allocates, so long as the callee takes no arguments and its frame fits
/// in the capacity asked for.
fn aFiberChargesBlockAndStack(nullary: *c.JanetFunction) void {
    settle();
    var before = c.janet_vm.next_collection;
    const fiber = c.janet_fiber(nullary, 1024, 0, null);
    var after = c.janet_vm.next_collection;

    assert(fiber.*.capacity == 1024);
    assert(after - before == @sizeOf(c.JanetFiber) + 1024 * @sizeOf(c.Janet));

    // And the floor is charged, not the request: 32 slots for a request of 1.
    before = c.janet_vm.next_collection;
    _ = c.janet_fiber(nullary, 1, 0, null);
    after = c.janet_vm.next_collection;
    assert(after - before == @sizeOf(c.JanetFiber) + 32 * @sizeOf(c.Janet));
}

// -------------------------------------------------------------- fiber_reset

/// A rejected arity is reported by returning null, and leaves the fiber in the
/// newborn state rather than half-built -- callers use the return value to
/// implement `janet_pcall`, not to recover a partial frame. This is also the
/// only vantage point from which `janet_fiber_reset`'s own stores are visible.
fn aRejectedResetLeavesANewborn(binary: *c.JanetFunction, nullary: *c.JanetFunction) void {
    const fiber = c.janet_fiber(nullary, 64, 0, null);
    const child = c.janet_fiber(nullary, 32, 0, null);
    const env = c.janet_table(0);
    const root = c.janet_wrap_fiber(fiber);

    c.janet_gcroot(root);
    c.janet_gcroot(c.janet_wrap_fiber(child));
    c.janet_gcroot(c.janet_wrap_table(env));
    defer {
        _ = c.janet_gcunroot(c.janet_wrap_table(env));
        _ = c.janet_gcunroot(c.janet_wrap_fiber(child));
        _ = c.janet_gcunroot(root);
    }

    dirty(fiber, child, env);
    assert(c.janet_fiber_reset(fiber, binary, 0, null) == null);
    assertNewborn(fiber, frame_size);
}

/// Recycling keeps the stack the fiber already paid for. This is the whole
/// reason `janet_fiber_reset` exists as a separate entry point, and a port that
/// cleared capacity or data would still pass everything else here.
fn aResetKeepsTheStack(binary: *c.JanetFunction, nullary: *c.JanetFunction) void {
    const fiber = c.janet_fiber(nullary, 4096, 0, null);
    const data = fiber.*.data;

    c.janet_gcroot(c.janet_wrap_fiber(fiber));
    defer _ = c.janet_gcunroot(c.janet_wrap_fiber(fiber));
    settle();
    const before = c.janet_vm.next_collection;

    assert(c.janet_fiber_reset(fiber, binary, 0, null) == null);
    assert(fiber.*.capacity == 4096);
    assert(fiber.*.data == data);
    assert(c.janet_vm.next_collection == before);
}

/// Arguments are copied into the slots above the frame base, and a null argv is
/// a request for that many nils rather than a request for nothing. Read through
/// a rejected callee so the frame machinery has not moved anything.
fn argumentsLandAboveTheFrame(binary: *c.JanetFunction, nullary: *c.JanetFunction) void {
    const fiber = c.janet_fiber(nullary, 64, 0, null);
    c.janet_gcroot(c.janet_wrap_fiber(fiber));
    defer _ = c.janet_gcunroot(c.janet_wrap_fiber(fiber));

    var args = [_]c.Janet{
        harness.wrapInteger(101),
        harness.wrapInteger(102),
        harness.wrapInteger(103),
    };

    // Three arguments to a function of two: rejected, but only after the
    // arguments have been placed.
    assert(c.janet_fiber_reset(fiber, binary, 3, &args) == null);
    assert(fiber.*.stacktop == frame_size + 3);
    assert(fiber.*.stackstart == frame_size);
    for (0..3) |i| {
        assert(c.janet_unwrap_integer(fiber.*.data[@intCast(frame_size + @as(i32, @intCast(i)))]) ==
            101 + @as(i32, @intCast(i)));
    }

    // No argv means nil, and means it for every slot.
    for (0..3) |i| {
        fiber.*.data[@intCast(frame_size + @as(i32, @intCast(i)))] = harness.wrapInteger(-1);
    }
    assert(c.janet_fiber_reset(fiber, binary, 3, null) == null);
    assert(fiber.*.stacktop == frame_size + 3);
    for (0..3) |i| {
        assert(harness.isType(fiber.*.data[@intCast(frame_size + @as(i32, @intCast(i)))], c.JANET_NIL));
    }

    // Zero arguments touch neither the stack pointer nor the slots.
    fiber.*.data[@intCast(frame_size)] = harness.wrapInteger(-7);
    assert(c.janet_fiber_reset(fiber, binary, 0, null) == null);
    assert(fiber.*.stacktop == frame_size);
    assert(c.janet_unwrap_integer(fiber.*.data[@intCast(frame_size)]) == -7);
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
fn theArgumentBlockGrowsOnEquality(variadic: *c.JanetFunction) void {
    const argc: i32 = 32 - frame_size;
    var args: [28]c.Janet = undefined;
    for (0..@intCast(argc)) |i| args[i] = harness.wrapInteger(@intCast(i));
    assert(2 * frame_size + variadic.def.*.slotcount < 64);

    const fiber = c.janet_fiber(variadic, 32, argc, &args);
    assert(fiber != null);
    c.janet_gcroot(c.janet_wrap_fiber(fiber));
    defer _ = c.janet_gcunroot(c.janet_wrap_fiber(fiber));

    // `JANET_FRAME_SIZE + argc == 32 == the capacity asked for`, so the stack
    // was doubled to 64 before the arguments were written.
    assert(fiber.*.capacity == 64);
}

/// A fiber built by `janet_fiber` is left with its first frame pushed and
/// marked as an entrance frame, and -- under the event loop -- with no
/// supervisor.
fn aFiberIsReadyToRun(binary: *c.JanetFunction) void {
    var args = [_]c.Janet{ harness.wrapInteger(3), harness.wrapInteger(4) };
    const fiber = c.janet_fiber(binary, 32, 2, &args);
    assert(fiber != null);
    c.janet_gcroot(c.janet_wrap_fiber(fiber));
    defer _ = c.janet_gcunroot(c.janet_wrap_fiber(fiber));

    const frame = fiberFrame(fiber);
    assert(fiber.*.frame == frame_size);
    assert(frame.func == binary);
    assert(frame.flags == c.JANET_STACKFRAME_ENTRANCE);
    assert(statusOf(fiber) == c.JANET_STATUS_NEW);
    if (with_ev) assert(fiber.*.supervisor_channel == null);
}

/// A fiber allocated here has to survive the collector: marked while rooted,
/// and freed with its value stack when it is not. Nothing else in this file
/// runs the sweep over a block these functions produced.
fn aFiberSurvivesACollection(nullary: *c.JanetFunction) void {
    const fiber = c.janet_fiber(nullary, 128, 0, null);
    const root = c.janet_wrap_fiber(fiber);

    c.janet_gcroot(root);
    c.janet_collect();
    assert(heap.memoryType(fiber) == c.JANET_MEMORY_FIBER);
    assert(fiber.*.capacity == 128);
    assert(onBlocks(fiber));

    _ = c.janet_gcunroot(root);
    settle();
    const blocks_before = c.janet_vm.block_count;
    c.janet_collect();
    assert(c.janet_vm.block_count == blocks_before);
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
fn assertEmptyFuncdef(def: *c.JanetFuncDef) void {
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
    const def = c.janet_funcdef_alloc();
    const root = c.janet_wrap_function(c.janet_thunk(def));

    c.janet_gcroot(root);
    defer _ = c.janet_gcunroot(root);

    assert(heap.memoryType(def) == c.JANET_MEMORY_FUNCDEF);
    assert(!heap.reachable(def));
    assert(onBlocks(def));
    assertEmptyFuncdef(def);
}

/// Two funcdefs are two blocks. A port that cached or reused one would pass
/// every field assertion above.
fn funcdefsAreDistinct() void {
    const a = c.janet_funcdef_alloc();
    const b = c.janet_funcdef_alloc();
    assert(a != b);
    assert(onBlocks(a));
    assert(onBlocks(b));
}

/// The funcdef block is charged at its own size.
fn aFuncdefChargesItsBlock() void {
    settle();
    const before = c.janet_vm.next_collection;
    _ = c.janet_funcdef_alloc();
    const after = c.janet_vm.next_collection;
    assert(after - before == @sizeOf(c.JanetFuncDef));
}

/// An empty funcdef is initialised well enough for the mark phase to walk it
/// and the sweep to free it. This is what the field-by-field assertions are
/// actually protecting: the collector reads every one of those pointers.
fn anEmptyFuncdefSurvivesACollection() void {
    const def = c.janet_funcdef_alloc();
    const root = c.janet_wrap_function(c.janet_thunk(def));

    c.janet_gcroot(root);
    c.janet_collect();
    assert(heap.memoryType(def) == c.JANET_MEMORY_FUNCDEF);
    assert(def.*.max_arity == std.math.maxInt(i32));

    _ = c.janet_gcunroot(root);
    settle();
    const blocks_before = c.janet_vm.block_count;
    c.janet_collect();
    assert(c.janet_vm.block_count == blocks_before);
}

// ------------------------------------------------------------------- thunks

/// A thunk is a `JANET_MEMORY_FUNCTION` block wrapping one funcdef and no
/// environments, sized for exactly that.
fn aThunkWrapsTheDef() void {
    const def = c.janet_funcdef_alloc();
    const func = c.janet_thunk(def);
    const root = c.janet_wrap_function(func);

    c.janet_gcroot(root);
    defer _ = c.janet_gcunroot(root);

    assert(heap.memoryType(func) == c.JANET_MEMORY_FUNCTION);
    assert(!heap.reachable(func));
    assert(onBlocks(func));
    assert(func.*.def == def);
}

fn aThunkChargesItsBlock() void {
    const def = c.janet_funcdef_alloc();
    settle();
    const before = c.janet_vm.next_collection;
    _ = c.janet_thunk(def);
    const after = c.janet_vm.next_collection;
    assert(after - before == @sizeOf(c.JanetFunction));
}

/// Two thunks over one def are two functions that agree about the def.
fn thunksAreDistinct() void {
    const def = c.janet_funcdef_alloc();
    const a = c.janet_thunk(def);
    const b = c.janet_thunk(def);
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
        const def = c.janet_funcdef_alloc();
        def.*.environments_length = 1;
        // The abort message is the point of the exercise, not of the log.
        const null_fd = std.c.open("/dev/null", .{ .ACCMODE = .WRONLY });
        if (null_fd >= 0) _ = std.c.dup2(null_fd, 2);
        _ = c.janet_thunk(def);
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
fn repeatedCycles(nullary: *c.JanetFunction) void {
    var i: i32 = 0;
    while (i < 64) : (i += 1) {
        const fiber = c.janet_wrap_fiber(c.janet_fiber(nullary, i, 0, null));
        const thunk = c.janet_wrap_function(c.janet_thunk(c.janet_funcdef_alloc()));
        c.janet_gcroot(fiber);
        c.janet_gcroot(thunk);
        c.janet_collect();
        _ = c.janet_funcdef_alloc();
        _ = c.janet_gcunroot(thunk);
        _ = c.janet_gcunroot(fiber);
        c.janet_collect();
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
    var x = c.janet_cstringv("delayed");
    var out = c.janet_wrap_nil();

    c.janet_gcroot(x);
    defer _ = c.janet_gcunroot(x);
    const f = c.janet_thunk_delay(x);
    c.janet_gcroot(c.janet_wrap_function(f));
    defer _ = c.janet_gcunroot(c.janet_wrap_function(f));

    assert(f.*.def.*.arity == 0);
    assert(f.*.def.*.min_arity == 0);
    assert(f.*.def.*.max_arity == std.math.maxInt(i32));
    assert((f.*.def.*.flags & c.JANET_FUNCDEF_FLAG_VARARG) != 0);
    assert(f.*.def.*.slotcount == 1);
    assert(f.*.def.*.bytecode_length == 2);
    assert(f.*.def.*.constants_length == 1);
    assert(harness.equals(f.*.def.*.constants[0], x));
    assert(f.*.def.*.name == null);
    assert(f.*.def.*.environments_length == 0);

    assert(c.janet_pcall(f, 0, null, &out, null) == c.JANET_SIGNAL_OK);
    assert(harness.equals(out, x));

    // Varargs: it ignores whatever it is called with.
    assert(c.janet_pcall(f, 1, &x, &out, null) == c.JANET_SIGNAL_OK);
    assert(harness.equals(out, x));
}

// ------------------------------------------------------------------- main

pub fn run() void {
    _ = c.janet_init();
    defer c.janet_deinit();

    test_env = c.janet_core_env(null);
    c.janet_gcroot(c.janet_wrap_table(test_env));

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
