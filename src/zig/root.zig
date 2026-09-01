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
//! A module boundary was never a barrier: `raise.Error` is declared in the
//! `raise` module and a subsystem writes `raise.Error!repr.Value` across the
//! import. The compiler sees through a module the way it sees through a file.
//!
//! What it cannot see through is a *compilation* boundary. The only thing that
//! joins two separately compiled objects is a symbol in a symbol table --
//! which means a calling convention, which means C's, and Zig is explicit
//! about what that costs:
//!
//! ```text
//! error: return type 'error{X}!i32' not allowed in function with calling
//! convention 'aarch64_aapcs_darwin'
//! ```
//!
//! With every subsystem in one compilation a neighbour is reached by path, the
//! call is an ordinary Zig call, and `raise.Error` crosses it. That is what
//! makes the raise *checked*: a caller that forgets to `try` a raise-capable
//! callee is a compile error, where across the C ABI it was a silent jump.
//!
//! ## Nothing here decides anything
//!
//! The conditions are `build.zig`'s, passed in through `@import("options")`,
//! and `zigSelection` is the one place each is written. When there were two
//! readers of a selection -- an import here and a guard elsewhere -- a
//! subsystem could be compiled without being guarded off.
//!
//! ## Why the imports are discarded rather than bound
//!
//! A subsystem's contribution is its `export`s, and nothing here calls it.
//! `_ = @import(...)` in a `comptime` block is what makes Zig analyse the file
//! and emit them; binding each to a `const` would suggest a namespace someone
//! reads, and no one does. The imports that *are* bound are inside the
//! subsystems, where one reaches another.
//!
//! ## Some files are not named here
//!
//! `vm.zig`'s call protocol and `value/helpers/wrap.zig` are imported by the
//! interpreter as well as by this file, because the loop inlines them --
//! 2.4-3.4% on method dispatch and 89% on arithmetic for reaching them out of
//! line, measured. One module means one instance either way, so two importers
//! are not two copies.
//!
//! The other absences are subsystems reached through the file that registers
//! them: `os/date.zig`, `os/fs.zig` and `os/process.zig` through `os.zig`,
//! `ev/stream.zig`, `ev/channel.zig` and `ev/backend.zig` through `ev.zig`,
//! `ffi/types.zig`, `ffi/marshal.zig` and `ffi/call.zig` through `ffi.zig`,
//! and `pp/pretty.zig` through `pp.zig`.

const options = @import("options");

comptime {
    // The compiler front end.
    if (options.scratch_vector) _ = @import("scratch_vector.zig");
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
    // Named here although `os/fs.zig` already reaches it, because a name in
    // this block is what puts a file's `test` blocks in `janet-runtime-test`.
    // A file reached only through a lazy container-level `const` is analysed
    // when something calls into it and its tests are not collected; `stat.zig`
    // had three that ran nowhere until it was listed.
    if (options.os_fs) _ = @import("os/fs/stat.zig");
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

// The block above is what makes a subsystem's `export`s exist; this one is
// what lets something *call* a subsystem without going through one.
//
// The caller is `test/contracts.zig`, which `build.zig` gives this file as an
// imported module. A contract that reaches its subject here is inside the
// compilation, so `raise.Error` crosses to it exactly as it crosses between
// two subsystems -- which is the whole reason the contracts are built this way
// rather than linked against `libjanet.a`. `makeRuntimeGraph` has the
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

pub const scratch_vector = @import("scratch_vector.zig");
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
/// The value layer's namespace. `test/` reaches a leaf through it --
/// `@import("subsystems").value.tables` -- exactly as it reaches every other
/// subsystem through the flat declarations above. The leaf, not the group, is
/// the import unit.
pub const value = @import("value.zig");
pub const abstract_type = @import("abstract_type.zig");
pub const method_type = @import("method_type.zig");
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
pub const vm_state = @import("vm/state.zig");
pub const dynlib = @import("dynlib.zig");
pub const stdio = @import("stdio.zig");
pub const fatal = @import("fatal.zig");

/// The raise vocabulary and the core-cfunction registration layer, named here
/// so that a caller outside this compilation -- a contract, the client, the
/// image generator -- reaches them the way a subsystem does.
pub const raise = @import("raise.zig");
pub const corefn = @import("corefn.zig");

/// The published entry points, reachable by import rather than by symbol.
///
/// A contract that is about what a native module sees -- the registration
/// surface, the arity checks, the wrappers `module.zig` declares -- names the
/// entry point here. Everything else a contract needs is the subsystem above.
pub const capi = @import("capi.zig");

// `cabi_check.zig`: `cabi.zig`'s declarations against the definitions they
// name. An `extern fn` is a promise the compiler believes, and this is what
// stops it being taken on trust.
comptime {
    @import("cabi_check.zig").verify();
}

// `capi.zig` is the C ABI, and the only file under `src/zig` that exports.
// Referencing it here is what makes its `comptime` blocks run -- and those
// blocks, rather than the list above, are what decides which subsystems a
// configuration compiles.
comptime {
    _ = @import("capi.zig");
}
