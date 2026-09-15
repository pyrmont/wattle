//! The interop proof: the `zig/*` builtins the Janet suite exercises, and the
//! `getline` replacement the client binds.
//!
//! `cli.zig` calls `setIo` before anything else, takes `lineGetterValue` for
//! the value it binds over `getline`, and calls `register` to define the
//! builtins. `test/suite-zig-interop.janet` is what calls those builtins, and
//! nothing else does. A native module author reaches the runtime through
//! `module.zig` rather than through anything here.
//!
//! Nothing here crosses a symbol table. This file compiles into the client,
//! which imports the runtime, so a cfunction here is an ordinary
//! `raise.CFunction` and a raise is a returned error. Each entry point is a
//! plain Zig function under this file's own namespace, `interop.register`,
//! rather than an exported symbol under a prefix of its own.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const access = subsystems.value.access;
const args = subsystems.args;
const arrays = subsystems.value.arrays;
const buffers = subsystems.value.buffers;
const fibers = @import("subsystems").value.fibers;
const functions = @import("subsystems").value.functions;
const gc_alloc = subsystems.gc_alloc;
const gc_mark = subsystems.gc_mark;
const raise = @import("subsystems").raise;
const registry = subsystems.registry;
const repr = @import("repr");
const signal_core = subsystems.signal;
const subsystems = @import("subsystems");
const tables = @import("subsystems").value.tables;
const value_core = subsystems.value;
const vm_entry = subsystems.vm_entry;
const vm_state = @import("subsystems").vm_state;
const wrap = subsystems.value.wrap;

// ==========================================================================
// Constants
// ==========================================================================

/// The five operations `dispatch` switches on, in the order it numbers them.
/// Each `cfunZig*` function passes an operation to `dispatchOrPanic`.
const identity_operation = 0;
const length_operation = 1;
const call_operation = 2;
const rooted_operation = 3;
const fail_operation = 4;

/// The process's `Io`, which `readline` reads standard input through.
///
/// `cli.zig`'s `main` calls `setIo` with it before anything else runs, so it
/// is `undefined` only before the client has started.
var process_io: std.Io = undefined;

// ==========================================================================
// Aliased types
// ==========================================================================

/// The type of a cfunction in this file. This is `raise.CFunction`, which
/// returns `raise.Error!Value` over Zig's own calling convention, so a
/// raise is a returned error and a caller that forgets the `try` gets a
/// compile error.
const CFunction = raise.CFunction;

// ==========================================================================
// Types
// ==========================================================================

/// A line `readline` read, as a pointer and a length.
///
/// `lineGetter` declares a line, passes it to `readline`, and frees `bytes`
/// with `std.c.free` once the buffer has taken a copy. `length` is `i32`
/// because it becomes a Janet index.
pub const WattleLine = struct {
    bytes: ?[*]u8 = null,
    length: i32 = 0,
};

// ==========================================================================
// Public functions
// ==========================================================================

/// Returns the value `cli.zig` binds over `getline`.
///
/// The result wraps `lineGetter`. This function cannot raise.
pub fn lineGetterValue() repr.Value {
    return wrap.fromCfunction(@ptrCast(&lineGetter));
}

/// Defines the five `zig/*` builtins in `env`, and returns whether that
/// raised.
///
/// `env` is the environment to define into, and `err` takes the raised payload
/// when a raise happened. Pass null to discard it.
///
/// `signal.tryInit` is what points the VM's `return_reg` at a payload, and so
/// what makes `signal.plan` choose `.raise` rather than ending the process.
/// The result is a `bool` rather than a `Signal`, because the only thing a
/// caller does with the signal is compare it against `ok`.
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

/// Stores the process's `Io` for `readline`.
///
/// `io` is the `Io` `cli.zig`'s `main` builds. `main` calls this first, before
/// any other function here runs.
pub fn setIo(io: std.Io) void {
    process_io = io;
}

// ==========================================================================
// Private functions
// ==========================================================================

/// The five `zig/*` cfunctions, one per operation.
///
/// Each checks its arity, checks any type the operation needs, and passes its
/// operation to `dispatchOrPanic`. `zig/call` and `zig/length` are the two
/// that check a type, because `dispatch` unwraps without checking.
fn cfunZigCall(argv: []repr.Value) raise.Error!repr.Value {
    try args.fixArity(@intCast(argv.len), 2);
    if (!repr.checkType(argv[0], repr.Tag.function)) {
        return args.panicType(argv[0], 0, repr.TagSet.one(.function));
    }
    return dispatchOrPanic(call_operation, argv);
}

fn cfunZigFail(argv: []repr.Value) raise.Error!repr.Value {
    try args.fixArity(@intCast(argv.len), 1);
    return dispatchOrPanic(fail_operation, argv);
}

fn cfunZigIdentity(argv: []repr.Value) raise.Error!repr.Value {
    try args.fixArity(@intCast(argv.len), 1);
    return dispatchOrPanic(identity_operation, argv);
}

fn cfunZigLength(argv: []repr.Value) raise.Error!repr.Value {
    try args.fixArity(@intCast(argv.len), 1);
    if (!repr.checkTypes(argv[0], repr.TagSet.lengthable)) {
        return args.panicType(argv[0], 0, repr.TagSet.lengthable);
    }
    return dispatchOrPanic(length_operation, argv);
}

fn cfunZigRooted(argv: []repr.Value) raise.Error!repr.Value {
    try args.fixArity(@intCast(argv.len), 0);
    return dispatchOrPanic(rooted_operation, argv);
}

