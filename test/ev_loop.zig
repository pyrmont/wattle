//! Behavioral contract for the event loop, the scheduler, streams and
//! channels.
//!
//! ## What the Janet suites cannot reach
//!
//! `test/suite-ev.wattle` has 742 assertions and every one of them goes through
//! the thirty `ev/` bindings. Five areas have no Janet spelling at all:
//!
//!  - The embedder's channel API. `channel.channelMake`,
//!    `channel.channelGive` and `channel.channelTake` are the non-blocking
//!    mode (`Caller.detached`) of the push and pop, which `ev/give` and
//!    `ev/take` never select. Only the supervisor path inside the loop reaches
//!    it otherwise, and then only on a fiber that has already failed.
//!  - `makeStreamExt`. Type-punning a stream, a larger allocation with a
//!    caller-supplied method table, is what `net.zig` does and what no Janet
//!    program can ask for.
//!  - `makePipe`'s four modes. Janet reaches mode 1 through `os/spawn` and
//!    nothing else, and the descriptor flags each mode sets are invisible from
//!    Janet even then.
//!  - `ev.evDefaultThreadedCallback`'s nine tags. `ev/thread` uses two.
//!  - The abis. `channel.channelGiveAbi`, `marsh.marshalAbi` and their kin
//!    report rather than raise, and a report is what an embedder sees when one
//!    refuses. `harness.abiRaised` is the instrument for that half and
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
//! ## Two things about how the subjects are reached
//!
//! `theProtectedScope` tests `harness.raised` directly, which is the mechanism
//! sixty-three contracts rest on and the only place it is checked as a
//! subject: a returning call gives null, a raising call gives the signal and
//! the payload, and the scopes nest. Everything else here calls its subject
//! and reads the refusal as a value, `ev/stream.streamType`'s raising
//! callbacks included.
//!
//! The Windows arm of this file compiles. The contract driver is installed
//! unconditionally, so the matrix's cross-compile entries build it whether or
//! not they pass `-Dinstall-tests`.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");
const builtin = @import("builtin");

// ==========================================================================
// Project imports
// ==========================================================================

/// `boundary` rather than `abi`, which a local below binds to a raise report.
const boundary = @import("abi");
const buffers = @import("subsystems").value.buffers;
const c = @import("cabi");
const capi = @import("subsystems").capi;
const channel = subsystems.ev_channel;
const constants = @import("constants");
const core_env = @import("subsystems").env;
const ev = subsystems.ev;
const expect = @import("expect.zig").expect;
const fibers = @import("subsystems").value.fibers;
const gc_alloc = @import("subsystems").gc_alloc;
const gc_mark = @import("subsystems").gc_mark;
const harness = @import("harness.zig");
const host = @import("host");
const method_type = @import("subsystems").method_type;
const order = @import("subsystems").value.order;
const pp_describe = @import("subsystems").pp_describe;
const raise = @import("subsystems").raise;
const registry = @import("subsystems").registry;
const repr = @import("repr");
const strings = @import("subsystems").value.strings;
const stream = subsystems.ev_stream;
const subsystems = @import("subsystems");
const utils = @import("subsystems").utils;
const value = @import("subsystems").value;
const vm_lifecycle = @import("subsystems").lifecycle;
const wrap = @import("subsystems").value.wrap;

// ==========================================================================
// Constants
// ==========================================================================

/// The flag values are `std`'s rather than the subject's, which has its own
/// four constants ten lines from `makePipe`. Importing them
/// would make this compare the subject with itself, and the question here is
/// whether the descriptor the *host* gave back has the flag set.
const fd_cloexec: c_int = std.c.FD_CLOEXEC;
const o_nonblock: c_int = @bitCast(@as(u32, @bitCast(std.c.O{ .NONBLOCK = true })));
var post_record: PostRecord = .{};

const probe_methods = [_]method_type.CMethod{
    .{ .name = "probe", .cfun = raise.stored(&probeMethod) },
    .{ .name = null, .cfun = null },
};

const windows = builtin.os.tag == .windows;

// ==========================================================================
// Types
// ==========================================================================

const PostRecord = struct {
    calls: u32 = 0,
    tag: i32 = 0,
    value: repr.Value = undefined,
};

/// A stream with room for a payload after the header, which is what
/// `makeStreamExt` exists for.
const ProbeStream = extern struct {
    stream: stream.Stream,
    marker: u64,
};

// ==========================================================================
// Cases
// ==========================================================================

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

fn raisesContractPanic() raise.Error!void {
    return raise.panic("contract panic");
}

fn returnsQuietly() raise.Error!void {
    return;
}

