const std = @import("std");

/// Janet's version, in one place.
///
/// `Config` carries these four values into the runtime, `boot_tests.zig`
/// compares the quintet and `env.zig` publishes `janet/build`, so every reader
/// resolves back to this declaration rather than to a spelling of its own.
const version = std.SemanticVersion{ .major = 1, .minor = 41, .patch = 3 };
const version_extra = "-dev";
const version_string = std.fmt.comptimePrint("{d}.{d}.{d}{s}", .{
    version.major, version.minor, version.patch, version_extra,
});
const build_name = "zig";

/// The Janet suites, and the configuration each one needs.
///
/// **A suite whose subject or whose fixtures a configuration does not compile
/// is not scheduled**, which is `test/contracts.zig`'s rule for contracts
/// applied to the other half of the test surface. A Janet file resolves its
/// bindings at *compile* time, so a suite naming a binding the build did not
/// register does not skip a case -- it refuses to load, and the whole suite is
/// lost with it.
///
/// `needs_os` is the only condition so far. `-Dreduced-os=true` registers five
/// `os` bindings and no more, and these seven suites reach past them:
/// `suite-os` is *about* the OS library, and the other six use the filesystem,
/// the environment or a subprocess to build their fixtures. Everything else
/// runs unchanged, which is 28 of the 35 -- the population this gate is worth
/// having for.
const Suite = struct {
    path: []const u8,
    needs_os: bool = false,
};

const test_suites = &[_]Suite{
    .{ .path = "test/suite-array.janet" },
    .{ .path = "test/suite-asm.janet" },
    .{ .path = "test/suite-boot.janet" },
    .{ .path = "test/suite-buffer.janet" },
    .{ .path = "test/suite-bundle.janet", .needs_os = true },
    .{ .path = "test/suite-capi.janet" },
    .{ .path = "test/suite-cfuns.janet" },
    .{ .path = "test/suite-compile.janet" },
    .{ .path = "test/suite-corelib.janet" },
    .{ .path = "test/suite-debug.janet" },
    .{ .path = "test/suite-ev.janet", .needs_os = true },
    .{ .path = "test/suite-ev2.janet", .needs_os = true },
    .{ .path = "test/suite-ffi.janet" },
    .{ .path = "test/suite-filewatch.janet", .needs_os = true },
    .{ .path = "test/suite-inttypes.janet" },
    .{ .path = "test/suite-io.janet", .needs_os = true },
    .{ .path = "test/suite-marsh.janet" },
    .{ .path = "test/suite-math.janet" },
    .{ .path = "test/suite-net.janet", .needs_os = true },
    .{ .path = "test/suite-os.janet", .needs_os = true },
    .{ .path = "test/suite-parse.janet" },
    .{ .path = "test/suite-peg.janet" },
    .{ .path = "test/suite-pp.janet" },
    .{ .path = "test/suite-specials.janet" },
    .{ .path = "test/suite-string.janet" },
    .{ .path = "test/suite-strtod.janet" },
    .{ .path = "test/suite-struct.janet" },
    .{ .path = "test/suite-symcache.janet" },
    .{ .path = "test/suite-table.janet" },
    .{ .path = "test/suite-tuple.janet" },
    .{ .path = "test/suite-unknown.janet" },
    .{ .path = "test/suite-value.janet" },
    .{ .path = "test/suite-vm.janet" },
    .{ .path = "test/suite-zig-interop.janet" },
    .{ .path = "test/regalloc-bytecode.janet" },
};

// **This file compiles no C and holds no C flags.** Neither `src/` nor `test/`
// contains a `.c`. What remains of C in this tree is four hand-written headers
// -- `src/host/janet_features.h` and the three host translations under
// `src/runtime` -- and
// libc itself, which is deliberate: "no C in the tree" and "no libc" are
// different claims, and only the first is a goal.

const BuildOptions = struct {
    /// Set only for the object set the bootstrap image generator is built
    /// from. A core cfunction table carries docstrings in the generator and not
    /// in the runtime, and `src/runtime/corefn.zig` reads it to decide.
    /// It is a field rather than a parameter because the alternative is
    /// threading a boolean through six constructors that have no other use
    /// for it.
    bootstrap: bool = false,
    install_tests: bool,
    sanitize_thread: bool,
    single_threaded: bool,
    nanbox: bool,
    nanbox_pointer_shift: ?i32,
    dynamic_modules: bool,
    docstrings: bool,
    sourcemaps: bool,
    reduced_os: bool,
    assembler: bool,
    peg: bool,
    int_types: bool,
    prf: bool,
    net: bool,
    ipv6: bool,
    ev: bool,
    processes: bool,
    umask: bool,
    realpath: bool,
    fiber_stack_shuffle: bool,
    epoll: bool,
    kqueue: bool,
    interpreter_interrupt: bool,
    ffi: bool,
    ffi_jit: bool,
    filewatch: bool,
    cryptorand: bool,
    recursion_guard: i32,
    max_proto_depth: i32,
    max_macro_expand: i32,
    stack_max: i32,
    os_name: ?[]const u8 = null,
    arch_name: ?[]const u8 = null,
};

/// Which subsystems this configuration answers in Zig.
///
/// One bool per subsystem, computed once by `zigSelection` and read **once**, by
/// `src/root.zig`, which imports the file each one selects.
///
/// One reader is the point. With two -- an import here and a guard there --
/// they are two separate lists, and a subsystem can be compiled without being
/// guarded off.
const Selection = struct {
    scratch_vector: bool,
    utilities: bool,
    registry: bool,
    regalloc: bool,
    verify: bool,
    emit_core: bool,
    disasm: bool,
    bytecode: bool,
    compiler_primitives: bool,
    parser: bool,
    specials_core: bool,
    optimize: bool,
    scan: bool,
    math_core: bool,
    int_types_core: bool,
    /// No `root.zig` import reads this one: `os.zig` guards the four
    /// `janet_os_*env*` exports on it, so a reduced-OS build exports what it
    /// always did. Same for `os_time`.
    os_environ: bool,
    os_fs: bool,
    os_time: bool,
    io: bool,
    os_process: bool,
    os: bool,
    ev: bool,
    net: bool,
    ffi_zig: bool,
    filewatch: bool,
    args: bool,
    gc_alloc: bool,
    gc_mark: bool,
    gc_sweep: bool,
    arrays: bool,
    buffers: bool,
    strings: bool,
    symbols: bool,
    tuples: bool,
    tables: bool,
    structs: bool,
    order: bool,
    access: bool,
    abstracts: bool,
    functions: bool,
    wrap: bool,
    pp: bool,
    marsh: bool,
    peg_engine: bool,
    env: bool,
    fibers: bool,
    signal: bool,
    debug: bool,
    vm: bool,
    vm_entry: bool,
    lifecycle: bool,

    /// Whether any subsystem at all is answered by Zig, computed by reflection
    /// over the fields rather than from a list.
    ///
    /// `src/runtime/fatal.zig` provides `janet_zig_out_of_memory` and
    /// `janet_zig_fatal`, and nineteen subsystems call one of them. This
    /// condition used to name the ones that did, and such a list goes stale the
    /// moment something adds a twentieth: ten of the nineteen were missing once,
    /// which nothing noticed because the default build turns every subsystem on
    /// and one of the named few was always among
    /// them. Only a build selecting a single unnamed subsystem failed to link,
    /// which is exactly what a differential test does.
    fn any(self: Selection) bool {
        inline for (@typeInfo(Selection).@"struct".fields) |field| {
            if (@field(self, field.name)) return true;
        }
        return false;
    }
};

/// The `janet` module, for a build that is not this one.
///
/// **This is the whole public build surface, and it exists because the example
/// did not prove what it looked like it proved.** `examples/numarray` imports
/// one module, which is the intended source experience -- but the module it
/// imports is constructed inside `build()` from `RuntimeGraph`, the generated
/// configuration and the private `abi`, `raise`, `constants` and
/// `abstract_type` modules. None of that is reachable from another package, so
/// "an author writes `@import("janet")`" was demonstrated only for authors
/// building inside this repository.
///
/// A dependent's `build.zig` calls this instead:
///
/// ```zig
/// const janet = @import("janet");
/// const mod = b.createModule(.{ .root_source_file = b.path("mymodule.zig"), ... });
/// mod.addImport("janet", janet.janetModule(b.dependency("janet", .{
///     .target = target,
///     .optimize = optimize,
/// }), target, optimize));
/// ```
///
/// **Two things have to match and neither is checked here.** The dependent must
/// use the same Zig version as the runtime it loads into -- a module is a
/// source dependency and Zig makes no ABI promise across versions -- and it
/// must be built with the same value representation and feature options as that
/// runtime, because `config` decides `Value`'s layout. Loading a `-Dnanbox=false`
/// module into a NaN-boxed runtime is not a link error; it is wrong values.
/// `examples/standalone` is the worked instance and `zig build standalone`
/// builds it the way an outside author would.
/// The options `build()` resolved, so `janetModule` can reuse them.
///
/// **`b.option` may be declared only once per builder.** A dependent reaches
/// `janetModule` after `b.dependency` has already run this package's
/// `build()`, which declared every one of them, so re-reading panics with
/// "Option ... declared twice". The values are identical either way; this is
/// only about who asked first. The fallback covers a caller that somehow
/// arrives before `build()` ran.
var resolved_options: ?BuildOptions = null;

