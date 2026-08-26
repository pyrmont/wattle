//! Behavioral contract for the file watcher's backends, watcher type and
//! cfunction surface.
//!
//! ## What the Janet suites cannot reach
//!
//! `test/suite-filewatch.janet` drives a real watcher over a real directory,
//! which is what it is for. Five things have no Janet spelling at all:
//!
//!  - **The abstract type's callback set.** `janet_filewatch_at` is
//!    `JANET_ATEND_GCMARK`, so a mark callback and nothing else. From Janet
//!    only the *name* is visible, through `(type watcher)`; that the `get`,
//!    `put`, `tostring`, `compare`, `hash`, `next`, `call`, `length` and
//!    `bytes` slots are all null is what makes a watcher opaque, and it is
//!    invisible from the language.
//!  - **The mark callback on an incompletely initialised watcher.**
//!    `janet_abstract` does not zero, and the watcher is filled field by
//!    field, so `filewatchMark` opens by asking whether the channel is set.
//!    Nothing in Janet can hand the collector a watcher in that state; a
//!    `@memset` and a `janet_abstract` can.
//!  - **A stale `errno`.** Two of the subject's retry loops repeat on
//!    *success* -- see `FOUND.md`, "filewatch/remove retries a close that
//!    succeeded" -- and reaching that needs `EINTR` in `errno` when the
//!    cfunction is entered, which no Janet program can arrange. It is a
//!    defect, so the contract pins it rather than asserting the behaviour
//!    anyone would want.
//!  - **The two halves of the flag table.** The names are in
//!    `filewatch_flags.zig` and the values are in the subject, and only a
//!    contract can ask the name lookup and the value decoder the same question
//!    and compare the answers.
//!  - **The failure messages that need an argument no Janet caller would
//!    write.** A raise is asserted here by its *message*, which Part 11
//!    recorded as the difference between a test and a tautology.
//!
//! ## What it deliberately does not do
//!
//! It does not run the event loop. `filewatch/listen` starts a fiber that
//! suspends on the watcher's stream, and pumping that from a contract means
//! running the loop -- a contract that waits on the kernel is a contract that
//! hangs when it is wrong. The suite does that, where it belongs. What is
//! checked here is everything either side of it: the argument decoding, the
//! flag decoding, the watcher's shape, and every raise on the way.
//!
//! ## What the migration changed
//!
//! **A refusal is a value.** `test/filewatch_core.c` reached one by opening a
//! scope, arming `janet_contract_arm`, calling through
//! `janet_contract_call_cfunction` and reading `janet_contract_raised` -- four
//! shims, of which this file and `test/net_sockets.c` were the last two users.
//! `harness.raised` is the whole of it here, because a cfunction is a raising
//! Zig function and this contract is compiled beside it.
//!
//! **The name half is reached by import**, so the two `janet_filewatch_flag_*`
//! symbols this file hand-declared are gone with the rest of that seam --
//! rule 44, and `filewatch_core.zig` was the other caller.
//!
//! **The backend is derived from Zig's target rather than from the subject.**
//! The C contract picked its platform with `#if defined(JANET_LINUX)` and the
//! same cascade `filewatch/abi.h` uses, which is two descriptions of one fact.
//! Asking `filewatch_core.zig` which backend it compiled would be one -- rule
//! 8's circularity -- so this file reads `builtin.os.tag` instead and lets the
//! two disagree if they ever do.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");
const harness = @import("harness.zig");

const subsystems = @import("subsystems");
const value = @import("subsystems").value;
const gc_alloc = @import("subsystems").gc_alloc;
const order = @import("subsystems").value.order;
const core_env = @import("subsystems").env;
const wrap = @import("subsystems").value.wrap;
const args_core = @import("subsystems").args;
const abstract_type = @import("subsystems").abstract_type;
const vm_lifecycle = @import("subsystems").lifecycle;
const abstracts = @import("subsystems").value.abstracts;
const pp_describe = @import("subsystems").pp_describe;
const ev_channel = @import("subsystems").ev_channel;
const filewatch_core = subsystems.filewatch;
const flags = subsystems.filewatch;
const Platform = flags.Platform;

const assert = std.debug.assert;

