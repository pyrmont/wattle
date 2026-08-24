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
//!    caller-supplied method table -- is what `net_sockets.zig` does and what
//!    no Janet program can ask for.
//!  - **`makePipe`'s four modes.** Janet reaches mode 1 through `os/spawn` and
//!    nothing else; the descriptor flags each mode sets are invisible from
//!    Janet even then.
//!  - **`janet_ev_default_threaded_callback`'s nine tags.** `ev/thread` uses
//!    two of them.
//!  - **The faces.** `janet_channel_give`, `janet_marshal` and their kin are
//!    `janet.h`'s, and what an embedder sees when one refuses is a report
//!    rather than an error. `harness.faceRaised` is the instrument for that
//!    half and `harness.raised` for the other -- rule 15.
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
//! ## What the migration changed
//!
//! **This is the last `test/*.c`, and four of the five things it needed from
//! `test/support.zig` were the reason that file existed.**
//!
//!  - `janet_contract_protect` opened a protected scope so that a C body could
//!    raise into it. `harness.raised` is that, and the section that used to
//!    test the shim now tests `harness.raised` itself -- see below.
//!  - `janet_contract_at_get`, `janet_contract_at_next` and
//!    `janet_contract_at_tostring` called an abstract type's raising callbacks
//!    on C's behalf. `janet_stream_type` is an `abstract_type.AbstractType`
//!    here, so the callbacks are called and the error is handled.
//!  - `janet_contract_cfunction` adapted a C cfunction into one the runtime
//!    could call. A cfunction written in Zig needs no adapter; `raise.stored`
//!    is the cast that puts one in a `JanetMethod` row or a `janet_def`.
//!
//! **The section that tested the shim now tests the harness.** `test_protect_
//! scope` in the C original had `janet_contract_protect` as its subject, which
//! was test-only code. Deleting it outright would drop the only direct check
//! of the mechanism sixty-three contracts rest on, so what is kept is the
//! same three claims pointed at `harness.raised`: a returning call answers
//! null, a raising call answers the signal and the payload, and the scopes
//! nest.
//!
//! **The Windows arm compiles now, and did not before.** `zig build
//! -Dtarget=x86_64-windows-gnu -Dinstall-tests=true` failed on three
//! `INVALID_HANDLE_VALUE`s in `test/ev_loop.c`, and nothing standing caught it
//! because `build.zig` installs the C driver only under `-Dinstall-tests` and
//! the matrix's four cross-compile entries do not pass it. The Zig driver is
//! installed unconditionally, so those four entries compile this file --
//! `phase_11.md` said this was a gap that closes itself, and this is it
//! closing.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi");
const c = abi.c;
const raise = @import("raise");
const harness = @import("harness.zig");

const subsystems = @import("subsystems");
const ev = subsystems.ev_loop;
const channel = subsystems.ev_channel;
const stream = subsystems.ev_stream;
const abstract_type = subsystems.abstract_type;

const assert = std.debug.assert;
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
/// the divergence is inherited from upstream's `ev.c` and a gate is not where a
/// behavioural change to the event loop belongs -- rule 11's instruction to
/// assert the part that is common and quarantine the rest.
const unregister_of_an_unregistered_handle_is_quiet = builtin.os.tag != .linux;

/// `INVALID_HANDLE_VALUE`, written out rather than imported.
///
/// `ev_stream.zig` has the same two lines privately. This is the value half of
/// rule 46: the constant is the *host's*, so a contract that imported the
/// subject's copy could not notice the subject having the wrong one. It is
/// also what `test/ev_loop.c` could not spell portably -- the C original
/// reached for `INVALID_HANDLE_VALUE`, which is why that file never
/// cross-compiled to Windows.
fn invalidHandle() c.JanetHandle {
    return if (windows) @ptrFromInt(std.math.maxInt(usize)) else -1;
}

fn payloadIs(payload: c.Janet, text: []const u8) bool {
    if (!harness.isType(payload, c.JANET_STRING)) return false;
    const s = c.janet_unwrap_string(payload);
    const length: usize = @intCast(c.janet_string_length(s));
    return std.mem.eql(u8, s[0..length], text);
}

