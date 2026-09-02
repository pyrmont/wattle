//! The runtime's Zig root: every subsystem this configuration answers in Zig,
//! gathered into one module and one compilation.
//!
//! ## One compilation is what makes the raise checked
//!
//! A Zig **module** is a root file plus everything it reaches by relative
//! `@import`; it is a namespace and a settings scope, not a compile barrier,
//! and a raise crosses one -- `raise.Error` is declared in the `raise` module
//! and a subsystem writes `raise.Error!repr.Value` across the import. A
//! **compilation** is one `zig build-obj` run and can hold several modules;
//! this one holds eight, with `abi`, `raise`, `corefn` and the three host
//! header translations beside the root.
//!
//! What nothing sees through is a *compilation* boundary: the only thing that
//! joins two separately compiled objects is a symbol, which means a C calling
//! convention, and Zig refuses an error union in one --
//!
//! ```text
//! error: return type 'error{X}!i32' not allowed in function with calling
//! convention 'aarch64_aapcs_darwin'
//! ```
//!
//! -- so with every subsystem in one compilation a neighbour is reached by
//! path, the call is an ordinary Zig call, and a caller that forgets to `try`
//! a raise-capable callee is a compile error.
//!
//! **Nothing here decides anything.** The conditions are `build.zig`'s, passed
//! in through `@import("options")`, and `zigSelection` is the one place each
//! is written, so a subsystem cannot be compiled without being guarded off.

const options = @import("options");

comptime {
    // The compiler front end.
    if (options.scratch_vector) _ = @import("runtime/scratch_vector.zig");
    if (options.utilities) _ = @import("runtime/utils.zig");
    if (options.registry) _ = @import("runtime/registry.zig");
    if (options.regalloc) _ = @import("runtime/compiler/regalloc.zig");
    if (options.verify) _ = @import("runtime/bytecode/verify.zig");
    if (options.emit_core) _ = @import("runtime/compiler/emit.zig");
    if (options.disasm) _ = @import("runtime/bytecode/disasm.zig");
    if (options.bytecode) _ = @import("runtime/bytecode.zig");
    if (options.compiler_primitives) _ = @import("runtime/compiler.zig");
    if (options.parser) _ = @import("runtime/parser.zig");
    if (options.specials_core) _ = @import("runtime/compiler/specials.zig");
    if (options.optimize) _ = @import("runtime/compiler/optimize.zig");

    // Numbers.
    if (options.scan) _ = @import("runtime/scan.zig");
    if (options.math_core) _ = @import("runtime/math.zig");
    if (options.int_types_core) _ = @import("runtime/value/ints.zig");

    // Platform and standard-library services.
    if (options.os_fs) _ = @import("runtime/os/fs.zig");
    // Named here although `os/fs.zig` already reaches it, because a name in
    // this block is what puts a file's `test` blocks in `janet-runtime-test`.
    // A file reached only through a lazy container-level `const` is analysed
    // when something calls into it, and its tests are not collected at all.
    if (options.os_fs) _ = @import("runtime/os/fs/stat.zig");
    if (options.io) _ = @import("runtime/io.zig");
    if (options.os_process) _ = @import("runtime/os/process.zig");
    if (options.os) _ = @import("runtime/os.zig");
    if (options.net) _ = @import("runtime/net.zig");
    if (options.ffi_zig) {
        _ = @import("runtime/ffi.zig");
        _ = @import("runtime/ffi/types.zig");
        _ = @import("runtime/ffi/classify.zig");
    }
    if (options.filewatch) _ = @import("runtime/filewatch.zig");

    // The value layer and the collector.
    if (options.args) _ = @import("runtime/args.zig");
    if (options.gc_alloc) _ = @import("runtime/gc.zig");
    if (options.gc_mark) _ = @import("runtime/gc/mark.zig");
    if (options.gc_sweep) _ = @import("runtime/gc/sweep.zig");
    if (options.arrays) _ = @import("runtime/value/arrays.zig");
    if (options.buffers) _ = @import("runtime/value/buffers.zig");
    if (options.strings) _ = @import("runtime/value/strings.zig");
    if (options.symbols) _ = @import("runtime/value/symbols.zig");
    if (options.tuples) _ = @import("runtime/value/tuples.zig");
    if (options.tables) _ = @import("runtime/value/tables.zig");
    if (options.structs) _ = @import("runtime/value/structs.zig");
    if (options.order) _ = @import("runtime/value/helpers/order.zig");
    if (options.access) _ = @import("runtime/value/helpers/access.zig");
    if (options.abstracts) _ = @import("runtime/value/abstracts.zig");
    if (options.functions) _ = @import("runtime/value/functions.zig");
    if (options.wrap) _ = @import("runtime/value/helpers/wrap.zig");
    _ = @import("runtime/ev/locks.zig");
    _ = @import("runtime/os/fs/host_stat.zig");
    _ = @import("runtime/fatal.zig");
    if (options.pp) _ = @import("runtime/pp/format.zig");
    if (options.marsh) _ = @import("runtime/marsh.zig");
    if (options.peg_engine) _ = @import("runtime/peg.zig");
    if (options.env) _ = @import("runtime/env.zig");

    // The interpreter.
    if (options.fibers) _ = @import("runtime/value/fibers.zig");
    if (options.signal) _ = @import("runtime/signal.zig");
    if (options.debug) _ = @import("runtime/debug.zig");
    if (options.vm) _ = @import("runtime/vm.zig");
    if (options.vm_entry) _ = @import("runtime/vm/entry.zig");
    if (options.lifecycle) _ = @import("runtime/vm/lifecycle.zig");
}