pub fn janetModule(
    dep: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const b = dep.builder;
    const opts = resolved_options orelse readOptions(b);

    const config_module = makeConfigModule(b, blk: {
        var cfg = janetConfig(opts, target);
        cfg.native_module = true;
        break :blk cfg;
    });
    const repr_module = b.createModule(.{
        .root_source_file = b.path("src/api/repr.zig"),
        .target = target,
        .optimize = optimize,
    });
    repr_module.addImport("config", config_module);
    // **`abi` rather than `types`, which is the whole of what this package
    // publishes as a layout.** `src/api/abi.zig` holds what a separately
    // compiled module and the runtime must agree on -- the abstract-type
    // vtable, the registration and method rows, the abstract head and the
    // subtraction that recovers it, the signal numbering, the build config --
    // and nothing else. Handing out the whole type catalogue instead puts
    // fifty-odd declarations an author's compilation never names into the
    // author's `.so`, because they shared a file.
    const abi_module = b.createModule(.{
        .root_source_file = b.path("src/api/abi.zig"),
        .target = target,
        .optimize = optimize,
    });
    abi_module.addImport("repr", repr_module);
    const constants_module = b.createModule(.{
        .root_source_file = b.path("src/api/constants.zig"),
        .target = target,
        .optimize = optimize,
    });
    constants_module.addImport("config", config_module);
    constants_module.addImport("repr", repr_module);
    // **No `cabi`.** `crossings.zig` was split out of it so that an author's
    // `.so` would not take 163 libc declarations to obtain six, and with
    // `types` gone nothing in the author package -- `module.zig`, `raise.zig`,
    // `abstract_type.zig`, `crossings.zig` -- imports it at all. It was here
    // as an import a module whose source cannot resolve it, which is a trap
    // rather than a service.
    const janet_module = b.createModule(.{
        .root_source_file = b.path("src/module.zig"),
        .target = target,
        .optimize = optimize,
    });
    configureCModule(b, janet_module, target, opts);
    janet_module.addImport("abi", abi_module);
    janet_module.addImport("repr", repr_module);
    janet_module.addImport("constants", constants_module);
    janet_module.addImport("config", config_module);
    return janet_module;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const options = readOptions(b);
    resolved_options = options;

    // The runtime object is built below rather than here, because it
    // *contains* the core image: `core_env.zig` reaches the generated bytes
    // with `@embedFile` rather than through a linked-in object. So the
    // generator has
    // to be described first.

    // Bootstrap tools must execute on the build host even during a cross build.
    // Keep the host's architecture, OS, and ABI, but pin a baseline CPU instead
    // of the detected model. The bootstrap runs once to generate the image and
    // gains nothing from host-specific instructions, while native CPU detection
    // is a portability hazard: an emulated or unusual host can report a model
    // the code generator rejects, which fails the build before any Janet source
    // is compiled. Pinning it also keeps image generation reproducible across
    // machines of the same architecture.
    //
    // Running the generator on the host is viable because the image is
    // architecture-neutral -- a marshalled byte stream rather than anything
    // laid out for a particular machine -- and that is what makes cross
    // compiling work at all. It is evidenced rather than proved: a
    // host-generated image runs on aarch64 under the container recipe in
    // `test/README.md`, and has never been run on a 32-bit target, whose
    // binaries are deliberately not executed.
    //
    // The *OS version* is kept rather than dropped, and the reason is not
    // cosmetic. Naming the arch, the OS tag and the ABI without a
    // version resolves to `aarch64-macos-none`, and the SDK's availability
    // macros then expand differently: `<spawn.h>` drags in the mach headers,
    // translate-c demotes `mach_msg_type_descriptor_t` to an opaque type
    // because it holds a bitfield, and the `_Static_assert` on that
    // structure's size fails the translation. Only a subsystem that
    // translates a system header notices, and this is the first one that
    // does. Starting from the host's own query keeps the version and still
    // pins the CPU model, which is what this is for.
    const boot_host = blk: {
        var query = b.graph.host.query;
        query.cpu_model = .baseline;
        break :blk b.resolveTargetQuery(query);
    };
    const boot_module = b.createModule(.{
        .root_source_file = b.path("src/boot/boot.zig"),
        .target = boot_host,
        .optimize = .Debug,
    });
    configureCModule(b, boot_module, boot_host, options);
    // The bootstrap compiler is a build-time tool that runs on the host, not a
    // thing under test, and it is built for the host even when -Dtarget names
    // something else. ThreadSanitizer is dropped from it for that reason and
    // for a practical one: Zig's bundled libtsan needs macOS SDK headers it
    // cannot see, so leaving it on makes -Dsanitize-thread fail on this
    // development machine no matter which target was asked for.
    boot_module.sanitize_thread = null;
    // The generator gets the same subsystems as the runtime, built a second
    // time because they must run on the host -- see `boot_host` above -- and
    // with `bootstrap` set. `src/runtime/corefn.zig` is what reads it: a core
    // cfunction carries its docstring in the generator and not in the runtime,
    // and defines a binding where the runtime only puts a value.
    const boot_options = blk: {
        var o = options;
        o.bootstrap = true;
        break :blk o;
    };
    // The generator could not be anything but Zig: it registers the whole core
    // environment, so it needs every cfunction there is, and a cfunction is a
    // Zig function.
    //
    // It gets its own instance of the graph, built for `boot_host` and carrying
    // `bootstrap = true`, because `corefn.zig` reads that to decide which
    // registration shape to emit and the two halves of one build must not
    // disagree about it.
    const boot_graph = makeRuntimeGraph(b, boot_host, .Debug, boot_options, null);
    if (boot_graph) |g| {
        boot_module.addImport("subsystems", g.subsystems);
        boot_module.addImport("config", g.config);
        boot_module.addImport("host", g.host);
        boot_module.addImport("repr", g.repr);
        boot_module.addImport("constants", g.constants);
    }
    const boot = b.addExecutable(.{ .name = "janet-boot", .root_module = boot_module });

    // The generator writes the image to a path it is handed rather than to
    // stdout. The output is a marshalled byte stream, and a byte stream through
    // a captured stdout is one text-mode host away from a translated 0x0A.
    const generate_image = b.addRunArtifact(boot);
    generate_image.setCwd(b.path("."));
    generate_image.addArg(".");
    generate_image.addArgs(&.{ "JANET_PATH", "/usr/local/lib/janet" });
    generate_image.addArg("image-out");
    const image_source = generate_image.addOutputFileArg("janet-image.bin");
    generate_image.addFileInput(b.path("src/boot/boot.janet"));

    // The image on its own, so that a build can be asked for the generator's
    // output rather than for something linked against it. It is what a
    // reproducibility claim compares: the bytes, rather than the C an earlier
    // emitter wrapped around them.
    const image_step = b.step("image", "Generate the core image and write it to <prefix>/janet-image.bin");
    image_step.dependOn(&b.addInstallFile(image_source, "janet-image.bin").step);

    // Now the runtime object, which embeds what the generator just produced.
    const runtime_graph = makeRuntimeGraph(b, target, optimize, options, image_source);
    const zig_runtime = if (runtime_graph) |g|
        b.addObject(.{ .name = "janet-zig", .root_module = g.subsystems })
    else
        null;

    const static_module = makeRuntimeModule(b, target, optimize, options, zig_runtime);
    const static_library = b.addLibrary(.{
        .name = "janet",
        .linkage = .static,
        .version = version,
        .root_module = static_module,
    });
    // **No header is installed, and the gap is deliberate.** What a native
    // module reaches by symbol is `capi.zig`, where every published name states
    // the signature it publishes and the compiler checks it. A hand-written
    // header would declare the same surface with nothing comparing a
    // declaration to its definition, which is a weaker promise than the tree
    // keeps.
    b.installArtifact(static_library);

    const shared_module = makeRuntimeModule(b, target, optimize, options, zig_runtime);
    const shared_library = b.addLibrary(.{
        .name = "janet",
        .linkage = .dynamic,
        .version = version,
        .root_module = shared_module,
    });
    // A ThreadSanitizer build produces test binaries, not distributable
    // artifacts, and it cannot produce this one: TSan gives its thread-locals
    // the initial-exec model, and `ld.lld` rejects the resulting
    // R_AARCH64_TLSLE_ADD_TPREL_HI12 against `debug.panic_stage` with "cannot
    // be used with -shared". Clearing the flag on this module alone does not
    // help, because the subsystem objects are shared with the static library
    // and are compiled once. Nothing that TSan exists to run needs the shared
    // object -- every contract links the static library.
    if (!options.sanitize_thread) b.installArtifact(shared_library);

    // **The client imports the runtime rather than linking it.** It was an
    // embedder -- it took the object and reached `janet_init` and its
    // neighbours through the symbol table -- and `DESIGN.md` section 11 is the
    // decision that ended that: there is no C API to be an embedder of. The
    // import is what lets `cli.zig` write `try` at a raise and hold a
    // `raise.CFunction` rather than an `.auto`-convention pointer across a
    // compilation boundary.
    const client_module = b.createModule(.{
        .root_source_file = b.path("src/client/cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    configureCModule(b, client_module, target, options);
    if (runtime_graph) |g| {
        client_module.addImport("subsystems", g.subsystems);
        client_module.addImport("host", g.host);
        client_module.addImport("abi", g.abi);
        client_module.addImport("repr", g.repr);
        client_module.addImport("constants", g.constants);
        client_module.addImport("config", g.config);
    }
    const client = b.addExecutable(.{ .name = "janet", .root_module = client_module });
    if (target.result.os.tag != .windows) client.rdynamic = true;
    // **A native module resolves into the client, and the client must keep the
    // symbols it publishes.**
    //
    // `rdynamic` puts the export table in the binary, and the linker's
    // dead-strip then removes every symbol the client itself never calls.
    // Measured at `HEAD` — the Debug client exports **691** and the
    // `ReleaseSafe` client **92**, with `janet_cfuns_ext` and `janet_abstract`
    // among the six hundred that go. So a module has only ever been able to
    // reach whatever the interpreter happened to reference, and the old
    // `test/zig-native.janet` fixture passed because its four names were in
    // that accidental set. The shared library is unaffected — 690 in every
    // mode — because nothing dead-strips an exported symbol there.
    //
    // So the client keeps what `capi.zig` says it publishes rather than what
    // the optimizer can prove it uses.
    client.link_gc_sections = false;
    b.installArtifact(client);

    // `janet`, the module a native module imports -- and the *only* one it
    // imports. `src/module.zig` has the argument; what it costs the build
    // is this function, which any module in the tree asks for by name.
    const nativeModule = struct {
        fn make(
            bb: *std.Build,
            g: ?RuntimeGraph,
            t: std.Build.ResolvedTarget,
            o: std.builtin.OptimizeMode,
            opts: BuildOptions,
            root: []const u8,
            name: []const u8,
        ) *std.Build.Step.Compile {
            const janet_module = bb.createModule(.{
                .root_source_file = bb.path("src/module.zig"),
                .target = t,
                .optimize = o,
            });
            configureCModule(bb, janet_module, t, opts);
            const mod = bb.createModule(.{
                .root_source_file = bb.path(root),
                .target = t,
                .optimize = o,
            });
            configureCModule(bb, mod, t, opts);
            if (g) |graph| {
                janet_module.addImport("abi", graph.abi);
                janet_module.addImport("repr", graph.repr);
                janet_module.addImport("cabi", graph.cabi);
                janet_module.addImport("config", graph.module_config);
                janet_module.addImport("constants", graph.constants);
                mod.addImport("janet", janet_module);
            }
            const lib = bb.addLibrary(.{
                .name = name,
                .linkage = .dynamic,
                .root_module = mod,
            });
            lib.linker_allow_shlib_undefined = true;
            return lib;
        }
    }.make;

    const native_module = nativeModule(
        b,
        runtime_graph,
        target,
        optimize,
        options,
        "src/runtime/native_module.zig",
        "janet-zig-native",
    );
    // Dynamic module loading is platform-specific, so ship this alongside the
    // test executables for cross-platform runs.
    installTest(b, options, native_module);

    // `examples/numarray`, the sample an author reads: the worked example of
    // `DESIGN.md` section 5, which `zig build test` loads and runs.
    const numarray_module = nativeModule(
        b,
        runtime_graph,
        target,
        optimize,
        options,
        "examples/numarray/numarray.zig",
        "numarray",
    );
    installTest(b, options, numarray_module);

    // The three host translations -- `os/abi.h`, `net/abi.h`, `filewatch/abi.h`
    // -- have no oracle and need none: each keeps what it declares inside one
    // subsystem, and every name it publishes has a Zig caller that fails to
    // compile when the translation stops providing it.

    const run_step = b.step("run", "Run Janet");
    const run_client = b.addRunArtifact(client);
    run_client.setCwd(b.path("."));
    if (b.args) |args| run_client.addArgs(args);
    run_step.dependOn(&run_client.step);

    // An alias of `zig-contract-test`, kept because documents cite the name.
    const subsystem_step = b.step("subsystem-test", "Run the contracts (alias of zig-contract-test)");

    // The Zig contracts, in the runtime's own compilation.
    //
    // A contract that linked `libjanet.a` would cross the C ABI on every call,
    // and a raise would reach it only as an out-of-band report -- because a
    // symbol table is what joins two compilations, a symbol has a calling
    // convention, and Zig will not put an error union on a C-ABI function. This
    // binary puts the contract on the near side instead: `makeRuntimeGraph`
    // again, with `test/contracts.zig` as the root and the subsystems as an
    // import. A contract calls its subject by `@import` and writes `try`.
    //
    // What that costs is one more compilation of the runtime, and what it buys
    // is that a contract calls its subject the way a subsystem calls its
    // neighbour -- by import, with `try` -- so no face, no adapter pool, and no
    // flag stand between the two.
    checkContractsListed(b);
    checkAliasesUsed(b);
    const zig_contracts_step = b.step(
        "zig-contract-test",
        "Run the contracts that live in the runtime's compilation",
    );
    if (makeRuntimeGraph(b, target, optimize, options, image_source)) |graph| {
        const module = b.createModule(.{
            .root_source_file = b.path("test/contracts.zig"),
            .target = target,
            .optimize = optimize,
        });
        configureCModule(b, module, target, options);
        module.addImport("cabi", graph.cabi);
        module.addImport("config", graph.config);
        module.addImport("options", graph.selection);
        module.addImport("host", graph.host);
        module.addImport("abi", graph.abi);
        module.addImport("repr", graph.repr);
        module.addImport("constants", graph.constants);
        module.addImport("subsystems", graph.subsystems);
        const exe = b.addExecutable(.{ .name = "janet-zig-contract-test", .root_module = module });
        // A contract may load the native-module fixture, and a contract that
        // registers a cfunction the runtime later names needs its own symbols
        // visible for the same reason the client does.
        if (target.result.os.tag != .windows) exe.rdynamic = true;
        installTest(b, options, exe);
        // Installed unconditionally, for the same reason
        // `janet-contract-support.o` is: the narrow loop is a first-class
        // instrument here. `tools/testing/contract.sh` runs one contract by name, and
        // for a Zig contract that is this binary with an argument rather than
        // a `zig cc` of its own -- there is no source for a shallow link to
        // compile, and no link either, because the runtime it tests is inside.
        b.getInstallStep().dependOn(&b.addInstallArtifact(exe, .{}).step);
        const run = b.addRunArtifact(exe);
        run.setCwd(b.path("."));
        zig_contracts_step.dependOn(&run.step);
    }
    subsystem_step.dependOn(zig_contracts_step);

    // ------------------------------------------------ the module-error suite
    //
    // `abstract_type.define` exists to turn a wrong callback into a compile
    // error that names the contract rather than two
    // function types, and "the message is useful" is a claim like any other:
    // it needs an instrument that fails when the message stops being made.
    //
    // Each fixture under `test/module-errors/` is a module an author might
    // plausibly write wrongly, compiled with `expect_errors` naming the phrase
    // the diagnosis turns on. A build that *succeeds* fails the step, so
    // deleting a check in `define` is caught here rather than by a native
    // module author reading a type diff.
    const module_errors_step = b.step(
        "module-errors",
        "Prove a wrong native module fails at its own definition",
    );
    //
    // `expect_errors = .{ .contains = ... }` matches a whole *line* by suffix,
    // so each phrase below is the message's complete tail. That is stricter
    // than a keyword and deliberately so: the thing under test is the
    // sentence, and a sentence that changes should change here too.
    const module_error_cases = [_]struct { file: []const u8, phrase: []const u8 }{
        .{
            .file = "test/module-errors/wrong_payload.zig",
            .phrase = "abstract type 'module-errors/wrong-payload', callback 'gc': the first " ++
                "parameter must be `*wrong_payload.Right`, the payload type given to `define` " ++
                "-- it is `*wrong_payload.Wrong`. `define` generates the cast from the " ++
                "runtime's erased pointer, so the callback never writes one.",
        },
        .{
            .file = "test/module-errors/raising_gc.zig",
            .phrase = "abstract type 'module-errors/raising-gc', callback 'gc': this callback " ++
                "cannot raise, and that is a contract rather than an oversight. `gc` and " ++
                "`gcmark` run inside the collector -- a finalizer on an object that is already " ++
                "unreachable, a mark mid-traversal -- and `compare`, `hash`, `bytes` and " ++
                "`gcperthread` run inside operations that must be total. There is no scope " ++
                "above any of them and nothing to retry, so a raise would have nowhere to " ++
                "go, and none of the six has a return value to report one through either.",
        },
        .{
            .file = "test/module-errors/unknown_slot.zig",
            .phrase = "abstract type 'module-errors/unknown-slot' has no callback named " ++
                "'finalizer'. The callbacks are: gc, gcmark, get, put, marshal, unmarshal, " ++
                "tostring, compare, hash, next, call, length, bytes, gcperthread",
        },
        .{
            .file = "test/module-errors/wrong_cfunction.zig",
            .phrase = "cfunction 'identity': it takes its arguments as one `[]Value` slice, " ++
                "not a count and a pointer -- it must be `fn (argv: []Value) " ++
                "align(module.fn_align) Error!Value`",
        },
        .{
            .file = "test/module-errors/broad_error_set.zig",
            // The tail only: the anonymous-union suffix Zig gives `Value`
            // changes per compilation, so a phrase containing the given type
            // would be a check on the compiler's numbering.
            .phrase = "A cfunction answers a `Value` or a signal, so the type is exactly " ++
                "`Error!Value`: a wider error set is reinterpreted at the call rather " ++
                "than diagnosed here.",
        },
        .{
            .file = "test/module-errors/underaligned.zig",
            .phrase = "cfunction 'cramped': its alignment is 1. The runtime tags the low " ++
                "bits of a cfunction's address, so the alignment must be at least " ++
                "`module.fn_align`, which is 16.",
        },
        .{
            .file = "test/module-errors/overaligned_payload.zig",
            .phrase = "alloc(overaligned_payload.Wide): this type's alignment is 128. The " ++
                "runtime's allocator is malloc-backed and promises nothing stricter than " ++
                "`max_align_t`, so a payload needing more has to align its own storage " ++
                "inside an allocation this can make.",
        },
        .{
            .file = "test/module-errors/nonraising_get.zig",
            .phrase = "abstract type 'module-errors/nonraising-get', callback 'get': this " ++
                "callback may raise and its return type must say so: write `raise.Error!?Value`. " ++
                "It runs inside an interpreter frame with a real scope above it.",
        },
    };
    // **A fixture must not import `subsystems`, and the matrix is what says
    // so.** The first version of this step called `makeRuntimeGraph` inside
    // the loop and each fixture reached `define` through the runtime root, so
    // every `full` entry analysed the whole runtime four extra times. The
    // acceptance matrix went from **264s to 1,400s** with no verdict changing
    // -- and it read as the "disturbed machine" this file warns about, which
    // is exactly the wrong diagnosis. A fixture compiles the author package
    // and its leaves and nothing else.
    if (makeRuntimeGraph(b, target, optimize, options, image_source)) |graph| {
        const janet_module = b.createModule(.{
            .root_source_file = b.path("src/module.zig"),
            .target = target,
            .optimize = optimize,
        });
        configureCModule(b, janet_module, target, options);
        janet_module.addImport("abi", graph.abi);
        janet_module.addImport("repr", graph.repr);
        janet_module.addImport("cabi", graph.cabi);
        janet_module.addImport("config", graph.module_config);
        janet_module.addImport("constants", graph.constants);
        for (module_error_cases) |case| {
            const module = b.createModule(.{
                .root_source_file = b.path(case.file),
                .target = target,
                .optimize = optimize,
            });
            module.addImport("janet", janet_module);
            module.addImport("host", graph.host);
            module.addImport("repr", graph.repr);
            const obj = b.addObject(.{ .name = "module-errors", .root_module = module });
            obj.expect_errors = .{ .contains = case.phrase };
            module_errors_step.dependOn(&obj.step);
        }
    }

    // **The standalone consumer, built the way an outside author builds one.**
    //
    // `examples/numarray` is compiled here, with `RuntimeGraph` and the private
    // modules in hand, so it proves the *source* experience and cannot notice
    // if the published build surface rots. This step runs `zig build` inside
    // `examples/standalone`, which depends on this package by path and reaches
    // it only through `janetModule` -- so a change that breaks a real consumer
    // fails here rather than in somebody else's repository.
    //
    // It is a step of its own rather than part of `zig build test` because it
    // compiles the runtime's modules a second time in a second cache. The
    // acceptance matrix carries it, which is where a per-phase cost belongs.
    const standalone_step = b.step(
        "standalone",
        "Build the example that consumes this package from outside",
    );
    const standalone = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
    standalone.setCwd(b.path("examples/standalone"));
    standalone.setName("zig build (examples/standalone)");
    // Its output is its own; nothing here reads it, so the step's verdict is
    // the exit status.
    standalone.expectExitCode(0);
    // **It must actually run.** Without this the build graph has no idea what
    // this command reads -- the sub-package's sources and this file's public
    // helper are not declared inputs -- so it is hashed on its argv alone,
    // reports `cached`, and passes forever. Breaking `janetModule` on purpose
    // is what showed it: the sub-build failed when run by hand and the step
    // stayed green. An instrument that cannot fail is the thing this whole
    // package of checks exists to avoid. The inner `zig build` does its own
    // caching, so a no-change run is cheap.
    standalone.has_side_effects = true;
    standalone_step.dependOn(&standalone.step);

    // The fuzz targets, in a third compilation of the runtime.
    //
    // They need their own artifact rather than a place in the contract driver
    // because
    // `std.testing.fuzz` resolves through `@import("root").fuzz`, which exists
    // only in a test root -- a `pub fn run() void` cannot be a fuzz target and
    // a fuzz target cannot be a contract.
    //
    // Hung off `test_step` deliberately. Without `--fuzz` each target runs
    // once over its (empty) corpus, which costs milliseconds and is a smoke
    // check; with it, `zig build fuzz --fuzz` runs the campaign. The four C
    // originals were named by no build system at all, which is how they came
    // to be four files rather than four instruments, and a step nothing
    // depends on would reproduce that.
    const fuzz_step = b.step("fuzz", "Run the fuzz targets (add --fuzz to campaign)");
    if (makeRuntimeGraph(b, target, optimize, options, image_source)) |graph| {
        const module = b.createModule(.{
            .root_source_file = b.path("test/fuzz.zig"),
            .target = target,
            .optimize = optimize,
        });
        configureCModule(b, module, target, options);
        module.addImport("cabi", graph.cabi);
        module.addImport("config", graph.config);
        module.addImport("options", graph.selection);
        module.addImport("host", graph.host);
        module.addImport("abi", graph.abi);
        module.addImport("repr", graph.repr);
        module.addImport("constants", graph.constants);
        module.addImport("subsystems", graph.subsystems);
        const exe = b.addTest(.{ .name = "janet-fuzz-test", .root_module = module });
        if (target.result.os.tag != .windows) exe.rdynamic = true;
        installTest(b, options, exe);
        b.getInstallStep().dependOn(&b.addInstallArtifact(exe, .{}).step);
        const run = b.addRunArtifact(exe);
        run.setCwd(b.path("."));
        fuzz_step.dependOn(&run.step);
    }

    // The in-file `test "…"` blocks, in a fourth compilation of the runtime.
    //
    // A contract is `pub fn run() void` and is called by the driver; a `test`
    // block is called by nothing, so until this step existed the forty-odd of
    // them in `io.zig`, `filewatch.zig`, `ffi/` and `os/` were compiled by no
    // configuration at all and were free to rot. They root at `root.zig`, which
    // is the file that names every subsystem this configuration compiles, so
    // the set of tests that run is the set of files that build -- a `test` in a
    // subsystem the options exclude is not analysed, the same as its subject.
    //
    // Separate from the contract driver because the two are different
    // instruments and the difference is worth keeping: a contract asserts what
    // Janet observes, from outside the subsystem and against an independently
    // derived oracle, and runs against a live runtime the driver initialises
    // and tears down; a `test` block here asserts something interior --
    // classification tables, flag decoding, a parser for a host string -- and
    // has no runtime under it.
    const runtime_tests_step = b.step("runtime-test", "Run the in-file `test` blocks in the runtime");
    if (makeRuntimeGraph(b, target, optimize, options, image_source)) |graph| {
        const exe = b.addTest(.{ .name = "janet-runtime-test", .root_module = graph.subsystems });
        if (target.result.os.tag != .windows) exe.rdynamic = true;
        installTest(b, options, exe);
        // Run as a plain command rather than through `addRunArtifact`, which
        // hands a test binary `--listen=-` and speaks the build runner's
        // protocol over it. That protocol reports the count only to
        // `--summary`, and a test set that has silently become empty then looks
        // exactly like one that passed -- the failure `test/README.md` names
        // for a suite reporting `0 of 0`. Run bare, the default test runner
        // prints "All N tests passed." on every `zig build test`.
        const run = std.Build.Step.Run.create(b, "run janet-runtime-test");
        run.addArtifactArg(exe);
        run.setCwd(b.path("."));
        runtime_tests_step.dependOn(&run.step);
    }

    const test_step = b.step("test", "Run Janet's contracts and test suites");
    test_step.dependOn(subsystem_step);
    test_step.dependOn(fuzz_step);
    test_step.dependOn(runtime_tests_step);
    test_step.dependOn(module_errors_step);
    addCliChecks(b, test_step, client);

    // The native-module fixture is a dynamic library and is skipped under TSan
    // for the same reason the shared library is; see there.
    if (options.dynamic_modules and target.result.os.tag != .windows and !options.sanitize_thread) {
        const run_native_test = b.addRunArtifact(client);
        run_native_test.setCwd(b.path("."));
        run_native_test.addArg("test/zig-native.janet");
        run_native_test.addFileArg(native_module.getEmittedBin());
        test_step.dependOn(&run_native_test.step);

        // The sample module, loaded and exercised the way a user's would be.
        // "A sample out-of-tree native module compiles and loads using only the
        // published module interface" is a claim like any other, so it is a
        // step rather than a sentence.
        const run_numarray = b.addRunArtifact(client);
        run_numarray.setCwd(b.path("."));
        run_numarray.addArg("examples/numarray/test/numarray.janet");
        run_numarray.addFileArg(numarray_module.getEmittedBin());
        test_step.dependOn(&run_numarray.step);
    }

    inline for (test_suites) |suite| {
        if (!suite.needs_os or !options.reduced_os) {
            const run_suite = b.addRunArtifact(client);
            run_suite.setCwd(b.path("."));
            run_suite.addArg(suite.path);
            test_step.dependOn(&run_suite.step);
        }
    }
}

/// Every file-scope alias is used by the file that declares it.
///
/// Zig rejects an unused *local*; a container-level declaration is never
/// checked, so `const io = @import("io.zig");` outlives the last call that
/// needed it and nothing says so.
///
/// The rule is deliberately narrow. It looks only at a non-`pub` `const` whose
/// entire right-hand side is one token -- an `@import`, a dotted path, or a
/// literal -- and asks whether its name appears anywhere else in its own file,
/// **comments and string literals blanked first**. Widening it past one token
/// would start reading expressions, and an expression can have an effect worth
/// keeping.
///
/// It is not only about imports: `const chunk_bits = 32;` in
/// `compiler/regalloc.zig` is the shape no sweep for an `@import` would find.
fn checkAliasesUsed(b: *std.Build) void {
    for ([_][]const u8{ "src", "test" }) |root| checkAliasesIn(b, root);
}

fn checkAliasesIn(b: *std.Build, path: []const u8) void {
    const io = b.graph.io;
    var dir = b.build_root.handle.openDir(io, path, .{ .iterate = true }) catch |err| {
        std.debug.panic("build.zig: cannot open {s}/: {t}", .{ path, err });
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        const child = b.pathJoin(&.{ path, entry.name });
        switch (entry.kind) {
            .directory => checkAliasesIn(b, child),
            .file => if (std.mem.endsWith(u8, entry.name, ".zig")) checkAliasesInFile(b, child),
            else => {},
        }
    }
}

fn checkAliasesInFile(b: *std.Build, path: []const u8) void {
    const text = b.build_root.handle.readFileAlloc(
        b.graph.io,
        path,
        b.allocator,
        std.Io.Limit.limited(4 << 20),
    ) catch |err| std.debug.panic("build.zig: cannot read {s}: {t}", .{ path, err });

    // Comments are stripped before counting. A one-letter alias otherwise finds
    // itself everywhere -- `test/vm_state.zig`'s unused `const c = @import(
    // "cabi")` was held alive by the `c` inside a `[*c]Vm` written in a comment,
    // which is exactly the reader-facing prose this check exists to stop
    // standing in for a real dependency.
    const code = stripLineComments(b, text);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const name = aliasDeclared(line) orelse continue;
        if (countIdentifier(code, name) > 1) continue;
        std.debug.panic(
            "build.zig: {s} declares `{s}` and never uses it. A file-scope alias " ++
                "is not checked by the compiler, so delete it rather than leaving it " ++
                "to name a dependency the file no longer has.",
            .{ path, name },
        );
    }
}

/// The name a line declares as a plain alias, or null if it is anything else.
/// `text` with every `//` comment **and every string literal's contents**
/// blanked. Zig has no block comments, so a line scanner is the whole of it.
///
/// The string contents go for the same reason the comments do: they are not
/// code, and counting them made the check miss what it exists to find.
/// `const options = @import("options");` used to count *two* occurrences of
/// `options` -- the declaration and the name inside its own import -- so a
/// file that never read `options.anything` still passed, and nine of those had
/// accumulated by the time the string blanking landed.
fn stripLineComments(b: *std.Build, text: []const u8) []const u8 {
    const out = b.allocator.dupe(u8, text) catch @panic("OOM");
    var i: usize = 0;
    var in_string = false;
    while (i < out.len) : (i += 1) {
        switch (out[i]) {
            '\n' => in_string = false,
            '\\' => if (in_string) {
                out[i] = ' ';
                if (i + 1 < out.len) {
                    i += 1;
                    out[i] = ' ';
                }
            },
            '"' => in_string = !in_string,
            '/' => if (!in_string and i + 1 < out.len and out[i + 1] == '/') {
                while (i < out.len and out[i] != '\n') : (i += 1) out[i] = ' ';
            },
            else => if (in_string) {
                out[i] = ' ';
            },
        }
    }
    return out;
}

fn aliasDeclared(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "const ")) return null;
    if (!std.mem.endsWith(u8, line, ";")) return null;
    const eq = std.mem.indexOf(u8, line, " = ") orelse return null;
    const name = line["const ".len..eq];
    for (name) |ch| if (!isIdentifierChar(ch)) return null;
    if (name.len == 0) return null;

    const rhs = line[eq + " = ".len .. line.len - 1];
    if (std.mem.startsWith(u8, rhs, "@import(")) {
        // `@import("x.zig")` and `@import("x.zig").Member` alike; anything with
        // a call or an operator after it is an expression, not an alias.
        const rest = rhs["@import(".len..];
        const close = std.mem.indexOfScalar(u8, rest, ')') orelse return null;
        for (rest[close + 1 ..]) |ch| if (!isIdentifierChar(ch) and ch != '.') return null;
        return name;
    }
    for (rhs) |ch| if (!isIdentifierChar(ch) and ch != '.') return null;
    return if (rhs.len == 0) null else name;
}

