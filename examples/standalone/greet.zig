//! The smallest module that exercises the published interface.
//!
//! It has one import, one nfunction and one abstract type. That is enough
//! that the module would fail to compile if `wattle` stopped offering
//! registration, the raising nfunction shape, or `wattle.define`.
//!
//! `build.zig` in this directory builds it, and `zig build examples/standalone` at
//! the repository root runs that build.

const wattle = @import("wattle");

/// A payload, so that `wattle.define` is exercised rather than only
/// available.
///
/// `greeting_type` names this type and `greetingGc` is written over it.
/// `count` is the only field, and `hello` is the only writer.
const Greeting = struct {
    count: i32,
};

/// Frees nothing. Implements the `gc` callback.
///
/// This function cannot raise.
///
/// A `Greeting` has no allocation of its own, so there is nothing to free.
fn greetingGc(_: *Greeting, _: usize) void {}

/// The `standalone/greeting` abstract type, which `hello` passes to
/// `wattle.new`. It is declared at container level because the runtime keeps
/// this address and reads it again at teardown.
const greeting_type = wattle.define(Greeting, .{
    .name = "standalone/greeting",
    .gc = greetingGc,
});

/// Returns a new greeting abstract with a `count` of 1. Implements
/// `(standalone/hello)`.
///
/// `argv` is empty, because this nfunction takes no arguments.
///
/// This function raises if the arity is wrong.
fn hello(argv: []wattle.Value) wattle.Error!wattle.Value {
    try wattle.fixarity(argv, 0);
    const g = wattle.new(Greeting, &greeting_type, null);
    g.* = .{ .count = 1 };
    return wattle.abstract(g);
}

/// Defines the module's one nfunction.
///
/// `env` is the capability to define a binding in the environment the module
/// is loading into. `wattle.entry` below passes `defs` to the loader.
///
/// This function cannot raise.
fn defs(env: *wattle.Env) wattle.Error!void {
    wattle.nfuns(env, "standalone", &.{
        wattle.reg("hello", &hello, "(standalone/hello)\n\nAnswer a greeting."),
    });
}

comptime {
    wattle.entry(defs);
}