/// One Janet source string, evaluated for its value. Every use here builds
/// fibers and channels the C sections then drive by hand, so a failure to
/// compile is a broken contract rather than a tested refusal.
fn doString(source: [*:0]const u8) c.Janet {
    var out = c.janet_wrap_nil();
    if (c.janet_dostring(c.janet_core_env(null), source, "ev_loop", &out) != 0) {
        std.debug.print("ev_loop: {s}\n", .{c.janet_to_string(out)});
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
    assert(harness.raised(returnsQuietly, .{}) == null);

    // The raising arm answers the signal and the payload.
    const r = harness.raised(raisesContractPanic, .{}).?;
    assert(r.signal == c.JANET_SIGNAL_ERROR);
    assert(r.says("contract panic"));

    // Scopes nest, and the inner one does not swallow the outer's state. This
    // is the claim that is about the scope rather than about the call: an
    // inner `janet_try_init` moves `janet_vm.return_reg` and `janet_restore`
    // has to put back what was there, not null.
    const outer = harness.raised(struct {
        fn body() raise.Raising(void) {
            assert(harness.raised(returnsQuietly, .{}) == null);
            const inner = harness.raised(raisesContractPanic, .{}).?;
            assert(inner.says("contract panic"));
            return raise.panic("outer panic");
        }
    }.body, .{}).?;
    assert(outer.says("outer panic"));
}

// ==========================================================================
// Channels
// ==========================================================================

fn theEmbedderChannelApi() void {
    const chan = channel.janet_channel_make(2).?;
    const chanv = c.janet_wrap_abstract(chan);
    c.janet_gcroot(chanv);
    defer _ = c.janet_gcunroot(chanv);

    // Nothing to take from an empty channel, and mode 2 registers no pending
    // read, so a second take behaves the same as the first.
    var out = c.janet_ckeywordv("untouched");
    assert(!try_(channel.channelTake(chan, &out)));
    assert(harness.isType(out, c.JANET_KEYWORD));
    assert(!try_(channel.channelTake(chan, &out)));

    // Two gives fit under the limit and report "do not block".
    assert(!try_(channel.channelGive(chan, harness.wrapInteger(1))));
    assert(!try_(channel.channelGive(chan, harness.wrapInteger(2))));
    // The third exceeds the limit; mode 2 declines to block and says so.
    assert(try_(channel.channelGive(chan, harness.wrapInteger(3))));

    // All three are queued, in order.
    for ([_]i32{ 1, 2, 3 }) |expected| {
        assert(try_(channel.channelTake(chan, &out)));
        assert(c.janet_unwrap_integer(out) == expected);
    }
    assert(!try_(channel.channelTake(chan, &out)));
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
    const chan = channel.janet_channel_make_threaded(1).?;
    var out = c.janet_wrap_nil();
    assert(!try_(channel.channelGive(chan, harness.wrapInteger(7))));
    assert(try_(channel.channelTake(chan, &out)));
    assert(c.janet_unwrap_integer(out) == 7);

    // Packing is what a threaded channel does that an ordinary one does not: a
    // value that is not one of the five self-contained types is marshalled on
    // the way in and unmarshalled on the way out.
    assert(!try_(channel.channelGive(chan, c.janet_cstringv("packed"))));
    assert(try_(channel.channelTake(chan, &out)));
    assert(payloadIs(out, "packed"));
}

/// Giving to a closed channel raises, and this asserts the *face* -- what an
/// embedder calling `janet.h`'s `janet_channel_give` sees, which is a report.
/// The import beside it is the same refusal arriving as an error.
fn theClosedChannel() void {
    const chanv = doString("(def c (ev/chan 4)) (ev/chan-close c) c");
    c.janet_gcroot(chanv);
    defer _ = c.janet_gcunroot(chanv);
    var argv = [_]c.Janet{chanv};
    const chan = try_(channel.getChannel(&argv, 0)).?;

    // Taking from a closed channel succeeds and yields nil.
    var out = harness.wrapInteger(99);
    assert(try_(channel.channelTake(chan, &out)));
    assert(harness.isType(out, c.JANET_NIL));

    const face = harness.faceRaised(c.janet_channel_give, .{ chan, harness.wrapInteger(1) }).?;
    assert(face.signal == c.JANET_SIGNAL_ERROR);
    assert(face.says("cannot write to closed channel"));

    const imported = harness.raised(channel.channelGive, .{ chan, harness.wrapInteger(1) }).?;
    assert(imported.says("cannot write to closed channel"));
}

fn theChannelGetters() void {
    const chanv = doString("(ev/chan 3)");
    c.janet_gcroot(chanv);
    defer _ = c.janet_gcunroot(chanv);

    var argv = [_]c.Janet{ chanv, c.janet_wrap_nil() };
    const chan = try_(channel.getChannel(&argv, 0)).?;
    assert(try_(channel.getChannel(&argv, 0)) == chan);

    // `optchannel` takes the default for a missing argument and for nil, and
    // the channel for anything else. It is a face and has no raising twin:
    // `janet.h` declares it and the runtime never calls it.
    assert(c.janet_optchannel(&argv, 1, 1, null) == null);
    assert(c.janet_optchannel(&argv, 2, 1, null) == null);
    assert(c.janet_optchannel(&argv, 2, 0, null) == chan);
}

// ==========================================================================
// Streams
// ==========================================================================

fn probeMethod(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    _ = argc;
    _ = argv;
    return c.janet_ckeywordv("probe");
}

const probe_methods = [_]c.JanetMethod{
    .{ .name = "probe", .cfun = raise.stored(&probeMethod) },
    .{ .name = null, .cfun = null },
};

/// A stream with room for a payload after the header, which is what
/// `makeStreamExt` exists for.
const ProbeStream = extern struct {
    stream: c.JanetStream,
    marker: u64,
};

/// A pipe, and the pair of handles it answers with. Every stream section needs
/// one and every one of them closes the far end by hand.
fn probePipe() [2]c.JanetHandle {
    var handles: [2]c.JanetHandle = undefined;
    assert(stream.makePipe(&handles, 0) == 0);
    return handles;
}

fn closeFarEnd(handles: [2]c.JanetHandle) void {
    if (!windows) _ = ev.close(handles[1]);
}

fn theStreamExtension() void {
    const handles = probePipe();
    const ps: *ProbeStream = @ptrCast(@alignCast(try_(stream.makeStreamExt(
        handles[0],
        @intCast(c.JANET_STREAM_READABLE),
        &probe_methods,
        @sizeOf(ProbeStream),
    ))));
    ps.marker = 0x0123456789ABCDEF;

    const s = &ps.stream;
    assert(s.handle == handles[0]);
    assert(s.flags == @as(u32, @intCast(c.JANET_STREAM_READABLE)));
    assert(s.read_fiber == null and s.write_fiber == null);
    assert(@intFromPtr(s.methods) == @intFromPtr(&probe_methods));

    // The abstract's size is the caller's, not the header's.
    assert(c.janet_abstract_size(ps) == @sizeOf(ProbeStream));

    // The abstract carries the type this file imports rather than some other
    // registration of the same name. Asserted through `janet_abstract_type`,
    // whose answer is a run-time value: two declarations compared at comptime
    // are never equal whatever the linker did -- rule 38.
    assert(c.janet_abstract_type(ps) == abstract_type.stored(&stream.janet_stream_type));

    // The getter reaches the caller's table rather than the default one.
    const at = &stream.janet_stream_type;
    var found = c.janet_wrap_nil();
    var out = c.janet_wrap_nil();
    assert(try_(at.get.?(ps, c.janet_ckeywordv("probe"), &found)) == 1);
    assert(harness.isType(found, c.JANET_CFUNCTION));
    assert(try_(at.get.?(ps, c.janet_ckeywordv("close"), &out)) == 0);

    // `next` walks the same table.
    assert(harness.keywordIs(try_(at.next.?(ps, c.janet_wrap_nil())), "probe"));
    assert(harness.isType(try_(at.next.?(ps, c.janet_ckeywordv("probe"))), c.JANET_NIL));

    assert(ps.marker == 0x0123456789ABCDEF);
    try_(stream.streamClose(s));
    assert(s.flags & @as(u32, @intCast(c.JANET_STREAM_CLOSED)) != 0);
    assert(s.handle == invalidHandle());
    // Closing twice is a no-op rather than a double close.
    try_(stream.streamClose(s));
    assert(s.handle == invalidHandle());
    closeFarEnd(handles);
}

fn theDefaultMethods() void {
    const handles = probePipe();
    const s = try_(stream.makeStream(handles[0], @intCast(c.JANET_STREAM_READABLE), null));
    const at = &stream.janet_stream_type;

    // A null method table means the four default stream methods.
    //
    // Named through the core bindings rather than as symbols. Phase 10 Part
    // 17g removed `janet_cfun_stream_close` and its three neighbours from
    // `janet.h`, and a cfunction is no longer a C function -- so what is
    // asserted is that the method table and the `ev/` binding are the same
    // function, which is slightly stronger than comparing addresses would be.
    var out = c.janet_wrap_nil();
    inline for (.{ "close", "read", "chunk", "write" }) |name| {
        assert(try_(at.get.?(s, c.janet_ckeywordv(name), &out)) == 1);
        assert(harness.isType(out, c.JANET_CFUNCTION));
        assert(c.janet_unwrap_cfunction(out) ==
            c.janet_unwrap_cfunction(c.janet_resolve_core("ev/" ++ name)));
    }

    // A non-keyword key is not a method lookup.
    assert(try_(at.get.?(s, harness.wrapInteger(0), &out)) == 0);
    try_(stream.streamClose(s));
    closeFarEnd(handles);
}

fn theStreamRendering() void {
    const handles = probePipe();
    const s = try_(stream.makeStream(handles[0], @intCast(c.JANET_STREAM_READABLE), null));
    const buffer = c.janet_buffer(16);
    try_(stream.janet_stream_type.tostring.?(s, buffer));

    var expected: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&expected, "[fd={d}]", .{
        if (windows) @as(i32, @intCast(@intFromPtr(handles[0]))) else handles[0],
    }) catch unreachable;
    assert(buffer.*.count == @as(i32, @intCast(text.len)));
    assert(std.mem.eql(u8, buffer.*.data[0..text.len], text));

    try_(stream.streamClose(s));
    closeFarEnd(handles);
}

