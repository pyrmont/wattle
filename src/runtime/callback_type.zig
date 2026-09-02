//! The event loop's callback type, typed as raising.
//!
//! An event callback is the function the loop calls when a stream becomes
//! readable, a write completes, a fiber is cancelled or the collector marks --
//! eight of them in the tree, across `ev/stream.zig`, `net.zig` and
//! `filewatch.zig` -- and every one of them can raise: a short read raises, a
//! closed stream raises, a failed accept raises.
//!
//! **The pointer is storage, and the type is this file's.** A fiber has an
//! `ev_callback` member and `ev.asyncStartFiber` takes one; both are a place to
//! put a pointer rather than a calling convention, so the pointer is unchanged
//! and only its declared type differs. That is the same division
//! `abstract_type.zig` draws and for the same reason.
//!
//! Typing it as raising is what makes the `try` at each dispatch site a
//! compile error to omit. An untyped callback lets a raise flatten into a
//! report that the dispatcher walks past, and the report then surfaces at
//! whichever scope boundary comes next -- the failure mode `signal.tryInit`
//! and `signal.restore` assert against.

const raise = @import("../api/raise.zig");
const fatal = @import("fatal.zig");
const fibers = @import("value/fibers.zig");
const ev_loop = @import("ev.zig");

/// What an event callback is.
pub const EVCallback = *const fn (*fibers.Fiber, ev_loop.AsyncEvent) raise.Error!void;

/// A callback read out of storage — a fiber's `ev_callback` member, or an
/// argument to `ev.asyncStartFiber`. The pointer is the same pointer.
pub inline fn of(slot: ev_loop.EVCallback) EVCallback {
    return @ptrCast(slot.?);
}

/// The same pointer on its way back into that storage, at registration.
pub inline fn stored(callback: anytype) ev_loop.EVCallback {
    return @ptrCast(callback);
}

/// Dispatch an event no callback may raise from.
///
/// `MARK` and `DEINIT` are the two, and neither has anywhere to put a raise:
/// the first runs inside the collector's traversal and the second inside
/// `ev.zig`'s `asyncEnd`, which is the teardown a raise would have to return
/// *through*. No callback in the tree raises from either — each answers them
/// with a `gc/mark.zig` mark or a free and nothing else — so a raise here is a
/// defect in that callback, and naming it beats letting the report travel to
/// whichever scope boundary comes next.
pub inline fn dispatchTotal(
    callback: EVCallback,
    fiber: *fibers.Fiber,
    event: ev_loop.AsyncEvent,
) void {
    callback(fiber, event) catch fatal.fatal(
        "an event callback raised from JANET_ASYNC_EVENT_MARK or _DEINIT, which cannot carry a raise",
    );
}
