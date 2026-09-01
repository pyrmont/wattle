//! Behavioral contract for the event loop, the scheduler, streams and
//! channels.
//!
//! ## What the Janet suites cannot reach
//!
//! `test/suite-ev.janet` has 742 assertions and every one of them goes through
//! the thirty `ev/` bindings. Five areas have no Janet spelling at all:
//!
//!  - **The embedder's channel API.** `janet_channel_make`,
//!    `janet_channel_give` and `janet_channel_take` are the non-blocking mode
//!    (`mode == 2`) of the push and pop, which `ev/give` and `ev/take` never
//!    select. Only the supervisor path inside the loop reaches it otherwise,
//!    and then only on a fiber that has already failed.
//!  - **`makeStreamExt`.** Type-punning a stream -- a larger allocation and a
//!    caller-supplied method table -- is what `net.zig` does and what no Janet
//!    program can ask for.
//!  - **`makePipe`'s four modes.** Janet reaches mode 1 through `os/spawn` and
//!    nothing else; the descriptor flags each mode sets are invisible from
//!    Janet even then.
//!  - **`janet_ev_default_threaded_callback`'s nine tags.** `ev/thread` uses
//!    two of them.
//!  - **The abis.** `janet_channel_give`, `janet_marshal` and their kin are
//!    published, and what an embedder sees when one refuses is a report rather
//!    than an error. `harness.abiRaised` is the instrument for that half and
//!    `harness.raised` for the other.
//!
//! ## What it deliberately does not do
//!
//! It does not drive the polling backend. `loop1` blocks until a descriptor is
//! ready or a timeout expires, and a contract that waits on the kernel is a
//! contract that hangs when it is wrong. What is checked instead is everything
//! either side of the poll: the loop's own exit condition, the timer heap's
//! ordering decisions, and the self-pipe round trip, which one turn of the
//! loop performs without entering the backend at all.
//!
//! ## Why a contract inside the compilation matters here
//!
//! Four of the five things a C contract needed from an adapter object were the
//! reason that object existed:
//!
//!  - a protected scope so that a C body could raise into it. `harness.raised`
//!    is that, and the section below tests it directly.
//!  - three shims that called an abstract type's raising callbacks on C's
//!    behalf. `janet_stream_type` is an `abstract_type.AbstractType` here, so
//!    the callbacks are called and the error is handled.
//!  - an adapter that turned a C cfunction into one the runtime could call. A
//!    cfunction written in Zig needs no adapter; `raise.stored` is the cast
//!    that puts one in a `JanetMethod` row or a `janet_def`.
//!
//! **The section that tested the shim tests the harness instead.** Deleting it
//! outright would drop the only direct check of the mechanism sixty-three
//! contracts rest on, so the same three claims point at `harness.raised`: a
//! returning call answers null, a raising call answers the signal and the
//! payload, and the scopes nest.
//!
//! **The Windows arm compiles, and its predecessor did not.** `zig build
//! -Dtarget=x86_64-windows-gnu -Dinstall-tests=true` failed on three
//! `INVALID_HANDLE_VALUE`s, and nothing caught it because the driver that held
//! them was installed only under `-Dinstall-tests` and the matrix's
//! cross-compile entries do not pass it. This driver is installed
//! unconditionally, so those entries compile this file.

const std = @import("std");
const builtin = @import("builtin");
const repr = @import("repr");
const constants = @import("constants");
const raise = @import("subsystems").raise;
const harness = @import("harness.zig");

const subsystems = @import("subsystems");
const value = @import("subsystems").value;
const gc_alloc = @import("subsystems").gc_alloc;
const buffers = @import("subsystems").value.buffers;
const utils = @import("subsystems").utils;
const order = @import("subsystems").value.order;
const gc_mark = @import("subsystems").gc_mark;
const core_env = @import("subsystems").env;
const registry = @import("subsystems").registry;
const wrap = @import("subsystems").value.wrap;
const vm_lifecycle = @import("subsystems").lifecycle;
const pp_describe = @import("subsystems").pp_describe;
const ev_mod = @import("subsystems").ev;
const ev_channel = @import("subsystems").ev_channel;
const c = @import("cabi");
const strings = @import("subsystems").value.strings;
const tuples = @import("subsystems").value.tuples;
/// `boundary` rather than `abi`, which a local below binds to a raise report.
const boundary = @import("abi");
const method_type = @import("subsystems").method_type;
const host = @import("host");
const ev = subsystems.ev;
const channel = subsystems.ev_channel;
const stream = subsystems.ev_stream;

const expect = @import("expect.zig").expect;
const windows = builtin.os.tag == .windows;

/// Whether closing a stream whose handle was never registered with the backend
/// is quiet.
///
/// It is not, on epoll. `ev_backend.zig`'s two `unregister` implementations
/// disagree about the same error path: the kqueue one discards the status of
/// its `EV_DELETE` -- "the status might be -1 on the BSDs for subprocesses" --
/// and the epoll one ends `if (status == -1) return raise.panicv(...)`. So a
/// `dup`ed handle, which was never `EPOLL_CTL_ADD`ed under its own number,
/// raises ENOENT on Linux and is silently ignored on macOS.
///
/// `FOUND.md` has the entry. It is quarantined here rather than fixed, because
/// the divergence is inherited from Janet and a gate is not where a
/// behavioural change to the event loop belongs: assert the part that is
/// common and quarantine the rest.
const unregister_of_an_unregistered_handle_is_quiet = builtin.os.tag != .linux;

/// `INVALID_HANDLE_VALUE`, written out rather than imported.
///
/// `ev/stream.zig` has the same two lines privately, and that is deliberate:
/// the constant is the *host's*, so a contract that imported the subject's
/// copy could not notice the subject having the wrong one.
fn invalidHandle() host.Handle {
    return if (windows) @ptrFromInt(std.math.maxInt(usize)) else -1;
}

fn payloadIs(payload: repr.Value, text: []const u8) bool {
    if (!harness.isType(payload, repr.Tag.string)) return false;
    const s = wrap.toString(payload);
    const length: usize = strings.head(s).length;
    return std.mem.eql(u8, s[0..length], text);
}

