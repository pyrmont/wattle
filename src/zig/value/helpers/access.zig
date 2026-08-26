//! Access: reaching inside a Janet value by index or by key, and the
//! iteration protocol beneath `next`.
//!
//! `value_access.zig` until Phase 12's namespace batch 3, `value/accessing.zig`
//! until increment 6f, and `value/helpers/access.zig` now that the gerund is
//! retired; `port/NAMESPACES.md` has the scheme. An operation rather than a
//! type, so the verbs stay: `access.in(ds, k)`, `access.get(ds, k)`,
//! `access.next(ds, k)`.
//! `getImpl` lost its suffix on the way -- `access.get` says what it is,
//! where `value_access.getImpl` needed the `Impl` to distinguish it from the
//! `janet_get` abi beside it, and the abi is spelled by `@export` now.
//!
//! **Two abis were renamed rather than left, on batch 2's rule.**
//! `getindex`/`getIndex` and `putindex`/`putIndex` differed by one letter's
//! case, one being the `callconv(.c)` abi and the other the raising kernel it
//! wraps -- the shape `port/swallowed.janet` exists to catch, because picking
//! the wrong one loses a raise and nothing says so. This predates the
//! namespace and is not created by it; the abis are `getindexAbi` and
//! `putindexAbi` now, after the convention increment 5d's population (c1)
//! established and batch 2 applied to `pushCstringAbi`.
//!
//! `access.zig` still stands over this file as nine `pub const` aliases, and
//! is a facade in exactly the sense `NAMESPACES.md` rejected for the value
//! layer -- `access.in` is a second, longer spelling of `access.in`. It
//! had a second arm until Phase 11 Part 26 and has had no reason since. The
//! batch repointed it and left it, as batch 2 left `containers.zig`: retiring
//! a facade is an increment, not something to fold into a split.
//!
//! Indexed and keyed access over an arbitrary Janet value, and the iteration
//! protocol beneath `next`. This is Part 7b of Phase 8 and it takes the rest
//! of `src/core/value.c`: `janet_next` and `janet_next_impl`, and the seven
//! accessors under `getter_checkint` -- `janet_in`, `janet_get`,
//! `janet_getindex`, `janet_length`, `janet_lengthv`, `janet_putindex` and
//! `janet_put`. With 7a's `JANET_ZIG_VALUE_ORDER` region beside it, `value.c`
//! now holds no C the port has not taken.
//!
//! Like 7a this needs **no seam**. `getter_checkint` is the file's only
//! remaining `static` and every one of its callers is here, so the two halves
//! stay closed over their own privates. `janet_next` sits physically between
//! 7a's two regions, which is why `value.c` carries two guarded regions per
//! selector rather than one; nothing was moved to make them contiguous.
//!
//! ## Zig calls `janet_panicf` through the C variadic ABI
//!
//! This is the first subsystem to do that, and it is worth saying why, because
//! Part 1 went the other way. `capi.c`'s getters report a `JanetArgFault` code
//! and let C format it, for a reason that does not apply here: a getter must
//! not raise, so it cannot afford a formatter that allocates. These accessors
//! are under no such constraint. Panicking *is* their contract -- `janet_in`
//! panics on a missing key, `janet_length` panics on a value with no length --
//! and this file is jump-transparent, so a `longjmp` out of `janet_panicf`
//! strands nothing. A fault-code seam here would add a translation layer to
//! twelve messages whose only job is to be identical to the C original's.
//!
//! What the direct call costs is an ABI assumption: `%v` passes a `Janet` by
//! value through `...`, and `%T` and `%d` pass an `int` where the caller holds
//! a type-flag mask and an `int32_t`. Zig lowers a call to an `extern`
//! variadic function under the target's C ABI, so this is sound in principle
//! on every target here -- but "in principle" is not the standard this project
//! works to, and the layout of `Janet` changes under `-Dnanbox=false` from an
//! eight-byte union to a sixteen-byte struct, which is exactly the size class
//! where the classification rules diverge. So `test/value_access.c` asserts
//! the *rendered message text*, byte for byte, for every one of the twelve.
//! That check runs under both selectors, under both value layouts, and on
//! every platform in the acceptance matrix, which makes the ABI a tested fact
//! rather than an assumed one.
//!
//! `janet_panicf` is `JANET_NO_RETURN`, and the translation carries that
//! through, so the panic arms below need no `unreachable` after them.
//!
//! ## SPIKE-8, and the two callbacks that are allowed to raise
//!
//! Six of the nine functions here reach a third-party abstract type's `get`,
//! `put`, `next` or `length` callback, and `janet_next_impl` resumes an
//! arbitrary fiber through `janet_continue`. Under SPIKE-8 these are called
//! directly, in the shape of the C original, and a signal raised by one jumps
//! straight through the Zig frame that invoked it. There is no `defer` here
//! and `build.zig` checks that there is not.
//!
//! One piece of state does have to survive such a jump, and the C original
//! handles it by hand rather than by scope: `janet_next_impl` parks the child
//! fiber in `janet_vm.fiber->child` across `janet_continue` and has to clear
//! it again. It clears the slot *before* `janet_panicv` on the non-interpreter
//! path, and deliberately does **not** clear it before `janet_signalv` on the
//! interpreter path, because the interpreter unwinds through the fiber chain
//! and needs the link. That asymmetry is reproduced exactly. Writing it as a
//! `defer` would be both a jump-transparency violation and wrong.
//!
//! `janet_in`, `janet_get`, `janet_getindex`, `janet_length`, `janet_lengthv`,
//! `janet_putindex`, `janet_put` and `janet_next_impl` are all called directly
//! by `run_vm`. That was the constraint `-Dcall-trampoline` stayed off for;
//! since the hinge each is an ordinary Zig call that `run_vm` `try`s, and the
//! selector is gone.
//!
//! ## What is reproduced rather than repaired
//!
//! Three pieces of the C original's arithmetic are undefined behaviour that
//! happens to work, and all three are in `FOUND.md` rather than fixed here.
//! Zig has no undefined behaviour to inherit, so each one is written as the
//! explicit wrapping or address-space operation the C compiles to in practice.
//!
//!  - **`janet_next_impl` advances a bucket pointer that may be null.** For a
//!    table or struct it computes `value.dictionaryFind(...) + 1`, and
//!    `value.dictionaryFind` returns `NULL` when it finds neither the key, nor an
//!    empty bucket, nor a tombstone. No dictionary a caller can build reaches
//!    that state -- every constructor rounds its capacity up through
//!    `value.capacityFor`, so a dictionary always has a spare bucket, and the one
//!    exception is the zero-capacity table `FOUND.md` already records, which
//!    dies inside `value.dictionaryFind` rather than returning from it. So this is
//!    a latent increment rather than a live one, and it is written as
//!    arithmetic on `usize` so that it stays defined for whatever makes it
//!    reachable later.
//!  - **`janet_next_impl` overflows the index it is asked to advance past.**
//!    `janet_unwrap_integer(key) + 1` on a key of `INT32_MAX` is signed
//!    overflow. It wraps to `INT32_MIN`, the `i >= 0` test then rejects it and
//!    the answer is right. Written here with `+%`.
//!  - **`janet_putindex` overflows the capacity it asks for.** `index + 1` on
//!    an index of `INT32_MAX` is signed overflow, and unlike `janet_put` --
//!    which bounds the index at `INT32_MAX - 1` through `getter_checkint` --
//!    `janet_putindex` takes the `int32_t` directly from its caller with no
//!    bound at all. Written here with `+%`, which reproduces the wrap the C
//!    compiles to; what follows it is a `janet_array_ensure` for a negative
//!    capacity, which is where the C original's behaviour stops being
//!    defensible. The VM only ever reaches this with a bytecode immediate, so
//!    it takes a C API caller to get there.
//!
//! A fourth is not arithmetic. `janet_length` and `janet_lengthv` render an
//! abstract type's `size_t` length with `%u`, which Janet's formatter reads
//! with `va_arg(args, uint64_t)`. The two agree only where `size_t` is 64
//! bits. That is every target this project builds for, and the widening is
//! preserved rather than corrected so the rendering is identical where it
//! works.
//!
//! ## The two lookup families are not one function
//!
//! `janet_in` and `janet_get` answer the same question and differ in what a
//! failure is: `janet_in` panics on a bad key and `janet_get` returns nil, and
//! that difference runs all the way down -- through whether a non-integer key
//! on a tuple is an error, through whether an abstract type without a `get`
//! callback is an error, through whether a fiber accepts a key other than
//! zero. `janet_getindex` is a third answer again: it takes an `int32_t`
//! rather than a `Janet`, panics only on a negative index and on a missing
//! setter, and returns nil for everything else. The three are written out
//! separately here for the same reason they are separate in C. Factoring them
//! into one function with a policy flag would put a branch on the VM's hot
//! path to save thirty lines.

