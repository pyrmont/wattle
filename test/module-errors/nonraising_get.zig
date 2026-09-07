//! A `get` that cannot report a refusal.
//!
//! The other half of the raising rule: `get` runs inside an interpreter frame
//! with a real scope above it, so its return type has to include the error an
//! author eventually returns.
//!
//! `build.zig`'s `module-errors` step compiles this and requires the failure.

const janet = @import("janet");
const repr = @import("repr");

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