// **The imports above are discarded rather than bound.** A subsystem's
// contribution is its `export`s and nothing here calls it, so
// `_ = @import(...)` in a `comptime` block is what makes Zig analyse the file
// and emit them; binding each to a `const` would suggest a namespace someone
// reads. Two files are imported by the interpreter as well as by this block --
// `vm.zig`'s call protocol and `value/helpers/wrap.zig`, because the loop
// inlines them, measured at 2.4-3.4% on method dispatch and 89% on arithmetic
// for reaching them out of line. One module means one instance either way.
// The other absences are subsystems reached through the file that registers
// them: `os/date.zig`, `os/fs.zig` and `os/process.zig` through `os.zig`,
// `ev/stream.zig`, `ev/channel.zig` and `ev/backend.zig` through `ev.zig`,
// `ffi/types.zig`, `ffi/marshal.zig` and `ffi/call.zig` through `ffi.zig`,
// and `pp/pretty.zig` through `pp.zig`.

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

pub const scratch_vector = @import("runtime/scratch_vector.zig");
pub const utils = @import("runtime/utils.zig");
pub const registry = @import("runtime/registry.zig");
pub const regalloc = @import("runtime/compiler/regalloc.zig");
pub const verify = @import("runtime/bytecode/verify.zig");
pub const emit_core = @import("runtime/compiler/emit.zig");
pub const disasm = @import("runtime/bytecode/disasm.zig");
pub const bytecode = @import("runtime/bytecode.zig");
pub const compiler_primitives = @import("runtime/compiler.zig");
pub const parser = @import("runtime/parser.zig");
pub const specials_core = @import("runtime/compiler/specials.zig");
pub const special = @import("runtime/special_type.zig");
pub const optimize = @import("runtime/compiler/optimize.zig");

pub const scan = @import("runtime/scan.zig");
pub const math = @import("runtime/math.zig");
pub const inttypes = @import("runtime/value/ints.zig");

pub const fs = @import("runtime/os/fs.zig");
pub const stat = @import("runtime/os/fs/stat.zig");
pub const open = @import("runtime/os/fs/open.zig");
pub const io = @import("runtime/io.zig");
pub const os = @import("runtime/os.zig");
pub const date = @import("runtime/os/date.zig");
pub const os_files = @import("runtime/os/fs.zig");
pub const process = @import("runtime/os/process.zig");
pub const os_locks = @import("runtime/ev/locks.zig");
pub const host_stat = @import("runtime/os/fs/host_stat.zig");
pub const ev = @import("runtime/ev.zig");
pub const ev_channel = @import("runtime/ev/channel.zig");
pub const ev_stream = @import("runtime/ev/stream.zig");
pub const ev_backend = @import("runtime/ev/backend.zig");
pub const net = @import("runtime/net.zig");
pub const ffi_classify = @import("runtime/ffi/classify.zig");
pub const ffi = @import("runtime/ffi.zig");
pub const ffi_types = @import("runtime/ffi/types.zig");
pub const ffi_marshal = @import("runtime/ffi/marshal.zig");
pub const ffi_call = @import("runtime/ffi/call.zig");
pub const filewatch = @import("runtime/filewatch.zig");

pub const args = @import("runtime/args.zig");
pub const gc_alloc = @import("runtime/gc.zig");
pub const gc_mark = @import("runtime/gc/mark.zig");
pub const gc_sweep = @import("runtime/gc/sweep.zig");
/// The value layer's namespace. `test/` reaches a leaf through it --
/// `@import("subsystems").value.tables` -- exactly as it reaches every other
/// subsystem through the flat declarations above. The leaf, not the group, is
/// the import unit.
pub const value = @import("runtime/value.zig");
pub const abstract_type = @import("api/abstract_type.zig");
pub const method_type = @import("runtime/method_type.zig");
pub const pp_format = @import("runtime/pp/format.zig");
pub const pp_pretty = @import("runtime/pp/pretty.zig");
pub const pp_describe = @import("runtime/pp.zig");
pub const marsh = @import("runtime/marsh.zig");
pub const peg = @import("runtime/peg.zig");
pub const env = @import("runtime/env.zig");

pub const signal = @import("runtime/signal.zig");
pub const debug = @import("runtime/debug.zig");
pub const vm = @import("runtime/vm.zig");
pub const vm_entry = @import("runtime/vm/entry.zig");
pub const lifecycle = @import("runtime/vm/lifecycle.zig");
pub const vm_state = @import("runtime/vm/state.zig");
pub const dynlib = @import("runtime/dynlib.zig");
pub const stdio = @import("runtime/stdio.zig");
pub const fatal = @import("runtime/fatal.zig");

/// The raise vocabulary and the core-cfunction registration layer, named here
/// so that a caller outside this compilation -- a contract, the client, the
/// image generator -- reaches them the way a subsystem does.
pub const raise = @import("api/raise.zig");
pub const corefn = @import("runtime/corefn.zig");

/// The published entry points, reachable by import rather than by symbol.
///
/// A contract that is about what a native module sees -- the registration
/// surface, the arity checks, the wrappers `module.zig` declares -- names the
/// entry point here. Everything else a contract needs is the subsystem above.
pub const capi = @import("runtime/capi.zig");

// `cabi_check.zig`: `cabi.zig`'s declarations against the definitions they
// name. An `extern fn` is a promise the compiler believes, and this is what
// stops it being taken on trust.
comptime {
    @import("host/cabi_check.zig").verify();
}

// `capi.zig` is the C ABI, and the only file under `src/` that exports.
// Referencing it here is what makes its `comptime` blocks run -- and those
// blocks, rather than the list above, are what decides which subsystems a
// configuration compiles.
comptime {
    _ = @import("runtime/capi.zig");
}
