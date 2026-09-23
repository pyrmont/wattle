//! The `quickbin` client: a Janet program as one executable.
//!
//! `build.zig`'s `quickbin` roots an executable at this file with two imports
//! it generates: `quickbin_image`, the image of the program, and
//! `quickbin_natives`, the native modules linked into the executable. Each
//! native is a separate object whose `module.entry` exports
//! `_wattle_init_<name>` and `_wattle_mod_config_<name>`, and
//! `quickbin_natives` names those symbols with `@extern`.
//!
//! `runRaising` builds the environment as `cli.zig` does and calls
//! `run-image` on a fiber with the image, the argument vector and one loader
//! nfunction per native. The program runs as `wattle -i` runs an image file,
//! with the program name in place of the image path, and the exit status is
//! the event loop's.
//!
//! Nothing is loaded with `dlopen`, so the executable publishes no symbols
//! and on a musl target links statically.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const args_core = subsystems.args;
const arrays = subsystems.value.arrays;
const capi = subsystems.capi;
const env_core = subsystems.env;
const fibers = subsystems.value.fibers;
const gc_alloc = subsystems.gc_alloc;
const interop = @import("interop.zig");
const lifecycle = subsystems.lifecycle;
const natives = @import("quickbin_natives").natives;
const pp_format = subsystems.pp_format;
const raise = @import("subsystems").raise;
const registry = subsystems.registry;
const repr = @import("repr");
const subsystems = @import("subsystems");
const symbols = subsystems.value.symbols;
const tables = subsystems.value.tables;
const value = subsystems.value;
const vm_state = subsystems.vm_state;
const wrap = subsystems.value.wrap;

// ==========================================================================
// Constants
// ==========================================================================

/// The image of the program, as `wattle -c` wrote it.
const image = @embedFile("quickbin_image");

// ==========================================================================
// Types
// ==========================================================================

/// The loader nfunction for `natives[index]`.
///
/// The nfunction takes no arguments. It refuses the module if its
/// `_wattle_mod_config` report differs from this build's, runs its
/// `_wattle_init` into a new table, sets `:native` to the module's name and
/// returns the table, as `native` does for a module it opens.
fn Loader(comptime index: usize) type {
    return struct {
        fn load(argv: []repr.Value) raise.Error!repr.Value {
            try args_core.fixarity(argv, 0);
            const native = natives[index];
            if (env_core.checkModuleConfig(@ptrCast(native.config))) |refusal| {
                return pp_format.panicf("could not load native %s: %S", .{ native.name.ptr, refusal });
            }
            const env = tables.new(0);
            // Rooted against a collection triggered from inside the module's
            // entry point, as `native` roots it.
            try fibers.push(vm_state.currentFiber(), wrap.fromTable(env));
            const init: env_core.ModuleEntry = @ptrCast(native.init);
            try raise.fromAbi(init.?(@ptrCast(env), &capi.table));
            tables.put(env, value.fromBytes("native", .keyword), value.fromBytes(native.name, .string));
            return wrap.fromTable(env);
        }
    };
}

// ==========================================================================
// Public functions
// ==========================================================================

/// Runs the program, and returns the process's exit status.
///
/// `minimal` is the arguments and the environment as the host gave them;
/// `cli.zig`'s `main` has the reason the full `std.process.Init` is not used.
/// The result is 1 when the argument vector is empty and when the status does
/// not fit a `u8`.
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

/// Runs the program and turns a raise that reached the top into a status of
/// 1.
///
/// `arguments` is the process's argument vector, the program name first.
fn run(arguments: []const [:0]const u8) c_int {
    return runRaising(arguments) catch 1;
}

/// Builds the environment, resolves `run-image` and runs it on a fiber.
///
/// `arguments` is the process's argument vector, the program name first. The
/// environment is the one `cli.zig` builds. `run-image` is called with the
/// image, every argument including the program name, and a table from each
/// native's name to its loader.
///
/// This function raises if the core environment or the argument array cannot
/// be built. It returns 1 if the runtime does not start, if a binding fails to
/// register, or if `run-image` is unbound; otherwise the result is the event
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
    for (arguments) |argument| try arrays.push(args, value.fromBytes(argument, .string));
    tables.put(env, value.fromBytes("executable", .keyword), value.fromBytes(arguments[0], .string));

    const loaders = tables.new(@intCast(natives.len));
    inline for (0..natives.len) |index| {
        tables.put(
            loaders,
            value.fromBytes(natives[index].name, .string),
            wrap.fromNfunction(raise.stored(&Loader(index).load)),
        );
    }

    const run_image = registry.resolve(env, symbols.csymbol("run-image"));
    if (run_image.type == .none) return 1;

    var run_args = [_]repr.Value{
        value.fromBytes(image, .string),
        wrap.fromArray(args),
        wrap.fromTable(loaders),
    };
    // `run-image` takes two to three arguments, and the core image is what
    // guarantees it, so the `catch` is a claim about the image rather than
    // about this call.
    const fiber = fibers.new(wrap.toFunction(run_image.value), 64, &run_args) catch unreachable;
    gc_alloc.gcroot(wrap.fromFiber(fiber));
    fiber.env = env;
    return env_core.loopFiber(fiber);
}
