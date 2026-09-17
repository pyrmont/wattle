//! The core environment. Thirty-six cfunctions, the native-module loader, the
//! bootstrap's inline assembler, the environment every other subsystem's
//! `lib*` registers into, and the three entry points that run Janet source.
//!
//! Building the core environment and running code in one are one subject
//! rather than two that sit together: `dobytes` takes the `tables.Table` to
//! run in, and running source means nothing without one.
//!
//! A cfunction that decides to raise returns `raise.Error` and its abi
//! delivers it. A cfunction that makes no such decision has no error channel
//! and is written as the plain `raise.CFunction` it is: `(describe x)` cannot
//! fail on its own account, and giving it an error union it never returns
//! would be ceremony rather than shape.
//!
//! The bootstrap half is compiled only into the image generator. `coreEnv` has
//! two implementations, chosen by `corefn.bootstrap`: the generator assembles
//! the environment from scratch, and the runtime unmarshals it from the image.
//! Zig does not analyse the branch it does not take, so the inline assembler
//! below is checked by a bootstrap build and by nothing else. The acceptance
//! matrix runs one.
//!
//! `loadLibs` calls seven subsystem `lib*` functions that exist only in some
//! configurations, so this file reads `config.peg` and its kin. `build.zig`
//! decides them and hands them over as comptime booleans, read in one place.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");
const builtin = @import("builtin");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const abstracts = @import("value/abstracts.zig");
const args_core = @import("args.zig");
const arrays = @import("value/arrays.zig");
const asm_core = @import("bytecode.zig");
const buffers = @import("value/buffers.zig");
const c = @import("cabi");
const capi = @import("capi.zig");
const clib = @import("dynlib.zig");
const compiler_primitives = @import("compiler.zig");
const config = @import("config");
const constants = @import("constants");
const corefn = @import("corefn.zig");
const ev_loop = @import("ev.zig");
const fatal = @import("fatal.zig");
const ffi = @import("ffi.zig");
const fibers = @import("value/fibers.zig");
const filewatch = @import("filewatch.zig");
const fingerprint = @import("../api/fingerprint.zig");
const functions = @import("value/functions.zig");
const gc_alloc = @import("gc.zig");
const gc_mark = @import("gc/mark.zig");
const interface = @import("../api/interface.zig");
const inttypes = @import("value/ints.zig");
const io_core = @import("io.zig");
const marsh = @import("marsh.zig");
const maps = @import("value/maps.zig");
const math = @import("math.zig");
const net = @import("net.zig");
const numscan = @import("scan.zig");
const order = @import("value/helpers/order.zig");
const os_surface = @import("os.zig");
const parser_core = @import("parser.zig");
const peg = @import("peg.zig");
const pp_describe = @import("pp.zig");
const pp_format = @import("pp/format.zig");
const raise = @import("../api/raise.zig");
const registry = @import("registry.zig");
const repr = @import("repr");
const stdio = @import("stdio.zig");
const strings = @import("value/strings.zig");
const structs = @import("value/structs.zig");
const symbols = @import("value/symbols.zig");
const tables = @import("value/tables.zig");
const trace_frames = @import("debug.zig");
const transients = @import("value/transients.zig");
const tuples = @import("value/tuples.zig");
const utils = @import("utils.zig");
const value = @import("value.zig");
const vectors = @import("value/vectors.zig");
const vm_entry = @import("vm/entry.zig");
const vm_lifecycle = @import("vm/lifecycle.zig");
const vm_state = @import("vm/state.zig");
const wrap = @import("value/helpers/wrap.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// `api/fingerprint.zig`'s number, as the sixteen digits `janet/api` is bound
/// to.
const api_z = fingerprint.hex(fingerprint.api);

/// Whether this build has 64-bit integer types, and the six other feature
/// gates `loadLibs` reads. `build.zig` decides each and hands it over as a
/// comptime boolean.
const bits64 = config.bits64;
const has_assembler = config.assembler;
const has_ev = config.ev;
const has_ffi = config.ffi;
const has_filewatch = config.filewatch;
const has_int_types = config.int_types;
const has_net = config.net;
const has_peg = config.peg;

/// The two version strings, as pointers `strings.cstring` can walk.
///
/// `config` has them as `[]const u8`, and a slice is not a pointer with a
/// sentinel: the bytes behind a Zig string literal happen to be
/// NUL-terminated, but `.ptr` does not say so and nothing would check it.
/// `comptimePrint` gives back `*const [N:0]u8`, which puts the sentinel in the
/// type.
const build_z = std.fmt.comptimePrint("{s}", .{config.build_name});
const version_z = std.fmt.comptimePrint("{s}", .{config.version});
const janet_version_z = std.fmt.comptimePrint("{s}", .{config.janet_version});

/// The core image, generated by `wattle-boot` and embedded rather than linked.
///
/// It is not a linked object: `build.zig` hands the generator's output to this
/// module as an anonymous import, and `@embedFile` reads it. The alternative
/// is two megabytes of hex literals in a generated source file.
///
/// Referenced only from the runtime branch below, and a container-level
/// declaration is analysed only when something references it, so the bootstrap
/// build, which has no image and is what produces one, never asks for the
/// import.
///
/// The length is the image and not a byte more. `@embedFile` gives a
/// sentinel-terminated array, so the NUL is there and `.len` excludes it, and
/// what the runtime hands `unmarshal` is exactly the marshalled stream. `pub`
/// for `test/core_env.zig`, which asserts that unmarshalling consumes exactly
/// `core_image.len` bytes. That is the claim the shortened length rests on,
/// and it is not one the runtime itself has any reason to make.
pub const core_image = @embedFile("wattle_image");

/// The bodies of `get` and `in`, hand-assembled: fetch, then compare the
/// result against nil so that a missing key takes the default.
const get_asm = [_]u32{
    opword(constants.Opcode.get) | (1 << 24),
    opword(constants.Opcode.load_nil) | (3 << 8),
    opword(constants.Opcode.equals) | (3 << 8) | (3 << 24),
    opword(constants.Opcode.jump_if) | (3 << 8) | (2 << 16),
    opword(constants.Opcode.@"return"),
    opword(constants.Opcode.@"return") | (2 << 8),
};

const in_asm = [_]u32{
    opword(constants.Opcode.in) | (1 << 24),
    opword(constants.Opcode.load_nil) | (3 << 8),
    opword(constants.Opcode.equals) | (3 << 8) | (3 << 24),
    opword(constants.Opcode.jump_if) | (3 << 8) | (2 << 16),
    opword(constants.Opcode.@"return"),
    opword(constants.Opcode.@"return") | (2 << 8),
};

/// The sandbox flags `(sandbox ...)` accepts, by keyword.
///
/// The slice's length is the terminator, so no null-name row is needed. The
/// order matters only in that `(sandbox ...)` reports an unknown keyword by
/// not finding it, so nothing depends on where a row sits.
const sandbox_options = [_]SandboxOption{
    .{ .name = "all", .flag = vm_lifecycle.Sandbox.all },
    .{ .name = "asm", .flag = vm_lifecycle.Sandbox.of(&.{"asm"}) },
    .{ .name = "chroot", .flag = vm_lifecycle.Sandbox.of(&.{"chroot"}) },
    .{ .name = "compile", .flag = vm_lifecycle.Sandbox.of(&.{"compile"}) },
    .{ .name = "env", .flag = vm_lifecycle.Sandbox.of(&.{"env"}) },
    .{ .name = "exit", .flag = vm_lifecycle.Sandbox.of(&.{"exit"}) },
    .{ .name = "ffi", .flag = vm_lifecycle.Sandbox.ffi },
    .{ .name = "ffi-define", .flag = vm_lifecycle.Sandbox.of(&.{"ffi_define"}) },
    .{ .name = "ffi-jit", .flag = vm_lifecycle.Sandbox.of(&.{"ffi_jit"}) },
    .{ .name = "ffi-use", .flag = vm_lifecycle.Sandbox.of(&.{"ffi_use"}) },
    .{ .name = "fs", .flag = vm_lifecycle.Sandbox.fs },
    .{ .name = "fs-read", .flag = vm_lifecycle.Sandbox.of(&.{"fs_read"}) },
    .{ .name = "fs-temp", .flag = vm_lifecycle.Sandbox.of(&.{"fs_temp"}) },
    .{ .name = "fs-write", .flag = vm_lifecycle.Sandbox.of(&.{"fs_write"}) },
    .{ .name = "hrtime", .flag = vm_lifecycle.Sandbox.of(&.{"hrtime"}) },
    .{ .name = "modules", .flag = vm_lifecycle.Sandbox.of(&.{"dynamic_modules"}) },
    .{ .name = "net", .flag = vm_lifecycle.Sandbox.net },
    .{ .name = "net-connect", .flag = vm_lifecycle.Sandbox.of(&.{"net_connect"}) },
    .{ .name = "net-listen", .flag = vm_lifecycle.Sandbox.of(&.{"net_listen"}) },
    .{ .name = "sandbox", .flag = vm_lifecycle.Sandbox.of(&.{"sandbox"}) },
    .{ .name = "signal", .flag = vm_lifecycle.Sandbox.of(&.{"signal"}) },
    .{ .name = "subprocess", .flag = vm_lifecycle.Sandbox.of(&.{"subprocess"}) },
    .{ .name = "threads", .flag = vm_lifecycle.Sandbox.of(&.{"threads"}) },
    .{ .name = "unmarshal", .flag = vm_lifecycle.Sandbox.of(&.{"unmarshal"}) },
};

/// Whether this target is Windows, which separates path segments differently
/// and has no `dlopen`.
const windows = builtin.os.tag == .windows;

// ==========================================================================
// Types
// ==========================================================================

/// `string`, `symbol`, `keyword` and `buffer` differ only in what they wrap
/// the concatenation in.
fn Concat(comptime finish: anytype) type {
    return struct {
        fn cfun(argv: []repr.Value) raise.Error!repr.Value {
            const b = buffers.new(0);
            for (argv) |a| try pp_describe.toStringB(b, a);
            return finish(b);
        }
    };
}

/// `_wattle_mod_config`: what a module was built against, which `native`
/// compares with the host's.
///
/// The module writes into the `abi.BuildConfig` the caller supplies, writing
/// the smaller of the caller's width and its own, and returns its own width.
/// A module built against a shorter `abi.BuildConfig` therefore reads as that
/// prefix rather than as a struct of the wrong size.
pub const ModuleConfig = ?*const fn (out: *abi.BuildConfig, size: usize) callconv(.c) usize;

/// `_wattle_init`: the environment to define into, and the table of every
/// crossing the module may make.
///
/// The table is a parameter rather than a set of symbols: the runtime exports
/// no `janet_*` name and the module declares none, so the only thing a loaded
/// `.so` has of this runtime is the pointer it is handed here.
pub const ModuleEntry = ?*const fn (*abi.Env, *const interface.Runtime) callconv(.c) void;

/// One row of `sandbox_options`: the keyword, and the permissions it names.
const SandboxOption = struct { name: [:0]const u8, flag: vm_lifecycle.Sandbox };

/// The four type-mask predicates, which differ only in the mask.
fn TypeFlagPredicate(comptime flags: repr.TagSet) type {
    return struct {
        fn cfun(argv: []repr.Value) raise.Error!repr.Value {
            try args_core.fixarity(argv, 1);
            return wrap.fromBoolean(repr.checkTypes(argv[0], flags));
        }
    };
}

// ==========================================================================
// Public functions
// ==========================================================================

/// Compares a module's `_wattle_mod_config` report with this build's
/// configuration bits, compiler version and interface fingerprint, in that
/// order, and returns the refusal for the first difference, or null.
///
/// `mod_config` is the module's `_wattle_mod_config`. `native` calls this for a
/// module it opened and the `quickbin` client for each module linked into it,
/// so both report a mismatch in the same words.
pub fn checkModuleConfig(
    mod_config: *const fn (out: *abi.BuildConfig, size: usize) callconv(.c) usize,
) ?strings.String {
    // Zeroed first, so that a module whose `abi.BuildConfig` is shorter than
    // this one's leaves the fields it does not have at zero rather than at
    // whatever the stack held. The width the module reports back is what a
    // later loader reads to tell a short report from a full one; nothing here
    // needs it, because a zero never matches a field this build compares.
    var modconf: abi.BuildConfig = .{};
    _ = mod_config(&modconf, @sizeOf(abi.BuildConfig));
    const host = fingerprint.build_config;
    if (host.bits != modconf.bits) {
        var host_text: [16]u8 = undefined;
        var module_text: [16]u8 = undefined;
        return configMismatch(
            "bits",
            host,
            modconf,
            bitsText(&host_text, host.bits),
            bitsText(&module_text, modconf.bits),
        );
    }
    if (!std.mem.eql(u8, &host.zig, &modconf.zig)) {
        var host_text: [33]u8 = undefined;
        var module_text: [33]u8 = undefined;
        return configMismatch(
            "zig version",
            host,
            modconf,
            zigText(&host_text, host.zig),
            zigText(&module_text, modconf.zig),
        );
    }
    if (host.api != modconf.api) {
        const host_text = fingerprint.hex(host.api);
        const module_text = fingerprint.hex(modconf.api);
        return configMismatch("api version", host, modconf, &host_text, &module_text);
    }
    return null;
}

/// The core environment, assembled in the bootstrap and unmarshalled in the
/// runtime. `replacements` is the table to define into.
pub fn coreEnv(replacements: ?*tables.Table) raise.Error!*tables.Table {
    return if (corefn.bootstrap)
        bootstrapCoreEnv(replacements)
    else
        imageCoreEnv(replacements);
}

/// `coreEnv` for a caller with no error channel.
pub fn coreEnvAbi(replacements: ?*tables.Table) *tables.Table {
    return raise.toAbi(coreEnv(replacements));
}

/// The forward lookup table an unmarshalled image resolves its symbol
/// references against.
pub fn coreLookupTable(replacements: ?*tables.Table) raise.Error!*tables.Table {
    const dict = tables.new(512);
    try loadLibs(dict);

    if (replacements) |table| {
        for (0..table.capacity) |i| {
            const kv = table.slots()[i];
            if (!repr.checkType(kv.key, repr.Tag.nil)) {
                tables.put(dict, kv.key, kv.value);
            }
        }
    }

    return dict;
}

/// Parses, compiles and runs `bytes`, one top-level form at a time.
///
/// What comes back is a set of `JANET_DO_ERROR_*` flags rather than a signal,
/// and diagnostics go to stderr: `vm/entry.zig`'s `continueFiber` gives back a
/// `Resumed` and the compiler gives back a status, so the failures this
/// function handles arrive as values already.
///
/// The error union is the other kind of failure: the diagnostic machinery
/// itself raising, from `(dyn :err)` or from a `tostring` callback inside a
/// trace. `boot.zig` is the one caller, and it must not drop that. Through a
/// reporting abi the raise becomes a report nobody consumes, `boot` reads the
/// zeroed status as success, and the process exits 0 in silence.
pub fn dobytes(
    env: *tables.Table,
    bytes: ?[*]const u8,
    len: i32,
    source_path: ?[*:0]const u8,
    out: ?*repr.Value,
) raise.Error!c_int {
    return dobytesImpl(env, if (bytes) |p| (if (len <= 0) &.{} else p[0..@intCast(len)]) else &.{}, source_path, out);
}

/// `dobytes` over a slice, which is where the work is.
pub fn dobytesImpl(
    env: *tables.Table,
    bytes: []const u8,
    source_path: ?[*:0]const u8,
    out: ?*repr.Value,
) raise.Error!c_int {
    var errflags: c_int = 0;
    var done = false;
    var index: i32 = 0;
    var ret = wrap.fromNil();
    var fiber: ?*fibers.Fiber = null;
    const where: ?strings.String = if (source_path) |p| strings.cstring(p) else null;

    if (where) |w| gc_alloc.gcroot(wrap.fromString(w));
    const path: [*:0]const u8 = if (source_path) |p| p else "<unknown>";
    const parser: *parser_core.Parser = @ptrCast(@alignCast(abstracts.newBytes(
        &parser_core.parserType,
        @sizeOf(parser_core.Parser),
    )));
    parser_core.parserInit(parser);
    gc_alloc.gcroot(wrap.fromAbstract(parser));

    while (!done) {
        while (parser_core.parserHasMore(parser)) {
            const form = parser_core.parserProduce(parser);
            const cres = try compiler_primitives.compile(form, env, where);
            if (cres.status == .ok) {
                const f = functions.thunk(cres.funcdef.?);
                // `fibers.new` refuses only on an arity mismatch, and a thunk
                // takes no arguments and is given none.
                const thunk_fiber = fibers.new(f, 64, &.{}) catch unreachable;
                fiber = thunk_fiber;
                thunk_fiber.env = env;
                const resumed = vm_entry.continueFiber(thunk_fiber, wrap.fromNil());
                ret = resumed.value;
                if (resumed.signal != abi.Signal.ok and resumed.signal != abi.Signal.event) {
                    try trace_frames.stacktraceExt(thunk_fiber, ret, "");
                    errflags |= constants.JANET_DO_ERROR_RUNTIME;
                    done = true;
                }
            } else {
                var line: i32 = @intCast(parser.line);
                var col: i32 = @intCast(parser.column);
                if (cres.error_mapping.line > 0 and cres.error_mapping.column > 0) {
                    line = cres.error_mapping.line;
                    col = cres.error_mapping.column;
                }
                const ctx = try pp_format.formatc("%s:%d:%d: compile error", .{ path, line, col });
                const errstr = try pp_format.formatc("%s: %s", .{ ctx, cres.@"error" });
                ret = wrap.fromString(errstr);
                // One line, both branches, and the context appears once.
                // `stacktraceExt` renders `ret`, which is `errstr`, which
                // begins with `ctx`, so printing `ctx` here as well prints the
                // context twice, and printing it with no separator runs it
                // straight into the trace's own `error: `.
                try eprintf("%s\n", .{errstr});
                if (cres.macrofiber != null) {
                    try trace_frames.stacktraceExt(cres.macrofiber, ret, "");
                }
                errflags |= constants.JANET_DO_ERROR_COMPILE;
                done = true;
            }
        }

        if (done) break;

        switch (parser_core.parserStatus(parser)) {
            .dead => done = true,
            .@"error" => {
                errflags |= constants.JANET_DO_ERROR_PARSE;
                const line: i32 = @intCast(parser.line);
                const col: i32 = @intCast(parser.column);
                const errstr = try pp_format.formatc("%s:%d:%d: parse error: %s", .{ path, line, col, parser_core.parserError(parser) });
                ret = wrap.fromString(errstr);
                try eprintf("%s\n", .{errstr});
                done = true;
            },
            else => {
                if (index >= @as(i32, @intCast(bytes.len))) {
                    try parser_core.eofChecked(parser);
                } else {
                    try parser_core.consumeChecked(parser, bytes[@intCast(index)]);
                    index += 1;
                }
            },
        }
    }

    _ = gc_alloc.gcunroot(wrap.fromAbstract(parser));
    if (where) |w| _ = gc_alloc.gcunroot(wrap.fromString(w));
    if (has_ev) {
        // Enter the event loop if we are not already in it.
        if (vm_state.current().stackn == 0) {
            if (fiber) |f| gc_alloc.gcroot(wrap.fromFiber(f));
            try ev_loop.loop();
            if (fiber) |f| {
                _ = gc_alloc.gcunroot(wrap.fromFiber(f));
                if (errflags == 0) ret = f.last_value;
            }
        }
    }
    if (out) |slot| slot.* = ret;
    return errflags;
}

/// The same over a NUL-terminated string, and the one abi left in this file's
/// run entry points: `test/core_env.zig` pins the length it computes by
/// calling it as an abi. Nothing in the runtime calls it.
pub fn dostring(
    env: *tables.Table,
    str: [*:0]const u8,
    source_path: ?[*:0]const u8,
    out: ?*repr.Value,
) c_int {
    var len: i32 = 0;
    while (str[@intCast(len)] != 0) len += 1;
    return raise.toAbi(dobytes(env, str, len, source_path, out));
}

/// Runs a fiber to completion, through the event loop where the build has one,
/// and reports its final status.
pub fn loopFiber(fiber: *fibers.Fiber) raise.Error!c_int {
    if (has_ev) {
        ev_loop.schedule(fiber, wrap.fromNil());
        try ev_loop.loop();
        return @intCast(@intFromEnum(fibers.status(fiber)));
    }
    const resumed = vm_entry.continueFiber(fiber, wrap.fromNil());
    if (resumed.signal != abi.Signal.ok and resumed.signal != abi.Signal.event) {
        try trace_frames.stacktraceExt(fiber, resumed.value, "");
    }
    return @intCast(@intFromEnum(resumed.signal));
}

/// `native` for a caller with no error channel.
pub fn nativeAbi(name: [*:0]const u8, err: *?strings.String) ModuleEntry {
    return raise.toAbi(native(name, err));
}

// ==========================================================================
// Private functions
// ==========================================================================

/// Passes a non-null allocation through. Running out of memory is fatal here
/// rather than raising, so a null ends the process.
inline fn allocated(pointer: ?*anyopaque) *anyopaque {
    if (pointer) |p| return p;
    fatal.outOfMemory();
}

/// Prints and aborts rather than raising. Both call sites in `range` are
/// checking the arithmetic above them rather than anything the caller
/// supplied.
inline fn assert(condition: bool, message: [*:0]const u8) void {
    if (!condition) fatal.fatal(message);
}

/// Spells a configuration bit set as hexadecimal digits in `buf`, at least
/// four of them, and returns `buf` as a C string.
///
/// `buf` is written over and holds the result until its caller returns.
fn bitsText(buf: *[16]u8, bits: c_uint) [*:0]const u8 {
    _ = c.snprintf(buf, buf.len, "%.4x", bits);
    return @ptrCast(buf);
}

/// Assembled from scratch, in the image generator. Everything here ends up in
/// the image, so this is the only place these thirty-odd bindings exist.
fn bootstrapCoreEnv(replacements: ?*tables.Table) raise.Error!*tables.Table {
    const env: *tables.Table = replacements orelse tables.new(0);

    quickAsmDef(env, .{ .tag = constants.JANET_FUN_CMP }, "cmp", 2, 2, 2, 2, &opOnly(constants.Opcode.compare.number() | @as(u32, 1 << 24)) ++ opOnly(constants.Opcode.@"return"), "(cmp x y)\n\n" ++
        "Returns -1 if x is strictly less than y, 1 if y is strictly greater " ++
        "than x, and 0 otherwise. To return 0, x and y must be the exact same type.");
    quickAsmDef(env, .{ .tag = constants.JANET_FUN_NEXT }, "next", 2, 1, 2, 2, &opOnly(constants.Opcode.next.number() | @as(u32, 1 << 24)) ++ opOnly(constants.Opcode.@"return"), "(next x &opt key)\n\n" ++
        "Gets the next key in `x`. Can be used to iterate through " ++
        "the keys of `x` in an unspecified order. Keys are guaranteed " ++
        "to be seen only once per iteration if `x` is not mutated " ++
        "during iteration. If `key` is `nil`, returns the first key. " ++
        "If `nil` is returned, there are no more keys to iterate " ++
        "through.\n" ++
        "\n" ++
        "`x` can be a bytes, indexed, dictionary, fiber, or abstract " ++
        "type with a suitable `next` method.");
    quickAsmDef(env, .{ .tag = constants.JANET_FUN_PROP }, "propagate", 2, 2, 2, 2, &opOnly(constants.Opcode.propagate.number() | @as(u32, 1 << 24)) ++ opOnly(constants.Opcode.@"return"), "(propagate x fiber)\n\n" ++
        "Propagate a signal from a fiber to the current fiber and " ++
        "set the last value of the current fiber to `x`.  The signal " ++
        "value is then available as the status of the current fiber. " ++
        "The resulting stack trace from the current fiber will include " ++
        "frames from fiber. If fiber is in a state that can be resumed, " ++
        "resuming the current fiber will first resume `fiber`. " ++
        "This function can be used to re-raise an error without losing " ++
        "the original stack trace.");
    quickAsmDef(env, .{ .tag = constants.JANET_FUN_DEBUG }, "debug", 1, 0, 1, 1, &opOnly(constants.Opcode.signal.number() | @as(u32, 2 << 24)) ++ opOnly(constants.Opcode.@"return"), "(debug &opt x)\n\n" ++
        "Throws a debug signal that can be caught by a parent fiber and used to inspect " ++
        "the running state of the current fiber. Returns the value passed in by resume.");
    quickAsmDef(env, .{ .tag = constants.JANET_FUN_ERROR }, "error", 1, 1, 1, 1, &opOnly(constants.Opcode.@"error"), "(error e)\n\n" ++
        "Throws an error e that can be caught and handled by a parent fiber.");
    quickAsmDef(env, .{ .tag = constants.JANET_FUN_YIELD }, "yield", 1, 0, 1, 2, &opOnly(constants.Opcode.signal.number() | @as(u32, 3 << 24)) ++ opOnly(constants.Opcode.@"return"), "(yield &opt x)\n\n" ++
        "Yield a value to a parent fiber. When a fiber yields, its execution is paused until " ++
        "another thread resumes it. The fiber will then resume, and the last yield call will " ++
        "return the value that was passed to resume.");
    quickAsmDef(env, .{ .tag = constants.JANET_FUN_CANCEL }, "cancel", 2, 2, 2, 2, &opOnly(constants.Opcode.cancel.number() | @as(u32, 1 << 24)) ++ opOnly(constants.Opcode.@"return"), "(cancel fiber err)\n\n" ++
        "Resume a fiber but have it immediately raise an error. This lets a programmer unwind a pending fiber. " ++
        "Returns the same result as resume.");
    quickAsmDef(env, .{ .tag = constants.JANET_FUN_RESUME }, "resume", 2, 1, 2, 2, &opOnly(constants.Opcode.@"resume".number() | @as(u32, 1 << 24)) ++ opOnly(constants.Opcode.@"return"), "(resume fiber &opt x)\n\n" ++
        "Resume a new or suspended fiber and optionally pass in a value to the fiber that " ++
        "will be returned to the last yield in the case of a pending fiber, or the argument to " ++
        "the dispatch function in the case of a new fiber. Returns either the return result of " ++
        "the fiber's dispatch function, or the value from the next yield call in fiber.");
    quickAsmDef(env, .{ .tag = constants.JANET_FUN_IN }, "in", 3, 2, 3, 4, &in_asm, "(in x key &opt dflt)\n\n" ++
        "Get value in `x` at `key`. For bytes and indexed " ++
        "types, `key` must be a non-negative interger in " ++
        "bounds or an error is raised. For dictionaries " ++
        "`key` must be a non-nil value and if not found, " ++
        "will return `dflt` if provided or `nil` otherwise.\n" ++
        "\n" ++
        "`x` can be a bytes, indexed, dictionary, fiber, or " ++
        "abstract type with a suitable `get` method.");
    // The slice below is `get_asm`'s own length. Upstream passes `in_asm`'s
    // here; the two arrays are the same length, so nothing observes the
    // difference.
    quickAsmDef(env, .{ .tag = constants.JANET_FUN_GET }, "get", 3, 2, 3, 4, &get_asm, "(get x key &opt dflt)\n\n" ++
        "Get the value mapped to `key` in `x`. Returns `dflt` " ++
        "or `nil` if `key` is not found. Similar to `in`, but " ++
        "will not throw an error if `key` is invalid for `x`. " ++
        "However, if `x` is an abstract type, its getter may " ++
        "throw an error.\n" ++
        "\n" ++
        "`x` can be a bytes, indexed, dictionary, fiber, or " ++
        "abstract type with a suitable `get` method.");
    quickAsmDef(env, .{ .tag = constants.JANET_FUN_PUT }, "put", 3, 3, 3, 3, &opOnly(constants.Opcode.put.number() | @as(u32, 1 << 16) | (2 << 24)) ++ opOnly(constants.Opcode.@"return"), "(put x key val)\n\n" ++
        "Associate `key` with `val` for mutable `x`. Arrays " ++
        "and buffers only accept non-negative integer keys, " ++
        "and will expand if an out of bounds value is " ++
        "provided. For an array, extra space will be filled " ++
        "with `nil`s, while for buffers, 0 bytes are used " ++
        "instead. For a table, putting a key that is in the " ++
        "table prototype will hide the association defined by " ++
        "the prototype, but will not mutate the prototype " ++
        "table. Putting a `nil` value into a table will " ++
        "remove the table's corresponding association. " ++
        "Returns `x`.");
    quickAsmDef(env, .{ .tag = constants.JANET_FUN_LENGTH }, "length", 1, 1, 1, 1, &opOnly(constants.Opcode.length) ++ opOnly(constants.Opcode.@"return"), "(length ds)\n\n" ++
        "Returns the length or count of a data structure in constant time as an integer. For " ++
        "structs and tables, returns the number of key-value pairs in the data structure.");
    quickAsmDef(env, .{ .tag = constants.JANET_FUN_BNOT }, "bnot", 1, 1, 1, 1, &opOnly(constants.Opcode.bnot) ++ opOnly(constants.Opcode.@"return"), "(bnot x)\n\nReturns the bit-wise inverse of integer x.");
    makeApply(env);

    // Variadic operators
    templatizeVarop(env, .{ .tag = constants.JANET_FUN_ADD }, "+", 0, 0, constants.Opcode.add, "(+ & xs)\n\n" ++
        "Returns the sum of all xs. If xs is empty, return 0.");
    templatizeVarop(env, .{ .tag = constants.JANET_FUN_SUBTRACT }, "-", 0, 0, constants.Opcode.subtract, "(- & xs)\n\n" ++
        "Returns the difference of xs. If xs is empty, returns 0. If xs has one element, returns the " ++
        "negative value of that element. Otherwise, returns the first element in xs minus the sum of " ++
        "the rest of the elements.");
    templatizeVarop(env, .{ .tag = constants.JANET_FUN_MULTIPLY }, "*", 1, 1, constants.Opcode.multiply, "(* & xs)\n\n" ++
        "Returns the product of all elements in xs. If xs is empty, returns 1.");
    templatizeVarop(env, .{ .tag = constants.JANET_FUN_DIVIDE }, "/", 1, 1, constants.Opcode.divide, "(/ & xs)\n\n" ++
        "Returns the quotient of xs. If xs is empty, returns 1. If xs has one value x, returns " ++
        "the reciprocal of x. Otherwise return the first value of xs repeatedly divided by the remaining " ++
        "values.");
    templatizeVarop(env, .{ .tag = constants.JANET_FUN_DIVIDE_FLOOR }, "div", 1, 1, constants.Opcode.divide_floor, "(div & xs)\n\n" ++
        "Returns the floored division of xs. If xs is empty, returns 1. If xs has one value x, returns " ++
        "the reciprocal of x. Otherwise return the first value of xs repeatedly divided by the remaining " ++
        "values.");
    templatizeVarop(env, .{ .tag = constants.JANET_FUN_MODULO }, "mod", 0, 1, constants.Opcode.modulo, "(mod & xs)\n\n" ++
        "Returns the result of applying the modulo operator on the first value of xs with each remaining value. " ++
        "`(mod x 0)` is defined to be `x`.");
    templatizeVarop(env, .{ .tag = constants.JANET_FUN_REMAINDER }, "%", 0, 1, constants.Opcode.remainder, "(% & xs)\n\n" ++
        "Returns the remainder of dividing the first value of xs by each remaining value.");
    templatizeVarop(env, .{ .tag = constants.JANET_FUN_BAND }, "band", -1, -1, constants.Opcode.band, "(band & xs)\n\n" ++
        "Returns the bit-wise and of all values in xs. Each x in xs must be an integer.");
    templatizeVarop(env, .{ .tag = constants.JANET_FUN_BOR }, "bor", 0, 0, constants.Opcode.bor, "(bor & xs)\n\n" ++
        "Returns the bit-wise or of all values in xs. Each x in xs must be an integer.");
    templatizeVarop(env, .{ .tag = constants.JANET_FUN_BXOR }, "bxor", 0, 0, constants.Opcode.bxor, "(bxor & xs)\n\n" ++
        "Returns the bit-wise xor of all values in xs. Each x in xs must be an integer.");
    templatizeVarop(env, .{ .tag = constants.JANET_FUN_LSHIFT }, "blshift", 1, 1, constants.Opcode.shift_left, "(blshift x & shifts)\n\n" ++
        "Returns the value of x bit shifted left by the sum of all values in shifts. x " ++
        "and each element in shift must be an integer.");
    templatizeVarop(env, .{ .tag = constants.JANET_FUN_RSHIFT }, "brshift", 1, 1, constants.Opcode.shift_right, "(brshift x & shifts)\n\n" ++
        "Returns the value of x bit shifted right by the sum of all values in shifts. x " ++
        "and each element in shift must be an integer.");
    templatizeVarop(env, .{ .tag = constants.JANET_FUN_RSHIFTU }, "brushift", 1, 1, constants.Opcode.shift_right_unsigned, "(brushift x & shifts)\n\n" ++
        "Returns the value of x bit shifted right by the sum of all values in shifts. x " ++
        "and each element in shift must be an integer. The sign of x is not preserved, so " ++
        "for positive shifts the return value will always be positive.");

    // Variadic comparators
    templatizeComparator(env, .{ .tag = constants.JANET_FUN_GT }, ">", false, constants.Opcode.greater_than, "(> & xs)\n\n" ++
        "Check if xs is in descending order. Returns a boolean.");
    templatizeComparator(env, .{ .tag = constants.JANET_FUN_LT }, "<", false, constants.Opcode.less_than, "(< & xs)\n\n" ++
        "Check if xs is in ascending order. Returns a boolean.");
    templatizeComparator(env, .{ .tag = constants.JANET_FUN_GTE }, ">=", false, constants.Opcode.greater_than_equal, "(>= & xs)\n\n" ++
        "Check if xs is in non-ascending order. Returns a boolean.");
    templatizeComparator(env, .{ .tag = constants.JANET_FUN_LTE }, "<=", false, constants.Opcode.less_than_equal, "(<= & xs)\n\n" ++
        "Check if xs is in non-descending order. Returns a boolean.");
    templatizeComparator(env, .{ .tag = constants.JANET_FUN_EQ }, "=", false, constants.Opcode.equals, "(= & xs)\n\n" ++
        "Check if all values in xs are equal. Returns a boolean.");
    templatizeComparator(env, .{ .tag = constants.JANET_FUN_NEQ }, "not=", true, constants.Opcode.equals, "(not= & xs)\n\n" ++
        "Check if any values in xs are not equal. Returns a boolean.");

    // Platform detection
    registry.def(env, "wattle/version", value.fromBytes(version_z, .string), "The version number of the running Wattle program.");
    registry.def(env, "janet/version", value.fromBytes(janet_version_z, .string), "The version of Janet the running program implements.");
    registry.def(env, "janet/build", value.fromBytes(build_z, .string), "The build identifier of the running Wattle program.");
    registry.def(env, "janet/api", value.fromBytes(&api_z, .string), "The fingerprint of the native module interface this program was built " ++
        "with, as sixteen hexadecimal digits. A native module loads only into a " ++
        "program whose janet/api and janet/config-bits are the same as the " ++
        "module's own, and that was built with the same version of Zig.");
    // The docstring is upstream's, `janetconf.h` and all: it is text a Janet
    // program reads with `(doc janet/config-bits)`, so it is behaviour rather
    // than prose and is preserved exactly.
    registry.def(env, "janet/config-bits", wrap.fromInteger(constants.JANET_CURRENT_CONFIG_BITS), "The flag set of config options from janetconf.h which is used to check " ++
        "if native modules are compatible with the host program.");

    // Allow references to the environment
    registry.def(env, "root-env", wrap.fromTable(env), "The root environment used to create environments with (make-env).");

    try loadLibs(env);
    gc_alloc.gcroot(wrap.fromTable(env));
    return env;
}

/// `(array & xs)`.
fn cfunArray(argv: []repr.Value) raise.Error!repr.Value {
    const array = arrays.new(argv.len);
    array.count = argv.len;
    @memcpy(array.reserved()[0..argv.len], argv);
    return wrap.fromArray(array);
}

/// `(int? x)`.
fn cfunCheckInt(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    return wrap.fromBoolean(args_core.checkint(argv[0]));
}

/// `(nat? x)`.
fn cfunCheckNat(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    if (!args_core.checkint(argv[0])) return wrap.fromFalse();
    return wrap.fromBoolean(wrap.toInteger(argv[0]) >= 0);
}

/// `(describe x)`, which cannot fail on its own account and so declares no
/// raise.
fn cfunDescribe(argv: []repr.Value) raise.Error!repr.Value {
    const b = buffers.new(0);
    for (argv) |a| try pp_describe.descriptionB(b, a);
    return value.fromBytes(b.slice(), .string);
}

/// `(dyn key &opt default)`.
fn cfunDyn(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, 2);
    const env = vm_state.current().fiber.?.env;
    const val = if (env) |dyns| tables.get(dyns, argv[0]) else wrap.fromNil();
    if (argv.len == 2 and repr.checkType(val, repr.Tag.nil)) return argv[1];
    return val;
}

