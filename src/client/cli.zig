//! The `janet` client: the environment the command line runs in.
//!
//! **It imports the runtime rather than linking it.** `DESIGN.md` section 11
//! is the decision: there is no C API for this to be an embedder of, so the
//! client is an ordinary Zig program that `@import`s the runtime, `try`s a
//! raise, and holds a `raise.CFunction` rather than a function pointer across
//! a compilation boundary. It is still its own compilation, because a native
//! module resolves into the client's symbol table rather than the library's.
//!
//! It is the root of its own module and reaches the runtime by the name
//! `subsystems`, so it is a separate compilation rather than a file of the
//! runtime.

const std = @import("std");
const repr = @import("repr");
const raise = @import("subsystems").raise;
const subsystems = @import("subsystems");
const interop = @import("interop.zig");

const value = subsystems.value;
const arrays = subsystems.value.arrays;
const tables = subsystems.value.tables;
const wrap = subsystems.value.wrap;
const fibers = subsystems.value.fibers;
const symbols = subsystems.value.symbols;
const env_core = subsystems.env;
const gc_alloc = subsystems.gc_alloc;
const lifecycle = subsystems.lifecycle;
const registry = subsystems.registry;

pub fn main(init: std.process.Init) !u8 {
    interop.setIo(init.io);
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len == 0) return 1;
    return std.math.cast(u8, run(arguments)) orelse 1;
}

/// Build the environment the CLI runs in, resolve `cli-main`, and hand it a
/// fiber.
fn run(arguments: []const [:0]const u8) c_int {
    return runRaising(arguments) catch 1;
}

fn runRaising(arguments: []const [:0]const u8) raise.Raising(c_int) {
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
    // `fibers.new` answers `error.Arity` when the callee rejects the arguments.
    // `cli-main` takes one, and the core image is what guarantees it, so the
    // `catch` is a claim about the image rather than about this call.
    const fiber = fibers.new(wrap.toFunction(main_function), 64, &main_args) catch unreachable;
    gc_alloc.gcroot(wrap.fromFiber(fiber));
    fiber.env = env;
    return env_core.loopFiber(fiber);
}
