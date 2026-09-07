//! A native module's own build script, of the shape an outside author
//! writes.
//!
//! Nothing here reaches into the runtime's build. This file depends on the
//! `janet` package, takes one module from it, and imports that module by name.
//! There is no `RuntimeGraph`, no generated configuration, and no `types`,
//! `raise`, `constants` or `abstract_type`. Those are private, and a package
//! that required them would not be consumable.
//!
//! That is what this directory is for. `examples/numarray` proves the source
//! experience. It is built inside the runtime's own `build()` with the
//! private graph available, so it could keep proving that after the public
//! surface had stopped working. This build fails to configure if it has.

const std = @import("std");
const janet = @import("janet");

/// Builds `greet.zig` as a shared library that imports the `janet` package.
///
/// `b` is the build graph. `standardTargetOptions` and
/// `standardOptimizeOption` take the target and the optimize mode from the
/// command line, and `janet.janetModule` builds the `janet` import from the
/// package dependency.
///
/// One build setting matters to a module author:
/// `linker_allow_shlib_undefined`. The module resolves no runtime symbol at
/// load time. The runtime exports no `janet_*` name, and the module reaches
/// it through the table `_janet_init` is given. The setting lets the library
/// link with the symbols the loading process supplies left undefined, and
/// `tools/check/exports.janet` measures that set.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("greet.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("janet", janet.janetModule(
        b.dependency("janet", .{ .target = target, .optimize = optimize }),
        target,
        optimize,
    ));

    const lib = b.addLibrary(.{
        .name = "greet",
        .linkage = .dynamic,
        .root_module = mod,
    });
    // The loading process supplies the symbols left undefined here.
    lib.linker_allow_shlib_undefined = true;
    b.installArtifact(lib);
}
