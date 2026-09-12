//! `core/channel`: the queue of values, the two queues of blocked fibers, the
//! lock that makes a threaded channel safe, and the ten `ev/` cfunctions over
//! them.
//!
//! This file owns the channel's layout. Its last member is a
//! `pthread_mutex_t` or a `CRITICAL_SECTION`, `host.zig`'s in both arms, which
//! is where every host type in this tree comes from, so this file needs no
//! `@cImport` of its own. `Channel` is the only declaration of that layout,
//! and `unwrap` below is the one cast from the abstract's payload pointer to
//! it.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const abstract_type = @import("../../api/abstract_type.zig");
const abstracts = @import("../value/abstracts.zig");
const args_core = @import("../args.zig");
const buffers = @import("../value/buffers.zig");
const constants = @import("constants");
const corefn = @import("../corefn.zig");
const ev = @import("../ev.zig");
const fibers = @import("../value/fibers.zig");
const gc_alloc = @import("../gc.zig");
const gc_mark = @import("../gc/mark.zig");
const host = @import("host");
const marsh = @import("../marsh.zig");
const math = @import("../math.zig");
const method_type = @import("../method_type.zig");
const os_locks = @import("locks.zig");
const pp_format = @import("../pp/format.zig");
const raise = @import("../../api/raise.zig");
const repr = @import("repr");
const tables = @import("../value/tables.zig");
const tuples = @import("../value/tuples.zig");
const utils = @import("../utils.zig");
const value = @import("../value.zig");
const vm_state = @import("../vm/state.zig");
const wrap = @import("../value/helpers/wrap.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// The marshalling flag a threaded channel sets to hand ownership across.
const marshalDecref: c_int = 0x40000;

/// The most items a channel is meant to take. Unused: the limit a channel
/// actually enforces is the argument layer's natural-number check, and this
/// records the intent rather than being consulted.
const max_channel_capacity: i32 = 0xFFFFFF;

/// The methods reached through `(:give ch x)` and its siblings.
const chanat_methods = [_]method_type.Method{
    .{ .name = "select", .cfun = &cfunChoice },
    .{ .name = "rselect", .cfun = &cfunRchoice },
    .{ .name = "count", .cfun = &cfunCount },
    .{ .name = "take", .cfun = &cfunTake },
    .{ .name = "give", .cfun = &cfunGive },
    .{ .name = "capacity", .cfun = &cfunCapacity },
    .{ .name = "full", .cfun = &cfunFull },
    .{ .name = "close", .cfun = &cfunClose },
    .{ .name = null, .cfun = null },
};

/// The abstract type a channel is.
///
/// `pub` for `ev.zig` and for `test/ev_loop.zig`, which both name the type to
/// recognise a channel abstract.
pub const channelType = abstract_type.define(Channel, .{
    .name = "core/channel",
    .gc = chanatGC,
    .gcmark = chanatMark,
    .get = chanatGet,
    .marshal = chanatMarshal,
    .unmarshal = chanatUnmarshal,
    .next = chanatNext,
    .gcperthread = chanatGCPerThread,
});

/// Whether this target's channel lock is a `CRITICAL_SECTION`.
const windows = ev.windows;

// ==========================================================================
// Aliased types
// ==========================================================================

/// The channel's lock, which is `host.zig`'s mutex either way.
const Lock = if (windows) host.CRITICAL_SECTION else host.pthread_mutex_t;

// ==========================================================================
// Types
// ==========================================================================

/// Which caller is pushing, which decides what it does when it cannot.
pub const Caller = enum(c_int) {
    /// `ev/give`: register a pending write and block.
    plain = 0,
    /// One clause of an `ev/select`: register a pending *choice* write.
    choice = 1,
    /// A caller with no root fiber to suspend: `channelGive` below, and the
    /// supervisor push the loop makes on a fiber's behalf. Registers nothing.
    detached = 2,
};

/// A `core/channel`: the value queue, the read and write queues of blocked
/// fibers, the capacity, and the lock.
pub const Channel = struct {
    items: ev.Queue(repr.Value),
    read_pending: ev.Queue(Pending),
    write_pending: ev.Queue(Pending),
    limit: i32,
    closed: bool,
    is_threaded: bool,
    lock: Lock,
};

/// The mode a blocked fiber is waiting in. The values travel between threads
/// inside a generic message's `tag`, so each is written out.
const Mode = enum(c_int) {
    read = 0,
    write = 1,
    choice_read = 2,
    choice_write = 3,
    close = 4,
};

/// One fiber waiting on a channel, with the mode it is waiting in.
const Pending = struct {
    thread: ?*vm_state.Vm,
    fiber: *fibers.Fiber,
    sched_id: u32,
    mode: Mode,
};

// ==========================================================================
// Public functions
// ==========================================================================

/// The channel argument at `argv[n]`, or a raise where it is not a channel.
fn channelArg(argv: []const repr.Value, n: usize) raise.Error!*Channel {
    return try args_core.getAbstract(Channel, argv, n, &channelType);
}

/// Gives a value to a channel from Zig, with no fiber to suspend.
pub fn channelGive(chan: ?*Channel, x: repr.Value) raise.Error!bool {
    return push(unwrap(chan), x, .detached);
}

/// `channelGive` for a caller with no error channel.
pub fn channelGiveAbi(chan: ?*Channel, x: repr.Value) c_int {
    return @intFromBool(raise.toAbi(channelGive(chan, x)));
}

/// A new unthreaded channel of the given capacity.
pub fn channelMake(limit: u32) ?*Channel {
    ev.assert(@src(), limit <= std.math.maxInt(i32), "bad limit");
    const chan = unwrap(abstracts.newFor(Channel, &channelType));
    chanInit(chan, @intCast(limit), false);
    return @ptrCast(chan);
}

/// A new threaded channel, which allocates its lock as well.
pub fn channelMakeThreaded(limit: u32) ?*Channel {
    ev.assert(@src(), limit <= std.math.maxInt(i32), "bad limit");
    const chan = unwrap(abstracts.threaded(&channelType, @sizeOf(Channel)));
    chanInit(chan, @intCast(limit), true);
    return @ptrCast(chan);
}

/// Takes a value from a channel from Zig, with no fiber to suspend.
pub fn channelTake(chan: ?*Channel, out: *repr.Value) raise.Error!bool {
    return pop(unwrap(chan), out, .detached);
}

/// The first ten rows `ev.zig`'s `libEv` installs, in its order.
pub fn entries() []const corefn.Entry {
    const list = comptime blk: {
        var acc: []const corefn.Entry = &.{};
        acc = acc ++ [_]corefn.Entry{
            corefn.reg("ev/give", &cfunGive, @src(), "(ev/give channel value)", "Write a value to a channel, suspending the current fiber if the channel is full. " ++
                "Returns the channel if the write succeeded, nil otherwise."),
            corefn.reg("ev/take", &cfunTake, @src(), "(ev/take channel)", "Read from a channel, suspending the current fiber if no value is available."),
            corefn.reg("ev/full", &cfunFull, @src(), "(ev/full channel)", "Check if a channel is full or not."),
            corefn.reg("ev/capacity", &cfunCapacity, @src(), "(ev/capacity channel)", "Get the number of items a channel will store before blocking writers."),
            corefn.reg("ev/count", &cfunCount, @src(), "(ev/count channel)", "Get the number of items currently waiting in a channel."),
            corefn.reg("ev/select", &cfunChoice, @src(), "(ev/select & clauses)", "Block until the first of several channel operations occur. Returns a " ++
                "tuple of the form [:give chan], [:take chan x], or [:close chan], " ++
                "where a :give tuple is the result of a write and a :take tuple is the " ++
                "result of a read. Each clause must be either a channel (for a channel " ++
                "take operation) or a tuple [channel x] (for a channel give operation). " ++
                "Operations are tried in order such that earlier clauses take " ++
                "precedence over later clauses. Both give and take operations can " ++
                "return a [:close chan] tuple, which indicates that the specified " ++
                "channel was closed while waiting, or that the channel was already " ++
                "closed."),
            corefn.reg("ev/rselect", &cfunRchoice, @src(), "(ev/rselect & clauses)", "Similar to ev/select, but will try clauses in a random order for fairness."),
            corefn.reg("ev/chan", &cfunNew, @src(), "(ev/chan &opt capacity)", "Create a new channel. capacity is the number of values to queue before " ++
                "blocking writers, defaults to 0 if not provided. Returns a new channel."),
            corefn.reg("ev/thread-chan", &cfunNewThreaded, @src(), "(ev/thread-chan &opt limit)", "Create a threaded channel. A threaded channel is a channel that can be shared between threads and " ++
                "used to communicate between any number of operating system threads."),
            corefn.reg("ev/chan-close", &cfunClose, @src(), "(ev/chan-close chan)", "Close a channel. A closed channel will cause all pending reads and writes to return nil. " ++
                "Returns the channel."),
        };
        break :blk acc;
    };
    return list;
}

/// The channel at slot `n`, or a raise where it is not a channel.
pub fn getChannel(argv: []const repr.Value, n: usize) raise.Error!?*Channel {
    return try args_core.getAbstract(Channel, argv, n, &channelType);
}

/// The `[tag fiber-or-value task-id]` tuple a supervisor channel receives.
pub fn makeSupervisorEvent(name: [*:0]const u8, fiber: *fibers.Fiber, threaded: bool) repr.Value {
    var tup: [3]repr.Value = undefined;
    tup[0] = value.fromBytes(std.mem.span(name), .keyword);
    tup[1] = if (threaded) fiber.last_value else wrap.fromFiber(fiber);
    tup[2] = if (fiber.env) |env|
        tables.get(env, value.fromBytes("task-id", .keyword))
    else
        wrap.fromNil();
    return wrap.fromTuple(tuples.newFrom(&tup));
}

/// The channel at slot `n`, or `dflt` where the slot is absent or nil.
pub fn optChannel(
    argv: []const repr.Value,
    n: usize,
    dflt: ?*Channel,
) raise.Error!?*Channel {
    if (argv.len > n and !repr.checkType(argv[n], repr.Tag.nil)) {
        return getChannel(argv, n);
    }
    return dflt;
}

/// Takes the lock, pops a value, and releases it.
pub fn pop(chan: *Channel, item: *repr.Value, is_choice: Caller) raise.Error!bool {
    lock(chan);
    defer unlock(chan);
    return popWithLock(chan, item, is_choice);
}

/// Takes the lock, pushes a value, and releases it.
pub fn push(chan: *Channel, x: repr.Value, mode: Caller) raise.Error!bool {
    lock(chan);
    defer unlock(chan);
    return pushWithLock(chan, x, mode);
}

// ==========================================================================
// Private functions
// ==========================================================================

/// `(ev/capacity ch)`.
fn cfunCapacity(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const chan = try channelArg(argv, 0);
    lock(chan);
    defer unlock(chan);
    const ret = wrap.fromInteger(chan.limit);
    return ret;
}

/// `(ev/select & clauses)`.
fn cfunChoice(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, -1);

    if (vm_state.current().coerce_error) {
        return raise.panic("cannot select from channel inside janet_call");
    }

    // Check channels for immediate reads and writes.
    for (argv, 0..) |arg, i| {
        // An argument that is not indexed reads as an empty view, whose
        // length is not two, which is the read arm, and the same result the
        // null test gave.
        const data = args_core.indexedView(arg) orelse &[_]repr.Value{};
        if (data.len == 2) {
            // Write.
            const chan = try channelArg(data, 0);
            lock(chan);
            defer unlock(chan);
            if (chan.closed) return makeCloseResult(chan);
            if (chan.items.count() < chan.limit) {
                _ = try pushWithLock(chan, data[1], .choice);
                return makeWriteResult(chan);
            }
        } else {
            // Read.
            const chan = try channelArg(argv, i);
            lock(chan);
            defer unlock(chan);
            if (chan.closed) return makeCloseResult(chan);
            if (chan.items.head != chan.items.tail) {
                var item: repr.Value = undefined;
                _ = try popWithLock(chan, &item, .choice);
                return makeReadResult(chan, item);
            }
        }
    }

    // Wait for all readers or writers.
    for (argv, 0..) |arg, i| {
        const data = args_core.indexedView(arg) orelse &[_]repr.Value{};
        if (data.len == 2) {
            const chan = try channelArg(data, 0);
            lock(chan);
            defer unlock(chan);
            _ = try pushWithLock(chan, data[1], .choice);
        } else {
            var item: repr.Value = undefined;
            const chan = try channelArg(argv, i);
            lock(chan);
            defer unlock(chan);
            _ = try popWithLock(chan, &item, .choice);
        }
    }

    return ev.awaitEvent();
}

