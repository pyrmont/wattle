//! `core/channel`: the queue of values, the two queues of blocked fibers, the
//! lock that makes a threaded channel safe, and the ten `ev/` cfunctions over
//! them.
//!
//! This file owns the channel's layout. Its last member is a
//! `pthread_mutex_t` or a `CRITICAL_SECTION` -- `host.zig`'s in both arms,
//! which is where every host type in this tree comes from, so this file needs
//! no `@cImport` of its own.
//!
//! **`Channel` is the only declaration of it.** The public entry points took a
//! `*Channel` -- a second, opaque name for the same pointer, which
//! existed because a C header could not say more. `unwrap` is still the one
//! cast, and it is the same cast `janet_channel_unwrap` has always been.

const std = @import("std");
const corefn = @import("../corefn.zig");
const raise = @import("../raise.zig");
const pp_format = @import("../pp/format.zig");
const ev = @import("../ev.zig");

const repr = @import("repr");
const constants = @import("constants");
const vm_state = @import("../vm/state.zig");
const marsh = @import("../marsh.zig");
const abstract_type = @import("../abstract_type.zig");
const method_type = @import("../method_type.zig");
const tables = @import("../value/tables.zig");
const gc_alloc = @import("../gc.zig");
const buffers = @import("../value/buffers.zig");
const tuples = @import("../value/tuples.zig");
const utils = @import("../utils.zig");
const gc_mark = @import("../gc/mark.zig");
const math = @import("../math.zig");
const fibers = @import("../value/fibers.zig");
const wrap = @import("../value/helpers/wrap.zig");
const args_core = @import("../args.zig");
const value = @import("../value.zig");
const abstracts = @import("../value/abstracts.zig");
const os_locks = @import("locks.zig");
const abi = @import("abi");
const host = @import("host");
const windows = ev.windows;

/// The most items a channel is meant to hold. Unused: the limit a channel
/// actually enforces is the argument layer's natural-number check, and this
/// documents the intent rather than being consulted.
const max_channel_capacity: i32 = 0xFFFFFF;

/// The marshalling flag a threaded channel sets to hand ownership across.
const marshalDecref: c_int = 0x40000;

/// The mode a blocked fiber is waiting in. The values travel between threads
/// inside a generic message's `tag`, so each is written out.
const Mode = enum(c_int) {
    read = 0,
    write = 1,
    choice_read = 2,
    choice_write = 3,
    close = 4,
};

/// Mirrors `JanetChannelPending` in `ev.c`.
const Pending = struct {
    thread: ?*vm_state.Vm,
    fiber: *fibers.Fiber,
    sched_id: u32,
    mode: Mode,
};

const Lock = if (windows) host.CRITICAL_SECTION else host.pthread_mutex_t;

/// Mirrors `struct JanetChannel` in `ev.c`.
pub const Channel = struct {
    items: ev.Queue(repr.Value),
    read_pending: ev.Queue(Pending),
    write_pending: ev.Queue(Pending),
    limit: i32,
    closed: bool,
    is_threaded: bool,
    lock: Lock,
};

pub inline fn unwrap(abstract: ?*anyopaque) *Channel {
    return @ptrCast(@alignCast(abstract));
}

pub fn channelUnwrap(abstract: ?*anyopaque) ?*Channel {
    return @ptrCast(abstract);
}

inline fn wrapChannel(chan: *Channel) repr.Value {
    return wrap.fromAbstract(chan);
}

// ==========================================================================
// Packing, locking, and lifetime
// ==========================================================================

inline fn isThreaded(chan: *Channel) bool {
    return chan.is_threaded;
}