/// `harness.raised` is the mechanism every contract in this driver rests on.
/// Nothing else asserts it directly, so its three claims are made here.
fn theProtectedScope() void {
    // The returning arm gives null.
    expect(harness.raised(returnsQuietly, .{}) == null);

    // The raising arm gives the signal and the payload.
    const r = harness.raised(raisesContractPanic, .{}).?;
    expect(r.signal == boundary.Signal.@"error");
    expect(r.says("contract panic"));

    // Scopes nest, and the inner one does not swallow the outer's state. This
    // is the claim that is about the scope rather than about the call: an
    // inner `signal.tryInit` moves `vm.return_reg` and `signal.restore` has to
    // put back what was there, not null.
    const outer = harness.raised(struct {
        fn body() raise.Error!void {
            expect(harness.raised(returnsQuietly, .{}) == null);
            const inner = harness.raised(raisesContractPanic, .{}).?;
            expect(inner.says("contract panic"));
            return raise.panic("outer panic");
        }
    }.body, .{}).?;
    expect(outer.says("outer panic"));
}

fn theEmbedderChannelApi() void {
    const chan = channel.channelMake(2).?;
    const chanv = wrap.fromAbstract(chan);
    gc_alloc.gcroot(chanv);
    defer _ = gc_alloc.gcunroot(chanv);

    // Nothing to take from an empty channel, and mode 2 registers no pending
    // read, so a second take behaves the same as the first.
    var out = value.fromBytes("untouched", .keyword);
    expect(!try_(channel.channelTake(chan, &out)));
    expect(wrap.isKeyword(out));
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

/// The two embedder constructors take a `u32` and assert that it fits an
/// `i32`, so the largest value that does fit is the one input that separates
/// that bound from the one below it. `(ev/chan n)` reaches neither function:
/// `cfunNew` calls `chanInit` itself, with no bound of its own.
fn theChannelCapacityBound() void {
    const limit: u32 = std.math.maxInt(i32);

    const chan = channel.channelMake(limit).?;
    var out = wrap.fromNil();
    expect(!try_(channel.channelGive(chan, harness.wrapInteger(3))));
    expect(try_(channel.channelTake(chan, &out)));
    expect(wrap.toInteger(out) == 3);

    const threaded = channel.channelMakeThreaded(limit).?;
    expect(!try_(channel.channelGive(threaded, harness.wrapInteger(4))));
    expect(try_(channel.channelTake(threaded, &out)));
    expect(wrap.toInteger(out) == 4);
}

/// Giving to a closed channel raises, and this asserts the *abi*, which is
/// what a caller across a compilation boundary sees: a report. The import
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
    // the channel for anything else. The count travels in the slice rather
    // than as a separate `argc`, so this reads `argv.len`.
    expect(try_(channel.optChannel(argv[0..1], 1, null)) == null);
    expect(try_(channel.optChannel(argv[0..2], 1, null)) == null);
    expect(try_(channel.optChannel(argv[0..2], 0, null)) == chan);
}

fn probeMethod(argv: []repr.Value) raise.Error!repr.Value {
    _ = @as(i32, @intCast(argv.len));

    return value.fromBytes("probe", .keyword);
}

/// A pipe, and the pair of handles it gives back. Every stream section needs
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
        @intCast(constants.stream_readable),
        &probe_methods,
        @sizeOf(ProbeStream),
    ))));
    ps.marker = 0x0123456789ABCDEF;

    const s = &ps.stream;
    expect(s.handle == handles[0]);
    expect(s.flags == @as(u32, @intCast(constants.stream_readable)));
    expect(s.read_ops == null and s.write_ops == null);
    expect(@intFromPtr(s.methods) == @intFromPtr(&probe_methods));
    // A fresh stream starts at the head of the file. `makeStreamExt` casts
    // over memory `newBytes` does not zero, so every field it means to define
    // it must write: a declaration's default serves a struct literal and this
    // is not one. The field exists only on Windows, so only Windows can be
    // asked -- which is the whole reason it is asked here rather than left to
    // a read somewhere returning nil for a reason nobody would guess.
    if (windows) expect(s.position == 0);

    // The abstract's size is the caller's, not the header's.
    expect(boundary.abstractHead(ps).size == @sizeOf(ProbeStream));

    // The abstract has the type this file imports rather than some other
    // registration of the same name. Asserted through the head's own `type`
    // pointer, which is a run-time value: two declarations compared at
    // comptime are never equal whatever the linker did.
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
    expect(s.flags & @as(u32, @intCast(constants.stream_closed)) != 0);
    expect(s.handle == invalidHandle());
    // Closing twice is a no-op rather than a double close.
    try_(stream.streamClose(s));
    expect(s.handle == invalidHandle());
    closeFarEnd(handles);
}

fn theDefaultMethods() void {
    const handles = probePipe();
    const s = try_(stream.makeStream(handles[0], @intCast(constants.stream_readable), null));
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
    const s = try_(stream.makeStream(handles[0], @intCast(constants.stream_readable), null));
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
    const readable: u32 = @intCast(constants.stream_readable);
    const writable: u32 = @intCast(constants.stream_writable);
    const socket: u32 = @intCast(constants.stream_socket);
    const acceptable: u32 = @intCast(constants.stream_acceptable);
    const udpserver: u32 = @intCast(constants.stream_udpserver);

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
    const flags: u32 = @intCast(constants.stream_readable | constants.stream_not_closeable);
    const s = try_(stream.makeStream(handles[0], flags, null));
    try_(stream.streamClose(s));

    // The handle is forgotten either way; what NOT_CLOSEABLE changes is that
    // the descriptor itself survives, so it is still usable here.
    expect(s.flags & @as(u32, @intCast(constants.stream_closed)) != 0);
    expect(s.handle == invalidHandle());

    if (!windows) {
        var byte: u8 = 'x';
        expect(c.write(handles[1], @ptrCast(&byte), 1) == 1);
        expect(c.read(handles[0], @ptrCast(&byte), 1) == 1);
        _ = c.close(handles[0]);
        _ = c.close(handles[1]);
    }
}

