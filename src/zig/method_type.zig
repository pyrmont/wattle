//! A method table row, in the two declared forms it is reached by.
//!
//! A method table is an `abi.CFunction` stored somewhere else: a name and a
//! cfunction, terminated by a null name. Typing the table entry is what makes
//! a method's `try` a compile error to omit, exactly as `abstract_type.zig`
//! does for a finalizer and `callback_type.zig` for an event callback.
//!
//! The layout is one row in both forms -- a name and a pointer -- and the
//! pointer is the same pointer. What differs is the *declared* type of the
//! function it points at: `Method`'s is `raise.CFunction`, and `CMethod`'s is
//! the C-ABI `CFunction` the published method lookups have to take.
//!
//! There is no terminator constant: all twelve tables in the tree spell theirs
//! inline as `.{ .name = null, .cfun = null }`.

const abi = @import("abi");

/// `JanetMethod`, with the cfunction typed as raising.
///
/// The declaration is `abi.Method`, which `src/zig/module.zig` names as well:
/// a module author builds a method table with the same two fields and hands it
/// to the same two entry points, so the layout is agreed rather than declared
/// twice. This is the runtime's name for it, kept because nine subsystems
/// spell `method_type.Method`.
pub const Method = abi.Method;

/// The same row with the cfunction as the C ABI declares it.
///
/// `Method` above and this are one layout -- a name and a pointer -- and they
/// differ only in the *declared* type of the function the pointer names. This
/// is the arm for the places where that signature is fixed from outside:
/// `janet_getmethod` and `janet_nextmethod` take an array of these, and
/// `Stream.methods` points at one, because a caller that reached the runtime
/// through the C ABI cannot hold a `raise.CFunction`.
///
/// A method table written for a Zig caller uses `Method`. This one exists so
/// that the boundary's tables do not have to be cast at every read.
///
/// **Both are `extern`, and the assertion below is why that matters.** A
/// `[*]const Method` is `@ptrCast` to a `[*]const CMethod` at the two entry
/// points, so "one layout" has to be a guarantee rather than an observation:
/// an auto-layout struct may be reordered, and these two would then agree only
/// until a compiler release disagreed. `abi.Method` is `extern` because an
/// author's compilation and the runtime must lay it out the same way; this one
/// is `extern` so that the cast between them is sound by declaration.
pub const CMethod = extern struct {
    name: ?[*:0]const u8 = null,
    cfun: abi.CFunction = null,
};

comptime {
    if (@sizeOf(CMethod) != @sizeOf(Method) or
        @offsetOf(CMethod, "name") != @offsetOf(Method, "name") or
        @offsetOf(CMethod, "cfun") != @offsetOf(Method, "cfun"))
        @compileError("Method and CMethod are cast to each other and no longer share a layout");
}
