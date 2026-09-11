//! A payload the runtime's allocator cannot align, allocated.
//!
//! `janet_calloc` is `malloc`-backed, so the strictest alignment it promises
//! is `max_align_t`. `alloc` takes the payload type rather than returning a
//! `?*anyopaque`, so a request for more than that is refused at the call that
//! makes it. Given the opaque pointer an author would write the `@alignCast`
//! themselves, and nothing would check it.
//!
//! `build.zig`'s `module-errors` step compiles this and requires the failure.

const janet = @import("janet");

/// Over-aligned on purpose. A cache-line-aligned lane is the plausible way an
/// author arrives here: a reasonable thing to ask for, and still more than the
/// allocator can supply.
const Wide = struct {
    lane: f64 align(128),
};

fn make(argv: []janet.Value) janet.Error!janet.Value {
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
