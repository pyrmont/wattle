//! A callback written over the wrong payload type.
//!
//! The mistake `wattle.define` exists to catch: the author declares the
//! abstract with one payload type and writes a callback over another. In C
//! both are `void *`, so nothing says anything until the cast reads the wrong
//! memory at run time, in somebody else's program.
//!
//! `build.zig`'s `module-errors` step compiles this and requires the failure.

const wattle = @import("wattle");

const Right = struct { n: i32 };
const Wrong = struct { m: f64 };

fn wrongPayloadGc(_: *Wrong, _: usize) void {}

pub const at = wattle.define(Right, .{
    .name = "module-errors/wrong-payload",
    .gc = wrongPayloadGc,
});

comptime {
    _ = at;
}
