//! `core/channel`: the queue of values, the two queues of blocked fibers, the
//! lock that makes a threaded channel safe, and the ten `ev/` cfunctions over
//! them. Part of the `-Dev-loop` object; `ev_loop.zig` has the reasoning for
//! why the four files are one module.
//!
//! `JanetChannel` is opaque in `janet.h` and defined in `ev.c`, so this file
//! owns the layout. Its last member is a `pthread_mutex_t` or a
//! `CRITICAL_SECTION` -- `types.zig`'s in both arms, which is where every
//! shared type in this tree comes from since Phase 12 increment 5f, so this
//! file needs no `@cImport` of its own the way `os/abi.h` did.
//!
//! The public entry points take `*types.JanetChannel`, which is opaque;
//! `unwrap` is the one cast, and it is the same cast `janet_channel_unwrap`
//! has always been.

const std = @import("std");
const corefn = @import("corefn");
const raise = @import("raise");
const pp_format = @import("../pp/format.zig");
const ev = @import("../ev.zig");
const ev_core = @import("../ev.zig");

const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");
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
const kind = @import("../value/helpers/kind.zig");
const wrap = @import("../value/helpers/wrap.zig");
const args_core = @import("../args.zig");
const value = @import("../value.zig");
const abstracts = @import("../value/abstracts.zig");
const os_locks = @import("locks.zig");
const windows = ev.windows;

/// `JANET_MAX_CHANNEL_CAPACITY` in `ev.c`. Declared and unused there too: the
/// limit a channel enforces is `janet_optnat`'s, and this constant documents
/// the intent rather than being consulted.
const max_channel_capacity: i32 = 0xFFFFFF;

/// `JANET_MARSHAL_DECREF` in `src/core/util.h`, which no translation ever
/// carried. It is a plain integer, so restating it here risks no layout.
const janet_marshal_decref: c_int = 0x40000;

/// The mode a blocked fiber is waiting in. An unnamed C enum, so its values
/// are its declaration order.
const mode_read: c_int = 0;
const mode_write: c_int = 1;
const mode_choice_read: c_int = 2;
const mode_choice_write: c_int = 3;
const mode_close: c_int = 4;

/// Mirrors `JanetChannelPending` in `ev.c`.
const Pending = extern struct {
    thread: ?*types.JanetVM,
    fiber: *types.JanetFiber,
    sched_id: u32,
    mode: c_int,
};

const Lock = if (windows) types.CRITICAL_SECTION else types.pthread_mutex_t;

/// Mirrors `struct JanetChannel` in `ev.c`.
pub const Channel = extern struct {
    items: types.JanetQueue,
    read_pending: types.JanetQueue,
    write_pending: types.JanetQueue,
    limit: i32,
    closed: c_int,
    is_threaded: c_int,
    lock: Lock,
};

pub inline fn unwrap(abstract: ?*anyopaque) *Channel {
    return @ptrCast(@alignCast(abstract));
}

pub fn channelUnwrap(abstract: ?*anyopaque) ?*types.JanetChannel {
    return @ptrCast(abstract);
}

inline fn wrapChannel(chan: *Channel) types.Janet {
    return wrap.fromAbstract(chan);
}

// ==========================================================================
// Packing, locking, and lifetime
// ==========================================================================

inline fn isThreaded(chan: *Channel) bool {
    return chan.is_threaded != 0;
}

/// Marshal a value that is about to cross an operating system thread.
///
/// Returns true on failure. The five types listed are self-contained words
/// and cross as they are; everything else becomes a buffer holding an unsafe
/// marshalling, which `unpack` reverses.
fn pack(chan: *Channel, x: *types.Janet) raise.Raising(bool) {
    if (!isThreaded(chan)) return false;
    switch (kind.typeOf(x.*)) {
        constants.JANET_NIL, constants.JANET_NUMBER, constants.JANET_POINTER, constants.JANET_BOOLEAN, constants.JANET_CFUNCTION => return false,
        else => {
            const buf: *types.JanetBuffer = @ptrCast(@alignCast(utils.malloc(@sizeOf(types.JanetBuffer)) orelse
                ev.outOfMemory(@src())));
            _ = buffers.init(buf, 10);
            try marsh.marshal(buf, x.*, null, constants.JANET_MARSHAL_UNSAFE);
            x.* = wrap.fromBuffer(buf);
            return false;
        },
    }
}