/// Defines the five `zig/*` builtins, from inside `register`'s try scope.
///
/// `env` is the environment to define into. Each row is a name, a cfunction
/// and the docstring `(doc zig/...)` prints. This function raises if a
/// definition does.
///
/// The local `defs` is the table and this function is what installs it.
fn define(env: *tables.Table) raise.Error!void {
    const defs = [_]struct { name: [*:0]const u8, cfun: CFunction, doc: [*:0]const u8 }{
        .{ .name = "zig/identity", .cfun = &cfunZigIdentity, .doc = "Round-trip one Janet value through Zig." },
        .{ .name = "zig/length", .cfun = &cfunZigLength, .doc = "Read the length of a Janet collection in Zig." },
        .{ .name = "zig/call", .cfun = &cfunZigCall, .doc = "Call a Janet closure from Zig through a protected call." },
        .{ .name = "zig/rooted", .cfun = &cfunZigRooted, .doc = "Create and root a Janet value across a forced collection." },
        .{ .name = "zig/fail", .cfun = &cfunZigFail, .doc = "Raise a controlled Janet error after returning from Zig." },
    };
    for (defs) |d| {
        registry.def(env, d.name, wrap.fromCfunction(@ptrCast(d.cfun)), d.doc);
    }
}

/// Runs one operation over `argv` and writes its result to `out`.
///
/// `operation` is one of the five constants above, `argv` is the cfunction's
/// arguments, and `out` takes the result. The result is 1 on success and 0
/// when the operation refuses, in which case `out` has the value
/// `dispatchOrPanic` raises with. This function raises what `access.length`
/// raises.
///
/// Nothing here checks a type: each `cfunZig*` has already checked what its
/// own operation needs.
fn dispatch(
    operation: i32,
    argv: []const repr.Value,
    out: *repr.Value,
) raise.Error!c_int {
    switch (operation) {
        identity_operation => out.* = argv[0],
        length_operation => out.* = wrapInteger(try access.length(argv[0])),
        call_operation => {
            var fiber: ?*fibers.Fiber = null;
            const function = unwrapFunction(argv[0]);
            const resumed = vm_entry.pcall(function, argv[1..2], &fiber);
            out.* = resumed.value;
            if (resumed.signal != abi.Signal.ok) return 0;
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

/// Returns what `dispatch` produced, or raises with its refusal.
///
/// `operation` is one of the five constants above and `argv` is the
/// cfunction's arguments. This function raises when `dispatch` returns 0,
/// with the value `dispatch` wrote to `out`.
fn dispatchOrPanic(operation: i32, argv: []repr.Value) raise.Error!repr.Value {
    var result: repr.Value = undefined;
    if (try dispatch(operation, argv, &result) == 0) {
        return raise.panicv(result);
    }
    return result;
}

/// `getline`, replaced so that the client reads its own lines.
///
/// The arguments are a prompt, a buffer to fill and a third Janet ignores
/// here, all optional. The buffer is truncated and then filled with one line
/// including its newline, or left empty at end of input. This function raises
/// on a wrong argument type and returns the buffer.
fn lineGetter(argv: []repr.Value) raise.Error!repr.Value {
    try args.checkArity(@intCast(argv.len), 0, 3);
    const prompt: [*:0]const u8 = if (argv.len >= 1) try args.GetString.get(argv, 0) else "";
    const buffer = if (argv.len >= 2) try args.GetBuffer.get(argv, 1) else buffers.new(10);
    var line: WattleLine = .{ .bytes = null, .length = 0 };

    buffer.*.count = 0;
    if (readline(prompt, &line) != 0 and line.length > 0) {
        try buffers.pushBytes(buffer, line.bytes.?[0..@intCast(line.length)]);
    }
    std.c.free(line.bytes);
    return wrap.fromBuffer(buffer);
}

/// Allocates and roots a value across a forced collection, and writes it to
/// `out`.
///
/// `out` takes the rooted value, or the raised payload when `rootedProbe`
/// raises. The result is true when it raised. The rooting is dropped on both
/// arms by a `defer`.
///
/// No `volatile` local is needed: that would be about what a jump leaves
/// indeterminate, and nothing jumps.
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

/// Reads one line from standard input into `out`, after writing `prompt` to
/// standard error.
///
/// `prompt` is written first, `out` takes the line's bytes and length, and the
/// bytes are `std.heap.c_allocator`'s for the caller to free. The result is 1
/// when a line was read and 0 at end of input, on a write or read failure, on
/// an empty line, and when the length does not fit an `i32`.
fn readline(prompt: [*:0]const u8, out: *WattleLine) c_int {
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

/// The body of `makeRooted`, so that the unrooting and the scope are `defer`s
/// rather than four flags read on both arms.
///
/// `rooted` takes the value as soon as it is rooted, so `makeRooted`'s `defer`
/// drops the rooting whether or not the push raises. This function raises what
/// `arrays.push` raises.
fn rootedProbe(rooted: *?repr.Value) raise.Error!void {
    const array = arrays.new(1);
    const v = wrap.fromArray(array);
    gc_alloc.gcroot(v);
    rooted.* = v;
    try arrays.push(array, value_core.fromBytes("alive", .string));
    gc_mark.collect();
}

/// Returns a function out of a value already checked to be a function.
///
/// `value` is checked by `cfunZigCall` before `dispatch` reaches this.
fn unwrapFunction(value: repr.Value) *functions.Function {
    return wrap.toFunction(value);
}

/// Returns an integer as a value.
///
/// `value` becomes a `f64`, which is what a Janet number is. It takes and
/// returns values rather than pointers: an out-parameter would not survive an
/// ordinary Zig caller, because `&argv[0]` is `*allowzero const Value` when
/// `argv` is `[*c]`, and only a declaration as lossy as a C header's would
/// take that for a `*const Value`.
fn wrapInteger(value: i32) repr.Value {
    return wrap.fromNumber(@floatFromInt(value));
}
