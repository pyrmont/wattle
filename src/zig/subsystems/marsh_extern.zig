//! `marsh.zig`'s raise-capable interface, resolved to the C symbols.
//! `subsystems/marshalling.zig` picks between the two on `-Dmarsh`.
//!
//! Phase 10 Part 17d. The error is declared and never returned.

const abi = @import("abi");
const raise = @import("raise");
const c = abi.c;

pub const marshalInt = raise.declared(c.janet_marshal_int).call;
pub const marshalInt64 = raise.declared(c.janet_marshal_int64).call;
pub const marshalByte = raise.declared(c.janet_marshal_byte).call;
