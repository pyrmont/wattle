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
//! copies. Their `_extern.zig` shims are named by `vm_run.zig` alone, and only
//! when the selector says C.
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
    if (options.vector) _ = @import("vector.zig");
    if (options.utilities) _ = @import("utils.zig");
    if (options.registry) _ = @import("registry.zig");
    if (options.int_scan) _ = @import("intscan.zig");
    if (options.text_scan) _ = @import("textscan.zig");
    if (options.regalloc) _ = @import("regalloc.zig");
    if (options.verify) _ = @import("verify.zig");
    if (options.remove_noops) _ = @import("remove_noops.zig");
    if (options.movopt) _ = @import("movopt.zig");
    if (options.emit_core) _ = @import("emit_core.zig");
    if (options.asm_encode) _ = @import("asm_encode.zig");
    if (options.asm_decode) _ = @import("asm_decode.zig");
    if (options.disasm) _ = @import("disasm.zig");
    if (options.asm_core) _ = @import("asm_core.zig");
    if (options.compiler_primitives) _ = @import("compiler_primitives.zig");
    if (options.parser_core) _ = @import("parser_core.zig");
    if (options.specials_core) _ = @import("specials_core.zig");
    if (options.builtin_optimizers) _ = @import("builtin_optimizers.zig");

    // Numbers.
    if (options.number_scan) _ = @import("numscan.zig");
    if (options.math_core) _ = @import("math.zig");
    if (options.int_types_core) _ = @import("inttypes.zig");

    // Platform and standard-library services.
    if (options.os_permissions) _ = @import("os_permissions.zig");
    if (options.os_platform) _ = @import("os_platform.zig");
    if (options.os_environ) _ = @import("os_environ.zig");
    if (options.os_fs) _ = @import("os_fs.zig");
    if (options.os_stat) _ = @import("os_stat.zig");
    if (options.os_time) _ = @import("os_time.zig");
    if (options.os_fs_paths) _ = @import("os_fs_paths.zig");
    if (options.io_core) _ = @import("io_core.zig");
    if (options.os_process) _ = @import("os_process.zig");
    if (options.os_surface) _ = @import("os_surface.zig");
    if (options.ev_core) _ = @import("ev_core.zig");
    if (options.ev_loop) _ = @import("ev_loop.zig");
    if (options.net_sockets) _ = @import("net_sockets.zig");
    if (options.ffi_layout) _ = @import("ffi_layout.zig");
    if (options.ffi_classify) _ = @import("ffi_classify.zig");
    if (options.ffi_core) _ = @import("ffi_core.zig");
    if (options.filewatch_flags) _ = @import("filewatch_flags.zig");
    if (options.filewatch_core) _ = @import("filewatch_core.zig");

    // The value layer and the collector.
    if (options.args_core) _ = @import("args_core.zig");
    if (options.gc_alloc) _ = @import("gc_alloc.zig");
    if (options.gc_mark) _ = @import("gc_mark.zig");
    if (options.gc_sweep) _ = @import("gc_sweep.zig");
    if (options.buffer_array) _ = @import("buffer_array.zig");
    if (options.string_symbol) _ = @import("string_symbol.zig");
    if (options.struct_table) _ = @import("struct_table.zig");
    if (options.value_order) _ = @import("value_order.zig");
    if (options.value_access) _ = @import("value_access.zig");
    if (options.abstract_core) _ = @import("abstract_core.zig");
    if (options.value_alloc) _ = @import("value_alloc.zig");
    if (options.value_wrap) _ = @import("value_wrap.zig");
    _ = @import("os_locks.zig");
    _ = @import("host_stat.zig");
    _ = @import("fatal.zig");
    if (options.pp) _ = @import("pp_format.zig");
    if (options.marsh) _ = @import("marsh.zig");
    if (options.peg_engine) _ = @import("peg.zig");
    if (options.core_env) _ = @import("core_env.zig");

    // The interpreter.
    if (options.vm_state) _ = @import("vm_state.zig");
    if (options.fiber_core) _ = @import("fiber_core.zig");
    if (options.signal_core) _ = @import("signal_core.zig");
    if (options.trace_frames) _ = @import("trace_frames.zig");
    if (options.debug_frames) _ = @import("debug_frames.zig");
    if (options.vm_calls) _ = @import("vm_calls.zig");
    if (options.vm_run) _ = @import("vm_run.zig");
    if (options.vm_entry) _ = @import("vm_entry.zig");
    if (options.vm_lifecycle) _ = @import("vm_lifecycle.zig");
}
