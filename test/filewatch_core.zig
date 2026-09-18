//! Behavioral contract for the file watcher's backends, watcher type and
//! cfunction surface.
//!
//! ## What the Janet suites cannot reach
//!
//! `test/suite-filewatch.janet` drives a real watcher over a real directory,
//! which is what it is for. Five things have no Janet spelling at all:
//!
//!  - The abstract type's callback set. `filewatch.watcherType` has a mark
//!    callback and nothing else. From Janet only the *name* is visible,
//!    through `(type watcher)`; that the `get`, `put`, `tostring`, `compare`,
//!    `hash`, `next`, `call`, `length` and `bytes` slots are all null is what
//!    makes a watcher opaque, and it is invisible from the language.
//!  - The mark callback on an incompletely initialised watcher. An abstract's
//!    payload is not zeroed and the watcher is filled field by field, so
//!    `filewatchMark` opens by asking whether the channel is set. Nothing in
//!    Janet can give the collector a watcher in that state; a `@memset` and an
//!    `abstracts.newBytes` can.
//!  - A stale `errno`. A retry loop that repeats on *success* while `errno` is
//!    `EINTR` needs `EINTR` in `errno` when the cfunction is entered, which no
//!    Janet program can arrange. `c.retryIntr` repeats only a call that
//!    failed, and this is the only place the removal can be asked with a dirty
//!    `errno`, so the assertion is what says the result does not depend on
//!    one.
//!  - The two halves of the flag table. The names are in
//!    `filewatch_flags.zig` and the values are in the subject, and only a
//!    contract can ask the name lookup and the value decoder the same question
//!    and compare what each gives back.
//!  - The failure messages that need an argument no Janet caller would write.
//!    A raise is asserted here by its *message*, which is the difference
//!    between a test and a tautology.
//!
//! ## What it deliberately does not do
//!
//! It runs the event loop for one case only. `filewatch/listen` starts a fiber
//! that suspends on the watcher's stream, and pumping that from a contract
//! means running the loop, and a contract that waits on the kernel hangs when
//! it is wrong. The suite does that. What is checked here is everything either
//! side of it: the argument decoding, the flag decoding, the watcher's shape,
//! and every raise on the way.
//!
//! The one case is the kqueue backend's naming of a watched directory. The
//! backend decides between a directory and a file by `fstat`ing the watched
//! descriptor, and the structure `fstat` fills is laid out differently on the
//! two macOS architectures, so the case runs wherever the driver does. Each
//! wait in it is bounded by `ev/with-deadline`.
//!
//! ## Two things about how the subjects are reached
//!
//! A refusal is a value. A cfunction is a raising Zig function and this
//! contract is compiled beside it, so `harness.raised` is the whole of it.
//!
//! The backend is derived from Zig's target rather than from the subject.
//! Asking the subject which backend it compiled would be circular, so this
//! file reads `builtin.os.tag` instead and lets the two disagree if they ever
//! do.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");
const builtin = @import("builtin");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const abstracts = @import("subsystems").value.abstracts;
const args_core = @import("subsystems").args;
const core_env = @import("subsystems").env;
const ev_channel = @import("subsystems").ev_channel;
const expect = @import("expect.zig").expect;
const filewatch_core = subsystems.filewatch;
const gc_alloc = @import("subsystems").gc_alloc;
const harness = @import("harness.zig");
const order = @import("subsystems").value.order;
const pp_describe = @import("subsystems").pp_describe;
const repr = @import("repr");
const subsystems = @import("subsystems");
const value = @import("subsystems").value;
const vm_lifecycle = @import("subsystems").lifecycle;
const wrap = @import("subsystems").value.wrap;

// ==========================================================================
// Constants
// ==========================================================================

/// Which vocabulary this target's backend uses, and the word it puts in
/// "unknown %s flag". Null where the host has no backend at all, in which case
/// every entry point raises before a flag is ever looked at.
const backend: ?struct { platform: Platform, word: []const u8 } = switch (builtin.os.tag) {
    .linux => .{ .platform = .linux, .word = "linux" },
    .windows => .{ .platform = .windows, .word = "windows filewatch" },
    .macos, .freebsd, .netbsd, .openbsd, .dragonfly => .{ .platform = .kqueue, .word = "bsd" },
    else => null,
};

/// Every name `filewatch.libFilewatch` registers, in registration order. The
/// order is not itself pinned, a table having none, but the list is: a
/// binding that stops being registered is what this catches, and a
/// registration table is the one place a cfunction can go missing without a
/// link error.
const filewatch_bindings = [_][*:0]const u8{
    "filewatch/new",    "filewatch/add",      "filewatch/remove",
    "filewatch/listen", "filewatch/unlisten",
};

