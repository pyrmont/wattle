//! The line editor's module root.
//!
//! `build.zig` builds a module named `lineedit` from this file, which
//! `res/tools/layout.zig` imports and the `test/lineedit` step tests. None of
//! these files imports the runtime, so they compile and are tested without
//! one. The client does not import the editor yet.

// ==========================================================================
// Project imports
// ==========================================================================

pub const layout = @import("lineedit/layout.zig");
pub const picture = @import("lineedit/picture.zig");
pub const rune = @import("lineedit/rune.zig");

// ==========================================================================
// Tests
// ==========================================================================

comptime {
    // A `test` block is collected only from a file that the test root
    // references, so each file is named here.
    _ = layout;
    _ = picture;
    _ = rune;
}
