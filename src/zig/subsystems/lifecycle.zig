//! The runtime's lifecycle as its callers see it.
//!
//! It had a second arm until Phase 11 Part 26: `-Dvm-lifecycle=c` resolved this
//! to `vm_lifecycle_extern.zig`. Phase 10 Part 18 spent the selector; the shim
//! then sat behind a comptime-`false` branch that nothing analyses.
//!
//! Phase 10 Part 17d. `sandboxAssert` is why this file exists and the rest are
//! here because they share its selector: fifty-eight cfunctions across `os`,
//! `io`, `net`, `ffi` and the module loader open with `janet_sandbox_assert`,
//! which makes it the most-called raise in the runtime after the argument
//! layer's. The alternative to a façade is fifty-eight copies of a two-line
//! conditional import, which is what `arglayer.zig` exists to avoid.

const impl = @import("vm_lifecycle.zig");

pub const sandboxAssert = impl.sandboxAssert; // janet_sandbox_assert
pub const init = impl.init; // janet_init
pub const sandbox = impl.sandbox; // janet_sandbox