/// `(module/expand-path path template)`.
fn cfunExpandPath(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 2);
    const input = try args_core.getCString(argv, 0);
    const template = try args_core.getCString(argv, 1);
    const curfile = try dynCString("current-file", "");
    const syspath = try dynCString("syspath", "");
    const out = buffers.new(0);
    const tlen = std.mem.len(template);
    const input_len = std.mem.len(input);

    // The name component: everything after the last separator.
    var name: usize = input_len;
    while (name > 0) {
        if (isPathSep(input[name - 1])) break;
        name -= 1;
    }

    // The directory component of `(dyn :current-file)`. This walk starts at
    // the terminator and tests the character it is *on* rather than the one
    // before it, so a path with a single leading separator reports the current
    // directory. That is what a Janet program sees.
    const curfile_len = std.mem.len(curfile);
    var curname: usize = curfile_len;
    while (curname > 0) {
        if (isPathSep(curfile[curname])) break;
        curname -= 1;
    }
    const curdir: [*:0]const u8 = if (curname == 0) "." else curfile;
    const curlen: i32 = if (curname == 0) 1 else @intCast(curname);

    var i: usize = 0;
    while (i < tlen) : (i += 1) {
        if (template[i] != ':') {
            try buffers.pushU8(out, template[i]);
            continue;
        }
        const rest: [*]const u8 = template + i;
        if (matches(rest, ":all:")) {
            try buffers.pushCString(out, input);
            i += 4;
        } else if (matches(rest, ":@all:")) {
            if (input[0] == '@') {
                var p: usize = 0;
                while (input[p] != 0 and !isPathSep(input[p])) p += 1;
                const len = p - 1;
                const str: [*]u8 = @ptrCast(allocated(gc_alloc.smalloc(len + 1)));
                @memcpy(str[0..len], input[1 .. 1 + len]);
                str[len] = 0;
                _ = try pp_format.formatb(out, "%V", .{vm_state.dyn(@ptrCast(str))});
                gc_alloc.sfree(str);
                try buffers.pushCString(out, input + p);
            } else {
                try buffers.pushCString(out, input);
            }
            i += 5;
        } else if (matches(rest, ":cur:")) {
            try buffers.pushBytes(out, curdir[0..@intCast(curlen)]);
            i += 4;
        } else if (matches(rest, ":dir:")) {
            try buffers.pushBytes(out, input[0..@intCast(name)]);
            i += 4;
        } else if (matches(rest, ":sys:")) {
            try buffers.pushCString(out, syspath);
            i += 4;
        } else if (matches(rest, ":name:")) {
            try buffers.pushCString(out, input + name);
            i += 5;
        } else if (matches(rest, ":native:")) {
            try buffers.pushCString(out, if (windows) ".dll" else ".so");
            i += 7;
        } else {
            try buffers.pushU8(out, ':');
        }
    }

    normalizePath(out);
    return wrap.fromBuffer(out);
}