const std = @import("std");
const raise = @import("raise");
const pp_format = @import("../../pp/format.zig");
const vm_calls = @import("../../vm.zig");
const abstract_type = @import("../../abstract_type.zig");
const buffers = @import("../buffers.zig");
const config = @import("config");
const structs = @import("../structs.zig");
const tables = @import("../tables.zig");
const arrays = @import("../arrays.zig");
const utils = @import("../../utils.zig");
const order = @import("order.zig");
const fibers = @import("../fibers.zig");
const kind = @import("kind.zig");
const wrap = @import("wrap.zig");
const args_core = @import("../../args.zig");
const value = @import("../../value.zig");
const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");
const vm_entry = @import("../../vm/entry.zig");

/// From `util.c`, declared here rather than in `cabi.zig`. This is the same
/// declaration `struct_table.zig` carries, and the same exception to the usual
/// justification: a `Janet` crosses here, so the reason it is safe is that the
/// type is `types.Janet`, which every file in the tree shares, not that no
/// Janet type is involved.
inline fn vm() *types.JanetVM {
    return c.vm();
}

/// A sign-preserving widening, which is what C's `int32_t` to `size_t`
/// conversion does. Most uses here are indices the callers have already
/// bounded, but two are not: `janet_putindex`'s `memset` length can wrap
/// negative at `INT32_MAX`, and this is what makes it reach `@memset` as the
/// same enormous value the C hands `memset`. See the note above about what is
/// reproduced rather than repaired.
inline fn asSize(n: i32) usize {
    return @bitCast(@as(isize, n));
}

