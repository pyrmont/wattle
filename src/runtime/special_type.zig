//! `Special`, the compiler's special-form table row.
//!
//! **A compiler special is a second `abi.CFunction`**: thirteen forms behind
//! one signature, dispatched from one place. Typing the callback as raising is
//! what lets a special return an error at all.
//!
//! The callback takes a slice, because what it is given is one tuple's tail.

const raise = @import("../api/raise.zig");
const repr = @import("repr");
const compiler = @import("compiler.zig");

/// What a compiler special is: a name and the raising function that compiles
/// the form's arguments.
pub const Special = struct {
    name: [*:0]const u8,
    compile: ?*const fn (compiler.FormOptions, []const repr.Value) raise.Error!compiler.Slot = null,
};
