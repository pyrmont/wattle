//! The event loop's callback type, typed as raising.
//!
//! An event callback is the function the loop calls when a stream becomes
//! readable, a write completes, a fiber is cancelled or the collector marks.
//! The callbacks are in `ev/stream.zig`, `net.zig` and `filewatch.zig`, and
//! every one of them can raise: a short read raises, a closed stream raises, a
//! failed accept raises.
//!
//! The pointer is storage and the type is this file's. A fiber has an
//! `ev_callback` member and `ev.asyncStartFiber` takes a callback; both are a
//! place to put a pointer rather than a calling convention, so the pointer is
//! unchanged and only its declared type differs. That is the same division
//! `abstract_type.zig` draws, and for the same reason.
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
const fatal = @import("fatal.zig");
const fibers = @import("value/fibers.zig");
const raise = @import("../api/raise.zig");

// ==========================================================================
// Types
// ==========================================================================

/// What an event callback is: a fiber, the event, and a raise for a failure.
pub const EVCallback = *const fn (*fibers.Fiber, ev_loop.AsyncEvent) raise.Error!void;

// ==========================================================================
// Public functions
// ==========================================================================

/// Dispatches an event no callback may raise from, and aborts if one does.
///
/// `callback` is the callback, `fiber` the fiber it runs for and `event` the
/// event. The mark and deinit events are the two: the first runs inside the
/// collector's traversal and the second inside `ev.zig`'s `asyncEnd`, which is
/// the teardown a raise would have to return through. No callback in the tree
/// raises from either, each doing a mark or a free and nothing else,
/// so a raise here is a defect in that callback and naming it beats letting
/// the report travel to whichever scope boundary comes next.
pub inline fn dispatchTotal(
    callback: EVCallback,
    fiber: *fibers.Fiber,
    event: ev_loop.AsyncEvent,
) void {
    callback(fiber, event) catch fatal.fatal(
        "an event callback raised from the mark or deinit event, which cannot take a raise",
    );
}

/// Reads a callback out of storage.
///
/// `slot` is a fiber's `ev_callback` member or an argument to
/// `ev.asyncStartFiber`. The pointer is the same pointer.
///
/// See `stored`, which is the same pointer on its way into that storage.
pub inline fn of(slot: ev_loop.EVCallback) EVCallback {
    return @ptrCast(slot.?);
}

/// Returns a callback on its way into that storage, at registration.
///
/// `callback` is the callback. The pointer is the same pointer.
///
/// See `of`, which is the read back out.
pub inline fn stored(callback: anytype) ev_loop.EVCallback {
    return @ptrCast(callback);
}
