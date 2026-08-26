//! The runtime's Zig root: every subsystem this configuration answers in Zig,
//! gathered into one module and one compilation.
//!
//! ## Module, compilation, object — three things C spells one way
//!
//! "Translation unit" is C's word and does not fit, so it is worth being exact
//! about what changed. A Zig **module** is a root file plus everything it
//! reaches by relative `@import("foo.zig")`; it is a namespace and a settings
//! scope, not a compile barrier. A **compilation** is one `zig build-obj` run,
//! and it can hold several modules — this one holds eight, with `abi`,
//! `raise`, `corefn` and the three host-header translations beside the root.
//!
//! A module boundary was never the problem, and the tree proved it before this
//! part existed: `raise.Error` is declared in the `raise` module and
//! `vm_calls.zig` has always written `raise.Error!c.Janet` across the import.
//! The compiler sees through a module the way it sees through a file.
//!
//! What it cannot see through is a *compilation* boundary. Until Part 17a each
//! selector was its own `b.addObject`, so there were sixty-three compilations,
//! and the only thing that joins two separately compiled objects is a symbol
//! in a symbol table — which means a calling convention, which means C's.
//!
//! Zig is explicit about what that costs:
//!
//! ```text
//! error: return type 'error{X}!i32' not allowed in function with calling
//! convention 'aarch64_aapcs_darwin'
//! ```
//!
//! Part 4's rule followed from it — **an error union cannot cross a subsystem
//! seam** — and it was read for thirteen increments as a fact about porting
//! rather than about the build. So `os_surface.zig` calling `janet_getcstring`
//! raised by `longjmp` even though both sides were Zig, and 729 calls in the
//! argument layer alone were still jumping when this file was written.
//!
//! ## What one compilation buys
//!
//! A subsystem imports its neighbour by path, the call is an ordinary Zig
//! call, and `raise.Error` crosses it. That is what lets Part 17 delete the
//! third `setjmp` — and, more to the point, it is what makes the conversion
//! *checked*: a caller that forgets to `try` a raise-capable callee is a
//! compile error, where under the C ABI it was a silent jump.
//!
//! ## Nothing here decides anything
//!
//! The conditions are `build.zig`'s, passed in through `@import("options")`,
//! and they are the same expressions that decide the `JANET_ZIG_*` macro for
//! the C side. `zigSelection` computes both, so a subsystem cannot be imported
//! here and left unguarded there, which was the failure mode when the two were
//! separate lists.
//!
//! ## Why the imports are discarded rather than bound
//!
//! A subsystem's contribution is its `export`s, and nothing here calls it.
//! `_ = @import(...)` in a `comptime` block is what makes Zig analyse the file
//! and emit them; binding each to a `const` would suggest a namespace someone
//! reads, and no one does. The imports that *are* bound are inside the
//! subsystems, where one reaches another.
//!
//! ## Four files are not named here
//!
//! `vm_calls.zig` and `value_wrap.zig` are imported by `vm_run.zig` as well as
//! by this file, because the loop inlines them — Part 2 measured 2.4-3.4% on
//! method dispatch and 89% on arithmetic for reaching them out of line. One
//! module means one instance either way, so the two importers are not two
//! copies. Their `_extern.zig` shims were named by `vm_run.zig` alone and only
//! when the selector said C, which is why Phase 11 Part 26 could delete all
//! eleven of them without anything here changing: a comptime-`false` branch is
//! not analysed, so nothing in one was ever diagnosed.
//!
//! The other absences are subsystems reached through the file that registers
//! them: `os_calendar`, `os_files` and `os_procs` through `os_surface.zig`,
//! `ev_stream`, `ev_channel` and `ev_backend` through `ev_loop.zig`,
//! `net_addr` through `net_sockets.zig`, `ffi_types`, `ffi_marshal` and
//! `ffi_call` through `ffi_core.zig`, and `pp_pretty` and `pp_describe`
//! through `pp_format.zig`. Each of those was already one object with one
//! selector, and folding the tree did not change what belongs to what.

const options = @import("options");