/// One Janet source string, evaluated for its value. Every use here builds
/// fibers and channels the C sections then drive by hand, so a failure to
/// compile is a broken contract rather than a tested refusal.
fn doString(source: [*:0]const u8) repr.Value {
    var out = wrap.fromNil();
    if (core_env.dostring(harness.coreEnv(), source, "ev_loop", &out) != 0) {
        std.debug.print("ev_loop: {s}\n", .{pp_describe.toString(out)});
        @panic("ev_loop: a contract form failed");
    }
    return out;
}

// ==========================================================================
// The protected scope, which is now the harness's own
// ==========================================================================

fn raisesContractPanic() raise.Raising(void) {
    return raise.panic("contract panic");
}

fn returnsQuietly() raise.Raising(void) {
    return;
}

/// `harness.raised` is what `janet_contract_protect` was, and it is the
/// mechanism every contract in this driver rests on. Nothing else asserts it
/// directly, so the three claims the C section made about the shim are kept
/// and pointed here.
fn theProtectedScope() void {
    // The returning arm answers null.
    expect(harness.raised(returnsQuietly, .{}) == null);

    // The raising arm answers the signal and the payload.
    const r = harness.raised(raisesContractPanic, .{}).?;
    expect(r.signal == boundary.Signal.@"error");
    expect(r.says("contract panic"));

    // Scopes nest, and the inner one does not swallow the outer's state. This
    // is the claim that is about the scope rather than about the call: an
    // inner `janet_try_init` moves `vm.return_reg` and `janet_restore`
    // has to put back what was there, not null.
    const outer = harness.raised(struct {
        fn body() raise.Raising(void) {
            expect(harness.raised(returnsQuietly, .{}) == null);
            const inner = harness.raised(raisesContractPanic, .{}).?;
            expect(inner.says("contract panic"));
            return raise.panic("outer panic");
        }
    }.body, .{}).?;
    expect(outer.says("outer panic"));
}

// ==========================================================================
// Channels
// ==========================================================================

fn theEmbedderChannelApi() void {
    const chan = channel.channelMake(2).?;
    const chanv = wrap.fromAbstract(chan);
    gc_alloc.gcroot(chanv);
    defer _ = gc_alloc.gcunroot(chanv);

    // Nothing to take from an empty channel, and mode 2 registers no pending
    // read, so a second take behaves the same as the first.
    var out = value.fromBytes("untouched", .keyword);
    expect(!try_(channel.channelTake(chan, &out)));
    expect(harness.isType(out, repr.Tag.keyword));
    expect(!try_(channel.channelTake(chan, &out)));

    // Two gives fit under the limit and report "do not block".
    expect(!try_(channel.channelGive(chan, harness.wrapInteger(1))));
    expect(!try_(channel.channelGive(chan, harness.wrapInteger(2))));
    // The third exceeds the limit; mode 2 declines to block and says so.
    expect(try_(channel.channelGive(chan, harness.wrapInteger(3))));

    // All three are queued, in order.
    for ([_]i32{ 1, 2, 3 }) |expected| {
        expect(try_(channel.channelTake(chan, &out)));
        expect(wrap.toInteger(out) == expected);
    }
    expect(!try_(channel.channelTake(chan, &out)));
}

/// A raising call this contract expects to return. `try` needs an error union
/// in the enclosing signature and these sections are `void`, so the unwrap is
/// here with the panic that says which one it was.
fn try_(result: anytype) @typeInfo(@TypeOf(result)).error_union.payload {
    return result catch @panic("ev_loop: a call that should have returned raised");
}

fn theThreadedChannel() void {
    // A threaded channel is a threaded abstract, so it is not on this thread's
    // GC heap and takes its lock on every operation.
    const chan = channel.channelMakeThreaded(1).?;
    var out = wrap.fromNil();
    expect(!try_(channel.channelGive(chan, harness.wrapInteger(7))));
    expect(try_(channel.channelTake(chan, &out)));
    expect(wrap.toInteger(out) == 7);

    // Packing is what a threaded channel does that an ordinary one does not: a
    // value that is not one of the five self-contained types is marshalled on
    // the way in and unmarshalled on the way out.
    expect(!try_(channel.channelGive(chan, value.fromBytes("packed", .string))));
    expect(try_(channel.channelTake(chan, &out)));
    expect(payloadIs(out, "packed"));
}

/// Giving to a closed channel raises, and this asserts the *abi* -- what a
/// caller across a compilation boundary sees, which is a report. The import
/// beside it is the same refusal arriving as an error.
fn theClosedChannel() void {
    const chanv = doString("(def c (ev/chan 4)) (ev/chan-close c) c");
    gc_alloc.gcroot(chanv);
    defer _ = gc_alloc.gcunroot(chanv);
    var argv = [_]repr.Value{chanv};
    const chan = try_(channel.getChannel(&argv, 0)).?;

    // Taking from a closed channel succeeds and yields nil.
    var out = harness.wrapInteger(99);
    expect(try_(channel.channelTake(chan, &out)));
    expect(harness.isType(out, repr.Tag.nil));

    const abi = harness.abiRaised(subsystems.ev_channel.channelGiveAbi, .{ chan, harness.wrapInteger(1) }).?;
    expect(abi.signal == boundary.Signal.@"error");
    expect(abi.says("cannot write to closed channel"));

    const imported = harness.raised(channel.channelGive, .{ chan, harness.wrapInteger(1) }).?;
    expect(imported.says("cannot write to closed channel"));
}

fn theChannelGetters() void {
    const chanv = doString("(ev/chan 3)");
    gc_alloc.gcroot(chanv);
    defer _ = gc_alloc.gcunroot(chanv);

    var argv = [_]repr.Value{ chanv, wrap.fromNil() };
    const chan = try_(channel.getChannel(&argv, 0)).?;
    expect(try_(channel.getChannel(&argv, 0)) == chan);

    // `optChannel` takes the default for a missing argument and for nil, and
    // the channel for anything else. The count travels in the slice: the abi
    // that took `(argv, argc, n)` is `capi.zig`'s `janet_optchannel`, and what
    // is left here reads `argv.len`.
    expect(try_(ev_channel.optChannel(argv[0..1], 1, null)) == null);
    expect(try_(ev_channel.optChannel(argv[0..2], 1, null)) == null);
    expect(try_(ev_channel.optChannel(argv[0..2], 0, null)) == chan);
}

