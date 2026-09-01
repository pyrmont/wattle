//! The contracts' assertion, and the reason it is not `std.debug.assert`.
//!
//! `std.debug.assert` is `if (!ok) unreachable`, and in `ReleaseFast` and
//! `ReleaseSmall` `unreachable` is undefined behaviour rather than a trap — the
//! optimizer is entitled to assume the condition holds and delete the branch
//! that tests it. A contract built that way still runs, still exits zero, and
//! checks nothing.
//!
//! That matters here rather than in general because
//! `tools/testing/matrix.janet` runs the whole test step in exactly those two
//! modes. Three of the acceptance matrix's entries were reporting on a driver
//! whose 5,016 assertions had been compiled out.
//!
//! `@panic` is the fix: it is a call in every optimize mode, and the panic
//! handler aborts. The cost is that the condition is now evaluated and branched
//! on in release builds too, which is what a test is for.
//!
//! This is not `std.testing.expect`, which returns `error.TestUnexpectedResult`
//! for a `test` block's runner to collect. A contract is `pub fn run() void`
//! called by `test/contracts.zig`'s driver; it has no error channel to put a
//! failure in and no runner to collect one, so a failed assertion has to stop
//! the process where it stands.

/// Abort unless `ok`, in every optimize mode.
///
/// `inline` so the panic names the contract's line rather than this file's.
pub inline fn expect(ok: bool) void {
    if (!ok) @panic("contract assertion failed");
}