/// A stream is a file descriptor, so both directions refuse to work without
/// `marshal_unsafe`, and the refusal reaches an embedder as the report
/// `marsh.marshalAbi` leaves. `ev/thread` and a threaded channel both marshal
/// unsafely, and either of them can be given a stream, so the Windows refusal
/// has a Janet spelling too. `suite-ev2` has it.
fn theStreamMarshalling() void {
    const handles = probePipe();
    const s = try_(stream.makeStream(handles[0], @intCast(constants.stream_readable), null));
    const streamv = wrap.fromAbstract(s);
    gc_alloc.gcroot(streamv);
    defer _ = gc_alloc.gcunroot(streamv);

    const buffer = buffers.new(32);
    {
        const r = harness.abiRaised(subsystems.marsh.marshalAbi, .{ buffer, streamv, null, 0 }).?;
        expect(r.says("can only marshal stream with unsafe flag"));
    }

    // Windows stops here, and the refusal is the claim. A completion port
    // association is a property of the file object, and a duplicate names the
    // same file object, so the receiving VM cannot associate it with its own
    // port. Tolerating that would leave the receiving VM's completions
    // arriving at this VM's loop under this stream's key.
    if (windows) {
        const r = harness.abiRaised(
            subsystems.marsh.marshalAbi,
            .{ buffer, streamv, null, constants.marshal_unsafe },
        ).?;
        expect(r.says("a stream does not marshal on Windows: this runtime does not move a registered handle to another completion port"));
        try_(stream.streamClose(s));
        closeFarEnd(handles);
        return;
    }

    // With the flag, it marshals, and duplicates the descriptor on the way
    // out, which is what makes an unmarshalled stream independent of this one.
    buffer.count = 0;
    subsystems.marsh.marshalAbi(buffer, streamv, null, constants.marshal_unsafe);
    expect(buffer.count > 0);

    // Marshalling clears NODUPS, because the handle may now have two owners.
    expect(s.flags & @as(u32, @intCast(constants.stream_nodups)) == 0);

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
        constants.marshal_unsafe,
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
    expect(back.read_ops == null and back.write_ops == null);

    // Both ends really do read the same pipe. No guard: Windows returned
    // above, so everything from here is POSIX.
    {
        var byte: u8 = 'z';
        var got: u8 = 0;
        expect(c.write(handles[1], @ptrCast(&byte), 1) == 1);
        expect(c.read(back.handle, @ptrCast(&got), 1) == 1);
        expect(got == 'z');
    }
    // `back.handle` is the `dup`, and nothing ever registered *it*: the
    // marshal duplicated the descriptor and cleared NODUPS, so the close takes
    // the deregistering path with a handle the backend has never seen.
    // Deregistering something that was never registered is quiet on every
    // backend: it is the state the call is trying to reach.
    try_(stream.streamClose(back));
    try_(stream.streamClose(s));
    closeFarEnd(handles);
}

/// The fibers `probeOperation` names its two operations by.
var probe_fibers: [2]?*fibers.Fiber = .{ null, null };

/// What `probeOperation` recorded: two characters per event, the operation
/// and then the event, in the order the events arrived.
var probe_log: [64]u8 = undefined;
var probe_log_len: usize = 0;

/// An event callback that records what it was given and ends its operation on
/// a close, which is what every callback in the runtime does with that event.
fn probeOperation(op: *stream.Operation, event: ev.AsyncEvent) raise.Error!void {
    const which: u8 = if (op.fiber == probe_fibers[0])
        '0'
    else if (op.fiber == probe_fibers[1])
        '1'
    else
        '?';
    const tag: u8 = switch (event) {
        constants.AsyncEvent.init => 'i',
        constants.AsyncEvent.deinit => 'd',
        constants.AsyncEvent.mark => 'm',
        constants.AsyncEvent.close => 'c',
        else => 'x',
    };
    if (probe_log_len + 2 <= probe_log.len) {
        probe_log[probe_log_len] = which;
        probe_log[probe_log_len + 1] = tag;
        probe_log_len += 2;
    }
    if (event == constants.AsyncEvent.close) ev.asyncEnd(op);
}

