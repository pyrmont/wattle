//! Order: the three questions a container asks about a value it holds --
//! is it equal to this one, what is its hash, and which of the two sorts
//! first.
//!
//! An operation rather than a type, so the names keep their verbs --
//! `order.hash(x)`, `order.equals(a, b)`, `order.compare(a, b)`.
//!
//! `hash` cost one rename to become an ordinary name: the accumulator the
//! switch below writes was `var hash: i32 = 0;`, and a container-level
//! declaration and a local cannot share a name whatever the file is called.
//! The local is `h`.
//!
//! Hashing, equality and ordering over an arbitrary Janet value:
//! `janet_hash`, `janet_equals` and `janet_compare`, together with the
//! non-recursive traversal stack the last two share.
//!
//! ## Why these three are one increment
//!
//! Not because they read alike -- `janet_hash` is a flat switch with no
//! traversal at all. They are one file because they are one *contract*. A hash
//! table needs `janet_hash` and `janet_equals` to agree, and a struct needs
//! `janet_compare` to totally order whatever `janet_hash` puts in the same
//! bucket. The Robin Hood insert is the proof: it breaks a displacement tie by
//! full hash and then by `janet_compare` on the keys, because `janet_hash`
//! reads only the bytes for all three string-like types, so `:tie` and `"tie"`
//! collide and are not equal.
//!
//! ## The traversal stack is the shape, not an optimisation
//!
//! `janet_equals` and `janet_compare` are written as a loop over an explicit
//! stack in the VM state, not as recursion, because a tuple or struct may nest
//! to any depth a parser will accept and a stack overflow is not a catchable
//! error. That constraint is unchanged here, so the shape is kept rather than
//! the meaning: same stack, same growth policy, same node layout, same four
//! return codes out of `traversalNext`. A rewrite as recursion with a depth
//! guard would be a different function with different limits.
//!
//! Three things about that stack are easy to get wrong when reading it, and
//! all three are load-bearing:
//!
//!  - **The stack pointer addresses the top element, and the base slot is
//!    never used.** `pushTraversalNode` pre-increments before storing, and
//!    `traversalNext` walks while `t > traversal_base`. One slot at the bottom
//!    is permanently dead. It is also what makes the empty test cheap, and
//!    both functions depend on it.
//!  - **Neither entry point pops what it pushed.** `janet_equals` and
//!    `janet_compare` each reset `traversal` to `traversal_base` on entry and
//!    leave whatever they pushed behind on an early return. The stack is
//!    scratch space owned by whichever comparison is running, never state that
//!    survives one. This is why an early `return 0` needs no unwinding, and
//!    also why these two may not be re-entered from a callback they invoke.
//!  - **The prototype hop rewrites the top of the stack rather than pushing.**
//!    When a struct's pairs are exhausted and both sides have prototypes,
//!    `traversalNext` sets `traversal = t - 1` -- popping the struct node --
//!    and hands the two prototypes back as the next pair. The caller's own
//!    loop then pushes a fresh node for them. Written as a push it would grow
//!    the stack by one per level of prototype chain for no reason.
//!
//! The growth policy is `janet_realloc` with `2 * oldsize + 1`, floored at
//! 128 nodes, and a failure ends the process through `JANET_OUT_OF_MEMORY` --
//! here `janet_zig_out_of_memory`. Nothing frees this array; `janet_deinit`
//! does, and it is not part of this increment.
//!
//! ## SPIKE-8 applies directly, and twice over
//!
//! Both entry points reach a third-party abstract type's `compare` callback
//! through `compareAbstract`, and `janet_hash` reaches its `hash` callback.
//! Under SPIKE-8 such a callback may not raise, and a signal from one that
//! does jumps straight through these frames. There is no `defer` here and
//! `build.zig` checks that there is not. What a jump would strand is the
//! traversal array's *contents*, never the array itself: the array is owned by
//! `janet_vm` and the next comparison resets the stack pointer over whatever
//! was left, so a jump out of the middle of one is recovered by the next one
//! starting. That is the C original's behaviour too, and it is the reason the
//! reset lives at the top of each entry point rather than at the bottom.
//!
//! These three are also on the VM call path -- `run_vm` calls `janet_equals`
//! and `janet_compare` directly. That was the constraint `-Dcall-trampoline`
//! stayed off for; since the hinge each is an ordinary Zig call `run_vm`
//! `try`s, and the selector is gone.
//!
//! ## What is reproduced rather than repaired
//!
//! **A re-entrant `compare` callback corrupts the comparison that called it.**
//! There is one traversal stack per VM and both entry points reset it, so a
//! callback that compares anything -- or merely looks something up, since
//! `janet_table_get` reaches `janet_equals` through `janet_dict_find` --
//! destroys the state of the comparison that invoked it. `traversalNext` then
//! sees an empty stack, reports 2 for "no next node", and `janet_compare`
//! returns `status - 2`, which is zero: two values that differ are reported
//! equal. Nothing crashes and no sanitizer fires. SPIKE-8 settled that such a
//! callback may not *raise*, and that is written down; that it may not
//! *compare* is written down nowhere. `FOUND.md` records it, with the
//! reproducer. `janet_equals` has the same hole and is
//! shielded from it in practice, because it compares stored hashes before
//! pushing anything and so only ever traverses values that are equal.
//!
//! **`janet_compare` is not an ordering on NaN.** Both `==` and `<` are false,
//! so it returns 1 whichever way round the arguments are. The C comment above
//! the function says "excepts NaNs" and this is what that means.
//!
//! `traversalNext`'s key-returning branch is written in the C original as a
//! `for` loop whose body returns unconditionally on its first iteration, so
//! the induction variable is read once as a bound and never incremented. It is
//! an `if` spelled as a `for`. This writes the `if`, because writing a loop
//! that cannot iterate would be reproducing a typo rather than a behaviour --
//! the two are the same function of the same inputs, which the contract pins.
//! Nothing about it is a defect: the slot index advances in the *value*
//! branch, one slot per key/value pair.
//!
//! That branch also walks every bucket of the struct rather than every
//! *entry*, so the nil keys of empty buckets are compared alongside real ones.
//! That is correct rather than sloppy: a struct's Robin Hood layout is a
//! function of the set of pairs, so two structs that compare equal have
//! identical bucket arrays, and `janet_compare` has already rejected a
//! capacity mismatch before any node is pushed.
//!
//! `janet_hash`'s pointer fallback branches on `sizeOf(double) == sizeOf(void
//! *)`, which is a comptime condition here, and reads the raw payload word
//! through `janet_u64`. That macro spells a different field per value
//! representation -- `x.u64` for both NaN-boxed layouts, `x.as.u64` for the
//! tagged one -- so `asU64` below selects on the translated type's shape.
//! The `janet_equals` arm for strings is likewise the C original's and not a
//! tidied one: only `JANET_STRING` uses `janet_string_equal`, and symbols and
//! keywords fall through to the pointer comparison, which is sound because
//! both are interned and strings are not.
//! The consequence is deliberate in the original and preserved: a pointer's
//! hash is not the same number across representations, because the NaN-boxed
//! word carries the type tag and the tagged one does not. Nothing may depend
//! on a hash being stable across builds, and nothing does.

