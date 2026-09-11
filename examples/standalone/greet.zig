//! The smallest module that exercises the published interface.
//!
//! It has one import, one cfunction and one abstract type. That is enough
//! that the module would fail to compile if `janet` stopped offering
//! registration, the raising cfunction shape, or `janet.define`.
//!
//! `build.zig` in this directory builds it, and `zig build standalone` at
//! the repository root runs that build.

const janet = @import("janet");

/// A payload, so that `janet.define` is exercised rather than only
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
/// `janet.new`. It is declared at container level because the runtime keeps
/// this address and reads it again at teardown.
const greeting_type = janet.define(Greeting, .{
    .name = "standalone/greeting",
    .gc = greetingGc,
});

/// Returns a new greeting abstract with a `count` of 1. Implements
/// `(standalone/hello)`.
///
/// `argv` is empty, because this cfunction takes no arguments.
///
/// This function raises if the arity is wrong.
fn hello(argv: []janet.Value) janet.Error!janet.Value {
    try janet.fixarity(argv, 0);
    const g = janet.new(Greeting, &greeting_type, null);
    g.* = .{ .count = 1 };
    return janet.abstract(g);
}

/// Defines the module's one cfunction.
///
/// `env` is the capability to define a binding in the environment the module
/// is loading into. `janet.entry` below passes `defs` to the loader.
///
/// This function cannot raise.
fn defs(env: *janet.Env) janet.Error!void {
    janet.cfuns(env, "standalone", &.{
        janet.reg("hello", &hello, "(standalone/hello)\n\nAnswer a greeting."),
    });
}

comptime {
    janet.entry(defs);
}
