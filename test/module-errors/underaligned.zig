//! A cfunction aligned to less than the runtime needs.
//!
//! The runtime tags the low bits of a cfunction's address, so `module.fn_align`
//! is a requirement rather than a suggestion -- and the expected-signature text
//! has always said so. Nothing checked it: `raise.stored` casts the pointer
//! into the runtime's slot, and an under-aligned function then either survives
//! by an accident of the linker or trips a runtime assertion a long way from
//! the definition that caused it.
//!
//! `build.zig`'s `module-errors` step compiles this and requires the failure.

const janet = @import("janet");

/// Everything right except the alignment.
fn cramped(argv: []janet.Value) align(1) janet.Error!janet.Value {
    return argv[0];
}

fn defs(env: *janet.Env) void {
    janet.cfuns(env, "cramped", &.{
        janet.reg("cramped", &cramped, null),
    });
}

comptime {
    janet.entry(defs);
}
