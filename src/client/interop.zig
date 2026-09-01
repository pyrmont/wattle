//! The interop proof: the `zig/*` builtins a native module author reaches
//! Janet through, and the `getline` replacement the client binds.
//!
//! **Nothing here crosses a symbol table.** It compiles into the client, which
//! imports the runtime, so a cfunction here is an ordinary `raise.CFunction`
//! and a raise is a returned error. Each entry point is a plain Zig function
//! under this file's own namespace -- `interop.register`, not
//! `janet_zig_interop_register`.

const std = @import("std");
const repr = @import("repr");
const raise = @import("subsystems").raise;
const corefn = @import("subsystems").corefn;
const subsystems = @import("subsystems");
const abi = @import("abi");
const vm_state = @import("subsystems").vm_state;
const functions = @import("subsystems").value.functions;
const fibers = @import("subsystems").value.fibers;
const tables = @import("subsystems").value.tables;

const args = subsystems.args;
const arrays = subsystems.value.arrays;
const buffers = subsystems.value.buffers;
const access = subsystems.value.access;
const wrap = subsystems.value.wrap;
const gc_alloc = subsystems.gc_alloc;
const gc_mark = subsystems.gc_mark;
const registry = subsystems.registry;
const signal_core = subsystems.signal;
const value_core = subsystems.value;
const vm_entry = subsystems.vm_entry;

const identity_operation = 0;
const length_operation = 1;
const call_operation = 2;
const rooted_operation = 3;
const fail_operation = 4;

pub const JanetZigLine = struct {
    bytes: ?[*]u8 = null,
    length: i32 = 0,
};

var process_io: std.Io = undefined;

pub fn setIo(io: std.Io) void {
    process_io = io;
}