fn unpack(chan: *Channel, x: *types.Janet, is_cleanup: bool) raise.Raising(bool) {
    if (!isThreaded(chan)) return false;
    switch (kind.typeOf(x.*)) {
        constants.JANET_NIL, constants.JANET_NUMBER, constants.JANET_POINTER, constants.JANET_BOOLEAN, constants.JANET_CFUNCTION => return false,
        constants.JANET_BUFFER => {
            const buf = wrap.toBuffer(x.*);
            const flags: c_int = if (is_cleanup)
                constants.JANET_MARSHAL_UNSAFE | janet_marshal_decref
            else
                constants.JANET_MARSHAL_UNSAFE;
            x.* = try marsh.unmarshal(buf.*.data.?[0..@intCast(buf.*.count)], flags, null, null);
            buffers.deinit(buf);
            utils.free(buf);
            return false;
        },
        else => return true,
    }
}

fn chanInit(chan: *Channel, limit: i32, threaded: bool) void {
    chan.limit = limit;
    chan.closed = 0;
    chan.is_threaded = @intFromBool(threaded);
    ev_core.qInit(&chan.items);
    ev_core.qInit(&chan.read_pending);
    ev_core.qInit(&chan.write_pending);
    os_locks.mutexInit(@ptrCast(&chan.lock));
}

fn lock(chan: *Channel) void {
    if (!isThreaded(chan)) return;
    os_locks.mutexLock(@ptrCast(&chan.lock));
}

fn unlock(chan: *Channel) void {
    if (!isThreaded(chan)) return;
    raise.reported(os_locks.mutexUnlock(@ptrCast(&chan.lock)));
}

fn chanDeinit(chan: *Channel) void {
    if (isThreaded(chan)) {
        var item: types.Janet = undefined;
        lock(chan);
        ev_core.qDeinit(&chan.read_pending);
        ev_core.qDeinit(&chan.write_pending);
        while (ev_core.qPop(&chan.items, &item, @sizeOf(types.Janet)) == 0) {
            // Draining a threaded channel's items as it is torn down. The
            // channel is already unlinked and its queues are being freed
            // around this loop, so there is no scope above it and nothing
            // that could act on a raise if there were.
            _ = raise.total(unpack(chan, &item, true), "a channel's teardown");
        }
        ev_core.qDeinit(&chan.items);
        unlock(chan);
    } else {
        ev_core.qDeinit(&chan.read_pending);
        ev_core.qDeinit(&chan.write_pending);
        ev_core.qDeinit(&chan.items);
    }
    os_locks.mutexDeinit(@ptrCast(&chan.lock));
}

// ==========================================================================
// The abstract type's callbacks
// ==========================================================================

fn chanatGC(p: ?*anyopaque, s: usize) callconv(.c) c_int {
    _ = s;
    chanDeinit(unwrap(p));
    return 0;
}

/// Replace every reference to *this* thread's VM in a pending queue with
/// null, so that a channel outliving the thread does not name it.
fn removeVMRef(fq: *types.JanetQueue) void {
    const pending: [*]Pending = @ptrCast(@alignCast(fq.data orelse return));
    const me = c.vm();
    if (fq.head <= fq.tail) {
        var i = fq.head;
        while (i < fq.tail) : (i += 1) {
            if (pending[@intCast(i)].thread == me) pending[@intCast(i)].thread = null;
        }
    } else {
        var i = fq.head;
        while (i < fq.capacity) : (i += 1) {
            if (pending[@intCast(i)].thread == me) pending[@intCast(i)].thread = null;
        }
        i = 0;
        while (i < fq.tail) : (i += 1) {
            if (pending[@intCast(i)].thread == me) pending[@intCast(i)].thread = null;
        }
    }
}

fn chanatGCPerThread(p: ?*anyopaque, s: usize) callconv(.c) c_int {
    _ = s;
    const chan = unwrap(p);
    lock(chan);
    removeVMRef(&chan.read_pending);
    removeVMRef(&chan.write_pending);
    unlock(chan);
    return 0;
}