/// Which vocabulary this target's backend uses, and the word it puts in
/// "unknown %s flag". Null where the host has no backend at all, in which case
/// every entry point raises before a flag is ever looked at.
const backend: ?struct { platform: Platform, word: []const u8 } = switch (builtin.os.tag) {
    .linux => .{ .platform = .linux, .word = "linux" },
    .windows => .{ .platform = .windows, .word = "windows filewatch" },
    .macos, .freebsd, .netbsd, .openbsd, .dragonfly => .{ .platform = .kqueue, .word = "bsd" },
    else => null,
};

const windows = builtin.os.tag == .windows;

var raises_seen: u32 = 0;

// ==========================================================================
// Refusals
// ==========================================================================

fn expectRaise(name: [*:0]const u8, argv: []types.Janet, message: []const u8) void {
    const r = harness.coreRaised(name, argv) orelse {
        std.debug.print("filewatch_core: expected a raise saying: {s}\n", .{message});
        @panic("filewatch_core: expected a raise, got a return");
    };
    assert(r.signal == constants.JANET_SIGNAL_ERROR);
    if (!r.says(message)) {
        std.debug.print("expected: {s}\n", .{message});
        std.debug.print("     got: {s}\n", .{pp_describe.toString(r.payload)});
        @panic("filewatch_core: the raise carried another message");
    }
    raises_seen += 1;
}

/// For a message whose tail is the host's own wording: `janet_ev_lasterr`
/// renders `strerror`, which differs by platform and by libc, and pinning it
/// would make this contract a test of the C library. An abstract rendered by
/// `%v` carries an address, which is the other reason.
fn expectRaisePrefix(name: [*:0]const u8, argv: []types.Janet, prefix: []const u8) void {
    const r = harness.coreRaised(name, argv) orelse {
        std.debug.print("filewatch_core: expected a raise starting: {s}\n", .{prefix});
        @panic("filewatch_core: expected a raise, got a return");
    };
    assert(r.signal == constants.JANET_SIGNAL_ERROR);
    if (!r.beginsWith(prefix)) {
        std.debug.print("expected prefix: {s}\n", .{prefix});
        std.debug.print("            got: {s}\n", .{pp_describe.toString(r.payload)});
        @panic("filewatch_core: the raise carried another message");
    }
    raises_seen += 1;
}

/// Where the message is the host's from end to end, or where the case is a
/// recorded defect whose wording is not the subject.
fn expectAnyRaise(name: [*:0]const u8, argv: []types.Janet) void {
    const r = harness.coreRaised(name, argv) orelse
        @panic("filewatch_core: expected a raise, got a return");
    assert(r.signal == constants.JANET_SIGNAL_ERROR);
    raises_seen += 1;
}

/// A cfunction that is expected to return, by the name the registry knows.
fn callCore(name: [*:0]const u8, argv: []types.Janet) types.Janet {
    return harness.callCore(name, argv) catch
        @panic("filewatch_core: a call that should have returned raised");
}

// ==========================================================================
// Registration
// ==========================================================================

/// Every name `janet_lib_filewatch` registers, in the order it registers them.
/// The order is not itself a contract -- a table has none -- but the list is: a
/// binding that stops being registered is what this catches, and Part 6
/// recorded that a registration table is the one place a cfunction can go
/// missing without a link error.
const filewatch_bindings = [_][*:0]const u8{
    "filewatch/new",    "filewatch/add",      "filewatch/remove",
    "filewatch/listen", "filewatch/unlisten",
};

fn theRegistration() void {
    assert(filewatch_bindings.len == 5);
    // `harness.core` asserts the binding resolves to a cfunction.
    for (filewatch_bindings) |name| _ = harness.core(name);
}

// ==========================================================================
// A channel
// ==========================================================================

/// `filewatch/new` takes a channel and there is no entry point that makes one,
/// so it comes from the language. Nothing else in this file does.
fn makeChannel() types.Janet {
    var chan = wrap.fromNil();
    const env = harness.coreEnv();
    const status = core_env.dostring(env, "(ev/chan 16)", "filewatch_core", &chan);
    assert(status == 0);
    assert(args_core.checkabstract(chan, abstract_type.stored(&ev_channel.channelType)) != null);
    return chan;
}

// ==========================================================================
// Arguments and flags
// ==========================================================================

