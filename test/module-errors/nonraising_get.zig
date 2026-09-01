//! A `get` that cannot report a refusal.
//!
//! The other half of the raising contract: `get` runs inside an interpreter
//! frame with a real scope above it, so its return type has to carry the error
//! the author will eventually want to return.
//!
//! `build.zig`'s `module-errors` step compiles this and requires the failure.

const repr = @import("repr");
const janet = @import("janet");

const Payload = struct { n: i32 };

fn plainGet(_: *Payload, _: repr.Value) ?repr.Value {
    return null;
}

pub const at = janet.define(Payload, .{
    .name = "module-errors/nonraising-get",
    .get = plainGet,
});

comptime {
    _ = at;
}
