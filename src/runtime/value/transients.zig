//! `core/transient`: a collection updated in place until it is made
//! persistent.
//!
//! A transient is an abstract whose payload is a `Transient`, and
//! `transient_type` is its type. `lib` installs `transient`, which makes one
//! from a vector, `conj!` and `assoc!`, which change it in place and return it,
//! and `persistent!`, which makes a vector of it and ends it. `fromVector` and
//! `persistent` are the same two for the runtime.
//!
//! One type serves every collection. The payload is a tagged union with an arm
//! for each collection a transient can hold, so `(type t)` does not say which
//! it holds, and each binding dispatches on the arm. How an update changes a
//! collection's nodes in place is the collection's own file:
//! `vectors.zig`'s header has the rules for a vector.
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

// ==========================================================================
// Project imports
// ==========================================================================

const abstract_type = @import("../../api/abstract_type.zig");
const abstracts = @import("abstracts.zig");
const args_core = @import("../args.zig");
const corefn = @import("../corefn.zig");
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
/// `fromVector` returns a `Transient`, and `persistent` takes one. `vector` is
/// a transient of a vector, and `ended` is a transient `persistent!` has
/// ended.
pub const Transient = union(enum) {
    ended,
    vector: vectors.Vector,
};

// ==========================================================================
// Public functions
// ==========================================================================

/// Allocates a transient of `v`.
///
/// This function cannot raise. `v` does not change, and the transient shares
/// its nodes until an update copies them.
pub fn fromVector(v: *const vectors.Vector) *Transient {
    const t: *Transient = @ptrCast(@alignCast(abstracts.newBytes(&transient_type, @sizeOf(Transient))));
    t.* = .{ .vector = v.* };
    return t;
}

/// Installs `transient`, `persistent!`, `conj!` and `assoc!` into the core
/// environment and registers `core/transient`.
///
/// `env` is the environment. This function raises if the registration does.
pub fn lib(env: *tables.Table) raise.Error!void {
    const entries = comptime [_]corefn.Entry{
        corefn.reg("transient", &cfunTransient, @src(), "(transient coll)", "Return a transient of the persistent collection `coll`, which `conj!` and `assoc!` change in place. `coll` itself does not change."),
        corefn.reg("persistent!", &cfunPersistent, @src(), "(persistent! coll)", "Return a persistent collection with the contents of the transient `coll`. Every later operation on `coll` raises an error."),
        corefn.reg("conj!", &cfunConjBang, @src(), "(conj! coll & xs)", "Add the elements xs to the transient `coll` in place, and return it. For a transient of a vector, the elements are added at the end."),
        corefn.reg("assoc!", &cfunAssocBang, @src(), "(assoc! coll key val & kvs)", "Associate each key with the value that follows it in the transient `coll` in place, and return it. For a transient of a vector, a key is an index from 0 up to the length, and a key equal to the length adds the value at the end."),
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
        .vector => |*v| wrap.fromAbstract(vectors.persistent(v)),
    };
    t.* = .ended;
    return result;
}

// ==========================================================================
// Private functions
// ==========================================================================

/// `assoc!`: each key associated with its value in place.
fn cfunAssocBang(argv: []repr.Value) raise.Error!repr.Value {
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
    }
    return argv[0];
}

/// `conj!`: the elements added in place.
fn cfunConjBang(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, -1);
    const t = try getActive(argv);
    switch (t.*) {
        .ended => unreachable,
        .vector => |*v| for (argv[1..]) |x| vectors.transientConj(v, x),
    }
    return argv[0];
}

/// `persistent!`: the persistent collection, ending the transient.
fn cfunPersistent(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    return persistent(try getActive(argv));
}

/// `transient`: a transient of a persistent collection.
fn cfunTransient(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const v = try args_core.getAbstract(vectors.Vector, argv, 0, &vectors.vector_type);
    return wrap.fromAbstract(fromVector(v));
}

/// The transient in the first argument, refused where `persistent!` has ended
/// it.
fn getActive(argv: []const repr.Value) raise.Error!*Transient {
    const t = try args_core.getAbstract(Transient, argv, 0, &transient_type);
    if (t.* == .ended) return raise.panic(ended_message);
    return t;
}

/// `core/transient`'s `get` callback: the collection's element at `key`.
fn transientGet(t: *Transient, key: repr.Value) raise.Error!?repr.Value {
    return switch (t.*) {
        .ended => raise.panic(ended_message),
        .vector => |*v| vectors.lookup(v, key),
    };
}

/// `core/transient`'s `length` callback.
fn transientLength(t: *Transient, _: usize) raise.Error!usize {
    return switch (t.*) {
        .ended => raise.panic(ended_message),
        .vector => |*v| v.count,
    };
}

/// `core/transient`'s `gcmark` callback: the collection's nodes.
fn transientMark(t: *Transient, _: usize) void {
    switch (t.*) {
        .ended => {},
        .vector => |*v| vectors.mark(v),
    }
}

/// `core/transient`'s `next` callback, which refuses.
fn transientNext(t: *Transient, _: repr.Value) raise.Error!repr.Value {
    if (t.* == .ended) return raise.panic(ended_message);
    return raise.panic("a transient cannot be iterated; call persistent! first");
}