const std = @import("std");
const config = @import("config");
const strings = @import("../strings.zig");
const utils = @import("../../utils.zig");
const wrap = @import("wrap.zig");
const fatal = @import("../../fatal.zig");
const types = @import("types");
const repr = @import("repr");
const constants = @import("constants");
const vm_state = @import("../../vm/lifecycle.zig");

const tuple_flag_bracketctor: i32 = constants.JANET_TUPLE_FLAG_BRACKETCTOR;

/// `janet_u64(x)`, which is the only macro in this file whose spelling depends
/// on the value representation: `(x).u64` under either NaN-boxed layout, where
/// `Janet` is a union, and `(x).as.u64` under the tagged one, where it is a
/// struct with the payload in a nested union. Selecting on whether the
/// translated type has the field directly gets both without restating the
/// three-way `#ifdef` in `janet.h`.
const isBoxedUnion = config.value_repr != .tagged;

inline fn asU64(x: repr.Value) u64 {
    return if (comptime isBoxedUnion) @field(x, "u64") else @field(x.as, "u64");
}

// ------------------------------------------------------------ the traversal

/// `push_traversal_node`. Grows the stack when the top is one short of the
/// end, stores at the pre-incremented pointer, and never shrinks.
///
/// The `is_new` test guards more than the size computation: when the array has
/// never been allocated `traversal` is null, and the `traversal + 1 >=
/// traversal_top` comparison beside it would be arithmetic on a null pointer.
/// The C original relies on `||` short-circuiting for that and so does this.
/// The traversal stack starts unallocated; `pushTraversalNode` grows it on the
/// first push, which is what `base == null` means.
pub fn traversalInit(t: *types.Traversal) void {
    t.* = .{};
}