/// `(gccollect)`.
fn cfunGccollect(argv: []repr.Value) raise.Error!repr.Value {
    _ = argv;
    gc_mark.collect();
    return wrap.fromNil();
}

/// `(gcinterval)`.
fn cfunGcinterval(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 0);
    return wrap.fromNumber(@floatFromInt(vm_state.current().gc.interval));
}

/// `(gcsetinterval interval)`.
fn cfunGcsetinterval(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const s = try args_core.getSize(argv, 0);
    // Limited to 48 bits, and only where a size is wider than that.
    if (bits64 and (s >> 48) != 0) return raise.panic("interval too large");
    vm_state.current().gc.interval = s;
    return wrap.fromNil();
}

/// `(gensym)`.
fn cfunGensym(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 0);
    return wrap.fromSymbol(symbols.gen());
}

/// `(getline &opt prompt buf env)`.
fn cfunGetline(argv: []repr.Value) raise.Error!repr.Value {
    const in = io_core.dynfile("in", stdio.in());
    const out = io_core.dynfile("out", stdio.out());
    try args_core.arity(argv, 0, 3);
    const buf = if (argv.len >= 2) try args_core.getBuffer(argv, 1) else buffers.new(10);
    if (argv.len >= 1) {
        const prompt = try args_core.getString(argv, 0);
        _ = c.fprintf(out, "%s", prompt);
        _ = c.fflush(out);
    }
    buf.count = 0;
    while (true) {
        const ch = c.fgetc(in);
        if (c.feof(in) != 0 or ch < 0) break;
        try buffers.pushU8(buf, @intCast(ch));
        if (ch == '\n') break;
    }
    return wrap.fromBuffer(buf);
}

