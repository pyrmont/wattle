//! `buffer_array.zig`'s raise-capable interface, resolved to the C symbols
//! instead of the Zig bodies. `subsystems/containers.zig` picks between the two
//! on `-Dbuffer-array`.
//!
//! Phase 10 Part 17c, and the same shape as `args_core_extern.zig`: the error
//! is declared and never returned, because the C body raises from the inside by
//! jumping.

const abi = @import("abi");
const raise = @import("raise");
const c = abi.c;

pub const canRealloc = raise.declared(c.janet_buffer_can_realloc).call;
pub const pointerBufferUnsafe = raise.declared(c.janet_pointer_buffer_unsafe).call;
pub const bufferEnsure = raise.declared(c.janet_buffer_ensure).call;
pub const bufferSetcount = raise.declared(c.janet_buffer_setcount).call;
pub const bufferExtra = raise.declared(c.janet_buffer_extra).call;
pub const bufferPushBytes = raise.declared(c.janet_buffer_push_bytes).call;
pub const bufferPushString = raise.declared(c.janet_buffer_push_string).call;
pub const bufferPushCString = raise.declared(c.janet_buffer_push_cstring).call;
pub const bufferPushU8 = raise.declared(c.janet_buffer_push_u8).call;
pub const bufferPushU16 = raise.declared(c.janet_buffer_push_u16).call;
pub const bufferPushU32 = raise.declared(c.janet_buffer_push_u32).call;
pub const bufferPushU64 = raise.declared(c.janet_buffer_push_u64).call;
pub const arrayPush = raise.declared(c.janet_array_push).call;