// ==========================================================================
// Streams
// ==========================================================================

fn probeMethod(argv: []repr.Value) raise.Raising(repr.Value) {
    _ = @as(i32, @intCast(argv.len));

    return value.fromBytes("probe", .keyword);
}

const probe_methods = [_]method_type.CMethod{
    .{ .name = "probe", .cfun = raise.stored(&probeMethod) },
    .{ .name = null, .cfun = null },
};

/// A stream with room for a payload after the header, which is what
/// `makeStreamExt` exists for.
const ProbeStream = extern struct {
    stream: stream.Stream,
    marker: u64,
};

/// A pipe, and the pair of handles it answers with. Every stream section needs
/// one and every one of them closes the far end by hand.
fn probePipe() [2]host.Handle {
    var handles: [2]host.Handle = undefined;
    expect(stream.makePipe(&handles, 0) == 0);
    return handles;
}

fn closeFarEnd(handles: [2]host.Handle) void {
    if (!windows) _ = c.close(handles[1]);
}

fn theStreamExtension() void {
    const handles = probePipe();
    const ps: *ProbeStream = @ptrCast(@alignCast(try_(stream.makeStreamExt(
        handles[0],
        @intCast(constants.JANET_STREAM_READABLE),
        &probe_methods,
        @sizeOf(ProbeStream),
    ))));
    ps.marker = 0x0123456789ABCDEF;

    const s = &ps.stream;
    expect(s.handle == handles[0]);
    expect(s.flags == @as(u32, @intCast(constants.JANET_STREAM_READABLE)));
    expect(s.read_fiber == null and s.write_fiber == null);
    expect(@intFromPtr(s.methods) == @intFromPtr(&probe_methods));

    // The abstract's size is the caller's, not the header's.
    expect(boundary.abstractHead(ps).size == @sizeOf(ProbeStream));

    // The abstract carries the type this file imports rather than some other
    // registration of the same name. Asserted through `janet_abstract_type`,
    // whose answer is a run-time value: two declarations compared at comptime
    // are never equal whatever the linker did.
    expect(boundary.abstractHead(ps).type == &stream.streamType);

    // The getter reaches the caller's table rather than the default one.
    const at = &stream.streamType;
    const found = try_(at.get.?(ps, value.fromBytes("probe", .keyword))).?;
    expect(harness.isType(found, repr.Tag.cfunction));
    expect(try_(at.get.?(ps, value.fromBytes("close", .keyword))) == null);

    // `next` walks the same table.
    expect(harness.keywordIs(try_(at.next.?(ps, wrap.fromNil())), "probe"));
    expect(harness.isType(try_(at.next.?(ps, value.fromBytes("probe", .keyword))), repr.Tag.nil));

    expect(ps.marker == 0x0123456789ABCDEF);
    try_(stream.streamClose(s));
    expect(s.flags & @as(u32, @intCast(constants.JANET_STREAM_CLOSED)) != 0);
    expect(s.handle == invalidHandle());
    // Closing twice is a no-op rather than a double close.
    try_(stream.streamClose(s));
    expect(s.handle == invalidHandle());
    closeFarEnd(handles);
}

fn theDefaultMethods() void {
    const handles = probePipe();
    const s = try_(stream.makeStream(handles[0], @intCast(constants.JANET_STREAM_READABLE), null));
    const at = &stream.streamType;

    // A null method table means the four default stream methods.
    //
    // Named through the core bindings rather than as symbols: a cfunction is
    // not a C function, so what is asserted is that the method table and the
    // `ev/` binding are the same
    // asserted is that the method table and the `ev/` binding are the same
    // function, which is slightly stronger than comparing addresses would be.
    inline for (.{ "close", "read", "chunk", "write" }) |name| {
        const out = try_(at.get.?(s, value.fromBytes(name, .keyword))).?;
        expect(harness.isType(out, repr.Tag.cfunction));
        expect(wrap.toCfunction(out) ==
            wrap.toCfunction(registry.resolveCore("ev/" ++ name)));
    }

    // A non-keyword key is not a method lookup.
    expect(try_(at.get.?(s, harness.wrapInteger(0))) == null);
    try_(stream.streamClose(s));
    closeFarEnd(handles);
}

fn theStreamRendering() void {
    const handles = probePipe();
    const s = try_(stream.makeStream(handles[0], @intCast(constants.JANET_STREAM_READABLE), null));
    const buffer = buffers.new(16);
    try_(stream.streamType.tostring.?(s, @ptrCast(buffer)));

    var expected: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&expected, "[fd={d}]", .{
        if (windows) @as(i32, @intCast(@intFromPtr(handles[0]))) else handles[0],
    }) catch unreachable;
    expect(buffer.count == @as(i32, @intCast(text.len)));
    expect(std.mem.eql(u8, buffer.slice()[0..text.len], text));

    try_(stream.streamClose(s));
    closeFarEnd(handles);
}

fn theStreamFlagMessages() void {
    const handles = probePipe();
    const readable: u32 = @intCast(constants.JANET_STREAM_READABLE);
    const writable: u32 = @intCast(constants.JANET_STREAM_WRITABLE);
    const socket: u32 = @intCast(constants.JANET_STREAM_SOCKET);
    const acceptable: u32 = @intCast(constants.JANET_STREAM_ACCEPTABLE);
    const udpserver: u32 = @intCast(constants.JANET_STREAM_UDPSERVER);

    const s = try_(stream.makeStream(handles[0], readable | socket, null));

    // Every flag the caller asks for is present, so nothing is raised.
    expect(harness.raised(stream.streamFlags, .{ s, readable }) == null);
    expect(harness.raised(stream.streamFlags, .{ s, readable | socket }) == null);

    // The message names every flag that was *asked for*, in a fixed order, and
    // the last word is "socket" only when a socket was asked for.
    {
        const r = harness.raised(stream.streamFlags, .{ s, writable }).?;
        expect(r.says("bad stream, expected writable stream"));
    }
    {
        const all = readable | writable | acceptable | udpserver | socket;
        const r = harness.raised(stream.streamFlags, .{ s, all }).?;
        expect(r.says("bad stream, expected readable writable server datagram socket"));
    }

    // A closed stream is refused before its flags are looked at.
    try_(stream.streamClose(s));
    {
        const r = harness.raised(stream.streamFlags, .{ s, readable }).?;
        expect(r.says("stream is closed"));
    }
    closeFarEnd(handles);
}

