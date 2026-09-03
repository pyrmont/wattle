//! Access: reaching inside a Janet value by index or by key, and the iteration
//! protocol beneath `next`. An operation rather than a type, so the verbs stay:
//! `access.in(ds, k)`, `access.get(ds, k)`, `access.next(ds, k)`.
//!
//! **Panicking is these functions' contract.** `in` raises on a missing key and
//! `length` on a value with no length, which is the opposite constraint from a
//! getter in the argument layer: a getter must not raise and so cannot afford a
//! formatter that allocates. These can, so they format their own messages.
//! Every panic arm below is a `return` of a raising call, so none needs an
//! `unreachable` after it.
//!
//! **The rendered messages are a tested fact rather than an assumed one.**
//! Formatting one passes a `Value` by value through a variadic `extern` call,
//! and a `Value`'s layout changes under `-Dnanbox=false` from an eight-byte
//! union to a sixteen-byte struct -- the size class where the C ABI's
//! classification rules diverge. `test/value_access.zig` asserts the rendered
//! text byte for byte for all twelve messages, under both value layouts and on
//! every platform in the acceptance matrix.
//!
//! **The two lookup families are not one function.** `in` and `get` answer the
//! same question and differ in what a failure is -- `in` panics on a bad key
//! and `get` returns nil -- and that difference runs all the way down: whether
//! a non-integer key on a tuple is an error, whether an abstract type with no
//! `get` callback is an error, whether a fiber accepts a key other than zero.
//! `getIndex` is a third answer again, taking an `i32` rather than a `Value`,
//! panicking only on a negative index and a missing setter and answering nil
//! for everything else. Factoring the three into one function with a policy
//! flag would put a branch on the VM's hot path to save thirty lines.

const std = @import("std");
const raise = @import("../../../api/raise.zig");
const pp_format = @import("../../pp/format.zig");
const vm_calls = @import("../../vm.zig");
const abstract_type = @import("../../../api/abstract_type.zig");
const buffers = @import("../buffers.zig");
const config = @import("config");
const structs = @import("../structs.zig");
const tables = @import("../tables.zig");
const arrays = @import("../arrays.zig");
const utils = @import("../../utils.zig");
const order = @import("order.zig");
const fibers = @import("../fibers.zig");
const wrap = @import("wrap.zig");
const args_core = @import("../../args.zig");
const value = @import("../../value.zig");
const repr = @import("repr");
const constants = @import("constants");
const vm_state = @import("../../vm/state.zig");
const vm_entry = @import("../../vm/entry.zig");
const strings = @import("../strings.zig");
const tuples = @import("../tuples.zig");
const abi = @import("abi");

/// One bucket forward from `p`, in address space rather than pointer space,
/// because `p` may be null: `nextImpl` computes `value.dictionaryFind(...) + 1`
/// and `dictionaryFind` answers null when it finds neither the key, nor an
/// empty bucket, nor a tombstone.
///
/// No dictionary a caller can build reaches that state -- every constructor
/// rounds its capacity up through `value.capacityFor`, so a dictionary always
/// has a spare bucket, and a zero-capacity table, which no constructor
/// produces, dies inside `dictionaryFind` rather than returning from it. The
/// arithmetic is on `usize` so that it stays defined for whatever makes it
/// reachable later.
inline fn nextBucket(p: ?*const tables.KV) *const tables.KV {
    return @ptrFromInt(@intFromPtr(p) +% @sizeOf(tables.KV));
}

// ------------------------------------------------------------------ next

/// The public entry, which is `nextImpl` with the
/// interpreter flag clear -- so a signal from a resumed fiber becomes a panic
/// rather than being re-raised. Nothing in the tree calls it; `run_vm` always
/// passes the flag set. It exists for a module, and a module is the one caller
/// that may reach the fiber arm with no fiber of its own running.
pub fn next(ds: repr.Value, key: repr.Value) raise.Raising(repr.Value) {
    return nextImpl(ds, key, false);
}

