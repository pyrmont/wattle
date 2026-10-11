//! The `crypto/` library: `crypto/hash`, `crypto/hasher`, `crypto/update!`,
//! `crypto/digest`, `crypto/hmac` and `crypto/equal?`.
//!
//! `env.zig`'s `loadLibs` calls `libCrypto` in every configuration. The
//! digests, the keyed digests and the streaming state are `std.crypto`'s, so
//! this file holds argument extraction and the abstract type, and no
//! cryptographic code.
//!
//! ## Algorithms and results
//!
//! An _algorithm_ is the keyword `:sha256`, `:sha512` or `:blake3`. A digest is
//! a string of raw bytes: 32 bytes for `:sha256` and `:blake3`, and 64 for
//! `:sha512`. The functions return no hex text, because a caller that stores
//! or compares a digest wants the bytes, and `string/format` with `%02x`
//! spells them.
//!
//! `crypto/hmac` accepts `:sha256` and `:sha512`. `:blake3` has a keyed mode
//! of its own with a fixed key length, which is a different function, so it is
//! refused rather than answered with a construction that is not HMAC.
//!
//! ## The streaming state
//!
//! `crypto/hasher` returns a `crypto/hasher`, an abstract that holds the state
//! of one algorithm. `crypto/update!` adds bytes to it, and `crypto/digest`
//! returns the digest of the bytes added so far and leaves the state as it
//! was, so more bytes can follow. The state has no `marshal` callback, so
//! marshalling a hasher raises.
//!
//! ## Comparison
//!
//! `crypto/equal?` compares two byte sequences in time that depends on their
//! lengths and not on where they differ, so that a caller can compare a keyed
//! digest with one it received. Sequences of different lengths are unequal.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abstract_type = @import("../api/abstract_type.zig");
const abstracts = @import("value/abstracts.zig");
const args_core = @import("args.zig");
const corefn = @import("corefn.zig");
const pp_format = @import("pp/format.zig");
const raise = @import("../api/raise.zig");
const registry = @import("registry.zig");
const repr = @import("repr");
const strings = @import("value/strings.zig");
const tables = @import("value/tables.zig");
const wrap = @import("value/helpers/wrap.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// The abstract type `crypto/hasher` returns.
pub const hasher_type = abstract_type.define(Hasher, .{
    .name = "crypto/hasher",
});

// ==========================================================================
// Types
// ==========================================================================

/// The algorithms the functions of this file take as a keyword.
const Algo = enum { sha256, sha512, blake3 };

/// The payload of a `crypto/hasher`: the state of one algorithm.
///
/// `crypto/hasher` returns a `*Hasher`, and `crypto/update!` and
/// `crypto/digest` take one.
pub const Hasher = struct {
    state: union(Algo) {
        sha256: std.crypto.hash.sha2.Sha256,
        sha512: std.crypto.hash.sha2.Sha512,
        blake3: std.crypto.hash.Blake3,
    },
};

// ==========================================================================
// Public functions
// ==========================================================================

/// Installs the `crypto/` functions into the core environment and registers the
/// type of `crypto/hasher`.
///
/// `env` is the environment. This function raises if the registration does.
pub fn libCrypto(env: *tables.Table) raise.Error!void {
    const entries = comptime [_]corefn.Entry{
        corefn.reg("crypto/hash", &nfunHash, @src(), "(crypto/hash algo val)", "Returns the digest of val, a string or a buffer, as a string of raw bytes. " ++
            "algo is `:sha256`, `:sha512` or `:blake3`. The digest is 32 bytes for `:sha256` and `:blake3`, and 64 bytes for `:sha512`. " ++
            "Raises an error if algo is another value."),
        corefn.reg("crypto/hasher", &nfunHasher, @src(), "(crypto/hasher algo)", "Creates a hasher for algo, which is `:sha256`, `:sha512` or `:blake3`. " ++
            "Add bytes to it with ^crypto/update! and read the digest with ^crypto/digest. " ++
            "Raises an error if algo is another value."),
        corefn.reg("crypto/update!", &nfunUpdate, @src(), "(crypto/update! hasher val)", "Adds val, a string or a buffer, to hasher, a hasher from ^crypto/hasher. Returns hasher."),
        corefn.reg("crypto/digest", &nfunDigest, @src(), "(crypto/digest hasher)", "Returns the digest of the bytes added to hasher so far, as a string of raw bytes. " ++
            "The hasher is unchanged, so more bytes can be added afterwards."),
        corefn.reg("crypto/hmac", &nfunHmac, @src(), "(crypto/hmac algo key val)", "Returns the HMAC of val, a string or a buffer, under key, a string or a buffer, as a string of raw bytes. " ++
            "algo is `:sha256` or `:sha512`, and the result is 32 or 64 bytes. " ++
            "Raises an error if algo is another value, `:blake3` included."),
        corefn.reg("crypto/equal?", &nfunEqual, @src(), "(crypto/equal? x val)", "Checks whether x and val, each a string or a buffer, hold the same bytes. " ++
            "The time taken depends on the lengths and not on where the bytes differ, so it suits comparing a digest with one that was received. " ++
            "Strings of different lengths are not equal."),
    };
    corefn.install(env, entries);
    try registry.registerAbstractType(&hasher_type);
}

// ==========================================================================
// Private functions
// ==========================================================================

/// Returns the digest `state` holds after the bytes added so far, in `out`, and
/// the number of bytes it wrote.
///
/// A copy of the state is finished, so `state` is unchanged.
fn finish(state: anytype, out: *[64]u8) usize {
    var copy = state.*;
    switch (copy) {
        .sha256 => |*h| {
            h.final(out[0..32]);
            return 32;
        },
        .sha512 => |*h| {
            h.final(out[0..64]);
            return 64;
        },
        .blake3 => |*h| {
            h.final(out[0..32]);
            return 32;
        },
    }
}

/// Returns the algorithm named by the keyword at `n`.
///
/// This function raises if the argument is not `:sha256`, `:sha512` or
/// `:blake3`.
fn getAlgo(argv: []repr.Value, n: usize) raise.Error!Algo {
    const name = try args_core.optKeyword(argv, n, null);
    if (name) |wanted| {
        const text = std.mem.span(wanted);
        if (std.mem.eql(u8, text, "sha256")) return .sha256;
        if (std.mem.eql(u8, text, "sha512")) return .sha512;
        if (std.mem.eql(u8, text, "blake3")) return .blake3;
    }
    return pp_format.panicf("expected :sha256, :sha512, or :blake3, got %v", .{argv[n]});
}

/// Returns the bytes of the string or buffer at `n`.
///
/// This function raises if the argument is not a byte sequence.
fn getData(argv: []repr.Value, n: usize) raise.Error![]const u8 {
    return args_core.viewBytes(try args_core.getBytes(argv, n));
}

/// Returns a string of the first `len` bytes of `out`.
fn digestString(out: *const [64]u8, len: usize) repr.Value {
    return wrap.fromString(strings.new(out[0..len]));
}

/// `(crypto/digest hasher)`.
fn nfunDigest(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const hasher: *Hasher = try args_core.getAbstract(Hasher, argv, 0, &hasher_type);
    var out: [64]u8 = undefined;
    const len = finish(&hasher.state, &out);
    return digestString(&out, len);
}

/// `(crypto/equal? x val)`. The bytes are combined with exclusive or over the
/// whole length, so no byte ends the comparison early.
fn nfunEqual(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 2);
    const left = try getData(argv, 0);
    const right = try getData(argv, 1);
    if (left.len != right.len) return wrap.fromBoolean(false);
    var difference: u8 = 0;
    for (left, right) |a, b| difference |= a ^ b;
    std.mem.doNotOptimizeAway(&difference);
    return wrap.fromBoolean(difference == 0);
}

