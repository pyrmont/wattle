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
//!    table or struct it computes `janet_dict_find(...) + 1`, and
//!    `janet_dict_find` returns `NULL` when it finds neither the key, nor an
//!    empty bucket, nor a tombstone. No dictionary a caller can build reaches
//!    that state -- every constructor rounds its capacity up through
//!    `janet_tablen`, so a dictionary always has a spare bucket, and the one
//!    exception is the zero-capacity table `FOUND.md` already records, which
//!    dies inside `janet_dict_find` rather than returning from it. So this is
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
const abi = @import("abi");
const raise = @import("raise");
const pp_format = @import("pp_format.zig");
const vm_calls = @import("vm_calls.zig");
const abstract_type = @import("abstract_type.zig");
const containers = @import("containers.zig");
const c = abi.c;

/// From `util.c`, which `abi.zig` deliberately does not translate. This is the
/// same declaration `struct_table.zig` carries, and the same exception to the
/// usual justification: a `Janet` crosses here, so the reason it is safe is
/// that the type comes from the one shared translation, not that no Janet type
/// is involved.
extern fn janet_dict_find(buckets: [*c]const c.JanetKV, cap: i32, key: c.Janet) callconv(.c) [*c]const c.JanetKV;

inline fn vm() *c.JanetVM {
    return &c.janet_vm;
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

/// `janet_struct_head`. Recovered by `@sizeOf` rather than `@offsetof` because
/// translate-c drops the flexible array member the C macro takes the offset
/// of; the two agree because `data` is maximally aligned within the head.
inline fn structHead(st: [*c]const c.JanetKV) *c.JanetStructHead {
    return @ptrFromInt(@intFromPtr(st) -% @sizeOf(c.JanetStructHead));
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
inline fn wrapInteger(x: i32) c.Janet {
    return c.janet_wrap_number(@floatFromInt(x));
}

/// One bucket forward from `p`, in address space rather than pointer space.
/// See the note above about `janet_dict_find` returning null.
inline fn nextBucket(p: [*c]const c.JanetKV) [*c]const c.JanetKV {
    return @ptrFromInt(@intFromPtr(p) +% @sizeOf(c.JanetKV));
}

// ------------------------------------------------------------------ next

/// `janet_next`. The public entry, which is `janet_next_impl` with the
/// interpreter flag clear -- so a signal from a resumed fiber becomes a panic
/// rather than being re-raised. Nothing in the tree calls it; `run_vm` always
/// passes one. It exists for embedders, and `FOUND.md` has what happens when
/// one uses it on a fiber.
pub fn next(ds: c.Janet, key: c.Janet) raise.Raising(c.Janet) {
    return nextImpl(ds, key, 0);
}

export fn janet_next(ds: c.Janet, key: c.Janet) callconv(.c) c.Janet {
    return raise.reported(next(ds, key));
}

/// `janet_next_impl`. Given a data structure and the previous key, produces
/// the next key, or nil when there is none. Four arms answer it in four
/// unrelated ways, and everything else panics.
///
/// The dictionary case is the only one that has to *find* the previous key
/// before it can move past it, and it does so with `janet_dict_find` rather
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
pub fn nextImpl(ds: c.Janet, key: c.Janet, is_interpreter: c_int) raise.Raising(c.Janet) {
    const t = c.janet_type(ds);
    switch (t) {
        c.JANET_TABLE, c.JANET_STRUCT => {
            var cap: i32 = undefined;
            var start: [*c]const c.JanetKV = undefined;
            if (t == c.JANET_TABLE) {
                const tab = c.janet_unwrap_table(ds);
                cap = tab.*.capacity;
                start = tab.*.data;
            } else {
                const st = c.janet_unwrap_struct(ds);
                cap = structHead(st).capacity;
                start = st;
            }
            const end = start + asSize(cap);
            var kv = if (c.janet_checktype(key, c.JANET_NIL) != 0)
                start
            else
                nextBucket(janet_dict_find(start, cap, key));
            while (@intFromPtr(kv) < @intFromPtr(end)) : (kv += 1) {
                if (c.janet_checktype(kv.*.key, c.JANET_NIL) == 0) return kv.*.key;
            }
        },
        c.JANET_STRING, c.JANET_KEYWORD, c.JANET_SYMBOL, c.JANET_BUFFER, c.JANET_ARRAY, c.JANET_TUPLE => {
            var i: i32 = undefined;
            if (c.janet_checktype(key, c.JANET_NIL) != 0) {
                i = 0;
            } else if (c.janet_checkint(key) != 0) {
                i = c.janet_unwrap_integer(key) +% 1;
            } else {
                return c.janet_wrap_nil();
            }
            const len: i32 = if (t == c.JANET_BUFFER)
                c.janet_unwrap_buffer(ds).*.count
            else if (t == c.JANET_ARRAY)
                c.janet_unwrap_array(ds).*.count
            else if (t == c.JANET_TUPLE)
                c.janet_tuple_length(c.janet_unwrap_tuple(ds))
            else
                c.janet_string_length(c.janet_unwrap_string(ds));
            if (i < len and i >= 0) {
                return wrapInteger(i);
            }
        },
        c.JANET_ABSTRACT => {
            const abst = c.janet_unwrap_abstract(ds);
            const at = abstract_type.ofAbstract(abst);
            if (at.*.next == null) return c.janet_wrap_nil();
            return at.*.next.?(abst, key);
        },
        c.JANET_FIBER => {
            const child = c.janet_unwrap_fiber(ds);
            var retreg: c.Janet = undefined;
            const status = c.janet_fiber_status(child);
            if (status == c.JANET_STATUS_ALIVE or
                status == c.JANET_STATUS_DEAD or
                status == c.JANET_STATUS_ERROR or
                status == c.JANET_STATUS_USER0 or
                status == c.JANET_STATUS_USER1 or
                status == c.JANET_STATUS_USER2 or
                status == c.JANET_STATUS_USER3 or
                status == c.JANET_STATUS_USER4)
            {
                return c.janet_wrap_nil();
            }
            vm().fiber.*.child = child;
            const sig = c.janet_continue(child, c.janet_wrap_nil(), &retreg);
            if (sig != c.JANET_SIGNAL_OK and (child.*.flags & (@as(i32, 1) << @intCast(sig))) == 0) {
                if (is_interpreter != 0) {
                    // Deliberately without clearing `child` first: the
                    // interpreter unwinds through the fiber chain and the link
                    // has to still be there when it does.
                    return raise.signal(sig, retreg);
                } else {
                    vm().fiber.*.child = null;
                    return raise.panicv(retreg);
                }
            }
            vm().fiber.*.child = null;
            if (sig == c.JANET_SIGNAL_OK or
                sig == c.JANET_SIGNAL_ERROR or
                sig == c.JANET_SIGNAL_USER0 or
                sig == c.JANET_SIGNAL_USER1 or
                sig == c.JANET_SIGNAL_USER2 or
                sig == c.JANET_SIGNAL_USER3 or
                sig == c.JANET_SIGNAL_USER4)
            {
                // Fiber cannot be resumed, so discard last value.
                return c.janet_wrap_nil();
            } else {
                return wrapInteger(0);
            }
        },
        else => return pp_format.panicf("expected iterable type, got %v", .{ds}),
    }
    return c.janet_wrap_nil();
}

export fn janet_next_impl(ds: c.Janet, key: c.Janet, is_interpreter: c_int) callconv(.c) c.Janet {
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
fn getterCheckInt(vtype: c.JanetType, key: c.Janet, max: i32) raise.Raising(i32) {
    if (c.janet_checkint(key) == 0) return badKey(vtype, key, max);
    const ret = c.janet_unwrap_integer(key);
    if (ret < 0) return badKey(vtype, key, max);
    if (ret >= max) return badKey(vtype, key, max);
    return ret;
}

fn badKey(vtype: c.JanetType, key: c.Janet, max: i32) raise.Error {
    return pp_format.panicf("expected integer key for %s in range [0, %d), got %v", .{ c.janet_type_names[@intCast(vtype)], @as(c_int, max), key });
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
pub fn in(ds: c.Janet, key: c.Janet) raise.Raising(c.Janet) {
    var value: c.Janet = undefined;
    const vtype = c.janet_type(ds);
    switch (vtype) {
        c.JANET_STRUCT => value = c.janet_struct_get(c.janet_unwrap_struct(ds), key),
        c.JANET_TABLE => value = c.janet_table_get(c.janet_unwrap_table(ds), key),
        c.JANET_ARRAY => {
            const array = c.janet_unwrap_array(ds);
            const index = getterCheckInt(vtype, key, array.*.count);
            value = array.*.data[asSize(try index)];
        },
        c.JANET_TUPLE => {
            const tuple = c.janet_unwrap_tuple(ds);
            const len = c.janet_tuple_length(tuple);
            value = tuple[asSize(try getterCheckInt(vtype, key, len))];
        },
        c.JANET_BUFFER => {
            const buffer = c.janet_unwrap_buffer(ds);
            const index = getterCheckInt(vtype, key, buffer.*.count);
            value = wrapInteger(buffer.*.data[asSize(try index)]);
        },
        c.JANET_STRING, c.JANET_SYMBOL, c.JANET_KEYWORD => {
            const str = c.janet_unwrap_string(ds);
            const index = getterCheckInt(vtype, key, c.janet_string_length(str));
            value = wrapInteger(str[asSize(try index)]);
        },
        c.JANET_ABSTRACT => {
            const at = abstract_type.ofAbstract(c.janet_unwrap_abstract(ds));
            if (at.*.get) |get| {
                if (try get(c.janet_unwrap_abstract(ds), key, &value) == 0)
                    return pp_format.panicf("key %v not found in %v ", .{ key, ds });
            } else {
                return pp_format.panicf("no getter for %v", .{ds});
            }
        },
        c.JANET_FIBER => {
            // Bit of a hack to allow iterating over fibers.
            if (c.janet_equals(key, wrapInteger(0)) != 0) {
                return c.janet_unwrap_fiber(ds).*.last_value;
            } else {
                return pp_format.panicf("expected key 0, got %v", .{key});
            }
        },
        else => return pp_format.panicf("expected %T, got %v", .{ @as(c_int, c.JANET_TFLAG_LENGTHABLE), ds }),
    }
    return value;
}

export fn janet_in(ds: c.Janet, key: c.Janet) callconv(.c) c.Janet {
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
pub fn getImpl(ds: c.Janet, key: c.Janet) raise.Raising(c.Janet) {
    const t = c.janet_type(ds);
    switch (t) {
        c.JANET_STRING, c.JANET_SYMBOL, c.JANET_KEYWORD => {
            if (c.janet_checkint(key) == 0) return c.janet_wrap_nil();
            const index = c.janet_unwrap_integer(key);
            if (index < 0) return c.janet_wrap_nil();
            const str = c.janet_unwrap_string(ds);
            if (index >= c.janet_string_length(str)) return c.janet_wrap_nil();
            return wrapInteger(str[asSize(index)]);
        },
        c.JANET_ABSTRACT => {
            var value: c.Janet = undefined;
            const abst = c.janet_unwrap_abstract(ds);
            const at = abstract_type.ofAbstract(abst);
            const get = at.*.get orelse return c.janet_wrap_nil();
            if ((try get(abst, key, &value)) != 0) return value;
            return c.janet_wrap_nil();
        },
        c.JANET_ARRAY, c.JANET_TUPLE, c.JANET_BUFFER => {
            if (c.janet_checkint(key) == 0) return c.janet_wrap_nil();
            const index = c.janet_unwrap_integer(key);
            if (index < 0) return c.janet_wrap_nil();
            if (t == c.JANET_ARRAY) {
                const a = c.janet_unwrap_array(ds);
                if (index >= a.*.count) return c.janet_wrap_nil();
                return a.*.data[asSize(index)];
            } else if (t == c.JANET_BUFFER) {
                const b = c.janet_unwrap_buffer(ds);
                if (index >= b.*.count) return c.janet_wrap_nil();
                return wrapInteger(b.*.data[asSize(index)]);
            } else {
                const tup = c.janet_unwrap_tuple(ds);
                if (index >= c.janet_tuple_length(tup)) return c.janet_wrap_nil();
                return tup[asSize(index)];
            }
        },
        c.JANET_TABLE => {
            return c.janet_table_get(c.janet_unwrap_table(ds), key);
        },
        c.JANET_STRUCT => {
            const st = c.janet_unwrap_struct(ds);
            return c.janet_struct_get(st, key);
        },
        c.JANET_FIBER => {
            // Bit of a hack to allow iterating over fibers.
            if (c.janet_equals(key, wrapInteger(0)) != 0) {
                return c.janet_unwrap_fiber(ds).*.last_value;
            } else {
                return c.janet_wrap_nil();
            }
        },
        else => return c.janet_wrap_nil(),
    }
}

export fn janet_get(ds: c.Janet, key: c.Janet) callconv(.c) c.Janet {
    return raise.reported(getImpl(ds, key));
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
pub fn getIndex(ds: c.Janet, index: i32) raise.Raising(c.Janet) {
    var value: c.Janet = undefined;
    if (index < 0) return raise.panic("expected non-negative index");
    switch (c.janet_type(ds)) {
        c.JANET_STRING, c.JANET_SYMBOL, c.JANET_KEYWORD => {
            if (index >= c.janet_string_length(c.janet_unwrap_string(ds))) {
                value = c.janet_wrap_nil();
            } else {
                value = wrapInteger(c.janet_unwrap_string(ds)[asSize(index)]);
            }
        },
        c.JANET_ARRAY => {
            if (index >= c.janet_unwrap_array(ds).*.count) {
                value = c.janet_wrap_nil();
            } else {
                value = c.janet_unwrap_array(ds).*.data[asSize(index)];
            }
        },
        c.JANET_BUFFER => {
            if (index >= c.janet_unwrap_buffer(ds).*.count) {
                value = c.janet_wrap_nil();
            } else {
                value = wrapInteger(c.janet_unwrap_buffer(ds).*.data[asSize(index)]);
            }
        },
        c.JANET_TUPLE => {
            if (index >= c.janet_tuple_length(c.janet_unwrap_tuple(ds))) {
                value = c.janet_wrap_nil();
            } else {
                value = c.janet_unwrap_tuple(ds)[asSize(index)];
            }
        },
        c.JANET_TABLE => value = c.janet_table_get(c.janet_unwrap_table(ds), wrapInteger(index)),
        c.JANET_STRUCT => value = c.janet_struct_get(c.janet_unwrap_struct(ds), wrapInteger(index)),
        c.JANET_ABSTRACT => {
            const at = abstract_type.ofAbstract(c.janet_unwrap_abstract(ds));
            if (at.*.get) |get| {
                if (try get(c.janet_unwrap_abstract(ds), wrapInteger(index), &value) == 0)
                    value = c.janet_wrap_nil();
            } else {
                return pp_format.panicf("no getter for %v", .{ds});
            }
        },
        c.JANET_FIBER => {
            if (index == 0) {
                value = c.janet_unwrap_fiber(ds).*.last_value;
            } else {
                value = c.janet_wrap_nil();
            }
        },
        else => return pp_format.panicf("expected %T, got %v", .{ @as(c_int, c.JANET_TFLAG_LENGTHABLE), ds }),
    }
    return value;
}

export fn janet_getindex(ds: c.Janet, index: i32) callconv(.c) c.Janet {
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
pub fn length(x: c.Janet) raise.Raising(i32) {
    switch (c.janet_type(x)) {
        c.JANET_STRING, c.JANET_SYMBOL, c.JANET_KEYWORD => return c.janet_string_length(c.janet_unwrap_string(x)),
        c.JANET_ARRAY => return c.janet_unwrap_array(x).*.count,
        c.JANET_BUFFER => return c.janet_unwrap_buffer(x).*.count,
        c.JANET_TUPLE => return c.janet_tuple_length(c.janet_unwrap_tuple(x)),
        c.JANET_STRUCT => return structHead(c.janet_unwrap_struct(x)).length,
        c.JANET_TABLE => return c.janet_unwrap_table(x).*.count,
        c.JANET_ABSTRACT => {
            const abst = c.janet_unwrap_abstract(x);
            const at = abstract_type.ofAbstract(abst);
            if (at.*.length) |callback| {
                const len = try callback(abst, c.janet_abstract_head(abst).*.size);
                if (len > @as(usize, @intCast(std.math.maxInt(i32)))) {
                    return pp_format.panicf("invalid integer length %u", .{@as(u64, len)});
                }
                return @intCast(len);
            }
            var argv = [_]c.Janet{x};
            const len = try vm_calls.mcall("length", 1, &argv);
            if (c.janet_checkint(len) == 0)
                return pp_format.panicf("invalid integer length %v", .{len});
            return c.janet_unwrap_integer(len);
        },
        else => return pp_format.panicf("expected %T, got %v", .{ @as(c_int, c.JANET_TFLAG_LENGTHABLE), x }),
    }
}

export fn janet_length(x: c.Janet) callconv(.c) i32 {
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
pub fn lengthv(x: c.Janet) raise.Raising(c.Janet) {
    switch (c.janet_type(x)) {
        c.JANET_STRING, c.JANET_SYMBOL, c.JANET_KEYWORD => return wrapInteger(c.janet_string_length(c.janet_unwrap_string(x))),
        c.JANET_ARRAY => return wrapInteger(c.janet_unwrap_array(x).*.count),
        c.JANET_BUFFER => return wrapInteger(c.janet_unwrap_buffer(x).*.count),
        c.JANET_TUPLE => return wrapInteger(c.janet_tuple_length(c.janet_unwrap_tuple(x))),
        c.JANET_STRUCT => return wrapInteger(structHead(c.janet_unwrap_struct(x)).length),
        c.JANET_TABLE => return wrapInteger(c.janet_unwrap_table(x).*.count),
        c.JANET_ABSTRACT => {
            const abst = c.janet_unwrap_abstract(x);
            const at = abstract_type.ofAbstract(abst);
            if (at.*.length) |callback| {
                const len = try callback(abst, c.janet_abstract_head(abst).*.size);
                // If len is always less then double, we can never overflow
                if (comptime @hasDecl(c, "JANET_32")) {
                    return c.janet_wrap_number(@floatFromInt(len));
                } else {
                    if (len < @as(usize, c.JANET_INTMAX_INT64)) {
                        return c.janet_wrap_number(@floatFromInt(len));
                    } else {
                        return pp_format.panicf("integer length %u too large", .{@as(u64, len)});
                    }
                }
            }
            var argv = [_]c.Janet{x};
            return try vm_calls.mcall("length", 1, &argv);
        },
        else => return pp_format.panicf("expected %T, got %v", .{ @as(c_int, c.JANET_TFLAG_LENGTHABLE), x }),
    }
}

export fn janet_lengthv(x: c.Janet) callconv(.c) c.Janet {
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
pub fn putIndex(ds: c.Janet, index: i32, value: c.Janet) raise.Raising(void) {
    switch (c.janet_type(ds)) {
        c.JANET_ARRAY => {
            const array = c.janet_unwrap_array(ds);
            if (index >= array.*.count) {
                c.janet_array_ensure(array, index +% 1, 2);
                var i = array.*.count;
                while (i < index +% 1) : (i += 1) {
                    array.*.data[asSize(i)] = c.janet_wrap_nil();
                }
                array.*.count = index +% 1;
            }
            array.*.data[asSize(index)] = value;
        },
        c.JANET_BUFFER => {
            const buffer = c.janet_unwrap_buffer(ds);
            if (c.janet_checkint(value) == 0)
                return pp_format.panicf("can only put integers in buffers, got %v", .{value});
            if (index >= buffer.*.count) {
                try containers.bufferEnsure(buffer, index +% 1, 2);
                @memset((buffer.*.data + asSize(buffer.*.count))[0..asSize(index +% 1 -% buffer.*.count)], 0);
                buffer.*.count = index +% 1;
            }
            buffer.*.data[asSize(index)] = @truncate(@as(u32, @bitCast(c.janet_unwrap_integer(value))));
        },
        c.JANET_TABLE => {
            const table = c.janet_unwrap_table(ds);
            c.janet_table_put(table, wrapInteger(index), value);
        },
        c.JANET_ABSTRACT => {
            const at = abstract_type.ofAbstract(c.janet_unwrap_abstract(ds));
            if (at.*.put) |callback| {
                try callback(c.janet_unwrap_abstract(ds), wrapInteger(index), value);
            } else {
                return pp_format.panicf("no setter for %v ", .{ds});
            }
        },
        else => return pp_format.panicf("expected %T, got %v", .{ @as(c_int, c.JANET_TFLAG_ARRAY | c.JANET_TFLAG_BUFFER | c.JANET_TFLAG_TABLE), ds }),
    }
}

export fn janet_putindex(ds: c.Janet, index: i32, value: c.Janet) callconv(.c) void {
    _ = raise.reported(putIndex(ds, index, value));
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
pub fn put(ds: c.Janet, key: c.Janet, value: c.Janet) raise.Raising(void) {
    const vtype = c.janet_type(ds);
    switch (vtype) {
        c.JANET_ARRAY => {
            const array = c.janet_unwrap_array(ds);
            const index = try getterCheckInt(vtype, key, std.math.maxInt(i32) - 1);
            if (index >= array.*.count) {
                c.janet_array_ensure(array, index + 1, 2);
                var i = array.*.count;
                while (i < index + 1) : (i += 1) {
                    array.*.data[asSize(i)] = c.janet_wrap_nil();
                }
                array.*.count = index + 1;
            }
            array.*.data[asSize(index)] = value;
        },
        c.JANET_BUFFER => {
            const buffer = c.janet_unwrap_buffer(ds);
            const index = try getterCheckInt(vtype, key, std.math.maxInt(i32) - 1);
            if (c.janet_checkint(value) == 0)
                return pp_format.panicf("can only put integers in buffers, got %v", .{value});
            if (index >= buffer.*.count) {
                try containers.bufferEnsure(buffer, index + 1, 2);
                @memset((buffer.*.data + asSize(buffer.*.count))[0..asSize(index + 1 - buffer.*.count)], 0);
                buffer.*.count = index + 1;
            }
            buffer.*.data[asSize(index)] = @truncate(@as(u32, @bitCast(c.janet_unwrap_integer(value))));
        },
        c.JANET_TABLE => c.janet_table_put(c.janet_unwrap_table(ds), key, value),
        c.JANET_ABSTRACT => {
            const at = abstract_type.ofAbstract(c.janet_unwrap_abstract(ds));
            if (at.*.put) |callback| {
                try callback(c.janet_unwrap_abstract(ds), key, value);
            } else {
                return pp_format.panicf("no setter for %v ", .{ds});
            }
        },
        else => return pp_format.panicf("expected %T, got %v", .{ @as(c_int, c.JANET_TFLAG_ARRAY | c.JANET_TFLAG_BUFFER | c.JANET_TFLAG_TABLE), ds }),
    }
}

export fn janet_put(ds: c.Janet, key: c.Janet, value: c.Janet) callconv(.c) void {
    _ = raise.reported(put(ds, key, value));
}
