const std = @import("std");

const version = std.SemanticVersion{ .major = 1, .minor = 41, .patch = 3 };

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

const common_c_flags = &.{
    "-std=c99",
    "-Wall",
    "-Wextra",
    "-fvisibility=hidden",
};

// Test translation units must keep assert() active in every optimize mode. Zig
// defines NDEBUG for C sources in ReleaseFast and ReleaseSmall, which would
// otherwise delete the contract checks along with the calls nested inside them,
// leaving the tests silently vacuous and their call sequences incomplete.
const test_c_flags = &.{
    "-std=c99",
    "-Wall",
    "-Wextra",
    "-fvisibility=hidden",
    "-UNDEBUG",
};

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
};

/// Which subsystems this configuration answers in Zig.
///
/// One bool per selector, computed once by `zigSelection` and read twice: by
/// `addRuntimeSources`, which defines the matching `JANET_ZIG_*` macro so the C
/// original guards itself off, and by `src/zig/subsystems/root.zig`, which
/// imports the file that replaces it. Before Phase 10 Part 17a those were two
/// lists — a condition here and an `addObject` there — and a subsystem could be
/// compiled without being guarded off, or guarded off without being compiled.
/// The two readers now cannot disagree, because there is one list.
const Selection = struct {
    vector: bool,
    utilities: bool,
    registry: bool,
    int_scan: bool,
    text_scan: bool,
    regalloc: bool,
    verify: bool,
    remove_noops: bool,
    movopt: bool,
    emit_core: bool,
    asm_encode: bool,
    asm_decode: bool,
    disasm: bool,
    asm_core: bool,
    compiler_primitives: bool,
    parser_core: bool,
    specials_core: bool,
    builtin_optimizers: bool,
    number_scan: bool,
    math_core: bool,
    int_types_core: bool,
    os_permissions: bool,
    os_platform: bool,
    os_environ: bool,
    os_fs: bool,
    os_stat: bool,
    os_time: bool,
    os_fs_paths: bool,
    io_core: bool,
    os_process: bool,
    os_surface: bool,
    ev_core: bool,
    ev_loop: bool,
    net_sockets: bool,
    ffi_layout: bool,
    ffi_classify: bool,
    ffi_core: bool,
    filewatch_flags: bool,
    filewatch_core: bool,
    args_core: bool,
    gc_alloc: bool,
    gc_mark: bool,
    gc_sweep: bool,
    buffer_array: bool,
    string_symbol: bool,
    struct_table: bool,
    value_order: bool,
    value_access: bool,
    abstract_core: bool,
    value_alloc: bool,
    value_wrap: bool,
    pp: bool,
    marsh: bool,
    peg_engine: bool,
    core_env: bool,
    vm_state: bool,
    fiber_core: bool,
    signal_core: bool,
    trace_frames: bool,
    debug_frames: bool,
    vm_calls: bool,
    vm_run: bool,
    vm_entry: bool,
    vm_lifecycle: bool,

    /// Whether any subsystem at all is answered by Zig, computed by reflection
    /// over the fields rather than from a list.
    ///
    /// `src/zig/subsystems/fatal.zig` provides `janet_zig_out_of_memory` and
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

    const zig_runtime = makeZigRuntimeObject(b, target, optimize, config_header, options);

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
    addAbiIncludePath(b, boot_module);
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
    // `-Dboot=c` went with the cfunction arms in Part 17g. The image generator
    // registers the whole core environment, so it needed every C cfunction
    // there is; a C body cannot be a cfunction any more, and neither can the
    // generator be C. What goes with it is the byte-equality check between the
    // two generators, which was the last differential above the subsystems.
    addRuntimeSources(
        boot_module,
        null,
        boot_options,
        makeZigRuntimeObject(b, boot_host, .Debug, config_header, boot_options),
    );
    const boot = b.addExecutable(.{ .name = "janet-boot", .root_module = boot_module });

    const generate_image = b.addRunArtifact(boot);
    generate_image.setCwd(b.path("."));
    generate_image.addArg(".");
    generate_image.addArgs(&.{ "JANET_PATH", "/usr/local/lib/janet", "image-only" });
    generate_image.addFileInput(b.path("src/boot/boot.janet"));
    const image_source = generate_image.captureStdOut(.{ .basename = "janet-image.c" });

    // The image on its own, so that a build can be asked for the generator's
    // output rather than for something linked against it. Phase 9's gate reads
    // it under `-Dboot=c` and `-Dboot=zig` and compares the bytes.
    const image_step = b.step("image", "Generate the core image and write it to <prefix>/janet-image.c");
    image_step.dependOn(&b.addInstallFile(image_source, "janet-image.c").step);

    const static_module = makeRuntimeModule(b, target, optimize, config_header, image_source, options, zig_runtime);
    const static_library = b.addLibrary(.{
        .name = "janet",
        .linkage = .static,
        .version = version,
        .root_module = static_module,
    });
    static_library.installHeader(b.path("src/include/janet.h"), "janet/janet.h");
    static_library.installHeader(config_header, "janet/janetconf.h");
    b.installArtifact(static_library);

    const shared_module = makeRuntimeModule(b, target, optimize, config_header, image_source, options, zig_runtime);
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
    addAbiIncludePath(b, client_module);
    addRuntimeSources(client_module, image_source, options, zig_runtime);
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
    addAbiIncludePath(b, native_module_root);
    const native_module = b.addLibrary(.{
        .name = "janet-zig-native",
        .linkage = .dynamic,
        .root_module = native_module_root,
    });
    native_module.linker_allow_shlib_undefined = true;
    // Dynamic module loading is platform-specific, so ship this alongside the
    // test executables for cross-platform runs.
    installTest(b, options, native_module);

    const run_step = b.step("run", "Run Janet");
    const run_client = b.addRunArtifact(client);
    run_client.setCwd(b.path("."));
    if (b.args) |args| run_client.addArgs(args);
    run_step.dependOn(&run_client.step);

    const abi_step = b.step("abi-test", "Verify Janet C and Zig ABI assumptions");
    const subsystem_step = b.step("subsystem-test", "Run mixed-runtime subsystem contract tests");

    const c_abi_module = makeCModule(b, target, optimize, config_header, options);
    c_abi_module.addCSourceFiles(.{ .files = &.{"test/abi.c"}, .flags = test_c_flags });
    const c_abi_test = b.addExecutable(.{ .name = "janet-c-abi-test", .root_module = c_abi_module });
    installTest(b, options, c_abi_test);
    const run_c_abi_test = b.addRunArtifact(c_abi_test);
    abi_step.dependOn(&run_c_abi_test.step);

    const embed_module = makeCModule(b, target, optimize, config_header, options);
    embed_module.addCSourceFiles(.{ .files = &.{"test/embed.c"}, .flags = test_c_flags });
    embed_module.linkLibrary(static_library);
    const embed_test = b.addExecutable(.{ .name = "janet-embed-test", .root_module = embed_module });
    installTest(b, options, embed_test);
    const run_embed_test = b.addRunArtifact(embed_test);
    abi_step.dependOn(&run_embed_test.step);

    // Every C contract, in one executable.
    //
    // These were fifty-nine separate ones until Phase 10 Part 11 measured
    // what that cost: compiling all fifty-eight translation units takes six
    // seconds and linking them separately takes thirty, to run about two
    // seconds of assertions. `zig build test` is what the acceptance matrix
    // runs nine times over and what the mutation sweep runs for every mutant
    // that reaches its last judge, so the thirty seconds is paid a great many
    // times per increment. `test/contracts.c` is the driver and
    // `test/contracts.h` the list; the contract *files* stay one per subject.
    //
    // A source that a configuration cannot compile is left out here and its
    // `JANET_CONTRACT_*` macro is left undefined, which is what keeps the
    // driver's list in step with this one. The conditions are the same ones
    // each contract carried when it had an executable of its own.
    const contract_test_module = makeCModule(b, target, optimize, config_header, options);
    contract_test_module.addIncludePath(b.path("src/core"));
    contract_test_module.linkLibrary(static_library);

    var contract_sources: std.ArrayList([]const u8) = .empty;
    contract_sources.append(b.allocator, "test/contracts.c") catch @panic("OOM");

    // `include` adds one contract source and defines the macro that puts it in
    // the driver's table. The macro name is the file's, upper-cased.
    const Contracts = struct {
        fn include(
            builder: *std.Build,
            module: *std.Build.Module,
            list: *std.ArrayList([]const u8),
            comptime name: []const u8,
        ) void {
            list.append(builder.allocator, "test/" ++ name ++ ".c") catch @panic("OOM");
            comptime var upper: [name.len]u8 = undefined;
            comptime for (name, 0..) |ch, i| {
                upper[i] = std.ascii.toUpper(ch);
            };
            module.addCMacro("JANET_CONTRACT_" ++ upper, "1");
        }
    };
    const include = Contracts.include;

    // A contract written in Zig, and the reason there is one.
    //
    // `pp_format.zig`'s drivers take their format string as a `comptime`
    // parameter, so there is no symbol for a C contract to call: the caller
    // *instantiates* the driver. That is the same position a subsystem is in
    // when it calls its neighbour, and Part 17a's answer applies -- be inside
    // the compilation. So a Zig contract is its own module rooted at
    // `test/<name>.zig`, importing the subsystem under test by path.
    //
    // What keeps it honest is the `options` module. Every field is `false`, so
    // the *neighbours* resolve to their `_extern.zig` shims and link to the
    // real `libjanet.a`: `printer` is `pp_extern.zig`, `containers` is
    // `buffer_array_extern.zig`, `arglayer` is `args_core_extern.zig`. Only
    // the generic code under test is compiled locally, because only generic
    // code has to be. The same `false` suppresses the subsystem's own
    // `@export`s, which would otherwise collide with the library's.
    const ZigContracts = struct {
        fn includeZig(
            builder: *std.Build,
            module: *std.Build.Module,
            contract_target: std.Build.ResolvedTarget,
            contract_optimize: std.builtin.OptimizeMode,
            header: std.Build.LazyPath,
            opts: BuildOptions,
            comptime name: []const u8,
            comptime subject: []const u8,
        ) void {
            const abi_module = builder.createModule(.{
                .root_source_file = builder.path("src/zig/abi.zig"),
                .target = contract_target,
                .optimize = contract_optimize,
            });
            configureCModule(builder, abi_module, contract_target, header, opts);
            addAbiIncludePath(builder, abi_module);

            const raise_module = builder.createModule(.{
                .root_source_file = builder.path("src/zig/raise.zig"),
                .target = contract_target,
                .optimize = contract_optimize,
            });
            configureCModule(builder, raise_module, contract_target, header, opts);
            addAbiIncludePath(builder, raise_module);
            raise_module.addIncludePath(builder.path("src/core"));
            raise_module.addImport("abi", abi_module);

            const selection = makeSelectionModule(builder, std.mem.zeroes(Selection));

            // The subsystem under test, as a module of its own so that its
            // relative imports resolve beside it rather than beside the
            // contract. `subject` is the name the contract spells.
            const subject_module = builder.createModule(.{
                .root_source_file = builder.path("src/zig/subsystems/" ++ subject ++ ".zig"),
                .target = contract_target,
                .optimize = contract_optimize,
            });
            configureCModule(builder, subject_module, contract_target, header, opts);
            addAbiIncludePath(builder, subject_module);
            subject_module.addIncludePath(builder.path("src/core"));
            subject_module.addImport("abi", abi_module);
            subject_module.addImport("raise", raise_module);
            subject_module.addImport("options", selection);

            const contract_module = builder.createModule(.{
                .root_source_file = builder.path("test/" ++ name ++ ".zig"),
                .target = contract_target,
                .optimize = contract_optimize,
            });
            configureCModule(builder, contract_module, contract_target, header, opts);
            addAbiIncludePath(builder, contract_module);
            contract_module.addIncludePath(builder.path("src/core"));
            contract_module.addImport("abi", abi_module);
            contract_module.addImport("raise", raise_module);
            contract_module.addImport("options", selection);
            contract_module.addImport("subject", subject_module);

            const object = builder.addObject(.{
                .name = "janet-contract-" ++ name,
                .root_module = contract_module,
            });
            module.addObject(object);

            // Installed for the same reason `janet-contract-support.o` is: the
            // *shallow* contract path in `port/contract.sh` and `matrix.py`
            // links objects against `zig-out/lib/libjanet.a` by hand, and a
            // Zig contract has no `.c` for it to compile.
            builder.getInstallStep().dependOn(&builder.addInstallFile(
                object.getEmittedBin(),
                "lib/janet-contract-" ++ name ++ ".o",
            ).step);

            comptime var upper: [name.len]u8 = undefined;
            comptime for (name, 0..) |ch, i| {
                upper[i] = std.ascii.toUpper(ch);
            };
            module.addCMacro("JANET_CONTRACT_" ++ upper, "1");
        }
    };
    const includeZig = ZigContracts.includeZig;

    include(b, contract_test_module, &contract_sources, "vector");
    include(b, contract_test_module, &contract_sources, "utils");
    include(b, contract_test_module, &contract_sources, "registry");
    // `test/intscan.c` and `test/inttypes.c` name types a `-Dint-types=false`
    // build does not define.
    if (options.int_types) include(b, contract_test_module, &contract_sources, "intscan");
    include(b, contract_test_module, &contract_sources, "textscan");
    include(b, contract_test_module, &contract_sources, "regalloc");
    include(b, contract_test_module, &contract_sources, "verify");
    include(b, contract_test_module, &contract_sources, "remove_noops");
    include(b, contract_test_module, &contract_sources, "movopt");
    include(b, contract_test_module, &contract_sources, "emit_core");
    if (options.assembler) {
        include(b, contract_test_module, &contract_sources, "asm_encode");
        include(b, contract_test_module, &contract_sources, "asm_decode");
        include(b, contract_test_module, &contract_sources, "disasm");
    }
    include(b, contract_test_module, &contract_sources, "compiler_primitives");
    include(b, contract_test_module, &contract_sources, "specials_core");
    include(b, contract_test_module, &contract_sources, "numscan");
    include(b, contract_test_module, &contract_sources, "math");
    if (options.int_types) include(b, contract_test_module, &contract_sources, "inttypes");
    if (!options.reduced_os) {
        include(b, contract_test_module, &contract_sources, "os_permissions");
    }
    include(b, contract_test_module, &contract_sources, "os_platform");
    if (!options.reduced_os) {
        include(b, contract_test_module, &contract_sources, "os_environ");
        include(b, contract_test_module, &contract_sources, "os_fs");
        include(b, contract_test_module, &contract_sources, "os_stat");
        include(b, contract_test_module, &contract_sources, "os_time");
        include(b, contract_test_module, &contract_sources, "os_fs_paths");
    }
    if (hasProcesses(options)) include(b, contract_test_module, &contract_sources, "os_process");
    include(b, contract_test_module, &contract_sources, "os_surface");
    if (hasEv(options)) include(b, contract_test_module, &contract_sources, "ev_core");
    if (hasEv(options)) include(b, contract_test_module, &contract_sources, "ev_loop");
    if (hasNet(options)) include(b, contract_test_module, &contract_sources, "net_sockets");
    if (hasFilewatch(options)) include(b, contract_test_module, &contract_sources, "filewatch_flags");
    if (hasFilewatch(options)) include(b, contract_test_module, &contract_sources, "filewatch_core");
    if (options.ffi) {
        include(b, contract_test_module, &contract_sources, "ffi_layout");
        include(b, contract_test_module, &contract_sources, "ffi_classify");
        include(b, contract_test_module, &contract_sources, "ffi_core");
    }
    include(b, contract_test_module, &contract_sources, "io_core");
    include(b, contract_test_module, &contract_sources, "parser_core");
    include(b, contract_test_module, &contract_sources, "vm_state");
    include(b, contract_test_module, &contract_sources, "args_core");
    include(b, contract_test_module, &contract_sources, "gc_alloc");
    include(b, contract_test_module, &contract_sources, "gc_mark");
    include(b, contract_test_module, &contract_sources, "gc_sweep");
    include(b, contract_test_module, &contract_sources, "buffer_array");
    include(b, contract_test_module, &contract_sources, "string_symbol");
    include(b, contract_test_module, &contract_sources, "struct_table");
    include(b, contract_test_module, &contract_sources, "value_order");
    include(b, contract_test_module, &contract_sources, "value_access");
    include(b, contract_test_module, &contract_sources, "abstract_core");
    include(b, contract_test_module, &contract_sources, "value_alloc");
    // Three files behind one selector since Part 4, and three layers of one
    // subject: rendering a value, laying a structure of them out, and the
    // format engine that drives both. They run in that order.
    include(b, contract_test_module, &contract_sources, "pp_describe");
    include(b, contract_test_module, &contract_sources, "pp_pretty");
    includeZig(b, contract_test_module, target, optimize, config_header, options, "pp_format", "pp_format");
    // `test/peg.c` names `janet_peg_type` and `JanetPeg`, which `janet.h`
    // declares only under `JANET_PEG`.
    if (options.peg) include(b, contract_test_module, &contract_sources, "peg");
    include(b, contract_test_module, &contract_sources, "core_env");
    include(b, contract_test_module, &contract_sources, "marsh");
    include(b, contract_test_module, &contract_sources, "value_wrap");
    include(b, contract_test_module, &contract_sources, "gc_stress");
    include(b, contract_test_module, &contract_sources, "signal_core");
    include(b, contract_test_module, &contract_sources, "trace_frames");
    include(b, contract_test_module, &contract_sources, "vm_run");
    include(b, contract_test_module, &contract_sources, "vm_lifecycle");
    include(b, contract_test_module, &contract_sources, "vm_entry");
    include(b, contract_test_module, &contract_sources, "vm_calls");
    include(b, contract_test_module, &contract_sources, "fiber_core");

    contract_test_module.addCSourceFiles(.{
        .files = contract_sources.items,
        .flags = test_c_flags,
    });

    // Phase 10 Part 17g. A cfunction is a Zig function now, so a C contract
    // can neither call one nor define one; `test/support.zig` is the adapter
    // that lets `test/*.c` go on doing both. It is linked here and nowhere
    // else, so nothing test-only reaches the runtime.
    const support_module = b.createModule(.{
        .root_source_file = b.path("test/support.zig"),
        .target = target,
        .optimize = optimize,
    });
    configureCModule(b, support_module, target, config_header, options);
    addAbiIncludePath(b, support_module);
    support_module.addIncludePath(b.path("src/core"));
    // Its own `abi` translation. A second one costs a compilation and buys
    // isolation: nothing here shares a type with the runtime object, and the
    // only types it names are `Janet` and the two table rows.
    const support_abi = b.createModule(.{
        .root_source_file = b.path("src/zig/abi.zig"),
        .target = target,
        .optimize = optimize,
    });
    configureCModule(b, support_abi, target, config_header, options);
    addAbiIncludePath(b, support_abi);
    support_module.addImport("abi", support_abi);
    // The contract adapter needs the same abstract-type mirror the runtime
    // uses, so that the pointer it hands back has the layout the runtime
    // dispatches through. `raise` comes with it, for `raise.Error`.
    const support_raise = b.createModule(.{
        .root_source_file = b.path("src/zig/raise.zig"),
        .target = target,
        .optimize = optimize,
    });
    configureCModule(b, support_raise, target, config_header, options);
    addAbiIncludePath(b, support_raise);
    support_raise.addIncludePath(b.path("src/core"));
    support_raise.addImport("abi", support_abi);

    const support_at = b.createModule(.{
        .root_source_file = b.path("src/zig/subsystems/abstract_type.zig"),
        .target = target,
        .optimize = optimize,
    });
    configureCModule(b, support_at, target, config_header, options);
    addAbiIncludePath(b, support_at);
    support_at.addImport("abi", support_abi);
    support_at.addImport("raise", support_raise);
    support_module.addImport("abstract_type", support_at);

    // The same for the special-form mirror: `test/specials_core.c` calls a
    // special's `compile` directly, and since the hinge that is a raising Zig
    // function rather than a C one.
    const support_special = b.createModule(.{
        .root_source_file = b.path("src/zig/subsystems/special.zig"),
        .target = target,
        .optimize = optimize,
    });
    configureCModule(b, support_special, target, config_header, options);
    addAbiIncludePath(b, support_special);
    support_special.addIncludePath(b.path("src/core"));
    support_special.addImport("abi", support_abi);
    support_special.addImport("raise", support_raise);
    support_module.addImport("special", support_special);

    const support = b.addObject(.{ .name = "janet-contract-support", .root_module = support_module });
    contract_test_module.addObject(support);

    // Installed beside the library, unconditionally, because the *shallow*
    // contract path is a first-class instrument here and does not go through
    // this executable: `port/contract.sh` and `matrix.py`'s `contracts` jobs
    // `zig cc` one contract against `zig-out/lib/libjanet.a`, and since Part
    // 17g that link needs this object too. It is not gated behind
    // `-Dinstall-tests`, which installs runnable test binaries for another
    // machine; this is a link input the narrow loop cannot work without, and
    // a missing one is an undefined symbol in fourteen matrix entries at
    // once, which is how it was found.
    b.getInstallStep().dependOn(&b.addInstallFile(
        support.getEmittedBin(),
        "lib/janet-contract-support.o",
    ).step);

    const contract_test = b.addExecutable(.{
        .name = "janet-contract-test",
        .root_module = contract_test_module,
    });
    installTest(b, options, contract_test);
    subsystem_step.dependOn(&b.addRunArtifact(contract_test).step);

    const zig_abi_module = b.createModule(.{
        .root_source_file = b.path("src/zig/abi_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    zig_abi_module.addIncludePath(b.path("src/include"));
    zig_abi_module.addIncludePath(b.path("src/zig"));
    addAbiIncludePath(b, zig_abi_module);
    zig_abi_module.addIncludePath(config_header.dirname());
    zig_abi_module.linkSystemLibrary("c", .{});
    const zig_abi_test = b.addTest(.{ .name = "janet-zig-abi-test", .root_module = zig_abi_module });
    installTest(b, options, zig_abi_test);
    const run_zig_abi_test = b.addRunArtifact(zig_abi_test);
    abi_step.dependOn(&run_zig_abi_test.step);

    const test_step = b.step("test", "Run ABI checks and Janet's test suites");
    test_step.dependOn(abi_step);
    test_step.dependOn(subsystem_step);
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
    const header = b.fmt(
        \\#ifndef JANETCONF_H
        \\#define JANETCONF_H
        \\#define JANET_VERSION_MAJOR 1
        \\#define JANET_VERSION_MINOR 41
        \\#define JANET_VERSION_PATCH 3
        \\#define JANET_VERSION_EXTRA "-dev"
        \\#define JANET_VERSION "1.41.3-dev"
        \\#define JANET_BUILD "zig"
        \\{s}{s}{s}{s}{s}{s}{s}{s}{s}{s}{s}{s}{s}{s}{s}{s}{s}{s}{s}{s}{s}{s}{s}{s}
        \\#define JANET_RECURSION_GUARD {d}
        \\#define JANET_MAX_PROTO_DEPTH {d}
        \\#define JANET_MAX_MACRO_EXPAND {d}
        \\#define JANET_STACK_MAX {d}
        \\{s}{s}#endif
        \\
    , .{
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

/// `src/zig/abi.zig` translates `src/zig/state_abi.h`, which reaches Janet's
/// internal `src/core/state.h`. Every module that imports abi.zig — directly or
/// through cli.zig, interop.zig, or native_module.zig — therefore needs the
/// core include path as well as the public one. Contract tests deliberately do
/// not get it unless they exercise an internal header themselves.
fn addAbiIncludePath(b: *std.Build, module: *std.Build.Module) void {
    module.addIncludePath(b.path("src/core"));
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
    module.addIncludePath(b.path("src/include"));
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
    image_source: std.Build.LazyPath,
    options: BuildOptions,
    zig_runtime: ?*std.Build.Step.Compile,
) *std.Build.Module {
    const module = makeCModule(b, target, optimize, config_header, options);
    addRuntimeSources(module, image_source, options, zig_runtime);
    return module;
}

fn addRuntimeSources(
    module: *std.Build.Module,
    image_source: ?std.Build.LazyPath,
    options: BuildOptions,
    zig_runtime: ?*std.Build.Step.Compile,
) void {
    const sel = zigSelection(options);
    // The bootstrap compiler is the one runtime built without an image: it is
    // what produces one.
    if (image_source) |image| module.addCSourceFile(.{ .file = image, .flags = common_c_flags });

    // The two whole-file swaps. Neither guards a C original off with a macro,
    // because there is no C left in the file to guard: the selector picks
    // between compiling `vector.c` and not compiling it.
    if (!sel.vector) module.addCSourceFiles(.{ .files = &.{"src/core/vector.c"}, .flags = common_c_flags });
    if (!sel.regalloc) module.addCSourceFiles(.{ .files = &.{"src/core/regalloc.c"}, .flags = common_c_flags });

    // Everything else guards its C original off. The condition that decided
    // each of these is in `zigSelection`, with the import in
    // `src/zig/subsystems/root.zig` that answers it; all this does is name the
    // macro, which is a static fact about the C source rather than a decision.
    if (sel.utilities) module.addCMacro("JANET_ZIG_UTILS", "1");
    if (sel.registry) module.addCMacro("JANET_ZIG_REGISTRY", "1");
    if (sel.int_scan) module.addCMacro("JANET_ZIG_INTSCAN", "1");
    if (sel.text_scan) module.addCMacro("JANET_ZIG_TEXTSCAN", "1");
    if (sel.verify) module.addCMacro("JANET_ZIG_VERIFY", "1");
    if (sel.remove_noops) module.addCMacro("JANET_ZIG_REMOVE_NOOPS", "1");
    if (sel.movopt) module.addCMacro("JANET_ZIG_MOVOPT", "1");
    if (sel.emit_core) module.addCMacro("JANET_ZIG_EMIT_CORE", "1");
    if (sel.asm_encode) module.addCMacro("JANET_ZIG_ASM_ENCODE", "1");
    if (sel.asm_decode) module.addCMacro("JANET_ZIG_ASM_DECODE", "1");
    if (sel.disasm) module.addCMacro("JANET_ZIG_DISASM", "1");
    if (sel.asm_core) module.addCMacro("JANET_ZIG_ASM_CORE", "1");
    if (sel.compiler_primitives) module.addCMacro("JANET_ZIG_COMPILER_PRIMITIVES", "1");
    if (sel.parser_core) module.addCMacro("JANET_ZIG_PARSER_CORE", "1");
    if (sel.specials_core) module.addCMacro("JANET_ZIG_SPECIALS_CORE", "1");
    if (sel.builtin_optimizers) module.addCMacro("JANET_ZIG_BUILTIN_OPTIMIZERS", "1");
    if (sel.number_scan) module.addCMacro("JANET_ZIG_NUMSCAN", "1");
    if (sel.math_core) module.addCMacro("JANET_ZIG_MATH_CORE", "1");
    if (sel.int_types_core) module.addCMacro("JANET_ZIG_INT_TYPES_CORE", "1");
    if (sel.os_permissions) module.addCMacro("JANET_ZIG_OS_PERMISSIONS", "1");
    if (sel.os_platform) module.addCMacro("JANET_ZIG_OS_PLATFORM", "1");
    if (sel.os_environ) module.addCMacro("JANET_ZIG_OS_ENVIRON", "1");
    if (sel.os_fs) module.addCMacro("JANET_ZIG_OS_FS", "1");
    if (sel.os_stat) module.addCMacro("JANET_ZIG_OS_STAT", "1");
    if (sel.os_time) module.addCMacro("JANET_ZIG_OS_TIME", "1");
    if (sel.os_fs_paths) module.addCMacro("JANET_ZIG_OS_FS_PATHS", "1");
    if (sel.io_core) module.addCMacro("JANET_ZIG_IO_CORE", "1");
    if (sel.os_process) module.addCMacro("JANET_ZIG_OS_PROCESS", "1");
    if (sel.os_surface) module.addCMacro("JANET_ZIG_OS_SURFACE", "1");
    if (sel.ev_core) module.addCMacro("JANET_ZIG_EV_CORE", "1");
    if (sel.ev_loop) module.addCMacro("JANET_ZIG_EV_LOOP", "1");
    if (sel.net_sockets) module.addCMacro("JANET_ZIG_NET_SOCKETS", "1");
    if (sel.ffi_layout) module.addCMacro("JANET_ZIG_FFI_LAYOUT", "1");
    if (sel.ffi_classify) module.addCMacro("JANET_ZIG_FFI_CLASSIFY", "1");
    if (sel.ffi_core) module.addCMacro("JANET_ZIG_FFI_CORE", "1");
    if (sel.filewatch_flags) module.addCMacro("JANET_ZIG_FILEWATCH_FLAGS", "1");
    if (sel.filewatch_core) module.addCMacro("JANET_ZIG_FILEWATCH_CORE", "1");
    if (sel.args_core) module.addCMacro("JANET_ZIG_ARGS_CORE", "1");
    if (sel.gc_alloc) module.addCMacro("JANET_ZIG_GC_ALLOC", "1");
    if (sel.gc_mark) module.addCMacro("JANET_ZIG_GC_MARK", "1");
    if (sel.gc_sweep) module.addCMacro("JANET_ZIG_GC_SWEEP", "1");
    if (sel.buffer_array) module.addCMacro("JANET_ZIG_BUFFER_ARRAY", "1");
    if (sel.string_symbol) module.addCMacro("JANET_ZIG_STRING_SYMBOL", "1");
    if (sel.struct_table) module.addCMacro("JANET_ZIG_STRUCT_TABLE", "1");
    if (sel.value_order) module.addCMacro("JANET_ZIG_VALUE_ORDER", "1");
    if (sel.value_access) module.addCMacro("JANET_ZIG_VALUE_ACCESS", "1");
    if (sel.abstract_core) module.addCMacro("JANET_ZIG_ABSTRACT_CORE", "1");
    if (sel.value_alloc) module.addCMacro("JANET_ZIG_VALUE_ALLOC", "1");
    if (sel.value_wrap) module.addCMacro("JANET_ZIG_VALUE_WRAP", "1");
    if (sel.pp) module.addCMacro("JANET_ZIG_PP", "1");
    if (sel.marsh) module.addCMacro("JANET_ZIG_MARSH", "1");
    if (sel.peg_engine) module.addCMacro("JANET_ZIG_PEG_ENGINE", "1");
    if (sel.core_env) module.addCMacro("JANET_ZIG_CORE_ENV", "1");
    if (sel.vm_state) module.addCMacro("JANET_ZIG_VM_STATE", "1");
    if (sel.fiber_core) module.addCMacro("JANET_ZIG_FIBER_CORE", "1");
    if (sel.signal_core) module.addCMacro("JANET_ZIG_SIGNAL_CORE", "1");
    if (sel.trace_frames) module.addCMacro("JANET_ZIG_TRACE_FRAMES", "1");
    if (sel.debug_frames) module.addCMacro("JANET_ZIG_DEBUG_FRAMES", "1");
    if (sel.vm_calls) module.addCMacro("JANET_ZIG_VM_CALLS", "1");
    if (sel.vm_run) module.addCMacro("JANET_ZIG_VM_RUN", "1");
    if (sel.vm_entry) module.addCMacro("JANET_ZIG_VM_ENTRY", "1");
    if (sel.vm_lifecycle) module.addCMacro("JANET_ZIG_VM_LIFECYCLE", "1");

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
        .vector = true,
        .utilities = true,
        .registry = true,
        .int_scan = options.int_types,
        .text_scan = true,
        .regalloc = true,
        .verify = true,
        .remove_noops = true,
        .movopt = true,
        .emit_core = true,
        .asm_encode = options.assembler,
        .asm_decode = options.assembler,
        .disasm = options.assembler,
        .asm_core = options.assembler,
        .compiler_primitives = true,
        .parser_core = true,
        .specials_core = true,
        .builtin_optimizers = true,
        .number_scan = true,
        .math_core = true,
        .int_types_core = options.int_types,
        .os_permissions = !options.reduced_os,
        .os_platform = true,
        .os_environ = !options.reduced_os,
        .os_fs = !options.reduced_os,
        .os_stat = !options.reduced_os,
        .os_time = hasGettime(options),
        .os_fs_paths = !options.reduced_os,
        .io_core = true,
        .os_process = hasProcesses(options),
        .os_surface = true,
        .ev_core = hasEv(options),
        .ev_loop = hasEv(options),
        .net_sockets = hasNet(options),
        .ffi_layout = options.ffi,
        .ffi_classify = options.ffi,
        .ffi_core = options.ffi,
        .filewatch_flags = hasFilewatch(options),
        .filewatch_core = hasFilewatch(options),
        .args_core = true,
        .gc_alloc = true,
        .gc_mark = true,
        .gc_sweep = true,
        .buffer_array = true,
        .string_symbol = true,
        .struct_table = true,
        .value_order = true,
        .value_access = true,
        .abstract_core = true,
        .value_alloc = true,
        .value_wrap = true,
        .pp = true,
        .marsh = true,
        .peg_engine = options.peg,
        .core_env = true,
        .vm_state = true,
        .fiber_core = true,
        .signal_core = true,
        .trace_frames = true,
        .debug_frames = true,
        .vm_calls = true,
        .vm_run = true,
        .vm_entry = true,
        .vm_lifecycle = true,
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

/// `src/core/features.h` defines JANET_EV unless JANET_NO_EV is set, which
/// `addRuntimeSources` does for a build that disables the event loop or is
/// single-threaded. Everything in `ev.c` — the subsystem included — is compiled
/// only when it is defined.
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

/// A subsystem whose frames a Janet signal is allowed to jump through declares
/// itself with `//! jump-transparent` on a line of its own, and must then hold
/// nothing that a skipped cleanup would strand: no `defer`, no `errdefer`.
///
/// SPIKE-8 decided to let a third-party callback's panic jump straight past the
/// Zig frames that invoked it, rather than catching it below each one. A probe
/// established that the jump itself is harmless — Zig has no destructors, so a
/// frame owning nothing is as jump-safe as a C one — and that the single
/// casualty is `defer`, which is skipped silently. That makes the whole
/// decision rest on a property of the source, so it is checked here rather than
/// written down and hoped for. Two of the eight `defer`s in the tree today
/// release a GC lock, and a skipped `janet_gcunlock` wedges the collector
/// permanently rather than merely leaking.
///
/// Deliberately crude: a token scan, skipping line comments. It cannot tell
/// which frames a signal actually reaches, so it over-approximates to the whole
/// file, which for the collector and the value core is very nearly exact.
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
/// `setjmp` could not go while any remained. `src/zig/subsystems/root.zig` has
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
) ?*std.Build.Step.Compile {
    const sel = zigSelection(options);
    if (!sel.any()) return null;

    // One `abi` translation for the whole object, which is the rule `abi.zig`
    // states: two `@cImport` blocks over the same header produce distinct,
    // incompatible types, so a `JanetFiber` from one is not the `JanetFiber` the
    // other holds. It mattered per-object before and it matters here for the
    // same reason -- `os_abi`, `net_abi` and `filewatch_abi` are second
    // translations by design, and each keeps what it declares inside one file.
    const abi_module = b.createModule(.{
        .root_source_file = b.path("src/zig/abi.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
    });
    configureCModule(b, abi_module, target, config_header, options);
    addAbiIncludePath(b, abi_module);

    const module = b.createModule(.{
        .root_source_file = b.path("src/zig/subsystems/root.zig"),
        .target = target,
        .optimize = optimize,
        // Linked into the shared library as well as the static one, and ELF
        // shared objects require position-independent code. Mach-O is always
        // position independent, so omitting this only fails on ELF targets.
        .pic = true,
    });
    configureCModule(b, module, target, config_header, options);
    module.addIncludePath(b.path("src/core"));
    module.addImport("abi", abi_module);
    module.addImport("options", makeSelectionModule(b, sel));

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
    addAbiIncludePath(b, raise_module);
    raise_module.addIncludePath(b.path("src/core"));
    raise_module.addImport("abi", abi_module);
    module.addImport("raise", raise_module);

    const corefn_module = b.createModule(.{
        .root_source_file = b.path("src/zig/corefn.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
    });
    configureCModule(b, corefn_module, target, config_header, options);
    addAbiIncludePath(b, corefn_module);
    corefn_module.addIncludePath(b.path("src/core"));
    corefn_module.addImport("abi", abi_module);
    // Since Part 17g `corefn` names `raise.CFunction`: a registration table
    // row and a method table row are both typed by what a cfunction is.
    corefn_module.addImport("raise", raise_module);
    module.addImport("corefn", corefn_module);

    // The three second translations of host headers. Each is attached
    // unconditionally: an import the configuration does not reach is not
    // analysed, so a `-Dnet=false` build pays nothing for `net_abi`.
    for ([_]struct { name: []const u8, source: []const u8 }{
        .{ .name = "os_abi", .source = "src/zig/os_abi.zig" },
        .{ .name = "net_abi", .source = "src/zig/net_abi.zig" },
        .{ .name = "filewatch_abi", .source = "src/zig/filewatch_abi.zig" },
    }) |entry| {
        const host = b.createModule(.{
            .root_source_file = b.path(entry.source),
            .target = target,
            .optimize = optimize,
            .pic = true,
        });
        configureCModule(b, host, target, config_header, options);
        addAbiIncludePath(b, host);
        module.addImport(entry.name, host);
    }

    return b.addObject(.{ .name = "janet-zig", .root_module = module });
}

/// `@import("options")`: the `Selection` as comptime booleans.
///
/// The root imports what this says is selected, and `addRuntimeSources` guards
/// off the C original for the same fields, so the two cannot disagree. Written
/// by reflection rather than as a list for the reason `Selection.any` is: a
/// list acquires a stale entry the first time an increment adds a selector and
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
