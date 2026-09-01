//! A callback slot that does not exist.
//!
//! A typo in a field name is the cheapest mistake to make and, with C's
//! positional initializer and its sixteen `JANET_ATEND_*` macros, one of the
//! more expensive to find.
//!
//! `build.zig`'s `module-errors` step compiles this and requires the failure.

const janet = @import("janet");

const Payload = struct { n: i32 };

fn finalize(_: *Payload, _: usize) void {}

pub const at = janet.define(Payload, .{
    .name = "module-errors/unknown-slot",
    .finalizer = finalize,
});

comptime {
    _ = at;
}