/// `(ev/chan-close ch)`.
fn cfunClose(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const chan = try channelArg(argv, 0);
    lock(chan);
    defer unlock(chan);
    if (!chan.closed) {
        chan.closed = true;
        var writer: Pending = undefined;
        while (chan.write_pending.pop(&writer) == 0) {
            if (writer.thread != vm_state.current()) {
                if (writer.thread) |target| {
                    ev.evPostEvent(target, threadChanCallback, .{
                        .fiber = writer.fiber,
                        .argp = chan,
                        .tag = @intFromEnum(Mode.close),
                        .argi = @bitCast(writer.sched_id),
                        .argj = wrap.fromNil(),
                    });
                }
            } else if (fibers.canResume(writer.fiber) and
                writer.sched_id == writer.fiber.sched_id)
            {
                if (writer.mode == .choice_write) {
                    ev.schedule(writer.fiber, makeCloseResult(chan));
                } else {
                    ev.schedule(writer.fiber, wrap.fromNil());
                }
            }
        }
        var reader: Pending = undefined;
        while (chan.read_pending.pop(&reader) == 0) {
            if (reader.thread != vm_state.current()) {
                if (reader.thread) |target| {
                    ev.evPostEvent(target, threadChanCallback, .{
                        .fiber = reader.fiber,
                        .argp = chan,
                        .tag = @intFromEnum(Mode.close),
                        .argi = @bitCast(reader.sched_id),
                        .argj = wrap.fromNil(),
                    });
                }
            } else if (fibers.canResume(reader.fiber) and
                reader.sched_id == reader.fiber.sched_id)
            {
                if (reader.mode == .choice_read) {
                    ev.schedule(reader.fiber, makeCloseResult(chan));
                } else {
                    ev.schedule(reader.fiber, wrap.fromNil());
                }
            }
        }
    }
    return argv[0];
}

