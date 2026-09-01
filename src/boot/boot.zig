//! The image generator's entry point.
//!
//! It initialises a runtime, runs the five smoke tests, builds the environment
//! `src/boot/boot.janet` compiles against, and hands that script the core
//! image to write out. The script `spit`s it to the path `build.zig` names in
//! `boot/args` as `image-out`.
//!
//! The image is a marshalled byte stream and `core_env.zig` reaches it with
//! `@embedFile`, so nothing routes those bytes through a stream a host may
//! translate.
//!
//! **It imports the runtime rather than linking it**, which is why it lives
//! here rather than under `src/zig/`: a module's root directory owns every
//! file beneath it, and two modules cannot claim the same one. `src/boot/`
//! holds the bootstrap script too, which is what its name is about.

const std = @import("std");
const builtin = @import("builtin");
const repr = @import("repr");
const subsystems = @import("subsystems");
const tests = @import("boot_tests.zig");
const stdio = subsystems.stdio;
const config = @import("config");

const value = subsystems.value;
const arrays = subsystems.value.arrays;
const tables = subsystems.value.tables;
const wrap = subsystems.value.wrap;
const env_core = subsystems.env;
const lifecycle = subsystems.lifecycle;
const registry = subsystems.registry;

extern fn chdir(path: [*:0]const u8) callconv(.c) c_int;
extern fn _chdir(path: [*:0]const u8) callconv(.c) c_int;

fn changeDirectory(path: [*:0]const u8) c_int {
    return if (builtin.os.tag == .windows) _chdir(path) else chdir(path);
}

/// Say what the bootstrap failed on, without asking anything of the machinery
/// that may have failed.
///
/// `dobytes` has already printed a message and a trace, and both come out of
/// the fiber's frame walk -- so a defect in that walk, or in the collector
/// that feeds it, loses the diagnosis exactly when it is needed. A defect in
/// the mark phase has produced exactly that: the entire symptom was this
/// program exiting 1 in silence, with all 65 contracts passing.
///
/// So this reads the value directly rather than formatting it: an error is a
/// string or a keyword nine times in ten, and the type name alone is worth
/// more than nothing when it is not.
fn reportBootFailure(result: repr.Value) void {
    const tag = repr.typeOf(result);
    var buffer: [512]u8 = undefined;
    const text = switch (tag) {
        .string, .symbol, .keyword => blk: {
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

fn fail(comptime message: []const u8, args: anytype) noreturn {
    var buffer: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, message, args) catch message;
    _ = fwrite(text.ptr, 1, text.len, stdio.err());
    exit(1);
}

extern fn fwrite(ptr: [*]const u8, size: usize, n: usize, stream: ?*anyopaque) callconv(.c) usize;
extern fn exit(status: c_int) callconv(.c) noreturn;

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(allocator);

    _ = lifecycle.init() catch fail("Could not initialise the runtime\n", .{});

    // The five smoke tests, which run before anything is generated.
    tests.all();

    const env = env_core.coreEnv(null) catch fail("Could not build the core environment\n", .{});

    // `boot/args`, which `boot.janet` reads.
    const arg_array = arrays.new(@intCast(arguments.len));
    for (arguments) |a| arrays.push(arg_array, value.fromBytes(a, .string)) catch
        fail("Could not build boot/args\n", .{});
    registry.def(env, "boot/args", wrap.fromArray(arg_array), "Command line arguments.");

    // The build options `boot.janet` configures the image from. They are
    // `config` fields rather than macros: `build.zig` is the one derivation.
    const opts = tables.new(0);
    if (!config.docstrings)
        tables.put(opts, value.fromBytes("no-docstrings", .keyword), wrap.fromTrue());
    if (!config.sourcemaps)
        tables.put(opts, value.fromBytes("no-sourcemaps", .keyword), wrap.fromTrue());
    registry.def(env, "boot/config", wrap.fromTable(opts), "Boot options");

    // Without sourcemaps the script is compiled anonymously, which is what
    // keeps this machine's paths out of the generated image.
    const boot_filename: ?[*:0]const u8 =
        if (!config.sourcemaps) null else "boot.janet";

    if (arguments.len < 2) fail("Usage: janet-boot <directory> [...]\n", .{});
    if (changeDirectory(arguments[1].ptr) != 0)
        fail("Could not change to directory {s}\n", .{arguments[1]});

    // Zig 0.16 routes file access through an `Io`, which `std.process.Init`
    // hands us. `cli.zig` already takes the same one and gives it to
    // `interop.zig`.
    const source = std.Io.Dir.cwd().readFileAlloc(
        init.io,
        "src/boot/boot.janet",
        allocator,
        .limited(1 << 24),
    ) catch fail("Could not read src/boot/boot.janet\n", .{});

    // The result value, so that a failure says *what* failed.
    //
    // `dobytes` already prints a message and a trace, but both come out of the
    // fiber's frame walk -- so a defect in that walk, or in the collector that
    // feeds it, loses the diagnosis exactly when it is needed. That is not
    // hypothetical: a defect in the mark phase has produced exactly that, and
    // the whole symptom was this program exiting 1 in silence, with every
    // contract passing. One `%v` of the value costs nothing and does not depend on a
    // single frame being walkable.
    var result = wrap.fromNil();
    const status = env_core.dobytes(env, source.ptr, @intCast(source.len), boot_filename, &result) catch
        fail("The bootstrap's own diagnostics raised\n", .{});
    if (status != 0) reportBootFailure(result);

    lifecycle.deinit();
    return std.math.cast(u8, status) orelse 1;
}
