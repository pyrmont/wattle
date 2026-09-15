//! The contracts' assertion, and why it is not `std.debug.assert`.
//!
//! `std.debug.assert` is `if (!ok) unreachable`, and in `ReleaseFast` and
//! `ReleaseSmall` `unreachable` is undefined behaviour rather than a trap. The
//! optimizer may then assume the condition is true and delete the branch that
//! tests it, leaving a contract that still runs, still exits zero and checks
//! nothing.
//!
//! That is a hazard here rather than in general because
//! `res/testing/matrix.janet` runs the whole test step in those two modes,
//! as its `ReleaseFast` and `ReleaseSmall` jobs.
//!
//! `@panic` is a call in every optimize mode and the panic handler aborts,
//! so the condition is evaluated and branched on in a release build too.
//!
//! This is not `std.testing.expect`, which returns
//! `error.TestUnexpectedResult` for a `test` block's runner to collect. A
//! contract is `pub fn run() void` called by `test/contracts.zig`'s driver, so
//! it has no error channel to put a failure in and no runner to collect one,
//! and a failed assertion has to stop the process where it stands.

// ==========================================================================
// Public functions
// ==========================================================================

/// Abort unless `ok`, in every optimize mode.
///
/// `inline` so the panic names the contract's line rather than this file's.
pub inline fn expect(ok: bool) void {
    if (!ok) @panic("contract assertion failed");
}
