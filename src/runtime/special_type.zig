//! `Special`, the compiler's special-form table row.
//!
//! A special form is one row of a table the compiler dispatches through, in
//! the way a method table's row is: a name beside a raising callback. Typing
//! the callback as raising is what lets a special return an error at all.
//!
//! `compiler/specials.zig` declares the one table, thirteen rows in
//! lexicographic order, and `compiler.zig` reaches it by name.

// ==========================================================================
// Project imports
// ==========================================================================

const compiler = @import("compiler.zig");
const raise = @import("../api/raise.zig");
const repr = @import("repr");

// ==========================================================================
// Types
// ==========================================================================

/// What a compiler special is: a name and the raising function that compiles
/// the form's arguments.
///
/// `compile` takes the form's arguments as a slice, because what it is given
/// is one tuple's tail, and returns the slot the form's value is in.
pub const Special = struct {
    name: [*:0]const u8,
    compile: ?*const fn (compiler.FormOptions, []const repr.Value) raise.Error!compiler.Slot = null,
};
