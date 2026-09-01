//! The Zig contract driver: one executable over every contract that lives
//! inside the runtime's own compilation.
//!
//! ## Why it has this shape
//!
//! A contract that linked `libjanet.a` would have every call resolved by the
//! linker, which is to say across the C ABI, and Zig will not put an error
//! union on a C-ABI function. A raise could not reach it as a value at all: it
//! would arrive as an out-of-band report.
//!
//! A contract in *this* binary is on the near side. `build.zig` builds the
//! runtime's module graph a second time with this file as its root, so a
//! contract reaches its subject through `@import("subsystems")` and a raise
//! crosses as `error.JanetSignal` — the same way it crosses between two
//! subsystems, and checked by the compiler in the same way. Nothing is
//! reported, nothing is adapted, and a contract that forgets to handle a raise
//! does not compile.
//!
//! The cost is one more compilation of the runtime. The alternative — a
//! contract module compiled beside `libjanet.a` — gives a *local copy* of the
//! subject rather than the one the rest of the binary runs, which a
//! `comptime`-generic subject can take and a collector or an interpreter
//! cannot.
//!
//! ## The shape
//!
//! One file per subject, each with its own `janet_init`/`janet_deinit` pair so
//! that none inherits another's heap; they run in the order this file
//! declares them; with no argument every compiled-in contract runs, and with
//! one argument only the contract named runs, which is what `tools/testing/contract.sh`
//! drives.
//!
//! ## Adding one
//!
//! A contract is `test/<name>.zig` exposing `pub fn run() void`, added to the
//! list below under the same condition `build.zig` applies to its subsystem.
//! Those conditions are read from `options`, which is the build's own
//! `Selection` — so a contract exists exactly when its subject does, and the
//! two cannot drift. A driver on the far side of a symbol table needs that
//! condition written twice, once in the build and once in its own list.
//!
//! Not every `test/*.zig` belongs here. `harness.zig` is the shared vocabulary,
//! `expect.zig` is the assertion every contract uses, and `fuzz.zig` is the
//! four fuzz targets, which cannot be contracts because `std.testing.fuzz`
//! resolves through `@import("root").fuzz` and so needs a test root of its own.
//! All three are named in `checkContractsListed`'s `exempt`, which is the list
//! that keeps "not a contract" from meaning "forgotten".

const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");

// The runtime, pulled in for its `export`s rather than for its namespace.
//
// This line is what makes the binary a Janet. `src/zig/root.zig`
// emits every subsystem's `export`s from a container-level `comptime` block,
// and a module nothing references is never analysed -- so without this,
// `build.zig` hands the compilation a whole runtime and the link fails on
// `janet_init`.
//
// The `pub const` namespace beside that block stays lazy, which is the
// property `-Dpeg=false` and `-Dffi=false` rest on: naming a subsystem here
// forces the exports, and only a contract that actually spells
// `subsystems.peg` forces `peg.zig`.
comptime {
    _ = @import("subsystems");
}

const Contract = struct {
    name: []const u8,
    run: *const fn () void,
};

/// One entry, resolved at comptime.
///
/// The file is passed as a type rather than derived from the name, because
/// `@import`'s operand must be a literal and `name ++ ".zig"` is not one. So
/// the name appears twice on each line; it is the string `tools/testing/contract.sh`
/// passes on the command line, and the only thing that checks it against the
/// file is that both are on the same line.
fn with(
    comptime list: []const Contract,
    comptime name: []const u8,
    comptime file: type,
) []const Contract {
    return list ++ [_]Contract{.{ .name = name, .run = &file.run }};
}