/// Given a data structure and the previous key, produce the next key, or nil
/// when there is none. Four arms answer it in four unrelated ways, and
/// everything else panics.
///
/// **The fiber arm resumes an arbitrary fiber, and a raise from it passes
/// through this frame.** One piece of state has to survive that raise and is
/// handled by hand rather than by scope: the child fiber is parked in
/// `vm.fiber.child` across the resume, and the slot is cleared *before* the
/// panic on the non-interpreter path and deliberately **not** cleared before
/// the signal on the interpreter path, because the interpreter unwinds through
/// the fiber chain and needs the link. Writing that as a `defer` would clear it
/// on both paths and break the second.
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
/// which is the opposite of what `in` does with the same key.
///
/// The fiber case is what makes `next` a protocol rather than a traversal:
/// iterating a fiber *runs* it. The key it returns is always the integer zero,
/// because a fiber has no meaningful index; what the caller does with it is
/// fetch `last_value` through `in`, which is what the accessors' fiber arms
/// exist for. A fiber that cannot be
/// resumed answers nil immediately, and one that finishes during the resume
/// answers nil on the way out.
///
/// This is not a published symbol. `next` is the one caller outside the
/// interpreter, and it reaches it by `@import`.
pub fn nextImpl(ds: repr.Value, key: repr.Value, is_interpreter: bool) raise.Raising(repr.Value) {
    const t = repr.typeOf(ds);
    switch (t) {
        repr.Tag.table, repr.Tag.@"struct" => {
            var cap: i32 = undefined;
            var start: [*]const tables.KV = undefined;
            if (t == repr.Tag.table) {
                const tab = wrap.toTable(ds);
                cap = @intCast(tab.capacity);
                start = tab.data.?;
            } else {
                const st = wrap.toStruct(ds);
                cap = @intCast(structs.head(st).capacity);
                start = st;
            }
            const end = start + utils.asSize(cap);
            var kv: [*]const tables.KV = if (repr.checkType(key, repr.Tag.nil))
                start
            else
                @ptrCast(nextBucket(value.dictionaryFind(start[0..@intCast(cap)], key)));
            while (@intFromPtr(kv) < @intFromPtr(end)) : (kv += 1) {
                if (!repr.checkType(kv[0].key, repr.Tag.nil)) return kv[0].key;
            }
        },
        repr.Tag.string, repr.Tag.keyword, repr.Tag.symbol, repr.Tag.buffer, repr.Tag.array, repr.Tag.tuple => {
            var i: i32 = undefined;
            if (repr.checkType(key, repr.Tag.nil)) {
                i = 0;
            } else if (args_core.checkint(key)) {
                // The last representable index has no successor, so iteration
                // ends there rather than wrapping to `INT32_MIN` and being
                // rejected by the range test below.
                const previous = wrap.toInteger(key);
                if (previous == std.math.maxInt(i32)) return wrap.fromNil();
                i = previous + 1;
            } else {
                return wrap.fromNil();
            }
            const len: i32 = if (t == repr.Tag.buffer)
                @as(i32, @intCast(wrap.toBuffer(ds).count))
            else if (t == repr.Tag.array)
                @as(i32, @intCast(wrap.toArray(ds).count))
            else if (t == repr.Tag.tuple)
                @intCast(tuples.head(wrap.toTuple(ds)).length)
            else
                @intCast(strings.head(wrap.toString(ds)).length);
            if (i < len and i >= 0) {
                return wrap.fromInteger(i);
            }
        },
        repr.Tag.abstract => {
            const abst = wrap.toAbstract(ds);
            const at = abstract_type.ofAbstract(abst);
            const callback = at.next orelse return wrap.fromNil();
            return callback(abst, key);
        },
        repr.Tag.fiber => {
            const child = wrap.toFiber(ds);
            var retreg: repr.Value = undefined;
            const status = fibers.status(child);
            if (status == fibers.FiberStatus.alive or
                status == fibers.FiberStatus.dead or
                status == fibers.FiberStatus.@"error" or
                status == fibers.FiberStatus.user0 or
                status == fibers.FiberStatus.user1 or
                status == fibers.FiberStatus.user2 or
                status == fibers.FiberStatus.user3 or
                status == fibers.FiberStatus.user4)
            {
                return wrap.fromNil();
            }
            // **Only when there is a fiber to link into.** The parent link
            // is what puts the resumed fiber on the caller's chain so a trace
            // or `debug/lineage` can see it; with no fiber running there is no
            // chain, which is the state an embedder calling `next` from its
            // own code is in. The interpreter always has one.
            const parent = vm_state.current().fiber;
            if (parent) |p| p.child = child;
            const resumed = vm_entry.continueFiber(child, wrap.fromNil());
            const sig = resumed.signal;
            retreg = resumed.value;
            if (sig != abi.Signal.ok and !child.flags.traps.has(sig)) {
                if (is_interpreter) {
                    // Deliberately without clearing `child` first: the
                    // interpreter unwinds through the fiber chain and the link
                    // has to still be there when it does.
                    return raise.signal(sig, retreg);
                } else {
                    if (parent) |p| p.child = null;
                    return raise.panicv(retreg);
                }
            }
            if (parent) |p| p.child = null;
            if (sig == abi.Signal.ok or
                sig == abi.Signal.@"error" or
                sig == abi.Signal.user0 or
                sig == abi.Signal.user1 or
                sig == abi.Signal.user2 or
                sig == abi.Signal.user3 or
                sig == abi.Signal.user4)
            {
                // Fiber cannot be resumed, so discard last value.
                return wrap.fromNil();
            } else {
                return wrap.fromInteger(0);
            }
        },
        else => return pp_format.panicf("expected iterable type, got %v", .{ds}),
    }
    return wrap.fromNil();
}

