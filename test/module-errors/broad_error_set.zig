//! A cfunction whose error set is wider than the runtime's.
//!
//! `Error` is `error{JanetSignal}` and nothing else, because the runtime
//! invokes a cfunction *through* that type. An `anyerror!Value` looks like it
//! should be accepted, being a superset with the right payload, but the call
//! reinterprets it as the narrower type, so the author's extra errors are
//! unrepresentable with nothing said about it. The definition is the only
//! place the mistake can still be pointed at.
//!
//! `build.zig`'s `module-errors` step compiles this and requires the failure.

const janet = @import("janet");

/// The right shape, with an error set that is not the runtime's.
fn widened(argv: []janet.Value) align(janet.fn_align) anyerror!janet.Value {
    return argv[0];
}

fn defs(env: *janet.Env) janet.Error!void {
    janet.cfuns(env, "broad", &.{
        janet.reg("widened", &widened, null),
    });
}

comptime {
    janet.entry(defs);
}
