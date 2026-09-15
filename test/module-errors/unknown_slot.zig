//! A callback slot that does not exist.
//!
//! A typo in a field name is the cheapest mistake to make and, where the slot
//! set is positional and the names are the caller's own, one of the more
//! expensive to find. `wattle.define` takes a struct literal, so a field that
//! names no slot is refused at the definition.
//!
//! `build.zig`'s `module-errors` step compiles this and requires the failure.

const wattle = @import("wattle");

const Payload = struct { n: i32 };

fn finalize(_: *Payload, _: usize) void {}

pub const at = wattle.define(Payload, .{
    .name = "module-errors/unknown-slot",
    .finalizer = finalize,
});

comptime {
    _ = at;
}
