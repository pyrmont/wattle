//! The `wattle` client: the environment the command line runs in.
//!
//! `build.zig` roots an executable named `wattle` at this file. `main` gives
//! `interop.zig` the process's `Io`, and `runRaising` builds the environment,
//! resolves `cli-main` and runs it on a fiber under the event loop.
//!
//! This file imports the runtime rather than linking it. There is no C API for
//! it to be an embedder of, so the client is an ordinary Zig program that
//! `@import`s the runtime, writes `try` at a raise, and uses a
//! `raise.CFunction` rather than a function pointer across a compilation
//! boundary. It is the root of its own module and reaches the runtime by the
//! name `subsystems`, so it is still a separate compilation: a native module
//! resolves into the client's symbol table rather than the library's.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const arrays = subsystems.value.arrays;
const env_core = subsystems.env;
const fibers = subsystems.value.fibers;
const gc_alloc = subsystems.gc_alloc;
const interop = @import("interop.zig");
const lifecycle = subsystems.lifecycle;
const raise = @import("subsystems").raise;
const registry = subsystems.registry;
const repr = @import("repr");
const subsystems = @import("subsystems");
const symbols = subsystems.value.symbols;
const tables = subsystems.value.tables;
const value = subsystems.value;
const wrap = subsystems.value.wrap;

// ==========================================================================
// Public functions
// ==========================================================================

/// Runs the client, and returns the process's exit status.
///
/// `minimal` is the arguments and the environment as the host gave them. The
/// full `std.process.Init` would have the standard library parse the
/// environment before `main` runs, and that parse asserts every entry has a
/// name and an `=`, which a host does not promise. The runtime reads the
/// environment itself, as `os/environ` does, so the `Io` built here is given
/// none. It reaches `interop.zig` before anything else, because the line
/// getter reads through it. The result is 1 when the argument vector is empty
/// and when the status does not fit a `u8`.
pub fn main(minimal: std.process.Init.Minimal) !u8 {
    var threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{ .argv0 = .init(minimal.args) });
    defer threaded.deinit();
    interop.setIo(threaded.io());
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const arguments = try minimal.args.toSlice(arena.allocator());
    if (arguments.len == 0) return 1;
    return std.math.cast(u8, run(arguments)) orelse 1;
}

// ==========================================================================
// Private functions
// ==========================================================================

/// Runs the client and turns a raise that reached the top into a status of 1.
///
/// `arguments` is the process's argument vector, the program name first.
/// `runRaising` does the work; this is the one place a raise becomes an exit
/// status.
fn run(arguments: []const [:0]const u8) c_int {
    return runRaising(arguments) catch 1;
}

/// Builds the environment the CLI runs in, resolves `cli-main` and runs it on
/// a fiber.
///
/// `arguments` is the process's argument vector, the program name first. The
/// environment replaces `getline` with `interop.lineGetterValue`, gains the
/// bindings `interop.register` defines, and binds the program name under
/// `executable` and the rest of the arguments as an array.
///
/// This function raises if the core environment or the argument array cannot
/// be built. It returns 1 if the runtime does not start, if a binding fails to
/// register, or if `cli-main` is unbound; otherwise the result is the event
/// loop's.
fn runRaising(arguments: []const [:0]const u8) raise.Error!c_int {
    if (try lifecycle.init() != 0) return 1;
    defer lifecycle.deinit();

    const replacements = tables.new(0);
    tables.put(replacements, value.fromBytes("getline", .symbol), interop.lineGetterValue());
    const env = try env_core.coreEnv(replacements);

    var err: repr.Value = wrap.fromNil();
    if (interop.register(env, &err)) return 1;

    const args = arrays.new(@intCast(arguments.len));
    for (arguments[1..]) |argument| try arrays.push(args, value.fromBytes(argument, .string));
    tables.put(env, value.fromBytes("executable", .keyword), value.fromBytes(arguments[0], .string));

    const cli_main = registry.resolve(env, symbols.csymbol("cli-main"));
    if (cli_main.type == .none) return 1;
    const main_function = cli_main.value;

    var main_args = [_]repr.Value{wrap.fromArray(args)};
    // `fibers.new` returns `error.Arity` when the callee rejects the
    // arguments. `cli-main` takes one, and the core image is what guarantees
    // it, so the `catch` is a claim about the image rather than about this
    // call.
    const fiber = fibers.new(wrap.toFunction(main_function), 64, &main_args) catch unreachable;
    gc_alloc.gcroot(wrap.fromFiber(fiber));
    fiber.env = env;
    return env_core.loopFiber(fiber);
}
