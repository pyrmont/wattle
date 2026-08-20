//! The event loop's raise-capable entry points, resolved to the C symbols.
//! `subsystems/evloop.zig` picks between the two on `-Dev-loop`.
//!
//! Phase 10 Part 17d. The error is declared and never returned.

const abi = @import("abi");
const raise = @import("raise");
const ev_callback = @import("ev_callback.zig");
const c = abi.c;

pub const cancel = raise.declared(c.janet_cancel).call;
pub const streamFlags = raise.declared(c.janet_stream_flags).call;
pub const getChannel = raise.declared(c.janet_getchannel).call;
pub const streamClose = raise.declared(c.janet_stream_close).call;
pub const evInit = raise.declared(c.janet_ev_init).call;
pub const edgeTriggeredStream = raise.declared(c.janet_stream_edge_triggered).call;
pub const levelTriggeredStream = raise.declared(c.janet_stream_level_triggered).call;
pub const threadedCall = raise.declared(c.janet_ev_threaded_call).call;

/// The C face reports "blocked" as an `int`; a Zig caller wants the `bool` the
/// implementation actually produces, so this is the one entry here that is not
/// a bare `raise.declared`.
pub inline fn channelGive(chan: ?*c.JanetChannel, x: c.Janet) raise.Raising(bool) {
    return try raise.crossing(c.janet_channel_give(chan, x)) != 0;
}

/// The two async starts, which `raise.declared` cannot derive: the C symbol
/// takes `JanetEVCallback` and a converted caller has an
/// `ev_callback.EVCallback`, so the shim casts the pointer as well as turning
/// the report back into an error. The cast is the same one `ev_callback.stored`
/// makes at every registration -- the C ABI's storage, not its convention.
pub inline fn asyncStartFiber(
    fiber: [*c]c.JanetFiber,
    s: *c.JanetStream,
    mode: c.JanetAsyncMode,
    callback: ev_callback.EVCallback,
    state: ?*anyopaque,
) raise.Raising(void) {
    c.janet_async_start_fiber(fiber, s, mode, ev_callback.stored(callback), state);
    if (raise.tookCRaise()) return error.JanetSignal;
}

pub inline fn asyncStart(
    s: *c.JanetStream,
    mode: c.JanetAsyncMode,
    callback: ev_callback.EVCallback,
    state: ?*anyopaque,
) raise.Error {
    c.janet_async_start(s, mode, ev_callback.stored(callback), state);
}