const probe_dir = "/tmp/wattle-filewatch-contract";
var raises_seen: u32 = 0;
const windows = builtin.os.tag == .windows;

// ==========================================================================
// Aliased types
// ==========================================================================

const Platform = filewatch_core.Platform;

// ==========================================================================
// Cases
// ==========================================================================

fn expectRaise(name: [*:0]const u8, argv: []repr.Value, message: []const u8) void {
    const r = harness.coreRaised(name, argv) orelse {
        std.debug.print("filewatch_core: expected a raise saying: {s}\n", .{message});
        @panic("filewatch_core: expected a raise, got a return");
    };
    expect(r.signal == abi.Signal.@"error");
    if (!r.says(message)) {
        std.debug.print("expected: {s}\n", .{message});
        std.debug.print("     got: {s}\n", .{pp_describe.toString(r.payload)});
        @panic("filewatch_core: the raise carried another message");
    }
    raises_seen += 1;
}

/// For a message whose tail is the host's own wording: `ev/stream.evLasterr`
/// renders `strerror`, which differs by platform and by libc, and pinning it
/// would make this contract a test of the C library. An abstract rendered by
/// `%v` renders an address, which is the other reason.
fn expectRaisePrefix(name: [*:0]const u8, argv: []repr.Value, prefix: []const u8) void {
    const r = harness.coreRaised(name, argv) orelse {
        std.debug.print("filewatch_core: expected a raise starting: {s}\n", .{prefix});
        @panic("filewatch_core: expected a raise, got a return");
    };
    expect(r.signal == abi.Signal.@"error");
    if (!r.beginsWith(prefix)) {
        std.debug.print("expected prefix: {s}\n", .{prefix});
        std.debug.print("            got: {s}\n", .{pp_describe.toString(r.payload)});
        @panic("filewatch_core: the raise carried another message");
    }
    raises_seen += 1;
}

/// Where the message is the host's from end to end, or where the case is a
/// recorded defect whose wording is not the subject.
fn expectAnyRaise(name: [*:0]const u8, argv: []repr.Value) void {
    const r = harness.coreRaised(name, argv) orelse
        @panic("filewatch_core: expected a raise, got a return");
    expect(r.signal == abi.Signal.@"error");
    raises_seen += 1;
}

/// A cfunction expected to return, called by the name the registry has for it.
fn callCore(name: [*:0]const u8, argv: []repr.Value) repr.Value {
    return harness.callCore(name, argv) catch
        @panic("filewatch_core: a call that should have returned raised");
}

/// `filewatch/new` takes a channel and there is no entry point that makes one,
/// so it comes from the language. Nothing else in this file does.
fn makeChannel() repr.Value {
    var chan = wrap.fromNil();
    const env = harness.coreEnv();
    const status = core_env.dostring(env, "(ev/chan 16)", "filewatch_core", &chan);
    expect(status == 0);
    expect(args_core.checkabstract(chan, &ev_channel.channelType) != null);
    return chan;
}

fn theRegistration() void {
    expect(filewatch_bindings.len == 5);
    // `harness.core` asserts the binding resolves to a cfunction.
    for (filewatch_bindings) |name| _ = harness.core(name);
}

fn theArgumentFaults(chan: repr.Value) void {
    var one = [_]repr.Value{chan};
    var none = [_]repr.Value{};

    expectRaise("filewatch/new", &none, "arity mismatch, expected at least 1, got 0");
    var bad = [_]repr.Value{harness.wrapInteger(7)};
    expectRaise("filewatch/new", &bad, "bad slot #0, expected core/channel, got 7");
    expectRaise("filewatch/add", &one, "arity mismatch, expected at least 2, got 1");
    expectRaise("filewatch/remove", &one, "arity mismatch, expected 2, got 1");
    expectRaise("filewatch/listen", &none, "arity mismatch, expected 1, got 0");
    expectRaise("filewatch/unlisten", &none, "arity mismatch, expected 1, got 0");

    // A channel is not a watcher, and every entry point that takes one says so
    // with the abstract type's name, which is the only place that name is
    // visible from outside the subsystem.
    expectRaisePrefix("filewatch/listen", &one, "bad slot #0, expected filewatch/watcher, got ");
}