fn markFQ(fq: *types.JanetQueue) void {
    const pending: [*]Pending = @ptrCast(@alignCast(fq.data orelse return));
    if (fq.head <= fq.tail) {
        var i = fq.head;
        while (i < fq.tail) : (i += 1) gc_mark.mark(wrap.fromFiber(pending[@intCast(i)].fiber));
    } else {
        var i = fq.head;
        while (i < fq.capacity) : (i += 1) gc_mark.mark(wrap.fromFiber(pending[@intCast(i)].fiber));
        i = 0;
        while (i < fq.tail) : (i += 1) gc_mark.mark(wrap.fromFiber(pending[@intCast(i)].fiber));
    }
}

fn chanatMark(p: ?*anyopaque, s: usize) callconv(.c) c_int {
    _ = s;
    const chan = unwrap(p);
    markFQ(&chan.read_pending);
    markFQ(&chan.write_pending);
    const items = &chan.items;
    const data: [*]types.Janet = @ptrCast(@alignCast(items.data orelse return 0));
    if (items.head <= items.tail) {
        var i = items.head;
        while (i < items.tail) : (i += 1) gc_mark.mark(data[@intCast(i)]);
    } else {
        var i = items.head;
        while (i < items.capacity) : (i += 1) gc_mark.mark(data[@intCast(i)]);
        i = 0;
        while (i < items.tail) : (i += 1) gc_mark.mark(data[@intCast(i)]);
    }
    return 0;
}

fn chanatGet(p: ?*anyopaque, key: types.Janet, out: *types.Janet) raise.Raising(c_int) {
    _ = p;
    if (kind.checkType(key, constants.JANET_KEYWORD) == 0) return 0;
    return args_core.getmethod(wrap.toKeyword(key), @ptrCast(&chanat_methods), out);
}

fn chanatNext(p: ?*anyopaque, key: types.Janet) raise.Raising(types.Janet) {
    _ = p;
    return args_core.nextmethod(@ptrCast(&chanat_methods), key);
}

