//! `JanetAbstractType`, with the callbacks that can raise typed as raising.
//!
//! Phase 10 Part 17h/17i. This is the same change Part 17g made to
//! `JanetCFunction`, applied to the other table of function pointers the
//! runtime dispatches through. Seven of the fifteen callbacks can raise —
//! `gc`, `gcmark`, `get`, `put`, `marshal`, `unmarshal`, `tostring`, `next`,
//! `call` and `length` between them cover every one the census found — and
//! until this part each of them delivered by `longjmp`, because
//! `janet.h`'s declaration fixes a C signature and a C signature has no error
//! channel.
//!
//! ## Why a mirror rather than an edit to `janet.h`
//!
//! The layout is `janet.h`'s exactly: same fields, same order, same widths, so
//! `@ptrCast` bridges the two and C code that only *stores* an abstract type —
//! or compares its address, which `marsh.c` does — is unaffected. What differs
//! is the declared type of the functions the pointers point at. That is the
//! same division Part 17g drew for `method_type.Method`: the C ABI is a layout, and
//! a layout is all the remaining C needs.
//!
//! ## The six that stay C, and why `gc` and `gcmark` are among them
//!
//! `compare`, `hash`, `bytes` and `gcperthread` cannot raise in any
//! implementation in the tree, and none of them is reached from a path that
//! could grow one: `compare` and `hash` are called from `value_order.zig`
//! inside comparisons that must be total. They keep the C convention so that
//! the difference is visible rather than uniform-and-meaningless — Phase 10's
//! rule 4, which governs an implementation's signature, against rule 12, which
//! governs a type something else fixes. Here nothing else fixes them.
//!
//! **`gc` and `gcmark` joined them in the hinge, and that is a contract rather
//! than a measurement.** The hinge first typed all ten raising callbacks
//! alike, which left three jump sites the collector could not do anything
//! with. The reason they could not is not that the tree happens to have no
//! raising finalizer — it is *when the collector calls them*:
//!
//! > A finalizer runs mid-sweep on an object that is already unreachable, and
//! > `gcmark` runs mid-traversal. There is no scope above either, no caller
//! > that could act on an error, and nothing to retry.
//!
//! So a raise from one has nowhere to go **for anybody**, including a native
//! module. `FOUND.md`'s "A panicking finalizer poisons the heap and kills the
//! process at deinit" is what C's attempt to allow it costs: the block is
//! finalized but neither freed nor unlinked, every later sweep finalizes it
//! again, and `janet_deinit` eventually exits the process.
//!
//! Typing them non-raising is what turns that into a **compile error at the
//! callback's own definition**, which is the only place the diagnosis is
//! cheap. It takes nothing away: both already return `c_int`, and
//! `janet.h`'s own call site is
//! `janet_assert(!head->type->gc(...), "finalizer failed")` — so the intended
//! failure channel was always a nonzero return, never a panic.
//!
//! Measured before deciding: of the sixteen `gc` and `gcmark` implementations
//! in the tree, **fifteen never raised**, and the one that did — `streamGC`,
//! through `closeImplHandle` to the backend's `unregister` — was reporting a
//! failed `epoll_ctl`/`kevent` from inside the collector, where no caller
//! could have acted on it either.
//!
//! The other five stay raising and should: `get`, `put`, `next`, `call` and
//! `tostring` run inside an interpreter frame with a real scope above them,
//! and a module author reporting an error from one is ordinary.

const std = @import("std");
const raise = @import("raise");
const types = @import("types");
const c = @import("cabi");

pub const AbstractType = extern struct {
    name: [*:0]const u8,
    gc: ?*const fn (?*anyopaque, usize) callconv(.c) c_int = null,
    gcmark: ?*const fn (?*anyopaque, usize) callconv(.c) c_int = null,
    get: ?*const fn (?*anyopaque, types.Janet, *types.Janet) raise.Error!c_int = null,
    put: ?*const fn (?*anyopaque, types.Janet, types.Janet) raise.Error!void = null,
    marshal: ?*const fn (?*anyopaque, *types.JanetMarshalContext) raise.Error!void = null,
    unmarshal: ?*const fn (*types.JanetMarshalContext) raise.Error!?*anyopaque = null,
    tostring: ?*const fn (?*anyopaque, *types.JanetBuffer) raise.Error!void = null,
    compare: ?*const fn (?*anyopaque, ?*anyopaque) callconv(.c) c_int = null,
    hash: ?*const fn (?*anyopaque, usize) callconv(.c) i32 = null,
    next: ?*const fn (?*anyopaque, types.Janet) raise.Error!types.Janet = null,
    call: ?*const fn (?*anyopaque, i32, [*]types.Janet) raise.Error!types.Janet = null,
    length: ?*const fn (?*anyopaque, usize) raise.Error!usize = null,
    bytes: ?*const fn (?*anyopaque, usize) callconv(.c) types.JanetByteView = null,
    gcperthread: ?*const fn (?*anyopaque, usize) callconv(.c) c_int = null,
};

comptime {
    if (@sizeOf(AbstractType) != @sizeOf(types.JanetAbstractType)) {
        @compileError("abstract_type.AbstractType has drifted from janet.h's layout");
    }
    // Field by field, because the size alone does not say it.
    //
    // Every callback here is pointer-sized, so a field *inserted* into one
    // mirror and *removed* from the other leaves `@sizeOf` unmoved and every
    // later slot reading as its neighbour -- a `marshal` that dispatches to
    // `unmarshal`, silently. Phase 11 Part 14 added this after
    // `test/peg.zig` set out to compare the two descriptions of
    // `janet_peg_type` and found that the claim it wanted belonged here: it
    // is about the two *types* rather than about the PEG engine, and a
    // `@compileError` reaches every build rather than one contract.
    const ours = @typeInfo(AbstractType).@"struct".fields;
    const theirs = @typeInfo(types.JanetAbstractType).@"struct".fields;
    if (ours.len != theirs.len) {
        @compileError("abstract_type.AbstractType has a different number of fields from janet.h's");
    }
    for (ours, theirs) |a, b| {
        if (!std.mem.eql(u8, a.name, b.name)) {
            @compileError("abstract_type.AbstractType field '" ++ a.name ++
                "' is '" ++ b.name ++ "' in janet.h");
        }
        if (@offsetOf(AbstractType, a.name) != @offsetOf(types.JanetAbstractType, b.name)) {
            @compileError("abstract_type.AbstractType field '" ++ a.name ++
                "' is at a different offset from janet.h's");
        }
    }
}

/// An abstract type read out of the storage `janet.h` still describes: a
/// `JanetAbstract`'s header, a `janet_get_abstract_type` lookup, an argument
/// checked by `janet_getabstract`. The pointer is the same pointer.
pub inline fn of(slot: ?*const types.JanetAbstractType) *const AbstractType {
    return @ptrCast(@alignCast(slot.?));
}

/// The abstract type of a live abstract, which is where a dispatch starts.
pub inline fn ofAbstract(abst: ?*anyopaque) *const AbstractType {
    return of(types.abstractHead(abst).type);
}

/// The same pointer on its way back into that storage.
pub inline fn stored(at: *const AbstractType) *const types.JanetAbstractType {
    return @ptrCast(at);
}