fn isIdentifierChar(ch: u8) bool {
    return ch == '_' or std.ascii.isAlphanumeric(ch);
}

/// How many times `name` appears in `text` as a whole identifier, **not
/// counting a member reference**.
///
/// A file-scope alias is used as `name.field`, `name(...)` or bare; it is never
/// reached as `.name`, so an occurrence preceded by a dot is somebody else's
/// field, enum literal or method. That distinction is what the check was
/// missing for `const c = @import("cabi")`: every `callconv(.c)` in the file
/// counted as a use of `c`, so a file that had stopped calling libc entirely
/// still passed, and four of those had accumulated.
fn countIdentifier(text: []const u8, name: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, name)) |at| {
        i = at + name.len;
        // A `.` before the name means a member reference -- unless it is the
        // second dot of a range, where `arr[0..c.strlen(s)]` really is a use of
        // `c`. That case cost one false positive on the first run of this
        // check, which is the whole reason the condition is not just `!= '.'`.
        const dotted = text[at - 1] == '.' and !(at >= 2 and text[at - 2] == '.');
        const before_ok = at == 0 or (!isIdentifierChar(text[at - 1]) and !dotted);
        const after_ok = i == text.len or !isIdentifierChar(text[i]);
        if (before_ok and after_ok) count += 1;
    }
    return count;
}

