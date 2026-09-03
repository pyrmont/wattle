//! A payload the runtime's allocator cannot align, allocated.
//!
//! `janet_calloc` is `malloc`-backed, so the strictest alignment it promises
//! is `max_align_t`. While `alloc` answered `?*anyopaque`, an author asking
//! for more wrote the `@alignCast` at their own call site -- an assumption
//! nothing checked, and undefined behaviour with no diagnostic anywhere.
//! `alloc` takes the type instead, so the assumption is checked where it is
//! made.
//!
//! `build.zig`'s `module-errors` step compiles this and requires the failure.

const janet = @import("janet");

/// Over-aligned on purpose. A cache-line-aligned lane is the plausible way an
/// author arrives here: it is a reasonable thing to want and the allocator
/// still cannot supply it.
const Wide = struct {
    lane: f64 align(128),
};

fn make(argv: []janet.Value) align(janet.fn_align) janet.Error!janet.Value {
    try janet.fixarity(argv, 0);
    const lanes = janet.alloc(Wide, 4) orelse return janet.panic("out of memory");
    janet.free(lanes);
    return janet.nil();
}

fn defs(env: *janet.Env) janet.Error!void {
    janet.cfuns(env, "overaligned", &.{
        janet.reg("make", &make, null),
    });
}

comptime {
    janet.entry(defs);
}