fn theStreamFlagMessages() void {
    const handles = probePipe();
    const readable: u32 = @intCast(c.JANET_STREAM_READABLE);
    const writable: u32 = @intCast(c.JANET_STREAM_WRITABLE);
    const socket: u32 = @intCast(c.JANET_STREAM_SOCKET);
    const acceptable: u32 = @intCast(c.JANET_STREAM_ACCEPTABLE);
    const udpserver: u32 = @intCast(c.JANET_STREAM_UDPSERVER);

    const s = try_(stream.makeStream(handles[0], readable | socket, null));

    // Every flag the caller asks for is present, so nothing is raised.
    assert(harness.raised(stream.streamFlags, .{ s, readable }) == null);
    assert(harness.raised(stream.streamFlags, .{ s, readable | socket }) == null);

    // The message names every flag that was *asked for*, in a fixed order, and
    // the last word is "socket" only when a socket was asked for.
    {
        const r = harness.raised(stream.streamFlags, .{ s, writable }).?;
        assert(r.says("bad stream, expected writable stream"));
    }
    {
        const all = readable | writable | acceptable | udpserver | socket;
        const r = harness.raised(stream.streamFlags, .{ s, all }).?;
        assert(r.says("bad stream, expected readable writable server datagram socket"));
    }

    // A closed stream is refused before its flags are looked at.
    try_(stream.streamClose(s));
    {
        const r = harness.raised(stream.streamFlags, .{ s, readable }).?;
        assert(r.says("stream is closed"));
    }
    closeFarEnd(handles);
}

