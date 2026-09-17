//! A `contents` with no `chunk` callback beside it.
//!
//! A type's contents are read through its runs, so a type that declares
//! contents and hands out no runs gives a reader nothing to read.
//! `wattle.define` refuses the declaration at the definition.
//!
//! `build.zig`'s `module-errors` step compiles this and requires the failure.

const wattle = @import("wattle");

const Payload = struct { items: [2]wattle.Value };

fn length(_: *Payload, _: usize) wattle.Error!usize {
    return 2;
}

pub const at = wattle.define(Payload, .{
    .name = "module-errors/contents-without-chunk",
    .length = length,
    .contents = .pairs,
});

comptime {
    _ = at;
}
