//! What a C contract needs now that a cfunction is not a C function.
//!
//! Phase 10 Part 17g gave `JanetCFunction` the type `raise.CFunction`: it
//! returns `error{JanetSignal}!Janet` and is called with Zig's own calling
//! convention. Two things a contract used to do freely stop working, and this
//! object is the smallest thing that restores both without turning
//! `test/*.c` into Zig:
//!
//!  - **Calling one.** `janet_unwrap_cfunction(fun)(argc, argv)` appears in
//!    eight contracts. `callCFunction` below invokes it with the right
//!    convention and turns a returned raise into the jump those files already
//!    assert against with `janet_try`.
//!  - **Defining one.** Twenty-nine contracts define a probe cfunction in C
//!    and hand it to the runtime -- as a registration row, an abstract type's
//!    method, or a wrapped value the interpreter will call. `cfunction` below
//!    adapts one: it hands back a Zig-ABI cfunction that forwards to the C
//!    body, taken from a fixed pool so that the same input always yields the
//!    same pointer and identity assertions still hold.
//!
//! It is linked into the contract binary and into nothing else, so no
//! test-only symbol reaches the runtime. Part 17h is expected to add the
//! protected-call shim here, for the same reason and in the same place.
//!
//! The adapter is not a general mechanism and must not become one. A C body
//! still raises by jumping, so `cfunction`'s thunk is a Zig frame a `longjmp`
//! crosses; it holds nothing, which is the same argument every
//! jump-transparent file in the tree rests on, and Part 17i removes the jump.

const std = @import("std");
const abi = @import("abi");
const c = abi.c;

/// `raise.CFunction`. Spelled out because this object is not the runtime's
/// module; `src/zig/interop.zig` has the note on what that costs.
const CFunction = *const fn (i32, [*c]c.Janet) error{JanetSignal}!c.Janet;

/// What `janet.h` used to mean by `JanetCFunction`, and what a contract's own
/// probe still is.
const CCFunction = *const fn (i32, [*c]c.Janet) callconv(.c) c.Janet;

const alignment = 16;

/// Invoke a cfunction from C, reporting a raise the way a C-ABI face does.
///
/// It delivered the raise as a jump until the hinge, and that stopped being
/// safe the moment a contract opened its scope with `janet_try_init` rather
/// than `janet_try`: `janet_try_init` points `janet_vm.signal_buf` at a
/// `jmp_buf` nothing has `setjmp`'d, so the jump lands in whichever dead frame
/// set the buffer last. `test/filewatch_core.c` found it -- an assertion in
/// `test_flag_table_halves` jumped back into `test_flag_faults` and failed
/// there, naming the wrong message and the wrong line.
///
/// Reporting is what every other C-ABI face does since the hinge, so a
/// contract reads a raise the one way: `janet_contract_arm` before, and
/// `janet_contract_raised` after. A contract that forgets is caught at the
/// next scope boundary by the assertions in `janet_try_init` and
/// `janet_restore`, rather than by a wild jump.
export fn janet_contract_call_cfunction(
    fun: c.JanetCFunction,
    argc: i32,
    argv: [*c]c.Janet,
) callconv(.c) c.Janet {
    const cfun: CFunction = @ptrCast(fun.?);
    return cfun(argc, argv) catch {
        c.janet_zig_c_raise_record();
        return c.janet_wrap_nil();
    };
}

// ------------------------------------------------ coming back out of C

/// A C body's result, or the raise it reported on the way.
///
/// This is `raise.crossing` under another name -- the runtime's own module is
/// not this one, and `src/zig/interop.zig` records what that costs. Every
/// thunk below wraps a C function the runtime will call with Zig's convention,
/// so each is a place a raise leaves C and has to become an error again. A
/// thunk that skipped this would hand the runtime a blank value with the
/// report still standing, and the assertions in `janet_try_init` and
/// `janet_restore` would name the next scope rather than this one.
inline fn crossing(value: anytype) error{JanetSignal}!@TypeOf(value) {
    if (c.janet_zig_c_raise_take() != 0) return error.JanetSignal;
    return value;
}

// ---------------------------------------------------------- the adapter pool

