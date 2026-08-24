//! `core/channel`: the queue of values, the two queues of blocked fibers, the
//! lock that makes a threaded channel safe, and the ten `ev/` cfunctions over
//! them. Part of the `-Dev-loop` object; `ev_loop.zig` has the reasoning for
//! why the four files are one module.
//!
//! `JanetChannel` is opaque in `janet.h` and defined in `ev.c`, so this file
//! owns the layout. Its last member is a `pthread_mutex_t` or a
//! `CRITICAL_SECTION` -- reached through `abi.zig`, because `state.h` already
//! includes the header that declares it under `JANET_EV`, which is what keeps
//! this inside the single-translation rule rather than needing a second
//! `@cImport` the way `os_abi.h` did.
//!
//! The public entry points take `*c.JanetChannel`, which translate-c renders
//! as an opaque pointer; `unwrap` is the one cast, and it is the same cast
//! `janet_channel_unwrap` has always been.

const std = @import("std");
const abi = @import("abi");
const corefn = @import("corefn");
const raise = @import("raise");
const pp_format = @import("pp_format.zig");
const ev = @import("ev_loop.zig");
const ev_core = @import("ev_core.zig");

const c = abi.c;
const marshalling = @import("marshalling.zig");
const arglayer = @import("arglayer.zig");
const marsh = @import("marsh.zig");
const abstract_type = @import("abstract_type.zig");
const windows = ev.windows;

/// `JANET_MAX_CHANNEL_CAPACITY` in `ev.c`. Declared and unused there too: the
/// limit a channel enforces is `janet_optnat`'s, and this constant documents
/// the intent rather than being consulted.
const max_channel_capacity: i32 = 0xFFFFFF;

/// `JANET_MARSHAL_DECREF` in `src/core/util.h`, which `abi.zig` deliberately
/// does not translate. It is a plain integer, so restating it here risks no
/// layout; see `abi.zig` for why that header stays out of the translation.
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
    thread: ?*c.JanetVM,
    fiber: [*c]c.JanetFiber,
    sched_id: u32,
    mode: c_int,
};

const Lock = if (windows) c.CRITICAL_SECTION else c.pthread_mutex_t;

/// Mirrors `struct JanetChannel` in `ev.c`.
pub const Channel = extern struct {
    items: c.JanetQueue,
    read_pending: c.JanetQueue,
    write_pending: c.JanetQueue,
    limit: i32,
    closed: c_int,
    is_threaded: c_int,
    lock: Lock,
};

pub inline fn unwrap(abstract: ?*anyopaque) *Channel {
    return @ptrCast(@alignCast(abstract));
}

export fn janet_channel_unwrap(abstract: ?*anyopaque) callconv(.c) ?*c.JanetChannel {
    return @ptrCast(abstract);
}

