//! The registry's two raise-capable entry points, resolved to the C symbols.
//! `subsystems/registration.zig` picks between these and the Zig ones on
//! `-Dregistry`.
//!
//! Phase 10 Part 17f. The error is declared and never returned: `util.c`'s
//! bodies jump from the inside.
//!
//! Neither symbol is in `abi.zig`'s translation -- `janet_text_substitution`
//! because it is `util.h`'s and `util.h` is deliberately not translated, and
//! `janet_register_abstract_type` because `raise.declared` needs the exact
//! parameter types and `janet.h`'s `const JanetAbstractType *` translates to a
//! `[*c]` the Zig callers do not use.

const abi = @import("abi");
const raise = @import("raise");
const c = abi.c;

extern fn janet_register_abstract_type(at: *const c.JanetAbstractType) callconv(.c) void;
extern fn janet_text_substitution(
    subst: *c.Janet,
    bytes: [*c]const u8,
    len: u32,
    extra_argv: [*c]c.JanetArray,
) callconv(.c) c.JanetByteView;

pub const registerAbstractType = raise.declared(janet_register_abstract_type).call;
pub const textSubstitution = raise.declared(janet_text_substitution).call;