/// `(getproto x)`.
fn cfunGetproto(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    if (repr.checkType(argv[0], repr.Tag.table)) {
        const t = wrap.toTable(argv[0]);
        return if (t.proto) |proto| wrap.fromTable(proto) else wrap.fromNil();
    }
    if (repr.checkType(argv[0], repr.Tag.@"struct")) {
        const st = wrap.toStruct(argv[0]);
        const proto = structs.head(st).proto;
        return if (proto) |p| wrap.fromStruct(p) else wrap.fromNil();
    }
    return pp_format.panicf("expected struct or table, got %v", .{argv[0]});
}

/// `(hash x)`.
fn cfunHash(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    return wrap.fromNumber(@floatFromInt(order.hash(argv[0])));
}

/// `(abstract? x)`.
fn cfunIsAbstract(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    return wrap.fromBoolean(repr.checkType(argv[0], repr.Tag.abstract));
}

/// `(dictionary? x)`: a table, a struct, or an abstract whose contents are
/// pairs.
fn cfunIsDictionary(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    return wrap.fromBoolean(args_core.checkdictionary(argv[0]));
}

/// `(indexed? x)`: an array, a vector, a tuple, or an abstract whose contents
/// are elements.
fn cfunIsIndexed(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    return wrap.fromBoolean(args_core.checkindexed(argv[0]));
}