// ------------------------------------------------------------- the getters

/// The bounds check the panicking accessors share: a key has to be an integer,
/// non-negative, and below `max`, and any of the three failing produces the
/// same message. `badKey` is the one copy of it.
fn getterCheckInt(vtype: repr.Tag, key: repr.Value, max: i32) raise.Raising(i32) {
    if (!args_core.checkint(key)) return badKey(vtype, key, max);
    const ret = wrap.toInteger(key);
    if (ret < 0) return badKey(vtype, key, max);
    if (ret >= max) return badKey(vtype, key, max);
    return ret;
}

fn badKey(vtype: repr.Tag, key: repr.Value, max: i32) raise.Error {
    return pp_format.panicf("expected integer key for %s in range [0, %d), got %v", .{ utils.typeNames[@intFromEnum(vtype)], @as(c_int, max), key });
}

/// Keyed access that treats a bad key as an error. This is `(in ds k)` and the
/// VM's `GETINDEX`-family read.
///
/// The two dictionary types answer through `structs.get` and `tables.get`,
/// which means a key that is simply absent yields nil
/// rather than panicking -- the panic here is about keys that are *wrong* for
/// the container, not keys that are missing from it. For the four sequence
/// types the key must be an integer in range, which is `getterCheckInt`.
///
/// An abstract type is the one place where a missing key does panic, because
/// its `get` callback reports presence separately from the value it produces,
/// and absence is defined as an error here. The trailing space in that message
/// is part of the text a program sees and is not a typo to tidy.
pub fn in(ds: repr.Value, key: repr.Value) raise.Raising(repr.Value) {
    var val: repr.Value = undefined;
    const vtype = repr.typeOf(ds);
    switch (vtype) {
        repr.Tag.@"struct" => val = structs.get(wrap.toStruct(ds), key),
        repr.Tag.table => val = tables.get(wrap.toTable(ds), key),
        repr.Tag.array => {
            const array = wrap.toArray(ds);
            const index = getterCheckInt(vtype, key, @intCast(array.count));
            val = array.slice()[utils.asSize(try index)];
        },
        repr.Tag.tuple => {
            const tuple = wrap.toTuple(ds);
            const len = tuples.head(tuple).length;
            val = tuple[utils.asSize(try getterCheckInt(vtype, key, @intCast(len)))];
        },
        repr.Tag.buffer => {
            const buffer = wrap.toBuffer(ds);
            const index = getterCheckInt(vtype, key, @intCast(buffer.count));
            val = wrap.fromInteger(buffer.slice()[utils.asSize(try index)]);
        },
        repr.Tag.string, repr.Tag.symbol, repr.Tag.keyword => {
            const str = wrap.toString(ds);
            const index = getterCheckInt(vtype, key, @intCast(strings.head(str).length));
            val = wrap.fromInteger(str[utils.asSize(try index)]);
        },
        repr.Tag.abstract => {
            const at = abstract_type.ofAbstract(wrap.toAbstract(ds));
            if (at.get) |getter| {
                val = try getter(wrap.toAbstract(ds), key) orelse
                    return pp_format.panicf("key %v not found in %v ", .{ key, ds });
            } else {
                return pp_format.panicf("no getter for %v", .{ds});
            }
        },
        repr.Tag.fiber => {
            // Bit of a hack to allow iterating over fibers.
            if (order.equals(key, wrap.fromInteger(0))) {
                return wrap.toFiber(ds).last_value;
            } else {
                return pp_format.panicf("expected key 0, got %v", .{key});
            }
        },
        else => return pp_format.panicf("expected %T, got %v", .{ repr.TagSet.lengthable, ds }),
    }
    return val;
}

