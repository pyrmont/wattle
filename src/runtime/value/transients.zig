//! `core/transient`: a collection updated in place until it is made
//! persistent.
//!
//! A transient is an abstract whose payload is a `Transient`, and
//! `transient_type` is its type. `lib` installs `transient`, which makes one
//! from a vector, a map or a set; `conj!`, `assoc!`, `dissoc!` and `disj!`,
//! which change it in place and return it; and `persistent!`, which makes a
//! persistent collection of it and ends it. `fromVector`, `fromTree` and
//! `persistent` are the same for the runtime.
//!
//! One type serves every collection. The payload is a tagged union with an arm
//! for each collection a transient can hold, so `(type t)` does not say which
//! it holds, and each binding dispatches on the arm. A binding given a
//! transient of a collection it does not take refuses it by naming the
//! collection. How an update changes a collection's nodes in place is the
//! collection's own file: `vectors.zig`'s header has the rules for a vector,
//! and `maps.zig`'s for a map and a set.
//!
//! These rules hold for every transient:
//!
//! - A transient is made only from a persistent collection, so nothing makes a
//!   transient of a transient. The nodes a transient makes are reachable from
//!   it and from nothing else.
//!
//! - `persistent!` ends a transient, and every operation refuses once it has.
//!   The ended arm has no collection in it, so an ended transient keeps no
//!   nodes alive.
//!
//! - A transient is read with `length`, `get` and `in`, and is not indexed. A
//!   `chunk` callback cannot raise, so it could not refuse a read of an ended
//!   transient. `next` refuses, so `each` and what is built on it refuse a
//!   transient rather than reading it as empty.
//!
//! - The rules for a map's and a set's keys and values are the persistent
//!   collection's: a nil or NaN key raises when stored, a nil value removes
//!   its key, and a missing key reads as nil.

// ==========================================================================
// Project imports
// ==========================================================================

