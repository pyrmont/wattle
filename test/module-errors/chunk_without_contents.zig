//! A `chunk` callback with no `contents` beside it.
//!
//! A reader of a run has to know whether it holds elements or alternating keys
//! and values, and a type that hands out runs without saying which leaves the
//! reader to guess. `wattle.define` refuses the omission at the definition.
//!
//! `build.zig`'s `module-errors` step compiles this and requires the failure.

const wattle = @import("wattle");

const Payload = struct { items: [2]wattle.Value };

fn chunk(self: *Payload, _: usize) wattle.Chunk {
    return .{ .items = &self.items, .start = 0 };
}

fn length(_: *Payload, _: usize) wattle.Error!usize {
    return 2;
}

pub const at = wattle.define(Payload, .{
    .name = "module-errors/chunk-without-contents",
    .length = length,
    .chunk = chunk,
});

comptime {
    _ = at;
}
