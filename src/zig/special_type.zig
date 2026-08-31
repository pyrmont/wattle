//! `Special`, the compiler's special-form table row.
//!
//! **A compiler special is a second `JanetCFunction`**: thirteen forms behind
//! one signature, dispatched from one place. Typing the callback as raising is
//! what lets a special return an error at all -- the last of the four fixed
//! function-pointer tables to be typed, after the cfunction, the abstract type
//! and the event callback.
//!
//! **There were two descriptions of this row**, and the reason for the second
//! was a C header that fixed the signature at
//! `JanetSlot (*)(JanetFopts, int32_t, const Janet *)` and made the layout a
//! contract with a C implementation of the same table. With both gone, what
//! was left was a second struct, a `@sizeOf` check holding the two together,
//! and a pair of casts between them. `janetc_special` is not exported, so
//! nothing outside this tree can hold one either.
//!
//! The callback takes a slice, because the count and the pointer were always
//! one tuple's tail.

const raise = @import("raise");
const types = @import("types");
const repr = @import("repr");

/// What a compiler special is: a name and the raising function that compiles
/// the form's arguments.
pub const Special = struct {
    name: [*:0]const u8,
    compile: ?*const fn (types.JanetFopts, []const repr.Value) raise.Error!types.JanetSlot = null,
};
