//! Kind: what a Janet *is*, asked four ways.
//!
//! `typeOf` answers the tag, `checkType` and `checkTypes` test it against one
//! type or a mask of them, and `truthy` answers the only question Janet asks
//! of a value without caring what type it is. Phase 12's namespace batch 4
//! split them out of `value_wrap.zig`; `port/NAMESPACES.md` has the scheme.
//!
//! **They are here rather than in `wrap.zig` because they do not convert
//! anything.** That is the whole argument, and the note makes it as a
//! consequence rather than as a preference: with these four gone, every gerund
//! in `value/` is true of its file. `wrap` converts, `kind` inspects,
//! `order` compares, `access` reaches inside. `wrap.truthy(x)` would
//! have been a misnomer in a file whose other 36 members all move a value
//! across the representation boundary.
//!
//! **`typeOf` is the name the tree already used.** `janet_type` is reserved
//! twice over -- `type` is a Zig keyword in all but name and the tree binds it
//! everywhere -- and `value_wrap.zig`'s three layout structs have had an
//! `inline fn typeOf` each since Phase 8. `NAMESPACES.md` rule 7 is that a
//! reserved name takes the tree's own word, and this is the case it was
//! written for: **95 references, the largest single name left on the seam
//! after increment 5d**, spelled `c.janet_type` for two increments because
//! nothing could spell it in Zig.
//!
//! ## The layout stays next door
//!
//! All four questions are answered by the representation, and the
//! representation is `wrap.zig`'s -- three layout structs behind one
//! comptime-selected `repr`. This file reaches it and does not copy it, which
//! is batch 2's line where it matters most: a second copy of the bit patterns
//! is the one duplication that could disagree with the values themselves.
//!
//! So `wrap.repr` is `pub` for this file alone, and `wrap.zig` says so
//! at the declaration. The dependency is one-directional -- `wrap.zig`
//! names nothing here, because its own `ops` sub-namespace already reaches
//! `repr` directly for the inline predicates `vm_run` needs.
//!
//! ## The abis keep the C signature and the members keep the C name
//!
//! `janet_checktype` answers `int`, not `bool`, and so does this file's
//! `checkType`. That is deliberate and it is a scope decision rather than a
//! taste one: 218 of the 228 call sites carry an explicit `!= 0` or `== 0`,
//! and turning the return type into a `bool` is a change to every one of them
//! that the split does not need. `wrap.ops` already holds the `bool`
//! spelling for the interpreter, which is the caller that wanted it.
//!
//! Whether the two should converge -- and whether `ops` survives that -- is
//! `NAMESPACES.md`'s open question 2b.

const wrap = @import("wrap.zig");
const types = @import("types");
const c = @import("cabi");

const repr = wrap.repr;

/// `janet_type`. The tag, which under both NaN-boxed layouts is a shift and a
/// mask of the word and under the tagged layout is a field read.
pub fn typeOf(x: types.Janet) types.JanetType {
    return repr.typeOf(x);
}

/// `janet_checktype`. Answers `c_int` because `janet.h` does; see the header.
pub fn checkType(x: types.Janet, t: types.JanetType) c_int {
    return @intFromBool(repr.checkType(x, t));
}

/// `janet_checktypes`. The mask is `1 << type`, so a caller tests several
/// types in one call; `JANET_TFLAG_*` in `janet.h` are the constants.
pub fn checkTypes(x: types.Janet, typeflags: c_int) c_int {
    const bit = @as(c_int, 1) << @intCast(repr.typeOf(x));
    return bit & typeflags;
}

/// `janet_truthy`. Everything but `nil` and `false` is true, which is the one
/// question that does not dispatch on the type.
pub fn truthy(x: types.Janet) c_int {
    return @intFromBool(repr.truthy(x));
}