/// Every `test/*.zig` that is a contract must be named in `test/contracts.zig`.
///
/// Forget the line and **the tree is green with a contract that never runs**.
/// Nothing else would say so: the driver never heard of it, and a file nobody
/// compiles produces no diagnostic. A check that runs before the first build is
/// worth more than a paragraph that runs before the first mistake, and it costs
/// one directory read.
///
/// Deliberately crude, in the way `checkJumpTransparency` was: a substring
/// search for the file's name in the driver's source. It cannot tell a live
/// entry from one inside a comment, and it does not need to — what it is
/// looking for is a file nobody has mentioned at all.
fn checkContractsListed(b: *std.Build) void {
    // Not contracts: the driver itself and the shared helpers.
    const exempt = [_][]const u8{ "contracts.zig", "harness.zig", "fuzz.zig", "expect.zig" };

    const io = b.graph.io;
    const driver = b.build_root.handle.readFileAlloc(
        io,
        "test/contracts.zig",
        b.allocator,
        std.Io.Limit.limited(1 << 20),
    ) catch |err| std.debug.panic("build.zig: cannot read test/contracts.zig: {t}", .{err});

    var dir = b.build_root.handle.openDir(io, "test", .{ .iterate = true }) catch |err| {
        std.debug.panic("build.zig: cannot open test/: {t}", .{err});
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
        for (exempt) |name| {
            if (std.mem.eql(u8, entry.name, name)) break;
        } else {
            if (std.mem.indexOf(u8, driver, entry.name) == null) {
                std.debug.panic(
                    "build.zig: test/{s} is a contract that test/contracts.zig does not list, " ++
                        "so nothing runs it. Add it there, or to `exempt` in checkContractsListed " ++
                        "if it is not a contract.",
                    .{entry.name},
                );
            }
        }
    }
}