fn chanatMarshal(p: ?*anyopaque, ctx: *types.JanetMarshalContext) raise.Raising(void) {
    const chan = unwrap(p);
    try marsh.marshalByte(ctx, @intCast(chan.is_threaded));
    marsh.marshalAbstract(ctx, chan);
    try marsh.marshalByte(ctx, @intCast(chan.closed));
    try marsh.marshalInt(ctx, chan.limit);
    try marsh.marshalInt(ctx, ev_core.qCount(&chan.items));
    const items = &chan.items;
    const data: [*]types.Janet = @ptrCast(@alignCast(items.data orelse return));
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

fn chanatUnmarshal(ctx: *types.JanetMarshalContext) raise.Raising(?*anyopaque) {
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
    abst.closed = @intFromBool(is_closed != 0);
    var i: i32 = 0;
    while (i < count) : (i += 1) {
        var item = try marsh.unmarshalJanet(ctx);
        ev.assert(@src(), ev_core.qPush(&abst.items, &item, @sizeOf(types.Janet)) == 0, "bad unmarshal channel");
    }
    return abst;
}

/// `pub` for `ev_loop.zig`, which declared it `extern const` while already
/// importing this file, and for `test/ev_loop.zig`. The `export` stays --
/// `janet.h` declares it.
pub const channelType: abstract_type.AbstractType = .{
    .name = "core/channel",
    .gc = chanatGC,
    .gcmark = chanatMark,
    .get = chanatGet,
    .put = null,
    .marshal = chanatMarshal,
    .unmarshal = chanatUnmarshal,
    .tostring = null,
    .compare = null,
    .hash = null,
    .next = chanatNext,
    .call = null,
    .length = null,
    .bytes = null,
    .gcperthread = chanatGCPerThread,
};

// ==========================================================================
// The three result tuples, and the supervisor event
// ==========================================================================

fn makeWriteResult(chan: *Channel) types.Janet {
    const tup = tuples.begin(2);
    tup[0] = value.fromBytes("give", .keyword);
    tup[1] = wrapChannel(chan);
    return wrap.fromTuple(tuples.end(tup));
}

fn makeReadResult(chan: *Channel, x: types.Janet) types.Janet {
    const tup = tuples.begin(3);
    tup[0] = value.fromBytes("take", .keyword);
    tup[1] = wrapChannel(chan);
    tup[2] = x;
    return wrap.fromTuple(tuples.end(tup));
}

fn makeCloseResult(chan: *Channel) types.Janet {
    const tup = tuples.begin(2);
    tup[0] = value.fromBytes("close", .keyword);
    tup[1] = wrapChannel(chan);
    return wrap.fromTuple(tuples.end(tup));
}

/// The `[tag fiber-or-value task-id]` tuple a supervisor channel receives.
pub fn makeSupervisorEvent(name: [*:0]const u8, fiber: *types.JanetFiber, threaded: bool) types.Janet {
    var tup: [3]types.Janet = undefined;
    tup[0] = value.fromBytes(std.mem.span(name), .keyword);
    tup[1] = if (threaded) fiber.*.last_value else wrap.fromFiber(fiber);
    tup[2] = if (fiber.*.env) |env|
        tables.get(env, value.fromBytes("task-id", .keyword))
    else
        wrap.fromNil();
    return wrap.fromTuple(tuples.newFrom(&tup, 3));
}

// ==========================================================================
// Waking a fiber that is waiting on another thread's VM
// ==========================================================================

fn threadChanCallback(msg: types.JanetEVGenericMessage) callconv(.c) void {
    const sched_id: u32 = @bitCast(msg.argi);
    const fiber = msg.fiber.?;
    const mode = msg.tag;
    const chan = unwrap(msg.argp);
    var x = msg.argj;
    lock(chan);
    if (fiber.sched_id == sched_id) {
        if (mode == mode_choice_read) {
            ev.assert(@src(), !raise.total(unpack(chan, &x, false), "a threaded channel's wakeup"), "packing error");
            ev.schedule(fiber, makeReadResult(chan, x));
        } else if (mode == mode_choice_write) {
            ev.schedule(fiber, makeWriteResult(chan));
        } else if (mode == mode_read) {
            ev.assert(@src(), !raise.total(unpack(chan, &x, false), "a threaded channel's wakeup"), "packing error");
            ev.schedule(fiber, x);
        } else if (mode == mode_write) {
            ev.schedule(fiber, wrapChannel(chan));
        } else { // mode == mode_close
            ev.schedule(fiber, wrap.fromNil());
        }
    } else if (mode != mode_close) {
        // The fiber has already been canceled or resumed, so resend the event
        // to another waiting thread.
        const is_read = (mode == mode_choice_read) or (mode == mode_read);
        if (is_read) {
            var reader: Pending = undefined;
            var sent = false;
            while (ev_core.qPop(&chan.read_pending, &reader, @sizeOf(Pending)) == 0) {
                const target = reader.thread orelse continue;
                ev.evPostEvent(target, threadChanCallback, .{
                    .tag = reader.mode,
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
            while (ev_core.qPop(&chan.write_pending, &writer, @sizeOf(Pending)) == 0) {
                const target = writer.thread orelse continue;
                ev.evPostEvent(target, threadChanCallback, .{
                    .tag = writer.mode,
                    .fiber = writer.fiber,
                    .argi = @bitCast(writer.sched_id),
                    .argp = chan,
                    .argj = wrap.fromNil(),
                });
                break;
            }
        }
    }
    unlock(chan);
}

// ==========================================================================
// Push and pop
// ==========================================================================

/// Push a value, reporting whether the caller should block.
///
/// `mode` is 0 for `ev/give`, 1 for a `ev/select` clause, and 2 for a caller
/// that has no root fiber to suspend -- `janet_channel_give`, and the
/// supervisor push the loop makes on a fiber's behalf.
fn pushWithLock(chan: *Channel, x_in: types.Janet, mode: c_int) raise.Raising(bool) {
    var x = x_in;
    var reader: Pending = undefined;
    if (chan.closed != 0) {
        unlock(chan);
        return raise.panic("cannot write to closed channel");
    }
    if (try pack(chan, &x)) {
        unlock(chan);
        return pp_format.panicf("failed to pack value for channel: %v", .{x});
    }
    const is_threaded = isThreaded(chan);
    var is_empty: c_int = undefined;
    if (is_threaded) {
        // Don't dereference a fiber owned by another thread.
        is_empty = ev_core.qPop(&chan.read_pending, &reader, @sizeOf(Pending));
    } else {
        while (true) {
            is_empty = ev_core.qPop(&chan.read_pending, &reader, @sizeOf(Pending));
            if (is_empty != 0 or reader.sched_id == reader.fiber.*.sched_id) break;
        }
    }
    if (is_empty != 0) {
        // No pending reader.
        if (ev_core.qPush(&chan.items, &x, @sizeOf(types.Janet)) != 0) {
            _ = try unpack(chan, &x, true);
            unlock(chan);
            return pp_format.panicf("channel overflow: %v", .{x});
        } else if (ev_core.qCount(&chan.items) > chan.limit) {
            // No root fiber, we are in completion on a root fiber. Don't block.
            if (mode == 2) {
                unlock(chan);
                return true;
            }
            // Pushed successfully, but should block.
            const pending: Pending = .{
                .thread = c.vm(),
                .fiber = c.vm().root_fiber.?,
                .sched_id = c.vm().root_fiber.?.sched_id,
                .mode = if (mode != 0) mode_choice_write else mode_write,
            };
            _ = ev_core.qPush(&chan.write_pending, &pending, @sizeOf(Pending));
            unlock(chan);
            if (is_threaded) gc_alloc.gcroot(wrap.fromFiber(pending.fiber));
            return true;
        }
    } else {
        // Pending reader.
        if (is_threaded) {
            if (reader.thread) |target| {
                ev.evPostEvent(target, threadChanCallback, .{
                    .tag = reader.mode,
                    .fiber = reader.fiber,
                    .argi = @bitCast(reader.sched_id),
                    .argp = chan,
                    .argj = x,
                });
            } else {
                // No vm to send to, so unpack the payload to avoid a leak.
                _ = try unpack(chan, &x, true);
            }
        } else if (reader.mode == mode_choice_read) {
            ev.schedule(reader.fiber, makeReadResult(chan, x));
        } else {
            ev.schedule(reader.fiber, x);
        }
    }
    unlock(chan);
    return false;
}

pub fn push(chan: *Channel, x: types.Janet, mode: c_int) raise.Raising(bool) {
    lock(chan);
    return pushWithLock(chan, x, mode);
}

/// Pop a value, reporting whether one was obtained.
///
/// `is_choice` is 0 for `ev/take`, 1 for a `ev/select` clause, and 2 for
/// `janet_channel_take`, which does not register a pending read.
fn popWithLock(chan: *Channel, item: *types.Janet, is_choice: c_int) raise.Raising(bool) {
    var writer: Pending = undefined;
    if (chan.closed != 0) {
        unlock(chan);
        item.* = wrap.fromNil();
        return true;
    }
    const is_threaded = isThreaded(chan);
    if (ev_core.qPop(&chan.items, item, @sizeOf(types.Janet)) != 0) {
        // Queue empty.
        if (is_choice == 2) return false; // Skip pending read.
        const pending: Pending = .{
            .thread = c.vm(),
            .fiber = c.vm().root_fiber.?,
            .sched_id = c.vm().root_fiber.?.sched_id,
            .mode = if (is_choice != 0) mode_choice_read else mode_read,
        };
        _ = ev_core.qPush(&chan.read_pending, &pending, @sizeOf(Pending));
        unlock(chan);
        if (is_threaded) gc_alloc.gcroot(wrap.fromFiber(pending.fiber));
        return false;
    }
    ev.assert(@src(), !(try unpack(chan, item, false)), "bad channel packing");
    if (ev_core.qPop(&chan.write_pending, &writer, @sizeOf(Pending)) == 0) {
        // Pending writer.
        if (is_threaded) {
            if (writer.thread) |target| {
                ev.evPostEvent(target, threadChanCallback, .{
                    .tag = writer.mode,
                    .fiber = writer.fiber,
                    .argi = @bitCast(writer.sched_id),
                    .argp = chan,
                    .argj = wrap.fromNil(),
                });
            }
        } else if (writer.mode == mode_choice_write) {
            ev.schedule(writer.fiber, makeWriteResult(chan));
        } else {
            ev.schedule(writer.fiber, wrap.fromAbstract(chan));
        }
    }
    unlock(chan);
    return true;
}

pub fn pop(chan: *Channel, item: *types.Janet, is_choice: c_int) raise.Raising(bool) {
    lock(chan);
    return popWithLock(chan, item, is_choice);
}

// ==========================================================================
// The public channel API
// ==========================================================================

pub fn getChannel(argv: []const types.Janet, n: i32) raise.Raising(?*types.JanetChannel) {
    return @ptrCast(try args_core.getAbstract(argv, n, abstract_type.stored(&channelType)));
}

pub fn getchannel(argv: [*]const types.Janet, n: i32) ?*types.JanetChannel {
    return raise.reported(getChannel(argv[0..@intCast(n + 1)], n));
}

pub fn optchannel(
    argv: [*]const types.Janet,
    argc: i32,
    n: i32,
    dflt: ?*types.JanetChannel,
) callconv(.c) ?*types.JanetChannel {
    if (argc > n and kind.checkType(argv[@intCast(n)], constants.JANET_NIL) == 0) {
        return raise.reported(getChannel(argv[0..@intCast(n + 1)], n));
    }
    return dflt;
}

pub fn channelGive(chan: ?*types.JanetChannel, x: types.Janet) raise.Raising(bool) {
    return push(unwrap(chan), x, 2);
}

pub fn janet_channel_give(chan: ?*types.JanetChannel, x: types.Janet) c_int {
    return @intFromBool(raise.reported(channelGive(chan, x)));
}

pub fn channelTake(chan: ?*types.JanetChannel, out: *types.Janet) raise.Raising(bool) {
    return pop(unwrap(chan), out, 2);
}

pub fn janet_channel_take(chan: ?*types.JanetChannel, out: *types.Janet) c_int {
    return @intFromBool(raise.reported(channelTake(chan, out)));
}

pub fn channelMake(limit: u32) ?*types.JanetChannel {
    ev.assert(@src(), limit <= std.math.maxInt(i32), "bad limit");
    const chan = unwrap(abstracts.new(abstract_type.stored(&channelType), @sizeOf(Channel)));
    chanInit(chan, @intCast(limit), false);
    return @ptrCast(chan);
}

pub fn channelMakeThreaded(limit: u32) ?*types.JanetChannel {
    ev.assert(@src(), limit <= std.math.maxInt(i32), "bad limit");
    const chan = unwrap(abstracts.threaded(abstract_type.stored(&channelType), @sizeOf(Channel)));
    chanInit(chan, @intCast(limit), true);
    return @ptrCast(chan);
}

// ==========================================================================
// The cfunctions
// ==========================================================================

fn channelArg(argv: []const types.Janet, n: i32) raise.Raising(*Channel) {
    return unwrap(try args_core.getAbstract(argv, n, abstract_type.stored(&channelType)));
}

fn giveImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 2);
    const chan = try channelArg(argv, 0);
    if (c.vm().coerce_error != 0) {
        return raise.panic("cannot give to channel inside janet_call");
    }
    if (try push(chan, argv[1], 0)) return ev.awaitEvent();
    return argv[0];
}

fn takeImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 1);
    const chan = try channelArg(argv, 0);
    var item: types.Janet = undefined;
    if (c.vm().coerce_error != 0) {
        return raise.panic("cannot take from channel inside janet_call");
    }
    if (try pop(chan, &item, 0)) ev.schedule(c.vm().root_fiber.?, item);
    return ev.awaitEvent();
}

