//! The bindings of a runtime built without the compiler and the parser.
//!
//! A runtime built with `-Dwasm-image` does not compile `compiler.zig` or
//! `parser.zig`. The core image it loads still names `compile` and the
//! `parser/` functions, because the bootstrap that made it had both and the
//! image refers to an nfunction by name. This file registers an nfunction under
//! each of those names, so the image loads. Calling one raises an error.
//!
//! `env.zig` installs these rows in place of `libCompile` and `libParse`, and
//! its `dobytesImpl` reports the same condition for source text.

// ==========================================================================
// Project imports
// ==========================================================================

const corefn = @import("corefn.zig");
const raise = @import("../api/raise.zig");
const repr = @import("repr");
const tables = @import("value/tables.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// The message every stub raises, and the message `dobytesImpl` prints.
pub const message = "this runtime has no compiler or parser; it can only load an image";

// ==========================================================================
// Public functions
// ==========================================================================

/// Registers a stub under the name of `compile` and of each `parser/` function.
///
/// `env` is the core lookup dictionary. The runtime puts the nfunctions there
/// and the image supplies the bindings, so the rows carry no docstring.
pub fn lib(env: *tables.Table) void {
    const entries = comptime [_]corefn.Entry{
        corefn.reg("compile", &unavailable, @src(), "(compile ast)", "Raises an error in a build without the compiler."),
        corefn.reg("parser/byte", &unavailable, @src(), "(parser/byte parser b)", "Raises an error in a build without the parser."),
        corefn.reg("parser/clone", &unavailable, @src(), "(parser/clone parser)", "Raises an error in a build without the parser."),
        corefn.reg("parser/consume", &unavailable, @src(), "(parser/consume parser bytes)", "Raises an error in a build without the parser."),
        corefn.reg("parser/eof", &unavailable, @src(), "(parser/eof parser)", "Raises an error in a build without the parser."),
        corefn.reg("parser/error", &unavailable, @src(), "(parser/error parser)", "Raises an error in a build without the parser."),
        corefn.reg("parser/flush", &unavailable, @src(), "(parser/flush parser)", "Raises an error in a build without the parser."),
        corefn.reg("parser/has-more", &unavailable, @src(), "(parser/has-more parser)", "Raises an error in a build without the parser."),
        corefn.reg("parser/insert", &unavailable, @src(), "(parser/insert parser val)", "Raises an error in a build without the parser."),
        corefn.reg("parser/new", &unavailable, @src(), "(parser/new)", "Raises an error in a build without the parser."),
        corefn.reg("parser/produce", &unavailable, @src(), "(parser/produce parser)", "Raises an error in a build without the parser."),
        corefn.reg("parser/state", &unavailable, @src(), "(parser/state parser)", "Raises an error in a build without the parser."),
        corefn.reg("parser/status", &unavailable, @src(), "(parser/status parser)", "Raises an error in a build without the parser."),
        corefn.reg("parser/where", &unavailable, @src(), "(parser/where parser)", "Raises an error in a build without the parser."),
    };
    corefn.install(env, entries);
}

// ==========================================================================
// Private functions
// ==========================================================================

/// The implementation of every stub. It ignores `argv` and raises `message`.
fn unavailable(argv: []repr.Value) raise.Error!repr.Value {
    _ = argv;
    return raise.panic(message);
}