/// `(ev/count ch)`.
fn cfunCount(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const chan = try channelArg(argv, 0);
    lock(chan);
    defer unlock(chan);
    return wrap.fromInteger(chan.items.count());
}

/// `(ev/full ch)`.
fn cfunFull(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const chan = try channelArg(argv, 0);
    lock(chan);
    defer unlock(chan);
    return wrap.fromBoolean(chan.items.count() >= chan.limit);
}

/// `(ev/give ch x)`.
fn cfunGive(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 2);
    const chan = try channelArg(argv, 0);
    if (vm_state.current().coerce_error) {
        return raise.panic("cannot give to channel inside janet_call");
    }
    if (try push(chan, argv[1], .plain)) return ev.awaitEvent();
    return argv[0];
}

/// `(ev/chan &opt capacity)`.
fn cfunNew(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 0, 1);
    const limit = try args_core.optNat(argv, 0, 0);
    const chan = unwrap(abstracts.newFor(Channel, &channelType));
    chanInit(chan, limit, false);
    return wrap.fromAbstract(chan);
}

/// `(ev/thread-chan &opt limit)`.
fn cfunNewThreaded(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 0, 1);
    const limit = try args_core.optNat(argv, 0, 0);
    const chan = unwrap(abstracts.threaded(&channelType, @sizeOf(Channel)));
    chanInit(chan, limit, true);
    return wrap.fromAbstract(chan);
}

