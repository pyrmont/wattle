//! Phase 3's interop proof: the `zig/*` builtins a native module author
//! reaches Janet through, and the `getline` replacement the client binds.
//!
//! **The CLI left in Phase 12 increment 6h.** `janet_zig_cli_run` lived below
//! the proof from Phase 2 to here, and it is what gave this file its name in
//! reverse: `cli.zig` was fifteen lines that marshalled argv into C pointers
//! and called the export. It is `cli.zig`'s `run` now, an ordinary Zig
//! function, and the marshalling went with the ABI that needed it.
//!
//! **Nothing here is published as a C symbol any more.** The nine
//! `janet_zig_*` exports were `src/zig/interop_bridge.c`'s interface when the
//! bridge was C; every one of them had caller and callee inside this file or
//! one import away, so each is a plain Zig function with the module's own name
//! for a namespace -- `interop.register`, not `janet_zig_interop_register`.
//! `interop.h` keeps `JanetZigLine` alone, for the oracle that compares it.

const std = @import("std");
const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");

const identity_operation = 0;
const length_operation = 1;
const call_operation = 2;
const rooted_operation = 3;
const fail_operation = 4;

var process_io: std.Io = undefined;

pub fn setIo(io: std.Io) void {
    process_io = io;
}

fn readline(prompt: [*:0]const u8, out: *types.JanetZigLine) c_int {
    std.Io.File.stderr().writeStreamingAll(process_io, std.mem.span(prompt)) catch return 0;

    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(std.heap.c_allocator);

    while (true) {
        var byte: [1]u8 = undefined;
        const count = std.Io.File.stdin().readStreaming(process_io, &.{byte[0..]}) catch return 0;
        if (count == 0) break;
        line.append(std.heap.c_allocator, byte[0]) catch return 0;
        if (byte[0] == '\n') break;
    }

    if (line.items.len == 0) return 0;
    const owned = line.toOwnedSlice(std.heap.c_allocator) catch return 0;
    out.bytes = owned.ptr;
    out.length = std.math.cast(i32, owned.len) orelse {
        std.heap.c_allocator.free(owned);
        return 0;
    };
    return 1;
}

fn dispatch(
    operation: i32,
    argv: []const types.Janet,
    out: *types.Janet,
) c_int {
    _ = @as(i32, @intCast(argv.len));
    switch (operation) {
        identity_operation => out.* = argv[0],
        // This answers 0 or 1 rather than an error union, and since
        // increment 6h that is a fact about `janet_length` rather than about
        // this function: everything the arms call is reached through the C
        // ABI, which reports a raise instead of returning one. So the check
        // stays where the report is read, and `dispatchOrPanic` turns a
        // refusal into `janet_panicv` -- the same answer the jump used to
        // give.
        length_operation => {
            const n = c.janet_length(argv[0]);
            if (janet_zig_c_raise_take() != 0) return 0;
            out.* = wrapInteger(n);
        },
        call_operation => {
            var fiber: ?*types.JanetFiber = null;
            const function = unwrapFunction(argv[0]);
            const signal = c.janet_pcall(function, 1, argv[1..].ptr, out, &fiber);
            if (signal != constants.JANET_SIGNAL_OK) return 0;
        },
        rooted_operation => {
            if (makeRooted(out) != constants.JANET_SIGNAL_OK) return 0;
        },
        fail_operation => {
            out.* = argv[0];
            return 0;
        },
        else => return 0,
    }
    return 1;
}

// ==========================================================================
// The interop cfunctions
//
// Phase 10 Part 17g. These five and the line getter were C bodies in
// `src/zig/interop_bridge.c` until a cfunction stopped being a C function.
// They are here rather than there for the reason `raise.CFunction`'s comment
// gives: the type returns `error{JanetSignal}!Janet` with Zig's own calling
// convention, so no C body can have it and no C caller can invoke one.
//
// **This object is not the runtime's**, so it cannot import `raise` -- the
// client is its own compilation and `raise.zig` reaches `cabi` by module name.
// The type is therefore spelled out below rather than imported, and that is
// worth being explicit about: what joins this object to the runtime is now
// Zig's `.auto` calling convention rather than C's. It is deterministic for a
// given compiler version and target, which is what makes the link work, and it
// is not a documented ABI, which is what decision 2 means by `janet.h` ceasing
// to be a native-module interface. `src/zig/native_module.zig` is in the same
// position and says so once, here.
// ==========================================================================

/// `raise.CFunction`, spelled out. See the note above.
const CFunction = *const fn ([]types.Janet) error{JanetSignal}!types.Janet;