/// Install a test executable under `<prefix>/test` when -Dinstall-tests is set.
///
/// `zig build test` runs what it builds, which is impossible when the target is
/// not the host. Installing the executables lets a cross-compiled build be
/// carried to the target machine and run there.
fn installTest(b: *std.Build, options: BuildOptions, exe: *std.Build.Step.Compile) void {
    if (!options.install_tests) return;
    const install = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = "test" } },
    });
    b.getInstallStep().dependOn(&install.step);
}

fn addCliChecks(
    b: *std.Build,
    test_step: *std.Build.Step,
    zig_client: *std.Build.Step.Compile,
) void {
    const clients = [_]*std.Build.Step.Compile{zig_client};
    for (clients) |client| {
        const eval = b.addRunArtifact(client);
        eval.addArgs(&.{ "-e", "(prin (+ 20 22))" });
        eval.expectStdOutEqual("42");
        test_step.dependOn(&eval.step);

        const file = b.addRunArtifact(client);
        file.setCwd(b.path("."));
        file.addArg("test/zig-cli-input.janet");
        file.expectStdOutEqual("file-ok");
        test_step.dependOn(&file.step);

        const help = b.addRunArtifact(client);
        help.addArg("--help");
        help.expectStdOutMatch("Options are:");
        test_step.dependOn(&help.step);

        const failure = b.addRunArtifact(client);
        failure.addArgs(&.{ "-e", "(error \"cli-error\")" });
        failure.expectExitCode(1);
        failure.expectStdErrMatch("cli-error");
        test_step.dependOn(&failure.step);
    }

    const repl = b.addRunArtifact(zig_client);
    repl.setStdIn(.{ .bytes = "(+ 1 2)\n" });
    repl.expectStdOutMatch("3");
    repl.expectStdOutMatch("Janet 1.41.3-dev-zig");
    repl.expectStdErrMatch("repl:1:>");
    test_step.dependOn(&repl.step);
}

