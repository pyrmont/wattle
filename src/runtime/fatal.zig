//! The two ways this runtime gives up.
//!
//! Both are `noreturn`, and that is the whole of their contract: a caller may
//! not carry on. Both write to `stdio.err()`, which names the handle on every
//! target, and neither is overridable: there is no preprocessor for an
//! embedder to redefine one through.

const std = @import("std");
const stdio = @import("stdio.zig");
const c = @import("cabi");

fn write(text: []const u8) void {
    _ = c.fwrite(text.ptr, 1, text.len, stdio.err());
}

/// Report the failure and `c.abort`. **The abort is the contract**: a caller
/// that runs out of memory does not return, and does not get a chance to
/// unwind either.
pub fn outOfMemory() noreturn {
    write("janet out of memory\n");
    c.abort();
}

/// An invariant this runtime does not know how to continue past.
pub fn fatal(message: [*:0]const u8) noreturn {
    write("janet abort: ");
    write(std.mem.span(message));
    write("\n");
    c.abort();
}
