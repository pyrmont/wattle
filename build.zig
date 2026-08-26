const std = @import("std");

/// Janet's version, in one place.
///
/// The three numbers were spelled here *and* in `makeConfigHeader`'s format
/// string, kept in step by hand. Phase 12 increment 4 needed the same values in
/// `Config` -- the runtime had been reading them back out of the *translated*
/// `janetconf.h`, which is configuration arriving through the `@cImport` as a
/// value rather than as a predicate -- and a third spelling was one too many.
const version = std.SemanticVersion{ .major = 1, .minor = 41, .patch = 3 };
const version_extra = "-dev";
const version_string = std.fmt.comptimePrint("{d}.{d}.{d}{s}", .{
    version.major, version.minor, version.patch, version_extra,
});
const build_name = "zig";

// `core_sources` -- the forty-four files of `src/core` -- stood here. Phase 10
// Part 18 removed the last symbol any of them defined, and then the twenty-nine
// selector arms that were the only remaining reason to compile one.

// `boot_sources` -- `src/boot/boot.c` and its five smoke tests -- stood here.
// They are `src/zig/boot.zig` and `src/zig/boot_tests.zig` since Part 18;
// `boot.c` held the last `main` written in C anywhere under `src/`.

const test_suites = &.{
    "test/suite-array.janet",
    "test/suite-asm.janet",
    "test/suite-boot.janet",
    "test/suite-buffer.janet",
    "test/suite-bundle.janet",
    "test/suite-capi.janet",
    "test/suite-cfuns.janet",
    "test/suite-compile.janet",
    "test/suite-corelib.janet",
    "test/suite-debug.janet",
    "test/suite-ev.janet",
    "test/suite-ev2.janet",
    "test/suite-ffi.janet",
    "test/suite-filewatch.janet",
    "test/suite-inttypes.janet",
    "test/suite-io.janet",
    "test/suite-marsh.janet",
    "test/suite-math.janet",
    "test/suite-net.janet",
    "test/suite-os.janet",
    "test/suite-parse.janet",
    "test/suite-peg.janet",
    "test/suite-pp.janet",
    "test/suite-specials.janet",
    "test/suite-string.janet",
    "test/suite-strtod.janet",
    "test/suite-struct.janet",
    "test/suite-symcache.janet",
    "test/suite-table.janet",
    "test/suite-tuple.janet",
    "test/suite-unknown.janet",
    "test/suite-value.janet",
    "test/suite-vm.janet",
    "test/suite-zig-interop.janet",
    "test/regalloc-bytecode.janet",
};

// **This file compiles no C, and holds no C flags.** `common_c_flags` was the
// flag set for C compiled into the product and lost its last user at Phase 11
// Part 19; `test_c_flags` was `test/abi.c` and `test/embed.c`'s and lost its
// two at Phase 12 increment 5f. Neither removal was announced by anything,
// because an unreferenced container declaration in `build.zig` is as silent as
// one in a subsystem -- which is the standing reason to write the removal down
// where the declaration was.
//
// `src/` has held no `.c` since Phase 10 Part 18 and `test/` holds none now.
// What remains of C in this tree is four hand-written headers under `src/zig`
// -- `janet_features.h` and the three host translations -- and libc itself,
// which Phase 10's decision 4 keeps deliberately: "no C in the tree" and "no
// libc" are different claims, and only the first is a goal.

// `SubsystemImplementation` -- the `c or zig` enum behind twenty-nine `-D`
// options -- stood here. Phase 10 Part 18 spent the last of those arms: there
// is no C implementation left for one to select, so a flag that could still be
// spelled would select nothing, and rule 21 is about exactly that. Phase 11
// owns whatever remains of the switch bookkeeping.

const BuildOptions = struct {
    /// Set only for the object set the bootstrap image generator is built
    /// from. Phase 10 Part 6 gave Zig subsystems a reason to care: a core
    /// cfunction table carries docstrings in the generator and not in the
    /// runtime, and `src/zig/corefn.zig` reads `JANET_BOOTSTRAP` to decide.
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
    simple_getline: bool,
    epoll: bool,
    kqueue: bool,
    interpreter_interrupt: bool,
    ffi: bool,
    ffi_jit: bool,
    filewatch: bool,
    cryptorand: bool,
    computed_gotos: bool,
    recursion_guard: i32,
    max_proto_depth: i32,
    max_macro_expand: i32,
    stack_max: i32,
    os_name: ?[]const u8 = null,
    arch_name: ?[]const u8 = null,
};