/// One slot per adapted C cfunction. Sized by measurement: the contracts
/// define twenty-nine between them and no single run needs them all, so this
/// is comfortable rather than tight. Overflowing it is a hard failure rather
/// than a silent wrap, because the alternative is a probe that answers as
/// some other probe.
const pool_size = 64;

var pool: [pool_size]?CCFunction = @splat(null);
var pool_used: usize = 0;

fn Thunk(comptime index: usize) type {
    return struct {
        fn call(argc: i32, argv: [*c]c.Janet) align(alignment) error{JanetSignal}!c.Janet {
            return crossing(pool[index].?(argc, argv));
        }
    };
}

const thunks: [pool_size]CFunction = blk: {
    var list: [pool_size]CFunction = undefined;
    for (&list, 0..) |*slot, i| slot.* = &Thunk(i).call;
    break :blk list;
};

/// Adapt a contract's own C cfunction into one the runtime can call.
///
/// Idempotent by identity: asking twice for the same C function returns the
/// same adapted pointer, so `janet_unwrap_cfunction(x) == janet_contract_cfunction(probe)`
/// means what the old `== probe` meant.
export fn janet_contract_cfunction(fun: CCFunction) callconv(.c) c.JanetCFunction {
    // Idempotent in both directions: asking again for a C function already in
    // the pool answers its slot, and handing back a thunk answers the thunk.
    // `test/value_access.c` registers one table twice, and a second adaptation
    // that wrapped the wrapper would break the identity the first established.
    for (thunks) |thunk| {
        if (@intFromPtr(thunk) == @intFromPtr(fun)) return @ptrCast(fun);
    }
    for (pool[0..pool_used], 0..) |slot, i| {
        if (slot == fun) return @ptrCast(thunks[i]);
    }
    if (pool_used == pool_size) {
        std.debug.panic("test/support.zig: the cfunction adapter pool is full", .{});
    }
    pool[pool_used] = fun;
    pool_used += 1;
    return @ptrCast(thunks[pool_used - 1]);
}

/// Adapt every row of a `JanetReg` table in place, before registering it.
export fn janet_contract_adapt_regs(table: [*c]c.JanetReg) callconv(.c) void {
    var i: usize = 0;
    while (table[i].name != null) : (i += 1) {
        if (table[i].cfun) |fun| table[i].cfun = janet_contract_cfunction(@ptrCast(fun));
    }
}

/// The same for a `JanetMethod` table.
export fn janet_contract_adapt_methods(table: [*c]c.JanetMethod) callconv(.c) void {
    var i: usize = 0;
    while (table[i].name != null) : (i += 1) {
        if (table[i].cfun) |fun| table[i].cfun = janet_contract_cfunction(@ptrCast(fun));
    }
}

// ------------------------------------------------- asserting that it raised

// Phase 10 Part 17h. A contract used to catch a raise with `janet_try`, which
// is a `setjmp`, and the exit gate forbids one anywhere in the tree. A C face
// now records the raise and returns instead of jumping, so an EXPECT_PANIC
// opens a scope with `janet_try_init` — which is `janet_try` without the jump
// — runs the expression, and asks these.
//
// `janet_try_init` is still needed and is not a formality: `janet_signal_plan`
// answers TOP_LEVEL when `return_reg` is null, and a TOP_LEVEL raise ends the
// process rather than reporting. The scope is what makes the raise reportable;
// the jump was only ever how it travelled.

/// Run a C body under a protected scope and report the signal it raised.
///
/// This was `janet_zig_ev_protect` in `src/core/ev.c` -- nine lines that were
/// the second of Phase 10's three `setjmp` sites, kept compiled under both
/// arms of the selector so that `test/ev_loop.c` could name them. The hinge
/// deleted the function along with the jump, and a contract that wants a
/// protected scope now gets one here, where every other test-only symbol
/// lives.
///
/// The scope is real and is not a formality: `janet_try_init` points
/// `janet_vm.return_reg` at `tstate.payload`, which is what makes
/// `janet_signal_plan` answer `RAISE` rather than `TOP_LEVEL`, and a
/// `TOP_LEVEL` raise ends the process instead of reporting. What is gone is
/// only the travel.
export fn janet_contract_protect(
    body: *const fn (?*anyopaque) callconv(.c) void,
    ctx: ?*anyopaque,
    payload: *c.Janet,
) callconv(.c) c.JanetSignal {
    var tstate: c.JanetTryState = undefined;
    c.janet_try_init(&tstate);
    c.janet_zig_c_raise_clear();
    body(ctx);
    var signal: c.JanetSignal = 0;
    // Before `janet_restore`, because the report is a claim about this scope
    // and the assertion there is what says so when it is not.
    if (c.janet_zig_c_raise_take() != 0) signal = c.janet_vm.pending_signal;
    c.janet_restore(&tstate);
    if (signal != 0) payload.* = tstate.payload;
    return signal;
}