/// `(memcmp a b &opt len offset-a offset-b)`.
fn cfunMemcmp(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 2, 5);
    const a = try args_core.getBytes(argv, 0);
    const b = try args_core.getBytes(argv, 1);
    const len = try args_core.optNat(argv, 2, @intCast(if (a.len < b.len) a.len else b.len));
    const offset_a = try args_core.optNat(argv, 3, 0);
    const offset_b = try args_core.optNat(argv, 4, 0);
    // The sum is taken wide so that the bound is right for every offset and
    // length a caller can pass: at `int32_t` a large offset and a large length
    // overflow the addition and let the comparison read off the end of both
    // views.
    if (@as(i64, offset_a) + @as(i64, len) > a.len) {
        return pp_format.panicf("invalid offset-a: %d", .{offset_a});
    }
    if (@as(i64, offset_b) + @as(i64, len) > b.len) {
        return pp_format.panicf("invalid offset-b: %d", .{offset_b});
    }
    const result = c.memcmp(
        a.bytes.? + @as(usize, @intCast(offset_a)),
        b.bytes.? + @as(usize, @intCast(offset_b)),
        @intCast(len),
    );
    return wrap.fromInteger(result);
}

/// `(native path &opt env)`: loads a `.so` and runs its `_wattle_init`.
fn cfunNative(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, 2);
    const argv0 = argv[0];
    const path = try args_core.getString(argv, 0);
    var err: ?strings.String = null;
    const env = if (argv.len == 2) try args_core.getTable(argv, 1) else tables.new(0);
    const loaded = try native(@ptrCast(path), &err);
    const init = loaded orelse {
        return pp_format.panicf("could not load native %S: %S", .{ path, err });
    };
    // Rooted against a collection triggered from inside the module's entry
    // point, which runs arbitrary third-party code.
    try fibers.push(vm_state.currentFiber(), wrap.fromTable(env));
    try raise.fromAbi(init(@ptrCast(env), &capi.table));
    tables.put(env, value.fromBytes("native", .keyword), argv0);
    return wrap.fromTable(env);
}

/// `(range start &opt end step)`.
fn cfunRange(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, 3);
    var start: f64 = 0;
    var stop: f64 = 0;
    var step: f64 = 1;
    var count: f64 = 0;
    if (argv.len == 3) {
        start = try args_core.getNumber(argv, 0);
        stop = try args_core.getNumber(argv, 1);
        step = try args_core.getNumber(argv, 2);
        count = if (step != 0.0) (stop - start) / step else 0.0;
    } else if (argv.len == 2) {
        start = try args_core.getNumber(argv, 0);
        stop = try args_core.getNumber(argv, 1);
        count = stop - start;
    } else {
        stop = try args_core.getNumber(argv, 0);
        count = stop;
    }
    if (std.math.isInf(step)) return raise.panic("infinite step not allowed");
    count = if (count > 0.0) count else 0.0;
    assert(count >= 0.0, "bad range code");
    if (count > @as(f64, @floatFromInt(std.math.maxInt(i32)))) {
        return pp_format.panicf("range is too large, %f elements", .{count});
    }
    const int_count: i32 = @intFromFloat(@ceil(count));
    if (step > 0.0) {
        assert(start + @as(f64, @floatFromInt(int_count)) * step >= stop, "bad range code");
    } else {
        assert(start + @as(f64, @floatFromInt(int_count)) * step <= stop, "bad range code");
    }
    const array = arrays.new(@intCast(int_count));
    const room = array.reserved();
    for (0..@as(usize, @intCast(int_count))) |i| {
        room[i] = wrap.fromNumber(start + @as(f64, @floatFromInt(i)) * step);
    }
    array.count = @intCast(int_count);
    return wrap.fromArray(array);
}

/// `(sandbox & flags)`, with each keyword looked up in `sandbox_options`.
fn cfunSandbox(argv: []repr.Value) raise.Error!repr.Value {
    var flags: vm_lifecycle.Sandbox = .{};
    for (0..argv.len) |i| {
        const kw = try args_core.getKeyword(argv, i);
        var found = false;
        for (sandbox_options) |option| {
            if (utils.cstrcmp(kw, option.name.ptr) == 0) {
                flags = flags.with(option.flag);
                found = true;
                break;
            }
        }
        if (!found) return pp_format.panicf("unknown capability %v", .{argv[i]});
    }
    try vm_lifecycle.sandbox(flags);
    return wrap.fromNil();
}

/// `(scan-number str &opt base)`.
fn cfunScanNumber(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, 2);
    const view = try args_core.getBytes(argv, 0);
    const base = try args_core.optInteger(argv, 1, 0);
    if (!(base == 0 or (base >= 2 and base <= 36))) {
        return pp_format.panicf("expected base between 2 and 36, got %d", .{base});
    }
    const number = numscan.scanNumberBase(args_core.viewBytes(view).ptr, @intCast(view.len), base) orelse
        return wrap.fromNil();
    return wrap.fromNumber(number);
}

/// `(setdyn key value)`.
fn cfunSetdyn(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 2);
    const fiber = vm_state.currentFiber();
    const dyns = fiber.env orelse made: {
        const fresh = tables.new(2);
        fiber.env = fresh;
        break :made fresh;
    };
    tables.put(dyns, argv[0], argv[1]);
    return argv[1];
}

/// `(signal what &opt payload)`, where `what` is a user signal number or a
/// keyword from `utils.signalNames`.
fn cfunSignal(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, 2);
    const payload = if (argv.len == 2) argv[1] else wrap.fromNil();
    if (args_core.checkint(argv[0])) {
        const s = wrap.toInteger(argv[0]);
        // 0 through 7, which is what `user0` through `user7` are. The two
        // signals past them are `interrupt` and `event`, so a wider bound here
        // would let a program raise the interpreter's own signals through the
        // form documented as the user one; the keyword form has no such gap,
        // because `signalNames` has no `:user8`.
        if (s < 0 or s > 7) {
            return pp_format.panicf("expected user signal between 0 and 7, got %d", .{s});
        }
        return raise.signal(@enumFromInt(@intFromEnum(abi.Signal.user0) + @as(c_uint, @intCast(s))), payload);
    }
    const kw = try args_core.getKeyword(argv, 0);
    for (utils.signalNames, 0..) |signal_name, i| {
        if (utils.cstrcmp(kw, signal_name) == 0) {
            return raise.signal(@enumFromInt(i), payload);
        }
    }
    return pp_format.panicf("unknown signal %v", .{argv[0]});
}

/// `(slice x &opt start end)`.
fn cfunSlice(argv: []repr.Value) raise.Error!repr.Value {
    // Read through `argSlot`, because `getSlice` is what checks the arity and
    // it runs after this: `(slice)` reaches here with no argument at all.
    const x = args_core.argSlot(argv, 0);
    if (args_core.bytesView(x)) |bytes| {
        const range = try args_core.getSlice(argv);
        return value.fromBytes(bytes[@intCast(range.start)..@intCast(range.end)], .string);
    } else if (try args_core.chunks(x)) |found| {
        var source = found;
        const range = try args_core.getSlice(argv);
        source.window(@intCast(range.start), @intCast(range.end));
        const length: usize = @intCast(range.end - range.start);
        return wrap.fromTuple(try tuples.newFromChunks(&source, length));
    }
    // The message is the fault layer's and has no spelling on this side.
    return args_core.panicIndexed(x, 0, repr.TagSet.bytes);
}

/// `(struct & kvs)`.
fn cfunStruct(argv: []repr.Value) raise.Error!repr.Value {
    if (argv.len & 1 != 0) return raise.panic("expected even number of arguments");
    const st = structs.begin(argv.len >> 1);
    var i: usize = 0;
    while (i + 1 < argv.len) : (i += 2) {
        structs.put(st, argv[i], argv[i + 1]);
    }
    return wrap.fromStruct(structs.end(st));
}

/// `(table & kvs)`.
fn cfunTable(argv: []repr.Value) raise.Error!repr.Value {
    if (argv.len & 1 != 0) return raise.panic("expected even number of arguments");
    const table = tables.new(argv.len >> 1);
    var i: usize = 0;
    while (i + 1 < argv.len) : (i += 2) {
        tables.put(table, argv[i], argv[i + 1]);
    }
    return wrap.fromTable(table);
}

/// `(trace f)`.
fn cfunTrace(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const func = try args_core.getFunction(argv, 0);
    functions.setTraced(func, true);
    return argv[0];
}

/// `(tuple & xs)`.
fn cfunTuple(argv: []repr.Value) raise.Error!repr.Value {
    return wrap.fromTuple(tuples.newFrom(argv));
}

/// `(type x)`.
fn cfunType(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const t = repr.typeOf(argv[0]);
    if (t == .abstract) {
        return value.fromBytes(abi.abstractHead(wrap.toAbstract(argv[0])).type.name, .keyword);
    }
    // A keyword has the symbol tag, and is told apart by its kind.
    if (wrap.isKeyword(argv[0])) return value.fromBytes("keyword", .keyword);
    return value.fromBytes(utils.typeNames[@intFromEnum(t)], .keyword);
}

