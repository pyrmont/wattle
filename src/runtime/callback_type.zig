//! The event loop's callback type, typed as raising.
//!
//! An event callback is the function the loop calls when a stream becomes
//! readable, a write completes, a fiber is cancelled or the collector marks.
//! The callbacks are in `ev/stream.zig`, `net.zig` and `filewatch.zig`, and
//! every one of them can raise: a short read raises, a closed stream raises, a
//! failed accept raises.
//!
//! Typing it as raising is what makes the `try` at each dispatch site a
//! compile error to omit. An untyped callback lets a raise flatten into a
//! report that the dispatcher walks past, and the report then surfaces at
//! whichever scope boundary comes next, which is the failure `signal.tryInit`
//! and `signal.restore` assert against.

// ==========================================================================
// Project imports
// ==========================================================================

const ev_loop = @import("ev.zig");
const ev_stream = @import("ev/stream.zig");
const fatal = @import("fatal.zig");
const raise = @import("../api/raise.zig");

// ==========================================================================
// Types
// ==========================================================================

/// What an event callback is: an operation, the event, and a raise for a
/// failure.
///
/// `ev/stream.zig`'s `Operation` is what a callback reads its stream, its
/// fiber and its own state from, so a stream with several operations
/// outstanding delivers each event to the one it belongs to.
pub const EVCallback = *const fn (*ev_stream.Operation, ev_loop.AsyncEvent) raise.Error!void;

// ==========================================================================
// Public functions
// ==========================================================================

/// Dispatches an event no callback may raise from, and aborts if one does.
///
/// `callback` is the callback, `op` the operation it runs for and `event` the
/// event. The mark and deinit events are the two: the first runs inside the
/// collector's traversal and the second inside `ev.zig`'s `asyncEnd`, which is
/// the teardown a raise would have to return through. No callback in the tree
/// raises from either, each doing a mark or a free and nothing else,
/// so a raise here is a defect in that callback and naming it beats letting
/// the report travel to whichever scope boundary comes next.
pub inline fn dispatchTotal(
    callback: EVCallback,
    op: *ev_stream.Operation,
    event: ev_loop.AsyncEvent,
) void {
    callback(op, event) catch fatal.fatal(
        "an event callback raised from the mark or deinit event, which cannot take a raise",
    );
}
