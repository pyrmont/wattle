//! A `get` that cannot report a refusal.
//!
//! The other half of the raising contract: `get` runs inside an interpreter
//! frame with a real scope above it, so its return type has to carry the error
//! the author will eventually want to return.
//!
//! `build.zig`'s `module-errors` step compiles this and requires the failure.

const repr = @import("repr");
const abstract_type = @import("abstract_type");

const Payload = struct { n: i32 };

fn plainGet(_: *Payload, _: repr.Value, _: *repr.Value) c_int {
    return 0;
}

pub const at = abstract_type.define(Payload, .{
    .name = "module-errors/nonraising-get",
    .get = plainGet,
});

comptime {
    _ = at;
}