fn choiceImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.arity(argv, 1, -1);
    var len: i32 = undefined;
    var data: ?[*]const types.Janet = undefined;

    if (c.vm().coerce_error != 0) {
        return raise.panic("cannot select from channel inside janet_call");
    }

    // Check channels for immediate reads and writes.
    var i: i32 = 0;
    while (i < @as(i32, @intCast(argv.len))) : (i += 1) {
        if (args_core.indexedView(argv[@intCast(i)], &data, &len) != 0 and len == 2) {
            // Write.
            const chan = try channelArg(data.?[0..@intCast(len)], 0);
            lock(chan);
            if (chan.closed != 0) {
                unlock(chan);
                return makeCloseResult(chan);
            }
            if (ev_core.qCount(&chan.items) < chan.limit) {
                _ = try pushWithLock(chan, data.?[1], 1);
                return makeWriteResult(chan);
            }
            unlock(chan);
        } else {
            // Read.
            const chan = try channelArg(argv, i);
            lock(chan);
            if (chan.closed != 0) {
                unlock(chan);
                return makeCloseResult(chan);
            }
            if (chan.items.head != chan.items.tail) {
                var item: types.Janet = undefined;
                _ = try popWithLock(chan, &item, 1);
                return makeReadResult(chan, item);
            }
            unlock(chan);
        }
    }

    // Wait for all readers or writers.
    i = 0;
    while (i < @as(i32, @intCast(argv.len))) : (i += 1) {
        if (args_core.indexedView(argv[@intCast(i)], &data, &len) != 0 and len == 2) {
            const chan = try channelArg(data.?[0..@intCast(len)], 0);
            lock(chan);
            _ = try pushWithLock(chan, data.?[1], 1);
        } else {
            var item: types.Janet = undefined;
            const chan = try channelArg(argv, i);
            lock(chan);
            _ = try popWithLock(chan, &item, 1);
        }
    }

    return ev.awaitEvent();
}