/// `janet_wrap_integer`. Written out rather than called, because the function
/// it would call does not exist in every configuration. `janet.h` declares
/// `JANET_API Janet janet_wrap_integer(int32_t)` beside its macro, and
/// `wrap.c` provides that declaration's definition only inside `#if
/// defined(JANET_NANBOX_32) || defined(JANET_NANBOX_64)`. It is the only one
/// of the twenty-two declared `janet_wrap_*` functions with no definition
/// under `-Dnanbox=false`, so a caller that cannot use the macro -- which is
/// exactly the "language bindings" case the header's own comment names -- does
/// not link against a tagged build. `FOUND.md` has it. The macro is one line
/// and this is the whole of it.
inline fn wrapInteger(x: i32) types.Janet {
    return wrap.fromNumber(@floatFromInt(x));
}

/// One bucket forward from `p`, in address space rather than pointer space.
/// See the note above about `value.dictionaryFind` returning null.
inline fn nextBucket(p: ?*const types.JanetKV) *const types.JanetKV {
    return @ptrFromInt(@intFromPtr(p) +% @sizeOf(types.JanetKV));
}

// ------------------------------------------------------------------ next

/// `janet_next`. The public entry, which is `janet_next_impl` with the
/// interpreter flag clear -- so a signal from a resumed fiber becomes a panic
/// rather than being re-raised. Nothing in the tree calls it; `run_vm` always
/// passes one. It exists for embedders, and `FOUND.md` has what happens when
/// one uses it on a fiber.
pub fn next(ds: types.Janet, key: types.Janet) raise.Raising(types.Janet) {
    return nextImpl(ds, key, 0);
}

pub fn janet_next(ds: types.Janet, key: types.Janet) types.Janet {
    return raise.reported(next(ds, key));
}

