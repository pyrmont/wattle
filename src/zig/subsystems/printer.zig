//! The two renderers a subsystem reaches when it needs a value as text.
//!
//! They had a second arm until Phase 11 Part 26: `-Dpp=c` resolved this to
//! `pp_extern.zig`. Phase 10 Part 18 spent the selector; the shim then sat
//! behind a comptime-`false` branch that nothing analyses.
//!
//! Phase 10 Part 17d. `janet_to_string_b` is `(string x)` and
//! `janet_description_b` is `(describe x)`, and both raise for the same
//! reason: rendering a value runs an abstract type's `tostring` callback,
//! which is a C function pointer a native module supplied. That callback is
//! also why every file that calls these is jump-transparent and stays so —
//! SPIKE-8's rule says it may not raise and nothing enforces it.

const impl = @import("pp_describe.zig");

pub const toStringB = impl.toStringB; // janet_to_string_b
pub const descriptionB = impl.descriptionB; // janet_description_b