/// `(untrace f)`.
fn cfunUntrace(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const func = try args_core.getFunction(argv, 0);
    functions.setTraced(func, false);
    return argv[0];
}

/// Builds the refusal `native` reports when a field of `abi.BuildConfig`
/// differs.
///
/// `field` names the field that differed, and `host_value` and `module_value`
/// are that field's two values already spelled as text. `host` and
/// `module_config` supply the two Janet versions, which the message reports
/// and `native` does not compare.
fn configMismatch(
    field: [*:0]const u8,
    host: abi.BuildConfig,
    module_config: abi.BuildConfig,
    host_value: [*:0]const u8,
    module_value: [*:0]const u8,
) strings.String {
    var errbuf: [256]u8 = undefined;
    // Both versions are spelled with `%d`. `%.d` is precision zero, which
    // writes nothing at all for a value of zero, so a host built from an
    // `x.0.y` release would report itself as `x..y` beside a module reporting
    // `x.0.y`: one message, two spellings of one field.
    _ = c.snprintf(
        &errbuf,
        errbuf.len,
        "config mismatch - %s - host %d.%d.%d(%s) vs. module %d.%d.%d(%s) - " ++
            "native needs to be recompiled!",
        field,
        host.major,
        host.minor,
        host.patch,
        host_value,
        module_config.major,
        module_config.minor,
        module_config.patch,
        module_value,
    );
    return strings.cstring(@ptrCast(&errbuf));
}

/// The string a dynamic binding names, or `dflt` where the binding is absent.
/// An embedded NUL is a raise, since the result is handed on as a C string.
fn dynCString(name: [*:0]const u8, dflt: [*:0]const u8) raise.Error![*:0]const u8 {
    const x = vm_state.dyn(name);
    if (repr.checkType(x, repr.Tag.nil)) return dflt;
    if (!repr.checkType(x, repr.Tag.string)) {
        return pp_format.panicf("expected string, got %v", .{x});
    }
    const jstr = wrap.toString(x);
    const cstr: [*:0]const u8 = @ptrCast(jstr);
    if (std.mem.len(cstr) != strings.head(jstr).length) {
        return pp_format.panicf("string %v contains embedded 0s", .{x});
    }
    return cstr;
}

/// A variadic `(dyn :err)` write. Zig cannot define a C variadic on every
/// target this builds for, but calling one is ordinary, so the three lines are
/// written out here; `ev.zig` and `debug.zig` have them for the same reason.
inline fn eprintf(comptime format: [:0]const u8, args: anytype) raise.Error!void {
    // `pp/format.dynprintf` can raise: `(dyn :err)` may be a Janet function,
    // and calling it can. Every caller here is raising, so the raise is
    // returned.
    return pp_format.dynprintf("err", stdio.err(), format, args);
}

/// `buffer`'s finisher, which hands the buffer itself back.
fn finishBuffer(b: *buffers.Buffer) repr.Value {
    return wrap.fromBuffer(b);
}

/// `keyword`'s finisher.
fn finishKeyword(b: *buffers.Buffer) repr.Value {
    return value.fromBytes(b.slice(), .keyword);
}

/// `string`'s finisher.
fn finishString(b: *buffers.Buffer) repr.Value {
    return value.fromBytes(b.slice(), .string);
}

/// `symbol`'s finisher.
fn finishSymbol(b: *buffers.Buffer) repr.Value {
    return value.fromBytes(b.slice(), .symbol);
}

/// Unmarshalled from the image, in the runtime. Memoized in the VM's
/// `core_env`, which is what makes the replacements argument meaningful only
/// on the first call.
fn imageCoreEnv(replacements: ?*tables.Table) raise.Error!*tables.Table {
    if (vm_state.current().core_env) |memoized| return memoized;

    const dict = try coreLookupTable(replacements);

    const marsh_out = try marsh.unmarshal(
        core_image[0..@intCast(core_image.len)],
        0,
        dict,
        null,
    );

    gc_alloc.gcroot(marsh_out);
    const env = wrap.toTable(marsh_out);
    vm_state.current().core_env = env;

    // The image is emitted by `wattle-boot`, which is built for the build host,
    // so a value it holds is the host's. Two bindings can differ between the
    // two: `janet/config-bits`, through the NaN-box pointer shift, and
    // `janet/api`, whose number is over layouts the target decides.
    // Each is rewritten with this compilation's own.
    overwriteBinding(env, "janet/config-bits", wrap.fromInteger(constants.JANET_CURRENT_CONFIG_BITS));
    overwriteBinding(env, "janet/api", value.fromBytes(&api_z, .string));

    // Invert the image dict here rather than in `boot.janet`, where it would
    // break deterministic builds.
    const lidv = registry.resolve(env, symbols.csymbol("load-image-dict")).value;
    const midv = registry.resolve(env, symbols.csymbol("make-image-dict")).value;

    // A smaller corelib may not have either, so check rather than assume.
    if (repr.checkType(lidv, repr.Tag.table) and repr.checkType(midv, repr.Tag.table)) {
        const lid = wrap.toTable(lidv);
        const mid = wrap.toTable(midv);
        for (0..lid.capacity) |i| {
            const kv = &lid.slots()[i];
            if (!repr.checkType(kv.key, repr.Tag.nil)) {
                tables.put(mid, kv.value, kv.key);
            }
        }
    }

    return env;
}

/// Whether `ch` separates path segments, which on Windows is either slash.
inline fn isPathSep(ch: u8) bool {
    if (windows and ch == '\\') return true;
    return ch == '/';
}