/// `janet_next_impl`. Given a data structure and the previous key, produces
/// the next key, or nil when there is none. Four arms answer it in four
/// unrelated ways, and everything else panics.
///
/// The dictionary case is the only one that has to *find* the previous key
/// before it can move past it, and it does so with `value.dictionaryFind` rather
/// than by scanning, which is what makes a full iteration linear rather than
/// quadratic. It then walks forward over the empty buckets, since a hash table
/// stores its pairs sparsely and a nil key marks a slot that has none.
///
/// The sequence case does not look at the data structure at all until it has
/// decided what the next index would be: a nil key starts at zero, an integer
/// key advances by one, and anything else falls out of the switch to nil. Only
/// then does it read the length to decide whether that index exists. A
/// non-integer key is therefore not an error here -- iteration simply stops --
/// which is the opposite of what `janet_in` does with the same key.
///
/// The fiber case is the odd one, and it is what makes `next` a protocol
/// rather than a traversal: iterating a fiber *runs* it. The key it returns is
/// always the integer zero, because a fiber has no meaningful index; what the
/// caller does with it is fetch `last_value` through `janet_in`, which is the
/// hack the accessors' `JANET_FIBER` arms exist for. A fiber that cannot be
/// resumed answers nil immediately, and one that finishes during the resume
/// answers nil on the way out.
///
/// `janet_next_impl` is declared in `util.h` rather than in `janet.h`, so the
/// C build hides it under `-fvisibility=hidden` and this `export` does not.
/// That widens the shared library's symbol set and changes nothing that
/// already linked; `src/zig/README.md` has the general form of it, which four
/// subsystems now share.
pub fn nextImpl(ds: types.Janet, key: types.Janet, is_interpreter: c_int) raise.Raising(types.Janet) {
    const t = kind.typeOf(ds);
    switch (t) {
        constants.JANET_TABLE, constants.JANET_STRUCT => {
            var cap: i32 = undefined;
            var start: [*]const types.JanetKV = undefined;
            if (t == constants.JANET_TABLE) {
                const tab = wrap.toTable(ds);
                cap = tab.*.capacity;
                start = tab.*.data.?;
            } else {
                const st = wrap.toStruct(ds);
                cap = types.structHead(st).capacity;
                start = st;
            }
            const end = start + asSize(cap);
            var kv: [*]const types.JanetKV = if (kind.checkType(key, constants.JANET_NIL) != 0)
                start
            else
                @ptrCast(nextBucket(value.dictionaryFind(start, cap, key)));
            while (@intFromPtr(kv) < @intFromPtr(end)) : (kv += 1) {
                if (kind.checkType(kv[0].key, constants.JANET_NIL) == 0) return kv[0].key;
            }
        },
        constants.JANET_STRING, constants.JANET_KEYWORD, constants.JANET_SYMBOL, constants.JANET_BUFFER, constants.JANET_ARRAY, constants.JANET_TUPLE => {
            var i: i32 = undefined;
            if (kind.checkType(key, constants.JANET_NIL) != 0) {
                i = 0;
            } else if (args_core.checkint(key) != 0) {
                i = wrap.toInteger(key) +% 1;
            } else {
                return wrap.fromNil();
            }
            const len: i32 = if (t == constants.JANET_BUFFER)
                wrap.toBuffer(ds).*.count
            else if (t == constants.JANET_ARRAY)
                wrap.toArray(ds).*.count
            else if (t == constants.JANET_TUPLE)
                types.tupleHead(wrap.toTuple(ds)).length
            else
                types.stringHead(wrap.toString(ds)).length;
            if (i < len and i >= 0) {
                return wrapInteger(i);
            }
        },
        constants.JANET_ABSTRACT => {
            const abst = wrap.toAbstract(ds);
            const at = abstract_type.ofAbstract(abst);
            if (at.*.next == null) return wrap.fromNil();
            return at.*.next.?(abst, key);
        },
        constants.JANET_FIBER => {
            const child = wrap.toFiber(ds);
            var retreg: types.Janet = undefined;
            const status = fibers.status(child);
            if (status == constants.JANET_STATUS_ALIVE or
                status == constants.JANET_STATUS_DEAD or
                status == constants.JANET_STATUS_ERROR or
                status == constants.JANET_STATUS_USER0 or
                status == constants.JANET_STATUS_USER1 or
                status == constants.JANET_STATUS_USER2 or
                status == constants.JANET_STATUS_USER3 or
                status == constants.JANET_STATUS_USER4)
            {
                return wrap.fromNil();
            }
            vm().fiber.?.child = child;
            const sig = vm_entry.continueFiber(child, wrap.fromNil(), &retreg);
            if (sig != constants.JANET_SIGNAL_OK and (child.*.flags & (@as(i32, 1) << @intCast(sig))) == 0) {
                if (is_interpreter != 0) {
                    // Deliberately without clearing `child` first: the
                    // interpreter unwinds through the fiber chain and the link
                    // has to still be there when it does.
                    return raise.signal(sig, retreg);
                } else {
                    vm().fiber.?.child = null;
                    return raise.panicv(retreg);
                }
            }
            vm().fiber.?.child = null;
            if (sig == constants.JANET_SIGNAL_OK or
                sig == constants.JANET_SIGNAL_ERROR or
                sig == constants.JANET_SIGNAL_USER0 or
                sig == constants.JANET_SIGNAL_USER1 or
                sig == constants.JANET_SIGNAL_USER2 or
                sig == constants.JANET_SIGNAL_USER3 or
                sig == constants.JANET_SIGNAL_USER4)
            {
                // Fiber cannot be resumed, so discard last value.
                return wrap.fromNil();
            } else {
                return wrapInteger(0);
            }
        },
        else => return pp_format.panicf("expected iterable type, got %v", .{ds}),
    }
    return wrap.fromNil();
}

pub fn janet_next_impl(ds: types.Janet, key: types.Janet, is_interpreter: c_int) types.Janet {
    return raise.reported(nextImpl(ds, key, is_interpreter));
}

// ------------------------------------------------------------- the getters

/// `getter_checkint`. The bounds check the panicking accessors share: a key
/// has to be an integer, non-negative, and below `max`, and any of the three
/// failing produces the same message.
///
/// The C original reaches that message through three `goto bad`s into a label
/// past the `return`, which is how it keeps one copy of a format string with
/// four arguments. Written here as three early panics, which is the same
/// control flow without the label.
fn getterCheckInt(vtype: types.JanetType, key: types.Janet, max: i32) raise.Raising(i32) {
    if (args_core.checkint(key) == 0) return badKey(vtype, key, max);
    const ret = wrap.toInteger(key);
    if (ret < 0) return badKey(vtype, key, max);
    if (ret >= max) return badKey(vtype, key, max);
    return ret;
}

fn badKey(vtype: types.JanetType, key: types.Janet, max: i32) raise.Error {
    return pp_format.panicf("expected integer key for %s in range [0, %d), got %v", .{ utils.typeNames[@intCast(vtype)], @as(c_int, max), key });
}