/// Release the stack and return it to what `traversalInit` starts from.
///
/// **All three, not just `base`.** `FOUND.md` has the reason: `push` decides
/// whether to grow on `base == null`, so a dangling one reaches
/// `janet_realloc` with a freed pointer -- and clearing only `base` would
/// leave `at` and `top` pointing into the same freed block, which is the same
/// inconsistency one field over. A type whose reset is one statement is what
/// stops the second half being a choice.
pub fn traversalDeinit(t: *types.Traversal) void {
    utils.free(t.base);
    t.* = .{};
}

fn pushTraversalNode(t: *types.Traversal, lhs: ?*anyopaque, rhs: ?*anyopaque, index2: i32) void {
    var node: types.JanetTraversalNode = undefined;
    node.self = @ptrCast(@alignCast(lhs));
    node.other = @ptrCast(@alignCast(rhs));
    node.index = 0;
    node.index2 = index2;
    const is_new = t.base == null;
    if (is_new or @intFromPtr(t.at.? + 1) >= @intFromPtr(t.top.?)) {
        const oldsize: usize = if (is_new) 0 else (@intFromPtr(t.at) -%
            @intFromPtr(t.base)) / @sizeOf(types.JanetTraversalNode);
        var newsize: usize = 2 *% oldsize +% 1;
        if (newsize < 128) newsize = 128;
        const tn: [*]types.JanetTraversalNode = @ptrCast(@alignCast(utils.realloc(
            @ptrCast(t.base),
            newsize *% @sizeOf(types.JanetTraversalNode),
        ) orelse fatal.outOfMemory()));
        t.base = tn;
        t.top = tn + newsize;
        t.at = tn + oldsize;
    }
    t.at.? += 1;
    t.at.?[0] = node;
}

/// `traversal_next`. Advances the traversal of the structs and tuples on the
/// stack without recursion, writing the next pair to compare through `x` and
/// `y`. The four codes are the C original's and both callers depend on the
/// numbering:
///
///  - 0 -- a next pair was found and written.
///  - 1 -- stop early, left is less.
///  - 2 -- no next pair; the traversal is finished.
///  - 3 -- stop early, left is greater.
///
/// `janet_compare` returns `status - 2`, which maps 1, 2 and 3 onto -1, 0 and
/// 1. That is the whole reason for the gap in the middle.
fn traversalNext(stack: *types.Traversal, x: *repr.Value, y: *repr.Value) i32 {
    var t = stack.at;
    while (t != null and @intFromPtr(t.?) > @intFromPtr(stack.base.?)) : (t = t.? - 1) {
        const node = t.?;
        const self = node[0].self.?;
        const tself: *const types.JanetTupleHead = @ptrCast(@alignCast(self));
        const sself: *const types.JanetStructHead = @ptrCast(@alignCast(self));
        const other = node[0].other.?;
        const tother: *const types.JanetTupleHead = @ptrCast(@alignCast(other));
        const sother: *const types.JanetStructHead = @ptrCast(@alignCast(other));
        if (self.memoryType() == .tuple) {
            // A tuple node: index is the element to compare next.
            if (node[0].index < tself.length and node[0].index < tother.length) {
                const index = node[0].index;
                node[0].index += 1;
                x.* = types.tupleData(tself)[asSize(index)];
                y.* = types.tupleData(tother)[asSize(index)];
                stack.at = node;
                return 0;
            }
            if (node[0].index2 != 0 and tself.length != tother.length) {
                return if (tself.length > tother.length) 3 else 1;
            }
        } else {
            // A struct node: index is the bucket, and index2 says the key of
            // that bucket has already been handed back and the value is next.
            if (node[0].index2 != 0) {
                node[0].index2 = 0;
                const index = node[0].index;
                node[0].index += 1;
                x.* = types.structData(sself)[asSize(index)].value;
                y.* = types.structData(sother)[asSize(index)].value;
                stack.at = node;
                return 0;
            }
            if (node[0].index < sself.capacity) {
                node[0].index2 = 1;
                x.* = types.structData(sself)[asSize(node[0].index)].key;
                y.* = types.structData(sother)[asSize(node[0].index)].key;
                stack.at = node;
                return 0;
            }
            // Buckets exhausted; hop to the prototypes, replacing this node
            // rather than stacking one on top of it.
            const sproto = sself.proto;
            const oproto = sother.proto;
            if (sproto != null and oproto == null) return 3;
            if (sproto == null and oproto != null) return 1;
            if (oproto != null and sproto != null) {
                x.* = wrap.fromStruct(sproto.?);
                y.* = wrap.fromStruct(oproto.?);
                stack.at = node - 1;
                return 0;
            }
        }
    }
    stack.at = t;
    return 2;
}

