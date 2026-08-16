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
    "src/core/regalloc.c",
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
};

const common_c_flags = &.{
    "-std=c99",
    "-Wall",
    "-Wextra",
    "-fvisibility=hidden",
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
    };

    // Bootstrap tools must execute on the build host even during a cross build.
    const boot_module = makeCModule(b, b.graph.host, .Debug, config_header, options);
    boot_module.addCMacro("JANET_BOOTSTRAP", "1");
    boot_module.addCSourceFiles(.{ .files = core_sources, .flags = common_c_flags });
    boot_module.addCSourceFiles(.{ .files = &.{"src/core/vector.c"}, .flags = common_c_flags });
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
    c_abi_module.addCSourceFiles(.{ .files = &.{"test/abi.c"}, .flags = common_c_flags });
    const c_abi_test = b.addExecutable(.{ .name = "janet-c-abi-test", .root_module = c_abi_module });
    const run_c_abi_test = b.addRunArtifact(c_abi_test);
    abi_step.dependOn(&run_c_abi_test.step);

    const embed_module = makeCModule(b, target, optimize, config_header, options);
    embed_module.addCSourceFiles(.{ .files = &.{"test/embed.c"}, .flags = common_c_flags });
    embed_module.linkLibrary(static_library);
    const embed_test = b.addExecutable(.{ .name = "janet-embed-test", .root_module = embed_module });
    const run_embed_test = b.addRunArtifact(embed_test);
    abi_step.dependOn(&run_embed_test.step);

    const vector_test_module = makeCModule(b, target, optimize, config_header, options);
    vector_test_module.addIncludePath(b.path("src/core"));
    vector_test_module.addCSourceFiles(.{ .files = &.{"test/vector.c"}, .flags = common_c_flags });
    vector_test_module.linkLibrary(static_library);
    const vector_test = b.addExecutable(.{ .name = "janet-vector-test", .root_module = vector_test_module });
    const run_vector_test = b.addRunArtifact(vector_test);
    subsystem_step.dependOn(&run_vector_test.step);

    const utilities_test_module = makeCModule(b, target, optimize, config_header, options);
    utilities_test_module.addIncludePath(b.path("src/core"));
    utilities_test_module.addCSourceFiles(.{ .files = &.{"test/utils.c"}, .flags = common_c_flags });
    utilities_test_module.linkLibrary(static_library);
    const utilities_test = b.addExecutable(.{ .name = "janet-utilities-test", .root_module = utilities_test_module });
    const run_utilities_test = b.addRunArtifact(utilities_test);
    subsystem_step.dependOn(&run_utilities_test.step);

    if (options.int_types) {
        const int_scan_test_module = makeCModule(b, target, optimize, config_header, options);
        int_scan_test_module.addCSourceFiles(.{ .files = &.{"test/intscan.c"}, .flags = common_c_flags });
        int_scan_test_module.linkLibrary(static_library);
        const int_scan_test = b.addExecutable(.{ .name = "janet-intscan-test", .root_module = int_scan_test_module });
        const run_int_scan_test = b.addRunArtifact(int_scan_test);
        subsystem_step.dependOn(&run_int_scan_test.step);
    }

    const text_scan_test_module = makeCModule(b, target, optimize, config_header, options);
    text_scan_test_module.addIncludePath(b.path("src/core"));
    text_scan_test_module.addCSourceFiles(.{ .files = &.{"test/textscan.c"}, .flags = common_c_flags });
    text_scan_test_module.linkLibrary(static_library);
    const text_scan_test = b.addExecutable(.{ .name = "janet-textscan-test", .root_module = text_scan_test_module });
    const run_text_scan_test = b.addRunArtifact(text_scan_test);
    subsystem_step.dependOn(&run_text_scan_test.step);

    const zig_abi_module = b.createModule(.{
        .root_source_file = b.path("src/zig/abi_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    zig_abi_module.addIncludePath(b.path("src/include"));
    zig_abi_module.addIncludePath(b.path("src/zig"));
    zig_abi_module.addIncludePath(config_header.dirname());
    zig_abi_module.linkSystemLibrary("c", .{});
    const zig_abi_test = b.addTest(.{ .name = "janet-zig-abi-test", .root_module = zig_abi_module });
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
        \\{s}#endif
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
    });
    const generated = b.addWriteFiles();
    return generated.add("janetconf.h", header);
}

fn defineIf(enabled: bool, comptime name: []const u8) []const u8 {
    return if (enabled) "#define " ++ name ++ "\n" else "";
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
        .zig => {
            module.addObject(subsystems.vector.?);
            module.addCSourceFiles(.{
                .files = &.{"src/zig/runtime_bridge.c"},
                .flags = common_c_flags,
            });
        },
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
    const subsystem_module = b.createModule(.{
        .root_source_file = b.path(source),
        .target = target,
        .optimize = optimize,
    });
    configureCModule(b, subsystem_module, target, config_header, options);
    const abi_module = b.createModule(.{
        .root_source_file = b.path("src/zig/abi.zig"),
        .target = target,
        .optimize = optimize,
    });
    configureCModule(b, abi_module, target, config_header, options);
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