/// Registers every subsystem's `lib*` into `env`, skipping the ones this
/// build has no code for.
fn loadLibs(env: *tables.Table) raise.Error!void {
    const entries = comptime [_]corefn.Entry{
        corefn.reg("native", &cfunNative, @src(), "(native path &opt env)", "Load a native module from the given path. The path " ++
            "must be an absolute or relative path on the file system, and is " ++
            "usually a .so file on Unix systems, and a .dll file on Windows. " ++
            "Returns an environment table that contains functions and other values " ++
            "from the native module."),
        corefn.reg("describe", &cfunDescribe, @src(), "(describe x)", "Returns a string that is a human-readable description of `x`. " ++
            "For recursive data structures, the string returned contains a " ++
            "pointer value from which the identity of `x` " ++
            "can be determined."),
        corefn.reg("string", &Concat(finishString).cfun, @src(), "(string & xs)", "Creates a string by concatenating the elements of `xs` together. If an " ++
            "element is not a byte sequence, it is converted to bytes via `describe`. " ++
            "Returns the new string."),
        corefn.reg("symbol", &Concat(finishSymbol).cfun, @src(), "(symbol & xs)", "Creates a symbol by concatenating the elements of `xs` together. If an " ++
            "element is not a byte sequence, it is converted to bytes via `describe`. " ++
            "Returns the new symbol."),
        corefn.reg("keyword", &Concat(finishKeyword).cfun, @src(), "(keyword & xs)", "Creates a keyword by concatenating the elements of `xs` together. If an " ++
            "element is not a byte sequence, it is converted to bytes via `describe`. " ++
            "Returns the new keyword."),
        corefn.reg("buffer", &Concat(finishBuffer).cfun, @src(), "(buffer & xs)", "Creates a buffer by concatenating the elements of `xs` together. If an " ++
            "element is not a byte sequence, it is converted to bytes via `describe`. " ++
            "Returns the new buffer."),
        corefn.reg("abstract?", &cfunIsAbstract, @src(), "(abstract? x)", "Check if x is an abstract type."),
        corefn.reg("table", &cfunTable, @src(), "(table & kvs)", "Creates a new table from a variadic number of keys and values. " ++
            "kvs is a sequence k1, v1, k2, v2, k3, v3, ... If kvs has " ++
            "an odd number of elements, an error will be thrown. Returns the " ++
            "new table."),
        corefn.reg("array", &cfunArray, @src(), "(array & items)", "Create a new array that contains items. Returns the new array."),
        corefn.reg("scan-number", &cfunScanNumber, @src(), "(scan-number str &opt base)", "Parse a number from a byte sequence and return that number, either an integer " ++
            "or a real. The number " ++
            "must be in the same format as numbers in janet source code. Will return nil " ++
            "on an invalid number. Optionally provide a base - if a base is provided, no " ++
            "radix specifier is expected at the beginning of the number."),
        corefn.reg("tuple", &cfunTuple, @src(), "(tuple & items)", "Creates a new tuple that contains items. Returns the new tuple."),
        corefn.reg("struct", &cfunStruct, @src(), "(struct & kvs)", "Create a new struct from a sequence of key value pairs. " ++
            "kvs is a sequence k1, v1, k2, v2, k3, v3, ... If kvs has " ++
            "an odd number of elements, an error will be thrown. Returns the " ++
            "new struct."),
        corefn.reg("gensym", &cfunGensym, @src(), "(gensym)", "Returns a new symbol that is unique across the runtime. This means it " ++
            "will not collide with any already created symbols during compilation, so " ++
            "it can be used in macros to generate automatic bindings."),
        corefn.reg("gccollect", &cfunGccollect, @src(), "(gccollect)", "Run garbage collection. You should probably not call this manually."),
        corefn.reg("gcsetinterval", &cfunGcsetinterval, @src(), "(gcsetinterval interval)", "Set an integer number of bytes to allocate before running garbage collection. " ++
            "Low values for interval will be slower but use less memory. " ++
            "High values will be faster but use more memory."),
        corefn.reg("gcinterval", &cfunGcinterval, @src(), "(gcinterval)", "Returns the integer number of bytes to allocate before running an iteration " ++
            "of garbage collection."),
        corefn.reg("type", &cfunType, @src(), "(type x)", "Returns the type of `x` as a keyword. `x` is one of:\n\n" ++
            "* :number\n" ++
            "* :nil\n" ++
            "* :boolean\n" ++
            "* :fiber\n" ++
            "* :string\n" ++
            "* :symbol\n" ++
            "* :keyword\n" ++
            "* :array\n" ++
            "* :tuple\n" ++
            "* :table\n" ++
            "* :struct\n" ++
            "* :buffer\n" ++
            "* :function\n" ++
            "* :cfunction\n" ++
            "* :pointer\n\n" ++
            "or another keyword for an abstract type."),
        corefn.reg("hash", &cfunHash, @src(), "(hash value)", "Gets a hash for any value. The hash is an integer can be used " ++
            "as a cheap hash function for all values. If two values are strictly equal, " ++
            "then they will have the same hash value."),
        corefn.reg("getline", &cfunGetline, @src(), "(getline &opt prompt buf env)", "Reads a line of input into a buffer, including the newline character, using a prompt. " ++
            "An optional environment table can be provided for auto-complete. " ++
            "Returns the modified buffer. " ++
            "Use this function to implement a simple interface for a terminal program."),
        corefn.reg("dyn", &cfunDyn, @src(), "(dyn key &opt default)", "Get a dynamic binding. Returns the default value (or nil) if no binding found."),
        corefn.reg("setdyn", &cfunSetdyn, @src(), "(setdyn key value)", "Set a dynamic binding. Returns value."),
        corefn.reg("trace", &cfunTrace, @src(), "(trace func)", "Enable tracing on a function. Returns the function."),
        corefn.reg("untrace", &cfunUntrace, @src(), "(untrace func)", "Disables tracing on a function. Returns the function."),
        corefn.reg("module/expand-path", &cfunExpandPath, @src(), "(module/expand-path path template)", "Expands a path template as found in `module/paths` for `module/find`. " ++
            "This takes in a path (the argument to require) and a template string, " ++
            "to expand the path to a path that can be used for importing files. " ++
            "The replacements are as follows:\n\n" ++
            "* :all: -- the value of path verbatim.\n\n" ++
            "* :@all: -- Same as :all:, but if `path` starts with the @ character, " ++
            "the first path segment is replaced with a dynamic binding " ++
            "`(dyn <first path segment as keyword>)`.\n\n" ++
            "* :cur: -- the directory portion, if any, of (dyn :current-file)\n\n" ++
            "* :dir: -- the directory portion, if any, of the path argument\n\n" ++
            "* :name: -- the name component of path, with extension if given\n\n" ++
            "* :native: -- the extension used to load natives, .so or .dll\n\n" ++
            "* :sys: -- the system path, or (dyn :syspath)"),
        corefn.reg("int?", &cfunCheckInt, @src(), "(int? x)", "Check if x can be exactly represented as a 32 bit signed two's complement integer."),
        corefn.reg("nat?", &cfunCheckNat, @src(), "(nat? x)", "Check if x can be exactly represented as a non-negative 32 bit signed two's complement integer."),
        corefn.reg("bytes?", &TypeFlagPredicate(repr.TagSet.bytes).cfun, @src(), "(bytes? x)", "Check if x is a string, symbol, keyword, or buffer."),
        corefn.reg("indexed?", &cfunIsIndexed, @src(), "(indexed? x)", "Check if x is an array, a vector, a tuple, or an abstract type that implements the indexed protocol."),
        corefn.reg("dictionary?", &cfunIsDictionary, @src(), "(dictionary? x)", "Check if x is a table, a struct, or an abstract type that implements the dictionary protocol."),
        corefn.reg("lengthable?", &TypeFlagPredicate(repr.TagSet.lengthable).cfun, @src(), "(lengthable? x)", "Check if x is a bytes, indexed, or dictionary."),
        corefn.reg("slice", &cfunSlice, @src(), "(slice x &opt start end)", "Extract a sub-range of an indexed data structure or byte sequence."),
        corefn.reg("range", &cfunRange, @src(), "(range & args)", "Create an array of values [start, end) with a given step. " ++
            "With one argument, returns a range [0, end). With two arguments, returns " ++
            "a range [start, end). With three, returns a range with optional step size."),
        corefn.reg("signal", &cfunSignal, @src(), "(signal what x)", "Raise a signal with payload x. `what` can be an integer\n" ++
            "from 0 through 7 indicating user(0-7), or one of:\n\n" ++
            "* :ok\n" ++
            "* :error\n" ++
            "* :debug\n" ++
            "* :yield\n" ++
            "* :user(0-7)\n" ++
            "* :interrupt\n" ++
            "* :await"),
        corefn.reg("memcmp", &cfunMemcmp, @src(), "(memcmp a b &opt len offset-a offset-b)", "Compare memory. Takes two byte sequences `a` and `b`, and " ++
            "return 0 if they have identical contents, a negative integer if a is less than b, " ++
            "and a positive integer if a is greater than b. Optionally take a length and offsets " ++
            "to compare slices of the bytes sequences."),
        corefn.reg("getproto", &cfunGetproto, @src(), "(getproto x)", "Get the prototype of a table or struct. Will return nil if `x` has no prototype."),
        corefn.reg("sandbox", &cfunSandbox, @src(), "(sandbox & forbidden-capabilities)", "Disable feature sets to prevent the interpreter from using certain system resources. " ++
            "Once a feature is disabled, there is no way to re-enable it. Capabilities can be:\n\n" ++
            "* :all - disallow all (except IO to stdout, stderr, and stdin)\n" ++
            "* :asm - disallow calling `asm` and `disasm` functions.\n" ++
            "* :chroot - disallow calling `os/posix-chroot`\n" ++
            "* :compile - disallow calling `compile`. This will disable a lot of functionality, such as `eval`.\n" ++
            "* :env - disallow reading and write env variables\n" ++
            "* :exit - disallow calling `os/exit` or otherwise early exiting the process in trivial ways.\n" ++
            "* :ffi - disallow FFI (recommended if disabling anything else)\n" ++
            "* :ffi-define - disallow loading new FFI modules and binding new functions\n" ++
            "* :ffi-jit - disallow calling `ffi/jitfn`\n" ++
            "* :ffi-use - disallow using any previously bound FFI functions and memory-unsafe functions.\n" ++
            "* :fs - disallow access to the file system\n" ++
            "* :fs-read - disallow read access to the file system\n" ++
            "* :fs-temp - disallow creating temporary files\n" ++
            "* :fs-write - disallow write access to the file system\n" ++
            "* :hrtime - disallow high-resolution timers\n" ++
            "* :modules - disallow load dynamic modules (natives)\n" ++
            "* :net - disallow network access\n" ++
            "* :net-connect - disallow making outbound network connections\n" ++
            "* :net-listen - disallow accepting inbound network connections\n" ++
            "* :sandbox - disallow calling this function\n" ++
            "* :signal - disallow adding or removing signal handlers\n" ++
            "* :subprocess - disallow running subprocesses\n" ++
            "* :threads - disallow spawning threads with `ev/thread`. Certain helper threads may still be spawned.\n" ++
            "* :unmarshal - disallow calling the `unmarshal` function.\n"),
    };
    corefn.install(env, entries);
    try io_core.libIo(env);
    try math.libMath(env);
    arrays.lib(env);
    tuples.lib(env);
    vectors.lib(env);
    try maps.lib(env);
    try transients.lib(env);
    buffers.lib(env);
    tables.lib(env);
    structs.lib(env);
    try fibers.lib(env);
    try os_surface.libOs(env);
    parser_core.libParse(env);
    compiler_primitives.libCompile(env);
    trace_frames.libDebug(env);
    strings.lib(env);
    marsh.libMarsh(env);
    if (has_peg) try peg.libPeg(env);
    if (has_assembler) try asm_core.libAsm(env);
    if (has_int_types) try inttypes.libInttypes(env);
    if (has_ev) {
        try ev_loop.libEv(env);
        if (has_filewatch) filewatch.libFilewatch(env);
    }
    if (has_net) net.libNet(env);
    if (has_ffi) ffi.libFfi(env);
}

/// `apply`. Registers: 0 function, 1 args, 2 argn, 3 jump flag, 4 iterator,
/// 5 loop value.
fn makeApply(env: *tables.Table) void {
    const apply_asm = [_]u32{
        opSS(constants.Opcode.length, 2, 1),
        opSSS(constants.Opcode.equals_immediate, 3, 2, 0), // immediate tail call if no args
        opSI(constants.Opcode.jump_if, 3, 9),

        opSI(constants.Opcode.load_integer, 4, 0),

        opSSS(constants.Opcode.in, 5, 1, 4),
        opSSI(constants.Opcode.add_immediate, 4, 4, 1),
        opSSI(constants.Opcode.equals, 3, 4, 2),
        opSI(constants.Opcode.jump_if, 3, 3),
        opS(constants.Opcode.push, 5),
        opword(constants.Opcode.jump) | (@as(u32, @bitCast(@as(i32, -5))) << 8),

        opS(constants.Opcode.push_array, 5),

        opS(constants.Opcode.tailcall, 0),
    };
    quickAsmDef(
        env,
        .{ .tag = constants.JANET_FUN_APPLY, .vararg = true },
        "apply",
        1,
        1,
        std.math.maxInt(i32),
        6,
        &apply_asm,
        "(apply f & args)\n\n" ++
            "Applies a function f to a variable number of arguments. Each " ++
            "element in args is used as an argument to f, except the last " ++
            "element in args, which is expected to be an array or a tuple. " ++
            "Each element in this last argument is then also pushed as an " ++
            "argument to f.",
    );
}

/// `strncmp` against a literal. It reads through the template's NUL rather
/// than past it, so a template ending in a colon is compared safely and is no
/// match.
inline fn matches(p: [*]const u8, comptime literal: [:0]const u8) bool {
    return c.strncmp(p, literal.ptr, literal.len) == 0;
}

/// Loads a native module and returns its `_wattle_init`, or nothing with the
/// reason in `err`.
///
/// The module's `_wattle_mod_config` is compared with this build's
/// configuration bits, compiler version and interface fingerprint, in that
/// order, and the first difference is a refusal rather than a load. Janet's
/// own version is reported in a refusal and is not compared, so a module built
/// against one release loads into another whose interface is the same.
fn native(name: [*:0]const u8, err: *?strings.String) raise.Error!ModuleEntry {
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"dynamic_modules"}));
    const processed_name = utils.getProcessedName(name);
    const lib = clib.load(@ptrCast(processed_name));
    if (name != processed_name) utils.free(processed_name);
    if (clib.failed(lib)) {
        err.* = strings.cstring(clib.lastError());
        return null;
    }
    const init: ModuleEntry = @ptrCast(@alignCast(try clib.symbol(lib, "_wattle_init")));
    if (init == null) {
        err.* = strings.cstring("could not find the _wattle_init symbol");
        return null;
    }
    const getter: ModuleConfig = @ptrCast(@alignCast(try clib.symbol(lib, "_wattle_mod_config")));
    const mod_config = getter orelse {
        err.* = strings.cstring("could not find the _wattle_mod_config symbol");
        return null;
    };
    err.* = checkModuleConfig(mod_config);
    return if (err.* == null) init else null;
}