/// C's conversion of a signed index to `size_t` for subscripting. Every index
/// that reaches this has already been bounded against a non-negative length.
inline fn asSize(n: i32) usize {
    return @bitCast(@as(isize, n));
}

// ------------------------------------------------------------ abstract types

/// `janet_compare_abstract`. Identity first, then the abstract *type* pointers
/// -- which is what orders two unrelated abstract types against each other,
/// arbitrarily but consistently within one process -- and only then the type's
/// own `compare`, with a pointer comparison standing in when it has none.
fn compareAbstract(xx: types.JanetAbstract, yy: types.JanetAbstract) i32 {
    if (xx == yy) return 0;
    const xt = types.abstractHead(xx).type;
    const yt = types.abstractHead(yy).type;
    if (xt != yt) {
        return if (@intFromPtr(xt) > @intFromPtr(yt)) 1 else -1;
    }
    if (xt.*.compare == null) {
        return if (@intFromPtr(xx) > @intFromPtr(yy)) 1 else -1;
    }
    return xt.*.compare.?(xx, yy);
}

// ------------------------------------------------------------ equality

/// `janet_equals`. Deep equality, with the traversal stack standing in for
/// recursion over tuples and structs.
///
/// Note what the tuple and struct cases do *before* pushing: identity, then
/// the stored hash, then the length, plus the bracket flag for a tuple and the
/// presence of a prototype on both sides or neither for a struct. Those are
/// rejections rather than shortcuts, and the hash is the one that does the
/// work -- `janet_tuple_end` and `janet_struct_end` put it in the head, so two
/// values that differ essentially always disagree there. The practical
/// consequence is that the only inputs which reach the traversal are ones that
/// are *equal*, and the three checks behind the hash are reachable only on a
/// collision. `test/value_order.zig` forges one to get at them.
///
/// Abstract values are compared by `compareAbstract` rather than by an
/// `equals` callback, because the abstract type interface has no such
/// callback: ordering is the only relation a third-party type provides, and
/// equality is defined as its zero.
pub fn equals(x_in: repr.Value, y_in: repr.Value) c_int {
    var x = x_in;
    var y = y_in;
    const stack = &vm_state.current().traversal;
    stack.at = stack.base;
    while (true) {
        if (repr.typeOf(x) != repr.typeOf(y)) return 0;
        switch (repr.typeOf(x)) {
            repr.Tag.nil => {},
            repr.Tag.boolean => {
                if (wrap.toBoolean(x) != wrap.toBoolean(y)) return 0;
            },
            repr.Tag.number => {
                if (wrap.toNumber(x) != wrap.toNumber(y)) return 0;
            },
            repr.Tag.string => {
                // Only strings. Symbols and keywords reach the pointer
                // comparison below, which is sound because both are interned
                // and the string case is not. Kept as the C original has it
                // rather than merged: the merged form would be the same
                // function, and it would also be a slower one.
                if (strings.equal(wrap.toString(x), wrap.toString(y)) == 0) return 0;
            },
            repr.Tag.abstract => {
                if (compareAbstract(wrap.toAbstract(x), wrap.toAbstract(y)) != 0) return 0;
            },
            repr.Tag.tuple => {
                const t1 = wrap.toTuple(x);
                const t2 = wrap.toTuple(y);
                if (t1 != t2) {
                    const h1 = types.tupleHead(t1);
                    const h2 = types.tupleHead(t2);
                    if ((tuple_flag_bracketctor & (h1.gc.flags ^ h2.gc.flags)) != 0) return 0;
                    if (h1.hash != h2.hash) return 0;
                    if (h1.length != h2.length) return 0;
                    pushTraversalNode(stack, h1, h2, 0);
                }
            },
            repr.Tag.@"struct" => {
                const s1 = wrap.toStruct(x);
                const s2 = wrap.toStruct(y);
                if (s1 != s2) {
                    const h1 = types.structHead(s1);
                    const h2 = types.structHead(s2);
                    if (h1.hash != h2.hash) return 0;
                    if (h1.length != h2.length) return 0;
                    if (h1.proto != null and h2.proto == null) return 0;
                    if (h1.proto == null and h2.proto != null) return 0;
                    pushTraversalNode(stack, h1, h2, 0);
                }
            },
            else => {
                if (wrap.toPointer(x) != wrap.toPointer(y)) return 0;
            },
        }
        if (traversalNext(stack, &x, &y) != 0) break;
    }
    return 1;
}