fn theNotCloseableStream() void {
    const handles = probePipe();
    const flags: u32 = @intCast(constants.JANET_STREAM_READABLE | constants.JANET_STREAM_NOT_CLOSEABLE);
    const s = try_(stream.makeStream(handles[0], flags, null));
    try_(stream.streamClose(s));

    // The handle is forgotten either way; what NOT_CLOSEABLE changes is that
    // the descriptor itself survives, which is why it is still usable here.
    expect(s.flags & @as(u32, @intCast(constants.JANET_STREAM_CLOSED)) != 0);
    expect(s.handle == invalidHandle());

    if (!windows) {
        var byte: u8 = 'x';
        expect(c.write(handles[1], @ptrCast(&byte), 1) == 1);
        expect(c.read(handles[0], @ptrCast(&byte), 1) == 1);
        _ = c.close(handles[0]);
        _ = c.close(handles[1]);
    }
}

// ==========================================================================
// Pipes
// ==========================================================================

/// The flag values are `std`'s rather than the subject's, which has its own
/// four constants ten lines from `makePipe`. Importing them
/// would make this compare the subject with itself, and the question here is
/// whether the descriptor the *host* handed back carries the flag.
const fd_cloexec: c_int = std.c.FD_CLOEXEC;
const o_nonblock: c_int = @bitCast(@as(u32, @bitCast(std.c.O{ .NONBLOCK = true })));

fn isCloexec(fd: c_int) bool {
    const flags = c.fcntl(fd, std.c.F.GETFD);
    expect(flags != -1);
    return flags & fd_cloexec != 0;
}

fn isNonblock(fd: c_int) bool {
    const flags = c.fcntl(fd, std.c.F.GETFL);
    expect(flags != -1);
    return flags & o_nonblock != 0;
}

/// The four modes and exactly which descriptor gets which flag. The mode
/// numbers are what `os/spawn` and the self pipe pass, and nothing in Janet
/// can observe the result.
fn thePipeModes() void {
    // mode: cloexec0 cloexec1 nonblock0 nonblock1
    const expected = [4][4]bool{
        .{ true, true, true, true },
        .{ true, false, true, false },
        .{ false, true, false, true },
        .{ true, true, false, false },
    };
    for (expected, 0..) |row, mode| {
        var h: [2]host.Handle = undefined;
        expect(stream.makePipe(&h, @intCast(mode)) == 0);
        expect(isCloexec(h[0]) == row[0]);
        expect(isCloexec(h[1]) == row[1]);
        expect(isNonblock(h[0]) == row[2]);
        expect(isNonblock(h[1]) == row[3]);

        // The two ends are a pipe rather than two unrelated descriptors.
        var byte: u8 = @intCast('a' + mode);
        var got: u8 = 0;
        expect(c.write(h[1], @ptrCast(&byte), 1) == 1);
        expect(c.read(h[0], @ptrCast(&got), 1) == 1);
        expect(got == byte);
        _ = c.close(h[0]);
        _ = c.close(h[1]);
    }
}

fn theLastError() void {
    // `janet_ev_lasterr` reads errno and renders it, with no side effect of
    // its own -- the same errno gives the same string twice.
    std.c._errno().* = @intFromEnum(std.posix.E.BADF);
    const first = stream.evLasterr();
    const second = stream.evLasterr();
    expect(harness.isType(first, repr.Tag.string));
    expect(order.equals(first, second));
    std.c._errno().* = @intFromEnum(std.posix.E.INVAL);
    expect(!order.equals(first, stream.evLasterr()));
}

// ==========================================================================
// The loop's own state
// ==========================================================================

fn theLoopExitCondition() void {
    // Nothing scheduled, no timers, no listeners.
    expect(ev_mod.loopDone());

    // A listener is enough to keep the loop alive, and the count is a count
    // rather than a flag.
    ev.evIncRefcount();
    expect(!ev_mod.loopDone());
    ev.evIncRefcount();
    expect(!ev_mod.loopDone());
    ev.evDecRefcount();
    expect(!ev_mod.loopDone());
    ev.evDecRefcount();
    expect(ev_mod.loopDone());
}

const PostRecord = struct {
    calls: u32 = 0,
    tag: i32 = 0,
    value: repr.Value = undefined,
};

var post_record: PostRecord = .{};

fn postCallback(msg: ev_mod.GenericMessage) callconv(.c) void {
    post_record.calls += 1;
    post_record.tag = msg.tag;
    post_record.value = msg.argj;
}

/// The self pipe, end to end: posting an event raises the listener count, and
/// one turn of the loop delivers the callback and lowers it again. On Windows
/// the same round trip goes through the completion port instead.
fn thePostedEventRoundTrip() void {
    post_record = .{};
    var msg = std.mem.zeroes(ev_mod.GenericMessage);
    msg.tag = 41;
    msg.argj = harness.wrapInteger(42);

    expect(ev_mod.loopDone());
    ev.evPostEvent(null, &postCallback, msg);
    expect(!ev_mod.loopDone());

    raise.reported(ev_mod.loop());
    expect(post_record.calls == 1);
    expect(post_record.tag == 41);
    expect(wrap.toInteger(post_record.value) == 42);
    expect(ev_mod.loopDone());
}