const contracts: []const Contract = blk: {
    var list: []const Contract = &.{};
    list = with(list, "vector", @import("vector.zig"));
    if (options.os_environ) list = with(list, "os_environ", @import("os_environ.zig"));
    if (options.pp) list = with(list, "pp_format", @import("pp_format.zig"));
    // `-Dint-types=false` compiles neither the subsystem nor its contract.
    if (options.scan) list = with(list, "intscan", @import("intscan.zig"));
    list = with(list, "textscan", @import("textscan.zig"));
    list = with(list, "regalloc", @import("regalloc.zig"));
    list = with(list, "movopt", @import("movopt.zig"));
    list = with(list, "remove_noops", @import("remove_noops.zig"));
    // `-Dreduced-os=true` compiles neither the subsystem nor its contract.
    if (options.os_fs) list = with(list, "os_permissions", @import("os_permissions.zig"));
    list = with(list, "verify", @import("verify.zig"));
    // `-Dassembler=false` compiles none of the three subsystems these test.
    if (options.bytecode) list = with(list, "asm_encode", @import("asm_encode.zig"));
    if (options.disasm) list = with(list, "asm_decode", @import("asm_decode.zig"));
    if (options.disasm) list = with(list, "disasm", @import("disasm.zig"));
    list = with(list, "os_platform", @import("os_platform.zig"));
    if (options.os_time) list = with(list, "os_time", @import("os_time.zig"));
    if (options.os_fs) list = with(list, "os_fs", @import("os_fs.zig"));
    if (options.os_fs) list = with(list, "os_stat", @import("os_stat.zig"));
    if (options.os_fs) list = with(list, "os_fs_paths", @import("os_fs_paths.zig"));
    if (options.pp) list = with(list, "pp_describe", @import("pp_describe.zig"));
    if (options.pp) list = with(list, "pp_pretty", @import("pp_pretty.zig"));
    list = with(list, "emit_core", @import("emit_core.zig"));
    list = with(list, "compiler_primitives", @import("compiler_primitives.zig"));
    list = with(list, "specials_core", @import("specials_core.zig"));
    list = with(list, "parser_core", @import("parser_core.zig"));
    list = with(list, "gc_alloc", @import("gc_alloc.zig"));
    list = with(list, "gc_mark", @import("gc_mark.zig"));
    list = with(list, "gc_sweep", @import("gc_sweep.zig"));
    list = with(list, "gc_stress", @import("gc_stress.zig"));
    list = with(list, "gc_pcall", @import("gc_pcall.zig"));
    list = with(list, "numscan", @import("numscan.zig"));
    list = with(list, "math", @import("math.zig"));
    if (options.int_types_core) list = with(list, "inttypes", @import("inttypes.zig"));
    list = with(list, "buffer_array", @import("buffer_array.zig"));
    list = with(list, "abstract_core", @import("abstract_core.zig"));
    list = with(list, "string_symbol", @import("string_symbol.zig"));
    list = with(list, "struct_table", @import("struct_table.zig"));
    list = with(list, "value_wrap", @import("value_wrap.zig"));
    list = with(list, "value_alloc", @import("value_alloc.zig"));
    list = with(list, "value_order", @import("value_order.zig"));
    list = with(list, "value_access", @import("value_access.zig"));
    list = with(list, "trace_frames", @import("trace_frames.zig"));
    list = with(list, "signal_core", @import("signal_core.zig"));
    list = with(list, "fiber_core", @import("fiber_core.zig"));
    list = with(list, "vm_state", @import("vm_state.zig"));
    list = with(list, "vm_lifecycle", @import("vm_lifecycle.zig"));
    list = with(list, "vm_entry", @import("vm_entry.zig"));
    list = with(list, "vm_calls", @import("vm_calls.zig"));
    list = with(list, "vm_run", @import("vm_run.zig"));
    if (options.utilities) list = with(list, "utils", @import("utils.zig"));
    if (options.registry) list = with(list, "registry", @import("registry.zig"));
    if (options.env) list = with(list, "core_env", @import("core_env.zig"));
    if (options.args) list = with(list, "args_core", @import("args_core.zig"));
    if (options.marsh) list = with(list, "marsh", @import("marsh.zig"));
    // `-Dpeg=false` compiles neither the subject nor its contract.
    if (options.peg_engine) list = with(list, "peg", @import("peg.zig"));
    // `-Dffi=false` compiles neither the subsystems nor their contracts.
    if (options.ffi_zig) list = with(list, "ffi_layout", @import("ffi_layout.zig"));
    if (options.ffi_zig) list = with(list, "ffi_classify", @import("ffi_classify.zig"));
    if (options.ffi_zig) list = with(list, "ffi_core", @import("ffi_core.zig"));
    // `-Dprocesses=false` and `-Dreduced-os=true` each compile neither the
    // subsystem nor its contract.
    if (options.os_process) list = with(list, "os_process", @import("os_process.zig"));
    list = with(list, "io_core", @import("io_core.zig"));
    list = with(list, "os_surface", @import("os_surface.zig"));
    // The event loop's kernels and the file watcher's vocabularies: both are
    // `hasEv`-conditioned in `build.zig`, and `filewatch_flags` needs the file
    // watcher as well.
    if (options.ev) list = with(list, "ev_core", @import("ev_core.zig"));
    if (options.filewatch) list = with(list, "filewatch_flags", @import("filewatch_flags.zig"));
    if (options.filewatch) list = with(list, "filewatch_core", @import("filewatch_core.zig"));
    if (options.net) list = with(list, "net_sockets", @import("net_sockets.zig"));
    if (options.ev) list = with(list, "ev_loop", @import("ev_loop.zig"));
    break :blk list;
};