const abstract_type = @import("../../api/abstract_type.zig");
const abstracts = @import("abstracts.zig");
const args_core = @import("../args.zig");
const corefn = @import("../corefn.zig");
const maps = @import("maps.zig");
const pp_format = @import("../pp/format.zig");
const raise = @import("../../api/raise.zig");
const registry = @import("../registry.zig");
const repr = @import("repr");
const tables = @import("tables.zig");
const vectors = @import("vectors.zig");
const wrap = @import("helpers/wrap.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// What every operation on an ended transient raises.
const ended_message = "transient used after persistent!";

/// The abstract type a transient is.
pub const transient_type = abstract_type.define(Transient, .{
    .name = "core/transient",
    .gcmark = transientMark,
    .get = transientGet,
    .length = transientLength,
    .next = transientNext,
});

// ==========================================================================
// Types
// ==========================================================================

/// A transient's payload.
///
/// `fromVector` and `fromTree` return a `Transient`, and `persistent` takes
/// one. `vector`, `map` and `set` are a transient of that collection, and
/// `ended` is a transient `persistent!` has ended.
pub const Transient = union(enum) {
    ended,
    map: maps.Tree,
    set: maps.Tree,
    vector: vectors.Vector,
};

// ==========================================================================
// Public functions
// ==========================================================================

/// Allocates a transient of the map or set `t`, as `kind` says.
///
/// This function cannot raise. `t` does not change, and the transient shares
/// its nodes until an update copies them.
pub fn fromTree(t: *const maps.Tree, kind: maps.Kind) *Transient {
    const result = newTransient();
    result.* = switch (kind) {
        .map => .{ .map = maps.copyTree(t) },
        .set => .{ .set = maps.copyTree(t) },
    };
    return result;
}

/// Allocates a transient of `v`.
///
/// This function cannot raise. `v` does not change, and the transient shares
/// its nodes until an update copies them.
pub fn fromVector(v: *const vectors.Vector) *Transient {
    const result = newTransient();
    result.* = .{ .vector = v.* };
    // The payload copy brings the tail pointer with it, and an inline tail
    // belongs to `v`'s block: the transient would be pointing into a vector it
    // does not own, and marking from the transient would not keep that block
    // alive. So it takes a copy of its own.
    vectors.deinlineTail(&result.vector);
    return result;
}

/// Installs `transient`, `persistent!`, `conj!`, `assoc!`, `dissoc!` and
/// `disj!` into the core environment and registers `core/transient`.
///
/// `env` is the environment. This function raises if the registration does.
pub fn lib(env: *tables.Table) raise.Error!void {
    const entries = comptime [_]corefn.Entry{
        corefn.reg("transient", &nfunTransient, @src(), "(transient coll)", "Return a transient of the persistent vector, map or set `coll`, which `conj!`, `assoc!`, `dissoc!` and `disj!` change in place. `coll` itself does not change."),
        corefn.reg("persistent!", &nfunPersistent, @src(), "(persistent! coll)", "Return a persistent collection with the contents of the transient `coll`. Every later operation on `coll` raises an error."),
        corefn.reg("conj!", &nfunConjBang, @src(), "(conj! coll & xs)", "Add the elements xs to the transient `coll`, of a vector or a set, in place, and return it. For a transient of a vector, the elements are added at the end."),
        corefn.reg("assoc!", &nfunAssocBang, @src(), "(assoc! coll key val & kvs)", "Associate each key with the value that follows it in the transient `coll`, of a vector or a map, in place, and return it. For a transient of a vector, a key is an index from 0 up to the length, and a key equal to the length adds the value at the end. For a transient of a map, a nil value removes the key."),
        corefn.reg("dissoc!", &nfunDissocBang, @src(), "(dissoc! coll & ks)", "Remove the keys ks from the transient of a map `coll` in place, and return it."),
        corefn.reg("disj!", &nfunDisjBang, @src(), "(disj! coll & xs)", "Remove the elements xs from the transient of a set `coll` in place, and return it."),
    };
    corefn.install(env, entries);
    try registry.registerAbstractType(&transient_type);
}

/// Returns the persistent collection of `t`'s contents, and ends `t`.
///
/// This function cannot raise. `t` must not be ended, and an ended transient
/// is illegal behaviour.
pub fn persistent(t: *Transient) repr.Value {
    const result = switch (t.*) {
        .ended => unreachable,
        .map => |*m| wrap.fromMap(maps.persistent(m, .map)),
        .set => |*s| wrap.fromAbstract(maps.persistent(s, .set)),
        .vector => |*v| wrap.fromVector(vectors.persistent(v)),
    };
    t.* = .ended;
    return result;
}

// ==========================================================================
// Private functions
// ==========================================================================

/// `assoc!`: each key associated with its value in place.
fn nfunAssocBang(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 3, -1);
    const t = try getActive(argv);
    try vectors.checkPairs(argv);
    switch (t.*) {
        .ended => unreachable,
        .vector => |*v| {
            var i: usize = 1;
            while (i < argv.len) : (i += 2) {
                vectors.transientAssoc(v, try vectors.getIndex(argv, i, v.count), argv[i + 1]);
            }
        },
        .map => |*m| {
            var i: usize = 1;
            while (i < argv.len) : (i += 2) try maps.checkKey(argv[i]);
            i = 1;
            while (i < argv.len) : (i += 2) {
                if (repr.checkType(argv[i + 1], repr.Tag.nil)) {
                    maps.transientRemove(m, .map, argv[i]);
                } else {
                    maps.transientPut(m, .map, argv[i..][0..2]);
                }
            }
        },
        .set => return refuseArm(t, "a vector or a map"),
    }
    return argv[0];
}

/// `conj!`: the elements added in place.
fn nfunConjBang(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, -1);
    const t = try getActive(argv);
    switch (t.*) {
        .ended => unreachable,
        .vector => |*v| for (argv[1..]) |x| vectors.transientConj(v, x),
        .set => |*s| {
            for (argv[1..]) |x| try maps.checkKey(x);
            for (argv[1..]) |x| maps.transientPut(s, .set, &.{x});
        },
        .map => return refuseArm(t, "a vector or a set"),
    }
    return argv[0];
}

