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
const c = abi.c;

pub const mcall = c.janet_mcall;
pub const callNonfn = c.janet_call_nonfn;
pub const resolveMethod = c.janet_resolve_method;
pub const unaryCall = c.janet_unary_call;
pub const binopCall = c.janet_binop_call;
pub const fillTable = c.janet_fill_table;
pub const fillStruct = c.janet_fill_struct;
pub const fillString = c.janet_fill_string;
