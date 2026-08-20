//! `value_access.zig`'s Zig interface, resolved to the C symbols instead of the
//! Zig bodies. `subsystems/access.zig` picks between the two on
//! `-Dvalue-access`.
//!
//! Phase 10 Part 17c, and the same shape as `args_core_extern.zig`: the error
//! is declared and never returned, because the C body raises from the inside
//! by jumping. `raise.declared` derives each signature from the C declaration
//! rather than restating it.

const abi = @import("abi");
const raise = @import("raise");
const c = abi.c;

/// `src/core/util.h`, declared here rather than translated, for the reason
/// `abi.zig` gives: that header falls through to `dlfcn.h` on any target it
/// does not recognise as Windows and breaks the shared translation. The
/// `Janet` parameters are `abi.zig`'s own type, so nothing about the
/// single-translation rule is at stake. `vm_run.zig` carried this same
/// declaration until Part 17c gave it a layer to import instead.
extern fn janet_next_impl(ds: c.Janet, key: c.Janet, is_interpreter: c_int) callconv(.c) c.Janet;

pub const next = raise.declared(c.janet_next).call;
pub const nextImpl = raise.declared(janet_next_impl).call;
pub const in = raise.declared(c.janet_in).call;
pub const getIndex = raise.declared(c.janet_getindex).call;
pub const length = raise.declared(c.janet_length).call;
pub const lengthv = raise.declared(c.janet_lengthv).call;
pub const putIndex = raise.declared(c.janet_putindex).call;
pub const put = raise.declared(c.janet_put).call;
pub const getImpl = raise.declared(c.janet_get).call;