fn theArgumentFaults(chan: types.Janet) void {
    var one = [_]types.Janet{chan};
    var none = [_]types.Janet{};

    expectRaise("filewatch/new", &none, "arity mismatch, expected at least 1, got 0");
    var bad = [_]types.Janet{harness.wrapInteger(7)};
    expectRaise("filewatch/new", &bad, "bad slot #0, expected core/channel, got 7");
    expectRaise("filewatch/add", &one, "arity mismatch, expected at least 2, got 1");
    expectRaise("filewatch/remove", &one, "arity mismatch, expected 2, got 1");
    expectRaise("filewatch/listen", &none, "arity mismatch, expected 1, got 0");
    expectRaise("filewatch/unlisten", &none, "arity mismatch, expected 1, got 0");

    // A channel is not a watcher, and every entry point that takes one says so
    // with the abstract type's name -- which is the only place that name is
    // visible from outside the subsystem.
    expectRaisePrefix("filewatch/listen", &one, "bad slot #0, expected filewatch/watcher, got ");
}

/// The message names the backend, and that word is the only part of it that
/// ever differed between them.
fn theFlagFaults(chan: types.Janet, word: []const u8) void {
    var buffer: [64]u8 = undefined;
    const unknown = std.fmt.bufPrint(&buffer, "unknown {s} flag ", .{word}) catch unreachable;

    {
        var argv = [_]types.Janet{ chan, value.fromBytes("not-a-flag", .keyword) };
        expectRaisePrefix("filewatch/new", &argv, unknown);
    }
    {
        // A non-keyword is refused before the vocabulary is consulted, so this
        // message has no backend word in it.
        var argv = [_]types.Janet{ chan, value.fromBytes("all", .string) };
        expectRaise("filewatch/new", &argv, "expected keyword, got \"all\"");
    }
    {
        // The first flag is good and the second is not: the decoder folds left
        // and reports the one that failed rather than the first argument.
        var argv = [_]types.Janet{ chan, value.fromBytes("all", .keyword), value.fromBytes("nope", .keyword) };
        var full: [80]u8 = undefined;
        const message = std.fmt.bufPrint(&full, "{s}:nope", .{unknown}) catch unreachable;
        expectRaise("filewatch/new", &argv, message);
    }
    {
        // A keyword holding a zero byte matches nothing. It is the case the
        // name lookup compares by length for, and it is unreachable from a
        // source literal.
        const bytes = [_]u8{ 'a', 'l', 'l', 0 };
        var argv = [_]types.Janet{ chan, value.fromBytes(&bytes, .keyword) };
        expectRaisePrefix("filewatch/new", &argv, unknown);
    }
}

/// The two halves of one table. The names are `filewatch_flags.zig`'s and the
/// values are the subject's, and the index the lookup reports is what selects a
/// value -- so a name the host has a constant for is accepted and one it does
/// not is refused *by that name*. Asking every row of this platform's
/// vocabulary is the only way to see the halves line up.
///
/// `:all` is index zero on every backend and is the union of the rest, so it is
/// the one row that must always be accepted.
fn theFlagTableHalves(chan: types.Janet, platform: Platform, word: []const u8) void {
    var buffer: [64]u8 = undefined;
    const unknown = std.fmt.bufPrint(&buffer, "unknown {s} flag :", .{word}) catch unreachable;

    const count = flags.flagCount(platform);
    assert(count > 0);

    var accepted: u32 = 0;
    for (0..count) |i| {
        const name = flags.flagName(platform, i).?;
        var argv = [_]types.Janet{ chan, value.fromBytes(name, .keyword) };
        if (harness.coreRaised("filewatch/new", &argv)) |r| {
            // The only reason a name from this platform's own vocabulary is
            // refused is that the host's headers do not define the constant,
            // which the value table records as a zero. The message still names
            // the flag.
            assert(r.signal == constants.JANET_SIGNAL_ERROR);
            assert(r.beginsWith(unknown));
        } else {
            accepted += 1;
        }
    }
    assert(accepted >= 1);

    // Every vocabulary contains `:all`. Its *index* is a property of the
    // table's own order rather than of the flag, and this asserted index zero
    // until Phase 11 Part 24 ran the container: `windows_names` and
    // `kqueue_names` open with it, and `linux_names` is alphabetical, so
    // `access` sorts ahead. The assertion was true on the two platforms
    // anybody had run it on and false on the third for as long as it existed.
    assert(flags.flagIndex(platform, "all") != null);

    // A name that belongs to a different backend is refused here, which is
    // what makes the split a split rather than one shared vocabulary. The
    // three tables share only `all`.
    const other: Platform = if (platform == .linux) .windows else .linux;
    var refused: u32 = 0;
    for (0..flags.flagCount(other)) |i| {
        const name = flags.flagName(other, i).?;
        if (std.mem.eql(u8, name, "all")) continue;
        // Names shared with this platform's vocabulary are not the test.
        if (flags.flagIndex(platform, name) != null) continue;
        var argv = [_]types.Janet{ chan, value.fromBytes(name, .keyword) };
        expectRaisePrefix("filewatch/new", &argv, unknown);
        refused += 1;
    }
    assert(refused >= 1);
}