/// `(ev/rselect & clauses)`.
fn cfunRchoice(argv: []repr.Value) raise.Error!repr.Value {
    fisherYatesArgs(argv);
    return cfunChoice(argv);
}

/// `(ev/take ch)`.
fn cfunTake(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const chan = try channelArg(argv, 0);
    var item: repr.Value = undefined;
    if (vm_state.current().coerce_error) {
        return raise.panic("cannot take from channel inside janet_call");
    }
    if (try pop(chan, &item, .plain)) ev.schedule(vm_state.current().root_fiber.?, item);
    return ev.awaitEvent();
}

/// The collector finalising a channel: frees the queues and the lock.
fn chanatGC(chan: *Channel, _: usize) void {
    chanDeinit(chan);
}

/// What runs on each thread that still names a channel being collected: drops
/// this thread's references to it.
fn chanatGCPerThread(chan: *Channel, _: usize) void {
    lock(chan);
    defer unlock(chan);
    removeVMRef(&chan.read_pending);
    removeVMRef(&chan.write_pending);
}

/// The method lookup behind `(:give ch x)` and its siblings.
fn chanatGet(_: *Channel, key: repr.Value) raise.Error!?repr.Value {
    return args_core.findMethod(key, @ptrCast(&chanat_methods));
}

/// Traces the queued values and the fibers in both pending queues.
fn chanatMark(chan: *Channel, _: usize) void {
    markFQ(&chan.read_pending);
    markFQ(&chan.write_pending);
    for (chan.items.segments()) |run| {
        for (run) |item| gc_mark.mark(item);
    }
}