/// Keyed access that treats every failure as nil. This is `(get
/// ds k)`, and it accepts anything at all as `ds` -- a number, a function, nil
/// -- because the `default` arm returns nil rather than panicking.
///
/// The array, tuple and buffer arm shares one integer check across three
/// containers, which is why it is written as a nested `if` on the type rather
/// than as three cases.
pub fn get(ds: repr.Value, key: repr.Value) raise.Raising(repr.Value) {
    const t = repr.typeOf(ds);
    switch (t) {
        repr.Tag.string, repr.Tag.symbol, repr.Tag.keyword => {
            if (!args_core.checkint(key)) return wrap.fromNil();
            const index = wrap.toInteger(key);
            if (index < 0) return wrap.fromNil();
            const str = wrap.toString(ds);
            if (index >= strings.head(str).length) return wrap.fromNil();
            return wrap.fromInteger(str[utils.asSize(index)]);
        },
        repr.Tag.abstract => {
            const abst = wrap.toAbstract(ds);
            const at = abstract_type.ofAbstract(abst);
            const getter = at.get orelse return wrap.fromNil();
            return try getter(abst, key) orelse wrap.fromNil();
        },
        repr.Tag.array, repr.Tag.tuple, repr.Tag.buffer => {
            if (!args_core.checkint(key)) return wrap.fromNil();
            const index = wrap.toInteger(key);
            if (index < 0) return wrap.fromNil();
            if (t == repr.Tag.array) {
                const a = wrap.toArray(ds);
                if (index >= a.count) return wrap.fromNil();
                return a.slice()[utils.asSize(index)];
            } else if (t == repr.Tag.buffer) {
                const b = wrap.toBuffer(ds);
                if (index >= b.count) return wrap.fromNil();
                return wrap.fromInteger(b.slice()[utils.asSize(index)]);
            } else {
                const tup = wrap.toTuple(ds);
                if (index >= tuples.head(tup).length) return wrap.fromNil();
                return tup[utils.asSize(index)];
            }
        },
        repr.Tag.table => {
            return tables.get(wrap.toTable(ds), key);
        },
        repr.Tag.@"struct" => {
            const st = wrap.toStruct(ds);
            return structs.get(st, key);
        },
        repr.Tag.fiber => {
            // Bit of a hack to allow iterating over fibers.
            if (order.equals(key, wrap.fromInteger(0))) {
                return wrap.toFiber(ds).last_value;
            } else {
                return wrap.fromNil();
            }
        },
        else => return wrap.fromNil(),
    }
}

