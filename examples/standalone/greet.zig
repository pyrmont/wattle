//! The smallest module that exercises the published interface.
//!
//! One import, one cfunction, one abstract type -- enough that the module
//! would fail to compile if `janet` stopped offering registration, the
//! raising cfunction shape, or `define`.

const janet = @import("janet");

/// A payload, so that `define` is exercised and not merely available.
const Greeting = struct {
    count: i32,
};

fn greetingGc(_: *Greeting, _: usize) c_int {
    return 0;
}

/// Declared at container level, which `define`'s documentation requires: the
/// runtime keeps this address and reads it again at teardown.
const greeting_type = janet.define(Greeting, .{
    .name = "standalone/greeting",
    .gc = greetingGc,
});

fn hello(argv: []janet.Value) align(janet.fn_align) janet.Error!janet.Value {
    try janet.fixarity(argv, 0);
    const g = janet.new(Greeting, &greeting_type, null);
    g.* = .{ .count = 1 };
    return janet.abstract(g);
}

fn defs(env: *janet.Env) void {
    janet.cfuns(env, "standalone", &.{
        janet.reg("hello", &hello, "(standalone/hello)\n\nAnswer a greeting."),
    });
}

comptime {
    janet.entry(defs);
}