/// Two operations outstanding on one stream in one direction. No Wattle
/// program can see the list itself, so the order, the marking and the close
/// are asserted here.
///
/// The oracle is the log the callback writes, which is derived from the events
/// it is given rather than from the list it is being asserted about.
fn theOperationsOnOneStream() void {
    const handles = probePipe();
    const s = try_(stream.makeStream(handles[0], @intCast(constants.stream_readable), &probe_methods));
    const sv = wrap.fromAbstract(s);
    gc_alloc.gcroot(sv);
    defer _ = gc_alloc.gcunroot(sv);

    const pair = doString("[(fiber/new (fn [] nil)) (fiber/new (fn [] nil))]");
    gc_alloc.gcroot(pair);
    defer _ = gc_alloc.gcunroot(pair);
    const tup = harness.elems(pair);
    probe_fibers = .{ wrap.toFiber(tup[0]), wrap.toFiber(tup[1]) };
    probe_log_len = 0;

    try_(ev.asyncStartFiber(probe_fibers[0], s, constants.AsyncMode.reading, &probeOperation, null));
    try_(ev.asyncStartFiber(probe_fibers[1], s, constants.AsyncMode.reading, &probeOperation, null));
    const first = probe_fibers[0].?.ev_op.?;
    const second = probe_fibers[1].?.ev_op.?;

    // The second read does not displace the first. Both are on the stream, in
    // the order they were started, and neither is in the other direction.
    expect(s.read_ops == first);
    expect(first.next == second);
    expect(second.next == null);
    expect(s.write_ops == null);
    expect(first.stream == s and second.stream == s);
    expect(first.serial != second.serial);

    // A dispatch walk offers an event to both, in that order, and stops.
    stream.opMarkPending(s);
    expect(stream.opTakePending(s, true) == first);
    expect(stream.opTakePending(s, true) == second);
    expect(stream.opTakePending(s, true) == null);
    expect(stream.opTakePending(s, false) == null);
    expect(stream.opWaiting(s, true) and !stream.opWaiting(s, false));

    // A collection reaches both, because the stream traces every operation on
    // it rather than one fiber per direction.
    gc_mark.collect();
    expect(std.mem.indexOf(u8, probe_log[0..probe_log_len], "0m") != null);
    expect(std.mem.indexOf(u8, probe_log[0..probe_log_len], "1m") != null);

    // Ending the first leaves the second, and the stream's head is now the
    // second rather than nothing.
    probe_log_len = 0;
    ev.asyncEnd(first);
    expect(s.read_ops == second);
    expect(second.next == null);
    expect(probe_fibers[0].?.ev_op == null);
    expect(probe_fibers[1].?.ev_op == second);
    expect(std.mem.eql(u8, probe_log[0..probe_log_len], "0d"));

    // Closing ends every operation left, not only the last started.
    probe_log_len = 0;
    try_(stream.streamClose(s));
    expect(s.read_ops == null and s.write_ops == null);
    expect(probe_fibers[1].?.ev_op == null);
    expect(std.mem.eql(u8, probe_log[0..probe_log_len], "1c1d"));

    probe_fibers = .{ null, null };
    closeFarEnd(handles);
}

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
    // `evLasterr` reads errno and renders it, with no side effect of its own
    // the same errno gives the same string twice.
    std.c._errno().* = @intFromEnum(std.posix.E.BADF);
    const first = stream.evLasterr();
    const second = stream.evLasterr();
    expect(harness.isType(first, repr.Tag.string));
    expect(order.equals(first, second));
    std.c._errno().* = @intFromEnum(std.posix.E.INVAL);
    expect(!order.equals(first, stream.evLasterr()));
}

fn theLoopExitCondition() void {
    // Nothing scheduled, no timers, no listeners.
    expect(ev.loopDone());

    // A listener is enough to keep the loop alive, and the count is a count
    // rather than a flag.
    ev.evIncRefcount();
    expect(!ev.loopDone());
    ev.evIncRefcount();
    expect(!ev.loopDone());
    ev.evDecRefcount();
    expect(!ev.loopDone());
    ev.evDecRefcount();
    expect(ev.loopDone());
}

fn postCallback(msg: ev.GenericMessage) callconv(.c) void {
    post_record.calls += 1;
    post_record.tag = msg.tag;
    post_record.value = msg.argj;
}

/// The self pipe, end to end: posting an event raises the listener count, and
/// one turn of the loop delivers the callback and lowers it again. On Windows
/// the same round trip goes through the completion port instead.
fn thePostedEventRoundTrip() void {
    post_record = .{};
    var msg = std.mem.zeroes(ev.GenericMessage);
    msg.tag = 41;
    msg.argj = harness.wrapInteger(42);

    expect(ev.loopDone());
    ev.evPostEvent(null, &postCallback, msg);
    expect(!ev.loopDone());

    raise.toAbi(ev.loop());
    expect(post_record.calls == 1);
    expect(post_record.tag == 41);
    expect(wrap.toInteger(post_record.value) == 42);
    expect(ev.loopDone());
}

