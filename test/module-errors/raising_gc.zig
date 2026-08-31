//! A finalizer that raises.
//!
//! `gc` runs mid-sweep on an object that is already unreachable, so there is
//! no scope above it and nothing to retry. `DESIGN.md` section 5 and
//! `FOUND.md`'s "A panicking finalizer poisons the heap and kills the process
//! at deinit" are why this is a compile error at the author's own definition
//! rather than a run-time abort in somebody else's program.
//!
//! `build.zig`'s `module-errors` step compiles this and requires the failure.

const abstract_type = @import("abstract_type");
const raise = @import("raise");

const Payload = struct { n: i32 };

fn raisingGc(_: *Payload, _: usize) raise.Error!c_int {
    return raise.panic("a finalizer cannot report this way");
}

pub const at = abstract_type.define(Payload, .{
    .name = "module-errors/raising-gc",
    .gc = raisingGc,
});

comptime {
    _ = at;
}
