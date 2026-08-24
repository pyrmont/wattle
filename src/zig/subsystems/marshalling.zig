//! The marshalling context's raise-capable entry points as their callers see
//! them.
//!
//! It had a second arm until Phase 11 Part 26: `-Dmarsh=c` resolved this to
//! `marsh_extern.zig`. Phase 10 Part 18 spent the selector; the shim then sat
//! behind a comptime-`false` branch that nothing analyses.
//!
//! Phase 10 Part 17d. These are the five an abstract type's `marshal` and
//! `unmarshal` callbacks use to write and read their own payload, so every
//! marshallable abstract in the tree reaches them — the parser, the PEG
//! engine, the FFI's two types, the file handle and the event-loop stream.
//! Each raises on a malformed image, which is untrusted input by definition.
//!
//! The rest of the protocol is absent for Phase 10's fourth rule.
//! `janet_marshal_flags` and `janet_unmarshal_flags` return a field of the
//! context and cannot fail, so a caller of either still writes
//! `c.janet_marshal_flags(...)` and gets the same symbol under either
//! selector. So does a caller of `janet_marshal_abstract`, which only records
//! a reference.
//!
//! **`marshalSize` is the fourth, and Phase 11 Part 14 added it because it was
//! missing.** This list said `janet_marshal_size` was "reached from inside the
//! subsystem", and it was not: `pegMarshal` and `fileMarshal` both called the
//! *face* from inside a `raise.Raising` callback, so a buffer that refused to
//! grow mid-write became a report nobody consumed. It writes a length through
//! `push64` like any other value and raises exactly where `marshalInt64` does.

const impl = @import("marsh.zig");

pub const marshalInt = impl.marshalInt; // janet_marshal_int
pub const marshalInt64 = impl.marshalInt64; // janet_marshal_int64
pub const marshalByte = impl.marshalByte; // janet_marshal_byte
pub const marshalSize = impl.marshalSize; // janet_marshal_size
