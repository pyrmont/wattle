//! A native Janet module written in Zig: the worked example of **scheduling
//! work through the event loop**, as `url` is of the views and `numarray` of
//! the abstract type.
//!
//! `DESIGN.md` section 15 reduces the loop to one sentence -- when something
//! happens, resume a fiber with a value -- and gives a module three operations
//! to take part in it: `await` suspends, `post` knocks, `wake` resumes. This
//! module is the smallest honest use of all three. It hashes bytes, which is
//! real work with no I/O in it, on a thread of its own, so the fiber that
//! asked waits and every other fiber in the program keeps running.
//!
//! ```janet
//! (import digest)
//! (digest/sha256 "abc")   # -> "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
//! ```
//!
//! **The shape is five steps and the order is the contract.** Read the loop
//! and the fiber; root what has to survive the wait; start the thread; suspend
//! with `await`. The thread computes and posts. The callback, back on the loop
//! thread, builds the answer, wakes the fiber, unroots and frees.
//!
//! **Starting the thread before the suspend is not a race.** The loop is
//! single-threaded, so an event the worker posts before this cfunction has
//! returned is not processed until the fiber has suspended. There is no
//! window and therefore nothing to synchronise.
//!
//! **The worker thread touches nothing in `janet.*` but `post`**, which is the
//! one function on the surface a thread with no VM may call. Everything else
//! finds the VM through a thread-local that thread does not have, and calling
//! one aborts with `called from a thread that is not running Janet` rather
//! than reading null state.
//!
//! It imports `janet` and `std` and nothing else. Built by `build.zig` and
//! loaded by `test/digest.janet`, which `zig build test` runs.

const std = @import("std");
const janet = @import("janet");

/// One hash in flight: what the cfunction fills in, the thread computes into,
/// and the callback reads and frees.
///
/// **It is the module's own allocation and its lifetime is exactly the wait.**
/// The runtime never reads it -- `post` carries it as an opaque pointer and
/// hands it straight back -- so freeing it in the callback is the module's job
/// and happens on both branches of the `wake` below.
const Hash = struct {
    /// The loop, read on the loop thread and used on the worker's.
    loop: *janet.Loop,
    /// The fiber to wake, rooted for the whole wait.
    fiber: janet.Value,
    /// The argument, rooted for the whole wait. **This is what keeps `bytes`
    /// valid**: the slice points at the string's own storage, and the fiber is
    /// suspended, so nothing else in the program is holding the value on this
    /// module's behalf.
    source: janet.Value,
    bytes: []const u8,
    digest: [std.crypto.hash.sha2.Sha256.digest_length]u8,
};

/// The worker thread: hash, post, exit.
///
/// Every line of this function runs on a thread with no VM. It reads the two
/// fields it was given, writes one, and calls the one crossing that is legal
/// here.
fn hashOnThread(job: *Hash) void {
    std.crypto.hash.sha2.Sha256.hash(job.bytes, &job.digest, .{});
    janet.post(job.loop, &hashDone, job);
}

/// The callback, on the loop thread, between two fibers.
///
/// **`align(janet.fn_align)` is not decoration.** The runtime carries this
/// pointer to the loop thread inside a Janet value, which under a nonzero
/// `-Dnanbox-pointer-shift` reuses its low bits; `janet.PostCallback` carries
/// the alignment in its type so that forgetting it is a compile error here
/// rather than a call to the wrong address there. A cfunction is declared the
/// same way and for the same reason.
///
/// **Building a `Value` here is allowed**: allocating through the collector is
/// fatal on failure rather than a raise, and no safe point runs between fibers
/// on the loop thread. What is not allowed is raising -- this signature cannot
/// carry one -- or doing work, which belongs on the thread above.
///
/// **The cleanup is unconditional, and that is the point of reading `wake`'s
/// answer.** A `false` means `ev/cancel` moved the fiber on, or that it
/// finished; the runtime would have dropped the resume, and the root and the
/// allocation are still this module's. A module that unrooted and freed only
/// under the `true` branch would leak exactly the cancelled case.
fn hashDone(w: *janet.Wake, raw: *anyopaque) align(janet.fn_align) callconv(.c) void {
    const job: *Hash = @ptrCast(@alignCast(raw));
    const digits = "0123456789abcdef";
    var hex: [2 * @typeInfo(@FieldType(Hash, "digest")).array.len]u8 = undefined;
    for (job.digest, 0..) |byte, i| {
        hex[i * 2] = digits[byte >> 4];
        hex[i * 2 + 1] = digits[byte & 0xf];
    }
    _ = janet.wake(w, job.fiber, janet.string(&hex));
    _ = janet.gcunroot(job.source);
    _ = janet.gcunroot(job.fiber);
    janet.free(job);
}

/// `(digest/sha256 bytes)` -- the SHA-256 of `bytes`, as lowercase hex.
///
/// **How long the bytes stay valid is the getter's rule, and the root is what
/// buys the part of it this needs.** A string's, a symbol's and a keyword's
/// bytes are stable while the value is reachable, so rooting the argument is
/// exactly enough: the fiber is suspended and nothing else holds it. A
/// *buffer's* bytes are `data[0..count]`, and a push from another fiber may
/// move them -- so hashing a buffer another fiber can write to while this
/// waits is the caller's to avoid, and is the one thing this module cannot
/// check for them.
///
/// The refusal for a wrong argument type is the runtime's, from `getBytes`.
/// The refusal for a build with no event loop is the runtime's too, from
/// `loop`, and reads `event loop not enabled`.
fn sha256(argv: []janet.Value) align(janet.fn_align) janet.Error!janet.Value {
    try janet.fixarity(argv, 1);
    const bytes = try janet.getBytes(argv, 0);
    const l = try janet.loop();
    const fiber = try janet.rootFiber();

    const cells = janet.alloc(Hash, 1) orelse return janet.panic("out of memory");
    const job = &cells[0];
    job.* = .{
        .loop = l,
        .fiber = fiber,
        .source = argv[0],
        .bytes = bytes,
        .digest = undefined,
    };
    janet.gcroot(job.fiber);
    janet.gcroot(job.source);

    const thread = std.Thread.spawn(.{}, hashOnThread, .{job}) catch {
        // Nothing has been posted, so this frame is the only owner and the
        // cleanup is the callback's, done here instead.
        _ = janet.gcunroot(job.source);
        _ = janet.gcunroot(job.fiber);
        janet.free(job);
        return janet.panic("could not start a thread to hash on");
    };
    thread.detach();

    return janet.await();
}

// ==========================================================================
// The module entry point
// ==========================================================================

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
