//! The two ways this runtime gives up.
//!
//! Both are `noreturn`, and that is the whole of their contract: a caller may
//! not carry on. Both write to `stdio.err()`, which names the handle on every
//! target, and neither is overridable -- upstream Janet lets an embedder
//! redefine `JANET_OUT_OF_MEMORY`, which is a preprocessor facility with
//! nothing behind it here.

const std = @import("std");
const stdio = @import("stdio.zig");
const c = @import("cabi");

fn write(text: []const u8) void {
    _ = c.fwrite(text.ptr, 1, text.len, stdio.err());
}

/// `JANET_OUT_OF_MEMORY` followed by `c.abort`. The C macro ends the process with
/// `exit(1)` and then the C function aborted anyway, so the abort is what
/// callers actually got and it is what happens here.
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