/// `JANET_CFUNCTION_ALIGN`'s maximum, as `corefn.alignment` computes it.
const alignment = 16;

/// `raise.crossing`, spelled out. This object is not the runtime's module, so
/// it cannot import `raise`; the note on `CFunction` above has the reason.
extern fn janet_zig_c_raise_take() callconv(.c) c_int;

inline fn crossing(value: anytype) error{JanetSignal}!@TypeOf(value) {
    if (janet_zig_c_raise_take() != 0) return error.JanetSignal;
    return value;
}

/// Ask the dispatcher for an answer, or turn its refusal into a raise.
///
/// The raise is `janet_panicv`, which since the hinge reports rather than
/// jumps, so this returns an error like everything else. It was a plain
/// `c.Janet` while the abi was `JANET_NO_RETURN`: the `try` below was
/// unreachable and Zig never checked it against this signature.
fn dispatchOrPanic(operation: i32, argv: []types.Janet) error{JanetSignal}!types.Janet {
    var result: types.Janet = undefined;
    if (dispatch(operation, argv, &result) == 0) {
        try crossing(c.janet_panicv(result));
    }
    return result;
}

fn zigIdentity(argv: []types.Janet) align(alignment) error{JanetSignal}!types.Janet {
    try crossing(c.janet_fixarity(@as(i32, @intCast(argv.len)), 1));
    return dispatchOrPanic(identity_operation, argv);
}

fn zigLength(argv: []types.Janet) align(alignment) error{JanetSignal}!types.Janet {
    try crossing(c.janet_fixarity(@as(i32, @intCast(argv.len)), 1));
    if (c.janet_checktypes(argv[0], constants.JANET_TFLAG_LENGTHABLE) == 0) {
        try crossing(c.janet_panic_type(argv[0], 0, constants.JANET_TFLAG_LENGTHABLE));
    }
    return dispatchOrPanic(length_operation, argv);
}

fn zigCall(argv: []types.Janet) align(alignment) error{JanetSignal}!types.Janet {
    try crossing(c.janet_fixarity(@as(i32, @intCast(argv.len)), 2));
    if (c.janet_checktype(argv[0], constants.JANET_FUNCTION) == 0) {
        try crossing(c.janet_panic_type(argv[0], 0, constants.JANET_TFLAG_FUNCTION));
    }
    return dispatchOrPanic(call_operation, argv);
}

fn zigRooted(argv: []types.Janet) align(alignment) error{JanetSignal}!types.Janet {
    try crossing(c.janet_fixarity(@as(i32, @intCast(argv.len)), 0));
    return dispatchOrPanic(rooted_operation, argv);
}

fn zigFail(argv: []types.Janet) align(alignment) error{JanetSignal}!types.Janet {
    try crossing(c.janet_fixarity(@as(i32, @intCast(argv.len)), 1));
    return dispatchOrPanic(fail_operation, argv);
}

/// `getline`, replaced so that the Zig client reads its own lines.
fn lineGetter(argv: []types.Janet) align(alignment) error{JanetSignal}!types.Janet {
    try crossing(c.janet_arity(@as(i32, @intCast(argv.len)), 0, 3));
    const prompt: [*:0]const u8 = if (@as(i32, @intCast(argv.len)) >= 1) @ptrCast(try crossing(c.janet_getstring(argv.ptr, 0))) else "";
    const buffer = if (@as(i32, @intCast(argv.len)) >= 2) try crossing(c.janet_getbuffer(argv.ptr, 1)) else c.janet_buffer(10);
    var line: types.JanetZigLine = .{ .bytes = null, .length = 0 };

    buffer.*.count = 0;
    if (readline(prompt, &line) != 0 and line.length > 0) {
        try crossing(c.janet_buffer_push_bytes(buffer, line.bytes.?, line.length));
    }
    std.c.free(line.bytes);
    return c.janet_wrap_buffer(buffer);
}

/// The value `cli.run` binds over `getline`.
pub fn lineGetterValue() types.Janet {
    return c.janet_wrap_cfunction(@ptrCast(&lineGetter));
}