/// `janet_in`. Keyed access that treats a bad key as an error. This is `(in ds
/// k)` and the VM's `GETINDEX`-family read.
///
/// The two dictionary types answer through `janet_struct_get` and
/// `janet_table_get`, which means a key that is simply absent yields nil
/// rather than panicking -- the panic here is about keys that are *wrong* for
/// the container, not keys that are missing from it. For the four sequence
/// types the key must be an integer in range, which is `getterCheckInt`.
///
/// An abstract type is the one place where a missing key does panic, because
/// its `get` callback reports presence separately from the value it produces
/// and the C original chose to treat absence as an error. Note the trailing
/// space in that message; it is the C original's and is preserved.
pub fn in(ds: types.Janet, key: types.Janet) raise.Raising(types.Janet) {
    var val: types.Janet = undefined;
    const vtype = kind.typeOf(ds);
    switch (vtype) {
        constants.JANET_STRUCT => val = structs.get(wrap.toStruct(ds), key),
        constants.JANET_TABLE => val = tables.get(wrap.toTable(ds), key),
        constants.JANET_ARRAY => {
            const array = wrap.toArray(ds);
            const index = getterCheckInt(vtype, key, array.*.count);
            val = array.*.data.?[asSize(try index)];
        },
        constants.JANET_TUPLE => {
            const tuple = wrap.toTuple(ds);
            const len = types.tupleHead(tuple).length;
            val = tuple[asSize(try getterCheckInt(vtype, key, len))];
        },
        constants.JANET_BUFFER => {
            const buffer = wrap.toBuffer(ds);
            const index = getterCheckInt(vtype, key, buffer.*.count);
            val = wrapInteger(buffer.*.data.?[asSize(try index)]);
        },
        constants.JANET_STRING, constants.JANET_SYMBOL, constants.JANET_KEYWORD => {
            const str = wrap.toString(ds);
            const index = getterCheckInt(vtype, key, types.stringHead(str).length);
            val = wrapInteger(str[asSize(try index)]);
        },
        constants.JANET_ABSTRACT => {
            const at = abstract_type.ofAbstract(wrap.toAbstract(ds));
            if (at.*.get) |getter| {
                if (try getter(wrap.toAbstract(ds), key, &val) == 0)
                    return pp_format.panicf("key %v not found in %v ", .{ key, ds });
            } else {
                return pp_format.panicf("no getter for %v", .{ds});
            }
        },
        constants.JANET_FIBER => {
            // Bit of a hack to allow iterating over fibers.
            if (order.equals(key, wrapInteger(0)) != 0) {
                return wrap.toFiber(ds).*.last_value;
            } else {
                return pp_format.panicf("expected key 0, got %v", .{key});
            }
        },
        else => return pp_format.panicf("expected %T, got %v", .{ @as(c_int, constants.JANET_TFLAG_LENGTHABLE), ds }),
    }
    return val;
}

pub fn janet_in(ds: types.Janet, key: types.Janet) types.Janet {
    return raise.reported(in(ds, key));
}

/// `janet_get`. Keyed access that treats every failure as nil. This is `(get
/// ds k)`, and it accepts anything at all as `ds` -- a number, a function, nil
/// -- because the `default` arm returns nil rather than panicking.
///
/// The array, tuple and buffer arm shares one integer check across three
/// containers, which is why it is written as a nested `if` on the type rather
/// than as three cases. That is the C original's shape and the reason it
/// shadows `t`: the outer `t` is the `JanetType` and the inner one is the
/// tuple. Renamed here, since Zig will not allow the shadowing and the C is no
/// clearer for it.
pub fn get(ds: types.Janet, key: types.Janet) raise.Raising(types.Janet) {
    const t = kind.typeOf(ds);
    switch (t) {
        constants.JANET_STRING, constants.JANET_SYMBOL, constants.JANET_KEYWORD => {
            if (args_core.checkint(key) == 0) return wrap.fromNil();
            const index = wrap.toInteger(key);
            if (index < 0) return wrap.fromNil();
            const str = wrap.toString(ds);
            if (index >= types.stringHead(str).length) return wrap.fromNil();
            return wrapInteger(str[asSize(index)]);
        },
        constants.JANET_ABSTRACT => {
            var val: types.Janet = undefined;
            const abst = wrap.toAbstract(ds);
            const at = abstract_type.ofAbstract(abst);
            const getter = at.*.get orelse return wrap.fromNil();
            if ((try getter(abst, key, &val)) != 0) return val;
            return wrap.fromNil();
        },
        constants.JANET_ARRAY, constants.JANET_TUPLE, constants.JANET_BUFFER => {
            if (args_core.checkint(key) == 0) return wrap.fromNil();
            const index = wrap.toInteger(key);
            if (index < 0) return wrap.fromNil();
            if (t == constants.JANET_ARRAY) {
                const a = wrap.toArray(ds);
                if (index >= a.*.count) return wrap.fromNil();
                return a.*.data.?[asSize(index)];
            } else if (t == constants.JANET_BUFFER) {
                const b = wrap.toBuffer(ds);
                if (index >= b.*.count) return wrap.fromNil();
                return wrapInteger(b.*.data.?[asSize(index)]);
            } else {
                const tup = wrap.toTuple(ds);
                if (index >= types.tupleHead(tup).length) return wrap.fromNil();
                return tup[asSize(index)];
            }
        },
        constants.JANET_TABLE => {
            return tables.get(wrap.toTable(ds), key);
        },
        constants.JANET_STRUCT => {
            const st = wrap.toStruct(ds);
            return structs.get(st, key);
        },
        constants.JANET_FIBER => {
            // Bit of a hack to allow iterating over fibers.
            if (order.equals(key, wrapInteger(0)) != 0) {
                return wrap.toFiber(ds).*.last_value;
            } else {
                return wrap.fromNil();
            }
        },
        else => return wrap.fromNil(),
    }
}