fn theNotCloseableStream() void {
    const handles = probePipe();
    const flags: u32 = @intCast(c.JANET_STREAM_READABLE | c.JANET_STREAM_NOT_CLOSEABLE);
    const s = try_(stream.makeStream(handles[0], flags, null));
    try_(stream.streamClose(s));

    // The handle is forgotten either way; what NOT_CLOSEABLE changes is that
    // the descriptor itself survives, which is why it is still usable here.
    assert(s.flags & @as(u32, @intCast(c.JANET_STREAM_CLOSED)) != 0);
    assert(s.handle == invalidHandle());

    if (!windows) {
        var byte: u8 = 'x';
        assert(ev.write(handles[1], @ptrCast(&byte), 1) == 1);
        assert(ev.read(handles[0], @ptrCast(&byte), 1) == 1);
        _ = ev.close(handles[0]);
        _ = ev.close(handles[1]);
    }
}

// ==========================================================================
// Pipes
// ==========================================================================

/// The flag values are `std`'s rather than the subject's, which has its own
/// four constants ten lines from `makePipe`. Rule 46 again: importing them
/// would make this compare the subject with itself, and the question here is
/// whether the descriptor the *host* handed back carries the flag.
const fd_cloexec: c_int = std.c.FD_CLOEXEC;
const o_nonblock: c_int = @bitCast(@as(u32, @bitCast(std.c.O{ .NONBLOCK = true })));

fn isCloexec(fd: c_int) bool {
    const flags = ev.fcntl(fd, std.c.F.GETFD);
    assert(flags != -1);
    return flags & fd_cloexec != 0;
}

fn isNonblock(fd: c_int) bool {
    const flags = ev.fcntl(fd, std.c.F.GETFL);
    assert(flags != -1);
    return flags & o_nonblock != 0;
}

/// The four modes and exactly which descriptor gets which flag. The mode
/// numbers are what `os/spawn` and the self pipe pass, and nothing in Janet
/// can observe the result.
fn thePipeModes() void {
    // mode: cloexec0 cloexec1 nonblock0 nonblock1
    const expect = [4][4]bool{
        .{ true, true, true, true },
        .{ true, false, true, false },
        .{ false, true, false, true },
        .{ true, true, false, false },
    };
    for (expect, 0..) |row, mode| {
        var h: [2]c.JanetHandle = undefined;
        assert(stream.makePipe(&h, @intCast(mode)) == 0);
        assert(isCloexec(h[0]) == row[0]);
        assert(isCloexec(h[1]) == row[1]);
        assert(isNonblock(h[0]) == row[2]);
        assert(isNonblock(h[1]) == row[3]);

        // The two ends are a pipe rather than two unrelated descriptors.
        var byte: u8 = @intCast('a' + mode);
        var got: u8 = 0;
        assert(ev.write(h[1], @ptrCast(&byte), 1) == 1);
        assert(ev.read(h[0], @ptrCast(&got), 1) == 1);
        assert(got == byte);
        _ = ev.close(h[0]);
        _ = ev.close(h[1]);
    }
}

