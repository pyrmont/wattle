//! The event loop's raise-capable entry points as their callers see them:
//! `-Dev-loop`'s implementation when the selector says Zig, and the C symbols
//! wearing the same signatures when it says C.
//!
//! Phase 10 Part 17d. Four entry points across three of the selector's four
//! files — `ev_loop.zig`, `ev_stream.zig` and `ev_channel.zig` — which is why
//! the façade is named for the selector rather than for a file.
//!
//! `janet_schedule`, `janet_async_end` and the rest of the loop's surface are
//! absent by Phase 10's fourth rule: they cannot raise, and `janet_schedule`
//! in particular is called from a signal-handler-like context where raising
//! would have nowhere to go.

const options = @import("options");

const impl = if (options.ev_loop)
    @import("ev_loop.zig")
else
    @import("ev_loop_extern.zig");

pub const cancel = impl.cancel; // janet_cancel
pub const streamFlags = impl.streamFlags; // janet_stream_flags
pub const getChannel = impl.getChannel; // janet_getchannel
pub const channelGive = impl.channelGive; // janet_channel_give
pub const streamClose = impl.streamClose; // janet_stream_close
pub const evInit = impl.evInit; // janet_ev_init
pub const edgeTriggeredStream = impl.edgeTriggeredStream; // janet_stream_edge_triggered
pub const levelTriggeredStream = impl.levelTriggeredStream; // janet_stream_level_triggered
pub const threadedCall = impl.threadedCall; // janet_ev_threaded_call
pub const asyncStart = impl.asyncStart; // janet_async_start
pub const asyncStartFiber = impl.asyncStartFiber; // janet_async_start_fiber