// ------------------------------------------------------------ hashing

/// `murmur64`, the finalizer from MurmurHash3 used on its own as an integer
/// mixer. Every multiply and shift here is on `u64`, where C's unsigned
/// arithmetic already wraps, so no wrapping operator is needed for
/// correctness -- but the multiplies are written `*%` anyway to say so.
fn murmur64(h_in: u64) u64 {
    var h = h_in;
    h ^= h >> 33;
    h *%= 0xff51afd7ed558ccd;
    h ^= h >> 33;
    h *%= 0xc4ceb9fe1a85ec53;
    h ^= h >> 33;
    return h;
}

/// `janet_hash`. A hash for any Janet value, agreeing with `janet_equals` on
/// every type.
///
/// The three string-like types share one arm and hash only their *bytes*, so
/// `:tie`, `'tie` and `"tie"` all hash alike while comparing unequal. That is
/// deliberate and it is what makes the `janet_compare` tiebreak in the Robin
/// Hood insert load-bearing rather than defensive.
///
/// Everything with a stored hash -- strings, symbols, keywords, tuples,
/// structs -- returns it rather than recomputing, so this function never
/// traverses anything. A tuple adds one when it was written with brackets,
/// which is the only place a flag participates in a hash.
pub fn hash(x: repr.Value) callconv(.c) i32 {
    var h: i32 = 0;
    switch (repr.typeOf(x)) {
        repr.Tag.nil => h = 0,
        repr.Tag.boolean => h = @intFromBool(wrap.toBoolean(x)),
        repr.Tag.string, repr.Tag.symbol, repr.Tag.keyword => {
            h = stringHeadHash(wrap.toString(x));
        },
        repr.Tag.tuple => {
            const t = wrap.toTuple(x);
            const head = types.tupleHead(t);
            h = head.hash;
            const inc: u32 = if ((head.gc.flags & tuple_flag_bracketctor) != 0) 1 else 0;
            // Through u32 to avoid the signed overflow the C comment names.
            h = @bitCast(@as(u32, @bitCast(h)) +% inc);
        },
        repr.Tag.@"struct" => h = types.structHead(wrap.toStruct(x)).hash,
        repr.Tag.number => {
            var d = wrap.toNumber(x);
            d += 0.0; // normalize negative zero
            const bits: u64 = murmur64(@bitCast(d));
            h = @bitCast(@as(u32, @truncate(bits >> 32)));
        },
        else => {
            // The abstract arm falls through to the pointer h when the type
            // supplies no `h` callback, which is why it is folded in here
            // rather than written as its own case.
            if (repr.typeOf(x) == repr.Tag.abstract) {
                const xx = wrap.toAbstract(x);
                const at = types.abstractHead(xx).type;
                if (at.*.hash != null) {
                    return at.*.hash.?(xx, types.abstractHead(xx).size);
                }
            }
            if (comptime @sizeOf(f64) == @sizeOf(*anyopaque)) {
                // Assuming 8 byte pointer (8 byte aligned)
                const i = murmur64(asU64(x));
                h = @bitCast(@as(u32, @truncate(i >> 32)));
            } else {
                // Assuming 4 byte pointer (or smaller)
                const diff: usize = @intFromPtr(wrap.toPointer(x));
                const hilo: u32 = @as(u32, @truncate(diff)) *% 2654435769;
                h = @bitCast((hilo << 16) | (hilo >> 16));
            }
        },
    }
    return h;
}