/// `(crypto/hash algo val)`.
fn nfunHash(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 2);
    const algo = try getAlgo(argv, 0);
    const data = try getData(argv, 1);
    var out: [64]u8 = undefined;
    switch (algo) {
        .sha256 => {
            std.crypto.hash.sha2.Sha256.hash(data, out[0..32], .{});
            return digestString(&out, 32);
        },
        .sha512 => {
            std.crypto.hash.sha2.Sha512.hash(data, out[0..64], .{});
            return digestString(&out, 64);
        },
        .blake3 => {
            std.crypto.hash.Blake3.hash(data, out[0..32], .{});
            return digestString(&out, 32);
        },
    }
}

/// `(crypto/hasher algo)`.
fn nfunHasher(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const algo = try getAlgo(argv, 0);
    const hasher: *Hasher = abstracts.newFor(Hasher, &hasher_type);
    hasher.state = switch (algo) {
        .sha256 => .{ .sha256 = std.crypto.hash.sha2.Sha256.init(.{}) },
        .sha512 => .{ .sha512 = std.crypto.hash.sha2.Sha512.init(.{}) },
        .blake3 => .{ .blake3 = std.crypto.hash.Blake3.init(.{}) },
    };
    return wrap.fromAbstract(hasher);
}

/// `(crypto/hmac algo key val)`.
fn nfunHmac(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 3);
    const algo = try getAlgo(argv, 0);
    const key = try getData(argv, 1);
    const data = try getData(argv, 2);
    var out: [64]u8 = undefined;
    switch (algo) {
        .sha256 => {
            std.crypto.auth.hmac.sha2.HmacSha256.create(out[0..32], data, key);
            return digestString(&out, 32);
        },
        .sha512 => {
            std.crypto.auth.hmac.sha2.HmacSha512.create(out[0..64], data, key);
            return digestString(&out, 64);
        },
        .blake3 => return pp_format.panicf("crypto/hmac takes :sha256 or :sha512, got %v", .{argv[0]}),
    }
}

/// `(crypto/update! hasher val)`.
fn nfunUpdate(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 2);
    const hasher: *Hasher = try args_core.getAbstract(Hasher, argv, 0, &hasher_type);
    const data = try getData(argv, 1);
    switch (hasher.state) {
        .sha256 => |*h| h.update(data),
        .sha512 => |*h| h.update(data),
        .blake3 => |*h| h.update(data),
    }
    return argv[0];
}
