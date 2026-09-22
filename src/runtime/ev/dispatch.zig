//! How the loop hands an event to a callback, and the callback type it takes.
//!
//! An event callback is the function the loop calls when a stream becomes
//! readable, a write completes, a fiber is cancelled or the collector marks.
//! The callbacks are in `stream.zig`, `net.zig` and `filewatch.zig`, and
//! every one of them can raise: a short read raises, a closed stream raises, a
//! failed accept raises.
//!
//! Typing `EVCallback` as raising is what makes the `try` at each dispatch
//! site a compile error to omit. An untyped callback lets a raise flatten
//! into a report that the dispatcher walks past, and the report then surfaces
//! at whichever scope boundary comes next, which is the failure
//! `signal.tryInit` and `signal.restore` assert against.
//!
//! `dispatch` is the one site a raising delivery goes through. It keeps the
//! callback, the event and the operation serial of the dispatch in progress
//! in the VM, so that `ev.zig` can name them when a loop with no protected
//! caller ends the process. `dispatchTotal` is the mark and deinit events,
//! which no callback may raise from.

// ==========================================================================
// Project imports
// ==========================================================================

const ev_loop = @import("../ev.zig");
const ev_stream = @import("stream.zig");
const fatal = @import("../fatal.zig");
const raise = @import("../../api/raise.zig");
const vm_state = @import("../vm/state.zig");

// ==========================================================================
// Types
// ==========================================================================

/// What a dispatch is doing: the callback, the event it was given, and the
/// serial of the operation it runs for.
///
/// The three are copied before the call, because a callback may free its own
/// operation and `op` cannot be read after it returns. A record left behind
/// is the failure's, since a dispatch that returns puts back the record it
/// found: a `checkToClose` failure after a callback returned, and any failure
/// outside a callback, finds no record.
pub const DispatchContext = struct {
    callback: EVCallback,
    event: ev_loop.AsyncEvent,
    serial: u64,
};

/// What an event callback is: an operation, the event, and a raise for a
/// failure.
///
/// `stream.zig`'s `Operation` is what a callback reads its stream, its
/// fiber and its own state from, so a stream with several operations
/// outstanding delivers each event to the one it belongs to.
pub const EVCallback = *const fn (*ev_stream.Operation, ev_loop.AsyncEvent) raise.Error!void;

// ==========================================================================
// Public functions
// ==========================================================================

/// Forgets the record of a dispatch that raised.
///
/// `vm/entry.zig` calls this when a fiber resume ends on a raise, which is
/// where a raise stops being in flight: a `try` around `(ev/read ...)` reads
/// the payload of a dispatch that raised, and the record must not then name
/// the next failure of that same turn. `ev.zig` calls it again at the start
/// of a loop turn and of the Windows cancellation drain, so that a record no
/// resume consumed cannot outlive the turn it was made in.
pub fn clearDispatchContext() void {
    vm_state.current().ev.dispatch_context = null;
}

/// Dispatches an event a callback may raise from, recording what it was.
///
/// `op` is the operation and `event` the event it is given. The record is put
/// in place before the call and put back on return, so a raise leaves the
/// record of the innermost dispatch that made it: a callback taking `close`
/// may close a second stream, and that nested dispatch is the one that names
/// the failure. The record outlives the call only while the raise does, which
/// is what `clearDispatchContext` keeps true.
pub inline fn dispatch(
    op: *ev_stream.Operation,
    event: ev_loop.AsyncEvent,
) raise.Error!void {
    const sched = &vm_state.current().ev;
    const enclosing = sched.dispatch_context;
    sched.dispatch_context = .{
        .callback = op.callback,
        .event = event,
        .serial = op.serial,
    };
    try op.callback(op, event);
    sched.dispatch_context = enclosing;
}

/// The dispatch in progress, which after a raise is the dispatch that made
/// it, and nothing when the raise came from outside a callback.
pub fn dispatchContext() ?DispatchContext {
    return vm_state.current().ev.dispatch_context;
}

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
