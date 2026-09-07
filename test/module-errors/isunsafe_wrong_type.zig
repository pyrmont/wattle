//! `isUnsafe` on something that is neither capability.
//!
//! It takes `anytype`, because Zig has no overloading and the question is the
//! same one on both sides of a marshal. `anytype` accepts anything until
//! something rejects it, so the rejection is written out, and this fixture is
//! what checks that it is.
//!
//! `build.zig`'s `module-errors` step compiles this and requires the failure.

const janet = @import("janet");

const Payload = struct { n: i32 };

fn confusedMarshal(self: *Payload, m: *janet.Marshal) janet.Error!void {
    // The render, not the marshal: a plausible slip, and the sort of thing
    // `anytype` would otherwise leave to a much later error.
    if (janet.isUnsafe(self)) return janet.panic("unreachable");
    janet.pushAbstract(m, self);
}

pub const at = janet.define(Payload, .{
    .name = "module-errors/isunsafe-wrong-type",
    .marshal = confusedMarshal,
});

comptime {
    _ = at;
}
