//! The event loop's raise-capable entry points as their callers see them.
//!
//! It had a second arm until Phase 11 Part 26: `-Dev-loop=c` resolved this to
//! `ev_loop_extern.zig`. This was the one of the eleven shims whose condition
//! was not comptime-`true` — `options.ev_loop` is `hasEv(options)`, so
//! `-Dev=false` and `-Dsingle-threaded=true` selected the shim for real, and it
//! held only because nothing in such a build references a declaration here.
//!
//! Phase 10 Part 17d. Four entry points across three of the selector's four
//! files — `ev_loop.zig`, `ev_stream.zig` and `ev_channel.zig` — which is why
//! the façade is named for the selector rather than for a file.
//!
//! `janet_schedule`, `janet_async_end` and the rest of the loop's surface are
//! absent by Phase 10's fourth rule: they cannot raise, and `janet_schedule`
//! in particular is called from a signal-handler-like context where raising
//! would have nowhere to go.
//!
//! **`makeStream`, `makeStreamExt` and `loop` joined in Phase 11 Part 15, and
//! they were missing rather than excluded.** All three raise —
//! `janet_stream`'s `registerStream` on a refused descriptor, `janet_loop`'s
//! `loop1` on anything the scheduler surfaces — and six callers inside the
//! runtime were reaching their C faces from inside `raise.Raising` functions,
//! so the raise became a report nobody consumed and killed the process at an
//! unrelated scope boundary. That is the same defect Part 14 found in
//! `janet_marshal_size`; `phase_11.md`'s rule 40 has the sweep that enumerates
//! the class.

const impl = @import("ev_loop.zig");

pub const cancel = impl.cancel; // janet_cancel
pub const streamFlags = impl.streamFlags; // janet_stream_flags
pub const getChannel = impl.getChannel; // janet_getchannel
pub const channelGive = impl.channelGive; // janet_channel_give
pub const streamClose = impl.streamClose; // janet_stream_close
pub const makeStream = impl.makeStream; // janet_stream
pub const makeStreamExt = impl.makeStreamExt; // janet_stream_ext
pub const loop = impl.loop; // janet_loop
pub const evInit = impl.evInit; // janet_ev_init
pub const edgeTriggeredStream = impl.edgeTriggeredStream; // janet_stream_edge_triggered
pub const levelTriggeredStream = impl.levelTriggeredStream; // janet_stream_level_triggered
pub const threadedCall = impl.threadedCall; // janet_ev_threaded_call
pub const asyncStart = impl.asyncStart; // janet_async_start
pub const asyncStartFiber = impl.asyncStartFiber; // janet_async_start_fiber
