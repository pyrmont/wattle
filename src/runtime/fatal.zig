//! The two ways this runtime gives up.
//!
//! Both are `noreturn`, and that is the whole of their contract: a caller may
//! not continue. Both write to `stdio.err()`, which names the handle on every
//! target, and neither is overridable, because there is no preprocessor for an
//! embedder to redefine one through.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const c = @import("cabi");
const stdio = @import("stdio.zig");

// ==========================================================================
// Public functions
// ==========================================================================

/// Reports an invariant this runtime has no way to continue past, and
/// aborts.
///
/// `message` is written after `janet abort: `. This function does not return.
pub fn fatal(message: [*:0]const u8) noreturn {
    write("janet abort: ");
    write(std.mem.span(message));
    write("\n");
    c.abort();
}

/// Reports an allocation failure and aborts.
///
/// The abort is the contract: a caller that runs out of memory does not
/// return, and does not get a chance to unwind either. This function does not
/// return.
pub fn outOfMemory() noreturn {
    write("janet out of memory\n");
    c.abort();
}

// ==========================================================================
// Private functions
// ==========================================================================

/// Writes `text` to standard error.
///
/// `fatal` and `outOfMemory` are the callers. Nothing here checks the result:
/// both are already giving up.
fn write(text: []const u8) void {
    _ = c.fwrite(text.ptr, 1, text.len, stdio.err());
}
