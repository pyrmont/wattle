//! A cfunction aligned to less than the runtime needs.
//!
//! The runtime tags the low bits of a cfunction's address, so
//! `module.fn_align` is a requirement rather than a suggestion. `raise.stored`
//! casts the pointer into the runtime's slot and cannot refuse it there, so an
//! under-aligned function either survives by an accident of the linker or
//! trips a runtime assertion a long way from the definition that caused it.
//! The alignment is checked at the definition instead.
//!
//! `build.zig`'s `module-errors` step compiles this and requires the failure.

const janet = @import("janet");

/// Everything right except the alignment.
fn cramped(argv: []janet.Value) align(1) janet.Error!janet.Value {
    return argv[0];
}

fn defs(env: *janet.Env) janet.Error!void {
    janet.cfuns(env, "cramped", &.{
        janet.reg("cramped", &cramped, null),
    });
}

comptime {
    janet.entry(defs);
}