fn fullImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 1);
    const chan = try channelArg(argv, 0);
    lock(chan);
    const ret = wrap.fromBoolean(@intFromBool(ev_core.qCount(&chan.items) >= chan.limit));
    unlock(chan);
    return ret;
}

fn capacityImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 1);
    const chan = try channelArg(argv, 0);
    lock(chan);
    const ret = ev.wrapInteger(chan.limit);
    unlock(chan);
    return ret;
}

fn countImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 1);
    const chan = try channelArg(argv, 0);
    lock(chan);
    const ret = ev.wrapInteger(ev_core.qCount(&chan.items));
    unlock(chan);
    return ret;
}

/// Fisher-Yates shuffle of the arguments, so that `ev/rselect` is fair.
fn fisherYatesArgs(argv: []types.Janet) void {
    var i = @as(i32, @intCast(argv.len));
    while (i > 1) : (i -= 1) {
        const swap_index = math.rngU32(&c.vm().ev_rng) % @as(u32, @intCast(i));
        const temp = argv[swap_index];
        argv[swap_index] = argv[@intCast(i - 1)];
        argv[@intCast(i - 1)] = temp;
    }
}

fn rchoiceImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    fisherYatesArgs(argv);
    return choiceImpl(argv);
}

fn newImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.arity(argv, 0, 1);
    const limit = try args_core.optNat(argv, 0, 0);
    const chan = unwrap(abstracts.new(abstract_type.stored(&channelType), @sizeOf(Channel)));
    chanInit(chan, limit, false);
    return wrap.fromAbstract(chan);
}