/// Writes an unthreaded channel's contents and capacity.
fn chanatMarshal(chan: *Channel, m: *abi.Marshal) raise.Error!void {
    try marsh.marshalByte(m, @intFromBool(chan.is_threaded));
    marsh.marshalAbstract(m, chan);
    try marsh.marshalByte(m, @intFromBool(chan.closed));
    try marsh.marshalInt(m, chan.limit);
    try marsh.marshalInt(m, chan.items.count());
    for (chan.items.segments()) |run| {
        for (run) |item| try marsh.marshalJanet(m, item);
    }
}

/// The iteration order behind `next` and `(keys ch)`.
fn chanatNext(_: *Channel, key: repr.Value) raise.Error!repr.Value {
    return args_core.nextmethod(@ptrCast(&chanat_methods), key);
}

/// Reads a channel back, refusing a threaded one, which cannot be rebuilt from
/// a portable stream.
fn chanatUnmarshal(u: *abi.Unmarshal) raise.Error!*Channel {
    // The lead byte `chanatMarshal` wrote says which heap the channel lived
    // on. A threaded channel cannot be rebuilt from a portable stream: it
    // needs an allocation on the threaded heap and a reference count handed to
    // whoever reads it, and this encoding has neither. So it is refused where
    // the caller can act on it, and every path past here has the byte clear.
    const is_threaded = try marsh.unmarshalByte(u);
    if (is_threaded != 0) return raise.panic("cannot unmarshal a threaded channel");
    const abst: *Channel = unwrap(try marsh.unmarshalAbstract(u, @sizeOf(Channel)));
    const is_closed = try marsh.unmarshalByte(u);
    const limit = try marsh.unmarshalInt(u);
    const count = try marsh.unmarshalInt(u);
    if (count < 0) return raise.panic("invalid negative channel count");
    if (count > limit) return raise.panic("invalid channel count");
    // Unthreaded, and that comes from the byte rather than from a constant:
    // the threaded case raised above.
    chanInit(abst, limit, false);
    abst.closed = is_closed != 0;
    for (0..@as(usize, @intCast(count))) |_| {
        const item = try marsh.unmarshalJanet(u);
        ev.assert(@src(), abst.items.push(item) == 0, "bad unmarshal channel");
    }
    return abst;
}

/// Frees the queues, and the lock where the channel is threaded.
fn chanDeinit(chan: *Channel) void {
    if (isThreaded(chan)) {
        var item: repr.Value = undefined;
        lock(chan);
        defer unlock(chan);
        chan.read_pending.deinit();
        chan.write_pending.deinit();
        while (chan.items.pop(&item) == 0) {
            // Draining a threaded channel's items as it is torn down. The
            // channel is already unlinked and its queues are being freed
            // around this loop, so there is no scope above it and nothing
            // that could act on a raise if there were.
            _ = raise.total(unpack(chan, &item, true), "a channel's teardown");
        }
        chan.items.deinit();
    } else {
        chan.read_pending.deinit();
        chan.write_pending.deinit();
        chan.items.deinit();
    }
    os_locks.mutexDeinit(@ptrCast(&chan.lock));
}