/// A null callback is an event that wakes a loop blocked in the backend and
/// does nothing else. `ev.ThreadedCallback` is optional, and this is what
/// exercises the null arm of it.
///
/// The reference it takes is given back by the turn that delivers it, on
/// every backend. `evPostEvent` raises the listener count unconditionally, so
/// that the loop cannot decide it is done while an event is in flight; a
/// handler that lowered it only when there was a callback to run would leave
/// the count one higher for ever, and a loop that was interrupted once would
/// never report done again. One turn is what this drives, rather than `loop`,
/// because the assertion is about that turn.
fn theNullCallback() void {
    expect(ev.loopDone());
    const msg = std.mem.zeroes(ev.GenericMessage);
    ev.evPostEvent(null, null, msg);
    expect(!ev.loopDone());
    _ = raise.toAbi(ev.loop1());
    expect(ev.loopDone());
}

/// `ev.evDefaultThreadedCallback` with a null fiber is the cleanup-only
/// path: nothing is scheduled, and the payload is released for the two tags
/// that own one.
///
/// `*_STRINGF` is the "string, freed" tag: the subroutine allocated the bytes
/// and the callback releases them. Every other tag either has no
/// payload or points at something that is not the callback's: `ERR_STRING`
/// points at a string literal, and a tag with no payload may still name the
/// *request* pointer the subroutine has already released.
///
/// Freeing for every tag is what makes `(os/shell "cmd")` abort the process
/// and `ev/thread`'s start failure free `"failed to start thread"`. The two
/// halves are asserted here by construction: every payload below is a separate
/// heap block, so `res/testing/leaks.sh` counts a payload the callback
/// should have freed and did not, and the sanitizer catches one it freed twice.
fn theThreadedReplyTags() void {
    const Case = struct { tag: c_int, callback_frees: bool };
    const cases = [_]Case{
        .{ .tag = constants.ev_tctag_nil, .callback_frees = false },
        .{ .tag = constants.ev_tctag_integer, .callback_frees = false },
        .{ .tag = constants.ev_tctag_string, .callback_frees = false },
        .{ .tag = constants.ev_tctag_stringf, .callback_frees = true },
        .{ .tag = constants.ev_tctag_keyword, .callback_frees = false },
        .{ .tag = constants.ev_tctag_err_string, .callback_frees = false },
        .{ .tag = constants.ev_tctag_err_stringf, .callback_frees = true },
        .{ .tag = constants.ev_tctag_err_keyword, .callback_frees = false },
        .{ .tag = constants.ev_tctag_boolean, .callback_frees = false },
    };
    var owned: u32 = 0;
    for (cases) |case| {
        var msg = std.mem.zeroes(ev.GenericMessage);
        msg.tag = @intCast(case.tag);
        msg.fiber = null;
        // A heap payload, so that a missing free is a leak a sanitizer sees
        // and a double free is a crash.
        const payload = utils.malloc(8).?;
        const bytes: [*]u8 = @ptrCast(payload);
        @memcpy(bytes[0..8], "abcdefg\x00");
        msg.argp = payload;
        ev.evDefaultThreadedCallback(msg);
        if (case.callback_frees) {
            owned += 1;
        } else {
            // Not the callback's, so it is this contract's.
            utils.free(payload);
        }
    }
    expect(owned == 2);
    // The loop is untouched: a null fiber schedules nothing.
    expect(ev.loopDone());
}

/// Scheduling three deadlines out of order checks the ordering the heap
/// imposes rather than the wall clock: they come back in order.
fn theOrderedTimeouts() void {
    const out = doString(
        \\(def log ![])
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

/// `ev.addtimeout` and `ev.addtimeoutNil` differ in one field of the `Timeout`
/// they build: `is_error`. An expired error timeout cancels the fiber and an
/// expired nil timeout resumes it with nil.
///
/// Neither can be called from here directly. Both go through
/// `addFiberTimeout`, which reads `vm.root_fiber.?`, and that is set only
/// while the loop is running a task. `addtimeoutNil` has no caller in the tree
/// at all: `ev/read`'s optional timeout and the socket layer both take the
/// error one. So the contract lends the core environment a cfunction of its
/// own and drives it from a task, which is the only way to reach the pair.
fn cfunAddTimeout(argv: []repr.Value) raise.Error!repr.Value {
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
        "Contract-only: ev.addtimeout when the second argument is true, " ++
            "ev.addtimeoutNil when it is false.",
    );

    const out = doString(
        \\(def results ![])
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
        const row = harness.elems(results.slice()[i]);
        if (harness.keywordIs(row[0], "nil")) {
            // `addtimeout_nil` resumes with nil rather than raising.
            expect(harness.isType(row[1], repr.Tag.nil));
        } else {
            // `addtimeout` cancels the fiber, so `protect` reports a failure
            // with the message the loop supplies.
            const pair = harness.elems(row[1]);
            expect(harness.isType(pair[0], repr.Tag.boolean));
            expect(!wrap.toBoolean(pair[0]));
            expect(payloadIs(pair[1], "timeout"));
        }
    }
    expect(ev.loopDone());
}

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
    raise.toAbi(ev.loop());
    expect(ev.loopDone());

    // The supervisor got `[:error fiber nil]` rather than a stack trace on
    // stderr, and the fiber's last value is what the cancel passed.
    var event = wrap.fromNil();
    expect(try_(channel.channelTake(sup, &event)));
    expect(harness.isIndexed(event));
    const tup = harness.elems(event);
    expect(tup.len == 3);
    expect(harness.keywordIs(tup[0], "error"));
    expect(wrap.toFiber(tup[1]) == fiber);
    expect(harness.isType(tup[2], repr.Tag.nil));
    expect(payloadIs(fiber.last_value, "nope"));
    // One event, not two: the first schedule was superseded by the cancel.
    expect(!try_(channel.channelTake(sup, &event)));
}