fn theLastError() void {
    // `janet_ev_lasterr` reads errno and renders it, with no side effect of
    // its own -- the same errno gives the same string twice.
    std.c._errno().* = @intFromEnum(std.posix.E.BADF);
    const first = stream.janet_ev_lasterr();
    const second = stream.janet_ev_lasterr();
    assert(harness.isType(first, c.JANET_STRING));
    assert(c.janet_equals(first, second) != 0);
    std.c._errno().* = @intFromEnum(std.posix.E.INVAL);
    assert(c.janet_equals(first, stream.janet_ev_lasterr()) == 0);
}

// ==========================================================================
// The loop's own state
// ==========================================================================

fn theLoopExitCondition() void {
    // Nothing scheduled, no timers, no listeners.
    assert(c.janet_loop_done() != 0);

    // A listener is enough to keep the loop alive, and the count is a count
    // rather than a flag.
    ev.janet_ev_inc_refcount();
    assert(c.janet_loop_done() == 0);
    ev.janet_ev_inc_refcount();
    assert(c.janet_loop_done() == 0);
    ev.janet_ev_dec_refcount();
    assert(c.janet_loop_done() == 0);
    ev.janet_ev_dec_refcount();
    assert(c.janet_loop_done() != 0);
}

const PostRecord = struct {
    calls: u32 = 0,
    tag: i32 = 0,
    value: c.Janet = undefined,
};

var post_record: PostRecord = .{};

fn postCallback(msg: c.JanetEVGenericMessage) callconv(.c) void {
    post_record.calls += 1;
    post_record.tag = msg.tag;
    post_record.value = msg.argj;
}

/// The self pipe, end to end: posting an event raises the listener count, and
/// one turn of the loop delivers the callback and lowers it again. On Windows
/// the same round trip goes through the completion port instead.
fn thePostedEventRoundTrip() void {
    post_record = .{};
    var msg = std.mem.zeroes(c.JanetEVGenericMessage);
    msg.tag = 41;
    msg.argj = harness.wrapInteger(42);

    assert(c.janet_loop_done() != 0);
    ev.janet_ev_post_event(null, &postCallback, msg);
    assert(c.janet_loop_done() == 0);

    c.janet_loop();
    assert(post_record.calls == 1);
    assert(post_record.tag == 41);
    assert(c.janet_unwrap_integer(post_record.value) == 42);
    assert(c.janet_loop_done() != 0);
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
    assert(c.janet_loop_done() != 0);
    const msg = std.mem.zeroes(c.JanetEVGenericMessage);
    ev.janet_ev_post_event(null, null, msg);
    assert(c.janet_loop_done() == 0);
    _ = c.janet_loop1();
    if (windows) {
        assert(c.janet_loop_done() != 0);
    } else {
        assert(c.janet_loop_done() == 0);
        ev.janet_ev_dec_refcount();
        assert(c.janet_loop_done() != 0);
    }
}

/// `janet_ev_default_threaded_callback` with a null fiber is the cleanup-only
/// path: nothing is scheduled and the payload is released. Every tag frees,
/// because both of the original's switches send everything but the two
/// `*_STRINGF` cases to a `default` that also frees.
fn theThreadedReplyTags() void {
    const tags = [_]c_int{
        c.JANET_EV_TCTAG_NIL,        c.JANET_EV_TCTAG_INTEGER,
        c.JANET_EV_TCTAG_STRING,     c.JANET_EV_TCTAG_STRINGF,
        c.JANET_EV_TCTAG_KEYWORD,    c.JANET_EV_TCTAG_ERR_STRING,
        c.JANET_EV_TCTAG_ERR_STRINGF, c.JANET_EV_TCTAG_ERR_KEYWORD,
        c.JANET_EV_TCTAG_BOOLEAN,
    };
    var freed: u32 = 0;
    for (tags) |tag| {
        var msg = std.mem.zeroes(c.JanetEVGenericMessage);
        msg.tag = @intCast(tag);
        msg.fiber = null;
        // A heap payload, so that a missing free is a leak a sanitizer sees
        // and a double free is a crash.
        const payload = c.janet_malloc(8).?;
        const bytes: [*]u8 = @ptrCast(payload);
        @memcpy(bytes[0..8], "abcdefg\x00");
        msg.argp = payload;
        c.janet_ev_default_threaded_callback(msg);
        freed += 1;
    }
    assert(freed == 9);
    // The loop is untouched: a null fiber schedules nothing.
    assert(c.janet_loop_done() != 0);
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
    assert(harness.isType(out, c.JANET_ARRAY));
    const log = c.janet_unwrap_array(out);
    assert(log.*.count == 3);
    assert(harness.keywordIs(log.*.data[0], "a"));
    assert(harness.keywordIs(log.*.data[1], "b"));
    assert(harness.keywordIs(log.*.data[2], "c"));
}

