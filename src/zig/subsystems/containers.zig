//! The growable containers' raise-capable kernels as their callers see them:
//! `-Dbuffer-array`'s implementation when the selector says Zig, and the C
//! symbols wearing the same signatures when it says C.
//!
//! Phase 10 Part 17c. Only the kernels that *raise* are here, which is a small
//! part of the subsystem's surface and the whole of its jump surface. Two
//! failures account for all of them: a container that has reached `INT32_MAX`
//! — "array overflow", "buffer overflow" — and a buffer whose payload is
//! foreign memory the runtime may not reallocate.
//!
//! Everything else the containers export is absent on purpose, by Phase 10's
//! fourth rule. `janet_array_pop`, `janet_buffer_init`, `janet_array_ensure`
//! and their several dozen relatives cannot raise, and a façade entry for one
//! would put a `try` on it at every call site, which is a lie about what it
//! does. A caller still writes `c.janet_array_pop(...)` and gets the same
//! symbol under either selector.
//!
//! `string_symbol.zig` and `struct_table.zig` are the other two container
//! subsystems and neither appears here, which is worth saying because it looks
//! like an omission. Their raises are all *inside cfunctions* — the shape Part
//! 17b already converted — rather than in kernels another subsystem calls, so
//! there is nothing for a façade to present.

const options = @import("options");

const impl = if (options.buffer_array)
    @import("buffer_array.zig")
else
    @import("buffer_array_extern.zig");

pub const canRealloc = impl.canRealloc; // janet_buffer_can_realloc
pub const pointerBufferUnsafe = impl.pointerBufferUnsafe; // janet_pointer_buffer_unsafe
pub const bufferEnsure = impl.bufferEnsure; // janet_buffer_ensure
pub const bufferSetcount = impl.bufferSetcount; // janet_buffer_setcount
pub const bufferExtra = impl.bufferExtra; // janet_buffer_extra
pub const bufferPushBytes = impl.bufferPushBytes; // janet_buffer_push_bytes
pub const bufferPushString = impl.bufferPushString; // janet_buffer_push_string
pub const bufferPushCString = impl.bufferPushCString; // janet_buffer_push_cstring
pub const bufferPushU8 = impl.bufferPushU8; // janet_buffer_push_u8
pub const bufferPushU16 = impl.bufferPushU16; // janet_buffer_push_u16
pub const bufferPushU32 = impl.bufferPushU32; // janet_buffer_push_u32
pub const bufferPushU64 = impl.bufferPushU64; // janet_buffer_push_u64
pub const arrayPush = impl.arrayPush; // janet_array_push
