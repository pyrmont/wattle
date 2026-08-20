//! Registration and substitution as their callers see it: `-Dregistry`'s
//! implementation when the selector says Zig, and the C symbols wearing the
//! same signatures when it says C.
//!
//! Phase 10 Part 17f. Only the two raise-capable entry points need a façade.
//! Everything else `registry.zig` exports -- `janet_def`, the four
//! `janet_cfuns*` forms, `janet_resolve`, `janet_binding_from_entry` -- cannot
//! raise, so a caller reaches those through the C ABI as it always did and
//! nothing is gained by naming them here.

const options = @import("options");

const impl = if (options.registry)
    @import("registry.zig")
else
    @import("registry_extern.zig");

pub const registerAbstractType = impl.registerAbstractType;
pub const textSubstitution = impl.textSubstitution;