fn readline(prompt: [*:0]const u8, out: *JanetZigLine) c_int {
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
    argv: []const repr.Value,
    out: *repr.Value,
) raise.Raising(c_int) {
    switch (operation) {
        identity_operation => out.* = argv[0],
        length_operation => out.* = wrapInteger(try access.length(argv[0])),
        call_operation => {
            var fiber: ?*fibers.Fiber = null;
            const function = unwrapFunction(argv[0]);
            const signal = vm_entry.pcall(function, 1, argv[1..].ptr, out, &fiber);
            if (signal != abi.Signal.ok) return 0;
        },
        rooted_operation => {
            if (makeRooted(out)) return 0;
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
// These five and the line getter are ordinary `raise.CFunction`s: the type
// returns `raise.Raising(Value)` over Zig's own calling convention, so a raise
// is a returned error and a caller that forgets to `try` one is a compile
// error.
// ==========================================================================

const CFunction = raise.CFunction;

/// `JANET_CFUNCTION_ALIGN`'s maximum.
const alignment = corefn.alignment;

/// Ask the dispatcher for an answer, or turn its refusal into a raise.
fn dispatchOrPanic(operation: i32, argv: []repr.Value) raise.Raising(repr.Value) {
    var result: repr.Value = undefined;
    if (try dispatch(operation, argv, &result) == 0) {
        return raise.panicv(result);
    }
    return result;
}

fn cfunZigIdentity(argv: []repr.Value) align(alignment) raise.Raising(repr.Value) {
    try args.fixArity(@intCast(argv.len), 1);
    return dispatchOrPanic(identity_operation, argv);
}

fn cfunZigLength(argv: []repr.Value) align(alignment) raise.Raising(repr.Value) {
    try args.fixArity(@intCast(argv.len), 1);
    if (!repr.checkTypes(argv[0], repr.TagSet.lengthable)) {
        return args.panicType(argv[0], 0, repr.TagSet.lengthable);
    }
    return dispatchOrPanic(length_operation, argv);
}

fn cfunZigCall(argv: []repr.Value) align(alignment) raise.Raising(repr.Value) {
    try args.fixArity(@intCast(argv.len), 2);
    if (!repr.checkType(argv[0], repr.Tag.function)) {
        return args.panicType(argv[0], 0, repr.TagSet.one(.function));
    }
    return dispatchOrPanic(call_operation, argv);
}

fn cfunZigRooted(argv: []repr.Value) align(alignment) raise.Raising(repr.Value) {
    try args.fixArity(@intCast(argv.len), 0);
    return dispatchOrPanic(rooted_operation, argv);
}

fn cfunZigFail(argv: []repr.Value) align(alignment) raise.Raising(repr.Value) {
    try args.fixArity(@intCast(argv.len), 1);
    return dispatchOrPanic(fail_operation, argv);
}

/// `getline`, replaced so that the Zig client reads its own lines.
fn lineGetter(argv: []repr.Value) align(alignment) raise.Raising(repr.Value) {
    try args.checkArity(@intCast(argv.len), 0, 3);
    const prompt: [*:0]const u8 = if (argv.len >= 1) try args.GetString.get(argv, 0) else "";
    const buffer = if (argv.len >= 2) try args.GetBuffer.get(argv, 1) else buffers.new(10);
    var line: JanetZigLine = .{ .bytes = null, .length = 0 };

    buffer.*.count = 0;
    if (readline(prompt, &line) != 0 and line.length > 0) {
        try buffers.pushBytes(buffer, line.bytes.?[0..@intCast(line.length)]);
    }
    std.c.free(line.bytes);
    return wrap.fromBuffer(buffer);
}

/// The value `cli.run` binds over `getline`.
pub fn lineGetterValue() repr.Value {
    return wrap.fromCfunction(@ptrCast(&lineGetter));
}

/// Define the five `zig/*` builtins, from inside `register`'s try scope.
///
/// `defs` is what the C name camelCases onto and it shadows the local below.
/// The local is the table and the function is what installs it.
fn define(env: *tables.Table) raise.Raising(void) {
    const defs = [_]struct { name: [*:0]const u8, cfun: CFunction, doc: [*:0]const u8 }{
        .{ .name = "zig/identity", .cfun = &cfunZigIdentity, .doc = "Round-trip one Janet value through Zig." },
        .{ .name = "zig/length", .cfun = &cfunZigLength, .doc = "Read the length of a Janet collection in Zig." },
        .{ .name = "zig/call", .cfun = &cfunZigCall, .doc = "Call a Janet closure from Zig through janet_pcall." },
        .{ .name = "zig/rooted", .cfun = &cfunZigRooted, .doc = "Create and root a Janet value across a forced collection." },
        .{ .name = "zig/fail", .cfun = &cfunZigFail, .doc = "Raise a controlled Janet error after returning from Zig." },
    };
    for (defs) |d| {
        registry.def(env, d.name, wrap.fromCfunction(@ptrCast(d.cfun)), d.doc);
    }
}

// ---------------------------------------------- what the C bridge was for
//
// Everything below was the last `.c` file under `src/`. It survived on two
// reasons that have both expired: `janet_wrap_integer` is a macro a Zig caller
// could not use, which four subsystems now write out in three lines; and a
// protected scope was a `setjmp`, which is `tryInit` and a report now.

/// Run `define` inside a protected scope and say whether it raised.
///
/// `tryInit` is what points the VM's `return_reg` at a payload, and therefore
/// what makes `signalPlan` answer `RAISE` rather than ending the process.
///
/// **It answers a bool rather than a `Signal`.** The signal came from the VM's
/// `pending_signal` and no caller ever read it -- `cli.zig` compared it against
/// `JANET_SIGNAL_OK` and nothing else -- so the only thing that field carried
/// here was the answer this returns. Reading it was also the last thing in the
/// tree that needed the VM state to be a linker symbol.
pub fn register(env: *tables.Table, err: ?*repr.Value) bool {
    var state: vm_state.TryState = undefined;
    signal_core.tryInit(&state);
    defer signal_core.restore(&state);
    define(env) catch {
        if (err) |slot| slot.* = state.payload;
        return true;
    };
    return false;
}

/// The interop test's rooted-value probe: allocate an array, root it, push
/// through a collection, and hand it back.
///
/// Janet carries a comment about `volatile` locals that does not apply here:
/// it is about what a jump left indeterminate, and nothing jumps.
fn makeRooted(out: *repr.Value) bool {
    var state: vm_state.TryState = undefined;
    var rooted: ?repr.Value = null;

    signal_core.tryInit(&state);
    defer signal_core.restore(&state);
    defer if (rooted) |v| {
        _ = gc_alloc.gcunroot(v);
    };

    rootedProbe(&rooted) catch {
        out.* = state.payload;
        return true;
    };
    out.* = rooted.?;
    return false;
}

/// The body of `makeRooted`, so that the unrooting and the scope are `defer`s
/// rather than four flags read on both arms.
fn rootedProbe(rooted: *?repr.Value) raise.Raising(void) {
    const array = arrays.new(1);
    const v = wrap.fromArray(array);
    gc_alloc.gcroot(v);
    rooted.* = v;
    try arrays.push(array, value_core.fromBytes("alive", .string));
    gc_mark.collect();
}

/// `janet_wrap_integer`, written out: Janet declares it beside its macro and
/// defines the symbol only for the two nanbox layouts. Four subsystems carry
/// the same three lines.
///
/// **It takes and returns values rather than pointers.** The out-parameter
/// shape here was the C bridge's, and it did not survive being asked for by an
/// ordinary Zig caller: `&argv[0]` is `*allowzero const Value` when `argv` is
/// `[*c]`, and only a declaration as lossy as a C header's would take that for
/// a `*const Value`.
fn wrapInteger(value: i32) repr.Value {
    return wrap.fromNumber(@floatFromInt(value));
}

fn unwrapFunction(value: repr.Value) *functions.Function {
    return wrap.toFunction(value);
}
