//! A native Janet module written in Zig: the worked example of scheduling
//! work through the event loop.
//!
//! `url` is the worked example of the views and `numarray` is the worked
//! example of the abstract type. This module imports `janet` and `std` and
//! nothing else. `build.zig` builds it and `examples/digest/test/digest.janet`
//! loads it, which `zig build test` runs.
//!
//! ```janet
//! (import digest)
//! (digest/sha256 "abc")
//! # -> "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
//! ```
//!
//! ## Taking part in the event loop
//!
//! `DESIGN.md` section 15 reduces the loop to one sentence: when something
//! happens, resume a fiber with a value. It gives a module three operations to
//! take part in it. `janet.await` suspends, `janet.post` queues a callback for
//! the loop thread, and `janet.wake` resumes. This module uses all three. It
//! hashes bytes, which is work with no I/O in it, on a thread of its own, so
//! the calling fiber waits and every other fiber in the program keeps running.
//!
//! The shape is five steps and the order is required. `sha256` reads the
//! loop and the fiber, roots what has to survive the wait, starts the thread
//! and suspends with `janet.await`. The thread computes and posts.
//! `hashDone`, back on the loop thread, joins the thread, builds the result,
//! wakes the fiber and unroots.
//!
//! ## Owning the thread
//!
//! A `*Loop` is valid until the runtime shuts down, and nothing tells the
//! worker thread about the shutdown. The thread is therefore owned by an
//! abstract value, `Hash`, whose `gc` callback joins it. Teardown runs every
//! finalizer before it releases the loop, so a hash in flight at exit posts
//! into a loop that is still valid, and the join delays exit until the hash
//! is done.
//!
//! ## What the worker thread may call
//!
//! The worker thread touches nothing in `janet.*` but `janet.post`, which
//! is the one function on the surface a thread that is not running Janet may
//! call. Every other function finds the runtime through a thread-local that
//! thread does not have. Calling any of them aborts with `called from a
//! thread that is not running Janet` rather than reading null state.

const std = @import("std");
const janet = @import("janet");

/// One hash in flight: what the cfunction fills in, the thread computes
/// into, and the callback reads.
///
/// `sha256` allocates a `Hash` with `janet.new`, `hashOnThread` takes a
/// `*Hash` and `hashDone` reads it.
///
/// A `Hash` is the payload of a `digest/hash` abstract value, and the
/// collector frees it. `janet.post` passes it to the callback as an opaque
/// pointer. `sha256` roots the abstract value and `hashDone` unroots it, so a
/// collection during the wait does not finalize it. At teardown every
/// finalizer runs regardless of roots, and `hashGc` joins a thread still
/// running.
const Hash = struct {
    /// The worker thread, or null once `hashDone` has joined it or if it was
    /// never started. `hashGc` joins it when it is not null.
    thread: ?std.Thread,
    /// The loop, read on the loop thread and used on the worker thread.
    loop: *janet.Loop,
    /// The fiber to wake, rooted for the whole wait.
    fiber: janet.Value,
    /// The argument, rooted for the whole wait so that `bytes` stays valid.
    source: janet.Value,
    /// The bytes to hash, read on the worker thread.
    bytes: []const u8,
    /// The result, written on the worker thread and read on the loop thread.
    digest: [std.crypto.hash.sha2.Sha256.digest_length]u8,
};

/// Joins the worker thread if `hashDone` has not. Implements the `gc`
/// callback.
///
/// The join returns at once in the common case, because the collector
/// finalizes a `Hash` only after `hashDone` has unrooted it. At teardown it
/// waits for a hash still in flight, whose `janet.post` reaches a loop that
/// teardown has not yet released.
///
/// This function cannot raise. `DESIGN.md` section 5 gives the reason.
fn hashGc(self: *Hash, _: usize) void {
    if (self.thread) |thread| thread.join();
}

/// The `digest/hash` abstract type, which `sha256` passes to `janet.new`. It
/// is declared at container level because the runtime keeps this address and
/// reads it again at teardown.
const hash_type = janet.define(Hash, .{
    .name = "digest/hash",
    .gc = hashGc,
});

/// Hashes `job.bytes` into `job.digest` and posts `hashDone`.
///
/// `job` is the hash in flight. This function is the whole of the worker
/// thread's work.
///
/// This function cannot raise.
///
/// This function runs on a thread that is not running Janet.
fn hashOnThread(job: *Hash) void {
    std.crypto.hash.sha2.Sha256.hash(job.bytes, &job.digest, .{});
    // The one crossing a thread that is not running Janet may call.
    janet.post(job.loop, &hashDone, job);
}

