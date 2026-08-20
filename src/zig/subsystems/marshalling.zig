//! The marshalling context's raise-capable entry points as their callers see
//! them: `-Dmarsh`'s implementation when the selector says Zig, and the C
//! symbols wearing the same signatures when it says C.
//!
//! Phase 10 Part 17d. These are the five an abstract type's `marshal` and
//! `unmarshal` callbacks use to write and read their own payload, so every
//! marshallable abstract in the tree reaches them — the parser, the PEG
//! engine, the FFI's two types, the file handle and the event-loop stream.
//! Each raises on a malformed image, which is untrusted input by definition.
//!
//! The rest of the protocol is absent for Phase 10's fourth rule.
//! `janet_marshal_flags` and `janet_unmarshal_flags` return a field of the
//! context and cannot fail; `janet_marshal_size` and `janet_marshal_abstract`
//! are reached from inside the subsystem. A caller of any of those still
//! writes `c.janet_marshal_flags(...)` and gets the same symbol under either
//! selector.

const options = @import("options");

const impl = if (options.marsh)
    @import("marsh.zig")
else
    @import("marsh_extern.zig");

pub const marshalInt = impl.marshalInt; // janet_marshal_int
pub const marshalInt64 = impl.marshalInt64; // janet_marshal_int64
pub const marshalByte = impl.marshalByte; // janet_marshal_byte