/// `janet_addtimeout` and `janet_addtimeout_nil` differ in one field of the
/// `JanetTimeout` they build: `is_error`. An expired error timeout cancels the
/// fiber and an expired nil timeout resumes it with nil.
///
/// Neither can be called from here directly -- both read
/// `janet_vm.root_fiber`, which is only set while the loop is running a task
/// -- and `janet_addtimeout_nil` has **no Janet caller at all**: `ev/read`'s
/// optional timeout uses the error one, and only the socket layer uses the
/// other. So the contract lends the core environment a cfunction of its own
/// and drives it from a task, which is the only way to reach the pair.
fn cfunAddTimeout(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try subsystems.args_core.fixarity(argc, 2);
    const sec = try subsystems.args_core.getNumber(argv, 0);
    if (try subsystems.args_core.getBoolean(argv, 1) != 0) {
        ev.janet_addtimeout(sec);
    } else {
        ev.janet_addtimeout_nil(sec);
    }
    return c.janet_wrap_nil();
}

fn theTwoTimeoutConstructors() void {
    const env = c.janet_core_env(null);
    c.janet_def(
        env,
        "test/add-timeout",
        c.janet_wrap_cfunction(raise.stored(&cfunAddTimeout)),
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
    const results = c.janet_unwrap_array(out);
    assert(results.*.count == 2);
    for (0..@intCast(results.*.count)) |i| {
        const row = c.janet_unwrap_tuple(results.*.data[i]);
        if (harness.keywordIs(row[0], "nil")) {
            // `addtimeout_nil` resumes with nil rather than raising.
            assert(harness.isType(row[1], c.JANET_NIL));
        } else {
            // `addtimeout` cancels the fiber, so `protect` reports a failure
            // carrying the message the loop supplies.
            const pair = c.janet_unwrap_tuple(row[1]);
            assert(harness.isType(pair[0], c.JANET_BOOLEAN));
            assert(c.janet_unwrap_boolean(pair[0]) == 0);
            assert(payloadIs(pair[1], "timeout"));
        }
    }
    assert(c.janet_loop_done() != 0);
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
    c.janet_gcroot(fiberv);
    defer _ = c.janet_gcunroot(fiberv);
    const fiber = c.janet_unwrap_fiber(fiberv);

    {
        const r = harness.raised(ev.cancel, .{ fiber, c.janet_cstringv("nope") }).?;
        assert(r.says("cannot cancel non-task fiber"));
    }

    // Scheduling it makes it a task, and cancelling then succeeds.
    const sup = channel.janet_channel_make(4).?;
    const supv = c.janet_wrap_abstract(sup);
    c.janet_gcroot(supv);
    defer _ = c.janet_gcunroot(supv);
    fiber.*.supervisor_channel = @ptrCast(sup);

    ev.janet_schedule(fiber, c.janet_wrap_nil());
    assert(harness.raised(ev.cancel, .{ fiber, c.janet_cstringv("nope") }) == null);
    c.janet_loop();
    assert(c.janet_loop_done() != 0);

    // The supervisor got `[:error fiber nil]` rather than a stack trace on
    // stderr, and the fiber's last value is what the cancel carried.
    var event = c.janet_wrap_nil();
    assert(try_(channel.channelTake(sup, &event)));
    assert(harness.isType(event, c.JANET_TUPLE));
    const tup = c.janet_unwrap_tuple(event);
    assert(c.janet_tuple_length(tup) == 3);
    assert(harness.keywordIs(tup[0], "error"));
    assert(c.janet_unwrap_fiber(tup[1]) == fiber);
    assert(harness.isType(tup[2], c.JANET_NIL));
    assert(payloadIs(fiber.*.last_value, "nope"));
    // One event, not two: the first schedule was superseded by the cancel.
    assert(!try_(channel.channelTake(sup, &event)));
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
    c.janet_gcroot(out);
    defer _ = c.janet_gcunroot(out);
    const tup = c.janet_unwrap_tuple(out);
    const log = c.janet_unwrap_array(tup[0]);

    ev.janet_schedule(c.janet_unwrap_fiber(tup[1]), c.janet_wrap_nil());
    ev.janet_schedule_soon(c.janet_unwrap_fiber(tup[2]), c.janet_wrap_nil(), ev.sig_ok);
    c.janet_loop();

    assert(log.*.count == 2);
    assert(harness.keywordIs(log.*.data[0], "b"));
    assert(harness.keywordIs(log.*.data[1], "a"));
}

fn theScheduleSignalOrder() void {
    const out = doString(
        \\(def log @[])
        \\(def a (fiber/new (fn [] (array/push log :a)) :e))
        \\(def b (fiber/new (fn [] (array/push log :b)) :e))
        \\[log a b]
    );
    c.janet_gcroot(out);
    defer _ = c.janet_gcunroot(out);
    const tup = c.janet_unwrap_tuple(out);
    const log = c.janet_unwrap_array(tup[0]);

    // `janet_schedule_signal` appends where `janet_schedule_soon` prepends,
    // and nothing in Janet chooses between the two.
    ev.janet_schedule_signal(c.janet_unwrap_fiber(tup[1]), c.janet_wrap_nil(), ev.sig_ok);
    ev.janet_schedule_soon(c.janet_unwrap_fiber(tup[2]), c.janet_wrap_nil(), ev.sig_ok);
    c.janet_loop();

    assert(log.*.count == 2);
    assert(harness.keywordIs(log.*.data[0], "b"));
    assert(harness.keywordIs(log.*.data[1], "a"));
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
    c.janet_gcroot(out);
    defer _ = c.janet_gcunroot(out);
    const tup = c.janet_unwrap_tuple(out);
    const log = c.janet_unwrap_array(tup[0]);

    for (1..4) |i| {
        ev.janet_schedule_signal(c.janet_unwrap_fiber(tup[@intCast(i)]), c.janet_wrap_nil(), ev.sig_ok);
    }
    c.janet_loop();

    assert(log.*.count == 3);
    assert(harness.keywordIs(log.*.data[0], "a"));
    assert(harness.keywordIs(log.*.data[1], "b"));
    assert(harness.keywordIs(log.*.data[2], "c"));
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
    c.janet_gcroot(out);
    defer _ = c.janet_gcunroot(out);
    const tup = c.janet_unwrap_tuple(out);
    const chan = try_(channel.getChannel(tup, 0)).?;
    const a = c.janet_unwrap_fiber(tup[1]);
    const b = c.janet_unwrap_fiber(tup[2]);
    b.*.supervisor_channel = @ptrCast(chan);

    // b is scheduled first, so it is a task and `cancel` will accept it; the
    // cancel then supersedes that schedule.
    ev.janet_schedule(b, c.janet_wrap_nil());
    ev.janet_schedule(a, c.janet_wrap_nil());
    assert(harness.raised(ev.cancel, .{ b, c.janet_cstringv("late") }) == null);
    c.janet_loop();

    var first = c.janet_wrap_nil();
    var second = c.janet_wrap_nil();
    assert(try_(channel.channelTake(chan, &first)));
    assert(try_(channel.channelTake(chan, &second)));
    // The task queued before the cancel runs first: the cancel appended.
    assert(harness.keywordIs(first, "a"));
    // And b ran once, as an error, rather than twice or as a sleep.
    assert(harness.isType(second, c.JANET_TUPLE));
    assert(harness.keywordIs(c.janet_unwrap_tuple(second)[0], "error"));
    assert(!try_(channel.channelTake(chan, &first)));
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
    const s = try_(stream.makeStream(handles[0], @intCast(c.JANET_STREAM_READABLE), null));
    const streamv = c.janet_wrap_abstract(s);
    c.janet_gcroot(streamv);
    defer _ = c.janet_gcunroot(streamv);

    const buffer = c.janet_buffer(32);
    {
        const r = harness.faceRaised(c.janet_marshal, .{ buffer, streamv, null, 0 }).?;
        assert(r.says("can only marshal stream with unsafe flag"));
    }

    // With the flag, it marshals -- and duplicates the descriptor on the way
    // out, which is what makes an unmarshalled stream independent of this one.
    buffer.*.count = 0;
    c.janet_marshal(buffer, streamv, null, c.JANET_MARSHAL_UNSAFE);
    assert(buffer.*.count > 0);

    // Marshalling clears NODUPS, because the handle may now have two owners.
    assert(s.flags & @as(u32, @intCast(c.JANET_STREAM_NODUPS)) == 0);

    // The reader refuses without the flag too.
    {
        const r = harness.faceRaised(
            c.janet_unmarshal,
            .{ buffer.*.data, @as(usize, @intCast(buffer.*.count)), 0, null, null },
        ).?;
        assert(r.says("can only unmarshal stream with unsafe flag"));
    }

    const backv = c.janet_unmarshal(
        buffer.*.data,
        @intCast(buffer.*.count),
        c.JANET_MARSHAL_UNSAFE,
        null,
        null,
    );
    c.janet_gcroot(backv);
    defer _ = c.janet_gcunroot(backv);
    const back: *c.JanetStream = @ptrCast(@alignCast(c.janet_unwrap_abstract(backv)));
    assert(back != s);
    // A different descriptor for the same pipe: `dup` was called.
    assert(back.handle != s.handle);
    assert(back.flags == s.flags);
    assert(back.read_fiber == null and back.write_fiber == null);

    if (!windows) {
        // Both ends really do read the same pipe.
        var byte: u8 = 'z';
        var got: u8 = 0;
        assert(ev.write(handles[1], @ptrCast(&byte), 1) == 1);
        assert(ev.read(back.handle, @ptrCast(&got), 1) == 1);
        assert(got == 'z');
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
        assert(ev.close(back.handle) == 0);
        back.handle = invalidHandle();
        back.flags |= @intCast(c.JANET_STREAM_CLOSED);
    }
    try_(stream.streamClose(s));
    closeFarEnd(handles);
}

// ==========================================================================
// What only the queue holds
// ==========================================================================

/// `janet_ev_mark` walks the spawn queue and marks each task's *value* as well
/// as its fiber. The fiber is redundant -- scheduling also puts it in
/// `janet_vm.active_tasks`, which is a root -- but the resume value is not held
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
    c.janet_gcroot(out);
    defer _ = c.janet_gcunroot(out);
    const tup = c.janet_unwrap_tuple(out);
    const chan = try_(channel.getChannel(tup, 0)).?;
    const f = c.janet_unwrap_fiber(tup[1]);

    // A string built here and rooted only until it is queued.
    var value = c.janet_cstringv("only-in-the-queue");
    c.janet_gcroot(value);
    ev.janet_schedule(f, value);
    _ = c.janet_gcunroot(value);
    value = c.janet_wrap_nil();

    // Nothing but the task entry refers to it now.
    c.janet_collect();
    c.janet_loop();

    var got = c.janet_wrap_nil();
    assert(try_(channel.channelTake(chan, &got)));
    assert(payloadIs(got, "only-in-the-queue"));
}