/// Collapses `.` and `..` segments in place, walking two indices rather than
/// two pointers, so nothing has to reason about what a zero-capacity buffer
/// left in `data`.
///
/// `dot_count` is three states rather than a count: non-negative is a run of
/// leading dots in the current segment, and -1 means the segment has a non-dot
/// character in it and the dots are no longer leading.
///
/// A dot run that ends the string is applied after the loop. A run only
/// reaches a branch when a separator ends it, so without the second block
/// below a trailing `.` or `..` is collected and dropped without ever being
/// applied, which would make `a/b/..` give back `a/b/` while `a/b/../` gives
/// back `a/`, the same path meaning two things depending on whether it ends in
/// a separator. The block is the separator branch's three dot cases and not
/// its fourth: a path that did not end in a separator does not gain one.
fn normalizePath(out: *buffers.Buffer) void {
    const data = out.data;
    const end: usize = @intCast(out.count);
    var print: usize = 0;
    var normal_section_count: i32 = 0;
    var dot_count: i32 = 0;
    for (0..end) |scan| {
        const ch = data.?[scan];
        if (ch == '.') {
            if (dot_count >= 0) {
                dot_count += 1;
            } else {
                data.?[print] = '.';
                print += 1;
            }
        } else if (isPathSep(ch)) {
            if (dot_count == 1) {
                // A bare "." segment: drop it and the separator with it.
            } else if (dot_count == 2) {
                if (normal_section_count > 0) {
                    print -= 1; // unprint the last separator
                    while (print > 0 and !isPathSep(data.?[print - 1])) print -= 1;
                    normal_section_count -= 1;
                } else {
                    data.?[print] = '.';
                    data.?[print + 1] = '.';
                    data.?[print + 2] = '/';
                    print += 3;
                }
            } else if (scan == 0 or dot_count != 0) {
                while (dot_count > 0) : (dot_count -= 1) {
                    data.?[print] = '.';
                    print += 1;
                }
                if (scan > 0) normal_section_count += 1;
                data.?[print] = '/';
                print += 1;
            }
            dot_count = 0;
        } else {
            while (dot_count > 0) : (dot_count -= 1) {
                data.?[print] = '.';
                print += 1;
            }
            dot_count = -1;
            data.?[print] = ch;
            print += 1;
        }
    }
    // The run that ended the string. Every write below replaces bytes the run
    // itself occupied, so `print` cannot pass `end`.
    if (dot_count == 1) {
        // A bare "." segment: dropped, and there is no separator to drop with
        // it.
    } else if (dot_count == 2) {
        if (normal_section_count > 0) {
            print -= 1; // unprint the last separator
            while (print > 0 and !isPathSep(data.?[print - 1])) print -= 1;
            normal_section_count -= 1;
        } else {
            data.?[print] = '.';
            data.?[print + 1] = '.';
            print += 2;
        }
    } else if (dot_count > 2) {
        while (dot_count > 0) : (dot_count -= 1) {
            data.?[print] = '.';
            print += 1;
        }
    }
    out.count = @intCast(print);
}

/// A one-word instruction, for an opcode with no operands.
fn opOnly(comptime op: anytype) [1]u32 {
    return .{opword(op)};
}

/// An instruction with one register operand.
inline fn opS(op: anytype, a: u32) u32 {
    return opword(op) | (a << 8);
}

/// An instruction with a register and a signed immediate.
inline fn opSI(op: anytype, a: u32, i: i32) u32 {
    return opword(op) | (a << 8) | (@as(u32, @bitCast(i)) << 16);
}

/// An instruction with two register operands.
inline fn opSS(op: anytype, a: u32, b: u32) u32 {
    return opword(op) | (a << 8) | (b << 16);
}

/// An instruction with two registers and a signed immediate.
inline fn opSSI(op: anytype, a: u32, b: u32, i: i32) u32 {
    return opword(op) | (a << 8) | (b << 16) | (@as(u32, @bitCast(i)) << 24);
}

/// An instruction with three register operands.
inline fn opSSS(op: anytype, a: u32, b: u32, d: u32) u32 {
    return opword(op) | (a << 8) | (b << 16) | (d << 24);
}

/// The opcode's own word, taking either an `Opcode` or a number already
/// combined with operand bits.
inline fn opword(op: anytype) u32 {
    return if (@TypeOf(op) == constants.Opcode) op.number() else @intCast(op);
}

/// Replaces the value of a binding the unmarshalled image already holds.
///
/// `name` is the binding's symbol and `v` is what its `:value` becomes.
/// Nothing is written where the image has no such binding, which is what a
/// build with a smaller core environment leaves behind.
fn overwriteBinding(env: *tables.Table, name: [*:0]const u8, v: repr.Value) void {
    const binding = tables.get(env, wrap.fromSymbol(symbols.csymbol(name)));
    if (!repr.checkType(binding, repr.Tag.table)) return;
    tables.put(wrap.toTable(binding), value.fromBytes("value", .keyword), v);
}

/// Assembles one function from a bytecode array, for the bootstrap.
fn quickAsm(
    flags: functions.FuncDefFlags,
    name: [*:0]const u8,
    arity: i32,
    min_arity: i32,
    max_arity: i32,
    slots: i32,
    bytecode: []const u32,
) *functions.FuncDef {
    const def = functions.defs.new();
    def.arity = arity;
    def.min_arity = min_arity;
    def.max_arity = max_arity;
    def.flags = flags;
    def.slotcount = slots;
    const size = bytecode.len * @sizeOf(u32);
    def.bytecode = @ptrCast(@alignCast(allocated(utils.malloc(size))));
    def.bytecode_length = @intCast(bytecode.len);
    def.name = strings.cstring(name);
    @memcpy(def.instructions()[0..bytecode.len], bytecode);
    compiler_primitives.defAddflags(def);
    return def;
}

/// The same, and defines it into the environment with its docstring.
fn quickAsmDef(
    env: *tables.Table,
    flags: functions.FuncDefFlags,
    name: [*:0]const u8,
    arity: i32,
    min_arity: i32,
    max_arity: i32,
    slots: i32,
    bytecode: []const u32,
    doc: [*:0]const u8,
) void {
    const def = quickAsm(flags, name, arity, min_arity, max_arity, slots, bytecode);
    registry.def(env, name, wrap.fromFunction(functions.thunk(def)), doc);
}

/// The variadic comparators. Registers: 0 args, 1 argn, 2 jump flag, 3 last
/// value, 4 next operand, 5 loop iterator.
fn templatizeComparator(
    env: *tables.Table,
    flags: functions.FuncDefFlags,
    name: [*:0]const u8,
    invert: bool,
    op: anytype,
    doc: [*:0]const u8,
) void {
    const comparator_asm = [_]u32{
        opSS(constants.Opcode.length, 1, 0),
        opSSS(constants.Opcode.less_than_immediate, 2, 1, 2),
        opSI(constants.Opcode.jump_if, 2, 10),

        // Prime the loop
        opSSI(constants.Opcode.get_index, 3, 0, 0),
        opSI(constants.Opcode.load_integer, 5, 1),

        // Main loop
        opSSS(constants.Opcode.in, 4, 0, 5),
        opSSS(op, 2, 3, 4),
        opSI(constants.Opcode.jump_if_not, 2, 7),
        opSSI(constants.Opcode.add_immediate, 5, 5, 1),
        opSS(constants.Opcode.move_near, 3, 4),
        opSSI(constants.Opcode.equals, 2, 5, 1),
        opSI(constants.Opcode.jump_if_not, 2, -6),

        // Done
        opS(if (invert) constants.Opcode.load_false else constants.Opcode.load_true, 3),
        opS(constants.Opcode.@"return", 3),

        // Failed
        opS(if (invert) constants.Opcode.load_true else constants.Opcode.load_false, 3),
        opS(constants.Opcode.@"return", 3),
    };
    quickAsmDef(
        env,
        varargOf(flags),
        name,
        0,
        0,
        std.math.maxInt(i32),
        6,
        &comparator_asm,
        doc,
    );
}

/// The variadic operators. Registers: 0 args, 1 argn, 2 jump flag,
/// 3 accumulator, 4 operand, 5 loop iterator.
fn templatizeVarop(
    env: *tables.Table,
    flags: functions.FuncDefFlags,
    name: [*:0]const u8,
    nullary: i32,
    unary: i32,
    op: anytype,
    doc: [*:0]const u8,
) void {
    const varop_asm = [_]u32{
        opSS(constants.Opcode.length, 1, 0), // argn = count(args)

        // Check nullary
        opSSS(constants.Opcode.equals_immediate, 2, 1, 0),
        opSI(constants.Opcode.jump_if_not, 2, 3),
        opSI(constants.Opcode.load_integer, 3, nullary),
        opS(constants.Opcode.@"return", 3),

        // Check unary
        opSSI(constants.Opcode.equals_immediate, 2, 1, 1),
        opSI(constants.Opcode.jump_if_not, 2, 5),
        opSI(constants.Opcode.load_integer, 3, unary),
        opSSI(constants.Opcode.get_index, 4, 0, 0),
        opSSS(op, 3, 3, 4),
        opS(constants.Opcode.@"return", 3),

        // Two or more arguments: prime the loop
        opSSI(constants.Opcode.get_index, 3, 0, 0),
        opSI(constants.Opcode.load_integer, 5, 1),
        // Main loop
        opSSS(constants.Opcode.in, 4, 0, 5),
        opSSS(op, 3, 3, 4),
        opSSI(constants.Opcode.add_immediate, 5, 5, 1),
        opSSI(constants.Opcode.equals, 2, 5, 1),
        opSI(constants.Opcode.jump_if_not, 2, -4),

        opS(constants.Opcode.@"return", 3),
    };
    quickAsmDef(
        env,
        varargOf(flags),
        name,
        0,
        0,
        std.math.maxInt(i32),
        6,
        &varop_asm,
        doc,
    );
}

/// The same flags with `vararg` set, which is the only bit the two templates
/// add to what their caller passed.
fn varargOf(flags: functions.FuncDefFlags) functions.FuncDefFlags {
    var out = flags;
    out.vararg = true;
    return out;
}

/// Spells a compiler version in `buf` and returns `buf` as a C string.
///
/// `raw` is the NUL-padded field of an `abi.BuildConfig`, which a module fills
/// in and so may hold anything. Copying stops at the first byte outside
/// printable ASCII, which is what the padding is, and a terminator is
/// appended. `buf` is written over and holds the result until its caller
/// returns.
fn zigText(buf: *[33]u8, raw: [32]u8) [*:0]const u8 {
    var len: usize = 0;
    while (len < raw.len and raw[len] >= ' ' and raw[len] < 0x7F) : (len += 1) buf[len] = raw[len];
    buf[len] = 0;
    return @ptrCast(buf);
}