/// The message names the backend, and that word is the only part of it that
/// ever differed between them.
fn theFlagFaults(chan: repr.Value, word: []const u8) void {
    var buffer: [64]u8 = undefined;
    const unknown = std.fmt.bufPrint(&buffer, "unknown {s} flag ", .{word}) catch unreachable;

    {
        var argv = [_]repr.Value{ chan, value.fromBytes("not-a-flag", .keyword) };
        expectRaisePrefix("filewatch/new", &argv, unknown);
    }
    {
        // A non-keyword is refused before the vocabulary is consulted, so this
        // message has no backend word in it.
        var argv = [_]repr.Value{ chan, value.fromBytes("all", .string) };
        expectRaise("filewatch/new", &argv, "expected keyword, got \"all\"");
    }
    {
        // The first flag is good and the second is not: the decoder folds left
        // and reports the one that failed rather than the first argument.
        var argv = [_]repr.Value{ chan, value.fromBytes("all", .keyword), value.fromBytes("nope", .keyword) };
        var full: [80]u8 = undefined;
        const message = std.fmt.bufPrint(&full, "{s}:nope", .{unknown}) catch unreachable;
        expectRaise("filewatch/new", &argv, message);
    }
    {
        // A keyword with a zero byte in it matches nothing. It is the case the
        // name lookup compares by length for, and it is unreachable from a
        // source literal.
        const bytes = [_]u8{ 'a', 'l', 'l', 0 };
        var argv = [_]repr.Value{ chan, value.fromBytes(&bytes, .keyword) };
        expectRaisePrefix("filewatch/new", &argv, unknown);
    }
}

/// The two halves of one table. The names are `filewatch_flags.zig`'s and the
/// values are the subject's, and the index the lookup reports is what selects a
/// value, so a name the host has a constant for is accepted and one it does
/// not is refused *by that name*. Asking every row of this platform's
/// vocabulary is the only way to see the halves line up.
///
/// `:all` is index zero on every backend and is the union of the rest, so it is
/// the one row that must always be accepted.
fn theFlagTableHalves(chan: repr.Value, platform: Platform, word: []const u8) void {
    var buffer: [64]u8 = undefined;
    const unknown = std.fmt.bufPrint(&buffer, "unknown {s} flag :", .{word}) catch unreachable;

    const count = filewatch_core.flagCount(platform);
    expect(count > 0);

    var accepted: u32 = 0;
    for (0..count) |i| {
        const name = filewatch_core.flagName(platform, i).?;
        var argv = [_]repr.Value{ chan, value.fromBytes(name, .keyword) };
        if (harness.coreRaised("filewatch/new", &argv)) |r| {
            // The only reason a name from this platform's own vocabulary is
            // refused is that the host's headers do not define the constant,
            // which the value table records as a zero. The message still names
            // the flag.
            expect(r.signal == abi.Signal.@"error");
            expect(r.beginsWith(unknown));
        } else {
            accepted += 1;
        }
    }
    expect(accepted >= 1);

    // Every vocabulary contains `:all`. Its *index* is a property of the
    // table's own order rather than of the flag, and this asserted index zero
    // until a container run: `windows_names` and `kqueue_names` open with it,
    // and `linux_names` is alphabetical, so `access` sorts ahead. The assertion
    // was true on the two platforms anybody had run it on and false on the
    // third for as long as it existed.
    expect(filewatch_core.flagIndex(platform, "all") != null);

    // A name that belongs to a different backend is refused here, which is
    // what makes the split a split rather than one shared vocabulary. The
    // three tables share only `all`.
    const other: Platform = if (platform == .linux) .windows else .linux;
    var refused: u32 = 0;
    for (0..filewatch_core.flagCount(other)) |i| {
        const name = filewatch_core.flagName(other, i).?;
        if (std.mem.eql(u8, name, "all")) continue;
        // Names shared with this platform's vocabulary are not the test.
        if (filewatch_core.flagIndex(platform, name) != null) continue;
        var argv = [_]repr.Value{ chan, value.fromBytes(name, .keyword) };
        expectRaisePrefix("filewatch/new", &argv, unknown);
        refused += 1;
    }
    expect(refused >= 1);
}