fn readOptions(b: *std.Build) BuildOptions {
    // 0 through 2, not the 0 through 4 Janet's own header advertises. The shift takes
    // the low bits of a wrapped pointer, so every cfunction and abstract type
    // descriptor has to be aligned to `1 << shift`; at 3 and 4 that is more
    // than a function pointer carries on its own, and the registration check
    // aborts the bootstrap. Raising the ceiling means declaring the alignment
    // on every cfunction in the tree, which is a change nothing asks for.
    const pointer_shift = b.option(i32, "nanbox-pointer-shift", "Override the NaN-box pointer shift (0 through 2)");
    if (pointer_shift) |shift| {
        if (shift < 0 or shift > 2) @panic("-Dnanbox-pointer-shift must be between 0 and 2: " ++
            "a shift above 2 needs every cfunction pointer aligned past what a function pointer promises");
    }

    const options: BuildOptions = .{
        .install_tests = b.option(bool, "install-tests", "Install the contract, fuzz and runtime test executables so they can be run on another machine") orelse false,
        .sanitize_thread = b.option(bool, "sanitize-thread", "Build with ThreadSanitizer, for the threaded-abstract and event-loop paths") orelse false,
        .single_threaded = b.option(bool, "single-threaded", "Build without thread-local VM state") orelse false,
        .nanbox = b.option(bool, "nanbox", "Use Janet's NaN-boxed value representation") orelse true,
        .nanbox_pointer_shift = pointer_shift,
        .dynamic_modules = b.option(bool, "dynamic-modules", "Enable dynamic native modules") orelse true,
        .docstrings = b.option(bool, "docstrings", "Include documentation strings") orelse true,
        .sourcemaps = b.option(bool, "sourcemaps", "Include source maps") orelse true,
        .reduced_os = b.option(bool, "reduced-os", "Build the reduced OS library") orelse false,
        .assembler = b.option(bool, "assembler", "Enable the assembler") orelse true,
        .peg = b.option(bool, "peg", "Enable PEG support") orelse true,
        .int_types = b.option(bool, "int-types", "Enable integer abstract types") orelse true,
        .prf = b.option(bool, "prf", "Enable profiling instrumentation") orelse false,
        .net = b.option(bool, "net", "Enable networking") orelse true,
        .ipv6 = b.option(bool, "ipv6", "Enable IPv6") orelse true,
        .ev = b.option(bool, "ev", "Enable the event loop") orelse true,
        .processes = b.option(bool, "processes", "Enable process APIs") orelse true,
        .umask = b.option(bool, "umask", "Enable umask support") orelse true,
        .realpath = b.option(bool, "realpath", "Enable realpath support") orelse true,
        .epoll = b.option(bool, "epoll", "Enable the epoll backend") orelse true,
        .kqueue = b.option(bool, "kqueue", "Enable the kqueue backend") orelse true,
        .interpreter_interrupt = b.option(bool, "interpreter-interrupt", "Enable interpreter interrupts") orelse true,
        .ffi = b.option(bool, "ffi", "Enable FFI") orelse true,
        .ffi_jit = b.option(bool, "ffi-jit", "Enable the FFI JIT") orelse true,
        .filewatch = b.option(bool, "filewatch", "Enable file watching") orelse true,
        .cryptorand = b.option(bool, "cryptorand", "Enable cryptographic random bytes") orelse true,
        .recursion_guard = b.option(i32, "recursion-guard", "C recursion guard") orelse 1024,
        .max_proto_depth = b.option(i32, "max-proto-depth", "Maximum prototype lookup depth") orelse 200,
        .max_macro_expand = b.option(i32, "max-macro-expand", "Maximum macro expansion depth") orelse 200,
        .stack_max = b.option(i32, "stack-max", "Maximum Janet stack size") orelse 0x7fffffff,
        // `os/which` and `os/arch` overrides. A build option rather than a
        // macro, because no header is installed for a user to edit.
        .fiber_stack_shuffle = b.option(bool, "fiber-stack-shuffle", "Move every fiber's stack on every frame push, so a pointer kept across one is a use-after-free the allocator can see") orelse false,
        .os_name = b.option([]const u8, "os-name", "Override the keyword os/which reports"),
        .arch_name = b.option([]const u8, "arch-name", "Override the keyword os/arch reports"),
    };

    if (options.recursion_guard < 10 or options.recursion_guard > 8000)
        @panic("-Drecursion-guard must be between 10 and 8000");
    if (options.max_proto_depth < 10 or options.max_proto_depth > 8000)
        @panic("-Dmax-proto-depth must be between 10 and 8000");
    if (options.max_macro_expand < 1 or options.max_macro_expand > 8000)
        @panic("-Dmax-macro-expand must be between 1 and 8000");
    if (options.stack_max < 8096)
        @panic("-Dstack-max must be at least 8096");

    return options;
}

/// Which of the three value representations this build compiles.
///
/// `DESIGN.md` section 7 drops `nanbox_32` and renames the option to
/// `-Dvalue-repr`. Neither is done: all three are still selectable by
/// `-Dnanbox` and the target's word size.
const ValueRepr = enum { nanbox_64, nanbox_32, tagged };

/// What the build decided, as comptime facts for `@import("config")`.
///
/// This struct is where configuration is *resolved*. A file reads
/// `config.<name>`; nothing asks a translation what it was compiled with.
///
/// **The fields are positives, and the build options they come from are a
/// mixture.** A `-D` flag names the feature (`-Dpeg`, `-Dev`), but the clause
/// that decides whether the subsystem exists also folds in the target and the
/// other options -- the event loop is off on a single-threaded build and under
/// Emscripten, epoll exists only on Linux, kqueue only on the BSDs. Each such
/// clause is written out below beside the field it decides, because the
/// derivation is what a reader needs and `options.<name>` alone is not it.
///
/// Four facts that were macros in Janet are *not* fields here --
/// `JANET_32`/`JANET_64`, `JANET_BIG_ENDIAN`, `JANET_WINDOWS` and
/// `JANET_PLAN9`. Those are properties of the target, which Janet's header
/// recovered by testing a hand-maintained list of architecture macros with a
/// fallback that *assumes big-endian* when it recognises nothing.
/// `@import("builtin")` knows them exactly, so the call sites read `builtin`
/// and the guesswork goes.
const Config = struct {
    bootstrap: bool,
    /// Whether this compilation is a native module rather than the runtime.
    ///
    /// `raise.zig` and `abstract_type.zig` are compiled into both, and the
    /// difference is not a feature: inside the runtime a raise reaches
    /// `signal.zig` by import, and inside a module the same call is a symbol,
    /// because the runtime is on the other side of a `dlopen`. `raise.zig`
    /// carries both arms and picks on this.
    native_module: bool,
    docstrings: bool,
    sourcemaps: bool,
    dynamic_modules: bool,
    assembler: bool,
    peg: bool,
    int_types: bool,
    prf: bool,
    ev: bool,
    net: bool,
    ffi: bool,
    ffi_jit: bool,
    filewatch: bool,
    cryptorand: bool,
    reduced_os: bool,
    processes: bool,
    realpath: bool,
    umask: bool,
    ev_epoll: bool,
    ev_kqueue: bool,
    ev_poll: bool,
    ipv6: bool,

    /// Two facts a dozen files read. They are fields for the same reason the
    /// rest are: configuration is resolved here, so a file that needs to know
    /// whether this build has threads asks `config`, not the preprocessor and
    /// not a translated constant.
    single_threaded: bool,
    interpreter_interrupt: bool,

    /// The version quintet and the four limits, which the runtime reads as
    /// `config` fields: `boot_tests.zig` compares the quintet, `env.zig`
    /// publishes `janet/build`, and the limits are read at nineteen, eleven,
    /// one and two sites.
    version_major: i32,
    version_minor: i32,
    version_patch: i32,
    version_extra: []const u8,
    version: []const u8,
    build_name: []const u8,
    recursion_guard: i32,
    max_proto_depth: i32,
    max_macro_expand: i32,
    stack_max: i32,

    /// Whether the target is 64-bit. A field rather than `@sizeOf(usize)` at
    /// the call site because `test/ffi_layout.zig` says
    /// why: a contract wants "the same input the subject reads, rather than
    /// the subject's answer, and rather than `@sizeOf(usize)`, which is a
    /// different question that happens to agree here".
    bits64: bool,
    value_repr: ValueRepr,
    nanbox_pointer_shift: i32,
    os_name: ?[]const u8,
    arch_name: ?[]const u8,

    /// Three predicates the runtime reads that **nothing in this tree ever
    /// defines**, carried as constants so that the behaviour is unchanged.
    /// A comptime-false condition means the branch behind it has never been
    /// analysed, so each of these guards code no build has ever type-checked --
    /// which is why the fourth stopped being one; see `debug` below.
    ///
    ///   - `spawn`/`symlinks`/`locales` are upstream configuration options
    ///     this build has no `-D` for, so they are pinned on.
    ///
    /// `JANET_PLAN9` was the fourth and is the one that improves by moving: it
    /// becomes `builtin.os.tag == .plan9` at the call site, false for every
    /// target built here and correct for the one it names.
    spawn: bool = true,
    symlinks: bool = true,
    locales: bool = true,

    /// Move every fiber's stack on every frame push, so that a pointer kept
    /// across one becomes a use-after-free the allocator can see.
    ///
    /// **It is an option rather than a pinned constant because a comptime-false
    /// constant is code nothing type-checks**, and this one was not: the arm
    /// held a slice of an optional many-pointer with no `.?`, which no
    /// configuration could compile. `-Dfiber-stack-shuffle=true` is in the
    /// acceptance matrix as a build entry for that reason.
    ///
    /// Not wired to `builtin.mode == .Debug`: that would reallocate the fiber
    /// stack on every frame push in every Debug build, which is not what a
    /// Debug build is for.
    debug: bool = false,
};

