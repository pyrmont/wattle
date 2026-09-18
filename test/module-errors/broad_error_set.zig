//! A cfunction whose error set is wider than the runtime's.
//!
//! `Error` is `error{Signal}` and nothing else, because the runtime
//! invokes a cfunction *through* that type. An `anyerror!Value` looks like it
//! should be accepted, being a superset with the right payload, but the call
//! reinterprets it as the narrower type, so the author's extra errors are
//! unrepresentable with nothing said about it. The definition is the only
//! place the mistake can still be pointed at.
//!
//! `build.zig`'s `module-errors` step compiles this and requires the failure.

const wattle = @import("wattle");

/// The right shape, with an error set that is not the runtime's.
fn widened(argv: []wattle.Value) anyerror!wattle.Value {
    return argv[0];
}

fn defs(env: *wattle.Env) wattle.Error!void {
    wattle.cfuns(env, "broad", &.{
        wattle.reg("widened", &widened, null),
    });
}

comptime {
    wattle.entry(defs);
}
