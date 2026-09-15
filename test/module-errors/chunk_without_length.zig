//! A `chunk` callback with no `length` beside it.
//!
//! A reader asks `chunk` for the run holding each index below the length, so a
//! type that hands out runs and has no length gives the reader nothing to stop
//! at. `wattle.define` refuses the pair at the definition.
//!
//! `build.zig`'s `module-errors` step compiles this and requires the failure.

const wattle = @import("wattle");

const Payload = struct { items: [2]wattle.Value };

fn chunk(self: *Payload, _: usize) wattle.Chunk {
    return .{ .items = &self.items, .start = 0 };
}

pub const at = wattle.define(Payload, .{
    .name = "module-errors/chunk-without-length",
    .chunk = chunk,
});

comptime {
    _ = at;
}
