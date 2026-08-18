const std = @import("std");

const version = std.SemanticVersion{ .major = 1, .minor = 41, .patch = 3 };

const core_sources = &.{
    "src/core/abstract.c",
    "src/core/array.c",
    "src/core/asm.c",
    "src/core/buffer.c",
    "src/core/bytecode.c",
    "src/core/capi.c",
    "src/core/cfuns.c",
    "src/core/compile.c",
    "src/core/corelib.c",
    "src/core/debug.c",
    "src/core/emit.c",
    "src/core/ev.c",
    "src/core/ffi.c",
    "src/core/fiber.c",
    "src/core/filewatch.c",
    "src/core/gc.c",
    "src/core/inttypes.c",
    "src/core/io.c",
    "src/core/marsh.c",
    "src/core/math.c",
    "src/core/net.c",
    "src/core/os.c",
    "src/core/parse.c",
    "src/core/peg.c",
    "src/core/pp.c",
    "src/core/run.c",
    "src/core/specials.c",
    "src/core/state.c",
    "src/core/string.c",
    "src/core/strtod.c",
    "src/core/struct.c",
    "src/core/symcache.c",
    "src/core/table.c",
    "src/core/tuple.c",
    "src/core/util.c",
    "src/core/value.c",
    "src/core/vm.c",
    "src/core/wrap.c",
};

const boot_sources = &.{
    "src/boot/array_test.c",
    "src/boot/boot.c",
    "src/boot/buffer_test.c",
    "src/boot/number_test.c",
    "src/boot/system_test.c",
    "src/boot/table_test.c",
};

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

const SubsystemImplementation = enum {
    c,
    zig,
};

const BuildOptions = struct {
    vector: SubsystemImplementation,
    utilities: SubsystemImplementation,
    int_scan: SubsystemImplementation,
    text_scan: SubsystemImplementation,
    regalloc: SubsystemImplementation,
    verify: SubsystemImplementation,
    remove_noops: SubsystemImplementation,
    movopt: SubsystemImplementation,
    emit_core: SubsystemImplementation,
    asm_encode: SubsystemImplementation,
    asm_decode: SubsystemImplementation,
    disasm: SubsystemImplementation,
    compiler_primitives: SubsystemImplementation,
    parser_core: SubsystemImplementation,
    specials_core: SubsystemImplementation,
    builtin_optimizers: SubsystemImplementation,
    number_scan: SubsystemImplementation,
    math_core: SubsystemImplementation,
    int_types_core: SubsystemImplementation,
    os_permissions: SubsystemImplementation,
    os_platform: SubsystemImplementation,
    os_environ: SubsystemImplementation,
    os_fs: SubsystemImplementation,
    os_stat: SubsystemImplementation,
    os_time: SubsystemImplementation,
    os_fs_paths: SubsystemImplementation,
    io_core: SubsystemImplementation,
    os_process: SubsystemImplementation,
    ev_core: SubsystemImplementation,
    ffi_layout: SubsystemImplementation,
    ffi_classify: SubsystemImplementation,
    filewatch_flags: SubsystemImplementation,
    vm_state: SubsystemImplementation,
    fiber_core: SubsystemImplementation,
    signal_core: SubsystemImplementation,
    trace_frames: SubsystemImplementation,
    install_tests: bool,
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
    call_trampoline: bool,
    recursion_guard: i32,
    max_proto_depth: i32,
    max_macro_expand: i32,
    stack_max: i32,
};