// ==========================================================================
// The abstract type
// ==========================================================================

/// `JANET_ATEND_GCMARK`: a mark callback and nothing else. Every later slot
/// being null is what makes a watcher opaque to `get`, `put`, `next`, `compare`
/// and the rest, and none of that is visible from Janet.
fn theAbstractType(chan: types.Janet) void {
    var argv = [_]types.Janet{chan};
    const watcher = callCore("filewatch/new", &argv);
    assert(harness.isType(watcher, constants.JANET_ABSTRACT));

    // A `Janet` in a local is not a root: the collector scans the VM and the
    // fiber stacks, and a cfunction's arguments are on one of those. Nothing
    // here is, so every watcher this file holds across an allocation has to be
    // rooted by hand -- and a watcher that is collected closes its stream, so
    // the symptom is a later call failing on a descriptor the test still
    // believes it owns.
    gc_alloc.gcroot(watcher);
    defer _ = gc_alloc.gcunroot(watcher);

    const abst = wrap.toAbstract(watcher);
    const at = &filewatch_core.janet_filewatch_at;
    assert(std.mem.eql(u8, std.mem.span(at.name), "filewatch/watcher"));
    assert(at.gc == null);
    assert(at.gcmark != null);
    assert(at.get == null);
    assert(at.put == null);
    assert(at.marshal == null);
    assert(at.unmarshal == null);
    assert(at.tostring == null);
    assert(at.compare == null);
    assert(at.hash == null);
    assert(at.next == null);
    assert(at.call == null);
    assert(at.length == null);
    assert(at.bytes == null);
    assert(at.gcperthread == null);

    // The registered type is this one: `janet_abstract` stored the mirror, and
    // a watcher answers with the same address.
    assert(types.abstractHead(abst).type == @as(*const types.JanetAbstractType, @ptrCast(at)));

    // The live watcher marks without complaint, and reports zero as every
    // `gcmark` in the tree does.
    assert(at.gcmark.?(abst, types.abstractHead(abst).size) == 0);

    // And a watcher that never reached its backend's `init`. `janet_abstract`
    // does not zero, so the guard is a read of whatever was there; a zeroed one
    // is the case it exists for, and the collector reaching a watcher in that
    // state is what a raise between the allocation and the initialisation would
    // leave behind.
    const size = types.abstractHead(abst).size;
    const blank = abstracts.new(@ptrCast(at), size).?;
    const bytes: [*]u8 = @ptrCast(blank);
    @memset(bytes[0..size], 0);
    assert(at.gcmark.?(blank, size) == 0);
}

// ==========================================================================
// The watcher lifecycle
// ==========================================================================

const probe_dir = "/tmp/janet-filewatch-contract";

