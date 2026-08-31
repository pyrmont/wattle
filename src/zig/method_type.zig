//! `JanetMethod`, with its cfunction typed as raising.
//!
//! A method table is a `JanetCFunction` stored somewhere else: a name and a
//! cfunction, terminated by a null name. Typing the table entry is what makes
//! a method's `try` a compile error to omit, exactly as `abstract_type.zig`
//! does for a finalizer and `callback_type.zig` for an event callback.
//!
//! The layout is Janet's exactly -- a name and a pointer -- and the pointer is
//! the same pointer. What differs is the *declared* type of the function it
//! points at, which is `raise.CFunction` rather than
//! table is. Where one of these arrays meets a signature C still declares --
//! `janet_getmethod`, `janet_nextmethod`, `JanetStream.methods` -- it is cast,
//! because a layout is all those need.
//!
//! ## Why this is its own file
//!
//! It stood in `corefn.zig`, which registers core cfunctions and does not use
//! it: nine subsystems declare a method table and none of them reached the
//! type through the registration layer for a reason. Splitting it out leaves
//! that layer alone and puts the fourth retyped table beside the other three,
//! where the suffix is what makes them read as a family.
//!
//! `method_end` did not come with it. It was
//! `JANET_REG_END` for a method table and nothing had ever referenced it: all
//! twelve tables in the tree spell their terminator inline as
//! `.{ .name = null, .cfun = null }`.

const raise = @import("raise");

/// `JanetMethod`, with the cfunction typed as raising.
pub const Method = extern struct {
    name: ?[*:0]const u8,
    cfun: ?raise.CFunction,
};
