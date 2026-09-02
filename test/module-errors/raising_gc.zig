//! A finalizer that raises.
//!
//! `gc` runs mid-sweep on an object that is already unreachable, so there is
//! no scope above it and nothing to retry. `DESIGN.md` section 5 is why this
//! is a compile error at the author's own definition rather than a poisoned
//! heap in somebody else's program.
//!
//! `build.zig`'s `module-errors` step compiles this and requires the failure.

const janet = @import("janet");

const Payload = struct { n: i32 };

fn raisingGc(_: *Payload, _: usize) janet.Error!void {
    return janet.panic("a finalizer cannot report this way");
}

pub const at = janet.define(Payload, .{
    .name = "module-errors/raising-gc",
    .gc = raisingGc,
});

comptime {
    _ = at;
}