fn newThreadedImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.arity(argv, 0, 1);
    const limit = try args_core.optNat(argv, 0, 0);
    const chan = unwrap(abstracts.threaded(abstract_type.stored(&channelType), @sizeOf(Channel)));
    chanInit(chan, limit, true);
    return wrap.fromAbstract(chan);
}

fn closeImpl(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 1);
    const chan = try channelArg(argv, 0);
    lock(chan);
    if (chan.closed == 0) {
        chan.closed = 1;
        var writer: Pending = undefined;
        while (ev_core.qPop(&chan.write_pending, &writer, @sizeOf(Pending)) == 0) {
            if (writer.thread != c.vm()) {
                if (writer.thread) |target| {
                    ev.evPostEvent(target, threadChanCallback, .{
                        .fiber = writer.fiber,
                        .argp = chan,
                        .tag = mode_close,
                        .argi = @bitCast(writer.sched_id),
                        .argj = wrap.fromNil(),
                    });
                }
            } else if (fibers.canResume(writer.fiber) != 0 and
                writer.sched_id == writer.fiber.*.sched_id)
            {
                if (writer.mode == mode_choice_write) {
                    ev.schedule(writer.fiber, makeCloseResult(chan));
                } else {
                    ev.schedule(writer.fiber, wrap.fromNil());
                }
            }
        }
        var reader: Pending = undefined;
        while (ev_core.qPop(&chan.read_pending, &reader, @sizeOf(Pending)) == 0) {
            if (reader.thread != c.vm()) {
                if (reader.thread) |target| {
                    ev.evPostEvent(target, threadChanCallback, .{
                        .fiber = reader.fiber,
                        .argp = chan,
                        .tag = mode_close,
                        .argi = @bitCast(reader.sched_id),
                        .argj = wrap.fromNil(),
                    });
                }
            } else if (fibers.canResume(reader.fiber) != 0 and
                reader.sched_id == reader.fiber.*.sched_id)
            {
                if (reader.mode == mode_choice_read) {
                    ev.schedule(reader.fiber, makeCloseResult(chan));
                } else {
                    ev.schedule(reader.fiber, wrap.fromNil());
                }
            }
        }
    }
    unlock(chan);
    return argv[0];
}

