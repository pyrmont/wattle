//! A `pull*` inside a `marshal` callback.
//!
//! The mistake `Marshal` and `Unmarshal` are two types for. The runtime builds
//! the push side and the pull side at separate sites, so there is no stream to
//! read from inside a `marshal`; with one bidirectional context this compiled
//! and failed at run time on a state the callback's own direction never set.
//! Two types make it a compile error at the callback's own definition.
//!
//! `build.zig`'s `module-errors` step compiles this and requires the failure.

const janet = @import("janet");

const Payload = struct { n: i32 };

fn backwardsMarshal(self: *Payload, m: *janet.Marshal) janet.Error!void {
    janet.pushAbstract(m, self);
    self.n = try janet.pullInteger(m);
}

pub const at = janet.define(Payload, .{
    .name = "module-errors/pull-on-marshal",
    .marshal = backwardsMarshal,
});

comptime {
    _ = at;
}