pub fn janet_get(ds: types.Janet, key: types.Janet) types.Janet {
    return raise.reported(get(ds, key));
}

/// `janet_getindex`. Access by a machine integer rather than a `Janet`, which
/// is a third failure policy again: a negative index panics, a value with no
/// indexed access panics, an abstract type with no `get` callback panics, and
/// everything else -- including an index past the end and an abstract `get`
/// that reports absence -- yields nil.
///
/// The asymmetry in the abstract arm is worth naming, because it is the
/// difference between this and `janet_in` on the same value: both panic when
/// the type has no `get` at all, but a `get` that runs and reports absence is
/// an error to `janet_in` and a nil to `janet_getindex`.
pub fn getIndex(ds: types.Janet, index: i32) raise.Raising(types.Janet) {
    var val: types.Janet = undefined;
    if (index < 0) return raise.panic("expected non-negative index");
    switch (kind.typeOf(ds)) {
        constants.JANET_STRING, constants.JANET_SYMBOL, constants.JANET_KEYWORD => {
            if (index >= types.stringHead(wrap.toString(ds)).length) {
                val = wrap.fromNil();
            } else {
                val = wrapInteger(wrap.toString(ds)[asSize(index)]);
            }
        },
        constants.JANET_ARRAY => {
            if (index >= wrap.toArray(ds).*.count) {
                val = wrap.fromNil();
            } else {
                val = wrap.toArray(ds).*.data.?[asSize(index)];
            }
        },
        constants.JANET_BUFFER => {
            if (index >= wrap.toBuffer(ds).*.count) {
                val = wrap.fromNil();
            } else {
                val = wrapInteger(wrap.toBuffer(ds).*.data.?[asSize(index)]);
            }
        },
        constants.JANET_TUPLE => {
            if (index >= types.tupleHead(wrap.toTuple(ds)).length) {
                val = wrap.fromNil();
            } else {
                val = wrap.toTuple(ds)[asSize(index)];
            }
        },
        constants.JANET_TABLE => val = tables.get(wrap.toTable(ds), wrapInteger(index)),
        constants.JANET_STRUCT => val = structs.get(wrap.toStruct(ds), wrapInteger(index)),
        constants.JANET_ABSTRACT => {
            const at = abstract_type.ofAbstract(wrap.toAbstract(ds));
            if (at.*.get) |getter| {
                if (try getter(wrap.toAbstract(ds), wrapInteger(index), &val) == 0)
                    val = wrap.fromNil();
            } else {
                return pp_format.panicf("no getter for %v", .{ds});
            }
        },
        constants.JANET_FIBER => {
            if (index == 0) {
                val = wrap.toFiber(ds).*.last_value;
            } else {
                val = wrap.fromNil();
            }
        },
        else => return pp_format.panicf("expected %T, got %v", .{ @as(c_int, constants.JANET_TFLAG_LENGTHABLE), ds }),
    }
    return val;
}

pub fn getindexAbi(ds: types.Janet, index: i32) types.Janet {
    return raise.reported(getIndex(ds, index));
}

// ------------------------------------------------------------- the lengths