/// A mark callback and nothing else. Every other slot being null is what makes
/// a watcher opaque to `get`, `put`, `next`, `compare` and the rest, and none
/// of that is visible from Janet.
fn theAbstractType(chan: repr.Value) void {
    var argv = [_]repr.Value{chan};
    const watcher = callCore("filewatch/new", &argv);
    expect(harness.isType(watcher, repr.Tag.abstract));

    // A `Janet` in a local is not a root: the collector scans the VM and the
    // fiber stacks, and a cfunction's arguments are on one of those. Nothing
    // here is, so every watcher this file keeps across an allocation has to be
    // rooted by hand, and a watcher that is collected closes its stream, so
    // the symptom is a later call failing on a descriptor the test still
    // believes it owns.
    gc_alloc.gcroot(watcher);
    defer _ = gc_alloc.gcunroot(watcher);

    const abst = wrap.toAbstract(watcher);
    const at = &filewatch_core.watcherType;
    expect(std.mem.eql(u8, at.name, "filewatch/watcher"));
    // The `gc` callback exists exactly where there is something to release.
    // Only the kqueue backend opens a descriptor per watched path; on the
    // other two a watcher owns nothing outside the collector's heap, and a
    // callback that did nothing would be one more thing to read and discount.
    expect((at.gc != null) ==
        (backend != null and backend.?.platform == .kqueue));
    expect(at.gcmark != null);
    expect(at.get == null);
    expect(at.put == null);
    expect(at.marshal == null);
    expect(at.unmarshal == null);
    expect(at.tostring == null);
    expect(at.compare == null);
    expect(at.hash == null);
    expect(at.next == null);
    expect(at.call == null);
    expect(at.length == null);
    expect(at.bytes == null);
    expect(at.gcperthread == null);

    // The registered type is this one: `abstract` stored this address
    // and a watcher reports it.
    expect(abi.abstractHead(abst).type == at);

    // The live watcher marks without complaint.
    at.gcmark.?(abst, abi.abstractHead(abst).size);

    // And a watcher that never reached its backend's `init`. `abstract`
    // does not zero, so the guard is a read of whatever was there; a zeroed one
    // is the case it exists for, and the collector reaching a watcher in that
    // state is what a raise between the allocation and the initialisation would
    // leave behind.
    const size = abi.abstractHead(abst).size;
    const blank = abstracts.newBytes(@ptrCast(at), size);
    const bytes: [*]u8 = @ptrCast(blank);
    @memset(bytes[0..size], 0);
    at.gcmark.?(blank, size);

    // Its stream is null, which is a closed watcher to every call that asks.
    // Windows keeps no stream on the watcher and has no such state.
    if (!windows) {
        const unready = wrap.fromAbstract(blank);
        gc_alloc.gcroot(unready);
        defer _ = gc_alloc.gcunroot(unready);
        var add_argv = [_]repr.Value{ unready, value.fromBytes(probe_dir, .string), value.fromBytes("all", .keyword) };
        expectRaise("filewatch/add", &add_argv, "watcher is closed");
        var remove_argv = [_]repr.Value{ unready, value.fromBytes(probe_dir, .string) };
        expectRaise("filewatch/remove", &remove_argv, "watcher is closed");
        var listen_argv = [_]repr.Value{unready};
        expectRaise("filewatch/listen", &listen_argv, "watcher is closed");
    }
}

