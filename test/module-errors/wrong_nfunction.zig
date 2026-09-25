//! An nfunction with the wrong shape, registered.
//!
//! The runtime stores an nfunction in a slot typed by the C ABI, so putting one
//! there is a `@ptrCast`, and a cast accepts anything. `module.reg` checks the
//! shape at the registration, which is the last place the mistake can still be
//! diagnosed. Without it the wrong pointer surfaces as a crash inside the
//! interpreter with nothing naming the module.
//!
//! `build.zig`'s `module-errors` step compiles this and requires the failure.

const wattle = @import("wattle");

/// The C shape: a count and a pointer, returning a value with no way to
/// refuse. It is what a module author coming from a C API writes first.
fn oldShape(argc: i32, argv: [*]wattle.Value) wattle.Value {
    _ = argc;
    return argv[0];
}

fn defs(env: *wattle.Env) wattle.Error!void {
    wattle.nfuns(env, "wrong", &.{
        wattle.reg("identity", &oldShape, null, null),
    });
}

comptime {
    wattle.entry(defs);
}