/// Joins the worker thread, renders the digest as hex, wakes the fiber and
/// unroots the job.
///
/// `w` is the capability to put the fiber back on the run queue, and `raw`
/// is the `*Hash` that `hashOnThread` passed to `janet.post`. This function
/// runs on the loop thread, between two fibers.
///
/// This function cannot raise, and its signature cannot express a raise.
fn hashDone(w: *janet.Wake, raw: *anyopaque) callconv(.c) void {
    const job: *Hash = @ptrCast(@alignCast(raw));
    // The thread posted this callback as its last call, so the join waits only
    // for it to return from `janet.post`.
    job.thread.?.join();
    job.thread = null;
    const digits = "0123456789abcdef";
    var hex: [2 * @typeInfo(@FieldType(Hash, "digest")).array.len]u8 = undefined;
    for (job.digest, 0..) |byte, i| {
        hex[i * 2] = digits[byte >> 4];
        hex[i * 2 + 1] = digits[byte & 0xf];
    }
    // Building a `Value` here is allowed: allocation through the collector is
    // fatal on failure rather than a raise, and no safe point runs between
    // fibers on the loop thread.
    _ = janet.wake(w, job.fiber, janet.string(&hex));
    // On both branches of `janet.wake`: a `false` means `ev/cancel` moved the
    // fiber on or it finished, and the roots are still this module's.
    _ = janet.gcunroot(job.source);
    _ = janet.gcunroot(job.fiber);
    _ = janet.gcunroot(janet.abstract(job));
}

/// Returns the SHA-256 of `bytes` as lowercase hex, hashed on a thread of
/// its own. Implements `(digest/sha256 bytes)`.
///
/// `argv` slot 0 is the bytes to hash. This function suspends the calling
/// fiber, and the result reaches that fiber when `hashDone` wakes it.
///
/// This function raises if the arity is wrong, if slot 0 is not a string,
/// symbol, keyword or buffer, if the build has no event loop, or if the
/// thread cannot be started.
fn sha256(argv: []janet.Value) janet.Error!janet.Value {
    try janet.fixarity(argv, 1);
    const bytes = try janet.getBytes(argv, 0);
    // Raises `event loop not enabled` in a build without the loop.
    const l = try janet.loop();
    const fiber = try janet.rootFiber();

    // `janet.new` returns a block already on the collector's heap list, and
    // nothing between it and this assignment reaches a safe point, so
    // `hashGc` never reads `thread` before it is set.
    const job = janet.new(Hash, &hash_type, null);
    job.* = .{
        .thread = null,
        .loop = l,
        .fiber = fiber,
        .source = argv[0],
        .bytes = bytes,
        .digest = undefined,
    };
    // The fiber is suspended, so nothing else keeps the argument reachable.
    // The root keeps a string's, a symbol's or a keyword's bytes stable for
    // the wait; a buffer's bytes move on a push from another fiber, which
    // this module cannot prevent.
    janet.gcroot(job.fiber);
    janet.gcroot(job.source);
    // Nothing else references the abstract value during the wait, and the
    // collector must not finalize it while the thread holds `job`.
    janet.gcroot(janet.abstract(job));

    // Started before the suspend, which is not a race: the loop is
    // single-threaded, so an event posted before this cfunction returns is
    // not processed until the fiber has suspended.
    job.thread = std.Thread.spawn(.{}, hashOnThread, .{job}) catch {
        // Nothing has been posted, so this frame does the callback's cleanup.
        // `thread` stays null, so `hashGc` has nothing to join.
        _ = janet.gcunroot(job.source);
        _ = janet.gcunroot(job.fiber);
        _ = janet.gcunroot(janet.abstract(job));
        return janet.panic("could not start a thread to hash on");
    };

    return janet.await();
}

// ==========================================================================
// The module entry point
// ==========================================================================

/// Defines the module's one cfunction.
///
/// `env` is the capability to define a binding in the environment the module
/// is loading into. `janet.entry` below passes `defs` to the loader.
///
/// This function cannot raise.
fn defs(env: *janet.Env) janet.Error!void {
    janet.cfuns(env, "digest", &.{
        janet.reg(
            "sha256",
            &sha256,
            "(digest/sha256 bytes)\n\nThe SHA-256 of bytes, as lowercase hex, hashed on a thread of its own.",
        ),
    });
}

comptime {
    janet.entry(defs);
}