const chanat_methods = [_]method_type.Method{
    .{ .name = "select", .cfun = &choiceImpl },
    .{ .name = "rselect", .cfun = &rchoiceImpl },
    .{ .name = "count", .cfun = &countImpl },
    .{ .name = "take", .cfun = &takeImpl },
    .{ .name = "give", .cfun = &giveImpl },
    .{ .name = "capacity", .cfun = &capacityImpl },
    .{ .name = "full", .cfun = &fullImpl },
    .{ .name = "close", .cfun = &closeImpl },
    .{ .name = null, .cfun = null },
};

/// The first ten rows of `janet_lib_ev`, in its order.
pub fn entries() []const corefn.Entry {
    const list = comptime blk: {
        var acc: []const corefn.Entry = &.{};
        acc = acc ++ [_]corefn.Entry{
            corefn.reg("ev/give", &giveImpl, @src(), "(ev/give channel value)", "Write a value to a channel, suspending the current fiber if the channel is full. " ++
                "Returns the channel if the write succeeded, nil otherwise."),
            corefn.reg("ev/take", &takeImpl, @src(), "(ev/take channel)", "Read from a channel, suspending the current fiber if no value is available."),
            corefn.reg("ev/full", &fullImpl, @src(), "(ev/full channel)", "Check if a channel is full or not."),
            corefn.reg("ev/capacity", &capacityImpl, @src(), "(ev/capacity channel)", "Get the number of items a channel will store before blocking writers."),
            corefn.reg("ev/count", &countImpl, @src(), "(ev/count channel)", "Get the number of items currently waiting in a channel."),
            corefn.reg("ev/select", &choiceImpl, @src(), "(ev/select & clauses)", "Block until the first of several channel operations occur. Returns a " ++
                "tuple of the form [:give chan], [:take chan x], or [:close chan], " ++
                "where a :give tuple is the result of a write and a :take tuple is the " ++
                "result of a read. Each clause must be either a channel (for a channel " ++
                "take operation) or a tuple [channel x] (for a channel give operation). " ++
                "Operations are tried in order such that earlier clauses take " ++
                "precedence over later clauses. Both give and take operations can " ++
                "return a [:close chan] tuple, which indicates that the specified " ++
                "channel was closed while waiting, or that the channel was already " ++
                "closed."),
            corefn.reg("ev/rselect", &rchoiceImpl, @src(), "(ev/rselect & clauses)", "Similar to ev/select, but will try clauses in a random order for fairness."),
            corefn.reg("ev/chan", &newImpl, @src(), "(ev/chan &opt capacity)", "Create a new channel. capacity is the number of values to queue before " ++
                "blocking writers, defaults to 0 if not provided. Returns a new channel."),
            corefn.reg("ev/thread-chan", &newThreadedImpl, @src(), "(ev/thread-chan &opt limit)", "Create a threaded channel. A threaded channel is a channel that can be shared between threads and " ++
                "used to communicate between any number of operating system threads."),
            corefn.reg("ev/chan-close", &closeImpl, @src(), "(ev/chan-close chan)", "Close a channel. A closed channel will cause all pending reads and writes to return nil. " ++
                "Returns the channel."),
        };
        break :blk acc;
    };
    return list;
}