/// Access by a machine integer rather than a `Value`, which
/// is a third failure policy again: a negative index panics, a value with no
/// indexed access panics, an abstract type with no `get` callback panics, and
/// everything else -- including an index past the end and an abstract `get`
/// that reports absence -- yields nil.
///
/// The asymmetry in the abstract arm is worth naming, because it is the
/// difference between this and `in` on the same value: both panic when
/// the type has no `get` at all, but a `get` that runs and reports absence is
/// an error to `in` and a nil to `getIndex`.
pub fn getIndex(ds: repr.Value, index: i32) raise.Raising(repr.Value) {
    var val: repr.Value = undefined;
    if (index < 0) return raise.panic("expected non-negative index");
    switch (repr.typeOf(ds)) {
        repr.Tag.string, repr.Tag.symbol, repr.Tag.keyword => {
            if (index >= strings.head(wrap.toString(ds)).length) {
                val = wrap.fromNil();
            } else {
                val = wrap.fromInteger(wrap.toString(ds)[utils.asSize(index)]);
            }
        },
        repr.Tag.array => {
            if (index >= wrap.toArray(ds).count) {
                val = wrap.fromNil();
            } else {
                val = wrap.toArray(ds).slice()[utils.asSize(index)];
            }
        },
        repr.Tag.buffer => {
            if (index >= wrap.toBuffer(ds).count) {
                val = wrap.fromNil();
            } else {
                val = wrap.fromInteger(wrap.toBuffer(ds).slice()[utils.asSize(index)]);
            }
        },
        repr.Tag.tuple => {
            if (index >= tuples.head(wrap.toTuple(ds)).length) {
                val = wrap.fromNil();
            } else {
                val = wrap.toTuple(ds)[utils.asSize(index)];
            }
        },
        repr.Tag.table => val = tables.get(wrap.toTable(ds), wrap.fromInteger(index)),
        repr.Tag.@"struct" => val = structs.get(wrap.toStruct(ds), wrap.fromInteger(index)),
        repr.Tag.abstract => {
            const at = abstract_type.ofAbstract(wrap.toAbstract(ds));
            if (at.get) |getter| {
                val = try getter(wrap.toAbstract(ds), wrap.fromInteger(index)) orelse wrap.fromNil();
            } else {
                return pp_format.panicf("no getter for %v", .{ds});
            }
        },
        repr.Tag.fiber => {
            if (index == 0) {
                val = wrap.toFiber(ds).last_value;
            } else {
                val = wrap.fromNil();
            }
        },
        else => return pp_format.panicf("expected %T, got %v", .{ repr.TagSet.lengthable, ds }),
    }
    return val;
}

// ------------------------------------------------------------- the lengths

/// The length as a machine integer.
///
/// Six of the seven built-in cases read a count that is already an `int32_t`.
/// The abstract case is the one that can fail, and it fails in two different
/// ways depending on which of two mechanisms answers: a `length` callback
/// returns a `usize`, which is rejected when it exceeds `INT32_MAX`; a type
/// without one is asked for a `length` *method* through `vm_calls.mcall`, which
/// returns a `Value` and is rejected when that is not an integer. Two
/// rejections, two messages, two format specifiers.
///
/// **The rejection message renders that `usize` with `%u`**, which the
/// formatter reads as a `u64`. The two agree only where a `usize` is 64 bits,
/// which is every target this project builds for; the widening is what keeps
/// the rendering identical there.
pub fn length(x: repr.Value) raise.Raising(i32) {
    switch (repr.typeOf(x)) {
        repr.Tag.string, repr.Tag.symbol, repr.Tag.keyword => return @intCast(strings.head(wrap.toString(x)).length),
        repr.Tag.array => return @intCast(wrap.toArray(x).count),
        repr.Tag.buffer => return @intCast(wrap.toBuffer(x).count),
        repr.Tag.tuple => return @intCast(tuples.head(wrap.toTuple(x)).length),
        repr.Tag.@"struct" => return @intCast(structs.head(wrap.toStruct(x)).length),
        repr.Tag.table => return @intCast(wrap.toTable(x).count),
        repr.Tag.abstract => {
            const abst = wrap.toAbstract(x);
            const at = abstract_type.ofAbstract(abst);
            if (at.length) |callback| {
                const len = try callback(abst, utils.abstractHead(abst).size);
                if (len > @as(usize, @intCast(std.math.maxInt(i32)))) {
                    return pp_format.panicf("invalid integer length %u", .{@as(u64, len)});
                }
                return @intCast(len);
            }
            var argv = [_]repr.Value{x};
            const len = try vm_calls.mcall("length", &argv);
            // **Both ends of the range, in one rule.** The slot arm above
            // refuses a length past `maxInt(i32)` because no caller can use
            // one; a Janet-level `:length` method may answer a *negative*,
            // which `checkint` accepts and no caller can use either. Refusing
            // it here rather than at each caller is what lets every reader of
            // this function's `i32` treat it as a count. `DESIGN.md` section
            // 12 has the decision.
            if (!args_core.checkint(len) or wrap.toInteger(len) < 0)
                return pp_format.panicf("invalid integer length %v", .{len});
            return wrap.toInteger(len);
        },
        else => return pp_format.panicf("expected %T, got %v", .{ repr.TagSet.lengthable, x }),
    }
}