comptime {
    // The compiler front end.
    if (options.stretchy) _ = @import("stretchy.zig");
    if (options.utilities) _ = @import("utils.zig");
    if (options.registry) _ = @import("registry.zig");
    if (options.regalloc) _ = @import("compiler/regalloc.zig");
    if (options.verify) _ = @import("bytecode/verify.zig");
    if (options.emit_core) _ = @import("compiler/emit.zig");
    if (options.disasm) _ = @import("bytecode/disasm.zig");
    if (options.bytecode) _ = @import("bytecode.zig");
    if (options.compiler_primitives) _ = @import("compiler.zig");
    if (options.parser) _ = @import("parser.zig");
    if (options.specials_core) _ = @import("compiler/specials.zig");
    if (options.optimize) _ = @import("compiler/optimize.zig");

    // Numbers.
    if (options.scan) _ = @import("scan.zig");
    if (options.math_core) _ = @import("math.zig");
    if (options.int_types_core) _ = @import("value/ints.zig");

    // Platform and standard-library services.
    if (options.os_fs) _ = @import("os/fs.zig");
    if (options.io) _ = @import("io.zig");
    if (options.os_process) _ = @import("os/process.zig");
    if (options.os) _ = @import("os.zig");
    if (options.net) _ = @import("net.zig");
    if (options.ffi_zig) {
        _ = @import("ffi.zig");
        _ = @import("ffi/types.zig");
        _ = @import("ffi/classify.zig");
    }
    if (options.filewatch) _ = @import("filewatch.zig");

    // The value layer and the collector.
    if (options.args) _ = @import("args.zig");
    if (options.gc_alloc) _ = @import("gc.zig");
    if (options.gc_mark) _ = @import("gc/mark.zig");
    if (options.gc_sweep) _ = @import("gc/sweep.zig");
    if (options.arrays) _ = @import("value/arrays.zig");
    if (options.buffers) _ = @import("value/buffers.zig");
    if (options.strings) _ = @import("value/strings.zig");
    if (options.symbols) _ = @import("value/symbols.zig");
    if (options.tuples) _ = @import("value/tuples.zig");
    if (options.tables) _ = @import("value/tables.zig");
    if (options.structs) _ = @import("value/structs.zig");
    if (options.order) _ = @import("value/helpers/order.zig");
    if (options.access) _ = @import("value/helpers/access.zig");
    if (options.abstracts) _ = @import("value/abstracts.zig");
    if (options.functions) _ = @import("value/functions.zig");
    if (options.wrap) _ = @import("value/helpers/wrap.zig");
    if (options.kind) _ = @import("value/helpers/kind.zig");
    _ = @import("ev/locks.zig");
    _ = @import("os/fs/host_stat.zig");
    _ = @import("fatal.zig");
    if (options.pp) _ = @import("pp/format.zig");
    if (options.marsh) _ = @import("marsh.zig");
    if (options.peg_engine) _ = @import("peg.zig");
    if (options.env) _ = @import("env.zig");

    // The interpreter.
    if (options.fibers) _ = @import("value/fibers.zig");
    if (options.signal) _ = @import("signal.zig");
    if (options.debug) _ = @import("debug.zig");
    if (options.vm) _ = @import("vm.zig");
    if (options.vm_entry) _ = @import("vm/entry.zig");
    if (options.lifecycle) _ = @import("vm/lifecycle.zig");
}

// ------------------------------------------------------- the same, by name

// Phase 11 Part 1. The block above is what makes a subsystem's `export`s
// exist; this one is what lets something *call* a subsystem without going
// through one.
//
// The caller is `test/contracts.zig`, which `build.zig` gives this file as an
// imported module. A contract that reaches its subject here is inside the
// compilation, so `raise.Error` crosses to it exactly as it crosses between
// two subsystems -- which is the whole reason the Zig contracts are built this
// way rather than linked against `libjanet.a`. `makeRuntimeGraph` has the
// argument.
//
// **These are lazy and must stay lazy.** A `pub const` at container scope is
// analysed when something references it, and nothing in the runtime
// references any of these -- so a configuration that cannot compile a
// subsystem is unharmed as long as no contract names it either. That is the
// same condition `build.zig` already applies to the contract *list*
// (`-Dpeg=false` compiles neither `peg.zig` nor the peg contract), so the two
// cannot drift apart without the build saying so. Do not add a
// `comptime { _ = ... }` over this block: it would make every name eager and
// break `-Dpeg=false`, `-Dffi=false` and `-Dev=false` at once.
//
// The list is deliberately flat rather than grouped the way the block above
// is. A contract spells one name and does not care which layer it came from.