/// `disj!`: the elements removed in place.
fn nfunDisjBang(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, -1);
    const t = try getActive(argv);
    switch (t.*) {
        .ended => unreachable,
        .set => |*s| for (argv[1..]) |x| maps.transientRemove(s, .set, x),
        .vector, .map => return refuseArm(t, "a set"),
    }
    return argv[0];
}

/// `dissoc!`: the keys removed in place.
fn nfunDissocBang(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, -1);
    const t = try getActive(argv);
    switch (t.*) {
        .ended => unreachable,
        .map => |*m| for (argv[1..]) |key| maps.transientRemove(m, .map, key),
        .vector, .set => return refuseArm(t, "a map"),
    }
    return argv[0];
}

/// `persistent!`: the persistent collection, ending the transient.
fn nfunPersistent(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    return persistent(try getActive(argv));
}

/// `transient`: a transient of a persistent collection.
fn nfunTransient(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    if (vectors.toVector(argv[0])) |v| return wrap.fromAbstract(fromVector(v));
    if (maps.toTree(argv[0], .map)) |m| return wrap.fromAbstract(fromTree(m, .map));
    if (maps.toTree(argv[0], .set)) |s| return wrap.fromAbstract(fromTree(s, .set));
    return pp_format.panicf("bad slot #0, expected vector, map or core/set, got %v", .{argv[0]});
}

/// The transient in the first argument, refused where `persistent!` has ended
/// it.
fn getActive(argv: []const repr.Value) raise.Error!*Transient {
    const t = try args_core.getAbstract(Transient, argv, 0, &transient_type);
    if (t.* == .ended) return raise.panic(ended_message);
    return t;
}

/// Allocates a transient, which the caller fills.
fn newTransient() *Transient {
    return @ptrCast(@alignCast(abstracts.newBytes(&transient_type, @sizeOf(Transient))));
}

/// Refuses a transient of a collection the binding does not take, naming the
/// collections it does and the one `t` holds.
fn refuseArm(t: *const Transient, comptime expected: []const u8) raise.Error {
    const held: [*:0]const u8 = switch (t.*) {
        .ended => unreachable,
        .map => "a map",
        .set => "a set",
        .vector => "a vector",
    };
    return pp_format.panicf("expected a transient of " ++ expected ++ ", got a transient of %s", .{held});
}

/// `core/transient`'s `get` callback: the collection's entry at `key`.
///
/// A transient of a map or a set reads as the persistent collection does: a
/// missing key is reported as found with nil, so `in` gives nil for it.
fn transientGet(t: *Transient, key: repr.Value) raise.Error!?repr.Value {
    return switch (t.*) {
        .ended => raise.panic(ended_message),
        .map => |*m| if (maps.find(m, .map, key)) |entry| entry[1] else wrap.fromNil(),
        .set => |*s| if (maps.find(s, .set, key)) |entry| entry[0] else wrap.fromNil(),
        .vector => |*v| vectors.lookup(v, key),
    };
}

/// `core/transient`'s `length` callback.
fn transientLength(t: *Transient, _: usize) raise.Error!usize {
    return switch (t.*) {
        .ended => raise.panic(ended_message),
        .map, .set => |*tree| tree.count,
        .vector => |*v| v.count,
    };
}

/// `core/transient`'s `gcmark` callback: the collection's nodes.
fn transientMark(t: *Transient, _: usize) void {
    switch (t.*) {
        .ended => {},
        .map, .set => |*tree| maps.mark(tree),
        .vector => |*v| vectors.mark(v),
    }
}

/// `core/transient`'s `next` callback, which refuses.
fn transientNext(t: *Transient, _: repr.Value) raise.Error!repr.Value {
    if (t.* == .ended) return raise.panic(ended_message);
    return raise.panic("a transient cannot be iterated; call persistent! first");
}