/// Define the five `zig/*` builtins, from inside `register`'s try scope.
///
/// `defs` is what the C name camelCases onto and it shadows the local below,
/// which is rule 29's population (d) met at the one name this increment had to
/// choose. The local is the table and the function is what installs it.
fn define(env: *types.JanetTable) void {
    const defs = [_]struct { name: [*:0]const u8, cfun: CFunction, doc: [*:0]const u8 }{
        .{ .name = "zig/identity", .cfun = &zigIdentity, .doc = "Round-trip one Janet value through Zig." },
        .{ .name = "zig/length", .cfun = &zigLength, .doc = "Read the length of a Janet collection in Zig." },
        .{ .name = "zig/call", .cfun = &zigCall, .doc = "Call a Janet closure from Zig through janet_pcall." },
        .{ .name = "zig/rooted", .cfun = &zigRooted, .doc = "Create and root a Janet value across a forced collection." },
        .{ .name = "zig/fail", .cfun = &zigFail, .doc = "Raise a controlled Janet error after returning from Zig." },
    };
    for (defs) |d| {
        c.janet_def(env, d.name, c.janet_wrap_cfunction(@ptrCast(d.cfun)), d.doc);
    }
}

// ---------------------------------------------- what the C bridge was for
//
// Everything below was `src/zig/interop_bridge.c`, the last `.c` file under
// `src/`. It survived from Phase 2 to Phase 10 Part 18 on two reasons that had
// both expired: `janet_wrap_integer` is a macro a Zig caller could not use,
// which four subsystems now write out in three lines; and a protected scope was
// a `setjmp`, which the hinge replaced with `janet_try_init` and a report.
//
// The three below the try scope are the ones `port/STRUCTURE.md` recorded as
// dead and increment 6h found live: `dispatch`, a dozen lines above them,
// calls all three, and it had been calling them through the C ABI because
// that is what the bridge left behind.

/// Run `define` inside a protected scope and report what it raised.
///
/// `janet_try_init` is what points `janet_vm.return_reg` at a payload, and
/// therefore what makes `janet_signal_plan` answer `RAISE` rather than ending
/// the process. That was true when this was a `setjmp` and it is what remains
/// true now that the raise arrives as a report instead of a jump.
pub fn register(env: *types.JanetTable, err: ?*types.Janet) types.JanetSignal {
    var state: types.JanetTryState = undefined;
    var signal: types.JanetSignal = constants.JANET_SIGNAL_OK;
    c.janet_try_init(&state);
    c.janet_zig_c_raise_clear();
    define(env);
    if (c.janet_zig_c_raise_take() != 0) signal = c.vm().pending_signal;
    if (signal != constants.JANET_SIGNAL_OK) {
        if (err) |slot| slot.* = state.payload;
    }
    c.janet_restore(&state);
    return signal;
}

/// The interop test's rooted-value probe: allocate an array, root it, push
/// through a collection, and hand it back.
///
/// The C carried a comment about `volatile` locals that no longer applies, and
/// the reason it no longer applies is the whole of Phase 10: a `longjmp` left
/// a local written inside the scope indeterminate, and nothing jumps past this
/// frame any more.
fn makeRooted(out: *types.Janet) types.JanetSignal {
    var state: types.JanetTryState = undefined;
    var rooted = false;
    var value = c.janet_wrap_nil();
    var signal: types.JanetSignal = constants.JANET_SIGNAL_OK;

    c.janet_try_init(&state);
    c.janet_zig_c_raise_clear();
    const array = c.janet_array(1);
    if (c.janet_zig_c_raise_take() == 0) {
        value = c.janet_wrap_array(array);
        _ = c.janet_gcroot(value);
        rooted = true;
        c.janet_array_push(array, c.janet_wrap_string(c.janet_cstring("alive")));
        c.janet_collect();
    }
    if (c.janet_zig_c_raise_take() != 0) {
        signal = c.vm().pending_signal;
        out.* = state.payload;
    } else {
        out.* = value;
    }
    if (rooted) _ = c.janet_gcunroot(value);
    c.janet_restore(&state);
    return signal;
}

/// `janet_wrap_integer`, written out: `janet.h` declares it beside its macro
/// and `wrap.c` defined it only for the two nanbox layouts. Four subsystems
/// carry the same three lines.
///
/// **The out-parameter went with the ABI in increment 6h**, and so did the
/// pointer `unwrapFunction` took below. Both shapes were the C bridge's --
/// this file's own comment said as much about the first -- and neither
/// survived being asked for by an ordinary Zig caller: `&argv[0]` is
/// `*allowzero const Janet`, because `argv` is `[*c]`, and only a declaration
/// as lossy as the header's would take it for a `*const Janet`. That is
/// increment 5h's population meeting a caller, three sites after 5d's twelve.
fn wrapInteger(value: i32) types.Janet {
    return c.janet_wrap_number(@floatFromInt(value));
}

fn unwrapFunction(value: types.Janet) *types.JanetFunction {
    return c.janet_unwrap_function(value);
}
