//! A native module's own build script, of the shape an outside author
//! writes, and the executable that links the module in.
//!
//! Nothing here reaches into the runtime's build. This file depends on the
//! `wattle` package and reaches it through its two public functions:
//! `wattleModule` for the module a shared object imports, and `quickbin` for
//! an executable that carries the runtime, an image of `main.janet` and the
//! module linked statically. There is no `RuntimeGraph`, no generated
//! configuration, and no `types`, `raise`, `constants` or `abstract_type`.
//! Those are private, and a package that required them would not be
//! consumable.
//!
//! That is what this directory is for. `examples/numarray` and
//! `examples/quickbin` prove the source experience. They are built inside
//! the runtime's own `build()` with the private graph available, so they
//! could keep proving that after the public surface had stopped working.
//! This build fails to configure if it has.

const std = @import("std");
const wattle = @import("wattle");

/// Builds `greet.zig` as a shared library, and `hello` as an executable with
/// `greet.zig` linked in.
///
/// `b` is the build graph. `standardTargetOptions` and
/// `standardOptimizeOption` take the target and the optimize mode from the
/// command line, and `wattle.wattleModule` builds the `wattle` import from the
/// package dependency.
///
/// One build setting matters to a module author:
/// `linker_allow_shlib_undefined`. The module resolves no runtime symbol at
/// load time. The runtime exports no `janet_*` name, and the module reaches
/// it through the table `_wattle_init` is given. The setting lets the library
/// link with the symbols the loading process supplies left undefined, and
/// `res/check/exports.janet` measures that set.
///
/// The executable takes two instances of the dependency. `dep` is built for
/// the target and is what the executable links. `host` is built for the
/// machine running the build, because the image inside the executable is
/// made by running a client, and on a cross build the target's client does
/// not run here. `zig build test` runs the executable.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dep = b.dependency("wattle", .{ .target = target, .optimize = optimize });

    const mod = b.createModule(.{
        .root_source_file = b.path("greet.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("wattle", wattle.wattleModule(dep, target, optimize));

    const lib = b.addLibrary(.{
        .name = "greet",
        .linkage = .dynamic,
        .root_module = mod,
    });
    // The loading process supplies the symbols left undefined here.
    lib.linker_allow_shlib_undefined = true;
    b.installArtifact(lib);

    const host = b.dependency("wattle", .{ .target = b.graph.host, .optimize = .Debug });
    const exe = wattle.quickbin(dep, host, .{
        .name = "hello",
        .source = b.path("main.wattle"),
        .natives = &.{
            .{ .name = "greet", .root = b.path("greet.zig") },
        },
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);

    // `(type (greet/hello))` is the abstract type's name, which only the
    // linked-in module can have supplied.
    const run = b.addRunArtifact(exe);
    run.expectStdOutEqual("standalone/greeting\n");
    run.expectExitCode(0);
    const test_step = b.step("test", "Run the executable and check its output");
    test_step.dependOn(&run.step);
}
