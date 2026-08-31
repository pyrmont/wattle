//! A callback slot that does not exist.
//!
//! A typo in a field name is the cheapest mistake to make and, with C's
//! positional initializer and its sixteen `JANET_ATEND_*` macros, one of the
//! more expensive to find.
//!
//! `build.zig`'s `module-errors` step compiles this and requires the failure.

const abstract_type = @import("abstract_type");

const Payload = struct { n: i32 };

fn finalize(_: *Payload, _: usize) c_int {
    return 0;
}

pub const at = abstract_type.define(Payload, .{
    .name = "module-errors/unknown-slot",
    .finalizer = finalize,
});

comptime {
    _ = at;
}