fn theLifecycle(chan: types.Janet) void {
    var new_argv = [_]types.Janet{chan};
    const dir = value.fromBytes(probe_dir, .string);

    // `std.posix` has neither of these in 0.16 and nothing in the tree
    // translates <sys/stat.h>, so they are the libc entry points by name. An
    // existing directory is fine; anything else fails the `add` below.
    _ = std.c.rmdir(probe_dir);
    _ = std.c.mkdir(probe_dir, 0o755);

    const watcher = callCore("filewatch/new", &new_argv);
    assert(harness.isType(watcher, constants.JANET_ABSTRACT));
    gc_alloc.gcroot(watcher);
    defer _ = gc_alloc.gcunroot(watcher);

    // A path the host cannot open. The two backends word this differently --
    // inotify reports `janet_ev_lasterr` bare and kqueue prefixes it -- and
    // both are the host's `strerror` after that.
    {
        var argv = [_]types.Janet{
            watcher,
            value.fromBytes(probe_dir ++ "/no-such-entry", .string),
            value.fromBytes("all", .keyword),
        };
        expectAnyRaise("filewatch/add", &argv);
    }

    // Adding returns the watcher itself rather than a descriptor, which is
    // what lets `(-> w (filewatch/add p) (filewatch/add q))` thread.
    {
        var argv = [_]types.Janet{ watcher, dir, value.fromBytes("all", .keyword) };
        assert(order.equals(callCore("filewatch/add", &argv), watcher) != 0);
    }

    // A path that was never added has no descriptor to look up.
    {
        var argv = [_]types.Janet{ watcher, value.fromBytes(probe_dir ++ "/never-added", .string) };
        expectRaise("filewatch/remove", &argv, "bad watch descriptor");
    }

    // `FOUND.md`, "filewatch/remove retries a close that succeeded". The retry
    // loop repeats while the call *succeeded* and `errno` holds EINTR, so a
    // stale EINTR turns one successful removal into two attempts and the second
    // one fails. Nothing in Janet can leave EINTR in `errno` across a cfunction
    // entry; this is what the contract is for. Pinned rather than asserted
    // away, on Phase 8's rule: the behaviour is defined, so the port reproduces
    // it and the assertion holds.
    {
        var argv = [_]types.Janet{ watcher, dir };
        std.c._errno().* = @intFromEnum(std.posix.E.INTR);
        expectAnyRaise("filewatch/remove", &argv);
    }

    // With a clean `errno` the same call is the ordinary one, and it answers
    // with the watcher. The descriptor above is gone, so this needs a fresh
    // watch first.
    {
        var add_argv = [_]types.Janet{ watcher, dir, value.fromBytes("all", .keyword) };
        var rm_argv = [_]types.Janet{ watcher, dir };
        _ = callCore("filewatch/add", &add_argv);
        std.c._errno().* = 0;
        assert(order.equals(callCore("filewatch/remove", &rm_argv), watcher) != 0);
    }

    // Listening twice is refused, and that refusal is the only thing outside
    // the event loop that reads `is_watching`. Unlistening twice is *not*
    // refused: the second call returns without touching the stream.
    {
        var argv = [_]types.Janet{ watcher, dir, value.fromBytes("all", .keyword) };
        var one = [_]types.Janet{watcher};
        _ = callCore("filewatch/add", &argv);
        assert(harness.isType(callCore("filewatch/listen", &one), constants.JANET_NIL));
        expectRaise("filewatch/listen", &one, "already watching");
        assert(harness.isType(callCore("filewatch/unlisten", &one), constants.JANET_NIL));
        assert(harness.isType(callCore("filewatch/unlisten", &one), constants.JANET_NIL));
    }

    // And the watcher is dead after that, which is why this is the last thing
    // the lifecycle does. `filewatch/unlisten` closes the *watcher's own*
    // descriptor -- the inotify instance or the kqueue -- and nothing reopens
    // it, so every later `filewatch/add` fails on it. `FOUND.md` has the entry;
    // it is pinned here because it is the shape of the whole object's life, and
    // because a Janet program that hit it would see the failure several calls
    // away from the call that caused it.
    {
        var argv = [_]types.Janet{ watcher, dir, value.fromBytes("all", .keyword) };
        expectAnyRaise("filewatch/add", &argv);
    }

    _ = std.c.rmdir(probe_dir);
}

pub fn run() void {
    harness.init();
    defer vm_lifecycle.deinit();

    const chan = makeChannel();
    gc_alloc.gcroot(chan);
    defer _ = gc_alloc.gcunroot(chan);

    theRegistration();
    theArgumentFaults(chan);

    if (backend) |be| {
        theFlagFaults(chan, be.word);
        theFlagTableHalves(chan, be.platform, be.word);
        theAbstractType(chan);
        if (!windows) theLifecycle(chan);
    }

    std.debug.print("filewatch_core contract ok ({d} raises)\n", .{raises_seen});
}
