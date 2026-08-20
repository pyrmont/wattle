//! The printer's two raise-capable entry points, resolved to the C symbols.
//! `subsystems/printer.zig` picks between the two on `-Dpp`.
//!
//! Phase 10 Part 17d. The error is declared and never returned.

const abi = @import("abi");
const raise = @import("raise");
const c = abi.c;

pub const toStringB = raise.declared(c.janet_to_string_b).call;
pub const descriptionB = raise.declared(c.janet_description_b).call;