/// Discard any earlier report, before a window this contract means to measure.
export fn janet_contract_arm() callconv(.c) void {
    c.janet_zig_c_raise_clear();
}

/// Whether a raise reached a C face inside the window. Clears.
export fn janet_contract_raised() callconv(.c) c_int {
    return c.janet_zig_c_raise_take();
}

/// The same question without consuming the answer, for a C body that has to
/// stop early and leave the report standing for whoever is measuring.
///
/// A contract's callback is a C function the runtime calls, so a raise inside
/// it arrives as a report rather than as the jump that used to leave the
/// function outright. `test/marsh.c`'s `probe_unmarshal` is the worked case:
/// it reads eight fields from a stream the test deliberately truncates, and
/// without a test after each read it goes on reading past the end. The thunk
/// that called it turns the standing report back into an error.
export fn janet_contract_raising() callconv(.c) c_int {
    return if (c.janet_vm.c_raised != 0) 1 else 0;
}

/// The signal the raise carried. Read after `janet_contract_raised`, which is
/// what establishes that there was one.
export fn janet_contract_signal() callconv(.c) c.JanetSignal {
    return c.janet_vm.pending_signal;
}

/// The value the raise carried. Reads through `return_reg`, where the
/// innermost scope pointed it -- the same value a `janet_try` would have left
/// in its `JanetTryState`.
export fn janet_contract_payload() callconv(.c) c.Janet {
    return if (c.janet_vm.return_reg) |reg| reg.* else c.janet_wrap_nil();
}

// ----------------------------------------------- defining an abstract type

// The same problem as `janet_contract_cfunction`, one table along. Phase 10's
// hinge typed `JanetAbstractType`'s callbacks as raising, so the runtime
// dispatches them with Zig's calling convention; a contract's abstract type is
// C and its callbacks are C functions. `janet_contract_abstract_type` adapts
// one: it hands back a Zig-typed abstract type whose raising callbacks forward
// to the C ones, from a fixed pool so that the same input always yields the
// same pointer — which matters here even more than it did for cfunctions,
// because contracts compare abstract types by address and `marsh.c` looks them
// up that way.
//
// The four callbacks that stay C -- `compare`, `hash`, `bytes`,
// `gcperthread` -- are copied straight across, because their type did not
// change.

const abstract_type = @import("abstract_type");
const AbstractType = abstract_type.AbstractType;
const CAbstract = c.JanetAbstractType;

const at_pool_size = 64;
var at_sources: [at_pool_size]?*const CAbstract = @splat(null);
var at_adapted: [at_pool_size]AbstractType = undefined;
var at_used: usize = 0;

fn AtThunks(comptime i: usize) type {
    return struct {
        fn src() *const CAbstract {
            return at_sources[i].?;
        }
        fn get(p: ?*anyopaque, key: c.Janet, out: [*c]c.Janet) error{JanetSignal}!c_int {
            return crossing(src().get.?(p, key, out));
        }
        fn put(p: ?*anyopaque, key: c.Janet, value: c.Janet) error{JanetSignal}!void {
            return crossing(src().put.?(p, key, value));
        }
        fn marshal(p: ?*anyopaque, ctx: [*c]c.JanetMarshalContext) error{JanetSignal}!void {
            return crossing(src().marshal.?(p, ctx));
        }
        fn unmarshal(ctx: [*c]c.JanetMarshalContext) error{JanetSignal}!?*anyopaque {
            return crossing(src().unmarshal.?(ctx));
        }
        fn tostring(p: ?*anyopaque, buffer: [*c]c.JanetBuffer) error{JanetSignal}!void {
            return crossing(src().tostring.?(p, buffer));
        }
        fn next(p: ?*anyopaque, key: c.Janet) error{JanetSignal}!c.Janet {
            return crossing(src().next.?(p, key));
        }
        fn call(p: ?*anyopaque, argc: i32, argv: [*c]c.Janet) error{JanetSignal}!c.Janet {
            return crossing(src().call.?(p, argc, argv));
        }
        fn length(p: ?*anyopaque, n: usize) error{JanetSignal}!usize {
            return crossing(src().length.?(p, n));
        }
    };
}