/// A module's `wake` answers whether the fiber will be resumed, which is how
/// the module learns whether to free its context. It is false for a value that
/// is not a fiber and for a fiber a cancel has already scheduled, and true for
/// a fiber it schedules. The capability is the VM itself.
fn theWakeAnswers() void {
    const w: *boundary.Wake = @ptrCast(harness.vm());
    expect(!capi.wake(w, wrap.fromNumber(1), wrap.fromNil()));

    const out = doString("[(fiber/new (fn [x] x) :e) (fiber/new (fn [x] x) :e)]");
    gc_alloc.gcroot(out);
    defer _ = gc_alloc.gcunroot(out);
    const tup = harness.elems(out);
    const cancelled = wrap.toFiber(tup[0]);

    // The supervisor takes the cancelled fiber's error, which would otherwise
    // print a stack trace.
    const sup = channel.channelMake(4).?;
    const supv = wrap.fromAbstract(sup);
    gc_alloc.gcroot(supv);
    defer _ = gc_alloc.gcunroot(supv);
    cancelled.supervisor_channel = @ptrCast(sup);

    ev.schedule(cancelled, wrap.fromNil());
    expect(harness.raised(ev.cancel, .{ cancelled, value.fromBytes("gone", .string) }) == null);
    expect(!capi.wake(w, tup[0], wrap.fromNil()));

    expect(capi.wake(w, tup[1], value.fromBytes("woken", .string)));
    raise.toAbi(ev.loop());
    expect(ev.loopDone());
    expect(payloadIs(wrap.toFiber(tup[1]).last_value, "woken"));
}

/// `ev.scheduleSoon` puts a task at the head of the spawn queue where
/// `ev.schedule` appends. Nothing in Janet chooses between them.
fn theScheduleSoonOrder() void {
    const out = doString(
        \\(def log ![])
        \\(def a (fiber/new (fn [] (array/push log :a))))
        \\(def b (fiber/new (fn [] (array/push log :b))))
        \\[log a b]
    );
    gc_alloc.gcroot(out);
    defer _ = gc_alloc.gcunroot(out);
    const tup = harness.elems(out);
    const log = wrap.toArray(tup[0]);

    ev.schedule(wrap.toFiber(tup[1]), wrap.fromNil());
    ev.scheduleSoon(wrap.toFiber(tup[2]), wrap.fromNil(), boundary.Signal.ok);
    raise.toAbi(ev.loop());

    expect(log.count == 2);
    expect(harness.keywordIs(log.slice()[0], "b"));
    expect(harness.keywordIs(log.slice()[1], "a"));
}

fn theScheduleSignalOrder() void {
    const out = doString(
        \\(def log ![])
        \\(def a (fiber/new (fn [] (array/push log :a)) :e))
        \\(def b (fiber/new (fn [] (array/push log :b)) :e))
        \\[log a b]
    );
    gc_alloc.gcroot(out);
    defer _ = gc_alloc.gcunroot(out);
    const tup = harness.elems(out);
    const log = wrap.toArray(tup[0]);

    // `scheduleSignal` appends where `scheduleSoon` prepends, and nothing in
    // Janet chooses between the two.
    ev.scheduleSignal(wrap.toFiber(tup[1]), wrap.fromNil(), boundary.Signal.ok);
    ev.scheduleSoon(wrap.toFiber(tup[2]), wrap.fromNil(), boundary.Signal.ok);
    raise.toAbi(ev.loop());

    expect(log.count == 2);
    expect(harness.keywordIs(log.slice()[0], "b"));
    expect(harness.keywordIs(log.slice()[1], "a"));
}

/// `theScheduleSignalOrder` pairs an append with a prepend, which cannot tell
/// "appends" from "prepends": with both prepending the order comes out the
/// same. Three appends in a row can.
fn theScheduleSignalIsFifo() void {
    const out = doString(
        \\(def log ![])
        \\(def a (fiber/new (fn [] (array/push log :a)) :e))
        \\(def b (fiber/new (fn [] (array/push log :b)) :e))
        \\(def c (fiber/new (fn [] (array/push log :c)) :e))
        \\[log a b c]
    );
    gc_alloc.gcroot(out);
    defer _ = gc_alloc.gcunroot(out);
    const tup = harness.elems(out);
    const log = wrap.toArray(tup[0]);

    for (1..4) |i| {
        ev.scheduleSignal(wrap.toFiber(tup[@intCast(i)]), wrap.fromNil(), boundary.Signal.ok);
    }
    raise.toAbi(ev.loop());

    expect(log.count == 3);
    expect(harness.keywordIs(log.slice()[0], "a"));
    expect(harness.keywordIs(log.slice()[1], "b"));
    expect(harness.keywordIs(log.slice()[2], "c"));
}