/// `janet_string_hash`, which is `janet_string_head(s)->hash`.
inline fn stringHeadHash(s: [*]const u8) i32 {
    return types.stringHead(s).hash;
}

// ------------------------------------------------------------ ordering

/// `janet_compare`. A total order over every Janet value except NaN, returning
/// -1, 0 or 1.
///
/// Values of different types order by their `repr.Tag`, which makes the
/// order across types an artifact of the enumeration in `janet.h` rather than
/// anything meaningful -- and stable, which is all it has to be.
///
/// The tuple and struct cases differ from `janet_equals` in what they can
/// settle without traversing, because an ordering cannot stop at "not equal".
/// A struct compares capacity and then hash before pushing, so two structs of
/// different sizes are ordered by size; the hash comparison after it orders
/// two same-size structs that differ, arbitrarily but consistently, and only
/// a hash tie reaches the traversal. A tuple can settle nothing but the
/// bracket flag up front, since tuples of different lengths still order
/// element-wise until one runs out -- which is what the `index2` flag on a
/// tuple node means, and why `janet_compare` pushes it as 1 where
/// `janet_equals` pushes 0.
pub fn compare(x_in: repr.Value, y_in: repr.Value) callconv(.c) c_int {
    var x = x_in;
    var y = y_in;
    const stack = &vm_state.current().traversal;
    stack.at = stack.base;
    var status: i32 = 0;
    while (true) {
        const tx = repr.typeOf(x);
        const ty = repr.typeOf(y);
        if (tx != ty) return if (@intFromEnum(tx) < @intFromEnum(ty)) -1 else 1;
        switch (tx) {
            repr.Tag.nil => {},
            repr.Tag.boolean => {
                const diff = @as(c_int, @intFromBool(wrap.toBoolean(x))) - @intFromBool(wrap.toBoolean(y));
                if (diff != 0) return diff;
            },
            repr.Tag.number => {
                const xx = wrap.toNumber(x);
                const yy = wrap.toNumber(y);
                // A NaN on either side makes both `==` and `<` false, so
                // this returns 1 whichever way round the arguments are --
                // which is not an ordering, and is the "excepts NaNs" in the
                // C comment above this function. Reproduced, not repaired.
                if (xx == yy) {
                    // Equal so far; fall through to the traversal.
                } else {
                    return if (xx < yy) -1 else 1;
                }
            },
            repr.Tag.string, repr.Tag.symbol, repr.Tag.keyword => {
                const diff = strings.compare(wrap.toString(x), wrap.toString(y));
                if (diff != 0) return diff;
            },
            repr.Tag.abstract => {
                const diff = compareAbstract(wrap.toAbstract(x), wrap.toAbstract(y));
                if (diff != 0) return diff;
            },
            repr.Tag.tuple => {
                const lhs = wrap.toTuple(x);
                const rhs = wrap.toTuple(y);
                const lh = types.tupleHead(lhs);
                const rh = types.tupleHead(rhs);
                if ((tuple_flag_bracketctor & (lh.gc.flags ^ rh.gc.flags)) != 0) {
                    return if ((lh.gc.flags & tuple_flag_bracketctor) != 0) 1 else -1;
                }
                pushTraversalNode(stack, lh, rh, 1);
            },
            repr.Tag.@"struct" => {
                const lhs = wrap.toStruct(x);
                const rhs = wrap.toStruct(y);
                const lh = types.structHead(lhs);
                const rh = types.structHead(rhs);
                if (lh.capacity < rh.capacity) return -1;
                if (lh.capacity > rh.capacity) return 1;
                if (lh.hash < rh.hash) return -1;
                if (lh.hash > rh.hash) return 1;
                pushTraversalNode(stack, lh, rh, 0);
            },
            else => {
                if (wrap.toPointer(x) == wrap.toPointer(y)) {
                    // Equal so far; fall through to the traversal.
                } else {
                    return if (@intFromPtr(wrap.toPointer(x)) >
                        @intFromPtr(wrap.toPointer(y))) 1 else -1;
                }
            },
        }
        status = traversalNext(stack, &x, &y);
        if (status != 0) break;
    }
    return status - 2;
}
