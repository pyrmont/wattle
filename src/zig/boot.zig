//! The image generator's entry point.
//!
//! It initialises a runtime, runs the five smoke tests, builds the environment
//! `src/boot/boot.janet` compiles against, and hands that script the core
//! image to emit on stdout. `build.zig` captures the output as
//! `janet-image.c`, which is the one generated C file this tree still produces
//! and the reason `janet-image.o` is in the archive.
//!
//! This was `src/boot/boot.c` until Phase 10 Part 18, and it was the last
//! `main` in C anywhere under `src/`. It lives beside `cli.zig` rather than in
//! `src/boot/` because a module's imports resolve beside its root, and both
//! `abi.zig` and the subsystems are here; `src/boot/` holds the bootstrap
//! *script*, which is what its name was always about.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi.zig");
const c = abi.c;
const tests = @import("boot_tests.zig");
const stdio = @import("subsystems/stdio.zig");

extern fn chdir(path: [*:0]const u8) callconv(.c) c_int;
extern fn _chdir(path: [*:0]const u8) callconv(.c) c_int;

fn changeDirectory(path: [*:0]const u8) c_int {
    return if (builtin.os.tag == .windows) _chdir(path) else chdir(path);
}

fn fail(comptime message: []const u8, args: anytype) noreturn {
    var buffer: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, message, args) catch message;
    _ = fwrite(text.ptr, 1, text.len, stdio.err());
    c.exit(1);
}

extern fn fwrite(ptr: [*]const u8, size: usize, n: usize, stream: ?*anyopaque) callconv(.c) usize;

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(allocator);

    _ = c.janet_init();

    // The five smoke tests, which run before anything is generated.
    tests.all();

    const env = c.janet_core_env(null);

    // `boot/args`, which `boot.janet` reads.
    const arg_array = c.janet_array(@intCast(arguments.len));
    for (arguments) |a| c.janet_array_push(arg_array, c.janet_cstringv(a.ptr));
    c.janet_def(env, "boot/args", c.janet_wrap_array(arg_array), "Command line arguments.");

    // The options `janetconf.h` sets, so that `boot.janet` can configure the
    // image. `@hasDecl` is the Zig spelling of the `#ifdef` the C used, over
    // the same generated header.
    const opts = c.janet_table(0);
    if (@hasDecl(c, "JANET_NO_DOCSTRINGS"))
        c.janet_table_put(opts, c.janet_ckeywordv("no-docstrings"), c.janet_wrap_true());
    if (@hasDecl(c, "JANET_NO_SOURCEMAPS"))
        c.janet_table_put(opts, c.janet_ckeywordv("no-sourcemaps"), c.janet_wrap_true());
    c.janet_def(env, "boot/config", c.janet_wrap_table(opts), "Boot options");

    // Without sourcemaps the script is compiled anonymously, which is what
    // keeps this machine's paths out of the generated image.
    const boot_filename: [*c]const u8 =
        if (@hasDecl(c, "JANET_NO_SOURCEMAPS")) null else "boot.janet";

    if (arguments.len < 2) fail("Usage: janet-boot <directory> [...]\n", .{});
    if (changeDirectory(arguments[1].ptr) != 0)
        fail("Could not change to directory {s}\n", .{arguments[1]});

    // Zig 0.16 routes file access through an `Io`, which `std.process.Init`
    // hands us. `cli.zig` already takes the same one and gives it to
    // `runtime.zig`.
    const source = std.Io.Dir.cwd().readFileAlloc(
        init.io,
        "src/boot/boot.janet",
        allocator,
        .limited(1 << 24),
    ) catch fail("Could not read src/boot/boot.janet\n", .{});

    const status = c.janet_dobytes(env, source.ptr, @intCast(source.len), boot_filename, null);

    c.janet_deinit();
    return std.math.cast(u8, status) orelse 1;
}
