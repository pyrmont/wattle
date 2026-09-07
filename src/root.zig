//! The runtime module's root file.
//!
//! `build.zig` builds the runtime object and the in-file `test` blocks from
//! this module. It also imports it under the name `subsystems` into the
//! client, the bootstrap image generator, the contract driver and the fuzz
//! tests.
//!
//! ## Configurable imports
//!
//! The `comptime` block imports a subsystem when `options` says the build
//! selected it. The imports are discarded rather than bound because binding
//! each to a `const` would suggest a namespace someone reads. Importing a file
//! here makes Zig analyse its container level, which runs the file's `comptime`
//! blocks and, in a test build, collects its `test` blocks.
//!
//! A file the block does not name is analysed when something the compilation
//! analyses refers to it. So `os.zig` causes `os/date.zig` to be analysed. A
//! test build analyses less of the tree than an object build. A file it does
//! not analyse contributes no `test` blocks. So a file whose tests must run is
//! named here even when a subsystem imports it.
//!
//! ## Lazy names
//!
//! The declarations above the block are how a compilation outside the runtime
//! names a subsystem (e.g. `@import("subsystems").peg`). A `pub const` at
//! container scope is analysed only when something references it, and nothing
//! in the runtime references these. A build that turns a subsystem off does
//! not compile it and binding to a name does not force it to do so.

// ==========================================================================
// Project imports
// ==========================================================================

pub const abstract_type = @import("api/abstract_type.zig");
pub const args = @import("runtime/args.zig");
pub const bytecode = @import("runtime/bytecode.zig");
pub const capi = @import("runtime/capi.zig");
pub const compiler_primitives = @import("runtime/compiler.zig");
pub const corefn = @import("runtime/corefn.zig");
pub const date = @import("runtime/os/date.zig");
pub const debug = @import("runtime/debug.zig");
pub const disasm = @import("runtime/bytecode/disasm.zig");
pub const dynlib = @import("runtime/dynlib.zig");
pub const emit_core = @import("runtime/compiler/emit.zig");
pub const env = @import("runtime/env.zig");
pub const ev = @import("runtime/ev.zig");
pub const ev_backend = @import("runtime/ev/backend.zig");
pub const ev_channel = @import("runtime/ev/channel.zig");
pub const ev_stream = @import("runtime/ev/stream.zig");
pub const fatal = @import("runtime/fatal.zig");
pub const ffi = @import("runtime/ffi.zig");
pub const ffi_call = @import("runtime/ffi/call.zig");
pub const ffi_classify = @import("runtime/ffi/classify.zig");
pub const ffi_marshal = @import("runtime/ffi/marshal.zig");
pub const ffi_types = @import("runtime/ffi/types.zig");
pub const filewatch = @import("runtime/filewatch.zig");
pub const fs = @import("runtime/os/fs.zig");
pub const gc_alloc = @import("runtime/gc.zig");
pub const gc_mark = @import("runtime/gc/mark.zig");
pub const gc_sweep = @import("runtime/gc/sweep.zig");
pub const host_stat = @import("runtime/os/fs/host_stat.zig");
pub const inttypes = @import("runtime/value/ints.zig");
pub const io = @import("runtime/io.zig");
pub const lifecycle = @import("runtime/vm/lifecycle.zig");
pub const marsh = @import("runtime/marsh.zig");
pub const math = @import("runtime/math.zig");
pub const method_type = @import("runtime/method_type.zig");
pub const net = @import("runtime/net.zig");
pub const open = @import("runtime/os/fs/open.zig");
pub const optimize = @import("runtime/compiler/optimize.zig");
pub const os = @import("runtime/os.zig");
pub const os_locks = @import("runtime/ev/locks.zig");
pub const parser = @import("runtime/parser.zig");
pub const peg = @import("runtime/peg.zig");
pub const pp_describe = @import("runtime/pp.zig");
pub const pp_format = @import("runtime/pp/format.zig");
pub const pp_pretty = @import("runtime/pp/pretty.zig");
pub const process = @import("runtime/os/process.zig");
pub const raise = @import("api/raise.zig");
pub const regalloc = @import("runtime/compiler/regalloc.zig");
pub const registry = @import("runtime/registry.zig");
pub const scan = @import("runtime/scan.zig");
pub const scratch_vector = @import("runtime/scratch_vector.zig");
pub const signal = @import("runtime/signal.zig");
pub const special = @import("runtime/special_type.zig");
pub const specials_core = @import("runtime/compiler/specials.zig");
pub const stat = @import("runtime/os/fs/stat.zig");
pub const stdio = @import("runtime/stdio.zig");
pub const utils = @import("runtime/utils.zig");
pub const value = @import("runtime/value.zig");
pub const verify = @import("runtime/bytecode/verify.zig");
pub const vm = @import("runtime/vm.zig");
pub const vm_entry = @import("runtime/vm/entry.zig");
pub const vm_state = @import("runtime/vm/state.zig");

// ==========================================================================
// Compile-time imports
// ==========================================================================

/// What the build decided, as comptime booleans generated by `zig build`.
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

    // Named although `os/fs.zig` imports it. A test build analyses none of the
    // calls that reach it, so its `test` blocks need this name.
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
