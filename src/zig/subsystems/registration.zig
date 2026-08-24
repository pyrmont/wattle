//! Registration and substitution as their callers see it.
//!
//! It had a second arm until Phase 11 Part 26: `-Dregistry=c` resolved this to
//! `registry_extern.zig`. Phase 10 Part 18 spent the selector; the shim then
//! sat behind a comptime-`false` branch that nothing analyses, which is how it
//! came to declare `janet_text_substitution` for thirteen parts after Part 13
//! retired that face.
//!
//! Phase 10 Part 17f. Only the two raise-capable entry points need a façade.
//! Everything else `registry.zig` exports -- `janet_def`, the four
//! `janet_cfuns*` forms, `janet_resolve`, `janet_binding_from_entry` -- cannot
//! raise, so a caller reaches those through the C ABI as it always did and
//! nothing is gained by naming them here.

const impl = @import("registry.zig");

pub const registerAbstractType = impl.registerAbstractType;
pub const textSubstitution = impl.textSubstitution;