const RuntimeSubsystems = struct {
    vector: ?*std.Build.Step.Compile,
    utilities: ?*std.Build.Step.Compile,
    int_scan: ?*std.Build.Step.Compile,
    text_scan: ?*std.Build.Step.Compile,
    regalloc: ?*std.Build.Step.Compile,
    verify: ?*std.Build.Step.Compile,
    remove_noops: ?*std.Build.Step.Compile,
    movopt: ?*std.Build.Step.Compile,
    emit_core: ?*std.Build.Step.Compile,
    asm_encode: ?*std.Build.Step.Compile,
    asm_decode: ?*std.Build.Step.Compile,
    disasm: ?*std.Build.Step.Compile,
    compiler_primitives: ?*std.Build.Step.Compile,
    parser_core: ?*std.Build.Step.Compile,
    specials_core: ?*std.Build.Step.Compile,
    builtin_optimizers: ?*std.Build.Step.Compile,
    number_scan: ?*std.Build.Step.Compile,
    math_core: ?*std.Build.Step.Compile,
    int_types_core: ?*std.Build.Step.Compile,
    os_permissions: ?*std.Build.Step.Compile,
    os_platform: ?*std.Build.Step.Compile,
    os_environ: ?*std.Build.Step.Compile,
    os_fs: ?*std.Build.Step.Compile,
    os_stat: ?*std.Build.Step.Compile,
    os_time: ?*std.Build.Step.Compile,
    os_fs_paths: ?*std.Build.Step.Compile,
    io_core: ?*std.Build.Step.Compile,
    os_process: ?*std.Build.Step.Compile,
    ev_core: ?*std.Build.Step.Compile,
    ffi_layout: ?*std.Build.Step.Compile,
    ffi_classify: ?*std.Build.Step.Compile,
    filewatch_flags: ?*std.Build.Step.Compile,
    vm_state: ?*std.Build.Step.Compile,
    fiber_core: ?*std.Build.Step.Compile,
    signal_core: ?*std.Build.Step.Compile,
    trace_frames: ?*std.Build.Step.Compile,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const options = readOptions(b);
    const config_header = makeConfigHeader(b, options);

    const subsystems: RuntimeSubsystems = .{
        .vector = if (options.vector == .zig)
            makeZigSubsystemObject(b, target, optimize, config_header, options, "janet-vector-zig", "src/zig/subsystems/vector.zig")
        else
            null,
        .utilities = if (options.utilities == .zig)
            makeZigSubsystemObject(b, target, optimize, config_header, options, "janet-utils-zig", "src/zig/subsystems/utils.zig")
        else
            null,
        .int_scan = if (options.int_types and options.int_scan == .zig)
            makeZigSubsystemObject(b, target, optimize, config_header, options, "janet-intscan-zig", "src/zig/subsystems/intscan.zig")
        else
            null,
        .text_scan = if (options.text_scan == .zig)
            makeZigSubsystemObject(b, target, optimize, config_header, options, "janet-textscan-zig", "src/zig/subsystems/textscan.zig")
        else
            null,
        .regalloc = if (options.regalloc == .zig)
            makeZigSubsystemObject(b, target, optimize, config_header, options, "janet-regalloc-zig", "src/zig/subsystems/regalloc.zig")
        else
            null,
        .verify = if (options.verify == .zig)
            makeZigSubsystemObject(b, target, optimize, config_header, options, "janet-verify-zig", "src/zig/subsystems/verify.zig")
        else
            null,
        .remove_noops = if (options.remove_noops == .zig)
            makeZigSubsystemObject(b, target, optimize, config_header, options, "janet-remove-noops-zig", "src/zig/subsystems/remove_noops.zig")
        else
            null,
        .movopt = if (options.movopt == .zig)
            makeZigSubsystemObject(b, target, optimize, config_header, options, "janet-movopt-zig", "src/zig/subsystems/movopt.zig")
        else
            null,
        .emit_core = if (options.emit_core == .zig)
            makeZigSubsystemObject(b, target, optimize, config_header, options, "janet-emit-core-zig", "src/zig/subsystems/emit_core.zig")
        else
            null,
        .asm_encode = if (options.assembler and options.asm_encode == .zig)
            makeZigSubsystemObject(b, target, optimize, config_header, options, "janet-asm-encode-zig", "src/zig/subsystems/asm_encode.zig")
        else
            null,
        .asm_decode = if (options.assembler and options.asm_decode == .zig)
            makeZigSubsystemObject(b, target, optimize, config_header, options, "janet-asm-decode-zig", "src/zig/subsystems/asm_decode.zig")
        else
            null,
        .disasm = if (options.assembler and options.disasm == .zig)
            makeZigSubsystemObject(b, target, optimize, config_header, options, "janet-disasm-zig", "src/zig/subsystems/disasm.zig")
        else
            null,
        .compiler_primitives = if (options.compiler_primitives == .zig)
            makeZigSubsystemObject(b, target, optimize, config_header, options, "janet-compiler-primitives-zig", "src/zig/subsystems/compiler_primitives.zig")
        else
            null,
        .parser_core = if (options.parser_core == .zig)
            makeZigSubsystemObject(b, target, optimize, config_header, options, "janet-parser-core-zig", "src/zig/subsystems/parser_core.zig")
        else
            null,
        .specials_core = if (options.specials_core == .zig)
            makeZigSubsystemObject(b, target, optimize, config_header, options, "janet-specials-core-zig", "src/zig/subsystems/specials_core.zig")
        else
            null,
        .builtin_optimizers = if (options.builtin_optimizers == .zig)
            makeZigSubsystemObject(b, target, optimize, config_header, options, "janet-builtin-optimizers-zig", "src/zig/subsystems/builtin_optimizers.zig")
        else
            null,
        .number_scan = if (options.number_scan == .zig)
            makeZigSubsystemObject(b, target, optimize, config_header, options, "janet-numscan-zig", "src/zig/subsystems/numscan.zig")
        else
            null,
        .math_core = if (options.math_core == .zig)
            makeZigSubsystemObject(b, target, optimize, config_header, options, "janet-math-zig", "src/zig/subsystems/math.zig")
        else
            null,
        .int_types_core = if (options.int_types and options.int_types_core == .zig)
            makeZigSubsystemObject(b, target, optimize, config_header, options, "janet-inttypes-zig", "src/zig/subsystems/inttypes.zig")
        else
            null,
        .os_permissions = if (!options.reduced_os and options.os_permissions == .zig)
            makeZigSubsystemObject(b, target, optimize, config_header, options, "janet-os-permissions-zig", "src/zig/subsystems/os_permissions.zig")
        else
            null,
        .os_platform = if (options.os_platform == .zig)
            makeZigSubsystemObject(b, target, optimize, config_header, options, "janet-os-platform-zig", "src/zig/subsystems/os_platform.zig")
        else
            null,
        .os_environ = if (!options.reduced_os and options.os_environ == .zig)
            makeZigSubsystemObject(b, target, optimize, config_header, options, "janet-os-environ-zig", "src/zig/subsystems/os_environ.zig")
        else
            null,
        .os_fs = if (!options.reduced_os and options.os_fs == .zig)
            makeZigSubsystemObject(b, target, optimize, config_header, options, "janet-os-fs-zig", "src/zig/subsystems/os_fs.zig")
        else
            null,
        .os_stat = if (!options.reduced_os and options.os_stat == .zig)
            makeZigSubsystemObject(b, target, optimize, config_header, options, "janet-os-stat-zig", "src/zig/subsystems/os_stat.zig")
        else
            null,
        .os_time = if (hasGettime(options) and options.os_time == .zig)
            makeZigSubsystemObject(b, target, optimize, config_header, options, "janet-os-time-zig", "src/zig/subsystems/os_time.zig")
        else
            null,
        .os_fs_paths = if (!options.reduced_os and options.os_fs_paths == .zig)
            makeZigSubsystemObject(b, target, optimize, config_header, options, "janet-os-fs-paths-zig", "src/zig/subsystems/os_fs_paths.zig")
        else
            null,
        .io_core = if (options.io_core == .zig)
            makeZigSubsystemObject(b, target, optimize, config_header, options, "janet-io-core-zig", "src/zig/subsystems/io_core.zig")
        else
            null,
        .os_process = if (hasProcesses(options) and options.os_process == .zig)
            makeZigSubsystemObject(b, target, optimize, config_header, options, "janet-os-process-zig", "src/zig/subsystems/os_process.zig")
        else
            null,
        .ev_core = if (hasEv(options) and options.ev_core == .zig)
            makeZigSubsystemObject(b, target, optimize, config_header, options, "janet-ev-core-zig", "src/zig/subsystems/ev_core.zig")
        else
            null,
        .ffi_layout = if (options.ffi and options.ffi_layout == .zig)
            makeZigSubsystemObject(b, target, optimize, config_header, options, "janet-ffi-layout-zig", "src/zig/subsystems/ffi_layout.zig")
        else
            null,
        .filewatch_flags = if (hasFilewatch(options) and options.filewatch_flags == .zig)
            makeZigSubsystemObject(b, target, optimize, config_header, options, "janet-filewatch-flags-zig", "src/zig/subsystems/filewatch_flags.zig")
        else
            null,
        .ffi_classify = if (options.ffi and options.ffi_classify == .zig)
            makeZigSubsystemObject(b, target, optimize, config_header, options, "janet-ffi-classify-zig", "src/zig/subsystems/ffi_classify.zig")
        else
            null,
        .vm_state = if (options.vm_state == .zig)
            makeZigSubsystemObject(b, target, optimize, config_header, options, "janet-vm-state-zig", "src/zig/subsystems/vm_state.zig")
        else
            null,
        .fiber_core = if (options.fiber_core == .zig)
            makeZigSubsystemObject(b, target, optimize, config_header, options, "janet-fiber-core-zig", "src/zig/subsystems/fiber_core.zig")
        else
            null,
        .signal_core = if (options.signal_core == .zig)
            makeZigSubsystemObject(b, target, optimize, config_header, options, "janet-signal-core-zig", "src/zig/subsystems/signal_core.zig")
        else
            null,
        .trace_frames = if (options.trace_frames == .zig)
            makeZigSubsystemObject(b, target, optimize, config_header, options, "janet-trace-frames-zig", "src/zig/subsystems/trace_frames.zig")
        else
            null,
    };

    // Bootstrap tools must execute on the build host even during a cross build.
    // Keep the host's architecture, OS, and ABI, but pin a baseline CPU instead
    // of the detected model. The bootstrap runs once to generate the image and
    // gains nothing from host-specific instructions, while native CPU detection
    // is a portability hazard: an emulated or unusual host can report a model
    // the code generator rejects, which fails the build before any Janet source
    // is compiled. Pinning it also keeps image generation reproducible across
    // machines of the same architecture.
    const boot_host = b.resolveTargetQuery(.{
        .cpu_arch = b.graph.host.result.cpu.arch,
        .os_tag = b.graph.host.result.os.tag,
        .abi = b.graph.host.result.abi,
        .cpu_model = .baseline,
    });
    const boot_module = makeCModule(b, boot_host, .Debug, config_header, options);
    boot_module.addCMacro("JANET_BOOTSTRAP", "1");
    boot_module.addCSourceFiles(.{ .files = core_sources, .flags = common_c_flags });
    boot_module.addCSourceFiles(.{ .files = &.{"src/core/vector.c"}, .flags = common_c_flags });
    boot_module.addCSourceFiles(.{ .files = &.{"src/core/regalloc.c"}, .flags = common_c_flags });
    boot_module.addCSourceFiles(.{ .files = boot_sources, .flags = common_c_flags });
    const boot = b.addExecutable(.{ .name = "janet-boot", .root_module = boot_module });

    const generate_image = b.addRunArtifact(boot);
    generate_image.setCwd(b.path("."));
    generate_image.addArg(".");
    generate_image.addArgs(&.{ "JANET_PATH", "/usr/local/lib/janet", "image-only" });
    generate_image.addFileInput(b.path("src/boot/boot.janet"));
    const image_source = generate_image.captureStdOut(.{ .basename = "janet-image.c" });

    const static_module = makeRuntimeModule(b, target, optimize, config_header, image_source, options, subsystems);
    const static_library = b.addLibrary(.{
        .name = "janet",
        .linkage = .static,
        .version = version,
        .root_module = static_module,
    });
    static_library.installHeader(b.path("src/include/janet.h"), "janet/janet.h");
    static_library.installHeader(config_header, "janet/janetconf.h");
    b.installArtifact(static_library);

    const shared_module = makeRuntimeModule(b, target, optimize, config_header, image_source, options, subsystems);
    const shared_library = b.addLibrary(.{
        .name = "janet",
        .linkage = .dynamic,
        .version = version,
        .root_module = shared_module,
    });
    b.installArtifact(shared_library);

    // Compile the runtime directly into the Zig client so all public API
    // symbols remain available to dynamically loaded Janet modules.
    const client_module = b.createModule(.{
        .root_source_file = b.path("src/zig/cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    configureCModule(b, client_module, target, config_header, options);
    addAbiIncludePath(b, client_module);
    addRuntimeSources(client_module, image_source, options, subsystems);
    client_module.addCSourceFiles(.{
        .files = &.{"src/zig/interop_bridge.c"},
        .flags = common_c_flags,
    });
    const client = b.addExecutable(.{ .name = "janet", .root_module = client_module });
    if (target.result.os.tag != .windows) client.rdynamic = true;
    b.installArtifact(client);

    // Keep the original C shell as a comparison target during Phase 2.
    const c_client_module = makeRuntimeModule(b, target, optimize, config_header, image_source, options, subsystems);
    c_client_module.addCSourceFiles(.{
        .files = &.{"src/mainclient/shell.c"},
        .flags = common_c_flags,
    });
    const c_client = b.addExecutable(.{ .name = "janet-c", .root_module = c_client_module });
    if (target.result.os.tag != .windows) c_client.rdynamic = true;
    b.installArtifact(c_client);

    const native_module_root = b.createModule(.{
        .root_source_file = b.path("src/zig/native_module.zig"),
        .target = target,
        .optimize = optimize,
    });
    configureCModule(b, native_module_root, target, config_header, options);
    addAbiIncludePath(b, native_module_root);
    native_module_root.addCSourceFiles(.{
        .files = &.{"src/zig/native_bridge.c"},
        .flags = common_c_flags,
    });
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

    const run_c_step = b.step("run-c", "Run the comparison C Janet client");
    const run_c_client = b.addRunArtifact(c_client);
    run_c_client.setCwd(b.path("."));
    if (b.args) |args| run_c_client.addArgs(args);
    run_c_step.dependOn(&run_c_client.step);

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

    const vector_test_module = makeCModule(b, target, optimize, config_header, options);
    vector_test_module.addIncludePath(b.path("src/core"));
    vector_test_module.addCSourceFiles(.{ .files = &.{"test/vector.c"}, .flags = test_c_flags });
    vector_test_module.linkLibrary(static_library);
    const vector_test = b.addExecutable(.{ .name = "janet-vector-test", .root_module = vector_test_module });
    installTest(b, options, vector_test);
    const run_vector_test = b.addRunArtifact(vector_test);
    subsystem_step.dependOn(&run_vector_test.step);

    const utilities_test_module = makeCModule(b, target, optimize, config_header, options);
    utilities_test_module.addIncludePath(b.path("src/core"));
    utilities_test_module.addCSourceFiles(.{ .files = &.{"test/utils.c"}, .flags = test_c_flags });
    utilities_test_module.linkLibrary(static_library);
    const utilities_test = b.addExecutable(.{ .name = "janet-utilities-test", .root_module = utilities_test_module });
    installTest(b, options, utilities_test);
    const run_utilities_test = b.addRunArtifact(utilities_test);
    subsystem_step.dependOn(&run_utilities_test.step);

    if (options.int_types) {
        const int_scan_test_module = makeCModule(b, target, optimize, config_header, options);
        int_scan_test_module.addCSourceFiles(.{ .files = &.{"test/intscan.c"}, .flags = test_c_flags });
        int_scan_test_module.linkLibrary(static_library);
        const int_scan_test = b.addExecutable(.{ .name = "janet-intscan-test", .root_module = int_scan_test_module });
        installTest(b, options, int_scan_test);
        const run_int_scan_test = b.addRunArtifact(int_scan_test);
        subsystem_step.dependOn(&run_int_scan_test.step);
    }

    const text_scan_test_module = makeCModule(b, target, optimize, config_header, options);
    text_scan_test_module.addIncludePath(b.path("src/core"));
    text_scan_test_module.addCSourceFiles(.{ .files = &.{"test/textscan.c"}, .flags = test_c_flags });
    text_scan_test_module.linkLibrary(static_library);
    const text_scan_test = b.addExecutable(.{ .name = "janet-textscan-test", .root_module = text_scan_test_module });
    installTest(b, options, text_scan_test);
    const run_text_scan_test = b.addRunArtifact(text_scan_test);
    subsystem_step.dependOn(&run_text_scan_test.step);

    const regalloc_test_module = makeCModule(b, target, optimize, config_header, options);
    regalloc_test_module.addIncludePath(b.path("src/core"));
    regalloc_test_module.addCSourceFiles(.{ .files = &.{"test/regalloc.c"}, .flags = test_c_flags });
    regalloc_test_module.linkLibrary(static_library);
    const regalloc_test = b.addExecutable(.{ .name = "janet-regalloc-test", .root_module = regalloc_test_module });
    installTest(b, options, regalloc_test);
    const run_regalloc_test = b.addRunArtifact(regalloc_test);
    subsystem_step.dependOn(&run_regalloc_test.step);

    const verify_test_module = makeCModule(b, target, optimize, config_header, options);
    verify_test_module.addCSourceFiles(.{ .files = &.{"test/verify.c"}, .flags = test_c_flags });
    verify_test_module.linkLibrary(static_library);
    const verify_test = b.addExecutable(.{ .name = "janet-verify-test", .root_module = verify_test_module });
    installTest(b, options, verify_test);
    const run_verify_test = b.addRunArtifact(verify_test);
    subsystem_step.dependOn(&run_verify_test.step);

    const remove_noops_test_module = makeCModule(b, target, optimize, config_header, options);
    remove_noops_test_module.addIncludePath(b.path("src/core"));
    remove_noops_test_module.addCSourceFiles(.{ .files = &.{"test/remove_noops.c"}, .flags = test_c_flags });
    remove_noops_test_module.linkLibrary(static_library);
    const remove_noops_test = b.addExecutable(.{ .name = "janet-remove-noops-test", .root_module = remove_noops_test_module });
    installTest(b, options, remove_noops_test);
    const run_remove_noops_test = b.addRunArtifact(remove_noops_test);
    subsystem_step.dependOn(&run_remove_noops_test.step);

    const movopt_test_module = makeCModule(b, target, optimize, config_header, options);
    movopt_test_module.addIncludePath(b.path("src/core"));
    movopt_test_module.addCSourceFiles(.{ .files = &.{"test/movopt.c"}, .flags = test_c_flags });
    movopt_test_module.linkLibrary(static_library);
    const movopt_test = b.addExecutable(.{ .name = "janet-movopt-test", .root_module = movopt_test_module });
    installTest(b, options, movopt_test);
    const run_movopt_test = b.addRunArtifact(movopt_test);
    subsystem_step.dependOn(&run_movopt_test.step);

    const emit_core_test_module = makeCModule(b, target, optimize, config_header, options);
    emit_core_test_module.addIncludePath(b.path("src/core"));
    emit_core_test_module.addCSourceFiles(.{ .files = &.{"test/emit_core.c"}, .flags = test_c_flags });
    emit_core_test_module.linkLibrary(static_library);
    const emit_core_test = b.addExecutable(.{ .name = "janet-emit-core-test", .root_module = emit_core_test_module });
    installTest(b, options, emit_core_test);
    const run_emit_core_test = b.addRunArtifact(emit_core_test);
    subsystem_step.dependOn(&run_emit_core_test.step);

    if (options.assembler) {
        const asm_encode_test_module = makeCModule(b, target, optimize, config_header, options);
        asm_encode_test_module.addCSourceFiles(.{ .files = &.{"test/asm_encode.c"}, .flags = test_c_flags });
        asm_encode_test_module.linkLibrary(static_library);
        const asm_encode_test = b.addExecutable(.{ .name = "janet-asm-encode-test", .root_module = asm_encode_test_module });
        installTest(b, options, asm_encode_test);
        const run_asm_encode_test = b.addRunArtifact(asm_encode_test);
        subsystem_step.dependOn(&run_asm_encode_test.step);

        const asm_decode_test_module = makeCModule(b, target, optimize, config_header, options);
        asm_decode_test_module.addCSourceFiles(.{ .files = &.{"test/asm_decode.c"}, .flags = test_c_flags });
        asm_decode_test_module.linkLibrary(static_library);
        const asm_decode_test = b.addExecutable(.{ .name = "janet-asm-decode-test", .root_module = asm_decode_test_module });
        installTest(b, options, asm_decode_test);
        const run_asm_decode_test = b.addRunArtifact(asm_decode_test);
        subsystem_step.dependOn(&run_asm_decode_test.step);

        const disasm_test_module = makeCModule(b, target, optimize, config_header, options);
        disasm_test_module.addCSourceFiles(.{ .files = &.{"test/disasm.c"}, .flags = test_c_flags });
        disasm_test_module.linkLibrary(static_library);
        const disasm_test = b.addExecutable(.{ .name = "janet-disasm-test", .root_module = disasm_test_module });
        installTest(b, options, disasm_test);
        const run_disasm_test = b.addRunArtifact(disasm_test);
        subsystem_step.dependOn(&run_disasm_test.step);
    }

    const compiler_primitives_test_module = makeCModule(b, target, optimize, config_header, options);
    compiler_primitives_test_module.addIncludePath(b.path("src/core"));
    compiler_primitives_test_module.addCSourceFiles(.{ .files = &.{"test/compiler_primitives.c"}, .flags = test_c_flags });
    compiler_primitives_test_module.linkLibrary(static_library);
    const compiler_primitives_test = b.addExecutable(.{ .name = "janet-compiler-primitives-test", .root_module = compiler_primitives_test_module });
    installTest(b, options, compiler_primitives_test);
    const run_compiler_primitives_test = b.addRunArtifact(compiler_primitives_test);
    subsystem_step.dependOn(&run_compiler_primitives_test.step);

    const specials_core_test_module = makeCModule(b, target, optimize, config_header, options);
    specials_core_test_module.addIncludePath(b.path("src/core"));
    specials_core_test_module.addCSourceFiles(.{ .files = &.{"test/specials_core.c"}, .flags = test_c_flags });
    specials_core_test_module.linkLibrary(static_library);
    const specials_core_test = b.addExecutable(.{ .name = "janet-specials-core-test", .root_module = specials_core_test_module });
    installTest(b, options, specials_core_test);
    const run_specials_core_test = b.addRunArtifact(specials_core_test);
    subsystem_step.dependOn(&run_specials_core_test.step);

    const number_scan_test_module = makeCModule(b, target, optimize, config_header, options);
    number_scan_test_module.addIncludePath(b.path("src/core"));
    number_scan_test_module.addCSourceFiles(.{ .files = &.{"test/numscan.c"}, .flags = test_c_flags });
    number_scan_test_module.linkLibrary(static_library);
    const number_scan_test = b.addExecutable(.{ .name = "janet-numscan-test", .root_module = number_scan_test_module });
    installTest(b, options, number_scan_test);
    const run_number_scan_test = b.addRunArtifact(number_scan_test);
    subsystem_step.dependOn(&run_number_scan_test.step);

    const math_test_module = makeCModule(b, target, optimize, config_header, options);
    math_test_module.addCSourceFiles(.{ .files = &.{"test/math.c"}, .flags = test_c_flags });
    math_test_module.linkLibrary(static_library);
    const math_test = b.addExecutable(.{ .name = "janet-math-test", .root_module = math_test_module });
    installTest(b, options, math_test);
    const run_math_test = b.addRunArtifact(math_test);
    subsystem_step.dependOn(&run_math_test.step);

    if (options.int_types) {
        const int_types_core_test_module = makeCModule(b, target, optimize, config_header, options);
        int_types_core_test_module.addCSourceFiles(.{ .files = &.{"test/inttypes.c"}, .flags = test_c_flags });
        int_types_core_test_module.linkLibrary(static_library);
        const int_types_core_test = b.addExecutable(.{ .name = "janet-inttypes-test", .root_module = int_types_core_test_module });
        installTest(b, options, int_types_core_test);
        const run_int_types_core_test = b.addRunArtifact(int_types_core_test);
        subsystem_step.dependOn(&run_int_types_core_test.step);
    }

    if (!options.reduced_os) {
        const os_permissions_test_module = makeCModule(b, target, optimize, config_header, options);
        os_permissions_test_module.addCSourceFiles(.{ .files = &.{"test/os_permissions.c"}, .flags = test_c_flags });
        os_permissions_test_module.linkLibrary(static_library);
        const os_permissions_test = b.addExecutable(.{ .name = "janet-os-permissions-test", .root_module = os_permissions_test_module });
        installTest(b, options, os_permissions_test);
        const run_os_permissions_test = b.addRunArtifact(os_permissions_test);
        subsystem_step.dependOn(&run_os_permissions_test.step);
    }

    const os_platform_test_module = makeCModule(b, target, optimize, config_header, options);
    os_platform_test_module.addCSourceFiles(.{ .files = &.{"test/os_platform.c"}, .flags = test_c_flags });
    os_platform_test_module.linkLibrary(static_library);
    const os_platform_test = b.addExecutable(.{ .name = "janet-os-platform-test", .root_module = os_platform_test_module });
    installTest(b, options, os_platform_test);
    const run_os_platform_test = b.addRunArtifact(os_platform_test);
    subsystem_step.dependOn(&run_os_platform_test.step);

    if (!options.reduced_os) {
        const os_environ_test_module = makeCModule(b, target, optimize, config_header, options);
        os_environ_test_module.addCSourceFiles(.{ .files = &.{"test/os_environ.c"}, .flags = test_c_flags });
        os_environ_test_module.linkLibrary(static_library);
        const os_environ_test = b.addExecutable(.{ .name = "janet-os-environ-test", .root_module = os_environ_test_module });
        installTest(b, options, os_environ_test);
        const run_os_environ_test = b.addRunArtifact(os_environ_test);
        subsystem_step.dependOn(&run_os_environ_test.step);

        const os_fs_test_module = makeCModule(b, target, optimize, config_header, options);
        os_fs_test_module.addCSourceFiles(.{ .files = &.{"test/os_fs.c"}, .flags = test_c_flags });
        os_fs_test_module.linkLibrary(static_library);
        const os_fs_test = b.addExecutable(.{ .name = "janet-os-fs-test", .root_module = os_fs_test_module });
        installTest(b, options, os_fs_test);
        const run_os_fs_test = b.addRunArtifact(os_fs_test);
        subsystem_step.dependOn(&run_os_fs_test.step);

        const os_stat_test_module = makeCModule(b, target, optimize, config_header, options);
        os_stat_test_module.addCSourceFiles(.{ .files = &.{"test/os_stat.c"}, .flags = test_c_flags });
        os_stat_test_module.linkLibrary(static_library);
        const os_stat_test = b.addExecutable(.{ .name = "janet-os-stat-test", .root_module = os_stat_test_module });
        installTest(b, options, os_stat_test);
        const run_os_stat_test = b.addRunArtifact(os_stat_test);
        subsystem_step.dependOn(&run_os_stat_test.step);

        const os_time_test_module = makeCModule(b, target, optimize, config_header, options);
        os_time_test_module.addCSourceFiles(.{ .files = &.{"test/os_time.c"}, .flags = test_c_flags });
        os_time_test_module.addIncludePath(b.path("src/core"));
        os_time_test_module.linkLibrary(static_library);
        const os_time_test = b.addExecutable(.{ .name = "janet-os-time-test", .root_module = os_time_test_module });
        installTest(b, options, os_time_test);
        const run_os_time_test = b.addRunArtifact(os_time_test);
        subsystem_step.dependOn(&run_os_time_test.step);

        const os_fs_paths_test_module = makeCModule(b, target, optimize, config_header, options);
        os_fs_paths_test_module.addCSourceFiles(.{ .files = &.{"test/os_fs_paths.c"}, .flags = test_c_flags });
        os_fs_paths_test_module.linkLibrary(static_library);
        const os_fs_paths_test = b.addExecutable(.{ .name = "janet-os-fs-paths-test", .root_module = os_fs_paths_test_module });
        installTest(b, options, os_fs_paths_test);
        const run_os_fs_paths_test = b.addRunArtifact(os_fs_paths_test);
        subsystem_step.dependOn(&run_os_fs_paths_test.step);
    }

    if (hasProcesses(options)) {
        const os_process_test_module = makeCModule(b, target, optimize, config_header, options);
        os_process_test_module.addCSourceFiles(.{ .files = &.{"test/os_process.c"}, .flags = test_c_flags });
        os_process_test_module.linkLibrary(static_library);
        const os_process_test = b.addExecutable(.{ .name = "janet-os-process-test", .root_module = os_process_test_module });
        installTest(b, options, os_process_test);
        const run_os_process_test = b.addRunArtifact(os_process_test);
        subsystem_step.dependOn(&run_os_process_test.step);
    }

    if (hasEv(options)) {
        const ev_core_test_module = makeCModule(b, target, optimize, config_header, options);
        ev_core_test_module.addCSourceFiles(.{ .files = &.{"test/ev_core.c"}, .flags = test_c_flags });
        ev_core_test_module.linkLibrary(static_library);
        const ev_core_test = b.addExecutable(.{ .name = "janet-ev-core-test", .root_module = ev_core_test_module });
        installTest(b, options, ev_core_test);
        const run_ev_core_test = b.addRunArtifact(ev_core_test);
        subsystem_step.dependOn(&run_ev_core_test.step);
    }

    if (hasFilewatch(options)) {
        const filewatch_flags_test_module = makeCModule(b, target, optimize, config_header, options);
        filewatch_flags_test_module.addCSourceFiles(.{ .files = &.{"test/filewatch_flags.c"}, .flags = test_c_flags });
        filewatch_flags_test_module.linkLibrary(static_library);
        const filewatch_flags_test = b.addExecutable(.{ .name = "janet-filewatch-flags-test", .root_module = filewatch_flags_test_module });
        installTest(b, options, filewatch_flags_test);
        const run_filewatch_flags_test = b.addRunArtifact(filewatch_flags_test);
        subsystem_step.dependOn(&run_filewatch_flags_test.step);
    }

    if (options.ffi) {
        const ffi_layout_test_module = makeCModule(b, target, optimize, config_header, options);
        ffi_layout_test_module.addCSourceFiles(.{ .files = &.{"test/ffi_layout.c"}, .flags = test_c_flags });
        ffi_layout_test_module.linkLibrary(static_library);
        const ffi_layout_test = b.addExecutable(.{ .name = "janet-ffi-layout-test", .root_module = ffi_layout_test_module });
        installTest(b, options, ffi_layout_test);
        const run_ffi_layout_test = b.addRunArtifact(ffi_layout_test);
        subsystem_step.dependOn(&run_ffi_layout_test.step);

        const ffi_classify_test_module = makeCModule(b, target, optimize, config_header, options);
        ffi_classify_test_module.addCSourceFiles(.{ .files = &.{"test/ffi_classify.c"}, .flags = test_c_flags });
        ffi_classify_test_module.linkLibrary(static_library);
        const ffi_classify_test = b.addExecutable(.{ .name = "janet-ffi-classify-test", .root_module = ffi_classify_test_module });
        installTest(b, options, ffi_classify_test);
        const run_ffi_classify_test = b.addRunArtifact(ffi_classify_test);
        subsystem_step.dependOn(&run_ffi_classify_test.step);
    }

    const io_core_test_module = makeCModule(b, target, optimize, config_header, options);
    io_core_test_module.addCSourceFiles(.{ .files = &.{"test/io_core.c"}, .flags = test_c_flags });
    io_core_test_module.linkLibrary(static_library);
    const io_core_test = b.addExecutable(.{ .name = "janet-io-core-test", .root_module = io_core_test_module });
    installTest(b, options, io_core_test);
    const run_io_core_test = b.addRunArtifact(io_core_test);
    subsystem_step.dependOn(&run_io_core_test.step);

    const parser_core_test_module = makeCModule(b, target, optimize, config_header, options);
    parser_core_test_module.addCSourceFiles(.{ .files = &.{"test/parser_core.c"}, .flags = test_c_flags });
    parser_core_test_module.linkLibrary(static_library);
    const parser_core_test = b.addExecutable(.{ .name = "janet-parser-core-test", .root_module = parser_core_test_module });
    installTest(b, options, parser_core_test);
    const run_parser_core_test = b.addRunArtifact(parser_core_test);
    subsystem_step.dependOn(&run_parser_core_test.step);

    const vm_state_test_module = makeCModule(b, target, optimize, config_header, options);
    vm_state_test_module.addIncludePath(b.path("src/core"));
    vm_state_test_module.addCSourceFiles(.{ .files = &.{"test/vm_state.c"}, .flags = test_c_flags });
    vm_state_test_module.linkLibrary(static_library);
    const vm_state_test = b.addExecutable(.{ .name = "janet-vm-state-test", .root_module = vm_state_test_module });
    installTest(b, options, vm_state_test);
    const run_vm_state_test = b.addRunArtifact(vm_state_test);
    subsystem_step.dependOn(&run_vm_state_test.step);

    const signal_core_test_module = makeCModule(b, target, optimize, config_header, options);
    signal_core_test_module.addIncludePath(b.path("src/core"));
    signal_core_test_module.addCSourceFiles(.{ .files = &.{"test/signal_core.c"}, .flags = test_c_flags });
    signal_core_test_module.linkLibrary(static_library);
    const signal_core_test = b.addExecutable(.{ .name = "janet-signal-core-test", .root_module = signal_core_test_module });
    installTest(b, options, signal_core_test);
    const run_signal_core_test = b.addRunArtifact(signal_core_test);
    subsystem_step.dependOn(&run_signal_core_test.step);

    const trace_frames_test_module = makeCModule(b, target, optimize, config_header, options);
    trace_frames_test_module.addIncludePath(b.path("src/core"));
    trace_frames_test_module.addCSourceFiles(.{ .files = &.{"test/trace_frames.c"}, .flags = test_c_flags });
    trace_frames_test_module.linkLibrary(static_library);
    const trace_frames_test = b.addExecutable(.{ .name = "janet-trace-frames-test", .root_module = trace_frames_test_module });
    installTest(b, options, trace_frames_test);
    const run_trace_frames_test = b.addRunArtifact(trace_frames_test);
    subsystem_step.dependOn(&run_trace_frames_test.step);

    const fiber_core_test_module = makeCModule(b, target, optimize, config_header, options);
    fiber_core_test_module.addIncludePath(b.path("src/core"));
    fiber_core_test_module.addCSourceFiles(.{ .files = &.{"test/fiber_core.c"}, .flags = test_c_flags });
    fiber_core_test_module.linkLibrary(static_library);
    const fiber_core_test = b.addExecutable(.{ .name = "janet-fiber-core-test", .root_module = fiber_core_test_module });
    installTest(b, options, fiber_core_test);
    const run_fiber_core_test = b.addRunArtifact(fiber_core_test);
    subsystem_step.dependOn(&run_fiber_core_test.step);

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
    addCliChecks(b, test_step, client, c_client);

    if (options.dynamic_modules and target.result.os.tag != .windows) {
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
    c_client: *std.Build.Step.Compile,
) void {
    const clients = [_]*std.Build.Step.Compile{ zig_client, c_client };
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
        .vector = b.option(SubsystemImplementation, "vector", "Select the vector implementation (c or zig)") orelse .zig,
        .utilities = b.option(SubsystemImplementation, "utilities", "Select the pure utility implementation (c or zig)") orelse .zig,
        .int_scan = b.option(SubsystemImplementation, "int-scan", "Select the 64-bit integer scanner (c or zig)") orelse .zig,
        .text_scan = b.option(SubsystemImplementation, "text-scan", "Select UTF-8 and symbol validation (c or zig)") orelse .zig,
        .regalloc = b.option(SubsystemImplementation, "regalloc", "Select the compiler register allocator (c or zig)") orelse .zig,
        .verify = b.option(SubsystemImplementation, "verify", "Select the bytecode verifier (c or zig)") orelse .zig,
        .remove_noops = b.option(SubsystemImplementation, "remove-noops", "Select bytecode no-op removal (c or zig)") orelse .zig,
        .movopt = b.option(SubsystemImplementation, "movopt", "Select bytecode dead-write optimization (c or zig)") orelse .zig,
        .emit_core = b.option(SubsystemImplementation, "emit-core", "Select compiler emitter core (c or zig)") orelse .zig,
        .asm_encode = b.option(SubsystemImplementation, "asm-encode", "Select assembly instruction encoding (c or zig)") orelse .zig,
        .asm_decode = b.option(SubsystemImplementation, "asm-decode", "Select assembly instruction decoding (c or zig)") orelse .zig,
        .disasm = b.option(SubsystemImplementation, "disasm", "Select function disassembly (c or zig)") orelse .zig,
        .compiler_primitives = b.option(SubsystemImplementation, "compiler-primitives", "Select compiler slot and funcdef primitives (c or zig)") orelse .zig,
        .parser_core = b.option(SubsystemImplementation, "parser-core", "Select parser lifecycle and result queue implementation (c or zig)") orelse .zig,
        .specials_core = b.option(SubsystemImplementation, "specials-core", "Select simple special-form implementations (c or zig)") orelse .zig,
        .builtin_optimizers = b.option(SubsystemImplementation, "builtin-optimizers", "Select the builtin optimizer registry (c or zig)") orelse .zig,
        .number_scan = b.option(SubsystemImplementation, "number-scan", "Select number scanning and double formatting (c or zig)") orelse .zig,
        .math_core = b.option(SubsystemImplementation, "math-core", "Select the random number generator and math kernels (c or zig)") orelse .zig,
        .int_types_core = b.option(SubsystemImplementation, "int-types-core", "Select the 64-bit integer numeric kernels (c or zig)") orelse .zig,
        .os_permissions = b.option(SubsystemImplementation, "os-permissions", "Select OS permission parsing and formatting (c or zig)") orelse .zig,
        .os_platform = b.option(SubsystemImplementation, "os-platform", "Select OS, architecture, compiler, and CPU detection (c or zig)") orelse .zig,
        .os_environ = b.option(SubsystemImplementation, "os-environ", "Select environment scanning and host operations (c or zig)") orelse .zig,
        .os_fs = b.option(SubsystemImplementation, "os-fs", "Select basic filesystem host operations (c or zig)") orelse .zig,
        .os_stat = b.option(SubsystemImplementation, "os-stat", "Select file metadata classification and the stat field registry (c or zig)") orelse .zig,
        .os_time = b.option(SubsystemImplementation, "os-time", "Select the platform clock shim, wall clock, and sleep (c or zig)") orelse .zig,
        .os_fs_paths = b.option(SubsystemImplementation, "os-fs-paths", "Select directory enumeration, links, timestamps, and canonical paths (c or zig)") orelse .zig,
        .io_core = b.option(SubsystemImplementation, "io-core", "Select file mode parsing and the stream host operations (c or zig)") orelse .zig,
        .os_process = b.option(SubsystemImplementation, "os-process", "Select the process control kernels and host operations (c or zig)") orelse .zig,
        .ev_core = b.option(SubsystemImplementation, "ev-core", "Select the event loop queue, timeout heap ordering, and timestamp kernels (c or zig)") orelse .zig,
        .ffi_layout = b.option(SubsystemImplementation, "ffi-layout", "Select the FFI type name tables and struct layout kernels (c or zig)") orelse .zig,
        .ffi_classify = b.option(SubsystemImplementation, "ffi-classify", "Select the FFI register classification and argument allocation kernels (c or zig)") orelse .zig,
        .filewatch_flags = b.option(SubsystemImplementation, "filewatch-flags", "Select the file watcher's keyword vocabularies for every backend (c or zig)") orelse .zig,
        .vm_state = b.option(SubsystemImplementation, "vm-state", "Select the thread-local JanetVM storage and the operations over it as a whole (c or zig)") orelse .zig,
        .fiber_core = b.option(SubsystemImplementation, "fiber-core", "Select the fiber stack frame, funcframe, and function environment machinery (c or zig)") orelse .zig,
        .signal_core = b.option(SubsystemImplementation, "signal-core", "Select the try scope, signal decision, and signal injection machinery (c or zig)") orelse .zig,
        .trace_frames = b.option(SubsystemImplementation, "trace-frames", "Select the stack frame decoding behind stack traces (c or zig)") orelse .zig,
        .install_tests = b.option(bool, "install-tests", "Install the C contract test executables so they can be run on another machine") orelse false,
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
        .call_trampoline = b.option(bool, "call-trampoline", "Enter cfunctions from JOP_CALL/JOP_TAILCALL through a per-call setjmp scope (Phase 7 groundwork; see SPIKE-7.md)") orelse false,
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
        defineIf(options.call_trampoline, "JANET_CALL_TRAMPOLINE"),
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
    module.linkSystemLibrary("c", .{});
    linkPlatformLibraries(module, target.result.os.tag, options.single_threaded);
}

fn makeRuntimeModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    config_header: std.Build.LazyPath,
    image_source: std.Build.LazyPath,
    options: BuildOptions,
    subsystems: RuntimeSubsystems,
) *std.Build.Module {
    const module = makeCModule(b, target, optimize, config_header, options);
    addRuntimeSources(module, image_source, options, subsystems);
    return module;
}

fn addRuntimeSources(
    module: *std.Build.Module,
    image_source: std.Build.LazyPath,
    options: BuildOptions,
    subsystems: RuntimeSubsystems,
) void {
    module.addCSourceFiles(.{ .files = core_sources, .flags = common_c_flags });
    module.addCSourceFile(.{ .file = image_source, .flags = common_c_flags });
    switch (options.vector) {
        .c => module.addCSourceFiles(.{ .files = &.{"src/core/vector.c"}, .flags = common_c_flags }),
        .zig => module.addObject(subsystems.vector.?),
    }
    if (options.utilities == .zig) {
        module.addCMacro("JANET_ZIG_UTILS", "1");
        module.addObject(subsystems.utilities.?);
    }
    if (options.int_types and options.int_scan == .zig) {
        module.addCMacro("JANET_ZIG_INTSCAN", "1");
        module.addObject(subsystems.int_scan.?);
    }
    if (options.text_scan == .zig) {
        module.addCMacro("JANET_ZIG_TEXTSCAN", "1");
        module.addObject(subsystems.text_scan.?);
    }
    switch (options.regalloc) {
        .c => module.addCSourceFiles(.{ .files = &.{"src/core/regalloc.c"}, .flags = common_c_flags }),
        .zig => module.addObject(subsystems.regalloc.?),
    }
    if (options.verify == .zig) {
        module.addCMacro("JANET_ZIG_VERIFY", "1");
        module.addObject(subsystems.verify.?);
    }
    if (options.remove_noops == .zig) {
        module.addCMacro("JANET_ZIG_REMOVE_NOOPS", "1");
        module.addObject(subsystems.remove_noops.?);
    }
    if (options.movopt == .zig) {
        module.addCMacro("JANET_ZIG_MOVOPT", "1");
        module.addObject(subsystems.movopt.?);
    }
    if (options.emit_core == .zig) {
        module.addCMacro("JANET_ZIG_EMIT_CORE", "1");
        module.addObject(subsystems.emit_core.?);
    }
    if (options.assembler and options.asm_encode == .zig) {
        module.addCMacro("JANET_ZIG_ASM_ENCODE", "1");
        module.addObject(subsystems.asm_encode.?);
    }
    if (options.assembler and options.asm_decode == .zig) {
        module.addCMacro("JANET_ZIG_ASM_DECODE", "1");
        module.addObject(subsystems.asm_decode.?);
    }
    if (options.assembler and options.disasm == .zig) {
        module.addCMacro("JANET_ZIG_DISASM", "1");
        module.addObject(subsystems.disasm.?);
    }
    if (options.compiler_primitives == .zig) {
        module.addCMacro("JANET_ZIG_COMPILER_PRIMITIVES", "1");
        module.addObject(subsystems.compiler_primitives.?);
    }
    if (options.parser_core == .zig) {
        module.addCMacro("JANET_ZIG_PARSER_CORE", "1");
        module.addObject(subsystems.parser_core.?);
    }
    if (options.specials_core == .zig) {
        module.addCMacro("JANET_ZIG_SPECIALS_CORE", "1");
        module.addObject(subsystems.specials_core.?);
    }
    if (options.builtin_optimizers == .zig) {
        module.addCMacro("JANET_ZIG_BUILTIN_OPTIMIZERS", "1");
        module.addObject(subsystems.builtin_optimizers.?);
    }
    if (options.number_scan == .zig) {
        module.addCMacro("JANET_ZIG_NUMSCAN", "1");
        module.addObject(subsystems.number_scan.?);
    }
    if (options.math_core == .zig) {
        module.addCMacro("JANET_ZIG_MATH_CORE", "1");
        module.addObject(subsystems.math_core.?);
    }
    if (options.int_types and options.int_types_core == .zig) {
        module.addCMacro("JANET_ZIG_INT_TYPES_CORE", "1");
        module.addObject(subsystems.int_types_core.?);
    }
    if (!options.reduced_os and options.os_permissions == .zig) {
        module.addCMacro("JANET_ZIG_OS_PERMISSIONS", "1");
        module.addObject(subsystems.os_permissions.?);
    }
    if (options.os_platform == .zig) {
        module.addCMacro("JANET_ZIG_OS_PLATFORM", "1");
        module.addObject(subsystems.os_platform.?);
    }
    if (!options.reduced_os and options.os_environ == .zig) {
        module.addCMacro("JANET_ZIG_OS_ENVIRON", "1");
        module.addObject(subsystems.os_environ.?);
    }
    if (!options.reduced_os and options.os_fs == .zig) {
        module.addCMacro("JANET_ZIG_OS_FS", "1");
        module.addObject(subsystems.os_fs.?);
    }
    if (!options.reduced_os and options.os_stat == .zig) {
        module.addCMacro("JANET_ZIG_OS_STAT", "1");
        module.addObject(subsystems.os_stat.?);
    }
    if (hasGettime(options) and options.os_time == .zig) {
        module.addCMacro("JANET_ZIG_OS_TIME", "1");
        module.addObject(subsystems.os_time.?);
    }
    if (!options.reduced_os and options.os_fs_paths == .zig) {
        module.addCMacro("JANET_ZIG_OS_FS_PATHS", "1");
        module.addObject(subsystems.os_fs_paths.?);
    }
    if (options.io_core == .zig) {
        module.addCMacro("JANET_ZIG_IO_CORE", "1");
        module.addObject(subsystems.io_core.?);
    }
    if (hasProcesses(options) and options.os_process == .zig) {
        module.addCMacro("JANET_ZIG_OS_PROCESS", "1");
        module.addObject(subsystems.os_process.?);
    }
    if (hasEv(options) and options.ev_core == .zig) {
        module.addCMacro("JANET_ZIG_EV_CORE", "1");
        module.addObject(subsystems.ev_core.?);
    }
    if (options.ffi and options.ffi_layout == .zig) {
        module.addCMacro("JANET_ZIG_FFI_LAYOUT", "1");
        module.addObject(subsystems.ffi_layout.?);
    }
    if (options.ffi and options.ffi_classify == .zig) {
        module.addCMacro("JANET_ZIG_FFI_CLASSIFY", "1");
        module.addObject(subsystems.ffi_classify.?);
    }
    if (hasFilewatch(options) and options.filewatch_flags == .zig) {
        module.addCMacro("JANET_ZIG_FILEWATCH_FLAGS", "1");
        module.addObject(subsystems.filewatch_flags.?);
    }
    if (options.vm_state == .zig) {
        module.addCMacro("JANET_ZIG_VM_STATE", "1");
        module.addObject(subsystems.vm_state.?);
    }
    if (options.fiber_core == .zig) {
        module.addCMacro("JANET_ZIG_FIBER_CORE", "1");
        module.addObject(subsystems.fiber_core.?);
    }
    if (options.signal_core == .zig) {
        module.addCMacro("JANET_ZIG_SIGNAL_CORE", "1");
        module.addObject(subsystems.signal_core.?);
    }
    if (options.trace_frames == .zig) {
        module.addCMacro("JANET_ZIG_TRACE_FRAMES", "1");
        module.addObject(subsystems.trace_frames.?);
    }
    if (options.vector == .zig or options.regalloc == .zig or options.movopt == .zig or
        options.parser_core == .zig or options.number_scan == .zig or
        options.vm_state == .zig or options.fiber_core == .zig or
        options.signal_core == .zig or options.trace_frames == .zig or
        (hasEv(options) and options.ev_core == .zig))
    {
        module.addCSourceFiles(.{
            .files = &.{"src/zig/runtime_bridge.c"},
            .flags = common_c_flags,
        });
    }
}

/// `src/core/util.h` defines JANET_GETTIME unless the build is both reduced-OS
/// and single-threaded, and the clock shim exists only when it is defined.
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
fn hasFilewatch(options: BuildOptions) bool {
    return hasEv(options) and options.filewatch;
}

fn makeZigSubsystemObject(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    config_header: std.Build.LazyPath,
    options: BuildOptions,
    name: []const u8,
    source: []const u8,
) *std.Build.Step.Compile {
    // These objects are linked into the shared library as well as the static
    // one, and ELF shared objects require position-independent code. Mach-O is
    // always position independent, so omitting this only fails on ELF targets.
    const subsystem_module = b.createModule(.{
        .root_source_file = b.path(source),
        .target = target,
        .optimize = optimize,
        .pic = true,
    });
    configureCModule(b, subsystem_module, target, config_header, options);
    subsystem_module.addIncludePath(b.path("src/core"));
    const abi_module = b.createModule(.{
        .root_source_file = b.path("src/zig/abi.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
    });
    configureCModule(b, abi_module, target, config_header, options);
    addAbiIncludePath(b, abi_module);
    subsystem_module.addImport("abi", abi_module);
    return b.addObject(.{ .name = name, .root_module = subsystem_module });
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