fn adapt(comptime i: usize, from: *const CAbstract) void {
    const T = AtThunks(i);
    at_adapted[i] = .{
        .name = from.name,
        // `gc` and `gcmark` are copied straight across like `compare` and
        // `hash`: the hinge typed them non-raising, so a contract's C body
        // already has exactly the signature the slot wants.
        .gc = from.gc,
        .gcmark = from.gcmark,
        .get = if (from.get != null) &T.get else null,
        .put = if (from.put != null) &T.put else null,
        .marshal = if (from.marshal != null) &T.marshal else null,
        .unmarshal = if (from.unmarshal != null) &T.unmarshal else null,
        .tostring = if (from.tostring != null) &T.tostring else null,
        .compare = from.compare,
        .hash = from.hash,
        .next = if (from.next != null) &T.next else null,
        .call = if (from.call != null) &T.call else null,
        .length = if (from.length != null) &T.length else null,
        .bytes = from.bytes,
        .gcperthread = from.gcperthread,
    };
}

/// Adapt a contract's own C abstract type. Idempotent by identity in both
/// directions, so an address comparison still means what it meant.
export fn janet_contract_abstract_type(from: *const CAbstract) callconv(.c) *const CAbstract {
    for (&at_adapted, 0..) |*a, i| {
        if (i >= at_used) break;
        if (@intFromPtr(a) == @intFromPtr(from)) return from;
    }
    for (at_sources[0..at_used], 0..) |s, i| {
        if (s == from) return @ptrCast(&at_adapted[i]);
    }
    if (at_used == at_pool_size) {
        std.debug.panic("test/support.zig: the abstract-type adapter pool is full", .{});
    }
    at_sources[at_used] = from;
    inline for (0..at_pool_size) |i| {
        if (i == at_used) adapt(i, from);
    }
    at_used += 1;
    return @ptrCast(&at_adapted[at_used - 1]);
}

// ------------------------------------- invoking an abstract type's callback

// A handful of contracts call an abstract type's callback directly, to test it
// without going through the interpreter. Since the hinge typed those callbacks
// as raising, C cannot invoke one; these are the same shim
// `janet_contract_call_cfunction` is, one per callback kind that a contract
// actually reaches. A raise arrives as the jump those files already assert on.

export fn janet_contract_at_tostring(
    at: *const AbstractType,
    p: ?*anyopaque,
    buffer: [*c]c.JanetBuffer,
) callconv(.c) void {
    at.tostring.?(p, buffer) catch c.janet_zig_c_raise_record();
}

export fn janet_contract_at_next(
    at: *const AbstractType,
    p: ?*anyopaque,
    key: c.Janet,
) callconv(.c) c.Janet {
    return at.next.?(p, key) catch {
        c.janet_zig_c_raise_record();
        return c.janet_wrap_nil();
    };
}

export fn janet_contract_at_get(
    at: *const AbstractType,
    p: ?*anyopaque,
    key: c.Janet,
    out: [*c]c.Janet,
) callconv(.c) c_int {
    return at.get.?(p, key, out) catch {
        c.janet_zig_c_raise_record();
        return 0;
    };
}

// ------------------------------------------- invoking a compiler special

// `test/specials_core.c` calls thirteen specials through
// `janetc_special(name)->compile(...)`, which the hinge retyped as raising.
// The same shim as the abstract-type ones above, for the one table that has a
// single callback. A raise arrives as a report, which is what that file's
// `EXPECT_*` macros already read.

const special = @import("special");

export fn janet_contract_special_compile(
    s: ?*const c.JanetSpecial,
    options: c.JanetFopts,
    argument_count: i32,
    arguments: [*c]const c.Janet,
) callconv(.c) c.JanetSlot {
    return special.of(s).compile.?(options, argument_count, arguments) catch {
        c.janet_zig_c_raise_record();
        return std.mem.zeroes(c.JanetSlot);
    };
}