/// Which subsystems this configuration answers in Zig.
///
/// One bool per selector, computed once by `zigSelection` and read **once**, by
/// `src/zig/root.zig`, which imports the file each one selects.
///
/// It was read twice until Phase 12 increment 6f. The second reader was
/// `addRuntimeSources`, which defined a matching `JANET_ZIG_*` macro so the C
/// original would guard itself off — and there has been no C original since
/// Phase 10 Part 18, so all sixty-seven macros were being defined for nobody.
/// Before Phase 10 Part 17a the two readers were two separate lists, and a
/// subsystem could be compiled without being guarded off; unifying them was
/// that part's subject, and deleting the C half is what finishes it.
const Selection = struct {
    stretchy: bool,
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
    /// Kept past increment 6f's merge although no `root.zig` import reads it:
    /// `os.zig` guards the four `janet_os_*env*` exports on it, so a
    /// reduced-OS build exports what it always did. Same for `os_time`.
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
    kind: bool,
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
    /// `src/zig/fatal.zig` provides `janet_zig_out_of_memory` and
    /// `janet_zig_fatal`, and nineteen subsystems call one of them. This
    /// condition used to name the ones that did, and the list went stale the
    /// moment an increment added a twentieth: ten of the nineteen were missing
    /// by Phase 8 Part 10, which nothing noticed because the default build
    /// turns every subsystem on and one of the named few was always among
    /// them. Only a build selecting a single unnamed subsystem failed to link,
    /// which is exactly what a differential test does.
    fn any(self: Selection) bool {
        inline for (@typeInfo(Selection).@"struct".fields) |field| {
            if (@field(self, field.name)) return true;
        }
        return false;
    }
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const options = readOptions(b);
    const config_header = makeConfigHeader(b, options);

    // The runtime object is built below rather than here, because since Phase
    // 11 Part 19 it *contains* the core image: `core_env.zig` reaches the
    // generated bytes with `@embedFile` rather than through a symbol the
    // linker resolves against a compiled `janet-image.c`. So the generator has
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
    // `PLAN.md`, and has never been run on a 32-bit target, whose binaries are
    // deliberately not executed.
    //
    // The *OS version* is kept rather than dropped, and Phase 10 Part 12 is
    // what found out why. Naming the arch, the OS tag and the ABI without a
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
        .root_source_file = b.path("src/zig/boot.zig"),
        .target = boot_host,
        .optimize = .Debug,
    });
    configureCModule(b, boot_module, boot_host, config_header, options);
    // The bootstrap compiler is a build-time tool that runs on the host, not a
    // thing under test, and it is built for the host even when -Dtarget names
    // something else. ThreadSanitizer is dropped from it for that reason and
    // for a practical one: Zig's bundled libtsan needs macOS SDK headers it
    // cannot see, so leaving it on makes -Dsanitize-thread fail on this
    // development machine no matter which target was asked for.
    boot_module.sanitize_thread = null;
    boot_module.addCMacro("JANET_BOOTSTRAP", "1");
    // `-Dboot=c` builds the image generator from C whatever the runtime is
    // selected to be, which is the arrangement every phase up to here shipped:
    // the image the Zig runtime embeds was compiled and marshalled by the C
    // one. `-Dboot=zig` gives the generator the same selectors as the runtime,
    // so that `zig build image` can be run both ways and the two images
    // compared. The subsystem objects are built a second time here because
    // they must run on the host -- see `boot_host` above.
    //
    // `JANET_BOOTSTRAP` used to reach only the C registration layer, where it
    // swaps the `JANET_CORE_*` macros in `util.h` for their non-`_S` forms and
    // adds the `math/pi` family in `math.c`. Phase 10 Part 6 gave the Zig side
    // a stake in it: a subsystem that registers a core cfunction carries the
    // docstrings in the generator and not in the runtime, and reaches
    // `janet_cfuns_ext` rather than `janet_core_cfuns_ext`. So the macro now
    // goes to the Zig objects too, through `boot_options`, and
    // `src/zig/corefn.zig` reads it.
    const boot_options = blk: {
        var o = options;
        o.bootstrap = true;
        break :blk o;
    };
    // The generator's own configuration, for the host it runs on rather than
    // for `-Dtarget`, and carrying the same `bootstrap = true` as the macro
    // above. The module compiles with `JANET_BOOTSTRAP` defined, so `Config`
    // must say so too, or the two halves of one build disagree about which
    // registration shape `corefn.zig` is emitting.
    // The graph already built one for `boot_host` from the same inputs;
    // a second instance puts the generated file in two modules at once.

    // `-Dboot=c` went with the cfunction arms in Part 17g. The image generator
    // registers the whole core environment, so it needed every C cfunction
    // there is; a C body cannot be a cfunction any more, and neither can the
    // generator be C. What goes with it is the byte-equality check between the
    // two generators, which was the last differential above the subsystems.
    // The graph is kept rather than discarded into `makeZigRuntimeObject`,
    // because `boot_tests.zig` spells Janet types and a module reaches
    // `types.zig` only through a named import. This one is built for
    // `boot_host`, so it needs its own instance for the same reason it
    // already gets its own `config`.
    const boot_graph = makeRuntimeGraph(b, boot_host, .Debug, config_header, boot_options, null);
    addRuntimeSources(
        boot_module,
        if (boot_graph) |g| b.addObject(.{ .name = "janet-zig-boot", .root_module = g.subsystems }) else null,
    );
    if (boot_graph) |g| {
        boot_module.addImport("config", g.config);
        boot_module.addImport("types", g.types);
        boot_module.addImport("constants", g.constants);
        boot_module.addImport("cabi", g.cabi);
    }
    const boot = b.addExecutable(.{ .name = "janet-boot", .root_module = boot_module });

    // The generator writes the image to a path it is handed rather than to
    // stdout, which it did while the output was C text. Part 19 made the
    // output a marshalled byte stream, and a byte stream through a captured
    // stdout is one text-mode host away from a translated 0x0A.
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
    const runtime_graph = makeRuntimeGraph(b, target, optimize, config_header, options, image_source);
    const zig_runtime = if (runtime_graph) |g|
        b.addObject(.{ .name = "janet-zig", .root_module = g.subsystems })
    else
        null;

    const static_module = makeRuntimeModule(b, target, optimize, config_header, options, zig_runtime);
    const static_library = b.addLibrary(.{
        .name = "janet",
        .linkage = .static,
        .version = version,
        .root_module = static_module,
    });
    // **No header is installed, and that is Phase 12 increment 5f's deliberate
    // gap.** `janet.h` and the generated `janetconf.h` were installed here, and
    // `janet.h` is gone: what a C caller sees is Phase 13's subject, written as
    // `capi.zig` and generated from it, so installing the retired header --
    // the one whose declarations nothing checked against their definitions --
    // would have shipped the migration's scaffold as the interface.
    b.installArtifact(static_library);

    const shared_module = makeRuntimeModule(b, target, optimize, config_header, options, zig_runtime);
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

    // Compile the runtime directly into the Zig client so all public API
    // symbols remain available to dynamically loaded Janet modules.
    const client_module = b.createModule(.{
        .root_source_file = b.path("src/zig/cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    configureCModule(b, client_module, target, config_header, options);
    addRuntimeSources(client_module, zig_runtime);
    if (runtime_graph) |g| {
        client_module.addImport("types", g.types);
        client_module.addImport("constants", g.constants);
        client_module.addImport("cabi", g.cabi);
    }
    const client = b.addExecutable(.{ .name = "janet", .root_module = client_module });
    if (target.result.os.tag != .windows) client.rdynamic = true;
    b.installArtifact(client);

    // `janet-c`, the original C shell, stood here. It was Phase 2's comparison
    // target and `port/PLAN.md` had it down to be deleted rather than ported;
    // Part 18 spent it, because `janet_dynprintf` went with the rest of the
    // variadic surface and the shell was its last caller outside the runtime.
    // There has been nothing to compare it against since Part 17g anyway: a
    // cfunction is a Zig function, so no configuration builds a C client.

    const native_module_root = b.createModule(.{
        .root_source_file = b.path("src/zig/native_module.zig"),
        .target = target,
        .optimize = optimize,
    });
    configureCModule(b, native_module_root, target, config_header, options);
    if (runtime_graph) |g| {
        native_module_root.addImport("types", g.types);
        native_module_root.addImport("constants", g.constants);
        native_module_root.addImport("cabi", g.cabi);
        // Phase 12 increment 5e: `janet_config_current` was a `janet.h` macro
        // that `cabi.zig` carried as translate-c's rendering. It is written
        // out at the one call site now, and the version quintet it reads is
        // `config`'s -- which this module had no reason to name until then.
        native_module_root.addImport("config", g.config);
    }
    const native_module = b.addLibrary(.{
        .name = "janet-zig-native",
        .linkage = .dynamic,
        .root_module = native_module_root,
    });
    native_module.linker_allow_shlib_undefined = true;
    // Dynamic module loading is platform-specific, so ship this alongside the
    // test executables for cross-platform runs.
    installTest(b, options, native_module);

    // `zig build translate` stood here. It ran the same headers `abi.zig`
    // translated through the same include paths and installed the result as
    // `zig-out/translated.zig`, because a `@cImport` leaves no artefact a
    // script can read -- which is how `src/zig/types.zig` and
    // `src/zig/constants.zig` came to hold the compiler's reading of the C
    // rather than a person's, per configuration. Phase 12 increment 5f deleted
    // the headers it ran, so the step has nothing to translate.
    //
    // The three host translations that remain -- `os/abi.h`, `net/abi.h`,
    // `filewatch/abi.h` -- had no oracle and needed none: each keeps what it
    // declares inside one subsystem, and every name it publishes has a Zig
    // caller that fails to compile when the translation stops providing it.

    const run_step = b.step("run", "Run Janet");
    const run_client = b.addRunArtifact(client);
    run_client.setCwd(b.path("."));
    if (b.args) |args| run_client.addArgs(args);
    run_step.dependOn(&run_client.step);

    // The name is Phase 3's and outlived its subject: there is no mixed runtime
    // and no `subsystems/` directory. It is an alias of `zig-contract-test`,
    // kept because `port/testing.md` and `port/phase_4.md` cite it.
    const subsystem_step = b.step("subsystem-test", "Run the contracts (alias of zig-contract-test)");

    // **`zig build abi-test` is gone, and so are its three binaries.** Phase 12
    // increment 5f. `janet-c-abi-test` (`test/abi.c`) and `janet-embed-test`
    // (`test/embed.c`) were the two C programs that proved a C caller could see
    // `janet.h`'s layout and link against the library, and `janet-zig-abi-test`
    // (`src/zig/abi_test.zig`) compared hand-written Zig layouts against the
    // translation of the same header. All three ask a question about a header
    // that no longer exists.
    //
    // The question they asked is a real one and Phase 13 is where it comes
    // back: `capi.zig` is what a C caller sees, and a C program that includes
    // the generated header and links the library is how that gets checked.
    // Restoring it here against the retired header would have checked the
    // migration's own scaffold.

    // There is no C contract driver any more. Phase 11 Part 22 took the last
    // `test/*.c` contract, and `test/contracts.c`, `test/contracts.h`,
    // `test/support.h` and `test/support.zig` went with it -- the driver, its
    // list, and the adapter object that let C call and define a cfunction that
    // has not been a C function since Phase 10 Part 17g.
    //
    // What that removes from this file, beyond the target: one C module linked
    // against the static library, a second `abi` translation and the `raise`
    // and `abstract_type` modules built on it for the adapter, and the
    // unconditional install of `janet-contract-support.o` that the narrow
    // contract loop needed as a link input. `port/contract.sh` and
    // `port/matrix.janet` no longer `zig cc` anything: a contract by name is
    // `zig-out/bin/janet-zig-contract-test <name>`.

    // The Zig contracts, in the runtime's own compilation.
    //
    // Phase 11 Part 1. The executable above links `libjanet.a`, so every call
    // it makes crosses the C ABI and a raise reaches it as the out-of-band
    // report `janet_zig_c_raise_*` carries -- the last of the migration
    // scaffold, and what this phase is here to delete. A contract cannot stop
    // needing that report while it is on the far side of a symbol table, so
    // this binary puts it on the near side: `makeRuntimeGraph` again, with
    // `test/contracts.zig` as the root and the subsystems as an import.
    //
    // What that costs is one more compilation of the runtime, and what it buys
    // is that a contract calls its subject the way a subsystem calls its
    // neighbour -- by import, with `try` -- so no face, no adapter pool, and no
    // flag stand between the two. Both drivers run until `test/` holds no `.c`;
    // then this one is the only one.
    checkContractsListed(b);
    const zig_contracts_step = b.step(
        "zig-contract-test",
        "Run the contracts that live in the runtime's compilation",
    );
    if (makeRuntimeGraph(b, target, optimize, config_header, options, image_source)) |graph| {
        const module = b.createModule(.{
            .root_source_file = b.path("test/contracts.zig"),
            .target = target,
            .optimize = optimize,
        });
        configureCModule(b, module, target, config_header, options);
        // The image needs no mention here since Part 19. It used to be a C
        // translation unit this module compiled for itself, for the same
        // reason the library compiled one: a runtime without an image cannot
        // `janet_init`. It is inside `graph.subsystems` now.
        module.addImport("cabi", graph.cabi);
        module.addImport("raise", graph.raise);
        module.addImport("corefn", graph.corefn);
        module.addImport("options", graph.selection);
        module.addImport("config", graph.config);
        module.addImport("types", graph.types);
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
        // instrument here. `port/contract.sh` runs one contract by name, and
        // for a Zig contract that is this binary with an argument rather than
        // a `zig cc` of its own -- there is no source for a shallow link to
        // compile, and no link either, because the runtime it tests is inside.
        b.getInstallStep().dependOn(&b.addInstallArtifact(exe, .{}).step);
        const run = b.addRunArtifact(exe);
        run.setCwd(b.path("."));
        zig_contracts_step.dependOn(&run.step);
    }
    subsystem_step.dependOn(zig_contracts_step);

    // The fuzz targets, in a third compilation of the runtime.
    //
    // Phase 11 Part 23, replacing `test/fuzzers/*.c`. They need their own
    // artifact rather than a place in the contract driver because
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
    if (makeRuntimeGraph(b, target, optimize, config_header, options, image_source)) |graph| {
        const module = b.createModule(.{
            .root_source_file = b.path("test/fuzz.zig"),
            .target = target,
            .optimize = optimize,
        });
        configureCModule(b, module, target, config_header, options);
        module.addImport("cabi", graph.cabi);
        module.addImport("raise", graph.raise);
        module.addImport("corefn", graph.corefn);
        module.addImport("options", graph.selection);
        module.addImport("config", graph.config);
        module.addImport("types", graph.types);
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

    const test_step = b.step("test", "Run Janet's contracts and test suites");
    test_step.dependOn(subsystem_step);
    test_step.dependOn(fuzz_step);
    addCliChecks(b, test_step, client);

    // The native-module fixture is a dynamic library and is skipped under TSan
    // for the same reason the shared library is; see there.
    if (options.dynamic_modules and target.result.os.tag != .windows and !options.sanitize_thread) {
        const run_native_test = b.addRunArtifact(client);
        run_native_test.setCwd(b.path("."));
        run_native_test.addArg("test/zig-native.janet");
        run_native_test.addFileArg(native_module.getEmittedBin());
        test_step.dependOn(&run_native_test.step);
    }

    inline for (test_suites) |suite| {
        const run_suite = b.addRunArtifact(client);
        run_suite.setCwd(b.path("."));
        run_suite.addArg(suite);
        test_step.dependOn(&run_suite.step);
    }
}

/// Every `test/*.zig` that is a contract must be named in `test/contracts.zig`.
///
/// Phase 11 Part 1, and the reason it is a check rather than a habit is the
/// shape of the work this phase is: sixty-odd contracts move from C to Zig one
/// at a time, and each move is three edits — delete `test/<name>.c`, drop its
/// line from `build.zig` and `test/contracts.h`, add `test/<name>.zig` and a
/// line to `test/contracts.zig`. Forget the last of those and **the tree is
/// green with a contract that never runs**. Nothing else would say so: the C
/// driver no longer compiles it and the Zig driver never heard of it.
///
/// This is `AGENTS.md`'s own lesson about `matrix.janet`'s preflight, applied
/// before the mistake rather than after it: "a check that runs before the
/// first build is worth more than a paragraph that runs before the first
/// mistake." It costs one directory read.
///
/// Deliberately crude, in the way `checkJumpTransparency` was: a substring
/// search for the file's name in the driver's source. It cannot tell a live
/// entry from one inside a comment, and it does not need to — what it is
/// looking for is a file nobody has mentioned at all.
fn checkContractsListed(b: *std.Build) void {
    // Not contracts: the driver itself and the shared helpers. `support.zig`
    // was the third until Phase 11 Part 22 deleted it with the C driver.
    const exempt = [_][]const u8{ "contracts.zig", "harness.zig", "fuzz.zig" };

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
    // One client, not two. `janet-c` was the other, and Part 18 deleted it
    // with `src/mainclient/shell.c`.
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
    const pointer_shift = b.option(i32, "nanbox-pointer-shift", "Override the NaN-box pointer shift (0 through 4)");
    if (pointer_shift) |shift| {
        if (shift < 0 or shift > 4) @panic("-Dnanbox-pointer-shift must be between 0 and 4");
    }

    const options: BuildOptions = .{
        .install_tests = b.option(bool, "install-tests", "Install the C contract test executables so they can be run on another machine") orelse false,
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
        .simple_getline = b.option(bool, "simple-getline", "Use simple line input") orelse false,
        .epoll = b.option(bool, "epoll", "Enable the epoll backend") orelse true,
        .kqueue = b.option(bool, "kqueue", "Enable the kqueue backend") orelse true,
        .interpreter_interrupt = b.option(bool, "interpreter-interrupt", "Enable interpreter interrupts") orelse true,
        .ffi = b.option(bool, "ffi", "Enable FFI") orelse true,
        .ffi_jit = b.option(bool, "ffi-jit", "Enable the FFI JIT") orelse true,
        .filewatch = b.option(bool, "filewatch", "Enable file watching") orelse true,
        .cryptorand = b.option(bool, "cryptorand", "Enable cryptographic random bytes") orelse true,
        // Off under both selectors, including the Zig one. Phase 7 decided this
        // would flip on in the increment that first put a Zig frame on the VM
        // call path; Phase 9 Part 3 reversed that on SPIKE-8's rule, which is
        // later than the decision, plus a measurement. port/phase_9.md
        // has the reasoning. Still selectable, and still in the per-increment
        // acceptance set, so the scoped path stays exercised and measurable.
        .computed_gotos = b.option(bool, "computed-gotos", "Dispatch run_vm with computed gotos where the compiler has them; -Dcomputed-gotos=false forces the switch, for measuring dispatch shape (see SPIKE-9.md)") orelse true,
        .recursion_guard = b.option(i32, "recursion-guard", "C recursion guard") orelse 1024,
        .max_proto_depth = b.option(i32, "max-proto-depth", "Maximum prototype lookup depth") orelse 200,
        .max_macro_expand = b.option(i32, "max-macro-expand", "Maximum macro expansion depth") orelse 200,
        .stack_max = b.option(i32, "stack-max", "Maximum Janet stack size") orelse 0x7fffffff,
        // `os/which` and `os/arch` overrides. Until Phase 12 increment 1 these
        // were `JANET_OS_NAME` and `JANET_ARCH_NAME`, bare tokens a user set in
        // a hand-written `janetconf.h` and `src/zig/state_abi.h` stringified
        // because translate-c cannot recover an identifier's text. A build
        // option is where they have to come from once the header is not
        // installed, and it removes the stringify dance with them.
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

fn makeConfigHeader(b: *std.Build, options: BuildOptions) std.Build.LazyPath {
    // Its own `b.fmt` because the main one is at Zig's 32-argument limit for a
    // format call, and six more would exceed it.
    const version_block = std.fmt.comptimePrint(
        \\#define JANET_VERSION_MAJOR {d}
        \\#define JANET_VERSION_MINOR {d}
        \\#define JANET_VERSION_PATCH {d}
        \\#define JANET_VERSION_EXTRA "{s}"
        \\#define JANET_VERSION "{s}"
        \\#define JANET_BUILD "{s}"
        \\
    , .{ version.major, version.minor, version.patch, version_extra, version_string, build_name });
    const header = b.fmt(
        \\#ifndef JANETCONF_H
        \\#define JANETCONF_H
        \\{s}{s}{s}{s}{s}{s}{s}{s}{s}{s}{s}{s}{s}{s}{s}{s}{s}{s}{s}{s}{s}{s}{s}{s}{s}
        \\#define JANET_RECURSION_GUARD {d}
        \\#define JANET_MAX_PROTO_DEPTH {d}
        \\#define JANET_MAX_MACRO_EXPAND {d}
        \\#define JANET_STACK_MAX {d}
        \\{s}{s}#endif
        \\
    , .{
        version_block,
        defineIf(options.single_threaded, "JANET_SINGLE_THREADED"),
        defineIf(!options.nanbox, "JANET_NO_NANBOX"),
        if (options.nanbox_pointer_shift) |shift| b.fmt("#define JANET_NANBOX_64_POINTER_SHIFT {d}\n", .{shift}) else "",
        defineIf(!options.dynamic_modules, "JANET_NO_DYNAMIC_MODULES"),
        defineIf(!options.docstrings, "JANET_NO_DOCSTRINGS"),
        defineIf(!options.sourcemaps, "JANET_NO_SOURCEMAPS"),
        defineIf(options.reduced_os, "JANET_REDUCED_OS"),
        defineIf(!options.assembler, "JANET_NO_ASSEMBLER"),
        defineIf(!options.peg, "JANET_NO_PEG"),
        defineIf(!options.int_types, "JANET_NO_INT_TYPES"),
        defineIf(options.prf, "JANET_PRF"),
        defineIf(!options.net, "JANET_NO_NET"),
        defineIf(!options.ipv6, "JANET_NO_IPV6"),
        defineIf(!options.ev or options.single_threaded, "JANET_NO_EV"),
        defineIf(!options.processes, "JANET_NO_PROCESSES"),
        defineIf(!options.umask, "JANET_NO_UMASK"),
        defineIf(!options.realpath, "JANET_NO_REALPATH"),
        defineIf(options.simple_getline, "JANET_SIMPLE_GETLINE"),
        defineIf(!options.epoll, "JANET_EV_NO_EPOLL"),
        defineIf(!options.kqueue, "JANET_EV_NO_KQUEUE"),
        defineIf(!options.interpreter_interrupt, "JANET_NO_INTERPRETER_INTERRUPT"),
        defineIf(!options.ffi, "JANET_NO_FFI"),
        defineIf(!options.ffi_jit, "JANET_NO_FFI_JIT"),
        defineIf(!options.filewatch, "JANET_NO_FILEWATCH"),
        options.recursion_guard,
        options.max_proto_depth,
        options.max_macro_expand,
        options.stack_max,
        defineIf(!options.cryptorand, "JANET_NO_CRYPTORAND"),
        defineIf(!options.computed_gotos, "JANET_NO_COMPUTED_GOTOS"),
    });
    const generated = b.addWriteFiles();
    return generated.add("janetconf.h", header);
}

fn defineIf(enabled: bool, comptime name: []const u8) []const u8 {
    return if (enabled) "#define " ++ name ++ "\n" else "";
}

/// What the build decided, as comptime facts for `@import("config")`.
///
/// **Phase 12 increment 1.** Until here the Zig runtime learned its own
/// configuration by asking the `@cImport` — `@hasDecl(c, "JANET_PEG")` and 53
/// more like it — which made `janet.h` not merely the declaration surface but
/// the place the configuration was *resolved*. The header cannot be retired
/// while that is true, so this struct is where the resolution moves.
///
/// **The positives are computed here because the preprocessor could not
/// compute them.** `makeConfigHeader` emits negatives (`JANET_NO_PEG`,
/// `JANET_EV_NO_EPOLL`) because `#ifndef` is the only tool a config header
/// has, and `janet.h` then derives the positive form from the absence of the
/// negative, with the platform folded in. That derivation is reproduced below,
/// clause for clause, against `src/include/janet.h`'s "Enable or disable"
/// block. It has to be exact: the C types this runtime still uses are declared
/// inside those same `#ifdef`s, so a `Config` that disagrees with the header
/// would compile Zig against a struct the header did not declare.
///
/// Four facts that were macros are *not* fields here — `JANET_32`/`JANET_64`,
/// `JANET_BIG_ENDIAN`, `JANET_WINDOWS` and `JANET_PLAN9`. Those are properties
/// of the target, and `janet.h` recovers them by testing a hand-maintained
/// list of architecture macros with a fallback (its endianness check *assumes
/// big-endian* when it recognises nothing). `@import("builtin")` knows them
/// exactly, so the call sites read `builtin` and the guesswork goes.
/// Which of the three value representations this build compiles.
///
/// `value_wrap.zig` used to recover this by asking whether the *translated*
/// `Janet` had an `as` or a `tagged` field — reading the layout off the shape
/// of a C type, which is the sharpest form of the problem increment 1 exists
/// to fix: it made `janet.h` the place the value representation was decided.
///
/// `DESIGN.md` §7 drops `nanbox_32` and renames the option to `-Dvalue-repr`.
/// Neither is done here: this increment moves where the answer comes from and
/// changes no answer.
const ValueRepr = enum { nanbox_64, nanbox_32, tagged };

const Config = struct {
    bootstrap: bool,
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

    /// The two `src/zig/state_abi.h` restates that had no `Config` field.
    ///
    /// **Phase 12 increment 4, and they are increment 1's clause unmet.** That
    /// increment swept for `@hasDecl(c, "JANET_*")` and `@hasField(c.Janet,
    /// ...)` — the forms in which the runtime asked the `@cImport` a
    /// *question*. Configuration also reached Zig as an *answer*:
    /// `state_abi.h` exists to turn `#ifdef JANET_EV` into `#define
    /// JANET_VM_HAS_EV 1`, precisely because "translate-c does not surface a
    /// macro defined with no value", and `vm_state.zig` and eleven others
    /// then read `c.JANET_VM_HAS_EV != 0`. A grep for `@hasDecl` cannot see
    /// that. See `phase_12.md`'s rule 16.
    single_threaded: bool,
    interpreter_interrupt: bool,

    /// `janetconf.h`'s, for the same reason: the runtime read every one of
    /// these back out of the translated header. `boot_tests.zig` compares the
    /// version quintet, `core_env.zig` publishes `janet/build`, and the four
    /// limits are read at nineteen, eleven, one and two sites.
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

    /// `janet.h`'s `JANET_64`/`JANET_32`, which it recovers by testing a
    /// hand-maintained list of architecture macros. A field rather than
    /// `@sizeOf(usize)` at the call site because `test/ffi_layout.zig` says
    /// why: a contract wants "the same input the subject reads, rather than
    /// the subject's answer, and rather than `@sizeOf(usize)`, which is a
    /// different question that happens to agree here".
    bits64: bool,
    value_repr: ValueRepr,
    nanbox_pointer_shift: i32,
    os_name: ?[]const u8,
    arch_name: ?[]const u8,

    /// Five predicates the Zig runtime reads that **nothing in this tree ever
    /// defines**, carried as constants so the migration changes no behaviour.
    /// Found by this increment, and they are rule 72's class: a comptime-false
    /// condition means the branch behind it has never been analysed.
    ///
    ///   - `spawn`/`symlinks`/`locales` are upstream `janetconf.h` options
    ///     `build.zig` has no `-D` for, so they have been pinned on since the
    ///     port began.
    ///   - `debug` is `JANET_DEBUG`, which `value/fibers.zig` documents as
    ///     "edited in by hand to shake out use-after-free by moving the stack
    ///     on every frame push". It must **not** be wired to
    ///     `builtin.mode == .Debug`: that would reallocate the fiber stack on
    ///     every frame push in every Debug build.
    ///
    /// `JANET_PLAN9` was the sixth and is the one that improves by moving:
    /// it becomes `builtin.os.tag == .plan9` at the call site, false for every
    /// target built here and correct for the one it names.
    spawn: bool = true,
    symlinks: bool = true,
    locales: bool = true,
    debug: bool = false,
};

/// Reproduces `src/include/janet.h`'s derivation with the target folded in.
///
/// Each line cites the header clause it mirrors. Changing one without changing
/// the header is how the two come to disagree, and the disagreement is silent
/// until a C type declared inside the matching `#ifdef` fails to resolve.
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

    // `#if !defined(JANET_NO_EV) && !defined(__EMSCRIPTEN__)`, plus
    // `makeConfigHeader`'s own extra clause: it emits JANET_NO_EV when the
    // build is single-threaded, so the event loop is off there too.
    const ev = options.ev and !options.single_threaded and !emscripten;
    // `#ifndef JANET_NO_FFI` / `#if !defined(__EMSCRIPTEN__)`
    const ffi = options.ffi and !emscripten;
    // `#if defined(JANET_LINUX) && !defined(JANET_EV_NO_EPOLL)`
    const ev_epoll = linux and options.epoll;
    // the JANET_BSD and JANET_APPLE clauses, which define the same macro
    const ev_kqueue = (bsd or apple) and options.kqueue;

    return .{
        .bootstrap = options.bootstrap,
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
        // `#if !defined(JANET_WINDOWS) && !defined(JANET_EV_EPOLL) && !defined(JANET_EV_KQUEUE)`
        .ev_poll = !windows and !ev_epoll and !ev_kqueue,
        .ipv6 = options.ipv6,
        .bits64 = target.result.ptrBitWidth() == 64,
        // `janet.h`: JANET_NO_NANBOX gives the tagged struct; otherwise the
        // pointer width picks between the two NaN-boxed unions.
        .value_repr = if (!options.nanbox)
            .tagged
        else if (target.result.ptrBitWidth() == 64)
            .nanbox_64
        else
            .nanbox_32,
        // `#if (defined(_M_ARM64) || defined(__aarch64__)) && !defined(JANET_APPLE)`
        // — aarch64 that is **not** Apple, because aarch64 macOS uses the same
        // 47-bit userland address space as amd64 and so needs no shift. The
        // option overrides it either way. Carried as a number rather than a
        // predicate because `registry.zig` compares it to zero.
        //
        // **This clause was written inverted in increment 1** — `apple and
        // aarch64` — and increment 4 found it by comparing `Config` against the
        // translated header per configuration. `checkPointerAlign` guarded on
        // this field while masking with `c.JANET_NANBOX_64_POINTER_SHIFT`, so
        // on aarch64 Linux the guard returned early and the alignment check was
        // off on the only targets that shift, while on aarch64 macOS it ran
        // with a zero mask and checked nothing. `constants_check.zig` now holds
        // the two together.
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
    config_header: std.Build.LazyPath,
    options: BuildOptions,
) *std.Build.Module {
    const module = b.createModule(.{ .target = target, .optimize = optimize });
    configureCModule(b, module, target, config_header, options);
    return module;
}

fn configureCModule(
    b: *std.Build,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    config_header: std.Build.LazyPath,
    options: BuildOptions,
) void {
    // `src/zig` alone since Phase 12 increment 5f. It was `src/include` for
    // `janet.h`, `src/core` for the internal headers `state_abi.h` reached
    // (added separately, by `addAbiIncludePath`), and `src/zig` for the
    // hand-written translation headers. Only the last of those still exists:
    // `os/abi.h`, `net/abi.h`, `filewatch/abi.h` and the `janet_features.h`
    // the four of them open with, which moved up from `src/core` when that
    // directory emptied.
    module.addIncludePath(b.path("src/zig"));
    module.addIncludePath(config_header.dirname());
    if (options.bootstrap) module.addCMacro("JANET_BOOTSTRAP", "1");
    module.linkSystemLibrary("c", .{});
    applySanitizers(module, options);
    linkPlatformLibraries(module, target.result.os.tag, options.single_threaded);
}

/// The sanitizer configuration Phase 8's exit gate names, applied to every
/// module the build makes -- the C runtime, the Zig subsystems, and the
/// contract binaries alike.
///
/// **`sanitize_c` is set explicitly rather than left to the optimize mode.**
/// Zig turns C undefined-behaviour checking on in Debug and ReleaseSafe by
/// itself, and the tree had been relying on that: the `janet_vm` misalignment
/// in `FOUND.md` was found by a check nobody had asked for. A check that fires
/// by luck is not a gate, and the default is `.trap`, which aborts on a bare
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
    config_header: std.Build.LazyPath,
    options: BuildOptions,
    zig_runtime: ?*std.Build.Step.Compile,
) *std.Build.Module {
    const module = makeCModule(b, target, optimize, config_header, options);
    addRuntimeSources(module, zig_runtime);
    return module;
}

fn addRuntimeSources(
    module: *std.Build.Module,
    zig_runtime: ?*std.Build.Step.Compile,
) void {
    // The image used to be added here, as the generated `janet-image.c`. It is
    // inside `zig_runtime` now -- an `@embedFile` in `core_env.zig` reached
    // through `makeRuntimeGraph`'s anonymous import -- so a module that takes
    // the object takes the image with it, and this function no longer has an
    // opinion about either.

    // The two whole-file swaps used to be here: `if (!sel.vector)` compiled
    // `src/core/vector.c` and `if (!sel.regalloc)` compiled
    // `src/core/regalloc.c`, because neither guarded its C original off with a
    // macro. `zigSelection` has said `.vector = true` and `.regalloc = true`
    // literally since Phase 10 Part 18 deleted both files, so both branches
    // named a source that is not there and neither could be taken. `build.zig`
    // is an ordinary program, so nothing diagnosed that -- rule 31's silence
    // in the build script rather than in a subsystem. Taken with Part 19
    // because this function's whole remaining subject was which C to compile.
    //
    // The `Selection` fields stay: `makeSelectionModule` publishes them and
    // `containers.zig` and its neighbours read them to pick an import.

    // **The sixty-seven `JANET_ZIG_*` macros stood here until Phase 12
    // increment 6f.** Each guarded a C original off, and there is no C original
    // left: `src/` has held zero `.c` files since Phase 10 Part 18, and nothing
    // in `src/include`, `src/core`, `test/` or the generated config header ever
    // read one. (`os/abi.h` and `net/abi.h` define names with the same prefix --
    // include guards, `JANET_ZIG_PATH_MAX`, `JANET_ZIG_MSG_NOSIGNAL` -- and
    // those are unrelated and live.)
    //
    // They were found on the way into 6f's first merge, which would otherwise
    // have had to decide what becomes of `JANET_ZIG_ASM_CORE` when `asm_core`
    // and `asm_encode` become `bytecode.zig`. The answer is that the question
    // was already void, and every merge in the increment is free of it.
    //
    // **The `Selection` fields stay.** They are what `makeSelectionModule`
    // publishes and what `src/zig/root.zig` reads as `options.<name>` to decide
    // which subsystems to import; only the C half of each selector is gone.

    // One object rather than sixty-three, which is Part 17a's whole subject.
    if (zig_runtime) |object| module.addObject(object);
}

/// Which subsystems this configuration answers in Zig.
///
/// Every condition the build makes about a subsystem is here, and nowhere else.
/// Three kinds appear:
///
///  - the selector itself, `-Dargs-core=zig`;
///  - a feature gate, where the subsystem has nothing to do in a build that
///    turned its feature off — `-Dffi=false` leaves `ffi_layout.zig` with no
///    types to name, and `-Dpeg=false` leaves `peg.zig` without `JanetPeg`,
///    which `janet.h` declares inside its own `#ifdef`;
///  - a reduced-OS gate, where `os.c` does not compile the region either.
fn zigSelection(options: BuildOptions) Selection {
    return .{
        .stretchy = true,
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
        .kind = true,
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

/// `src/core/janet_features.h` defines JANET_EV unless JANET_NO_EV is set, which
/// `makeConfigHeader` does for a build that disables the event loop or is
/// single-threaded. `janet.h` gates its whole event-loop surface on it, so the
/// header and the subsystem agree about whether there is one.
fn hasEv(options: BuildOptions) bool {
    return options.ev and !options.single_threaded;
}

/// `src/core/filewatch.c` is wrapped in JANET_EV and JANET_FILEWATCH, so the
/// keyword vocabularies exist only when both are on. The subsystem compiles all
/// three backends' names on every target, but there is nothing to compile them
/// for when the file watcher itself is absent.
/// `src/core/net.c` is wrapped in JANET_NET, which `janet.h` defines only when
/// JANET_EV is on and JANET_NO_NET is off. So the socket layer exists exactly
/// when the event loop does and networking was not turned off.
fn hasNet(options: BuildOptions) bool {
    return hasEv(options) and options.net;
}

fn hasFilewatch(options: BuildOptions) bool {
    return hasEv(options) and options.filewatch;
}

/// Build the runtime's Zig object: one compilation holding every subsystem
/// this configuration answers in Zig.
///
/// Several *modules*, one *compilation*, one object. The modules below --
/// `abi`, `raise`, `corefn`, `options` and the three host-header translations
/// -- are namespaces and settings scopes rather than compile barriers, and an
/// error union crosses them freely; `raise.Error` always did. What it could
/// not cross was the boundary between two `addObject`s, because a symbol table
/// is the only thing that joins those and a symbol has a calling convention.
///
/// **This was sixty-three objects until Phase 10 Part 17a**, one per selector,
/// each with its own `abi`, `raise` and `corefn` modules and its own entry in a
/// `RuntimeSubsystems` struct. The reason for collapsing them is not tidiness:
/// a call between two objects is resolved by the linker, which is to say across
/// the C ABI, and Zig will not put an error union on a C-ABI function. So every
/// raise that crossed a selector boundary had to be a `longjmp`, and the third
/// `setjmp` could not go while any remained. `src/zig/root.zig` has
/// the fuller statement.
///
/// What that removes here is the six special constructors this file used to
/// carry -- for the interpreter loop, the printer, the OS surface, the FFI, the
/// event loop and the sockets -- each of which existed to fold *some* modules
/// together so that a `raise.Error` could cross between them. Folding is now
/// the default and there is nothing left to arrange: a subsystem reaches its
/// neighbour with an ordinary `@import`, and the import graph lives in the
/// sources rather than being wired up here.
///
/// Split out of `build` so the bootstrap compiler can have an object of its
/// own. `-Dboot=zig` builds this a second time for the *host* rather than for
/// `-Dtarget`: `janet-boot` is a build-time tool that runs on the build
/// machine, so it has to be a host binary whatever `-Dtarget` says. Nothing is
/// given up by that, because the image it emits is architecture-neutral -- see
/// the `boot_host` comment in `build`, which is why cross-compiling works at
/// all.
///
/// Returns null when no subsystem is Zig, which is `-Dall=c`: there is then
/// nothing to compile and nothing for the C runtime to link against.
fn makeZigRuntimeObject(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    config_header: std.Build.LazyPath,
    options: BuildOptions,
    image_source: ?std.Build.LazyPath,
) ?*std.Build.Step.Compile {
    const graph = makeRuntimeGraph(b, target, optimize, config_header, options, image_source) orelse return null;
    return b.addObject(.{ .name = "janet-zig", .root_module = graph.subsystems });
}

/// The runtime's module graph, before anything decides what to make of it.
///
/// Two things are made of it, and the second is why this is separate from
/// `makeZigRuntimeObject`. The runtime wraps it in one `addObject` and links
/// that into the library and the client. **`test/contracts.zig` imports it**,
/// so that a Zig contract and the subsystem it tests are inside one
/// compilation — which is the whole of Phase 11's answer to "how does a
/// contract reach a raise-capable function once the C-ABI faces are gone".
///
/// Part 17a's argument, restated from the test side: the only thing joining
/// two separately compiled objects is a symbol, a symbol has a calling
/// convention, and Zig will not put an error union on a C-ABI function. A
/// contract that links `libjanet.a` therefore cannot see a raise except as the
/// out-of-band report `janet_zig_c_raise_*` carries — which is exactly the
/// mechanism this phase exists to delete. A contract *in* the compilation
/// calls its subject by import and writes `try`.
///
/// The `abi` module is shared rather than rebuilt, and that is load-bearing
/// for the same reason `abi.zig`'s own header comment gives: two `@cImport`
/// blocks over one header produce distinct types, so a contract holding a
/// second translation's `Janet` could not pass it to the subsystem at all.
const RuntimeGraph = struct {
    subsystems: *std.Build.Module,
    raise: *std.Build.Module,
    corefn: *std.Build.Module,
    selection: *std.Build.Module,
    config: *std.Build.Module,
    /// Phase 12 increments 3 and 4. A contract reaches these the same way the
    /// runtime does, for Phase 11 Part 1's reason: it is compiled *into* a
    /// second copy of the runtime, so `test/` spells the same types and the
    /// same constants and holds 5,143 of the 8,795 seam references. A module
    /// the runtime has and the contracts do not is a call-site rewrite that
    /// stops at the `src/` boundary.
    types: *std.Build.Module,
    constants: *std.Build.Module,
    cabi: *std.Build.Module,
};

fn makeRuntimeGraph(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    config_header: std.Build.LazyPath,
    options: BuildOptions,
    image_source: ?std.Build.LazyPath,
) ?RuntimeGraph {
    const sel = zigSelection(options);
    if (!sel.any()) return null;

    // Phase 12 increment 1: what the build decided, as comptime constants
    // rather than as macros a `@cImport` is asked about. Created first because
    // `types.zig` selects the value representation and the event-loop backend
    // from it.
    //
    // **The shared `abi` translation stood here until increment 5f.** It was
    // one `@cImport` of `janet.h` and seven internal headers for the whole
    // object, on the rule that two `@cImport` blocks over the same header
    // produce distinct, incompatible types -- so a `JanetFiber` from one is not
    // the `JanetFiber` the other holds. `types.zig` is that single owner now
    // and it is Zig, which is the stronger form of the same rule. The three
    // host translations under `os/`, `net/` and `filewatch/` remain, and each
    // still keeps what it declares inside one subsystem.
    const config_module = makeConfigModule(b, janetConfig(options, target));

    // Phase 12: the Janet types, owned by Zig rather than translated out of
    // `janet.h`. Its own module because `src/zig/root.zig` is a
    // module root and cannot reach a file above itself.
    const types_module = b.createModule(.{
        .root_source_file = b.path("src/zig/types.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
    });
    types_module.addImport("config", config_module);
    // `types.zig` takes the pthread types from libc: `std.c` carries glibc's
    // `pthread_attr_t` and musl's is a different size, which `JanetVM` embeds.
    types_module.link_libc = true;

    // Phase 12 increment 4: the constants, opcodes and flags, owned by Zig
    // rather than translated. Its own module for the same reason `types.zig`
    // is one.
    const constants_module = b.createModule(.{
        .root_source_file = b.path("src/zig/constants.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
    });
    constants_module.addImport("config", config_module);
    // Phase 12 increment 5b: what the runtime calls itself through, in Zig.
    // Increment 6g spent the re-export `abi.zig` carried, so a subsystem now
    // writes `const c = @import("cabi");` and every module that has a `c`
    // needs this import by name.
    const cabi_module = b.createModule(.{
        .root_source_file = b.path("src/zig/cabi.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
    });
    configureCModule(b, cabi_module, target, config_header, options);
    cabi_module.addImport("config", config_module);
    cabi_module.addImport("types", types_module);
    cabi_module.addImport("constants", constants_module);

    // The two oracles stood here -- `types_check.zig` against the translated
    // types, `constants_check.zig` against the translated constants and
    // `Config` against `janet.h`'s own derivation. Increment 5f spent both
    // with the header they compared against.

    const module = b.createModule(.{
        .root_source_file = b.path("src/zig/root.zig"),
        .target = target,
        .optimize = optimize,
        // Linked into the shared library as well as the static one, and ELF
        // shared objects require position-independent code. Mach-O is always
        // position independent, so omitting this only fails on ELF targets.
        .pic = true,
    });
    configureCModule(b, module, target, config_header, options);
    module.addImport("cabi", cabi_module);
    module.addImport("types", types_module);
    module.addImport("constants", constants_module);
    const selection_module = makeSelectionModule(b, sel);
    module.addImport("options", selection_module);
    module.addImport("config", config_module);

    // The core image, which `core_env.zig` reads with `@embedFile` since Part
    // 19. It arrives as an import rather than as a linked-in `janet-image.c`,
    // which is what took the last C translation unit out of the product.
    //
    // Absent for the bootstrap generator, which is the runtime that *produces*
    // an image and would otherwise depend on itself. Nothing needs to be
    // guarded for that: `corefn.bootstrap` is comptime, the branch naming the
    // image is not analysed there, and a container-level declaration nothing
    // references is never resolved.
    if (image_source) |image| module.addAnonymousImport("janet_image", .{ .root_source_file = image });

    // `raise.zig` and `corefn.zig` hold no `export` and were imported into
    // every object, once per object. One object means one copy, which is the
    // first thing the fold gives back.
    //
    // `raise.zig` can be jumped through -- `janet_zig_signal_record` renders a
    // coercion message with `%v`, which runs an abstract type's `tostring`
    // callback -- so it carries the marker and is in the checked list above.
    const raise_module = b.createModule(.{
        .root_source_file = b.path("src/zig/raise.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
    });
    configureCModule(b, raise_module, target, config_header, options);
    raise_module.addImport("cabi", cabi_module);
    raise_module.addImport("types", types_module);
    raise_module.addImport("constants", constants_module);
    module.addImport("raise", raise_module);

    const corefn_module = b.createModule(.{
        .root_source_file = b.path("src/zig/corefn.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
    });
    configureCModule(b, corefn_module, target, config_header, options);
    corefn_module.addImport("cabi", cabi_module);
    // Since Part 17g `corefn` names `raise.CFunction`: a registration table
    // row and a method table row are both typed by what a cfunction is.
    corefn_module.addImport("raise", raise_module);
    corefn_module.addImport("config", config_module);
    corefn_module.addImport("types", types_module);
    corefn_module.addImport("constants", constants_module);
    module.addImport("corefn", corefn_module);

    // **The three host translations stopped being modules at Phase 12
    // increment 6f.** They are `os/abi.zig`, `net/abi.zig` and
    // `filewatch/abi.zig` now, each beside the hand-written `.h` it translates,
    // and each reached by path from inside the subsystem that owns it -- one
    // importer for `filewatch`, two for `net`, six for `os`, all within the
    // subtree. A module name bought nothing once the file sat where its callers
    // are.
    //
    // The loop that made them set `.pic = true`, because they link into the
    // shared library and ELF requires position-independent code where Mach-O is
    // always position independent. A path import inherits the importing
    // module's settings, so the subsystems module's `.pic` now covers them --
    // **checked on `x86_64-linux-gnu` rather than inferred**, since that is
    // where getting it wrong fails, and it fails at link rather than at
    // compile.

    return .{
        .subsystems = module,
        .raise = raise_module,
        .corefn = corefn_module,
        .selection = selection_module,
        .config = config_module,
        .types = types_module,
        .constants = constants_module,
        .cabi = cabi_module,
    };
}

/// `@import("options")`: the `Selection` as comptime booleans.
///
/// The root imports what this says is selected, and since Phase 12 increment 6f
/// that is the only reader: `addRuntimeSources` used to guard off the C original
/// for the same fields, and there is no C original left. Written by reflection
/// rather than as a list for the reason `Selection.any` is: a list acquires a
/// stale entry the first time an increment adds a selector and nothing
/// announces it.
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