/// `janet_length`. The length as a machine integer.
///
/// Six of the seven built-in cases read a count that is already an `int32_t`.
/// The abstract case is the one that can fail, and it fails in two different
/// ways depending on which of two mechanisms answers: a `length` callback
/// returns a `size_t`, which is rejected when it exceeds `INT32_MAX`; a type
/// without one is asked for a `length` *method* through `janet_mcall`, which
/// returns a `Janet` and is rejected when that is not an integer. Two
/// rejections, two messages, two format specifiers.
pub fn length(x: types.Janet) raise.Raising(i32) {
    switch (kind.typeOf(x)) {
        constants.JANET_STRING, constants.JANET_SYMBOL, constants.JANET_KEYWORD => return types.stringHead(wrap.toString(x)).length,
        constants.JANET_ARRAY => return wrap.toArray(x).*.count,
        constants.JANET_BUFFER => return wrap.toBuffer(x).*.count,
        constants.JANET_TUPLE => return types.tupleHead(wrap.toTuple(x)).length,
        constants.JANET_STRUCT => return types.structHead(wrap.toStruct(x)).length,
        constants.JANET_TABLE => return wrap.toTable(x).*.count,
        constants.JANET_ABSTRACT => {
            const abst = wrap.toAbstract(x);
            const at = abstract_type.ofAbstract(abst);
            if (at.*.length) |callback| {
                const len = try callback(abst, utils.abstractHead(abst).*.size);
                if (len > @as(usize, @intCast(std.math.maxInt(i32)))) {
                    return pp_format.panicf("invalid integer length %u", .{@as(u64, len)});
                }
                return @intCast(len);
            }
            var argv = [_]types.Janet{x};
            const len = try vm_calls.mcall("length", &argv);
            if (args_core.checkint(len) == 0)
                return pp_format.panicf("invalid integer length %v", .{len});
            return wrap.toInteger(len);
        },
        else => return pp_format.panicf("expected %T, got %v", .{ @as(c_int, constants.JANET_TFLAG_LENGTHABLE), x }),
    }
}

pub fn janet_length(x: types.Janet) i32 {
    return raise.reported(length(x));
}

/// `janet_lengthv`. The length as a `Janet`, which exists so that an abstract
/// type longer than `INT32_MAX` can answer at all: the value is wrapped as a
/// double rather than truncated, and the bound moves from `INT32_MAX` to
/// `JANET_INTMAX_INT64`, the largest integer a double represents exactly.
///
/// The 32-bit arm has no bound because it cannot need one -- a `size_t` there
/// is 32 bits, so every value it can hold is exactly representable. That is
/// the C original's `#ifdef JANET_32`, kept here as a `comptime` branch on the
/// same condition rather than dropped, even though no target this project
/// builds for takes it.
pub fn lengthv(x: types.Janet) raise.Raising(types.Janet) {
    switch (kind.typeOf(x)) {
        constants.JANET_STRING, constants.JANET_SYMBOL, constants.JANET_KEYWORD => return wrapInteger(types.stringHead(wrap.toString(x)).length),
        constants.JANET_ARRAY => return wrapInteger(wrap.toArray(x).*.count),
        constants.JANET_BUFFER => return wrapInteger(wrap.toBuffer(x).*.count),
        constants.JANET_TUPLE => return wrapInteger(types.tupleHead(wrap.toTuple(x)).length),
        constants.JANET_STRUCT => return wrapInteger(types.structHead(wrap.toStruct(x)).length),
        constants.JANET_TABLE => return wrapInteger(wrap.toTable(x).*.count),
        constants.JANET_ABSTRACT => {
            const abst = wrap.toAbstract(x);
            const at = abstract_type.ofAbstract(abst);
            if (at.*.length) |callback| {
                const len = try callback(abst, utils.abstractHead(abst).*.size);
                // If len is always less then double, we can never overflow
                if (comptime !config.bits64) {
                    return wrap.fromNumber(@floatFromInt(len));
                } else {
                    if (len < @as(usize, constants.JANET_INTMAX_INT64)) {
                        return wrap.fromNumber(@floatFromInt(len));
                    } else {
                        return pp_format.panicf("integer length %u too large", .{@as(u64, len)});
                    }
                }
            }
            var argv = [_]types.Janet{x};
            return try vm_calls.mcall("length", &argv);
        },
        else => return pp_format.panicf("expected %T, got %v", .{ @as(c_int, constants.JANET_TFLAG_LENGTHABLE), x }),
    }
}

pub fn janet_lengthv(x: types.Janet) types.Janet {
    return raise.reported(lengthv(x));
}

// ------------------------------------------------------------- the setters