/// Sets up an empty channel of the given capacity.
fn chanInit(chan: *Channel, limit: i32, threaded: bool) void {
    chan.limit = limit;
    chan.closed = false;
    chan.is_threaded = threaded;
    chan.items.init();
    chan.read_pending.init();
    chan.write_pending.init();
    os_locks.mutexInit(@ptrCast(&chan.lock));
}

/// Shuffles the arguments with Fisher-Yates, so that `ev/rselect` is fair.
fn fisherYatesArgs(argv: []repr.Value) void {
    var i = argv.len;
    while (i > 1) : (i -= 1) {
        const swap_index = math.rngU32(&vm_state.current().ev.ev_rng) % @as(u32, @intCast(i));
        const temp = argv[swap_index];
        argv[swap_index] = argv[i - 1];
        argv[i - 1] = temp;
    }
}

/// Whether a channel is threaded, which is what decides every lock below.
inline fn isThreaded(chan: *Channel) bool {
    return chan.is_threaded;
}

/// Takes the channel's lock, or does nothing for an unthreaded channel.
fn lock(chan: *Channel) void {
    if (!isThreaded(chan)) return;
    os_locks.mutexLock(@ptrCast(&chan.lock));
}

/// The `[:close ch]` tuple a blocked fiber receives when the channel closes.
fn makeCloseResult(chan: *Channel) repr.Value {
    const tup = tuples.begin(2);
    tup[0] = value.fromBytes("close", .keyword);
    tup[1] = wrapChannel(chan);
    return wrap.fromTuple(tuples.end(tup));
}

/// The `[:read ch value]` tuple a blocked reader receives.
fn makeReadResult(chan: *Channel, x: repr.Value) repr.Value {
    const tup = tuples.begin(3);
    tup[0] = value.fromBytes("take", .keyword);
    tup[1] = wrapChannel(chan);
    tup[2] = x;
    return wrap.fromTuple(tuples.end(tup));
}

/// The `[:write ch]` tuple a blocked writer receives.
fn makeWriteResult(chan: *Channel) repr.Value {
    const tup = tuples.begin(2);
    tup[0] = value.fromBytes("give", .keyword);
    tup[1] = wrapChannel(chan);
    return wrap.fromTuple(tuples.end(tup));
}

/// Traces the fibers in one pending queue.
fn markFQ(fq: *ev.Queue(Pending)) void {
    for (fq.segments()) |run| {
        for (run) |pending| gc_mark.mark(wrap.fromFiber(pending.fiber));
    }
}

/// Marshals a value that is about to cross an operating system thread.
///
/// Reports true on failure. The five types listed are self-contained words and
/// cross as they are; everything else becomes a buffer of an unsafe
/// marshalling, which `unpack` reverses.
fn pack(chan: *Channel, x: *repr.Value) raise.Error!bool {
    if (!isThreaded(chan)) return false;
    switch (repr.typeOf(x.*)) {
        repr.Tag.nil, repr.Tag.number, repr.Tag.pointer, repr.Tag.boolean, repr.Tag.cfunction => return false,
        else => {
            const buf: *buffers.Buffer = @ptrCast(@alignCast(utils.malloc(@sizeOf(buffers.Buffer)) orelse
                ev.outOfMemory(@src())));
            // `marshal` raises on any value a threaded channel cannot take,
            // an alive fiber, a file in safe mode, an unregistered cfunction,
            // and this buffer is not the collector's, so the raise has to
            // release it here.
            errdefer {
                buffers.deinit(buf);
                utils.free(buf);
            }
            _ = buffers.init(buf, 10);
            try marsh.marshal(buf, x.*, null, constants.JANET_MARSHAL_UNSAFE);
            x.* = wrap.fromBuffer(buf);
            return false;
        },
    }
}