fn theLifecycle(chan: repr.Value) void {
    var new_argv = [_]repr.Value{chan};
    const dir = value.fromBytes(probe_dir, .string);

    // `std.posix` has neither of these in 0.16 and nothing in the tree
    // translates <sys/stat.h>, so they are the libc entry points by name. An
    // existing directory is fine; anything else fails the `add` below.
    _ = std.c.rmdir(probe_dir);
    _ = std.c.mkdir(probe_dir, 0o755);

    const watcher = callCore("filewatch/new", &new_argv);
    expect(harness.isType(watcher, repr.Tag.abstract));
    gc_alloc.gcroot(watcher);
    defer _ = gc_alloc.gcunroot(watcher);

    // A path the host cannot open. The two backends word this differently,
    // inotify reporting `evLasterr` bare and kqueue prefixing it, and
    // both are the host's `strerror` after that.
    {
        var argv = [_]repr.Value{
            watcher,
            value.fromBytes(probe_dir ++ "/no-such-entry", .string),
            value.fromBytes("all", .keyword),
        };
        expectAnyRaise("filewatch/add", &argv);
    }

    // Adding returns the watcher itself rather than a descriptor, which is
    // what lets `(-> w (filewatch/add p) (filewatch/add q))` thread.
    {
        var argv = [_]repr.Value{ watcher, dir, value.fromBytes("all", .keyword) };
        expect(order.equals(callCore("filewatch/add", &argv), watcher));
    }

    // A path that was never added has no descriptor to look up.
    {
        var argv = [_]repr.Value{ watcher, value.fromBytes(probe_dir ++ "/never-added", .string) };
        expectRaise("filewatch/remove", &argv, "bad watch descriptor");
    }

    // A removal succeeds with a dirty `errno`. A loop that repeats while the
    // call *succeeded* and `errno` is EINTR turns one successful
    // removal into two attempts, and the second one fails. `c.retryIntr`
    // repeats only a call that failed, so a stale `errno` changes nothing.
    {
        var argv = [_]repr.Value{ watcher, dir };
        std.c._errno().* = @intFromEnum(std.posix.E.INTR);
        expect(order.equals(callCore("filewatch/remove", &argv), watcher));
    }

    // With a clean `errno` the same call is the ordinary one, and it reports
    // with the watcher. The descriptor above is gone, so this needs a fresh
    // watch first.
    {
        var add_argv = [_]repr.Value{ watcher, dir, value.fromBytes("all", .keyword) };
        var rm_argv = [_]repr.Value{ watcher, dir };
        _ = callCore("filewatch/add", &add_argv);
        std.c._errno().* = 0;
        expect(order.equals(callCore("filewatch/remove", &rm_argv), watcher));
    }

    // Listening twice is refused, and that refusal is the only thing outside
    // the event loop that reads `is_watching`. Unlistening twice is *not*
    // refused: the second call returns without touching the stream.
    {
        var argv = [_]repr.Value{ watcher, dir, value.fromBytes("all", .keyword) };
        var one = [_]repr.Value{watcher};
        _ = callCore("filewatch/add", &argv);
        expect(harness.isType(callCore("filewatch/listen", &one), repr.Tag.nil));
        expectRaise("filewatch/listen", &one, "already watching");
        expect(harness.isType(callCore("filewatch/unlisten", &one), repr.Tag.nil));
        expect(harness.isType(callCore("filewatch/unlisten", &one), repr.Tag.nil));
    }

    // The watcher is closed after that, and all three calls say so.
    // `filewatch/unlisten` closes the watcher's own descriptor, the inotify
    // instance or the kqueue, and nothing reopens it. The one that matters
    // is `listen`: without the refusal it reported success, started a fiber on
    // a closed stream, delivered nothing ever again, and kept the event loop
    // from finishing, so a program saw the failure nowhere at all.
    //
    // This is the last thing the lifecycle does, because it is the end of it.
    {
        var argv = [_]repr.Value{ watcher, dir, value.fromBytes("all", .keyword) };
        expectRaise("filewatch/add", &argv, "watcher is closed");
        var one = [_]repr.Value{watcher};
        expectRaise("filewatch/listen", &one, "watcher is closed");
        var two = [_]repr.Value{ watcher, dir };
        expectRaise("filewatch/remove", &two, "watcher is closed");
    }

    _ = std.c.rmdir(probe_dir);
}

/// A kqueue event on a watched directory names the directory whole, with an
/// empty file name, and one on a watched file splits its path at the last
/// separator. See the header on why this runs the loop.
fn theEventNamesAWatchedDirectory() void {
    harness.inFiber(harness.coreEnv(),
        \\(def dir "/tmp/wattle-filewatch-contract-events")
        \\(def file (string dir "/f"))
        \\(def other (string dir "/g"))
        \\(os/mkdir dir)
        \\(spit file "x")
        \\(def ch (ev/chan 16))
        \\(def fw (filewatch/new ch))
        \\(defn event-for [path]
        \\  (ev/with-deadline 2
        \\    (var found nil)
        \\    (while (nil? found)
        \\      (def event (ev/take ch))
        \\      (when (= path (event :wd-path)) (set found event)))
        \\    found))
        \\(defer (do (filewatch/unlisten fw) (os/rm file) (os/rm other) (os/rmdir dir))
        \\  (filewatch/add fw dir :write)
        \\  (filewatch/add fw file :write)
        \\  (filewatch/listen fw)
        \\  (spit other "x")
        \\  (def on-dir (event-for dir))
        \\  (assert (= dir (on-dir :dir-name)))
        \\  (assert (= "" (on-dir :file-name)))
        \\  (spit file "xy")
        \\  (def on-file (event-for file))
        \\  (assert (= dir (on-file :dir-name)))
        \\  (assert (= "f" (on-file :file-name))))
    );
}

// ==========================================================================
// Entry
// ==========================================================================

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
        if (be.platform == .kqueue and harness.coreOptional("os/mkdir") != null) {
            theEventNamesAWatchedDirectory();
        }
    }

    std.debug.print("filewatch_core raises: {d}\n", .{raises_seen});
}
