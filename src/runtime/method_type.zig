//! A method table row.
//!
//! A method table is an array of rows, a name beside an nfunction, terminated
//! by a row whose name is null. The nfunction is the stored form that
//! `raise.stored` builds, so a method that raises is written with `try` and the
//! row holds the C-ABI function that calls it.
//!
//! There is no terminator constant. A table spells its own, inline, as
//! `.{ .name = null, .nfun = null }`.

// ==========================================================================
// Project imports
// ==========================================================================

const module = @import("../module.zig");

// ==========================================================================
// Aliased types
// ==========================================================================

/// A method table's row.
///
/// The declaration is `module.Method`: a module author builds a method table
/// with the same two fields and passes it to the same two entry points, so the
/// layout is agreed rather than declared twice. This is the runtime's name for
/// the same type.
pub const Method = module.Method;
