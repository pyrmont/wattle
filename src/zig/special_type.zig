//! `JanetSpecial`, with its one callback typed as raising.
//!
//! Phase 10's hinge, and the last of the four fixed function-pointer tables
//! this phase retypes — `JanetCFunction` in Part 17g, `JanetAbstractType` and
//! `JanetEVCallback` in the hinge, and this. It is the smallest of them and
//! the one that says the rule most plainly: **a compiler special is a second
//! `JanetCFunction`.** Thirteen forms behind one signature, dispatched from
//! one place, and until the type changed no special could return an error
//! because the table would not hold one.
//!
//! `compile.h` fixes that signature at
//! `JanetSlot (*)(JanetFopts, int32_t, const Janet *)`, and eight of the
//! thirteen specials raise — `set` on an unknown binding, `def` on a bad
//! head, `fn` on a malformed parameter list. Each kept an abi that jumped.
//!
//! The layout is `compile.h`'s exactly, so `janetc_special` still answers a
//! `const JanetSpecial *` and `compile.c` under `-Dcompiler-primitives=c` is
//! unaffected: what it needs is a name and a pointer, which is storage rather
//! than a calling convention. `abstract_type.zig` draws the same line and
//! records the argument.

const raise = @import("raise");
const types = @import("types");
const c = @import("cabi");

/// What a compiler special is, since the hinge.
pub const Special = extern struct {
    name: [*:0]const u8,
    compile: ?*const fn (types.JanetFopts, i32, [*]const types.Janet) raise.Error!types.JanetSlot = null,
};

comptime {
    if (@sizeOf(Special) != @sizeOf(types.JanetSpecial)) {
        @compileError("special.Special has drifted from compile.h's layout");
    }
}

/// A special read out of the storage `compile.h` still describes — what
/// `janetc_special` answered. The pointer is the same pointer.
pub inline fn of(slot: ?*const types.JanetSpecial) *const Special {
    return @ptrCast(@alignCast(slot.?));
}

/// The same pointer on its way back into that storage.
pub inline fn stored(s: *const Special) ?*const types.JanetSpecial {
    return @ptrCast(s);
}