/// Pops a value, reporting whether one was obtained. `Caller.detached` here is
/// `channelTake`, which does not register a pending read.
///
/// The caller takes the lock across this and releases it, for the reason
/// `pushWithLock` gives, and for one more of its own: the `.detached` arm
/// below returns without unlocking, so an empty threaded channel would stay
/// locked if the release were this function's.
fn popWithLock(chan: *Channel, item: *repr.Value, is_choice: Caller) raise.Error!bool {
    var writer: Pending = undefined;
    if (chan.closed) {
        item.* = wrap.fromNil();
        return true;
    }
    const is_threaded = isThreaded(chan);
    if (chan.items.pop(item) != 0) {
        // Queue empty.
        if (is_choice == .detached) return false; // Skip pending read.
        const pending: Pending = .{
            .thread = vm_state.current(),
            .fiber = vm_state.current().root_fiber.?,
            .sched_id = vm_state.current().root_fiber.?.sched_id,
            .mode = if (is_choice == .choice) Mode.choice_read else Mode.read,
        };
        _ = chan.read_pending.push(pending);
        if (is_threaded) gc_alloc.gcroot(wrap.fromFiber(pending.fiber));
        return false;
    }
    ev.assert(@src(), !(try unpack(chan, item, false)), "bad channel packing");
    if (chan.write_pending.pop(&writer) == 0) {
        // Pending writer.
        if (is_threaded) {
            if (writer.thread) |target| {
                ev.evPostEvent(target, threadChanCallback, .{
                    .tag = @intFromEnum(writer.mode),
                    .fiber = writer.fiber,
                    .argi = @bitCast(writer.sched_id),
                    .argp = chan,
                    .argj = wrap.fromNil(),
                });
            }
        } else if (writer.mode == .choice_write) {
            ev.schedule(writer.fiber, makeWriteResult(chan));
        } else {
            ev.schedule(writer.fiber, wrap.fromAbstract(chan));
        }
    }
    return true;
}

/// Pushes a value, reporting whether the caller should block.
///
/// The caller takes the lock across this and releases it, with a `defer`.
/// Releasing it here instead, on each of this function's own returns, is what
/// the two raising paths inside `pack` and `unpack` go straight past, and a
/// threaded channel left locked is locked against every other thread.
fn pushWithLock(chan: *Channel, x_in: repr.Value, mode: Caller) raise.Error!bool {
    var x = x_in;
    var reader: Pending = undefined;
    if (chan.closed) return raise.panic("cannot write to closed channel");
    if (try pack(chan, &x)) {
        return pp_format.panicf("failed to pack value for channel: %v", .{x});
    }
    const is_threaded = isThreaded(chan);
    var is_empty: c_int = undefined;
    if (is_threaded) {
        // Don't dereference a fiber owned by another thread.
        is_empty = chan.read_pending.pop(&reader);
    } else {
        while (true) {
            is_empty = chan.read_pending.pop(&reader);
            if (is_empty != 0 or reader.sched_id == reader.fiber.sched_id) break;
        }
    }
    if (is_empty != 0) {
        // No pending reader.
        if (chan.items.push(x) != 0) {
            _ = try unpack(chan, &x, true);
            return pp_format.panicf("channel overflow: %v", .{x});
        } else if (chan.items.count() > chan.limit) {
            // No root fiber, we are in completion on a root fiber. Don't block.
            if (mode == .detached) return true;
            // Pushed successfully, but should block.
            const pending: Pending = .{
                .thread = vm_state.current(),
                .fiber = vm_state.current().root_fiber.?,
                .sched_id = vm_state.current().root_fiber.?.sched_id,
                .mode = if (mode == .choice) Mode.choice_write else Mode.write,
            };
            _ = chan.write_pending.push(pending);
            if (is_threaded) gc_alloc.gcroot(wrap.fromFiber(pending.fiber));
            return true;
        }
    } else {
        // Pending reader.
        if (is_threaded) {
            if (reader.thread) |target| {
                ev.evPostEvent(target, threadChanCallback, .{
                    .tag = @intFromEnum(reader.mode),
                    .fiber = reader.fiber,
                    .argi = @bitCast(reader.sched_id),
                    .argp = chan,
                    .argj = x,
                });
            } else {
                // No vm to send to, so unpack the payload to avoid a leak.
                _ = try unpack(chan, &x, true);
            }
        } else if (reader.mode == .choice_read) {
            ev.schedule(reader.fiber, makeReadResult(chan, x));
        } else {
            ev.schedule(reader.fiber, x);
        }
    }
    return false;
}

/// Replaces every reference to this thread's VM in a pending queue with null,
/// so that a channel outliving the thread does not name it.
fn removeVMRef(fq: *ev.Queue(Pending)) void {
    const me = vm_state.current();
    for (fq.segments()) |run| {
        for (run) |*pending| {
            if (pending.thread == me) pending.thread = null;
        }
    }
}

