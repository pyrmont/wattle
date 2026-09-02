//! A dynamically loaded Janet module written in Zig: the proof that a `.so`
//! outside the runtime can define a builtin.
//!
//! It is written against the published interface: it imports `janet` and
//! nothing else, which is what makes it a proof of the thing a module author
//! actually uses. Reaching past that interface for the runtime's own
//! declarations would prove something else.
//!
//! `examples/numarray/numarray.zig` is the worked example; this is the
//! smallest possible module and exists to be loaded by a contract.

const janet = @import("janet");

fn identity(argv: []janet.Value) align(janet.fn_align) janet.Error!janet.Value {
    try janet.fixarity(argv, 1);
    return argv[0];
}

fn defs(env: *janet.Env) void {
    janet.cfuns(env, "zig-native", &.{
        janet.reg(
            "identity",
            &identity,
            "(identity x)\n\nRound-trip a Janet value through a dynamically loaded Zig module.",
        ),
    });
}

comptime {
    janet.entry(defs);
}