/// A null callback is what `janet_loop1_interrupt` posts, to wake a loop that
/// is blocked in the backend and do nothing else.
///
/// **The reference it takes is never given back.** `janet_ev_post_event`
/// raises the listener count unconditionally, and the self-pipe handler lowers
/// it only inside `if (response.cb) |cb|`. So a null callback leaves the count
/// one higher for ever and `janet_loop_done` never reports done again. The
/// Windows completion port lowers it outside the test and does not have this.
/// Both are reproduced rather than repaired, and `FOUND.md` has the entry --
/// which is why this drives one turn of the loop rather than calling
/// `janet_loop`, and why it puts the count back by hand afterwards.
fn theNullCallback() void {
    expect(ev_mod.loopDone());
    const msg = std.mem.zeroes(ev_mod.GenericMessage);
    ev.evPostEvent(null, null, msg);
    expect(!ev_mod.loopDone());
    _ = raise.reported(ev_mod.loop1());
    if (windows) {
        expect(ev_mod.loopDone());
    } else {
        expect(!ev_mod.loopDone());
        ev.evDecRefcount();
        expect(ev_mod.loopDone());
    }
}

/// `janet_ev_default_threaded_callback` with a null fiber is the cleanup-only
/// path: nothing is scheduled and the payload is released. Every tag frees,
/// because both of the original's switches send everything but the two
/// `*_STRINGF` cases to a `default` that also frees.
fn theThreadedReplyTags() void {
    const tags = [_]c_int{
        constants.JANET_EV_TCTAG_NIL,         constants.JANET_EV_TCTAG_INTEGER,
        constants.JANET_EV_TCTAG_STRING,      constants.JANET_EV_TCTAG_STRINGF,
        constants.JANET_EV_TCTAG_KEYWORD,     constants.JANET_EV_TCTAG_ERR_STRING,
        constants.JANET_EV_TCTAG_ERR_STRINGF, constants.JANET_EV_TCTAG_ERR_KEYWORD,
        constants.JANET_EV_TCTAG_BOOLEAN,
    };
    var freed: u32 = 0;
    for (tags) |tag| {
        var msg = std.mem.zeroes(ev_mod.GenericMessage);
        msg.tag = @intCast(tag);
        msg.fiber = null;
        // A heap payload, so that a missing free is a leak a sanitizer sees
        // and a double free is a crash.
        const payload = utils.malloc(8).?;
        const bytes: [*]u8 = @ptrCast(payload);
        @memcpy(bytes[0..8], "abcdefg\x00");
        msg.argp = payload;
        ev_mod.evDefaultThreadedCallback(msg);
        freed += 1;
    }
    expect(freed == 9);
    // The loop is untouched: a null fiber schedules nothing.
    expect(ev_mod.loopDone());
}

// ==========================================================================
// The timer heap
// ==========================================================================

/// Scheduling three deadlines out of order checks the ordering the heap
/// imposes rather than the wall clock: they come back in order.
fn theOrderedTimeouts() void {
    const out = doString(
        \\(def log @[])
        \\(defn t [n d] (ev/go (fn [] (ev/sleep d) (array/push log n))))
        \\(t :c 0.03) (t :a 0.01) (t :b 0.02)
        \\(ev/sleep 0.06)
        \\log
    );
    expect(harness.isType(out, repr.Tag.array));
    const log = wrap.toArray(out);
    expect(log.count == 3);
    expect(harness.keywordIs(log.slice()[0], "a"));
    expect(harness.keywordIs(log.slice()[1], "b"));
    expect(harness.keywordIs(log.slice()[2], "c"));
}

/// `janet_addtimeout` and `janet_addtimeout_nil` differ in one field of the
/// `Timeout` they build: `is_error`. An expired error timeout cancels the
/// fiber and an expired nil timeout resumes it with nil.
///
/// Neither can be called from here directly -- both read
/// `vm.root_fiber`, which is only set while the loop is running a task
/// -- and `janet_addtimeout_nil` has **no Janet caller at all**: `ev/read`'s
/// optional timeout uses the error one, and only the socket layer uses the
/// other. So the contract lends the core environment a cfunction of its own
/// and drives it from a task, which is the only way to reach the pair.
fn cfunAddTimeout(argv: []repr.Value) raise.Raising(repr.Value) {
    try subsystems.args.fixarity(argv, 2);
    const sec = try subsystems.args.getNumber(argv, 0);
    if (try subsystems.args.getBoolean(argv, 1)) {
        ev.addtimeout(sec);
    } else {
        ev.addtimeoutNil(sec);
    }
    return wrap.fromNil();
}

fn theTwoTimeoutConstructors() void {
    const env = harness.coreEnv();
    registry.def(
        env,
        "test/add-timeout",
        wrap.fromCfunction(raise.stored(&cfunAddTimeout)),
        "Contract-only: janet_addtimeout when the second argument is true, " ++
            "janet_addtimeout_nil when it is false.",
    );

    const out = doString(
        \\(def results @[])
        \\(ev/go (fn []
        \\  (test/add-timeout 0.01 false)
        \\  (array/push results [:nil (ev/take (ev/chan 0))])))
        \\(ev/go (fn []
        \\  (test/add-timeout 0.01 true)
        \\  (array/push results [:err (protect (ev/take (ev/chan 0)))])))
        \\(ev/sleep 0.08)
        \\results
    );
    const results = wrap.toArray(out);
    expect(results.count == 2);
    for (0..@intCast(results.count)) |i| {
        const row = wrap.toTuple(results.slice()[i]);
        if (harness.keywordIs(row[0], "nil")) {
            // `addtimeout_nil` resumes with nil rather than raising.
            expect(harness.isType(row[1], repr.Tag.nil));
        } else {
            // `addtimeout` cancels the fiber, so `protect` reports a failure
            // carrying the message the loop supplies.
            const pair = wrap.toTuple(row[1]);
            expect(harness.isType(pair[0], repr.Tag.boolean));
            expect(!wrap.toBoolean(pair[0]));
            expect(payloadIs(pair[1], "timeout"));
        }
    }
    expect(ev_mod.loopDone());
}

// ==========================================================================
// Scheduling
// ==========================================================================