pub const stretchy = @import("stretchy.zig");
pub const utils = @import("utils.zig");
pub const registry = @import("registry.zig");
pub const regalloc = @import("compiler/regalloc.zig");
pub const verify = @import("bytecode/verify.zig");
pub const emit_core = @import("compiler/emit.zig");
pub const disasm = @import("bytecode/disasm.zig");
pub const bytecode = @import("bytecode.zig");
pub const compiler_primitives = @import("compiler.zig");
pub const parser = @import("parser.zig");
pub const specials_core = @import("compiler/specials.zig");
pub const special = @import("special_type.zig");
pub const optimize = @import("compiler/optimize.zig");

pub const scan = @import("scan.zig");
pub const math = @import("math.zig");
pub const inttypes = @import("value/ints.zig");

pub const fs = @import("os/fs.zig");
pub const stat = @import("os/fs/stat.zig");
pub const open = @import("os/fs/open.zig");
pub const io = @import("io.zig");
pub const os = @import("os.zig");
pub const date = @import("os/date.zig");
pub const os_files = @import("os/fs.zig");
pub const process = @import("os/process.zig");
pub const os_locks = @import("ev/locks.zig");
pub const host_stat = @import("os/fs/host_stat.zig");
pub const ev = @import("ev.zig");
pub const ev_channel = @import("ev/channel.zig");
pub const ev_stream = @import("ev/stream.zig");
pub const ev_backend = @import("ev/backend.zig");
pub const net = @import("net.zig");
pub const ffi_classify = @import("ffi/classify.zig");
pub const ffi = @import("ffi.zig");
pub const ffi_types = @import("ffi/types.zig");
pub const ffi_marshal = @import("ffi/marshal.zig");
pub const ffi_call = @import("ffi/call.zig");
pub const filewatch = @import("filewatch.zig");

pub const args = @import("args.zig");
pub const gc_alloc = @import("gc.zig");
pub const gc_mark = @import("gc/mark.zig");
pub const gc_sweep = @import("gc/sweep.zig");
/// The value layer's namespace, and the one level `root.zig` gains from the
/// batch that moved these files into `value/`. `test/` reaches a leaf through
/// it -- `@import("subsystems").value.tables` -- exactly as it reaches every
/// other subsystem through the flat declarations above. `port/NAMESPACES.md`
/// has the taxonomy and why the leaf, not the group, is the import unit.
pub const value = @import("value.zig");
pub const abstract_type = @import("abstract_type.zig");
pub const pp_format = @import("pp/format.zig");
pub const pp_pretty = @import("pp/pretty.zig");
pub const pp_describe = @import("pp.zig");
pub const marsh = @import("marsh.zig");
pub const peg = @import("peg.zig");
pub const env = @import("env.zig");

pub const signal = @import("signal.zig");
pub const debug = @import("debug.zig");
pub const vm = @import("vm.zig");
pub const vm_entry = @import("vm/entry.zig");
pub const lifecycle = @import("vm/lifecycle.zig");
pub const dynlib = @import("dynlib.zig");
pub const stdio = @import("stdio.zig");
pub const fatal = @import("fatal.zig");

// `types_check` and `constants_check` stood here, holding `types.zig` and
// `constants.zig` against the `@cImport` they replaced. Both were oracles with
// a fixed lifetime -- they compared Zig against a translation of `janet.h` --
// and Phase 12 increment 5f spent them with their subject.
//
// Phase 12 increment 5c: `cabi.zig`'s declarations against the definitions they
// name. 5b moved the declarations into Zig but not the checking -- an
// `extern fn` is a promise the compiler believes -- and this is what closes it.
// Unlike the other two oracles it does not die with the header: a name leaves
// when 5d converts its call sites to a direct call.
comptime {
    @import("cabi_check.zig").verify();
}

// Phase 12 increment 5h, decision 5: `capi.zig` is the C ABI, and the
// only file under `src/zig` that exports. Referencing it here is what
// makes its `comptime` blocks run -- and those blocks, rather than the
// list above, are what decides which subsystems a configuration
// compiles.
comptime {
    _ = @import("capi.zig");
}
