//! The line editor's module root.
//!
//! `build.zig` builds a module named `lineedit` from this file, which the
//! client and `res/tools/layout.zig` import and the `test/lineedit` step
//! tests. None of these files imports the runtime or reads or writes the
//! terminal, so they compile and are tested without either.
//! `src/client/prompt.zig` is what connects a `session.Session` to both.

// ==========================================================================
// Project imports
// ==========================================================================

pub const editor = @import("lineedit/editor.zig");
pub const history = @import("lineedit/history.zig");
pub const keys = @import("lineedit/keys.zig");
pub const layout = @import("lineedit/layout.zig");
pub const picture = @import("lineedit/picture.zig");
pub const render = @import("lineedit/render.zig");
pub const rune = @import("lineedit/rune.zig");
pub const session = @import("lineedit/session.zig");

// ==========================================================================
// Tests
// ==========================================================================

comptime {
    // A `test` block is collected only from a file that the test root
    // references, so each file is named here.
    _ = editor;
    _ = history;
    _ = keys;
    _ = layout;
    _ = picture;
    _ = render;
    _ = rune;
    _ = session;
}