/// `ev.evMark` walks the spawn queue and marks each task's *value* as well as
/// its fiber. The fiber is redundant, scheduling also putting it in
/// `vm.ev.active_tasks`, which is a root, but the resume value is not kept
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
    const tup = harness.elems(out);
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
    raise.toAbi(ev.loop());

    var got = wrap.fromNil();
    expect(try_(channel.channelTake(chan, &got)));
    expect(payloadIs(got, "only-in-the-queue"));
}

/// `ev.loop` returns when `ev.loopDone` says there is nothing left, and a task
/// suspended on a timer counts as something left, through `is_suspended`,
/// which raises the listener count on the way out of `loop1`. Every Janet test
/// reaches this from *inside* the loop, where the caller's own fiber keeps it
/// alive; only a caller outside can watch `loop` decide for itself.
fn theLoopWaitsForASleepingTask() void {
    expect(ev.loopDone());
    const out = doString(
        \\(def out (ev/chan 8))
        \\(def f (fiber/new (fn [] (ev/sleep 0.05) (ev/give out :done)) :e))
        \\[out f]
    );
    gc_alloc.gcroot(out);
    defer _ = gc_alloc.gcunroot(out);
    const tup = harness.elems(out);
    const chan = try_(channel.getChannel(tup[0..1], 0)).?;

    ev.schedule(wrap.toFiber(tup[1]), wrap.fromNil());
    expect(!ev.loopDone());
    raise.toAbi(ev.loop());

    // It ran to completion rather than being abandoned at its first suspend.
    var got = wrap.fromNil();
    expect(try_(channel.channelTake(chan, &got)));
    expect(harness.keywordIs(got, "done"));
    expect(ev.loopDone());
}

/// A chunked read over a pipe that cannot be satisfied when it is issued.
///
/// The writer sends three bytes, sleeps, and sends three more, so the read
/// waits on the backend at least once before it has its six. `suite-net` has
/// the same shape over a socket and it does not complete on Windows. A
/// failure here is the read path, and a pass narrows it to the socket.
///
/// The read is bounded by a deadline, so a backend that never wakes it fails
/// this case rather than hanging the driver.
fn theChunkedReadThatWaits() void {
    const out = doString(
        \\(def out (ev/chan 8))
        \\(def [r w] (os/pipe))
        \\(def reader
        \\  (fiber/new
        \\    (fn []
        \\      (ev/give out (in (protect (ev/with-deadline 1 (string (ev/chunk r 6)))) 1))
        \\      (:close r))
        \\    :e))
        \\(def writer
        \\  (fiber/new
        \\    (fn [] (ev/write w "abc") (ev/sleep 0.05) (ev/write w "def") (:close w))
        \\    :e))
        \\[out reader writer]
    );
    gc_alloc.gcroot(out);
    defer _ = gc_alloc.gcunroot(out);
    const tup = harness.elems(out);
    const chan = try_(channel.getChannel(tup[0..1], 0)).?;

    ev.schedule(wrap.toFiber(tup[1]), wrap.fromNil());
    ev.schedule(wrap.toFiber(tup[2]), wrap.fromNil());
    raise.toAbi(ev.loop());

    // The reader reports the deadline's message where the read did not
    // finish, so the channel holds one or the other and never nothing.
    var got = wrap.fromNil();
    expect(try_(channel.channelTake(chan, &got)));
    expect(harness.stringValueIs(got, "abcdef"));
    expect(ev.loopDone());
}

/// `cancel` appends too, and nothing above distinguishes that from prepending.
/// Both fibers report into the same channel, so the order they reach it in is
/// the assertion, and the cancel's `sched_id` bump means the schedule that
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
    const tup = harness.elems(out);
    const chan = try_(channel.getChannel(tup[0..1], 0)).?;
    const a = wrap.toFiber(tup[1]);
    const b = wrap.toFiber(tup[2]);
    b.supervisor_channel = @ptrCast(chan);

    // b is scheduled first, so it is a task and `cancel` will accept it; the
    // cancel then supersedes that schedule.
    ev.schedule(b, wrap.fromNil());
    ev.schedule(a, wrap.fromNil());
    expect(harness.raised(ev.cancel, .{ b, value.fromBytes("late", .string) }) == null);
    raise.toAbi(ev.loop());

    var first = wrap.fromNil();
    var second = wrap.fromNil();
    expect(try_(channel.channelTake(chan, &first)));
    expect(try_(channel.channelTake(chan, &second)));
    // The task queued before the cancel runs first: the cancel appended.
    expect(harness.keywordIs(first, "a"));
    // And b ran once, as an error, rather than twice or as a sleep.
    expect(harness.isIndexed(second));
    expect(harness.keywordIs(harness.elems(second)[0], "error"));
    expect(!try_(channel.channelTake(chan, &first)));
}

