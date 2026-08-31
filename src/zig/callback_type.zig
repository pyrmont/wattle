//! `JanetEVCallback`, typed as raising.
//!
//! An event callback is the function the loop calls when a stream becomes
//! readable, a write completes, a fiber is cancelled or the collector marks --
//! eight of them in the tree, across `ev/stream.zig`,
//! stream becomes readable, a write completes, a fiber is cancelled or the
//! collector marks — eight of them in the tree, across `ev_stream.zig`,
//! `net_sockets.zig` and `filewatch_core.zig` — and every one of them can
//! raise: a short read raises, a closed stream raises, a failed accept raises.
//!
//! `janet.h` fixes the C signature at `void (*)(JanetFiber *, JanetAsyncEvent)`
//! and a C signature has no error channel, so until this file each callback
//! kept an abi that jumped. What is left of that signature is a *layout*:
//! `JanetFiber` has an `ev_callback` member and `janet_async_start_fiber`
//! takes one, and both are storage rather than a calling convention. So the
//! pointer is unchanged and only its declared type differs, which is the same
//! division `abstract_type.zig` draws and for the same reason.
//!
//! ## Why there is no `crossingOrDeliver` left at a dispatch
//!
//! There were eighteen: the two backends' event pumps, the stream closer, the
//! collector's mark, and `janet_async_start_fiber`'s own `INIT`. Each called
//! through the C signature, so a raise inside a callback reported and the
//! dispatcher walked on — and the report then surfaced at whichever scope
//! boundary came next, which is the failure mode the hinge's assertions in
//! `janet_try_init` and `janet_restore` exist to catch. Typing the pointer
//! makes the `try` at each of them a compile error to omit, which is decision
//! 5 applied to the last fixed table but one.

const raise = @import("raise");
const fatal = @import("fatal.zig");
const types = @import("types");

/// What an event callback is, since the hinge.
pub const EVCallback = *const fn (*types.JanetFiber, types.JanetAsyncEvent) raise.Error!void;

/// A callback read out of the storage `janet.h` still describes — a fiber's
/// `ev_callback` member, or an argument to `janet_async_start_fiber`. The
/// pointer is the same pointer.
pub inline fn of(slot: types.JanetEVCallback) EVCallback {
    return @ptrCast(slot.?);
}

/// The same pointer on its way back into that storage, at registration.
pub inline fn stored(callback: anytype) types.JanetEVCallback {
    return @ptrCast(callback);
}

/// Dispatch an event no callback may raise from.
///
/// `MARK` and `DEINIT` are the two, and neither has anywhere to put a raise:
/// the first runs inside the collector's traversal and the second inside
/// `janet_async_end`, which is the teardown a raise would have to unwind
/// *through*. No callback in the tree raises from either — each answers them
/// with a `janet_mark` or a `janet_free` and nothing else — so a raise here is
/// a defect in that callback, and naming it beats letting the report travel to
/// whichever scope boundary comes next.
pub inline fn dispatchTotal(
    callback: EVCallback,
    fiber: *types.JanetFiber,
    event: types.JanetAsyncEvent,
) void {
    callback(fiber, event) catch fatal.fatal(
        "an event callback raised from JANET_ASYNC_EVENT_MARK or _DEINIT, which cannot carry a raise",
    );
}