/// The length as a `Value`, which exists so that an abstract
/// type longer than `INT32_MAX` can answer at all: the value is wrapped as a
/// double rather than truncated, and the bound moves from `INT32_MAX` to
/// `JANET_INTMAX_INT64`, the largest integer a double represents exactly.
///
/// The 32-bit arm has no bound because it cannot need one -- a `usize` there is
/// 32 bits, so every value it can hold is exactly representable. It is a
/// `comptime` branch rather than a deletion, even though no target this project
/// builds for selects it.
pub fn lengthv(x: repr.Value) raise.Raising(repr.Value) {
    switch (repr.typeOf(x)) {
        repr.Tag.string, repr.Tag.symbol, repr.Tag.keyword => return wrap.fromInteger(@intCast(strings.head(wrap.toString(x)).length)),
        repr.Tag.array => return wrap.fromInteger(@intCast(wrap.toArray(x).count)),
        repr.Tag.buffer => return wrap.fromInteger(@intCast(wrap.toBuffer(x).count)),
        repr.Tag.tuple => return wrap.fromInteger(@intCast(tuples.head(wrap.toTuple(x)).length)),
        repr.Tag.@"struct" => return wrap.fromInteger(@intCast(structs.head(wrap.toStruct(x)).length)),
        repr.Tag.table => return wrap.fromInteger(@intCast(wrap.toTable(x).count)),
        repr.Tag.abstract => {
            const abst = wrap.toAbstract(x);
            const at = abstract_type.ofAbstract(abst);
            if (at.length) |callback| {
                const len = try callback(abst, utils.abstractHead(abst).size);
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
            var argv = [_]repr.Value{x};
            const len = try vm_calls.mcall("length", &argv);
            // **A length, and this is the arm the `length` builtin reaches.**
            // `checksize` is the whole rule -- a number, integral, and in
            // `[0, maxInt(usize)]` -- so a method answering a negative, a
            // fraction or something that is not a number at all is refused
            // here rather than handed on as a length. `length` above asks
            // `checkint` for the same three things against a narrower bound,
            // which is the one documented difference between these two
            // functions.
            if (!args_core.checksize(len)) {
                return pp_format.panicf("invalid integer length %v", .{len});
            }
            return len;
        },
        else => return pp_format.panicf("expected %T, got %v", .{ repr.TagSet.lengthable, x }),
    }
}

// ------------------------------------------------------------- the setters

/// Write by a machine integer. Three container types accept
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
/// **The index is bounded exactly as `put` bounds its key**, and for the same
/// reason: the growth arms compute `index + 1`, and the last representable
/// index has no successor. The interpreter reaches here with a bytecode
/// immediate and cannot exceed it; a module computing an index can.
pub fn putIndex(ds: repr.Value, index: i32, val: repr.Value) raise.Raising(void) {
    const vtype = repr.typeOf(ds);
    switch (vtype) {
        repr.Tag.array => {
            const array = wrap.toArray(ds);
            _ = try getterCheckInt(vtype, wrap.fromInteger(index), std.math.maxInt(i32) - 1);
            if (index >= array.count) {
                arrays.ensure(array, @intCast(index + 1), 2);
                @memset(array.reserved()[array.count..utils.asSize(index + 1)], wrap.fromNil());
                array.count = @intCast(index + 1);
            }
            array.slice()[utils.asSize(index)] = val;
        },
        repr.Tag.buffer => {
            const buffer = wrap.toBuffer(ds);
            _ = try getterCheckInt(vtype, wrap.fromInteger(index), std.math.maxInt(i32) - 1);
            if (!args_core.checkint(val))
                return pp_format.panicf("can only put integers in buffers, got %v", .{val});
            if (index >= buffer.count) {
                try buffers.ensure(buffer, @intCast(index + 1), 2);
                @memset(buffer.reserved()[buffer.count..utils.asSize(index + 1)], 0);
                buffer.count = @intCast(index + 1);
            }
            buffer.slice()[utils.asSize(index)] = @truncate(@as(u32, @bitCast(wrap.toInteger(val))));
        },
        repr.Tag.table => {
            const table = wrap.toTable(ds);
            tables.put(table, wrap.fromInteger(index), val);
        },
        repr.Tag.abstract => {
            const at = abstract_type.ofAbstract(wrap.toAbstract(ds));
            if (at.put) |callback| {
                try callback(wrap.toAbstract(ds), wrap.fromInteger(index), val);
            } else {
                return pp_format.panicf("no setter for %v ", .{ds});
            }
        },
        else => return pp_format.panicf("expected %T, got %v", .{ repr.TagSet.of(&.{ .array, .buffer, .table }), ds }),
    }
}

/// Write by a `Value` key. The array and buffer arms are
/// `putIndex`'s body with a `getterCheckInt` in front, bounded at
/// `INT32_MAX - 1` so that the `index + 1` below it cannot overflow.
///
/// The two are not factored together, even though the bodies below the check
/// are identical, because the order in which each raises is observable: `put` on
/// a buffer checks the *key* before the value, so `(put @"" :x :y)` complains
/// about the key and `(put @"" 0 :y)` complains about the value.
pub fn put(ds: repr.Value, key: repr.Value, val: repr.Value) raise.Raising(void) {
    const vtype = repr.typeOf(ds);
    switch (vtype) {
        repr.Tag.array => {
            const array = wrap.toArray(ds);
            const index = try getterCheckInt(vtype, key, std.math.maxInt(i32) - 1);
            if (index >= array.count) {
                arrays.ensure(array, @intCast(index + 1), 2);
                @memset(array.reserved()[array.count..utils.asSize(index + 1)], wrap.fromNil());
                array.count = @intCast(index + 1);
            }
            array.slice()[utils.asSize(index)] = val;
        },
        repr.Tag.buffer => {
            const buffer = wrap.toBuffer(ds);
            const index = try getterCheckInt(vtype, key, std.math.maxInt(i32) - 1);
            if (!args_core.checkint(val))
                return pp_format.panicf("can only put integers in buffers, got %v", .{val});
            if (index >= buffer.count) {
                try buffers.ensure(buffer, @intCast(index + 1), 2);
                @memset(buffer.reserved()[buffer.count..utils.asSize(index + 1)], 0);
                buffer.count = @intCast(index + 1);
            }
            buffer.slice()[utils.asSize(index)] = @truncate(@as(u32, @bitCast(wrap.toInteger(val))));
        },
        repr.Tag.table => tables.put(wrap.toTable(ds), key, val),
        repr.Tag.abstract => {
            const at = abstract_type.ofAbstract(wrap.toAbstract(ds));
            if (at.put) |callback| {
                try callback(wrap.toAbstract(ds), key, val);
            } else {
                return pp_format.panicf("no setter for %v ", .{ds});
            }
        },
        else => return pp_format.panicf("expected %T, got %v", .{ repr.TagSet.of(&.{ .array, .buffer, .table }), ds }),
    }
}