/// `channel.channelMakeThreaded` differs from `channel.channelMake` in one
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

/// `channel.optChannel` takes its default when the argument is absent or nil,
/// and the channel otherwise. "Absent" is `argv.len > n`, and the boundary is
/// the case where the argument *exists* in the array but the slice's length
/// says it does not.
fn theOptChannelBoundary() void {
    const chanv = doString("(ev/chan 1)");
    gc_alloc.gcroot(chanv);
    defer _ = gc_alloc.gcunroot(chanv);

    var argv = [_]repr.Value{ chanv, wrap.fromNil() };
    const chan = try_(channel.getChannel(&argv, 0)).?;

    // A channel is there and the count says so.
    expect(try_(channel.optChannel(argv[0..1], 0, null)) == chan);
    // A channel is there and the count says it is not: the default wins, and
    // the value at that index is never looked at. An empty slice is the count
    // saying zero, which a sentinel table cannot express and a slice can.
    expect(try_(channel.optChannel(argv[0..0], 0, null)) == null);
    expect(try_(channel.optChannel(argv[0..0], 0, chan)) == chan);
    // Present but nil: the default wins.
    expect(try_(channel.optChannel(argv[0..2], 1, null)) == null);
}

/// A value at the index that is not a channel is an argument error.
///
/// `channel.getChannel` takes the argument slice and raises, so there is no
/// pointer-and-count conversion and no report to consume; what a Janet program
/// observes is the refusal.
fn theWrongArgumentIsNotAChannel() void {
    const chanv = doString("(ev/chan 1)");
    gc_alloc.gcroot(chanv);
    defer _ = gc_alloc.gcunroot(chanv);

    var argv = [_]repr.Value{ chanv, wrap.fromNil() };
    expect(try_(channel.getChannel(&argv, 0)).? == try_(channel.getChannel(argv[0..1], 0)).?);

    const refusal = harness.raised(channel.getChannel, .{ @as([]const repr.Value, &argv), @as(i32, 1) }).?;
    expect(refusal.signal == boundary.Signal.@"error");
}

// ==========================================================================
// Entry
// ==========================================================================

/// Runs one case, naming it first on the host that cannot say which it was.
///
/// `harness.announce` carries the reasoning. This contract keeps its own VM
/// for the whole run, so unlike `os_surface`'s `section` there is nothing to
/// open or close around the body.
fn inCase(comptime name: []const u8, comptime body: fn () void) void {
    harness.announce("ev_loop", name);
    body();
}

pub fn run() void {
    harness.init();
    defer vm_lifecycle.deinit();

    inCase("theProtectedScope", theProtectedScope);

    inCase("theEmbedderChannelApi", theEmbedderChannelApi);
    inCase("theThreadedChannel", theThreadedChannel);
    inCase("theChannelCapacityBound", theChannelCapacityBound);
    inCase("theClosedChannel", theClosedChannel);
    inCase("theChannelGetters", theChannelGetters);

    inCase("theStreamExtension", theStreamExtension);
    inCase("theDefaultMethods", theDefaultMethods);
    inCase("theStreamRendering", theStreamRendering);
    inCase("theStreamFlagMessages", theStreamFlagMessages);
    inCase("theNotCloseableStream", theNotCloseableStream);
    inCase("theStreamMarshalling", theStreamMarshalling);
    inCase("theOperationsOnOneStream", theOperationsOnOneStream);

    if (!windows) {
        inCase("thePipeModes", thePipeModes);
        inCase("theLastError", theLastError);
    }

    inCase("theLoopExitCondition", theLoopExitCondition);
    inCase("thePostedEventRoundTrip", thePostedEventRoundTrip);
    inCase("theNullCallback", theNullCallback);
    inCase("theThreadedReplyTags", theThreadedReplyTags);

    inCase("theOrderedTimeouts", theOrderedTimeouts);
    inCase("theTwoTimeoutConstructors", theTwoTimeoutConstructors);
    inCase("theCancelOfANonTask", theCancelOfANonTask);
    inCase("theWakeAnswers", theWakeAnswers);
    inCase("theScheduleSoonOrder", theScheduleSoonOrder);
    inCase("theScheduleSignalOrder", theScheduleSignalOrder);
    inCase("theScheduleSignalIsFifo", theScheduleSignalIsFifo);
    inCase("theMarkedTaskValues", theMarkedTaskValues);
    inCase("theLoopWaitsForASleepingTask", theLoopWaitsForASleepingTask);
    inCase("theChunkedReadThatWaits", theChunkedReadThatWaits);
    inCase("theCancelAppends", theCancelAppends);
    inCase("theThreadedFlag", theThreadedFlag);
    inCase("theOptChannelBoundary", theOptChannelBoundary);
    inCase("theWrongArgumentIsNotAChannel", theWrongArgumentIsNotAChannel);
}
