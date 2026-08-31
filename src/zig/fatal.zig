//! The two ways this runtime gives up, and the last two symbols
//! a C bridge defined.
//!
//! They were C because `JANET_OUT_OF_MEMORY` is a macro an embedder may
//! override in `janet.h` and because both wanted `stderr`, which nothing in
//! Zig could name until `stdio.zig`. Neither reason survives: the override is
//! a preprocessor facility no Zig caller could ever have seen -- the same
//! thing `io_core.zig` records about `JANET_EXIT` -- and `stdio.err()` names
//! the handle on every target.
//!
//! Both are `noreturn`, and that is the whole of their contract: a caller may
//! not carry on. The location reported is this file's rather than
//! `runtime_bridge.c`'s, which is the same difference `io_core.zig`'s
//! `exitWith` already records.

const std = @import("std");
const stdio = @import("stdio.zig");

extern fn abort() callconv(.c) noreturn;
extern fn fwrite(ptr: [*]const u8, size: usize, n: usize, stream: ?*anyopaque) callconv(.c) usize;

fn write(text: []const u8) void {
    _ = fwrite(text.ptr, 1, text.len, stdio.err());
}

/// `JANET_OUT_OF_MEMORY` followed by `abort`. The C macro ends the process with
/// `exit(1)` and then the C function aborted anyway, so the abort is what
/// callers actually got and it is what happens here.
pub fn outOfMemory() noreturn {
    write("janet out of memory\n");
    abort();
}

/// An invariant this runtime does not know how to continue past.
pub fn fatal(message: [*:0]const u8) noreturn {
    write("janet abort: ");
    write(std.mem.span(message));
    write("\n");
    abort();
}