inline fn wrapChannel(chan: *Channel) c.Janet {
    return c.janet_wrap_abstract(chan);
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
fn pack(chan: *Channel, x: *c.Janet) raise.Raising(bool) {
    if (!isThreaded(chan)) return false;
    switch (c.janet_type(x.*)) {
        c.JANET_NIL, c.JANET_NUMBER, c.JANET_POINTER, c.JANET_BOOLEAN, c.JANET_CFUNCTION => return false,
        else => {
            const buf: *c.JanetBuffer = @ptrCast(@alignCast(c.janet_malloc(@sizeOf(c.JanetBuffer)) orelse
                ev.outOfMemory(@src())));
            _ = c.janet_buffer_init(buf, 10);
            try marsh.marshal(buf, x.*, null, c.JANET_MARSHAL_UNSAFE);
            x.* = c.janet_wrap_buffer(buf);
            return false;
        },
    }
}

fn unpack(chan: *Channel, x: *c.Janet, is_cleanup: bool) raise.Raising(bool) {
    if (!isThreaded(chan)) return false;
    switch (c.janet_type(x.*)) {
        c.JANET_NIL, c.JANET_NUMBER, c.JANET_POINTER, c.JANET_BOOLEAN, c.JANET_CFUNCTION => return false,
        c.JANET_BUFFER => {
            const buf = c.janet_unwrap_buffer(x.*);
            const flags: c_int = if (is_cleanup)
                c.JANET_MARSHAL_UNSAFE | janet_marshal_decref
            else
                c.JANET_MARSHAL_UNSAFE;
            x.* = try marsh.unmarshal(buf.*.data, @intCast(buf.*.count), flags, null, null);
            c.janet_buffer_deinit(buf);
            c.janet_free(buf);
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
    c.janet_os_mutex_init(@ptrCast(&chan.lock));
}

fn lock(chan: *Channel) void {
    if (!isThreaded(chan)) return;
    c.janet_os_mutex_lock(@ptrCast(&chan.lock));
}

fn unlock(chan: *Channel) void {
    if (!isThreaded(chan)) return;
    c.janet_os_mutex_unlock(@ptrCast(&chan.lock));
}

fn chanDeinit(chan: *Channel) void {
    if (isThreaded(chan)) {
        var item: c.Janet = undefined;
        lock(chan);
        ev_core.qDeinit(&chan.read_pending);
        ev_core.qDeinit(&chan.write_pending);
        while (ev_core.qPop(&chan.items, &item, @sizeOf(c.Janet)) == 0) {
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
    c.janet_os_mutex_deinit(@ptrCast(&chan.lock));
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
fn removeVMRef(fq: *c.JanetQueue) void {
    const pending: [*c]Pending = @ptrCast(@alignCast(fq.data));
    const me = &c.janet_vm;
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

fn markFQ(fq: *c.JanetQueue) void {
    const pending: [*c]Pending = @ptrCast(@alignCast(fq.data));
    if (fq.head <= fq.tail) {
        var i = fq.head;
        while (i < fq.tail) : (i += 1) c.janet_mark(c.janet_wrap_fiber(pending[@intCast(i)].fiber));
    } else {
        var i = fq.head;
        while (i < fq.capacity) : (i += 1) c.janet_mark(c.janet_wrap_fiber(pending[@intCast(i)].fiber));
        i = 0;
        while (i < fq.tail) : (i += 1) c.janet_mark(c.janet_wrap_fiber(pending[@intCast(i)].fiber));
    }
}

fn chanatMark(p: ?*anyopaque, s: usize) callconv(.c) c_int {
    _ = s;
    const chan = unwrap(p);
    markFQ(&chan.read_pending);
    markFQ(&chan.write_pending);
    const items = &chan.items;
    const data: [*c]c.Janet = @ptrCast(@alignCast(items.data));
    if (items.head <= items.tail) {
        var i = items.head;
        while (i < items.tail) : (i += 1) c.janet_mark(data[@intCast(i)]);
    } else {
        var i = items.head;
        while (i < items.capacity) : (i += 1) c.janet_mark(data[@intCast(i)]);
        i = 0;
        while (i < items.tail) : (i += 1) c.janet_mark(data[@intCast(i)]);
    }
    return 0;
}

fn chanatGet(p: ?*anyopaque, key: c.Janet, out: [*c]c.Janet) raise.Raising(c_int) {
    _ = p;
    if (c.janet_checktype(key, c.JANET_KEYWORD) == 0) return 0;
    return c.janet_getmethod(c.janet_unwrap_keyword(key), @ptrCast(&chanat_methods), out);
}

fn chanatNext(p: ?*anyopaque, key: c.Janet) raise.Raising(c.Janet) {
    _ = p;
    return c.janet_nextmethod(@ptrCast(&chanat_methods), key);
}

fn chanatMarshal(p: ?*anyopaque, ctx: [*c]c.JanetMarshalContext) raise.Raising(void) {
    const chan = unwrap(p);
    try marshalling.marshalByte(ctx, @intCast(chan.is_threaded));
    c.janet_marshal_abstract(ctx, chan);
    try marshalling.marshalByte(ctx, @intCast(chan.closed));
    try marshalling.marshalInt(ctx, chan.limit);
    try marshalling.marshalInt(ctx, ev_core.qCount(&chan.items));
    const items = &chan.items;
    const data: [*c]c.Janet = @ptrCast(@alignCast(items.data));
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

fn chanatUnmarshal(ctx: [*c]c.JanetMarshalContext) raise.Raising(?*anyopaque) {
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
        ev.assert(@src(), ev_core.qPush(&abst.items, &item, @sizeOf(c.Janet)) == 0, "bad unmarshal channel");
    }
    return abst;
}

/// `pub` for `ev_loop.zig`, which declared it `extern const` while already
/// importing this file, and for `test/ev_loop.zig`. The `export` stays --
/// `janet.h` declares it.
pub export const janet_channel_type: abstract_type.AbstractType = .{
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

fn makeWriteResult(chan: *Channel) c.Janet {
    const tup = c.janet_tuple_begin(2);
    tup[0] = c.janet_ckeywordv("give");
    tup[1] = wrapChannel(chan);
    return c.janet_wrap_tuple(c.janet_tuple_end(tup));
}

fn makeReadResult(chan: *Channel, x: c.Janet) c.Janet {
    const tup = c.janet_tuple_begin(3);
    tup[0] = c.janet_ckeywordv("take");
    tup[1] = wrapChannel(chan);
    tup[2] = x;
    return c.janet_wrap_tuple(c.janet_tuple_end(tup));
}

fn makeCloseResult(chan: *Channel) c.Janet {
    const tup = c.janet_tuple_begin(2);
    tup[0] = c.janet_ckeywordv("close");
    tup[1] = wrapChannel(chan);
    return c.janet_wrap_tuple(c.janet_tuple_end(tup));
}

/// The `[tag fiber-or-value task-id]` tuple a supervisor channel receives.
pub fn makeSupervisorEvent(name: [*c]const u8, fiber: [*c]c.JanetFiber, threaded: bool) c.Janet {
    var tup: [3]c.Janet = undefined;
    tup[0] = c.janet_ckeywordv(name);
    tup[1] = if (threaded) fiber.*.last_value else c.janet_wrap_fiber(fiber);
    tup[2] = if (fiber.*.env != null)
        c.janet_table_get(fiber.*.env, c.janet_ckeywordv("task-id"))
    else
        c.janet_wrap_nil();
    return c.janet_wrap_tuple(c.janet_tuple_n(&tup, 3));
}

// ==========================================================================
// Waking a fiber that is waiting on another thread's VM
// ==========================================================================

fn threadChanCallback(msg: c.JanetEVGenericMessage) callconv(.c) void {
    const sched_id: u32 = @bitCast(msg.argi);
    const fiber = msg.fiber;
    const mode = msg.tag;
    const chan = unwrap(msg.argp);
    var x = msg.argj;
    lock(chan);
    if (fiber.*.sched_id == sched_id) {
        if (mode == mode_choice_read) {
            ev.assert(@src(), !raise.total(unpack(chan, &x, false), "a threaded channel's wakeup"), "packing error");
            ev.janet_schedule(fiber, makeReadResult(chan, x));
        } else if (mode == mode_choice_write) {
            ev.janet_schedule(fiber, makeWriteResult(chan));
        } else if (mode == mode_read) {
            ev.assert(@src(), !raise.total(unpack(chan, &x, false), "a threaded channel's wakeup"), "packing error");
            ev.janet_schedule(fiber, x);
        } else if (mode == mode_write) {
            ev.janet_schedule(fiber, wrapChannel(chan));
        } else { // mode == mode_close
            ev.janet_schedule(fiber, c.janet_wrap_nil());
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
                ev.janet_ev_post_event(target, threadChanCallback, .{
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
                ev.janet_ev_post_event(target, threadChanCallback, .{
                    .tag = writer.mode,
                    .fiber = writer.fiber,
                    .argi = @bitCast(writer.sched_id),
                    .argp = chan,
                    .argj = c.janet_wrap_nil(),
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
fn pushWithLock(chan: *Channel, x_in: c.Janet, mode: c_int) raise.Raising(bool) {
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
        if (ev_core.qPush(&chan.items, &x, @sizeOf(c.Janet)) != 0) {
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
                .thread = &c.janet_vm,
                .fiber = c.janet_vm.root_fiber,
                .sched_id = c.janet_vm.root_fiber.*.sched_id,
                .mode = if (mode != 0) mode_choice_write else mode_write,
            };
            _ = ev_core.qPush(&chan.write_pending, &pending, @sizeOf(Pending));
            unlock(chan);
            if (is_threaded) c.janet_gcroot(c.janet_wrap_fiber(pending.fiber));
            return true;
        }
    } else {
        // Pending reader.
        if (is_threaded) {
            if (reader.thread) |target| {
                ev.janet_ev_post_event(target, threadChanCallback, .{
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
            ev.janet_schedule(reader.fiber, makeReadResult(chan, x));
        } else {
            ev.janet_schedule(reader.fiber, x);
        }
    }
    unlock(chan);
    return false;
}

pub fn push(chan: *Channel, x: c.Janet, mode: c_int) raise.Raising(bool) {
    lock(chan);
    return pushWithLock(chan, x, mode);
}

/// Pop a value, reporting whether one was obtained.
///
/// `is_choice` is 0 for `ev/take`, 1 for a `ev/select` clause, and 2 for
/// `janet_channel_take`, which does not register a pending read.
fn popWithLock(chan: *Channel, item: *c.Janet, is_choice: c_int) raise.Raising(bool) {
    var writer: Pending = undefined;
    if (chan.closed != 0) {
        unlock(chan);
        item.* = c.janet_wrap_nil();
        return true;
    }
    const is_threaded = isThreaded(chan);
    if (ev_core.qPop(&chan.items, item, @sizeOf(c.Janet)) != 0) {
        // Queue empty.
        if (is_choice == 2) return false; // Skip pending read.
        const pending: Pending = .{
            .thread = &c.janet_vm,
            .fiber = c.janet_vm.root_fiber,
            .sched_id = c.janet_vm.root_fiber.*.sched_id,
            .mode = if (is_choice != 0) mode_choice_read else mode_read,
        };
        _ = ev_core.qPush(&chan.read_pending, &pending, @sizeOf(Pending));
        unlock(chan);
        if (is_threaded) c.janet_gcroot(c.janet_wrap_fiber(pending.fiber));
        return false;
    }
    ev.assert(@src(), !(try unpack(chan, item, false)), "bad channel packing");
    if (ev_core.qPop(&chan.write_pending, &writer, @sizeOf(Pending)) == 0) {
        // Pending writer.
        if (is_threaded) {
            if (writer.thread) |target| {
                ev.janet_ev_post_event(target, threadChanCallback, .{
                    .tag = writer.mode,
                    .fiber = writer.fiber,
                    .argi = @bitCast(writer.sched_id),
                    .argp = chan,
                    .argj = c.janet_wrap_nil(),
                });
            }
        } else if (writer.mode == mode_choice_write) {
            ev.janet_schedule(writer.fiber, makeWriteResult(chan));
        } else {
            ev.janet_schedule(writer.fiber, c.janet_wrap_abstract(chan));
        }
    }
    unlock(chan);
    return true;
}

pub fn pop(chan: *Channel, item: *c.Janet, is_choice: c_int) raise.Raising(bool) {
    lock(chan);
    return popWithLock(chan, item, is_choice);
}

// ==========================================================================
// The public channel API
// ==========================================================================

pub fn getChannel(argv: [*c]const c.Janet, n: i32) raise.Raising(?*c.JanetChannel) {
    return @ptrCast(try arglayer.getAbstract(argv, n, abstract_type.stored(&janet_channel_type)));
}

export fn janet_getchannel(argv: [*c]const c.Janet, n: i32) callconv(.c) ?*c.JanetChannel {
    return raise.reported(getChannel(argv, n));
}

export fn janet_optchannel(
    argv: [*c]const c.Janet,
    argc: i32,
    n: i32,
    dflt: ?*c.JanetChannel,
) callconv(.c) ?*c.JanetChannel {
    if (argc > n and c.janet_checktype(argv[@intCast(n)], c.JANET_NIL) == 0) {
        return raise.reported(getChannel(argv, n));
    }
    return dflt;
}

pub fn channelGive(chan: ?*c.JanetChannel, x: c.Janet) raise.Raising(bool) {
    return push(unwrap(chan), x, 2);
}

export fn janet_channel_give(chan: ?*c.JanetChannel, x: c.Janet) callconv(.c) c_int {
    return @intFromBool(raise.reported(channelGive(chan, x)));
}

pub fn channelTake(chan: ?*c.JanetChannel, out: *c.Janet) raise.Raising(bool) {
    return pop(unwrap(chan), out, 2);
}

export fn janet_channel_take(chan: ?*c.JanetChannel, out: *c.Janet) callconv(.c) c_int {
    return @intFromBool(raise.reported(channelTake(chan, out)));
}

pub export fn janet_channel_make(limit: u32) callconv(.c) ?*c.JanetChannel {
    ev.assert(@src(), limit <= std.math.maxInt(i32), "bad limit");
    const chan = unwrap(c.janet_abstract(abstract_type.stored(&janet_channel_type), @sizeOf(Channel)));
    chanInit(chan, @intCast(limit), false);
    return @ptrCast(chan);
}

pub export fn janet_channel_make_threaded(limit: u32) callconv(.c) ?*c.JanetChannel {
    ev.assert(@src(), limit <= std.math.maxInt(i32), "bad limit");
    const chan = unwrap(c.janet_abstract_threaded(abstract_type.stored(&janet_channel_type), @sizeOf(Channel)));
    chanInit(chan, @intCast(limit), true);
    return @ptrCast(chan);
}

// ==========================================================================
// The cfunctions
// ==========================================================================

fn channelArg(argv: [*c]const c.Janet, n: i32) raise.Raising(*Channel) {
    return unwrap(try arglayer.getAbstract(argv, n, abstract_type.stored(&janet_channel_type)));
}

fn giveImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 2);
    const chan = try channelArg(argv, 0);
    if (c.janet_vm.coerce_error != 0) {
        return raise.panic("cannot give to channel inside janet_call");
    }
    if (try push(chan, argv[1], 0)) return ev.awaitEvent();
    return argv[0];
}

fn takeImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    const chan = try channelArg(argv, 0);
    var item: c.Janet = undefined;
    if (c.janet_vm.coerce_error != 0) {
        return raise.panic("cannot take from channel inside janet_call");
    }
    if (try pop(chan, &item, 0)) ev.janet_schedule(c.janet_vm.root_fiber, item);
    return ev.awaitEvent();
}

fn choiceImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 1, -1);
    var len: i32 = undefined;
    var data: [*c]const c.Janet = undefined;

    if (c.janet_vm.coerce_error != 0) {
        return raise.panic("cannot select from channel inside janet_call");
    }

    // Check channels for immediate reads and writes.
    var i: i32 = 0;
    while (i < argc) : (i += 1) {
        if (c.janet_indexed_view(argv[@intCast(i)], &data, &len) != 0 and len == 2) {
            // Write.
            const chan = try channelArg(data, 0);
            lock(chan);
            if (chan.closed != 0) {
                unlock(chan);
                return makeCloseResult(chan);
            }
            if (ev_core.qCount(&chan.items) < chan.limit) {
                _ = try pushWithLock(chan, data[1], 1);
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
                var item: c.Janet = undefined;
                _ = try popWithLock(chan, &item, 1);
                return makeReadResult(chan, item);
            }
            unlock(chan);
        }
    }

    // Wait for all readers or writers.
    i = 0;
    while (i < argc) : (i += 1) {
        if (c.janet_indexed_view(argv[@intCast(i)], &data, &len) != 0 and len == 2) {
            const chan = try channelArg(data, 0);
            lock(chan);
            _ = try pushWithLock(chan, data[1], 1);
        } else {
            var item: c.Janet = undefined;
            const chan = try channelArg(argv, i);
            lock(chan);
            _ = try popWithLock(chan, &item, 1);
        }
    }

    return ev.awaitEvent();
}

fn fullImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    const chan = try channelArg(argv, 0);
    lock(chan);
    const ret = c.janet_wrap_boolean(@intFromBool(ev_core.qCount(&chan.items) >= chan.limit));
    unlock(chan);
    return ret;
}

fn capacityImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    const chan = try channelArg(argv, 0);
    lock(chan);
    const ret = ev.wrapInteger(chan.limit);
    unlock(chan);
    return ret;
}

fn countImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    const chan = try channelArg(argv, 0);
    lock(chan);
    const ret = ev.wrapInteger(ev_core.qCount(&chan.items));
    unlock(chan);
    return ret;
}

/// Fisher-Yates shuffle of the arguments, so that `ev/rselect` is fair.
fn fisherYatesArgs(argc: i32, argv: [*c]c.Janet) void {
    var i = argc;
    while (i > 1) : (i -= 1) {
        const swap_index = c.janet_rng_u32(&c.janet_vm.ev_rng) % @as(u32, @intCast(i));
        const temp = argv[swap_index];
        argv[swap_index] = argv[@intCast(i - 1)];
        argv[@intCast(i - 1)] = temp;
    }
}

fn rchoiceImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    fisherYatesArgs(argc, argv);
    return choiceImpl(argc, argv);
}

fn newImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 0, 1);
    const limit = try arglayer.optNat(argv, argc, 0, 0);
    const chan = unwrap(c.janet_abstract(abstract_type.stored(&janet_channel_type), @sizeOf(Channel)));
    chanInit(chan, limit, false);
    return c.janet_wrap_abstract(chan);
}

fn newThreadedImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 0, 1);
    const limit = try arglayer.optNat(argv, argc, 0, 0);
    const chan = unwrap(c.janet_abstract_threaded(abstract_type.stored(&janet_channel_type), @sizeOf(Channel)));
    chanInit(chan, limit, true);
    return c.janet_wrap_abstract(chan);
}

fn closeImpl(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    const chan = try channelArg(argv, 0);
    lock(chan);
    if (chan.closed == 0) {
        chan.closed = 1;
        var writer: Pending = undefined;
        while (ev_core.qPop(&chan.write_pending, &writer, @sizeOf(Pending)) == 0) {
            if (writer.thread != &c.janet_vm) {
                if (writer.thread) |target| {
                    ev.janet_ev_post_event(target, threadChanCallback, .{
                        .fiber = writer.fiber,
                        .argp = chan,
                        .tag = mode_close,
                        .argi = @bitCast(writer.sched_id),
                        .argj = c.janet_wrap_nil(),
                    });
                }
            } else if (c.janet_fiber_can_resume(writer.fiber) != 0 and
                writer.sched_id == writer.fiber.*.sched_id)
            {
                if (writer.mode == mode_choice_write) {
                    ev.janet_schedule(writer.fiber, makeCloseResult(chan));
                } else {
                    ev.janet_schedule(writer.fiber, c.janet_wrap_nil());
                }
            }
        }
        var reader: Pending = undefined;
        while (ev_core.qPop(&chan.read_pending, &reader, @sizeOf(Pending)) == 0) {
            if (reader.thread != &c.janet_vm) {
                if (reader.thread) |target| {
                    ev.janet_ev_post_event(target, threadChanCallback, .{
                        .fiber = reader.fiber,
                        .argp = chan,
                        .tag = mode_close,
                        .argi = @bitCast(reader.sched_id),
                        .argj = c.janet_wrap_nil(),
                    });
                }
            } else if (c.janet_fiber_can_resume(reader.fiber) != 0 and
                reader.sched_id == reader.fiber.*.sched_id)
            {
                if (reader.mode == mode_choice_read) {
                    ev.janet_schedule(reader.fiber, makeCloseResult(chan));
                } else {
                    ev.janet_schedule(reader.fiber, c.janet_wrap_nil());
                }
            }
        }
    }
    unlock(chan);
    return argv[0];
}

const chanat_methods = [_]corefn.Method{
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
