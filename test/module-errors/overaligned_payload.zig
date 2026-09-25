//! A payload the runtime's allocator cannot align, allocated.
//!
//! `calloc` is `malloc`-backed, so the strictest alignment it promises
//! is `max_align_t`. `alloc` takes the payload type rather than returning a
//! `?*anyopaque`, so a request for more than that is refused at the call that
//! makes it. Given the opaque pointer an author would write the `@alignCast`
//! themselves, and nothing would check it.
//!
//! `build.zig`'s `module-errors` step compiles this and requires the failure.

const wattle = @import("wattle");

/// Over-aligned on purpose. A cache-line-aligned lane is the plausible way an
/// author arrives here: a reasonable thing to ask for, and still more than the
/// allocator can supply.
const Wide = struct {
    lane: f64 align(128),
};

fn make(argv: []wattle.Value) wattle.Error!wattle.Value {
    try wattle.fixarity(argv, 0);
    const lanes = wattle.alloc(Wide, 4) orelse return wattle.panic("out of memory");
    wattle.free(lanes);
    return wattle.nil();
}

fn defs(env: *wattle.Env) wattle.Error!void {
    wattle.nfuns(env, "overaligned", &.{
        wattle.reg("make", &make, null, null),
    });
}

comptime {
    wattle.entry(defs);
}
