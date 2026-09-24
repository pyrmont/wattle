//! The arity refusal shared by the interpreter, its entry point and compiler.
//!
//! Callers supply the accepted bounds and the argument count. A compiler
//! check may know only a lower bound when the call contains a splice.
//! `mismatch` is out of line because the host call path reaches it only after
//! a frame refusal, and formatting it adds code to that call path if inlined.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const pp_format = @import("pp/format.zig");
const fibers = @import("value/fibers.zig");
const raise = @import("../api/raise.zig");
const repr = @import("repr");
const strings = @import("value/strings.zig");
const wrap = @import("value/helpers/wrap.zig");

// ==========================================================================
// Public functions
// ==========================================================================

/// Formats an arity refusal for `callee` with `got` arguments.
///
/// `at_least` marks a count inferred from a splice. `prefix` identifies the
/// compiler check, or is empty for a call. The largest signed integer as
/// `max` means the upper bound is unbounded.
///
/// This function raises if rendering `callee` raises.
pub fn format(
    callee: repr.Value,
    got: i64,
    at_least: bool,
    min: i32,
    max: i32,
    prefix: [*:0]const u8,
) raise.Error!strings.String {
    const plural: [*:0]const u8 = if (got == 1) "" else "s";
    const count = if (at_least)
        try pp_format.formatc("at least %d", .{got})
    else
        try pp_format.formatc("%d", .{got});
    if (min == max) {
        return pp_format.formatc("%s%v called with %s argument%s, expected %d", .{ prefix, callee, count, plural, min });
    }
    if (max == std.math.maxInt(i32)) {
        return pp_format.formatc("%s%v called with %s argument%s, expected at least %d", .{ prefix, callee, count, plural, min });
    }
    if (min > max) {
        return pp_format.formatc("%s%v called with %s argument%s, expected at most %d", .{ prefix, callee, count, plural, max });
    }
    return pp_format.formatc("%s%v called with %s argument%s, expected %d to %d", .{ prefix, callee, count, plural, min, max });
}

/// Raises an arity refusal for `callee` with `got` arguments.
///
/// `callee` must be a function whose frame check has already refused `got`.
pub noinline fn mismatch(callee: repr.Value, got: usize) raise.Error {
    const definition = wrap.toFunction(callee).def.?;
    const message = format(callee, @intCast(got), false, definition.min_arity, definition.max_arity, "") catch |err| return err;
    return raise.panicv(wrap.fromString(message));
}

/// Raises the refusal for an invalid map tail in `fiber`'s pending call.
pub noinline fn mapTailMismatch(callee: repr.Value, fiber: *fibers.Fiber) raise.Error {
    const refusal = fibers.pendingMapTailRefusal(fiber, wrap.toFunction(callee)).?;
    const message = formatMapTail(callee, refusal) catch |err| return err;
    return raise.panicv(wrap.fromString(message));
}

/// Formats a refused map tail for `callee`.
pub fn formatMapTail(callee: repr.Value, refusal: fibers.MapTailRefusal) raise.Error!strings.String {
    return switch (refusal) {
        .missing_value => |key| pp_format.formatc("%v called with no value for key %v", .{ callee, key }),
        .invalid_key => |key| pp_format.formatc("%v called with key %v, which a map cannot hold", .{ callee, key }),
    };
}