/// Stop this process at the end of `main` when `JANET_CONTRACT_PAUSE` is set,
/// so that `leaks <pid>` can scan a heap that is finished with.
///
/// **This exists because `leaks --atExit` cannot measure a contract that
/// forks**, and three of the sixty-five do. That mode inserts
/// `libLeaksAtExit.dylib`, which interposes `_exit` and `abort` with
/// `kill(getpid(), SIGSTOP)` followed by the real one -- the stop is how the
/// `leaks` process is told there is a heap to scan. A `fork()`ed child carries
/// the dylib in its inherited image, stops itself the same way, and nothing
/// ever resumes it: `leaks` is watching the parent. The parent's `waitpid`
/// then never returns, which is the hang the leak check's own header records
/// as "never returns under it" and read as *not* a fork.
///
/// An `exec`ed child is safe -- the dylib's initializer strips itself from
/// `DYLD_INSERT_LIBRARIES`, so `os/spawn` is not the hazard and a raw
/// `fork` is: `os_process` has seven, `value_alloc` one, and `os_surface`
/// reaches one through `os/posix-fork`.
///
/// Stopping here instead reaches the same heap by a route with no interposer
/// in it, so a child exits normally and the leak check covers all three.
/// `tools/testing/leaks.sh` drives it.
fn pauseForLeakCheck() void {
    if (builtin.os.tag == .windows) return;
    if (std.c.getenv("JANET_CONTRACT_PAUSE") == null) return;
    _ = std.c.kill(std.c.getpid(), std.c.SIG.STOP);
}

/// No argument runs every contract in list order; one or more names run those,
/// in the order given, **in one process**.
///
/// **The no-argument form is the interesting one.** Every contract opens with
/// an init and closes with a deinit, so it is sixty-five teardowns
/// and re-initialisations of the whole runtime — and `FOUND.md` records that
/// this binary aborts in glibc's `malloc_consolidate` with no argument while
/// **every contract passes when run by name**. A defect that needs the sequence
/// cannot be bisected one name at a time, and a name may be repeated, which is
/// what asks whether the sequence matters at all or only the count.
pub fn main(init: std.process.Init) !u8 {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());

    if (arguments.len > 1) {
        // Resolve every name before running any, so an unknown one is a
        // usage error rather than a partial run: the contracts mutate global
        // runtime state, and half a sequence is not a result.
        var chosen: [64]*const fn () void = undefined;
        var count: usize = 0;
        for (arguments[1..]) |name| {
            if (count == chosen.len) {
                std.debug.print("contracts: at most {d} names\n", .{chosen.len});
                return 2;
            }
            for (contracts) |contract| {
                if (std.mem.eql(u8, contract.name, name)) {
                    chosen[count] = contract.run;
                    count += 1;
                    break;
                }
            } else {
                std.debug.print(
                    "contracts: {s} was not compiled into this binary\n",
                    .{name},
                );
                return 2;
            }
        }
        for (chosen[0..count]) |run| run();
        pauseForLeakCheck();
        return 0;
    }

    for (contracts) |contract| contract.run();
    pauseForLeakCheck();
    return 0;
}