/// `janet_putindex`. Write by a machine integer. Three container types accept
/// it and the rest panic; note that the type-flag mask in that message is
/// `ARRAY | BUFFER | TABLE` and not `LENGTHABLE`, because writing to a tuple,
/// a struct or a string is not a bad key but an impossible one.
///
/// An array or buffer written past its end grows to fit, and the growth is
/// where the two differ: an array fills the gap with nil in a loop, and a
/// buffer zeroes it with `memset`, because a buffer's elements are bytes and
/// zero is a byte. The whole of that -- the reserve, the fill and the new
/// `count` -- is inside the `index >= count` test, so an in-range write
/// touches only the one slot and leaves the count alone. The bound is `>=`
/// rather than `>` because appending at exactly the current count is a growth
/// by one.
///
/// The buffer arm masks the value to eight bits *after* checking it is an
/// integer at all, so `(put @"" 0 300)` stores 44 and does not complain. That
/// is established behaviour, not an oversight, and the same truncation is in
/// `janet_put`.
pub fn putIndex(ds: types.Janet, index: i32, val: types.Janet) raise.Raising(void) {
    switch (kind.typeOf(ds)) {
        constants.JANET_ARRAY => {
            const array = wrap.toArray(ds);
            if (index >= array.*.count) {
                arrays.ensure(array, index +% 1, 2);
                var i = array.*.count;
                while (i < index +% 1) : (i += 1) {
                    array.*.data.?[asSize(i)] = wrap.fromNil();
                }
                array.*.count = index +% 1;
            }
            array.*.data.?[asSize(index)] = val;
        },
        constants.JANET_BUFFER => {
            const buffer = wrap.toBuffer(ds);
            if (args_core.checkint(val) == 0)
                return pp_format.panicf("can only put integers in buffers, got %v", .{val});
            if (index >= buffer.*.count) {
                try buffers.ensure(buffer, index +% 1, 2);
                @memset((buffer.*.data.? + asSize(buffer.*.count))[0..asSize(index +% 1 -% buffer.*.count)], 0);
                buffer.*.count = index +% 1;
            }
            buffer.*.data.?[asSize(index)] = @truncate(@as(u32, @bitCast(wrap.toInteger(val))));
        },
        constants.JANET_TABLE => {
            const table = wrap.toTable(ds);
            tables.put(table, wrapInteger(index), val);
        },
        constants.JANET_ABSTRACT => {
            const at = abstract_type.ofAbstract(wrap.toAbstract(ds));
            if (at.*.put) |callback| {
                try callback(wrap.toAbstract(ds), wrapInteger(index), val);
            } else {
                return pp_format.panicf("no setter for %v ", .{ds});
            }
        },
        else => return pp_format.panicf("expected %T, got %v", .{ @as(c_int, constants.JANET_TFLAG_ARRAY | constants.JANET_TFLAG_BUFFER | constants.JANET_TFLAG_TABLE), ds }),
    }
}

pub fn putindexAbi(ds: types.Janet, index: i32, val: types.Janet) void {
    _ = raise.reported(putIndex(ds, index, val));
}

/// `janet_put`. Write by a `Janet` key. The array and buffer arms are
/// `janet_putindex`'s with a `getterCheckInt` in front, bounded at `INT32_MAX
/// - 1` so that the `index + 1` below it cannot overflow -- the bound
/// `janet_putindex` does not have.
///
/// The two are not factored together, even though the bodies below the check
/// are identical, because the C original does not factor them and the
/// difference in the panic each one raises first is observable: `janet_put` on
/// a buffer checks the *key* before the value, so `(put @"" :x :y)` complains
/// about the key and `(put @"" 0 :y)` complains about the value.
pub fn put(ds: types.Janet, key: types.Janet, val: types.Janet) raise.Raising(void) {
    const vtype = kind.typeOf(ds);
    switch (vtype) {
        constants.JANET_ARRAY => {
            const array = wrap.toArray(ds);
            const index = try getterCheckInt(vtype, key, std.math.maxInt(i32) - 1);
            if (index >= array.*.count) {
                arrays.ensure(array, index + 1, 2);
                var i = array.*.count;
                while (i < index + 1) : (i += 1) {
                    array.*.data.?[asSize(i)] = wrap.fromNil();
                }
                array.*.count = index + 1;
            }
            array.*.data.?[asSize(index)] = val;
        },
        constants.JANET_BUFFER => {
            const buffer = wrap.toBuffer(ds);
            const index = try getterCheckInt(vtype, key, std.math.maxInt(i32) - 1);
            if (args_core.checkint(val) == 0)
                return pp_format.panicf("can only put integers in buffers, got %v", .{val});
            if (index >= buffer.*.count) {
                try buffers.ensure(buffer, index + 1, 2);
                @memset((buffer.*.data.? + asSize(buffer.*.count))[0..asSize(index + 1 - buffer.*.count)], 0);
                buffer.*.count = index + 1;
            }
            buffer.*.data.?[asSize(index)] = @truncate(@as(u32, @bitCast(wrap.toInteger(val))));
        },
        constants.JANET_TABLE => tables.put(wrap.toTable(ds), key, val),
        constants.JANET_ABSTRACT => {
            const at = abstract_type.ofAbstract(wrap.toAbstract(ds));
            if (at.*.put) |callback| {
                try callback(wrap.toAbstract(ds), key, val);
            } else {
                return pp_format.panicf("no setter for %v ", .{ds});
            }
        },
        else => return pp_format.panicf("expected %T, got %v", .{ @as(c_int, constants.JANET_TFLAG_ARRAY | constants.JANET_TFLAG_BUFFER | constants.JANET_TFLAG_TABLE), ds }),
    }
}

pub fn janet_put(ds: types.Janet, key: types.Janet, val: types.Janet) void {
    _ = raise.reported(put(ds, key, val));
}
