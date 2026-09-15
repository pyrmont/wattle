//! A `pull*` inside a `marshal` callback.
//!
//! The mistake `Marshal` and `Unmarshal` are two types for. The runtime builds
//! the push side and the pull side at separate sites, so there is no stream to
//! read from inside a `marshal`. One bidirectional context would compile this
//! and fail at run time on a state the callback's own direction never set; two
//! types make it a compile error at the callback's own definition.
//!
//! `build.zig`'s `module-errors` step compiles this and requires the failure.

const wattle = @import("wattle");

const Payload = struct { n: i32 };

fn backwardsMarshal(self: *Payload, m: *wattle.Marshal) wattle.Error!void {
    wattle.pushAbstract(m, self);
    self.n = try wattle.pullInteger(m);
}

pub const at = wattle.define(Payload, .{
    .name = "module-errors/pull-on-marshal",
    .marshal = backwardsMarshal,
});

comptime {
    _ = at;
}