/// `cancel` is the one scheduling entry point that raises, and only for a
/// fiber the loop has never seen.
///
/// The second half is the supervisor path, which is the loop's own use of the
/// non-blocking push (`mode == 2`) and which a Janet program reaches only by
/// passing a channel to `ev/go`. Attaching the channel by hand is what lets
/// this check the event's shape without one.
fn theCancelOfANonTask() void {
    const fiberv = doString("(fiber/new (fn [] 1) :e)");
    gc_alloc.gcroot(fiberv);
    defer _ = gc_alloc.gcunroot(fiberv);
    const fiber = wrap.toFiber(fiberv);

    {
        const r = harness.raised(ev.cancel, .{ fiber, value.fromBytes("nope", .string) }).?;
        expect(r.says("cannot cancel non-task fiber"));
    }

    // Scheduling it makes it a task, and cancelling then succeeds.
    const sup = channel.channelMake(4).?;
    const supv = wrap.fromAbstract(sup);
    gc_alloc.gcroot(supv);
    defer _ = gc_alloc.gcunroot(supv);
    fiber.supervisor_channel = @ptrCast(sup);

    ev.schedule(fiber, wrap.fromNil());
    expect(harness.raised(ev.cancel, .{ fiber, value.fromBytes("nope", .string) }) == null);
    raise.reported(ev_mod.loop());
    expect(ev_mod.loopDone());

    // The supervisor got `[:error fiber nil]` rather than a stack trace on
    // stderr, and the fiber's last value is what the cancel carried.
    var event = wrap.fromNil();
    expect(try_(channel.channelTake(sup, &event)));
    expect(harness.isType(event, repr.Tag.tuple));
    const tup = wrap.toTuple(event);
    expect(tuples.head(tup).length == 3);
    expect(harness.keywordIs(tup[0], "error"));
    expect(wrap.toFiber(tup[1]) == fiber);
    expect(harness.isType(tup[2], repr.Tag.nil));
    expect(payloadIs(fiber.last_value, "nope"));
    // One event, not two: the first schedule was superseded by the cancel.
    expect(!try_(channel.channelTake(sup, &event)));
}

/// `janet_schedule_soon` puts a task at the head of the spawn queue where
/// `janet_schedule` appends. Nothing in Janet chooses between them.
fn theScheduleSoonOrder() void {
    const out = doString(
        \\(def log @[])
        \\(def a (fiber/new (fn [] (array/push log :a))))
        \\(def b (fiber/new (fn [] (array/push log :b))))
        \\[log a b]
    );
    gc_alloc.gcroot(out);
    defer _ = gc_alloc.gcunroot(out);
    const tup = wrap.toTuple(out);
    const log = wrap.toArray(tup[0]);

    ev.schedule(wrap.toFiber(tup[1]), wrap.fromNil());
    ev.scheduleSoon(wrap.toFiber(tup[2]), wrap.fromNil(), boundary.Signal.ok);
    raise.reported(ev_mod.loop());

    expect(log.count == 2);
    expect(harness.keywordIs(log.slice()[0], "b"));
    expect(harness.keywordIs(log.slice()[1], "a"));
}

fn theScheduleSignalOrder() void {
    const out = doString(
        \\(def log @[])
        \\(def a (fiber/new (fn [] (array/push log :a)) :e))
        \\(def b (fiber/new (fn [] (array/push log :b)) :e))
        \\[log a b]
    );
    gc_alloc.gcroot(out);
    defer _ = gc_alloc.gcunroot(out);
    const tup = wrap.toTuple(out);
    const log = wrap.toArray(tup[0]);

    // `janet_schedule_signal` appends where `janet_schedule_soon` prepends,
    // and nothing in Janet chooses between the two.
    ev.scheduleSignal(wrap.toFiber(tup[1]), wrap.fromNil(), boundary.Signal.ok);
    ev.scheduleSoon(wrap.toFiber(tup[2]), wrap.fromNil(), boundary.Signal.ok);
    raise.reported(ev_mod.loop());

    expect(log.count == 2);
    expect(harness.keywordIs(log.slice()[0], "b"));
    expect(harness.keywordIs(log.slice()[1], "a"));
}

/// `theScheduleSignalOrder` pairs an append with a prepend, which cannot tell
/// "appends" from "prepends" -- with both prepending the order comes out the
/// same. Three appends in a row can.
fn theScheduleSignalIsFifo() void {
    const out = doString(
        \\(def log @[])
        \\(def a (fiber/new (fn [] (array/push log :a)) :e))
        \\(def b (fiber/new (fn [] (array/push log :b)) :e))
        \\(def c (fiber/new (fn [] (array/push log :c)) :e))
        \\[log a b c]
    );
    gc_alloc.gcroot(out);
    defer _ = gc_alloc.gcunroot(out);
    const tup = wrap.toTuple(out);
    const log = wrap.toArray(tup[0]);

    for (1..4) |i| {
        ev.scheduleSignal(wrap.toFiber(tup[@intCast(i)]), wrap.fromNil(), boundary.Signal.ok);
    }
    raise.reported(ev_mod.loop());

    expect(log.count == 3);
    expect(harness.keywordIs(log.slice()[0], "a"));
    expect(harness.keywordIs(log.slice()[1], "b"));
    expect(harness.keywordIs(log.slice()[2], "c"));
}

/// `cancel` appends too, and nothing above distinguishes that from prepending.
/// Both fibers report into the same channel, so the order they reach it in is
/// the assertion -- and the cancel's `sched_id` bump means the schedule that
/// preceded it is skipped rather than run.
fn theCancelAppends() void {
    const out = doString(
        \\(def out (ev/chan 8))
        \\(def a (fiber/new (fn [] (ev/give out :a)) :e))
        \\(def b (fiber/new (fn [] (ev/sleep 10)) :e))
        \\[out a b]
    );
    gc_alloc.gcroot(out);
    defer _ = gc_alloc.gcunroot(out);
    const tup = wrap.toTuple(out);
    const chan = try_(channel.getChannel(tup[0..1], 0)).?;
    const a = wrap.toFiber(tup[1]);
    const b = wrap.toFiber(tup[2]);
    b.supervisor_channel = @ptrCast(chan);

    // b is scheduled first, so it is a task and `cancel` will accept it; the
    // cancel then supersedes that schedule.
    ev.schedule(b, wrap.fromNil());
    ev.schedule(a, wrap.fromNil());
    expect(harness.raised(ev.cancel, .{ b, value.fromBytes("late", .string) }) == null);
    raise.reported(ev_mod.loop());

    var first = wrap.fromNil();
    var second = wrap.fromNil();
    expect(try_(channel.channelTake(chan, &first)));
    expect(try_(channel.channelTake(chan, &second)));
    // The task queued before the cancel runs first: the cancel appended.
    expect(harness.keywordIs(first, "a"));
    // And b ran once, as an error, rather than twice or as a sleep.
    expect(harness.isType(second, repr.Tag.tuple));
    expect(harness.keywordIs(wrap.toTuple(second)[0], "error"));
    expect(!try_(channel.channelTake(chan, &first)));
}

