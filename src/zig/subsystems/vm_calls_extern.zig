//! `vm_calls.zig`'s interface, resolved to the C symbols instead of the Zig
//! bodies. `build.zig` puts this behind `vm_run.zig`'s `vm_calls` import when
//! `-Dvm-calls=c`.
//!
//! It exists so that the two selectors stay independent after Part 3 folded
//! Part 2's helpers into the loop's object. Without it, `-Dvm-calls=c` would
//! silently keep answering with Zig for every call the interpreter makes, which
//! is the one thing a differential selector may not do. The names are
//! `vm_calls.zig`'s rather than `state.h`'s, because the importer should not
//! have to know which side it is talking to.
//!
//! Everything here is a call across a translation-unit boundary, which is
//! exactly the 2.4-3.4% Part 2 measured on method dispatch. That is the cost of
//! asking a C-selected callee layer to answer for a Zig loop, and it is charged
//! to the selector rather than to the port.

const abi = @import("abi");
const raise = @import("raise");
const vm_calls = @import("vm_calls.zig");
const c = abi.c;

// The panicking faces. These are what the C originals *are*: they raise from
// the inside by jumping, so the Zig loop that calls them is jumped through
// rather than returned to. `vm_run.zig` reaches them through `scoped`.
pub const mcallPanicking = c.janet_mcall;
pub const callNonfnPanicking = c.janet_call_nonfn;
pub const resolveMethodPanicking = c.janet_resolve_method;
pub const unaryCallPanicking = c.janet_unary_call;
pub const binopCallPanicking = c.janet_binop_call;
pub const fillTable = c.janet_fill_table;
pub const fillStruct = c.janet_fill_struct;
pub const fillString = c.janet_fill_string;

// The error-returning faces, for a converted caller. Under this selector they
// are the panicking symbols wearing the Zig signature: the C body jumps, so the
// error is never actually returned, and a caller written to `try` them still
// compiles and still behaves exactly as it does today. That is what keeps
// `-Dvm-calls=c` a selector rather than a second dialect the loop has to know
// about. `raise.Error` appears in the signature and never in the value.
pub inline fn mcall(name: [*c]const u8, argc: i32, argv: [*c]c.Janet) raise.Error!c.Janet {
    return try vm_calls.mcall(name, argc, argv);
}
pub inline fn callNonfn(fiber: [*c]c.JanetFiber, callee: c.Janet) raise.Error!c.Janet {
    return try vm_calls.callNonfn(fiber, callee);
}
pub inline fn resolveMethod(name: c.Janet, fiber: [*c]c.JanetFiber) raise.Error!c.Janet {
    return try vm_calls.resolveMethod(name, fiber);
}
pub inline fn unaryCall(method: [*c]const u8, arg: c.Janet) raise.Error!c.Janet {
    return try vm_calls.unaryCall(method, arg);
}
pub inline fn binopCall(lmethod: [*c]const u8, rmethod: [*c]const u8, lhs: c.Janet, rhs: c.Janet) raise.Error!c.Janet {
    return try vm_calls.binopCall(lmethod, rmethod, lhs, rhs);
}
