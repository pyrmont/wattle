//! `fiber_core.zig`'s raise-capable interface, resolved to the C symbols
//! instead of the Zig bodies. `vm_run.zig` and `vm_entry.zig` reach this
//! instead of the subsystem when `-Dfiber-core=c`.
//!
//! It exists for the reason `vm_calls_extern.zig` exists, and Phase 10 Part 17a
//! is where the fiber layer acquired the same need: the four pushes now raise
//! by returning, and a caller written to `try` them must go on compiling when
//! the selector answers with `fiber.c` instead. Under this selector the error
//! is declared and never returned — the C body raises from the inside by
//! jumping, so the Zig frame that called it is jumped through rather than
//! returned to. `raise.Error` appears in the signature and never in the value.
//!
//! That is what keeps `-Dfiber-core=c` a selector rather than a second dialect
//! its callers have to know about, and it is why the file carries the marker:
//! every call here can be jumped out of.

const abi = @import("abi");
const raise = @import("raise");
const fiber_core = @import("fiber_core.zig");
const c = abi.c;

pub inline fn push(fiber: *c.JanetFiber, x: c.Janet) raise.Error!void {
    try fiber_core.push(fiber, x);
}

pub inline fn push2(fiber: *c.JanetFiber, x: c.Janet, y: c.Janet) raise.Error!void {
    try fiber_core.push2(fiber, x, y);
}

pub inline fn push3(fiber: *c.JanetFiber, x: c.Janet, y: c.Janet, z: c.Janet) raise.Error!void {
    try fiber_core.push3(fiber, x, y, z);
}

pub inline fn pushn(fiber: *c.JanetFiber, arr: [*c]const c.Janet, n: i32) raise.Error!void {
    try fiber_core.pushn(fiber, arr, n);
}
