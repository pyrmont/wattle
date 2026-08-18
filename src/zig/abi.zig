/// The single translation of Janet's C headers. Every Zig subsystem shares it,
/// so that a `JanetFiber *` produced by one is the same Zig type as a
/// `JanetFiber *` consumed by another; two `@cImport` blocks over the same
/// header produce distinct, incompatible types.
///
/// `state_abi.h` comes first because it includes `features.h`, which has to
/// precede every system header. `fiber.h` and `gc.h` join it as internal core
/// headers on the same footing as `state.h`: from Phase 7 onward the ports are
/// runtime-core work, so the private declarations those three carry are the
/// intended interface rather than a layout leak. `gc.h` arrived with Phase 8
/// Part 3, which needs `enum JanetMemoryType` to tell the two heap lists apart;
/// the function-like macros it defines over `JanetGCObject` do not survive
/// translation and are written out in Zig where they are used.
///
/// `util.h` is deliberately *not* here, and adding it breaks the Windows
/// cross-compile for every subsystem at once. Its dynamic-library section falls
/// through to `#include <dlfcn.h>` unless `JANET_WINDOWS` is defined, and that
/// macro is not set in the translation, so a header with nothing to do with the
/// port fails the import that every Zig object shares. A subsystem that needs
/// one of `util.h`'s functions declares it directly; they take primitive
/// parameters, so no Janet type crosses and the single-translation rule is not
/// at stake.
pub const c = @cImport({
    @cInclude("state_abi.h");
    @cInclude("fiber.h");
    @cInclude("gc.h");
    @cInclude("interop.h");
    @cInclude("runtime.h");
});