/// `janet_loop` returns when `janet_loop_done` says there is nothing left, and
/// a task suspended on a timer counts as something left -- through
/// `is_suspended`, which raises the listener count on the way out of `loop1`.
/// Every Janet test reaches this from *inside* the loop, where the caller's own
/// fiber keeps it alive; only a caller outside can watch `janet_loop` decide
/// for itself.
fn theLoopWaitsForASleepingTask() void {
    assert(c.janet_loop_done() != 0);
    const out = doString(
        \\(def out (ev/chan 8))
        \\(def f (fiber/new (fn [] (ev/sleep 0.05) (ev/give out :done)) :e))
        \\[out f]
    );
    c.janet_gcroot(out);
    defer _ = c.janet_gcunroot(out);
    const tup = c.janet_unwrap_tuple(out);
    const chan = try_(channel.getChannel(tup, 0)).?;

    ev.janet_schedule(c.janet_unwrap_fiber(tup[1]), c.janet_wrap_nil());
    assert(c.janet_loop_done() == 0);
    c.janet_loop();

    // It ran to completion rather than being abandoned at its first suspend.
    var got = c.janet_wrap_nil();
    assert(try_(channel.channelTake(chan, &got)));
    assert(harness.keywordIs(got, "done"));
    assert(c.janet_loop_done() != 0);
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
    const plain = channel.janet_channel_make(2).?;
    const threaded = channel.janet_channel_make_threaded(2).?;
    const plainv = c.janet_wrap_abstract(plain);
    c.janet_gcroot(plainv);
    defer _ = c.janet_gcunroot(plainv);

    const original = c.janet_buffer(8);
    c.janet_buffer_push_cstring(original, "payload");
    const originalv = c.janet_wrap_buffer(original);
    c.janet_gcroot(originalv);
    defer _ = c.janet_gcunroot(originalv);

    var item = c.janet_wrap_nil();

    assert(!try_(channel.channelGive(plain, originalv)));
    assert(try_(channel.channelTake(plain, &item)));
    assert(harness.isType(item, c.JANET_BUFFER));
    assert(c.janet_unwrap_buffer(item) == original);

    assert(!try_(channel.channelGive(threaded, originalv)));
    assert(try_(channel.channelTake(threaded, &item)));
    assert(harness.isType(item, c.JANET_BUFFER));
    const copy = c.janet_unwrap_buffer(item);
    assert(copy != original);
    assert(copy.*.count == original.*.count);
    const length: usize = @intCast(original.*.count);
    assert(std.mem.eql(u8, copy.*.data[0..length], original.*.data[0..length]));
}

/// `janet_optchannel` takes its default when the argument is absent or nil, and
/// the channel otherwise. "Absent" is `argc > n`, and the boundary is the case
/// where the argument *exists* in the array but the count says it does not.
fn theOptChannelBoundary() void {
    const chanv = doString("(ev/chan 1)");
    c.janet_gcroot(chanv);
    defer _ = c.janet_gcunroot(chanv);

    var argv = [_]c.Janet{ chanv, c.janet_wrap_nil() };
    const chan = try_(channel.getChannel(&argv, 0)).?;

    // A channel is there and the count says so.
    assert(c.janet_optchannel(&argv, 1, 0, null) == chan);
    // A channel is there and the count says it is not: the default wins, and
    // the value at that index is never looked at.
    assert(c.janet_optchannel(&argv, 0, 0, null) == null);
    assert(c.janet_optchannel(&argv, 0, 0, chan) == chan);
    // Present but nil: the default wins.
    assert(c.janet_optchannel(&argv, 2, 1, null) == null);
}

pub fn run() void {
    _ = c.janet_init();
    defer c.janet_deinit();

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

    std.debug.print("ev_loop contract ok\n", .{});
}