/// The one derivation: what the `-D` options and the target together decide.
///
/// Every comptime fact a file reads as `config.<name>` is answered here and
/// nowhere else, so a file cannot be compiled under one answer and guarded
/// under another.
fn janetConfig(options: BuildOptions, target: std.Build.ResolvedTarget) Config {
    const os = target.result.os.tag;
    const emscripten = os == .emscripten;
    const linux = os == .linux;
    const bsd = switch (os) {
        .freebsd, .openbsd, .netbsd, .dragonfly => true,
        else => false,
    };
    const apple = switch (os) {
        .macos, .ios, .tvos, .watchos, .visionos => true,
        else => false,
    };
    const windows = os == .windows;

    // The event loop needs threads and needs a host that has them, so
    // `-Dev=true` is necessary and not sufficient: a single-threaded build and
    // an Emscripten target each turn it off on their own.
    const ev = options.ev and !options.single_threaded and !emscripten;
    // `#ifndef JANET_NO_FFI` / `#if !defined(__EMSCRIPTEN__)`
    const ffi = options.ffi and !emscripten;
    // `#if defined(JANET_LINUX) && !defined(JANET_EV_NO_EPOLL)`
    const ev_epoll = linux and options.epoll;
    // the JANET_BSD and JANET_APPLE clauses, which define the same macro
    const ev_kqueue = (bsd or apple) and options.kqueue;

    return .{
        .bootstrap = options.bootstrap,
        .native_module = false,
        .debug = options.fiber_stack_shuffle,
        .docstrings = options.docstrings,
        .sourcemaps = options.sourcemaps,
        .dynamic_modules = options.dynamic_modules,
        .assembler = options.assembler,
        .peg = options.peg,
        .int_types = options.int_types,
        .prf = options.prf,
        .ev = ev,
        // `#if defined(JANET_EV) && !defined(JANET_NO_NET) && !defined(__EMSCRIPTEN__)`
        .net = ev and options.net and !emscripten,
        .ffi = ffi,
        // `#ifdef JANET_FFI` / `#ifndef JANET_NO_FFI_JIT`
        .ffi_jit = ffi and options.ffi_jit,
        .filewatch = options.filewatch,
        .cryptorand = options.cryptorand,
        .reduced_os = options.reduced_os,
        .processes = options.processes,
        .realpath = options.realpath,
        .umask = options.umask,
        .ev_epoll = ev_epoll,
        .ev_kqueue = ev_kqueue,
        // Poll is the fallback: everything that is not Windows and has
        // neither epoll nor kqueue.
        .ev_poll = !windows and !ev_epoll and !ev_kqueue,
        .ipv6 = options.ipv6,
        .bits64 = target.result.ptrBitWidth() == 64,
        // `-Dnanbox=false` gives the tagged struct; otherwise the pointer
        // width picks between the two NaN-boxed unions.
        .value_repr = if (!options.nanbox)
            .tagged
        else if (target.result.ptrBitWidth() == 64)
            .nanbox_64
        else
            .nanbox_32,
        // aarch64 that is **not** Apple, because aarch64 macOS uses the same
        // 47-bit userland address space as amd64 and so needs no shift. The
        // option overrides it either way. Carried as a number rather than a
        // predicate because `registry.zig` compares it to zero.
        //
        // **This clause was once written inverted** — `apple and aarch64` — and
        // `registry.checkPointerAlign` guarded on this field while masking with
        // the shift itself. On aarch64 Linux the guard returned early and the
        // alignment check was off on the only targets that shift; on aarch64
        // macOS it ran with a zero mask and checked nothing. One derivation is
        // what closes that.
        .nanbox_pointer_shift = options.nanbox_pointer_shift orelse
            if (!apple and target.result.cpu.arch == .aarch64) 2 else 0,
        .os_name = options.os_name,
        .arch_name = options.arch_name,
        .single_threaded = options.single_threaded,
        .interpreter_interrupt = options.interpreter_interrupt,
        .version_major = version.major,
        .version_minor = version.minor,
        .version_patch = version.patch,
        .version_extra = version_extra,
        .version = version_string,
        .build_name = build_name,
        .recursion_guard = options.recursion_guard,
        .max_proto_depth = options.max_proto_depth,
        .max_macro_expand = options.max_macro_expand,
        .stack_max = options.stack_max,
    };
}

/// `@import("config")`: `Config` as comptime constants.
///
/// Built by reflection for the reason `makeSelectionModule` is: a hand-written
/// list acquires a stale entry the first time a field is added and nothing
/// announces it.
fn makeConfigModule(b: *std.Build, cfg: Config) *std.Build.Module {
    const step = b.addOptions();
    inline for (@typeInfo(Config).@"struct".fields) |field| {
        step.addOption(field.type, field.name, @field(cfg, field.name));
    }
    return step.createModule();
}

fn makeCModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options: BuildOptions,
) *std.Build.Module {
    const module = b.createModule(.{ .target = target, .optimize = optimize });
    configureCModule(b, module, target, options);
    return module;
}

fn configureCModule(
    b: *std.Build,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    options: BuildOptions,
) void {
    // Two include paths, one per tier that holds a header: the three subsystem
    // translations `os/abi.h`, `net/abi.h` and `filewatch/abi.h` are runtime
    // files, and the `janet_features.h` all three of them open with is the
    // host's.
    module.addIncludePath(b.path("src/runtime"));
    module.addIncludePath(b.path("src/host"));
    module.linkSystemLibrary("c", .{});
    applySanitizers(module, options);
    linkPlatformLibraries(module, target.result.os.tag, options.single_threaded);
}

/// The sanitizer configuration, applied to every module the build makes --
/// the runtime, the client and the contract binaries alike.
///
/// **`sanitize_c` is set explicitly rather than left to the optimize mode.**
/// Zig turns C undefined-behaviour checking on in Debug and ReleaseSafe by
/// itself, and the tree had been relying on that: an alignment fault in the
/// runtime's own thread-local state was found by a check nobody had asked for.
/// A check that fires by luck is not a gate, and the default is `.trap`, which
/// aborts on a bare
/// `ud2` with no message and no line. `.full` links the UBSan runtime and
/// prints what was violated and where, which is the difference between a
/// diagnosis and a core dump.
///
/// It is set per optimize mode rather than unconditionally, and the difference
/// is not cosmetic: forcing `.full` everywhere puts the UBSan runtime inside
/// ReleaseFast, which is the mode a release artifact is built in. Measured --
/// a ReleaseFast build with `sanitize_c = .full` reports on `(gcsetinterval -1)`
/// where the same build without it does not. The gate wants the check *named*,
/// not the shipping binary changed, so the release modes keep the `.off` Zig
/// would have chosen and the two checked modes say `.full` out loud.
///
/// `sanitize_thread` is opt-in through `-Dsanitize-thread` rather than on by
/// default. TSan needs its own runtime and slows the suites by roughly an order
/// of magnitude, and the paths it covers -- the threaded-abstract refcount and
/// the event loop -- are exercised by two contracts rather than by all of them.
fn applySanitizers(module: *std.Build.Module, options: BuildOptions) void {
    module.sanitize_c = switch (module.optimize orelse .Debug) {
        .Debug, .ReleaseSafe => .full,
        .ReleaseFast, .ReleaseSmall => .off,
    };
    if (options.sanitize_thread) module.sanitize_thread = true;
}

fn makeRuntimeModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options: BuildOptions,
    zig_runtime: ?*std.Build.Step.Compile,
) *std.Build.Module {
    const module = makeCModule(b, target, optimize, options);
    addRuntimeSources(module, zig_runtime);
    return module;
}

fn addRuntimeSources(
    module: *std.Build.Module,
    zig_runtime: ?*std.Build.Step.Compile,
) void {
    // The image travels inside the object: an `@embedFile` in `core_env.zig`
    // reached through `makeRuntimeGraph`'s anonymous import. A module that
    // takes the object takes the image with it, so this function has no opinion
    // about either.
    //
    // One object, holding every subsystem this configuration selects.
    if (zig_runtime) |object| module.addObject(object);
}

/// Which subsystems this configuration answers in Zig.
///
/// Every condition the build makes about a subsystem is here, and nowhere else.
/// Two kinds appear:
///
///  - a feature gate, where the subsystem has nothing to do in a build that
///    turned its feature off — `-Dffi=false` leaves `ffi/classify.zig` with no
///    types to name, and `-Dpeg=false` leaves nothing for `peg.zig` to name;
///  - a reduced-OS gate, which drops the region rather than the file.
fn zigSelection(options: BuildOptions) Selection {
    return .{
        .scratch_vector = true,
        .utilities = true,
        .registry = true,
        .regalloc = true,
        .verify = true,
        .emit_core = true,
        .disasm = options.assembler,
        .bytecode = options.assembler,
        .compiler_primitives = true,
        .parser = true,
        .specials_core = true,
        .optimize = true,
        .scan = true,
        .math_core = true,
        .int_types_core = options.int_types,
        .os_environ = !options.reduced_os,
        .os_fs = !options.reduced_os,
        .os_time = hasGettime(options),
        .io = true,
        .os_process = hasProcesses(options),
        .os = true,
        .ev = hasEv(options),
        .net = hasNet(options),
        .ffi_zig = options.ffi,
        .filewatch = hasFilewatch(options),
        .args = true,
        .gc_alloc = true,
        .gc_mark = true,
        .gc_sweep = true,
        .arrays = true,
        .buffers = true,
        .strings = true,
        .symbols = true,
        .tuples = true,
        .tables = true,
        .structs = true,
        .order = true,
        .access = true,
        .abstracts = true,
        .functions = true,
        .wrap = true,
        .pp = true,
        .marsh = true,
        .peg_engine = options.peg,
        .env = true,
        .fibers = true,
        .signal = true,
        .debug = true,
        .vm = true,
        .vm_entry = true,
        .lifecycle = true,
    };
}

fn hasGettime(options: BuildOptions) bool {
    return !options.reduced_os or !options.single_threaded;
}

/// The process functions are compiled only outside a reduced-OS build and only
/// when process support is enabled, so the subsystem that serves them exists
/// under the same two conditions.
fn hasProcesses(options: BuildOptions) bool {
    return !options.reduced_os and options.processes;
}

/// Whether this build has an event loop at all. `-Dsingle-threaded` takes it
/// away regardless of `-Dev`, because every wait in it is a wait on another
/// thread; `Config.ev` folds in the target as well.
fn hasEv(options: BuildOptions) bool {
    return options.ev and !options.single_threaded;
}

/// The socket layer exists exactly when the event loop does and networking was
/// not turned off: every socket operation suspends on the loop.
fn hasNet(options: BuildOptions) bool {
    return hasEv(options) and options.net;
}

/// The file watcher needs the event loop for the same reason. It compiles all
/// three backends' keyword vocabularies on every target, but there is nothing
/// to compile them for when the watcher itself is absent.
fn hasFilewatch(options: BuildOptions) bool {
    return hasEv(options) and options.filewatch;
}

