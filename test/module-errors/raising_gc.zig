//! A finalizer that raises.
//!
//! `gc` runs mid-sweep on an object that is already unreachable, so there is
//! no scope above it, nothing to retry, and no caller a report could reach.
//! Its type has no error union, which makes this a compile error at the
//! author's own definition rather than a poisoned heap in somebody else's
//! program.
//!
//! `build.zig`'s `module-errors` step compiles this and requires the failure.

const wattle = @import("wattle");

const Payload = struct { n: i32 };

fn raisingGc(_: *Payload, _: usize) wattle.Error!void {
    return wattle.panic("a finalizer cannot report this way");
}

pub const at = wattle.define(Payload, .{
    .name = "module-errors/raising-gc",
    .gc = raisingGc,
});

comptime {
    _ = at;
}
