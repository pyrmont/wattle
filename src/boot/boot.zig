//! The image generator's entry point.
//!
//! `build.zig` roots an executable named `wattle-boot` at this file and runs it
//! to produce the core image. `main` initialises a runtime, runs the five
//! smoke tests in `boot_tests.zig`, builds the environment
//! `src/boot/boot.wattle` compiles against, and runs that script. The script
//! writes the image to the path `build.zig` passes after `image-out` in
//! `boot/args`.
//!
//! The image is a marshalled byte stream, and `runtime/env.zig`'s `core_image`
//! reads it back with `@embedFile`, so nothing routes those bytes through a
//! stream a host may translate.
//!
//! This file imports the runtime rather than linking it, and is the root of
//! its own module for that reason. It reaches the runtime by the name
//! `subsystems`, the way `test/` and the client do, rather than being a file
//! of it. `src/boot/` contains the bootstrap script as well, which is what
//! the directory's name is about.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");
const builtin = @import("builtin");

// ==========================================================================
// Project imports
// ==========================================================================

const arrays = subsystems.value.arrays;
const config = @import("config");
const env_core = subsystems.env;
const lifecycle = subsystems.lifecycle;
const registry = subsystems.registry;
const repr = @import("repr");
const stdio = subsystems.stdio;
const subsystems = @import("subsystems");
const tables = subsystems.value.tables;
const tests = @import("boot_tests.zig");
const value = subsystems.value;
const wrap = subsystems.value.wrap;

// ==========================================================================
// Public functions
// ==========================================================================

/// Generates the core image, and returns the bootstrap script's status.
///
/// `init` is the process's own initialisation, which supplies the arena and
/// the `Io`. The first argument after the program name is a directory to
/// change to, and the rest reach the script as `boot/args`. This function
/// prints a message and exits 1 on any failure before the script runs.
pub fn main(init: std.process.Init) !u8 {
    const allocator = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(allocator);

    _ = lifecycle.init() catch fail("Could not initialise the runtime\n", .{});

    // The five smoke tests, which run before anything is generated.
    tests.all();

    const env = env_core.coreEnv(null) catch fail("Could not build the core environment\n", .{});

    // `boot/args`, which `boot.wattle` reads.
    const arg_array = arrays.new(@intCast(arguments.len));
    for (arguments) |a| arrays.push(arg_array, value.fromBytes(a, .string)) catch
        fail("Could not build boot/args\n", .{});
    registry.def(env, "boot/args", wrap.fromArray(arg_array), "Command line arguments.");

    // The build options `boot.wattle` configures the image from. They are
    // `config` fields rather than macros: `build.zig` is the one derivation.
    const opts = tables.new(0);
    if (!config.docstrings)
        tables.put(opts, value.fromBytes("no-docstrings", .keyword), wrap.fromTrue());
    if (!config.sourcemaps)
        tables.put(opts, value.fromBytes("no-sourcemaps", .keyword), wrap.fromTrue());
    registry.def(env, "boot/config", wrap.fromTable(opts), "Boot options");

    // Without sourcemaps the script is compiled anonymously, which is what
    // leaves this machine's paths out of the generated image.
    const boot_filename: ?[*:0]const u8 =
        if (!config.sourcemaps) null else "boot.wattle";

    if (arguments.len < 2) fail("Usage: wattle-boot <directory> [...]\n", .{});
    if (changeDirectory(arguments[1].ptr) != 0)
        fail("Could not change to directory {s}\n", .{arguments[1]});

    // Zig 0.16 routes file access through an `Io`, which `std.process.Init`
    // provides. `cli.zig` takes the same `Io` and passes it to `interop.zig`.
    const source = std.Io.Dir.cwd().readFileAlloc(
        init.io,
        "src/boot/boot.wattle",
        allocator,
        .limited(1 << 24),
    ) catch fail("Could not read src/boot/boot.wattle\n", .{});

    // The result value is kept so that `reportBootFailure` can say what the
    // script failed on.
    var result = wrap.fromNil();
    const status = env_core.dobytes(env, source.ptr, @intCast(source.len), boot_filename, &result) catch
        fail("The bootstrap's own diagnostics raised\n", .{});
    if (status != 0) reportBootFailure(result);

    lifecycle.deinit();
    return std.math.cast(u8, status) orelse 1;
}

// ==========================================================================
// Private functions
// ==========================================================================

/// The C library's directory change, under the two names it has. Windows
/// spells it `_chdir` and every other host `chdir`, and `changeDirectory`
/// picks between them.
extern fn _chdir(path: [*:0]const u8) callconv(.c) c_int;
extern fn chdir(path: [*:0]const u8) callconv(.c) c_int;

/// Changes the working directory, by whichever name the target has for it.
///
/// `path` is the directory. The result is the C function's, which is 0 on
/// success.
fn changeDirectory(path: [*:0]const u8) c_int {
    return if (builtin.os.tag == .windows) _chdir(path) else chdir(path);
}

/// The C library's exit.
extern fn exit(status: c_int) callconv(.c) noreturn;

/// Prints a message to standard error and exits 1.
///
/// `message` is a format string and `args` its arguments. A message longer
/// than the buffer is printed unformatted rather than dropped.
fn fail(comptime message: []const u8, args: anytype) noreturn {
    var buffer: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, message, args) catch message;
    _ = fwrite(text.ptr, 1, text.len, stdio.err());
    exit(1);
}

/// The C library's buffered write, which `fail` and `reportBootFailure` use
/// because both run where the runtime may be the thing that failed.
extern fn fwrite(ptr: [*]const u8, size: usize, n: usize, stream: ?*anyopaque) callconv(.c) usize;

/// Prints what the bootstrap script failed on, asking nothing of the
/// machinery that may have failed.
///
/// `result` is the value the script raised with. `dobytes` has already
/// printed a message and a trace, and both come out of the fiber's frame
/// walk, so a defect in that walk, or in the collector that feeds it, loses
/// the diagnosis exactly when it is needed. A defect in the mark phase
/// produces that, and the whole symptom is this program exiting 1 in silence
/// with every contract passing.
///
/// So this reads the value directly rather than formatting it. An error is
/// usually a string or a keyword, and the type name alone is worth more than
/// nothing when it is not.
fn reportBootFailure(result: repr.Value) void {
    const tag = repr.typeOf(result);
    var buffer: [512]u8 = undefined;
    const text = switch (tag) {
        .string, .symbol => blk: {
            const bytes = wrap.toString(result);
            const len = std.mem.len(bytes);
            break :blk std.fmt.bufPrint(&buffer, "boot failed: {s}\n", .{bytes[0..@min(len, 400)]}) catch
                "boot failed, and the message could not be rendered\n";
        },
        else => std.fmt.bufPrint(&buffer, "boot failed with a {s}\n", .{@tagName(tag)}) catch
            "boot failed\n",
    };
    _ = fwrite(text.ptr, 1, text.len, stdio.err());
}