/// The runtime's module graph: every subsystem this configuration answers in
/// Zig, in one compilation.
///
/// Several *modules*, one *compilation*. `config`, `repr`, `abi`, `constants`,
/// `host`, `cabi` and `options` are namespaces and settings scopes rather than
/// compile barriers, and an error union crosses them freely. What it cannot
/// cross is the boundary between two `addObject`s, because a symbol table is
/// the only thing that joins those and a symbol has a calling convention.
///
/// It is a graph rather than an object because it is built more than once: for
/// `-Dtarget`, and for the *host*, so `janet-boot` -- a build-time tool that
/// runs on the build machine -- has one of its own.
///
/// Four things are made of it: the runtime wraps it in one `addObject` and
/// links that into the library and the client, and `test/contracts.zig`,
/// `test/fuzz.zig` and the in-file `test` blocks each root a compilation of
/// their own **on** it, so that a contract and the subsystem it tests are
/// inside one compilation.
///
/// That is the whole answer to "how does a contract reach a raise-capable
/// function": the only thing joining two separately compiled objects is a
/// symbol, a symbol has a calling convention, and Zig will not put an error
/// union on a C-ABI function. A contract that linked `libjanet.a` could not
/// see a raise except as an out-of-band report. A contract *in* the
/// compilation calls its subject by import and writes `try`.
/// second translation's `Janet` could not pass it to the subsystem at all.
const RuntimeGraph = struct {
    subsystems: *std.Build.Module,
    selection: *std.Build.Module,
    config: *std.Build.Module,
    /// The same configuration with `native_module` set.
    ///
    /// `raise.zig` and `abstract_type.zig` compile into a native module as
    /// well as into the runtime, and inside a module the calls `raise.zig`
    /// makes are symbols rather than imports. Every module-shaped graph below
    /// -- `janetModule`, `nativeModule`, the `module-errors` fixtures -- hands
    /// the author package this one; the runtime's own graph never does.
    module_config: *std.Build.Module,
    /// What a separately compiled module and the runtime must agree on, and
    /// nothing else -- `src/api/abi.zig`. `janetModule` hands an author's
    /// package this one; the runtime has it too, so that its `AbstractType`
    /// and an author's are one type.
    abi: *std.Build.Module,
    /// What is left of the type catalogue: the shapes the host decides, which
    /// `root` and `cabi` both name and must spell the same way. A contract
    /// reaches it the way the runtime does -- compiled *into* a second copy of
    /// the runtime -- so `test/` spells the same declarations. A module the
    /// runtime has and the contracts do not is a call-site rewrite that stops
    /// at the `src/` boundary.
    host: *std.Build.Module,
    constants: *std.Build.Module,
    cabi: *std.Build.Module,
    /// The value representation, below `host` and `constants` because they name
    /// `repr.Value` at 28 code sites across seventeen aggregates, and below
    /// `constants` because the tag numbering is `repr.Tag`'s and `constants`
    /// restates it for a C caller rather than owning it. Its own import list is
    /// `config` alone, set below and nowhere else, which is what makes "the
    /// representation module does not import allocation, tables, the VM or the
    /// collector" a build error rather than a review comment.
    repr: *std.Build.Module,
};

fn makeRuntimeGraph(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options: BuildOptions,
    image_source: ?std.Build.LazyPath,
) ?RuntimeGraph {
    const sel = zigSelection(options);
    if (!sel.any()) return null;

    // What the build decided, as comptime constants rather than as macros a
    // `@cImport` is asked about. Created first because the subsystems select
    // the value representation and the event-loop backend from it.
    //
    // **One owner per type.** Two `@cImport` blocks over the same header
    // produce distinct, incompatible types -- a `pthread_attr_t` from one is
    // not the one the other holds. `host.zig` is that single owner for the
    // pthread types and it is Zig, which is the stronger form of the same
    // rule. The three host translations under `os/`, `net/` and `filewatch/`
    // each keep what they declare inside one subsystem for the same reason.
    const config_module = makeConfigModule(b, janetConfig(options, target));

    // The value representation. Its own module because `src/root.zig` is a
    // module root and cannot reach a file above itself. The representation is a
    // module below it -- see `RuntimeGraph.repr` for why the import list is the
    // gate.
    const repr_module = b.createModule(.{
        .root_source_file = b.path("src/api/repr.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
    });

    // The module boundary's declarations. In the runtime because `raise.zig`
    // -- which compiles into an author's module as well as into `root` --
    // names `abi.Signal` and `abi.JanetCFunction`. One instance, so that the
    // runtime's `AbstractType` and an author's are one type.
    const abi_module = b.createModule(.{
        .root_source_file = b.path("src/api/abi.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
    });
    abi_module.addImport("repr", repr_module);

    // The shapes the host decides -- `FILE`, the descriptor, the pthread types
    // and Windows' critical section. Still a module rather than a file of
    // `root` because `cabi` names the same six and cannot import a file of
    // `root`; its import list is `std` and `builtin` and nothing else.
    const host_module = b.createModule(.{
        .root_source_file = b.path("src/host/host.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
    });
    // `host.zig` takes the pthread types from libc: `std.c` carries glibc's
    // `pthread_attr_t` and musl's is a different size, which `Vm` embeds.
    host_module.link_libc = true;

    // The constants, opcodes and flags, owned by Zig. Its own module because
    // the bootstrap, the client and the runtime all spell them.
    const constants_module = b.createModule(.{
        .root_source_file = b.path("src/api/constants.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
    });
    constants_module.addImport("config", config_module);
    repr_module.addImport("config", config_module);
    // `constants` goes the other way: the tag is `repr.Tag`, so `constants.zig`
    // reaches *up* for the `JANET_TFLAG_*` shifts and its whole import list is
    // `config` and `repr` -- which is what makes "no allocation, tables, VM or
    // GC in the constants" a build error.
    constants_module.addImport("repr", repr_module);
    // What the runtime calls itself through, in Zig. A subsystem writes
    // `const c = @import("cabi");` and every module that has a `c` needs this
    // import by name.
    const cabi_module = b.createModule(.{
        .root_source_file = b.path("src/host/cabi.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
    });
    configureCModule(b, cabi_module, target, options);
    cabi_module.addImport("config", config_module);
    cabi_module.addImport("host", host_module);
    cabi_module.addImport("repr", repr_module);
    cabi_module.addImport("constants", constants_module);

    const module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        // Linked into the shared library as well as the static one, and ELF
        // shared objects require position-independent code. Mach-O is always
        // position independent, so omitting this only fails on ELF targets.
        .pic = true,
    });
    configureCModule(b, module, target, options);
    module.addImport("cabi", cabi_module);
    module.addImport("host", host_module);
    module.addImport("abi", abi_module);
    module.addImport("repr", repr_module);
    module.addImport("constants", constants_module);
    const selection_module = makeSelectionModule(b, sel);
    module.addImport("options", selection_module);
    module.addImport("config", config_module);

    // The core image, which `core_env.zig` reads with `@embedFile`. It arrives
    // as an import rather than as a linked-in translation unit, which is what
    // keeps the product free of C.
    //
    // Absent for the bootstrap generator, which is the runtime that *produces*
    // an image and would otherwise depend on itself. Nothing needs to be
    // guarded for that: `corefn.bootstrap` is comptime, the branch naming the
    // image is not analysed there, and a container-level declaration nothing
    // references is never resolved.
    if (image_source) |image| module.addAnonymousImport("janet_image", .{ .root_source_file = image });

    // **`raise.zig` and `corefn.zig` are ordinary files of `root`.** They were
    // modules, and being modules is what forced them to call the runtime
    // through its own symbol table: a module reaches only its declared imports,
    // so `raise.signal` could not name `signal.zig` and `corefn` could not name
    // `env.zig`. Twelve exports existed for that and nothing else.
    //
    // They are still module *roots* in the native-module package
    // (`janetModule` above), where the calls they cannot make by import really
    // are symbols. `raise.zig` carries both arms and picks at comptime on
    // `config.native_module`.

    // **The three host translations are not modules.** `os/abi.zig`,
    // `net/abi.zig` and `filewatch/abi.zig` each sit beside the hand-written
    // `.h` they translate and are reached by path from inside the subsystem
    // that owns them -- one importer for `filewatch`, two for `net`, six for
    // `os`, all within the subtree. A module name buys nothing once the file
    // sits where its callers are.
    //
    // A path import inherits the importing module's settings, so the
    // subsystems module's `.pic` covers them -- **checked on
    // `x86_64-linux-gnu` rather than inferred**, since that is where getting
    // it wrong fails, and it fails at link rather than at compile.

    return .{
        .subsystems = module,
        .selection = selection_module,
        .config = config_module,
        .module_config = makeConfigModule(b, blk: {
            var cfg = janetConfig(options, target);
            cfg.native_module = true;
            break :blk cfg;
        }),
        .abi = abi_module,
        .host = host_module,
        .constants = constants_module,
        .cabi = cabi_module,
        .repr = repr_module,
    };
}

/// `@import("options")`: the `Selection` as comptime booleans.
///
/// The root imports what this says is selected, and it is the only reader.
/// Written by reflection rather than as a list, for the reason `Selection.any`
/// is: a list acquires a stale entry the first time a subsystem is added and
/// nothing announces it.
fn makeSelectionModule(b: *std.Build, sel: Selection) *std.Build.Module {
    const step = b.addOptions();
    inline for (@typeInfo(Selection).@"struct".fields) |field| {
        step.addOption(bool, field.name, @field(sel, field.name));
    }
    return step.createModule();
}

fn linkPlatformLibraries(module: *std.Build.Module, os: std.Target.Os.Tag, single_threaded: bool) void {
    switch (os) {
        .windows => {
            module.linkSystemLibrary("ws2_32", .{});
            module.linkSystemLibrary("psapi", .{});
            module.linkSystemLibrary("wsock32", .{});
        },
        .linux => {
            module.linkSystemLibrary("m", .{});
            module.linkSystemLibrary("dl", .{});
            module.linkSystemLibrary("rt", .{});
            if (!single_threaded) module.linkSystemLibrary("pthread", .{});
        },
        .macos, .ios, .tvos, .watchos, .visionos => {
            module.linkSystemLibrary("m", .{});
            module.linkSystemLibrary("dl", .{});
            if (!single_threaded) module.linkSystemLibrary("pthread", .{});
        },
        else => {
            module.linkSystemLibrary("m", .{});
            module.linkSystemLibrary("dl", .{});
            if (!single_threaded) module.linkSystemLibrary("pthread", .{});
        },
    }
}