// ==========================================================================
// Marshalling a stream
// ==========================================================================

/// A stream carries a file descriptor, so both directions refuse to work
/// without `JANET_MARSHAL_UNSAFE` -- and the refusal reaches an embedder as a
/// report, which is what `janet_marshal` is. `ev/thread` is the only thing in
/// Janet that marshals unsafely, and it never marshals a bare stream, so
/// neither the refusal nor the success path has a Janet spelling.
fn theStreamMarshalling() void {
    const handles = probePipe();
    const s = try_(stream.makeStream(handles[0], @intCast(constants.JANET_STREAM_READABLE), null));
    const streamv = wrap.fromAbstract(s);
    gc_alloc.gcroot(streamv);
    defer _ = gc_alloc.gcunroot(streamv);

    const buffer = buffers.new(32);
    {
        const r = harness.abiRaised(subsystems.marsh.marshalAbi, .{ buffer, streamv, null, 0 }).?;
        expect(r.says("can only marshal stream with unsafe flag"));
    }

    // With the flag, it marshals -- and duplicates the descriptor on the way
    // out, which is what makes an unmarshalled stream independent of this one.
    buffer.count = 0;
    subsystems.marsh.marshalAbi(buffer, streamv, null, constants.JANET_MARSHAL_UNSAFE);
    expect(buffer.count > 0);

    // Marshalling clears NODUPS, because the handle may now have two owners.
    expect(s.flags & @as(u32, @intCast(constants.JANET_STREAM_NODUPS)) == 0);

    // The reader refuses without the flag too.
    {
        const r = harness.abiRaised(
            subsystems.marsh.unmarshalAbi,
            .{ buffer.data, @as(usize, @intCast(buffer.count)), 0, null, null },
        ).?;
        expect(r.says("can only unmarshal stream with unsafe flag"));
    }

    const backv = subsystems.marsh.unmarshalAbi(
        buffer.data,
        @intCast(buffer.count),
        constants.JANET_MARSHAL_UNSAFE,
        null,
        null,
    );
    gc_alloc.gcroot(backv);
    defer _ = gc_alloc.gcunroot(backv);
    const back: *stream.Stream = @ptrCast(@alignCast(wrap.toAbstract(backv)));
    expect(back != s);
    // A different descriptor for the same pipe: `dup` was called.
    expect(back.handle != s.handle);
    expect(back.flags == s.flags);
    expect(back.read_fiber == null and back.write_fiber == null);

    if (!windows) {
        // Both ends really do read the same pipe.
        var byte: u8 = 'z';
        var got: u8 = 0;
        expect(c.write(handles[1], @ptrCast(&byte), 1) == 1);
        expect(c.read(back.handle, @ptrCast(&got), 1) == 1);
        expect(got == 'z');
    }
    // `back.handle` is the `dup`, and nothing ever registered *it* -- the
    // marshal duplicated the descriptor and cleared NODUPS, so the close takes
    // the deregistering path with a handle the backend has never seen. On
    // epoll that is an ENOENT this contract has no scope to catch; see the
    // constant above.
    if (unregister_of_an_unregistered_handle_is_quiet) {
        try_(stream.streamClose(back));
    } else {
        // The stream still has to go, and the assertions above are what this
        // section is for. Dropping the reference lets the collector take it by
        // the same path, which is where the ENOENT would arrive too -- so the
        // handle is closed directly and the stream marked, rather than routed
        // through the backend.
        expect(c.close(back.handle) == 0);
        back.handle = invalidHandle();
        back.flags |= @intCast(constants.JANET_STREAM_CLOSED);
    }
    try_(stream.streamClose(s));
    closeFarEnd(handles);
}

// ==========================================================================
// What only the queue holds
// ==========================================================================

/// `janet_ev_mark` walks the spawn queue and marks each task's *value* as well
/// as its fiber. The fiber is redundant -- scheduling also puts it in
/// `vm.ev.active_tasks`, which is a root -- but the resume value is not held
/// anywhere else, so the queue's walk is the only thing keeping it alive.
///
/// Reaching that needs a value with no other reference, which `ev/go` cannot
/// supply: it copies the value into the fiber's stack when it builds it, so the
/// fiber roots it too. Building the fiber in Janet and scheduling it from here
/// leaves the task entry as the only holder.
fn theMarkedTaskValues() void {
    const out = doString(
        \\(def out (ev/chan 8))
        \\(def f (fiber/new (fn [x] (ev/give out x)) :e))
        \\[out f]
    );
    gc_alloc.gcroot(out);
    defer _ = gc_alloc.gcunroot(out);
    const tup = wrap.toTuple(out);
    const chan = try_(channel.getChannel(tup[0..1], 0)).?;
    const f = wrap.toFiber(tup[1]);

    // A string built here and rooted only until it is queued.
    var val = value.fromBytes("only-in-the-queue", .string);
    gc_alloc.gcroot(val);
    ev.schedule(f, val);
    _ = gc_alloc.gcunroot(val);
    val = wrap.fromNil();

    // Nothing but the task entry refers to it now.
    gc_mark.collect();
    raise.reported(ev_mod.loop());

    var got = wrap.fromNil();
    expect(try_(channel.channelTake(chan, &got)));
    expect(payloadIs(got, "only-in-the-queue"));
}

