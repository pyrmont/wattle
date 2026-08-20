const std = @import("std");
const abi = @import("abi.zig");
const c = abi.c;

const identity_operation = 0;
const length_operation = 1;
const call_operation = 2;
const rooted_operation = 3;
const fail_operation = 4;

var process_io: std.Io = undefined;

pub fn setIo(io: std.Io) void {
    process_io = io;
}

export fn janet_zig_readline(prompt: [*:0]const u8, out: *c.JanetZigLine) callconv(.c) c_int {
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

export fn janet_zig_dispatch(
    operation: i32,
    argc: i32,
    argv: [*c]const c.Janet,
    out: *c.Janet,
) callconv(.c) c_int {
    _ = argc;
    switch (operation) {
        identity_operation => out.* = argv[0],
        // `janet_dispatch` is a plain C-ABI function and cannot return an
        // error, so a raise from `janet_length` is reported to *its* caller as
        // a refusal. The C bridge turns that into `janet_panicv`, which is the
        // same answer the jump used to give.
        length_operation => {
            const n = c.janet_length(argv[0]);
            if (janet_zig_c_raise_take() != 0) return 0;
            c.janet_zig_wrap_integer(n, out);
        },
        call_operation => {
            var fiber: ?*c.JanetFiber = null;
            const function = c.janet_zig_unwrap_function(&argv[0]);
            const signal = c.janet_pcall(function, 1, argv + 1, out, &fiber);
            if (signal != c.JANET_SIGNAL_OK) return 0;
        },
        rooted_operation => {
            if (c.janet_zig_make_rooted(out) != c.JANET_SIGNAL_OK) return 0;
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
// client is its own compilation and `raise.zig` reaches `abi` by module name.
// The type is therefore spelled out below rather than imported, and that is
// worth being explicit about: what joins this object to the runtime is now
// Zig's `.auto` calling convention rather than C's. It is deterministic for a
// given compiler version and target, which is what makes the link work, and it
// is not a documented ABI, which is what decision 2 means by `janet.h` ceasing
// to be a native-module interface. `src/zig/native_module.zig` is in the same
// position and says so once, here.
// ==========================================================================

/// `raise.CFunction`, spelled out. See the note above.
const CFunction = *const fn (i32, [*c]c.Janet) error{JanetSignal}!c.Janet;

/// `JANET_CFUNCTION_ALIGN`'s maximum, as `corefn.alignment` computes it.
const alignment = 16;

/// `raise.crossing`, spelled out. This object is not the runtime's module, so
/// it cannot import `raise`; the note on `CFunction` above has the reason.
extern fn janet_zig_c_raise_take() callconv(.c) c_int;

inline fn crossing(value: anytype) error{JanetSignal}!@TypeOf(value) {
    if (janet_zig_c_raise_take() != 0) return error.JanetSignal;
    return value;
}

/// Ask the Zig half for an answer, or turn its refusal into a raise.
///
/// The raise is `janet_panicv`, which since the hinge reports rather than
/// jumps, so this returns an error like everything else. It was a plain
/// `c.Janet` while the face was `JANET_NO_RETURN`: the `try` below was
/// unreachable and Zig never checked it against this signature.
fn dispatchOrPanic(operation: i32, argc: i32, argv: [*c]c.Janet) error{JanetSignal}!c.Janet {
    var result: c.Janet = undefined;
    if (janet_zig_dispatch(operation, argc, argv, &result) == 0) {
        try crossing(c.janet_panicv(result));
    }
    return result;
}

fn zigIdentity(argc: i32, argv: [*c]c.Janet) align(alignment) error{JanetSignal}!c.Janet {
    try crossing(c.janet_fixarity(argc, 1));
    return dispatchOrPanic(identity_operation, argc, argv);
}

fn zigLength(argc: i32, argv: [*c]c.Janet) align(alignment) error{JanetSignal}!c.Janet {
    try crossing(c.janet_fixarity(argc, 1));
    if (c.janet_checktypes(argv[0], c.JANET_TFLAG_LENGTHABLE) == 0) {
        try crossing(c.janet_panic_type(argv[0], 0, c.JANET_TFLAG_LENGTHABLE));
    }
    return dispatchOrPanic(length_operation, argc, argv);
}

fn zigCall(argc: i32, argv: [*c]c.Janet) align(alignment) error{JanetSignal}!c.Janet {
    try crossing(c.janet_fixarity(argc, 2));
    if (c.janet_checktype(argv[0], c.JANET_FUNCTION) == 0) {
        try crossing(c.janet_panic_type(argv[0], 0, c.JANET_TFLAG_FUNCTION));
    }
    return dispatchOrPanic(call_operation, argc, argv);
}

fn zigRooted(argc: i32, argv: [*c]c.Janet) align(alignment) error{JanetSignal}!c.Janet {
    try crossing(c.janet_fixarity(argc, 0));
    return dispatchOrPanic(rooted_operation, argc, argv);
}

fn zigFail(argc: i32, argv: [*c]c.Janet) align(alignment) error{JanetSignal}!c.Janet {
    try crossing(c.janet_fixarity(argc, 1));
    return dispatchOrPanic(fail_operation, argc, argv);
}

/// `getline`, replaced so that the Zig client reads its own lines.
fn lineGetter(argc: i32, argv: [*c]c.Janet) align(alignment) error{JanetSignal}!c.Janet {
    try crossing(c.janet_arity(argc, 0, 3));
    const prompt: [*c]const u8 = if (argc >= 1) @ptrCast(try crossing(c.janet_getstring(argv, 0))) else "";
    const buffer = if (argc >= 2) try crossing(c.janet_getbuffer(argv, 1)) else c.janet_buffer(10);
    var line: c.JanetZigLine = .{ .bytes = null, .length = 0 };

    buffer.*.count = 0;
    if (janet_zig_readline(prompt, &line) != 0 and line.length > 0) {
        try crossing(c.janet_buffer_push_bytes(buffer, line.bytes, line.length));
    }
    std.c.free(line.bytes);
    return c.janet_wrap_buffer(buffer);
}

/// The value `janet_zig_cli_run` binds over `getline`.
export fn janet_zig_line_getter_value() callconv(.c) c.Janet {
    return c.janet_wrap_cfunction(@ptrCast(&lineGetter));
}

/// The five `zig/*` definitions, called from inside the C bridge's try scope.
export fn janet_zig_interop_defs(env: *c.JanetTable) callconv(.c) void {
    const defs = [_]struct { name: [*c]const u8, cfun: CFunction, doc: [*c]const u8 }{
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

// ------------------------------------------------------- the CLI, and the end
// ------------------------------------------------------- of C in `src/`

// Everything below was `src/zig/interop_bridge.c`, the last `.c` file under
// `src/`. It survived from Phase 2 to Phase 10 Part 18 on two reasons that had
// both expired: `janet_wrap_integer` is a macro a Zig caller could not use,
// which four subsystems now write out in three lines; and a protected scope was
// a `setjmp`, which the hinge replaced with `janet_try_init` and a report.

/// `janet_zig_cli_run`. Build the environment the CLI runs in, resolve
/// `cli-main`, and hand it a fiber.
pub export fn janet_zig_cli_run(argc: i32, argv: [*c]const [*c]const u8) callconv(.c) c_int {
    if (c.janet_init() != 0) return 1;
    defer c.janet_deinit();

    const replacements = c.janet_table(0);
    c.janet_table_put(replacements, c.janet_csymbolv("getline"), janet_zig_line_getter_value());
    const env = c.janet_core_env(replacements);

    var err: c.Janet = c.janet_wrap_nil();
    if (janet_zig_interop_register(env, &err) != c.JANET_SIGNAL_OK) return 1;

    const args = c.janet_array(argc);
    var i: i32 = 1;
    while (i < argc) : (i += 1) c.janet_array_push(args, c.janet_cstringv(argv[@intCast(i)]));
    c.janet_table_put(env, c.janet_ckeywordv("executable"), c.janet_cstringv(argv[0]));

    var main_function: c.Janet = c.janet_wrap_nil();
    if (c.janet_resolve(env, c.janet_csymbol("cli-main"), &main_function) == c.JANET_BINDING_NONE)
        return 1;

    var main_args = [_]c.Janet{c.janet_wrap_array(args)};
    const fiber = c.janet_fiber(c.janet_unwrap_function(main_function), 64, 1, &main_args);
    _ = c.janet_gcroot(c.janet_wrap_fiber(fiber));
    fiber.*.env = env;
    return c.janet_loop_fiber(fiber);
}

/// Run `janet_zig_interop_defs` inside a protected scope and report what it
/// raised.
///
/// `janet_try_init` is what points `janet_vm.return_reg` at a payload, and
/// therefore what makes `janet_signal_plan` answer `RAISE` rather than ending
/// the process. That was true when this was a `setjmp` and it is what remains
/// true now that the raise arrives as a report instead of a jump.
pub export fn janet_zig_interop_register(env: *c.JanetTable, err: ?*c.Janet) callconv(.c) c.JanetSignal {
    var state: c.JanetTryState = undefined;
    var signal: c.JanetSignal = c.JANET_SIGNAL_OK;
    c.janet_try_init(&state);
    c.janet_zig_c_raise_clear();
    janet_zig_interop_defs(env);
    if (c.janet_zig_c_raise_take() != 0) signal = c.janet_vm.pending_signal;
    if (signal != c.JANET_SIGNAL_OK) {
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
pub export fn janet_zig_make_rooted(out: *c.Janet) callconv(.c) c.JanetSignal {
    var state: c.JanetTryState = undefined;
    var rooted = false;
    var value = c.janet_wrap_nil();
    var signal: c.JanetSignal = c.JANET_SIGNAL_OK;

    c.janet_try_init(&state);
    c.janet_zig_c_raise_clear();
    const array = c.janet_array(1);
    if (c.janet_zig_c_raise_take() == 0) {
        value = c.janet_wrap_array(array);
        _ = c.janet_gcroot(value);
        rooted = true;
        c.janet_array_push(array, c.janet_cstringv("alive"));
        c.janet_collect();
    }
    if (c.janet_zig_c_raise_take() != 0) {
        signal = c.janet_vm.pending_signal;
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
/// carry the same three lines, and this out-parameter shape is what the C
/// bridge existed to provide.
pub export fn janet_zig_wrap_integer(value: i32, out: *c.Janet) callconv(.c) void {
    out.* = c.janet_wrap_number(@floatFromInt(value));
}

pub export fn janet_zig_unwrap_function(value: *const c.Janet) callconv(.c) [*c]c.JanetFunction {
    return c.janet_unwrap_function(value.*);
}
