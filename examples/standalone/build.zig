//! A native module built the way an outside author builds one.
//!
//! **Nothing here reaches into the runtime's build.** It depends on the `janet`
//! package, asks it for one module, and imports that module by name. There is
//! no `RuntimeGraph`, no generated configuration, no `types`, `raise`,
//! `constants` or `abstract_type` -- those are private, and a package that
//! required them would not be consumable.
//!
//! That is the whole point of this directory. `examples/numarray` proves the
//! source experience; it is built inside the runtime's own `build()` with the
//! private graph in hand, so it could keep proving that after the public
//! surface had rotted away. This one fails to configure if it has.

const std = @import("std");
const janet = @import("janet");

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
    // The runtime supplies every `janet_*` symbol at load time, so the module
    // links with them undefined. This is the one build setting a module author
    // has to know about.
    lib.linker_allow_shlib_undefined = true;
    b.installArtifact(lib);
}