/// `janet_loop` returns when `janet_loop_done` says there is nothing left, and
/// a task suspended on a timer counts as something left -- through
/// `is_suspended`, which raises the listener count on the way out of `loop1`.
/// Every Janet test reaches this from *inside* the loop, where the caller's own
/// fiber keeps it alive; only a caller outside can watch `janet_loop` decide
/// for itself.
fn theLoopWaitsForASleepingTask() void {
    expect(ev_mod.loopDone());
    const out = doString(
        \\(def out (ev/chan 8))
        \\(def f (fiber/new (fn [] (ev/sleep 0.05) (ev/give out :done)) :e))
        \\[out f]
    );
    gc_alloc.gcroot(out);
    defer _ = gc_alloc.gcunroot(out);
    const tup = wrap.toTuple(out);
    const chan = try_(channel.getChannel(tup[0..1], 0)).?;

    ev.schedule(wrap.toFiber(tup[1]), wrap.fromNil());
    expect(!ev_mod.loopDone());
    raise.reported(ev_mod.loop());

    // It ran to completion rather than being abandoned at its first suspend.
    var got = wrap.fromNil();
    expect(try_(channel.channelTake(chan, &got)));
    expect(harness.keywordIs(got, "done"));
    expect(ev_mod.loopDone());
}

// ==========================================================================
// The threaded flag, and optchannel's boundary
// ==========================================================================

/// `janet_channel_make_threaded` differs from `janet_channel_make` in one
/// field, and no binding reads it. What reads it is the packing: a threaded
/// channel marshals anything that is not one of five self-contained types on
/// the way in and unmarshals it on the way out, and an unthreaded one stores
/// the value as it is.
///
/// So the flag is observable as *identity*. A buffer given to an unthreaded
/// channel comes back as the same object; the same buffer given to a threaded
/// one comes back as a copy with the same contents, because it made the round
/// trip through the wire format. Nothing in Janet can ask a channel whether it
/// is threaded, so this is the only way to pin the constructor.
fn theThreadedFlag() void {
    const plain = channel.channelMake(2).?;
    const threaded = channel.channelMakeThreaded(2).?;
    const plainv = wrap.fromAbstract(plain);
    gc_alloc.gcroot(plainv);
    defer _ = gc_alloc.gcunroot(plainv);

    const original = buffers.new(8);
    buffers.pushCstringAbi(original, "payload");
    const originalv = wrap.fromBuffer(original);
    gc_alloc.gcroot(originalv);
    defer _ = gc_alloc.gcunroot(originalv);

    var item = wrap.fromNil();

    expect(!try_(channel.channelGive(plain, originalv)));
    expect(try_(channel.channelTake(plain, &item)));
    expect(harness.isType(item, repr.Tag.buffer));
    expect(wrap.toBuffer(item) == original);

    expect(!try_(channel.channelGive(threaded, originalv)));
    expect(try_(channel.channelTake(threaded, &item)));
    expect(harness.isType(item, repr.Tag.buffer));
    const copy = wrap.toBuffer(item);
    expect(copy != original);
    expect(copy.count == original.count);
    const length: usize = @intCast(original.count);
    expect(std.mem.eql(u8, copy.slice()[0..length], original.slice()[0..length]));
}

/// `janet_optchannel` takes its default when the argument is absent or nil, and
/// the channel otherwise. "Absent" is `argc > n`, and the boundary is the case
/// where the argument *exists* in the array but the count says it does not.
fn theOptChannelBoundary() void {
    const chanv = doString("(ev/chan 1)");
    gc_alloc.gcroot(chanv);
    defer _ = gc_alloc.gcunroot(chanv);

    var argv = [_]repr.Value{ chanv, wrap.fromNil() };
    const chan = try_(channel.getChannel(&argv, 0)).?;

    // A channel is there and the count says so.
    expect(try_(ev_channel.optChannel(argv[0..1], 0, null)) == chan);
    // A channel is there and the count says it is not: the default wins, and
    // the value at that index is never looked at. An empty slice is the count
    // saying zero, which a sentinel table cannot express and a slice can.
    expect(try_(ev_channel.optChannel(argv[0..0], 0, null)) == null);
    expect(try_(ev_channel.optChannel(argv[0..0], 0, chan)) == chan);
    // Present but nil: the default wins.
    expect(try_(ev_channel.optChannel(argv[0..2], 1, null)) == null);
}

/// A value at the index that is not a channel is an argument error.
///
/// Its other half was the `janet_getchannel` shim: the pointer-and-count to
/// slice conversion and the report it left instead of an error. That entry
/// point is not part of the published surface, so both went with it; what a
/// Janet program can still observe is the refusal.
fn theWrongArgumentIsNotAChannel() void {
    const chanv = doString("(ev/chan 1)");
    gc_alloc.gcroot(chanv);
    defer _ = gc_alloc.gcunroot(chanv);

    var argv = [_]repr.Value{ chanv, wrap.fromNil() };
    expect(try_(channel.getChannel(&argv, 0)).? == try_(channel.getChannel(argv[0..1], 0)).?);

    const refusal = harness.raised(channel.getChannel, .{ @as([]const repr.Value, &argv), @as(i32, 1) }).?;
    expect(refusal.signal == boundary.Signal.@"error");
}

pub fn run() void {
    harness.init();
    defer vm_lifecycle.deinit();

    theProtectedScope();

    theEmbedderChannelApi();
    theThreadedChannel();
    theClosedChannel();
    theChannelGetters();

    theStreamExtension();
    theDefaultMethods();
    theStreamRendering();
    theStreamFlagMessages();
    theNotCloseableStream();
    theStreamMarshalling();

    if (!windows) {
        thePipeModes();
        theLastError();
    }

    theLoopExitCondition();
    thePostedEventRoundTrip();
    theNullCallback();
    theThreadedReplyTags();

    theOrderedTimeouts();
    theTwoTimeoutConstructors();
    theCancelOfANonTask();
    theScheduleSoonOrder();
    theScheduleSignalOrder();
    theScheduleSignalIsFifo();
    theMarkedTaskValues();
    theLoopWaitsForASleepingTask();
    theCancelAppends();
    theThreadedFlag();
    theOptChannelBoundary();
    theWrongArgumentIsNotAChannel();

    std.debug.print("ev_loop contract ok\n", .{});
}
