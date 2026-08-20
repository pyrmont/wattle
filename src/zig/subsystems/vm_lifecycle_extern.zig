//! `vm_lifecycle.zig`'s raise-capable exports, resolved to the C symbols.
//! `subsystems/lifecycle.zig` picks between the two on `-Dvm-lifecycle`.
//!
//! Phase 10 Part 17d. The error is declared and never returned: the C body
//! raises from the inside by jumping.

const abi = @import("abi");
const raise = @import("raise");
const c = abi.c;

pub const sandboxAssert = raise.declared(c.janet_sandbox_assert).call;
pub const init = raise.declared(c.janet_init).call;
pub const sandbox = raise.declared(c.janet_sandbox).call;