/// What the loop runs on the main thread when a threaded channel is given to
/// or taken from.
fn threadChanCallback(msg: ev.GenericMessage) callconv(.c) void {
    const sched_id: u32 = @bitCast(msg.argi);
    const fiber = msg.fiber.?;
    const mode: Mode = @enumFromInt(msg.tag);
    const chan = unwrap(msg.argp);
    var x = msg.argj;
    lock(chan);
    defer unlock(chan);
    if (fiber.sched_id == sched_id) {
        if (mode == .choice_read) {
            ev.assert(@src(), !raise.total(unpack(chan, &x, false), "a threaded channel's wakeup"), "packing error");
            ev.schedule(fiber, makeReadResult(chan, x));
        } else if (mode == .choice_write) {
            ev.schedule(fiber, makeWriteResult(chan));
        } else if (mode == .read) {
            ev.assert(@src(), !raise.total(unpack(chan, &x, false), "a threaded channel's wakeup"), "packing error");
            ev.schedule(fiber, x);
        } else if (mode == .write) {
            ev.schedule(fiber, wrapChannel(chan));
        } else { // mode == .close
            ev.schedule(fiber, wrap.fromNil());
        }
    } else if (mode != .close) {
        // The fiber has already been canceled or resumed, so resend the event
        // to another waiting thread.
        const is_read = (mode == .choice_read) or (mode == .read);
        if (is_read) {
            var reader: Pending = undefined;
            var sent = false;
            while (chan.read_pending.pop(&reader) == 0) {
                const target = reader.thread orelse continue;
                ev.evPostEvent(target, threadChanCallback, .{
                    .tag = @intFromEnum(reader.mode),
                    .fiber = reader.fiber,
                    .argi = @bitCast(reader.sched_id),
                    .argp = chan,
                    .argj = x,
                });
                sent = true;
                break;
            }
            if (!sent) _ = raise.total(unpack(chan, &x, true), "a threaded channel's wakeup");
        } else {
            var writer: Pending = undefined;
            while (chan.write_pending.pop(&writer) == 0) {
                const target = writer.thread orelse continue;
                ev.evPostEvent(target, threadChanCallback, .{
                    .tag = @intFromEnum(writer.mode),
                    .fiber = writer.fiber,
                    .argi = @bitCast(writer.sched_id),
                    .argp = chan,
                    .argj = wrap.fromNil(),
                });
                break;
            }
        }
    }
}

/// Releases the channel's lock, which every caller reaches through a `defer`.
///
/// A `defer` has no error channel, and a mutex this thread took and cannot
/// release leaves the channel unusable by anyone, so the failure is fatal at
/// the site rather than a report for whatever opens the next scope.
fn unlock(chan: *Channel) void {
    if (!isThreaded(chan)) return;
    raise.total(os_locks.mutexUnlock(@ptrCast(&chan.lock)), "a channel's unlock");
}

/// Reverses `pack` for a value that has crossed a thread.
fn unpack(chan: *Channel, x: *repr.Value, is_cleanup: bool) raise.Error!bool {
    if (!isThreaded(chan)) return false;
    switch (repr.typeOf(x.*)) {
        repr.Tag.nil, repr.Tag.number, repr.Tag.pointer, repr.Tag.boolean, repr.Tag.cfunction => return false,
        repr.Tag.buffer => {
            const buf = wrap.toBuffer(x.*);
            const flags: c_int = if (is_cleanup)
                constants.JANET_MARSHAL_UNSAFE | marshalDecref
            else
                constants.JANET_MARSHAL_UNSAFE;
            x.* = try marsh.unmarshal(buf.slice(), flags, null, null);
            buffers.deinit(buf);
            utils.free(buf);
            return false;
        },
        else => return true,
    }
}

/// The one cast from an abstract's payload pointer to a `Channel`.
pub inline fn unwrap(abstract: ?*anyopaque) *Channel {
    return @ptrCast(@alignCast(abstract));
}

/// A channel as a Janet value.
inline fn wrapChannel(chan: *Channel) repr.Value {
    return wrap.fromAbstract(chan);
}