/// Marshal a value that is about to cross an operating system thread.
///
/// Returns true on failure. The five types listed are self-contained words
/// and cross as they are; everything else becomes a buffer holding an unsafe
/// marshalling, which `unpack` reverses.
fn pack(chan: *Channel, x: *repr.Value) raise.Raising(bool) {
    if (!isThreaded(chan)) return false;
    switch (repr.typeOf(x.*)) {
        repr.Tag.nil, repr.Tag.number, repr.Tag.pointer, repr.Tag.boolean, repr.Tag.cfunction => return false,
        else => {
            const buf: *buffers.Buffer = @ptrCast(@alignCast(utils.malloc(@sizeOf(buffers.Buffer)) orelse
                ev.outOfMemory(@src())));
            // `marshal` raises on any value a threaded channel cannot carry --
            // an alive fiber, a file in safe mode, an unregistered cfunction --
            // and this buffer is not the collector's. `FOUND.md`.
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

fn unpack(chan: *Channel, x: *repr.Value, is_cleanup: bool) raise.Raising(bool) {
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

fn chanInit(chan: *Channel, limit: i32, threaded: bool) void {
    chan.limit = limit;
    chan.closed = false;
    chan.is_threaded = threaded;
    chan.items.init();
    chan.read_pending.init();
    chan.write_pending.init();
    os_locks.mutexInit(@ptrCast(&chan.lock));
}

fn lock(chan: *Channel) void {
    if (!isThreaded(chan)) return;
    os_locks.mutexLock(@ptrCast(&chan.lock));
}

/// The unlock half, which every caller reaches through a `defer`.
///
/// A `defer` cannot carry an error, and a mutex this thread holds and cannot
/// release leaves the channel unusable by anyone -- so the failure is fatal at
/// the site rather than a report for whatever opens the next scope.
fn unlock(chan: *Channel) void {
    if (!isThreaded(chan)) return;
    raise.total(os_locks.mutexUnlock(@ptrCast(&chan.lock)), "a channel's unlock");
}

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

// ==========================================================================
// The abstract type's callbacks
// ==========================================================================

fn chanatGC(chan: *Channel, _: usize) void {
    chanDeinit(chan);
}

/// Replace every reference to *this* thread's VM in a pending queue with
/// null, so that a channel outliving the thread does not name it.
fn removeVMRef(fq: *ev.Queue(Pending)) void {
    const me = vm_state.current();
    for (fq.segments()) |run| {
        for (run) |*pending| {
            if (pending.thread == me) pending.thread = null;
        }
    }
}

fn chanatGCPerThread(chan: *Channel, _: usize) void {
    lock(chan);
    defer unlock(chan);
    removeVMRef(&chan.read_pending);
    removeVMRef(&chan.write_pending);
}

fn markFQ(fq: *ev.Queue(Pending)) void {
    for (fq.segments()) |run| {
        for (run) |pending| gc_mark.mark(wrap.fromFiber(pending.fiber));
    }
}

fn chanatMark(chan: *Channel, _: usize) void {
    markFQ(&chan.read_pending);
    markFQ(&chan.write_pending);
    const items = &chan.items;
    const data: [*]repr.Value = @ptrCast(@alignCast(items.data orelse return));
    if (items.head <= items.tail) {
        var i = items.head;
        while (i < items.tail) : (i += 1) gc_mark.mark(data[@intCast(i)]);
    } else {
        var i = items.head;
        while (i < items.capacity) : (i += 1) gc_mark.mark(data[@intCast(i)]);
        i = 0;
        while (i < items.tail) : (i += 1) gc_mark.mark(data[@intCast(i)]);
    }
}

fn chanatGet(_: *Channel, key: repr.Value) raise.Raising(?repr.Value) {
    return args_core.findMethod(key, @ptrCast(&chanat_methods));
}

fn chanatNext(_: *Channel, key: repr.Value) raise.Raising(repr.Value) {
    return args_core.nextmethod(@ptrCast(&chanat_methods), key);
}

fn chanatMarshal(chan: *Channel, ctx: *abi.JanetMarshalContext) raise.Raising(void) {
    try marsh.marshalByte(ctx, @intFromBool(chan.is_threaded));
    marsh.marshalAbstract(ctx, chan);
    try marsh.marshalByte(ctx, @intFromBool(chan.closed));
    try marsh.marshalInt(ctx, chan.limit);
    try marsh.marshalInt(ctx, chan.items.count());
    const items = &chan.items;
    const data: [*]repr.Value = @ptrCast(@alignCast(items.data orelse return));
    if (items.head <= items.tail) {
        var i = items.head;
        while (i < items.tail) : (i += 1) try marsh.marshalJanet(ctx, data[@intCast(i)]);
    } else {
        var i = items.head;
        while (i < items.capacity) : (i += 1) try marsh.marshalJanet(ctx, data[@intCast(i)]);
        i = 0;
        while (i < items.tail) : (i += 1) try marsh.marshalJanet(ctx, data[@intCast(i)]);
    }
}

fn chanatUnmarshal(ctx: *abi.JanetMarshalContext) raise.Raising(*Channel) {
    const is_threaded = try marsh.unmarshalByte(ctx);
    const abst: *Channel = unwrap(if (is_threaded != 0)
        try marsh.unmarshalAbstractThreaded(ctx, @sizeOf(Channel))
    else
        try marsh.unmarshalAbstract(ctx, @sizeOf(Channel)));
    const is_closed = try marsh.unmarshalByte(ctx);
    const limit = try marsh.unmarshalInt(ctx);
    const count = try marsh.unmarshalInt(ctx);
    if (count < 0) return raise.panic("invalid negative channel count");
    if (count > limit) return raise.panic("invalid channel count");
    // The C original initialises the channel unthreaded whatever the byte it
    // just read said. Reproduced, not repaired; `FOUND.md` has the entry.
    chanInit(abst, limit, false);
    abst.closed = is_closed != 0;
    for (0..@as(usize, @intCast(count))) |_| {
        const item = try marsh.unmarshalJanet(ctx);
        ev.assert(@src(), abst.items.push(item) == 0, "bad unmarshal channel");
    }
    return abst;
}

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

// ==========================================================================
// The three result tuples, and the supervisor event
// ==========================================================================

fn makeWriteResult(chan: *Channel) repr.Value {
    const tup = tuples.begin(2);
    tup[0] = value.fromBytes("give", .keyword);
    tup[1] = wrapChannel(chan);
    return wrap.fromTuple(tuples.end(tup));
}

fn makeReadResult(chan: *Channel, x: repr.Value) repr.Value {
    const tup = tuples.begin(3);
    tup[0] = value.fromBytes("take", .keyword);
    tup[1] = wrapChannel(chan);
    tup[2] = x;
    return wrap.fromTuple(tuples.end(tup));
}

fn makeCloseResult(chan: *Channel) repr.Value {
    const tup = tuples.begin(2);
    tup[0] = value.fromBytes("close", .keyword);
    tup[1] = wrapChannel(chan);
    return wrap.fromTuple(tuples.end(tup));
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

// ==========================================================================
// Waking a fiber that is waiting on another thread's VM
// ==========================================================================

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

// ==========================================================================
// Push and pop
// ==========================================================================

/// Which caller is pushing, which decides what it does when it cannot.
pub const Caller = enum(c_int) {
    /// `ev/give`: register a pending write and block.
    plain = 0,
    /// One clause of an `ev/select`: register a pending *choice* write.
    choice = 1,
    /// A caller with no root fiber to suspend -- `janet_channel_give`, and the
    /// supervisor push the loop makes on a fiber's behalf. Registers nothing.
    detached = 2,
};

/// Push a value, reporting whether the caller should block.
///
/// **The caller holds the lock across this and releases it.** It used to
/// release the lock itself, on each of its own returns -- which the two
/// `raise` paths inside `pack` and `unpack` went straight past, leaving a
/// threaded channel locked against every other thread. `FOUND.md` has the
/// deadlock; a `defer` in each caller is the fix.
fn pushWithLock(chan: *Channel, x_in: repr.Value, mode: Caller) raise.Raising(bool) {
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

pub fn push(chan: *Channel, x: repr.Value, mode: Caller) raise.Raising(bool) {
    lock(chan);
    defer unlock(chan);
    return pushWithLock(chan, x, mode);
}

/// Pop a value, reporting whether one was obtained. `Caller.detached` here is
/// `channelTake`, which does not register a pending read.
///
/// **The caller holds the lock across this and releases it**, for the reason
/// `pushWithLock` gives -- and for one more of its own: the `.detached` arm
/// below returned without unlocking at all, which `FOUND.md` records as a
/// threaded channel left locked when it is empty.
fn popWithLock(chan: *Channel, item: *repr.Value, is_choice: Caller) raise.Raising(bool) {
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

pub fn pop(chan: *Channel, item: *repr.Value, is_choice: Caller) raise.Raising(bool) {
    lock(chan);
    defer unlock(chan);
    return popWithLock(chan, item, is_choice);
}

// ==========================================================================
// The public channel API
// ==========================================================================

pub fn getChannel(argv: []const repr.Value, n: usize) raise.Raising(?*Channel) {
    return try args_core.getAbstract(Channel, argv, n, &channelType);
}

/// `janet_optchannel`'s body, over the slice the boundary builds from the
/// count it was handed. The reporting half is `capi.zig`'s.
pub fn optChannel(
    argv: []const repr.Value,
    n: usize,
    dflt: ?*Channel,
) raise.Raising(?*Channel) {
    if (argv.len > n and !repr.checkType(argv[n], repr.Tag.nil)) {
        return getChannel(argv, n);
    }
    return dflt;
}

pub fn channelGive(chan: ?*Channel, x: repr.Value) raise.Raising(bool) {
    return push(unwrap(chan), x, .detached);
}

pub fn channelGiveAbi(chan: ?*Channel, x: repr.Value) c_int {
    return @intFromBool(raise.reported(channelGive(chan, x)));
}

pub fn channelTake(chan: ?*Channel, out: *repr.Value) raise.Raising(bool) {
    return pop(unwrap(chan), out, .detached);
}

pub fn channelMake(limit: u32) ?*Channel {
    ev.assert(@src(), limit <= std.math.maxInt(i32), "bad limit");
    const chan = unwrap(abstracts.newFor(Channel, &channelType));
    chanInit(chan, @intCast(limit), false);
    return @ptrCast(chan);
}

pub fn channelMakeThreaded(limit: u32) ?*Channel {
    ev.assert(@src(), limit <= std.math.maxInt(i32), "bad limit");
    const chan = unwrap(abstracts.threaded(&channelType, @sizeOf(Channel)));
    chanInit(chan, @intCast(limit), true);
    return @ptrCast(chan);
}

// ==========================================================================
// The cfunctions
// ==========================================================================

fn channelArg(argv: []const repr.Value, n: usize) raise.Raising(*Channel) {
    return try args_core.getAbstract(Channel, argv, n, &channelType);
}

fn cfunGive(argv: []repr.Value) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 2);
    const chan = try channelArg(argv, 0);
    if (vm_state.current().coerce_error) {
        return raise.panic("cannot give to channel inside janet_call");
    }
    if (try push(chan, argv[1], .plain)) return ev.awaitEvent();
    return argv[0];
}

fn cfunTake(argv: []repr.Value) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    const chan = try channelArg(argv, 0);
    var item: repr.Value = undefined;
    if (vm_state.current().coerce_error) {
        return raise.panic("cannot take from channel inside janet_call");
    }
    if (try pop(chan, &item, .plain)) ev.schedule(vm_state.current().root_fiber.?, item);
    return ev.awaitEvent();
}

fn cfunChoice(argv: []repr.Value) raise.Raising(repr.Value) {
    try args_core.arity(argv, 1, -1);

    if (vm_state.current().coerce_error) {
        return raise.panic("cannot select from channel inside janet_call");
    }

    // Check channels for immediate reads and writes.
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const data = args_core.indexedView(argv[i]);
        if (data != null and data.?.len == 2) {
            // Write.
            const chan = try channelArg(data.?, 0);
            lock(chan);
            defer unlock(chan);
            if (chan.closed) return makeCloseResult(chan);
            if (chan.items.count() < chan.limit) {
                _ = try pushWithLock(chan, data.?[1], .choice);
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
    i = 0;
    while (i < argv.len) : (i += 1) {
        const data = args_core.indexedView(argv[i]);
        if (data != null and data.?.len == 2) {
            const chan = try channelArg(data.?, 0);
            lock(chan);
            defer unlock(chan);
            _ = try pushWithLock(chan, data.?[1], .choice);
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

fn cfunFull(argv: []repr.Value) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    const chan = try channelArg(argv, 0);
    lock(chan);
    defer unlock(chan);
    return wrap.fromBoolean(chan.items.count() >= chan.limit);
}

fn cfunCapacity(argv: []repr.Value) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    const chan = try channelArg(argv, 0);
    lock(chan);
    defer unlock(chan);
    const ret = wrap.fromInteger(chan.limit);
    return ret;
}

fn cfunCount(argv: []repr.Value) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    const chan = try channelArg(argv, 0);
    lock(chan);
    defer unlock(chan);
    return wrap.fromInteger(chan.items.count());
}

/// Fisher-Yates shuffle of the arguments, so that `ev/rselect` is fair.
fn fisherYatesArgs(argv: []repr.Value) void {
    var i = @as(i32, @intCast(argv.len));
    while (i > 1) : (i -= 1) {
        const swap_index = math.rngU32(&vm_state.current().ev.ev_rng) % @as(u32, @intCast(i));
        const temp = argv[swap_index];
        argv[swap_index] = argv[@intCast(i - 1)];
        argv[@intCast(i - 1)] = temp;
    }
}

fn cfunRchoice(argv: []repr.Value) raise.Raising(repr.Value) {
    fisherYatesArgs(argv);
    return cfunChoice(argv);
}

fn cfunNew(argv: []repr.Value) raise.Raising(repr.Value) {
    try args_core.arity(argv, 0, 1);
    const limit = try args_core.optNat(argv, 0, 0);
    const chan = unwrap(abstracts.newFor(Channel, &channelType));
    chanInit(chan, limit, false);
    return wrap.fromAbstract(chan);
}

fn cfunNewThreaded(argv: []repr.Value) raise.Raising(repr.Value) {
    try args_core.arity(argv, 0, 1);
    const limit = try args_core.optNat(argv, 0, 0);
    const chan = unwrap(abstracts.threaded(&channelType, @sizeOf(Channel)));
    chanInit(chan, limit, true);
    return wrap.fromAbstract(chan);
}

fn cfunClose(argv: []repr.Value) raise.Raising(repr.Value) {
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

/// The first ten rows of `janet_lib_ev`, in its order.
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
